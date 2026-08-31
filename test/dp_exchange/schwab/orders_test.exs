defmodule DpExchange.Schwab.OrdersTest do
  @moduledoc """
  Order construction, and the refusals that keep a throttled write from being spent on a
  knowable rejection.

  Order writes on this venue are limited to somewhere between 0 and 120 a minute per
  account, while reads are free. That asymmetry is why every check here happens locally:
  a rejection the documentation already predicted should not cost one of them.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Schwab.Orders

  @buy %{symbol: "AAPL", side: :buy, quantity: 15}

  describe "the documented market order, reproduced" do
    test "matches the venue's own worked example" do
      # From the Documentation tab: "Buy 15 shares of XYZ at the Market good for the Day."
      assert {:ok, payload} = Orders.build(@buy)

      assert payload["orderType"] == "MARKET"
      assert payload["session"] == "NORMAL"
      assert payload["duration"] == "DAY"
      assert payload["orderStrategyType"] == "SINGLE"

      assert [leg] = payload["orderLegCollection"]
      assert leg["instruction"] == "BUY"
      assert leg["quantity"] == 15
      assert leg["instrument"] == %{"symbol" => "AAPL", "assetType" => "EQUITY"}
    end

    test "session and duration are always present, even on the simplest order" do
      # Every documented example carries both. `session` has no slot in Core at all, so
      # the default is stated rather than hidden.
      assert {:ok, payload} = Orders.build(@buy)

      assert Map.has_key?(payload, "session")
      assert Map.has_key?(payload, "duration")
    end

    test "session is overridable, per request and per package option" do
      assert {:ok, payload} = Orders.build(Map.put(@buy, :session, "SEAMLESS"))
      assert payload["session"] == "SEAMLESS"

      assert {:ok, payload} = Orders.build(@buy, session: "AM")
      assert payload["session"] == "AM"
    end
  end

  describe "prices" do
    test "a limit order carries its price as a string" do
      request =
        %{@buy | side: :buy} |> Map.merge(%{order_type: :limit, price: Decimal.new("34.97")})

      assert {:ok, payload} = Orders.build(request)
      assert payload["orderType"] == "LIMIT"
      assert payload["price"] == "34.97"
    end

    test "a stop_limit carries both" do
      request =
        Map.merge(@buy, %{
          order_type: :stop_limit,
          price: Decimal.new("37.00"),
          stop_price: Decimal.new("37.03")
        })

      assert {:ok, payload} = Orders.build(request)
      assert payload["price"] == "37.00"
      assert payload["stopPrice"] == "37.03"
    end

    test "a market order carries neither" do
      assert {:ok, payload} = Orders.build(@buy)

      refute Map.has_key?(payload, "price")
      refute Map.has_key?(payload, "stopPrice")
    end

    test "a limit with no price is refused locally, not by the venue" do
      assert Orders.build(Map.put(@buy, :order_type, :limit)) ==
               {:error, {:missing_order_field, :price}}
    end

    test "a stop with no stop price is refused, and stop_limit names the missing half" do
      assert Orders.build(Map.put(@buy, :order_type, :stop)) ==
               {:error, {:missing_order_field, :stop_price}}

      assert Orders.build(Map.put(@buy, :order_type, :stop_limit)) ==
               {:error, {:missing_order_field, :stop_price}}

      assert Orders.build(Map.merge(@buy, %{order_type: :stop_limit, stop_price: 1})) ==
               {:error, {:missing_order_field, :price}}
    end
  end

  describe "the published instruction matrix is enforced before sending" do
    test "equity instructions are accepted on an equity" do
      for instruction <- Orders.equity_instructions() do
        assert {:ok, payload} = Orders.build(Map.put(@buy, :instruction, instruction))
        assert [%{"instruction" => ^instruction}] = payload["orderLegCollection"]
      end
    end

    test "an option instruction on an equity is refused, as the venue's table says" do
      for instruction <- Orders.option_instructions() do
        assert {:error, {:instruction_not_valid_for_asset, ^instruction, "EQUITY"}} =
                 Orders.build(Map.put(@buy, :instruction, instruction))
      end
    end

    test "an equity instruction on an option is refused too" do
      option = %{symbol: "XYZ   240315C00500000", quantity: 10}

      for instruction <- Orders.equity_instructions() do
        assert {:error, {:instruction_not_valid_for_asset, ^instruction, "OPTION"}} =
                 Orders.build(Map.put(option, :instruction, instruction))
      end
    end

    test "the option example from the documentation builds" do
      # "Buy to open 10 contracts of the XYZ March 15, 2024 $50 CALL at a Limit of $6.45."
      request = %{
        symbol: "XYZ   240315C00500000",
        instruction: "BUY_TO_OPEN",
        quantity: 10,
        order_type: :limit,
        price: Decimal.new("6.45")
      }

      assert {:ok, payload} = Orders.build(request)
      assert [leg] = payload["orderLegCollection"]
      assert leg["instrument"]["assetType"] == "OPTION"
      assert leg["instrument"]["symbol"] == "XYZ   240315C00500000"
      assert payload["price"] == "6.45"
    end

    test "the two sets are disjoint, which is what makes the check meaningful" do
      assert Orders.equity_instructions() -- Orders.option_instructions() ==
               Orders.equity_instructions()
    end
  end

  describe "vocabulary outside the venue is named, not mapped to something near" do
    test "an order type Core admits but this venue has no atom for is refused" do
      # `:post_only` has no Schwab equivalent; NON_MARKETABLE is close and is not the
      # same thing. `:ioc` and `:fok` are durations here, not order types.
      for type <- [:post_only, :ioc, :fok, :trailing_stop] do
        assert {:error, {:unsupported_order_type, ^type}} =
                 Orders.build(Map.put(@buy, :order_type, type))
      end
    end

    test ":gtd is refused because three fixed horizons are not an arbitrary date" do
      assert Orders.build(Map.put(@buy, :time_in_force, :gtd)) ==
               {:error, {:unsupported_time_in_force, :gtd}}
    end

    test "the four durations the venue does serve all map" do
      for {tif, native} <- [
            day: "DAY",
            gtc: "GOOD_TILL_CANCEL",
            fok: "FILL_OR_KILL",
            ioc: "IMMEDIATE_OR_CANCEL"
          ] do
        assert {:ok, payload} = Orders.build(Map.put(@buy, :time_in_force, tif))
        assert payload["duration"] == native
      end
    end
  end

  describe "quantities" do
    test "a fractional quantity is passed through, never rounded" do
      # `quantityType` admits DOLLARS and `quantity` is a double. Rounding to whole
      # shares would change the size of the order silently.
      assert {:ok, payload} = Orders.build(%{@buy | quantity: Decimal.new("0.5")})
      assert [%{"quantity" => 0.5}] = payload["orderLegCollection"]
    end

    test "zero, negative and non-numeric quantities are refused" do
      for bad <- [0, -1, "15", nil] do
        assert {:error, _reason} = Orders.build(%{@buy | quantity: bad})
      end
    end
  end

  describe "missing pieces are named" do
    test "no symbol, no side" do
      assert Orders.build(%{side: :buy, quantity: 1}) ==
               {:error, {:missing_order_field, :symbol}}

      assert Orders.build(%{symbol: "AAPL", quantity: 1}) ==
               {:error, {:missing_order_field, :side}}
    end

    test "a pair-shaped symbol is refused here too" do
      assert {:error, {:not_an_equity_symbol, "BTC-USD"}} =
               Orders.build(%{@buy | symbol: "BTC-USD"})
    end
  end
end
