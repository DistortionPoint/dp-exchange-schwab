# What the specs actually say

Every value below is read out of `openapi/` or `documentation/` in this directory, with the
place it came from named. Nothing here is recalled, inferred, or filled in from a similar
venue. That distinction is the point: Gemini's published candle-width list turned out to
name three widths its API rejects, and only measurement caught it.

Captured 2026-08-28. The Market Data spec is dated `TraderApi-MDIS-03-21-2024(4).json`, the
trading spec `TraderApi-Prod_05-11-2024.yaml`; the trading documentation was last published
**2025-10-30**, the market-data documentation **2024-06-27**.

## 1. Candle widths — `GET /pricehistory`

From `components.parameters.QueryParamperiodtype`, `QueryParamperiod`,
`QueryParamfrequencytype`, `QueryParamfrequency`.

A candle is not one parameter here. It is a **(periodType, frequencyType, frequency)**
triple, and the legal combinations are constrained in both directions.

| `periodType` | legal `period` | default `period` | legal `frequencyType` | default `frequencyType` |
|---|---|---|---|---|
| `day` | 1, 2, 3, 4, 5, 10 | 10 | `minute` | `minute` |
| `month` | 1, 2, 3, 6 | 1 | `daily`, `weekly` | `weekly` |
| `year` | 1, 2, 3, 5, 10, 15, 20 | 1 | `daily`, `weekly`, `monthly` | `monthly` |
| `ytd` | 1 | 1 | `daily`, `weekly` | `weekly` |

| `frequencyType` | legal `frequency` |
|---|---|
| `minute` | 1, 5, 10, 15, 30 |
| `daily` | 1 |
| `weekly` | 1 |
| `monthly` | 1 |

`frequency` defaults to `1` in every case.

**So the venue's actual candle widths are eight**: 1m, 5m, 10m, 15m, 30m, 1d, 1w, 1M.

Two consequences the contract has to respect:

**A width is only reachable through a period that allows it.** The minute widths need
`periodType=day`, which caps the lookback at 10 days. Ten days of 1-minute candles is the
most this venue will serve, and no combination of the other parameters extends it. A
consumer asking for a year of 1-minute data cannot be served, and must be told so rather
than handed a coarser series — which is exactly the substitution this family refuses.

**`startDate`/`endDate` are epoch milliseconds** and both are optional; unset, `endDate`
defaults to *the previous business day's close*, not to now.

`Candle` carries `open`, `high`, `low`, `close`, `volume`, `datetime` (int64 epoch ms) and
`datetimeISO8601`. Volume is present, so unlike Robinhood this venue can populate it.

## 2. Order vocabulary — `components.schemas`

Read verbatim from `openapi/accounts-and-trading-production.openapi.json`.

**`orderType`** (what an order *has*) — `MARKET`, `LIMIT`, `STOP`, `STOP_LIMIT`,
`TRAILING_STOP`, `CABINET`, `NON_MARKETABLE`, `MARKET_ON_CLOSE`, `EXERCISE`,
`TRAILING_STOP_LIMIT`, `NET_DEBIT`, `NET_CREDIT`, `NET_ZERO`, `LIMIT_ON_CLOSE`, `UNKNOWN`.

**`orderTypeRequest`** (what you may *ask for*) — the same list **minus `UNKNOWN`**.

That is the whole difference between the two schemas, and it is worth stating because the
inventory guessed otherwise: the guess was that requested types resolve into other types.
They do not. `UNKNOWN` is a value an order can come back as and a value you cannot send —
a read-side escape hatch, not a resolution rule.

**`duration`** (time-in-force) — `DAY`, `GOOD_TILL_CANCEL`, `FILL_OR_KILL`,
`IMMEDIATE_OR_CANCEL`, `END_OF_WEEK`, `END_OF_MONTH`, `NEXT_END_OF_MONTH`, `UNKNOWN`.

**`session`** — `NORMAL`, `AM`, `PM`, `SEAMLESS`. This has no analogue anywhere else in the
family. Every crypto venue trades continuously; here an order carries *which trading
session it is for*, and it is a required part of an order rather than an option.

**`orderStrategyType`** — `SINGLE`, `CANCEL`, `RECALL`, `PAIR`, `FLATTEN`, `TWO_DAY_SWAP`,
`BLAST_ALL`, `OCO`, `TRIGGER`.

**`status`** — `AWAITING_PARENT_ORDER`, `AWAITING_CONDITION`, `AWAITING_STOP_CONDITION`,
`AWAITING_MANUAL_REVIEW`, `ACCEPTED`, `AWAITING_UR_OUT`, `PENDING_ACTIVATION`, `QUEUED`,
`WORKING`, `REJECTED`, `PENDING_CANCEL`, `CANCELED`, `PENDING_REPLACE`, `REPLACED`,
`FILLED`, `EXPIRED`, `NEW`, `AWAITING_RELEASE_TIME`, `PENDING_ACKNOWLEDGEMENT`,
`PENDING_RECALL`, `UNKNOWN`.

**`specialInstruction`** — `ALL_OR_NONE`, `DO_NOT_REDUCE`, `ALL_OR_NONE_DO_NOT_REDUCE`.
**`taxLotMethod`** — `FIFO`, `LIFO`, `HIGH_COST`, `LOW_COST`, `AVERAGE_COST`,
`SPECIFIC_LOT`, `LOSS_HARVESTER`.
**`requestedDestination`** — `INET`, `ECN_ARCA`, `CBOE`, `AMEX`, `PHLX`, `ISE`, `BOX`,
`NYSE`, `NASDAQ`, `BATS`, `C2`, `AUTO`.
**`stopType`** — `STANDARD`, `BID`, `ASK`, `LAST`, `MARK`.
**`stopPriceLinkBasis` / `priceLinkBasis`** — `MANUAL`, `BASE`, `TRIGGER`, `LAST`, `BID`,
`ASK`, `ASK_BID`, `MARK`, `AVERAGE`.
**`stopPriceLinkType` / `priceLinkType`** — `VALUE`, `PERCENT`, `TICK`.
**`amountIndicator`** — `DOLLARS`, `SHARES`, `ALL_SHARES`, `PERCENTAGE`, `UNKNOWN`.
**`settlementInstruction`** — `REGULAR`, `CASH`, `NEXT_DAY`, `UNKNOWN`.
**`complexOrderStrategyType`** — 21 members, all options structures (`VERTICAL`,
`IRON_CONDOR`, `CALENDAR`, …). Not relevant until options are.

### Mapping onto Core's vocabulary

Core's `@order_types` are `:market, :limit, :stop, :stop_limit, :post_only, :ioc, :fok` and
its `@time_in_force` are `:gtc, :ioc, :fok, :gtd, :day`. Schwab splits these differently:

- `:market` → `MARKET`, `:limit` → `LIMIT`, `:stop` → `STOP`, `:stop_limit` → `STOP_LIMIT`.
  Four of Core's seven map cleanly.
- **`:ioc` and `:fok` are not order types here** — they are `duration` values
  (`IMMEDIATE_OR_CANCEL`, `FILL_OR_KILL`). Declaring them under `supported_order_types`
  would be the same mistake already caught once on Gemini, where `:post_only` was declared
  as a time-in-force.
- **`:post_only` has no equivalent.** `NON_MARKETABLE` is close and is not the same thing.
  It does not go in the declaration.
- `:gtd` has no equivalent either. Schwab expresses dated expiry as
  `END_OF_WEEK`/`END_OF_MONTH`/`NEXT_END_OF_MONTH`, which are three fixed horizons, not an
  arbitrary date. `:gtd` is **absent**, not approximated.
- `TRAILING_STOP`, `TRAILING_STOP_LIMIT`, `MARKET_ON_CLOSE`, `LIMIT_ON_CLOSE` are real
  order types this venue supports that Core has no vocabulary for. They are a genuine
  contract gap, and the honest declaration lists only what Core can name.

## 3. Margin and buying power — `components.schemas`

`SecuritiesAccount` is a union: an account is either a **`MarginAccount`** or a
**`CashAccount`**, with different balance schemas. There is no single "leverage" number.

`MarginBalance` carries: `availableFunds`, `availableFundsNonMarginableTrade`,
`buyingPower`, `buyingPowerNonMarginableTrade`, `dayTradingBuyingPower`,
`dayTradingBuyingPowerCall`, `equity`, `equityPercentage`, `isInCall`, `longMarginValue`,
`maintenanceCall`, `maintenanceRequirement`, `marginBalance`, `optionBuyingPower`,
`regTCall`, `shortBalance`, `shortMarginValue`, `sma`, `stockBuyingPower`.

`CashBalance` carries none of those: `cashAvailableForTrading`,
`cashAvailableForWithdrawal`, `cashCall`, `cashDebitCallValue`,
`longNonMarginableMarketValue`, `totalCash`, `unsettledCash`.

**This settles the `max_leverage` question the design doc flagged.** A single scalar is the
wrong shape twice over. It is wrong because there are *five* different buying powers on a
margin account — overall, non-marginable, day-trading, option, stock — which are not
multiples of one another. And it is wrong because on a cash account every one of them is
simply absent, so any number reported would be invented. `regTCall` and `sma` are the
Reg-T-specific fields, and both are call/credit amounts rather than ratios.

The declaration should not carry `max_leverage` for this venue.

## 4. Rate limits — `documentation/accounts-and-trading-production.txt`

> Trader API applications (Individual and Commercial) are limited in the number of
> PUT/POST/DELETE order requests per minute per account based on the properties of the
> application specified during registration […] Throttle limits for orders can be set from
> zero (0) to 120 requests per minute per account. Get order requests are unthrottled.

Three things follow, and all three matter for the declaration:

**The ceiling is per-application and negotiated**, not a property of the venue. It is set
when the app is registered, anywhere in `0..120`. A hardcoded number in `capabilities/0`
would be a claim about *someone else's* app. It has to be configurable, with no default
that pretends to know.

**Zero is a legal value.** An app can be registered with no order throughput at all. A
declaration must be able to express that, and `:unsupported` is not the same as a ceiling
of zero — the endpoint exists, it is the app that cannot use it.

**It is per account, not per app or per key.** Every other venue in this family limits by
credential. Core's `ceiling` type has `limit`, `per_ms` and `burst` and no notion of a
per-account dimension. Recorded as a contract question.

Reads are unthrottled *for orders*. Nothing in either document states a limit for market
data, and no `429` appears anywhere in either spec. That is an absence, not a permission:
it is recorded as unmeasured.

## 5. Sandbox

> Apps may exist in either Sandbox (test data access) or the Production environment (live
> data access). […] **The Trader API Sandbox environments will be available later this
> year.**

— `documentation/accounts-and-trading-production.txt`, from a document published
2025-10-30.

The portal has a Sandbox concept for apps generally, and for *Trader API* it is promised
rather than delivered. Neither spec declares a sandbox server: `servers` is a single entry
in each, `https://api.schwabapi.com/marketdata/v1` and `https://api.schwabapi.com/trader/v1`.

**So: no sandbox.** Unlike Gemini, this venue cannot be exercised end-to-end without
touching real money, and the environment split that Gemini needed has nothing to point at
here. If Schwab ships one, the shape is already known from Gemini and can be added.

## 6. Authentication

`components.securitySchemes.oauth` in both specs: `type: oauth2`, `flows:
authorizationCode`. Three-legged, with a user redirect through Schwab's login site.

From `documentation/accounts-and-trading-production.txt`: the refresh token expires after
**7 days** or on password reset, after which the full flow must be restarted — the app
cannot renew itself past that.

This is the sharpest case in the family of the invariant that a host implements auth and
the package only signs. A seven-day refresh expiry that ends in a *browser redirect* cannot
live inside a library: something has to put a human in front of a login page. The package
receives tokens; it does not obtain them.

## 7. Market hours — `GET /markets`

`markets` takes one or more of `equity`, `option`, `bond`, `future`, `forex`, plus an
optional `date`. `Hours` returns `isOpen` (boolean), `sessionHours`, `marketType`,
`exchange`, `product`, `date`.

This is the first venue in the family that can answer `market_status/1` from the venue
rather than by assuming `:open`, and `isOpen` is a direct answer rather than something
derived from a schedule.

## 8. Instruments and movers

`GET /instruments` takes `projection` — `symbol-search`, `symbol-regex`, `desc-search`,
`desc-regex`, `search`, `fundamental`. There is **no "list everything" projection**: every
lookup is a search against a term. Task 7.4's catalogue stress test has to account for
that — the catalogue cannot be enumerated, only queried.

`GET /movers/{symbol_id}` takes `$DJI`, `$COMPX`, `$SPX`, `NYSE`, `NASDAQ`, `OTCBB`,
`INDEX_ALL`, `EQUITY_ALL`, `OPTION_ALL`, `OPTION_PUT`, `OPTION_CALL`; `sort` takes
`VOLUME`, `TRADES`, `PERCENT_CHANGE_UP`, `PERCENT_CHANGE_DOWN`.

## 9. Asset types

`AssetMainType` — `BOND`, `EQUITY`, `FOREX`, `FUTURE`, `FUTURE_OPTION`, `INDEX`,
`MUTUAL_FUND`, `OPTION`. Eight, with a separate quote schema for each of seven of them.

No crypto. Schwab publishes a separate **Crypto** API product (see
`portal-raw/find-products.json`); it is not part of Trader API – Individual and nothing
here describes it.

## Still unmeasured

Everything above is read from documentation. None of it has been probed against the live
API, because that needs a credential this repo must never hold. Per D7 that makes all of it
tier-1 evidence: good enough to declare `:experimental`, not good enough to declare
`:proven`.

The one live check that has been run is recorded in `endpoint-inventory.md`: an
unauthenticated `GET /marketdata/v1/quotes` returns `401`, which confirms the base URL and
path shape without a credential.

## 10. Order construction, from the Documentation tab's worked examples

The specs give the *enums*; the Documentation tab gives eleven complete order payloads,
which is what actually settles the shape. Read from
`documentation/accounts-and-trading-production.txt`.

### An order is a strategy with legs, not a flat record

Every example has the same skeleton:

```json
{ "orderType": "...", "session": "NORMAL", "duration": "DAY",
  "orderStrategyType": "SINGLE",
  "orderLegCollection": [
    { "instruction": "BUY", "quantity": 15,
      "instrument": { "symbol": "XYZ", "assetType": "EQUITY" } } ] }
```

`session` and `duration` are present on **every** example, including the simplest market
order. They are not optional decoration, and `session` has no slot in `Core.Venue` at all
(recorded at 7.5).

An instrument carries its **own `assetType`**. The symbol alone does not say what it is,
which matters because `SymbolFormat` can distinguish an option by its fixed width but a
consumer must still be told which it meant.

### `instruction` is constrained by asset type, and the venue publishes the matrix

| `instruction` | EQUITY | OPTION |
|---|---|---|
| `BUY` | accepted | **reject** |
| `SELL` | accepted | **reject** |
| `BUY_TO_COVER` | accepted | **reject** |
| `SELL_SHORT` | accepted | **reject** |
| `BUY_TO_OPEN` | **reject** | accepted |
| `BUY_TO_CLOSE` | **reject** | accepted |
| `SELL_TO_OPEN` | **reject** | accepted |
| `SELL_TO_CLOSE` | **reject** | accepted |

This is a *published* rejection table, which is rare and worth using. A package that
builds an order can refuse a mismatched pair locally instead of spending an order-rate
slot to be told no — and on this venue order writes are the throttled operation while
reads are free, so a locally-catchable rejection is worth catching.

Note it also confirms the short-selling declaration from the other direction:
`SELL_SHORT` and `BUY_TO_COVER` are equity-only.

### Only equities and options can be traded at all

> "Order entry will only be available for the assetType 'EQUIT' and 'OPTION as of this
> time."

(The truncation is the venue's own.) So although `assetType` admits eleven values and
market data covers seven quote shapes, **the tradable set is two**. A declaration listing
more would overstate what `place_order/3` can do.

### Multi-leg and conditional orders exist and the contract cannot express them

`orderStrategyType` `TRIGGER` and `OCO` nest whole orders inside
`childOrderStrategies`, and the vertical-spread example carries two legs at one net
price with `orderType: "NET_DEBIT"`. `Core.Venue`'s `place_order/3` takes a flat request
map — one symbol, one side, one quantity — so none of this is reachable through the
contract.

That is not a defect to fix here. It is the honest boundary: this package can place the
single-leg equity orders `Core` can describe, and the rest is a Core gap (7.5).

### `TRAILING_STOP` needs three fields Core has no name for

`stopPriceLinkBasis` (`BID`), `stopPriceLinkType` (`VALUE`), `stopPriceOffset` (`10`).
Already recorded at 7.5 as an order type with no Core atom; this is what implementing it
would additionally require.
