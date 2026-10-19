defmodule DpExchange.Schwab.TickAnCredentialsTest do
  @moduledoc """
  Tick AN: what the package does with a credential before and during a request.

  Two guards, both stateless on the credential itself:

    * an access token the credential says is expired is not sent (the venue's answer would be
      a `401` the package already knows, and on a write it would spend a throttled slot);
    * two refreshes of the same one-time refresh token cannot overlap on a node: the second is
      refused locally, because sending it can only be answered with a refusal that reads as a
      dead grant.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Schwab
  alias DpExchange.Schwab.{Auth, Fake, Rest}

  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @past ~U[2020-01-01 00:00:00Z]

  @refreshable %{
    access_token: "old-access",
    refresh_token: "old-refresh",
    client_id: "client",
    client_secret: "secret"
  }

  # A plug that proves nothing was sent: it raises if a request reaches it.
  defp exploding, do: fn _conn -> raise "a request was sent with an expired credential" end

  defp expired, do: %{access_token: "at-1", expires_at: @past}
  defp fresh, do: %{access_token: "at-1", expires_at: DateTime.add(DateTime.utc_now(), 600)}

  describe "Auth.check_unexpired/1" do
    test "an expires_at in the past is expired, one in the future is not" do
      now = DateTime.utc_now()

      assert Auth.check_unexpired(%{expires_at: DateTime.add(now, -1, :second)}) ==
               {:error, {:credentials_expired, :schwab}}

      assert Auth.check_unexpired(%{expires_at: @past}) ==
               {:error, {:credentials_expired, :schwab}}

      assert Auth.check_unexpired(%{expires_at: DateTime.add(now, 60, :second)}) == :ok
    end

    test "absent, nil or unreadable is not expired: the venue judges it" do
      unjudged = [%{}, nil, %{expires_at: nil}, %{expires_at: "soon"}, %{access_token: "a"}]

      for credentials <- unjudged do
        assert Auth.check_unexpired(credentials) == :ok
      end
    end

    test "a token inside the refresh margin is still sent; needs_refresh?/2 renews it" do
      soon = %{expires_at: DateTime.add(DateTime.utc_now(), 30)}

      assert Auth.check_unexpired(soon) == :ok
      assert Auth.needs_refresh?(soon)
    end
  end

  describe "an expired credential is refused before anything is sent" do
    test "every read" do
      refused = {:error, {:credentials_expired, :schwab}}

      assert Rest.get_price("AAPL", expired(), plug: exploding()) == refused
      assert Rest.get_accounts(expired(), plug: exploding()) == refused
      assert Schwab.get_price("AAPL", credentials: expired(), plug: exploding()) == refused
    end

    test "every write: place, replace, cancel and preview" do
      payload = %{"orderType" => "MARKET"}
      refused = {:error, {:credentials_expired, :schwab}}
      plug = exploding()

      assert Rest.place_order(expired(), "ABCDEF", payload, plug: plug) == refused
      assert Rest.replace_order(expired(), "ABCDEF", "123", payload, plug: plug) == refused
      assert Rest.cancel_order(expired(), "ABCDEF", "123", plug: plug) == refused
      assert Rest.preview_order(expired(), "ABCDEF", payload, plug: plug) == refused
    end

    test "a missing token is still the missing-credentials refusal, judged first" do
      assert Rest.get_price("AAPL", %{expires_at: @past}, plug: exploding()) ==
               {:error, {:missing_credentials, :schwab}}
    end

    test "an unexpired credential is signed and sent" do
      body = %{"AAPL" => %{"quote" => %{"lastPrice" => 101.5, "quoteTime" => 1_787_936_147_000}}}
      plug = fn conn -> Req.Test.json(conn, body) end

      assert {:ok, %{symbol: "AAPL"}} = Rest.get_price("AAPL", fresh(), plug: plug)
    end
  end

  describe "the fake refuses what the real path refuses" do
    test "an expired credential is credentials_expired from the fake too" do
      assert Fake.get_price("AAPL", credentials: expired()) ==
               {:error, {:credentials_expired, :schwab}}

      assert {:ok, %{symbol: "AAPL"}} = Fake.get_price("AAPL", credentials: fresh())
    end

    test "the fake's own refresh answers a credential the fake then serves" do
      assert {:ok, renewed} = Fake.refresh_credentials(@refreshable)
      assert DateTime.compare(renewed.expires_at, DateTime.utc_now()) == :gt
      assert {:ok, %{symbol: "AAPL"}} = Fake.get_price("AAPL", credentials: renewed)
    end
  end

  describe "refresh/2 - one refresh of a refresh token at a time on a node" do
    @refreshable %{
      access_token: "at-1",
      refresh_token: "rt-1",
      client_id: "cid",
      client_secret: "csec"
    }

    @renewal %{"access_token" => "at-2", "refresh_token" => "rt-2", "expires_in" => 1_800}

    defp refreshable do
      %{@refreshable | refresh_token: "rt-an-#{System.unique_integer([:positive])}"}
    end

    test "a second refresh of the same token while one is in flight is refused, unsent" do
      test_pid = self()
      credentials = refreshable()

      plug = fn conn ->
        send(test_pid, {:request_sent, self()})

        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end

        Req.Test.json(conn, @renewal)
      end

      winner = Task.async(fn -> Auth.refresh(credentials, plug: plug, retry_attempts: 0) end)
      assert_receive {:request_sent, in_flight}, 5_000

      assert Auth.refresh(credentials, plug: plug) == {:error, {:refresh_in_progress, :schwab}}

      assert Schwab.refresh_credentials(credentials, plug: plug) ==
               {:error, {:refresh_in_progress, :schwab}}

      # Neither loser sent anything: only the winner's request is ever seen.
      refute_receive {:request_sent, _other}, 500

      send(in_flight, :release)
      assert {:ok, %{access_token: "at-2", refresh_token: "rt-2"}} = Task.await(winner, 5_000)
    end

    test "the lock is released after a success and after a refusal" do
      credentials = refreshable()
      renewed = fn conn -> Req.Test.json(conn, @renewal) end

      assert {:ok, _first} = Auth.refresh(credentials, plug: renewed)
      assert {:ok, _second} = Auth.refresh(credentials, plug: renewed)

      refused = fn conn -> Req.Test.json(%{conn | status: 400}, %{"error" => "invalid_grant"}) end

      for _attempt <- 1..2 do
        assert {:refused, {:reauthorization_required, 400, "invalid_grant"}} =
                 Auth.refresh(credentials, plug: refused)
      end
    end

    test "the lock is released when the request raises in the caller" do
      credentials = refreshable()
      boom = fn _conn -> raise "plug failed" end

      for _attempt <- 1..2 do
        refute refresh_outcome(credentials, boom) == {:error, {:refresh_in_progress, :schwab}}
      end
    end

    # Whatever the refresh did, as a value: a raise is `:raised`, so the second attempt is
    # judged on whether the lock was left behind, not on how the first one ended.
    defp refresh_outcome(credentials, plug) do
      Auth.refresh(credentials, plug: plug)
    rescue
      _exception -> :raised
    end
  end
end
