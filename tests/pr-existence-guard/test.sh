#!/usr/bin/env bash
# Golden test for the issue-scoped PR-existence guard (#214).
#
# The #195 incident: two sessions scaffolded `implement-issue` for the same issue under two
# DIFFERENT branch names (fix/195-ci-wiring-check-proves-a-suite-is-invoke and
# fix/195-ci-wiring-executable-mode). Step 4's branch-name resume check is keyed on an exact match,
# so it saw neither as "the same issue" and both scaffolded a PR. #214 added a fallback: ask GitHub
# whether the ISSUE already has an open PR closing it — a branch name is a guess at what a prior
# run called itself, but "does this issue already have a closing PR" doesn't depend on guessing
# right.
#
# The program under test is NOT copied here. It is EXTRACTED from the marked block inside
# skills/_shared/open-pr.md — the one home of the PR-open recipe (#635) — and run verbatim via
# `jq -f`, so the thing this suite proves green is the thing an agent pastes — same discipline as
# tests/merge-gate/test.sh (#91), which this suite is modeled on.
set -euo pipefail
cd "$(dirname "$0")/../.."

RECIPE="./skills/_shared/open-pr.md"
[ -r "$RECIPE" ] || { echo "FAIL: $RECIPE missing — nothing to extract the guard from"; exit 1; }

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
WORK=$(kit_scratch)
FIXTURES="$KIT_ROOT/tests/pr-existence-guard/fixtures"

command -v jq > /dev/null 2>&1 || {
  echo "FAIL: jq is missing — it is a \`required\` prerequisite in requirements.json, and the guard"
  echo "      this suite exercises is written in it."
  exit 1; }

FAILED=0
note_fail() { echo "FAIL: $1"; FAILED=1; }

# ------------------------------------------------------------------ 1. extract the shipped program
#
# The markers are jq comments, so they can sit inside the program without changing it, and the
# recipe stays a single pasteable block. Both are matched as fixed strings.
BEGIN_MARK='# >>> issue-scoped PR-existence guard'
END_MARK='# <<< issue-scoped PR-existence guard'

n_begin=$(grep -c -F -- "$BEGIN_MARK" "$RECIPE" || true)
n_end=$(grep -c -F -- "$END_MARK" "$RECIPE" || true)
if [ "$n_begin" != "1" ] || [ "$n_end" != "1" ]; then
  echo "FAIL: $RECIPE must carry EXACTLY ONE marked guard program"
  echo "      found $n_begin '$BEGIN_MARK' and $n_end '$END_MARK'"
  echo "      Two blocks means two homes for the guard, and a guard with two homes drifts."
  exit 1
fi

PROG="$WORK/close-filter.jq"
awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  index($0, b) { inside = 1 }
  inside       { print }
  inside && index($0, e) { exit }
' "$RECIPE" > "$PROG"

[ -s "$PROG" ] || { echo "FAIL: extracted an empty program from $RECIPE"; exit 1; }

# jq compiles the whole program before it reads any input; --arg issue "" makes this a pure parse
# check without needing a real fixture (the program references $issue, so parsing it without a
# bound $issue is itself a compile error, not just a missing-input one).
if ! jq --arg issue "" -f "$PROG" < /dev/null > /dev/null 2>"$WORK/parse.err"; then
  echo "FAIL: the extracted guard program does not compile:"
  sed 's/^/      /' "$WORK/parse.err"
  exit 1
fi

# ---------------------------------------------------------------------------------- 2. the verdicts
#
# verdict <fixture> <issue> <want-numbers> <what it pins>
# want-numbers: space-joined, sorted PR numbers the guard should return; "-" means none.
verdict() {
  local fixture="$1" issue="$2" want="$3" what="$4"
  local path="$FIXTURES/$fixture" out got
  if [ ! -r "$path" ]; then
    note_fail "$fixture — fixture missing ($what)"
    return 0
  fi
  if ! out=$(jq --arg issue "$issue" -f "$PROG" < "$path" 2>"$WORK/run.err"); then
    note_fail "$fixture — the guard program errored ($what):
$(sed 's/^/      /' "$WORK/run.err")"
    return 0
  fi
  got=$(printf '%s' "$out" | jq -r '[.[].number] | sort | map(tostring) | join(" ")')
  [ -n "$got" ] || got='-'
  if [ "$got" != "$want" ]; then
    note_fail "$fixture — $what
      want: $want
      got:  $got"
    return 0
  fi
  echo "ok: $fixture — $what"
}

# The #195 incident, reproduced exactly: two open PRs closing the same issue under two DIFFERENT
# branch names. A branch-name-keyed check would see neither as a match for the other; the guard
# must return BOTH so the "2+" path in SKILL.md Step 4 can flag the duplicate instead of silently
# scaffolding a third.
verdict 195-duplicate-different-branches.json 195 '204 205' \
  'two open PRs closing the same issue under different branch names are both found'

# The single-match shape Task 3 asks for directly: one open PR, under a branch name that does not
# match whatever a fresh run would derive, already closes the issue. The guard must find it so
# Step 4 resumes onto it instead of scaffolding a second one.
verdict 195-single-closer-different-branch.json 195 '205' \
  'a lone closing PR under an unrelated branch name is found and resumable'

# A PR that only mentions the issue must not read as closing it — the false positive the plain
# `gh pr list --search` text match alone would produce.
verdict mentions-not-closes.json 42 '-' \
  'a PR that merely mentions the issue does not count as closing it'

# The \b boundary has to hold in both directions: #420 must not match a #42 search, and a truncated
# #4 must not either.
verdict near-number-substring.json 42 '-' \
  'a longer or shorter number substring never matches the exact issue number'

# No open PRs at all — the guard must not invent a match.
verdict no-open-prs.json 42 '-' \
  'an empty PR list reduces to zero matches'

# GitHub's closing-keyword set, case-insensitive and across tense/number: FIXED, resolves, closes.
verdict mixed-keywords-case-insensitive.json 42 '60 61 62' \
  'the full closing-keyword set matches case-insensitively'

# GitHub also recognizes the colon form ("Closes: #42"), and some PRs carry no space at all
# ("Fixes:#42"). Both must still count as closing — a false negative here is what lets a
# duplicate scaffold through on a PR that really does already close the issue.
verdict colon-and-tight-spacing.json 42 '70 71' \
  'the colon form and tight spacing between keyword and number still match'

# A `null` body (a PR with no description) must not crash the whole filter, and it must not
# swallow a genuine neighbor's match either (#259).
verdict null-body.json 42 '81' \
  'a null-body PR does not crash the guard and a real neighbor still matches'

# ---------------------------------------------------------------------------------------- verdict
if [ "$FAILED" -ne 0 ]; then
  echo
  echo "pr-existence-guard: FAILED"
  exit 1
fi
echo
echo "pr-existence-guard: OK — the shipped guard program finds open closing PRs across fixtures."
