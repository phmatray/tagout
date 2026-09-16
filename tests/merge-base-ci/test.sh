#!/usr/bin/env bash
# Golden test for skills/merge-pr/scripts/base-run-verdict.sh (#355).
#
# WHAT BROKE. `merge-pr` gates hard on CI *before* the merge and then tears down at PR-green: it
# never reads the workflow run its own merge triggers on the base branch. Measured on this repo,
# 2026-08-30: #338's push run on `main` was CANCELLED (superseded 2m39s later by the next merge)
# and #342's run 33346395704 recorded the failure — nobody read either, `main` stayed red for ~40
# minutes, and every in-flight PR in the fleet inherited the red bar.
#
# WHAT THIS SUITE PINS. The one property that makes the answer attributable: the verdict is
# resolved FOR A SHA, never for "the newest run on the base branch". Under a merge train — which
# is the normal `auto-dev` shape, several merges within minutes — a sibling merge landing two
# seconds later would otherwise donate its run to this merge's verdict, and the report would name
# the wrong change. So the stub below deliberately arms a RECENCY TRAP: `gh run list` answers with
# a sibling sha's FAILING run, and any helper that asks that question instead of asking the
# check-runs endpoint about its own sha goes red here.
#
# The CI rules themselves are NOT re-derived here. The helper delegates them to the registered
# decision `ci.verdict` (#91, #170, #208) — the same reduction `merge-pr` Step 3 already runs, and
# the reason a superseded `cancelled` cannot mask a newer `success`. What this suite proves is the
# mapping around it: which ci.verdict word becomes green, which becomes red, and — the case the
# incident turns on — which becomes the honest NON-VERDICT `unverified`.
set -euo pipefail
# A GH_HOST in the developer's or CI's shell would decide the host cases (#514) on its own.
unset GH_HOST
cd "$(dirname "$0")/../.."

HELPER="./skills/merge-pr/scripts/base-run-verdict.sh"
[ -x "$HELPER" ] || { echo "FAIL: $HELPER missing or not executable"; exit 1; }

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Scratch dir and EXIT trap from the shared preamble (#72).
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
kit_guard kit_guard_samples_unchanged
WORK=$(kit_scratch)

command -v jq > /dev/null 2>&1 || {
  echo "FAIL: jq is missing — it is a \`required\` prerequisite in requirements.json, and the"
  echo "      decision this helper delegates to is written in it."
  exit 1; }

# The decision engine appends one event per run. Point it INTO the scratch dir: left to its own
# defaults it would write into the repository this suite is running from (#208's fail-open log).
export KIT_DECISION_LOG="$WORK/decision-events.jsonl"

# ------------------------------------------------------------------ the `gh` stub
#
# Only two questions are answerable, and they answer DIFFERENTLY on purpose:
#
#   * `api …/commits/<sha>/check-runs` — the real question. Serves the Nth canned response armed
#     for THAT sha (clamped to the last one, so a poll past the script repeats it — which is what
#     "the run never finishes" needs). A response starting with `ERR:` simulates gh failing: the
#     rest goes to stderr and the stub exits 1.
#   * `run list …` — the recency trap. Always the sibling merge's failing run, whatever was asked.
#     A helper that resolves by recency reads a red that is not its own.
#
# Anything else is an unhandled invocation and fails loudly rather than answering a question this
# suite never scripted.
#
# Each log line carries the GH_HOST the call ran under (#514). `gh auth token --hostname H`, the
# host helper's credential probe, succeeds only for a host listed in $GH_STUB_HOSTS.
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
case "$*" in
  *check-runs*)
    sha=""
    for a in "$@"; do
      case "$a" in
        */commits/*/check-runs*)
          sha="${a#*/commits/}"
          sha="${sha%%/check-runs*}"
          ;;
      esac
    done
    [ -n "$sha" ] || { echo "STUB: no sha in the check-runs path: $*" >&2; exit 1; }
    dir="$GH_RESPONSES/$sha"
    # A sha nobody armed carries no check-runs. That is a real GitHub answer (a base branch with
    # no CI, or a run not posted yet), not a stub gap, so it is served rather than refused.
    [ -d "$dir" ] || { printf '%s' '[{"total_count":0,"check_runs":[]}]'; exit 0; }
    n=$(( $(cat "$dir/count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$dir/count"
    max=$(cat "$dir/max" 2>/dev/null || echo 1)
    use=$n
    [ "$use" -gt "$max" ] && use=$max
    content=$(cat "$dir/$use.json")
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
  *"run list"*)
    # base-run-followup.sh's one lookup (#561) can also be asked to fail — same ERR: convention
    # the check-runs branch above uses, so a case can arm "the lookup itself fails" without a
    # second stub shape.
    case "$RUN_LIST_TRAP" in
      ERR:*) printf '%s\n' "${RUN_LIST_TRAP#ERR:}" >&2; exit 1 ;;
      *)     printf '%s' "$RUN_LIST_TRAP" ;;
    esac
    ;;
  *actions/runs*)
    # The #479 fallback. Keyed by sha or it is the recency trap again: a query without head_sha=
    # gets the sibling's failing run, whatever it asked for.
    case "$*" in
      *head_sha=*)
        all="$*"; sha="${all#*head_sha=}"; sha="${sha%%&*}"   # ${*#…} would strip each word, not the join
        # An OUTAGE (rate limit, network) takes both endpoints down, not just check-runs; a case
        # models one by touching this marker after arming.
        [ -e "$GH_RESPONSES/$sha/outage" ] && { echo "API rate limit exceeded" >&2; exit 1; }
        f="$GH_RESPONSES/$sha/workflow-runs.json"
        if [ -f "$f" ]; then cat "$f"; else printf '%s' '{"total_count":0,"workflow_runs":[]}'; fi
        ;;
      *)
        printf '%s' '{"total_count":1,"workflow_runs":[{"id":33346395704,"name":"kit","head_sha":"'"$SIBLING_SHA"'","status":"completed","conclusion":"failure","html_url":"https://github.invalid/run/33346395704","run_started_at":"2026-08-30T09:00:00Z"}]}'
        ;;
    esac
    ;;
  *)
    echo "STUB: unhandled gh invocation: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

# The sibling merge in the train: its run is red, and it is what every recency-shaped query
# returns. Nothing in this suite may ever report red because of it.
export SIBLING_SHA=b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2
export RUN_LIST_TRAP='[{"databaseId":33346395704,"headSha":"'"$SIBLING_SHA"'","conclusion":"failure","status":"completed","name":"kit","url":"https://github.invalid/run/33346395704"}]'

# ------------------------------------------------------------------ arming helpers

# run <name> <id> <state> — one check-run object. `state` is written into `conclusion` for a
# finished run and into `status` for one that is not, which is the shape the check-runs API gives
# and the shape ci.verdict's `(.conclusion // .status)` reads.
run_obj() {
  local name="$1" id="$2" state="$3"
  case "$state" in
    queued|in_progress|waiting|requested|pending)
      printf '{"name":"%s","id":%s,"app":{"id":15368},"started_at":"2026-08-30T09:00:00Z","html_url":"https://github.invalid/checks/%s","status":"%s","conclusion":null}' \
        "$name" "$id" "$id" "$state" ;;
    *)
      printf '{"name":"%s","id":%s,"app":{"id":15368},"started_at":"2026-08-30T09:00:00Z","html_url":"https://github.invalid/checks/%s","status":"completed","conclusion":"%s"}' \
        "$name" "$id" "$id" "$state" ;;
  esac
}

# page <run-json>… — one --paginate --slurp page wrapping the given runs.
page() {
  local first=1 out='[{"total_count":0,"check_runs":['
  local r
  for r in "$@"; do
    [ "$first" -eq 1 ] || out="$out,"
    out="$out$r"
    first=0
  done
  printf '%s' "$out]}]"
}

# arm <sha> <page-1> [<page-2> …] — the scripted answers for one sha, poll by poll.
arm() {
  local sha="$1"; shift
  local dir="$GH_RESPONSES/$sha"
  rm -rf "$dir"; mkdir -p "$dir"
  local idx=1 resp
  for resp in "$@"; do
    printf '%s' "$resp" > "$dir/$idx.json"
    idx=$((idx + 1))
  done
  echo "$((idx - 1))" > "$dir/max"
}

# reset_case <name> — a fresh call log and a fresh response tree per case.
reset_case() {
  GH_CALL_LOG="$WORK/gh-calls.$1.log"
  GH_RESPONSES="$WORK/gh-resp.$1"
  export GH_CALL_LOG GH_RESPONSES
  rm -rf "$GH_RESPONSES"; mkdir -p "$GH_RESPONSES"
  : > "$GH_CALL_LOG"
}

# The helper always exits 0 and always prints one JSON object: a non-verdict is an ANSWER, not a
# failure, so a non-zero exit would give an autonomous merge a new way to stop after the merge has
# already landed. Assert both here, once, rather than at every call site.
verdict_of() {
  local out rc=0
  out=$("$HELPER" "$@" 2>"$WORK/helper.err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: the helper exited $rc — a post-merge reader must always answer, never refuse:" >&2
    sed 's/^/      /' "$WORK/helper.err" >&2
    exit 1
  fi
  printf '%s' "$out" | jq -e . > /dev/null 2>&1 || {
    echo "FAIL: the helper did not print one JSON object:" >&2
    printf '%s\n' "$out" | sed 's/^/      /' >&2
    exit 1; }
  printf '%s' "$out"
}

expect_verdict() {
  local label="$1" want="$2" got_json="$3" got
  got=$(printf '%s' "$got_json" | jq -r .verdict)
  [ "$got" = "$want" ] || {
    echo "FAIL [$label]: expected verdict '$want', got '$got'"
    printf '%s\n' "$got_json" | jq . | sed 's/^/      /'
    exit 1; }
}

# ---------------------------------------------------------------- 0. usage: no sha refuses
#
# The one case that is NOT a verdict: called with no sha there is nothing to resolve, and printing
# `unverified` would let a caller that forgot the argument report a clean non-verdict forever.
rc=0
out=$("$HELPER" 2>&1) || rc=$?
[ "$rc" -eq 64 ] || { echo "FAIL [usage]: expected exit 64 with no sha, got $rc"; echo "$out"; exit 1; }
echo "  ok: usage — no sha refuses with exit 64 rather than printing a non-verdict"

# ---------------------------------------------------------------- 1. resolved BY SHA, not by recency
#
# The merge-train case, and the reason this helper exists. Our sha is green; the sibling merge that
# landed two seconds later is red and is what every recency query answers. Green is the only
# correct verdict, and the call log must show the question was asked about our sha.
reset_case by-sha
SHA=a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
arm "$SHA" "$(page "$(run_obj kit 501 success)" "$(run_obj title-gate 502 success)")"
arm "$SIBLING_SHA" "$(page "$(run_obj kit 601 failure)")"
v=$(verdict_of "$SHA" --timeout 60 --poll-seconds 0)
expect_verdict by-sha green "$v"
grep -qF "commits/$SHA/check-runs" "$GH_CALL_LOG" || {
  echo "FAIL [by-sha]: the helper never asked the check-runs endpoint about $SHA:"
  sed 's/^/      /' "$GH_CALL_LOG"; exit 1; }
if grep -qF 'run list' "$GH_CALL_LOG"; then
  echo "FAIL [by-sha]: the helper asked a recency-shaped question (\`gh run list\`). A sibling"
  echo "      merge's run must not be able to donate its verdict to this sha:"
  sed 's/^/      /' "$GH_CALL_LOG"; exit 1
fi
echo "  ok: by-sha — a green sha reports green even though the newest run on the branch is red"

# ---------------------------------------------------------------- 2. a sibling sha's run is refused
#
# The mirror of case 1, in the direction that matters more: OUR merge is the one that broke the
# base. A green sibling landing after it must not launder that red into a pass.
reset_case sibling-refused
SHA=c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3
arm "$SHA" "$(page "$(run_obj kit 701 failure)")"
arm "$SIBLING_SHA" "$(page "$(run_obj kit 702 success)")"
export RUN_LIST_TRAP='[{"databaseId":33346400000,"headSha":"'"$SIBLING_SHA"'","conclusion":"success","status":"completed","name":"kit","url":"https://github.invalid/run/33346400000"}]'
v=$(verdict_of "$SHA" --timeout 60 --poll-seconds 0)
expect_verdict sibling-refused red "$v"
printf '%s' "$v" | jq -e '.runs | map(select(.state == "failure")) | length == 1' > /dev/null || {
  echo "FAIL [sibling-refused]: the failing job is not named in .runs — a filed bug needs it:"
  printf '%s\n' "$v" | jq . | sed 's/^/      /'; exit 1; }
echo "  ok: sibling-refused — a red sha stays red even though a sibling merge's newer run is green"
# Restore the red trap for the cases below.
export RUN_LIST_TRAP='[{"databaseId":33346395704,"headSha":"'"$SIBLING_SHA"'","conclusion":"failure","status":"completed","name":"kit","url":"https://github.invalid/run/33346395704"}]'

# ---------------------------------------------------------------- 3. no run for the sha → unverified
#
# A base branch with no CI, or a run GitHub has not posted yet. `ci.verdict` calls this `no-ci`,
# which for a PRE-merge gate means "let mergeStateStatus decide" — but here the merge has already
# happened, and the honest report is that this merge's effect on the base was never verified.
# Reporting it as green is the regression this whole issue exists to prevent.
reset_case no-run
SHA=d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4
# Nothing armed for $SHA at all: the stub serves an empty check_runs page, exactly as GitHub does.
arm "$SIBLING_SHA" "$(page "$(run_obj kit 801 success)")"
v=$(verdict_of "$SHA" --timeout 0 --poll-seconds 0)
expect_verdict no-run unverified "$v"
printf '%s' "$v" | jq -e '.reason == "no-ci"' > /dev/null || {
  echo "FAIL [no-run]: expected reason 'no-ci', got '$(printf '%s' "$v" | jq -r .reason)'"; exit 1; }
echo "  ok: no-run — a sha with no check-runs is unverified, never green"


# ---------------------------------------------------------------- 4. a cancelled run is a NON-verdict
#
# `dce7d5b`, exactly. `cancel-in-progress` (#27/#29) cancels the previous `main` run the moment the
# next merge lands, so under a fleet this is the ROUTINE outcome of a merge train — and it is the
# shape that made the incident invisible. `ci.verdict` files a cancelled job under `.failed`,
# because pre-merge a cancelled check is a reason not to merge; post-merge the merge has already
# landed and the run recorded nothing about it. Reporting that as `red` would file a bug against a
# merge nobody has evidence about; reporting it as `green` is the silence #355 exists to end.
reset_case cancelled-only
SHA=e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5
arm "$SHA" "$(page "$(run_obj kit 901 cancelled)")"
v=$(verdict_of "$SHA" --timeout 0 --poll-seconds 0)
expect_verdict cancelled-only unverified "$v"
printf '%s' "$v" | jq -e '.reason == "cancelled"' > /dev/null || {
  echo "FAIL [cancelled-only]: expected reason 'cancelled', got '$(printf '%s' "$v" | jq -r .reason)'"; exit 1; }
echo "  ok: cancelled-only — a sha whose only run was cancelled is unverified, not red and not green"

# ------------------------------------------------- 4b. a run awaiting approval is its own NON-verdict
#
# `ci.verdict` files a completed run whose conclusion is `action_required` under its third,
# non-terminal word `needs-approval` (#495) — GitHub's state for a run a maintainer must approve.
# The post-merge mapping had no arm for it, so it fell through to the catch-all whose own comment
# calls itself unreachable, and the report read `unexpected-ci-verdict:needs-approval` — an internal
# error string in place of a fact the caller can act on (#586). It is `unverified` for the same
# reason `cancelled` is: the merge landed and the run recorded nothing about it. The reason must
# name the actual condition, because that is the one a human can clear by approving the run.
reset_case needs-approval
SHA=a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4
arm "$SHA" "$(page "$(run_obj kit 902 action_required)")"
v=$(verdict_of "$SHA" --timeout 0 --poll-seconds 0)
expect_verdict needs-approval unverified "$v"
printf '%s' "$v" | jq -e '.reason == "needs-approval"' > /dev/null || {
  echo "FAIL [needs-approval]: expected reason 'needs-approval', got '$(printf '%s' "$v" | jq -r .reason)'"; exit 1; }
echo "  ok: needs-approval — a run awaiting approval is named, not reported as an unexpected verdict"

# ---------------------------------------------------------------- 5. a SUPERSEDED cancellation is noise
#
# The other half of the same rule, and the one that keeps case 4 from becoming "ignore cancelled
# runs": a cancelled run with a NEWER run of the same job behind it was superseded, and the newer
# run is the verdict. That reduction is `ci.verdict`'s (#91), not this helper's — this case proves
# the helper still delegates to it rather than short-circuiting on the word `cancelled`.
reset_case superseded-cancel
SHA=f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6
arm "$SHA" "$(page "$(run_obj kit 910 cancelled)" "$(run_obj kit 911 success)")"
v=$(verdict_of "$SHA" --timeout 60 --poll-seconds 0)
expect_verdict superseded-cancel green "$v"
printf '%s' "$v" | jq -e '.runs | length == 1' > /dev/null || {
  echo "FAIL [superseded-cancel]: .runs is the raw history, not the reduced one-run-per-job set:"
  printf '%s\n' "$v" | jq . | sed 's/^/      /'; exit 1; }
echo "  ok: superseded-cancel — a cancelled run behind a newer success is green, via ci.verdict's reduction"

# ---------------------------------------------------------------- 6. cancelled must not swallow a real red
#
# One job cancelled beside another job that genuinely FAILED. `red` is the answer: there is real
# evidence of a breakage, and case 4's carve-out must not launder it into a non-verdict.
reset_case cancelled-plus-failure
SHA=0707070707070707070707070707070707070707
arm "$SHA" "$(page "$(run_obj kit 920 cancelled)" "$(run_obj title-gate 921 failure)")"
v=$(verdict_of "$SHA" --timeout 0 --poll-seconds 0)
expect_verdict cancelled-plus-failure red "$v"
echo "  ok: cancelled-plus-failure — a cancelled job beside a real failure still reports red"

# ---------------------------------------------------------------- 7. pending polls, then answers
#
# The run is still going when the merge returns — the normal case, since the push run starts the
# half-second after. Two pending polls, then the verdict.
reset_case pending-then-green
SHA=1818181818181818181818181818181818181818
arm "$SHA" \
  "$(page "$(run_obj kit 930 in_progress)")" \
  "$(page "$(run_obj kit 930 in_progress)")" \
  "$(page "$(run_obj kit 930 success)")"
v=$(verdict_of "$SHA" --timeout 60 --poll-seconds 0)
expect_verdict pending-then-green green "$v"
[ "$(cat "$GH_RESPONSES/$SHA/count")" -ge 3 ] || {
  echo "FAIL [pending-then-green]: the helper stopped polling before the run finished"; exit 1; }
echo "  ok: pending-then-green — a still-running base run is polled until it is final"

# ---------------------------------------------------------------- 8. the bound expires → unverified
#
# A run that never finishes inside the bound. `unverified`, NEVER `red`: a helper that reported a
# slow run as a breakage would file bugs against healthy merges, which is a worse failure than the
# silence it replaces.
reset_case pending-forever
SHA=2929292929292929292929292929292929292929
arm "$SHA" "$(page "$(run_obj kit 940 queued)")"
v=$(verdict_of "$SHA" --timeout 0 --poll-seconds 0)
expect_verdict pending-forever unverified "$v"
printf '%s' "$v" | jq -e '.reason == "timeout"' > /dev/null || {
  echo "FAIL [pending-forever]: expected reason 'timeout', got '$(printf '%s' "$v" | jq -r .reason)'"; exit 1; }
echo "  ok: pending-forever — an expired bound is a stated non-verdict, never a breakage"

# ---------------------------------------------------------------- 9. a transient gh failure is not an answer
#
# `gh` failing says nothing about the base branch, so it must not read as `no-ci` (case 3's green-
# adjacent silence) on the first attempt. Two failures, then the real answer.
reset_case transient-error
SHA=3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a
arm "$SHA" \
  'ERR:API rate limit exceeded' \
  'ERR:context deadline exceeded' \
  "$(page "$(run_obj kit 950 success)")"
v=$(verdict_of "$SHA" --timeout 60 --poll-seconds 0)
expect_verdict transient-error green "$v"
echo "  ok: transient-error — a failing gh call is retried, not reported as 'no CI on the base'"

# ---------------------------------------------------------------- 10. a query that never answers
#
# The same failure, past the bound. It is a non-verdict with its own reason, so a report can say
# WHY there is no answer — "the base was never verified because the query failed" and "…because
# the run never finished" send a reader to different places.
reset_case query-failed
SHA=4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b
arm "$SHA" 'ERR:API rate limit exceeded'
touch "$GH_RESPONSES/$SHA/outage"          # the outage reaches the #479 fallback too
v=$(verdict_of "$SHA" --timeout 0 --poll-seconds 0)
expect_verdict query-failed unverified "$v"
printf '%s' "$v" | jq -e '.reason == "query-failed"' > /dev/null || {
  echo "FAIL [query-failed]: expected reason 'query-failed', got '$(printf '%s' "$v" | jq -r .reason)'"; exit 1; }
echo "  ok: query-failed — a gh call that never answers is its own named non-verdict"

# ---------------------------------------------------------------- 11. `no-ci` is not answered on
# the first poll — it is indistinguishable from "GitHub has not posted the run yet"
#
# This helper runs SECONDS after `gh pr merge` returned, and the push run's check-runs are not
# posted instantly. Answering `no-ci` on the first reading would make `unverified` the outcome of
# almost every healthy merge, with the whole timeout budget unused — a step that always reports a
# non-verdict is the silence #355 removes, wearing a different word. So `no-ci` is retried until
# the settle window expires, and only then is it an answer (case 3 is that expiry, with the window
# clamped to a zero timeout).
reset_case no-ci-settles
SHA=5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c
arm "$SHA" \
  "$(page)" \
  "$(page)" \
  "$(page "$(run_obj kit 960 success)")"
v=$(verdict_of "$SHA" --timeout 60 --settle 60 --poll-seconds 0)
expect_verdict no-ci-settles green "$v"
[ "$(cat "$GH_RESPONSES/$SHA/count")" -ge 3 ] || {
  echo "FAIL [no-ci-settles]: the helper answered before the run was posted"; exit 1; }
echo "  ok: no-ci-settles — an empty check-run set is retried inside the settle window, not answered"

# ---------------------------------------------------------------- 12. a partly-posted job graph is
# not green yet
#
# The mirror hazard, and the one that would report a broken base as clean: a fast job's check-run
# exists and is green while a job behind a \`needs:\` chain has not posted at all. The reduction
# calls that set clear — correctly, on the evidence it has. SKILL.md §3 already makes this argument
# for the PRE-merge gate ("wait one poll interval and re-derive"); post-merge the window is widest,
# so `clear` counts only once the reduced JOB SET matches the previous poll's.
reset_case late-job
SHA=6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d
arm "$SHA" \
  "$(page "$(run_obj kit 970 success)")" \
  "$(page "$(run_obj kit 970 success)" "$(run_obj deploy 971 queued)")" \
  "$(page "$(run_obj kit 970 success)" "$(run_obj deploy 971 failure)")"
v=$(verdict_of "$SHA" --timeout 60 --poll-seconds 0)
expect_verdict late-job red "$v"
[ "$(cat "$GH_RESPONSES/$SHA/count")" -ge 3 ] || {
  echo "FAIL [late-job]: the helper called it on the first reading, before the graph had posted"; exit 1; }
echo "  ok: late-job — a green first reading is re-derived, so a job that posts a beat later still counts"

# ---------------------------------------------------------------- 13. --report-line: the literal
# grammar, never JSON, never a paraphrase (#455)
#
# The whole point of this mode: `merge-pr` Step 5b's `BASE:` field must be able to COPY this
# output verbatim rather than compose its own sentence around the JSON verdict/reason. A clean
# success set becomes exactly `green (clear)` on stdout — nothing else.
reset_case report-line-green
SHA=7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e
arm "$SHA" "$(page "$(run_obj kit 980 success)")"
out=$("$HELPER" "$SHA" --report-line --timeout 60 --poll-seconds 0)
[ "$out" = "green (clear)" ] || { echo "FAIL [report-line-green]: expected 'green (clear)', got '$out'"; exit 1; }
echo "  ok: report-line-green — --report-line prints exactly 'green (clear)' for a clean success set"

# ---------------------------------------------------------------- 14. --report-line: the
# wrong-workflow trap (AC2) — the literal shape of the #429/#449 incident
#
# The target sha's OWN check-runs are failed. `gh run list` is armed to answer a fabricated,
# COMPLETED, SUCCESSFUL run named after a different workflow (`pages-build-deployment`), with the
# exact job names the incident's agents cited as their (wrong) evidence: build/deploy/
# report-build-status. `--report-line` must never let that leak in — it prints `RED (failed)`,
# derived only from the real check-runs for this sha.
reset_case report-line-wrong-workflow
SHA=8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f
arm "$SHA" "$(page "$(run_obj kit 990 failure)")"
export RUN_LIST_TRAP='[{"databaseId":90000000001,"headSha":"'"$SIBLING_SHA"'","conclusion":"success","status":"completed","name":"pages-build-deployment","jobs":["build","deploy","report-build-status"],"url":"https://github.invalid/run/90000000001"}]'
out=$("$HELPER" "$SHA" --report-line --timeout 60 --poll-seconds 0)
[ "$out" = "RED (failed)" ] || { echo "FAIL [report-line-wrong-workflow]: expected 'RED (failed)', got '$out'"; exit 1; }
if grep -qF 'run list' "$GH_CALL_LOG"; then
  echo "FAIL [report-line-wrong-workflow]: the helper asked a recency-shaped question (\`gh run list\`)."
  echo "      --report-line must derive its answer only from the check-runs endpoint for this sha:"
  sed 's/^/      /' "$GH_CALL_LOG"; exit 1
fi
export RUN_LIST_TRAP='[{"databaseId":33346395704,"headSha":"'"$SIBLING_SHA"'","conclusion":"failure","status":"completed","name":"kit","url":"https://github.invalid/run/33346395704"}]'
echo "  ok: report-line-wrong-workflow — a wrong-workflow 'green' from gh run list never leaks into the line"

# ---------------------------------------------------------------- 15. --report-line: cancelled-only
reset_case report-line-cancelled
SHA=9090909090909090909090909090909090909090
arm "$SHA" "$(page "$(run_obj kit 991 cancelled)")"
out=$("$HELPER" "$SHA" --report-line --timeout 0 --poll-seconds 0)
[ "$out" = "unverified (cancelled)" ] || { echo "FAIL [report-line-cancelled]: expected 'unverified (cancelled)', got '$out'"; exit 1; }
echo "  ok: report-line-cancelled — a cancelled-only sha prints exactly 'unverified (cancelled)'"

# ---------------------------------------------------------------- 16. --report-line: a pending
# set that never settles before --timeout
reset_case report-line-timeout
SHA=a1b2a1b2a1b2a1b2a1b2a1b2a1b2a1b2a1b2a1b2
arm "$SHA" "$(page "$(run_obj kit 992 queued)")"
out=$("$HELPER" "$SHA" --report-line --timeout 0 --poll-seconds 0)
[ "$out" = "unverified (timeout)" ] || { echo "FAIL [report-line-timeout]: expected 'unverified (timeout)', got '$out'"; exit 1; }
echo "  ok: report-line-timeout — a run that never settles prints exactly 'unverified (timeout)'"

# ---------------------------------------------------------------- 17. --report-line: no CI posted
# at all
reset_case report-line-no-ci
SHA=c3d4c3d4c3d4c3d4c3d4c3d4c3d4c3d4c3d4c3d4
out=$("$HELPER" "$SHA" --report-line --timeout 0 --poll-seconds 0)
[ "$out" = "unverified (no-ci)" ] || { echo "FAIL [report-line-no-ci]: expected 'unverified (no-ci)', got '$out'"; exit 1; }
echo "  ok: report-line-no-ci — a sha with no check-runs prints exactly 'unverified (no-ci)'"

# ---------------------------------------------------------------- 17b. base-run-followup.sh: the
# one-shot lookup for a timeout-reasoned unverified base verdict (#561, AC1-AC5)
#
# `base-run-verdict.sh` itself never calls `gh run list` (cases 1, 2 and 14 above pin that red).
# This helper is the one place in the skill that does — invoked by Step 5b only when the verdict's
# own reason is exactly `timeout` — so it gets its own scripted `gh run list` answers via
# $RUN_LIST_TRAP and its own fresh call log per case.
FOLLOWUP="./skills/merge-pr/scripts/base-run-followup.sh"
[ -x "$FOLLOWUP" ] || { echo "FAIL: $FOLLOWUP missing or not executable"; exit 1; }

followup_of() {   # followup_of <base> <sha> — always exits 0, always prints one report-line
  local out rc=0
  out=$("$FOLLOWUP" "$@" 2>"$WORK/followup.err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: base-run-followup.sh exited $rc — a post-merge reader must always answer:" >&2
    sed 's/^/      /' "$WORK/followup.err" >&2
    exit 1
  fi
  printf '%s' "$out"
}

reset_case followup-green
SHA=b1c2b1c2b1c2b1c2b1c2b1c2b1c2b1c2b1c2b1c2
export RUN_LIST_TRAP='[{"headSha":"'"$SHA"'","conclusion":"success","workflowName":"kit","createdAt":"2026-09-12T09:05:00Z"}]'
out=$(followup_of main "$SHA")
[ "$out" = "green (base-run)" ] || { echo "FAIL [followup-green]: expected 'green (base-run)', got '$out'"; exit 1; }
n=$(grep -c 'run list' "$GH_CALL_LOG" || true)
[ "$n" -eq 1 ] || { echo "FAIL [followup-green]: expected exactly one 'gh run list' call (AC5), got $n:"; cat "$GH_CALL_LOG"; exit 1; }
echo "  ok: followup-green — a completed, successful run for the sha reports 'green (base-run)' in one call (AC1, AC5)"

reset_case followup-red
SHA=c2d3c2d3c2d3c2d3c2d3c2d3c2d3c2d3c2d3c2d3
export RUN_LIST_TRAP='[{"headSha":"'"$SHA"'","conclusion":"failure","workflowName":"kit","createdAt":"2026-09-12T09:05:00Z"}]'
out=$(followup_of main "$SHA")
[ "$out" = "RED (base-run)" ] || { echo "FAIL [followup-red]: expected 'RED (base-run)', got '$out'"; exit 1; }
echo "  ok: followup-red — a completed, failed run for the sha reports 'RED (base-run)' (AC2)"

reset_case followup-no-match
SHA=d3e4d3e4d3e4d3e4d3e4d3e4d3e4d3e4d3e4d3e4
export RUN_LIST_TRAP='[{"headSha":"'"$SIBLING_SHA"'","conclusion":"success","workflowName":"kit","createdAt":"2026-09-12T09:05:00Z"}]'
out=$(followup_of main "$SHA")
[ "$out" = "unverified (timeout)" ] || { echo "FAIL [followup-no-match]: expected 'unverified (timeout)', got '$out'"; exit 1; }
echo "  ok: followup-no-match — nothing in the listing matches the sha: unverified (timeout), unchanged (AC3)"

reset_case followup-still-running
SHA=e4f5e4f5e4f5e4f5e4f5e4f5e4f5e4f5e4f5e4f5
export RUN_LIST_TRAP='[{"headSha":"'"$SHA"'","conclusion":null,"workflowName":"kit","createdAt":"2026-09-12T09:05:00Z"}]'
out=$(followup_of main "$SHA")
[ "$out" = "unverified (timeout)" ] || { echo "FAIL [followup-still-running]: expected 'unverified (timeout)', got '$out'"; exit 1; }
echo "  ok: followup-still-running — the matched run has no conclusion yet: unverified (timeout), unchanged (AC3)"

reset_case followup-gh-fails
SHA=f5a6f5a6f5a6f5a6f5a6f5a6f5a6f5a6f5a6f5a6
export RUN_LIST_TRAP='ERR:this-must-not-be-read-as-a-verdict'
rc=0
out=$("$FOLLOWUP" main "$SHA" 2>/dev/null) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [followup-gh-fails]: expected exit 0, got $rc"; exit 1; }
[ "$out" = "unverified (timeout)" ] || { echo "FAIL [followup-gh-fails]: expected 'unverified (timeout)', got '$out'"; exit 1; }
echo "  ok: followup-gh-fails — the lookup itself failing is not evidence about the base: unverified (timeout), exit 0 (AC3)"

reset_case followup-multi-newest-wins
SHA=a6b7a6b7a6b7a6b7a6b7a6b7a6b7a6b7a6b7a6b7
export RUN_LIST_TRAP='[{"headSha":"'"$SHA"'","conclusion":"failure","workflowName":"kit","createdAt":"2026-09-12T09:00:00Z"},{"headSha":"'"$SHA"'","conclusion":"success","workflowName":"kit","createdAt":"2026-09-12T09:05:00Z"}]'
out=$(followup_of main "$SHA")
[ "$out" = "green (base-run)" ] || { echo "FAIL [followup-multi-newest-wins]: expected 'green (base-run)', got '$out'"; exit 1; }
echo "  ok: followup-multi-newest-wins — several runs for the sha resolve to the newest createdAt, mirroring base-run-verdict.sh's own reduction"

reset_case followup-usage
rc=0; out=$("$FOLLOWUP" 2>&1) || rc=$?
[ "$rc" -eq 64 ] || { echo "FAIL [followup-usage]: expected exit 64 with no args, got $rc"; echo "$out"; exit 1; }
echo "  ok: followup-usage — no base branch/sha refuses with exit 64 rather than printing a non-verdict"

reset_case followup-wrong-workflow-does-not-launder
# The exact #429/#449-shaped trap, one level down: this push triggered TWO workflows on the same
# sha (this repo's own `ci` and `release-please` both fire on a push to main) — release-please
# finished fast and green, `ci` itself is still running (no conclusion yet). Taking the single
# newest entry overall would read release-please's `success` as the verdict; grouping by workflow
# first must keep `ci`'s own non-answer from being laundered into a green.
SHA=b7c8b7c8b7c8b7c8b7c8b7c8b7c8b7c8b7c8b7c8
export RUN_LIST_TRAP='[{"headSha":"'"$SHA"'","conclusion":"success","workflowName":"release-please","createdAt":"2026-09-12T09:05:05Z"},{"headSha":"'"$SHA"'","conclusion":null,"workflowName":"ci","createdAt":"2026-09-12T09:05:00Z"}]'
out=$(followup_of main "$SHA")
[ "$out" = "unverified (timeout)" ] || { echo "FAIL [followup-wrong-workflow-does-not-launder]: expected 'unverified (timeout)', got '$out' — a fast, unrelated workflow's success must not stand in for the CI run that is still going"; exit 1; }
echo "  ok: followup-wrong-workflow-does-not-launder — release-please's fast green does not launder ci's own still-running run into a verdict"

reset_case followup-red-wins-over-unrelated-green
# The mirror, in the direction that matters more: `ci` itself genuinely failed on this sha while
# release-please succeeded. RED must win — a real failure is never masked by an unrelated pass.
SHA=c8d9c8d9c8d9c8d9c8d9c8d9c8d9c8d9c8d9c8d9
export RUN_LIST_TRAP='[{"headSha":"'"$SHA"'","conclusion":"success","workflowName":"release-please","createdAt":"2026-09-12T09:05:05Z"},{"headSha":"'"$SHA"'","conclusion":"failure","workflowName":"ci","createdAt":"2026-09-12T09:05:00Z"}]'
out=$(followup_of main "$SHA")
[ "$out" = "RED (base-run)" ] || { echo "FAIL [followup-red-wins-over-unrelated-green]: expected 'RED (base-run)', got '$out'"; exit 1; }
echo "  ok: followup-red-wins-over-unrelated-green — ci's real failure reports red even though release-please succeeded on the same sha"

reset_case followup-all-workflows-green
# The clean multi-workflow case: every workflow that ran on this sha succeeded — green is correct
# once every group, not just the newest overall, has been checked.
SHA=d9e0d9e0d9e0d9e0d9e0d9e0d9e0d9e0d9e0d9e0
export RUN_LIST_TRAP='[{"headSha":"'"$SHA"'","conclusion":"success","workflowName":"release-please","createdAt":"2026-09-12T09:05:05Z"},{"headSha":"'"$SHA"'","conclusion":"success","workflowName":"ci","createdAt":"2026-09-12T09:05:00Z"}]'
out=$(followup_of main "$SHA")
[ "$out" = "green (base-run)" ] || { echo "FAIL [followup-all-workflows-green]: expected 'green (base-run)', got '$out'"; exit 1; }
echo "  ok: followup-all-workflows-green — green only once every workflow on the sha has succeeded"

# Restore the red trap the merge-train cases above (and any re-run of this file top to bottom) rely on.
export RUN_LIST_TRAP='[{"databaseId":33346395704,"headSha":"'"$SIBLING_SHA"'","conclusion":"failure","status":"completed","name":"kit","url":"https://github.invalid/run/33346395704"}]'

# ---------------------------------------------------------------- 18. Step 5b quotes the literal
# line and names the forbidden shortcuts (#455 Task 3, AC3)
#
# A structural check on the prose, not the script: Step 5b's `BASE:` value must be the literal
# `--report-line` output, and the step must name the two specific anti-patterns the #429/#449
# incident measured — `gh run list` and inferring status from another workflow's job names.
MERGE_PROSE="$(kit_skill_prose "$KIT_ROOT" merge-pr)"   # router + references/steps/*.md (#499)
grep -q -- '--report-line' "$MERGE_PROSE" || {
  echo "FAIL: skills/merge-pr/SKILL.md never mentions --report-line — Step 5b must call it, not"
  echo "      compose its own sentence around the JSON verdict/reason"
  exit 1; }
grep -qi 'never.*gh run list' "$MERGE_PROSE" || {
  echo "FAIL: skills/merge-pr/SKILL.md does not forbid 'gh run list' for Step 5b's BASE: value"
  exit 1; }
grep -q 'pages-build-deployment' "$MERGE_PROSE" || {
  echo "FAIL: skills/merge-pr/SKILL.md does not name the pages-build-deployment trap (#429/#449)"
  exit 1; }
echo "  ok: merge-pr-skill-prose — Step 5b quotes --report-line and names the forbidden shortcuts"

# ---------------------------------------------------------------- 18b. Step 5b's timeout follow-up
# is gated behind the literal reason string, never a broader match (#561, AC4)
grep -qF 'base-run-followup.sh' "$MERGE_PROSE" || {
  echo "FAIL: skills/merge-pr/SKILL.md's prose never mentions base-run-followup.sh — Step 5b must"
  echo "      call it on a timeout verdict, not compose its own ad hoc gh run list question"
  exit 1; }
grep -qF '"unverified (timeout)")' "$MERGE_PROSE" || {
  echo "FAIL: Step 5b's follow-up call is not gated behind the literal case arm"
  echo "      '\"unverified (timeout)\")' — every other verdict/reason must stay byte-for-byte"
  echo "      unchanged (AC4)"
  exit 1; }
echo "  ok: merge-pr-skill-prose-followup — the timeout follow-up is gated behind the literal reason string, not a broader match"

# ---------------------------------------------------------------- 19. auto-dev grammar-checks
# BASE: before trusting it (#455 Task 4, AC4)
grep -qF '^(green|RED|unverified)' skills/auto-dev/SKILL.md || {
  echo "FAIL: skills/auto-dev/SKILL.md never states the BASE: field's fixed grammar"
  exit 1; }
grep -qi 're-derive' skills/auto-dev/SKILL.md || {
  echo "FAIL: skills/auto-dev/SKILL.md never says a non-matching BASE: value is re-derived"
  exit 1; }
echo "  ok: auto-dev-skill-prose — the BASE: field states its grammar and the re-derive backstop"

# ---------------------------------------------------------------- 20. check-runs 404s, the workflow
# runs for the sha exist (#479)
#
# Twelve merges of one GHES fleet run answered `unverified (query-failed)` because check-runs
# 404s on a just-created squash sha while `actions/runs?head_sha=<sha>` already lists the run.
# The fallback must read THAT — keyed by sha, so the sibling-merge trap stays armed — and say
# which path answered.
wf_run() {   # <completed-<conclusion>|<status>> → one workflow-run object for $SHA
  case "$1" in
    completed-*) printf '{"id":777,"name":"kit","head_sha":"%s","status":"completed","conclusion":"%s","html_url":"https://github.invalid/run/777","run_started_at":"2026-09-09T09:00:00Z"}' "$SHA" "${1#completed-}" ;;
    *)           printf '{"id":777,"name":"kit","head_sha":"%s","status":"%s","conclusion":null,"html_url":"https://github.invalid/run/777","run_started_at":"2026-09-09T09:00:00Z"}' "$SHA" "$1" ;;
  esac
}
arm_wf() { mkdir -p "$GH_RESPONSES/$SHA"; printf '{"total_count":1,"workflow_runs":[%s]}' "$1" > "$GH_RESPONSES/$SHA/workflow-runs.json"; }

reset_case fallback-red
SHA=d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5
arm "$SHA" 'ERR:HTTP 404: Not Found'
arm_wf "$(wf_run completed-failure)"
out=$("$HELPER" "$SHA" --report-line --timeout 0 --poll-seconds 0)
[ "$out" = "RED (base-run)" ] || { echo "FAIL [fallback-red]: expected 'RED (base-run)', got '$out'"; cat "$GH_CALL_LOG"; exit 1; }
grep -qF "head_sha=$SHA" "$GH_CALL_LOG" || { echo "FAIL [fallback-red]: the fallback did not ask workflow-runs BY SHA"; cat "$GH_CALL_LOG"; exit 1; }
if grep -qE 'actions/runs\?branch=|run list' "$GH_CALL_LOG"; then
  echo "FAIL [fallback-red]: the fallback asked a recency-shaped question"; cat "$GH_CALL_LOG"; exit 1; fi
echo "  ok: fallback-red — check-runs 404 + a failing workflow run for the sha prints 'RED (base-run)' (#479)"

reset_case fallback-green
SHA=e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6e6
arm "$SHA" 'ERR:HTTP 404: Not Found'
arm_wf "$(wf_run completed-success)"
out=$("$HELPER" "$SHA" --report-line --timeout 5 --poll-seconds 0)
[ "$out" = "green (base-run)" ] || { echo "FAIL [fallback-green]: expected 'green (base-run)', got '$out'"; exit 1; }
echo "  ok: fallback-green — check-runs 404 + a passing workflow run for the sha prints 'green (base-run)'"

reset_case fallback-no-run-yet
SHA=f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7
arm "$SHA" 'ERR:HTTP 404: Not Found'
out=$("$HELPER" "$SHA" --report-line --timeout 0 --settle 0 --poll-seconds 0)
[ "$out" = "unverified (no-run-yet)" ] || { echo "FAIL [fallback-no-run-yet]: expected 'unverified (no-run-yet)', got '$out'"; exit 1; }
echo "  ok: fallback-no-run-yet — check-runs 404 + nothing for the sha yet prints 'unverified (no-run-yet)', not 'no-ci'"

# Every fallback line still matches #455's grammar.
for line in "RED (base-run)" "green (base-run)" "unverified (no-run-yet)"; do
  printf '%s\n' "$line" | grep -qE '^(green|RED|unverified) \([a-z-]+\)$' \
    || { echo "FAIL [fallback-grammar]: '$line' breaks the report-line grammar"; exit 1; }
done
echo "  ok: fallback-grammar — the three fallback tokens match ^(green|RED|unverified) \\([a-z-]+\\)$"

# ---------------------------------------------------------------- 21. the repository's own host (#514)
#
# `gh api` never infers a host, so on a GitHub Enterprise checkout both reads — check-runs and the
# #479 workflow-runs fallback — reached github.com, and that base's verdict was never read. The seam
# is the stub's log: the GH_HOST each call ran under, and its endpoint. Each case arms the check-runs
# 404 so that BOTH reads are made, and runs the script by its absolute path from the checkout whose
# origin decides the host.
HELPER_ABS="$KIT_ROOT/skills/merge-pr/scripts/base-run-verdict.sh"
expect_call() {   # expect_call <label> <fixed string> — the case's gh log holds a line containing it
  grep -qF -- "$2" "$GH_CALL_LOG" || {
    echo "FAIL [$1]: gh was never called as '$2':"; sed 's/^/      /' "$GH_CALL_LOG"; exit 1; }
}
arm_ghe() {   # check-runs 404s and the sha's workflow run failed: the fallback answers red
  arm "$SHA" 'ERR:HTTP 404: Not Found'
  arm_wf "$(wf_run completed-failure)"
}
CO_GHE="$WORK/co-ghe"
git init -q "$CO_GHE"
git -C "$CO_GHE" remote add origin git@ghe.example.com:acme/widgets.git

reset_case followup-ghe
# The #514 host bug, one script over (#561): with an explicit -R (no host prefix), the follow-up's
# one `gh run list` lookup must run under the ORIGIN's host, never gh's default — the same
# origin-checkout case the ghe-origin/ghe-repo cases below pin for check-runs and workflow-runs.
SHA=e0f1e0f1e0f1e0f1e0f1e0f1e0f1e0f1e0f1e0f1
export RUN_LIST_TRAP='[{"headSha":"'"$SHA"'","conclusion":"success","workflowName":"ci","createdAt":"2026-09-12T09:05:00Z"}]'
out=$(cd "$CO_GHE" && GH_STUB_HOSTS=ghe.example.com "$KIT_ROOT/skills/merge-pr/scripts/base-run-followup.sh" -R acme/widgets main "$SHA")
[ "$out" = "green (base-run)" ] || { echo "FAIL [followup-ghe]: expected 'green (base-run)', got '$out'"; cat "$GH_CALL_LOG"; exit 1; }
grep -qF "GH_HOST=ghe.example.com ARGS: -R acme/widgets run list" "$GH_CALL_LOG" || {
  echo "FAIL [followup-ghe]: the lookup did not run under GH_HOST=ghe.example.com:"; sed 's/^/      /' "$GH_CALL_LOG"; exit 1; }
echo "  ok: followup-ghe — the follow-up's one gh run list call resolves the repository's own host (#514), like every sibling gh call in this skill"

reset_case ghe-origin
SHA=1a2b1a2b1a2b1a2b1a2b1a2b1a2b1a2b1a2b1a2b
arm_ghe
out=$(cd "$CO_GHE" && GH_STUB_HOSTS=ghe.example.com "$HELPER_ABS" "$SHA" --report-line --timeout 0 --poll-seconds 0)
[ "$out" = "RED (base-run)" ] || { echo "FAIL [ghe-origin]: expected 'RED (base-run)', got '$out'"; cat "$GH_CALL_LOG"; exit 1; }
expect_call ghe-origin "GH_HOST=ghe.example.com ARGS: api repos/{owner}/{repo}/commits/$SHA/check-runs "
expect_call ghe-origin "GH_HOST=ghe.example.com ARGS: api repos/{owner}/{repo}/actions/runs?head_sha=$SHA&"
echo "  ok: ghe-origin — with no -R, both reads ask repos/{owner}/{repo}/… under GH_HOST=ghe.example.com"

reset_case ghe-repo
SHA=2b3c2b3c2b3c2b3c2b3c2b3c2b3c2b3c2b3c2b3c
arm_ghe
out=$(cd "$CO_GHE" && GH_STUB_HOSTS=ghe.example.com "$HELPER_ABS" -R acme/widgets "$SHA" --report-line --timeout 0 --poll-seconds 0)
[ "$out" = "RED (base-run)" ] || { echo "FAIL [ghe-repo]: expected 'RED (base-run)', got '$out'"; cat "$GH_CALL_LOG"; exit 1; }
expect_call ghe-repo "GH_HOST=ghe.example.com ARGS: api repos/acme/widgets/commits/$SHA/check-runs "
expect_call ghe-repo "GH_HOST=ghe.example.com ARGS: api repos/acme/widgets/actions/runs?head_sha=$SHA&"
echo "  ok: ghe-repo — -R acme/widgets: both reads ask repos/acme/widgets/… under GH_HOST=ghe.example.com"

# A HOST/ prefix on -R names the host outright — even from this checkout, whose origin is
# github.com — and only OWNER/REPO reaches the endpoint.
reset_case ghe-prefix
SHA=3c4d3c4d3c4d3c4d3c4d3c4d3c4d3c4d3c4d3c4d
arm_ghe
out=$("$HELPER" -R ghe.example.com/acme/widgets "$SHA" --report-line --timeout 0 --poll-seconds 0)
[ "$out" = "RED (base-run)" ] || { echo "FAIL [ghe-prefix]: expected 'RED (base-run)', got '$out'"; cat "$GH_CALL_LOG"; exit 1; }
expect_call ghe-prefix "GH_HOST=ghe.example.com ARGS: api repos/acme/widgets/commits/$SHA/check-runs "
expect_call ghe-prefix "GH_HOST=ghe.example.com ARGS: api repos/acme/widgets/actions/runs?head_sha=$SHA&"
if grep -qF 'repos/ghe.example.com' "$GH_CALL_LOG"; then
  echo "FAIL [ghe-prefix]: the host leaked into the endpoint:"; sed 's/^/      /' "$GH_CALL_LOG"; exit 1
fi
echo "  ok: ghe-prefix — -R HOST/OWNER/REPO: the reads ask repos/acme/widgets/… under GH_HOST=ghe.example.com"

# github.com stays as it was: this checkout's origin names a host the stub holds no token for, so
# no read runs under a GH_HOST and gh keeps its own default.
reset_case github-unchanged
SHA=4d5e4d5e4d5e4d5e4d5e4d5e4d5e4d5e4d5e4d5e
arm "$SHA" "$(page "$(run_obj kit 996 success)")"
v=$(verdict_of "$SHA" --timeout 60 --poll-seconds 0)
expect_verdict github-unchanged green "$v"
if grep -qE '^GH_HOST=[^<]' "$GH_CALL_LOG"; then
  echo "FAIL [github-unchanged]: a read ran under a GH_HOST nobody asked for:"; sed 's/^/      /' "$GH_CALL_LOG"; exit 1
fi
echo "  ok: github-unchanged — no credentials for the origin's host: every read keeps gh's default"

# A malformed -R is a usage error: exit 64, the slug named, gh never called.
reset_case malformed-slug
rc=0; out=$("$HELPER" -R acme 5e6f5e6f5e6f5e6f5e6f5e6f5e6f5e6f5e6f5e6f --timeout 0 --poll-seconds 0 2>&1) || rc=$?
[ "$rc" -eq 64 ] || { echo "FAIL [malformed-slug]: expected exit 64, got $rc"; echo "$out"; exit 1; }
grep -qF "malformed repository slug 'acme'" <<<"$out" || { echo "FAIL [malformed-slug]: stderr does not name the slug: $out"; exit 1; }
[ ! -s "$GH_CALL_LOG" ] || { echo "FAIL [malformed-slug]: gh was called:"; cat "$GH_CALL_LOG"; exit 1; }
echo "  ok: malformed-slug — -R acme is exit 64, the slug named, no gh call"

# The host helper is part of the install: without it the reader refuses, naming the missing file,
# rather than reading gh's default host — the exact #514 failure.
NOHELPER="$WORK/nohelper"
mkdir -p "$NOHELPER/skills/merge-pr/scripts" "$NOHELPER/scripts"
cp "$HELPER_ABS" "$NOHELPER/skills/merge-pr/scripts/base-run-verdict.sh"
# The script's own `[ -x "$DECIDE" ]` check runs before the helper loads; this stand-in is never run.
printf '#!/bin/sh\nexit 99\n' > "$NOHELPER/scripts/decide.sh"
chmod +x "$NOHELPER/scripts/decide.sh"
reset_case missing-helper
rc=0; out=$(bash "$NOHELPER/skills/merge-pr/scripts/base-run-verdict.sh" 6f7a6f7a6f7a6f7a6f7a6f7a6f7a6f7a6f7a6f7a --timeout 0 --poll-seconds 0 2>&1) || rc=$?
[ "$rc" -eq 64 ] || { echo "FAIL [missing-helper]: expected exit 64, got $rc"; echo "$out"; exit 1; }
grep -qF '_shared/scripts/_gh-host.sh; reinstall the kit' <<<"$out" || { echo "FAIL [missing-helper]: stderr does not name the helper: $out"; exit 1; }
[ ! -s "$GH_CALL_LOG" ] || { echo "FAIL [missing-helper]: gh was called:"; cat "$GH_CALL_LOG"; exit 1; }
echo "  ok: missing-helper — exit 64, the missing helper named, no gh call"

echo "merge-base-ci golden test OK"
