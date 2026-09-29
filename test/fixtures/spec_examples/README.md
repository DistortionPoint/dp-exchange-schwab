# Spec-example fixtures

Every file here is either the vendor's own documented example, transcribed verbatim (or as
a genuine subset of one that is too large to keep whole), or — where the vendor publishes
no example for that shape — an instance built **strictly from the schema's own properties
and JSON types**, marked `_schema` in its filename so it is never mistaken for a worked
example. Nothing here was invented by looking at what the code already does; every value
traces to one of the two committed vendor documents:

- `docs/reference/schwab/openapi/market-data-production.openapi.json` (cited `MD:<line>`)
- `docs/reference/schwab/openapi/accounts-and-trading-production.openapi.json` (cited `AT:<line>`)
- `docs/reference/schwab/documentation/market-data-production.txt` (cited `market-data-production.txt:<line>`)
- `docs/reference/schwab/documentation/accounts-and-trading-production.txt` (cited `accounts-and-trading-production.txt:<line>`)

Line numbers are from the committed files as of this sweep (2026-09-29) and may drift if
those files are ever re-captured; `script/check_doc_sources.sh` (see the package's own
`spec-facts.md`) is what re-verifies them against a fresh capture.

## market_data/

| File | Source | Citation |
|---|---|---|
| `quotes_multi_criteria_search.json` | `components.examples.MultiCriteriaSearch`, the `AAPL` (equity) and `AAAIX` (mutual fund) entries only — a genuine subset of a 15.5KB multi-symbol example, kept to the two shapes `get_price/3`/`get_top_of_book/3` actually branch on | MD:1038 (component), MD:88 (referenced from `GET /quotes`'s `200` response) |
| `price_history_single_symbol.json` | `components.examples.SingleSymbolCriteriaSearch`, in full | MD:856 (component), MD:345 (referenced from `GET /pricehistory`'s `200` response) |
| `market_hours_single.json` | `components.examples.GetMarketHour`, in full | MD:723 (component), MD:516 (referenced from `GET /markets/{market_id}`'s `200` response) |
| `market_hours_all.json` | `components.examples.GetMarketHours`, in full | MD:759 (component), MD:461 (referenced from `GET /markets`'s `200` response) |
| `instruments_search.json` | `components.examples.GetInstruments`, in full | MD:692 (component), MD:576 (referenced from `GET /instruments`'s `200` response) |
| `instrument_by_cusip.json` | `components.examples.GetInstrumentByCusip`, in full | MD:713 (component), MD:636 (referenced from `GET /instruments/{cusip_id}`'s `200` response) |
| `movers_index.json` | `components.examples.SearchMoversByIndexSymbol`, in full | MD:825 (component), MD:403 (referenced from `GET /movers/{symbol_id}`'s `200` response) |
| `expiration_chain.json` | `components.examples.GetExpirationChain`, in full — every row spells the date field `expirationDate`, which is `Rest.expiration_date/1`'s fallback clause, not its schema-named `expiration` clause; see the note below | MD:923 (component), MD:277 (referenced from `GET /expirationchain`'s `200` response) |
| `option_chain_schema.json` | **Schema-derived.** `GET /chains` publishes no example at all (`op.responses["200"].content["application/json"]` has a `schema` key and no `example`/`examples`). Built from `OptionChain` (`underlyingPrice`, `callExpDateMap`/`putExpDateMap` as `number`/`object`), `OptionContractMap` and `OptionContract` (`isMini`, `isNonStandard`, `isIndexOption` as `boolean`; `strikePrice`, `multiplier` as `number`; `expirationDate`, `settlementType`, `expirationType`, `symbol` as `string`). One call and one put at the same expiry/strike, with different `isMini`/`isNonStandard` so both fields are provably read per side rather than copied from one. The `"2026-03-20:15"` outer key (expiry date + `:` + the venue's own days-to-expiration) is not constrained by the schema itself — `callExpDateMap`/`putExpDateMap` are typed `additionalProperties`, no key pattern — so that shape is carried from `Rest.chain_expiry/1`'s own comment, itself sourced from `OptionContract` | MD:5120 (`OptionChain`), MD:5189 (`OptionContractMap`), MD:5315 (`OptionContract`) |

`get_symbol_quote/3` (`GET /{symbol_id}/quotes`) is not a separate fixture: the vendor's
own document points that endpoint's `200` example at `SingleCriteriaSearch`, which is a
`$ref` to the *same* `SingleSymbolCriteriaSearch` component `price_history_single_symbol.json`
already holds (MD:345, `paths./{symbol_id}/quotes.get.responses.200.content.application/json.examples.SingleCriteriaSearch`)
— a price-history shape under a quote endpoint, which reads as a vendor copy-paste rather
than a real quote response. Recorded as an observed inconsistency rather than "fixed":
`Rest.get_symbol_quote/3` never decodes this body, it returns it unnormalised (see its own
`@doc`), so the mismatch has nowhere to surface as a code defect — the spec-example test
pins the pass-through and the request shape, and reuses `price_history_single_symbol.json`
rather than inventing a second, contradicting "real" quote fixture for an endpoint this
package does not interpret.

## accounts_and_trading/

The Accounts and Trading OpenAPI document publishes **no examples anywhere** — every
`responses.200`/`201` and every `requestBody` was checked programmatically
(`Object.values(...).some(ct => ct.example || ct.examples)` over every path/method) and
none carry one. Every fixture in this directory except the two order-placement requests is
therefore `_schema`-suffixed and built strictly from the schema's own properties and JSON
types; nothing is a live-measured value, and none is claimed to be.

| File | Source | Citation |
|---|---|---|
| `account_numbers_schema.json` | **Schema-derived.** `AccountNumberHash[]` — `accountNumber`/`hashValue` both `string` | AT:1119 |
| `account_margin_schema.json` | **Schema-derived.** `Account` wrapping a `MarginAccount` (`type: MARGIN`), two `Position`s (one long, one short) whose `instrument` is `AccountEquity`, and `currentBalances` as `MarginBalance` | AT:1714 (`Account`), AT:2296 (`SecuritiesAccountBase`), AT:2336 (`MarginAccount`), AT:2491 (`MarginBalance`), AT:2123 (`Position`) |
| `account_cash_schema.json` | **Schema-derived.** `Account` wrapping a `CashAccount` (`type: CASH`) with one position at `longQuantity`/`shortQuantity` both `0` — a closed position the venue still lists — and `currentBalances` as `CashBalance` | AT:2572 (`CashAccount`), AT:2667 (`CashBalance`) |
| `account_summaries_schema.json` | **Schema-derived.** `[MarginAccount, CashAccount]`, the shape `GET /accounts` (plural, unlike `GET /accounts/{accountNumber}`) documents — an array of `Account` | AT:1714 |
| `order_filled_schema.json` | **Schema-derived.** One `Order`, `status: FILLED`, single-leg `orderLegCollection` of `OrderLegCollection`/`AccountEquity` | AT:1731 (`Order`), AT:2221 (`OrderLegCollection`) |
| `orders_window_schema.json` | **Schema-derived.** `[Order, Order]` — the first `FILLED`, the second `WORKING` with `filledQuantity > 0`, matching `orders`'s own `array of Order` response shape for both `GET /orders` and `GET /accounts/{accountNumber}/orders` | AT:1731 |
| `place_order_request_buy_market_stock.json` | **Vendor's own worked example**, verbatim — "Buy Market: Stock" | `accounts-and-trading-production.txt:160` |
| `replace_order_request_buy_limit_option.json` | **Vendor's own worked example**, verbatim — "Buy Limit: Single Option". `complexOrderStrategyType` is part of the vendor's example but has no `Core` request field, so `Orders.build/2` never emits it — see the test for why that is not treated as a mismatch | `accounts-and-trading-production.txt:179` |
| `preview_order_response_schema.json` | **Schema-derived.** `PreviewOrder` wrapping `OrderStrategy` (`orderLegs` of `OrderLeg`, flat `assetType`/`finalSymbol`, no nested `instrument` — the shape `Orders.to_preview/1`'s own moduledoc already cites), `OrderValidationResult`, `CommissionAndFee` | AT:2037 (`PreviewOrder`), AT:1372 (`OrderStrategy`), AT:1471 (`OrderLeg`) |
| `transaction_schema.json` | **Schema-derived.** `[Transaction]` — both `GET /accounts/{accountNumber}/transactions` and `.../transactions/{transactionId}` document `type: array` of `Transaction`, never a bare object | AT:3398 (`Transaction`), AT:3526 (`TransferItem`) |
| `user_preference_schema.json` | **Schema-derived.** One `UserPreference` object (`accounts`, `streamerInfo`, `offers`) — used both for `Rest.get_user_preference/2`'s own passthrough and, unmodified, to prove `StreamerInfo.from_user_preference/1` bootstraps from the exact same body | AT:3579 (`UserPreference`), AT:3602 (`UserPreferenceAccount`), AT:3631 (`StreamerInfo`) |

The `201`/empty-body-plus-`Location`-header shape `place_order/4` and `replace_order/5`
decode is documented directly on the operation, not as a JSON example: `POST
/accounts/{accountNumber}/orders`'s `201` response is `"description": "Empty response body
if an order was successfully placed/created."` with a `Location` header described as "Link
to the newly created order if order was successfully created." (AT:330-345, and identically
at AT:530-545 for `PUT .../orders/{orderId}`). The spec-example tests build that response
with `Plug.Conn.put_resp_header/3` and an empty body rather than a fixture file, since there
is no JSON to commit.

## streamer/

The Streamer has no OpenAPI document — `docs/reference/schwab/documentation/market-data-production.txt`
is prose with numbered field tables, which is the closest thing it has to a schema. Citations
below are to that file.

| File | Source | Citation |
|---|---|---|
| `level_one_equities_data_frame.json` | **Vendor's own worked example**, verbatim — "LEVELONE_EQUITIES Response Example" (SCHW/AAPL/SPY). Carries no fields `34`/`35`, so all three rows decode with `venue_time: nil` | `market-data-production.txt:452` |
| `level_one_equities_venue_time_schema.json` | **Schema-derived**, from the authoritative `LEVELONE_EQUITIES` Response Field Definitions table (fields `0`-`13`, `34`, `35`) — **deliberately not** the generic frame at `market-data-production.txt:112`, whose own fields `34`/`35` (`149.81`, `1668715930570`) are shifted one position out of step with this table (its field `34` reads as this table's field `33`, "Mark Price", a `double`, not "Quote Time in Long", a `long`) and would decode a garbage 1970 timestamp if used for this purpose. `StreamerFields`'s own `"34" => :quote_time` comment already cites the field-table location, not the shifted example, so this fixture follows the same choice rather than the vendor's inconsistent one; the inconsistency itself is recorded here rather than silently worked around | `market-data-production.txt:663-673` (table), `market-data-production.txt:112` (the contradicting generic example, not used) |
| `level_one_options_frame_schema.json` | **Schema-derived**, fields `0`-`12`, `16`-`18` | `market-data-production.txt:811` |
| `level_one_futures_frame_schema.json` | **Schema-derived**, fields `0`-`12`. Field `6`/`7` (`bid_id`/`ask_id`) are swapped relative to `LEVELONE_EQUITIES`, per `StreamerFields`'s own comment | `market-data-production.txt:1280` |
| `level_one_forex_frame_schema.json` | **Schema-derived**, fields `0`-`7`. No venue timestamp is named for this service in the fields this package reads | `market-data-production.txt:1930` |
| `chart_equity_frame_schema.json` | **Schema-derived**, fields `0`-`8` | `market-data-production.txt:2274` |
| `chart_futures_frame_schema.json` | **Schema-derived**, fields `0`-`6`. Field `1` is `chart_time` here and field `2` is `open` — the numbering `CHART_EQUITY` does not share, which is the historical defect `StreamerFields`'s own moduledoc records | `market-data-production.txt:2389` |
| `nyse_book_frame_schema.json` | **Schema-derived**, fields `0`-`3`, shared by `NYSE_BOOK`/`NASDAQ_BOOK`/`OPTIONS_BOOK`. Each level is `[price, aggregate_size, market_maker_count, market_makers]`; the first bid level's `aggregate_size` (`550`) is deliberately **not** the sum of its market makers' own sizes (`300 + 200 = 500`), so the test can tell "the venue's own aggregate was kept" from "the makers were summed" | `market-data-production.txt:2163` |
| `screener_equity_frame_schema.json` | **Schema-derived**, fields `0`-`4`, shared by `SCREENER_EQUITY`/`SCREENER_OPTION`. Renamed only — the package has no `Core` value type for a screener frame yet (`Socket`'s own comment: "ACCT_ACTIVITY and the screeners have field maps but no value type in this contract yet") | `market-data-production.txt:2498` |
| `acct_activity_frame_schema.json` | **Schema-derived**. Keyed on `"seq"`/`"key"` for two of its four fields, per the vendor and per `StreamerFields`'s own comment. Renamed only, for the same reason as the screener | `market-data-production.txt:2626` |
