defmodule DpExchange.Schwab.OrdersRefusalsTest do
  @moduledoc """
  Fields an order type never reads are refused rather than sent, and an invalid
  instruction names the value the caller gave.

  A market order carrying a `:price` is ambiguous: the caller may believe they placed a
  limit. Sent as MARKET it fills at any price, and the venue does not object.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Schwab.Orders

  @buy %{symbol: "AAPL", side: :buy, quantity: 15}

  describe "a field the order type never reads is refused" do
    test "an explicit market order carrying a price is refused, not sent as a market order" do
      request = Map.merge(@buy, %{order_type: :market, price: Decimal.new("150")})

      assert Orders.build(request) == {:error, {:price_not_allowed, :market}}
    end

    test "a market order carrying a stop price is refused" do
      request = Map.merge(@buy, %{order_type: :market, stop_price: 10})

      assert Orders.build(request) == {:error, {:stop_price_not_allowed, :market}}
    end

    test "market_on_close takes neither price" do
      assert Orders.build(Map.merge(@buy, %{order_type: :market_on_close, price: 1})) ==
               {:error, {:price_not_allowed, :market_on_close}}

      assert Orders.build(Map.merge(@buy, %{order_type: :market_on_close, stop_price: 1})) ==
               {:error, {:stop_price_not_allowed, :market_on_close}}
    end

    test "a stop price on a limit or limit_on_close is refused" do
      for type <- [:limit, :limit_on_close] do
        request = Map.merge(@buy, %{order_type: type, price: 1, stop_price: 2})

        assert Orders.build(request) == {:error, {:stop_price_not_allowed, type}}
      end
    end

    test "a limit price on a plain stop is refused" do
      request = Map.merge(@buy, %{order_type: :stop, stop_price: 1, price: 2})

      assert Orders.build(request) == {:error, {:price_not_allowed, :stop}}
    end

    test "a trailing field on a non-trailing order is refused, whatever the type" do
      for {type, extra} <- [
            market: %{},
            limit: %{price: 1},
            stop: %{stop_price: 1},
            stop_limit: %{stop_price: 1, price: 1}
          ],
          key <- [:stop_price_offset, :stop_price_link_basis, :stop_price_link_type] do
        request = @buy |> Map.merge(extra) |> Map.merge(%{key => 5, order_type: type})

        assert Orders.build(request) == {:error, {:trailing_field_not_allowed, key, type}}
      end
    end

    test "a trailing stop takes no price or stop price" do
      base = Map.merge(@buy, %{order_type: :trailing_stop, stop_price_offset: 10})

      assert Orders.build(Map.put(base, :price, 1)) ==
               {:error, {:price_not_allowed, :trailing_stop}}

      assert Orders.build(Map.put(base, :stop_price, 1)) ==
               {:error, {:stop_price_not_allowed, :trailing_stop}}
    end

    test "a trailing stop limit takes a price but not a stop price" do
      base = Map.merge(@buy, %{order_type: :trailing_stop_limit, stop_price_offset: 10})

      assert {:ok, %{"price" => "1"}} = Orders.build(Map.put(base, :price, 1))

      assert Orders.build(Map.put(base, :stop_price, 1)) ==
               {:error, {:stop_price_not_allowed, :trailing_stop_limit}}
    end

    test "a forwarded nil is absent, not a meaningless field" do
      request = Map.merge(@buy, %{order_type: :market, price: nil, stop_price: nil})

      assert {:ok, payload} = Orders.build(request)
      refute Map.has_key?(payload, "price")
    end

    test "a missing required field is reported before a meaningless one" do
      request = Map.merge(@buy, %{order_type: :limit, stop_price: 1})

      assert Orders.build(request) == {:error, {:missing_order_field, :price}}
    end
  end

  describe "an invalid instruction names the value given" do
    test "a non-string instruction is reported as itself, not as the side" do
      assert Orders.build(Map.put(@buy, :instruction, :buy)) ==
               {:error, {:invalid_instruction, :buy}}

      assert Orders.build(Map.put(@buy, :instruction, 42)) ==
               {:error, {:invalid_instruction, 42}}
    end

    test "a side that is not buy or sell is reported as itself" do
      assert Orders.build(%{symbol: "AAPL", side: :hold, quantity: 1}) ==
               {:error, {:invalid_instruction, :hold}}
    end
  end
end
