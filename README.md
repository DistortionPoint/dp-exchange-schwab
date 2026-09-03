# DpExchangeSchwab

**EXPERIMENTAL.** Charles Schwab's Trader API behind the shared `DpExchange.Core.Venue`
facade.

Part of the **DpExchange** family: every venue package exposes the same facade, returns the
same `Core.Types.*` values, and hides its own transport. A consumer cannot tell from the
facade how data reaches the package, and must not be able to.

```elixir
def deps do
  [{:dp_exchange_schwab, "~> 0.1.0"}]
end
```

## Status

Nothing here has run against the live API, and on this venue that is **structural rather
than temporary**:

- Every endpoint requires OAuth credentials this repository must never hold.
- **Schwab publishes no sandbox.** Its own documentation says Trader API sandboxes "will be
  available later this year", and neither specification declares a non-production server.

So there is nowhere to exercise this package that is not somebody's real money. Every
endpoint is declared `:experimental` and none can become `:proven` here — that happens when
a consumer trades live. See `capabilities/0`; maturity is per endpoint, not per package.

The declaration was derived from Schwab's two OpenAPI documents **before** any provider code
was written. Both are committed under `docs/reference/schwab/`, because the portal returns
`403` to an anonymous reader and publishes no spec anywhere — this reference cannot be
re-fetched, so it travels with the code.

## What is different about this venue

**A symbol is one instrument, not a pair.** Every other venue in the family addresses
`BASE-QUOTE`. Here `AAPL` names a single security. `SymbolFormat.validate/1` *refuses*
pair-shaped input rather than splitting it: `BTC`, `ETH` and `SOL` are all real listed
equity tickers, so a misrouted crypto pair has a plausible wrong answer waiting — an ETF
holding nothing like the coin, quoted in dollars, indistinguishable downstream from a real
price.

**The market closes.** `market_status/1` is answered from `/markets`, never assumed. A feed
delivering nothing at 3am is correct, and a consumer that alarms on silence would alarm
every night — making a real outage indistinguishable from a Saturday.

**This package speaks the Streamer.** Schwab publishes a WebSocket **Streamer** with 15
services — `LEVELONE_*` for quotes and top of book, `NYSE_BOOK`, `NASDAQ_BOOK` and
`OPTIONS_BOOK` for depth, `CHART_*` for candles, and `ACCT_ACTIVITY` for order and fill
events. It is documented in the prose beside the OpenAPI specifications, not in them, which
is how this README once claimed the venue had no socket at all.

`subscribe/2` bootstraps it through `GET /userPreference` and `coverage/1` reports
`:stream`. **Where that bootstrap fails — no token, an expired one, a response without
`streamerInfo` — the feed polls instead, emits `:degraded`, and reports `:internal_poll` for
every symbol.** The route is always visible; nothing claims to be a stream that is not one.

`get_order_book/2` remains `:unsupported`, and the reason is now narrow and true: **the REST
API publishes no depth.** Depth on this venue arrives by subscription.

**The catalogue cannot be enumerated.** `/instruments` has no list-everything projection —
every lookup is a search. `get_symbols/1` therefore requires a `:query` and returns
`{:error, {:query_required, :schwab}}` without one. That is deliberately *not*
`:not_supported`: the endpoint works, the caller has to say what it wants.

**It can preview and replace, and nothing else in the family can.** `previewOrder`
validates an order and estimates its cost without placing it; `PUT .../orders/{id}` amends
atomically. Both matter more here than they would elsewhere: order writes are throttled to
`0..120` a minute per account and reads are not, so previewing a rejection is free while
placing one is not — and cancel-then-place spends two writes *and* opens a window in which
no order is live.

## Authentication

The host authenticates. This package signs, and refreshes.

The initial grant is three-legged OAuth: a browser, a person, and a redirect through
Schwab's login site. No library can do that. Everything after is mechanical, and per §6.0
credential *use* — signing, session refresh, token rotation — belongs here.

| | Lifetime | Renewed by |
|---|---|---|
| `access_token` | 30 minutes | `Auth.refresh/2` |
| `refresh_token` | 7 days from its own creation | `Auth.refresh/2` — every call mints a new one, and the seven days restart |

**The refresh token is one-time use.** A refresh spends the token it was given and returns
its replacement. So there is no weekly ceiling on unattended operation: a host refreshing
every half hour rolls the window forward every half hour and never needs a person again.

**Persist the result of every refresh before using it.** Losing the returned token costs the
grant, and recovering costs a person at a browser. `refresh/2` is never retried internally —
it is at-most-once, because a retry after a timeout re-sends a token that may already have
been spent.

```elixir
credentials = %{
  access_token: "…",
  refresh_token: "…",
  client_id: "…",
  client_secret: "…"
}

{:ok, quote} = DpExchange.Schwab.get_price("AAPL", credentials: credentials)
```

## Supervision

A library does not start itself. Supervise it:

```elixir
children = [
  {DpExchange.Schwab, symbols: ["AAPL", "MSFT"], credentials: credentials}
]
```

The order ceiling is **not** declared in `capabilities/0`, because Schwab has none to
declare: the documented limit is `0..120` order writes per minute *per account*, set *per
application at registration*. Pass `:order_limit_per_minute` matching your own app's
registration.

## Testing against it

`DpExchange.Schwab.Fake` is an in-process stand-in that **refuses what the real venue
refuses** — a pair-shaped symbol, a missing credential, a year of one-minute candles, an
instruction that does not match the asset type. It is also the only place in the family
where the closed-market path can be exercised:

```elixir
DpExchange.Schwab.Fake.market_status(credentials: creds, market_status: :closed)
```

## Licence

MIT.
