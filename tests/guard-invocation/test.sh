#!/usr/bin/env bash
# Golden test for the guard-invocation fallback (#414).
#
# $GUARDS points at this skill's own scripts/ directory, resolved from wherever the kit is
# installed — as an installed plugin that is the plugin cache, outside any worktree an
# auto-dev/implement-issue worker is confined to. Two independent workers in one fleet run hit a
# refusal invoking a guard at that path and each improvised its own recovery. This suite pins the
# one documented recovery skills/_shared/guard-invocation.md now states, and that every site
# defining $GUARDS points at it.
#
# Seam under test: the skill documents as TEXT — a documentation contract, not runtime behaviour
# (a refused invocation path is a host/sandbox policy, not something this suite can reproduce).
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT_ROOT="$(pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
kit_guard kit_guard_samples_unchanged

FAILED=0
note_fail() { echo "FAIL: $1"; FAILED=1; }

DOC="skills/_shared/guard-invocation.md"

# ------------------------------------------------------------ 1. the fallback guidance exists
[ -f "$DOC" ] || { echo "FAIL: $DOC does not exist"; exit 1; }

grep -q -- '_assert-branch\.sh' "$DOC" \
  || note_fail "$DOC does not name _assert-branch.sh — a copy that omits it silently breaks the guard"

grep -qi -- 'delete\|remove' "$DOC" \
  || note_fail "$DOC does not state the cleanup step (delete/remove the scratch directory)"

grep -qi -- 'bare `git commit`\|bare `git push`\|bare `git merge`\|never fall back to a bare' "$DOC" \
  || note_fail "$DOC does not forbid falling back to a bare git commit/push/merge"

grep -qi -- 'report' "$DOC" \
  || note_fail "$DOC does not require reporting the deviation"

# #668: five scripts spelled the repository five ways and agents transferred the shape they used a
# call ago, 11 refusals in 18 days. The doctrine names ONE spelling, and the `--` rule beside it —
# the four `guarded-commit`/`guarded-merge` refusals in that window were all the plain git spelling
# leaking in front of `--`.
grep -qF -- '-R <[host/]owner/repo>' "$DOC" \
  || note_fail "$DOC does not name -R <[host/]owner/repo> as the one repository spelling"
grep -qF -- 'after `--`' "$DOC" \
  || note_fail "$DOC does not state that git/gh's own arguments go after --"

grep -qi -- 'make-worktree\.sh' "$DOC" \
  || note_fail "$DOC does not explicitly exclude make-worktree.sh's pre-worktree \$GUARDS usage"

grep -qi -- 'guarded-pr-merge\.sh' "$DOC" \
  || note_fail "$DOC does not name guarded-pr-merge.sh — the fallback's scope missed a fourth guard script"

# Naming it in the intro isn't enough — the fallback's own Step 1 recipe (the "## The fallback"
# section) must actually cp it, or an agent following that recipe hits "No such file or directory".
# Captured, then read by herestring: negated, this pipe is exempt from sigpipe-idiom-check.py, yet it
# is the same race — an awk killed by SIGPIPE makes the pipeline 141, `!` turns that into "no
# match", and the FAIL below fires on a document that does name the guard.
fallback_section=$(awk '/^## The fallback/{f=1} f' "$DOC")
if ! grep -qi -- 'guarded-pr-merge\.sh' <<<"$fallback_section"; then
  note_fail "$DOC names guarded-pr-merge.sh only outside '## The fallback' — its Step 1 cp recipe doesn't cover it"
fi

# ------------------------------------------------------------ 1b. the isolation-safe shape and bounded exit (#763)
# The harness refuses on command TEXT, so the first thing under isolation is the plain absolute
# plugin-path call; the copy is a last resort with a scratch name free of the vcs token; and the
# whole fallback ends in a bounded BLOCKED report, not an open-ended retry.
plugin_line=$(grep -n -i 'plugin.path' <<<"$fallback_section" | head -1 | cut -d: -f1 || true)
cp_line=$(grep -n '^ *cp ' <<<"$fallback_section" | head -1 | cut -d: -f1 || true)
{ [ -n "$plugin_line" ] && [ -n "$cp_line" ] && [ "$plugin_line" -lt "$cp_line" ]; } \
  || note_fail "$DOC's fallback does not name the plugin-path call before the first cp"

if grep -rIn -- '\.git-guards' skills commands >/dev/null 2>&1; then
  note_fail "a scratch name containing the vcs token (.git-guards) remains under skills/ or commands/"
fi

copy_block=$(awk '/^ *```bash/{b=1;blk="";next} /^ *```/{if(b&&blk ~ /cp /)print blk;b=0} b{blk=blk"\n"$0}' <<<"$fallback_section")
grep -q -- 'mkdir -p' <<<"$copy_block" \
  || note_fail "$DOC's copy block does not create its target directory with mkdir -p"

grep -q -- 'BLOCKED' <<<"$fallback_section" \
  || note_fail "$DOC's fallback has no BLOCKED exit"
grep -qi -- 'one attempt per' <<<"$fallback_section" \
  || note_fail "$DOC's fallback has no one-attempt-per-shape clause"

# A `file:line` site must be accompanied — within the next few lines — by a pointer to the shared
# fallback doc, so the next skill that adds a guarded call site cannot forget it silently. Shared by
# sections 2 and 2b below, so a change to the window logic can't silently apply to one and not the
# other. This mirrors ci-wiring-check.py's own reasoning: a missing pointer looks exactly like a
# skill that already covers the case.
CONTEXT_LINES=10
site_points_at_doc() {
  local file="$1" line="$2" end=$(( $2 + CONTEXT_LINES )) window
  window=$(sed -n "${line},${end}p" "$file")
  grep -q -- 'guard-invocation\.md' <<<"$window"
}

# ------------------------------------------------------------ 2. every GUARDS= site points at it
while IFS=: read -r file line _; do
  [ "$file" = "$DOC" ] && continue
  site_points_at_doc "$file" "$line" \
    || note_fail "$file:$line defines \$GUARDS but does not point at $DOC within $CONTEXT_LINES lines"
done < <(grep -rn '^GUARDS=' skills/)

# ------------------------------------------------------------ 2b. every literal guarded-pr-merge.sh call site points at it
#
# guarded-pr-merge.sh is never behind a `$GUARDS=` line, so the scan above cannot see it — hand-list
# its known FILES instead (#414's reopened round), but derive the LINE dynamically by grepping the
# full-path spelling: a hardcoded line number drifts the moment either file grows or shrinks above
# it (these three are edited in nearly every auto-dev PR), silently narrowing or missing the window.
# A fifth call site in a file this scan doesn't know about is a gap this test accepts (see the
# issue's Out of scope / approach C).
PR_MERGE_FILES="skills/merge-pr/SKILL.md skills/merge-pr/references/steps/05-merge.md skills/auto-dev/references/steps/04-supervise.md"
for file in $PR_MERGE_FILES; do
  [ -f "$file" ] || { note_fail "$file (a guarded-pr-merge.sh call site) does not exist"; continue; }
  found=0
  while IFS=: read -r line _; do
    found=1
    site_points_at_doc "$file" "$line" \
      || note_fail "$file:$line invokes guarded-pr-merge.sh but does not point at $DOC within $CONTEXT_LINES lines"
  done < <(grep -n 'merge-pr/scripts/guarded-pr-merge\.sh' "$file")
  [ "$found" -eq 1 ] \
    || note_fail "$file no longer invokes guarded-pr-merge.sh by its full path — update this scan or the fallback is orphaned there"
done

# ------------------------------------------------------------ 3. fleet workers get the standing clause
for f in commands/auto-dev-worker.md commands/auto-dev-merge.md; do
  [ -f "$f" ] || { note_fail "$f does not exist"; continue; }
  grep -q -- 'guard-invocation\.md' "$f" \
    || note_fail "$f does not point at $DOC"
  grep -qi -- 'report' "$f" \
    || note_fail "$f does not carry the report-the-deviation requirement"
done

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "PASS: guard-invocation fallback is documented once and every \$GUARDS site points at it"
