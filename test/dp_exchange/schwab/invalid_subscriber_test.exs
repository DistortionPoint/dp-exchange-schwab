defmodule DpExchange.Schwab.InvalidSubscriberTest do
  @moduledoc """
  A `:to` that `Core.Fanout.resolve/1` cannot send to is refused in `Feed`, recorded nowhere,
  and the facade sees a feed registered under `{:global, _}` / `{:via, _, _}` as running.

  `resolve/1` has a pid clause and an atom clause. A string, integer or `{:global, _}` tuple
  used to be stored as a subscriber and raised `FunctionClauseError` inside the shared
  `Feed` on the first delivery or notice, and the restart dropped every consumer.
  """

  use DpExchange.Schwab.FeedCase, async: true

  alias DpExchange.Schwab
  alias DpExchange.Schwab.{Fake, Feed}

  # `nil` is absent here: `Core.Config.opt/3` reads an explicit `nil` as "not given" and
  # substitutes the caller, which is the family's convention for forwarded options.
  @bad_targets ["consumer", 42, {:global, :somebody}, {:via, Registry, :x}, true, false]

  describe "Feed.subscribe/3" do
    test "refuses a :to it cannot send to, and records nothing" do
      feed = start_feed(socket: fake_socket())

      for bad <- @bad_targets do
        assert Feed.subscribe(feed, ["AAPL"], to: bad) == {:error, {:invalid_subscriber, bad}}
      end

      assert Feed.wanted(feed) == []
      assert Process.alive?(feed)
    end

    test "judges the symbols before the subscriber" do
      feed = start_feed(socket: fake_socket())

      assert Feed.subscribe(feed, ["BTC-USD"], to: "consumer") ==
               {:error, {:invalid_symbols, ["BTC-USD"]}}

      assert Feed.subscribe(feed, :nope, to: "consumer") == {:error, {:invalid_symbols, :nope}}
    end

    test "a pid and a registered atom are still accepted" do
      feed = start_feed(socket: fake_socket())
      name = :"schwab_invalid_subscriber_#{System.unique_integer([:positive])}"
      Process.register(self(), name)

      assert Feed.subscribe(feed, ["AAPL"], to: self()) == :ok
      assert Feed.subscribe(feed, ["MSFT"], to: name) == :ok
      assert Enum.sort(Feed.wanted(feed)) == ["AAPL", "MSFT"]
    end

    test "the feed keeps serving a good consumer after a refused one" do
      feed = start_feed(socket: fake_socket())

      assert Feed.subscribe(feed, ["AAPL"], to: self()) == :ok
      assert {:error, {:invalid_subscriber, "x"}} = Feed.subscribe(feed, ["MSFT"], to: "x")

      send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      assert_receive {:dp_exchange, :schwab, %{symbol: "AAPL"}}, 5_000
      assert Process.alive?(feed)
    end
  end

  describe "Feed.subscribe_notices/2" do
    test "refuses a :to it cannot send to, and a notice later does not crash the feed" do
      feed = start_feed(socket: fake_socket())

      for bad <- @bad_targets do
        assert Feed.subscribe_notices(feed, to: bad) == {:error, {:invalid_subscriber, bad}}
      end

      assert Feed.subscribe_notices(feed, to: self()) == :ok
      send(feed, {:dp_exchange, :schwab, DpExchange.Core.Notice.new(:link_up, :schwab)})
      assert_receive {:dp_exchange, :schwab, %DpExchange.Core.Notice{kind: :link_up}}, 5_000
      assert Process.alive?(feed)
    end

    test "a pid is accepted" do
      feed = start_feed(socket: fake_socket())
      assert Feed.subscribe_notices(feed, to: self()) == :ok
    end
  end

  describe "the facade" do
    test "reads a feed registered under {:global, _} as running" do
      name = {:global, {:schwab_global_feed, make_ref()}}
      _feed = start_feed(name: name, socket: fake_socket())

      # An absent feed answers `:feed_not_started`; a live one reaches `Feed` and is refused
      # on the subscriber.
      assert Schwab.subscribe(["AAPL"], feed: name, to: "consumer") ==
               {:error, {:invalid_subscriber, "consumer"}}

      assert Schwab.subscribe_notices(feed: name, to: "consumer") ==
               {:error, {:invalid_subscriber, "consumer"}}

      assert %{} = Schwab.status(feed: name)
      assert map_size(Schwab.status(feed: name)) > 0
    end

    test "still answers :feed_not_started for a global name nobody registered" do
      name = {:global, {:schwab_missing_feed, make_ref()}}
      assert Schwab.subscribe(["AAPL"], feed: name) == {:error, :feed_not_started}
      assert Schwab.status(feed: name) == %{}
    end
  end

  describe "Fake refuses the same way, in the same order" do
    test "subscribe/2" do
      for bad <- @bad_targets do
        assert Fake.subscribe(["AAPL"], to: bad) == {:error, {:invalid_subscriber, bad}}
      end

      assert Fake.wanted() == []

      assert Fake.subscribe(["BTC-USD"], to: "consumer") ==
               {:error, {:invalid_symbols, ["BTC-USD"]}}
    end

    test "update_symbols/2 changes nothing on a refused subscriber" do
      assert Fake.subscribe(["AAPL"]) == :ok
      assert Fake.update_symbols(["MSFT"], to: "x") == {:error, {:invalid_subscriber, "x"}}
      assert Fake.wanted() == ["AAPL"]
    end

    test "subscribe_notices/1" do
      for bad <- @bad_targets do
        assert Fake.subscribe_notices(to: bad) == {:error, {:invalid_subscriber, bad}}
      end

      refute_received {:dp_exchange, :schwab, _any}
      assert Fake.subscribe_notices(to: self()) == :ok
      assert_receive {:dp_exchange, :schwab, %DpExchange.Core.Notice{kind: :link_up}}, 5_000
    end
  end
end
