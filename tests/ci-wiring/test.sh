#!/usr/bin/env bash
# Golden test for scripts/ci-wiring-check.py — the guard that every tests/<name>/test.sh is run
# by a CI step that can actually fail the build (#45).
#
# What this suite guards:
#   1. the happy path on THIS repo — the real tests/ and the real .github/workflows/
#   2. a suite nothing invokes                        -> REFUSE, naming it
#   3. a step that is commented out                   -> REFUSE (the path survives as comment text)
#   4. a step marked continue-on-error: true          -> REFUSE (runs, fails, build stays green)
#   5. a step marked if: false                        -> REFUSE (never runs)
#   6. `run: ./tests/x/test.sh || true`               -> REFUSE (exit status discarded)
#   7. a workflow with no automatic trigger           -> REFUSE (workflow_dispatch is not CI)
#   8. a pull_request-only workflow                   -> REFUSE (#133: never runs on a push to main)
#   9. push-to-main AND pull_request                  -> accept (the fix must not refuse ci.yml)
#  10. every other `push:` filter shape               -> the branch filter is actually read
#  11. an empty tests/ directory                      -> REFUSE, never a vacuous "all wired"
#  12. every tests/<name>/ named in README.md exists  -> the prose cannot outlive the directory
#  13. wired, but committed 100644 (Windows core.filemode=false) -> REFUSE, naming the mode + fix
#  14. the happy path stays a pass with a real, staged 100755 fixture
#  15. not a git repository at all                    -> REFUSE, mode is unknowable, not a pass
#  16. a suite committed as a symlink (120000)         -> REFUSE, without the fatal --chmod=+x fix
#  17. a suite name git quotes (non-ASCII)             -> still caught at the wrong mode
#  18. both defects at once (unreadable index AND a genuinely unwired suite) -> both are named
#  19. a suite that is wired but never `git add`ed        -> REFUSE, naming it and the `git add` fix
#  20. a suite that is BOTH untracked AND unwired          -> both reasons named, neither contradicts
#      the other (the "not executable" reason must not claim CI invokes a suite the "not enforced"
#      reason just said nothing invokes)
#  21. untracked AND wired-but-continue-on-error          -> REFUSE, but never claims "no step
#      invokes it" — a step does, it just can't fail the build (#238)
#  22. untracked AND wired-but-pull_request-only          -> same contradiction, reached via the
#      workflow-level reason instead of the step-level one (#238)
#  23. wrong index mode AND genuinely uninvoked            -> the sibling contradiction on the
#      wrong-mode print branch, mirroring 21/22 on the mode-is-None branch (#238)
#
# The refusal cases are the point. A gate is worth exactly what its refusal path is worth, and an
# inline `run:` block cannot have one — which is why scripts/release-title-gate.sh was extracted
# from yaml after its inline version failed open, and why this one starts out extracted.
#
# Section lines carry a label, never a fraction: a denominator goes stale the moment a section is
# added, and a stale one reads as a run that stopped early.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO/scripts/ci-wiring-check.py"
# Scratch dir and EXIT trap come from the shared preamble (#72).
#
# Sourced via $REPO, never $PWD: this suite deliberately does NOT cd — it is written to run from
# anywhere — and it sets `set -uo pipefail` without `-e`. With `$PWD` the source silently failed
# off-root, `kit_init`/`kit_scratch` were then "command not found", `WORK` stayed empty, and every
# fixture path resolved against the filesystem ROOT (`mkdir /uninvoked`, `rm -rf /empty/tests`).
# CI never saw it because CI invokes from the repo root.
. "$REPO/tests/_lib.sh" || {
  echo "FAIL: cannot source $REPO/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$REPO"
# The kit's ONE importlib loader (#42, #51) — sections 24-25 drive functions of the checker
# directly, which is what makes a Windows-only defect reproducible on the Linux runner.
kit_source "$REPO/tests/_lib/py.sh"
WORK=$(kit_scratch)

fails=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# Refusal fixtures are built by mutating a scaffolded workflow — with sed for the step-level cases,
# by overriding $TRIGGERS for the workflow-level ones — and a fixture that did not come out as
# intended would ALSO be refused: by accident, for the wrong reason, reading as a pass. So each one
# is asserted against the parsed yaml before its verdict is trusted. (`\n` in a sed replacement is a
# GNU extension; this is what catches it if the suite is ever run where sed behaves differently.)
assert_parsed() {
  local file="$1" expr="$2" label="$3"
  python3 -c "
import sys, yaml
d = yaml.safe_load(open('$file'))
sys.exit(0 if ($expr) else 1)
" 2>/dev/null || { bad "fixture bug — $label did not come out as intended"; return 1; }
  return 0
}

# Run the checker over a scratch repo; echo its output, return its status.
run_check() { python3 "$CHECK" --repo "$1" 2>&1; }

# The `on:` block scaffold() writes. The default is the shape the real ci.yml carries — a push to
# `main` AND pull requests — because that is what every step-level fixture below means by "an
# otherwise normal CI workflow". It used to be `pull_request:` alone, which was harmless only while
# the guard treated the four automatic triggers as interchangeable; once a PR-only workflow is a
# refusal in its own right (#133), a PR-only scaffold would give sections 2-6 a SECOND, workflow-level
# reason to refuse, and each of those assertions would then pass without proving the step-level
# defect it names.
#
# A fixture that is about the trigger itself sets TRIGGERS before calling scaffold; scaffold resets
# it afterwards, so an override can never leak into the next fixture.
DEFAULT_TRIGGERS=$'on:\n  push:\n    branches: [main]\n  pull_request:'
TRIGGERS="$DEFAULT_TRIGGERS"

# Build a scratch repo with the named suites and one workflow that wires all of them. Each
# scratch root is a real git repository — the mode probe reads the INDEX, never the filesystem
# (that is the whole point: a Windows checkout's working-copy mode lies), so a fixture with no
# `.git` at all would make the probe refuse every section below for "not a repository" instead of
# whatever that section actually means to test. Every suite is staged at its real, correct 100755
# here; the sections that mean to test the mode probe itself override one path afterwards.
scaffold() {
  local root="$1"; shift
  mkdir -p "$root/.github/workflows"
  git -C "$root" init -q
  # `core.filemode` is normally decided by git probing whether the filesystem preserves the
  # executable bit at all — that probe, not the config file, is what `chmod +x` below actually
  # depends on. Pinned explicitly so every section below stages a real 100755, regardless of
  # $TMPDIR landing on a filesystem where the probe would otherwise say false (a Windows/WSL
  # DrvFs mount, some Docker bind-mounts) — the exact class of host this whole suite is about.
  git -C "$root" config core.filemode true
  local s
  for s in "$@"; do
    mkdir -p "$root/tests/$s"
    touch "$root/tests/$s/test.sh"
    chmod +x "$root/tests/$s/test.sh"
    git -C "$root" add -- "tests/$s/test.sh"
  done
  {
    echo 'name: ci'
    printf '%s\n' "$TRIGGERS"
    echo 'jobs:'
    echo '  kit:'
    echo '    runs-on: ubuntu-latest'
    echo '    steps:'
    for s in "$@"; do
      echo "      - name: $s golden test"
      echo "        run: ./tests/$s/test.sh"
    done
  } > "$root/.github/workflows/ci.yml"
  TRIGGERS="$DEFAULT_TRIGGERS"
}

# Restage an already-tracked suite at an arbitrary index mode, and prove the restage took — a
# fixture that silently stayed at 100755 would pass every assertion below for the wrong reason.
# Shared by sections 13, 16 and 17, which differ only in the mode, the path, and the label on a
# fixture-bug failure.
stage_at_mode() {
  local root="$1" path="$2" mode="$3" label="$4" sha
  sha=$(git -C "$root" hash-object -w "$root/$path")
  git -C "$root" update-index --add --cacheinfo "$mode,$sha,$path"
  [ "$(git -C "$root" ls-files -s -z -- "$path" | awk '{print $1}')" = "$mode" ] \
    || bad "fixture bug: $path was not restaged at $mode ($label)"
}

echo "== ci-wiring-check golden test =="

# --------------------------------------------------------------- 1. the real repo passes
out=$(run_check "$REPO"); rc=$?
if [ $rc -eq 0 ]; then ok "this repo: every suite is enforced by CI"
else bad "this repo should pass but did not:"; printf '%s\n' "$out" | sed 's/^/        /'; fi

# --------------------------------------------------------------- 2. an uninvoked suite
R="$WORK/uninvoked"; scaffold "$R" alpha beta
mkdir -p "$R/tests/orphan"; touch "$R/tests/orphan/test.sh"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && grep -q 'tests/orphan/test.sh' <<<"$out"; then
  ok "a suite nothing invokes is refused, and named"
else bad "expected refusal naming tests/orphan/test.sh; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 3. commented-out step
# The regression that made this a script: `grep` on the raw file accepts the leftover comment
# text, so the disabled suite reads as wired. Parsing the yaml removes the step entirely.
R="$WORK/commented"; scaffold "$R" alpha beta
sed -i.bak 's|^      - name: beta golden test|#      - name: beta golden test|; s|^        run: ./tests/beta/test.sh|#        run: ./tests/beta/test.sh|' \
  "$R/.github/workflows/ci.yml"
grep -q '^#        run: ./tests/beta/test.sh' "$R/.github/workflows/ci.yml" \
  || bad "fixture bug: the beta step was not commented out"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && grep -q 'tests/beta/test.sh' <<<"$out"; then
  ok "a commented-out step does not count as wired"
else bad "expected refusal for the commented-out beta step; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 4. continue-on-error
R="$WORK/soft"; scaffold "$R" alpha beta
sed -i.bak 's|^        run: ./tests/beta/test.sh|        continue-on-error: true\n        run: ./tests/beta/test.sh|' \
  "$R/.github/workflows/ci.yml"
assert_parsed "$R/.github/workflows/ci.yml" \
  "d['jobs']['kit']['steps'][1].get('continue-on-error') is True" "continue-on-error"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && grep -q 'cannot fail the build' <<<"$out"; then
  ok "continue-on-error: true does not count as wired"
else bad "expected refusal for continue-on-error; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 5. if: false
R="$WORK/iffalse"; scaffold "$R" alpha beta
sed -i.bak 's|^        run: ./tests/beta/test.sh|        if: false\n        run: ./tests/beta/test.sh|' \
  "$R/.github/workflows/ci.yml"
assert_parsed "$R/.github/workflows/ci.yml" \
  "d['jobs']['kit']['steps'][1].get('if') is False" "if: false"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && grep -q 'cannot fail the build' <<<"$out"; then
  ok "if: false does not count as wired"
else bad "expected refusal for if: false; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 6. `|| true`
R="$WORK/ortrue"; scaffold "$R" alpha beta
sed -i.bak 's|^        run: ./tests/beta/test.sh|        run: ./tests/beta/test.sh \|\| true|' \
  "$R/.github/workflows/ci.yml"
assert_parsed "$R/.github/workflows/ci.yml" \
  "d['jobs']['kit']['steps'][1]['run'].strip().endswith('|| true')" "|| true"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && grep -q 'tests/beta/test.sh' <<<"$out"; then
  ok "a discarded exit status (|| true) does not count as wired"
else bad "expected refusal for '|| true'; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 7. no automatic trigger
R="$WORK/manual"; TRIGGERS=$'on:\n  workflow_dispatch:'; scaffold "$R" alpha
# PyYAML reads YAML 1.1, so the bare key `on:` is the boolean True, not the string "on".
assert_parsed "$R/.github/workflows/ci.yml" \
  "list(d.get('on', d.get(True))) == ['workflow_dispatch']" "workflow_dispatch-only trigger"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && grep -q 'no automatic trigger' <<<"$out"; then
  ok "a workflow_dispatch-only workflow is not CI"
else bad "expected refusal for a manual-only workflow; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 8. pull_request-only workflow
# #133. `push`, `pull_request`, `pull_request_target` and `schedule` used to be interchangeable
# evidence of "automatically triggered", and any one of them was enough. That was accidentally
# sufficient only because ci.yml was the sole run:-bearing workflow in the repo and it carries BOTH
# push-to-main and pull_request — so "automatically triggered" silently also meant "runs on main".
# #119 added .github/workflows/release-title.yml, triggered on pull_request alone, and removed the
# coincidence. A suite wired only there never runs on the push that lands on `main`, which is the
# last verdict before release-please cuts a tag: green guard, absent coverage, no diagnostic — the
# guard's own stated failure mode, reappearing through a case its model did not represent.
R="$WORK/pronly"; TRIGGERS=$'on:\n  pull_request:'; scaffold "$R" alpha
assert_parsed "$R/.github/workflows/ci.yml" \
  "list(d.get('on', d.get(True))) == ['pull_request']" "pull_request-only trigger"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && grep -q 'tests/alpha/test.sh' <<<"$out" \
   && grep -q 'never on a push to main' <<<"$out"; then
  ok "a pull_request-only workflow does not count as enforcing a suite"
else bad "expected refusal naming tests/alpha/test.sh and the PR-only reason; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 9. both triggers still pass
# The other half of #133, and the one that costs something if it breaks: requiring a push-to-main
# trigger must NOT over-refuse the real ci.yml, which carries `push: branches: [main]` alongside
# `pull_request`. Section 1 already asserts that against the live repo, but section 1 fails for any
# reason at all; this pins the specific shape, so the guarantee survives an unrelated edit to this
# repo's own workflows.
R="$WORK/bothtriggers"; scaffold "$R" alpha beta
assert_parsed "$R/.github/workflows/ci.yml" \
  "sorted(d.get('on', d.get(True))) == ['pull_request', 'push']
   and d.get('on', d.get(True))['push']['branches'] == ['main']" \
  "push-to-main plus pull_request"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 0 ]; then
  ok "a workflow on both push:main and pull_request still counts as enforcing"
else bad "expected acceptance for a push:main + pull_request workflow; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 10. the branch filter is read
# "Runs on a push to main" is not "has a push: key": the branch filter decides it, and most of the
# shapes below are a way for a push trigger to exist and still never fire on `main`. Table-driven,
# because the interesting part is the filter rather than the fixture — one section apiece would be a
# dozen near-identical copies of the block above.
#
# The `!` rows are the subtle ones. `!` is filter syntax, not part of a branch name, and GitHub lets
# the LAST matching pattern in the list decide — so `["**", "!main"]` does NOT run on main and
# `["!main", "**"]` does. Read as an unordered "does any pattern match", the first of those two
# reads as enforced: the same fail-open this whole issue is about, one level down inside the fix.
#
# Each case is asserted parsed before its verdict is read, for the reason at the top of this file:
# a mangled `on:` block would be refused too, by accident, and every want=1 row would then pass
# without exercising anything. The reason substring is the second half of that guard — it is what
# separates "refused because the branch filter misses main" from "refused for some other reason".
trigger_case() {
  local name="$1" on_block="$2" want="$3" label="$4" expect="${5:-}"
  local R="$WORK/trigger-$name" out rc
  TRIGGERS="$on_block"; scaffold "$R" alpha
  assert_parsed "$R/.github/workflows/ci.yml" \
    "bool(d.get('on', d.get(True)))
     and d['jobs']['kit']['steps'][0]['run'].strip() == './tests/alpha/test.sh'" \
    "$label" || return
  out=$(run_check "$R"); rc=$?
  if [ "$rc" -ne "$want" ]; then
    bad "$label: expected exit $want, got $rc: $out"; return
  fi
  if [ -n "$expect" ] && ! grep -q "$expect" <<<"$out"; then
    bad "$label: exit $want as expected, but the reason never said '$expect': $out"; return
  fi
  ok "$label"
}

trigger_case nofilter $'on:\n  push:' 0 \
  "push: with no branches filter runs on every branch, main included"
trigger_case listwithmain $'on:\n  push:\n    branches: [main, release/*]' 0 \
  "a branches list that names main counts"
trigger_case listwithoutmain $'on:\n  push:\n    branches: [release/*]' 1 \
  "a branches list that never matches main does not count" \
  "push trigger does not reach main"
trigger_case glob $'on:\n  push:\n    branches: ["ma*"]' 0 \
  "a branches glob that matches main counts"
trigger_case ignoremain $'on:\n  push:\n    branches-ignore: [main]' 1 \
  "branches-ignore: [main] excludes the one branch that matters" \
  "push trigger does not reach main"
trigger_case ignoreother $'on:\n  push:\n    branches-ignore: [docs/**]' 0 \
  "branches-ignore that spares main still counts"
trigger_case negated $'on:\n  push:\n    branches: ["**", "!main"]' 1 \
  "a negated pattern AFTER a match takes main back out" \
  "push trigger does not reach main"
trigger_case renegated $'on:\n  push:\n    branches: ["!main", "**"]' 0 \
  "a positive pattern after a negation puts main back in"
trigger_case nullbranches $'on:\n  push:\n    branches:' 1 \
  "a branches: key whose every entry is commented out selects nothing" \
  "push trigger does not reach main"
trigger_case emptybranches $'on:\n  push:\n    branches: []' 1 \
  "an empty branches list selects nothing" \
  "push trigger does not reach main"
trigger_case bothfilters $'on:\n  push:\n    branches: [main]\n    branches-ignore: [docs/**]' 1 \
  "branches and branches-ignore together is an invalid trigger, not a passing one" \
  "both branches and branches-ignore"
trigger_case bothfiltersnull $'on:\n  push:\n    branches:\n    branches-ignore: [docs/**]' 1 \
  "a null branches: still counts as set, so the invalid combination is still caught" \
  "both branches and branches-ignore"
trigger_case tagsonly $'on:\n  push:\n    tags: ["v*"]' 1 \
  "a tags-only push trigger never fires on a branch push" \
  "push trigger does not reach main"
trigger_case scheduleonly $'on:\n  schedule:\n    - cron: "0 3 * * *"' 1 \
  "a nightly schedule is not the merge gate" \
  "runs on a schedule only"

# --------------------------------------------------------------- 11. empty tests/
# Without this the glob matches nothing, the loop body never runs, and the checker would report
# "0 suites, all wired" — a pass that means the opposite of what it says.
R="$WORK/empty"; scaffold "$R" alpha
rm -rf "$R/tests"; mkdir -p "$R/tests"
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] && grep -q 'refusing to report' <<<"$out"; then
  ok "an empty tests/ refuses instead of passing vacuously"
else bad "expected refusal on an empty tests/; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 12. README names real directories
# The README paragraph on hardening a destructive operation cites suites by name. That is a small
# enumeration of exactly the kind this issue removed, so it is pinned rather than trusted.
missing=
while read -r d; do
  [ -z "$d" ] && continue
  [ -d "$REPO/$d" ] || missing="$missing $d"
done < <(grep -oE 'tests/[a-z0-9][a-z0-9-]*/' "$REPO/README.md" | sort -u)
if [ -z "$missing" ]; then
  ok "every tests/<name>/ named in README.md exists"
else
  bad "README.md names directories that do not exist:$missing"
fi

# --------------------------------------------------------------- 13. wired, but committed 100644
# #195. A suite whose step is invoked by a workflow that runs on a push to main — every rule above
# is satisfied — is still worthless if CI cannot execute the file. `git config core.filemode` is
# false on a Windows checkout, so `chmod +x` never reaches the INDEX and the suite is committed
# 100644; CI's `./tests/x/test.sh` then dies with "Permission denied", exit 126, on a commit this
# checker called fully enforced (PR #193). The working-copy mode set by scaffold()'s `chmod +x`
# above is a decoy here on purpose — it is what a Windows contributor's own working copy would also
# show, and it is not what CI reads.
R="$WORK/badmode"; scaffold "$R" alpha beta
stage_at_mode "$R" tests/beta/test.sh 100644 "wired but committed 100644"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && grep -q 'tests/beta/test.sh' <<<"$out" \
   && grep -q '100644' <<<"$out" \
   && grep -q 'git update-index --chmod=+x tests/beta/test.sh' <<<"$out"; then
  ok "a suite committed 100644 is refused, naming the mode and the remedy"
else bad "expected refusal naming tests/beta/test.sh, its mode and the remedy; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 14. the happy path stays a pass
# The companion to 13: this same probe must not turn the ordinary 100755 case scaffold() now
# builds into an accidental refusal. Section 1 already covers the real repo; this pins the shape
# a scratch fixture produces, so the guarantee survives an unrelated edit to scaffold() itself.
R="$WORK/goodmode"; scaffold "$R" alpha beta
out=$(run_check "$R"); rc=$?
if [ $rc -eq 0 ]; then
  ok "suites staged 100755 are not reported as inexecutable"
else bad "expected acceptance for a normally-staged fixture; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 15. not a git repository at all
# The mode is unknowable here, not merely "not 100755" — a directory with no `.git` cannot answer
# `git ls-files -s`. Reporting every suite as fine would be the exact failure this issue closes,
# one layer further down: an unanswerable question read as a pass. `worktrees-ignored.sh` applies
# the same rule to its own verdict.
R="$WORK/notarepo"; scaffold "$R" alpha
rm -rf "$R/.git"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && grep -qi 'index' <<<"$out"; then
  ok "a directory that is not a git repository refuses rather than reporting every suite fine"
else bad "expected refusal naming the unreadable index; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 16. a suite committed as a symlink
# `120000` is not `100644` — the "wrong mode" case above would not catch it by accident — and CI
# would follow the link rather than refuse it outright. The kit ships no symlinked suite; accepting
# a mode nobody intended is how the next hole opens, so this is refused on the same footing as an
# ordinary non-executable file.
#
# The remedy text is asserted, not just the refusal: `git update-index --chmod=+x` — the fix
# printed for the 100644 case in section 13 — FATALS on a symlink entry ("cannot chmod +x"), so
# printing it here unconditionally would hand a contributor a command that cannot work. Confirmed
# by hand before this assertion was written: `git update-index --chmod=+x` against a 120000 entry
# exits 128 with "fatal: git update-index: cannot chmod +x".
R="$WORK/symlink"; scaffold "$R" alpha
stage_at_mode "$R" tests/alpha/test.sh 120000 "wired but committed as a symlink"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && grep -q 'tests/alpha/test.sh' <<<"$out" \
   && grep -q '120000' <<<"$out" \
   && ! grep -q -- '--chmod=+x tests/alpha/test.sh' <<<"$out"; then
  ok "a suite committed as a symlink (120000) is refused, without the fatal --chmod=+x remedy"
else bad "expected refusal naming tests/alpha/test.sh and mode 120000, without --chmod=+x; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 17. a suite name git quotes
# `git ls-files -s` C-quotes any path it considers unusual by default — every non-ASCII byte
# qualifies — so a plain-string lookup against its output misses such a path entirely: not a
# refusal, a silent "untracked, so skip it". A wired suite named tests/café/test.sh, committed
# 100644, must still be caught (measured before this fix: it was reported enforced, exit 0). This
# pins that index_modes() reads with `-z`, which turns quoting off, rather than a plain
# `git ls-files -s`.
R="$WORK/quoted"; scaffold "$R" café
stage_at_mode "$R" tests/café/test.sh 100644 "quoted path, wired but committed 100644"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && grep -q '100644' <<<"$out"; then
  ok "a suite whose name git quotes (non-ASCII) is still caught at the wrong mode"
else bad "expected refusal for tests/café/test.sh at 100644; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 18. both defects at once
# The wiring verdict is computed from the filesystem and the parsed workflow — it does not need
# git at all — so an unreadable index must not swallow it. Before this section's fix, computing
# `not_executable` returned early on `mode_error`, and a repo with BOTH a genuinely unwired suite
# AND an unreadable index only ever reported the index problem: fixing the index and re-running was
# the only way to learn about the unwired suite, one problem per run instead of both at once.
R="$WORK/bothdefects"; scaffold "$R" alpha
mkdir -p "$R/tests/orphan"; touch "$R/tests/orphan/test.sh"; chmod +x "$R/tests/orphan/test.sh"
rm -rf "$R/.git"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && grep -q 'tests/orphan/test.sh' <<<"$out" \
   && grep -qi 'index' <<<"$out"; then
  ok "an unreadable index still names a genuinely unwired suite in the same run"
else bad "expected both tests/orphan/test.sh AND the index problem named; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 19. a suite wired but never git-added
# #210. `tests/ghost/test.sh` exists on disk, is chmod +x'd, and is named by an enforcing step of a
# workflow that runs on a push to main — every rule above is satisfied — but it was never `git add`ed.
# `modes.get(suite)` is then simply absent from the index, and the old comprehension's `is not None`
# guard excluded untracked suites from `not_executable` entirely: the check reported the repo fully
# enforced (measured, issue #210). A suite absent from the index is absent from any real clone or CI
# checkout, so this must refuse on the same footing as a wrong mode, not silently pass.
R="$WORK/ghost"; scaffold "$R" alpha ghost
# scaffold() stages every suite it's given, including ghost — undo that one `git add` so the
# fixture matches its own name: staged on disk (+x, from scaffold's loop), absent from the index.
git -C "$R" rm --cached -q -- tests/ghost/test.sh
assert_parsed "$R/.github/workflows/ci.yml" \
  "any('ghost' in (s.get('run') or '') for s in d['jobs']['kit']['steps'])" \
  "ghost step wired into ci.yml"
[ -z "$(git -C "$R" ls-files -- tests/ghost/test.sh)" ] \
  || bad "fixture bug: tests/ghost/test.sh was staged — the whole point is that it is not"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && grep -q 'tests/ghost/test.sh' <<<"$out" \
   && grep -q 'not staged in the index at all' <<<"$out" \
   && grep -q 'git add tests/ghost/test.sh' <<<"$out"; then
  ok "a suite wired but never git-added refuses, naming it and the git add remedy"
else bad "expected refusal naming tests/ghost/test.sh and the git add remedy; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 20. untracked AND unwired, together
# The `not_executable` and `unwired` verdicts are computed independently (by design, see section 18),
# so a suite can legitimately land in both. Before this was guarded, the "not executable" heading's
# fixed wording — "CI invokes it as ./{suite}" — was printed even when the "not enforced by CI" heading
# directly above it had just said "no step invokes it": a self-contradictory refusal in the same run
# (measured). `tests/orphan2/test.sh` here is invoked by nothing AND never `git add`ed.
R="$WORK/ghostorphan"; scaffold "$R" alpha
mkdir -p "$R/tests/orphan2"; touch "$R/tests/orphan2/test.sh"; chmod +x "$R/tests/orphan2/test.sh"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && grep -q 'no step invokes it' <<<"$out" \
   && grep -q 'no step invokes it either' <<<"$out" \
   && ! grep -q 'CI invokes it as ./tests/orphan2/test.sh' <<<"$out"; then
  ok "a suite that is both untracked and unwired names both reasons without contradicting itself"
else bad "expected both reasons named, without the 'CI invokes it' claim; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 21. untracked AND continue-on-error
# #238. The `mode is None` print branch inferred "no step invokes it either" from `suite in unwired`
# alone — but `unwired` covers THREE distinct reasons (no step invokes it / a step invokes it but
# can't fail the build / a step invokes it but the workflow never runs on main), not just the first.
# `tests/beta/test.sh` here IS invoked, by a continue-on-error step (mirrors section 4's fixture),
# and is ALSO untracked (mirrors section 19's `git rm --cached`). The "not executable" message must
# not claim no step invokes it — one does, it just can't fail the build.
R="$WORK/softghost"; scaffold "$R" alpha beta
sed -i.bak 's|^        run: ./tests/beta/test.sh|        continue-on-error: true\n        run: ./tests/beta/test.sh|' \
  "$R/.github/workflows/ci.yml"
assert_parsed "$R/.github/workflows/ci.yml" \
  "d['jobs']['kit']['steps'][1].get('continue-on-error') is True" "continue-on-error (untracked variant)"
git -C "$R" rm --cached -q -- tests/beta/test.sh
[ -z "$(git -C "$R" ls-files -- tests/beta/test.sh)" ] \
  || bad "fixture bug: tests/beta/test.sh was staged — the whole point is that it is not"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && grep -q 'cannot fail the build' <<<"$out" \
   && ! grep -q 'no step invokes it either' <<<"$out" \
   && grep -q 'CI invokes it as ./tests/beta/test.sh' <<<"$out"; then
  ok "an untracked suite invoked by a continue-on-error step does not claim no step invokes it"
else bad "expected refusal without the false 'no step invokes it either' claim; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 22. untracked AND pull_request-only
# Same contradiction, reached via the workflow-level reason (#133) instead of the step-level one.
# `tests/ghost2/test.sh` is invoked by an otherwise-enforcing step on a pull_request-only workflow
# (mirrors section 8's fixture), and is ALSO untracked.
R="$WORK/prghost"; TRIGGERS=$'on:\n  pull_request:'; scaffold "$R" alpha ghost2
assert_parsed "$R/.github/workflows/ci.yml" \
  "list(d.get('on', d.get(True))) == ['pull_request']" "pull_request-only trigger (untracked variant)"
git -C "$R" rm --cached -q -- tests/ghost2/test.sh
[ -z "$(git -C "$R" ls-files -- tests/ghost2/test.sh)" ] \
  || bad "fixture bug: tests/ghost2/test.sh was staged — the whole point is that it is not"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && grep -q 'never on a push to main' <<<"$out" \
   && ! grep -q 'no step invokes it either' <<<"$out" \
   && grep -q 'CI invokes it as ./tests/ghost2/test.sh' <<<"$out"; then
  ok "an untracked suite invoked only on a pull_request-only workflow does not claim no step invokes it"
else bad "expected refusal without the false 'no step invokes it either' claim; got rc=$rc: $out"; fi

# --------------------------------------------------------------- 23. wrong mode AND genuinely uninvoked
# The sibling of section 21/22 on the OTHER print branch (~403-409): a suite committed at the wrong
# index mode that no step names at all (mirrors section 2's orphan, but staged 100644 instead of
# untracked). Before this diff the wrong-mode branch printed "CI invokes it as ./{suite}"
# unconditionally, contradicting the "not enforced" section's "no step invokes it" verdict for the
# very same suite in the very same run.
R="$WORK/badmodeorphan"; scaffold "$R" alpha
mkdir -p "$R/tests/orphan3"; touch "$R/tests/orphan3/test.sh"
stage_at_mode "$R" tests/orphan3/test.sh 100644 "wrong mode, nothing invokes it"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 1 ] && grep -q 'tests/orphan3/test.sh' <<<"$out" \
   && grep -q 'but no step invokes it either' <<<"$out" \
   && ! grep -q 'CI invokes it as ./tests/orphan3/test.sh' <<<"$out"; then
  ok "a suite committed at the wrong mode that nothing invokes does not claim CI invokes it"
else bad "expected refusal without the false 'CI invokes it' claim; got rc=$rc: $out"; fi

# --------------------------------------------------- 24. suite names are POSIX-spelled, off Windows
# #174, mechanism 2. `str(p.relative_to(repo))` joins with the PLATFORM separator, so on a native
# Windows checkout every suite came out `tests\preflight\test.sh` while .github/workflows/ci.yml
# spells `./tests/preflight/test.sh`. Nothing ever matched: the checker refused all 19 suites on a
# tree CI was green on.
#
# The derivation is a named function precisely so this case can exist. Driving it with
# PureWindowsPath objects reproduces the bug HERE, on Linux, where no amount of running the checker
# normally ever could — and PureWindowsPath has no `.glob()`, which is why `entries` is a parameter
# rather than something the function goes and fetches.
if py_module "$CHECK" <<'PYCASE'
import pathlib
repo = pathlib.PureWindowsPath(r"C:\repo\kit")
names = mod.suite_names(
    pathlib.PureWindowsPath(r"C:\repo\kit\tests"),
    repo,
    entries=[
        pathlib.PureWindowsPath(r"C:\repo\kit\tests\preflight\test.sh"),
        pathlib.PureWindowsPath(r"C:\repo\kit\tests\ci-wiring\test.sh"),
    ],
)
assert names == ["tests/ci-wiring/test.sh", "tests/preflight/test.sh"], names

# And the POSIX host is unchanged — the same call over PurePosixPath still yields the same strings,
# so `.as_posix()` is a no-op here rather than a second spelling to keep in step.
posix = mod.suite_names(
    pathlib.PurePosixPath("/repo/kit/tests"),
    pathlib.PurePosixPath("/repo/kit"),
    entries=[pathlib.PurePosixPath("/repo/kit/tests/preflight/test.sh")],
)
assert posix == ["tests/preflight/test.sh"], posix
PYCASE
then
  ok "suite_names spells suite paths with / even off a Windows-flavoured root"
else
  bad "suite_names did not produce POSIX suite names — a Windows checkout matches no workflow step"
fi

# ------------------------------------------------ 25. the workflows are read as UTF-8, not as locale
# #174, mechanism 4, and the one that sits IN FRONT of section 24's: on Windows this checker did not
# return the wrong verdict, it crashed before it could compute one —
#
#     UnicodeDecodeError: 'charmap' codec can't decode byte 0x8f  (load_workflows -> yaml.safe_load)
#
# `path.open()` with no `encoding=` uses the locale default, which is cp1252 there; both workflows
# carry non-Latin-1 UTF-8 bytes (an em-dash at ci.yml offset 8675). GitHub Actions guarantees these
# files are UTF-8, so the encoding is not a question the locale gets to answer.
#
# Driven over a SCAFFOLDED repo rather than over $REPO. Both probes below read a non-zero exit as
# their answer, and `--repo "$REPO"` exits 1 for an unwired suite, a wrong index mode or an untracked
# one too — every failure this suite exists to catch. Against the real repo a contributor who forgot
# to wire tests/foo/ would get section 1's true verdict AND a fabricated encoding defect beside it.
# The fixture is wired, staged and green by construction, so a non-zero exit here has one cause.
R="$WORK/encoding"; scaffold "$R" alpha
# The hazard, made explicit: a YAML comment carrying U+2014 — three UTF-8 bytes, undecodable as
# cp1252 (which is where 0x8f came from) and as ASCII.
printf '# an em-dash \xe2\x80\x94 undecodable as cp1252 or ASCII, fine as UTF-8\n' \
  >> "$R/.github/workflows/ci.yml"
if ! python3 -c "import sys; sys.exit(0 if any(b > 127 for b in open(sys.argv[1], 'rb').read()) else 1)" \
        "$R/.github/workflows/ci.yml"; then
  bad "fixture bug — the scaffolded workflow carries no non-ASCII byte, so neither probe can bite"
else
  out=$(run_check "$R"); rc=$?
  if [ $rc -ne 0 ]; then
    bad "control invalid — the encoding fixture is not otherwise a pass (rc=$rc): $out"
  else
    # PYTHONUTF8=0 and PYTHONCOERCECLOCALE=0 are both required: without them CPython turns the C
    # locale into UTF-8 on its own (PEP 538/540) and the case would pass for the wrong reason, so
    # the locale default is asserted before it is used.
    if LC_ALL=C LANG=C PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 python3 -c \
         'import locale, sys; sys.exit(0 if locale.getpreferredencoding(False).lower() in ("ansi_x3.4-1968", "ascii", "us-ascii") else 1)'; then
      out=$(LC_ALL=C LANG=C PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 python3 "$CHECK" --repo "$R" 2>&1); rc=$?
      if [ $rc -eq 0 ]; then
        ok "the workflows are decoded as UTF-8 under an ASCII locale (the Windows cp1252 shape)"
      else
        bad "the checker failed under an ASCII locale (rc=$rc) — it is reading files at the locale's"
        bad "  mercy, which is the crash Windows sees: $(printf '%s' "$out" | tail -1)"
      fi
    else
      # Not a failure of the checker — a newer CPython that no longer honours the locale here (PEP
      # 686 made UTF-8 mode the default in 3.15). Say so rather than reporting a green that proved
      # nothing; the EncodingWarning probe below still names the defect directly.
      ok "skipped — this CPython exposes no ASCII locale default, so the cp1252 shape is unreachable"
    fi

    # The same defect named directly, and the probe that survives the day the locale case above
    # stops being reachable. PEP 597's EncodingWarning fires on exactly the construct at fault — an
    # `open()` that let the locale decide — and turning it into an error makes it a red case rather
    # than a note. The message is asserted, not just the exit status: an EncodingWarning raised
    # inside an imported library would otherwise be reported as a defect of this checker.
    out=$(PYTHONWARNDEFAULTENCODING=1 PYTHONWARNINGS=error::EncodingWarning \
          python3 "$CHECK" --repo "$R" 2>&1); rc=$?
    if [ $rc -eq 0 ]; then
      ok "no read in the checker leaves its encoding to the locale (EncodingWarning as error)"
    elif grep -qF 'EncodingWarning' <<<"$out"; then
      bad "a read has no explicit encoding= (rc=$rc): $(printf '%s' "$out" | grep -F 'ci-wiring-check.py' | tail -1)"
    else
      bad "the EncodingWarning probe failed for an unrelated reason (rc=$rc), so it proves nothing"
      bad "  about encodings: $(printf '%s' "$out" | tail -1)"
    fi
  fi
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "ci-wiring golden test: all sections passed."
else
  echo "ci-wiring golden test: $fails section(s) FAILED."
fi
exit $((fails > 0))
