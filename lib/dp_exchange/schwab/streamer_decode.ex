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
  * `LEVELONE_OPTIONS` names the pair at fields 38 and 39 and `LEVELONE_FOREX` at 8 and 9,
    "Quote Time in Long" / "Trade Time in Long" and "Quote Time" / "Trade Time" (the
    service tables in `market-data-production.txt`). A frame that does not carry them
    gets `venue_time: nil`, as below.

  Where a service carries one, `to_quote/3` and `to_top_of_book/3` use it; where it does
  not, or the frame did not include it, `venue_time` is `nil`. It is never filled from
  `observed_at`, which is a separate field stating only when the frame arrived (the socket
  passes that time in).

  `nil` there is not an oversight. It says the venue did not stamp this frame, which is the
  difference between "quoted at 14:53:02" and "seen at 14:53:02". This used to say
  `LEVELONE_*` carried no venue time in the fields this package reads at all — true when it
  was written, false once `StreamerFields` started naming these fields for the services
  that document them.
  """

  alias DpExchange.Core.Types.{Candle, OrderBook, Quote, TopOfBook}
  alias DpExchange.Schwab.Bound

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
    with {:ok, price} <- required_decimal(last, :price),
         :ok <- traded_price(price) do
      # **The day's cumulative volume, labelled `:running_total`, as REST does.** `:print` is
      # only true where every print is delivered, and LEVELONE is CONFLATED ("Data is
      # conflated by the streamer"): `last_size` is the size of whichever trade the
      # streamer happened to emit last, so it is neither a sum of prints nor a figure to
      # difference, and calling it `:print` told a consumer it could add frames up (tick R,
      # MD8; it did, until then). `total_volume` is the venue's cumulative figure and is
      # what a consumer differences. Read rather than required: `:volume` is not enforced on
      # `Core.Types.Quote`, so an absent or unreadable total is `nil`, the window with it,
      # and the quote still stands. A NEGATIVE total is not a volume either: it is unreadable
      # and reads as `nil` (see `volume_decimal/1`), never as a cumulative figure below zero.
      volume = volume_decimal(Map.get(fields, :total_volume))

      {:ok,
       %Quote{
         symbol: symbol,
         price: price,
         volume: volume,
         volume_window: volume && :running_total,
         # **The venue's own trade time, where the service names one — `nil` otherwise.**
         # `LEVELONE_EQUITIES` field 35, `LEVELONE_OPTIONS` 39, `LEVELONE_FUTURES`/
         # `LEVELONE_FUTURES_OPTIONS` 11 and `LEVELONE_FOREX` 9 — "Trade Time in Long" /
         # "Trade Time", the last trade time in milliseconds since epoch (see the moduledoc's
         # table) — is the venue's own statement of when the `last` price this `Quote`
         # reports actually traded, read in preference to the frame's arrival time whenever
         # the frame carries it.
         #
         # This used to be unconditional `nil`, on the premise that no `LEVELONE_*` service
         # carried a venue timestamp at all in the fields this package read — false for
         # all five once `StreamerFields` named these fields. Before that, it was `timestamp:
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

  # **Zero is not a traded price.** An option that has not traded today, or an equity before
  # its first print, streams `last` as `0` rather than omitting it, and a `Quote` built from
  # that reports a price at which nothing traded - the same "nearby substitute" the REST arm
  # refuses (`Rest.get_price/3` skips a zero `lastPrice`, and falls to `mark` there). The
  # streamer has no `mark` field here to fall to, so the frame yields no quote. A negative
  # `last` is refused with it, as on the REST arm. Whether the venue streams a zero for an
  # untraded instrument is read from the REST arm's own precedent and not measured.
  defp traded_price(price),
    do: if(Decimal.positive?(price), do: :ok, else: {:error, :no_traded_price})

  @doc """
  A `TopOfBook` from a `LEVELONE_*` frame.

  Sizes are the venue's own and are **in lots, not shares** for equities — the vendor says
  so, and this package does not multiply by 100: a lot size is not universally 100, and a
  package guessing the multiplier would report a size the venue never sent.

  `venue_time` is the venue's own quote time where the service names one — `LEVELONE_EQUITIES`
  field 34, `LEVELONE_OPTIONS` 38, `LEVELONE_FUTURES`/`LEVELONE_FUTURES_OPTIONS` 10 and
  `LEVELONE_FOREX` 8, "the last time a bid or ask updated" (see the moduledoc's table) — and
  `nil` where the frame did not carry it. `observed_at` is when the frame arrived either way,
  and the pair together is the honest statement of freshness this type promises.

  A present side that cannot be read, or is negative, is
  `{:error, {:invalid_decimal, :bid | :ask | :bid_size | :ask_size, value}}`.

  ## This returns the frame's DELTA, and is not what crosses the facade

  `LEVELONE_*` is Change delivery, so a frame states only what moved and this function can
  only report what the frame stated. The result is therefore a partial book: a field absent
  here means "the venue did not mention it", which is **not** what a `nil` means on
  `Core.Types.TopOfBook` — there it says the level does not exist.

  `Socket.merge_top_of_book/3` resolves that, folding this delta onto the last book published
  for the symbol, and the merged snapshot is what a consumer receives. Nothing that calls
  this function directly should publish its result.
  """
  @spec to_top_of_book(map(), String.t(), DateTime.t()) ::
          {:ok, TopOfBook.t()} | {:error, term()}
  def to_top_of_book(fields, symbol, observed_at) do
    with {:ok, {bid, bid_size}} <- book_side(fields, :bid, :bid_size),
         {:ok, {ask, ask_size}} <- book_side(fields, :ask, :ask_size) do
      {:ok,
       %TopOfBook{
         symbol: symbol,
         bid: bid,
         ask: ask,
         bid_size: bid_size,
         ask_size: ask_size,
         venue_time: field_time(fields, :quote_time),
         observed_at: observed_at,
         provider: :schwab
       }}
    end
  end

  # One side of the top of book, `{price, size}`.
  #
  # **A price of 0 means no resting order on that side** (`nil` price, `nil` size), exactly as
  # on the REST arm; a bid of zero is not a bid. **A present side that cannot be read refuses**
  # the whole frame's book - `{:error, {:invalid_decimal, :bid, value}}` - and is never turned
  # into `nil`, which `TopOfBook` reads as "no resting order": an unreadable price must not
  # become a statement about the market. A negative price refuses with it. An ABSENT price
  # (`nil`: this Change frame did not mention the side) is `nil` and the size is whatever the
  # frame carried; `Socket` merges that onto the last book.
  #
  # **A size that is present must be readable too, and not negative** (the same rule as an
  # unreadable book level): `{:error, {:invalid_decimal, :bid_size, value}}`. An unreadable
  # size used to become `nil` ("not published") while the price beside it was published as
  # a live level. An absent size is `nil`; a size of 0 is a size of 0.
  #
  # The price is judged first, as on the REST arm: a price of 0 is "no resting order" and its
  # size is moot, so an unreadable size beside it does not refuse the frame.
  defp book_side(fields, price_key, size_key) do
    size_raw = Map.get(fields, size_key)

    case Map.get(fields, price_key) do
      nil ->
        with {:ok, size} <- book_size(size_raw, size_key), do: {:ok, {nil, size}}

      raw ->
        raw |> decimal() |> side_price(raw, price_key, size_raw, size_key)
    end
  end

  defp book_size(nil, _size_key), do: {:ok, nil}

  defp book_size(raw, size_key) do
    case decimal(raw) do
      nil ->
        {:error, {:invalid_decimal, size_key, raw}}

      size ->
        if Decimal.negative?(size),
          do: {:error, {:invalid_decimal, size_key, raw}},
          else: {:ok, size}
    end
  end

  defp side_price(nil, raw, price_key, _size_raw, _size_key),
    do: {:error, {:invalid_decimal, price_key, raw}}

  defp side_price(price, raw, price_key, size_raw, size_key) do
    case Decimal.compare(price, 0) do
      :gt -> with {:ok, size} <- book_size(size_raw, size_key), do: {:ok, {price, size}}
      :eq -> {:ok, {nil, nil}}
      :lt -> {:error, {:invalid_decimal, price_key, raw}}
    end
  end

  @doc """
  A `Candle` from a `CHART_*` frame.

  `chart_time` is milliseconds since epoch and is **the bar's opening**, which is what
  `:opened_at` means. A bar without it is refused: a chart bar wearing the arrival time
  would be placed in the series at the wrong minute, and every value in it would still be
  real.

  `timeframe` is the caller's, because the venue's chart services stream one width and do
  not name it in the frame.

  Errors: `{:error, :missing_venue_timestamp}` (no usable `chart_time`),
  `{:error, {:invalid_decimal, field, value}}` (a price absent or unreadable),
  `{:error, {:non_positive_price, field, value}}` and `{:error, :incoherent_candle}`.

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

  `Rest`'s own candle decode — the REST arm of the same type — already guarded all four.
  This was the copy that did not.

  `volume` is not required: it is not an enforced key on `Candle`, and a frame that did not
  state a volume has not stated one. An unreadable or **negative** one is `nil` as well, and the
  bar stands.
  """
  @spec to_candle(map(), String.t(), String.t()) :: {:ok, Candle.t()} | {:error, term()}
  def to_candle(fields, symbol, timeframe) do
    with {:ok, opened_at} <- chart_time(Map.get(fields, :chart_time)),
         {:ok, open} <- required_price(Map.get(fields, :open), :open),
         {:ok, high} <- required_price(Map.get(fields, :high), :high),
         {:ok, low} <- required_price(Map.get(fields, :low), :low),
         {:ok, close} <- required_price(Map.get(fields, :close), :close) do
      bar = %Candle{
        symbol: symbol,
        timeframe: timeframe,
        opened_at: opened_at,
        open: open,
        high: high,
        low: low,
        close: close,
        volume: volume_decimal(Map.get(fields, :volume)),
        provider: :schwab
      }

      # As `Rest`'s copy: an incoherent bar (high below low, open or close) is refused.
      if Candle.coherent?(bar), do: {:ok, bar}, else: {:error, :incoherent_candle}
    end
  end

  # A traded volume is never below zero. A negative figure from the venue is a fault, not a
  # statement, and carrying it would hand a consumer differencing the cumulative total a
  # volume that runs backwards. Volume is not an enforced key on `Quote` or `Candle`, so an
  # unreadable one is `nil` ("not stated") and the price beside it stands.
  defp volume_decimal(value) do
    case decimal(value) do
      %Decimal{} = volume -> if Decimal.negative?(volume), do: nil, else: volume
      nil -> nil
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

  # A traded price on a bar (tick R, MD6): zero or negative refuses the bar, as an unreadable
  # one does. A bar opening at 0 is a venue fault, not a market that traded at nothing.
  defp required_price(value, field) do
    with {:ok, parsed} <- required_decimal(value, field) do
      if Decimal.positive?(parsed),
        do: {:ok, parsed},
        else: {:error, {:non_positive_price, field, value}}
    end
  end

  # Reads a `LEVELONE_*` service's own timestamp field — `:quote_time` or `:trade_time`,
  # milliseconds since epoch on the services that name them (see `to_quote/3`'s and
  # `to_top_of_book/3`'s docs) — and answers `nil` for anything that is not a usable
  # instant: absent (the service does not name this field, or a Change-delivery frame did
  # not carry it this time), non-positive, or out of `DateTime.from_unix/2`'s range. `nil`
  # is not a decode fault here the way it is for `to_candle/3`'s prices or
  # `to_order_book/2`'s snapshot time — a `LEVELONE_*` quote or top of book is valid
  # without a venue timestamp: `venue_time` is `nil` and `observed_at` states arrival.
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

  ## An unreadable level refuses the book

  `{:error, {:unreadable_level, :bids | :asks, value}}` for a level without a readable price
  or size, a price <= 0, a negative size, or a side that is present but not a list. A level
  of size 0 is no liquidity and is dropped. Nothing is silently thinned.
  """
  @spec to_order_book(map(), String.t()) :: {:ok, OrderBook.t()} | {:error, term()}
  def to_order_book(fields, symbol) do
    with {:ok, timestamp} <- snapshot_time(Map.get(fields, :snapshot_time)),
         {:ok, bids} <- levels(Map.get(fields, :bids), :bids, :desc),
         {:ok, asks} <- levels(Map.get(fields, :asks), :asks, :asc) do
      {:ok,
       %OrderBook{
         symbol: symbol,
         bids: bids,
         asks: asks,
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

  # A level is `[price, aggregate_size, …]`.
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
  #
  # **An unreadable level refuses the whole book** (tick R, MD5). Levels missing a price or a
  # size used to be dropped, and a side that was not a list became `[]`: every remaining level
  # was true and the book was silently thinner than the venue's, which is how a wrong best
  # price gets published. Now `{:error, {:unreadable_level, side, value}}`: a level that is not
  # `[price, size, ...]` (or the object form), has no readable price or size, a price <= 0 or
  # a negative size; and a side that is present but not a list. A side that is ABSENT (`nil`)
  # is empty. A size of exactly 0 is no liquidity at that price and is dropped.
  defp levels(rows, side, direction) when is_list(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case level(row) do
        {:ok, level} -> {:cont, {:ok, [level | acc]}}
        :empty -> {:cont, {:ok, acc}}
        :unreadable -> {:halt, {:error, {:unreadable_level, side, bounded_value(row)}}}
      end
    end)
    |> case do
      {:ok, built} ->
        {:ok, Enum.sort_by(built, fn {price, _size} -> price end, {direction, Decimal})}

      error ->
        error
    end
  end

  defp levels(nil, _side, _direction), do: {:ok, []}

  defp levels(other, side, _direction),
    do: {:error, {:unreadable_level, side, bounded_value(other)}}

  # The venue's value, quoted into an error tuple: a small one comes back as sent, a large one
  # (a whole book sent where a level was expected) is cut so a hostile or broken frame cannot
  # ride the error into every log.
  defp bounded_value(value) do
    if :erlang.external_size(value) <= 512, do: value, else: Bound.text(value)
  end

  defp level(row) do
    case {level_at(row, 0), level_at(row, 1)} do
      {nil, _size} -> :unreadable
      {_price, nil} -> :unreadable
      {price, size} -> classify_level({price, size}, Decimal.compare(price, 0), size)
    end
  end

  defp classify_level(level, :gt, size) do
    case Decimal.compare(size, 0) do
      :gt -> {:ok, level}
      :eq -> :empty
      :lt -> :unreadable
    end
  end

  defp classify_level(_level, _non_positive_price, _size), do: :unreadable

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
  defp decimal(%Decimal{} = value), do: finite_decimal(value)
  defp decimal(value) when is_integer(value), do: value |> Decimal.new() |> finite_decimal()
  defp decimal(value) when is_float(value), do: value |> Decimal.from_float() |> finite_decimal()

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
      {parsed, ""} -> finite_decimal(parsed)
      _unparsable -> nil
    end
  end

  defp decimal(_other), do: nil

  # NaN, Infinity and an exponent beyond +-1000 (`1E999999999` is finite to `Decimal`, and
  # the first compare or add against it allocates a huge integer) are not a number here.
  #
  # And a coefficient of 34 or more digits (decimal128's limit; chosen, not measured): an
  # integer carries exponent 0, so only this stops a million-digit "price".
  @max_coefficient Integer.pow(10, 34)

  defp finite_decimal(%Decimal{exp: exp} = value) do
    cond do
      Decimal.nan?(value) or Decimal.inf?(value) -> nil
      abs(exp) > 1000 -> nil
      value.coef >= @max_coefficient -> nil
      true -> value
    end
  end
end
