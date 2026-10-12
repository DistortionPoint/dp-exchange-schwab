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

  # Core's vocabulary => Schwab's. The eight Core can name; the venue's CABINET,
  # NON_MARKETABLE, EXERCISE and NET_* order types have no Core atom and are refused.
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

  The request is `Core`'s vocabulary: `:symbol`, `:side`, `:quantity`, `:order_type` and
  `:time_in_force` (all four required), and optionally `:price`, `:stop_price`, `:session`.
  The venue's own `:instruction` (required for an option, which has no plain buy or sell),
  and a trailing stop's `:stop_price_offset`, `:stop_price_link_basis` and
  `:stop_price_link_type`, ride along under their venue names. `opts[:session]` is read when
  the request names none. **Any other key is refused**, `client_order_id` included: Schwab
  publishes no idempotency key, so there is nothing to send it as and silently ignoring it
  would let a caller believe a retry was safe.

  Refuses, by name and before any request, in this order:

  - a request that is not a map: `{:invalid_order_request, request}`
  - a key this builder does not read: `{:unsupported_order_field, key}`
  - a nil, non-text or blank symbol: `{:invalid_symbol, value}`
  - a side that is not `:buy`/`:sell` (or `"buy"`/`"sell"`, any case):
    `{:invalid_side, value}`; no side and no instruction: `{:missing_field, :side}`
  - no order type or time-in-force: `{:missing_field, :order_type}` /
    `{:missing_field, :time_in_force}`. Neither is defaulted, and a missing order type is never
    read as a market order: a forgotten field must not become an order at any price
  - an order type or time-in-force outside what this venue serves
  - a quantity that is missing (`{:missing_field, :quantity}`), or is not a positive, finite
    Decimal, integer or numeric string (`{:invalid_quantity, value}`). **Floats are refused**:
    a float has already lost digits
  - a field the order type never reads, `{:unexpected_field, key}` (a `:price` on a market,
    stop or trailing-stop order, a `:stop_price` on a market, limit or trailing order, an
    offset, link basis or link type on a non-trailing order). A market order carrying a
    price is ambiguous - the caller may believe they placed a limit - so it is refused
  - a limit order carries no price, or a stop order no stop price —
    `{:missing_field, key}`; the venue would reject it, and a locally-refused order has not
    spent a throttled write
  - a price or stop price that is not a positive, finite Decimal, integer or numeric
    string (floats refused): `{:invalid_price, value}` / `{:invalid_stop_price, value}`
  - the instruction does not match the asset type, per the venue's published matrix
    (`{:instruction_not_valid_for_asset, instruction, asset}`), or is not a string
    (`{:invalid_instruction, value}`, naming the value given)
  - `:instrument_type` names an asset this builder cannot send

  **`:instrument_type` sets the leg's `assetType`.** Nothing in a ticker tells a mutual fund
  from a share (`SWPPX` and `AAPL` are spelled alike, and `capabilities/0` declares both),
  so every non-option order went out as `EQUITY` — a fund order sent as a share order.
  `:mutual_fund` sends `MUTUAL_FUND` and `:cash_equivalent` sends `CASH_EQUIVALENT`, the
  Trader API's own `assetType` values; `:equity`/`:spot` (or none) sends `EQUITY`, and an
  option symbol is `OPTION` whatever is said. Anything else is
  `{:error, {:unsupported_instrument_type, value}}` rather than a guessed `EQUITY`.
  """
  @spec build(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def build(request, opts \\ [])

  # A keyword list or any other non-map used to raise `BadMapError` from `Map.get/2` in the
  # caller's process, after a throttled-write gate had been passed.
  def build(request, _opts) when not is_map(request),
    do: {:error, {:invalid_order_request, request}}

  def build(request, opts) do
    with :ok <- check_keys(request),
         {:ok, native} <- SymbolFormat.validate_read(Map.get(request, :symbol)),
         {:ok, instruction} <- fetch_instruction(request, native),
         {:ok, order_type} <- fetch_order_type(request),
         {:ok, duration} <- fetch_duration(request),
         {:ok, quantity} <- fetch_quantity(request),
         :ok <- check_prices(order_type, request),
         {:ok, session} <- fetch_session(request, opts),
         {:ok, asset} <- fetch_asset_type(request, native),
         :ok <- check_links(request) do
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
               "assetType" => asset
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

  @doc """
  Whether `order_id` can name an order: a non-blank string with no surrounding whitespace.

  Anything else - `nil`, an integer, a blank or padded string - is
  `{:error, {:invalid_order_id, value}}`, decided before the account option and the
  credential. Schwab ids are numeric strings (`Location` ends in one, and `get_order/3`
  returns `Order.id` as one); an integer is not accepted, and a padded id would be a
  different path segment, so the venue would answer 404 for an order that exists.
  """
  @spec check_order_id(term()) :: :ok | {:error, {:invalid_order_id, term()}}
  def check_order_id(order_id) when is_binary(order_id) do
    if order_id != "" and String.trim(order_id) == order_id,
      do: :ok,
      else: {:error, {:invalid_order_id, order_id}}
  end

  def check_order_id(other), do: {:error, {:invalid_order_id, other}}

  @doc """
  The `Order` for a placement the venue accepted (it named `id`) when reading it back failed.

  Built from the payload `build/2` produced - the exact order that was sent, with the
  normalised symbol, side, type and time-in-force - and nothing else: `:pending`, no fills,
  no timestamp. `place_order/3` answers with it so a placed order is never reported as a
  failure; `replace_order/4` does not use it, because a replacement's read-back failure is
  `{:replace_accepted_unread, id, reason}`.
  """
  @spec accepted(String.t(), map()) :: {:ok, Order.t()} | {:error, term()}
  def accepted(id, %{"orderLegCollection" => [leg | _rest]} = payload) do
    payload
    |> Map.merge(%{"orderId" => id, "status" => "ACCEPTED", "quantity" => leg["quantity"]})
    |> from_venue()
  end

  defp preview_leg(%{"instrument" => instrument} = leg) do
    leg
    |> Map.delete("instrument")
    |> Map.put("assetType", instrument["assetType"])
    |> Map.put("finalSymbol", instrument["symbol"])
  end

  defp preview_leg(leg), do: leg

  # The keys this builder reads. Anything else is refused by name (`client_order_id` among
  # them: Schwab has no idempotency key to carry it). A key whose value is `nil` is a
  # forwarded unset option and counts as absent, as it does for every field below. The
  # first offender in key order is named, so the answer does not depend on map iteration.
  @request_keys [
    :symbol,
    :side,
    :quantity,
    :order_type,
    :time_in_force,
    :price,
    :stop_price,
    :session,
    :instruction,
    :instrument_type,
    :stop_price_offset,
    :stop_price_link_basis,
    :stop_price_link_type
  ]

  defp check_keys(request) do
    request
    |> Enum.reject(fn {key, value} -> is_nil(value) or key in @request_keys end)
    |> Enum.map(fn {key, _value} -> key end)
    |> Enum.sort()
    |> case do
      [] -> :ok
      [key | _rest] -> {:error, {:unsupported_order_field, key}}
    end
  end

  # Fractional is real here — `quantityType` admits DOLLARS and `quantity` is a double —
  # so a non-integer quantity is passed through rather than rounded. Rounding a
  # fractional order to whole shares would change the size silently. A float is not accepted
  # as input: it has already lost digits, and which decimal the caller meant is not this
  # package's to guess. A numeric string is read as the exact number it spells.
  defp fetch_quantity(request) do
    case Map.get(request, :quantity) do
      nil -> {:error, {:missing_field, :quantity}}
      %Decimal{} = quantity -> decimal_quantity(quantity, quantity)
      quantity when is_integer(quantity) -> positive(quantity)
      quantity when is_binary(quantity) -> string_quantity(quantity)
      other -> {:error, {:invalid_quantity, other}}
    end
  end

  defp string_quantity(text) do
    case text |> String.trim() |> Decimal.parse() do
      {%Decimal{} = parsed, ""} -> decimal_quantity(parsed, text)
      _unreadable -> {:error, {:invalid_quantity, text}}
    end
  end

  # `Decimal.to_float/1` raises on NaN, Infinity and anything past the float range, in the
  # caller's process. A quantity the venue could never read is `:invalid_quantity`, like any
  # other, and refused before a throttled write is spent on it.
  #
  # **The exponent is bounded before `to_float/1` expands it.** It builds `10 ** exp` as an
  # integer, so `1E999999999` meant a billion-digit number computed in the caller's process.
  # The same +-1000 limit `finite_number?/1` applies to a price; chosen, not measured.
  defp decimal_quantity(quantity, original) do
    if Decimal.nan?(quantity) or Decimal.inf?(quantity) or abs(quantity.exp) > 1000 do
      {:error, {:invalid_quantity, original}}
    else
      float = Decimal.to_float(quantity)
      if float > 0, do: {:ok, float}, else: {:error, {:invalid_quantity, original}}
    end
  rescue
    _out_of_range in [ArgumentError, ArithmeticError] ->
      {:error, {:invalid_quantity, original}}
  end

  # `price`, `stopPrice` and `stopPriceOffset` are checked here so a non-finite value is
  # refused by name instead of being sent to the venue as a price (`"NaN"` / `"Infinity"`).
  #
  # **And a value that is not a number at all.** `maybe_put/3` ends in `to_string/1`, so
  # `price: :market` went out as `"market"`, `price: "abc"` as `"abc"`, and `price: %{}`
  # raised `Protocol.UndefinedError` in the caller's process. The schema types all three as
  # `number`, so anything that is not an integer, a finite `Decimal` or a string that reads
  # as a finite number is refused by name. **A float is refused too**: it has already lost
  # digits, and `to_string/1` of one is scientific below 1.0e-4.
  defp check_offset(request) do
    value = Map.get(request, :stop_price_offset)

    if finite_number?(value) and not is_float(value),
      do: :ok,
      else: {:error, {:invalid_order_field, :stop_price_offset, value}}
  end

  defp finite_number?(nil), do: true
  defp finite_number?(value) when is_number(value), do: true

  defp finite_number?(%Decimal{exp: exp} = value),
    do: not (Decimal.nan?(value) or Decimal.inf?(value)) and abs(exp) <= 1000

  defp finite_number?(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {parsed, ""} -> finite_number?(parsed)
      _unreadable -> false
    end
  end

  defp finite_number?(_other), do: false

  # `stopPriceLinkBasis` and `stopPriceLinkType` are enums (`accounts-and-trading-production
  # .openapi.json`). Sent as given, so a lower-case or atom value reached the venue as
  # something that is not in the enum; refused by name instead, before a write is spent.
  @link_bases ~w(MANUAL BASE TRIGGER LAST BID ASK ASK_BID MARK AVERAGE)
  @link_types ~w(VALUE PERCENT TICK)

  defp check_links(request) do
    [stop_price_link_basis: @link_bases, stop_price_link_type: @link_types]
    |> Enum.find(fn {key, allowed} ->
      value = Map.get(request, key)
      not is_nil(value) and value not in allowed
    end)
    |> case do
      nil -> :ok
      {key, _allowed} -> {:error, {:invalid_order_field, key, Map.get(request, key)}}
    end
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

  # **The order type is required, never inferred.** A request with no type and no price used
  # to go out as a MARKET order (and one with a price was refused): a forgotten field became
  # an order at any price. Which type the caller meant is not this package's to guess, so an
  # absent type (or a forwarded `nil`) is `{:missing_field, :order_type}`.
  defp fetch_order_type(request) do
    case Map.get(request, :order_type) do
      nil ->
        {:error, {:missing_field, :order_type}}

      type ->
        case Map.fetch(@order_types, type) do
          {:ok, native} -> {:ok, native}
          :error -> {:error, {:unsupported_order_type, type}}
        end
    end
  end

  # **The duration is required, never defaulted to `DAY`.** A missing time-in-force silently
  # became a day order; a caller who forgot it may have meant good-till-cancelled. `nil` is
  # absent (a forwarded unset option); any other value is checked.
  defp fetch_duration(request) do
    case Map.get(request, :time_in_force) do
      nil ->
        {:error, {:missing_field, :time_in_force}}

      tif ->
        case Map.fetch(@durations, tif) do
          {:ok, native} -> {:ok, native}
          :error -> {:error, {:unsupported_time_in_force, tif}}
        end
    end
  end

  # `:side` is Core's word: `:buy`/`:sell`, or `"buy"`/`"sell"` in any case. It maps to the
  # plain equity instructions; the open/close forms are option vocabulary a caller supplies
  # explicitly as `:instruction`.
  defp fetch_instruction(request, native) do
    with {:ok, side} <- normalize_side(Map.get(request, :side)) do
      instruction =
        case {Map.get(request, :instruction), side} do
          {nil, :buy} -> "BUY"
          {nil, :sell} -> "SELL"
          {nil, nil} -> nil
          {explicit, _side} when is_binary(explicit) -> String.upcase(explicit)
          {other, _side} -> {:not_a_string, other}
        end

      with :ok <- instruction_agrees(instruction, side),
           do: validate_instruction(instruction, native)
    end
  end

  defp normalize_side(nil), do: {:ok, nil}
  defp normalize_side(side) when side in [:buy, :sell], do: {:ok, side}

  defp normalize_side(side) when is_binary(side) do
    case String.downcase(side) do
      "buy" -> {:ok, :buy}
      "sell" -> {:ok, :sell}
      _other -> {:error, {:invalid_side, side}}
    end
  end

  defp normalize_side(other), do: {:error, {:invalid_side, other}}

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

  defp validate_instruction(nil, _native), do: {:error, {:missing_field, :side}}

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

  # The offending value itself, never the side: `instruction: :buy` used to report
  # `{:invalid_instruction, :sell}` (the request's side), naming a value the caller did not
  # get wrong.
  defp validate_instruction({:not_a_string, other}, _native),
    do: {:error, {:invalid_instruction, other}}

  # A limit order without a price and a stop order without a stop price are both
  # rejected by the venue. Refusing here costs nothing; letting them through costs one
  # of a small number of writes per minute.
  defp check_prices(type, request) do
    with :ok <- require_fields(request, required_fields(type)),
         :ok <- refuse_meaningless(type, request),
         :ok <- positive_price(request, :price, :invalid_price),
         :ok <- positive_price(request, :stop_price, :invalid_stop_price),
         do: check_offset(request)
  end

  # A price or stop at or below zero cannot be a valid single-instrument order, and one that
  # is not a number, is NaN or Infinity, or is a float is refused by name (see
  # `check_offset/1`). Fields the order type never reads were refused before this runs, so
  # every price present here is one the type sends. The net types (NET_DEBIT, NET_CREDIT,
  # NET_ZERO), where zero and negative values are legitimate, are not buildable.
  defp positive_price(request, key, tag) do
    value = Map.get(request, key)

    if is_nil(value) or positive_value?(value),
      do: :ok,
      else: {:error, {tag, value}}
  end

  defp positive_value?(value) when is_integer(value), do: value > 0

  defp positive_value?(value) when is_binary(value) do
    case value |> String.trim() |> Decimal.parse() do
      {%Decimal{} = parsed, ""} -> positive_value?(parsed)
      _unreadable -> false
    end
  end

  defp positive_value?(%Decimal{} = value),
    do: finite_number?(value) and Decimal.gt?(value, 0)

  defp positive_value?(_other), do: false

  defp required_fields(type) when type in @trailing_types, do: [:stop_price_offset]
  defp required_fields("LIMIT_ON_CLOSE"), do: [:price]
  defp required_fields("LIMIT"), do: [:price]
  defp required_fields("STOP"), do: [:stop_price]
  defp required_fields("STOP_LIMIT"), do: [:stop_price, :price]
  defp required_fields(_market), do: []

  # **A field the order type never reads is refused, not sent.** `orderType: MARKET` with a
  # `price` went out as a market order: the caller, who may well believe they placed a limit,
  # got a fill at any price, and the venue does not object to the extra field. The same holds
  # for a `stopPrice` on a LIMIT, or a trailing offset on a STOP. Which of the two the caller
  # meant is not this package's to choose, so the request is refused by name.
  #
  # A trailing stop's trigger is derived from its offset, so it takes no `stop_price`;
  # `TRAILING_STOP_LIMIT` is the only trailing type that also reads a `price`. This is read
  # from the documented examples (a trailing stop carries only the offset triple), not probed.
  @trailing_keys [:stop_price_offset, :stop_price_link_basis, :stop_price_link_type]

  @meaningless %{
    "MARKET" => [:price, :stop_price] ++ @trailing_keys,
    "MARKET_ON_CLOSE" => [:price, :stop_price] ++ @trailing_keys,
    "LIMIT" => [:stop_price] ++ @trailing_keys,
    "LIMIT_ON_CLOSE" => [:stop_price] ++ @trailing_keys,
    "STOP" => [:price] ++ @trailing_keys,
    "STOP_LIMIT" => @trailing_keys,
    "TRAILING_STOP" => [:price, :stop_price],
    "TRAILING_STOP_LIMIT" => [:stop_price]
  }

  defp refuse_meaningless(type, request) do
    @meaningless
    |> Map.fetch!(type)
    |> Enum.find(&(Map.get(request, &1) != nil))
    |> case do
      nil -> :ok
      key -> {:error, {:unexpected_field, key}}
    end
  end

  # Checked in order, so a stop_limit missing both names the stop price first — the field
  # that makes it a stop at all.
  defp require_fields(request, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case Map.get(request, key) do
        nil -> {:halt, {:error, {:missing_field, key}}}
        _present -> {:cont, :ok}
      end
    end)
  end

  defp asset_type(native), do: if(SymbolFormat.option?(native), do: "OPTION", else: "EQUITY")

  # See `build/2`'s "`:instrument_type` sets the leg's `assetType`". An option symbol is an
  # option whatever the request says; a non-option symbol takes the caller's stated type.
  defp fetch_asset_type(request, native) do
    if SymbolFormat.option?(native),
      do: {:ok, "OPTION"},
      else: stated_asset_type(Map.get(request, :instrument_type))
  end

  defp stated_asset_type(type) when type in [nil, :equity, :spot], do: {:ok, "EQUITY"}
  defp stated_asset_type(:mutual_fund), do: {:ok, "MUTUAL_FUND"}
  defp stated_asset_type(:cash_equivalent), do: {:ok, "CASH_EQUIVALENT"}
  defp stated_asset_type(other), do: {:error, {:unsupported_instrument_type, other}}

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

  defp maybe_put(payload, "stopPriceOffset", value) when is_integer(value) do
    Map.put(payload, "stopPriceOffset", Jason.Fragment.new(Integer.to_string(value)))
  end

  # A string offset (`check_offset/1` accepts one that reads as a finite number) is a number
  # on the wire too, not the quoted text the generic clause below would send; it is read, then
  # written out in full as a Decimal is.
  defp maybe_put(payload, "stopPriceOffset", value) when is_binary(value) do
    {parsed, ""} = value |> String.trim() |> Decimal.parse()
    maybe_put(payload, "stopPriceOffset", parsed)
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

  # Text that `positive_price/3` accepted: sent as the number it reads as, with no surrounding
  # blanks and no exponent (`" 1.5 "` and `"1E+2"` went out verbatim).
  # Text that is not a number at all (an enum such as `stopPriceLinkBasis: "BID"`) goes out
  # as written; only numeric text is rewritten.
  defp maybe_put(payload, key, value) when is_binary(value) do
    case value |> String.trim() |> Decimal.parse() do
      {%Decimal{} = parsed, ""} -> maybe_put(payload, key, parsed)
      _not_a_number -> Map.put(payload, key, value)
    end
  end

  defp maybe_put(payload, key, value), do: Map.put(payload, key, to_string(value))

  # --- reading an order back --------------------------------------------------

  # `Core.Types.Order.order_type/0` names all eight order types `build/2` can send
  # (`:trailing_stop`, `:trailing_stop_limit`, `:market_on_close` and `:limit_on_close` joined
  # it in Core 0.3.74; before that they read back as `nil`). The venue's CABINET,
  # NON_MARKETABLE, EXERCISE and NET_* types have no Core atom and read back as `nil`.
  #
  # Built FROM `@order_types` rather than a second hand-typed table, so an order type added
  # to `@order_types` cannot silently drift from what comes back here. `@durations_in` below
  # does the same inversion for the same reason.
  @order_types_in Map.new(@order_types, fn {atom, wire} -> {wire, atom} end)

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

  # The venue's JSON numbers arrive as `Decimal`s (`floats: :decimals`, see `Rest`): finite
  # ones only, as for a string.
  defp number(%Decimal{} = value), do: if(finite_number?(value), do: value, else: nil)

  defp number(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {parsed, ""} -> if finite_number?(parsed), do: parsed, else: nil
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
