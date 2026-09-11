# Using `dp_exchange_schwab`

Rules for an agent or developer writing code against this package. Read this before the
README; it is what the Hex tarball ships for consumers.


## BREAKING — `Quote` and `OrderBook` no longer carry `:timestamp`

They carry **`:venue_time`** (the venue's own, `nil` where the venue publishes none) and
**`:observed_at`** (when this package read it, always present) — the shape
`Core.Types.TopOfBook` has always had. Requires `dp_exchange_core ~> 0.2.1`.

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


**When is `venue_time` `nil` on this venue? On every streamed quote.** `LEVELONE_*` frames
carry no venue time in the fields this package reads, so a `Quote` from `subscribe/2` always
has `venue_time: nil` and a real `observed_at`. That is not a gap — it is the fact the split
exists to state, and before 0.2.0 this package put the frame's arrival time in a field
documented as the venue's own.

The **book** is the opposite and always was: `to_order_book/2` reads the venue's
`snapshot_time` and fails closed without it, so an `OrderBook` always carries a real
`venue_time`. `get_price/3` over REST does too.

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
will not fix it.

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
`{:error, {:missing_account_hash, :schwab}}` — the same atom every other account endpoint
here uses. It answered `{:account_hash_required, :schwab}` until 2026-09-07: one condition
with two spellings, so a consumer handling "you forgot the account hash" uniformly could
not. There is no "all" in the venue's type enum —
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
`:order_limit_per_minute`. **State your own ceiling if you place orders at all**, matching
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

## 13. Making the fake fail on demand

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
fails, the rest succeed". `coverage/1`, `coverage_by_kind/1` and `subscribe_notices/1` are
local bookkeeping that always succeeds by construction. And not yet wired, stated here
rather than left to be discovered: `get_option_chain/2`, `get_option_expirations/2`,
`get_screener/2`, `get_transactions/2` and `get_rate_limit_status/2` — they gate credentials
correctly but cannot yet be made to fail on demand.

## 14. A reconnect resubscribes on its own; a crash costs one retry, never a lost consumer state

The Streamer socket and the fallback poller are both **linked** children of `Feed` — not
supervised siblings you can restart independently. `Feed` traps exits, so either one
dying abnormally does not take `Feed` down with it: `coverage/1` and `coverage_by_kind/1`
clear (this feed has exactly one active route at a time, so a crash costs everything it
was delivering, not a partial set), you get a `:link_down` `Core.Notice`, and this
package retries the route on its own — a fresh Streamer bootstrap if the credential
still works, falling back to the poll otherwise. You never need to call `subscribe/2`
again for this.

**An ordinary reconnect — no crash, just the venue dropping the TCP connection — also
resubscribes on its own**, on a 60-second unconditional timer: `Socket.handle_disconnect/2`
clears the venue's own subscriptions on every reconnect (see `Socket`'s own moduledoc),
and `Feed` re-issues your `wanted` symbols whether or not it can tell a reconnect
happened. Worst case, up to 60 seconds of silence after a reconnect before delivery
resumes on its own — sooner if you notice `:link_up` via `subscribe_notices/1` and call
`subscribe/2` or `update_symbols/2` yourself, which also re-issues immediately.

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

and a second one, `severity: :info`, when you catch up. **Those two notices bracket exactly
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
