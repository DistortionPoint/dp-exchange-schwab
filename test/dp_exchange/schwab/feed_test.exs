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

  # A real 21-character Schwab option symbol — root, padded to 6; expiry as YYMMDD; C/P;
  # strike * 1000 padded to 8 digits — matching `SymbolFormat.option?/1`'s pattern.
  @option_symbol "AAPL  260116C00250000"

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

    # `feed` is linked to THIS test process (plain `start_link`, no supervisor) and
    # on_exit callbacks run after the test process itself has already exited — so by the
    # time this runs, `feed` may already be gone, a race whose window `Feed` trapping
    # exits (added for the crash-isolation fix) widens: `Process.alive?/1` can still
    # answer `true` a moment before the same teardown catches up and the process is
    # gone by the time `GenServer.stop/2` actually reaches it. `:noproc` here means
    # cleanup has nothing left to do, not a test failure.
    on_exit(fn ->
      try do
        GenServer.stop(feed, :normal)
      catch
        :exit, _reason -> :ok
      end
    end)

    feed
  end

  describe ":interval_ms is validated at init, not at the first tick" do
    # `interval_ms` reaches `Core.PollingFeed` and ends up in `Process.send_after/3`, which
    # accepts neither a negative nor a fractional delay — but not until the first tick, in
    # another process, long after `start_link/1` answered `{:ok, pid}`. Under this tree's
    # `:one_for_one` strategy that is a restart loop rather than a refusal, and the crash
    # names the timer, not the option. Refused at `init/1` instead.
    test "a non-positive or fractional interval is refused at start" do
      for bad <- [0, -1, 1.5, "1000"] do
        assert_raise ArgumentError, ~r/interval_ms must be a positive integer/, fn ->
          Feed.init(interval_ms: bad)
        end
      end
    end

    # An explicit `nil` is what a forwarded, never-configured option looks like, and
    # `Core.Config.opt/3` is what turns it back into the default rather than passing the
    # `nil` through to the timer.
    test "an absent or explicitly nil interval takes the default" do
      assert {:ok, _state} = Feed.init([])
      assert {:ok, _state2} = Feed.init(interval_ms: nil)
    end
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

      # The route is established on the first ask, not at boot — see the moduledoc's "A
      # consumer that never subscribes must not find a socket open" section.
      :ok = Feed.subscribe(feed, ["AAPL"])

      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :degraded, details: %{fallback: :internal_poll}}},
                     2_000

      assert %{route: :internal_poll} = Feed.status(feed)
    end

    test "a response without streamerInfo is a bootstrap failure, not an empty stream" do
      # 200, valid JSON, and no socket in it. This is the shape that would produce a feed
      # that connects to nothing while every status looks healthy.
      feed = start_feed(plug: responding(%{"accounts" => []}), retry_attempts: 0)

      :ok = Feed.subscribe(feed, ["AAPL"])

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded, details: details}}, 2_000
      assert details.reason =~ "no_streamer_info"
      assert %{route: :internal_poll} = Feed.status(feed)
    end

    test "credentials with no access token cannot bootstrap even when the call succeeds" do
      feed =
        start_feed(
          credentials: %{},
          plug: responding(@user_preference),
          retry_attempts: 0
        )

      :ok = Feed.subscribe(feed, ["AAPL"])

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded, details: details}}, 2_000
      assert details.reason =~ "missing_credentials"
    end
  end

  describe "nothing is dialled before the first subscribe" do
    # The invariant the whole family's supervision rule rests on: a consumer that
    # supervises this package and never asks for anything must not find a socket open,
    # and must not have caused a single request to reach the venue either — see the
    # moduledoc's "A consumer that never subscribes must not find a socket open" section.
    # Nothing currently pinned this, which is exactly how it drifted.
    test "starting the feed makes no venue call and establishes no route" do
      test_pid = self()

      # Any request reaching this plug is itself the failure — proven by raising rather
      # than by a timing assertion (`Process.sleep/1` is forbidden here for exactly this
      # reason: it cannot tell "will never happen" from "hasn't happened yet").
      plug = fn _conn ->
        send(test_pid, :unexpected_venue_call)
        raise "no request should have reached the venue before subscribe/2"
      end

      feed = start_feed(plug: plug, retry_attempts: 0, symbols: ["AAPL"])

      # `status/1` is a synchronous call — it only returns once every message queued
      # ahead of it (including any `init/1`-time continue, were one still wired) has been
      # processed, so this is a real fence, not a race against `Process.sleep/1`.
      assert %{route: nil, delivering: 0, wanted: 1, last_error: nil} = Feed.status(feed)
      assert Feed.coverage(feed) == %{}
      assert Feed.coverage_by_kind(feed) == %{}
      refute_received :unexpected_venue_call
    end

    test "subscribing is what actually dials, and only then" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, :venue_call)
        Plug.Conn.resp(conn, 401, "no")
      end

      feed = start_feed(plug: plug, retry_attempts: 0)
      refute_received :venue_call

      :ok = Feed.subscribe(feed, ["AAPL"])
      assert_receive :venue_call, 2_000
    end
  end

  describe "a crashed socket is isolated, not fatal" do
    # `fake_socket/0` is injected via `opts` — it was never `start_link`'d FROM `Feed`,
    # so it is not actually linked to it. Every real socket this module ever opens IS
    # linked — `start_socket/1` calls `Socket.start_link/1` from inside `ensure_route/1`,
    # a `Feed` callback, and `start_link` always links. `:sys.replace_state/2` runs the
    # given function INSIDE the target process, so `Process.link/1` inside it creates a
    # link owned by `feed`, matching what `start_socket/1` does in production, from a
    # place this test controls.
    defp link_socket_into_feed(feed, socket) do
      :sys.replace_state(feed, fn state ->
        Process.link(socket)
        state
      end)
    end

    test "the feed survives a linked socket being killed" do
      socket = fake_socket()

      # `isolate_crashed_route/2` retries the route immediately, through the real
      # `start_socket/1` this time — `retry_attempts: 0` and a refusing plug keep that
      # retry from ever reaching the live network from this test.
      feed =
        start_feed(
          socket: socket,
          plug: responding(%{"error" => "unauthorized"}, 401),
          retry_attempts: 0
        )

      :ok = Feed.subscribe(feed, ["AAPL"])
      link_socket_into_feed(feed, socket)

      # `:kill`, not `:normal` — a non-trapping process ignores a peer's normal exit,
      # which would prove nothing about the trap_exit flag this test exists to check.
      ref = Process.monitor(feed)
      Process.exit(socket, :kill)
      refute_receive {:DOWN, ^ref, :process, ^feed, _reason}, 500
      assert Process.alive?(feed)
    end

    test "coverage clears, a :link_down notice fires, and it retries the route immediately" do
      socket = fake_socket()
      # The REPLACEMENT route, dialled by `isolate_crashed_route/2` -> `ensure_route/1`,
      # goes through the real `start_socket/1` this time (`fake_socket/0` only ever
      # stands in for the FIRST socket, injected directly) — `retry_attempts: 0` and a
      # refusing plug make that attempt fail fast and land on the poll route, which is
      # itself the proof an attempt was made right away rather than never.
      feed =
        start_feed(
          socket: socket,
          plug: responding(%{"error" => "unauthorized"}, 401),
          retry_attempts: 0
        )

      :ok = Feed.subscribe(feed, ["AAPL"])
      send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      assert_receive {:dp_exchange, :schwab, %Types.Quote{}}, 2_000
      assert Feed.coverage(feed) == %{"AAPL" => :stream}

      link_socket_into_feed(feed, socket)
      Process.exit(socket, :kill)

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :link_down}}, 2_000
      assert Process.alive?(feed)

      # Cleared immediately — not "eventually, once something else overwrites it" — the
      # coverage-truthfulness question the audit asked directly: does `coverage/1` still
      # say `:stream` right after the socket carrying "AAPL" crashed? It must not.
      assert Feed.coverage(feed) == %{}

      # The replacement route landed on `:poll` (the only place a refusing plug can take
      # it), which is itself proof `isolate_crashed_route/2` retried right away instead
      # of leaving this feed on a dead `:stream` route forever.
      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :degraded, details: %{fallback: :internal_poll}}},
                     2_000

      assert %{route: :internal_poll} = Feed.status(feed)
    end
  end

  describe "a reconnect resends the wanted set on its own — no consumer action needed" do
    test "the periodic timer re-issues every wanted symbol on the stream route" do
      socket = fake_socket()
      feed = start_feed(socket: socket)
      :ok = Feed.subscribe(feed, ["AAPL"])

      assert subscribed_services(socket) == %{
               "LEVELONE_EQUITIES" => ["AAPL"],
               "CHART_EQUITY" => ["AAPL"]
             }

      send(feed, :resubscribe)
      # A synchronous call forces the cast above to be processed before this returns.
      Feed.coverage(feed)

      assert subscribed_services(socket) == %{
               "LEVELONE_EQUITIES" => ["AAPL", "AAPL"],
               "CHART_EQUITY" => ["AAPL", "AAPL"]
             }
    end

    test "sends nothing when nothing is wanted" do
      socket = fake_socket()
      feed = start_feed(socket: socket)
      # No symbols wanted — an empty `subscribe/2` is what puts this feed on the `:stream`
      # route at all now that nothing does so on its own at boot; see the moduledoc's "A
      # consumer that never subscribes must not find a socket open" section.
      :ok = Feed.subscribe(feed, [])

      send(feed, :resubscribe)
      Feed.coverage(feed)

      assert subscribed_services(socket) == %{}
      assert Process.alive?(feed)
    end

    test "the poll route is left to PollingFeed's own ticking" do
      feed =
        start_feed(plug: responding(%{"error" => "unauthorized"}, 401), retry_attempts: 0)

      :ok = Feed.subscribe(feed, ["AAPL"])
      assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded}}, 2_000

      send(feed, :resubscribe)
      Feed.coverage(feed)

      assert %{route: :internal_poll} = Feed.status(feed)
      assert Process.alive?(feed)
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

      :ok = Feed.subscribe(feed, ["AAPL"])
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

      :ok = Feed.subscribe(feed, ["AAPL"])

      assert_receive {:dp_exchange, :schwab, %Types.Quote{symbol: "AAPL"}}, 3_000
      assert Feed.coverage(feed) == %{"AAPL" => :internal_poll}
      assert %{route: :internal_poll} = Feed.status(feed)
    end

    test "an unresponsive poller cannot kill the Feed — reads degrade, the venue stays up" do
      # dp-exchange-core issue #28, reported against dp_exchange_robinhood and true here for
      # the same reason: on this route all three of `coverage/1`, `coverage_by_kind/1` and
      # `status/1` delegate into `PollingFeed` with `GenServer.call/2`'s five-second default,
      # into a process that could not answer while a fetch was in flight. The exit
      # propagated out of `handle_call/3` and killed `Feed`, which restarts from static opts
      # that never carry a consumer's later `subscribe/2`.
      #
      # The poller is swapped for a dead pid rather than suspended, so the exit is an
      # immediate `:noproc` rather than a five-second timeout: same `catch :exit` path,
      # deterministic, and it costs the suite nothing.
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

      :ok = Feed.subscribe(feed, ["AAPL"])
      assert_receive {:dp_exchange, :schwab, %Types.Quote{symbol: "AAPL"}}, 3_000
      :ok = Feed.subscribe_notices(feed, to: self())

      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}, 500

      :sys.replace_state(feed, fn state -> %{state | poller: dead} end)

      # All three reads answer instead of exiting, and none of them invents coverage.
      assert Feed.coverage(feed) == %{}
      assert Feed.coverage_by_kind(feed) == %{quotes: %{}}

      status = Feed.status(feed)
      refute status.delivering
      assert status.last_error == :poller_unresponsive
      assert status.route == :internal_poll

      assert Process.alive?(feed)

      # An empty map alone is indistinguishable from a venue delivering nothing. The notice
      # is what says "we could not ask", which is a different fact about the world.
      assert_receive {:dp_exchange, :schwab, %{kind: :link_down} = notice}, 500
      assert notice.severity == :warning
      assert notice.message =~ "did not answer a read"
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

      :ok = Feed.subscribe(feed, ["AAPL"])

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

    test "a symbol delivering only a Candle is :candles, never :quotes" do
      feed = start_feed(socket: fake_socket())
      Feed.subscribe(feed, ["MSFT"])

      send(feed, {:dp_exchange, :schwab, candle_for("MSFT")})
      assert_receive {:dp_exchange, :schwab, %Types.Candle{}}, 2_000

      by_kind = Feed.coverage_by_kind(feed)

      assert by_kind == %{candles: %{"MSFT" => :stream}}
      refute Map.has_key?(by_kind, :quotes)

      assert_union_matches_coverage(feed, by_kind)
      assert_declared_streamable(by_kind)
    end

    test "two symbols delivering different kinds land under different keys, and the union still matches coverage/1" do
      feed = start_feed(socket: fake_socket())
      Feed.subscribe(feed, ["AAPL", "MSFT"])

      send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      send(feed, {:dp_exchange, :schwab, candle_for("MSFT")})
      assert_receive {:dp_exchange, :schwab, %Types.Quote{}}, 2_000
      assert_receive {:dp_exchange, :schwab, %Types.Candle{}}, 2_000

      by_kind = Feed.coverage_by_kind(feed)

      assert by_kind == %{quotes: %{"AAPL" => :stream}, candles: %{"MSFT" => :stream}}

      assert_union_matches_coverage(feed, by_kind)
      assert_declared_streamable(by_kind)
    end

    test "an OrderBook value has no kind mapping — nothing this feed subscribes ever produces one" do
      # `services_for/1` never asks for `NYSE_BOOK`, `NASDAQ_BOOK` or `OPTIONS_BOOK` (see
      # `Feed`'s moduledoc), so a real stream never delivers a `Types.OrderBook` here. This
      # injects one anyway to prove `record_kind/3` does not misreport it as a declared
      # kind — `capabilities().streamable` no longer names `:order_book`, and a reported
      # kind the declaration does not name is exactly what `Core.AdapterContract`'s
      # conformance suite checks for.
      feed = start_feed(socket: fake_socket())
      Feed.subscribe(feed, ["MSFT"])

      send(feed, {:dp_exchange, :schwab, order_book_for("MSFT")})
      assert_receive {:dp_exchange, :schwab, %Types.OrderBook{}}, 2_000

      assert Feed.coverage_by_kind(feed) == %{}
      assert Feed.coverage(feed) == %{"MSFT" => :stream}
    end
  end

  describe "the socket subscribe wiring — services_for/1" do
    test "an equity symbol reaches both LEVELONE_EQUITIES and CHART_EQUITY" do
      socket = fake_socket()
      feed = start_feed(socket: socket)

      Feed.subscribe(feed, ["AAPL"])

      services = subscribed_services(socket)
      assert %{"LEVELONE_EQUITIES" => ["AAPL"]} = services
      assert %{"CHART_EQUITY" => ["AAPL"]} = services
    end

    test "an option symbol reaches only LEVELONE_OPTIONS — no CHART_EQUITY, no book service" do
      socket = fake_socket()
      feed = start_feed(socket: socket)

      Feed.subscribe(feed, [@option_symbol])

      services = subscribed_services(socket)
      assert Map.has_key?(services, "LEVELONE_OPTIONS")
      refute Map.has_key?(services, "CHART_EQUITY")
      refute Map.has_key?(services, "LEVELONE_EQUITIES")
    end

    test "NYSE_BOOK, NASDAQ_BOOK, OPTIONS_BOOK and ACCT_ACTIVITY are never sent" do
      # The defect this section guards: `capabilities/0` once declared these streamable
      # with nothing here ever asking the venue for them. Wiring `:candles` must not
      # accidentally start asking for the other three too.
      socket = fake_socket()
      feed = start_feed(socket: socket)

      Feed.subscribe(feed, ["AAPL", @option_symbol])

      services = subscribed_services(socket)
      refute Map.has_key?(services, "NYSE_BOOK")
      refute Map.has_key?(services, "NASDAQ_BOOK")
      refute Map.has_key?(services, "OPTIONS_BOOK")
      refute Map.has_key?(services, "ACCT_ACTIVITY")
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

    # The bootstrap path (`Rest.get_user_preference/2`) reaches `Core.HttpClient`, which fails
    # closed with "Rate limiter unavailable" when no limiter is named — so a test that means
    # to exercise the Streamer bootstrap must supply one, or it silently measures the
    # fallback-to-poll path instead. Learned the hard way while proving the blocking bug:
    # without this the plug was never reached at all.
    defp permissive_limiter do
      name = :"limiter_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        start_supervised(
          {DefaultRateLimiter,
           name: name, limits: %{schwab: %{limit: 1_000, per_ms: 1_000, burst: 1_000}}},
          id: name
        )

      name
    end

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

  defp quote_for(symbol) do
    %Types.Quote{
      symbol: symbol,
      price: Decimal.new("100.5"),
      venue_time: DateTime.utc_now(),
      observed_at: DateTime.utc_now(),
      provider: :schwab
    }
  end

  defp order_book_for(symbol) do
    %Types.OrderBook{
      symbol: symbol,
      bids: [{Decimal.new("100.00"), Decimal.new("10")}],
      asks: [{Decimal.new("100.10"), Decimal.new("5")}],
      venue_time: DateTime.utc_now(),
      observed_at: DateTime.utc_now(),
      sequence: nil,
      provider: :schwab
    }
  end

  defp candle_for(symbol) do
    %Types.Candle{
      symbol: symbol,
      timeframe: "1m",
      opened_at: DateTime.utc_now(),
      open: Decimal.new("100.0"),
      high: Decimal.new("101.0"),
      low: Decimal.new("99.5"),
      close: Decimal.new("100.5"),
      volume: Decimal.new("1000"),
      provider: :schwab
    }
  end

  # `WebSockex.cast/2` sends `{:"$websockex_cast", message}` straight to the pid via
  # `Kernel.send/2` — `fake_socket/0`'s process never calls `receive`, so every subscribe
  # this feed sent is still sitting in its mailbox by the time a synchronous
  # `Feed.subscribe/2,3` call has returned. Returns `%{service => keys}`.
  defp subscribed_services(socket_pid) do
    {:messages, messages} = Process.info(socket_pid, :messages)

    for {:"$websockex_cast", {:subscribe, service, "SUBS", keys, _opts}} <- messages,
        reduce: %{} do
      acc -> Map.update(acc, service, keys, &(&1 ++ keys))
    end
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

  describe "a read cannot be blocked by a subscribe establishing the route (core #28's class)" do
    test "coverage/1 answers while a subscribe is still bootstrapping the Streamer" do
      # Establishing the Streamer route means a signed `Rest.get_user_preference/2` round
      # trip plus a WebSocket connect. That used to run INLINE in `handle_call/3`, so a
      # subscribe blocked this GenServer for the whole of it — and with `Core.HttpClient`'s
      # documented defaults (30_000 ms per attempt, 3 attempts) that window reaches about
      # ninety seconds. `coverage/1` and `status/1` are plain `GenServer.call/2`s carrying
      # the FIVE-second default, so a health check arriving during a subscribe did not wait,
      # it exited — and a consumer calling it from their own `handle_call/3` died with it.
      #
      # That is dp-exchange-core issue #28's exact failure on a different venue and a
      # different call. It was found by sweeping this family for the class the #30 reporter
      # named — "work done in the process that owes a reply" — not by it failing in
      # production a second time. This test failed before the fix, with `coverage/1` not
      # answering inside 500 ms.
      test_pid = self()

      plug = fn conn ->
        if String.contains?(conn.request_path, "userPreference") do
          send(test_pid, :bootstrap_started)
          # Stands in for a slow venue. The real budget is ~90s; 2s keeps the test quick
          # while still being far longer than the 500ms this asserts a read answers within.
          Process.sleep(2_000)
          Plug.Conn.resp(conn, 401, "no")
        else
          Req.Test.json(conn, quote_body())
        end
      end

      feed =
        start_feed(
          plug: plug,
          limiter: permissive_limiter(),
          retry_attempts: 0,
          start_delay_ms: 0,
          interval_ms: 50
        )

      subscriber = Task.async(fn -> Feed.subscribe(feed, ["AAPL"]) end)
      assert_receive :bootstrap_started, 1_000

      reader = Task.async(fn -> Feed.coverage(feed) end)
      result = Task.yield(reader, 500) || Task.shutdown(reader, :brutal_kill)

      assert match?({:ok, _}, result),
             "coverage/1 did not answer within 500ms while a subscribe was establishing " <>
               "the route — the Feed is blocked inside handle_call. got: #{inspect(result)}"

      # The subscribe still gets its own answer once the route settles; deferring the reply
      # must not mean losing it.
      assert Task.await(subscriber, 5_000) in [:ok, {:error, :no_route}]
      assert Process.alive?(feed)
    end

    test "two subscribes during one bootstrap share it, and both are answered" do
      # `waiting` is a list precisely so this cannot become two Streamer connections for a
      # consumer that called `subscribe/2` twice in quick succession. Both callers are owed
      # a reply from the one bootstrap; dropping either would hang a caller until its
      # `@call_timeout`.
      test_pid = self()

      plug = fn conn ->
        if String.contains?(conn.request_path, "userPreference") do
          send(test_pid, :bootstrap_started)
          Process.sleep(500)
          Plug.Conn.resp(conn, 401, "no")
        else
          Req.Test.json(conn, quote_body())
        end
      end

      feed =
        start_feed(
          plug: plug,
          limiter: permissive_limiter(),
          retry_attempts: 0,
          start_delay_ms: 0,
          interval_ms: 50
        )

      first = Task.async(fn -> Feed.subscribe(feed, ["AAPL"]) end)
      assert_receive :bootstrap_started, 1_000
      second = Task.async(fn -> Feed.subscribe(feed, ["MSFT"]) end)

      assert Task.await(first, 5_000) in [:ok, {:error, :no_route}]
      assert Task.await(second, 5_000) in [:ok, {:error, :no_route}]

      # Exactly one bootstrap ran: a second would have sent a second `:bootstrap_started`.
      refute_receive :bootstrap_started, 300

      assert Enum.sort(Feed.wanted(feed)) == ["AAPL", "MSFT"]
    end
  end
end
