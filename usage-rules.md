# Using `dp_exchange_schwab`

Rules for an agent or developer writing code against this package. Read this before the
README; it is what the Hex tarball ships for consumers.

## 1. This package is EXPERIMENTAL and cannot be proven here

Nothing in it has run against the live API. Every endpoint needs OAuth credentials this
repository must never hold, and **Schwab publishes no sandbox** — its documentation promises
Trader API sandboxes "later this year" and neither specification declares a non-production
server. There is nowhere to exercise this that is not real money.

Check `DpExchange.Schwab.capabilities().endpoints` before calling anything. Maturity is per
endpoint.

## 2. Credentials are arguments, never configuration

Pass them per call. This package never reads a vault, never caches a token, and never logs
one.

```elixir
credentials = %{access_token: "…", refresh_token: "…", client_id: "…", client_secret: "…"}
```

`:access_token` alone is enough to sign. The rest are needed to refresh.

**There is no anonymous surface — market data included.** A call without a token is refused
locally with `{:error, {:missing_credentials, :schwab}}` rather than being sent.

## 3. Refresh, and persist what you get back

The access token lives **30 minutes**. `DpExchange.Schwab.Auth.refresh/2` renews it.

**The refresh token is one-time use.** Every refresh spends the old one and returns a new one
carrying a fresh seven days. So:

- **Persist the returned credential before using it.** Refreshing and then crashing before
  storing costs the grant, and only a person at a browser can restore it.
- **Do not retry a refresh.** The package will not, deliberately. If a refresh times out, the
  token may already have been spent; try again with the credential you still hold, not the
  one you just sent.
- `{:refused, {:reauthorization_required, _status, _detail}}` is **terminal**. Seven days
  elapsed with no refresh, or the user reset their password. Send a person to the login
  page; do not retry.

Refreshing at least once a week means never needing a person again.

## 4. A symbol is one instrument, not a pair

`"AAPL"`, not `"AAPL-USD"`. Pair-shaped input is refused, and this matters more than it
looks: `BTC`, `ETH` and `SOL` are real listed equity tickers, so a crypto pair routed here
by mistake has a plausible wrong answer available.

Option symbols are fixed-width and positional — `"XYZ   240315C00500000"`. The padding is
part of the format; do not trim it.

## 5. Candles: eight widths, and a hard lookback cap

`1m 5m 10m 15m 30m 1d 1w 1M`.

**Minute widths reach at most ten days back.** A longer range returns
`{:error, {:lookback_exceeds_venue, timeframe, requested_days, max_days}}`. It is not
truncated and not downgraded to a coarser width — handle the error; do not assume a series.

An unsupported width returns `{:error, {:unsupported_timeframe, width}}`.

## 6. Account calls need a hash, not an account number

`get_accounts/2` returns `%{account_number: …, hash: …}`. **Every other account path takes
the hash**, passed as `:account_hash`. Nothing is defaulted — placing an order against a
silently-chosen account is not something this package will do for you.

```elixir
{:ok, [account]} = DpExchange.Schwab.get_accounts(credentials)
DpExchange.Schwab.get_balances(credentials, account_hash: account.hash)
```

## 7. Orders: only what Core can name

Order types: `:market`, `:limit`, `:stop`, `:stop_limit`, `:trailing_stop`,
`:trailing_stop_limit`, `:market_on_close`, `:limit_on_close` — eight, not four; see §7b
for the four Schwab-specific ones and what a trailing stop needs. Time in force: `:day`,
`:gtc`, `:fok`, `:ioc`.

- **`:ioc` and `:fok` are time-in-force here, not order types.** Schwab spells them as
  `duration`.
- **`:post_only` and `:gtd` do not exist on this venue** and are refused rather than mapped
  to something near. Schwab's dated expiries are three fixed horizons, not an arbitrary date.
- Multi-leg spreads and `OCO`/`TRIGGER` orders are not reachable either — `place_order/3`
  takes a flat request.

Schwab publishes which instructions each asset type accepts, and this package enforces it
**before sending**: `BUY`/`SELL`/`SELL_SHORT`/`BUY_TO_COVER` are equity-only, and the
`_TO_OPEN`/`_TO_CLOSE` forms are option-only. Order writes are throttled and reads are not,
so a locally-catchable rejection is worth catching.

## 7a. Preview before you place, and replace rather than cancel

Two things this venue can do that no other in the family can. Both are declared —
`supports_order_preview` and `supports_order_replace` — so you can branch on capability
rather than on venue name.

```elixir
{:ok, preview} = DpExchange.Schwab.preview_order(credentials, request, account_hash: hash)
```

**Preview is close to free and placing is not.** Order writes are throttled here to
somewhere between 0 and 120 a minute per account; reads are unthrottled. A rejection found
by previewing costs nothing. One found by placing costs a scarce write.

```elixir
{:ok, new_id} = DpExchange.Schwab.replace_order(credentials, old_id, request, account_hash: hash)
```

**`replace_order/4` returns a NEW id.** Schwab treats a replacement as a new order, so the
id you passed in is dead afterwards — keep the one you get back, or you will be tracking an
order that no longer exists.

Use it instead of cancel-then-place wherever you can. The two are **not equivalent**:
cancel-then-place leaves a window with no order live, and spends two throttled writes
rather than one.

## 7b. Sessions, and the order types Core learned here

Every order carries a `session` — `NORMAL` unless you say otherwise. Pass `:session` in
the request or `session:` in options. `supported_sessions` lists what the venue takes;
this is the only venue in the family where the field is non-empty, because it is the only
one whose market closes.

Eight order types, not four: `:market`, `:limit`, `:stop`, `:stop_limit`,
`:trailing_stop`, `:trailing_stop_limit`, `:market_on_close`, `:limit_on_close`.

A trailing stop **requires `:stop_price_offset`** and is refused locally without one — the
offset is the order. `:stop_price_link_basis` (`"BID"`) and `:stop_price_link_type`
(`"VALUE"`, `"PERCENT"`, `"TICK"`) ride along under the venue's own names, because `Core`
names none of the three.

## 8. The market closes, and silence is usually correct

Call `market_status/1` before concluding a quiet feed is broken. This is the only venue in
the family where delivering nothing is the normal overnight state.

`coverage/1` reports what has **arrived**, not what was subscribed. An empty map at 3am is
not a fault.

## 9. The Streamer, and what arrives only there

**This package speaks the WebSocket Streamer as of 2026-09-01.** Fifteen services, and the
four kinds a consumer subscribes to are quotes, top of book, **depth** and candles; with a
credential — which is every call here — order and fill events arrive too.

```elixir
DpExchange.Schwab.capabilities().streamable
# [:quotes, :top_of_book, :order_book, :candles, :orders, :fills]
```

**Depth arrives on the socket and nowhere else.** `get_order_book/2` still returns
`{:error, :not_supported}`, and that is now a narrow and accurate claim: there is no
*request-response* order book, and the contract's callback is a read. Subscribe instead.

**`:trades` is deliberately not in that list.** `LEVELONE_*` carries a *last* price — one
print restated on every update, not the sequence of them. If you need a tape, this venue
does not publish one, and reconstructing it from `last` skips prints.

**Field numbers differ per service, and that is the trap.** Field 1 is `bid` on
`LEVELONE_EQUITIES` and `description` on `LEVELONE_OPTIONS`; fields 6 and 7 are
`ask_id`/`bid_id` on equities and `bid_id`/`ask_id` on futures — swapped, per the vendor.
`DpExchange.Schwab.StreamerFields` holds the per-service maps; do not reuse one service's
numbering for another.

**`SUBS` replaces and `ADD` accumulates.** There is no default: pass the command you mean.
A `SUBS` sent to extend a subscription silently drops everything not in it.

## 10. Reference data, options and transactions

**The option chain is expiry × strike, both sides** — `get_option_chain/2` rebuilds
Schwab's `callExpDateMap`/`putExpDateMap` into that grid. A strike listed on one side keeps
a `nil` on the other; iterate strikes rather than assuming both.

`underlying_price` is carried **only when you ask for it** (`include_underlying_quote:
true`). `nil` means the venue did not send it — not that the underlying has no price, and
not an invitation to fetch one separately and pair two observations taken at two times.

**Four of `/chains`'s parameters are model inputs, not filters.** `volatility`,
`underlying_price`, `interest_rate` and `days_to_expiration` are what Schwab prices an
`ANALYTICAL` chain with. This package supplies none of them; if you pass one, you are asking
the venue to price against a number you chose.

**`get_transactions/2` needs four things and defaults none of them**: `:account_hash`,
`:from`, `:to` and `:types`. There is no "all" in the venue's type enum —
`DpExchange.Schwab.transaction_types/0` lists the fifteen, and passing all fifteen is how
you ask for everything. A default here would hand you a real ledger missing whichever kinds
it left out.

`get_all_orders/2` needs both ends of a window for the same reason.

## 11. What this package does not implement

*This section used to be headed "what this venue does not have". That was wrong for at
least one entry, and the distinction is the point: a capability this package lacks is not
the same as one the venue lacks, and only the second would justify routing the work
somewhere else permanently.*

**Every negative this package makes is now audited**, with the source and date consulted:
see `docs/reference/schwab/negative-claims.md`, which ships in the tarball.

`get_order_book/2`, `get_market_overview/1`, `list_instruments/1`, `get_fees/2`,
`get_transfers/2`, `get_rate_limit_status/2`, `quantization/1` and `get_trade_history/2`
return `{:error, :not_supported}`. So do the eleven money-movement callbacks: **a stock
broker moves money through cheques, ACH and wires arranged with a person, not through an
API**, and the Accounts and Trading specification has no payment method, transfer, allowlist
or network list. `get_transactions/2` *reports* money that moved and is served.

- **`get_order_book/2`** — the venue publishes depth on the Streamer, and this package now
  reads it there. The REST callback stays unsupported because there is no REST endpoint.
- **`get_trade_history/2`** — `get_transactions/2` is where fills live on this venue, and it
  is implemented. Use that.

## 12. Rate limits are yours, not the venue's

The documented ceiling is `0..120` order writes per minute **per account**, set **per
application at registration**. Pass `:order_limit_per_minute` matching your own app's. Zero
is a legal registration value.
