defmodule DpExchange.Schwab.SocketTest do
  @moduledoc """
  The Streamer socket's state machine, exercised through its callbacks.

  `WebSockex` callbacks are pure functions over state, so the rules that matter are testable
  without a server: **LOGIN gates every other command**, a rejected login still arrives as a
  response, and a reconnect clears the session rather than pretending it survived.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Notice, Types}
  alias DpExchange.Schwab.{Socket, StreamerInfo}

  @info %StreamerInfo{
    socket_url: "wss://streamer-api.schwab.com/ws",
    customer_id: "cust-1",
    correl_id: "corr-1",
    channel: "IO",
    function_id: "APIAPP"
  }

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        info: @info,
        access_token: "token-abc",
        subscriber: self(),
        logged_in?: false,
        request_id: 1,
        subscriptions: MapSet.new()
      },
      overrides
    )
  end

  defp frame(payload), do: {:text, Jason.encode!(payload)}

  describe "connecting sends LOGIN and nothing else" do
    test "connect schedules the login rather than replying, which the behaviour forbids" do
      assert {:ok, _state} = Socket.handle_connect(%{}, state())
      assert_received :login
    end

    test "the login frame carries the token and both identifiers" do
      assert {:reply, {:text, raw}, new_state} = Socket.handle_info(:login, state())

      assert %{"requests" => [login]} = Jason.decode!(raw)
      assert login["service"] == "ADMIN"
      assert login["command"] == "LOGIN"
      assert login["parameters"]["Authorization"] == "token-abc"
      assert login["SchwabClientCustomerId"] == "cust-1"
      assert login["SchwabClientCorrelId"] == "corr-1"
      assert new_state.request_id == 2
    end

    test "connecting does NOT announce link_up" do
      # The link is up and the session is not. Announcing here tells a consumer the feed is
      # live while the venue is still ignoring every command.
      assert {:ok, _state} = Socket.handle_connect(%{}, state())
      refute_received {:dp_exchange, :schwab, %Notice{kind: :link_up}}
    end

    test "an unrelated message is ignored" do
      assert {:ok, _state} = Socket.handle_info(:tick, state())
    end
  end

  describe "LOGIN gates every other command" do
    test "a subscribe before login is dropped and reported, not queued" do
      # A caller told the subscription succeeded would wait for data the venue never agreed
      # to send.
      assert {:ok, unchanged} =
               Socket.handle_cast(
                 {:subscribe, "LEVELONE_EQUITIES", "SUBS", ~w(AAPL), []},
                 state()
               )

      assert unchanged.subscriptions == MapSet.new()
      assert_received {:dp_exchange, :schwab, %Notice{kind: :degraded}}
    end

    test "a subscribe after login goes out" do
      assert {:reply, {:text, raw}, new_state} =
               Socket.handle_cast(
                 {:subscribe, "LEVELONE_EQUITIES", "SUBS", ~w(AAPL MSFT), []},
                 state(%{logged_in?: true})
               )

      assert %{"requests" => [request]} = Jason.decode!(raw)
      assert request["service"] == "LEVELONE_EQUITIES"
      assert request["command"] == "SUBS"
      assert request["parameters"]["keys"] == "AAPL,MSFT"
      assert MapSet.size(new_state.subscriptions) == 1
    end

    test "an invalid subscribe is reported rather than sent" do
      assert {:ok, _state} =
               Socket.handle_cast(
                 {:subscribe, "LEVELONE_CRYPTO", "SUBS", ~w(BTC), []},
                 state(%{logged_in?: true})
               )

      assert_received {:dp_exchange, :schwab, %Notice{kind: :degraded}}
    end
  end

  describe "a response can arrive and still say no" do
    test "a successful LOGIN sets the session and announces link_up" do
      response = %{
        "response" => [
          %{"service" => "ADMIN", "command" => "LOGIN", "content" => %{"code" => 0}}
        ]
      }

      assert {:ok, new_state} = Socket.handle_frame(frame(response), state())

      assert new_state.logged_in?
      assert_received {:dp_exchange, :schwab, %Notice{kind: :link_up}}
    end

    test "a REJECTED login leaves the session closed and says why" do
      # Treating a response's arrival as success is how a socket waits forever for data.
      response = %{
        "response" => [
          %{
            "service" => "ADMIN",
            "command" => "LOGIN",
            "content" => %{"code" => 3, "msg" => "credential rejected"}
          }
        ]
      }

      assert {:ok, new_state} = Socket.handle_frame(frame(response), state())

      refute new_state.logged_in?
      assert_received {:dp_exchange, :schwab, %Notice{kind: :degraded, details: details}}
      assert details.reason == "credential rejected"
    end

    test "a rejected subscription is reported without closing the session" do
      response = %{
        "response" => [
          %{
            "service" => "LEVELONE_EQUITIES",
            "command" => "SUBS",
            "content" => %{"code" => 9, "msg" => "not entitled"}
          }
        ]
      }

      assert {:ok, new_state} = Socket.handle_frame(frame(response), state(%{logged_in?: true}))

      assert new_state.logged_in?
      assert_received {:dp_exchange, :schwab, %Notice{kind: :degraded}}
    end
  end

  describe "reconnection is not resubscription" do
    test "a disconnect clears the session and the subscriptions" do
      # A socket that kept believing it was subscribed would report a healthy feed that
      # receives nothing.
      before =
        state(%{logged_in?: true, subscriptions: MapSet.new([{"LEVELONE_EQUITIES", ~w(AAPL)}])})

      assert {:reconnect, cleared} = Socket.handle_disconnect(%{reason: :closed}, before)

      refute cleared.logged_in?
      assert cleared.subscriptions == MapSet.new()
      assert_received {:dp_exchange, :schwab, %Notice{kind: :link_down}}
    end
  end

  describe "data frames" do
    test "a LEVELONE frame emits BOTH a quote and a top of book" do
      # One frame is two facts: bid and ask are resting orders, last is an execution.
      data = %{
        "data" => [
          %{
            "service" => "LEVELONE_EQUITIES",
            "content" => [
              %{"key" => "AAPL", "0" => "AAPL", "1" => 10.5, "2" => 10.6, "3" => 10.55}
            ]
          }
        ]
      }

      assert {:ok, _state} = Socket.handle_frame(frame(data), state(%{logged_in?: true}))

      assert_received {:dp_exchange, :schwab, %Types.Quote{} = quote_}
      assert_received {:dp_exchange, :schwab, %Types.TopOfBook{} = top}
      assert Decimal.equal?(quote_.price, Decimal.new("10.55"))
      assert Decimal.equal?(top.bid, Decimal.new("10.5"))
    end

    test "a LEVELONE frame with no last emits ONLY the top of book" do
      # The top of book still stands; a quote would have to invent a traded price.
      data = %{
        "data" => [
          %{
            "service" => "LEVELONE_EQUITIES",
            "content" => [%{"key" => "AAPL", "0" => "AAPL", "1" => 10.5, "2" => 10.6}]
          }
        ]
      }

      assert {:ok, _state} = Socket.handle_frame(frame(data), state(%{logged_in?: true}))

      assert_received {:dp_exchange, :schwab, %Types.TopOfBook{}}
      refute_received {:dp_exchange, :schwab, %Types.Quote{}}
    end

    test "a CHART frame emits a candle" do
      data = %{
        "data" => [
          %{
            "service" => "CHART_EQUITY",
            "content" => [
              %{
                "key" => "AAPL",
                "0" => "AAPL",
                "1" => 10.0,
                "2" => 11.0,
                "3" => 9.5,
                "4" => 10.5,
                "5" => 1000,
                "7" => 1_787_936_147_000
              }
            ]
          }
        ]
      }

      assert {:ok, _state} = Socket.handle_frame(frame(data), state(%{logged_in?: true}))

      assert_received {:dp_exchange, :schwab, %Types.Candle{} = candle}
      assert candle.opened_at == DateTime.from_unix!(1_787_936_147_000, :millisecond)
    end

    test "a BOOK frame emits an order book" do
      data = %{
        "data" => [
          %{
            "service" => "NASDAQ_BOOK",
            "content" => [
              %{
                "key" => "AAPL",
                "0" => "AAPL",
                "1" => 1_787_936_147_000,
                "2" => [[10.50, 300, 1, []]],
                "3" => [[10.60, 200, 1, []]]
              }
            ]
          }
        ]
      }

      assert {:ok, _state} = Socket.handle_frame(frame(data), state(%{logged_in?: true}))

      assert_received {:dp_exchange, :schwab, %Types.OrderBook{} = book}
      assert length(book.bids) == 1
      assert book.timestamp == DateTime.from_unix!(1_787_936_147_000, :millisecond)
    end

    test "a service with no field map emits nothing rather than a wrong field" do
      # Silence is correct here; a value decoded with another service's numbering is not.
      data = %{"data" => [%{"service" => "ADMIN", "content" => [%{"1" => "x"}]}]}

      assert {:ok, _state} = Socket.handle_frame(frame(data), state(%{logged_in?: true}))
      refute_received {:dp_exchange, :schwab, _anything}
    end

    test "a heartbeat is not data" do
      # Reading one as a quote is a price that never traded.
      notify = %{"notify" => [%{"heartbeat" => "1668715930582"}]}

      assert {:ok, _state} = Socket.handle_frame(frame(notify), state(%{logged_in?: true}))
      refute_received {:dp_exchange, :schwab, _anything}
    end

    test "a malformed frame does not take down the socket" do
      # One bad message must not kill a live feed.
      assert {:ok, _state} = Socket.handle_frame({:text, "not json"}, state())
    end

    test "an unrecognised frame shape is ignored" do
      assert {:ok, _state} =
               Socket.handle_frame(frame(%{"something" => []}), state(%{logged_in?: true}))

      refute_received {:dp_exchange, :schwab, _anything}
    end
  end
end
