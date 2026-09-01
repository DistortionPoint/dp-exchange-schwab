defmodule DpExchange.Schwab.Fake do
  @moduledoc """
  An in-process stand-in for this venue, for consumers' tests.

  ## It refuses what the real venue refuses

  A fake that answers where the real one would refuse is worse than no fake: it lets a
  consumer's test suite go green against behaviour that cannot happen. So this one
  reproduces the refusals, not just the successes — a pair-shaped symbol, a missing
  credential, a year of one-minute candles, an instruction that does not match the asset
  type. Each is the same error the real package returns, from the same module.

  ## It closes the market on request

  `market_status/1` answers `:open` by default and `:closed` when told to, because a
  consumer testing an equities venue needs to exercise the overnight path — the one where
  a feed delivering nothing is correct. Every other venue in the family is always open,
  so this is the only place that path can be tested at all.

  Starts nothing. `start_link/1` returns `:ignore`, so a consumer that swaps this in does
  not find a process it did not ask for.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.Types.{Balance, Candle, Quote, TopOfBook}
  alias DpExchange.Core.Venue
  alias DpExchange.Schwab
  alias DpExchange.Schwab.{Orders, Rest, SymbolFormat}

  @listed ~w(AAPL MSFT GOOGL AMZN NVDA F BRK.B)

  @prices %{
    "AAPL" => "227.50",
    "MSFT" => "418.20",
    "GOOGL" => "165.90",
    "AMZN" => "182.30",
    "NVDA" => "121.40",
    "F" => "10.85",
    "BRK.B" => "455.10"
  }

  # A fixed instant, not `DateTime.utc_now/0`. A fake whose timestamps move makes a
  # consumer's assertions flap, and the family's own rule is that a timestamp is the
  # venue's claim about an instant — so the fake states one.
  @as_of ~U[2026-08-31 14:30:00Z]

  @doc "Symbols this fake lists."
  @spec listed() :: [String.t()]
  def listed, do: @listed

  @doc "The instant every value from this fake is stamped with."
  @spec as_of() :: DateTime.t()
  def as_of, do: @as_of

  # --- identity -----------------------------------------------------------

  @impl true
  def provider_name, do: Schwab.provider_name()

  @impl true
  def runtime_id, do: Schwab.runtime_id()

  @impl true
  def asset_classes, do: Schwab.asset_classes()

  @impl true
  def capabilities, do: Schwab.capabilities()

  @doc "Endpoints the venue does not serve."
  @spec venue_does_not_serve() :: [{atom(), arity()}]
  defdelegate venue_does_not_serve, to: Schwab

  @doc "Quote currencies."
  @spec quotes() :: [String.t()]
  defdelegate quotes, to: Schwab

  @impl true
  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def start_link(_opts), do: :ignore

  # --- market data --------------------------------------------------------

  @impl true
  def get_price(symbol, opts \\ []) do
    with :ok <- require_credentials(opts),
         {:ok, native} <- SymbolFormat.validate(symbol),
         {:ok, price} <- fetch_price(native) do
      {:ok,
       %Quote{
         symbol: native,
         price: Decimal.new(price),
         volume: Decimal.new("1000000"),
         timestamp: @as_of,
         provider: :schwab
       }}
    end
  end

  @impl true
  def get_top_of_book(symbol, opts \\ []) do
    with :ok <- require_credentials(opts),
         {:ok, native} <- SymbolFormat.validate(symbol),
         {:ok, price} <- fetch_price(native) do
      {:ok,
       %TopOfBook{
         symbol: native,
         bid: price |> Decimal.new() |> Decimal.sub(Decimal.new("0.01")),
         ask: price |> Decimal.new() |> Decimal.add(Decimal.new("0.01")),
         bid_size: Decimal.new("100"),
         ask_size: Decimal.new("200"),
         venue_time: @as_of,
         observed_at: @as_of,
         provider: :schwab
       }}
    end
  end

  defp fetch_price(native) do
    case Map.fetch(@prices, native) do
      {:ok, price} -> {:ok, price}
      :error -> {:refused, :not_listed}
    end
  end

  @impl true
  def get_historical_prices(symbol, timeframe, range, opts \\ []) do
    with :ok <- require_credentials(opts),
         {:ok, native} <- SymbolFormat.validate(symbol),
         :ok <- check_timeframe(timeframe),
         :ok <- check_lookback(timeframe, range),
         {:ok, price} <- fetch_price(native) do
      {:ok,
       for offset <- 4..0//-1 do
         base = Decimal.new(price)

         %Candle{
           symbol: native,
           timeframe: timeframe,
           opened_at: DateTime.add(@as_of, -offset * 60, :second),
           # A bar with four distinct prices. A fake whose OHLC all equal one number cannot
           # catch a caller that reads the wrong one.
           open: Decimal.sub(base, Decimal.new("0.50")),
           high: Decimal.add(base, Decimal.new("1.00")),
           low: Decimal.sub(base, Decimal.new("1.00")),
           close: base,
           volume: Decimal.new("250000"),
           provider: :schwab
         }
       end}
    end
  end

  defp check_timeframe(timeframe) do
    if timeframe in Rest.timeframes(),
      do: :ok,
      else: {:error, {:unsupported_timeframe, timeframe}}
  end

  # The refusal that matters, reproduced: minute widths cap at ten days.
  defp check_lookback(timeframe, range) do
    with {:ok, max_days} <- Rest.max_lookback_days(timeframe),
         %DateTime{} = start <- Keyword.get(range, :start) do
      days = @as_of |> DateTime.diff(start, :second) |> div(86_400)

      if days > max_days,
        do: {:error, {:lookback_exceeds_venue, timeframe, days, max_days}},
        else: :ok
    else
      _no_range_or_width -> :ok
    end
  end

  @impl true
  def get_symbols(opts \\ []) do
    with :ok <- require_credentials(opts) do
      case Keyword.get(opts, :query) do
        query when is_binary(query) and query != "" ->
          {:ok, Enum.filter(@listed, &String.starts_with?(&1, String.upcase(query)))}

        _absent ->
          {:error, {:query_required, :schwab}}
      end
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
  def get_market_overview(_opts \\ []), do: Venue.not_supported()

  @impl true
  def list_instruments(_opts \\ []), do: Venue.not_supported()

  @doc """
  Open by default, closed on request.

  The only place in the family where a consumer can exercise the closed-market path.
  """
  @impl true
  def market_status(opts \\ []) do
    with :ok <- require_credentials(opts) do
      {:ok, Keyword.get(opts, :market_status, :open)}
    end
  end

  @impl true
  def quantization(_symbol), do: Venue.not_supported()

  # --- accounts and trading -----------------------------------------------

  @impl true
  def get_accounts(credentials, opts \\ []) do
    with :ok <- require_credentials(credentials: credentials) do
      {:ok, [%{account_number: "123456789", hash: Keyword.get(opts, :account_hash, "FAKEHASH")}]}
    end
  end

  @impl true
  def get_balances(credentials, opts \\ []) do
    with :ok <- require_credentials(credentials: credentials),
         {:ok, _hash} <- require_account(opts) do
      {:ok,
       [
         %Balance{
           currency: "USD",
           balance: Decimal.new("50000.00"),
           available_balance: Decimal.new("100000.00"),
           hold: nil,
           timestamp: @as_of,
           provider: :schwab
         }
       ]}
    end
  end

  @impl true
  def get_fees(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_transfers(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def place_order(credentials, request, opts \\ []) do
    with :ok <- require_credentials(credentials: credentials),
         {:ok, _hash} <- require_account(opts),
         # The real refusals, from the real module — a fake that accepted an order the
         # venue publishes as invalid would green-light code that cannot work.
         {:ok, _payload} <- Orders.build(request, opts) do
      {:ok, "fake-order-1"}
    end
  end

  # Both are real on this venue, so the fake answers rather than refusing — and it builds
  # through `Orders` for the same reason `place_order/3` does: an order the venue
  # publishes as invalid must be refused here too.
  @impl true
  def preview_order(credentials, request, opts \\ []) do
    with :ok <- require_credentials(credentials: credentials),
         {:ok, _hash} <- require_account(opts),
         {:ok, _payload} <- Orders.build(request, opts) do
      {:ok,
       %{
         "orderStrategy" => %{"orderType" => "MARKET"},
         "orderValidationResult" => %{"rejects" => []},
         "commissionAndFee" => %{"commission" => %{}}
       }}
    end
  end

  @impl true
  def replace_order(credentials, _order_id, request, opts \\ []) do
    with :ok <- require_credentials(credentials: credentials),
         {:ok, _hash} <- require_account(opts),
         {:ok, _payload} <- Orders.build(request, opts) do
      # A replacement is a NEW order on this venue, so the id differs from the one
      # replaced. A fake returning the old id would hide that from a consumer's test.
      {:ok, "fake-order-2"}
    end
  end

  @impl true
  def cancel_order(credentials, _order_id, opts \\ []) do
    with :ok <- require_credentials(credentials: credentials),
         {:ok, _hash} <- require_account(opts) do
      :ok
    end
  end

  @impl true
  def get_order(credentials, order_id, opts \\ []) do
    with :ok <- require_credentials(credentials: credentials),
         {:ok, _hash} <- require_account(opts) do
      {:ok, %{"orderId" => order_id, "status" => "FILLED"}}
    end
  end

  @impl true
  def get_orders(credentials, opts \\ []) do
    with :ok <- require_credentials(credentials: credentials),
         {:ok, _hash} <- require_account(opts) do
      {:ok, []}
    end
  end

  @impl true
  def get_trade_history(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def test_connection(credentials, opts \\ []) do
    with {:ok, accounts} <- get_accounts(credentials, opts) do
      {:ok, %{accounts: length(accounts)}}
    end
  end

  @impl true
  def get_rate_limit_status(_credentials, _opts \\ []), do: Venue.not_supported()

  # --- streaming ----------------------------------------------------------

  @impl true
  def subscribe(symbols, opts \\ []) do
    to = Keyword.get(opts, :to, self())
    covered = Enum.filter(symbols, &(&1 in @listed))

    Process.put(__MODULE__, Enum.uniq(subscribed() ++ covered))

    for symbol <- covered do
      {:ok, quote_struct} = get_price(symbol, credentials: %{access_token: "fake"})
      send(to, {:dp_exchange, :schwab, quote_struct})
    end

    :ok
  end

  @impl true
  def unsubscribe(symbols, _opts \\ []) do
    Process.put(__MODULE__, Enum.reject(subscribed(), &(&1 in symbols)))
    :ok
  end

  @impl true
  def update_symbols(symbols, opts \\ []) do
    Process.put(__MODULE__, [])
    subscribe(symbols, opts)
  end

  @impl true
  def coverage(_opts \\ []), do: Map.new(subscribed(), &{&1, :internal_poll})

  @impl true
  def subscribe_notices(_opts \\ []), do: :ok

  defp subscribed, do: Process.get(__MODULE__, [])

  # --- plumbing -----------------------------------------------------------

  # Market data needs credentials here exactly as it does on the real venue. A fake that
  # served quotes anonymously would let a consumer build a code path the venue rejects.
  defp require_credentials(opts) do
    case Keyword.get(opts, :credentials) do
      %{} = credentials when map_size(credentials) > 0 -> :ok
      _absent -> {:refused, :missing_credentials}
    end
  end

  defp require_account(opts) do
    case Keyword.get(opts, :account_hash) do
      hash when is_binary(hash) and hash != "" -> {:ok, hash}
      _absent -> {:error, {:missing_account_hash, :schwab}}
    end
  end

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

  @impl true
  def get_positions(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_funding(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_contract_stats(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_rates(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_balances(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_rewards(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_history(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def stake(_asset, _amount, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def unstake(_asset, _amount, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def quote_conversion(_from, _to, _amount, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def commit_conversion(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_conversion(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def list_portfolios(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_deposit_address(_asset, _network, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def list_approved_addresses(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def estimate_withdrawal_fee(_asset, _network, _amount, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def withdraw(_asset, _network, _amount, _address, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_option_chain(_underlying, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_option_expirations(_underlying, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_option_greeks(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def list_watchlists(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def create_watchlist(_name, _symbols, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def update_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def delete_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_financials(_symbol, _kind, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_corporate_events(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_filings(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_news(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_screener(_name, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def create_account(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def rename_account(_id, _name, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_roles(_opts \\ []), do: DpExchange.Core.Venue.not_supported()
end
