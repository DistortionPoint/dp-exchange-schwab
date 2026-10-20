defmodule DpExchange.Schwab.MarketDataReviewTest do
  @moduledoc """
  Market-data refusals found by reading the REST path against the vendor's OpenAPI document.

  Each test names a plausible wrong answer that used to be available: a chain contract
  silently replaced by another, a last trading day one day late, a requested range dropped
  for the most recent window, a date the venue cannot read.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
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

  defp responding(body), do: fn conn -> Req.Test.json(conn, body) end

  defp exploding(message) do
    fn _conn -> raise "a request was sent: #{message}" end
  end

  defp capturing(body) do
    me = self()

    fn conn ->
      send(me, {:request, conn.request_path, conn.query_string})
      Req.Test.json(conn, body)
    end
  end

  defp contract(symbol, extra \\ %{}), do: Map.merge(%{"symbol" => symbol}, extra)

  defp chain(call_rows, put_rows \\ []) do
    %{
      "symbol" => "SPX",
      "callExpDateMap" => %{"2026-03-20:15" => %{"5000.0" => call_rows}},
      "putExpDateMap" => %{"2026-03-20:15" => %{"5000.0" => put_rows}}
    }
  end

  describe "an option chain slot holding two contracts" do
    test "is refused, not resolved to the last contract listed" do
      body = chain([contract("SPX   260320C05000000"), contract("SPXW  260320C05000000")])

      assert {:error, {:ambiguous_chain_row, ~D[2026-03-20], strike, :call}} =
               Rest.get_option_chain("SPX", @creds, plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(strike, 5000)
    end

    test "one contract per side still builds" do
      body = chain([contract("SPX   260320C05000000")], [contract("SPX   260320P05000000")])

      assert {:ok, chain} =
               Rest.get_option_chain("SPX", @creds, plug: responding(body), retry_attempts: 0)

      [{_strike, row}] = Map.to_list(chain.expiries[~D[2026-03-20]])
      assert row.call.venue_symbol == "SPX   260320C05000000"
      assert row.put.venue_symbol == "SPX   260320P05000000"
    end

    test "the raw read keeps every contract for a caller that can choose" do
      body = chain([contract("SPX   260320C05000000"), contract("SPXW  260320C05000000")])

      assert {:ok, raw} =
               Rest.get_chains(@creds,
                 symbol: "SPX",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert [_one, _two] = raw["callExpDateMap"]["2026-03-20:15"]["5000.0"]
    end
  end

  describe "last_trading_day is the US Eastern day of the venue's stamp" do
    defp last_trading_day(stamp) do
      body = chain([contract("SPX   260320C05000000", %{"lastTradingDay" => stamp})])

      {:ok, chain} =
        Rest.get_option_chain("SPX", @creds, plug: responding(body), retry_attempts: 0)

      [{_strike, row}] = Map.to_list(chain.expiries[~D[2026-03-20]])
      row.call.last_trading_day
    end

    test "the vendor's own example in daylight time reads the Friday, not the Saturday" do
      # 1655510400000 is 2022-06-18T00:00Z: Friday 2022-06-17 20:00 EDT.
      assert last_trading_day(1_655_510_400_000) == ~D[2022-06-17]
    end

    test "the vendor's own example in standard time reads the Thursday, not the Friday" do
      # 1702602000000 is 2023-12-15T01:00Z: Thursday 2023-12-14 20:00 EST.
      assert last_trading_day(1_702_602_000_000) == ~D[2023-12-14]
    end

    test "the daylight-time boundary is honoured on both sides" do
      # A date differs between the two offsets only for instants in 04:00-05:00Z, so those
      # are the ones that prove which offset applied. Daylight time began 2026-03-08 07:00Z
      # and ended 2026-11-01 06:00Z.
      assert last_trading_day(at(~U[2026-03-08 04:30:00Z])) == ~D[2026-03-07]
      assert last_trading_day(at(~U[2026-03-09 04:30:00Z])) == ~D[2026-03-09]
      assert last_trading_day(at(~U[2026-11-01 04:30:00Z])) == ~D[2026-11-01]
      assert last_trading_day(at(~U[2026-11-02 04:30:00Z])) == ~D[2026-11-01]
    end

    test "an instant before the current US rule has no honest date here" do
      assert last_trading_day(at(~U[2005-06-10 12:00:00Z])) == nil
    end

    defp at(datetime), do: DateTime.to_unix(datetime, :millisecond)
  end

  describe "chain date parameters" do
    test "a Date and an ISO string are sent as yyyy-MM-dd" do
      assert {:ok, _result} =
               Rest.get_chains(@creds,
                 symbol: "AAPL",
                 from_date: ~D[2026-03-01],
                 to_date: "2026-04-01",
                 plug: capturing(%{}),
                 retry_attempts: 0
               )

      assert_receive {:request, "/marketdata/v1/chains", query}
      assert query =~ "fromDate=2026-03-01"
      assert query =~ "toDate=2026-04-01"
    end

    test "a DateTime or a malformed string is refused before the request" do
      assert {:error, {:invalid_date, :from_date, ~U[2026-03-01 12:00:00Z]}} =
               Rest.get_chains(@creds,
                 symbol: "AAPL",
                 from_date: ~U[2026-03-01 12:00:00Z],
                 plug: exploding("DateTime fromDate"),
                 retry_attempts: 0
               )

      assert {:error, {:invalid_date, :to_date, "03/01/2026"}} =
               Rest.get_chains(@creds,
                 symbol: "AAPL",
                 to_date: "03/01/2026",
                 plug: exploding("malformed toDate"),
                 retry_attempts: 0
               )
    end

    test "a market's date follows the same rule" do
      assert {:error, {:invalid_date, :date, ~U[2026-07-04 12:00:00Z]}} =
               Rest.get_market("bond", @creds,
                 date: ~U[2026-07-04 12:00:00Z],
                 plug: exploding("DateTime market date"),
                 retry_attempts: 0
               )
    end
  end

  describe "price history ranges" do
    test "a start that is not a DateTime is refused, not dropped for the latest window" do
      bad_start = [start: 1_780_000_000_000]

      assert {:error, {:invalid_range, ^bad_start}} =
               Rest.get_historical_prices("AAPL", "1d", bad_start, @creds,
                 plug: exploding("integer start"),
                 retry_attempts: 0
               )

      bad_end = [start: ~U[2026-06-01 00:00:00Z], end: ~D[2026-06-05]]

      assert {:error, {:invalid_range, ^bad_end}} =
               Rest.get_historical_prices("AAPL", "1d", bad_end, @creds,
                 plug: exploding("Date end"),
                 retry_attempts: 0
               )
    end

    test "a range that is not a keyword list is refused before any request, never raised" do
      for bad <- [nil, 5, "range", %{start: 1}, [1, 2], [start: nil] ++ :improper] do
        assert {:error, {:invalid_range, ^bad}} =
                 Rest.get_historical_prices("AAPL", "1d", bad, @creds,
                   plug: exploding("non-keyword range"),
                   retry_attempts: 0
                 )
      end
    end

    test "a blank or nil symbol is {:invalid_symbol, v}, before any request" do
      for bad <- [nil, 5, "", "  "] do
        assert {:error, {:invalid_symbol, ^bad}} =
                 Rest.get_historical_prices(bad, "1d", [], @creds,
                   plug: exploding("bad symbol"),
                   retry_attempts: 0
                 )

        assert {:error, {:invalid_symbol, ^bad}} =
                 Rest.get_price(bad, @creds, plug: exploding("bad symbol"), retry_attempts: 0)

        assert {:error, {:invalid_symbol, ^bad}} =
                 Rest.get_top_of_book(bad, @creds,
                   plug: exploding("bad symbol"),
                   retry_attempts: 0
                 )
      end
    end

    test "a minute lookback a fraction past ten days is eleven days, and refused" do
      range = [start: ~U[2026-06-01 00:00:00Z], end: ~U[2026-06-11 01:00:00Z]]

      assert {:error, {:range_unavailable, "1m", earliest: %DateTime{}, requested: requested}} =
               Rest.get_historical_prices("AAPL", "1m", range, @creds,
                 plug: exploding("ten days and an hour"),
                 retry_attempts: 0
               )

      assert requested == ~U[2026-06-01 00:00:00Z]
    end

    test "exactly ten days of minutes is still served" do
      range = [start: ~U[2026-06-01 00:00:00Z], end: ~U[2026-06-11 00:00:00Z]]

      assert {:ok, []} =
               Rest.get_historical_prices("AAPL", "1m", range, @creds,
                 plug: responding(%{"candles" => []}),
                 retry_attempts: 0
               )
    end

    test "a bar stamped zero is undated, not 1970" do
      body = %{
        "candles" => [%{"open" => 1, "high" => 2, "low" => 1, "close" => 2, "datetime" => 0}]
      }

      assert {:error, :missing_venue_timestamp} =
               Rest.get_historical_prices("AAPL", "1d", [], @creds,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end
  end

  describe "market_status/2 and the venue's market enum" do
    test "a market outside the enum is refused before the request, not raised on" do
      assert {:error, {:unknown_market, "crypto"}} =
               Rest.market_status(@creds,
                 market: "crypto",
                 plug: exploding("crypto market"),
                 retry_attempts: 0
               )

      assert {:error, {:unknown_market, :equity}} =
               Rest.market_status(@creds,
                 market: :equity,
                 plug: exploding("atom market"),
                 retry_attempts: 0
               )
    end

    test "the fake refuses the same market" do
      assert {:error, {:unknown_market, "crypto"}} =
               Fake.market_status(credentials: @creds, market: "crypto")

      assert {:ok, :open} = Fake.market_status(credentials: @creds, market: "option")
    end
  end

  describe "movers filters are the venue's enums" do
    test "a sort outside the enum is refused before the request" do
      assert {:error, {:invalid_sort, "volume"}} =
               Rest.get_movers("$SPX", @creds,
                 sort: "volume",
                 plug: exploding("lower-case sort"),
                 retry_attempts: 0
               )
    end

    test "a frequency outside the enum is refused, including a numeric string" do
      for bad <- [2, "60", -1] do
        assert {:error, {:invalid_frequency, ^bad}} =
                 Rest.get_movers("$SPX", @creds,
                   frequency: bad,
                   plug: exploding("bad frequency"),
                   retry_attempts: 0
                 )
      end
    end

    test "every listed value is sent" do
      for sort <- ~w(VOLUME TRADES PERCENT_CHANGE_UP PERCENT_CHANGE_DOWN), freq <- [0, 60] do
        assert {:ok, _result} =
                 Rest.get_movers("NASDAQ", @creds,
                   sort: sort,
                   frequency: freq,
                   plug: capturing(%{"screeners" => []}),
                   retry_attempts: 0
                 )

        # "Sent" is the claim: the value reaches the venue in the query, not only past the check.
        assert_receive {:request, _path, query}, 5_000
        assert %{"sort" => ^sort, "frequency" => frequency} = URI.decode_query(query)
        assert frequency == Integer.to_string(freq)
      end
    end

    test "the screener refuses the same filters, and so does the fake" do
      assert {:error, {:invalid_sort, "nope"}} =
               Rest.get_screener("$SPX", @creds,
                 sort: "nope",
                 plug: exploding("screener sort"),
                 retry_attempts: 0
               )

      assert {:error, {:invalid_sort, "nope"}} =
               Fake.get_screener("$SPX", credentials: @creds, sort: "nope")

      assert {:error, {:invalid_frequency, 3}} =
               Fake.get_screener("$SPX", credentials: @creds, frequency: 3)
    end
  end

  describe "an instrument CUSIP is one path segment" do
    test "a slash or question mark is escaped, not read as path or query" do
      assert {:ok, _result} =
               Rest.get_instrument("037/833?100", @creds,
                 plug: capturing(%{}),
                 retry_attempts: 0
               )

      assert_receive {:request, path, query}
      assert path == "/marketdata/v1/instruments/037%2F833%3F100"
      assert query == ""
    end
  end
end
