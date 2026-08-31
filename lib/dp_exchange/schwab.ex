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

  Four things, and each shows up in the contract rather than being smoothed over:

  **A symbol is one instrument, not a pair.** Every other venue in the family addresses
  `BASE-QUOTE`. Here `AAPL` names a single security and what you pay with is USD because
  the venue is a US broker. `SymbolFormat` therefore *refuses* pair-shaped input instead of
  splitting it — `BTC`, `ETH` and `SOL` are all real listed equity tickers, so a misrouted
  crypto pair has a plausible wrong answer waiting for it.

  **The market closes.** `market_status/1` is answered from `/markets`, not assumed. A feed
  delivering nothing at 3am is correct, and a consumer that alarms on silence would alarm
  every night — making a real outage indistinguishable from a Saturday.

  **The host authenticates; this package signs and refreshes.** The initial grant is
  three-legged OAuth through a browser and a person, which no library can do. Everything
  after is mechanical: the access token lives 30 minutes and `Auth.refresh/2` renews it,
  minting a new refresh token each time with a fresh seven days. A host that keeps
  refreshing never needs a person again.

  **There is no order book and no socket.** Neither specification describes depth or
  streaming, so `get_order_book/2` is `:unsupported` and the feed is a poll. Schwab
  publishes a separate Thinkorswim product where a streaming surface would live; it is out
  of scope here and named so a reader knows where to look.

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
  def get_order_book(_symbol, _opts \\ []), do: Venue.not_supported()

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
end
