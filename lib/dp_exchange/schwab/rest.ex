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
  alias DpExchange.Core.Types.Quote
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
         bid: decimal(row["bidPrice"]),
         ask: decimal(row["askPrice"]),
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
        candles(body, native)
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

  defp candles(%{"candles" => rows}, native) when is_list(rows) do
    symbol = SymbolFormat.to_canonical_symbol(native)

    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case candle(symbol, row) do
        {:ok, quote_struct} -> {:cont, {:ok, [quote_struct | acc]}}
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
  defp candles(%{"empty" => true}, _native), do: {:refused, :not_listed}
  defp candles(_other, _native), do: {:error, :unexpected_response_shape}

  # A candle is delivered as a `Quote` because that is the contract's shape for a series.
  # `close` is the price: an OHLC bar's price, for a series, is where it ended.
  defp candle(symbol, row) do
    with {:ok, close} <- required(row, "close"),
         {:ok, timestamp} <- candle_time(row) do
      {:ok,
       %Quote{
         symbol: symbol,
         price: decimal(close),
         bid: nil,
         ask: nil,
         volume: decimal(row["volume"]),
         timestamp: timestamp,
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
