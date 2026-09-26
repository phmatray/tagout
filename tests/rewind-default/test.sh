#!/usr/bin/env bash
# Golden test for skills/create-pr/scripts/rewind-default.sh — the guard that moves the local
# default branch back to origin/<default> only once the pushed branch provably carries it (#636).
#
# Fail-path-first, like every guard suite here: the refusals are proven before the happy path, so
# a check that silently stopped matching cannot pass by accident.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
REWIND="$KIT/skills/create-pr/scripts/rewind-default.sh"
[ -x "$REWIND" ] || { echo "FAIL: $REWIND missing or not executable"; exit 1; }

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
WORK=$(kit_scratch)

# A scratch repo, one commit on `main`, wired to a local bare `origin` with `main` already pushed.
# Local config only — the ambient user config may sign commits, which a fixture must not depend on.
new_repo_with_origin() {
  local d="$WORK/$1"
  git init -q "$d"
  git -C "$d" symbolic-ref HEAD refs/heads/main
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name "Rewind Default Test"
  git -C "$d" config commit.gpgsign false
  echo seed > "$d/seed.txt"
  git -C "$d" add seed.txt
  git -C "$d" commit -q -m seed
  git init -q --bare "$WORK/$1.git"
  git -C "$d" remote add origin "$WORK/$1.git"
  git -C "$d" push -q -u origin main
  printf '%s' "$d"
}

run() {
  # $1=out-file, rest is the command. Never let the guard's own exit abort this suite under set -e.
  local out="$1"; shift
  set +e
  "$@" > "$out" 2>&1
  RC=$?
  set -e
}

# ---------------------------------------------------------------------------- (a) bad arguments
d=$(new_repo_with_origin repo-a)
run "$WORK/out.a1" "$REWIND" -C "$d" main
[ "$RC" -eq 2 ] || { echo "FAIL: (a1) missing <branch> should refuse (2), got $RC"; cat "$WORK/out.a1"; exit 1; }
grep -qF 'usage: rewind-default.sh' "$WORK/out.a1" || { echo "FAIL: (a1) refusal carries no usage line"; exit 1; }
run "$WORK/out.a2" "$REWIND" -C /nope main fix/x
[ "$RC" -eq 2 ] || { echo "FAIL: (a2) an unreadable -C path should refuse (2), got $RC"; exit 1; }
echo "ok   (a) bad/unreadable arguments refuse with 2 and print the usage line"

# ---------------------------------------------------------------------------- (b) HEAD is <default>
d=$(new_repo_with_origin repo-b)
before=$(git -C "$d" rev-parse main)
run "$WORK/out.b" "$REWIND" -C "$d" main fix/never-created
[ "$RC" -eq 2 ] || { echo "FAIL: (b) HEAD still on main should refuse (2), got $RC"; cat "$WORK/out.b"; exit 1; }
grep -qF 'still' "$WORK/out.b" || { echo "FAIL: (b) refusal does not explain HEAD is still the default"; exit 1; }
after=$(git -C "$d" rev-parse main)
[ "$before" = "$after" ] || { echo "FAIL: (b) main moved despite the refusal"; exit 1; }
echo "ok   (b) HEAD on the default branch itself refuses (2), default untouched"

# ---------------------------------------------------------------------------- (c) detached HEAD
d=$(new_repo_with_origin repo-c)
before=$(git -C "$d" rev-parse main)
git -C "$d" checkout -q --detach main
run "$WORK/out.c" "$REWIND" -C "$d" main fix/never-created
[ "$RC" -eq 2 ] || { echo "FAIL: (c) detached HEAD should refuse (2), got $RC"; cat "$WORK/out.c"; exit 1; }
grep -qF 'detached' "$WORK/out.c" || { echo "FAIL: (c) refusal does not name the detached HEAD"; exit 1; }
after=$(git -C "$d" rev-parse main)
[ "$before" = "$after" ] || { echo "FAIL: (c) main moved despite the refusal"; exit 1; }
echo "ok   (c) a detached HEAD refuses (2), default untouched"

# ---------------------------------------------------------------------------- (d) the pushed branch lacks main's newest commit
d=$(new_repo_with_origin repo-d)
# fix/x branches BEFORE main's newest commit, so it will lack it once main advances.
git -C "$d" branch fix/x main
echo advance > "$d/advance.txt"
git -C "$d" add advance.txt
git -C "$d" commit -q -m "main advances (never pushed)"
before=$(git -C "$d" rev-parse main)
git -C "$d" checkout -q fix/x
git -C "$d" push -q -u origin fix/x
run "$WORK/out.d" "$REWIND" -C "$d" main fix/x
[ "$RC" -eq 3 ] || { echo "FAIL: (d) a pushed branch lacking main's tip should refuse (3), got $RC"; cat "$WORK/out.d"; exit 1; }
after=$(git -C "$d" rev-parse main)
[ "$before" = "$after" ] || { echo "FAIL: (d) main moved despite the refusal"; exit 1; }
echo "ok   (d) origin/<branch> lacking <default>'s tip refuses (3), default untouched"

# ---------------------------------------------------------------------------- (e) the happy path
d=$(new_repo_with_origin repo-e)
origin_main_before=$(git -C "$d" rev-parse origin/main)
echo fix > "$d/fix.txt"
git -C "$d" add fix.txt
git -C "$d" commit -q -m "a fix committed on main (never pushed)"
main_tip=$(git -C "$d" rev-parse main)
git -C "$d" checkout -q -b fix/y
git -C "$d" push -q -u origin fix/y
run "$WORK/out.e" "$REWIND" -C "$d" main fix/y
[ "$RC" -eq 0 ] || { echo "FAIL: (e) the happy path should exit 0, got $RC"; cat "$WORK/out.e"; exit 1; }
grep -qF "REWOUND main $main_tip -> $origin_main_before" "$WORK/out.e" \
  || { echo "FAIL: (e) missing/wrong REWOUND receipt"; cat "$WORK/out.e"; exit 1; }
main_after=$(git -C "$d" rev-parse main)
[ "$main_after" = "$origin_main_before" ] || { echo "FAIL: (e) main did not end up at origin/main ($main_after != $origin_main_before)"; exit 1; }
fix_y_after=$(git -C "$d" rev-parse fix/y)
[ "$fix_y_after" = "$main_tip" ] || { echo "FAIL: (e) fix/y lost the commit it was pushed with"; exit 1; }
echo "ok   (e) default rewound to origin/<default> once the pushed branch proves it carries it; branch keeps its commit"

echo "rewind-default golden test OK"
