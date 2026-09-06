defmodule DpExchange.Schwab.FeedTest do
  @moduledoc """
  The feed's routing decision, and the two things a consumer can observe about it.

  ## What is actually being tested here

  This venue's feed has two routes — the Streamer, and a REST poll when the Streamer cannot
  be bootstrapped — and **the whole risk lives in which one a consumer is told it got.**
  A feed that fell back to polling and reported `:stream` would be the family's signature
  defect: a plausible value with the wrong meaning, invisible until somebody wondered why
  no depth ever arrived.

  So the assertions are about the seam, not the transport: `coverage/1` names the route it
  actually used, a bootstrap failure emits `:degraded` rather than failing silently, and the
  wanted set survives a subscription that has not delivered yet.

  ## Why `:socket` can be injected

  A pid passed as `:socket` skips the bootstrap. That is not a test-only hole in the design
  — `Feed` needs it on reconnect — and it is what lets the socket-bearing branches run
  without a WebSocket server. Where a test needs the *bootstrap* path, it drives the real
  one through a `plug`.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, DefaultRateLimiter, Notice, Types}
  alias DpExchange.Schwab.Feed

  @moduletag :capture_log

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

  @credentials %{
    access_token: "token-abc",
    refresh_token: "r",
    client_id: "c",
    client_secret: "s"
  }

  @user_preference %{
    "streamerInfo" => [
      %{
        "streamerSocketUrl" => "wss://streamer-api.schwab.com/ws",
        "schwabClientCustomerId" => "cust-1",
        "schwabClientCorrelId" => "corr-1",
        "schwabClientChannel" => "IO",
        "schwabClientFunctionId" => "APIAPP"
      }
    ]
  }

  defp responding(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  # A stand-in for the socket process. It is a real process so `is_pid/1` and the liveness
  # checks behave, and it never speaks — the feed's socket-side behaviour under test is what
  # it *sends*, not what comes back.
  defp fake_socket do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp start_feed(opts) do
    {:ok, feed} =
      Feed.start_link(
        Keyword.merge([name: nil, credentials: @credentials, subscriber: self()], opts)
      )

    on_exit(fn -> if Process.alive?(feed), do: GenServer.stop(feed, :normal) end)
    feed
  end

  describe "the route a consumer actually got" do
    test "an injected socket streams, and coverage says so only once something arrives" do
      feed = start_feed(socket: fake_socket())

      # Nothing has been delivered yet. Reporting the subscribed symbol as covered here is
      # exactly the claim `coverage/1` exists to refuse.
      assert Feed.subscribe(feed, ["AAPL"]) == :ok
      assert Feed.coverage(feed) == %{}

      send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      assert_receive {:dp_exchange, :schwab, %Types.Quote{}}, 2_000

      assert Feed.coverage(feed) == %{"AAPL" => :stream}
      assert %{route: :stream} = Feed.status(feed)
    end

    test "a bootstrap that fails falls back to the poll and SAYS so" do
      # `/userPreference` refuses. The feed cannot stream, and a consumer that is not told
      # would spend the session wondering where depth went.
      feed = start_feed(plug: responding(%{"error" => "unauthorized"}, 401), retry_attempts: 0)

      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :degraded, details: %{fallback: :internal_poll}}},
                     2_000

      assert %{route: :internal_poll} = Feed.status(feed)
    end

    test "a response without streamerInfo is a bootstrap failure, not an empty stream" do
      # 200, valid JSON, and no socket in it. This is the shape that would produce a feed
      # that connects to nothing while every status looks healthy.
      feed = start_feed(plug: responding(%{"accounts" => []}), retry_attempts: 0)

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded, details: details}}, 2_000
      assert details.reason =~ "no_streamer_info"
      assert %{route: :internal_poll} = Feed.status(feed)
    end

    test "credentials with no access token cannot bootstrap even when the call succeeds" do
      _feed =
        start_feed(
          credentials: %{},
          plug: responding(@user_preference),
          retry_attempts: 0
        )

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded, details: details}}, 2_000
      assert details.reason =~ "missing_credentials"
    end
  end

  describe "the wanted set is not the covered set" do
    test "a second subscribe does not drop a symbol that has not delivered yet" do
      # The bug this replaces: `subscribe/2` read the current set out of `coverage/1` and
      # re-sent the union. A symbol subscribed and not yet quoted is absent from coverage,
      # so the next subscribe silently unsubscribed it.
      feed = start_feed(socket: fake_socket())

      Feed.subscribe(feed, ["AAPL"])
      Feed.subscribe(feed, ["MSFT"])

      assert feed |> Feed.wanted() |> Enum.sort() == ["AAPL", "MSFT"]
    end

    test "unsubscribe removes from wanted and from coverage" do
      feed = start_feed(socket: fake_socket())

      Feed.subscribe(feed, ["AAPL", "MSFT"])
      send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      assert_receive {:dp_exchange, :schwab, %Types.Quote{}}, 2_000

      assert Feed.unsubscribe(feed, ["AAPL"]) == :ok
      assert Feed.wanted(feed) == ["MSFT"]
      assert Feed.coverage(feed) == %{}
    end

    test "update_symbols replaces rather than accumulating" do
      feed = start_feed(socket: fake_socket())

      Feed.subscribe(feed, ["AAPL"])
      assert Feed.update_symbols(feed, ["MSFT"]) == :ok
      assert Feed.wanted(feed) == ["MSFT"]
    end
  end

  describe "what reaches a subscriber" do
    test "a refusal reaches the subscriber and is not counted as coverage" do
      feed = start_feed(socket: fake_socket())
      Feed.subscribe(feed, ["AAPL"])

      send(feed, {:dp_exchange, :schwab, {:refused, "AAPL", :delisted}})

      assert_receive {:dp_exchange, :schwab, {:refused, "AAPL", :delisted}}, 2_000
      assert Feed.coverage(feed) == %{}
    end

    test "notices reach a notice subscriber without the data channel" do
      feed = start_feed(socket: fake_socket())
      parent = self()
      watcher = spawn(fn -> relay(parent) end)

      assert Feed.subscribe_notices(feed, to: watcher) == :ok
      send(feed, {:dp_exchange, :schwab, Notice.new(:link_up, :schwab)})

      assert_receive {:relayed, {:dp_exchange, :schwab, %Notice{kind: :link_up}}}, 2_000
    end

    test "a value with no symbol is delivered and does not enter coverage" do
      # `ACCT_ACTIVITY` and anything else without a symbol still reaches the subscriber.
      # Coverage is per symbol, so there is nothing to record — and inventing a key for it
      # would report a symbol nobody subscribed to.
      feed = start_feed(socket: fake_socket())

      send(feed, {:dp_exchange, :schwab, %{account: "123", event: "OrderFill"}})

      assert_receive {:dp_exchange, :schwab, %{event: "OrderFill"}}, 2_000
      assert Feed.coverage(feed) == %{}
    end

    test "an unrecognised message is ignored rather than crashing the feed" do
      feed = start_feed(socket: fake_socket())
      send(feed, :something_else)
      assert Feed.wanted(feed) == []
    end

    test "an unknown call is refused rather than raising" do
      feed = start_feed(socket: fake_socket())
      assert GenServer.call(feed, :nonsense) == {:error, :unknown_call}
    end

    test "a subscriber registered by name (not a raw pid) is delivered to rather than crashing the feed" do
      # Filed as a live bug on the sibling Coinbase package: Process.alive?/1 only
      # accepts a pid and raises on anything else, so a consumer that registers itself
      # under a name and hands that name to `to:` — ordinary OTP practice — crashed the
      # whole feed on the very first delivery.
      name = :"schwab_feed_test_subscriber_#{System.unique_integer([:positive])}"
      Process.register(self(), name)
      feed = start_feed(socket: fake_socket())

      Feed.subscribe(feed, ["AAPL"], to: name)
      send(feed, {:dp_exchange, :schwab, %{account: "123", event: "OrderFill"}})

      assert_receive {:dp_exchange, :schwab, %{event: "OrderFill"}}, 2_000
      assert Process.alive?(feed)

      Process.unregister(name)
    end

    test "a name that is not (or no longer) registered is silently skipped, not a crash" do
      name = :"schwab_feed_test_unregistered_#{System.unique_integer([:positive])}"
      refute Process.whereis(name)
      feed = start_feed(socket: fake_socket())

      Feed.subscribe(feed, ["AAPL"], to: name)
      send(feed, {:dp_exchange, :schwab, %{account: "123", event: "OrderFill"}})
      Process.sleep(20)

      assert Process.alive?(feed)
    end
  end

  describe "update_credentials/2 — a refreshed token reaches a live socket" do
    # A stand-in that relays every raw message it receives back to the test process,
    # rather than `fake_socket/0`'s silent sleep — this is the one test that needs to see
    # *what* `Feed` sent, not merely that the feed did not crash. `WebSockex.cast/2` wraps
    # its payload as `{:"$websockex_cast", message}` (`deps/websockex/lib/websockex.ex`),
    # which is the exact shape asserted below.
    defp relaying_fake_socket(parent) do
      pid =
        spawn(fn ->
          Stream.repeatedly(fn ->
            receive do
              message -> send(parent, {:relayed_to_socket, message})
            end
          end)
          |> Stream.run()
        end)

      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      pid
    end

    test "the new access token is cast to the live socket on the stream route" do
      socket = relaying_fake_socket(self())
      feed = start_feed(socket: socket)
      Feed.subscribe(feed, ["AAPL"])

      new_credentials = Map.put(@credentials, :access_token, "fresh-token")
      assert Feed.update_credentials(feed, new_credentials) == :ok

      assert_receive {:relayed_to_socket,
                      {:"$websockex_cast", {:update_access_token, "fresh-token"}}},
                     2_000
    end

    test "a route with no live socket (the poll route) is not sent anything, and does not crash" do
      feed =
        start_feed(
          plug: fn conn ->
            if String.contains?(conn.request_path, "userPreference") do
              Plug.Conn.resp(conn, 401, "no")
            else
              Req.Test.json(conn, quote_body())
            end
          end,
          retry_attempts: 0,
          interval_ms: 60_000,
          start_delay_ms: 60_000,
          symbols: ["AAPL"]
        )

      assert %{route: :internal_poll} = Feed.status(feed)

      new_credentials = Map.put(@credentials, :access_token, "fresh-token")
      assert Feed.update_credentials(feed, new_credentials) == :ok
      assert Process.alive?(feed)
    end
  end

  describe "the poll route" do
    test "coverage on the poll route reports :internal_poll, never :stream" do
      # The whole point of the two routes being visible. A poll reporting `:stream` is the
      # substitution this family refuses.
      feed =
        start_feed(
          plug: fn conn ->
            if String.contains?(conn.request_path, "userPreference") do
              Plug.Conn.resp(conn, 401, "no")
            else
              Req.Test.json(conn, quote_body())
            end
          end,
          retry_attempts: 0,
          interval_ms: 50,
          start_delay_ms: 0,
          symbols: ["AAPL"]
        )

      assert_receive {:dp_exchange, :schwab, %Types.Quote{symbol: "AAPL"}}, 3_000
      assert Feed.coverage(feed) == %{"AAPL" => :internal_poll}
      assert %{route: :internal_poll} = Feed.status(feed)
    end

    test "coverage_by_kind on the poll route reports only :quotes, never :order_book" do
      # Depth structurally cannot arrive on this route — the poller only ever calls
      # `Rest.get_price/3` — so there must be no `:order_book` key at all, not an empty one.
      feed =
        start_feed(
          plug: fn conn ->
            if String.contains?(conn.request_path, "userPreference") do
              Plug.Conn.resp(conn, 401, "no")
            else
              Req.Test.json(conn, quote_body())
            end
          end,
          retry_attempts: 0,
          interval_ms: 50,
          start_delay_ms: 0,
          symbols: ["AAPL"]
        )

      assert_receive {:dp_exchange, :schwab, %Types.Quote{symbol: "AAPL"}}, 3_000

      by_kind = Feed.coverage_by_kind(feed)

      assert by_kind == %{quotes: %{"AAPL" => :internal_poll}}
      refute Map.has_key?(by_kind, :order_book)

      assert_union_matches_coverage(feed, by_kind)
      assert_declared_streamable(by_kind)
    end
  end

  describe "the fallback poll's own silent-delivery notice — DpCryptoManagement issue #21" do
    # `Core.PollingFeed` 0.1.50 added `:on_notice`, fired once on the transition into
    # delivering nothing and once on the transition back out. This is `Feed`'s own wiring
    # of it (`start_poller/1`) under test — not `Core.PollingFeed`'s latching logic itself,
    # which belongs to that package's own suite.
    #
    # These notices must never read as the Streamer's own health. `PollingFeed` only ever
    # runs on this venue's `:poll` route, so a `:coverage_change` notice can only ever
    # describe the fallback poll — the Streamer's connection health is a different `kind`
    # entirely (`:link_down` / `:link_up`, from `Socket`, provider `:schwab` as
    # an atom). This poller's label is `"schwab-fallback-poll"`, a *string*, precisely so
    # both the notice's `provider` and its message text are unambiguous even read alone.

    defp always_failing_quotes_plug do
      fn conn ->
        if String.contains?(conn.request_path, "userPreference") do
          Plug.Conn.resp(conn, 401, "no")
        else
          Plug.Conn.resp(conn, 500, "boom")
        end
      end
    end

    # Fails `fail_times` polls against `/quotes`, then succeeds — the family idiom for
    # driving a poll through failure and recovery deterministically (see
    # `dp_exchange_coinbase`'s `feed_test.exs`, `flaky_socket_loop/2`, for the same shape
    # applied to a socket send instead of an HTTP response).
    defp recovering_quotes_plug(counter, fail_times) do
      fn conn ->
        if String.contains?(conn.request_path, "userPreference") do
          Plug.Conn.resp(conn, 401, "no")
        else
          attempt = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)

          if attempt < fail_times do
            Plug.Conn.resp(conn, 500, "boom")
          else
            Req.Test.json(conn, quote_body())
          end
        end
      end
    end

    test "delivering nothing on the fallback poll emits a coverage_change warning naming the poll, not the Streamer" do
      feed =
        start_feed(
          plug: always_failing_quotes_plug(),
          retry_attempts: 0,
          interval_ms: 50,
          # Headroom before the first tick so `subscribe_notices/2` below is guaranteed to
          # land before the poller's first attempt — the poller is a third process on its
          # own timer, not driven by a message this test controls.
          start_delay_ms: 150,
          symbols: ["AAPL"]
        )

      :ok = Feed.subscribe_notices(feed, to: self())

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :coverage_change} = notice}, 3_000

      assert notice.severity == :warning
      assert notice.provider == "schwab-fallback-poll"

      assert notice.message ==
               "schwab-fallback-poll has delivered nothing in 1 consecutive attempts"

      assert notice.details.label == "schwab-fallback-poll"

      # Never the Streamer's own vocabulary. A reader with only this text has to be able
      # to tell the two apart.
      refute notice.message =~ "Streamer"
      refute notice.message =~ "socket"
    end

    test "the notice fires once per outage, not once per failed tick" do
      feed =
        start_feed(
          plug: always_failing_quotes_plug(),
          retry_attempts: 0,
          interval_ms: 50,
          start_delay_ms: 150,
          symbols: ["AAPL"]
        )

      :ok = Feed.subscribe_notices(feed, to: self())

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :coverage_change, severity: :warning}},
                     3_000

      # Several more tick intervals pass with the poll still failing every attempt — no
      # second notice, because `PollingFeed` latches to `:dead` on the first crossing and
      # only fires again on recovery.
      refute_receive {:dp_exchange, :schwab, %Notice{kind: :coverage_change}}, 400
    end

    test "recovery fires a distinct info notice once the fallback poll starts delivering again" do
      counter = :counters.new(1, [])

      feed =
        start_feed(
          plug: recovering_quotes_plug(counter, 3),
          retry_attempts: 0,
          interval_ms: 50,
          start_delay_ms: 150,
          symbols: ["AAPL"]
        )

      :ok = Feed.subscribe_notices(feed, to: self())

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :coverage_change, severity: :warning}},
                     3_000

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :coverage_change} = recovery},
                     3_000

      assert recovery.severity == :info
      assert recovery.provider == "schwab-fallback-poll"

      assert recovery.message ==
               "schwab-fallback-poll has resumed delivering after 3 consecutive failures"

      assert recovery.details.label == "schwab-fallback-poll"

      # The recovered quote itself still arrives normally on the same route.
      assert_receive {:dp_exchange, :schwab, %Types.Quote{symbol: "AAPL"}}, 3_000
      assert Feed.coverage(feed) == %{"AAPL" => :internal_poll}
    end
  end

  describe "coverage_by_kind on the stream route" do
    test "a symbol delivering only a Quote is :quotes, never :order_book" do
      feed = start_feed(socket: fake_socket())
      Feed.subscribe(feed, ["AAPL"])

      send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      assert_receive {:dp_exchange, :schwab, %Types.Quote{}}, 2_000

      by_kind = Feed.coverage_by_kind(feed)

      assert by_kind == %{quotes: %{"AAPL" => :stream}}
      refute Map.has_key?(by_kind, :order_book)

      assert_union_matches_coverage(feed, by_kind)
      assert_declared_streamable(by_kind)
    end

    test "a symbol delivering only an OrderBook is :order_book, never :quotes" do
      feed = start_feed(socket: fake_socket())
      Feed.subscribe(feed, ["MSFT"])

      send(feed, {:dp_exchange, :schwab, order_book_for("MSFT")})
      assert_receive {:dp_exchange, :schwab, %Types.OrderBook{}}, 2_000

      by_kind = Feed.coverage_by_kind(feed)

      assert by_kind == %{order_book: %{"MSFT" => :stream}}
      refute Map.has_key?(by_kind, :quotes)

      assert_union_matches_coverage(feed, by_kind)
      assert_declared_streamable(by_kind)
    end

    test "two symbols delivering different kinds land under different keys, and the union still matches coverage/1" do
      feed = start_feed(socket: fake_socket())
      Feed.subscribe(feed, ["AAPL", "MSFT"])

      send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      send(feed, {:dp_exchange, :schwab, order_book_for("MSFT")})
      assert_receive {:dp_exchange, :schwab, %Types.Quote{}}, 2_000
      assert_receive {:dp_exchange, :schwab, %Types.OrderBook{}}, 2_000

      by_kind = Feed.coverage_by_kind(feed)

      assert by_kind == %{quotes: %{"AAPL" => :stream}, order_book: %{"MSFT" => :stream}}

      assert_union_matches_coverage(feed, by_kind)
      assert_declared_streamable(by_kind)
    end
  end

  describe "rate_limit_blocking — DpCryptoManagement issue #23 (fallback poll)" do
    # A limiter with a single, already-spent allowance: `record/3` commits usage the way
    # `acquire/3` does, without `acquire/3`'s own wait — so the bucket starts genuinely
    # empty and the next request against it has to wait out one whole emission interval
    # (~300ms) regardless of which mode reaches it. That wait is the one observable
    # difference between blocking (`acquire/3`, which waits it out and then succeeds) and
    # fail-fast (`check/3`, which refuses immediately and never retries before the next
    # poll tick) — proving `rate_limit_blocking` actually reaches `Core.HttpClient` on the
    # fallback poll route, across the process boundary `apply_config/1` exists to cross.
    #
    # `Config.put_override(:rate_limit_module, DefaultRateLimiter)` overrides this file's
    # own `setup` block (which points every other test at `PermissiveLimiter`) so these
    # two tests exercise the real limiter — `state.config_snapshot` captures whichever
    # module is active in the test process at the moment `start_feed/1` calls
    # `Feed.start_link/1`, so the override has to happen first.
    defp exhausted_limiter do
      name = :"limiter_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        DefaultRateLimiter.start_link(
          name: name,
          limits: %{default: %{limit: 1, per_ms: 300, burst: 0}}
        )

      :ok = DefaultRateLimiter.record(:schwab, 1, limiter: name)
      name
    end

    defp poll_plug do
      fn conn ->
        if String.contains?(conn.request_path, "userPreference") do
          Plug.Conn.resp(conn, 401, "no")
        else
          Req.Test.json(conn, quote_body())
        end
      end
    end

    test "the fallback poll defaults to blocking, matching this feed's own documented design: a slow cycle, not a missing price" do
      Config.put_override(:rate_limit_module, DefaultRateLimiter)

      feed =
        start_feed(
          plug: poll_plug(),
          retry_attempts: 0,
          interval_ms: 60_000,
          start_delay_ms: 0,
          symbols: ["AAPL"],
          limiter: exhausted_limiter()
        )

      # check/3 would refuse immediately and never retry inside this window (the next
      # tick is 60s away) — only acquire/3 (the default) delivers here at all. The
      # bootstrap's own `/userPreference` call shares this same limiter and opts, so it
      # waits out the bucket too before falling back — hence the generous timeout.
      assert_receive {:dp_exchange, :schwab, %Types.Quote{symbol: "AAPL"}}, 3_000
      assert %{route: :internal_poll} = Feed.status(feed)
    end

    test "a caller can still opt into fail-fast explicitly, and it costs the poll cycle" do
      Config.put_override(:rate_limit_module, DefaultRateLimiter)

      feed =
        start_feed(
          plug: poll_plug(),
          retry_attempts: 0,
          interval_ms: 60_000,
          start_delay_ms: 0,
          symbols: ["AAPL"],
          limiter: exhausted_limiter(),
          rate_limit_blocking: false
        )

      refute_receive {:dp_exchange, :schwab, %Types.Quote{symbol: "AAPL"}}, 1_500
      assert Process.alive?(feed)
    end
  end

  test "child_spec carries the configured name as its id" do
    assert %{id: :my_feed, type: :worker} = Feed.child_spec(name: :my_feed)
  end

  defp quote_for(symbol) do
    %Types.Quote{
      symbol: symbol,
      price: Decimal.new("100.5"),
      timestamp: DateTime.utc_now(),
      provider: :schwab
    }
  end

  defp order_book_for(symbol) do
    %Types.OrderBook{
      symbol: symbol,
      bids: [{Decimal.new("100.00"), Decimal.new("10")}],
      asks: [{Decimal.new("100.10"), Decimal.new("5")}],
      timestamp: DateTime.utc_now(),
      sequence: nil,
      provider: :schwab
    }
  end

  # The invariant `coverage_by_kind/1`'s own moduledoc states: every symbol `coverage/1`
  # reports appears under some kind in `by_kind`, and vice versa — asserted as a set
  # equality over symbol keys, not over the maps themselves, since the same symbol can
  # legitimately repeat under more than one kind.
  defp assert_union_matches_coverage(feed, by_kind) do
    coverage_symbols = feed |> Feed.coverage() |> Map.keys() |> Enum.sort()

    union =
      by_kind
      |> Map.values()
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()
      |> Enum.sort()

    assert union == coverage_symbols
  end

  defp assert_declared_streamable(by_kind) do
    declared = MapSet.new(DpExchange.Schwab.capabilities().streamable)
    reported = by_kind |> Map.keys() |> MapSet.new()

    assert MapSet.subset?(reported, declared)
  end

  defp quote_body do
    %{
      "AAPL" => %{
        "quote" => %{
          "lastPrice" => 227.5,
          "totalVolume" => 51_234_567,
          "quoteTime" => 1_787_936_147_000
        }
      }
    }
  end

  defp relay(parent) do
    receive do
      message ->
        send(parent, {:relayed, message})
        relay(parent)
    end
  end
end
