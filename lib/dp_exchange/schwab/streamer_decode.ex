defmodule DpExchange.Schwab.StreamerDecode do
  @moduledoc """
  Streamer data frames into the contract's value types.

  Pure functions. The socket hands frames here and gets `Quote`, `TopOfBook` or `Candle`
  back — or an error, which is the point of several of the rules below.

  ## A LEVELONE frame is two different things at once

  It carries `bid`, `ask` **and** `last` in one payload. Those are not the same fact: the
  first two are resting orders and the third is an execution. So one frame decodes to a
  `Quote` *or* a `TopOfBook` depending on which was asked for, and **never to a `Quote`
  whose price came from the bid** — the defect this family has found five times.

  A frame with no `last` yields no quote. `{:error, :no_traded_price}` is the honest answer;
  substituting the bid, the ask or the midpoint would produce a price nobody traded at.

  ## The venue's own time, and when it is absent

  `CHART_EQUITY` stamps each bar with `chart_time` in milliseconds, and that is the bar's
  opening. `LEVELONE_*` frames carry no timestamp of their own in the fields this package
  reads — so a quote decoded from one takes **the frame's arrival time**, which the socket
  passes in, and a top of book records it as `observed_at` with `venue_time: nil`.

  `nil` there is not an oversight. It says the venue did not stamp this frame, which is the
  difference between "quoted at 14:53:02" and "seen at 14:53:02".
  """

  alias DpExchange.Core.Types.{Candle, Quote, TopOfBook}

  @doc """
  A `Quote` from a `LEVELONE_*` frame.

  **`last` and nothing else.** A frame without it is `{:error, :no_traded_price}`: bid and
  ask are resting orders, and a quote built from one reports a price at which nothing
  traded.

  `observed_at` is when the frame arrived, because these frames carry no venue time.
  """
  @spec to_quote(map(), String.t(), DateTime.t()) :: {:ok, Quote.t()} | {:error, term()}
  def to_quote(%{last: last} = fields, symbol, observed_at) when last != nil do
    {:ok,
     %Quote{
       symbol: symbol,
       price: decimal(last),
       # The venue's `total_volume` is the day's aggregate, not this trade's. `last_size` is
       # the trade's own, and it is the one a Quote's volume means.
       volume: decimal(Map.get(fields, :last_size)),
       timestamp: observed_at,
       provider: :schwab
     }}
  end

  def to_quote(_fields, _symbol, _observed_at), do: {:error, :no_traded_price}

  @doc """
  A `TopOfBook` from a `LEVELONE_*` frame.

  Sizes are the venue's own and are **in lots, not shares** for equities — the vendor says
  so, and this package does not multiply by 100: a lot size is not universally 100, and a
  package guessing the multiplier would report a size the venue never sent.

  `venue_time` is `nil` because these frames carry none; `observed_at` is when the frame
  arrived, and the pair together is the only honest statement of freshness.
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
       venue_time: nil,
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
  """
  @spec to_candle(map(), String.t(), String.t()) :: {:ok, Candle.t()} | {:error, term()}
  def to_candle(fields, symbol, timeframe) do
    with {:ok, opened_at} <- chart_time(Map.get(fields, :chart_time)) do
      {:ok,
       %Candle{
         symbol: symbol,
         timeframe: timeframe,
         opened_at: opened_at,
         open: decimal(Map.get(fields, :open)),
         high: decimal(Map.get(fields, :high)),
         low: decimal(Map.get(fields, :low)),
         close: decimal(Map.get(fields, :close)),
         volume: decimal(Map.get(fields, :volume)),
         provider: :schwab
       }}
    end
  end

  defp chart_time(ms) when is_integer(ms), do: {:ok, DateTime.from_unix!(ms, :millisecond)}

  defp chart_time(ms) when is_binary(ms) do
    case Integer.parse(ms) do
      {parsed, ""} -> {:ok, DateTime.from_unix!(parsed, :millisecond)}
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

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> decimal
      _unparsable -> nil
    end
  end

  defp decimal(_other), do: nil
end
