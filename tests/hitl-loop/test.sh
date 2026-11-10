#!/usr/bin/env bash
# Golden test for the debug-issue feedback loop (#320).
#
# The skill's Phase 1 now gates hypothesising behind a command the agent has ALREADY RUN, and the
# material that says how to build one lives in three shipped artifacts plus two pointers. Each of
# them is invisible when it goes missing: a reference nothing links is a file nobody opens, a
# template nobody runs is a template that stopped working three refactors ago, an eval that is not
# in the set cannot fail, and a pointer that was dropped from merge-pr looks exactly like a pointer
# that was never needed. So this suite pins all four, by the same rule the rest of tests/ follows —
# a tool the kit ships is a tool the kit tests.
#
# Four assertions, in the order the plan for #320 names them:
#   (a) feedback-loop.md exists, credits its source, and SKILL.md links it from BOTH Phase 1 (where
#       an agent in trouble reads) and Bundled techniques (where an agent browsing reads).
#   (b) scripts/hitl-loop.template.sh actually runs with piped stdin and emits its KEY=VALUE dump —
#       the part the agent parses, and the only part a syntax-only check cannot prove.
#   (c) the eval set parses AND carries `loop-before-hypothesis`, the one eval whose expected
#       output is a command that was run rather than a theory that was formed.
#   (d) merge-pr's `fix-check` correction and implement-issue's green-wall blocker — the two places
#       the kit meets broken code unattended — each name the skill at that exact spot, not merely
#       somewhere in the file.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
SKILL_DIR="skills/debug-issue"
REFERENCE="$SKILL_DIR/feedback-loop.md"
TEMPLATE="$SKILL_DIR/scripts/hitl-loop.template.sh"
EVALS="$SKILL_DIR/evals/evals.json"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
kit_guard kit_guard_samples_unchanged

# Extract one markdown section: from the first line matching $1 up to (not including) the next
# heading at $2's level or shallower. Written with awk rather than sed -n '/x/,/y/p' because the
# range form re-arms on a second match and would concatenate two unrelated sections.
section() {
  local file="$1" start_re="$2" stop_re="$3"
  awk -v start="$start_re" -v stop="$stop_re" '
    $0 ~ start { inside = 1; print; next }
    inside && $0 ~ stop { exit }
    inside { print }
  ' "$file"
}

# ---------------------------------------------------------------- (a) the reference

[ -s "$REFERENCE" ] || {
  echo "FAIL [a/exists]: $REFERENCE is missing or empty — Phase 1 points at a file that is not there"
  exit 1; }
echo "  ok: a/exists — $REFERENCE is present"

grep -q 'mattpocock/skills' "$REFERENCE" || {
  echo "FAIL [a/credit]: $REFERENCE does not credit mattpocock/skills — the port is MIT and the"
  echo "                 attribution travels with the file, not with the PR that landed it"
  exit 1; }
echo "  ok: a/credit — the reference credits mattpocock/skills"

phase1=$(section "$SKILL_DIR/SKILL.md" '^### Phase 1' '^### Phase 2')
[ -n "$phase1" ] || { echo "FAIL [a/phase1]: no '### Phase 1' section in $SKILL_DIR/SKILL.md"; exit 1; }
grep -q 'feedback-loop\.md' <<<"$phase1" || {
  echo "FAIL [a/phase1]: Phase 1 does not link feedback-loop.md — the loop is the phase's own"
  echo "                 completion criterion, so the agent must find it from inside the phase"
  exit 1; }
echo "  ok: a/phase1 — Phase 1 links feedback-loop.md"

grep -q 'already run' <<<"$phase1" || {
  echo "FAIL [a/criterion]: Phase 1's completion criterion does not require a command ALREADY RUN."
  echo "                    'you can state what is failing' is a sentence; the criterion is a command."
  exit 1; }
echo "  ok: a/criterion — Phase 1 ends on a command already run"

bundled=$(section "$SKILL_DIR/SKILL.md" '^## Bundled techniques' '^## ')
[ -n "$bundled" ] || { echo "FAIL [a/bundled]: no '## Bundled techniques' section in $SKILL_DIR/SKILL.md"; exit 1; }
grep -q 'feedback-loop\.md' <<<"$bundled" || {
  echo "FAIL [a/bundled]: Bundled techniques does not list feedback-loop.md"; exit 1; }
grep -q 'hitl-loop\.template\.sh' <<<"$bundled" || {
  echo "FAIL [a/bundled]: Bundled techniques does not list scripts/hitl-loop.template.sh"; exit 1; }
echo "  ok: a/bundled — Bundled techniques lists the reference and the HITL template"

# ---------------------------------------------------------------- (b) the HITL template

[ -s "$TEMPLATE" ] || { echo "FAIL [b/exists]: $TEMPLATE is missing or empty"; exit 1; }
grep -q 'mattpocock/skills' "$TEMPLATE" || {
  echo "FAIL [b/credit]: $TEMPLATE does not credit mattpocock/skills"; exit 1; }

# The template is COPIED and edited, never run in place — so what is pinned here is that the
# shipped copy still works: the two helpers consume piped answers in order and the trailing dump
# is machine-parseable. Canned stdin stands in for the human.
scratch=$(kit_scratch)
out="$scratch/hitl.out"
rc=0
printf '\ny\nboom\n' | bash "$TEMPLATE" > "$out" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || {
  echo "FAIL [b/runs]: $TEMPLATE exited $rc on piped stdin; a template that cannot run"
  echo "               non-interactively cannot be driven by an agent. Output:"
  sed 's/^/        /' "$out"
  exit 1; }
grep -q '^ERRORED=y$' "$out" || {
  echo "FAIL [b/dump]: no 'ERRORED=y' line in the dump — the agent parses these lines. Output:"
  sed 's/^/        /' "$out"
  exit 1; }
grep -q '^ERROR_MSG=boom$' "$out" || {
  echo "FAIL [b/dump]: no 'ERROR_MSG=boom' line in the dump. Output:"
  sed 's/^/        /' "$out"
  exit 1; }
echo "  ok: b/runs — the HITL template consumes piped answers and prints its KEY=VALUE dump"

# ---------------------------------------------------------------- (c) the eval

[ -s "$EVALS" ] || { echo "FAIL [c/exists]: $EVALS is missing or empty"; exit 1; }
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$EVALS" || {
  echo "FAIL [c/parses]: $EVALS is not valid JSON"; exit 1; }
python3 - "$EVALS" <<'PY' || exit 1
import json, sys
data = json.load(open(sys.argv[1]))
names = [e.get("name") for e in data.get("evals", [])]
if "loop-before-hypothesis" not in names:
    print("FAIL [c/eval]: no 'loop-before-hypothesis' eval — the eval set cannot see an agent that")
    print("               hypothesises before running anything. Present: %s" % names)
    sys.exit(1)
PY
echo "  ok: c/eval — evals.json parses and carries loop-before-hypothesis"

# ---------------------------------------------------------------- (d) the two pointers

# Stops at the first BLANK line, so the window is the correction's own paragraph and nothing else.
# A window that ran to the next `^## ` would span 80-odd lines — every other correction in Step 4 —
# and would still say ok with the pointer moved into the sync or the review correction instead.
fix_check=$(section "$(kit_skill_prose "$KIT" merge-pr)" '^[*][*]Fix a red CI check[.][*][*]' '^[[:space:]]*$')
[ -n "$fix_check" ] || {
  echo "FAIL [d/merge-pr]: could not find the '**Fix a red CI check.**' correction in"
  echo "                   skills/merge-pr/SKILL.md — if it was renamed, re-point this assertion"
  echo "                   rather than dropping it."
  exit 1; }
grep -q 'debug-issue' <<<"$fix_check" || {
  echo "FAIL [d/merge-pr]: the fix-check correction does not name debug-issue. A worker"
  echo "                   staring at a red check is exactly who needs the loop."
  exit 1; }
echo "  ok: d/merge-pr — the fix-check correction points at debug-issue"

# Herestring, not a pipe into `grep -q` (#391): `grep -n` over a 700+ line file can still be
# writing when the second grep's match closes the read end, and pipefail turns that SIGPIPE into
# this check's verdict.
honest_effort=$(grep -n 'honest effort' "$(kit_skill_prose "$KIT" implement-issue)")
grep -q 'debug-issue' <<<"$honest_effort" || {
  echo "FAIL [d/implement-issue]: the Autonomy-contract green-wall bullet ('honest effort') does not"
  echo "                          name debug-issue on the same line. 'Honest effort' has to"
  echo "                          mean the loop was built, not that the fix was retried."
  exit 1; }
echo "  ok: d/implement-issue — the green-wall blocker points at debug-issue"

echo "hitl-loop golden test OK"
