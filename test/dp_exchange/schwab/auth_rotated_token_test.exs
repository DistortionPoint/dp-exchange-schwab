defmodule DpExchange.Schwab.AuthRotatedTokenTest do
  @moduledoc """
  A rotated refresh token the next `refresh/2` would refuse is not stored.

  `put_rotated_refresh/2` accepted any non-empty binary, so `"   "`, `" rt "` and a token with
  a control character were persisted by a host as the replacement, and the next refresh
  answered `{:missing_credentials, :schwab}` ("nothing was sent") or `{:invalid_credentials,
  :schwab}` for a credential the venue had just issued. The access token was already judged by
  `Auth.check_token/1`; the refresh token now is too.
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

  defp responding(body) do
    fn conn -> Req.Test.json(conn, body) end
  end

  test "a blank, padded or control-character replacement is the missing-replacement error" do
    for bad <- ["   ", " rt-2", "rt-2 ", "rt\n2", "rt\t2"] do
      body = %{"access_token" => "at-2", "refresh_token" => bad, "expires_in" => 1_800}

      assert Auth.refresh(@creds, plug: responding(body)) ==
               {:error, :missing_rotated_refresh_token}
    end
  end

  test "a clean replacement is stored exactly as sent" do
    body = %{"access_token" => "at-2", "refresh_token" => "rt-2", "expires_in" => 1_800}

    assert {:ok, renewed} = Auth.refresh(@creds, plug: responding(body))
    assert renewed.refresh_token == "rt-2"
    assert renewed.access_token == "at-2"
  end

  test "an expires_in that is no usable claim leaves no :expires_at, and the old one is dropped" do
    stale = Map.put(@creds, :expires_at, ~U[2020-01-01 00:00:00Z])

    for expires_in <- [nil, 0, -5, 86_401, "1800", 1800.5] do
      body = %{"access_token" => "at-2", "refresh_token" => "rt-2", "expires_in" => expires_in}

      assert {:ok, renewed} = Auth.refresh(stale, plug: responding(body))
      refute Map.has_key?(renewed, :expires_at)
    end
  end

  test "a one-day expires_in is the largest claim kept, dated from :now" do
    now = ~U[2026-09-01 10:00:00Z]
    body = %{"access_token" => "at-2", "refresh_token" => "rt-2", "expires_in" => 86_400}

    assert {:ok, renewed} = Auth.refresh(@creds, plug: responding(body), now: now)
    assert renewed.expires_at == ~U[2026-09-02 10:00:00Z]
  end
end
