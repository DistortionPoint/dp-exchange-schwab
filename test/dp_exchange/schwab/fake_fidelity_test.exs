defmodule DpExchange.Schwab.FakeFidelityTest do
  @moduledoc """
  The fake refuses what the real path refuses, **in the same order**, and answers with the
  shapes the real decode produces.

  Every refusal compared here is one the real facade makes locally, before any request
  leaves, so each is asserted against the real facade and the fake side by side and neither
  needs a network. A consumer whose tests run against the fake would otherwise see a
  different error from the one production returns for the same mistake.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Schwab
  alias DpExchange.Schwab.{Fake, Rest}

  defmodule PermissiveLimiter do
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
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @creds %{access_token: "at-1"}
  @window [from: ~U[2026-08-01 00:00:00Z], to: ~U[2026-09-01 00:00:00Z]]

  defp responding(body), do: fn conn -> Req.Test.json(conn, body) end

  defp capturing(body, test_pid) do
    fn conn ->
      send(test_pid, {:request, conn.request_path, conn.query_string})
      Req.Test.json(conn, body)
    end
  end

  describe "the account hash comes before the credential, as in the facade" do
    test "every account endpoint names the missing hash when both are missing" do
      request = %{symbol: "AAPL", side: :buy, quantity: 1}

      cases = [
        {:get_balances, [%{}, []]},
        {:get_order, [%{}, "1", []]},
        {:get_orders, [%{}, []]},
        {:get_transactions, [%{}, []]},
        {:preview_order, [%{}, request, []]}
      ]

      for {function, args} <- cases do
        real = apply(Schwab, function, args)
        assert real == {:error, {:missing_account_hash, :schwab}}
        assert apply(Fake, function, args) == real
      end
    end

    test "the order's own shape is refused before the credential is looked at" do
      # `preview_order/3`, because it has no order-ceiling check ahead of the build.
      args = [%{}, %{symbol: "AAPL", quantity: 1}, [account_hash: "H"]]

      assert {:error, {:missing_order_field, :side}} = apply(Schwab, :preview_order, args)
      assert apply(Fake, :preview_order, args) == apply(Schwab, :preview_order, args)

      assert {:error, {:missing_order_field, :side}} =
               Fake.place_order(%{}, %{symbol: "AAPL", quantity: 1}, account_hash: "H")

      assert {:error, {:missing_order_field, :side}} =
               Fake.replace_order(%{}, "1", %{symbol: "AAPL", quantity: 1}, account_hash: "H")
    end

    test "the window is refused before the credential, for orders and transactions" do
      assert {:error, {:from_and_to_required, :schwab}} =
               Schwab.get_orders(%{}, account_hash: "H")

      assert Fake.get_orders(%{}, account_hash: "H") ==
               Schwab.get_orders(%{}, account_hash: "H")

      assert Fake.get_transactions(%{}, account_hash: "H") ==
               Schwab.get_transactions(%{}, account_hash: "H")
    end

    test "with everything else right, the credential is the last refusal" do
      assert {:error, {:missing_credentials, :schwab}} =
               Fake.get_balances(%{}, account_hash: "H")

      assert {:error, {:missing_credentials, :schwab}} =
               Fake.cancel_order(%{}, "1", account_hash: "H")
    end
  end

  describe "transactions: the type is validated by the module that sends it" do
    test "a type outside the venue's enum is refused by the fake as by the facade" do
      opts = [account_hash: "H", types: "EVERYTHING"] ++ @window

      assert {:error, {:unknown_transaction_types, ["EVERYTHING"]}} =
               Schwab.get_transactions(@creds, opts)

      assert Fake.get_transactions(@creds, opts) == Schwab.get_transactions(@creds, opts)
    end

    test "a type given as an atom is refused, not raised on" do
      # `types: :TRADE` matched no clause and raised `CaseClauseError` in the caller.
      opts = [account_hash: "H", types: :TRADE] ++ @window

      assert {:error, {:unknown_transaction_types, [:TRADE]}} =
               Schwab.get_transactions(@creds, opts)

      assert Fake.get_transactions(@creds, opts) == Schwab.get_transactions(@creds, opts)
    end

    test "a one-element list of a non-string is a bad type, not 'multiple types'" do
      opts = [account_hash: "H", types: [:TRADE]] ++ @window

      assert {:error, {:unknown_transaction_types, [:TRADE]}} =
               Schwab.get_transactions(@creds, opts)
    end

    test "an empty list names no type" do
      opts = [account_hash: "H", types: []] ++ @window

      assert {:error, {:types_required, :schwab}} = Schwab.get_transactions(@creds, opts)
      assert Fake.get_transactions(@creds, opts) == Schwab.get_transactions(@creds, opts)
    end

    test "a valid single type is served by the fake" do
      opts = [account_hash: "H", types: ["TRADE"]] ++ @window
      assert {:ok, [%{"type" => "TRADE"}]} = Fake.get_transactions(@creds, opts)
    end
  end

  describe "movers: the universe is judged before the credential" do
    test "an unknown universe is the same refusal with or without a credential" do
      assert {:error, {:unknown_movers_universe, "NOPE"}} = Schwab.get_screener("NOPE", [])
      assert Fake.get_screener("NOPE", []) == Schwab.get_screener("NOPE", [])
    end

    test "a universe that is not a string is refused, not raised on" do
      assert {:error, {:unknown_movers_universe, :nasdaq}} =
               Rest.get_movers(:nasdaq, @creds, retry_attempts: 0)

      assert {:error, {:unknown_market, :equity}} =
               Rest.get_market(:equity, @creds, retry_attempts: 0)
    end

    test "the fake's row carries the symbol in its metrics, as the venue's row does" do
      assert {:ok, [%{metrics: %{"symbol" => "AAPL"}}]} =
               Fake.get_screener("$DJI", credentials: @creds)
    end
  end

  describe "options: an underlying that is not a symbol is refused, not raised on" do
    test "the chain and the expirations answer an error for a non-string underlying" do
      for bad <- [:aapl, nil, ""] do
        assert {:error, {:invalid_underlying, ^bad}} =
                 Rest.get_option_chain(bad, @creds, retry_attempts: 0)

        assert {:error, {:invalid_underlying, ^bad}} =
                 Rest.get_option_expirations(bad, @creds, retry_attempts: 0)
      end
    end

    test "the fake refuses it first, before the credential, as the real path does" do
      assert {:error, {:invalid_underlying, :aapl}} = Fake.get_option_chain(:aapl, [])
      assert {:error, {:invalid_underlying, :aapl}} = Fake.get_option_expirations(:aapl, [])
    end
  end

  describe "history: the range is judged by the module that sends the request" do
    test "an end with no start is refused by the fake as by the facade" do
      range = [end: ~U[2026-06-05 00:00:00Z]]
      opts = [credentials: @creds]

      assert {:error, {:range_start_required, :schwab}} =
               Schwab.get_historical_prices("AAPL", "1d", range, opts)

      assert Fake.get_historical_prices("AAPL", "1d", range, opts) ==
               Schwab.get_historical_prices("AAPL", "1d", range, opts)
    end

    test "a start after its end is refused by the fake as by the facade" do
      range = [start: ~U[2026-06-05 00:00:00Z], end: ~U[2026-06-01 00:00:00Z]]
      opts = [credentials: @creds]

      assert {:error, {:range_start_after_end, :schwab}} =
               Schwab.get_historical_prices("AAPL", "1d", range, opts)

      assert Fake.get_historical_prices("AAPL", "1d", range, opts) ==
               Schwab.get_historical_prices("AAPL", "1d", range, opts)
    end

    test "a bounded window is sized by its own span, not by how long ago it began" do
      # Thirty days back, but a one-day window: the venue is asked for one day of one-minute
      # bars, which it can serve. The fake measured from the start alone and refused it.
      start = DateTime.add(Fake.as_of(), -30, :day)
      range = [start: start, end: DateTime.add(start, 1, :day)]

      assert {:ok, [_first | _rest]} =
               Fake.get_historical_prices("AAPL", "1m", range, credentials: @creds)

      assert :ok = Rest.check_history("1m", range, Fake.as_of())
    end

    test "an open-ended range is still measured back from now" do
      range = [start: DateTime.add(Fake.as_of(), -30, :day)]

      assert {:error, {:lookback_exceeds_venue, "1m", 30, 10}} =
               Rest.check_history("1m", range, Fake.as_of())

      assert {:error, {:lookback_exceeds_venue, "1m", 30, 10}} =
               Fake.get_historical_prices("AAPL", "1m", range, credentials: @creds)
    end
  end

  describe "the fake's values are the shapes the real decode produces" do
    test "available balance is part of the total, never more than it" do
      assert {:ok, [balance]} = Fake.get_balances(@creds, account_hash: "H")
      assert Decimal.compare(balance.available_balance, balance.balance) != :gt
    end

    test "a short position is unsigned and states no realised P/L" do
      assert {:ok, [position]} = Fake.get_positions(credentials: @creds)
      assert position.side == :short
      refute Decimal.negative?(position.notional_value)
      assert position.realised_pnl == nil
    end
  end

  describe "the real endpoints these tests lean on" do
    test "a single-symbol quote that is not an object is refused" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_symbol_quote("AAPL", @creds,
                 plug: responding([%{"quote" => %{}}]),
                 retry_attempts: 0
               )
    end

    test "contract_type reaches the venue, and so does the camelCase spelling" do
      for key <- [:contract_type, :contractType] do
        opts = [{key, "CALL"}, symbol: "AAPL", plug: capturing(%{}, self()), retry_attempts: 0]

        assert {:ok, _body} = Rest.get_chains(@creds, opts)

        assert_receive {:request, "/marketdata/v1/chains", query}
        assert URI.decode_query(query)["contractType"] == "CALL"
      end
    end

    test "no contract type is sent when none is given" do
      assert {:ok, _body} =
               Rest.get_chains(@creds,
                 symbol: "AAPL",
                 plug: capturing(%{}, self()),
                 retry_attempts: 0
               )

      assert_receive {:request, "/marketdata/v1/chains", query}
      refute Map.has_key?(URI.decode_query(query), "contractType")
    end
  end
end
