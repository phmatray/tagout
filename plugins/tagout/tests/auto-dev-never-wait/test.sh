#!/usr/bin/env bash
# Golden test for the auto-dev "never wait" invariant (#187).
#
# Two of three phase-1 workers in a live fleet run were killed after doing essentially all of the
# work: each ended its turn to "wait" for a subagent or background suite it had itself dispatched,
# and a worker that ends its turn has ended its run — its final message IS its report, and nothing
# resumes it (#314: workers are background sub-agents now, and the rule survives the substrate
# change — the deferral just arrives as a report instead of a dead process). `SKILL.md` already
# documented this hazard at length for phase 2 (waiting on CI), but `commands/auto-dev-worker.md` —
# the literal text a phase-1 worker's context is seeded with — said nothing about it at all.
#
# This suite pins two textual invariants so neither regresses silently:
#   1. commands/auto-dev-worker.md carries a hard "never wait" rule, naming the forbidden phrasings
#      a worker actually produced.
#   2. skills/auto-dev/SKILL.md Step 4 recognizes the "died waiting, all boxes ticked" signature and
#      prescribes a tail prompt (not a restart) as its recovery — the worker-side fix does not
#      retroactively rescue a session that already died this way.
#
# Reads only files under commands/ and skills/auto-dev/ — never samples/ — so no kit_guard is needed.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $1"; exit 1; }

WORKER_MD="$KIT/commands/auto-dev-worker.md"
[ -f "$WORKER_MD" ] || fail "missing $WORKER_MD"

# 1a. The worker prompt states the background-sub-agent warning: the worker's final message is its
#     report, and ending the turn ends the run (#314 re-grounded the rule on sub-agents).
grep -qi "background sub-agent" "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md has no 'background sub-agent' marker"
grep -qi "final message is your report" "$WORKER_MD" \
  || fail "commands/auto-dev-worker.md does not say the final message is the report"

# 1a'. Neither worker command still describes itself as a `claude -p` process — that substrate is
#      gone (#314, the v2.0 breaking change). A plain `grep -q` exit 1 on both files is the pass.
MERGE_MD="$KIT/commands/auto-dev-merge.md"
[ -f "$MERGE_MD" ] || fail "missing $MERGE_MD"
if grep -q 'claude -p' "$WORKER_MD" "$MERGE_MD"; then
  fail "a worker command still names 'claude -p' as its substrate: $(grep -n 'claude -p' "$WORKER_MD" "$MERGE_MD" | head -3)"
fi

# 1b. It names the observed forbidden phrasings verbatim, so a future edit that quietly drops one
#     of the three concrete examples is caught rather than passing on the marker phrase alone.
FORBIDDEN_PHRASINGS=(
  "I'll pause here and wait for"
  "I'll pick this back up automatically once it completes"
  "I'll stop issuing further tool calls now and wait"
)
for phrasing in "${FORBIDDEN_PHRASINGS[@]}"; do
  grep -qF "$phrasing" "$WORKER_MD" \
    || fail "commands/auto-dev-worker.md is missing the forbidden phrasing: $phrasing"
done

# 2. skills/auto-dev/SKILL.md Step 4 recognizes a worker killed by an in-worker wait — all plan
#    checkboxes ticked plus a deferral-shaped final line — and prescribes a tail prompt, not a
#    restart, as the recovery.
SKILL_MD="$(kit_skill_prose "$KIT" auto-dev)"   # router + references/steps/*.md
[ -f "$SKILL_MD" ] || fail "missing $SKILL_MD"

grep -qi "checkboxes.*ticked" "$SKILL_MD" \
  || fail "skills/auto-dev/SKILL.md does not name the 'all checkboxes ticked' recognition signature"
grep -qi "deferral" "$SKILL_MD" \
  || fail "skills/auto-dev/SKILL.md does not name the deferral-shaped final line signature"
grep -qi "tail prompt" "$SKILL_MD" \
  || fail "skills/auto-dev/SKILL.md does not prescribe a tail prompt as the recovery"
grep -qi "not a restart\|never a restart\|not a re-run" "$SKILL_MD" \
  || fail "skills/auto-dev/SKILL.md does not rule out a restart as the recovery"

echo "PASS: auto-dev-never-wait"
