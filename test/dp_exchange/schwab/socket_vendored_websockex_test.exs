defmodule DpExchange.Schwab.SocketVendoredWebSockexTest do
  @moduledoc """
  The two defects `DpExchange.Schwab.Vendor.WebSockex` exists to fix, each driven through
  a real `Socket.start_link/1` against a real TCP server on `127.0.0.1`. Tier 1, no network:
  a unit call to a callback cannot show that the library driving it does not stall or raise
  first.

    * **The opening handshake has a deadline**, `socket_connect_timeout` plus
      `socket_recv_timeout`. websockex 0.5.1 bounds each `recv` of the upgrade response
      separately and every chunk restarts that timer, so a peer that trickled the response
      held a start or a reconnect open indefinitely. Measured 2026-09-27 on Coinbase's
      `start_link/1` against a server sending one byte every 200 ms was still connecting
      at 12 s.
    * **A malformed close frame disconnects instead of crashing.** websockex 0.5.1's
      `websocket_loop/3` has no clause for `WebSockex.Frame.parse_frame/1`'s own error
      return, so a close frame with an invalid status code raised `CaseClauseError` before
      `handle_disconnect/2` could run. Measured live on Webull; the defect is websockex's.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Schwab.{Socket, StreamerInfo}

  @moduletag :capture_log

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  # 200 + 300: the deadline under test is 500 ms.
  @timeouts [socket_connect_timeout: 200, socket_recv_timeout: 300]

  # FIN + close, length 10, "bye-bye!!!": the first two bytes are no valid close code.
  @malformed_close_frame <<136, 10, 98, 121, 101, 45, 98, 121, 101, 33, 33, 33>>

  test "a start whose upgrade response trickles in fails at the deadline" do
    {listen_socket, port} = listen()
    serve(listen_socket, [&trickle/1])

    started = System.monotonic_time(:millisecond)
    task = Task.async(fn -> Socket.start_link(socket_opts(port)) end)

    # Without the deadline this call does not return at all, so the yield is what fails.
    assert {:ok, {:error, %WebSockex.ConnError{original: :timeout}}} =
             Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)

    assert System.monotonic_time(:millisecond) - started < 3_000
  end

  test "a reconnect whose upgrade response trickles in fails at the deadline and retries" do
    test_pid = self()
    {listen_socket, port} = listen()

    serve(listen_socket, [
      &upgrade_then_close/1,
      &trickle/1,
      fn socket ->
        send(test_pid, :third_connection)
        :gen_tcp.close(socket)
      end
    ])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port))
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    # The first reconnect trickles. Only a deadline ends it, and only then can the socket
    # make its next attempt: attempt 2 waits one second of backoff, so this lands at about
    # 1.5 s. Without the deadline it never arrives.
    assert_receive :third_connection, 10_000
  end

  test "a malformed close frame disconnects cleanly instead of crashing the socket" do
    {listen_socket, port} = listen()
    serve(listen_socket, [&upgrade_then_send_malformed_close/1])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port))
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    # `handle_disconnect/2` ran: it is what sends `:link_down`. Upstream crashed first.
    assert_receive {:dp_exchange, :schwab, %Notice{kind: :link_down, details: details}},
                   10_000

    assert details.reason =~ "invalid_close_code"
    assert Process.alive?(socket_pid)
  end

  test "a wss peer whose certificate nothing trusts is refused" do
    # websockex's own default is `verify: :verify_none`. Against this server, the TLS
    # handshake used to complete and the upgrade request went out.
    key = [key: {:rsa, 2048, 65_537}]

    %{server_config: server} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: key, intermediates: [], peer: key},
        client_chain: %{root: key, intermediates: [], peer: key}
      })

    {:ok, listen_socket} = :ssl.listen(0, [:binary, active: false, reuseaddr: true] ++ server)
    on_exit(fn -> :ssl.close(listen_socket) end)
    {:ok, {_address, port}} = :ssl.sockname(listen_socket)
    test_pid = self()

    spawn(fn ->
      {:ok, transport} = :ssl.transport_accept(listen_socket, 10_000)
      send(test_pid, {:server_handshake, elem(:ssl.handshake(transport, 5_000), 0)})
    end)

    # Generous timeouts: this asserts a TLS refusal, and a 2048-bit RSA handshake on a loaded
    # machine can outlast the 500 ms handshake deadline the other tests here use.
    opts =
      socket_opts(port)
      |> Keyword.merge(url: "wss://localhost:#{port}/", socket_connect_timeout: 10_000)
      |> Keyword.put(:socket_recv_timeout, 10_000)

    assert {:error, %WebSockex.ConnError{original: {:tls_alert, _alert}}} =
             Socket.start_link(opts)

    assert_receive {:server_handshake, :error}, 5_000
  end

  defp socket_opts(port) do
    [
      url: "ws://127.0.0.1:#{port}/",
      subscriber: self(),
      access_token: "test-token",
      streamer_info: %StreamerInfo{
        socket_url: "ws://127.0.0.1:#{port}/",
        customer_id: "cust-1",
        correl_id: "corr-1",
        channel: "IO",
        function_id: "APIAPP"
      }
    ] ++ @timeouts
  end

  defp listen do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    on_exit(fn -> :gen_tcp.close(listen_socket) end)
    {:ok, port} = :inet.port(listen_socket)
    {listen_socket, port}
  end

  # Each handler serves one accepted connection, in order.
  defp serve(listen_socket, handlers) do
    server =
      spawn(fn ->
        Enum.each(handlers, fn handler ->
          {:ok, client_socket} = :gen_tcp.accept(listen_socket, 10_000)
          handler.(client_socket)
        end)
      end)

    on_exit(fn -> Process.exit(server, :kill) end)
  end

  defp trickle(socket) do
    {:ok, _request} = recv_until_headers_end(socket, "")
    :ok = :gen_tcp.send(socket, "HTTP/1.1 101 Switching Protocols\r\n")
    drip(socket)
  end

  # One byte every 100 ms, which restarts a per-`recv` timer of 300 ms forever. Stops when
  # the client closes, which is what the deadline does.
  defp drip(socket) do
    case :gen_tcp.send(socket, "X") do
      :ok ->
        Process.sleep(100)
        drip(socket)

      {:error, _closed} ->
        :ok
    end
  end

  defp upgrade_then_close(socket) do
    upgrade(socket)
    :gen_tcp.close(socket)
  end

  defp upgrade_then_send_malformed_close(socket) do
    upgrade(socket)
    :ok = :gen_tcp.send(socket, @malformed_close_frame)
    # Waits for the client to tear down, so the close cannot race the frame.
    # This socket sends LOGIN on connect, so a read can return that frame first. Read until
    # the client has actually closed.
    read_until_closed(socket)
    :gen_tcp.close(socket)
  end

  defp upgrade(socket) do
    {:ok, request} = recv_until_headers_end(socket, "")

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Accept: #{accept_header(request)}\r\n\r\n"
      )
  end

  defp read_until_closed(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, _frame} -> read_until_closed(socket)
      {:error, _closed} -> :ok
    end
  end

  defp recv_until_headers_end(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> recv_until_headers_end(socket, acc <> data)
        {:error, _reason} = error -> error
      end
    end
  end

  defp accept_header(request) do
    [_full_match, key] = Regex.run(~r/Sec-WebSocket-Key:\s*(\S+)/i, request)

    :sha
    |> :crypto.hash(key <> @handshake_guid)
    |> Base.encode64()
  end
end
