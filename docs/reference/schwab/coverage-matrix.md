# Schwab Trader API — coverage matrix

**Source**: the two OpenAPI documents in `openapi/`, committed here. Enumerated
2026-08-31 against the paths `lib/` constructs. **REST counts re-verified 2026-09-06
against `lib/dp_exchange/schwab/rest.ex`; the Streamer section below was written when this
package asserted a false negative about streaming and is kept as the record of that, with
what has since changed added below it.**

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
  nothing for a request-response callback to read. Depth is a Streamer service.

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

## The Streamer — 15 services, and now the socket speaks them

**This package asserts that Schwab has no streaming API. That is false**, and the evidence
is in `documentation/market-data-production.txt`, captured 2026-08-28 and committed here.

Schwab publishes a WebSocket **Streamer** carrying market data *and* account activity:

| service | what it streams |
|---|---|
| `LEVELONE_EQUITIES`, `LEVELONE_EQUITY` | equity quotes |
| `LEVELONE_OPTIONS` | option quotes |
| `LEVELONE_FUTURES`, `LEVELONE_FUTURES_OPTIONS` | futures quotes |
| `LEVELONE_FOREX` | FX quotes |
| **`NYSE_BOOK`, `NASDAQ_BOOK`, `OPTIONS_BOOK`** | **order-book depth** |
| `CHART_EQUITY`, `CHART_FUTURES` | streaming candles |
| `SCREENER_EQUITY`, `SCREENER_OPTION` | screener results |
| **`ACCT_ACTIVITY`** | **order and fill events** |
| `ADMIN` | session administration |

Commands: `LOGIN`, `LOGOUT`, `SUBS`, `UNSUBS`, `ADD`, `VIEW`.

### What this package gets wrong as a result

**`get_order_book/2` is declared `:unsupported`** on the recorded grounds that *"no
endpoint in either document returns depth"*. True of the REST API; false of the venue.
Three book services carry depth.

**`mix.exs` says "No `websockex`. This venue has no streaming API at all"**, and `Feed`'s
moduledoc says neither specification describes a streaming surface. The specifications do
not — because the streamer is not REST. The prose documentation beside them describes it in
detail.

**`streamable` is `[:quotes]` by poll.** With `ACCT_ACTIVITY` it could be
`[:quotes, :order_book, :orders, :fills]` — a claim no venue in this family currently makes.

The error was reading the OpenAPI documents and stopping there.

## What was wrong, and what it now reads

The three paragraphs above are the original finding, kept verbatim as the record of the
defect. As of this release, all three are corrected:

- **`mix.exs` no longer says "no streaming API at all"** and does not name `websockex`
  because it is not the transport — `WebSockex` is, and it is now a declared dependency.
- **`get_order_book/2` is still `:unsupported`, and the reason is now narrow and true**:
  the REST API publishes no depth. Depth arrives by subscription — `NYSE_BOOK`,
  `NASDAQ_BOOK` and `OPTIONS_BOOK` are decoded and delivered.
- **`streamable` is `[:quotes, :top_of_book, :order_book, :candles, :orders, :fills]`.**
  `Feed` bootstraps the Streamer through `GET /userPreference` and falls back to the REST
  poll — reporting `:internal_poll` rather than `:stream` — only when that bootstrap fails.

The lesson this section exists to carry forward: **the error was reading the OpenAPI
documents and stopping there.** Neither document claims to describe the whole venue: the
Streamer is documented in the prose beside them. A capability audit that reads only the
machine-readable specification will miss a transport that vendor chose not to put in one.

## A second correction (2026-09-06): decoded is not delivered

The paragraph above — "Depth arrives by subscription — `NYSE_BOOK`, `NASDAQ_BOOK` and
`OPTIONS_BOOK` are decoded and delivered" — was itself wrong, in the direction opposite
the original finding. **Decoded, yes; delivered, no.** `StreamerDecode.to_order_book/2`
and `Socket.decode/4`'s book-frame clause were real and tested, but nothing in `Feed` ever
*subscribed* `NYSE_BOOK`, `NASDAQ_BOOK`, `OPTIONS_BOOK` or `ACCT_ACTIVITY` — a consumer
calling `subscribe/2` and asking for `:order_book`, `:orders` or `:fills` got the
declaration and permanent silence. A documentation-accuracy sweep found the gap by reading
`Feed.services_for/1` (then `service_for/1`) against `capabilities().streamable` rather
than against `StreamerDecode`'s decoder coverage, which is what the first correction had
checked instead.

**What is genuinely true as of this correction:**

- **`streamable` is `[:quotes, :top_of_book, :candles]`.** `:candles` is newly wired —
  `services_for/1` sends every non-option symbol to `CHART_EQUITY` as well as
  `LEVELONE_EQUITIES`, and the two services share the identical "Equities symbols in upper
  case" key format, so nothing about that routing is a guess.
- **`:order_book` and `:orders`/`:fills` are not declared, and wiring either would need a
  fact this package does not have**: which book service (`NYSE_BOOK` vs `NASDAQ_BOOK`) an
  equity symbol belongs on — the vendor documents no rule — and the per-`message_type`
  schema of `ACCT_ACTIVITY`'s `message_data`, which the vendor states exists and does not
  publish. See `docs/design/ideas/schwab-depth-and-account-activity-streaming.md`.
- **`get_order_book/2` stays `:unsupported`, for a reason now narrower than either prior
  one**: the REST API publishes no depth, and depth does not arrive by subscription either,
  because subscribing it honestly is not currently possible.

The lesson this correction adds to the one above: **a capability audit that checks decoder
coverage instead of the subscribe call graph will find the same kind of gap from the other
side** — a service the code can turn into a value is not the same fact as a service the
code ever asks the venue for.
