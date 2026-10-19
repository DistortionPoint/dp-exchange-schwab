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
  alias DpExchange.Schwab.Vendor.WebSockex, as: VendoredWebSockex

  @moduletag :capture_log

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  # 200 + 300: the deadline under test is 500 ms.
  @timeouts [socket_connect_timeout: 200, socket_recv_timeout: 300]

  # FIN + close, length 10, "bye-bye!!!": the first two bytes are no valid close code.
  @malformed_close_frame <<136, 10, 98, 121, 101, 45, 98, 121, 101, 33, 33, 33>>

  # A client of the vendored module itself, to drive `handle_local_close/4` into a close frame
  # that cannot be sent. `Conn.socket_send/2` calls `conn.conn_mod.send/2`, but `open_socket/1`
  # only accepts `:gen_tcp` or `:ssl` as `conn_mod` (deps/websockex conn.ex `open_socket/1`
  # clauses), so a stub transport cannot be injected; the send is made to fail with a real
  # error instead. The peer resets the connection while the client has its socket passive (so
  # the reset is not read as a remote close first). The first send after a reset answers
  # `{:error, :closed}`, every later one `{:error, :enotconn}`: the client spends the first,
  # and the close frame gets the second, which neither of upstream's two reasons matched.
  # (Filling the send buffer until a send timed out was tried first and flaked: the close
  # frame sometimes still fit.)
  defmodule ResetClient do
    @moduledoc false
    use DpExchange.Schwab.Vendor.WebSockex

    @impl true
    def handle_connect(conn, test_pid), do: {:ok, %{test: test_pid, socket: conn.socket}}

    @impl true
    def handle_info(:go_passive, state) do
      :ok = :inet.setopts(state.socket, active: false)
      send(state.test, :passive)
      {:ok, state}
    end

    def handle_info(:spend_then_close, state) do
      send(state.test, {:spent, :gen_tcp.send(state.socket, "x")})
      {:close, state}
    end

    @impl true
    def handle_disconnect(status, state) do
      send(state.test, {:disconnected, status.reason})
      {:ok, state}
    end
  end

  test "a close frame that cannot be sent is a closed connection, not a crash" do
    {listen_socket, port} = listen()
    test_pid = self()

    serve(listen_socket, [
      fn socket ->
        upgrade(socket)
        send(test_pid, {:server, self()})

        receive do
          :reset ->
            :ok = :inet.setopts(socket, linger: {true, 0})
            :ok = :gen_tcp.close(socket)
            send(test_pid, :reset_done)
        after
          60_000 -> :ok
        end
      end
    ])

    conn = WebSockex.Conn.new("ws://127.0.0.1:#{port}/", @timeouts)
    {:ok, client} = VendoredWebSockex.start(conn, ResetClient, self(), [])
    on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)

    send(client, :go_passive)
    assert_receive :passive, 5_000

    assert_receive {:server, server}, 5_000
    send(server, :reset)
    assert_receive :reset_done, 5_000
    # The reset has to reach the client's stack before it sends.
    Process.sleep(200)

    send(client, :spend_then_close)

    assert_receive {:spent, {:error, :closed}}, 5_000
    # Upstream raised `CaseClauseError` here, before `handle_disconnect/2` could run.
    assert_receive {:disconnected, {:remote, :closed}}, 5_000
  end

  test "a start whose upgrade response trickles in fails at the deadline" do
    {listen_socket, port} = listen()
    serve(listen_socket, [&trickle/1])

    task = Task.async(fn -> Socket.start_link(socket_opts(port)) end)

    # Without the deadline this call does not return at all, so the yield is what fails.
    # No tighter wall-clock bound: under a loaded suite 500 ms of deadline measured 3.6 s
    # end to end, and returning at all is the property under test.
    assert {:ok, {:error, %WebSockex.ConnError{original: :timeout}}} =
             Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
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

  test "an upgrade response with no Sec-WebSocket-Accept ends the attempt, not the process" do
    # Upstream matched the header with `{_, res} = List.keyfind(...)`: a MatchError in the
    # linked handshake task, which killed the socket and the caller's start with it.
    {listen_socket, port} = listen()

    serve(listen_socket, [
      fn socket ->
        {:ok, _request} = recv_until_headers_end(socket, "")

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
          )

        read_until_closed(socket)
      end
    ])

    assert {:error, %WebSockex.HandshakeError{response: nil}} =
             Socket.start_link(socket_opts(port))
  end

  test "a malformed header line in the upgrade response ends the attempt, not the process" do
    # `WebSockex.Conn.decode_headers/2` has no clause for a line `:erlang.decode_packet/3`
    # calls an `:http_error`, so this raised in the linked handshake task.
    {listen_socket, port} = listen()

    serve(listen_socket, [
      fn socket ->
        {:ok, _request} = recv_until_headers_end(socket, "")

        :ok =
          :gen_tcp.send(socket, "HTTP/1.1 101 Switching Protocols\r\nnot a header line\r\n\r\n")

        read_until_closed(socket)
      end
    ])

    assert {:error, %WebSockex.ConnError{original: {:handshake_failed, _exception}}} =
             Socket.start_link(socket_opts(port))
  end

  test "a malformed close frame disconnects cleanly instead of crashing the socket" do
    {listen_socket, port} = listen()
    serve(listen_socket, [&upgrade_then_send_malformed_close/1])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port))
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    # `handle_disconnect/2` ran: it is what sends `:link_down`. Upstream crashed first.
    assert_receive {:dp_exchange, :schwab, %Notice{kind: :link_down, details: details}},
                   10_000

    assert details.reason == :connection_lost
    assert details.message =~ "invalid_close_code"
    assert Process.alive?(socket_pid)
  end

  test "a fragmented message that never ends is cut off at the size ceiling" do
    # Upstream joined every continuation onto the message with no ceiling, so a peer that
    # never sent the final frame grew this process's memory for as long as it kept sending.
    {listen_socket, port} = listen()
    serve(listen_socket, [&upgrade_then_send_endless_fragments/1])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port))
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    # The close is this side's own, code 1009, and `handle_disconnect/2` ran.
    assert_receive {:dp_exchange, :schwab, %Notice{kind: :link_down, details: details}},
                   30_000

    assert details.reason == :connection_lost
    assert details.message =~ "1009"
    assert Process.alive?(socket_pid)
  end

  test "a frame that declares a huge payload and never completes is cut off at the ceiling" do
    # Upstream kept appending to `state.buffer` while a frame stayed incomplete, and a header
    # declaring 2^40 bytes is never complete.
    {listen_socket, port} = listen()
    serve(listen_socket, [&upgrade_then_send_unfinished_frame/1])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port))
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    assert_receive {:dp_exchange, :schwab, %Notice{kind: :link_down, details: details}},
                   30_000

    assert details.reason == :connection_lost
    assert details.message =~ "1009"
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
      # Test-only seam: this server is plain TCP. `Socket` refuses `ws://` without it.
      allow_insecure_socket: true,
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

  # A text message started with FIN clear, then 140 continuation frames of 65_535 bytes with
  # no final frame: 9 MiB, past the 8 MiB ceiling. A send that fails is the client closing on
  # us, which is the outcome under test.
  defp upgrade_then_send_endless_fragments(socket) do
    upgrade(socket)
    chunk = :binary.copy("a", 65_535)
    :gen_tcp.send(socket, <<0::1, 0::3, 1::4, 0::1, 126::7, 65_535::16, chunk::binary>>)

    Enum.each(1..140, fn _n ->
      :gen_tcp.send(socket, <<0::1, 0::3, 0::4, 0::1, 126::7, 65_535::16, chunk::binary>>)
    end)

    read_until_closed(socket)
    :gen_tcp.close(socket)
  end

  # A FIN text frame whose header declares 2^40 bytes, of which 9 MiB ever arrive.
  defp upgrade_then_send_unfinished_frame(socket) do
    upgrade(socket)
    :gen_tcp.send(socket, <<1::1, 0::3, 1::4, 0::1, 127::7, 1_099_511_627_776::64>>)
    chunk = :binary.copy("a", 65_536)
    Enum.each(1..144, fn _n -> :gen_tcp.send(socket, chunk) end)

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
