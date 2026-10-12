defmodule DpExchange.Schwab.PathAndWindowTest do
  @moduledoc """
  Caller-supplied path segments are one segment, transactions share the orders window rules,
  and `/accounts/accountNumbers` rows that cannot be addressed are refused.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Schwab.Rest

  defmodule Limiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, Limiter)
    :ok
  end

  @creds %{access_token: "at-1"}

  defp capturing(body, me) do
    fn conn ->
      send(me, {:request, conn.method, conn.request_path})
      Req.Test.json(conn, body)
    end
  end

  defp exploding, do: fn _conn -> raise "a request with an unusable path or window was sent" end

  describe "path segments" do
    test "a slash in an order id is escaped, so a DELETE cannot be redirected" do
      assert :ok =
               Rest.cancel_order(@creds, "HASH", "1/../../orders",
                 plug: capturing(%{}, self()),
                 retry_attempts: 0
               )

      assert_receive {:request, "DELETE", path}, 5_000
      assert path == "/trader/v1/accounts/HASH/orders/1%2F..%2F..%2Forders"
    end

    test "an integer order id is its digits" do
      assert {:ok, %{}} =
               Rest.get_order(@creds, "HASH", 1_005_439_821,
                 plug: capturing(%{}, self()),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", "/trader/v1/accounts/HASH/orders/1005439821"}, 5_000
    end

    test "an empty or non-text id is refused before any request" do
      refused = {:error, {:invalid_path_segment, :schwab}}
      opts = [plug: exploding(), retry_attempts: 0]

      assert refused == Rest.get_order(@creds, "HASH", "", opts)
      assert refused == Rest.cancel_order(@creds, "HASH", :nope, opts)
      assert refused == Rest.get_order(@creds, "", "1", opts)
      assert refused == Rest.get_balances(@creds, nil, opts)
      assert refused == Rest.get_transaction(@creds, "HASH", %{}, opts)
      assert refused == Rest.replace_order(@creds, "HASH", "", %{}, opts)
      assert refused == Rest.place_order(@creds, "", %{}, opts)
      assert refused == Rest.preview_order(@creds, "", %{}, opts)
    end

    test "a transaction id cannot leave its segment" do
      assert {:ok, []} =
               Rest.get_transaction(@creds, "HASH", "5?x=1#y",
                 plug: capturing([], self()),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path}, 5_000
      assert path == "/trader/v1/accounts/HASH/transactions/5%3Fx%3D1%23y"
    end
  end

  describe "transactions window" do
    test "a reversed, over-long or unreadable window is refused before any request" do
      cases = [
        {[from: ~U[2026-09-01 00:00:00Z], to: ~U[2026-08-01 00:00:00Z]],
         {:transaction_window_reversed, :schwab}},
        {[from: ~U[2024-08-01 00:00:00Z], to: ~U[2026-08-01 00:00:00Z]],
         {:transaction_window_too_long, :schwab}},
        {[from: "last week", to: "today"], {:transaction_window_invalid, :schwab}},
        {[from: 1, to: 2], {:transaction_window_invalid, :schwab}}
      ]

      for {window, reason} <- cases do
        assert {:error, ^reason} =
                 Rest.get_transactions(
                   @creds,
                   "HASH",
                   window ++ [types: ["TRADE"], plug: exploding()]
                 )

        assert {:error, ^reason} = Rest.check_transactions(window ++ [types: ["TRADE"]])
      end
    end

    test "a window of exactly a year is accepted" do
      window = [from: ~U[2025-08-01 00:00:00Z], to: ~U[2026-08-01 00:00:00Z]]
      assert :ok = Rest.check_transactions(window ++ [types: "TRADE"])
    end
  end

  describe "get_accounts/2 rows" do
    test "a row without a usable hash refuses the whole reply" do
      for body <- [
            ["not an object"],
            [%{"accountNumber" => "1", "hashValue" => 42}],
            [%{"accountNumber" => "1", "hashValue" => ""}],
            [%{"accountNumber" => "1"}]
          ] do
        plug = fn conn -> Req.Test.json(conn, body) end

        assert {:error, :unexpected_response_shape} =
                 Rest.get_accounts(@creds, plug: plug, retry_attempts: 0)
      end
    end
  end

  describe "list query values" do
    test "a list of fields is comma-joined rather than raising" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})
        Req.Test.json(conn, [])
      end

      assert {:ok, []} =
               Rest.get_account_summaries(@creds,
                 fields: ["positions", :orders],
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, "fields=positions%2Corders"}, 5_000
    end
  end

  describe "the /orders 60-day rule" do
    @now ~U[2026-10-11 12:00:00Z]

    test "a start more than 60 days before now is refused before any request" do
      opts = [
        from: ~U[2026-08-01 00:00:00Z],
        to: ~U[2026-08-02 00:00:00Z],
        now: @now,
        plug: exploding()
      ]

      assert {:error, {:order_window_start_too_old, :schwab}} = Rest.get_all_orders(@creds, opts)
      assert {:error, {:order_window_start_too_old, :schwab}} = Rest.check_all_orders_window(opts)
    end

    test "exactly 60 days is accepted, and the per-account endpoint has no such rule" do
      sixty = [from: DateTime.add(@now, -60 * 86_400, :second), to: @now, now: @now]
      assert :ok = Rest.check_all_orders_window(sixty)

      old = [from: ~U[2026-08-01 00:00:00Z], to: ~U[2026-08-02 00:00:00Z], now: @now]
      assert :ok = Rest.check_order_window(old)

      assert {:ok, []} =
               Rest.get_orders(@creds, "HASH",
                 from: old[:from],
                 to: old[:to],
                 plug: capturing([], self()),
                 retry_attempts: 0
               )
    end
  end

  describe "status and types are checked against the spec's enums" do
    @window [from: ~U[2026-10-01 00:00:00Z], to: ~U[2026-10-02 00:00:00Z], now: @now]

    test "an order status outside apiOrderStatus is refused before any request" do
      assert length(Rest.order_statuses()) == 21

      for status <- ["working", :WORKING, "OPEN", "", 7] do
        opts = [status: status, plug: exploding(), retry_attempts: 0] ++ @window
        refused = {:error, {:invalid_order_status, status}}

        assert refused == Rest.get_all_orders(@creds, opts)
        assert refused == Rest.get_orders(@creds, "HASH", opts)
        assert refused == Rest.check_order_window(opts)
      end
    end

    test "every listed status is sent as given" do
      for status <- Rest.order_statuses() do
        assert {:ok, []} =
                 Rest.get_orders(
                   @creds,
                   "HASH",
                   [status: status, plug: capturing([], self()), retry_attempts: 0] ++ @window
                 )
      end
    end

    test "a transaction type outside TransactionType is refused before any request" do
      for type <- ["trade", :TRADE, "ALL", ""] do
        assert {:error, _reason} =
                 Rest.get_transactions(
                   @creds,
                   "HASH",
                   [types: type, plug: exploding()] ++ Keyword.take(@window, [:from, :to])
                 )
      end
    end
  end

  describe "numbers that are finite but absurd" do
    test "a price with an exponent beyond 1000 is refused, as a string or a struct" do
      body = %{"AAPL" => %{"quote" => %{"lastPrice" => "1e999999999", "quoteTime" => 1}}}
      plug = fn conn -> Req.Test.json(conn, body) end

      assert {:error, {:invalid_decimal, :price, "1e999999999"}} =
               Rest.get_price("AAPL", @creds, plug: plug, retry_attempts: 0)

      buy = %{symbol: "AAPL", side: :buy, quantity: 1, order_type: :limit, time_in_force: :day}

      absurd = ["1e999999999", Decimal.new("1E5000"), Decimal.new("NaN"), Decimal.new("-Inf")]

      for price <- absurd do
        assert {:error, {:invalid_price, ^price}} =
                 DpExchange.Schwab.Orders.build(Map.put(buy, :price, price))
      end

      assert {:ok, _payload} =
               DpExchange.Schwab.Orders.build(Map.put(buy, :price, Decimal.new("1E3")))
    end

    test "a strike key with an absurd exponent is an unreadable strike" do
      strikes = %{"1E5000" => [%{}]}
      body = %{"symbol" => "AAPL", "callExpDateMap" => %{"2026-12-18:60" => strikes}}
      plug = fn conn -> Req.Test.json(conn, body) end

      assert {:error, {:unreadable_chain_strike, "1E5000"}} =
               Rest.get_option_chain("AAPL", @creds, plug: plug, retry_attempts: 0)
    end
  end
end
