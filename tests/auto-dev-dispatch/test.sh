#!/usr/bin/env bash
# Golden test for #412 — auto-dev dispatched every worker into the supervisor's OWN cwd.
#
# #314 moved workers from one-shot `claude -p` processes (which got their own cwd) to in-process
# background sub-agents (which inherit the supervisor's). Step 3's dispatch form was carried over
# unchanged, so the property the fleet's whole conflict strategy rests on — "one area per
# concurrent worker" — silently stopped being true whenever the supervisor itself ran in a
# worktree: every worker landed in that same tree instead of one of its own, and the first one to
# `git switch -c` moved every other worker's HEAD out from under it.
#
# This suite pins the textual invariants that fix it, one per plan task:
#   1. Step 3's dispatch form (both the phase-1 and phase-2 spawn blocks) carries the Agent tool's
#      `isolation: "worktree"` option, and *Gotchas* names the cwd-inheritance hazard.
#   2. commands/auto-dev-worker.md and commands/auto-dev-merge.md each state that the given
#      worktree IS the worktree — no nesting another one, no touching a path outside it.
#   3. SKILL.md documents a first-act toplevel assertion (the worker reports `git rev-parse
#      --show-toplevel`; the supervisor refuses a match against its own) and what happens on a
#      refusal — re-dispatch correctly, don't let the worker proceed, don't count it BLOCKED. The
#      decision itself is a marked, extractable shell program (same discipline as
#      tests/pr-existence-guard/test.sh, modeled on it) so this suite proves the exact thing an
#      agent would paste, not a paraphrase of it.
#
# #510 extends it to the second dispatch onto an existing PR branch: both command files carry the
# worker's `branch-held guard:` refusal and 04-worktree.md points at it (its Task 2); SKILL.md
# Step 3 releases the branch through release-branch.sh before every such dispatch, *Cleanup
# nuance* says the branch goes while the tree stays, and Step 4 handles the refusal (its Task 3).
#
# Reads only files under commands/, skills/auto-dev/ and skills/implement-issue/references/steps/
# — never samples/ — so no kit_guard is needed.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $1"; exit 1; }

SKILL_MD="$(kit_skill_prose "$KIT" auto-dev)"   # router + references/steps/*.md
WORKER_MD="$KIT/commands/auto-dev-worker.md"
MERGE_MD="$KIT/commands/auto-dev-merge.md"
[ -f "$SKILL_MD" ] || fail "missing $SKILL_MD"
[ -f "$WORKER_MD" ] || fail "missing $WORKER_MD"
[ -f "$MERGE_MD" ] || fail "missing $MERGE_MD"

# --- Task 1: isolation: "worktree" on BOTH spawn blocks in Step 3 -----------------------------
#
# Step 3 runs from its own heading to Step 4's; extracted with awk rather than grep -A so the
# window is exact regardless of how long the section grows, and so a later section is never
# accidentally included.
STEP3=$(awk '/^## Step 3 —/{flag=1} /^## Step 4 —/{flag=0} flag' "$SKILL_MD")
[ -n "$STEP3" ] || fail "skills/auto-dev/SKILL.md has no '## Step 3 —' section"

iso_count=$(printf '%s\n' "$STEP3" | grep -cF 'isolation: "worktree"' || true)
[ "$iso_count" -ge 2 ] \
  || fail "Step 3 names 'isolation: \"worktree\"' $iso_count time(s); expected at least 2 (phase-1 AND phase-2 spawn blocks)"

grep -qF 'Agent(subagent_type: general-purpose, model: <tier>, run in background,' "$SKILL_MD" \
  || fail "the phase-1 spawn block's opening line moved or was reworded — check it still carries isolation: \"worktree\""

# 1'. The guard needs two ends wired, not just documented: the supervisor captures its OWN
# toplevel once (Step 1), and BOTH dispatch prompts hand it to the worker as a per-dispatch fact
# (Step 3) — a Spec-review finding on this issue caught the guard prose existing with neither end
# actually wired, which no earlier version of this suite could have caught.
STEP1=$(awk '/^## Step 1 —/{flag=1} /^## Step 2 —/{flag=0} flag' "$SKILL_MD")
[ -n "$STEP1" ] || fail "skills/auto-dev/SKILL.md has no '## Step 1 —' section"
grep -q "git rev-parse --show-toplevel" <<<"$STEP1" \
  || fail "Step 1 does not capture the supervisor's own toplevel"
grep -qi "SUPERVISOR_TOPLEVEL" <<<"$STEP1" \
  || fail "Step 1 does not name the SUPERVISOR_TOPLEVEL value the guard compares against"

toplevel_fact_count=$(printf '%s\n' "$STEP3" | grep -cF 'SUPERVISOR_TOPLEVEL=' || true)
[ "$toplevel_fact_count" -ge 2 ] \
  || fail "Step 3's dispatch prompts pass 'SUPERVISOR_TOPLEVEL=' $toplevel_fact_count time(s); expected at least 2 (phase-1 AND phase-2 prompts)"

# Gotchas names the cwd-inheritance hazard, so the next reader doesn't rediscover it cold.
GOTCHAS=$(awk '/^## Gotchas /{flag=1; print; next} /^## /{flag=0} flag' "$SKILL_MD")   # to the next heading: the step files follow the router in the assembled prose
[ -n "$GOTCHAS" ] || fail "skills/auto-dev/SKILL.md has no '## Gotchas' section"
grep -qi "inherit" <<<"$GOTCHAS" \
  || fail "Gotchas does not name the cwd-inheritance hazard (#412)"
grep -qi "cwd\|working directory" <<<"$GOTCHAS" \
  || fail "Gotchas does not mention the supervisor's cwd/working directory being inherited"

# --- Task 2: the worker commands say the given worktree IS the worktree ----------------------
for f in "$WORKER_MD" "$MERGE_MD"; do
  grep -qi "worktree you were given\|given worktree" "$f" \
    || fail "$f does not state that the given worktree is the one to work in"
  grep -qi "make-worktree\.sh" "$f" \
    || fail "$f does not warn against calling make-worktree.sh for another worktree"
  grep -qi "never touch\|do not touch\|outside your own\|outside its own\|outside the worktree" "$f" \
    || fail "$f does not forbid touching a path outside its own worktree"
  # The command file must instruct the WORKER to actually run the check, not just document that
  # the check exists elsewhere (SKILL.md) — this is the exact gap the Spec review found.
  grep -q "git rev-parse --show-toplevel" "$f" \
    || fail "$f does not instruct the worker to run 'git rev-parse --show-toplevel' as its first act"
  grep -qi "SUPERVISOR_TOPLEVEL" "$f" \
    || fail "$f does not tell the worker to compare against the prompt's SUPERVISOR_TOPLEVEL value"
  grep -qi "worker-toplevel guard" "$f" \
    || fail "$f does not point the worker at the worker-toplevel guard block to run the comparison"
done

# --- Task 3: the toplevel assertion, and what a refusal does --------------------------------
#
# 3a. Prose, scoped to the actual new sections — NOT a whole-file grep. A whole-file grep for
#     common words like "re-dispatch" or "BLOCKED" is satisfied by unrelated pre-existing prose
#     elsewhere in this long document (Step 3's tier-escalation note, Step 4's PARTIAL/BLOCKED
#     handling) regardless of whether the NEW guard section says anything at all, which would let
#     this suite pass even if the new prose were deleted outright.
GUARD_SECTION=$(awk '
  /^### ⛔ Dispatch-time guard — confirm the worker actually got its own worktree/ { flag=1 }
  flag { print }
  /^\*\*Pick each worker.s model from its labels\*\*/ { exit }
' "$SKILL_MD")
[ -n "$GUARD_SECTION" ] \
  || fail "skills/auto-dev/SKILL.md has no '### ⛔ Dispatch-time guard — confirm the worker actually got its own worktree' section"

grep -q "git rev-parse --show-toplevel" <<<"$GUARD_SECTION" \
  || fail "the new guard section does not document the first-act 'git rev-parse --show-toplevel' assertion"
grep -qi "re-dispatch" <<<"$GUARD_SECTION" \
  || fail "the new guard section does not say the supervisor re-dispatches on a refusal"
grep -Eqi "not.{0,40}BLOCKED|never.{0,40}BLOCKED" <<<"$GUARD_SECTION" \
  || fail "the new guard section does not say a same-cwd refusal is NOT counted as a BLOCKED issue"
grep -qi "auto-clean" <<<"$GUARD_SECTION" \
  || fail "the new guard section does not state the auto-clean-only-if-unchanged cleanup nuance for isolation: \"worktree\""
grep -qi "Needs manual sweep" <<<"$GUARD_SECTION" \
  || fail "the new guard section does not point a leftover worker worktree at '## Needs manual sweep'"

# 3a'. The plan also asks Step 4's per-slot handling to say what happens on a refusal — a second,
# separately-scoped location, so a future edit that removes it from ONE of the two homes is caught.
STEP4_INTRO=$(awk '
  /^## Step 4 —/ { flag=1 }
  flag { print }
  /^You.re woken by a worker.s report/ { exit }
' "$SKILL_MD")
[ -n "$STEP4_INTRO" ] || fail "skills/auto-dev/SKILL.md has no '## Step 4 —' section"
grep -qi "re-dispatch" <<<"$STEP4_INTRO" \
  || fail "Step 4's intro does not say the supervisor re-dispatches a worker-toplevel guard refusal"
grep -Eqi "not.{0,40}BLOCKED|never.{0,40}BLOCKED" <<<"$STEP4_INTRO" \
  || fail "Step 4's intro does not say a same-cwd refusal is NOT counted as a BLOCKED issue"

# 3b. The decision itself, RUN — not just grepped for. It was a marked block in Step 3 that a worker
#     pasted; it is a script now, so this drives the very file a worker executes, from real
#     directories rather than from two strings handed to it.
GUARD="$KIT/skills/auto-dev/scripts/worker-toplevel-guard.sh"
[ -x "$GUARD" ] || fail "$GUARD missing or not executable"
grep -qF 'worker-toplevel-guard.sh "$SUPERVISOR_TOPLEVEL"' "$SKILL_MD" \
  || fail "Step 3 no longer invokes worker-toplevel-guard.sh with the supervisor's toplevel"
if grep -qF '# >>> worker-toplevel guard' "$SKILL_MD"; then
  fail "Step 3 still carries the marked worker-toplevel block — the script is its one home now"
fi
for f in "$WORKER_MD" "$MERGE_MD"; do
  grep -qF 'skills/auto-dev/scripts/worker-toplevel-guard.sh' "$f" \
    || fail "$f does not tell the worker to run worker-toplevel-guard.sh as its first act"
done

G_SCRATCH="$(kit_scratch)"
SUP="$G_SCRATCH/supervisor"; WRK="$G_SCRATCH/worker"; BARE="$G_SCRATCH/not-a-repo"
mkdir -p "$SUP/sub" "$WRK" "$BARE"
git -C "$SUP" init -q; git -C "$WRK" init -q
SUP_TOP=$(git -C "$SUP" rev-parse --show-toplevel)

# guard_case <label> <cwd> <want exit> <want first word> [args…]
guard_case() {
  local label="$1" cwd="$2" want_rc="$3" want_word="$4"; shift 4
  local out rc=0
  out=$(cd "$cwd" && "$GUARD" "$@" 2>&1) || rc=$?
  [ "$rc" -eq "$want_rc" ] || fail "worker-toplevel guard [$label]: exit $rc, wanted $want_rc — $out"
  case "$out" in
    "$want_word"*) ;;
    *) fail "worker-toplevel guard [$label]: expected a line starting '$want_word', got: $out" ;;
  esac
}
# A matching toplevel — the shared-worktree hazard itself — must be a refusal.
guard_case "the supervisor's own tree" "$SUP" 1 REFUSE "$SUP_TOP"
guard_case "a subdirectory of the supervisor's tree" "$SUP/sub" 1 REFUSE "$SUP_TOP"
# A differing toplevel — the normal isolated case — must proceed.
guard_case "a tree of its own" "$WRK" 0 PROCEED "$SUP_TOP"
# Not a git directory at all is a refusal, never a PROCEED and never a crash.
guard_case "not a git work tree" "$BARE" 1 REFUSE "$SUP_TOP"
# The same tree reached through a symlink is still the same tree.
ln -s "$SUP" "$G_SCRATCH/supervisor-link"
guard_case "the supervisor's tree through a symlink" "$SUP" 1 REFUSE "$G_SCRATCH/supervisor-link"
# No supervisor toplevel is no verdict — and above all not exit 0.
guard_case "no argument" "$WRK" 2 "worker-toplevel guard: no verdict"
guard_case "an empty argument" "$WRK" 2 "worker-toplevel guard: no verdict" ""

# --- #510 Task 2: the worker-side branch-held guard ---------------------------------------------
#
# A re-dispatch onto an existing PR branch can wake up in a fresh tree while a retired worker's
# tree still holds that branch. The worker cannot repair that from inside its own tree, so both
# command files give it a NAMED refusal the supervisor acts on (release-branch.sh, then
# re-dispatch) and forbid the workarounds that would put two trees on one branch. Newlines are
# folded to spaces first, so a sentence the prose wraps across lines still matches.
for f in "$WORKER_MD" "$MERGE_MD"; do
  flat=$(tr '\n' ' ' < "$f")
  grep -qF 'branch-held guard:' <<<"$flat" \
    || fail "$f does not carry the 'branch-held guard:' refusal signature (#510)"
  grep -qF 'release-branch.sh then re-dispatch' <<<"$flat" \
    || fail "$f's branch-held signature does not name the supervisor's repair ('release-branch.sh then re-dispatch')"
  grep -Eqi '(do not|never)[^.]{0,80}--ignore-other-worktrees' <<<"$flat" \
    || fail "$f does not forbid --ignore-other-worktrees (two trees on one branch, #510)"
done

WORKTREE_STEP="$KIT/skills/implement-issue/references/steps/04-worktree.md"
[ -f "$WORKTREE_STEP" ] || fail "missing $WORKTREE_STEP"
flat=$(tr '\n' ' ' < "$WORKTREE_STEP")
grep -qi 'checked out in another worktree' <<<"$flat" \
  || fail "04-worktree.md does not name the branch-checked-out-in-another-worktree case (#510)"
grep -qF 'commands/auto-dev-worker.md' <<<"$flat" \
  || fail "04-worktree.md does not point the held-branch case at commands/auto-dev-worker.md"
if grep -qF 'release-branch.sh then re-dispatch' <<<"$flat"; then
  fail "04-worktree.md restates the branch-held signature — its one home is the two command files"
fi

# --- #510 Task 3: the supervisor releases before every dispatch onto an existing PR branch ------
#
# The release has one home (release-branch.sh) and one caller (the supervisor), so Step 3 must
# carry the guard that runs it — scoped to its own subsection, never a whole-file grep, for the
# reason 3a gives — and name every entry point that re-enters a branch an earlier tree may hold.
RELEASE_SECTION=$(awk '
  /^### ⛔ Dispatch-time guard — release the PR branch before re-dispatching onto it/ { flag=1 }
  flag && /^### The worker-prompt contract/ { flag=0 }
  flag { print }
' <<<"$STEP3")
[ -n "$RELEASE_SECTION" ] \
  || fail "Step 3 has no '### ⛔ Dispatch-time guard — release the PR branch before re-dispatching onto it' subsection (#510)"
grep -qF 'release-branch.sh' <<<"$RELEASE_SECTION" \
  || fail "the release guard does not name release-branch.sh"
# Each entry point by its OWN bullet, not by a word: `tier` and `phase 2` also occur in the
# verdict rules below them, so a word match survives deleting the bullet it was meant to pin.
for entry in '- a **`PARTIAL` resume**' '- a **BLOCKED/FAILED tier escalation**' '- **phase 2** (' \
             '- the **push-and-land**' '- a **restart after a crash**'; do
  grep -qF -- "$entry" <<<"$RELEASE_SECTION" \
    || fail "the release guard has no '$entry' entry-point bullet"
done
grep -qF 'HELD' <<<"$RELEASE_SECTION" || fail "the release guard does not say what a HELD verdict does"
grep -qF 'Needs manual sweep' <<<"$RELEASE_SECTION" \
  || fail "the release guard does not record a HELD verdict under '## Needs manual sweep'"
grep -Eqi 'never.{0,40}FREE' <<<"$RELEASE_SECTION" \
  || fail "the release guard does not forbid reading a no-verdict exit 2 as FREE"

# The verdict words the guard acts on are the script's own, read from its --help rather than retyped
# here: a verdict renamed or added in the script but not in the prose that consumes it fails.
RB_HELP=$("$KIT/skills/auto-dev/scripts/release-branch.sh" --help)
VERDICT_WORDS=$(awk '
  /^One verdict line/ { on = 1; next }
  /^Exit codes:/      { on = 0 }
  on && /^  [A-Z]/    { print $1; if ($1 == "HELD") print $3 }
' <<<"$RB_HELP")
n_words=$(printf '%s\n' "$VERDICT_WORDS" | grep -c . || true)
[ "$n_words" -ge 7 ] \
  || fail "read $n_words verdict word(s) from release-branch.sh --help; expected FREE, RELEASED and HELD with its four reasons"
for w in $VERDICT_WORDS; do
  grep -qF -- "$w" <<<"$RELEASE_SECTION" \
    || fail "the release guard never mentions '$w', a verdict word release-branch.sh prints"
done

# The Cleanup nuance paragraph keeps its decision — the tree stays for the sweep — and now says
# the branch does not stay with it.
CLEANUP=$(awk '/^\*\*Cleanup nuance for / { flag=1 } flag && /^$/ { exit } flag { print }' "$SKILL_MD" | tr '\n' ' ')
[ -n "$CLEANUP" ] || fail "skills/auto-dev/SKILL.md has no '**Cleanup nuance for …' paragraph"
grep -qi 'tree stays' <<<"$CLEANUP" || fail "the Cleanup nuance paragraph no longer says the tree stays for the sweep"
grep -qF 'release-branch.sh' <<<"$CLEANUP" \
  || fail "the Cleanup nuance paragraph does not say the branch is released (release-branch.sh) while the tree stays"

# Step 4 handles the worker's named refusal as a dispatch defect: release, re-dispatch at the same
# tier, never tier-escalate, and outside the PARTIAL cap. Step 4's bullets are one line each.
STEP4=$(awk '/^## Step 4 —/ { flag=1; print; next } flag && /^## / { flag=0 } flag' "$SKILL_MD")
BH_BULLET=$(printf '%s\n' "$STEP4" | grep -F -- '- **Reported BLOCKED with `DETAIL: branch-held guard' || true)
[ -n "$BH_BULLET" ] || fail "Step 4 has no '- **Reported BLOCKED with \`DETAIL: branch-held guard' bullet (#510)"
grep -qF 'release-branch.sh' <<<"$BH_BULLET" || fail "Step 4's branch-held bullet does not run release-branch.sh"
grep -qi 're-dispatch' <<<"$BH_BULLET" || fail "Step 4's branch-held bullet does not say to re-dispatch"
grep -Eqi 'never tier-escalate' <<<"$BH_BULLET" || fail "Step 4's branch-held bullet does not forbid a tier escalation"
grep -Eqi "(don't|do not|never) count it against the .PARTIAL" <<<"$BH_BULLET" \
  || fail "Step 4's branch-held bullet does not keep it outside the PARTIAL cap"

echo "PASS: auto-dev-dispatch"
