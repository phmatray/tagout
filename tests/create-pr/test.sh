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
# leftover [DEBUG- probe diffed against origin/$DEFAULT, routes leftover commits through
# guarded-commit.sh, and no longer refuses the default branch outright (#636).
check_step2_shape() {
  local f="$1"
  if grep -q 'nothing to open from the default branch' "$f"; then
    echo "FAIL: $f still refuses the default branch outright"; return 1
  fi
  grep -q '\[DEBUG-' "$f" \
    || { echo "FAIL: $f carries no [DEBUG- probe check"; return 1; }
  grep -q 'git diff "origin/' "$f" \
    || { echo "FAIL: $f does not diff against origin/\$DEFAULT for the probe check"; return 1; }
  grep -q 'guarded-commit.sh' "$f" \
    || { echo "FAIL: $f does not route leftover commits through guarded-commit.sh"; return 1; }
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

# (g) the real tree: 02 refuses [DEBUG- probes, diffs against origin/$DEFAULT, routes leftovers
# through guarded-commit.sh, and no longer refuses the default branch outright (#636).
check_step2_shape "$KIT/$LOCATE" || exit 1
echo "ok   (g) $LOCATE refuses [DEBUG- probes on the default branch, routes leftovers through guarded-commit.sh, and no longer refuses it outright"

# (h) 03-open.md invokes rewind-default.sh once the branch is off the default (#636).
grep -qF 'rewind-default.sh' "$KIT/$OPEN" \
  || { echo "FAIL: $OPEN does not invoke rewind-default.sh"; exit 1; }
echo "ok   (h) $OPEN invokes rewind-default.sh"

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
