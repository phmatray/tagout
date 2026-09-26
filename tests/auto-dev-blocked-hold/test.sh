#!/usr/bin/env bash
# Golden test for the auto-dev BLOCKED verdict becoming a native hold (#511).
#
# A worker's `BLOCKED` report used to die with the run that paid for it: nothing wrote the
# blocker back anywhere the next `survey.sh` reads, so a re-dispatched worker re-found the same
# prerequisite or re-plan block from scratch. The fix gives the worker's final line a structured
# `BLOCKED_BY:` field (`commands/auto-dev-worker.md`) and has the supervisor write it back as a
# native hold (`skills/auto-dev/SKILL.md` Step 4) — a `blocked_by` edge for a prerequisite, an
# assignment for a re-plan — never tier-escalating either shape. This repo has no harness that
# runs `auto-dev` end-to-end, so this suite pins the textual invariants of the two rendered docs
# (the established pattern — see tests/auto-dev-worktree-field/test.sh).
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $1"; exit 1; }

WORKER_MD="$KIT/commands/auto-dev-worker.md"
SKILL_MD="$KIT/skills/auto-dev/SKILL.md"
PLAN_MD="$KIT/skills/implement-issue/references/steps/02-read-the-plan.md"
[ -f "$WORKER_MD" ] || fail "missing $WORKER_MD"
[ -f "$SKILL_MD" ] || fail "missing $SKILL_MD"
[ -f "$PLAN_MD" ] || fail "missing $PLAN_MD"

# --------------------------------------------------------------- Task 2: the worker's final line

# 1. The required final line ends in a BLOCKED_BY: field.
grep -qE '^PHASE1 \| ISSUE: .* \| BLOCKED_BY:' "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md's required final line does not end in BLOCKED_BY:"

# 2. Its grammar names all three shapes.
grep -qF '#a[,#b]' "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md's BLOCKED_BY grammar does not name #a[,#b]"
grep -qF 'replan' "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md's BLOCKED_BY grammar does not name replan"
grep -qE 'BLOCKED_BY.*none|none.*BLOCKED_BY' "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md's BLOCKED_BY grammar does not name none"

# 3. A missing field reads as none (an older worker's report).
grep -qE 'missing.{0,40}reads as `?none`?|a missing field reads as `?none`?' "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md does not say a missing BLOCKED_BY field reads as none"

# ------------------------------------------- Task 3: the supervisor writes the verdict back (AC5)

BLOCKED_BY_LINE=$(grep -n 'Reported BLOCKED with a `BLOCKED_BY:`' "$SKILL_MD" | head -1 | cut -d: -f1) || true
[ -n "$BLOCKED_BY_LINE" ] \
  || fail "SKILL.md Step 4 has no 'Reported BLOCKED with a \`BLOCKED_BY:\`' bullet"

GENERIC_LINE=$(grep -n 'Reported BLOCKED/FAILED' "$SKILL_MD" | head -1 | cut -d: -f1) || true
[ -n "$GENERIC_LINE" ] || fail "SKILL.md's generic 'Reported BLOCKED/FAILED' bullet is missing"

# (a) forbids tier escalation for it
grep -qF 'Never tier-escalate a `BLOCKED_BY` report' "$SKILL_MD" \
  || fail "AC5(a): SKILL.md does not forbid tier-escalating a BLOCKED_BY report"

# (b) names the parent-less wire-edges.sh call
grep -qF 'wire-edges.sh --repo' "$SKILL_MD" \
  || fail "AC5(b): SKILL.md does not name the wire-edges.sh call"
grep -qF 'parent-less mode' "$SKILL_MD" \
  || fail "AC5(b): SKILL.md does not say the wire-edges.sh call runs in parent-less mode"

# (c) checks each blocker is OPEN first
grep -qF 'each named issue is still OPEN' "$SKILL_MD" \
  || fail "AC5(c): SKILL.md does not check each blocker is OPEN before wiring"

# (d) names the fallback recap line
grep -qF 'this hold is good for **this run only**' "$SKILL_MD" \
  || fail "AC5(d): SKILL.md does not name the fallback recap line (held for this run only)"

# (e) routes replan to --add-assignee @me
grep -qF -- '--add-assignee @me' "$SKILL_MD" \
  || fail "AC5(e): SKILL.md does not route BLOCKED_BY: replan to --add-assignee @me"

# All five invariants sit in the BLOCKED_BY bullet, ordered before the generic bullet.
[ "$BLOCKED_BY_LINE" -lt "$GENERIC_LINE" ] \
  || fail "SKILL.md's BLOCKED_BY bullet is not ordered before the generic BLOCKED/FAILED bullet"

# The generic bullet now handles only BLOCKED_BY: none.
grep -qF 'BLOCKED_BY: none' "$SKILL_MD" \
  || fail "SKILL.md's generic bullet does not say it handles BLOCKED_BY: none"

# --------------------------------------------------------- Task 3: the state file section (AC6)

grep -qF '## Held on a prerequisite' "$SKILL_MD" \
  || fail "AC6: SKILL.md's state-file template is missing '## Held on a prerequisite'"

STEP6=$(grep -n '^## Step 6' "$SKILL_MD" | head -1 | cut -d: -f1) || true
[ -n "$STEP6" ] || fail "SKILL.md is missing a '## Step 6' heading"
if ! tail -n "+$STEP6" "$SKILL_MD" | grep -qF '## Held on a prerequisite'; then
  fail "AC6: Step 6's final summary does not mention '## Held on a prerequisite'"
fi

# ------------------------------------------------- Task 1: the read-the-plan.md BLOCKED_BY pointer

grep -qF 'BLOCKED_BY:` field rather than `none`' "$PLAN_MD" \
  || fail "02-read-the-plan.md does not name the BLOCKED_BY: field rather than none"
grep -qF 'writes it back as a hold instead of a blind re-dispatch' "$PLAN_MD" \
  || fail "02-read-the-plan.md does not say it writes back as a hold instead of a blind re-dispatch"

echo "PASS: auto-dev-blocked-hold"
