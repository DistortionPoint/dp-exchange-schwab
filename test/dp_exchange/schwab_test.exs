defmodule DpExchange.SchwabTest do
  @moduledoc """
  The facade, its supervision tree, and the fake.

  The tests worth reading are the ones about *which refusal*. This venue distinguishes
  four things a caller must handle differently — no credential, no account hash, no
  search term, and an endpoint the venue does not have — and collapsing any pair of them
  would send a consumer looking in the wrong place.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias DpExchange.Core.Capabilities
  alias DpExchange.Schwab
  alias DpExchange.Schwab.{Fake, Feed, Supervisor}

  @creds %{access_token: "at-1"}

  describe "identity" do
    test "the venue names itself the same way everywhere" do
      assert Schwab.provider_name() == "Schwab"
      assert Schwab.runtime_id() == :schwab
      assert Schwab.asset_classes() == [:equity]
      assert Schwab.quotes() == ["USD"]
      assert %Capabilities{} = Schwab.capabilities()
    end

    test "it is the only venue in the family that is not crypto" do
      refute :crypto in Schwab.asset_classes()
    end
  end

  describe "the four refusals a caller must tell apart" do
    test "no credentials — market data included, because there is no anonymous surface" do
      assert Schwab.get_price("AAPL") == {:error, {:missing_credentials, :schwab}}
      assert Schwab.get_symbols() == {:error, {:missing_credentials, :schwab}}
      assert Schwab.market_status() == {:error, {:missing_credentials, :schwab}}

      assert Schwab.get_historical_prices("AAPL", "1d", []) ==
               {:error, {:missing_credentials, :schwab}}
    end

    test "no account hash — every account path takes one, and none is defaulted" do
      # Silently using some first account would place an order against an account the
      # caller did not choose.
      for call <- [
            fn -> Schwab.get_balances(@creds) end,
            fn -> Schwab.place_order(@creds, %{symbol: "AAPL", side: :buy, quantity: 1}) end,
            fn -> Schwab.cancel_order(@creds, "1") end,
            fn -> Schwab.get_order(@creds, "1") end,
            fn -> Schwab.get_orders(@creds) end
          ] do
        assert call.() == {:error, {:missing_account_hash, :schwab}}
      end
    end

    test "no search term — a pull needs one, and that is not the same as no pull" do
      # Core's contract asserts every venue can be pulled. This venue can be, but only
      # against a term: `/instruments` has no list-everything projection.
      assert Schwab.get_symbols(credentials: @creds) == {:error, {:query_required, :schwab}}
      refute Schwab.get_symbols(credentials: @creds) == {:error, :not_supported}
    end

    test "endpoints the venue does not have say so, and only those" do
      assert Schwab.get_order_book("AAPL") == {:error, :not_supported}
      assert Schwab.get_market_overview() == {:error, :not_supported}
      assert Schwab.list_instruments() == {:error, :not_supported}
      assert Schwab.quantization("AAPL") == {:error, :not_supported}
      assert Schwab.get_fees(@creds) == {:error, :not_supported}
      assert Schwab.get_transfers(@creds) == {:error, :not_supported}
      assert Schwab.get_trade_history(@creds) == {:error, :not_supported}
      assert Schwab.get_rate_limit_status(@creds) == {:error, :not_supported}
    end
  end

  describe "the declaration and the code agree" do
    test "every endpoint declared :unsupported actually says so" do
      for {{name, arity}, :unsupported} <- Schwab.capabilities().endpoints do
        assert apply(Schwab, name, unsupported_args(name, arity)) == {:error, :not_supported},
               "#{name}/#{arity} is declared :unsupported but did not say so"
      end
    end

    test "venue_does_not_serve is reachable from the facade" do
      assert {:get_order_book, 2} in Schwab.venue_does_not_serve()
    end
  end

  describe "the supervision tree" do
    test "starts a limiter and a feed, like every other venue" do
      unique = System.unique_integer([:positive])

      opts = [
        name: :"sup_#{unique}",
        feed: :"sfeed_#{unique}",
        limiter: :"slim_#{unique}",
        symbols: [],
        start_delay_ms: 60_000
      ]

      assert {:ok, pid} = Schwab.start_link(opts)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)

      assert length(Elixir.Supervisor.which_children(pid)) == 2
    end

    test "names default and are overridable" do
      assert Supervisor.limiter_name([]) == DpExchange.Schwab.RateLimiter
      assert Supervisor.feed_name([]) == Feed
      assert Supervisor.limiter_name(limiter: :mine) == :mine
      assert Supervisor.feed_name(feed: :mine) == :mine
    end

    test "child_spec takes its id from the name" do
      assert %{id: :custom} = Schwab.child_spec(name: :custom)
      assert %{id: DpExchange.Schwab} = Schwab.child_spec([])
    end

    test "the ORDER ceiling has no default, because the venue has none" do
      # 0..120 per minute per account, set per application at registration. A number
      # baked into the package would be a claim about somebody else's registration.
      limits = Supervisor.limits([])
      assert limits.default.limit == Supervisor.default_read_limit()

      configured = Supervisor.limits(order_limit_per_minute: 20)
      assert configured.schwab_orders.limit == 20
    end

    test "a registration with zero order throughput is legal and does not divide by zero" do
      # Zero is a legal registration value. It is not `:unsupported` — the endpoint
      # exists, the app cannot use it — and the limiter must still start.
      limits = Supervisor.limits(order_limit_per_minute: 0)
      assert limits.schwab_orders.limit >= 1
    end
  end

  describe "the feed routes, and reports only what arrived" do
    setup do
      unique = System.unique_integer([:positive])
      name = :"feed_#{unique}"

      # No symbols and a long delay: this asserts routing, not fetching, and a fetch
      # would reach the venue.
      {:ok, feed} = Feed.start_link(name: name, symbols: [], start_delay_ms: 60_000)

      {:ok, feed: feed, name: name}
    end

    test "subscribe, unsubscribe and update_symbols all route", %{name: name} do
      assert :ok = Schwab.subscribe(["AAPL"], feed: name)
      assert :ok = Schwab.update_symbols(["AAPL", "MSFT"], feed: name)
      assert :ok = Schwab.unsubscribe(["MSFT"], feed: name)
    end

    test "coverage is empty until something actually arrives", %{name: name} do
      :ok = Schwab.subscribe(["AAPL"], feed: name)

      # Observed, never intended. On this venue that matters twice over: overnight,
      # nothing is arriving and nothing is wrong.
      assert Schwab.coverage(feed: name) == %{}
    end

    test "the poller exposes its own status", %{feed: feed} do
      assert %{delivering: _delivering} = Feed.status(feed)
      assert Feed.interval_ms() > 0
    end

    test "subscribe_notices always answers" do
      assert Schwab.subscribe_notices() == :ok
    end
  end

  describe "the facade without a started feed" do
    test "subscribing says so rather than silently doing nothing" do
      assert Schwab.subscribe(["AAPL"], feed: :no_such_feed) == {:error, :feed_not_started}
      assert Schwab.update_symbols(["AAPL"], feed: :no_such_feed) == {:error, :feed_not_started}
    end

    test "unsubscribing from nothing is :ok, and coverage is empty" do
      assert Schwab.unsubscribe(["AAPL"], feed: :no_such_feed) == :ok
      assert Schwab.coverage(feed: :no_such_feed) == %{}
    end
  end

  describe "the fake refuses what the real venue refuses" do
    test "market data needs credentials here too" do
      assert Fake.get_price("AAPL") == {:refused, :missing_credentials}
      assert Fake.get_symbols() == {:refused, :missing_credentials}
      assert Fake.market_status() == {:refused, :missing_credentials}
    end

    test "a quote is stamped with a fixed instant, so assertions do not flap" do
      assert {:ok, quote_struct} = Fake.get_price("AAPL", credentials: @creds)

      assert quote_struct.timestamp == Fake.as_of()
      assert Decimal.lt?(quote_struct.bid, quote_struct.ask)
      assert quote_struct.provider == :schwab
    end

    test "an unlisted symbol is refused and a pair never validates" do
      assert Fake.get_price("ZZZZ", credentials: @creds) == {:refused, :not_listed}

      assert {:error, {:not_an_equity_symbol, "BTC-USD"}} =
               Fake.get_price("BTC-USD", credentials: @creds)
    end

    test "the ten-day cap is reproduced, because that is the refusal that matters" do
      range = [start: DateTime.add(Fake.as_of(), -365, :day)]

      assert {:error, {:lookback_exceeds_venue, "1m", _days, 10}} =
               Fake.get_historical_prices("AAPL", "1m", range, credentials: @creds)
    end

    test "an unsupported width is refused" do
      assert {:error, {:unsupported_timeframe, "1h"}} =
               Fake.get_historical_prices("AAPL", "1h", [], credentials: @creds)
    end

    test "a reachable range returns a series" do
      range = [start: DateTime.add(Fake.as_of(), -3, :day)]

      assert {:ok, candles} =
               Fake.get_historical_prices("AAPL", "5m", range, credentials: @creds)

      assert length(candles) == 5
      assert Enum.all?(candles, &(&1.bid == nil))
    end

    test "the market can be closed, which is the only place that path is testable" do
      # Every other venue in the family is always open.
      assert Fake.market_status(credentials: @creds) == {:ok, :open}
      assert Fake.market_status(credentials: @creds, market_status: :closed) == {:ok, :closed}
    end

    test "a search needs a term here too, and matches by prefix" do
      assert Fake.get_symbols(credentials: @creds) == {:error, {:query_required, :schwab}}
      assert {:ok, ["AAPL", "AMZN"]} = Fake.get_symbols(credentials: @creds, query: "A")
    end

    test "an order the venue publishes as invalid is refused by the fake too" do
      # A fake that accepted it would green-light code that cannot work.
      request = %{symbol: "AAPL", instruction: "BUY_TO_OPEN", quantity: 1}

      assert {:error, {:instruction_not_valid_for_asset, "BUY_TO_OPEN", "EQUITY"}} =
               Fake.place_order(@creds, request, account_hash: "H")
    end

    test "a valid order is accepted, and the account hash is still required" do
      request = %{symbol: "AAPL", side: :buy, quantity: 1}

      assert {:ok, "fake-order-1"} = Fake.place_order(@creds, request, account_hash: "H")

      assert Fake.place_order(@creds, request, []) ==
               {:error, {:missing_account_hash, :schwab}}
    end

    test "accounts, balances, orders and connection all answer" do
      assert {:ok, [%{hash: "FAKEHASH"}]} = Fake.get_accounts(@creds)
      assert {:ok, [balance]} = Fake.get_balances(@creds, account_hash: "H")
      assert balance.currency == "USD"
      assert :ok = Fake.cancel_order(@creds, "1", account_hash: "H")
      assert {:ok, %{"orderId" => "1"}} = Fake.get_order(@creds, "1", account_hash: "H")
      assert {:ok, []} = Fake.get_orders(@creds, account_hash: "H")
      assert {:ok, %{accounts: 1}} = Fake.test_connection(@creds)
    end

    test "subscribing pushes quotes and reports :internal_poll, never :stream" do
      :ok = Fake.subscribe(["AAPL", "MSFT"], to: self())

      assert Fake.coverage() == %{"AAPL" => :internal_poll, "MSFT" => :internal_poll}
      assert_receive {:dp_exchange, :schwab, %DpExchange.Core.Types.Quote{symbol: "AAPL"}}

      :ok = Fake.unsubscribe(["MSFT"])
      assert Fake.coverage() == %{"AAPL" => :internal_poll}

      :ok = Fake.update_symbols(["MSFT"])
      assert Fake.coverage() == %{"MSFT" => :internal_poll}
    end

    test "an unlisted symbol is not covered and pushes nothing" do
      :ok = Fake.update_symbols([])
      :ok = Fake.subscribe(["ZZZZ"], to: self())

      assert Fake.coverage() == %{}
      refute_receive {:dp_exchange, :schwab, _anything}, 50
    end

    test "the short arities answer too — a default nothing calls is dead code" do
      # Each of these is the arity-N-1 head the behaviour's default arguments generate.
      # They are real public API a consumer can reach, and an untested default is a
      # clause nobody has checked.
      assert Fake.get_balances(@creds) == {:error, {:missing_account_hash, :schwab}}
      assert Fake.get_orders(@creds) == {:error, {:missing_account_hash, :schwab}}
      assert Fake.get_order(@creds, "1") == {:error, {:missing_account_hash, :schwab}}
      assert Fake.cancel_order(@creds, "1") == {:error, {:missing_account_hash, :schwab}}

      assert Fake.place_order(@creds, %{symbol: "AAPL", side: :buy, quantity: 1}) ==
               {:error, {:missing_account_hash, :schwab}}

      assert Fake.get_historical_prices("AAPL", "1d", []) ==
               {:refused, :missing_credentials}

      assert "AAPL" in Fake.listed()
      assert :ok = Fake.subscribe([])
      assert :ok = Fake.unsubscribe([])
      assert :ok = Fake.update_symbols([])
      assert Fake.coverage() == %{}
    end

    test "it declares the real venue's capabilities and starts nothing" do
      assert Fake.capabilities() == Schwab.capabilities()
      assert Fake.start_link([]) == :ignore
      assert %{id: :fake} = Fake.child_spec(name: :fake)
      assert Fake.provider_name() == "Schwab"
      assert Fake.runtime_id() == :schwab
      assert Fake.asset_classes() == [:equity]
      assert Fake.quotes() == ["USD"]
      assert Fake.subscribe_notices() == :ok
      assert Fake.venue_does_not_serve() == Schwab.venue_does_not_serve()
    end

    test "everything the venue does not serve says so" do
      assert Fake.get_order_book("AAPL") == {:error, :not_supported}
      assert Fake.get_market_overview() == {:error, :not_supported}
      assert Fake.list_instruments() == {:error, :not_supported}
      assert Fake.quantization("AAPL") == {:error, :not_supported}
      assert Fake.get_fees(@creds) == {:error, :not_supported}
      assert Fake.get_transfers(@creds) == {:error, :not_supported}
      assert Fake.get_trade_history(@creds) == {:error, :not_supported}
      assert Fake.get_rate_limit_status(@creds) == {:error, :not_supported}
    end
  end

  defp unsupported_args(name, arity) do
    case {name, arity} do
      {:quantization, 1} -> ["AAPL"]
      {:get_historical_prices, 4} -> ["AAPL", "1d", [], []]
      {:get_order_book, 2} -> ["AAPL", []]
      {:place_order, 3} -> [@creds, %{}, []]
      {_name, 3} -> [@creds, "id", []]
      {_name, 2} -> [@creds, []]
      {_name, 1} -> [[]]
    end
  end
end
