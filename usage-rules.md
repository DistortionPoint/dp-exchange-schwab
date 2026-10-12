# Using `dp_exchange_schwab`

Rules for an agent or developer writing code against this package. Read this before the
README; it is what the Hex tarball ships for consumers.


## `get_order/3` and `get_orders/2` return `Core.Types.Order`

They used to return the venue's raw JSON map, against the `Core.Venue` contract. If you
wrote `order["status"]` against this package, it is now `order.status` — an atom from
`Core.Types.Order`'s vocabulary, or `nil` where Schwab's own value has no equivalent there
(`REPLACED`, `CABINET`, `END_OF_WEEK`; `TRAILING_STOP`, `TRAILING_STOP_LIMIT`,
`MARKET_ON_CLOSE` and `LIMIT_ON_CLOSE` read back as their own atoms since Core 0.3.74). A spread has `symbol: nil` and `side: nil` at
the top and carries its `legs`. An order with no `orderId` is refused rather than returned.

## BREAKING — `Quote` and `OrderBook` no longer carry `:timestamp`

They carry **`:venue_time`** (the venue's own, `nil` where the venue publishes none) and
**`:observed_at`** (when this package read it, always present) — the shape
`Core.Types.TopOfBook` has always had. The split arrived in `dp_exchange_core` 0.2.1; this package now requires `~> 0.3.50`.

```elixir
# before
quote.timestamp

# after
quote.venue_time  # may be nil — the venue did not date this
quote.observed_at # always present
```

**Why it had to break.** `:timestamp` was documented as the venue's own, "never invented",
and two packages in this family could not keep that promise: the frames they decode carry no
venue time at all. With one field their only options were to lie or to drop real data, and
they lied. Now they can say `nil` and mean it.

**What to do with `nil`.** Whatever you would have done with a wrong answer, but knowingly.
The consumer who decided this design stores `venue_time` as their time-series point time
where it is present, and where it is `nil` stores `observed_at` **and records that they
did** — so a mis-bucketed value is attributable rather than invisible. That decision was not
expressible before, because there was no way to see which kind of time you had.

`Trade`, `Fill`, `Balance` and `OrderBookDelta` are **unchanged** — they keep a single
`:timestamp`, because every one of them is built from a venue-supplied time and fails closed
without it.


**When is `venue_time` `nil` on a streamed quote?** When the frame did not carry the venue's
own trade time. `LEVELONE_EQUITIES` (field 35), `LEVELONE_OPTIONS` (39), `LEVELONE_FUTURES`
and `LEVELONE_FUTURES_OPTIONS` (11) and `LEVELONE_FOREX` (9) name one, and a `Quote` reads it
when the frame includes it. Otherwise `venue_time` is `nil` beside a real `observed_at`. That
is not a gap — it is the fact the split exists to state, and before 0.2.0 this package put
the frame's arrival time in a field documented as the venue's own.

**A delayed quote is never delivered.** An account without real-time entitlements is
streamed delayed rows (`"delayed": true`), and neither `Quote` nor `TopOfBook` can say so.
Those `LEVELONE_*` and `*_BOOK` rows are withheld, and the first one per symbol per
Streamer session raises a `:degraded` `Core.Notice` with `details.symbol`, `details.service`
and the reason. A symbol that is subscribed and never delivers, with that notice, is an
entitlement problem on the account, not a feed fault. `CHART_*` candles are still delivered.

The **book** is the opposite and always was: `to_order_book/2` reads the venue's
`snapshot_time` and fails closed without it, so an `OrderBook` always carries a real
`venue_time`.

**`get_price/2` over REST used to do the same, and stopped in 0.2.29.** This section said it
still did. A quote row carrying neither `quoteTime` nor `tradeTime`, or carrying one this
package cannot read, now comes back with `venue_time: nil` rather than refusing — the price
is guarded separately and `Core.Types.Quote` does not enforce the time, so discarding a real
traded price over it threw away what the caller asked for. **Write the `nil` branch for REST
quotes too**, not only for streamed ones.

`get_historical_prices/4` still refuses an undated bar, because
`Core.Types.Candle` enforces `:opened_at` and a bar at an invented minute lands in the series
looking like a real one.

## Candle windows, the forming bar, and daily times

`get_historical_prices(symbol, timeframe, range, opts)` takes `range: [start: dt, end: dt]`.
`:start` is **inclusive** and `:end` **exclusive** on `opened_at`; an absent `:end` is now.
The request always carries `endDate` (the venue's own default is the previous business day's
close and would drop today). An `:end` without a `:start` is
`{:error, {:range_start_required, :schwab}}`.

The bar still forming (`opened_at + width > now`) is **not returned** unless you pass
`include_partial: true`; with it the last bar may still change (`Candle` has no flag for it).
`include_partial` must be a boolean.

Daily, weekly and monthly bars are stamped exchange-local midnight by the venue; `opened_at`
here is **00:00 UTC of that session date**, not the instant sent. Minute bars keep the
instant. Whether the venue counts `period` back from `endDate` (sent when you give no
`:start`) is read from its document, not measured.

## A bid or ask of 0 is no order; an unreadable one is an error

On `get_top_of_book/2` and the streamed `TopOfBook`, a price of `0` means no resting order on
that side: `nil` price and `nil` size. A present side that cannot be read (non-numeric, empty
string, NaN, negative) is `{:error, {:invalid_decimal, :bid | :ask, value}}` on REST; on the
stream that frame's book is not delivered and the last one stands. `nil` is never produced
for something unreadable.

A streamed `Quote`'s `volume` is the day's cumulative total with `volume_window:
:running_total` (difference it), exactly as REST. It is never one print: LEVELONE is
conflated.

A streamed order book with an unreadable level (no price or size, a price <= 0, a negative
size, a non-list side) is not delivered at all; a level of size 0 is dropped as no liquidity.

Nothing is ever substituted into `venue_time` on either path: it is the venue's own instant
or it is `nil`, never this package's clock. That is what `dp_exchange_core` issue #31 split
the field to guarantee, and it has not changed.

## A streamed order book is sorted, so `hd(bids)` is the best bid

`to_order_book/2` guarantees it as of 0.2.30 — **bids descending, asks ascending** — and it
is `Core.Types.OrderBook`'s contract rather than this package's convenience. You do not need
to sort what you receive, and you should not assume the venue's own row order means anything.
A level whose price cannot be read is dropped rather than carried with a `nil` price.

## A streamed quote with an unreadable last price is refused, not nilled

As of 0.2.30, a `LEVELONE_*` frame whose `last` is a NaN or an Infinity delivers no `Quote`
at all, rather than a `%Quote{price: nil}`: the decoder's own answer is
`{:error, {:invalid_decimal, :price, _}}`, and the socket drops it (the frame's top of book,
if it moved one, is still delivered). `Core.Types.Quote` enforces `:price`, and a quote with
no price is not a weaker quote — it is not a quote. The frame's **size** is not enforced and an unreadable one still yields
`volume: nil` beside a good price.

## A streamed quote with a zero or negative last is refused too

A `LEVELONE_*` frame whose `last` reads as zero or less delivers no `Quote`
(`{:error, :no_traded_price}`), exactly as a frame with no `last`. An option that has not
traded today is the case: a zero there is the absence of a print, and a `Quote` built from it
reports a price at which nothing traded. REST has refused a zero `lastPrice` the same way
(falling to `mark`) for longer; the streamer now agrees. The frame's top of book is still
delivered if it moved one.

## A REST top of book is dated by `quoteTime` alone

`get_top_of_book/2` sets `venue_time` from `quoteTime` ("the last time a bid or ask updated")
and from nothing else. It used to fall back to `tradeTime`, which dates the last print and
can be much older than the book on the same row. A row without a usable `quoteTime` has
`venue_time: nil`, as the streamed book does when a frame carries no quote time. (`get_price/2`
is unchanged: a quote's price is dated by `tradeTime` first when the price is `lastPrice`.)

## A screener row the venue did not name is dropped

Also 0.2.30. `get_screener/2` used to publish such a row with `symbol: ""`, which satisfied
the contract's non-nil requirement while saying nothing — and an empty string is worse than a
`nil`, because a consumer keying coverage by symbol gets a live entry named `""`.

**A shorter list is not an error, and the venue's ranking is preserved**: a dropped row
leaves a gap in `rank` rather than renumbering the survivors, because `rank` is the position
the venue returned the row in.

Full reasoning and the options that were weighed:
[`dp_exchange_core` issue #31](https://github.com/DistortionPoint/dp-exchange-core/issues/31).

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
locally with `{:error, {:missing_credentials, :schwab}}` rather than being sent. Not
`{:refused, _}`: `Core.Venue` reserves that for the venue's own word about a request it
actually received, and a call with no credential never leaves this process.

**A blank credential counts as a missing one.** An `:access_token` — or, for `refresh/2`, a `:refresh_token`, `:client_id` or `:client_secret` that is `""`, or only
whitespace, is refused locally with `{:error, {:missing_credentials, :schwab}}` — it is
never signed with. This matters because the usual way a credential goes missing is not a
`nil`: it is a `.env` line reading `NAME=` with nothing after it, and `System.get_env/1`
hands that back as `""`. Signing with it produced a well-formed request the venue refused
for a reason naming signatures, which points at the signing code rather than at the
credential.
**A credential with surrounding whitespace is refused, never trimmed and sent.** An
`:access_token` (or a `refresh/2` `:refresh_token`, `:client_id`, `:client_secret`) such as
`" token"` or `"token\n"` answers `{:error, {:invalid_credentials, :schwab}}`; the value is
never echoed. It used to be trimmed for the one signed request while the Streamer `LOGIN`
and the refresh read it untrimmed. Blank is still `{:missing_credentials, :schwab}`, and wins.

**A single-symbol read judges its symbol before credentials.** `get_price/2`,
`get_top_of_book/2` and `get_historical_prices/4` answer `{:error, {:invalid_symbol, value}}`
for `nil`, a non-string or a blank string, with or without credentials and before any
request. (Formerly `{:not_an_equity_symbol, value}` for the first two, after the
credential check, and `{:empty_symbol, ""}` for blank.) A well-formed string that is not an
equity keeps `{:not_an_equity_symbol, value}`. `get_historical_prices/4` answers
`{:error, {:invalid_range, range}}` for a `range` that is not a keyword list or whose
`:start`/`:end` is not a `DateTime` (formerly a raise, and `{:invalid_range_bound, key,
value}`), before any request.

A blank `:client_secret` used to reach the venue and come back 401, which this package maps
to `{:refused, {:reauthorization_required, ...}}` — the **terminal** answer meaning a person
must authorize again at a browser. An unset config value is not a spent grant.

**`DpExchange.Schwab.Fake` enforces that on every endpoint, and five of them slipped
before.** `Fake.get_positions/1`, `Fake.get_option_chain/2`,
`Fake.get_option_expirations/2`, `Fake.get_screener/2` and `Fake.get_transactions/2`
answered `{:ok, _}` with no credentials at all, on a venue where every single call needs
OAuth. A consuming suite that called them without credentials and asserted success was
going green against behaviour this venue does not have. If yours does, it needs updating —
that is the fix, not a regression in it. They were missed because `dp_exchange_core`'s
assertion 17 checks a fixed list of nine callback names that predates this surface and
includes none of the five; passing that assertion is not evidence that the rest of a fake
gates credentials.

## 3. Refresh, and persist what you get back

The access token lives **30 minutes**. `DpExchange.Schwab.refresh_credentials/2` renews it —
call this, not `DpExchange.Schwab.Auth.refresh/2` directly, which is internal and reached
only by going past the facade.

**`DpExchange.Schwab.needs_refresh?(credentials, now \\ DateTime.utc_now())` answers when.**
This package holds no state and starts no timer — it cannot decide on your behalf when a
credential you hold is about to expire, only whether it is, when asked. Call it before a
call you are about to make, or on your own schedule:

```elixir
if DpExchange.Schwab.needs_refresh?(credentials) do
  {:ok, renewed} = DpExchange.Schwab.refresh_credentials(credentials)
  :my_app.persist_schwab_credential(renewed)
  DpExchange.Schwab.update_credentials(renewed)
  renewed
else
  credentials
end
```

`true` once the access token is close to expiring, or has already expired. **`false` when
`credentials` carries no `:expires_at`** — an unknown expiry is not an expired one. A host
that never tracks expiry at all still gets refreshed correctly, just reactively: check
`DpExchange.Schwab.credential_failure?(status)` against the `status` inside a `{:refused,
{:venue_error, status, detail}}` result, and refresh-then-retry once when it is `true`.
Any other `4xx` is about the request, not the credential, and retrying with a fresh token
will not fix it. The `detail` is the venue's own text, bounded: longer than 2_048 bytes it is
cut on a UTF-8 boundary and ends `… (N bytes)`; a shorter one is unchanged, and a `detail`
that was not text arrives as its bounded `inspect/2` rendering.

**On the streaming side the same reactive signal arrives as a notice, and you must handle
it.** `credential_failure?/1` covers a REST response you are holding; a live Streamer login
is refused asynchronously, with no call of yours to return it to. When that happens this
package emits:

```elixir
%DpExchange.Core.Notice{kind: :credentials_rejected, provider: :schwab, details: %{reason: _}}
```

Subscribe with `DpExchange.Schwab.subscribe_notices/1` and treat that kind as "refresh now" —
the same `refresh_credentials/2` → persist → `update_credentials/2` sequence above. **The
socket cannot fix its own token.** It backs off (one second, doubling, capped at thirty) and
retries the same rejected credential until you replace it, so a host that ignores this notice
has a feed that reconnects forever and never logs in. This also covers what
`needs_refresh?/2` structurally cannot: a token the venue stops accepting *early* — revoked,
or rotated by something else — which no clock check can predict.

**A login refused for a non-credential reason stays `:degraded`, deliberately.** The vendor's
response-code table answers `3 LOGIN_DENIED` with *"reconnect and re-login with new token"*,
which is why that code — and only that code — is reported as a credential rejection. `9
UNKNOWN_FAILURE` is the vendor's error of last resort and `11 SERVICE_NOT_AVAILABLE` is the
venue being down; a fresh token is the remedy for neither, and reporting them as a rejected
credential would be this package claiming something the venue never said.

**Any refused login ends that Streamer connection and is retried.** The package closes the
socket itself, backs off on the consecutive-failure count (1s, doubling, capped at 30s) and
logs in again on a fresh connection, presenting whatever token `update_credentials/2` last
supplied. So a `:degraded` login notice means a retry is in progress, not a feed that has
stopped for good. There is nothing to restart.

**The refresh token is one-time use.** Every refresh spends the old one and returns a new
one. So:

- **Persist the returned credential before using it.** Refreshing and then crashing before
  storing costs the grant, and only a person at a browser can restore it.
- **Do not retry a refresh.** The package will not, deliberately. If a refresh times out, the
  token may already have been spent; try again with the credential you still hold, not the
  one you just sent.
- `{:refused, {:reauthorization_required, _status, _detail}}` is **terminal**. The refresh
  token's seven days elapsed, or the user reset their password. Send a person to the login
  page; do not retry.
- `{:refused, {:client_credentials_rejected, _status, _detail}}` is **not** a dead grant.
  The venue answered `invalid_client`: your app's `client_id` or `client_secret` is wrong
  (rotated, mistyped, or from another app). Fix the configuration; a person logging in again
  would get the same refusal. This code is the OAuth standard's (RFC 6749 §5.2); Schwab's
  reference does not list its token errors, and it has not yet been observed from Schwab.

**The vendor documents the refresh token as valid seven days after creation, full stop —
three times, in the same words each time
(`accounts-and-trading-production.txt:57,75,102`).** It does not say whether refreshing
before expiry resets that clock forward from the new token's own creation, and this
repository has no sandbox and no credential to test the difference. Plan for a person to
re-authenticate at least once every seven days regardless of how often you refresh in
between — the safe reading is the vendor's literal words, not the more convenient one.

**`:to` on `subscribe/2` and `subscribe_notices/1` must be a pid or a registered name** (an
atom other than `nil`, `true`, `false`). Anything else — a string, an integer, a
`{:global, _}` or `{:via, _, _}` tuple — answers `{:error, {:invalid_subscriber, term}}` and
records nothing; symbols are judged first. Register a process and pass its pid. A feed itself
may be registered under `{:global, _}` or `{:via, _, _}` and passed as `feed:`.

**If you hold a running feed (you called `subscribe/2` or started this package supervised),
also call `DpExchange.Schwab.update_credentials/2` with the refreshed credential.** The
Streamer is meant to stay up far longer than one 30-minute access token, and a feed's
credentials are otherwise fixed at whatever they were when it started — a socket that
reconnects on an access token nobody ever refreshed presents a token the venue's own
`LOGIN_DENIED` will keep rejecting, forever, since nothing about that fixes itself with
time. `update_credentials/2` does not force a reconnect; it only changes what the *next*
one presents.

```elixir
{:ok, renewed} = DpExchange.Schwab.refresh_credentials(credentials)
:my_app.persist_schwab_credential(renewed)
DpExchange.Schwab.update_credentials(renewed)
```

**Your refresh token and client secret will not appear in the crash log.** `Feed` and
`Socket` both hold your credential for as long as they run, and a crash of either logs
that process's state via OTP's default crash report — which is where you *would* see it,
because a crash report prints unredacted `Logger` metadata otherwise. Both processes wrap
the credential set in a struct before it ever reaches state, so the crash line reads
`credentials: #DpExchange.Schwab.Credentials<expires_at: nil, ...>` rather than the
tokens and secret themselves — `expires_at` stays visible because it is not a secret and
is useful to see mid-incident. This is not a claim about your own code: if you read
`state.credentials` yourself via `:sys.get_state/1` or similar, you get the same struct —
call `Map.from_struct/1` on it to get the plain map back.

The same holds for the message `update_credentials/2` sends the feed (wrapped before it is
sent, so a timed-out call's exit reason does not print the tokens) and for the Streamer's
`customer_id` and `correl_id` in `StreamerInfo`, which `Socket` keeps in its state and which
`inspect/1` now hides.

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

A range needs a `:start`. `[end: t]` alone returns `{:error, {:range_start_required, :schwab}}`
and a start after its end returns `{:error, {:range_start_after_end, :schwab}}` — the venue's
`period` is relative to now, so an end alone would silently give the wrong dates. The
venue's `empty: true` answer is `{:refused, :not_listed}`; the document does not say whether it
can also mean "listed, no bars in the window", so treat it as "no such series".

## 6. Account calls need a hash, not an account number

`get_accounts/2` returns `%{account_number: …, hash: …}`. **Every other account path takes
the hash**, passed as `:account_hash`. Nothing is defaulted — placing an order against a
silently-chosen account is not something this package will do for you.

```elixir
{:ok, [account]} = DpExchange.Schwab.get_accounts(credentials)
DpExchange.Schwab.get_balances(credentials, account_hash: account.hash)
```

**`get_positions/1` is the exception, and it takes `:account_number`.** It reads every
account in one call, and `Position` has no account field. So with more than one account,
leave out `:account_number` and you get `{:error, {:missing_option, :account_number}}` rather
than one list mixing every account (a credential with exactly one account needs no number). A row holding both a long and a short leg comes back as two
positions. `notional_value` is unsigned, because `:side` carries the direction. A negative
`longQuantity` or `shortQuantity` refuses the whole read as `{:error,
{:unexpected_position_quantity, :negative}}`: the spec leaves the sign of a short unstated, and
reading it as a flat position would drop the short from the reply.

Venue times (`quoteTime`, `tradeTime`, a candle's `datetime`) are read as epoch **milliseconds**
always; a small integer is not guessed to be seconds.

A margin account's `available_balance` is `availableFunds`, not `buyingPower`. Buying power
is leveraged and can exceed the balance it would sit inside.

`balance` means **the cash in the account** for both account types: `totalCash` on a cash
account, `marginBalance` on a margin account. **Unmeasured:** the spec types `marginBalance`
as a bare `number` with no description, so that it is the cash side and that it is negative
when borrowing is a reading, not a documented fact. It is never `equity`, which includes the market value of securities held. A margin
reply without `marginBalance` is `{:error, :unexpected_response_shape}`.

Money and quantities are decoded without float rounding (`floats: :decimals`), so every digit
the venue sent survives. That includes the calls that hand back the venue's body unmapped
(`preview_order/3`, `get_transactions/2`, `get_all_orders/2`, ...): a fractional JSON number
in those maps is a `Decimal`, not a float; an integer stays an integer. Streamer frames are
not covered by this: they are decoded by `Socket` and read by `StreamerDecode`, which accepts
a float, an integer, a string or a `Decimal`.

A `get_positions` row whose `longQuantity` and `shortQuantity` are both absent, or one of them
present but unreadable, refuses the whole reply: `{:error, {:unexpected_position_quantity,
:unreadable}}`. Only quantities stated as zero are a flat position, which is skipped.

`get_transactions/2` returns at most 3000 rows per the spec; a reply of 3000 or more is
`{:error, :history_truncated}` and is never returned as complete. Narrow the window or
`:symbol` and ask again.

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
so a locally-catchable rejection is worth catching. `DpExchange.Schwab.equity_instructions/0`
and `DpExchange.Schwab.option_instructions/0` list the matrix directly, the same way
`transaction_types/0` lists the venue's transaction-type enum — check before building a
request rather than discover the mismatch by refusal.

## 7a. Preview before you place, and replace rather than cancel

Two things this venue can do that no other in the family can. Both are declared —
`supports_order_preview` and `supports_order_replace` — so you can branch on capability
rather than on venue name.

```elixir
{:ok, preview} = DpExchange.Schwab.preview_order(credentials, request, account_hash: hash)
```

**A preview the venue rejects is `{:refused, {:preview_rejected, rejects}}`, not `{:ok, _}`.**
`/previewOrder` answers 200 with `orderValidationResult.rejects` listing the rules the order
breaks; a non-empty list is a refusal (`rejects` is the venue's own detail rows, capped at 50
and bounded). `alerts`, `warns` and `reviews` are advisory and ride along in the `{:ok, body}`
of a clean preview. `Fake.preview_order/3` models one rejection it can know without the
venue: an option order for a fractional number of contracts. The rule name it carries is the
fake's own, not the venue's; queue other rejections with `DpExchange.Core.FakeInjection`.

**Preview is close to free and placing is not.** Schwab throttles order writes to somewhere
between 0 and 120 a minute per account. Its documentation says "Get order requests are
unthrottled" and states no limit for market data or for `previewOrder`, which is an absence
in the document and not a measurement (`docs/reference/schwab/spec-facts.md` §4). A
rejection found by previewing costs a read. One found by placing costs a scarce write.

This package meters both. Reads, `preview_order` included, share one bucket at
`read_limit_per_minute` (120 by default), a courtesy ceiling rather than the venue's. Order
writes share one bucket at your declared `order_limit_per_minute` **across every account the
supervisor serves**, because the limiter keys by provider, not by account. That is stricter
than Schwab's per-account count, never looser. Run one supervisor per account if you need
each account's full ceiling.

```elixir
{:ok, %Order{id: new_id}} =
  DpExchange.Schwab.replace_order(credentials, old_id, request, account_hash: hash)
```

**`replace_order/4` returns the NEW order, with a new id.** Schwab treats a replacement as a new order, so the
id you passed in is dead afterwards — keep the one you get back, or you will be tracking an
order that no longer exists.

`place_order/3` and `replace_order/4` return an `Order`, read back with `get_order/3` once the
venue names the id. The venue answers a write with only a `Location` header.

- If the read back of a **placement** fails, the order is still placed: you get an `Order` built
  from the payload that was sent (normalised symbol, side, type, time-in-force) and the id the
  venue named, with `status: :pending`.
- If the read back of a **replacement** fails, you get
  `{:error, {:replace_accepted_unread, new_id, reason}}`. The old order is gone and `new_id` is
  live; no `Order` is built from your request. Read it with `get_order(new_id)`.
- **A write that may have reached the venue and is not proven is
  `{:error, {:order_unconfirmed, nil, reason}}`**: a timeout or transport failure after the
  request left, a 5xx, or a 2xx with no `Location`. Order writes are sent exactly once, so
  never retry on it: list the account's orders (`get_orders/2`) to find out whether the order
  exists. The `nil` is the client order id, which Schwab has no field for. Failures decided
  before anything was sent (validation, a missing option or credential, our own rate limiter
  refusing, the venue's 429) stay plain `{:error, _}`; **every venue 4xx except 429 is
  `{:refused, _}`** (409, 415 and 422 included: writes are sent once, so a 4xx is always the
  answer to the first attempt). `cancel_order/3` follows the same rule.
  A missing order (404) on `get_order/3`, `cancel_order/3` or `replace_order/4` is
  `{:refused, :not_found}`.

`cancel_order/3` returns `{:ok, :cancelled}`.

**What a request must say.** `place_order/3`, `preview_order/3` and `replace_order/4` require
`:symbol`, `:side` (`:buy`/`:sell`, or `"buy"`/`"sell"` in any case; or the option `:instruction`),
`:quantity` (a Decimal, an integer or a numeric string; **a float is refused**),
`:order_type` and `:time_in_force`. Nothing is defaulted: a missing order type is
`{:missing_field, :order_type}` (never a market order), a missing time-in-force
`{:missing_field, :time_in_force}` (never `:day`). A price the order type does not read is
`{:unexpected_field, :price}`; prices follow the quantity rule (`{:invalid_price, v}`,
`{:invalid_stop_price, v}`). **Any key the builder does not read is
`{:unsupported_order_field, key}`, `client_order_id` included, whatever its value (`nil`
too)**: Schwab has no idempotency key, so silently ignoring it would let you believe a retry
was safe. Checks run in this order:
request shape, unknown keys, symbol, side, order type, time-in-force, quantity, prices, then
`opts[:account_hash]` (`{:missing_option, :account_hash}`), the order ceiling, and the
credential. `get_order/3`, `cancel_order/3` and `replace_order/4` check the order id first:
`{:error, {:invalid_order_id, v}}` for `nil`, a non-string, a blank or a padded string.

Use it instead of cancel-then-place wherever you can. The two are **not equivalent**:
cancel-then-place leaves a window with no order live, and spends two throttled writes
rather than one.

## 7b. Sessions, and the order types Core learned here

Every order carries a `session` — `NORMAL` unless you say otherwise. Pass `:session` in
the request or `session:` in options. `supported_sessions` lists what the venue takes;
this is the only venue in the family where the field is non-empty, because it is the only
one whose market closes. The atoms map `:regular` to `NORMAL`, `:pre_market` to `AM`,
`:post_market` to `PM` and `:extended` to `SEAMLESS`; the venue's own `NORMAL`, `AM`, `PM`
and `SEAMLESS` are accepted in any case. Anything else is
`{:error, {:unsupported_session, value}}` before a request is sent, never `NORMAL`.

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
not a fault. `DpExchange.Schwab.wanted/1` is the other half — what was asked for — so
comparing the two tells "not yet arrived" apart from "never subscribed," which `coverage/1`
alone cannot. `DpExchange.Schwab.status/1` is the feed-wide summary (route, delivering
count, wanted count, last error) a health check reaches for instead of assembling one from
`coverage/1` and `coverage_by_kind/1`.

## 9. The Streamer, and what arrives only there

**This package speaks the WebSocket Streamer as of 2026-09-01.** Schwab's Streamer carries
fifteen services, and the three kinds a consumer subscribes to and actually receives are
quotes, top of book and candles — `services_for/1` sends every non-option symbol to both
`LEVELONE_EQUITIES` and `CHART_EQUITY`, and an option symbol to `LEVELONE_OPTIONS` only.

```elixir
DpExchange.Schwab.capabilities().streamable
# [:quotes, :top_of_book, :candles]
```

### A streamed `TopOfBook` is a full book, not the frame that produced it

Schwab's `LEVELONE_*` services are **Change** delivery: a frame carries only the fields that
moved. This package merges each frame onto the last book it published for that symbol and
hands you the merged snapshot, so a `TopOfBook` you receive means what
`Core.Types.TopOfBook` says it means — a `nil` bid is a book with no resting bid, not a
frame that happened not to mention one.

You therefore do **not** need to accumulate these yourself, and you should not: two
consumers folding the same stream would be doing the venue's conflation twice. Treat each
`TopOfBook` as replacing the previous one for that symbol.

Two consequences worth knowing:

* **Before the venue has ever reported a side, it is `nil`.** The first frames after a
  subscribe can carry one side only. A `nil` there is "not yet reported by this session"
  rather than "no resting bid", and the two are indistinguishable from the outside — so a
  caller sizing an order against a `nil` on a freshly subscribed symbol should wait for a
  frame that states it, exactly as it would for a genuinely one-sided book.
* **A reconnect resets it.** The merge state is per connection and is dropped when the
  session is, because a level from a session the venue no longer has is not a level this
  package will keep asserting. You will see a `:link_down` notice, and the book rebuilds
  from the new session's frames.

`CHART_*` is **All Sequence** and `NYSE_BOOK`/`NASDAQ_BOOK`/`OPTIONS_BOOK` are **Whole** —
both deliver complete units, so nothing is merged for those and a missing price in a candle
is refused rather than filled in.

**A documentation-accuracy sweep (2026-09-06) found `streamable` naming three more kinds —
`:order_book`, `:orders`, `:fills` — that nothing here ever subscribed.** The decoders for
`NYSE_BOOK`/`NASDAQ_BOOK`/`OPTIONS_BOOK` and `ACCT_ACTIVITY` existed and were tested, which
is exactly why the gap was easy to miss: decoding a frame and asking the venue to send one
are different facts, and only the second one was true. That declaration is corrected here.

**Depth does not arrive by subscription, and neither do order or fill events, and each is
absent for a reason that would make wiring it a guess:** `NYSE_BOOK` and `NASDAQ_BOOK` are
both documented only as "Level Two book for Equities," with no stated rule for which
service a given equity belongs on; `ACCT_ACTIVITY`'s `message_data` is documented JSON
"whose shape depends on `message_type`" that the vendor does not publish. `get_order_book/2`
still returns `{:error, :not_supported}`, and that remains a narrow and accurate claim:
there is no *request-response* order book, and the contract's callback is a read — that has
never depended on whether depth is streamable, which it is not.

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
`:from`, `:to` and `:types`. A missing `:account_hash` is
`{:error, {:missing_option, :account_hash}}` — the same answer every other account endpoint
here gives. It was `{:missing_account_hash, :schwab}` until the trading-conventions pass, and
`{:account_hash_required, :schwab}` before 2026-09-07.

**`:types` takes ONE type, not a list, and there is no "all".** The venue's own parameter
is a scalar enum (`TransactionType`), not an array — `DpExchange.Schwab.transaction_types/0`
lists the fifteen values it accepts, one at a time. Passing more than one is refused as
`{:error, {:multiple_transaction_types, :schwab, types}}` rather than joined into one
request or split into several merged ones; call this once per type and merge the results
yourself if you want several. A single-element list (`types: ["TRADE"]`) is accepted as a
convenience and treated the same as the bare string.

`get_all_orders/2` and `get_orders/2` both need both ends of a window for the same reason
`get_transactions/2` needs `:from`/`:to` — the venue requires `fromEnteredTime` and
`toEnteredTime` on both its "every account" and its per-account orders read, and this
package refuses locally with `{:error, {:from_and_to_required, :schwab}}` rather than
picking one. A window whose `to` is before its `from` is
`{:error, {:order_window_reversed, :schwab}}`, one longer than 365 days (the spec's "maximum
date range is 1 year") is `{:error, {:order_window_too_long, :schwab}}`, and an end that is
neither a `DateTime` nor an ISO-8601 string is `{:error, {:order_window_invalid, :schwab}}`;
none of these is sent, because how the venue refuses them is not documented.
`get_all_orders/2` also refuses a `from` more than 60 days before now
(`{:order_window_start_too_old, :schwab}`; the spec: "Date must be within 60 days from
today's date"), and `:status` on both orders reads must be one of the venue's 21 uppercase
`apiOrderStatus` strings (`Rest.order_statuses/0`), else `{:invalid_order_status, value}`.
`get_transactions/2` applies the same window rules (the spec also says "maximum date range is
1 year" there) under the names `:transaction_window_reversed`, `:transaction_window_too_long`
and `:transaction_window_invalid`. A transaction id or account hash that is empty or not
text/an integer is `{:error, {:invalid_path_segment, :schwab}}` from `Rest`, and one
containing `/`, `?` or `#` is escaped into a single path segment rather than changing the
path. An order id given to the facade's `get_order/3`, `cancel_order/3` or `replace_order/4`
is checked first, as `{:error, {:invalid_order_id, value}}`: `nil`, an integer, a blank or a
padded string.

An orders reply is capped by the venue at 3000 rows unless `:max_results` is given
("Default is 3000"). With no `:max_results`, a reply of 3000 or more rows from
`get_all_orders/2` or `get_orders/2` is `{:error, :history_truncated}`, as for
`get_transactions/2`: narrow the window or pass the bound you want.

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

Those are not the whole list. `DpExchange.Schwab.venue_does_not_serve/0` is: it also covers
`get_trades/2`, `get_auction_imbalance/2`, `get_volume_profile/3`, `place_orders/3`,
`preview_replace/4`, `cancel_all_orders/2`, `close_position/3`, and the staking,
conversion, watchlist, news and account-management callbacks. Every endpoint it names is
declared `:unsupported` in `capabilities/0`.

- **`get_order_book/2`** — the venue publishes depth on the Streamer, but this package does
  not subscribe it (§9): the vendor names no rule for routing an equity symbol between
  `NYSE_BOOK` and `NASDAQ_BOOK`, and guessing one is exactly what this package refuses to
  do. The REST callback stays unsupported because there is, separately, no REST endpoint.
- **`get_trade_history/2`** — `get_transactions/2` is where fills live on this venue, and it
  is implemented. Use that.

## 12. Rate limits are yours, not the venue's

The documented ceiling is `0..120` order writes per minute **per account**, set **per
application at registration**. Pass `:order_limit_per_minute` matching your own app's. Zero
is a legal registration value.

**Leaving `:order_limit_per_minute` out no longer sails through at your read limit — a
tree started without it refuses every order write outright.** A documentation-accuracy
sweep (2026-09-06) found the supervisor silently reusing `:read_limit_per_minute` (120 by
default) for order writes whenever this option was omitted — the top of Schwab's own
range, assumed for a registration this package was never told about. The first fix
defaulted the *number* to `0` instead, and was itself sent back on review: a starved
limiter answers `{:rate_limited, _}` or blocks under `rate_limit_blocking: true`, which
looks exactly like the *venue* throttling you, when in fact the venue said nothing and
this package was refusing on your behalf for a reason that answer cannot show.

```elixir
DpExchange.Schwab.place_order(creds, request)
# {:error, :order_limit_not_declared} — this tree was never told a ceiling
```

`place_order/3`, `replace_order/4` and `cancel_order/3` now check **before** touching the
limiter at all, and answer `{:error, :order_limit_not_declared}` distinctly — never
`{:rate_limited, _}` — when the tree behind them was started without
`:order_limit_per_minute`, and `{:error, :order_limit_zero}` when it was declared as `0` (a
registration granting no order throughput; the limiter's arithmetic floor of 1 must not
grant one write a minute). **State your own ceiling if you place orders at all**, matching
what your application was registered with, or `0` if it places none. A consumer that only
ever reads quotes is unaffected either way, and a consumer using its own `:limiter`
outside `DpExchange.Schwab.Supervisor` entirely gets no opinion from this check — it only
applies to a tree this package itself supervises.

**A declared ceiling is now actually enforced, which it was not before.** `place_order/3`,
`replace_order/4` and `cancel_order/3` used to meter against the same `:schwab` bucket
every read does, so a correctly-stated `:order_limit_per_minute` never gated a real write
— it would have sailed through at the read ceiling regardless, and any true over-limit
behaviour surfaced as a rejection from Schwab itself. They now meter against
`:schwab_orders`, the bucket `DpExchange.Schwab.Supervisor.limits/1` has always built for exactly this.
`preview_order/3` is unaffected by both changes — it is not a throttled order write on
this venue.

**A bad ceiling now fails at start, and an explicit `nil` reads as silence.**
`:order_limit_per_minute` and `:read_limit_per_minute` must be non-negative integers;
anything else raises `ArgumentError` from this package's own `Supervisor`, at `start_link/1`, naming the option and
the venue's documented range, rather than failing later inside the limiter's arithmetic
where the message names neither. Passing `nil` — what a forwarded
`Application.get_env/2` lookup produces when nothing was configured — now reads as "you
said nothing", the same as omitting the key, instead of being taken as a stated
registration carrying a `nil` ceiling. `:interval_ms` on the fallback poll is validated the
same way: a zero, negative or fractional value is refused at start rather than crashing on
the first tick inside `Process.send_after/3`, in another process, as a restart loop.

## 13. What the fake remembers, and making it fail on demand

**The fake remembers the orders it placed, per process.** `place_order/3` issues a numeric
id, a new one each time, and the order reads back as what you placed: its symbol,
instruction, size and price, `WORKING` (so `:open`), nothing filled. `get_order/3` and
`get_orders/2` (narrowed by `opts[:status]`) answer from that; `cancel_order/3` marks it
`CANCELED`, and `replace_order/4` marks it `REPLACED` and issues a new working order. A
cancel or replace of an order that is no longer working is `{:refused, {:venue_error, 400}}`,
and an id the fake never issued is `{:refused, :not_found}` on every one of the
three. `place_order/3`, `replace_order/4` and `cancel_order/3` also refuse an undeclared or
zero order ceiling (`{:error, :order_limit_not_declared}` / `{:error, :order_limit_zero}`)
exactly as the facade does, when a real tree is supervised under the same `:order_limit` name;
with no tree the fake, like the facade, has no opinion. `get_orders/2` leads with one canned filled AAPL order (entered 2026-01-02) so a
check over its elements is not vacuous; `1005439821` is that order's id. The fake honours
the `from`/`to` window like the venue: only orders entered inside it are listed, so a
window that excludes 2026-01-02 omits the canned order. A placed order is entered at the
moment it is placed.

`DpExchange.Schwab.Fake` is wired to `DpExchange.Core.FakeInjection`, the same seam the
other four venue packages expose. Until now this package was the only one without it.

```elixir
DpExchange.Core.FakeInjection.queue_failures(:schwab, [{:error, :timeout}])
DpExchange.Schwab.Fake.get_price("AAPL", credentials: creds)  #=> {:error, :timeout}
DpExchange.Schwab.Fake.get_price("AAPL", credentials: creds)  #=> {:ok, %Quote{}}

# Every call for one symbol fails, indefinitely; every other symbol is untouched:
DpExchange.Core.FakeInjection.fail_always(:schwab, "MSFT", {:refused, :not_listed})
```

**`bypass_credentials/1` matters more here than on any other venue.** This one has no
anonymous surface at all, so without it there is no way to exercise dispatch or decode
logic without building a credential map for every call:

```elixir
DpExchange.Core.FakeInjection.bypass_credentials(:schwab)
DpExchange.Schwab.Fake.get_price("AAPL", [])  #=> {:ok, %Quote{}}, no credentials needed
```

Injection is process-scoped through `Core.Config`, so it is `async: true` safe and reaches
only the calling process and `Task`s it spawns — not a separately-supervised `GenServer`.

**What is not wired.** `subscribe/2`, `unsubscribe/2` and `update_symbols/2` take a list of
symbols in one call, and whole-call injection cannot express "this one symbol in the batch
fails, the rest succeed". `coverage/1`, `coverage_by_kind/1`, `wanted/1`, `status/1` and
`subscribe_notices/1` are local bookkeeping that always succeeds by construction. Every
call with a real success path is wired, including `get_positions/1`, `get_option_chain/2`,
`get_option_expirations/2` (both targetable by the underlying symbol), `get_screener/2`,
`get_transactions/2` and `get_all_orders/2`. (`get_rate_limit_status/2` is `:unsupported`, so
it has nothing to inject into.)

**The fake models the normal route.** `Fake.coverage/1` reports `:stream` and
`Fake.status/1` `route: :stream`, as a real feed does once the Streamer bootstraps (the
`:internal_poll` fallback is not modelled). `Fake.subscribe_notices/1` registers and sends
nothing, as the real feed sends no notice on registration. `Fake.update_symbols/2` ignores
`:to`, as the real one does.

**The fake judges a credential as the real package does.** A call whose credential has no
non-blank `:access_token` — `%{refresh_token: "x"}`, `%{access_token: ""}` — is
`{:error, {:missing_credentials, :schwab}}` here as there, and in the same place in the
order of refusals: market-data calls first refuse a nil, non-string or blank symbol
(`{:invalid_symbol, v}`), then want a credential map, then judge their own arguments
(equity-ness of the symbol, width, range, market), then sign; account calls judge theirs and
sign last. A `to:` atom naming no registered process is skipped on delivery (and covers
nothing), as the real feed's fan-out skips it. The
fake also narrows `get_orders/2` by `:max_results`, refuses an unreadable `:from_date` or
`:to_date` on `get_option_chain/2`, and answers `{:refused, {:account_not_found, number}}`
to a `get_positions/1` `:account_number` other than the one account it holds.

**What the fake does not provide.** The facade's raw reads — `get_transaction/4`,
`get_account_summaries/2`, `get_symbol_quote/3`, `get_market/3`, `get_instrument/3`,
`get_user_preference/2` — and `refresh_credentials/2` return the venue's own JSON, which a
fake could only invent. Drive `DpExchange.Schwab.Rest` with your own `:plug` for those. The
static lists (`movers_universes/0`, `markets/0`, `transaction_types/0`,
`equity_instructions/0`, `option_instructions/0`), `needs_refresh?/2`,
`credential_failure?/1`, `wanted/1`, `status/1` and `update_credentials/2` are on the fake.

## A connect that never finishes ends at a deadline, and a malformed close frame is a reconnect

Two things this package's socket does that the `websockex` library it is built on does not.
Both come from a private, patched fork of websockex 0.5.1's process loop,
``DpExchange.Schwab.Vendor.WebSockex``, carried from `dp_exchange_webull` on 2026-09-27.

- **The opening handshake has a deadline**: `socket_connect_timeout` plus
  `socket_recv_timeout`. Upstream bounds each read of the upgrade response separately, so
  a peer that trickled the response held a connect open indefinitely. A connect that
  misses the deadline now fails with `%WebSockex.ConnError{original: :timeout}`, the same
  error a plain read timeout gives. On a reconnect, that means backoff and another try, not
  a socket stuck connecting.
- **A close frame with an invalid status code disconnects.** Upstream raised on it and
  crashed the socket before its reconnect logic ran. It now produces an ordinary
  `:link_down` and reconnect.

**This package depends on `{:websockex, "== 0.5.1"}` exactly.** The fork calls that
release's internals. If your application pins a different websockex version, dependency
resolution will fail, so resolve to 0.5.1.

**The WebSocket verifies the venue's TLS certificate** (2026-09-27). websockex's own
default is not to (`verify: :verify_none`), and until then this package connected with
that default, accepting any certificate. It now uses the operating system's trust store and
HTTPS hostname rules. On a host with no system CA bundle the connection fails with a TLS
error rather than connecting unverified. Pass your own `:ssl_options` to override.

## 14. A reconnect resubscribes on its own; a crash costs one retry, never a lost consumer state

The Streamer socket and the fallback poller are both **linked** children of `Feed` — not
supervised siblings you can restart independently. `Feed` traps exits, so either one
dying abnormally does not take `Feed` down with it: `coverage/1` and `coverage_by_kind/1`
clear (this feed has exactly one active route at a time, so a crash costs everything it
was delivering, not a partial set), you get a `:link_down` `Core.Notice`, and this
package retries the route on its own — a fresh Streamer bootstrap if the credential
still works, falling back to the poll otherwise. You never need to call `subscribe/2`
again for this.

**An ordinary reconnect (no crash, just the venue dropping the TCP connection) also
resubscribes on its own, as soon as the new LOGIN succeeds.** `Socket.handle_disconnect/2`
clears the venue's own subscriptions on every reconnect (see `Socket`'s own moduledoc),
and `Feed` re-issues your `wanted` symbols the moment the socket reports it has logged in
again. A 60-second unconditional timer re-issues them as well, as a safety net.

**`subscribe/2` or `update_symbols/2` can answer `{:error, {:route_pending, ms}}`.** The
first call on a feed waits for the Streamer to be set up (`GET /userPreference`). If that
is slow, the call is answered after about ten seconds rather than outliving its own 15s
timeout and exiting. Your symbols are recorded and applied once the route is set up, so
there is nothing to retry.

**The fallback poll is not permanent.** If the Streamer could not be bootstrapped and this
feed fell back to polling (`coverage/1` says `:internal_poll`), it retries the Streamer on
that same 60-second timer and switches back when it can. The poll stops, your `wanted`
set moves to the socket, and an `:info` `:coverage_change` notice says the Streamer is
back. A credential the venue *refused* is not retried on the timer, because it would be
refused again. Calling `update_credentials/2` with a refreshed one retries at once, and so
does a bootstrap that was already in flight when you called it and then failed: it is
retried with the new credential rather than judged against the old one.

**What still costs you your whole subscription: `Feed` itself crashing** — a bug outside
the crash-isolation path above, or anything that kills the `Feed` pid directly.
`DpExchange.Schwab.Supervisor` restarts `Feed` under `:one_for_one`, but from the
*static* `opts` your supervision tree started it with; every `subscribe/2`,
`update_symbols/2`, `subscribe_notices/1` call and every `update_credentials/2` push you
made afterward is gone. Nothing inside this package can replay those calls — it never
held onto the functions or the process that made them. If your consumer needs to survive
a `Feed` restart unattended, monitor the `Feed` pid (or the `DpExchange.Schwab` pid it
sits under) yourself and re-issue `subscribe/2` on `:DOWN`.

## A slow subscriber gets dropped, and told — it does not get an unbounded mailbox

If your process falls far enough behind that its mailbox reaches **10,000 queued
messages**, this package stops sending it events and emits a `Core.Notice`:

```elixir
%Core.Notice{
  kind: :degraded,
  severity: :warning,
  message: "subscriber #PID<0.123.0> is 10000 messages behind, past the 10000 bound — ...",
  details: %{subscriber: "#PID<0.123.0>", queue_len: 10_000, bound: 10_000, dropping: :newest}
}
```

and a second one, `severity: :info`, once you have drained below **half** the bound (5,000 by
default). Not merely back under it: a mailbox hovering at the bound used to flip on every
message, with a notice each time, into the same full mailbox. Now one stall costs one pair.
**Those two notices bracket exactly
the window you have to reconcile** from the pull endpoints — that is what the pair is for,
and why the recovery notice exists at all rather than just the alarm.

Three things are worth knowing about the shape of this:

- **The newest is dropped, not the oldest.** A sender cannot remove a message from your
  mailbox; only you can. So what happens is that nothing further is added while you are over
  the bound. It is also the better trade: a quote that arrives while you are ten thousand
  messages behind is stale by the time you would read it, and the frames it would have
  displaced are no fresher.
- **Only you are affected.** Another subscriber keeping up keeps receiving everything. One
  slow consumer is never allowed to become an outage for the others.
- **`coverage/1` does not change.** It reports what the *venue* delivered to this package,
  not what this package forwarded to you. A symbol whose frames are being dropped for your
  backlog is still arriving, and reporting it as `:not_covered` would point you at the venue
  when the backlog is yours.

Notices themselves are never dropped, whatever your queue looks like — the notice telling
you that you are being dropped must not be the first casualty of it.

Raise or lower the bound at start:

```elixir
{DpExchange.Schwab, max_queue_len: 50_000}
```

Any positive integer. It must be an integer — a string or a float raises at `init/1` rather
than quietly falling back to the default, because a back-pressure setting you believe you
configured and did not is worse than not having configured one.

**If you are seeing these notices, the fix is on your side.** Consume in a process that does
nothing else, or hand the payload straight to a queue or an ETS table and do the work
elsewhere. The bound is not a tuning knob for throughput; it is the line past which this
package stops writing into memory you are not reading.

## Telemetry: attach one handler, see every venue

This package emits the `:telemetry` events `DpExchange.Core.Telemetry` documents. Attach to
the names, not to anything venue-specific:

```elixir
:telemetry.attach_many(
  "dp-exchange-metrics",
  DpExchange.Core.Telemetry.event_prefixes(),
  &MyApp.Metrics.handle/4,
  nil
)
```

`:provider` in the metadata is how you tell venues apart — one handler covers the whole
family.

**These names were documented long before anything emitted them.** If you attached a handler
before this version and saw nothing, that was not your venue being quiet:
`:telemetry.attach/4` against a name nobody emits succeeds, so an empty panel was
indistinguishable from no traffic. Every one of them fires now.

Four things to know before you build on them:

- **Telemetry is the metrics channel; `Core.Notice` is the action channel.** Telemetry is
  aggregate and lossy by design. Alarm on notices. Graph telemetry. Alarming on a gauge
  documented as droppable is how a missed sample becomes a page at 3am.
- **`:stop` fires for every outcome**, success or error. That is deliberate: a latency panel
  built on successes alone shows a venue getting *faster* exactly as it starts failing,
  because the slow calls are the ones dropping out of the sample. `:exception` is a separate
  event from a `:stop` carrying an error — an error result is the venue answering badly, an
  exception is this package failing to ask.
- **`retry_after_ms` is always milliseconds**, including where the venue's own header is in
  seconds. A panel summing a mixture of the two is wrong by a factor of a thousand without
  ever looking wrong.
- **`:bytes` may be absent from `[:dp_exchange, :link, :event]`**, and absent is not zero. A
  polling route has no frame, so there is no byte count that means what a socket's does.
  Treat a missing `:bytes` as "this route cannot measure that", not as no data.

`:endpoint` metadata is the request URL with the query string removed. Deliberate: telemetry
metadata reaches logs, aggregators and third-party exporters, and the query string is the one
part of a URL that can carry a token.

## Every capability claim is dated, and says what it was measured against

`capabilities/0` carries two provenance fields, and they are there to be read:

```elixir
caps = DpExchange.Schwab.capabilities()
caps.measured_at       # ~D[...] — when someone last checked
caps.measured_against  # what they checked: which documents, which endpoints, live or not
```

**`measured_against` is the one that matters when you are deciding how much to trust a
claim.** It distinguishes a figure measured live against the venue's API from one read off a
documentation page and never probed — and this package's own declarations contain both
kinds, stated per claim rather than as one blanket sentence.

A claim read from documentation is not worse, it is *different*: it is what the vendor says
it will do, which is the right basis for a ceiling you must not exceed and a weaker basis for
behaviour you are about to depend on. If your decision turns on the difference, read the
field rather than assuming.

`measured_at` going stale is a real thing that happens — venues change, and a declaration is
a claim about a real venue. `script/check_doc_sources.sh` reports the age on its weekly run
so it does not quietly get old, but nothing forces it: if you are relying on a capability in
a way you cannot afford to have wrong, check the date and, where it matters, verify against
the venue yourself.

## 15. Nothing is dialled until you subscribe

Supervising this package — `{DpExchange.Schwab, opts}` in your own tree, or
`DpExchange.Schwab.Supervisor.start_link/1` directly — starts a `Feed` that does **not**
reach the venue on its own. No `GET /userPreference`, no Streamer `LOGIN`, no poll —
until you call `subscribe/2` or `update_symbols/2` for the first time. Before that,
`status/1` reports `route: nil`, and `coverage/1`/`coverage_by_kind/1` report `%{}`, the
same honest "nothing has happened" answer this package already gives a symbol you
subscribed and that has not delivered yet.

This was not always true, and if you built against an earlier version it is worth
knowing what changed. Before 2026-09-07 this package dialled the venue unconditionally
at boot — `Feed.init/1` scheduled a continue that ran before any `subscribe/2` could
reach it, so a tree that supervised this package and never subscribed anything still
made a signed request and, on success, opened a live Streamer session, with no notice
about it either way. Every other venue in this family defers dialling to the first ask;
this one did not, until now. **If your consumer relied on data already arriving the
instant your supervision tree came up — with no `subscribe/2` call of your own — that
behaviour is gone.** Call `subscribe/2` explicitly, the same as you already do for every
other venue.

One consequence worth naming: if the Streamer cannot bootstrap, the `Notice{kind:
:degraded}` telling you so now fires on your first `subscribe/2` rather than at boot.
That is later than before for a consumer that does subscribe, and irrelevant for one
that never does — a feed nothing has asked anything of has no route to be degraded
about.

## A write the venue cannot deduplicate is sent exactly once, and never retried

`Core.HttpClient` retries any failure that is not a 4xx — a timeout, a connection reset, a
503. For a read that is right: asking the same question twice costs a request and nothing
else. For a write it is not, because those are precisely the failures where the venue may
have **received and acted on** the request before the connection broke. A retried order is a
second order, and you see one call and one answer either way.

So order-creating and order-changing calls here are sent once. A transport failure comes back
to you as an error, and **the outcome of that attempt is genuinely unknown** — the order may
or may not exist at the venue. Read your open orders before placing again; do not treat the
error as "it did not happen".

This is not a blanket ban on retrying. It is a ban on repeating an action the venue cannot
tell apart from the first one. Reads still retry, and so does any write carrying an
idempotency key the venue honours.

## Error shapes that mean "do not act on this answer"

Returned by calls that previously answered `{:ok, _}` carrying a value you could not act on.
A consumer matching only `{:ok, _}` needs no change; one that enumerates error reasons
should know them.

`{:error, {:undecodable_response, :schwab}}` — the venue answered `2xx` with a body this
package could not decode. The realistic cause is not malformed JSON from the venue; it is a
`2xx` that never reached the venue, such as a captive portal or a CDN maintenance page
answering `200 text/html`. **Worth retrying**: nothing about the request was wrong. This
package used to substitute an empty object for such a body, which then decoded into a
well-formed value with every field `nil` and was returned as success.


**On `get_price/2` this replaced a false statement about the venue's listings.** An
undecodable body became an empty object, an empty object has no key for the symbol, and a
missing key means `{:refused, :not_listed}` — permanent, not worth retrying. So a maintenance
page came back as "Schwab does not carry AAPL". `{:refused, :not_listed}` still means exactly
what it says; it is now only ever reached from a `2xx` whose JSON object genuinely omits the
symbol, which is the venue's own way of saying so.

## Streaming calls answer; they never exit your process

`subscribe/2`, `unsubscribe/2`, `update_symbols/2` and `subscribe_notices/1` return
`{:error, :feed_not_started}` when this venue's feed is not running (`unsubscribe/2`
answers `:ok`: there is nothing to stop). They return `{:error, :feed_timeout}` when the
feed is too busy to answer within its call budget, and `{:error, {:feed_exited, reason}}`
when it dies while answering. `coverage/1` and `coverage_by_kind/1` answer an empty map in
all three cases, which means "not observed". Treat `:feed_timeout` as transient and retry.
Treat the other two as a feed your supervision tree has to bring back.

**A symbol set must be a list.** Anything else answers `{:error, {:invalid_symbols, value}}`
from all three, as a list holding a symbol this venue refuses already did, and the feed is
left as it was. It used to raise inside the feed, which restarted from its boot-time
options and lost every subscription. The `:symbols` start option is held to the same rule:
a pair-shaped or non-list value stops the feed at start with an `ArgumentError` naming it,
where it used to be sent to the Streamer unchanged. `DpExchange.Schwab.Fake` refuses the
same sets.

**Arguments are judged before the feed is looked at, and `unsubscribe/2` judges every
element.** `subscribe/2`, `unsubscribe/2` and `update_symbols/2` check the symbols (a proper
list of non-blank equity or option strings), then `subscribe/2` and `subscribe_notices/1`
check `:to`, and only then answer `{:error, :feed_not_started}`; so a malformed argument
answers the same whether or not the feed runs. `unsubscribe(nil)` and
`unsubscribe(["AAPL", :x, 42])` are `{:error, {:invalid_symbols, value}}` (they used to be
`:ok`). `subscribe([])` registers the subscriber and opens nothing: no `GET /userPreference`,
no socket, until a call names a symbol. A feed given as a pid on another node answers as a
feed that is not started, and no longer raises.

**A `401` or `403` on the fallback poll is an outage, not a refusal.** It used to be
reported as `{:refused, symbol, _}` for every wanted symbol, which a consumer reads as "the
venue does not carry this" and answers by dropping the symbol. It is now an ordinary failed
cycle: retried, and surfaced by the poll's "delivered nothing" `:coverage_change` notice.
Refresh the credential and call `update_credentials/2`.
