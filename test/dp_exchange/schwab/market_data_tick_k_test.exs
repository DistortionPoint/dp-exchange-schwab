defmodule DpExchange.Schwab.MarketDataTickKTest do
  @moduledoc """
  Tick K review of the market-data surface: a book dated by the wrong field, a zero last
  price published as a traded price, a non-object order body, and a quadratic chain decode.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.{OptionChain, TopOfBook}
  alias DpExchange.Schwab.{Rest, StreamerDecode}

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
  @observed ~U[2026-08-28 14:53:02Z]

  defp responding(body, status \\ 200) do
    fn conn -> Req.Test.json(%{conn | status: status}, body) end
  end

  defp opts(plug), do: [plug: plug, retry_attempts: 0]

  describe "get_top_of_book/3 dates the book by quoteTime alone" do
    defp book_body(times) do
      %{
        "AAPL" => %{
          "quote" => Map.merge(%{"bidPrice" => 227.4, "askPrice" => 227.6}, times)
        }
      }
    end

    test "a row with only a tradeTime has an undated book, not the print's time" do
      body = book_body(%{"tradeTime" => 1_787_936_147_000})

      assert {:ok, %TopOfBook{venue_time: nil}} =
               Rest.get_top_of_book("AAPL", @creds, opts(responding(body)))
    end

    test "a zero quoteTime beside a tradeTime is still undated" do
      body = book_body(%{"quoteTime" => 0, "tradeTime" => 1_787_936_147_000})

      assert {:ok, %TopOfBook{venue_time: nil}} =
               Rest.get_top_of_book("AAPL", @creds, opts(responding(body)))
    end

    test "quoteTime dates the book even when the last trade is far older" do
      body = book_body(%{"quoteTime" => 1_787_936_147_000, "tradeTime" => 1_700_000_000_000})

      assert {:ok, %TopOfBook{venue_time: at}} =
               Rest.get_top_of_book("AAPL", @creds, opts(responding(body)))

      assert at == DateTime.from_unix!(1_787_936_147_000, :millisecond)
    end
  end

  describe "StreamerDecode.to_quote/3 refuses a zero or negative last" do
    test "zero, as a number and as text, is no traded price" do
      for last <- [0, 0.0, "0", "0.00", Decimal.new(0)] do
        assert {:error, :no_traded_price} =
                 StreamerDecode.to_quote(%{last: last, bid: 1.0, ask: 1.1}, "AAPL", @observed)
      end
    end

    test "a negative last is no traded price" do
      assert {:error, :no_traded_price} =
               StreamerDecode.to_quote(%{last: -1.5}, "AAPL", @observed)
    end

    test "a positive last still decodes" do
      assert {:ok, quoted} = StreamerDecode.to_quote(%{last: "0.01"}, "AAPL", @observed)
      assert Decimal.equal?(quoted.price, Decimal.new("0.01"))
    end
  end

  describe "get_historical_prices/5 query" do
    test "a forwarded extended_hours: nil is silence, sent as false, never blank" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:query, conn.query_string})
        Req.Test.json(conn, %{"candles" => [], "symbol" => "AAPL", "empty" => false})
      end

      assert {:ok, []} =
               Rest.get_historical_prices(
                 "AAPL",
                 "1d",
                 [],
                 @creds,
                 plug: plug,
                 retry_attempts: 0,
                 extended_hours: nil
               )

      assert_receive {:query, query}, 5_000
      params = URI.decode_query(query)
      assert params["needExtendedHoursData"] == "false"
      assert params["periodType"] == "year"
      assert params["frequencyType"] == "daily"
    end
  end

  describe "get_order/4 answers an object or a refusal" do
    test "a list body is an unreadable reply, not an order" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_order(@creds, "H", "1", opts(responding([%{"orderId" => 1}])))
    end

    test "an object body is returned as sent" do
      assert {:ok, %{"orderId" => 1}} =
               Rest.get_order(@creds, "H", "1", opts(responding(%{"orderId" => 1})))
    end
  end

  describe "get_option_chain/3 on a large chain" do
    test "every contract lands in its slot, in one pass" do
      strikes = for n <- 1..400, do: "#{n}.0"
      expiries = ["2026-03-20:15", "2026-04-17:43", "2026-06-19:106"]

      side = fn letter ->
        for expiry <- expiries, into: %{} do
          {expiry,
           for strike <- strikes, into: %{} do
             {strike, [%{"symbol" => "#{letter}-#{expiry}-#{strike}"}]}
           end}
        end
      end

      body = %{
        "symbol" => "AAPL",
        "callExpDateMap" => side.("C"),
        "putExpDateMap" => side.("P")
      }

      assert {:ok, %OptionChain{expiries: grid}} =
               Rest.get_option_chain("AAPL", @creds, opts(responding(body)))

      assert map_size(grid) == 3

      for {_expiry, row_map} <- grid do
        assert map_size(row_map) == 400
        assert Enum.all?(row_map, fn {_strike, row} -> row.call && row.put end)
      end

      row = grid[~D[2026-04-17]][Decimal.new("123.0")]
      assert row.call.venue_symbol == "C-2026-04-17:43-123.0"
      assert row.put.venue_symbol == "P-2026-04-17:43-123.0"
    end
  end
end
