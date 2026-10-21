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
  - a key this builder does not read: `{:unsupported_order_field, key}` - **whatever its
    value, `nil` included**
  - a nil, non-text or blank symbol: `{:invalid_symbol, value}`
  - a side that is not `:buy`/`:sell` (or `"buy"`/`"sell"`, any case):
    `{:invalid_side, value}`; no side and no instruction: `{:missing_field, :side}`
  - no order type or time-in-force: `{:missing_field, :order_type}` /
    `{:missing_field, :time_in_force}`. Neither is defaulted, and a missing order type is never
    read as a market order: a forgotten field must not become an order at any price
  - an order type or time-in-force outside what this venue serves
  - a quantity that is missing (`{:missing_field, :quantity}`), or is not a positive, finite
    Decimal, integer or numeric string (`{:invalid_quantity, value}`). **Floats are refused**:
    a float has already lost digits. An integer above 2^53 is refused too: the venue's
    `quantity` is a double, which cannot hold it exactly. A quantity below 0.01 or above
    1.0e14 is written out in plain digits (`Jason.Fragment`), never `1.0e-5`
  - a field the order type never reads, `{:unexpected_field, key}` (a `:price` on a market,
    stop or trailing-stop order, a `:stop_price` on a market, limit or trailing order, an
    offset, link basis or link type on a non-trailing order). A market order carrying a
    price is ambiguous - the caller may believe they placed a limit - so it is refused
  - a limit order carries no price, or a stop order no stop price —
    `{:missing_field, key}`; the venue would reject it, and a locally-refused order has not
    spent a throttled write
  - a price or stop price that is not a positive, finite Decimal, integer or numeric
    string (floats refused): `{:invalid_price, value}` / `{:invalid_stop_price, value}`
  - an EQUITY `price` or `stop_price` off the price increment: `{:price_not_on_tick, key,
    value, increment}`, with `increment` the text `"0.01"` (price at or above 1) or `"0.0001"`
    (below 1). **Refused, never rounded**: rounding a limit price moves the caller's money.
    This is the SEC's sub-penny rule (Rule 612 of Regulation NMS, 17 CFR 242.612), not
    something read from Schwab's two OpenAPI documents (they publish no tick or lot rule,
    `capabilities.ex`'s note on `quantization/1`) and not probed: no credential is held. It
    applies to equities only; an option's increment is not stated anywhere this package
    reads, so an option price is not judged
  - a `stop_price_offset` that is not a positive, finite number:
    `{:invalid_order_field, :stop_price_offset, value}`
  - the instruction does not match the asset type, per the venue's published matrix
    (`{:instruction_not_valid_for_asset, instruction, asset}`), or is not a string
    (`{:invalid_instruction, value}`, naming the value given)
  - `:instrument_type` names an asset this builder cannot send

  **`:instrument_type` sets the leg's `assetType`, and only EQUITY and OPTION are orderable.**
  Nothing in a ticker tells a mutual fund from a share (`SWPPX` and `AAPL` are spelled alike),
  so sending every non-option order as `EQUITY` made a fund order a share order. The vendor
  states that order entry is available only for `EQUITY` and `OPTION`
  (`accounts-and-trading-production.txt:128`), so `:mutual_fund` and `:cash_equivalent` are
  `{:error, {:unsupported_instrument_type, value}}` (they were sent as `MUTUAL_FUND` and
  `CASH_EQUIVALENT` before). `:equity`/`:spot` (or none) sends `EQUITY`, and an option symbol
  is `OPTION` whatever is said. Anything else is refused too, never a guessed `EQUITY`.
  """
  @spec build(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def build(request, opts \\ [])

  # A keyword list or any other non-map used to raise `BadMapError` from `Map.get/2` in the
  # caller's process, after a throttled-write gate had been passed.
  #
  # **A struct is not a request map either.** `is_map/1` is true for one, and `check_keys/1`
  # then enumerates it: structs implement no `Enumerable`, so `build(%URI{})` raised
  # `Protocol.UndefinedError` in the caller's process, and `request[:price]` would have raised
  # in `Access`. Its fields are not this builder's vocabulary, so it is refused by name.
  def build(request, _opts) when not is_map(request) or is_struct(request),
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
         :ok <- check_ticks(asset, request),
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
  Builds the order a `replace_order/4` sends: `build/2`, except that an EMPTY map is refused first.

  Schwab replaces an order by `PUT`ting a whole new one, so the change map is built as a whole
  order. A replace that changes nothing is not a replace (`Core.Venue.replace_order/4`), and
  `%{}` used to fall through to `build/2`'s symbol check, answering `{:invalid_symbol, nil}`.
  A non-map, a struct or an empty map is `{:error, {:invalid_order_request, value}}`; anything
  else is judged by `build/2`.
  """
  @spec build_replacement(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def build_replacement(request, opts \\ []) do
    if request == %{},
      do: {:error, {:invalid_order_request, request}},
      else: build(request, opts)
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
  # them: Schwab has no idempotency key to carry it). **An unknown key is refused whatever
  # its value, `nil` included** (tick R, DV1; BREAKING): a `client_order_id: nil` is still a
  # caller reaching for a field this venue cannot honour, and the family refuses it the same
  # way on every venue. A nil on a key this builder DOES read still counts as absent, as it
  # does for every field below. The first offender in key order is named, so the answer does
  # not depend on map iteration.
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
    |> Enum.reject(fn {key, _value} -> key in @request_keys end)
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
      float_quantity(quantity, original)
    end
  rescue
    # `Decimal.Error` is what the pinned Decimal raises for a finite value past the float range
    # (`number bigger than DBL_MAX`, `number smaller than DBL_MIN`). It was not in this list, so
    # `1E400` raised out of `build/2` in the caller's process instead of being refused by name.
    # The other two are what an older Decimal raised for the same input.
    _out_of_range in [ArgumentError, ArithmeticError, Decimal.Error] ->
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
  #
  # **An offset is a distance, so it is positive.** Zero or a negative offset was accepted and
  # sent: a trailing stop that trails by nothing (or by a negative amount) is not the order the
  # caller means, and the venue would reject it after spending a throttled write.
  defp check_offset(request) do
    value = Map.get(request, :stop_price_offset)

    if is_nil(value) or positive_value?(value),
      do: :ok,
      else: {:error, {:invalid_order_field, :stop_price_offset, value}}
  end

  # **At most 34 significant digits and an exponent within +-1000.** The same bound the rest
  # of the family puts on a venue number (Decimal's own default context is 28 digits; 34 is
  # decimal128). Chosen, not measured: no price, size or balance has more. Without it `1`
  # followed by a million digits is "finite" and the first compare allocates it.
  @max_coefficient Integer.pow(10, 34)

  defp finite_number?(value) when is_integer(value), do: abs(value) < @max_coefficient

  defp finite_number?(%Decimal{exp: exp} = value),
    do:
      not (Decimal.nan?(value) or Decimal.inf?(value)) and abs(exp) <= 1000 and
        value.coef < @max_coefficient

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

  # **The venue's `quantity` is a double, so only a quantity a double holds exactly is sent.**
  # `Decimal.to_float/1` rounds, in either direction, a Decimal with more digits than a double
  # carries (`1.00000000000000001` went out as `1.0`, `0.30000000000000004999` as another
  # number): an order for a size the caller did not ask for. The float must read back as the
  # very Decimal that was given, or the quantity is refused by name.
  defp float_quantity(quantity, original) do
    float = Decimal.to_float(quantity)

    if float > 0 and Decimal.eq?(Decimal.from_float(float), quantity),
      do: {:ok, plain_quantity(float, quantity)},
      else: {:error, {:invalid_quantity, original}}
  end

  # **A JSON number, never scientific notation.** `Jason` writes a float through the shortest
  # round-trip form, which is `1.0e-5` below about a thousandth and `1.0e15` from a quadrillion;
  # the venue documents a plain number. Inside `[0.01, 1.0e14)` the float is written plain, so
  # it is sent as the float it always was. Outside it the quantity is written out digit for digit
  # from the exact Decimal (`Decimal.to_string(_, :normal)`) and carried unquoted in a
  # `Jason.Fragment`, the way `stopPriceOffset` is. The bounds are chosen well inside the
  # float formatter's switch points, not measured at them.
  defp plain_quantity(float, _quantity) when float >= 0.01 and float < 1.0e14, do: float

  defp plain_quantity(_float, quantity),
    do: Jason.Fragment.new(Decimal.to_string(quantity, :normal))

  # An integer the venue's double cannot hold exactly (above 2^53) is a different size once sent,
  # exactly as a Decimal with more digits than a double is refused above.
  @max_exact_quantity 9_007_199_254_740_992

  defp positive(quantity) when quantity > 0 and quantity <= @max_exact_quantity,
    do: {:ok, quantity}

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
  # absent (a forwarded unset option); any other value is checked. A duration this venue does
  # not serve (`:gtd`, `:gfw`, a string, ...) is the family's
  # `{:unsupported_order_combination, type, tif}` -- `type` is the order type already accepted
  # by `fetch_order_type/1`, so the request's own atom.
  defp fetch_duration(request) do
    case Map.get(request, :time_in_force) do
      nil ->
        {:error, {:missing_field, :time_in_force}}

      tif ->
        case Map.fetch(@durations, tif) do
          {:ok, native} ->
            {:ok, native}

          :error ->
            {:error, {:unsupported_order_combination, Map.get(request, :order_type), tif}}
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

  defp positive_value?(value) when is_integer(value), do: value > 0 and finite_number?(value)

  defp positive_value?(value) when is_binary(value) do
    case value |> String.trim() |> Decimal.parse() do
      {%Decimal{} = parsed, ""} -> positive_value?(parsed)
      _unreadable -> false
    end
  end

  defp positive_value?(%Decimal{} = value),
    do: finite_number?(value) and Decimal.gt?(value, 0)

  defp positive_value?(_other), do: false

  # **An equity price must sit on the price increment, or the order is refused** (never rounded:
  # a limit price moved to the nearest cent is a different order). See `build/2`'s
  # "price_not_on_tick" for what the rule is and what it is not: the SEC's sub-penny rule, not a
  # Schwab publication, and not probed. `price` and `stop_price` were already judged positive
  # and finite by `check_prices/2`, so each is a number here. An option leg is not judged.
  defp check_ticks("EQUITY", request) do
    Enum.reduce_while([:price, :stop_price], :ok, fn key, :ok ->
      case check_tick(key, Map.get(request, key)) do
        :ok -> {:cont, :ok}
        {:error, _off_tick} = refused -> {:halt, refused}
      end
    end)
  end

  defp check_ticks(_asset, _request), do: :ok

  defp check_tick(_key, nil), do: :ok

  defp check_tick(key, value) do
    price = price_decimal(value)
    {places, increment} = if Decimal.lt?(price, 1), do: {4, "0.0001"}, else: {2, "0.01"}

    if Decimal.eq?(Decimal.round(price, places, :down), price),
      do: :ok,
      else: {:error, {:price_not_on_tick, key, value, increment}}
  end

  # Only ever called on a value `positive_value?/1` accepted: an integer, a Decimal, or text
  # that reads as a number in full.
  defp price_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp price_decimal(%Decimal{} = value), do: value

  defp price_decimal(value) when is_binary(value) do
    {parsed, ""} = value |> String.trim() |> Decimal.parse()
    parsed
  end

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
  # **Order entry is EQUITY and OPTION only**: "Order entry will only be available for the
  # assetType 'EQUIT' and 'OPTION' as of this time" (`accounts-and-trading-production.txt:128`,
  # the document's own typo). `:mutual_fund` and `:cash_equivalent` used to be sent as
  # `MUTUAL_FUND` and `CASH_EQUIVALENT`, asset types the vendor says it does not accept; they
  # are refused like any other type this builder cannot send.
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
  one. `PENDING_CANCEL`, `PENDING_REPLACE` and `PENDING_RECALL` are read the same way (an
  order being cancelled with shares already executed is `:partially_filled`, not `:open`).
  All 21 `apiOrderStatus` values are handled; `REPLACED` and `UNKNOWN` (and any value outside
  the enum) are `nil`.

  `average_price` is the quantity-weighted mean of the `executionLegs` prices in the order's
  `EXECUTION` activities (`orderActivityCollection`), for a single-leg order only. It is `nil`
  when there are no executions, when any one is unreadable or not positive (never a partial
  average), and for a spread. A single-leg order carries that leg's symbol and side; a spread carries neither at
  the top and reports its legs, each with a `ratio` taken as the leg quantities over their
  greatest common divisor — the definition of a spread ratio, not an estimate of one.

  An order with no `orderId` is `{:error, {:missing_required_field, :id}}`: one a caller
  cannot cancel, replace or look up again is not an order it can use.
  """
  @spec from_venue(term()) :: {:ok, Order.t()} | {:error, term()}
  def from_venue(%{"orderId" => id} = order)
      when is_integer(id) or (is_binary(id) and id != "") do
    with {:ok, legs} <- legs(order["orderLegCollection"]),
         {:ok, quantity} <- size(order["quantity"]),
         {:ok, filled} <- size(order["filledQuantity"]),
         status = status(order["status"], filled),
         :ok <- consistent(status, quantity, filled) do
      {symbol, side, spread_legs} = leg_fields(legs)

      {:ok,
       %Order{
         id: to_string(id),
         symbol: symbol,
         side: side,
         order_type: @order_types_in[order["orderType"]],
         time_in_force: @durations_in[order["duration"]],
         quantity: quantity,
         price: number(order["price"]),
         stop_price: number(order["stopPrice"]),
         filled_quantity: filled,
         average_price: average_price(order, length(legs)),
         status: status,
         legs: spread_legs,
         created_at: timestamp(order["enteredTime"]),
         provider: :schwab
       }}
    end
  end

  # A struct is a map to a pattern: a JSON number such as `42.5` is decoded to a `%Decimal{}`
  # (`floats: :decimals`), and "an order with no id" would be a wrong name for it.
  def from_venue(order) when is_map(order) and not is_struct(order),
    do: {:error, {:missing_required_field, :id}}

  def from_venue(_other), do: {:error, :unexpected_response_shape}

  # **A status that contradicts the sizes beside it is refused, not carried.** The venue's word
  # for the state and its own `filledQuantity`/`quantity` cannot both be true of one order, and
  # which of them is right is not this package's to choose: `:filled` or `:partially_filled`
  # with nothing filled; `:pending`, `:open` or `:partially_filled` with the whole size filled;
  # `:filled` with only part of it. (`Core.Types.Order.new/1` refuses the same combinations.)
  # Only sizes the venue stated are judged: an absent one contradicts nothing.
  defp consistent(status, quantity, filled) do
    if contradictory?(status, quantity, filled),
      do: {:error, :unexpected_response_shape},
      else: :ok
  end

  defp contradictory?(status, quantity, %Decimal{} = filled) do
    nothing? = Decimal.eq?(filled, 0)

    {all?, part?} =
      case quantity do
        %Decimal{} -> {Decimal.eq?(filled, quantity), Decimal.lt?(filled, quantity)}
        nil -> {false, false}
      end

    (status in [:filled, :partially_filled] and nothing?) or
      (status in [:pending, :open, :partially_filled] and all? and not nothing?) or
      (status == :filled and part?)
  end

  defp contradictory?(_status, _quantity, nil), do: false

  # An order's size and its filled size are never negative (`Core.Types.Order.new/1` raises on
  # one: a negative is a decode bug, and a consumer summing fills against it concludes the order
  # is over-filled). A venue reply carrying one is refused whole, not clamped and not carried.
  # Absent or unreadable is `nil`, "not stated", as for every other number here.
  defp size(raw) do
    case number(raw) do
      %Decimal{} = value ->
        if Decimal.negative?(value), do: {:error, :unexpected_response_shape}, else: {:ok, value}

      nil ->
        {:ok, nil}
    end
  end

  # **Every leg, or a refusal.** Legs that were not objects used to be filtered out, and the
  # count of legs is what decides whether this is a single-leg order or a spread. A two-leg
  # spread with one unreadable leg therefore came back as a SINGLE-leg order carrying the
  # other leg's symbol and side: a caller reconciling it saw an outright position where it
  # holds half of a spread. A collection that was not a list was wrapped into one leg the
  # same way. An absent collection is still no legs.
  defp legs(nil), do: {:ok, []}

  defp legs(legs) when is_list(legs) do
    if Enum.all?(legs, &(is_map(&1) and not is_struct(&1))),
      do: {:ok, legs},
      else: {:error, :unexpected_response_shape}
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

  # **Every one of `apiOrderStatus`'s 21 values is handled, none is defaulted.** Nineteen map
  # to a Core status; `REPLACED` (the order was superseded: its successor is a different order,
  # and "replaced" is not "cancelled") and `UNKNOWN` (the venue's own "I do not know") have no
  # Core word and are `nil`, as is any value the enum does not list. A status this package does
  # not recognise is never read as `:open` or `:pending`.
  #
  # **A live order with fills is partially filled, whichever live status it carries.** Only
  # `WORKING` used to say so: an order the venue had begun cancelling or replacing
  # (`PENDING_CANCEL`, `PENDING_REPLACE`, `PENDING_RECALL`) with shares already executed was
  # read as `:open`, with the fills visible only to a caller that also read `filled_quantity`.
  defp status("WORKING", filled), do: live_status(filled)
  defp status("FILLED", _filled), do: :filled
  defp status("CANCELED", _filled), do: :cancelled
  defp status("REJECTED", _filled), do: :rejected
  defp status("EXPIRED", _filled), do: :expired
  defp status(pending, _filled) when pending in @pending, do: :pending
  defp status(live, filled) when live in @still_live, do: live_status(filled)
  defp status(_replaced_or_unknown, _filled), do: nil

  defp live_status(%Decimal{} = filled) do
    if Decimal.gt?(filled, 0), do: :partially_filled, else: :open
  end

  defp live_status(_not_stated), do: :open

  # **The average fill price, from the executions the venue itself reports.** A single-leg
  # order's `orderActivityCollection` lists its `EXECUTION` activities, each with
  # `executionLegs` carrying the `price` and `quantity` of one fill. The average is the
  # quantity-weighted mean of those prices, which is what an average price is; it is `nil`
  # (never a partial average) when there are no fills, when any fill is unreadable or not
  # positive, and for a spread, whose legs are different instruments with no common price.
  # Read from the document's `OrderActivity`/`ExecutionLeg` schemas, not probed: no credential
  # is held.
  defp average_price(order, leg_count) when leg_count <= 1 do
    case order["orderActivityCollection"] do
      activities when is_list(activities) ->
        activities |> Enum.flat_map(&execution_legs/1) |> weighted_average()

      _absent ->
        nil
    end
  end

  defp average_price(_order, _spread), do: nil

  defp execution_legs(%{"activityType" => "EXECUTION", "executionLegs" => legs})
       when is_list(legs),
       do: legs

  defp execution_legs(_other_activity), do: []

  defp weighted_average([]), do: nil

  defp weighted_average(legs) do
    fills = Enum.map(legs, &fill/1)

    if Enum.all?(fills, &match?({%Decimal{}, %Decimal{}}, &1)) do
      quantity =
        Enum.reduce(fills, Decimal.new(0), fn {_price, qty}, acc -> Decimal.add(acc, qty) end)

      value =
        Enum.reduce(fills, Decimal.new(0), fn {price, qty}, acc ->
          Decimal.add(acc, Decimal.mult(price, qty))
        end)

      Decimal.div(value, quantity)
    end
  end

  defp fill(%{"price" => price, "quantity" => quantity}) do
    with %Decimal{} = price <- number(price),
         %Decimal{} = quantity <- number(quantity),
         true <- Decimal.gt?(price, 0) and Decimal.gt?(quantity, 0) do
      {price, quantity}
    else
      _unreadable -> nil
    end
  end

  defp fill(_unreadable), do: nil

  # An integer or a float is judged exactly as a Decimal is (34 digits, exponent within +-1000):
  # an integer is a "finite number" with no limit on its length otherwise.
  defp number(value) when is_integer(value), do: value |> Decimal.new() |> number()
  defp number(value) when is_float(value), do: value |> Decimal.from_float() |> number()

  # The quantity `build/2` wrote out in plain digits (see `plain_quantity/2`): read back through
  # its own JSON text, so `accepted/2` reports the size that was sent.
  defp number(%Jason.Fragment{} = fragment), do: fragment |> Jason.encode!() |> number()

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

  # Schwab writes `enteredTime` as `2024-03-29T14:05:31+0000` — an offset with no colon.
  # Elixir's `DateTime.from_iso8601/1` reads that form itself (`parse_offset/1` in Elixir 1.18's
  # `Calendar.ISO`, which this package requires), so there is no second, colon-inserting parser:
  # one existed and never ran, because anything it could read this already had. A time neither
  # reads is `nil`, not a guess.
  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _unreadable -> nil
    end
  end

  defp timestamp(_absent), do: nil
end
