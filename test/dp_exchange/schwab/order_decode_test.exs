defmodule DpExchange.Schwab.OrderDecodeTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.{Order, OrderLeg}
  alias DpExchange.Schwab.Orders

  # `get_order/3` and `get_orders/2` handed back the venue's raw JSON where `Core.Venue`
  # types them `Types.Order.t()`. These pin the decode that replaced that, against bodies in
  # the vendor's own OpenAPI `Order` shape.
  @limit_buy %{
    "orderId" => 123,
    "status" => "FILLED",
    "orderType" => "LIMIT",
    "duration" => "GOOD_TILL_CANCEL",
    "quantity" => 10,
    "filledQuantity" => 10,
    "price" => 190.25,
    "enteredTime" => "2026-01-02T15:04:05+0000",
    "orderLegCollection" => [
      %{"instruction" => "BUY", "quantity" => 10, "instrument" => %{"symbol" => "AAPL"}}
    ]
  }

  test "a single-leg order decodes to an Order carrying its leg's symbol and side" do
    assert {:ok, %Order{} = order} = Orders.from_venue(@limit_buy)

    assert order.id == "123"
    assert order.symbol == "AAPL"
    assert order.side == :buy
    assert order.order_type == :limit
    assert order.time_in_force == :gtc
    assert Decimal.equal?(order.quantity, 10)
    assert Decimal.equal?(order.price, Decimal.new("190.25"))
    assert order.status == :filled
    assert order.provider == :schwab
    assert order.legs == []
  end

  test "enteredTime's colon-less offset still parses" do
    # Schwab writes `+0000`. `DateTime.from_iso8601/1` reads it (Elixir 1.18 accepts the basic
    # offset), so no second parser is kept.
    assert {:ok, %Order{created_at: %DateTime{} = at}} = Orders.from_venue(@limit_buy)
    assert at == ~U[2026-01-02 15:04:05Z]
  end

  test "an enteredTime that is not a time is no time, never a guess" do
    for unreadable <- ["yesterday", "2026-01-02T15:04:05+9999", "2026-13-45T00:00:00+0000", 12] do
      assert {:ok, %Order{created_at: nil}} =
               Orders.from_venue(%{@limit_buy | "enteredTime" => unreadable})
    end
  end

  test "the terminal and in-flight statuses each read back as their own atom" do
    for {wire, atom} <- [
          {"REJECTED", :rejected},
          {"EXPIRED", :expired},
          {"PENDING_CANCEL", :open},
          {"PENDING_REPLACE", :open},
          {"PENDING_RECALL", :open},
          {"QUEUED", :pending}
        ] do
      assert {:ok, %Order{status: ^atom}} = Orders.from_venue(%{@limit_buy | "status" => wire})
    end
  end

  test "a leg that names no readable instrument has no symbol" do
    for leg <- [
          %{"instruction" => "BUY", "quantity" => 1},
          %{"instruction" => "BUY", "quantity" => 1, "instrument" => %{"symbol" => 5}}
        ] do
      assert {:ok, %Order{symbol: nil, side: :buy}} =
               Orders.from_venue(%{@limit_buy | "orderLegCollection" => [leg]})
    end
  end

  test "a spread leg's closing effect and equity type read back, and unknown ones are nil" do
    leg = fn symbol, effect, type ->
      %{
        "instruction" => "SELL_TO_CLOSE",
        "quantity" => 1,
        "positionEffect" => effect,
        "orderLegType" => type,
        "instrument" => %{"symbol" => symbol}
      }
    end

    legs = [leg.("AAPL", "CLOSING", "EQUITY"), leg.("MSFT", "AUTOMATIC", "FUTURE")]
    spread = %{@limit_buy | "orderLegCollection" => legs}

    assert {:ok, %Order{legs: [first, second]}} = Orders.from_venue(spread)
    assert %OrderLeg{position_effect: :close, instrument_type: :equity} = first
    assert %OrderLeg{position_effect: nil, instrument_type: nil} = second
  end

  test "WORKING is :partially_filled only when the venue's filledQuantity says so" do
    working = %{@limit_buy | "status" => "WORKING", "filledQuantity" => 0}
    assert {:ok, %Order{status: :open}} = Orders.from_venue(working)

    partial = %{working | "filledQuantity" => 4}
    assert {:ok, %Order{status: :partially_filled}} = Orders.from_venue(partial)
  end

  test "a value Core has no word for is nil, never the nearest atom" do
    # CABINET is not :limit; REPLACED is not :cancelled; EXCHANGE is not a side.
    odd = %{
      @limit_buy
      | "orderType" => "CABINET",
        "status" => "REPLACED",
        "duration" => "END_OF_WEEK",
        "orderLegCollection" => [
          %{"instruction" => "EXCHANGE", "quantity" => 1, "instrument" => %{"symbol" => "AAPL"}}
        ]
    }

    assert {:ok, %Order{order_type: nil, status: nil, time_in_force: nil, side: nil}} =
             Orders.from_venue(odd)
  end

  test "every order type the package can send reads back as the atom it was sent from" do
    for {wire, atom} <- [
          {"TRAILING_STOP", :trailing_stop},
          {"TRAILING_STOP_LIMIT", :trailing_stop_limit},
          {"MARKET_ON_CLOSE", :market_on_close},
          {"LIMIT_ON_CLOSE", :limit_on_close},
          {"STOP_LIMIT", :stop_limit}
        ] do
      assert {:ok, %Order{order_type: ^atom}} =
               Orders.from_venue(%{@limit_buy | "orderType" => wire})
    end
  end

  test "a spread with an unreadable leg is refused, not read as a single-leg order" do
    # The unreadable leg was filtered out, and one leg left decides "single-leg": the order
    # came back as an outright BUY of the surviving leg's symbol.
    spread = %{
      @limit_buy
      | "orderLegCollection" => [
          %{"instruction" => "BUY", "quantity" => 1, "instrument" => %{"symbol" => "AAPL"}},
          "unreadable"
        ]
    }

    assert {:error, :unexpected_response_shape} = Orders.from_venue(spread)

    assert {:error, :unexpected_response_shape} =
             Orders.from_venue(%{@limit_buy | "orderLegCollection" => "x"})
  end

  test "an order with no leg collection still decodes, with no symbol or side" do
    assert {:ok, %Order{symbol: nil, side: nil, legs: []}} =
             Orders.from_venue(Map.delete(@limit_buy, "orderLegCollection"))
  end

  test "a spread reports its legs with ratios, and no single symbol or side" do
    spread = %{
      @limit_buy
      | "orderLegCollection" => [
          %{
            "instruction" => "BUY_TO_OPEN",
            "quantity" => 2,
            "positionEffect" => "OPENING",
            "orderLegType" => "OPTION",
            "instrument" => %{"symbol" => "AAPL  260116C00200000"}
          },
          %{
            "instruction" => "SELL_TO_OPEN",
            "quantity" => 4,
            "positionEffect" => "OPENING",
            "orderLegType" => "OPTION",
            "instrument" => %{"symbol" => "AAPL  260116C00210000"}
          }
        ]
    }

    assert {:ok, %Order{symbol: nil, side: nil, legs: [first, second]}} =
             Orders.from_venue(spread)

    assert %OrderLeg{side: :buy, ratio: 1, position_effect: :open, instrument_type: :option} =
             first

    assert %OrderLeg{side: :sell, ratio: 2} = second
  end

  test "a leg quantity with a huge exponent answers at once, with no ratio from it" do
    # `Decimal.integer?/1` accepts `"1E999999999"`, and `Decimal.to_integer/1` then built a
    # billion-digit integer in the caller's process.
    [first, second] = @limit_buy["orderLegCollection"] ++ @limit_buy["orderLegCollection"]

    spread = %{
      @limit_buy
      | "orderLegCollection" => [first, Map.put(second, "quantity", "1E999999999")]
    }

    task = Task.async(fn -> Orders.from_venue(spread) end)

    # `legs: nil` is "the legs are not known": one unreadable quantity gives no ratio to ANY
    # leg (the ratios are quantities over their gcd), and the top stays without a symbol or
    # side because it is still a spread. An assertion over the legs themselves would pass
    # vacuously on the empty list.
    assert {:ok, {:ok, %Order{legs: nil, symbol: nil, side: nil}}} =
             Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
  end

  test "an order with no id is refused, and so is a list containing one" do
    assert {:error, {:missing_required_field, :id}} =
             Orders.from_venue(Map.delete(@limit_buy, "orderId"))

    assert {:error, {:missing_required_field, :id}} =
             Orders.list_from_venue([@limit_buy, Map.delete(@limit_buy, "orderId")])
  end

  test "a body that is not an order, or not a list of them, is refused" do
    assert {:error, :unexpected_response_shape} = Orders.from_venue([])
    assert {:error, :unexpected_response_shape} = Orders.list_from_venue(%{"orders" => []})
    assert {:ok, []} = Orders.list_from_venue([])
  end
end
