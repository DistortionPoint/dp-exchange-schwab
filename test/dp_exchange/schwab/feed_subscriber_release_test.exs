defmodule DpExchange.Schwab.FeedSubscriberReleaseTest do
  @moduledoc """
  When the last data subscriber dies, the symbols it asked for are released through the path
  `unsubscribe/2` takes, so the Streamer is told and the single connection is not held open
  for a consumer that no longer exists.
  """

  use DpExchange.Schwab.FeedCase, async: true

  alias DpExchange.Schwab.Feed

  defp forwarding_socket do
    test_pid = self()

    socket =
      spawn(fn ->
        Stream.repeatedly(fn -> receive(do: (message -> send(test_pid, message))) end)
        |> Stream.run()
      end)

    on_exit(fn -> Process.exit(socket, :kill) end)
    socket
  end

  defp idle_process do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp kill_and_settle(feed, pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    # A call is answered only after the feed's own `:DOWN` has been handled.
    _settled = Feed.coverage(feed)
    :ok
  end

  test "the last data subscriber dying releases its symbols and tells the Streamer" do
    feed = start_feed(socket: forwarding_socket(), subscriber: nil)
    subscriber = idle_process()

    :ok = Feed.subscribe(feed, ["AAPL"], to: subscriber)
    assert_receive {:"$websockex_cast", {:subscribe_all, batch}}, 5_000
    assert {"LEVELONE_EQUITIES", "SUBS", ["AAPL"], []} in batch

    kill_and_settle(feed, subscriber)

    assert Feed.wanted(feed) == []
    assert_receive {:"$websockex_cast", {:subscribe_all, emptied}}, 5_000
    assert {"LEVELONE_EQUITIES", "SUBS", [], []} in emptied
    assert {"CHART_EQUITY", "SUBS", [], []} in emptied
  end

  test "one of two data subscribers dying keeps the symbols" do
    feed = start_feed(socket: forwarding_socket(), subscriber: nil)
    dying = idle_process()
    staying = idle_process()

    :ok = Feed.subscribe(feed, ["AAPL"], to: dying)
    :ok = Feed.subscribe(feed, ["MSFT"], to: staying)

    kill_and_settle(feed, dying)

    assert Enum.sort(Feed.wanted(feed)) == ["AAPL", "MSFT"]
  end

  test "a registered-name subscriber keeps the symbols alive" do
    feed = start_feed(socket: forwarding_socket(), subscriber: nil)
    name = :"release_named_#{System.unique_integer([:positive])}"
    holder = idle_process()
    Process.register(holder, name)
    dying = idle_process()

    :ok = Feed.subscribe(feed, ["AAPL"], to: name)
    :ok = Feed.subscribe(feed, ["MSFT"], to: dying)

    kill_and_settle(feed, dying)

    assert Enum.sort(Feed.wanted(feed)) == ["AAPL", "MSFT"]
  end

  test "a notice-only subscriber dying releases nothing" do
    feed = start_feed(socket: forwarding_socket(), subscriber: nil)
    data = idle_process()
    watcher = idle_process()

    :ok = Feed.subscribe(feed, ["AAPL"], to: data)
    :ok = Feed.subscribe_notices(feed, to: watcher)

    kill_and_settle(feed, watcher)

    assert Feed.wanted(feed) == ["AAPL"]
  end

  test "boot-configured symbols are kept when the last subscriber dies" do
    feed = start_feed(socket: forwarding_socket(), subscriber: nil, symbols: ["TSLA"])
    subscriber = idle_process()

    :ok = Feed.subscribe(feed, ["AAPL"], to: subscriber)
    kill_and_settle(feed, subscriber)

    assert Feed.wanted(feed) == ["TSLA"]
  end
end
