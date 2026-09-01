defmodule DpExchange.Schwab.Rest do
  @moduledoc """
  Schwab's REST surface — internal.

  ## Every call is signed, market data included

  There is no anonymous endpoint on this venue. A quote needs the same bearer token an
  order does, which is why `credential_benefit` is `:required` and why every function
  here takes credentials.

  ## Two servers, one package

  Market data lives at `/marketdata/v1` and accounts and trading at `/trader/v1`. They
  are separate API products on Schwab's portal with separate specifications, and a
  consumer sees neither — which is the facade doing its job (D12).

  ## The candle triple

  `/pricehistory` does not take a width. It takes `periodType`, `period`, `frequencyType`
  and `frequency`, and the legal combinations are constrained in both directions. This
  module owns the translation from a canonical width like `"5m"` to that quadruple, and
  **refuses a width the venue cannot serve rather than picking the nearest one** — see
  `timeframes/0`.

  The refusal that matters is not the unknown width. It is the *reachable* one: minute
  candles require `periodType=day`, which caps the lookback at ten days. A caller asking
  for a year of one-minute data is asking for something this venue does not have, and
  answering with ten days of it, or with daily candles, would be a plausible wrong answer
  of exactly the kind this family exists to refuse.

  ## The market closes

  `market_status/1` is answered from `/markets`, not assumed. This is the first venue in
  the family where a feed delivering nothing is usually correct rather than broken, and
  guessing `:open` would make a real outage indistinguishable from a Saturday.

  ## A pull requires a query

  `get_symbols/1` takes a `:query`, because `/instruments` has no list-everything
  projection — all six of its projections search against a term. Without one it returns
  `{:error, {:query_required, :schwab}}` and sends nothing.

  ## Accounts are addressed by a hash, and getting one is a prerequisite

  `/accounts/accountNumbers` returns account numbers **and** their encrypted hashes, and
  every other account path takes the hash. So `get_accounts/2` is not a convenience here;
  it is the first call any trading flow has to make.

  Balances read the account's own declared `type`. A `MarginAccount` and a `CashAccount`
  carry entirely different fields, and an account whose type the venue did not state is
  `{:error, :unexpected_response_shape}` rather than assumed to be either — reading a
  margin account as cash would report no buying power for an account that has one.

  ## Placing an order returns an id from a header, or fails

  Schwab answers a placed order with `201` and an **empty body**; the id is in `Location`.
  A `201` with no `Location` returns `{:error, :order_id_not_returned}` rather than
  success, because a caller that cannot name the order it just placed cannot cancel it.
  """

  alias DpExchange.Core.HttpClient

  alias DpExchange.Core.Types.{
    Candle,
    OptionChain,
    OptionContract,
    Position,
    Quote,
    ScreenerResult,
    TopOfBook
  }

  alias DpExchange.Schwab.{Auth, SymbolFormat}

  @market_data_url "https://api.schwabapi.com/marketdata/v1"
  @trader_url "https://api.schwabapi.com/trader/v1"

  # Canonical width => {periodType, frequencyType, frequency}. `period` is chosen
  # separately from the caller's range, because it is a *lookback*, not part of the
  # width.
  #
  # Read from the OpenAPI document's own parameter descriptions, which constrain each
  # axis by the one above it. See docs/reference/schwab/spec-facts.md §1 for the table.
  @candles %{
    "1m" => {"day", "minute", 1},
    "5m" => {"day", "minute", 5},
    "10m" => {"day", "minute", 10},
    "15m" => {"day", "minute", 15},
    "30m" => {"day", "minute", 30},
    "1d" => {"year", "daily", 1},
    "1w" => {"year", "weekly", 1},
    "1M" => {"year", "monthly", 1}
  }

  # Legal `period` values per `periodType`, verbatim from the spec. A period outside its
  # list is rejected by the venue, so it is rejected here instead — locally, by name.
  @periods %{
    "day" => [1, 2, 3, 4, 5, 10],
    "month" => [1, 2, 3, 6],
    "year" => [1, 2, 3, 5, 10, 15, 20],
    "ytd" => [1]
  }

  @doc "Market-data base URL, overridable for tests."
  @spec market_data_url(keyword()) :: String.t()
  def market_data_url(opts), do: Keyword.get(opts, :market_data_url, @market_data_url)

  @doc "Trader base URL, overridable for tests."
  @spec trader_url(keyword()) :: String.t()
  def trader_url(opts), do: Keyword.get(opts, :trader_url, @trader_url)

  @doc "Canonical candle widths this venue serves, shortest first."
  @spec timeframes() :: [String.t()]
  def timeframes, do: ~w(1m 5m 10m 15m 30m 1d 1w 1M)

  @doc """
  The deepest lookback a width can reach, in days.

  Minute widths are only reachable through `periodType=day`, whose largest legal `period`
  is 10. This is the number a caller needs before asking for a year of one-minute data,
  and `get_historical_prices/4` refuses rather than truncating silently.
  """
  @spec max_lookback_days(String.t()) :: {:ok, pos_integer()} | :error
  def max_lookback_days(timeframe) do
    case Map.fetch(@candles, timeframe) do
      {:ok, {period_type, _frequency_type, _frequency}} ->
        {:ok,
         period_type |> then(&Map.fetch!(@periods, &1)) |> Enum.max() |> days_for(period_type)}

      :error ->
        :error
    end
  end

  # Days in one unit of each `periodType`, rounded **up** — a lookback bound that
  # overstated its reach would let a request through that the venue then truncates
  # silently, which is the failure this whole module is arranged to prevent. Overstating
  # the days per unit understates nothing: it only makes the bound stricter.
  #
  # `month` and `ytd` are unreachable from `@candles` today, and are carried anyway
  # because `@periods` is the venue's own table and a partial conversion is how a width
  # added later picks the wrong lookback without anyone noticing.
  @days_per_unit %{"day" => 1, "month" => 31, "year" => 366, "ytd" => 366}

  defp days_for(period, period_type), do: period * Map.fetch!(@days_per_unit, period_type)

  # --- market data --------------------------------------------------------

  @doc """
  A quote for one symbol.

  Timestamped from the venue's own `quoteTime`. A quote the venue did not date returns
  `{:error, :missing_venue_timestamp}` — the local clock is never substituted.
  """
  @spec get_price(String.t(), map(), keyword()) ::
          {:ok, Quote.t()} | {:error, term()} | {:refused, term()}
  def get_price(symbol, credentials, opts) do
    with {:ok, native} <- SymbolFormat.validate(symbol),
         path = "/quotes?symbols=" <> URI.encode(native) <> "&indicative=false",
         {:ok, body} <- get(market_data_url(opts) <> path, credentials, opts),
         {:ok, row} <- quote_row(body, native) do
      build_quote(native, row)
    end
  end

  # The response is keyed by symbol, and a symbol the venue does not list comes back
  # either absent or as a `QuoteError`. Both are refusals rather than errors: they are
  # permanent for this symbol and retrying changes nothing.

  @doc """
  Best bid and ask for `symbol` — the top of the book, not a traded price.

  Reads the same `/quotes` payload as `get_price/3`, which carries `bidPrice`, `askPrice`,
  `bidSize` and `askSize` alongside the last trade. Those used to ride on the `Quote`;
  `Core.Types.Quote` has no fields for them now.

  **This is not the venue's order book.** Schwab publishes depth over its WebSocket Streamer
  (`NYSE_BOOK`, `NASDAQ_BOOK`, `OPTIONS_BOOK`), which this package does not speak yet — see
  `get_order_book/2`. This is the top of it, from REST.
  """
  @spec get_top_of_book(String.t(), map(), keyword()) ::
          {:ok, TopOfBook.t()} | {:error, term()} | {:refused, term()}
  def get_top_of_book(symbol, credentials, opts) do
    with {:ok, native} <- SymbolFormat.validate(symbol),
         path = "/quotes?symbols=" <> URI.encode(native) <> "&indicative=false",
         {:ok, body} <- get(market_data_url(opts) <> path, credentials, opts),
         {:ok, row} <- quote_row(body, native) do
      {:ok,
       %TopOfBook{
         symbol: SymbolFormat.to_canonical_symbol(native),
         bid: decimal(row["bidPrice"]),
         ask: decimal(row["askPrice"]),
         bid_size: decimal(row["bidSize"]),
         ask_size: decimal(row["askSize"]),
         venue_time: top_of_book_time(row),
         observed_at: DateTime.utc_now(),
         provider: :schwab
       }}
    end
  end

  defp top_of_book_time(row) do
    case venue_time(row) do
      {:ok, at} -> at
      _no_venue_time -> nil
    end
  end

  defp quote_row(body, native) when is_map(body) do
    case Map.get(body, native) do
      %{"quote" => quote_map} when is_map(quote_map) -> {:ok, quote_map}
      %{"errors" => _errors} -> {:refused, :not_listed}
      nil -> {:refused, :not_listed}
      _other -> {:error, :unexpected_response_shape}
    end
  end

  defp quote_row(_other, _native), do: {:error, :unexpected_response_shape}

  defp build_quote(native, row) do
    with {:ok, price} <- quoted_price(row),
         {:ok, timestamp} <- venue_time(row) do
      {:ok,
       %Quote{
         symbol: SymbolFormat.to_canonical_symbol(native),
         price: decimal(price),
         volume: decimal(row["totalVolume"]),
         timestamp: timestamp,
         provider: :schwab
       }}
    end
  end

  # `lastPrice` is the trade price and is what a quote means here. `mark` is Schwab's own
  # derived value and is used only when there is no last — never a mid computed by us,
  # because what a price *means* is the caller's decision.
  defp quoted_price(row) do
    case row["lastPrice"] || row["mark"] do
      nil -> {:error, :unexpected_response_shape}
      "" -> {:error, :unexpected_response_shape}
      price -> {:ok, price}
    end
  end

  # `quoteTime` and `tradeTime` are epoch milliseconds on this venue.
  defp venue_time(row) do
    case row["quoteTime"] || row["tradeTime"] do
      nil -> {:error, :missing_venue_timestamp}
      "" -> {:error, :missing_venue_timestamp}
      raw -> parse_time(raw)
    end
  end

  defp parse_time(value) when is_integer(value) and value > 100_000_000_000,
    do: DateTime.from_unix(value, :millisecond)

  defp parse_time(value) when is_integer(value), do: DateTime.from_unix(value)

  defp parse_time(value) when is_binary(value) do
    case Integer.parse(value) do
      {epoch, ""} -> parse_time(epoch)
      _not_an_epoch -> {:error, {:unparseable_venue_timestamp, value}}
    end
  end

  defp parse_time(other), do: {:error, {:unparseable_venue_timestamp, other}}

  @doc """
  Candles for `symbol` at `timeframe`.

  Refuses rather than substitutes, in two distinct ways that mean different things:

  - `{:error, {:unsupported_timeframe, timeframe}}` — the venue does not serve this width
    at all.
  - `{:error, {:lookback_exceeds_venue, timeframe, requested_days, max_days}}` — the
    width exists but cannot reach that far back. Minute candles cap at ten days. This is
    the refusal that matters: answering with ten days, or with daily candles, would be a
    plausible wrong answer.
  """
  @spec get_historical_prices(String.t(), String.t(), keyword(), map(), keyword()) ::
          {:ok, [Quote.t()]} | {:error, term()} | {:refused, term()}
  def get_historical_prices(symbol, timeframe, range, credentials, opts) do
    with {:ok, native} <- SymbolFormat.validate(symbol),
         {:ok, {period_type, frequency_type, frequency}} <- fetch_candle(timeframe),
         {:ok, period} <- fetch_period(timeframe, period_type, range) do
      params = %{
        "symbol" => native,
        "periodType" => period_type,
        "period" => period,
        "frequencyType" => frequency_type,
        "frequency" => frequency,
        "needExtendedHoursData" => Keyword.get(opts, :extended_hours, false)
      }

      path = "/pricehistory?" <> URI.encode_query(params)

      with {:ok, body} <- get(market_data_url(opts) <> path, credentials, opts) do
        candles(body, native, timeframe)
      end
    end
  end

  defp fetch_candle(timeframe) do
    case Map.fetch(@candles, timeframe) do
      {:ok, triple} -> {:ok, triple}
      :error -> {:error, {:unsupported_timeframe, timeframe}}
    end
  end

  # The caller's requested range decides `period`, and a range the width cannot reach is
  # refused by name rather than clamped.
  defp fetch_period(timeframe, period_type, range) do
    legal = Map.fetch!(@periods, period_type)
    requested_days = requested_days(range)

    case requested_days do
      nil ->
        {:ok, Enum.max(legal)}

      days ->
        {:ok, max_days} = max_lookback_days(timeframe)

        if days > max_days do
          {:error, {:lookback_exceeds_venue, timeframe, days, max_days}}
        else
          {:ok, smallest_covering(legal, days, period_type)}
        end
    end
  end

  defp requested_days(range) do
    case {Keyword.get(range, :start), Keyword.get(range, :end)} do
      {%DateTime{} = start, %DateTime{} = finish} ->
        finish |> DateTime.diff(start, :second) |> div(86_400) |> max(1)

      {%DateTime{} = start, nil} ->
        DateTime.utc_now() |> DateTime.diff(start, :second) |> div(86_400) |> max(1)

      _no_range ->
        nil
    end
  end

  defp smallest_covering(legal, days, period_type) do
    legal
    |> Enum.sort()
    |> Enum.find(Enum.max(legal), fn period -> days_for(period, period_type) >= days end)
  end

  defp candles(%{"candles" => rows}, native, timeframe) when is_list(rows) do
    symbol = SymbolFormat.to_canonical_symbol(native)

    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case candle(symbol, timeframe, row) do
        {:ok, bar} -> {:cont, {:ok, [bar | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      error -> error
    end
  end

  # An empty series for a symbol the venue does not list. `empty: true` is Schwab's own
  # flag and is carried as a refusal, not as zero candles — a caller must be able to tell
  # "no data" from "no such symbol".
  defp candles(%{"empty" => true}, _native, _timeframe), do: {:refused, :not_listed}
  defp candles(_other, _native, _timeframe), do: {:error, :unexpected_response_shape}

  # A bar is a `Core.Types.Candle`, not a `Quote`.
  #
  # This used to build a Quote with `price: close`, on the reasoning that "an OHLC bar's
  # price, for a series, is where it ended". The close is a real number and it is not the
  # bar: open, high and low were being discarded at the boundary, and no caller could tell,
  # because what arrived was a well-formed Quote. Core 0.1.16 types this callback as
  # `[Types.Candle.t()]` and the four prices are carried.
  #
  # `:opened_at` — Schwab stamps a bar at its **open**, in epoch milliseconds.
  defp candle(symbol, timeframe, row) do
    # Timestamp first, deliberately. An undated bar is `:missing_venue_timestamp` — the
    # specific refusal this package is built around — and checking prices ahead of it would
    # report `:unexpected_response_shape` for a row whose real problem is that it cannot be
    # placed in time.
    with {:ok, timestamp} <- candle_time(row),
         {:ok, open} <- required(row, "open"),
         {:ok, high} <- required(row, "high"),
         {:ok, low} <- required(row, "low"),
         {:ok, close} <- required(row, "close") do
      {:ok,
       %Candle{
         symbol: symbol,
         timeframe: timeframe,
         opened_at: timestamp,
         open: decimal(open),
         high: decimal(high),
         low: decimal(low),
         close: decimal(close),
         volume: decimal(row["volume"]),
         provider: :schwab
       }}
    end
  end

  defp candle_time(%{"datetime" => nil}), do: {:error, :missing_venue_timestamp}
  defp candle_time(%{"datetime" => datetime}), do: parse_time(datetime)
  defp candle_time(_no_datetime), do: {:error, :missing_venue_timestamp}

  defp required(row, key) do
    case Map.get(row, key) do
      nil -> {:error, :unexpected_response_shape}
      "" -> {:error, :unexpected_response_shape}
      value -> {:ok, value}
    end
  end

  @doc """
  Whether the equity market is open, from the venue rather than from a guess.

  `/markets` answers `isOpen` directly. A venue that says nothing about a market returns
  `{:ok, :closed}` only when it explicitly says so — an absent market is
  `{:error, :unexpected_response_shape}`, because "the venue did not mention it" is not
  the same as "it is shut".
  """
  @spec market_status(map(), keyword()) ::
          {:ok, :open | :closed} | {:error, term()} | {:refused, term()}
  def market_status(credentials, opts) do
    market = Keyword.get(opts, :market, "equity")
    path = "/markets?markets=" <> URI.encode(market)

    with {:ok, body} <- get(market_data_url(opts) <> path, credentials, opts) do
      read_is_open(body, market)
    end
  end

  # The response nests: %{"equity" => %{"EQ" => %{"isOpen" => true}}}. The inner key is
  # a product code that varies, so it is searched rather than assumed.
  defp read_is_open(body, market) when is_map(body) do
    case Map.get(body, market) do
      products when is_map(products) and map_size(products) > 0 ->
        open? =
          Enum.any?(products, fn {_code, product} -> is_map(product) and product["isOpen"] end)

        {:ok, if(open?, do: :open, else: :closed)}

      _absent ->
        {:error, :unexpected_response_shape}
    end
  end

  defp read_is_open(_other, _market), do: {:error, :unexpected_response_shape}

  @doc """
  Symbols matching a search term.

  **This venue has no catalogue endpoint.** `/instruments` takes a `projection` —
  `symbol-search`, `symbol-regex`, `desc-search`, `desc-regex`, `search`, `fundamental` —
  and every one of them searches against a term. There is no "list everything", and there
  could not sensibly be: the catalogue is every US-listed equity and option.

  So a pull here requires a query, and one is refused *by name* when absent:
  `{:error, {:query_required, :schwab}}`. That is deliberately **not** `:not_supported` —
  the endpoint works, and the caller has to say what it wants. Returning the result of
  some arbitrary search instead would hand back a short list that looks like a catalogue,
  which is the plausible wrong answer this venue makes available.

  Pass `:query`, and optionally `:projection` (default `symbol-search`).
  """
  @spec get_symbols(map(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()} | {:refused, term()}
  def get_symbols(credentials, opts) do
    with {:ok, query} <- fetch_query(opts) do
      params = %{
        "symbol" => query,
        "projection" => Keyword.get(opts, :projection, "symbol-search")
      }

      path = "/instruments?" <> URI.encode_query(params)

      with {:ok, body} <- get(market_data_url(opts) <> path, credentials, opts) do
        instrument_symbols(body)
      end
    end
  end

  defp fetch_query(opts) do
    case Keyword.get(opts, :query) do
      query when is_binary(query) and query != "" -> {:ok, query}
      _absent -> {:error, {:query_required, :schwab}}
    end
  end

  defp instrument_symbols(%{"instruments" => rows}) when is_list(rows) do
    symbols =
      rows
      |> Enum.map(& &1["symbol"])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&SymbolFormat.to_canonical_symbol/1)
      |> Enum.sort()

    {:ok, symbols}
  end

  # A search that matched nothing is an empty list, not a refusal: "no instrument is
  # called that" is a real answer, unlike "no such endpoint".
  defp instrument_symbols(%{}), do: {:ok, []}
  defp instrument_symbols(_other), do: {:error, :unexpected_response_shape}

  # --- the rest of market data --------------------------------------------

  @doc """
  One symbol's quote — `GET /{symbol_id}/quotes`.

  **Not `get_price/2` narrowed to one.** The batch `/quotes` endpoint takes a list and this
  takes a path segment, and Schwab publishes both: a caller reading one symbol pays for one
  URL rather than a query string it has to build. `opts[:fields]` takes the venue's own
  comma-separated field groups — `quote`, `fundamental`, `extended`, `reference`, `regular`
  — and nothing is sent when it is absent, which is the venue asking for all of them.

  Returns the venue's own map keyed by symbol, unnormalised: `Types.Quote` carries one price
  and this endpoint's `fundamental` and `reference` blocks are neither prices nor quotes.
  `get_price/2` is the normalised read.
  """
  @spec get_symbol_quote(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_symbol_quote(symbol, credentials, opts) when is_binary(symbol) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    query = query_string(%{"fields" => Keyword.get(opts, :fields)})

    with {:ok, body} <-
           get(
             market_data_url(opts) <> "/#{URI.encode(native)}/quotes" <> query,
             credentials,
             opts
           ) do
      {:ok, body}
    end
  end

  @doc """
  An option chain — `GET /chains`.

  **Seventeen query parameters, and four of them are model inputs rather than filters.**
  `volatility`, `underlyingPrice`, `interestRate` and `daysToExpiration` are what Schwab
  prices an *analytical* chain with; sending them on a `SINGLE` chain asks the venue to
  price against numbers the caller invented. They are passed through only when given, and
  this package supplies none of them.

  `opts[:symbol]` is required. Everything else is optional and nothing is defaulted: a
  `strikeCount` or a `range` chosen here would narrow a chain the caller asked for in full.

  Returned as the venue's own map. Schwab publishes `callExpDateMap` and `putExpDateMap`
  keyed by expiry-then-strike, which is the shape `Core.Types.OptionChain` normalises to —
  `get_option_chain/3` does that, and this is the raw read for callers that want the
  underlying quote and the model fields beside it.
  """
  @spec get_chains(map(), keyword()) :: {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_chains(credentials, opts) do
    case Keyword.get(opts, :symbol) do
      symbol when is_binary(symbol) ->
        query =
          %{"symbol" => SymbolFormat.to_exchange_symbol(symbol)}
          |> put_chain_params(opts)
          |> query_string()

        with {:ok, body} <- get(market_data_url(opts) <> "/chains" <> query, credentials, opts),
             do: {:ok, body}

      _missing ->
        {:error, {:symbol_required, :schwab}}
    end
  end

  @chain_params [
    contractType: "contractType",
    strike_count: "strikeCount",
    include_underlying_quote: "includeUnderlyingQuote",
    strategy: "strategy",
    interval: "interval",
    strike: "strike",
    range: "range",
    from_date: "fromDate",
    to_date: "toDate",
    volatility: "volatility",
    underlying_price: "underlyingPrice",
    interest_rate: "interestRate",
    days_to_expiration: "daysToExpiration",
    exp_month: "expMonth",
    option_type: "optionType",
    entitlement: "entitlement"
  ]

  defp put_chain_params(params, opts) do
    Enum.reduce(@chain_params, params, fn {key, name}, acc ->
      Map.put(acc, name, chain_value(Keyword.get(opts, key)))
    end)
  end

  defp chain_value(%Date{} = date), do: Date.to_iso8601(date)
  defp chain_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp chain_value(value), do: value

  @doc """
  The expiries listed on an underlying — `GET /expirationchain`.

  One parameter and a much smaller answer than `get_chains/2`: a caller choosing an expiry
  does not need every strike to do it.
  """
  @spec get_expiration_chain(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_expiration_chain(symbol, credentials, opts) when is_binary(symbol) do
    query = query_string(%{"symbol" => SymbolFormat.to_exchange_symbol(symbol)})

    with {:ok, body} <-
           get(market_data_url(opts) <> "/expirationchain" <> query, credentials, opts),
         do: {:ok, body}
  end

  @doc """
  A venue mover list — `GET /movers/{symbol_id}`.

  **`symbol_id` is an index or a universe, not a symbol.** The venue's enum is `$DJI`,
  `$COMPX`, `$SPX`, `NYSE`, `NASDAQ`, `OTCBB`, `INDEX_ALL`, `EQUITY_ALL`, `OPTION_ALL`,
  `OPTION_PUT` and `OPTION_CALL` — a ticker sent here is not a smaller mover list, it is a
  404. A value outside the enum is refused before the request rather than sent.

  `opts[:sort]` and `opts[:frequency]` are the venue's own enums and are sent only when
  given. **`frequency` is a number of minutes**, not a count of rows: `0` means every mover
  in the session and `60` means those that moved in the last hour.
  """
  @movers_universes ~w($DJI $COMPX $SPX NYSE NASDAQ OTCBB INDEX_ALL EQUITY_ALL OPTION_ALL OPTION_PUT OPTION_CALL)

  @spec get_movers(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_movers(universe, credentials, opts) when is_binary(universe) do
    if universe in @movers_universes do
      query =
        query_string(%{
          "sort" => Keyword.get(opts, :sort),
          "frequency" => Keyword.get(opts, :frequency)
        })

      path = "/movers/" <> URI.encode(universe) <> query

      with {:ok, body} <- get(market_data_url(opts) <> path, credentials, opts), do: {:ok, body}
    else
      {:error, {:unknown_movers_universe, universe}}
    end
  end

  @doc "The mover universes this venue publishes, as its own strings."
  @spec movers_universes() :: [String.t()]
  def movers_universes, do: @movers_universes

  @doc """
  One market's hours — `GET /markets/{market_id}`.

  **Not `get_market_status/1` narrowed.** That reads `/markets` for every market at once;
  this asks about one, and `opts[:date]` asks about a *different day* — which is the reason
  to reach for it: "is the bond market open on the 4th" is not answerable from today's
  status.

  `market_id` is the venue's own enum: `equity`, `option`, `bond`, `future`, `forex`. A
  value outside it is refused before the request.
  """
  @markets ~w(equity option bond future forex)

  @spec get_market(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_market(market, credentials, opts) when is_binary(market) do
    if market in @markets do
      query = query_string(%{"date" => chain_value(Keyword.get(opts, :date))})
      path = "/markets/" <> market <> query

      with {:ok, body} <- get(market_data_url(opts) <> path, credentials, opts), do: {:ok, body}
    else
      {:error, {:unknown_market, market}}
    end
  end

  @doc "The markets this venue publishes hours for."
  @spec markets() :: [String.t()]
  def markets, do: @markets

  @doc """
  One instrument by CUSIP — `GET /instruments/{cusip_id}`.

  **A CUSIP is not a ticker**, and this endpoint takes only the first. `get_symbols/2`
  searches by symbol; this resolves an identifier a caller already holds — from a filing, a
  statement, or a corporate action — to the instrument Schwab knows.
  """
  @spec get_instrument(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_instrument(cusip, credentials, opts) when is_binary(cusip) do
    path = "/instruments/" <> URI.encode(cusip)

    with {:ok, body} <- get(market_data_url(opts) <> path, credentials, opts), do: {:ok, body}
  end

  @doc """
  The option chain for an underlying, as `Types.OptionChain` — `GET /chains`.

  **Schwab's shape is the one this type was designed around**: `callExpDateMap` and
  `putExpDateMap`, each keyed by expiry and then by strike. The keys are normalised —
  `"2026-03-20:15"` is an expiry with the venue's days-to-expiration appended, and
  `"500.0"` is a strike — and the grid is rebuilt with a call and a put at each
  intersection.

  **A strike listed on one side only keeps a `nil` on the other.** A caller iterating
  strikes has to see that the put is missing rather than have the strike vanish.

  `underlying_price` is carried **only when the venue sent it**, which it does when
  `include_underlying_quote` is asked for. `nil` means it was not in the response, not that
  the underlying has no price — and a chain valued against a price fetched separately is two
  observations at two times.

  A row this package cannot address — no readable expiry, strike or right — is refused
  rather than dropped, for the same reason a hole in a chain that looks complete is worse
  than an error.
  """
  @spec get_option_chain(String.t(), map(), keyword()) ::
          {:ok, OptionChain.t()} | {:error, term()} | {:refused, term()}
  def get_option_chain(underlying, credentials, opts) when is_binary(underlying) do
    with {:ok, body} <- get_chains(credentials, Keyword.put(opts, :symbol, underlying)) do
      with {:ok, calls} <- chain_side(body["callExpDateMap"], underlying, :call),
           {:ok, puts} <- chain_side(body["putExpDateMap"], underlying, :put) do
        {:ok,
         %OptionChain{
           underlying: body["symbol"] || underlying,
           expiries: merge_chain(calls ++ puts),
           underlying_price: decimal(body["underlyingPrice"]),
           venue_time: nil,
           provider: :schwab
         }}
      end
    end
  end

  defp chain_side(nil, _underlying, _right), do: {:ok, []}

  defp chain_side(%{} = side, underlying, right) do
    Enum.reduce_while(side, {:ok, []}, fn {expiry_key, strikes}, {:ok, acc} ->
      case chain_expiry(expiry_key) do
        {:ok, expiry} ->
          case chain_strikes(strikes, underlying, expiry, right) do
            {:ok, contracts} -> {:cont, {:ok, acc ++ contracts}}
            error -> {:halt, error}
          end

        :error ->
          {:halt, {:error, {:unreadable_chain_expiry, expiry_key}}}
      end
    end)
  end

  defp chain_side(_other, _underlying, _right), do: {:error, :unexpected_response_shape}

  # `"2026-03-20:15"` — the venue appends its own days-to-expiration to the date. That
  # number is a countdown from *today* and would be stale as a key; the date is not.
  defp chain_expiry(key) when is_binary(key) do
    key
    |> String.split(":")
    |> List.first()
    |> Date.from_iso8601()
    |> case do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp chain_expiry(_key), do: :error

  defp chain_strikes(%{} = strikes, underlying, expiry, right) do
    Enum.reduce_while(strikes, {:ok, []}, fn {strike_key, contracts}, {:ok, acc} ->
      case chain_strike(strike_key) do
        nil ->
          {:halt, {:error, {:unreadable_chain_strike, strike_key}}}

        strike ->
          rows =
            contracts
            |> List.wrap()
            |> Enum.map(&to_contract(&1, underlying, expiry, strike, right))

          {:cont, {:ok, acc ++ rows}}
      end
    end)
  end

  defp chain_strikes(_other, _underlying, _expiry, _right),
    do: {:error, :unexpected_response_shape}

  # `Decimal.new/1` raises on a string that is not a number, and a raise inside a chain read
  # would take the whole grid down over one key. This refuses that key by name instead.
  defp chain_strike(key) when is_binary(key) do
    case Decimal.parse(key) do
      {value, ""} -> value
      _other -> nil
    end
  end

  defp chain_strike(key), do: decimal(key)

  defp to_contract(row, underlying, expiry, strike, right) do
    %OptionContract{
      underlying: underlying,
      expiry: expiry,
      strike: strike,
      right: right,
      venue_symbol: row["symbol"],
      multiplier: decimal(row["multiplier"]),
      settlement_type: row["settlementType"],
      expiration_type: row["expirationType"],
      last_trading_day: chain_last_trading_day(row["lastTradingDay"]),
      # The venue does not name these three on a chain row. `nil` says "not stated"; `false`
      # would say the venue told us it is not one.
      index_option: nil,
      mini: nil,
      non_standard: row["nonStandard"],
      provider: :schwab
    }
  end

  # The venue sends this as epoch milliseconds on a chain row, unlike the expiry key.
  defp chain_last_trading_day(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, at} -> DateTime.to_date(at)
      {:error, _reason} -> nil
    end
  end

  defp chain_last_trading_day(_other), do: nil

  defp merge_chain(contracts) do
    Enum.reduce(contracts, %{}, fn contract, grid ->
      strikes = Map.get(grid, contract.expiry, %{})
      row = Map.get(strikes, contract.strike, %{call: nil, put: nil})

      Map.put(
        grid,
        contract.expiry,
        Map.put(strikes, contract.strike, Map.put(row, contract.right, contract))
      )
    end)
  end

  @doc """
  The expiries listed on an underlying — `GET /expirationchain`.

  A much smaller answer than `get_option_chain/3`, and its own endpoint rather than a
  narrowing of one: the venue publishes both.

  A date the venue sends that this package cannot parse is dropped from the list rather than
  refused — an expiration chain has no strikes hanging off each date, so a missing entry is a
  missing date and not a hole in a grid.
  """
  @spec get_option_expirations(String.t(), map(), keyword()) ::
          {:ok, [Date.t()]} | {:error, term()} | {:refused, term()}
  def get_option_expirations(underlying, credentials, opts) when is_binary(underlying) do
    with {:ok, body} <- get_expiration_chain(underlying, credentials, opts) do
      dates =
        body
        |> Map.get("expirationList", [])
        |> List.wrap()
        |> Enum.map(&expiration_date/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort(Date)

      {:ok, dates}
    end
  end

  defp expiration_date(%{"expirationDate" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> parsed
      {:error, _reason} -> nil
    end
  end

  defp expiration_date(_row), do: nil

  @doc """
  A mover list as `Types.ScreenerResult` — `GET /movers/{symbol_id}`.

  `name` is the venue's universe: `$DJI`, `NASDAQ`, `OPTION_PUT` and the rest;
  `movers_universes/0` lists them and anything else is refused.

  **The rank is the position the venue returned the row in.** Schwab sorts by whatever
  `opts[:sort]` asked for and this package does not re-rank: two venues' "top movers" answer
  different questions, and so do one venue's under two sorts.
  """
  @spec get_screener(String.t(), map(), keyword()) ::
          {:ok, [ScreenerResult.t()]} | {:error, term()} | {:refused, term()}
  def get_screener(name, credentials, opts) do
    with {:ok, body} <- get_movers(name, credentials, opts) do
      rows =
        body
        |> Map.get("screeners", [])
        |> List.wrap()
        |> Enum.with_index(1)
        |> Enum.map(fn {row, rank} ->
          %ScreenerResult{
            symbol: row["symbol"] || "",
            screener: name,
            rank: rank,
            metrics: row,
            venue_time: nil,
            provider: :schwab
          }
        end)

      {:ok, rows}
    end
  end

  @doc """
  Open positions — `GET /accounts` with the venue's `positions` field.

  **Positions live inside the account response here**, not on an endpoint of their own, and
  Schwab returns them only when asked: without `fields=positions` the same call answers
  balances and says nothing about exposure. This always asks.

  Schwab reports **long and short quantities as separate fields** rather than one signed
  number, and this reads whichever is non-zero: `longQuantity` is a `:long` and
  `shortQuantity` a `:short`. A row with both zero is skipped — it is a closed position the
  venue still lists, not an open one of size nothing.

  `liquidation_price` is `nil`: Schwab publishes none per position. **That is not safety** —
  the account's maintenance requirement is in the balances beside it.
  """
  @spec get_positions(map(), keyword()) ::
          {:ok, [Position.t()]} | {:error, term()} | {:refused, term()}
  def get_positions(credentials, opts) do
    with {:ok, accounts} <-
           get_account_summaries(credentials, Keyword.put(opts, :fields, "positions")) do
      {:ok, accounts |> Enum.flat_map(&account_positions/1) |> Enum.reject(&is_nil/1)}
    end
  end

  defp account_positions(%{"securitiesAccount" => %{"positions" => positions}})
       when is_list(positions),
       do: Enum.map(positions, &to_position/1)

  defp account_positions(_account), do: []

  defp to_position(row) do
    long = decimal(row["longQuantity"])
    short = decimal(row["shortQuantity"])
    instrument = row["instrument"] || %{}

    case position_side(long, short) do
      nil ->
        nil

      {side, quantity} ->
        %Position{
          symbol: instrument["symbol"],
          side: side,
          quantity: quantity,
          instrument_type: position_instrument(instrument["assetType"]),
          average_cost: decimal(row["averagePrice"]),
          mark_price: nil,
          notional_value: decimal(row["marketValue"]),
          realised_pnl: decimal(row["longOpenProfitLoss"] || row["shortOpenProfitLoss"]),
          unrealised_pnl: decimal(row["currentDayProfitLoss"]),
          liquidation_price: nil,
          leverage: nil,
          venue_time: nil,
          provider: :schwab
        }
    end
  end

  # Two fields, not one signed number. A row with both zero is a closed position the venue
  # still lists — skipped rather than reported as an open position of size nothing.
  defp position_side(long, short) do
    cond do
      not is_nil(long) and Decimal.positive?(long) -> {:long, long}
      not is_nil(short) and Decimal.positive?(short) -> {:short, short}
      true -> nil
    end
  end

  defp position_instrument("EQUITY"), do: :equity
  defp position_instrument("OPTION"), do: :option
  defp position_instrument("COLLECTIVE_INVESTMENT"), do: :fund
  defp position_instrument(_other), do: nil
  # --- the rest of accounts and trading ------------------------------------

  @doc """
  Every account's balances and positions — `GET /accounts`.

  **Not `get_accounts/2`.** That one reads `/accounts/accountNumbers` and returns the
  encrypted hashes every other endpoint addresses by; this returns the accounts themselves,
  and the two are different answers to different questions. A caller needs the first to
  address anything and the second to know what is in it.

  `opts[:fields]` takes the venue's `positions` to include them; without it Schwab returns
  balances only. Nothing is defaulted, because positions are a much larger response and
  asking for them on every call is a decision the caller should make.
  """
  @spec get_account_summaries(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_account_summaries(credentials, opts) do
    query = query_string(%{"fields" => Keyword.get(opts, :fields)})

    with {:ok, body} <- get(trader_url(opts) <> "/accounts" <> query, credentials, opts) do
      {:ok, List.wrap(body)}
    end
  end

  @doc """
  Orders across **every** account — `GET /orders`.

  **`fromEnteredTime` and `toEnteredTime` are both required by the venue** and are refused
  here when missing rather than defaulted: a window this package chose would return a real
  list of orders over a period the caller did not ask about, and an empty one would read as
  "no orders".

  `get_orders/3` is the per-account read. This is the one that answers "what is working
  anywhere", which on a credential with several accounts is a different question.

  `opts[:status]` takes one of the venue's twenty-one statuses; `opts[:max_results]` bounds
  the page.
  """
  @spec get_all_orders(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_all_orders(credentials, opts) do
    with {:ok, from, to} <- order_window(opts) do
      query =
        query_string(%{
          "fromEnteredTime" => from,
          "toEnteredTime" => to,
          "status" => Keyword.get(opts, :status),
          "maxResults" => Keyword.get(opts, :max_results)
        })

      with {:ok, body} <- get(trader_url(opts) <> "/orders" <> query, credentials, opts) do
        {:ok, List.wrap(body)}
      end
    end
  end

  defp order_window(opts) do
    both_ends(Keyword.get(opts, :from), Keyword.get(opts, :to))
  end

  # Both ends or neither. A window with one end is a window this package would have to
  # complete, and either end it chose returns a real answer over a period the caller did not
  # ask about.
  defp both_ends(nil, _to), do: {:error, {:from_and_to_required, :schwab}}
  defp both_ends(_from, nil), do: {:error, {:from_and_to_required, :schwab}}
  defp both_ends(from, to), do: {:ok, schwab_datetime(from), schwab_datetime(to)}
  # Schwab's documented shape is `yyyy-MM-dd'T'HH:mm:ss.SSSZ`. A `DateTime` is rendered to
  # it; anything else is passed through, because a caller holding the venue's own string
  # should not have it reformatted.
  defp schwab_datetime(%DateTime{} = at) do
    at |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601() |> String.replace("Z", ".000Z")
  end

  defp schwab_datetime(value), do: value

  @transaction_types ~w(TRADE RECEIVE_AND_DELIVER DIVIDEND_OR_INTEREST ACH_RECEIPT
                        ACH_DISBURSEMENT CASH_RECEIPT CASH_DISBURSEMENT ELECTRONIC_FUND
                        WIRE_OUT WIRE_IN JOURNAL MEMORANDUM MARGIN_CALL MONEY_MARKET
                        SMA_ADJUSTMENT)

  @doc "The transaction types this venue records — there is no 'all' among them."
  @spec transaction_types() :: [String.t()]
  def transaction_types, do: @transaction_types

  @doc """
  Transactions on one account — `GET /accounts/{accountNumber}/transactions`.

  **Three parameters are required by the venue, and `types` is one of them.** There is no
  "everything" value in its enum: the fifteen types are `TRADE`, `RECEIVE_AND_DELIVER`,
  `DIVIDEND_OR_INTEREST`, the two ACH kinds, the two cash kinds, `ELECTRONIC_FUND`,
  `WIRE_OUT`, `WIRE_IN`, `JOURNAL`, `MEMORANDUM`, `MARGIN_CALL`, `MONEY_MARKET` and
  `SMA_ADJUSTMENT`. `transaction_types/0` lists them; passing all fifteen is how a caller
  asks for everything, and this package does not do it on their behalf — a default would
  return a real ledger that is missing whichever kinds it left out.

  `opts[:symbol]` narrows to one instrument.
  """
  @spec get_transactions(map(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_transactions(credentials, account_hash, opts) when is_binary(account_hash) do
    with {:ok, from, to} <- transaction_window(opts),
         {:ok, types} <- transaction_type_param(opts) do
      query =
        query_string(%{
          "startDate" => from,
          "endDate" => to,
          "types" => types,
          "symbol" => Keyword.get(opts, :symbol)
        })

      path = "/accounts/" <> account_hash <> "/transactions" <> query

      with {:ok, body} <- get(trader_url(opts) <> path, credentials, opts) do
        {:ok, List.wrap(body)}
      end
    end
  end

  defp transaction_window(opts) do
    both_ends(Keyword.get(opts, :from), Keyword.get(opts, :to))
  end

  defp transaction_type_param(opts) do
    case Keyword.get(opts, :types) do
      nil ->
        {:error, {:types_required, :schwab}}

      types when is_list(types) ->
        case Enum.reject(types, &(&1 in @transaction_types)) do
          [] -> {:ok, Enum.join(types, ",")}
          unknown -> {:error, {:unknown_transaction_types, unknown}}
        end

      type when is_binary(type) ->
        transaction_type_param(Keyword.put(opts, :types, [type]))
    end
  end

  @doc """
  One transaction by id — `GET /accounts/{accountNumber}/transactions/{transactionId}`.

  The id is Schwab's own integer, from a row `get_transactions/3` returned.
  """
  @spec get_transaction(map(), String.t(), integer() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_transaction(credentials, account_hash, transaction_id, opts)
      when is_binary(account_hash) do
    path = "/accounts/" <> account_hash <> "/transactions/" <> to_string(transaction_id)

    with {:ok, body} <- get(trader_url(opts) <> path, credentials, opts), do: {:ok, body}
  end

  @doc """
  The signed-in user's preferences — `GET /userPreference`.

  **This is the streaming bootstrap.** `DpExchange.Schwab.StreamerInfo` reads the same
  endpoint for the socket URL and login fields; this returns the whole response, which also
  carries the account nicknames, the default account, and the display preferences a caller
  may want.

  Takes no parameters.
  """
  @spec get_user_preference(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_user_preference(credentials, opts) do
    with {:ok, body} <- get(trader_url(opts) <> "/userPreference", credentials, opts),
         do: {:ok, body}
  end

  # Only the parameters the caller actually gave. An empty query string is no `?` at all,
  # because a bare `?` is a different URL and this venue signs nothing, so the only cost of
  # sending one is a reader wondering what was filtered.
  defp query_string(params) do
    case params |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Enum.sort() do
      [] -> ""
      pairs -> "?" <> URI.encode_query(pairs)
    end
  end

  # --- accounts and trading -----------------------------------------------

  @doc """
  Account numbers and their encrypted hashes.

  **Every other account endpoint takes the hash, not the number.** Schwab returns both
  from this one endpoint, which makes it a prerequisite for the whole trading surface
  rather than a convenience. A caller holding an account number and no hash cannot
  address anything.

  Returned as a list of `%{account_number: ..., hash: ...}` rather than the venue's own
  key names, because the hash is the part a caller uses and the naming should say so.
  """
  @spec get_accounts(map(), keyword()) :: {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_accounts(credentials, opts) do
    with {:ok, body} <- get(trader_url(opts) <> "/accounts/accountNumbers", credentials, opts) do
      account_numbers(body)
    end
  end

  defp account_numbers(rows) when is_list(rows) do
    accounts =
      Enum.map(rows, fn row ->
        %{account_number: row["accountNumber"], hash: row["hashValue"]}
      end)

    if Enum.any?(accounts, &is_nil(&1.hash)) do
      {:error, :unexpected_response_shape}
    else
      {:ok, accounts}
    end
  end

  defp account_numbers(_other), do: {:error, :unexpected_response_shape}

  @doc """
  Balances for one account, as `Core.Types.Balance` values.

  A Schwab account is a discriminated union: a `MarginAccount` and a `CashAccount` carry
  different balance fields entirely, and the response says which through `type`. Both are
  read; neither is guessed at from the other.

  Cash is reported as a `USD` balance. `available_balance` is the account's own
  buying power for a margin account and its cash available for trading for a cash
  account — which are the same *question* answered by different fields, and the venue
  answers only the one that applies.
  """
  @spec get_balances(map(), String.t(), keyword()) ::
          {:ok, [DpExchange.Core.Types.Balance.t()]} | {:error, term()} | {:refused, term()}
  def get_balances(credentials, account_hash, opts) do
    path = "/accounts/" <> URI.encode(account_hash)

    with {:ok, body} <- get(trader_url(opts) <> path, credentials, opts) do
      balances(body)
    end
  end

  defp balances(%{"securitiesAccount" => account}) when is_map(account) do
    current = account["currentBalances"] || %{}

    with {:ok, total} <- balance_total(account["type"], current) do
      {:ok,
       [
         %DpExchange.Core.Types.Balance{
           currency: "USD",
           balance: decimal(total),
           available_balance: decimal(available(account["type"], current)),
           hold: nil,
           # The venue does not date a balance response. Rather than stamp it with the
           # local clock and call it the venue's, the timestamp is the read time and the
           # moduledoc says so — a balance is a snapshot of now by construction, unlike a
           # quote, which is a claim about an instant the venue chose.
           timestamp: DateTime.utc_now(),
           provider: :schwab
         }
       ]}
    end
  end

  defp balances(_other), do: {:error, :unexpected_response_shape}

  # MARGIN and CASH carry different fields. An account whose type the venue did not state
  # is unreadable rather than assumed to be either — reading a margin account as cash
  # would report a buying power of nil for an account that has one.
  defp balance_total("MARGIN", current), do: fetch_balance(current, "liquidationValue")
  defp balance_total("CASH", current), do: fetch_balance(current, "totalCash")
  defp balance_total(_unknown, _current), do: {:error, :unexpected_response_shape}

  defp fetch_balance(current, key) do
    case Map.get(current, key) do
      nil -> {:error, :unexpected_response_shape}
      value -> {:ok, value}
    end
  end

  defp available("MARGIN", current), do: current["buyingPower"]
  defp available("CASH", current), do: current["cashAvailableForTrading"]
  defp available(_unknown, _current), do: nil

  @doc "Place an order. Returns the venue's order id, read from the `Location` header."
  @spec place_order(map(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()} | {:refused, term()}
  def place_order(credentials, account_hash, payload, opts) do
    path = "/accounts/" <> URI.encode(account_hash) <> "/orders"

    with {:ok, headers} <- Auth.headers(credentials, opts),
         {:ok, body} <- Jason.encode(payload) do
      headers = [{"Content-Type", "application/json"} | headers]

      url = trader_url(opts) <> path

      case HttpClient.request(:post, url, headers, body, request_opts(opts)) do
        # Schwab answers a placed order with 201 and an empty body; the id is in the
        # Location header. A caller that needs the order must be given the id, so a 201
        # without one is a failure rather than a success with nothing in it.
        {:ok, %{status: status} = response} when status in 200..299 ->
          order_id_from_location(response)

        {:ok, %{status: status, body: response}} when status in [400, 401, 403, 404] ->
          {:refused, refusal(status, response)}

        {:ok, %{status: status, body: response}} ->
          {:error, {:exchange_error, :schwab, "HTTP #{status}: #{inspect(response)}"}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp order_id_from_location(response) do
    location =
      response
      |> Map.get(:headers, %{})
      |> header("location")

    case location do
      nil -> {:error, :order_id_not_returned}
      value -> {:ok, value |> String.split("/") |> List.last()}
    end
  end

  # Req normalises header names to lowercase and values to lists; a plain map of strings
  # is also accepted so this does not depend on one client's shape.
  defp header(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _rest] -> value
      value when is_binary(value) -> value
      _absent -> nil
    end
  end

  defp header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} -> if String.downcase(to_string(key)) == name, do: value
      _other -> nil
    end)
  end

  defp header(_headers, _name), do: nil

  @doc """
  Validate an order **without placing it**, returning the venue's own estimate.

  `POST /accounts/{hash}/previewOrder`. This is the only endpoint in the family that
  checks an order against the venue's own rules before committing to it, and on this venue
  it is worth more than elsewhere: **order writes are throttled and reads are not**, so a
  rejection discovered by previewing costs nothing while one discovered by placing costs a
  scarce write.

  Returns the venue's response as-is. `Core` has no type for a preview — the fields are
  `orderStrategy`, `orderValidationResult` and `commissionAndFee`, none of which map onto
  anything the contract names — and inventing one would put a shape in `Core.Types` that
  exactly one venue can fill.
  """
  @spec preview_order(map(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def preview_order(credentials, account_hash, payload, opts) do
    path = "/accounts/" <> URI.encode(account_hash) <> "/previewOrder"

    post_json(credentials, trader_url(opts) <> path, payload, opts)
  end

  @doc """
  Replace an open order **atomically**.

  `PUT /accounts/{hash}/orders/{orderId}`. Every other venue in the family cancels and
  re-places, and on this venue those two calls are **not equivalent**: cancel-then-place
  opens a window in which no order is live, and on a moving market that window is the
  risk. It also costs two throttled writes instead of one.

  The new order's id comes back in `Location`, as it does for a placed order — Schwab
  treats a replacement as a new order, so the old id is dead afterwards and a caller
  holding it would be tracking an order that no longer exists.
  """
  @spec replace_order(map(), String.t(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()} | {:refused, term()}
  def replace_order(credentials, account_hash, order_id, payload, opts) do
    path = "/accounts/" <> URI.encode(account_hash) <> "/orders/" <> URI.encode(order_id)

    with {:ok, headers} <- Auth.headers(credentials, opts),
         {:ok, body} <- Jason.encode(payload) do
      headers = [{"Content-Type", "application/json"} | headers]
      url = trader_url(opts) <> path

      case HttpClient.request(:put, url, headers, body, request_opts(opts)) do
        {:ok, %{status: status} = response} when status in 200..299 ->
          order_id_from_location(response)

        {:ok, %{status: status, body: response}} when status in [400, 401, 403, 404] ->
          {:refused, refusal(status, response)}

        {:ok, %{status: status, body: response}} ->
          {:error, {:exchange_error, :schwab, "HTTP #{status}: #{inspect(response)}"}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp post_json(credentials, url, payload, opts) do
    with {:ok, headers} <- Auth.headers(credentials, opts),
         {:ok, body} <- Jason.encode(payload) do
      headers = [{"Content-Type", "application/json"} | headers]

      case HttpClient.request(:post, url, headers, body, request_opts(opts)) do
        {:ok, %{status: status, body: response}} when status in 200..299 ->
          {:ok, decode(response)}

        {:ok, %{status: status, body: response}} when status in [400, 401, 403, 404] ->
          {:refused, refusal(status, response)}

        {:ok, %{status: status, body: response}} ->
          {:error, {:exchange_error, :schwab, "HTTP #{status}: #{inspect(response)}"}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Cancel an order."
  @spec cancel_order(map(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()} | {:refused, term()}
  def cancel_order(credentials, account_hash, order_id, opts) do
    path = "/accounts/" <> URI.encode(account_hash) <> "/orders/" <> URI.encode(order_id)

    with {:ok, headers} <- Auth.headers(credentials, opts) do
      url = trader_url(opts) <> path

      case HttpClient.request(:delete, url, headers, nil, request_opts(opts)) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status, body: body}} when status in [400, 401, 403, 404] ->
          {:refused, refusal(status, body)}

        {:ok, %{status: status, body: body}} ->
          {:error, {:exchange_error, :schwab, "HTTP #{status}: #{inspect(body)}"}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "One order, as the venue reports it."
  @spec get_order(map(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_order(credentials, account_hash, order_id, opts) do
    path = "/accounts/" <> URI.encode(account_hash) <> "/orders/" <> URI.encode(order_id)
    get(trader_url(opts) <> path, credentials, opts)
  end

  @doc "Orders for one account within a window the venue requires."
  @spec get_orders(map(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_orders(credentials, account_hash, opts) do
    path = "/accounts/" <> URI.encode(account_hash) <> "/orders"

    with {:ok, body} <- get(trader_url(opts) <> path, credentials, opts) do
      if is_list(body), do: {:ok, body}, else: {:error, :unexpected_response_shape}
    end
  end

  # --- request ------------------------------------------------------------

  defp get(url, credentials, opts) do
    with {:ok, headers} <- Auth.headers(credentials, opts) do
      case HttpClient.request(:get, url, headers, nil, request_opts(opts)) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, decode(body)}

        # Permanent for the request as sent. A 401 is the credential rather than the
        # request, and `Auth.credential_failure?/1` is what a caller checks to decide
        # whether refreshing and retrying is worth doing.
        {:ok, %{status: status, body: body}} when status in [400, 401, 403, 404] ->
          {:refused, refusal(status, body)}

        {:ok, %{status: status, body: body}} ->
          {:error, {:exchange_error, :schwab, "HTTP #{status}: #{inspect(body)}"}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp request_opts(opts) do
    opts
    |> Keyword.take([:limiter, :timeout, :retry_attempts, :log_requests, :plug, :req_adapter])
    |> Keyword.merge(provider: :schwab, raw_status: true)
  end

  defp refusal(status, body) do
    case decode(body) do
      %{"errors" => [%{"detail" => detail} | _rest]} -> {:venue_error, status, detail}
      %{"error_description" => detail} when is_binary(detail) -> {:venue_error, status, detail}
      %{"message" => detail} when is_binary(detail) -> {:venue_error, status, detail}
      _other -> {:venue_error, status}
    end
  end

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{}
    end
  end

  # A JSON array decodes to a list, and several endpoints here return one —
  # `/accounts/accountNumbers` and both order listings. Falling through to `%{}` made
  # those come back silently empty rather than loudly wrong, which is the worse failure
  # of the two: an account list that is empty because the parser dropped it looks exactly
  # like a credential with no linked accounts.
  defp decode(body) when is_map(body) or is_list(body), do: body
  defp decode(_other), do: %{}

  defp decimal(nil), do: nil
  defp decimal(""), do: nil
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_binary(value), do: Decimal.new(value)
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
end
