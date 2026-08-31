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
  real price. `to_exchange_symbol/1` returns `{:ok, native} | {:error, reason}` rather
  than a bare string — a transformation that cannot fail may return a string, a
  validation cannot.

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

Core with `Timeframe.nameable/0` and `max_leverage: :per_account` — both landed for this
package and not yet published. This package cannot build against Hex until Core does.
