defmodule DpExchange.Schwab.ArgumentOrderTest do
  @moduledoc """
  The family's argument conventions on the facade and the feed: arguments are judged before
  a feed or a credential is looked at, an element-wise judgement is made on every symbol
  list, `subscribe([])` opens nothing, and a remote pid never raises.
  """

  use DpExchange.Schwab.FeedCase, async: true

  alias DpExchange.Schwab
  alias DpExchange.Schwab.Feed

  @creds %{access_token: "token-abc"}

  # A pid on a node this VM is not, built without distribution: `Process.alive?/1` raises
  # `ArgumentError` for one.
  defp remote_pid do
    node = "tick_o_remote@nowhere"

    :erlang.binary_to_term(
      <<131, 88, 119, byte_size(node)::8, node::binary, 1::32, 0::32, 1::32>>
    )
  end

  describe "streaming calls judge their arguments before looking for a feed" do
    test "a bad symbol list is refused whether or not the feed runs" do
      missing = [feed: :tick_o_no_such_feed]

      for bad <- [nil, :x, "AAPL", 42, ["AAPL", :x, 42], [nil], [""], ["   "], ["BTC-USD"]] do
        assert {:error, {:invalid_symbols, _value}} = Schwab.subscribe(bad, missing)
        assert {:error, {:invalid_symbols, _value}} = Schwab.unsubscribe(bad, missing)
        assert {:error, {:invalid_symbols, _value}} = Schwab.update_symbols(bad, missing)
      end

      assert Schwab.unsubscribe(["AAPL", :x, 42], missing) ==
               {:error, {:invalid_symbols, [:x, 42]}}

      improper = ["AAPL" | "MSFT"]
      assert Schwab.subscribe(improper, missing) == {:error, {:invalid_symbols, improper}}
      assert Schwab.unsubscribe(improper, missing) == {:error, {:invalid_symbols, improper}}
    end

    test "a bad subscriber is refused before the feed is looked at, after the symbols" do
      missing = [feed: :tick_o_no_such_feed]

      assert Schwab.subscribe(["AAPL"], [to: "consumer"] ++ missing) ==
               {:error, {:invalid_subscriber, "consumer"}}

      assert Schwab.subscribe_notices([to: 42] ++ missing) == {:error, {:invalid_subscriber, 42}}

      assert Schwab.subscribe(["BTC-USD"], [to: "consumer"] ++ missing) ==
               {:error, {:invalid_symbols, ["BTC-USD"]}}
    end

    test "good arguments with no feed still answer :feed_not_started (unsubscribe :ok)" do
      missing = [feed: :tick_o_no_such_feed]

      assert Schwab.subscribe(["AAPL"], missing) == {:error, :feed_not_started}
      assert Schwab.update_symbols(["AAPL"], missing) == {:error, :feed_not_started}
      assert Schwab.unsubscribe(["AAPL"], missing) == :ok
    end

    test "the feed refuses a malformed element in unsubscribe and keeps what it holds" do
      feed = start_feed(socket: fake_socket())
      assert Feed.subscribe(feed, ["AAPL", "MSFT"]) == :ok

      assert Feed.unsubscribe(feed, ["AAPL", :x, 42]) == {:error, {:invalid_symbols, [:x, 42]}}
      improper = ["AAPL" | "MSFT"]
      assert Feed.unsubscribe(feed, improper) == {:error, {:invalid_symbols, improper}}
      assert Enum.sort(Feed.wanted(feed)) == ["AAPL", "MSFT"]
      assert Process.alive?(feed)

      assert Feed.unsubscribe(feed, ["AAPL"]) == :ok
      assert Feed.wanted(feed) == ["MSFT"]
    end
  end

  describe "subscribe([]) opens nothing" do
    test "no bootstrap request is made and no route is chosen" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:bootstrap_request, conn.request_path})
        Plug.Conn.resp(conn, 500, "")
      end

      feed = start_feed(plug: plug, limiter: permissive_limiter())

      assert Feed.subscribe(feed, [], to: self()) == :ok
      assert Feed.update_symbols(feed, []) == :ok

      state = :sys.get_state(feed)
      assert state.route == nil
      assert state.route_bootstrap == nil
      assert state.socket == nil
      refute_receive {:bootstrap_request, _path}, 200
    end
  end

  describe "a remote feed pid never raises" do
    test "reads answer empty and writes answer :feed_not_started" do
      remote = remote_pid()
      refute node(remote) == node()
      opts = [feed: remote]

      assert Schwab.coverage(opts) == %{}
      assert Schwab.coverage_by_kind(opts) == %{}
      assert Schwab.status(opts) == %{}
      assert Schwab.wanted(opts) == []
      assert Schwab.subscribe(["AAPL"], opts) == {:error, :feed_not_started}
      assert Schwab.update_credentials(@creds, opts) == {:error, :feed_not_started}
    end
  end

  describe "single-symbol reads" do
    test "nil, non-binary and blank are {:invalid_symbol, v} before credentials" do
      for bad <- [nil, 42, :aapl, "", "   "] do
        assert Schwab.get_price(bad) == {:error, {:invalid_symbol, bad}}
        assert Schwab.get_top_of_book(bad) == {:error, {:invalid_symbol, bad}}
        assert Schwab.get_historical_prices(bad, "1d", []) == {:error, {:invalid_symbol, bad}}
      end
    end

    test "a well-formed symbol still hits credentials, and a non-equity keeps its tag" do
      assert Schwab.get_price("AAPL") == {:error, {:missing_credentials, :schwab}}

      assert Schwab.get_price("BTC-USD", credentials: @creds) ==
               {:error, {:not_an_equity_symbol, "BTC-USD"}}
    end

    test "a range that is not a keyword list is refused, not raised on" do
      for bad <- [nil, 5, "range", [1, 2], [start: 1], [start: ~D[2026-06-01]]] do
        assert Schwab.get_historical_prices("AAPL", "1d", bad, credentials: @creds) ==
                 {:error, {:invalid_range, bad}}
      end
    end
  end
end
