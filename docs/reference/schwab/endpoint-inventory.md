# Schwab Trader API — endpoint inventory

**Source**: the Charles Schwab Developer Portal, "Trader API – Individual", captured by the
architect on **2026-08-28** and committed verbatim under `portal-capture/`.

Schwab's documentation is **private** — the portal returns `403` without a session — so
unlike the other four venues nothing here can be re-fetched by a reader. That is exactly
why the captures are in the repository rather than linked: this file must be checkable
against a fixed source, and the source has to travel with it.

## Superseded in part — read `spec-facts.md` first

This file was written from saved portal *pages*, which carry the endpoint outline and not
the spec. On **2026-08-28** the architect signed the browser in and the two OpenAPI
documents were captured in full; they are in `openapi/`, and everything derived from them
is in **`spec-facts.md`**.

What that changes here:

- The section that used to say parameter values were unavailable is gone. They are
  available. `periodType`, `frequencyType` and every order enum are in `spec-facts.md`.
- The endpoint lists below were **checked against the real specs and are exactly right** —
  10 market-data paths and 13 trading operations across 10 paths, no more and no fewer. That is worth saying,
  because it means the outline-only capture was not lossy about *shape*, only about values.
- One reading below was **wrong**, and is corrected in place: see "Schema names, verbatim".
- The sandbox question is answered, and the answer is no. See `spec-facts.md` §5.

What still stands: none of it is measured against the live API, for want of a credential.
## Verified live, 2026-08-28

| Check | Result |
|---|---|
| `GET https://api.schwabapi.com/marketdata/v1/quotes` | **401** — the endpoint exists and requires authentication |
| `https://developer.schwab.com/…/specifications/…` | **403** — the documentation is private, as expected |
| A public OpenAPI document | none found |

The `401` is worth stating: it confirms the base URL and path shape from the capture are
right, without a credential and without guessing.

**Sandbox: answered, and the answer is no.** The saved pages mentioned no sandbox because
the sandbox text lives on the *Documentation* tab, which the page capture did not carry.
It does now: Schwab writes that "The Trader API Sandbox environments will be available
later this year" — a promise, in a document published 2025-10-30, with no sandbox server in
either spec. Task 7.1 is therefore closed: there is nothing to test against. Gemini's demo
environment was the family's most useful testing surface and this venue has no equivalent,
which is a real difference between them rather than a gap in the capture.

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
`orderType` **and** `orderTypeRequest` as separate schemas was read here as meaning that
some requested types resolve into others. **That was wrong**, and the spec says so: the two
enums are identical except that `orderType` also carries `UNKNOWN`. It is a read-side
escape hatch — a value an order can come back as and a value you cannot send — not a
resolution rule. Recorded rather than quietly edited, because the guess was plausible and
the plausible-but-wrong reading is the failure mode this reference exists to catch.

## What 7.2 was waiting on — all five answered

Every one of the five open items is now read out of the specs. They are in `spec-facts.md`
with the schema or parameter each came from; in short:

1. **`/pricehistory` parameters** — eight candle widths (1m, 5m, 10m, 15m, 30m, 1d, 1w,
   1M), reachable only through constrained `(periodType, frequencyType, frequency)`
   triples. The minute widths cap the lookback at 10 days.
2. **Order enums** — full members for `orderType`, `orderTypeRequest`, `duration` and
   `session`. Four of Core's seven order types map; `:ioc`/`:fok` are `duration` values
   here and must not be declared as order types; `:post_only` and `:gtd` have no
   equivalent.
3. **Margin fields** — `MarginBalance` carries five distinct buying powers plus `regTCall`
   and `sma`; `CashBalance` carries none of them. `max_leverage` is the wrong shape and
   should not be declared for this venue.
4. **Rate limits** — order writes are `0..120` per minute **per account**, set per
   application at registration. Not a venue constant, so not a hardcoded ceiling. Order
   reads are unthrottled; market data has no documented limit, which is recorded as
   unmeasured rather than unlimited.
5. **Sandbox** — none. Promised, not shipped, and no sandbox server in either spec.

Nothing above is measured against the live API. That is a deliberate limit, not an
omission: it needs a credential this repo must never hold, so per D7 this is tier-1
evidence and supports `:experimental`, never `:proven`.
