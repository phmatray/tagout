#!/usr/bin/env bash
# Golden test for skills/create-pr — the PR-open recipe keeps one home (#635).
#
# create-pr ships no script: it follows skills/_shared/open-pr.md, the one place `gh pr create` is
# spelled as a command. So what a suite can hold is the POINTERS — the skill links the recipe
# rather than re-spelling it, and writes through the guards rather than a bare git push/commit.
#
# Fail-path-first, like every suite here: the one-home check is driven to red on a scratch copy of
# skills/ carrying a second `gh pr create`, so a check that silently stopped matching cannot pass.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

OPEN="skills/create-pr/references/steps/03-open.md"
LOCATE="skills/create-pr/references/steps/02-locate-the-work.md"
[ -f "$KIT/$OPEN" ] || { echo "FAIL: $OPEN missing"; exit 1; }
[ -f "$KIT/$LOCATE" ] || { echo "FAIL: $LOCATE missing"; exit 1; }

# $1 = a 02-locate-the-work.md-shaped file. Fails, naming the reason, unless it: refuses on a
# leftover [DEBUG- probe diffed against the EXACT origin/$DEFAULT ref, routes every leftover commit
# through guarded-commit.sh GATED on a `git status --porcelain` dirty-tree check a few lines above
# it (an unconditional call would commit on every run, not only a dirty one), and no longer refuses
# the default branch outright (#636).
check_step2_shape() {
  local f="$1" line window
  if grep -q 'nothing to open from the default branch' "$f"; then
    echo "FAIL: $f still refuses the default branch outright"; return 1
  fi
  grep -q '\[DEBUG-' "$f" \
    || { echo "FAIL: $f carries no [DEBUG- probe check"; return 1; }
  grep -qF 'git diff "origin/$DEFAULT"' "$f" \
    || { echo "FAIL: $f does not diff the exact origin/\$DEFAULT ref for the probe check"; return 1; }
  grep -q 'guarded-commit\.sh' "$f" \
    || { echo "FAIL: $f does not route leftover commits through guarded-commit.sh"; return 1; }
  while IFS=: read -r line _; do
    window=$(sed -n "$(( line > 5 ? line - 5 : 1 )),${line}p" "$f")
    printf '%s\n' "$window" | grep -q 'git status --porcelain' \
      || { echo "FAIL: $f calls guarded-commit.sh at line $line with no git status --porcelain gate above it"; return 1; }
  done < <(grep -n 'guarded-commit\.sh' "$f")
  return 0
}

# $1 = a 03-open.md-shaped file. Fails unless it invokes rewind-default.sh GATED on a
# `$FROM_DEFAULT` check a few lines above the call — an unconditional call would rewind the local
# default on every ordinary PR, not only a debug-issue hand-off (#636).
check_rewind_gated() {
  local f="$1" line window
  line=$(grep -n 'rewind-default\.sh".*-C ' "$f" | head -1 | cut -d: -f1)
  [ -n "$line" ] || { echo "FAIL: $f does not invoke rewind-default.sh"; return 1; }
  window=$(sed -n "$(( line > 3 ? line - 3 : 1 )),${line}p" "$f")
  printf '%s\n' "$window" | grep -q 'FROM_DEFAULT' \
    || { echo "FAIL: $f calls rewind-default.sh at line $line with no FROM_DEFAULT gate above it"; return 1; }
  return 0
}

# $1 = a root holding skills/. Prints every `gh pr create` command line outside the recipe, as
# <path>:<line>:<text> relative to that root, and returns 1 when there is one.
check_one_home() {
  local root="$1" hits others rc=0
  hits=$(kit_scratch)/hits
  others=$(kit_scratch)/others
  (cd "$root" && grep -rnE '^[[:space:]]*gh pr create' skills) > "$hits" || rc=$?
  [ "$rc" -le 1 ] || { echo "FAIL: grep could not read $root/skills (exit $rc)"; return 1; }
  grep -q '^skills/_shared/open-pr\.md:' "$hits" \
    || { echo "FAIL: skills/_shared/open-pr.md spells no \`gh pr create\` line — the one home is empty"; return 1; }
  grep -v '^skills/_shared/open-pr\.md:' "$hits" > "$others" || true
  if [ -s "$others" ]; then
    echo "FAIL: \`gh pr create\` is spelled outside skills/_shared/open-pr.md:"; cat "$others"; return 1
  fi
  return 0
}

# ------------------------------------------------------------- (d) the one-home check, driven to red
scratch=$(kit_scratch)
cp -R "$KIT/skills" "$scratch/"
printf '\ngh pr create --title x\n' >> "$scratch/$OPEN"
if check_one_home "$scratch" > "$scratch/red.out" 2>&1; then
  echo "FAIL: a second \`gh pr create\` in $OPEN was accepted"; exit 1
fi
grep -qF 'skills/create-pr/references/steps/03-open.md' "$scratch/red.out" \
  || { echo "FAIL: the one-home check refused without naming the file"; cat "$scratch/red.out"; exit 1; }
echo "ok   (d) a second \`gh pr create\` under skills/create-pr/ is refused, naming the file"

# ------------------------------------------------------------- (f) a reintroduced default-branch
# refusal is refused, fail path first (#636)
scratch2=$(kit_scratch)
cp "$KIT/$LOCATE" "$scratch2/locate.md"
printf '\n%s\n' '1. **`$BRANCH` is `$DEFAULT`** -> refuse: "nothing to open from the default branch".' \
  >> "$scratch2/locate.md"
if check_step2_shape "$scratch2/locate.md" > "$scratch2/red.out" 2>&1; then
  echo "FAIL: a reintroduced default-branch refusal in $LOCATE was accepted"; exit 1
fi
grep -qF 'still refuses the default branch' "$scratch2/red.out" \
  || { echo "FAIL: (f) refused for the wrong reason"; cat "$scratch2/red.out"; exit 1; }
echo "ok   (f) a reintroduced default-branch refusal in $LOCATE is refused, fail path first"

# ------------------------------------------------------------- (i) an ungated guarded-commit.sh
# call is refused, fail path first (#636) — check_step2_shape must catch a commit with no
# dirty-tree gate above it, not just the mere presence of a guarded-commit.sh call anywhere.
scratch3=$(kit_scratch)
cat > "$scratch3/ungated.md" <<'FIXTURE'
[DEBUG- probe check present]
git diff "origin/$DEFAULT"
"$GUARDS/guarded-commit.sh" -C "$WORKTREE" <commit-identity> "$BRANCH" -- -am "fix: x"
FIXTURE
if check_step2_shape "$scratch3/ungated.md" > "$scratch3/red.out" 2>&1; then
  echo "FAIL: an ungated guarded-commit.sh call was accepted"; exit 1
fi
grep -qF 'no git status --porcelain gate' "$scratch3/red.out" \
  || { echo "FAIL: (i) refused for the wrong reason"; cat "$scratch3/red.out"; exit 1; }
echo "ok   (i) an ungated guarded-commit.sh call (no dirty-tree check above it) is refused, fail path first"

cat > "$scratch3/gated.md" <<'FIXTURE'
[DEBUG- probe check present]
git diff "origin/$DEFAULT"
if [ -n "$(git status --porcelain)" ]; then
  "$GUARDS/guarded-commit.sh" -C "$WORKTREE" <commit-identity> "$BRANCH" -- -am "fix: x"
fi
FIXTURE
check_step2_shape "$scratch3/gated.md" \
  || { echo "FAIL: (i) a properly gated guarded-commit.sh call was rejected"; exit 1; }
echo "ok   (i) a gated guarded-commit.sh call passes"

# ------------------------------------------------------------- (j) an ungated rewind-default.sh
# call is refused, fail path first (#636) — check_rewind_gated must catch an unconditional call.
cat > "$scratch3/rewind-ungated.md" <<'FIXTURE'
"<kit>/skills/create-pr/scripts/rewind-default.sh" -C "$WORKTREE" "$DEFAULT" "$BRANCH"
FIXTURE
if check_rewind_gated "$scratch3/rewind-ungated.md" > "$scratch3/red2.out" 2>&1; then
  echo "FAIL: an ungated rewind-default.sh call was accepted"; exit 1
fi
grep -qF 'no FROM_DEFAULT gate' "$scratch3/red2.out" \
  || { echo "FAIL: (j) refused for the wrong reason"; cat "$scratch3/red2.out"; exit 1; }
echo "ok   (j) an ungated rewind-default.sh call (no \$FROM_DEFAULT check above it) is refused, fail path first"

cat > "$scratch3/rewind-gated.md" <<'FIXTURE'
if [ "${FROM_DEFAULT:-0}" = 1 ]; then
  "<kit>/skills/create-pr/scripts/rewind-default.sh" -C "$WORKTREE" "$DEFAULT" "$BRANCH"
fi
FIXTURE
check_rewind_gated "$scratch3/rewind-gated.md" \
  || { echo "FAIL: (j) a properly gated rewind-default.sh call was rejected"; exit 1; }
echo "ok   (j) a gated rewind-default.sh call passes"

# ------------------------------------------------------------- the real tree
# (a) step 03 links the recipe, at the depth that resolves from references/steps/.
grep -qF '../../../_shared/open-pr.md' "$KIT/$OPEN" \
  || { echo "FAIL: $OPEN does not link ../../../_shared/open-pr.md"; exit 1; }
echo "ok   (a) $OPEN links _shared/open-pr.md"

# (b) `gh pr create` has one home.
check_one_home "$KIT" || exit 1
echo "ok   (b) \`gh pr create\` is spelled only in skills/_shared/open-pr.md"

# (c) every write goes through the guards.
bare=$(kit_scratch)/bare
rc=0
grep -rnE '^[[:space:]]*git[[:space:]]+(push|commit)([[:space:]]|$)' "$KIT/skills/create-pr" > "$bare" || rc=$?
[ "$rc" -le 1 ] || { echo "FAIL: grep could not read skills/create-pr (exit $rc)"; exit 1; }
if [ -s "$bare" ]; then
  echo "FAIL: skills/create-pr/ begins a bare git push/commit — go through guarded-push.sh:"; cat "$bare"; exit 1
fi
echo "ok   (c) no bare git push or git commit under skills/create-pr/"

# (g) the real tree: 02 refuses [DEBUG- probes against the exact origin/$DEFAULT ref, routes every
# leftover commit through a git-status-gated guarded-commit.sh call, and no longer refuses the
# default branch outright (#636).
check_step2_shape "$KIT/$LOCATE" || exit 1
echo "ok   (g) $LOCATE refuses [DEBUG- probes on the default branch, gates leftover commits on a dirty tree through guarded-commit.sh, and no longer refuses it outright"

# (h) 03-open.md invokes rewind-default.sh, gated on \$FROM_DEFAULT — not unconditionally (#636).
check_rewind_gated "$KIT/$OPEN" || exit 1
echo "ok   (h) $OPEN invokes rewind-default.sh, gated on \$FROM_DEFAULT"

# (e) the issue number Step 2 reads from a branch name — the sed script is read out of the step and
# run, so a dropped -n/p (the whole branch name becomes $ISSUE, issue-view fails, the PR silently
# links no issue) turns this red.
parse=$(grep -F '"$BRANCH" | sed -nE' "$KIT/$LOCATE" | sed -nE "s/.*sed -nE '([^']*)'.*/\1/p") || true
[ -n "$parse" ] || { echo "FAIL: no branch-name sed script found in $LOCATE"; exit 1; }
for case in 'fix/88-null-header 88' 'feat/1234-x 1234' 'main -' 'fix/88 -' 'release/2.0 -'; do
  branch=${case% *}; want=${case##* }
  [ "$want" != - ] || want=
  got=$(printf '%s\n' "$branch" | sed -nE "$parse")
  [ "$got" = "$want" ] || { echo "FAIL: (e) '$branch' parsed to '$got', want '$want'"; exit 1; }
done
echo "ok   (e) $LOCATE reads <type>/<N>-<slug> as N, and anything else as no issue"

echo "create-pr golden test OK"
