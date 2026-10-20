defmodule DpExchange.Schwab.TickAjRobustnessTest do
  @moduledoc """
  Tick AJ: the answers a caller's bad input must get instead of a crash or a silent default.

  * a non-keyword `opts` on the facade and the Fake is `{:invalid_options, value}`, not an
    `ArgumentError` in the caller's process (the four plain-value reads raise on purpose);
  * `max_results:` on the orders reads is a positive integer, else `{:invalid_option, ...}`;
  * `limit:` on `get_historical_prices/4` is `{:unsupported_option, :limit}` (the venue has no
    such parameter), and `subscribe/2` refuses the market-data options the Streamer cannot
    honour (MD4);
  * a nil / non-binary symbol, CUSIP or account hash on the raw reads is a named refusal.

  Every refusal here is decided before a request is built, so nothing touches a network.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Schwab
  alias DpExchange.Schwab.{Fake, Rest}

  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @creds %{access_token: "at-1"}
  @from ~U[2026-10-01 00:00:00Z]
  @to ~U[2026-10-02 00:00:00Z]

  defp window(extra), do: [from: @from, to: @to] ++ extra

  describe "a non-keyword opts on the facade" do
    test "is refused by name on every call that reads it" do
      for bad <- [%{credentials: @creds}, :bad, "opts", [1, 2]] do
        refusal = {:error, {:invalid_options, echoed(bad)}}

        assert Schwab.get_price("AAPL", bad) == refusal
        assert Schwab.get_top_of_book("AAPL", bad) == refusal
        assert Schwab.market_status(bad) == refusal
        assert Schwab.get_accounts(@creds, bad) == refusal
        assert Schwab.get_balances(@creds, bad) == refusal
        assert Schwab.get_orders(@creds, bad) == refusal
        assert Schwab.get_all_orders(@creds, bad) == refusal
        assert Schwab.get_transactions(@creds, bad) == refusal
        assert Schwab.get_positions(bad) == refusal
        assert Schwab.get_user_preference(@creds, bad) == refusal
        assert Schwab.get_symbol_quote("AAPL", @creds, bad) == refusal
        assert Schwab.get_market("equity", @creds, bad) == refusal
        assert Schwab.get_instrument("037833100", @creds, bad) == refusal
        assert Schwab.place_order(@creds, %{}, bad) == refusal
        assert Schwab.subscribe(["AAPL"], bad) == refusal
        assert Schwab.unsubscribe(["AAPL"], bad) == refusal
        assert Schwab.update_symbols(["AAPL"], bad) == refusal
        assert Schwab.subscribe_notices(bad) == refusal
      end
    end

    test "reads that return a plain value raise rather than answer a plausible empty value" do
      for mod <- [Schwab, Fake], bad <- [%{feed: :x}, :bad, "opts"] do
        for fun <- [:coverage, :coverage_by_kind, :wanted, :status] do
          error =
            assert_raise ArgumentError, fn -> apply(mod, fun, [bad]) end

          assert error.message =~ "opts must be a keyword list"
        end
      end
    end

    test "the Fake refuses exactly as the facade does, for every function that reads opts" do
      calls = [
        {:get_price, ["AAPL"]},
        {:get_top_of_book, ["AAPL"]},
        {:get_historical_prices, ["AAPL", "1d", []]},
        {:get_symbols, []},
        {:market_status, []},
        {:get_accounts, [@creds]},
        {:get_balances, [@creds]},
        {:place_order, [@creds, %{}]},
        {:preview_order, [@creds, %{}]},
        {:replace_order, [@creds, "1", %{}]},
        {:cancel_order, [@creds, "1"]},
        {:get_order, [@creds, "1"]},
        {:get_orders, [@creds]},
        {:get_all_orders, [@creds]},
        {:test_connection, [@creds]},
        {:get_positions, []},
        {:get_option_chain, ["AAPL"]},
        {:get_option_expirations, ["AAPL"]},
        {:get_screener, ["$SPX"]},
        {:get_transactions, [@creds]},
        {:refresh_credentials, [@creds]},
        {:get_transaction, [@creds, "H", 1]},
        {:get_account_summaries, [@creds]},
        {:get_symbol_quote, ["AAPL", @creds]},
        {:get_market, ["equity", @creds]},
        {:get_instrument, ["037833100", @creds]},
        {:get_user_preference, [@creds]},
        {:subscribe, [["AAPL"]]},
        {:unsubscribe, [["AAPL"]]},
        {:update_symbols, [["AAPL"]]},
        {:subscribe_notices, []},
        {:update_credentials, [@creds]}
      ]

      for bad <- [%{credentials: @creds}, :bad, "opts"], {fun, args} <- calls do
        refusal = {:error, {:invalid_options, echoed(bad)}}

        assert apply(Schwab, fun, args ++ [bad]) == refusal, "facade #{fun}"
        assert apply(Fake, fun, args ++ [bad]) == refusal, "fake #{fun}"
      end
    end
  end

  describe "max_results on the orders reads" do
    test "anything but a positive integer is refused before a request" do
      for bad <- [0, -1, 1.5, "5", :all] do
        refusal = {:error, {:invalid_option, :max_results, bad}}
        opts = window(max_results: bad)

        assert Rest.check_order_window(opts) == refusal
        assert Rest.get_orders(@creds, "H", opts) == refusal
        assert Fake.get_orders(@creds, [account_hash: "H"] ++ opts) == refusal
        assert Rest.check_all_orders_window(opts ++ [now: @to]) == refusal
      end
    end

    test "an invalid status is still judged before max_results" do
      opts = window(status: "nope", max_results: 0)
      assert Rest.check_order_window(opts) == {:error, {:invalid_order_status, "nope"}}
    end

    test "a positive integer, and an absent or nil one, pass" do
      assert Rest.check_order_window(window(max_results: 1)) == :ok
      assert Rest.check_order_window(window([])) == :ok
      assert Rest.check_order_window(window(max_results: nil)) == :ok
    end

    test "a valid max_results reaches the venue as maxResults" do
      parent = self()

      plug = fn conn ->
        send(parent, {:query, conn.query_string})
        Req.Test.json(conn, [])
      end

      assert {:ok, []} =
               Rest.get_orders(@creds, "H", window(max_results: 5, plug: plug, retry_attempts: 0))

      assert_receive {:query, query}, 5_000
      assert URI.decode_query(query)["maxResults"] == "5"
    end
  end

  describe "limit on get_historical_prices" do
    test "is unsupported on the real path, whatever its value" do
      for limit <- [1, 500, 0, "10"] do
        assert Rest.check_history("1d", [], ~U[2026-10-01 00:00:00Z], limit: limit) ==
                 {:error, {:unsupported_option, :limit}}

        assert Schwab.get_historical_prices("AAPL", "1d", [], credentials: @creds, limit: limit) ==
                 {:error, {:unsupported_option, :limit}}

        assert Fake.get_historical_prices("AAPL", "1d", [], credentials: @creds, limit: limit) ==
                 {:error, {:unsupported_option, :limit}}
      end
    end

    test "a forwarded nil limit is silence" do
      assert Rest.check_history("1d", [], ~U[2026-10-01 00:00:00Z], limit: nil) == :ok
    end
  end

  describe "subscribe/2 market-data options the Streamer cannot honour" do
    test "include_partial: true is unsupported, a non-boolean is invalid" do
      assert Schwab.subscribe(["AAPL"], include_partial: true) ==
               {:error, {:unsupported_option, :include_partial}}

      assert Schwab.subscribe(["AAPL"], include_partial: "yes") ==
               {:error, {:invalid_option, :include_partial, "yes"}}

      assert Fake.subscribe(["AAPL"], include_partial: true) ==
               {:error, {:unsupported_option, :include_partial}}

      assert Fake.subscribe(["AAPL"], include_partial: 1) ==
               {:error, {:invalid_option, :include_partial, 1}}
    end

    test "limit, depth and since are unsupported" do
      for key <- [:limit, :depth, :since] do
        expected = {:error, {:unsupported_option, key}}

        assert Schwab.subscribe(["AAPL"], [{key, 5}]) == expected
        assert Fake.subscribe(["AAPL"], [{key, 5}]) == expected
      end
    end

    test "the symbols and the subscriber are judged before the options" do
      assert Schwab.subscribe("AAPL", limit: 5) == {:error, {:invalid_symbols, "AAPL"}}
      assert {:error, {:invalid_subscriber, "x"}} = Schwab.subscribe(["AAPL"], to: "x", limit: 5)
    end

    test "false and nil are silence: the call goes on to look for a feed" do
      assert Schwab.subscribe(["AAPL"], feed: :tick_aj_no_such_feed, include_partial: false) ==
               {:error, :feed_not_started}

      assert Schwab.subscribe(["AAPL"], feed: :tick_aj_no_such_feed, limit: nil, depth: nil) ==
               {:error, :feed_not_started}
    end
  end

  describe "a bad symbol, CUSIP or account hash on the raw reads" do
    test "get_symbol_quote refuses a nil, non-binary or blank symbol, on the Fake too" do
      for bad <- [nil, 7, "", "   "] do
        refusal = {:error, {:invalid_symbol, bad}}

        assert Rest.get_symbol_quote(bad, @creds, []) == refusal
        assert Schwab.get_symbol_quote(bad, @creds) == refusal
        assert Fake.get_symbol_quote(bad, @creds) == refusal
      end
    end

    test "get_transactions refuses a nil or non-binary account hash instead of raising" do
      opts = window(types: "TRADE")

      for bad <- [nil, 7, :hash] do
        assert Rest.get_transactions(@creds, bad, opts) ==
                 {:error, {:invalid_path_segment, :schwab}}
      end
    end

    test "get_instrument refuses a nil, blank or non-binary CUSIP" do
      for bad <- [nil, "", 37_833_100] do
        assert Rest.get_instrument(bad, @creds, []) == {:error, {:invalid_path_segment, :schwab}}
      end
    end
  end

  # What the refusal echoes: the value as given, with a `:credentials` entry redacted
  # (`Core.Options.check/2`, Core 0.3.113), so the token never reaches a logged tuple.
  defp echoed(%{credentials: _creds} = bad), do: %{bad | credentials: :redacted}
  defp echoed(bad), do: bad
end
