defmodule DpExchange.Schwab.RestGapsTest do
  @moduledoc """
  The REST branches an ordinary response never takes: a half-empty book, a chain the venue
  shaped wrongly, a position row that cannot be attributed, and an order write that fails in
  a way a caller must read correctly.

  Each asserts what the decoder MUST do: refuse by name, or carry an absence forward as
  `nil`. None substitutes a nearby value.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.TopOfBook
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

  # A blocking acquire that gave up waiting: this package's own limiter refusing, before any
  # request was built.
  defmodule TimedOutLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: {:error, :rate_limit_timeout}
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
  @quote_time 1_787_936_147_000

  defp responding(body, status \\ 200) do
    fn conn -> Req.Test.json(%{conn | status: status}, body) end
  end

  defp opts(plug), do: [plug: plug, retry_attempts: 0]

  defp quote_body(fields) do
    %{"AAPL" => %{"quote" => Map.merge(%{"quoteTime" => @quote_time}, fields)}}
  end

  defp accounts_with(positions), do: [%{"securitiesAccount" => %{"positions" => positions}}]

  describe "get_top_of_book/3 — a side the venue left empty" do
    test "a null bid price is no resting bid, and the ask is still read" do
      body = quote_body(%{"bidPrice" => nil, "askPrice" => 101.0, "askSize" => 5})

      assert {:ok, %TopOfBook{} = book} =
               Rest.get_top_of_book("AAPL", @creds, opts(responding(body)))

      assert book.bid == nil
      assert book.bid_size == nil
      assert Decimal.equal?(book.ask, 101)
      assert Decimal.equal?(book.ask_size, 5)
    end

    test "an unreadable or negative ask size beside a live ask refuses the whole book" do
      for bad <- ["abc", -1] do
        body =
          quote_body(%{"bidPrice" => 99.0, "bidSize" => 5, "askPrice" => 101.0, "askSize" => bad})

        assert Rest.get_top_of_book("AAPL", @creds, opts(responding(body))) ==
                 {:error, {:invalid_decimal, :ask_size, bad}}
      end
    end
  end

  describe "get_price/3 — a price that is not a number at all" do
    test "a boolean or an object where a price belongs is refused by name, not read as absent" do
      for bad <- [true, %{"value" => 1}] do
        body = quote_body(%{"lastPrice" => bad})

        assert Rest.get_price("AAPL", @creds, opts(responding(body))) ==
                 {:error, {:invalid_decimal, :price, bad}}
      end
    end
  end

  describe "get_historical_prices/5 — a bar price that is present but empty" do
    test "an empty open is an unreadable bar, not a bar with a nil open" do
      body = %{
        "candles" => [
          %{
            "open" => "",
            "high" => 2.0,
            "low" => 0.5,
            "close" => 1.5,
            "datetime" => @quote_time
          }
        ]
      }

      assert Rest.get_historical_prices("AAPL", "1d", [], @creds, opts(responding(body))) ==
               {:error, :unexpected_response_shape}
    end
  end

  describe "get_option_chain/3 — shapes the venue should not send" do
    test "a side that is not an object refuses the chain" do
      body = %{"callExpDateMap" => []}

      assert Rest.get_option_chain("AAPL", @creds, opts(responding(body))) ==
               {:error, :unexpected_response_shape}
    end

    test "an expiry whose strikes are not an object refuses the chain" do
      body = %{"callExpDateMap" => %{"2026-03-20:15" => []}}

      assert Rest.get_option_chain("AAPL", @creds, opts(responding(body))) ==
               {:error, :unexpected_response_shape}
    end

    test "a last trading day past the calendar is unstated, never a guessed date" do
      body = %{
        "callExpDateMap" => %{
          "2026-03-20:15" => %{
            "200.0" => [
              %{"symbol" => "AAPL  260320C00200000", "lastTradingDay" => 9_999_999_999_999_999}
            ]
          }
        }
      }

      assert {:ok, chain} = Rest.get_option_chain("AAPL", @creds, opts(responding(body)))

      contract = chain.expiries[~D[2026-03-20]][Decimal.new("200.0")].call
      assert contract.venue_symbol == "AAPL  260320C00200000"
      assert contract.last_trading_day == nil
    end
  end

  describe "get_option_expirations/3 — rows without a date" do
    test "a row that names no date is dropped, and the dated ones are kept" do
      rows = [%{}, "2026-03-20", %{"expiration" => "2026-03-20"}, %{"expiration" => 5}]
      body = %{"expirationList" => rows}

      assert Rest.get_option_expirations("AAPL", @creds, opts(responding(body))) ==
               {:ok, [~D[2026-03-20]]}
    end

    test "an absent list is no expirations listed" do
      assert Rest.get_option_expirations("AAPL", @creds, opts(responding(%{}))) == {:ok, []}
    end
  end

  describe "get_positions/2 — rows that need care" do
    test "both legs held on an instrument that names no symbol refuses, once per leg" do
      row = %{"instrument" => %{}, "longQuantity" => 100.0, "shortQuantity" => 40.0}
      body = accounts_with([row])

      assert Rest.get_positions(@creds, opts(responding(body))) ==
               {:error, {:missing_required_field, :symbol}}
    end

    test "an option and a collective investment keep their own instrument types" do
      body =
        accounts_with([
          %{
            "instrument" => %{"symbol" => "AAPL  260320C00200000", "assetType" => "OPTION"},
            "longQuantity" => 1.0,
            "shortQuantity" => 0.0
          },
          %{
            "instrument" => %{"symbol" => "SWPPX", "assetType" => "COLLECTIVE_INVESTMENT"},
            "longQuantity" => 10.0,
            "shortQuantity" => 0.0
          }
        ])

      assert {:ok, positions} = Rest.get_positions(@creds, opts(responding(body)))
      assert Enum.map(positions, & &1.instrument_type) == [:option, :fund]
    end
  end

  describe "get_balances/3 — an account with no balances object" do
    test "a cash account that states no currentBalances has no readable total" do
      body = %{"securitiesAccount" => %{"type" => "CASH"}}

      assert Rest.get_balances(@creds, "ABCDEF", opts(responding(body))) ==
               {:error, :unexpected_response_shape}
    end
  end

  describe "a body that parses but is neither an object nor a list" do
    test "get_user_preference/2 refuses it by name" do
      assert Rest.get_user_preference(@creds, opts(responding(5))) ==
               {:error, :unexpected_response_shape}
    end
  end

  describe "a 4xx that is not one of the four the venue documents" do
    test "a read answers an error carrying the status, not a refusal and not a success" do
      assert {:error, {:exchange_error, :schwab, text}} =
               Rest.get_user_preference(@creds, opts(responding(%{"message" => "x"}, 422)))

      assert text =~ "HTTP 422"
    end

    test "a preview answers an error carrying the status too" do
      payload = %{"orderStrategy" => %{}}

      assert {:error, {:exchange_error, :schwab, text}} =
               Rest.preview_order(
                 @creds,
                 "ABCDEF",
                 payload,
                 opts(responding(%{"message" => "x"}, 422))
               )

      assert text =~ "HTTP 422"
    end
  end

  describe "an order write that fails" do
    test "our own limiter giving up is a plain error: nothing was sent, nothing to reconcile" do
      Config.put_override(:rate_limit_module, TimedOutLimiter)
      exploding = fn _conn -> raise "a request was sent past a limiter that refused" end

      assert Rest.place_order(
               @creds,
               "ABCDEF",
               %{"orderType" => "MARKET"},
               plug: exploding,
               rate_limit_blocking: true
             ) == {:error, {:exchange_error, :schwab, :rate_limit_timeout}}
    end

    test "an answer too large to read is unconfirmed: the order may be live" do
      # Past `Core.HttpClient`'s default cap. The venue answered, so the order may exist, and
      # the response that would have named it was refused: a caller must reconcile, not retry.
      oversized = fn conn ->
        Plug.Conn.resp(conn, 201, :binary.copy("x", 16 * 1024 * 1024 + 1))
      end

      assert {:error, {:order_unconfirmed, nil, {:exchange_error, :schwab, reason}}} =
               Rest.place_order(@creds, "ABCDEF", %{"orderType" => "MARKET"}, plug: oversized)

      assert reason =~ "response_too_large"
    end
  end
end
