#!/usr/bin/env bash
# Golden test for skills/review-sessions — the transcript harvest and the skill over it (#397).
#
# The harvest is deterministic and the suite holds it to a planted set: one signal of every kind,
# each after a Skill tool_use naming a kit skill, plus one decoy per class the script must NOT
# collect (a non-kit tool error, a deny from a foreign hook, the harness's own worktree refusal, a
# non-JSON line, a record older than --since). A script that over-collects fails here as loudly as
# one that under-collects: the assertion is on the exact set of (kind, skill) pairs.
#
# The transcript shapes are the ones Claude Code writes today — `type`, `timestamp`, and
# `message.content` blocks of `text` / `tool_use` / `tool_result` — pinned by construction in the
# writer below, the same way tests/usage-report/test.sh pins the usage shape.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
kit_guard kit_guard_samples_unchanged

SCRIPT="$KIT/skills/review-sessions/scripts/harvest.py"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing"; exit 1; }
SKILL="$KIT/skills/review-sessions/SKILL.md"

# ------------------------------------------------------------------------- fixture writers
# $1 = out file (appended), $2 = type (user|assistant), $3 = timestamp, $4 = JSON for message.content
write_line() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
out, typ, ts, content = sys.argv[1:5]
rec = {"type": typ, "timestamp": ts, "message": {"role": typ, "content": json.loads(content)}}
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PY
}
tool_use() { # $1 id  $2 name  $3 input JSON
  printf '[{"type":"tool_use","id":"%s","name":"%s","input":%s}]' "$1" "$2" "$3"
}
tool_result() { # $1 id  $2 text  $3 is_error (true|false)
  python3 -c 'import json,sys; print(json.dumps([{"type":"tool_result","tool_use_id":sys.argv[1],"content":sys.argv[2],"is_error":sys.argv[3]=="true"}]))' "$1" "$2" "$3"
}
text() { python3 -c 'import json,sys; print(json.dumps([{"type":"text","text":sys.argv[1]}]))' "$1"; }

# source_guard <outvar> <label> <want-rc> <want-prefix> -- <cmd…> — runs a guard for real,
# captures its combined stdout+stderr, asserts the exit code and the guard's own documented
# "<name>: <WORD> — " prefix (an independent literal, never re-derived from harvest.py's own
# GUARD_RE), and leaves the captured text in $<outvar> for the caller to read right after the
# call — so a fixture can never agree with a drifted guard message by construction (#552).
source_guard() {
  local outvar="$1" label="$2" want_rc="$3" want_prefix="$4"; shift 4
  [ "$1" = "--" ] || { echo "FAIL: source_guard($label): missing -- before the command"; exit 1; }
  shift
  local rc=0 out
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq "$want_rc" ] || {
    echo "FAIL: source_guard($label): expected exit $want_rc, got $rc:"; echo "$out"; exit 1; }
  case "$out" in
    "$want_prefix"*) : ;;
    *) echo "FAIL: source_guard($label): output no longer starts '$want_prefix': $out"; exit 1 ;;
  esac
  eval "$outvar=\$out"
}

PROJ=$(kit_scratch)/-Users-me-repo-tagout    # the dir name carries the kit name → in-kit paths count
mkdir -p "$PROJ"
T="$PROJ/sess-1.jsonl"
D="2026-08-20T10:00:00.000Z"

# The skill that owns everything below.
write_line "$T" assistant "$D" "$(tool_use t0 Skill '{"skill":"tagout:implement-issue","args":"47"}')"
# 1. tool-error: an is_error on a kit script.
write_line "$T" assistant "$D" "$(tool_use t1 Bash '{"command":"./skills/implement-issue/scripts/tick-plan.sh --issue 47"}')"
write_line "$T" user "$D" "$(tool_result t1 'tick-plan: gh api timed out' true)"
# decoy: an is_error on a non-kit command.
write_line "$T" assistant "$D" "$(tool_use t2 Bash '{"command":"/usr/bin/foo --bar"}')"
write_line "$T" user "$D" "$(tool_result t2 'foo: command not found' true)"
# 2. hook-deny: the kit's write-gate.
write_line "$T" assistant "$D" "$(tool_use t3 Bash '{"command":"git commit -m x"}')"
write_line "$T" user "$D" "$(tool_result t3 'Blocked by the git write-gate: `git commit -m x` is one of the writes that produced #26 and #280 in a shared checkout.' true)"
# decoy: a deny from a foreign hook.
write_line "$T" assistant "$D" "$(tool_use t4 Grep '{"pattern":"class Foo"}')"
write_line "$T" user "$D" "$(tool_result t4 'roseline-nudge: prefer search_symbols over Grep for C#' true)"
# decoy: the harness worktree refusal (not the kit) — a main session's wording, on a command that
# names a kit script (so it actually exercises the drop rather than being dropped for missing that).
write_line "$T" assistant "$D" "$(tool_use t5 Bash '{"command":"\"$GUARDS/guarded-commit.sh\" -C /x feat/47-x -- -m x"}')"
write_line "$T" user "$D" "$(tool_result t5 'This session is isolated in the worktree /x, but this command names git in a form too complex to verify. Refusing to run it.' true)"
# decoy: the same harness refusal, a sub-agent's wording ("This agent is …").
write_line "$T" assistant "$D" "$(tool_use t5b Bash '{"command":"\"$GUARDS/guarded-commit.sh\" -C /x feat/47-x -- -m x"}')"
write_line "$T" user "$D" "$(tool_result t5b 'This agent is isolated in the worktree /x, but this command names git in a form too complex to verify. Refusing to run it.' true)"
# decoy: the harness wraps some of its own refusals in a <tool_use_error> tag (confirmed on real
# transcripts) — unwrap() must strip it before the prefix check, or this falls through as a
# spurious tool-error on the guard script the command names.
write_line "$T" assistant "$D" "$(tool_use t5c Bash '{"command":"\"$GUARDS/guarded-commit.sh\" -C /x feat/47-x -- -m x"}')"
write_line "$T" user "$D" "$(tool_result t5c '<tool_use_error>This agent is isolated in the worktree /x, but this command names git in a form too complex to verify. Refusing to run it.</tool_use_error>' true)"
# and the same wrap on a hook-deny — must still be RECOGNIZED as one (not dropped, not tool-error).
write_line "$T" assistant "$D" "$(tool_use t3b Bash '{"command":"git commit -m x"}')"
write_line "$T" user "$D" "$(tool_result t3b '<tool_use_error>Blocked by the git write-gate: `git commit -m x` is one of the writes that produced #26 and #280 in a shared checkout.</tool_use_error>' true)"
# decoys (#645): a harness/dispatch tool failure is not a kit tool-error — only a Bash call's own
# failure is. Each below is is_error and its tool_use touches a skills/ path, so it counts as a
# tool-error today; after the fix, none of them may.
# decoy: Agent — a host dispatch-depth ceiling, not the kit.
write_line "$T" assistant "$D" "$(tool_use t30 Agent '{"prompt":"run skills/implement-issue/SKILL.md"}')"
write_line "$T" user "$D" "$(tool_result t30 'Subagent nesting limit reached (depth 3 of 3)' true)"
# decoy: Agent — fork unavailable inside a forked worker (same host ceiling).
write_line "$T" assistant "$D" "$(tool_use t31 Agent '{"prompt":"run skills/implement-issue/SKILL.md"}')"
write_line "$T" user "$D" "$(tool_result t31 'Fork is not available inside a forked worker' true)"
# decoy: Edit — a harness tool_use_error, wrapped.
write_line "$T" assistant "$D" "$(tool_use t32 Edit '{"file_path":"skills/x/SKILL.md"}')"
write_line "$T" user "$D" "$(tool_result t32 '<tool_use_error>String to replace not found in file.</tool_use_error>' true)"
# decoy: Read — a missing kit prose link, not a script failing.
write_line "$T" assistant "$D" "$(tool_use t33 Read '{"file_path":"skills/_shared/github-mechanics.md"}')"
write_line "$T" user "$D" "$(tool_result t33 'File does not exist.' true)"
# decoy: Grep — the harness's own tool-availability error, wrapped.
write_line "$T" assistant "$D" "$(tool_use t34 Grep '{"path":"skills/"}')"
write_line "$T" user "$D" "$(tool_result t34 '<tool_use_error>Error: No such tool available: Grep</tool_use_error>' true)"
# decoy: Bash — the harness blocking a sleep, wrapped (the tool ran, the harness refused it).
write_line "$T" assistant "$D" "$(tool_use t35 Bash '{"command":"sleep 45; skills/auto-dev/scripts/wait-ci.sh 598"}')"
write_line "$T" user "$D" "$(tool_result t35 '<tool_use_error>Blocked: sleep 45 followed by: skills/auto-dev/scripts/wait-ci.sh 598</tool_use_error>' true)"
# decoy: an MCP tool — a browser session conflict, not a kit script.
write_line "$T" assistant "$D" "$(tool_use t36 mcp__plugin_chrome-devtools-mcp_chrome-devtools__new_page '{"url":"http://localhost:4174/tagout/"}')"
write_line "$T" user "$D" "$(tool_result t36 'The browser is already running for /x/chrome-profile' true)"
# decoy: Bash — a permission rejection, no structural tell (the one literal prefix this task adds).
write_line "$T" assistant "$D" "$(tool_use t37 Bash '{"command":"skills/auto-dev/scripts/wait-ci.sh 598"}')"
write_line "$T" user "$D" "$(tool_result t37 'The user doesn'\''t want to proceed with this tool use. The tool use was rejected.' true)"
# 3. forbidden-wait.
write_line "$T" assistant "$D" "$(text "The suite is running. I'll pause here and wait for the code-review report before continuing.")"
# 4. worker-report.
write_line "$T" assistant "$D" "$(text 'PHASE1 | ISSUE: 47 | PR: none | STATUS: BLOCKED | DETAIL: no usable plan | FILED: none')"
# 5. suite-fail: a kit golden suite's FAIL line inside a tool result. Built with printf, not a raw
# multi-line literal (#645): a literal 'ok: frontier\nFAIL: ...' line would itself start a SOURCE
# line with "FAIL:" — the exact column-0 shape AC4 requires this file to have none of.
write_line "$T" assistant "$D" "$(tool_use t6 Bash '{"command":"./tests/survey/test.sh"}')"
write_line "$T" user "$D" "$(tool_result t6 "$(printf 'ok: frontier\nFAIL: SKILL.md Step 4 does not carry the immediate re-survey trigger (tests/survey/test.sh case 12d)')" true)"
# decoy (#645): reading the suite's OWN source is not a suite failure, even though (before this
# task's t6 rewrite above) it embeds the same FAIL: line the real positive plants.
write_line "$T" assistant "$D" "$(tool_use t41 Bash '{"command":"sed -n '"'"'1,400p'"'"' tests/review-sessions/test.sh"}')"
write_line "$T" user "$D" "$(tool_result t41 "$(cat "${BASH_SOURCE[0]}")" false)"
# 6. guard-refusal — sourced from the REAL guard, never retyped, so the fixture cannot agree with
# a drifted GUARD_RE the way a hand-typed one could (#513).
GR=$(kit_scratch)/guard-repo
git init -q "$GR"
git -C "$GR" symbolic-ref HEAD refs/heads/main
source_guard GOUT t7 2 "guarded-commit: REFUSED — " -- \
  "$KIT/skills/implement-issue/scripts/guarded-commit.sh" -C "$GR" feat/other -- -m x
write_line "$T" assistant "$D" "$(tool_use t7 Bash '{"command":"\"$GUARDS/guarded-commit.sh\" -C \"$WORKTREE\" feat/other -- -m x"}')"
write_line "$T" user "$D" "$(tool_result t7 "$(printf 'Exit code 2\n%s' "$GOUT")" true)"
# 6b-6e. guard-refusal, the other five real guards' own real output — sourced through
# source_guard the same way t7 is above, never typed by hand (#552).
TICK_BEFORE=$(kit_scratch)/tick-before.md
TICK_AFTER=$(kit_scratch)/tick-after.md
printf -- '- [ ] **Step 1:** fix the widget\n' > "$TICK_BEFORE"
printf -- '- [x] **Step 1:** fix the gadget\n' > "$TICK_AFTER"
source_guard TICK_OUT t9 1 "tick-plan: REFUSED — " -- \
  "$KIT/skills/implement-issue/scripts/tick-plan.sh" --repo o/r --issue 1 \
  --before "$TICK_BEFORE" --after "$TICK_AFTER"
write_line "$T" assistant "$D" "$(tool_use t9 Bash '{"command":"\"$GUARDS/tick-plan.sh\" --issue 47"}')"
write_line "$T" user "$D" "$(tool_result t9 "$(printf 'Exit code 1\n%s' "$TICK_OUT")" true)"

GH_STUB=$(kit_scratch)/gh-stub-bin
mkdir -p "$GH_STUB"
cat > "$GH_STUB/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
  echo "a required status check has not passed" >&2
  exit 1
elif [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  printf 'OPEN\t\t\n'
else
  echo "gh stub: unexpected invocation: $*" >&2
  exit 99
fi
STUB
chmod +x "$GH_STUB/gh"
OLD_PATH="$PATH"
PATH="$GH_STUB:$PATH"
source_guard PRMERGE_OUT t10 2 "guarded-pr-merge: REJECTED — " -- \
  "$KIT/skills/merge-pr/scripts/guarded-pr-merge.sh" 999
PATH="$OLD_PATH"
write_line "$T" assistant "$D" "$(tool_use t10 Bash '{"command":"\"$GUARDS/guarded-pr-merge.sh\" 47"}')"
write_line "$T" user "$D" "$(tool_result t10 "$(printf 'Exit code 2\n%s' "$PRMERGE_OUT")" true)"

source_guard MERGE_OUT t20 2 "guarded-merge: REFUSED — " -- \
  "$KIT/skills/implement-issue/scripts/guarded-merge.sh" -C "$GR" feat/other -- origin/main
write_line "$T" assistant "$D" "$(tool_use t20 Bash '{"command":"\"$GUARDS/guarded-merge.sh\" -C \"$WORKTREE\" feat/47-x -- origin/main"}')"
write_line "$T" user "$D" "$(tool_result t20 "$(printf 'Exit code 2\n%s' "$MERGE_OUT")" true)"

WT_REPO=$(kit_scratch)/worktree-repo
mkdir -p "$WT_REPO"
git -C "$WT_REPO" init -q -b main
git -C "$WT_REPO" config user.email t@example.com
git -C "$WT_REPO" config user.name "Golden Test"
printf 'unrelated.txt\n' > "$WT_REPO/.gitignore"
git -C "$WT_REPO" add -A
git -C "$WT_REPO" commit -q -m base
source_guard WT_OUT t21 2 "make-worktree: REFUSED — " -- \
  "$KIT/skills/implement-issue/scripts/make-worktree.sh" -C "$WT_REPO" feat/x
write_line "$T" assistant "$D" "$(tool_use t21 Bash '{"command":"\"$KIT/skills/implement-issue/scripts/make-worktree.sh\" 47"}')"
write_line "$T" user "$D" "$(tool_result t21 "$(printf 'Exit code 2\n%s' "$WT_OUT")" true)"
# a compound command (a read piped/chained before the real guard call) is STILL an invocation —
# invoked_guard gates on is_error, not on the command's first word (#513 review: a first-word
# heuristic missed exactly this shape, and needed a growing read-command allowlist to approximate it).
PUSH_REPO=$(kit_scratch)/push-repo
PUSH_ORIGIN=$(kit_scratch)/push-origin.git
mkdir -p "$PUSH_REPO"
git -C "$PUSH_REPO" init -q -b main
git -C "$PUSH_REPO" config user.email t@example.com
git -C "$PUSH_REPO" config user.name "Golden Test"
printf 'seed\n' > "$PUSH_REPO/seed.txt"
git -C "$PUSH_REPO" add -A
git -C "$PUSH_REPO" commit -q -m seed
git init -q --bare "$PUSH_ORIGIN"
git -C "$PUSH_REPO" remote add origin "$PUSH_ORIGIN"
git -C "$PUSH_REPO" push -q -u origin main
git -C "$PUSH_REPO" checkout -q -b feature
source_guard PUSH_OUT t11 4 "guarded-push: ALERT — " -- \
  "$KIT/skills/implement-issue/scripts/guarded-push.sh" -C "$PUSH_REPO" --verify-only feature
write_line "$T" assistant "$D" "$(tool_use t11 Bash '{"command":"cat plan.md && \"$GUARDS/guarded-push.sh\" -C \"$WORKTREE\" --verify-only feat/47-x"}')"
write_line "$T" user "$D" "$(tool_result t11 "$(printf 'Exit code 4\n%s' "$PUSH_OUT")" true)"
# decoy: a Read that merely QUOTES a guard line (a backticked table cell) — not the guard running.
write_line "$T" assistant "$D" "$(tool_use t12 Read '{"file_path":"notes.md"}')"
write_line "$T" user "$D" "$(tool_result t12 "| \`guarded-commit: REFUSED — HEAD is on 'main'\` |" false)"
# AC6 (#496): invocation, not mention. A Read carrying the guard's own real refusal text (t7's
# $GOUT) verbatim is excluded because it isn't Bash; a Bash that actually NAMES the guard but did
# NOT fail (is_error:false) is excluded even though the body still reads as a refusal — the
# is_error gate is what does the work, not a guess about the command's shape.
write_line "$T" assistant "$D" "$(tool_use t13 Read '{"file_path":"guarded-commit.sh"}')"
write_line "$T" user "$D" "$(tool_result t13 "$GOUT" false)"
write_line "$T" assistant "$D" "$(tool_use t14 Bash '{"command":"cat notes.md"}')"
write_line "$T" user "$D" "$(tool_result t14 "$GOUT" false)"
# and separately: a Bash that DOES name the guard, but did not fail (is_error:false) — the is_error
# gate is what excludes it, not a guess about the command's shape.
write_line "$T" assistant "$D" "$(tool_use t14b Bash '{"command":"\"$GUARDS/guarded-commit.sh\" -C \"$WORKTREE\" feat/other -- -m x"}')"
write_line "$T" user "$D" "$(tool_result t14b "$GOUT" false)"
# AC7 (#496): a Bash that only READS a guard's own source (grep) and did not fail (is_error:false)
# is not "invoking" it, even though the command names a kit script and the source text mentions an
# exit code.
write_line "$T" assistant "$D" "$(tool_use t16 Bash '{"command":"grep -n usage skills/merge-pr/scripts/guarded-pr-merge.sh"}')"
write_line "$T" user "$D" "$(tool_result t16 'skills/merge-pr/scripts/guarded-pr-merge.sh:56:refuse() { printf ... ; exit 64; }' false)"
# a guard basename mentioned only in a Bash tool_use's `description` field (never its `command`)
# must not flip the invocation gate.
write_line "$T" assistant "$D" "$(tool_use t19 Bash '{"command":"ls -la","description":"test guarded-commit.sh behavior"}')"
write_line "$T" user "$D" "$(tool_result t19 "$GOUT" true)"
# AC8 (#496): kit_name counts only as a standalone identifier — never as a substring of a
# dash-encoded scratchpad directory that happens to spell the kit's name.
write_line "$T" assistant "$D" "$(tool_use t17 Bash '{"command":"cd /private/tmp/claude-501/-Users-x-tagout/scratchpad && ls"}')"  # tmp-lint:allow — a fixture COMMAND string under test, not a path this suite writes
write_line "$T" user "$D" "$(tool_result t17 'ls: cannot access '"'"'foo'"'"': No such file or directory' true)"
write_line "$T" assistant "$D" "$(tool_use t18 Bash '{"command":"cd /Users/x/tagout && scripts/preflight.sh"}')"
write_line "$T" user "$D" "$(tool_result t18 'preflight: PyYAML missing' true)"
# decoy: kit_name's trailing boundary — a same-PREFIXED sibling directory ("tagout.bak")
# is not the kit's own path segment, even though it starts with the kit's name.
write_line "$T" assistant "$D" "$(tool_use t22 Bash '{"command":"ls /x/tagout.bak/notes.txt"}')"
write_line "$T" user "$D" "$(tool_result t22 "ls: cannot access notes.txt: No such file or directory" true)"
# 7. harness-nudge (a plain user string).
python3 - "$T" "$D" <<'PY'
import json, sys
out, ts = sys.argv[1:3]
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps({"type": "user", "timestamp": ts, "message": {"role": "user", "content": "[Request interrupted by user]"}}) + "\n")
PY
# decoys (#645): prose that QUOTES a never-wait phrase, a worker-report shape or a nudge is not the
# kit failing — only an UNQUOTED occurrence is. And a deny-shaped line that did not fail (is_error
# false) is not a hook-deny.
# decoy: forbidden-wait, quoted via emphasis + a straight double quote.
write_line "$T" assistant "$D" "$(text "> *\"I'll pause here and wait for the report\"* is what the worker said before it died.")"
# decoy: forbidden-wait, quoted via a JSON-escaped quote (the \" case).
write_line "$T" assistant "$D" "$(text '"failure_scenario": "ends its turn with \"I'\''ll stop issuing further tool calls now and wait\""')"
# decoy: worker-report, quoted via a backtick.
write_line "$T" assistant "$D" "$(text 'a dispatch that reports `STATUS: BLOCKED` on any failure')"
# decoy: harness-nudge, quoted via a backtick, in a USER text block.
write_line "$T" user "$D" "$(text '- the `harness-nudge` kind on `[Request interrupted` is noise')"
# code-review finding (#645): a quoted occurrence of a nudge phrase FOLLOWED by a genuine unquoted
# one in the SAME block. `str.find()` only ever sees the first (quoted) occurrence, so a naive
# quoted-check on that index alone drops the real nudge after it — every occurrence must be checked.
write_line "$T" user "$D" "$(text 'earlier we quoted `[Request interrupted` as fine, but now: [Request interrupted by user]')"
# decoy: hook-deny shape that did NOT fail (is_error false) — a test's own printed incident line.
write_line "$T" assistant "$D" "$(tool_use t40 Bash '{"command":"./tests/incident-check/test.sh"}')"
write_line "$T" user "$D" "$(tool_result t40 "$(printf 'INCIDENT (verbatim shape) -> ALLOW\nBlocked by the git write-gate: git commit -m x')" false)"
# decoys: a non-JSON line, and an old kit tool-error --since must drop.
printf 'not json at all\n' >> "$T"
write_line "$T" assistant "2026-08-01T09:00:00.000Z" "$(tool_use t8 Bash '{"command":"./skills/auto-dev/scripts/survey.sh"}')"
write_line "$T" user "2026-08-01T09:00:00.000Z" "$(tool_result t8 'survey.sh: jq: parse error' true)"

# ------------------------------------------------------------------------- the harvest, JSON
OUT=$(kit_scratch)/records.jsonl
python3 "$SCRIPT" "$PROJ" --json --since 2026-08-15 > "$OUT" 2>"$OUT.err" || {
  echo "FAIL: harvest.py exited non-zero on the fixture"; cat "$OUT.err"; exit 1; }
python3 - "$OUT" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
pairs = sorted({(r["kind"], r["skill"]) for r in recs})
want = sorted({(k, "implement-issue") for k in
               ("tool-error", "hook-deny", "forbidden-wait", "worker-report", "suite-fail", "guard-refusal", "harness-nudge")})
if pairs != want:
    print("FAIL: (kind, skill) set differs from the planted set")
    print("  got :", pairs); print("  want:", want); sys.exit(1)
keys = {"kind", "skill", "session", "path", "ts", "excerpt", "tool", "detail", "count"}
bad = [r for r in recs if set(r) != keys]
if bad:
    print("FAIL: a record does not carry the documented keys:", bad[0]); sys.exit(1)
old = [r for r in recs if r["ts"].startswith("2026-08-01")]
if old:
    print("FAIL: --since did not drop the record dated before it:", old[0]); sys.exit(1)
tool_err = [r for r in recs if r["kind"] == "tool-error"]
tool_err_details = sorted(r["detail"] for r in tool_err)
if len(tool_err) != 2 or not any("tick-plan.sh" in d for d in tool_err_details) \
        or not any("preflight.sh" in d for d in tool_err_details):
    print("FAIL: exactly two tool-errors were expected, on tick-plan.sh and preflight.sh:", tool_err_details); sys.exit(1)
guard_details = sorted({r["detail"] for r in recs if r["kind"] == "guard-refusal"})
want_guards = ["guarded-commit", "guarded-merge", "guarded-pr-merge", "guarded-push", "make-worktree", "tick-plan"]
if guard_details != want_guards:
    print("FAIL: guard-refusal details differ from the six real guard names")
    print("  got :", guard_details); print("  want:", want_guards); sys.exit(1)
# #645: a quoted occurrence (any of the three text kinds) or a non-failing deny line must not add to
# the summed count — count, never len(), since a collapse (t3+t3b) is one record worth 2.
def summed(kind):
    return sum(r["count"] for r in recs if r["kind"] == kind)
want_summed = {"forbidden-wait": 1, "worker-report": 1, "harness-nudge": 2, "hook-deny": 2, "suite-fail": 1}
for kind, want_n in want_summed.items():
    got_n = summed(kind)
    if got_n != want_n:
        print(f"FAIL: {kind} summed count is {got_n}, want {want_n} (a quoted or non-failing decoy leaked through)")
        sys.exit(1)
print("ok   the JSON records are exactly the planted set, keyed as documented, and --since holds")
PY

# ------------------------------------------------------------------------- the tally, markdown
MD=$(kit_scratch)/tally.md
python3 "$SCRIPT" "$PROJ" --markdown --since 2026-08-15 > "$MD" 2>/dev/null || { echo "FAIL: --markdown exited non-zero"; exit 1; }
grep -q '^## implement-issue$' "$MD" || { echo "FAIL: the tally has no per-skill heading"; cat "$MD"; exit 1; }
grep -q '^signals: 15 across 1 sessions' "$MD" || { echo "FAIL: the tally does not end with 'signals: 15 across 1 sessions'"; tail -3 "$MD"; exit 1; }
grep -q 'skipped 1 unparseable' "$MD" || { echo "FAIL: the non-JSON line was not counted as skipped"; tail -3 "$MD"; exit 1; }
echo "ok   the markdown tally groups by skill and kind, counts the skipped line, ends with the signals line"

# ------------------------------------------------------------------------- refusals
if python3 "$SCRIPT" "$PROJ/does-not-exist" --json > "$OUT.missing" 2>&1; then
  echo "FAIL: a missing project dir must exit non-zero"; exit 1; fi
rc=0; python3 "$SCRIPT" "$PROJ/does-not-exist" --json > "$OUT.missing" 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL: a missing project dir must exit 2, got $rc"; exit 1; }
if grep -q Traceback "$OUT.missing"; then echo "FAIL: a missing project dir produced a traceback"; cat "$OUT.missing"; exit 1; fi
rc=0; python3 "$SCRIPT" "$PROJ" --since not-a-date > "$OUT.date" 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL: a malformed --since must exit 2, got $rc"; exit 1; }
rc=0; python3 "$SCRIPT" "$PROJ" --json --markdown > "$OUT.both" 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL: --json and --markdown together must exit 2 (they are exclusive), got $rc"; exit 1; }
# An EXISTING directory that cannot be listed is not "no signals": glob() would swallow the
# PermissionError and the run would answer clean with exit 0. Skipped as root, who can read anything.
if [ "$(id -u)" -ne 0 ]; then
  LOCKED=$(kit_scratch)/-Users-me-repo-tagout-locked; mkdir -p "$LOCKED"; chmod 000 "$LOCKED"
  rc=0; python3 "$SCRIPT" "$LOCKED" --json > "$OUT.locked" 2>&1 || rc=$?
  chmod 755 "$LOCKED"
  [ "$rc" -eq 2 ] || { echo "FAIL: an unreadable (chmod 000) project dir must exit 2, got $rc"; cat "$OUT.locked"; exit 1; }
  if grep -q Traceback "$OUT.locked"; then echo "FAIL: an unreadable project dir produced a traceback"; cat "$OUT.locked"; exit 1; fi
fi
EMPTY=$(kit_scratch)/-Users-me-repo-other; mkdir -p "$EMPTY"
python3 "$SCRIPT" "$EMPTY" --markdown > "$OUT.empty" 2>&1 || { echo "FAIL: an empty project dir must exit 0"; exit 1; }
grep -q '^no signals' "$OUT.empty" || { echo "FAIL: an empty project dir must print the explicit 'no signals' line"; cat "$OUT.empty"; exit 1; }
echo "ok   refusals: missing or unreadable dir → 2 without a traceback, bad --since → 2, --json --markdown → 2, empty dir → 0 and 'no signals'"

# ------------------------------------------------------------------------- the never-wait phrases are READ from the kit's suite
# ---------------------------------------------------------------- the rename's two edges (#611)
# (a) a transcript recorded BEFORE the rename — the old skill-id prefix, a checkout still under
#     …/ai-migration-kit — keeps counting under the DEFAULT --kit-name (the old name rides along);
# (b) "tagout" is an ordinary word since the rename: a consumer's own "docs/tagout procedure.md"
#     erroring in a non-kit project is NOT a kit tool-error.
echo "== the old kit name still counts by default; the bare word 'tagout' does not =="
OLDP=$(kit_scratch)/-Users-me-repo-ai-migration-kit; mkdir -p "$OLDP"; OT="$OLDP/sess-old.jsonl"
write_line "$OT" assistant "$D" "$(tool_use o0 Skill '{"skill":"ai-migration-kit:implement-issue","args":"47"}')"
write_line "$OT" assistant "$D" "$(tool_use o1 Bash '{"command":"./skills/implement-issue/scripts/tick-plan.sh --issue 47"}')"
write_line "$OT" user "$D" "$(tool_result o1 'tick-plan: gh api timed out' true)"
WORDP=$(kit_scratch)/-Users-x-tagout-procedures; mkdir -p "$WORDP"; WT="$WORDP/sess-word.jsonl"
write_line "$WT" assistant "$D" "$(tool_use w1 Bash '{"command":"cat \"docs/tagout procedure.md\""}')"
write_line "$WT" user "$D" "$(tool_result w1 'cat: docs/tagout procedure.md: No such file or directory' true)"
OUT2=$(kit_scratch)/records-rename.jsonl
python3 "$SCRIPT" "$OLDP" "$WORDP" --json --since 2026-08-15 > "$OUT2" 2>"$OUT2.err" || {
  echo "FAIL: harvest.py exited non-zero on the rename fixtures"; cat "$OUT2.err"; exit 1; }
python3 - "$OUT2" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
got = sorted((r["kind"], r["skill"], r["detail"]) for r in recs)
if len(recs) != 1 or got[0][:2] != ("tool-error", "implement-issue") or "tick-plan.sh" not in got[0][2]:
    print("FAIL: expected exactly one tool-error, attributed through the OLD skill-id prefix; got", got); sys.exit(1)
if any("procedure" in r["detail"] for r in recs):
    print("FAIL: the bare word 'tagout' in a consumer's file was harvested as a kit path"); sys.exit(1)
PY
echo "ok   old-name transcripts count by default; the bare word 'tagout' does not"

grep -q 'auto-dev-never-wait' "$SCRIPT" || { echo "FAIL: harvest.py does not read the never-wait phrases from tests/auto-dev-never-wait/test.sh"; exit 1; }
grep -q 'never-wait phrases: kit' "$MD" || { echo "FAIL: the tally does not say the never-wait phrases came from the kit's suite"; tail -1 "$MD"; exit 1; }
echo "ok   the never-wait phrase list has one home, and the tally names its source"

# ------------------------------------------------------------------------- the skill's prose
[ -f "$SKILL" ] || { echo "FAIL: $SKILL missing"; exit 1; }
grep -q '^name: review-sessions$' "$SKILL" || { echo "FAIL: SKILL.md does not declare name: review-sessions"; exit 1; }
for ref in _shared/recap.md _shared/preconditions.md _shared/filing-bar.md _shared/prior-rejections.md _shared/untrusted-input-boundary.md; do
  grep -qF -- "../$ref" "$SKILL" || { echo "FAIL: SKILL.md does not link ../$ref"; exit 1; }
done
grep -qF 'auto-dev/references/retro-taxonomy.md' "$SKILL" || { echo "FAIL: SKILL.md does not reuse the retro taxonomy"; exit 1; }
grep -qF 'scripts/harvest.py' "$SKILL" || { echo "FAIL: SKILL.md never names scripts/harvest.py"; exit 1; }
grep -qF -- '--dry-run' "$SKILL" || { echo "FAIL: SKILL.md offers no --dry-run"; exit 1; }
grep -qi 'already fixed' "$SKILL" || { echo "FAIL: SKILL.md has no 'already fixed' outcome"; exit 1; }
grep -qF 'create-issue' "$SKILL" || { echo "FAIL: SKILL.md never names create-issue as the filing path"; exit 1; }
if grep -q 'gh issue create' "$SKILL"; then echo "FAIL: SKILL.md files with a raw gh issue create instead of create-issue"; exit 1; fi
if grep -q 'gh issue close' "$SKILL"; then echo "FAIL: SKILL.md closes issues — this skill never closes anything"; exit 1; fi
echo "ok   the skill links its five shared references and the taxonomy, files only through create-issue, never closes"

echo "review-sessions golden test OK"
