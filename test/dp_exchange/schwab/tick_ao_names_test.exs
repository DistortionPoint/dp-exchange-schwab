defmodule DpExchange.Schwab.TickAoNamesTest do
  @moduledoc """
  Tick AO, lens M: two trees in one VM need nothing but two distinct `name:`s.

  The limiter, the order record and the feed are named from the tree's `name:` unless
  `:limiter`, `:order_limit` or `:feed` says otherwise, the default tree keeps its fixed names,
  and every facade call resolves the same names from the `name:` it is given.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Schwab
  alias DpExchange.Schwab.{Feed, Options, OrderLimit}
  alias DpExchange.Schwab.Supervisor, as: SchwabSupervisor

  @creds %{access_token: "at-1"}

  test "the default tree keeps its fixed names, and an explicit name wins" do
    for opts <- [[], [name: nil], [name: SchwabSupervisor]] do
      assert SchwabSupervisor.feed_name(opts) == Feed
      assert SchwabSupervisor.limiter_name(opts) == DpExchange.Schwab.RateLimiter
      assert SchwabSupervisor.order_limit_name(opts) == OrderLimit
    end

    opts = [name: :ao_named, feed: :mine, limiter: :lim, order_limit: :ol]
    assert SchwabSupervisor.feed_name(opts) == :mine
    assert SchwabSupervisor.limiter_name(opts) == :lim
    assert SchwabSupervisor.order_limit_name(opts) == :ol
  end

  test "a non-default atom name derives all three, and a non-atom name derives nothing" do
    assert SchwabSupervisor.feed_name(name: :ao_tree) == Module.concat(:ao_tree, "Feed")

    assert SchwabSupervisor.limiter_name(name: :ao_tree) ==
             Module.concat(:ao_tree, "RateLimiter")

    assert SchwabSupervisor.order_limit_name(name: :ao_tree) ==
             Module.concat(:ao_tree, "OrderLimit")

    assert SchwabSupervisor.feed_name(name: {:global, :ao_tree}) == Feed
  end

  test "a forwarded name: nil is the default name, never an unnamed supervisor" do
    assert SchwabSupervisor.supervisor_name([]) == SchwabSupervisor
    assert SchwabSupervisor.supervisor_name(name: nil) == SchwabSupervisor
    assert SchwabSupervisor.supervisor_name(name: :ao_tree) == :ao_tree
    assert %{id: DpExchange.Schwab} = Schwab.child_spec(name: nil)
    assert %{id: :ao_tree} = Schwab.child_spec(name: :ao_tree)
  end

  test "every call accepts name:, and a typo is still refused" do
    assert Options.check(:get_price, name: :ao_tree) == :ok
    assert Options.check(:status, name: :ao_tree) == :ok
    assert Options.check(:place_order, name: :ao_tree) == :ok
    assert Options.check(:status, nme: :ao_tree) == {:error, {:unknown_option, :nme}}
  end

  test "two trees started with only distinct names run side by side, each addressed by name" do
    unique = System.unique_integer([:positive])
    first = :"ao_tree_a_#{unique}"
    second = :"ao_tree_b_#{unique}"

    for {name, extra} <- [{first, [order_limit_per_minute: 5]}, {second, []}] do
      start_supervised!(%{
        id: name,
        start: {Schwab, :start_link, [[name: name, symbols: []] ++ extra]},
        type: :supervisor
      })
    end

    first_feed = Process.whereis(SchwabSupervisor.feed_name(name: first))
    second_feed = Process.whereis(SchwabSupervisor.feed_name(name: second))
    assert is_pid(first_feed)
    assert is_pid(second_feed)
    refute first_feed == second_feed

    # The order record each call consults is its own tree's.
    assert OrderLimit.ensure_declared(name: first) == :ok
    assert OrderLimit.ensure_declared(name: second) == {:error, :order_limit_not_declared}

    request = %{
      symbol: "AAPL",
      side: :buy,
      quantity: 1,
      order_type: :market,
      time_in_force: :day
    }

    assert Schwab.place_order(@creds, request, name: second, account_hash: "hash") ==
             {:error, :order_limit_not_declared}

    # The feed each call reaches is its own: a tree that was never started has none.
    assert Schwab.update_symbols([], name: first) == :ok
    assert Schwab.update_symbols([], name: second) == :ok

    assert Schwab.update_symbols([], name: :"ao_tree_none_#{unique}") ==
             {:error, :feed_not_started}
  end
end
