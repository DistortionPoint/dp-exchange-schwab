# CLAUDE.md

Guidance for Claude Code working in this repository.

**ABSOLUTE RULES**:
***THIS IS ELIXIR. It is Functional, Parallel, and Concurrent. You CAN NOT treat this like Python, Ruby, or Javascript.
1. ALL operations MUST be concurrent/parallel in a single message
2. Prefer Agents over MCPs
3. **NEVER save working files, text/mds and tests to the root folder**
4. ALWAYS organize files in appropriate subdirectories
5. ALWAYS do CI Checks before COMMIT
6. NEVER COMMIT OR PUSH without confirmation
7. MANAGE YOUR CONTEXT
8. ALL TESTS MUST PASS — 0 failures allowed
9. ALL Credo issues must pass. Not just some, not just critical, ALL
10. NEVER USE PERL or PYTHON
11. NEVER USE the SYSTEM TMP. NEVER MEANS NEVER. DO NOT EVER DO THIS
12. NEVER REWRITE SHARED GIT HISTORY — no force-push, no rewriting a pushed branch, no
    `git reset --hard` over work you did not create. Ordinary git IS allowed and expected.
    Rule 6 is the gate on commit and push, and it is the only gate.
13. NEVER USE KILL/PKILL UNSCOPED, only scoped to your specific things. NEVER MEANS NEVER. DO NOT EVER DO THIS

**THIS REPO IS PUBLIC.** Every commit is a public commit, and git history is not
retractable. Verify `.gitignore` covers `.env*` (except `.env.sample`) and `.mcp.json`
before anything is staged. A leaked credential is not fixed by a later commit.

## Project Overview

`dp_exchange_schwab` is the Charles Schwab venue package for the **DpExchange** family. It
depends on `dp_exchange_core` for the contract, the value types and the conformance suite,
and shares the `DpExchange.*` namespace that Core owns.

**Status: EXPERIMENTAL, and here that is structural rather than temporary.** Every endpoint
requires OAuth credentials this repository must never hold, and **Schwab publishes no
sandbox** — its own documentation promises Trader API sandboxes "later this year", and
neither specification declares a non-production server. There is nowhere to exercise this
package that is not somebody's real money, so no endpoint here can reach `:proven` from
inside this repo. That happens when a consumer trades live.

## What makes this venue different from the rest of the family

Four things. Each is load-bearing, and each is the reason for some piece of code that would
otherwise look like over-engineering.

**A symbol is one instrument, not a pair.** Every other package normalises `BASE-QUOTE`.
Here `AAPL` names a single security and the quote currency is USD because the venue is a US
broker. `SymbolFormat` is therefore mostly a *refusal*, and `to_exchange_symbol/1` is split
from `validate/1` on purpose: `Core.SymbolNormalizer` requires the first to be total, while
callers about to spend a request need the second.

The danger is specific. `BTC`, `ETH` and `SOL` are all real listed equity tickers. A
misrouted crypto pair has a **plausible wrong answer** waiting for it — an ETF holding
nothing like the coin, quoted in dollars, indistinguishable downstream from a real price.

**The market closes.** This is the only venue in the family where a feed delivering nothing
is usually correct. `market_status/1` is answered from `/markets` and never assumed;
guessing `:open` would make a real outage indistinguishable from a Saturday. The feed does
*not* stop itself when the market closes — pausing would make "closed" and "crashed" look
the same from outside, and pre/post-market are real trading windows.

**Credentials rotate, and the rotation is destructive.** The access token lives 30 minutes
and `Auth.refresh/2` renews it in-package. The refresh token is **one-time use**: every
refresh spends the old one and returns a replacement carrying a fresh seven days. Three
things follow, and the code enforces all three:

- A success with no replacement token is an **error**, not a token to keep.
- A refresh is **never retried** — it is at-most-once, and `:retry_attempts` is dropped
  from the caller's options rather than defaulted, so it cannot be switched back on.
- The result must be persisted before use. Losing it costs the grant.

**There is no venue rate-limit constant.** Schwab's documented ceiling is `0..120` order
writes per minute *per account*, set *per application at registration*. Reads are
unthrottled. So `capabilities/0` declares `authenticated_ceiling: nil` — a number there
would be a claim about somebody else's registration — and the limiter is configured from
options instead. Zero is a legal registration value and is **not** the same as
`:unsupported`.

## Where the facts come from

Every claim this package makes about Schwab comes from **Schwab's own two OpenAPI documents
and the portal's Documentation tab**, committed verbatim to `docs/reference/schwab/`. The
portal returns `403` to an anonymous reader and publishes no specification anywhere, so —
unlike every other venue in the family — **this reference cannot be re-fetched**. It has to
travel with the code, and it does.

`docs/reference/schwab/spec-facts.md` names the schema or parameter behind every declared
value. When a declaration changes, that file is what it must be checked against.

**Re-capturing carries a security hazard.** The portal's `api-specification` response
returns the signed-in account's live `appKey` and `appSecret` alongside the spec, because
that endpoint also feeds the "Try it" console. They are redacted in `portal-raw/`. **Redact
again before anything is staged** — this repository is public.

## The refusals, and why each one exists

This package refuses in more places than the crypto venues do, and every refusal is a place
where a *plausible wrong answer* was available:

| Refusal | The wrong answer it prevents |
|---|---|
| `{:not_an_equity_symbol, sym}` | a crypto pair resolving to a same-named ETF |
| `{:lookback_exceeds_venue, …}` | ten days of minutes, or a year of dailies, silently substituted for a year of minutes |
| `{:unsupported_timeframe, tf}` | the nearest width standing in for the one asked for |
| `{:query_required, :schwab}` | an arbitrary search result that looks like a catalogue |
| `{:missing_account_hash, …}` | an order placed against a silently-chosen account |
| `{:instruction_not_valid_for_asset, …}` | a throttled order write spent on a documented rejection |
| `:missing_venue_timestamp` | the local clock standing in for the venue's |
| `:unexpected_response_shape` on an untyped account | a margin account read as cash, reporting no buying power for one that has it |

Adding a fallback to any of these is a regression, however reasonable it looks in isolation.

## Essential Commands

```bash
mix deps.get
mix test                # 0 failures, always
mix test --cover        # threshold 90
mix format
mix quality             # format --check-formatted + credo --strict + dialyzer + sobelow
```

## Testing

Tier 1 (in-process fakes) is all that runs unattended, and here it is all that *can* run:
there is no sandbox and no anonymous endpoint, so tiers 2 and 3 have nowhere to point until
a credential-holding consumer runs them.

`DpExchange.Schwab.Fake` must **refuse what the real venue refuses**. A fake that answers
where the real one would refuse lets a consumer's suite go green against behaviour that
cannot happen, which is worse than having no fake. It is also the only place in the family
where the closed-market path is testable.

Tests must be `async: true` safe. Configuration seams resolve through `Core.Config`, which
is process-scoped, so two async tests can want the same fake to behave differently.

## Layout

```
lib/dp_exchange/schwab.ex              the facade — the only public surface
lib/dp_exchange/schwab/auth.ex         signing and token refresh
lib/dp_exchange/schwab/capabilities.ex the declaration, derived before any provider code
lib/dp_exchange/schwab/rest.ex         both servers: /marketdata/v1 and /trader/v1
lib/dp_exchange/schwab/orders.ex       order construction and the published instruction matrix
lib/dp_exchange/schwab/symbol_format.ex translation (total) and validation (refusing)
lib/dp_exchange/schwab/feed.ex         a REST poll behind Core.PollingFeed
lib/dp_exchange/schwab/supervisor.ex   limiter + feed
lib/dp_exchange/schwab/fake.ex         in-process stand-in for consumers
docs/reference/schwab/                 Schwab's own documentation, committed verbatim
```

Everything except `schwab.ex` is internal. A consumer that reaches past the facade has found
a gap in it — fix the facade, do not document the workaround.

## Definition of "Done"

- Tests written and passing, 0 failures
- `mix quality` clean
- Coverage at or above 90
- Public functions documented with `@doc` and `@spec`
- CHANGELOG entry where behaviour changed
- Any claim about the venue traceable to `docs/reference/schwab/`
