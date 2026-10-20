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

### Security

- **The `:global` name that guards a refresh no longer carries an MD5 of the refresh token.**
  `Auth.refresh/2` registered `{:schwab_refresh, md5(refresh_token), scope}`, and
  `:global.registered_names/0` lists that to every connected node, so anyone able to read the
  cluster's names could confirm a guessed or leaked refresh token by hashing it. The name now
  carries `HMAC-SHA256(client_secret, refresh_token)`: it confirms nothing without the client
  secret, which no name carries, and it is still identical on every node for the same credential,
  which is what makes the guard reach the connected nodes (a per-node random key would give two
  nodes two names for one token). Behaviour is otherwise unchanged: the second overlapping refresh
  of a token still answers `{:error, {:refresh_in_progress, :schwab}}`, unsent.
- **The Streamer access token is judged before the socket exists, and travels wrapped.**
  `Socket.start_link/1` refuses a token that cannot be sent as it is (blank, padded, a control
  byte, or not valid UTF-8) as `{:error, {:missing_credentials, :schwab}}` or `{:error,
  {:invalid_credentials, :schwab}}`; a token that is not valid UTF-8 made the LOGIN's
  `Jason.encode!/1` raise with the whole binary in the exception message. `update_access_token/2`
  makes the same judgement and casts the token as a `Credentials` struct rather than a bare
  string, because OTP prints a crashing process's mailbox in its crash report; a cast carrying a
  token that fails the judgement is ignored and the token the next LOGIN presents stays as it
  was. `Feed` already judged the token it pushed, so this closes the direct callers.

### Fixed

- **A string of 64 bytes or more cut out of a large document no longer keeps the whole document
  alive.** A decoded JSON string of that size is a sub-binary that points into the response or
  Streamer frame it came from (shorter ones are already copied by the runtime on OTP 27+).
  `Bound.text/1` (the venue's `detail` and `message` in error tuples, and the `service` and
  `symbol` text in notices) returned one as it came, so a long error detail held the whole
  response body, and a notice held the whole many-row Streamer frame, for as long as anything
  held the tuple or the notice. It now returns a copy. The same copy is made for an option
  chain's contract text fields and its `underlying` and a position's `symbol`, venue text whose
  length the package does not control.

- `Feed`'s "Streamer still unreachable" debug line is built lazily, so the reason is no longer
  inspected on every retry when debug logging is off.

### Changed

- **Two trees in one VM need only distinct `name:`s.** A tree started with a non-default atom
  `name:` and no explicit `:feed`, `:limiter` or `:order_limit` now names those processes
  `Module.concat(name, Feed)`, `RateLimiter` and `OrderLimit`; before, a second tree on the
  defaults failed with `already_started` unless all four names were passed. The default tree
  keeps its fixed names exactly, and an explicit name wins. Every facade function now accepts
  `name:` (all of them address the limiter, the order record or the feed) and resolves the same
  derived names from it; `Supervisor.limiter_name/1`, `feed_name/1` and `order_limit_name/1` do
  the derivation. A `name:` that is not an atom derives nothing.
- **A forwarded `name: nil` is the default name,** not an unnamed supervisor
  (`Supervisor.start_link/1`, `Schwab.child_spec/1`). `Feed.start_link/1` keeps `name: nil` as
  "start unnamed", the seam a standalone feed (and the test suite) uses.

### Documentation

- `usage-rules.md` states the two-tree rule above, and that the refresh guard needs nothing,
  being derived from the credential.

## [0.2.145] - 2026-10-19

### Dependencies

- **Requires `dp_exchange_core ~> 0.3.111`** (was `~> 0.3.109`). That release refuses a GET with a body
  before sending (Req 0.7.0-0.7.2, which the Core floor admits, sent it as a retried POST) and
  refuses URL userinfo over plain http.

### Added

- **A credential whose `:expires_at` has passed is refused before anything is sent:
  `{:error, {:credentials_expired, :schwab}}`.** Every REST read, `preview_order/3` and every
  order write (`place_order/3`, `replace_order/4`, `cancel_order/3`) now asks
  `Auth.check_unexpired/1` after the token check and before the request, so a token the
  credential itself says is dead no longer spends a rate-limit slot (or a throttled order write)
  to be answered `401`. Absent, `nil` or non-`DateTime` `:expires_at` is not expired (as for
  `needs_refresh?/2`) and is judged by the venue; a token inside the 120 s refresh margin is still
  sent. `DpExchange.Schwab.Fake` refuses an expired credential with the same tuple, in the same
  order, and `Fake.refresh_credentials/2` now dates its new token from the real clock (as
  `Auth.refresh/2` does) rather than the fake's fixed `as_of/0`, whose thirty minutes are long
  over. Nothing in the package refreshes, retries or loops on a `401`: that stays the host's call.
- **Two overlapping `refresh_credentials/2` calls on one refresh token no longer both reach the
  venue: the second answers `{:error, {:refresh_in_progress, :schwab}}`, sent nothing.** The
  refresh token is assumed one-time use, so the second request could only be answered with a
  refusal that reads as a dead grant (`:reauthorization_required`), and a host persisting that
  answer overwrote the winner's good credential with a spent one. The guard is a `:global`
  name registered for the request (this node and connected ones), carrying a digest of the token
  and unregistered however the caller exits, a kill included. It closes the overlap only, not a
  caller that starts after the winner with a credential it read before, nor a node that is not
  connected: the host still owns ordering.
  Covered by `tick_an_credentials_test.exs`.

### Fixed

- **`vendor/websockex.ex` moduledoc said "exactly four" changes and "four marked changes" while
  listing six, and its call-site markers used three numbering schemes.** Diffed in full against
  `deps/websockex` 0.5.1: every other function body, `@spec` and callback is identical, and the
  difference is exactly the six documented fixes. The moduledoc now says six and maps each marker
  to its number. No behaviour change.
- **`usage-rules.md` stated three things the code does not do.** It required `dp_exchange_core`
  `~> 0.3.101` (it is `~> 0.3.109`); said `get_screener/2` drops an unnamed row and keeps the
  survivors' ranks (it refuses the whole list, `{:unreadable_screener_row, rank}`); and said
  `cancel_order/3` answers `:order_unconfirmed` like place and replace (a cancel keeps Core's plain
  `{:exchange_error, :schwab, _}`, as `Core.Venue` specifies). It also said the Fake does not
  provide `refresh_credentials/2` and the raw reads while another paragraph said it does; and an
  undecodable `2xx` on a refresh is now documented as not safely retryable.

## [0.2.144] - 2026-10-19

### Changed — BREAKING

- **A venue refusing a Streamer subscription is a `:refusal` notice, not `:degraded`.** A
  `SUBS`, `ADD` or `VIEW` the venue answers with a failure code (for example `19
  REACHED_SYMBOL_LIMIT`, `21 BAD_COMMAND_FORMAT`) now raises `Core.Notice` kind `:refusal` with
  `details.symbols` (the keys that command carried, remembered by request id and bounded at 256
  commands; `[]` when the socket no longer remembers it), `details.service`,
  `details.reason: :command_rejected` and the venue's text in `details.message`. `:degraded` means
  a slower path is in use (`Core.Notice` kind rules). A failed `UNSUBS` stays `:degraded`.
- **The Streamer's `:link_down` is one per outage.** `handle_disconnect/2` raised a
  `:link_down` notice and a `Telemetry.link_down/2` event for every redial that failed to
  connect, and for every connect-LOGIN-denied-close cycle, none of which a `:link_up` had
  closed. It now raises one, and re-arms on the next LOGIN that succeeds. Count redials with the
  `link_reconnect_attempt` event, which still fires on every attempt.
- **Order entry is EQUITY and OPTION only: `instrument_type: :mutual_fund` and `:cash_equivalent`
  are refused.** `Orders.build/2` sent them as `MUTUAL_FUND` and `CASH_EQUIVALENT`, but the
  vendor states "Order entry will only be available for the assetType 'EQUIT' and 'OPTION' as of
  this time" (`accounts-and-trading-production.txt:128`, `spec-facts.md` section 10: "the
  tradable set is two"). Both are now `{:error, {:unsupported_instrument_type, type}}` before a
  throttled write is spent. They stay in `capabilities().supported_instrument_types`: that list
  is what quotes and positions route, and the comment beside it now says so.
- **`replace_order/4` given an empty change map answers `{:error, {:invalid_order_request,
  %{}}}`** (conformance group 50), on the facade and the Fake. It used to answer
  `{:invalid_symbol, nil}` from building the empty map as a whole order. A non-map was already
  `{:invalid_order_request, v}`; `preview_order/3` already answers `place_order/3`'s refusal
  (now pinned by a test). New `Orders.build_replacement/2`.
- **`status/1` has one shape on every route.** `delivering` was a count on the Streamer route
  and a boolean (`Core.PollingFeed.status/1`'s type) on the fallback poll, which let a consumer
  tell how data reaches the package. It is now a boolean everywhere (some symbol has arrived).
  The count moved to `covered`, the poll route's `symbols` is `wanted`, and `failures_since_ok`
  (0 on the Streamer) is on both. Keys on every route: `route`, `delivering`, `wanted`,
  `covered`, `failures_since_ok`, `last_error`. `Fake.status/1` and a poller that did not answer
  (`delivering: false, covered: 0, last_error: :poller_unresponsive`) follow the same shape.

### Fixed

- **A feed stopped normally left its Streamer socket running.** `Socket` and the poller are
  linked to `Feed`, not supervised, and neither traps exits, so a `:normal` exit did not reach
  them: the socket reconnected forever, holding the venue's one Streamer connection per user.
  `Feed.terminate/2` now shuts both down.
- **Vendored websockex (`DpExchange.Schwab.Vendor.WebSockex`), two more fixes.** (5) A raise in
  the opening handshake (an upgrade response without `Sec-WebSocket-Accept` was a `MatchError`;
  a malformed header line is a `CaseClauseError` in the real `WebSockex.Conn`) killed the socket
  through the linked handshake task, skipping `handle_disconnect/2` and its backoff; it is now a
  `HandshakeError` / `ConnError` through the ordinary paths. (6) A close frame that could not be
  sent for any reason but `:closed`/`:einval` was a `CaseClauseError` from the very
  `{:close, state}` this package returns to end a failed or silent connection; it is now a
  closed connection (socket closed first) and `handle_disconnect/2` runs.

- **A Streamer frame the socket could not read was dropped in silence.** Unparseable JSON, a
  JSON frame that is not a `response`, `data` or `notify`, and a `notify` entry that is not a
  heartbeat (the vendor's `30 STOP_STREAMING` is an admin message) now raise one `:data_quality`
  notice per session, `details.reason` `:unparseable_frame`, `:unrecognised_frame` or
  `:unrecognised_notify` with `details.bytes`, never the content. On a venue that is quiet
  every night, a feed discarding everything looked like a quiet market.
- **`refresh_credentials/2` could raise after the refresh token was spent.** `opts[:now]` is read
  only once the venue has answered, and `now: nil` (a forwarded unset option; `Keyword.get_lazy/3`
  returns a present `nil`) or a value that is not a `DateTime` raised in `DateTime.add/3` in
  the caller's process, losing the rotated token with the one-time token already gone. A
  forwarded `nil` is now silence (the clock), and any other non-`DateTime` is
  `{:error, {:invalid_option, :now, value}}` before anything is sent (`Auth.check_now/1`,
  shared with `Fake.refresh_credentials/2`, judged after the credential and before the token
  URL).
- **A forwarded `nil` `:socket_connect_timeout` or `:socket_recv_timeout` reached the dial as
  its timeout** (`Keyword.put_new/3` keeps a present `nil`), raising `badarg` inside the connect.
  It now gets the deliberate default.
- **A forwarded `nil` `:rate_limit_blocking` turned the fallback poll fail-fast.** The `true`
  default was `put_new`, so a present `nil` kept the key and `Rest` then dropped it as silence;
  the poll ran with Core's fail-fast `check/3`, the "87 of 87 symbols delivering collapses to 8
  of 87" failure the default exists to prevent. `nil` now gets the default; an explicit `false`
  is still honoured.

### Documentation

- The refresh token's "one-time use" rule is now labelled as this package's safe ASSUMPTION in
  `Auth`'s moduledoc, `README.md` and `usage-rules.md`: no committed vendor document states it
  (the user-guides README said the accounts-and-trading document did; it does not, and now
  says so). `Auth`'s "what ends a grant" now lists the causes the portal's OAuth restart guide
  gives (revocation, credential or two-factor change, an aborted flow, policy change) beyond the
  seven days and a password reset. `Rest.get_movers/3`'s doc cites the Streamer's `SCREENER_*`
  reading of `frequency` as minutes without borrowing it for REST. The `orders_window_schema`
  fixture no longer carries `"closeTime": null` (the schema types it a date-time string).
- The facade (`lib/dp_exchange/schwab.ex`) labels the one-time-use refresh sentence as an
  assumption too. `coverage-matrix.md`'s Streamer section is rewritten to the code
  (`streamable` is `[:quotes, :top_of_book, :candles]`, depth and `ACCT_ACTIVITY` decoded but
  never subscribed, `get_order_book/2` `:unsupported`), the earlier wrong statements kept only
  as dated history lines, and `negative-claims.md`'s "No REST order book" row says
  this package does not subscribe depth. The Socket backoff test's comment no longer claims the
  vendored socket traps exits.
- Tests: the vendored close-frame send failure (`handle_local_close`) is exercised by filling
  the socket's send buffer against a server that never reads.
- `Auth`'s moduledoc and `usage-rules.md` section 3 state that two processes refreshing the
  same credential at once get one success and one `:reauthorization_required` that is not a
  dead grant, and that a host must refresh from a single owner.
- The delayed-quote notice and docs now say what the vendor says (`"delayed": true` is NFL data:
  delayed, or real-time from only a subset of exchanges), not that the account has no
  real-time entitlement.
- Audited and found consistent with `docs/reference/schwab`, no change: every Streamer field
  table in `StreamerFields` (LEVELONE equities, options, futures, futures options, forex, books,
  chart equity and futures), the REST quote, candle, chain, expiration, balance, position, order
  and user-preference readers, and every `Fake` body and refusal order against the facade.
  The vendor's generic Streamer example (`market-data-production.txt:112`) numbers its
  `LEVELONE_EQUITIES` fields one higher than the field table from field 12; the table is
  still the one followed (see `test/fixtures/spec_examples/README.md`).

## [0.2.143] - 2026-10-18

### Changed — BREAKING

- **`place_order/3`, `replace_order/4` and `cancel_order/3` no longer list `:retry_attempts`
  or `:retry_delay`.** An order write is always sent exactly once, so neither key is read:
  any value (`0` and `1` included) is `{:error, {:unknown_option, key}}` before anything is
  sent, on the facade and the Fake. Before, `:retry_attempts` was accepted when absent, `nil`
  or `0` and refused as `{:error, {:unsupported_option, :retry_attempts}}` otherwise, while
  the request quietly forced one attempt. `refresh_credentials/2` already refused both.
  `preview_order/3` keeps both (it is retried). `Options.check_error` loses its
  `{:unsupported_option, :retry_attempts}` member.
- The read-back after an accepted `place_order/3` / `replace_order/4` is a single attempt, so
  a failing read no longer holds the caller in backoff after the order is already placed.

### Fixed

- **A venue value quoted into an error tuple is bounded.** `{:unreadable_level, side, value}`
  (order-book decode) and `{:invalid_decimal, field, value}` / `{:non_positive_price, field,
  value}` (REST quotes and bars) carried the venue's value whole, so a huge string, object or
  list where a level or price belongs rode into the caller's error and every log. A value up to
  512 bytes (external size) is still returned as sent; a larger one is cut like the rest of the
  package's venue text (`Bound.text/1`, `bounded_raw/1`).
- `Rest` builds a request path's segments with a prepend and one reverse rather than `++` in
  the reducer (no behaviour change).

## [0.2.142] - 2026-10-18

Depends on dp_exchange_core 0.3.105 (conformance group 46: a call that sends no request takes no transport key).

### Changed

- **A shared transport key is allowed on a call only when the call reads it.** A call that
  sends no HTTP request (`subscribe/2`, `subscribe_notices/1`, `unsubscribe/2`,
  `update_symbols/2`, `update_credentials/2`, `coverage/1`, `wanted/1`, `coverage_by_kind/1`,
  `status/1`) now allows only its own keys and `:credentials`: `timeout:`, `plug:`,
  `max_body_bytes:` and the rest answer `{:error, {:unknown_option, key}}` (the plain-value
  reads raise `ArgumentError`), on the facade and the Fake. They used to be accepted for
  "uniformity" and read by nothing. `:retry_delay` is likewise refused on the three order
  writes (one attempt, no wait), and `:retry_attempts` and `:retry_delay` on
  `refresh_credentials/2` (never retried, whatever the caller asked).
- **`:max_retry_after_s` is now forwarded on the order writes and on `refresh_credentials/2`.**
  It was dropped there although Core reads it on a 429 even with no retry (it clamps the
  `Retry-After` the limiter is penalised for).

## [0.2.141] - 2026-10-18

Depends on dp_exchange_core 0.3.103 (conformance groups 44, fake export parity, and 45, notice shapes).

### Changed — BREAKING

- **`:environment` and `:base_url` are refused on every facade function and on the Fake**
  (`{:error, {:unknown_option, key}}`). `Core` lists them as shared transport keys, but this
  venue has one environment and no call read either: the base URLs are `:market_data_url` and
  `:trader_url`. A `base_url:` that was accepted and did nothing sent a live token to the
  production host from a caller who believed it had redirected the call.
- **`:retry_attempts` on `place_order/3`, `replace_order/4` and `cancel_order/3` is refused
  unless absent, `nil` or `0`**: `{:error, {:unsupported_option, :retry_attempts}}` before
  anything is sent, on the facade and the Fake. It used to be accepted and silently not
  honoured. Schwab has no idempotency key, so a retry could place an order twice.
- **A streamed frame dropped for an unreadable value is announced as `:data_quality`, not
  `:degraded`** (`details.reason: :frame_unreadable`, an atom; the text is in
  `details.message`), per the family rule that an undecodable payload is `:data_quality`.
  `:delayed_quotes_withheld` stays `:degraded`: the payload decodes, the account lacks the
  entitlement.
- **`get_symbols/1` refuses a `:projection` outside the venue's six** (`symbol-search`,
  `symbol-regex`, `desc-search`, `desc-regex`, `search`, `fundamental`) as `{:error,
  {:invalid_projection, value}}`, before a request is spent learning it; the Fake agrees.

### Fixed

- **`:adapter`, `:weight`, `:retry_delay`, `:max_retry_after_s` and `:max_body_bytes` were
  accepted on every REST call and silently dropped.** They are now forwarded to
  `Core.HttpClient` (the order writes take `:adapter`, `:weight` and `:max_body_bytes`; their
  attempt count stays fixed at one, see the `:retry_attempts` entry above). A forwarded `nil`
  is silence for all of them.
- **A forwarded `max_body_bytes: nil` removed the 1 MiB cap on `refresh_credentials/2`'s token
  response**: the key survived `put_new/3` and Core read it as its own 16 MiB default.
- Docs: `README.md` and `usage-rules.md` stated a stale package version and a stale
  `dp_exchange_core` floor (`~> 0.3.95`; it is `~> 0.3.101`); the `usage-rules.md` section on
  options said every function reads the shared transport keys, which was untrue; the README's
  supervision example now says that supervising dials nothing and `:symbols` names no
  subscriber; `get_all_orders/2` pointed at `get_orders/3` (the facade function is
  `get_orders/2`).

## [0.2.140] - 2026-10-17

### Changed — BREAKING

- **A facade option the call does not read is refused, not ignored.** Every facade function
  that takes keyword `opts` checks them with `DpExchange.Core.Options.check/2` at the
  boundary, against the keys that function reads (the shared transport keys plus its own),
  and answers `{:error, {:unknown_option, key}}` for the first other key - a `nil`-valued
  one included - before an internal key is added, before anything is sent and before the
  credential is judged. A positional argument that can be judged without `opts` (symbol,
  order id, underlying, universe, market, CUSIP, transaction path, subscribed symbols) is
  judged first. `coverage/1`, `wanted/1`, `coverage_by_kind/1` and `status/1`, which have no
  error channel, raise `ArgumentError` for an unknown key. The Fake refuses identically
  (conformance group 43), before `FakeInjection` is consulted. The allowed keys live in one
  table, `DpExchange.Schwab.Options`, and `usage-rules.md` section 16 lists them. This
  replaces the package's own non-keyword check, so there is one implementation.

  A caller who passed a stray key now gets the refusal: `update_symbols/2` takes no `:to`
  (it replaces the set and delivers to whoever subscribed), and the Fake-only
  `market_status:` seam is `{:unknown_option, :market_status}` on the real facade.
  `:limit`, `:depth`, `:since` and `include_partial: true` keep answering
  `{:unsupported_option, key}`. Requires `dp_exchange_core ~> 0.3.101`.

### Changed

- **A non-keyword `opts` is refused, not raised.** Every facade function that reads `opts`
  answered an `ArgumentError`/`FunctionClauseError` in the caller's process for a map or a
  bare value; it is now `{:error, {:invalid_options, value}}` before anything is read or
  sent (the family tag). `coverage/1`, `wanted/1`, `coverage_by_kind/1` and `status/1`, which
  have no error channel, raise `ArgumentError` (bounded inspect): an empty answer would be a
  plausible "nothing covered". The Fake does the same on every function.
- **`get_screener/2` refuses an unreadable row** as `{:error, {:unreadable_screener_row,
  rank}}` instead of dropping it (a "top movers" list with a mover missing).
- **`max_results:` on `get_orders/2` and `get_all_orders/2` is a positive integer or absent**,
  else `{:error, {:invalid_option, :max_results, value}}` before any request (the spec types it
  an integer; `0`, a negative, a float or a string was sent as given). The Fake refuses alike.
- **`get_historical_prices/4` refuses `limit:`** as `{:error, {:unsupported_option, :limit}}`
  (Core's MD4): `/pricehistory` documents no count parameter and the option used to be
  accepted and ignored. A forwarded `limit: nil` is silence. The Fake refuses alike.
- **`subscribe/2` refuses the market-data options the Streamer cannot honour** (MD4):
  `include_partial: true`, `:limit`, `:depth` and `:since` are `{:error, {:unsupported_option,
  key}}`, a non-boolean `include_partial` is `{:error, {:invalid_option, :include_partial,
  v}}`. They used to be accepted and ignored. The Fake refuses alike.
- **`get_option_expirations/2` refuses an unreadable row** as `{:error,
  {:unreadable_expiration, row}}`. It used to drop it, answering a list with an expiry
  missing, or `{:ok, []}` ("no expirations") for a reply that listed only unreadable ones.

### Fixed

- `get_symbol_quote/3`, `get_instrument/3`, `get_transaction/4` and the raw
  `Rest.get_transactions/3` raised `FunctionClauseError` for a nil or non-binary symbol, CUSIP
  or account hash. They answer `{:error, {:invalid_symbol, v}}` or `{:error,
  {:invalid_path_segment, :schwab}}` (a blank CUSIP or symbol too, which built the path
  `/instruments/` or `//quotes`). The Fake answers the same; its documented "raises, as the
  real function does" is withdrawn.

## [0.2.139] - 2026-10-17

### Added

- **`DpExchange.Schwab.Fake` now carries every function the facade exports.** Seven had no
  fake - `refresh_credentials/2`, `get_transaction/4`, `get_account_summaries/2`,
  `get_symbol_quote/3`, `get_market/3`, `get_instrument/3` and `get_user_preference/2` - so a
  consumer who swapped the fake in met an `UndefinedFunctionError` on the real venue's own
  surface. Each answers the venue's own JSON in the shape of the vendor specification's
  examples (`get_market/3` only for `equity` and `option`, the two with an example; the other
  markets are `{:refused, {:venue_error, 404}}` rather than invented hours), consults
  `FakeInjection`, and judges its arguments before the credential as the real path does. A
  test pins `Schwab.__info__(:functions) -- Fake.__info__(:functions) == []`.

### Changed

- The argument checks the new fakes share with the real code are now public:
  `Rest.validate_market_request/2`, `Rest.validate_transaction_path/2` and
  `Auth.validate_refresh_input/1`. `Rest.get_market/3`, `Rest.get_transaction/4` and
  `Auth.refresh/2` call them, so behaviour is unchanged and the fake cannot drift from it.

## [0.2.138] - 2026-10-17

### Fixed

- **A crashed route or unresponsive poller now emits `[:dp_exchange, :link, :down]`
  (tick AI).** A Socket that crashes runs no `handle_disconnect/2`, so its link_down event never
  fired, and `Feed.isolate_crashed_route/2` and the unresponsive-poller path sent only the
  `:link_down` Notice; a consumer's link gauge stayed "up". `Feed` now emits
  `Telemetry.link_down(:schwab, reason)` (bounded text) once per lost link: not again when the
  Socket already reported its own, and not again until a `:link_up` closes the outage.
- **A failed order write is tagged `{:exchange_error, :schwab, _}`, not
  `{:exchange_error, :schwab_orders, _}` (tick AI).** `Rest.place_order/4`,
  `replace_order/5` and `cancel_order/4` meter in the `:schwab_orders` bucket by passing it
  as `Core.HttpClient`'s `:provider`, and Core echoes that option as the error's venue tag, so
  an internal bucket name leaked where the family's venue tag belongs and a consumer matching
  `{:exchange_error, :schwab, _}` on a placement never matched (also inside
  `{:order_unconfirmed, nil, _}`). Order writes now pass `provider: :schwab` with Core's
  `rate_limit_key: :schwab_orders`, which selects only the limiter bucket, so errors AND
  `[:dp_exchange, :request, _]` / `[:dp_exchange, :rate_limit, _]` telemetry say `:schwab`.
  Behaviour change for anything that matched `:schwab_orders`. Needs `dp_exchange_core` with
  `:rate_limit_key`: the floor is now `~> 0.3.99`.
- Tests: an unresponsive poller emits link_down telemetry once; an order write's
  `[:dp_exchange, :request, :stop]` carries `provider: :schwab`.

## [0.2.137] - 2026-10-16

### Changed

- **Conformance group 42 is supplied (tick AH).** The contract test passes
  `ambiguous_place_order:`, driving the real `place_order/3` with a 503 plug, so an
  unconfirmed write is held to `{:error, {:order_unconfirmed, nil, _}}` and a pre-send refusal
  to not being one. The `dp_exchange_core` floor is now `~> 0.3.98`.

## [0.2.136] - 2026-10-16

### Fixed

- **An order quantity a double cannot hold exactly is refused (tick AH).** The venue's
  `quantity` is a double and `Orders.build/2` sent `Decimal.to_float/1` of it, which rounds:
  `1.00000000000000001` went out as `1.0`, an order for a size the caller did not ask for.
  It is now `{:error, {:invalid_quantity, value}}` unless the float reads back as the very
  Decimal given.
- **`preview_order` asks for its three attempts explicitly (tick AH).** Core's `HttpClient`
  default for a POST becomes one attempt; a preview places nothing, so it sets
  `retry_attempts: 3` with `put_new` (a caller's own value still wins). Order writes and the
  token refresh already force one or zero attempts and are unchanged.

## [0.2.135] - 2026-10-16

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.134] - 2026-10-16

### Fixed

- **The last data subscriber dying releases the feed's symbols (tick AG).** A dead pid was
  dropped from delivery but its symbols stayed wanted, so a crashed consumer left them
  streaming and the user's single Streamer connection held open. `Feed` now releases every
  wanted symbol except the boot-time `:symbols` through the path `unsubscribe/2` takes (empty
  `SUBS` to the socket, the poller's set on the poll route, a bootstrap in flight torn down
  on settling) when the last data subscriber dies. Any remaining data subscriber keeps the
  set, registered names (never monitored) and the boot `:subscriber` included; a notice-only
  subscriber dying releases nothing. **Behaviour change:** a consumer that restarts must
  `subscribe/2` again.
- **`Fake.status/1` answers the real feed's Streamer-route shape (tick AG).** It returned a
  hybrid that matched neither real shape: `delivering` a boolean, plus the poll route's
  `symbols`, `covered` and `failures_since_ok`. The real feed on `route: :stream` answers
  `%{route: :stream, delivering: count, wanted: count, last_error: nil}`, so a consumer
  reading `status.delivering > 0` or `status.wanted` passed against the real package and broke
  on the fake. **Breaking for a suite that matched the old keys** (`symbols`, `covered`,
  `failures_since_ok`, a boolean `delivering`).
- **`Socket` does not send LOGIN twice on a reconnect (tick AG).** `handle_connect/2` queues
  `:login` to itself, and nothing reads the mailbox while the socket reconnects, so a
  connection that dropped before handling its `:login` left it queued beside the next
  connection's own: two LOGIN frames on one session. The venue answers the second with a
  failure, which counted toward `login_failures`, closed a healthy session and backed the
  reconnect off. A queued `:login` is discarded before the new one is sent.

### Documented

- **`usage-rules.md`: the feed's symbol set is feed-wide, a refresh must have one author, and
  the `status/1` shapes (tick AG).** `subscribe/2`, `unsubscribe/2` and `update_symbols/2`
  edit one set shared by every subscriber (a symbol a consumer unsubscribes is gone for all of
  them).
  Two processes refreshing the same credential at once spend its one-time refresh token
  twice; the loser is answered `{:refused, {:reauthorization_required, _, _}}` although the
  grant is fine, so serialise refreshes behind one process and read your store again before
  treating that answer as terminal. `status/1` is documented per route.

## [0.2.133] - 2026-10-15

### Fixed

- **An incoherent or duplicated candle is refused (tick AF).** A REST or streamed bar whose
  high is below its low, open or close (`Candle.coherent?/1`) now answers
  `{:error, :incoherent_candle}` instead of a plausible bar that corrupts any range built on
  it (a dropped streamed bar is reported as unreadable). A REST series holding two bars at
  the same instant (or two daily bars on one session date) answers
  `{:error, :unexpected_response_shape}` rather than counting a session twice. Out-of-order
  rows were already sorted.
- **`Socket` cancels its login-deadline and liveness timers (tick AF).** Both were only
  ref-checked: the `:login_deadline` timer stayed alive after the LOGIN response arrived
  (and after a disconnect or stop) until it fired. The timer refs are now kept
  (`login_timer`, `liveness_timer`) and cancelled on LOGIN success or refusal, on the
  deadline close, on disconnect, on reconnect and in `terminate/2`; the ref check stays.
  Audit of every other `Process.send_after` in `lib/dp_exchange`: `Feed`'s `:resubscribe`
  chain lives and dies with the Feed process, and its bootstrap and redial timers were
  already kept and cancelled. Tests assert no live login timer remains after LOGIN.

## [0.2.132] - 2026-10-15

- **`dp_exchange_core` floor raised to `~> 0.3.95` (tick AE).** The old floor predated `wanted/1`
  (0.3.93), the conformance group 41 options this package's contract test passes (0.3.94,
  ignored by an older Core: a silent pass) and the groups that no longer pass vacuously
  (0.3.95).

Tick AE: stability and documentation accuracy.

### Fixed

- **`Auth.refresh/2` refuses a token response whose `access_token` is blank or unsendable.**
  `merge_tokens/3` accepted `""` or `"  "` (any binary) beside a good rotated refresh token and
  returned it as the renewed credential. It now judges the access token with `check_token/1`
  and answers `{:error, :unexpected_response_shape}`, the tag a missing one already had.
- **`Feed` cancels a route bootstrap's timers when it settles.** The `:route_bootstrap_timeout`
  and per-caller `:bootstrap_reply_due` timers were only ref-checked, so a settled bootstrap
  left up to 95 s of stale messages to arrive later. The timer refs are kept in the bootstrap,
  cancelled on every settle path and any already-fired message is flushed; the ref check stays
  as defence. The crash-redial timer's message is flushed on cancel the same way.

## [0.2.131] - 2026-10-14

### Added

- The conformance suite runs Core's group 41 (family reasons) with `unlisted_symbol:` and
  `padded_credentials:`, so an unlisted symbol answering anything but `{:refused, :not_listed}`
  or a padded credential answering anything but `{:error, {:invalid_credentials, venue}}` fails
  this package's own suite. `dp_exchange_core` 0.3.94.

## [0.2.130] - 2026-10-14

Tick AD: facade consistency (design `2026-10-14_design-facade-consistency`) and performance.

### Changed — BREAKING (returned reasons and notice details)

- **`{:error, {:not_an_equity_symbol, s}}` is now `{:refused, {:not_an_equity_symbol, s}}`**,
  from every read and order build that judges a symbol (`get_price/2`, `get_prices/2` per
  symbol, `get_top_of_book/2`, `get_historical_prices/4`, `place_order/3` and the other
  order calls), real and Fake. The venue lists equities only, so the same symbol never
  succeeds on retry. Match `{:refused, {:not_an_equity_symbol, _}}`.
- **`get_top_of_book/2` for an instrument with no book answers `{:refused, :no_quote}`**, not
  `{:error, :no_top_of_book}`. The Fake lists only quoting equities and never answers it.
- **`{:error, {:lookback_exceeds_venue, tf, days, max}}` is now `{:error, {:range_unavailable,
  tf, earliest: DateTime.t(), requested: DateTime.t()}}`**, the family shape. `earliest` is
  `max` days before now (the documented minute-candle retention, not probed); `requested` is
  the range's `:start`. Real and Fake.
- **`Core.Notice` `details.reason` is an atom; the free text moved to `details.message`.** The
  sites: `:link_down` from the Streamer (`:connection_lost`), a crashed route
  (`:route_crashed`), an unanswered poll read (`:poller_unresponsive`), the Streamer
  unreachable (`:streamer_unreachable`), a refused login (`:login_rejected`), a rejected
  command (`:command_rejected`), a subscription not sent (`:subscription_not_sent`), a full
  held-command queue (`:held_commands_full`), withheld delayed quotes
  (`:delayed_quotes_withheld`) and a dropped unreadable frame (`:frame_unreadable`). Code that
  read the string from `details.reason` reads `details.message`.

### Fixed

- **A `:link_down` from the feed (an unanswered poll read, a crashed route) was never
  closed.** Core describes `:link_down` and `:link_up` as a pair, and a consumer waiting for
  recovery on the poll route waited forever. The first good poll after one now sends a
  single `:link_up` (latched; the Streamer's own `:link_up` closes it when the redial reaches
  the Streamer). Tests: `feed_test.exs`, "the poll route".
- **Checked, no change: the vendored WebSocket client does not re-parse a large frame per
  chunk.** `parse_frame/1` on an incomplete frame reads only the header and the declared
  length (constant work), and the buffer join is an append the VM does in place, so a frame
  in N chunks is linear. Reasoned from the code; not timed.

Tick AD: performance and hot paths.

- **Every streamed symbol kept its whole Streamer frame alive.** `Jason.decode/1` returns strings
  as sub-binaries that point into the raw frame, so the four-byte `AAPL` taken from a row held
  the entire frame (kilobytes for a `*_BOOK` or a many-row `LEVELONE_*` frame) for as long as
  anything held the symbol, and something always did: `Socket`'s `last_top` key and reported
  sets, `Feed`'s `delivering` and `kinds` keys, and every `Quote`, `TopOfBook` and `Candle` a
  consumer cached as its last price. One retained frame per streaming symbol, for the life of
  the session. `Socket` now copies the symbol out of the frame once per row
  (`:binary.copy/1`, a few bytes). Proven by `:binary.referenced_byte_size/1` on each place the
  symbol lands.
- `Fake.unsubscribe/2` removed `m` symbols from `n` held with `n * m` list walks; it now builds a
  set once. No change in behaviour.

## [0.2.129] - 2026-10-14

Tick AC: decoder robustness against hostile or malformed venue payloads.

- **A Streamer response code of `0.0` read as success.** `StreamerProtocol.succeeded?/1` tested
  `code == 0`, which is numeric equality, so `0.0` and `-0.0` passed. Only the integer codes the
  vendor lists (0, 26, 27, 28, 29) are success now.
- **A negative volume was carried as a volume.** A negative `total_volume` / `totalVolume` on a
  `Quote` and a negative `volume` on a `Candle`, from the Streamer or REST, are now `nil` ("not
  stated", with `volume_window` `nil` too) and the price beside it stands.
- **`Rest.place_order/4` and `replace_order/5` returned any last `Location` segment as the order
  id.** `portal`, `1005?next=/login` or `1005#x` came back as `{:ok, id}` and, when the read-back
  failed, were wrapped in a `%Order{}`. The venue's `orderId` is an integer, so a segment that is
  not 1 to 19 digits is `{:error, {:order_unconfirmed, nil, :order_id_not_returned}}`, like no
  `Location` at all.
- **An error body with `"detail": null` answered `{:venue_error, status, nil}`.** It is
  `{:venue_error, status}` now, as for a body with no detail.
- **`get_option_chain/3` carried non-text and impossible values.** A chain `symbol` that is
  present and not text is `{:error, :unexpected_response_shape}` (it became `underlying: 5`); a
  strike key of zero or below is `{:unreadable_chain_strike, key}`; a contract `symbol`,
  `settlementType` or `expirationType` that is not text, a zero or negative `multiplier`, and a
  zero or negative `underlyingPrice` read as `nil` ("not stated").
- **`get_balances/3` read an unreadable available figure as "not stated".** A present
  `availableFunds` / `cashAvailableForTrading` that is `"abc"`, `""`, NaN, an infinity or an
  absurd exponent is `{:error, :unexpected_response_shape}`, as the total beside it already was;
  an absent or `null` one is still `nil`.
- **The four list reads passed non-object rows through.** `get_account_summaries/2`,
  `get_all_orders/2`, `get_orders/3` and `get_transactions/3` answered `[1, "x", nil]` as sent, and
  callers read `row["orderId"]` and raised. A list with any non-object row is
  `{:error, :unexpected_response_shape}`.
- **`Orders.build/2` raised on a struct.** `is_map/1` is true for one, `check_keys/1` then
  enumerated it, and `Protocol.UndefinedError` came out in the caller's process. A struct is
  `{:error, {:invalid_order_request, struct}}`, as the fake answers too.
- **The vendored WebSocket client had no ceiling on a message.** A frame that stayed incomplete
  (a header declaring 2^40 bytes) or a fragmented message with no final frame grew the socket
  process's memory for as long as the peer sent. Past 8 MiB the socket now closes with code 1009
  and reconnects in the ordinary way (fourth marked change to `DpExchange.Schwab.Vendor.WebSockex`).

## [0.2.128] - 2026-10-14

- **A feed could be left with no route.** If the fallback poller crashed a second time within a
  minute while a Streamer upgrade was in flight, its redial was delayed; the redial found the
  upgrade still running and did nothing, and when the upgrade then failed the feed stayed on no
  route, delivering nothing until a consumer subscribed again. A failed upgrade with no route now
  falls back to the poll, or opens nothing when nothing is wanted.
- **A poll refusal for a symbol unsubscribed while the cycle was in flight was still delivered.**
  It is now dropped, as a late quote for that symbol already was.
- **Docs:** `{:error, :feed_timeout}` is documented as "no answer", not "not applied": the request
  is still applied, and the streaming calls are idempotent.

## [0.2.127] - 2026-10-13

- **`Orders.build/2` raised for a finite quantity outside the float range.** `1E400` or `1E-400`
  made `Decimal` raise `Decimal.Error` in the caller's process; it is now refused as
  `{:invalid_quantity, quantity}` like any unusable quantity.
- **A `Socket` subscriber registered by name never heard `:relogged_in`.** It was sent to a pid
  only, so a named subscriber got the `:link_up` notice but waited out the 60s re-assert.
- **Tests:** every line the suite never executed was read and either tested, proven dead and
  removed (`Orders.timestamp_compact/1` and several `Rest`, `Fake` and facade fallbacks), or
  kept as a commented defensive clause.

## [0.2.126] - 2026-10-12

- **Security: no credential is sent to a non-https override.** A `:token_url`, `:trader_url`
  or `:market_data_url` that is not https answers `{:error, {:insecure_url, :schwab}}` before
  any request (`:plug` and `:req_adapter` are exempt); an order write refused this way is a
  plain error, never `order_unconfirmed`.
- **Security: the Streamer is wss only.** `Socket.start_link/1` refuses a non-`wss://` URL,
  venue-supplied or overridden, with `{:error, {:insecure_url, :schwab}}`; the LOGIN frame
  carries the access token. `allow_insecure_socket: true` is the test-only seam.
- **Security: a token, client id or client secret with a control character or invalid UTF-8 is
  refused** as `{:invalid_credentials, :schwab}`. It reached the `Authorization` header or the
  LOGIN encoder, and the resulting error quoted it.
- **`Feed.update_credentials/2` with a non-map answers `{:invalid_credentials, :schwab}`** like
  the facade, instead of echoing the rejected value.
- **`Socket.start_link/1` with a missing required option raises naming the key only**, not a
  `KeyError` that printed the access token.

## [0.2.125] - 2026-10-12

- **Docs (`usage-rules.md` checked line by line against the code):** the Core requirement is
  `~> 0.3.74`; documents the jittered and short-session reconnect backoff, the route-crash backoff
  and the closing of a route settled with nothing wanted, the full order-validation check order, the
  5,000-entry notice caps and what happens past them, the cash-account available-balance field,
  that `:ssl_options` is honoured only with `verify: :verify_peer`, that a hand-built child spec
  must wrap its credentials, and corrects the Fake's `subscribe_notices/1` and refusal order.

## [0.2.124] - 2026-10-12

- **A Streamer session accepted and then severed within seconds reconnected at once, forever.**
  The backoff count reset on every successful LOGIN, so a venue that accepts the login and then
  closes (`12 CLOSE_CONNECTION`, one Streamer connection per user; `30 STOP_STREAMING`) got a
  zero delay every time. Two nodes sharing one Schwab user would take the connection from each
  other at network speed. Sessions that end within 10 seconds (chosen, not measured) now count
  toward the existing 1s-doubling, 30s-capped backoff; a session that lasts clears the count.
- **A Socket in its reconnect backoff ignored its parent stopping it.** The wait, up to 30s, was
  a bare sleep, so a socket `Feed` had stopped or orphaned slept out the delay and dialled the
  Streamer once more, which on a one-connection-per-user venue can sever its replacement. The
  wait now exits with the parent's reason.
- **Reconnect backoff is jittered** (`Socket.jittered_delay_ms/1`: shortened by up to a quarter,
  never lengthened; an immediate reconnect stays immediate), so nodes sharing a venue outage do
  not retry in lockstep. The `link_reconnect_attempt` telemetry `delay_ms` reports the delay
  actually waited.
- **A route that kept crashing was redialled with no backoff.** The first crash in a quiet period
  still redials at once; a crash within 60s of the previous one now waits 1s, doubling to 30s,
  and the `:link_down` notice says how long. A stale redial timer does nothing, and the wanted
  set is checked again when the timer fires.
- **A route that finished connecting after every symbol was unsubscribed stayed open.** A
  bootstrap or upgrade that settles with nothing wanted now tears down the Streamer session or
  poller it just started. Callers waiting on it are answered as before.

## [0.2.123] - 2026-10-12

- Docs: every public facade function is documented in HexDocs (156 added); docs build is warning-free.

## [0.2.122] - 2026-10-12

- **Test suite (tick V, every test file read line by line):** the Streamer snapshot-time
  refusal tests fed an ignored key and never reached the epoch guard, now they do; the status
  enum test checks the status is sent; a huge-exponent leg test no longer passes vacuously;
  fallback-poll and Fake tests wait on observed state, not timed windows; socket and feed waits
  on spawned processes are 5s; duplicate and Decimal-only tests removed.

## [0.2.121] - 2026-10-12

### Fixed -- tick U (test-suite quality, regression review of tick T)

- `StreamerDecode.to_top_of_book/3` judges the price before the size, as REST does: a price of
  0 is "no resting order" and its size is moot, so an unreadable size beside it no longer
  refuses the frame (tick T had made the streamed arm stricter than REST there). A size beside
  a live price, or a size with no price in a delta, is still refused when unreadable or
  negative. When both are unreadable the price is the fault reported.
- Tests: the declared-`:unsupported` sweeps assert they sweep something; added tests for the
  streamed unreadable size, the `last_top` cap, and the price-before-size order.

## [0.2.120] - 2026-10-12

### Fixed -- tick T (regression review of tick S, docs vs code, hot path)

- **BREAKING: a candle with a zero or negative open, high, low or close is refused (MD6).**
  `Rest.get_historical_prices/4` answers `{:error, {:non_positive_price, field, value}}` for the
  reply, and `StreamerDecode.to_candle/3` refuses the bar; neither path checked the sign
  before, so a bar opening at 0 sat in the series like any other.
- **BREAKING: a present book size that cannot be read, or is negative, refuses the book
  (MD5).** `Rest.get_top_of_book/2` and `StreamerDecode.to_top_of_book/3` answer
  `{:error, {:invalid_decimal, :bid_size | :ask_size, value}}`. It used to become `nil`
  ("not published") beside a published price, while the tick S `:degraded` notice already
  said "a price or size could not be read".
- **A streamed candle dropped for an unreadable or non-positive value is announced**, once per
  symbol per session, like a dropped book frame (`details.reason` now reads "a price, size or
  time in it could not be read").
- REST `{:invalid_decimal, :bid | :ask, value}` quotes `value` bounded (short strings and
  numbers as sent, anything else cut), so a hostile reply cannot ride the error tuple.
- `Socket` no longer lets `last_top` grow without limit for rows the venue sends under keys
  that were never subscribed: a new key past the 5,000 cap is published but not carried.
- Hot path: `Feed.put_kind/3` allocates nothing when the kind is already recorded for the
  symbol (it built a `MapSet` per delivered frame).
- Docs: `usage-rules.md` said a streamed book level that cannot be read is dropped; it refuses
  the book (since 0.2.118). `StreamerDecode` no longer says a missing venue time "falls back to
  `observed_at`" (it is `nil`). A stray comment block in `Feed` now sits on `@call_timeout`.

## [0.2.119] - 2026-10-12

### Fixed -- tick S regression review

- **A streamer book frame refused for an unreadable value is no longer dropped in silence.**
  An unreadable or negative bid/ask on a `LEVELONE_*` frame (and an unreadable level on a
  `*_BOOK` frame) dropped the frame and left the last published book standing with no word:
  a frozen book that looked live. `Socket` now raises one `:degraded` notice per symbol per
  session (`details: %{symbol:, service:, reason:}`, bounded and cleared on reconnect). The
  last good book still stands for the next delta, and `Feed.coverage/1` is unchanged: it
  reports a kind a symbol has delivered this session and a streaming route has no staleness
  window, so the notice is how a consumer learns a symbol's book has stopped updating.
- Unmeasured, left as is: a weekly bar stamped on a non-Monday day maps to its own ISO week,
  and a daily bar counts as complete only from 00:00 UTC of the next date (a few hours after
  the US close), so the day's finished bar is withheld until then unless `include_partial`.

## [0.2.118] - 2026-10-12

### Fixed -- market-data and order conventions (family tick R, MD1-MD3, MD5, MD6, MD8, DV1, DV6)

- **BREAKING: `get_historical_prices/4` always sends `endDate` (MD2).** With no range, or
  only `:start`, the request omitted `endDate`, and the venue defaults it to "the market
  close of previous business day" (market-data-production.openapi.json,
  `QueryParamenddate`), which silently dropped today. `endDate` is now the caller's `:end`
  or now. `:start` is inclusive and `:end` exclusive on `opened_at`, also enforced on the
  decoded bars. With no `:start`, `period` is sent beside `endDate = now`; that `period`
  counts back from `endDate` is read from the document and **unmeasured**. The lookback
  check (`requested_days`) is sized over the same window and the same instant that is sent.
- **BREAKING: the bar still forming is no longer returned (MD1).** A bar is in progress when
  `opened_at + width > now`; it is dropped unless the caller passes `include_partial: true`
  (any other non-boolean is `{:error, {:invalid_option, :include_partial, v}}`). With the
  option the bar is returned as-is and may still change. Weekly bars close at the next
  Monday and monthly bars at the next first of the month.
- **BREAKING: daily, weekly and monthly `opened_at` is 00:00 UTC of the session date
  (MD3).** The venue stamps exchange-local midnight (the document's example,
  `1451624400000`, is 05:00Z); the date is the fact, not that instant. Minute bars keep the
  instant sent.
- **BREAKING: an unreadable order-book level refuses the frame's book (MD5).** The Streamer
  silently dropped levels missing a price or size and turned a non-list side into `[]`.
  `StreamerDecode.to_order_book/2` now answers
  `{:error, {:unreadable_level, :bids | :asks, value}}` for a level without a readable price
  or size, a price <= 0, a negative size, or a present non-list side. A size of exactly 0 is
  no liquidity and is dropped; an absent side is empty.
- **BREAKING: a bid or ask is `nil` only when the venue says there is no order (MD6).** A
  price of `0` is no resting order on that side (`nil` price and `nil` size), on REST
  `get_top_of_book/2` and on the stream. A present side that cannot be read (a non-number,
  an empty string, NaN, a negative) refuses the book: REST answers
  `{:error, {:invalid_decimal, :bid | :ask, value}}`, the stream drops that frame's book
  and keeps the last published one. It used to become `nil`, which `TopOfBook` reads as "no
  resting order". On the stream a cleared side also clears its previous size.
  `StreamerDecode.to_top_of_book/3` now returns `{:ok, _} | {:error, _}`.
- **BREAKING: a streamed `Quote` reports `total_volume` as `:running_total` (MD8).**
  LEVELONE is conflated, so `last_size` labelled `:print` was a claim the stream cannot
  keep. `volume` is now the day's cumulative total, as on REST; with no total the volume
  and its window are `nil`.
- **BREAKING: an unknown request key holding `nil` is refused (DV1).**
  `client_order_id: nil` and any other unread key is `{:unsupported_order_field, key}`
  whatever its value. A nil on a key the builder reads is still an unset option.
- **BREAKING: every 4xx except 429 on an order write is `{:refused, _}` (DV6).** 409, 415,
  422 and any other undocumented 4xx used to be `:order_unconfirmed`. Writes are sent
  exactly once, so a 4xx is always the answer to the first attempt; 429 stays a plain
  `{:error, _}`. `cancel_order/3` follows the same rule.
- Fake parity: the fake's candle series is aligned to the width, cut by the same
  `Rest.window_candles/4`, honours `include_partial` and refuses it the same way.

## [0.2.117] - 2026-10-12

### Fixed -- regression review of the trading conventions and Decimal switch (family tick R)

- **BREAKING (error value): a duration the venue does not serve is the family's
  `{:error, {:unsupported_order_combination, order_type, time_in_force}}`**, not
  `{:unsupported_time_in_force, tif}` (`:gtd`, `:gfw`, a string, ...). Same on `Fake`, which
  builds through `Orders.build/2`.
- **An orders reply at the venue's default cap is refused, not returned as complete.** The
  spec's `maxResults` reads "Default is 3000", so `get_all_orders/2` and `get_orders/2` with
  no `:max_results` and a reply of 3000 or more rows answer `{:error, :history_truncated}`,
  as `get_transactions/2` does. A caller's own `:max_results` is honoured as its bound.
- **A preview's reject rows keep a number a `Decimal`.** `bound_reject/1` matched a `Decimal`
  as a map and rebuilt it as `%{sign:, coef:, exp:}`; lists inside a row are now bounded too.
- **`Fake` parity with the Decimal switch:** its canned order price, its transaction row's
  `netAmount`, its screener metrics and the bodies it builds for placed orders hold
  `Decimal`s where the real path holds them (they were floats).
- Docs: the `marginBalance` reading ("cash side, negative when borrowing") is stated as
  **unmeasured**: the spec types the field as a bare `number` with no description. Raw-body
  calls now say their fractional numbers are `Decimal`s; the facade's order-id check
  (`{:invalid_order_id, v}`, integers refused) is documented where `invalid_path_segment` was.

## [0.2.116] - 2026-10-12

### Changed

- **BREAKING: `get_balances` reports the same quantity for both account types: the cash in the
  account.** A MARGIN account's `balance` was `equity` (net worth, securities' market value
  included, the loan netted off) while a CASH account's was `totalCash`; one field carried two
  meanings. A MARGIN account's `balance` is now `marginBalance` (its cash side; negative when
  borrowing; documented in the spec as a bare `number`, **not measured**) and `equity` is no
  longer read. A MARGIN reply with no `marginBalance` is `{:error, :unexpected_response_shape}`
  (it never substitutes `equity`). `available_balance` is unchanged.
- **BREAKING: money and quantities keep every digit.** Reads are sent with `decode_body: false`
  and decoded with Jason `floats: :decimals`, so a fractional JSON number reaches the decoders
  as a `Decimal` (previously a float then `Decimal.from_float/1`, which carried the binary
  error). `preview_order` returns the venue's body as-is, so its fractional numbers are now
  `Decimal`s, not floats.
- **BREAKING: `get_positions` refuses a row whose quantities cannot be read.** A row with both
  `longQuantity` and `shortQuantity` absent, or one present but unreadable (`"abc"`, `""`,
  NaN), used to be dropped as flat; it is now `{:error, {:unexpected_position_quantity,
  :unreadable}}` for the whole reply. Only quantities stated as zero are flat. One leg omitted
  beside a readable leg is read as that leg alone.
- **BREAKING: `get_transactions` refuses a reply of 3000 or more rows** as `{:error,
  :history_truncated}` (the spec: "Maximum number of transactions in response is 3000"). It
  was returned as complete. Narrow the window or `:symbol` and ask again; the package does not
  walk the window itself. `Fake.get_transactions/2` answers through the same check
  (`Rest.within_transactions_cap/1`).
- **BREAKING (error value): `{:error, {:invalid_symbols, v}}` carries the caller's argument as
  given.** A list holding a refused element used to report only the refused elements, trimmed
  (`["  "]` became `[""]`; `["AAPL", :x]` became `[:x]`). `v` is now the whole list passed, on
  the facade, `Feed` and `Fake` alike (Core's assertion 32).
- Numbers decoded as `Decimal` now also reach the order decoder (`Orders` reads a `Decimal`
  price, stop price and quantities as itself); a filled order's `price` was `nil` otherwise.

## [0.2.115] - 2026-10-12

### Changed

Family trading conventions (T1-T12). Every answer below is the same on the facade, `Rest` and
`DpExchange.Schwab.Fake`.

- **BREAKING: an unproven order write is `{:error, {:order_unconfirmed, nil, reason}}`.**
  `place_order/3` and `replace_order/4` send once; a timeout or transport failure after the
  request left, or a 5xx, used to be a bare `{:error, reason}` (or
  `{:error, {:exchange_error, :schwab, "HTTP 5xx"}}`) that a caller read as "worth retrying",
  and a `201`/`2xx` with no `Location` was `{:error, :order_id_not_returned}`, also on a
  replacement the venue had already applied. All are now `:order_unconfirmed` (the `nil` is the
  client order id, which Schwab has no field for; `reason` is bounded). Our own limiter
  refusing, the venue's 429, validation, a missing option or credential stay plain
  `{:error, _}`; a venue 4xx stays `{:refused, _}`.
- **BREAKING: no defaults on an order.** A request without `:order_type` is
  `{:error, {:missing_field, :order_type}}` (it was a MARKET order when it carried no price) and
  one without `:time_in_force` is `{:error, {:missing_field, :time_in_force}}` (it was `:day`).
- **BREAKING: unread request keys are refused.** `client_order_id` (silently ignored: Schwab has
  no idempotency key) and any other key the builder does not read are
  `{:error, {:unsupported_order_field, key}}`. A key holding `nil` counts as absent.
- **BREAKING: preview rejections are refusals.** `preview_order/3` with a non-empty
  `orderValidationResult.rejects` is `{:refused, {:preview_rejected, rejects}}` (it was
  `{:ok, body}`); a non-object preview body is `{:error, :unexpected_response_shape}`.
  `Fake.preview_order/3` rejects an option order for a fractional number of contracts in that
  shape (the rule name is the fake's own, not the venue's), where it always answered
  `rejects: []`.
- **BREAKING: request validation tags and order.** Order: request is a map, unknown keys,
  symbol, side, order type, time-in-force, quantity, prices, then `opts[:account_hash]`, the
  order ceiling and the credential (the ceiling used to be checked before the order was built).
  `{:missing_order_field, f}` is `{:missing_field, f}`; a non-buy/sell side is
  `{:invalid_side, v}` (was `{:invalid_instruction, v}`); a missing or blank symbol is
  `{:invalid_symbol, v}` (was `{:missing_order_field, :symbol}` / `{:empty_symbol, v}`);
  `{:price_not_allowed, t}`, `{:stop_price_not_allowed, t}` and
  `{:trailing_field_not_allowed, k, t}` are all `{:unexpected_field, key}`; a bad `:price` /
  `:stop_price` is `{:invalid_price, v}` / `{:invalid_stop_price, v}` (was
  `{:invalid_order_field, key, v}`, and `{:invalid_price, v}` for both).
- **Accepted now:** `side: "buy"` / `"sell"` in any case (was `{:invalid_instruction, "buy"}`)
  and a numeric-string `:quantity` such as `"1"` (was `{:invalid_quantity, "1"}`).
- **BREAKING: floats are refused** for `:quantity`, `:price`, `:stop_price` and
  `:stop_price_offset` (`{:invalid_quantity, v}` etc.): a float has lost digits, and one was
  sent as a JSON float. Pass a Decimal, an integer or a numeric string.
- **BREAKING: order ids.** `get_order/3`, `cancel_order/3` and `replace_order/4` answer
  `{:error, {:invalid_order_id, v}}` first (before the account option, the order ceiling and
  the credential) for `nil`, a non-string, a blank or a padded string. A blank id used to be
  sent, an integer accepted, and `nil` answered `{:invalid_path_segment, :schwab}` after the
  account and ceiling checks. `Rest.check_path_segment/1` is removed (`Orders.check_order_id/1`
  replaces it).
- **BREAKING: a replacement whose read-back failed** is
  `{:error, {:replace_accepted_unread, new_id, reason}}`, where it was
  `{:ok, %Order{status: :pending}}` built from the request. A placement whose read-back failed
  still answers `{:ok, %Order{status: :pending}}`, now built from the validated payload (the
  normalised side, symbol and type) rather than the caller's raw request.
- **BREAKING: a missing option is `{:error, {:missing_option, key}}`.**
  `{:missing_account_hash, :schwab}` is `{:missing_option, :account_hash}` on every account
  endpoint (facade and Fake); `get_positions/1` with several accounts and no `:account_number`
  is `{:missing_option, :account_number}` (was `{:account_number_required, n}`).
- **BREAKING: a missing order is `{:refused, :not_found}`.** `get_order/3`, `cancel_order/3` and
  `replace_order/4` answer it for a 404 (was `{:refused, {:venue_error, 404}}`); the Fake for an
  id it never issued.

## [0.2.114] - 2026-10-11

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.113] - 2026-10-11

### Changed

- **BREAKING: `unsubscribe/2` judges every symbol.** `unsubscribe(["AAPL", :x, 42])`,
  `unsubscribe(nil)` and `unsubscribe([""])` answered `:ok` (the feed's `handle_call` had no
  per-symbol check, unlike `subscribe` and `update_symbols`; `DpExchange.Schwab.Fake` the
  same). They now answer `{:error, {:invalid_symbols, value}}`, `value` being the refused
  elements (or the argument when it is not a proper list). One judgement,
  `Feed.check_symbols/1`, is shared by the facade, the feed and the Fake, and an improper
  list is refused instead of raising.
- **BREAKING: streaming arguments are judged before the feed is looked at.**
  `subscribe/2`, `unsubscribe/2`, `update_symbols/2` check symbols, then (`subscribe/2`,
  `subscribe_notices/1`) the subscriber, then answer `{:error, :feed_not_started}`. A bad
  argument with no feed used to answer `:feed_not_started` (or `:ok` for `unsubscribe`).
- **BREAKING: single-symbol reads.** `get_price/2`, `get_top_of_book/2` and
  `get_historical_prices/4` (facade, `Rest` and Fake) answer `{:error, {:invalid_symbol, v}}`
  for `nil`, a non-string or a blank string, before credentials. Was
  `{:not_an_equity_symbol, v}` (after credentials) and `{:empty_symbol, v}`. A well-formed
  non-equity string keeps `{:not_an_equity_symbol, v}`.
- **BREAKING: `get_historical_prices` range.** A `range` that is not a keyword list is
  `{:error, {:invalid_range, range}}` (it raised in `Keyword.get/2`); a `:start`/`:end` that
  is not a `DateTime` is the same instead of `{:invalid_range_bound, key, value}`.
- **BREAKING: a credential with surrounding whitespace is refused.** `Auth.headers/2` and
  `refresh/2` answer `{:error, {:invalid_credentials, :schwab}}` (value never echoed)
  instead of trimming and sending it; `Feed` shares the check (`Auth.check_token/1`) for the
  Streamer `LOGIN` token. Blank stays `{:missing_credentials, :schwab}`.
- **BREAKING (Fake): `coverage/1` reports `:stream` and `status/1` `route: :stream`** (the
  real feed's normal route) where it said `:internal_poll`; `subscribe_notices/1` no longer
  sends a `:link_up` on registration (the real feed sends none); `update_symbols/2` ignores
  `:to`, as the real one does.

### Fixed

- **`Fake.subscribe/2` no longer raises for a `to:` atom that names no process.** It used
  `send/2` directly (`ArgumentError`); every delivery now goes through a private `deliver/2`
  using `Core.Fanout.resolve/1`, which skips it as the real feed does, and a symbol is
  recorded as covered only when the target resolves.
- **`subscribe([])` no longer bootstraps.** It ran `GET /userPreference` and dialled the
  Streamer for an empty wanted set. The subscriber is registered and nothing is opened until
  a symbol is named (`settle_route/2`).
- **The facade no longer raises for a feed given as a pid on another node.** `alive?/1` called
  `Process.alive?/1` on it; `coverage/1`, `status/1`, `subscribe/2` and `update_credentials/2`
  now answer as for a feed that is not started.
- **An explicit `ssl_options: nil` (or `[]`, or a list without `verify: :verify_peer`) no
  longer disables certificate verification** on the Streamer socket; it gets the verified
  defaults. A caller's own list that keeps `verify: :verify_peer` is honoured.

## [0.2.112] - 2026-10-11

### Fixed

- **`Feed.update_credentials/2` sent the credential map to the feed in the clear.** The
  state redaction in `Credentials` does not reach the call message, which OTP prints in full
  in the caller's exit reason when the call times out
  (`{:timeout, {GenServer, :call, [feed, {:update_credentials, %{refresh_token: ...}}, _]}}`)
  and in the feed's "Last message" line if it dies handling it. The map is now wrapped in the
  caller, before it is sent.
- **`StreamerInfo` printed the customer and correlation ids.** `Socket` keeps the struct in
  its state for the life of the connection, so any crash report carried
  `schwabClientCustomerId` and `schwabClientCorrelId`. Its `Inspect` now omits both; the LOGIN
  still reads the real values.
- **`Feed.start_link/1` and `DpExchange.Schwab.Supervisor.start_link/1` stored a raw `:credentials` map** when
  reached without `child_spec/1`; both now wrap it (`Credentials.wrap_opt/1`), so the
  supervisor's init arguments and the feed's start arguments print redacted.
- **`Auth.refresh/2` held up to 16 MiB of whatever answered the token URL.** A token response
  is a couple of kilobytes. The cap is now 1 MiB (`:max_body_bytes` overrides it) and an
  oversized reply is `{:error, {:exchange_error, :schwab, {:response_too_large, limit}}}`.

### Checked, no change

- Load: `Rest.get_prices/3` batches 100 symbols per request, `get_option_chain/3` flattens
  once, `Feed`'s `delivering`/`kinds` are bounded by the wanted set, `Socket`'s `held` by 64
  and its delayed-symbol set by 5_000. Streamer symbol limits per `SUBS` are not documented
  and not measured, so no cap is invented. A burst of frames is not back-pressured between
  `Socket` and `Feed` (consumers are, through `Core.Fanout`); unmeasured against the venue.

## [0.2.111] - 2026-10-11

### Fixed

- **`subscribe/2` and `subscribe_notices/1` stored any `:to` term, and a string, integer or
  `{:global, _}` tuple crashed the shared `Feed` on first delivery.** `Core.Fanout.resolve/1`
  has clauses for a pid and an atom only, so the `FunctionClauseError` was raised inside
  `Feed` and the restart dropped every consumer. Both now answer
  `{:error, {:invalid_subscriber, term}}` (a pid or a registered atom other than `nil`,
  `true`, `false` is accepted) before recording anything, after the symbol check.
  `Feed.valid_subscriber/1` is shared with `DpExchange.Schwab.Fake`, which refuses in the
  same order.
- **The facade read a running `{:global, _}` or `{:via, _, _}` feed as absent.** `alive?/1`
  handled only pids and local atoms, so `coverage/1`, `wanted/1`, `status/1` and
  `subscribe/2` answered empty or `:feed_not_started` for a live feed. It now resolves any
  `GenServer.server()` through `GenServer.whereis/1`.
- **Frames and notices already queued from a replaced `Socket` were counted against its
  successor.** A socket carried no identity in what it sent, so a `:link_down` still in
  `Feed`'s mailbox when a crashed socket was replaced wiped the new session's coverage, and a
  late frame reported a symbol `:stream` that the new session had not delivered. `Socket`
  takes an optional `:tag` and, when given, sends `{:dp_exchange, :schwab, {:from_socket, tag,
  payload}}`; without one the subscriber protocol is unchanged. `Feed` tags each socket it
  builds, handles messages bearing the current tag as before, and drops any other.
- **`Feed` stayed on the fallback poll for good when credentials were replaced while the
  Streamer bootstrap was in flight.** `update_credentials/2` starts a retry only when no
  bootstrap is running, and the periodic tick deliberately skips a credential the venue
  REFUSED. A bootstrap that started under the old token and was refused therefore left
  `last_error` as `{:refused, _}`, the new token was never tried against `/userPreference`,
  and the feed polled (no candles) until restarted. A bootstrap now records the credential
  generation it started under; if it settles on the poll route and the generation has since
  moved, the Streamer is retried once with the current credential. Covers the initial
  bootstrap, a background upgrade, and the timeout/task-down paths.
- **A stale fallback-poll refusal or "delivering nothing" notice could reach consumers after
  the route upgraded to the Streamer.** Quotes were already tagged with the poller that
  produced them; `on_refusal` and `on_notice` were not, so one queued in `Feed`'s mailbox
  when the poll was stopped was delivered as if current. Both are now tagged and dropped
  unless they come from the poller serving the route.

## [0.2.110] - 2026-10-11

### Fixed

- **Venue-supplied text is bounded before it enters an error tuple, a notice or telemetry.**
  `Rest.refusal/2` put a venue's `detail`, `message` or `error_description` into
  `{:venue_error, status, detail}` whole, `Auth` did the same with a token endpoint's
  `error_description`, and the Streamer's LOGIN or command `msg`, its `service` and its
  delayed-quote `symbol` went into notices unbounded, as did `inspect(reason)` in
  disconnect, crash, fallback and re-assert notices, log lines and the `link_down`
  telemetry. A proxy's HTML page or a hostile reply became megabytes in every caller's
  tuple. A new internal `DpExchange.Schwab.Bound` cuts a binary to 2_048 bytes on a UTF-8
  boundary with a `… (N bytes)` marker (a short message is unchanged) and renders any
  other term with `inspect(limit: 50, printable_limit: 2_048)`; reason terms use
  `printable_limit: 1_024`. A non-string `errors[0].detail` now arrives as bounded text
  rather than as the raw term.
- **`Fake` ignored the order ceiling the real facade enforces.** `Schwab.place_order/3`,
  `replace_order/4` and `cancel_order/3` refuse `{:error, :order_limit_not_declared}` and
  `{:error, :order_limit_zero}`; the fake accepted both. The check moved to
  `OrderLimit.ensure_declared/1`, shared by the facade and the fake, in the same position
  (after the account hash, before the order is built). With no tree supervised the fake, like
  the facade, has no opinion.
- **`Socket`'s set of already-reported delayed symbols could grow without bound.** It is
  keyed by a venue-supplied key; it is capped at 5_000, past which a delayed quote is still
  withheld but no longer announced.

## [0.2.109] - 2026-10-11

### Fixed

- **A REST epoch below 1e11 was read as SECONDS.** `Rest.parse_time/1` guessed the unit from
  the magnitude, though the spec types `quoteTime`, `tradeTime` and a candle's `datetime` as
  int64 epoch milliseconds. A genuine early-history bar (a `datetime` before March 1973, 50e9
  ms for instance) was read as seconds and placed in the year 3554. Always milliseconds now;
  the unit is not inferred. A value the spec does not offer is read as what it says.
- **A negative position quantity dropped the position.** `position_side/2` only takes a
  positive leg, so a short sent as `shortQuantity: -40` (the spec leaves the sign unstated,
  unmeasured) fell through to "flat" and vanished from `get_positions/1`. A negative
  `longQuantity` or `shortQuantity` now refuses the reply as
  `{:error, {:unexpected_position_quantity, :negative}}`.
- **Trailing-stop and on-close orders read back as `order_type: nil`.** Core 0.3.74 names
  `:trailing_stop`, `:trailing_stop_limit`, `:market_on_close` and `:limit_on_close`, but
  `Orders.from_venue/1` kept a four-atom filter, so an order this package placed with one of
  them came back typeless. The read-back table is now the full inverse of the send table, and
  the dependency floor is `~> 0.3.74`.
- **A `LIMIT_ON_CLOSE` price of zero or below was sent.** It was the one limit type left out
  of the positive-price check `LIMIT`, `STOP`, `STOP_LIMIT` and `TRAILING_STOP_LIMIT` get.
- **A stale LOGIN deadline or liveness check closed a fresh session.** `Socket` did not clear
  `login_deadline` and `liveness` when the connection dropped. A timer that fired during the
  reconnect backoff sat in the mailbox ahead of the new `:login`, still matched the old ref in
  the state, and closed the freshly connected session with a bogus `:login_unanswered`
  notice. Both are cleared with the rest of the session in `handle_disconnect/2`.

## [0.2.108] - 2026-10-11

### Fixed

- **Error text quotes a venue body bounded.** Four unexpected-status branches in `Rest` and
  the token refresh in `Auth` put `inspect(body)` / `inspect(response)` into
  `{:exchange_error, :schwab, _}`, so a CDN error page became the message. Quoted bounded
  now (`limit: 50`, `printable_limit: 2_048`), as Core does.

- **`Fake` accepted any non-empty credential map.** Its check was `map_size > 0`, so
  `%{refresh_token: "x"}` and `%{access_token: ""}` answered `{:ok, _}` where the real package
  answers `{:error, {:missing_credentials, :schwab}}` (`Auth.headers/2` refuses a blank or
  absent token). The fake now asks `Auth.headers/2` itself, and asks it where the real path
  does: market-data calls want a credential map first (the facade), then judge their own
  arguments (symbol, width, range, market, query), then sign; account calls judge theirs and
  sign last. A blank token with a bad symbol is the symbol's refusal, in both.
- **`Fake.get_option_chain/2` skipped the chain's date checks.** An unreadable `:from_date` or
  `:to_date` is `{:error, {:invalid_date, key, value}}` from the real path, after the
  underlying and before the credential; the fake answered a chain. `Rest.check_chain_dates/1`
  is that check, shared.
- **`Fake.get_positions/1` ignored `:account_number`.** The real read refuses a number the
  credential has no account for (`{:refused, {:account_not_found, number}}`); the fake served
  its one account for any number. It holds `"123456789"` and refuses the rest.
- **`Fake.get_orders/2` and `get_all_orders/2` ignored `:max_results`**, which the venue's
  `maxResults` honours. A positive integer now narrows the list.
- **`Fake.get_symbols/1` returned symbols unsorted**, where `Rest.get_symbols/2` sorts.
- **Four fake calls could not be made to fail.** `get_option_chain/2`,
  `get_option_expirations/2` (both targetable by the underlying), `get_screener/2` and
  `get_transactions/2` now consult `Core.FakeInjection` like the rest.
- **The facade's `place_orders/3` doc said a multi-leg order is placed through `place_order/3`
  with `:legs`.** There is no such key: `place_order/3` builds a single-leg order, and
  `supports_multi_leg_orders` is `false`.

### Added

- `Fake.wanted/1`, `Fake.status/1`, `Fake.update_credentials/2` and delegates for
  `movers_universes/0`, `markets/0`, `transaction_types/0`, `equity_instructions/0`,
  `option_instructions/0`, `needs_refresh?/2` and `credential_failure?/1`, so a consumer that
  swaps the fake in for the facade finds the same names. `wanted/1` holds every valid symbol
  asked for; `coverage/1` still holds only the ones the fake delivers. The facade's raw
  undecoded reads and `refresh_credentials/2` are deliberately not faked (they would invent
  venue documents); the moduledoc says so.

### Changed (tests)

- Every wait on a spawned process, a socket stand-in or a poll timer in `feed_test`,
  `feed_upgrade_test`, `bootstrap_route_test`, `fallback_poll_test`, `defensive_branches_test`,
  `schwab_test`, `order_limit_test`, `credentials_test` and `forwarded_nil_test` is at least
  five seconds (it was 0.5 to 3 s, or the 100 ms default). The test that "the feed survives a
  linked socket being killed" decided by a 500 ms `refute_receive`; it now waits for the
  `:link_down` the feed raises for the crash it isolated.
- README's dependency line names the current version.

## [0.2.107] - 2026-10-11

### Fixed

- **A REST top of book could be dated by the last trade.** `get_top_of_book/3` took
  `venue_time` from `quoteTime` and, when that was absent or zero, from `tradeTime`. The
  latter dates the last print and can be hours older than the book on the same row, so the
  book wore a time that was not its own. `quoteTime` alone is read (as
  `StreamerDecode.to_top_of_book/3` already did); without it `venue_time` is `nil`.
- **A streamed `last` of zero was published as a traded price.** `StreamerDecode.to_quote/3`
  accepted `last: 0`, which an instrument with no print yet (an untraded option) streams in
  place of omitting it, and built a `Quote` at price zero. REST has skipped a zero `lastPrice`
  since early on. A zero or negative `last` is now `{:error, :no_traded_price}`, so the socket
  delivers no quote for the frame (its top of book is unaffected). The venue streaming zero for
  an untraded instrument is inferred from the REST arm's precedent, not measured.
- **`Rest.get_order/4` returned a non-object body as sent**, against its `{:ok, map()}` spec; a
  list body is now `{:error, :unexpected_response_shape}`.
- **A forwarded `extended_hours: nil` reached `/pricehistory` as a blank value.**
  `get_historical_prices/5` read the option with `Keyword.get/3`, which returns a present
  `nil`; `needExtendedHoursData=` went out empty. It is read with `DpExchange.Core.Config.opt/3` like the
  rest of the family, so `nil` is absent and the parameter is `false`.
- **Option chain decode was quadratic.** `chain_side/3` and `chain_strikes/4` appended each
  expiry's and strike's contracts with `acc ++ rows`, copying the accumulator every time; an
  index chain with thousands of contracts did O(n^2) work. Contracts are collected per
  strike/expiry and flattened once; order and results are unchanged.

## [0.2.106] - 2026-10-11

### Fixed

- **A `Decimal` quantity with an absurd exponent was expanded before it was refused.**
  `Orders.build/2` checked NaN and Infinity, then called `Decimal.to_float/1`, which builds
  `10 ** exp` as an integer: `1E999999999` meant a billion-digit number in the caller's
  process. The exponent is now bounded to +-1000 (the limit `Rest` and prices already use;
  chosen, not measured) and a quantity outside it is `{:error, {:invalid_quantity, value}}`.
- **A price, stop price or offset written as text went out as written.** `" 6.45 "` kept its
  blanks and `"1E+2"` its exponent, and a text `stopPriceOffset` was a quoted string though the
  spec types it `number`. Text that reads as a finite number is now sent as that number, in
  full notation, as a `Decimal` already was (the offset as a bare JSON number).
- **`Orders.build/2` raised on a request that was not a map** (a keyword list, `nil`). It is
  `{:error, {:invalid_order_request, request}}`; the `@spec` takes `term()`.
- **The facade could raise after an order was placed.** `place_order/3` and `replace_order/4`
  build the returned `Order` with `Decimal.new/1` on the request's price, which raises on a
  text price with blanks that `Orders.build/2` had accepted; an unreadable value is now `nil`.
  A request with an explicit `order_type: nil` (a market order) read back as `order_type: nil`
  and now reads `:market`.
- **`replace_order/4` checked the request before the order id.** `Fake.replace_order/4`
  refuses an unusable id first, `Rest` does too but only after `Orders.build/2`, so a request
  wrong both ways got two different refusals. The facade now checks the id (after the account
  hash and the order-limit gate, before the request is built), so the facade, `Rest` and the
  fake agree.
- **`Fake.get_all_orders/2` did not exist** although the facade exposes `get_all_orders/2`.
  Added: it refuses what `Rest.check_all_orders_window/1` refuses (the window, the status
  enum, the 60-day rule with `opts[:now]`), needs no account hash, wants a credential, and
  returns the venue-shaped rows undecoded, narrowed by the window and status as
  `Fake.get_orders/2` is.
- **`Feed.unsubscribe/2` answered `{:error, :no_route}` before any route existed**, for a
  call with nothing to apply. It is `:ok` (the set is recorded and applied when a route is
  dialled).
- **A route that crashed after the last symbol was unsubscribed was redialled.** A Streamer
  session or a poller nobody had asked for was opened. With nothing wanted the route is left
  unset and the next `subscribe/2` or `update_symbols/2` dials it.
- **A zero or negative `price` or `stop_price` was sent.** For LIMIT, STOP, STOP_LIMIT and
  TRAILING_STOP_LIMIT it is now `{:error, {:invalid_price, value}}` before any request. The net
  types (NET_DEBIT, NET_CREDIT, NET_ZERO) are not checked: zero and negative are legitimate
  there, and this builder does not send them.
- **`Feed.update_credentials/2` with a non-map** is `{:error, {:invalid_credentials, value}}`,
  answered in the caller before the call, so the feed process is never reached.

## [0.2.105] - 2026-10-11

### Fixed

- **A caller-supplied order id, transaction id or account hash could change the request
  path.** `Rest` encoded these with `URI.encode/1`, which leaves `/`, `?` and `#` alone, so
  `cancel_order/4` (a `DELETE`) with `"1/../../orders"` addressed a different path and a `?`
  or `#` cut the path short; an integer id raised `FunctionClauseError` in the caller's
  process. Every segment is now encoded as one (`/` becomes `%2F`), an integer is its digits,
  and an empty or non-text value is `{:error, {:invalid_path_segment, :schwab}}` before any
  request. Applies to `get_balances/3`, `get_transactions/3`, `get_transaction/4`,
  `place_order/4`, `preview_order/4`, `replace_order/5`, `cancel_order/4`, `get_order/4`
  and `get_orders/3`.
- **`get_transactions/3` did not check its window.** The spec documents "Maximum date range
  is 1 year" for `/accounts/{accountNumber}/transactions` as it does for orders, but only the
  orders window was checked. A reversed window is now
  `{:error, {:transaction_window_reversed, :schwab}}`, one over 365 days
  `{:transaction_window_too_long, :schwab}` and an unreadable end
  `{:transaction_window_invalid, :schwab}`, before any request (also in the fake, through
  `Rest.check_transactions/1`). How the venue refuses these is not documented and not
  measured.
- **`get_accounts/2` returned rows it could not use.** A row that was not an object raised in
  `Access`, and a `hashValue` that was a number or blank was returned and then failed in every
  `/accounts/{hash}` path built from it. Either is now `{:error, :unexpected_response_shape}`.
- **A list passed as a query value raised in the caller's process** (`fields: ["positions"]`
  on `get_account_summaries/2` or `get_symbol_quote/3`). A list is now joined with commas,
  the form the venue documents for `fields`.
- **A `Decimal` struct, or a string, with an absurd exponent was accepted as a number.**
  `Rest`'s decimal reader passed a `Decimal` struct through untouched (NaN and Infinity
  included), and no reader limited the exponent: `"1e999999999"` parses as finite and the
  first compare or add against it allocates a billion-digit integer. `Rest`, `StreamerDecode`
  and `Orders` now treat NaN, Infinity and an exponent beyond +-1000 as not a number (the limit
  is chosen, not measured). A chain strike key goes through the same reader. In `Orders.build/2`
  such a price, stop price or offset is `{:error, {:invalid_order_field, key, value}}`.
- **`get_all_orders/2` did not apply the `/orders` 60-day rule.** The spec's `fromEnteredTime`
  on `GET /orders` reads "Date must be within 60 days from today's date"
  (`accounts-and-trading-production.openapi.json`, the `/orders` operation; the per-account
  endpoint has no such sentence). A start more than 60 days before now is
  `{:error, {:order_window_start_too_old, :schwab}}` before any request. Now is `opts[:now]`
  (a `DateTime`, for tests) or the clock. `Rest.check_all_orders_window/1` is the public check.
  How the venue itself refuses it is not documented and not measured.
- **`status` was sent unchecked on both orders endpoints.** It is the spec's `apiOrderStatus`
  enum (21 values, `Rest.order_statuses/0`). Anything else (a lower-case string, an atom) is
  `{:error, {:invalid_order_status, value}}` before any request, in `get_orders/3`,
  `get_all_orders/2` and the fake. `types` on `get_transactions/3` was already checked against
  the `TransactionType` enum. **Breaking for the fake:** `Fake.get_orders/2` used to accept
  `status: :working`; it now needs the venue's `"WORKING"`.
- **The fake accepted order ids the real path refuses.** `Fake.get_order/3`, `cancel_order/3`
  and `replace_order/4` now refuse an empty or non-text/integer id with
  `{:error, {:invalid_path_segment, :schwab}}` before looking at the credential, as `Rest`
  does, and read an integer id as its digits.

### Reviewed, no change needed

`get_price/3`, `get_prices/3`, `get_historical_prices/5` (period/startDate/endDate handling),
`market_status/2`, `get_market/3`, `get_movers/3`, `get_chains/2`, `get_option_chain/3`,
`get_positions/2` and `get_balances/3` decoding were re-read against the market-data and
trader specs; no other defect found.

## [0.2.104] - 2026-10-11

### Fixed

- **The fake's `get_orders/2` ignored the `from`/`to` window.** The venue requires
  `fromEnteredTime` and `toEnteredTime` on `/accounts/{accountNumber}/orders`
  (`accounts-and-trading-production.openapi.json`) and returns only orders entered inside
  them; the fake listed every order whatever the window. It now keeps an order only when
  its `enteredTime` falls inside the window (ends included). The canned order was entered
  `2026-01-02`, so a window that does not contain that date no longer lists it. A placed
  order is entered at the moment of placement (it was the fixed `as_of` date), so a window
  around now lists it.
- **An impossible order window is refused locally.** `Rest.get_orders/3`, `get_all_orders/2`
  and the fake (through `Rest.check_order_window/1`) now refuse, before any request, a window
  whose `to` is before its `from` (`{:error, {:order_window_reversed, :schwab}}`), one longer
  than a year (`{:error, {:order_window_too_long, :schwab}}`; the spec says "Maximum date
  range is 1 year" for the account endpoint, read here as 365 days, the stricter reading)
  and ends that are neither a `DateTime` nor a parseable ISO-8601 string
  (`{:error, {:order_window_invalid, :schwab}}`). How the venue itself refuses these is not
  documented and not measured, so none is sent. The all-accounts `/orders` endpoint documents
  "within 60 days from today's date" for `fromEnteredTime`; that is relative to the call and
  is not checked here.
- Order ids the fake's `replace_order/4` issues are accepted by its own `get_order/3` and
  `cancel_order/3` (covered by a test). `place_orders/3` and `close_position/3` are
  `:unsupported` on this venue, so they mint no ids.
- **A price, stop price or trailing offset that was not a number was sent as a string.**
  `Orders.build/2` ended in `to_string/1`, so `price: :market` went out as `"market"`,
  `price: "abc"` as `"abc"`, and `price: %{}` raised `Protocol.UndefinedError` in the
  caller's process. Anything that is not an integer, a float, a finite `Decimal` or a string
  reading as a finite number is now `{:error, {:invalid_order_field, key, value}}`, before
  a throttled write is spent.
- **`stop_price_link_basis` and `stop_price_link_type` were sent unchecked.** Both are enums
  in the spec (`MANUAL BASE TRIGGER LAST BID ASK ASK_BID MARK AVERAGE`; `VALUE PERCENT TICK`).
  A lower-case string or an atom reached the venue as something outside the enum. Any other
  value is now `{:error, {:invalid_order_field, key, value}}`.
- **`StreamerProtocol.subscribe/5` built requests the venue does not document.** `ADD`,
  `UNSUBS` and `VIEW` with no keys sent `"keys": ""`, and a key that was blank, not a string
  or contained a comma (read by the venue as two symbols) was joined into the request. Both
  are now `{:error, {:invalid_keys, keys}}`. `SUBS` with no keys is still accepted, because
  `Socket` turns it into an `UNSUBS` of what it holds, or nothing.
- **`StreamerInfo.from_user_preference/1` took the first of several `streamerInfo` entries**
  and accepted a non-string identifier. The schema makes `streamerInfo` an array; with more
  than one entry nothing says which is this session's, so it is now
  `{:error, :ambiguous_streamer_info}`, and a number, map or blank in the socket URL or any
  of the four `LOGIN` identifiers is `{:incomplete_streamer_info, fields}`.

### Reviewed, no change needed

`order_limit.ex` (a plain `Agent`; `status/1` answers `{:error, :not_started}` when nothing
runs under the name), `streamer_fields.ex` (every field number re-read against the
`market-data-production.txt` tables for LEVELONE_EQUITIES, OPTIONS, FUTURES,
FUTURES_OPTIONS, FOREX, the book services, CHART_EQUITY, CHART_FUTURES, SCREENER and
ACCT_ACTIVITY: all match), `streamer_decode.ex` and `auth.ex` (stateless; the one-time
refresh token is the host's to persist, as documented). The `LEVELONE_EQUITIES` sample frame
in the vendor prose shows a number at field 34 where the field table says "Quote Time in
Long"; the code follows the table and reads a non-integer there as no venue time.

## [0.2.103] - 2026-10-11

### Fixed

- **The fake read back a filled AAPL buy for every order, whatever was placed.**
  `place_order/3`, `replace_order/4` and `get_order/3` decoded one canned `FILLED` order, and
  `cancel_order/3` confirmed any id. The fake now remembers what was placed (per process) as
  the venue's own `Order` body, sent through JSON like the wire: the order reads back with
  its symbol, instruction, size and price in `WORKING` (`:open`) with nothing filled;
  `cancel_order/3` marks it `CANCELED`, `replace_order/4` marks it `REPLACED` and issues a
  new working order, and `get_orders/2` lists what was placed after one canned filled order,
  narrowed by `opts[:status]`. Cancelling or replacing an order that is no longer working is
  `{:refused, {:venue_error, 400}}`, and an id the fake never issued is
  `{:refused, {:venue_error, 404}}` on a read, a cancel and a replace, as `Rest.refusal/2`
  delivers them. Placed ids count up from `1005439901`; `1005439821` is the canned order.

- **The fake issued order ids and an account hash in a format the venue never produces.**
  `place_order/3`, `replace_order/4` and `get_orders/2` answered `fake-order-1` and
  `fake-order-2`, and `get_accounts/2` answered the hash `FAKEHASH`. The venue's `orderId`
  is an int64 (`accounts-and-trading-production.openapi.json`), which `Orders.from_venue/1`
  returns as a decimal string, and `accountNumbers` answers an opaque upper-case hex
  `hashValue`. A consumer that parsed the id as a number, or validated the hash, passed
  against the venue and failed against the fake. The ids are now numeric (a
  replacement is a new order), the hash is
  `9ABCDEF0123456789ABCDEF01234567`, and a numeric id reaches `Orders.from_venue/1` as the
  integer the wire carries.

## [0.2.102] - 2026-10-11

### Fixed

- **An expired access token on the fallback poll reported every wanted symbol as refused.**
  `/quotes` answering `401` or `403` reached `Feed` as `{:refused, {:venue_error, status, _}}`
  for each symbol in the failed chunk, and each was delivered as `{:refused, symbol, _}`:
  the venue stating it does not carry the symbol, which a consumer answers by dropping it
  from its scope. A token lives 30 minutes, so this was the commonest poll failure there is.
  A credential failure (`Auth.credential_failure?/1`) is now an ordinary failed cycle,
  retried, and surfaced by the poll's "delivered nothing" `:coverage_change` notice. `400`
  and `404` on a whole chunk are still reported per symbol; the vendor does not say whether
  one bad symbol in a batch refuses all of it.
- **A symbol argument that was not a list crashed the feed.** `subscribe/2`, `unsubscribe/2`
  and `update_symbols/2` passed it through to `Feed`, where `for symbol <- 5` or
  `MapSet.new(5)` raised; the feed restarted from its boot-time options and every
  subscription and pushed credential was lost. All three now answer
  `{:error, {:invalid_symbols, value}}` and change nothing.
- **The `:symbols` start option skipped the equity-only refusal.** `symbols: ["BTC-USD"]`
  entered `wanted` unchecked and was sent to the Streamer as an equities key, while the same
  symbol was refused by name on every later call. It is validated at start now and stops the
  feed with an `ArgumentError` naming the symbol.
- **A forwarded `limiter: nil` failed every REST call.** The facade used `Keyword.put_new/3`,
  which keeps a present `nil`; `Core.HttpClient` resolved it to Core's global limiter, which
  this package never starts. It is `Keyword.put/3` now, as `DpExchange.Schwab.Supervisor.limiter_name/1`
  already was.
- **`Fake.subscribe/2` raised under an injected `get_price` failure, and accepted what the
  real feed refuses.** It built its pushed quote through the public `get_price/2`, which
  consults `FakeInjection`, so a failure queued for `get_price` made it raise `MatchError`.
  It also dropped a pair-shaped symbol silently and answered `:ok`, cleared the subscribed
  set before refusing an `update_symbols/2`, and did not trim a padded symbol. It now
  refuses the sets the real feed refuses, with the same `{:invalid_symbols, _}`, and changes
  nothing when it does.

### Documentation

- **"Reads are unthrottled" overclaimed.** The vendor's sentence is "Get order requests are
  unthrottled", and it states no limit for market data or `previewOrder`. That is an absence
  in the document, not a measurement (`spec-facts.md` §4). `README.md`, `usage-rules.md` and
  `Supervisor` now say so.

## [0.2.101] - 2026-10-11

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.100] - 2026-10-11

### Fixed

- **A `MARKET` order carrying a `:price` was sent as a market order.** The caller may have
  believed they placed a limit; the order filled at any price. `Orders.build/2` now refuses
  a field the order type never reads: `{:price_not_allowed, type}` (a price on market,
  market-on-close, stop or trailing stop), `{:stop_price_not_allowed, type}` (a stop price on
  market, limit, the on-close types, or either trailing type) and
  `{:trailing_field_not_allowed, key, type}` (`:stop_price_offset`, `:stop_price_link_basis`
  or `:stop_price_link_type` on a non-trailing order). A forwarded `nil` is absent. Required
  fields are still reported first. Which fields each type reads is taken from the vendor's
  worked examples, not probed live.

- **`:invalid_instruction` named the side, not the bad value.** `instruction: :buy` reported
  `{:invalid_instruction, :sell}` when the request's side was `:sell`. It now reports the
  value the caller gave.

- **An option chain slot holding two contracts silently kept the last.** Schwab lists an
  array of contracts per strike, and an index's monthly and weekly roots (`SPX`/`SPXW`) can
  share an expiry and strike. `get_option_chain/3` overwrote the first with the second. It
  is now `{:error, {:ambiguous_chain_row, expiry, strike, right}}`; `get_chains/2` still
  returns every contract.

- **`last_trading_day` was a day late for evening stamps.** The venue stamps the day in the
  evening Eastern (its own examples `1655510400000` and `1702602000000` are 20:00 EDT and
  20:00 EST), and the UTC calendar day of that instant is the next one. The US Eastern day is
  used (US rule, 2007 onward; `nil` before, as no honest date exists without a zone
  database). Documentation-derived.

- **A price-history range bound that was not a `DateTime` was ignored.** An integer, `Date`
  or string `:start` fell through to `period` and the most recent window answered. It is now
  `{:error, {:invalid_range_bound, :start | :end, value}}`.

- **The lookback was truncated to whole days.** Ten days and an hour counted as ten and
  passed a one-minute request the venue cannot serve. It is rounded up.

- **A candle with `datetime: 0` was placed at 1970.** It is `:missing_venue_timestamp`, as a
  quote's zero time already was.

- **Dates the venue cannot read were sent anyway.** `get_chains/2` `:from_date`/`:to_date` and
  `get_market/3` `:date` stringified a `DateTime` into `"2026-03-01 12:00:00Z"`. They take a
  `Date` or a `YYYY-MM-DD` string, else `{:error, {:invalid_date, key, value}}`.

- **`market_status/2` raised on a non-string `:market` and sent an unlisted one.** It is
  checked against the venue's enum like `get_market/3`: `{:error, {:unknown_market, value}}`.

- **`get_movers/3` and `get_screener/3` sent any `sort` or `frequency`.** Both are checked
  against the venue's enums (`{:invalid_sort, v}`, `{:invalid_frequency, v}`). The doc's
  claim that `frequency` is "a number of minutes" is withdrawn: the vendor's description
  ("directions of up or down") does not say so. `Fake` refuses the same requests.

- **`get_instrument/3` did not escape its CUSIP as one path segment**, so `/`, `?` or `#` in
  it changed the path or query.

## [0.2.99] - 2026-10-10

### Fixed

- **A mutual-fund order was sent as an equity order.** `Orders.build/2` derived the leg's
  `assetType` from the ticker alone, and nothing in a ticker tells `SWPPX` from `AAPL`, so
  every non-option order went out as `EQUITY` although `capabilities/0` declares
  `:mutual_fund` and `:cash_equivalent`. The request's `:instrument_type` now sets it:
  `:mutual_fund` → `MUTUAL_FUND`, `:cash_equivalent` → `CASH_EQUIVALENT` (the Trader API's
  own values), none/`:equity` → `EQUITY`; an option symbol is always `OPTION`. Any other
  type is `{:error, {:unsupported_instrument_type, value}}`. Documentation-derived; no fund
  order has been placed live.

- **`update_credentials/2` could take a running feed down.** Anything that was not a map
  (`nil`, or the `{:error, _}` a failed `refresh_credentials/2` returned and the caller
  forwarded unchecked) reached the `Feed` process, which raised inside `handle_call/3`;
  `Supervisor` restarted it from its start-time options and every `subscribe/2` made since
  was gone. It now answers `{:error, {:invalid_credentials, :schwab}}` from the facade,
  before the feed is looked at, and the feed is untouched.
- **Documentation contradicted the code in several places a consumer reads.**
  `Rest.get_balances/3`'s `@doc` said a margin account's `available_balance` is its buying
  power; the code (and `usage-rules.md`) read `availableFunds`, because buying power is
  leveraged. `Rest.get_historical_prices/5`'s `@spec` promised `Quote.t()` and returns
  `Candle.t()`. `get_trade_history/2`'s `@doc` said it was neither declared `:experimental`
  nor `:unsupported`; it is declared `:unsupported` and answers `{:error, :not_supported}`.
  The README told a consumer to pin `~> 0.1.0` (no current release matches), said every
  endpoint is `:experimental` (the unserved ones are `:unsupported`), and named the internal
  `Auth.refresh/2` where `usage-rules.md` points at `refresh_credentials/2`. `Fake`'s
  moduledoc and `usage-rules.md` listed `get_rate_limit_status/2` among endpoints with a
  success path that lacks an injection point; it is `:unsupported` and has no success path.
  `Feed`'s moduledoc described one `/quotes` request per symbol where the fallback poll
  batches 100 per request, and its `wanted/1` `@doc` rendered a block of source comments as
  documentation. `StreamerDecode`'s moduledoc said `observed_at` "stands in" for an absent
  `venue_time`, which the code never does. Stale references to functions that no longer
  exist (`ensure_route/1`, `Rest.to_candle/3`, `get_market_status/1`, `Socket.subscribe/4`)
  now name the ones that do, and `Capabilities`' source comments no longer describe option
  chains, movers and positions as unimplemented.

## [0.2.98] - 2026-10-10

### Fixed

- **`get_option_chain/3` and `get_option_expirations/3` raised on a non-string
  underlying.** `:aapl` or `nil` hit a guarded clause and raised `FunctionClauseError` in the
  caller's process; an empty string reached the venue. Each now answers
  `{:error, {:invalid_underlying, value}}` through the new `Rest.check_underlying/1`, and
  `Fake` runs the same check before its credential check.

- **`Fake` refused in a different order from the real facade, and skipped refusals the real
  path makes.** The real account endpoints check the account hash, then the call's own
  parameters (order shape, time window, transaction type), and look at the credential last,
  when the request is signed. The fake checked the credential first, so a call missing both
  got `:missing_credentials` from the fake and `:missing_account_hash` in production. The
  fake also skipped `Rest.get_historical_prices/5`'s range checks (an end with no start, a
  start after its end), sized a bounded window by how long ago it began instead of by its
  span, accepted any transaction type, and checked the movers universe after the credential.
  It now calls `Rest.check_history/3`, `check_transactions/1`, `check_order_window/1` and
  `check_movers_universe/1` — the functions the real path uses — in the real order.
- **`Fake` answered values the real decode cannot produce.** `get_balances/2` reported an
  available balance of twice the total, though the real decode reads `availableFunds` so that
  it never exceeds it; `get_positions/1` returned a negative `notional_value` for a short and
  a `realised_pnl`, where the real decode is unsigned and the venue states no realised figure.
- **`get_chains/2` dropped `contract_type:` without a word.** The option table listed the key
  as `:contractType` only, so `contract_type: "CALL"` returned the full chain, calls and
  puts, where one side was asked for. Both spellings are sent now.
- **`Rest.get_transactions/3` raised on a non-string `:types`.** `types: :TRADE` matched no
  clause and raised `CaseClauseError` in the caller's process, and `types: [:TRADE]` was
  reported as "multiple types". Both are `{:unknown_transaction_types, [type]}` now, and
  `types: []` is `{:types_required, :schwab}`.
- **`Rest.get_movers/3` and `Rest.get_market/3` raised `FunctionClauseError` on a
  non-string name** (`:nasdaq`, `:equity`); they answer `{:unknown_movers_universe, _}` and
  `{:unknown_market, _}` like any other value outside the enum.
- **`Rest.get_symbol_quote/3` returned a non-object body as `{:ok, body}`**, against its own
  `{:ok, map()}` spec; it answers `{:error, :unexpected_response_shape}` like the other
  market-data reads.
- **`get_transaction/4` and `get_user_preference/2` specs on the facade promised `map()`**
  where the venue documents an array and the body is returned as sent; they now say
  `map() | [map()]`.

## [0.2.97] - 2026-10-10

### Fixed

- **A delayed quote was delivered as a live one.** An account without real-time
  entitlements is streamed rows marked `"delayed": true`; the flag was ignored, so a
  15-minute-old quote and book reached the consumer stamped `observed_at: now`. Delayed
  `LEVELONE_*` and `*_BOOK` rows are now withheld, with a `:degraded` notice once per symbol
  per session naming the symbol, service and reason. `CHART_*` candles carry their own
  bucket time and are still delivered.

- **`session` is validated against the venue's enum.** A request or option `session:` went
  onto the wire unchecked, and an atom encodes as its lower-case name, so a caller following
  `capabilities().supported_sessions` and passing `session: :pre_market` sent `"pre_market"`
  and spent a throttled order write on a rejection. `:regular`, `:pre_market`, `:post_market`
  and `:extended` now map to `NORMAL`, `AM`, `PM` and `SEAMLESS`; the venue's own values are
  accepted in any case; anything else is `{:error, {:unsupported_session, value}}`.
- **Order numbers.** A float `price`/`stopPrice` below `1.0e-4` went out as `"1.0e-4"` (plain
  notation now, as for a Decimal). A NaN or Infinity `Decimal` price or offset is refused as
  `{:error, {:invalid_order_field, key, value}}` instead of being sent as `"NaN"`, and a NaN,
  Infinity or out-of-range `Decimal` quantity is `{:invalid_quantity, _}` instead of raising
  in `Decimal.to_float/1`.
- **A feed subscription spelled differently from the venue's symbol delivered nothing.**
  `Feed` validated `" aapl"` as `AAPL` and sent `AAPL` to the Streamer but kept `" aapl"` in
  its wanted set, so every `AAPL` frame was dropped as unwanted, and `unsubscribe/2` could
  not remove it. `subscribe`, `unsubscribe`, `update_symbols` and the `:symbols` start option
  now store the canonical spelling.
- **`LEVELONE_OPTIONS` and `LEVELONE_FOREX` quotes now carry the venue's own times.** Fields
  38/39 (options) and 8/9 (forex) are documented as quote and trade time in milliseconds and
  were left unnamed, so those quotes reported `venue_time: nil` though the venue stamped
  them. `usage-rules.md` also wrongly said every streamed quote has `venue_time: nil`.
- **A streamer row with no `key` and no symbol field** was decoded into a `Quote`, `Candle`
  or `OrderBook` with `symbol: nil`; it is now dropped.

## [0.2.96] - 2026-10-10

### Changed

- **`dp_exchange_core` 0.3.61.** The fallback poll's `[:dp_exchange, :link, …]` telemetry now
  names `provider: :schwab`, the same atom as its notices, instead of the label string
  `"schwab-fallback-poll"`. A telemetry handler matching the string must match the atom.

### Fixed

- **`get_historical_prices/5` empty series.** The venue's `{"empty": true, "candles": []}`
  (CandleList carries both as siblings) returned `{:ok, []}` because the rows clause matched
  first; `{:refused, :not_listed}` now fires. Whether `empty: true` can also mean "listed,
  no bars in window" is unmeasured and documented as ambiguous.
- **`get_historical_prices/5` ranges.** A range with only `:end` was ignored (most recent
  window ending now). It is now `{:error, {:range_start_required, :schwab}}`, and a start
  after its end is `{:error, {:range_start_after_end, :schwab}}`.
- **`market_status/2`** read an absent `isOpen` as `:closed` and the string `"false"` as
  open. Only a boolean counts; none present is `{:error, :unexpected_response_shape}`.
- **`get_account_summaries/2`, `get_all_orders/2`, `get_transactions/3`** wrapped a map body
  into a one-row list. They now refuse it as `:unexpected_response_shape`.
- **Declared order ceiling of `0`** was floored to 1/min by the limiter arithmetic and
  permitted a write per minute. `place_order/3`, `replace_order/4` and `cancel_order/3` now
  answer `{:error, :order_limit_zero}` locally.
- **`time_in_force: nil`** is treated as absent (default `:day`) instead of refused.

## [0.2.95] - 2026-10-10

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.94] - 2026-10-10

### Fixed

- **A wanted-set update went to the Streamer as one frame per service.** The venue documents
  `FAILED_COMMAND_SUBS` (code 22) as caused by "two or more commands are processed in
  parallel causing one to fail", so one of the three could be lost until the next periodic
  resubscribe. `Feed` now sends them in one envelope. `Socket.subscribe/5` is replaced by
  `Socket.subscribe_all/2`, which sends a list of commands as one frame.

## [0.2.93] - 2026-10-10

### Fixed

- **A `Feed` without `:subscriber` subscribed itself, and every message looped.** The default
  was `self()` inside `init/1`. `Supervisor` passes no `:subscriber`, so the supervised tree
  delivered each quote back to the Feed, which delivered it again. Notices were relayed twice.
  There is now no default: subscribers arrive through `subscribe/3`'s `to:`.
- **A position holding both a long and a short quantity lost the short leg.** Each leg is
  now its own position. A row with both legs carries `nil` `notional_value`, and each leg's
  cost comes from `averageLongPrice` or `averageShortPrice`.
- **Positions from every account were merged with no account label.** With more than one
  account, `get_positions/2` now needs `:account_number`, and is
  `{:error, {:account_number_required, n}}` without it.
- **`notional_value` carried the venue's sign.** It is now unsigned, because `:side` carries
  the direction.
- **A margin account's `available_balance` was `buyingPower`.** That is leveraged, so a $50k
  account reported $200k available inside a $50k balance. It is now `availableFunds`.
- **A balance that did not parse as a number was accepted** and became `nil` downstream. It
  is now `{:error, :unexpected_response_shape}`.
- **A book level with no size was kept as `{price, nil}`.** It is now dropped, as a level
  with no price already was.
- **A poll quote queued when the route upgraded to the stream counted as `:stream`.** Each
  poller's deliveries are now tagged, and a stale one is dropped.
- **`Socket.last_top` kept every symbol ever framed until a reconnect.** A `LEVELONE_*`
  `SUBS` or `UNSUBS` now drops the book for the symbols it removes.
- **`subscribe/3` and `update_symbols/2` accepted symbols the REST route refuses** and sent
  them to the Streamer unchanged. They are now `{:error, {:invalid_symbols, symbols}}` before
  anything changes.

### Changed

- **`place_order/3` and `replace_order/4` return an `Order`, not the bare id.** `Core.Venue`
  types both as `Order.t()`, and a consumer matching `%Order{}` across venues broke on this one.
  The order is read back with `get_order/3`, a read and not a throttled write. If the read back
  fails, the order is still placed, so the answer is `{:ok, %Order{id: id, status: :pending}}`
  built from the id and the request.
- **`cancel_order/3` returns `{:ok, :cancelled}`**, the shape `Core.Venue` now declares for a
  cancel whose answer carries no order. It returned a bare `:ok`, which matched none of the
  `{:ok, _} | {:error, _} | {:refused, _}` shapes every other call returns.

## [0.2.92] - 2026-10-10

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.91] - 2026-10-10

### Fixed

- **An order request with no `:order_type` and a `:price` went out as a MARKET order.** It carried the
  caller's `:price`, which a market order ignores. A type-less request with a price or stop price is now
  `{:error, {:missing_order_field, :order_type}}`.
- **An explicit `:instruction` silently overrode a contradicting `:side`.** `side: :sell,
  instruction: "BUY"` sent BUY. The two must now agree, or the request is
  `{:error, {:conflicting_order_fields, ...}}`.

## [0.2.90] - 2026-10-10

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.89] - 2026-10-10

### Fixed

- **Twelve facade reads skipped the supervised rate limiter.** `get_positions`,
  `get_option_chain`, `get_option_expirations`, `get_screener`, `get_transactions`,
  `get_transaction`, `get_account_summaries`, `get_all_orders`, `get_symbol_quote`,
  `get_market`, `get_instrument` and `get_user_preference` passed raw `opts` to `Rest`. In a
  supervised deployment they used the default limiter instance, not
  `DpExchange.Schwab.RateLimiter`. All now go through it, as `get_price` already did.
- **The fallback poll kept the token it started with.** Its fetch closed over
  `state.credentials`, so `update_credentials/2` never reached it. A feed held on `:poll` past
  the access token's 30 minutes got a 401 on every fetch for good. The fetch now reads the
  current credential each cycle.
- **A reconnect that failed before LOGIN retried at full speed.** The backoff read only
  `login_failures`, which stays 0 when the network is down, so an instant ECONNREFUSED or DNS
  failure spun and flooded `:link_down`. `websockex`'s `attempt_number` now counts too.
- **A LEVELONE frame that moved no book field republished the book.** A trade-only delta sent
  the carried bid and ask with `observed_at: now` and no `venue_time`, a stale book presented
  as fresh. On a symbol's first frame it sent `nil` levels, which read as "no resting order".
  A top of book is now published only when the frame moves a book field.
- **REST `get_price/3` dated a last-trade price by `quoteTime`.** That is the last bid/ask
  update and can be much newer than the trade. `lastPrice` is now dated by `tradeTime` first,
  matching the Streamer. `mark` and `nAV` still use `quoteTime` first.
- **A refresh with no `expires_in` kept the old token's expiry.** `needs_refresh?/2` then said
  yes on every call, and each call spent the one-time refresh token again. The old
  `:expires_at` now goes with the old token.
- **Unsubscribing the last symbol of a service never reached the venue.** Nothing was sent for a
  service with no wanted symbols, so it kept streaming until a reconnect. `Feed` now sends an
  empty `SUBS`, and `Socket` turns that into an `UNSUBS` of exactly the keys its session holds.
- **The fallback poll spent one request per symbol per cycle.** At the default 120-a-minute
  read ceiling, it could not finish a cycle past about 60 symbols. New `Rest.get_prices/3`
  sends up to 100 symbols per `/quotes` request, and the poll uses it.
- **Smaller fail-closed gaps.**
  - `get_transactions` and `get_transaction` now URI-encode the account hash.
  - An instrument search body without `instruments` is now an error. It used to be an empty
    match, because `%{}` matches every map.
  - A `Location` ending in `/` is now "order id not returned", not `{:ok, ""}`.
  - A non-UTC `DateTime` keeps its milliseconds, because it is converted to UTC first.
- Two tests that proved little: one slept 20 ms before asserting the feed was alive, and one
  held a bootstrap 2 s against a 1.5 s deadline. They now synchronise on messages.

### Documentation

- The read and order ceilings are stated as metered. Reads, previews included, share a courtesy
  120-a-minute bucket. Order writes share one bucket across every account a supervisor serves,
  because `Core.DefaultRateLimiter` does not read `:scope`. The docs said reads were unthrottled
  and orders were metered per account.

## [0.2.88] - 2026-10-05

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.87] - 2026-10-03

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.86] - 2026-10-02

### Fixed

- **Requires dp_exchange_core `~> 0.3.50`**, the first release whose `Quote` has the
  `volume_window` field this package now sets. The old floor admitted core releases
  without it, and a consumer resolving one would fail to compile. Locks 0.3.51, which also
  stops a blocking request being metered twice: a feed pacing itself with
  `rate_limit_blocking: true` had been running at half its declared ceiling.

## [0.2.85] - 2026-10-02

### Changed

- **Every `Quote` that carries a volume now says which quantity it is**, in
  `volume_window` (dp_exchange_core 0.3.50, dp-exchange-core issue #42). The Streamer's
  `last_size` is `:print`, one trade, to sum. The REST quote's `totalVolume` is
  `:running_total`, the trading day's cumulative total, to difference. Both were in
  `Quote.volume` with nothing to tell them apart.

## [0.2.84] - 2026-10-02

### Fixed

- **A Streamer LOGIN that is never answered now ends the connection instead of stalling
  it.** Every command waits for the LOGIN response, so a server that answered pings but
  not the LOGIN left the socket holding its subscriptions indefinitely while the ping
  check reported it alive. The socket now gives each LOGIN 30 seconds. If nothing comes
  back, it raises a `:degraded` notice with `details.reason: :login_unanswered` and
  reconnects. The reconnect is not backed off, because the venue rejected nothing. The
  same shape was measured on Gemini on 2026-10-02. The 30-second bound was not measured
  against Schwab, because a LOGIN needs a credential this repo never holds.

## [0.2.83] - 2026-10-01

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.82] - 2026-09-29

### Fixed

- `get_symbols/2` skips an instrument row that is not an object, or whose `symbol` is not a
  string. Either raised in the caller's process.

## [0.2.81] - 2026-09-29

### Fixed

- A quote whose `lastPrice` is `0`, an instrument that has not traded, falls back to `mark`
  as when `lastPrice` is absent. The `||` chain stopped at the `0` and delivered a price of
  zero. A zero `nAV` with no other price is refused.
- A `quoteTime` of `0` is no time: `tradeTime` is used, or the venue time is `nil`. A zero
  became a venue time of 1970-01-01, which every staleness check reads as decades old.

## [0.2.80] - 2026-09-29

### Fixed

- A short position's `unrealised_pnl` is read from `shortOpenProfitLoss`. It was
  `longOpenProfitLoss || shortOpenProfitLoss`, and `0` is truthy, so a short position whose
  reply carried `"longOpenProfitLoss": 0`, the ordinary shape, reported zero P/L. The field
  is now chosen by the position's side. Found by a spec-example test.

### Added

- Spec-example tests: every REST call and every Streamer service this package decodes,
  driven with the vendor's documented examples (or cited schema-built instances, since the
  trading document publishes none), with requests checked against the documented
  parameters. Fixtures and their sources are under `test/fixtures/spec_examples/`.

## [0.2.79] - 2026-09-29

### Fixed

Checked against the vendor's committed OpenAPI documents and Streamer guide.

- `get_orders/2` sends the `fromEnteredTime`/`toEnteredTime` window the venue requires,
  from `:from`/`:to`, and refuses locally with `{:error, {:from_and_to_required, :schwab}}`
  without one. It sent no window, so per the vendor document it could not succeed.
- A MARGIN account's balance total is read from `equity`. It was read from
  `liquidationValue`, which `MarginBalance` does not carry, so every margin balance in the
  documented shape was refused.
- Order and transaction time filters are formatted `yyyy-MM-dd'T'HH:mm:ss.SSSZ` for any
  `DateTime` precision. A sub-second `DateTime` produced `...00.123.000Z`.
- `get_historical_prices/5` sends `startDate`/`endDate` for an explicit range. The range was
  used only to size `period`, so the series ended at the previous close.
- Option expirations read the schema's `expiration` as well as the example's
  `expirationDate`; option contracts read `isMini`, `isNonStandard` and `isIndexOption`,
  which were always `nil`.
- `preview_order/4` sends the documented `PreviewOrder` body, with the order under
  `orderStrategy` and legs as `orderLegs`.
- `stopPriceOffset` is sent as a JSON number, without float rounding.
- `get_transactions/3` sends a single `types` value; more than one is refused with
  `{:error, {:multiple_transaction_types, :schwab, types}}`.
- A per-symbol `QuoteError` (`invalidSymbols` and siblings) is read as not listed.
- Streamer response codes 26-29 are success; they raised a false `:degraded` notice.
- A position's open P/L is `unrealised_pnl`; it was reported as `realised_pnl`. The venue
  publishes no realised figure, so that is `nil`. `MUTUAL_FUND` positions are `:fund`.
- Level-one equity, futures and futures-option frames carry their venue time (fields 34/35
  and 10/11); it was always `nil`.
- The docs no longer claim that refreshing keeps a refresh token alive indefinitely. The
  vendor states a refresh token is valid for 7 days after creation.

## [0.2.78] - 2026-09-29

### Fixed

- The streaming bootstrap reads the `/userPreference` response in the shape the vendor's
  OpenAPI documents, an array of `UserPreference`. `StreamerInfo.from_user_preference/1`
  accepted only a single object and answered `:no_streamer_info` for the array, so a feed
  given the documented shape fell back to polling every time. A one-element array is read as
  its element. More than one is `{:error, :ambiguous_user_preference}`, which falls back to
  polling rather than guessing which preference is the signed-in user's.
- `get_user_preference/2` and `get_transaction/4` specs now say `map() | [map()]`, as the
  vendor documents both as arrays, and either refuses a body that is neither.
  `get_instrument/3` refuses a body that is not an object, as its spec already promised.

## [0.2.77] - 2026-09-29

### Fixed

- `get_option_expirations/3` refuses an `expirationList` that is not a list, instead of
  answering `{:ok, []}`, "no expirations". `get_screener/3` refuses a `screeners` that is not
  a list, which raised in the caller's process before. A
  screener row that is not an object is dropped like one with no symbol, instead of raising.
- An order whose `orderLegCollection` holds a leg that is not an object, or is not a list, is
  refused. Such legs were filtered out, and a two-leg spread with one unreadable leg came
  back as a single-leg order carrying the other leg's symbol and side.
- `get_movers/3` and `get_market/3` refuse a body that is not an object, as their specs
  already promised. They returned the body as sent, so a list reached `get_screener/3`,
  which read it as an object and raised.

## [0.2.76] - 2026-09-29

### Fixed

- `get_positions/2` refuses a reply in which an account's `positions` is not a list, or an
  entry has no `securitiesAccount` object. Either used to contribute nothing, so that account
  read as holding no positions. An account with no `positions` field, or a `null` one, still
  holds none.
- Locked `dp_exchange_core` 0.3.48.

## [0.2.75] - 2026-09-29

### Fixed

- A refresh refused with `invalid_client` now returns
  `{:refused, {:client_credentials_rejected, status, detail}}` instead of
  `{:refused, {:reauthorization_required, ...}}`. That error code means the app's client
  pair is wrong, not that the grant is dead (RFC 6749 §5.2), so a rotated or mistyped
  `client_secret` used to send a person to log in again, and the login did not help. Any
  other refusal keeps the terminal answer. The code is the OAuth standard's and has not yet
  been observed from Schwab.
- Locked `dp_exchange_core` 0.3.47.

## [0.2.74] - 2026-09-28

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.73] - 2026-09-28

### Fixed

- **The fake upper-cases subscribed symbols, as the real facade has since the previous
  release.** `Fake.subscribe/2`, `unsubscribe/2` and `update_symbols/2` took symbols exactly
  as given. So a `btc-usd` subscription delivered nothing against the fake while the real
  package delivered `BTC-USD`, and a consumer's tier-1 tests certified silence where the
  venue delivers.

## [0.2.72] - 2026-09-28

### Fixed

- **A lower-case symbol subscribes under its canonical form again.** `subscribe/2`,
  `unsubscribe/2` and `update_symbols/2` now upper-case their symbols. The previous release
  made `Feed` drop a payload for a symbol it does not want. The venue delivers the
  canonical upper-case symbol, so a `btc-usd` subscription received nothing, where before
  it had received data. Measured 2026-09-28: `update_symbols(["btc-usd"])`, then a
  `BTC-USD` quote, and `coverage/1` was `%{}`. Case is the only difference normalised.

## [0.2.71] - 2026-09-28

### Fixed

- **A frame arriving after `unsubscribe/2` is no longer delivered or counted.** A venue
  keeps sending for a moment after an unsubscribe. Those frames used to reach the
  subscribers who had just asked to stop, and they re-entered delivery tracking, which
  `unsubscribe/2` had just pruned. A streaming route has no staleness window, so one late
  frame left `coverage/1` answering `:stream` for an unsubscribed symbol indefinitely.
  `Feed` now drops a payload whose symbol it no longer wants.

## [0.2.70] - 2026-09-28

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.69] - 2026-09-28

### Fixed

- **The Streamer socket no longer keeps every subscription it has ever sent.** Each
  subscribe added `{service, keys}` to a set in the socket's state, keyed by the whole
  symbol list, and nothing ever read it. Only a reconnect emptied it, so every change of
  symbol set held another full key list for the life of the connection. Measured
  2026-09-27: 500 subscribes left 501 entries, and the state grew from 108 to 11,011
  words. The field is gone. A test pins that repeated subscribes leave the state the same
  size.

## [0.2.68] - 2026-09-28

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.67] - 2026-09-28

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.66] - 2026-09-28

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.65] - 2026-09-28

### Changed

- **`decimal` may now resolve to 3.x** (`~> 2.0 or ~> 3.0`), alongside `dp_exchange_core`
  0.3.41, which widened the same way. Decimal 3.0 makes the mitigations for
  CVE-2026-32686 the default, so an input such as `1e1000000000` is rejected rather than
  materialised. This package's full suite, its REST mutation fuzz and its socket frame
  fuzz were run on 3.1.1 first, with numbers of more than 34 digits added to the fuzz
  values, since 3.x refuses to parse those. All pass with no raise and no hang.

## [0.2.64] - 2026-09-27

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.63] - 2026-09-27

### Fixed

- **A streaming facade call answers instead of exiting the caller's process.**
  `subscribe/2`, `unsubscribe/2`, `update_symbols/2`, `subscribe_notices/1`, `coverage/1`
  and `coverage_by_kind/1` called into `Feed` with a bare `GenServer.call/3`, which exits
  the caller when no `Feed` is running (`:noproc`) or when one is too busy to answer in
  its call budget (`:timeout`). Every one of these callbacks is specified to return a
  value. An `alive?/1` check covered a `Feed` never started, but not one that died between the check and the call, or a busy one. They now answer `{:error, :feed_not_started}` (`:ok` for `unsubscribe/2`),
  `{:error, :feed_timeout}`, or `{:error, {:feed_exited, reason}}`, and the coverage calls
  answer an empty map.

## [0.2.62] - 2026-09-27

### Security

- **The WebSocket now verifies the venue's TLS certificate.** websockex defaults to
  `insecure: true`, which is `verify: :verify_none`, and this package passed no TLS
  options. So its `wss://` connection accepted any certificate, from anyone able to sit
  on the network path, who then received everything sent after the upgrade, credentials
  included. Measured 2026-09-27: against a local TLS server with a certificate from a CA
  nothing trusts, the handshake completed and the upgrade request went out. The socket
  now defaults `:ssl_options` to `verify: :verify_peer`, the operating system's trust
  store (`:public_key.cacerts_get/0`) and HTTPS hostname matching. A caller may pass its
  own `:ssl_options`. This venue's live endpoints (`streamer-api.schwab.com`) were checked the same day
  and verify under these options. HTTP requests were never affected, because Mint
  verifies by default.

## [0.2.61] - 2026-09-27

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.60] - 2026-09-27

### Fixed

- **The WebSocket opening handshake now has a deadline: `socket_connect_timeout` plus
  `socket_recv_timeout`.** websockex bounds each `recv` of the HTTP upgrade response
  separately, and every chunk restarts that timer. So a peer that trickled the response
  held a start open indefinitely, which blocked `Feed` inside a `handle_call/3` and queued
  every other consumer's call behind it. It could do the same to a reconnect, where the
  socket delivered nothing and its silence check could not run. Measured 2026-09-27
  against a local server sending one byte every 200 ms: still connecting at 12 s. The
  attempt now ends at the deadline with `%WebSockex.ConnError{original: :timeout}`, the
  error a timed-out `recv` already produced.
- **A malformed WebSocket close frame no longer crashes the socket.** websockex 0.5.1
  raised `CaseClauseError` on a close frame with an invalid status code, before
  `handle_disconnect/2` could run. `dp_exchange_webull` found this live, and its fix is now
  here as well. The frame now disconnects and reconnects like any other close.
- Both fixes come from `DpExchange.Schwab.Vendor.WebSockex`, a private patched fork of
  websockex 0.5.1's process loop, carried from `dp_exchange_webull`. The `websockex`
  dependency is pinned `== 0.5.1`, up from `~> 0.4`, because the fork calls that
  release's internals.


## [0.2.59] - 2026-09-27

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.58] - 2026-09-27

### Fixed

- **A spread leg with a huge-exponent quantity no longer stalls order decoding.**
  `Decimal.integer?/1` accepts a quantity such as `"1E999999999"`, and
  `Decimal.to_integer/1` then builds the whole integer. At `1E10000000` that already took
  longer than 4 seconds in the caller's process (measured 2026-09-27). The magnitude is
  now compared first. A leg above 10^12, a bound that was chosen rather than measured,
  gets no ratio, the same result a fractional quantity already gives.

### Fixed

- **A token response with an extreme `expires_in` no longer stalls `refresh/2`.** The
  value went straight to `DateTime.add/3`. That function computes a date for any offset,
  and for 10^24 seconds it took longer than 4 seconds in the caller's process (measured
  2026-09-27). The venue documents 1800 seconds. Anything above one day, a bound that was
  chosen rather than measured, is now read as no expiry claim, which an absent
  `expires_in` already was: the credential refreshes on a 401.

## [0.2.57] - 2026-09-27

### Fixed

- **A response value of the wrong type raised inside the caller's process.** Found by
  mutating every value of real response bodies into wrong shapes, across ten read calls:
  - `get_balances/3`: a `currentBalances` that was not an object raised `BadMapError`.
  - `get_positions/2`: a position row, or its `instrument`, that was not an object raised
    in `Access`.
  - `get_option_chain/3`: a contract entry that was not an object raised in `Access`.

  Each is now refused as `{:error, :unexpected_response_shape}`, following the policy the
  code already states: a row this package cannot read refuses the reply rather than being
  dropped, so a missing entry is never read as "none held". An absent `currentBalances`
  is still an empty one. 0 raising mutations remain. Break-verified: all three new tests
  fail on the previous code.

## [0.2.56] - 2026-09-27

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.55] - 2026-09-26

### Fixed

- **A Streamer frame whose `response` or `content` entries were not objects crashed the
  socket.** Both were read as maps, and a raise in `handle_frame/2` drops the connection.
  Found by mutating every value of real frames into wrong shapes. Such entries are now
  skipped, like an unrecognised frame. Break-verified: both new tests fail on the previous
  code.

## [0.2.54] - 2026-09-25

### Fixed

- **A half-open Streamer connection stayed "connected" indefinitely.** It delivered
  nothing and was never reconnected, and on this venue overnight silence is normal, so
  nothing else would notice. The Streamer's heartbeat notifies have no documented
  interval, so each connection now pings every 30s (RFC 6455 requires a pong). After 90s
  with no frame or pong it raises a `:degraded` notice (`:silent_connection`) and closes,
  taking the ordinary reconnect-and-LOGIN path. Also corrects a `handle_connect/2` comment
  that still said a pre-login subscribe is refused (it has been held since 0.2.48).
  Break-verified: three of the four new tests fail on the previous code.

## [0.2.53] - 2026-09-25

### Fixed

- **Candles kept whatever order the venue sent.** `get_historical_prices/5` returned the
  `candles` rows in arrival order, and the vendor's document does not state one. They are
  now sorted oldest first by `opened_at`, as the other venues in this family already
  sort them and as `Core.Venue` now documents. Break-verified: the new test fails on the
  previous code.

## [0.2.52] - 2026-09-25

### Fixed

- **A poller crash during a background return to the Streamer could leave the feed with
  no route at all.** When the fallback poller crashed while an upgrade bootstrap (added in
  0.2.50) was in flight, the request for a new route joined that bootstrap and kept its
  upgrade flag. If the bootstrap then failed, it "stayed on" a poll that no longer existed,
  so the feed had no route and nothing that would start one until a consumer called
  `subscribe/2` again. Joining an in-flight bootstrap now always makes it an ordinary one,
  which falls back to a fresh poll on failure. Break-verified: the new test fails on the
  previous code.

## [0.2.51] - 2026-09-25

### Fixed

- **A slow Streamer bootstrap crashed every caller waiting on it.** The first
  `subscribe/2` or `update_symbols/2` on a feed with no route waits for
  `GET /userPreference`, and so does every call that joins it. That bootstrap is allowed
  95s (`HttpClient`'s own retry budget), but the caller's `GenServer.call` gives up at 15s,
  so each waiting caller EXITED and took its process down. Each caller now arms a reply
  deadline at two thirds of the call timeout and is answered
  `{:error, {:route_pending, ms}}` if the bootstrap is still running. Its symbols are
  already wanted and are applied when the route settles. `usage-rules.md` §14 says so.
  Break-verified: the new test fails on the previous code.

## [0.2.50] - 2026-09-24

### Fixed

- **A feed that fell back to the poll never returned to the Streamer.** Once
  `/userPreference` failed, the route stayed `:poll` for the life of the process: the
  `:resubscribe` tick only re-armed itself on that route, and `update_credentials/2` only
  pushed a token into a socket that did not exist. One 5xx at startup, or a token the host
  refreshed a minute later, cost the feed its candles (socket-only) and its Streamer quotes
  until a restart. Each tick on the poll route now retries the bootstrap in the
  background, and `update_credentials/2` retries at once. On success the socket takes
  over, the poller is stopped and `wanted` is re-issued, with an `:info`
  `:coverage_change` notice. On failure the running poll continues, with no second poller
  and no repeated `:degraded`. A credential the venue refused is retried only when it
  changes. `usage-rules.md` §14 now says so, and its stale "up to 60 seconds of silence
  after a reconnect" is corrected. Break-verified: the three new tests fail on the
  previous code.

## [0.2.49] - 2026-09-24

### Fixed

- **A reconnect left the Streamer silent for up to a minute.** A reconnect clears the
  venue's subscriptions, and `Feed` only re-asserted them on its 60s timer. `Socket` now
  reports each successful RE-login (`{:dp_exchange, :schwab, :relogged_in, pid}`), the first
  moment a `SUBS` can land. The first login is excluded because its commands are already
  held and released. `Feed` re-asserts `wanted` at once without re-arming the timer.
  Break-verified: the new socket and feed tests fail on the previous code.

## [0.2.48] - 2026-09-24

### Fixed

- **Every Streamer bootstrap dropped its first subscription.** `WebSockex.start_link/4`
  runs `handle_connect/2`, which queues LOGIN, before it returns, and `Feed` subscribes the
  moment it does. Its `SUBS` were therefore handled a network round trip before the LOGIN
  response could arrive. `Socket` dropped them with a spurious `:degraded` "not logged in"
  notice, and streaming data began only when `Feed`'s periodic re-assert fired, up to 60s
  later. `subscribe/4` is a cast that always answers `:ok`, so its documented
  `{:error, :not_logged_in}` was never returned either. A command that arrives before
  LOGIN succeeds is now validated, held, and sent in one envelope once the LOGIN succeeds.
  A held `SUBS` supersedes earlier held commands for its service, the hold is capped at 64
  with a `:degraded` refusal past that, and a failed LOGIN keeps the hold for the next
  connection. Break-verified: three socket tests fail on the previous code.

## [0.2.47] - 2026-09-24

### Fixed

- **A LOGIN the venue refused without closing the connection left the Streamer dead
  indefinitely.** LOGIN is sent only when a connection opens, and after any refused LOGIN
  `Socket` waited for the venue to close the socket. The vendor's response-code table marks
  only `3 LOGIN_DENIED` (and `12`) as `Connection Severed: Yes`. `11 SERVICE_NOT_AVAILABLE` is
  `No` and `9 UNKNOWN_FAILURE` is `TBD`. A LOGIN answered with `11` therefore left an open
  socket that was never logged in and never retried. `Feed` passed the `:degraded` notice on
  and nothing else, every later subscribe got "not logged in", and a refreshed token never
  reached a LOGIN. Now any failed LOGIN makes `handle_frame/2` answer `{:close, state}`. The
  local close takes the same backed-off `handle_disconnect/2` path as a remote one and
  reconnects with a fresh LOGIN. Break-verified: four socket tests fail on the previous
  code. `usage-rules.md` now says a refused login is retried.

## [0.2.46] - 2026-09-24

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.45] - 2026-09-24

### Fixed

- **`get_order/3` and `get_orders/2` returned the venue's raw JSON, not `Types.Order`.** Both
  are `@impl` of `Core.Venue` callbacks typed `result(Types.Order.t())` and
  `result([Types.Order.t()])`, and both handed back Schwab's map as it arrived. A consumer
  writing venue-agnostic code that matched `%Order{}`, or read `order.status`, broke on this
  venue and only this one. **The fake did the same**, so the conformance suite — which drives
  fakes — could not see it, and two tests pinned it: one asserted `{:ok, %{}}` for an EMPTY
  OBJECT as a successful order, one asserted the raw `%{"orderId" => "1"}`. Found by feeding
  the real facade plausible response bodies and reading what came back.

  `Orders.from_venue/1` now decodes the OpenAPI `Order` object, used by both the facade and the
  fake so they cannot drift. Read from the vendor's committed OpenAPI document and not probed
  live — this repository holds no Schwab credentials. A value Core has no word for becomes
  `nil`, never the nearest atom: `TRAILING_STOP` is not `:stop`, `REPLACED` is not
  `:cancelled`. `WORKING` is `:partially_filled` only when the venue's own `filledQuantity`
  says so. A spread reports its legs with ratios over their greatest common divisor and no
  single top-level symbol or side. An order with no `orderId` is refused, and so is a list
  containing one. `enteredTime`'s colon-less `+0000` offset is parsed.

  The fake's `get_orders/2` now answers one order rather than `[]`, which made every check
  over its elements vacuous.

- **Both option endpoints raised on an array.** `get_option_chain/2` read
  `body["callExpDateMap"]` and raised `ArgumentError` from `Access` on a list;
  `get_option_expirations/2` raised `BadMapError`. Both now refuse a non-object body with
  `:unexpected_response_shape`, the atom this package's `Auth` already uses.

  Found by feeding every active facade callback a set of plausible-but-wrong bodies — `[]`,
  `null`, `{}`, an object whose list fields are all `null`, and `{"data": {}}` — and
  flagging any call that raised, or that answered with a wrapper as a row or a record with
  no identity. `Core.Venue`'s error discipline is that a facade answers and never raises in
  the caller's process. `response_shape_test.exs` pins each body that used to fail, driven
  through the facade, red against the previous code.

## [0.2.44] - 2026-09-23

### Fixed

- **A forwarded `nil` option was used as the value instead of meaning "not set".** This
  family forwards `opts` unchanged through every layer, so an option a caller's own caller
  never set arrives as `key: nil`, and `Keyword.get/3` substitutes its default only for an
  ABSENT key. `Core.Config.opt/3` exists for exactly this; these call sites predated it and
  now use it.

  The one that mattered most was **`:to`**, and its two halves failed in opposite
  directions. The real `Feed` put `nil` in its subscriber set, and `Core.Fanout.deliver/4`
  resolves `nil` the way it resolves any name nothing answers to — nobody — so
  `subscribe/2` answered `:ok` and **data never arrived**. The fake called `send(nil, _)`,
  which raises. A consumer's tier-1 tests could not have shown them the real behaviour even
  by accident: the fake crashed where the venue went quiet.

  **`:limiter`** returned `nil` from `DpExchange.Schwab.Supervisor.limiter_name/1`: the limiter started
  unnamed while REST resolved `limiter: nil` to `Core.DefaultRateLimiter`'s global default —
  a different, usually absent limiter.

  **`:name` was deliberately left alone.** There `nil` is not "unset" — it is OTP's own way
  to say "do not register this process", and this package's test support starts unnamed
  feeds with it. The first pass converted it too and several test files went red at once,
  which is how that was found; it is recorded so it is not tried again. `:credentials` is
  unchanged as well, since `nil` and `%{}` already end in the same `missing_credentials`
  refusal.

  Each changed call site is tested red-before, green-after: `forwarded_nil_test.exs` drives
  `Feed.subscribe/3` and `subscribe_notices/2` against a probe standing in for the feed
  process, so what is measured is exactly the client-side resolution that changed. Core's
  conformance suite gains assertion 27 for the fake half.

## [0.2.43] - 2026-09-15

### Fixed

- **A blank `:client_secret` turned a misconfiguration into a terminal "a person must log in
  again".** `refresh/2` trimmed `:refresh_token` and `:client_id` and checked `:client_secret`
  with `is_binary/1` alone, so a blank secret passed the local gate and went out as
  `Basic base64("client_id:")`. Schwab answers a bad client pair with 401; `do_refresh/5`
  maps 400/401/403 to `{:refused, {:reauthorization_required, ...}}`, which this module
  documents as **terminal** — seven days elapsed, or the user reset their password, fixable
  only by a person at a browser. So a host with an unset config value was told its grant was
  dead and a human was needed, when the remedy was a string it already had somewhere else.
  Every value plausible, only the meaning wrong.

  All three fields are now checked the same way, and a blank one takes the
  `{:missing_credentials, :schwab}` branch, whose contract says nothing was sent and nothing
  is spent. The test had the same shape as the code: it enumerated all three deletions and
  exactly one blanking, so the field nobody blanked was the field nobody trimmed. It now
  blanks all three.

## [0.2.42] - 2026-09-15

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.41] - 2026-09-14

### Fixed

- **`read_limit_per_minute: 0` divided by zero in the limiter.** `limits/1` floored the order
  ceiling at 1 and not the read ceiling, so a host that registered no read throughput — a
  value `validate_ceiling!/2` accepts by name, deliberately, because zero is a legal
  registration — handed `DefaultRateLimiter` a `limit: 0`, which is the divisor in its GCRA
  arithmetic. The limiter died on the first REST call and was restarted into a crash loop.

  The floor went in with `schwab_orders`, the key whose default is `0` and so the obviously
  reachable one; the read key is just as reachable and was never asked the same question. The
  test covering it had the same shape — it asserted `schwab_orders.limit >= 1` and stopped
  there. It now asserts over every entry, so a key added later cannot reopen this by simply
  not being listed, and a companion test pins that the floor moves zero and nothing else: a
  floor that rounded every small ceiling up would pace a host faster than it registered for,
  which is a worse failure than the crash it replaces.

  The floor is on the arithmetic, never on the declaration. `capabilities/0` keeps saying what
  this application was actually registered for.

- **An order price or size could go onto the wire in scientific notation.**
  `Decimal.to_string/1` defaults to `:scientific`, and `to_string/1` on a `%Decimal{}`
  reaches that same default through `String.Chars` — so a value carrying an exponent was
  serialised as `"1.5E+2"` or `"1E-8"`. That is not a number this venue reads, and a
  different order if it read one at all.

  **An exponent is not exotic.** `Decimal.normalize/1` — the ordinary way to strip trailing
  zeros — turns `150.00` into `1.5E+2`, and anything below a millionth carries one by
  construction: `Decimal.new("0.00000001")` is `1E-8`. A caller normalising a price before
  placing an order is doing something entirely reasonable.

  Every money field now goes through a helper that asks for `:normal` explicitly, and the
  generic map-building helpers refuse a `%Decimal{}` before it can reach `String.Chars` at
  all — so a money field added to a payload later cannot reintroduce it.

  This was found in four of the five venue packages at once. Each of them already said
  `:normal` *somewhere* — in a conversion helper, a withdrawal amount, an option parameter —
  and none of them had said it on the order path, which is the one that spends money.

## [0.2.40] - 2026-09-14

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.39] - 2026-09-14

### Fixed

- **A timed-out order write was retried, and could place the order twice.**
  `place_order/4`, `replace_order/5` and `cancel_order/4` forwarded `:retry_attempts` into
  `Core.HttpClient`, which retries anything that is not a 4xx — a timeout, a connection
  reset, a 503. Those are exactly the failures where the venue may have **received and acted
  on** the request before the connection broke, so the retry places a second order and the
  caller sees one call and one answer.

  Retrying is only safe where the venue can tell the second attempt from the first. Schwab
  publishes no idempotency key for these endpoints — `dp_exchange_coinbase` and
  `dp_exchange_robinhood` both send a `client_order_id` their venues document as one, which
  is why their writes may retry and these may not.

  Order writes are now sent exactly once, and `:retry_attempts` is no longer forwarded at
  all, so a caller passing its own opts through cannot re-enable it. Reads are unchanged.

  **A transport failure on an order write now means the outcome is unknown**, which it
  always did — it was simply being hidden by an automatic second attempt. `usage-rules.md`
  says so, and says to read your open orders rather than placing again.

- **A venue timestamp outside the epoch range raised out of the decoder, and zero quietly
  became 1970.** The time helpers used `DateTime.from_unix!/2`, which handles neither case.

  **Out of range RAISES.** A venue moving a field from seconds to milliseconds, or from
  milliseconds to microseconds, is ordinary drift — and the value it sends is `invalid Unix
  time`, thrown out of the read rather than returned by it, where the function's own contract
  already offers `{:error, :missing_venue_timestamp}`.

  **Zero and negative do NOT raise.** They become 1970 and earlier, which is worse, because
  the result is a perfectly valid `DateTime` a caller cannot tell from the venue's own
  instant — and `0` is a common venue sentinel for "unknown". This package had already ruled
  that out in as many words for level timestamps ("an unreadable level timestamp does not
  become the epoch"); the rule now holds wherever an epoch is converted.

  Both answer `{:error, :missing_venue_timestamp}`. Tests cover each, and there were none for
  either path before.

## [0.2.38] - 2026-09-14

### Fixed

- **The fallback poll's notices named the poll where the venue belonged.** `provider` and
  "which feed inside this venue spoke" were one field, and the label won it — so this
  package emitted `:schwab` from `Socket`'s link notices and `"schwab-fallback-poll"` from
  the poll's. A consumer matching `notice.provider == :schwab` missed every notice the
  fallback poll raised, including the one saying the fallback poll is delivering nothing.

  Core 0.3.17 separated the two, so the label can stay as deliberately unambiguous as its
  own comment requires — a `:coverage_change` pasted into an issue must not read as the
  Streamer going dark — without costing the venue its name. `provider` is now `:schwab`
  and `details.label` is still `"schwab-fallback-poll"`. The `dp_exchange_core` floor
  moves to `~> 0.3.17`: below that the option does not exist and is silently ignored.

## [0.2.37] - 2026-09-14

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.36] - 2026-09-14

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.35] - 2026-09-14

### Fixed

- **The periodic re-assert discarded its own result, so one that could not run said
  nothing.** `handle_info(:resubscribe, %{route: :stream})` called `apply_symbols/1` and
  threw the answer away. That function returns `:ok`, `{:error, :no_route}`, or whatever
  `PollingFeed.update_symbols/2` returns — and `route: :stream` with no socket is a reachable
  shape, because `apply_symbols/1`'s stream clause is guarded `when is_pid(socket)` and
  anything else falls through to `{:error, :no_route}`.

  A periodic re-assert is the only thing that recovers a subscription the venue has quietly
  stopped serving, so one that cannot run is exactly the event worth knowing about.
  `dp_exchange_webull` spent three issues on a blind resubscribe that failed without saying
  so. A failure is now a `Logger.warning` naming the reason and how many symbols are
  affected; nothing is torn down, because the route may be mid-rebuild and reacting here
  would race `ensure_route/1`.

  **A successful re-assert stays silent, and that is now pinned by a test.** This timer fires
  on every interval for the life of the feed, so a line on the happy path would be one per
  tick forever — which is `dp_exchange_webull`'s issue #2, where 234 of 239 ERROR lines in a
  single boot described routine behaviour until ERROR stopped carrying information on that
  host. Both directions were broken on purpose and both fail.

  Found by running dialyzer with `:unmatched_returns`, which is **not** enabled by default.

### Changed

- `Feed` now `require Logger` — it had no log line at all before this.

#### On the dialyzer flag itself, since it is not being adopted

`:unmatched_returns` was run across all six repositories as an experiment and found nine
sites. Eight are idiomatic and correct: `Process.cancel_timer/1` where the answer genuinely
does not matter, `if Process.alive?(socket) do … end` with no `else`, a discarded timer
reference, and one `:xref.set_default/2` whose failure would only make a check noisier. One
was real, and it is fixed above.

Enabling the flag family-wide would mean annotating those eight with `_ =` — and an
unexplained `_ =` reads as unexplained in a codebase whose style is to say why. One
substantive finding in nine does not pay for that, so the flag stays off and the measurement
is recorded here instead of being repeated by the next person who wonders.

## [0.2.34] - 2026-09-13

### Changed

- **A crashed POLLER was never tested, only a crashed socket.** `Feed` has two
  `{:EXIT, pid, reason}` clauses — one matching `state.socket`, one matching
  `state.poller` — and only the socket one had ever executed. The poll route is this
  venue's documented degraded mode, so the untested clause is precisely the one that runs
  when the venue is *already* not serving the Streamer.

  Without that clause the `:EXIT` reaches the catch-all and is ignored, leaving a feed whose
  `route` still says `:internal_poll` while the process doing the polling is gone —
  `coverage/1` answering for a route nobody serves. That is the same truthfulness question
  the socket-crash test beside it already asks. Verified by deleting the clause, which turns
  the new test red.

- **`get_top_of_book/2`'s facade clause was never executed at all.** Every assertion went to
  `Rest` directly, so a delegate wired to the wrong function — or one dropping the
  `with_limiter/1` wrap — would have passed the whole suite. It was also missing from the
  "every read refuses without credentials" sweep, which is where the other reads are held.
  Both halves are now covered, and the wrong-delegate case was performed on purpose and
  fails.

  No delegation was wrong. Found by reading which lines the suite never executes, with the
  `def ... \\ []` head artifact filtered out — a multi-line default-argument head is counted
  separately from its body and never runs, so most of what that report flags is noise.

  Coverage 91.44% to 91.76%.

## [0.2.33] - 2026-09-13

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.32] - 2026-09-13

_No consumer-facing changes. Internal or packaging work only — recorded so every published version has a heading, because an absent one cannot be told apart from one the release pipeline dropped._

## [0.2.31] - 2026-09-13

### Fixed

- **`usage-rules.md` said `get_price/3` always carries a real `venue_time`.** That stopped
  being true in 0.2.29, when a quote row carrying neither `quoteTime` nor `tradeTime` stopped
  being refused and started coming back with `venue_time: nil` — and the documentation did
  not follow. `usage-rules.md` is what a consuming agent reads, so a consumer taking that
  advice had a latent crash on a field this package had just started returning.

  It now tells a REST caller to write the `nil` branch, names `get_historical_prices/5` as
  the case that still refuses (because `Core.Types.Candle` enforces `:opened_at`), and
  restates what has not changed: nothing is ever substituted into `venue_time`.

### Changed

- `usage-rules.md` now states three consumer-visible behaviours from 0.2.30 that shipped
  without a consumer-facing note: the streamed order book's ordering guarantee, that a
  `LEVELONE_*` frame with a NaN last price is refused rather than delivered with
  `price: nil`, and that a screener row the venue did not name is dropped — leaving a gap in
  `rank` rather than renumbering the survivors.

## [0.2.29] - 2026-09-13

### Fixed

- **A streamed order book came back in the venue's row order, so `hd(bids)` was not the best
  bid.** `Core.Types.OrderBook` makes this part of the contract and anticipates the mistake
  by name: *"The ordering is part of the contract, not a convenience: a caller reading
  `hd(bids)` as the best bid is reading it correctly, and a venue package that returns
  venue-order without re-sorting has broken the contract even though every value in it is
  true."*

  A test asserted the opposite — "levels keep the venue's ordering" — and carried no
  reasoning for it. Its own fixture was the tell: an ASCENDING bid list, which is exactly the
  order that contract calls broken. It is kept rather than deleted, with its expectation
  corrected and the reasoning recorded, because the fixture is the useful part: it is the
  case that was wrong.

  `dp_exchange_coinbase` was the one package in the family already sorting, so the family had
  both answers running at once. The sort matches its `sorted/2`, including
  `{direction, Decimal}` rather than term order, because `Decimal` structs do not compare
  correctly as plain terms.

  `Core.Types.OrderBookDelta` is the genuine exception and says so separately — its entries
  "arrive in the venue's own order". This package decodes snapshots, which that type
  contrasts itself against as having "eager, sorted `bids`/`asks` lists".

## [0.2.28] - 2026-09-13

### Fixed

- **A streamed quote whose last price was a NaN or Infinity was published with
  `price: nil`.** `StreamerDecode.to_quote/3` guarded only `when last != nil` in the head
  and then assigned `price: decimal(last)` — and `decimal/1` answers `nil` for exactly the
  poisoned values this module's own comment documents at length ("NaN", "Inf", "-Inf" and
  their case variants all parse fully). The guard was doing its job; its *output* was then
  put straight into a field `Core.Types.Quote` lists in `@enforce_keys`, and `Quote.new/1`
  refuses a `nil` there in as many words — "a nil here is what a decode bug on a renamed
  venue field produces".

  The asymmetry is the point, and it is why this survived: a `nil` **bid** is legitimate
  (`TopOfBook` says a one-sided book is real, and the NaN test covers it), a `nil` **price**
  is not. The guard was applied to one decoder in this module and not its neighbour, while
  `Rest.build_quote/2` already used `required_decimal(raw_price, :price)` for the same field
  on the other transport.

  `:volume` is unchanged and still reads through `decimal/1`: it is not enforced, so an
  unreadable last size is `nil` and the quote still stands.

- **A screener row the venue did not name was published with `symbol: ""`.**
  `Core.Types.ScreenerResult` enforces `:symbol`; `row["symbol"] || ""` satisfied that while
  saying nothing. An empty string is worse than the `nil` it replaced — a `nil` is
  detectable, `""` is a value, so a consumer keying coverage by symbol gets a live entry
  named `""`.

  Such a row is now dropped, the rule `dp_exchange_robinhood` already states for the same
  situation: "a row missing `symbol` entirely is dropped rather than published under a
  fabricated one". Dropped **after** `Enum.with_index/2`, so a survivor keeps the position
  the venue returned it in — closing the gap would re-rank the list, which this endpoint's
  own ordering comment rules out.

  Both found by a mechanical audit of every literal struct construction in the family
  against the fields its Core type requires non-nil — the check `new/1` performs and 85
  literal constructions bypass.

## [0.2.27] - 2026-09-13

### Fixed

- **A REST quote the venue did not date was refused outright.** `build_quote/2` gated on
  `{:ok, timestamp} <- venue_time(row)`, so a row carrying neither `quoteTime` nor
  `tradeTime` — or carrying one this package could not read — discarded a real, already
  guarded traded price over a field `Core.Types.Quote` does not enforce. It lists
  `[:symbol, :price, :observed_at, :provider]`, and `observed_at` states freshness and is
  always present.

  This package's own **streamer** arm had already decided it the other way, and said so:
  `StreamerDecode.to_quote/3` sets `venue_time: nil` under "**`nil`, and that is the fix**
  … there is nothing venue-stamped to put here — and `nil` says exactly that, which is a
  different fact from 'quoted at 14:53:02'." Same venue, same type, the opposite answer
  decided by transport.

  The guarantee those comments exist to protect is untouched: an unstated venue time is
  `nil`, never this package's clock. That is what dp-exchange-core issue #31 split the field
  to prevent, and the tests now assert it directly instead of inferring it from an `{:error,
  _}` — which could not tell a `nil` from a substitution in the first place.

  `get_historical_prices/5` is unchanged and still refuses: it builds a `Candle`, which does
  enforce `:opened_at`, so a bar this package cannot place in time would otherwise land in
  the series at an invented minute.

  Third venue in this family with the same defect, found by sweep after `dp_exchange_gemini`
  and `dp_exchange_webull`.

## [0.2.26] - 2026-09-13

### Fixed

- **A streamed `TopOfBook` published the venue's delta as though it were the book.**
  `LEVELONE_*` is **Change** delivery — the vendor's own service table gives that type to
  `LEVELONE_EQUITIES`, `LEVELONE_OPTIONS`, `LEVELONE_FUTURES` and
  `LEVELONE_FUTURES_OPTIONS`, and defines it as *"Only fields that clients are interested in,
  and have changed, are streamed to the client. Data is conflated by the streamer."* A frame
  there states only what moved.

  `Socket` emitted each frame straight through, so a frame that moved only the ask produced
  `%TopOfBook{bid: nil, bid_size: nil, ask_size: nil}`. `Core.Types.TopOfBook` defines those
  `nil`s: a `nil` bid is *"an illiquid instrument [that] can genuinely have no resting bid,
  and a venue that says so is telling the truth"*, and a `nil` size *"means 'not published',
  never 'none available'"*. Neither claim was the venue's. On a liquid equity the bid
  vanished on every frame that moved only the other side.

  Every value in it was real and came from the venue; only the meaning was wrong — the
  failure mode this family names as its recurring one, and the reason it survived review is
  that the delivery type had been read correctly and written down, and the conclusion drawn
  from it was "so `nil` is permitted" rather than "so this is not a book yet".

  Each frame is now merged onto the last book published for that symbol, and the SNAPSHOT
  crosses the facade. Presence decides, not value: `StreamerProtocol.rename/2` builds its map
  only from field numbers the frame carried, so a key means the venue spoke. A field present
  but unreadable — a NaN, which has its own guard and tests — is **not** carried forward,
  because the venue did say something and answering with the previous value would invent an
  answer to a question that was actually asked.

  The merge state is per connection and is dropped on reconnect alongside `subscriptions`,
  for the same reason those are dropped: a level from a session the venue no longer has is
  not one this package will keep asserting.

  This is also a facade fix. A consumer able to tell a Change service from an All Sequence
  one by the shape of its values is a consumer who can see how this venue works.

  `CHART_*` (All Sequence) and the book services (Whole) deliver complete units and are
  unchanged — nothing is merged for those, and a missing candle price is still refused.

### Changed

- `usage-rules.md` now states that a streamed `TopOfBook` is a merged snapshot: consumers
  must not accumulate frames themselves, a side not yet reported by the current session is
  `nil` and indistinguishable from a genuinely absent one, and a reconnect rebuilds the book.

## [0.2.25] - 2026-09-12

### Fixed

- **A position row the venue did not attribute to an instrument was reported as a position.**
  `Core.Types.Position` enforces `:symbol` and its `new/1` refuses a `nil` there, but this
  decoder builds the struct literally — as every decoder in this family does — so that check
  never ran and the symbol came through by key. A position naming no instrument cannot be
  sized, closed or reconciled by anyone: it is not a weaker claim about what is held, it is
  not a claim at all, and it sat in a list of real positions looking like one.

  One unattributable row now refuses the whole reply rather than being dropped. A position
  list with an entry silently missing reads as "you hold none of that instrument", which is a
  different and more dangerous claim than "this response could not be read".

- **A reconnect-timing test failed under load while the behaviour was correct.** It asserted
  the attempt-1 path returns in under 500ms, which is stricter than the claim needs — the
  claim is "no backoff was applied", and the smallest backoff is a full second, so any time
  under one proves it. Measured against that boundary now. Same shape as the rate-limiter
  bucket race and `Core.PollingFeed`'s poll-interval waits: a timing assertion that holds
  when the machine is quiet and inverts when it is not.

## [0.2.24] - 2026-09-12

### Fixed

- **A streamed chart bar could carry a `nil` price.** `StreamerDecode.to_candle/3` built
  `%Core.Types.Candle{}` literally and put the four prices through bare `decimal/1`, which
  answers `nil` for an absent, empty, unparseable, NaN or Infinity value. `Candle` enforces
  all four and its `new/1` refuses a `nil` in any of them, but nothing here called `new/1`, so
  a bar with a `nil` `open` sat in the series looking like every other bar.

  **The venue's own documentation says such a frame cannot happen**, which is what makes
  refusing correct rather than merely strict. Its Streamer table gives `CHART_EQUITY` and
  `CHART_FUTURES` the delivery type **All Sequence** — *"All data is streamed to the client
  and includes a sequence number"* — as against **Change**, *"Only fields that clients are
  interested in, and have changed, are streamed"*. A missing price on a `CHART_*` frame is a
  decode fault, not a partial update.

  That distinction is why `to_top_of_book/3` still carries a `nil` bid or ask and was left
  alone: `LEVELONE_*` **is** Change delivery, a frame there genuinely omits what did not move,
  and `Types.TopOfBook` permits `nil` for exactly that reason. Same package, opposite answer,
  because the venue says something different about each service — now asserted in both
  directions so a later tightening cannot be copied from one onto the other.

  `Rest.to_candle/3`, the REST arm of the same type, already guarded all four. This was the
  copy that did not.

## [0.2.23] - 2026-09-12
### Changed

- **`usage-rules.md` documents the error shapes this package started returning this week.**
  Several calls that used to answer `{:ok, _}` with a value a consumer could not act on now
  refuse instead, and none of those refusals had reached the document a consuming agent
  actually reads. CLAUDE.md is explicit that `usage-rules.md` "is not optional and it is not
  the README", and shipping the behaviour without it left a consumer to discover the new
  shapes from a crash.

  A consumer matching only `{:ok, _}` needs no change. One that enumerates error reasons now
  has them, each with whether retrying is worth anything — which is the part that decides
  what a caller does next, and the part a bare list of atoms would leave out.

## [0.2.22] - 2026-09-12

### Fixed

- **`mix.lock` moved to `dp_exchange_core` 0.3.10.** It carries two conformance-suite
  consolidations and two test-isolation fixes in Core's own suite; for this package the
  effect is that every fake call the contract suite makes now builds its arguments through
  one builder, so this venue's `endpoint_opts` and `endpoint_symbols` reach all of them
  rather than only the call sites that happened to be wired. `mix.lock` is committed and CI
  honours it, so the pin allowing the newer Core was never the same thing as running it.

## [0.2.21] - 2026-09-12

### Fixed

- **Two conformance assertions were inert here, and are not any more.** Core's assertions 14
  (`get_top_of_book/2` returns a `TopOfBook` with a `DateTime` `observed_at` and no `price`
  field) and 23 (`Quote`/`OrderBook` carry the venue's own time or `nil`, never an unparsed
  stand-in) both called this package's fake with no credential — those endpoints are
  public-SHAPED, so a credential can only travel in `opts`, and nothing put one there. This
  package answered `{:error, {:missing_credentials, _}}` and the assertions' skip-on-refusal
  clause took that for an answer.

  Measured: with a fake deliberately returning `observed_at: nil` — the exact defect
  assertion 14 exists to catch — this package's contract suite passed clean against Core
  0.3.8. Against 0.3.9 it fails, on exactly the endpoints `capabilities/0` declares active.
  Locked forward accordingly; `mix.lock` is committed and CI honours it, so the pin allowing
  the newer Core was never the same thing as running it.

## [0.2.20] - 2026-09-12

### Fixed

- **`mix.lock` moved to `dp_exchange_core` 0.3.8, so assertion 24's refusal check runs
  here.** 0.3.8 stops that assertion accepting a refusal from an endpoint `capabilities/0`
  declares active — the clause that let three packages pass an assertion which never
  executed on them. The pin already allowed the new Core, but `mix.lock` is committed and CI
  runs `mix deps.get`, which honours it: "the pin allows it" and "CI resolves it" are
  different statements and only the second one decides what actually runs.

## [0.2.19] - 2026-09-12

### Fixed

- **This package was passing fake-driven conformance assertions that never ran.** Several
  assertions in `Core.AdapterContract` call an active endpoint through this venue's fake,
  and every account-scoped one was refused for the missing account before it reached the
  behaviour under test. The suite took that refusal as a legitimate answer and skipped —
  green, and proving nothing.

  Caught by deliberately breaking this package's fake against Core's new assertion 24
  (a `Balance` must name the asset it is a balance of): the suite stayed green. It was never
  confined to 24 — **assertion 17, the credential gate, had been passing for the wrong
  reason**, getting its expected failure from the absent account rather than from the
  stripped credential it exists to test.

  The contract test now declares `endpoint_opts:`, Core 0.3.7's new option, naming the
  option each of this venue's own endpoints needs. Verified the way the gap was found: with
  the fake broken on purpose, the suite now fails.

## [0.2.18] - 2026-09-11

### Fixed

- **The reconnect backoff crashed during a long storm — the one thing it existed to
  survive.** `reconnect_delay_ms/1` computed `min(base * round(:math.pow(2, failures - 1)),
  max)`, and `:math.pow/2` raises `ArithmeticError` once the exponent passes 1023, because
  the float range ends at ~1.8e308. Clamping the *result* does not help: the raise happens
  while computing the argument to `min/2`.

  This is the function's own stated scenario, not a contrived one. Its moduledoc says a
  `LOGIN_DENIED` "means the venue will keep severing the connection for exactly as long as
  this process keeps presenting the same access token", and only a host calling
  `Auth.refresh/2` changes that. At the 30-second cap, the 1025th consecutive rejection is
  about 8.5 hours in — an access token that expired overnight with nobody on hand to refresh
  it, which is precisely what the backoff is for. The crash then landed inside
  `handle_disconnect/2`, reading as this socket's fault rather than the credential's.

  The existing cap test asserted 10 and 100 failures, both comfortably inside the float
  range, so neither reached it. Now `Bitwise.bsl/2` with the exponent clamped before the
  shift, and a test at 1024, 1025, 5000 and 100000.

  Found while giving `dp_exchange_coinbase`, `dp_exchange_gemini` and `dp_exchange_webull`
  the reconnect backoff they had none of — this package's was the family's only one, so its
  arithmetic was what got copied, and one test for a large attempt number caught it in all
  four at once.

- **`get_balances/3`'s `currency: "USD"` was an assumption with nothing saying so.** The
  venue publishes no currency field: verified against the vendor's own OpenAPI document,
  `docs/reference/schwab/openapi/accounts-and-trading-production.openapi.json`, 2026-09-11 —
  the string `"currency"` does not occur in it at all, and the only `Currency` schema is an
  `assetType` enum for a position's instrument, a different question from what the account
  is denominated in.

  The value is almost certainly right, resting on the Trader API being US-domiciled
  brokerage accounts. That is a documented fact about the product and not a field this
  package read, and CLAUDE.md is explicit about the difference — "Declare what you measured,
  not what you assume... An unlabelled number is worse than a missing one." It is now
  labelled, with what would falsify it. This is the only hardcoded currency on a real decode
  path anywhere in the family; every other literal like it is in a `Fake`.

## [0.2.17] - 2026-09-11

### Fixed

- **`subscribe_notices/2` could kill the caller for asking during trouble.** It was the one
  public call in `Feed` left on `GenServer.call/2`'s five-second default timeout. Every
  sibling call — `subscribe/3`, `unsubscribe/2`, `update_symbols/2`, `coverage/1` — is given
  `@call_timeout`, which is this package's own statement of how long the feed may
  legitimately take to answer on a busy mailbox.

  A consumer registers for notices at start-up, which is precisely when that mailbox is
  deepest: the transport is coming up, symbols are being resolved, and the handler itself may
  replay a notice to the newly-registered subscriber. A `GenServer.call/3` timeout exits in
  the **caller**, not in the feed — so the channel a host uses to hear that something is
  wrong was the one call that could take the host's calling process down for asking under
  exactly the conditions it exists to report.

  Now uses `@call_timeout` like every other call. The test blocks the feed's own process for
  six seconds — past the old default, nowhere near the new timeout — and asserts both that
  the call succeeds and that it genuinely queued behind the block, so it fails on the
  unfixed code rather than passing for free.

## [0.2.15] - 2026-09-11

### Fixed

- **A `200` this package could not decode became an empty object, and then an empty
  everything.** `decode/1` collapsed any unparseable body to `%{}` in both `Rest` and `Auth`.
  `%{}` is a map, so it passed straight through the account, order and quote readers and came
  out as a well-formed struct with every field `nil`, returned as `{:ok, value}`.

  **Half of this was already found and fixed once, for lists only.** The note on the
  `is_map or is_list` clause says it exactly: "an account list that is empty because the
  parser dropped it looks exactly like a credential with no linked accounts." The same
  sentence was true of every other reader and was left standing for them — a fix applied
  where it was found rather than where it applied.

  **`get_price/3` turned an unreadable body into a claim about the venue's listings.** An
  undecodable `200` became `%{}`, `%{}` has no key for the symbol, and a missing key means
  `{:refused, :not_listed}` — permanent, not worth retrying. So an interstitial, a captive
  portal or a CDN maintenance page, each of which answers `200 text/html`, came back as
  "Schwab does not carry AAPL". The venue's real "not listed" answer is a `200` whose JSON
  object simply omits the symbol; that decodes fine and is unchanged.

  Success bodies now refuse with `{:error, {:undecodable_response, :schwab}}`, for every
  shape rather than for lists alone. The endpoints whose `2xx` body is legitimately empty —
  a placed or replaced order, which answers `201` with the id in `Location`, and a cancel,
  which answers with nothing — never came through the decoder and are unaffected. `Auth.refresh/2`
  now names a decode failure rather than reporting `:unexpected_response_shape` for a body
  that was not a token response at all. Refusal bodies keep the lenient decode on purpose.

- **`"NaN"` and `"Inf"` from a venue became real `Decimal` prices and flowed through
  untouched.** Every numeric field in this package funnels through a `decimal/1` helper whose
  binary clause uses `Decimal.parse/1` and requires the whole string be consumed — the
  family's established idiom, and the fix for a venue sending the literal `"null"` in a price
  field. **That guard is not sufficient on its own.** `"NaN"`, `"Inf"` and `"-Inf"` all parse
  *fully*, and case-insensitively: `"-nan"`, `"inf"` and `"Infinity"` too. Each one arrived as
  a well-formed `Decimal` and was admitted as a price.

  That is worse than the raise the parse replaced, because it fails a long way from the
  cause. Measured:

  - `Decimal.add(nan, 1)` is `NaN` — it poisons a consumer's arithmetic **silently**.
  - `Decimal.compare(nan, _)` **raises** `invalid_operation: operation on NaN` — in the
    consumer's own process, with a message naming `Decimal` rather than the venue that sent
    it, and a stacktrace pointing nowhere near this package.
  - An `Infinity` is quieter still: it never raises and compares greater than everything, so
    it silently wins every "is this the best price" test a consumer makes.

  **Found where it was fixed, not where it applied.** `dp_exchange_webull` hit this and
  guarded both of its own copies; the other four venues guarded **none at all — this one had 2**. Every
  copy in the family now rejects a non-finite value the same way it rejects an unparsable
  one — as absent, which is what a price that is not a number actually is.

  Tested per venue at the decode seam, and the tests were verified against the *unguarded*
  helper first: eight of ten fail without the check. They cover the lowercase and mixed
  spellings too, since a guard matching only the canonical `"NaN"` would let `"inf"` straight
  through.

## [0.2.14] - 2026-09-11

### Added

- **`script/check_doc_sources.sh` now reports the age and provenance of this package's own
  capability claims.** `capabilities/0` carries `measured_at` and `measured_against` because
  CLAUDE.md is explicit — *"Declare what you measured, not what you assume. If it was
  measured, say when and against what."* Both were populated and **nothing read them**: not
  the weekly checker, not a test, not a line of consumer documentation.

  That is the same shape as the `MANUAL` documentation rows before they were aged — a claim
  that quietly gets old while still reading as current. The check reports the age against the
  same `STALE_DAYS` threshold, and reports a missing `measured_against` as its own finding,
  because half the rule is not the rule.

  Reported, never enforced. A stale measurement is not a build failure; it is a venue nobody
  has re-checked, and only a person re-measuring can fix it.

- **`usage-rules.md` tells consumers those fields exist and what to do with them.** They ship
  inside the Hex tarball and are what a consuming agent reads, and none of the five mentioned
  provenance at all. The distinction worth acting on is not the date but
  `measured_against`: a figure measured live against the venue's API and one read off a
  documentation page and never probed are different kinds of claim, and this package's
  declarations contain both.

### Fixed

- **The first version of that check would have reported `MISSING` on every venue, forever.**
  It grepped for `measured_against: "…"` on one line. Every venue in this family states the
  field as a multi-line `<>` concatenation, because the honest answer is a paragraph — which
  documents, which endpoints, measured live or read from a page. A single-line grep matches
  none of them.

  Recorded rather than quietly corrected, because the same mistake was made twice in the same
  hour: the reading that produced the check also concluded `measured_against` was unset
  across the whole family, and came within one commit of replacing five accurate provenance
  statements — including this one's — with a flat "not probed against the live API". For
  `dp_exchange_gemini` that would have been **false**: its statement records timeframes and
  candle windows measured *live* against `api.gemini.com`. A checker that cannot see a value
  is not evidence the value is absent.

  The field is now detected by presence and reported as a `file:line` pointer rather than
  quoted. These statements run to a paragraph each and the clause that matters is rarely the
  first one, so an excerpt in a weekly notice would mislead more than it informs.

## [0.2.13] - 2026-09-11

### Fixed

- **A Streamer bootstrap that never answered stranded every `subscribe/2` caller, for the
  life of the feed.** `start_route_bootstrap/2`'s "already in flight" clause makes every
  later `subscribe/2` **join the waiting list** of the bootstrap in progress, and the only
  clause that cleared `route_bootstrap` was the `{ref, result}` reply. So a bootstrap task
  that died or hung meant no `subscribe/2` ever returned again: each caller blocked until its
  own `GenServer.call` timeout and then **exited, taking the calling process with it**.

  Verified by driving it rather than reasoning about it: killing the task left
  `route_bootstrap` holding the dead ref, a second `subscribe/2` joined it — two callers
  waiting — and neither was ever replied to.

  Two ways in, both now closed:

  **A task killed from outside.** `fetch_user_preference/2` converts a raise or an `exit`
  inside the task into an ordinary error result, and its comment says that stops "the
  bootstrap's waiting callers" from never being answered. It does — for those two.
  `Process.exit(pid, :kill)` is untrappable, so neither runs. A `:DOWN` matched on the stored
  ref now settles the bootstrap as a failure.

  **A task that simply never returns.** No `:DOWN` can catch this one: the process is
  perfectly alive, it just never answers. `@route_bootstrap_timeout_ms` now bounds it, kills
  the task and settles. **95 seconds, derived rather than picked**: `Core.HttpClient`'s
  documented defaults are 30 s per attempt over 3 attempts, which this module's own routing
  comment already works out as roughly ninety. Anything shorter would fire while a
  legitimately slow request was still inside its own retry budget and turn a recoverable call
  into a fall-back to the poll route.

  Both settle through `complete_route_bootstrap/2`'s ordinary failure path, so waiting callers
  get the same answer any other bootstrap failure gives them — a fall back to the poll route,
  this venue's documented degraded mode — rather than a new path that could drift from it.

  Found by sweeping the family for the shape of a defect fixed in `dp_exchange_coinbase`
  0.3.12 the same day. This one is worse: Coinbase's wedge silently disabled symbol aliasing,
  where this one blocks the facade's own `subscribe/2`.

## [0.2.12] - 2026-09-11

### Fixed

- **A dead subscriber's pid was never removed, and the fan-out walked it on every message
  for the life of the feed.** `Core.Fanout.resolve/1` skipped a dead subscriber at send
  time, so no *events* accumulated for one — which is what the contract asks for, and it was
  true. What accumulated was the **pid**. Nothing monitored a subscriber or pruned one, so a
  supervised consumer that restarts left its old pid behind on every restart.

  That is linear cost on the hot path: `deliver/4` walks the whole set and calls
  `Process.alive?/1` per entry, per message. Measured in `dp_exchange_core` 0.3.3 —

  | dead pids in set | µs per fan-out |
  |---|---|
  | 0 | 0.095 |
  | 200 | 4.301 |
  | 1000 | 22.842 |

  — roughly **240×** at a thousand accumulated pids, inside the one process every
  subscriber's data flows through.

  Subscribers are now monitored, and a `:DOWN` drops the pid from every set it was in.

  **A registered name is deliberately not pruned.** A pid that has died is gone permanently,
  so removing it is always right. A name is not a process: `subscribe/2` accepts one
  precisely so a consumer can restart under it, and a monitor fires when the *current holder*
  dies. Pruning on that would silently unsubscribe a consumer whose supervisor is about to
  bring it straight back under the same name — data loss with nothing to notice it by, which
  is worse than the leak. A name cannot leak anyway: the set holds one atom however many
  restarts happen.

## [0.2.11] - 2026-09-11

### Added

- **`check_doc_sources.sh` now checks whether its own manifest is COMPLETE.** Everything it
  did before verified the sources that were listed; nothing verified that the list covered
  what this package's `docs/reference/` actually cites. A checker whose coverage nobody
  audits reports "all sources resolve" while saying nothing about the sources it was never
  told about.

  The gap was real: `dp_exchange_gemini` cited 22 distinct URLs and listed 12, leaving two
  genuine vendor documentation pages — the WebSocket streams introduction that
  `websocket-api-replacement.md` names as its source, and one of the four API specifications
  `endpoint-inventory.md` diffs — unchecked by anything.

  Two classes, reported separately, because only one can be judged mechanically:

  **UNLISTED** — cited on a host the manifest already names as documentation. Same vendor,
  same docs site, different page: near-certainly a source that belongs in the manifest.

  **UNKNOWN** — cited on a host the manifest does not name at all. Deliberately **not**
  assumed to be documentation, because most are not: `api.gemini.com`,
  `api.sandbox.webull.com` and `api.schwabapi.com` are venue APIs, and adding one here would
  put a live venue into a **weekly scheduled fetch**. D7 is explicit that a venue seeing a
  package poll it on a timer will rate-limit or block. These are listed for a person to
  classify and never auto-added.

  Non-blocking, like the rest of the script: it prints and does not change the exit code. An
  unlisted page is a gap in evidence, not a broken build.

- **An "elided" URL in `endpoint-inventory.md` read as a citation and was not one.** It gave
  a `developer.schwab.com` address with ellipsis characters standing in for the parts nobody
  recorded — unfollowable by a reader and unverifiable by any checker. The row now describes
  the class of page instead of pretending to name one; the specific pages are in
  `doc-sources.tsv`, which is where a URL belongs.

  Found by the coverage check above, which flagged it as a cited source absent from the

- **Both of this package's scheduled checkers were run by hand for the first time, and they
  pass.** Neither had ever executed: they are scheduled weekly for Monday and landed on a
  Tuesday, so no cron had come around. A checker nobody has watched run is a checker nobody
  has proved works — and running these found the manifest-coverage gap above, which is not
  the defect either of them was written to catch.

  No vendor drift: every cited documentation source resolves exactly as recorded.

## [0.2.10] - 2026-09-11

### Changed

- **CI runs `mix test --cover --warnings-as-errors`.** `mix compile --warnings-as-errors`
  already covered `lib/`, but test files are compiled by `mix test`, which had no such flag
  — so a compile warning in a test file was permanent and green. Together the two now mean
  no warning survives anywhere in the build.

  The argument is not tidiness. A handful of permanent warnings is exactly the noise a
  genuinely wrong one hides behind. The gap was found by running
  `script/check_dependency_floor.sh` by hand — a checker scheduled weekly that had never
  once executed, because it landed on a Tuesday and its cron is Monday — and reading what
  scrolled past. `dp_exchange_core` 0.3.2 fixes five such warnings in the shared conformance
  suite, two of which were real defects that made every venue package noisy.

  Verified by injecting an unused function into a test file and confirming the run aborts: a
  gate nobody has watched fail is a gate nobody has proved.

## [0.2.9] - 2026-09-11

### Changed

- **`dp_exchange_core` floor raised to `~> 0.3.1`.** Core 0.3.0 deleted
  `Core.DataProvider` and `Core.FeedBehaviour` — two contracts with zero implementers, one
  of which was a **second, competing definition of the venue interface** carrying every
  shape this family has since fixed (prices as strings, providers as strings, balances with
  no timestamp, a single quote timestamp, `{:error, String.t()}` flattening the
  refusal/error distinction). A venue author who found it first would have built all of
  those, plausibly, and every one would have compiled.

  **No code changes here**: this package referenced neither module. The floor moves because
  a pin of `~> 0.2.8` would not resolve 0.3.x — the pin doing its job, not a problem to
  route around — and because staying behind would leave this package on a Core that still
  ships the contradicting contract.

  Resolved and compiled against before the pin was written, per the rule this file's own
  dependency comment already records: a floor is only correct once it has been *resolved*,
  never once it has been reasoned about.

- **A stale comment in `capabilities.ex` named the contract that was just deleted.** It
  described `list_instruments/1` as "an optional DataProvider callback"; it is an optional
  **`Core.Venue`** callback, and has been for as long as this package has existed. The
  comment was the only reference to `Core.DataProvider` anywhere in the five venue packages
  — which is how a module with 24 callbacks and no implementers stayed plausible enough to
  cite.

## [0.2.8] - 2026-09-11

### Added

- **This package now emits the `[:dp_exchange, :link, …]` telemetry the contract has
  documented since it was written.** `Core.Telemetry` said these are the events "every venue
  package emits"; there was not one `:telemetry.execute/3` call anywhere in the family for
  as long as the spec existed. `:telemetry.attach/4` against a name nobody emits **succeeds**
  — so a consumer wired a dashboard to it, got no error, and saw an empty panel, which reads
  as a venue with no traffic rather than as an unimplemented spec.

  `:link, :up` and `:link, :down` on the connection transitions, and `:link, :event` per
  frame with its wire size. The request and rate-limit events come free with
  `dp_exchange_core` 0.2.8, since every venue's REST goes through `Core.HttpClient` and every
  metered call through `Core.DefaultRateLimiter`.

  **The metrics channel is alongside the notice channel, never instead of it.** A
  `Core.Notice` is a condition a consumer must ACT on; telemetry is aggregate and lossy by
  design. A consumer that alarmed on a telemetry gauge would be acting on a channel
  documented as droppable, and one that graphed notices would be graphing something it is
  meant to handle.

  Two details worth stating, because both are places a plausible-looking number would have
  been wrong:

  A frame is counted **whether or not it parses**. The question the event answers is "is the
  venue sending", and a frame this package could not read is still a frame the venue sent —
  counting only what parsed would make a decoder bug here look like a silent venue.

  **This is the only package in the family that emits `:link, :reconnect_attempt`**, because
  it is the only one with a real attempt counter. `login_failures` is consecutive rejected
  logins, reset the moment one succeeds, so a consumer watching this event sees the backoff
  climbing and can tell a socket that cannot get back from one that flapped once. The delay
  is reported BEFORE the sleep, so the wait is visible as it starts rather than once it is
  over. The other four reconnect immediately with no counter and would have to report
  `attempt: 1` every time, rendering a reconnect loop as an endless series of first
  attempts — worse than no event, so they emit none.

  `:link, :up` fires on the **LOGIN response**, not on connect. The Streamer ignores every
  command until login succeeds, so a socket reporting the link up on connect would show a
  healthy venue for a session that receives nothing.

### Changed

- **`dp_exchange_core` floor raised to `~> 0.2.8`**, which is where `Core.Telemetry`'s
  emitter functions live. A venue calling `:telemetry.execute/3` directly would be naming
  events by hand in five places — five chances to write `:link_up` instead of
  `[:dp_exchange, :link, :up]`, with the drift invisible, since a wrong name emits
  successfully and simply never reaches a handler — and would be using a transitive
  dependency it never declared.

## [0.2.7] - 2026-09-11

### Added

- **Back-pressure: a slow subscriber no longer gets an unbounded mailbox.** `Core.Venue`'s
  `subscribe/2` doc promised this from the day the contract was written, and no venue in
  this family implemented any of it — every one fanned out with a bare `send/2` and had
  never looked at a subscriber's mailbox. A consumer that stalled accumulated a mailbox
  until the node died, with no notice, no log line, and `coverage/1` reporting perfect
  health throughout, because the feed genuinely was delivering.

  Past a bound (default 10,000 queued messages, `:max_queue_len` at start) this feed stops
  sending to that subscriber and emits a `:degraded` notice naming it, the queue length and
  the bound — and a second `severity: :info` notice when it catches up. The pair brackets
  exactly the window a consumer has to reconcile from the pull endpoints.

  Implemented in `dp_exchange_core` 0.2.6 as `Core.Fanout`, shared rather than written five
  times. Three properties worth stating, because they are what make dropping acceptable at
  all: another subscriber that is keeping up is unaffected; `coverage/1` does not change,
  because it reports what the *venue* delivered to this package and not what this package
  forwarded; and **notices are never subject to the bound**, since the notice saying a
  subscriber is being dropped must not be the first casualty of that same subscriber being
  dropped.

  See `usage-rules.md`, "A slow subscriber gets dropped, and told".

### Changed

- **`dp_exchange_core` floor raised to `~> 0.2.6`, and this one is hard.** `Feed` calls
  `Core.Fanout.max_queue_len!/2` at `init/1` and `Core.Fanout.deliver/4` on every payload.
  Against a lower Core this package does not misbehave, it fails to compile — which is the
  good outcome.

- **The pid-or-registered-name subscriber resolution moved to `Core.Fanout.resolve/1`.** All
  five venues had written it identically since DpCryptoManagement's issue #15; the data path
  and the notice path now share one definition, so they cannot drift into disagreeing about
  what counts as a reachable subscriber.

## [0.2.6] - 2026-09-10

## [0.2.5] - 2026-09-10

### Fixed

- **`coverage/1` kept answering `:stream` for symbols a dropped link had been delivering.**
  `Socket.handle_disconnect/2` returns `{:reconnect, …}`, so the socket *process* survives a
  transport drop and no `:EXIT` ever reaches `isolate_crashed_route/2` — the only path that
  cleared `delivering`. Between a drop and a successful re-LOGIN plus resubscribe, coverage
  reported symbols arriving from nowhere; and where the reconnect restored the socket while
  the venue silently failed to restore a symbol, that symbol reported `:stream` indefinitely.
  That is the 325-subscribed/174-delivering incident `coverage/1` exists to make visible.

  `Socket` already acted on the same fact one level down, clearing `logged_in?` and its
  `subscriptions` on disconnect because *"a socket that kept `logged_in?` would send
  subscriptions the venue ignores and report a healthy feed that receives nothing"*. This is
  the last piece of that: the feed's own record of what was arriving. A whole reset, for the
  reason `isolate_crashed_route/2` gives — this feed has exactly one active route at a time,
  so the link that dropped was the only thing delivering. `route` and `socket` are left
  alone, because that socket is reconnecting rather than dead.

  `dp_exchange_core` 0.2.5 writes the rule into `Core.Venue`'s `coverage/1` doc — observation
  is scoped to the current transport session — and records why it cannot be carried by a
  conformance assertion. All four streaming venues in the family had this wrong in the same
  way and are fixed in the same batch.

- **No published version was attributable to a changelog entry (dp-exchange-core issue
  #32).** Every entry in this repository's `CHANGELOG.md` sat under `## [Unreleased]` — in
  the **published tarball**, since `CHANGELOG.md` ships inside it — so a consumer could not
  tell which version introduced a breaking change, or whether they had already taken one.

  That mapping is load-bearing here rather than cosmetic. This family signals a breaking
  change with a **minor bump**, and those changes are repeatedly a refusal tuple or struct
  gaining a field: invisible to the compiler, and invisible to a test that pins the old
  shape. The reporting consumer's written upgrade procedure is *"read `CHANGELOG.md` for a
  `### Changed — BREAKING` section, then grep for every clause matching the old shape"* —
  which needs version → change. Without it, `### Changed — BREAKING` says *that* the shape
  changed and never whether they already have it.

  They gave two incidents from the same three days, and the difference between them is the
  whole argument: `dp_exchange_gemini` 0.1.42's refusal-shape change was found **after
  shipping**, by reading a fix comment, while `dp_exchange_webull` 0.4.0's was caught
  **before** — because that entry happened to name the version in its prose.

  **Two halves, because fixing only one would have let it recur immediately:**

  - **Going forward**, the release pipeline cuts a `## [x.y.z] - YYYY-MM-DD` heading itself,
    in the publish job and **before `mix hex.publish`** — a heading added after the upload
    would describe a tarball nobody can read.
  - **Retroactively**, the accumulated block now sits under a `## [<version>] and earlier`
    heading. Attributing each of ~1,600 lines to the exact release that carried it is
    archaeology; this restores the one fact a consumer needs from it — that none of it is
    pending — which is what the reporter suggested.

  The issue measured five packages, from their `deps/`. `dp_exchange_schwab` has the same
  defect and is not one of their dependencies, so it could not appear in their table: six
  instances, all fixed here.

## [0.2.4] and earlier - 2026-09-10

**Everything below this line is published.** Entries were accumulated under
`[Unreleased]` from the first release to `0.2.4`, so no reader could tell shipped work
from pending — dp-exchange-core issue #32. Attributing each entry to the exact version
that carried it would be archaeology across hundreds of releases; this heading restores
the one fact a consumer actually needs from it, which is that none of it is pending.

Releases from here on cut their own `## [x.y.z]` heading at publish time, so this is
the last block that will ever need a range.

### Documentation

- **`OPTIONS_BOOK` was recorded as the unblocked half of Schwab depth streaming. It is
  not** — corrected in `docs/design/ideas/schwab-depth-and-account-activity-streaming.md`,
  in `Feed.services_for/1` and in `Capabilities`' moduledoc, all of which carried the claim.

  That document said `OPTIONS_BOOK` "does not have this problem", meaning the
  `NYSE_BOOK`/`NASDAQ_BOOK` routing ambiguity, and read as though the options half only
  needed wiring. Checked against the vendor's own text, and it fails on something else
  entirely — **twice**:

  - **The vendor documents no `keys` format for the book services' option case.**
    `LEVELONE_OPTIONS` states *"Schwab-standard option symbol format:
    RRRRRRYYMMDDsWWWWWddd"*; the shared Book Common table covering all three book services
    says only *"Symbols in upper case and separated by commas. e.g.: AAPL,TSLA,IBM"*, with
    equity examples and no option format. Sending an option symbol there assumes the two
    match — the *new judgement* `services_for/1`'s own comment says it does not make. That
    comment is the standard this package holds itself to: `LEVELONE_EQUITIES` and
    `CHART_EQUITY` share symbols only because their key formats are documented *identically*.
  - **`capabilities/0` could not declare it honestly even if the format were known.**
    `Core.Capabilities`' `streamable` is a flat `[data_kind()]` with no asset-class
    dimension, so `:order_book` cannot be claimed for options without also claiming it for
    equities, where it is false and blocked. Delivering option books *without* declaring
    them would push a payload kind a consumer was never told to expect — the shape
    conformance assertion 20 exists to catch. That half is a Core change, not a Schwab one,
    and it is the same flat-list gap that blocks `dp_exchange_webull`'s per-asset-class
    `historical_timeframes`.

  **Nothing was wired and nothing changed behaviourally**, which is the point: the decode
  side is complete and tested (all three book services share `StreamerFields`' one `@book`
  table), so this looked like a small win right up until the vendor's text was read. A
  design document recording a part as unblocked when it is not is worse than one that says
  nothing — it is a trap for whoever picks it up next.

### Documentation

- **`usage-rules.md` now answers the question a consumer actually has after 0.2.0: when is
  `venue_time` `nil` here?** The migration note said what the fields mean; it did not say
  what this venue does with them, which is the part a caller writes a branch for.

  **On every streamed quote**, because `LEVELONE_*` frames carry no venue time in the fields
  this package reads — the fact the split exists to state, and the one this package used to
  hide behind the frame's arrival time. The book is the opposite and always was:
  `to_order_book/2` reads `snapshot_time` and fails closed without it.

### Changed — BREAKING

- **`Core.Types.Quote` and `Core.Types.OrderBook` no longer carry `:timestamp`.** They carry
  **`:venue_time`** (the venue's own, `nil` where the venue publishes none) and
  **`:observed_at`** (when this package read it, always present). Requires
  `dp_exchange_core ~> 0.2.1`; this package's own version takes a minor bump to signal it.

  `:timestamp` was documented as the venue's own and "never invented", and two packages in
  this family could not keep that promise, because the frames they decode carry no venue time
  at all. With one field their only options were to lie or drop real data, and they lied.

  **One path in this package was the reason.** `StreamerDecode.to_quote/3` — `LEVELONE_*`
  frames — put the frame's arrival time in `:timestamp` because those frames carry no venue
  time in the fields it reads. It now reports `venue_time: nil`, which is a different fact
  from "quoted at 14:53:02" and one it could not previously state. `to_order_book/2` was
  always the counter-example: it reads the venue's `snapshot_time` and fails closed without
  it, and is unchanged.

  The full reasoning, the three options weighed and the consumer's own argument for this one
  are in `dp_exchange_core`'s
  `docs/design/closed/2026-09-09_venue-time-and-observed-time.md`, announced and answered as
  dp-exchange-core issue #31. `Trade`, `Fill`, `Balance` and `OrderBookDelta` are unchanged.

### Documentation

- **A read time sits in a field the contract documents as the venue's own, and it is now
  labelled where it happens.** `Core.Types.Quote` says `:timestamp` is "the venue's own…
  never invented: a quote whose freshness we cannot state is a quote we must not return."
  This package's decoder does not keep that rule on the path noted at the code, because the
  venue publishes no time for those frames and the struct has a single `:timestamp` — unlike
  `Core.Types.TopOfBook`, which carries `:venue_time` and `:observed_at` separately and can
  therefore say "the venue did not date this".

  **No behaviour changed.** The gap is in the shared contract, not only here, and closing it
  means altering a published type that a live consumer decodes at every call site — 19 lib
  files and 27 test files across six repositories. That is a written-plan decision by this
  project's own rules, so it is
  `dp_exchange_core`'s `docs/design/2026-09-09_venue-time-and-observed-time.md`, with three
  options costed. What changed here is that a reader of the code is now told, rather than
  finding out by trusting the type's documentation.

### Fixed

- **Reads now carry `@call_timeout` explicitly, exactly as writes already did.** `coverage/1`,
  `coverage_by_kind/1`, `status/1` and `wanted/1` took `GenServer.call/2`'s implicit five
  seconds while every write named a generous one — the same asymmetry that turned a bounded
  delay into a dead caller in issue #28. Second line of defence, never the fix: a read that
  has to queue behind something should wait for it, not die of it.

- **A subscribe blocked every read on this Feed for as long as the Streamer bootstrap took
  — dp-exchange-core issue #28's failure, on this venue.** Establishing the stream route
  means a signed `Rest.get_user_preference/2` round trip followed by a WebSocket connect,
  and both ran **inline inside `handle_call/3`**. With `Core.HttpClient`'s documented
  defaults (30_000 ms per attempt, 3 attempts) that window reaches roughly **ninety
  seconds**, during which `coverage/1`, `coverage_by_kind/1`, `status/1` and `wanted/1`
  queued behind it — and those were plain `GenServer.call/2`s on the five-second default,
  so a health check arriving during a subscribe did not merely wait, it **exited**, taking
  a consumer that reads it from its own `handle_call/3` with it.

  **This was found by sweeping for the class rather than by it failing here.** The #30
  reporter named the shape — "work done in the process that owes a reply" — while
  describing something else, and this family has now paid for it three times (#16, #23,
  #28). Proven before it was fixed: `coverage/1` did not answer inside 500 ms while a
  subscribe was establishing the route.

  The slow half now runs in a task and the caller's reply is deferred;
  `dp_exchange_webull`'s `spawn_reconcile/3` reached this shape first and this is
  deliberately the same pattern rather than a second invention. **The socket is still
  opened by the Feed, not by the task** — `Socket.start_link/1` links to its caller, so
  connecting inside the task would tie the venue's connection to a process that exits
  moments later. The task fetches; the GenServer connects, bounded by
  `@socket_connect_timeout_ms`. Two subscribes arriving during one bootstrap share it and
  are both answered, which is why `waiting` is a list: starting a second bootstrap would
  open a second Streamer connection for a consumer that merely called `subscribe/2` twice.

### Documentation

- **`Credentials`' moduledoc now says that the redaction wrap lives in `child_spec/1`, and
  that bypassing `child_spec/1` bypasses it.** Requested by the consumer who verified the
  dp-exchange-core #29 fix and then went looking for their canary in their own supervisor's
  state — and found it. Their supervision code builds the child spec itself
  (`start: {__MODULE__, :start_feed, [module, opts, pairs]}`) for a legitimate reason: a
  `Core.PollingFeed`-shaped facade defaults `subscriber` to `self()`, which resolves to the
  *supervisor* when `start_link/1` is called from `init/1`, so a different delivery target
  can only be set at `start_link` time. On that path `child_spec/1` never runs, their
  supervisor stores the raw map, and OTP renders the live key on the next crash exactly as
  before. **Upgrading does not fix it, because nothing from this package is on that path.**

  No code change: `wrap/1` and `wrap_opt/1` were already public, which was all that path
  needed. What was missing was anyone saying so — the natural assumption, "upgraded,
  therefore redacted", is wrong there, and assertion 22 cannot see it because it asks about
  `child_spec/1`'s own rendering. `dp_exchange_core`'s `usage-rules/auth.md` carries the
  full version, including the reshaping case that bit them: a host mapping its own key
  names into a venue's and returning a bare map re-introduces the leak in its own code,
  downstream of anything a package can reach.

### Fixed

- **A read-only coverage call could kill the feed — dp-exchange-core issue #28.**
  `handle_call` delegated straight into `Core.PollingFeed` with `GenServer.call/2`'s
  five-second default, into a process that could not answer while a fetch was in flight —
  `:fetch_timeout_ms` floors at **30 seconds**, so a coverage read landing during an
  ordinary poll was not unlucky, it was a guaranteed timeout. The exit propagated out of
  `handle_call/3` and killed `Feed`, which restarts from the static opts its supervisor
  holds and never carries a consumer's later subscriptions. The reporting consumer watched
  a live venue go **61 pairs to 0 and stay there**, with the process alive, idle, and
  passing every liveness check. Asking whether the venue was healthy is what made it
  unhealthy.

  `Core.PollingFeed` no longer blocks on its fetch, which removes the cause. These reads
  are guarded here regardless, and it is not belt-and-braces: a poller mid-restart, wedged
  by something else, or simply gone is a condition this `Feed` has to survive, and no fix
  inside `PollingFeed` can promise it always answers.

  The fallback says the least that is true. `c:DpExchange.Core.Venue.coverage/1` returns a
  map, so an error tuple is not sayable, and an absent symbol already means
  `:not_covered` — while replying with a **remembered** coverage would assert arrivals
  nobody confirmed, the "nearby substitute where an error belongs" this family keeps paying
  for. A `:link_down` notice carries what an empty map cannot: **"we could not ask" is not
  "nothing arrived"**, and only the notice distinguishes them.

- **Credentials were written to the log in cleartext by any crash — dp-exchange-core issue
  #29.** A supervisor stores the `{module, :start_link, [opts]}` MFA its child spec names,
  and OTP writes that argument list through `inspect/1` into the `Start Call:` line of the
  report it logs on **any** child termination. `:credentials` arrived as a plain map, so
  every crash printed the live secret in full. It needs no unusual conditions, it lands in
  ordinary application logs — the artifact most likely to be shipped to an aggregator or
  attached to a bug report — and it defeats credential hygiene upstream of it: a consumer
  can hold the key encrypted at rest and still have it written out in the clear. The
  reporting consumer found live keys this way and nearly pasted them into a GitHub issue
  while reporting a different bug.

  `child_spec/1` now wraps `:credentials` with `DpExchange.Schwab.Credentials.wrap_opt/1`, and
  **the placement is the fix**: wrapping in `start_link/1` or `init/1` does nothing,
  because by then the supervisor above has already captured the raw list. `Feed.child_spec/1` does the same, for a consumer supervising the feed directly. Redacting the
  value rather than setting the `:sensitive` process flag is deliberate — that flag
  suppresses the whole report, including the stack trace that made the unrelated bug
  diagnosable. This keeps the report and removes only the secret. `dp_exchange_core`'s
  conformance suite gains **assertion 22** for exactly this, so it cannot come back here or
  arrive in a new venue.

### Added

- **`script/check_doc_sources.sh` and `docs/reference/schwab/doc-sources.tsv`** — a weekly,
  non-blocking check that every vendor documentation page this package cites still resolves
  the way it did when a person read it. It records status and redirect destination and does
  **not** follow redirects or diff content: a permanent redirect is itself the change notice
  (this family lost a streaming API to one, announced by nothing else), while content
  diffing a rendered docs site would be red every week for reasons that are never the reason
  we care about. Built after auditing what would have caught each way five vendors'
  documentation turned out to be wrong — across that whole sample a *changelog* diff caught
  nothing, and an *index* diff was the only mechanism that ever fired. It earned itself
  immediately: on its first run in `dp_exchange_webull` it caught a cited page that 404s, and
  pulling that thread found a rate ceiling five times too permissive against that venue's own
  per-endpoint table. Scheduled Mondays 09:20 UTC via
  `.github/workflows/doc-sources-check.yml`, never on push, never in the publish chain.
  Documentation sites only — never a venue API, which tier 2's never-on-a-schedule rule
  still forbids.

  All five rows here are class `manual`, and this venue is why that class exists.
  `developer.schwab.com` answers `403` to an anonymous reader, so no link check, index diff
  or changelog diff reaches it — the specification is committed to this repository instead
  and re-capture is a human signing in. Those rows are checked for *stability* (a `403` that
  stops being a `403` is itself news) and then reported with their age, going STALE past 180
  days to force the re-capture rather than let a claim quietly get old. The `dashboard` row
  carries the warning that the portal returns the signed-in account's live `appKey` and
  `appSecret` in the same JSON as the specification: redact before storing, never after.

### Fixed

- **Two venue facts were correctly measured/documented but not cited against
  `spec-facts.md`, the file CLAUDE.md names as canonical for checking a declared value.**
  Found by a family-wide sweep for constants encoding an unverified venue claim (the
  `@pairs_per_socket`/`@shard_spacing_ms` defect class in `dp_exchange_coinbase`). Neither
  number was wrong — this closes a citation gap, not a value change:
  (1) The 30-minute access-token lifetime, stated in prose in `Auth`'s and `Capabilities`'
  moduledocs, is now cited to `documentation/accounts-and-trading-production.txt:74` (a new
  §6 in `spec-facts.md`) — the 7-day refresh-token figure already had one. The code itself
  never hardcoded 30 minutes as a literal (`refresh/2` reads `expires_in` from the venue's
  own response), so nothing here changes runtime behaviour.
  (2) `SymbolFormat.@option_length` (21) had a correct in-code explanation of its own
  arithmetic (6 + 6 + 1 + 8) but no citation at all. Now cited to the venue's own
  `RRRRRRYYMMDDsWWWWWddd` format string (`documentation/market-data-production.txt:798`,
  new §1a in `spec-facts.md`), which matches the existing arithmetic exactly.

- **A crash of `Feed` or `Socket` printed OAuth credentials — the refresh token and
  client secret included — in cleartext, in OTP's own crash report.** `Feed` held
  `state.credentials` for its entire lifetime AND a second, unwrapped copy inside
  `state.opts` (the raw `init/1` keyword list, `:credentials` entry still in it).
  `Socket` held the access token as a bare string in `state.access_token`. OTP's default
  crash report prints a process's state in full on termination, and a plain map or
  string field prints in full — verified by crashing an equivalent process holding
  `%{access_token: ..., refresh_token: ..., client_secret: ...}` as a bare field and
  reading the resulting log line back. This venue's own moduledoc already calls
  `refresh_token` rotation "destructive" — a one-time-use token spent by the moment
  anyone reads a log is not a credential that can simply be reissued.
  `Process.flag(:sensitive, true)` does not help: the same crash, with the flag set,
  printed the same cleartext state. Now both processes wrap credentials in
  `DpExchange.Schwab.Credentials`, a struct whose `Inspect` is derived with `except:`
  naming every secret field, at the point they enter state; `state.opts` no longer
  carries a second copy at all (`Keyword.delete(opts, :credentials)`). Nothing
  downstream changes: a struct is a map, so `Auth.headers/2`'s `%{access_token: token} =
  credentials` still binds the real value inside the one function that has to send it.
  Re-verified against a real crash of the new shape: the log line now reads
  `credentials: #DpExchange.Schwab.Credentials<expires_at: nil, ...>`.

- **This was the one venue in the family that dialled the Streamer at boot, before any
  `subscribe/2` — a family-wide rule violation found by a 2026-09-07 cross-package
  audit.** `CLAUDE.md` states it plainly: "A library does not start itself… A consumer
  who has not asked for a venue must not find a socket open." `Feed.init/1` ended with
  `{:ok, state, {:continue, :connect}}`, and `handle_continue(:connect, state)` called
  `ensure_route/1` immediately — a signed `GET /userPreference` and, on success, a live
  Streamer `LOGIN`, for a tree that had never subscribed a single symbol.
  `dp_exchange_coinbase`, `dp_exchange_gemini`, `dp_exchange_webull` and
  `dp_exchange_robinhood` were all checked and all four already deferred dialling to
  `subscribe/2` or a first tick; this package did not. Reproduced directly: a feed
  started with a `:plug` that raises on any request, never subscribed, made no request —
  before the fix, the same setup logged a real `GET
  https://api.schwabapi.com/trader/v1/userPreference` from `start_link/1` alone.

  The eager dial was incidental, not load-bearing: `ensure_route/1` was already
  reachable from `handle_call({:subscribe, …})` and `handle_call({:update_symbols, …})`,
  both of which call it before replying, so every path a consumer actually uses to ask
  for data already established the route on demand. `{:continue, :connect}` is now gone
  from `init/1`; the route is established on the first `subscribe/2` or
  `update_symbols/2`, exactly as it already was for a second and every later call.

  This is also why `dp_exchange_core`'s conformance suite had to ship assertion 18
  ("link safety") as a *static* check on compiled abstract code rather than the stronger
  behavioural one — start the tree, kill a linked child, assert `Feed` survives — that
  was designed first: starting this package's real tree was not reliably network-free.
  This fix is what makes that stronger check safe to write for the whole family.

  Fixing this surfaced a second, independent defect it had been masking:
  `Feed.status/1`'s fallback clause hardcoded `route: :stream` in its reply, correct only
  because `state.route` had always already been set by the time any `handle_call` could
  run — no caller could previously observe the window between "started" and "routed".
  Deferring the dial made that window real. `status/1` now reports `state.route` itself,
  which reads `nil` before the first `subscribe/2` rather than a stream connection that
  was never dialled.

  **Behaviour change:** a consumer that supervises this package and never calls
  `subscribe/2` no longer causes any request to reach the venue, and no longer opens a
  Streamer session. If you relied on data already arriving the instant your supervision
  tree came up, with no `subscribe/2` of your own, that no longer happens — call
  `subscribe/2` explicitly, the same as every other venue in this family already
  requires. Nothing changes for a consumer that does subscribe: the route is established
  at that call exactly as it always was, and `Notice{kind: :degraded}` still fires at
  that same moment if the Streamer cannot bootstrap — now on first `subscribe/2` rather
  than at boot, which is the tradeoff this fix makes: a consumer that never subscribes
  has no route to be degraded about in the first place.

  Proven by `test/dp_exchange/schwab/feed_test.exs`, "nothing is dialled before the
  first subscribe" — asserts no venue call and `status/1` reporting `route: nil` for a
  feed that was started but never subscribed, and that `subscribe/2` is what actually
  triggers the first request. `mix quality` clean, `mix test --cover` at 91.14%, and
  `dp_exchange_core` bumped to 0.1.61 to run assertion 18.

- **A reconnect meant silence until a consumer noticed, and a crashed socket or poller
  took the whole `Feed` down with it.** Two related supervision defects, found by a
  2026-09-07 cross-package audit:

  `Socket.handle_disconnect/2` clears the venue's own subscriptions on every reconnect
  (see `Socket`'s own moduledoc, "Reconnection is not resubscription"), but nothing on
  this side of the link ever re-issued them: a routine network blip — not a crash, just
  an ordinary reconnect — left this feed connected, logged in, and asking the venue for
  nothing, until whoever was watching `subscribe_notices/1` noticed `:link_up` on their
  own and called `subscribe/2` again. `dp_exchange_coinbase` and `dp_exchange_gemini`
  both already close this exact "reconnect with no memory" gap; this package never had.
  `Feed` now re-issues `state.wanted` on a periodic, unconditional 60-second timer, the
  same shape those two packages use.

  Separately, `start_socket/1` and `start_poller/1` both run inside `ensure_route/1`, a
  `Feed` callback, which links either process to `Feed` the way `start_link` always
  does. `Feed` never called `Process.flag(:trap_exit, true)`, so either one exiting
  abnormally sent an untrappable `EXIT` signal along its link and crashed `Feed` too —
  every subscriber, the whole `wanted` set, gone, restarted by `DpExchange.Schwab.
  Supervisor` from the STATIC `opts` it was given at tree-start. Proven by linking a
  real process into a running `Feed` the way `start_socket/1` does and killing it with
  `Process.exit(pid, :kill)` (not `:normal`, which a non-trapping process ignores).
  `Feed` now traps exits; a crashed socket or poller clears its route (so `ensure_route/1`
  reconsiders from scratch), resets `coverage/1`/`coverage_by_kind/1` rather than leaving
  them reporting `:stream` for a route that no longer exists, reports a `:link_down`
  `Core.Notice`, and immediately retries — a fresh Streamer bootstrap if the credential
  still works, falling back to the poll the same way a first-ever bootstrap failure
  already does.

### Added

- **`Fake` is now wired to `DpExchange.Core.FakeInjection`.** This was the only package in
  the family with no wiring at all — Coinbase, Gemini, Webull and Robinhood all had it, and
  `usage-rules/testing.md` states the convention as "every venue's `Fake` is wired to
  `DpExchange.Core.FakeInjection`". Found by a cross-package audit; no single-package review
  could see it, because nothing inside this repo was missing. A consumer exercising its own
  retry, circuit-breaker or alerting code against several venues at once could not point
  that code at Schwab.

  The market-data and account/order callbacks with a real success path now check
  `FakeInjection.next_outcome/2` first, and `require_credentials/1` honours
  `FakeInjection.bypass_credentials/1`. The bypass matters more here than anywhere else in
  the family: this venue has no anonymous surface at all, so without it there is no way to
  exercise dispatch or decode logic without constructing a credential map for every call.

  Deliberately not wired, and documented as such in the module: `subscribe/2`,
  `unsubscribe/2` and `update_symbols/2` (whole-call injection cannot express "one symbol in
  the batch fails"), and `coverage/1`, `coverage_by_kind/1` and `subscribe_notices/1` (local
  bookkeeping that always succeeds by construction). Also not yet wired, and stated rather
  than left to be found: `get_option_chain/2`, `get_option_expirations/2`, `get_screener/2`,
  `get_transactions/2` and `get_rate_limit_status/2`.

### Fixed

- **Supervision ceilings and the feed's poll interval failed open on a bad value, and an
  explicit `nil` was read as a registration.** Two related gaps, both the forwarded-`opts`
  trap this family already has three incidents for:

  `Supervisor`'s `init/1` and `limits/1` read `:order_limit_per_minute` and
  `:read_limit_per_minute` with `Keyword.has_key?/2` and `Keyword.get/3`. A consumer
  forwarding an `Application.get_env/2` lookup that resolved to nothing passes
  `order_limit_per_minute: nil` — **present and `nil`, not absent** — so `has_key?/2`
  answered `true` (the host "stated a registration", which is the single fact `OrderLimit`
  exists to get right) and `Keyword.get/3` returned the `nil` rather than the default.
  `max(nil, 1)` is `nil` under Erlang term ordering, so that `nil` reached
  `DefaultRateLimiter` as `limit: nil, burst: nil` and failed inside its arithmetic, far
  from the option that caused it. Both now read through `DpExchange.Core.Config.opt/3`,
  which differs from `Keyword.get/3` in exactly that one case, and a value that is not a
  non-negative integer now raises `ArgumentError` at start naming the option and the
  venue's documented `0..120` range — `0` remains legal and distinct from "said nothing".

  `Feed.init/1` passed `:interval_ms` to `Core.PollingFeed` unchecked, and `PollingFeed`
  does not validate it either. A zero, negative or fractional value therefore did **not**
  fail `start_link/1` — it returned `{:ok, pid}` and crashed later, inside the poller, the
  first time `Process.send_after/3` was handed the delay, which under `:one_for_one` is a
  restart loop rather than a refusal. It is now refused at `init/1`.
  `DpExchange.Coinbase.Feed`'s `validate_shard_spacing_ms!/1` is the same guard for the
  same reason; this venue had none. Zero is refused here, unlike Coinbase's shard spacing
  where zero is a real if extreme choice: a poll interval of zero is not a fast poll, it is
  a process that reschedules itself with no delay and spends the venue's whole rate budget
  in one continuous burst.

- **BREAKING: `Fake` reported a missing credential as `{:refused, :missing_credentials}`,
  disagreeing with its own real facade.** The facade's own private `credentials/1`
  plumbing and `Auth.headers/2` have always answered
  `{:error, {:missing_credentials, :schwab}}`;
  `Fake.require_credentials/1` — the helper behind thirteen call sites, market data and
  account surface alike — answered a `:refused` tuple with a bare atom instead. Both halves
  were wrong. `DpExchange.Core.Venue`'s own moduledoc reserves `{:refused, reason}` for the
  venue's own permanent word about a request it **received**, and a call refused for want
  of a local credential never reaches Schwab at all; and the payload shape differed from
  the real one, so a consumer matching the real facade's error could not match the fake's.
  Now `{:error, {:missing_credentials, :schwab}}` in both. Assertion 17 cannot catch this —
  it asserts only that the result is not `{:ok, _}`, never that the refusal has the same
  shape as the real venue's.

- **BREAKING: `Fake` answered `{:ok, _}` with no credentials on five endpoints, on a venue
  where every single call requires OAuth.** `get_positions/1`, `get_option_chain/2`,
  `get_option_expirations/2`, `get_screener/2` and `get_transactions/2` never inspected
  credentials at all — `get_transactions/2` bound them as `_credentials` outright — while
  each real counterpart reaches the venue through `Rest`'s `get/3` → `Auth.headers/2` path
  and answers `{:error, {:missing_credentials, :schwab}}` without one. A consumer's suite
  calling any of them with no credentials and asserting success was going green against
  behaviour this venue does not have. All five now gate through the existing
  `require_credentials/1` helper, checked before each call's own argument validation so the
  refusal point matches the real order, not just the final answer.

  **Why assertion 17 did not catch it, even though this venue declares
  `credential_benefit: :required`.** The assertion gates on `Core.AdapterContract`'s
  hardcoded `@credentialed` list — `get_balances`, `get_accounts`, `get_fees`,
  `get_transfers`, `place_order`, `cancel_order`, `get_order`, `get_orders`,
  `get_trade_history` — which names none of the five. That list predates the widened
  callback surface and was never extended with it, so a venue can pass assertion 17 with
  its whole options/positions/screener/transactions surface ungated. Found by a
  cross-package audit comparing all five venue packages against each other, which found the
  identical gap in `dp_exchange_webull`'s fake on its own widened surface — a property of
  the assertion's fixed list rather than of either venue, and the durable fix belongs in
  Core.

- **BREAKING: `get_transactions/2` reported a missing account hash as
  `{:error, {:account_hash_required, :schwab}}` while every other account endpoint reported
  the identical condition as `{:error, {:missing_account_hash, :schwab}}`.** One condition,
  two spellings, on the same facade — so a consumer handling "you forgot the account hash"
  uniformly could not, and `CLAUDE.md`'s own refusal table documents only the second. Both
  the facade (`DpExchange.Schwab.get_transactions/2`) and `Fake` now go through the shared
  `account_hash/1` / `require_account/1` helper and answer `{:missing_account_hash,
  :schwab}`. The sibling atoms on that call, `:from_and_to_required` and `:types_required`,
  are unchanged — they name genuinely different conditions that appear nowhere else.

- **`capabilities/0` declared four streamable kinds this package could not deliver —
  `:order_book`, `:candles`, `:orders` and `:fills` — found by a documentation-accuracy
  sweep (2026-09-06) that read `Feed.services_for/1` (then `service_for/1`) against
  `capabilities().streamable` rather than against decoder coverage, which is what missed it
  the first time. `Feed` only ever subscribed `LEVELONE_EQUITIES`/`LEVELONE_OPTIONS`; it
  never sent `NYSE_BOOK`, `NASDAQ_BOOK`, `OPTIONS_BOOK` or `ACCT_ACTIVITY` a subscribe
  request. `StreamerDecode` and `Socket.decode/4` could turn any of the four into a real
  value — the decoders were real and tested — but decoding a frame and asking the venue to
  send one are different facts, and a consumer calling `subscribe/2` for any of the four
  got the declaration and then permanent silence: this family's forbidden substitution,
  wearing a capability flag instead of a value.

  **`:candles` is wired rather than narrowed**, because it can be without guessing:
  `CHART_EQUITY`'s `keys` parameter is documented identically to `LEVELONE_EQUITIES`'s
  ("Equities symbols in upper case… e.g.: AAPL,TSLA,IBM"), so `services_for/1` now sends
  every non-option symbol to both services, and `StreamerDecode.to_candle/3` — already
  real and tested — turns the result into a `Types.Candle`.

  **`:order_book` and `:orders`/`:fills` are narrowed out, because wiring either would be a
  guess.** `NYSE_BOOK` and `NASDAQ_BOOK` are both documented only as "Level Two book for
  Equities," with no vendor-stated rule for which service a given equity symbol belongs
  on. `ACCT_ACTIVITY`'s `message_data` is documented JSON "whose shape depends on
  `message_type`" that the vendor does not publish — there is no schema to decode against,
  only one to invent. `capabilities/0` now declares `streamable: [:quotes, :top_of_book,
  :candles]`, and `record_kind/3` no longer maps `Types.OrderBook` to `:order_book`, since
  nothing this module subscribes can ever produce one and a dead mapping left the
  possibility of `coverage_by_kind/1` reporting a kind the declaration does not name. What
  wiring either gap for real would need is recorded at
  `docs/design/ideas/schwab-depth-and-account-activity-streaming.md`.

  **This is breaking for a consumer routing on `capabilities().streamable`**: a check for
  `:order_book`, `:orders` or `:fills` in that list now returns `false` where it previously
  (wrongly) returned `true`. No consumer could have received any of the three regardless,
  since nothing ever delivered them — the declaration is the only thing that changes.

  `usage-rules.md`, `README.md`, `DpExchange.Schwab`'s moduledoc, `Capabilities`'
  moduledoc, `Feed`'s moduledoc and `docs/reference/schwab/coverage-matrix.md` are
  corrected in this same commit.

- **`DpExchange.Schwab.Supervisor.limits/1` defaulted `:order_limit_per_minute` to the read ceiling (120 by
  default) whenever a host omitted it — the top of Schwab's own documented `0..120` range,
  assumed for a registration this package was never told about, and the worst of the
  choices available: it fails open, letting a consumer write orders against a permission it
  may not hold.** Found by the same documentation-accuracy sweep: this module's own
  moduledoc already said a number baked in here "would be a claim about somebody else's
  registration," and said `:order_limit_per_minute` "has no default" — the code disagreed
  with its own comment for the one case, silence, where the claim is least justified.

  `:order_limit_per_minute` now defaults to `0` (`@default_order_limit`) — not a venue fact,
  since the venue has none to default to, but this package's own refusal to assume a
  registration until told otherwise. A host that places orders states its own ceiling; one
  that never does pays nothing for leaving it out, since the default only affects order
  writes. `README.md` and `usage-rules.md` §12 now say so.

- **The `0`-default above was reviewed and sent back: it failed closed illegibly.** Trace
  what a consumer who omitted `:order_limit_per_minute` actually saw calling
  `place_order/3`: the order-write bucket was starved, and
  `DpExchange.Core.DefaultRateLimiter.check/3` answered `{:rate_limited, wait_ms}` — or,
  under `rate_limit_blocking: true`, `acquire/3` simply made them wait, which presents as a
  hang. **That is a plausible value with the wrong meaning**, exactly the failure mode this
  family fails closed against: `:rate_limited` says the venue is pushing back, when the
  venue said nothing at all and this package is refusing on the consumer's own behalf for a
  reason the answer cannot show. Worse, a host who explicitly registered at `0` — a real,
  deliberate "I place no orders" — got the identical answer, so the two cases were
  indistinguishable from the outside despite meaning opposite things.

  **`DpExchange.Schwab.OrderLimit`** is new: a small supervised process, started alongside
  the limiter and the feed, holding exactly one fact for the tree's life — whether
  `:order_limit_per_minute` was ever passed, kept apart from what number it resolved to.
  `place_order/3`, `replace_order/4` and `cancel_order/3` consult it **before** any
  rate-limit call is made: a tree that was never told an order ceiling now answers
  `{:error, :order_limit_not_declared}`, unmistakable on its face from `{:rate_limited, _}`;
  a tree explicitly told `0` reaches the limiter exactly as before and is throttled for
  real, because that is what a stated `0` means. A consumer who bypasses `Supervisor`
  entirely — calling `Rest.place_order/4` with a `:limiter` of its own, which this package
  has always allowed — gets no opinion from `OrderLimit` at all: `{:error, :not_started}`
  is answered `:ok` by the new check, never collapsed into a refusal nobody asked for.

  **A second, independent gap surfaced in the same review: a declared ceiling was not
  enforced either.** `Rest`'s order writes (`place_order/4`, `replace_order/5`,
  `cancel_order/4`) reached the rate limiter through the same `provider: :schwab` every
  read uses, so `schwab_orders` — the bucket `DpExchange.Schwab.Supervisor.limits/1` has always built —
  metered nothing. A host who did everything right, passing a real `:order_limit_per_minute`
  matching its own registration, got **no protection from it**: writes sailed through at the
  generous read ceiling, and any real over-limit behaviour would have surfaced as a
  rejection from Schwab itself, never from this package's own guard. It went unnoticed
  because the read ceiling and Schwab's documented order maximum are both `120`, so nothing
  about it ever looked wrong. `Rest.place_order/4`, `replace_order/5` and `cancel_order/4`
  now tag their requests `provider: :schwab_orders` (a new `order_write_request_opts/1`),
  so a declared ceiling is finally the one that actually meters them. `preview_order/4` is
  deliberately unaffected — it is not a throttled order write on this venue.

  **This is breaking for a consumer who omitted `:order_limit_per_minute` and was relying
  on the old optimistic `120`.** `place_order/3`, `replace_order/4` and `cancel_order/3`
  now return `{:error, :order_limit_not_declared}` for such a consumer instead of silently
  reaching the venue. The fix is to declare the real ceiling: pass
  `:order_limit_per_minute` matching what the consumer's own application was registered
  with at `Supervisor`/`DpExchange.Schwab` start, or `0` if it places no orders at all.
  `Supervisor`'s moduledoc, `OrderLimit`'s moduledoc, `README.md` and `usage-rules.md` §12
  all state this.

### Changed

- **A rejected Streamer LOGIN now emits `:credentials_rejected` rather than a generic
  `:degraded`, so a host can act on it automatically.** This package refreshes only when the
  host calls `refresh_credentials/2` — that division is deliberate, since `Auth` holds no
  state and starts no timer — but it means the host needs a signal it can pattern-match to
  know a refresh is the remedy. A `LOGIN_DENIED` reported as `:degraded` with the reason in a
  free-text string gave it nothing to match on: the socket would back off and retry the same
  dead token indefinitely while the only real notification sat in a log line. `Core.Notice`'s
  own moduledoc calls `:credentials_rejected` close to load-bearing for exactly this, because
  a consumer whose keys stopped working otherwise learns it from the absence of data — the
  slowest possible signal.

  **Only the vendor's code `3 LOGIN_DENIED` maps to it.** Its response-code table
  (`docs/reference/schwab/documentation/market-data-production.txt`) answers that code with
  *"Client should reconnect and re-login with new token"* — a refresh instruction. `9
  UNKNOWN_FAILURE` (the vendor's error of last resort, which it asks be reported to Trader API
  support) and `11 SERVICE_NOT_AVAILABLE` (the venue being down) stay `:degraded`: a fresh
  token is the remedy for neither, and reporting them as a rejected credential would be this
  package asserting something the venue never said. The meaning of code `3` lives in
  `StreamerProtocol.login_denied?/1` rather than being re-derived by each caller.

  This closes the gap left by wiring `needs_refresh?/2` to the facade in the same release:
  that is a clock check against the credential you hold, and it structurally cannot catch a
  token the venue stops accepting *early* — revoked, or rotated elsewhere. `usage-rules.md`
  documents both triggers and says plainly that a host ignoring the notice has a feed that
  reconnects forever and never logs in.

### Added

- **Core's assertion 16 ("internal wiring") swept this package clean — thirteen violations,
  four wired to the facade, six deleted as dead code, one deleted after checking the vendor
  docs, and two new facade functions to complete a pairing this release already started.**
  `Core.AdapterContract`'s new assertion reads `:xref`'s real call graph, restricted to
  `lib/`, to find an internal export nothing calls from anywhere but `test/` — the same
  shape of defect `subscribe_notices/1` and `Auth.refresh/2` above were. Design doc:
  `docs/design/closed/2026-09-06_assertion-16-internal-wiring.md`.

  **`DpExchange.Schwab.needs_refresh?/2` and `DpExchange.Schwab.credential_failure?/1` —
  the two functions a host needs to complete the refresh cycle `refresh_credentials/2`
  started, now on the facade instead of on the internal `Auth` module.**
  `refresh_credentials/2` (this file, above) answers "how do I refresh"; nothing answered
  "when." `Auth.needs_refresh?/2` already existed and already had zero callers in `lib/` —
  the same defect `Auth.refresh/2` was, caught by the same audit that found this one.
  This package holds no state and starts no timer by design (`Auth`'s own moduledoc), so
  the "when" question stays with the host on purpose rather than being answered by a poll
  loop nobody asked for; the fix is making the existing predicate reachable, not inventing
  a scheduler. `credential_failure?/1` is its usual pairing: every `Rest` call that
  reaches the venue returns `{:refused, {:venue_error, status, detail}}` on a `4xx`, and a
  host holding that tuple can now ask this package whether `status` means the credential
  rather than re-deriving `status in [401, 403]` itself. `usage-rules.md` §3 now says how
  a host is meant to use both.

- **`DpExchange.Schwab.status/1` and `DpExchange.Schwab.wanted/1`** — `Feed.status/2` and
  `Feed.wanted/1` were real, tested, working accessors on the internal `Feed` process with
  no path to them through the facade, the same defect class `subscribe_notices/1` was
  before this release. `wanted/1` is `coverage/1`'s missing other half — what was asked
  for, as distinct from what has arrived — and without it a caller had no way to tell "not
  yet delivered" from "never subscribed" from outside the package. `status/1` is the
  feed-wide health summary a monitoring loop reaches for. Both resolve the feed the same
  way `coverage/1` already does and answer the same empty value when no feed is started.

- **`DpExchange.Schwab.equity_instructions/0` and `DpExchange.Schwab.option_instructions/0`**
  — the published instruction matrix `Orders.build/2` already enforces before sending, now
  reachable the same way `transaction_types/0` already exposes the venue's transaction-type
  enum. Order writes are throttled here and reads are not, so a caller building a request
  can check the matrix first instead of discovering a mismatch by refusal.

### Removed

Seven internal-module public functions, found unwired by the same assertion-16 audit and
judged genuinely dead rather than a mechanism nothing calls. **Breaking for anyone who
called them directly** — that requires having reached past the facade, which this
package's own `CLAUDE.md` already names as the caller's defect, not this package's — so
none of these had a facade entry point to remove:

- **`Auth.refresh_margin_seconds` (deleted)** — a getter over the private margin
  `needs_refresh?/2` already uses internally. Now that `needs_refresh?/2` answers the
  "when" question directly on the facade, a host has no remaining reason to want the raw
  number.
- **`Feed.interval_ms` (deleted)** — a getter over the fallback poll's default
  interval. A host that wants a different one already passes `:interval_ms`; nothing
  needs the default to use the package correctly.
- **`Supervisor.default_read_limit` (deleted)** — a getter over the read-limiter
  courtesy ceiling. Unlike the venue's order ceiling, this number is this package's own
  self-protection, not a venue fact, and a host controls it directly via
  `:read_limit_per_minute`.
- **`StreamerFields.decodable` (deleted), `StreamerProtocol.commands` (deleted)
  and `StreamerProtocol.services` (deleted)** — pure reflections of the internal
  service/command vocabulary, each already used directly (not through these functions) by
  the guards that actually validate a request. Exposing any of the three on the facade was
  never the right fix either: `Feed`'s own moduledoc is explicit that a venue service name
  (`LEVELONE_EQUITIES`, `NYSE_BOOK`, …) "must never cross this facade" — that vocabulary is
  wire-protocol detail, not part of the contract this package publishes.
- **`StreamerProtocol.logout` (deleted)** — the one of the thirteen that took real
  checking, because deleting a mechanism outright is the wrong default when the check exists
  precisely to catch real mechanisms nothing calls. The vendor documents `LOGOUT` as a sixth
  `ADMIN` command beside a one-Streamer-connection-per-user ceiling
  (`docs/reference/schwab/documentation/market-data-production.txt`, Response Code 12), which
  is exactly the shape of fact that made `Auth.refresh/2`'s absence a real bug rather than
  dead code. But the vendor documentation says nothing about what an *unclean* disconnect
  costs a session that never sent `LOGOUT` — only that the command itself closes the
  connection — and this package has no code path that ever intentionally ends a live
  Streamer session to begin with: `Socket` only ever reconnects. Wiring `logout/2` for real
  would mean building a graceful-stop capability (suppressing the automatic reconnect for a
  self-initiated close, sending the frame, then actually closing) that does not exist today,
  on a claim the vendor does not make. That is inventing venue behavior, not fixing a gap, so
  this function is removed rather than kept as a claim resting on a guess. If the family
  later needs a graceful Streamer shutdown, `docs/design/ideas/schwab-streamer-graceful-shutdown.md`
  records what it would need to check and build.

### Added

- **`refresh_credentials/2` and `update_credentials/2` — `Auth.refresh/2` was a mechanism
  built and never wired, the same defect class as `subscribe_notices/1` above and issue
  #16/#23/#26's `rate_limit_blocking` before it.** Nothing in this package ever called
  `Auth.refresh/2` or `Auth.needs_refresh?/2`; the only way a host could reach the refresh
  the venue requires every 30 minutes was to call the internal `Auth` module directly —
  which `usage-rules.md` §3 told it to do, in direct contradiction of this package's own
  `CLAUDE.md`: "Everything except `schwab.ex` is internal... A consumer that reaches past
  the facade has found a gap in it — fix the facade, do not document the workaround."

  Worse than a missing convenience: a Streamer socket is meant to stay up far longer than
  the 30-minute access token that logs it in, and a socket had no path to a fresh one at
  all. The vendor's own response-code table marks `LOGIN_DENIED`
  (`documentation/market-data-production.txt`, section 4) `Connection Severed: Yes` — the
  venue closes the connection after refusing a stale token, `websockex` reconnects with no
  delay of its own (`on_disconnect/5` in `deps/websockex/lib/websockex.ex` calls
  `open_connection/3` synchronously and loops), and this module had no way to present a
  different token on the next attempt. Once an access token expired, every future
  reconnect was to a `LOGIN_DENIED` this module could not fix, forever, at full connect
  speed.

  Two facade functions now close both gaps:

  - **`DpExchange.Schwab.refresh_credentials/2`** delegates to `Auth.refresh/2`, reachable
    the same way Gemini's sibling `refresh_access_token/3` already is — a venue-specific
    function beyond `Core.Venue`, not a Core change. `usage-rules.md` §3 now points here
    instead of at the internal module.
  - **`DpExchange.Schwab.update_credentials/2`** pushes the refreshed credential into a
    running feed. `Feed.update_credentials/2` replaces `state.credentials` so every future
    bootstrap or poll fetch signs with it, and on the `:stream` route with a live socket,
    forwards the new `:access_token` to the new `Socket.update_access_token/2`, which
    replaces what the socket's *next* `LOGIN` presents without forcing a reconnect — a
    session already logged in keeps running on the token it logged in with.

  Proven wired end to end, not merely present: `DpExchange.SchwabTest`'s
  "update_credentials/2 actually wires into a running feed's live socket" starts a real
  feed with a socket stand-in that relays its raw mailbox, calls
  `Schwab.update_credentials/2` — the facade, not `Feed` directly — and asserts the
  stand-in actually received `{:"$websockex_cast", {:update_access_token, "fresh-token"}}`.
  That is the same shape of regression `subscribe_notices/1`'s own fix below was proven
  against, and for the same reason: a facade function that merely compiles and returns
  `:ok` proves nothing about whether it reaches the process underneath.

- **`Socket` backs off before reconnecting after a rejected `LOGIN`, rather than hammering
  the venue at full connect speed.** `state.login_failures` counts consecutive
  `LOGIN_DENIED` responses, reset to `0` the instant one succeeds, and
  `Socket.reconnect_delay_ms/1` — a base 1s delay doubling per further failure, capped at
  30s — is what `handle_disconnect/2` sleeps before returning `{:reconnect, state}`. An
  ordinary disconnect after a healthy session (`login_failures: 0`) still reconnects
  instantly; nothing about a network blip suggests the credential is the problem. This
  does not fix a stale credential by itself — only `update_credentials/2` above can — it
  stops this package from hammering Schwab's server while nobody has fixed it yet, which
  without `update_credentials/2` existing at all was an unrecoverable condition with no
  bound on how hard this package would hit the venue while stuck in it.

- **The fallback poll's own silent-delivery failure now surfaces as a `Core.Notice`, not
  only a log line — Core 0.1.50's `PollingFeed.start_link/1` `:on_notice` option
  (`{:dp_exchange_core, "~> 0.1.50"}`, bumped from `~> 0.1.48`), DpCryptoManagement's
  issue #21.** That issue is a poll-based feed on another venue that delivered nothing for
  a whole deployment with only a `Logger.warning` to show for it — a log nobody was
  grepping in time. `Core.PollingFeed` already detected "delivered NOTHING in N
  consecutive attempts" and warned; it now also calls an injected `on_notice` with a
  `Core.Notice{kind: :coverage_change}`, fired once on the transition into
  delivering-nothing (`severity: :warning`) and once on the transition back out
  (`severity: :info`, "has resumed delivering after N consecutive failures"). Latched
  internally, never once per tick and never once per sweep while an outage continues.

  This venue's `Feed` wires it in `start_poller/1`: the fallback poller's `on_notice` sends
  the notice to the feed's own mailbox exactly the way its existing `sink` and `on_refusal`
  already do, and it reaches a subscriber through the *already-generic*
  `handle_info({:dp_exchange, :schwab, %Notice{} = notice}, state)` clause — no new match
  clause needed, because that handler was never specific to any one `kind`.

  **Kept distinguishable from the Streamer's own health, deliberately.** This package
  already emits a *different* one-time notice — `Notice{kind: :degraded}` from
  `ensure_route/1` — the instant the Streamer bootstrap itself fails, and untouched here.
  The new `:coverage_change` notice describes a different failure (the fallback poll
  running and then delivering nothing), and structurally cannot be confused with the
  Streamer's own connection health: `Core.PollingFeed` runs only on this venue's `:poll`
  route, so a `:coverage_change` notice can only ever originate there, never from `Socket`
  (whose own health surfaces as `:link_down` / `:link_reconnecting`, a different `kind`,
  provider `:schwab` as an atom). The poller's label was changed from `"schwab"` to
  `"schwab-fallback-poll"` so the distinction holds in the notice's own text too, not only
  in its `kind` and `provider` — a consumer reading only the message pasted into an issue
  can tell at a glance this is the fallback poll and not the socket. Verified nothing else
  reads the poller's internal label: `PollingFeed.status/1` does not expose it, and this
  was the only call site in the package that set it.

- **`coverage_by_kind/1` implemented — Core 0.1.48's optional `Venue` callback
  (`{:dp_exchange_core, "~> 0.1.48"}`, bumped from `~> 0.1.36`).** `coverage/1` reports one
  route per symbol regardless of what actually arrived, which Core's own moduledoc traces
  to a measured incident: Coinbase's order-book channel delivered over 11,000 frames for
  406 symbols while `ticker` was dark for all but 5, and `coverage/1` reported every one of
  the 406 as `:stream` — correctly, and uselessly, because it counts a `Types.OrderBook` as
  coverage exactly as much as a `Types.Quote`.

  **This venue sharpens the same blindness rather than merely repeating it, because it also
  conflates kind with route.** This package's own moduledoc has said since the Streamer
  landed that "only quotes survive the fallback": when `GET /userPreference` cannot
  bootstrap the Streamer, `Feed` polls `/quotes` and nothing else, so depth, candles,
  orders and fills cannot arrive on that route for *any* symbol — not merely rare, but
  structurally absent. A caller reading only `coverage/1` cannot distinguish "the venue
  sent no depth for this symbol" from "this feed silently fell back to a route that cannot
  carry depth at all," which is exactly the family's forbidden substitution shape wearing a
  route label instead of a value.

  `Feed.coverage_by_kind/1` now answers that. On the **stream** route, kind is read off the
  decoded value's own struct type — confirmed by reading `Socket.decode/4` and
  `StreamerDecode`, not assumed: `LEVELONE_*` frames decode to `Types.Quote` and/or
  `Types.TopOfBook`, `CHART_*` frames decode to `Types.Candle`, and `NYSE_BOOK`,
  `NASDAQ_BOOK` and `OPTIONS_BOOK` frames decode to `Types.OrderBook` — never off the
  venue's service name, which must not cross the facade. On the **poll** route it reports
  `%{quotes: PollingFeed.coverage(poller)}` and nothing else; no `:order_book` key is
  invented to look complete, because depth cannot arrive there regardless of what is
  subscribed.

  **The design tension named up front, checked and resolved rather than assumed away:**
  Core's moduledoc for this callback describes a venue where "a symbol can legitimately be
  `:internal_poll` for one kind while another is `:stream`." That is **not reachable on
  this venue as currently built** — `state.route` is feed-wide, chosen once in
  `ensure_route/1`, and its own first clause (`when route in [:stream, :poll]`) short-
  circuits every later call before the choice is ever revisited. A symbol's *kinds* can
  differ from another symbol's on the same feed (one quotes-only, one depth-only), but
  every kind for every symbol on a given feed process comes from the one route that process
  chose at bootstrap. Recorded here rather than forced into a test that cannot exist.

  Wired through the facade (`DpExchange.Schwab.coverage_by_kind/1`) and the fake
  (`DpExchange.Schwab.Fake.coverage_by_kind/1`, which reports `:quotes` only — it never
  models order-book delivery, so claiming that key would assert a delivery the fake cannot
  produce). `Core.AdapterContract`'s assertion group 15 — which asserts nothing when a venue
  has not implemented this callback — now runs against this venue and passes: the union of
  symbols across `coverage_by_kind/1`'s values equals `coverage/1`'s keys, and every kind
  key reported is one `capabilities().streamable` declares, on both routes.

### Documentation

- **`usage-rules.md` audited against the S1/S2/S2a fixes below, since it ships inside the
  Hex tarball and is what a consuming agent reads — a wrong claim there is acted on by a
  machine.** Verified with real execution, not by reading source: `mix run` against
  `Capabilities.declaration()` for `supported_instrument_types` and every endpoint's
  maturity, and `mix test` for the `CHART_FUTURES` decode and the `get_top_of_book/3`
  refusal (`test/dp_exchange/schwab/rest_test.exs:187`, which builds a `QuoteMutualFund`
  body with no `bidPrice`/`askPrice` keys and asserts `{:error, :no_top_of_book}`). Neither
  `usage-rules.md` nor `README.md` made a claim about instrument types, `CHART_FUTURES`, or
  the old all-`nil` top-of-book behaviour in the first place, so none of the three needed
  correcting — this records that the check was made, not that it was a no-op.

  Reading both documents in full end to end found two claims that *were* wrong, neither
  connected to that sweep:

  - **§7's order-type list contradicted §7b, forty lines later, in the same file.** §7 said
    "Order types: `:market`, `:limit`, `:stop`, `:stop_limit`" and "The venue supports
    `TRAILING_STOP`, `MARKET_ON_CLOSE` and `LIMIT_ON_CLOSE`, which `Core` has no vocabulary
    for. They are not reachable through this facade." §7b, added when Core learned those
    types, already said "Eight order types, not four" and named all eight as reachable.
    `Capabilities.declaration().supported_order_types` (checked live) is the eight named in
    §7b; §7's four-and-three-unreachable claim was never updated when §7b was written and
    has read as false since. §7 now states the eight order types up front and points to §7b
    for the trailing-stop detail, and the stale bullet is removed.
  - **§11 said "twelve money-movement callbacks"; the list in `capabilities.ex` has
    eleven** (`list_payment_methods` through `list_custody_fees`) — this changelog's own
    entry for Core 0.1.34 already says "eleven" (line 320), so the doc disagreed with both
    the source and its own project's history. Corrected to eleven.

### Fixed

- **`subscribe_notices/1` was a no-op that lied about what it did — third instance of
  "mechanism built, never wired" in this family this week, after issue #23's
  `rate_limit_blocking` and issue #22's `FrameSender` retry.** The facade discarded
  `opts[:to]` and answered `:ok` unconditionally, while `DpExchange.Schwab.Feed`'s notice
  registry sat right beside it, complete and working: `Feed.subscribe_notices/2` registers
  a subscriber and `Feed`'s own `handle_info` clause for `%Core.Notice{}` fans it out to
  every one of them, including the `:degraded` notice `ensure_route/1` emits on a bootstrap
  failure and the `:coverage_change` notice the fallback poll emits on its own
  delivered-nothing transitions (added above, DpCryptoManagement's issue #21). Nothing in
  the facade ever called it. Proven empirically before the fix: registering via
  `DpExchange.Schwab.subscribe_notices(to: self())`, driving a `:degraded` notice, and
  receiving nothing.

  Now resolves the feed the same way `coverage/1` and `update_symbols/2` already do and
  delegates to `Feed.subscribe_notices/2`. A feed that is not started answers
  `{:error, :feed_not_started}` — the `update_symbols/2` convention, not `coverage/1`'s
  `%{}` — because reporting `:ok` for a registration nothing will ever fire is the same
  lie this entry fixes, just moved one branch over. Regression test registers through the
  facade (not `Feed` directly), drives the fallback poll's `:coverage_change` notice, and
  asserts it lands in the subscriber's mailbox.

- **`:rate_limit_blocking` was unreachable everywhere in this package, including on the
  fallback poll route that most needs it — family-wide gap, DpCryptoManagement's issue
  #23.** `Core.HttpClient.check_rate_limits/1` reads this option to choose `acquire/3`
  (wait for capacity) over fail-fast `check/3`, and its own error message on a
  self-inflicted throttle tells a caller to set it — but no caller could, anywhere in this
  package: `Rest.request_opts/1`, `Auth.request_opts/1` and `Feed`'s own `request_opts`
  allowlist all stripped it before it ever reached `Core.HttpClient`. The same defect
  (`dp_exchange_webull`'s issue #23, `dp_exchange_robinhood`'s issue #16) audited across
  the rest of the family; this venue was one of four still carrying it.

  **Checked for an HTTP-based periodic replay comparable to Webull's blind resubscribe,
  as the investigation asked**, and this venue has one: `Feed`'s fallback poll route —
  when the Streamer cannot be bootstrapped (`GET /userPreference` fails), `Feed` falls
  back to polling `Rest.get_price/3` on `Core.PollingFeed`'s own timer, exactly the shape
  `dp_exchange_robinhood`'s `Feed` names first (its issue #16: `check/3` answers "is there
  capacity right now," and a poll that finds none simply skips the symbol for that
  cycle — 87 of 87 symbols delivering collapsing to 8 of 87 in a single tick, purely from
  the package's own limiter). `Feed`'s own `request_opts` — shared by that poll and by its
  Streamer-bootstrap call — now defaults `:rate_limit_blocking` to `true` for the same
  reason Robinhood's and Webull's do: neither call site has a one-off caller waiting
  synchronously on a tight deadline, so blocking for capacity is free and a slower cycle
  beats a missing price. `Rest.request_opts/1` and `Auth.request_opts/1` forward the
  option without defaulting it — a direct one-off call (trading, account reads, a token
  refresh) may legitimately want fail-fast, and neither module may decide that for it;
  `Auth`'s refresh is additionally at-most-once, so forcing it to wait would only delay
  discovering a credential needs a person, not help it.

  Proven end to end on the poll route with a real, pre-exhausted `Core.DefaultRateLimiter`
  (named, passed via `:limiter`, with `Config.put_override(:rate_limit_module, …)` set
  *before* `Feed.start_link/1` is called — `Feed` snapshots `Core.Config` at that moment
  and re-applies it inside its own process and inside the poller's fetch closure,
  specifically so a consumer's async-test seam crosses that process boundary; the snapshot
  has to be captured with the right module already active): the poll's HTTP call reaches
  the stubbed venue in blocking mode by default, and an explicit
  `rate_limit_blocking: false` keeps it fail-fast and costs that cycle's quote.

- **The Streamer's connect budget was inherited by accident, not chosen — family-wide
  defect sweep, S3.** `Socket.start_link/1` passed no options to `WebSockex.start_link/4`,
  so it silently accepted the dependency's general-purpose defaults:
  `socket_connect_timeout: 6_000` and `socket_recv_timeout: 5_000` (measured in
  `deps/websockex/lib/websockex/conn.ex:10-11`). That is 11 seconds of `Feed`'s own
  15-second `@call_timeout` spent on TCP and the HTTP upgrade *before* the Streamer's LOGIN
  round trip — which has to fit inside the same call, since the venue accepts no
  subscription until it has answered the login. `Feed` is a named, shared process, so an
  unreachable venue made every other consumer's queued call wait out that window too.

  Now set deliberately to 3s and 2s, chosen against that budget and documented with the
  arithmetic, both overridable and forwarded from `Feed`. This changes no failure
  semantics — `start_link/1` still returns `{:error, reason}` synchronously exactly as
  before. Regression tests pin the values and the overrides so a later refactor cannot
  quietly fall back to the dependency's defaults.

- **Every `CHART_FUTURES` candle failed, silently and permanently — found in the
  family-wide defect sweep (S1,
  `docs/design/2026-09-05_family-wide-defect-sweep.md`).** `StreamerFields` mapped
  `"CHART_FUTURES" => @chart_equity`, reusing `CHART_EQUITY`'s numbering for a service
  the vendor numbers differently starting at field 1. Verified against the vendor's own
  field tables in this repo's committed `market-data-production.txt`:
  `CHART_EQUITY` is 0 key, 1 Open, 2 High, 3 Low, 4 Close, 5 Volume, 6 Sequence, 7 Chart
  Time; `CHART_FUTURES` is 0 key, 1 Chart Time, 2 Open, 3 High, 4 Low, 5 Close, 6 Volume —
  no sequence, no chart day, and the timestamp one field earlier. Under the shared map, a
  futures frame's Chart Time decoded as `:open`, its real open as `:high`, and so on, and
  `to_candle/3` — which reads `:chart_time` — never found it, so `{:error,
  :missing_venue_timestamp}` fired on every frame. `socket.ex`'s `decode/4` swallows that
  error into `[]`: no candle, no crash, nothing in the logs. `StreamerFields.decodable` (since deleted)
  and `StreamerProtocol.services` (since deleted) both advertised the service as working the entire
  time. Fixed with a separate `@chart_futures` map transcribed from the vendor's own
  table. `grep -rn CHART_FUTURES test/` found exactly one prior hit — an assertion that
  the name appears in a services list — and no test had ever decoded a real
  `CHART_FUTURES` frame; added one built from the vendor's field numbering
  (`test/dp_exchange/schwab/socket_test.exs`) plus a unit test on the field map itself
  (`test/dp_exchange/schwab/streamer_test.exs`).

- **`capabilities/0` declared instrument types the code cannot route — S2 of the same
  sweep.** `supported_instrument_types` named `:future, :future_option, :index,
  :mutual_fund, :bond, :forex, :cash_equivalent` alongside `:spot` and `:option`, but
  `SymbolFormat.validate/1` — which every `Rest` and `Orders` function gates on before
  building a request — refuses any symbol containing `-`, `/`, `_` or `:`. Traced against
  the venue's own documented spellings: `/ESZ25` (a future), `EUR/USD` (forex) and `$SPX`
  (an index) are all refused as `{:error, {:not_an_equity_symbol, symbol}}` before a
  request is ever built, and the declaration contradicted this package's own
  `Schwab.asset_classes/0`, which has always said `[:equity]`. Narrowed the declaration to
  `[:spot, :option]` — the two shapes `SymbolFormat.validate/1` demonstrably accepted at
  the time (a plain equity ticker, and a 21-character fixed-width option symbol) and that
  `Rest.get_price/2`'s decode read correctly for both. `:mutual_fund`, `:bond` and
  `:cash_equivalent` were dropped too, not because they were disproven but because nothing
  in this repository had ever checked them — declaring an unmeasured claim is the same
  violation in the other direction.
  `test/dp_exchange/schwab/capabilities_test.exs:211` used to assert `:future in types`,
  encoding the false claim; corrected to assert the routable set and to check the claim
  against the actual gate (`SymbolFormat.validate/1`) rather than against the declaration
  alone.

  **Re-examined once measured, rather than left as "unmeasured, so dropped."**
  `SymbolFormat.validate/1` accepts `SWPPX` (a Schwab index fund) and `SNSXX` (a Schwab
  money-market fund) — plain letter tickers, since the venue does not spell a mutual fund
  symbol any differently from an equity one — while a Treasury CUSIP (`912828YY0`) is
  correctly refused, digits being outside `equity?/1`'s regex. So `:bond` stays dropped as
  a *measured* refusal, and `:mutual_fund`/`:cash_equivalent` moved from "unmeasured" to
  "measured routable" once the decode gap below was closed — the venue's own OpenAPI
  schema gives money-market funds (`assetSubType: MMF`) the identical `QuoteMutualFund`
  shape as ordinary funds (`OEF`/`CEF`), so one decode fix covers both declared types.
  `supported_instrument_types` is now `[:spot, :option, :mutual_fund, :cash_equivalent]`.
  Genuinely supporting the futures/forex/index types that remain dropped is still a
  feature (deferred, sweep §3), not this fix — it needs `SymbolFormat` taught those
  grammars as their own validated, non-equity shape, which `SymbolFormat.validate/1` is
  deliberately NOT loosened to do here.

- **A mutual fund's quote decoded as a venue error, for a payload the venue sent
  correctly.** `SymbolFormat.validate/1` has always accepted mutual fund symbols (they are
  spelled like equity tickers), but `Rest.quoted_price/1` read only `row["lastPrice"] ||
  row["mark"]`, and the vendor's own `QuoteMutualFund` schema
  (`docs/reference/schwab/openapi/market-data-production.openapi.json`) has neither field
  — a fund does not print continuous trades. Every real mutual fund quote therefore failed
  as `{:error, :unexpected_response_shape}`: the wrong-error twin of this family's usual
  defect, blaming the venue for a response that was completely valid. Fixed by reading
  `nAV` (Net Asset Value) as the price when `lastPrice`/`mark` are absent — the value the
  fund actually transacts at, not a derived stand-in, so this is not the ask-for-a-price
  substitution the family forbids. `closePrice` (yesterday's NAV) is deliberately never
  read as a further fallback: absent `nAV` still fails closed exactly as the equity path
  does. `get_top_of_book/3` also used to build an all-`nil` `TopOfBook` for a mutual fund,
  indistinguishable from a real book that happened to be empty — `QuoteMutualFund` has no
  `bidPrice`/`askPrice`/`bidSize`/`askSize` keys at all, so it now refuses cleanly with
  `{:error, :no_top_of_book}` when none of those keys are present, rather than nil-filling
  a book that does not exist. Regression tests build a `QuoteMutualFund` body from the
  vendor's own field list (`test/dp_exchange/schwab/rest_test.exs`), asserting the decoded
  price/volume/timestamp, the fail-closed behaviour when `nAV` is absent, and the
  `get_top_of_book/3` refusal — plus that an equity's top of book is unaffected.

- **A flaky `mix test --cover` failure, root-caused rather than dismissed.** One run
  showed a transient failure that did not reproduce on the next; treated as a real bug
  per this family's standard, not written off as noise. Root cause: six call sites in
  `test/dp_exchange/schwab/feed_test.exs` did `send(feed, msg)` to a live `Feed`
  GenServer and then `assert_receive` with ExUnit's default 100ms timeout — a genuine
  two-hop, cross-process wait (the `Feed` has to run `handle_info` and re-`send/2` to the
  test process), unlike this package's many same-process `assert_received` uses, which
  follow a call that has already returned synchronously and are not at risk. Under
  `--cover`'s instrumentation combined with `async: true`'s concurrency, 100ms is
  occasionally not enough. Fixed by giving all six the explicit 2,000ms budget this same
  file's bootstrap-path tests already used. Verified with 30+ clean `mix test --cover`
  runs across varied seeds (including one under deliberate heavy CPU load) before the
  fix, none reproducing the failure, and a further 100-run clean batch after it.

- **`get_symbol_quote/3` could build a malformed path for a non-equity symbol.** It is the
  one `Rest` function that deliberately skips `SymbolFormat.validate/1` (it reads back
  whatever a search or a chain handed it), so a symbol like `/ESZ25` could reach
  `URI.encode(native)` — whose default predicate leaves `/` unescaped, since it is meant
  for a whole URI rather than one path segment — producing `.../marketdata/v1//ESZ25/quotes`,
  an extra empty segment ahead of the real one. Fixed by restricting the predicate to
  `URI.char_unreserved?/1`, which percent-encodes everything unsafe inside a single
  segment (`/ESZ25` becomes `%2FESZ25`); a plain equity symbol is unaffected. Low impact
  given the S2 fix above narrows what reaches here in practice, but it was the one place
  the equity gate did not apply.

- **`Feed.fan_out/2` crashed on a subscriber registered by name — DpCryptoManagement's
  issue #15, same defect found on the sibling `dp_exchange_coinbase` package.**
  `subscribe/2`'s `to:` option accepts any value, and `fan_out/2` called
  `Process.alive?/1` on it directly — which only accepts a pid and raises on anything
  else. A consumer registering itself under a name (ordinary OTP practice) and handing
  that name to `to:` crash-looped the whole `Feed` GenServer on every delivery. Fixed by
  resolving a subscriber (pid or name) to a pid first, treating an unregistered name the
  same as a dead pid: silently skipped, never a crash.

- **`Decimal.new/1` raised on a non-numeric price string — the same defect class filed
  against `dp_exchange_webull` as DpCryptoManagement's issue #3.** Auditing every copy of
  the raising pattern in this package found it here too, in `rest.ex`'s `decimal/1`
  (`streamer_decode.ex` already used the safe form). Fixed with `Decimal.parse/1`,
  requiring the whole string be consumed — matching this package's own `chain_strike/1`,
  which already carried a comment naming the exact hazard.

  The lenient fix alone would have introduced a second, quieter defect: a malformed
  required field silently becoming `nil` instead of raising, which `@enforce_keys` does
  not catch. `build_quote/2` and `candle/3` now refuse the record instead
  (`{:error, {:invalid_decimal, field, value}}`), rather than delivering a `Quote` or
  `Candle` with a fabricated-looking `nil` in a field the type promises is real.

### Added

- **The Streamer is connected to the facade.** `subscribe/2` now bootstraps it through
  `GET /userPreference` and delivers over the socket; `coverage/1` reports `:stream`.

  The socket, its protocol, its field tables and its decoders all shipped last release —
  and **nothing called them.** `Feed` was still a REST poll, `subscribe/2` still routed to
  it, and `capabilities/0` already declared `streamable: [:quotes, :top_of_book,
  :order_book, :candles, :orders, :fills]`. **Four of those six reached no subscriber by any
  route.** Every test passed the whole time: the socket's own tests exercise its callbacks
  directly, and no test asked what a consumer receives.

  That is an over-declaration, which fails in a caller's hands rather than in CI, and it is
  the exact defect this package's own guide warns about in the other direction.

- **`Feed` falls back to polling when the bootstrap fails, and says so.** No token, an
  expired one, or a response without `streamerInfo` leaves the feed polling, emitting
  `:degraded` with the reason, and reporting `:internal_poll` on every symbol. **The route
  is always visible.** A poll that reported `:stream` would be this family's signature
  defect; a fallback that reported nothing would leave a consumer wondering where depth went.

- **`Feed.subscribe/3`, `unsubscribe/2` and `wanted/1`.** The feed now distinguishes what was
  *asked for* from what has *arrived*, which `coverage/1` deliberately does not.

### Fixed

- **`subscribe/2` silently dropped symbols that had not delivered yet.** It read the current
  set out of `coverage/1` and re-sent the union — and coverage reports only what has actually
  arrived, so a symbol subscribed a moment earlier and not yet quoted was absent from it and
  was unsubscribed by the next call.

  Observed-versus-intended is the distinction this family insists on, and here it had been
  applied to the wrong set: reporting only what arrived is right, and *subscribing* to only
  what arrived is a loss.

- **A consumer's `Core.Config` overrides now reach the feed.** `Config` resolves through the
  calling process and its `$callers` chain; a `GenServer` is in neither. The feed snapshots
  the starting caller's overrides and re-applies them in its own process and in the poller's
  — without which a consumer that swapped the rate limiter for its own async test would find
  the feed metering against the global one.

### Documentation

- **Three stale claims about the socket corrected**, in `README.md`, `DpExchange.Schwab`'s
  moduledoc and `Rest.get_top_of_book/3`. `get_order_book/2`'s reason has now changed three
  times behind one unchanged `:unsupported` — first "the venue has no order book", which was
  false; then "the Streamer is not implemented here", which was true and no longer is; now
  **"the REST API publishes no depth"**, which is the narrow thing that is actually true.

  Two of the three reasons were wrong and the value never moved to show it. That is the
  argument for writing the reason down rather than the value alone.

### Documentation

- **`streamable` now names what the Streamer carries** — quotes, top of book, **depth** and
  candles, plus order and fill events with a credential. It said `[:quotes]` while this
  package could not speak the socket; it can, so it does not any more.

  **`:trades` stays out, and that is a distinction rather than an omission.** No Streamer
  service publishes a tape: `LEVELONE_*` carries a *last* price, which is one print restated
  on every update rather than the sequence of them. Declaring it would promise a consumer
  something it would have to reconstruct from a field that skips prints. `:balances` and
  `:positions` stay out for the same kind of reason — `ACCT_ACTIVITY` reports activity, not
  state.

  Both streaming lists are **identical**, and that says something rather than being an
  oversight: there is no public market data on this venue and no anonymous socket.

- **Every negative this package makes is audited** —
  `docs/reference/schwab/negative-claims.md`, fourteen claims with the source and date
  consulted for each. Thirteen hold. The one that did not is the one this package is known
  for: *"Schwab has no streaming API"* was made from the OpenAPI documents alone, and the
  Streamer is not REST and is therefore absent from them by construction.

  The lesson is written down so it is not re-learned: **check every page a vendor publishes,
  not the endpoint list alone.**

- **`usage-rules.md` gains the Streamer, options, and transactions**, and its
  "what this package does not implement" section is now backed by that audit rather than by
  assertion. It records the per-service field numbering — field 1 is `bid` on equities and
  `description` on options; fields 6 and 7 are swapped between equities and futures — and
  that `SUBS` replaces where `ADD` accumulates.

- **`AGENTS.md` is a pointer, not a second copy.** This package carried a byte-identical
  duplicate of its own `usage-rules.md` while the other five carried the generated
  `usage_rules` file. A duplicate drifts, and a reader who finds two documents cannot tell
  which is current. All six now carry the generated file plus a pointer to the package's own
  rules.

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
