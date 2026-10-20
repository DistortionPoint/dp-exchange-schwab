defmodule DpExchange.Schwab.ProcessProbe do
  @moduledoc """
  The `process_probe:` for Core's conformance group 51: starts the long-lived processes that
  hold a credential, with no network, so the group can render what OTP would print for them.

  Handed a map holding one canary under every secret key name, it starts:

    * the tree's supervisor, its `Feed` and its `Ledger`, with the canaries as the feed's
      credentials, and pushes them through `update_credentials/2` so the ledger holds them too;
    * a `Socket` whose access token and `StreamerInfo` identifiers are the canary, connected to
      a local TCP server that accepts the upgrade and says nothing else (the `allow_insecure_socket`
      test seam), so nothing dials the venue.

  Answers `{:ok, pids}`; the group asks each for `:sys.get_status/2`, fails on a canary, and
  kills them afterwards. The supervisor is listed first so killing it ends its children rather
  than being restarted by it.
  """

  alias DpExchange.Schwab
  alias DpExchange.Schwab.{Ledger, Socket, StreamerInfo}
  alias DpExchange.Schwab.Supervisor, as: SchwabSupervisor

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @doc "Starts the credential-holding processes from `secrets`; `{:ok, [pid]}`."
  @spec start(map()) :: {:ok, [pid()]} | {:error, term()}
  def start(secrets) when is_map(secrets) do
    name = :"process_probe_#{System.unique_integer([:positive])}"

    with {:ok, supervisor} <- Schwab.start_link(name: name, credentials: secrets, symbols: []),
         :ok <- Schwab.update_credentials(secrets, name: name),
         {:ok, socket} <- start_socket(secrets) do
      ledger = SchwabSupervisor.ledger_name(name: name)
      # A read after the write: the ledger has the credentials by the time it answers.
      _held = Ledger.fetch(ledger)

      pids =
        for server <- [supervisor, feed_name(name), ledger, socket] do
          if is_pid(server), do: server, else: Process.whereis(server)
        end

      {:ok, pids}
    end
  end

  defp feed_name(name), do: SchwabSupervisor.feed_name(name: name)

  defp start_socket(secrets) do
    canary = Map.fetch!(secrets, :access_token)
    port = serve_idle()

    Socket.start_link(
      url: "ws://127.0.0.1:#{port}/",
      allow_insecure_socket: true,
      subscriber: self(),
      access_token: canary,
      streamer_info: %StreamerInfo{
        socket_url: "ws://127.0.0.1:#{port}/",
        customer_id: canary,
        correl_id: canary,
        channel: "IO",
        function_id: "APIAPP"
      },
      socket_connect_timeout: 5_000,
      socket_recv_timeout: 5_000
    )
  end

  # A server process of its own (not linked to the caller), listening on a port nothing else
  # knows: it accepts one connection, completes the upgrade and then only reads until the client
  # goes away, which ends it, and its listening socket with it.
  defp serve_idle do
    caller = self()

    spawn(fn ->
      {:ok, listen_socket} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listen_socket)
      send(caller, {:probe_port, port})

      {:ok, client} = :gen_tcp.accept(listen_socket, 10_000)
      upgrade(client)
      read_until_closed(client)
    end)

    receive do
      {:probe_port, port} -> port
    after
      5_000 -> raise "the probe's local server did not start"
    end
  end

  defp upgrade(client) do
    {:ok, request} = recv_headers(client, "")

    :ok =
      :gen_tcp.send(
        client,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Accept: #{accept_header(request)}\r\n\r\n"
      )
  end

  defp recv_headers(client, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      with {:ok, data} <- :gen_tcp.recv(client, 0, 5_000), do: recv_headers(client, acc <> data)
    end
  end

  defp read_until_closed(client) do
    case :gen_tcp.recv(client, 0, 60_000) do
      {:ok, _frame} -> read_until_closed(client)
      {:error, _closed} -> :ok
    end
  end

  defp accept_header(request) do
    [_full_match, key] = Regex.run(~r/Sec-WebSocket-Key:\s*(\S+)/i, request)

    :sha
    |> :crypto.hash(key <> @handshake_guid)
    |> Base.encode64()
  end
end
