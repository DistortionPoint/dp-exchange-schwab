#!/usr/bin/env bash
# Resolves every RUNTIME dependency in mix.exs down to the exact floor version its own
# requirement string declares, then compiles and exercises the package against that
# floor — never against whatever mix.lock happens to have resolved to today.
#
# Why this exists: a `~>` requirement states ">= this version", and ordinary `mix
# deps.get` always resolves the NEWEST version satisfying that bound. A floor that is
# actually too low still compiles and passes every ordinary CI run, and only a consumer
# who resolves an older-but-still-permitted version finds out. Four real incidents
# shipped this way across this family in one week (one of them a "corrected" floor that
# was itself still wrong) — see usage-rules/adapter.md, "Dependency floors are a claim
# exactly like a capability", for the writeup and what each one was.
#
# Scope, deliberately narrow:
#
#   - Only deps declared WITHOUT `only:` — i.e. only what a consumer of this package
#     actually resolves. A dev/test-only tool (credo, dialyxir, sobelow, ex_doc,
#     usage_rules, the test-only `plug`) never reaches a consumer's dependency tree, so
#     its floor is not a claim this package makes to anyone. This is not just a scoping
#     choice: pinning credo to its own declared floor (1.7.0) during this script's design
#     failed outright — that release does not compile under Elixir 1.18 at all (a bug in
#     a years-old release of credo itself, unrelated to anything in this repository).
#     Including dev tooling would make this check permanently red for a reason that has
#     nothing to do with whether THIS package's floor is honest.
#
#   - Compile with `--warnings-as-errors`, plus the package's own AdapterContract
#     conformance test (or, for `dp_exchange_core` itself, which defines that suite
#     rather than consuming it, the full test suite) — not a blanket `mix test`. Some
#     venue packages' lower-level socket/feed tests reach the real, live venue (found in
#     `dp_exchange_coinbase`'s `feed_test.exs` while designing this check — a separate,
#     pre-existing issue, filed but deliberately not fixed here). The conformance test
#     alone already calls `capabilities/0` under a fully offline Fake, which is exactly
#     the shape of two of the four known incidents (a struct field the floor doesn't have
#     yet; a Types module the floor doesn't ship yet) without opening a socket. The other
#     two (an undefined remote function, twice) are caught by the compile step, not by
#     any test.
#
# Never modifies the real checkout — everything happens inside a throwaway copy under
# tmp/floor_check (repo-local, gitignored; never the system tmp).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$ROOT/tmp/floor_check"

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"

rsync -a \
  --exclude='_build' --exclude='deps' --exclude='cover' --exclude='doc' \
  --exclude='tmp' \
  "$ROOT/" "$SCRATCH/"

cd "$SCRATCH"

# Pin every runtime dep requirement to `== ` its own floor version. A three-part
# requirement ("~> 0.1.68") keeps its patch; a two-part one ("~> 1.4") floors its patch
# at 0. Scoped to lines that open a deps() tuple (`{:name, ...`) so the unrelated
# `elixir: "~> 1.18"` requirement in `project/0` is never touched, and skips any line
# containing `only:`, which is how a dev/test-only dep is spelled in every mix.exs in
# this family. POSIX character classes throughout ([[:space:]], not \s) — BSD sed (macOS,
# for local runs) does not understand Perl-style shorthand classes; GNU sed (CI) accepts
# both, so this stays the portable common denominator.
sed -i.bak -E '
  /^[[:space:]]*\{:[a-zA-Z_]+,/ {
    /only:/! s/"~> ([0-9]+\.[0-9]+\.[0-9]+)"/"== \1"/g
    /only:/! s/"~> ([0-9]+\.[0-9]+)"/"== \1.0"/g
  }
' mix.exs
rm -f mix.exs.bak

echo "== Runtime deps pinned to floor =="
if ! grep -n '"== ' mix.exs; then
  echo "No runtime dependency uses a '~>' requirement — nothing for this check to pin." >&2
  exit 1
fi

rm -f mix.lock
mix deps.get
mix compile --warnings-as-errors

if grep -q "app: :dp_exchange_core," mix.exs; then
  # dp_exchange_core defines AdapterContract rather than consuming it, and — unlike some
  # venues' lower-level socket/feed tests — nothing in its own suite touches a live
  # network, so the full suite is both meaningful and safe to run here.
  echo "== dp_exchange_core itself — running the full suite =="
  mix test
else
  # Anchored to the start of the line (allowing indentation) so a comment merely
  # mentioning "use DpExchange.Core.AdapterContract" is never mistaken for the real
  # invocation. Exactly one is expected per venue package; zero or more than one means
  # this script's assumption about the repo's shape no longer holds, and it should say so
  # loudly rather than silently run the wrong thing (or, with more than one match, pass a
  # broken multi-path argument to `mix test`).
  contract_test=$(grep -rl -E "^[[:space:]]*use DpExchange\.Core\.AdapterContract" test/ 2>/dev/null || true)
  match_count=$(printf '%s\n' "$contract_test" | grep -c . || true)

  if [ "$match_count" -ne 1 ]; then
    echo "Expected exactly one AdapterContract conformance test under test/, found $match_count:" >&2
    printf '%s\n' "$contract_test" >&2
    exit 1
  fi

  echo "== Running the conformance suite at floor: $contract_test =="
  mix test "$contract_test"
fi
