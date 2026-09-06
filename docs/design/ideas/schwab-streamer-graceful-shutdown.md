# Schwab Streamer graceful shutdown

Non-blocking discovery from the assertion-16 internal-wiring sweep
(`docs/design/closed/2026-09-06_assertion-16-internal-wiring.md`).

## What was found

`StreamerProtocol.logout/2` built the venue's documented `ADMIN`/`LOGOUT` request and had
zero callers anywhere in `lib/`. It was deleted rather than wired, because wiring it for
real needs a capability this package does not have today: something that intentionally
ends a live Streamer session. `Socket` currently only ever reconnects
(`handle_disconnect/2`); there is no `Feed`- or facade-level "stop this feed" call for a
`LOGOUT` frame to precede.

## Why it might matter

The vendor documents a hard ceiling: **one Streamer connection per user at a time**
(`docs/reference/schwab/documentation/market-data-production.txt`, Response Code 12,
`CLOSE_CONNECTION`). `LOGOUT` is the vendor's own documented way to end a session cleanly
— *"Logs out of the streamer connection. Streamer will close the connection."* The
documentation does not say what, if anything, an abrupt disconnect (no `LOGOUT`) costs a
session that never sent it — whether the one-connection slot is held until some
server-side timeout, or released immediately either way. That silence is exactly why this
was not wired as a guess: `Auth.refresh/2`'s absence was a confirmed bug because the
consequence (`LOGIN_DENIED` on every reconnect past 30 minutes) was directly readable from
the vendor's own response-code table. This one has no equivalent confirmation.

## What building it for real would need

1. A way to know an unclean disconnect actually costs something — either a statement in
   a future vendor document, or an observed `CLOSE_CONNECTION` during Phase-2 live testing
   (tier 2, per `usage-rules.md` §1 and this package's own testing tiers) after a process
   crash or restart without a clean logout.
2. A `Feed`/`Socket` state flag distinguishing a self-initiated close from an unexpected
   one — `handle_disconnect/2` today always attempts to reconnect, and a `LOGOUT` sent by
   this package would otherwise trigger its own reconnect logic, undoing the intended stop.
3. A facade-level "stop this feed" entry point for a host to call on intentional shutdown
   — there is none today; a host currently only ever tears down the whole supervision
   subtree it owns.

None of this belongs in a wiring-only fix. If a future defect (a `CLOSE_CONNECTION` seen
in practice, or a vendor documentation update) confirms the risk, this doc is the starting
point.
