#!/usr/bin/env bash
# Golden test for the decision engine — scripts/decide.sh and scripts/decision-check.py (#208).
#
# What this suite guards, and why it is mostly refusals:
#
#   A. the dispatcher answers                     — every merge.step4 fixture, verdict by verdict,
#      which is what pins the precedence rule itself. Before this suite, five fixtures pinned
#      three of its eight rules: no fixture set isDraft, none carried a non-empty `pending`, none
#      was BLOCKED, none exercised the catch-all. The default could be flipped from `wait` to
#      `merge` with CI green.
#   B. the guard refuses                          — R1 … R9, each driven to RED over a scratch kit.
#
# B is the point. This guard exists because a decision had two homes and the copy nobody ran went
# wrong in silence; a guard whose own refusal path is untested is that same defect one level up. So
# every rule below is asserted by BREAKING a working kit in exactly one way and requiring the
# named rule to fire — never by reading the guard and believing it.
#
# The scratch kit is a real, minimal repository rather than a mock: decision-check.py obtains every
# program by RUNNING `scripts/decide.sh --program <id>` (one home for extraction), and reads program
# modes out of the git INDEX, so a fixture that is not a git repo with a real dispatcher in it would
# exercise neither path. `--repo` is what makes that affordable.
#
# Section lines carry a label, never a fraction: a denominator goes stale the moment a section is
# added, and a stale one reads as a run that stopped early.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO/scripts/decision-check.py"
DECIDE="$REPO/scripts/decide.sh"
FIXTURES="$REPO/tests/decisions/fixtures"

# Sourced via $REPO, never $PWD: this suite does not cd, and is written to run from anywhere.
. "$REPO/tests/_lib.sh" || {
  echo "FAIL: cannot source $REPO/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$REPO"
kit_guard kit_guard_samples_unchanged

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# ------------------------------------------------------------------------------------ the kit
#
# A working, minimal kit that decision-check.py accepts. Each refusal case copies it and breaks
# exactly one thing, so the rule that fires is attributable to that one change and nothing else.
#
# The program is chosen to exercise the derivations rather than to be realistic: TOKEN_RE reads
# {CLEAN, DIRTY} out of its `== "…"` comparisons (that is R8's whole token set, derived from the
# program and never listed in the registry), and VERDICT_LIT_RE reads {go, stop} out of its
# `verdict:"…"` constructions (that is what R4 holds the declared vocabulary to).
make_kit() {
  local k="$1"
  mkdir -p "$k/scripts" "$k/decisions" "$k/skills/demo/scripts" "$k/tests/demo"

  cp "$DECIDE" "$k/scripts/decide.sh"
  chmod +x "$k/scripts/decide.sh"

  cat > "$k/skills/demo/scripts/prog.sh" <<'PROG'
#!/usr/bin/env bash
set -euo pipefail
jq -c 'if .state == "CLEAN" then {verdict:"go", rule:"clean"}
       elif .state == "DIRTY" then {verdict:"stop", rule:"dirty"}
       else {verdict:"stop", rule:"other"} end'
PROG
  chmod +x "$k/skills/demo/scripts/prog.sh"

  # The owner INVOKES its decision inside a fenced block — that is R7's whole requirement, and the
  # fence matters: prose naming a script is not calling it.
  cat > "$k/skills/demo/SKILL.md" <<'OWNER'
# Demo skill

Step 4 — decide whether to go.

```bash
scripts/decide.sh demo.rule < state.json
```

Apply the verdict:

| Verdict | Do |
|---|---|
| `go` | proceed |
| `stop` | do not |
OWNER

  printf '#!/usr/bin/env bash\nexit 0\n' > "$k/tests/demo/test.sh"
  chmod +x "$k/tests/demo/test.sh"

  cat > "$k/decisions/registry.json" <<'REG'
{
  "description": "scratch kit",
  "decisions": [
    {
      "id": "demo.rule",
      "issue": 0,
      "program": { "kind": "exec", "path": "skills/demo/scripts/prog.sh" },
      "shape": null,
      "owner": "skills/demo/SKILL.md",
      "suites": ["tests/demo/test.sh"],
      "stdin": true,
      "verdict": { "source": "stdout-json", "vocabulary": ["go", "stop"] }
    }
  ],
  "not_decisions": {
    "scripts/decide.sh": "the dispatcher itself — it runs decisions, it is not one"
  }
}
REG

  git -C "$k" init -q
  git -C "$k" add -A
}

# Run the guard over a kit; print nothing, record status and output for the assertions.
run_check() {
  CHECK_OUT=$(python3 "$CHECK" --repo "$1" 2>&1)
  CHECK_RC=$?
}

# Assert the kit is refused as UNANSWERABLE (exit 2) rather than by a numbered rule, naming the
# cause. Two registry defects land here rather than on R9: an unknown `program.kind` and a
# `verdict.source` no dispatcher implements are both refused by `decide.sh --program` itself, which
# decision-check.py runs to obtain every program — so the extraction fails before any rule can be
# evaluated about that row.
#
# That is the right layer (the dispatcher is the one home for extraction, and it names the exact
# cause), but it costs something the guard's own report promises: "All of them, not the first". An
# Unanswerable aborts the whole check, so a registry carrying an unknown kind AND an unrelated R8
# restatement reports only the first. The build goes red either way and the cause is named, so this
# is a recorded limit rather than a defect — written down here so the next reader does not have to
# rediscover which layer refuses what.
unanswerable() {
  local k="$1" needle="$2" label="$3"
  run_check "$k"
  if [ "$CHECK_RC" -ne 2 ]; then
    bad "$label — expected exit 2 (unanswerable), got $CHECK_RC"
    return
  fi
  case "$CHECK_OUT" in
    *"$needle"*) ok "$label" ;;
    *) bad "$label — exited 2, but never named '$needle':"
       printf '%s\n' "$CHECK_OUT" | sed 's/^/          /' ;;
  esac
}

# Assert the guard REFUSES a broken kit, naming the expected rule. A fixture that fails for the
# wrong reason is the failure mode this wrapper exists to stop: it would read as a pass.
refuses() {
  local k="$1" rule="$2" label="$3"
  run_check "$k"
  if [ "$CHECK_RC" -eq 0 ]; then
    bad "$label — the guard PASSED a kit it must refuse"
    return
  fi
  case "$CHECK_OUT" in
    *"$rule"*) ok "$label" ;;
    *) bad "$label — refused, but not by $rule:"
       printf '%s\n' "$CHECK_OUT" | sed 's/^/          /' ;;
  esac
}

echo "== A. the dispatcher answers — every fixture, verdict by verdict"

# The recorded verdicts. Each line is <fixture> <expected-verdict-or-RC2>, and together they pin
# all fifteen precedence rules plus the two refusal paths. Kept as a here-doc rather than an
# associative array: this must parse under macOS bash 3.2, which has none (scripts/parse-sweep.sh).
while read -r fixture expected; do
  [ -n "$fixture" ] || continue
  out=$("$DECIDE" merge.step4 "$FIXTURES/merge.step4/$fixture" 2>/dev/null)
  rc=$?
  if [ "$expected" = "RC2" ]; then
    if [ "$rc" -eq 2 ]; then ok "$fixture — refused with exit 2, no verdict is not a pass"
    else bad "$fixture — expected exit 2, got $rc ('$out')"; fi
  elif [ "$rc" -ne 0 ]; then
    bad "$fixture — expected verdict '$expected', but decide.sh exited $rc"
  elif [ "$out" = "$expected" ]; then
    ok "$fixture — $expected"
  else
    bad "$fixture — expected '$expected', got '$out'"
  fi
done <<'FIXTURES_EOF'
clean.json merge
behind.json sync
behind-state.json sync
dirty-fresh.json sync
failed.json fix-check
pending.json wait
unstable-quiet.json wait
unknown.json wait
unrecognised.json wait
draft-flag.json ready
draft-state.json ready
blocked-approval.json review
blocked-changes-requested.json review
changes-requested.json review
unresolved-threads.json review
empty RC2
not-an-object.json RC2
FIXTURES_EOF

echo "== B. the guard refuses"

# --- the happy path first, so every refusal below is attributable to its one mutation ----------
BASE=$(kit_scratch)/kit
mkdir -p "$BASE"
make_kit "$BASE"
run_check "$BASE"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "a coherent kit passes (so the refusals below are caused by their mutation, not by the kit)"
else
  bad "the scratch kit does not pass clean — every case below is meaningless until it does:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

# --- R9 registry integrity ---------------------------------------------------------------------
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
sed -i.bak 's/"id": "demo.rule"/"id": "Demo.Rule"/' "$k/decisions/registry.json"
refuses "$k" R9 "R9 — a malformed decision id is refused"

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
sed -i.bak 's/"stdout-json"/"exit-map"/' "$k/decisions/registry.json"
unanswerable "$k" "exit-map" \
  "a verdict.source no dispatcher implements is refused by the dispatcher, exit 2"

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
rm -f "$k/tests/demo/test.sh"
refuses "$k" R9 "R9 — a suite listed in the registry but absent is refused"

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
rm -f "$k/skills/demo/SKILL.md"
refuses "$k" R9 "R9 — an owner that cannot be read is refused"

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
sed -i.bak 's/"kind": "exec"/"kind": "inline"/' "$k/decisions/registry.json"
unanswerable "$k" "inline" \
  "an unknown program.kind is refused by the dispatcher, exit 2"

# --- R1 one home, and a program CI can actually execute ----------------------------------------
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
git -C "$k" update-index --chmod=-x skills/demo/scripts/prog.sh 2>/dev/null
refuses "$k" R1 "R1 — a program committed 100644 is refused (CI would die with Permission denied)"

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
git -C "$k" rm --cached -q skills/demo/scripts/prog.sh
refuses "$k" R1 "R1 — a program that is not in the git index is refused"

# --- R4 the declared vocabulary is exact -------------------------------------------------------
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
sed -i.bak 's/{verdict:"stop", rule:"other"}/{verdict:"maybe", rule:"other"}/' \
  "$k/skills/demo/scripts/prog.sh"
git -C "$k" add -A
refuses "$k" R4 "R4 — a verdict the program emits but the registry never declared is refused"

# --- R5 causes are distinct, and a comment quoting the form it documents is not a branch --------
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
python3 - "$k/skills/demo/scripts/prog.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
    "set -euo pipefail\n",
    'set -euo pipefail\n# always emits verdict:"stop" when state is not CLEAN\n',
)
open(p, "w").write(t)
PY
git -C "$k" add -A
run_check "$k"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "R5 — a comment quoting the verdict form it documents is not counted as an extra branch"
else
  bad "R5 — a documentary comment made the guard refuse a kit that R5 must accept:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

# --- the strip's own limit: a `#` legitimately inside a verdict value must survive intact --------
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
python3 - "$k/skills/demo/scripts/prog.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
    'else {verdict:"stop", rule:"other"} end',
    'elif .state == "HASH" then {verdict:"needs-#1", rule:"hash"}\n'
    '       else {verdict:"stop", rule:"other"} end',
)
open(p, "w").write(t)
PY
python3 - "$k/decisions/registry.json" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace('"vocabulary": ["go", "stop"]', '"vocabulary": ["go", "stop", "needs-#1"]')
open(p, "w").write(t)
PY
git -C "$k" add -A
run_check "$k"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "a '#' legitimately inside a verdict value (needs-#1) is still counted and R4/R5 both pass"
else
  bad "a '#' inside a quoted verdict value was truncated, breaking R4/R5 on an otherwise-coherent kit:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

# --- R6 reads subset emits, and a comment naming an unbuilt field is not a real read (#261) ------
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
# Give demo.rule a shape: the marked block is where R6 reads what the input state actually
# contains, matched against what READ_RE finds the program reading (`.state`).
cat >> "$k/skills/demo/SKILL.md" <<'SHAPE'

```bash
# >>> decision demo.rule shape >>>
state=$(printf '%s' '"CLEAN"' | jq '{state: .}')
# <<< decision demo.rule shape <<<
```
SHAPE
python3 - "$k/decisions/registry.json" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace('"shape": null',
              '"shape": {"home": "skills/demo/SKILL.md", "marker": "demo.rule shape"}')
open(p, "w").write(t)
PY
git -C "$k" add -A
run_check "$k"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "R6 — a shape whose emitted keys cover the program's reads passes (baseline for the case below)"
else
  bad "R6 — the shape baseline itself does not pass, so the comment case below is meaningless:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

# A comment naming a field the shape does NOT build must not be counted as a real read.
python3 - "$k/skills/demo/scripts/prog.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
    "set -euo pipefail\n",
    "set -euo pipefail\n# also reads .legacy_field for back-compat\n",
)
open(p, "w").write(t)
PY
git -C "$k" add -A
run_check "$k"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "R6 — a comment mentioning a field the shape does not build is not counted as a real read"
else
  bad "R6 — a documentary comment made the guard refuse a shape-covered kit it must accept:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

# A genuine (non-comment) read of a field the shape does not build must be refused — the positive
# case the two above only set up for.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
cat >> "$k/skills/demo/SKILL.md" <<'SHAPE'

```bash
# >>> decision demo.rule shape >>>
state=$(printf '%s' '"CLEAN"' | jq '{state: .}')
# <<< decision demo.rule shape <<<
```
SHAPE
python3 - "$k/decisions/registry.json" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace('"shape": null',
              '"shape": {"home": "skills/demo/SKILL.md", "marker": "demo.rule shape"}')
open(p, "w").write(t)
PY
python3 - "$k/skills/demo/scripts/prog.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
    'if .state == "CLEAN" then {verdict:"go", rule:"clean"}',
    'if .state == "CLEAN" then {verdict:"go", rule:"clean"}\n'
    '       elif .legacy_field == "x" then {verdict:"stop", rule:"legacy"}',
)
open(p, "w").write(t)
PY
git -C "$k" add -A
refuses "$k" R6 "R6 — a genuine read of a field the shape does not build is refused"

# A comment INSIDE the marked shape block naming a `{...}` construction for a field the live shape
# does not build must not be counted as a real emit — the mirror image of the two read-side cases
# above, on emitted_keys() instead of READ_RE (#274). Left unfixed, the comment's phantom
# `legacy_field` key covers a genuine missing read and R6 wrongly passes.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
cat >> "$k/skills/demo/SKILL.md" <<'SHAPE'

```bash
# >>> decision demo.rule shape >>>
# earlier revision built: { legacy_field: .foo, state: .bar }
state=$(printf '%s' '"CLEAN"' | jq '{state: .}')
# <<< decision demo.rule shape <<<
```
SHAPE
python3 - "$k/decisions/registry.json" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace('"shape": null',
              '"shape": {"home": "skills/demo/SKILL.md", "marker": "demo.rule shape"}')
open(p, "w").write(t)
PY
python3 - "$k/skills/demo/scripts/prog.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
    'if .state == "CLEAN" then {verdict:"go", rule:"clean"}',
    'if .state == "CLEAN" then {verdict:"go", rule:"clean"}\n'
    '       elif .legacy_field == "x" then {verdict:"stop", rule:"legacy"}',
)
open(p, "w").write(t)
PY
git -C "$k" add -A
refuses "$k" R6 \
  "R6 — a comment inside the shape block naming an unbuilt field is not counted as a real emit"

# A `#` embedded inside a SINGLE-quoted string on the same shape line as a real `{...}` construction
# must not truncate that construction and hide a real emit (code-review finding on #274): a shape
# block is ordinary bash/jq, never protected by R3's "no single quote" refusal the way a
# `kind=="block"` program is, so this is reachable in real shape text — the actual registered
# `merge.step4` shape embeds `gh api graphql -f query='…'`.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
cat >> "$k/skills/demo/SKILL.md" <<'SHAPE'

```bash
# >>> decision demo.rule shape >>>
state=$(echo 'see issue #99 for context' > /dev/null; printf '%s' '"CLEAN"' | jq '{state: .}')
# <<< decision demo.rule shape <<<
```
SHAPE
python3 - "$k/decisions/registry.json" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace('"shape": null',
              '"shape": {"home": "skills/demo/SKILL.md", "marker": "demo.rule shape"}')
open(p, "w").write(t)
PY
git -C "$k" add -A
run_check "$k"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "R6 — a '#' inside a single-quoted string on the shape line does not truncate a real emit"
else
  bad "R6 — a single-quoted '#' on the shape's own line wrongly hid a real emit, causing a false refusal:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

# The inverse: an odd number of embedded `"` inside a single-quoted string on the shape line must not
# desync the double-quote parity and leave a genuine TRAILING comment un-stripped — that would
# resurrect the exact phantom-emit bug #274 fixes, reached through a second quoting path.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
cat >> "$k/skills/demo/SKILL.md" <<'SHAPE'

```bash
# >>> decision demo.rule shape >>>
state=$(printf '%s' '"CLEAN"' | jq '{state: .}'); echo 'the value is "quoted' > /dev/null  # earlier revision built: { legacy_field: .foo, state: .bar }
# <<< decision demo.rule shape <<<
```
SHAPE
python3 - "$k/decisions/registry.json" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace('"shape": null',
              '"shape": {"home": "skills/demo/SKILL.md", "marker": "demo.rule shape"}')
open(p, "w").write(t)
PY
python3 - "$k/skills/demo/scripts/prog.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
    'if .state == "CLEAN" then {verdict:"go", rule:"clean"}',
    'if .state == "CLEAN" then {verdict:"go", rule:"clean"}\n'
    '       elif .legacy_field == "x" then {verdict:"stop", rule:"legacy"}',
)
open(p, "w").write(t)
PY
git -C "$k" add -A
refuses "$k" R6 \
  "R6 — an odd embedded quote inside a single-quoted string does not hide a genuine trailing comment's phantom key"

# The `'\''` bash idiom for embedding a literal apostrophe inside a single-quoted string (e.g.
# `printf '%s' 'it'\''s'`) must not desync the quote-toggle scan either — the same #274 phantom-emit
# shape as the two cases above, reached through a THIRD quoting path (#306): a scanner that treats
# the idiom's close/escape/reopen span as an unmatched extra quote-pair ends the line believing a
# string is still open, hiding a genuine trailing comment's phantom key.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
cat >> "$k/skills/demo/SKILL.md" <<'SHAPE'

```bash
# >>> decision demo.rule shape >>>
state=$(printf '%s' 'it'\''s' | jq '{state: .}')  # earlier revision built: { legacy_field: .foo, state: .bar }
# <<< decision demo.rule shape <<<
```
SHAPE
python3 - "$k/decisions/registry.json" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace('"shape": null',
              '"shape": {"home": "skills/demo/SKILL.md", "marker": "demo.rule shape"}')
open(p, "w").write(t)
PY
python3 - "$k/skills/demo/scripts/prog.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
    'if .state == "CLEAN" then {verdict:"go", rule:"clean"}',
    'if .state == "CLEAN" then {verdict:"go", rule:"clean"}\n'
    '       elif .legacy_field == "x" then {verdict:"stop", rule:"legacy"}',
)
open(p, "w").write(t)
PY
git -C "$k" add -A
refuses "$k" R6 \
  "R6 — the escaped-apostrophe idiom on a shape line does not hide a genuine trailing comment's phantom key"

# Edge case: the idiom used TWICE on one line must still let a trailing comment's phantom key be
# found — the fix must not special-case a single occurrence only.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
cat >> "$k/skills/demo/SKILL.md" <<'SHAPE'

```bash
# >>> decision demo.rule shape >>>
state=$(printf '%s' 'it'\''s '\''really'\''' | jq '{state: .}')  # earlier revision built: { legacy_field: .foo, state: .bar }
# <<< decision demo.rule shape <<<
```
SHAPE
python3 - "$k/decisions/registry.json" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace('"shape": null',
              '"shape": {"home": "skills/demo/SKILL.md", "marker": "demo.rule shape"}')
open(p, "w").write(t)
PY
python3 - "$k/skills/demo/scripts/prog.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
    'if .state == "CLEAN" then {verdict:"go", rule:"clean"}',
    'if .state == "CLEAN" then {verdict:"go", rule:"clean"}\n'
    '       elif .legacy_field == "x" then {verdict:"stop", rule:"legacy"}',
)
open(p, "w").write(t)
PY
git -C "$k" add -A
refuses "$k" R6 \
  "R6 — the escaped-apostrophe idiom used twice on one shape line still lets a trailing comment's phantom key be found"

# Edge case: the escaped-apostrophe idiom used to CLOSE a string with no reopening quote right after
# (the `'\''s`-style end-of-word shape, e.g. `'it'\'s`) is NOT the same as the full close/escape/
# reopen span — a scan that assumes a reopening `'` is always there, and blindly swallows whatever
# character actually follows the escape, desyncs `in_sq` just as badly and hides a genuine trailing
# comment's phantom key.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
cat >> "$k/skills/demo/SKILL.md" <<'SHAPE'

```bash
# >>> decision demo.rule shape >>>
state=$(printf '%s' 'it'\'s | jq '{state: .}')  # earlier revision built: { legacy_field: .foo, state: .bar }
# <<< decision demo.rule shape <<<
```
SHAPE
python3 - "$k/decisions/registry.json" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace('"shape": null',
              '"shape": {"home": "skills/demo/SKILL.md", "marker": "demo.rule shape"}')
open(p, "w").write(t)
PY
python3 - "$k/skills/demo/scripts/prog.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
    'if .state == "CLEAN" then {verdict:"go", rule:"clean"}',
    'if .state == "CLEAN" then {verdict:"go", rule:"clean"}\n'
    '       elif .legacy_field == "x" then {verdict:"stop", rule:"legacy"}',
)
open(p, "w").write(t)
PY
git -C "$k" add -A
refuses "$k" R6 \
  "R6 — the escaped-apostrophe idiom closing a string with no reopening quote does not hide a genuine trailing comment's phantom key"

# Edge case: a shape line using the idiom with NO trailing comment must be unaffected — the fix is
# additive, not a rewrite of the scanner's default behavior.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
cat >> "$k/skills/demo/SKILL.md" <<'SHAPE'

```bash
# >>> decision demo.rule shape >>>
state=$(printf '%s' 'it'\''s' | jq '{state: .}')
# <<< decision demo.rule shape <<<
```
SHAPE
python3 - "$k/decisions/registry.json" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace('"shape": null',
              '"shape": {"home": "skills/demo/SKILL.md", "marker": "demo.rule shape"}')
open(p, "w").write(t)
PY
git -C "$k" add -A
run_check "$k"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "R6 — a shape line using the escaped-apostrophe idiom with no trailing comment is unaffected"
else
  bad "R6 — a shape line using the escaped-apostrophe idiom with no trailing comment wrongly refused:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

# --- R7 the owner must INVOKE, not merely mention -----------------------------------------------
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
# Delete the fenced call, leaving the skill otherwise intact. This is the exact move that would
# reintroduce #208 with the engine watching: re-derive the verdict by hand and every other rule
# here stays green.
python3 - "$k/skills/demo/SKILL.md" <<'PY'
import sys, re
p = sys.argv[1]
t = open(p).read()
t = t.replace("```bash\nscripts/decide.sh demo.rule < state.json\n```\n", "")
open(p, "w").write(t)
PY
refuses "$k" R7 "R7 — an owner that stopped invoking its own decision is refused"

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
# The same call, but OUTSIDE a fence — prose naming a script is not calling it.
python3 - "$k/skills/demo/SKILL.md" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace("```bash\nscripts/decide.sh demo.rule < state.json\n```\n",
              "Run scripts/decide.sh demo.rule to decide.\n")
open(p, "w").write(t)
PY
refuses "$k" R7 "R7 — an invocation that is only prose, not a fenced call, is refused"

# --- R8 prose may not re-enumerate the states the program tests ---------------------------------
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
cat >> "$k/skills/demo/SKILL.md" <<'RESTATE'

| State | Then |
|---|---|
| `CLEAN` | go |
| `DIRTY` | stop |
RESTATE
refuses "$k" R8 "R8 — a table re-enumerating the states the program tests is refused"

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
cat >> "$k/skills/demo/SKILL.md" <<'ANNOTATED'

<!-- decided-by: demo.rule -->

| State | Then |
|---|---|
| `CLEAN` | go |
| `DIRTY` | stop |
ANNOTATED
run_check "$k"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "R8 — an explicitly annotated table is allowed (the escape hatch works)"
else
  bad "R8 — the annotation escape hatch does not work:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
cat >> "$k/skills/demo/SKILL.md" <<'OVERREACH'

<!-- decided-by: demo.rule -->

| State | Then |
|---|---|
| `CLEAN` | go |
| `MERGEABLE` | go |
OVERREACH
refuses "$k" R8 "R8 — an annotated table naming a state the program never tests is refused"

# --- R8's annotated-table path must not let a comment-mentioned token silence a real gap ---------
# tokens_by_id[ann] is SUBTRACTED on this path, so a comment-derived phantom token (widening that
# set) could otherwise make a real, uncovered table row read as covered — the opposite of R8's
# stated failure direction. A comment naming the same state OVERREACH annotates must not change the
# verdict: the program still never tests MERGEABLE in real code, so R8 must still refuse.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
python3 - "$k/skills/demo/scripts/prog.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
    "set -euo pipefail\n",
    'set -euo pipefail\n# a future release may also handle .state == "MERGEABLE" here\n',
)
open(p, "w").write(t)
PY
git -C "$k" add -A
cat >> "$k/skills/demo/SKILL.md" <<'PHANTOM_TOKEN'

<!-- decided-by: demo.rule -->

| State | Then |
|---|---|
| `CLEAN` | go |
| `MERGEABLE` | go |
PHANTOM_TOKEN
refuses "$k" R8 \
  "R8 — a comment mentioning a state's == form does not silence a real annotated-table gap"

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
cat >> "$k/skills/demo/SKILL.md" <<'UNKNOWNID'

<!-- decided-by: nope.missing -->

| State | Then |
|---|---|
| `CLEAN` | go |
| `DIRTY` | stop |
UNKNOWNID
refuses "$k" R8 "R8 — an annotation for an unregistered decision is refused"

# --- the claim the whole design rests on --------------------------------------------------------
#
# R8's token set is derived BY REGEX FROM THE PROGRAM TEXT, never from a list in the registry. That
# is the single property that separated the winning design from the losing one: a hand-typed
# vocabulary in the manifest is a second copy, and the manifest of a system whose purpose is to
# abolish second copies is the last place one may live. So: grow the program a NEW branch, restate
# THAT branch as a table, touch the registry not at all — and the guard must still fire.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
python3 - "$k/skills/demo/scripts/prog.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace('elif .state == "DIRTY"',
              'elif .state == "BLOCKED" then {verdict:"stop", rule:"blocked"}\n       elif .state == "DIRTY"')
open(p, "w").write(t)
PY
git -C "$k" add -A
cat >> "$k/skills/demo/SKILL.md" <<'NEWTOKEN'

| State | Then |
|---|---|
| `BLOCKED` | stop |
| `CLEAN` | go |
NEWTOKEN
refuses "$k" R8 "R8 — a NEW program branch restated as a table fires with the registry untouched"

# --- R10 every executable is registered or recorded (#252) --------------------------------------
#
# The counter-guard to R1: R1 proves everything IN the registry is real, R10 proves everything
# REAL is in the registry (registered as a program) or explicitly recorded as deliberately not
# one. The escape this closes is the fifteen-second one from #252's own Problem section: delete a
# decision's registry row, and its program stops being anyone's business — R10 is what still
# notices it exists.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
cat > "$k/skills/demo/scripts/extra.sh" <<'EXTRA'
#!/usr/bin/env bash
exit 0
EXTRA
chmod +x "$k/skills/demo/scripts/extra.sh"
git -C "$k" add -A
refuses "$k" R10 \
  "R10 — a tracked executable neither registered nor recorded in not_decisions is refused by name"

# R10's own failure modes, on not_decisions itself (#252 Task 2).

# A path cannot be BOTH a registered program and a recorded non-decision — one file, two
# contradictory claims.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
python3 - "$k/decisions/registry.json" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
    '"scripts/decide.sh": "the dispatcher itself — it runs decisions, it is not one"',
    '"scripts/decide.sh": "the dispatcher itself — it runs decisions, it is not one",\n'
    '    "skills/demo/scripts/prog.sh": "wrongly recorded — this IS demo.rule\'s own program"',
)
open(p, "w").write(t)
PY
git -C "$k" add -A
refuses "$k" R10 \
  "R10 — a path that is both a registered program and recorded in not_decisions is refused"

# A not_decisions key whose file no longer exists is a stale record.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
python3 - "$k/decisions/registry.json" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
    '"scripts/decide.sh": "the dispatcher itself — it runs decisions, it is not one"',
    '"scripts/decide.sh": "the dispatcher itself — it runs decisions, it is not one",\n'
    '    "skills/demo/scripts/ghost.sh": "a file that was deleted, but nobody deleted this record"',
)
open(p, "w").write(t)
PY
git -C "$k" add -A
refuses "$k" R10 "R10 — a not_decisions entry whose file no longer exists is refused as stale"

# An empty reason verifies nothing — the reason IS the whole value of the record.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
python3 - "$k/decisions/registry.json" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
    '"scripts/decide.sh": "the dispatcher itself — it runs decisions, it is not one"',
    '"scripts/decide.sh": ""',
)
open(p, "w").write(t)
PY
git -C "$k" add -A
refuses "$k" R10 "R10 — a not_decisions entry with an empty reason is refused"

# An ABSOLUTE path must never be checked against the real filesystem root — `pathlib`'s `/`
# operator silently discards the repo root the moment the right side is absolute, so an absolute
# key would otherwise probe the machine running the check instead of the repo (code-review finding
# on #252). Every path in this registry is repo-relative; an absolute one is refused outright,
# never treated as "exists" just because the same absolute path happens to be a real file on disk.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
python3 - "$k/decisions/registry.json" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace(
    '"scripts/decide.sh": "the dispatcher itself — it runs decisions, it is not one"',
    '"scripts/decide.sh": "the dispatcher itself — it runs decisions, it is not one",\n'
    '    "/etc/hosts": "an absolute path — must be refused, never checked against the real root"',
)
open(p, "w").write(t)
PY
git -C "$k" add -A
refuses "$k" R10 "R10 — an absolute path in not_decisions is refused, never checked against the real filesystem root"

# --- R10's SCOPE: hooks/ and scripts at a skill's ROOT (#307) -----------------------------------
#
# `E` is only as complete as the pathspecs it is enumerated with. #252 took those from the four
# globs its own Problem section measured "32 executables" with — `scripts/` and
# `skills/*/scripts/` — so a genuinely decision-shaped file living anywhere else was invisible BY
# CONSTRUCTION: R10 never enumerated it, it therefore needed neither a registry row nor a
# `not_decisions` record, and the guard never noticed it existed. Two such files were already in
# this repo when #307 was filed — `hooks/roseline-gate.sh`, a PreToolUse gate that branches on
# `ROSELINE_GATE` and a launcher probe to allow or deny a Read, and
# `skills/debug-issue/find-polluter.sh` at a skill's root. Each new shape is driven to RED
# below over the scratch kit, the same way every other rule here is.

# A hook. `hooks/` holds the only files in this kit that decide whether a tool call runs at all,
# and it sat entirely outside `E`.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
mkdir -p "$k/hooks"
printf '#!/usr/bin/env bash\nexit 0\n' > "$k/hooks/demo-gate.sh"
chmod +x "$k/hooks/demo-gate.sh"
git -C "$k" add -A
refuses "$k" R10 \
  "R10 — a tracked executable under hooks/ is refused by name (the #307 glob-scope gap)"

# The same hook, RECORDED. Widening `E` must not leave a hooks/ path with no reachable remedy: a
# gap closed by making its own fix impossible is not closed.
python3 - "$k/decisions/registry.json" <<'RECORD'
import json, sys
p = sys.argv[1]
doc = json.load(open(p))
doc["not_decisions"]["hooks/demo-gate.sh"] = "a scratch hook, recorded rather than registered"
json.dump(doc, open(p, "w"), indent=2)
RECORD
git -C "$k" add -A
run_check "$k"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "R10 — a hooks/ executable recorded in not_decisions passes; the widened E stays answerable"
else
  bad "R10 — recording a hooks/ executable did not satisfy the widened E:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

# A script at a skill's ROOT rather than under its `scripts/` subdirectory — the exact shape of
# `skills/debug-issue/find-polluter.sh`.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
printf '#!/usr/bin/env bash\nexit 0\n' > "$k/skills/demo/root-tool.sh"
chmod +x "$k/skills/demo/root-tool.sh"
git -C "$k" add -A
refuses "$k" R10 \
  "R10 — a tracked executable at a skill's ROOT, not under scripts/, is refused (#307)"

# A script nested DEEPER than `skills/<one-segment>/scripts/`. The replaced glob's singleton `*`
# had to match exactly one segment, so this was out of reach as well — the case #252's own comment
# flagged as "the NEXT script someone drops in", now enumerated rather than flagged.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
mkdir -p "$k/skills/demo/nested/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$k/skills/demo/nested/scripts/deep.sh"
chmod +x "$k/skills/demo/nested/scripts/deep.sh"
git -C "$k" add -A
refuses "$k" R10 \
  "R10 — a tracked executable nested below skills/<skill>/scripts/ is refused (#307)"

# --- R10's SCOPE: the DELIBERATELY ABSENT exclusion is real at every depth (#384) ---------------
#
# git's pathspec `*` crosses `/` — the same property the two nesting cases just above exist to
# enumerate — so `skills/*.sh` also reaches a `templates/` or `tests/` directory nested anywhere
# below `skills/`, not just the repo-root ones the header's old "DELIBERATELY ABSENT" wording
# implied. Each fixture below is a tracked executable under one of the four excluded directory
# names, nested a level deep, and must PASS (excluded from `E`) rather than be refused.

# A fixture under a nested `templates/` — the exact shape #384 measured against `main`.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
mkdir -p "$k/skills/demo/templates"
printf '#!/usr/bin/env bash\nexit 0\n' > "$k/skills/demo/templates/fixture.sh"
chmod +x "$k/skills/demo/templates/fixture.sh"
git -C "$k" add -A
run_check "$k"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "R10 — a tracked executable under a nested templates/ is excluded from E at any depth (#384)"
else
  bad "R10 — a nested templates/ fixture was not excluded from E:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

# The mirror case for a nested `tests/`.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
mkdir -p "$k/skills/demo/tests"
printf '#!/usr/bin/env bash\nexit 0\n' > "$k/skills/demo/tests/fixture.sh"
chmod +x "$k/skills/demo/tests/fixture.sh"
git -C "$k" add -A
run_check "$k"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "R10 — a tracked executable under a nested tests/ is excluded from E at any depth (#384)"
else
  bad "R10 — a nested tests/ fixture was not excluded from E:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

# The mirror case for a nested `evals/` — and the `.py` half of every exclusion pair, the exact
# shape the issue's own Spec names (`skills/foo/evals/run.py`).
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
mkdir -p "$k/skills/demo/evals"
printf '#!/usr/bin/env python3\n' > "$k/skills/demo/evals/run.py"
chmod +x "$k/skills/demo/evals/run.py"
git -C "$k" add -A
run_check "$k"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "R10 — a tracked .py file under a nested evals/ is excluded from E at any depth (#384)"
else
  bad "R10 — a nested evals/ fixture was not excluded from E:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

# The mirror case for a nested `samples/`, the fourth and last excluded directory name.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
mkdir -p "$k/skills/demo/samples"
printf '#!/usr/bin/env bash\nexit 0\n' > "$k/skills/demo/samples/fixture.sh"
chmod +x "$k/skills/demo/samples/fixture.sh"
git -C "$k" add -A
run_check "$k"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "R10 — a tracked executable under a nested samples/ is excluded from E at any depth (#384)"
else
  bad "R10 — a nested samples/ fixture was not excluded from E:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

# The REFERENCE bash reader for scripts/tracked-exec-globs.txt — the shape #144's
# parse-sweep.sh consumer will copy (#307). It must honor `#` as a comment starter ANYWHERE on
# the line, exactly like decision-check.py's `line.split("#", 1)[0].strip()`: strip everything
# from the first `#` onward, trim BOTH leading and trailing whitespace (Python's `.strip()` takes
# both), then drop blank lines (#384 finding 2 — a whole-line-only comment strip let `#`,
# `PreToolUse` and `gates` reach `git ls-files` as three extra pathspecs). A future consumer
# copying this must match that split exactly, not merely "look similar".
read_tracked_exec_globs() {
  sed 's/#.*//' "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^[[:space:]]*$'
}

# The format documents `#` as starting a comment ANYWHERE on the line, and decision-check.py's
# reader honors that mid-line. The divergence, expressed as a test (#384 finding 2): a line
# carrying a trailing inline comment must read as the pathspec alone, not the comment text as
# extra pathspecs `git ls-files` would then receive.
fixture_list=$(kit_scratch)/fixture-globs.txt
printf 'hooks/*.sh   # PreToolUse gates\n' > "$fixture_list"
fixture_read=$(read_tracked_exec_globs "$fixture_list")
if [ "$fixture_read" = 'hooks/*.sh' ]; then
  ok "the bash reference reader strips a mid-line # comment, like decision-check.py's reader (#384)"
else
  bad "the bash reference reader kept trailing text after # — got: '$fixture_read'"
fi

# `E`'s pathspecs are DATA in one file, not a literal inside one guard, so a second consumer can
# read the same answer instead of keeping a copy that drifts. #144 widens `scripts/parse-sweep.sh`
# past `tests/*/test.sh` to exactly these paths, and #307's triage asked that whichever half landed
# first define the list the other reads. This asserts the shipped list is readable from bash — the
# language of that other consumer — and that it really enumerates the two files #307 was filed about
# — plus a regression check (#384 Task 1 Step 5): the new exclude lines must not have eaten a real
# script.
globs=$(read_tracked_exec_globs "$REPO/scripts/tracked-exec-globs.txt")
if [ -z "$globs" ]; then
  bad "scripts/tracked-exec-globs.txt is missing or declares no pathspecs — R10's E is unanswerable"
else
  # Globbing off: these ARE glob patterns, and an unquoted expansion would otherwise let the shell
  # match them against whatever directory the suite is run from before git ever sees them.
  set -f
  listed=$(git -C "$REPO" ls-files -- $globs)
  set +f
  missing=''
  for want in hooks/roseline-gate.sh skills/debug-issue/find-polluter.sh skills/auto-dev/scripts/survey.sh; do
    case "$listed" in
      *"$want"*) ;;
      *) missing="$missing $want" ;;
    esac
  done
  if [ -z "$missing" ]; then
    ok "the shipped pathspec list reads from bash and still enumerates real scripts after the #384 excludes (#307, #384, for #144)"
  else
    bad "the shipped pathspec list misses:$missing"
  fi
fi

# --- tracked_exec_globs()'s two Unanswerable branches are driven to red, not trusted (#384) -----
#
# tracked_exec_globs() raises on an unreadable list and on a comment-only one — its own docstring
# says why: "A missing or comment-only list would otherwise make R10 enumerate NOTHING and report
# every executable in the repo as covered — the #45 shape, a guard serving 'all clean' over an
# empty set." Both work by hand today, but nothing above drives either branch: this suite's own
# rule is "every rule ... is asserted by BREAKING a working kit ... never by reading the guard and
# believing it", and until now these two raises were read and believed.
#
# TRACKED_EXEC_GLOBS_FILE resolves against decision-check.py's OWN location, never `--repo`
# (tracked_exec_globs()'s own docstring) — deliberately, since a scratch kit built by make_kit
# carries no copy of the list. So neither branch can be reached by pointing $CHECK at a scratch
# kit; the harness below copies decision-check.py itself into the kit (decide.sh is already there,
# from make_kit) alongside a list under test, then runs THAT COPY with --repo <kit>, the only way
# the resolution lines up with the fixture rather than this repo's own real list.

# guard_copy_with_list <dir> <list-content|--absent> — drops a private copy of decision-check.py
# into $dir/scripts/, plus a tracked-exec-globs.txt holding <list-content> (or no file at all, for
# --absent, the "unreadable" case).
guard_copy_with_list() {
  local dir="$1" content="$2"
  cp "$CHECK" "$dir/scripts/decision-check.py"
  if [ "$content" = --absent ]; then
    rm -f "$dir/scripts/tracked-exec-globs.txt"
  else
    printf '%s\n' "$content" > "$dir/scripts/tracked-exec-globs.txt"
  fi
}

# Reuses unanswerable()'s exit-2/needle check rather than repeating it: only the CHECK path
# differs, so swap it in for the duration of the call — the COPY of the guard guard_copy_with_list
# placed inside the kit, never the real $CHECK, which would resolve TRACKED_EXEC_GLOBS_FILE
# against THIS repo's own list and never see the fixture at all.
unanswerable_copy() {
  local k="$1" needle="$2" label="$3"
  local real_check="$CHECK"
  CHECK="$k/scripts/decision-check.py"
  unanswerable "$k" "$needle" "$label"
  CHECK="$real_check"
}

# The comment-only list.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
guard_copy_with_list "$k" '# just a comment, no pathspecs'
unanswerable_copy "$k" "declares no pathspecs" \
  "tracked_exec_globs() — a comment-only list is Unanswerable, not silently enumerating the whole repo unfiltered (#384)"

# The unreadable list — here, entirely absent, which reaches the same OSError branch as a
# permission-denied read.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
guard_copy_with_list "$k" --absent
unanswerable_copy "$k" "could not read R10's pathspec list" \
  "tracked_exec_globs() — a missing list is Unanswerable, not silently enumerating the whole repo unfiltered (#384)"

# Both raises just asserted are LOAD-BEARING, not merely present: mutate a fresh copy so each
# `raise Unanswerable(...)` becomes `return ()`, and require the unanswerable verdict to disappear.
# A raise a maintainer could silently delete without a single test noticing is the same defect
# this whole suite exists to close, one level up. The mutation touches only a disposable copy of
# decision-check.py inside the scratch kit — never the real, tracked one.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
guard_copy_with_list "$k" '# just a comment, no pathspecs'
python3 - "$k/scripts/decision-check.py" <<'MUTATE'
import re, sys
p = sys.argv[1]
text = open(p, encoding="utf-8").read()
text, n = re.subn(
    r'raise Unanswerable\(\s*\n\s*f"\{path\} declares no pathspecs.*?\n\s*\)',
    'return ()',
    text,
    count=1,
    flags=re.S,
)
if n != 1:
    sys.exit("expected to mutate exactly 1 raise, matched %d" % n)
open(p, "w", encoding="utf-8").write(text)
MUTATE
CHECK_OUT=$(python3 "$k/scripts/decision-check.py" --repo "$k" 2>&1)
CHECK_RC=$?
if [ "$CHECK_RC" -ne 2 ]; then
  ok "tracked_exec_globs()'s comment-only raise is load-bearing — without it the guard no longer refuses as unanswerable (#384)"
else
  bad "tracked_exec_globs()'s comment-only raise is NOT load-bearing — the guard still exits 2 without it:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
guard_copy_with_list "$k" --absent
python3 - "$k/scripts/decision-check.py" <<'MUTATE'
import re, sys
p = sys.argv[1]
text = open(p, encoding="utf-8").read()
text, n = re.subn(
    r'raise Unanswerable\(f"could not read R10\x27s pathspec list at \{path\}: \{exc\}"\)',
    'return ()',
    text,
    count=1,
)
if n != 1:
    sys.exit("expected to mutate exactly 1 raise, matched %d" % n)
open(p, "w", encoding="utf-8").write(text)
MUTATE
CHECK_OUT=$(python3 "$k/scripts/decision-check.py" --repo "$k" 2>&1)
CHECK_RC=$?
if [ "$CHECK_RC" -ne 2 ]; then
  ok "tracked_exec_globs()'s unreadable-list raise is load-bearing — without it the guard no longer refuses as unanswerable (#384)"
else
  bad "tracked_exec_globs()'s unreadable-list raise is NOT load-bearing — the guard still exits 2 without it:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

# --- the escape hatch of #208 is closed, end to end (#252 Task 3) -------------------------------
#
# Before R10, this was a fifteen-second escape: delete a decision's registry row, and every OTHER
# rule goes quiet along with it — R7's owner check and R8's token derivation both iterate only over
# STILL-REGISTERED decisions, so an orphaned program and its restating table become invisible to
# both. R10 is what still notices the file exists.
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"

# A second, harmless decision, so the registry is never EMPTY once demo.rule's row is deleted below
# — an empty `decisions` list would hit the pre-existing #45 refusal (Unanswerable, exit 2), which
# would prove nothing about R10 specifically.
cat > "$k/skills/demo/scripts/other.sh" <<'OTHER'
#!/usr/bin/env bash
set -euo pipefail
jq -c '{verdict:"ok", rule:"only"}'
OTHER
chmod +x "$k/skills/demo/scripts/other.sh"
cat > "$k/skills/demo/OTHER.md" <<'OWNER2'
# Demo other skill

```bash
scripts/decide.sh demo.other < state.json
```
OWNER2
mkdir -p "$k/tests/demo-other"
printf '#!/usr/bin/env bash\nexit 0\n' > "$k/tests/demo-other/test.sh"
chmod +x "$k/tests/demo-other/test.sh"
python3 - "$k/decisions/registry.json" <<'PY'
import json, sys
p = sys.argv[1]
doc = json.load(open(p))
doc["decisions"].append({
    "id": "demo.other",
    "issue": 0,
    "program": {"kind": "exec", "path": "skills/demo/scripts/other.sh"},
    "shape": None,
    "owner": "skills/demo/OTHER.md",
    "suites": ["tests/demo-other/test.sh"],
    "stdin": True,
    "verdict": {"source": "stdout-json", "vocabulary": ["ok"]},
})
json.dump(doc, open(p, "w"), indent=2)
PY
git -C "$k" add -A
run_check "$k"
if [ "$CHECK_RC" -eq 0 ]; then
  ok "a second, harmless decision keeps the kit coherent (baseline for the escape-hatch case below)"
else
  bad "the two-decision baseline does not pass, so the escape-hatch case below is meaningless:"
  printf '%s\n' "$CHECK_OUT" | sed 's/^/          /'
fi

# Reproduce the #208 escape: delete demo.rule's OWN registry row, but leave its program (prog.sh)
# and its restating table (SKILL.md's "Apply the verdict" table) exactly as they were.
python3 - "$k/decisions/registry.json" <<'PY'
import json, sys
p = sys.argv[1]
doc = json.load(open(p))
doc["decisions"] = [d for d in doc["decisions"] if d["id"] != "demo.rule"]
json.dump(doc, open(p, "w"), indent=2)
PY
run_check "$k"
case "$CHECK_OUT" in
  *R8*) bad "the escape-hatch fixture — R8 fired, but it must NOT: R8 going silent once demo.rule \
is unregistered is the escape itself, and a fixture where R8 still catches it does not reproduce \
#208's shape" ;;
  *) ok "R8 stays silent once demo.rule is unregistered — the exact silent half of the #208 escape" ;;
esac
refuses "$k" R10 \
  "R10 — deleting a decision's row while its program and restating table survive is refused (the #208 escape, now closed)"

# --- the exit-code contract ----------------------------------------------------------------------
k=$(kit_scratch)/kit; mkdir -p "$k"; make_kit "$k"
rm -f "$k/scripts/decide.sh"
run_check "$k"
if [ "$CHECK_RC" -eq 2 ]; then
  ok "exit 2 — with no dispatcher no program can be extracted, and an unanswerable question is not a pass"
else
  bad "expected exit 2 when the dispatcher is absent, got $CHECK_RC"
fi

echo
# --- the interpreter is resolved, not left to the OS's search order (#623) ------------------------
#
# `subprocess.run(["bash", ...])` leaves argv[0] for the OS to resolve. On Windows that is
# CreateProcess, whose search order reaches C:\Windows\System32\bash.exe — the WSL launcher — before
# the Git Bash every other script in this kit runs under. WSL can read neither `C:\...` (it eats the
# backslashes as escapes, which is how #623 surfaced: every separator gone from the path) nor
# `C:/...` (it wants /mnt/c/...), so rewriting the path does not fix it and was measured not to.
# Resolving the interpreter through shutil.which() does, and leaves the path argument alone.
#
# The assertion is structural because it cannot be behavioural: on Linux a bare "bash" resolves to
# the right interpreter, so no fixture can drive this red on CI. Pinning the call site is the only
# thing that keeps the idiom from coming back.
# Full-line comments are stripped first, into a file rather than through a pipe: the prose below
# and in decision-check.py's own header quotes the very idiom being refused, and a `grep -q` fed by
# a pipe is what scripts/sigpipe-idiom-check.py refuses.
code_only="$(kit_scratch)/decision-check.code"
grep -v '^[[:space:]]*#' "$CHECK" > "$code_only"
if grep -Eq '\[[[:space:]]*["'"'"']bash["'"'"'][[:space:]]*,' "$code_only"; then
  bad "decision-check.py invokes a bare \"bash\" — on Windows CreateProcess resolves that to WSL, \
which cannot see the checkout, so no verdict is reached (#623). Resolve it through shutil.which()."
else
  ok "the bash interpreter is resolved explicitly, not left to the OS search order (#623)"
fi

# Every file read and write pins utf-8, and so do the subprocess decodes (#623). Windows defaults
# both to the locale codec (cp1252 here), under which a single em-dash in this repo's own registry
# or prose raises UnicodeDecodeError and the script exits with a traceback instead of a verdict.
# Structural for the same reason as the case above: ubuntu CI is already utf-8, so nothing here can
# be driven red behaviourally. `grep -Evq` reads the extracted calls from a FILE, never a pipe, so
# scripts/sigpipe-idiom-check.py has nothing to refuse.
io_calls="$(kit_scratch)/decision-check.io"
grep -Eo '(read|write)_text\([^)]*\)' "$code_only" > "$io_calls"
# A subprocess decode spells text=True and encoding= on two SEPARATE lines, so it is counted rather
# than matched: awk reads the line after each text=True and reports how many lack the pin.
unpinned_decodes=$(awk '/text=True,/ { getline nxt; if (nxt !~ /encoding=/) n++ } END { print n+0 }' "$code_only")
if ! [ -s "$io_calls" ]; then
  bad "no read_text/write_text call was found in decision-check.py at all — the utf-8 assertion below would pass vacuously, which is not a pass"
elif grep -Evq 'encoding=' "$io_calls"; then
  bad "decision-check.py reads or writes a file without pinning encoding=, so a cp1252 host decodes this repo's utf-8 with the wrong codec and reaches no verdict (#623)"
elif [ "$unpinned_decodes" -ne 0 ]; then
  bad "$unpinned_decodes subprocess call(s) decode child output with text=True but no encoding= — including program_text()'s own, which reads decide.sh's utf-8 program back through cp1252 (#623)"
else
  ok "every file read/write and subprocess decode pins utf-8 (#623)"
fi

# The refusal paths print U+2192 and U+2014, and this suite captures that output through a command
# substitution — a pipe, where Windows falls back to the locale codec. Without both streams pinned,
# report() raised UnicodeEncodeError and the guard died mid-verdict (#623).
if [ "$(grep -Ec 'sys[.]std(out|err)[.]reconfigure' "$code_only")" -eq 2 ]; then
  ok "both output streams are pinned to utf-8 before the first verdict is printed (#623)"
else
  bad "decision-check.py does not pin BOTH sys.stdout and sys.stderr — its refusal lines carry characters cp1252 cannot encode, so on Windows it dies printing the verdict instead of returning it (#623)"
fi
if [ "$fails" -eq 0 ]; then
  echo "decisions: OK — the dispatcher answers, and every rule of the guard goes red on demand."
  exit 0
fi
echo "decisions: $fails failure(s)."
exit 1
