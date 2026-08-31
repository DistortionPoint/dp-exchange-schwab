defmodule DpExchange.Schwab.AuthTest do
  @moduledoc """
  Signing, and the refresh that keeps signing possible.

  The tests worth reading are the ones about *which* failure it is. A refused refresh and
  a 5xx during refresh both stop the call, and a caller must do opposite things about
  them: one needs a person at a browser, the other needs a retry. A package that returned
  the same error for both would have a consumer retrying forever against a credential
  that can never succeed.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Schwab.Auth

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

  @creds %{
    access_token: "at-1",
    refresh_token: "rt-1",
    client_id: "cid",
    client_secret: "csec"
  }

  defp responding(body, status \\ 200) do
    fn conn -> Req.Test.json(%{conn | status: status}, body) end
  end

  describe "headers/2" do
    test "a token becomes a Bearer header" do
      assert {:ok, headers} = Auth.headers(@creds)
      assert {"Authorization", "Bearer at-1"} in headers
      assert {"Accept", "application/json"} in headers
    end

    test "a blank token is missing, not a header reading 'Bearer '" do
      # Sending it turns a local, nameable refusal into a remote 401 — and spends a
      # rate-limit slot to learn something already known.
      assert Auth.headers(%{access_token: "   "}) == {:error, {:missing_credentials, :schwab}}
      assert Auth.headers(%{access_token: ""}) == {:error, {:missing_credentials, :schwab}}
    end

    test "no credentials at all refuses before any request" do
      assert Auth.headers(nil) == {:error, {:missing_credentials, :schwab}}
      assert Auth.headers(%{}) == {:error, {:missing_credentials, :schwab}}

      assert Auth.headers(%{access_token: :not_a_string}) ==
               {:error, {:missing_credentials, :schwab}}
    end

    test "extra headers are appended" do
      assert {:ok, headers} = Auth.headers(@creds, extra_headers: [{"X-Trace", "abc"}])
      assert {"X-Trace", "abc"} in headers
    end
  end

  describe "needs_refresh?/2 — an unknown expiry is not an expired one" do
    test "true inside the margin, and when already expired" do
      now = ~U[2026-08-31 12:00:00Z]

      assert Auth.needs_refresh?(%{expires_at: DateTime.add(now, 60, :second)}, now)
      assert Auth.needs_refresh?(%{expires_at: DateTime.add(now, -600, :second)}, now)
    end

    test "false while there is real time left" do
      now = ~U[2026-08-31 12:00:00Z]

      refute Auth.needs_refresh?(%{expires_at: DateTime.add(now, 1_700, :second)}, now)
    end

    test "false when nobody said — silence is not expiry" do
      # Refreshing on every call because no expiry was supplied would hammer the token
      # endpoint and, if the refresh token rotates, churn the host's stored credential
      # for nothing. Such a host still gets refreshed, reactively, on a 401.
      refute Auth.needs_refresh?(@creds, ~U[2026-08-31 12:00:00Z])
      refute Auth.needs_refresh?(@creds)
    end

    test "the margin refreshes ahead of expiry rather than at it" do
      # A token that dies mid-flight produces a 401 the caller cannot tell from a revoked
      # grant, and the request has already gone out by then.
      assert Auth.refresh_margin_seconds() > 0
    end
  end

  describe "refresh/2 — the happy path" do
    test "returns a new access token and an expiry derived from the venue's own expires_in" do
      body = %{
        "access_token" => "at-2",
        "refresh_token" => "rt-1",
        "expires_in" => 1_800,
        "token_type" => "Bearer"
      }

      now = ~U[2026-08-31 12:00:00Z]

      assert {:ok, renewed} =
               Auth.refresh(@creds, plug: responding(body), retry_attempts: 0, now: now)

      assert renewed.access_token == "at-2"
      assert renewed.expires_at == ~U[2026-08-31 12:30:00Z]
    end

    test "every refresh mints a new refresh token, and it replaces the old one" do
      # The token sent is SPENT by this call. The one returned is its only replacement,
      # and carries a fresh seven days — which is why a host refreshing every half hour
      # never needs a person again, and why losing this value costs the grant.
      body = %{"access_token" => "at-2", "refresh_token" => "rt-2", "expires_in" => 1_800}

      assert {:ok, renewed} = Auth.refresh(@creds, plug: responding(body))

      assert renewed.refresh_token == "rt-2"
      refute renewed.refresh_token == @creds.refresh_token
    end

    test "a success with NO replacement token is a failure, not a credential to keep" do
      # The old token is already spent. Returning {:ok, creds} still holding it would
      # hand back something guaranteed to die at the NEXT refresh — days later, far from
      # the cause, and by then only a person at a browser can recover it.
      for body <- [
            %{"access_token" => "at-2", "expires_in" => 1_800},
            %{"access_token" => "at-2", "refresh_token" => ""},
            %{"access_token" => "at-2", "refresh_token" => nil}
          ] do
        assert Auth.refresh(@creds, plug: responding(body)) ==
                 {:error, :missing_rotated_refresh_token}
      end
    end

    test "a refresh is never retried, whatever the caller asks for" do
      # At-most-once. A retry after a timeout re-sends a token that may already have been
      # spent, and the replacement would sit in a response nobody read. `retry_attempts`
      # is dropped from the caller's options rather than defaulted, so this cannot be
      # switched back on by accident.
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        Plug.Conn.resp(conn, 500, "boom")
      end

      assert {:error, _reason} = Auth.refresh(@creds, plug: plug, retry_attempts: 5)
      assert :counters.get(counter, 1) == 1
    end

    test "a rotated refresh token replaces the old one" do
      # The documentation does not say whether Schwab rotates. Assuming it does not would
      # silently discard a rotation and strand the host at the NEXT refresh — failing
      # seven days later, far from the cause.
      body = %{"access_token" => "at-2", "refresh_token" => "rt-2", "expires_in" => 1_800}

      assert {:ok, renewed} = Auth.refresh(@creds, plug: responding(body), retry_attempts: 0)

      assert renewed.refresh_token == "rt-2"
    end

    test "the host's own bookkeeping survives the round trip" do
      creds = Map.put(@creds, :account_hash, "ABC123")
      body = %{"access_token" => "at-2", "refresh_token" => "rt-2", "expires_in" => 1_800}

      assert {:ok, renewed} = Auth.refresh(creds, plug: responding(body), retry_attempts: 0)

      assert renewed.account_hash == "ABC123"
    end

    test "no expires_in means no expiry claim, rather than an invented 1800" do
      body = %{"access_token" => "at-2", "refresh_token" => "rt-2"}

      assert {:ok, renewed} = Auth.refresh(@creds, plug: responding(body), retry_attempts: 0)

      refute Map.has_key?(renewed, :expires_at)
      refute Auth.needs_refresh?(renewed, DateTime.utc_now())
    end

    test "the renewed credential signs" do
      body = %{"access_token" => "at-2", "refresh_token" => "rt-2", "expires_in" => 1_800}

      assert {:ok, renewed} = Auth.refresh(@creds, plug: responding(body), retry_attempts: 0)
      assert {:ok, headers} = Auth.headers(renewed)
      assert {"Authorization", "Bearer at-2"} in headers
    end
  end

  describe "refresh/2 — the failures differ because the remedies differ" do
    test "a rejected refresh token is terminal and says so" do
      # Seven days are up, or the user reset their password. Only a person at a browser
      # can fix this, and a caller must not retry.
      body = %{"error" => "invalid_grant", "error_description" => "refresh token invalid"}

      assert {:refused, {:reauthorization_required, 400, detail}} =
               Auth.refresh(@creds, plug: responding(body, 400), retry_attempts: 0)

      assert detail == "refresh token invalid"
    end

    test "401 and 403 on refresh are also terminal" do
      for status <- [401, 403] do
        assert {:refused, {:reauthorization_required, ^status, _detail}} =
                 Auth.refresh(@creds, plug: responding(%{}, status), retry_attempts: 0)
      end
    end

    test "an unexpected 4xx is an error naming the status, not a reauthorization" do
      # Only 400, 401 and 403 mean the grant is finished. A 404 means the endpoint is
      # wrong, which is a deployment problem, and telling a host to send a person to a
      # login page for it would be a serious misdiagnosis. A 429 never reaches here at
      # all — Core intercepts venue rate limiting before this module sees it.
      assert {:error, {:exchange_error, :schwab, message}} =
               Auth.refresh(@creds, plug: responding(%{}, 404), retry_attempts: 0)

      assert message =~ "404"
    end

    test "a 5xx is retryable too, and arrives already classified by Core" do
      # `raw_status: true` only hands back 4xx — Core converts a server error before this
      # module sees it, deliberately, because a 5xx is not a venue's considered answer.
      assert {:error, {:exchange_error, :schwab, message}} =
               Auth.refresh(@creds, plug: responding(%{}, 503), retry_attempts: 0)

      assert message =~ "503"
    end

    test "a refusal with only an error code still carries it" do
      assert {:refused, {:reauthorization_required, 400, "invalid_grant"}} =
               Auth.refresh(@creds,
                 plug: responding(%{"error" => "invalid_grant"}, 400),
                 retry_attempts: 0
               )
    end

    test "a refusal whose body is not JSON still names the status" do
      plug = fn conn -> Plug.Conn.resp(conn, 401, "<html>gateway</html>") end

      assert {:refused, {:reauthorization_required, 401, nil}} =
               Auth.refresh(@creds, plug: plug, retry_attempts: 0)
    end

    test "a success with no access token is an unreadable response, not a silent pass" do
      assert {:error, :unexpected_response_shape} =
               Auth.refresh(@creds,
                 plug: responding(%{"token_type" => "Bearer"}),
                 retry_attempts: 0
               )
    end

    test "missing pieces refuse locally, and nothing is sent" do
      # A plug that would crash if called proves no request went out.
      exploding = fn _conn -> raise "a request was sent when it should not have been" end

      for incomplete <- [
            Map.delete(@creds, :refresh_token),
            Map.delete(@creds, :client_id),
            Map.delete(@creds, :client_secret),
            %{@creds | refresh_token: "  "},
            %{}
          ] do
        assert Auth.refresh(incomplete, plug: exploding) ==
                 {:error, {:missing_credentials, :schwab}}
      end

      # The single-arity head, which takes no options at all.
      assert Auth.refresh(%{}) == {:error, {:missing_credentials, :schwab}}
    end

    test "a non-JSON success body is an unreadable response" do
      plug = fn conn -> Plug.Conn.resp(conn, 200, "not json at all") end

      assert Auth.refresh(@creds, plug: plug, retry_attempts: 0) ==
               {:error, :unexpected_response_shape}
    end
  end

  describe "credential_failure?/1" do
    test "401 and 403 are the credential; everything else is the request" do
      assert Auth.credential_failure?(401)
      assert Auth.credential_failure?(403)
      refute Auth.credential_failure?(400)
      refute Auth.credential_failure?(429)
      refute Auth.credential_failure?(500)
    end
  end

  describe "token_url/1" do
    test "defaults to the venue's documented endpoint and is overridable" do
      assert Auth.token_url([]) == "https://api.schwabapi.com/v1/oauth/token"
      assert Auth.token_url(token_url: "http://localhost/token") == "http://localhost/token"
    end
  end
end
