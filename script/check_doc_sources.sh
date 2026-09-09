#!/usr/bin/env bash
# Checks that every vendor documentation page this package CITES still resolves the way it
# did when someone read it, and reports the ones a machine cannot check at all.
#
# Why this exists, and why it is this shape rather than a changelog watcher:
#
# This family built five packages against five vendors' documentation, and then audited
# what would have caught each way that documentation turned out to be wrong. The writeup is
# in dp_exchange_core's `docs/design/closed/`, under detecting-vendor-api-change. The result
# that decided this script:
#
#   - A CHANGELOG diff — the mechanism everyone reaches for first — caught NOTHING, across
#     the whole sample. Gemini replaced the WebSocket market-data API this family's price
#     feed ran on, and searching four years of Gemini's own dated revision history finds
#     `marketdata` 0 times, `l2_updates` 0, `sunset` 0, `breaking` 0. The entire notice
#     given for replacing a venue's streaming API was its ABSENCE from the new docs site.
#
#   - What would have caught it is this: the page stopped resolving the way it used to.
#     `https://docs.gemini.com/rest-api/` — the URL the code cited — now 301s to a
#     different host. A 301 is invisible to a browser, to `curl -L`, and to a human reader;
#     it looks like a rename and is not. **A permanent redirect on a documentation URL a
#     package cites is a change notice**, because in that case it was the only one issued.
#
# So this does not diff content and does not follow redirects. It records what each cited
# URL DID — status, and redirect target if any — on the day a person read it, and reports
# any deviation from that. Content diffing was considered and rejected: vendor docs sites
# are rendered, carry build hashes and rotating banners, and would be red every week for
# reasons that are never the reason we care about. Status-and-destination is the smallest
# signal that is never noise.
#
# The `manual` class is the other half, and it is not a degraded case of the first.
# Schwab's documentation is behind a login: `developer.schwab.com` returns 403 to an
# anonymous reader, and the OpenAPI documents are fetched at runtime from a different
# origin, so even a saved page carries the outline and not the specification. No link
# check, index diff or changelog diff reaches a venue of that shape. What is available is a
# human signing in and re-capturing — so those rows are checked for *stability* (a 403 that
# stops being a 403 is itself news) and then reported with their age, and go STALE past
# @stale_days to force the re-capture rather than let a claim quietly get old. That closes
# the gap named in the design doc: capability claims carry `measured_at`, and until now
# nothing ever READ that age.
#
# What this deliberately does NOT do: touch a venue's API. Every URL here is a
# documentation site. Tier-2 tests hit live venue endpoints and must never run on a
# schedule — a venue that sees a package polling it on a timer will rate-limit or block.
# Fetching a docs page is not that, and this script must never be extended into that.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Days before a `manual` row — one no machine can verify — is reported STALE.
STALE_DAYS=180

shopt -s nullglob
MANIFESTS=("$ROOT"/docs/reference/*/doc-sources.tsv)
shopt -u nullglob

if [ ${#MANIFESTS[@]} -eq 0 ]; then
  echo "No docs/reference/*/doc-sources.tsv found — nothing to check."
  echo "A package that cites vendor documentation should carry one; see this script's header."
  exit 0
fi

# GNU date parses `-d <date>`; BSD date (macOS, where this is written and run by hand)
# needs `-j -f <fmt>`. Probe once rather than branching on `uname`, which is wrong on a
# mac with GNU coreutils installed.
if date -d "2000-01-01" +%s >/dev/null 2>&1; then
  to_epoch() { date -d "$1" +%s; }
else
  to_epoch() { date -j -f "%Y-%m-%d" "$1" +%s; }
fi

NOW=$(date +%s)
failures=0
checked=0

for manifest in "${MANIFESTS[@]}"; do
  echo "== ${manifest#"$ROOT"/}"

  # IFS is set per-read so leading/trailing spaces inside a field survive; `|| [ -n "$url" ]`
  # so a final line without a trailing newline is still processed.
  while IFS=$'\t' read -r url expect_status expect_location observed_on class note || [ -n "${url:-}" ]; do
    case "$url" in ''|'#'*) continue ;; esac
    checked=$((checked + 1))

    # `-` means "no redirect". A literal empty field cannot be used: TAB is IFS
    # WHITESPACE, so bash collapses a run of tabs into ONE delimiter and every
    # column after an empty one silently shifts left. That is not hypothetical —
    # the first draft of this manifest used empty fields and reported all seven
    # rows as changed, because `observed_on` had landed in `expect_location`. A
    # checker that cries wolf on its first run is worse than no checker.
    if [ "$expect_location" = "-" ]; then expect_location=""; fi

    # No -L: the redirect IS the signal, so it must not be followed away. Two attempts,
    # because a single transient failure on a weekly job is not evidence of rot.
    read -r got_status got_location <<<"$(
      curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 25 "$url" 2>/dev/null \
        || curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 25 "$url" 2>/dev/null \
        || echo '000 '
    )"
    got_location="${got_location:-}"

    if [ "$got_status" != "$expect_status" ]; then
      echo "  CHANGED  status $expect_status -> $got_status   $url"
      if [ -n "$note" ]; then echo "           recorded $observed_on: $note"; fi
      failures=$((failures + 1))
      continue
    fi

    if [ "$got_location" != "$expect_location" ]; then
      echo "  CHANGED  redirect target moved   $url"
      echo "           was: ${expect_location:-<none>}"
      echo "           now: ${got_location:-<none>}"
      failures=$((failures + 1))
      continue
    fi

    if [ "$class" = "manual" ]; then
      age=$(( (NOW - $(to_epoch "$observed_on")) / 86400 ))
      if [ "$age" -gt "$STALE_DAYS" ]; then
        echo "  STALE    $age days since a human last read this ($observed_on)   $url"
        echo "           No machine can verify this page — sign in, re-capture, update the row."
        failures=$((failures + 1))
      else
        echo "  MANUAL   $got_status, unverifiable by machine; read $observed_on ($age days ago)   $url"
      fi
      continue
    fi

    echo "  OK       $got_status   $url"
  done < "$manifest"
done

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures of $checked cited documentation sources changed or went stale."
  echo
  echo "This is a NOTICE, not a build failure — nothing here blocks a merge or a release."
  echo "A changed row means a vendor moved something a package cites. Read the page, decide"
  echo "whether what this package CLAIMS about the venue is still true, fix it if not, and"
  echo "then update the row with what you observed and today's date. Do not update the row"
  echo "first: the row is a record of what someone read, and rewriting it to match a fetch"
  echo "nobody looked at turns this check into a rubber stamp."
  exit 1
fi

echo "All $checked cited documentation sources resolve as recorded."
