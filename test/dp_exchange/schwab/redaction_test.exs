defmodule DpExchange.Schwab.RedactionTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Schwab.{Credentials, Feed, StreamerInfo}

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

  describe "StreamerInfo" do
    test "inspect hides the customer and correlation ids but keeps the rest" do
      info = %StreamerInfo{
        socket_url: "wss://streamer.example/ws",
        customer_id: "CANARY-CUSTOMER-ID",
        correl_id: "CANARY-CORREL-ID",
        channel: "IO",
        function_id: "APIAPP"
      }

      text = inspect(info)

      refute text =~ "CANARY-CUSTOMER-ID"
      refute text =~ "CANARY-CORREL-ID"
      assert text =~ "wss://streamer.example/ws"

      # Inside a plain state map, which is how a crash report prints it.
      refute inspect(%{info: info}) =~ "CANARY"
      # The LOGIN still reads the real values.
      assert info.customer_id == "CANARY-CUSTOMER-ID"
    end
  end

  @creds %{access_token: "a", refresh_token: "r", client_id: "c", client_secret: "s"}

  defp sending(body), do: fn conn -> Plug.Conn.send_resp(conn, 200, body) end

  describe "Auth.refresh/2 response size" do
    setup do
      DpExchange.Core.Config.put_override(:rate_limit_module, OpenLimiter)
      :ok
    end

    test "a token response over the default cap is refused, not held" do
      huge = String.duplicate("x", 1_048_576 + 1)

      assert {:error, {:exchange_error, :schwab, {:response_too_large, 1_048_576}}} =
               DpExchange.Schwab.Auth.refresh(@creds, plug: sending(huge), retry_attempts: 0)
    end

    test "the cap can be tightened by the caller" do
      assert {:error, {:exchange_error, :schwab, {:response_too_large, 64}}} =
               DpExchange.Schwab.Auth.refresh(@creds,
                 plug: sending(String.duplicate("x", 65)),
                 retry_attempts: 0,
                 max_body_bytes: 64
               )
    end
  end

  describe "Feed.update_credentials/2 call message" do
    test "reaches the feed wrapped, so a timeout or crash report cannot print the secrets" do
      test_pid = self()

      feed =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, message} ->
              send(test_pid, {:got, message})
              GenServer.reply(from, :ok)
          end
        end)

      raw = %{
        access_token: "CANARY-ACCESS",
        refresh_token: "CANARY-REFRESH",
        client_id: "CANARY-ID",
        client_secret: "CANARY-SECRET"
      }

      assert Feed.update_credentials(feed, raw) == :ok

      assert_receive {:got, {:update_credentials, %Credentials{} = sent}}, 5_000
      refute inspect(sent) =~ "CANARY"
      refute inspect({:update_credentials, sent}) =~ "CANARY"
      assert sent.access_token == "CANARY-ACCESS"
      assert sent.refresh_token == "CANARY-REFRESH"
    end
  end

  describe "Supervisor.start_link/1" do
    test "a raw credential map never sits in the supervisor's stored child specs" do
      id = System.unique_integer([:positive])

      opts = [
        name: :"redaction_sup_#{id}",
        feed: :"redaction_feed_#{id}",
        limiter: :"redaction_limiter_#{id}",
        order_limit: :"redaction_order_limit_#{id}",
        credentials: %{
          access_token: "CANARY-ACCESS",
          refresh_token: "CANARY-REFRESH",
          client_id: "CANARY-ID",
          client_secret: "CANARY-SECRET"
        }
      ]

      supervisor =
        start_supervised!(%{
          id: :redaction_sup,
          start: {DpExchange.Schwab.Supervisor, :start_link, [opts]},
          type: :supervisor
        })

      refute inspect(:sys.get_state(supervisor), limit: :infinity) =~ "CANARY"
    end
  end
end
