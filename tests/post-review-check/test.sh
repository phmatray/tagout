#!/usr/bin/env bash
# Golden test for post-review-check.sh — proves it catches a code-review dispatch that wrote
# past its own report (#659). Every case runs against a real fixture git repo (no `git` command
# is mocked, per the issue's own Testing decisions), and each case gets its OWN fresh repo: a
# fixture shared across cases would let one case's residue mask another (e.g. the untracked
# file from the dirty-tree case would trip exit 1 before the advanced-HEAD case's exit 2 ever
# ran).
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
SCRIPT="$KIT/skills/implement-issue/scripts/post-review-check.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable"; exit 1; }

# Scratch dir and EXIT trap come from the shared preamble (#72).
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
WORK=$(kit_scratch)

# A fresh one-commit repo on `main`, local-only identity and hooks path — the ambient user
# config must never reach a test fixture (mirrors tests/guarded-git/test.sh's new_repo()).
new_repo() {
  local d="$WORK/$1"
  git init -q "$d"
  git -C "$d" symbolic-ref HEAD refs/heads/main       # version-proof `git init -b main`
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name "Post Review Check Test"
  git -C "$d" config commit.gpgsign false
  git -C "$d" config core.hooksPath "$d/.git/hooks"
  git -C "$d" config --unset-all commit.template 2> /dev/null || true
  echo seed > "$d/seed.txt"
  git -C "$d" add seed.txt
  git -C "$d" commit -q -m seed
  printf '%s' "$d"
}

# Runs the guard without `set -e` aborting the test, capturing stdout+stderr and the code.
run() {
  local name="$1"; shift
  OUT="$WORK/out.$name"
  set +e
  "$@" > "$OUT" 2>&1
  RC=$?
  set -e
}

fail() { echo "FAIL [$1]: $2"; [ -n "${OUT:-}" ] && sed 's/^/    | /' "$OUT"; exit 1; }

# ---------------------------------------------------------------------- case: clean (exit 0)
R=$(new_repo clean)
BEFORE=$(git -C "$R" rev-parse HEAD)
run clean "$SCRIPT" -C "$R" --branch main --before "$BEFORE"
[ "$RC" -eq 0 ] || fail clean "expected exit 0, got $RC"
grep -q "^post-review-check: clean" "$OUT" || fail clean "missing the clean verdict line"
grep -qF "$BEFORE" "$OUT" || fail clean "clean line does not name the unchanged sha"

# ------------------------------------------------------- case: dirty, untracked file (exit 1)
R=$(new_repo dirty-untracked)
BEFORE=$(git -C "$R" rev-parse HEAD)
echo stray > "$R/untracked.txt"
run dirty_untracked "$SCRIPT" -C "$R" --branch main --before "$BEFORE"
[ "$RC" -eq 1 ] || fail dirty_untracked "expected exit 1, got $RC"
grep -q "REFUSED - uncommitted changes" "$OUT" || fail dirty_untracked "missing the REFUSED line"
grep -q "untracked.txt" "$OUT" || fail dirty_untracked "output does not name the untracked file"

# --------------------------------------------------------- case: dirty, tracked edit (exit 1)
R=$(new_repo dirty-tracked)
BEFORE=$(git -C "$R" rev-parse HEAD)
echo changed >> "$R/seed.txt"
run dirty_tracked "$SCRIPT" -C "$R" --branch main --before "$BEFORE"
[ "$RC" -eq 1 ] || fail dirty_tracked "expected exit 1, got $RC"
grep -q "seed.txt" "$OUT" || fail dirty_tracked "output does not include the diff --stat of the tracked change"

# -------------------------------------------------------------- case: HEAD advanced (exit 2)
R=$(new_repo advanced)
BEFORE=$(git -C "$R" rev-parse HEAD)
git -C "$R" commit -q --allow-empty -m "second commit, never authorized"
AFTER=$(git -C "$R" rev-parse HEAD)
run advanced "$SCRIPT" -C "$R" --branch main --before "$BEFORE"
[ "$RC" -eq 2 ] || fail advanced "expected exit 2, got $RC"
grep -q "REFUSED - HEAD advanced from $BEFORE to $AFTER" "$OUT" || fail advanced "missing the advance line naming both shas"
grep -q "second commit, never authorized" "$OUT" || fail advanced "output does not list the new commit's subject line"

# ------------------------------------------------------------- case: wrong branch (exit 3)
R=$(new_repo wrong-branch)
BEFORE=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q -b other
run wrong_branch "$SCRIPT" -C "$R" --branch main --before "$BEFORE"
[ "$RC" -eq 3 ] || fail wrong_branch "expected exit 3, got $RC"
grep -q "REFUSED - HEAD is on 'other', expected 'main'" "$OUT" || fail wrong_branch "missing the branch-mismatch line"

# ------------------------------------------------------------- case: detached HEAD (exit 3)
R=$(new_repo detached)
BEFORE=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q "$BEFORE"
run detached "$SCRIPT" -C "$R" --branch main --before "$BEFORE"
[ "$RC" -eq 3 ] || fail detached "expected exit 3, got $RC"
grep -q "REFUSED - HEAD is on '<detached>', expected 'main'" "$OUT" || fail detached "missing the detached-HEAD line"

# ---------------------------------------------------------- case: usage errors (exit 64)
R=$(new_repo usage)
BEFORE=$(git -C "$R" rev-parse HEAD)

run usage_missing_branch "$SCRIPT" -C "$R" --before "$BEFORE"
[ "$RC" -eq 64 ] || fail usage_missing_branch "expected exit 64 for a missing --branch, got $RC"

run usage_missing_before "$SCRIPT" -C "$R" --branch main
[ "$RC" -eq 64 ] || fail usage_missing_before "expected exit 64 for a missing --before, got $RC"

run usage_bad_before "$SCRIPT" -C "$R" --branch main --before not-a-sha
[ "$RC" -eq 64 ] || fail usage_bad_before "expected exit 64 for an unresolvable --before, got $RC"

run usage_not_a_repo "$SCRIPT" -C "$WORK" --branch main --before "$BEFORE"
[ "$RC" -eq 64 ] || fail usage_not_a_repo "expected exit 64 for a non-repository -C, got $RC"

# ---------------------------------------------------- wiring: 07-review.md still calls the guard
# #659's Verification axis: the cases above only prove the SCRIPT is correct in isolation — nothing
# fails if Step 7's prose is edited to drop the call, mangle its flags, or revert to the three-line
# memory aid this script replaced. Pin the literal invocation so that drift is caught here too.
STEP7="$KIT/skills/implement-issue/references/steps/07-review.md"
[ -f "$STEP7" ] || fail wiring "missing $STEP7"
grep -qF '"$GUARDS/post-review-check.sh" -C "$WORKTREE" --branch "$BRANCH" --before' "$STEP7" \
  || fail wiring "07-review.md no longer calls post-review-check.sh with -C/--branch/--before"

echo "OK: post-review-check.sh — clean/dirty(untracked+tracked)/advanced/wrong-branch/detached/usage/wiring all verified"
