#!/usr/bin/env bash
# Golden test for main-worktree.sh — the one home for "this repository's main working tree".
#
# Written fail-path-first (tests/_lib.sh for scratch/cleanup), the same shape as
# tests/worktrees-ignored/test.sh cases 23a-23c, which is where this recipe used to live inline —
# duplicated once per caller until #125 gave it a script of its own. The cases below are exactly
# the layouts that broke a caller-spelled version of the same derivation:
#   * a linked worktree answering with itself instead of the main checkout (fail-open, #125)
#   * a bare repository's first porcelain record being fed to callers that cannot use it
#   * a path containing a space, truncated by an `awk '{print $2}'` spelling (#125, merge-mechanics)
set -euo pipefail
cd "$(dirname "$0")/../.."

HELPER="./scripts/main-worktree.sh"
[ -x "$HELPER" ] || { echo "FAIL: $HELPER missing or not executable"; exit 1; }
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
WORK=$(kit_scratch)

# A throwaway repo with one commit, so `worktree add` has something to branch from.
init_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name "Golden Test"
  printf 'x\n' > "$dir/tracked.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -qm base
}

# ---------------------------------------------------------------- 1. normal layout

rec="$WORK/rec"
init_repo "$rec"
git -C "$rec" worktree add -q .claude/worktrees/feat -b feat
rec_phys=$(cd "$rec" && pwd -P)   # git reports resolved paths; macOS /var -> /private/var

out=$("$KIT/$HELPER" -C "$rec")
[ "$out" = "$rec_phys" ] || { echo "FAIL [main-checkout]: got '$out', expected '$rec_phys'"; exit 1; }
echo "  ok: main-checkout — prints the main working tree's own root"

# THE case #125 exists for: asked from inside the LINKED worktree, must still answer with the
# main checkout, not the worktree itself.
linked="$rec/.claude/worktrees/feat"
out=$("$KIT/$HELPER" -C "$linked")
[ "$out" = "$rec_phys" ] || { echo "FAIL [linked-worktree]: got '$out', expected '$rec_phys'"; exit 1; }
echo "  ok: linked-worktree — answers with the main checkout, not the worktree it was asked from"

# ---------------------------------------------------------------- 2. bare + linked worktrees

bare="$WORK/bare.git"
git init -q --bare "$bare"
git -C "$rec" push -q "$bare" main
git -C "$bare" worktree add -q "$bare/.claude/worktrees/g" main

out=$("$KIT/$HELPER" -C "$bare")
[ -z "$out" ] || { echo "FAIL [bare]: expected empty output, got '$out'"; exit 1; }
echo "  ok: bare — prints nothing (no working tree, no hazard)"

out=$("$KIT/$HELPER" -C "$bare/.claude/worktrees/g")
[ -z "$out" ] || { echo "FAIL [bare-linked]: expected empty output, got '$out'"; exit 1; }
echo "  ok: bare-linked — a worktree OF a bare repo also yields nothing"

# ---------------------------------------------------------------- 3. path containing a space

spaced="$WORK/my repo"
init_repo "$spaced"
spaced_phys=$(cd "$spaced" && pwd -P)

out=$("$KIT/$HELPER" -C "$spaced")
[ "$out" = "$spaced_phys" ] || { echo "FAIL [spaced]: got '$out', expected '$spaced_phys'"; exit 1; }
echo "  ok: spaced — a path containing a space survives intact"

# ---------------------------------------------------------------- 4. plumbing must fail closed

rc=0; "$KIT/$HELPER" -C "$WORK/does-not-exist" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || { echo "FAIL [not-a-repo]: expected exit 3, got $rc"; exit 1; }
echo "  ok: not-a-repo — exit 3, distinct from a verdict"

rc=0; "$KIT/$HELPER" -C >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || { echo "FAIL [dangling-C]: expected exit 3, got $rc"; exit 1; }
echo "  ok: dangling-C — exit 3"

rc=0; "$KIT/$HELPER" --repo /tmp >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || { echo "FAIL [bad-arg]: expected exit 3, got $rc"; exit 1; }
echo "  ok: bad-arg — exit 3"

# `git worktree list` itself can fail for a reason that has nothing to do with bareness — a
# corrupted `.git/worktrees` admin area, a pre-worktree git, a permissions error. That must also
# land on exit 3, not on `set -e` propagating whatever arbitrary status git happened to return: a
# caller checking only `[ -z "$wt_root" ]` (which the header above says is enough) cannot tell that
# apart from "verified bare, nothing to check" unless every non-bare failure is funnelled to the
# same exit code as every other "no verdict was reached" case.
STUB="$WORK/failing-bin"
MARKER="$WORK/worktree-list-was-called"
mkdir -p "$STUB"
REAL_GIT=$(command -v git)
cat > "$STUB/git" <<STUBEOF
#!/bin/sh
# Fail worktree-list only: every other git call this script and its test harness make must
# behave as usual, or the whole suite breaks rather than reproducing the one thing under test.
if [ "\$1" = "-C" ] && [ "\$3" = "worktree" ] && [ "\$4" = "list" ]; then
  echo called >> "$MARKER"
  echo "fake git: worktree list failed" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
STUBEOF
chmod +x "$STUB/git"

rc=0; out=$(PATH="$STUB:$PATH" "$KIT/$HELPER" -C "$rec" 2>/dev/null) || rc=$?
[ -s "$MARKER" ] \
  || { echo "FAIL [worktree-list-fails]: the stub git was never reached — this case reproduces nothing"; exit 1; }
[ "$rc" -eq 3 ] \
  || { echo "FAIL [worktree-list-fails]: expected exit 3 when 'git worktree list' itself fails, got $rc"; exit 1; }
[ -z "$out" ] \
  || { echo "FAIL [worktree-list-fails]: expected no stdout on a non-bare failure, got '$out'"; exit 1; }
echo "  ok: worktree-list-fails — a non-bare 'git worktree list' failure is exit 3, not a leaked status"

# ---------------------------------------------------------------- 5. --help

grep -q 'Exit codes:' <<<"$("$KIT/$HELPER" --help 2>&1)" \
  || { echo "FAIL [help]: --help does not document the exit codes"; exit 1; }
echo "  ok: help — documents the exit codes"

echo "main-worktree golden test OK"
