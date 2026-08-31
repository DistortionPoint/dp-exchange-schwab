# Schwab Developer Portal — User Guides

**17 documents, captured 2026-08-31** from the signed-in portal at
`developer.schwab.com/user-guides`.

These had never been captured. They are not reachable from any product page and are not
part of either OpenAPI document, so a capture organised around API products misses them
entirely — which is what happened the first time.

| # | guide | why it matters here |
|---|---|---|
| 01 | Introduction | portal onboarding overview |
| 02 | User Registration | account creation |
| 03 | How API Products are Organized | **the product / LOB / app model** — see `../portal-product-landscape.md` |
| 04 | Requesting Product Access | how entitlement is granted; why 6 of 7 products read `204` |
| 05 | **Authenticate with OAuth** | **three-legged flow, entities, token vocabulary** |
| 06–09 | 3rd Party Company | company roles and profiles — not applicable to an individual developer |
| 10–11 | Individual Developer | **the role this project's account holds** |
| 12 | Create an App | where `appKey`/`appSecret` come from |
| 13 | Modify an App | |
| 14 | Test in Sandbox | which products have a lower environment |
| 15 | Promoting Apps to Production | |
| 16 | **OAuth Restart vs. Refresh Token** | **the refresh-vs-restart decision table** |
| 17 | App Callback URL Requirements | HTTPS-only, 255 characters, comma-separated |

## The two that carry design weight

**05** establishes that the refresh token arrives with the initial access token and must be
stored. It does **not** give the 7-day lifetime or the one-time-use rule — those are in
`../documentation/accounts-and-trading-production.txt`.

**16** is the document that draws this package's auth boundary. Refresh handles an expired
or lost `access_token`. A full three-legged restart is required when the `refresh_token` is
compromised, a new scope is needed, different accounts must be authorised, the user revokes
access, or credentials/TFA change. Every restart condition needs a browser and a person, so
it is the host's; the refresh path is the package's, and is what `Auth.refresh/2` implements.

Captured as text. The portal renders these from the Angular bundle rather than an API, so
there is no JSON form to keep alongside them.
