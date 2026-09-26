#!/usr/bin/env bash
# Golden test for release-branch.sh — the supervisor frees a PR branch that a retired worker's
# worktree still has checked out, before any re-dispatch onto it (#510).
#
# The incident this pins: one auto-dev run dispatched onto an existing PR branch twice — a PARTIAL
# resume, then a restart after the supervisor's session crashed — and both workers came back
# BLOCKED without changing a line. `isolation: "worktree"` put each one in a fresh tree, `git
# switch <branch>` there was refused ("already used by worktree at …") because the first worker's
# tree still held the branch, and the worker's sandbox refused every git command naming that tree.
#
# Every case builds a real scratch repository — no git stub — with a holder worktree locked the way
# the harness locks one, runs the script, and asserts its verdict line, its exit code and what
# `git worktree list --porcelain` says afterwards. Expected values are literals written here, never
# re-derived from the script.
set -euo pipefail
cd "$(dirname "$0")/../.."

HELPER="./skills/auto-dev/scripts/release-branch.sh"
[ -x "$HELPER" ] || { echo "FAIL: $HELPER missing or not executable"; exit 1; }
KIT="$PWD"
GUARDED_COMMIT="$KIT/skills/implement-issue/scripts/guarded-commit.sh"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
kit_guard kit_guard_samples_unchanged

# Physical spelling, once: macOS answers mktemp under /var, a symlink to /private/var, and git
# records the path it is handed — so every literal below is built from the resolved root.
WORK=$(CDPATH= cd -- "$(kit_scratch)" && pwd -P)

BR="feat/1-x"
LOCK_REASON="claude agent agent-a (pid 99999999)"

fail() { echo "FAIL [$1]: $2"; exit 1; }

# new_repo <dir> — a main checkout on `main` with one commit, pushed to a bare `origin` beside it.
new_repo() {
  local dir="$1"
  # `-b main` on the BARE side too (#678, via-make-worktree): otherwise its HEAD symref follows
  # whatever this host's own `init.defaultBranch` happens to be, which `main` is pushed to below
  # regardless of that name — a divergence make-worktree.sh now resolves against and refuses on
  # (`git ls-remote --symref` advertises nothing for a HEAD pointing at a branch that was never
  # pushed), where the old hardcoded `BASE_BRANCH=main` never looked at the remote's HEAD at all.
  git init -q --bare -b main "$dir-origin.git"
  git init -q -b main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name "Golden Test"
  printf 'base\n' > "$dir/tracked.txt"
  printf '.claude/worktrees/\n.worktrees/\n' > "$dir/.gitignore"   # both homes, as make-worktree.sh proves
  git -C "$dir" add -A
  git -C "$dir" commit -qm base
  git -C "$dir" remote add origin "$dir-origin.git"
  git -C "$dir" push -q origin main
}

# add_holder <repo> <path> — a retired worker's tree: on $BR, one commit of its own, pushed, and
# locked the way the harness locks an isolated agent's tree.
add_holder() {
  local repo="$1" holder="$2"
  git -C "$repo" worktree add -q -b "$BR" "$holder" main
  printf 'work\n' >> "$holder/tracked.txt"
  git -C "$holder" commit -qam "work on $BR"
  git -C "$holder" push -q -u origin "$BR"
  git -C "$repo" worktree lock --reason "$LOCK_REASON" "$holder"
}

# run_helper <args…> — sets $rc, $out (stdout) and $err (stderr) for the assertions that follow.
run_helper() {
  rc=0
  "$KIT/$HELPER" "$@" > "$WORK/stdout" 2> "$WORK/stderr" || rc=$?
  out=$(cat "$WORK/stdout")
  err=$(cat "$WORK/stderr")
}

# record_of <repo> <path> — that worktree's porcelain record (worktree / HEAD / branch|detached / locked).
record_of() {
  local list
  list=$(git -C "$1" worktree list --porcelain)
  printf '%s\n' "$list" | awk -v p="worktree $2" '$0 == p { on = 1 } on && $0 == "" { on = 0 } on { print }'
}

# on_branch <path> — true while that tree's HEAD is still refs/heads/$BR.
on_branch() {
  [ "$(git -C "$1" symbolic-ref -q HEAD 2>/dev/null || true)" = "refs/heads/$BR" ]
}

# ---------------------------------------------------------------- 1. FREE (AC1)
#
# The branch exists but no tree has it checked out, and a sibling tree holds a branch whose name
# EXTENDS it — the substring trap make-worktree.sh's exact match exists for.
c1="$WORK/free"
new_repo "$c1"
git -C "$c1" branch "$BR"
git -C "$c1" worktree add -q -b "$BR-longer" "$WORK/free-sibling" main
git -C "$c1" worktree list --porcelain > "$WORK/free.before"
run_helper -C "$c1" "$BR"
[ "$rc" -eq 0 ] || fail free "expected exit 0, got $rc; stderr: $err"
[ "$out" = "FREE" ] || fail free "expected 'FREE', got '$out'"
git -C "$c1" worktree list --porcelain > "$WORK/free.after"
cmp -s "$WORK/free.before" "$WORK/free.after" \
  || fail free "git worktree list --porcelain changed on a FREE verdict:
$(diff "$WORK/free.before" "$WORK/free.after" || true)"
echo "  ok: free — FREE, exit 0, porcelain byte-identical; a holder of '$BR-longer' is not a match"

# ---------------------------------------------------------------- 2. RELEASED (AC2)
#
# The #1329 shape: a clean, pushed, harness-locked holder, and a second tree that cannot switch to
# the branch until the holder lets go. The holder's path carries a space, and it holds an untracked
# file — which is neither dirty nor lost.
c2="$WORK/released"
new_repo "$c2"
mkdir -p "$WORK/released trees"
h2="$WORK/released trees/agent a"
add_holder "$c2" "$h2"
printf 'note\n' > "$h2/untracked-note.txt"
sha2=$(git -C "$h2" rev-parse HEAD)
adopter2="$WORK/released-adopter"
git -C "$c2" worktree add -q -b worktree-agent-b "$adopter2" main
if git -C "$adopter2" switch -q "$BR" 2>/dev/null; then
  fail released "precondition: a second tree could switch to $BR while the holder had it — the fixture does not reproduce the wall"
fi

run_helper -C "$c2" "$BR"
[ "$rc" -eq 0 ] || fail released "expected exit 0, got $rc; stdout: $out; stderr: $err"
[ "$out" = "RELEASED $h2" ] || fail released "expected 'RELEASED $h2', got '$out'"
rec2=$(record_of "$c2" "$h2")
grep -qx 'detached' <<<"$rec2" || fail released "the holder is not detached:
$rec2"
grep -qx "HEAD $sha2" <<<"$rec2" || fail released "the holder's HEAD moved off $sha2:
$rec2"
grep -qxF "locked $LOCK_REASON" <<<"$rec2" || fail released "the holder lost its lock:
$rec2"
[ -f "$h2/untracked-note.txt" ] || fail released "the holder's untracked file is gone"
git -C "$adopter2" switch -q "$BR" || fail released "a second tree still cannot switch to $BR after RELEASED"
echo "  ok: released — RELEASED, exit 0; holder detached at the same sha, still locked, untracked file kept; a second tree's git switch succeeds"

# ---------------------------------------------------------------- 3. HELD — nothing is stranded (AC3)
#
# Each holder carries something the kit must not discard. Every HELD exits 1 and leaves the holder
# on the branch.
c3="$WORK/dirty"
new_repo "$c3"
h3="$WORK/dirty-holder"
add_holder "$c3" "$h3"
printf 'uncommitted\n' >> "$h3/tracked.txt"
run_helper -C "$c3" "$BR"
[ "$rc" -eq 1 ] || fail dirty "expected exit 1, got $rc; stdout: $out; stderr: $err"
[ "$out" = "HELD $h3 dirty" ] || fail dirty "expected 'HELD $h3 dirty', got '$out'"
on_branch "$h3" || fail dirty "the holder was moved off $BR"
grep -qx 'uncommitted' "$h3/tracked.txt" || fail dirty "the holder's uncommitted edit is gone"
echo "  ok: dirty — HELD dirty, exit 1; holder still on $BR with its edit"

c4="$WORK/unpushed"
new_repo "$c4"
h4="$WORK/unpushed-holder"
add_holder "$c4" "$h4"
printf 'more\n' >> "$h4/tracked.txt"
git -C "$h4" commit -qam "not pushed yet"
run_helper -C "$c4" "$BR"
[ "$rc" -eq 1 ] || fail unpushed "expected exit 1, got $rc; stdout: $out; stderr: $err"
[ "$out" = "HELD $h4 unpushed 1" ] || fail unpushed "expected 'HELD $h4 unpushed 1', got '$out'"
on_branch "$h4" || fail unpushed "the holder was moved off $BR"
echo "  ok: unpushed — HELD unpushed 1, exit 1; holder still on $BR"

# Never pushed at all: there is no origin/<branch> to be contained in, so the count is HEAD's full
# history — the base commit plus the worker's one.
c5="$WORK/never-pushed"
new_repo "$c5"
h5="$WORK/never-pushed-holder"
git -C "$c5" worktree add -q -b "$BR" "$h5" main
printf 'work\n' >> "$h5/tracked.txt"
git -C "$h5" commit -qam "work on $BR"
run_helper -C "$c5" "$BR"
[ "$rc" -eq 1 ] || fail never-pushed "expected exit 1, got $rc; stdout: $out; stderr: $err"
[ "$out" = "HELD $h5 unpushed 2" ] || fail never-pushed "expected 'HELD $h5 unpushed 2', got '$out'"
on_branch "$h5" || fail never-pushed "the holder was moved off $BR"
echo "  ok: never-pushed — HELD unpushed 2 (no origin/$BR), exit 1; holder still on $BR"

# The user's own checkout is never detached, however clean and pushed it is.
c6="$WORK/main-checkout"
new_repo "$c6"
git -C "$c6" switch -q -c "$BR"
git -C "$c6" push -q -u origin "$BR"
run_helper -C "$c6" "$BR"
[ "$rc" -eq 1 ] || fail main-checkout "expected exit 1, got $rc; stdout: $out; stderr: $err"
[ "$out" = "HELD $c6 main-checkout" ] || fail main-checkout "expected 'HELD $c6 main-checkout', got '$out'"
on_branch "$c6" || fail main-checkout "the main checkout was moved off $BR"
echo "  ok: main-checkout — HELD main-checkout, exit 1; the main checkout still on $BR"

# git still lists a holder whose directory is gone (a lock keeps the record from being pruned).
c7="$WORK/missing"
new_repo "$c7"
h7="$WORK/missing-holder"
add_holder "$c7" "$h7"
rm -rf "$h7"
run_helper -C "$c7" "$BR"
[ "$rc" -eq 1 ] || fail missing "expected exit 1, got $rc; stdout: $out; stderr: $err"
[ "$out" = "HELD $h7 missing" ] || fail missing "expected 'HELD $h7 missing', got '$out'"
list7=$(git -C "$c7" worktree list --porcelain)
grep -qxF "worktree $h7" <<<"$list7" || fail missing "the holder's record was pruned — only the housekeeping sweep removes"
echo "  ok: missing — HELD missing, exit 1; the record is surfaced, not pruned"

# ---------------------------------------------------------------- 4. a holder that is no longer a worktree
#
# The directory is there but its `.git` link is gone, and it sits INSIDE the main checkout the way
# `.claude/worktrees/<name>` does. Any git command run there walks up to the enclosing checkout —
# the #469 walk-up — so a release that trusted it would detach the USER'S checkout. It has to
# refuse instead, with no verdict, and leave the main checkout on its branch.
c8="$WORK/walk-up"
new_repo "$c8"
mkdir -p "$c8/.claude/worktrees"
h8="$c8/.claude/worktrees/agent-c"
add_holder "$c8" "$h8"
rm -f "$h8/.git"
run_helper -C "$c8" "$BR"
[ "$rc" -eq 2 ] || fail walk-up "expected exit 2 (no verdict), got $rc; stdout: $out; stderr: $err"
[ -z "$out" ] || fail walk-up "a no-verdict run printed a verdict: '$out'"
grep -qF 'release-branch: REFUSED —' <<<"$err" || fail walk-up "stderr does not carry the REFUSED line: $err"
# The toplevel check has to be what stopped it. The branch check behind it would also refuse here
# (the enclosing checkout is on main), so without this line the case stays green with the one check
# it exists for deleted.
grep -qF 'walked up to an enclosing checkout' <<<"$err" \
  || fail walk-up "the refusal is not the walk-up diagnosis, so the toplevel check did not stop it: $err"
[ "$(git -C "$c8" symbolic-ref -q HEAD || true)" = "refs/heads/main" ] \
  || fail walk-up "the enclosing main checkout was moved off main"
echo "  ok: walk-up — exit 2, no verdict; the enclosing main checkout is still on main"

# ---------------------------------------------------------------- 5. the #469 record (AC4)
#
# make-worktree.sh records each tree's path under kit.worktree.<branch>.path, and
# assert_worktree_live refuses a guarded write from any other tree on that branch. A release that
# left the record naming the old holder would therefore stop the adopting worker at its first
# commit — so the record goes with the branch. One naming some other tree is not ours to touch.
c9="$WORK/record"
new_repo "$c9"
h9="$WORK/record-holder"
add_holder "$c9" "$h9"
git -C "$c9" config "kit.worktree.$BR.path" "$h9"
run_helper -C "$c9" "$BR"
{ [ "$rc" -eq 0 ] && [ "$out" = "RELEASED $h9" ]; } \
  || fail record "expected 'RELEASED $h9' with exit 0, got '$out' with exit $rc; stderr: $err"
if left=$(git -C "$c9" config --get "kit.worktree.$BR.path"); then
  fail record "kit.worktree.$BR.path still names the released holder: $left"
fi
a9="$WORK/record-adopter"
git -C "$c9" worktree add -q -b worktree-agent-b "$a9" main
git -C "$a9" switch -q "$BR"
gc_rc=0
"$GUARDED_COMMIT" -C "$a9" "$BR" -- --allow-empty -qm "adopted after release" > "$WORK/gc.out" 2>&1 || gc_rc=$?
[ "$gc_rc" -eq 0 ] || fail record "guarded-commit.sh from the adopting tree exited $gc_rc:
$(cat "$WORK/gc.out")"
echo "  ok: record — the record naming the holder is unset; guarded-commit.sh from the adopting tree succeeds"

c10="$WORK/foreign"
new_repo "$c10"
h10="$WORK/foreign-holder"
add_holder "$c10" "$h10"
other10="$WORK/some-other-tree"
git -C "$c10" config "kit.worktree.$BR.path" "$other10"
run_helper -C "$c10" "$BR"
{ [ "$rc" -eq 0 ] && [ "$out" = "RELEASED $h10" ]; } \
  || fail foreign "expected 'RELEASED $h10' with exit 0, got '$out' with exit $rc; stderr: $err"
[ "$(git -C "$c10" config --get "kit.worktree.$BR.path" || true)" = "$other10" ] \
  || fail foreign "a record naming another tree was changed"
echo "  ok: foreign — a record naming another tree is left unchanged"

# A failing post-checkout hook: `git switch` returns the hook's status AFTER it has detached HEAD,
# so its exit code is not the verdict — the read-back is. Released, record gone, and the warning
# proves the non-zero path was the one taken.
c12="$WORK/hook"
new_repo "$c12"
h12="$WORK/hook-holder"
add_holder "$c12" "$h12"
git -C "$c12" config "kit.worktree.$BR.path" "$h12"
sha12=$(git -C "$h12" rev-parse HEAD)
mkdir -p "$c12/.git/hooks"
printf '#!/bin/sh\nexit 1\n' > "$c12/.git/hooks/post-checkout"
chmod +x "$c12/.git/hooks/post-checkout"
run_helper -C "$c12" "$BR"
{ [ "$rc" -eq 0 ] && [ "$out" = "RELEASED $h12" ]; } \
  || fail hook "expected 'RELEASED $h12' with exit 0 despite the failing hook, got '$out' with exit $rc; stderr: $err"
grep -qF 'git switch exited' <<<"$err" || fail hook "no warning that git switch exited non-zero — the hook path was not exercised: $err"
rec12=$(record_of "$c12" "$h12")
{ grep -qx 'detached' <<<"$rec12" && grep -qx "HEAD $sha12" <<<"$rec12"; } \
  || fail hook "the holder is not detached at $sha12:
$rec12"
if left=$(git -C "$c12" config --get "kit.worktree.$BR.path"); then
  fail hook "kit.worktree.$BR.path still names the released holder: $left"
fi
echo "  ok: hook — a failing post-checkout hook does not undo the release; the read-back decides"

# The record cannot be unset (a stale config.lock): RELEASED would then send the adopting worker
# straight into assert_worktree_live's refusal, so it is no verdict instead — and nothing changed.
c13="$WORK/unset-fails"
new_repo "$c13"
h13="$WORK/unset-fails-holder"
add_holder "$c13" "$h13"
git -C "$c13" config "kit.worktree.$BR.path" "$h13"
: > "$c13/.git/config.lock"
run_helper -C "$c13" "$BR"
rm -f "$c13/.git/config.lock"
[ "$rc" -eq 2 ] || fail unset-fails "expected exit 2, got $rc; stdout: $out; stderr: $err"
[ -z "$out" ] || fail unset-fails "a no-verdict run printed a verdict: '$out'"
on_branch "$h13" || fail unset-fails "the holder was detached although the record could not be unset"
[ "$(git -C "$c13" config --get "kit.worktree.$BR.path" || true)" = "$h13" ] \
  || fail unset-fails "the record naming the holder changed"
echo "  ok: unset-fails — a record that cannot be unset is no verdict; the holder stays on $BR"

# The record make-worktree.sh really writes. Every case above writes kit.worktree.<branch>.path by
# hand; this one lets make-worktree.sh build the holder in its real home (.claude/worktrees/<branch>)
# and write the record itself, then runs the release the way SKILL.md Step 3 does — from the
# checkout, with no -C. A key renamed in the writer and the reader but not here turns this red.
c14="$WORK/via-make-worktree"
new_repo "$c14"
mw_out=$("$KIT/skills/implement-issue/scripts/make-worktree.sh" -C "$c14" "$BR" 2>&1) \
  || fail via-make-worktree "make-worktree.sh refused the fixture: $mw_out"
h14=$(printf '%s\n' "$mw_out" | sed -n 's/^WORKTREE=//p')
[ -d "$h14" ] || fail via-make-worktree "make-worktree.sh printed no usable WORKTREE= line: $mw_out"
[ -n "$(git -C "$c14" config --get "kit.worktree.$BR.path" || true)" ] \
  || fail via-make-worktree "precondition: make-worktree.sh wrote no kit.worktree.$BR.path record"
printf 'work\n' >> "$h14/tracked.txt"
git -C "$h14" commit -qam "work on $BR"
git -C "$h14" push -q -u origin "$BR"
git -C "$c14" worktree lock --reason "$LOCK_REASON" "$h14"
rc=0
( cd "$c14" && "$KIT/$HELPER" "$BR" ) > "$WORK/stdout" 2> "$WORK/stderr" || rc=$?
out=$(cat "$WORK/stdout")
err=$(cat "$WORK/stderr")
{ [ "$rc" -eq 0 ] && [ "$out" = "RELEASED $h14" ]; } \
  || fail via-make-worktree "expected 'RELEASED $h14' with exit 0, got '$out' with exit $rc; stderr: $err"
if left=$(git -C "$c14" config --get "kit.worktree.$BR.path"); then
  fail via-make-worktree "the record make-worktree.sh wrote still names the released holder: $left"
fi
a14="$WORK/via-make-worktree-adopter"
git -C "$c14" worktree add -q -b worktree-agent-b "$a14" main
git -C "$a14" switch -q "$BR"
gc_rc=0
"$GUARDED_COMMIT" -C "$a14" "$BR" -- --allow-empty -qm "adopted after release" > "$WORK/gc.out" 2>&1 || gc_rc=$?
[ "$gc_rc" -eq 0 ] || fail via-make-worktree "guarded-commit.sh from the adopting tree exited $gc_rc:
$(cat "$WORK/gc.out")"
echo "  ok: via-make-worktree — a make-worktree.sh holder is released from the checkout with no -C; its own record goes; guarded-commit.sh adopts"

# ---------------------------------------------------------------- 6. no verdict (AC5)
#
# A bad invocation answers nothing: exit 2, the REFUSED line on stderr, nothing on stdout — and
# nothing changed, least of all the holder it never got as far as reading.
c11="$WORK/refuse"
new_repo "$c11"
h11="$WORK/refuse-holder"
add_holder "$c11" "$h11"
git -C "$c11" worktree list --porcelain > "$WORK/refuse.before"
nonrepo="$WORK/not-a-repo"
mkdir -p "$nonrepo"
if git -C "$nonrepo" rev-parse --git-dir >/dev/null 2>&1; then
  fail refuse "precondition: $nonrepo sits inside a git repository, so it cannot stand for 'not a repository'"
fi

expect_refusal() {   # <label> <args…>
  local label="$1"; shift
  run_helper "$@"
  [ "$rc" -eq 2 ] || fail "refuse/$label" "expected exit 2, got $rc; stdout: $out; stderr: $err"
  [ -z "$out" ] || fail "refuse/$label" "a refusal printed a verdict on stdout: '$out'"
  grep -qF 'release-branch: REFUSED —' <<<"$err" \
    || fail "refuse/$label" "stderr does not carry 'release-branch: REFUSED —': $err"
}
expect_refusal unknown-option -C "$c11" --bogus "$BR"
expect_refusal missing-branch -C "$c11"
expect_refusal c-without-path -C
expect_refusal extra-argument -C "$c11" "$BR" extra
expect_refusal not-a-repo -C "$nonrepo" "$BR"
git -C "$c11" worktree list --porcelain > "$WORK/refuse.after"
cmp -s "$WORK/refuse.before" "$WORK/refuse.after" \
  || fail refuse "a refused invocation changed git worktree list --porcelain"
on_branch "$h11" || fail refuse "a refused invocation moved the holder off $BR"
echo "  ok: refuse — unknown option, missing branch, -C without a path, an extra argument and a non-repository -C each exit 2 and change nothing"

# ---------------------------------------------------------------- 7. the contract, by construction
help=$("$KIT/$HELPER" --help)
grep -qF 'Exit codes:' <<<"$help" || fail help "--help does not print the 'Exit codes:' contract"

# The housekeeping sweep is the only remover: no line of code in the script removes, unlocks or
# prunes a worktree. Comment lines are skipped, because the header says in prose that it never does.
if grep -v '^[[:space:]]*#' "$KIT/$HELPER" | grep -nE 'worktree[[:space:]]+(remove|unlock|prune)'; then
  fail source "release-branch.sh runs a worktree remove/unlock/prune — the housekeeping sweep is the only remover"
fi
echo "  ok: contract — --help prints 'Exit codes:', and no code line removes, unlocks or prunes a worktree"

echo "PASS: release-branch"
