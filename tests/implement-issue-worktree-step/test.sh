#!/usr/bin/env bash
# Golden test for make-worktree.sh — implement-issue's Step 4, driven to red first (#280).
#
# The incident this pins: a phase-1 worker composed its own worktree-ignore check instead of
# calling the kit's, got a false "NOT ignored" verdict (git check-ignore -q without the trailing
# slash, on a directory that does not exist yet), and "fixed" it by committing a .gitignore edit
# into the MAIN checkout — e0ad515, 2026-08-27, docs/desktop-launcher. Every case below drives
# make-worktree.sh over a scratch repository shaped like one side of that incident.
set -euo pipefail
cd "$(dirname "$0")/../.."

HELPER="./skills/implement-issue/scripts/make-worktree.sh"
[ -x "$HELPER" ] || { echo "FAIL: $HELPER missing or not executable"; exit 1; }
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
WORK=$(kit_scratch)

# A throwaway repo on `main`, whose .gitignore is exactly $2 — make-worktree.sh always creates
# fresh off `main`, so every fixture needs one to branch from.
init_repo() {
  local dir="$1" gitignore="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name "Golden Test"
  printf '%b' "$gitignore" > "$dir/.gitignore"
  git -C "$dir" add -A
  git -C "$dir" commit -qm base
}

# ---------------------------------------------------------------- 1. refusal: home not ignored
#
# The state of a repo that never adopted #43's rule at all — neither worktree home is mentioned,
# so worktrees-ignored.sh's `1` fires on both. The exact spelling of the incident's OWN mistake
# (a worker's hand-rolled `check-ignore` without the trailing slash) is covered by case 2 below;
# this case is the simpler, more common way a repo can be unprotected in the first place.

caseA="$WORK/case-a"
init_repo "$caseA" 'unrelated.txt\n'
BRANCH_A="feat/1-unignored-home"

cp "$caseA/.gitignore" "$WORK/case-a.gitignore.before"
commits_before=$(git -C "$caseA" rev-list --count HEAD)

rc=0
out=$("$KIT/$HELPER" -C "$caseA" "$BRANCH_A" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [unignored-home]: expected exit 2, got $rc"; echo "$out"; exit 1; }

cmp -s "$caseA/.gitignore" "$WORK/case-a.gitignore.before" \
  || { echo "FAIL [unignored-home]: .gitignore was modified — this script must NEVER write it"; exit 1; }

commits_after=$(git -C "$caseA" rev-list --count HEAD)
[ "$commits_before" = "$commits_after" ] \
  || { echo "FAIL [unignored-home]: a commit landed in the main checkout ($commits_before -> $commits_after)"; exit 1; }

[ ! -e "$caseA/.claude/worktrees/$BRANCH_A" ] \
  || { echo "FAIL [unignored-home]: a worktree directory was left on disk despite the refusal"; exit 1; }

wt_count=$(git -C "$caseA" worktree list --porcelain | grep -c '^worktree ')
[ "$wt_count" -eq 1 ] \
  || { echo "FAIL [unignored-home]: git worktree list grew to $wt_count entries despite the refusal"; exit 1; }

echo "  ok: unignored-home — exit 2, .gitignore byte-identical, no new commit, no worktree left behind"

# The never-write invariant, in the refusal's own words (#280's Task 3): the operator must be able
# to act on the message alone, without re-deriving what to add — so the exact line has to be in
# it, verbatim, alongside the instruction that THEY add it, never this script.
grep -qF '.claude/worktrees/' <<<"$out" \
  || { echo "FAIL [unignored-home]: refusal does not name the exact .gitignore line to add:"; echo "$out"; exit 1; }
grep -qF 'Add this line yourself' <<<"$out" \
  || { echo "FAIL [unignored-home]: refusal does not tell the operator to add the line themselves:"; echo "$out"; exit 1; }

echo "  ok: unignored-home — the refusal names the exact line, and says to add it yourself"

# The other half of the same invariant: not just "does not write it in this run", but "cannot",
# by construction — the write call itself must not exist in the script's source.
! grep -qF '>> .gitignore' "$KIT/$HELPER" \
  || { echo "FAIL [never-write]: $HELPER contains a literal '>> .gitignore' — it must never write the file it only ever proposes editing"; exit 1; }

echo "  ok: never-write — the script contains no '>> .gitignore' write, by construction"

# ---------------------------------------------------------------- 2. the incident's exact spelling
#
# .gitignore DOES carry `.claude/worktrees/` and `.worktrees/` — both anchored, trailing-slash,
# exactly as this kit's own .gitignore does — but NEITHER directory exists yet, which is the state
# of every fresh checkout and the exact state Step 4 is in before it creates anything. A guard
# spelled `check-ignore -q .worktrees` (no slash) answers "NOT ignored" here; the real
# worktrees-ignored.sh answers "ignored", because it queries with the slash. This case proves that
# false negative cannot come back through this script.

caseB="$WORK/case-b"
init_repo "$caseB" '.claude/worktrees/\n.worktrees/\n'
BRANCH_B="feat/2-incident-spelling"

[ ! -e "$caseB/.claude/worktrees" ] \
  || { echo "FAIL [incident-spelling]: fixture setup bug — .claude/worktrees/ already exists"; exit 1; }

rc=0
out=$("$KIT/$HELPER" -C "$caseB" "$BRANCH_B") || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [incident-spelling]: expected exit 0, got $rc"; echo "$out"; exit 1; }

grep -q '^WORKTREE=' <<<"$out" \
  || { echo "FAIL [incident-spelling]: no WORKTREE= line in output:"; echo "$out"; exit 1; }
grep -qF "BRANCH=$BRANCH_B" <<<"$out" \
  || { echo "FAIL [incident-spelling]: no BRANCH=$BRANCH_B line in output:"; echo "$out"; exit 1; }

wt_path=$(printf '%s\n' "$out" | sed -n 's/^WORKTREE=//p')
[ -d "$wt_path" ] \
  || { echo "FAIL [incident-spelling]: WORKTREE= path does not exist on disk: $wt_path"; exit 1; }
# Herestring, not a pipe into `grep -q` (#391).
head_branch=$(git -C "$wt_path" symbolic-ref --quiet --short HEAD)
grep -qF "$BRANCH_B" <<<"$head_branch" \
  || { echo "FAIL [incident-spelling]: $wt_path is not checked out on $BRANCH_B"; exit 1; }

echo "  ok: incident-spelling — the correctly-slashed rule passes before the directory exists, exit 0"

# ---------------------------------------------------------------- 3. a stale worktree record is not a reuse
#
# git's own admin metadata can outlive the directory it names (a hand deletion, a partial
# teardown) and `git worktree list` still reports it for the branch. Reusing that path blindly
# would exit 0 naming a WORKTREE that Steps 5-9 then fail to -C into — a false success reported by
# THIS script, not just a later one. Recreate it instead.

caseC="$WORK/case-c"
init_repo "$caseC" '.claude/worktrees/\n.worktrees/\n'
BRANCH_C="feat/3-stale-worktree"

out=$("$KIT/$HELPER" -C "$caseC" "$BRANCH_C")
first_wt=$(printf '%s\n' "$out" | sed -n 's/^WORKTREE=//p')
[ -d "$first_wt" ] || { echo "FAIL [stale-worktree]: setup — first call did not create $first_wt"; exit 1; }

rm -rf "$first_wt"
[ ! -e "$first_wt" ] || { echo "FAIL [stale-worktree]: setup — could not remove $first_wt"; exit 1; }

rc=0
out=$("$KIT/$HELPER" -C "$caseC" "$BRANCH_C" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [stale-worktree]: expected exit 0 (recreate), got $rc"; echo "$out"; exit 1; }

second_wt=$(printf '%s\n' "$out" | sed -n 's/^WORKTREE=//p')
[ -n "$second_wt" ] || { echo "FAIL [stale-worktree]: no WORKTREE= line in output:"; echo "$out"; exit 1; }
[ -d "$second_wt" ] \
  || { echo "FAIL [stale-worktree]: reported WORKTREE=$second_wt does not exist on disk — the stale record was reused, not recreated"; exit 1; }

echo "  ok: stale-worktree — a deleted-but-still-listed worktree is recreated, never reused blind"

# ---------------------------------------------------------------- 4. `--` ends options, not the branch
#
# `-C <repo> -- <branch>` is the conventional way to signal end-of-options. A parser that
# `break`s out of its loop on `--` (guarded-commit.sh's shape, where everything after `--` is
# passed through verbatim to `git`) discards the branch this script still needs to read itself.

caseD="$WORK/case-d"
init_repo "$caseD" '.claude/worktrees/\n.worktrees/\n'
BRANCH_D="feat/4-end-of-options"

rc=0
out=$("$KIT/$HELPER" -C "$caseD" -- "$BRANCH_D" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [end-of-options]: expected exit 0, got $rc"; echo "$out"; exit 1; }
grep -qF "BRANCH=$BRANCH_D" <<<"$out" \
  || { echo "FAIL [end-of-options]: -- swallowed the branch instead of ending options:"; echo "$out"; exit 1; }

echo "  ok: end-of-options — '--' before <branch> does not discard it"

# ---------------------------------------------------------------- 5. the tree's path is recorded (#469)
#
# The guards' mid-run liveness assertion reads `kit.worktree.<branch>.path` from the common
# .git/config; this is the one place it is written. Three shapes: a fresh create, a reuse (the
# record is rewritten, so a recreated tree on the same branch matches), and a branch carrying `/`
# (the `.path` third component is what keeps the slash inside git's subsection).

caseE="$WORK/case-e"
init_repo "$caseE" '.claude/worktrees/\n.worktrees/\n'
BRANCH_E="fix/469-worktree/liveness"

out=$("$KIT/$HELPER" -C "$caseE" "$BRANCH_E")
wt_e=$(printf '%s\n' "$out" | sed -n 's/^WORKTREE=//p')
rec=$(git -C "$caseE" config --get "kit.worktree.${BRANCH_E}.path" 2>/dev/null || true)
[ -n "$rec" ] || { echo "FAIL [record-create]: no kit.worktree.$BRANCH_E.path recorded after a fresh create"; exit 1; }
[ "$rec" = "$(cd "$wt_e" && pwd -P)" ] \
  || { echo "FAIL [record-create]: recorded '$rec' is not the tree's absolute path '$(cd "$wt_e" && pwd -P)'"; exit 1; }
# The record must be readable FROM the worktree too — that is where the guards run.
[ "$(git -C "$wt_e" config --get "kit.worktree.${BRANCH_E}.path")" = "$rec" ] \
  || { echo "FAIL [record-create]: the record is not visible through the worktree's own config"; exit 1; }
echo "  ok: record-create — kit.worktree.<branch>.path holds the tree's absolute path, slash in the branch and all"

git -C "$caseE" config "kit.worktree.${BRANCH_E}.path" "/stale/from/an/earlier/run"
out=$("$KIT/$HELPER" -C "$caseE" "$BRANCH_E")
[ "$(git -C "$caseE" config --get "kit.worktree.${BRANCH_E}.path")" = "$rec" ] \
  || { echo "FAIL [record-reuse]: a reuse did not re-record the tree's path over a stale value"; exit 1; }
echo "  ok: record-reuse — reusing the tree re-records its path"

# ---------------------------------------------------------------- 5. Step 4 calls the guard, not a re-spelling
#
# A tool the kit ships is a tool Step 4 actually reaches for — pin that the prose names it, and pin
# the ⛔ clause naming BOTH observed failure spellings from the incident this whole suite is about,
# so a future edit cannot quietly drop either warning without going red.

SKILL="$(kit_skill_prose "$KIT" implement-issue)"   # router + references/steps/*.md (#499)
[ -f "$SKILL" ] || { echo "FAIL [skill-doc]: $SKILL not found"; exit 1; }

STEP4=$(sed -n '/^## Step 4 /,/^## Step 5 /p' "$SKILL")
[ -n "$STEP4" ] || { echo "FAIL [skill-doc]: could not extract Step 4's section from $SKILL"; exit 1; }

grep -qF 'make-worktree.sh' <<<"$STEP4" \
  || { echo "FAIL [skill-doc]: Step 4 does not reference make-worktree.sh"; exit 1; }
grep -q '⛔' <<<"$STEP4" \
  || { echo "FAIL [skill-doc]: Step 4 carries no ⛔ clause for this step's own hazard"; exit 1; }
grep -qF 'git check-ignore' <<<"$STEP4" \
  || { echo "FAIL [skill-doc]: Step 4's ⛔ clause does not name the hand-written 'git check-ignore' spelling"; exit 1; }
grep -qF 'git commit' <<<"$STEP4" \
  || { echo "FAIL [skill-doc]: Step 4's ⛔ clause does not name 'git commit' in the main checkout"; exit 1; }
grep -qF 'main checkout' <<<"$STEP4" \
  || { echo "FAIL [skill-doc]: Step 4's ⛔ clause does not say WHERE the observed commit landed (the main checkout)"; exit 1; }

echo "  ok: skill-doc — Step 4 names make-worktree.sh and pins the ⛔ clause naming both spellings"

echo "implement-issue-worktree-step golden test OK"
