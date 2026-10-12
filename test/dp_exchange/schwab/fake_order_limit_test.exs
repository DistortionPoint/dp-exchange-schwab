defmodule DpExchange.Schwab.FakeOrderLimitTest do
  @moduledoc """
  The fake refuses an order write under an undeclared or zero order ceiling exactly as the
  facade does, through the one shared `OrderLimit.ensure_declared/1`.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Types.Order
  alias DpExchange.Schwab
  alias DpExchange.Schwab.Fake

  @creds %{access_token: "at-1"}
  @request %{symbol: "AAPL", side: :buy, quantity: 1, order_type: :market, time_in_force: :day}

  defp start_tree(extra) do
    unique = System.unique_integer([:positive])

    opts =
      [
        name: :"fol_sup_#{unique}",
        feed: :"fol_feed_#{unique}",
        limiter: :"fol_lim_#{unique}",
        order_limit: :"fol_olim_#{unique}",
        symbols: [],
        start_delay_ms: 60_000
      ] ++ extra

    {:ok, pid} = Schwab.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)

    [account_hash: "H", order_limit: :"fol_olim_#{unique}"]
  end

  test "a tree with no declared ceiling is refused by all three order writes" do
    opts = start_tree([])

    assert Fake.place_order(@creds, @request, opts) == {:error, :order_limit_not_declared}

    assert Fake.replace_order(@creds, "1005439821", @request, opts) ==
             {:error, :order_limit_not_declared}

    assert Fake.cancel_order(@creds, "1005439821", opts) == {:error, :order_limit_not_declared}
  end

  test "a declared zero is refused as :order_limit_zero" do
    opts = start_tree(order_limit_per_minute: 0)

    assert Fake.place_order(@creds, @request, opts) == {:error, :order_limit_zero}
  end

  test "a declared ceiling, or no tree at all, lets the write through" do
    declared = start_tree(order_limit_per_minute: 20)

    no_tree = [account_hash: "H"]

    assert {:ok, %Order{}} = Fake.place_order(@creds, @request, declared)
    assert {:ok, %Order{}} = Fake.place_order(@creds, @request, no_tree)
  end

  test "reads are never gated" do
    opts = start_tree([])

    assert {:ok, [_balance]} = Fake.get_balances(@creds, opts)
  end
end
