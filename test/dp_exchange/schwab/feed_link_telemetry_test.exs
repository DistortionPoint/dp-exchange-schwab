defmodule DpExchange.Schwab.FeedLinkTelemetryTest do
  @moduledoc """
  A route that dies without saying so still emits `[:dp_exchange, :link, :down]`, once.

  A crashed Socket runs no `handle_disconnect/2`, so the event it emits there never fires;
  `Feed` reports the lost link itself. It must not report it twice when the Socket already
  did. Telemetry handlers are global, so each test filters on a marker unique to it, which
  keeps these tests async-safe.
  """

  use DpExchange.Schwab.FeedCase, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Schwab.Feed

  defp attach_for(marker) do
    test_pid = self()
    id = "feed-link-telemetry-#{marker}"

    :ok =
      :telemetry.attach(
        id,
        [:dp_exchange, :link, :down],
        fn _event, _measurements, %{provider: :schwab, reason: reason}, _config ->
          if is_binary(reason) and String.contains?(reason, marker),
            do: send(test_pid, {:link_down_event, marker, reason})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp crashing_feed do
    socket = fake_socket()

    feed =
      start_feed(
        socket: socket,
        plug: responding(%{"error" => "unauthorized"}, 401),
        retry_attempts: 0
      )

    :ok = Feed.subscribe(feed, ["AAPL"])

    :sys.replace_state(feed, fn state ->
      Process.link(socket)
      state
    end)

    {feed, socket}
  end

  test "a crashed socket emits link_down telemetry exactly once" do
    marker = "marker-#{System.unique_integer([:positive])}"
    attach_for(marker)
    {feed, socket} = crashing_feed()
    :ok = Feed.subscribe_notices(feed, to: self())

    Process.exit(socket, {:crash, marker})

    assert_receive {:link_down_event, ^marker, reason}, 5_000
    assert reason =~ marker
    assert_receive {:dp_exchange, :schwab, %Notice{kind: :link_down}}, 5_000
    refute_receive {:link_down_event, ^marker, _reason}, 500
  end

  test "an unresponsive poller emits link_down telemetry once, not once per read" do
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
    assert_receive {:dp_exchange, :schwab, %DpExchange.Core.Types.Quote{symbol: "AAPL"}}, 5_000
    :ok = Feed.subscribe_notices(feed, to: self())

    # The exit reason of a call to a dead pid names that pid, which is unique on this node.
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _reason}, 5_000
    marker = inspect(dead)
    attach_for(marker)

    :sys.replace_state(feed, fn state -> %{state | poller: dead} end)

    assert Feed.coverage(feed) == %{}
    assert Feed.coverage_by_kind(feed) == %{quotes: %{}}
    assert Feed.status(feed).last_error == :poller_unresponsive

    assert_receive {:link_down_event, ^marker, _reason}, 5_000
    assert_receive {:dp_exchange, :schwab, %Notice{kind: :link_down}}, 5_000
    refute_receive {:link_down_event, ^marker, _reason}, 500
  end

  test "a socket that already reported its own link_down is not reported twice" do
    marker = "marker-#{System.unique_integer([:positive])}"
    attach_for(marker)
    {feed, socket} = crashing_feed()
    :ok = Feed.subscribe_notices(feed, to: self())

    # What `Socket.handle_disconnect/2` sends after emitting its own telemetry event.
    send(feed, {:dp_exchange, :schwab, Notice.new(:link_down, :schwab)})
    assert_receive {:dp_exchange, :schwab, %Notice{kind: :link_down}}, 5_000

    Process.exit(socket, {:crash, marker})

    assert_receive {:dp_exchange, :schwab,
                    %Notice{kind: :link_down, details: %{reason: :route_crashed}}},
                   5_000

    refute_receive {:link_down_event, ^marker, _reason}, 500
  end
end
