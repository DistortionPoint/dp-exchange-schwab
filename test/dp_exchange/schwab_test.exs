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

  alias DpExchange.Core.{Capabilities, Config, Notice}
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

    test "the FAKE says the same thing, for every declared-unsupported endpoint" do
      # The facade sweep above proves the real module agrees with its declaration. This
      # proves the fake does too — and it matters more than it looks: a consumer's test
      # suite runs against the fake, so a fake that answered differently would let a
      # consumer write a passing test against behaviour the real package does not have.
      #
      # It also keeps the stubs honest. Thirty-three callbacks arrived with Core 0.1.16 and
      # are declared, not implemented; without this they are uncovered lines that nothing
      # would notice going wrong.
      for {{name, arity}, :unsupported} <- Schwab.capabilities().endpoints do
        assert apply(Schwab.Fake, name, unsupported_args(name, arity)) ==
                 {:error, :not_supported},
               "#{name}/#{arity} is declared :unsupported but the fake did not say so"
      end
    end

    test "venue_does_not_serve is reachable from the facade" do
      assert {:get_order_book, 2} in Schwab.venue_does_not_serve()
    end
  end

  describe "the supervision tree" do
    test "starts a limiter, an order-ceiling record and a feed" do
      unique = System.unique_integer([:positive])

      opts = [
        name: :"sup_#{unique}",
        feed: :"sfeed_#{unique}",
        limiter: :"slim_#{unique}",
        order_limit: :"solim_#{unique}",
        symbols: [],
        start_delay_ms: 60_000
      ]

      assert {:ok, pid} = Schwab.start_link(opts)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)

      # One more than every other venue in the family — `OrderLimit`, the record of
      # whether `:order_limit_per_minute` was ever stated. See `Supervisor`'s moduledoc.
      assert length(Elixir.Supervisor.which_children(pid)) == 3
    end

    test "names default and are overridable" do
      assert Supervisor.limiter_name([]) == DpExchange.Schwab.RateLimiter
      assert Supervisor.feed_name([]) == Feed
      assert Supervisor.order_limit_name([]) == DpExchange.Schwab.OrderLimit
      assert Supervisor.limiter_name(limiter: :mine) == :mine
      assert Supervisor.feed_name(feed: :mine) == :mine
      assert Supervisor.order_limit_name(order_limit: :mine) == :mine
    end

    test "child_spec takes its id from the name" do
      assert %{id: :custom} = Schwab.child_spec(name: :custom)
      assert %{id: DpExchange.Schwab} = Schwab.child_spec([])
    end

    test "the order ceiling defaults to zero, never to the read ceiling" do
      # 0..120 per minute per account, set per application at registration. A number
      # baked into the package would be a claim about somebody else's registration — and
      # until a documentation-accuracy sweep (2026-09-06) found it, omitting the option
      # silently defaulted `schwab_orders.limit` to `reads` (120, the TOP of Schwab's own
      # range): the worst possible guess, because it is the one most likely to let a
      # consumer write orders past a registration it does not hold. The read ceiling is
      # this package's own courtesy self-protection, not a venue fact — asserted by
      # value, since a host has no reason to ask this package what it is.
      limits = Supervisor.limits([])
      assert limits.default.limit == 120

      # Omitting the option now reads identically to registering explicit zero — this
      # package assumes no order throughput at all until a host states its own ceiling.
      assert limits.schwab_orders == Supervisor.limits(order_limit_per_minute: 0).schwab_orders

      configured = Supervisor.limits(order_limit_per_minute: 20)
      assert configured.schwab_orders.limit == 20
    end

    test "a registration with zero order throughput is legal and does not divide by zero" do
      # Zero is a legal registration value. It is not `:unsupported` — the endpoint
      # exists, the app cannot use it — and the limiter must still start. `max(orders, 1)`
      # is a floor on the GCRA arithmetic (it divides by the rate), not a claim that a
      # zero-registered host may actually place one order a minute — `capabilities/0` is
      # where the real ceiling is said.
      limits = Supervisor.limits(order_limit_per_minute: 0)
      assert limits.schwab_orders.limit >= 1
    end

    # An explicit `nil` is what a consumer forwarding `Application.get_env/2` produces when
    # nothing was configured. `Keyword.has_key?/2` answers `true` for it and
    # `Keyword.get/3` returns the `nil` rather than the default, so the old code read it as
    # "the host stated a registration" AND carried `limit: nil` into the limiter's
    # arithmetic. `Core.Config.opt/3` treats present-and-nil as absent, which is the whole
    # reason it exists.
    test "an explicit nil ceiling reads as silence, not as a registration" do
      assert Supervisor.limits(order_limit_per_minute: nil).schwab_orders ==
               Supervisor.limits([]).schwab_orders

      assert Supervisor.limits(read_limit_per_minute: nil).default ==
               Supervisor.limits([]).default
    end

    # Fails at start rather than deep inside the limiter's GCRA arithmetic, where the
    # message names neither the option nor the caller that set it.
    test "a ceiling that is not a non-negative integer is refused at start" do
      assert_raise ArgumentError, ~r/order_limit_per_minute must be a non-negative integer/, fn ->
        Supervisor.init(order_limit_per_minute: -1)
      end

      assert_raise ArgumentError, ~r/read_limit_per_minute must be a non-negative integer/, fn ->
        Supervisor.init(read_limit_per_minute: "120")
      end
    end
  end

  describe "place_order/3, replace_order/4, cancel_order/3 — the order-write gate" do
    # A consumer who omitted `:order_limit_per_minute` used to reach the venue at the
    # (wrongly optimistic) read ceiling; then it was fixed to reach a starved limiter and
    # come back looking exactly like the venue itself was throttling — `{:rate_limited,
    # _}` or a silent block under `rate_limit_blocking: true`, a plausible value with the
    # wrong meaning. These prove the actual, reviewed fix: a distinct refusal, raised
    # before any HTTP call, that only fires for a tree that was told nothing.
    #
    # `PermissiveLimiter` is defined once, below, in "refresh_credentials/2". Elixir's
    # nested-module alias is lexically scoped to that `describe` block, not this whole
    # file, so it is named in full here rather than redefined.
    setup do
      Config.put_override(:rate_limit_module, __MODULE__.PermissiveLimiter)
      :ok
    end

    @order_request %{symbol: "AAPL", side: :buy, quantity: 1}

    defp placed_ok_plug do
      fn conn ->
        conn |> Plug.Conn.put_resp_header("location", "/orders/7") |> Plug.Conn.resp(201, "")
      end
    end

    defp start_order_tree(extra_opts) do
      unique = System.unique_integer([:positive])

      opts =
        [
          name: :"sup_#{unique}",
          feed: :"sfeed_#{unique}",
          limiter: :"slim_#{unique}",
          order_limit: :"solim_#{unique}",
          symbols: [],
          start_delay_ms: 60_000
        ] ++ extra_opts

      {:ok, pid} = Schwab.start_link(opts)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)

      [account_hash: "H", order_limit: :"solim_#{unique}"]
    end

    test "a tree started without :order_limit_per_minute refuses all three, before the venue is ever reached" do
      base = start_order_tree([])
      exploding = fn _conn -> raise "an order write should never have reached the venue" end
      call_opts = base ++ [plug: exploding, retry_attempts: 0]

      assert Schwab.place_order(@creds, @order_request, call_opts) ==
               {:error, :order_limit_not_declared}

      assert Schwab.replace_order(@creds, "1", @order_request, call_opts) ==
               {:error, :order_limit_not_declared}

      assert Schwab.cancel_order(@creds, "1", call_opts) == {:error, :order_limit_not_declared}
    end

    test "a tree started WITH :order_limit_per_minute lets every one of the three reach the venue" do
      base = start_order_tree(order_limit_per_minute: 20)
      call_opts = base ++ [plug: placed_ok_plug(), retry_attempts: 0]

      assert {:ok, "7"} = Schwab.place_order(@creds, @order_request, call_opts)
      assert {:ok, "7"} = Schwab.replace_order(@creds, "1", @order_request, call_opts)

      assert :ok =
               Schwab.cancel_order(@creds, "1",
                 account_hash: "H",
                 order_limit: base[:order_limit],
                 plug: fn c -> Plug.Conn.resp(c, 200, "") end,
                 retry_attempts: 0
               )
    end

    test "an EXPLICIT zero also reaches the venue path — it is a stated ceiling, not silence" do
      # Distinct from the undeclared case on purpose: `0` said on purpose is this
      # consumer's own answer, and `PermissiveLimiter` here stands in for the real
      # limiter that would then throttle it for real — `Supervisor.limits/1`'s own tests
      # cover that arithmetic. This test only proves the GATE does not confuse the two.
      base = start_order_tree(order_limit_per_minute: 0)
      call_opts = base ++ [plug: placed_ok_plug(), retry_attempts: 0]

      assert {:ok, "7"} = Schwab.place_order(@creds, @order_request, call_opts)
    end

    test "preview_order/3 is never gated — it is not a throttled order write on this venue" do
      base = start_order_tree([])

      body = %{
        "orderStrategy" => %{"orderType" => "MARKET"},
        "orderValidationResult" => %{"rejects" => []},
        "commissionAndFee" => %{"commission" => %{}}
      }

      plug = fn conn -> Req.Test.json(conn, body) end
      call_opts = base ++ [plug: plug, retry_attempts: 0]

      assert {:ok, _preview} = Schwab.preview_order(@creds, @order_request, call_opts)
    end

    test "a consumer who never supervises this module at all is unaffected — no tree, no new refusal" do
      # Matches the existing "no account hash" refusal's own calling convention: a bare
      # facade call with no supervision tree behind it, which this package has always
      # allowed by letting a caller supply its own `:limiter`.
      assert {:ok, "7"} =
               Schwab.place_order(@creds, @order_request,
                 account_hash: "H",
                 plug: placed_ok_plug(),
                 retry_attempts: 0
               )
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

    test "coverage_by_kind reports :quotes with nothing in it until something actually arrives",
         %{name: name} do
      :ok = Schwab.subscribe(["AAPL"], feed: name)

      # This feed has no plug configured, so `/userPreference` cannot reach a real Streamer
      # bootstrap and the feed lands on the poll route — which reports `%{quotes: ...}`
      # unconditionally, per `Feed.coverage_by_kind/1`'s own contract for that route, even
      # before the poller's `start_delay_ms: 60_000` lets anything through.
      assert Schwab.coverage_by_kind(feed: name) == %{quotes: %{}}
    end

    test "the poller exposes its own status", %{feed: feed} do
      assert %{delivering: _delivering} = Feed.status(feed)
    end

    test "status/1 delegates to the named feed, and is empty when no feed is running",
         %{name: name} do
      assert %{delivering: _delivering, route: _route} = Schwab.status(feed: name)
      assert Schwab.status(feed: :no_such_feed) == %{}
    end

    test "wanted/1 is what was asked for, not what coverage/1 reports", %{name: name} do
      :ok = Schwab.subscribe(["AAPL", "MSFT"], feed: name)

      # Nothing has delivered yet — coverage/1 is empty while wanted/1 already carries
      # both symbols, which is the entire reason the two are separate functions.
      assert Enum.sort(Schwab.wanted(feed: name)) == ["AAPL", "MSFT"]
      assert Schwab.coverage(feed: name) == %{}
      assert Schwab.wanted(feed: :no_such_feed) == []
    end

    test "subscribe_notices registers with the named feed, not the default one", %{name: name} do
      assert Schwab.subscribe_notices(feed: name) == :ok
    end
  end

  describe "the facade without a started feed" do
    test "subscribing says so rather than silently doing nothing" do
      assert Schwab.subscribe(["AAPL"], feed: :no_such_feed) == {:error, :feed_not_started}
      assert Schwab.update_symbols(["AAPL"], feed: :no_such_feed) == {:error, :feed_not_started}
    end

    test "subscribe_notices says so too, rather than answering :ok for a registration nothing will ever fire" do
      assert Schwab.subscribe_notices(feed: :no_such_feed) == {:error, :feed_not_started}
    end

    test "update_credentials says so too, rather than answering :ok with nothing to update" do
      assert Schwab.update_credentials(@creds, feed: :no_such_feed) ==
               {:error, :feed_not_started}
    end

    test "unsubscribing from nothing is :ok, and coverage is empty" do
      assert Schwab.unsubscribe(["AAPL"], feed: :no_such_feed) == :ok
      assert Schwab.coverage(feed: :no_such_feed) == %{}
      assert Schwab.coverage_by_kind(feed: :no_such_feed) == %{}
    end
  end

  describe "subscribe_notices/1 actually wires to the feed's notice registry" do
    # This was a no-op that discarded `opts[:to]` and answered `:ok` unconditionally,
    # while `Feed`'s notice registry — `subscribe_notices/2`, the `notice_subscribers`
    # set, and `fan_out/2` — sat right beside it, complete and reachable only by calling
    # `Feed` directly. Proven broken empirically before the fix: registering here with
    # `to: self()`, driving a real notice, and receiving nothing.
    #
    # So this registers through the FACADE, never through `Feed` directly, and drives a
    # notice the same way `FeedTest`'s own "fallback poll's own silent-delivery notice"
    # tests do — no credentials means `Auth.headers/2` refuses before any HTTP call is
    # even attempted, so no plug or fake venue is needed to fail the bootstrap and then
    # every poll attempt.
    test "a subscriber registered through the facade receives the fallback poll's coverage_change notice" do
      unique = System.unique_integer([:positive])
      name = :"notice_regression_feed_#{unique}"

      {:ok, feed} =
        Feed.start_link(
          name: name,
          symbols: ["AAPL"],
          interval_ms: 50,
          # Headroom before the poller's first tick, so the facade call below is
          # guaranteed to land before the fallback poll's own first attempt — the
          # poller runs on its own timer, not on a message this test controls.
          start_delay_ms: 150,
          retry_attempts: 0
        )

      on_exit(fn -> if Process.alive?(feed), do: GenServer.stop(feed, :normal) end)

      assert Schwab.subscribe_notices(feed: name, to: self()) == :ok

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :coverage_change} = notice}, 3_000
      assert notice.severity == :warning
      assert notice.provider == "schwab-fallback-poll"
    end
  end

  describe "update_credentials/2 actually wires into a running feed's live socket" do
    # `Feed.update_credentials/2` and `Socket.update_access_token/2` are the two halves
    # `FeedTest`'s own "update_credentials/2" describe block already proves reach each
    # other; this proves the third — that the FACADE reaches `Feed`, the same gap
    # `subscribe_notices/1` had above before it was wired. `WebSockex.cast/2` wraps its
    # payload as `{:"$websockex_cast", message}` — that shape is what a socket relaying
    # its raw mailbox receives.
    test "a refreshed access token reaches the live socket through the facade alone" do
      unique = System.unique_integer([:positive])
      name = :"update_credentials_regression_feed_#{unique}"
      parent = self()

      socket =
        spawn(fn ->
          Stream.repeatedly(fn ->
            receive do
              message -> send(parent, {:relayed_to_socket, message})
            end
          end)
          |> Stream.run()
        end)

      on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)

      {:ok, feed} =
        Feed.start_link(
          name: name,
          socket: socket,
          credentials: @creds,
          symbols: ["AAPL"],
          start_delay_ms: 60_000
        )

      on_exit(fn -> if Process.alive?(feed), do: GenServer.stop(feed, :normal) end)

      new_credentials = Map.put(@creds, :access_token, "fresh-token")
      assert Schwab.update_credentials(new_credentials, feed: name) == :ok

      assert_receive {:relayed_to_socket,
                      {:"$websockex_cast", {:update_access_token, "fresh-token"}}},
                     2_000
    end
  end

  describe "refresh_credentials/2 — Auth.refresh/2 reachable through the facade" do
    # `Auth.refresh/2` was previously reachable only by calling the internal `Auth`
    # module directly — reaching past the facade, which this package's own CLAUDE.md
    # names as a gap in the facade to fix, not a workaround to document. This proves the
    # facade function actually delegates, both ways `Auth.refresh/2` can answer.
    @refresh_creds %{
      access_token: "at-1",
      refresh_token: "rt-1",
      client_id: "cid",
      client_secret: "csec"
    }

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

    defp responding(body, status \\ 200) do
      fn conn -> Req.Test.json(%{conn | status: status}, body) end
    end

    test "the happy path returns the rotated credential, exactly as Auth.refresh/2 does" do
      body = %{"access_token" => "at-2", "refresh_token" => "rt-2", "expires_in" => 1_800}

      assert {:ok, renewed} =
               Schwab.refresh_credentials(@refresh_creds,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert renewed.access_token == "at-2"
      assert renewed.refresh_token == "rt-2"
    end

    test "a terminal refusal passes through unchanged" do
      body = %{"error" => "invalid_grant", "error_description" => "refresh token invalid"}

      assert {:refused, {:reauthorization_required, 400, "refresh token invalid"}} =
               Schwab.refresh_credentials(@refresh_creds,
                 plug: responding(body, 400),
                 retry_attempts: 0
               )
    end
  end

  describe "needs_refresh?/2 — the other half of refresh_credentials/2, reachable through the facade" do
    # `Auth.needs_refresh?/2` was previously reachable only by calling the internal
    # `Auth` module directly. This proves the facade delegates, exactly as it does for
    # `refresh_credentials/2` above.
    test "true once the access token is close to expiry, and when nobody said" do
      now = ~U[2026-08-31 12:00:00Z]

      assert Schwab.needs_refresh?(%{expires_at: DateTime.add(now, 60, :second)}, now)
      refute Schwab.needs_refresh?(%{expires_at: DateTime.add(now, 1_700, :second)}, now)
      refute Schwab.needs_refresh?(%{access_token: "at-1"}, now)
    end

    test "defaults `now` to the current time" do
      refute Schwab.needs_refresh?(%{access_token: "at-1"})
    end
  end

  describe "credential_failure?/1 — reachable through the facade" do
    # `Auth.credential_failure?/1` was previously reachable only by calling the internal
    # `Auth` module directly.
    test "401 and 403 are credential failures; other statuses are not" do
      assert Schwab.credential_failure?(401)
      assert Schwab.credential_failure?(403)
      refute Schwab.credential_failure?(400)
      refute Schwab.credential_failure?(429)
      refute Schwab.credential_failure?(500)
    end
  end

  describe "equity_instructions/0 and option_instructions/0 — reachable through the facade" do
    # Both previously reachable only by calling the internal `Orders` module directly.
    test "the two lists are exactly what the venue publishes, and do not overlap" do
      assert Schwab.equity_instructions() == ~w(BUY SELL BUY_TO_COVER SELL_SHORT)

      assert Schwab.option_instructions() ==
               ~w(BUY_TO_OPEN BUY_TO_CLOSE SELL_TO_OPEN SELL_TO_CLOSE)

      assert Schwab.equity_instructions() -- Schwab.option_instructions() ==
               Schwab.equity_instructions()
    end
  end

  describe "the fake refuses what the real venue refuses" do
    test "market data needs credentials here too" do
      assert Fake.get_price("AAPL") == {:error, {:missing_credentials, :schwab}}
      assert Fake.get_symbols() == {:error, {:missing_credentials, :schwab}}
      assert Fake.market_status() == {:error, {:missing_credentials, :schwab}}
    end

    test "a quote is stamped with a fixed instant, so assertions do not flap" do
      assert {:ok, quote_struct} = Fake.get_price("AAPL", credentials: @creds)

      assert quote_struct.timestamp == Fake.as_of()
      # The book moved to TopOfBook; the fake exposes it through get_top_of_book/2.
      assert {:ok, top} = Fake.get_top_of_book("AAPL", credentials: @creds)
      assert Decimal.lt?(top.bid, top.ask)
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
      # Bars carry four prices now, not one. A fake whose OHLC all matched could not catch
      # a caller reading the wrong one.
      assert Enum.all?(candles, &Decimal.lt?(&1.low, &1.high))
      assert Enum.all?(candles, & &1.opened_at)
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

    test "coverage_by_kind reports :quotes only, and its union matches coverage/1" do
      :ok = Fake.subscribe(["AAPL", "MSFT"], to: self())

      by_kind = Fake.coverage_by_kind()

      assert by_kind == %{quotes: %{"AAPL" => :internal_poll, "MSFT" => :internal_poll}}
      refute Map.has_key?(by_kind, :order_book)

      union = by_kind |> Map.values() |> Enum.flat_map(&Map.keys/1) |> Enum.sort()
      assert union == Fake.coverage() |> Map.keys() |> Enum.sort()

      declared = MapSet.new(Fake.capabilities().streamable)
      assert by_kind |> Map.keys() |> MapSet.new() |> MapSet.subset?(declared)
    end

    test "an unlisted symbol is not covered and pushes nothing" do
      :ok = Fake.update_symbols([])
      :ok = Fake.subscribe(["ZZZZ"], to: self())

      assert Fake.coverage() == %{}
      assert Fake.coverage_by_kind() == %{quotes: %{}}
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
               {:error, {:missing_credentials, :schwab}}

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

  # Argument shapes for the declared-unsupported sweep. A lookup rather than a case, so a
  # callback added to the facade adds a row instead of a branch.
  @wide_facade_args %{
    {:withdraw, 5} => ["AAPL", "bitcoin", :one, "addr", []],
    {:estimate_withdrawal_fee, 4} => ["AAPL", "bitcoin", :one, []],
    {:quote_conversion, 4} => ["AAPL", "USD", :one, []],
    {:get_deposit_address, 3} => ["AAPL", "bitcoin", []],
    {:create_watchlist, 3} => ["name", [], []],
    {:get_financials, 3} => ["AAPL", :balance_sheet, []],
    {:rename_account, 3} => ["id", "name", []],
    {:stake, 3} => ["AAPL", :one, []],
    {:unstake, 3} => ["AAPL", :one, []],
    {:get_funding, 2} => ["AAPL", []],
    {:get_contract_stats, 2} => ["AAPL", []],
    {:get_option_chain, 2} => ["AAPL", []],
    {:get_option_expirations, 2} => ["AAPL", []],
    {:get_option_greeks, 2} => ["id", []],
    {:get_watchlist, 2} => ["id", []],
    {:update_watchlist, 2} => ["id", []],
    {:delete_watchlist, 2} => ["id", []],
    {:get_filings, 2} => ["id", []],
    {:get_screener, 2} => ["id", []],
    {:commit_conversion, 2} => ["id", []],
    {:get_conversion, 2} => ["id", []],
    {:get_top_of_book, 2} => ["AAPL", []]
  }

  defp unsupported_args(name, arity) do
    case Map.fetch(@wide_facade_args, {name, arity}) do
      {:ok, args} ->
        Enum.map(args, fn
          :one -> Decimal.new("1")
          other -> other
        end)

      :error ->
        legacy_args(name, arity)
    end
  end

  defp legacy_args(name, arity) do
    case {name, arity} do
      {:quantization, 1} -> ["AAPL"]
      {:get_historical_prices, 4} -> ["AAPL", "1d", [], []]
      {:get_order_book, 2} -> ["AAPL", []]
      {:place_order, 3} -> [@creds, %{}, []]
      # Every other arity-4 callback takes credentials, an id, a change map and opts.
      {_name, 4} -> [@creds, "id", %{}, []]
      {_name, 3} -> [@creds, "id", []]
      {_name, 2} -> [@creds, []]
      {_name, 1} -> [[]]
    end
  end
end
