defmodule DpExchange.Schwab.SecretHygieneTest do
  @moduledoc """
  Tick Z security audit: a credential never rides an error, and never goes on a clear channel.

  Every value here is an obvious fake. None of these tests opens a connection: each refusal
  asserted is decided before the request or the socket is built.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Schwab.{Auth, Rest, Socket, StreamerInfo}

  @fake_token "test-secret-not-real"

  @credentials %{
    access_token: @fake_token,
    refresh_token: "test-refresh-not-real",
    client_id: "test-client-not-real",
    client_secret: "test-client-secret-not-real"
  }

  describe "Auth.check_token/1 refuses a value that cannot travel as sent" do
    test "an interior newline is refused, and the value is not echoed" do
      token = "test-secret\nnot-real"

      assert Auth.check_token(token) == {:error, {:invalid_credentials, :schwab}}
      assert Auth.headers(%{access_token: token}) == {:error, {:invalid_credentials, :schwab}}
    end

    test "a token that is not valid UTF-8 is refused" do
      token = "test-secret-" <> <<0xFF, 0xFE>>

      assert Auth.check_token(token) == {:error, {:invalid_credentials, :schwab}}
    end

    test "an interior space is still a value; only control bytes and bad UTF-8 are refused" do
      assert Auth.check_token("test secret") == {:ok, "test secret"}
    end

    test "refresh refuses a refresh token with a control byte and sends nothing" do
      credentials = %{@credentials | refresh_token: "test-refresh\r\nnot-real"}

      assert Auth.refresh(credentials, []) == {:error, {:invalid_credentials, :schwab}}
    end
  end

  describe "a credential is not sent to a non-https override" do
    test "refresh refuses an http token_url before anything is sent" do
      assert Auth.refresh(@credentials, token_url: "http://token.example.invalid/token") ==
               {:error, {:insecure_url, :schwab}}
    end

    test "a read refuses an http trader_url" do
      assert Rest.get_accounts(@credentials, trader_url: "http://trader.example.invalid") ==
               {:error, {:insecure_url, :schwab}}
    end

    test "a read refuses an http market_data_url" do
      assert Rest.get_price("AAPL", @credentials, market_data_url: "http://md.example.invalid") ==
               {:error, {:insecure_url, :schwab}}
    end

    test "an order write refuses an http trader_url as a plain error, not an unconfirmed order" do
      opts = [trader_url: "http://trader.example.invalid"]

      assert Rest.place_order(@credentials, "hash-1", %{}, opts) ==
               {:error, {:insecure_url, :schwab}}

      assert Rest.replace_order(@credentials, "hash-1", "1", %{}, opts) ==
               {:error, {:insecure_url, :schwab}}

      assert Rest.cancel_order(@credentials, "hash-1", "1", opts) ==
               {:error, {:insecure_url, :schwab}}
    end

    test "https is accepted, and so is an in-process plug seam on any URL" do
      assert Auth.check_secure_url("https://api.example.invalid", []) == :ok
      assert Auth.check_secure_url("HTTPS://api.example.invalid", []) == :ok
      assert Auth.check_secure_url("http://x", plug: fn conn -> conn end) == :ok
      assert Auth.check_secure_url("http://x", []) == {:error, {:insecure_url, :schwab}}
      assert Auth.check_secure_url(nil, []) == {:error, {:insecure_url, :schwab}}
    end
  end

  defp socket_opts(url) do
    [
      subscriber: self(),
      access_token: @fake_token,
      streamer_info: %StreamerInfo{
        socket_url: url,
        customer_id: "cust-1",
        correl_id: "corr-1",
        channel: "IO",
        function_id: "APIAPP"
      }
    ]
  end

  describe "Socket.start_link/1" do
    test "refuses a ws:// URL from the venue, so the LOGIN token never goes in clear" do
      assert Socket.start_link(socket_opts("ws://streamer.example.invalid/ws")) ==
               {:error, {:insecure_url, :schwab}}
    end

    test "refuses a ws:// :url override too" do
      opts = [url: "ws://streamer.example.invalid/ws"] ++ socket_opts("wss://x.example.invalid")

      assert Socket.start_link(opts) == {:error, {:insecure_url, :schwab}}
    end

    test "a missing option raises without printing the access token" do
      opts = Keyword.delete(socket_opts("wss://x.example.invalid"), :subscriber)

      error = assert_raise ArgumentError, fn -> Socket.start_link(opts) end

      assert error.message =~ ":subscriber"
      refute error.message =~ @fake_token
    end
  end
end
