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

echo "OK: post-review-check.sh — clean verified"
