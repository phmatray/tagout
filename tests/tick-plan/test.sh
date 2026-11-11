#!/usr/bin/env bash
# Golden test for tick-plan.sh — the guarded write that replaces
#   jq -Rs '{body: .}' plan.md | gh api .../issues/N -X PATCH --input -
#
# That pipeline wiped two live issue bodies (Koine#1813). Measured cause: `jq -Rs` on a
# missing OR empty file still emits a well-formed {"body": ""}, and `gh api` applies it
# faithfully. On the empty-file path jq even exits 0, so `set -o pipefail` alone does NOT
# catch it. Every case below must therefore fail CLOSED — refuse, exit non-zero, and make
# NO call to gh at all.
set -euo pipefail
cd "$(dirname "$0")/../.."
# A GH_HOST in the developer's or CI's shell would decide the host cases (#514) on its own.
unset GH_HOST

TICK="./skills/implement-issue/scripts/tick-plan.sh"
[ -x "$TICK" ] || { echo "FAIL: $TICK missing or not executable"; exit 1; }

# Scratch dir and EXIT trap come from the shared preamble (#72) — eight suites each had
# their own, and they had diverged. KIT_ROOT is derived from this file's location rather
# than $PWD: $PWD is only right because a `cd` sits above, and moving it would break the
# source silently (tests/ci-wiring did exactly that).
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
WORK=$(kit_scratch)

# A `gh` stub on PATH: records every invocation, so the test can prove that a refused write
# never reached the network. It also stores the PATCHed body and serves it back on a GET, so
# the script's verify-after-write step is genuinely exercised rather than stubbed away.
#
# The stub resolves `--input` the way real `gh` does — a path is read from that file, a bare `-`
# from stdin — and records which of the two it was in $GH_INPUT_PATH. That is what lets the suite
# pin the payload's transport (#113): `--input -` is the stdin pipe that sat for 25–35 minutes on
# a 30KB body after GitHub had already stored it.
#
# Each log line also carries the GH_HOST the call ran under (#514), and `gh auth token --hostname H`
# — the host helper's credential probe — succeeds only for a host listed in $GH_STUB_HOSTS. That
# branch comes FIRST: the read branch below would otherwise answer it, and sleep under
# $GH_READ_SLEEP.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "GH_HOST=${GH_HOST-<unset>} ARGS: $*" >> "$GH_CALL_LOG"
if [ "${1:-}" = auth ] && [ "${2:-}" = token ]; then
  host=""; prev=""
  for a in "$@"; do [ "$prev" = "--hostname" ] && host="$a"; prev="$a"; done
  case " ${GH_STUB_HOSTS:-} " in *" $host "*) echo "gho_stub_token_for_$host"; exit 0 ;; esac
  exit 1
fi
# The write is either the comment path's `api … -X PATCH --input <json>` or the body path's
# `issue edit <n> --body-file <raw body>` that the tracker contract's github backend sends (#751).
# Either way $GH_PAYLOAD ends up as the {body} JSON the call carried, so one round-trip check reads both.
if [[ "$*" == *PATCH* ]] || [ "${1:-} ${2:-}" = "issue edit" ]; then
  input="<none>"; prev=""
  for a in "$@"; do
    [ "$prev" = "--input" ] && input="$a"
    [ "$prev" = "--body-file" ] && input="$a"
    prev="$a"
  done
  printf '%s\n' "$input" > "$GH_INPUT_PATH"
  if [ "${1:-} ${2:-}" = "issue edit" ]; then
    jq -Rs '{body: .}' < "$input" > "$GH_PAYLOAD"
  elif [ "$input" = "<none>" ] || [ "$input" = "-" ]; then
    cat > "$GH_PAYLOAD"
  else
    cp "$input" "$GH_PAYLOAD"
  fi
  [ -n "${GH_PATCH_FAIL:-}" ] && exit 4
  jq -r .body < "$GH_PAYLOAD" > "$GH_STORE"
  # $GH_MANGLE_STORE models a concurrent edit: GitHub ends up holding something other than
  # what was sent, which the read-back must catch whether or not the call was bounded.
  [ -n "${GH_MANGLE_STORE:-}" ] && printf 'a concurrent edit\n' >> "$GH_STORE"
  # $GH_PAYLOAD is stored BEFORE the sleep on purpose: that is the production symptom (#113) —
  # GitHub already holds the new body while the client is still waiting on the call.
  #
  # $GH_PATCH_IGNORE_TERM is the adversarial version: a call that will not die on SIGTERM. A
  # deadline that only sends TERM is advisory against it, because the script then blocks in
  # `wait` for the whole sleep — the exact stall the deadline exists to prevent.
  if [ -n "${GH_PATCH_IGNORE_TERM:-}" ]; then
    trap '' TERM
    sleep "${GH_PATCH_SLEEP:-8}"
    exit 0
  fi
  # `exec` so the sleep inherits this pid and a kill on it actually ends the call.
  [ -n "${GH_PATCH_SLEEP:-}" ] && exec sleep "$GH_PATCH_SLEEP"
  exit 0
else
  [ -n "${GH_READ_FAIL:-}" ] && exit 3
  # The adversarial read-back: records its pid, then refuses to die on TERM and does NOT exec, so
  # this process and its `sleep` both outlive the group leader. That is the shape the read-back
  # actually has in production — it is launched through a shell function, so the leader is a
  # subshell and `gh` is its child.
  if [ -n "${GH_READ_IGNORE_TERM:-}" ]; then
    echo $$ > "$GH_READ_PID"
    trap '' TERM
    sleep "${GH_READ_SLEEP:-25}"
    exit 0
  fi
  # $GH_READ_SLEEP stalls the READ-BACK — the leg that decides the verdict and that #135 found
  # unbounded. `exec` so the sleep inherits this pid and a kill on it actually ends the call.
  [ -n "${GH_READ_SLEEP:-}" ] && exec sleep "$GH_READ_SLEEP"
  # $GH_READBACK_CRLF models a text-mode `gh` stdout on THIS call only (#215 Task 1) — every \n it
  # emits comes back as \r\n, the same class of corruption #199 found in `jq -j`, but here on the
  # leg that reads back what GitHub now holds rather than the local pre-send round-trip.
  # The body path reads back with `issue view <n> --json …` (#751): the stored body as gh's JSON.
  emit() {
    if [ "${1:-} ${2:-}" = "issue view" ]; then
      [ -f "$GH_STORE" ] && jq -Rs '{number: 42, title: "t", state: "OPEN", url: "u", labels: [], body: .}' < "$GH_STORE"
    else
      [ -f "$GH_STORE" ] && cat "$GH_STORE"
    fi
  }
  if [ -n "${GH_READBACK_CRLF:-}" ]; then
    emit "$@" | sed $'s/$/\r/'
    exit 0
  fi
  emit "$@"
fi
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

BEFORE="$WORK/before.md"
cat > "$BEFORE" <<'EOF'
## Summary

Body with **bold**, `backticks`, "quotes" and a stray - [ ] lookalike inline.

## 🛠️ Implementation plan

- [ ] **Task 1 — Reproduce.** Confirm the empty-body PATCH.
- [ ] **Task 2 — Fail closed.** Guard the write.
- [ ] **Task 3 — Verify.** Re-read after writing.
EOF

fresh_log() {
  GH_CALL_LOG="$WORK/gh-calls.$1.log"
  GH_PAYLOAD="$WORK/gh-payload.$1.json"
  GH_STORE="$WORK/gh-store.$1.md"
  GH_INPUT_PATH="$WORK/gh-input.$1.txt"
  export GH_CALL_LOG GH_PAYLOAD GH_STORE GH_INPUT_PATH
  : > "$GH_CALL_LOG"; rm -f "$GH_PAYLOAD" "$GH_STORE" "$GH_INPUT_PATH"
}

# Asserts: the command refused (non-zero) AND gh was never invoked.
refuses() {
  local name="$1"; shift
  fresh_log "$name"
  if "$@" >"$WORK/out.$name" 2>"$WORK/err.$name"; then
    echo "FAIL [$name]: expected a refusal, got exit 0"; cat "$WORK/out.$name"; exit 1
  fi
  if [ -s "$GH_CALL_LOG" ]; then
    echo "FAIL [$name]: refused but STILL called gh:"; cat "$GH_CALL_LOG"; exit 1
  fi
  echo "  ok: $name — refused, no gh call"
}

# ---------------------------------------------------------------- refusals

# 1. The exact production failure: the plan file was never written.
refuses missing-file "$TICK" --repo o/r --issue 1 --before "$BEFORE" --after "$WORK/nope.md"

# 2. The case `set -o pipefail` does NOT catch: file exists but is empty (jq exits 0).
: > "$WORK/empty.md"
refuses empty-file "$TICK" --repo o/r --issue 1 --before "$BEFORE" --after "$WORK/empty.md"

# 3. Truncated mid-write: valid prefix, silently loses the tail of the plan.
head -c 120 "$BEFORE" > "$WORK/truncated.md"
refuses truncated "$TICK" --repo o/r --issue 1 --before "$BEFORE" --after "$WORK/truncated.md"

# 4. Body edited beyond the checkboxes — ticking is a one-character substitution, so any
#    other change means something rewrote the body and must not be pushed.
sed 's/^- \[ \] \*\*Task 1/- [x] **Task 1/' "$BEFORE" | sed 's/Confirm the empty-body PATCH./Rewritten by an agent./' > "$WORK/mangled.md"
refuses body-mutated "$TICK" --repo o/r --issue 1 --before "$BEFORE" --after "$WORK/mangled.md"

# 5. The plan heading vanished.
grep -v '🛠️ Implementation plan' "$BEFORE" | sed 's/^- \[ \] \*\*Task 1/- [x] **Task 1/' > "$WORK/noheading.md"
refuses heading-lost "$TICK" --repo o/r --issue 1 --before "$BEFORE" --after "$WORK/noheading.md"

# 6. Nothing was actually flipped — the intended edit silently didn't land.
cp "$BEFORE" "$WORK/noop.md"
refuses no-change "$TICK" --repo o/r --issue 1 --before "$BEFORE" --after "$WORK/noop.md"

# 7. Un-ticking: a box went from [x] back to [ ]. Never legitimate here.
sed 's/^- \[ \] \*\*Task 1/- [x] **Task 1/; s/^- \[ \] \*\*Task 2/- [x] **Task 2/' "$BEFORE" > "$WORK/two-done.md"
sed 's/^- \[x\] \*\*Task 2/- [ ] **Task 2/' "$WORK/two-done.md" > "$WORK/unticked.md"
refuses unticking "$TICK" --repo o/r --issue 1 --before "$WORK/two-done.md" --after "$WORK/unticked.md"

# ---------------------------------------------------------------- happy path

fresh_log happy
sed 's/^- \[ \] \*\*Task 1/- [x] **Task 1/' "$BEFORE" > "$WORK/ticked.md"
"$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md" > "$WORK/out.happy" 2>&1 \
  || { echo "FAIL [happy]: a legitimate tick was refused"; cat "$WORK/out.happy"; exit 1; }

# The body path writes through the tracker contract (#751): `issue edit 42`, and no `api … -X PATCH`.
grep -q 'ARGS: issue edit 42 --repo o/r --body-file ' "$GH_CALL_LOG" \
  || { echo "FAIL [happy]: wrong write call"; cat "$GH_CALL_LOG"; exit 1; }
grep -q 'X PATCH' "$GH_CALL_LOG" \
  && { echo "FAIL [happy]: the body path still PATCHes through gh api"; cat "$GH_CALL_LOG"; exit 1; }

# The payload must round-trip to the ticked file byte for byte.
python3 - "$GH_PAYLOAD" "$WORK/ticked.md" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1]))
want = open(sys.argv[2], encoding="utf-8").read()
assert set(payload) == {"body"}, f"payload should carry only 'body', got {sorted(payload)}"
assert payload["body"] == want, "payload body is not byte-identical to the ticked file"
assert payload["body"].strip(), "payload body is empty — the exact bug this guards"
PY
echo "  ok: happy — PATCHed the ticked body verbatim"

# 7b. The payload travels in a FILE, never down a stdin pipe. `--input -` is the last surviving
#     piece of the recipe this script replaced, and it is what made a 30KB PATCH take 25–35
#     minutes to return from a write GitHub had already applied (#113).
if grep -qE -- '--input -($| )' "$GH_CALL_LOG"; then
  echo "FAIL [input-file]: the PATCH still pipes its payload via '--input -'"; cat "$GH_CALL_LOG"; exit 1
fi
INPUT_PATH=$(cat "$GH_INPUT_PATH")
case "$INPUT_PATH" in
  ''|'-'|'<none>')
    echo "FAIL [input-file]: expected '--input <file>', the PATCH passed '${INPUT_PATH:-<empty>}'"
    cat "$GH_CALL_LOG"; exit 1 ;;
esac
# The stub copied $INPUT_PATH into $GH_PAYLOAD, which the round-trip check above already proved
# byte-identical to the ticked file — so the file really held the payload, not just a path.
[ -f "$GH_PAYLOAD" ] || { echo "FAIL [input-file]: no payload was captured from $INPUT_PATH"; exit 1; }
echo "  ok: input-file — the payload came from $INPUT_PATH, not a stdin pipe"

# ...and it is scratch: registered for cleanup, so it does not outlive the run.
if [ -e "$INPUT_PATH" ]; then
  echo "FAIL [input-file]: payload temp file $INPUT_PATH outlived the script"; exit 1
fi
echo "  ok: input-file — the payload temp file is removed on exit"

# 8. A comment-hosted plan targets the comments endpoint, not the issue.
fresh_log comment
"$TICK" --repo o/r --issue 42 --comment-id 998877 --before "$BEFORE" --after "$WORK/ticked.md" >/dev/null 2>&1 \
  || { echo "FAIL [comment]: legitimate comment tick refused"; exit 1; }
grep -q 'repos/o/r/issues/comments/998877' "$GH_CALL_LOG" \
  || { echo "FAIL [comment]: wrong endpoint"; cat "$GH_CALL_LOG"; exit 1; }
echo "  ok: comment — PATCHed the comment endpoint"

# 9. Runs from a foreign working directory (plugin-install simulation, cf. ci.yml).
fresh_log foreign
KIT="$PWD"
( cd "$WORK" && bash "$KIT/$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md" >/dev/null 2>&1 ) \
  || { echo "FAIL [foreign-cwd]: refused when run from another directory"; exit 1; }
echo "  ok: foreign cwd"

# ---------------------------------------------------------------- the deadline
#
# The PATCH runs under a pure-bash deadline (TICK_PLAN_PATCH_TIMEOUT, default 60s; no timeout(1),
# which stock macOS does not ship). Expiry is NOT failure: killing the call does not un-send it,
# so the read-back — which costs 0.4s against the real API — is what decides the verdict.

# Runs the tick with a stub that sleeps past the deadline; leaves the exit code in $RC and the
# wall-clock cost in $ELAPSED. No command substitution around the call: an orphaned child would
# hold the pipe open and hide the very stall being measured.
run_bounded() {
  local name="$1" timeout="$2"; shift 2
  fresh_log "$name"
  local start; start=$(date +%s)
  RC=0
  TICK_PLAN_PATCH_TIMEOUT="$timeout" "$@" > "$WORK/out.$name" 2>&1 || RC=$?
  ELAPSED=$(( $(date +%s) - start ))
}

# Same, but captures through a PIPE — which is how a caller actually runs this script (a command
# substitution, an agent harness reading stdout/stderr). The distinction is the whole of #135: a
# file has no EOF to wait on, so redirecting to one cannot observe a descendant of a bounded call
# still holding the inherited stdout/stderr open. Measured before the fix, same 2s deadline against
# the same 60s call: 4s to a file, 60s to a pipe, byte-identical output and exit 0 either way.
run_bounded_piped() {
  local name="$1" timeout="$2"; shift 2
  fresh_log "$name"
  local start; start=$(date +%s)
  RC=0
  local out
  out=$(TICK_PLAN_PATCH_TIMEOUT="$timeout" "$@" 2>&1) || RC=$?
  ELAPSED=$(( $(date +%s) - start ))
  printf '%s\n' "$out" > "$WORK/out.$name"
}

# 9b. The deadline has exactly ONE home. Two `gh` calls need bounding (#135), and this repo's grain
#     says a shared mechanism lives in one place — `tests/_lib.sh` exists because ten copies of a
#     preamble had already diverged (#72). A hand-copied second escalation would satisfy every
#     behavioural case below and still be the defect, so assert the shape directly.
run_bounded_defs=$(grep -c '^run_bounded()' "$TICK" || true)
[ "$run_bounded_defs" -eq 1 ] \
  || { echo "FAIL [helper-single-home]: expected exactly 1 run_bounded() definition in $TICK, found
        $run_bounded_defs — the deadline must have one home, not a copy per call site"; exit 1; }
# Comment lines are stripped first: the script quotes the phrase "needs kill -9" when explaining
# the report it was written against, and counting prose as an escalation is a false positive.
kill9_lines=$(grep -v '^[[:space:]]*#' "$TICK" | grep -c 'kill -9' || true)
[ "$kill9_lines" -eq 1 ] \
  || { echo "FAIL [helper-single-home]: expected exactly 1 line carrying the SIGKILL escalation in
        $TICK, found $kill9_lines — the deadline has been copied rather than shared"; exit 1; }
echo "  ok: helper-single-home — one run_bounded(), one SIGKILL escalation"

export GH_PATCH_SLEEP=6

# 10. Bounded, and GitHub holds what was sent → success, and back in a couple of seconds rather
#     than at the end of the sleep. Driven at 2s rather than 1s so the run has to actually WAIT:
#     `date +%s` is whole-second, so a 1s deadline can fire almost immediately and would pass even
#     if the timer measured nothing at all.
run_bounded bounded-match 2 "$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md"
[ "$RC" -eq 0 ] || { echo "FAIL [bounded-match]: expected success from the read-back, got exit $RC"
                     cat "$WORK/out.bounded-match"; exit 1; }
[ "$ELAPSED" -ge 1 ] || { echo "FAIL [bounded-match]: returned in ${ELAPSED}s with a 2s deadline —
        the timer is not measuring anything"; cat "$WORK/out.bounded-match"; exit 1; }
[ "$ELAPSED" -lt 5 ] || { echo "FAIL [bounded-match]: took ${ELAPSED}s — the PATCH was not bounded"
                          cat "$WORK/out.bounded-match"; exit 1; }
grep -q 'body verified intact' "$WORK/out.bounded-match" \
  || { echo "FAIL [bounded-match]: no verified-intact verdict"; cat "$WORK/out.bounded-match"; exit 1; }
grep -qi 'bounded' "$WORK/out.bounded-match" \
  || { echo "FAIL [bounded-match]: the output does not say the call was bounded, so a reader cannot
        tell the two success paths apart"; cat "$WORK/out.bounded-match"; exit 1; }
echo "  ok: bounded-match — bounded at 2s, verdict from the read-back (${ELAPSED}s, sleep was 6s)"

# 11. Bounded, but GitHub holds something else → the existing ALERT, exit 1. A killed call must
#     never be allowed to launder a mismatch into success.
#     2s, not 1s: the read-back now goes through tracker.sh (#751) — a few more process starts — and
#     a 1s deadline cut it short under a parallel suite run, turning this case into "read-back
#     bounded" instead of "body differs". The PATCH still sleeps 6s, so `-lt 6` still proves it was cut.
export GH_MANGLE_STORE=1
run_bounded bounded-differs 2 "$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md"
unset GH_MANGLE_STORE
[ "$RC" -eq 1 ] || { echo "FAIL [bounded-differs]: expected exit 1, got $RC"
                     cat "$WORK/out.bounded-differs"; exit 1; }
grep -q 'ALERT' "$WORK/out.bounded-differs" \
  || { echo "FAIL [bounded-differs]: no ALERT on a mismatched body"; cat "$WORK/out.bounded-differs"; exit 1; }
[ "$ELAPSED" -lt 6 ] || { echo "FAIL [bounded-differs]: took ${ELAPSED}s — the PATCH was not bounded"; exit 1; }
# ...and it must NOT tell the reader to restore. After a cut-short PATCH the write most likely never
# landed, so restoring is either a no-op or it un-ticks a write that arrives a moment later.
grep -q 'Do NOT restore' "$WORK/out.bounded-differs" \
  || { echo "FAIL [bounded-differs]: the bounded mismatch still advises a restore"
       cat "$WORK/out.bounded-differs"; exit 1; }
echo "  ok: bounded-differs — bounded, mismatch still ALERTs and exits 1, without advising a restore"

# 11b. A call that ignores SIGTERM must still be bounded. A deadline that only asks politely is
#      advisory: `wait` then blocks for the whole call and the stall comes straight back.
export GH_PATCH_IGNORE_TERM=1 GH_PATCH_SLEEP=20
run_bounded bounded-stubborn 1 "$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md"
unset GH_PATCH_IGNORE_TERM
export GH_PATCH_SLEEP=6
[ "$RC" -eq 0 ] || { echo "FAIL [bounded-stubborn]: expected success from the read-back, got exit $RC"
                     cat "$WORK/out.bounded-stubborn"; exit 1; }
[ "$ELAPSED" -lt 10 ] || { echo "FAIL [bounded-stubborn]: took ${ELAPSED}s of a 20s call — SIGTERM was
        ignored and nothing escalated, so the deadline is advisory"; cat "$WORK/out.bounded-stubborn"; exit 1; }
echo "  ok: bounded-stubborn — a TERM-ignoring call is escalated and still bounded (${ELAPSED}s of 20s)"

# 11c. The bound must release the CALLER, not merely the script's own control flow. Killing the one
#      pid bash returns leaves any descendant of the bounded call alive, still holding the stdout
#      and stderr it inherited — so a caller reading this script through a pipe blocks for the full
#      duration of the very call the deadline reported bounding, and reports success at the end of
#      it (#135). The stubborn stub is the right shape here because it spawns `sleep` as a child.
export GH_PATCH_IGNORE_TERM=1 GH_PATCH_SLEEP=20
run_bounded_piped bounded-releases-the-caller 2 \
  "$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md"
unset GH_PATCH_IGNORE_TERM
export GH_PATCH_SLEEP=6
[ "$RC" -eq 0 ] || { echo "FAIL [bounded-releases-the-caller]: expected success from the read-back, got exit $RC"
                     cat "$WORK/out.bounded-releases-the-caller"; exit 1; }
[ "$ELAPSED" -lt 10 ] || { echo "FAIL [bounded-releases-the-caller]: the caller waited ${ELAPSED}s of a
        20s call. The deadline bounded the script's control flow but not the job — a surviving
        descendant still holds the pipe, so the bound buys the caller nothing"
                           cat "$WORK/out.bounded-releases-the-caller"; exit 1; }
grep -q 'body verified intact' "$WORK/out.bounded-releases-the-caller" \
  || { echo "FAIL [bounded-releases-the-caller]: no verified-intact verdict"
       cat "$WORK/out.bounded-releases-the-caller"; exit 1; }
echo "  ok: bounded-releases-the-caller — a piped caller is released at the deadline (${ELAPSED}s of 20s)"

# 12. Bounded AND the read-back failed → nothing at all confirms what GitHub holds, so the script
#     must not report success. This is the one path where the sole authority is unavailable.
export GH_READ_FAIL=1
run_bounded bounded-unverified 1 "$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md"
unset GH_READ_FAIL
[ "$RC" -ne 0 ] || { echo "FAIL [bounded-unverified]: claimed success with no evidence either way"
                     cat "$WORK/out.bounded-unverified"; exit 1; }
grep -q 'ALERT' "$WORK/out.bounded-unverified" \
  || { echo "FAIL [bounded-unverified]: no ALERT"; cat "$WORK/out.bounded-unverified"; exit 1; }
echo "  ok: bounded-unverified — bounded + unreadable = no verdict, and it says so"

unset GH_PATCH_SLEEP

# 13. Unbounded PATCH whose read-back fails keeps today's softer contract: gh itself reported
#     success, so this stays a WARNING and exit 0 rather than becoming an error.
fresh_log warn-unverified
export GH_READ_FAIL=1
RC=0
"$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md" \
  > "$WORK/out.warn-unverified" 2>&1 || RC=$?
unset GH_READ_FAIL
[ "$RC" -eq 0 ] || { echo "FAIL [warn-unverified]: a successful PATCH must not fail on a read-back hiccup"
                     cat "$WORK/out.warn-unverified"; exit 1; }
grep -q 'WARNING' "$WORK/out.warn-unverified" \
  || { echo "FAIL [warn-unverified]: no WARNING"; cat "$WORK/out.warn-unverified"; exit 1; }
# The summary line must not contradict that warning by claiming the body was verified — nothing
# was read back, so there is nothing behind such a claim.
grep -q 'body verified intact' "$WORK/out.warn-unverified" \
  && { echo "FAIL [warn-unverified]: warned 'unverified' on stderr and claimed 'verified intact' on stdout"
       cat "$WORK/out.warn-unverified"; exit 1; }
echo "  ok: warn-unverified — unbounded + unreadable stays a WARNING, and claims no verification"

# 14. A PATCH that fails on its own is still a refusal — nothing was sent, so there is nothing to
#     read back. The exit status now arrives via `wait` on a backgrounded call rather than from a
#     foreground `if !`, which is new machinery and worth pinning.
fresh_log patch-failed
export GH_PATCH_FAIL=1
RC=0
"$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md" \
  > "$WORK/out.patch-failed" 2>&1 || RC=$?
unset GH_PATCH_FAIL
[ "$RC" -ne 0 ] || { echo "FAIL [patch-failed]: a failed PATCH reported success"
                     cat "$WORK/out.patch-failed"; exit 1; }
grep -q 'REFUSED' "$WORK/out.patch-failed" \
  || { echo "FAIL [patch-failed]: no REFUSED"; cat "$WORK/out.patch-failed"; exit 1; }
grep -qE 'jq .body|issue view' "$GH_CALL_LOG" \
  && { echo "FAIL [patch-failed]: read back a body after a PATCH that never landed"
       cat "$GH_CALL_LOG"; exit 1; }
echo "  ok: patch-failed — a failing PATCH still REFUSES, with no read-back"

# 15a. The read-back is bounded too, after a PATCH that succeeded on its own. Bounding one of the
#      two `gh` calls does not remove #113's failure mode, it relocates it — and the bounded PATCH
#      path *guarantees* the read-back runs next, because expiry is a deliberate handover to it.
#      A cut-short read-back is a FAILED read-back: the authority did not answer, so this routes to
#      the existing WARNING (the PATCH itself reported success, so the write almost certainly
#      landed) rather than inventing a fourth verdict.
export GH_READ_SLEEP=20
run_bounded readback-bounded-clean-patch 2 \
  "$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md"
unset GH_READ_SLEEP
[ "$RC" -eq 0 ] || { echo "FAIL [readback-bounded-clean-patch]: a successful PATCH must not fail on a
        bounded read-back, got exit $RC"; cat "$WORK/out.readback-bounded-clean-patch"; exit 1; }
[ "$ELAPSED" -lt 10 ] || { echo "FAIL [readback-bounded-clean-patch]: took ${ELAPSED}s of a 20s
        read-back — the read-back is still unbounded, so #113's stall just moved one line down"
                           cat "$WORK/out.readback-bounded-clean-patch"; exit 1; }
grep -q 'NOT verified' "$WORK/out.readback-bounded-clean-patch" \
  || { echo "FAIL [readback-bounded-clean-patch]: a bounded read-back verified nothing, so the
        summary must not claim it did"; cat "$WORK/out.readback-bounded-clean-patch"; exit 1; }
echo "  ok: readback-bounded-clean-patch — bounded read-back = failed read-back (${ELAPSED}s of 20s)"

# 15b. Both legs cut short: nothing establishes what GitHub now holds, so this is the ALERT the
#      contract already defines for "bounded PATCH + no answer", not a success and not a warning.
export GH_PATCH_IGNORE_TERM=1 GH_PATCH_SLEEP=20 GH_READ_SLEEP=20
run_bounded readback-bounded-after-bounded-patch 2 \
  "$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md"
unset GH_PATCH_IGNORE_TERM GH_READ_SLEEP GH_PATCH_SLEEP
[ "$RC" -ne 0 ] || { echo "FAIL [readback-bounded-after-bounded-patch]: claimed success with nothing
        confirming either leg"; cat "$WORK/out.readback-bounded-after-bounded-patch"; exit 1; }
grep -q 'ALERT' "$WORK/out.readback-bounded-after-bounded-patch" \
  || { echo "FAIL [readback-bounded-after-bounded-patch]: no ALERT"
       cat "$WORK/out.readback-bounded-after-bounded-patch"; exit 1; }
[ "$ELAPSED" -lt 20 ] || { echo "FAIL [readback-bounded-after-bounded-patch]: took ${ELAPSED}s of two
        20s calls — at least one leg ran unbounded"
                           cat "$WORK/out.readback-bounded-after-bounded-patch"; exit 1; }
echo "  ok: readback-bounded-after-bounded-patch — both legs bounded, ALERT stands (${ELAPSED}s)"

# 15c. A REAL body must not cost minutes of CPU. The emptiness check ran the whole fetched body
#      through `${got//[[:space:]]/}`, and bash 3.2's pattern substitution is O(n^2) in the subject
#      length — measured on a live 15.8KB issue body: 4KB 5s, 8KB 33s, 15.8KB 247s, all of it pure
#      CPU *after* the PATCH has landed, with no deadline over it because it is not a `gh` call at
#      all. That is the "hangs after a successful PATCH, needs kill -9" report behind #135. The
#      bodies elsewhere in this suite are a few hundred bytes, which is why it never showed here.
fresh_log big-body-is-not-quadratic
big_before="$WORK/big-before.md"; big_after="$WORK/big-after.md"
{
  echo '## Implementation plan'
  echo
  i=0
  while [ "$i" -lt 120 ]; do
    echo "- [ ] **Step $i:** a step whose text is long enough to make this body realistic, because"
    echo "      the defect is quadratic in body size and a toy body cannot show it."
    i=$(( i + 1 ))
  done
} > "$big_before"
sed '3s/^- \[ \]/- [x]/' "$big_before" > "$big_after"
[ "$(wc -c < "$big_before" | tr -d ' ')" -ge 8000 ] \
  || { echo "FAIL [big-body-is-not-quadratic]: fixture body is too small to exercise the defect"; exit 1; }
run_bounded big-body-is-not-quadratic 60 "$TICK" --repo o/r --issue 42 \
  --before "$big_before" --after "$big_after"
[ "$RC" -eq 0 ] || { echo "FAIL [big-body-is-not-quadratic]: expected success, got exit $RC"
                     cat "$WORK/out.big-body-is-not-quadratic"; exit 1; }
[ "$ELAPSED" -lt 10 ] || { echo "FAIL [big-body-is-not-quadratic]: a $(wc -c < "$big_before" | tr -d ' ')-byte
        body took ${ELAPSED}s with a stub that answers instantly — the script is spending it in
        pure bash, not on the network. This is the post-PATCH stall no deadline can see"
                           cat "$WORK/out.big-body-is-not-quadratic"; exit 1; }
echo "  ok: big-body-is-not-quadratic — $(wc -c < "$big_before" | tr -d ' ') bytes ticked in ${ELAPSED}s"

# 15e. The escalation must reach the GROUP even once the group LEADER has gone. The read-back runs
#      through a shell function, so bash forks a subshell as leader with `gh` as its child — and a
#      subshell dies on SIGTERM in milliseconds no matter how stubborn the call underneath it is.
#      Gating SIGKILL on `kill -0 "$leader"` therefore skips the escalation in exactly the case it
#      exists for, and the surviving child keeps whatever it inherited open. "SIGKILL cannot be
#      ignored, which is what makes the bound a bound" is only true if the signal is actually sent.
export GH_READ_IGNORE_TERM=1 GH_READ_SLEEP=25 GH_READ_PID="$WORK/read.pid"
rm -f "$WORK/read.pid"
run_bounded readback-escalates-to-the-group 2 \
  "$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md"
unset GH_READ_IGNORE_TERM GH_READ_SLEEP
[ "$ELAPSED" -lt 12 ] || { echo "FAIL [readback-escalates-to-the-group]: took ${ELAPSED}s of a 25s
        read-back"; cat "$WORK/out.readback-escalates-to-the-group"; exit 1; }
read_pid=$(cat "$WORK/read.pid" 2>/dev/null || true)
[ -n "$read_pid" ] || { echo "FAIL [readback-escalates-to-the-group]: the stub never recorded a pid,
        so this case proves nothing"; exit 1; }
sleep 1
if kill -0 "$read_pid" 2>/dev/null; then
  kill -9 -- -"$read_pid" 2>/dev/null || kill -9 "$read_pid" 2>/dev/null || true
  echo "FAIL [readback-escalates-to-the-group]: the read-back call (pid $read_pid) outlived the
        deadline. Its group leader exited on TERM, so the SIGKILL gated on the leader never fired
        and the group was never escalated — the orphan lives on holding what it inherited"
  exit 1
fi
echo "  ok: readback-escalates-to-the-group — the whole group dies, not just the leader"

# 15f. `die` prints REFUSED, and REFUSED is documented — in this script's header and in
#      references/github-mechanics.md — as "nothing was sent". After the PATCH has left, that
#      message is a lie with teeth: the documented response to REFUSED is to leave the issue alone
#      or restore from --before, which would un-tick a write that actually landed. So no `die` may
#      appear after the write.
patch_line=$(grep -n 'run_bounded /dev/null' "$TICK" | head -1 | cut -d: -f1)
[ -n "$patch_line" ] || { echo "FAIL [refused-means-nothing-sent]: cannot locate the PATCH call in
        $TICK, so this case cannot check anything"; exit 1; }
# Exactly ONE die() is legitimate after that point: the one reached only when `gh` itself reported
# the PATCH failed, where "nothing was sent" is still true. Any other — a scratch file that could
# not be created, a validation added later — fires on a path where the write may already have
# landed, and that is the lie. So pin the count and pin which one it is.
post_write_dies=$(tail -n "+$patch_line" "$TICK" | grep -c 'die "' || true)
[ "$post_write_dies" -eq 1 ] || { echo "FAIL [refused-means-nothing-sent]: $post_write_dies die()
        calls appear after the PATCH is sent (line $patch_line), expected exactly 1. REFUSED means
        'nothing was sent'; reached after the write has left, it tells the agent to restore — and
        that un-ticks a write that landed"
                                  tail -n "+$patch_line" "$TICK" | grep -n 'die "' | sed 's/^/        /'
                                  exit 1; }
# Herestring, not a pipe into `grep -q` (#391): `tail`/`grep` over the script can still be writing
# when the final match closes the read end.
post_write_die_lines=$(tail -n "+$patch_line" "$TICK" | grep 'die "')
grep -q 'NOT changed' <<<"$post_write_die_lines" \
  || { echo "FAIL [refused-means-nothing-sent]: the one post-write die() is no longer the
        failed-PATCH one, so it may fire on a path where the write already landed"; exit 1; }
echo "  ok: refused-means-nothing-sent — the only post-write die() is the failed-PATCH one"

# 15d. The knob is named where the agent actually reads it. The script header and
#      references/github-mechanics.md document `TICK_PLAN_PATCH_TIMEOUT`, but SKILL.md Step 6 — the
#      text an agent has open while ticking — did not, so the exit-1 bounded paths had no
#      documented recovery at the point of use. A run that stalls despite a documented timeout is
#      also indistinguishable from one with no timeout at all, which is how #135 was first
#      misdiagnosed as "the deadline shells out to timeout(1), which macOS lacks".
grep -q 'TICK_PLAN_PATCH_TIMEOUT' skills/implement-issue/references/steps/06-implementation-loop.md \
  || { echo "FAIL [docs-name-the-knob]: SKILL.md never names TICK_PLAN_PATCH_TIMEOUT, so the agent
        ticking a box cannot tell a bounded call from a broken one"; exit 1; }
echo "  ok: docs-name-the-knob — SKILL.md names the deadline knob"

# 15. The deadline must be a sane number: a junk value is caught before anything is sent.
refuses bad-timeout env TICK_PLAN_PATCH_TIMEOUT=soon \
  "$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md"

# 16. A text-mode jq stdout must not make a correct payload look wrong (#199). On Git Bash/msys,
#     `jq -j` rewrites every \n it emits as \r\n; that reproduces the condition on any host by
#     wrapping the real jq and doctoring only its `-j` output, so a literal `jq -j '.body' | diff`
#     — the pattern that shipped the #199 bug — sees exactly what a Windows agent saw. This pins a
#     REGRESSION (nobody may reintroduce that stdout-based comparison), not a live property of the
#     fixed script: tick-plan.sh no longer calls jq with `-j` anywhere, and the `--rawfile` compare
#     it uses instead never routes body text through a stdout at all — it is judged purely by jq's
#     exit code — so there is no stdout boundary left here for this stub to corrupt. A genuinely
#     correct tick must still be ACCEPTED either way — the corruption this case models is confined
#     to a verification leg the current code no longer has.
REAL_JQ="$(command -v jq)"
mkdir -p "$WORK/binjq"
# $REAL_JQ (from `command -v jq`) travels via the ENVIRONMENT, never embedded as a string literal
# in the generated script: it is untrusted input, and splicing it into a shell heredoc/sed
# expression corrupts the stub the moment the path contains a shell-special character.
cat > "$WORK/binjq/jq" <<'STUB'
#!/usr/bin/env bash
# Wraps the real jq, reached via $REAL_JQ in the environment. A `-j` invocation gets \r appended
# to every line of its output, reproducing Git Bash's text-mode stdout. Every other jq call
# (payload build, length check, and the round-trip comparison itself, which never uses -j) passes
# straight through untouched.
for a in "$@"; do
  if [ "$a" = "-j" ]; then
    "$REAL_JQ" "$@" | sed $'s/$/\r/'
    exit "${PIPESTATUS[0]}"
  fi
done
exec "$REAL_JQ" "$@"
STUB
chmod +x "$WORK/binjq/jq"

fresh_log crlf-jq-stdout
( PATH="$WORK/binjq:$PATH"; export PATH REAL_JQ
  "$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md" \
    > "$WORK/out.crlf-jq-stdout" 2>&1 ) \
  || { echo "FAIL [crlf-jq-stdout]: a correct tick was refused under a text-mode jq -j stdout (#199)"
       cat "$WORK/out.crlf-jq-stdout"; exit 1; }
echo "  ok: crlf-jq-stdout — a text-mode jq -j stdout does not refuse a correct tick"

# 17. Read-back leg (#215 Task 1). Unlike case 16's round-trip check — entirely local, no network
#     fetch needed, so #199's fix could avoid the stdout boundary altogether — this leg's read of
#     what GitHub now holds MUST cross gh's own stdout to reach us; there is no way to skip that
#     boundary. GH_READBACK_CRLF models a text-mode `gh` stdout on the read (`--jq .body`) call
#     only (the PATCH leg is untouched), isolating the read-back comparison specifically. A
#     genuinely correct write must still be reported verified, not escalated to a false ALERT.
fresh_log crlf-readback-stdout
export GH_READBACK_CRLF=1
crlf_readback_rc=0
"$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md" \
  > "$WORK/out.crlf-readback-stdout" 2>&1 || crlf_readback_rc=$?
unset GH_READBACK_CRLF
[ "$crlf_readback_rc" -eq 0 ] \
  || { echo "FAIL [crlf-readback-stdout]: a correct write was refused/ALERTed under a text-mode gh
        stdout on the read-back leg (#215)"; cat "$WORK/out.crlf-readback-stdout"; exit 1; }
grep -q 'body verified intact' "$WORK/out.crlf-readback-stdout" \
  || { echo "FAIL [crlf-readback-stdout]: no verified-intact verdict"; cat "$WORK/out.crlf-readback-stdout"; exit 1; }
echo "  ok: crlf-readback-stdout — a text-mode gh stdout on the read-back does not falsely ALERT (#215)"

# 18. The checkbox-only-diff guard (#215 Task 2). Unlike the read-back leg, BOTH operands here
#     (--before and --after) are transformed by the SAME tool (unticked_form, which shells out to
#     sed) before being compared, so a corruption sed applies uniformly to every invocation lands
#     on both sides identically and cancels out in the diff. Modelled the same way case 16 models
#     jq -j: wrap the real sed (reached via $REAL_SED in the environment, never spliced into the
#     generated script as a literal — same untrusted-path reasoning as case 16's $REAL_JQ) and
#     append \r to every line it emits, scoped to just this invocation.
REAL_SED="$(command -v sed)"
mkdir -p "$WORK/binsed"
cat > "$WORK/binsed/sed" <<'STUB'
#!/usr/bin/env bash
# Wraps the real sed, reached via $REAL_SED in the environment, and appends \r to every line it
# emits. unticked_form is the only sed call tick-plan.sh makes on this path, so wrapping every sed
# invocation here is fine.
"$REAL_SED" "$@" | "$REAL_SED" $'s/$/\r/'
STUB
chmod +x "$WORK/binsed/sed"

fresh_log crlf-checkbox-diff-sed-stdout
( PATH="$WORK/binsed:$PATH"; export PATH REAL_SED
  "$TICK" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md" \
    > "$WORK/out.crlf-checkbox-diff-sed-stdout" 2>&1 ) \
  || { echo "FAIL [crlf-checkbox-diff-sed-stdout]: a correct tick was refused under a text-mode sed
        stdout on the checkbox-only-diff guard (#215)"
       cat "$WORK/out.crlf-checkbox-diff-sed-stdout"; exit 1; }
echo "  ok: crlf-checkbox-diff-sed-stdout — a text-mode sed stdout does not break the checkbox-only-diff guard (#215)"

# ---------------------------------------------------------------- the repository's own host (#514)
#
# `gh api` never infers a host, so on a GitHub Enterprise repository a bare OWNER/REPO reached
# github.com: 13 refused ticks in 7 sessions. The seam is the stub's log — the GH_HOST each call ran
# under, and the endpoint it was asked for.

# has_call <name> <ERE> — the case's gh log holds a line matching <ERE>, or the case fails.
has_call() {
  grep -qE -- "$2" "$GH_CALL_LOG" \
    || { echo "FAIL [$1]: gh was never called as /$2/"; cat "$GH_CALL_LOG"; exit 1; }
}

# 19. A checkout whose origin is on a GHE host: the PATCH and the read-back both reach that host.
CO_GHE="$WORK/co-ghe"
git init -q "$CO_GHE"
git -C "$CO_GHE" remote add origin git@ghe.example.com:acme/widgets.git
fresh_log ghe-origin
( cd "$CO_GHE" && GH_STUB_HOSTS=ghe.example.com "$KIT_ROOT/$TICK" --repo acme/widgets --issue 42 \
    --before "$BEFORE" --after "$WORK/ticked.md" > "$WORK/out.ghe-origin" 2>&1 ) \
  || { echo "FAIL [ghe-origin]: a legitimate tick was refused"; cat "$WORK/out.ghe-origin"; exit 1; }
has_call ghe-origin '^GH_HOST=ghe\.example\.com ARGS: issue edit 42 --repo acme/widgets --body-file '
has_call ghe-origin '^GH_HOST=ghe\.example\.com ARGS: issue view 42 --repo acme/widgets --json '
echo "  ok: ghe-origin — the PATCH and the read-back both ran under GH_HOST=ghe.example.com"

# 20. A HOST/ prefix on --repo names the host outright; it never leaks into the endpoint.
fresh_log ghe-prefix
"$TICK" --repo ghe.example.com/acme/widgets --issue 42 --before "$BEFORE" --after "$WORK/ticked.md" \
  > "$WORK/out.ghe-prefix" 2>&1 \
  || { echo "FAIL [ghe-prefix]: a legitimate tick was refused"; cat "$WORK/out.ghe-prefix"; exit 1; }
has_call ghe-prefix '^GH_HOST=ghe\.example\.com ARGS: issue edit 42 --repo acme/widgets --body-file '
has_call ghe-prefix '^GH_HOST=ghe\.example\.com ARGS: issue view 42 --repo acme/widgets --json '
if grep -q 'repos/ghe\.example\.com' "$GH_CALL_LOG"; then
  echo "FAIL [ghe-prefix]: the host leaked into the endpoint"; cat "$GH_CALL_LOG"; exit 1
fi
echo "  ok: ghe-prefix — repository acme/widgets, under GH_HOST=ghe.example.com"

# 21. A malformed slug is a usage error: exit 1, the slug named, and gh never called.
fresh_log malformed-slug
RC=0
"$TICK" --repo acme --issue 42 --before "$BEFORE" --after "$WORK/ticked.md" \
  > "$WORK/out.malformed-slug" 2>&1 || RC=$?
[ "$RC" -eq 1 ] || { echo "FAIL [malformed-slug]: expected exit 1, got $RC"; cat "$WORK/out.malformed-slug"; exit 1; }
[ ! -s "$GH_CALL_LOG" ] || { echo "FAIL [malformed-slug]: gh was called:"; cat "$GH_CALL_LOG"; exit 1; }
grep -qF "malformed repository slug 'acme'" "$WORK/out.malformed-slug" \
  || { echo "FAIL [malformed-slug]: stderr does not name the slug"; cat "$WORK/out.malformed-slug"; exit 1; }
echo "  ok: malformed-slug — exit 1, slug named, no gh call"

# 22. The host helper is part of the install: without it the tick refuses, naming the missing file,
#     rather than falling back to gh's default host — the exact #514 failure.
NOHELPER="$WORK/nohelper/skills/implement-issue/scripts"
mkdir -p "$NOHELPER"
cp "$TICK" "$NOHELPER/tick-plan.sh"
fresh_log missing-helper
RC=0
bash "$NOHELPER/tick-plan.sh" --repo o/r --issue 42 --before "$BEFORE" --after "$WORK/ticked.md" \
  > "$WORK/out.missing-helper" 2>&1 || RC=$?
[ "$RC" -eq 1 ] || { echo "FAIL [missing-helper]: expected exit 1, got $RC"; cat "$WORK/out.missing-helper"; exit 1; }
[ ! -s "$GH_CALL_LOG" ] || { echo "FAIL [missing-helper]: gh was called:"; cat "$GH_CALL_LOG"; exit 1; }
grep -qF '_shared/scripts/_gh-host.sh; reinstall the kit' "$WORK/out.missing-helper" \
  || { echo "FAIL [missing-helper]: stderr does not name the missing helper"; cat "$WORK/out.missing-helper"; exit 1; }
echo "  ok: missing-helper — exit 1, the missing helper named, no gh call"

# 23. A comment-hosted plan is a GitHub-only shape (#751): on a GitLab-profiled checkout
#     --comment-id is refused by name before anything is sent — no gh call, no glab call.
CO_GL="$WORK/co-gitlab"
mkdir -p "$CO_GL/.claude/skills"
git init -q "$CO_GL"
printf '%s\n' '# Repo profile' '' '## Tracker' '- **Tracker:** gitlab (gitlab.com)' \
  > "$CO_GL/.claude/skills/repo-profile.md"
GLAB_CALL_LOG="$WORK/glab-calls.log"; export GLAB_CALL_LOG; : > "$GLAB_CALL_LOG"
printf '#!/usr/bin/env bash\necho "$*" >> "$GLAB_CALL_LOG"\nexit 1\n' > "$WORK/bin/glab"
chmod +x "$WORK/bin/glab"
fresh_log gitlab-comment
RC=0
( cd "$CO_GL" && "$KIT_ROOT/$TICK" --repo g/p --issue 42 --comment-id 5 \
    --before "$BEFORE" --after "$WORK/ticked.md" > "$WORK/out.gitlab-comment" 2>&1 ) || RC=$?
[ "$RC" -ne 0 ] || { echo "FAIL [gitlab-comment]: a comment plan on GitLab was not refused"; exit 1; }
grep -qF 'a plan hosted in a comment is a GitHub-only shape (#750)' "$WORK/out.gitlab-comment" \
  || { echo "FAIL [gitlab-comment]: the refusal does not name the GitHub-only shape"; cat "$WORK/out.gitlab-comment"; exit 1; }
[ ! -s "$GH_CALL_LOG" ] && [ ! -s "$GLAB_CALL_LOG" ] \
  || { echo "FAIL [gitlab-comment]: a host was called"; cat "$GH_CALL_LOG" "$GLAB_CALL_LOG"; exit 1; }
echo "  ok: gitlab-comment — --comment-id on GitLab is refused by name, nothing sent"

# 24. The body path on GitLab (#751): a tick is PUT as the issue description, read back through
#     issue-view and verified; an edit that is not a checkbox flip is REFUSED with no glab call.
#     A stateful glab stub: PUT stores the description file, GET serves it back as GitLab's JSON.
GLAB_STORE="$WORK/glab-store.md"; export GLAB_STORE
cat > "$WORK/bin/glab" <<'GLAB'
#!/usr/bin/env bash
echo "$*" >> "$GLAB_CALL_LOG"
[ "${1:-}" = api ] || exit 1
method=GET; f=""; prev=""
for a in "$@"; do
  case "$prev" in
    -X) method="$a" ;;
    -F) case "$a" in description=@*) f="${a#description=@}" ;; esac ;;
  esac
  prev="$a"
done
if [ "$method" = PUT ]; then cp "$f" "$GLAB_STORE"; echo '{}'; exit 0; fi
jq -Rs '{iid: 42, title: "t", state: "opened", labels: [], web_url: "u", description: .}' < "$GLAB_STORE"
GLAB
chmod +x "$WORK/bin/glab"
cp "$BEFORE" "$GLAB_STORE"
fresh_log gitlab-tick; : > "$GLAB_CALL_LOG"
( cd "$CO_GL" && "$KIT_ROOT/$TICK" --repo g/p --issue 42 --before "$BEFORE" --after "$WORK/ticked.md" \
    > "$WORK/out.gitlab-tick" 2>&1 ) \
  || { echo "FAIL [gitlab-tick]: a legitimate GitLab tick was refused"; cat "$WORK/out.gitlab-tick"; exit 1; }
grep -q 'body verified intact' "$WORK/out.gitlab-tick" \
  || { echo "FAIL [gitlab-tick]: no verified-intact verdict"; cat "$WORK/out.gitlab-tick"; exit 1; }
cmp -s "$GLAB_STORE" "$WORK/ticked.md" \
  || { echo "FAIL [gitlab-tick]: GitLab does not hold the ticked body byte for byte"; exit 1; }
grep -q -- '-X PUT projects/g%2Fp/issues/42 -F description=@' "$GLAB_CALL_LOG" \
  || { echo "FAIL [gitlab-tick]: the description was not PUT"; cat "$GLAB_CALL_LOG"; exit 1; }
[ ! -s "$GH_CALL_LOG" ] || { echo "FAIL [gitlab-tick]: gh was called on a GitLab profile"; cat "$GH_CALL_LOG"; exit 1; }
echo "  ok: gitlab-tick — PUT as the description, read back and verified, no gh call"

fresh_log gitlab-refuse; : > "$GLAB_CALL_LOG"
RC=0
( cd "$CO_GL" && "$KIT_ROOT/$TICK" --repo g/p --issue 42 --before "$BEFORE" --after "$WORK/mangled.md" \
    > "$WORK/out.gitlab-refuse" 2>&1 ) || RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUSED' "$WORK/out.gitlab-refuse" \
  || { echo "FAIL [gitlab-refuse]: a non-checkbox edit was not REFUSED"; cat "$WORK/out.gitlab-refuse"; exit 1; }
[ ! -s "$GLAB_CALL_LOG" ] || { echo "FAIL [gitlab-refuse]: glab was called"; cat "$GLAB_CALL_LOG"; exit 1; }
echo "  ok: gitlab-refuse — a non-checkbox edit is REFUSED with an empty glab log"

# 25. The body path on Azure DevOps (#751): the PATCH sets the description AND its Markdown format,
#     the tick is read back through issue-view and verified; a non-checkbox edit is REFUSED with no
#     az call. A stateful az stub: the workitems PATCH stores the patch, the GET serves it back.
CO_AZ="$WORK/co-azure"
mkdir -p "$CO_AZ/.claude/skills"
git init -q "$CO_AZ"
printf '%s\n' '# Repo profile' '' '## Tracker' '- **Tracker:** azure-devops (dev.azure.com/acme/Shop)' \
  > "$CO_AZ/.claude/skills/repo-profile.md"
AZ_CALL_LOG="$WORK/az-calls.log"; AZ_STORE="$WORK/az-store.md"; AZ_PATCH="$WORK/az-patch.json"
export AZ_CALL_LOG AZ_STORE AZ_PATCH
cat > "$WORK/bin/az" <<'AZ'
#!/usr/bin/env bash
echo "$*" >> "$AZ_CALL_LOG"
method=GET; f=""; prev=""
for a in "$@"; do
  case "$prev" in --http-method) method="$a" ;; --in-file) f="$a" ;; esac
  prev="$a"
done
if [ "$method" = PATCH ]; then
  cp "$f" "$AZ_PATCH"
  jq -j '.[] | select(.path == "/fields/System.Description") | .value' "$f" > "$AZ_STORE"
  echo '{}'; exit 0
fi
jq -Rs '{id: 42, fields: {"System.Title": "t", "System.State": "Active", "System.Description": .},
         multilineFieldsFormat: {"System.Description": "Markdown"}}' < "$AZ_STORE"
AZ
chmod +x "$WORK/bin/az"
cp "$BEFORE" "$AZ_STORE"
fresh_log azure-tick; : > "$AZ_CALL_LOG"
( cd "$CO_AZ" && "$KIT_ROOT/$TICK" --repo acme/Shop --issue 42 --before "$BEFORE" --after "$WORK/ticked.md" \
    > "$WORK/out.azure-tick" 2>&1 ) \
  || { echo "FAIL [azure-tick]: a legitimate Azure DevOps tick was refused"; cat "$WORK/out.azure-tick"; exit 1; }
grep -q 'body verified intact' "$WORK/out.azure-tick" \
  || { echo "FAIL [azure-tick]: no verified-intact verdict"; cat "$WORK/out.azure-tick"; exit 1; }
cmp -s "$AZ_STORE" "$WORK/ticked.md" \
  || { echo "FAIL [azure-tick]: Azure DevOps does not hold the ticked body byte for byte"; exit 1; }
[ "$(jq -r '.[] | select(.path == "/multilineFieldsFormat/System.Description") | .value' "$AZ_PATCH")" = Markdown ] \
  || { echo "FAIL [azure-tick]: the PATCH did not set the description format to Markdown"; cat "$AZ_PATCH"; exit 1; }
[ ! -s "$GH_CALL_LOG" ] || { echo "FAIL [azure-tick]: gh was called on an Azure DevOps profile"; cat "$GH_CALL_LOG"; exit 1; }
echo "  ok: azure-tick — PATCHed as Markdown, read back and verified, no gh call"

fresh_log azure-refuse; : > "$AZ_CALL_LOG"
RC=0
( cd "$CO_AZ" && "$KIT_ROOT/$TICK" --repo acme/Shop --issue 42 --before "$BEFORE" --after "$WORK/mangled.md" \
    > "$WORK/out.azure-refuse" 2>&1 ) || RC=$?
[ "$RC" -ne 0 ] && grep -q 'REFUSED' "$WORK/out.azure-refuse" \
  || { echo "FAIL [azure-refuse]: a non-checkbox edit was not REFUSED"; cat "$WORK/out.azure-refuse"; exit 1; }
[ ! -s "$AZ_CALL_LOG" ] || { echo "FAIL [azure-refuse]: az was called"; cat "$AZ_CALL_LOG"; exit 1; }
echo "  ok: azure-refuse — a non-checkbox edit is REFUSED with an empty az log"

echo "tick-plan golden test OK"
