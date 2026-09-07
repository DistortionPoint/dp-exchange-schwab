defmodule DpExchange.Schwab.CredentialsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DpExchange.Schwab.Credentials

  @access_token "LEAK_PROOF_ACCESS_TOKEN_abc123"
  @refresh_token "LEAK_PROOF_REFRESH_TOKEN_def456"
  @client_id "LEAK_PROOF_CLIENT_ID_ghi789"
  @client_secret "LEAK_PROOF_CLIENT_SECRET_jkl012"

  describe "wrap/1" do
    test "a raw credentials map is struct-ified" do
      wrapped =
        Credentials.wrap(%{
          access_token: @access_token,
          refresh_token: @refresh_token,
          client_id: @client_id,
          client_secret: @client_secret
        })

      assert %Credentials{
               access_token: @access_token,
               refresh_token: @refresh_token,
               client_id: @client_id,
               client_secret: @client_secret
             } = wrapped
    end

    test "already-wrapped credentials pass through unchanged" do
      wrapped = Credentials.wrap(%{access_token: @access_token})

      assert Credentials.wrap(wrapped) == wrapped
    end

    test "an unrelated extra key is ignored, matching Auth's own deliberately open " <>
           "credentials() type (`optional(any()) => any()`)" do
      wrapped = Credentials.wrap(%{access_token: @access_token, extra: "x"})

      assert wrapped.access_token == @access_token
    end

    test "an empty map wraps to a struct whose fields are all nil, matching " <>
           "access_token/1's catch-all refusal in feed.ex" do
      assert Credentials.wrap(%{}) == %Credentials{}
    end
  end

  describe "wrap_token/1" do
    test "wraps a bare access-token string, leaving every other field nil" do
      assert Credentials.wrap_token(@access_token) == %Credentials{access_token: @access_token}
    end
  end

  describe "Inspect redaction" do
    test "no secret field appears in the struct's own inspected output" do
      wrapped =
        Credentials.wrap(%{
          access_token: @access_token,
          refresh_token: @refresh_token,
          client_id: @client_id,
          client_secret: @client_secret
        })

      rendered = inspect(wrapped)

      refute rendered =~ @access_token
      refute rendered =~ @refresh_token
      refute rendered =~ @client_id
      refute rendered =~ @client_secret
      assert rendered =~ "DpExchange.Schwab.Credentials<expires_at: nil, ...>"
    end

    test "the secret stays redacted nested inside an ordinary map — the exact shape a " <>
           "GenServer's state takes" do
      state = %{credentials: Credentials.wrap(%{refresh_token: @refresh_token}), opts: []}

      refute inspect(state) =~ @refresh_token
    end
  end

  describe "crash-report proof" do
    # Mirrors the exact state-construction idiom `Feed.init/1` (feed.ex) and
    # `Socket.start_link/1` (socket.ex) use: credentials wrapped via `Credentials.wrap/1`
    # (or `wrap_token/1`) and stored as a top-level field of a GenServer's state. Before
    # this fix, the equivalent state shape — a PLAIN map, not this struct — printed the
    # refresh token and client secret in full on a crash of either process; this proves
    # the wrapping mechanism they now both rely on. `async: false`: a `CaptureLog`-content
    # assertion under `async: true` was already found non-concurrency-safe once in this
    # family.
    defmodule LeakyProbe do
      use GenServer

      @spec start_link(map()) :: GenServer.on_start()
      def start_link(credentials), do: GenServer.start_link(__MODULE__, credentials)

      @spec init(map()) :: {:ok, map()}
      def init(credentials) do
        {:ok, %{credentials: DpExchange.Schwab.Credentials.wrap(credentials), opts: []}}
      end

      @spec boom(pid()) :: any()
      def boom(pid), do: GenServer.call(pid, :boom)

      @spec handle_call(:boom, GenServer.from(), map()) :: no_return()
      def handle_call(:boom, _from, _state), do: raise("simulated crash for leak-proof test")
    end

    test "a crash of a process holding wrapped credentials never prints the secrets" do
      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          {:ok, pid} =
            LeakyProbe.start_link(%{
              access_token: @access_token,
              refresh_token: @refresh_token,
              client_id: @client_id,
              client_secret: @client_secret
            })

          ref = Process.monitor(pid)

          try do
            LeakyProbe.boom(pid)
          catch
            :exit, _reason -> :ok
          end

          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
        end)

      assert log =~ "simulated crash for leak-proof test"
      refute log =~ @access_token
      refute log =~ @refresh_token
      refute log =~ @client_id
      refute log =~ @client_secret
      assert log =~ "DpExchange.Schwab.Credentials<expires_at: nil, ...>"
    end
  end
end
