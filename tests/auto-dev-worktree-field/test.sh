#!/usr/bin/env bash
# Golden test for the auto-dev normal MERGED report's WORKTREE handling (#234).
#
# `skills/auto-dev/SKILL.md` Step 4's normal `Reported MERGED` bullet acted purely on a worker's
# `STATUS: MERGED` field and never read the same report's `WORKTREE` field, even though
# `commands/auto-dev-merge.md` mandates that field carry exactly this information. `merge-pr`'s own
# Step 7 is documented as tolerant of partial local cleanup (e.g. `git worktree remove` needing
# `--force` on a dirty leftover, or a `git branch -D` racing something else), so a worker can
# legitimately report `STATUS: MERGED` with `WORKTREE: branch deleted, worktree still present` — and
# that worker was shut down and its slot refilled without anything noticing the leftover.
#
# The fix has the bullet read `WORKTREE` before refilling: a fully-cleaned result proceeds
# unchanged, anything else (including a missing field, which is non-clean, not evidence of success)
# is recorded in a new `## Needs manual sweep` state-file section before the slot is still refilled
# regardless — the PR is merged, only local cleanup is outstanding. This suite pins the textual
# invariants so none regresses silently; it asserts SKILL.md prose, not runtime behavior — this repo
# has no harness that runs `auto-dev` end-to-end, so its golden suites for this skill assert
# structural properties of the doc itself (see tests/auto-dev-never-wait/test.sh for the established
# pattern).
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $1"; exit 1; }

SKILL_MD="$(kit_skill_prose "$KIT" auto-dev)"   # router + references/steps/*.md
[ -f "$SKILL_MD" ] || fail "missing $SKILL_MD"

# 1. Step 2's state-file schema example carries a '## Needs manual sweep' section with a one-line
#    entry shape naming the issue, PR, and the WORKTREE text.
grep -qF '## Needs manual sweep' "$SKILL_MD" \
  || fail "SKILL.md's state-file schema is missing the '## Needs manual sweep' section"
grep -qF -- '- #<n> → PR #<pr> — WORKTREE: <text>' "$SKILL_MD" \
  || fail "SKILL.md's '## Needs manual sweep' section is missing its one-line entry shape"

# 2. The normal 'Reported MERGED' bullet reads the worker's WORKTREE field before refilling.
grep -qF "read the worker's \`WORKTREE\` field" "$SKILL_MD" \
  || fail "SKILL.md's normal MERGED bullet does not say it reads the worker's WORKTREE field"

# 3. A missing WORKTREE field is treated as non-clean, not as evidence of success.
grep -qF '**missing** `WORKTREE` field is treated the same way, as non-clean' "$SKILL_MD" \
  || fail "SKILL.md does not say a missing WORKTREE field counts as non-clean"

# 4. A non-clean result is recorded in '## Needs manual sweep' naming the issue, PR, and the
#    WORKTREE text verbatim — BEFORE the slot is refilled, but refilling still happens regardless.
grep -qF "add a line to the state file's \`## Needs manual sweep\` section naming the" "$SKILL_MD" \
  || fail "SKILL.md's normal MERGED bullet does not record a non-clean result in '## Needs manual sweep'"
grep -qF 'still end the agent and refill the slot' "$SKILL_MD" \
  || fail "SKILL.md does not say the slot is refilled regardless of a non-clean WORKTREE result"

# 5. The bullet still names the fully-cleaned path proceeding exactly as before (end the agent,
#    refill the slot) — the new read must not have dropped the original behavior on a clean result.
grep -qF 'reads as fully cleaned up' "$SKILL_MD" \
  || fail "SKILL.md does not distinguish a fully-cleaned WORKTREE result from a non-clean one"

# 6. '## Needs manual sweep' is not write-only: Step 6's final summary surfaces any entries still on
#    the state file, since nothing else in the skill ever reads that section back.
grep -qF 'any `## Needs manual' "$SKILL_MD" \
  || fail "SKILL.md's Step 6 (Stop & report) does not surface outstanding '## Needs manual sweep' entries"

# 7. A non-clean WORKTREE result does not block the issue from moving to '## Completed' — the sweep
#    note tracks local housekeeping separately, avoiding the ambiguity of the sibling takeover bullet
#    (which DOES defer '## Completed' because it re-dispatches a session to close the gap).
grep -qF 'still moves to `## Completed` right away' "$SKILL_MD" \
  || fail "SKILL.md does not clarify that a non-clean WORKTREE result still moves the issue to '## Completed'"

echo "PASS: auto-dev-worktree-field"
