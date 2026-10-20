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

  use DpExchange.Schwab.FeedCase, async: true

  alias DpExchange.Core.{Config, Notice, Types}
  alias DpExchange.Schwab.Feed

  defmodule ExitOnceLimiter do
    @moduledoc false
    # Exits on the first `acquire/3` and permits every later one. The `:limiter` option each
    # request carries is an Agent holding whether the exit is still owed, so the first
    # request (the bootstrap) fails the way a dead limiter process fails a caller, and the
    # fallback poll that follows is left able to run.
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, opts) do
      if Agent.get_and_update(Keyword.fetch!(opts, :limiter), &{&1, false}),
        do: exit(:limiter_gone),
        else: :ok
    end

    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

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

  describe "a feed that stops normally takes its socket with it" do
    test "GenServer.stop/1 ends the linked socket, which does not trap exits" do
      socket = fake_socket()
      ref = Process.monitor(socket)
      feed = start_feed(socket: socket)

      assert :ok = GenServer.stop(feed, :normal)
      assert_receive {:DOWN, ^ref, :process, ^socket, :shutdown}, 5_000
    end
  end

  describe "a forwarded nil :rate_limit_blocking is silence, so the fallback poll still blocks" do
    # `Keyword.put_new/3` keeps a present `nil`, and `Rest` drops a `nil` as silence, so the
    # `true` default never applied and the poll ran fail-fast.
    test "nil gets the default; an explicit false is still honoured" do
      assert {:ok, silent} = Feed.init(rate_limit_blocking: nil)
      assert silent.request_opts[:rate_limit_blocking] == true

      assert {:ok, explicit} = Feed.init(rate_limit_blocking: false)
      assert explicit.request_opts[:rate_limit_blocking] == false

      assert {:ok, absent} = Feed.init([])
      assert absent.request_opts[:rate_limit_blocking] == true
    end
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

    # The boot-time `:symbols` get the judgement `subscribe/2` makes, so the door that never
    # ran it cannot put a pair-shaped or non-string symbol into the wanted set.
    test "boot symbols this venue would refuse are refused at start, by name" do
      for bad <- [[:aapl], [42], ["AAPL", nil], ["BTC-USD"]] do
        assert_raise ArgumentError, ~r/symbols must be equity or option tickers/, fn ->
          Feed.init(symbols: bad)
        end
      end

      assert_raise ArgumentError, ~r/symbols must be a list of ticker strings/, fn ->
        Feed.init(symbols: "AAPL")
      end
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
      assert_receive {:dp_exchange, :schwab, %Types.Quote{}}, 5_000

      assert Feed.coverage(feed) == %{"AAPL" => :stream}

      assert %{route: :stream, delivering: true, wanted: 1, covered: 1, failures_since_ok: 0} =
               stream_status = Feed.status(feed)

      # One shape on every route: the poll route answers the same keys with the same types.
      poll = start_feed(plug: responding(%{"error" => "unauthorized"}, 401), retry_attempts: 0)
      :ok = Feed.subscribe(poll, ["AAPL"])
      assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded}}, 5_000
      poll_status = Feed.status(poll)

      assert %{route: :internal_poll, delivering: false, wanted: 1, covered: 0} = poll_status
      assert Enum.sort(Map.keys(poll_status)) == Enum.sort(Map.keys(stream_status))
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
                     5_000

      assert %{route: :internal_poll} = Feed.status(feed)
    end

    test "a response without streamerInfo is a bootstrap failure, not an empty stream" do
      # 200, valid JSON, and no socket in it. This is the shape that would produce a feed
      # that connects to nothing while every status looks healthy.
      feed = start_feed(plug: responding(%{"accounts" => []}), retry_attempts: 0)

      :ok = Feed.subscribe(feed, ["AAPL"])

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded, details: details}}, 5_000
      assert details.reason == :streamer_unreachable
      assert details.message =~ "no_streamer_info"
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

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded, details: details}}, 5_000
      assert details.reason == :streamer_unreachable
      assert details.message =~ "missing_credentials"
    end

    test "a bootstrap that raises falls back to the poll with the reason, never a crash" do
      feed = start_feed(plug: responding(%{"error" => "unauthorized"}, 401), retry_attempts: 0)

      # Not a URL, so building the request raises before anything is sent. The task converts
      # the raise into an error result; unconverted, its linked exit would reach the feed with
      # no clause and the caller parked on the bootstrap would never be answered.
      :sys.replace_state(feed, fn state ->
        %{state | request_opts: Keyword.put(state.request_opts, :trader_url, 5)}
      end)

      :ok = Feed.subscribe(feed, ["AAPL"])

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded, details: details}}, 5_000
      assert details.reason == :streamer_unreachable
      assert details.message =~ ":exception"
      assert %{route: :internal_poll} = Feed.status(feed)
    end

    test "a bootstrap that exits falls back to the poll with the reason, never a crash" do
      # An exit is not a raise and `rescue` does not see it: a limiter process that is gone
      # leaves the caller with `exit/1`.
      {:ok, gate} = Agent.start_link(fn -> true end)
      Config.put_override(:rate_limit_module, ExitOnceLimiter)

      feed = start_feed(plug: responding(quote_body()), retry_attempts: 0, limiter: gate)

      :ok = Feed.subscribe(feed, ["AAPL"])

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded, details: details}}, 5_000
      assert details.reason == :streamer_unreachable
      assert details.message =~ ":exit"
      assert details.message =~ "limiter_gone"
      assert %{route: :internal_poll} = Feed.status(feed)
    end

    test "a poll that cannot start leaves no route, and the reason is kept" do
      # `PollingFeed` refuses a negative `:start_delay_ms` at its own start. The fallback then
      # has nothing to poll with, and says so rather than claiming a route it does not have.
      feed =
        start_feed(
          plug: responding(%{"error" => "unauthorized"}, 401),
          retry_attempts: 0,
          start_delay_ms: -1
        )

      assert Feed.subscribe(feed, ["AAPL"]) == {:error, :no_route}

      state = :sys.get_state(feed)
      assert state.route == nil
      assert state.poller == nil
      assert state.last_error == {:invalid_option, :start_delay_ms, -1}
    end

    test "a notice for a subscriber name nothing holds is skipped, and the others still get it" do
      feed = start_feed(plug: responding(%{"error" => "unauthorized"}, 401), retry_attempts: 0)

      # An atom naming no process: valid to register (the process may start later), and
      # skipped at send time, as `Core.Fanout` skips it, rather than raising.
      :ok = Feed.subscribe_notices(feed, to: :schwab_feed_test_name_nobody_holds)
      :ok = Feed.subscribe(feed, ["AAPL"])

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded}}, 5_000
      assert Process.alive?(feed)
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
      assert %{route: nil, delivering: false, wanted: 1, covered: 0, last_error: nil} =
               Feed.status(feed)

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

      # A synchronous call is the fence: without it the negative below is checked before
      # anything queued behind `init/1` has run, and could not fail.
      assert %{route: nil} = Feed.status(feed)
      refute_received :venue_call

      :ok = Feed.subscribe(feed, ["AAPL"])
      assert_receive :venue_call, 5_000
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
      #
      # The feed announces the crash it isolated (`:link_down`), so the test waits for that
      # event rather than for a quiet interval: a feed taken down by the exit would never
      # send it, and a short `refute_receive` window would decide the test by a race.
      :ok = Feed.subscribe_notices(feed, to: self())
      ref = Process.monitor(feed)
      Process.exit(socket, :kill)
      assert_receive {:dp_exchange, :schwab, %Notice{kind: :link_down}}, 5_000
      refute_received {:DOWN, ^ref, :process, ^feed, _reason}
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
      assert_receive {:dp_exchange, :schwab, %Types.Quote{}}, 5_000
      assert Feed.coverage(feed) == %{"AAPL" => :stream}

      link_socket_into_feed(feed, socket)
      Process.exit(socket, :kill)

      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :link_down, details: %{reason: :route_crashed} = details}},
                     5_000

      assert is_binary(details.message)
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
                     5_000

      assert %{route: :internal_poll} = Feed.status(feed)
    end

    test "the first crash in a quiet period redials at once, with nothing scheduled" do
      socket = fake_socket()

      feed =
        start_feed(
          socket: socket,
          plug: responding(%{"error" => "unauthorized"}, 401),
          retry_attempts: 0
        )

      :ok = Feed.subscribe(feed, ["AAPL"])
      :ok = Feed.subscribe_notices(feed, to: self())
      link_socket_into_feed(feed, socket)
      Process.exit(socket, :kill)

      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :link_down, message: "route crashed" <> _rest = message}},
                     5_000

      assert message =~ "reconnecting now"
      refute Map.has_key?(:sys.get_state(feed), :redial_timer)
    end

    test "a crash hard on the heels of another waits before redialling" do
      # A route that crashed on start was redialled at once, crashed, and was redialled
      # again: a connect storm with no delay anywhere in it. The first crash of a run still
      # redials at once (above); the second, within a minute of it, waits 1s.
      socket = fake_socket()

      feed =
        start_feed(
          socket: socket,
          plug: responding(%{"error" => "unauthorized"}, 401),
          retry_attempts: 0
        )

      :ok = Feed.subscribe(feed, ["AAPL"])
      :ok = Feed.subscribe_notices(feed, to: self())
      link_socket_into_feed(feed, socket)
      Process.exit(socket, :kill)

      # The first crash's own notice, taken here so the second crash's is the one read below.
      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :link_down, message: "route crashed" <> _rest = first}},
                     5_000

      assert first =~ "reconnecting now"

      # The first crash's immediate redial lands on the poll route.
      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :degraded, details: %{fallback: :internal_poll}}},
                     5_000

      poller = :sys.get_state(feed).poller
      assert is_pid(poller)

      started = System.monotonic_time(:millisecond)
      Process.exit(poller, :kill)

      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :link_down, message: "route crashed" <> _rest = message}},
                     5_000

      assert message =~ "reconnecting in 1000 ms"

      # Nothing dialled yet: no route, no bootstrap in flight, a redial scheduled.
      scheduled = :sys.get_state(feed)
      assert scheduled.route == nil
      assert scheduled.route_bootstrap == nil
      assert {_ref, _timer} = scheduled.redial_timer

      # The redial lands on the poll route again, and not before the delay. A LOWER bound,
      # which load can only lengthen.
      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :degraded, details: %{fallback: :internal_poll}}},
                     5_000

      assert System.monotonic_time(:millisecond) - started >= 1_000
    end

    test "a redial message that is not the current one does nothing" do
      socket = fake_socket()

      feed =
        start_feed(
          socket: socket,
          plug: responding(%{"error" => "unauthorized"}, 401),
          retry_attempts: 0
        )

      :ok = Feed.subscribe(feed, ["AAPL"])

      # Something wanted and no route, so a stale message that DID redial would start a
      # bootstrap. It must not.
      :sys.replace_state(feed, fn state ->
        %{state | socket: nil, route: nil, wanted: MapSet.new(["AAPL"])}
      end)

      send(feed, {:redial_after_crash, make_ref()})

      state = :sys.get_state(feed)
      assert state.route == nil
      assert state.route_bootstrap == nil
    end

    test "a pending redial finds nothing wanted if everything was unsubscribed meanwhile" do
      # `wanted` is judged again when the timer fires, not only when the crash was handled.
      socket = fake_socket()

      feed =
        start_feed(
          socket: socket,
          plug: responding(%{"error" => "unauthorized"}, 401),
          retry_attempts: 0
        )

      :ok = Feed.subscribe(feed, ["AAPL"])
      :ok = Feed.subscribe_notices(feed, to: self())
      link_socket_into_feed(feed, socket)
      Process.exit(socket, :kill)

      # The first crash's own notice, taken here so the second crash's is the one read below.
      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :link_down, message: "route crashed" <> _rest}},
                     5_000

      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :degraded, details: %{fallback: :internal_poll}}},
                     5_000

      Process.exit(:sys.get_state(feed).poller, :kill)

      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :link_down, message: "route crashed" <> _rest = second}},
                     5_000

      assert second =~ "reconnecting in"

      {ref, _timer} = :sys.get_state(feed).redial_timer
      :ok = Feed.unsubscribe(feed, ["AAPL"])

      # The timer's own message, delivered by hand so the test does not wait for it.
      send(feed, {:redial_after_crash, ref})

      state = :sys.get_state(feed)
      assert state.route == nil
      assert state.route_bootstrap == nil
      refute Map.has_key?(state, :redial_timer)
    end

    test "a crashed POLLER is isolated too, not only a crashed socket" do
      # `Feed` has two `{:EXIT, pid, reason}` clauses — one matching `state.socket`, one
      # matching `state.poller` — and only the socket one had ever executed. The poll route
      # is this venue's documented degraded mode, so the untested clause is the one that runs
      # when the venue is ALREADY not serving the Streamer.
      #
      # Both call `isolate_crashed_route/2`, which clears the route and retries from scratch.
      # Without the clause the `:EXIT` would reach the catch-all and be ignored, leaving a
      # feed whose `route` still says `:internal_poll` while the process doing the polling is
      # gone — coverage answering for a route nobody is serving, which is the same
      # truthfulness question the socket-crash test above asks.
      feed =
        start_feed(
          plug: responding(%{"error" => "unauthorized"}, 401),
          retry_attempts: 0
        )

      # The route is bootstrapped lazily, on the first thing that needs one.
      :ok = Feed.subscribe(feed, ["AAPL"])

      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :degraded, details: %{fallback: :internal_poll}}},
                     5_000

      poller = :sys.get_state(feed).poller
      assert is_pid(poller), "the poll route must actually be served by a process"
      assert %{route: :internal_poll} = Feed.status(feed)

      Process.exit(poller, :kill)

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :link_down}}, 5_000
      assert Process.alive?(feed), "one dead poller must not take the feed with it"

      # Retried rather than left dead: the same refusing plug can only land it back on the
      # poll route, and arriving there again is what proves the clause ran.
      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :degraded, details: %{fallback: :internal_poll}}},
                     5_000

      refute :sys.get_state(feed).poller == poller,
             "the replacement route must not be the process that just died"
    end

    test "a crash cancels a redial still pending from an earlier one" do
      feed = start_feed(plug: responding(%{"error" => "unauthorized"}, 401), retry_attempts: 0)
      :ok = Feed.subscribe(feed, ["AAPL"])

      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :degraded, details: %{fallback: :internal_poll}}},
                     5_000

      # A redial armed far beyond the test, so it is still pending whatever the load. Two
      # live redial timers would dial two routes against a venue that allows one connection.
      timer = Process.send_after(self(), :stale_redial, 600_000)
      :sys.replace_state(feed, &Map.put(&1, :redial_timer, {make_ref(), timer}))

      Process.exit(:sys.get_state(feed).poller, :kill)
      assert_receive {:dp_exchange, :schwab, %Notice{kind: :link_down}}, 5_000

      assert Process.read_timer(timer) == false
      refute_received :stale_redial
    end

    test "a redial that fires after another path already dialled a route does nothing" do
      feed = start_feed(plug: responding(%{"error" => "unauthorized"}, 401), retry_attempts: 0)
      :ok = Feed.subscribe(feed, ["AAPL"])

      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :degraded, details: %{fallback: :internal_poll}}},
                     5_000

      poller = :sys.get_state(feed).poller
      ref = make_ref()
      :sys.replace_state(feed, &Map.put(&1, :redial_timer, {ref, make_ref()}))

      # The timer's own message, delivered by hand: a route already stands, so dialling again
      # would open a second connection beside it.
      send(feed, {:redial_after_crash, ref})

      state = :sys.get_state(feed)
      assert state.poller == poller
      assert state.route_bootstrap == nil
      refute Map.has_key?(state, :redial_timer)
    end

    test "a TRANSPORT drop clears coverage too, not only a route crash" do
      # The test above kills the socket process. This one is the case that was missed:
      # `Socket.handle_disconnect/2` returns `{:reconnect, …}`, so a transport drop leaves
      # the socket process ALIVE, no `:EXIT` reaches `isolate_crashed_route/2`, and until
      # this the delivery records from the dead connection went on answering `:stream` —
      # indefinitely, where the reconnect came back but the venue silently failed to restore
      # a symbol. `Socket` already clears `logged_in?` and its `subscriptions` on the same
      # event, for the same reason one level down.
      feed = start_feed(socket: fake_socket())
      :ok = Feed.subscribe(feed, ["AAPL"])

      send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      assert_receive {:dp_exchange, :schwab, %Types.Quote{}}, 5_000
      assert Feed.coverage(feed) == %{"AAPL" => :stream}

      send(feed, {:dp_exchange, :schwab, Notice.new(:link_down, :schwab)})

      assert Feed.coverage(feed) == %{}
      assert Feed.coverage_by_kind(feed) == %{}

      # The route is untouched — that socket is reconnecting rather than dead, and clearing
      # it here would make `ensure_route/1` dial a second one. Coverage refills as frames
      # arrive after the re-LOGIN and resubscribe.
      send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      assert_receive {:dp_exchange, :schwab, %Types.Quote{}}, 5_000
      assert Feed.coverage(feed) == %{"AAPL" => :stream}
      assert %{route: :stream} = Feed.status(feed)
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

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(feed, :resubscribe)
          # A synchronous call forces the cast above to be processed before this returns.
          Feed.coverage(feed)
        end)

      assert subscribed_services(socket) == %{
               "LEVELONE_EQUITIES" => ["AAPL", "AAPL"],
               "CHART_EQUITY" => ["AAPL", "AAPL"]
             }

      # The negative control for the failure log added beside this test. A re-assert that
      # WORKED must say nothing: this timer fires on every interval for the life of the
      # feed, so a line here would be one per tick forever. `dp_exchange_webull`'s issue #2
      # is what that costs — 234 of 239 ERROR lines in one boot describing routine
      # behaviour, until ERROR stopped carrying information on that host.
      refute log =~ "re-assert", "a successful re-assert must be silent"
    end

    test "a successful re-login re-asserts at once, without waiting for the timer" do
      # On the timer alone a reconnected Streamer carried nothing for up to 60s — see the
      # moduledoc's "A re-login re-asserts at once; the timer is the net".
      socket = fake_socket()
      feed = start_feed(socket: socket)
      :ok = Feed.subscribe(feed, ["AAPL"])

      send(feed, {:dp_exchange, :schwab, :relogged_in, socket})
      Feed.coverage(feed)

      assert subscribed_services(socket) == %{
               "LEVELONE_EQUITIES" => ["AAPL", "AAPL"],
               "CHART_EQUITY" => ["AAPL", "AAPL"]
             }
    end

    test "a re-login report from a socket this feed no longer holds changes nothing" do
      socket = fake_socket()
      feed = start_feed(socket: socket)
      :ok = Feed.subscribe(feed, ["AAPL"])

      send(feed, {:dp_exchange, :schwab, :relogged_in, spawn(fn -> :ok end)})
      Feed.coverage(feed)

      assert subscribed_services(socket) == %{
               "LEVELONE_EQUITIES" => ["AAPL"],
               "CHART_EQUITY" => ["AAPL"]
             }
    end

    test "a re-assert that cannot reach a route says so, rather than failing silently" do
      # `apply_symbols/1` answers `:ok`, `{:error, :no_route}`, or whatever
      # `PollingFeed.update_symbols/2` answers — and this handler threw that away. A
      # periodic re-assert is the only thing that recovers a subscription the venue has
      # quietly stopped serving, so one that cannot run is exactly the event worth knowing
      # about; `dp_exchange_webull` spent three issues on a blind resubscribe that failed
      # without saying so.
      #
      # `route: :stream` with no socket is the reachable shape: `apply_symbols/1`'s stream
      # clause is guarded `when is_pid(socket)`, so anything else falls to
      # `{:error, :no_route}`.
      feed = start_feed(socket: fake_socket())
      :ok = Feed.subscribe(feed, ["AAPL"])

      :sys.replace_state(feed, fn state -> %{state | socket: nil} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(feed, :resubscribe)
          Feed.coverage(feed)
        end)

      assert log =~ "re-assert", "the failure must reach a log line, not be discarded"
      assert log =~ "no_route"
      assert Process.alive?(feed), "and it must not take the feed down"
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
      assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded}}, 5_000
      poller = :sys.get_state(feed).poller

      send(feed, :resubscribe)
      Feed.coverage(feed)

      # The tick neither replaces the poller nor re-plans its symbols: both stay as they were.
      assert %{route: :internal_poll} = Feed.status(feed)
      assert :sys.get_state(feed).poller == poller
      assert Feed.wanted(feed) == ["AAPL"]
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
      assert_receive {:dp_exchange, :schwab, %Types.Quote{}}, 5_000

      assert Feed.unsubscribe(feed, ["AAPL"]) == :ok
      assert Feed.wanted(feed) == ["MSFT"]
      assert Feed.coverage(feed) == %{}
    end

    test "unsubscribing the last symbol tells the socket its services want nothing" do
      # Grouping only what is wanted sent nothing at all once nothing was wanted, so the
      # venue kept streaming the last symbol until a reconnect.
      test_pid = self()

      socket =
        spawn(fn ->
          Stream.repeatedly(fn -> receive(do: (message -> send(test_pid, message))) end)
          |> Stream.run()
        end)

      on_exit(fn -> Process.exit(socket, :kill) end)
      feed = start_feed(socket: socket)

      Feed.subscribe(feed, ["AAPL"])
      # One cast carrying every service — the Streamer fails parallel commands (code 22).
      assert_receive {:"$websockex_cast", {:subscribe_all, batch}}, 5_000
      assert {"LEVELONE_EQUITIES", "SUBS", ["AAPL"], []} in batch

      assert Feed.unsubscribe(feed, ["AAPL"]) == :ok

      assert_receive {:"$websockex_cast", {:subscribe_all, emptied}}, 5_000
      assert {"LEVELONE_EQUITIES", "SUBS", [], []} in emptied
      assert {"CHART_EQUITY", "SUBS", [], []} in emptied
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

      assert_receive {:dp_exchange, :schwab, {:refused, "AAPL", :delisted}}, 5_000
      assert Feed.coverage(feed) == %{}
    end

    test "notices reach a notice subscriber without the data channel" do
      feed = start_feed(socket: fake_socket())
      parent = self()
      watcher = spawn(fn -> relay(parent) end)

      assert Feed.subscribe_notices(feed, to: watcher) == :ok
      send(feed, {:dp_exchange, :schwab, Notice.new(:link_up, :schwab)})

      assert_receive {:relayed, {:dp_exchange, :schwab, %Notice{kind: :link_up}}}, 5_000
    end

    test "a value with no symbol is delivered and does not enter coverage" do
      # `ACCT_ACTIVITY` and anything else without a symbol still reaches the subscriber.
      # Coverage is per symbol, so there is nothing to record — and inventing a key for it
      # would report a symbol nobody subscribed to.
      feed = start_feed(socket: fake_socket())

      send(feed, {:dp_exchange, :schwab, %{account: "123", event: "OrderFill"}})

      assert_receive {:dp_exchange, :schwab, %{event: "OrderFill"}}, 5_000
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

      assert_receive {:dp_exchange, :schwab, %{event: "OrderFill"}}, 5_000
      assert Process.alive?(feed)

      Process.unregister(name)
    end

    test "a name that is not (or no longer) registered is silently skipped, not a crash" do
      name = :"schwab_feed_test_unregistered_#{System.unique_integer([:positive])}"
      refute Process.whereis(name)
      feed = start_feed(socket: fake_socket())

      Feed.subscribe(feed, ["AAPL"], to: name)
      send(feed, {:dp_exchange, :schwab, %{account: "123", event: "OrderFill"}})

      # A call queued behind the event is answered only once the event has been handled,
      # so this proves the fan-out to a missing name ran and was survived. A sleep proved
      # only that 20 ms had passed.
      assert is_map(Feed.coverage(feed))
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

      new_credentials = Map.put(credentials(), :access_token, "fresh-token")
      assert Feed.update_credentials(feed, new_credentials) == :ok

      assert_receive {:relayed_to_socket,
                      {:"$websockex_cast",
                       {:update_access_token,
                        %DpExchange.Schwab.Credentials{access_token: "fresh-token"}}}},
                     5_000
    end

    test "a blank or padded token is kept out of the socket's LOGIN" do
      # `Auth.headers/2` refuses such a token, so a `LOGIN` carrying it would be a refused
      # credential nobody could name. The feed still accepts the credentials themselves.
      socket = relaying_fake_socket(self())
      feed = start_feed(socket: socket)
      Feed.subscribe(feed, ["AAPL"])

      for unusable <- ["  ", " padded-token "] do
        assert Feed.update_credentials(feed, Map.put(credentials(), :access_token, unusable)) ==
                 :ok
      end

      # The socket is written to in order, so once the later, usable token has arrived an
      # earlier unusable one would have arrived before it.
      assert Feed.update_credentials(feed, Map.put(credentials(), :access_token, "fresh")) == :ok

      assert_receive {:relayed_to_socket,
                      {:"$websockex_cast",
                       {:update_access_token,
                        %DpExchange.Schwab.Credentials{access_token: "fresh"}}}},
                     5_000

      # The cast carries a `Credentials` struct, never a bare string, so a refute shaped on the
      # string could not match anything and could not fail. Match the struct, and the tokens.
      refute_received {:relayed_to_socket,
                       {:"$websockex_cast",
                        {:update_access_token, %DpExchange.Schwab.Credentials{access_token: "  "}}}}

      refute_received {:relayed_to_socket,
                       {:"$websockex_cast",
                        {:update_access_token,
                         %DpExchange.Schwab.Credentials{access_token: " padded-token "}}}}
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

      new_credentials = Map.put(credentials(), :access_token, "fresh-token")
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

      assert_receive {:dp_exchange, :schwab, %Types.Quote{symbol: "AAPL"}}, 5_000
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
      assert_receive {:dp_exchange, :schwab, %Types.Quote{symbol: "AAPL"}}, 5_000
      :ok = Feed.subscribe_notices(feed, to: self())

      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}, 5_000

      :sys.replace_state(feed, fn state -> %{state | poller: dead} end)

      # All three reads answer instead of exiting, and none of them invents coverage.
      assert Feed.coverage(feed) == %{}
      assert Feed.coverage_by_kind(feed) == %{quotes: %{}}

      status = Feed.status(feed)
      assert status.delivering == false
      assert status.wanted == 1
      assert status.covered == 0
      assert status.failures_since_ok == 0
      assert status.last_error == :poller_unresponsive
      assert status.route == :internal_poll

      assert Process.alive?(feed)

      # An empty map alone is indistinguishable from a venue delivering nothing. The notice
      # is what says "we could not ask", which is a different fact about the world.
      assert_receive {:dp_exchange, :schwab, %{kind: :link_down} = notice}, 5_000
      assert notice.severity == :warning
      assert notice.message =~ "did not answer a read"
      # `details.reason` is an atom; the exit it caught is bounded text in `details.message`.
      assert notice.details.reason == :poller_unresponsive
      assert is_binary(notice.details.message)
    end

    test "the poll route's :link_down is closed by one :link_up on the first good poll" do
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
      assert_receive {:dp_exchange, :schwab, %Types.Quote{symbol: "AAPL"}}, 5_000
      :ok = Feed.subscribe_notices(feed, to: self())
      refute :sys.get_state(feed).link_down_open

      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}, 5_000
      :sys.replace_state(feed, fn state -> %{state | poller: dead} end)

      # One unanswered read: the `:link_down`. The real poller is still ticking, so its next
      # good poll must close it. (No further read of `coverage/1` or `status/1` here: each
      # would be unanswered again and open a new `:link_down`.)
      assert Feed.coverage(feed) == %{}
      assert_receive {:dp_exchange, :schwab, %Notice{kind: :link_down}}, 5_000

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :link_up, provider: :schwab}}, 5_000
      refute :sys.get_state(feed).link_down_open

      # Latched: a later good poll says nothing more.
      tag = :sys.get_state(feed).poll_tag
      send(feed, {:dp_exchange, :schwab, {:polled, tag, quote_for("AAPL")}})
      _state = :sys.get_state(feed)
      refute_received {:dp_exchange, :schwab, %Notice{kind: :link_up}}
    end

    test "a Socket :link_up closes the open :link_down, so the poll clause does not repeat it" do
      # Nothing subscribed, so no route is dialled: the latch is the only thing in play.
      feed = start_feed(retry_attempts: 0)

      :ok = Feed.subscribe_notices(feed, to: self())
      :sys.replace_state(feed, fn state -> %{state | link_down_open: true} end)

      send(feed, {:dp_exchange, :schwab, Notice.new(:link_up, :schwab)})
      assert_receive {:dp_exchange, :schwab, %Notice{kind: :link_up}}, 5_000
      refute :sys.get_state(feed).link_down_open
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

      assert_receive {:dp_exchange, :schwab, %Types.Quote{symbol: "AAPL"}}, 5_000

      by_kind = Feed.coverage_by_kind(feed)

      assert by_kind == %{quotes: %{"AAPL" => :internal_poll}}
      refute Map.has_key?(by_kind, :order_book)

      assert_union_matches_coverage(feed, by_kind)
      assert_declared_streamable(by_kind)
    end
  end

  describe "a dead subscriber is dropped, not walked forever" do
    # `Core.Fanout.resolve/1` already skipped a dead subscriber at send time, so no EVENTS
    # accumulated — but nothing removed the pid, so a supervised consumer that restarts left
    # one behind on every restart, for the life of this feed. `deliver/4` walks the whole set
    # calling `Process.alive?/1` once per message, so the cost was linear in uptime: measured
    # in Core 0.3.3 at 0.095 us per fan-out against a clean set and 22.8 us against one
    # carrying a thousand dead pids. This venue's Streamer pushes every quote through
    # the same set, and its fallback poll uses it too.
    test "a subscriber that dies is removed from the subscriber set" do
      feed = start_feed(socket: fake_socket())
      subscriber = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Feed.subscribe(feed, ["AAPL"], to: subscriber)
      assert MapSet.member?(:sys.get_state(feed).subscribers, subscriber)

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, _reason}, 5_000

      # A call is answered only after the feed's own `:DOWN` has been handled.
      _settled = Feed.coverage(feed)

      state = :sys.get_state(feed)
      refute MapSet.member?(state.subscribers, subscriber)
      refute Map.has_key?(state.monitors, subscriber)
    end

    test "a notice subscriber that dies is removed too" do
      feed = start_feed(socket: fake_socket())
      watcher = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Feed.subscribe_notices(feed, to: watcher)
      assert MapSet.member?(:sys.get_state(feed).notice_subscribers, watcher)

      ref = Process.monitor(watcher)
      Process.exit(watcher, :kill)
      assert_receive {:DOWN, ^ref, :process, ^watcher, _reason}, 5_000
      _settled = Feed.coverage(feed)

      refute MapSet.member?(:sys.get_state(feed).notice_subscribers, watcher)
    end

    test "a REGISTERED NAME is never monitored, and survives its holder dying" do
      # The half that must not be pruned. A name is not a process: `subscribe/2` accepts one
      # precisely so a consumer can restart under it, and pruning when the current holder
      # dies would silently unsubscribe a consumer whose supervisor is about to bring it
      # straight back — data loss with nothing to notice it by.
      feed = start_feed(socket: fake_socket())
      name = :"named_subscriber_#{System.unique_integer([:positive])}"
      holder = spawn(fn -> Process.sleep(:infinity) end)
      Process.register(holder, name)

      :ok = Feed.subscribe(feed, ["AAPL"], to: name)
      assert :sys.get_state(feed).monitors == %{}

      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, _reason}, 5_000
      _settled = Feed.coverage(feed)

      assert MapSet.member?(:sys.get_state(feed).subscribers, name)
    end

    test "subscribing twice from one pid monitors it once" do
      # Each monitor delivers its own `:DOWN`, so stacking them means N-1 messages nothing
      # will match.
      feed = start_feed(socket: fake_socket())
      subscriber = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(subscriber, :kill) end)

      :ok = Feed.subscribe(feed, ["AAPL"], to: subscriber)
      first = :sys.get_state(feed).monitors

      :ok = Feed.subscribe(feed, ["MSFT"], to: subscriber)
      :ok = Feed.subscribe_notices(feed, to: subscriber)

      assert :sys.get_state(feed).monitors == first
      assert map_size(first) == 1
    end
  end

  describe "a frame arriving after unsubscribe" do
    test "is neither delivered nor counted as coverage" do
      # The venue keeps sending for a moment after an unsubscribe. Such a frame used to
      # reach subscribers and re-enter delivery tracking, and a streaming route has no
      # staleness window, so `coverage/1` answered `:stream` for it indefinitely.
      feed = start_feed(socket: fake_socket(), subscriber: self(), symbols: ["AAPL"])

      send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      assert_receive {:dp_exchange, :schwab, %{symbol: "AAPL"}}, 5_000
      assert Feed.coverage(feed) == %{"AAPL" => :stream}

      # `:no_route` here only means this test's feed has no live route; the set changed.
      _reply = Feed.unsubscribe(feed, ["AAPL"])
      assert Feed.wanted(feed) == []
      send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})

      assert Feed.coverage(feed) == %{}
      refute_received {:dp_exchange, :schwab, %{symbol: "AAPL"}}
    end
  end

  describe "back-pressure — a slow subscriber does not get an unbounded mailbox" do
    # `Core.Venue`'s `subscribe/2` doc promised this from the day the contract was written,
    # and no venue in this family implemented any of it: every one fanned out with a bare
    # `send/2` and had never looked at a subscriber's mailbox. A consumer that stalls
    # accumulated a mailbox until the node died, with no notice, no log line, and
    # `coverage/1` reporting perfect health throughout — because the feed genuinely was
    # delivering. Implemented in `Core.Fanout` 0.2.6 and wired here.

    # A subscriber that never consumes, so everything sent to it stays queued.
    defp stalled_subscriber do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    defp queued(pid) do
      {:message_queue_len, len} = Process.info(pid, :message_queue_len)
      len
    end

    test "past its bound, a subscriber stops being sent to and its mailbox stops growing" do
      slow = stalled_subscriber()

      feed =
        start_feed(socket: fake_socket(), subscriber: slow, symbols: ["AAPL"], max_queue_len: 3)

      for _each <- 1..10, do: send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      # A call is answered only after every send above has been handled.
      _settled = Feed.coverage(feed)

      # Three payloads got through, then the bound stopped it — not ten, and, the point,
      # not unbounded. The fourth message is the `:degraded` notice announcing the drop:
      # this venue puts its data subscriber in `notice_subscribers` at `init/1`, so the same
      # pid gets both. That it arrives at all is the property, not an accident — notices are
      # deliberately NOT subject to the bound, because the notice saying a subscriber is
      # being dropped must not be the first casualty of that same subscriber being dropped.
      assert queued(slow) == 4
    end

    test "a stalled subscriber is reported once, not once per dropped message" do
      slow = stalled_subscriber()

      feed =
        start_feed(socket: fake_socket(), subscriber: slow, symbols: ["AAPL"], max_queue_len: 1)

      :ok = Feed.subscribe_notices(feed, to: self())

      for _each <- 1..2, do: send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      _settled = Feed.coverage(feed)

      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :degraded, severity: :warning, details: details}},
                     5_000

      assert details.bound == 1
      assert details.dropping == :newest
      assert details.subscriber == inspect(slow)

      # A notice per dropped message would arrive at the rate of the stream the consumer
      # already cannot keep up with, into the same fan-out that is overloaded.
      for _each <- 1..5, do: send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})

      # A reply from the feed is sent after everything it sent this process before it, and
      # both come from the one process, so no notice can still be on its way once this
      # returns. `refute_received` is exact here where a timed wait only guessed.
      _settled = Feed.coverage(feed)
      refute_received {:dp_exchange, :schwab, %Notice{kind: :degraded}}
    end

    test "a symbol whose frames are dropped for a slow consumer is still covered" do
      # `coverage/1` reports what the VENUE delivered to this package, not what this package
      # forwarded. Reporting `:not_covered` here would blame the venue for a consumer's own
      # backlog, and send an operator looking at the wrong system entirely.
      slow = stalled_subscriber()

      feed =
        start_feed(socket: fake_socket(), subscriber: slow, symbols: ["AAPL"], max_queue_len: 1)

      for _each <- 1..5, do: send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})

      assert Feed.coverage(feed) == %{"AAPL" => :stream}
    end

    test "an invalid bound fails at init, loudly, rather than falling back to the default" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Feed.start_link(
                 name: nil,
                 credentials: credentials(),
                 subscriber: self(),
                 max_queue_len: "3"
               )

      assert message =~ ":schwab"
      assert message =~ ":max_queue_len"
    end
  end

  describe "coverage_by_kind on the stream route" do
    test "a symbol delivering only a Quote is :quotes, never :order_book" do
      feed = start_feed(socket: fake_socket())
      Feed.subscribe(feed, ["AAPL"])

      send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      assert_receive {:dp_exchange, :schwab, %Types.Quote{}}, 5_000

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
      assert_receive {:dp_exchange, :schwab, %Types.Candle{}}, 5_000

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
      assert_receive {:dp_exchange, :schwab, %Types.Quote{}}, 5_000
      assert_receive {:dp_exchange, :schwab, %Types.Candle{}}, 5_000

      by_kind = Feed.coverage_by_kind(feed)

      assert by_kind == %{quotes: %{"AAPL" => :stream}, candles: %{"MSFT" => :stream}}

      assert_union_matches_coverage(feed, by_kind)
      assert_declared_streamable(by_kind)
    end

    test "one symbol delivering several kinds keeps each, and a repeated kind adds nothing" do
      feed = start_feed(socket: fake_socket())
      Feed.subscribe(feed, ["AAPL"])

      top =
        Types.TopOfBook.new(symbol: "AAPL", observed_at: DateTime.utc_now(), provider: :schwab)

      send(feed, {:dp_exchange, :schwab, top})
      assert_receive {:dp_exchange, :schwab, %Types.TopOfBook{}}, 5_000
      assert Feed.coverage_by_kind(feed) == %{top_of_book: %{"AAPL" => :stream}}

      # A second kind for the same symbol joins the first; the same kind again changes nothing.
      send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      assert_receive {:dp_exchange, :schwab, %Types.Quote{}}, 5_000
      assert_receive {:dp_exchange, :schwab, %Types.Quote{}}, 5_000

      by_kind = Feed.coverage_by_kind(feed)

      assert by_kind == %{top_of_book: %{"AAPL" => :stream}, quotes: %{"AAPL" => :stream}}
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
      assert_receive {:dp_exchange, :schwab, %Types.OrderBook{}}, 5_000

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

    # An empty SUBS is "nothing wanted here", which `Socket` sends as an `UNSUBS` of what its
    # session holds, or not at all. It subscribes nothing, so it is not counted here.
    for {:"$websockex_cast", {:subscribe_all, batch}} <- messages,
        {service, "SUBS", [_first | _rest] = keys, _opts} <- batch,
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

  defp relay(parent) do
    receive do
      message ->
        send(parent, {:relayed, message})
        relay(parent)
    end
  end

  describe "init without a subscriber, refused symbols and stale poll deliveries" do
    test "a feed started without :subscriber does not subscribe itself" do
      # `self()` in `init/1` is the Feed: a self-subscribed Feed re-delivered every message
      # to its own mailbox, forever.
      assert {:ok, state} = Feed.init([])
      assert MapSet.size(state.subscribers) == 0
      assert state.subscriber == nil
    end

    test "a symbol the REST route refuses is refused by subscribe and update_symbols too" do
      feed = start_feed(socket: fake_socket())

      assert Feed.subscribe(feed, ["AAPL", "BTC-USD"]) ==
               {:error, {:invalid_symbols, ["AAPL", "BTC-USD"]}}

      assert Feed.update_symbols(feed, ["BTC-USD"]) == {:error, {:invalid_symbols, ["BTC-USD"]}}
      assert Feed.wanted(feed) == []
    end

    test "a poll quote from a poller no longer serving the route is dropped, not counted" do
      feed = start_feed(socket: fake_socket())
      assert Feed.subscribe(feed, ["AAPL"]) == :ok

      send(feed, {:dp_exchange, :schwab, {:polled, make_ref(), quote_for("AAPL")}})

      # The call is the fence: the feed has handled the stale delivery before it answers,
      # and anything it forwarded to this process was sent before that answer.
      assert Feed.coverage(feed) == %{}
      refute_received {:dp_exchange, :schwab, %Types.Quote{}}
    end
  end

  describe "the wanted set is spelled the way the venue delivers" do
    # `SymbolFormat.validate/1` trims and upper-cases, so a padded or lower-case symbol was
    # accepted and sent to the Streamer as `AAPL` while `wanted` kept the caller's spelling.
    # Every frame then arrived as `AAPL`, matched nothing in `wanted`, and was dropped.
    test "a padded lower-case subscription still receives the venue's upper-case symbol" do
      feed = start_feed(socket: fake_socket())
      assert Feed.subscribe(feed, [" aapl "]) == :ok
      assert Feed.wanted(feed) == ["AAPL"]

      send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      assert_receive {:dp_exchange, :schwab, %Types.Quote{symbol: "AAPL"}}, 5_000
      assert Feed.coverage(feed) == %{"AAPL" => :stream}
    end

    test "unsubscribe removes a symbol however the caller spells it" do
      feed = start_feed(socket: fake_socket())
      assert Feed.subscribe(feed, ["AAPL", "MSFT"]) == :ok
      assert Feed.unsubscribe(feed, [" msft"]) == :ok

      assert Feed.wanted(feed) == ["AAPL"]
    end

    test "symbols given at start are normalised too" do
      feed = start_feed(socket: fake_socket(), symbols: ["aapl"])

      assert Feed.wanted(feed) == ["AAPL"]
    end
  end

  describe "a symbol argument that is not a list" do
    # `for symbol <- 5` and `MapSet.new(5)` raised inside `handle_call/3`, killing the feed.
    # It restarted from the supervisor's boot-time options, so every consumer's subscription
    # and every credential pushed by `update_credentials/2` was gone.
    test "is refused by name and leaves the feed, and what it holds, alone" do
      feed = start_feed(socket: fake_socket())
      assert Feed.subscribe(feed, ["AAPL"]) == :ok

      for bad <- [:AAPL, "AAPL", 5, nil, %{}] do
        assert Feed.subscribe(feed, bad) == {:error, {:invalid_symbols, bad}}
        assert Feed.unsubscribe(feed, bad) == {:error, {:invalid_symbols, bad}}
        assert Feed.update_symbols(feed, bad) == {:error, {:invalid_symbols, bad}}
      end

      assert Process.alive?(feed)
      assert Feed.wanted(feed) == ["AAPL"]
    end
  end

  describe "a feed with nothing wanted dials nothing" do
    test "unsubscribing before any route exists is :ok, not :no_route" do
      feed = start_feed([])

      assert Feed.unsubscribe(feed, ["AAPL"]) == :ok
      assert Feed.wanted(feed) == []
      assert %{route: nil} = Feed.status(feed)
    end

    test "a route that crashes after the last symbol left is not redialled" do
      socket = fake_socket()

      exploding = fn _conn -> raise "a route nobody asked for was dialled" end
      feed = start_feed(socket: socket, plug: exploding, retry_attempts: 0)

      :ok = Feed.subscribe(feed, ["AAPL"])
      _applied = Feed.unsubscribe(feed, ["AAPL"])
      assert Feed.wanted(feed) == []

      :sys.replace_state(feed, fn state ->
        Process.link(socket)
        state
      end)

      Process.exit(socket, :kill)

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :link_down}}, 5_000

      state = :sys.get_state(feed)
      assert state.route == nil
      assert state.route_bootstrap == nil
      assert state.poller == nil
      assert Process.alive?(feed)
    end
  end

  describe "symbols given at start are validated like every later call" do
    # `symbols: ["BTC-USD"]` skipped the equity-only refusal `subscribe/2` makes: it entered
    # `wanted` and was sent to the Streamer unchanged as an equities key.
    test "a pair the venue's REST route refuses stops the feed at start, by name" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Feed.start_link(
                 name: nil,
                 credentials: credentials(),
                 symbols: ["AAPL", "BTC-USD"]
               )

      assert message =~ "BTC-USD"
    end

    test "a non-list stops it too" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{}, _stack}} =
               Feed.start_link(name: nil, credentials: credentials(), symbols: :AAPL)
    end
  end
end
