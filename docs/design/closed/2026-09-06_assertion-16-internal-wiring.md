# Assertion 16 ("internal wiring") sweep - Design Document

**Date**: 2026-09-06
**Status**: Implemented
**Version**: 1.0
**Author(s)**: Architect/Claude collaboration

## Project Overview

### Objectives

- [x] Resolve every violation `Core.AdapterContract`'s new assertion 16 reports against
      this package, with a stated decision (wire / delete / expose on facade) and
      justification per function.
- [x] For `Auth.needs_refresh?/2`, decide whether the host or the package should be the
      one deciding "when to refresh," and leave the host with a usable answer either way.
- [x] For `StreamerProtocol.logout/2`, check the vendor documentation before deciding, and
      do not invent a venue consequence the documentation does not state.
- [x] Land the same commit with `usage-rules.md` and `CHANGELOG.md` updated — not deferred.
- [x] Clear `mix test` (0 failures, including assertion 16 against a local Core checkout),
      `mix quality`, `mix test --cover` (>= 90), `mix docs` (0 doc-reference warnings).

### Scope

**In scope**: the thirteen violations assertion 16 reports (`Auth.needs_refresh?/2`,
`Auth.credential_failure?/1`, `Auth.refresh_margin_seconds/0`, `Feed.interval_ms/0`,
`Feed.status/1`, `Feed.wanted/1`, `Orders.equity_instructions/0`,
`Orders.option_instructions/0`, `StreamerFields.decodable/0`,
`StreamerProtocol.commands/0`, `StreamerProtocol.services/0`, `StreamerProtocol.logout/2`,
`Supervisor.default_read_limit/0`), plus the facade and documentation changes each
resolution requires.

**Out of scope**: any other family-wide defect sweep, any change to Core, and building a
graceful Streamer shutdown capability (see `docs/design/ideas/schwab-streamer-graceful-shutdown.md`
— discovered while reasoning about `logout/2`, deliberately not acted on here).

### Why this is urgent

Core's `Core.AdapterContract` gained assertion 16, built on `Core.UnwiredCheck`, which
reads `:xref`'s real call graph (a captured `&Mod.fun/1` and `apply(Mod, :fun, args)` both
count as callers) restricted to modules compiled from `lib/` — a call from `test/` does
not count. It exists because "mechanism built, documented, and never wired" hit this
family six times in one week, two of them in this package (`subscribe_notices/1`'s
registry, `Auth.refresh/2`). The next time this package bumps its `dp_exchange_core`
dependency past the version that ships this assertion, its own suite fails on the
violations below unless they are cleared first.

## The judgement, per violation

Every violation resolves to one of: **wire** (a real mechanism, reachable from the facade
or an internal caller, that should be called and was not), **delete** (a getter over a
module attribute or an orphaned builder with no real consumer), or **expose on facade**
(a wiring fix that specifically means adding the missing facade entry point).

### `Auth.needs_refresh?/2` — the one that needed the most care

**Decision: expose on the facade**, as `DpExchange.Schwab.needs_refresh?/2`, paired with
the already-wired `refresh_credentials/2`.

Two candidates were weighed:

1. **The host decides when to refresh** (facade exposure). `Auth` holds no state and
   starts no timer by design — its own moduledoc: "Nothing is cached here. This module
   holds no state, writes nothing." A host already holds `credentials` (it is passed per
   call, never stored by this package, per §6.0) and is the only thing with an opinion
   about *when* it is about to need one.
2. **Something in-package checks and self-reports** (a new internal mechanism), which
   would have meant Feed periodically checking `needs_refresh?/2` against
   `state.credentials` and emitting `Core.Notice{kind: :credentials_expiring}` — a real,
   unused Core notice kind, and Coinbase's and Webull's sockets already emit its sibling
   `:credentials_rejected` on an auth failure, which is genuine family precedent for
   in-package credential signaling.

Option 2 was rejected for this pass, not because it is a bad idea, but because it is a
different and larger piece of work than a wiring fix: `Feed` has no timer today (the
`:poll` route's own ticks capture `state.credentials` once per `start_poller/1` call, not
per tick, so even that existing periodic hook is not a clean fit without also fixing that
capture), and there is no cross-venue precedent yet for *expiring* (as opposed to
*rejected*) credentials in this family. Building it well is its own design document, not
a line item in a thirteen-violation sweep. Exposing `needs_refresh?/2` is minimal, safe,
mirrors exactly how `refresh_credentials/2` was fixed one commit earlier, and gives the
host a real, usable answer to "when do I refresh" today. `usage-rules.md` §3 now states
it.

### `Auth.credential_failure?/1`

**Decision: expose on the facade**, as `DpExchange.Schwab.credential_failure?/1`. Every
`Rest` call that reaches the venue already returns `{:refused, {:venue_error, status,
detail}}` on a `4xx` — the host already has `status` in hand the moment it needs this
answer. `Rest.ex`'s own comment ("what a caller checks to decide whether refreshing and
retrying is worth doing") describes a host-facing helper, not an internal one; nothing in
this package retries a refused request itself (the moduledoc is explicit that refresh is
never automatic).

### `Auth.refresh_margin_seconds/0`

**Decision: delete.** A getter over the private margin `needs_refresh?/2` already applies
internally. Now that `needs_refresh?/2` itself answers "is it time," a host has no
remaining reason to want the raw number — it is not required to interpret the boolean, and
no code anywhere reads the getter instead of the attribute.

### `Feed.interval_ms/0`

**Decision: delete.** A getter over the fallback poll's default interval, read directly
from the attribute everywhere it is used. A host that wants a different interval already
passes `:interval_ms` to `start_link/1`; nothing in the package's own correctness depends
on a host knowing the default.

### `Feed.status/1` and `Feed.wanted/1`

**Decision: wire — expose both on the facade**, as `DpExchange.Schwab.status/1` and
`DpExchange.Schwab.wanted/1`. These are not attribute getters; they are live `GenServer`
state queries, documented as genuinely useful (`wanted/1`: "What has been asked for, which
is not what `coverage/1` reports" — the observed-versus-intended pairing `coverage/1`
needs to be read correctly), fully tested, and simply never reachable through the facade.
This is the same defect class as `subscribe_notices/1` one commit earlier: a real,
working, internal mechanism with no facade entry point. Both now resolve the feed exactly
as `coverage/1` does and answer the same empty value when no feed is running.

### `Orders.equity_instructions/0` and `Orders.option_instructions/0`

**Decision: wire — expose both on the facade.** The published instruction matrix
`Orders.build/2` already enforces before sending. This is a direct parallel to the
already-exposed `transaction_types/0` ("there is no 'all' in the venue's type enum") —
venue vocabulary a caller needs to construct a valid request without wasting a throttled
order write discovering the mismatch by refusal.

### `StreamerFields.decodable/0`, `StreamerProtocol.commands/0`, `StreamerProtocol.services/0`

**Decision: delete, all three.** Each is a pure reflection of an internal attribute
(`@maps`, `@commands`, `@services`) already read directly by the code that actually
validates a request (`for_service/1`'s `Map.fetch`, `known_service/1`'s membership guard).
No caller anywhere in `lib/` used the getter instead of the attribute. Exposing any of the
three on the facade was considered and rejected on a stronger ground than "unused": `Feed`'s
own moduledoc states a venue service name (`LEVELONE_EQUITIES`, `NYSE_BOOK`, …) "must
never cross this facade" — that vocabulary is wire-protocol detail this package
deliberately keeps internal, not part of the contract it publishes. `@services` stays (it
gates `known_service/1`); `@commands` and `@maps`'s only external accessor were removed
with their getters.

### `StreamerProtocol.logout/2` — checked against the vendor documentation

**Decision: delete**, after reading
`docs/reference/schwab/documentation/market-data-production.txt`.

The vendor documents `LOGOUT` as a sixth `ADMIN` command — *"Logs out of the streamer
connection. Streamer will close the connection."* — beside a documented ceiling of **one
Streamer connection per user at a time** (Response Code 12, `CLOSE_CONNECTION`). That
combination is exactly the shape of fact that made `Auth.refresh/2`'s absence a confirmed
bug: a documented consequence (`LOGIN_DENIED`, `Connection Severed: Yes`) directly tied to
a mechanism nothing called. `logout/2` was checked against the same bar and the
documentation did not clear it: **it says nothing about what an unclean disconnect costs a
session that never sent `LOGOUT`** — only what the clean path does. Absence of a stated
consequence is not evidence of one, and this package's own rule is not to guess venue
behaviour.

Separately, and independently of the documentation question: this package has **no
existing code path** that intentionally ends a live Streamer session. `Socket` only ever
reconnects (`handle_disconnect/2`). Wiring `logout/2` for real would mean building a new
capability — suppressing the automatic reconnect for a self-initiated close, sending the
frame, then actually closing, plus a facade-level "stop this feed" entry point that does
not exist today. That is new product surface, not a wiring fix, and it would rest on a
consequence the vendor does not document. `logout/2` is removed; the reasoning and what
building it for real would need are recorded at
`docs/design/ideas/schwab-streamer-graceful-shutdown.md` for if/when the family has
evidence the risk is real.

### `Supervisor.default_read_limit/0`

**Decision: delete.** A getter over this package's own courtesy read-ceiling — unlike the
venue's order limit (`0..120`, genuinely unknowable without a registration), this number
is invented self-protection, not a venue fact. A host controls it directly via
`:read_limit_per_minute`; nothing needs the default to use the package correctly.

## Gates

- `mix test`: 0 failures, 437 tests, including assertion 16 clean against a local
  `dp_exchange_core` checkout (`{:dp_exchange_core, path: ..., override: true}`, reverted
  before commit).
- `mix quality` (format, `credo --strict`, `dialyzer`, `sobelow`): clean.
- `mix test --cover`: 90.50% (baseline before this change: 90.56% — net neutral, both
  comfortably above the 90% threshold).
- `mix docs`: 0 documentation-reference warnings.

## Retrospective

**What was found.** Of the thirteen reported violations, four were real mechanisms with
no facade entry point (`needs_refresh?/2`, `credential_failure?/1`, `status/1`,
`wanted/1`) — the same defect class as `subscribe_notices/1`, caught by the same audit
one commit earlier. Two more (`equity_instructions/0`, `option_instructions/0`) were real
venue vocabulary that belonged on the facade for the same reason `transaction_types/0`
already is. Seven were genuinely dead: three attribute getters no code ever called instead
of the attribute (`refresh_margin_seconds/0`, `interval_ms/0`, `default_read_limit/0`),
three more of the same shape that additionally would have leaked wire-protocol vocabulary
across the facade if exposed instead (`decodable/0`, `commands/0`, `services/0`), and one
(`logout/2`) that looked at first read like it might be the same class of bug as
`Auth.refresh/2` — a documented venue mechanism nothing called — but did not survive
checking against the vendor documentation and the package's own architecture: no stated
consequence, and no existing capability to call it from.

**What this confirms about the check.** Assertion 16 does not distinguish "dangerous to
delete" from "safe to delete" — that judgement has to be made per function, against the
vendor documentation and this package's own facade boundary, not assumed from the shape of
the violation list. Four of thirteen turned out to be the dangerous kind here; nine did
not. Both outcomes are the check doing its job.

**Nothing deferred.** All thirteen violations resolved in this pass; `usage-rules.md` and
`CHANGELOG.md` updated in the same commit as the code, per this package's own "Definition
of Done."
