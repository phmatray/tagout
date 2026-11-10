#!/usr/bin/env bash
# Golden test for skills/auto-dev/scripts/usage_report.py's transcript discovery (#281) and, since
# 2.0, for measure_phase2.py's by-issue pairing of the two sub-agent transcripts a worker leaves (#314).
#
# The bug: the script discovered sessions with one glob, `<proj>/*.jsonl`, which matches only the
# transcripts sitting DIRECTLY in the project directory. A worker dispatched via the Agent tool
# writes its transcript to `<proj>/<session-id>/subagents/agent-*.jsonl` instead — a layout the
# glob never opens, and nothing in the output said so. Measured on this repo's own 2026-08-27
# fleet run: 21 sub-agent transcripts carrying 86% of the run's tokens were silently invisible,
# and the ORCHESTRATOR vs WORKERS split was wrong in exactly the direction that flatters the
# orchestrator's share.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

SCRIPT="$KIT/skills/auto-dev/scripts/usage_report.py"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing"; exit 1; }
PHASE2="$KIT/skills/auto-dev/scripts/measure_phase2.py"
[ -f "$PHASE2" ] || { echo "FAIL: $PHASE2 missing"; exit 1; }

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

# ------------------------------------------------------------------------------- fixture builders
#
# Each transcript line only needs a `message.model` + `message.usage` object — scan() in
# usage_report.py reads nothing else. measure_phase2.py additionally reads an assistant turn's
# text (the worker's report line, #314) and tool_use blocks (the pre-2.0 merge-pr handoff).
write_usage_line() {
  # $1 = out file (appended), $2 = model, $3..$6 = input/output/cacheWrite/cacheRead,
  # $7 = optional assistant text, $8 = optional tool name (a `Skill merge-pr` tool_use block)
  local out="$1" model="$2" tin="$3" tout="$4" tcw="$5" tcr="$6" text="${7:-}" tool="${8:-}"
  python3 - "$out" "$model" "$tin" "$tout" "$tcw" "$tcr" "$text" "$tool" <<'PY'
import json, sys
out, model, tin, tout, tcw, tcr, text, tool = sys.argv[1:9]
rec = {
    "type": "assistant",
    "message": {
        "model": model,
        "usage": {
            "input_tokens": int(tin),
            "output_tokens": int(tout),
            "cache_creation_input_tokens": int(tcw),
            "cache_read_input_tokens": int(tcr),
        },
    },
}
content = []
if text:
    content.append({"type": "text", "text": text})
if tool:
    content.append({"type": "tool_use", "id": "t1", "name": tool, "input": {"skill": "merge-pr"}})
if content:
    rec["message"]["role"] = "assistant"
    rec["message"]["content"] = content
with open(out, "a") as f:
    f.write(json.dumps(rec) + "\n")
PY
}

write_user_line() {
  # $1 = out file (appended), $2 = text — exercises first_user_label()'s string-content branch.
  python3 - "$1" "$2" <<'PY'
import json, sys
out, text = sys.argv[1], sys.argv[2]
rec = {"type": "user", "message": {"role": "user", "content": text}}
with open(out, "a") as f:
    f.write(json.dumps(rec) + "\n")
PY
}

MODEL="claude-sonnet-4-5-20250929"

# ------------------------------------------------------------------------- two-kind (the bug)
#
# top session "sess-main": input 1500 | output 300 | cacheWrite 50  | cacheRead 15 → 1,865 tok
# sub session "agent-a1" (parent sess-main): input 2000 | output 400 | cacheWrite 100 | cacheRead 20 → 2,520 tok
# sub session "agent-w1" — workflow-nested, at sess-main/subagents/workflows/wf_test1/ (#309):
#     input 1000 | output 200 | cacheWrite 50 | cacheRead 10 → 1,260 tok
# grand total: 5,645 tok, across 3 sessions (1 top-level, 2 sub-agent).
PROJ1=$(kit_scratch)
write_usage_line "$PROJ1/sess-main.jsonl" "$MODEL" 1000 200 50 10
write_usage_line "$PROJ1/sess-main.jsonl" "$MODEL" 500  100 0  5

mkdir -p "$PROJ1/sess-main/subagents"
write_user_line  "$PROJ1/sess-main/subagents/agent-a1.jsonl" "the raw first-user text — must lose to the meta.json description below"
write_usage_line "$PROJ1/sess-main/subagents/agent-a1.jsonl" "$MODEL" 2000 400 100 20
cat > "$PROJ1/sess-main/subagents/agent-a1.meta.json" <<'JSON'
{"agentType": "general-purpose", "description": "measure sub-agent token share"}
JSON

# A sub-agent dispatched through the `Workflow` tool nests one level deeper, under
# `subagents/workflows/wf_<id>/` (#309). Same `.jsonl` + sibling `.meta.json` shape, and its
# `parent` is still the TOP-LEVEL session two directories above `workflows/`, not the `wf_*` id.
mkdir -p "$PROJ1/sess-main/subagents/workflows/wf_test1"
write_user_line  "$PROJ1/sess-main/subagents/workflows/wf_test1/agent-w1.jsonl" "raw workflow-nested first-user text — must lose to its meta.json description"
write_usage_line "$PROJ1/sess-main/subagents/workflows/wf_test1/agent-w1.jsonl" "$MODEL" 1000 200 50 10
cat > "$PROJ1/sess-main/subagents/workflows/wf_test1/agent-w1.meta.json" <<'JSON'
{"agentType": "general-purpose", "description": "workflow-nested sub-agent"}
JSON

OUT1=$(kit_scratch)/out.txt
python3 "$SCRIPT" "$PROJ1" --main sess-main > "$OUT1" 2>&1 || {
  echo "FAIL: usage_report.py exited non-zero on the two-kind fixture"; cat "$OUT1"; exit 1; }

# The grand total is the SUM of both files, not the top-level file alone (the original bug).
grep -q "total tokens 5,645" "$OUT1" || {
  echo "FAIL: grand total is not the sum of the top-level AND every sub-agent transcript, workflow-nested included (expected 5,645)"
  cat "$OUT1"; exit 1; }

# Session count is 2 (both files counted), and the header states the top/sub-agent split rather
# than leaving it to be inferred from the row count.
grep -q "SESSIONS: 3 in $PROJ1" "$OUT1" || {
  echo "FAIL: header does not report 3 sessions"; cat "$OUT1"; exit 1; }
grep -q "(1 top-level, 2 sub-agent)" "$OUT1" || {
  echo "FAIL: header does not count the workflow-nested sub-agent in the top-level/sub-agent split"
  cat "$OUT1"; exit 1; }

# Every row is labelled with its kind, so the two are distinguishable in the listing. The
# session column truncates to 8 chars (usage_report.py's `r['sid'][:8]`), hence "sess-mai".
grep -qE '\btop\b.*sess-mai' "$OUT1" || {
  echo "FAIL: the top-level row is not marked with its kind"; cat "$OUT1"; exit 1; }
grep -qE '\bsub\b.*agent-a1' "$OUT1" || {
  echo "FAIL: the sub-agent row is not marked with its kind"; cat "$OUT1"; exit 1; }
grep -qE '\bsub\b.*agent-w1' "$OUT1" || {
  echo "FAIL: the workflow-nested sub-agent has no row (discover_transcripts() did not reach it)"
  cat "$OUT1"; exit 1; }

# The sub-agent row prefers its sibling .meta.json description over first_user_label()'s text.
grep -q "measure sub-agent token share" "$OUT1" || {
  echo "FAIL: sub-agent row does not use the sibling .meta.json description as its label"
  cat "$OUT1"; exit 1; }
if grep -q "must lose to the meta.json description" "$OUT1"; then
  echo "FAIL: sub-agent row fell back to first_user_label() despite a sibling .meta.json existing"
  cat "$OUT1"; exit 1
fi
# row_label() is unchanged by #309 — the .meta.json sibling works at the deeper depth too.
grep -q "workflow-nested sub-agent" "$OUT1" || {
  echo "FAIL: workflow-nested row does not use its sibling .meta.json description as its label"
  cat "$OUT1"; exit 1; }

# ORCHESTRATOR vs WORKERS: the sub-agent's tokens land on the WORKER side even though its parent
# session ("sess-main") IS the orchestrator named by --main — attributing them to the parent would
# restate the original under-count in the other direction, just with a smaller error.
if ! python3 - "$OUT1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"orchestrator\s*:\s*\$([\d.]+)", text)
w = re.search(r"workers\+other:\s*\$([\d.]+)", text)
assert m and w, "ORCHESTRATOR vs WORKERS section missing"
orch, work = float(m.group(1)), float(w.group(1))
# Sonnet rates: (3.0, 15.0, 3.75, 0.30) $/1M tok, applied per session.
top_cost = (1500*3.0 + 300*15.0 + 50*3.75 + 15*0.30) / 1e6
sub_cost = (2000*3.0 + 400*15.0 + 100*3.75 + 20*0.30) / 1e6
# The workflow-nested sub-agent's parent is sess-main (the orchestrator) too, and its tokens
# belong to the worker side just the same (#309).
wf_cost  = (1000*3.0 + 200*15.0 + 50*3.75 + 10*0.30) / 1e6
assert abs(orch - top_cost) < 0.01, f"orchestrator cost {orch} != top-level-only {top_cost}"
assert abs(work - (sub_cost + wf_cost)) < 0.01, f"workers cost {work} != sub-agent total {sub_cost + wf_cost} (parent-of-sub is the orchestrator, but its tokens are a worker's \u2014 and the workflow-nested one counts)"
PY
then
  echo "FAIL: ORCHESTRATOR vs WORKERS split did not attribute the sub-agent's tokens to the worker side"
  cat "$OUT1"; exit 1
fi
echo "ok: two-kind — top-level + Agent-tool sub-agents (flat AND workflow-nested) all counted, summed, labelled, and split correctly"

# --------------------------------------------------------------- top-only (no subagents/ dir)
#
# Zero sub-agent transcripts must be a PRINTED fact, not an absence that looks like completeness.
PROJ2=$(kit_scratch)
write_user_line  "$PROJ2/sess-solo.jsonl" "solo top-level session, no subagents dir anywhere"
write_usage_line "$PROJ2/sess-solo.jsonl" "$MODEL" 100 20 0 0

OUT2=$(kit_scratch)/out.txt
python3 "$SCRIPT" "$PROJ2" > "$OUT2" 2>&1 || {
  echo "FAIL: usage_report.py exited non-zero on the top-only fixture"; cat "$OUT2"; exit 1; }

grep -q "SESSIONS: 1 in $PROJ2" "$OUT2" || {
  echo "FAIL: header does not report 1 session for the top-only fixture"; cat "$OUT2"; exit 1; }
grep -q "(1 top-level, 0 sub-agent)" "$OUT2" || {
  echo "FAIL: zero sub-agent transcripts is not printed as a fact — looks like an omission instead"
  cat "$OUT2"; exit 1; }
echo "ok: top-only — a project dir with no subagents/ anywhere reports (1 top-level, 0 sub-agent), not silence"

# ------------------------------------------------ 2.0 fleet: orchestrator + two sub-agents per issue
#
# Since #314 a worker is TWO Agent-tool sub-agents per issue, both under the supervisor session's
# subagents/ dir: phase 1 (auto-dev-worker) ends with `PHASE1 | ISSUE: N | PR: n | STATUS: READY`,
# phase 2 (auto-dev-merge) with `ISSUE: N | PR: n | STATUS: MERGED …`. Nothing sits next to the
# orchestrator's transcript any more — `top` is the orchestrator alone.
#
# orchestrator "sess-orch": input 1000 | output 100 | cacheWrite 0 | cacheRead 0
# phase 1 "agent-a" (issue 7): 3 turns, cacheRead 1M + 2M + 3M = 6M   (implement half)
# phase 2 "agent-b" (issue 7): 2 turns, cacheRead 400K + 600K = 1M     (merge half, fresh: starts at 400K)
PROJ3=$(kit_scratch)
write_user_line  "$PROJ3/sess-orch.jsonl" "auto-dev supervisor: fleet of 1"
write_usage_line "$PROJ3/sess-orch.jsonl" "$MODEL" 1000 100 0 0
mkdir -p "$PROJ3/sess-orch/subagents"
write_user_line   "$PROJ3/sess-orch/subagents/agent-a.jsonl" "Invoke auto-dev-worker with args 7"
write_usage_line  "$PROJ3/sess-orch/subagents/agent-a.jsonl" "$MODEL" 100 10 0 1000000
write_usage_line  "$PROJ3/sess-orch/subagents/agent-a.jsonl" "$MODEL" 100 10 0 2000000
write_usage_line  "$PROJ3/sess-orch/subagents/agent-a.jsonl" "$MODEL" 100 10 0 3000000 \
  "PHASE1 | ISSUE: 7 | PR: 12 | STATUS: READY | DETAIL: all tasks landed. | FILED: none"
write_user_line   "$PROJ3/sess-orch/subagents/agent-b.jsonl" "Invoke auto-dev-merge with args 12"
write_usage_line  "$PROJ3/sess-orch/subagents/agent-b.jsonl" "$MODEL" 100 10 0 400000
write_usage_line  "$PROJ3/sess-orch/subagents/agent-b.jsonl" "$MODEL" 100 10 0 600000 \
  "ISSUE: 7 | PR: 12 | STATUS: MERGED | DETAIL: squash-merged. | FILED: none | WORKTREE: cleaned up"

OUT3=$(kit_scratch)/out.txt
python3 "$SCRIPT" "$PROJ3" --main sess-orch > "$OUT3" 2>&1 || {
  echo "FAIL: usage_report.py exited non-zero on the 2.0 fleet fixture"; cat "$OUT3"; exit 1; }
grep -q "(1 top-level, 2 sub-agent)" "$OUT3" || {
  echo "FAIL: 2.0 fleet — header does not report (1 top-level, 2 sub-agent)"; cat "$OUT3"; exit 1; }
if ! python3 - "$OUT3" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"orchestrator\s*:\s*\$([\d.]+)", text)
w = re.search(r"workers\+other:\s*\$([\d.]+)", text)
assert m and w, "ORCHESTRATOR vs WORKERS section missing"
orch, work = float(m.group(1)), float(w.group(1))
top_cost = (1000*3.0 + 100*15.0) / 1e6
sub_cost = (500*3.0 + 50*15.0 + 7_000_000*0.30) / 1e6
assert abs(orch - top_cost) < 0.01, f"orchestrator cost {orch} != top-level-only {top_cost}"
assert abs(work - sub_cost) < 0.01, f"workers cost {work} != both sub-agents {sub_cost}"
PY
then
  echo "FAIL: 2.0 fleet — both phase sub-agents were not attributed to WORKERS"; cat "$OUT3"; exit 1
fi

# Three more transcripts that must NOT disturb issue 7's row, each a real 2.0 shape:
#   agent-c — phase 1 of issue 8 spelled `ISSUE: #8` (the natural GitHub form; auto-dev-merge.md
#             never mandated bare digits), bolded, with a trailing "Done." turn after the report;
#   agent-d — phase 2 of issue 8 that invoked `Skill merge-pr` and then RETURNED A DEFERRAL (the
#             failure Step 4 recovers) — it has a handoff tool_use and no report line, and must not
#             be mis-read as a pre-2.0 "merge inside the implement session" row;
#   sess-orch's own final text quotes a report line at line start — the orchestrator is never a half.
write_usage_line "$PROJ3/sess-orch/subagents/agent-c.jsonl" "$MODEL" 100 10 0 500000 \
  "**PHASE1 | ISSUE: #8 | PR: #13 | STATUS: READY | DETAIL: done. | FILED: none**"
write_usage_line "$PROJ3/sess-orch/subagents/agent-c.jsonl" "$MODEL" 100 10 0 510000 "Done."
write_usage_line "$PROJ3/sess-orch/subagents/agent-d.jsonl" "$MODEL" 100 10 0 30000 "" "Skill"
write_usage_line "$PROJ3/sess-orch/subagents/agent-d.jsonl" "$MODEL" 100 10 0 31000 \
  "I'll pause here and wait for CI to finish."
write_usage_line "$PROJ3/sess-orch.jsonl" "$MODEL" 100 10 0 50000 \
  "Merged this run:
ISSUE: 7 | PR: 12 | STATUS: MERGED"

OUT4=$(kit_scratch)/phase2.txt
python3 "$PHASE2" "$PROJ3" > "$OUT4" 2>&1 || {
  echo "FAIL: measure_phase2.py exited non-zero on the 2.0 fleet fixture"; cat "$OUT4"; exit 1; }
# One row for issue 7: 3 implement turns / 6.0M, 2 merge turns / 1.0M, merge context starting at 400K.
grep -qE '#7[[:space:]]+3[[:space:]]+6\.0M[[:space:]]+2[[:space:]]+1\.0M[[:space:]]+400K' "$OUT4" || {
  echo "FAIL: measure_phase2.py did not pair issue 7's phase-1 and phase-2 sub-agents into one row (3/6.0M implement, 2/1.0M merge, 400K at merge start)"
  cat "$OUT4"; exit 1; }
grep -q "issues with both an implement and a merge half: 1$" "$OUT4" || {
  echo "FAIL: measure_phase2.py counted something other than issue 7 as a paired issue (the orchestrator's quoted report line, or the deferral)"
  cat "$OUT4"; exit 1; }
# Issue 8 is seen (its `ISSUE: #8` phase-1 report, bolded, followed by a stray "Done.") and reported
# as unpaired — its phase-2 agent returned a deferral, which is not a merge half.
grep -qE 'unpaired: 1 issue\(s\).*\(#8\)' "$OUT4" || {
  echo "FAIL: measure_phase2.py did not report issue 8 (ISSUE: #8, then a trailing 'Done.' turn) as the one unpaired issue"
  cat "$OUT4"; exit 1; }
if grep -q 'pre-2.0' "$OUT4"; then
  echo "FAIL: measure_phase2.py mis-read a 2.0 sub-agent (the phase-2 deferral with a merge-pr tool_use) as a pre-2.0 session"
  cat "$OUT4"; exit 1
fi
echo "ok: 2.0 fleet — orchestrator is the only top-level transcript, both phase sub-agents count as workers, and measure_phase2.py pairs them by issue"

# ------------------------------------------------------------- the no-positional forms (#354)
#
# The docstring's `--main <sid>` and `--top N` invocations, PROJECT_DIR auto-detected from $PWD:
# the first argv parser collected every non-`--` token as a positional, so `<sid>` was read as the
# project dir and the documented form failed with "project dir not found: <sid>". The fixture sits
# under a fake HOME at the encoded path of THIS cwd, which is what detect_project_dir() computes.
FAKEHOME=$(kit_scratch)
PROJ4="$FAKEHOME/.claude/projects/$(pwd | tr '/.' '--')"
mkdir -p "$PROJ4"
write_usage_line "$PROJ4/sess-main.jsonl" "$MODEL" 1000 200 50 10
write_usage_line "$PROJ4/sess-w1.jsonl"   "$MODEL" 300  60  0  0
write_usage_line "$PROJ4/sess-w2.jsonl"   "$MODEL" 200  40  0  0
OUT5=$(kit_scratch)/nopos.txt

HOME="$FAKEHOME" python3 "$SCRIPT" --main sess-main > "$OUT5" 2>&1 || {
  echo "FAIL: the documented \`--main <sid>\` form (no PROJECT_DIR) exited non-zero (#354)"; cat "$OUT5"; exit 1; }
grep -q "SESSIONS: 3 in $PROJ4" "$OUT5" || {
  echo "FAIL: --main <sid> without PROJECT_DIR did not auto-detect the project dir (#354)"; cat "$OUT5"; exit 1; }
grep -qE 'sess-mai.*<<< ORCHESTRATOR' "$OUT5" || {
  echo "FAIL: --main <sid> did not mark the orchestrator row"; cat "$OUT5"; exit 1; }
grep -q '=== ORCHESTRATOR vs WORKERS ===' "$OUT5" || {
  echo "FAIL: --main <sid> did not print the ORCHESTRATOR vs WORKERS split"; cat "$OUT5"; exit 1; }

HOME="$FAKEHOME" python3 "$SCRIPT" --top 1 > "$OUT5" 2>&1 || {
  echo "FAIL: \`--top 1\` without PROJECT_DIR exited non-zero (#354)"; cat "$OUT5"; exit 1; }
rows=$(awk '/^----/ { n++; next } n == 1 { c++ } END { print c + 0 }' "$OUT5")
[ "$rows" -eq 1 ] || { echo "FAIL: --top 1 listed $rows row(s) between the rules, expected exactly 1"; cat "$OUT5"; exit 1; }

if HOME="$FAKEHOME" python3 "$SCRIPT" --main > "$OUT5" 2>&1; then
  echo "FAIL: a bare --main (no value) must be a usage error, not a run"; cat "$OUT5"; exit 1; fi
grep -q 'usage:' "$OUT5" || { echo "FAIL: a bare --main did not print the usage line"; cat "$OUT5"; exit 1; }
if grep -q Traceback "$OUT5"; then echo "FAIL: a bare --main crashed with a traceback instead of a usage error"; cat "$OUT5"; exit 1; fi

HOME="$FAKEHOME" python3 "$SCRIPT" --main sess-main "$PROJ4" > "$OUT5" 2>&1 || {
  echo "FAIL: --main <sid> followed by an explicit PROJECT_DIR exited non-zero"; cat "$OUT5"; exit 1; }
grep -q "SESSIONS: 3 in $PROJ4" "$OUT5" || {
  echo "FAIL: --main <sid> <PROJECT_DIR> did not read the explicit dir"; cat "$OUT5"; exit 1; }
echo "ok: usage_report.py consumes --main/--top values instead of reading them as PROJECT_DIR (#354)"

# ------------------------------------------------- the prose agrees with the scan (#385)
#
# discover_transcripts() has reached workflow-nested transcripts (`subagents/workflows/wf_*/*.jsonl`)
# since #382; the orchestrator's Cost accounting paragraph in SKILL.md must not keep telling it
# they are uncounted, or the retro discounts a total that is complete.
SKILL_MD="$(kit_skill_prose "$KIT" auto-dev)"   # router + references/steps/*.md
if grep -q 'workflows", "wf_\*"' "$SCRIPT"; then
  if grep -q 'not yet counted' "$SKILL_MD"; then
    echo "FAIL: skills/auto-dev/SKILL.md still says workflow-nested sub-agents are 'not yet counted' while usage_report.py discovers them (#385)"; exit 1; fi
  if grep -q 'at the layouts it does read' "$SKILL_MD"; then
    echo "FAIL: skills/auto-dev/SKILL.md still hedges the header split with 'at the layouts it does read' (#385)"; exit 1; fi
else
  echo "FAIL: usage_report.py no longer carries the workflows/wf_* glob (#309) — this guard's premise is gone; re-decide it"; exit 1
fi
echo "ok: the Cost accounting paragraph agrees with usage_report.py's transcript discovery (#385)"
