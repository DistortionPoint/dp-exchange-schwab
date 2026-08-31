defmodule DpExchange.Schwab.Orders do
  @moduledoc """
  Building Schwab order payloads, and refusing the ones the venue publishes as invalid —
  internal.

  ## An order here is a strategy with legs

  Every worked example in the venue's documentation has the same skeleton: an outer
  strategy carrying `orderType`, `session`, `duration` and `orderStrategyType`, and an
  `orderLegCollection` of instruments and instructions. `Core.Venue.place_order/3` takes
  a flat request — one symbol, one side, one quantity — so this module builds the
  single-leg `SINGLE` strategy that shape corresponds to, and nothing else.

  Multi-leg spreads, `TRIGGER` and `OCO` nest whole orders inside `childOrderStrategies`
  and are unreachable through the contract. That is a Core gap, recorded rather than
  worked around: inventing a request shape here would put venue vocabulary into a
  consumer's code, which is exactly what the facade exists to prevent (D12).

  ## `session` has no slot in the contract, and it is required

  Every documented example carries it, including the simplest market order. Nothing in
  `Core` expresses "which trading session", because every crypto venue trades
  continuously. `NORMAL` is used unless the caller overrides it, and that default is
  stated here rather than hidden: it is the session a person placing an order by hand
  would get, and the alternative is refusing every order until Core grows the field.

  ## The instruction matrix is published, so a mismatch is refused locally

  Schwab documents which instructions each asset type accepts, and the table is
  exhaustive. That is worth using rather than discovering: on this venue **order writes
  are the throttled operation and reads are free**, so an order rejected for a knowable
  reason has spent a scarce slot to learn something the documentation already said.
  """

  alias DpExchange.Schwab.SymbolFormat

  # Read verbatim from the venue's "Instruction for EQUITY and OPTION" table.
  @equity_instructions ~w(BUY SELL BUY_TO_COVER SELL_SHORT)
  @option_instructions ~w(BUY_TO_OPEN BUY_TO_CLOSE SELL_TO_OPEN SELL_TO_CLOSE)

  # Core's vocabulary => Schwab's. Only the four Core can name; the venue's
  # TRAILING_STOP, MARKET_ON_CLOSE, LIMIT_ON_CLOSE and NET_* have no Core atom (7.5).
  @order_types %{
    market: "MARKET",
    limit: "LIMIT",
    stop: "STOP",
    stop_limit: "STOP_LIMIT",
    trailing_stop: "TRAILING_STOP",
    trailing_stop_limit: "TRAILING_STOP_LIMIT",
    market_on_close: "MARKET_ON_CLOSE",
    limit_on_close: "LIMIT_ON_CLOSE"
  }

  # A trailing stop is not a price, it is an *offset from a moving reference*, and Schwab
  # needs all three parts: what to trail (`stopPriceLinkBasis`), whether the offset is a
  # value, a percent or ticks (`stopPriceLinkType`), and the offset itself
  # (`stopPriceOffset`). Nothing in `Core`'s request vocabulary names them, so they are
  # taken from the request under their venue names and **required** — a trailing stop
  # missing its offset is not a trailing stop, and the venue would reject it after
  # spending one of a small number of writes per minute.
  @trailing_types ["TRAILING_STOP", "TRAILING_STOP_LIMIT"]

  # `duration` is Schwab's name for time-in-force. `:gtd` is deliberately absent: Schwab
  # offers END_OF_WEEK, END_OF_MONTH and NEXT_END_OF_MONTH, which are three fixed
  # horizons rather than an arbitrary date, and picking the nearest would be a guess
  # about what the caller meant.
  @durations %{
    day: "DAY",
    gtc: "GOOD_TILL_CANCEL",
    fok: "FILL_OR_KILL",
    ioc: "IMMEDIATE_OR_CANCEL"
  }

  @doc "Instructions the venue accepts for equities."
  @spec equity_instructions() :: [String.t()]
  def equity_instructions, do: @equity_instructions

  @doc "Instructions the venue accepts for options."
  @spec option_instructions() :: [String.t()]
  def option_instructions, do: @option_instructions

  @doc """
  Build a single-leg order payload from a contract request.

  The request is `Core`'s vocabulary: `:symbol`, `:side`, `:quantity`, and optionally
  `:order_type`, `:price`, `:stop_price`, `:time_in_force`, `:session`.

  Refuses, by name and before any request, when:

  - the order type or time-in-force is outside what this venue serves
  - a limit order carries no price, or a stop order no stop price — the venue would
    reject it, and a locally-refused order has not spent a throttled write
  - the instruction does not match the asset type, per the venue's published matrix
  """
  @spec build(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def build(request, opts \\ []) do
    with {:ok, symbol} <- fetch(request, :symbol),
         {:ok, native} <- SymbolFormat.validate(symbol),
         {:ok, quantity} <- fetch_quantity(request),
         {:ok, order_type} <- fetch_order_type(request),
         {:ok, duration} <- fetch_duration(request),
         {:ok, instruction} <- fetch_instruction(request, native),
         :ok <- check_prices(order_type, request) do
      {:ok,
       %{
         "orderType" => order_type,
         "session" => session(request, opts),
         "duration" => duration,
         "orderStrategyType" => "SINGLE",
         "orderLegCollection" => [
           %{
             "instruction" => instruction,
             "quantity" => quantity,
             "instrument" => %{
               "symbol" => native,
               "assetType" => asset_type(native)
             }
           }
         ]
       }
       |> maybe_put("price", request[:price])
       |> maybe_put("stopPrice", request[:stop_price])
       |> maybe_put("stopPriceOffset", request[:stop_price_offset])
       |> maybe_put("stopPriceLinkBasis", request[:stop_price_link_basis])
       |> maybe_put("stopPriceLinkType", request[:stop_price_link_type])}
    end
  end

  defp fetch(request, key) do
    case Map.get(request, key) do
      nil -> {:error, {:missing_order_field, key}}
      value -> {:ok, value}
    end
  end

  # Fractional is real here — `quantityType` admits DOLLARS and `quantity` is a double —
  # so a non-integer quantity is passed through rather than rounded. Rounding a
  # fractional order to whole shares would change the size silently.
  defp fetch_quantity(request) do
    case Map.get(request, :quantity) do
      nil -> {:error, {:missing_order_field, :quantity}}
      %Decimal{} = quantity -> positive(Decimal.to_float(quantity))
      quantity when is_number(quantity) -> positive(quantity)
      other -> {:error, {:invalid_quantity, other}}
    end
  end

  defp positive(quantity) when quantity > 0, do: {:ok, quantity}
  defp positive(quantity), do: {:error, {:invalid_quantity, quantity}}

  defp fetch_order_type(request) do
    type = Map.get(request, :order_type, :market)

    case Map.fetch(@order_types, type) do
      {:ok, native} -> {:ok, native}
      :error -> {:error, {:unsupported_order_type, type}}
    end
  end

  defp fetch_duration(request) do
    tif = Map.get(request, :time_in_force, :day)

    case Map.fetch(@durations, tif) do
      {:ok, native} -> {:ok, native}
      :error -> {:error, {:unsupported_time_in_force, tif}}
    end
  end

  # `:side` is Core's word. It maps to the plain equity instructions; the open/close
  # forms are option vocabulary a caller supplies explicitly as `:instruction`.
  defp fetch_instruction(request, native) do
    instruction =
      case {Map.get(request, :instruction), Map.get(request, :side)} do
        {nil, :buy} -> "BUY"
        {nil, :sell} -> "SELL"
        {nil, nil} -> nil
        {explicit, _side} when is_binary(explicit) -> String.upcase(explicit)
        {_other, side} -> side
      end

    validate_instruction(instruction, native)
  end

  defp validate_instruction(nil, _native), do: {:error, {:missing_order_field, :side}}

  defp validate_instruction(instruction, native) when is_binary(instruction) do
    allowed =
      if SymbolFormat.option?(native), do: @option_instructions, else: @equity_instructions

    if instruction in allowed do
      {:ok, instruction}
    else
      # The venue publishes this table, so the refusal names both halves rather than
      # letting the venue spend a throttled write to say the same thing.
      {:error, {:instruction_not_valid_for_asset, instruction, asset_type(native)}}
    end
  end

  defp validate_instruction(other, _native), do: {:error, {:invalid_instruction, other}}

  # A limit order without a price and a stop order without a stop price are both
  # rejected by the venue. Refusing here costs nothing; letting them through costs one
  # of a small number of writes per minute.
  defp check_prices(type, request) when type in @trailing_types,
    do: require_fields(request, [:stop_price_offset])

  defp check_prices("LIMIT_ON_CLOSE", request), do: require_fields(request, [:price])

  defp check_prices("LIMIT", request), do: require_fields(request, [:price])
  defp check_prices("STOP", request), do: require_fields(request, [:stop_price])
  defp check_prices("STOP_LIMIT", request), do: require_fields(request, [:stop_price, :price])
  defp check_prices(_market, _request), do: :ok

  # Checked in order, so a stop_limit missing both names the stop price first — the field
  # that makes it a stop at all.
  defp require_fields(request, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case Map.get(request, key) do
        nil -> {:halt, {:error, {:missing_order_field, key}}}
        _present -> {:cont, :ok}
      end
    end)
  end

  defp session(request, opts) do
    Map.get(request, :session) || Keyword.get(opts, :session) || "NORMAL"
  end

  defp asset_type(native), do: if(SymbolFormat.option?(native), do: "OPTION", else: "EQUITY")

  defp maybe_put(payload, _key, nil), do: payload

  defp maybe_put(payload, key, %Decimal{} = value),
    do: Map.put(payload, key, Decimal.to_string(value))

  defp maybe_put(payload, key, value), do: Map.put(payload, key, to_string(value))
end
