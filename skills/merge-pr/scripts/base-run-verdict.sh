#!/usr/bin/env bash
# base-run-verdict.sh — read the base branch's CI verdict AT THE SHA a merge just produced (#355).
#
# WHY THIS EXISTS. `merge-pr` gates hard on CI *before* the merge and then tears down at PR-green:
# Step 5 merges, Step 6 files follow-ups, Step 7 deletes the branch, Step 8 recaps. Nothing in
# that tail ever looks at the workflow run the merge itself triggers on the base branch — so a
# green PR check-run, which only ever proved the branch was green against the base it was TESTED
# with, is allowed to stand in for "the tree this merge produced is green". Two PRs each green
# against their own base can still break `main` when both land.
#
# Measured on this repo, 2026-08-30: `dce7d5b` (#338) had its push run on `main` CANCELLED,
# superseded 2m39s later by the next merge; `f17c85c` (#342) had run 33346395704 record the
# failure. Both PRs had already reported MERGED and torn down, so neither run was ever read. `main`
# stayed red ~40 minutes and every in-flight PR in the fleet inherited the red bar — PR #340's own
# CI failed on it despite its diff being unrelated. A human noticed; #352 was filed by hand.
#
# WHAT IT DOES. Given the squash sha `guarded-pr-merge.sh` printed on exit 0, it resolves the
# check-runs FOR THAT SHA, polls while any of them is still running (bounded), and hands the final
# set to the registered decision `ci.verdict` — the same reduction `merge-pr` Step 3 already runs.
# It prints one JSON object and exits 0.
#
#   {"verdict":"green|red|unverified","reason":"<slug>","sha":"<sha>","runs":[{name,html_url,state}]}
#
# BY SHA, NEVER BY RECENCY. `gh run list --branch main` answers "the newest run on the branch",
# which under a merge train — the normal `auto-dev` shape — is routinely a SIBLING merge's run
# landing seconds later. That would attribute someone else's red to this merge, and someone else's
# green over this merge's red. The check-runs endpoint is keyed on the sha by construction, which
# is why it is the one asked here (and it is the same endpoint §3 already uses). Nothing in this
# script asks a recency-shaped question; `tests/merge-base-ci/test.sh` arms a deliberately wrong
# `gh run list` answer so a rewrite that reaches for one goes red.
#
# THE FALLBACK IS ALSO BY SHA (#479). On GitHub Enterprise Server the check-runs endpoint answered
# 404 on every one of twelve just-created squash shas in one fleet run — eventually consistent —
# while the workflow runs for those very shas were visible, so every merge reported `unverified`
# and a base that went red twice was never seen. When check-runs FAILS (404, any error) the
# workflow-runs endpoint is asked `?head_sha=<sha>` — keyed on the sha like check-runs, never on
# the branch — and its runs are mapped into the check-runs shape so the same `ci.verdict`
# reduction judges them. A verdict from that path says so in its reason: `green (base-run)`,
# `RED (base-run)`, and `unverified (no-run-yet)` when it found nothing for the sha. Twelve
# `unverified` in a row is a FINDING, not a default — `merge-pr` Step 5b says so.
#
# THE VERDICT MAPPING. `ci.verdict` answers a PRE-merge question, so its four words do not map
# one-to-one onto a POST-merge report. This script maps them; it does not re-decide them, and it
# adds no second rule set (#208 — one id, one program, one home):
#
#   clear   -> green       reason "clear"
#   failed  -> red         reason "failed"      ... unless every failing job's latest run is
#              unverified  reason "cancelled"       `cancelled`, which is a NON-VERDICT, not a
#                                                   pass and not a breakage. `cancel-in-progress`
#                                                   (#27/#29) cancels the previous `main` run the
#                                                   moment the next merge lands, so under a fleet
#                                                   this is the COMMON outcome — it is exactly the
#                                                   `dce7d5b` case above, and the honest answer is
#                                                   "this merge's effect was never verified".
#   pending -> keep polling; on timeout, unverified, reason "timeout"
#   no-ci   -> unverified  reason "no-ci"       the base runs no CI on push, or the run has not
#                                               been posted yet. Pre-merge that means "let
#                                               mergeStateStatus decide"; post-merge the merge has
#                                               already happened and there is nothing to decide —
#                                               reporting it green is the regression #355 exists
#                                               to prevent.
#
# NEITHER `clear` NOR `no-ci` IS ANSWERED ON THE FIRST READING, because this runs seconds after the
# merge and GitHub posts check-runs on its own schedule. `no-ci` is indistinguishable from "nothing
# posted yet", so it is retried until `--settle` (default 90s, clamped to `--timeout`) expires;
# `clear` is indistinguishable from "only the fast jobs have posted", so it is accepted only once
# the reduced JOB SET matches the previous poll's. §4 has the full argument. `failed` IS answered
# immediately: a job that failed does not become un-failed when a later job posts.
#
# A TIMEOUT IS NOT A BREAKAGE. On expiry the answer is `unverified`, never `red`: a skill that
# reported a slow run as a failure would file bugs against healthy merges. And an `unverified` is
# not this script failing — it is this script working, and saying so.
#
# IT ALWAYS ANSWERS. Exit is 0 for every verdict, including every non-verdict. `merge-pr` calls
# this AFTER the merge has landed and cannot be undone, so a non-zero exit here would give an
# autonomous fleet a brand-new way to strand a slot on a merge that already succeeded. The only
# refusals, both exit 64 and both before any `gh` call, are a usage error — no sha to resolve, and
# printing `unverified` would let a caller that forgot its argument report a clean non-verdict
# forever — and a kit whose host helper will not load (#514), where every read would reach gh's
# default host and a GitHub Enterprise base would never be read at all.
#
# IT NEVER REVERTS, and this script cannot: it performs no writes at all. On red the caller files
# a bug naming the sha and the run URL (`merge-pr` Step 5b). An autonomous revert of what may well
# be a sibling merge's breakage is a strictly worse failure than a filed issue.
#
# Exit codes:
#   0   a verdict was produced — `green`, `red`, or one of the `unverified` non-verdicts
#   64  usage error: no sha, an unparseable option, a non-numeric bound, a malformed -R slug — or
#       skills/_shared/scripts/_gh-host.sh cannot be loaded
set -euo pipefail

TOOL="base-run-verdict"

usage() {
  echo "usage: $TOOL.sh [-R <[host/]owner/repo>] <base-sha> [--timeout <s>] [--poll-seconds <s>] [--settle <s>] [--report-line]" >&2
}
refuse() { echo "$TOOL: $1" >&2; usage; exit 64; }

# ------------------------------------------------------------------------------ 1. self-location
#
# $0 through any symlinks first — a plugin install reaches this file by link, and `pwd -P` alone
# canonicalizes the directory, not the link. No `readlink -f`: macOS's readlink has no -f. Lifted
# from scripts/decide.sh, which lifted it from guarded-commit.sh, where the loop was debugged.
SELF="$0"
while [ -L "$SELF" ]; do
  _link=$(readlink -- "$SELF") || break
  case "$_link" in
    /*) SELF="$_link" ;;
    *)  SELF="$(dirname -- "$SELF")/$_link" ;;
  esac
done
KIT_ROOT=$(CDPATH= cd -- "$(dirname -- "$SELF")/../../.." && pwd -P) \
  || KIT_ROOT="$(dirname -- "$SELF")/../../.."
DECIDE="$KIT_ROOT/scripts/decide.sh"

# ------------------------------------------------------------------------------ 2. the arguments
SHA=""
REPO=""
TIMEOUT=600
POLL_SECONDS=15
SETTLE=90
REPORT_LINE=0

is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)      usage; exit 0 ;;
    -R|--repo)      REPO="${2:-}"; [ -n "$REPO" ] || refuse "-R needs an <owner/repo>"; shift 2 ;;
    --timeout)      TIMEOUT="${2:-}"; is_uint "$TIMEOUT" || refuse "--timeout needs a whole number of seconds, got '${2:-}'"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="${2:-}"; is_uint "$POLL_SECONDS" || refuse "--poll-seconds needs a whole number of seconds, got '${2:-}'"; shift 2 ;;
    --settle)       SETTLE="${2:-}"; is_uint "$SETTLE" || refuse "--settle needs a whole number of seconds, got '${2:-}'"; shift 2 ;;
    --report-line)  REPORT_LINE=1; shift ;;
    --)             shift ;;
    -*)             refuse "unexpected option: $1" ;;
    *)
      [ -z "$SHA" ] || refuse "two shas given: '$SHA' and '$1' — one merge produces one sha"
      SHA="$1"; shift ;;
  esac
done

[ -n "$SHA" ] || refuse "no base sha given (guarded-pr-merge.sh prints it as \`MERGED <sha>\` on exit 0)"
case "$SHA" in
  *[!0-9a-fA-F]*|"") refuse "'$SHA' is not a hex sha" ;;
esac

command -v jq > /dev/null 2>&1 || refuse "jq is missing — it is a \`required\` prerequisite in requirements.json"
command -v gh > /dev/null 2>&1 || refuse "gh is missing — there is no other way to read check-runs"
[ -x "$DECIDE" ] || refuse "cannot execute $DECIDE — the ci.verdict decision has no other home"

# The repository's own host (#514): `gh api` never infers one, so on a GitHub Enterprise base both
# reads below reached github.com. Decided in ONE place, the helper, once and before the poll loop;
# its exported GH_HOST reaches every read. With no -R it takes the checkout's origin host; a HOST/
# prefix on -R names the host outright and is stripped to OWNER/REPO.
# CALLABLE, not merely readable: an empty or truncated helper sources cleanly and defines nothing.
GH_HOST_LIB="$KIT_ROOT/skills/_shared/scripts/_gh-host.sh"
if [ -r "$GH_HOST_LIB" ]; then . "$GH_HOST_LIB" || true; fi
command -v gh_host_resolve > /dev/null 2>&1 \
  || { echo "$TOOL: REFUSED — cannot load $GH_HOST_LIB; reinstall the kit" >&2; exit 64; }
gh_host_resolve "$REPO" || exit 64

# `{owner}/{repo}` is gh's own placeholder, resolved from the repository gh is pointed at. An
# explicit -R overrides it, which is what lets a caller standing in a worktree of one repo read
# another's base branch.
OWNER_REPO="{owner}/{repo}"
[ -n "$REPO" ] && OWNER_REPO="$KIT_REPO_SLUG"

# ------------------------------------------------------------------------------- 3. the answer
#
# Printed through jq so the object is always valid JSON whatever the reason text holds, and always
# on ONE line: the caller reads it with `jq -r .verdict`, and a caller that captures it into a
# shell variable must not have to care about embedded newlines.
#
# `--report-line` (#455) formats the SAME two fields — no second data source, no re-poll — into
# the one-line grammar `^(green|RED|unverified) \([a-z-]+\)$` a caller can copy verbatim instead of
# composing its own sentence around the JSON. `red` is the only word capitalized, matching the
# capitalization `auto-dev`'s report-line convention already uses for that word.
answer() {
  local verdict="$1" reason="$2" runs="${3:-[]}"
  if [ "$REPORT_LINE" -eq 1 ]; then
    local word="$verdict"
    [ "$word" = "red" ] && word="RED"
    # Defensive sanitization: the grammar promises `[a-z-]+` for the reason even on the
    # `unexpected-ci-verdict:$ci` catch-all below (unreachable today — decide.sh's own vocabulary
    # restriction keeps `$ci` inside the known set — but a caller regex-matching this line should
    # never have to read this script's source to know it holds). A no-op on every known reason,
    # which is already lowercase a-z and `-` only.
    local safe_reason
    safe_reason=$(printf '%s' "$reason" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z-' '-')
    printf '%s (%s)\n' "$word" "$safe_reason"
    exit 0
  fi
  jq -cn --arg v "$verdict" --arg r "$reason" --arg s "$SHA" --argjson runs "$runs" \
    '{verdict: $v, reason: $r, sha: $s, runs: $runs}'
  exit 0
}

# ------------------------------------------------------------------------------ 4. the poll loop
#
# This runs SECONDS after `gh pr merge` returned, which is the whole point and also the whole
# difficulty: GitHub has not necessarily posted the push run's check-runs yet. Two races follow
# from that, and both read as a clean answer if the first reading is trusted:
#
#   * NOTHING POSTED YET looks exactly like A BASE WITH NO CI. `ci.verdict` answers `no-ci` to both,
#     and answering on the first poll would make `unverified` the near-universal outcome — the
#     600-second budget unused, and the step reporting a non-verdict for every healthy merge. So
#     `no-ci` is RETRIED until the settle window expires; only then is it an answer. The window is
#     what a base that genuinely runs no CI on push costs, once, and it is bounded.
#   * A PARTIALLY-POSTED JOB GRAPH looks exactly like a green one. A fast job's check-run can exist
#     and be `success` while a job behind a `needs:` chain has not posted at all, and the reduction
#     — correctly — calls that set clear. SKILL.md §3 already makes this argument pre-merge ("wait
#     one poll interval and re-derive"); post-merge the window is at its widest. So `clear` is
#     accepted only once the reduced JOB SET is the same as the previous poll's. That costs one
#     extra poll interval on a green base, not a settle window.
#
# `failed` is acted on immediately: a job that has genuinely failed does not become un-failed by a
# later job posting, and making a red base wait would delay the one outcome that needs filing.
#
# SECONDS is bash's own count of elapsed seconds since the shell started, so the deadline needs no
# `date` subprocess per poll and cannot be moved by a clock adjustment mid-run.
# An `if`, not `[ … ] && …`: under `set -e` that AND-list exits the script whenever the test is
# false, which is the ordinary case.
if [ "$SETTLE" -gt "$TIMEOUT" ]; then SETTLE="$TIMEOUT"; fi
start=$SECONDS
deadline=$(( start + TIMEOUT ))
settle_deadline=$(( start + SETTLE ))
last_reason="timeout"
verdict_json=""
ci=""
# Deliberately unmatchable: a first poll can never "agree" with a reading that does not exist, and
# a failed poll resets to it so a gap in the readings cannot be read as two agreeing ones.
NO_READING=$'\001none'
prev_sig="$NO_READING"
source=check-runs

while :; do
  raw=""
  rc=0
  # The two failures are kept apart deliberately. `gh` failing (rate limit, a network blip, an
  # unauthenticated host) is NOT evidence about the base branch, so it must not read as `no-ci`
  # — which is why it is retried until the deadline rather than answered on the first attempt.
  raw=$(gh api "repos/$OWNER_REPO/commits/$SHA/check-runs" --paginate --slurp 2>/dev/null) || rc=$?
  source=check-runs
  if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then
    # check-runs failed (a fresh sha 404s on GHES, #479): ask workflow-runs FOR THIS SHA and map
    # the answer into the check-runs shape — same reduction, no second rule set. Still by sha.
    wr=""; wrc=0
    wr=$(gh api "repos/$OWNER_REPO/actions/runs?head_sha=$SHA&per_page=100" 2>/dev/null) || wrc=$?
    if [ "$wrc" -eq 0 ] && [ -n "$wr" ]; then
      mapped=$(printf '%s' "$wr" | jq -c '[{total_count: 0, check_runs: [ .workflow_runs[]? | {name, id, app: {id: 0}, started_at: (.run_started_at // .created_at), html_url, status, conclusion} ]}]' 2>/dev/null) || mapped=""
      if [ -n "$mapped" ]; then raw="$mapped"; rc=0; source=workflow-runs; fi
    fi
  fi
  if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then
    last_reason="query-failed"
    prev_sig="$NO_READING"
  else
    dec_rc=0
    # `decide.sh` extracts and runs the marked `ci.verdict` block from
    # references/merge-mechanics.md §3 — the program `tests/merge-gate/test.sh` pins over
    # fixtures. Nothing is re-implemented here; a second copy of that reduction is precisely what
    # #208 removed.
    verdict_json=$(printf '%s' "$raw" | "$DECIDE" ci.verdict --json 2>/dev/null) || dec_rc=$?
    if [ "$dec_rc" -ne 0 ] || [ -z "$verdict_json" ]; then
      # The decision refusing is not the base branch's fault either — same treatment as a failed
      # query: retry, and if the deadline arrives first, say which of the two it was.
      last_reason="decision-failed"
      prev_sig="$NO_READING"
    else
      ci=$(printf '%s' "$verdict_json" | jq -r '.verdict // ""')
      # The reduced job set, order-independent: which jobs have posted, not what they say. That is
      # the question "has the graph finished appearing?" and it is the only thing compared.
      # Joined as JSON (`tojson`), not with a NUL: bash drops NUL bytes from a command
      # substitution — with a warning on every poll — so the separator never reached the
      # comparison and `["a b","c"]` read the same as `["a","b c"]`. A JSON array keeps every
      # boundary, whatever a job name contains.
      sig=$(printf '%s' "$verdict_json" | jq -c '[ .latest[].name ] | sort')
      case "$ci" in
        pending)
          last_reason="timeout" ;;
        no-ci)
          if [ "$SECONDS" -ge "$settle_deadline" ]; then break; fi
          last_reason="no-ci"; [ "$source" = workflow-runs ] && last_reason="no-run-yet" ;;
        clear)
          if [ "$sig" = "$prev_sig" ]; then break; fi
          last_reason="timeout" ;;
        *)
          break ;;
      esac
      prev_sig="$sig"
    fi
  fi
  # Reached only while the answer is still "not yet". Every branch that HAS an answer has broken
  # out above, so a clear or no-ci reading can never be lost to the deadline: SETTLE is clamped to
  # TIMEOUT, so the settle window always expires first.
  [ "$SECONDS" -lt "$deadline" ] || answer unverified "$last_reason"
  # A zero poll interval is legitimate (the suites use it); `sleep 0` returns immediately.
  sleep "$POLL_SECONDS"
done

# ---------------------------------------------------------------------------- 5. map the verdict
#
# `.latest` is the REDUCED set — one run per job, newest wins — so this is the set a filed bug
# should name, not the raw history attached to the sha.
runs=$(printf '%s' "$verdict_json" \
  | jq -c '[ .latest[] | {name, html_url, state} ]')

# A verdict read through the workflow-runs fallback says so (#479): `base-run` for a judged set,
# `no-run-yet` for an empty one — distinct from `no-ci` (check-runs answered, and had nothing).
src_reason=clear; [ "$source" = workflow-runs ] && src_reason=base-run
empty_reason=no-ci; [ "$source" = workflow-runs ] && empty_reason=no-run-yet
case "$ci" in
  clear)
    answer green "$src_reason" "$runs" ;;
  no-ci)
    answer unverified "$empty_reason" "$runs" ;;
  failed)
    # `ci.verdict` puts `cancelled` in `.failed` because pre-merge a cancelled check is a reason
    # NOT to merge. Post-merge it is a different fact: the merge already landed, and a cancelled
    # run recorded nothing about it. Split the two here rather than teaching the shared decision a
    # second, caller-specific meaning — the reduction has already dropped every SUPERSEDED
    # cancellation, so what reaches this point is only ever a job whose LATEST run was cancelled.
    n_real=$(printf '%s' "$verdict_json" \
      | jq '[ .failed[] | select(.state != "cancelled") ] | length')
    if [ "$n_real" -gt 0 ]; then
      [ "$source" = workflow-runs ] && answer red base-run "$runs"
      answer red failed "$runs"
    fi
    answer unverified cancelled "$runs" ;;
  needs-approval)
    # `ci.verdict`'s third, non-terminal word (#495): the run completed `action_required`, GitHub's
    # state for one a maintainer must approve. Post-merge that is the same shape as `cancelled` —
    # the merge landed and the run recorded nothing about it — so it is `unverified`, never red and
    # never green. What it is NOT is unexpected: it named itself `unexpected-ci-verdict:needs-approval`
    # here until #586, reporting an internal error string in place of the one condition on this
    # branch a human can actually clear, by approving the run (`skills/merge-pr/scripts/approve-runs.sh`).
    answer unverified needs-approval "$runs" ;;
  *)
    # `decide.sh` has already refused any word outside ci.verdict's declared vocabulary, so this
    # is unreachable through it — and is therefore written as a non-verdict rather than a guess.
    answer unverified "unexpected-ci-verdict:$ci" "$runs" ;;
esac
