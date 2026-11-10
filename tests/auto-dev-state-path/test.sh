#!/usr/bin/env bash
# Golden test for auto-dev's pinned state-file path (#417 Task 2).
#
# Before this issue, skills/auto-dev/SKILL.md Step 2 told the supervisor to persist its state file
# "outside the repo (a scratch/temp dir, not a tracked path)" — prose an agent interprets, not a path
# a hook can read. #417's Stop hook (hooks/autodev-stop-gate.sh) needs to find that file without
# being told where it is, so the path has to be PINNED and DERIVABLE from the repository alone.
#
# This suite is a grep over SKILL.md's Step 2 and Step 6 text, not an execution of the skill (there
# is nothing to execute — the skill is a markdown procedure a model follows). It pins two things:
#   1. Step 2 states the path as the derivable expression the hook computes independently, and keeps
#      the existing "outside the repo, never tracked" requirement intact;
#   2. Step 6 removes the file on drain, which is what makes an absent file mean "no fleet running
#      here" rather than "a fleet ran once, years ago, and never cleaned up."
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $1"; exit 1; }

SKILL_MD="$(kit_skill_prose "$KIT" auto-dev)"   # router + references/steps/*.md
[ -f "$SKILL_MD" ] || fail "missing $SKILL_MD"

# --------------------------------------------------------------- 1. the path is pinned, not prose
PINNED='${AUTODEV_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}/tagout/auto-dev/<host>/<owner>/<repo>.md'
grep -qF "$PINNED" "$SKILL_MD" \
  || fail "SKILL.md no longer states the pinned, derivable state-file path — $PINNED"

# The old free-form instruction must be gone; a reader (or a hook author) should have exactly one
# path to find, not a prose alternative sitting next to it.
grep -qF 'a scratch/temp dir, not a tracked path' "$SKILL_MD" \
  && fail "SKILL.md still carries the old prose path ('a scratch/temp dir') alongside the pinned one"

# The collision-prone dash-joined filename must be gone too: `-` is legal inside both a GitHub
# owner and repo name, so `auto-dev-<owner>-<repo>.md` cannot tell `foo-bar/baz` apart from
# `foo/bar-baz` (both flatten to `auto-dev-foo-bar-baz.md`). Nesting `<owner>` and `<repo>` as two
# path SEGMENTS is what the hook actually does (hooks/autodev-stop-gate.sh); this pins the doc to
# the same shape rather than the old one-file-per-repo string.
grep -qF 'auto-dev-<owner>-<repo>.md' "$SKILL_MD" \
  && fail "SKILL.md still states the collision-prone dash-joined path (auto-dev-<owner>-<repo>.md)"

# Still outside the repo, never tracked — the ONE requirement #417 must not loosen.
state_block=$(sed -n '/Persist a \*\*state file\*\* at the pinned/,/^```markdown/p' "$SKILL_MD")
[ -n "$state_block" ] || fail "could not locate the Step 2 state-file paragraph in $SKILL_MD"
grep -qi 'outside the repo' <<<"$state_block" \
  || fail "Step 2's state-file paragraph dropped the 'outside the repo' requirement"
grep -qi 'never a tracked path\|not a tracked path' <<<"$state_block" \
  || fail "Step 2's state-file paragraph dropped the 'never a tracked path' requirement"

# --------------------------------------------------------------------- 2. Step 6 removes it on drain
step6=$(sed -n '/^## Step 6 — Stop & recap/,$p' "$SKILL_MD")
[ -n "$step6" ] || fail "could not locate '## Step 6 — Stop & recap' in $SKILL_MD"
grep -qi 'remove the state file' <<<"$step6" \
  || fail "Step 6 does not explicitly remove the state file on drain"
grep -qF 'rm -f' <<<"$step6" \
  || fail "Step 6's removal instruction has no concrete rm command"
grep -qF "$PINNED" <<<"$step6" \
  || fail "Step 6's removal instruction does not target the same pinned path Step 2 declares"

# Removal must be gated on the drain actually completing, not on every stop — a supervisor asked to
# stop mid-fleet must NOT delete evidence of the work still in flight.
grep -qi "mid-run stop\|only once the drain" <<<"$step6" \
  || fail "Step 6 does not say the removal is skipped on a mid-run stop"

# --------------------------------------------------------------------- 3. #417 is credited
grep -qF '#417' "$SKILL_MD" \
  || fail "SKILL.md does not credit #417 for the pinned path / hook that reads it"

# ------------------------------------------------------------------------- 4. structural wiring
./scripts/parse-sweep.sh tests/auto-dev-state-path/test.sh >/dev/null \
  || fail "parse-sweep rejects this suite"

echo "PASS: auto-dev-state-path (pinned path stated, Step 6 removes it on drain)"
