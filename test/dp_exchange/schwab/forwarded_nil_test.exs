defmodule DpExchange.Schwab.ForwardedNilTest do
  use ExUnit.Case, async: true

  alias DpExchange.Schwab.Feed

  # **A forwarded `nil` means the caller said nothing, and nothing means the default.**
  #
  # `Keyword.get/3` substitutes its default only for an ABSENT key, never for one present
  # and `nil` — and this family forwards `opts` unchanged through every layer by
  # convention. So `to: nil` arrived here whenever a caller's own caller never set it, and
  # `Keyword.get(opts, :to, self())` handed `nil` on as the subscriber. `Core.Config.opt/3`
  # exists for exactly this and says so; these call sites predated it.
  #
  # The two failure modes were opposite, which is the worst part. In the real `Feed` a `nil`
  # subscriber is silently delivered to nobody — `subscribe/3` answers `:ok` and data never
  # arrives, the failure this family ranks worst. In the fake, `send(nil, _)` raises. So a
  # consumer's tier-1 tests could not have shown them the real behaviour even by accident.
  #
  # Tested against a PROBE standing in for the feed process: it answers the call and
  # reports what it was handed. What changed is the client-side resolution of `:to`, so
  # that is exactly what is measured — no socket, no venue, no timing.
  defp probe do
    test = self()

    spawn_link(fn ->
      receive do
        {:"$gen_call", from, message} ->
          send(test, {:probed, message})
          GenServer.reply(from, :ok)
      end
    end)
  end

  test "subscribe_notices/2 with a forwarded `to: nil` registers the caller" do
    probe = probe()
    Feed.subscribe_notices(probe, to: nil)

    assert_receive {:probed, {:subscribe_notices, subscriber}}
    assert subscriber == self()
  end

  test "subscribe/3 with a forwarded `to: nil` delivers to the caller, not to nobody" do
    # The one that went silent. `nil` reached the subscriber set, and
    # `Core.Fanout.deliver/4` resolves `nil` the way it resolves any registered name
    # nothing answers to: nobody. `subscribe/3` answered `:ok` and nothing ever arrived.
    probe = probe()
    Feed.subscribe(probe, ["BTC-USD"], to: nil)

    assert_receive {:probed, message}
    assert elem(message, 0) == :subscribe
    assert elem(message, 2) == self()
  end

  test "an explicit recipient is still honoured" do
    probe = probe()
    other = spawn(fn -> Process.sleep(:infinity) end)
    Feed.subscribe_notices(probe, to: other)

    assert_receive {:probed, {:subscribe_notices, ^other}}
  end

  test "Supervisor.limiter_name/1 with a forwarded `limiter: nil` names this venue's limiter" do
    # It returned `nil`. The supervisor then started the limiter with `name: nil` — an
    # unnamed process nothing could address — while every REST call carried `limiter: nil`
    # down to `Core.DefaultRateLimiter`, whose own `Config.opt/3` resolved that to its GLOBAL
    # default name: a different limiter, usually not started, so calls failed closed with
    # `:not_started` against a venue limiter that was running the whole time.
    assert DpExchange.Schwab.Supervisor.limiter_name(limiter: nil) ==
             DpExchange.Schwab.Supervisor.limiter_name([])

    refute is_nil(DpExchange.Schwab.Supervisor.limiter_name(limiter: nil))
  end

  defmodule RecordingLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    # The facade calls run in the caller's process, so `self()` here is the test.
    @impl true
    def acquire(_provider, _weight, opts), do: record(opts)
    @impl true
    def check(_provider, _weight, opts), do: record(opts)
    @impl true
    def record(_provider, _weight, _opts), do: :ok

    defp record(opts) do
      send(self(), {:limiter_opt, Keyword.get(opts, :limiter)})
      :ok
    end
  end

  test "a REST call with a forwarded `limiter: nil` meters against this venue's limiter" do
    # The facade used `Keyword.put_new/3`, which keeps a present `limiter: nil`. `Core`
    # then resolved it to its own global limiter, which this package never starts, so every
    # call failed closed against a venue limiter that was running the whole time.
    DpExchange.Core.Config.put_override(:rate_limit_module, RecordingLimiter)

    _result =
      DpExchange.Schwab.get_price("AAPL",
        credentials: %{access_token: "t"},
        limiter: nil,
        retry_attempts: 0,
        plug: fn conn -> Plug.Conn.resp(conn, 500, "no") end
      )

    assert_received {:limiter_opt, limiter}
    assert limiter == DpExchange.Schwab.Supervisor.limiter_name([])
    refute is_nil(limiter)
  end
end
