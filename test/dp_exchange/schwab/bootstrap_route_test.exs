defmodule DpExchange.Schwab.BootstrapRouteTest do
  @moduledoc """
  What a caller gets while the Streamer bootstrap is still in flight.

  Two describes that share one risk: the bootstrap is the only thing in this feed that can
  take arbitrarily long, so everything reaching the feed during one is a chance to wedge a
  caller that had nothing to do with it. A read must still be answered, a second subscriber
  must not be forgotten, and a bootstrap that never returns must be timed out rather than
  waited on. Split out for wall clock — see `DpExchange.Schwab.FeedCase`.
  """

  use DpExchange.Schwab.FeedCase, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Schwab.Feed

  describe "the Streamer bootstrap cannot wedge every subscribe/2 caller" do
    # `start_route_bootstrap/2`'s "already in flight" clause makes every later `subscribe/2`
    # JOIN the waiting list of the bootstrap in progress, and the only clause that used to
    # clear `route_bootstrap` was the `{ref, result}` reply. So a bootstrap task that never
    # answers meant no `subscribe/2` ever returned again: each caller blocked until its own
    # `GenServer.call` timeout and then EXITED, taking the calling process with it, for the
    # life of the feed.
    #
    # Verified to wedge before the fix by driving both paths directly — a killed task left
    # `route_bootstrap` holding the dead ref, a second subscribe joined it, and neither
    # caller was ever replied to.

    test "a killed bootstrap task answers every waiting caller instead of stranding them" do
      # `fetch_user_preference/2` converts a raise or an `exit` inside the task into an
      # ordinary error result, and its comment says that stops waiting callers from never
      # being answered. It does — for those two. A kill is untrappable, so neither runs.
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:bootstrapping, self()})
        Process.sleep(:infinity)
        conn
      end

      feed = start_feed(plug: plug, limiter: permissive_limiter())

      spawn(fn -> send(test_pid, {:subscribed, Feed.subscribe(feed, ["AAPL"])}) end)
      assert_receive {:bootstrapping, task_pid}, 3_000

      Process.exit(task_pid, :kill)

      # The caller gets an answer rather than hanging to its own call timeout, and the
      # answer is this venue's documented degraded mode.
      assert_receive {:subscribed, _result}, 3_000
      assert :sys.get_state(feed).route_bootstrap == nil
      assert :sys.get_state(feed).route == :poll
      assert Process.alive?(feed)
    end

    test "a bootstrap that never returns is timed out, not waited on forever" do
      # The other half, and the one no `:DOWN` can catch: the task is perfectly alive, it
      # just never answers.
      #
      # The timeout is delivered as a message rather than waited out on a shortened budget.
      # Both of these tests used to set `route_bootstrap_timeout_ms:` to a tenth or a third
      # of a second and then `assert_receive` the plug reporting in — which is a race the
      # test sets up against itself: it demands the plug be REACHED while telling the feed
      # to give up before it might be. Under the full suite's parallelism the feed won it
      # about one run in ten, and the failure read as a mysterious flake in the feed rather
      # than as the contradiction in the test that it was. (Measured while chasing it: the
      # FIRST `Req` request in a VM takes ~108 ms just to reach its plug — module loading and
      # pool setup, paid once — so alone in a fresh VM these lost even without contention.)
      # Driving the timer directly is
      # deterministic, costs no wall clock at all, and exercises the same clause — the
      # arming itself is covered separately, below, by a test that does NOT also require
      # the plug to have been reached.
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:bootstrapping, self()})
        Process.sleep(:infinity)
        conn
      end

      feed = start_feed(plug: plug, limiter: permissive_limiter())

      spawn(fn -> send(test_pid, {:subscribed, Feed.subscribe(feed, ["AAPL"])}) end)
      assert_receive {:bootstrapping, task_pid}, 3_000

      %{ref: ref} = :sys.get_state(feed).route_bootstrap
      send(feed, {:route_bootstrap_timeout, ref})

      assert_receive {:subscribed, _result}, 3_000
      assert :sys.get_state(feed).route_bootstrap == nil

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded} = notice}, 3_000
      assert notice.details.reason =~ "bootstrap_timeout"
      assert notice.details.fallback == :internal_poll

      # The timed-out task is actually gone, not left running behind the feed's back.
      # Polled rather than slept: a fixed sleep here is a bet on how fast the VM reaps a
      # killed process, which is exactly the kind of guess this suite avoids elsewhere.
      refute_eventually_alive(task_pid)
      assert Process.alive?(feed)
    end

    # The other half of the split above: that the timer is really armed from
    # `route_bootstrap_timeout_ms`, end to end, without a `send/2` standing in for it.
    #
    # This one can afford a budget far shorter than a round trip precisely BECAUSE it makes
    # no claim about the plug. Whether the wedged plug was entered before the budget expired
    # or not, the feed must answer its caller and say why — so there is nothing here for a
    # slow schedule to break.
    test "callers waiting on a slow bootstrap are answered before their own call times out" do
      # The bootstrap may take 95s and a caller's `GenServer.call` gives up at 15s, so every
      # waiting caller used to EXIT. See `Feed`'s moduledoc, "A caller waiting on the
      # bootstrap is answered before its call times out". The bootstrap budget here is far
      # longer than the reply deadline, so only the reply deadline can answer in time.
      feed =
        start_feed(
          plug: fn conn ->
            Process.sleep(:infinity)
            conn
          end,
          limiter: permissive_limiter(),
          route_bootstrap_timeout_ms: 60_000,
          bootstrap_reply_ms: 200
        )

      callers =
        for symbol <- ["AAPL", "MSFT"] do
          Task.async(fn -> Feed.subscribe(feed, [symbol]) end)
        end

      for caller <- callers do
        assert {:ok, {:error, {:route_pending, 200}}} = Task.yield(caller, 2_000)
      end

      # Recorded, not refused: the symbols are wanted, and the bootstrap is still running.
      assert Enum.sort(Feed.wanted(feed)) == ["AAPL", "MSFT"]
      assert %{waiting: []} = :sys.get_state(feed).route_bootstrap
    end

    test "the timeout is armed from the configured budget, and names it" do
      feed =
        start_feed(
          plug: fn conn ->
            Process.sleep(:infinity)
            conn
          end,
          limiter: permissive_limiter(),
          route_bootstrap_timeout_ms: 50
        )

      test_pid = self()
      spawn(fn -> send(test_pid, {:subscribed, Feed.subscribe(feed, ["AAPL"])}) end)

      assert_receive {:subscribed, _result}, 3_000
      assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded} = notice}, 3_000

      # The budget is named, not merely applied — a consumer reading the notice has to be
      # able to tell a timeout at 50 ms from one at the 95-second default.
      assert notice.details.reason == "{:bootstrap_timeout, 50}"
      assert :sys.get_state(feed).route_bootstrap == nil
      assert Process.alive?(feed)
    end

    test "a SECOND subscriber parked on a wedged bootstrap is answered too" do
      # The one that made this the worst wedge in the package: the waiting list is what every
      # later caller joins, so stranding it strands all of them, not just the first.
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:bootstrapping, self()})
        Process.sleep(:infinity)
        conn
      end

      feed = start_feed(plug: plug, limiter: permissive_limiter())

      spawn(fn -> send(test_pid, {:first, Feed.subscribe(feed, ["AAPL"])}) end)
      assert_receive {:bootstrapping, _task_pid}, 3_000

      spawn(fn -> send(test_pid, {:second, Feed.subscribe(feed, ["MSFT"])}) end)

      # Both callers are on the waiting list before the timer is fired, which is the whole
      # point: the second joined a bootstrap that was already in flight.
      wait_for_waiting(feed, 2)

      %{ref: ref} = :sys.get_state(feed).route_bootstrap
      send(feed, {:route_bootstrap_timeout, ref})

      assert_receive {:first, _r1}, 3_000
      assert_receive {:second, _r2}, 3_000
      assert Process.alive?(feed)
    end

    # `Feed.subscribe/2` is a `GenServer.call/3` made from a spawned process, so "the second
    # caller has joined the waiting list" is not observable from the return value — it is
    # observable in the feed's own state, which is where this looks.
    defp wait_for_waiting(feed, count, waited \\ 0) do
      case :sys.get_state(feed).route_bootstrap do
        %{waiting: waiting} when length(waiting) >= count ->
          :ok

        _other when waited >= 2_000 ->
          flunk("only #{inspect(:sys.get_state(feed).route_bootstrap)} after 2000ms")

        _other ->
          Process.sleep(10)
          wait_for_waiting(feed, count, waited + 10)
      end
    end

    test "a timer left over from a bootstrap that already settled is ignored" do
      # The timeout is armed per attempt and matched on the stored ref, so one arriving for a
      # bootstrap that has since completed must not tear down whatever is running now.
      feed = start_feed(socket: fake_socket())
      :ok = Feed.subscribe(feed, ["AAPL"])

      send(feed, {:route_bootstrap_timeout, make_ref()})
      _settled = Feed.coverage(feed)

      assert Process.alive?(feed)
      assert :sys.get_state(feed).route_bootstrap == nil
    end

    defp refute_eventually_alive(pid, waited \\ 0) do
      cond do
        not Process.alive?(pid) -> :ok
        waited >= 2_000 -> flunk("#{inspect(pid)} was still alive after 2000ms")
        true -> Process.sleep(10) && refute_eventually_alive(pid, waited + 10)
      end
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
