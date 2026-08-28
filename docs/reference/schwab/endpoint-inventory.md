# Schwab Trader API — endpoint inventory

**Source**: the Charles Schwab Developer Portal, "Trader API – Individual", captured by the
architect on **2026-08-28** and committed verbatim under `portal-capture/`.

Schwab's documentation is **private** — the portal returns `403` without a session — so
unlike the other four venues nothing here can be re-fetched by a reader. That is exactly
why the captures are in the repository rather than linked: this file must be checkable
against a fixed source, and the source has to travel with it.

## What the captures do and do not contain

**They contain** the complete endpoint inventory and the full list of schema names, for
both halves of the API. That is reproducible from the committed files by anyone.

**They do not contain parameter values.** The portal is a Swagger UI that fetches its
OpenAPI document at runtime, so a saved page carries the outline and not the spec. Searched
in both captures: `periodType` — 0 hits, `frequencyType` — 0 hits. Schema *names* like
`orderType`, `session` and `duration` appear; their enum members do not.

This is recorded rather than filled in from memory. Getting a candle-width enum from
recollection is precisely the failure this family exists to prevent, and it has already
bitten once: Gemini's own published enum lists three widths its API rejects, and only
measurement caught it.

## Verified live, 2026-08-28

| Check | Result |
|---|---|
| `GET https://api.schwabapi.com/marketdata/v1/quotes` | **401** — the endpoint exists and requires authentication |
| `https://developer.schwab.com/…/specifications/…` | **403** — the documentation is private, as expected |
| A public OpenAPI document | none found |

The `401` is worth stating: it confirms the base URL and path shape from the capture are
right, without a credential and without guessing.

**No sandbox is mentioned anywhere in either capture** — searched for `sandbox`, `paper`
and `simulat`, zero hits. Task 7.1 asks whether a sandbox exists and whether it works; on
this evidence the answer to the first is *not documented*, so the second does not arise
yet. Gemini's demo environment turned out to be the family's most useful testing surface,
so this is worth a direct question to Schwab rather than an assumption either way.

## Market Data

**Server**: `https://api.schwabapi.com/marketdata/v1`

| Method | Path | Purpose |
|---|---|---|
| GET | `/quotes` | quotes by list of symbols |
| GET | `/{symbol_id}/quotes` | quote by single symbol |
| GET | `/chains` | option chain for an optionable symbol |
| GET | `/expirationchain` | option expiration chain |
| GET | `/pricehistory` | price history for a single symbol and date range |
| GET | `/movers/{symbol_id}` | movers for a specific index |
| GET | `/markets` | market hours for several markets |
| GET | `/markets/{market_id}` | market hours for one market |
| GET | `/instruments` | instruments by symbols and projections |
| GET | `/instruments/{cusip_id}` | instrument by CUSIP |

### Three things this list settles on its own

**There is no order-book endpoint.** Quotes, chains, price history, movers, hours,
instruments — and nothing that returns depth. `get_order_book/2` is `:unsupported` on the
inventory alone.

**There is a market-hours endpoint, and this is the venue that needs one.** `market_status/1`
exists in the contract for exactly this: an equities venue is closed nights and weekends,
and a feed that alarms on delivering nothing would alarm every night, making a real outage
indistinguishable from Saturday. Schwab is the first venue in the family that can answer it
from the venue rather than by assuming `:open`.

**It is not a crypto venue.** The schema list carries `QuoteEquity`, `QuoteOption`,
`QuoteFuture`, `QuoteFutureOption`, `QuoteIndex`, `QuoteForex`, `QuoteMutualFund` — seven
quote shapes across `AssetMainType`. Every other venue in this family returns one shape for
one asset class, and the symbol is a *pair*. Here a symbol is a single instrument.

## Accounts and Trading

**Server**: `https://api.schwabapi.com/trader/v1`

| Method | Path | Purpose |
|---|---|---|
| GET | `/accounts/accountNumbers` | account numbers and their encrypted values |
| GET | `/accounts` | balances and positions for all linked accounts |
| GET | `/accounts/{accountNumber}` | balances and positions for one account |
| GET | `/accounts/{accountNumber}/orders` | orders for one account |
| POST | `/accounts/{accountNumber}/orders` | place an order |
| GET | `/accounts/{accountNumber}/orders/{orderId}` | one order |
| DELETE | `/accounts/{accountNumber}/orders/{orderId}` | cancel an order |
| PUT | `/accounts/{accountNumber}/orders/{orderId}` | **replace** an order |
| GET | `/orders` | orders across all accounts |
| POST | `/accounts/{accountNumber}/previewOrder` | preview an order |
| GET | `/accounts/{accountNumber}/transactions` | transactions |
| GET | `/accounts/{accountNumber}/transactions/{transactionId}` | one transaction |
| GET | `/userPreference` | user preferences |

### Two capabilities the contract has no slot for

**`previewOrder`.** Schwab will tell you what an order *would* do — validation, estimated
commission and fees — without placing it. Nothing in `Core.Venue` expresses that, and it is
genuinely useful: it is the only endpoint in the family that lets a consumer check an order
against the venue's own rules before committing. Worth raising as a Core question rather
than quietly dropping.

**Order replacement (`PUT`).** Every other venue in this family cancels and re-places.
Schwab replaces atomically. `Core.Venue` has `cancel_order/3` and `place_order/3` and no
`replace_order`, so the contract can only express this as two calls — which on this venue
is *not* equivalent, because a cancel-then-place has a window where neither order is live.

Both are recorded here rather than decided: 7.2 derives the declaration, and a contract
gap found from documentation is exactly what Phase 7 exists to surface.

### Accounts are addressed by an encrypted number

`/accounts/accountNumbers` returns account numbers **and their encrypted values**, and
every other account path takes `{accountNumber}`. That strongly suggests the encrypted form
is what the other endpoints expect, which would make an account lookup a prerequisite for
every account call. The captures do not state it outright, so it is flagged as a question
for 7.2 rather than asserted.

## Schema names, verbatim

Recorded because they are what the runtime spec would flesh out, and because the *shape* of
the list is already informative.

**Market data**: `Bond`, `FundamentalInst`, `Instrument`, `InstrumentResponse`, `Hours`,
`Interval`, `Screener`, `Candle`, `CandleList`, `EquityResponse`, `QuoteError`,
`ExtendedMarket`, `ForexResponse`, `Fundamental`, `FutureOptionResponse`, `FutureResponse`,
`IndexResponse`, `MutualFundResponse`, `OptionResponse`, `QuoteEquity`, `QuoteForex`,
`QuoteFuture`, `QuoteFutureOption`, `QuoteIndex`, `QuoteMutualFund`, `QuoteOption`,
`QuoteRequest`, `QuoteResponse`, `QuoteResponseObject`, `ReferenceEquity`,
`ReferenceForex`, `ReferenceFuture`, `ReferenceFutureOption`, `ReferenceIndex`,
`ReferenceMutualFund`, `ReferenceOption`, `RegularMarket`, `AssetMainType`,
`EquityAssetSubType`, `MutualFundAssetSubType`, `ContractType`, `SettlementType`,
`ExpirationType`, `FundStrategy`, `ExerciseType`, `DivFreq`, `QuoteType`, `ErrorResponse`,
`Error`, `ErrorSource`, `OptionChain`, `OptionContractMap`, `Underlying`,
`OptionDeliverables`, `OptionContract`, `ExpirationChain`, `Expiration`.

**Accounts and trading**: `AccountNumberHash`, `session`, `duration`, `orderType`,
`orderTypeRequest`, `complexOrderStrategyType`, `requestedDestination`,
`stopPriceLinkBasis`, `stopPriceLinkType`, `stopPriceOffset`, `stopType`,
`priceLinkBasis`, `priceLinkType`, `taxLotMethod`, `specialInstruction`,
`orderStrategyType`, `status`, `amountIndicator`, `settlementInstruction`, `OrderStrategy`,
`OrderLeg`, `OrderBalance`, `OrderValidationResult`, `OrderValidationDetail`,
`APIRuleAction`, `CommissionAndFee`.

`orderType` **and** `orderTypeRequest` as separate schemas is worth noticing: a venue that
distinguishes the order type you *ask for* from the order type an order *has* usually does
so because some requested types resolve into others.

## What is still needed before 7.2 can be finished

The declaration needs values this capture does not carry:

1. **`/pricehistory` parameters** — `periodType`, `period`, `frequencyType`, `frequency`
   and their accepted enum members. Without them `historical_timeframes` cannot be declared,
   and declaring it from memory is the exact failure this family refuses.
2. **`orderType` / `orderTypeRequest` / `duration` / `session` enum members** — needed for
   `supported_order_types` and `supported_time_in_force`.
3. **Margin fields** — whether Reg-T buying power appears on the account response, and in
   what shape. §7.2 flags that `max_leverage` may be the wrong shape for a Reg-T account,
   and that is answerable only from the account schema.
4. **Rate limits** — no ceiling appears in either capture.
5. **Whether a sandbox exists.**

Any one of these would do it: the OpenAPI JSON the portal fetches (visible in a browser's
network tab as it loads the Specifications page), the expanded per-endpoint views, or the
"Documentation" tab that sits beside "Specifications" in the same portal.
