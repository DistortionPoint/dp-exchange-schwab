# Schwab Trader API — coverage matrix

**Source**: the two OpenAPI documents in `openapi/`, committed here. Enumerated
2026-08-31 against the paths `lib/` constructs. **REST counts re-verified 2026-09-03; the
Streamer section below was written when this package asserted a false negative about
streaming and is kept as the record of that, with what has since changed added below it.**

## Counts

| | operations | implemented |
|---|---|---|
| Market Data Production | 10 | 9 |
| Accounts and Trading Production | 13 | 11 |
| **total** | **23** | **20** |

**87%** of the two REST specifications, up from 52% at the original capture. What remains:
`GET /orders` (cross-account), `GET /accounts` (cross-account list; this package uses
`accountNumbers` + per-account fetch), `GET /instruments/{cusip_id}` (lookup by symbol
covers the common case). Options chains and expirations, and movers, now have facade
homes and are implemented — see `capabilities/0`.

## Matrix

```
✓ GET    /quotes
  GET    /{symbol_id}/quotes
  GET    /chains
  GET    /expirationchain
✓ GET    /pricehistory
  GET    /movers/{symbol_id}
✓ GET    /markets
  GET    /markets/{market_id}
✓ GET    /instruments
  GET    /instruments/{cusip_id}

✓ GET    /accounts/accountNumbers
  GET    /accounts
✓ GET    /accounts/{accountNumber}
✓ GET    /accounts/{accountNumber}/orders
✓ POST   /accounts/{accountNumber}/orders
✓ GET    /accounts/{accountNumber}/orders/{orderId}
✓ DELETE /accounts/{accountNumber}/orders/{orderId}
✓ PUT    /accounts/{accountNumber}/orders/{orderId}
✓ POST   /accounts/{accountNumber}/previewOrder
  GET    /orders
  GET    /accounts/{accountNumber}/transactions
  GET    /accounts/{accountNumber}/transactions/{transactionId}
  GET    /userPreference
```

## The eleven gaps, and what each costs

| endpoint | consequence of not having it |
|---|---|
| `GET /accounts/{n}/transactions` | **`get_trade_history/2` is `:unsupported`.** Fills live here; this is the only source of them |
| `GET /accounts/{n}/transactions/{id}` | single transaction |
| `GET /accounts` | a host with several accounts must loop `accountNumbers` and fetch each |
| `GET /orders` | orders across all accounts in one call; same looping cost |
| `GET /{symbol_id}/quotes` | single-symbol quote; `/quotes` covers it with a list of one |
| `GET /chains` | option chains — no facade home |
| `GET /expirationchain` | option expirations — no facade home |
| `GET /movers/{symbol_id}` | market movers — no facade home |
| `GET /markets/{market_id}` | one market's hours; `/markets` covers it |
| `GET /instruments/{cusip_id}` | lookup by CUSIP rather than by symbol |
| `GET /userPreference` | **the streamer bootstrap** — returns `streamerInfo` with `streamerSocketUrl`. Without it there is no WebSocket connection at all |

**Three are conveniences** the facade already covers by another route
(`/{symbol_id}/quotes`, `/markets/{market_id}`, and arguably `/accounts` and `/orders`).
**Three have no facade home** — chains, expirations, movers — and are normalisation
questions rather than implementation ones.

**The two that matter most are the transactions pair and `/userPreference`.** The first is
why this package cannot report a fill. The second is why it has no streaming.

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
