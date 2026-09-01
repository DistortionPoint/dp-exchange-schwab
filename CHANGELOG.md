# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Status: EXPERIMENTAL

Stated here rather than only per-release, because a reader arriving at a specific
version needs it as much as one reading the top.

This package has not run in production. While it is `0.x` the API may change without a
major version — pin three-part (`~> 0.1.0`). Maturity is declared **per endpoint**
through `capabilities/0`, not per package.

**Nothing here has been probed against the live API**, and on this venue that is
structural rather than temporary. Every Schwab endpoint requires OAuth credentials this
repository must never hold, and **the venue publishes no sandbox** — Schwab writes that
Trader API sandboxes "will be available later this year" in a document published
2025-10-30, and neither specification declares a non-production server. So there is
nowhere to exercise this package that is not somebody's real money.

That caps the evidence at tier 1 (D7): reading a specification says what a venue is
*documented* to do, never what it does. No endpoint is `:proven` and none can become
`:proven` here — that happens when a consumer trades live.

**Whenever an endpoint moves to `:proven`, the entry that does it states the evidence** —
which venue, what was run against it, and when. "Marked proven" with no evidence is not
an acceptable changelog line.

## [Unreleased]

### Changed

- **Core dependency moves to `~> 0.1.36`**, and `place_orders/3` is declared **absent with
  the reason**: this venue places one order per request. A batch is one request the venue
  accepts or rejects as a unit, and a caller placing several here calls `place_order/3`
  several times and reconciles the outcomes itself.

### Added

- **The eleven REST endpoints this package did not reach** — the single-symbol quote, option
  chains and expirations, movers, one market's hours, an instrument by CUSIP, the account
  summaries and positions, orders across every account, transactions and one transaction,
  and `/userPreference`.

  **Four of them were declared absent on a claim about the package, and the declaration said
  so.** Option chains, expirations, movers-as-a-screener and positions-via-the-accounts-
  endpoint were all published by the venue and unimplemented here; `venue_does_not_serve`
  named them as this package's gap rather than the venue's, which is the distinction this
  package had to learn the hard way about streaming.

  **The chain is Schwab's shape and this is the type it was designed around.**
  `callExpDateMap` and `putExpDateMap` are keyed by expiry-then-strike, and the expiry key
  carries the venue's days-to-expiration after a colon — a countdown from *today*, dropped
  because it would be stale as a key. A strike listed on one side keeps a `nil` on the other,
  and an expiry or strike this package cannot read is **refused by name** rather than
  dropped: a hole in a chain that looks complete is worse than an error.

  **`underlying_price` is carried only when the venue sent it**, which needs
  `include_underlying_quote`. `nil` means it was not in the response, not that the underlying
  has no price — and a chain valued against a price fetched separately is two observations
  at two times.

  **Four of `/chains`'s seventeen parameters are model inputs, not filters.** `volatility`,
  `underlyingPrice`, `interestRate` and `daysToExpiration` are what Schwab prices an
  analytical chain with, and this package supplies none of them: sending one would price a
  chain against a number the package invented.

  **Positions come out of the account and Schwab reports long and short as separate
  quantities.** Both are positive and `:side` says which; a row with both zero is a closed
  position the venue still lists, and is skipped rather than reported as an open position of
  size nothing. `liquidation_price` is `nil` — Schwab publishes none per position, and that
  is not safety.

  **Two endpoints have required parameters this package refuses to default.** `/orders`
  needs both ends of a time window; `/transactions` needs a window **and a type list, and
  its enum has no "all"** — `transaction_types/0` lists the fifteen, and passing all fifteen
  is how a caller asks for everything. A window or a type set chosen here returns a real
  answer over the wrong period or missing whichever kinds it left out, and an empty result
  reads as "nothing happened".

  A mover universe or a market outside the venue's enums is refused before the request: a
  ticker sent to `/movers` is not a smaller mover list, it is a 404.

### Changed

- **Core dependency moves to `~> 0.1.34`**, and eleven money-movement callbacks are declared
  **absent with the reason**: a stock broker moves money through cheques, ACH and wires
  arranged with a person, not through an API, and the Accounts and Trading specification has
  no payment method, transfer, allowlist or network list — nor an FX, notional-valuation or
  custody endpoint. `get_transactions/2` *reports* money that moved and is served.


- **`DpExchange.Schwab.Socket` — the Streamer connected.** `websockex` is now a dependency;
  `mix.exs` said to add it "when it is implemented, and not before", and it is.

  **LOGIN is a gate, not a greeting.** The vendor: *"This must be successful before sending
  other commands."* The socket tracks whether login succeeded and **refuses a subscription
  before it has** — a package that sent `SUBS` on connect would have it silently ignored and
  then wait for data that never arrives, which looks exactly like a quiet market. Login is
  asynchronous, so `subscribe/5` before the *response* returns rather than sending a frame
  the venue drops.

  **`:link_up` waits for the login response**, not the TCP connection. Announcing it on
  connect would tell a consumer the feed is live while the venue is still ignoring every
  command.

  **A rejected login still arrives as a response.** `succeeded?/1` checks the code inside
  `content`, and a rejection emits a `:degraded` notice carrying the venue's own message
  rather than leaving the socket to wait forever.

  **Reconnection is not resubscription.** A disconnect clears both the logged-in flag and
  the recorded subscriptions: the venue's session is gone, and a socket that kept believing
  it was subscribed would report a healthy feed that receives nothing.

  **A `LEVELONE` frame emits both a `Quote` and a `TopOfBook`** — one frame, two facts — and
  emits only the top of book when the venue reported no traded price. A service with no
  field map emits **nothing** rather than a value decoded with another service's numbering;
  a heartbeat is not data; and a malformed frame is dropped rather than taking down a live
  feed.


- **The two screeners and `ACCT_ACTIVITY`.** Fourteen of the fifteen services now have field
  maps; `ADMIN` has none because it is the login/logout channel and carries no market data,
  and that gap is asserted rather than left to be noticed.

  The screeners keep `sort_field` and `frequency` alongside the items, because **the same
  symbol returns a different list at a different sort** — a caller storing results without
  them cannot tell two screens apart.

  **`ACCT_ACTIVITY` is keyed on strings for two of its four fields**: the vendor names
  `"seq"` and `"key"` literally and numbers only the rest, so a decoder assuming every key
  is a number would drop both. `seq` is kept for the reason the vendor gives it — a client
  that reconnects can tell which messages it already saw, and **dropping it makes a replayed
  activity indistinguishable from a new one**, which is an order fill counted twice.

  `message_data` is left as the venue sent it. Its shape depends on `message_type` and the
  vendor publishes no schema per type in this document; decoding it on a guess would turn an
  unknown activity into a wrongly-shaped known one.


- **The three book services — `NYSE_BOOK`, `NASDAQ_BOOK`, `OPTIONS_BOOK` — with an
  `OrderBook` decoder.** These are the depth services this package declared `:unsupported`
  while saying the venue had no streaming API at all.

  **All three share one field table**, which the vendor documents once and names the three
  against — the only place in the Streamer where a shared map is correct, and the contrast
  with the `LEVELONE_*` services is the reason the others are separate.

  **A book frame carries the venue's own timestamp** at field 1, unlike the `LEVELONE_*`
  frames. A book without it is refused rather than stamped on arrival: a depth snapshot
  wearing the client's clock cannot be told from a current one.

  Each level is `[price, aggregate_size, market_maker_count, market_makers]`. The size kept
  is the venue's **aggregate**, not a sum over the makers — those differ when attribution is
  partial. The per-maker ids, sizes and quote times are **dropped**, which is a real loss on
  a lit book and is named here rather than left silent. `sequence` is `nil`: the Streamer
  publishes none on a book frame, so a caller cannot use one to detect a dropped update.


- **Field maps for the four `LEVELONE_*` services, and they disagree with each other more
  than expected.** Transcribed from the vendor's numbered tables, 2026-09-01:

      field 1   EQUITIES bid        OPTIONS description
      field 6   EQUITIES ask_id     FUTURES bid_id      FOREX total_volume
      field 7   EQUITIES bid_id     FUTURES ask_id

  **`LEVELONE_FUTURES` swaps the two exchange identifiers relative to `LEVELONE_EQUITIES`.**
  A shared map would report the bid's exchange as the ask's on every futures frame — and
  both values are real exchange codes, so nothing downstream would notice. `LEVELONE_OPTIONS`
  diverges from field 1 onward and carries its sizes at 16–18 rather than 4–5, where
  equities put them and where options put the last *price*.

  This is what the per-service design was for, and the transcription confirmed it rather
  than the other way round.


- **The Streamer's protocol, bootstrap and decoders — the API this package spent a year
  saying the venue did not have.**

  `StreamerInfo` reads `GET /trader/v1/userPreference`, which is the bootstrap. **The socket
  URL is issued per account and is not a constant**, and the same response carries the four
  identifiers `LOGIN` requires — none derivable from anything this package holds. The venue's
  own error notes say a client that changes `SchwabClientCustomerId` or
  `SchwabClientCorrelId` after logging in loses the connection, so they are fetched once and
  carried. **A missing field is an error**, because a `LOGIN` sent without one is refused
  with a message about the connection rather than about the field.

  `StreamerProtocol` builds the six commands and classifies the three frame kinds.
  **`subscribe/5` has no default command**: the venue's `SUBS` *replaces* every prior symbol
  for a service and `ADD` accumulates, so a package defaulting to `SUBS` for an incremental
  subscribe silently unsubscribes everything the caller already asked for — and the caller
  just sees the feed go quiet. A frame carrying none of `response`, `notify` or `data` is
  refused rather than read as data, because a heartbeat read as a quote is a price that
  never traded. **`succeeded?/1` checks the code inside `content`**: a rejected `LOGIN` still
  arrives as a response, and a package checking only that one arrived waits forever for data.

  `StreamerFields` holds the field maps **per service, because the numbers are not shared**.
  Field 1 is the bid in `LEVELONE_EQUITIES` and the open in `CHART_EQUITY`; one global table
  would decode a candle's open as a bid on every chart frame. A service with no map is an
  error rather than a fallback, and unnamed numbers are dropped — an unnamed field is
  absent, where a guessed name is wrong. Field 12 is named `:previous_close` because the
  vendor says it is the *previous day's* close.

  `StreamerDecode` turns frames into `Quote`, `TopOfBook` and `Candle`. **A `LEVELONE` frame
  carries bid, ask and last, and only `last` is a traded price** — a frame without it yields
  `{:error, :no_traded_price}` rather than a quote priced from a resting order. The quote's
  volume is the trade's own `last_size`, not the day's aggregate. A `CHART` bar without
  `chart_time` is refused rather than stamped on arrival: it would land in the series at the
  wrong minute with every value still real.

  Transcribed from the vendor's prose documentation at
  `docs/reference/schwab/documentation/market-data-production.txt`, 2026-09-01.

  **Not yet connected.** This is the protocol, not the transport; the socket itself and the
  remaining eleven services' field maps follow.

### Changed

- **`convert/4` and `get_trade_volume/2` (Core 0.1.22) are declared unsupported, for
  different reasons.** Asset-for-asset conversion is not something this venue does at all —
  Schwab is an equities and options broker and its equivalent is placing an order.
  `get_trade_volume/2` is absent from the Accounts and Trading specification: the account
  reports transactions, not an aggregated volume series.


- **Core 0.1.21's three new callbacks are declared, each read from the specification.**
  `/accounts/{accountNumber}/previewOrder` prices an order that does not exist yet and
  there is no `previewReplaceOrder`, so `preview_replace/4` has no endpoint — replacing is
  `PUT` on the order itself, priced only by making it. Cancelling is `DELETE` on one order,
  so there is no bulk cancel. Positions are read through the account and closed by placing
  the order yourself, which sizes against the last read rather than against the position
  now — so there is no `close_position/3` either.

  Recorded against the Accounts and Trading Production specification, 2026-09-01. This is
  the package that spent a year asserting the venue had no streaming API when it had
  fifteen services; absence here is read, not assumed.

### Fixed
- **This package no longer claims Schwab has no streaming API.** It does: a WebSocket
  **Streamer** with 15 services, including `NYSE_BOOK`, `NASDAQ_BOOK` and `OPTIONS_BOOK` for
  depth and `ACCT_ACTIVITY` for order and fill events. It is documented in the prose beside
  the two OpenAPI specifications and absent from both, which is how the error was made — the
  specifications were read and the prose next to them was not.

  Corrected in `mix.exs`, `DpExchange.Schwab`, `Feed`, `Capabilities`, `README.md` and both
  copies of `usage-rules.md`. **No capability value changed**: `get_order_book/2` remains
  `:unsupported` and `streamable` remains `[:quotes]`, because this package still cannot read
  depth. Only the recorded *reason* changed, from a false claim about the venue to a true one
  about the package.

- `usage-rules.md` §9 retitled from "What this venue does not have" to "**What this package
  does not implement**", and now says which of the listed capabilities the venue really does
  publish — `get_order_book/2` and `get_trade_history/2` both exist upstream.

### Added

- **`get_trades/2`, `get_auction_imbalance/2` and `get_volume_profile/3` are declared
  unsupported, read rather than assumed.** The Market Data Production specification
  publishes quotes, price history and movers and **no trade tape**; Schwab's equities do
  trade in opening and closing auctions and the venue publishes no imbalance feed through
  this API, nor a volume-at-price split. Checked 2026-09-01 — this is the package that spent
  a year asserting the venue had no streaming API when it had fifteen services.

- `docs/reference/schwab/portal-product-landscape.md` — the developer portal publishes **24
  products**; **7** are visible to this account and **1** is entitled. The other six return
  `204` from `lob-access/Status`, and Crypto and Thinkorswim are not among the seven at all.
  No credential this project holds reaches them, so Schwab's addressable surface is the
  Trader API and nothing further.
- `docs/reference/schwab/user-guides/` — the portal's 17 User Guides, never previously
  captured. Two matter here: **Authenticate with OAuth** and **OAuth Restart vs. Refresh
  Token**, the latter being the document that draws the package/host auth boundary.

### Added
- `DpExchange.Schwab.Capabilities` — the venue's declaration, derived from the two
  OpenAPI documents committed under `docs/reference/schwab/` **before** any provider was
  written. `docs/reference/schwab/spec-facts.md` names the schema or parameter behind
  every value.
- **The full Schwab documentation set**, captured 2026-08-28 from an authenticated
  portal session and committed so no reader needs to log in: both OpenAPI documents
  unwrapped and pretty-printed (`openapi/`), both Documentation tabs as verbatim HTML and
  repaired reading copies (`documentation/`), and the raw portal responses
  (`portal-raw/`). The portal returns `403` to an anonymous reader and publishes no
  OpenAPI document anywhere, so this reference cannot be re-fetched — which is exactly
  why it travels with the code.
  **The portal's spec response carries the signed-in account's live `appKey` and
  `appSecret`**, because that endpoint also feeds the "Try it" console. Both are redacted;
  the redaction is the only edit made to any captured file and is recorded in that
  directory's `README.md`. Anyone re-capturing must redact again before staging.
- `DpExchange.Schwab.Auth` — signing, **and access-token refresh**. Per §6.0 credential
  *storage* is host-side while credential *use* — signing, session refresh, token
  rotation — is venue strategy that crosses into the package, and Schwab splits along
  that line exactly. The access token lives **30 minutes**, so a package that only signed
  would hand back an expired token twice an hour and be unusable unattended. `refresh/2`
  is a machine-to-machine `POST` with no human in it. Only the initial three-legged grant
  — a browser, a person, a redirect — stays with the host, because nothing else can do it.

  **The refresh token is one-time use and every refresh mints a new one**, itself valid
  for a fresh seven days (Step 4's response block, `"refresh_token": … //Valid for 7
  days`). So there is **no weekly ceiling on unattended operation**: a host refreshing
  every half hour rolls the window forward every half hour and never needs a person
  again. The clock only runs out if refreshing stops for a week, or the user resets their
  Schwab password.

  Three consequences the code enforces, because each failure is unrecoverable without a
  person rather than merely inconvenient:
  - **A success with no replacement token is an error**
    (`{:error, :missing_rotated_refresh_token}`), never a credential to keep. The token
    just sent is spent, so carrying it forward would hand back something guaranteed to
    die at the *next* refresh — days later and far from the cause.
  - **A refresh is never retried.** It is at-most-once: a retry after a timeout re-sends
    a token that may already have been spent, while its replacement sits in a response
    nobody read. `:retry_attempts` is dropped from the caller's options and forced to
    zero, so it cannot be switched back on by accident.
  - **The result must be persisted before use.** Refreshing and then crashing before
    storing costs the grant.
- `DpExchange.Schwab.SymbolFormat` — mostly a refusal, because a symbol here names one
  instrument rather than a pair. `BTC`, `ETH` and `SOL` are all real listed equity
  tickers, so a misrouted crypto pair has a **plausible wrong answer** available: an ETF
  holding nothing like the coin, quoted in dollars, indistinguishable downstream from a
  real price.

  **Translation and validation are separate functions, and the split is forced.**
  `Core.SymbolNormalizer` requires `to_exchange_symbol/1` to be *total* — the conformance
  suite asserts the round trip over arbitrary input — while a caller about to spend a
  request must refuse first. So `to_exchange_symbol/1` and `to_canonical_symbol/1`
  translate and judge nothing; `validate/1` returns `{:ok, native} | {:error, reason}` and
  is what `Rest`, `Orders` and `Fake` call. A transformation that cannot fail may return a
  string; a validation may not.
- `DpExchange.Schwab.Rest` — both servers behind one module: `/marketdata/v1` for quotes,
  candles, market hours and instrument search, `/trader/v1` for accounts, balances and
  orders. A consumer sees neither (D12).

  Candles refuse in two distinct ways, because they mean different things:
  `{:error, {:unsupported_timeframe, tf}}` for a width the venue does not serve, and
  `{:error, {:lookback_exceeds_venue, tf, requested, max}}` for a width that exists but
  cannot reach that far back. The second is the one that matters — ten days of minutes, or
  a year of dailies, are both plausible wrong answers sitting right there.

  **`get_symbols/1` requires a `:query`**, returning `{:error, {:query_required, :schwab}}`
  without one. `/instruments` has no list-everything projection, so the catalogue cannot be
  enumerated, only searched. Deliberately not `:not_supported` — the endpoint works.

  **Accounts are addressed by an encrypted hash, not an account number**, so
  `get_accounts/2` is a prerequisite for the whole trading surface. Balances read the
  account's declared `type`: `MarginAccount` and `CashAccount` carry entirely different
  fields, and an untyped account is unreadable rather than assumed — reading a margin
  account as cash would report no buying power for one that has it.

  A placed order returns `201` with an **empty body** and its id in `Location`. A `201`
  with no `Location` is `{:error, :order_id_not_returned}`, because a caller that cannot
  name the order it just placed cannot cancel it.
- `DpExchange.Schwab.Orders` — builds the single-leg `SINGLE` strategy `place_order/3`
  corresponds to, and **enforces Schwab's own published instruction-by-asset-type matrix
  before sending**. Order writes are throttled on this venue and reads are free, so a
  rejection the documentation already predicted must not cost one of them. `session` and
  `duration` are on every order because every documented example carries them, and
  `session` has no slot in `Core` at all.

  Multi-leg spreads, `TRIGGER` and `OCO` nest whole orders in `childOrderStrategies` and
  are unreachable through the contract. Recorded as a Core gap rather than worked around:
  inventing a request shape would put venue vocabulary into consumer code.
- `DpExchange.Schwab.Feed` — a REST poll behind `Core.PollingFeed`. It does **not** stop
  itself when the market closes: pausing would make "closed" and "crashed" look identical
  from outside, and pre/post-market are real trading windows.
- `DpExchange.Schwab.Supervisor` — a limiter and a feed, like every venue. The limiter is
  **configured rather than declared**, because Schwab has no venue-wide ceiling to declare.
- `DpExchange.Schwab.Fake` — an in-process stand-in that **refuses what the real venue
  refuses**, including the ten-day lookback cap and the instruction matrix. It is also the
  only place in the family where the **closed-market path** can be exercised.

### What this venue taught the contract

Seven things `Core` could not express until this package needed them. All seven are now in
`dp_exchange_core`, and this package uses every one:

- **`preview_order/3` and `replace_order/4`** are facade callbacks, and this is the only
  venue that implements either. `previewOrder` validates an order and estimates its cost
  without placing it; `PUT .../orders/{id}` amends atomically and returns a **new** order
  id, because Schwab treats a replacement as a new order.
- **`supported_sessions`** — every documented order carries a `session`, and nothing in a
  family of continuously-trading crypto venues had a slot for it.
- **`catalog_access: :query_only`** — `/instruments` has no list-everything projection.
  Core's conformance suite asserted "every venue can be pulled", which is true here and
  only by search.
- **`ceiling` `:scope` and a zero `:limit`** — the order ceiling is per *account*, set per
  *application at registration*, and **zero is a legal registration**. A limiter keyed by
  credential would silently over-permit; a zero collapsed into `nil` would read as "no
  limit" rather than "none granted".
- **Four order types** — `TRAILING_STOP`, `TRAILING_STOP_LIMIT`, `MARKET_ON_CLOSE`,
  `LIMIT_ON_CLOSE`. This package declared four for a venue that serves eight.
- **Eight instrument types** — this declared `[:spot]` with a comment saying that
  understated the venue. It now names nine.
- **`supports_multi_leg_orders`**, declared **false** even though the venue has `TRIGGER`,
  `OCO` and net-priced spreads. `place_order/3` takes a flat request, and growing it a
  `:legs` key would put venue vocabulary into consumer code. The field makes the boundary
  visible instead of leaving it to be discovered.

### Notable in the declaration

- **Eight candle widths** — `1m 5m 10m 15m 30m 1d 1w 1M`. A width is a
  `(periodType, frequencyType, frequency)` triple whose combinations are constrained in
  both directions, and **the minute widths are reachable only through `periodType=day`,
  which caps the lookback at ten days.** A year of one-minute data cannot be served and
  must be refused rather than answered with a coarser series.
- **`:ioc` and `:fok` are declared as time-in-force, not order types.** Schwab spells them
  as `duration` values. `:post_only` and `:gtd` are **absent, not approximated** —
  `NON_MARKETABLE` is close and is not post-only, and `END_OF_WEEK`/`END_OF_MONTH`/
  `NEXT_END_OF_MONTH` are three fixed horizons, not an arbitrary date.
- **`max_leverage: :per_account`.** A margin account carries five different buying powers
  that are not multiples of one another, and a cash account at the same venue carries
  none of them, so no single number is true. This required Core to gain `:per_account`.
- **`authenticated_ceiling: nil`.** The documented limit is `0..120` order writes per
  minute *per account*, set *per application at registration* — a property of somebody's
  registration rather than of the venue. Reads are unthrottled for orders; market data
  has no documented limit, recorded as unmeasured rather than as unlimited.
- **No order book, no fee schedule, no transfers, no socket.** Nothing in either
  specification returns depth or describes a streaming surface; the feed will be a REST
  poll. `previewOrder` returns per-order commission, which is not a fee schedule.

### Requires

`dp_exchange_core ~> 0.1.11`. Three Core changes landed for this package, all of them
defects this venue exposed:

- **`Timeframe.nameable/0`** — the widths Core can *name*, wider than `known/0`, the widths
  it can *bucket*. `Capabilities` **and** the conformance suite both checked declarations
  against `known/0`, so a venue serving `1w` or `1M` could not declare them — while
  `Timeframe`'s own moduledoc already documented both as deliberately unbucketable. Core
  contradicted itself, and a venue serving a real weekly candle had two options:
  under-declare, or not ship.
- **`Timeframe` now models `10m`.** Its absence was not neutral: `aligned?/2` answers
  `true` for a width it cannot model, so every 10-minute candle passed the authenticity
  check unexamined.
- **`max_leverage: :per_account`** — see above. Without it, shipping meant declaring
  `supports_margin: false`, which is false, or inventing a multiplier.
