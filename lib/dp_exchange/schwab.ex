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

  **`get_order_book/2` is `:unsupported`, and the reason matters more than the value.**
  It used to read "there is no order book and no socket" — a claim about the venue, and
  wrong. The venue has both. **This package** has neither yet: the REST API returns no
  depth, and the WebSocket **Streamer** that does — `NYSE_BOOK`, `NASDAQ_BOOK`,
  `OPTIONS_BOOK` — is not implemented here. The value stays `:unsupported` because that is
  still true of this package today; the reason changes because the old one was false and
  would have stopped anyone looking.

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
  alias DpExchange.Schwab.{Capabilities, Feed, Orders, Rest, Supervisor}

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

  @doc "Canonical candle widths this venue serves."
  @spec quotes() :: [String.t()]
  def quotes, do: ["USD"]

  # --- lifecycle ----------------------------------------------------------

  @impl true
  def child_spec(opts) do
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

  @impl true
  def place_order(credentials, request, opts \\ []) do
    with {:ok, hash} <- account_hash(opts),
         {:ok, payload} <- Orders.build(request, opts) do
      Rest.place_order(credentials, hash, payload, with_limiter(opts))
    end
  end

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
  """
  @impl true
  def replace_order(credentials, order_id, request, opts \\ []) do
    with {:ok, hash} <- account_hash(opts),
         {:ok, payload} <- Orders.build(request, opts) do
      Rest.replace_order(credentials, hash, order_id, payload, with_limiter(opts))
    end
  end

  @impl true
  def cancel_order(credentials, order_id, opts \\ []) do
    with {:ok, hash} <- account_hash(opts) do
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

  # --- streaming, which here is a poll ------------------------------------

  @impl true
  def subscribe(symbols, opts \\ []) do
    feed = feed(opts)

    if alive?(feed) do
      current = feed |> Feed.coverage() |> Map.keys()
      Feed.update_symbols(feed, Enum.uniq(current ++ symbols))
    else
      {:error, :feed_not_started}
    end
  end

  @impl true
  def unsubscribe(symbols, opts \\ []) do
    feed = feed(opts)

    if alive?(feed) do
      remaining = feed |> Feed.coverage() |> Map.keys() |> Enum.reject(&(&1 in symbols))
      Feed.update_symbols(feed, remaining)
    else
      :ok
    end
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
  Refusals reach the subscriber through the same mailbox as quotes, so a caller
  registering here receives them.
  """
  @impl true
  def subscribe_notices(_opts \\ []), do: :ok

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
  """
  @impl true
  def get_transactions(credentials, opts) do
    case Keyword.get(opts, :account_hash) do
      hash when is_binary(hash) -> Rest.get_transactions(credentials, hash, opts)
      _missing -> {:error, {:account_hash_required, :schwab}}
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
