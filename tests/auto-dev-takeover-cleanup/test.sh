#!/usr/bin/env bash
# Golden test for the auto-dev takeover's local cleanup (#227).
#
# `skills/auto-dev/SKILL.md` Step 4's takeover bullet lets the supervisor land a stalled PR itself
# via `guarded-pr-merge.sh` when a worker idles at "ready" twice with CI already final. On a `0`
# (MERGED) verdict, the prose used to stop at "shut the worker down and refill the slot" — the
# script's own header comment is explicit that "local cleanup (branch/worktree teardown) is the
# caller's job", and nothing was ever the caller. Every landed takeover therefore leaked the
# worker's `.claude/worktrees/<branch>/` checkout and local head branch forever, with no follow-up
# triage either — the same guarantee every other merged PR in this kit gets via `merge-pr` Steps
# 6-7, just never invoked here.
#
# The fix reuses the fleet's own phase-2 dispatch contract (a background sub-agent spawned with
# the Agent tool at the cheap tier, invoking `auto-dev-merge <PR>` — the same spawn form Step 3
# already uses, #314) to run a cleanup-only `merge-pr <PR>` after the takeover's MERGED verdict — `merge-pr`'s own Step 1 resume contract
# detects `state == MERGED` and routes straight to Steps 6-7 (follow-up triage, then
# worktree/branch teardown), so the dispatch is pure cleanup with no risk of a second merge
# attempt, and it explicitly does not count against the fleet's N worker slots. This suite pins
# the textual invariants so none regresses silently again; it asserts SKILL.md prose, not runtime
# behavior — this repo has no harness that runs `auto-dev` end-to-end, so its golden suites for
# this skill assert structural properties of the doc itself (see tests/auto-dev-never-wait/test.sh
# for the established pattern).
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $1"; exit 1; }

SKILL_MD="$(kit_skill_prose "$KIT" auto-dev)"   # router + references/steps/*.md
[ -f "$SKILL_MD" ] || fail "missing $SKILL_MD"

# 1. The MERGED clause dispatches a cleanup sub-agent via the SAME phase-2 spawn form Step 3 uses
#    (an Agent-tool spawn at the small tier, in the background, whose prompt invokes
#    `auto-dev-merge <PR>`), not an ad hoc bare invocation — and says so by pointing at Step 3
#    rather than restating the whole block (#314: no `claude -p` process, no `--strict-mcp-config`).
grep -qF 'Agent(model: <small tier>, run in background, prompt: "Invoke `auto-dev-merge` with args `<PR>`' "$SKILL_MD" \
  || fail "SKILL.md's takeover MERGED clause does not spawn the cleanup sub-agent in Step 3's phase-2 form"
grep -qF 'the way Step 3 spawns phase 2' "$SKILL_MD" \
  || fail "SKILL.md's takeover MERGED clause does not point its cleanup dispatch at Step 3's spawn form"
if grep -q 'claude -p\|--strict-mcp-config' "$SKILL_MD"; then
  fail "SKILL.md still names the pre-2.0 process substrate: $(grep -n 'claude -p\|--strict-mcp-config' "$SKILL_MD" | head -3)"
fi

# 2. It says the cleanup session does not count against the fleet's N worker slots.
grep -qF 'not** one of the' "$SKILL_MD" \
  || fail "SKILL.md does not say the cleanup session is excluded from the N worker slots"

# 3. It states WHY a second merge can never happen: merge-pr's own resume contract routes an
#    already-MERGED PR straight to Steps 6-7.
grep -qF 'state == MERGED' "$SKILL_MD" \
  || fail "SKILL.md does not explain merge-pr's MERGED resume routing"
grep -qF 'Steps 6-7' "$SKILL_MD" \
  || fail "SKILL.md does not point the dispatch at merge-pr's Steps 6-7 (follow-ups + teardown)"

# 4. It recognizes completion from the same structured report line every phase-2 worker already
#    emits, and defers the '## Completed' entry to that report rather than the takeover moment.
grep -qF 'STATUS: MERGED|BLOCKED|FAILED | … | WORKTREE' "$SKILL_MD" \
  || fail "SKILL.md does not recognize cleanup completion via the standard phase-2 report line"
grep -qF "isn't truly closed" "$SKILL_MD" \
  || fail "SKILL.md does not defer the '## Completed' entry to the cleanup session's own report"

# 5. A failed/timed-out cleanup session must not block the fleet, and is safe to just re-dispatch.
grep -qF "don't block the fleet on it" "$SKILL_MD" \
  || fail "SKILL.md does not say a failed/timed-out cleanup session must not block the fleet"
grep -qF 're-dispatch the same call next heartbeat' "$SKILL_MD" \
  || fail "SKILL.md does not say to just re-dispatch a failed/timed-out cleanup session"

echo "PASS: auto-dev-takeover-cleanup"
