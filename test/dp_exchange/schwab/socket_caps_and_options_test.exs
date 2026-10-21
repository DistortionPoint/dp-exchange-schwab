defmodule DpExchange.Schwab.SocketCapsAndOptionsTest do
  @moduledoc """
  Two promises the `Socket` documents: `start_link/1` refuses a bad timeout before dialling,
  and a book for a symbol past the carry cap is announced and not published.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Core.Types.TopOfBook
  alias DpExchange.Schwab.{Credentials, Socket, StreamerInfo}

  @info %StreamerInfo{
    socket_url: "wss://streamer-api.schwab.com/ws",
    customer_id: "cust-1",
    correl_id: "corr-1",
    channel: "IO",
    function_id: "APIAPP"
  }

  defp start_opts(extra) do
    Keyword.merge([subscriber: self(), access_token: "token-abc", streamer_info: @info], extra)
  end

  describe "Socket.start_link/1 timeouts" do
    test "a non-positive or non-integer connect timeout is refused before dialling" do
      for bad <- [0, -1, 1.5, "3000", :infinity] do
        assert Socket.start_link(start_opts(socket_connect_timeout: bad)) ==
                 {:error, {:invalid_option, :socket_connect_timeout, bad}}
      end
    end

    test "a bad receive timeout is refused the same way" do
      assert Socket.start_link(start_opts(socket_recv_timeout: 0)) ==
               {:error, {:invalid_option, :socket_recv_timeout, 0}}
    end

    test "a nil timeout is silence, so the insecure-url refusal is what answers" do
      opts =
        start_opts(
          socket_connect_timeout: nil,
          socket_recv_timeout: nil,
          url: "ws://streamer.example.invalid/ws"
        )

      assert Socket.start_link(opts) == {:error, {:insecure_url, :schwab}}
    end
  end

  defp capped_state do
    %{
      info: @info,
      credentials: Credentials.wrap_token("token-abc"),
      subscriber: self(),
      logged_in?: true,
      request_id: 1,
      login_failures: 0,
      logged_in_once?: true,
      held: [],
      subscribed: %{},
      last_heard_at: nil,
      liveness: nil,
      last_top: Map.new(1..5_000, &{"S#{&1}", :carried})
    }
  end

  defp book_frame(symbol) do
    row = %{"key" => symbol, "1" => 10.0, "2" => 10.1, "4" => 3, "5" => 2}
    data = %{"service" => "LEVELONE_EQUITIES", "content" => [row]}
    {:text, Jason.encode!(%{"data" => [data]})}
  end

  describe "a book past the carry cap" do
    test "a symbol not carried is not published, and is announced once" do
      assert {:ok, after_first} = Socket.handle_frame(book_frame("NEWSYM"), capped_state())

      refute_receive {:dp_exchange, :schwab, %TopOfBook{}}, 500

      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :degraded, details: %{reason: :book_state_capped} = details}},
                     5_000

      assert details.symbol == "NEWSYM"

      assert {:ok, _again} = Socket.handle_frame(book_frame("OTHER"), after_first)

      refute_receive {:dp_exchange, :schwab, %Notice{details: %{reason: :book_state_capped}}},
                     500

      refute_receive {:dp_exchange, :schwab, %TopOfBook{}}, 500
    end

    test "a symbol already carried is still published and merged" do
      assert {:ok, _state} = Socket.handle_frame(book_frame("S1"), capped_state())

      assert_receive {:dp_exchange, :schwab, %TopOfBook{symbol: "S1", bid_size: bid_size}},
                     5_000

      assert Decimal.equal?(bid_size, 3)

      refute_receive {:dp_exchange, :schwab, %Notice{details: %{reason: :book_state_capped}}},
                     500
    end
  end
end
