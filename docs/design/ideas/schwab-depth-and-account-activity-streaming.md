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

`OPTIONS_BOOK` does not have **this** problem — every option symbol this package accepts
(`SymbolFormat.option?/1`) is unambiguous, and there is exactly one options book service.

### Correction, 2026-09-10: `OPTIONS_BOOK` is blocked too, by something else

The sentence above is true and was read as "so the options half is wireable". It is not,
and this section exists because that reading was tested against the vendor's own text and
failed. **A design document that records a part as unblocked when it is not is a trap for
whoever picks it up next** — worse than one that says nothing.

Two independent blockers, neither of which is the routing ambiguity above:

**1. The vendor does not document the key format for the book services' option case.**
The two are documented *differently*, which is the opposite of the test the equities
routing decision used:

| service | vendor's `keys` description |
|---|---|
| `LEVELONE_OPTIONS` | "Options symbols in uppercase and separated by commas **Schwab-standard option symbol format: RRRRRRYYMMDDsWWWWWddd**" |
| `NYSE_BOOK` / `NASDAQ_BOOK` / `OPTIONS_BOOK` (one shared "Book Common" table) | "Symbols in upper case and separated by commas. **e.g.: AAPL,TSLA,IBM**" |

The book table is generic-equity phrasing with equity examples and states no option format
at all. Routing an option symbol there means *assuming* it takes the `LEVELONE_OPTIONS`
format — and `services_for/1`'s own comment records the standard this package holds itself
to: `LEVELONE_EQUITIES` and `CHART_EQUITY` were routed the same symbols only because they
are "documented with the identical … key format, so … **no new judgement** about which
symbols qualify". Here the formats are documented differently, so it is a new judgement.

**2. `capabilities/0` cannot say "order book, options only".** `Core.Capabilities`'
`streamable` is `[data_kind()]` — a flat list with no asset-class dimension (checked
2026-09-10 against `capabilities.ex`). Adding `:order_book` would claim it for equities,
where it is false and blocked by the routing ambiguity above. Leaving it out while
delivering option books would push a payload kind a consumer was never told to expect,
which is the shape assertion 20 exists to catch. **Both halves of the declaration would be
wrong**, and that is independent of blocker 1 — fixing the key format alone does not
unblock this.

The same flat-list gap has bitten this family before, on `dp_exchange_webull`'s
`historical_timeframes`, where per-asset-class widths could not be expressed either. If it
is ever closed in Core, that is what unblocks this half — not a Schwab change.


## `:orders` and `:fills` — `ACCT_ACTIVITY`

**What was found.** `StreamerFields`'s own `@acct_activity` map decodes `message_data` as
an opaque string, with the comment: "a string carrying JSON whose shape depends on
`message_type`... the vendor does not publish [it] in this document." Decoding it into
`Core.Types.Order` or `Core.Types.Fill` needs that per-`message_type` schema, and this
package has no source for it — inventing one is exactly the "unknown activity into a
wrongly-shaped known one" `StreamerFields` was written to refuse.

## What building either for real would need

1. **Equity depth**: a confirmed, vendor-stated (or portal-support-confirmed) mapping from
   `LEVELONE_EQUITIES`'s `exchange_id` values to `NYSE_BOOK` / `NASDAQ_BOOK`, plus a
   `Feed` change to sequence the subscription — quote first, book once the symbol's
   exchange is known — since today `services_for/1` decides routing from the symbol alone
   and has no state to hold "which book this symbol belongs on" while waiting for a quote.
1a. **Options depth** (see the Correction above — this is NOT the easy half): the vendor's
   own statement of the `keys` format `OPTIONS_BOOK` accepts, which the shared "Book
   Common" table does not give, **and** a way for `capabilities/0` to say "order book,
   options only" — which `Core.Capabilities`' flat `streamable: [data_kind()]` cannot
   express today. The second is a Core change, not a Schwab one, and it also blocks
   `dp_exchange_webull`'s per-asset-class `historical_timeframes`.
2. **Account activity**: the vendor's own schema for `message_data` per `message_type` —
   from a future documentation revision, or from a credential-holding consumer capturing
   real frames during a Phase-2/3 exercise (tiers 2–3 per `usage-rules.md` §1, which this
   repository cannot run itself) — followed by `Core.Types.Order`/`Fill` decode functions
   in `StreamerDecode` built against that confirmed shape, not a guessed one.

Neither belongs in a documentation-accuracy fix. If a future defect or a vendor
documentation update supplies either missing fact, this doc is the starting point, and
`capabilities/0`'s `streamable` widens only once the corresponding decode is written and
tested against a confirmed shape — never ahead of it.
