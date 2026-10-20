defmodule DpExchange.Schwab.TickAoSecretsAndRetentionTest do
  @moduledoc """
  Tick AO: where a credential could surface, and what a small value keeps alive.

    * the `:global` name that guards a refresh is a keyed digest, not a bare hash of the token,
      so a name read off the cluster cannot confirm a guessed refresh token;
    * the Streamer token never travels bare: it is judged before the socket exists, it is
      wrapped before it is cast to a live socket (a mailbox is printed in a crash report), and a
      live socket's state, status and mailbox print without it;
    * a short string cut out of a large response or frame is copied, so an error tuple, a notice
      or a decoded record does not keep the whole document alive.

  Every credential here is an obvious fake and every request is answered in-process.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config

  alias DpExchange.Schwab.{
    Auth,
    Bound,
    Credentials,
    Feed,
    Rest,
    Socket,
    StreamerInfo
  }

  defmodule OpenLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  @canary "CANARY-STREAMER-TOKEN-ao"

  @info %StreamerInfo{
    socket_url: "wss://streamer.example.invalid/ws",
    customer_id: "cust-1",
    correl_id: "corr-1",
    channel: "IO",
    function_id: "APIAPP"
  }

  @creds %{access_token: "at-1"}

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  setup do
    Config.put_override(:rate_limit_module, OpenLimiter)
    :ok
  end

  describe "the refresh guard's :global name" do
    test "is a keyed digest: not the token, not a bare MD5 or SHA-256 of it" do
      test_pid = self()
      unique = System.unique_integer([:positive])
      token = "rt-ao-#{unique}"
      secret = "csec-ao-#{unique}"

      credentials = %{
        access_token: "at-1",
        refresh_token: token,
        client_id: "cid",
        client_secret: secret
      }

      plug = fn conn ->
        send(test_pid, {:names, :global.registered_names()})

        Req.Test.json(conn, %{
          "access_token" => "at-2",
          "refresh_token" => "rt-2",
          "expires_in" => 1_800
        })
      end

      assert {:ok, _renewed} = Auth.refresh(credentials, plug: plug, retry_attempts: 0)
      assert_receive {:names, names}, 5_000

      keyed = :crypto.mac(:hmac, :sha256, secret, token)
      mine = for {:schwab_refresh, digest, _scope} = name <- names, digest == keyed, do: name

      assert [{:schwab_refresh, digest, scope}] = mine
      assert byte_size(digest) == 32
      refute digest == :erlang.md5(token)
      refute digest == :crypto.hash(:sha256, token)
      refute inspect(mine, limit: :infinity) =~ token
      refute inspect(mine, limit: :infinity) =~ secret

      # Released when the request finished, however it ended.
      assert :global.whereis_name({:schwab_refresh, keyed, scope}) == :undefined
    end
  end

  describe "a Streamer token that cannot be sent as it is" do
    test "start_link refuses it by name before dialling, and never echoes it" do
      refusals = [
        {"CANARY\nSPLIT", {:error, {:invalid_credentials, :schwab}}},
        {"CANARY" <> <<0xFF, 0xFE>>, {:error, {:invalid_credentials, :schwab}}},
        {" CANARY ", {:error, {:invalid_credentials, :schwab}}},
        {"   ", {:error, {:missing_credentials, :schwab}}},
        {nil, {:error, {:missing_credentials, :schwab}}}
      ]

      for {token, expected} <- refusals do
        result = Socket.start_link(subscriber: self(), access_token: token, streamer_info: @info)

        assert result == expected
        refute inspect(result) =~ "CANARY"
      end
    end

    test "update_access_token/2 refuses it and sends nothing" do
      assert Socket.update_access_token(self(), "CANARY\nSPLIT") ==
               {:error, {:invalid_credentials, :schwab}}

      assert Socket.update_access_token(self(), "") == {:error, {:missing_credentials, :schwab}}

      assert Socket.update_access_token(self(), <<0xFF>>) ==
               {:error, {:invalid_credentials, :schwab}}

      refute_receive {:"$websockex_cast", _message}, 500
    end

    test "a cast carrying one leaves the token the next LOGIN presents as it was" do
      state = %{credentials: Credentials.wrap_token("old-token")}

      for bad <- ["bad\ntoken", "", <<0xFF>>, " padded "] do
        assert {:ok, ^state} = Socket.handle_cast({:update_access_token, bad}, state)

        assert {:ok, ^state} =
                 Socket.handle_cast({:update_access_token, Credentials.wrap_token(bad)}, state)
      end
    end

    test "a cast carrying a good token, wrapped or bare, replaces it" do
      state = %{credentials: Credentials.wrap_token("old-token")}
      wrapped = Credentials.wrap_token("fresh-1")

      assert {:ok, %{credentials: %Credentials{access_token: "fresh-1"}}} =
               Socket.handle_cast({:update_access_token, wrapped}, state)

      assert {:ok, %{credentials: %Credentials{access_token: "fresh-2"}}} =
               Socket.handle_cast({:update_access_token, "fresh-2"}, state)
    end
  end

  describe "the token cast to a live socket" do
    test "is wrapped, so a crash report printing the mailbox cannot print it" do
      assert Socket.update_access_token(self(), @canary) == :ok

      assert_receive {:"$websockex_cast", {:update_access_token, wrapped} = cast}, 5_000

      assert %Credentials{access_token: @canary} = wrapped
      refute inspect(cast, limit: :infinity) =~ @canary
    end
  end

  describe "a live process holding credentials" do
    test "a connected socket's state and mailbox print without its token or its rotation" do
      {listen_socket, port} = listen()
      serve(listen_socket, [&idle/1])

      {:ok, socket} = Socket.start_link(live_opts(port, @canary))
      on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)

      # The positive control: the state really does hold the token it must not print.
      assert :sys.get_state(socket).credentials.access_token == @canary
      refute printed(:sys.get_state(socket)) =~ @canary
      assert {:messages, messages} = Process.info(socket, :messages)
      refute printed(messages) =~ @canary

      rotated = "CANARY-ROTATED-ao"
      assert Socket.update_access_token(socket, rotated) == :ok

      assert :sys.get_state(socket).credentials.access_token == rotated
      refute printed(:sys.get_state(socket)) =~ rotated
    end

    test "a feed's status prints without the credentials it holds" do
      id = System.unique_integer([:positive])

      feed =
        start_supervised!(
          {Feed,
           name: :"ao_feed_#{id}",
           credentials: %{
             access_token: "CANARY-ACCESS",
             refresh_token: "CANARY-REFRESH",
             client_id: "CANARY-ID",
             client_secret: "CANARY-SECRET"
           }}
        )

      text = printed(:sys.get_status(feed))

      assert text =~ "DpExchange.Schwab.Credentials<"
      refute text =~ "CANARY"
    end
  end

  # A slice under 64 bytes is copied by the runtime itself on OTP 27+ (this package's floor is
  # OTP 28), so only a longer one can pin its document; every value below is 64 bytes or more,
  # or the test could not fail without the fix.
  @long_detail "symbol not found: " <> String.duplicate("d", 82)

  describe "a value cut out of a large document is copied" do
    test "Bound.text/1 does not keep the document it was sliced from" do
      document = String.duplicate("p", 1_000_000) <> @long_detail <> String.duplicate("p", 64)
      <<_head::binary-size(1_000_000), slice::binary-size(100), _tail::binary>> = document

      # The control: the slice does point into the megabyte.
      assert :binary.referenced_byte_size(slice) > 1_000_000

      bounded = Bound.text(slice)

      assert bounded == @long_detail
      assert :binary.referenced_byte_size(bounded) == byte_size(bounded)
    end

    test "a venue's error detail does not pin the response body" do
      body =
        Jason.encode!(%{
          "errors" => [%{"detail" => @long_detail}],
          "pad" => String.duplicate("p", 1_000_000)
        })

      plug = fn conn -> Plug.Conn.send_resp(conn, 400, body) end

      assert {:refused, {:venue_error, 400, detail}} =
               Rest.get_price("AAPL", @creds, plug: plug, retry_attempts: 0)

      assert detail == @long_detail
      assert :binary.referenced_byte_size(detail) == byte_size(detail)
    end

    test "a chain's contract text does not pin the chain body" do
      # Venue text whose length the package does not control, past the 64-byte copy threshold.
      long_type = String.duplicate("P", 80)

      contract = %{
        "symbol" => "AAPL  260320C00200000",
        "multiplier" => 100,
        "settlementType" => long_type,
        "expirationType" => long_type
      }

      body =
        Jason.encode!(%{
          "symbol" => "AAPL",
          "callExpDateMap" => %{"2026-03-20:15" => %{"200.0" => [contract]}},
          "putExpDateMap" => %{},
          "pad" => String.duplicate("p", 1_000_000)
        })

      plug = fn conn -> Plug.Conn.send_resp(conn, 200, body) end

      assert {:ok, chain} = Rest.get_option_chain("AAPL", @creds, plug: plug, retry_attempts: 0)

      call = chain.expiries |> Map.values() |> hd() |> Map.values() |> hd() |> Map.fetch!(:call)

      texts = [call.settlement_type, call.expiration_type]
      assert texts == [long_type, long_type]

      for text <- texts do
        assert :binary.referenced_byte_size(text) == byte_size(text)
      end
    end
  end

  defp printed(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp live_opts(port, token) do
    [
      url: "ws://127.0.0.1:#{port}/",
      # Test-only seam: this server is plain TCP. `Socket` refuses `ws://` without it.
      allow_insecure_socket: true,
      subscriber: self(),
      access_token: token,
      streamer_info: %{@info | socket_url: "ws://127.0.0.1:#{port}/"},
      socket_connect_timeout: 5_000,
      socket_recv_timeout: 5_000
    ]
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

  # Accepts the upgrade, then reads (and ignores) whatever the client sends until it closes.
  defp idle(socket) do
    upgrade(socket)
    read_until_closed(socket)
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
