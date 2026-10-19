# Schwab Trader API — coverage matrix

**Source**: the two OpenAPI documents in `openapi/`, committed here. Enumerated
2026-08-31 against the paths `lib/` constructs. **REST counts re-verified 2026-09-06
against `lib/dp_exchange/schwab/rest.ex`. The Streamer section was rewritten to the code as
it stands (tick AM); its history is kept at the end as dated lines.**

## Counts

| | operations | implemented |
|---|---|---|
| Market Data Production | 10 | 10 |
| Accounts and Trading Production | 13 | 13 |
| **total** | **23** | **23** |

**100%** of the two REST specifications — 52% at the original capture, 87% on 2026-09-03.
Every operation in both documents has a path constructed and a response read in `Rest`.

**"Implemented" here means the operation is reached, not that a `Core.Venue` callback
returns its data in the contract's vocabulary.** Two are deliberately still `:unsupported`
on the facade and neither is an unreached endpoint:

- **`get_trade_history/2`** — `/transactions` is implemented and reached as
  `get_transactions/2`, which returns the venue's own shape. Mapping a Schwab transaction
  onto `Core.Types.Fill` needs a live response to check against, and this repository holds
  no credential.
- **`get_order_book/2`** — no REST operation in either document returns depth, so there is
  nothing for a request-response callback to read. Depth is a Streamer service, and this
  package does not subscribe it (see "The Streamer" below).

## Matrix

Every operation, with the facade entry point that reaches it.

```
✓ GET    /quotes                                        get_price/2, get_top_of_book/2
✓ GET    /{symbol_id}/quotes                            get_symbol_quote/3
✓ GET    /chains                                        get_option_chain/2
✓ GET    /expirationchain                               get_option_expirations/2
✓ GET    /pricehistory                                  get_historical_prices/4
✓ GET    /movers/{symbol_id}                            get_screener/2
✓ GET    /markets                                       market_status/1
✓ GET    /markets/{market_id}                           get_market/3
✓ GET    /instruments                                   get_symbols/1  (requires :query)
✓ GET    /instruments/{cusip_id}                        get_instrument/3

✓ GET    /accounts/accountNumbers                       get_accounts/2
✓ GET    /accounts                                      get_account_summaries/2, get_positions/1
✓ GET    /accounts/{accountNumber}                      get_balances/2
✓ GET    /accounts/{accountNumber}/orders               get_orders/2
✓ POST   /accounts/{accountNumber}/orders               place_order/3
✓ GET    /accounts/{accountNumber}/orders/{orderId}     get_order/3
✓ DELETE /accounts/{accountNumber}/orders/{orderId}     cancel_order/3
✓ PUT    /accounts/{accountNumber}/orders/{orderId}     replace_order/4
✓ POST   /accounts/{accountNumber}/previewOrder         preview_order/3
✓ GET    /orders                                        get_all_orders/2
✓ GET    /accounts/{accountNumber}/transactions         get_transactions/2
✓ GET    /accounts/{accountNumber}/transactions/{id}    get_transaction/4
✓ GET    /userPreference                                get_user_preference/2, and the
                                                        Streamer bootstrap in `Feed`
```

## Where two operations answer the same question differently

Nothing below is a gap. They are recorded because reaching for the wrong one of a pair
costs a request or an answer to a different question.

| pair | which to reach for |
|---|---|
| `/quotes` vs `/{symbol_id}/quotes` | `/quotes` takes a list and is what the facade and the fallback poll use. `get_symbol_quote/3` is the single-symbol form, returned unnormalised |
| `/accounts/accountNumbers` vs `/accounts` | the first returns the **encrypted hashes** every other account path is addressed by, and is the prerequisite call. The second returns balances, and positions when asked |
| `/markets` vs `/markets/{market_id}` | `market_status/1` reads every market at once. `get_market/3` asks about one, and about a **different day** — which `/markets` cannot answer |
| `/accounts/{n}/orders` vs `/orders` | per-account, versus across every account in one call. Both require a date window |

**`/userPreference` is the one whose absence would be structural.** It returns
`streamerInfo.streamerSocketUrl` and the four identifiers `LOGIN` requires; without it
there is no WebSocket connection at all, and `Feed` falls back to polling `/quotes` and
says so through `coverage/1`.

## The Streamer — 15 services documented, 3 kinds subscribed

Schwab publishes a WebSocket **Streamer** carrying market data and account activity,
documented in `documentation/market-data-production.txt`, not in the OpenAPI documents (the
Streamer is not REST, so it is absent from them by construction).

| service | what it streams | this package |
|---|---|---|
| `LEVELONE_EQUITIES`, `LEVELONE_EQUITY` | equity quotes | `LEVELONE_EQUITIES` subscribed; becomes `Quote` and `TopOfBook` |
| `LEVELONE_OPTIONS` | option quotes | subscribed for option symbols |
| `LEVELONE_FUTURES`, `LEVELONE_FUTURES_OPTIONS`, `LEVELONE_FOREX` | futures and FX quotes | field tables decoded; never subscribed (`SymbolFormat` refuses those symbols) |
| `NYSE_BOOK`, `NASDAQ_BOOK`, `OPTIONS_BOOK` | order-book depth | decoded; **never subscribed** |
| `CHART_EQUITY` | streaming candles | subscribed for non-option symbols |
| `CHART_FUTURES` | futures candles | field table decoded; never subscribed |
| `SCREENER_EQUITY`, `SCREENER_OPTION` | screener results | not subscribed |
| `ACCT_ACTIVITY` | order and fill events | decoded where documented; **never subscribed** |
| `ADMIN` | session administration | `LOGIN` and `LOGOUT` |

Commands used: `LOGIN`, `LOGOUT`, `SUBS`, `UNSUBS`, `ADD`, `VIEW`.

**What `capabilities().streamable` says now: `[:quotes, :top_of_book, :candles]`**, and
`authenticated_streamable` is the same list (there is no anonymous socket).
`:order_book`, `:orders`, `:fills` and `:trades` are not declared:

- `:order_book` would need a fact this package does not have: which book service
  (`NYSE_BOOK` or `NASDAQ_BOOK`) an equity symbol belongs on. The vendor documents no rule,
  and the options book's key format is undocumented.
- `:orders` and `:fills` would need the per-`message_type` schema of `ACCT_ACTIVITY`'s
  `message_data`, which the vendor says exists and does not publish.
- `:trades` is not declared because `LEVELONE_*` carries a last price restated on every
  update, not the sequence of prints.

**`get_order_book/2` is `:unsupported`.** The REST API publishes no depth, and depth does not
arrive by subscription either, because subscribing it honestly is not currently possible.
`Feed` bootstraps the Streamer through `GET /userPreference` and falls back to the REST poll,
reporting `:internal_poll` rather than `:stream`, when that bootstrap fails. The design note
is `docs/design/ideas/schwab-depth-and-account-activity-streaming.md`.

### History, kept as dated lines

- 2026-08-28: this package asserted "Schwab has no streaming API", and `get_order_book/2` was
  declared `:unsupported` because "no endpoint in either document returns depth". The first was
  false: the claim came from reading the OpenAPI documents and stopping there.
- 2026-09-01: the package started speaking the Streamer (`WebSockex` as the transport).
  `streamable` was widened to six kinds, and this file wrongly said the book services were
  "decoded and delivered".
- 2026-09-06: a documentation-accuracy sweep read `Feed.services_for/1` against
  `capabilities().streamable` and found that nothing subscribed `NYSE_BOOK`, `NASDAQ_BOOK`,
  `OPTIONS_BOOK` or `ACCT_ACTIVITY`. `streamable` was narrowed to `[:quotes, :top_of_book,
  :candles]` (`:candles` newly wired, since `CHART_EQUITY` and `LEVELONE_EQUITIES` share the
  "Equities symbols in upper case" key format).

Two lessons carry forward. A capability audit that reads only the machine-readable
specification misses a transport the vendor chose not to put in one. And one that checks
decoder coverage instead of the subscribe call graph finds the same gap from the other side:
a service the code can turn into a value is not a service the code ever asks the venue for.
