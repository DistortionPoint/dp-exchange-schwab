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
  minting a new refresh token each time. The vendor documents the refresh token itself as
  valid seven days after creation and says nothing about whether refreshing resets that
  clock — see `Auth`'s own moduledoc — so a host should plan for a person to
  re-authenticate at least once every seven days regardless of how often it refreshes.

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
  of a refresh must be persisted by the host** — treat the refresh token as one-time use
  (this package's safe assumption; no committed vendor document states it, see `Auth`), so
  the one returned is the only way to refresh again. A credential whose `:expires_at` has
  passed (or is within five seconds of passing) is refused before anything is sent (`{:error, {:credentials_expired, :schwab}}`);
  one with no `:expires_at` is judged by the venue, and nothing here refreshes or retries on
  a `401` for you.

  ## Options

  Every function that takes keyword `opts` refuses a key it does not read:
  `{:error, {:unknown_option, key}}`, or `{:error, {:invalid_options, value}}` for a value
  that is not a keyword list, before anything is sent. The keys each function reads are one
  table, `DpExchange.Schwab.Options`, and `usage-rules.md` section 16. `coverage/1`,
  `wanted/1`, `coverage_by_kind/1` and `status/1` have no error channel and raise
  `ArgumentError` instead.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.{Config, Types, Venue}

  alias DpExchange.Schwab.{
    Auth,
    Capabilities,
    Feed,
    Options,
    OrderLimit,
    Orders,
    Rest,
    Supervisor,
    SymbolFormat
  }

  # --- identity -----------------------------------------------------------

  @doc """
  The display name of this venue: `"Schwab"`.

  See `c:DpExchange.Core.Venue.provider_name/0`.
  """
  @impl true
  def provider_name, do: "Schwab"

  @doc """
  The atom that identifies this venue at runtime: `:schwab`.

  See `c:DpExchange.Core.Venue.runtime_id/0`.
  """
  @impl true
  def runtime_id, do: :schwab

  @doc """
  The asset classes this venue trades: `[:equity]`.

  See `c:DpExchange.Core.Venue.asset_classes/0`.
  """
  @impl true
  def asset_classes, do: [:equity]

  @doc """
  The per-endpoint capability declaration, built by `DpExchange.Schwab.Capabilities.declaration/0`.

  See `c:DpExchange.Core.Venue.capabilities/0` for the contract.
  """
  @impl true
  def capabilities, do: Capabilities.declaration()

  @doc "Endpoints the venue does not serve, as distinct from ones not yet written."
  @spec venue_does_not_serve() :: [{atom(), arity()}]
  defdelegate venue_does_not_serve, to: Capabilities

  @doc "The quote currencies this venue settles in."
  @spec quotes() :: [String.t()]
  def quotes, do: ["USD"]

  # --- lifecycle ----------------------------------------------------------

  @doc """
  A supervisor child spec for this venue's tree (limiter, order-ceiling record and feed).

  Credentials in `opts` are wrapped here, before the supervisor captures the start arguments,
  so a crash report cannot print them. See `c:DpExchange.Core.Venue.child_spec/1`.
  """
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
      # `Config.opt/3`: a forwarded `name: nil` is silence, so it is the default id.
      id: Config.opt(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Starts this venue's supervision tree through `DpExchange.Schwab.Supervisor.start_link/1`.

  Reads `:name`, `:order_limit_per_minute`, `:read_limit_per_minute` and the feed options, and
  **refuses a key it does not read** before anything starts: `{:error, {:unknown_option, key}}`,
  or `{:error, {:invalid_options, opts}}` for a non-keyword list (a `:credentials` entry is
  redacted). The table is `DpExchange.Schwab.Options.start_keys/0`; `child_spec/1` reaches the
  same check when its supervisor starts the child. See `c:DpExchange.Core.Venue.start_link/1`.
  """
  @impl true
  def start_link(opts), do: Supervisor.start_link(opts)

  # --- market data --------------------------------------------------------

  @doc """
  The last price for `symbol`, read from the `/quotes` endpoint.

  Requires `opts[:credentials]`; a blank or non-binary symbol is refused before that check. See
  `c:DpExchange.Core.Venue.get_price/2`.
  """
  @impl true
  def get_price(symbol, opts \\ []) do
    # A nil, non-binary or blank symbol is `{:invalid_symbol, v}`, decided before credentials.
    with :ok <- SymbolFormat.check_present(symbol),
         :ok <- Options.check(:get_price, opts),
         {:ok, credentials} <- credentials(opts) do
      Rest.get_price(symbol, credentials, with_limiter(opts))
    end
  end

  @doc """
  Best bid and ask for `symbol`, read from the `/quotes` endpoint (REST publishes no deeper book).

  Requires `opts[:credentials]`. An instrument whose quote carries no book, such as a mutual fund,
  answers `{:refused, :no_quote}`. See `c:DpExchange.Core.Venue.get_top_of_book/2`.
  """
  @impl true
  def get_top_of_book(symbol, opts \\ []) do
    with :ok <- SymbolFormat.check_present(symbol),
         :ok <- Options.check(:get_top_of_book, opts),
         {:ok, credentials} <- credentials(opts) do
      Rest.get_top_of_book(symbol, credentials, with_limiter(opts))
    end
  end

  @doc """
  Candles for `symbol` from the `/pricehistory` endpoint.

  Requires `opts[:credentials]`; `timeframe` must be one of the widths this venue serves. See
  `c:DpExchange.Core.Venue.get_historical_prices/4`.
  """
  @impl true
  def get_historical_prices(symbol, timeframe, range, opts \\ []) do
    with :ok <- SymbolFormat.check_present(symbol),
         :ok <- Options.check(:get_historical_prices, opts),
         {:ok, credentials} <- credentials(opts) do
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

  `:projection` defaults to `"symbol-search"`; a value outside the venue's six is
  `{:error, {:invalid_projection, value}}`, decided before anything is sent.
  """
  @impl true
  def get_symbols(opts \\ []) do
    with :ok <- Options.check(:get_symbols, opts),
         {:ok, credentials} <- credentials(opts) do
      Rest.get_symbols(credentials, with_limiter(opts))
    end
  end

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.preview_replace/4`.
  """
  @impl true
  def preview_replace(_credentials, _id, _changes, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.close_position/3`.
  """
  @impl true
  def close_position(_credentials, _symbol, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.cancel_all_orders/2`.
  """
  @impl true
  def cancel_all_orders(_credentials, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. The REST API publishes no depth;
  see the moduledoc and `c:DpExchange.Core.Venue.get_order_book/2`.
  """
  @impl true
  def get_order_book(_symbol, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_trades/2`.
  """
  @impl true
  def get_trades(_symbol, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_auction_imbalance/2`.
  """
  @impl true
  def get_auction_imbalance(_symbol, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_volume_profile/3`.
  """
  @impl true
  def get_volume_profile(_symbol, _timeframe, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_market_overview/1`.
  """
  @impl true
  def get_market_overview(_opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. The catalogue cannot be
  enumerated; use `get_symbols/1` with a `:query`. See `c:DpExchange.Core.Venue.list_instruments/1`.
  """
  @impl true
  def list_instruments(_opts \\ []), do: Venue.not_supported()

  @doc """
  Whether the market is open, read from the `/markets` endpoint.

  Requires `opts[:credentials]`; `opts[:market]` defaults to `"equity"`. See
  `c:DpExchange.Core.Venue.market_status/1`.
  """
  @impl true
  def market_status(opts \\ []) do
    with :ok <- Options.check(:market_status, opts),
         {:ok, credentials} <- credentials(opts) do
      Rest.market_status(credentials, with_limiter(opts))
    end
  end

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.quantization/1`.
  """
  @impl true
  def quantization(_symbol), do: Venue.not_supported()

  # --- accounts and trading -----------------------------------------------

  @doc """
  The account numbers and their encrypted hashes, from `/accounts/accountNumbers`.

  The hash is what every other account endpoint here takes as `opts[:account_hash]`. See
  `c:DpExchange.Core.Venue.get_accounts/2`.
  """
  @impl true
  def get_accounts(credentials, opts \\ []) do
    with :ok <- Options.check(:get_accounts, opts) do
      Rest.get_accounts(credentials, with_limiter(opts))
    end
  end

  @doc """
  Balances for one account.

  Requires `:account_hash` — Schwab addresses accounts by an encrypted hash, and
  `get_accounts/2` is the only place to get one. That makes it a prerequisite for the
  whole trading surface rather than a convenience.
  """
  @impl true
  def get_balances(credentials, opts \\ []) do
    with :ok <- Options.check(:get_balances, opts),
         {:ok, hash} <- account_hash(opts) do
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

  The order is validated first (`Orders.build/2`: every refusal there is decided before the
  account option, the order ceiling and the credential), then `opts[:account_hash]`
  (`{:error, {:missing_option, :account_hash}}`), then the order ceiling:
  `{:error, :order_limit_not_declared}` when this tree was supervised without
  `:order_limit_per_minute` — see `Supervisor`'s moduledoc and `OrderLimit`. That is
  distinct from a declared ceiling of `0`, which answers `{:error, :order_limit_zero}`
  locally (a registration granting no throughput), and distinct from a consumer that never
  supervises this module at all, which gets no opinion from this check.

  **A write that may have reached the venue and is not proven is
  `{:error, {:order_unconfirmed, nil, reason}}`** (a timeout, a transport failure, a 5xx, or
  a `201` with no `Location`): the request is sent once, and a caller that retried a bare
  error could place the order twice. The `nil` is the client order id, which Schwab has no
  field for, so the caller reconciles with `get_orders/2`. `client_order_id` in the request
  is `{:error, {:unsupported_order_field, :client_order_id}}`. A venue 4xx is `{:refused, _}`.
  """
  @impl true
  def place_order(credentials, request, opts \\ []) do
    with :ok <- Options.check(:place_order, opts),
         {:ok, payload} <- Orders.build(request, opts),
         {:ok, hash} <- account_hash(opts),
         :ok <- ensure_order_limit_declared(opts),
         {:ok, id} <- Rest.place_order(credentials, hash, payload, with_limiter(opts)) do
      placed_order(credentials, id, payload, opts)
    end
  end

  # **An `Order`, as `Core.Venue` types it, not the bare id.** The venue answers a placement
  # with a `Location` header and nothing else, so `{:ok, "123"}` was all this returned, and a
  # consumer matching `%Order{}` across venues broke on this one. The order is read back with
  # `get_order/3`, a read on this venue rather than a throttled write. If that read fails the
  # order is still placed, so the answer is `{:ok, _}`, built only from what was sent
  # (`Orders.accepted/2`): the id the venue named and the payload, `:pending`, nothing invented.
  defp placed_order(credentials, id, payload, opts) do
    case read_back(credentials, id, opts) do
      {:ok, %Types.Order{} = order} -> {:ok, order}
      _read_back_failed -> Orders.accepted(id, payload)
    end
  end

  @doc """
  **Not supported.** Schwab places one order per request.

  `POST /accounts/{accountNumber}/orders` takes one order; the Accounts and Trading
  specification publishes no batch. Its multi-leg orders are one *order* with several legs,
  which is a different thing — the venue accepts or rejects it as one — and are **not
  reachable here either**: `place_order/3` takes a flat request (one symbol, one side, one
  quantity) and builds a single-leg `SINGLE` order, so `supports_multi_leg_orders` is
  `false` in `capabilities/0`.
  """
  @impl true
  def place_orders(_credentials, _requests, _opts), do: Venue.not_supported()

  @doc """
  Validate an order **without placing it**.

  The only endpoint in the family that checks an order against the venue's own rules
  before committing, and it earns its keep here specifically: order writes are throttled
  on this venue and reads are not, so a rejection found by previewing costs nothing while
  one found by placing costs a scarce write.

  Builds the same order `place_order/3` would through `Orders.build/2`, then reshapes it
  into `/previewOrder`'s own documented request — `PreviewOrder`/`OrderStrategy`, not
  `OrderRequest` — via `DpExchange.Schwab.Orders.to_preview/1`. A preview that passes
  describes the order that would actually be sent.

  **A preview the venue rejects is `{:refused, {:preview_rejected, rejects}}`**, not `{:ok, _}`:
  `/previewOrder` answers 200 with a non-empty `orderValidationResult.rejects` for an order it
  would refuse to place, and a caller that checked only the tag would go on to place it.
  `rejects` is the venue's own detail rows (`validationRuleName`, `message`, ...), capped and
  bounded. A clean preview is `{:ok, body}` with `alerts`, `warns` and `reviews` in it.
  """
  @impl true
  def preview_order(credentials, request, opts \\ []) do
    with :ok <- Options.check(:preview_order, opts),
         {:ok, payload} <- Orders.build(request, opts),
         {:ok, hash} <- account_hash(opts) do
      Rest.preview_order(credentials, hash, Orders.to_preview(payload), with_limiter(opts))
    end
  end

  @doc """
  Replace an open order **atomically**.

  Schwab amends in one call. Every other venue in the family cancels and re-places, and
  those are **not equivalent here**: cancel-then-place opens a window in which no order is
  live, and it spends two throttled writes rather than one.

  Returns the **new** order, read back as `place_order/3` reads one. Schwab treats a
  replacement as a new order, so the old id is dead afterwards and a caller still holding it
  would be tracking something that no longer exists.

  `{:error, :order_limit_not_declared}` under the same conditions as `place_order/3` — a
  replacement is a `PUT` order write, the same throttled category as a placement.

  The order id is checked first (`{:error, {:invalid_order_id, value}}` for `nil`, a
  non-string, a blank or a padded string), then the request (a non-map or an EMPTY map is
  `{:error, {:invalid_order_request, value}}`, since a replace that changes nothing is not a
  replace; Schwab sends the map as a whole new order, so every field of it is then judged as
  `place_order/3` judges it), the account option, the order
  ceiling and the credential. An unconfirmed write is `{:error, {:order_unconfirmed, nil,
  reason}}` as for `place_order/3`. **A replacement the venue applied whose read-back failed is
  `{:error, {:replace_accepted_unread, new_id, reason}}`**: the old order is gone and `new_id`
  is live, and no `Order` is invented from the request. Read it with `get_order/3`.
  """
  @impl true
  def replace_order(credentials, order_id, request, opts \\ []) do
    with :ok <- Orders.check_order_id(order_id),
         :ok <- Options.check(:replace_order, opts),
         {:ok, payload} <- Orders.build_replacement(request, opts),
         {:ok, hash} <- account_hash(opts),
         :ok <- ensure_order_limit_declared(opts),
         {:ok, new_id} <-
           Rest.replace_order(credentials, hash, order_id, payload, with_limiter(opts)) do
      # The NEW order, read back the way a placement is - but a failed read is not papered
      # over with an order built from the request: the replacement was applied, so the answer
      # says so and carries the id.
      case read_back(credentials, new_id, opts) do
        {:ok, %Types.Order{} = order} -> {:ok, order}
        {:error, reason} -> {:error, {:replace_accepted_unread, new_id, reason}}
        {:refused, reason} -> {:error, {:replace_accepted_unread, new_id, reason}}
      end
    end
  end

  @doc """
  Cancel an open order.

  `{:ok, :cancelled}` means the venue accepted the cancel request (a 2xx), not that the order
  has already left the book: Schwab may report it `PENDING_CANCEL` first, and a fill can beat the
  cancel. Read it with `get_order/3` for its final state. An order already filled, cancelled or
  replaced is the venue's 4xx, `{:refused, {:venue_error, status, detail}}` (or
  `{:venue_error, status}` with no detail), never `{:ok, _}`.

  `{:error, :order_limit_not_declared}` under the same conditions as `place_order/3` — a
  cancel is a `DELETE` order write, the same throttled category as a placement.
  """
  @impl true
  def cancel_order(credentials, order_id, opts \\ []) do
    with :ok <- Orders.check_order_id(order_id),
         :ok <- Options.check(:cancel_order, opts),
         {:ok, hash} <- account_hash(opts),
         :ok <- ensure_order_limit_declared(opts),
         :ok <- Rest.cancel_order(credentials, hash, order_id, with_limiter(opts)) do
      # `{:ok, :cancelled}`, as `dp_exchange_coinbase` and `dp_exchange_webull` answer a cancel
      # whose response carries no order. A bare `:ok` matched none of the `{:ok, _} |
      # {:error, _} | {:refused, _}` shapes every other call here returns.
      {:ok, :cancelled}
    end
  end

  # `Orders.from_venue/1` is what makes these two return what `Core.Venue` types them as —
  # `Types.Order.t()` — rather than the venue's raw JSON map, which they did until the
  # response-shape sweep read what the real facade actually handed back. See its @doc.
  @doc """
  One order, read from the account's `/orders/{id}` endpoint and returned as a `Types.Order`.

  Requires `opts[:account_hash]`; an order the venue does not know is `{:refused, :not_found}`.
  See `c:DpExchange.Core.Venue.get_order/3`.
  """
  @impl true
  def get_order(credentials, order_id, opts \\ []) do
    with :ok <- Orders.check_order_id(order_id),
         :ok <- Options.check(:get_order, opts) do
      fetch_order(credentials, order_id, opts)
    end
  end

  # The read itself, with no option check: `place_order/3` and `replace_order/4` read the order
  # back with their own (already checked) options, which carry keys `get_order/3` does not take.
  # The read-back after an accepted write is one attempt: the write's options carry no retry
  # keys (an order write is never retried), so the read would otherwise fall to Core's default
  # backoff and hold the caller after the order is already placed.
  defp read_back(credentials, order_id, opts),
    do: fetch_order(credentials, order_id, Keyword.put(opts, :retry_attempts, 0))

  defp fetch_order(credentials, order_id, opts) do
    with :ok <- Orders.check_order_id(order_id),
         {:ok, hash} <- account_hash(opts),
         {:ok, order} <- Rest.get_order(credentials, hash, order_id, with_limiter(opts)) do
      Orders.from_venue(order)
    end
  end

  @doc """
  Orders on one account, returned as `Types.Order` values.

  Requires `opts[:account_hash]`, plus `opts[:from]` and `opts[:to]`, which the venue requires;
  `opts[:status]` and `opts[:max_results]` are optional filters. See
  `c:DpExchange.Core.Venue.get_orders/2`.
  """
  @impl true
  def get_orders(credentials, opts \\ []) do
    with :ok <- Options.check(:get_orders, opts),
         {:ok, hash} <- account_hash(opts),
         {:ok, orders} <- Rest.get_orders(credentials, hash, with_limiter(opts)) do
      Orders.list_from_venue(orders)
    end
  end

  @doc """
  **Not supported yet.** `/transactions` carries fills, but mapping a Schwab transaction
  onto `Core.Types.Fill` needs a live response to check against and this repository holds
  no credential. Declared `:unsupported` in `capabilities/0` and answering
  `{:error, :not_supported}`, so the declaration and the code agree. Use
  `get_transactions/2`, which returns the venue's own transaction rows unmapped.
  """
  @impl true
  def get_trade_history(_credentials, _opts \\ []), do: Venue.not_supported()

  @doc """
  Checks the credential by reading the account list; answers `{:ok, %{accounts: count}}`.

  See `c:DpExchange.Core.Venue.test_connection/2`.
  """
  @impl true
  def test_connection(credentials, opts \\ []) do
    with :ok <- Options.check(:test_connection, opts),
         {:ok, accounts} <- Rest.get_accounts(credentials, with_limiter(opts)) do
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
  - **`{:refused, {:client_credentials_rejected, status, detail}}`** means the venue said
    `invalid_client`: the app's client pair is wrong, not the grant. Fix the configuration.
  - Never retried by this call itself, and cannot be made to retry through `opts`.
  - **`{:error, {:refresh_in_progress, :schwab}}`**: another refresh of the same refresh token
    is in flight (on this node or a connected one), so nothing was sent. Wait for it and use the credential your
    storage now holds; this one is about to be spent. It closes the overlap only - refresh
    from one process per credential (see `usage-rules.md` §3).

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
  def refresh_credentials(credentials, opts \\ []) do
    with :ok <- Options.check(:refresh_credentials, opts) do
      Auth.refresh(credentials, with_limiter(opts))
    end
  end

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
  `{:refused, {:venue_error, status, detail}}` (`{:venue_error, status}` when the body carries
  no detail) on a `4xx`. `status in [401, 403]` means
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

  Refuses what the feed cannot hold, recording nothing: `{:error, {:invalid_symbols, term}}`,
  then `{:error, {:invalid_subscriber, term}}` for a `:to` that is neither a pid nor a
  registered name (an atom other than `nil`, `true` or `false`).
  """
  @impl true
  def subscribe(symbols, opts \\ []) do
    # Arguments first (the symbols, the options, the subscriber, then the stream options),
    # THEN whether a feed runs: a bad argument answers the same whether or not the feed is
    # started.
    with :ok <- Feed.check_symbols(symbols),
         :ok <- Options.check(:subscribe, opts),
         {:ok, _subscriber} <- Feed.valid_subscriber(Config.opt(opts, :to, self())),
         :ok <- Feed.check_stream_options(opts) do
      feed = feed(opts)

      if alive?(feed) do
        feed_call(
          fn -> Feed.subscribe(feed, canonical_case(symbols), opts) end,
          {:error, :feed_not_started}
        )
      else
        {:error, :feed_not_started}
      end
    end
  end

  @doc """
  Removes `symbols` from the feed's set; `:ok` when no feed is started.

  Symbols are upper-cased on the way in. See `c:DpExchange.Core.Venue.unsubscribe/2`.
  """
  @impl true
  def unsubscribe(symbols, opts \\ []) do
    with :ok <- Feed.check_symbols(symbols),
         :ok <- Options.check(:unsubscribe, opts) do
      feed = feed(opts)

      feed_call(fn -> Feed.unsubscribe(feed, canonical_case(symbols)) end, :ok)
    end
  end

  @doc """
  Replaces the feed's whole symbol set with `symbols`.

  Symbols are upper-cased on the way in; `{:error, :feed_not_started}` when no feed runs. See
  `c:DpExchange.Core.Venue.update_symbols/2`.
  """
  @impl true
  def update_symbols(symbols, opts \\ []) do
    with :ok <- Feed.check_symbols(symbols),
         :ok <- Options.check(:update_symbols, opts) do
      feed = feed(opts)

      feed_call(
        fn -> Feed.update_symbols(feed, canonical_case(symbols)) end,
        {:error, :feed_not_started}
      )
    end
  end

  @doc """
  The route each symbol is actually arriving on, per symbol; `%{}` when no feed is started.

  See `c:DpExchange.Core.Venue.coverage/1`.
  """
  @impl true
  def coverage(opts \\ []), do: read_feed(:coverage, opts, %{}, &Feed.coverage/1)

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
  @impl true
  def wanted(opts \\ []), do: read_feed(:wanted, opts, [], &Feed.wanted/1)

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
  def coverage_by_kind(opts \\ []),
    do: read_feed(:coverage_by_kind, opts, %{}, &Feed.coverage_by_kind/1)

  @doc """
  Whether the feed is delivering, on which route, and what it last failed on.

  **One shape on every route**, because a consumer must not be able to tell how data reaches
  the package: `route` (`:stream`, `:internal_poll`, or `nil` before the first subscribe),
  `delivering` (a boolean, `Core.PollingFeed.status/1`'s type: some symbol has arrived),
  `wanted` and `covered` (counts of symbols asked for and symbols that have arrived),
  `failures_since_ok` (consecutive failed polls, always 0 on the Streamer) and `last_error`
  (the most recent bootstrap or poll failure, if any). A poller that did not answer the read
  is `delivering: false, covered: 0, last_error: :poller_unresponsive`. `delivering` used to
  be a count on the Streamer route and a boolean on the poll; the count is now `covered`.
  Neither value promises anything `coverage/1` and
  `coverage_by_kind/1` do not already say more precisely per symbol; this is the
  feed-wide summary a health check or a log line reaches for instead of assembling one
  from those two.

  Delegates to `Feed.status/1`, previously reachable only by going past the facade to
  that internal process. Returns `%{}` when no feed is started, matching `coverage/1`.
  """
  @spec status(keyword()) :: map()
  def status(opts \\ []), do: read_feed(:status, opts, %{}, &Feed.status/1)

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
  - `:credentials_expiring`, from `DpExchange.Schwab.Feed`, once per credential generation:
    `details.reason: :credentials_expiring` when the access token is inside the refresh
    margin, `:credentials_expired` (`severity: :error`) once it has lapsed. The venue checks
    the token at LOGIN only, so a live session otherwise learns nothing until a reconnect.
    Treat it as "refresh now". `DpExchange.Schwab.Fake` emits no notices.
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

  `{:error, {:invalid_subscriber, term}}` for a `:to` that is neither a pid nor a registered
  name; nothing is recorded.

  See `DpExchange.Schwab.Feed.subscribe_notices/2`, which this delegates to.
  """
  @impl true
  def subscribe_notices(opts \\ []) do
    with :ok <- Options.check(:subscribe_notices, opts),
         {:ok, _subscriber} <- Feed.valid_subscriber(Config.opt(opts, :to, self())) do
      feed = feed(opts)

      feed_call(fn -> Feed.subscribe_notices(feed, opts) end, {:error, :feed_not_started})
    end
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

  Something that is not a credential map (`nil`, or the `{:error, _}` a failed
  `refresh_credentials/2` returned) is `{:error, {:invalid_credentials, :schwab}}`, checked
  before the feed is looked at. It used to reach the `Feed` process, which raised inside
  `handle_call/3` and was restarted from its start-time options, losing every `subscribe/2`
  made since.
  """
  @spec update_credentials(map(), keyword()) :: :ok | {:error, term()}
  def update_credentials(credentials, opts \\ [])

  def update_credentials(credentials, opts) when is_map(credentials) do
    with :ok <- Options.check(:update_credentials, opts) do
      feed = feed(opts)

      if alive?(feed),
        do:
          feed_call(
            fn -> Feed.update_credentials(feed, credentials) end,
            {:error, :feed_not_started}
          ),
        else: {:error, :feed_not_started}
    end
  end

  def update_credentials(_not_a_map, _opts), do: {:error, {:invalid_credentials, :schwab}}

  # --- plumbing -----------------------------------------------------------

  # **`opts` is a keyword list holding only keys the function reads, or the call is refused**,
  # and that is decided by `Options.check/2` at the top of every public function, before any
  # of the readers below. They use `Keyword.get/3` or `Config.opt/3`, both of which raise on
  # anything else, so a map or a bare value used to escape as an `ArgumentError`/
  # `FunctionClauseError` in the caller's process instead of an answer.
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
      _absent -> {:error, {:missing_option, :account_hash}}
    end
  end

  # `Keyword.put/3`, not `put_new/3`: `limiter_name/1` already returns the caller's own
  # `:limiter` when it is set, and `put_new/3` keeps a PRESENT `limiter: nil` — which this
  # family forwards by convention. That `nil` reached `Core.HttpClient`, was resolved there
  # to Core's global default limiter, which this package never starts, and every call failed
  # closed against a venue limiter that was running the whole time.
  defp with_limiter(opts) do
    Keyword.put(opts, :limiter, Supervisor.limiter_name(opts))
  end

  # The check lives in `OrderLimit.ensure_declared/1`, shared with `Fake`, so the two refuse
  # an undeclared or zero order ceiling identically.
  defp ensure_order_limit_declared(opts), do: OrderLimit.ensure_declared(opts)

  defp feed(opts), do: Config.opt(opts, :feed, Supervisor.feed_name(opts))

  # The four reads that return a plain value (`coverage/1`, `wanted/1`, `coverage_by_kind/1`,
  # `status/1`) have no room for an error, and an empty answer for bad options would be a
  # plausible "nothing covered". So options that are not a keyword list, or hold a key these
  # do not read, RAISE `ArgumentError` (`Options.check!/2`, bounded inspect): a caller bug,
  # not a feed state.
  defp read_feed(function, opts, empty, reader) do
    :ok = Options.check!(function, opts)
    read_running(feed(opts), empty, reader)
  end

  defp read_running(feed, empty, reader) do
    if alive?(feed), do: feed_read(fn -> reader.(feed) end, empty), else: empty
  end

  # `{:global, _}` and `{:via, _, _}` feeds are running feeds too: `Process.whereis/1` only
  # knows local atoms, so a registered-elsewhere feed read as absent and coverage answered
  # empty for a live one. `GenServer.whereis/1` resolves every `GenServer.server()` shape.
  #
  # **A pid on another node is not running, as far as this facade can say.** `Process.alive?/1`
  # raises `ArgumentError` for a remote pid, which took down the caller of `coverage/1`,
  # `status/1`, `subscribe/2` and `update_credentials/2`. A feed is local to the node that
  # supervises it; a remote one answers `%{}` / `{:error, :feed_not_started}` rather than raising.
  defp alive?(pid) when is_pid(pid) and node(pid) != node(), do: false
  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive?(server), do: is_pid(GenServer.whereis(server))

  # **A streaming call answers; it does not exit in the caller's process.** Every
  # streaming callback's spec is a value (`:ok | {:error, term()}`, or a map). A bare
  # `GenServer.call/3` into `Feed` exits the caller instead: with `:noproc` when no `Feed` is
  # running, and with `:timeout` when one is too busy to answer within its call budget.
  # This facade checked `alive?/1` first, which covered a `Feed` never started. Three
  # sibling venues did not, and exited `:noproc` there (measured 2026-09-27). But the check
  # still raced a `Feed` that died between it and the call, and did nothing for a busy
  # one, so the exit is caught at the call itself. A reply that arrives after a timeout is
  # dropped by OTP's call aliases, so it cannot reach the caller's mailbox later.
  defp feed_call(call, not_running) do
    call.()
  catch
    :exit, {:noproc, _call} -> not_running
    :exit, {:timeout, _call} -> {:error, :feed_timeout}
    :exit, {reason, _call} -> {:error, {:feed_exited, reason}}
  end

  # `coverage/1` and `coverage_by_kind/1` return a map, with no room for an error. Any
  # failure is the empty answer, which says "not observed" and never claims delivery nobody
  # confirmed.
  defp feed_read(call, empty) do
    call.()
  catch
    :exit, _reason -> empty
  end

  # **Symbols are upper-cased on the way in.** Canonical symbols are upper case, and `Feed`
  # drops a payload whose symbol it does not want. So a caller who subscribed `btc-usd` got
  # nothing at all, because the venue delivers `BTC-USD`. Until 2026-09-27 that same caller
  # was delivered to, because nothing compared the two. Measured 2026-09-28:
  # `update_symbols(["btc-usd"])`, then a `BTC-USD` quote, and `coverage/1` was `%{}`.
  # Case is the one difference normalised here. Anything else that is not canonical is the
  # caller's to fix.
  #
  # Only ever called on a list `Feed.check_symbols/1` has already passed, so every element is a
  # string: a non-list, or a non-string element, is refused there and cannot reach this.
  defp canonical_case(symbols), do: Enum.map(symbols, &String.upcase/1)

  # --- Declared but not yet implemented -----------------------------------
  #
  # Core 0.1.16 widened the facade to the surface the venues actually publish. The five
  # implemented reads that open this section (`get_positions/1`, `get_option_chain/2`,
  # `get_option_expirations/2`, `get_screener/2`, `get_transactions/2`) are `:experimental`.
  # Every callback after them answers `{:error, :not_supported}` and is declared
  # `:unsupported` in `capabilities/0`, so a consumer routing on the declaration is told the
  # truth.
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
  def get_positions(opts) do
    with :ok <- Options.check(:get_positions, opts) do
      Rest.get_positions(Keyword.get(opts, :credentials, %{}), with_limiter(opts))
    end
  end

  @doc """
  The option chain for an underlying — expiry × strike, both sides.

  See `DpExchange.Schwab.Rest.get_option_chain/3`. `underlying_price` is carried only when
  the venue sent it, which needs `include_underlying_quote: true`.
  """
  @impl true
  def get_option_chain(underlying, opts) do
    with :ok <- Rest.check_underlying(underlying),
         :ok <- Options.check(:get_option_chain, opts) do
      Rest.get_option_chain(underlying, Keyword.get(opts, :credentials, %{}), with_limiter(opts))
    end
  end

  @doc """
  The expiries listed on an underlying.

  See `DpExchange.Schwab.Rest.get_option_expirations/3` — its own endpoint, not a narrowing
  of the chain.
  """
  @impl true
  def get_option_expirations(underlying, opts) do
    with :ok <- Rest.check_underlying(underlying),
         :ok <- Options.check(:get_option_expirations, opts) do
      Rest.get_option_expirations(
        underlying,
        Keyword.get(opts, :credentials, %{}),
        with_limiter(opts)
      )
    end
  end

  @doc """
  A mover list, by the venue's own universe — `movers_universes/0` lists them.

  See `DpExchange.Schwab.Rest.get_screener/3`. The rank is the position the venue returned
  the row in; nothing is re-ranked.
  """
  @impl true
  def get_screener(name, opts) do
    with :ok <- Rest.check_movers_universe(name),
         :ok <- Options.check(:get_screener, opts) do
      Rest.get_screener(name, Keyword.get(opts, :credentials, %{}), with_limiter(opts))
    end
  end

  @doc """
  Transactions on one account.

  `opts[:account_hash]`, `opts[:from]`, `opts[:to]` and `opts[:types]` are all required —
  the last three by the venue, and the first because every Schwab account endpoint addresses
  by the encrypted hash `get_accounts/2` returns. See
  `DpExchange.Schwab.Rest.get_transactions/3`, including why there is no "all types".

  A missing `opts[:account_hash]` is `{:error, {:missing_option, :account_hash}}`, the same
  answer every other account endpoint here gives (it was `{:missing_account_hash, :schwab}`,
  and before that `{:account_hash_required, :schwab}` on this function alone).
  """
  @impl true
  def get_transactions(credentials, opts) do
    with :ok <- Options.check(:get_transactions, opts),
         {:ok, hash} <- account_hash(opts) do
      Rest.get_transactions(credentials, hash, with_limiter(opts))
    end
  end

  @doc """
  One transaction by id. See `DpExchange.Schwab.Rest.get_transaction/4`.

  The venue documents an array here, so the body comes back as sent: an object or a list.
  """
  @spec get_transaction(map(), String.t(), integer() | String.t(), keyword()) ::
          {:ok, map() | [map()]} | {:error, term()} | {:refused, term()}
  def get_transaction(credentials, account_hash, transaction_id, opts \\ []) do
    with {:ok, _path} <- Rest.validate_transaction_path(account_hash, transaction_id),
         :ok <- Options.check(:get_transaction, opts) do
      Rest.get_transaction(credentials, account_hash, transaction_id, with_limiter(opts))
    end
  end

  @doc """
  Every account's balances, and its positions when asked.

  **Not `get_accounts/2`** — that reads `/accounts/accountNumbers` for the hashes every
  other endpoint addresses by. See `DpExchange.Schwab.Rest.get_account_summaries/2`.
  """
  @spec get_account_summaries(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_account_summaries(credentials, opts \\ []) do
    with :ok <- Options.check(:get_account_summaries, opts) do
      Rest.get_account_summaries(credentials, with_limiter(opts))
    end
  end

  @doc """
  Orders across every account. `opts[:from]` and `opts[:to]` are required by the venue.

  See `DpExchange.Schwab.Rest.get_all_orders/2`. `get_orders/2` is the per-account read.
  """
  @spec get_all_orders(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_all_orders(credentials, opts \\ []) do
    with :ok <- Options.check(:get_all_orders, opts) do
      Rest.get_all_orders(credentials, with_limiter(opts))
    end
  end

  @doc """
  One symbol's quote, unnormalised. See `DpExchange.Schwab.Rest.get_symbol_quote/3`.
  """
  @spec get_symbol_quote(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_symbol_quote(symbol, credentials, opts \\ []) do
    with :ok <- SymbolFormat.check_present(symbol),
         :ok <- Options.check(:get_symbol_quote, opts) do
      Rest.get_symbol_quote(symbol, credentials, with_limiter(opts))
    end
  end

  @doc "One market's hours, optionally on another day. See `DpExchange.Schwab.Rest.get_market/3`."
  @spec get_market(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_market(market, credentials, opts \\ []) do
    with :ok <- Rest.check_market(market),
         :ok <- Options.check(:get_market, opts) do
      Rest.get_market(market, credentials, with_limiter(opts))
    end
  end

  @doc "One instrument by CUSIP. See `DpExchange.Schwab.Rest.get_instrument/3`."
  @spec get_instrument(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_instrument(cusip, credentials, opts \\ []) do
    with :ok <- Rest.check_cusip(cusip),
         :ok <- Options.check(:get_instrument, opts) do
      Rest.get_instrument(cusip, credentials, with_limiter(opts))
    end
  end

  @doc """
  The signed-in user's preferences — the same endpoint the streamer bootstraps from.

  See `DpExchange.Schwab.Rest.get_user_preference/2`. The venue documents an array of
  preferences, so the body comes back as sent: an object or a list.
  """
  @spec get_user_preference(map(), keyword()) ::
          {:ok, map() | [map()]} | {:error, term()} | {:refused, term()}
  def get_user_preference(credentials, opts \\ []) do
    with :ok <- Options.check(:get_user_preference, opts) do
      Rest.get_user_preference(credentials, with_limiter(opts))
    end
  end

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

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.list_payment_methods/2`.
  """
  @impl true
  def list_payment_methods(_credentials, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_payment_method/3`.
  """
  @impl true
  def get_payment_method(_credentials, _id, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.add_payment_method/2`.
  """
  @impl true
  def add_payment_method(_details, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.transfer_internal/4`.
  """
  @impl true
  def transfer_internal(_asset, _amount, _opts, _request_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.request_approved_address/4`.
  """
  @impl true
  def request_approved_address(_asset, _network, _address, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.remove_approved_address/3`.
  """
  @impl true
  def remove_approved_address(_network, _address, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.list_networks/2`.
  """
  @impl true
  def list_networks(_asset, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.list_fee_promos/1`.
  """
  @impl true
  def list_fee_promos(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_fx_rate/3`.
  """
  @impl true
  def get_fx_rate(_pair, _at, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_notional_balances/3`.
  """
  @impl true
  def get_notional_balances(_credentials, _currency, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.list_custody_fees/2`.
  """
  @impl true
  def list_custody_fees(_credentials, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_funding/2`.
  """
  @impl true
  def get_funding(_symbol, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_contract_stats/2`.
  """
  @impl true
  def get_contract_stats(_symbol, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_staking_rates/1`.
  """
  @impl true
  def get_staking_rates(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_staking_balances/1`.
  """
  @impl true
  def get_staking_balances(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_staking_rewards/1`.
  """
  @impl true
  def get_staking_rewards(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_staking_history/1`.
  """
  @impl true
  def get_staking_history(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.stake/3`.
  """
  @impl true
  def stake(_asset, _amount, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.unstake/3`.
  """
  @impl true
  def unstake(_asset, _amount, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.quote_conversion/4`.
  """
  @impl true
  def quote_conversion(_from, _to, _amount, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.commit_conversion/2`.
  """
  @impl true
  def commit_conversion(_id, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_conversion/2`.
  """
  @impl true
  def get_conversion(_id, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.convert/4`.
  """
  @impl true
  def convert(_from, _to, _amount, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_trade_volume/2`.
  """
  @impl true
  def get_trade_volume(_credentials, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.list_portfolios/1`.
  """
  @impl true
  def list_portfolios(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_deposit_address/3`.
  """
  @impl true
  def get_deposit_address(_asset, _network, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.list_approved_addresses/1`.
  """
  @impl true
  def list_approved_addresses(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.estimate_withdrawal_fee/4`.
  """
  @impl true
  def estimate_withdrawal_fee(_asset, _network, _amount, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.withdraw/5`.
  """
  @impl true
  def withdraw(_asset, _network, _amount, _address, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_option_greeks/2`.
  """
  @impl true
  def get_option_greeks(_symbol, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.list_watchlists/1`.
  """
  @impl true
  def list_watchlists(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_watchlist/2`.
  """
  @impl true
  def get_watchlist(_id, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.create_watchlist/3`.
  """
  @impl true
  def create_watchlist(_name, _symbols, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.update_watchlist/2`.
  """
  @impl true
  def update_watchlist(_id, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.delete_watchlist/2`.
  """
  @impl true
  def delete_watchlist(_id, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_financials/3`.
  """
  @impl true
  def get_financials(_symbol, _kind, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_corporate_events/1`.
  """
  @impl true
  def get_corporate_events(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_filings/2`.
  """
  @impl true
  def get_filings(_symbol, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_news/1`.
  """
  @impl true
  def get_news(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.create_account/1`.
  """
  @impl true
  def create_account(_opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.rename_account/3`.
  """
  @impl true
  def rename_account(_id, _name, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_roles/1`.
  """
  @impl true
  def get_roles(_opts), do: Venue.not_supported()
end
