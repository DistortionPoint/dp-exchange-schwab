defmodule DpExchange.Schwab do
  @moduledoc """
  Charles Schwab's Trader API, behind the family's shared facade.

  **EXPERIMENTAL.** Nothing here has run in production, and on this venue that is
  structural rather than temporary: every endpoint needs OAuth credentials this repository
  must never hold, and **Schwab publishes no sandbox** — its own documentation says Trader
  API sandboxes "will be available later this year", and neither specification declares a
  non-production server. There is nowhere to exercise this package that is not somebody's
  real money, so maturity is `:experimental` throughout and moves only when a consumer
  trades live (D15).

  ## What is different about this venue

  Five things, and each shows up in the contract rather than being smoothed over:

  **A symbol is one instrument, not a pair.** Every other venue in the family addresses
  `BASE-QUOTE`. Here `AAPL` names a single security and what you pay with is USD because
  the venue is a US broker. `SymbolFormat.validate/1` therefore *refuses* pair-shaped input
  instead of splitting it — `BTC`, `ETH` and `SOL` are all real listed equity tickers, so a
  misrouted crypto pair has a plausible wrong answer waiting for it.

  **The market closes.** `market_status/1` is answered from `/markets`, not assumed. A feed
  delivering nothing at 3am is correct, and a consumer that alarms on silence would alarm
  every night — making a real outage indistinguishable from a Saturday.

  **The host authenticates; this package signs and refreshes.** The initial grant is
  three-legged OAuth through a browser and a person, which no library can do. Everything
  after is mechanical: the access token lives 30 minutes and `Auth.refresh/2` renews it,
  minting a new refresh token each time with a fresh seven days. A host that keeps
  refreshing never needs a person again.

  **`get_order_book/2` is `:unsupported`, and the reason has now changed three times.** It
  first read "there is no order book and no socket" — a claim about the venue, and wrong.
  The venue has both. It then read that the Streamer's depth services were not implemented
  here, and for one release it read that they were, because `NYSE_BOOK`, `NASDAQ_BOOK` and
  `OPTIONS_BOOK` had real, tested decoders in `StreamerDecode` — which was also wrong, in
  the opposite direction: nothing in `Feed` ever *subscribed* any of the three, so
  `capabilities().streamable` named `:order_book` for a symbol that could never actually
  deliver one. A documentation-accuracy sweep (2026-09-06) found that gap and narrowed
  `streamable` back to what `Feed` genuinely asks the venue for.

  What is true now, and is the only thing this value says: **the REST API publishes no
  depth**, so there is nothing for a *pull* call to return — and depth does not arrive by
  subscription either, because doing so honestly needs a fact this package does not have
  (which of `NYSE_BOOK`/`NASDAQ_BOOK` an equity symbol belongs on; the vendor names no
  rule). `Candles` do arrive by subscription now — `CHART_EQUITY` reaches the same symbols
  `LEVELONE_EQUITIES` does — so a caller wanting them calls `subscribe/2` and reads
  `coverage/1`, the same way `get_order_book/2`'s moduledoc once promised for depth and
  could not yet deliver.

  That is four different reasons behind one unchanged `:unsupported`, which is the argument
  for writing the reason down rather than the value alone — three of the four were wrong
  (one of them by over-correcting), and the value never moved to show it.

  **The catalogue cannot be enumerated.** `/instruments` has no list-everything projection
  — all six of its projections search against a term — so `get_symbols/1` requires a
  `:query` and returns `{:error, {:query_required, :schwab}}` without one. That is
  deliberately **not** `:not_supported`: the endpoint works, and a caller must be able to
  tell "needs a term" from "has no endpoint". Returning some arbitrary search instead would
  hand back a short list that looks like a catalogue.

  ## Credentials

  Passed per call, never read from a vault and never cached here (§6.0, invariant #2):

      credentials = %{
        access_token: "…",
        refresh_token: "…",
        client_id: "…",
        client_secret: "…"
      }

  Only `:access_token` is needed to sign. The rest are needed to refresh, and **the result
  of a refresh must be persisted by the host** — the refresh token is one-time use, so the
  one returned is the only way to refresh again.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.Venue
  alias DpExchange.Schwab.{Auth, Capabilities, Feed, OrderLimit, Orders, Rest, Supervisor}

  # --- identity -----------------------------------------------------------

  @impl true
  def provider_name, do: "Schwab"

  @impl true
  def runtime_id, do: :schwab

  @impl true
  def asset_classes, do: [:equity]

  @impl true
  def capabilities, do: Capabilities.declaration()

  @doc "Endpoints the venue does not serve, as distinct from ones not yet written."
  @spec venue_does_not_serve() :: [{atom(), arity()}]
  defdelegate venue_does_not_serve, to: Capabilities

  @doc "The quote currencies this venue settles in."
  @spec quotes() :: [String.t()]
  def quotes, do: ["USD"]

  # --- lifecycle ----------------------------------------------------------

  @impl true
  def child_spec(opts) do
    # Credentials are wrapped HERE, and not in `start_link/1` or `init/1` — that
    # distinction IS the fix. A supervisor stores the `{module, :start_link, [opts]}` MFA
    # it was handed, and OTP writes that argument list through `inspect/1` into the
    # `Start Call:` line of the report it logs on ANY child termination. Wrapping any later
    # does nothing: the raw list has already been captured by the supervisor above.
    # dp-exchange-core issue #29 — live API keys, in cleartext, in ordinary application
    # logs, produced by any crash at all.
    opts = DpExchange.Schwab.Credentials.wrap_opt(opts)

    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def start_link(opts), do: Supervisor.start_link(opts)

  # --- market data --------------------------------------------------------

  @impl true
  def get_price(symbol, opts \\ []) do
    with {:ok, credentials} <- credentials(opts) do
      Rest.get_price(symbol, credentials, with_limiter(opts))
    end
  end

  @impl true
  def get_top_of_book(symbol, opts \\ []) do
    with {:ok, credentials} <- credentials(opts) do
      Rest.get_top_of_book(symbol, credentials, with_limiter(opts))
    end
  end

  @impl true
  def get_historical_prices(symbol, timeframe, range, opts \\ []) do
    with {:ok, credentials} <- credentials(opts) do
      Rest.get_historical_prices(symbol, timeframe, range, credentials, with_limiter(opts))
    end
  end

  @doc """
  **A pull here requires a query**, and that is the venue's shape rather than a gap.

  `GET /instruments` has no "list everything" projection — every lookup is a search
  against a term — so the catalogue cannot be enumerated at all, only queried. Pass
  `:query`; without one this returns `{:error, {:query_required, :schwab}}`, which is
  deliberately not `:not_supported`. Returning some arbitrary search instead would hand
  back a short list that looks like a catalogue.
  """
  @impl true
  def get_symbols(opts \\ []) do
    with {:ok, credentials} <- credentials(opts) do
      Rest.get_symbols(credentials, with_limiter(opts))
    end
  end

  @impl true
  def preview_replace(_credentials, _id, _changes, _opts \\ []), do: Venue.not_supported()

  @impl true
  def close_position(_credentials, _symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def cancel_all_orders(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_order_book(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_trades(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_auction_imbalance(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_volume_profile(_symbol, _timeframe, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_market_overview(_opts \\ []), do: Venue.not_supported()

  @impl true
  def list_instruments(_opts \\ []), do: Venue.not_supported()

  @impl true
  def market_status(opts \\ []) do
    with {:ok, credentials} <- credentials(opts) do
      Rest.market_status(credentials, with_limiter(opts))
    end
  end

  @impl true
  def quantization(_symbol), do: Venue.not_supported()

  # --- accounts and trading -----------------------------------------------

  @impl true
  def get_accounts(credentials, opts \\ []),
    do: Rest.get_accounts(credentials, with_limiter(opts))

  @doc """
  Balances for one account.

  Requires `:account_hash` — Schwab addresses accounts by an encrypted hash, and
  `get_accounts/2` is the only place to get one. That makes it a prerequisite for the
  whole trading surface rather than a convenience.
  """
  @impl true
  def get_balances(credentials, opts \\ []) do
    with {:ok, hash} <- account_hash(opts) do
      Rest.get_balances(credentials, hash, with_limiter(opts))
    end
  end

  @doc """
  **Not supported.** Schwab publishes no fee-schedule endpoint. `previewOrder` returns an
  estimated commission for *one order*, which the contract cannot express and which is not
  a fee schedule.
  """
  @impl true
  def get_fees(_credentials, _opts \\ []), do: Venue.not_supported()

  @doc "**Not supported.** Money movement is not part of the Trader API."
  @impl true
  def get_transfers(_credentials, _opts \\ []), do: Venue.not_supported()

  @doc """
  Place an order.

  `{:error, :order_limit_not_declared}` when this tree was supervised without
  `:order_limit_per_minute` — see `Supervisor`'s moduledoc and `OrderLimit`. That is
  distinct from a real ceiling of `0`, which reaches the limiter and is throttled for
  real, and distinct from a consumer that never supervises this module at all, which gets
  no opinion from this check. Checked before `Orders.build/2`, so an undeclared ceiling is
  never masked by, or confused with, a separate refusal about the order's own shape.
  """
  @impl true
  def place_order(credentials, request, opts \\ []) do
    with {:ok, hash} <- account_hash(opts),
         :ok <- ensure_order_limit_declared(opts),
         {:ok, payload} <- Orders.build(request, opts) do
      Rest.place_order(credentials, hash, payload, with_limiter(opts))
    end
  end

  @doc """
  **Not supported.** Schwab places one order per request.

  `POST /accounts/{accountNumber}/orders` takes one order; the Accounts and Trading
  specification publishes no batch. Its multi-leg orders are one *order* with several legs,
  which is a different thing — the venue accepts or rejects it as one, and it is placed
  through `place_order/3` with `:legs`.
  """
  @impl true
  def place_orders(_credentials, _requests, _opts), do: Venue.not_supported()

  @doc """
  Validate an order **without placing it**.

  The only endpoint in the family that checks an order against the venue's own rules
  before committing, and it earns its keep here specifically: order writes are throttled
  on this venue and reads are not, so a rejection found by previewing costs nothing while
  one found by placing costs a scarce write.

  Builds the same payload `place_order/3` would, so a preview that passes describes the
  order that would actually be sent.
  """
  @impl true
  def preview_order(credentials, request, opts \\ []) do
    with {:ok, hash} <- account_hash(opts),
         {:ok, payload} <- Orders.build(request, opts) do
      Rest.preview_order(credentials, hash, payload, with_limiter(opts))
    end
  end

  @doc """
  Replace an open order **atomically**.

  Schwab amends in one call. Every other venue in the family cancels and re-places, and
  those are **not equivalent here**: cancel-then-place opens a window in which no order is
  live, and it spends two throttled writes rather than one.

  Returns the **new** order id. Schwab treats a replacement as a new order, so the old id
  is dead afterwards and a caller still holding it would be tracking something that no
  longer exists.

  `{:error, :order_limit_not_declared}` under the same conditions as `place_order/3` — a
  replacement is a `PUT` order write, the same throttled category as a placement.
  """
  @impl true
  def replace_order(credentials, order_id, request, opts \\ []) do
    with {:ok, hash} <- account_hash(opts),
         :ok <- ensure_order_limit_declared(opts),
         {:ok, payload} <- Orders.build(request, opts) do
      Rest.replace_order(credentials, hash, order_id, payload, with_limiter(opts))
    end
  end

  @doc """
  Cancel an open order.

  `{:error, :order_limit_not_declared}` under the same conditions as `place_order/3` — a
  cancel is a `DELETE` order write, the same throttled category as a placement.
  """
  @impl true
  def cancel_order(credentials, order_id, opts \\ []) do
    with {:ok, hash} <- account_hash(opts),
         :ok <- ensure_order_limit_declared(opts) do
      Rest.cancel_order(credentials, hash, order_id, with_limiter(opts))
    end
  end

  @impl true
  def get_order(credentials, order_id, opts \\ []) do
    with {:ok, hash} <- account_hash(opts) do
      Rest.get_order(credentials, hash, order_id, with_limiter(opts))
    end
  end

  @impl true
  def get_orders(credentials, opts \\ []) do
    with {:ok, hash} <- account_hash(opts) do
      Rest.get_orders(credentials, hash, with_limiter(opts))
    end
  end

  @doc """
  **Not supported yet.** `/transactions` carries fills, but mapping a Schwab transaction
  onto `Core.Types.Fill` needs a live response to check against and this repository holds
  no credential. Declared `:experimental` and returning `:not_supported` would be a
  declaration disagreeing with itself, so it is neither — see `capabilities/0`.
  """
  @impl true
  def get_trade_history(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def test_connection(credentials, opts \\ []) do
    with {:ok, accounts} <- Rest.get_accounts(credentials, with_limiter(opts)) do
      {:ok, %{accounts: length(accounts)}}
    end
  end

  @doc """
  **Not supported.** Schwab publishes no rate-limit status endpoint, and its documented
  order ceiling is a property of the *application's registration* rather than something
  queryable at runtime.
  """
  @impl true
  def get_rate_limit_status(_credentials, _opts \\ []), do: Venue.not_supported()

  @doc """
  Exchanges the refresh token in `credentials` for a new access token. **Credential use,
  not consent** — see the moduledoc's `## Credentials` section.

  Venue-specific, like Gemini's `refresh_access_token/3` — not part of `Core.Venue`,
  because refresh is a mechanism this contract has no callback for.

  Delegates to `DpExchange.Schwab.Auth.refresh/2` — see there for the full accounting of
  every returned shape, and why `Auth`'s own moduledoc calls this "the single most
  important operational fact" about this venue. In short:

  - **The caller must persist the result before using it.** The refresh token `credentials`
    carried is already spent by this call; the response's is its only replacement.
  - **`{:refused, {:reauthorization_required, status, detail}}` is terminal.** Only a person
    at a browser can fix it — do not retry.
  - Never retried by this call itself, and cannot be made to retry through `opts`.

  This was previously reachable only by calling `Auth.refresh/2` directly, which meant
  reaching past the facade — the exact thing this package's own `CLAUDE.md` says is a gap
  in the facade to fix, not a workaround to document. `usage-rules.md` pointed a consumer
  at the internal module by name; it now points here.

  A refreshed credential reaches a *running* feed through `update_credentials/2`, not
  through this function — refreshing and reconnecting are separate concerns, and a caller
  that only wants a fresh token for account or trading calls should not have to touch a
  feed to get one.
  """
  @spec refresh_credentials(Auth.credentials(), keyword()) ::
          {:ok, Auth.credentials()} | {:error, term()} | {:refused, term()}
  def refresh_credentials(credentials, opts \\ []),
    do: Auth.refresh(credentials, with_limiter(opts))

  @doc """
  Whether `credentials` should be refreshed before the next call.

  **The other half of `refresh_credentials/2`.** That function renews a credential; this
  one answers *when* to call it — `true` once the access token is close enough to
  expiring (a margin ahead of the venue's own 30-minute lifetime, so a request in flight
  does not expire mid-air), or has already expired, and deliberately `false` when
  `credentials` carries no `:expires_at` at all, because an unknown expiry is not an
  expired one.

  **This decision stays with the host on purpose.** `Auth` holds no state and starts no
  timer (§6.0, and see its moduledoc) — nothing inside this package could answer "is it
  time yet" without either polling on a schedule nobody asked for or caching a credential
  this package is built never to hold. A host that already has `credentials` in hand —
  because it is about to make a call, or because it runs its own schedule — calls this
  first. A host that does not track expiry at all still gets refreshed correctly; see
  `usage-rules.md` §3.

  Delegates to `DpExchange.Schwab.Auth.needs_refresh?/2`, previously reachable only by
  going past the facade to that internal module.
  """
  @spec needs_refresh?(Auth.credentials(), DateTime.t()) :: boolean()
  defdelegate needs_refresh?(credentials, now \\ DateTime.utc_now()), to: Auth

  @doc """
  Whether an HTTP status from this venue means the credential is finished, not just the
  request.

  Every `get_*`/`place_*`/`cancel_*` call above that reaches the venue returns
  `{:refused, {:venue_error, status, detail}}` on a `4xx`. `status in [401, 403]` means
  the access token itself is the problem — the caller's move is `refresh_credentials/2`
  and one retry; any other `4xx` is about the request and retrying it with a fresh token
  would not help.

  Delegates to `DpExchange.Schwab.Auth.credential_failure?/1`, previously reachable only
  by going past the facade to that internal module.
  """
  @spec credential_failure?(pos_integer()) :: boolean()
  defdelegate credential_failure?(status), to: Auth

  # --- streaming: the Streamer, or a poll when it cannot bootstrap --------

  @doc """
  Adds `symbols` to the feed's set. `opts[:to]` receives them; the caller by default.

  **The set this adds to is what was asked for, not what has arrived.** An earlier version
  read the current set out of `coverage/1` and re-sent the union, which silently dropped
  every symbol that had been subscribed and not yet quoted — a real loss dressed as an
  idempotent update.
  """
  @impl true
  def subscribe(symbols, opts \\ []) do
    feed = feed(opts)

    if alive?(feed) do
      Feed.subscribe(feed, symbols, opts)
    else
      {:error, :feed_not_started}
    end
  end

  @impl true
  def unsubscribe(symbols, opts \\ []) do
    feed = feed(opts)
    if alive?(feed), do: Feed.unsubscribe(feed, symbols), else: :ok
  end

  @impl true
  def update_symbols(symbols, opts \\ []) do
    feed = feed(opts)
    if alive?(feed), do: Feed.update_symbols(feed, symbols), else: {:error, :feed_not_started}
  end

  @impl true
  def coverage(opts \\ []) do
    feed = feed(opts)
    if alive?(feed), do: Feed.coverage(feed), else: %{}
  end

  @doc """
  What has been asked for, which is not what `coverage/1` reports.

  **The other half of the observed-versus-intended split `coverage/1` is built around.**
  `coverage/1` answers "what has actually arrived"; this answers "what was asked for" —
  and the two are not the same set the moment a symbol is subscribed and has not yet
  delivered. A caller comparing this against `coverage/1` can tell "not yet arrived" from
  "never asked for," which `coverage/1` alone cannot: an absent symbol reads identically
  either way from that function on its own.

  Delegates to `Feed.wanted/1`, previously reachable only by going past the facade to
  that internal process. Returns `[]` when no feed is started, matching `coverage/1`'s
  own empty-map answer for the same case.
  """
  @spec wanted(keyword()) :: [String.t()]
  def wanted(opts \\ []) do
    feed = feed(opts)
    if alive?(feed), do: Feed.wanted(feed), else: []
  end

  @doc """
  What is arriving, per symbol, split by which kind of data it is — never what `coverage/1`
  alone can tell apart.

  `coverage/1` reports one route for a symbol regardless of what actually delivered, which
  is truthful and was measured not to be enough: Coinbase's order-book channel delivered
  over 11,000 frames while quotes stayed dark, and `coverage/1` reported the symbol as
  `:stream` throughout (DpCryptoManagement's issue #22), because it counts a
  `Types.OrderBook` as coverage exactly as much as a `Types.Quote`.

  This venue sharpens that blindness rather than merely repeating it, because Schwab's
  fallback conflates kind with route too. **Only quotes survive the fallback**: when
  `GET /userPreference` cannot bootstrap the Streamer, `Feed` falls back to polling
  `/quotes` and nothing else, so candles cannot arrive on that route for *any* symbol —
  not "arrived rarely," structurally absent. A caller reading only `coverage/1` cannot tell
  "the venue sent no candle for this symbol" from "this feed silently fell back to a route
  that cannot carry candles at all." This is what separates the two: on the poll route it
  reports `%{quotes: coverage(opts)}` and no other key; on the Streamer route, kind comes
  from the decoded struct's own type, never from a service name. (Depth, order events and
  fill events arrive on **neither** route — `capabilities().streamable` does not declare
  them; see its moduledoc for why.)

  Delegates to `Feed.coverage_by_kind/1` — see there for the full accounting, including why
  this venue's own architecture (one route for the whole feed, chosen once) does not reach
  the "a symbol is `:internal_poll` for one kind and `:stream` for another" case the
  callback's own moduledoc describes as merely possible in general.

  Returns `%{}` when no feed is started, matching `coverage/1`.
  """
  @impl true
  @spec coverage_by_kind(keyword()) :: %{
          DpExchange.Core.Capabilities.data_kind() => %{Venue.symbol() => Venue.route()}
        }
  def coverage_by_kind(opts \\ []) do
    feed = feed(opts)
    if alive?(feed), do: Feed.coverage_by_kind(feed), else: %{}
  end

  @doc """
  Whether the feed is delivering, on which route, and what it last failed on.

  On the Streamer route this carries `route: :stream`, how many symbols are currently
  `delivering`, how many are `wanted`, and `last_error` from the most recent bootstrap
  failure, if any. On the fallback route it is `Core.PollingFeed.status/1`'s own map with
  `route: :internal_poll` merged in. Neither shape promises anything `coverage/1` and
  `coverage_by_kind/1` do not already say more precisely per symbol; this is the
  feed-wide summary a health check or a log line reaches for instead of assembling one
  from those two.

  Delegates to `Feed.status/1`, previously reachable only by going past the facade to
  that internal process. Returns `%{}` when no feed is started, matching `coverage/1`.
  """
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    feed = feed(opts)
    if alive?(feed), do: Feed.status(feed), else: %{}
  end

  @doc """
  Registers `opts[:to]` (the caller, by default) for this package's own notices — every
  `Core.Notice` either half of the feed emits:

  - `:degraded`, from `DpExchange.Schwab.Feed`, when the Streamer cannot bootstrap and it
    falls back to polling — and from `DpExchange.Schwab.Socket` for a login the venue
    refused for a reason a new token would not fix.
  - `:credentials_rejected`, from `DpExchange.Schwab.Socket`, when the venue answers a
    `LOGIN` with `3 LOGIN_DENIED`. **This is the kind a host must handle**: the socket
    cannot fix its own token, so it backs off and retries the same rejected credential
    until `refresh_credentials/2` and `update_credentials/2` replace it. See
    `usage-rules.md` §3.
  - `:link_up` and `:link_down`, from `DpExchange.Schwab.Socket`, as a session is
    established and lost. `:link_up` follows the *login* response, not merely a reconnected
    socket.
  - `:coverage_change`, which the fallback poll emits itself when it stops, or resumes,
    delivering.

  **This was a no-op.** It ignored `opts` entirely and returned `:ok` without registering
  anything, while `DpExchange.Schwab.Feed.subscribe_notices/2` — the registry that actually
  holds subscribers and fans notices out to them — sat right beside it, complete and
  unreachable through this facade. A caller that registered through here and later saw a
  `:degraded` notice reach nobody had no way to know the call it trusted had done nothing;
  it looked identical to a quiet, healthy feed. This is the third time this family has
  shipped a mechanism nothing calls: issue #23's `rate_limit_blocking` and issue #22's
  `FrameSender` retry were the other two.

  Resolves the feed exactly as `coverage/1` and `update_symbols/2` do, and — because
  registering with a feed that does not exist can never be honoured, the same reasoning
  `update_symbols/2` already applies — answers `{:error, :feed_not_started}` on the same
  terms rather than reporting `:ok` for a registration nothing will ever fire.

  See `DpExchange.Schwab.Feed.subscribe_notices/2`, which this delegates to.
  """
  @impl true
  def subscribe_notices(opts \\ []) do
    feed = feed(opts)
    if alive?(feed), do: Feed.subscribe_notices(feed, opts), else: {:error, :feed_not_started}
  end

  @doc """
  Pushes refreshed `credentials` into the running feed.

  **The other half of the round trip `refresh_credentials/2` starts.** Every future
  bootstrap or poll fetch signs with `credentials`; on the Streamer route with a live
  socket, the new `:access_token` also reaches `DpExchange.Schwab.Socket.update_access_token/2`
  immediately, so the socket's next `LOGIN` — an ordinary reconnect, or one already backing
  off after a `LOGIN_DENIED` — can succeed. **Does not force a reconnect**; a session
  already logged in keeps running on the token it logged in with.

  Before this existed, a feed's access token was fixed at the moment it started: a 30-minute
  token with nothing to renew it, on a socket meant to stay up far longer than that. See
  `DpExchange.Schwab.Feed`'s moduledoc, "Credentials rotate", for the full accounting.

  Resolves the feed exactly as `coverage/1` and `subscribe_notices/1` do; answers
  `{:error, :feed_not_started}` on the same terms, since there is nothing to update.
  """
  @spec update_credentials(map(), keyword()) :: :ok | {:error, term()}
  def update_credentials(credentials, opts \\ []) do
    feed = feed(opts)

    if alive?(feed),
      do: Feed.update_credentials(feed, credentials),
      else: {:error, :feed_not_started}
  end

  # --- plumbing -----------------------------------------------------------

  defp credentials(opts) do
    case Keyword.get(opts, :credentials) do
      %{} = credentials -> {:ok, credentials}
      _absent -> {:error, {:missing_credentials, :schwab}}
    end
  end

  # Named rather than defaulted. Every account path takes the hash, and silently using
  # some first account would place an order against an account the caller did not choose.
  defp account_hash(opts) do
    case Keyword.get(opts, :account_hash) do
      hash when is_binary(hash) and hash != "" -> {:ok, hash}
      _absent -> {:error, {:missing_account_hash, :schwab}}
    end
  end

  defp with_limiter(opts) do
    Keyword.put_new(opts, :limiter, Supervisor.limiter_name(opts))
  end

  # See `OrderLimit`'s moduledoc and `Supervisor`'s "A silent 0 is still the wrong fix"
  # section. `{:error, :not_started}` means this consumer never supervised `OrderLimit` at
  # all — bypassing `Supervisor` entirely with a `:limiter` of its own, which this package
  # has always allowed — and gets no opinion here, not a refusal: collapsing "I was never
  # asked" into "refused" would fail every consumer who does that, several of this
  # package's own tests among them. `declared?: false` means a tree WAS started through
  # `Supervisor` and specifically never told an order ceiling, which every order write
  # refuses rather than let masquerade as the venue's own throttling.
  defp ensure_order_limit_declared(opts) do
    case OrderLimit.status(Supervisor.order_limit_name(opts)) do
      {:error, :not_started} -> :ok
      %{declared?: true} -> :ok
      %{declared?: false} -> {:error, :order_limit_not_declared}
    end
  end

  defp feed(opts), do: Keyword.get(opts, :feed, Supervisor.feed_name(opts))

  defp alive?(name) when is_atom(name), do: is_pid(Process.whereis(name))
  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive?(_other), do: false

  # --- Declared but not yet implemented -----------------------------------
  #
  # Core 0.1.16 widened the facade to the surface the venues actually publish. These answer
  # `{:error, :not_supported}` and are declared `:unsupported` in `capabilities/0`, so a
  # consumer routing on the declaration is told the truth.
  #
  # **`:unsupported` here is a statement about this package, not about the venue.** That
  # distinction is the one Phase 1 had to correct after a package spent a year asserting a
  # venue had no streaming API when it had fifteen services. Where the venue genuinely does
  # not offer something, the comment beside it says so.

  @doc """
  Open positions, read through the account.

  See `DpExchange.Schwab.Rest.get_positions/2`. Schwab reports long and short as separate
  quantities rather than one signed number, and a row with both zero is a closed position
  the venue still lists.
  """
  @impl true
  def get_positions(opts),
    do: Rest.get_positions(Keyword.get(opts, :credentials, %{}), opts)

  @doc """
  The option chain for an underlying — expiry × strike, both sides.

  See `DpExchange.Schwab.Rest.get_option_chain/3`. `underlying_price` is carried only when
  the venue sent it, which needs `include_underlying_quote: true`.
  """
  @impl true
  def get_option_chain(underlying, opts),
    do: Rest.get_option_chain(underlying, Keyword.get(opts, :credentials, %{}), opts)

  @doc """
  The expiries listed on an underlying.

  See `DpExchange.Schwab.Rest.get_option_expirations/3` — its own endpoint, not a narrowing
  of the chain.
  """
  @impl true
  def get_option_expirations(underlying, opts),
    do: Rest.get_option_expirations(underlying, Keyword.get(opts, :credentials, %{}), opts)

  @doc """
  A mover list, by the venue's own universe — `movers_universes/0` lists them.

  See `DpExchange.Schwab.Rest.get_screener/3`. The rank is the position the venue returned
  the row in; nothing is re-ranked.
  """
  @impl true
  def get_screener(name, opts),
    do: Rest.get_screener(name, Keyword.get(opts, :credentials, %{}), opts)

  @doc """
  Transactions on one account.

  `opts[:account_hash]`, `opts[:from]`, `opts[:to]` and `opts[:types]` are all required —
  the last three by the venue, and the first because every Schwab account endpoint addresses
  by the encrypted hash `get_accounts/2` returns. See
  `DpExchange.Schwab.Rest.get_transactions/3`, including why there is no "all types".

  A missing `opts[:account_hash]` is `{:error, {:missing_account_hash, :schwab}}`, the same
  atom every other account endpoint here uses. It answered `{:account_hash_required,
  :schwab}` until a cross-package audit found this function carrying its own spelling of a
  condition the shared `account_hash/1` helper already names — two atoms for one condition,
  so a consumer handling "you forgot the account hash" uniformly could not.
  """
  @impl true
  def get_transactions(credentials, opts) do
    with {:ok, hash} <- account_hash(opts) do
      Rest.get_transactions(credentials, hash, opts)
    end
  end

  @doc "One transaction by id. See `DpExchange.Schwab.Rest.get_transaction/4`."
  @spec get_transaction(map(), String.t(), integer() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_transaction(credentials, account_hash, transaction_id, opts \\ []),
    do: Rest.get_transaction(credentials, account_hash, transaction_id, opts)

  @doc """
  Every account's balances, and its positions when asked.

  **Not `get_accounts/2`** — that reads `/accounts/accountNumbers` for the hashes every
  other endpoint addresses by. See `DpExchange.Schwab.Rest.get_account_summaries/2`.
  """
  @spec get_account_summaries(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_account_summaries(credentials, opts \\ []),
    do: Rest.get_account_summaries(credentials, opts)

  @doc """
  Orders across every account. `opts[:from]` and `opts[:to]` are required by the venue.

  See `DpExchange.Schwab.Rest.get_all_orders/2`. `get_orders/3` is the per-account read.
  """
  @spec get_all_orders(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_all_orders(credentials, opts \\ []), do: Rest.get_all_orders(credentials, opts)

  @doc """
  One symbol's quote, unnormalised. See `DpExchange.Schwab.Rest.get_symbol_quote/3`.
  """
  @spec get_symbol_quote(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_symbol_quote(symbol, credentials, opts \\ []),
    do: Rest.get_symbol_quote(symbol, credentials, opts)

  @doc "One market's hours, optionally on another day. See `DpExchange.Schwab.Rest.get_market/3`."
  @spec get_market(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_market(market, credentials, opts \\ []), do: Rest.get_market(market, credentials, opts)

  @doc "One instrument by CUSIP. See `DpExchange.Schwab.Rest.get_instrument/3`."
  @spec get_instrument(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_instrument(cusip, credentials, opts \\ []),
    do: Rest.get_instrument(cusip, credentials, opts)

  @doc """
  The signed-in user's preferences — the same endpoint the streamer bootstraps from.

  See `DpExchange.Schwab.Rest.get_user_preference/2`.
  """
  @spec get_user_preference(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_user_preference(credentials, opts \\ []),
    do: Rest.get_user_preference(credentials, opts)

  @doc "The mover universes this venue publishes."
  @spec movers_universes() :: [String.t()]
  defdelegate movers_universes(), to: Rest

  @doc "The markets this venue publishes hours for."
  @spec markets() :: [String.t()]
  defdelegate markets(), to: Rest

  @doc "The transaction types this venue records — there is no 'all' among them."
  @spec transaction_types() :: [String.t()]
  defdelegate transaction_types(), to: Rest

  @doc """
  Instructions the venue accepts on an order leg for an equity — `BUY`, `SELL`,
  `SELL_SHORT`, `BUY_TO_COVER`. `place_order/3`, `preview_order/3` and `replace_order/4`
  all refuse an instruction outside this list before it is sent, since order writes are
  throttled here and reads are not; a caller building a request can check the same list
  first rather than discover the mismatch by refusal.

  Delegates to `DpExchange.Schwab.Orders.equity_instructions/0`, previously reachable
  only by going past the facade to that internal module.
  """
  @spec equity_instructions() :: [String.t()]
  defdelegate equity_instructions(), to: Orders

  @doc """
  Instructions the venue accepts on an order leg for an option — `BUY_TO_OPEN`,
  `BUY_TO_CLOSE`, `SELL_TO_OPEN`, `SELL_TO_CLOSE`. See `equity_instructions/0`.

  Delegates to `DpExchange.Schwab.Orders.option_instructions/0`, previously reachable
  only by going past the facade to that internal module.
  """
  @spec option_instructions() :: [String.t()]
  defdelegate option_instructions(), to: Orders

  # **A stock broker moves money through cheques, ACH and wires arranged with a person, not
  # through an API.** The Accounts and Trading specification has no payment method, no
  # transfer, no allowlist and no network list — nothing in the twelve below appears in it.
  # `get_transactions/2` above *reports* money that moved and is the one that is served.

  @impl true
  def list_payment_methods(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def get_payment_method(_credentials, _id, _opts), do: Venue.not_supported()

  @impl true
  def add_payment_method(_details, _opts), do: Venue.not_supported()

  @impl true
  def transfer_internal(_asset, _amount, _opts, _request_opts), do: Venue.not_supported()

  @impl true
  def request_approved_address(_asset, _network, _address, _opts), do: Venue.not_supported()

  @impl true
  def remove_approved_address(_network, _address, _opts), do: Venue.not_supported()

  @impl true
  def list_networks(_asset, _opts), do: Venue.not_supported()

  @impl true
  def list_fee_promos(_opts), do: Venue.not_supported()

  @impl true
  def get_fx_rate(_pair, _at, _opts), do: Venue.not_supported()

  @impl true
  def get_notional_balances(_credentials, _currency, _opts), do: Venue.not_supported()

  @impl true
  def list_custody_fees(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def get_funding(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_contract_stats(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_staking_rates(_opts), do: Venue.not_supported()

  @impl true
  def get_staking_balances(_opts), do: Venue.not_supported()

  @impl true
  def get_staking_rewards(_opts), do: Venue.not_supported()

  @impl true
  def get_staking_history(_opts), do: Venue.not_supported()

  @impl true
  def stake(_asset, _amount, _opts), do: Venue.not_supported()

  @impl true
  def unstake(_asset, _amount, _opts), do: Venue.not_supported()

  @impl true
  def quote_conversion(_from, _to, _amount, _opts), do: Venue.not_supported()

  @impl true
  def commit_conversion(_id, _opts), do: Venue.not_supported()

  @impl true
  def get_conversion(_id, _opts), do: Venue.not_supported()

  @impl true
  def convert(_from, _to, _amount, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_trade_volume(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def list_portfolios(_opts), do: Venue.not_supported()

  @impl true
  def get_deposit_address(_asset, _network, _opts), do: Venue.not_supported()

  @impl true
  def list_approved_addresses(_opts), do: Venue.not_supported()

  @impl true
  def estimate_withdrawal_fee(_asset, _network, _amount, _opts), do: Venue.not_supported()

  @impl true
  def withdraw(_asset, _network, _amount, _address, _opts), do: Venue.not_supported()

  @impl true
  def get_option_greeks(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def list_watchlists(_opts), do: Venue.not_supported()

  @impl true
  def get_watchlist(_id, _opts), do: Venue.not_supported()

  @impl true
  def create_watchlist(_name, _symbols, _opts), do: Venue.not_supported()

  @impl true
  def update_watchlist(_id, _opts), do: Venue.not_supported()

  @impl true
  def delete_watchlist(_id, _opts), do: Venue.not_supported()

  @impl true
  def get_financials(_symbol, _kind, _opts), do: Venue.not_supported()

  @impl true
  def get_corporate_events(_opts), do: Venue.not_supported()

  @impl true
  def get_filings(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_news(_opts), do: Venue.not_supported()

  @impl true
  def create_account(_opts), do: Venue.not_supported()

  @impl true
  def rename_account(_id, _name, _opts), do: Venue.not_supported()

  @impl true
  def get_roles(_opts), do: Venue.not_supported()
end
