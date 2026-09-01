# Every negative this package makes, and what was checked

**Audited 2026-09-01.** A negative is any statement that the venue *lacks* something: a
`:unsupported` declaration, a "there is no…", a "does not support…". §0's rule says a value
must never be substituted for a missing one; this is the same rule pointed at documentation.
**An unverified negative is a substitution exactly like an invented value.**

This package is the reason the rule exists. "Schwab has no streaming API" was a plausible
negative nobody verified. It survived review and shaped `mix.exs`, three moduledocs and a
capability declaration — and it was **wrong**: the Streamer carries fifteen services, and is
documented in the prose beside the OpenAPI documents rather than inside them.

## What each negative was checked against

Sources, all consulted 2026-08-28 unless noted:

| source | what it is |
|---|---|
| **MD** | `docs/reference/schwab/openapi/market-data-production.openapi.json`, OpenAPI 3.0.3 |
| **AT** | `docs/reference/schwab/openapi/accounts-and-trading-production.openapi.json`, OpenAPI 3.0.1 |
| **prose** | the portal's Documentation tab for both APIs, `docs/reference/schwab/documentation/` |
| **guides** | the portal's 17 User Guides, `docs/reference/schwab/user-guides/` |
| **portal** | the signed-in Developer Portal, `docs/reference/schwab/portal-product-landscape.md` |

## The negatives, one per row

| claim | verified against | verdict |
|---|---|---|
| No crypto surface — no staking, no perpetual funding, no conversions, no deposit addresses, no networks, no allowlist | MD + AT, both re-read 2026-09-01 | **holds.** Schwab is an equities and options broker; none of these paths exists in either document |
| No payment methods, no internal transfer, no fiat registration | AT, 2026-09-01 | **holds.** Money reaches the account through cheques, ACH and wires arranged with a person |
| No FX rate, no notional valuation, no custody fee endpoint | AT, 2026-09-01 | **holds** |
| No batch order placement | AT, 2026-09-01 | **holds.** `POST /accounts/{n}/orders` takes one order. Its multi-leg orders are one *order* with several legs, which the venue accepts or rejects as one — a different thing |
| No preview-replace | AT, 2026-09-01 | **holds.** `previewOrder` prices an order that does not exist yet; there is no `previewReplaceOrder`, and replacing is `PUT` on the order itself |
| No bulk cancel | AT | **holds.** Cancelling is `DELETE` on one order |
| No position-closing endpoint | AT | **holds.** Positions are read through the account and closed by placing the order yourself |
| No aggregated trade volume | AT | **holds.** The account reports transactions; summing them here would be this package's arithmetic |
| No REST order book | MD | **holds, and it is narrower than it was.** Depth arrives on the Streamer; `get_order_book/2` is a request-response callback and there is no request-response depth |
| **"No streaming API"** | prose, 2026-08-28 | **WRONG, and corrected.** Fifteen services. The claim was made from the OpenAPI documents alone; the Streamer is not REST and is therefore absent from them by construction |
| No enumerable catalogue | MD | **holds.** `/instruments` has no list-everything projection, so `get_symbols/1` requires a `:query` — which is declared *active*, because "needs a search term" and "has no endpoint" are different facts |
| No sandbox | prose, published 2025-10-30 | **holds as of that date.** Schwab writes that Trader API sandboxes "will be available later this year", and neither spec declares a non-production server |
| No rate-limit constant to declare | prose | **holds.** The documented order limit is per-application and per-account, set at registration — a number here would be a claim about someone else's registration |
| 23 of the portal's 24 products unreachable | portal, 2026-08-31 | **holds, and it is an entitlement boundary rather than a capture failure.** `lob-access/Status` returns 200 for Trader API - Individual and 204 for the other six visible products; navigating to a spec under any of them redirects to `/home` |

## The lesson, stated so it is not re-learned

**Check every page a vendor publishes, not the endpoint list alone.** The Streamer's absence
from two OpenAPI documents was read as absence from the venue. A specification describes the
API it describes; what it does not mention is not thereby absent.

Robinhood's package makes the same negative and it **survived** verification there — five
documentation pages, all checked, zero occurrences of `websocket`, `wss://` or `streaming`.
The difference between the two is not the claim, it is whether anyone looked.
