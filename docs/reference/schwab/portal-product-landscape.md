# Schwab Developer Portal — the product landscape, and what is reachable

**Captured 2026-08-31** from the signed-in portal, using the portal's own API rather than
its rendered pages. This file exists to answer one question that had been open since the
first capture: **how many API products does Schwab publish, and how many can this project
ever read?**

The answer is 24, 7, and 1 — and those three numbers are not the same thing.

## The three counts

| count | what it is | source |
|---|---|---|
| **24** | every product in the portal's catalogue | `portal-raw/find-products.json` |
| **7** | products this account can *see* | `portal-raw/lob-cards.json` |
| **1** | products this account is *entitled to read specs for* | `lob-access/Status/{product}` |

### 24 — the catalogue

`find-products.json` is the global catalogue. It names every line of business the portal
knows about, whether or not the signed-in user has any relationship with it:

```
Account Verification                Retail Contact Center
Account and Client Data             Retail Open Banking
Advisor Services                    Retirement Account Aggregation
Advisor Services Legacy             Retirement Plan Services
Bank Lending                        Schwab Knowledge Assistant
Crypto                              Schwab Private Enterprise LOBs
Data Aggregation Services           Schwab Retirement Technologies
Dev Portal Testing                  Tax Data
Enterprise Client Verification      Think Or Swim
Thinkorswim                         Trader API - Commercial
Trader API - Individual             Wealth Asset Management
Wealth Portfolio Management         Webhook Notifications
```

**Crypto and Thinkorswim are real products.** They appear here, and `Think Or Swim` and
`Thinkorswim` are two separate catalogue entries. Nothing in this file says what their
endpoints are — a catalogue entry is a name, not a specification.

### 7 — what this account sees

`Product/lob-cards` returns the products rendered on the signed-in **API Products** page:

| product | APIs listed | `lob-access` status |
|---|---|---|
| **Trader API - Individual** | 2 | **200 — entitled** |
| Trader API - Commercial | 3 | 204 |
| Account and Client Data | 12 | 204 |
| Advisor Services | 66 | 204 |
| Data Aggregation Services | 1 | 204 |
| Schwab Retirement Technologies | 2 | 204 |
| Tax Data | 2 | 204 |
| **total** | **88** | |

The 88 API names are captured per product under `portal-raw/categorized-api-products/`.
26 of Advisor Services' 66 are per-tenant `Schwab OpenView Gateway - {id}` instances of
one gateway, not 26 distinct APIs.

### 1 — what can actually be read

**`lob-access/Status` returns `200` for Trader API - Individual and `204` for the other
six.** `204` is not a soft signal: navigating to a spec URL under any of those products
redirects to `/home` before a single specification request is issued. Verified against
`advisor-services/details/specifications/AS Trading` and
`trader-api--commercial/details/specifications/Market Data - Commercial Production`; both
bounced.

**This is an entitlement boundary, not a capture failure.** The account holder is an
individual Schwab client, not a broker, RIA, or retirement-plan provider. The six
unreadable products are the products of *being* one of those. No credential this project
will ever hold reaches them, and Crypto and Thinkorswim are not even among the seven.

## What that means for this package

**`Trader API - Individual` is the whole addressable venue**, and both of its APIs are
already captured in full:

| API | specification | prose documentation |
|---|---|---|
| Accounts and Trading Production | `openapi/accounts-and-trading-production.openapi.json` | `documentation/accounts-and-trading-production.txt` |
| Market Data Production | `openapi/market-data-production.openapi.json` | `documentation/market-data-production.txt` |

Both were re-fetched on 2026-08-31 and **diffed against the committed copies: the endpoint
paths are identical.** The earlier capture of this product was complete and is current.

Neither API publishes release notes — `…--release-notes` returns `404` for both.

## What was actually missing, and now is not

The portal's **User Guides** section, 17 documents, had never been captured. It is not
reachable from any product page and is not part of either specification, which is why a
capture organised around products missed it entirely. It is now in `user-guides/`.

Two of the seventeen bear directly on this package:

- **`05-authenticate-with-oauth.md`** — the three-legged flow, the entities, and the token
  vocabulary. States that the refresh token is issued alongside the initial access token
  and "should be stored for later use". It does **not** state the 7-day lifetime or the
  one-time-use property; those are in the Accounts and Trading prose documentation.
- **`16-oauth-restart-vs-refresh-token.md`** — the decision table for *refresh* versus
  *restart the whole flow*. This is the document that says a compromised `refresh_token`,
  a scope change, a user revoking access, or a credentials/TFA change all require the full
  three-legged restart, while a merely expired or lost `access_token` needs only a refresh.

**That distinction is a package/host boundary question, not a detail.** `Auth.refresh/2`
handles the refresh side in-package; every condition in guide 16's restart list needs a
browser and a person, and so belongs to the host. Neither can be inferred from the
OpenAPI documents, which describe neither.

## Method, so this is re-runnable

The portal is an Angular app talking to `jfk2-api-gateway.schwab.com`, and it sends a
bearer token the page holds in memory — not in cookies, `localStorage`, or
`sessionStorage`. So the gateway cannot be called directly, and `curl` gets `403` even for
public assets. **Everything here was captured by driving the signed-in browser and reading
the app's own responses**, which is also why re-running it needs a human to sign in first.

| what | how |
|---|---|
| catalogue | `find-products.json`, from the portal's own response |
| visible products | navigate `/products`, read `Product/lob-cards` |
| APIs per product | navigate `/products/{p}`, read `Product/{p}/categorized-api-products` |
| entitlement | navigate `/products/{p}`, read the status of `lob-access/Status/{p}` |
| specification | navigate `/products/{p}/details/specifications/{api}`, read `api-specification/{api}` |
| prose documentation | same page, read `contentdelivery.schwab.com/…--documentation` |
| user guides | `/user-guides`, click each of the 17 sidebar entries |

### The specification response carries live credentials

`api-specification/{api}` returns an envelope whose `appKey` and `appSecret` are **the
signed-in account's real application credentials**. They are redacted in everything
committed here, and the committed envelopes under `portal-raw/` were verified to contain
neither before staging.

**This repository is public and git history is not retractable.** Anything re-captured
from this endpoint must be redacted before it is staged, not after it is committed.
