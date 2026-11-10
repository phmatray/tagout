#!/usr/bin/env bash
# Golden test for auto-dev's two counted cost budgets (#270, folding #272, #522).
#
# A measured 19-merge fleet run cost $639 list-equivalent, and it was skewed at BOTH ends:
#   * the orchestrator was ONE session and 33% of the bill, and it never compacted once, because
#     the cadence in force ("~40-50% of the window, or every ~20 merges") could not fire inside a
#     19-merge run at all;
#   * the top 3 of 37 worker sessions were 32% of all worker cost, and the worst was an
#     `effort: medium` issue on the mid tier — neither its label nor its tier predicted it.
#
# #270 answered the first with a counted cadence that told the supervisor to run `/compact` itself —
# but no model has a tool that runs a built-in slash command (#522), so that rule could never fire on
# purpose either. The fix bounds the supervisor through the mechanism the harness actually runs
# unattended: its own auto-compact threshold (`autoCompactWindow`). Both budgets are still DECLARED IN
# ONE FILE — skills/auto-dev/references/token-economics.md — and every other document cites that
# section instead of carrying a number of its own. This suite exists because a figure restated in two
# documents is a figure that drifts: the old "~20 merges" cadence sat in Token economics lever 5 AND
# again in Step 4, and both copies were wrong together.
#
# What is pinned here:
#   1. the reference declares each integer exactly once, in a fixed, greppable form;
#   2. neither SKILL.md nor commands/auto-dev-worker.md RESTATES either integer, and SKILL.md carries
#      no backticked compact command — no model can run one;
#   3. both documents cite the section that owns them, and that section exists;
#   4. the `PARTIAL` contract is spelled the same on both sides of the hand-off — the worker's
#      report enum and the supervisor's Step 4 handling — including the two rules that make it
#      safe: a green tree, and a FRESH dispatch rather than a SendMessage;
#   5. the state file no longer carries a `last compacted @` counter — nothing computes from one any
#      more — and Step 1 reads the effective context bound instead.
#
# Reads only files under commands/ and skills/auto-dev/ — never samples/ — so no kit_guard is needed.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $1"; exit 1; }

REF="$KIT/skills/auto-dev/references/token-economics.md"
SKILL_MD="$(kit_skill_prose "$KIT" auto-dev)"   # router + references/steps/*.md
WORKER_MD="$KIT/commands/auto-dev-worker.md"
for f in "$REF" "$SKILL_MD" "$WORKER_MD"; do
  [ -f "$f" ] || fail "missing $f"
done

# ---------------------------------------------------------------- 1. one home, one declaration
# The declarations are deliberately shouty and fixed-shape. A prose sentence would be unpinnable:
# the point of this suite is that a reader (or an agent) can find the ONE place a number lives.
bound_decl=$(grep -cE '^- \*\*CONTEXT BOUND = autoCompactWindow [0-9]+\.\*\*' "$REF" || true)
[ "$bound_decl" = "1" ] \
  || fail "token-economics.md must declare the context bound exactly once as '- **CONTEXT BOUND = autoCompactWindow <n>.**' (found $bound_decl)"

budget_decl=$(grep -cE '^- \*\*WORKER TURN BUDGET = [0-9]+ turns\.\*\*' "$REF" || true)
[ "$budget_decl" = "1" ] \
  || fail "token-economics.md must declare the worker turn budget exactly once as '- **WORKER TURN BUDGET = <n> turns.**' (found $budget_decl)"

BOUND=$(grep -E '^- \*\*CONTEXT BOUND = autoCompactWindow [0-9]+\.\*\*' "$REF" | sed -E 's/.*autoCompactWindow ([0-9]+).*/\1/')
BUDGET=$(grep -E '^- \*\*WORKER TURN BUDGET = [0-9]+ turns\.\*\*' "$REF" | sed -E 's/.*= ([0-9]+) turns.*/\1/')
[ -n "$BOUND" ]  || fail "could not read the context bound out of $REF"
[ -n "$BUDGET" ]  || fail "could not read the worker turn budget out of $REF"

# The third budget (#548) declared the same shouty, fixed-shape way, so it can be read back and
# cross-checked against the ONE consumer that actually needs the number as a running value:
# hooks/autodev-stop-gate.sh's SUPERVISED_MINUTES constant. Unlike CONTEXT BOUND/WORKER TURN
# BUDGET (prose-only outside this file), this one has a real second copy by necessity — the hook
# cannot read a markdown file at Stop-hook time — so "declared once" here means "the code copy
# matches the declared source", checked by comparing the two integers, not by forbidding the copy.
window_decl=$(grep -cE '^- \*\*SUPERVISED WINDOW = [0-9]+ minutes\.\*\*' "$REF" || true)
[ "$window_decl" = "1" ] \
  || fail "token-economics.md must declare the supervised window exactly once as '- **SUPERVISED WINDOW = <n> minutes.**' (found $window_decl)"
WINDOW=$(grep -E '^- \*\*SUPERVISED WINDOW = [0-9]+ minutes\.\*\*' "$REF" | sed -E 's/.*= ([0-9]+) minutes.*/\1/')
[ -n "$WINDOW" ] || fail "could not read the supervised window out of $REF"

GATE="$KIT/hooks/autodev-stop-gate.sh"
[ -f "$GATE" ] || fail "missing $GATE"
gate_window=$(grep -E '^SUPERVISED_MINUTES=[0-9]+' "$GATE" | sed -E 's/^SUPERVISED_MINUTES=([0-9]+)/\1/')
[ -n "$gate_window" ] \
  || fail "$GATE has no 'SUPERVISED_MINUTES=<n>' constant for the supervised-window check"
[ "$gate_window" = "$WINDOW" ] \
  || fail "$GATE's SUPERVISED_MINUTES=$gate_window has drifted from token-economics.md's declared SUPERVISED WINDOW = $WINDOW minutes — change it in the ONE place ($REF) and update the gate's constant to match"

# Both are starting values from one run, not A/B-verified optima — the section's own standard for
# every other lever. Dropping that caveat is how a derived number becomes a law nobody re-measures.
grep -qi "not A/B-verified optima\|not A/B-verified" "$REF" \
  || fail "token-economics.md does not mark the two budgets as starting values rather than A/B-verified optima"

# ------------------------------------------------------- 2. nobody else restates either integer
# Scoped twice over, because both documents legitimately quote MEASUREMENTS in the same units and a
# blunt rule would forbid the evidence along with the restatement. A line is a violation only when
# it is about the mechanism (`autoCompactWindow` / `turn budget`) AND carries the very integer the
# reference declares — or the stale `80` default the value sits beside. So "never compacted once
# across all 19 merges" and "224 turns/session" stay sayable; "autoCompactWindow 20" and "a turn
# budget of 150 turns" do not.
#
# Both documents are HARD-WRAPPED, so the same rule is applied twice: once per line (which reports a
# useful line number) and once over the whole file flattened to a single line (which is the one that
# catches "autoCompactWindow\n20"). A line-oriented check alone was measured passing a restatement
# split across a line break — the identical hazard the PARTIAL block below already flattens for.
for f in "$SKILL_MD" "$WORKER_MD"; do
  hits=$(grep -nEi 'autoCompactWindow' "$f" | grep -E "(^|[^0-9])($BOUND|80)([^0-9]|$)" || true)
  if [ -n "$hits" ]; then
    echo "FAIL: $f restates the context bound — the integer's one home is $REF:"
    printf '%s\n' "$hits" | sed 's/^/        /'
    exit 1
  fi
  # Flattened, with a bounded window so the mechanism word and the figure have to be in the same
  # breath — `[^.]` stops the window at a sentence boundary, which is what keeps an unrelated
  # measurement three sentences later from reading as a restatement.
  # Herestring, not a pipe into `grep -q` (#391). The issue's Out-of-scope note argued this pair
  # was safe because the pattern normally does NOT match (measured 0/500 on already-compliant
  # content) — but that measurement says nothing about the one run that matters: the run where
  # the file DOES restate the bound, `grep -q` exits on the early match, and `tr` (still
  # writing the rest of a ~70KB file, past the typical pipe-buffer size) gets SIGPIPE'd, turning
  # a genuine violation into a false pass under pipefail. That is the exact failure class this
  # assertion exists to catch, reintroduced in the one place a race actually costs something —
  # converting it is strictly safer and costs nothing (code-review finding).
  flat=$(tr '\n' ' ' < "$f")
  if grep -qEi "autoCompactWindow[^.]{0,120}[^0-9]($BOUND|80)([^0-9]|$)" <<<"$flat"; then
    fail "$f restates the context bound across a line break — the integer's one home is $REF"
  fi
  hits=$(grep -nEi 'turn budget' "$f" | grep -E "(^|[^0-9])($BUDGET|150) *turns" || true)
  if [ -n "$hits" ]; then
    echo "FAIL: $f restates the worker turn budget — the integer's one home is $REF:"
    printf '%s\n' "$hits" | sed 's/^/        /'
    exit 1
  fi
  # Same herestring conversion as the context-bound check above, same reason (#391).
  flat=$(tr '\n' ' ' < "$f")
  if grep -qEi "turn budget[^.]{0,120}[^0-9]($BUDGET|150) *turns" <<<"$flat"; then
    fail "$f restates the worker turn budget across a line break — the integer's one home is $REF"
  fi
done

# The single likeliest drift site, pinned on its own: no model has a tool that runs a built-in slash
# command, so a backticked compact command anywhere in SKILL.md is the exact defect #522 reports.
if grep -qE '`/compact\b' "$SKILL_MD"; then
  fail "SKILL.md still tells the supervisor to run a backticked /compact — no model can run it: $(grep -nE '\`/compact\b' "$SKILL_MD" | head -3)"
fi

# ------------------------------------------------------------------- 3. the citations resolve
grep -q '^### The two budgets' "$REF" \
  || fail "token-economics.md has no '### The two budgets' section for the other documents to cite"
grep -q '^## Session length' "$REF" \
  || fail "token-economics.md has no '## Session length' section recording the two measurements"

for f in "$SKILL_MD" "$WORKER_MD"; do
  grep -q 'The two budgets' "$f" \
    || fail "$f does not cite token-economics.md § 'The two budgets' — a rule with no number and no citation is unusable"
done

# The measurements the budgets are derived from, so a future edit cannot keep the rules and drop
# the evidence that justifies them.
grep -q '33%' "$REF"     || fail "token-economics.md no longer records the orchestrator's 33% share of run cost"
grep -q '32%' "$REF"     || fail "token-economics.md no longer records the top-3-of-37 worker skew (32% of worker cost)"
grep -q '116,086,877' "$REF" || fail "token-economics.md no longer carries the measured orchestrator token count"

# ------------------------------------------------------------------- 4. the PARTIAL hand-off
grep -qF 'STATUS: READY|PARTIAL|BLOCKED|FAILED' "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md's final report line does not offer PARTIAL in its STATUS enum"
grep -qF 'STATUS: READY|PARTIAL|BLOCKED|FAILED' "$SKILL_MD" \
  || fail "skills/auto-dev/SKILL.md's worker-prompt contract does not offer PARTIAL in the report enum it quotes"

# The worker side: PARTIAL is a hand-off over a GREEN tree, never a way out of a red one.
grep -qi 'PARTIAL. requires a green tree\|PARTIAL requires a green tree' "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md does not state that PARTIAL requires a green tree (a red tree reports BLOCKED)"
grep -qi 'soft trigger' "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md does not say the turn count is a self-estimate against a soft trigger"

# The supervisor side: Step 4 handles PARTIAL, does not retire the slot, and resumes with a FRESH
# sub-agent — a SendMessage would resume the very context the budget exists to discard, which is
# the one way to implement this rule and save nothing (#314's substrate, in-process sub-agents).
grep -q 'Reported PARTIAL' "$SKILL_MD" \
  || fail "skills/auto-dev/SKILL.md Step 4 has no 'Reported PARTIAL' handling"
# Newlines flattened to spaces before matching: the prose is hard-wrapped, so a phrase this suite
# pins ("cap consecutive resumes") straddles a line break and a line-oriented grep would report it
# missing while it is plainly there — a false red that teaches the next reader to loosen the check.
partial_block=$(sed -n '/Reported PARTIAL/,/Reported BLOCKED/p' "$SKILL_MD" | tr '\n' ' ')
printf '%s' "$partial_block" | grep -qi 'fresh' \
  || fail "SKILL.md's 'Reported PARTIAL' handling does not prescribe a FRESH sub-agent dispatch"
printf '%s' "$partial_block" | grep -qi 'SendMessage' \
  || fail "SKILL.md's 'Reported PARTIAL' handling does not rule out a SendMessage resume (which keeps the context the budget discards)"
printf '%s' "$partial_block" | grep -qiE 'cap consecutive resumes|consecutive resumes at' \
  || fail "SKILL.md's 'Reported PARTIAL' handling has no cap on consecutive resumes, so a stuck issue can loop"

# The dispatch-time guard must carve PARTIAL out, exactly as it already carves out a tier escalation
# — a PARTIAL hand-off guarantees an open draft PR this fleet opened, so the guard would always refuse.
grep -qi 'PARTIAL. budget resume\|PARTIAL budget resume' "$SKILL_MD" \
  || fail "skills/auto-dev/SKILL.md's dispatch-time guard does not carve out a PARTIAL budget resume"

# ---------------------------------------------- 5. the retired counter is actually gone (inverted)
# #522: nothing computes a compaction-due check off a merge counter any more — the harness bounds
# context on its own threshold — so both the state-file field and the formula that read it must be
# gone, not merely present in some fixed shape.
grep -q 'last compacted @' "$SKILL_MD" \
  && fail "skills/auto-dev/SKILL.md's state-file template still carries 'last compacted @' — nothing computes from it any more, drop the field"
grep -qi 'lastCompacted' "$SKILL_MD" \
  && fail "skills/auto-dev/SKILL.md still computes a compaction-due check off 'lastCompacted' — the harness bounds context now, not a counted formula"

# --------------------------------------------- 5b. Step 1 reads the effective bound (Task 2, #522)
step1_block=$(sed -n '/^## Step 1 — Preconditions & profile/,/^## Step 2/p' "$SKILL_MD")
[ -n "$step1_block" ] || fail "could not locate '## Step 1 — Preconditions & profile' in $SKILL_MD"
for tok in 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' 'autoCompactWindow' '.claude/settings.local.json' '.claude/settings.json' '~/.claude/settings.json'; do
  printf '%s' "$step1_block" | grep -qF "$tok" \
    || fail "SKILL.md's Step 1 does not name '$tok' when reading the effective context bound"
done
printf '%s' "$step1_block" | grep -qi 'without stopping' \
  || fail "SKILL.md's Step 1 does not say a missing context bound goes in the recap without stopping"

# ------------------------------------------------ 6. Step 6 reports the share it kept missing
# Scoped to the Cost accounting block and flattened, for the same reason as the PARTIAL block. A
# file-wide `grep -qi worktree` here was measured GREEN with the entire caveat paragraph deleted —
# `worktree` appears 16 times in a skill whose subject is worktrees, so the check pinned nothing.
cost_block=$(sed -n '/\*\*Cost accounting\.\*\*/,/\*\*Lessons — mandatory\.\*\*/p' "$SKILL_MD" | tr '\n' ' ')
[ -n "$cost_block" ] || fail "could not locate Step 6's Cost accounting block in $SKILL_MD"
printf '%s' "$cost_block" | grep -qi 'orchestrator share' \
  || fail "skills/auto-dev/SKILL.md Step 6 does not report orchestrator share of total as a named metric"
printf '%s' "$cost_block" | grep -qiE 'worktree' \
  || fail "skills/auto-dev/SKILL.md Step 6's cost accounting has no worktree-transcript caveat"
# `[*_ ]*` between the words: the sentence carries markdown emphasis (*different*), and a pattern
# that assumed a plain space matched nothing while the caveat was plainly there.
printf '%s' "$cost_block" | grep -qiE 'different[*_ ]+(project|transcript)[*_ ]+(transcript[*_ ]+)?director' \
  || fail "skills/auto-dev/SKILL.md Step 6 does not say a worktree-run supervisor writes to a DIFFERENT project transcript directory — the whole reason usage_report.py must be pointed at both"

echo "PASS: auto-dev-cost-budgets (context bound=autoCompactWindow $BOUND, budget=$BUDGET turns, both declared once)"
