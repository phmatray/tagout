#!/usr/bin/env bash
# Golden test for skills/auto-dev/scripts/decision-tally.sh (#318) — the markdown tally over
# decide.sh's event log that auto-dev Step 6's mandatory `lessons` block pastes.
#
# Sections 1-5 are the script's own contract (Spec's four validation cases, plus the malformed-only
# edge decision-tally.sh's own header documents). Section 6 pins Step 6 / the retro taxonomy once
# Task 2 lands them — added there rather than in a second suite, since ci-wiring-check.py refuses a
# suite with no enforcing CI step and this one is already wired.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT_ROOT="$(pwd)"
TALLY="./skills/auto-dev/scripts/decision-tally.sh"
[ -x "$TALLY" ] || { echo "FAIL: $TALLY missing or not executable"; exit 1; }

. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
kit_guard kit_guard_samples_unchanged

WORK=$(kit_scratch)

# ------------------------------------------------------------------ 1. table + flags + footer
#
# The exact three rows the issue's own Spec illustrates, plus one malformed (non-JSON) line. Every
# event in the fixture shares ONE program hash, so "events since program change" == the total valid
# event count (67) — decision-tally.sh reports it as "how many events carry the log's most recent
# program hash", and a fixture with a single hash throughout makes that figure the whole count,
# which is what the Spec's own example shows.
PROG="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
FIXTURE="$WORK/events.jsonl"
{
  # 20 merge.step4/sync events, all ONE input hash -> repeat-poll (distinct=1 <= 20/5=4)
  for i in $(seq 1 20); do
    printf '{"v":1,"ts":"2026-08-01T00:00:%02dZ","decision":"merge.step4","verdict":"sync","rule":"r1","program":"%s","input_sha256":"sameinputhash0000000000000000000000000000000000000000000000"}\n' \
      "$((i % 60))" "$PROG"
  done
  # 7 merge.step4/merge events, 7 DISTINCT input hashes -> no flag
  for i in $(seq 1 7); do
    printf '{"v":1,"ts":"2026-08-01T01:00:%02dZ","decision":"merge.step4","verdict":"merge","rule":"r2","program":"%s","input_sha256":"input%02d0000000000000000000000000000000000000000000000000"}\n' \
      "$((i % 60))" "$PROG" "$i"
  done
  # 40 ci.verdict/pending events, 38 distinct input hashes (two repeats) -> systematic
  # (distinct=38 >= 40*0.8=32, verdict "pending" is non-terminal)
  for i in $(seq 1 40); do
    d="$i"
    [ "$i" -eq 39 ] && d=1
    [ "$i" -eq 40 ] && d=2
    printf '{"v":1,"ts":"2026-08-01T02:00:%02dZ","decision":"ci.verdict","verdict":"pending","rule":"r3","program":"%s","input_sha256":"civ%030d"}\n' \
      "$((i % 60))" "$PROG" "$d"
  done
  echo 'this line is not JSON at all'
} > "$FIXTURE"

expected=$(cat <<'EXPECTED'
| decision    | verdict | events | distinct inputs | programs | flag        |
|-------------|---------|-------:|----------------:|---------:|-------------|
| merge.step4 | sync    |     20 |               1 |        1 | repeat-poll |
| merge.step4 | merge   |      7 |               7 |        1 |             |
| ci.verdict  | pending |     40 |              38 |        1 | systematic  |
EXPECTED
)
out=$("$TALLY" "$FIXTURE")
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [table]: expected exit 0, got $rc"; echo "$out"; exit 1; }
table=$(printf '%s\n' "$out" | head -5)
[ "$table" = "$expected" ] || {
  echo "FAIL [table]: table does not match"; echo "--- got ---"; echo "$out"; echo "--- want ---"; echo "$expected"; exit 1
}
footer=$(printf '%s\n' "$out" | tail -1)
case "$footer" in
  "malformed lines: 1 · log: $FIXTURE · events since program change: 67 · non-terminal: fix-check,needs-approval,pending,sync,wait (registry)") : ;;
  *) echo "FAIL [table]: unexpected footer: $footer"; exit 1 ;;
esac
echo "  ok: table+flags+footer — repeat-poll, no flag, and systematic all fire on the Spec's own numbers"

# --------------------------------------------------------------------------------- 2. empty log
: > "$WORK/empty.jsonl"
out=$("$TALLY" "$WORK/empty.jsonl") ; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [empty]: expected exit 0, got $rc"; exit 1; }
[ "$out" = "no decision events" ] || { echo "FAIL [empty]: got '$out'"; exit 1; }
echo "  ok: empty log -> 'no decision events', exit 0"

# ---------------------------------------------------------- 3. missing default log, no argument
# A fresh repo with no .claude/decision-events.jsonl and no $KIT_DECISION_LOG: the default
# resolution finds nothing to read, which is the same valid state as an empty file, never an error.
REPO_NO_LOG="$WORK/no-log-repo"
mkdir -p "$REPO_NO_LOG"
git -C "$REPO_NO_LOG" init -q
out=$(cd "$REPO_NO_LOG" && env -u KIT_DECISION_LOG "$KIT_ROOT/$TALLY")
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [missing-default]: expected exit 0, got $rc"; exit 1; }
[ "$out" = "no decision events" ] || { echo "FAIL [missing-default]: got '$out'"; exit 1; }
echo "  ok: no default log and no argument -> 'no decision events', exit 0"

# -------------------------------------------------------------------- 4. malformed-only log
# Every line fails to parse as a taggable decision event: nothing to tally, same message as empty.
MALFORMED_ONLY="$WORK/malformed-only.jsonl"
printf 'not json\nalso not json\n{"decision":"x"}\n' > "$MALFORMED_ONLY"
out=$("$TALLY" "$MALFORMED_ONLY"); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [malformed-only]: expected exit 0, got $rc"; exit 1; }
[ "$out" = "no decision events" ] || { echo "FAIL [malformed-only]: got '$out'"; exit 1; }
echo "  ok: a log with only malformed lines -> 'no decision events', exit 0 (never fatal)"

# --------------------------------------------------------------------- 5. jq missing on PATH
# A PATH reduced to just enough to run the script's own shell built-ins plus bash itself: jq is
# genuinely absent, and the script must name it rather than fail on some downstream symptom.
STUB="$WORK/stub-bin"
mkdir -p "$STUB"
for c in bash cat mktemp rm awk git dirname; do
  p=$(command -v "$c") && ln -sf "$p" "$STUB/$c"
done
rc=0
out=$(PATH="$STUB" "$TALLY" "$FIXTURE" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [no-jq]: expected exit 2, got $rc"; echo "$out"; exit 1; }
grep -qi 'jq' <<<"$out" || { echo "FAIL [no-jq]: jq not named in the refusal: $out"; exit 1; }
echo "  ok: jq missing from PATH -> exit 2, naming jq"

# ------------------------------------------------------------------------- 6. usage error
rc=0
out=$("$TALLY" one two 2>&1) || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [usage]: expected exit 2 for two positional args, got $rc"; echo "$out"; exit 1; }
echo "  ok: two positional arguments -> exit 2 (usage error)"

# --------------------------------------------------------------------- 7. --help / thresholds
help_out=$("$TALLY" --help)
for needle in "repeat-poll" "systematic" "events / 5" "events \* 0.8"; do
  grep -qE -- "$needle" <<<"$help_out" || {
    echo "FAIL [help]: --help does not print the threshold text matching /$needle/"; exit 1
  }
done
echo "  ok: --help prints both flag names and their thresholds"

# ------------------------------------------------------- 8. Step 6's mandatory `lessons` block
#
# Prose pins, not behavior: SKILL.md Step 6 must actually SAY the block is mandatory, name the
# script that fills its table, and name the one accepted empty form — a step that merely alludes to
# "lessons learned" without these three anchors is exactly the free-prose outcome the issue rejects.
SKILL="$(kit_skill_prose "$KIT_ROOT" auto-dev)"   # router + references/steps/*.md
[ -f "$SKILL" ] || { echo "FAIL [lessons]: $SKILL missing"; exit 1; }
for needle in 'lessons:' 'decision-tally\.sh' 'lessons: none'; do
  grep -qE -- "$needle" "$SKILL" || {
    echo "FAIL [lessons]: $SKILL Step 6 does not contain /$needle/"; exit 1
  }
done
grep -qi 'a run without a `lessons` block is a run that was not finished' "$SKILL" || {
  echo "FAIL [lessons]: $SKILL is missing the Gotchas bullet naming an unfinished run"; exit 1
}
echo "  ok: SKILL.md Step 6 makes the lessons block mandatory, names decision-tally.sh, and the Gotchas bullet"

# ------------------------------------------------------------------- 9. the seven retro categories
#
# retro-taxonomy.md must carry EXACTLY seven `## ` headings, spelled exactly as the issue maps them
# from mattpocock/skills `retro` — a taxonomy that silently grows an eighth category or loses one
# stops being the fixed vocabulary the issue exists to give auto-dev.
TAXONOMY="skills/auto-dev/references/retro-taxonomy.md"
[ -f "$TAXONOMY" ] || { echo "FAIL [taxonomy]: $TAXONOMY missing"; exit 1; }
heading_count=$(grep -c '^## ' "$TAXONOMY")
[ "$heading_count" -eq 7 ] || {
  echo "FAIL [taxonomy]: $TAXONOMY has $heading_count '## ' headings, expected exactly 7"; exit 1
}
for cat in navigation automated-checks coding-standards steering tool-economy no-ops information-access; do
  grep -qE "^## .*\`?$cat\`?" "$TAXONOMY" || {
    echo "FAIL [taxonomy]: $TAXONOMY is missing the '$cat' heading"; exit 1
  }
done
grep -qi 'mattpocock/skills' "$TAXONOMY" || {
  echo "FAIL [taxonomy]: $TAXONOMY does not credit mattpocock/skills"; exit 1
}
grep -qi 'MIT' "$TAXONOMY" || {
  echo "FAIL [taxonomy]: $TAXONOMY does not name the MIT license"; exit 1
}
echo "  ok: retro-taxonomy.md carries exactly the seven named categories, credited to mattpocock/skills (MIT)"

# ------------------------------------------------------ 10. the non-terminal set comes from the
# registry (#378). A scratch copy of the kit — the script resolves the registry from its own
# location — whose registry declares a NEW non-terminal word (`retry`) makes `systematic` fire on
# it, with no change to the script; and a registry the script cannot read is NAMED in the footer,
# never silently read as the real set.
NT_KIT="$WORK/nt-kit"
mkdir -p "$NT_KIT/skills/auto-dev/scripts" "$NT_KIT/decisions"
cp "$TALLY" "$NT_KIT/skills/auto-dev/scripts/decision-tally.sh"
cat > "$NT_KIT/decisions/registry.json" <<'JSON'
{"decisions":[{"id":"x.y","verdict":{"vocabulary":["retry","done"],"nonTerminal":["retry"]}}],"not_decisions":{}}
JSON
NT_LOG="$WORK/nt-events.jsonl"
: > "$NT_LOG"
for i in $(seq 1 6); do
  printf '{"v":1,"ts":"2026-08-01T03:00:%02dZ","decision":"x.y","verdict":"retry","rule":"r","program":"p","input_sha256":"nt%03d"}\n' "$i" "$i" >> "$NT_LOG"
done
out=$("$NT_KIT/skills/auto-dev/scripts/decision-tally.sh" "$NT_LOG")
retry_row=$(printf '%s\n' "$out" | grep -E '^\| x\.y +\| retry ' || true)
grep -q 'systematic' <<<"$retry_row" \
  || { echo "FAIL [registry-nonterminal]: a registry-declared non-terminal word ('retry') did not trip systematic:"; echo "$out"; exit 1; }
grep -qF 'non-terminal: retry (registry)' <<<"$out" \
  || { echo "FAIL [registry-nonterminal]: the footer does not name the registry's set:"; echo "$out"; exit 1; }
echo "  ok: registry-nonterminal — a new nonTerminal word in the registry trips systematic with no script change"

rm -f "$NT_KIT/decisions/registry.json"
out=$("$NT_KIT/skills/auto-dev/scripts/decision-tally.sh" "$NT_LOG")
grep -qF '(fallback' <<<"$out" \
  || { echo "FAIL [registry-unreadable]: an unreadable registry is not named as a fallback in the footer:"; echo "$out"; exit 1; }
retry_row=$(printf '%s\n' "$out" | grep -E '^\| x\.y +\| retry ' || true)
grep -q 'systematic' <<<"$retry_row" \
  && { echo "FAIL [registry-unreadable]: 'retry' tripped systematic without a registry declaring it"; exit 1; }
echo "  ok: registry-unreadable — the fallback set is used and named, and an undeclared word does not trip"

echo "decision-tally golden test OK"
