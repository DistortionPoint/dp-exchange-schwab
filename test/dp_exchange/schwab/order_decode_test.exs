defmodule DpExchange.Schwab.OrderDecodeTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.{Order, OrderLeg}
  alias DpExchange.Schwab.{Fake, Orders}

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
    # Nothing filled: the in-flight cancel/replace/recall states are `:open`.
    unfilled = %{@limit_buy | "filledQuantity" => 0}

    for {wire, atom} <- [
          {"REJECTED", :rejected},
          {"EXPIRED", :expired},
          {"PENDING_CANCEL", :open},
          {"PENDING_REPLACE", :open},
          {"PENDING_RECALL", :open},
          {"QUEUED", :pending}
        ] do
      assert {:ok, %Order{status: ^atom}} = Orders.from_venue(%{unfilled | "status" => wire})
    end
  end

  # The vendor's own `apiOrderStatus` enum, read from the committed OpenAPI document
  # (`docs/reference/schwab/openapi/accounts-and-trading-production.openapi.json`), and the Core
  # status each one means. Nothing is defaulted: `REPLACED` and `UNKNOWN` have no Core word.
  @every_status [
    {"AWAITING_PARENT_ORDER", :pending},
    {"AWAITING_CONDITION", :pending},
    {"AWAITING_STOP_CONDITION", :pending},
    {"AWAITING_MANUAL_REVIEW", :pending},
    {"ACCEPTED", :pending},
    {"AWAITING_UR_OUT", :pending},
    {"PENDING_ACTIVATION", :pending},
    {"QUEUED", :pending},
    {"WORKING", :open},
    {"REJECTED", :rejected},
    {"PENDING_CANCEL", :open},
    {"CANCELED", :cancelled},
    {"PENDING_REPLACE", :open},
    {"REPLACED", nil},
    {"FILLED", :filled},
    {"EXPIRED", :expired},
    {"NEW", :pending},
    {"AWAITING_RELEASE_TIME", :pending},
    {"PENDING_ACKNOWLEDGEMENT", :pending},
    {"PENDING_RECALL", :open},
    {"UNKNOWN", nil}
  ]

  test "every value of the vendor's apiOrderStatus enum is handled, and none is defaulted" do
    enum = DpExchange.Schwab.Rest.order_statuses()

    # The table covers the enum exactly: a status added to the enum without a decision here, or
    # dropped from it, fails this line rather than reading back as something plausible.
    assert Enum.sort(Enum.map(@every_status, &elem(&1, 0))) == Enum.sort(enum)
    assert length(enum) == 21

    for {wire, atom} <- @every_status do
      # FILLED is consistent only with the whole size filled; every other state with none.
      filled = if wire == "FILLED", do: 10, else: 0
      order = %{@limit_buy | "status" => wire, "filledQuantity" => filled}

      assert {:ok, %Order{status: status}} = Orders.from_venue(order)
      assert status == atom, "#{wire} must read back as #{inspect(atom)}, got #{inspect(status)}"
    end
  end

  describe "a status that contradicts the sizes beside it is refused" do
    @refused {:error, :unexpected_response_shape}

    defp sized(status, quantity, filled) do
      %{@limit_buy | "status" => status, "quantity" => quantity, "filledQuantity" => filled}
    end

    test "FILLED with nothing filled" do
      assert Orders.from_venue(sized("FILLED", 10, 0)) == @refused

      # A live state with nothing filled is simply :open.
      for wire <- ["WORKING", "PENDING_CANCEL"] do
        assert {:ok, %Order{status: :open}} = Orders.from_venue(sized(wire, 10, 0))
      end
    end

    test "a live or pending state with the whole size filled" do
      for wire <- ["WORKING", "PENDING_CANCEL", "PENDING_REPLACE", "PENDING_RECALL"] do
        assert Orders.from_venue(sized(wire, 10, 10)) == @refused
      end
    end

    test "FILLED with only part filled" do
      assert Orders.from_venue(sized("FILLED", 10, 4)) == @refused
      assert Orders.from_venue(sized("FILLED", 10, "4.5")) == @refused
    end

    test "a consistent order, and a state that implies nothing about fills, is read" do
      assert {:ok, %Order{status: :filled}} = Orders.from_venue(sized("FILLED", 10, 10))

      assert {:ok, %Order{status: :partially_filled}} =
               Orders.from_venue(sized("WORKING", 10, 4))

      assert {:ok, %Order{status: :cancelled}} = Orders.from_venue(sized("CANCELED", 10, 10))
      assert {:ok, %Order{status: :cancelled}} = Orders.from_venue(sized("CANCELED", 10, 0))
      assert {:ok, %Order{status: :expired}} = Orders.from_venue(sized("EXPIRED", 10, 4))
      assert {:ok, %Order{status: nil}} = Orders.from_venue(sized("REPLACED", 10, 10))
    end

    test "an absent size contradicts nothing, and a list with one contradiction is refused" do
      no_filled = Map.delete(sized("FILLED", 10, 10), "filledQuantity")
      assert {:ok, %Order{status: :filled, filled_quantity: nil}} = Orders.from_venue(no_filled)

      no_quantity = Map.delete(sized("FILLED", 10, 10), "quantity")
      assert {:ok, %Order{status: :filled}} = Orders.from_venue(no_quantity)

      bad = [sized("FILLED", 10, 10), sized("FILLED", 10, 0)]
      assert Orders.list_from_venue(bad) == @refused
    end

    test "every order the Fake produces is consistent with Core's own constructor" do
      creds = %{access_token: "t"}
      opts = [account_hash: "H"]
      request = %{symbol: "AAPL", side: :buy, quantity: 3, order_type: :market}
      request = Map.put(request, :time_in_force, :day)

      assert {:ok, placed} = Fake.place_order(creds, request, opts)
      assert {:ok, replaced} = Fake.replace_order(creds, placed.id, request, opts)
      assert {:ok, :cancelled} = Fake.cancel_order(creds, replaced.id, opts)

      now = DateTime.utc_now()
      window = [from: DateTime.add(now, -3600), to: DateTime.add(now, 3600)]
      assert {:ok, orders} = Fake.get_orders(creds, opts ++ window)
      assert length(orders) == 2

      for order <- orders do
        assert %Order{} = Order.new(Map.from_struct(order))
      end

      assert {:ok, [canned]} =
               Fake.get_orders(
                 creds,
                 opts ++ [from: ~U[2026-01-01 00:00:00Z], to: ~U[2026-01-03 00:00:00Z]]
               )

      assert %Order{status: :filled} = Order.new(Map.from_struct(canned))
    end
  end

  test "a status the enum does not list, or none at all, is nil - never :open or :pending" do
    for wire <- ["working", "SUSPENDED", "", 7, nil] do
      assert {:ok, %Order{status: nil}} = Orders.from_venue(%{@limit_buy | "status" => wire})
    end

    assert {:ok, %Order{status: nil}} = Orders.from_venue(Map.delete(@limit_buy, "status"))
  end

  test "a live order with fills is :partially_filled whichever live status it carries" do
    for wire <- ["WORKING", "PENDING_CANCEL", "PENDING_REPLACE", "PENDING_RECALL"] do
      partial = %{@limit_buy | "status" => wire, "filledQuantity" => 4}

      assert {:ok, %Order{status: :partially_filled, filled_quantity: filled}} =
               Orders.from_venue(partial)

      assert Decimal.equal?(filled, 4)

      untouched = %{partial | "filledQuantity" => 0}
      assert {:ok, %Order{status: :open}} = Orders.from_venue(untouched)
    end
  end

  test "a cancelled or expired order keeps the fills it had, and is not reported as unfilled" do
    for {wire, atom} <- [{"CANCELED", :cancelled}, {"EXPIRED", :expired}] do
      order = %{@limit_buy | "status" => wire, "filledQuantity" => 3}

      assert {:ok, %Order{status: ^atom, filled_quantity: filled}} = Orders.from_venue(order)
      assert Decimal.equal?(filled, 3)
    end
  end

  test "a negative size or filled size refuses the order, it is not carried" do
    assert {:error, :unexpected_response_shape} =
             Orders.from_venue(%{@limit_buy | "quantity" => -1})

    assert {:error, :unexpected_response_shape} =
             Orders.from_venue(%{@limit_buy | "filledQuantity" => -4})

    assert {:error, :unexpected_response_shape} =
             Orders.list_from_venue([@limit_buy, %{@limit_buy | "filledQuantity" => -4}])
  end

  describe "average_price, from the executions the venue reports" do
    defp execution(legs) do
      %{"activityType" => "EXECUTION", "executionType" => "FILL", "executionLegs" => legs}
    end

    defp fill(price, quantity), do: %{"legId" => 1, "price" => price, "quantity" => quantity}

    test "is the quantity-weighted mean of the execution legs' prices" do
      order =
        Map.put(@limit_buy, "orderActivityCollection", [
          execution([fill(Decimal.new("10.00"), 1), fill(Decimal.new("20.00"), 3)]),
          execution([fill(Decimal.new("30.00"), 6)])
        ])

      # (10*1 + 20*3 + 30*6) / 10 = 25
      assert {:ok, %Order{average_price: average}} = Orders.from_venue(order)
      assert Decimal.equal?(average, Decimal.new("25"))
    end

    test "reads a JSON number off the wire as the exact digits it carried" do
      body =
        ~s({"orderId": 9, "status": "FILLED", "filledQuantity": 3, "quantity": 3,
            "orderLegCollection": [{"instruction": "BUY", "quantity": 3,
              "instrument": {"symbol": "AAPL"}}],
            "orderActivityCollection": [{"activityType": "EXECUTION", "executionType": "FILL",
              "quantity": 3, "executionLegs": [
                {"legId": 1, "price": 190.1, "quantity": 1},
                {"legId": 1, "price": 190.4, "quantity": 2}]}]})

      assert {:ok, order} = Jason.decode(body, floats: :decimals)
      assert {:ok, %Order{average_price: average}} = Orders.from_venue(order)
      # (190.1 + 2 * 190.4) / 3 = 190.3 exactly in decimal digits
      assert Decimal.equal?(average, Decimal.new("190.3"))
    end

    test "is nil when nothing was executed" do
      for activities <- [nil, [], [%{"activityType" => "ORDER_ACTION"}], [execution([])]] do
        order = Map.put(@limit_buy, "orderActivityCollection", activities)
        assert {:ok, %Order{average_price: nil}} = Orders.from_venue(order)
      end

      assert {:ok, %Order{average_price: nil}} = Orders.from_venue(@limit_buy)
    end

    test "is nil, never a partial average, when any one fill is unreadable or not positive" do
      good = fill(Decimal.new("10"), 1)

      for bad <- [
            %{"legId" => 1, "quantity" => 1},
            %{"legId" => 1, "price" => Decimal.new("10")},
            fill("abc", 1),
            fill(Decimal.new("0"), 1),
            fill(Decimal.new("10"), 0),
            fill(Decimal.new("-10"), 1),
            fill(Decimal.new("10"), -1),
            "x"
          ] do
        order = Map.put(@limit_buy, "orderActivityCollection", [execution([good, bad])])
        assert {:ok, %Order{average_price: nil}} = Orders.from_venue(order)
      end
    end

    test "is nil for a spread, whose legs are different instruments with no common price" do
      leg = fn symbol ->
        %{"instruction" => "BUY", "quantity" => 1, "instrument" => %{"symbol" => symbol}}
      end

      spread =
        @limit_buy
        |> Map.put("orderLegCollection", [leg.("AAPL"), leg.("MSFT")])
        |> Map.put("orderActivityCollection", [execution([fill(Decimal.new("10"), 1)])])

      assert {:ok, %Order{average_price: nil, symbol: nil}} = Orders.from_venue(spread)
    end

    test "an activity that is not an execution contributes nothing" do
      order =
        Map.put(@limit_buy, "orderActivityCollection", [
          %{"activityType" => "ORDER_ACTION", "executionLegs" => [fill(Decimal.new("99"), 1)]},
          execution([fill(Decimal.new("10"), 2)])
        ])

      assert {:ok, %Order{average_price: average}} = Orders.from_venue(order)
      assert Decimal.equal?(average, Decimal.new("10"))
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

  test "every value of the vendor's instruction enum reads back as a side, or nil" do
    # `instruction`, from the committed OpenAPI document: ten values. EXCHANGE is neither a buy
    # nor a sell, so it is nil, never a guess.
    table = [
      {"BUY", :buy},
      {"SELL", :sell},
      {"BUY_TO_COVER", :buy},
      {"SELL_SHORT", :sell},
      {"BUY_TO_OPEN", :buy},
      {"BUY_TO_CLOSE", :buy},
      {"SELL_TO_OPEN", :sell},
      {"SELL_TO_CLOSE", :sell},
      {"EXCHANGE", nil},
      {"SELL_SHORT_EXEMPT", :sell}
    ]

    for {wire, side} <- table do
      leg = %{"instruction" => wire, "quantity" => 10, "instrument" => %{"symbol" => "AAPL"}}
      order = %{@limit_buy | "orderLegCollection" => [leg]}

      assert {:ok, %Order{side: actual}} = Orders.from_venue(order)
      assert actual == side, "#{wire} must read back as #{inspect(side)}"
    end

    # An instruction the enum does not list is no side either.
    odd = %{"instruction" => "buy", "quantity" => 1, "instrument" => %{"symbol" => "AAPL"}}

    assert {:ok, %Order{side: nil}} =
             Orders.from_venue(%{@limit_buy | "orderLegCollection" => [odd]})
  end

  test "every order type and duration of the vendor's enums reads back, or is nil" do
    types = [
      {"MARKET", :market},
      {"LIMIT", :limit},
      {"STOP", :stop},
      {"STOP_LIMIT", :stop_limit},
      {"TRAILING_STOP", :trailing_stop},
      {"CABINET", nil},
      {"NON_MARKETABLE", nil},
      {"MARKET_ON_CLOSE", :market_on_close},
      {"EXERCISE", nil},
      {"TRAILING_STOP_LIMIT", :trailing_stop_limit},
      {"NET_DEBIT", nil},
      {"NET_CREDIT", nil},
      {"NET_ZERO", nil},
      {"LIMIT_ON_CLOSE", :limit_on_close},
      {"UNKNOWN", nil}
    ]

    for {wire, atom} <- types do
      assert {:ok, %Order{order_type: actual}} =
               Orders.from_venue(%{@limit_buy | "orderType" => wire})

      assert actual == atom, "#{wire} must read back as #{inspect(atom)}"
    end

    durations = [
      {"DAY", :day},
      {"GOOD_TILL_CANCEL", :gtc},
      {"FILL_OR_KILL", :fok},
      {"IMMEDIATE_OR_CANCEL", :ioc},
      {"END_OF_WEEK", nil},
      {"END_OF_MONTH", nil},
      {"NEXT_END_OF_MONTH", nil},
      {"UNKNOWN", nil}
    ]

    for {wire, atom} <- durations do
      assert {:ok, %Order{time_in_force: actual}} =
               Orders.from_venue(%{@limit_buy | "duration" => wire})

      assert actual == atom, "#{wire} must read back as #{inspect(atom)}"
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
