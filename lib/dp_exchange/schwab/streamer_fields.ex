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
