defmodule DpExchange.Schwab.FeedInterleavingTest do
  @moduledoc """
  Orderings of `Feed`'s own messages that a real node can produce, each forced by hand.

  Nothing here depends on timing: the bootstrap is held open by a plug that waits for the
  test's `:release`, the poller is killed on purpose, and the late message is sent by hand.
  """

  use DpExchange.Schwab.FeedCase, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Schwab.Feed

  # Answers 503 to everything until the test switches it to `{:hang, test_pid}`, which holds a
  # `/userPreference` request open until the test releases it with `{:release, body, status}`.
  defp switchable do
    {:ok, agent} = Agent.start_link(fn -> {%{"error" => "unavailable"}, 503} end)

    plug = fn conn ->
      bootstrap? = String.contains?(conn.request_path, "userPreference")

      {body, status} =
        case Agent.get(agent, & &1) do
          {:hang, notify} when bootstrap? ->
            send(notify, {:hanging, self()})

            receive do
              {:release, body, status} -> {body, status}
            end

          {:hang, _notify} ->
            {%{"error" => "unavailable"}, 503}

          settled ->
            settled
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end

    {agent, plug}
  end

  # A feed on the fallback poll with an UPGRADE bootstrap held open, and its poller killed as
  # the SECOND crash inside a run, so the crash schedules a redial instead of redialling now.
  defp upgrade_in_flight_then_poller_crash do
    {agent, plug} = switchable()
    feed = start_feed(plug: plug, retry_attempts: 0)

    :ok = Feed.subscribe(feed, ["AAPL"])
    assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded}}, 5_000
    poller = :sys.get_state(feed).poller

    test_pid = self()
    Agent.update(agent, fn _answer -> {:hang, test_pid} end)
    send(feed, :resubscribe)
    assert_receive {:hanging, request}, 5_000
    assert %{upgrade?: true} = :sys.get_state(feed).route_bootstrap

    # A crash one second ago makes the next one run 2, whose delay is not 0.
    :sys.replace_state(feed, fn state ->
      Map.put(state, :crash_run, {1, System.monotonic_time(:millisecond)})
    end)

    Process.exit(poller, :kill)
    wait_until(fn -> :sys.get_state(feed).poller == nil end)

    state = :sys.get_state(feed)
    assert state.route == nil
    # Still the upgrade: a crash that joined it would have stripped the flag. (Whether the
    # one-second redial has fired yet is irrelevant: it does nothing while this is in flight.)
    assert %{upgrade?: true} = state.route_bootstrap

    {feed, poller, request}
  end

  test "an upgrade that fails after its poller crashed (delayed redial) falls back to a poll" do
    {feed, poller, request} = upgrade_in_flight_then_poller_crash()

    send(request, {:release, %{"error" => "unavailable"}, 503})

    wait_until(fn ->
      replacement = :sys.get_state(feed).poller
      is_pid(replacement) and replacement != poller and Process.alive?(replacement)
    end)

    assert %{route: :internal_poll} = Feed.status(feed)
    assert %{route: :poll} = :sys.get_state(feed)
  end

  test "that same upgrade failing with nothing wanted opens nothing" do
    {feed, _poller, request} = upgrade_in_flight_then_poller_crash()

    # No route, so this records the empty set and sends nothing.
    assert :ok = Feed.unsubscribe(feed, ["AAPL"])
    send(request, {:release, %{"error" => "unavailable"}, 503})

    wait_until(fn -> :sys.get_state(feed).route_bootstrap == nil end)

    state = :sys.get_state(feed)
    assert state.route == nil
    assert state.poller == nil
    assert state.last_error != nil
  end

  test "a refusal for a symbol unsubscribed while the poll cycle was in flight is dropped" do
    feed = start_feed(socket: fake_socket())

    :ok = Feed.subscribe(feed, ["AAPL", "MSFT"])
    :ok = Feed.unsubscribe(feed, ["MSFT"])

    send(feed, {:dp_exchange, :schwab, {:refused, "MSFT", :late}})
    send(feed, {:dp_exchange, :schwab, {:refused, "AAPL", :current}})

    # The mailbox is ordered, so once AAPL's refusal is delivered MSFT's was already judged.
    assert_receive {:dp_exchange, :schwab, {:refused, "AAPL", :current}}, 5_000
    refute_received {:dp_exchange, :schwab, {:refused, "MSFT", :late}}
  end

  defp wait_until(fun, timeout \\ 5_000) do
    cond do
      fun.() ->
        :ok

      timeout <= 0 ->
        flunk("condition never became true")

      true ->
        receive do
        after
          20 -> wait_until(fun, timeout - 20)
        end
    end
  end
end
