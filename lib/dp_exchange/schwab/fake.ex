defmodule DpExchange.Schwab.Fake do
  @moduledoc """
  An in-process stand-in for this venue, for consumers' tests.

  ## It refuses what the real venue refuses

  A fake that answers where the real one would refuse is worse than no fake: it lets a
  consumer's test suite go green against behaviour that cannot happen. So this one
  reproduces the refusals, not just the successes — a pair-shaped symbol, a missing
  credential, a year of one-minute candles, an instruction that does not match the asset
  type. Each is the same error the real package returns, from the same module.

  ## It closes the market on request

  `market_status/1` answers `:open` by default and `:closed` when told to, because a
  consumer testing an equities venue needs to exercise the overnight path — the one where
  a feed delivering nothing is correct. Every other venue in the family is always open,
  so this is the only place that path can be tested at all.

  Starts nothing. `start_link/1` returns `:ignore`, so a consumer that swaps this in does
  not find a process it did not ask for.

  ## Failure injection

  Wired to `DpExchange.Core.FakeInjection`, the same deterministic seam the other four
  venue packages in this family expose. This package was the only one with no wiring at
  all — a cross-package audit found it, and `usage-rules/testing.md` states the convention
  as "every venue's `Fake` is wired to `DpExchange.Core.FakeInjection`". A consumer
  exercising its own retry or alerting code against several venues could not point that
  code at Schwab.

  The market-data and account/order callbacks with a real success path check
  `FakeInjection.next_outcome/2` first, so a queued or always-set outcome from
  `queue_failures/2,3` or `fail_always/2,3` short-circuits the normal logic and is returned
  as-is. `require_credentials/1` honours `FakeInjection.bypass_credentials/1`, which matters
  more here than anywhere else in the family: this venue has **no anonymous surface at
  all**, so without a bypass there is no way to exercise dispatch or decode logic without
  constructing a credential map for every call.

  **Not everything is wired, and the gaps are deliberate.** `subscribe/2`,
  `unsubscribe/2` and `update_symbols/2` each take a list of symbols in one call, and
  "this one symbol in the batch fails, the rest succeed" is a case whole-call injection
  cannot express. `coverage/1`, `coverage_by_kind/1` and `subscribe_notices/1` are local
  bookkeeping that always succeeds by construction, not a call standing in for one the
  venue could refuse.

  The widened surface is wired too: `get_positions/1`, `get_option_chain/2`,
  `get_option_expirations/2` (targetable by the underlying), `get_screener/2`,
  `get_transactions/2` and `get_all_orders/2` all consult `FakeInjection` first.
  (`get_rate_limit_status/2` has no success path to inject into: it is `:unsupported` and
  answers `{:error, :not_supported}`.)

  ## Credentials are judged by the module that signs

  A credential is refused as the real package refuses it: not a map (market data), or no
  non-blank `:access_token` (`Auth.headers/2`, the one judgement both share). Market-data
  calls ask for a credential map first, then judge their own arguments, then sign; account
  calls judge their arguments and sign last. `%{refresh_token: "x"}` and
  `%{access_token: ""}` are refused here as they are there.

  ## What is deliberately not provided

  The facade's raw, undecoded reads — `get_transaction/4`, `get_account_summaries/2`,
  `get_symbol_quote/3`, `get_market/3`, `get_instrument/3` and `get_user_preference/2` —
  and `refresh_credentials/2` have no fake. Each returns the venue's own JSON, so a fake
  would have to invent a venue document this repository has no credential to check
  against; a consumer needing one drives `DpExchange.Schwab.Rest` with its own `:plug`.
  The static lists and pure predicates (`movers_universes/0`, `markets/0`,
  `transaction_types/0`, `equity_instructions/0`, `option_instructions/0`,
  `needs_refresh?/2`, `credential_failure?/1`) are delegated, and `wanted/1`, `status/1`
  and `update_credentials/2` answer for the fake's own bookkeeping.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.Types.{Balance, Candle, Quote, TopOfBook}

  alias DpExchange.Core.{Config, FakeInjection, Notice, Types, Venue}
  alias DpExchange.Schwab
  alias DpExchange.Schwab.{Auth, Orders, Rest, SymbolFormat}

  @listed ~w(AAPL MSFT GOOGL AMZN NVDA F BRK.B)

  @prices %{
    "AAPL" => "227.50",
    "MSFT" => "418.20",
    "GOOGL" => "165.90",
    "AMZN" => "182.30",
    "NVDA" => "121.40",
    "F" => "10.85",
    "BRK.B" => "455.10"
  }

  # A fixed instant, not `DateTime.utc_now/0`. A fake whose timestamps move makes a
  # consumer's assertions flap, and the family's own rule is that a timestamp is the
  # venue's claim about an instant — so the fake states one.
  @as_of ~U[2026-08-31 14:30:00Z]

  # Ids as the venue issues them. An order id is an int64 that `Orders.from_venue/1` returns
  # as its decimal string (the `Location` header of a placement ends in it); the fake issued
  # `fake-order-1`, which the venue's own numbering can never produce. An account hash is the
  # opaque upper-case hex `accountNumbers` answers, here the spec fixture's own value (31
  # characters; the spec states no length, so none is claimed)
  # (`test/fixtures/spec_examples/accounts_and_trading/account_numbers_schema.json`); the
  # fake issued `FAKEHASH`. A replacement is a NEW order, so it has a different id.
  @order_id "1005439821"
  @hash "9ABCDEF0123456789ABCDEF01234567"

  # The one account the fake holds. `Rest.get_positions/2` names which account a read is
  # about by `opts[:account_number]` and refuses a number the credential has no account for,
  # after the read; the fake does the same against this number.
  @account_number "123456789"

  # What was asked for, kept apart from what the fake can deliver (`subscribed/0`).
  @wanted_key {__MODULE__, :wanted}

  @doc "Symbols this fake lists."
  @spec listed() :: [String.t()]
  def listed, do: @listed

  @doc "The instant every value from this fake is stamped with."
  @spec as_of() :: DateTime.t()
  def as_of, do: @as_of

  # --- identity -----------------------------------------------------------

  @impl true
  def provider_name, do: Schwab.provider_name()

  @impl true
  def runtime_id, do: Schwab.runtime_id()

  @impl true
  def asset_classes, do: Schwab.asset_classes()

  @impl true
  def capabilities, do: Schwab.capabilities()

  @doc "Endpoints the venue does not serve."
  @spec venue_does_not_serve() :: [{atom(), arity()}]
  defdelegate venue_does_not_serve, to: Schwab

  @doc "Quote currencies."
  @spec quotes() :: [String.t()]
  defdelegate quotes, to: Schwab

  @impl true
  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def start_link(_opts), do: :ignore

  # --- market data --------------------------------------------------------

  @impl true
  def get_price(symbol, opts \\ []) do
    with_injection(symbol, fn -> do_get_price(symbol, opts) end)
  end

  defp do_get_price(symbol, opts) do
    # The real order: the facade wants a credential map, `Rest` judges the symbol, and only
    # then does signing find a missing or blank token.
    with :ok <- require_credential_map(opts),
         {:ok, native} <- SymbolFormat.validate(symbol),
         :ok <- require_credentials(opts),
         {:ok, price} <- fetch_price(native) do
      {:ok,
       %Quote{
         symbol: native,
         price: Decimal.new(price),
         volume: Decimal.new("1000000"),
         # As the real `get_price/2`: the REST quote's `totalVolume`, a running total.
         volume_window: :running_total,
         venue_time: @as_of,
         observed_at: @as_of,
         provider: :schwab
       }}
    end
  end

  @impl true
  def get_top_of_book(symbol, opts \\ []) do
    with_injection(symbol, fn -> do_get_top_of_book(symbol, opts) end)
  end

  defp do_get_top_of_book(symbol, opts) do
    with :ok <- require_credential_map(opts),
         {:ok, native} <- SymbolFormat.validate(symbol),
         :ok <- require_credentials(opts),
         {:ok, price} <- fetch_price(native) do
      {:ok,
       %TopOfBook{
         symbol: native,
         bid: price |> Decimal.new() |> Decimal.sub(Decimal.new("0.01")),
         ask: price |> Decimal.new() |> Decimal.add(Decimal.new("0.01")),
         bid_size: Decimal.new("100"),
         ask_size: Decimal.new("200"),
         venue_time: @as_of,
         observed_at: @as_of,
         provider: :schwab
       }}
    end
  end

  defp fetch_price(native) do
    case Map.fetch(@prices, native) do
      {:ok, price} -> {:ok, price}
      :error -> {:refused, :not_listed}
    end
  end

  @impl true
  def get_historical_prices(symbol, timeframe, range, opts \\ []) do
    with_injection(symbol, fn -> do_get_historical_prices(symbol, timeframe, range, opts) end)
  end

  defp do_get_historical_prices(symbol, timeframe, range, opts) do
    with :ok <- require_credential_map(opts),
         {:ok, native} <- SymbolFormat.validate(symbol),
         # The real module's own question, in its order: width, range shape, then reach.
         :ok <- Rest.check_history(timeframe, range, @as_of),
         :ok <- require_credentials(opts),
         {:ok, price} <- fetch_price(native) do
      {:ok,
       for offset <- 4..0//-1 do
         base = Decimal.new(price)

         %Candle{
           symbol: native,
           timeframe: timeframe,
           opened_at: DateTime.add(@as_of, -offset * 60, :second),
           # A bar with four distinct prices. A fake whose OHLC all equal one number cannot
           # catch a caller that reads the wrong one.
           open: Decimal.sub(base, Decimal.new("0.50")),
           high: Decimal.add(base, Decimal.new("1.00")),
           low: Decimal.sub(base, Decimal.new("1.00")),
           close: base,
           volume: Decimal.new("250000"),
           provider: :schwab
         }
       end}
    end
  end

  @impl true
  def get_symbols(opts \\ []) do
    with_injection(nil, fn -> do_get_symbols(opts) end)
  end

  defp do_get_symbols(opts) do
    with :ok <- require_credential_map(opts),
         {:ok, query} <- fetch_query(opts),
         :ok <- require_credentials(opts) do
      # Sorted, as `Rest.get_symbols/2` returns them.
      {:ok,
       @listed
       |> Enum.filter(&String.starts_with?(&1, String.upcase(query)))
       |> Enum.sort()}
    end
  end

  defp fetch_query(opts) do
    case Keyword.get(opts, :query) do
      query when is_binary(query) and query != "" -> {:ok, query}
      _absent -> {:error, {:query_required, :schwab}}
    end
  end

  @impl true
  def preview_replace(_credentials, _id, _changes, _opts \\ []), do: Venue.not_supported()

  @impl true
  def close_position(_credentials, _symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def cancel_all_orders(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_order_book(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_trades(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_auction_imbalance(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_volume_profile(_symbol, _timeframe, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_market_overview(_opts \\ []), do: Venue.not_supported()

  @impl true
  def list_instruments(_opts \\ []), do: Venue.not_supported()

  @doc """
  Open by default, closed on request.

  The only place in the family where a consumer can exercise the closed-market path.
  """
  @impl true
  def market_status(opts \\ []) do
    with_injection(nil, fn -> do_market_status(opts) end)
  end

  defp do_market_status(opts) do
    with :ok <- require_credential_map(opts),
         # The real path's question: a market the venue has no hours for is refused.
         :ok <- Rest.check_market(Config.opt(opts, :market, "equity")),
         :ok <- require_credentials(opts) do
      {:ok, Config.opt(opts, :market_status, :open)}
    end
  end

  @impl true
  def quantization(_symbol), do: Venue.not_supported()

  # --- accounts and trading -----------------------------------------------

  @impl true
  def get_accounts(credentials, opts \\ []) do
    with_injection(nil, fn -> do_get_accounts(credentials, opts) end)
  end

  defp do_get_accounts(credentials, opts) do
    with :ok <- require_credentials(credentials: credentials) do
      {:ok, [%{account_number: @account_number, hash: Config.opt(opts, :account_hash, @hash)}]}
    end
  end

  @impl true
  def get_balances(credentials, opts \\ []) do
    with_injection(nil, fn -> do_get_balances(credentials, opts) end)
  end

  defp do_get_balances(credentials, opts) do
    with {:ok, _hash} <- require_account(opts),
         :ok <- require_credentials(credentials: credentials) do
      {:ok,
       [
         %Balance{
           currency: "USD",
           balance: Decimal.new("50000.00"),
           # Part of the total, never more than it: the real decode reads `availableFunds`, not
           # the leveraged `buyingPower`, for exactly that reason (`Rest.get_balances/3`).
           available_balance: Decimal.new("40000.00"),
           hold: nil,
           timestamp: @as_of,
           provider: :schwab
         }
       ]}
    end
  end

  @impl true
  def get_fees(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_transfers(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def place_order(credentials, request, opts \\ []) do
    with_injection(nil, fn -> do_place_order(credentials, request, opts) end)
  end

  defp do_place_order(credentials, request, opts) do
    # The real order (`Schwab.place_order/3`): account hash, then the order's own shape, then
    # the credential, which the real path only looks at when it signs the request.
    with {:ok, _hash} <- require_account(opts),
         # The real refusals, from the real module — a fake that accepted an order the
         # venue publishes as invalid would green-light code that cannot work.
         {:ok, payload} <- Orders.build(request, opts),
         :ok <- require_credentials(credentials: credentials) do
      # The read-back `Order`, as the real facade returns since 2026-10-10, not the bare id.
      # Of the order that was placed: its symbol, instruction, size and price, and the
      # venue's working state, not a filled AAPL buy whatever the request said.
      id = next_order_id()
      remember_body(id, working_body(id, payload))
      do_get_order(credentials, id, opts)
    end
  end

  # The venue's `Order` for a payload `Orders.build/2` produced, as it stands the moment
  # after the placement: `WORKING` and nothing filled. Sent through JSON, as the real one
  # is, so a `Decimal` price is the string the wire carries and the decode reads it back.
  defp working_body(id, payload) do
    [leg | _rest] = payload["orderLegCollection"]

    entered = %{
      "orderId" => wire_order_id(id),
      "status" => "WORKING",
      "quantity" => leg["quantity"],
      "filledQuantity" => 0,
      # Entered when it was placed, so a window around "now" lists it, as the venue's would.
      "enteredTime" => Calendar.strftime(DateTime.utc_now(), "%Y-%m-%dT%H:%M:%S+0000")
    }

    entered |> Map.merge(payload) |> Jason.encode!() |> Jason.decode!()
  end

  # Orders this process placed, as the venue-shaped bodies, by id.
  @orders_key {__MODULE__, :orders}
  @order_id_base 1_005_439_900

  defp next_order_id do
    Integer.to_string(@order_id_base + map_size(placed_bodies()) + 1)
  end

  defp placed_bodies, do: Process.get(@orders_key, %{})

  defp remember_body(id, body), do: Process.put(@orders_key, Map.put(placed_bodies(), id, body))

  # An order this process placed, else the one canned (filled, historical) order. Anything
  # else is an id the fake never issued: the venue's 404, `{:refused, {:venue_error, 404}}`
  # from `Rest.refusal/2` for a status with no readable detail. Every id used to read back
  # as a filled AAPL buy.
  defp find_body(order_id) do
    key = order_key(order_id)

    case Map.fetch(placed_bodies(), key) do
      {:ok, _body} = found -> found
      :error when key == @order_id -> {:ok, fake_order_body(@order_id)}
      :error -> {:refused, {:venue_error, 404}}
    end
  end

  # `Rest` puts an integer id into the path as its digits, so the fake reads it the same way.
  defp order_key(order_id) when is_integer(order_id), do: Integer.to_string(order_id)
  defp order_key(order_id), do: order_id

  @impl true
  def place_orders(_credentials, _requests, _opts), do: Venue.not_supported()

  # Both are real on this venue, so the fake answers rather than refusing — and it builds
  # through `Orders` for the same reason `place_order/3` does: an order the venue
  # publishes as invalid must be refused here too.
  @impl true
  def preview_order(credentials, request, opts \\ []) do
    with_injection(nil, fn -> do_preview_order(credentials, request, opts) end)
  end

  defp do_preview_order(credentials, request, opts) do
    with {:ok, _hash} <- require_account(opts),
         {:ok, _payload} <- Orders.build(request, opts),
         :ok <- require_credentials(credentials: credentials) do
      {:ok,
       %{
         "orderStrategy" => %{"orderType" => "MARKET"},
         "orderValidationResult" => %{"rejects" => []},
         "commissionAndFee" => %{"commission" => %{}}
       }}
    end
  end

  @impl true
  def replace_order(credentials, order_id, request, opts \\ []) do
    with_injection(nil, fn -> do_replace_order(credentials, order_id, request, opts) end)
  end

  defp do_replace_order(credentials, order_id, request, opts) do
    with {:ok, _hash} <- require_account(opts),
         :ok <- Rest.check_path_segment(order_id),
         {:ok, payload} <- Orders.build(request, opts),
         :ok <- require_credentials(credentials: credentials),
         {:ok, old} <- find_body(order_id),
         :ok <- require_working(old) do
      # A replacement is a NEW order on this venue, so the id differs from the one
      # replaced. A fake returning the old id would hide that from a consumer's test. The
      # old one is `REPLACED`, which the decode reads as no status at all, and no longer
      # cancellable; the new one is the working order the request describes.
      id = next_order_id()
      remember_body(order_key(order_id), %{old | "status" => "REPLACED"})
      remember_body(id, working_body(id, payload))
      do_get_order(credentials, id, opts)
    end
  end

  @impl true
  def cancel_order(credentials, order_id, opts \\ []) do
    with_injection(nil, fn -> do_cancel_order(credentials, order_id, opts) end)
  end

  defp do_cancel_order(credentials, order_id, opts) do
    with {:ok, _hash} <- require_account(opts),
         :ok <- Rest.check_path_segment(order_id),
         :ok <- require_credentials(credentials: credentials),
         {:ok, body} <- find_body(order_id),
         :ok <- require_working(body) do
      remember_body(order_key(order_id), %{body | "status" => "CANCELED"})
      {:ok, :cancelled}
    end
  end

  # Only a working order can be cancelled or replaced. The venue answers a 400 for one that
  # has filled, been cancelled or been replaced (`Rest.cancel_order/4` carries it as a
  # refusal); the fake used to confirm a cancel for any id at all.
  defp require_working(%{"status" => "WORKING"}), do: :ok
  defp require_working(_closed), do: {:refused, {:venue_error, 400}}

  @impl true
  def get_order(credentials, order_id, opts \\ []) do
    with_injection(nil, fn -> do_get_order(credentials, order_id, opts) end)
  end

  defp do_get_order(credentials, order_id, opts) do
    with {:ok, _hash} <- require_account(opts),
         :ok <- Rest.check_path_segment(order_id),
         :ok <- require_credentials(credentials: credentials) do
      # Decoded through the same `Orders.from_venue/1` the real facade uses, from a body in
      # the venue's own shape — so the fake cannot drift from the real decode. It returned the
      # raw map, the same contract violation the real facade had, which is why the suite
      # (driving fakes) could not see either.
      with {:ok, body} <- find_body(order_id), do: Orders.from_venue(body)
    end
  end

  @impl true
  def get_orders(credentials, opts \\ []) do
    with_injection(nil, fn -> do_get_orders(credentials, opts) end)
  end

  defp do_get_orders(credentials, opts) do
    with {:ok, _hash} <- require_account(opts),
         # The real venue refuses this call without both ends of a window
         # (`Rest.get_orders/3`'s own `fromEnteredTime`/`toEnteredTime` requirement) — a fake
         # that answered anyway would let a consumer's test suite go green calling this the
         # one way the real facade cannot be called.
         :ok <- Rest.check_order_window(opts),
         :ok <- require_credentials(credentials: credentials) do
      # One order, not `[]`: an empty list makes every check over its elements vacuous, which
      # is the "third axis" `dp_exchange_core`'s assertion-coverage document records.
      #
      # Then what this process placed, in id order, narrowed by `opts[:status]` as the venue's
      # own filter narrows. The canned order leads, so a read made before anything is placed
      # still has an element to check.
      with {:ok, bodies} <- windowed_bodies(opts), do: Orders.list_from_venue(bodies)
    end
  end

  @doc """
  Orders across every account, as `DpExchange.Schwab.get_all_orders/2` answers them: the
  venue's own rows, undecoded, as `Rest.get_all_orders/2` returns them.

  Refuses what the real path refuses before any request, through the same
  `Rest.check_all_orders_window/1`: a missing, reversed, over-long or unreadable window, a
  `status` outside the venue's enum, and a `from` more than 60 days before now
  (`opts[:now]` or the clock). No account hash is needed, as on the real endpoint. The
  window narrows the rows exactly as `get_orders/2` does: the canned order was entered on
  2026-01-02, so it is listed only by a window that contains that date and is recent enough
  to pass the 60-day rule.
  """
  @spec get_all_orders(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_all_orders(credentials, opts \\ []) do
    with_injection(nil, fn -> do_get_all_orders(credentials, opts) end)
  end

  defp do_get_all_orders(credentials, opts) do
    with :ok <- Rest.check_all_orders_window(opts),
         :ok <- require_credentials(credentials: credentials) do
      windowed_bodies(opts)
    end
  end

  # The canned order, then what this process placed in id order, narrowed by `opts[:status]`
  # and by the venue's own window: an order is returned only when it was entered inside
  # `fromEnteredTime..toEnteredTime`, ends included. The canned order was entered on
  # 2026-01-02, so a window that does not contain that date does not list it.
  defp windowed_bodies(opts) do
    placed = placed_bodies() |> Map.values() |> Enum.sort_by(& &1["orderId"])

    with {:ok, from, to} <- window_bounds(opts) do
      bodies =
        [fake_order_body(@order_id) | placed]
        |> Enum.filter(&status_wanted?(&1, Keyword.get(opts, :status)))
        |> Enum.filter(&entered_within?(&1, from, to))
        |> take_max_results(Keyword.get(opts, :max_results))

      {:ok, bodies}
    end
  end

  # `maxResults` bounds the page the venue returns. A positive integer narrows the list as
  # the venue's does; anything else is the venue's to judge, which the fake cannot, so it
  # leaves the list whole rather than inventing a refusal.
  defp take_max_results(bodies, max) when is_integer(max) and max > 0,
    do: Enum.take(bodies, max)

  defp take_max_results(bodies, _unbounded), do: bodies

  # The window as `DateTime`s. `Rest.check_order_window/1` has already run, so each end is a
  # `DateTime` or the venue's own string form (`yyyy-MM-dd'T'HH:mm:ss.SSSZ`), in range.
  defp window_bounds(opts) do
    {:ok, window_end(Keyword.fetch!(opts, :from)), window_end(Keyword.fetch!(opts, :to))}
  end

  defp window_end(%DateTime{} = at), do: at

  defp window_end(text) when is_binary(text) do
    {:ok, at, _offset} = DateTime.from_iso8601(text)
    at
  end

  defp entered_within?(body, from, to) do
    # Read by the facade's own decode (`created_at`), which also copes with the venue's
    # colon-less `+0000` offset, rather than a second parser here.
    case Orders.from_venue(body) do
      {:ok, %{created_at: %DateTime{} = entered}} ->
        DateTime.compare(entered, from) != :lt and DateTime.compare(entered, to) != :gt

      _unreadable ->
        false
    end
  end

  defp status_wanted?(_body, nil), do: true

  # `Rest.check_order_window/1` has already refused anything outside the venue's
  # `apiOrderStatus` enum, so this is an exact match, as the venue's filter is.
  defp status_wanted?(body, wanted), do: wanted == body["status"]

  # A venue-shaped `Order` object — the OpenAPI schema's own field names.
  defp fake_order_body(order_id) do
    %{
      "orderId" => wire_order_id(order_id),
      "status" => "FILLED",
      "orderType" => "LIMIT",
      "duration" => "DAY",
      "quantity" => 1,
      "filledQuantity" => 1,
      "price" => 190.25,
      "enteredTime" => "2026-01-02T15:04:05+0000",
      "orderLegCollection" => [
        %{"instruction" => "BUY", "quantity" => 1, "instrument" => %{"symbol" => "AAPL"}}
      ]
    }
  end

  # The venue sends `orderId` as an int64 (`"type": "integer"` in
  # `accounts-and-trading-production.openapi.json`), and `Orders.from_venue/1` turns it into
  # the string `Types.Order` carries. A numeric id goes through the decoder as the integer
  # the wire has, so the fake exercises the same path; an id that is not the canonical
  # decimal form of an integer (`"007"`, a caller's own string) is left exactly as given.
  defp wire_order_id(order_id) when is_binary(order_id) do
    case Integer.parse(order_id) do
      {number, ""} -> if Integer.to_string(number) == order_id, do: number, else: order_id
      _not_numeric -> order_id
    end
  end

  @impl true
  def get_trade_history(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def test_connection(credentials, opts \\ []) do
    with_injection(nil, fn -> do_test_connection(credentials, opts) end)
  end

  defp do_test_connection(credentials, opts) do
    # `do_get_accounts/2`, not `get_accounts/2`: this call has already consulted
    # `FakeInjection`, and the nested public read would consult it a second time.
    with {:ok, accounts} <- do_get_accounts(credentials, opts) do
      {:ok, %{accounts: length(accounts)}}
    end
  end

  @impl true
  def get_rate_limit_status(_credentials, _opts \\ []), do: Venue.not_supported()

  # --- streaming ----------------------------------------------------------

  @impl true
  # A symbol the real feed refuses (`{:invalid_symbols, _}`, the same equity-only judgement
  # `SymbolFormat.validate/1` makes for REST) is refused here too, before anything changes.
  # The fake used to drop it silently and answer `:ok`, so a consumer's test passed a pair
  # shaped symbol here that the real package refuses by name.
  def subscribe(symbols, opts \\ []) do
    with {:ok, symbols} <- checked_symbols(symbols) do
      to = Config.opt(opts, :to, self())
      covered = Enum.filter(symbols, &(&1 in @listed))

      Process.put(@wanted_key, Enum.uniq(wanted_symbols() ++ symbols))
      Process.put(__MODULE__, Enum.uniq(subscribed() ++ covered))

      # `do_get_price/2`, not `get_price/2`: the latter consults `FakeInjection`, so a failure a
      # consumer queued for `get_price` made this call raise a `MatchError`. The real
      # `subscribe/2` makes no price call, and the moduledoc says it is not wired.
      for symbol <- covered do
        {:ok, quote_struct} = do_get_price(symbol, credentials: %{access_token: "fake"})
        send(to, {:dp_exchange, :schwab, quote_struct})
      end

      :ok
    end
  end

  @impl true
  def unsubscribe(symbols, _opts \\ [])

  def unsubscribe(symbols, _opts) when not is_list(symbols),
    do: {:error, {:invalid_symbols, symbols}}

  def unsubscribe(symbols, _opts) do
    symbols = canonical_case(symbols)
    Process.put(@wanted_key, Enum.reject(wanted_symbols(), &(&1 in symbols)))
    Process.put(__MODULE__, Enum.reject(subscribed(), &(&1 in symbols)))
    :ok
  end

  @impl true
  def update_symbols(symbols, opts \\ []) do
    # Checked before the set is cleared: the real feed refuses first and changes nothing.
    with {:ok, symbols} <- checked_symbols(symbols) do
      Process.put(@wanted_key, [])
      Process.put(__MODULE__, [])
      subscribe(symbols, opts)
    end
  end

  @impl true
  def coverage(_opts \\ []), do: Map.new(subscribed(), &{&1, :internal_poll})

  @doc """
  What has been asked for, as `DpExchange.Schwab.wanted/1` answers it — every symbol the feed
  would hold, listed here or not. `coverage/1` is the other half: only the symbols this fake
  can deliver appear there.
  """
  @spec wanted(keyword()) :: [String.t()]
  def wanted(_opts \\ []), do: wanted_symbols()

  @doc """
  The feed-wide summary, as `DpExchange.Schwab.status/1` answers it on the poll route
  (`route: :internal_poll`, which is the route `coverage/1` reports here), with nothing
  failing: the fake delivers synchronously and has no error to report.
  """
  @spec status(keyword()) :: map()
  def status(_opts \\ []) do
    %{
      delivering: subscribed() != [],
      symbols: length(wanted_symbols()),
      covered: length(subscribed()),
      failures_since_ok: 0,
      last_error: nil,
      route: :internal_poll
    }
  end

  @doc """
  Accepts refreshed credentials as `DpExchange.Schwab.update_credentials/2` does. The fake
  holds no credential of its own, so a map is accepted and kept nowhere; anything else is
  `{:error, {:invalid_credentials, :schwab}}`, checked before anything else as on the facade.
  """
  @spec update_credentials(term(), keyword()) :: :ok | {:error, {:invalid_credentials, :schwab}}
  def update_credentials(credentials, _opts \\ [])
  def update_credentials(credentials, _opts) when is_map(credentials), do: :ok
  def update_credentials(_not_a_map, _opts), do: {:error, {:invalid_credentials, :schwab}}

  @doc "The mover universes the venue publishes. See `DpExchange.Schwab.movers_universes/0`."
  @spec movers_universes() :: [String.t()]
  defdelegate movers_universes, to: Schwab

  @doc "The markets the venue publishes hours for. See `DpExchange.Schwab.markets/0`."
  @spec markets() :: [String.t()]
  defdelegate markets, to: Schwab

  @doc "The venue's transaction types. See `DpExchange.Schwab.transaction_types/0`."
  @spec transaction_types() :: [String.t()]
  defdelegate transaction_types, to: Schwab

  @doc "Equity order instructions. See `DpExchange.Schwab.equity_instructions/0`."
  @spec equity_instructions() :: [String.t()]
  defdelegate equity_instructions, to: Schwab

  @doc "Option order instructions. See `DpExchange.Schwab.option_instructions/0`."
  @spec option_instructions() :: [String.t()]
  defdelegate option_instructions, to: Schwab

  @doc "Whether a credential needs refreshing. See `DpExchange.Schwab.needs_refresh?/2`."
  @spec needs_refresh?(map(), DateTime.t()) :: boolean()
  defdelegate needs_refresh?(credentials, now \\ DateTime.utc_now()), to: Schwab

  @doc "Whether a status means the credential is finished. See `credential_failure?/1`."
  @spec credential_failure?(pos_integer()) :: boolean()
  defdelegate credential_failure?(status), to: Schwab

  @doc """
  What `coverage/1` reports, split by kind — `:quotes` only, because that is all this fake
  can deliver.

  The real venue's `Feed` chooses between two routes and, on the Streamer route, can
  deliver `:top_of_book` and `:candles` alongside `:quotes` for a symbol subscribed on
  `LEVELONE_EQUITIES`/`LEVELONE_OPTIONS` and `CHART_EQUITY`. This fake models neither the
  route split nor the Streamer's second and third kinds — `subscribe/2` only ever pushes a
  `Types.Quote` built from `get_price/2` — so reporting anything beyond `:quotes` here
  would assert a delivery this fake cannot produce. Keeping this honest to what the fake
  actually does, rather than to everything the real venue can do, is the same choice
  `coverage/1` itself already made by answering `:internal_poll` unconditionally.
  """
  @impl true
  @spec coverage_by_kind(keyword()) :: %{
          DpExchange.Core.Capabilities.data_kind() => %{Venue.symbol() => Venue.route()}
        }
  def coverage_by_kind(opts \\ []), do: %{quotes: coverage(opts)}

  @doc """
  Registers for this fake's notice channel and delivers one, the way the real facade does.

  This used to be `def subscribe_notices(_opts \\\\ []), do: :ok` — it discarded
  `opts[:to]` and answered `:ok` unconditionally, so a consumer exercising its own notice
  handling against this fake received nothing and had no way to distinguish that from a
  venue with nothing to say.

  It is the same defect `DpExchange.Schwab`'s own `subscribe_notices/1` had — a facade
  backed by a real notice registry that discarded `opts[:to]` and answered `:ok` — which
  `Core.AdapterContract`'s assertion 16 names as "mechanism built, documented, and never
  wired". Fixing the real one and leaving the fake inert reproduces the gap in the one
  tier every consumer actually runs. Coinbase's, Gemini's and Webull's fakes all send a
  `:link_up` here; this one was the outlier.
  """
  @impl true
  def subscribe_notices(opts \\ []) do
    send(
      Config.opt(opts, :to, self()),
      {:dp_exchange, :schwab, Notice.new(:link_up, :schwab)}
    )

    :ok
  end

  defp subscribed, do: Process.get(__MODULE__, [])
  defp wanted_symbols, do: Process.get(@wanted_key, [])

  # --- plumbing -----------------------------------------------------------

  # Market data needs credentials here exactly as it does on the real venue. A fake that
  # served quotes anonymously would let a consumer build a code path the venue rejects.
  #
  # `{:error, {:missing_credentials, :schwab}}`, not `{:refused, _}`: a missing *local*
  # credential never reaches the venue at all, and `DpExchange.Core.Venue`'s own moduledoc
  # reserves `:refused` for the venue's own permanent word about a request it received.
  # This matches `DpExchange.Schwab`'s own `credentials/1` plumbing exactly — a fake
  # disagreeing with its own real facade on the shape of this refusal is the same
  # divergence assertion 17 exists to catch, one door down from a missing check entirely.
  #
  # **Two questions, asked where the real path asks them.** The facade's market-data calls
  # first want a credential map at all (`require_credential_map/1`); signing then wants a
  # non-blank `:access_token`, which is `Auth.headers/2`'s own judgement and is asked by
  # `require_credentials/1` after the request's own arguments are judged. A fake that
  # accepted any non-empty map (`%{refresh_token: "x"}`, `%{access_token: ""}`) answered
  # `{:ok, _}` where the real package refuses, on the one venue where a blank `.env` line is
  # the usual way a credential goes missing.
  defp require_credential_map(opts) do
    if FakeInjection.credentials_bypassed?(:schwab) do
      :ok
    else
      case Keyword.get(opts, :credentials) do
        %{} -> :ok
        _absent -> {:error, {:missing_credentials, :schwab}}
      end
    end
  end

  defp require_credentials(opts) do
    if FakeInjection.credentials_bypassed?(:schwab) do
      :ok
    else
      case Auth.headers(Keyword.get(opts, :credentials, %{})) do
        {:ok, _headers} -> :ok
        {:error, _reason} = refusal -> refusal
      end
    end
  end

  # `Core.FakeInjection`, the family's deterministic seam for making a fake fail on demand.
  #
  # This module had no wiring to it at all — the only one of the five venue packages
  # without any. A consumer could not use `queue_failures/2,3` or `fail_always/2,3` to
  # exercise its own retry, circuit-breaker or alerting code against this venue, and could
  # not use `bypass_credentials/1` to write a dispatch-only test without assembling a
  # credential map for every call. On the venue where **every** endpoint needs a credential
  # and there is no sandbox to fall back on, that is the package where the seam is worth
  # the most, not the least.
  #
  # Per-symbol targeting is real isolation: an override queued for one symbol can never be
  # satisfied by, or interfere with, a call for another. Functions taking no symbol pass
  # `nil` and match only a venue-wide override.
  defp with_injection(symbol, fun) do
    case FakeInjection.next_outcome(:schwab, symbol) do
      {:override, outcome} -> outcome
      :none -> fun.()
    end
  end

  defp require_account(opts) do
    case Keyword.get(opts, :account_hash) do
      hash when is_binary(hash) and hash != "" -> {:ok, hash}
      _absent -> {:error, {:missing_account_hash, :schwab}}
    end
  end

  # --- Declared but not yet implemented -----------------------------------
  #
  # Core 0.1.16 widened the facade to the surface the venues actually publish. These answer
  # `{:error, :not_supported}` and are declared `:unsupported` in `capabilities/0`, so a
  # consumer routing on the declaration is told the truth.
  #
  # **`:unsupported` here is a statement about this package, not about the venue.** That
  # distinction is the one Phase 1 had to correct after a package spent a year asserting a
  # venue had no streaming API when it had fifteen services. Where the venue genuinely does
  # not offer something, the comment beside it says so.

  @impl true
  def get_positions(opts \\ []) do
    with_injection(nil, fn -> do_get_positions(opts) end)
  end

  defp do_get_positions(opts) do
    with :ok <- require_credentials(opts),
         :ok <- check_account_number(Keyword.get(opts, :account_number)) do
      # A short, and no liquidation price — Schwab publishes none per position, and `nil`
      # there is not safety.
      {:ok,
       [
         %Types.Position{
           symbol: "AAPL",
           side: :short,
           quantity: Decimal.new("100"),
           instrument_type: :equity,
           average_cost: Decimal.new("180.25"),
           mark_price: nil,
           # Unsigned and without a realised figure, as the real decode: `Position` carries
           # direction in `:side`, and the venue states no realised P/L at all
           # (`Rest.get_positions/2`).
           notional_value: Decimal.new("17500"),
           realised_pnl: nil,
           unrealised_pnl: Decimal.new("-125"),
           liquidation_price: nil,
           leverage: nil,
           venue_time: nil,
           provider: :schwab
         }
       ]}
    end
  end

  defp check_account_number(nil), do: :ok
  defp check_account_number(@account_number), do: :ok
  defp check_account_number(number), do: {:refused, {:account_not_found, number}}

  @impl true
  def get_funding(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_contract_stats(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_rates(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_balances(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_rewards(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_history(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def stake(_asset, _amount, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def unstake(_asset, _amount, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def quote_conversion(_from, _to, _amount, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def commit_conversion(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_conversion(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def convert(_from, _to, _amount, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_trade_volume(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def list_portfolios(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_deposit_address(_asset, _network, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def list_approved_addresses(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def estimate_withdrawal_fee(_asset, _network, _amount, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def withdraw(_asset, _network, _amount, _address, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_option_chain(underlying, opts \\ []) do
    with_injection(injection_key(underlying), fn -> do_get_option_chain(underlying, opts) end)
  end

  defp do_get_option_chain(underlying, opts) do
    # The real order: the underlying, then the request's dates (`Rest.get_chains/2` judges
    # them before it signs anything), then the credential.
    with :ok <- Rest.check_underlying(underlying),
         :ok <- Rest.check_chain_dates(opts),
         :ok <- require_credentials(opts) do
      call = fake_contract(underlying, ~D[2026-03-20], Decimal.new("200"), :call)
      put = fake_contract(underlying, ~D[2026-03-20], Decimal.new("200"), :put)
      lone = fake_contract(underlying, ~D[2026-06-19], Decimal.new("220"), :call)

      {:ok,
       %Types.OptionChain{
         underlying: underlying,
         expiries: %{
           ~D[2026-03-20] => %{Decimal.new("200") => %{call: call, put: put}},
           # A strike with one side only, which a caller iterating strikes has to see.
           ~D[2026-06-19] => %{Decimal.new("220") => %{call: lone, put: nil}}
         },
         # Carried only when the venue sent it, and this fake did not ask for it.
         underlying_price: nil,
         venue_time: nil,
         provider: :schwab
       }}
    end
  end

  @impl true
  def get_option_expirations(underlying, opts \\ []) do
    with_injection(injection_key(underlying), fn ->
      with :ok <- Rest.check_underlying(underlying),
           :ok <- require_credentials(opts),
           do: {:ok, [~D[2026-03-20], ~D[2026-06-19]]}
    end)
  end

  # Per-symbol targeting by the underlying, when it is a symbol at all; a non-string is
  # refused by the real path before any request, so it targets only a venue-wide override.
  defp injection_key(underlying) when is_binary(underlying), do: underlying
  defp injection_key(_other), do: nil

  defp fake_contract(underlying, expiry, strike, right) do
    %Types.OptionContract{
      underlying: underlying,
      expiry: expiry,
      strike: strike,
      right: right,
      venue_symbol: "#{underlying}  #{Date.to_iso8601(expiry)}#{right}",
      multiplier: Decimal.new("100"),
      settlement_type: "P",
      expiration_type: "S",
      last_trading_day: nil,
      index_option: nil,
      mini: nil,
      non_standard: false,
      provider: :schwab
    }
  end

  @impl true
  def get_option_greeks(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def list_watchlists(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def create_watchlist(_name, _symbols, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def update_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def delete_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_financials(_symbol, _kind, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_corporate_events(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_filings(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_news(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_screener(name, opts \\ []) do
    with_injection(nil, fn -> do_get_screener(name, opts) end)
  end

  defp do_get_screener(name, opts) do
    # The universe before the credential, as the real path: `Rest.get_movers/3` refuses a
    # universe the venue has no list for before it signs anything.
    with :ok <- Rest.check_movers_universe(name),
         :ok <- Rest.check_movers_options(opts),
         :ok <- require_credentials(opts) do
      {:ok,
       [
         %Types.ScreenerResult{
           symbol: "AAPL",
           screener: name,
           # The venue's returned order, not a metric this fake ranked on.
           rank: 1,
           metrics: %{"symbol" => "AAPL", "netPercentChange" => 0.031, "volume" => 1_000_000},
           venue_time: nil,
           provider: :schwab
         }
       ]}
    end
  end

  @impl true
  def get_transactions(credentials, opts \\ []) do
    with_injection(nil, fn -> do_get_transactions(credentials, opts) end)
  end

  defp do_get_transactions(credentials, opts) do
    # The account hash, then the window and the type from `Rest.check_transactions/1` (the
    # module that sends the request, so the two cannot drift), and the credential last, as the
    # real path only looks at it when it signs. `require_account/1` rather than a second
    # spelling of the same check: this is the identical condition every other account
    # endpoint reports as `{:missing_account_hash, :schwab}`, and a consumer handling
    # "you forgot the account hash" uniformly cannot do it against two different atoms.
    with {:ok, _hash} <- require_account(opts),
         :ok <- Rest.check_transactions(opts),
         :ok <- require_credentials(credentials: credentials) do
      {:ok, [%{"activityId" => 1, "type" => "TRADE", "netAmount" => -1802.5}]}
    end
  end

  @impl true
  def list_payment_methods(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_payment_method(_credentials, _id, _opts \\ []), do: Venue.not_supported()

  @impl true
  def add_payment_method(_details, _opts \\ []), do: Venue.not_supported()

  @impl true
  def transfer_internal(_asset, _amount, _opts, _request_opts), do: Venue.not_supported()

  @impl true
  def request_approved_address(_asset, _network, _address, _opts \\ []),
    do: Venue.not_supported()

  @impl true
  def remove_approved_address(_network, _address, _opts \\ []), do: Venue.not_supported()

  @impl true
  def list_networks(_asset, _opts \\ []), do: Venue.not_supported()

  @impl true
  def list_fee_promos(_opts \\ []), do: Venue.not_supported()

  @impl true
  def get_fx_rate(_pair, _at, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_notional_balances(_credentials, _currency, _opts \\ []), do: Venue.not_supported()

  @impl true
  def list_custody_fees(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def create_account(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def rename_account(_id, _name, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_roles(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  # Upper-cased on the way in, as the real facade does, so a lower-case subscription gets
  # the same answer here as against the venue. Without it the fake delivered nothing for
  # `btc-usd` while the real package delivered `BTC-USD` (checked 2026-09-28).
  #
  # `SymbolFormat.to_canonical_symbol/1`, which also trims, as `Feed` does: `" aapl "` is a
  # valid symbol the real feed holds as `AAPL`, and upper-casing alone left it unlisted here.
  defp canonical_case(symbols) when is_list(symbols) do
    Enum.map(symbols, fn
      s when is_binary(s) -> SymbolFormat.to_canonical_symbol(s)
      other -> other
    end)
  end

  defp canonical_case(other), do: other

  # The real `Feed`'s question, in its order: canonical spelling, then the judgement REST
  # makes. A non-list is refused as the real feed now refuses it.
  defp checked_symbols(symbols) when is_list(symbols) do
    canonical = canonical_case(symbols)

    case Enum.reject(canonical, &match?({:ok, _native}, SymbolFormat.validate(&1))) do
      [] -> {:ok, canonical}
      invalid -> {:error, {:invalid_symbols, invalid}}
    end
  end

  defp checked_symbols(other), do: {:error, {:invalid_symbols, other}}
end
