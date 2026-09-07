defmodule DpExchange.Schwab.OrderLimitTest do
  @moduledoc """
  The one fact this module exists to hold: was `:order_limit_per_minute` ever stated.

  Not tested here: the facade's use of it (`DpExchange.Schwab`'s "the order ceiling" tests)
  or `Supervisor`'s wiring of it into the tree (`DpExchange.SchwabTest`'s supervision
  tests). This file is the module in isolation — start it, ask it, and confirm the one
  case a caller must never see collapsed: "nothing was running" is not "declared false".
  """

  use ExUnit.Case, async: true

  alias DpExchange.Schwab.OrderLimit

  defp unique_name, do: :"order_limit_#{System.unique_integer([:positive])}"

  describe "status/1" do
    test "reports what it was started with, declared true" do
      name = unique_name()
      start_supervised!({OrderLimit, name: name, declared?: true, limit: 20})

      assert OrderLimit.status(name) == %{declared?: true, limit: 20}
    end

    test "reports what it was started with, declared false" do
      name = unique_name()
      start_supervised!({OrderLimit, name: name, declared?: false, limit: 0})

      assert OrderLimit.status(name) == %{declared?: false, limit: 0}
    end

    test "an explicit zero is declared? true, not the same state as never declared" do
      # The distinction the whole module exists for: `0` stated on purpose is a real
      # answer ("I place no orders"), not the absence of one.
      name = unique_name()
      start_supervised!({OrderLimit, name: name, declared?: true, limit: 0})

      assert %{declared?: true, limit: 0} = OrderLimit.status(name)
    end

    test "nothing running under the name answers :not_started, never a declared? value" do
      refute Process.whereis(:order_limit_never_started)

      assert OrderLimit.status(:order_limit_never_started) == {:error, :not_started}
    end

    test "a process that already exited answers :not_started, not the last thing it held" do
      name = unique_name()
      {:ok, pid} = OrderLimit.start_link(name: name, declared?: true, limit: 5)
      # Unlinked first — this test is killing the agent on purpose, not asserting that a
      # crashed `OrderLimit` should take its caller down too.
      Process.unlink(pid)
      Process.exit(pid, :kill)

      # Give the runtime a chance to actually unregister the name before asking — this
      # waits on the process's own exit, never a fixed sleep.
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      assert OrderLimit.status(name) == {:error, :not_started}
    end
  end

  describe "child_spec/1" do
    test "id follows the configured name, like every other child in this tree" do
      assert %{id: :my_order_limit} = OrderLimit.child_spec(name: :my_order_limit)
    end
  end
end
