defmodule DpExchange.Schwab.TickAqTest do
  @moduledoc """
  Numbers, option validation and unbounded state (tick AQ): equity price increments,
  plain-notation quantities, venue number digit bounds, start-time option checks and the
  Streamer's pending-request bound.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Schwab.{Credentials, Fake, Feed, Orders, Socket, StreamerDecode, StreamerInfo}

  @buy %{symbol: "AAPL", side: :buy, quantity: 15, order_type: :limit, time_in_force: :day}
  @option "AAPL  260116C00250000"

  describe "an equity price must sit on the price increment, and is refused rather than rounded" do
    test "at or above one dollar the increment is a cent" do
      assert {:ok, %{"price" => "190.25"}} = Orders.build(Map.put(@buy, :price, "190.25"))

      assert Orders.build(Map.put(@buy, :price, Decimal.new("190.255"))) ==
               {:error, {:price_not_on_tick, :price, Decimal.new("190.255"), "0.01"}}

      assert Orders.build(Map.put(@buy, :price, "1.001")) ==
               {:error, {:price_not_on_tick, :price, "1.001", "0.01"}}
    end

    test "below one dollar the increment is a hundredth of a cent" do
      assert {:ok, %{"price" => "0.9999"}} = Orders.build(Map.put(@buy, :price, "0.9999"))

      assert Orders.build(Map.put(@buy, :price, Decimal.new("0.00000001"))) ==
               {:error, {:price_not_on_tick, :price, Decimal.new("0.00000001"), "0.0001"}}
    end

    test "a stop price is judged the same way" do
      request = Map.merge(@buy, %{order_type: :stop, stop_price: "10.005"})

      assert Orders.build(Map.delete(request, :price)) ==
               {:error, {:price_not_on_tick, :stop_price, "10.005", "0.01"}}
    end

    test "an option price is not judged, and the Fake refuses what the facade builder refuses" do
      option = %{@buy | symbol: @option, side: :buy} |> Map.put(:instruction, "BUY_TO_OPEN")
      assert {:ok, %{"price" => "6.455"}} = Orders.build(Map.put(option, :price, "6.455"))

      off = Map.put(@buy, :price, "190.255")

      assert Fake.place_order(%{access_token: "t"}, off, account_hash: "H") ==
               {:error, {:price_not_on_tick, :price, "190.255", "0.01"}}
    end
  end

  describe "quantities are never written in scientific notation" do
    test "a tiny or huge quantity is plain digits in the JSON" do
      for {quantity, plain} <- [
            {Decimal.new("0.00001"), "0.00001"},
            {Decimal.new("1E+14"), "100000000000000"}
          ] do
        assert {:ok, payload} = Orders.build(Map.merge(@buy, %{quantity: quantity, price: 1}))
        [leg] = payload["orderLegCollection"]
        assert Jason.encode!(leg["quantity"]) == plain
      end
    end

    test "an ordinary quantity stays the float it was" do
      assert {:ok, payload} = Orders.build(Map.merge(@buy, %{quantity: "0.25", price: 1}))
      assert [%{"quantity" => 0.25}] = payload["orderLegCollection"]
    end

    test "an accepted order reports a plain-digit quantity as the Decimal that was sent" do
      assert {:ok, payload} = Orders.build(Map.merge(@buy, %{quantity: "0.00001", price: 1}))
      assert {:ok, order} = Orders.accepted("7", payload)
      assert Decimal.eq?(order.quantity, Decimal.new("0.00001"))
    end

    test "an integer the venue's double cannot hold is refused" do
      too_big = 9_007_199_254_740_993

      assert Orders.build(Map.merge(@buy, %{quantity: too_big, price: 1})) ==
               {:error, {:invalid_quantity, too_big}}
    end
  end

  describe "a trailing offset is a distance" do
    test "zero and negative offsets are refused" do
      request = %{@buy | order_type: :trailing_stop} |> Map.delete(:price)

      for bad <- [0, -1, "0", Decimal.new("-0.5")] do
        assert Orders.build(Map.put(request, :stop_price_offset, bad)) ==
                 {:error, {:invalid_order_field, :stop_price_offset, bad}}
      end

      assert {:ok, payload} = Orders.build(Map.put(request, :stop_price_offset, 1))
      assert Jason.encode!(payload["stopPriceOffset"]) == "1"
    end
  end

  describe "venue numbers are bounded to 34 digits" do
    test "an integer or float with too many digits is no price" do
      huge = Integer.pow(10, 40)
      now = DateTime.utc_now()

      assert {:error, {:invalid_decimal, :price, _value}} =
               StreamerDecode.to_quote(%{last: huge}, "AAPL", now)

      assert {:error, {:invalid_decimal, :price, _value}} =
               StreamerDecode.to_quote(%{last: Integer.to_string(huge)}, "AAPL", now)

      assert {:ok, %{price: price}} =
               StreamerDecode.to_quote(%{last: 123_456_789_012_345}, "AAPL", now)

      assert Decimal.eq?(price, Decimal.new("123456789012345"))
    end
  end

  describe "options that would fail later fail at start" do
    test "an unusable boot subscriber is refused" do
      for bad <- ["consumer", 42, {:global, :x}, true, false] do
        assert_raise ArgumentError, ~r/subscriber must be a pid or a registered name/, fn ->
          Feed.init(subscriber: bad)
        end
      end

      assert {:ok, _result} = Feed.init(subscriber: self())
      assert {:ok, _result} = Feed.init(subscriber: nil)
    end

    test "timers and connect budgets must be positive integers" do
      for key <- [
            :route_bootstrap_timeout_ms,
            :bootstrap_reply_ms,
            :socket_connect_timeout,
            :socket_recv_timeout
          ],
          bad <- [0, -1, 1.5, "100"] do
        assert_raise ArgumentError, ~r/#{key} must be a positive integer/, fn ->
          Feed.init([{key, bad}])
        end
      end

      assert {:ok, _result} = Feed.init(route_bootstrap_timeout_ms: nil, bootstrap_reply_ms: 200)
    end

    test "a forwarded name: nil is the default child id, for the feed and the fake" do
      assert Feed.child_spec(name: nil).id == Feed
      assert Fake.child_spec(name: nil).id == Fake
      assert Fake.child_spec(name: :mine).id == :mine
    end
  end

  describe "the Streamer's pending-request map is bounded and says what it drops" do
    @info %StreamerInfo{
      socket_url: "wss://streamer-api.schwab.com/ws",
      customer_id: "cust-1",
      correl_id: "corr-1",
      channel: "IO",
      function_id: "APIAPP"
    }

    test "past the cap the oldest is forgotten, the newest kept, and a notice sent" do
      state = %{
        info: @info,
        credentials: Credentials.wrap_token("token-abc"),
        subscriber: self(),
        logged_in?: true,
        request_id: 1,
        login_failures: 0,
        last_heard_at: nil,
        logged_in_once?: false,
        held: [],
        subscribed: %{},
        last_top: %{}
      }

      final =
        Enum.reduce(1..300, state, fn n, acc ->
          {:reply, _frame, next} =
            Socket.handle_cast({:subscribe, "LEVELONE_EQUITIES", "SUBS", ["S#{n}"], []}, acc)

          next
        end)

      assert map_size(final.pending) == 256
      refute Map.has_key?(final.pending, "1")
      assert Map.has_key?(final.pending, "300")

      assert_received {:dp_exchange, :schwab,
                       %Notice{kind: :degraded, details: %{reason: :unanswered_commands}}}

      # Answering what is left empties the map: the add/remove cycle returns to the start.
      answered =
        Enum.reduce(final.pending, final, fn {id, _command}, acc ->
          response = %{
            "response" => [
              %{
                "service" => "LEVELONE_EQUITIES",
                "command" => "SUBS",
                "requestid" => id,
                "content" => %{"code" => 0}
              }
            ]
          }

          {:ok, next} = Socket.handle_frame({:text, Jason.encode!(response)}, acc)
          next
        end)

      assert answered.pending == %{}
    end
  end
end
