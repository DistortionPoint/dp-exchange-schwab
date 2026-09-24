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

  alias DpExchange.Core.Types.{Order, OrderLeg}
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

  @doc """
  Instructions the venue accepts for equities.

  Reachable through the facade as `DpExchange.Schwab.equity_instructions/0` — a caller
  building a request can check against this before sending, the same way
  `transaction_types/0` lets a caller check the venue's type enum before sending. Order
  writes are throttled here and reads are not, so this is worth checking rather than
  discovering by refusal.
  """
  @spec equity_instructions() :: [String.t()]
  def equity_instructions, do: @equity_instructions

  @doc """
  Instructions the venue accepts for options.

  Reachable through the facade as `DpExchange.Schwab.option_instructions/0` — see
  `equity_instructions/0`.
  """
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

  # **`Decimal.to_string/1` defaults to SCIENTIFIC notation.** So a price carrying an
  # exponent went onto the wire as `"1.5E+2"` or `"1E-8"` — not a number this venue reads,
  # and a different order if it read one at all.
  #
  # An exponent is not exotic. `Decimal.normalize/1` — the ordinary way to strip trailing
  # zeros — turns `150.00` into `1.5E+2`, and anything below a millionth carries one by
  # construction. A caller normalising a price before placing an order is doing something
  # entirely reasonable.
  #
  # Four of the five packages in this family already said `:normal` somewhere — including
  # `Rest.chain_value/1` in this very repo — and none of them had said it on the order path,
  # which is the one that spends money.
  defp maybe_put(payload, key, %Decimal{} = value),
    do: Map.put(payload, key, Decimal.to_string(value, :normal))

  defp maybe_put(payload, key, value), do: Map.put(payload, key, to_string(value))
  # --- reading an order back --------------------------------------------------

  @order_types_in %{
    "MARKET" => :market,
    "LIMIT" => :limit,
    "STOP" => :stop,
    "STOP_LIMIT" => :stop_limit
  }

  # The inverse of `@durations`, which is what this module SENDS — so reading back an order
  # this package placed yields the same atom it was placed with.
  @durations_in Map.new(@durations, fn {atom, wire} -> {wire, atom} end)

  @doc """
  One venue order object — the OpenAPI `Order` schema — as a `Core.Types.Order`.

  ## Why this exists

  `get_order/3` and `get_orders/2` are `@impl` of `Core.Venue` callbacks typed
  `result(Types.Order.t())` and `result([Types.Order.t()])`, and both handed back the
  venue's raw JSON map instead. A consumer writing venue-agnostic code that matched
  `%Order{}`, or read `order.status`, broke on this venue and only this one. The fake did the
  same, so the conformance suite — which drives fakes — could not see it; found by feeding the
  real facade plausible response bodies and reading what came back.

  ## Mapping, read from the vendor's committed OpenAPI document

  Every enum below is the `accounts-and-trading-production.openapi.json` schema's own list.
  **A value Core has no word for becomes `nil`, never the nearest atom** — `TRAILING_STOP`
  is not `:stop`, `REPLACED` is not `:cancelled`, `EXCHANGE` is not a side. Read from the
  document and not probed live: this repository holds no Schwab credentials.

  `WORKING` is `:open`, or `:partially_filled` when the venue's own `filledQuantity` is above
  zero — Schwab has no partial-fill status of its own, and that field is its statement of
  one. A single-leg order carries that leg's symbol and side; a spread carries neither at
  the top and reports its legs, each with a `ratio` taken as the leg quantities over their
  greatest common divisor — the definition of a spread ratio, not an estimate of one.

  An order with no `orderId` is `{:error, {:missing_required_field, :id}}`: one a caller
  cannot cancel, replace or look up again is not an order it can use.
  """
  @spec from_venue(term()) :: {:ok, Order.t()} | {:error, term()}
  def from_venue(%{"orderId" => id} = order)
      when is_integer(id) or (is_binary(id) and id != "") do
    legs = order |> Map.get("orderLegCollection") |> List.wrap() |> Enum.filter(&is_map/1)
    {symbol, side, spread_legs} = leg_fields(legs)

    {:ok,
     %Order{
       id: to_string(id),
       symbol: symbol,
       side: side,
       order_type: @order_types_in[order["orderType"]],
       time_in_force: @durations_in[order["duration"]],
       quantity: number(order["quantity"]),
       price: number(order["price"]),
       stop_price: number(order["stopPrice"]),
       filled_quantity: number(order["filledQuantity"]),
       status: status(order["status"], number(order["filledQuantity"])),
       legs: spread_legs,
       created_at: timestamp(order["enteredTime"]),
       provider: :schwab
     }}
  end

  def from_venue(%{} = _order), do: {:error, {:missing_required_field, :id}}
  def from_venue(_other), do: {:error, :unexpected_response_shape}

  @doc """
  A list of venue orders, all or nothing.

  Refused whole if any one cannot be read — this package's rule for a row it cannot address,
  stated on `Rest.get_option_chain/3`: a list with an entry silently missing reads as complete.
  """
  @spec list_from_venue(term()) :: {:ok, [Order.t()]} | {:error, term()}
  def list_from_venue(orders) when is_list(orders) do
    orders
    |> Enum.reduce_while({:ok, []}, fn order, {:ok, acc} ->
      case from_venue(order) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  def list_from_venue(_other), do: {:error, :unexpected_response_shape}

  @buys ~w(BUY BUY_TO_COVER BUY_TO_OPEN BUY_TO_CLOSE)
  @sells ~w(SELL SELL_SHORT SELL_TO_OPEN SELL_TO_CLOSE SELL_SHORT_EXEMPT)

  defp leg_fields([leg]), do: {leg_symbol(leg), leg_side(leg), []}

  defp leg_fields([_first, _second | _rest] = legs) do
    quantities = Enum.map(legs, &whole(number(&1["quantity"])))

    spread_legs =
      if Enum.all?(quantities, &(is_integer(&1) and &1 > 0)) do
        divisor = Enum.reduce(quantities, &Integer.gcd/2)

        legs
        |> Enum.zip(quantities)
        |> Enum.map(fn {leg, quantity} ->
          %OrderLeg{
            symbol: leg_symbol(leg),
            side: leg_side(leg),
            ratio: div(quantity, divisor),
            position_effect: position_effect(leg["positionEffect"]),
            instrument_type: instrument_type(leg["orderLegType"])
          }
        end)
      end

    # A spread has no single symbol or side; saying one would be naming one leg as the order.
    {nil, nil, spread_legs}
  end

  defp leg_fields(_no_legs), do: {nil, nil, []}

  defp leg_symbol(%{"instrument" => %{"symbol" => symbol}}) when is_binary(symbol),
    do: SymbolFormat.to_canonical_symbol(symbol)

  defp leg_symbol(_leg), do: nil

  defp leg_side(%{"instruction" => instruction}) when instruction in @buys, do: :buy
  defp leg_side(%{"instruction" => instruction}) when instruction in @sells, do: :sell
  defp leg_side(_leg), do: nil

  defp position_effect("OPENING"), do: :open
  defp position_effect("CLOSING"), do: :close
  defp position_effect(_other), do: nil

  defp instrument_type("EQUITY"), do: :equity
  defp instrument_type("OPTION"), do: :option
  defp instrument_type(_other), do: nil

  @pending ~w(NEW ACCEPTED QUEUED PENDING_ACTIVATION PENDING_ACKNOWLEDGEMENT AWAITING_PARENT_ORDER
              AWAITING_CONDITION AWAITING_STOP_CONDITION AWAITING_MANUAL_REVIEW AWAITING_UR_OUT
              AWAITING_RELEASE_TIME)
  @still_live ~w(PENDING_CANCEL PENDING_REPLACE PENDING_RECALL)

  defp status("WORKING", filled) do
    if match?(%Decimal{}, filled) and Decimal.gt?(filled, 0), do: :partially_filled, else: :open
  end

  defp status("FILLED", _filled), do: :filled
  defp status("CANCELED", _filled), do: :cancelled
  defp status("REJECTED", _filled), do: :rejected
  defp status("EXPIRED", _filled), do: :expired
  defp status(pending, _filled) when pending in @pending, do: :pending
  defp status(live, _filled) when live in @still_live, do: :open
  defp status(_replaced_or_unknown, _filled), do: nil

  defp number(value) when is_integer(value), do: Decimal.new(value)
  defp number(value) when is_float(value), do: Decimal.from_float(value)

  defp number(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {parsed, ""} -> if Decimal.nan?(parsed) or Decimal.inf?(parsed), do: nil, else: parsed
      _unreadable -> nil
    end
  end

  defp number(_absent), do: nil

  defp whole(%Decimal{} = value) do
    if Decimal.integer?(value), do: Decimal.to_integer(value), else: nil
  end

  defp whole(_other), do: nil

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _unreadable -> timestamp_compact(value)
    end
  end

  defp timestamp(_absent), do: nil

  # Schwab writes `enteredTime` as `2024-03-29T14:05:31+0000` — an offset with no colon, which
  # `DateTime.from_iso8601/1` does not accept.
  defp timestamp_compact(value) do
    case Regex.run(~r/^(.*)([+-])(\d{2})(\d{2})$/, value) do
      [_all, head, sign, hours, minutes] ->
        case DateTime.from_iso8601("#{head}#{sign}#{hours}:#{minutes}") do
          {:ok, at, _offset} -> at
          _unreadable -> nil
        end

      _no_offset ->
        nil
    end
  end
end
