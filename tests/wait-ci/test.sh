#!/usr/bin/env bash
# Golden test for skills/auto-dev/scripts/wait-ci.sh (#188).
#
# The script used to model a repo as having exactly ONE gating check, picked by a hardcoded
# default name (`CHECK="Build & Test"`) and matched against `gh pr checks`'s plain-text table.
# On a repo with two independently-gating checks (this kit's own `kit` + `title-gate`) no single
# name is correct: the default matches nothing and hangs to MAX_POLLS/exit 1, and setting CHECK to
# either name false-greens past the other.
#
# Field/vocabulary pin (Task 1 Step 1, gh 2.97.0, measured 2026-08-30):
#   $ gh pr checks --help
#     JSON FIELDS: bucket, completedAt, description, event, link, name, startedAt, state, workflow
#     "the --json flag ... includes a `bucket` field, which categorizes the `state` field into
#      `pass`, `fail`, `pending`, `skipping`, or `cancel`"
#   $ gh pr checks <a real PR> --json name,state,bucket
#     [{"bucket":"pass","name":"kit","state":"SUCCESS"}, {"bucket":"pass","name":"title-gate","state":"SUCCESS"}]
# `bucket` is gh's OWN classification (cli/cli pkg/cmd/pr/checks/aggregate.go: a switch on the raw
# check-run/status state that maps SUCCESS->pass, SKIPPED/NEUTRAL->skipping, the failure states->
# fail, CANCELLED->cancel, and everything else — QUEUED, IN_PROGRESS, PENDING, STALE, WAITING,
# ACTION_REQUIRED's absence, any future state gh adds — to the `pending` default case). So
# "final" = "bucket != pending" tracks exactly what the old script's `all_final` meant, without
# this script having to maintain its own copy of gh's raw-state vocabulary.
#
# Second pin, found by code review: gh does not print `[]` for a PR with zero checks — it FAILS
# the whole call, even with --json (cli/cli's `populateStatusChecks` errors before the exporter
# ever runs). Measured on PR #291 of this repo (a release-please branch with no CI wired):
#   $ gh pr checks 291 --json name,state,bucket ; echo $?
#     (stdout empty) / stderr: no checks reported on the 'release-please--...' branch / exit 1
# That is indistinguishable on stdout alone from a TRANSIENT gh failure (rate limit, network
# blip). Since #752 telling them apart is scripts/tracker/github.sh's job (`pr-checks` prints `[]`
# for that wording and fails on anything else): cases 6-7 pin the end-to-end outcome through the
# real backend, and cases 14-15 pin that the script itself reads only the verb's exit code and
# stdout, never folding a failure into "zero checks".
set -euo pipefail
cd "$(dirname "$0")/../.."

WAIT="./skills/auto-dev/scripts/wait-ci.sh"
[ -x "$WAIT" ] || { echo "FAIL: $WAIT missing or not executable"; exit 1; }
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Scratch dir and EXIT trap from the shared preamble (#72).
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
WORK=$(kit_scratch)

# A `gh` stub on PATH, answering the argv scripts/tracker/github.sh sends (#752: wait-ci.sh polls
# `tracker.sh pr-checks`, and github.sh makes the `gh pr checks` call the script used to make).
# `pr checks <pr> --json ...` (the poll query, and the final summary's) serves the Nth canned
# response under $GH_RESPONSES, clamped to the highest response actually written — a poll count
# beyond what a case scripted just repeats the last one, which is what "checks stay the same" or
# "no checks ever appear" both need. A response file starting with "ERR:" instead simulates gh
# FAILING: the rest of its content goes to stderr and the stub exits 1, matching real gh's shape for
# both a genuine zero-checks branch and a transient failure. `pr view` (pr-view's argv, the final
# summary) is a fixed reply: the summary's exact text is not what this suite pins.
#
# The same stub doubles as a `tracker.sh` stand-in (installed as <fake kit>/scripts/tracker.sh by
# cases 14-15): called as `pr-checks <pr>`, it serves the queue the same way, so a case can pin what
# wait-ci.sh does with the VERB's exit code and stdout, whatever text its stderr carries.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "ARGS: $*" >> "$GH_CALL_LOG"
case "$*" in
  *"pr checks"*"--json"*|"pr-checks "*)
    n=$(( $(cat "$GH_CALL_COUNT" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$GH_CALL_COUNT"
    max=$(cat "$GH_RESPONSES/max" 2>/dev/null || echo 1)
    use=$n
    [ "$use" -gt "$max" ] && use=$max
    content=$(cat "$GH_RESPONSES/$use.json")
    case "$content" in
      ERR:*)
        printf '%s\n' "${content#ERR:}" >&2
        exit 1
        ;;
      *)
        printf '%s' "$content"
        ;;
    esac
    ;;
  *"pr view"*)
    echo '{"number":1,"title":"t","url":"u","state":"OPEN","isDraft":false,"body":"","headRefName":"h","baseRefName":"main","headRefOid":"abc","author":{"login":"a"},"mergedAt":null,"mergeCommit":null}'
    ;;
  *)
    echo "STUB: unhandled gh invocation: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

# Arms a fresh scripted response queue: reset_case <name> <poll-1 JSON> [<poll-2 JSON> ...].
# A poll past the last argument repeats the last one (see the stub's `max` clamp above).
reset_case() {
  local name="$1"; shift
  GH_CALL_LOG="$WORK/gh-calls.$name.log"
  GH_CALL_COUNT="$WORK/gh-count.$name"
  GH_RESPONSES="$WORK/gh-resp.$name"
  export GH_CALL_LOG GH_CALL_COUNT GH_RESPONSES
  rm -rf "$GH_RESPONSES"; mkdir -p "$GH_RESPONSES"
  : > "$GH_CALL_LOG"
  rm -f "$GH_CALL_COUNT"
  local idx=1 resp
  for resp in "$@"; do
    printf '%s' "$resp" > "$GH_RESPONSES/$idx.json"
    idx=$((idx + 1))
  done
  echo "$((idx - 1))" > "$GH_RESPONSES/max"
}

has_poll() { grep -q "] poll $2:" <<<"$1"; }

# ---------------------------------------------------------------- 0. usage: no PR args refuses

rc=0
out=$("$WAIT" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [usage]: expected exit 2 with no PR args, got $rc"; echo "$out"; exit 1; }
echo "  ok: usage — no PR args refuses with exit 2"

# ---------------------------------------------------------------- 1. this repo's real shape:
# two independently-gating checks, one still running when the other has already finished.

reset_case shape \
  '[{"name":"kit","state":"IN_PROGRESS","bucket":"pending"},{"name":"title-gate","state":"SUCCESS","bucket":"pass"}]' \
  '[{"name":"kit","state":"SUCCESS","bucket":"pass"},{"name":"title-gate","state":"SUCCESS","bucket":"pass"}]'
rc=0
out=$(POLL_SECONDS=0 MAX_POLLS=5 "$WAIT" 42 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [shape]: expected exit 0, got $rc"; echo "$out"; exit 1; }
has_poll "$out" 1 || { echo "FAIL [shape]: missing poll 1"; echo "$out"; exit 1; }
has_poll "$out" 2 || { echo "FAIL [shape]: missing poll 2"; echo "$out"; exit 1; }
has_poll "$out" 3 && { echo "FAIL [shape]: polled a 3rd time — should have stopped once both were final"; echo "$out"; exit 1; }
echo "  ok: shape — waits through kit=IN_PROGRESS/title-gate=SUCCESS to both SUCCESS, no CHECK override needed"

# ---------------------------------------------------------------- 2. today's default-CHECK
# regression: CHECK unset (the fix — no hardcoded name), both checks already final on poll 1.
# Under the old script this hung to MAX_POLLS/exit 1 (CHECK="Build & Test" matches neither name).

reset_case default-check \
  '[{"name":"kit","state":"SUCCESS","bucket":"pass"},{"name":"title-gate","state":"SUCCESS","bucket":"pass"}]'
rc=0
out=$(POLL_SECONDS=0 MAX_POLLS=5 "$WAIT" 77 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [default-check]: expected exit 0 with CHECK unset, got $rc"; echo "$out"; exit 1; }
has_poll "$out" 1 || { echo "FAIL [default-check]: missing poll 1"; echo "$out"; exit 1; }
# One confirmation poll is required even when everything is final on poll 1 — stability can't be
# judged from a single poll with no prior count to compare against (#413).
has_poll "$out" 2 || { echo "FAIL [default-check]: missing the stability-confirmation poll 2"; echo "$out"; exit 1; }
has_poll "$out" 3 && { echo "FAIL [default-check]: polled a 3rd time — the set was already final and unchanged by poll 2"; echo "$out"; exit 1; }
echo "  ok: default-check — unset CHECK waits on every check by default and returns once final and stable"

# ---------------------------------------------------------------- 3. checks not yet registered:
# zero checks on poll 1, then they appear (already final) on poll 2 — no premature error.

reset_case zero-then-appear '[]' '[{"name":"kit","state":"SUCCESS","bucket":"pass"}]'
rc=0
out=$(POLL_SECONDS=0 MAX_POLLS=5 "$WAIT" 99 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [zero-then-appear]: expected exit 0, got $rc"; echo "$out"; exit 1; }
has_poll "$out" 1 || { echo "FAIL [zero-then-appear]: missing poll 1"; echo "$out"; exit 1; }
has_poll "$out" 2 || { echo "FAIL [zero-then-appear]: missing poll 2"; echo "$out"; exit 1; }
echo "  ok: zero-then-appear — a zero-check poll 1 (GitHub still registering the run) does not error"

# ---------------------------------------------------------------- 4. zero checks for the whole
# run: a fast, loud exit 2 well before MAX_POLLS, not a silent 60-minute poll to timeout.

reset_case zero-forever '[]'
rc=0
out=$(POLL_SECONDS=0 MAX_POLLS=5 "$WAIT" 5 2>&1) || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [zero-forever]: expected exit 2, got $rc"; echo "$out"; exit 1; }
grep -qi 'no checks found for PR 5' <<<"$out" || {
  echo "FAIL [zero-forever]: no clear message naming the PR with no checks"; echo "$out"; exit 1; }
has_poll "$out" 3 && { echo "FAIL [zero-forever]: should have failed fast, well before MAX_POLLS=5"; echo "$out"; exit 1; }
echo "  ok: zero-forever — fails fast (exit 2) instead of polling silently to MAX_POLLS"

# ---------------------------------------------------------------- 5. CHECK as an optional
# allow-list: with CHECK=kit, an unrelated check that never finishes must not block completion.

reset_case allow-list \
  '[{"name":"kit","state":"IN_PROGRESS","bucket":"pending"},{"name":"unrelated","state":"IN_PROGRESS","bucket":"pending"}]' \
  '[{"name":"kit","state":"SUCCESS","bucket":"pass"},{"name":"unrelated","state":"IN_PROGRESS","bucket":"pending"}]'
rc=0
out=$(CHECK=kit POLL_SECONDS=0 MAX_POLLS=5 "$WAIT" 8 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [allow-list]: expected exit 0 once 'kit' is final, got $rc"; echo "$out"; exit 1; }
has_poll "$out" 3 && { echo "FAIL [allow-list]: CHECK=kit should have ignored 'unrelated' and stopped at poll 2"; echo "$out"; exit 1; }
echo "  ok: allow-list — CHECK=kit waits only on the named check, ignoring 'unrelated' still pending"

# Same fixture, no CHECK filter: 'unrelated' staying pending must correctly block completion.
# Proves case 5 above is the filter doing real work, not 'unrelated' finishing on its own.
reset_case allow-list-control \
  '[{"name":"kit","state":"IN_PROGRESS","bucket":"pending"},{"name":"unrelated","state":"IN_PROGRESS","bucket":"pending"}]' \
  '[{"name":"kit","state":"SUCCESS","bucket":"pass"},{"name":"unrelated","state":"IN_PROGRESS","bucket":"pending"}]'
rc=0
out=$(POLL_SECONDS=0 MAX_POLLS=3 "$WAIT" 8 2>&1) || rc=$?
[ "$rc" -eq 1 ] || {
  echo "FAIL [allow-list-control]: expected exit 1 (timeout) — 'unrelated' never finishes without a CHECK filter, got $rc"
  echo "$out"; exit 1
}
echo "  ok: allow-list-control — without CHECK, a still-pending 'unrelated' correctly blocks completion"

# ---------------------------------------------------------------- 6. a TRANSIENT gh failure (rate
# limit, network blip — anything but "no checks reported") must NOT count toward MAX_ZERO_POLLS.
# Three consecutive failures, one more than the default MAX_ZERO_POLLS=2 — if a transient failure
# were miscounted as a zero-checks poll, this would wrongly exit 2 by poll 2.

reset_case transient-error \
  'ERR:API rate limit exceeded' \
  'ERR:context deadline exceeded' \
  'ERR:API rate limit exceeded' \
  '[{"name":"kit","state":"SUCCESS","bucket":"pass"}]'
rc=0
out=$(POLL_SECONDS=0 MAX_POLLS=6 "$WAIT" 3 2>&1) || rc=$?
[ "$rc" -eq 0 ] || {
  echo "FAIL [transient-error]: expected exit 0 once gh recovers, got $rc (a transient failure must not trip MAX_ZERO_POLLS)"
  echo "$out"; exit 1
}
has_poll "$out" 4 || { echo "FAIL [transient-error]: missing poll 4 (the recovery)"; echo "$out"; exit 1; }
echo "  ok: transient-error — three non-'no checks reported' gh failures in a row do not trip the zero-checks bound"

# ---------------------------------------------------------------- 7. a GENUINE zero-checks branch
# — gh failing with its real "no checks reported" wording (measured on PR #291 of this repo) —
# still counts toward MAX_ZERO_POLLS and fails fast, same as case 4's `[]`-shaped fixture.

reset_case zero-via-real-error \
  "ERR:no checks reported on the 'some-branch' branch" \
  "ERR:no checks reported on the 'some-branch' branch"
rc=0
out=$(POLL_SECONDS=0 MAX_POLLS=6 "$WAIT" 4 2>&1) || rc=$?
[ "$rc" -eq 2 ] || {
  echo "FAIL [zero-via-real-error]: expected exit 2, got $rc"; echo "$out"; exit 1
}
has_poll "$out" 3 && {
  echo "FAIL [zero-via-real-error]: should have failed fast, well before MAX_POLLS=6"; echo "$out"; exit 1
}
echo "  ok: zero-via-real-error — gh's real 'no checks reported' failure still trips the zero-checks bound"

# ---------------------------------------------------------------- 8. a `needs:`-gated required
# check materializing mid-run (#413): poll 1 reports two checks, both already `pass`. A buggy
# script reads that as done and exits 0 right there — the exact false-green this case pins against.
# Poll 2 shows a third check, `Build & Test`, appearing as `pending` (the aggregate job started once
# its dependencies finished). Poll 3 shows all three `pass`. The script must not return 0 before
# poll 3, because the check set was still growing when poll 1's set looked all-final.

reset_case growing-set \
  '[{"name":"kit","state":"SUCCESS","bucket":"pass"},{"name":"title-gate","state":"SUCCESS","bucket":"pass"}]' \
  '[{"name":"kit","state":"SUCCESS","bucket":"pass"},{"name":"title-gate","state":"SUCCESS","bucket":"pass"},{"name":"Build & Test","state":"IN_PROGRESS","bucket":"pending"}]' \
  '[{"name":"kit","state":"SUCCESS","bucket":"pass"},{"name":"title-gate","state":"SUCCESS","bucket":"pass"},{"name":"Build & Test","state":"SUCCESS","bucket":"pass"}]'
rc=0
out=$(POLL_SECONDS=0 MAX_POLLS=6 "$WAIT" 1149 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [growing-set]: expected exit 0 once the late check is also final, got $rc"; echo "$out"; exit 1; }
has_poll "$out" 2 || { echo "FAIL [growing-set]: missing poll 2 (the late-appearing check)"; echo "$out"; exit 1; }
has_poll "$out" 3 || { echo "FAIL [growing-set]: missing poll 3 — script returned 0 before the check set was complete"; echo "$out"; exit 1; }
has_poll "$out" 4 && { echo "FAIL [growing-set]: polled a 4th time — should have stopped once the set was both final and stable at poll 3"; echo "$out"; exit 1; }
echo "  ok: growing-set — a set that looks all-final on poll 1 but grows a pending check by poll 2 is not read as done until poll 3"

# ---------------------------------------------------------------- 9. companion to case 8: a set
# that is already final AND unchanged across two consecutive polls exits 0, having polled exactly
# one extra time (the stability confirmation costs one poll on every run, not just a growing one).

reset_case stable-across-two-polls \
  '[{"name":"kit","state":"SUCCESS","bucket":"pass"}]'
rc=0
out=$(POLL_SECONDS=0 MAX_POLLS=6 "$WAIT" 21 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [stable-across-two-polls]: expected exit 0, got $rc"; echo "$out"; exit 1; }
has_poll "$out" 2 || { echo "FAIL [stable-across-two-polls]: expected one confirmation poll (poll 2) before exiting"; echo "$out"; exit 1; }
has_poll "$out" 3 && { echo "FAIL [stable-across-two-polls]: polled a 3rd time — the set was already final and unchanged by poll 2"; echo "$out"; exit 1; }
echo "  ok: stable-across-two-polls — an all-final, unchanged set exits 0 after exactly one confirmation poll"

# ---------------------------------------------------------------- 10. the header's rationale (#314)
# The "why this exists" paragraph reasons from the worker substrate. Workers are Agent-tool
# background sub-agents now, not one-shot `claude -p` processes: the structural rule (the SUPERVISOR
# waits, never the phase-2 worker) and its name — a dispatch-timing bug — survive unchanged; only
# the mechanism of the loss does (a sub-agent that ends its turn to wait has ended its run — its
# report is a deferral — rather than a process dying). Pin all three so the header cannot drift
# back to the old substrate or lose the rule's name.
if grep -q 'claude -p' "$WAIT"; then
  echo "FAIL [header]: wait-ci.sh still reasons from a 'claude -p' worker: $(grep -n 'claude -p' "$WAIT" | head -1)"; exit 1
fi
grep -q 'dispatch-timing bug' "$WAIT" || {
  echo "FAIL [header]: wait-ci.sh no longer names the rule — 'dispatch-timing bug'"; exit 1
}
grep -qi 'sub-agent' "$WAIT" || {
  echo "FAIL [header]: wait-ci.sh does not reason from a sub-agent worker (its run ends with its turn)"; exit 1
}
echo "  ok: header — reasons from sub-agents (no 'claude -p'), still names the dispatch-timing bug"

# ---------------------------------------------------------------- 11. the header must document
# WHY final alone isn't enough (a `needs:`-gated aggregate check doesn't exist until its
# dependencies finish) and the happy-path cost of fixing it (one extra poll) — so nobody reads
# "final" as sufficient again, and nobody "optimises away" the confirmation poll as waste (#413).

grep -qi 'needs:' "$WAIT" || {
  echo "FAIL [header-stability]: wait-ci.sh's header does not name the \`needs:\`-gated-aggregate cause"; exit 1
}
grep -qi 'stable\|stability' "$WAIT" || {
  echo "FAIL [header-stability]: wait-ci.sh's header does not name the stability requirement"; exit 1
}
grep -qi 'one extra poll\|extra poll' "$WAIT" || {
  echo "FAIL [header-stability]: wait-ci.sh's header does not name the one-extra-poll cost"; exit 1
}
echo "  ok: header-stability — header names the needs:-gated-aggregate cause and the one-extra-poll cost"

# ---------------------------------------------------------------- 12. a same-COUNT swap: one check
# disappears while a different one appears in the same poll, net count unchanged. Comparing raw
# counts alone would read this as "stable" even though the set never actually stopped changing —
# found by code review on PR #451 (#413). Comparing the check NAMES (not just how many) closes it.

reset_case same-count-swap \
  '[{"name":"kit","state":"SUCCESS","bucket":"pass"},{"name":"old-check","state":"SUCCESS","bucket":"pass"}]' \
  '[{"name":"kit","state":"SUCCESS","bucket":"pass"},{"name":"Build & Test","state":"SUCCESS","bucket":"pass"}]'
rc=0
out=$(POLL_SECONDS=0 MAX_POLLS=6 "$WAIT" 55 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [same-count-swap]: expected exit 0 once the swapped set is itself stable, got $rc"; echo "$out"; exit 1; }
has_poll "$out" 3 || { echo "FAIL [same-count-swap]: exited before poll 3 — a same-count swap ('old-check' -> 'Build & Test') was wrongly read as stable at poll 2"; echo "$out"; exit 1; }
has_poll "$out" 4 && { echo "FAIL [same-count-swap]: polled a 4th time — should have stopped once the swapped set repeated unchanged at poll 3"; echo "$out"; exit 1; }
echo "  ok: same-count-swap — a same-size swap of check names is not read as stable; the identity, not just the count, must repeat"

# ---------------------------------------------------------------- 13. the poll goes through the
# tracker (#752): the old direct `gh pr checks <pr>` summary call (no --json) is gone, and every
# `pr checks` the stub saw is github.sh's `--json name,state,bucket` argv.

reset_case through-tracker '[{"name":"kit","state":"SUCCESS","bucket":"pass"}]'
rc=0
out=$(POLL_SECONDS=0 MAX_POLLS=4 "$WAIT" 13 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [through-tracker]: expected exit 0, got $rc"; echo "$out"; exit 1; }
checks_calls=$(grep 'pr checks' "$GH_CALL_LOG" || true)
if [ -n "$checks_calls" ] && grep -qv -- '--json name,state,bucket' <<<"$checks_calls"; then
  echo "FAIL [through-tracker]: a \`gh pr checks\` call did not come from tracker.sh pr-checks:"
  cat "$GH_CALL_LOG"; exit 1
fi
grep -q "kit"$'\t'"SUCCESS" <<<"$out" || {
  echo "FAIL [through-tracker]: the final table does not list the check and its state"; echo "$out"; exit 1; }
echo "  ok: through-tracker — every checks read is tracker.sh pr-checks' argv, the summary included"

# A fake kit: a COPY of wait-ci.sh (a copy, not a link — the script resolves KIT_ROOT through
# symlinks, so a link would reach the real tracker.sh) beside a stub tracker.sh that is the stub
# above. Cases 14-15 pin what the script does with the verb's exit code and stdout alone.
FAKE="$WORK/fake-kit"
mkdir -p "$FAKE/skills/auto-dev/scripts" "$FAKE/scripts"
cp "$WAIT" "$FAKE/skills/auto-dev/scripts/wait-ci.sh"
cp "$WORK/bin/gh" "$FAKE/scripts/tracker.sh"
chmod +x "$FAKE/skills/auto-dev/scripts/wait-ci.sh" "$FAKE/scripts/tracker.sh"
FWAIT="$FAKE/skills/auto-dev/scripts/wait-ci.sh"

# ---------------------------------------------------------------- 14. pr-checks exiting 1 is
# transient, WHATEVER its stderr says — even gh's old "no checks reported" wording. Telling a genuine
# zero apart is github.sh's concern now (it prints `[]`), so the script must never count a failed
# verb toward MAX_ZERO_POLLS: three failures in a row, then a recovery, exits 0.

reset_case verb-fails \
  "ERR:no checks reported on the 'some-branch' branch" \
  "ERR:no checks reported on the 'some-branch' branch" \
  'ERR:anything at all' \
  '[{"name":"kit","state":"SUCCESS","bucket":"pass"}]'
rc=0
out=$(POLL_SECONDS=0 MAX_POLLS=6 "$FWAIT" 14 2>&1) || rc=$?
[ "$rc" -eq 0 ] || {
  echo "FAIL [verb-fails]: expected exit 0 once pr-checks recovers, got $rc (a failed verb is transient)"; echo "$out"; exit 1; }
grep -q 'gh error, retrying' <<<"$out" || {
  echo "FAIL [verb-fails]: a failed pr-checks was not logged as a transient poll"; echo "$out"; exit 1; }
grep -q '^ARGS: pr-checks 14$' "$GH_CALL_LOG" || {
  echo "FAIL [verb-fails]: wait-ci.sh did not call tracker.sh pr-checks 14"; cat "$GH_CALL_LOG"; exit 1; }
echo "  ok: verb-fails — pr-checks exiting 1 is a transient poll whatever its stderr, never a zero-checks one"

# ---------------------------------------------------------------- 15. pr-checks printing `[]` is
# a zero-checks poll: it counts toward MAX_ZERO_POLLS and fails fast (exit 2).

reset_case verb-empty '[]'
rc=0
out=$(POLL_SECONDS=0 MAX_POLLS=6 "$FWAIT" 15 2>&1) || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [verb-empty]: expected exit 2 on pr-checks answering [], got $rc"; echo "$out"; exit 1; }
has_poll "$out" 3 && { echo "FAIL [verb-empty]: should have failed fast, well before MAX_POLLS=6"; echo "$out"; exit 1; }
grep -q '^ARGS: pr-checks 15$' "$GH_CALL_LOG" || {
  echo "FAIL [verb-empty]: wait-ci.sh did not call tracker.sh pr-checks 15"; cat "$GH_CALL_LOG"; exit 1; }
echo "  ok: verb-empty — pr-checks answering [] is a zero-checks poll and trips the bound"

echo "wait-ci golden test OK"
