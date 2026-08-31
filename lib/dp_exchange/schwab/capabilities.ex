defmodule DpExchange.Schwab.Capabilities do
  @moduledoc """
  What Schwab's Trader API can do, declared before anything was written against it.

  Every value here is read out of the two OpenAPI documents committed under
  `docs/reference/schwab/openapi/`, or out of the portal's Documentation tab beside them.
  Nothing is recalled and nothing is carried over from another venue. The distinction
  earns its keep: Gemini's own published candle-width list names three widths its API
  rejects, and only measurement caught that.

  `docs/reference/schwab/spec-facts.md` names the schema or parameter behind each value.
  When something here changes, that file is what it must be checked against.

  ## Nothing here is measured against the live API

  Reading a specification is tier-1 evidence (D7). It supports `:experimental` and it can
  never support `:proven`, because a specification describes what a venue is documented to
  do rather than what it does. Every endpoint below is therefore `:experimental` or
  `:unsupported`, and the one live observation on record is an unauthenticated `401` from
  `/marketdata/v1/quotes`, which confirms the base URL and nothing else.

  ## This venue is not shaped like the others

  Five differences matter enough to state before the values:

  **A symbol is one instrument, not a pair.** Every other venue in the family addresses a
  pair and returns one quote shape. Schwab has seven quote shapes across `AssetMainType`
  and a symbol names a single security.

  **The catalogue cannot be enumerated.** `/instruments` has no list-everything projection,
  so `get_symbols/1` is declared **active** but requires a `:query`. It is not
  `:unsupported`, and the difference is the point: "needs a search term" and "has no
  endpoint" are different facts, and a caller has to be able to act on each.

  **No order book and no socket *here*; the venue has both.** No endpoint in either
  OpenAPI document returns depth, and neither describes a streaming surface — both true,
  and both statements about the documents rather than the venue. Schwab's WebSocket
  **Streamer** carries `NYSE_BOOK`, `NASDAQ_BOOK` and `OPTIONS_BOOK`, and is documented in
  the prose beside those specifications. `get_order_book/2` stays `:unsupported` because
  this package does not speak the Streamer yet, and `streamable` stays `[:quotes]` for the
  same reason. Both change when it does.

  **The market closes.** `/markets` answers `isOpen` directly. This is the venue
  `market_status/1` was added to the contract for — a feed that alarms on silence would
  alarm every night, making a real outage indistinguishable from Saturday.

  **There is no sandbox.** Schwab writes that Trader API sandboxes "will be available
  later this year" in a document published 2025-10-30, and neither spec declares a
  non-production server. Unlike Gemini, this venue cannot be exercised end to end without
  touching real money.
  """

  alias DpExchange.Core.{Capabilities, Venue}

  @typedoc "A `{name, arity}` pair naming one `Core.Venue` callback."
  @type endpoint :: {atom(), arity()}

  # Endpoints the venue itself does not serve. Kept apart from "not yet implemented"
  # because a caller reacts to both the same way but anyone deciding what to build next
  # needs to know which is which — `venue_does_not_serve/0` exposes exactly this list.
  #
  # `get_order_book/2`        — no endpoint in either document returns depth.
  # `get_transfers/2`         — money movement is not in the Trader API at all.
  # `get_fees/2`              — no fee-schedule endpoint. `previewOrder` returns a
  #                             commission estimate for *one order*, which the contract
  #                             cannot express and which is not a fee schedule.
  # `get_symbols/1` is NOT here: it works, but requires a `:query`, because the venue has
  #                             no list-everything projection. See the facade.
  #

  # `list_instruments/1`      — an optional DataProvider callback returning richer
  #                             `Instrument` values. `get_symbols/1` already covers the
  #                             searchable surface, and the extra fields are not
  #                             checkable without a credential.
  # `get_market_overview/1`   — no bulk-snapshot endpoint. `/movers` covers a handful of
  #                             indices, which is not an overview of the venue.
  # `get_rate_limit_status/2` — nothing to query. The order ceiling is a property of the
  #                             application's registration, not runtime state.
  # `quantization/1`          — tick and lot rules are not published in either document.
  #                             A guessed `qty_step` is how an order is rejected at
  #                             submission for a reason nobody can see.
  #
  # `get_trade_history/2` is here for a *different* reason and it is worth separating:
  # `/transactions` exists and carries fills. Mapping one onto `Core.Types.Fill` needs a
  # live response to check against, and this repository holds no credential and the venue
  # has no sandbox. Declared `:unsupported` because that is what the facade returns today
  # — a declaration that disagreed with the code would be the worse of the two errors.
  # This one moves when someone with a credential can check the shape.
  @venue_does_not_serve [
    # Core 0.1.16's wider facade. **Mixed provenance, and the distinction matters here more
    # than anywhere** — this is the package that spent a year asserting the venue had no
    # streaming API when it had fifteen services.
    #
    # The venue genuinely does not serve: staking, perpetual funding, conversions, crypto
    # deposit and withdrawal addresses. Schwab is an equities and options broker.
    #
    # The venue DOES serve these and this package does not implement them yet: option
    # chains and expirations (`/chains`, `/expirationchain`), movers as a screener
    # (`/movers/{symbol_id}`), and positions via the accounts endpoint. Each is a Phase
    # 3–13 item, recorded in `docs/reference/schwab/coverage-matrix.md`.
    {:get_positions, 1},
    {:get_funding, 2},
    {:get_contract_stats, 2},
    {:get_staking_rates, 1},
    {:get_staking_balances, 1},
    {:get_staking_rewards, 1},
    {:get_staking_history, 1},
    {:stake, 3},
    {:unstake, 3},
    {:quote_conversion, 4},
    {:commit_conversion, 2},
    {:get_conversion, 2},
    {:list_portfolios, 1},
    {:get_deposit_address, 3},
    {:list_approved_addresses, 1},
    {:estimate_withdrawal_fee, 4},
    {:withdraw, 5},
    {:get_option_chain, 2},
    {:get_option_expirations, 2},
    {:get_option_greeks, 2},
    {:list_watchlists, 1},
    {:get_watchlist, 2},
    {:create_watchlist, 3},
    {:update_watchlist, 2},
    {:delete_watchlist, 2},
    {:get_financials, 3},
    {:get_corporate_events, 1},
    {:get_filings, 2},
    {:get_news, 1},
    {:get_screener, 2},
    {:create_account, 1},
    {:rename_account, 3},
    {:get_roles, 1},
    {:get_order_book, 2},
    {:get_transfers, 2},
    {:get_fees, 2},
    {:list_instruments, 1},
    {:get_market_overview, 1},
    {:get_rate_limit_status, 2},
    {:quantization, 1},
    {:get_trade_history, 2}
  ]

  @doc """
  Endpoints this venue does not serve, as distinct from ones not yet written.

  Everything named here is `:unsupported` in `declaration/0`, and the test suite asserts
  that rather than trusting it.
  """
  @spec venue_does_not_serve() :: [endpoint()]
  def venue_does_not_serve, do: @venue_does_not_serve

  @doc """
  The eight candle widths `GET /pricehistory` serves.

  A width is not one parameter here. It is a `(periodType, frequencyType, frequency)`
  triple, and the legal combinations are constrained in both directions — see
  `spec-facts.md` §1 for the full table.

  **The minute widths are only reachable through `periodType=day`, which caps the
  lookback at ten days.** Ten days of one-minute candles is the most this venue will
  serve, and no combination of the other parameters extends it. A consumer asking for a
  year of one-minute data cannot be served and must be told so — handing back a coarser
  series instead is the substitution this family exists to refuse.
  """
  @spec timeframes() :: [String.t()]
  def timeframes, do: ~w(1m 5m 10m 15m 30m 1d 1w 1M)

  @doc """
  The declaration.

  Built through `Capabilities.new/1` so Core validates it: an endpoint naming a callback
  that does not exist, an order type outside the contract's vocabulary, or a malformed
  ceiling all raise here rather than being discovered by a consumer.
  """
  @spec declaration() :: Capabilities.t()
  def declaration do
    Capabilities.new(
      endpoints: endpoint_maturities(),

      # US securities, quoted in USD. `AssetMainType` includes FOREX, which this package
      # does not address; that is a scope decision, and `asset_classes/0` says so.
      supported_quotes: ["USD"],

      # `:spot` is the closest atom the contract has, and it understates the venue.
      # `assetType` admits EQUITY, OPTION, FUTURE, FOREX, INDEX, MUTUAL_FUND,
      # FIXED_INCOME and more; Core's vocabulary is `[:spot, :perp]`, which was written
      # for crypto. Recorded as a Core gap (7.5) rather than papered over — declaring
      # `:spot` and saying nothing would imply the venue trades only spot equities.
      # Now expressible. `assetType` admits eleven values; these are the ones this venue
      # trades and quotes. Until Core learned them, this read `[:spot]` with a comment
      # saying the declaration understated the venue — and a declaration that needs a
      # comment to be true is exactly what the struct exists to prevent.
      #
      # `EQUITY` maps to `:spot`: a share bought outright is a spot instrument. The rest
      # are their own thing and were being flattened into it.
      supported_instrument_types: [
        :spot,
        :option,
        :future,
        :future_option,
        :index,
        :mutual_fund,
        :bond,
        :forex,
        :cash_equivalent
      ],

      # `instruction` admits SELL_SHORT, SELL_SHORT_EXEMPT and BUY_TO_COVER, and
      # `MarginBalance` carries `shortBalance` and `shortMarginValue`.
      supports_short_selling: true,

      # `SecuritiesAccount` is a discriminated union of `MarginAccount` and `CashAccount`.
      supports_margin: true,

      # **`:per_account`, and this is the answer 7.2 was asked to find.**
      #
      # A single leverage scalar is the wrong shape twice over. `MarginBalance` carries
      # five different buying powers — `buyingPower`, `buyingPowerNonMarginableTrade`,
      # `dayTradingBuyingPower`, `optionBuyingPower`, `stockBuyingPower` — which are not
      # multiples of one another, so no one of them is "the" leverage. And on a
      # `CashAccount` every one of them is absent, so any number reported for a cash
      # account would be invented.
      #
      # The Reg-T fields are `regTCall` and `sma`, and both are call and credit *amounts*
      # rather than ratios. Equities margin is not crypto margin, and Kraken's 5x does not
      # carry over. Leverage on this venue is a property of an account, not of the venue,
      # and belongs in a balance response rather than in a capability declaration.
      max_leverage: :per_account,

      # `quantity` is a double and `quantityType` admits DOLLARS as well as SHARES — a
      # dollar-denominated order necessarily yields a fractional share count.
      supports_fractional_shares: true,

      # **Both are real here, and both were Core gaps until this venue arrived.**
      #
      # `previewOrder` validates an order and returns estimated commission without
      # placing it. It is worth more on this venue than it would be elsewhere: order
      # writes are throttled and reads are not, so a rejection found by previewing costs
      # nothing while one found by placing costs a scarce write.
      #
      # `PUT .../orders/{orderId}` amends atomically. Every other venue in the family
      # cancels and re-places, and here those are **not equivalent** — cancel-then-place
      # opens a window in which no order is live, and spends two throttled writes rather
      # than one. So this is a claim about risk, not convenience.
      supports_order_preview: true,
      supports_order_replace: true,

      # `orderStrategyType` admits TRIGGER and OCO, and a vertical spread carries two
      # legs at one NET_DEBIT price. `place_order/3` takes a flat request, so this
      # package cannot build them and says so rather than declaring a capability the
      # facade cannot reach.
      supports_multi_leg_orders: false,

      # `session` is on every documented order, including the simplest market order.
      # Nothing in the family needed this until a venue whose market closes arrived.
      supported_sessions: [:pre_market, :regular, :post_market, :extended],

      # `/instruments` has no list-everything projection — all six of its projections
      # search against a term. `get_symbols/1` is active and requires `:query`.
      catalog_access: :query_only,

      # Four of Core's seven map. The three that do not are named rather than
      # approximated:
      #
      #   `:ioc` and `:fok` are **not order types here** — they are `duration` values
      #   (IMMEDIATE_OR_CANCEL, FILL_OR_KILL), and they appear below under
      #   `supported_time_in_force` where they belong. Declaring them here would repeat
      #   the mistake already caught once on Gemini, where `:post_only` was declared as a
      #   time-in-force.
      #
      #   `:post_only` has no equivalent. NON_MARKETABLE is close and is not the same
      #   thing, so it is absent rather than mapped.
      #
      # TRAILING_STOP, TRAILING_STOP_LIMIT, MARKET_ON_CLOSE and LIMIT_ON_CLOSE are real
      # order types this venue supports that Core has no vocabulary for. The honest
      # declaration lists only what Core can name; the gap is recorded at 7.5.
      # Eight, now that Core has words for four of them. TRAILING_STOP,
      # TRAILING_STOP_LIMIT, MARKET_ON_CLOSE and LIMIT_ON_CLOSE are real order types this
      # venue accepts, and until Core learned them this list read as four — under-declaring,
      # which is the safe direction and still a lie about the venue.
      supported_order_types: [
        :market,
        :limit,
        :stop,
        :stop_limit,
        :trailing_stop,
        :trailing_stop_limit,
        :market_on_close,
        :limit_on_close
      ],

      # `duration`: DAY, GOOD_TILL_CANCEL, FILL_OR_KILL, IMMEDIATE_OR_CANCEL.
      #
      # `:gtd` is **absent, not approximated.** Schwab expresses dated expiry as
      # END_OF_WEEK, END_OF_MONTH and NEXT_END_OF_MONTH — three fixed horizons, not an
      # arbitrary date. A caller asking for good-till-date cannot be served by picking the
      # nearest of the three.
      supported_time_in_force: [:day, :gtc, :fok, :ioc],

      # Quotes, and they arrive by poll. What a consumer receives is identical to a
      # streaming venue's; `coverage/1` reports `:internal_poll`, so the difference is
      # visible as what is arriving rather than as how it got here.
      streamable: [:quotes],
      authenticated_streamable: [:quotes],
      historical_timeframes: timeframes(),

      # Not a fixed number. The cap is a *period*, not a bar count, and it differs per
      # width: `periodType=day` allows at most 10 days, which is ~3,900 one-minute bars
      # over regular hours and a different number with extended hours enabled. Declaring
      # any single integer would be a guess that reads as a measurement.
      max_candles_per_request: nil,

      # `Candle` carries `volume`, and `QuoteEquity` carries `totalVolume`.
      reports_trade_volume: true,

      # Every US-listed equity and option. `GET /instruments` has **no "list everything"
      # projection** — every lookup is a search against a term — so the catalogue cannot
      # be enumerated at all, only queried. That is what 7.4 has to answer against.
      catalog_size: :vast,

      # OAuth 2.0 authorization-code on every endpoint in both documents, market data
      # included. There is no anonymous surface. The access token lives 30 minutes, and
      # `Auth.refresh/2` renews it in-package — minting a new refresh token each time,
      # itself valid for a fresh seven days. So a host that keeps refreshing never needs a
      # person again; only the initial grant needs a browser.
      credential_benefit: :required,

      # No anonymous surface, so no public ceiling to declare. `nil` is the absence of a
      # ceiling to state, not an unlimited one.
      public_ceiling: nil,

      # **Still nil, and now for a stated reason rather than for want of a way to say it.**
      #
      # Schwab's documented limit is `0..120` order writes per minute **per account**, set
      # **per application at registration**. Reads are unthrottled.
      #
      # Core can now express the two halves that were missing — `:scope` says a ceiling is
      # counted per account rather than per credential, and `limit: 0` is legal, so a
      # registration granted no order throughput is expressible and is distinguishable
      # from `:unsupported`. What Core still cannot do, and should not, is invent the
      # number: it is a property of *the consumer's own registration*, so any value here
      # would be a claim about somebody else's.
      #
      # So this stays `nil` — meaning "there is no venue constant" — and the host passes
      # `:order_limit_per_minute` to the supervisor, which builds the ceiling with
      # `scope: :account`. `Supervisor.limits/1` is where the shape now lives.
      authenticated_ceiling: nil,
      measured_at: ~D[2026-08-31],
      measured_against:
        "the two OpenAPI documents the Schwab Developer Portal serves for Trader API - " <>
          "Individual (Market Data Production, OpenAPI 3.0.3, and Accounts and Trading " <>
          "Production, OpenAPI 3.0.1), captured 2026-08-28 from an authenticated session " <>
          "and committed verbatim under docs/reference/schwab/, together with the " <>
          "portal's Documentation tab for both. Candle widths, order and duration enums, " <>
          "margin fields, instruction set and quantity types are READ FROM THOSE " <>
          "DOCUMENTS. NOTHING IS PROBED: every endpoint requires OAuth credentials this " <>
          "repo must never hold, and the venue publishes no sandbox to probe without " <>
          "them. Ceilings NOT measured — the documented order limit is per-application " <>
          "and per-account, so there is no venue constant to declare. The only live " <>
          "observation is an unauthenticated 401 from /marketdata/v1/quotes on " <>
          "2026-08-28, which confirms the base URL and path shape and nothing further"
    )
  end

  defp endpoint_maturities do
    active =
      for {name, arity} <- Venue.behaviour_info(:callbacks),
          {name, arity} not in @venue_does_not_serve,
          into: %{},
          do: {{name, arity}, :experimental}

    Enum.into(@venue_does_not_serve, active, &{&1, :unsupported})
  end
end
