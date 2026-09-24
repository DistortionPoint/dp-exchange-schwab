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
    # Schwab writes `+0000`, which `DateTime.from_iso8601/1` alone refuses.
    assert {:ok, %Order{created_at: %DateTime{} = at}} = Orders.from_venue(@limit_buy)
    assert at == ~U[2026-01-02 15:04:05Z]
  end

  test "WORKING is :partially_filled only when the venue's filledQuantity says so" do
    working = %{@limit_buy | "status" => "WORKING", "filledQuantity" => 0}
    assert {:ok, %Order{status: :open}} = Orders.from_venue(working)

    partial = %{working | "filledQuantity" => 4}
    assert {:ok, %Order{status: :partially_filled}} = Orders.from_venue(partial)
  end

  test "a value Core has no word for is nil, never the nearest atom" do
    # TRAILING_STOP is not :stop; REPLACED is not :cancelled; EXCHANGE is not a side.
    odd = %{
      @limit_buy
      | "orderType" => "TRAILING_STOP",
        "status" => "REPLACED",
        "duration" => "END_OF_WEEK",
        "orderLegCollection" => [
          %{"instruction" => "EXCHANGE", "quantity" => 1, "instrument" => %{"symbol" => "AAPL"}}
        ]
    }

    assert {:ok, %Order{order_type: nil, status: nil, time_in_force: nil, side: nil}} =
             Orders.from_venue(odd)
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
