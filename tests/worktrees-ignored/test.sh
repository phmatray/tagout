#!/usr/bin/env bash
# Golden test for worktrees-ignored.sh — the guard that an agent worktree can never be committed.
#
# Written fail-path-first, like tests/release-title-gate/test.sh and for the same reason this
# repo keeps re-learning: a guard whose PASS path is the only one ever exercised proves nothing,
# and one that quietly stopped matching would stay green forever. Every case below drives the
# guard over a scratch repository whose .gitignore is written for that case.
#
# The three hazards the guard's own header names are all regressions a reader could plausibly
# introduce while "tidying", so each gets a case that goes red:
#   * swapping -q for -v          → the negation case
#   * dropping the trailing slash → the fresh-checkout case
#   * broadening to `.claude/`    → the repo-profile case
set -euo pipefail
cd "$(dirname "$0")/../.."

GUARD="./scripts/worktrees-ignored.sh"
[ -x "$GUARD" ] || { echo "FAIL: $GUARD missing or not executable"; exit 1; }
KIT="$PWD"

# Scratch dir and EXIT trap come from the shared preamble (#72).
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
WORK=$(kit_scratch)

# A fresh repo whose .gitignore is exactly $1. Nothing is created on disk beyond .gitignore —
# that absence is the fresh-checkout condition the trailing-slash rule exists for.
#
# mktemp -d, NOT a counter: `n=$((n+1))` inside a $(...) helper increments a subshell's copy and
# the caller's stays 0, so every "fresh" repo would be the same directory — the trap
# tests/_lib.sh:65-70 documents and tests/roseline/test.sh:50-54 already states and works around.
scratch() {
  local dir; dir=$(mktemp -d "$WORK/r.XXXXXX")
  git -C "$dir" init -q
  printf '%b' "$1" > "$dir/.gitignore"
  printf '%s' "$dir"
}

# Asserts the guard exited $2 and said something naming $3.
verdict() {
  local name="$1" want_rc="$2" want_msg="$3" dir="$4"
  local out rc=0
  out=$(bash "$KIT/$GUARD" -C "$dir" 2>&1) || rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    echo "FAIL [$name]: expected exit $want_rc, got $rc"; echo "$out"; exit 1
  fi
  if ! printf '%s' "$out" | grep -qF -- "$want_msg"; then
    echo "FAIL [$name]: output did not mention '$want_msg':"; echo "$out"; exit 1
  fi
  echo "  ok: $name"
}

[ "$(scratch '')" != "$(scratch '')" ] || { echo "FAIL [scratch-isolation]: two scratch() calls returned the same directory"; exit 1; }
echo "  ok: scratch-isolation — each call returns a genuinely distinct directory"

# ---------------------------------------------------------------- refusals

# 1. Nothing ignored — the state of this repo before #43.
verdict no-rule 1 'is NOT ignored' "$(scratch '')"

# 2. THE fresh-checkout case. The rule is correct and the directory does not exist, which is every
#    CI run. A guard querying `.claude/worktrees` without the trailing slash answers "not ignored"
#    here and fails a repo that is configured properly; with the slash it passes. This case is the
#    only thing keeping that slash in place.
verdict fresh-checkout 0 'is ignored' "$(scratch '.claude/worktrees/\n.worktrees/\n')"

# 3. THE negation case — why the guard must use -q and not -v. `check-ignore -v` exits 0 here
#    because a pattern matched, and the matching pattern is the negation: the path is NOT ignored.
#    A -v-based guard passes this; -q refuses it.
verdict negated 1 'is NOT ignored' \
  "$(scratch '.claude/worktrees/\n.worktrees/\n!.claude/worktrees/\n')"

# 4. A commented-out rule — why the guard must not grep .gitignore. The string is still in the
#    file, so a grep passes while `git add -A` stages the worktree.
verdict commented-out 1 'is NOT ignored' "$(scratch '#.claude/worktrees/\n.worktrees/\n')"

# 5. The second worktree home on its own. superpowers:using-git-worktrees Step 1b defaults to
#    `.worktrees/` when the harness offers no native tool, so covering only `.claude/` leaves a
#    reachable path open — measured: `git add -A` stages `.worktrees/<branch>` just the same.
verdict only-claude-home 1 '.worktrees/ is NOT ignored' "$(scratch '.claude/worktrees/\n')"
verdict only-plain-home  1 '.claude/worktrees/ is NOT ignored' "$(scratch '.worktrees/\n')"

# 6. THE broadening case, and the one nothing else in CI can see. `.claude/` ignores the worktrees
#    perfectly well — so a guard that only asked "are worktrees ignored?" stays green — while also
#    hiding `.claude/skills/repo-profile.md`, which init tells consumer repos to
#    commit. Distinct exit code, because it is a different mistake with a different fix.
verdict broadened 2 'was broadened' "$(scratch '.claude/\n.worktrees/\n')"

# 7. Broadened by a wildcard rather than by the directory — same damage, and `.claude/*` is what a
#    "tidy-up" is at least as likely to produce.
verdict broadened-glob 2 'was broadened' "$(scratch '.claude/*\n.worktrees/\n')"

# ---------------------------------------------------------------- passes

# 8. The shipped configuration: both homes ignored, the profile still visible.
verdict correct 0 'is still visible' "$(scratch '.claude/worktrees/\n.worktrees/\n')"

# 9. A consumer repo that ALSO ignores unrelated .claude/ children must still pass — the guard
#    forbids hiding the profile, not every rule under .claude/.
verdict narrow-siblings 0 'is still visible' \
  "$(scratch '.claude/worktrees/\n.worktrees/\n.claude/settings.local.json\n')"

# 10. The guard is read-only. It is handed a repo it does not own, so it must not create the
#     scratch directories it asks about — the reason the trailing-slash query replaced a `mkdir`.
dir=$(scratch '.claude/worktrees/\n.worktrees/\n')
bash "$KIT/$GUARD" -C "$dir" >/dev/null 2>&1
[ ! -e "$dir/.claude" ] || { echo "FAIL [read-only]: the guard created $dir/.claude"; exit 1; }
[ ! -e "$dir/.worktrees" ] || { echo "FAIL [read-only]: the guard created $dir/.worktrees"; exit 1; }
echo "  ok: read-only — audits the workspace without writing to it"

# 11. The real article, end to end: a genuine `git worktree add` into an unignored home, then a
#     `git add -A` in the MAIN checkout — note the location, because it is the only place the
#     gitlink is reachable from: run from inside the linked worktree the home lives in the parent
#     checkout and `add -A` sees nothing (measured, #68). Asserts BOTH that the guard refuses and what the damage
#     actually looks like — a single 160000 gitlink, not a copy of the tree. The guard's header
#     states that as measured fact; this is the measurement, so it cannot rot into folklore.
real="$WORK/real"
mkdir -p "$real"
git -C "$real" init -q -b main
git -C "$real" config user.email t@example.com
git -C "$real" config user.name "Golden Test"
printf 'x\n' > "$real/tracked.txt"
git -C "$real" add -A
git -C "$real" commit -qm base
git -C "$real" worktree add -q .claude/worktrees/feat -b feat

rc=0; bash "$KIT/$GUARD" -C "$real" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL [real-worktree]: expected exit 1 on a live unignored worktree, got $rc"; exit 1; }

git -C "$real" add -A 2>/dev/null
entry=$(git -C "$real" ls-files -s -- .claude/worktrees/feat)
printf '%s' "$entry" | grep -q '^160000 ' \
  || { echo "FAIL [real-worktree]: expected a 160000 gitlink, got: $entry"; exit 1; }
[ "$(git -C "$real" ls-files -- .claude/worktrees | wc -l | tr -d ' ')" -eq 1 ] \
  || { echo "FAIL [real-worktree]: expected exactly one index entry for the worktree"; exit 1; }
echo "  ok: real-worktree — refused, and git add -A stages it as one 160000 gitlink"

# 12. Same repo, rule added: the guard passes and `git add -A` no longer sees the worktree. The
#     positive control for case 11 — without it, "nothing was staged" could just mean the tree
#     was empty.
git -C "$real" rm -r -q --cached .claude
printf '.claude/worktrees/\n.worktrees/\n' > "$real/.gitignore"
bash "$KIT/$GUARD" -C "$real" >/dev/null 2>&1 \
  || { echo "FAIL [real-worktree-fixed]: the guard still refuses a correctly configured repo"; exit 1; }
git -C "$real" add -A
[ -z "$(git -C "$real" ls-files -- .claude/worktrees)" ] \
  || { echo "FAIL [real-worktree-fixed]: git add -A still staged the worktree"; exit 1; }
echo "  ok: real-worktree-fixed — rule added, git add -A no longer stages it"

# ---------------------------------------------------------------- plumbing must fail closed

# 13. A path that is not a repository is a plumbing failure, never "nothing to check".
rc=0; bash "$KIT/$GUARD" -C "$WORK/does-not-exist" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || { echo "FAIL [not-a-repo]: expected exit 3, got $rc"; exit 1; }
echo "  ok: not-a-repo — exit 3, distinct from any verdict"

# 14. -C without a value must not silently audit the current directory.
rc=0; bash "$KIT/$GUARD" -C >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || { echo "FAIL [dangling-C]: expected exit 3, got $rc"; exit 1; }
echo "  ok: dangling-C — exit 3"

# 15. An unrecognised argument is refused rather than ignored.
rc=0; bash "$KIT/$GUARD" --repo /tmp >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || { echo "FAIL [bad-arg]: expected exit 3, got $rc"; exit 1; }
echo "  ok: bad-arg — exit 3"

# 16. --help documents the exit codes, matching the guards in skills/implement-issue/scripts and
#     the plugin-install simulation in ci.yml that greps for exactly this.
bash "$KIT/$GUARD" --help 2>&1 | grep -q 'Exit codes:' \
  || { echo "FAIL [help]: --help does not document the exit codes"; exit 1; }
echo "  ok: help — documents the exit codes"

# 17. Runs from a foreign working directory (plugin-install simulation, cf. ci.yml): the verdict
#     must follow -C, never the ambient CWD.
dir=$(scratch '')
( cd "$WORK" && bash "$KIT/$GUARD" -C "$dir" >/dev/null 2>&1 ) \
  && { echo "FAIL [foreign-cwd]: an unignored repo passed from another directory"; exit 1; }
echo "  ok: foreign cwd — the verdict follows -C, not the ambient directory"

# 18. THE shape the skills invoke (#71): a consumer installs the kit as a plugin, so the guard runs
#     from a directory that is not this repository — and, in the plugin cache, need not be a git
#     repository at all. Case 17 varies the working directory; this varies the SCRIPT'S OWN home,
#     which is the part a consumer changes.
#
#     Asserted as a pair, and the pair is the point. A guard that consulted its surroundings instead
#     of -C would answer from whatever repo it found and wave the consumer's repo through looking
#     exactly like a pass — so "refuses the unignored repo" is only meaningful next to "passes the
#     one that is configured". Neither half alone rules that out.
away="$WORK/plugin-cache/scripts"               # outside any git repo, like an installed plugin —
mkdir -p "$away"                                # and under $WORK, so the EXIT trap still cleans it up
cp "$KIT/$GUARD" "$away/worktrees-ignored.sh"
git -C "$(dirname "$(dirname "$away")")" rev-parse --git-dir >/dev/null 2>&1 \
  && { echo "FAIL [installed-elsewhere]: the fixture is inside a git repo — it proves nothing"; exit 1; }

dir=$(scratch '')                                # a consumer repo with no rule at all
rc=0; ( cd / && bash "$away/worktrees-ignored.sh" -C "$dir" >/dev/null 2>&1 ) || rc=$?
[ "$rc" -eq 1 ] || {
  echo "FAIL [installed-elsewhere]: expected exit 1 for an unignored consumer repo, got $rc"; exit 1; }

rc=0; ( cd / && bash "$away/worktrees-ignored.sh" -C "$KIT" >/dev/null 2>&1 ) || rc=$?
[ "$rc" -eq 0 ] || {
  echo "FAIL [installed-elsewhere]: a correctly configured repo was refused (exit $rc) — control invalid"; exit 1; }
echo "  ok: installed-elsewhere — judges the repo at -C, from a copy living outside any git repo"

# 19. -C takes the worktree ROOT. `.claude/worktrees/` contains a slash, so git anchors it and
#     resolves it relative to the directory it is asked about — point the guard at a subdirectory and
#     a perfectly configured repo answers "NOT ignored". Measured, and it reached a caller: the
#     profile probe passed `-C .` after cd-ing into an explicit [dir] argument.
#     `.worktrees/` has no internal slash, so it matches at any depth and hides the bug half the time
#     — which is why this asserts on the anchored home specifically.
dir=$(scratch '.claude/worktrees/\n.worktrees/\n')
mkdir -p "$dir/src/app"
bash "$KIT/$GUARD" -C "$dir" >/dev/null 2>&1 \
  || { echo "FAIL [root-vs-subdir]: the configured repo failed at its root — control invalid"; exit 1; }
rc=0; bash "$KIT/$GUARD" -C "$dir/src/app" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || {
  echo "FAIL [root-vs-subdir]: expected a subdirectory to be refused (exit 1), got $rc."
  echo "  If this now passes, git stopped anchoring the pattern and callers need not pass the root."; exit 1; }
echo "  ok: root-vs-subdir — the anchored home is only satisfied from the worktree root"

# 20. A rule that is in EFFECT but not committed still exits 0 — the path really is ignored for
#     whoever runs this, so the immediate hazard is covered — but it must SAY so, because callers
#     write the answer down. check-ignore is satisfied by .git/info/exclude and core.excludesFile.
dir=$(scratch '')                                # nothing committed
printf '.claude/worktrees/\n.worktrees/\n' >> "$dir/.git/info/exclude"
out=$(bash "$KIT/$GUARD" -C "$dir" 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [local-exclude]: expected exit 0 (it IS ignored here), got $rc"; exit 1; }
grep -qF 'note:' <<<"$out" \
  || { echo "FAIL [local-exclude]: a machine-local rule passed silently as if committed:"; echo "$out"; exit 1; }
grep -qF '.git/info/exclude' <<<"$out" \
  || { echo "FAIL [local-exclude]: the note does not name where the rule actually lives:"; echo "$out"; exit 1; }
echo "  ok: local-exclude — passes, but names the rule as uncommitted rather than a repo fact"

# 21. The committed case must NOT carry that note, or it means nothing.
dir=$(scratch '.claude/worktrees/\n.worktrees/\n')
git -C "$dir" add .gitignore
git -C "$dir" -c user.email=t@test -c user.name=T commit -qm "ignore worktree homes"
out=$(bash "$KIT/$GUARD" -C "$dir" 2>&1)
grep -qF 'note:' <<<"$out" \
  && { echo "FAIL [committed-rule]: a tracked .gitignore was flagged as undurable:"; echo "$out"; exit 1; }
echo "  ok: committed-rule — a tracked rule carries no durability note"

# ------------------------------------------------- the REUSE call site (#86)

# 22. The guard is invoked when a worktree is ABOUT TO BE USED, not only when one is about to be
#     created (#86) — and reuse is the steady state, not the edge case: implement-issue is
#     resume-safe by contract and merge-pr calls an existing worktree its "usual case". Cases 11-12
#     build a worktree and then judge the repo, which is already the reuse shape; what those cases
#     do not pin down is the argument a REUSE caller has in its hand. At creation time the caller
#     holds the repository it is creating in. At reuse time it holds `$WORKTREE` — the linked
#     worktree — and the obvious `rev-parse --show-toplevel` on that answers with the worktree
#     itself, not the checkout the hazard lives in.
#
#     Measured, and it fails OPEN, which is why this is a test and not a comment.
reuse="$WORK/reuse"
mkdir -p "$reuse"
git -C "$reuse" init -q -b main
git -C "$reuse" config user.email t@example.com
git -C "$reuse" config user.name "Golden Test"
printf 'x\n' > "$reuse/tracked.txt"
printf '.claude/worktrees/\n.worktrees/\n' > "$reuse/.gitignore"
git -C "$reuse" add -A
git -C "$reuse" commit -qm base
git -C "$reuse" worktree add -q .claude/worktrees/feat -b feat
LINKED="$reuse/.claude/worktrees/feat"

# 22a. A pre-existing worktree in a home that has stopped being ignored — the rule was committed and
#      a later edit dropped it, so nothing about creation was ever wrong and no creation-time check
#      would ever run again. Judged at the main checkout root, the guard refuses. This is the state
#      today; moving the call site must keep it so.
: > "$reuse/.gitignore"
rc=0; bash "$KIT/$GUARD" -C "$reuse" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL [reuse-main-root]: expected exit 1 for a reused worktree in an unignored home, got $rc"; exit 1; }
echo "  ok: reuse-main-root — a pre-existing worktree in an unignored home is refused"

# 22b. THE trap the move creates. Point the same guard at the worktree being reused and it answers
#      0 — the linked checkout still holds the committed .gitignore, so `.claude/worktrees/` is
#      "ignored" relative to a directory the hazard is not in. The hazard is real: `git add -A` in
#      the MAIN checkout stages the gitlink, asserted below so this cannot become folklore.
rc=0; bash "$KIT/$GUARD" -C "$LINKED" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || {
  echo "FAIL [reuse-wrong-root]: expected the linked worktree to answer 0 (fail-open), got $rc."
  echo "  If this changed, git stopped resolving the anchored pattern per-directory and the"
  echo "  main-root recipe in skills/_shared/worktree-ignore-check.md can be simplified."; exit 1; }
git -C "$reuse" add -A 2>/dev/null
# Herestring, not a pipe into `grep -q` (#391).
staged_mode=$(git -C "$reuse" ls-files -s -- .claude/worktrees/feat)
grep -q '^160000 ' <<<"$staged_mode" || {
  echo "FAIL [reuse-wrong-root]: the fail-open case is not actually hazardous — control invalid"; exit 1; }
git -C "$reuse" rm -r -q --cached .claude
echo "  ok: reuse-wrong-root — judging the reused worktree instead of its checkout fails OPEN"

# 22c. The recipe that closes 22b, and the reason the shared reference spells it out: from anywhere
#      inside a repo — main checkout or linked worktree — the first `worktree list --porcelain`
#      entry is the main worktree. Idempotent, so one call serves the created and reused paths
#      alike, which is the whole point of moving the check to where $WORKTREE is bound.
#      Compared as PHYSICAL paths: git reports the resolved path, and on macOS the scratch dir
#      arrives via the /var -> /private/var symlink, so a literal string compare fails on the
#      symlink rather than on the recipe.
#      One spelling only — case 23 exercises the same line against bare repos and spaced paths.
reuse_phys=$(cd "$reuse" && pwd -P)
main_root=$(git -C "$LINKED" worktree list --porcelain | sed -n '1s/^worktree //p')
[ "$main_root" = "$reuse_phys" ] || {
  echo "FAIL [reuse-main-root-recipe]: expected '$reuse_phys', got '$main_root'"; exit 1; }
[ "$(git -C "$reuse" worktree list --porcelain | sed -n '1s/^worktree //p')" = "$reuse_phys" ] || {
  echo "FAIL [reuse-main-root-recipe]: the recipe is not idempotent from the main checkout"; exit 1; }
rc=0; bash "$KIT/$GUARD" -C "$main_root" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL [reuse-main-root-recipe]: the recipe's root did not reproduce the refusal, got $rc"; exit 1; }
echo "  ok: reuse-main-root-recipe — worktree list --porcelain yields the checkout the hazard is in"

# 23. THE RECIPE the skills use to derive that root (#86). Case 22 proves the guard needs the main
#     checkout; this proves the one line documented in skills/_shared/worktree-ignore-check.md
#     actually produces it. It lives here because the first version of that recipe
#     (`head -1 | cut -d' ' -f2-`, no bare handling) was measured HARD-STOPPING a correctly
#     configured bare repository — a false refusal a reader cannot unblock, since the .gitignore it
#     asks for is already there.
main_worktree() {                                # the documented recipe, behaviourally identical
  local list; list=$(git -C "$1" worktree list --porcelain)
  local root; root=$(printf '%s\n' "$list" | sed -n '1s/^worktree //p')
  # A herestring, not a pipe into `grep -q` (#391): see skills/_shared/worktree-ignore-check.md's
  # illustrative snippet for the pipe form this mirrors, made race-safe the way main-worktree.sh is.
  local second_line; second_line=$(printf '%s\n' "$list" | sed -n '2p')
  grep -qx bare <<<"$second_line" && root=''
  printf '%s' "$root"
}

# 23a. Normal layout: identical answer from the main checkout and from inside a linked worktree.
#      The second half is the whole point — that is where $WORKTREE points on the reuse path.
rec="$WORK/rec"
mkdir -p "$rec"
git -C "$rec" init -q -b main
git -C "$rec" config user.email t@example.com
git -C "$rec" config user.name "Golden Test"
printf 'x\n' > "$rec/tracked.txt"
git -C "$rec" add -A
git -C "$rec" commit -qm base
git -C "$rec" worktree add -q .claude/worktrees/feat -b feat
rec_phys=$(cd "$rec" && pwd -P)                  # git reports resolved paths; macOS /var -> /private/var
[ "$(main_worktree "$rec")" = "$rec_phys" ] || {
  echo "FAIL [recipe-main]: from the main checkout, got '$(main_worktree "$rec")'"; exit 1; }
[ "$(main_worktree "$rec/.claude/worktrees/feat")" = "$rec_phys" ] || {
  echo "FAIL [recipe-linked]: from the linked worktree, got '$(main_worktree "$rec/.claude/worktrees/feat")'"; exit 1; }
echo "  ok: recipe — same main-checkout root from the checkout and from a linked worktree"

# 23b. THE regression. A bare repo with linked worktrees: the first entry IS the bare repository,
#      `check-ignore` cannot run in it ("must be run in a work tree"), and the guard would report
#      that as "NOT ignored" — refusing a repo whose .gitignore is already correct. There is no
#      hazard to guard either: a bare repo has no working tree for `git add -A` to run in. The
#      recipe must therefore yield NOTHING, and the caller skips the check.
bare="$WORK/bare.git"
git init -q --bare "$bare"
git -C "$rec" push -q "$bare" main
git -C "$bare" worktree add -q "$bare/.claude/worktrees/g" main
[ -z "$(main_worktree "$bare")" ] || {
  echo "FAIL [recipe-bare]: expected no root for a bare repo, got '$(main_worktree "$bare")'"; exit 1; }
[ -z "$(main_worktree "$bare/.claude/worktrees/g")" ] || {
  echo "FAIL [recipe-bare-linked]: expected no root from a bare repo's worktree"; exit 1; }
# And the control: had the caller passed the bare path anyway, the guard really does misreport.
rc=0; bash "$KIT/$GUARD" -C "$bare" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || {
  echo "FAIL [recipe-bare]: expected the guard to misjudge a bare repo (exit 1), got $rc — if this"
  echo "  changed, check-ignore learned to run in a bare repo and the skip may be droppable"; exit 1; }
echo "  ok: recipe — a bare repository yields no root, so the check is skipped rather than failed"

# 23c. A checkout under a path containing a space. `awk '{print $2}'` — the spelling this repo used
#      in merge-mechanics §7 — truncates at the space; the sed spelling does not.
spaced="$WORK/my repo"
mkdir -p "$spaced"
git -C "$spaced" init -q -b main
git -C "$spaced" config user.email t@example.com
git -C "$spaced" config user.name "Golden Test"
printf 'x\n' > "$spaced/tracked.txt"
git -C "$spaced" add -A
git -C "$spaced" commit -qm base
spaced_phys=$(cd "$spaced" && pwd -P)
[ "$(main_worktree "$spaced")" = "$spaced_phys" ] || {
  echo "FAIL [recipe-space]: got '$(main_worktree "$spaced")', expected '$spaced_phys'"; exit 1; }
echo "  ok: recipe — a path containing a space survives (the awk spelling truncates it)"

# ------------------------------------------------- a host without `rev` (#174)

# 24. rule_source() used to end `… | cut -f1 | rev | cut -d: -f3- | rev`, and `rev` is util-linux:
#     Git Bash does not ship it. The pipeline then produced NOTHING, durability_note() took its ""
#     branch, and a rule committed at .gitignore:25 was reported as "rule source unknown — treat
#     'ignored' as unverified beyond this checkout" — the caveat meant for "we could not tell where
#     the rule lives", on the one case it exists to distinguish from a global excludes file. It
#     matters more than a cosmetic note because init WRITES that verdict down as a
#     durable fact about the repository.
#
#     Reproduced on any host with a PATH-front shim whose `rev` exits 127, which is what the missing
#     binary looks like from inside the script. Asserted as a PAIR: silence alone would also be what
#     a rule_source() that returned nothing at all produces, so 24b requires the source to be NAMED
#     under the same shim.
#
#     These two build their own repositories rather than calling scratch(): scratch() sets up no
#     commit identity, and 24a needs to `git commit` with no `-c user.email=…` override of its own
#     — unlike case 21, which passes that override inline. revless_repo() exists to pre-set
#     user.email/user.name once instead of repeating that override at every commit-needing call.
revless_repo() {                                 # $1 = directory, $2 = .gitignore body (printf %b)
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name "Golden Test"
  printf '%b' "$2" > "$1/.gitignore"
}

shim="$WORK/rev-less"
mkdir -p "$shim"
# The shim prints on stderr as well as exiting 127: on a real rev-less host the message comes from
# bash ("line 120: rev: command not found"), not from rev, and 24a asserts that it is gone.
printf '%s\n' '#!/bin/sh' 'echo "rev: command not found" >&2' 'exit 127' > "$shim/rev"
chmod +x "$shim/rev"
rc=0; ( PATH="$shim:$PATH"; rev </dev/null >/dev/null 2>&1 ) || rc=$?
[ "$rc" -eq 127 ] || { echo "FAIL [rev-less]: the shim does not simulate a missing rev (exit $rc)"; exit 1; }

# 24a. The committed case, which is this repo's own and the one #174 measured wrong. A tracked
#      .gitignore must carry NO durability note at all — case 21's assertion, under the shim.
dir="$WORK/revless-committed"
revless_repo "$dir" '.claude/worktrees/\n.worktrees/\n'
git -C "$dir" add .gitignore
git -C "$dir" commit -qm "ignore worktree homes"
git -C "$dir" ls-files --error-unmatch .gitignore >/dev/null 2>&1 \
  || { echo "FAIL [rev-less-committed]: fixture bug — .gitignore is not tracked"; exit 1; }
# `|| rc=$?`, like verdict() does, and for the reason verdict() does it: under this file's
# `set -euo pipefail` an unexpected non-zero exit here would abort the suite AT this line — no
# FAIL line, no case 24b, and a reader left to work out from a bare exit code which case died.
rc=0; out=$(PATH="$shim:$PATH" bash "$KIT/$GUARD" -C "$dir" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [rev-less-committed]: the guard exited $rc on a correctly configured repo:"; echo "$out"; exit 1; }
grep -qF 'rule source unknown' <<<"$out" \
  && { echo "FAIL [rev-less-committed]: a committed rule was reported as unverified on a rev-less host:"; echo "$out"; exit 1; }
grep -qF 'command not found' <<<"$out" \
  && { echo "FAIL [rev-less-committed]: the guard still shells out to rev:"; echo "$out"; exit 1; }
echo "  ok: rev-less-committed — a tracked rule carries no false 'unverified' caveat without rev"

# 24b. The positive control. A machine-local rule must still be NAMED — if rule_source() merely
#      returned empty more quietly, 24a would pass and the guard would have lost the distinction
#      between "committed" and "this machine only" that callers write down.
dir="$WORK/revless-local"
revless_repo "$dir" ''
printf '.claude/worktrees/\n.worktrees/\n' >> "$dir/.git/info/exclude"
rc=0; out=$(PATH="$shim:$PATH" bash "$KIT/$GUARD" -C "$dir" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [rev-less-local-exclude]: the guard exited $rc on an ignored repo:"; echo "$out"; exit 1; }
grep -qF '.git/info/exclude' <<<"$out" \
  || { echo "FAIL [rev-less-local-exclude]: the rule source is not named on a rev-less host:"; echo "$out"; exit 1; }
echo "  ok: rev-less-local-exclude — the rule source is still named without rev"

# 24c. The Windows spelling of 24b. `check-ignore -v` names a global excludes file exactly as
#      core.excludesFile spells it, so on Git Bash the source comes back as `C:/Users/…/ignore` —
#      no leading `/`, which is what durability_note()'s global-excludes arm used to match on. It
#      fell through to the "not tracked by git … commit it" branch, telling the user to commit
#      their global excludes file on the one host this change is for.
#
#      Reproducible here because git prints the configured path verbatim and a directory may be
#      called `C:` on Linux — so the drive-letter SHAPE is testable without a Windows host, which
#      is the whole trick this suite needs.
dir="$WORK/revless-drive"
revless_repo "$dir" ''
mkdir -p "$dir/C:/fake"
printf '.claude/worktrees/\n.worktrees/\n' > "$dir/C:/fake/ignore"
git -C "$dir" config core.excludesFile "C:/fake/ignore"
# Herestring, not a pipe into `grep -q` (#391).
ignore_source=$(git -C "$dir" check-ignore -v .claude/worktrees/)
grep -q '^C:/fake/ignore:' <<<"$ignore_source" \
  || { echo "FAIL [drive-letter]: fixture bug — git did not report a drive-letter source"; exit 1; }
rc=0; out=$(PATH="$shim:$PATH" bash "$KIT/$GUARD" -C "$dir" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [drive-letter]: the guard exited $rc on an ignored repo:"; echo "$out"; exit 1; }
grep -qF 'a global excludes file' <<<"$out" \
  || { echo "FAIL [drive-letter]: a C:/ excludes file is not classified as a global one:"; echo "$out"; exit 1; }
grep -qF 'commit it' <<<"$out" \
  && { echo "FAIL [drive-letter]: the guard told the user to commit their global excludes file:"; echo "$out"; exit 1; }
echo "  ok: drive-letter — a C:/ excludes file reads as global, not as an uncommitted repo file"

echo "worktrees-ignored golden test OK"
