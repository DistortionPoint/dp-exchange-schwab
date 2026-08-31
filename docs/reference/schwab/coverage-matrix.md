# Schwab Trader API — coverage matrix

**Source**: the two OpenAPI documents in `openapi/`, committed here. Enumerated
2026-08-31 against the paths `lib/` constructs.

## Counts

| | operations | implemented |
|---|---|---|
| Market Data Production | 10 | 4 |
| Accounts and Trading Production | 13 | 8 |
| **total** | **23** | **12** |

The best-covered venue in the family at **52%**, and the only one whose specification is
committed — which is not a coincidence. It is the only venue that had no host adapter to
port, so its documentation had to be read.

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

## The Streamer — 15 services, none implemented

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
