defmodule DpExchange.Schwab.FeedUpgradeTest do
  @moduledoc """
  A feed that fell back to the poll goes back to the Streamer once it can.

  See `Feed`'s moduledoc, "The fallback is not permanent". Before it, one failed
  `/userPreference` at startup kept a feed polling for the life of the process: no
  candles, ever, until something restarted it.

  The bootstrap is driven through a `plug` whose answer the test switches mid-run. The
  success path needs `Socket.start_link/1` to actually connect, so a minimal WebSocket
  endpoint is served from `:gen_tcp`. It completes the HTTP upgrade and then holds the
  connection open, which is all a connect needs.
  """

  use DpExchange.Schwab.FeedCase, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Schwab.Feed

  defp user_preference(url) do
    %{
      "streamerInfo" => [
        %{
          "streamerSocketUrl" => url,
          "schwabClientCustomerId" => "cust-1",
          "schwabClientCorrelId" => "corr-1",
          "schwabClientChannel" => "IO",
          "schwabClientFunctionId" => "APIAPP"
        }
      ]
    }
  end

  # The plug answers whatever the agent currently holds, so a test can let the bootstrap
  # fail first and succeed later. Only `/userPreference` requests are counted: the fallback
  # poll's own `/quotes` requests reach the same plug and must not look like a bootstrap.
  defp switchable(initial) do
    {:ok, agent} = Agent.start_link(fn -> %{answer: initial, calls: 0} end)

    plug = fn conn ->
      bootstrap? = String.contains?(conn.request_path, "userPreference")

      answer =
        Agent.get_and_update(agent, fn %{answer: answer, calls: calls} = held ->
          {answer, %{held | calls: if(bootstrap?, do: calls + 1, else: calls)}}
        end)

      # `{:hang, test_pid}` holds a bootstrap open until the test releases it with an answer,
      # so the test can act while the bootstrap is in flight.
      {body, status} =
        case answer do
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

  defp answer(agent, body, status), do: Agent.update(agent, &%{&1 | answer: {body, status}})
  defp calls(agent), do: Agent.get(agent, & &1.calls)

  # Accepts one WebSocket client, completes the RFC 6455 handshake, then holds the
  # connection open and ignores whatever arrives.
  defp websocket_endpoint do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    pid =
      spawn(fn ->
        {:ok, client} = :gen_tcp.accept(listen)
        {:ok, request} = read_headers(client, "")
        [_header, key] = Regex.run(~r/Sec-WebSocket-Key: (\S+)/i, request)

        accept =
          :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

        :ok =
          :gen_tcp.send(
            client,
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" <>
              "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
          )

        drain(client)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    "ws://127.0.0.1:#{port}/ws"
  end

  defp read_headers(client, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      with {:ok, data} <- :gen_tcp.recv(client, 0, 5_000), do: read_headers(client, acc <> data)
    end
  end

  defp drain(client) do
    case :gen_tcp.recv(client, 0) do
      {:ok, _data} -> drain(client)
      {:error, _closed} -> :ok
    end
  end

  test "a transient bootstrap failure is retried on the tick, and the stream takes over" do
    {agent, plug} = switchable({%{"error" => "unavailable"}, 503})
    url = websocket_endpoint()
    feed = start_feed(plug: plug, retry_attempts: 0, url: url, allow_insecure_socket: true)

    :ok = Feed.subscribe(feed, ["AAPL"])

    assert_receive {:dp_exchange, :schwab,
                    %Notice{kind: :degraded, details: %{fallback: :internal_poll}}},
                   5_000

    poller = :sys.get_state(feed).poller
    ref = Process.monitor(poller)

    answer(agent, user_preference(url), 200)
    send(feed, :resubscribe)

    assert_receive {:dp_exchange, :schwab,
                    %Notice{kind: :coverage_change, severity: :info, details: %{route: :stream}}},
                   5_000

    assert %{route: :stream} = Feed.status(feed)
    assert_receive {:DOWN, ^ref, :process, ^poller, :shutdown}, 5_000
    assert :sys.get_state(feed).poller == nil
  end

  test "an upgrade that fails again keeps the running poll, and says nothing new" do
    {agent, plug} = switchable({%{"error" => "unavailable"}, 503})
    feed = start_feed(plug: plug, retry_attempts: 0)

    :ok = Feed.subscribe(feed, ["AAPL"])
    assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded}}, 5_000
    poller = :sys.get_state(feed).poller
    before = calls(agent)

    send(feed, :resubscribe)
    wait_until(fn -> :sys.get_state(feed).route_bootstrap == nil and calls(agent) > before end)

    # The same poller, not a second one, and no repeated `:degraded`.
    assert :sys.get_state(feed).poller == poller
    assert Process.alive?(poller)
    assert %{route: :internal_poll} = Feed.status(feed)
    refute_received {:dp_exchange, :schwab, %Notice{kind: :degraded}}
  end

  test "an upgrade answered with a Streamer description it cannot use keeps the poll" do
    # The venue answered 200, so the bootstrap itself succeeded; what it carried names no
    # Streamer. That is the same unreachable Streamer as a 503, and the same remedy: the
    # running poll stays, with the reason recorded for `status/1` and the next tick.
    {agent, plug} = switchable({%{"error" => "unavailable"}, 503})
    feed = start_feed(plug: plug, retry_attempts: 0)

    :ok = Feed.subscribe(feed, ["AAPL"])
    assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded}}, 5_000
    poller = :sys.get_state(feed).poller
    before = calls(agent)

    answer(agent, %{"streamerInfo" => []}, 200)
    send(feed, :resubscribe)
    wait_until(fn -> :sys.get_state(feed).route_bootstrap == nil and calls(agent) > before end)

    state = :sys.get_state(feed)
    assert state.poller == poller
    assert state.last_error == :no_streamer_info
    assert %{route: :internal_poll} = Feed.status(feed)
  end

  test "an upgrade whose bootstrap task dies keeps the running poll and is not left in flight" do
    # A killed task sends no reply, so only its `:DOWN` can settle the upgrade. Left alone, the
    # feed would hold the dead ref as "in flight" and never try again.
    {agent, plug} = switchable({%{"error" => "unavailable"}, 503})
    feed = start_feed(plug: plug, retry_attempts: 0)

    :ok = Feed.subscribe(feed, ["AAPL"])
    assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded}}, 5_000
    poller = :sys.get_state(feed).poller

    test_pid = self()
    Agent.update(agent, &%{&1 | answer: {:hang, test_pid}})
    send(feed, :resubscribe)
    assert_receive {:hanging, _request}, 5_000

    %{pid: task} = :sys.get_state(feed).route_bootstrap
    Process.exit(task, :kill)
    wait_until(fn -> :sys.get_state(feed).route_bootstrap == nil end)

    state = :sys.get_state(feed)
    assert state.poller == poller
    assert Process.alive?(poller)
    assert {:bootstrap_task_down, :killed} = state.last_error
    assert %{route: :internal_poll} = Feed.status(feed)
  end

  test "a poller that crashes during an upgrade is replaced, not lost with it" do
    # The crash asks for a route and joins the in-flight upgrade. Left an upgrade, its
    # failure "stayed on" a poll that no longer existed, leaving no route and nothing to
    # start one. See `Feed`'s `start_route_bootstrap/2`.
    {agent, plug} = switchable({%{"error" => "unavailable"}, 503})
    feed = start_feed(plug: plug, retry_attempts: 0)

    :ok = Feed.subscribe(feed, ["AAPL"])
    assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded}}, 5_000
    poller = :sys.get_state(feed).poller

    # Captured out here: inside `Agent.update/2`'s function, `self()` is the agent.
    test_pid = self()
    Agent.update(agent, &%{&1 | answer: {:hang, test_pid}})
    send(feed, :resubscribe)
    assert_receive {:hanging, request}, 5_000

    Process.exit(poller, :kill)
    wait_until(fn -> :sys.get_state(feed).poller == nil end)

    send(request, {:release, %{"error" => "unavailable"}, 503})

    wait_until(fn ->
      replacement = :sys.get_state(feed).poller
      is_pid(replacement) and replacement != poller and Process.alive?(replacement)
    end)

    assert %{route: :internal_poll} = Feed.status(feed)
  end

  test "credentials with no token swapped in mid-bootstrap cannot open the stream" do
    # The bootstrap request went out signed with the old token and succeeded. By the time it
    # settles, the credentials the socket's LOGIN would use are the new ones, and they hold no
    # token: the stream is refused by name and the feed falls back to the poll.
    {_agent, plug} = switchable({:hang, self()})
    url = websocket_endpoint()
    feed = start_feed(plug: plug, retry_attempts: 0, url: url, allow_insecure_socket: true)

    subscribing = Task.async(fn -> Feed.subscribe(feed, ["AAPL"]) end)
    assert_receive {:hanging, request}, 5_000

    :ok = Feed.update_credentials(feed, %{})
    send(request, {:release, user_preference(url), 200})

    assert :ok = Task.await(subscribing, 15_000)

    assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded, details: details}}, 5_000
    assert details.reason == :streamer_unreachable
    assert details.message =~ "missing_credentials"
    assert details.fallback == :internal_poll
    assert %{route: :internal_poll} = Feed.status(feed)
  end

  test "a REFUSED credential is not retried on the tick, only when credentials change" do
    {agent, plug} = switchable({%{"error" => "unauthorized"}, 401})
    feed = start_feed(plug: plug, retry_attempts: 0)

    :ok = Feed.subscribe(feed, ["AAPL"])
    assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded}}, 5_000
    assert {:refused, _reason} = :sys.get_state(feed).last_error
    before = calls(agent)

    send(feed, :resubscribe)
    assert :sys.get_state(feed).route_bootstrap == nil
    assert calls(agent) == before

    :ok = Feed.update_credentials(feed, credentials())
    wait_until(fn -> calls(agent) > before end)
  end

  test "a frame and a link_down from a replaced socket are dropped, the current one's are not" do
    {agent, plug} = switchable({%{"error" => "unavailable"}, 503})
    url = websocket_endpoint()
    feed = start_feed(plug: plug, retry_attempts: 0, url: url, allow_insecure_socket: true)

    :ok = Feed.subscribe(feed, ["AAPL"])
    assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded}}, 5_000

    answer(agent, user_preference(url), 200)
    send(feed, :resubscribe)

    assert_receive {:dp_exchange, :schwab,
                    %Notice{kind: :coverage_change, severity: :info, details: %{route: :stream}}},
                   5_000

    tag = :sys.get_state(feed).socket_tag
    assert is_reference(tag)
    stale = make_ref()
    quoted = quote_for("AAPL")

    send(feed, {:dp_exchange, :schwab, {:from_socket, stale, quoted}})
    assert Feed.coverage(feed) == %{}
    refute_received {:dp_exchange, :schwab, %DpExchange.Core.Types.Quote{}}

    send(feed, {:dp_exchange, :schwab, {:from_socket, tag, quoted}})
    assert_receive {:dp_exchange, :schwab, %DpExchange.Core.Types.Quote{symbol: "AAPL"}}, 5_000
    assert Feed.coverage(feed) == %{"AAPL" => :stream}

    down = Notice.new(:link_down, :schwab)
    send(feed, {:dp_exchange, :schwab, {:from_socket, stale, down}})
    assert Feed.coverage(feed) == %{"AAPL" => :stream}

    send(feed, {:dp_exchange, :schwab, {:from_socket, tag, down}})
    assert Feed.coverage(feed) == %{}
  end

  test "credentials replaced while a bootstrap is in flight retry it once it has failed" do
    # `update_credentials/2` finds a bootstrap in flight and starts nothing, and the tick skips
    # a REFUSED credential, so a bootstrap that started under the old token and was refused
    # left the feed polling for good although the new token was never tried.
    {agent, plug} = switchable({:hang, self()})
    feed = start_feed(plug: plug, retry_attempts: 0)

    subscribing = Task.async(fn -> Feed.subscribe(feed, ["AAPL"]) end)
    assert_receive {:hanging, request}, 5_000
    assert calls(agent) == 1

    :ok = Feed.update_credentials(feed, credentials())
    answer(agent, %{"error" => "unavailable"}, 503)
    send(request, {:release, %{"error" => "unauthorized"}, 401})

    assert :ok = Task.await(subscribing, 5_000)
    wait_until(fn -> calls(agent) >= 2 end)
  end

  test "a refusal or notice from a poll that was replaced is dropped, a current one is not" do
    {_agent, plug} = switchable({%{"error" => "unavailable"}, 503})
    feed = start_feed(plug: plug, retry_attempts: 0)

    :ok = Feed.subscribe(feed, ["AAPL"])
    assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded}}, 5_000

    send(feed, {:dp_exchange, :schwab, {:polled, make_ref(), {:refused, "AAPL", :stale}}})
    assert %{route: :internal_poll} = Feed.status(feed)
    refute_received {:dp_exchange, :schwab, {:refused, "AAPL", :stale}}

    tag = :sys.get_state(feed).poll_tag
    send(feed, {:dp_exchange, :schwab, {:polled, tag, {:refused, "AAPL", :current}}})
    assert_receive {:dp_exchange, :schwab, {:refused, "AAPL", :current}}, 5_000
  end

  test "a bootstrap that completes after everything was unsubscribed opens nothing" do
    # `wanted` was judged only when the bootstrap STARTED. One that completed after the last
    # symbol was unsubscribed still opened a Streamer session nobody asked for. The caller
    # parked on it is answered as ever; the route it settled is torn down.
    {_agent, plug} = switchable({:hang, self()})
    url = websocket_endpoint()
    feed = start_feed(plug: plug, retry_attempts: 0, url: url, allow_insecure_socket: true)

    subscribing = Task.async(fn -> Feed.subscribe(feed, ["AAPL"]) end)
    assert_receive {:hanging, request}, 5_000

    :ok = Feed.unsubscribe(feed, ["AAPL"])
    send(request, {:release, user_preference(url), 200})

    # Answered, not left to its own call timeout.
    assert Task.await(subscribing, 15_000)

    state = :sys.get_state(feed)
    assert state.route == nil
    assert state.socket == nil
    assert state.poller == nil
    assert state.route_bootstrap == nil
    assert MapSet.size(state.wanted) == 0
  end

  test "an upgrade that completes after everything was unsubscribed opens nothing" do
    {agent, plug} = switchable({%{"error" => "unavailable"}, 503})
    url = websocket_endpoint()
    feed = start_feed(plug: plug, retry_attempts: 0, url: url, allow_insecure_socket: true)

    :ok = Feed.subscribe(feed, ["AAPL"])
    assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded}}, 5_000

    test_pid = self()
    Agent.update(agent, &%{&1 | answer: {:hang, test_pid}})
    send(feed, :resubscribe)
    assert_receive {:hanging, request}, 5_000

    :ok = Feed.unsubscribe(feed, ["AAPL"])
    send(request, {:release, user_preference(url), 200})

    wait_until(fn -> :sys.get_state(feed).route_bootstrap == nil end)

    state = :sys.get_state(feed)
    assert state.route == nil
    assert state.socket == nil
    assert state.poller == nil
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
