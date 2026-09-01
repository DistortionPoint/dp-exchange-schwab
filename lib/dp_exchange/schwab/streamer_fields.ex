defmodule DpExchange.Schwab.StreamerFields do
  @moduledoc """
  What each numbered field means, per service.

  ## The numbers are not shared between services

  A Streamer data frame keys its content by number, and **the same number means different
  things in different services**. In `LEVELONE_EQUITIES` field 1 is the bid; in
  `CHART_EQUITY` field 1 is the open. There is no global table, and a package that built one
  would decode a candle's open as a bid on every chart frame — a real number in the wrong
  field, which is exactly the failure §0 is written against.

  So each service carries its own map, and `for_service/1` refuses a service it has no map
  for rather than falling back to another one's.

  ## Partial by design, and that is safe

  These maps name the fields this package uses. A frame carries more, and
  `StreamerProtocol.rename/2` **drops** anything unnamed. Dropping is the safe direction: an
  unnamed field is absent, where a guessed name is wrong.

  Read from the vendor's prose documentation, committed at
  `docs/reference/schwab/documentation/market-data-production.txt`, 2026-09-01. Every entry
  below is transcribed from a numbered table there.
  """

  # LEVELONE_EQUITIES, from the vendor's field table. Fields 0–13 are transcribed; the
  # service publishes more and this names what the package reads.
  @level_one_equities %{
    "0" => :symbol,
    "1" => :bid,
    "2" => :ask,
    "3" => :last,
    "4" => :bid_size,
    "5" => :ask_size,
    "6" => :ask_id,
    "7" => :bid_id,
    "8" => :total_volume,
    "9" => :last_size,
    "10" => :high,
    "11" => :low,
    # **The previous day's close, not this bar's.** The vendor: "Previous day's closing
    # price… updated from the DB at 3:30 AM ET." Reading it as a current price would be a
    # yesterday's number wearing today's timestamp.
    "12" => :previous_close,
    "13" => :exchange_id
  }

  # LEVELONE_OPTIONS. **Numbered differently from LEVELONE_EQUITIES from field 1 onward** —
  # field 1 is the description here and the bid there. This is the clearest case for why
  # these maps are per service.
  @level_one_options %{
    "0" => :symbol,
    "1" => :description,
    "2" => :bid,
    "3" => :ask,
    "4" => :last,
    "5" => :high,
    "6" => :low,
    # Previous day's close, per the vendor: "updated from the DB at 7:29AM ET."
    "7" => :previous_close,
    "8" => :total_volume,
    "9" => :open_interest,
    "10" => :volatility,
    "11" => :money_intrinsic_value,
    "12" => :expiration_year,
    "16" => :bid_size,
    "17" => :ask_size,
    "18" => :last_size
  }

  # LEVELONE_FUTURES. Fields 0–5 match LEVELONE_EQUITIES and then they diverge:
  #
  #   EQUITIES  6 => Ask ID, 7 => Bid ID
  #   FUTURES   6 => Bid ID, 7 => Ask ID
  #
  # **The exchange identifiers are swapped between the two services.** A shared map would
  # report the bid's exchange as the ask's on every futures frame, and both values would be
  # real exchange codes — nothing downstream would notice.
  #
  # Futures also carry their own `quote_time` and `trade_time` at 10 and 11, which
  # LEVELONE_EQUITIES does not publish in the fields this package reads.
  @level_one_futures %{
    "0" => :symbol,
    "1" => :bid,
    "2" => :ask,
    "3" => :last,
    "4" => :bid_size,
    "5" => :ask_size,
    "6" => :bid_id,
    "7" => :ask_id,
    "8" => :total_volume,
    "9" => :last_size,
    "10" => :quote_time,
    "11" => :trade_time,
    "12" => :high
  }

  # LEVELONE_FOREX. Fields 0–5 match again, and then this one differs from BOTH of the
  # others: 6 is the total volume here, where equities put an exchange id and futures put a
  # bid id.
  @level_one_forex %{
    "0" => :symbol,
    "1" => :bid,
    "2" => :ask,
    "3" => :last,
    "4" => :bid_size,
    "5" => :ask_size,
    "6" => :total_volume,
    "7" => :last_size
  }

  # CHART_EQUITY. Note field 1 is the OPEN here and the BID in LEVELONE_EQUITIES — the
  # reason this module exists.
  @chart_equity %{
    "0" => :symbol,
    "1" => :open,
    "2" => :high,
    "3" => :low,
    "4" => :close,
    "5" => :volume,
    "6" => :sequence,
    # Milliseconds since epoch, and the bar's own time — not when the frame arrived.
    "7" => :chart_time,
    "8" => :chart_day
  }

  @maps %{
    "LEVELONE_EQUITIES" => @level_one_equities,
    # The vendor lists both names; they carry the same field numbering.
    "LEVELONE_EQUITY" => @level_one_equities,
    "LEVELONE_OPTIONS" => @level_one_options,
    "LEVELONE_FUTURES" => @level_one_futures,
    # The vendor documents futures options with the futures numbering.
    "LEVELONE_FUTURES_OPTIONS" => @level_one_futures,
    "LEVELONE_FOREX" => @level_one_forex,
    "CHART_EQUITY" => @chart_equity,
    "CHART_FUTURES" => @chart_equity
  }

  @doc """
  The field map for `service`.

  **An error rather than a fallback for a service with no map.** Falling back to another
  service's numbering is how a candle's open becomes a bid.
  """
  @spec for_service(String.t()) :: {:ok, %{String.t() => atom()}} | {:error, term()}
  def for_service(service) do
    case Map.fetch(@maps, service) do
      {:ok, map} -> {:ok, map}
      :error -> {:error, {:no_field_map, service}}
    end
  end

  @doc """
  Every service this module can decode.

  Deliberately fewer than `StreamerProtocol.services/0`: the venue carries fifteen and this
  names the fields for the ones the package reads. The gap is visible on purpose — a service
  with no map is undecoded, not undocumented.
  """
  @spec decodable() :: [String.t()]
  def decodable, do: @maps |> Map.keys() |> Enum.sort()
end
