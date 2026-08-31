# Schwab Trader API — captured reference

Everything the Schwab Developer Portal serves for **Trader API – Individual**, captured
2026-08-28 from an authenticated session and committed here so that nobody has to log in
again to read it.

Schwab's documentation is behind a login. `developer.schwab.com` returns `403` to an
anonymous reader and there is no public OpenAPI document anywhere. That is the whole
reason these files are in the repository rather than linked: this reference has to be
checkable against a fixed source, so the source travels with it.

## The two sets

Schwab splits Trader API – Individual into two API products. Both are here in full.

| Product | Server | Surface |
|---|---|---|
| **Market Data Production** | `https://api.schwabapi.com/marketdata/v1` | 10 GETs across 10 paths |
| **Accounts and Trading Production** | `https://api.schwabapi.com/trader/v1` | 13 operations across 10 paths |

The portal's *internal* name for the second one is `Retail Trader API Production`;
`Accounts and Trading Production` is the display name and the one the architect uses.
Both names appear in the raw captures, and they are the same product —
`portal-raw/accounts-and-trading-production.product-details.json` shows the mapping.

## What is here

```
README.md                        this file
spec-facts.md                    the values derived from the specs, with the line that says each
endpoint-inventory.md            the endpoint list, with what it settles about the contract

openapi/
  market-data-production.openapi.json           OpenAPI 3.0.3, 172 KB, unwrapped and pretty-printed
  accounts-and-trading-production.openapi.json  OpenAPI 3.0.1,  99 KB, unwrapped and pretty-printed

documentation/
  market-data-production.{html,txt}             the portal's "Documentation" tab, 90 KB
  accounts-and-trading-production.{html,txt}    the portal's "Documentation" tab, 27 KB

portal-raw/                      the portal's responses, verbatim except for two redactions (see below)
  *.spec-envelope.json           the api-specification response; `.specification` is the OpenAPI doc as a string
  *.documentation.json           the CMS asset; `.[].body` is the HTML
  *.product-details.json         display name, description, app limit
  find-products.json             every API product Schwab publishes, not just this one

portal-capture/                  the architect's saved-page captures from before the login
```

`openapi/*.json` are the *unwrapped* documents: the portal wraps its OpenAPI text inside a
JSON envelope as a string field, and these are that string, parsed and pretty-printed. The
envelope is kept in `portal-raw/` so the unwrapping can be checked.

The `.txt` documentation files are reading copies. Schwab's own HTML is double-encoded in
nine places (`â€™` where `'` was meant); the `.html` files keep that verbatim and only the
`.txt` files are repaired.

## Re-capturing

The portal is an Angular app whose Swagger UI fetches its spec at runtime, so saving the
page gets the outline and not the spec. From an authenticated browser session, the four
requests worth keeping per product are:

```
GET .../api/v1/api-specification/{ProductName}          the OpenAPI envelope
GET .../api/v1/Product/api-product-details?apiProductName={ProductName}
GET .../api/v1/Product/find-products                    all products
GET https://contentdelivery.schwab.com/api/content/rtcontent/asset/{slug}--trader-api--individual--documentation
```

where `{ProductName}` is `Market Data Production` or `Retail Trader API Production`, and
`{slug}` is `market-data-production` or `retail-trader-api-production`. A page-context
`fetch()` will not work — `jfk2-api-gateway.schwab.com` is a different origin and CORS
blocks it. Read the response bodies from the network log instead.

## One thing worth noticing beyond this package

`find-products.json` lists 24 API products. Two are relevant later and neither is this one:
**Crypto**, and **Thinkorswim** — the latter being where a streaming quote surface would
live if Schwab has one. Nothing here has been checked against either; they are noted
because a reader looking for a Schwab websocket will not find it in these two specs, and
should know where to look next rather than concluding it does not exist.

## The one thing that was removed

The `api-specification` response carries `appKey` and `appSecret` alongside the spec — the
**live credentials of whichever developer app the signed-in account owns**. They are not
part of the API description; the portal ships them because the same endpoint feeds the
"Try it" console.

Both are replaced with `[REDACTED — app credential, never committed]` in
`portal-raw/*.spec-envelope.json`. That is the only edit made to any captured file, and it
is recorded here because the rest of this directory is worth trusting as verbatim and the
exception has to be visible.

**If you re-capture, redact again before anything is staged.** This repository is public
and git history is not retractable. The unwrapped `openapi/*.json` never contained them —
they live in the envelope, not in the spec — so the redaction only touches `portal-raw/`.
