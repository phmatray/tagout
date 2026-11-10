#!/usr/bin/env bash
# Golden test for the merge gate's latest-run-per-job reduction (#91).
#
# The gate `merge-pr` applies is a jq program, and until this suite existed nothing ever ran it.
# It was wrong, in both directions, for the same reason: it read the check-runs on a head SHA as a
# FLAT SET, when GitHub gives a HISTORY PER JOB. Several runs of one job coexist on one SHA and
# only the newest is a verdict.
#
#   * Measured on PR #85: head sha 8c58eb2 carried three check-runs all named `kit` — a `cancelled`
#     superseded by the next push, then two `success`. The flat gate classified the PR as failed,
#     entered the corrections loop, found nothing to fix, and refused a PR that was green twice.
#     This repo's own ci.yml sets `cancel-in-progress` (#27/#29), so it produces that shape as a
#     matter of routine.
#   * The symmetric hazard, never yet exercised: a stale `success` from an earlier run sitting
#     beside a newer `failure` for the same job, where "some run succeeded" reads as fine. That is
#     the direction that merges something broken.
#
# One reduction fixes both, so one suite pins both — plus the carve-out that makes the fix safe: a
# job whose LATEST run is `cancelled` still blocks. A superseded cancellation and a real one (a
# human pressing Cancel, a timeout) are different events, and only the second is a verdict.
#
# The program under test is NOT copied here. It is EXTRACTED from the marked block inside
# skills/merge-pr/references/merge-mechanics.md §3 and run verbatim, so the thing this suite proves
# green is the thing an agent pastes. A second copy would drift, and a drifted copy of a gate is
# exactly the failure mode above wearing a passing test.
set -euo pipefail
cd "$(dirname "$0")/../.."

RECIPE="./skills/merge-pr/references/merge-mechanics.md"
[ -r "$RECIPE" ] || { echo "FAIL: $RECIPE missing — nothing to extract the gate from"; exit 1; }

# Scratch dir and EXIT trap come from the shared preamble (#72). KIT_ROOT is derived from this
# file's location rather than $PWD — $PWD is only right because a `cd` sits above it.
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
kit_guard kit_guard_samples_unchanged
WORK=$(kit_scratch)
FIXTURES="$KIT_ROOT/tests/merge-gate/fixtures"

command -v jq > /dev/null 2>&1 || {
  echo "FAIL: jq is missing — it is a \`required\` prerequisite in requirements.json, and the gate"
  echo "      this suite exercises is written in it."
  exit 1; }

FAILED=0
note_fail() { echo "FAIL: $1"; FAILED=1; }

# ------------------------------------------------------------------ 1. extract the shipped program
#
# The extraction is NOT re-implemented here. `scripts/decide.sh --program ci.verdict` is the one
# home for it in this repo (#208), so an extraction bug reddens here too instead of being papered
# over by a second copy of the awk that happens to agree with the first. The marker-uniqueness
# refusal ("two homes for the gate") now lives inside that dispatcher, and the single-quote check
# moved to scripts/decision-check.py R3 — one rule, one implementation.
PROG="$WORK/verdict.jq"
"$KIT_ROOT/scripts/decide.sh" --program ci.verdict > "$PROG" || {
  echo "FAIL: could not extract the ci.verdict program"; exit 1; }
[ -s "$PROG" ] || { echo "FAIL: extracted an empty program"; exit 1; }

# jq compiles the whole program before it reads any input, so empty input is a pure parse check.
if ! jq -f "$PROG" < /dev/null > /dev/null 2>"$WORK/parse.err"; then
  echo "FAIL: the extracted verdict program does not compile:"
  sed 's/^/      /' "$WORK/parse.err"
  exit 1
fi

# Pagination is load-bearing and easy to lose in a rewrite: without --paginate --slurp the gate
# judges the first page and calls a PR green on the strength of the checks it happened to see.
#
# Asked of the `gh api` INVOCATION, not of the file. A whole-file grep passes while the flags
# survive only in a comment or in prose — including the comment two lines above the call, which
# spells `--slurp` — so it would go green over exactly the regression it names.
CALL=$(grep -F -- 'gh api' "$RECIPE" | grep -F -- 'check-runs' || true)
if [ -z "$CALL" ]; then
  note_fail "$RECIPE has no \`gh api\` line fetching check-runs — the gate has lost its input."
elif ! grep -q -F -- '--paginate --slurp' <<<"$CALL"; then
  note_fail "the check-runs call in $RECIPE no longer carries \`--paginate --slurp\`, so the gate
      would judge one page of a multi-page SHA:
      $CALL"
fi

# The refusal that keeps a failed query from reading as "no CI". `gh api` writes nothing on
# failure and the pipeline still exits 0 without pipefail, so an unguarded empty verdict is a pass.
grep -q -F -- 'no verdict; do not merge' "$RECIPE" || \
  note_fail "$RECIPE no longer refuses an empty verdict — a failed check-runs query would be
      indistinguishable from a SHA that carries no CI, and the second one merges."

# ------------------------------------------------------------------------------- 2. the verdicts
#
# verdict <fixture> <latest-count> <failed-jobs> <pending-jobs> <what it pins>
# Job lists are space-joined and sorted; `-` means none.
verdict() {
  local fixture="$1" want_latest="$2" want_failed="$3" want_pending="$4" what="$5"
  local path="$FIXTURES/$fixture" out got_latest got_failed got_pending
  if [ ! -r "$path" ]; then
    note_fail "$fixture — fixture missing ($what)"
    return 0
  fi
  if ! out=$(jq -f "$PROG" < "$path" 2>"$WORK/run.err"); then
    note_fail "$fixture — the verdict program errored ($what):
$(sed 's/^/      /' "$WORK/run.err")"
    return 0
  fi
  got_latest=$(printf '%s' "$out" | jq '.latest | length')
  got_failed=$(printf '%s' "$out" | jq -r '[.failed[].name] | sort | join(" ")')
  got_pending=$(printf '%s' "$out" | jq -r '[.pending[].name] | sort | join(" ")')
  [ -n "$got_failed" ] || got_failed='-'
  [ -n "$got_pending" ] || got_pending='-'
  if [ "$got_latest" != "$want_latest" ] || [ "$got_failed" != "$want_failed" ] \
     || [ "$got_pending" != "$want_pending" ]; then
    note_fail "$fixture — $what
      want: latest=$want_latest failed=$want_failed pending=$want_pending
      got:  latest=$got_latest failed=$got_failed pending=$got_pending"
    return 0
  fi
  echo "ok: $fixture — $what"
}

# The measured #85 shape: three `kit` runs on one SHA, the first superseded by the next push. The
# flat gate refused this PR; the reduction lets it through, because the latest run of every job is
# a success.
verdict superseded-cancel.json 2 - - \
  'a superseded cancelled run does not block a job whose latest run succeeded'

# The carve-out. Weakening the gate into "ignore cancelled" would pass this, which is why it is
# here: a real cancellation — a human pressing Cancel, a timeout — is a non-verdict and must block.
verdict latest-cancelled.json 1 kit - \
  'a job whose LATEST run is cancelled still blocks'

# The direction that would actually merge something broken.
verdict stale-success.json 1 kit - \
  'a stale success does not mask a newer failure for the same job'

# Unchanged behaviour, restated as a fixture so a rewrite cannot quietly alter it.
verdict skipped-only.json 1 - - \
  'a skipped run stays a non-event — neither failed nor pending'

# No CI at all: the reduction must not invent a verdict. The caller falls back to mergeStateStatus.
verdict no-checks.json 0 - - \
  'zero check-runs reduce to zero jobs, so nothing is failed or pending'

# Order in the API response is NOT the tiebreak — both fixtures list the loser last, so a reduction
# that took the array tail would answer wrongly in one direction and right-by-accident in the other.
# The greatest id decides, deterministically, because an id is assigned when a run is created.
verdict tie-greatest-id-blocks.json 1 kit - \
  'the greatest id wins — here a failure, despite a success later in the array'
verdict tie-greatest-id-passes.json 1 - - \
  'the greatest id wins — here a success, despite a failure later in the array'

# Why the key is .id and not .started_at. A job held behind `needs:` in an older run can START
# after a job from a newer run, so started_at does not order the RUNS. The newer run here (id
# 1202) began an hour earlier than the stale one it supersedes.
verdict newer-run-started-earlier.json 1 - - \
  'the newest run wins even when an older run started later'

# The nullable half of the same argument, and the one that fails open: a queued run has no
# started_at at all, so ordering on it sinks the run to the bottom and the gate reports the stale
# success it was created to supersede.
verdict queued-without-started-at.json 1 - kit \
  'a queued run with no started_at still supersedes the older success, and blocks as pending'

# The reduction must not hand a job identity away. Two products can publish a check of the same
# name; grouping on the name alone drops one of them, and it is a real failure that disappears.
verdict same-name-different-app.json 2 build - \
  'two apps posting the same check name are separate jobs, so neither retires the other'

# skipped is a non-event, which has to hold in BOTH orderings. Arriving last must not let it
# become a job entire verdict and erase the only real run there was.
verdict failure-then-skipped.json 1 kit - \
  'a later skipped run does not erase an earlier real failure for the same job'

# `pending` is derived from the same reduced set: an older success must not retire a running job.
verdict latest-in-progress.json 1 - kit \
  'a job whose latest run is still in progress is pending, not green'

# Several jobs at once, across two pages of --slurp output, including a job that no longer runs:
# `legacy-suite` has only an old failure, and absence of a current run is not a pass.
verdict multi-job-paginated.json 3 legacy-suite - \
  'jobs are reduced independently, across pages, and a vanished job keeps blocking'

# `waiting` / `requested` / `pending` (#191): a run behind an environment protection rule, or one an
# app has posted before starting, has no conclusion and is not `skipped` either — it has not run
# YET, which is not evidence of anything and must not read as green. Each fixture pairs the gated
# job with an unrelated green `kit` run so the case is a real PR with a gate, not a degenerate one.
verdict waiting-deployment-gate.json 2 - deploy \
  'a run waiting behind a deployment protection rule is pending, not green'
verdict requested-run.json 2 - preview-app \
  'a run an app has only requested is pending, not green'
verdict pending-status.json 2 - legacy-status-check \
  'a run whose status is literally "pending" is pending, not green'

# The mixed case, pinned separately: an unrelated job's success must not retire a waiting job, and
# only the waiting job's name should surface in `pending`.
verdict waiting-blocks-other-success.json 2 - deploy \
  'a waiting run blocks the gate even when a different job has already succeeded'

# A completed run whose conclusion is `action_required` (#495) is neither a failure nor unstarted —
# it is a third, non-terminal state: awaiting a maintainer's approval. `verdict()` above pins the
# reduced *sets*; this pins the *word* the caller branches on, since a run stuck in `needs_approval`
# must not silently fall through to `failed` (it would today, before this fix — approving a
# release-please run is not the same remedy as fixing a build) nor to `clear` (it has not run yet).
verdict_word() {
  local fixture="$1" want="$2" what="$3"
  local path="$FIXTURES/$fixture" out got
  if [ ! -r "$path" ]; then
    note_fail "$fixture — fixture missing ($what)"
    return 0
  fi
  if ! out=$(jq -f "$PROG" < "$path" 2>"$WORK/run.err"); then
    note_fail "$fixture — the verdict program errored ($what):
$(sed 's/^/      /' "$WORK/run.err")"
    return 0
  fi
  got=$(printf '%s' "$out" | jq -r .verdict)
  if [ "$got" != "$want" ]; then
    note_fail "$fixture — $what
      want: verdict=$want
      got:  verdict=$got"
    return 0
  fi
  echo "ok: $fixture — $what"
}

# Measured on PR #475 (release-please[bot]): the `release-title` run sat completed/action_required
# beside an unrelated green `kit` run. The flat-failed gate entered the corrections loop hunting for
# a fix that does not exist — nothing a push can change clears it, only an approval.
verdict_word needs-approval.json needs-approval \
  'a run awaiting approval is needs-approval, not failed'
# Same shape, the action_required run gone (approved and re-run as the green it becomes) — the
# remaining set is a plain success, so the verdict must fall all the way through to clear, not get
# stuck non-terminal.
verdict_word needs-approval-cleared.json clear \
  'once nothing needs approval any more, the verdict is clear'

# ---------------------------------------------------------------------------------------- verdict
if [ "$FAILED" -ne 0 ]; then
  echo
  echo "merge-gate: FAILED"
  exit 1
fi
echo
echo "merge-gate: OK — the shipped verdict program judges the latest run of each job."
