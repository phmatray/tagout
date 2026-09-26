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

# ------------------------------------------------------- 3. no pointer at the guard's old home (#635)
#
# The guard moved out of implement-issue's github-mechanics.md §5. A prose pointer still sending a
# reader there reaches a section with no program in it — and every check above stays green.
rc=0
grep -rnE 'PR-existence guard.*github-mechanics\.md|github-mechanics\.md.*PR-existence guard|§5.s own .*Residual limitation' \
  "$KIT_ROOT/skills" "$KIT_ROOT/commands" > "$WORK/stale-pointers" || rc=$?
if [ "$rc" -gt 1 ]; then
  note_fail "could not scan skills/ and commands/ for stale guard pointers (grep exit $rc)"
elif [ -s "$WORK/stale-pointers" ]; then
  note_fail "a pointer still sends the issue-scoped guard to github-mechanics.md §5 — point it at skills/_shared/open-pr.md:
$(sed 's/^/      /' "$WORK/stale-pointers")"
else
  echo "ok: no pointer sends the guard to its old home in github-mechanics.md §5"
fi

# ---------------------------------------------- 4. the branch-name lookup is silent on no match (#635)
#
# §1 reads ANY output of the `gh pr list --head` lookup as "a PR is already open". `.[0]` alone
# prints `null` for a no-match `[]` — the #286 shape — and every caller would then stop forever.
# The filter is read out of the recipe and run as gh's --jq runs it (raw output).
lookup=$(grep -F 'gh pr list --head "$BRANCH"' "$RECIPE" | sed -nE "s/.*--jq '([^']*)'.*/\1/p") || true
if [ -z "$lookup" ]; then
  note_fail "no --jq filter found on the branch-name lookup in $RECIPE"
elif [ -n "$(printf '[]' | jq -r "$lookup")" ]; then
  note_fail "the branch-name lookup ('$lookup') prints output for no open PR — §1 would read it as a PR"
elif [ -z "$(printf '[{"number":7}]' | jq -r "$lookup")" ]; then
  note_fail "the branch-name lookup ('$lookup') prints nothing for an open PR"
else
  echo "ok: the branch-name lookup prints nothing on no match and the PR on a match"
fi

# ------------------------------------------------ 5. the scaffold body still closes the issue (#641)
#
# Step 5 builds the draft PR's body by hand, not through open-pr.md — its printf line is the only
# thing on a resumed run that makes the guard above (§1-§4) see the scaffold as already closing the
# issue. Nothing runs that line or feeds its output to the guard today: if "Closes #%s." were ever
# dropped, this would go undetected and a resumed run would open a second PR for the same issue.
#
# check_body_builder <step-file> <want> — extract the body builder out of <step-file>, run it for a
# fake issue, wrap the resulting body into a one-PR fixture, and run it through the SAME extracted
# guard program §1 built ($PROG). <want> is the guard's expected PR-number result; "-" means none.
check_body_builder() {
  local step_file="$1" want="$2"
  local builder body pr_list out got stepnum
  builder="$(kit_scratch)/body-builder.sh"
  sed -n "/^{ printf 'Implements #%s/,/^BODY\$/p" "$step_file" > "$builder"
  if [ ! -s "$builder" ]; then
    note_fail "no body builder found in $step_file"
    return 0
  fi
  body="$WORK/body.md"
  if ! ISSUE=4242 BODY_FILE="$body" bash "$builder"; then
    note_fail "$step_file — the extracted body builder errored"
    return 0
  fi
  pr_list=$(jq -n --rawfile b "$body" '[{number:1,headRefName:"feat/4242-x",body:$b}]')
  if ! out=$(printf '%s' "$pr_list" | jq --arg issue 4242 -f "$PROG" 2>"$WORK/body-run.err"); then
    note_fail "$step_file — the guard program errored on the scaffold body:
$(sed 's/^/      /' "$WORK/body-run.err")"
    return 0
  fi
  got=$(printf '%s' "$out" | jq -r '[.[].number] | map(tostring) | join(" ")')
  [ "$want" != - ] || want=
  if [ "$got" != "$want" ]; then
    note_fail "$step_file — scaffold body closing check
      want: ${want:--}
      got:  ${got:--}"
    return 0
  fi
  stepnum=${step_file##*/}
  stepnum=${stepnum%%-*}
  if [ -n "$want" ]; then
    echo "ok: step $stepnum's scaffold PR body closes the issue the guard searches for"
  else
    echo "ok: step $stepnum's scaffold PR body without a Closes line is not found by the guard"
  fi
}

STEP_05="$KIT_ROOT/skills/implement-issue/references/steps/05-open-the-draft-pr.md"
NO_CLOSES="$WORK/05-no-closes.md"
sed 's/Closes #%s\.//' "$STEP_05" > "$NO_CLOSES"
check_body_builder "$NO_CLOSES" -
check_body_builder "$STEP_05" 1

# ---------------------------------------------------------------------------------------- verdict
if [ "$FAILED" -ne 0 ]; then
  echo
  echo "pr-existence-guard: FAILED"
  exit 1
fi
echo
echo "pr-existence-guard: OK — the shipped guard program finds open closing PRs across fixtures."
