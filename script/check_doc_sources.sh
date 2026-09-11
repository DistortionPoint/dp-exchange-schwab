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

# ---------------------------------------------------------------------------
# Is the manifest COMPLETE? Everything above verifies what is listed; nothing
# verified that the list covers what this package's reference docs actually cite.
#
# That gap was real and this check is what found it: `dp_exchange_gemini` cited 22 distinct
# URLs across `docs/reference/` and listed 12, so two genuine documentation pages —
# `specs/openapi/prediction-markets.yaml` and `websocket/introduction` — were never checked
# by anything. A checker whose coverage nobody verifies reports "all sources resolve" while
# saying nothing about the sources it was never told about.
#
# Two classes, reported separately, because only one of them can be judged mechanically:
#
#   UNLISTED — cited on a host the manifest ALREADY names as documentation. Same vendor,
#              same docs site, different page. Near-certainly a documentation source that
#              belongs in the manifest.
#
#   UNKNOWN  — cited on a host the manifest does not name at all. Deliberately NOT assumed
#              to be documentation, because most of them are not: `api.gemini.com`,
#              `exchange.gemini.com`, `api.sandbox.webull.com` are API hosts, and adding one
#              to this manifest would put a venue's live API into a WEEKLY SCHEDULED FETCH.
#              D7 is explicit that a venue seeing a package poll it on a timer will
#              rate-limit or block, and that tier-2 traffic is for a human choosing to run
#              it. So these are listed for a person to classify, never auto-added.
#
# Non-blocking like the rest of this script: it prints and does not change the exit code.
# An unlisted page is a gap in evidence, not a broken build.
echo
echo "== manifest coverage"

doc_hosts=$(
  awk -F'\t' 'NR > 1 && $1 ~ /^http/ { print $1 }' docs/reference/*/doc-sources.tsv 2>/dev/null |
    sed -E 's#^https?://([^/]+).*#\1#' | sort -u
)

listed_urls=$(
  awk -F'\t' 'NR > 1 && $1 ~ /^http/ { print $1 }' docs/reference/*/doc-sources.tsv 2>/dev/null |
    sort -u
)

# `[^ )"'\''`,>]` stops at the punctuation that ends a URL in prose and in Markdown links.
# Trailing `.`/`,`/`)` are stripped after, since a URL at the end of a sentence keeps one.
cited_urls=$(
  cat docs/reference/*/*.md 2>/dev/null |
    grep -ohE 'https?://[^ )"'\''`,>]+' | sed 's/[.,)]*$//' | sort -u
)

unlisted=0
unknown=0

for url in $cited_urls; do
  if printf '%s\n' "$listed_urls" | grep -qxF "$url"; then continue; fi

  host=$(printf '%s' "$url" | sed -E 's#^https?://([^/]+).*#\1#')

  if printf '%s\n' "$doc_hosts" | grep -qxF "$host"; then
    echo "  UNLISTED cited in docs/reference, absent from the manifest   $url"
    unlisted=$((unlisted + 1))
  else
    echo "  UNKNOWN  cited on a host the manifest does not name          $url"
    unknown=$((unknown + 1))
  fi
done

if [ "$unlisted" -eq 0 ] && [ "$unknown" -eq 0 ]; then
  echo "  Every URL cited in docs/reference is accounted for."
else
  echo
  echo "  $unlisted unlisted, $unknown on unknown hosts. Neither fails this run."
  echo "  UNLISTED: read the page, then add a row recording what it did and the date."
  echo "  UNKNOWN:  classify it. A documentation page gets a row; a venue API host gets"
  echo "            NONE — putting one here would schedule a weekly fetch against a live"
  echo "            venue, which is exactly what D7 forbids."
fi


# ---------------------------------------------------------------------------
# How old is this package's own claim about the venue?
#
# `capabilities/0` carries `measured_at` and `measured_against` because CLAUDE.md is
# explicit: "Declare what you measured, not what you assume. If it was measured, say when
# and against what." Every venue in this family populates both.
#
# **Nothing read them.** Not this script, not a test, not a line of consumer documentation —
# the five `usage-rules.md` files, which are what a consuming agent actually reads, did not
# mention the field at all. A provenance stamp nobody reads is the same shape as the MANUAL
# rows above before they were aged: a claim that quietly gets old while still reading as
# current, which is the failure this whole script exists for one category across.
#
# Reported, never enforced. A capability measurement going stale is not a build failure — it
# is a venue that has not been re-checked, and the only thing that can fix it is a person
# re-measuring and updating the date. Failing the build would just teach everyone to ignore
# it, which is the same argument this script's header already makes about per-push checks.
echo
echo "== capability provenance"

measured_at=$(
  grep -rhoE 'measured_at: ~D\[[0-9]{4}-[0-9]{2}-[0-9]{2}\]' lib 2>/dev/null |
    grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort | head -1 || true
)

# `measured_against` is detected by PRESENCE, and the first line of its value is shown rather
# than the whole thing.
#
# The obvious version — grep out `measured_against: "..."` on one line — is wrong here and
# was written that way first. Every venue in this family states this field as a multi-line
# `<>` concatenation, because the honest answer is a paragraph: which documents, which
# endpoints, measured live or read from a page. A single-line grep matches none of them and
# reports MISSING on all five, forever, while every one of them is correctly populated.
#
# That false negative is worth the comment because it is the same mistake twice: the first
# read of these venues concluded the field was unset family-wide, and nearly replaced five
# accurate provenance statements — including `dp_exchange_gemini`'s, which records timeframes
# measured LIVE against api.gemini.com — with a flat "not probed against the live API". A
# checker that cannot see a value is not evidence the value is absent.
measured_against_line=$(
  grep -rn 'measured_against:' lib 2>/dev/null | grep -v 'measured_against: nil' | head -1
)
if [ -z "$measured_at" ]; then
  echo "  MISSING  capabilities/0 declares no measured_at — an unlabelled claim is worse"
  echo "           than a missing one. See CLAUDE.md, \"Declare what you measured\"."
else
  caps_age=$(( (NOW - $(to_epoch "$measured_at")) / 86400 ))

  if [ "$caps_age" -gt "$STALE_DAYS" ]; then
    echo "  STALE    capabilities/0 was measured $caps_age days ago ($measured_at)"
    echo "           Re-measure against the venue and update both fields. A declaration is a"
    echo "           claim about a real venue, and this one has not been checked since."
  else
    echo "  OK       capabilities/0 measured $measured_at ($caps_age days ago)"
  fi
fi

# Half the rule is not the rule. CLAUDE.md asks for when AND against what, and an unlabelled
# claim is worse than a missing one — a date with no subject reads as provenance while saying
# nothing about what was actually examined.
#
# Reported as a POINTER rather than quoted. These statements run to a paragraph apiece and
# say which documents, which endpoints, and whether a figure was measured live or read from a
# page; excerpting a line of that in a weekly notice would be worse than useless, because the
# clause that matters is rarely the first one. A file and line is what a person can follow.
if [ -z "$measured_against_line" ]; then
  echo "  MISSING  measured_against is not set — the date says WHEN, nothing says AGAINST"
  echo "           WHAT. Name the evidence: the vendor documentation, a live probe, a"
  echo "           sandbox. See CLAUDE.md, \"Declare what you measured\"."
else
  echo "  OK       measured_against stated at ${measured_against_line%%:*}:$(
    printf %s "$measured_against_line" | cut -d: -f2
  )"
fi

echo "All $checked cited documentation sources resolve as recorded."
