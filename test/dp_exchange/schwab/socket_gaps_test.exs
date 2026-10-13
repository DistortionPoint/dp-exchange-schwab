defmodule DpExchange.Schwab.SocketGapsTest do
  @moduledoc """
  The Streamer socket's bookkeeping and refusals that the main socket suite never takes:
  what a session holds after each kind of command, what a socket that is gone answers, and
  the frames and casts it ignores rather than crashes on.

  Driven through the `WebSockex` callbacks over a plain state map, as `SocketTest` is.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Schwab.{Credentials, Socket, StreamerInfo}

  @info %StreamerInfo{
    socket_url: "wss://streamer-api.schwab.com/ws",
    customer_id: "cust-1",
    correl_id: "corr-1",
    channel: "IO",
    function_id: "APIAPP"
  }

  defp logged_in_state do
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

  defp command(state, command, keys) do
    cast = {:subscribe, "LEVELONE_EQUITIES", command, keys, []}
    assert {:reply, {:text, _frame}, next} = Socket.handle_cast(cast, state)
    next
  end

  defp held(state), do: state.subscribed["LEVELONE_EQUITIES"]

  describe "what the session holds after each command" do
    test "ADD accumulates without duplicating, UNSUBS removes only what it names" do
      subscribed = command(logged_in_state(), "SUBS", ["AAPL"])
      assert held(subscribed) == ["AAPL"]

      added = command(subscribed, "ADD", ["MSFT", "AAPL"])
      assert held(added) == ["AAPL", "MSFT"]

      assert held(command(added, "UNSUBS", ["AAPL"])) == ["MSFT"]
    end

    test "VIEW changes which fields arrive, never which symbols are held" do
      subscribed = command(logged_in_state(), "SUBS", ["AAPL", "MSFT"])

      assert held(command(subscribed, "VIEW", ["AAPL"])) == ["AAPL", "MSFT"]
    end

    test "UNSUBS of the last held symbol forgets the service" do
      subscribed = command(logged_in_state(), "SUBS", ["AAPL"])

      assert command(subscribed, "UNSUBS", ["AAPL"]).subscribed == %{}
    end
  end

  describe "a socket that is gone" do
    test "a token pushed to it and a command sent to it both answer :send_timeout" do
      # `{:global, name}` naming nothing makes the cast exit, as a dead socket's would.
      gone = {:global, :schwab_socket_gaps_nobody_registered}

      assert Socket.update_access_token(gone, "token-xyz") == {:error, :send_timeout}

      assert Socket.subscribe_all(gone, [{"LEVELONE_EQUITIES", "SUBS", ["AAPL"]}]) ==
               {:error, :send_timeout}
    end
  end

  describe "input the socket ignores rather than crashes on" do
    test "a cast it does not know leaves the state alone" do
      state = logged_in_state()

      assert Socket.handle_cast(:something_else, state) == {:ok, state}
    end

    test "a frame that is not text leaves the state alone" do
      state = logged_in_state()

      assert Socket.handle_frame({:binary, <<1, 2, 3>>}, state) == {:ok, state}
    end

    test "a data entry that is not a service with a content list publishes nothing" do
      state = logged_in_state()
      data = %{"data" => ["junk", %{"service" => "LEVELONE_EQUITIES"}]}

      assert {:ok, next} = Socket.handle_frame({:text, Jason.encode!(data)}, state)
      assert next.subscribed == state.subscribed
      refute_received {:dp_exchange, :schwab, _payload}
    end

    test "a service with field names but no value type in this contract publishes nothing" do
      state = logged_in_state()

      data = %{
        "data" => [
          %{"service" => "ACCT_ACTIVITY", "command" => "SUBS", "content" => [%{"key" => "acct"}]}
        ]
      }

      assert {:ok, next} = Socket.handle_frame({:text, Jason.encode!(data)}, state)
      assert next.subscribed == state.subscribed
      refute_received {:dp_exchange, :schwab, _payload}
    end
  end

  describe "a re-login reported to a subscriber that is not a pid" do
    # It used to be pid-only: a registered name heard the `:link_up` notice but not this
    # message, and waited out the 60s re-assert.
    test "a registered name hears the notice AND the private re-login message" do
      name = :schwab_socket_gaps_subscriber
      Process.register(self(), name)

      login_ok =
        Jason.encode!(%{
          "response" => [
            %{"service" => "ADMIN", "command" => "LOGIN", "content" => %{"code" => 0}}
          ]
        })

      state = %{logged_in_state() | subscriber: name, logged_in?: false}

      assert {:ok, %{logged_in?: true}} = Socket.handle_frame({:text, login_ok}, state)

      assert_received {:dp_exchange, :schwab, %DpExchange.Core.Notice{kind: :link_up}}
      assert_received {:dp_exchange, :schwab, :relogged_in, _socket}
    end
  end

  describe "child specs" do
    test "child_spec/1 starts the socket through start_link/1 with the options it was given" do
      opts = [url: "wss://streamer-api.schwab.com/ws"]

      assert %{id: Socket, start: {Socket, :start_link, [^opts]}} = Socket.child_spec(opts)
    end

    test "child_spec/2 is the vendored two-argument form, starting start_link/2" do
      assert %{id: Socket, start: {Socket, :start_link, [:conn_info, :state]}} =
               Socket.child_spec(:conn_info, :state)
    end
  end
end
