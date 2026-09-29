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

    assert {:ok, {:ok, %Order{legs: legs}}} =
             Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill)

    refute Enum.any?(List.wrap(legs), &is_integer(&1.ratio))
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
