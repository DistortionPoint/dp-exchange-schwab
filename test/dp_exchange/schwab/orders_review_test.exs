defmodule DpExchange.Schwab.OrdersReviewTest do
  @moduledoc """
  Order building and the facade's order calls, re-read against the spec: an absurd quantity
  exponent, text prices, the order of the replace checks, and the fake's all-accounts read.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.Order
  alias DpExchange.Schwab
  alias DpExchange.Schwab.{Fake, Orders, Rest}

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
  @buy %{symbol: "AAPL", side: :buy, quantity: 15}

  defp no_tree_opts do
    [
      account_hash: "H",
      order_limit: :"no_order_limit_#{System.unique_integer([:positive])}",
      retry_attempts: 0
    ]
  end

  describe "a quantity with an absurd exponent" do
    test "is refused before it is expanded to a float" do
      huge = %Decimal{sign: 1, coef: 1, exp: 999_999_999}
      tiny = %Decimal{sign: 1, coef: 1, exp: -999_999_999}

      for quantity <- [huge, tiny] do
        assert Orders.build(%{@buy | quantity: quantity}) ==
                 {:error, {:invalid_quantity, quantity}}
      end
    end

    test "an ordinary exponent is still a quantity" do
      assert {:ok, %{"orderLegCollection" => [%{"quantity" => quantity}]}} =
               Orders.build(%{@buy | quantity: Decimal.new("1.5E1")})

      assert quantity == 15.0
    end
  end

  describe "a zero or negative limit or stop price" do
    test "is refused for LIMIT, STOP, STOP_LIMIT and TRAILING_STOP_LIMIT" do
      zeroes = [0, -1, 0.0, -2.5, "0", " -3 ", Decimal.new("0"), Decimal.new("-0.01")]

      for value <- zeroes do
        refused = {:error, {:invalid_price, value}}

        assert Orders.build(Map.merge(@buy, %{order_type: :limit, price: value})) == refused

        assert Orders.build(Map.merge(@buy, %{order_type: :stop, stop_price: value})) ==
                 refused

        stop_limit = Map.merge(@buy, %{order_type: :stop_limit, price: 5, stop_price: value})
        assert Orders.build(stop_limit) == refused

        stop_limit = Map.merge(@buy, %{order_type: :stop_limit, price: value, stop_price: 5})
        assert Orders.build(stop_limit) == refused

        trailing =
          Map.merge(@buy, %{order_type: :trailing_stop_limit, price: value, stop_price_offset: 1})

        assert Orders.build(trailing) == refused
      end
    end

    test "a positive price still builds" do
      assert {:ok, %{"price" => "0.01"}} =
               Orders.build(Map.merge(@buy, %{order_type: :limit, price: "0.01"}))
    end
  end

  describe "Feed.update_credentials/2 with a non-map" do
    test "is refused in the caller and the feed is untouched" do
      {:ok, feed} =
        DpExchange.Schwab.Feed.start_link(name: nil, credentials: @creds, symbols: ["AAPL"])

      for bad <- [nil, "token", [access_token: "x"], {:error, :refresh_failed}] do
        assert DpExchange.Schwab.Feed.update_credentials(feed, bad) ==
                 {:error, {:invalid_credentials, bad}}
      end

      assert Process.alive?(feed)
      assert DpExchange.Schwab.Feed.wanted(feed) == ["AAPL"]
      GenServer.stop(feed)
    end
  end

  describe "a request that is not a map" do
    test "is refused by name, not raised on" do
      for request <- [[symbol: "AAPL", quantity: 1], nil, "AAPL"] do
        assert Orders.build(request) == {:error, {:invalid_order_request, request}}

        assert Fake.place_order(@creds, request, account_hash: "H") ==
                 {:error, {:invalid_order_request, request}}
      end
    end
  end

  describe "a price or offset given as text is sent as the number it reads as" do
    test "blanks and an exponent do not reach the wire" do
      limit = Map.merge(@buy, %{order_type: :limit, price: " 6.45 "})
      assert {:ok, %{"price" => "6.45"}} = Orders.build(limit)

      limit = Map.merge(@buy, %{order_type: :limit, price: "1E+2"})
      assert {:ok, %{"price" => "100"}} = Orders.build(limit)
    end

    test "a text stopPriceOffset is a bare JSON number, as a Decimal one is" do
      trailing = Map.merge(@buy, %{order_type: :trailing_stop, stop_price_offset: "10.50"})

      assert {:ok, %{"stopPriceOffset" => %Jason.Fragment{} = offset}} = Orders.build(trailing)
      assert Jason.encode!(%{"x" => offset}) == ~s({"x":10.50})
    end
  end

  describe "the facade's order calls" do
    test "replace_order/4 checks the order id before it builds the request" do
      refused = {:error, {:invalid_path_segment, :schwab}}
      exploding = fn _conn -> raise "a request with an unusable order id was sent" end
      opts = no_tree_opts() ++ [plug: exploding]

      # Wrong in both ways: the same answer as `Fake.replace_order/4`, which checks the id first.
      broken_request = %{symbol: "AAPL"}

      for bad <- ["", :nope, nil] do
        assert Schwab.replace_order(@creds, bad, broken_request, opts) == refused

        assert Fake.replace_order(@creds, bad, broken_request, account_hash: "H") == refused
      end
    end

    test "replace_order/4 still names the request when the id is usable" do
      assert Schwab.replace_order(@creds, "1", %{symbol: "AAPL"}, no_tree_opts()) ==
               {:error, {:missing_order_field, :quantity}}

      assert Fake.replace_order(@creds, "1", %{symbol: "AAPL"}, account_hash: "H") ==
               {:error, {:missing_order_field, :quantity}}
    end

    test "a placed order whose read-back fails carries a text price as a Decimal" do
      plug = fn conn ->
        conn |> Plug.Conn.put_resp_header("location", "/orders/7") |> Plug.Conn.resp(201, "")
      end

      request = Map.merge(@buy, %{order_type: :limit, price: " 190.25 "})

      assert {:ok, %Order{id: "7", price: price, quantity: quantity, order_type: :limit}} =
               Schwab.place_order(@creds, request, no_tree_opts() ++ [plug: plug])

      assert Decimal.equal?(price, Decimal.new("190.25"))
      assert Decimal.equal?(quantity, 15)
    end

    test "a placed market order with an explicit nil type reads back as a market order" do
      plug = fn conn ->
        conn |> Plug.Conn.put_resp_header("location", "/orders/7") |> Plug.Conn.resp(201, "")
      end

      request = Map.put(@buy, :order_type, nil)

      assert {:ok, %Order{order_type: :market}} =
               Schwab.place_order(@creds, request, no_tree_opts() ++ [plug: plug])
    end
  end

  describe "Fake.get_all_orders/2" do
    @window [from: ~U[2026-01-01 00:00:00Z], to: ~U[2026-01-03 00:00:00Z]]
    @now [now: ~U[2026-01-15 00:00:00Z]]

    test "lists the venue's own rows inside the window, with no account hash" do
      assert {:ok, [%{"status" => "FILLED", "orderId" => _id}]} =
               Fake.get_all_orders(@creds, @window ++ @now)

      outside = [from: ~U[2026-01-04 00:00:00Z], to: ~U[2026-01-05 00:00:00Z]]
      assert {:ok, []} = Fake.get_all_orders(@creds, outside ++ @now)
    end

    test "a placed order is listed by a window around now, and the status narrows it" do
      assert {:ok, %Order{}} = Fake.place_order(@creds, @buy, account_hash: "H")

      now = DateTime.utc_now()
      window = [from: DateTime.add(now, -3_600), to: DateTime.add(now, 3_600)]

      assert {:ok, [%{"status" => "WORKING"}]} = Fake.get_all_orders(@creds, window)

      working = [status: "WORKING"] ++ window
      assert {:ok, [%{"status" => "WORKING"}]} = Fake.get_all_orders(@creds, working)

      filled = [status: "FILLED"] ++ window
      assert {:ok, []} = Fake.get_all_orders(@creds, filled)
    end

    test "refuses what Rest refuses, before the credential" do
      assert {:error, _no_window} = refused = Fake.get_all_orders(%{}, [])
      assert refused == Rest.check_all_orders_window([])

      # 106 days before @now: past the spec's 60-day bound.
      too_old = [from: ~U[2025-10-01 00:00:00Z], to: ~U[2025-10-02 00:00:00Z]] ++ @now

      assert Fake.get_all_orders(@creds, too_old) ==
               {:error, {:order_window_start_too_old, :schwab}}

      assert Fake.get_all_orders(@creds, [status: :working] ++ @window ++ @now) ==
               {:error, {:invalid_order_status, :working}}

      reversed = [from: ~U[2026-01-03 00:00:00Z], to: ~U[2026-01-01 00:00:00Z]] ++ @now

      assert Fake.get_all_orders(@creds, reversed) ==
               {:error, {:order_window_reversed, :schwab}}
    end

    test "a valid window still needs a credential" do
      assert Fake.get_all_orders(%{}, @window ++ @now) ==
               {:error, {:missing_credentials, :schwab}}
    end
  end
end
