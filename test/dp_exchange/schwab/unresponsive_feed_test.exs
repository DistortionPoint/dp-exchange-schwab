defmodule DpExchange.Schwab.UnresponsiveFeedTest do
  @moduledoc """
  A feed that is alive and never answers: the facade's call gives up on the feed's own budget
  and answers a value, instead of exiting in the caller's process.

  Alone in a file because the budget is fifteen real seconds (`Feed`'s `@call_timeout`) and
  nothing can shorten what is being proved. The two calls run side by side so the wait is paid
  once.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag timeout: 60_000

  alias DpExchange.Schwab

  test "a call into a feed that never answers is :feed_timeout, and a read of it is empty" do
    silent =
      spawn(fn ->
        receive do
          :never_sent -> :ok
        end
      end)

    on_exit(fn -> Process.exit(silent, :kill) end)

    notices = Task.async(fn -> Schwab.subscribe_notices(feed: silent, to: self()) end)
    coverage = Task.async(fn -> Schwab.coverage(feed: silent) end)

    # `%{}` as a pattern matches ANY map, so the read is compared by value: empty, not merely
    # a map.
    assert [{:error, :feed_timeout}, empty] = Task.await_many([notices, coverage], 40_000)
    assert empty == %{}
  end
end
