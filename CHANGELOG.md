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
