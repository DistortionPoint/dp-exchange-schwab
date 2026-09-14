defmodule DpExchange.Schwab.FallbackPollTest do
  @moduledoc """
  The REST fallback poll: what it says when it delivers nothing, and how it blocks.

  Both describes here are about the poll route being honest rather than quiet — the
  family's signature defect is a plausible value with the wrong meaning, and a fallback
  that silently delivers nothing is exactly that. They cost a poll cycle each by
  construction. Split out for wall clock — see `DpExchange.Schwab.FeedCase`.
  """

  use DpExchange.Schwab.FeedCase, async: true

  alias DpExchange.Core.{Config, DefaultRateLimiter, Notice, Types}
  alias DpExchange.Schwab.Feed

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

      :ok = Feed.subscribe(feed, ["AAPL"])
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

      :ok = Feed.subscribe(feed, ["AAPL"])
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

      :ok = Feed.subscribe(feed, ["AAPL"])
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

      :ok = Feed.subscribe(feed, ["AAPL"])

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

      :ok = Feed.subscribe(feed, ["AAPL"])

      refute_receive {:dp_exchange, :schwab, %Types.Quote{symbol: "AAPL"}}, 1_500
      assert Process.alive?(feed)
    end
  end

  test "child_spec carries the configured name as its id" do
    assert %{id: :my_feed, type: :worker} = Feed.child_spec(name: :my_feed)
  end
end
