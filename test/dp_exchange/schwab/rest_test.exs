defmodule DpExchange.Schwab.RestTest do
  @moduledoc """
  The REST surface, and mostly the refusals.

  The one to read is "a year of one-minute data is refused". Schwab reaches minute
  candles only through `periodType=day`, whose deepest lookback is ten days. Every
  plausible wrong answer is available here — ten days of minutes, or a year of daily
  bars — and both would flow downstream looking exactly like what was asked for.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.{Candle, Quote}
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

  defp quote_body(fields) do
    %{"AAPL" => %{"quote" => Map.merge(%{"quoteTime" => 1_787_936_147_000}, fields)}}
  end

  describe "get_price/3" do
    test "builds a quote from the venue's own fields and clock" do
      body =
        quote_body(%{
          "lastPrice" => 227.5,
          "bidPrice" => 227.4,
          "askPrice" => 227.6,
          "totalVolume" => 51_234_567
        })

      assert {:ok, %Quote{} = quote_struct} =
               Rest.get_price("AAPL", @creds, plug: responding(body), retry_attempts: 0)

      assert quote_struct.symbol == "AAPL"
      assert Decimal.equal?(quote_struct.price, Decimal.from_float(227.5))

      assert Decimal.equal?(quote_struct.volume, Decimal.new(51_234_567))
      assert quote_struct.timestamp.year == 2026
      assert quote_struct.provider == :schwab
    end

    test "mark is used only when there is no last, and no mid is ever computed" do
      # What a price MEANS is the caller's decision. `mark` is the venue's own derived
      # value, which is a number Schwab published; a mid of bid and ask would be one we
      # invented.
      body = quote_body(%{"mark" => 100.0, "bidPrice" => 99.0, "askPrice" => 101.0})

      assert {:ok, quote_struct} =
               Rest.get_price("AAPL", @creds, plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(quote_struct.price, Decimal.from_float(100.0))
    end

    test "no price at all is unreadable rather than a nil-priced quote" do
      body = quote_body(%{"bidPrice" => 99.0, "askPrice" => 101.0})

      assert {:error, :unexpected_response_shape} =
               Rest.get_price("AAPL", @creds, plug: responding(body), retry_attempts: 0)
    end

    test "a non-numeric price refuses the quote rather than delivering price: nil" do
      # Decimal.new/1 used to raise here. The fix must not trade a crash for a Quote whose
      # required :price is silently nil, which is the same substitution wearing a
      # quieter shape.
      body = quote_body(%{"lastPrice" => "null"})

      assert {:error, {:invalid_decimal, :price, "null"}} =
               Rest.get_price("AAPL", @creds, plug: responding(body), retry_attempts: 0)
    end

    test "a quote the venue did not date fails closed" do
      body = %{"AAPL" => %{"quote" => %{"lastPrice" => 227.5}}}

      assert {:error, :missing_venue_timestamp} =
               Rest.get_price("AAPL", @creds, plug: responding(body), retry_attempts: 0)
    end

    test "an unlisted symbol is refused, whether absent or returned as an error object" do
      for body <- [%{}, %{"AAPL" => %{"errors" => [%{"detail" => "not found"}]}}] do
        assert {:refused, :not_listed} =
                 Rest.get_price("AAPL", @creds, plug: responding(body), retry_attempts: 0)
      end
    end

    test "a crypto pair never reaches the venue" do
      exploding = fn _conn -> raise "a request was sent for a pair-shaped symbol" end

      assert {:error, {:not_an_equity_symbol, "BTC-USD"}} =
               Rest.get_price("BTC-USD", @creds, plug: exploding)
    end

    test "no credentials refuses before any request" do
      exploding = fn _conn -> raise "an unauthenticated request was sent" end

      assert Rest.get_price("AAPL", %{}, plug: exploding) ==
               {:error, {:missing_credentials, :schwab}}
    end

    test "a 401 is a refusal naming the status, so a caller can refresh and retry" do
      assert {:refused, {:venue_error, 401}} =
               Rest.get_price("AAPL", @creds, plug: responding("", 401), retry_attempts: 0)
    end

    test "a 500 is an error, not a refusal" do
      assert {:error, {:exchange_error, :schwab, message}} =
               Rest.get_price("AAPL", @creds, plug: responding(%{}, 500), retry_attempts: 0)

      assert message =~ "500"
    end
  end

  describe "the candle triple — refusing rather than substituting" do
    test "every declared width maps to a legal triple" do
      assert Rest.timeframes() == ~w(1m 5m 10m 15m 30m 1d 1w 1M)

      for timeframe <- Rest.timeframes() do
        assert {:ok, _days} = Rest.max_lookback_days(timeframe)
      end
    end

    test "minute widths cap at ten days, and daily widths reach years" do
      for minute <- ~w(1m 5m 10m 15m 30m) do
        assert Rest.max_lookback_days(minute) == {:ok, 10}
      end

      assert {:ok, days} = Rest.max_lookback_days("1d")
      assert days > 7_000
    end

    test "a year of one-minute data is REFUSED, not truncated and not downgraded" do
      # The failure this venue makes available: ten days of minutes, or a year of daily
      # bars. Both are plausible, both are wrong, and neither is distinguishable
      # downstream from what was asked for.
      exploding = fn _conn -> raise "a request was sent for a range the venue cannot serve" end

      range = [start: ~U[2025-08-31 00:00:00Z], end: ~U[2026-08-31 00:00:00Z]]

      assert {:error, {:lookback_exceeds_venue, "1m", requested, 10}} =
               Rest.get_historical_prices("AAPL", "1m", range, @creds, plug: exploding)

      assert requested > 300
    end

    test "a width the venue does not serve is named, not approximated" do
      exploding = fn _conn -> raise "a request was sent for an unsupported width" end

      assert {:error, {:unsupported_timeframe, "1h"}} =
               Rest.get_historical_prices("AAPL", "1h", [], @creds, plug: exploding)

      assert {:error, {:unsupported_timeframe, "3m"}} =
               Rest.get_historical_prices("AAPL", "3m", [], @creds, plug: exploding)
    end

    test "a range within reach is served" do
      body = %{
        "candles" => [
          %{
            "open" => 1.0,
            "high" => 2.0,
            "low" => 0.5,
            "close" => 1.5,
            "volume" => 100,
            "datetime" => 1_787_936_147_000
          }
        ]
      }

      range = [start: DateTime.add(DateTime.utc_now(), -3, :day)]

      assert {:ok, [%Candle{} = candle]} =
               Rest.get_historical_prices("AAPL", "5m", range, @creds,
                 plug: responding(body),
                 retry_attempts: 0
               )

      # A bar carries four prices, and the close is only one of them. This asserted
      # `candle.price` until 2026-08-31, when the callback still returned Quotes and open,
      # high and low were discarded at the boundary.
      assert Decimal.equal?(candle.close, Decimal.from_float(1.5))
      assert Decimal.equal?(candle.volume, Decimal.new(100))
      assert candle.open
      assert candle.high
      assert candle.low
      assert candle.opened_at
    end

    test "no range asks for the deepest the width allows" do
      body = %{"candles" => []}

      assert {:ok, []} =
               Rest.get_historical_prices("AAPL", "1d", [], @creds,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "the venue's own empty flag is a refusal, not zero candles" do
      # A caller must be able to tell "no data in this window" from "no such symbol".
      assert {:refused, :not_listed} =
               Rest.get_historical_prices("AAPL", "1d", [], @creds,
                 plug: responding(%{"empty" => true}),
                 retry_attempts: 0
               )
    end

    test "an undated candle fails closed rather than taking the local clock" do
      body = %{"candles" => [%{"close" => 1.5}]}

      assert {:error, :missing_venue_timestamp} =
               Rest.get_historical_prices("AAPL", "1d", [], @creds,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "a candle with no close is unreadable" do
      body = %{"candles" => [%{"datetime" => 1_787_936_147_000}]}

      assert {:error, :unexpected_response_shape} =
               Rest.get_historical_prices("AAPL", "1d", [], @creds,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end
  end

  describe "market_status/2 — asked, never assumed" do
    test "an open market is read from the venue's own isOpen" do
      body = %{"equity" => %{"EQ" => %{"isOpen" => true}}}

      assert Rest.market_status(@creds, plug: responding(body), retry_attempts: 0) ==
               {:ok, :open}
    end

    test "a closed market is closed" do
      body = %{"equity" => %{"EQ" => %{"isOpen" => false}}}

      assert Rest.market_status(@creds, plug: responding(body), retry_attempts: 0) ==
               {:ok, :closed}
    end

    test "a market the venue did not mention is unreadable, NOT closed" do
      # This is the whole reason `market_status/1` exists on this venue. Reporting
      # `:closed` because the response was unrecognisable would make a broken parser
      # indistinguishable from a Saturday, which is exactly the confusion it was added
      # to remove.
      for body <- [%{}, %{"equity" => %{}}, %{"option" => %{"EQ" => %{"isOpen" => true}}}] do
        assert {:error, :unexpected_response_shape} =
                 Rest.market_status(@creds, plug: responding(body), retry_attempts: 0)
      end
    end

    test "the market is selectable" do
      body = %{"option" => %{"EQO" => %{"isOpen" => true}}}

      assert Rest.market_status(@creds,
               market: "option",
               plug: responding(body),
               retry_attempts: 0
             ) == {:ok, :open}
    end
  end

  describe "accounts are addressed by hash, not by number" do
    test "both are returned, and the hash is what a caller uses" do
      body = [%{"accountNumber" => "123456789", "hashValue" => "ABCDEF"}]

      assert {:ok, [account]} =
               Rest.get_accounts(@creds, plug: responding(body), retry_attempts: 0)

      assert account == %{account_number: "123456789", hash: "ABCDEF"}
    end

    test "a response with no hash is unreadable — the number alone addresses nothing" do
      body = [%{"accountNumber" => "123456789"}]

      assert {:error, :unexpected_response_shape} =
               Rest.get_accounts(@creds, plug: responding(body), retry_attempts: 0)
    end
  end

  describe "balances read the account's declared type, never guessing" do
    test "a margin account reports liquidation value and buying power" do
      body = %{
        "securitiesAccount" => %{
          "type" => "MARGIN",
          "currentBalances" => %{"liquidationValue" => 50_000.0, "buyingPower" => 100_000.0}
        }
      }

      assert {:ok, [balance]} =
               Rest.get_balances(@creds, "ABCDEF", plug: responding(body), retry_attempts: 0)

      assert balance.currency == "USD"
      assert Decimal.equal?(balance.balance, Decimal.from_float(50_000.0))
      assert Decimal.equal?(balance.available_balance, Decimal.from_float(100_000.0))
    end

    test "a cash account reports total cash and cash available" do
      body = %{
        "securitiesAccount" => %{
          "type" => "CASH",
          "currentBalances" => %{"totalCash" => 2_500.0, "cashAvailableForTrading" => 2_500.0}
        }
      }

      assert {:ok, [balance]} =
               Rest.get_balances(@creds, "ABCDEF", plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(balance.balance, Decimal.from_float(2_500.0))
    end

    test "an account whose type the venue did not state is unreadable, not assumed" do
      # Reading a margin account as cash would report no buying power for an account
      # that has one — a plausible value, and the wrong one.
      body = %{"securitiesAccount" => %{"currentBalances" => %{"totalCash" => 1.0}}}

      assert {:error, :unexpected_response_shape} =
               Rest.get_balances(@creds, "ABCDEF", plug: responding(body), retry_attempts: 0)
    end

    test "a margin account missing its total is unreadable rather than zero" do
      body = %{"securitiesAccount" => %{"type" => "MARGIN", "currentBalances" => %{}}}

      assert {:error, :unexpected_response_shape} =
               Rest.get_balances(@creds, "ABCDEF", plug: responding(body), retry_attempts: 0)
    end
  end

  describe "placing an order" do
    test "the id comes from the Location header, which is where Schwab puts it" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header(
          "location",
          "https://api.schwabapi.com/trader/v1/accounts/X/orders/1005"
        )
        |> Plug.Conn.resp(201, "")
      end

      assert {:ok, "1005"} =
               Rest.place_order(@creds, "ABCDEF", %{"orderType" => "MARKET"},
                 plug: plug,
                 retry_attempts: 0
               )
    end

    test "a 201 with no Location is a failure, not a success with no id" do
      # A caller that cannot name the order it just placed cannot cancel it.
      plug = fn conn -> Plug.Conn.resp(conn, 201, "") end

      assert {:error, :order_id_not_returned} =
               Rest.place_order(@creds, "ABCDEF", %{}, plug: plug, retry_attempts: 0)
    end

    test "a rejected order is a refusal carrying the venue's reason" do
      body = %{"message" => "Order validation failed"}

      assert {:refused, {:venue_error, 400, "Order validation failed"}} =
               Rest.place_order(@creds, "ABCDEF", %{},
                 plug: responding(body, 400),
                 retry_attempts: 0
               )
    end

    test "no credentials refuses before sending an order" do
      exploding = fn _conn -> raise "an unauthenticated order was sent" end

      assert Rest.place_order(%{}, "ABCDEF", %{}, plug: exploding) ==
               {:error, {:missing_credentials, :schwab}}
    end
  end

  describe "cancelling and reading orders" do
    test "a successful cancel is :ok" do
      plug = fn conn -> Plug.Conn.resp(conn, 200, "") end

      assert :ok = Rest.cancel_order(@creds, "ABCDEF", "1005", plug: plug, retry_attempts: 0)
    end

    test "cancelling an order that is gone is a refusal, not an error" do
      assert {:refused, {:venue_error, 404}} =
               Rest.cancel_order(@creds, "ABCDEF", "1005",
                 plug: responding("", 404),
                 retry_attempts: 0
               )
    end

    test "orders come back as a list, and a non-list is unreadable" do
      assert {:ok, [%{"orderId" => 1}]} =
               Rest.get_orders(@creds, "ABCDEF",
                 plug: responding([%{"orderId" => 1}]),
                 retry_attempts: 0
               )

      assert {:error, :unexpected_response_shape} =
               Rest.get_orders(@creds, "ABCDEF", plug: responding(%{}), retry_attempts: 0)
    end

    test "one order is returned as the venue reports it" do
      assert {:ok, %{"orderId" => 1005}} =
               Rest.get_order(@creds, "ABCDEF", "1005",
                 plug: responding(%{"orderId" => 1005}),
                 retry_attempts: 0
               )
    end
  end

  describe "preview and atomic replace — the two the contract had no room for" do
    test "a preview returns the venue's own validation and cost estimate" do
      body = %{
        "orderStrategy" => %{"orderType" => "MARKET"},
        "orderValidationResult" => %{"rejects" => []},
        "commissionAndFee" => %{"commission" => %{"commissionLegs" => []}}
      }

      assert {:ok, preview} =
               Rest.preview_order(@creds, "ABCDEF", %{"orderType" => "MARKET"},
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert preview["orderValidationResult"] == %{"rejects" => []}
    end

    test "a rejected preview is a refusal carrying the venue's reason" do
      # The whole point: learn this WITHOUT spending one of a small number of writes.
      body = %{"message" => "Insufficient buying power"}

      assert {:refused, {:venue_error, 400, "Insufficient buying power"}} =
               Rest.preview_order(@creds, "ABCDEF", %{},
                 plug: responding(body, 400),
                 retry_attempts: 0
               )
    end

    test "a replacement returns a NEW order id, because it is a new order" do
      # A caller still holding the old id would be tracking an order that no longer
      # exists.
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/orders/2001")
        |> Plug.Conn.resp(201, "")
      end

      assert {:ok, "2001"} =
               Rest.replace_order(@creds, "ABCDEF", "1005", %{}, plug: plug, retry_attempts: 0)
    end

    test "a replacement the venue refuses is a refusal, not an error" do
      assert {:refused, {:venue_error, 404}} =
               Rest.replace_order(@creds, "ABCDEF", "1005", %{},
                 plug: responding("", 404),
                 retry_attempts: 0
               )
    end

    test "a 5xx on either is an error worth retrying" do
      assert {:error, {:exchange_error, :schwab, _m}} =
               Rest.preview_order(@creds, "H", %{}, plug: responding(%{}, 500), retry_attempts: 0)

      assert {:error, {:exchange_error, :schwab, _m}} =
               Rest.replace_order(@creds, "H", "1", %{},
                 plug: responding(%{}, 500),
                 retry_attempts: 0
               )
    end

    test "neither is sent without credentials" do
      exploding = fn _conn -> raise "an unauthenticated order call was sent" end

      assert Rest.preview_order(%{}, "H", %{}, plug: exploding) ==
               {:error, {:missing_credentials, :schwab}}

      assert Rest.replace_order(%{}, "H", "1", %{}, plug: exploding) ==
               {:error, {:missing_credentials, :schwab}}
    end
  end

  describe "base URLs" do
    test "two servers, both overridable" do
      assert Rest.market_data_url([]) == "https://api.schwabapi.com/marketdata/v1"
      assert Rest.trader_url([]) == "https://api.schwabapi.com/trader/v1"
      assert Rest.market_data_url(market_data_url: "http://x") == "http://x"
      assert Rest.trader_url(trader_url: "http://y") == "http://y"
    end
  end
end
