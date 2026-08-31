defmodule DpExchange.Schwab.DefensiveBranchesTest do
  @moduledoc """
  The clauses that exist so something cannot happen, plus the facade's own routing.

  Each targets a branch no ordinary call reaches. They all encode the same decision —
  refuse, or carry the absence forward, never substitute something plausible — and a
  branch nobody has exercised is a decision nobody has checked.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Schwab
  alias DpExchange.Schwab.Rest

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

  defp responding(body, status \\ 200) do
    fn conn -> Req.Test.json(%{conn | status: status}, body) end
  end

  defp opts(plug), do: [plug: plug, retry_attempts: 0]

  describe "empty strings are absent fields, not values" do
    test "an empty price is an unreadable quote" do
      body = %{"AAPL" => %{"quote" => %{"lastPrice" => "", "quoteTime" => 1_787_936_147_000}}}

      assert {:error, :unexpected_response_shape} =
               Rest.get_price("AAPL", @creds, opts(responding(body)))
    end

    test "an empty timestamp fails closed rather than taking the local clock" do
      body = %{"AAPL" => %{"quote" => %{"lastPrice" => 1.0, "quoteTime" => ""}}}

      assert {:error, :missing_venue_timestamp} =
               Rest.get_price("AAPL", @creds, opts(responding(body)))
    end

    test "an empty candle close is unreadable" do
      body = %{"candles" => [%{"close" => "", "datetime" => 1_787_936_147_000}]}

      assert {:error, :unexpected_response_shape} =
               Rest.get_historical_prices("AAPL", "1d", [], @creds, opts(responding(body)))
    end

    test "an explicitly null candle datetime is missing, not zero" do
      body = %{"candles" => [%{"close" => 1.0, "datetime" => nil}]}

      assert {:error, :missing_venue_timestamp} =
               Rest.get_historical_prices("AAPL", "1d", [], @creds, opts(responding(body)))
    end
  end

  describe "timestamps" do
    test "a seconds epoch is read as seconds, and milliseconds as milliseconds" do
      # A threshold rather than a fallback: guessing wrong puts a 2026 quote in 1970 or
      # in the year 58,000, and both are loud.
      seconds = %{"AAPL" => %{"quote" => %{"lastPrice" => 1.0, "quoteTime" => 1_787_936_147}}}
      millis = %{"AAPL" => %{"quote" => %{"lastPrice" => 1.0, "quoteTime" => 1_787_936_147_000}}}

      assert {:ok, from_seconds} = Rest.get_price("AAPL", @creds, opts(responding(seconds)))
      assert {:ok, from_millis} = Rest.get_price("AAPL", @creds, opts(responding(millis)))

      # Same instant; the millisecond parse carries {0, 3} precision and the second parse
      # {0, 0}, which is a difference in stated precision rather than in time.
      assert DateTime.compare(from_seconds.timestamp, from_millis.timestamp) == :eq
    end

    test "an epoch delivered as a string is read" do
      body = %{"AAPL" => %{"quote" => %{"lastPrice" => 1.0, "quoteTime" => "1787936147000"}}}

      assert {:ok, quote_struct} = Rest.get_price("AAPL", @creds, opts(responding(body)))
      assert quote_struct.timestamp.year == 2026
    end

    test "a timestamp of an unexpected type is an error, not a guess" do
      for value <- ["not-a-number", %{"nested" => true}, [1, 2]] do
        body = %{"AAPL" => %{"quote" => %{"lastPrice" => 1.0, "quoteTime" => value}}}

        assert {:error, {:unparseable_venue_timestamp, _value}} =
                 Rest.get_price("AAPL", @creds, opts(responding(body)))
      end
    end
  end

  describe "shapes the venue should never send" do
    test "a quote entry that is neither a quote nor an error is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_price("AAPL", @creds, opts(responding(%{"AAPL" => "surprise"})))
    end

    test "a non-map quotes response is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_price("AAPL", @creds, opts(responding([1, 2, 3])))
    end

    test "a pricehistory response with neither candles nor empty is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_historical_prices("AAPL", "1d", [], @creds, opts(responding([1])))
    end

    test "a non-map markets response is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.market_status(@creds, opts(responding([1])))
    end

    test "a non-list accountNumbers response is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_accounts(@creds, opts(responding(%{"oops" => true})))
    end

    test "a balances response with no securitiesAccount is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_balances(@creds, "H", opts(responding(%{})))
    end

    test "an instruments response with no instruments key is an empty search, not an error" do
      # "No instrument is called that" is a real answer, unlike "no such endpoint".
      assert {:ok, []} = Rest.get_symbols(@creds, opts(responding(%{})) ++ [query: "ZZZZ"])
    end
  end

  describe "searching instruments" do
    test "symbols are canonicalised and sorted" do
      body = %{"instruments" => [%{"symbol" => "msft"}, %{"symbol" => "aapl"}, %{}]}

      assert {:ok, ["AAPL", "MSFT"]} =
               Rest.get_symbols(@creds, opts(responding(body)) ++ [query: "A"])
    end

    test "the projection is selectable" do
      body = %{"instruments" => [%{"symbol" => "AAPL"}]}

      assert {:ok, ["AAPL"]} =
               Rest.get_symbols(
                 @creds,
                 opts(responding(body)) ++ [query: "apple", projection: "desc-search"]
               )
    end
  end

  describe "candle period selection" do
    test "monthly and ytd period types have day conversions" do
      # `1w` and `1M` route through periodType=year; the month and ytd conversions exist
      # because the venue's table has them and a partial table is how a width silently
      # picks the wrong lookback later.
      assert {:ok, days} = Rest.max_lookback_days("1M")
      assert days > 7_000

      assert Rest.max_lookback_days("nonsense") == :error
    end

    test "a short range picks a small period rather than always the largest" do
      body = %{"candles" => []}

      assert {:ok, []} =
               Rest.get_historical_prices(
                 "AAPL",
                 "1d",
                 [start: DateTime.add(DateTime.utc_now(), -30, :day)],
                 @creds,
                 opts(responding(body))
               )
    end

    test "an open-ended range measured from a start is still bounded" do
      exploding = fn _conn -> raise "a request was sent for an unreachable range" end

      assert {:error, {:lookback_exceeds_venue, "1m", _days, 10}} =
               Rest.get_historical_prices(
                 "AAPL",
                 "1m",
                 [start: DateTime.add(DateTime.utc_now(), -60, :day)],
                 @creds,
                 plug: exploding
               )
    end
  end

  describe "errors and refusals carry what the venue said" do
    test "an errors array detail is surfaced" do
      body = %{"errors" => [%{"detail" => "symbol not found"}]}

      assert {:refused, {:venue_error, 404, "symbol not found"}} =
               Rest.get_price("AAPL", @creds, opts(responding(body, 404)))
    end

    test "an error_description is surfaced" do
      body = %{"error_description" => "token expired"}

      assert {:refused, {:venue_error, 401, "token expired"}} =
               Rest.get_price("AAPL", @creds, opts(responding(body, 401)))
    end

    test "a refusal with no readable detail still carries the status" do
      plug = fn conn -> Plug.Conn.resp(conn, 403, "not json") end

      assert {:refused, {:venue_error, 403}} = Rest.get_price("AAPL", @creds, opts(plug))
    end

    test "a 5xx on the trading endpoints is an error, not a refusal" do
      assert {:error, {:exchange_error, :schwab, _msg}} =
               Rest.place_order(@creds, "H", %{}, opts(responding(%{}, 500)))

      assert {:error, {:exchange_error, :schwab, _msg}} =
               Rest.cancel_order(@creds, "H", "1", opts(responding(%{}, 500)))
    end

    test "a cancel with no credentials refuses before sending" do
      exploding = fn _conn -> raise "an unauthenticated cancel was sent" end

      assert Rest.cancel_order(%{}, "H", "1", plug: exploding) ==
               {:error, {:missing_credentials, :schwab}}
    end
  end

  describe "the Location header is read whatever shape it arrives in" do
    test "a plain string header works as well as a list" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/orders/42")
        |> Plug.Conn.resp(201, "")
      end

      assert {:ok, "42"} = Rest.place_order(@creds, "H", %{}, opts(plug))
    end
  end

  describe "balances on an account type the venue did not name" do
    test "available buying power is nil rather than invented" do
      body = %{
        "securitiesAccount" => %{
          "type" => "MARGIN",
          "currentBalances" => %{
            "liquidationValue" => 1.0
          }
        }
      }

      assert {:ok, [balance]} = Rest.get_balances(@creds, "H", opts(responding(body)))
      assert balance.available_balance == nil
    end
  end

  describe "decoding and coercion at the edges" do
    test "a JSON body delivered as a string is decoded" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, ~s({"AAPL":{"quote":{"lastPrice":1.5,"quoteTime":1787936147000}}}))
      end

      assert {:ok, quote_struct} = Rest.get_price("AAPL", @creds, opts(plug))
      assert Decimal.equal?(quote_struct.price, Decimal.from_float(1.5))
    end

    test "an empty body reads as the symbol not being returned" do
      plug = fn conn -> Plug.Conn.resp(conn, 200, "") end

      #  is what an unparseable body decodes to, and an absent symbol is a refusal
      # rather than an error: retrying changes nothing.
      assert {:refused, :not_listed} = Rest.get_price("AAPL", @creds, opts(plug))
    end

    test "an empty-string numeric field is nil, not zero" do
      # Zero is a price. A venue that sent no bid has not quoted a bid of nothing.
      body = %{
        "AAPL" => %{
          "quote" => %{"lastPrice" => 1.0, "bidPrice" => "", "quoteTime" => 1_787_936_147_000}
        }
      }

      assert {:ok, quote_struct} = Rest.get_price("AAPL", @creds, opts(responding(body)))
      assert quote_struct.bid == nil
    end

    test "numbers arrive as integers, floats, strings or Decimals and all become Decimal" do
      for {sent, expected} <- [
            {1, Decimal.new(1)},
            {1.5, Decimal.from_float(1.5)},
            {"2.25", Decimal.new("2.25")}
          ] do
        body = %{
          "AAPL" => %{"quote" => %{"lastPrice" => sent, "quoteTime" => 1_787_936_147_000}}
        }

        assert {:ok, quote_struct} = Rest.get_price("AAPL", @creds, opts(responding(body)))
        assert Decimal.equal?(quote_struct.price, expected)
      end
    end

    test "an instruments response that is a bare list is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_symbols(@creds, opts(responding([1, 2])) ++ [query: "A"])
    end
  end

  describe "order placement edge cases" do
    test "a 4xx that is not a rejection of the credential is still a refusal" do
      assert {:refused, {:venue_error, 404}} =
               Rest.place_order(@creds, "H", %{}, opts(responding("", 404)))
    end

    test "a 5xx reading one order is an error" do
      assert {:error, {:exchange_error, :schwab, _msg}} =
               Rest.get_order(@creds, "H", "1", opts(responding(%{}, 500)))
    end

    test "a transport failure surfaces rather than being swallowed" do
      plug = fn _conn -> raise "boom" end

      assert {:error, _reason} = Rest.place_order(@creds, "H", %{}, opts(plug))
      assert {:error, _reason} = Rest.cancel_order(@creds, "H", "1", opts(plug))
    end
  end

  describe "the feed's own plumbing" do
    setup do
      # The poller fetches in its own process, which does not see a process-scoped
      # override, so a real limiter is started and named instead.
      limiter = :"lim_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        DpExchange.Core.DefaultRateLimiter.start_link(
          name: limiter,
          limits: %{default: %{limit: 1000, per_ms: 1000, burst: 1000}}
        )

      {:ok, limiter: limiter}
    end

    test "a fetched quote reaches the subscriber through the sink", %{limiter: limiter} do
      # The wiring that makes a poll indistinguishable from a socket to whoever
      # subscribed.
      body = %{
        "AAPL" => %{
          "quote" => %{"lastPrice" => 227.5, "quoteTime" => 1_787_936_147_000}
        }
      }

      {:ok, feed} =
        Schwab.Feed.start_link(
          name: :"sink_feed_#{System.unique_integer([:positive])}",
          symbols: ["AAPL"],
          credentials: @creds,
          subscriber: self(),
          start_delay_ms: 0,
          interval_ms: 50,
          limiter: limiter,
          plug: responding(body),
          retry_attempts: 0
        )

      assert_receive {:dp_exchange, :schwab, %DpExchange.Core.Types.Quote{symbol: "AAPL"}}, 3_000
      assert Schwab.Feed.coverage(feed) == %{"AAPL" => :internal_poll}
    end

    test "a refusal reaches the subscriber rather than being retried forever", %{
      limiter: limiter
    } do
      # Only the adapter can tell a delisted symbol from a network blip, so only the
      # adapter decides. An unlisted symbol comes back absent from the quotes map.
      {:ok, _feed} =
        Schwab.Feed.start_link(
          name: :"refusal_feed_#{System.unique_integer([:positive])}",
          symbols: ["ZZZZ"],
          credentials: @creds,
          subscriber: self(),
          start_delay_ms: 0,
          interval_ms: 50,
          limiter: limiter,
          plug: responding(%{}),
          retry_attempts: 0
        )

      assert_receive {:dp_exchange, :schwab, {:refused, "ZZZZ", :not_listed}}, 3_000
    end
  end

  describe "the facade routes to the venue" do
    test "market data and trading all reach Rest" do
      quote_body = %{
        "AAPL" => %{"quote" => %{"lastPrice" => 1.0, "quoteTime" => 1_787_936_147_000}}
      }

      assert {:ok, _quote} =
               Schwab.get_price("AAPL", [credentials: @creds] ++ opts(responding(quote_body)))

      assert {:ok, []} =
               Schwab.get_historical_prices(
                 "AAPL",
                 "1d",
                 [],
                 [credentials: @creds] ++ opts(responding(%{"candles" => []}))
               )

      assert {:ok, :open} =
               Schwab.market_status(
                 [credentials: @creds] ++
                   opts(responding(%{"equity" => %{"EQ" => %{"isOpen" => true}}}))
               )

      assert {:ok, ["AAPL"]} =
               Schwab.get_symbols(
                 [credentials: @creds, query: "A"] ++
                   opts(responding(%{"instruments" => [%{"symbol" => "AAPL"}]}))
               )

      assert {:ok, [_account]} =
               Schwab.get_accounts(
                 @creds,
                 opts(responding([%{"accountNumber" => "1", "hashValue" => "H"}]))
               )

      assert {:ok, %{accounts: 1}} =
               Schwab.test_connection(
                 @creds,
                 opts(responding([%{"accountNumber" => "1", "hashValue" => "H"}]))
               )
    end

    test "account-scoped calls reach Rest once a hash is supplied" do
      balances = %{
        "securitiesAccount" => %{"type" => "CASH", "currentBalances" => %{"totalCash" => 1.0}}
      }

      base = [credentials: @creds, account_hash: "H"]

      assert {:ok, [_balance]} = Schwab.get_balances(@creds, base ++ opts(responding(balances)))
      assert {:ok, []} = Schwab.get_orders(@creds, base ++ opts(responding([])))
      assert {:ok, %{}} = Schwab.get_order(@creds, "1", base ++ opts(responding(%{})))

      assert :ok =
               Schwab.cancel_order(
                 @creds,
                 "1",
                 base ++ opts(fn c -> Plug.Conn.resp(c, 200, "") end)
               )
    end

    test "place_order builds and sends" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/orders/7")
        |> Plug.Conn.resp(201, "")
      end

      request = %{symbol: "AAPL", side: :buy, quantity: 1}

      assert {:ok, "7"} =
               Schwab.place_order(@creds, request, [account_hash: "H"] ++ opts(plug))
    end

    test "an invalid order never reaches the venue" do
      exploding = fn _conn -> raise "an order the venue publishes as invalid was sent" end

      request = %{symbol: "AAPL", instruction: "BUY_TO_OPEN", quantity: 1}

      assert {:error, {:instruction_not_valid_for_asset, "BUY_TO_OPEN", "EQUITY"}} =
               Schwab.place_order(@creds, request, account_hash: "H", plug: exploding)
    end

    test "coverage accepts a pid as well as a name" do
      {:ok, feed} =
        Schwab.Feed.start_link(
          name: :"pid_feed_#{System.unique_integer([:positive])}",
          symbols: [],
          start_delay_ms: 60_000
        )

      assert Schwab.coverage(feed: feed) == %{}
    end
  end
end
