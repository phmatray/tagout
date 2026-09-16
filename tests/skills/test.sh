#!/usr/bin/env bash
# Golden test for check-frontmatter.py.
#
# That checker is an ABSENCE rule: it asserts skill frontmatter carries no `version`
# key (#16). An absence rule has no positive witness in the repo — the six real skills
# already satisfy it — so a pattern that quietly stops matching keeps printing
# "frontmatter OK" and CI cannot tell. Typo the key to `versionn`, drop a spelling,
# narrow the check out of existence: all stay green. This file is that missing witness.
#
# It also pins the two bugs the #16 review found in the first, regex-based attempt:
#   - `^[ \t]*version:` also matched indented continuation lines of a `>-` block
#     scalar, so PROSE tripped the guard (false positive, cases N2/N3 below);
#   - it missed `"version":`, `'version':`, `version :` and the flow form
#     `metadata: {version: 1}`, all the same key to YAML (false negatives, P2–P5).
# Both are why the checker parses YAML instead of pattern-matching.
set -euo pipefail
cd "$(dirname "$0")/../.."

CHECK="tests/skills/check-frontmatter.py"
[ -f "$CHECK" ] || { echo "FAIL: $CHECK missing"; exit 1; }

# Scratch dir and EXIT trap come from the shared preamble (#72) — eight suites each had
# their own, and they had diverged. KIT_ROOT is derived from this file's location rather
# than $PWD: $PWD is only right because a `cd` sits above, and moving it would break the
# source silently (tests/ci-wiring did exactly that).
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
WORK=$(kit_scratch)

# check-frontmatter.py resolves its root as parents[2] of its own path, so a scratch
# tree holding skills/, tests/skills/ and requirements.json is a complete world.
mkdir -p "$WORK/root"
# commands/ joins the scratch world for #266: commands/auto-dev-worker.md is a declared consumer of
# the untrusted-input boundary (it is what a dispatched worker actually reads), so a root without it
# answers NO SUCH CONSUMER for every boundary case below. It is never mutated — only skills/ is
# restored between cases — so one copy at setup is enough.
# evals/ joins the scratch world for #331: the trigger contract is now
# evals/<skill>-trigger-eval.json, so a root without evals/ answers "trigger eval set missing"
# for every skill. Unlike commands/ it IS mutated — by run_eval_case below, which restores it
# from $PRISTINE the same way run_case restores skills/.
# docs/, ARCHITECTURE.md and README.md join the scratch world for #269: check-shared-refs.py now
# checks every skills/_shared/*.md document that declares '## Consumers', not just the boundary,
# and several of those declared consumers live outside skills/ (docs/methodology.md,
# ARCHITECTURE.md, README.md) — a root without them answers NO SUCH CONSUMER on the untouched
# baseline itself. Never mutated, same reasoning as commands/.
cp -R skills tests commands evals requirements.json docs ARCHITECTURE.md README.md "$WORK/root/"
ROOT="$WORK/root"
PRISTINE="$WORK/pristine"
mkdir -p "$PRISTINE"
cp -R "$ROOT/skills" "$PRISTINE/"
cp -R "$ROOT/evals" "$PRISTINE/"
# commands/ used to be copy-once because nothing mutated it. #436 added a check over it (every
# command file names the skill it dispatches to), and a check no case can drive red is a check
# that stays green after it stops working — so it joins the restored set.
cp -R "$ROOT/commands" "$PRISTINE/"

fails=0

# run_case <label> <expect: pass|fail> <python mutator>
# The mutator receives the scratch root as argv[1] and edits a SKILL.md in place.
run_case() {
  local label="$1" expect="$2" mutator="$3"
  rm -rf "$ROOT/skills"
  cp -R "$PRISTINE/skills" "$ROOT/"
  python3 -c "$mutator" "$ROOT"
  local out rc
  set +e
  out=$(python3 "$ROOT/tests/skills/check-frontmatter.py" 2>&1)
  rc=$?
  set -e
  if [ "$expect" = fail ]; then
    if [ "$rc" -eq 0 ]; then
      echo "FAIL: [$label] expected a rejection, got exit 0"
      echo "      $out"
      fails=$((fails + 1))
    elif ! grep -q 'forbidden (#16)\|missing' <<<"$out"; then
      echo "FAIL: [$label] rejected, but not with the expected message"
      echo "      $out"
      fails=$((fails + 1))
    else
      echo "ok   [$label] rejected"
    fi
  else
    if [ "$rc" -ne 0 ]; then
      echo "FAIL: [$label] expected acceptance, got exit $rc"
      echo "      $out"
      fails=$((fails + 1))
    else
      echo "ok   [$label] accepted"
    fi
  fi
}

# Replace the `metadata:` block of one skill with an arbitrary YAML snippet.
meta_mutator() {
  cat <<PY
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]) / "skills/review-followups/SKILL.md"
t = p.read_text(encoding="utf-8")
t = re.sub(r'^metadata:\n(?:[ \t]+.*\n)+', '''$1''', t, count=1, flags=re.M)
p.write_text(t, encoding="utf-8")
PY
}

echo "== a version key must be rejected, however it is spelled =="
run_case "P1 plain           metadata.version" fail "$(meta_mutator 'metadata:
  author: Philippe Matray
  suite: tagout
  version: 1.8.0
')"
run_case "P2 double-quoted   metadata.version" fail "$(meta_mutator 'metadata:
  author: Philippe Matray
  suite: tagout
  "version": 1.8.0
')"
run_case "P3 single-quoted   metadata.version" fail "$(meta_mutator "metadata:
  author: Philippe Matray
  suite: tagout
  'version': 1.8.0
")"
run_case "P4 space-before-colon             " fail "$(meta_mutator 'metadata:
  author: Philippe Matray
  suite: tagout
  version : 1.8.0
')"
run_case "P5 flow mapping    metadata.version" fail "$(meta_mutator 'metadata: {author: Philippe Matray, suite: tagout, version: 1.8.0}
')"
run_case "P6 top-level       version         " fail "$(meta_mutator 'version: 2.0.0
metadata:
  author: Philippe Matray
  suite: tagout
')"

echo "== the other frontmatter facts stay enforced =="
run_case "P7 metadata.author missing        " fail "$(meta_mutator 'metadata:
  suite: tagout
')"
run_case "P8 metadata.suite missing         " fail "$(meta_mutator 'metadata:
  author: Philippe Matray
')"
run_case "P9 license key missing            " fail '
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]) / "skills/review-followups/SKILL.md"
t = p.read_text(encoding="utf-8")
# Drop the key but leave the WORD in prose: a substring test would still pass here.
t = t.replace("license: MIT\n", "", 1)
t = t.replace("compatibility: >-", "compatibility: >-\n  Ships under an MIT license: see LICENSE.", 1)
p.write_text(t, encoding="utf-8")
'

echo "== prose is not a key: these must be accepted =="
run_case "N1 untouched baseline             " pass 'import sys'
run_case "N2 \"version:\" inside compatibility" pass '
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]) / "skills/review-followups/SKILL.md"
t = p.read_text(encoding="utf-8")
t = re.sub(r"^compatibility: >-\n(?:[ \t]+.*\n)+",
           "compatibility: >-\n  Requires python3 and git. Tested against gh CLI at\n"
           "  version: 2.40 or later.\n", t, count=1, flags=re.M)
p.write_text(t, encoding="utf-8")
'
run_case "N3 \"version:\" inside description  " pass '
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]) / "skills/review-followups/SKILL.md"
t = p.read_text(encoding="utf-8")
t = re.sub(r"^description: >-\n(?:[ \t]+.*\n)+",
           "description: >-\n  Consolidates open migration follow-ups. Reports the schema\n"
           "  version: 2 payload. Triggers on \"what is still open\", « fais le point ».\n",
           t, count=1, flags=re.M)
p.write_text(t, encoding="utf-8")
'

echo "== the 750-char soft ceiling WARNs; the guide's 1024 still hard-fails (#323) =="
# The soft ceiling is this suite's first NON-BINARY verdict: it must print a warning and leave the
# exit code alone. run_case keys only on pass/fail, so it cannot tell "warned and accepted" from
# "said nothing and accepted" — which is the whole behaviour under test. Hence a helper that pins
# the exit code AND the output text, with a leading `!` on the pattern asserting its ABSENCE.
#
# run_desc_case <label> <expected exit> <pattern | !pattern> <python mutator>
run_desc_case() {
  local label="$1" want_rc="$2" pattern="$3" mutator="$4"
  rm -rf "$ROOT/skills"
  cp -R "$PRISTINE/skills" "$ROOT/"
  python3 -c "$mutator" "$ROOT"
  local out rc negate=0
  case "$pattern" in '!'*) negate=1; pattern="${pattern#!}" ;; esac
  set +e
  out=$(python3 "$ROOT/tests/skills/check-frontmatter.py" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne "$want_rc" ]; then
    echo "FAIL: [$label] expected exit $want_rc, got $rc"
    echo "      $out"
    fails=$((fails + 1))
    return
  fi
  if grep -qE "$pattern" <<<"$out"; then
    if [ "$negate" -eq 1 ]; then
      echo "FAIL: [$label] exit $rc as expected, but the output matched /$pattern/ and must not"
      echo "      $out"
      fails=$((fails + 1))
      return
    fi
  elif [ "$negate" -eq 0 ]; then
    echo "FAIL: [$label] exit $rc as expected, but the output did not match /$pattern/"
    echo "      $out"
    fails=$((fails + 1))
    return
  fi
  echo "ok   [$label]"
}

# Give review-followups' description exactly $1 NORMALIZED characters (the count the checker uses).
desc_mutator() {
  cat <<PY
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]) / "skills/review-followups/SKILL.md"
t = p.read_text(encoding="utf-8")
body = ("Consolidates the open migration follow-ups and updates them at the source. " * 40)[:$1].strip()
body += "x" * ($1 - len(body))
assert len(body) == $1, len(body)
t = re.sub(r"^description: >-\n(?:[ \t]+.*\n)+", "description: >-\n  " + body + "\n",
           t, count=1, flags=re.M)
p.write_text(t, encoding="utf-8")
PY
}

run_desc_case "W1 850 chars warns, exit unchanged " 0 \
  'WARN review-followups: description is 850 characters' "$(desc_mutator 850)"
run_desc_case "W2 1100 chars still hard-fails    " 1 \
  'review-followups: description is 1100 characters \(guide limit: 1024\)' "$(desc_mutator 1100)"
run_desc_case "W3 750 chars is silent            " 0 \
  '!review-followups: description is' "$(desc_mutator 750)"

echo "== the body-size report is visible and measures the real body, not a cached figure (#473) =="
# Appends exactly $1 raw bytes to the END of profile-repo's body (not literally after the
# frontmatter's closing --- — the assert below only proves the frontmatter parses; the checker
# measures everything from frontmatter-end to EOF either way, so appending anywhere in the body
# exercises the same code path). Padded with a 2-byte-in-UTF-8 character ("é"), never plain ASCII:
# ASCII is 1 byte == 1 character, so an ASCII-only pad can't tell a correct
# `len(body.encode("utf-8"))` apart from a regressed `len(body)` — both would report the same
# number. This pad makes that regression fail loudly instead of passing by coincidence.
append_body_bytes_mutator() {
  cat <<PY
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]) / "skills/profile-repo/SKILL.md"
t = p.read_text(encoding="utf-8")
m = re.match(r'^---\n.*?\n---\n', t, re.S)
assert m, "no frontmatter delimiters found"
n = $1
pad = "é" * (n // 2) + ("X" * (n % 2))
assert len(pad.encode("utf-8")) == n, (len(pad.encode("utf-8")), n)
p.write_text(t + pad, encoding="utf-8")
PY
}

# run_body_delta_case <label> <skill> <bytes to append>
# Unlike run_desc_case (one fixed pattern), this reads the reported number back TWICE — once on
# the untouched baseline, once after appending exactly N bytes — and asserts the delta equals N
# exactly. A hardcoded absolute figure would go stale the next time <skill>'s SKILL.md is edited
# for an unrelated reason; the delta does not (see _shared/test-seams.md's rule against an
# expected value recomputed the same way the implementation computes it).
run_body_delta_case() {
  local label="$1" skill="$2" delta="$3"
  rm -rf "$ROOT/skills"
  cp -R "$PRISTINE/skills" "$ROOT/"
  local before after want
  # set +e around both reads: a body-size line that does not exist yet (pre-implementation, or a
  # genuine miss) makes the second `grep -oE` exit 1 with no match, and under this file's
  # `set -euo pipefail` an unguarded `before=$(... | grep ...)` would abort the WHOLE suite right
  # here instead of letting this one case report FAIL and continue — exactly the guard
  # `run_desc_case` already applies around its own fallible call.
  set +e
  before=$(python3 "$ROOT/tests/skills/check-frontmatter.py" 2>&1 \
    | grep -oE "  ${skill}: [0-9]+" | grep -oE '[0-9]+$')
  set -e
  if [ -z "$before" ]; then
    echo "FAIL: [$label] could not read a baseline body size for $skill"
    fails=$((fails + 1))
    return
  fi
  python3 -c "$(append_body_bytes_mutator "$delta")" "$ROOT"
  set +e
  after=$(python3 "$ROOT/tests/skills/check-frontmatter.py" 2>&1 \
    | grep -oE "  ${skill}: [0-9]+" | grep -oE '[0-9]+$')
  set -e
  if [ -z "$after" ]; then
    echo "FAIL: [$label] could not read the mutated body size for $skill"
    fails=$((fails + 1))
    return
  fi
  want=$((before + delta))
  if [ "$after" -eq "$want" ]; then
    echo "ok   [$label] $before -> $after (+$delta)"
  else
    echo "FAIL: [$label] expected $skill: $want, got $after (baseline was $before)"
    fails=$((fails + 1))
  fi
}

run_desc_case "B1 body-size block header appears, exit unchanged" 0 \
  'body sizes \(bytes, frontmatter excluded\):' 'import sys'
run_desc_case "B2 body-size total line appears                 " 0 \
  '  total: [0-9]+' 'import sys'
run_body_delta_case "B3 appending 100 bytes moves the reported number by exactly 100" \
  profile-repo 100

# ---------------------------------------------------------------------------------------------
# The trigger contract has one home now: evals/<skill>-trigger-eval.json (#331). check-frontmatter.py
# used to guard tests/skills/<skill>.triggers.md — a bullet list no tool ever read, whose presence CI
# certified while the eval sets it duplicated drifted away from it. The rule moved to the file
# `evals/run_all.py` actually runs, and these cases are the witness that it really refuses, BY NAME,
# each way a set can be malformed. Without them the block could narrow to "the file exists" and every
# run would stay green.
#
# Only evals/ is mutated here — run_case restores skills/, run_eval_case restores evals/ — so the two
# families never disturb each other, and the real tree is never touched either way.
echo "== the trigger contract in evals/*.json must be well-formed (#331) =="

# run_eval_case <label> <expect: pass|fail> <expected marker> <python mutator>
# The mutator receives the scratch root as argv[1] and edits evals/ in place.
run_eval_case() {
  local label="$1" expect="$2" marker="$3" mutator="$4"
  # BOTH trees, every case. evals/ is what these cases mutate, but skills/ carries whatever the
  # last run_case left behind — so an N4 labelled "untouched baseline" would be running against a
  # rewritten description, and inserting one more failing run_case above this block would turn
  # every T case into a coin flip.
  rm -rf "$ROOT/evals" "$ROOT/skills" "$ROOT/commands"
  cp -R "$PRISTINE/evals" "$PRISTINE/skills" "$PRISTINE/commands" "$ROOT/"
  python3 -c "$mutator" "$ROOT"
  local out rc
  set +e
  out=$(python3 "$ROOT/tests/skills/check-frontmatter.py" 2>&1)
  rc=$?
  set -e
  if [ "$expect" = fail ]; then
    if [ "$rc" -eq 0 ]; then
      echo "FAIL: [$label] expected a rejection, got exit 0"
      echo "      $out"
      fails=$((fails + 1))
    elif ! grep -q "$marker" <<<"$out"; then
      echo "FAIL: [$label] rejected, but not with '$marker'"
      echo "      $out"
      fails=$((fails + 1))
    else
      echo "ok   [$label] rejected"
    fi
  else
    if [ "$rc" -ne 0 ]; then
      echo "FAIL: [$label] expected acceptance, got exit $rc"
      echo "      $out"
      fails=$((fails + 1))
    else
      echo "ok   [$label] accepted"
    fi
  fi
}

run_eval_case "T1 the set is missing entirely    " fail "trigger eval set missing" '
import pathlib, sys
(pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json").unlink()
'

run_eval_case "T2 the set is not valid JSON      " fail "not valid JSON" '
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
# A trailing comma: the single most common hand-edit typo, and one a bare existence check accepts.
p.write_text("[\n  {\"query\": \"file an issue\", \"should_trigger\": true},\n]\n", encoding="utf-8")
'

run_eval_case "T3 every entry is a positive      " fail "no should_trigger: false entry" '
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
entries = json.loads(p.read_text(encoding="utf-8"))
for e in entries:
    e["should_trigger"] = True
p.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
'

run_eval_case "T3b every entry is a negative     " fail "no should_trigger: true entry" '
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
entries = json.loads(p.read_text(encoding="utf-8"))
for e in entries:
    e["should_trigger"] = False
p.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
'

run_eval_case "T4 an entry has no query          " fail "missing or empty .query." '
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
entries = json.loads(p.read_text(encoding="utf-8"))
entries[0].pop("query")
p.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
'

run_eval_case "T5 a query is duplicated          " fail "duplicate query" '
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
entries = json.loads(p.read_text(encoding="utf-8"))
# A duplicated positive inflates recall for free — the set scores better for saying less.
entries.append(dict(entries[0]))
p.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
'

run_eval_case "T6 an entry carries a stray key   " fail "unexpected key" '
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
entries = json.loads(p.read_text(encoding="utf-8"))
# "expect" is the boundary set schema, not this one: a copy-paste the runner would silently ignore.
entries[0]["expect"] = {"create-issue": True}
p.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
'

run_eval_case "T7 the set is an empty list       " fail "non-empty JSON list" '
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
p.write_text("[]\n", encoding="utf-8")
'

run_eval_case "T8 a skill drops out of SKILLS     " fail "must list every skill" '
import pathlib, re, sys
# A skill with a valid set that run_all.py never runs: CI reports the contract present, the bench
# silently measures nine of ten. That is the exact failure #331 closed, one edit away from coming back.
# The mutation locates the SKILLS block and drops its first quoted entry whatever the wrapping,
# order or quoting: a literal-substring replace went silently no-op the day the list was re-wrapped
# (#394), and this guard was then never exercised at all. The assert is what makes that loud.
p = pathlib.Path(sys.argv[1]) / "evals/run_all.py"
t = p.read_text(encoding="utf-8")
m = re.search(r"SKILLS\s*=\s*\[(.*?)\]", t, re.S)
assert m, "run_all.py has no SKILLS = [...] block"
block = re.sub(r"\"[^\"]+\",\s*", "", m.group(1), count=1)
assert block != m.group(1), "mutation had no effect (#394)"
p.write_text(t[:m.start(1)] + block + t[m.end(1):], encoding="utf-8")
'

run_eval_case "T9 DEFAULT_KNOWN names a non-skill" fail "must list every skill" '
import pathlib, re, sys
# A stale name in DEFAULT_KNOWN cannot be attributed to any sibling, so a near-miss histogram
# would report a skill that does not exist. Same format-agnostic mutation as T8 (#394).
p = pathlib.Path(sys.argv[1]) / "evals/trigger_eval.py"
t = p.read_text(encoding="utf-8")
m = re.search(r"DEFAULT_KNOWN\s*=\s*\[(.*?)\]", t, re.S)
assert m, "trigger_eval.py has no DEFAULT_KNOWN = [...] block"
block = m.group(1).rstrip().rstrip(",") + ", \"revise-claude-md\""
assert block != m.group(1), "mutation had no effect (#394)"
p.write_text(t[:m.start(1)] + block + t[m.end(1):], encoding="utf-8")
'

run_eval_case "T10 an entry has a non-string note" fail "non-string .note." '
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
entries = json.loads(p.read_text(encoding="utf-8"))
entries[0]["note"] = 42
p.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
'

run_eval_case "T11 a duplicate differs only in case" fail "duplicate query" '
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
entries = json.loads(p.read_text(encoding="utf-8"))
# One query asked twice, spelled differently: the bench cannot tell them apart, nor may the guard.
dup = dict(entries[0])
dup["query"] = "  " + dup["query"].upper() + " "
entries.append(dup)
p.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
'

run_eval_case "T12 a slash-command query          " fail "slash-command query" '
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
entries = json.loads(p.read_text(encoding="utf-8"))
# The four rows #436 deleted, in miniature. A client expands a slash command into the prompt; it
# is never a tool call, so trigger_eval.py has no intent to observe and the row is permanently
# red — three subprocess runs per revision to report a miss the harness caused itself.
entries.append({"query": "/create-issue", "should_trigger": True})
p.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
'

run_eval_case "C1 a command names no skill       " fail "names no skill" '
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "commands/migrate.md"
# The routing IS the naming: strip the skill name and the file still runs, handing the model a
# prompt with no destination. This is the assertion the deleted /migrate eval rows were reaching
# for, in the one place it can be settled without spending a bench run.
p.write_text(p.read_text(encoding="utf-8").replace("migrate-legacy", "the pipeline"), encoding="utf-8")
'

run_eval_case "E1 a result is stale vs its set  " fail "does not cover" '
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
# Exactly the drift #450 found: the set grows, the committed recall does not, and the
# published number silently stops covering the queries added under it.
p = root / "evals/create-issue-trigger-eval.json"
entries = json.loads(p.read_text(encoding="utf-8"))
entries.append({"query": "a query nobody has measured yet", "should_trigger": True})
p.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
'

run_eval_case "E2 a contract was never measured  " fail "never been measured" '
import pathlib, sys
# Deleting the result must NOT be the cheap way past S1 — absence fails for the same
# reason staleness does. Silence is not a verdict.
(pathlib.Path(sys.argv[1]) / "evals/results/create-issue.json").unlink()
'

run_eval_case "N4 untouched baseline             " pass "" 'import sys'

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
# ---------------------------------------------------------------------------
# run_all.py refuses to PUBLISH a result that measured nothing (#450).
#
# On 2026-09-05 a 5-runs-per-query sweep degraded partway through and reported recall
# 0.0 for six consecutive skills. Every one of them fired first try when probed by hand
# a minute later. The runner wrote all six to disk, overwrote baseline.json, and exited
# 0 — and evals/README.md had documented that exact fingerprint as a broken detector
# since #370. A predicate nothing drives is a predicate that stops working quietly, so
# the four shapes are pinned here: the two it must refuse, and the two it must not.
#
# PYTHONPATH, because run_all.py imports its sibling trigger_eval by bare name.
# ---------------------------------------------------------------------------
echo "== run_all.py refuses an unbelievable result (#450) =="
kit_source "$KIT_ROOT/tests/_lib/py.sh"
got=$(cd "$KIT_ROOT" && PYTHONPATH="$KIT_ROOT/evals" py_module "$KIT_ROOT/evals/run_all.py" <<'PY'
pos = [{"should_trigger": True}] * 10 + [{"should_trigger": False}] * 10

# 1. The poisoned shape: every positive missed, every negative passed.
assert mod.broken_detector({"recall": 0.0, "specificity": 1.0}, pos), "poisoned result accepted"
# 2. A starved run: more than a quarter of the queries never answered.
starved = [{"should_trigger": True, "timed_out": True}] * 6 + [{"should_trigger": True}] * 14
assert mod.broken_detector({"recall": 0.9, "specificity": 1.0}, starved), "starved run accepted"
# 3. A genuinely weak description is NOT refused — the guard must not eat real findings.
assert mod.broken_detector({"recall": 0.33, "specificity": 1.0}, pos) is None, "real low recall refused"
# 4. A set with no positives cannot have a recall to be suspicious about.
assert mod.broken_detector({"recall": 0.0, "specificity": 1.0},
                           [{"should_trigger": False}] * 5) is None, "all-negative set refused"
print("ok")
PY
)
[ "$got" = "ok" ] || { echo "FAIL: broken_detector did not behave as specified (got '$got')"; exit 1; }
echo "  ok: a 0.0-recall/1.0-specificity result and a starved run are refused; a real low recall is not"

echo "check-frontmatter golden test: all cases behaved as specified"

# ---------------------------------------------------------------------------------------------
# check-shared-refs.py (#266, generalized by #269) — the same ABSENCE-rule problem, in both
# directions, over every `skills/_shared/*.md` document that opts in with a `## Consumers`
# section — not just the untrusted-input boundary #266 first wrote it for.
#
# The real tree satisfies the guard by construction: every declaring document's consumers are all
# linked, none unlisted. So its pass path proves nothing on its own — narrow a pattern, mistype the
# marker, or drop the rule-4 glob and it keeps printing "OK" while enforcing less and less. These
# cases are the missing witness, one per refusal the checker claims to make.
#
# The reverse rule (UNLISTED LINKER) is the one that matters most here and the one no fixture-free
# run can ever exercise: it fires only when a file points at a declaring document WITHOUT being
# declared, which by definition never happens in a tree that is passing. Without case B3 it could
# stop matching entirely and every CI run would still be green.
#
# Each error marker gets its own case, driven against the boundary doc — its original and
# best-populated witness. B5/B6 used to be two more refusals (NO CONSUMERS SECTION / NO BOUNDARY
# FILE); #269's opt-in rule retires both as errors — see the comment above them.
#
# Cases S1/S2 are the multi-document behaviour #269 added: an undeclared `skills/_shared/*.md` is
# skipped rather than refused (the opt-in rule), and a SECOND declaring document is actually
# checked — under the pre-#269 single-document checker, S2's fixture would pass, since only the
# boundary was ever read.
echo "== every declaring shared reference must stay linked, in both directions (#266, #269) =="

# run_shared_refs_case <label> <expect: pass|fail> <expected marker> <forbidden marker|""> <mutator>
# Same shape as run_case: restore skills/ from $PRISTINE, mutate, run the checker over $ROOT.
# tests/ is NOT restored between cases — only skills/ is mutated, exactly as above.
run_shared_refs_case() {
  local label="$1" expect="$2" marker="$3" forbidden="$4" mutator="$5"
  rm -rf "$ROOT/skills"
  cp -R "$PRISTINE/skills" "$ROOT/"
  python3 -c "$mutator" "$ROOT"
  local out rc
  set +e
  out=$(python3 "$ROOT/tests/skills/check-shared-refs.py" 2>&1)
  rc=$?
  set -e
  if [ "$expect" = fail ]; then
    if [ "$rc" -eq 0 ]; then
      echo "FAIL: [$label] expected a rejection, got exit 0"
      echo "      $out"
      fails=$((fails + 1))
    elif ! grep -q "$marker" <<<"$out"; then
      echo "FAIL: [$label] rejected, but not with '$marker'"
      echo "      $out"
      fails=$((fails + 1))
    elif [ -n "$forbidden" ] && grep -q "$forbidden" <<<"$out"; then
      echo "FAIL: [$label] rejected with '$marker', but also emitted '$forbidden'"
      echo "      $out"
      fails=$((fails + 1))
    else
      echo "ok   [$label] rejected"
    fi
  else
    if [ "$rc" -ne 0 ]; then
      echo "FAIL: [$label] expected acceptance, got exit $rc"
      echo "      $out"
      fails=$((fails + 1))
    else
      echo "ok   [$label] accepted"
    fi
  fi
}

run_shared_refs_case "B1 consumer stops linking it      " fail "MISSING LINK:" "" '
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "skills/merge-pr/SKILL.md"
t = p.read_text(encoding="utf-8")
# Repoint every one of merge-pr’s links at a different shared reference — the realistic regression
# is a rewrite that keeps a link and loses this one, not a file that stops linking anything.
t = t.replace("](../_shared/untrusted-input-boundary.md)", "](../_shared/preconditions.md)")
p.write_text(t, encoding="utf-8")
'

run_shared_refs_case "B2 listed consumer disappears     " fail "NO SUCH CONSUMER:" "" '
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "skills/_shared/untrusted-input-boundary.md"
t = p.read_text(encoding="utf-8")
t = t.replace("- `skills/create-issue/SKILL.md`", "- `skills/create-issue/SKILL-renamed.md`")
p.write_text(t, encoding="utf-8")
'

run_shared_refs_case "B3 a file links it unlisted       " fail "UNLISTED LINKER:" "" '
import pathlib, sys
# A THROWAWAY file, deliberately not a real skill: any real one is a plausible next consumer, and
# a fixture that hard-codes "this file must never be declared" turns red the day someone correctly
# declares it — a red build caused by closing the very reach gap the boundary exists for.
# Deliberately OUTSIDE skills/_shared/: a plain skill-tree file, exactly the shape a real
# regression takes (a sibling skills/_shared/*.md file is NOT exempt from this rule — see the
# checker script docstring — but this fixture does not need to rely on that).
p = pathlib.Path(sys.argv[1]) / "skills/zz-unlisted-fixture.md"
p.write_text("Read it under [the boundary](./_shared/untrusted-input-boundary.md).\n", encoding="utf-8")
'

run_shared_refs_case "B4 a listed link is wrong-depth   " fail "BROKEN LINK:" "" '
import pathlib, sys
# The regression a substring test cannot see: every character of a correct link is present, and it
# resolves to skills/migrate-legacy/_shared/… — a path that does not exist. The reminder reads
# fine and is unreachable, which is the guard emptied of meaning while looking green.
p = pathlib.Path(sys.argv[1]) / "skills/migrate-legacy/references/phase-1-assess.md"
t = p.read_text(encoding="utf-8")
t = t.replace("](../../_shared/untrusted-input-boundary.md)", "](../_shared/untrusted-input-boundary.md)")
p.write_text(t, encoding="utf-8")
'

# B5 and B6 used to be FAIL cases (NO CONSUMERS SECTION / NO BOUNDARY FILE): the single-document
# checker treated the boundary as mandatory, so losing its section or the file itself was a hard
# refusal. #269's opt-in rule (S1 above) is universal — it does not carve out an exception for a
# document that HAD declared and stopped — so both mutations now make this document silently
# SKIPPED like any other undeclared one, never refused. That is a deliberate consequence of
# generalizing the mechanism, not a loosened guard: the design explicitly treats every
# skills/_shared/*.md document as equally optional-until-declared, the boundary included.
run_shared_refs_case "B5 the Consumers section is gone  " pass "" "" '
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]) / "skills/_shared/untrusted-input-boundary.md"
t = p.read_text(encoding="utf-8")
# Split on the HEADING LINE, not the string: the doc cross-references `## Consumers` inline in its
# own intro, and a plain split truncates the file there instead — mutating something other than
# what the case name claims, which is how a fixture quietly stops testing its branch.
p.write_text(re.split(r"(?m)^## Consumers\s*$", t, maxsplit=1)[0], encoding="utf-8")
'

run_shared_refs_case "B6 the boundary file is deleted   " pass "" "" '
import pathlib, sys
(pathlib.Path(sys.argv[1]) / "skills/_shared/untrusted-input-boundary.md").unlink()
'

run_shared_refs_case "B7 Consumers declared but empty   " fail "EMPTY CONSUMERS SECTION:" "" '
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]) / "skills/_shared/untrusted-input-boundary.md"
t = p.read_text(encoding="utf-8")
head = re.split(r"(?m)^## Consumers\s*$", t, maxsplit=1)[0]
p.write_text(head + "## Consumers\n\nNothing is declared here yet.\n", encoding="utf-8")
'

run_shared_refs_case "B8 a prose bullet is not a path   " pass "" "" '
import pathlib, sys
# The section is written for a human. A reflowed sentence must not become
# "NO SUCH CONSUMER: … lists (Anything)" — the checker verifies the claim, it does not dictate
# the punctuation the claim is written in.
p = pathlib.Path(sys.argv[1]) / "skills/_shared/untrusted-input-boundary.md"
t = p.read_text(encoding="utf-8")
p.write_text(t + "\n- Anything else that grows an ingest point belongs on this list.\n", encoding="utf-8")
'

run_shared_refs_case "B9 untouched baseline             " pass "" "" 'import sys'

run_shared_refs_case "S1 undeclared doc is skipped      " pass "" "" '
import pathlib, sys
# No ## Consumers section, and nothing links it — the opt-in rule (#269): a shared reference that
# has not declared its reach yet must never fail CI for existing, or adopting the section anywhere
# would train people to delete it rather than fill it in.
p = pathlib.Path(sys.argv[1]) / "skills/_shared/zz-fixture-ref.md"
p.write_text("# A fixture shared reference\n\nNo Consumers section, and nothing links it.\n", encoding="utf-8")
'

run_shared_refs_case "S2 a second declaring doc checked " fail "MISSING LINK:" "" '
import pathlib, sys
# Under the pre-#269, single-document checker this fixture PASSES — only the boundary was ever
# read. Declaring ## Consumers here must make this second document checked in its own right.
p = pathlib.Path(sys.argv[1]) / "skills/_shared/zz-fixture-ref.md"
p.write_text(
    "# A fixture shared reference\n\n"
    "## Consumers\n\n"
    "- `skills/merge-pr/SKILL.md` - a fixture entry naming a real file that never links back\n",
    encoding="utf-8")
'

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "check-shared-refs golden test: all cases behaved as specified"

# ---------------------------------------------------------------------------------------------
# skills/_shared/test-seams.md must exist and create-issue must link it (#310). The Spec
# contract's Testing decisions heading points a reader at this file for the seam doctrine
# (what a seam is, choosing seams before tests, mocking at boundaries only, the three
# anti-patterns) — if the file goes missing or the link erodes, the doctrine and the contract
# silently diverge. Pinned directly against the real tree (no scratch fixture): the defect this
# guards is the committed prose losing its link, not a checker's behavior under mutation.
echo "== create-issue must link skills/_shared/test-seams.md (#310) =="

if [ -f "$KIT_ROOT/skills/_shared/test-seams.md" ]; then
  echo "ok   [S1 skills/_shared/test-seams.md exists     ]"
else
  echo "FAIL: [S1 skills/_shared/test-seams.md exists     ] file is missing"
  fails=$((fails + 1))
fi

if grep -qF '](../_shared/test-seams.md)' "$KIT_ROOT/skills/create-issue/SKILL.md" 2>/dev/null; then
  echo "ok   [S2 create-issue/SKILL.md links it          ]"
else
  echo "FAIL: [S2 create-issue/SKILL.md links it          ] missing the literal '](../_shared/test-seams.md)'"
  fails=$((fails + 1))
fi

# issue-template.md lives one directory deeper than SKILL.md (skills/create-issue/references/,
# not skills/create-issue/), so its correct link climbs two levels, not one — this is exactly the
# shape of link a copy-paste from SKILL.md gets wrong.
if grep -qF '](../../_shared/test-seams.md)' "$KIT_ROOT/skills/create-issue/references/issue-template.md" 2>/dev/null; then
  echo "ok   [S3 issue-template.md links it (../../)     ]"
else
  echo "FAIL: [S3 issue-template.md links it (../../)     ] missing the literal '](../../_shared/test-seams.md)'"
  fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "test-seams link golden test: all cases behaved as specified"

# ---------------------------------------------------------------------------------------------
# skills/_shared/grilling.md must exist and create-issue must link it (#312). `--grill` is the one
# sanctioned exception to create-issue's hands-off autonomy contract, and the doctrine that makes it
# safe — one round, the frontier only, facts are the agent's job, unanswered takes the recommended
# answer — lives in the shared file rather than in the skill, because triage-backlog's confirmation
# pass is the second consumer. A `--grill` branch in SKILL.md with no link to that file is a flag
# whose contract nothing states, which is precisely how the two would drift apart. Pinned against
# the real tree for the same reason as the test-seams block above.
echo "== create-issue must link skills/_shared/grilling.md (#312) =="

if [ -f "$KIT_ROOT/skills/_shared/grilling.md" ]; then
  echo "ok   [G1 skills/_shared/grilling.md exists       ]"
else
  echo "FAIL: [G1 skills/_shared/grilling.md exists       ] file is missing"
  fails=$((fails + 1))
fi

if grep -qF '](../_shared/grilling.md)' "$KIT_ROOT/skills/create-issue/SKILL.md" 2>/dev/null; then
  echo "ok   [G2 create-issue/SKILL.md links it          ]"
else
  echo "FAIL: [G2 create-issue/SKILL.md links it          ] missing the literal '](../_shared/grilling.md)'"
  fails=$((fails + 1))
fi

# The port is MIT-licensed work by someone else; the credit line is part of the file's contract,
# not a courtesy that may erode in a later edit.
if grep -qF 'mattpocock/skills' "$KIT_ROOT/skills/_shared/grilling.md" 2>/dev/null; then
  echo "ok   [G3 grilling.md credits its source          ]"
else
  echo "FAIL: [G3 grilling.md credits its source          ] missing the 'mattpocock/skills' attribution"
  fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "grilling link golden test: all cases behaved as specified"

# ---------------------------------------------------------------------------------------------
# The brainstorm, plan and TDD doctrines the lifecycle skills used to invoke from the superpowers
# plugin live under skills/_shared/ now (#324) — one home each, ported from obra/superpowers (MIT)
# and narrowed to this kit's hands-off autonomy contract. A doctrine file nobody links is exactly
# as good as a plugin nobody installed, so each is pinned three ways: it exists, its consumers link
# it (the same literal-link shape as the test-seams and grilling blocks above), and the credit line
# survives — the port is someone else's MIT-licensed work and the attribution is part of the file's
# contract. The header note every filed plan carries is read out of plan-shape.md rather than
# re-spelled here, and the fixture the SP2 case below locates must carry that exact note.
echo "== the ported doctrine references exist, are linked, and credit their source (#324) =="

for ref in brainstorm-and-spec plan-shape tdd-loop; do
  if [ -f "$KIT_ROOT/skills/_shared/$ref.md" ]; then
    echo "ok   [DR1 skills/_shared/$ref.md exists]"
  else
    echo "FAIL: [DR1 skills/_shared/$ref.md exists] file is missing"
    fails=$((fails + 1))
  fi
  if grep -qF 'obra/superpowers' "$KIT_ROOT/skills/_shared/$ref.md" 2>/dev/null; then
    echo "ok   [DR2 _shared/$ref.md credits its source]"
  else
    echo "FAIL: [DR2 _shared/$ref.md credits its source] missing the 'obra/superpowers' attribution"
    fails=$((fails + 1))
  fi
done

for pair in "create-issue:brainstorm-and-spec" "create-issue:plan-shape" "implement-issue:plan-shape" "implement-issue:tdd-loop"; do
  skill="${pair%%:*}"; ref="${pair##*:}"
  if grep -qF "](../_shared/$ref.md)" "$KIT_ROOT/skills/$skill/SKILL.md" 2>/dev/null; then
    echo "ok   [DR3 $skill/SKILL.md links _shared/$ref.md]"
  else
    echo "FAIL: [DR3 $skill/SKILL.md links _shared/$ref.md] missing the literal '](../_shared/$ref.md)'"
    fails=$((fails + 1))
  fi
done

# #523: a lifecycle hand-off typed in the same session starts on top of everything the previous
# skill read, and every later turn re-reads it (measured: 156-320 turns, 192k-287k average context
# per session). recap.md's Next bullet is the one home every skill's recap carries (#324), so the
# fix is one sentence there: send the reader to a fresh session and name deliver-issue as the skill
# that already runs the rest of the chain that way.
NEXT_LINE=$(grep -m1 '^\*\*Next\*\*' "$KIT_ROOT/skills/_shared/recap.md" 2>/dev/null || true)
if [ -n "$NEXT_LINE" ] && grep -qF 'fresh session' <<<"$NEXT_LINE" && grep -qF '`deliver-issue`' <<<"$NEXT_LINE"; then
  echo "ok   [DR4 recap.md's Next line sends the hand-off to a fresh session (#523)]"
else
  echo "FAIL: [DR4 recap.md's Next line sends the hand-off to a fresh session (#523)] recap.md's Next line does not send the hand-off to a fresh session"
  fails=$((fails + 1))
fi

# #523 (Task 2): one context holds every task of a plan only when there is a single one to hold —
# implement-issue Step 3 stops calling a plan of up to three tasks "small, localized" and keeps
# inline for a single-task plan only; everything else runs subagent-per-task, which already
# explores once (the pointer-note recipe just above this bullet in the same step).
IMPLEMENT_PROSE=$(kit_skill_prose "$KIT_ROOT" implement-issue)
INLINE_LINE=$(grep -m1 -- '^- \*\*Inline' "$IMPLEMENT_PROSE" 2>/dev/null || true)
if [ -n "$INLINE_LINE" ] && grep -qF 'single-task' <<<"$INLINE_LINE" && ! grep -qF '≤3 tasks' <<<"$INLINE_LINE"; then
  echo "ok   [DR5 implement-issue Step 3 keeps inline only for a single-task plan (#523)]"
else
  echo "FAIL: [DR5 implement-issue Step 3 keeps inline only for a single-task plan (#523)] Step 3 still keeps a plan of up to three tasks inline"
  fails=$((fails + 1))
fi

# tdd-loop.md carries two ports: the loop from obra/superpowers (checked above) and the good-test
# and mock-at-boundaries guidance from mattpocock/skills, which earns its own credit line.
if grep -qF 'mattpocock/skills' "$KIT_ROOT/skills/_shared/tdd-loop.md" 2>/dev/null; then
  echo "ok   [DR2 _shared/tdd-loop.md credits mattpocock/skills too]"
else
  echo "FAIL: [DR2 _shared/tdd-loop.md credits mattpocock/skills too] missing the 'mattpocock/skills' attribution"
  fails=$((fails + 1))
fi

# The loop runs every suite through a log and reads only its tail (#499): a passing run's
# hundreds of `ok` lines are otherwise re-read on every later turn of the session.
if grep -qF -- '-test.log' "$KIT_ROOT/skills/_shared/tdd-loop.md" && grep -qF 'tail -n' "$KIT_ROOT/skills/_shared/tdd-loop.md"; then
  echo "ok   [DR3 _shared/tdd-loop.md runs suites through a log and tails it]"
else
  echo "FAIL: [DR3 _shared/tdd-loop.md runs suites through a log and tails it] missing the '-test.log' redirect or the 'tail -n' read (#499)"
  fails=$((fails + 1))
fi

# The header note has one home. plan-shape.md states it; create-issue cites it rather than carrying
# a second copy that can drift; and the new-note fixture SP2 locates is that exact line.
PLAN_NOTE=$(grep -m1 '^> \*\*For agentic workers:\*\*' "$KIT_ROOT/skills/_shared/plan-shape.md" 2>/dev/null || true)
if [ -z "$PLAN_NOTE" ]; then
  echo "FAIL: [DR4 plan-shape.md states the header note] no '> **For agentic workers:**' line"
  fails=$((fails + 1))
elif printf '%s' "$PLAN_NOTE" | grep -q 'superpowers\|SUB-SKILL'; then
  echo "FAIL: [DR4 plan-shape.md states the header note] the note still prescribes the plugin: $PLAN_NOTE"
  fails=$((fails + 1))
elif ! printf '%s' "$PLAN_NOTE" | grep -qF 'implement-issue'; then
  echo "FAIL: [DR4 plan-shape.md states the header note] the note does not name implement-issue as the executor: $PLAN_NOTE"
  fails=$((fails + 1))
elif ! grep -qFx -- "$PLAN_NOTE" "$KIT_ROOT/tests/skills/fixtures/plan-new-header-note.md"; then
  echo "FAIL: [DR4 plan-shape.md states the header note] fixtures/plan-new-header-note.md does not carry plan-shape.md's exact note"
  fails=$((fails + 1))
else
  echo "ok   [DR4 plan-shape.md states the header note, and the new-note fixture carries it]"
fi
if grep -q 'REQUIRED SUB-SKILL' "$KIT_ROOT/skills/create-issue/SKILL.md" "$KIT_ROOT/skills/create-issue/references/issue-template.md" 2>/dev/null; then
  echo "FAIL: [DR5 create-issue no longer writes the old header note] 'REQUIRED SUB-SKILL' still appears in create-issue"
  fails=$((fails + 1))
else
  echo "ok   [DR5 create-issue no longer writes the old header note]"
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "doctrine references golden test: all cases behaved as specified"

# ---------------------------------------------------------------------------------------------
# skills/_shared/prior-rejections.md must exist, and all THREE consumers must link it (#319). A
# prior rejection is an ADR with `status: rejected`; the lookup that consults it runs at every inlet
# (`create-issue` Step 3, `merge-pr` 6c) and the pass that judges the queue (`triage-backlog` Step
# 4), while the authoring half runs in `triage-backlog` Step 7 alone. That asymmetry — three readers,
# one writer — is exactly the kind of rule that gets restated slightly differently in each SKILL.md
# and then drifts, which is why it has one home and why a SKILL.md that stops pointing at that home
# is a failure rather than a style question.
#
# `filing-bar.md` is checked too, and for a stronger reason than the others: its clause 4 is a VETO
# over gates 1-3, and a veto whose lookup recipe is not linked is a rule an inlet cannot actually
# apply. Pinned against the real tree — the defect IS the committed prose.
echo "== the prior-rejection recipe has one home, and its four consumers link it (#319) =="

if [ -f "$KIT_ROOT/skills/_shared/prior-rejections.md" ]; then
  echo "ok   [PR1 prior-rejections.md exists          ]"
else
  echo "FAIL: [PR1 prior-rejections.md exists          ] file is missing"
  fails=$((fails + 1))
fi

for consumer in create-issue merge-pr triage-backlog; do
  if grep -qF '](../_shared/prior-rejections.md)' \
      "$KIT_ROOT/skills/$consumer/SKILL.md" 2>/dev/null; then
    printf 'ok   [PR2 %-14s SKILL.md links it    ]\n' "$consumer"
  else
    printf 'FAIL: [PR2 %-14s SKILL.md links it    ] missing the literal\n' "$consumer"
    echo "      '](../_shared/prior-rejections.md)'"
    fails=$((fails + 1))
  fi
done

# Same directory, so the link is `](./prior-rejections.md)` rather than `](../_shared/…)`.
if grep -qF '](./prior-rejections.md)' "$KIT_ROOT/skills/_shared/filing-bar.md" 2>/dev/null; then
  echo "ok   [PR3 filing-bar.md links the recipe      ]"
else
  echo "FAIL: [PR3 filing-bar.md links the recipe      ] clause 4 is a veto over gates 1-3; without"
  echo "      the literal '](./prior-rejections.md)' it names no way to apply it"
  fails=$((fails + 1))
fi

# The port is MIT-licensed work by someone else; the credit is part of the file's contract, not a
# courtesy a later edit may drop. Same rule as G3 above.
if grep -qF 'mattpocock/skills' "$KIT_ROOT/skills/_shared/prior-rejections.md" 2>/dev/null; then
  echo "ok   [PR4 prior-rejections.md credits source  ]"
else
  echo "FAIL: [PR4 prior-rejections.md credits source  ] missing the 'mattpocock/skills' attribution"
  fails=$((fails + 1))
fi

# The degraded path has to be NAMED, not merely implied. A recipe that describes only the semantic
# lookup reads as "no lookup happened" on every machine without the server, which is the one outcome
# the fallback exists to prevent — and the helper it names is the only shell surface under test.
if grep -qF 'rejected-adrs.sh' "$KIT_ROOT/skills/_shared/prior-rejections.md" 2>/dev/null; then
  echo "ok   [PR5 the recipe names its fallback       ]"
else
  echo "FAIL: [PR5 the recipe names its fallback       ] missing 'rejected-adrs.sh' — without the"
  echo "      fallback named, a reader with no AdrMcp has nothing to run"
  fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "prior-rejection link golden test: all cases behaved as specified"

# ---------------------------------------------------------------------------------------------
# The decompose branch (#315) hangs off two references — the parent's tracking-body shape and
# the slicing rules — and create-issue must link both. The parent-body invariant they carry (no
# `Implementation plan`, no `### Task`, no `- [ ]`) is what keeps survey.sh's `haveplan` false so
# a tracking parent is never dispatched; a SKILL.md that stops linking the file stating it is a
# branch whose contract nothing states. Pinned against the real tree, same as the blocks above.
echo "== create-issue must link its decomposition references (#315) =="

for ref in tracking-issue decomposition; do
  if [ -f "$KIT_ROOT/skills/create-issue/references/$ref.md" ]; then
    echo "ok   [D1 references/$ref.md exists]"
  else
    echo "FAIL: [D1 references/$ref.md exists] file is missing"
    fails=$((fails + 1))
  fi
  if grep -qF "](references/$ref.md)" "$KIT_ROOT/skills/create-issue/SKILL.md" 2>/dev/null; then
    echo "ok   [D2 create-issue/SKILL.md links references/$ref.md]"
  else
    echo "FAIL: [D2 create-issue/SKILL.md links references/$ref.md] missing the literal '](references/$ref.md)'"
    fails=$((fails + 1))
  fi
  # The port is MIT-licensed work by someone else; the credit line is part of each file's contract.
  if grep -qF 'mattpocock/skills' "$KIT_ROOT/skills/create-issue/references/$ref.md" 2>/dev/null; then
    echo "ok   [D3 references/$ref.md credits its source]"
  else
    echo "FAIL: [D3 references/$ref.md credits its source] missing the 'mattpocock/skills' attribution"
    fails=$((fails + 1))
  fi
done

# triage-backlog's rescope emits the same parent + children shape, so it links the parent shape too.
if grep -qF '](../create-issue/references/tracking-issue.md)' "$KIT_ROOT/skills/triage-backlog/SKILL.md" 2>/dev/null; then
  echo "ok   [D4 triage-backlog/SKILL.md links tracking-issue.md]"
else
  echo "FAIL: [D4 triage-backlog/SKILL.md links tracking-issue.md] missing the literal '](../create-issue/references/tracking-issue.md)'"
  fails=$((fails + 1))
fi

# The shape the reference documents is the one survey.sh reads: its example parent body must
# itself carry none of the three plan tokens, or the reference teaches the wrong invariant.
if [ -f "$KIT_ROOT/skills/create-issue/references/tracking-issue.md" ]; then
  # Herestring, not a pipe into `grep -q` (#391): `sed` can still be writing when the match
  # closes the read end.
  fenced=$(sed -n '/^```markdown$/,/^```$/p' "$KIT_ROOT/skills/create-issue/references/tracking-issue.md")
  if grep -qE 'Implementation plan|### Task|- \[ \]' <<<"$fenced"; then
    echo "FAIL: [D5 tracking-issue.md's example body carries a plan token] a fenced example contains 'Implementation plan', '### Task' or '- [ ]'"
    fails=$((fails + 1))
  else
    echo "ok   [D5 tracking-issue.md's example bodies carry no plan token]"
  fi
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "decomposition references golden test: all cases behaved as specified"

# ---------------------------------------------------------------------------------------------
# The main-worktree derivation has one home now (#125): scripts/main-worktree.sh. Two broken
# spellings kept getting re-introduced before that — a caller resolving `-C` from
# `git rev-parse --show-toplevel` right next to a worktrees-ignored.sh call (fails OPEN from a
# linked worktree, tests/worktrees-ignored/test.sh case 22) and an `awk '{p=$2}'` listing that
# truncates a checkout under a path containing a space. This is the anti-recurrence guard: it
# scans the real skills/ tree, not a scratch copy, because the defect IS the committed prose and
# scripts, not something a fixture could stand in for.
#
# Proximity, not "the file mentions both": skills/profile-repo/scripts/repo-profile.sh
# legitimately carries an UNRELATED `rev-parse --show-toplevel` (line ~30, resolving the profile
# PATH argument — out of scope for #125, see the issue's own Assumptions) alongside four
# worktrees-ignored.sh mentions dozens of lines away. A whole-file substring check would flag that
# file forever; only a call sitting near a guard invocation is the actual bug.
echo "== the main-worktree derivation is not re-spelled (#125) =="
python3 - "$KIT_ROOT/skills" <<'PY'
import sys, pathlib

root = pathlib.Path(sys.argv[1])
REV_PARSE = "rev-parse --show-toplevel"
GUARD = "worktrees-ignored.sh"
AWK_BAD = "{p=$2}"
WINDOW = 5  # lines

failures = []
for path in sorted(root.rglob("*")):
    if not path.is_file():
        continue
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (UnicodeDecodeError, OSError):
        continue

    # Comment lines are explanatory prose, not re-introduced code — repo-profile.sh's own fix
    # comment says "this replaces `git rev-parse --show-toplevel`" a few lines above the guard
    # call it replaced it with, and that sentence is the point, not a regression.
    code_lines = [(i, l) for i, l in enumerate(lines) if not l.lstrip().startswith("#")]
    rev_lines = [i for i, l in code_lines if REV_PARSE in l]
    guard_lines = [i for i, l in code_lines if GUARD in l]
    for r in rev_lines:
        for g in guard_lines:
            if abs(r - g) <= WINDOW:
                failures.append(
                    "%s: '%s' (line %d) sits next to a '%s' call (line %d) — "
                    "resolve the main checkout via scripts/main-worktree.sh instead (#125)"
                    % (path, REV_PARSE, r + 1, GUARD, g + 1)
                )
                break

    for i, l in enumerate(lines):
        if AWK_BAD in l and "worktree" in l:
            failures.append(
                "%s:%d: the truncating awk spelling ('{p=$2}') is back — a path containing a "
                "space would be cut at the first space (#125)" % (path, i + 1)
            )

if failures:
    print("FAIL: the main-worktree derivation was re-spelled:")
    for f in failures:
        print("  " + f)
    sys.exit(1)
print("ok   no file under skills/ re-spells the main-worktree derivation")
PY
# ---------------------------------------------------------------------------------------------
# The `claude -p` worker substrate is gone (#314, the v2.0 breaking change): auto-dev dispatches
# every worker as an in-process background sub-agent through the Agent tool, and a sub-agent has
# no `--strict-mcp-config` flag and no process to die. Any file that still names either is stale
# doctrine a supervisor would follow — it scans the real tree, not a scratch copy, because the
# defect IS the committed prose. `evals/` legitimately keeps `claude -p` (it drives the eval
# harness, not a worker) and is deliberately outside the scope below.
echo "== no auto-dev file names the claude -p worker substrate (#314) =="
SUBSTRATE_HITS=$(grep -rn 'claude -p\|--strict-mcp-config' \
  "$KIT_ROOT/skills/auto-dev" \
  "$KIT_ROOT/commands/auto-dev-worker.md" \
  "$KIT_ROOT/commands/auto-dev-merge.md" \
  "$KIT_ROOT/skills/_shared/untrusted-input-boundary.md" || true)
if [ -n "$SUBSTRATE_HITS" ]; then
  echo "FAIL: the claude -p / --strict-mcp-config worker substrate is named again (#314):"
  echo "$SUBSTRATE_HITS" | sed 's/^/  /'
  exit 1
fi
echo "ok   no auto-dev file names claude -p or --strict-mcp-config"

# ---------------------------------------------------------------------------------------------
# The lifecycle skills no longer depend on the third-party superpowers plugin (#324): the
# brainstorm, plan and TDD doctrines they used to invoke live under skills/_shared/, and an
# `Invoke superpowers:X` line on a machine without the plugin degrades silently — the Skill tool
# has no such name, and the agent improvises whatever shape it likes. So the colon-invocation form
# is refused anywhere a session actually reads: skills/ and commands/. The bare word is still
# allowed — debug-issue's compatibility credit ("ported from the superpowers skill") and
# docs/superpowers/ (historical plans, a directory name) are attribution and history, not
# invocations. Scans the real tree, not a scratch copy: the defect IS the committed prose.
echo "== no shipped skill or command invokes a superpowers: skill (#324) =="
SUPERPOWERS_HITS=$(grep -rn 'superpowers:' "$KIT_ROOT/skills" "$KIT_ROOT/commands" || true)
if [ -n "$SUPERPOWERS_HITS" ]; then
  echo "FAIL: [SP1 no superpowers: invocation in skills/ or commands/] the plugin is named again (#324):"
  echo "$SUPERPOWERS_HITS" | sed 's/^/  /'
  fails=$((fails + 1))
else
  echo "ok   [SP1 no superpowers: invocation in skills/ or commands/]"
fi

# The header note every filed plan carries changed with #324, and every issue filed before it still
# carries the old one. implement-issue keeps executing both because its Step 2 locator anchors on
# the `🛠️ Implementation plan` heading, never on the note — this case pins that: the anchor is
# read out of the recipe itself (a re-spelling here would pass while the recipe drifted), it must
# not name the plugin, and it must hit a fixture of each note with the same task count.
echo "== implement-issue locates a plan under either header note (#324) =="
MECH="$KIT_ROOT/skills/implement-issue/references/github-mechanics.md"
RECIPE_LINE_RE="grep -q '[^']*' /tmp/plan-\$ISSUE.md"   # tmp-lint:allow — the recipe's own text being matched, not a path this suite writes
PLAN_ANCHOR=$(grep -o "$RECIPE_LINE_RE" "$MECH" | head -1 | sed "s/^grep -q '\(.*\)' .*$/\1/")
if [ -z "$PLAN_ANCHOR" ]; then
  echo "FAIL: [SP2 the §2 locator anchor is readable          ] no \"grep -q '…' <plan file>\" line in $MECH"
  fails=$((fails + 1))
elif printf '%s' "$PLAN_ANCHOR" | grep -qi 'superpowers\|SUB-SKILL\|agentic workers'; then
  echo "FAIL: [SP2 the §2 locator anchor is readable          ] anchors on the header note ('$PLAN_ANCHOR'), not the heading"
  fails=$((fails + 1))
else
  echo "ok   [SP2 the §2 locator anchor is readable          ] '$PLAN_ANCHOR'"
  for note in old new; do
    FIXTURE="$KIT_ROOT/tests/skills/fixtures/plan-$note-header-note.md"
    if ! grep -qF -- "$PLAN_ANCHOR" "$FIXTURE"; then
      echo "FAIL: [SP2 $note header note is located             ] anchor '$PLAN_ANCHOR' misses $FIXTURE"
      fails=$((fails + 1))
    elif [ "$(grep -c '^### Task ' "$FIXTURE")" -ne 2 ]; then
      echo "FAIL: [SP2 $note header note is located             ] expected 2 '### Task' blocks in $FIXTURE, got $(grep -c '^### Task ' "$FIXTURE")"
      fails=$((fails + 1))
    else
      echo "ok   [SP2 $note header note is located             ] anchor hit, 2 '### Task' blocks in the fixture"
    fi
  done
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "superpowers-independence golden test: all cases behaved as specified"

# ---------------------------------------------------------------------------------------------
# CONTEXT.md (#313) — the kit's own domain glossary, in Matt Pocock's format (ported from
# mattpocock/skills, MIT). This is a structural case, not a content one: it proves the file
# stays in shape (a term section before the ambiguities section, every term actually defined,
# "decision" still flagged rather than quietly resolved by a rename) without pinning the prose
# itself, which is free to grow. It runs over the real committed file for the same reason the
# #125 scan above does — the defect this guards against is the committed file drifting out of
# its own format, not something a fixture could stand in for.
echo "== CONTEXT.md stays in Matt Pocock's format, with decision flagged (#313) =="
python3 - "$KIT_ROOT" <<'PY'
import re
import sys
import pathlib

root = pathlib.Path(sys.argv[1])
path = root / "CONTEXT.md"
if not path.is_file():
    print("FAIL: CONTEXT.md missing at the kit root")
    sys.exit(1)

lines = path.read_text(encoding="utf-8").splitlines()

# At least one `## ` section heading must precede `## Flagged ambiguities`.
amb_idx = next((i for i, l in enumerate(lines) if l.startswith("## Flagged ambiguities")), None)
if amb_idx is None:
    print("FAIL: CONTEXT.md has no '## Flagged ambiguities' section")
    sys.exit(1)
section_headings_before = [l for l in lines[:amb_idx] if l.startswith("## ")]
if not section_headings_before:
    print("FAIL: CONTEXT.md has no '## ' term section before '## Flagged ambiguities'")
    sys.exit(1)

# Every "**Term**:" line must be followed by a non-empty definition line — skipping over at most
# one blank line, since a term header, blank line, definition is still a valid layout.
term_re = re.compile(r"^\*\*[^*]+\*\*:\s*$")
for i, l in enumerate(lines):
    if term_re.match(l):
        j = i + 1
        if j < len(lines) and not lines[j].strip():
            j += 1
        nxt = lines[j] if j < len(lines) else ""
        if not nxt.strip() or term_re.match(nxt):
            print("FAIL: CONTEXT.md line %d ('%s') has no definition on the next line" % (i + 1, l))
            sys.exit(1)

# The ambiguities section must still name "decision" and its registry home, not resolve it away.
amb_text = "\n".join(lines[amb_idx:])
if "decision" not in amb_text:
    print("FAIL: CONTEXT.md's '## Flagged ambiguities' section does not mention \"decision\"")
    sys.exit(1)
if "docs/decisions.md" not in amb_text:
    print("FAIL: CONTEXT.md's '## Flagged ambiguities' section does not name docs/decisions.md")
    sys.exit(1)

print("ok   CONTEXT.md has term sections, defined terms, and decision flagged")
PY

# The two naming consumers must point at the target repo's CONTEXT.md, and say what they refuse.
echo "== create-issue and implement-issue read the target repo's CONTEXT.md (#313) =="
for consumer in create-issue implement-issue; do
  prose="$(kit_skill_prose "$KIT_ROOT" "$consumer")"   # router + references/steps/*.md (#499)
  grep -q "CONTEXT.md" "$prose" || { echo "FAIL: $consumer does not mention CONTEXT.md"; exit 1; }
  grep -q "_Avoid_" "$prose" || { echo "FAIL: $consumer does not mention _Avoid_"; exit 1; }
done
echo "ok   create-issue and implement-issue both point at CONTEXT.md and its _Avoid_ lists"

# The map must know where the language lives.
echo "== ARCHITECTURE.md and README.md point at CONTEXT.md (#313) =="
for doc in ARCHITECTURE.md README.md; do
  grep -q "CONTEXT.md" "$doc" || { echo "FAIL: $doc does not mention CONTEXT.md"; exit 1; }
done
echo "ok   ARCHITECTURE.md and README.md both mention CONTEXT.md"

# ---------------------------------------------------------------------------------------------
# preconditions.md refuses a tracker this skill cannot run against (#311, #505). Fixture-free: this
# is a grep against the committed reference itself, not a probe run against a scratch repo — the
# probe/profile side of the Tracker line is pinned by tests/repo-profile/test.sh.
#
# #505 MOVED THE MECHANISM, so this pin moved with it. The refusal used to be a sentence the agent
# applied by hand ("`<host>` is not a supported tracker"); it is now the registered decision
# `tracker.capable`, which Step 1 asks through `decide.sh` and which answers `capable` for every
# skill on GitHub. The greps below are deliberately STRICTER than the one sentence they replace:
# naming a decision without invoking it is prose that decides nothing — precisely the drift
# `scripts/decision-check.py` R7 refuses — so the invocation is pinned separately from the refusal.
# Keep both. Dropping the invocation grep would let the refusal go decorative again, which is the
# failure #311 was filed for in the first place.
echo "== preconditions refuse a tracker the skill cannot run against (#311, #505) =="
PRECONDITIONS="$KIT_ROOT/skills/_shared/preconditions.md"
[ -f "$PRECONDITIONS" ] || { echo "FAIL: $PRECONDITIONS missing"; exit 1; }
grep -q 'Tracker' "$PRECONDITIONS" \
  || { echo "FAIL: $PRECONDITIONS does not mention the profile's Tracker line"; exit 1; }
grep -q 'decide.sh tracker.capable' "$PRECONDITIONS" \
  || { echo "FAIL: $PRECONDITIONS does not INVOKE tracker.capable — a named decision that is never run decides nothing"; exit 1; }
grep -q 'Proceed only on' "$PRECONDITIONS" \
  || { echo "FAIL: $PRECONDITIONS does not refuse a verdict other than capable"; exit 1; }
echo "ok   preconditions names Tracker, invokes tracker.capable and refuses a non-capable verdict"

# ---------------------------------------------------------------------------------------------
# create-issue's Inputs states the flag-position rule (#404): a flag is a standalone token at the
# start or end of the request, never a word inside the idea's own sentence — otherwise an
# unattended caller (merge-pr Step 6, the auto-dev workers, deliver-issue) that hands it an idea
# quoting "--grill" or "--seed #40" in prose reads that word as the flag. Driven to red on a
# scratch copy with the sentence stripped, so the check cannot pass vacuously.
echo "== create-issue's Inputs states the flag-position rule (#404) =="
CREATE_ISSUE_SKILL="$KIT_ROOT/skills/create-issue/SKILL.md"
[ -f "$CREATE_ISSUE_SKILL" ] || { echo "FAIL: $CREATE_ISSUE_SKILL missing"; exit 1; }

check_flag_position_rule() {
  # $1: a create-issue SKILL.md to check. Prints a message naming create-issue and returns
  # non-zero when the standalone-token rule is missing.
  if ! grep -qi 'a flag is a standalone token' "$1"; then
    echo "FAIL: create-issue's Inputs section does not state the flag-position rule"
    return 1
  fi
}

check_flag_position_rule "$CREATE_ISSUE_SKILL" || exit 1
echo "ok   create-issue states the flag-position rule"

_fpscratch=$(kit_scratch)
sed '/[Aa] flag is a standalone token/d' "$CREATE_ISSUE_SKILL" > "$_fpscratch/SKILL.md"
if fp_out=$(check_flag_position_rule "$_fpscratch/SKILL.md" 2>&1); then
  echo "FAIL: the flag-position check accepted a SKILL.md with the rule stripped"; exit 1
fi
grep -q 'create-issue' <<<"$fp_out" \
  || { echo "FAIL: the flag-position check refused the scratch copy without naming create-issue"; exit 1; }
echo "ok   a create-issue SKILL.md without the flag-position rule is refused, by name"

# ---------------------------------------------------------------------------------------------
# The roseline-gate essay moved to docs/roseline-gate.md (#325). Fixture-free: the defect this
# guards is the committed essay drifting away from its own four properties, or the README's link
# to it eroding, not something a scratch fixture could stand in for.
echo "== docs/roseline-gate.md carries the roseline-gate essay, linked from README (#325) =="
python3 - "$KIT_ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
path = root / "docs" / "roseline-gate.md"
if not path.is_file():
    print("FAIL: docs/roseline-gate.md missing")
    sys.exit(1)

text = path.read_text(encoding="utf-8")
for phrase in (
    "Inert outside C# projects",
    "A one-shot escape",
    "Fails open, always",
    "never enforces a tool that cannot be there",
):
    if phrase not in text:
        print("FAIL: docs/roseline-gate.md is missing the phrase %r" % phrase)
        sys.exit(1)

readme = (root / "README.md").read_text(encoding="utf-8")
if "docs/roseline-gate.md" not in readme:
    print("FAIL: README.md does not link docs/roseline-gate.md")
    sys.exit(1)

print("ok   docs/roseline-gate.md carries the four properties, and README links it")
PY

# ---------------------------------------------------------------------------------------------
# README leads with the failure modes and a "Which command?" table, and links every skill and
# command (#325). Fixture-free, same reason as the #313 CONTEXT.md case above: the defect is the
# committed README drifting out of shape, not something a scratch fixture models better.
echo "== README leads with failure modes, routes by situation, links every skill/command (#325) =="
python3 - "$KIT_ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
readme = (root / "README.md").read_text(encoding="utf-8")

for heading in ("## Why this kit exists", "## Which command?"):
    if heading not in readme:
        print("FAIL: README.md is missing the heading %r" % heading)
        sys.exit(1)

targets = set(re.findall(r"\]\(([^)]+)\)", readme))

missing = []
for skill_dir in sorted((root / "skills").iterdir()):
    if not skill_dir.is_dir() or skill_dir.name == "_shared":
        continue
    rel = "skills/%s/SKILL.md" % skill_dir.name
    if not (root / rel).is_file():
        continue
    if rel not in targets:
        missing.append(rel)

for cmd in sorted((root / "commands").glob("*.md")):
    rel = "commands/%s" % cmd.name
    if rel not in targets:
        missing.append(rel)

if missing:
    print("FAIL: README.md does not link: %s" % ", ".join(missing))
    sys.exit(1)

print("ok   README.md links every skills/*/SKILL.md and commands/*.md")
PY

# ------------------------------------------------------------------------------------------------
# The methodology guide names every skill and every command (#398). docs/methodology.md is the one
# document that reads the kit end to end; a skill added without a place in it is the README-links
# failure one level up — the guard walks the same directories that case does and greps the guide.
# Driven to red on a scratch copy of the tree with an extra skill folder, so the guard cannot go
# silent by matching nothing.
echo "== docs/methodology.md names every skill and command (#398) =="
# ONE check, written to a file and run twice — on the real tree (must pass) and on a scratch tree
# with an unnamed skills/zz-fake/ (must fail, and must NAME zz-fake). A second inline copy of the
# check would prove the copy, not the case; the red half is the guard that proves the guard.
_gscratch=$(kit_scratch)
cat > "$_gscratch/guide-check.py" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
guide = root / "docs/methodology.md"
if not guide.exists():
    print("FAIL: docs/methodology.md is missing"); sys.exit(1)
text = guide.read_text(encoding="utf-8")
missing = []
for d in sorted(p for p in (root / "skills").iterdir() if p.is_dir() and p.name != "_shared"):
    if d.name not in text:
        missing.append("skills/" + d.name)
for f in sorted((root / "commands").glob("*.md")):
    if f.stem not in text:
        missing.append("commands/" + f.name)
if missing:
    print("FAIL: docs/methodology.md never names: " + ", ".join(missing)); sys.exit(1)
print("ok   docs/methodology.md names every skill folder and every command")
PY
python3 "$_gscratch/guide-check.py" "$KIT_ROOT" || exit 1
mkdir -p "$_gscratch/tree/skills/zz-fake" "$_gscratch/tree/commands" "$_gscratch/tree/docs"
cp "$KIT_ROOT/docs/methodology.md" "$_gscratch/tree/docs/"
cp -R "$KIT_ROOT/skills/debug-issue" "$_gscratch/tree/skills/"
: > "$_gscratch/tree/skills/zz-fake/SKILL.md"
if python3 "$_gscratch/guide-check.py" "$_gscratch/tree" > "$_gscratch/guide-red.out" 2>&1; then
  echo "FAIL: the guide-coverage check accepted a tree with skills/zz-fake/ unnamed"; exit 1
fi
grep -q 'skills/zz-fake' "$_gscratch/guide-red.out" \
  || { echo "FAIL: the guide-coverage check refused the scratch tree without naming skills/zz-fake"; cat "$_gscratch/guide-red.out"; exit 1; }
echo "ok   a skill folder the guide does not name is refused, by name"

# ------------------------------------------------------------------------------------------------
# docs/ is the GitHub Pages site (#401), built by Pages' native Jekyll from the site's OWN layouts
# under docs/_layouts (the just-the-docs remote theme was dropped with the redesign): the config
# parses and names no remote theme, pins the mermaid version the scripts include reads, keeps a
# path-only exclude list; the landing page exists and links the guide, the Install page and the
# journal; every page the config does not exclude carries a `title:` — a page without one drops out
# of the navigation silently. Driven to red on scratch copies, one file broken the way its check
# exists to catch, refused by name, so no check can pass vacuously.
echo "== docs/ is a Pages site: config parses, layouts exist, index links the guide, every page is titled (#401) =="
_pscratch=$(kit_scratch)
cat > "$_pscratch/pages-check.py" <<'PY'
import html, pathlib, re, sys, yaml
root = pathlib.Path(sys.argv[1]); docs = root / "docs"
cfg_path = docs / "_config.yml"
if not cfg_path.exists():
    print("FAIL: docs/_config.yml is missing"); sys.exit(1)
cfg = yaml.safe_load(cfg_path.read_text(encoding="utf-8")) or {}
if cfg.get("remote_theme") or cfg.get("theme"):
    print("FAIL: docs/_config.yml names a theme (" + str(cfg.get("remote_theme") or cfg.get("theme")) + ") — the site ships its own layouts under docs/_layouts since the redesign"); sys.exit(1)
if not (isinstance(cfg.get("mermaid"), dict) and cfg["mermaid"].get("version")):
    print("FAIL: docs/_config.yml does not pin mermaid.version"); sys.exit(1)
# baseurl is spelled once more, independently, as the homepage in .github/repo-setup.yml: a Pages
# site whose baseurl disagrees with its published URL 404s every stylesheet and internal link with
# nothing red (#611's verification review) — pin the two together on the one literal
# tests/repo-setup/test.sh already reads.
manifest = root / ".github" / "repo-setup.yml"   # the fixture worlds below carry no manifest: only the real root is pinned
home = (yaml.safe_load(manifest.read_text(encoding="utf-8")) or {}).get("settings", {}).get("homepage", "") if manifest.exists() else ""
want = "/" + home.rstrip("/").rsplit("/", 1)[-1]
if home and cfg.get("baseurl") != want:
    print("FAIL: docs/_config.yml baseurl is " + repr(cfg.get("baseurl")) + " but .github/repo-setup.yml homepage " + repr(home) + " implies " + repr(want)); sys.exit(1)
# The layouts the defaults assign must exist, and the base layout must include the head, the top bar,
# the footer and the scripts — the four includes every page stands on.
layouts = docs / "_layouts"
for name in ("default", "home", "doc", "adr", "journal", "journal-index"):
    if not (layouts / (name + ".html")).exists():
        print("FAIL: docs/_layouts/" + name + ".html is missing"); sys.exit(1)
assigned = {v.get("values", {}).get("layout") for v in cfg.get("defaults", []) if isinstance(v, dict)}
for lay in sorted(l for l in assigned if l):
    if not (layouts / (lay + ".html")).exists():
        print("FAIL: docs/_config.yml assigns layout '" + lay + "' but docs/_layouts/" + lay + ".html does not exist — the Pages build would fail"); sys.exit(1)
base = (layouts / "default.html").read_text(encoding="utf-8")
for inc in ("head.html", "topbar.html", "footer.html", "scripts.html"):
    if ("include " + inc) not in base:
        print("FAIL: docs/_layouts/default.html does not include " + inc); sys.exit(1)
    if not (docs / "_includes" / inc).exists():
        print("FAIL: docs/_includes/" + inc + " is missing"); sys.exit(1)
scripts = (docs / "_includes" / "scripts.html").read_text(encoding="utf-8")
if "site.mermaid.version" not in scripts or "language-mermaid" not in scripts:
    print("FAIL: docs/_includes/scripts.html must load mermaid at site.mermaid.version and lift language-mermaid fences"); sys.exit(1)
index = docs / "index.md"
if not index.exists():
    print("FAIL: docs/index.md is missing"); sys.exit(1)
itext = index.read_text(encoding="utf-8")
if not re.search(r"^title:", itext, re.M) or "nav_order: 1" not in itext or "](methodology.md)" not in itext:
    print("FAIL: docs/index.md must carry title:, nav_order: 1 and link methodology.md"); sys.exit(1)
if re.search(r"\]\([^)]*\.html\)", itext):
    print("FAIL: docs/index.md links .html pages — link the .md source, which renders on GitHub and on Pages"); sys.exit(1)
globs = [e for e in cfg.get("exclude", []) if any(ch in e for ch in "*?[")]
if globs:
    print("FAIL: docs/_config.yml excludes by glob (" + ", ".join(globs) + ") — Jekyll 3 applies exclude to the layouts too, so a bare glob unpublishes every layout; name the file by path"); sys.exit(1)
excluded = [e.rstrip("/") for e in cfg.get("exclude", [])]
untitled = []
for p in sorted(docs.rglob("*.md")):
    rel = p.relative_to(docs).as_posix()
    if any(rel == e or rel.startswith(e + "/") for e in excluded):
        continue
    head = p.read_text(encoding="utf-8")[:2000]
    m = re.match(r"\A---\n(.*?)\n---\n", head, re.S)
    if not m or not re.search(r"^title:\s*\S", m.group(1), re.M):
        untitled.append(rel)
if untitled:
    print("FAIL: docs/ pages without a title: in their front matter: " + ", ".join(untitled)); sys.exit(1)
# The stylesheet the head links is the one Pages builds from docs/_sass/kit/: every partial the
# entry imports must exist, or the Sass step fails and the whole site ships unstyled.
entry = docs / "assets" / "css" / "site.scss"
if not entry.exists():
    print("FAIL: docs/assets/css/site.scss is missing"); sys.exit(1)
for part in re.findall(r'@import\s+"([^"]+)"', entry.read_text(encoding="utf-8")):
    d, _, n = part.rpartition("/")
    if not (docs / "_sass" / d / ("_" + n + ".scss")).exists():
        print("FAIL: docs/assets/css/site.scss imports " + part + " but docs/_sass/" + d + "/_" + n + ".scss does not exist — the Pages build would fail"); sys.exit(1)
head = (docs / "_includes" / "head.html").read_text(encoding="utf-8")
if "assets/css/site.css" not in head:
    print("FAIL: docs/_includes/head.html does not link assets/css/site.css"); sys.exit(1)
# The dark scheme (#527, kept through the redesign) is switchable end to end: the head restores the
# stored choice before first paint, the top bar carries the toggle, the script flips it, and the
# stylesheet answers both the attribute and prefers-color-scheme (the no-JavaScript path).
topbar = (docs / "_includes" / "topbar.html").read_text(encoding="utf-8")
sitejs = docs / "assets" / "js" / "site.js"
if "data-kit-scheme" not in head or "kit-scheme" not in head:
    print("FAIL: docs/_includes/head.html does not restore the stored scheme onto data-kit-scheme before first paint"); sys.exit(1)
if 'class="kit-scheme-toggle"' not in topbar:
    print("FAIL: docs/_includes/topbar.html carries no kit-scheme-toggle button"); sys.exit(1)
if not sitejs.exists() or "kit-scheme-toggle" not in sitejs.read_text(encoding="utf-8"):
    print("FAIL: docs/assets/js/site.js does not wire the kit-scheme-toggle"); sys.exit(1)
tokens = (docs / "_sass" / "kit" / "_tokens.scss").read_text(encoding="utf-8")
if 'data-kit-scheme="dark"' not in tokens or "prefers-color-scheme: dark" not in tokens:
    print("FAIL: docs/_sass/kit/_tokens.scss must answer both [data-kit-scheme=\"dark\"] and prefers-color-scheme: dark"); sys.exit(1)
# The restore and the toggle share state by string across two files: one storage key, one attribute.
texts = {p.name: p.read_text(encoding="utf-8") for p in sorted((docs / "_includes").glob("*.html"))}
texts["site.js"] = sitejs.read_text(encoding="utf-8")
for what, pattern in (("storage key", r"localStorage\.\w+Item\('([^']+)'"), ("attribute", r"Attribute\('(data-kit-[\w-]+)'")):
    found = sorted({v for t in texts.values() for v in re.findall(pattern, t)})
    if len(found) > 1:
        print("FAIL: the scheme restore and toggle use more than one " + what + " (" + ", ".join(found) + ") — the head and site.js must agree"); sys.exit(1)
# Inline scripts in includes take block comments only: a folded page would swallow the rest of a
# script after a // (measured on #527), and the rule costs nothing to keep.
for inc in sorted((docs / "_includes").glob("*.html")):
    for body in re.findall(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", inc.read_text(encoding="utf-8"), re.S):
        for line in body.splitlines():
            if re.search(r"(^|[\s;{}])//", line):
                print("FAIL: docs/_includes/" + inc.name + " has a // comment inside an inline <script> — use /* */: " + line.strip()); sys.exit(1)
# Every fenced command carries a copy button (the site's own, added by site.js), and Install and
# Platforms render the host table rather than restating it — docs/_data/hosts.yml is its one home.
if "kit-copy" not in texts["site.js"]:
    print("FAIL: docs/assets/js/site.js adds no kit-copy button to code blocks — the install commands would carry none"); sys.exit(1)
for page in ("install.md", "platforms.md"):
    p = docs / page
    if not p.exists():
        print("FAIL: docs/" + page + " is missing"); sys.exit(1)
    if "site.data.hosts" not in p.read_text(encoding="utf-8"):
        print("FAIL: docs/" + page + " does not read site.data.hosts — the host list has one home, docs/_data/hosts.yml"); sys.exit(1)
# The landing page (#527) installs on every host: it links the Install page, and its picker is
# rendered from the host table, never a hand-typed list of hosts.
if "](install.md)" not in itext or "kit-picker" not in itext or "site.data.hosts" not in itext:
    print("FAIL: docs/index.md must link install.md and carry a kit-picker rendered from site.data.hosts"); sys.exit(1)
# ...and every command on those pages comes from the table too: a command typed into a page goes
# stale the day its host's row changes, and nothing else notices. Install shows the rule-file
# hosts' shared clone line once, then each one's last line, so each such row has exactly that shape.
hosts = yaml.safe_load((docs / "_data" / "hosts.yml").read_text(encoding="utf-8"))
for page in ("index.md", "install.md", "platforms.md"):
    ptext = (docs / page).read_text(encoding="utf-8")
    for host in hosts:
        for line in host.get("install") or []:
            if line in ptext or html.escape(line, quote=False) in ptext:
                print("FAIL: docs/" + page + " types " + host["id"] + "'s install command instead of rendering it from docs/_data/hosts.yml: " + line); sys.exit(1)
rules = [h for h in hosts if h.get("tier") == "rules"]
for host in rules:
    if len(host.get("install") or []) != 2 or host["install"][0] != rules[0]["install"][0]:
        print("FAIL: docs/_data/hosts.yml " + host["id"] + " — a rule-file host installs with the shared clone line, then one more; docs/install.md shows the clone once"); sys.exit(1)
if len([h for h in hosts if h.get("tier") == "plugin"]) > 11:
    print("FAIL: docs/_data/hosts.yml has more than 11 plugin hosts — the picker's CSS in docs/_sass/kit/_home.scss shows 12 panels, one of them Other hosts; raise its @for bound"); sys.exit(1)
# The capability columns are the strings yes, partial and no, one per capability. YAML reads a bare
# yes/no as a boolean, and the Platforms table then printed true/false (measured on #527's first
# build); a missing key renders a blank cell.
caps = {"skills", "commands", "mcp", "hooks", "subagents"}
for host in hosts:
    if set(host.get("gets") or {}) != caps:
        print("FAIL: docs/_data/hosts.yml " + str(host.get("id")) + " gets " + ", ".join(sorted(host.get("gets") or {})) + " — every host names exactly " + ", ".join(sorted(caps))); sys.exit(1)
    for key, value in host["gets"].items():
        if value not in ("yes", "partial", "no"):
            print("FAIL: docs/_data/hosts.yml " + str(host.get("id")) + " gets." + key + " is " + repr(value) + " — quote it: \"yes\", \"partial\" or \"no\""); sys.exit(1)
print("ok   docs/_config.yml parses (no theme, no glob in exclude, every assigned layout exists), docs/index.md links the guide, every non-excluded page is titled, the dark scheme is switchable")
PY
python3 "$_pscratch/pages-check.py" "$KIT_ROOT" || exit 1
# The red halves: a full copy of docs/ per case, one file broken the way its check exists to catch,
# refused by name. ONE check file, run on each.
_red_docs() {  # <case> — a fresh copy of docs/ under $_pscratch/<case>
  rm -rf "${_pscratch:?}/$1"; mkdir -p "$_pscratch/$1"; cp -R "$KIT_ROOT/docs" "$_pscratch/$1/docs"
}
_red_refused() {  # <case> <text the refusal must name> <what was broken>
  if python3 "$_pscratch/pages-check.py" "$_pscratch/$1" > "$_pscratch/$1.out" 2>&1; then
    echo "FAIL: the Pages check accepted $3"; exit 1
  fi
  grep -qF -- "$2" "$_pscratch/$1.out" \
    || { echo "FAIL: the Pages check refused $3 without naming $2"; cat "$_pscratch/$1.out"; exit 1; }
  echo "ok   $3 is refused, by name"
}
_red_docs untitled
printf -- '---\nnav_order: 9\n---\n\n# untitled\n' > "$_pscratch/untitled/docs/untitled.md"
_red_refused untitled "untitled.md" "a docs/ page without a title"
_red_docs globtree
sed 's|^  - case-studies/winrt-portfolio/dashboard.html$|  - "*.html"|' "$KIT_ROOT/docs/_config.yml" > "$_pscratch/globtree/docs/_config.yml"
_red_refused globtree '*.html' "a glob in docs/_config.yml's exclude (the one that unpublished every layout)"
_red_docs ghostlayout
printf '\n  - scope:\n      path: decisions.md\n    values:\n      layout: ghost\n' >> "$_pscratch/ghostlayout/docs/_config.yml"
_red_refused ghostlayout "ghost" "a default assigning a layout with no file under docs/_layouts"
_red_docs ghostpartial
printf '@import "kit/ghost";\n' >> "$_pscratch/ghostpartial/docs/assets/css/site.scss"
_red_refused ghostpartial "kit/ghost" "a stylesheet importing a Sass partial that does not exist"
_red_docs theme
sed "s/localStorage.getItem('kit-scheme')/localStorage.getItem('kit-theme')/" "$KIT_ROOT/docs/_includes/head.html" > "$_pscratch/theme/docs/_includes/head.html"
_red_refused theme "kit-theme" "a scheme restore reading a storage key the toggle never writes"
_red_docs typed
printf '%s\n' 'git clone https://github.com/phmatray/tagout ~/.tagout' >> "$_pscratch/typed/docs/install.md"
_red_refused typed "docs/install.md types" "an install command typed into a page"
_red_docs gets
sed 's/, hooks: "yes"//' "$KIT_ROOT/docs/_data/hosts.yml" > "$_pscratch/gets/docs/_data/hosts.yml"
_red_refused gets "claude-code gets" "a host row missing a capability"

# ---------------------------------------------------------------------------------------------
# docs/journal/ is a Journal section (#443): one article per published release, rendered as a
# just-the-docs child section, and held to the journal's two prose rules by a gate rather than by
# review. Same shape as the Pages guard above: ONE check file, run on the real tree (must pass) and
# once per scratch tree (must fail, and must NAME the offending file).
echo "== docs/journal/ is a Journal section: parented, ordered, English, em dash free (#443) =="
_jscratch=$(kit_scratch)
cat > "$_jscratch/journal-check.py" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1]); jdir = root / "docs" / "journal"
if not jdir.is_dir():
    print("FAIL: docs/journal/ is missing"); sys.exit(1)
idx = jdir / "index.md"
if not idx.exists():
    print("FAIL: docs/journal/index.md is missing"); sys.exit(1)
itext = idx.read_text(encoding="utf-8")
if "has_children: true" not in itext[:2000]:
    print("FAIL: docs/journal/index.md does not carry has_children: true, so the section renders no child list")
    sys.exit(1)
for needle in ("Adding the next article", "Never renumber"):
    if needle not in itext:
        print("FAIL: docs/journal/index.md does not carry the recipe needle %r" % needle); sys.exit(1)
home_path = root / "docs" / "index.md"
if not home_path.exists():
    print("FAIL: docs/index.md is missing"); sys.exit(1)
home = home_path.read_text(encoding="utf-8")
if "](journal/index.md)" not in home:
    print("FAIL: docs/index.md does not link journal/index.md"); sys.exit(1)
articles = sorted(p for p in jdir.glob("*.md") if p.name != "index.md")
if not articles:
    print("FAIL: docs/journal/ holds no articles"); sys.exit(1)

# ponytail: rule 2 is a French function-word scan, not a language detector — a French article
# written without any of these markers would pass. Swap in a detector only if one ever slips through.
MARKERS = ["le", "la", "les", "des", "une", "pour", "avec", "dans", "qui", "pas", "nous", "cette",
           "sont", "mais", "leur", "aux", "ses", "sans", "donc", "ainsi", "chaque", "parce"]
MARKER_RE = re.compile(r"\b(" + "|".join(MARKERS) + r")\b", re.I)
FENCE_RE = re.compile(r"^```.*?^```", re.M | re.S)
SPAN_RE = re.compile(r"`[^`\n]*`")
QUOTE_RE = re.compile(r"«[^»]*»")
bad = []
orders = {}
for p in articles:
    rel = p.relative_to(root).as_posix()
    text = p.read_text(encoding="utf-8")
    for i, line in enumerate(text.splitlines(), 1):
        col = line.find("—")
        if col >= 0:
            bad.append("%s:%d:%d holds an em dash (U+2014)" % (rel, i, col + 1))
    prose = QUOTE_RE.sub(" ", SPAN_RE.sub(" ", FENCE_RE.sub(" ", text)))
    found = sorted({m.group(1).lower() for m in MARKER_RE.finditer(prose)})
    if len(found) >= 3:
        bad.append("%s reads as French, not English (markers: %s)" % (rel, ", ".join(found)))
    if not re.search(r"^parent:\s*[\"']?Journal[\"']?\s*$", text, re.M):
        bad.append("%s does not carry 'parent: Journal'" % rel)
    m = re.search(r"^nav_order:\s*[\"']?(\d+)[\"']?\s*$", text, re.M)
    if not m:
        bad.append("%s does not carry a numeric nav_order" % rel)
    else:
        orders.setdefault(int(m.group(1)), []).append(rel)
for order, owners in sorted(orders.items()):
    if len(owners) > 1:
        bad.append("nav_order %d is claimed by %s" % (order, ", ".join(sorted(owners))))
if bad:
    print("FAIL: docs/journal/ articles must be English, free of the em dash, and correctly ordered:")
    for b in bad:
        print("  " + b)
    sys.exit(1)
print("ok   %d journal articles, all English, em dash free, parented and uniquely ordered" % len(articles))
PY
python3 "$_jscratch/journal-check.py" "$KIT_ROOT" || exit 1
# Red path 1: an em dash anywhere in an article body. The natural draft of any prose in this repo
# contains one, which is why this rule is a gate rather than a review note.
mkdir -p "$_jscratch/emtree/docs/journal"
cp "$KIT_ROOT/docs/index.md" "$_jscratch/emtree/docs/"
cp "$KIT_ROOT/docs/journal/index.md" "$KIT_ROOT/docs/journal/v2.1.0.md" "$_jscratch/emtree/docs/journal/"
printf 'The gate refused \xe2\x80\x94 loudly.\n' >> "$_jscratch/emtree/docs/journal/v2.1.0.md"
if python3 "$_jscratch/journal-check.py" "$_jscratch/emtree" > "$_jscratch/journal-em.out" 2>&1; then
  echo "FAIL: the journal check accepted an article containing an em dash"; exit 1
fi
grep -q 'holds an em dash' "$_jscratch/journal-em.out" \
  || { echo "FAIL: the em dash refusal does not name the em dash rule"; cat "$_jscratch/journal-em.out"; exit 1; }
grep -q 'v2\.1\.0\.md' "$_jscratch/journal-em.out" \
  || { echo "FAIL: the em dash refusal does not name v2.1.0.md"; cat "$_jscratch/journal-em.out"; exit 1; }
echo "ok   an em dash in a journal article is refused, by name"

# Red path 2: an article written in French. The front matter is kept, so what is refused is the
# prose and not a missing parent: or nav_order:.
mkdir -p "$_jscratch/frtree/docs/journal"
cp "$KIT_ROOT/docs/index.md" "$_jscratch/frtree/docs/"
cp "$KIT_ROOT/docs/journal/index.md" "$_jscratch/frtree/docs/journal/"
awk '/^---$/{n++} {print} n==2{exit}' "$KIT_ROOT/docs/journal/v2.1.0.md" \
  > "$_jscratch/frtree/docs/journal/v2.1.0.md"
printf '\nCette version corrige les blocages dans la file, avec une garde pour les workers.\n' \
  >> "$_jscratch/frtree/docs/journal/v2.1.0.md"
if python3 "$_jscratch/journal-check.py" "$_jscratch/frtree" > "$_jscratch/journal-fr.out" 2>&1; then
  echo "FAIL: the journal check accepted an article written in French"; exit 1
fi
grep -q 'French' "$_jscratch/journal-fr.out" \
  || { echo "FAIL: the French refusal does not say 'French'"; cat "$_jscratch/journal-fr.out"; exit 1; }
grep -q 'v2\.1\.0\.md' "$_jscratch/journal-fr.out" \
  || { echo "FAIL: the French refusal does not name v2.1.0.md"; cat "$_jscratch/journal-fr.out"; exit 1; }
echo "ok   a French journal article is refused, by name"

# Red path 3: two articles claiming one nav_order, which is what renumbering, or copying an article
# without editing its front matter, produces. just-the-docs would then order them arbitrarily.
mkdir -p "$_jscratch/duptree/docs/journal"
cp "$KIT_ROOT/docs/index.md" "$_jscratch/duptree/docs/"
cp "$KIT_ROOT/docs/journal/index.md" "$KIT_ROOT/docs/journal/v2.1.0.md" "$_jscratch/duptree/docs/journal/"
cp "$_jscratch/duptree/docs/journal/v2.1.0.md" "$_jscratch/duptree/docs/journal/v2.0.0.md"
if python3 "$_jscratch/journal-check.py" "$_jscratch/duptree" > "$_jscratch/journal-dup.out" 2>&1; then
  echo "FAIL: the journal check accepted two articles claiming one nav_order"; exit 1
fi
grep -q 'nav_order 18' "$_jscratch/journal-dup.out" \
  || { echo "FAIL: the duplicate-order refusal does not name the number"; cat "$_jscratch/journal-dup.out"; exit 1; }
grep -q 'v2\.1\.0\.md' "$_jscratch/journal-dup.out" && grep -q 'v2\.0\.0\.md' "$_jscratch/journal-dup.out" \
  || { echo "FAIL: the duplicate-order refusal does not name both files"; cat "$_jscratch/journal-dup.out"; exit 1; }
echo "ok   two journal articles claiming one nav_order are refused, by number"

# Red path 4: an article with no parent:. Without a witness, a regex narrowed out of existence
# would leave this rule green forever.
mkdir -p "$_jscratch/orphtree/docs/journal"
cp "$KIT_ROOT/docs/index.md" "$_jscratch/orphtree/docs/"
cp "$KIT_ROOT/docs/journal/index.md" "$_jscratch/orphtree/docs/journal/"
grep -v '^parent:' "$KIT_ROOT/docs/journal/v2.1.0.md" > "$_jscratch/orphtree/docs/journal/v2.1.0.md"
if python3 "$_jscratch/journal-check.py" "$_jscratch/orphtree" > "$_jscratch/journal-orph.out" 2>&1; then
  echo "FAIL: the journal check accepted an article with no parent:"; exit 1
fi
grep -q "does not carry 'parent: Journal'" "$_jscratch/journal-orph.out" \
  || { echo "FAIL: the orphan refusal does not name the parent: rule"; cat "$_jscratch/journal-orph.out"; exit 1; }
grep -q 'v2\.1\.0\.md' "$_jscratch/journal-orph.out" \
  || { echo "FAIL: the orphan refusal does not name v2.1.0.md"; cat "$_jscratch/journal-orph.out"; exit 1; }
echo "ok   a journal article with no parent: is refused, by name"

# The journal goes stale silently: the check above holds every article that EXISTS to the two prose
# rules, and says nothing about a published release that has no article at all. This second check
# file closes that, and is deliberately a SEPARATE program from the prose check above: the prose red
# paths run against scratch trees that are plain directories rather than git repositories, and
# folding the coverage rule in would fail every one of them for the wrong reason.
# The tag list is an injectable argument defaulting to the tag list of the tree under test, so the
# red paths need no git repository built in scratch and exercise exactly the code the green run does.
cat > "$_jscratch/journal-coverage.py" <<'PY'
import pathlib, re, subprocess, sys
root = pathlib.Path(sys.argv[1])
if "--tags" in sys.argv:
    raw = sys.argv[sys.argv.index("--tags") + 1].split()
else:
    raw = subprocess.run(["git", "-C", str(root), "tag", "--list", "v*"],
                         capture_output=True, text=True).stdout.split()
VER = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
tags = {}
for t in raw:
    m = VER.match(t)
    if m:
        tags[t] = tuple(int(g) for g in m.groups())
if not tags:
    print("FAIL: no v* tags are visible, so journal coverage cannot be judged "
          "— is this a checkout without tags?")
    sys.exit(1)
newest = max(tags, key=tags.get)
missing = sorted((t for t in tags
                  if t != newest and not (root / "docs" / "journal" / (t + ".md")).exists()),
                 key=lambda t: tags[t])
if missing:
    print("FAIL: published releases with no journal article: " + ", ".join(missing)
          + " (the newest release, " + newest + ", is exempt for one version)")
    sys.exit(1)
print("ok   every published release except the newest (%s) has a journal article" % newest)
PY
# Red path 5: a published release that is NOT the newest and has no article. The one-release grace
# window is why v9.9.10 is passed alongside it: it is newer and equally absent, and must NOT be named.
if python3 "$_jscratch/journal-coverage.py" "$KIT_ROOT" --tags "v1.4.1 v9.9.9 v9.9.10" \
    > "$_jscratch/cov-missing.out" 2>&1; then
  echo "FAIL: the coverage check accepted a published release with no journal article"; exit 1
fi
grep -q 'v9\.9\.9' "$_jscratch/cov-missing.out" \
  || { echo "FAIL: the missing-article refusal does not name v9.9.9"; cat "$_jscratch/cov-missing.out"; exit 1; }
# ...and v9.9.10, which is equally absent but IS the newest, must not appear in the missing LIST.
# Asserting the whole line rather than a negative grep: v9.9.10 legitimately appears later in the
# message as the exempt version, so `grep -v` would be satisfied by the bug it is meant to catch.
# Without this, deleting the `t != newest` clause leaves every assertion here green.
grep -q 'article: v9\.9\.9 (the newest release, v9\.9\.10, is exempt' "$_jscratch/cov-missing.out" \
  || { echo "FAIL: the grace window did not exempt the newest release, or the refusal is misworded"
       cat "$_jscratch/cov-missing.out"; exit 1; }
echo "ok   a published release with no journal article is refused, by version"
echo "ok   the newest release is exempt from the coverage rule for one version"

# Red path 6: no tags at all. A checkout without tags would otherwise turn the whole rule into a
# no-op reporting a green tick, which is strictly worse than having no gate at all.
if python3 "$_jscratch/journal-coverage.py" "$KIT_ROOT" --tags "" \
    > "$_jscratch/cov-notags.out" 2>&1; then
  echo "FAIL: the coverage check passed with no tags visible"; exit 1
fi
grep -q 'no v\* tags are visible' "$_jscratch/cov-notags.out" \
  || { echo "FAIL: the empty-tag-list refusal does not say no tags are visible"; cat "$_jscratch/cov-notags.out"; exit 1; }
echo "ok   an empty tag list is refused, not passed"

# The green run: the real tree, against the real tag list.
python3 "$_jscratch/journal-coverage.py" "$KIT_ROOT" || exit 1

# ---------------------------------------------------------------------------------------------
# A pointer-only CLAUDE.md for agents working on the kit (#325). Exactly one of the two documented
# locations, a line budget so it stays pointers rather than sediment, and every relative link
# actually resolves — a link that used to work but now 404s is worse than no pointer at all.
echo "== exactly one pointer-only CLAUDE.md exists, <= 60 lines, links resolve (#325) =="
python3 - "$KIT_ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
candidates = [root / "CLAUDE.md", root / ".claude" / "CLAUDE.md"]
present = [p for p in candidates if p.is_file()]
if len(present) != 1:
    print("FAIL: expected exactly one of CLAUDE.md / .claude/CLAUDE.md, found %d" % len(present))
    sys.exit(1)

path = present[0]
lines = path.read_text(encoding="utf-8").splitlines()
if len(lines) > 60:
    print("FAIL: %s has %d lines, over the 60-line budget" % (path, len(lines)))
    sys.exit(1)

text = "\n".join(lines)
for m in re.finditer(r"\]\(([^)]+)\)", text):
    target = m.group(1)
    if target.startswith("http://") or target.startswith("https://") or target.startswith("#"):
        continue
    target_path = target.split("#", 1)[0]
    resolved = (path.parent / target_path).resolve()
    if not resolved.exists():
        print("FAIL: %s links %r, which does not resolve (tried %s)" % (path, target, resolved))
        sys.exit(1)

print("ok   %s exists, is <= 60 lines, and every relative link resolves" % path.relative_to(root))
PY
# create-issue consults the accepted ADRs before it brainstorms (#316). The touchpoint is prose and
# cannot go red on its own, so this pins the three load-bearing spellings: the server tool it calls,
# the verdict it must write when an idea contradicts a decision, and the file fallback for a host
# with no AdrMcp.
echo "== create-issue checks the idea against accepted ADRs (#316) =="
CREATE_ISSUE="$(kit_skill_prose "$KIT_ROOT" create-issue)"   # router + references/steps/*.md (#499)
[ -s "$CREATE_ISSUE" ] || { echo "FAIL: create-issue prose is empty"; exit 1; }
for needle in 'search_adrs' 'contradicts ADR-' 'docs/adr'; do
  grep -q "$needle" "$CREATE_ISSUE" \
    || { echo "FAIL: $CREATE_ISSUE does not mention '$needle'"; exit 1; }
done
echo "ok   create-issue names search_adrs, the contradiction verdict and the docs/adr fallback"

# ---------------------------------------------------------------------------------------------
# A diff that touches an accepted ADR's `code_refs` proposes an ADR update rather than making one
# (#316). Both consumers get the same paragraph, so both are pinned — and each must name
# `suggest_adr_from_change` AND the `## Follow-ups` heading the draft lands under, because a draft
# named without a destination is the failure mode this touchpoint exists to avoid.
echo "== implement-issue and merge-pr propose an ADR update, never write one (#316) =="
for f in implement-issue merge-pr; do
  path="$(kit_skill_prose "$KIT_ROOT" "$f")"   # router + references/steps/*.md (#499)
  [ -s "$path" ] || { echo "FAIL: $f prose is empty"; exit 1; }
  for needle in 'suggest_adr_from_change' '## Follow-ups' 'code_refs' 'docs/adr'; do
    grep -q -- "$needle" "$path" \
      || { echo "FAIL: $path does not mention '$needle'"; exit 1; }
  done
done
echo "ok   both consumers name suggest_adr_from_change, ## Follow-ups and the docs/adr fallback"

# ---------------------------------------------------------------------------------------------
# implement-issue Step 7 used to run code-review with no level, so it inherited whatever level was
# last typed in ANY session (#520) — one run inherited xhigh and spent 106.8M tokens on 25 review
# sub-agents. Every `/code-review` span in the assembled prose must now name an explicit level, and
# `ultra` must never be prescribed (it's a cloud review only a human can launch).
kit_check_code_review_levels() {
  # Reads $1 for backticked `/code-review ...` spans; FAILs (echoes and returns 1) the first time a
  # span's level word is missing or not one of low|medium|high|xhigh|max — which also catches
  # `ultra`, since it's not in that set.
  local file="${1:?kit_check_code_review_levels needs a file}" span level
  while IFS= read -r span; do
    level="$(printf '%s\n' "$span" | sed -E 's/^`\/code-review[[:space:]]*//; s/`$//' | awk '{print $1}')"
    case "$level" in
      low|medium|high|xhigh|max) ;;
      *) echo "FAIL: $file has a /code-review span with no valid level: $span"; return 1 ;;
    esac
  done < <(grep -oE '`/code-review[^`]*`' "$file")
  return 0
}

echo "== implement-issue names an explicit code-review level on every call (#520) =="
IMPLEMENT_ISSUE_PROSE="$(kit_skill_prose "$KIT_ROOT" implement-issue)"   # router + references/steps/*.md (#499)
[ -s "$IMPLEMENT_ISSUE_PROSE" ] || { echo "FAIL: implement-issue prose is empty"; exit 1; }
kit_check_code_review_levels "$IMPLEMENT_ISSUE_PROSE" || exit 1
echo "ok   every /code-review span in implement-issue's prose names low|medium|high|xhigh|max, never bare or ultra"

# The check must actually catch a bare call — proven on a scratch fixture, not just on the live
# prose, so the expected answer doesn't come from the file under test.
BARE_CODE_REVIEW="$(kit_scratch)/bare.md"
printf 'Run `/code-review` over the diff.\n' > "$BARE_CODE_REVIEW"
if kit_check_code_review_levels "$BARE_CODE_REVIEW" >/dev/null; then
  echo "FAIL: kit_check_code_review_levels did not catch a bare /code-review span in $BARE_CODE_REVIEW"
  exit 1
fi
echo "ok   the check fails on a bare \`/code-review\` span (scratch fixture)"

# ---------------------------------------------------------------------------------------------
# AdrMcp is documented as shipped, next to the RoselineMCP paragraph it mirrors, and the ADR index
# is reachable from both entry documents (#316). A dependency the kit ships without saying so is
# the failure this pins — the README already carries that promise for roseline.
echo "== README and ARCHITECTURE document AdrMcp and the ADR root (#316) =="
for f in "README.md" "ARCHITECTURE.md"; do
  path="$KIT_ROOT/$f"
  [ -f "$path" ] || { echo "FAIL: $path missing"; exit 1; }
  for needle in 'AdrMcp' 'docs/adr'; do
    grep -q -- "$needle" "$path" \
      || { echo "FAIL: $path does not mention '$needle'"; exit 1; }
  done
done
echo "ok   README and ARCHITECTURE both name AdrMcp and docs/adr"

# ---------------------------------------------------------------------------------------------
# merge-pr reads the base-branch CI run its OWN merge triggered, and always says what it found
# (#355). The skill used to end its contract at "the PR is MERGED": two PRs each green against
# their own base combined into a red `main` (f17c85c, 2026-08-30) and nobody read the push run,
# because both merges had already reported success and torn down.
#
# Three things are pinned, and the third is the one that keeps the step honest. The step itself,
# so it cannot be quietly dropped; the helper, so the skill cannot grow a second, hand-rolled CI
# reader beside it; and ALL THREE report outcomes, because an `unverified` that never reaches the
# report is indistinguishable from the silence this whole change removes — a merge whose base run
# was cancelled by the next merge in the train is the COMMON case, not an edge one.
echo "== merge-pr reports the base CI verdict its own merge produced (#355) =="
skill="$(kit_skill_prose "$KIT_ROOT" merge-pr)"   # router + references/steps/*.md (#499)
[ -s "$skill" ] || { echo "FAIL: merge-pr prose is empty"; exit 1; }
for needle in 'Step 5b' 'base-run-verdict.sh' 'base green at' 'base RED at' 'base unverified at'; do
  grep -q -F -- "$needle" "$skill" \
    || { echo "FAIL: $skill does not name '$needle' — Step 5b is not wired into the skill"; exit 1; }
done
# Never revert, and never stop. Both are autonomy-contract promises the step makes in prose only,
# so prose is where they have to be pinned: an autonomous fleet that gained a post-merge stop, or
# a skill that reverted somebody else's merge on an inherited red, are the two ways this step
# turns into a worse failure than the one it fixes.
grep -q -i -- 'never revert' "$skill" \
  || { echo "FAIL: $skill no longer says Step 5b never reverts"; exit 1; }
# The by-sha resolution recipe has one home, beside the §3 check-runs recipe it reuses.
mech="$KIT_ROOT/skills/merge-pr/references/merge-mechanics.md"
[ -f "$mech" ] || { echo "FAIL: $mech missing"; exit 1; }
grep -q -F -- 'base-run-verdict.sh' "$mech" \
  || { echo "FAIL: $mech carries no base-run resolution recipe"; exit 1; }
echo "ok   merge-pr names Step 5b, the helper, and all three base outcomes in its report"
# Three ways Step 5b could be written and still pass every check above, each found by review and
# each producing a WRONG report rather than a missing one — so each gets its own witness:
#   * `guarded-pr-merge.sh` prints the literal `<unknown-sha>` when its readback finds no
#     mergeCommit.oid. That is not a hex sha, the helper refuses it (exit 64 — its one non-answer),
#     and the snippet's three branches all fall through to nothing.
#   * a merge train inherits one red across several DIFFERENT squash shas, so a sha-keyed
#     de-duplication never matches and N workers file N bugs for one root cause.
#   * the resume path (`state == MERGED` on entry) has no $MERGE_OUT to read a sha from, and
#     `auto-dev` now reads a BASE: field off exactly the report line that path produces.
for needle in 'mergeCommit' 'the same job(s)' 'resumed after the merge'; do
  grep -q -F -- "$needle" "$skill" \
    || { echo "FAIL: $skill Step 5b lost its guard for '$needle'"; exit 1; }
done
echo "ok   Step 5b guards the unknown-sha sentinel, folds on the breakage, and survives a resume"


# The fleet inherits Step 5b through its workers, so the answer has to survive the report boundary:
# a phase-2 worker that folds "the base went red" into free-text DETAIL is indistinguishable, on the
# orchestrator's state board, from a clean merge. Both halves are pinned — the field on the report
# line the worker emits, and the place the board puts it — because either one alone re-hides it.
echo "== a red base after a worker's merge is fleet-visible (#355) =="
for f in "skills/auto-dev/SKILL.md" "commands/auto-dev-merge.md"; do
  path="$KIT_ROOT/$f"
  [ -f "$path" ] || { echo "FAIL: $path missing"; exit 1; }
  grep -q -F -- 'BASE:' "$path" \
    || { echo "FAIL: $path's phase-2 report line carries no BASE: field"; exit 1; }
done
grep -q -F -- 'MERGED (<commit>) — base' "$KIT_ROOT/skills/auto-dev/SKILL.md" \
  || { echo "FAIL: the auto-dev state board's Completed row does not carry the base verdict"; exit 1; }
echo "ok   auto-dev carries the base verdict on the report line and the state board"

# merge-pr Step 3 waits for CI by calling wait-ci.sh in one tool call, not polling turn-by-turn
# (#521). The step itself says how to wait — that wording is the contract the automation reads,
# so the skill must name wait-ci.sh there or a change that removes it becomes invisible to
# a test that only knows to look for the phrase it is supposed to name.
echo "== merge-pr Step 3 waits with wait-ci.sh (#521) =="
skill="$(kit_skill_prose "$KIT_ROOT" merge-pr)"   # router + references/steps/*.md (#499)
[ -s "$skill" ] || { echo "FAIL: merge-pr prose is empty"; exit 1; }
# Extract the Step 3 section: from "## Step 3" up to the next "## Step"
step3=$(sed -n '/^## Step 3/,/^## Step [0-9]/p' "$skill" | sed '$d')   # $d removes the last "## Step" line
[ -n "$step3" ] || { echo "FAIL: merge-pr Step 3 not found in assembled prose"; exit 1; }
grep -q -F -- 'wait-ci.sh' <<< "$step3" \
  || { echo "FAIL: merge-pr Step 3 does not mention wait-ci.sh"; exit 1; }
echo "ok   merge-pr Step 3 waits with wait-ci.sh"


echo "skills golden test: all cases behaved as specified"

# ---------------------------------------------------------------------------------------------
# The trigger contract has ONE home, and the records say so (#331). The ten
# tests/skills/<name>.triggers.md lists were a CACHE of the eval sets — a second copy of a contract
# nothing ran, which CI certified while the sets it duplicated drifted away from it. Deleting them
# is only half the fix: as long as a live document still points a reader at that path, the cache is
# rebuilt the first time someone follows the pointer. So this pins the pointer, not just the files.
#
# Pinned against the real tree (no scratch fixture): the defect IS the committed prose.
echo "== the trigger contract has one home, and the records name it (#331) =="

# Not `compgen -G`: it answers 1 for "no matches" AND for "not a builtin / progcomp disabled",
# so a guard whose whole job is anti-recurrence would print ok when it never ran at all.
r1_found=0
for f in "$KIT_ROOT"/tests/skills/*.triggers.md; do
  [ -e "$f" ] && r1_found=1
done
if [ "$r1_found" -ne 0 ]; then
  echo "FAIL: [R1 no tests/skills/*.triggers.md         ] a retired trigger list is back — the"
  echo "      contract lives in evals/<skill>-trigger-eval.json, guarded by check-frontmatter.py"
  fails=$((fails + 1))
else
  echo "ok   [R1 no tests/skills/*.triggers.md         ]"
fi

# Only these may still say "triggers.md", and each for a reason that is not a pointer:
#   CHANGELOG.md, reviews/  — dated, immutable records of what the kit did on a given day;
#                             rewriting them would falsify history (CHANGELOG.md is release-please's).
#   docs/backlog.md         — the entry rewritten as a CLOSED item, which has to name what closed.
#   tests/skills/*.py|sh    — this suite and the checker, explaining the rule they replaced.
# Anything else naming the path is a live pointer at a home that no longer exists.
# `plugins/` is out of the sweep: it is generated output (ADR 0017), so every hit under it is a
# byte-for-byte copy of a file already judged above at its source, and listing it would refuse the
# copy of something this list allows.
R2_ALLOWED="CHANGELOG.md docs/backlog.md tests/skills/check-frontmatter.py tests/skills/test.sh"
r2_hits=$(git -C "$KIT_ROOT" grep -l -F "triggers.md" -- . ':(exclude)plugins' 2>/dev/null || true)
r2_unexpected=""
# THIS file always matches (its own R1 glob is spelled below), so an empty or sentinel-less result
# means `git grep` failed rather than that the tree is clean — the one way this guard could pass
# while never having looked.
if ! grep -qx "tests/skills/test.sh" <<<"$r2_hits"; then
  echo "FAIL: [R2 no live pointer at the retired path  ] the git-grep sweep did not even find this"
  echo "      file, which always matches — the search failed; the verdict below would be vacuous"
  fails=$((fails + 1))
else
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in reviews/*) continue ;; esac
  case " $R2_ALLOWED " in *" $f "*) continue ;; esac
  r2_unexpected="$r2_unexpected $f"
done <<< "$r2_hits"
if [ -n "$r2_unexpected" ]; then
  echo "FAIL: [R2 no live pointer at the retired path  ]$r2_unexpected"
  echo "      still names tests/skills/<name>.triggers.md — point it at evals/<skill>-trigger-eval.json"
  fails=$((fails + 1))
else
  echo "ok   [R2 no live pointer at the retired path  ]"
fi
fi

# C: pin the ROW, not the filename. `grep -qF trigger-eval.json` over the whole file passes even if
#    the "Where each concern lives" row is deleted and the path appears in unrelated prose — which
#    is the very thing R3's own failure message claims to be checking.
if grep -qE '^\| Triggering contracts \|[^|]*evals/<name>-trigger-eval\.json' "$KIT_ROOT/ARCHITECTURE.md" 2>/dev/null; then
  echo "ok   [R3 ARCHITECTURE.md names the new home   ]"
else
  echo "FAIL: [R3 ARCHITECTURE.md names the new home   ] its \"Where each concern lives\" row must"
  echo "      point Triggering contracts at evals/<name>-trigger-eval.json"
  fails=$((fails + 1))
fi

# ---------------------------------------------------------------------------------------------
# The two auto-dev command files are DISPATCHED by name, so each carries ONE human-facing line and
# leaves the phase contract to its body (#323) — they were the longest descriptions in commands/,
# each re-stating what its own body already says.
#
# What they must NOT carry is `disable-model-invocation` (#323 review). #323's spec proposed it on
# the reasoning that "the supervisor never asks the model to FIND /auto-dev-worker" — true of
# discovery, false of invocation, and the key gates invocation. Since #314 a worker is an in-process
# SUB-AGENT: `skills/auto-dev/SKILL.md` dispatches `Agent(prompt: "Invoke \`auto-dev-worker\` with
# args <N>")`, and that sub-agent is a model whose first act is to invoke the command. Disabling
# model invocation would leave every phase-1 and phase-2 worker in the fleet unable to reach its own
# contract. Both halves are pinned so neither can drift back.
#
# Pinned against the real tree (no scratch fixture): the defect IS the committed frontmatter.
echo "== the dispatched auto-dev commands carry one line, and stay model-invocable (#323) =="
D_CHECK=$(cat <<'PY'
import re, sys, yaml
t = open(sys.argv[1], encoding="utf-8").read()
m = re.match(r"^---\n(.*?)\n---\n", t, re.S)
fm = yaml.safe_load(m.group(1)) if m else None
if not isinstance(fm, dict):
    sys.exit("frontmatter absent or not a YAML mapping")
if "disable-model-invocation" in fm:
    sys.exit("disable-model-invocation is set — since #314 the auto-dev worker is an in-process "
             "sub-agent that INVOKES this command through the Skill tool, so disabling model "
             "invocation breaks every worker in the fleet (#323 review)")
desc = " ".join(str(fm.get("description") or "").split())
if not desc:
    sys.exit("description missing — the slash-command list still shows it to a human")
if len(desc) > 200:
    sys.exit("description is %d characters — a dispatched command keeps ONE human-facing "
             "line (<= 200); the phase contract belongs in the body" % len(desc))
if not str(fm.get("argument-hint") or "").strip():
    sys.exit("argument-hint missing — it is how a human learns the argument")
PY
)
for cmd in auto-dev-worker auto-dev-merge; do
  set +e
  d_out=$(python3 -c "$D_CHECK" "$KIT_ROOT/commands/$cmd.md" 2>&1)
  d_rc=$?
  set -e
  if [ "$d_rc" -eq 0 ]; then
    echo "ok   [D1 commands/$cmd.md one line, invocable]"
  else
    echo "FAIL: [D1 commands/$cmd.md one line, invocable] $d_out"
    fails=$((fails + 1))
  fi
done

echo "== the inline-fix carve-out is stated once and repeated word for word in the worker command (#410) =="
# implement-issue's *Don't widen the blast radius* bullet is the normative home; commands/auto-dev-worker.md
# repeats the block because fleet workers read the command, not the skill. A repeated block drifts unless
# something reads both — this does: the sentences from the first marker to the second, whitespace-
# normalised, must be byte-identical in the two files. Written to a file first, never a heredoc inside
# `$( … )` (#131, the bash 3.2 scanner hazard parse-sweep exists to catch).
_cscratch=$(kit_scratch)
cat > "$_cscratch/carve-out-check.py" <<'PY'
import pathlib, re, sys
kit = pathlib.Path(sys.argv[1])
start = "it is **fixed inline** when it is **local**"
end = "read as deferred work and filed."
def block(rel):
    text = re.sub(r"\s+", " ", (kit / rel).read_text(encoding="utf-8"))
    i = text.find(start)
    if i < 0:
        sys.exit("%s: the carve-out block is missing (no %r)" % (rel, start))
    j = text.find(end, i)
    if j < 0:
        sys.exit("%s: the carve-out block is unterminated (no %r)" % (rel, end))
    return text[i:j + len(end)]
a = block("skills/implement-issue/SKILL.md")
b = block("commands/auto-dev-worker.md")
if a != b:
    sys.exit("the carve-out block differs between skills/implement-issue/SKILL.md and "
             "commands/auto-dev-worker.md — edit both or neither")
print("%d characters, identical" % len(a))
PY
set +e
c_out=$(python3 "$_cscratch/carve-out-check.py" "$KIT_ROOT" 2>&1)
c_rc=$?
set -e
if [ "$c_rc" -eq 0 ]; then
  echo "ok   [C1 carve-out block identical in SKILL.md and auto-dev-worker.md — $c_out]"
else
  echo "FAIL: [C1 carve-out block identical in SKILL.md and auto-dev-worker.md] $c_out"
  fails=$((fails + 1))
fi
# The red half: a one-word drift in a scratch copy of the worker command must be refused, naming both files.
mkdir -p "$_cscratch/drift/skills/implement-issue" "$_cscratch/drift/commands"
cp "$KIT_ROOT/skills/implement-issue/SKILL.md" "$_cscratch/drift/skills/implement-issue/SKILL.md"
# The drifted phrase sits on one line of the wrapped command file, so sed can reach it.
sed 's/survives without an issue/survives without any issue/' "$KIT_ROOT/commands/auto-dev-worker.md" > "$_cscratch/drift/commands/auto-dev-worker.md"
cmp -s "$KIT_ROOT/commands/auto-dev-worker.md" "$_cscratch/drift/commands/auto-dev-worker.md" \
  && { echo "FAIL: [C2] the drift fixture did not drift — the phrase moved; pick one that sits on a single line"; fails=$((fails + 1)); }
set +e
c_red=$(python3 "$_cscratch/carve-out-check.py" "$_cscratch/drift" 2>&1)
c_red_rc=$?
set -e
if [ "$c_red_rc" -ne 0 ] && printf '%s' "$c_red" | grep -q 'auto-dev-worker.md'; then
  echo "ok   [C2 a drifted worker copy is refused, naming both files]"
else
  echo "FAIL: [C2 a drifted worker copy is refused, naming both files] rc=$c_red_rc $c_red"
  fails=$((fails + 1))
fi

# Every file reference in a shipped prompt resolves (check-file-refs.py). The green half runs over the
# real tree; the red half over a two-file scratch world, so a checker that stops matching cannot pass.
echo "== every file reference in a shipped prompt resolves =="
set +e
fr_out=$(python3 "$KIT_ROOT/tests/skills/check-file-refs.py" 2>&1); fr_rc=$?
set -e
if [ "$fr_rc" -eq 0 ]; then echo "ok   [F1 real tree: $fr_out]"; else echo "FAIL: [F1 real tree] $fr_out"; fails=$((fails + 1)); fi
_fr="$WORK/file-refs"
run_file_refs_case() {  # <label> <expect: pass|fail> <marker> <SKILL.md body>
  local label="$1" expect="$2" marker="$3" body="$4"
  rm -rf "$_fr"; mkdir -p "$_fr/skills/demo/references"
  printf 'x\n' > "$_fr/skills/demo/references/real.md"
  printf '%s\n' "$body" > "$_fr/skills/demo/SKILL.md"
  local out rc; set +e; out=$(python3 "$KIT_ROOT/tests/skills/check-file-refs.py" "$_fr" 2>&1); rc=$?; set -e
  if [ "$expect" = fail ] && [ "$rc" -ne 0 ] && grep -q "$marker" <<<"$out"; then echo "ok   [$label] rejected"
  elif [ "$expect" = pass ] && [ "$rc" -eq 0 ]; then echo "ok   [$label] accepted"
  else echo "FAIL: [$label] rc=$rc $out"; fails=$((fails + 1)); fi
}
run_file_refs_case "F2 dead markdown link            " fail "references/gone.md" 'see [it](references/gone.md) and [ok](references/real.md)'
run_file_refs_case "F3 dead backticked kit path      " fail "scripts/gone.sh" 'run `scripts/gone.sh`, see `references/real.md`'
run_file_refs_case "F4 dead path inside a fence      " pass "" '```
`scripts/gone.sh`
```'
run_file_refs_case "F5 target-repo and placeholder   " pass "" 'edit `.github/workflows/ci.yml`, `{kit}/scripts/x.sh`, `/abs/x.sh`'

echo "== guarded-pr-merge.sh is spelled from <kit>/, and a missing guard never licenses a raw gh pr merge (#512) =="
# A cwd-relative `skills/merge-pr/scripts/guarded-pr-merge.sh` resolves only in the kit's own
# checkout; in a consumer repository it names nothing, and a sub-agent that could not find the guard
# fell back to a raw `gh pr merge` (#512). So the three guard-invocation sites spell it from `<kit>/`,
# and guard-invocation.md's "Never fall back" sentence names `gh pr merge` beside the three git
# writes. Written to a file first, never a heredoc inside `$( … )` (#131).
_pscratch=$(kit_scratch)
cat > "$_pscratch/pr-merge-spelling.py" <<'PY'
import pathlib, sys
kit, mode = pathlib.Path(sys.argv[1]), sys.argv[2]
GUARD = "skills/merge-pr/scripts/guarded-pr-merge.sh"
SITES = ("skills/merge-pr/SKILL.md", "skills/merge-pr/references/steps/05-merge.md",
         "skills/auto-dev/SKILL.md")
FALLBACK = "skills/_shared/guard-invocation.md"
def lines(rel):
    return enumerate((kit / rel).read_text(encoding="utf-8").splitlines(), 1)
bad = []
if mode == "kit-prefix":
    for rel in SITES:
        for n, line in lines(rel):
            i = line.find(GUARD)
            while i >= 0:
                if not line[:i].endswith("<kit>/"):
                    bad.append("%s:%d" % (rel, n))
                i = line.find(GUARD, i + 1)
    what = "spells %s without a <kit>/ prefix" % GUARD
else:
    # The whole bold sentence, whitespace-normalised, so a re-wrap cannot move `gh pr merge` off
    # the one physical line being read.
    text = (kit / FALLBACK).read_text(encoding="utf-8")
    i = text.find("Never fall back")
    if i < 0:
        bad = [FALLBACK + ": no 'Never fall back' sentence at all"]
    else:
        j = text.find(".**", i)
        sentence = " ".join(text[i:j if j > 0 else len(text)].split())
        if "gh pr merge" not in sentence:
            bad = ["%s:%d" % (FALLBACK, text.count("\n", 0, i) + 1)]
    what = "its 'Never fall back' sentence does not name gh pr merge"
if bad:
    sys.exit("%s — %s" % (", ".join(bad), what))
print("ok")
PY
pm_case() { # <label> <root> <mode: kit-prefix|fallback> <expect: pass|fail> [marker a refusal must name]
  local out rc; set +e; out=$(python3 "$_pscratch/pr-merge-spelling.py" "$2" "$3" 2>&1); rc=$?; set -e
  if [ "$4" = pass ] && [ "$rc" -eq 0 ]; then echo "ok   [$1]"
  elif [ "$4" = fail ] && [ "$rc" -ne 0 ] && grep -qF -e "${5:-}" <<<"$out"; then echo "ok   [$1] refused: $out"
  else echo "FAIL: [$1] rc=$rc $out"; fails=$((fails + 1)); fi
}
pm_case "PM1 the three sites spell <kit>/skills/merge-pr/scripts/guarded-pr-merge.sh" "$KIT_ROOT" kit-prefix pass
pm_case "PM2 guard-invocation.md's Never fall back names gh pr merge" "$KIT_ROOT" fallback pass
# The red half: the same four files with the prefix and the gh clause stripped must be refused, BY
# LINE — a check no case can drive red stays green after it stops matching.
for rel in skills/merge-pr/SKILL.md skills/merge-pr/references/steps/05-merge.md \
           skills/auto-dev/SKILL.md skills/_shared/guard-invocation.md; do
  mkdir -p "$_pscratch/drift/$(dirname "$rel")"
  sed -e 's#<kit>/skills/merge-pr/scripts/guarded-pr-merge#skills/merge-pr/scripts/guarded-pr-merge#g' \
      -e 's# or a raw `gh pr merge`##' "$KIT_ROOT/$rel" > "$_pscratch/drift/$rel"
done
pm_case "PM3 a bare spelling is refused, naming file:line" "$_pscratch/drift" kit-prefix fail "05-merge.md:"
pm_case "PM4 a Never fall back without gh pr merge is refused" "$_pscratch/drift" fallback fail "guard-invocation.md:"

echo "== every migrate-legacy file that invokes archify names its mermaid fallback (#476) =="
# Archify is a RECOMMENDED session capability (requirements.json `sessionSkills`), so a host without
# it must still get a picture: the migration phases fall back to the mermaid fence they already
# build as the archify spec's own companion. That degradation holds only if it is WRITTEN where the
# invocation is — a file naming archify and not mermaid is one a session would follow into a hard
# stop or a silent omission, which is exactly what `level: recommended` promises never happens.
# Same shape as case SP1: the defect IS the committed prose, so the green half scans the real tree
# and the red half a mutated copy of it.
#
# The mutation replaces the mermaid TOKEN rather than deleting its line. Prose wraps, and a
# `/mermaid/d` would delete the archify mention along with it on any line carrying both — the
# fixture would then stop naming archify at all and the guard would pass it for the wrong reason.
archify_fallback_check() {   # <a skills/migrate-legacy tree> → 0 clean · 1 offenders · 2 vacuous
  local root="$1" offenders="" named=0 f
  for f in "$root"/SKILL.md "$root"/references/*.md; do
    [ -f "$f" ] || continue
    grep -qi 'archify' "$f" || continue
    named=$((named + 1))
    grep -qi 'mermaid' "$f" || offenders="$offenders ${f#$root/}"
  done
  if [ -n "$offenders" ]; then
    echo "names archify with no mermaid fallback:$offenders"
    return 1
  fi
  # A guard with nothing to check must say so. Without this, deleting every archify mention from the
  # pipeline would read as "all clear" forever — the one way this case could pass vacuously.
  [ "$named" -gt 0 ] || { echo "no file under $root names archify at all"; return 2; }
  echo "$named file(s) name archify, each with its mermaid fallback"
  return 0
}
set +e
af_out=$(archify_fallback_check "$KIT_ROOT/skills/migrate-legacy" 2>&1); af_rc=$?
set -e
if [ "$af_rc" -eq 0 ]; then
  echo "ok   [A1 shipped tree: $af_out]"
else
  echo "FAIL: [A1 shipped tree names archify with its fallback] rc=$af_rc $af_out"
  fails=$((fails + 1))
fi
_ascratch=$(kit_scratch)
mkdir -p "$_ascratch/migrate-legacy/references"
sed 's/[Mm]ermaid/diagram-fence/g' "$KIT_ROOT/skills/migrate-legacy/SKILL.md" \
  > "$_ascratch/migrate-legacy/SKILL.md"
for f in "$KIT_ROOT"/skills/migrate-legacy/references/*.md; do
  sed 's/[Mm]ermaid/diagram-fence/g' "$f" > "$_ascratch/migrate-legacy/references/$(basename "$f")"
done
set +e
af_red=$(archify_fallback_check "$_ascratch/migrate-legacy" 2>&1); af_red_rc=$?
set -e
if [ "$af_red_rc" -eq 1 ] && grep -q 'phase-1-assess.md' <<<"$af_red"; then
  echo "ok   [A2 a stripped fallback is refused, naming the file]"
else
  echo "FAIL: [A2 a stripped fallback is refused, naming the file] rc=$af_red_rc $af_red"
  fails=$((fails + 1))
fi

echo "== every sessionSkills entry has a node in ARCHITECTURE.md's External dependencies graph (#476) =="
# requirements.json is the single source of truth for prerequisites, and ARCHITECTURE.md is where the
# kit draws them. A manifest entry with no node is a dependency the architecture does not admit to
# having — which is exactly how `archify` could end up declared, reported by preflight and explained
# in the README while the one picture of the kit's dependencies still showed four session skills.
#
# Only the *External dependencies* graph is read. The `## Skill call graph` fence is parsed by
# scripts/recap-wiring-check.py as a CI gate, and nothing here may touch it.
# Written to a file first, never a heredoc inside `$( … )` (#131, the bash 3.2 scanner hazard).
_dscratch=$(kit_scratch)
cat > "$_dscratch/session-skill-nodes.py" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
manifest = json.load(open(root / "requirements.json", encoding="utf-8"))
names = [s["name"] for s in manifest["sessionSkills"]]
if not names:
    sys.exit("requirements.json declares no sessionSkills at all — nothing to check")
text = (root / "ARCHITECTURE.md").read_text(encoding="utf-8")
m = re.search(r"^## External dependencies.*?(?=^## |\Z)", text, re.S | re.M)
if not m:
    sys.exit("ARCHITECTURE.md has no '## External dependencies' section")
section = m.group(0)
missing = [n for n in names if n not in section]
if missing:
    sys.exit("sessionSkills with no node in the External dependencies graph: " + ", ".join(missing))
print("%d session skill(s), each with a node" % len(names))
PY
set +e
ss_out=$(python3 "$_dscratch/session-skill-nodes.py" "$KIT_ROOT" 2>&1); ss_rc=$?
set -e
if [ "$ss_rc" -eq 0 ]; then
  echo "ok   [SS1 shipped tree: $ss_out]"
else
  echo "FAIL: [SS1 every sessionSkills entry has a node] $ss_out"
  fails=$((fails + 1))
fi
# The red half: delete the archify node from a scratch copy and the check must refuse, naming it.
# The cmp guard is load-bearing, not decoration — a fixture that did not actually change would leave
# this case green for a reason unrelated to what it claims to measure (cf. case C2 above).
mkdir -p "$_dscratch/drift"
cp "$KIT_ROOT/requirements.json" "$_dscratch/drift/requirements.json"
sed '/ARCHIFY\[/d' "$KIT_ROOT/ARCHITECTURE.md" > "$_dscratch/drift/ARCHITECTURE.md"
if cmp -s "$KIT_ROOT/ARCHITECTURE.md" "$_dscratch/drift/ARCHITECTURE.md"; then
  echo "FAIL: [SS2 a deleted node is refused, naming the skill] the fixture did not drift — there is"
  echo "      no 'ARCHIFY[' node line in ARCHITECTURE.md to delete"
  fails=$((fails + 1))
else
  set +e
  ss_red=$(python3 "$_dscratch/session-skill-nodes.py" "$_dscratch/drift" 2>&1); ss_red_rc=$?
  set -e
  if [ "$ss_red_rc" -ne 0 ] && grep -q 'archify' <<<"$ss_red"; then
    echo "ok   [SS2 a deleted node is refused, naming the skill]"
  else
    echo "FAIL: [SS2 a deleted node is refused, naming the skill] rc=$ss_red_rc $ss_red"
    fails=$((fails + 1))
  fi
fi

# --- every review/ADR diff range resolves against origin/main, not a local main (#601) -----------
#
# Nothing in the kit advances the main checkout's local `main` ref, so in a long-lived clone it
# drifts arbitrarily far behind `origin/main` and every hardcoded `main...HEAD` silently resolves
# against the stale one. Measured on one fleet run (2026-09-13): local `main` 30 commits behind, a
# reviewer handed a ~92-file diff, another 115 files — a reviewer that does not notice reviews
# already-merged code, finds nothing wrong with it, and reports a FALSE CLEAN on the gate whose
# whole job is catching what CI cannot. Two of the sites persisted the wrong diff to a FILE that
# reviewers then read byte-for-byte; one fed `suggest_adr_from_change`.
#
# Seven copies accumulated because nothing pinned them. This is that pin.
#
# The two exemptions are deliberate and must stay readable as such:
#   * skills/debug-issue/SKILL.md      — explains two-dot vs three-dot on purpose
#   * skills/merge-pr/.../06-follow-ups.md — says explicitly NOT to use `git diff main...HEAD`
# Both are named here, so an exemption is a decision on the record rather than a silent hole.
# `origin/main...HEAD` CONTAINS `main...HEAD`, so a plain grep matches every corrected line too.
# The corrected spellings are blanked out first, and whatever still names a range is by definition
# a bare one. Both dot-forms are pinned: the two-dot `main..HEAD` commit list handed to the same
# reviewer resolves against the same stale ref, and is the same defect.
o1_hits="$WORK/stale-range-hits"
: > "$o1_hits"
# Every file, not just *.md: eight scripts live under skills/implement-issue/scripts/, and a script
# is the one place a stale ref would actually EXECUTE rather than be copied out by a reader.
for o1_f in $(find "$KIT_ROOT/skills/implement-issue" -type f); do
  sed 's|origin/main\.\.\.HEAD||g; s|origin/main\.\.HEAD||g' "$o1_f"     | grep -n 'main\.\.\.HEAD\|main\.\.HEAD'     | sed "s|^|${o1_f#$KIT_ROOT/}:|" >> "$o1_hits" || :
done
if [ -s "$o1_hits" ]; then
  echo "FAIL: [O1 no stale main..HEAD under skills/implement-issue (#601)]"
  sed 's/^/      /' "$o1_hits"
  echo "      Use 'origin/main...HEAD', and fetch before diffing — a local 'main' is never advanced"
  echo "      by the kit, so these resolve against whatever the clone last happened to leave there."
  fails=$((fails + 1))
else
  echo "ok   [O1 no stale main..HEAD under skills/implement-issue (#601)]"
fi

# The exemptions are asserted to still EXIST, so that deleting one silently narrows the rule rather
# than announcing it — the same reason the rule above is a grep and not a convention.
o2_missing=""
for o2_f in "skills/debug-issue/SKILL.md" "skills/merge-pr/references/steps/06-follow-ups.md"; do
  # Blanked the same way O1 blanks, and for the same reason: `origin/main...HEAD` CONTAINS
  # `main...HEAD`, so a plain grep here would still pass after someone "corrected" an exemption —
  # the one edit that actually destroys it. What must survive is a BARE range.
  # Captured into a variable first, then read via a herestring: a `grep -q` fed by a STREAMING
  # producer under pipefail is the race scripts/sigpipe-idiom-check.py refuses (it closes the
  # pipe on its first match and the producer dies on SIGPIPE). An assignment has nothing to
  # close early. Same remedy the gate itself prints.
  o2_text=$(sed 's|origin/main\.\.\.HEAD||g; s|origin/main\.\.HEAD||g' "$KIT_ROOT/$o2_f")
  grep -q 'main\.\.\.HEAD\|main\.\.HEAD' <<<"$o2_text" || o2_missing="$o2_missing $o2_f"
done
if [ -n "$o2_missing" ]; then
  echo "FAIL: [O2 the two deliberate main...HEAD mentions survive (#601)] gone from:$o2_missing"
  echo "      These two discuss the idiom on purpose. If one genuinely no longer needs to, drop it"
  echo "      from this case's list in the same commit, so the exemption stays a decision."
  fails=$((fails + 1))
else
  echo "ok   [O2 the two deliberate main...HEAD mentions survive (#601)]"
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "one-trigger-home golden test: all cases behaved as specified"
