defmodule DpExchange.Schwab.Auth do
  @moduledoc """
  Signing requests, and refreshing the token that signs them — internal.

  ## The line, and which side each half falls on

  §6.0: credential **storage** is host-side and never leaves; credential **use** —
  signing, session refresh, token rotation — is venue strategy and crosses into the
  package. Schwab splits cleanly along that line, and the split is not academic:

  **The host's half is the browser.** Schwab's initial grant is three-legged OAuth. It
  redirects a *person* to Schwab's login site, has them choose which accounts to share,
  and catches the redirect back. There is no headless path; something has to put a human
  in front of a login page. A library cannot do it and should not try.

  **This package's half is everything after.** An access token is valid for **30
  minutes**. That is the number that decides this module's existence: a package that only
  signed, and handed an expired token back to the caller twice an hour, would be unusable
  for anything unattended. Refresh is a machine-to-machine `POST` with no human in it,
  and it is exactly the "session refresh, token rotation" §6.0 places on this side.

  So: the host logs a person in once, and this package keeps that grant alive
  indefinitely — for as long as it is refreshed at least once a week.

  ## The refresh token is one-time use, and every refresh issues a new one

  This is the single most important fact about operating this venue, and getting it wrong
  is unrecoverable rather than inconvenient.

  | | Lifetime | Renewed by |
  |---|---|---|
  | `access_token` | 30 minutes | `refresh/2`, from the refresh token |
  | `refresh_token` | 7 days **from its own creation** | `refresh/2` — every call mints a new one, and the seven days restart with it |

  A refresh **spends** the token it was given. The old string is dead the moment the
  request succeeds, and the response's `refresh_token` is its replacement with a fresh
  seven days on it. So there is no weekly ceiling on unattended operation: a host
  refreshing every thirty minutes rolls the seven-day window forward every thirty minutes
  and never needs a person again. The clock only runs out if the package stops refreshing
  for a week.

  Three consequences, and the code enforces all three:

  **A success without a `refresh_token` is an error, not a token to keep.** The old one is
  already spent, so carrying it forward would hand the host a credential that is
  guaranteed to fail at the *next* refresh — days later, far from the cause, and by then
  unrecoverable without a person. `refresh/2` returns
  `{:error, :missing_rotated_refresh_token}` instead.

  **A refresh is never retried.** It is an at-most-once operation: if the request times
  out, the token may already have been spent server-side, and retrying with the same
  string will fail while the *real* new token sits in a response nobody read. Retries are
  forced off inside `refresh/2` and cannot be re-enabled through options — a transport
  failure is returned for the caller to handle with the credential it still holds.

  **The result must be persisted before it is used.** A host that refreshes and then
  crashes before storing the response has lost the account until a person logs in again.
  That is a real operational hazard rather than a style note, and it is why `refresh/2`
  returns the whole credential rather than mutating anything.

  Nothing is cached here. This module holds no state, writes nothing, and logs no token
  value; `refresh/2` returns the new credential to the caller, which owns storage.

  ## What ends a grant for good

  Only two things: seven days with no refresh, or the user resetting their Schwab
  password. Both return `{:refused, {:reauthorization_required, status, detail}}`, which
  names the remedy — a person, at a browser — rather than an error a caller would retry
  against a credential that can never succeed.
  """

  alias DpExchange.Core.HttpClient

  @token_url "https://api.schwabapi.com/v1/oauth/token"

  # Refresh this far before expiry rather than at it. A token that expires mid-flight
  # produces a 401 the caller cannot distinguish from a revoked grant, and the request
  # has already been sent by then.
  @refresh_margin_seconds 120

  @typedoc """
  What the host supplies.

  `:access_token` is what signs. `:refresh_token`, `:client_id` and `:client_secret` are
  what `refresh/2` needs; a credential without them can still sign, it just cannot renew
  itself. `:expires_at` is optional and lets `needs_refresh?/2` answer without a failed
  request first.
  """
  @type credentials :: %{
          optional(:access_token) => String.t(),
          optional(:refresh_token) => String.t(),
          optional(:client_id) => String.t(),
          optional(:client_secret) => String.t(),
          optional(:expires_at) => DateTime.t(),
          optional(any()) => any()
        }

  @doc """
  Headers for an authenticated request.

  `{:error, {:missing_credentials, :schwab}}` when there is no usable token, and no
  request is sent. There is no anonymous surface on this venue — market data included —
  so an unauthenticated request is not a degraded request, it is a guaranteed `401`.
  Sending it would spend a rate-limit slot to learn something already known.

  A blank token counts as missing: `Bearer ` is not a credential, and sending it turns a
  local, nameable refusal into a remote one.
  """
  @spec headers(credentials() | nil, keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def headers(credentials, opts \\ [])

  def headers(%{access_token: token}, opts) when is_binary(token) do
    case String.trim(token) do
      "" ->
        {:error, {:missing_credentials, :schwab}}

      trimmed ->
        {:ok,
         [
           {"Authorization", "Bearer " <> trimmed},
           {"Accept", "application/json"}
         ] ++ Keyword.get(opts, :extra_headers, [])}
    end
  end

  def headers(_no_token, _opts), do: {:error, {:missing_credentials, :schwab}}

  @doc """
  Whether `credentials` should be refreshed before the next call.

  `true` when the token expires within #{@refresh_margin_seconds} seconds, or has already
  expired. **`false` when `:expires_at` is absent** — an unknown expiry is not an
  expired one, and refreshing on every call because nobody said would burn the venue's
  token endpoint and, if the refresh token does rotate, churn the host's stored
  credential for no reason.

  A host that does not track expiry still gets refreshed correctly; it just happens
  reactively, when a `401` arrives, rather than ahead of it.
  """
  @spec needs_refresh?(credentials(), DateTime.t()) :: boolean()
  def needs_refresh?(credentials, now \\ DateTime.utc_now())

  def needs_refresh?(%{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    DateTime.diff(expires_at, now, :second) <= @refresh_margin_seconds
  end

  def needs_refresh?(_no_expiry, _now), do: false

  @doc "Seconds of margin `needs_refresh?/2` refreshes ahead of expiry."
  @spec refresh_margin_seconds() :: pos_integer()
  def refresh_margin_seconds, do: @refresh_margin_seconds

  @doc """
  Exchange a refresh token for a new access token.

  Returns `{:ok, credentials}` carrying **both** new tokens plus an `:expires_at` derived
  from the venue's own `expires_in`, merged over whatever the caller passed in so the
  host's own bookkeeping survives the round trip.

  **The caller must persist the result before using it.** The refresh token passed in has
  been spent by this call; the one returned is its only replacement. Losing it costs the
  grant, and recovering costs a person at a browser.

  Never retried — see the module doc. Failure modes are deliberately distinct, because
  the remedies are:

  - `{:error, {:missing_credentials, :schwab}}` — no refresh token, or no client
    credentials to authenticate the refresh with. Nothing was sent, and nothing is spent.
  - `{:refused, {:reauthorization_required, status, detail}}` — Schwab rejected the
    refresh token. **Terminal.** Seven days elapsed with no refresh, or the user reset
    their password. Only a person at a browser can fix it; a caller must not retry.
  - `{:error, :missing_rotated_refresh_token}` — Schwab accepted the refresh and returned
    an access token but no replacement refresh token. Treated as a failure rather than a
    success, because the old token is already spent and reporting success would hand back
    a credential guaranteed to die at the next refresh.
  - `{:error, {:exchange_error, :schwab, message}}` — a 5xx, or a 4xx that is not a
    rejection of the credential. The grant is probably intact; the caller may try again
    with the credential it still holds.
  """
  @spec refresh(credentials(), keyword()) ::
          {:ok, credentials()} | {:error, term()} | {:refused, term()}
  def refresh(credentials, opts \\ [])

  def refresh(
        %{refresh_token: refresh_token, client_id: client_id, client_secret: client_secret} =
          credentials,
        opts
      )
      when is_binary(refresh_token) and is_binary(client_id) and is_binary(client_secret) do
    if String.trim(refresh_token) == "" or String.trim(client_id) == "" do
      {:error, {:missing_credentials, :schwab}}
    else
      do_refresh(credentials, refresh_token, client_id, client_secret, opts)
    end
  end

  def refresh(_incomplete, _opts), do: {:error, {:missing_credentials, :schwab}}

  defp do_refresh(credentials, refresh_token, client_id, client_secret, opts) do
    # Basic auth over the client pair, per the venue's documented example. This is the
    # one place a client secret is used, and it goes into a header on a single request —
    # never stored, never logged.
    basic = Base.encode64(client_id <> ":" <> client_secret)

    headers = [
      {"Authorization", "Basic " <> basic},
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Accept", "application/json"}
    ]

    body = URI.encode_query(%{"grant_type" => "refresh_token", "refresh_token" => refresh_token})

    case HttpClient.request(:post, token_url(opts), headers, body, request_opts(opts)) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        merge_tokens(credentials, decode(response), opts)

      {:ok, %{status: status, body: response}} when status in [400, 401, 403] ->
        {:refused, {:reauthorization_required, status, detail(decode(response))}}

      {:ok, %{status: status, body: response}} ->
        {:error, {:exchange_error, :schwab, "HTTP #{status}: #{inspect(response)}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The venue's own `expires_in` is used rather than a constant of ours. The
  # documentation says 1800 seconds; if that ever changes, the response is right and a
  # hardcoded 30 minutes would be silently wrong in the direction that fails.
  defp merge_tokens(credentials, %{"access_token" => access} = response, opts)
       when is_binary(access) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    renewed =
      %{access_token: access}
      |> put_expiry(response["expires_in"], now)
      |> put_rotated_refresh(response["refresh_token"])

    with {:ok, renewed} <- renewed, do: {:ok, Map.merge(credentials, renewed)}
  end

  defp merge_tokens(_credentials, _response, _opts), do: {:error, :unexpected_response_shape}

  defp put_expiry(renewed, seconds, now) when is_integer(seconds) and seconds > 0,
    do: Map.put(renewed, :expires_at, DateTime.add(now, seconds, :second))

  # No `expires_in` means no expiry claim. `needs_refresh?/2` treats an absent expiry as
  # "cannot tell", which falls back to refreshing on a 401 — correct, and better than
  # inventing 1800 seconds the venue did not state on this response.
  defp put_expiry(renewed, _absent, _now), do: renewed

  # The rotated token is mandatory, not opportunistic. See the module doc: the token this
  # request was made with is spent, so a response without a replacement leaves the host
  # holding a dead string it would not discover until the next refresh.
  defp put_rotated_refresh(renewed, token) when is_binary(token) and token != "",
    do: {:ok, Map.put(renewed, :refresh_token, token)}

  defp put_rotated_refresh(_renewed, _absent), do: {:error, :missing_rotated_refresh_token}

  @doc """
  Whether a status means the credential is finished rather than the request.

  `401` and `403` are not retryable with the same token. The caller's move is to
  `refresh/2` and try once more; if the refresh itself is refused, a person must log in.
  """
  @spec credential_failure?(pos_integer()) :: boolean()
  def credential_failure?(status), do: status in [401, 403]

  @doc "Token endpoint, overridable for tests."
  @spec token_url(keyword()) :: String.t()
  def token_url(opts), do: Keyword.get(opts, :token_url, @token_url)

  defp request_opts(opts) do
    opts
    |> Keyword.take([:limiter, :timeout, :log_requests, :plug, :req_adapter])
    |> Keyword.merge(provider: :schwab, raw_status: true, retry_attempts: 0)

    # `:retry_attempts` is dropped from the caller's options above and forced to 0 here,
    # deliberately and not as a default. A refresh is at-most-once: a retry after a
    # timeout re-sends a token that may already have been spent, and the replacement
    # token would then be sitting in a response nobody read — losing the grant entirely.
    # A caller that wants to try again does so with the credential it still holds.
  end

  defp detail(%{"error_description" => description}) when is_binary(description), do: description
  defp detail(%{"error" => error}) when is_binary(error), do: error
  defp detail(_other), do: nil

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{}
    end
  end

  defp decode(body) when is_map(body), do: body
  defp decode(_other), do: %{}
end
