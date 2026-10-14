defmodule DpExchange.Schwab.DecoderRobustnessTest do
  @moduledoc """
  Tick AC: what the decoders do with hostile or malformed venue payloads. Every test here
  fails on the code it was written against, and each one names the input that broke it.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.{Balance, Candle, OptionChain, Quote}
  alias DpExchange.Schwab.{Fake, Orders, Rest, StreamerDecode, StreamerProtocol}

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

  defp responding(body, status) do
    fn conn -> Req.Test.json(%{conn | status: status}, body) end
  end

  defp opts(body, status \\ 200), do: [plug: responding(body, status), retry_attempts: 0]

  describe "StreamerProtocol.succeeded?/1 reads only the integer codes the vendor lists" do
    test "a code of 0.0 or -0.0 is not success, though it compares equal to 0" do
      # `code == 0` is numeric equality: `0.0 == 0` is true, so a response carrying a float
      # code read as success. `in` is exact.
      refute StreamerProtocol.succeeded?(%{"content" => %{"code" => 0.0}})
      refute StreamerProtocol.succeeded?(%{"content" => %{"code" => -0.0}})
      refute StreamerProtocol.succeeded?(%{"content" => %{"code" => 26.0}})
      refute StreamerProtocol.succeeded?(%{"content" => %{"code" => "0"}})
      refute StreamerProtocol.succeeded?(%{"content" => %{"code" => false}})
    end

    test "the integer codes are still success" do
      for code <- [0, 26, 27, 28, 29] do
        assert StreamerProtocol.succeeded?(%{"content" => %{"code" => code}})
      end
    end
  end

  describe "a negative volume is not a volume" do
    test "a streamed quote keeps its price and reads a negative total as not stated" do
      fields = %{last: "10.5", total_volume: "-5"}

      assert {:ok, %Quote{} = quoted} = StreamerDecode.to_quote(fields, "AAPL", @observed)
      assert Decimal.equal?(quoted.price, Decimal.new("10.5"))
      assert quoted.volume == nil
      assert quoted.volume_window == nil
    end

    test "a streamed candle keeps its prices and reads a negative volume as not stated" do
      fields = %{
        chart_time: 1_700_000_000_000,
        open: "1",
        high: "2",
        low: "1",
        close: "2",
        volume: -1
      }

      assert {:ok, %Candle{volume: nil}} = StreamerDecode.to_candle(fields, "AAPL", "1m")

      zero = %{fields | volume: 0}
      assert {:ok, %Candle{} = bar} = StreamerDecode.to_candle(zero, "AAPL", "1m")
      assert Decimal.equal?(bar.volume, 0)
    end

    test "a REST quote with a negative totalVolume has no volume, and its price stands" do
      body = %{"AAPL" => %{"quote" => %{"lastPrice" => 10.5, "totalVolume" => -3}}}

      assert {:ok, %Quote{volume: nil, volume_window: nil} = quoted} =
               Rest.get_price("AAPL", @creds, opts(body))

      assert Decimal.equal?(quoted.price, Decimal.new("10.5"))
    end

    test "a REST candle with a negative volume has none, and its prices stand" do
      row = %{
        "datetime" => 1_451_624_400_000,
        "open" => 1,
        "high" => 2,
        "low" => 1,
        "close" => 2,
        "volume" => -7
      }

      body = %{"symbol" => "AAPL", "empty" => false, "candles" => [row]}

      assert {:ok, [%Candle{volume: nil} = bar]} =
               Rest.get_historical_prices("AAPL", "1d", [], @creds, opts(body))

      assert Decimal.equal?(bar.close, 2)
    end
  end

  describe "an order id read from Location is the venue's integer, or nothing" do
    @base "https://api.schwabapi.com/trader/v1/accounts/X/orders/"

    @bad_tails [
      "portal",
      "1005?next=/login",
      "1005abc",
      "..",
      "1005#frag",
      "12345678901234567890"
    ]

    defp placed_at(location) do
      plug = fn conn ->
        conn |> Plug.Conn.put_resp_header("location", location) |> Plug.Conn.resp(201, "")
      end

      payload = %{"orderType" => "MARKET"}
      Rest.place_order(@creds, "ABCDEF", payload, plug: plug, retry_attempts: 0)
    end

    test "a last segment that is not digits names no order and is unconfirmed, not returned" do
      for tail <- @bad_tails do
        result = placed_at(@base <> tail)

        assert {:error, {:order_unconfirmed, nil, :order_id_not_returned}} = result
      end
    end

    test "a numeric id is still the id" do
      assert {:ok, "1005"} = placed_at(@base <> "1005")
      assert {:ok, "1234567890123456789"} = placed_at(@base <> "1234567890123456789")
    end
  end

  describe "an error body with a null detail carries no detail" do
    test "errors[0].detail of null is {:venue_error, status}, not a three-tuple holding nil" do
      body = %{"errors" => [%{"detail" => nil, "title" => "Bad"}]}

      assert {:refused, {:venue_error, 400}} = Rest.get_price("AAPL", @creds, opts(body, 400))
    end

    test "a text detail is still carried, bounded" do
      body = %{"errors" => [%{"detail" => "no such symbol"}]}

      assert {:refused, {:venue_error, 400, "no such symbol"}} =
               Rest.get_price("AAPL", @creds, opts(body, 400))
    end
  end

  describe "get_option_chain/3 refuses what it cannot address and does not carry non-text" do
    defp chain(side_map, extra \\ %{}) do
      Map.merge(%{"symbol" => "AAPL", "callExpDateMap" => side_map}, extra)
    end

    defp one_strike(strike, contract) do
      %{"2026-03-20:15" => %{strike => [contract]}}
    end

    test "a chain whose own symbol is not text is unreadable, not an underlying of 5" do
      contract = %{"symbol" => "AAPL  260320C00200000"}
      body = chain(one_strike("200.0", contract), %{"symbol" => 5})

      assert {:error, :unexpected_response_shape} =
               Rest.get_option_chain("AAPL", @creds, opts(body))

      nested = chain(one_strike("200.0", contract), %{"symbol" => %{"a" => 1}})

      assert {:error, :unexpected_response_shape} =
               Rest.get_option_chain("AAPL", @creds, opts(nested))
    end

    test "a strike key of zero or below addresses no contract" do
      for strike <- ["0", "0.0", "-5.0"] do
        body = chain(one_strike(strike, %{"symbol" => "X"}))
        result = Rest.get_option_chain("AAPL", @creds, opts(body))

        assert {:error, {:unreadable_chain_strike, ^strike}} = result
      end
    end

    test "descriptive fields that are not text are not stated, and a zero multiplier is none" do
      contract = %{
        "symbol" => 123,
        "settlementType" => %{"x" => 1},
        "expirationType" => ["M"],
        "multiplier" => 0
      }

      body = chain(one_strike("200.0", contract))

      assert {:ok, %OptionChain{expiries: grid}} =
               Rest.get_option_chain("AAPL", @creds, opts(body))

      call = grid[~D[2026-03-20]][Decimal.new("200.0")].call
      assert call.venue_symbol == nil
      assert call.settlement_type == nil
      assert call.expiration_type == nil
      assert call.multiplier == nil
    end

    test "a negative underlyingPrice is not stated" do
      body = chain(one_strike("200.0", %{"symbol" => "X"}), %{"underlyingPrice" => -1.5})

      assert {:ok, %OptionChain{underlying_price: nil}} =
               Rest.get_option_chain("AAPL", @creds, opts(body))
    end

    test "a readable chain still decodes" do
      contract = %{"symbol" => "AAPL  260320C00200000", "multiplier" => 100}
      body = chain(one_strike("200.0", contract), %{"underlyingPrice" => 201.5})

      assert {:ok, %OptionChain{underlying: "AAPL", expiries: grid} = built} =
               Rest.get_option_chain("AAPL", @creds, opts(body))

      assert Decimal.equal?(built.underlying_price, Decimal.from_float(201.5))
      call = grid[~D[2026-03-20]][Decimal.new("200.0")].call
      assert call.venue_symbol == "AAPL  260320C00200000"
      assert Decimal.equal?(call.multiplier, 100)
    end
  end

  describe "get_balances/3 holds the available figure to the standard of the total" do
    test "a margin availableFunds that is present and unreadable refuses the reply" do
      for bad <- ["abc", "", "NaN", "Infinity", "1E5000"] do
        body = %{
          "securitiesAccount" => %{
            "type" => "MARGIN",
            "currentBalances" => %{"marginBalance" => 100.0, "availableFunds" => bad}
          }
        }

        result = Rest.get_balances(@creds, "ABCDEF", opts(body))

        assert {:error, :unexpected_response_shape} = result
      end
    end

    test "a cash cashAvailableForTrading that is present and unreadable refuses the reply" do
      body = %{
        "securitiesAccount" => %{
          "type" => "CASH",
          "currentBalances" => %{"totalCash" => 10.0, "cashAvailableForTrading" => %{"x" => 1}}
        }
      }

      assert {:error, :unexpected_response_shape} =
               Rest.get_balances(@creds, "ABCDEF", opts(body))
    end

    test "an absent or null available figure is still not stated" do
      absent = %{
        "securitiesAccount" => %{
          "type" => "MARGIN",
          "currentBalances" => %{"marginBalance" => 100.0}
        }
      }

      null = put_in(absent, ["securitiesAccount", "currentBalances", "availableFunds"], nil)

      for body <- [absent, null] do
        assert {:ok, [%Balance{available_balance: nil} = balance]} =
                 Rest.get_balances(@creds, "ABCDEF", opts(body))

        assert Decimal.equal?(balance.balance, 100)
      end
    end
  end

  describe "Orders.build/2 takes a plain request map" do
    test "a struct is refused by name, here and in the fake, and does not raise" do
      # `is_map/1` is true for a struct, and `check_keys/1` enumerates the request: structs
      # have no `Enumerable`, so this raised `Protocol.UndefinedError` in the caller's process.
      request = %URI{host: "example.com"}

      assert {:error, {:invalid_order_request, ^request}} = Orders.build(request, [])

      assert {:error, {:invalid_order_request, ^request}} =
               Fake.place_order(@creds, request, account_hash: "H")
    end
  end

  describe "a list read answers a list of objects, or refuses" do
    @window [
      from: ~U[2026-08-01 00:00:00Z],
      to: ~U[2026-09-01 00:00:00Z],
      now: ~U[2026-08-15 00:00:00Z]
    ]

    test "an account list holding a non-object row is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_account_summaries(@creds, opts([%{"a" => 1}, 7, nil]))
    end

    test "an all-accounts orders list holding a non-object row is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_all_orders(@creds, @window ++ opts([%{"orderId" => 1}, "x"]))
    end

    test "a per-account orders list holding a non-object row is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_orders(@creds, "hash-1", @window ++ opts([[1]]))
    end

    test "a transactions list holding a non-object row is unreadable" do
      args = @window ++ [types: "TRADE"] ++ opts([%{"activityId" => 1}, 2])

      assert {:error, :unexpected_response_shape} = Rest.get_transactions(@creds, "hash-1", args)
    end

    test "lists of objects, and the empty list, still answer" do
      assert {:ok, [%{"a" => 1}]} = Rest.get_account_summaries(@creds, opts([%{"a" => 1}]))
      assert {:ok, []} = Rest.get_account_summaries(@creds, opts([]))
    end
  end
end
