defmodule DpExchange.Schwab.StreamerDecode do
  @moduledoc """
  Streamer data frames into the contract's value types.

  Pure functions. The socket hands frames here and gets `Quote`, `TopOfBook`, `Candle` or
  `OrderBook` back — or an error, which is the point of several of the rules below.

  ## A LEVELONE frame is two different things at once

  It carries `bid`, `ask` **and** `last` in one payload. Those are not the same fact: the
  first two are resting orders and the third is an execution. So one frame decodes to a
  `Quote` *or* a `TopOfBook` depending on which was asked for, and **never to a `Quote`
  whose price came from the bid** — the defect this family has found five times.

  A frame with no `last` yields no quote. `{:error, :no_traded_price}` is the honest answer;
  substituting the bid, the ask or the midpoint would produce a price nobody traded at.

  ## The venue's own time, and when it is absent

  `CHART_EQUITY` stamps each bar with `chart_time` in milliseconds, and that is the bar's
  opening. Some `LEVELONE_*` services carry a venue timestamp of their own and some do
  not, and it is per-service rather than a family-wide fact:

  * `LEVELONE_EQUITIES` names field 34 "Quote Time in Long" and field 35 "Trade Time in
    Long" (`market-data-production.txt:663-673`) — the last time a bid or ask updated, and
    the last trade time, both milliseconds since epoch.
  * `LEVELONE_FUTURES` and `LEVELONE_FUTURES_OPTIONS` name the same pair at fields 10 and
    11 (`market-data-production.txt:1358-1366`, `:1730-1738`), already read as
    `:quote_time`/`:trade_time` by `StreamerFields`.
  * `LEVELONE_OPTIONS` and `LEVELONE_FOREX` name neither in the fields this package reads.

  Where a service carries one, `to_quote/3` and `to_top_of_book/3` use it; where it does
  not, or the frame did not include it, `venue_time` is `nil` and `observed_at` — the
  frame's arrival time, which the socket passes in — is what stands in.

  `nil` there is not an oversight. It says the venue did not stamp this frame, which is the
  difference between "quoted at 14:53:02" and "seen at 14:53:02". This used to say
  `LEVELONE_*` carried no venue time in the fields this package reads at all — true when it
  was written, false once `StreamerFields` started naming these fields for the services
  that document them.
  """

  alias DpExchange.Core.Types.{Candle, OrderBook, Quote, TopOfBook}

  @doc """
  A `Quote` from a `LEVELONE_*` frame.

  **`last` and nothing else.** A frame without it is `{:error, :no_traded_price}`: bid and
  ask are resting orders, and a quote built from one reports a price at which nothing
  traded.

  `observed_at` is when the frame arrived. `venue_time` is the venue's own trade time where
  the service names one — see the moduledoc's table — and `nil` otherwise.
  """
  @spec to_quote(map(), String.t(), DateTime.t()) :: {:ok, Quote.t()} | {:error, term()}
  def to_quote(%{last: last} = fields, symbol, observed_at) when last != nil do
    with {:ok, price} <- required_decimal(last, :price) do
      # The venue's `total_volume` is the day's aggregate, not this trade's. `last_size` is
      # the trade's own, so this quote's volume is one print, and says so in
      # `volume_window` (dp-exchange-core issue #42). Read rather than required: `:volume`
      # is not enforced on `Core.Types.Quote`, so an unreadable size is `nil`, the window
      # with it, and the quote still stands.
      volume = decimal(Map.get(fields, :last_size))

      {:ok,
       %Quote{
         symbol: symbol,
         price: price,
         volume: volume,
         volume_window: volume && :print,
         # **The venue's own trade time, where the service names one — `nil` otherwise.**
         # `LEVELONE_EQUITIES` field 35, `LEVELONE_FUTURES`/`LEVELONE_FUTURES_OPTIONS`
         # field 11 — "Trade Time in Long" / "Trade Time", the last trade time in
         # milliseconds since epoch (see the moduledoc's table) — is the venue's own
         # statement of when the `last` price this `Quote` reports actually traded, read in
         # preference to the frame's arrival time whenever the frame carries it.
         #
         # This used to be unconditional `nil`, on the premise that no `LEVELONE_*` service
         # carried a venue timestamp at all in the fields this package read — true for
         # `LEVELONE_OPTIONS`/`LEVELONE_FOREX`, false for the two services above once
         # `StreamerFields` started naming these fields. Before that, it was `timestamp:
         # observed_at`: an arrival time in a field `Core.Types.Quote` documented as the
         # venue's own, because the single `:timestamp` it had left no way to say the venue
         # did not date the frame. Core 0.2.0 split that field for this reason
         # (dp-exchange-core issue #31).
         #
         # `to_order_book/2` below is the counter-example and always was: it reads the
         # venue's `snapshot_time` and fails closed when absent, rather than substituting.
         # The rule was always keepable where the venue cooperates; it took naming the
         # fields to see it was keepable here too, for two of the four services.
         venue_time: field_time(fields, :trade_time),
         observed_at: observed_at,
         provider: :schwab
       }}
    end
  end

  def to_quote(_fields, _symbol, _observed_at), do: {:error, :no_traded_price}

  @doc """
  A `TopOfBook` from a `LEVELONE_*` frame.

  Sizes are the venue's own and are **in lots, not shares** for equities — the vendor says
  so, and this package does not multiply by 100: a lot size is not universally 100, and a
  package guessing the multiplier would report a size the venue never sent.

  `venue_time` is the venue's own quote time where the service names one — `LEVELONE_EQUITIES`
  field 34, `LEVELONE_FUTURES`/`LEVELONE_FUTURES_OPTIONS` field 10, "the last time a bid or
  ask updated" (see the moduledoc's table) — and `nil` where it does not (`LEVELONE_OPTIONS`,
  `LEVELONE_FOREX`) or the frame did not carry it. `observed_at` is when the frame arrived
  either way, and the pair together is the honest statement of freshness this type promises.

  ## This returns the frame's DELTA, and is not what crosses the facade

  `LEVELONE_*` is Change delivery, so a frame states only what moved and this function can
  only report what the frame stated. The result is therefore a partial book: a field absent
  here means "the venue did not mention it", which is **not** what a `nil` means on
  `Core.Types.TopOfBook` — there it says the level does not exist.

  `Socket.merge_top_of_book/3` resolves that, folding this delta onto the last book published
  for the symbol, and the merged snapshot is what a consumer receives. Nothing that calls
  this function directly should publish its result.
  """
  @spec to_top_of_book(map(), String.t(), DateTime.t()) :: {:ok, TopOfBook.t()}
  def to_top_of_book(fields, symbol, observed_at) do
    {:ok,
     %TopOfBook{
       symbol: symbol,
       bid: decimal(Map.get(fields, :bid)),
       ask: decimal(Map.get(fields, :ask)),
       bid_size: decimal(Map.get(fields, :bid_size)),
       ask_size: decimal(Map.get(fields, :ask_size)),
       venue_time: field_time(fields, :quote_time),
       observed_at: observed_at,
       provider: :schwab
     }}
  end

  @doc """
  A `Candle` from a `CHART_*` frame.

  `chart_time` is milliseconds since epoch and is **the bar's opening**, which is what
  `:opened_at` means. A bar without it is refused: a chart bar wearing the arrival time
  would be placed in the series at the wrong minute, and every value in it would still be
  real.

  `timeframe` is the caller's, because the venue's chart services stream one width and do
  not name it in the frame.

  ## The four prices are required, and on this service that is the venue's own rule

  `Core.Types.Candle` enforces `:open`, `:high`, `:low` and `:close`, and its `new/1` refuses
  a `nil` in any of them. This function builds the struct literally, so that check never ran
  here, and the four went through bare `decimal/1` — which answers `nil` for an absent,
  empty, unparseable, NaN or Infinity value. A bar with a `nil` `open` would sit in a series
  looking like every other bar.

  **A `CHART_*` frame cannot legitimately omit them.** The vendor's own Streamer table
  (`docs/reference/schwab/documentation/market-data-production.html`) gives `CHART_EQUITY`
  and `CHART_FUTURES` the delivery type **All Sequence** — *"All data is streamed to the
  client and includes a sequence number"* — as against **Change**, *"Only fields that clients
  are interested in, and have changed, are streamed"*. So a missing price here is a decode
  fault, not a partial update, and refusing is the honest answer.

  That distinction is also why `to_top_of_book/3` above does not refuse an absent bid: the
  `LEVELONE_*` services ARE Change delivery, and a frame there genuinely omits what did not
  move, so an absent level is a normal frame rather than a decode fault. Same package,
  opposite answer, because the venue says something different about each service.

  An earlier version of this paragraph finished "and `Types.TopOfBook` permits `nil` for
  exactly that reason", and stopped there. It does permit `nil` — but it says what that
  `nil` MEANS, and the meaning is "this level does not exist", not "this frame did not
  mention it". Reading the delivery type correctly and then publishing the delta anyway put
  a claim about the book on the venue's behalf that the venue never made. The delta is now
  merged onto the last known book in `Socket.merge_top_of_book/3`, and the snapshot is what
  crosses the facade.

  `Rest.to_candle/3` — the REST arm of the same type — already guarded all four. This was the
  copy that did not.

  `volume` stays unguarded: it is not an enforced key on `Candle`, and a frame that did not
  state a volume has not stated one.
  """
  @spec to_candle(map(), String.t(), String.t()) :: {:ok, Candle.t()} | {:error, term()}
  def to_candle(fields, symbol, timeframe) do
    with {:ok, opened_at} <- chart_time(Map.get(fields, :chart_time)),
         {:ok, open} <- required_decimal(Map.get(fields, :open), :open),
         {:ok, high} <- required_decimal(Map.get(fields, :high), :high),
         {:ok, low} <- required_decimal(Map.get(fields, :low), :low),
         {:ok, close} <- required_decimal(Map.get(fields, :close), :close) do
      {:ok,
       %Candle{
         symbol: symbol,
         timeframe: timeframe,
         opened_at: opened_at,
         open: open,
         high: high,
         low: low,
         close: close,
         volume: decimal(Map.get(fields, :volume)),
         provider: :schwab
       }}
    end
  end

  # The same shape as `Rest`'s own copy. A `nil` out of `decimal/1` means "absent, empty,
  # unparseable, or a NaN/Infinity this package refuses", and whether that may be carried
  # forward depends on the field; this is how a field says it may not.
  defp required_decimal(value, field) do
    case decimal(value) do
      nil -> {:error, {:invalid_decimal, field, value}}
      parsed -> {:ok, parsed}
    end
  end

  # Reads a `LEVELONE_*` service's own timestamp field — `:quote_time` or `:trade_time`,
  # milliseconds since epoch on the services that name them (see `to_quote/3`'s and
  # `to_top_of_book/3`'s docs) — and answers `nil` for anything that is not a usable
  # instant: absent (the service does not name this field, or a Change-delivery frame did
  # not carry it this time), non-positive, or out of `DateTime.from_unix/2`'s range. `nil`
  # is not a decode fault here the way it is for `to_candle/3`'s prices or
  # `to_order_book/2`'s snapshot time — a `LEVELONE_*` quote or top of book is valid
  # without a venue timestamp, it just falls back to `observed_at`.
  defp field_time(fields, key) do
    case Map.get(fields, key) do
      ms when is_integer(ms) and ms > 0 ->
        case DateTime.from_unix(ms, :millisecond) do
          {:ok, at} -> at
          {:error, _out_of_range} -> nil
        end

      _absent_or_non_positive ->
        nil
    end
  end

  @doc """
  An `OrderBook` from a `NYSE_BOOK`, `NASDAQ_BOOK` or `OPTIONS_BOOK` frame.

  **These frames carry the venue's own timestamp**, unlike the `LEVELONE_*` services — field
  1 is "Market Snapshot Time, milliseconds since Epoch". A book without it is refused: a
  depth snapshot wearing the arrival time cannot be told from a current one, and a stale
  book read as current is the most expensive wrong number this venue produces.

  ## Each level is an array, and the size that survives is the aggregate

  A level is `[price, aggregate_size, market_maker_count, market_makers]`, and each market
  maker beneath it carries its own id, size and quote time. `Core.Types.OrderBook` levels
  are `{price, size}`, so **the per-maker attribution is dropped** — a real loss on a lit
  book, and one worth naming rather than leaving silent.

  The size kept is the venue's **aggregate** for the level, not a sum over the makers: those
  are different numbers when attribution is partial, and the aggregate is the one the venue
  stands behind.
  """
  @spec to_order_book(map(), String.t()) :: {:ok, OrderBook.t()} | {:error, term()}
  def to_order_book(fields, symbol) do
    with {:ok, timestamp} <- snapshot_time(Map.get(fields, :snapshot_time)) do
      {:ok,
       %OrderBook{
         symbol: symbol,
         bids: levels(Map.get(fields, :bids), :desc),
         asks: levels(Map.get(fields, :asks), :asc),
         venue_time: timestamp,
         observed_at: DateTime.utc_now(),
         # The Streamer publishes no sequence on a book frame. `nil` means the venue did
         # not say, so a caller cannot use this to detect a dropped update.
         sequence: nil,
         provider: :schwab
       }}
    end
  end

  defp snapshot_time(ms) when is_integer(ms), do: from_unix_ms(ms)
  defp snapshot_time(_absent), do: {:error, :missing_venue_timestamp}

  # `DateTime.from_unix/2`, not `from_unix!/2`, and non-positive is refused.
  #
  # Two ways a number that reached here is still not a venue time, and the bang version
  # handled neither. **Out of range RAISES** — a venue moving to microseconds is `invalid
  # Unix time` — and this decoder runs inside the Socket process on a streamed frame, so the
  # exception does not surface as a bad field, it takes the LINK down. One malformed frame
  # costing a reconnect for every symbol on that connection is the opposite of what this
  # module's `{:error, :missing_venue_timestamp}` branch exists to do. **Zero and negative do
  # NOT raise**: they quietly become 1970 and earlier, on a field whose entire purpose is to
  # carry the venue's own instant.
  defp from_unix_ms(ms) when ms > 0 do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, at} -> {:ok, at}
      {:error, _out_of_range} -> {:error, :missing_venue_timestamp}
    end
  end

  defp from_unix_ms(_non_positive), do: {:error, :missing_venue_timestamp}

  # A level is `[price, aggregate_size, …]`. A level without a price is not a level, and
  # keeping it would put `{nil, size}` into a book a caller folds over.
  # Sorted here, not passed through in the venue's row order. `Core.Types.OrderBook` makes the
  # ordering part of the contract in as many words — "a caller reading `hd(bids)` as the best
  # bid is reading it correctly, and a venue package that returns venue-order without
  # re-sorting has broken the contract even though every value in it is true" — and this
  # returned whatever row the venue sent first.
  #
  # `{direction, Decimal}` rather than term order, matching `dp_exchange_coinbase`'s
  # `sorted/2` — the only package in the family that was already doing this — because
  # `Decimal` structs do not compare correctly as plain terms.
  #
  # The `not is_nil(price)` filter this already had is why a nil price cannot reach the sort.
  defp levels(rows, direction) when is_list(rows) do
    rows
    |> Enum.flat_map(fn row ->
      # A level without a size is dropped as one without a price is: `{price, nil}` reached
      # a caller summing the book, and `OrderBook`'s level type has no nil in it.
      case {level_at(row, 0), level_at(row, 1)} do
        {nil, _size} -> []
        {_price, nil} -> []
        {price, size} -> [{price, size}]
      end
    end)
    |> Enum.sort_by(fn {price, _size} -> price end, {direction, Decimal})
  end

  defp levels(_absent, _direction), do: []

  defp level_at(row, index) when is_list(row), do: row |> Enum.at(index) |> decimal()

  # The venue also documents an object form for a level in some renderings; read both rather
  # than assuming the array.
  defp level_at(%{} = row, 0), do: decimal(row["price"] || row["0"])
  defp level_at(%{} = row, 1), do: decimal(row["aggregateSize"] || row["1"])
  defp level_at(_row, _index), do: nil

  defp chart_time(ms) when is_integer(ms), do: from_unix_ms(ms)

  defp chart_time(ms) when is_binary(ms) do
    case Integer.parse(ms) do
      {parsed, ""} -> from_unix_ms(parsed)
      _not_an_epoch -> {:error, :missing_venue_timestamp}
    end
  end

  defp chart_time(_absent), do: {:error, :missing_venue_timestamp}

  # `nil` for absent, never zero. Zero is a price and a size, and a field the venue did not
  # send is neither.
  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  # `Decimal.parse/1` requiring the whole string be consumed is NOT a sufficient guard on
  # its own, which is the half this copy was missing. "NaN", "Inf" and "-Inf" all parse
  # fully and case-insensitively — `"-nan"` and `"inf"` too — so each arrived here as a
  # perfectly well-formed `Decimal` and flowed onward as a real price.
  #
  # That is worse than the raise this parse replaced, and it fails a long way from the
  # cause. Measured: `Decimal.add(nan, 1)` is NaN, so it poisons a consumer's arithmetic
  # silently; `Decimal.compare(nan, _)` RAISES `invalid_operation: operation on NaN`, in
  # the consumer's own process, with a message naming Decimal rather than the venue that
  # sent it. An Infinity is quieter still — it compares greater than everything and never
  # raises at all.
  #
  # `dp_exchange_webull` found this and guarded both of its own copies; the other four
  # venues guarded none of their nine. Fixed where it was found, not where it applied —
  # which is why this comment is in each of them now rather than one of them.
  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {parsed, ""} ->
        if Decimal.nan?(parsed) or Decimal.inf?(parsed), do: nil, else: parsed

      _unparsable ->
        nil
    end
  end

  defp decimal(_other), do: nil
end
