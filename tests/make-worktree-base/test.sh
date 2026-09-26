#!/usr/bin/env bash
# Golden test for make-worktree.sh's base-branch resolution (#678).
#
# The incident this pins: BASE_BRANCH was hardcoded to `main` and branched off the LOCAL ref,
# without a fetch. On FormCraft (default branch `dev`, no `main` on origin, a 13-month-stale local
# `main`), the worker's worktree started from an ancient, unrelated commit — silently, since
# `git worktree add -b … main` only fails when `main` is entirely absent. Every case below drives
# make-worktree.sh against a fixture shaped like that incident, or its regression boundary.
set -euo pipefail
cd "$(dirname "$0")/../.."

HELPER="./skills/implement-issue/scripts/make-worktree.sh"
[ -x "$HELPER" ] || { echo "FAIL: $HELPER missing or not executable"; exit 1; }
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot read $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
WORK=$(kit_scratch)

IGNORE_LINES='.claude/worktrees/
.worktrees/
'

# A bare "remote" whose default branch is $2, seeded with one commit on it so a clone actually
# sets refs/remotes/origin/HEAD — an empty branch clones with nothing for HEAD to point at.
make_bare_remote() {
  local bare="$1" default_branch="$2" seed
  seed=$(kit_scratch)
  git init -q -b "$default_branch" "$seed"
  git -C "$seed" config user.email t@example.com
  git -C "$seed" config user.name "Golden Test"
  printf '%s' "$IGNORE_LINES" > "$seed/.gitignore"
  printf 'x\n' > "$seed/f.txt"
  git -C "$seed" add -A
  git -C "$seed" commit -qm base
  git init -q --bare "$bare"
  git -C "$seed" push -q "$bare" "$default_branch"
  git -C "$bare" symbolic-ref HEAD "refs/heads/$default_branch"
}

# ---------------------------------------------------------------- 1-3. dev default, stale local
# main, a remote commit pushed after the clone

bare="$WORK/bare-dev.git"
make_bare_remote "$bare" dev

clone="$WORK/clone-dev"
git clone -q "$bare" "$clone"

# AC1: resolved off origin/dev with NO local `main` at all yet — isolated from AC2 below (its own
# branch name, run before the stale local `main` is ever created), so a regression that only shows
# up in the absence of a local `main` can't hide behind AC2's fixture always supplying one.
BRANCH0="feat/0-no-local-main-at-all"
git -C "$clone" show-ref --quiet refs/heads/main \
  && { echo "FAIL [dev-default]: setup bug — local main already exists before AC1 runs"; exit 1; }
out0=$("$KIT/$HELPER" -C "$clone" "$BRANCH0")
printf '%s\n' "$out0" | grep -qF 'BASE=origin/dev' \
  || { echo "FAIL [dev-default]: (AC1) no BASE=origin/dev line:"; echo "$out0"; exit 1; }
wt0=$(printf '%s\n' "$out0" | sed -n 's/^WORKTREE=//p')
head0=$(git -C "$wt0" rev-parse "$BRANCH0^{commit}")
dev_tip_at_clone=$(git -C "$clone" rev-parse origin/dev)
[ "$head0" = "$dev_tip_at_clone" ] \
  || { echo "FAIL [dev-default]: (AC1) expected $BRANCH0 at origin/dev's tip, got $head0"; exit 1; }
echo "  ok: dev-default (AC1) — no local main at all, resolves cleanly off origin/dev"

git -C "$clone" branch -q main   # NOW add it: AC2's stale local `main`, sitting beside `dev`

# AC3: a commit pushed to the remote's dev AFTER the clone must still be included — the fetch has
# to actually run, not just trust whatever refs/remotes/origin/dev already held at clone time.
push_seed="$WORK/push-seed"
git clone -q "$bare" "$push_seed"
printf 'y\n' > "$push_seed/g.txt"
git -C "$push_seed" add -A
git -C "$push_seed" -c user.email=t@example.com -c user.name="Golden Test" commit -qm second
git -C "$push_seed" push -q origin dev
remote_tip=$(git -C "$push_seed" rev-parse dev)

BRANCH1="feat/1-dev-default"
out=$("$KIT/$HELPER" -C "$clone" "$BRANCH1")

printf '%s\n' "$out" | grep -q '^WORKTREE=' \
  || { echo "FAIL [dev-default]: no WORKTREE= line:"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -qF 'BASE=origin/dev' \
  || { echo "FAIL [dev-default]: no BASE=origin/dev line:"; echo "$out"; exit 1; }

wt1=$(printf '%s\n' "$out" | sed -n 's/^WORKTREE=//p')
head1=$(git -C "$wt1" rev-parse "$BRANCH1^{commit}")
[ "$head1" = "$remote_tip" ] \
  || { echo "FAIL [dev-default]: expected $BRANCH1 at origin/dev's tip ($remote_tip), got $head1"; exit 1; }

echo "  ok: dev-default (AC2+AC3) — a stale local main and a post-clone remote commit don't fool it; BASE=origin/dev, at the real tip"

# ---------------------------------------------------------------- 4. --base override

fx_clone="$WORK/fx-seed"
git clone -q "$bare" "$fx_clone"
git -C "$fx_clone" checkout -q -b feature/x
printf 'z\n' > "$fx_clone/h.txt"
git -C "$fx_clone" add -A
git -C "$fx_clone" -c user.email=t@example.com -c user.name="Golden Test" commit -qm feature
git -C "$fx_clone" push -q origin feature/x
fx_tip=$(git -C "$fx_clone" rev-parse feature/x)

BRANCH4="feat/4-base-override"
out=$("$KIT/$HELPER" -C "$clone" --base feature/x "$BRANCH4")
printf '%s\n' "$out" | grep -qF 'BASE=origin/feature/x' \
  || { echo "FAIL [base-override]: no BASE=origin/feature/x line:"; echo "$out"; exit 1; }
wt4=$(printf '%s\n' "$out" | sed -n 's/^WORKTREE=//p')
head4=$(git -C "$wt4" rev-parse "$BRANCH4^{commit}")
[ "$head4" = "$fx_tip" ] \
  || { echo "FAIL [base-override]: expected $BRANCH4 at feature/x's tip ($fx_tip), got $head4 (not the resolved default dev)"; exit 1; }

echo "  ok: base-override — --base feature/x creates off origin/feature/x, not the resolved default"

# ---------------------------------------------------------------- 5. no source resolves → refuse

emptyBare="$WORK/empty-origin.git"
git init -q --bare "$emptyBare"   # no commits, no branches: HEAD advertises nothing at all

caseNoSource="$WORK/case-no-source"
git init -q -b main "$caseNoSource"
git -C "$caseNoSource" config user.email t@example.com
git -C "$caseNoSource" config user.name "Golden Test"
printf '%s' "$IGNORE_LINES" > "$caseNoSource/.gitignore"
git -C "$caseNoSource" add -A
git -C "$caseNoSource" commit -qm base
# An origin IS configured (so there is something to disagree with) but it is empty — `ls-remote
# --symref` advertises nothing, `refs/remotes/origin/HEAD` was never fetched either, and the
# tracker call fails offline (a local path, not a known GitHub host) — so nothing resolves a name.
git -C "$caseNoSource" remote add origin "$emptyBare"

BRANCH5="feat/5-no-source"
wt_count_before=$(git -C "$caseNoSource" worktree list --porcelain | grep -c '^worktree ')

rc=0
out=$("$KIT/$HELPER" -C "$caseNoSource" "$BRANCH5" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [no-source]: expected exit 2, got $rc"; echo "$out"; exit 1; }

[ ! -e "$caseNoSource/.claude/worktrees/$BRANCH5" ] \
  || { echo "FAIL [no-source]: a worktree directory was left on disk despite the refusal"; exit 1; }
git -C "$caseNoSource" show-ref --quiet "refs/heads/$BRANCH5" \
  && { echo "FAIL [no-source]: the branch was created despite the refusal"; exit 1; }
wt_count_after=$(git -C "$caseNoSource" worktree list --porcelain | grep -c '^worktree ')
[ "$wt_count_before" -eq "$wt_count_after" ] \
  || { echo "FAIL [no-source]: git worktree list grew despite the refusal"; exit 1; }

echo "  ok: no-source — no --base, no tracker verdict, no origin/HEAD, an origin that disagrees by existing: exit 2, nothing left behind"

# ---------------------------------------------------------------- 6. an ordinary main-default
# repo behaves the same as before (AC6 / regression boundary)

bare_main="$WORK/bare-main.git"
make_bare_remote "$bare_main" main
clone_main="$WORK/clone-main"
git clone -q "$bare_main" "$clone_main"
main_tip=$(git -C "$clone_main" rev-parse origin/main)

BRANCH6="feat/6-main-default"
out=$("$KIT/$HELPER" -C "$clone_main" "$BRANCH6")
printf '%s\n' "$out" | grep -qF 'BASE=origin/main' \
  || { echo "FAIL [main-default]: no BASE=origin/main line:"; echo "$out"; exit 1; }
wt6=$(printf '%s\n' "$out" | sed -n 's/^WORKTREE=//p')
head6=$(git -C "$wt6" rev-parse "$BRANCH6^{commit}")
[ "$head6" = "$main_tip" ] \
  || { echo "FAIL [main-default]: expected $BRANCH6 at origin/main's tip ($main_tip), got $head6"; exit 1; }

echo "  ok: main-default — an ordinary main-default repo still resolves cleanly, off origin/main"

echo "make-worktree-base golden test OK"
