# Schwab depth and account-activity streaming

Non-blocking discovery from a documentation-accuracy sweep (2026-09-06) that found
`capabilities/0` declaring `:order_book`, `:orders` and `:fills` streamable while
`Feed.services_for/1` (then `service_for/1`) never subscribed `NYSE_BOOK`, `NASDAQ_BOOK`,
`OPTIONS_BOOK` or `ACCT_ACTIVITY` — a consumer asking for any of the three got the
declaration and then permanent silence. The declaration was narrowed to
`[:quotes, :top_of_book, :candles]` rather than wiring the subscribe side, because wiring
either would mean guessing venue behaviour this package's own rules refuse to guess. This
doc is what closing that gap for real would need.

## `:order_book` — `NYSE_BOOK` / `NASDAQ_BOOK` / `OPTIONS_BOOK`

**What was found.** The vendor documents `NYSE_BOOK` and `NASDAQ_BOOK` identically —
"Level Two book for Equities" — and states no rule for which service a given equity
symbol belongs on. Subscribing every symbol to both, or picking one arbitrarily, would be
this family's forbidden substitution: a plausible book arriving under the wrong service
name, or twice, is not distinguishable from a correct one by its shape.

`LEVELONE_EQUITIES` field 13 (`exchange_id`, "Exchange ID" / "Primary 'listing' Exchange"
in the vendor's REST quote fields) is the only field this package has read from that could
answer the routing question — but only *after* a quote has already arrived for the
symbol, and only if its coded values are confirmed to mean "route to `NYSE_BOOK`" versus
"route to `NASDAQ_BOOK`", which the prose documentation committed here does not spell out
for the Streamer's `exchange_id` field specifically.

`OPTIONS_BOOK` does not have this problem — every option symbol this package accepts
(`SymbolFormat.option?/1`) is unambiguous, and there is exactly one options book service.

## `:orders` and `:fills` — `ACCT_ACTIVITY`

**What was found.** `StreamerFields`'s own `@acct_activity` map decodes `message_data` as
an opaque string, with the comment: "a string carrying JSON whose shape depends on
`message_type`... the vendor does not publish [it] in this document." Decoding it into
`Core.Types.Order` or `Core.Types.Fill` needs that per-`message_type` schema, and this
package has no source for it — inventing one is exactly the "unknown activity into a
wrongly-shaped known one" `StreamerFields` was written to refuse.

## What building either for real would need

1. **Depth**: a confirmed, vendor-stated (or portal-support-confirmed) mapping from
   `LEVELONE_EQUITIES`'s `exchange_id` values to `NYSE_BOOK` / `NASDAQ_BOOK`, plus a
   `Feed` change to sequence the subscription — quote first, book once the symbol's
   exchange is known — since today `services_for/1` decides routing from the symbol alone
   and has no state to hold "which book this symbol belongs on" while waiting for a quote.
2. **Account activity**: the vendor's own schema for `message_data` per `message_type` —
   from a future documentation revision, or from a credential-holding consumer capturing
   real frames during a Phase-2/3 exercise (tiers 2–3 per `usage-rules.md` §1, which this
   repository cannot run itself) — followed by `Core.Types.Order`/`Fill` decode functions
   in `StreamerDecode` built against that confirmed shape, not a guessed one.

Neither belongs in a documentation-accuracy fix. If a future defect or a vendor
documentation update supplies either missing fact, this doc is the starting point, and
`capabilities/0`'s `streamable` widens only once the corresponding decode is written and
tested against a confirmed shape — never ahead of it.
