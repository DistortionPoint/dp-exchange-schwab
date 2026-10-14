defmodule DpExchange.Schwab.FrameRetentionTest do
  @moduledoc """
  A symbol that leaves `Socket` must not keep the Streamer frame it was read from alive.

  `Jason.decode/1` returns strings as sub-binaries pointing into the raw frame, so a four-byte
  symbol retains the whole frame for as long as anything holds it. The socket holds it for the
  session (`last_top`, the reported-sets), `Feed` holds it as a `delivering` and `kinds` key,
  and a consumer holds it in every cached value. `:binary.referenced_byte_size/1` is the
  structural measure: it is the size of the binary a term keeps alive, not the size of the
  term, so a copy answers its own size and a slice of a frame answers the frame's.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Core.Types.{Quote, TopOfBook}
  alias DpExchange.Schwab.{Credentials, Socket, StreamerInfo}

  @info %StreamerInfo{
    socket_url: "wss://streamer-api.schwab.com/ws",
    customer_id: "cust-1",
    correl_id: "corr-1",
    channel: "IO",
    function_id: "APIAPP"
  }

  # Far larger than any symbol, and under a field number no service names, so it is dropped by
  # `StreamerProtocol.rename/2` and exists only to make the frame big.
  @padding String.duplicate("x", 20_000)

  defp state do
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
      last_top: %{}
    }
  end

  defp frame(row) do
    {:text,
     Jason.encode!(%{
       "data" => [%{"service" => "LEVELONE_EQUITIES", "command" => "SUBS", "content" => [row]}]
     })}
  end

  defp held_bytes(binary), do: :binary.referenced_byte_size(binary)

  test "the symbol on a delivered quote and top of book is not a slice of the frame" do
    row = %{"key" => "AAPL", "1" => 99.5, "2" => 100.5, "3" => 100.0, "999" => @padding}

    assert {:ok, after_frame} = Socket.handle_frame(frame(row), state())

    assert_received {:dp_exchange, :schwab, %Quote{symbol: "AAPL"} = quote_struct}
    assert_received {:dp_exchange, :schwab, %TopOfBook{symbol: "AAPL"} = top}

    assert held_bytes(quote_struct.symbol) == byte_size("AAPL")
    assert held_bytes(top.symbol) == byte_size("AAPL")

    # The key the socket carries for the session.
    assert [carried] = Map.keys(after_frame.last_top)
    assert held_bytes(carried) == byte_size("AAPL")
  end

  test "a symbol remembered as delayed is not a slice of the frame" do
    row = %{"key" => "AAPL", "delayed" => true, "1" => 99.5, "3" => 100.0, "999" => @padding}

    assert {:ok, after_frame} = Socket.handle_frame(frame(row), state())

    assert_received {:dp_exchange, :schwab, %Notice{kind: :degraded}}
    assert [reported] = MapSet.to_list(after_frame.delayed_reported)
    assert held_bytes(reported) == byte_size("AAPL")
  end

  test "a symbol remembered as unreadable is not a slice of the frame" do
    row = %{"key" => "AAPL", "1" => "not a number", "2" => 100.5, "999" => @padding}

    assert {:ok, after_frame} = Socket.handle_frame(frame(row), state())

    assert_received {:dp_exchange, :schwab, %Notice{kind: :degraded}}
    assert [{_what, reported}] = MapSet.to_list(after_frame.unreadable_reported)
    assert held_bytes(reported) == byte_size("AAPL")
  end
end
