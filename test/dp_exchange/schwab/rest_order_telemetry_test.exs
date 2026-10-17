defmodule DpExchange.Schwab.RestOrderTelemetryTest do
  @moduledoc """
  An order write is the venue's request in telemetry (`provider: :schwab`) and is metered in
  its own limiter bucket (`rate_limit_key: :schwab_orders`): the bucket must not be the
  identity a dashboard groups by. Telemetry handlers are global, so the handler filters on an
  account hash unique to the test, which keeps this async-safe.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Schwab.Rest

  defmodule RecordingLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(provider, _weight, _opts), do: note(provider)
    @impl true
    def check(provider, _weight, _opts), do: note(provider)
    @impl true
    def record(_provider, _weight, _opts), do: :ok

    defp note(provider) do
      send(self(), {:bucket, provider})
      :ok
    end
  end

  test "an order write's request telemetry says :schwab and the limiter bucket is :schwab_orders" do
    Config.put_override(:rate_limit_module, RecordingLimiter)
    hash = "HASH#{System.unique_integer([:positive])}"
    test_pid = self()
    id = "rest-order-telemetry-#{hash}"

    :ok =
      :telemetry.attach(
        id,
        [:dp_exchange, :request, :stop],
        fn _event, _measurements, metadata, _config ->
          if String.contains?(metadata.endpoint, hash),
            do: send(test_pid, {:request_stop, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "/orders/2001")
      |> Plug.Conn.resp(201, "")
    end

    assert {:ok, "2001"} =
             Rest.place_order(%{access_token: "at-1"}, hash, %{}, plug: plug, retry_attempts: 0)

    assert_receive {:request_stop, %{provider: :schwab, method: :post}}, 5_000
    assert_receive {:bucket, :schwab_orders}, 5_000
    refute_receive {:request_stop, _other}, 500
  end
end
