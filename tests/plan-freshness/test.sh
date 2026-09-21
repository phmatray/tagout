#!/usr/bin/env bash
# Golden test for skills/implement-issue/scripts/plan-freshness.sh and the SKILL.md prose that
# consumes it (#322).
#
# Why this exists. `implement-issue` Step 2 parses a plan that was written when the issue was
# FILED and executes it however long afterwards — #233 and #245 both trace to a `**Files:**` line
# naming a path that `main` no longer had. The failure shape is the one this repo keeps closing:
# nothing reports a problem. A subagent opens the file, finds it absent, improvises a nearby one,
# the task goes green, and Step 10 never says the plan was stale. `plan-freshness.sh` turns that
# silence into an exit code, and this suite drives both of its verdicts plus its refusal.
#
# The seam is the script's own CLI: argv in, stdout lines + exit code out, run against a scratch
# git repository built here (skills/_shared/test-seams.md — highest boundary a test can reach, and
# the one CI and Step 2 both actually depend on). Nothing is sourced; no internal is asserted on.
#
# Ported alongside the mechanisms in skills/implement-issue/references/spec-review.md from
# mattpocock/skills (MIT) — `engineering/code-review` and `in-progress/implement-spec`.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
kit_guard kit_guard_samples_unchanged

SCRIPT="$KIT_ROOT/skills/implement-issue/scripts/plan-freshness.sh"
SKILL="$(kit_skill_prose "$KIT_ROOT" implement-issue)"   # router + references/steps/*.md (#499)
MECHANICS="$KIT_ROOT/skills/implement-issue/references/github-mechanics.md"
SPEC_REVIEW="$KIT_ROOT/skills/implement-issue/references/spec-review.md"
WORK=$(kit_scratch)

FAILED=0
note_fail() { echo "FAIL: $1"; FAILED=1; }
note_ok()   { echo "ok   [$1]"; }

[ -x "$SCRIPT" ] || {
  echo "FAIL: $SCRIPT is missing or not executable — there is nothing to drive."
  echo "      Step 2 of implement-issue calls it by that path; a suite that skipped here would"
  echo "      report green about a script CI would fail on."
  exit 1; }

# ------------------------------------------------------------------ 1. the scratch repository
#
# A real repository, not a fixture directory: the script's whole job is `git cat-file -e <ref>:<p>`,
# so a stub of git would move the seam from "does this resolve against a ref" to "does this call
# the function I named git" — the mocking anti-pattern in _shared/test-seams.md.
REPO="$WORK/repo"
mkdir -p "$REPO/dir with space" "$REPO/.github/workflows"
git -C "$REPO" init -q
git -C "$REPO" config user.email "suite@example.invalid"
git -C "$REPO" config user.name "plan-freshness suite"
printf 'x\n' > "$REPO/a.sh"
printf 'y\n' > "$REPO/dir with space/b.sh"
# Dot-prefixed paths (#647): a Git Bash argv rewrite only ever touches an argument holding ':.', so
# these two exist at the base ref for the wrapper cases below to resolve.
printf 'ci\n' > "$REPO/.github/workflows/ci.yml"
printf 'root = true\n' > "$REPO/.editorconfig"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "init"

# `origin/main` without a remote: the script's default base is a ref name, and a remote-tracking
# ref is just a ref. This keeps the default path under test without a network or a second clone.
git -C "$REPO" update-ref refs/remotes/origin/main HEAD

# A second ref where a.sh does NOT exist, so `--base` is proved to be READ rather than accepted and
# ignored — a flag that is parsed and discarded passes every test that only ever spells the default.
git -C "$REPO" checkout -q -b without-a
git -C "$REPO" rm -q "a.sh"
git -C "$REPO" commit -qm "drop a.sh"
git -C "$REPO" checkout -q -

# ------------------------------------------------------------------------------- 2. the fixtures
cat > "$WORK/mixed.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: the mixed case

**Files:** modify `a.sh`, `gone.sh`; create `new.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.
PLAN

cat > "$WORK/all-present.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: everything still there

**Files:** modify `a.sh`; modify `dir with space/b.sh`.

- [ ] **Step 1:** do the thing.
PLAN

cat > "$WORK/no-tasks.md" <<'PLAN'
## Problem

There is no plan here at all — no `### Task` heading anywhere in the file.

**Files:** modify `a.sh`.
PLAN

# ------------------------------------------------------------------------------- 3. the verdicts
#
# run_case <label> <want-exit> <plan> [extra args…]
# stdout goes to a file; the assertions read that file. Nothing is piped through head/tail — the
# whole output is the evidence, and a truncated capture is how a wrong line goes unnoticed.
OUT="$WORK/out.txt"

BOUND=10
bounded_run() {   # bounded_run <plan> [extra args…] → $OUT, $GOT (143 = killed by the watchdog)
  local plan="$1" pid dog; shift
  GOT=0
  "$SCRIPT" -C "$REPO" "$@" "$plan" > "$OUT" 2>&1 &
  pid=$!
  ( sleep "$BOUND"; kill "$pid" 2>/dev/null ) > /dev/null 2>&1 &   # /dev/null: a leftover sleep never holds the suite's stdout open
  dog=$!
  wait "$pid" || GOT=$?
  kill "$dog" 2>/dev/null || true
  wait "$dog" 2>/dev/null || true
}

run_case() {
  local label="$1" want="$2" plan="$3"; shift 3
  bounded_run "$plan" "$@"
  if [ "$GOT" = 143 ]; then
    note_fail "$label — no exit within ${BOUND}s: plan-freshness.sh hung"
    return 0
  fi
  if [ "$GOT" != "$want" ]; then
    note_fail "$label — exit $GOT, wanted $want"
    sed 's/^/      /' "$OUT"
    return 0
  fi
  note_ok "$label"
}

run_terminates() {   # run_terminates <label> <plan> — passes on exit 0, 2 or 5
  local label="$1" plan="$2"
  bounded_run "$plan"
  case "$GOT" in
    0|2|5) note_ok "$label" ;;
    143)   note_fail "$label — no exit within ${BOUND}s: plan-freshness.sh hung" ;;
    *)     note_fail "$label — exit $GOT, not one of 0/2/5" ;;
  esac
}

want_line() {
  local label="$1" line="$2"
  if grep -Fxq "$line" "$OUT"; then
    note_ok "$label"
  else
    note_fail "$label — no line '$line' in the output:"
    sed 's/^/      /' "$OUT"
  fi
}

# The mirror of want_line: some fixtures are about a span producing NO line at all. Asserting only
# the lines that SHOULD appear cannot catch a span that is silently consumed as something else —
# which is exactly how #599 survived: every positive assertion still passed while the rename target
# was being eaten. `grep -Fxq` reads a FILE, so there is no pipeline for grep to close early.
want_no_line() {
  local label="$1" line="$2"
  if grep -Fxq "$line" "$OUT"; then
    note_fail "$label — the output names '$line', which it must not:"
    sed 's/^/      /' "$OUT"
  else
    note_ok "$label"
  fi
}

echo "== a plan with a stale modify path is exit 5, and says which path (#322) =="
run_case "C1 mixed plan exits 5             " 5 "$WORK/mixed.md"
want_line "C2 the present path is OK         " "OK modify a.sh (Task 1)"
want_line "C3 the absent path is MISSING     " "MISSING modify gone.sh (Task 1)"
want_line "C4 a create path is SKIPped       " "SKIP create new.sh (Task 1)"

echo "== a plan whose every path still exists is exit 0 =="
run_case "C5 all-present plan exits 0        " 0 "$WORK/all-present.md"
want_line "C6 a path with a space survives   " "OK modify dir with space/b.sh (Task 1)"

echo "== a file with no ### Task is a usage refusal (exit 2), not a silent pass =="
run_case "C7 task-less plan exits 2          " 2 "$WORK/no-tasks.md"

echo "== --base is READ, not merely accepted =="
run_case "C8 --base without-a finds a.sh gone" 5 "$WORK/all-present.md" --base without-a
want_line "C9 …and names it MISSING          " "MISSING modify a.sh (Task 1)"
run_case "C10 --base origin/main is the same as the default" 0 "$WORK/all-present.md" --base origin/main

echo "== a path an EARLIER task of the same plan creates is SKIP, not MISSING (#640) =="
cat > "$WORK/create-then-modify.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: create it

**Files:** create `new.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.

### Task 2: modify it

**Files:** modify `new.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.

### Task 3: a new test file

**Files:** test `other.sh` (new).

**Interfaces:** none.

- [ ] **Step 1:** do the thing.

### Task 4: modify the new test file

**Files:** modify `other.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.

### Task 5: rename a.sh

**Files:** rename `a.sh` → `moved.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.

### Task 6: modify the renamed file and the original

**Files:** modify `moved.sh`, `a.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.
PLAN
run_case "C102 create-then-modify plan exits 0 " 0 "$WORK/create-then-modify.md"
want_line "C103 the earlier create stays SKIP  " "SKIP create new.sh (Task 1)"
want_line "C104 a later modify of it is SKIP   " "SKIP modify new.sh (Task 2)"
want_line "C105 a later modify of a (new) is SKIP" "SKIP modify other.sh (Task 4)"
want_line "C106 a later modify of a rename target is SKIP" "SKIP modify moved.sh (Task 6)"
# a.sh is Task 5's rename SOURCE, not an unrelated path — it reads OK on its own terms (it
# genuinely resolves at the base ref, out of scope per #640's own Spec: a pre-existing path a plan
# renames/deletes away is not tracked, same as it was before this fix), not because of $CREATED.
want_line "C107 a's rename source, pre-existing at base, stays OK on its own terms" "OK modify a.sh (Task 6)"

echo "== …but a path only CREATED-known (never at base) is un-remembered once rename/delete CONSUMES it — referencing the old name after that is still MISSING, not silently SKIPped forever (found in review of #640) =="
cat > "$WORK/create-then-rename-then-stale.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: create it

**Files:** create `renamed-src.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.

### Task 2: rename it away

**Files:** rename `renamed-src.sh` → `renamed-dst.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.

### Task 3: a stale reference to the old name

**Files:** modify `renamed-src.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.
PLAN
run_case "C110 create-then-rename-then-stale-modify exits 5" 5 "$WORK/create-then-rename-then-stale.md"
want_line "C111 …the rename source is still SKIP first" "SKIP rename renamed-src.sh (Task 2)"
want_line "C112 …then the stale old-name reference is MISSING, not SKIP" \
  "MISSING modify renamed-src.sh (Task 3)"

cat > "$WORK/create-then-delete-then-stale.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: create it

**Files:** create `to-delete.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.

### Task 2: delete it

**Files:** delete `to-delete.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.

### Task 3: a stale reference to the deleted path

**Files:** modify `to-delete.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.
PLAN
run_case "C113 create-then-delete-then-stale-modify exits 5" 5 "$WORK/create-then-delete-then-stale.md"
want_line "C114 …the delete is still SKIP first" "SKIP delete to-delete.sh (Task 2)"
want_line "C115 …then the stale old-name reference is MISSING, not SKIP" \
  "MISSING modify to-delete.sh (Task 3)"

echo "== …and a path SKIPped from TWO different sites before being renamed away forgets BOTH records, not just one (found in review of #640) =="
cat > "$WORK/duplicate-then-rename-then-stale.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: create it

**Files:** create `dup.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.

### Task 2: its own new test, named again

**Files:** test `dup.sh` (new).

**Interfaces:** none.

- [ ] **Step 1:** do the thing.

### Task 3: rename it away

**Files:** rename `dup.sh` → `dup2.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.

### Task 4: a stale reference to the old name

**Files:** modify `dup.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.
PLAN
run_case "C116 duplicate-then-rename-then-stale-modify exits 5" 5 "$WORK/duplicate-then-rename-then-stale.md"
want_line "C117 …both earlier SKIPs of the duplicate fire" "SKIP create dup.sh (Task 1)"
want_line "C118 …the second SKIP fires too" "SKIP test dup.sh (Task 2)"
want_line "C119 …the rename source is still SKIP" "SKIP rename dup.sh (Task 3)"
want_line "C120 …and the stale reference is MISSING, not SKIP — neither duplicate survives" \
  "MISSING modify dup.sh (Task 4)"

cat > "$WORK/modify-then-create.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: modify before it exists

**Files:** modify `new.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.

### Task 2: create it

**Files:** create `new.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.
PLAN
run_case "C108 the reverse order (modify then create) exits 5" 5 "$WORK/modify-then-create.md"
want_line "C109 …and the early modify stays MISSING" "MISSING modify new.sh (Task 1)"

# --------------------------------------------------- 4. the prose that has to CALL the script
#
# A shipped script nothing invokes is the same absence-shaped failure ci-wiring-check.py exists for,
# one layer up: `plan-freshness.sh` can be green on every case above while SKILL.md Step 2 never
# mentions it, and a run would then execute a stale plan exactly as it did before #322. So the
# call site is pinned too — per STEP, not per file, because a grep over the whole SKILL.md passes
# on a mention parked in any other step.

section() {  # section <file> <start-heading> <end-heading> -> path to the extracted block
  # One file PER extraction. A single shared $WORK/section.txt made every $STEPn variable hold the
  # same path, so the five blocks were only ever correct because the calls and their assertions
  # happened to interleave in order — reorder one and it silently checks a different step's text.
  local file="$1" start="$2" end="$3" out
  out="$WORK/section-$(printf '%s' "$start" | tr -c 'A-Za-z0-9' '-').txt"
  awk -v s="$start" -v e="$end" '
    index($0, s) == 1 { inside = 1 }
    inside && index($0, e) == 1 && index($0, s) != 1 { exit }
    inside { print }
  ' "$file" > "$out"
  printf '%s' "$out"
}

want_in() {  # want_in <label> <file> <needle>
  local label="$1" file="$2" needle="$3"
  if [ -s "$file" ] && grep -Fq -- "$needle" "$file"; then
    note_ok "$label"
  else
    note_fail "$label — '$needle' is not in $(basename "$file")"
  fi
}

[ -r "$SKILL" ] || { echo "FAIL: $SKILL missing"; exit 1; }

echo "== a parenthetical aside is an ASIDE, not two paths (found in review of #322) =="
#
# `create-issue`'s own template writes `modify `Program.cs` (DI registration)`. Splitting on ", "
# before the aside came out turned ONE fresh path into two invented ones, both MISSING, exit 5 —
# and exit 5 is what routes Step 2 into re-anchoring, where an invented path anchors to nothing and
# becomes the "no usable plan" stop. A false stale costs the whole run, so it is pinned here.
cat > "$WORK/aside.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: asides

**Files:** modify `a.sh` (the entry point, and its guard); modify `dir with space/b.sh` (one line).
PLAN
run_case "C11 a comma inside () is not a split" 0 "$WORK/aside.md"
want_line "C12 …and the path survives whole  " "OK modify a.sh (Task 1)"

echo "== a wrapped **Files:** line is JOINED before parsing, not two failures (#419) =="
#
# `create-issue`'s own template writes `**Files:**` as flowing prose meant to be soft-wrapped, and
# issue #412's own plan did exactly that — a parenthetical aside spanning the wrap point. Before
# this fix the read loop only ever looked at ONE physical line: the first line's unclosed `(`
# corrupted the comma-split into bogus fragments and reported a false `MISSING`, and the second
# physical line — which starts with neither `### Task` nor `**Files:**` — matched no case at all and
# vanished from the output with NO verdict, neither OK nor MISSING. Both failures are pinned here:
# a fixture that mirrors #412's real shape (paren spanning the wrap, verb + path continuing after
# it) whose every named path genuinely exists, so a correct join reads exit 0 with both paths OK.
# (The second item's aside is deliberately NOT `(new)` — that marker is its own case, #433 below;
# mixing it in here would make this fixture assert two different things at once.)
cat > "$WORK/wrap-ok.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: wrap with only real paths

**Files:** modify `a.sh` (the entry point, and the
guard list); test `dir with space/b.sh` (already tracked).

- [ ] **Step 1:** do the thing.
PLAN
run_case "C30 a wrapped Files line exits 0    " 0 "$WORK/wrap-ok.md"
want_line "C31 …the first line's path is OK   " "OK modify a.sh (Task 1)"
want_line "C32 …the WRAPPED path is OK too    " "OK test dir with space/b.sh (Task 1)"

echo "== …and a genuinely stale path AFTER the wrap is still caught, not lost (#419) =="
#
# The mirror image of C30-C32: the same wrapped shape, but the path named on the continuation line
# does not exist. If the continuation were still silently dropped (rather than merely mis-split),
# this would read as a false-fresh exit 0 instead of the exit 5 a real stale path demands.
# (Same note as wrap-ok.md above: no `(new)` marker here, deliberately — that's #433's own fixture.)
cat > "$WORK/wrap-missing.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: wrap with a stale path after the wrap

**Files:** modify `a.sh` (the entry point, and the
guard list); test `gone.sh` (still absent).

- [ ] **Step 1:** do the thing.
PLAN
run_case "C33 a wrapped stale path exits 5    " 5 "$WORK/wrap-missing.md"
want_line "C34 …and the WRAPPED path is MISSING" "MISSING test gone.sh (Task 1)"

echo "== a '(new)' marker reads a create-shaped SKIP on ANY verb, not just create (#433) =="
#
# `create-issue`'s own template phrases a task's own new test file as `test \`path\` (new)`, not
# `create \`path\`` — the item is "the test for this task", not "a file this task modifies" — and
# before this fix the parenthetical-strip above threw `(new)` away as ordinary noise identically to
# `(DI registration)`, so the bare `test` verb then resolved the (deliberately absent) path and
# reported it MISSING — issue #414's own plan, reproduced here. `new-thing.sh` never exists in the
# fixture repo; a correct read is SKIP, never MISSING, and contributes nothing to the exit code.
cat > "$WORK/new-marker.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: a task with its own new test file

**Files:** test `tests/fixture/new-thing.sh` (new).

- [ ] **Step 1:** do the thing.
PLAN
run_case "C40 a '(new)' marker on 'test' exits 0" 0 "$WORK/new-marker.md"
want_line "C41 …and prints SKIP, not MISSING   " "SKIP test tests/fixture/new-thing.sh (Task 1)"

echo "== …the same path WITHOUT the marker still stales — the marker isn't a general escape (#433 AC2) =="
cat > "$WORK/no-marker.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: the same path, no marker

**Files:** test `tests/fixture/new-thing.sh`.
PLAN
run_case "C42 the same path with no marker: 5 " 5 "$WORK/no-marker.md"
want_line "C43 …and is named MISSING           " "MISSING test tests/fixture/new-thing.sh (Task 1)"

echo "== …a 'create' item is unaffected whether or not '(new)' is also present (#433 AC3) =="
cat > "$WORK/create-and-marker.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: a create item, redundantly marked

**Files:** create `brand-new.sh` (new).
PLAN
run_case "C44 'create … (new)' still exits 0   " 0 "$WORK/create-and-marker.md"
want_line "C45 …and prints SKIP create, as ever" "SKIP create brand-new.sh (Task 1)"

echo "== …two-word '(new file)' is the same marker, and it isn't a substring match (#433 Spec edge case) =="
#
# `(new)`/`(new file)` are the two closed spellings; `(new in v2)` must NOT match — it is a
# different, genuine parenthetical that happens to contain the word "new".
cat > "$WORK/new-file-marker.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: the two-word spelling, and a non-matching lookalike

**Files:** modify `another/new.sh` (new file); modify `dir with space/b.sh` (new in v2).
PLAN
run_case "C46 'new file' also SKIPs, exit 0    " 0 "$WORK/new-file-marker.md"
want_line "C47 …two-word marker prints SKIP    " "SKIP modify another/new.sh (Task 1)"
want_line "C48 …a lookalike aside is not eaten " "OK modify dir with space/b.sh (Task 1)"

echo "== …and a path that ALREADY EXISTS but is marked '(new)' anyway still SKIPs (#433 edge case) =="
#
# SKIP never checks existence — matching how `create` already behaves — so a stale or mistaken
# marker on an existing path is not adjudicated here, same as today's `create` verb.
cat > "$WORK/stale-marker.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: an existing path, marked new anyway

**Files:** modify `a.sh` (new).
PLAN
run_case "C49 a stale '(new)' marker exits 0   " 0 "$WORK/stale-marker.md"
want_line "C50 …and still prints SKIP          " "SKIP modify a.sh (Task 1)"

echo "== a ')' before a later '(' no longer hangs the aside strip (#519) =="
#
# The old first-'('-to-first-')' cut pairs the WRONG parens whenever a ')' precedes a later '(' —
# an empty-parens function call inside an aside, e.g. `f()`. Each pass then doubles part of the
# line instead of shrinking it, and the loop never terminates. These fixtures are all bounded by
# `bounded_run`'s watchdog above, so a regression FAILs instead of hanging this suite.
cat > "$WORK/hang-nested.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: a nested empty-parens call inside an aside

**Files:** modify `a.sh` (see `f()`), `dir with space/b.sh` (z).
PLAN
run_case "C51 a nested () aside terminates    " 0 "$WORK/hang-nested.md"
want_line "C52 …and the first path is OK       " "OK modify a.sh (Task 1)"
want_line "C53 …and the second path is OK      " "OK modify dir with space/b.sh (Task 1)"

cat > "$WORK/hang-new-nested.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: a nested () aside beside a '(new)' marker

**Files:** modify `a.sh` (new `f()`); test `brand-new.sh` (new).
PLAN
run_case "C54 …beside a '(new)' marker: 0      " 0 "$WORK/hang-new-nested.md"
want_line "C55 …the modify path is OK          " "OK modify a.sh (Task 1)"
want_line "C56 …the new-marked path is SKIPped " "SKIP test brand-new.sh (Task 1)"

# #512's own Task 1 **Files:** field, verbatim, with its two real paths swapped for this suite's
# fixture repo (`hooks/git-write-gate.sh` -> `a.sh`, `tests/git-gate/test.sh` -> `dir with space/b.sh`).
cat > "$WORK/hang-512-task1.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: guard_hint

**Files:** modify `a.sh` (new `guard_hint()` beside `deny()` at :182–191; the replacement sentences at :382, :403, :406, :410, :417); test `dir with space/b.sh` (extend `verdict()` at :65–100 with an optional 7th argument, the `CLAUDE_PLUGIN_ROOT` value, passed through `env`).
PLAN
run_case "C57 #512 Task 1's field terminates  " 0 "$WORK/hang-512-task1.md"
want_line "C58 …the modify path is OK          " "OK modify a.sh (Task 1)"
want_line "C59 …the test path is OK            " "OK test dir with space/b.sh (Task 1)"

# #512's own Task 2 field, same swap. Its prose and backticked shell code are #441's grammar to
# read correctly; this case pins only that the parser TERMINATES on it, not what it prints.
cat > "$WORK/hang-512-task2.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: the gate judges a raw gh pr merge

**Files:** modify `a.sh`: the cheap reject at :78 becomes `case "$cmd" in *git*|*gh*) ;; *) exit 0 ;; esac`. A `gh|*/gh` dispatch goes in `judge()` after the `cd` block and before `case "$1" in git|*/git)`. A new `judge_gh()` sits beside `judge()`. `deny()`'s escape sentence at :186 gains ``(or `GIT_GATE=off gh …`)``. The header at :7–12 names the `gh` arm and quotes #326's premise. Test `dir with space/b.sh`.
PLAN
run_terminates "C60 #512 Task 2's field terminates  " "$WORK/hang-512-task2.md"

cat > "$WORK/nested-aside.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: a '(new ...)' aside that is not the exact marker

**Files:** modify `a.sh` (new `guard_hint()` beside `deny()`).
PLAN
run_case "C61 a 'new ...' aside terminates     " 0 "$WORK/nested-aside.md"
want_line "C62 …and the path is OK, not MISSING" "OK modify a.sh (Task 1)"

cat > "$WORK/nested-plain.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: a genuinely nested aside

**Files:** modify `a.sh` (a (nested) aside), `dir with space/b.sh`.
PLAN
run_case "C63 a genuinely nested aside: 0      " 0 "$WORK/nested-plain.md"
want_line "C64 …the first path is OK           " "OK modify a.sh (Task 1)"
want_line "C65 …the second path is OK          " "OK modify dir with space/b.sh (Task 1)"

echo "== a path is a BACKTICK-QUOTED span; nothing else on the line is a path (decided at #441) =="

echo "== …a bulleted **Files:** field still resolves every backticked path (#441 shape 4) =="
#
# `create-issue` is no longer supposed to WRITE this shape (plan-shape.md now forbids it), but an
# already-filed plan can still carry one, and the parser must not turn its bullets into bogus
# MISSING items the way the pre-#441 comma-splitter did. Verbatim shape from the #441 discussion,
# with this suite's own fixture paths swapped in; also exercises `rename` + its arrow together.
cat > "$WORK/bulleted.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: a bulleted Files field

**Files:**
- Rename: `a.sh` → `renamed.sh`
- Modify: `dir with space/b.sh` (step name), `gone.sh` (the gate)
PLAN
run_case "C66 a bulleted Files field: exit 5   " 5 "$WORK/bulleted.md"
want_line "C67 …rename source is OK             " "OK rename a.sh (Task 1)"
want_line "C68 …rename target is SKIPped        " "SKIP rename renamed.sh (Task 1)"
want_line "C69 …a bulleted modify path is OK    " "OK modify dir with space/b.sh (Task 1)"
want_line "C70 …a bulleted stale path is MISSING" "MISSING modify gone.sh (Task 1)"

echo "== …and a stale rename SOURCE is still caught, not waved through (#441, #537 follow-up) =="
cat > "$WORK/rename-stale.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: renaming a path that is already gone

**Files:** rename `gone.sh` → `also-gone.sh`.
PLAN
run_case "C71 a stale rename: exit 5           " 5 "$WORK/rename-stale.md"
want_line "C72 …the missing source is MISSING   " "MISSING rename gone.sh (Task 1)"
want_line "C73 …the new target is still SKIPped " "SKIP rename also-gone.sh (Task 1)"

# The FIFTH false-STALE shape (#599), and a regression of the fix for the fourth: PR #594 added the
# `looks_like_path` filter to the rename SOURCE branch only, leaving the PENDING branch consuming
# whatever span arrived next as the target. A backticked aside between the two names was therefore
# eaten as the target, the real target fell through to the end-of-field flush, and a legitimately
# new file was reported MISSING. The shape is explicitly sanctioned by `skills/_shared/plan-shape.md`
# ("arrow or prose between them, either way"), so this was a legal plan being refused — and a false
# STALE is a stop, not a degraded answer: Step 2 reads it as "no usable plan" for the task.
echo "== …a backticked NON-PATH between a rename's two names is prose, not the target (#599) =="
cat > "$WORK/rename-aside.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: a rename with a backticked aside between its two names

**Files:** rename `a.sh` (see `guard_hint()` for context) → `NEWNAME-does-not-exist.sh`.
PLAN
run_case "C90 a rename with an aside: exit 0 " 0 "$WORK/rename-aside.md"
want_line "C91 …the source still resolves OK  " "OK rename a.sh (Task 1)"
want_no_line "C92 …the aside yields no item at all " "SKIP rename guard_hint() (Task 1)"
want_line "C93 …the REAL target is the target " "SKIP rename NEWNAME-does-not-exist.sh (Task 1)"

# The other half of the same branch, and the reason the end-of-field flush is left unconditional:
# a rename whose target never arrives must still resolve its source. #599's filter makes this path
# reachable in a NEW way — a source followed only by a non-path aside now falls through to the
# flush — so the flush's behaviour is pinned here rather than left to inspection.
echo "== …a rename whose target never arrives still resolves its source at end-of-field (#599) =="
cat > "$WORK/rename-no-target.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: a rename with no target at all

**Files:** rename `a.sh` (see `guard_hint()` for context).
PLAN
run_case "C94 a targetless rename: exit 0  " 0 "$WORK/rename-no-target.md"
want_line "C95 …the source still resolves OK  " "OK rename a.sh (Task 1)"
want_no_line "C96 …and no phantom target is named" "SKIP rename guard_hint() (Task 1)"

# #587's shape: a parenthetical aside that QUOTES a shell token containing a literal ")". The old
# aside-stripper paired every ")" against the nearest preceding "(" with no notion of a backtick
# span, so the cut landed INSIDE the quoted token, spliced the aside's text into the path, and a
# real file came back as `MISSING modify a.sh  arm`.
#
# #594's rewrite (paths are backtick-quoted spans, #441) removed that pairing loop wholesale and
# closed this incidentally — no case ever pinned the shape, which is how the same ~40-line function
# produced five false-STALE shapes in a row. These cases are that pin: numbered from C97 to stay
# clear of #599's C90-C96 in the sibling PR.
echo "== a backtick-quoted ')' inside an aside is not an aside delimiter (#587, closed by #594) =="
cat > "$WORK/paren-in-backticks.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: an aside quoting a shell token that contains a paren

**Files:** modify `a.sh` (the `timeout)` arm)
PLAN
run_case "C97 an aside quoting ')': exit 0  " 0 "$WORK/paren-in-backticks.md"
want_line "C98 …the real path resolves OK    " "OK modify a.sh (Task 1)"

echo "== …and the same with a call-shaped token, and two of them (#587) =="
cat > "$WORK/paren-in-backticks2.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: two quoted parens, and a second item after the aside

**Files:** modify `a.sh` (the `a)` and `b)` arms); modify `dir with space/b.sh` (see `judge()`)
PLAN
run_case "C99 two quoted parens: exit 0     " 0 "$WORK/paren-in-backticks2.md"
want_line "C100 …the first path is OK        " "OK modify a.sh (Task 1)"
want_line "C101 …the second path is OK too   " "OK modify dir with space/b.sh (Task 1)"

echo "== …two backticked paths joined by 'and' are two paths, not one glued string (#441, #514) =="
cat > "$WORK/and-joined.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: two paths joined by 'and'

**Files:** modify `a.sh` and `dir with space/b.sh` (wire the suite).
PLAN
run_case "C74 'and'-joined paths: exit 0        " 0 "$WORK/and-joined.md"
want_line "C75 …the first path is OK            " "OK modify a.sh (Task 1)"
want_line "C76 …the second path is OK           " "OK modify dir with space/b.sh (Task 1)"

echo "== …but a backticked COMMAND is prose, not a path (#654) =="
# #643's Task 3 ended its field with "…and their `plugins/tagout-migrate/` twins where
# `host-adapters.py build` writes them", and the field's last span was resolved as a path:
# `MISSING modify host-adapters.py build (Task 3)`, a false STALE on a fresh plan. A span carrying
# whitespace is a path only if its LAST word carries the same slash-or-dot evidence the predicate
# already asks of a span. `dir with space/b.sh` does; a command's trailing subcommand never does.
cat > "$WORK/command-span.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: a regenerate step naming the command that writes the copies

**Files:** modify `a.sh`, `dir with space/b.sh` and their twins where `host-adapters.py build`
writes them. Then run `python3 scripts/host-adapters.py build`.
PLAN
run_case "C127 a backticked command: exit 0     " 0 "$WORK/command-span.md"
want_line "C128 …the plain path is OK           " "OK modify a.sh (Task 1)"
want_line "C129 …the path with a space is OK    " "OK modify dir with space/b.sh (Task 1)"
want_no_line "C130 …the command is not a path     " "MISSING modify host-adapters.py build (Task 1)"
want_no_line "C131 …nor is the interpreted one    " "MISSING modify python3 scripts/host-adapters.py build (Task 1)"

echo "== …a trailing ':NN' or ':NN-MM'/':NN–MM' line anchor is stripped, not part of the path (#441, #512 shape 5) =="
#
# plan-shape.md's own task-block example writes `exact/path/to/existing.py:123-145` — the kit's own
# template produces this shape, so the reader has to accept it, not just the writer.
cat > "$WORK/anchored.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: anchored paths

**Files:** modify `a.sh:69`; test `dir with space/b.sh:65–100`.
PLAN
run_case "C77 anchored paths: exit 0            " 0 "$WORK/anchored.md"
want_line "C78 …a single ':NN' anchor is stripped" "OK modify a.sh (Task 1)"
want_line "C79 …an en-dash range anchor strips too" "OK test dir with space/b.sh (Task 1)"

cat > "$WORK/anchored-missing.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: an anchored path that does not exist

**Files:** modify `gone.sh:12-20`.
PLAN
run_case "C80 a stale anchored path: exit 5     " 5 "$WORK/anchored-missing.md"
want_line "C81 …named MISSING without the anchor " "MISSING modify gone.sh (Task 1)"

echo "== …an em-dash tail describing REGIONS of the one named path is prose, not more paths (#441, #552) =="
cat > "$WORK/em-dash-regions.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: one file, several backticked region names

**Files:** modify `dir with space/b.sh` — the fixture-writer helpers (~line 27-42), the `t7` block
(88-99), and the two stale comments (102-103, 191). No other file changes.
PLAN
run_case "C82 one path + region names: exit 0   " 0 "$WORK/em-dash-regions.md"
want_line "C83 …the one real path is OK          " "OK modify dir with space/b.sh (Task 1)"
if [ "$(wc -l < "$OUT" | tr -d ' ')" = 1 ]; then
  note_ok "C84 …and nothing else is printed      "
else
  note_fail "C84 …and nothing else is printed      — got:"
  sed 's/^/      /' "$OUT"
fi

echo "== …a prose sentence between paths, with capitalised verbs, is not split into fake items (#441, shape 6) =="
cat > "$WORK/prose-sentence.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: prose carrying capitalised verbs mid-field

**Files:** modify `a.sh:678`. Under the block, add one sentence: `<kit>` is the kit root, printed at
session start. Modify `dir with space/b.sh:44` with the same sentence. Test `dir with space/b.sh`
for the printed value.
PLAN
run_case "C85 a prose sentence mid-field: exit 0" 0 "$WORK/prose-sentence.md"
want_line "C86 …the first anchored path is OK    " "OK modify a.sh (Task 1)"
want_line "C87 …a capitalised 'Modify' is read    " "OK modify dir with space/b.sh (Task 1)"
want_line "C88 …a capitalised 'Test' is read      " "OK test dir with space/b.sh (Task 1)"
if grep -q 'MISSING' "$OUT"; then
  note_fail "C89 …and the prose itself is never MISSING — got:"
  sed 's/^/      /' "$OUT"
else
  note_ok "C89 …and the prose itself is never MISSING"
fi

echo "== …and a field with NO blank line before **Interfaces:** is not swallowed (#419 review) =="
#
# plan-shape.md's own template always puts a blank line between `**Files:**` and `**Interfaces:**`
# (as does every real plan this suite fixtures against), but nothing upstream enforces that blank
# line. Before this guard, a missing one let the Interfaces text get appended to the Files payload
# as a bogus continuation — turning a perfectly fresh plan into a false MISSING/exit 5.
cat > "$WORK/no-blank-before-interfaces.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: no blank line
**Files:** modify `a.sh`.
**Interfaces:** consumes `Foo.Bar`; produces `Baz.Qux`.

- [ ] **Step 1:** do the thing.
PLAN
run_case "C35 no blank before Interfaces: 0  " 0 "$WORK/no-blank-before-interfaces.md"
want_line "C36 …the real path is OK, not eaten" "OK modify a.sh (Task 1)"

echo "== …and two **Files:** lines under one task start two fields, not a merge (#419 Spec edge case) =="
cat > "$WORK/two-files-lines.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: two Files lines

**Files:** modify `a.sh`.
**Files:** modify `dir with space/b.sh`.

- [ ] **Step 1:** do the thing.
PLAN
run_case "C37 two Files: lines both parse    " 0 "$WORK/two-files-lines.md"
want_line "C38 …the first line's path is OK  " "OK modify a.sh (Task 1)"
want_line "C39 …the second line's path is OK " "OK modify dir with space/b.sh (Task 1)"

echo "== a CRLF plan body is read, not reported stale (found in review of #322) =="
#
# The plan arrives via `gh api … --jq .body`, and a body authored in GitHub's web editor is CRLF.
# The stray \r rode the last item of every **Files:** line and made it MISSING — with a diagnostic
# that printed identically to the path it was complaining about.
printf '## \xf0\x9f\x9b\xa0\xef\xb8\x8f Implementation plan\r\n\r\n### Task 1: crlf\r\n\r\n**Files:** modify `a.sh`; modify `dir with space/b.sh`.\r\n' > "$WORK/crlf.md"
run_case "C13 a CRLF plan is exit 0         " 0 "$WORK/crlf.md"
want_line "C14 …with the CR off the path    " "OK modify dir with space/b.sh (Task 1)"

echo "== a path is passed LITERALLY — brackets included =="
mkdir -p "$REPO/odd"
printf 'z\n' > "$REPO/odd/[bracketed].sh"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "a bracketed path"
git -C "$REPO" update-ref refs/remotes/origin/main HEAD
cat > "$WORK/bracket.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: brackets

**Files:** modify `odd/[bracketed].sh`.
PLAN
run_case "C15 a [bracketed] path resolves   " 0 "$WORK/bracket.md"
want_line "C16 …and is reported verbatim    " "OK modify odd/[bracketed].sh (Task 1)"

echo "== the other bold spelling is READ, not silently skipped =="
cat > "$WORK/altbold.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: the other spelling

**Files**: modify `gone.sh`.
PLAN
run_case "C17 **Files**: is parsed too      " 5 "$WORK/altbold.md"
want_line "C18 …and its stale path is named " "MISSING modify gone.sh (Task 1)"

echo "== a task's own \"no file\" idiom is not a path (#403) =="
#
# `create-issue`'s own doctrine (skills/_shared/plan-shape.md) writes `**Files:** none expected.`
# on a verification-only task — every issue filed under it does, #396's Task 4 and #372's Task 4
# among them. Treating that phrase as a path name reports a fresh plan STALE on every such task.
cat > "$WORK/no-file.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: verify the fix

**Files:** none expected.

- [ ] **Step 1:** run the suite and confirm it is green.
PLAN
run_case "C24 a 'none expected' task exits 0 " 0 "$WORK/no-file.md"
if grep -Eq 'MISSING|^OK |^SKIP' "$OUT"; then
  note_fail "C25 …and prints no verdict line   — got:"
  sed 's/^/      /' "$OUT"
else
  note_ok "C25 …and prints no verdict line   "
fi

echo "== …but a real-looking path is still checked, not waved through (#403) =="
#
# The negative: one word changed (`none expected` -> `none-such.md`) must flip exit 0 back to 5 —
# proving "none" did not become a magic word that hides a typo.
cat > "$WORK/no-file-typo.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: verify the fix

**Files:** modify none-such.md

- [ ] **Step 1:** run the suite and confirm it is green.
PLAN
run_case "C26 a real-looking path still stales" 5 "$WORK/no-file-typo.md"
want_line "C27 …and is named MISSING          " "MISSING modify none-such.md (Task 1)"

echo "== a parenthetical after the no-file phrase is still no-file (#403 Spec edge case) =="
#
# create-issue's own template pattern for asides (proven above at C11/C12) composes with this
# idiom too: `none expected (the PR description records the check).` The payload-level
# parenthetical strip (the C11/C12 machinery) removes the aside before the no-file list is ever
# consulted, so the leading `none expected` is what the list actually sees.
cat > "$WORK/no-file-aside.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: verify the fix

**Files:** none expected (the PR description records the check).

- [ ] **Step 1:** run the suite and confirm it is green.
PLAN
run_case "C28 'none expected (aside)' exits 0 " 0 "$WORK/no-file-aside.md"
if grep -Eq 'MISSING|^OK |^SKIP' "$OUT"; then
  note_fail "C29 …and prints no verdict line   — got:"
  sed 's/^/      /' "$OUT"
else
  note_ok "C29 …and prints no verdict line   "
fi

echo "== every no-verdict condition is exit 2 — none of them may read as 'fresh' =="
#
# Exit 2 is the code that says the question was never answered. Only the task-less case was driven
# before; the empty-plan guard the script's own header calls load-bearing had no test at all, which
# is the shape of hole this repo keeps closing.
: > "$WORK/empty.md"
run_case "C19 an EMPTY plan refuses         " 2 "$WORK/empty.md"
run_case "C20 an unresolvable --base refuses" 2 "$WORK/all-present.md" --base no/such/ref
if "$SCRIPT" -C "$REPO" > "$OUT" 2>&1; then
  note_fail "C21 no plan file refuses          — exited 0 with no plan argument"
else
  [ "$?" = 2 ] && note_ok "C21 no plan file refuses          " \
    || note_fail "C21 no plan file refuses          — wrong exit code"
fi
NOTREPO=$(kit_scratch)
if "$SCRIPT" -C "$NOTREPO" "$WORK/all-present.md" > "$OUT" 2>&1; then
  note_fail "C22 a non-repository refuses      — exited 0 outside a git repo"
else
  [ "$?" = 2 ] && note_ok "C22 a non-repository refuses      " \
    || note_fail "C22 a non-repository refuses      — wrong exit code"
fi

echo "== the shipped script parses under the #131 rules, like every suite does =="
#
# `parse-sweep.sh` with no arguments sweeps tests/*/test.sh only, so the SCRIPT this suite exists
# for is not covered by the CI step that runs it bare. Reuse the shipped tool rather than a second
# `bash -n`: it also carries the static scan for the bash 3.2 heredoc-in-$( … ) construct, which a
# modern bash's parser cannot see.
if "$KIT_ROOT/scripts/parse-sweep.sh" "skills/implement-issue/scripts/plan-freshness.sh" \
     > "$WORK/sweep.log" 2>&1; then
  note_ok "C23 plan-freshness.sh parse-sweeps"
else
  note_fail "C23 plan-freshness.sh parse-sweeps — parse-sweep refused:"
  sed 's/^/      /' "$WORK/sweep.log"
fi

echo "== a dot-prefixed <base>:<path> resolves on stdin, immune to a Git Bash argv rewrite (#647) =="
#
# check_span used to put "<base>:<path>" in argv (`git cat-file -e "$BASE:$path"`), and Git Bash's
# MSYS layer rewrites an argv entry holding ':.' before git.exe ever sees it — turning a present
# dot-prefixed path into a false MISSING. This wrapper reproduces the MEASURED rewrite shape
# (`/`→`\`, `:`→`;` on an argument matching `*:.*`) and forwards everything else untouched, so the
# fix is proven against the actual defect rather than against a description of it.
REAL_GIT=$(command -v git)
mkdir -p "$WORK/msys-bin"
cat > "$WORK/msys-bin/git" <<GITWRAP
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  case "\$a" in
    *:.*) a=\${a//\\//\\\\}; a=\${a//:/;} ;;
  esac
  args+=("\$a")
done
exec "$REAL_GIT" "\${args[@]}"
GITWRAP
chmod +x "$WORK/msys-bin/git"

if PATH="$WORK/msys-bin:$PATH" git -C "$REPO" cat-file -e origin/main:.editorconfig > "$OUT" 2>&1; then
  note_fail "C121 the wrapper really reproduces the defect — cat-file -e exited 0 under it"
else
  note_ok "C121 the wrapper really reproduces the defect — a raw cat-file -e fails under it"
fi

cat > "$WORK/dotfiles.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: touch CI and a root dotfile

**Files:** modify `.github/workflows/ci.yml`; modify `.editorconfig`; modify `a.sh`.
PLAN
OLDPATH="$PATH"
PATH="$WORK/msys-bin:$PATH"
run_case "C122 dot-prefixed paths under the wrapper: exit 0" 0 "$WORK/dotfiles.md"
want_line "C123 ….github/workflows/ci.yml reads OK" "OK modify .github/workflows/ci.yml (Task 1)"
want_line "C124 ….editorconfig reads OK           " "OK modify .editorconfig (Task 1)"

cat > "$WORK/dotfile-missing.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: a dot-prefixed path that is not there

**Files:** modify `.gone.yml`.
PLAN
run_case "C125 a stale dot-prefixed path: exit 5   " 5 "$WORK/dotfile-missing.md"
want_line "C126 …still named MISSING, not swallowed" "MISSING modify .gone.yml (Task 1)"
PATH="$OLDPATH"

echo "== SKILL.md Step 2 must RUN the freshness pass and carry a STALE list (#322) =="
STEP2=$(section "$SKILL" "## Step 2 — " "## Step 3 — ")
want_in "P1 Step 2 calls plan-freshness.sh " "$STEP2" "plan-freshness.sh"
want_in "P2 Step 2 names the STALE list    " "$STEP2" "STALE:"
want_in "P3 Step 2 re-anchors via Interfaces" "$STEP2" "**Interfaces:**"

echo "== github-mechanics §2b must carry the call and the re-anchor recipe =="
[ -r "$MECHANICS" ] || { echo "FAIL: $MECHANICS missing"; exit 1; }
# Scoped to §2b for the same reason the SKILL.md assertions are scoped per step: a mention parked
# in §5 would satisfy a whole-file grep while §2b said nothing at all.
SEC2B=$(section "$MECHANICS" "### 2b. " "## 3. ")
want_in "P4 §2b spells the freshness call  " "$SEC2B" "plan-freshness.sh"
want_in "P5 §2b spells the re-anchor search" "$SEC2B" "grep -l -F --"
want_in "P6 §2b names the STALE record     " "$SEC2B" "STALE:"

echo "== Step 3 must explore ONCE and hand later sub-agents a pointer (#322) =="
STEP3=$(section "$SKILL" "## Step 3 — " "## Step 4 — ")
want_in "P7 Step 3 names the notes file    " "$STEP3" 'issue-$ISSUE-notes.md'
want_in "P8 Step 3 says pointer, not copy  " "$STEP3" "pointer"

echo "== Step 6's failing test must cross the seam the plan named (#310, #322) =="
STEP6=$(section "$SKILL" "## Step 6 — " "## Step 7 — ")
want_in "P9 Step 6 names the seam preamble " "$STEP6" "Seams under test"
want_in "P10 Step 6 links the seam doctrine" "$STEP6" "_shared/test-seams.md"

echo "== Step 7 must review on a SECOND axis, against the Spec (#322) =="
if [ -r "$SPEC_REVIEW" ]; then
  note_ok "P11 references/spec-review.md exists"
else
  note_fail "P11 references/spec-review.md exists — $SPEC_REVIEW is missing"
fi
STEP7=$(section "$SKILL" "## Step 7 — " "## Step 8 — ")
want_in "P12 Step 7 links the Spec brief   " "$STEP7" "spec-review.md)"
want_in "P13 Step 7 routes creep to the PR " "$STEP7" "### Follow-ups"
want_in "P14 Step 7 refuses to rerank      " "$STEP7" "rerank"

# The credit is a licence obligation, not decoration: the brief, the a/b/c categories, the smell
# baseline and the two-heading aggregation are Matt Pocock's, taken under MIT.
want_in "P15 the brief credits its source  " "$SPEC_REVIEW" "mattpocock/skills"
want_in "P16 the brief carries the a/b/c   " "$SPEC_REVIEW" "scope creep"
want_in "P17 the brief bounds its length   " "$SPEC_REVIEW" "400 words"
# The Spec is fetched from an issue body — foreign text. A reference that ingests it and does not
# carry the boundary is the #266 failure one file over.
want_in "P18 the brief reads it as data    " "$SPEC_REVIEW" "untrusted-input-boundary.md"

echo "== Step 10 must REPORT both new verdicts — an unreported check is no check (#322) =="
STEP10=$(section "$SKILL" "## Step 10 — " "## Notes on quality")
want_in "P19 Step 10 reports freshness    " "$STEP10" "Plan freshness"
want_in "P20 Step 10 reports the Spec axis" "$STEP10" "Spec axis"

[ "$FAILED" -eq 0 ] || exit 1
echo "plan-freshness golden test: all cases behaved as specified"
