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
SKILL_MD="$(kit_skill_prose "$KIT" auto-dev)"   # router + references/steps/*.md
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
# A here-string, not a pipe (#391): `grep -q` exits on its first match, and a `tail` still writing
# then dies of SIGPIPE, which `pipefail` reports as this assertion failing — measured once in a
# parallel run of the whole plan, on a suite that passes alone.
if ! grep -qF '## Held on a prerequisite' <<<"$(tail -n "+$STEP6" "$SKILL_MD")"; then
  fail "AC6: Step 6's final summary does not mention '## Held on a prerequisite'"
fi

# ------------------------------------------------- Task 1: the read-the-plan.md BLOCKED_BY pointer

grep -qF 'BLOCKED_BY:` field rather than `none`' "$PLAN_MD" \
  || fail "02-read-the-plan.md does not name the BLOCKED_BY: field rather than none"
grep -qF 'writes it back as a hold instead of a blind re-dispatch' "$PLAN_MD" \
  || fail "02-read-the-plan.md does not say it writes back as a hold instead of a blind re-dispatch"

# ------------------------------------- #694: a one-way-door PR is held for the owner, never landed

door=$(sed -n '/<!-- one-way-door-hold:start -->/,/<!-- one-way-door-hold:end -->/p' "$SKILL_MD")
[ -n "$door" ] || fail "AC3: SKILL.md carries no one-way-door-hold block"
for want in 'gh pr view' '### One-way door' 'no phase-2 dispatch' 'retire the slot' '## Held for owner' '/merge-pr #'; do
  grep -qF -- "$want" <<<"$door" || fail "AC3: one-way-door-hold block does not name: $want"
done
grep -qF '## Held for owner' <<<"$(sed -n '/^```markdown/,/^```/p' "$SKILL_MD")" \
  || fail "AC3: the state-file template has no '## Held for owner' section"
step6=$(tail -n "+$STEP6" "$SKILL_MD")
grep -qF '## Held for owner' <<<"$step6" \
  || fail "AC3: Step 6's final summary does not name the '## Held for owner' entries"

# ---------------------- opt-in `Merge approval: owner`: every PR is held for the owner, never landed

owner=$(sed -n '/<!-- owner-approval-hold:start -->/,/<!-- owner-approval-hold:end -->/p' "$SKILL_MD")
[ -n "$owner" ] || fail "owner-approval: SKILL.md carries no owner-approval-hold block"
for want in 'decide.sh merge.approval' 'repo-profile.sh show' 'no phase-2 dispatch' 'retire the slot' \
            '## Held for owner' 'owner approval (profile)' '/merge-pr #' 'No verdict is a `hold` too' \
            'unrecognised-value' 'deliver-issue'; do
  grep -qF -- "$want" <<<"$owner" || fail "owner-approval: owner-approval-hold block does not name: $want"
done
# The block INVOKES the decision and may not restate it: the values the program accepts live in
# merge-approval.sh, and a sentence here saying which spellings land is the second home that
# let "any other value = unattended" merge with no human.
if grep -qiE 'absent, .unattended., or any other value' <<<"$owner"; then
  fail "owner-approval: the block restates which values land instead of asking merge.approval"
fi
# deliver-issue is the second place an agent merges with nobody watching (its Step 5): it asks too.
DELIVER_MD="$KIT/skills/deliver-issue/SKILL.md"
step5=$(sed -n '/^## Step 5 /,/^## Step 6 /p' "$DELIVER_MD")
for want in 'decide.sh merge.approval' 'dispatch nothing' '/merge-pr #'; do
  grep -qF -- "$want" <<<"$step5" || fail "owner-approval: deliver-issue Step 5 does not name: $want"
done
# A refresh must not silently drop the owner's decision.
GEN_MD="$KIT/skills/init/references/generating.md"
gen_row=$(grep -F '**Merge approval**' "$GEN_MD") \
  || fail "owner-approval: generating.md has no Merge approval row"
grep -qF 'verbatim' <<<"$gen_row" \
  || fail "owner-approval: generating.md does not say a refresh carries the Merge approval bullet over verbatim"
grep -qF '<!-- one-way-door-hold:start -->' "$SKILL_MD" \
  || fail "owner-approval: the one-way-door-hold block is gone"
grep -qF -- '— owner approval (profile)' <<<"$(sed -n '/^```markdown/,/^```/p' "$SKILL_MD")" \
  || fail "owner-approval: the state-file template lacks the 'owner approval (profile)' held form"
PROFILE_TPL="$KIT/skills/init/references/profile-template.md"
[ -f "$PROFILE_TPL" ] || fail "missing $PROFILE_TPL"
merge_approval=$(grep -F '**Merge approval:**' "$PROFILE_TPL") \
  || fail "owner-approval: the profile template has no '**Merge approval:**' bullet"
for want in 'unattended' 'owner'; do
  grep -qF -- "$want" <<<"$merge_approval" || fail "owner-approval: profile template bullet does not name: $want"
done

echo "PASS: auto-dev-blocked-hold"
