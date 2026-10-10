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

  An override is the venue's own `NORMAL`, `AM`, `PM` or `SEAMLESS` (any case), or one of
  Core's `capabilities().supported_sessions` atoms: `:regular` is `NORMAL`, `:pre_market` is
  `AM`, `:post_market` is `PM` and `:extended` is `SEAMLESS`. Anything else is
  `{:error, {:unsupported_session, value}}`, never `NORMAL`.

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
  # taken from the request under their venue names. Only the offset is **required** here: a
  # trailing stop missing its offset is not a trailing stop, and the venue would reject it
  # after spending one of a small number of writes per minute. The OpenAPI document marks no
  # field of the three required, so the other two ride along when given and are not demanded.
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
         {:ok, session} <- fetch_session(request, opts),
         :ok <- check_finite(request),
         :ok <- check_prices(order_type, request) do
      {:ok,
       %{
         "orderType" => order_type,
         "session" => session,
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

  @doc """
  Wraps a payload `build/2` produced into the shape `/previewOrder` documents.

  **`preview_order/4`'s request body is not `place_order/4`'s.** `POST
  /accounts/{hash}/orders` takes `OrderRequest`, whose legs are `orderLegCollection` of
  `OrderLegCollection` — that is the shape `build/2` returns, and it is correct for
  placing. `POST /accounts/{hash}/previewOrder` takes `PreviewOrder` (AT:2037-2054,
  `docs/reference/schwab/openapi/accounts-and-trading-production.openapi.json`), which
  carries the order under `orderStrategy` (`OrderStrategy`, AT:1372-1471) — a different
  schema, whose legs are `orderLegs` of `OrderLeg` (AT:1471-1511), not `orderLegCollection`
  of `OrderLegCollection`. `OrderLeg` has no nested `instrument` object either: it carries
  `assetType` and `finalSymbol` as flat fields (AT:1503-1510), where `OrderLegCollection`
  nests both under `instrument` (AT:2241-2243). This used to send the `OrderRequest` body
  verbatim to `/previewOrder`, which is not the schema that endpoint documents.

  `build/2`'s output is unchanged; this transforms it rather than building a second payload
  by hand, so a preview describes the exact same order `place_order/4` would send.
  """
  @spec to_preview(map()) :: map()
  def to_preview(order_request) when is_map(order_request) do
    legs = order_request |> Map.get("orderLegCollection", []) |> Enum.map(&preview_leg/1)

    strategy =
      order_request
      |> Map.delete("orderLegCollection")
      |> Map.put("orderLegs", legs)

    %{"orderStrategy" => strategy}
  end

  defp preview_leg(%{"instrument" => instrument} = leg) do
    leg
    |> Map.delete("instrument")
    |> Map.put("assetType", instrument["assetType"])
    |> Map.put("finalSymbol", instrument["symbol"])
  end

  defp preview_leg(leg), do: leg

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
      %Decimal{} = quantity -> decimal_quantity(quantity)
      quantity when is_number(quantity) -> positive(quantity)
      other -> {:error, {:invalid_quantity, other}}
    end
  end

  # `Decimal.to_float/1` raises on NaN, Infinity and anything past the float range, in the
  # caller's process. A quantity the venue could never read is `:invalid_quantity`, like any
  # other, and refused before a throttled write is spent on it.
  defp decimal_quantity(quantity) do
    if Decimal.nan?(quantity) or Decimal.inf?(quantity),
      do: {:error, {:invalid_quantity, quantity}},
      else: positive(Decimal.to_float(quantity))
  rescue
    _out_of_range in [ArgumentError, ArithmeticError] ->
      {:error, {:invalid_quantity, quantity}}
  end

  # A NaN or Infinity price went out as the string `"NaN"` / `"Infinity"`. Every field the
  # generic `maybe_put/3` stringifies is checked here, so a non-finite value is refused by
  # name instead of being sent to the venue as a price.
  defp check_finite(request) do
    Enum.reduce_while([:price, :stop_price, :stop_price_offset], :ok, fn key, :ok ->
      case Map.get(request, key) do
        %Decimal{} = value ->
          if Decimal.nan?(value) or Decimal.inf?(value),
            do: {:halt, {:error, {:invalid_order_field, key, value}}},
            else: {:cont, :ok}

        _other ->
          {:cont, :ok}
      end
    end)
  end

  # **`session` is the venue's enum, not whatever the caller typed.** The venue accepts
  # `NORMAL`, `AM`, `PM` and `SEAMLESS` (`session` schema, AT:1130-1138). The value was sent
  # through unchecked, and `Jason` encodes an atom as its lower-case name, so a caller who read
  # `capabilities().supported_sessions` and passed `session: :pre_market` sent `"pre_market"`:
  # a rejection that cost one of the throttled order writes.
  #
  # Core's four session atoms map to the venue's four values. `:extended` is `SEAMLESS`, the
  # only session that includes the extended hours; it also includes the regular one. Anything
  # else is refused, never defaulted to `NORMAL`.
  @core_sessions %{
    regular: "NORMAL",
    pre_market: "AM",
    post_market: "PM",
    extended: "SEAMLESS"
  }
  @sessions ~w(NORMAL AM PM SEAMLESS)

  defp fetch_session(request, opts) do
    case Map.get(request, :session) || Keyword.get(opts, :session) do
      nil -> {:ok, "NORMAL"}
      session -> native_session(session)
    end
  end

  defp native_session(session) when is_atom(session) do
    case Map.fetch(@core_sessions, session) do
      {:ok, native} -> {:ok, native}
      :error -> native_session(Atom.to_string(session), session)
    end
  end

  defp native_session(session) when is_binary(session), do: native_session(session, session)
  defp native_session(session), do: {:error, {:unsupported_session, session}}

  defp native_session(text, original) do
    upcased = text |> String.trim() |> String.upcase()

    if upcased in @sessions,
      do: {:ok, upcased},
      else: {:error, {:unsupported_session, original}}
  end

  defp positive(quantity) when quantity > 0, do: {:ok, quantity}
  defp positive(quantity), do: {:error, {:invalid_quantity, quantity}}

  # **No `:order_type` is a market order only when nothing says otherwise.** A request with
  # no type and a `:price` went out as a MARKET order, the price ignored: a forgotten field
  # became an order at any price. A price or a stop price says the caller meant something
  # else, and which is not this package's to guess, so that is refused. A bare request still
  # defaults to market, the venue's own documented example.
  defp fetch_order_type(request) do
    case Map.get(request, :order_type) do
      nil ->
        if Map.get(request, :price) || Map.get(request, :stop_price),
          do: {:error, {:missing_order_field, :order_type}},
          else: {:ok, Map.fetch!(@order_types, :market)}

      type ->
        case Map.fetch(@order_types, type) do
          {:ok, native} -> {:ok, native}
          :error -> {:error, {:unsupported_order_type, type}}
        end
    end
  end

  defp fetch_duration(request) do
    # Found 2026-10-10 by reading the path: `Map.get/3` substitutes its default only for an
    # ABSENT key, so `time_in_force: nil` (a forwarded unset option) was refused as an
    # unsupported duration. nil is absent here, as on Robinhood; any other value is still
    # checked, never defaulted.
    tif = Map.get(request, :time_in_force) || :day

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

    with :ok <- instruction_agrees(instruction, Map.get(request, :side)),
         do: validate_instruction(instruction, native)
  end

  # An explicit instruction that contradicts `:side` is refused: `side: :sell,
  # instruction: "BUY"` sent BUY, and which of the two the caller meant is not this
  # package's to choose.
  defp instruction_agrees(instruction, side)
       when is_binary(instruction) and side in [:buy, :sell] do
    direction = if String.starts_with?(instruction, "BUY"), do: :buy, else: :sell

    if direction == side,
      do: :ok,
      else: {:error, {:conflicting_order_fields, instruction: instruction, side: side}}
  end

  defp instruction_agrees(_instruction, _side), do: :ok

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

  defp asset_type(native), do: if(SymbolFormat.option?(native), do: "OPTION", else: "EQUITY")

  defp maybe_put(payload, _key, nil), do: payload

  # **`stopPriceOffset` is documented as a JSON number** — `OrderRequest.stopPriceOffset`
  # is `"type": "number", "format": "double"` (AT:1935-1938,
  # `docs/reference/schwab/openapi/accounts-and-trading-production.openapi.json`), and the
  # prose example agrees: `"stopPriceOffset": 10` with no quotes
  # (`accounts-and-trading-production.txt:378`). This used to fall through to the generic
  # clause below and go out as a quoted string via `to_string/1`, on every input type —
  # matching neither the schema nor the example.
  #
  # `price` and `stopPrice` are NOT changed here even though the same schema types them as
  # numbers too (AT:1795, AT:1925): the vendor's own prose examples send them BOTH ways —
  # `"stopPrice": "37.03"` quoted (`accounts-and-trading-production.txt:292`) and
  # `"stopPrice": 11.27` bare (`accounts-and-trading-production.txt:353`) — a contradiction
  # inside the vendor's own document that this package cannot resolve by reading it more
  # carefully. Left as a string, which is what every order this package has ever placed
  # sent and what the venue has accepted; recorded here rather than silently changed
  # alongside a field the documentation does not actually disagree about.
  #
  # `Jason.Fragment` carries the Decimal's own exact digits through unquoted — the same
  # `Decimal.to_string(value, :normal)` this module already uses to avoid scientific
  # notation on `price`/`stopPrice`, wrapped so Jason emits it as a bare number rather than
  # a quoted one. `Decimal.to_float/1` is never called: that rounds, and a Decimal read
  # from a caller's own money math is not this package's to round on the way out.
  defp maybe_put(payload, "stopPriceOffset", %Decimal{} = value) do
    Map.put(payload, "stopPriceOffset", Jason.Fragment.new(Decimal.to_string(value, :normal)))
  end

  defp maybe_put(payload, "stopPriceOffset", value) when is_number(value) do
    Map.put(payload, "stopPriceOffset", Jason.Fragment.new(to_string(value)))
  end

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

  # **`to_string/1` on a float is scientific below 1.0e-4.** `to_string(0.0001)` is
  # `"1.0e-4"`, the same unreadable-price failure the Decimal clause above closes, reached
  # through a float price instead. `Decimal.from_float/1` keeps the shortest round-trip digits
  # and `:normal` writes them out in full.
  defp maybe_put(payload, key, value) when is_float(value),
    do: Map.put(payload, key, value |> Decimal.from_float() |> Decimal.to_string(:normal))

  defp maybe_put(payload, key, value), do: Map.put(payload, key, to_string(value))

  # --- reading an order back --------------------------------------------------

  # `Core.Types.Order.order_type/0` is `:market | :limit | :stop | :stop_limit |
  # :post_only | :ioc | :fok` — this venue never builds the last three, and of the four it
  # does build, only these four have a Core atom. `build/2`'s own `@order_types` above can
  # also send `TRAILING_STOP`, `TRAILING_STOP_LIMIT`, `MARKET_ON_CLOSE` and
  # `LIMIT_ON_CLOSE`, none of which Core names (see that map's own comment), so reading
  # one of those back has nowhere honest to land but `nil`.
  #
  # Built FROM `@order_types` rather than a second hand-typed table, restricted to the
  # types Core actually has an atom for — so an order type added to `@order_types` cannot
  # silently drift from what comes back here the way two independently maintained tables
  # could. `@durations_in` below does the same inversion for the same reason.
  @core_order_types ~w(market limit stop stop_limit)a

  @order_types_in @order_types
                  |> Map.filter(fn {atom, _wire} -> atom in @core_order_types end)
                  |> Map.new(fn {atom, wire} -> {wire, atom} end)

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
    with {:ok, legs} <- legs(order["orderLegCollection"]) do
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
  end

  def from_venue(%{} = _order), do: {:error, {:missing_required_field, :id}}
  def from_venue(_other), do: {:error, :unexpected_response_shape}

  # **Every leg, or a refusal.** Legs that were not objects used to be filtered out, and the
  # count of legs is what decides whether this is a single-leg order or a spread. A two-leg
  # spread with one unreadable leg therefore came back as a SINGLE-leg order carrying the
  # other leg's symbol and side: a caller reconciling it saw an outright position where it
  # holds half of a spread. A collection that was not a list was wrapped into one leg the
  # same way. An absent collection is still no legs.
  defp legs(nil), do: {:ok, []}

  defp legs(legs) when is_list(legs) do
    if Enum.all?(legs, &is_map/1), do: {:ok, legs}, else: {:error, :unexpected_response_shape}
  end

  defp legs(_unreadable), do: {:error, :unexpected_response_shape}

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

  # **Compared before it is expanded.** `Decimal.to_integer/1` builds the whole integer, so a
  # venue quantity of `"1E999999999"`, which `Decimal.integer?/1` accepts, meant computing a
  # number with a billion digits. `1E10000000` already took longer than 4 seconds (measured
  # 2026-09-27), and it ran inside `list_from_venue/1` in the caller's process.
  # `Decimal.compare/2` works on coefficient and exponent and returns at once.
  # `@max_leg_quantity` is chosen, not measured: a trillion contracts is more than any
  # order leg, and a leg past it gets the same `nil` as a fractional one.
  @max_leg_quantity Decimal.new("1E12")

  defp whole(%Decimal{} = value) do
    if Decimal.compare(Decimal.abs(value), @max_leg_quantity) != :gt and Decimal.integer?(value),
      do: Decimal.to_integer(value),
      else: nil
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
