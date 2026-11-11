#!/usr/bin/env bash
# auto-dev wait-ci — block until each PR's gating checks are ALL final, then print the result table.
#
# Why this exists (see SKILL.md, "NEVER dispatch phase 2 while CI is pending"):
# a phase-2 merge worker is a background sub-agent whose final message is its report, and
# whose run ends with its turn (#314; before 2.0 it was a one-shot process, and the rule
# predates the substrate). Dispatched while CI is still pending, the only thing it can do
# is wait — so it reaches for a background watch ("I'll resume when the poll notifies me"),
# ends its turn, and its run is over mid-merge: what the supervisor receives is that
# deferral as the report, nothing resumes the agent, and the PR just stays open. That is
# a dispatch-timing bug, not a prompt-wording one: dispatching at "PR ready" *guarantees*
# the worker meets a pending run. Five worker sessions were lost this way in a single
# .NET run with Testcontainers (Build & Test there takes 16-20 min: it pulls ~4.4 GB of
# SQL Server + Oracle images) before the wait was moved up to the supervisor.
#
# So: the SUPERVISOR runs this in the background, and only once it returns does it
# dispatch phase 2 — with the finished check table pasted into the prompt, so the worker
# has nothing left to wait for. Measured: ~11 min of idle-and-die -> 17-55 s clean merges.
#
# WHAT COUNTS AS "DONE" (#188). This used to model a repo as having exactly ONE gating check,
# picked by a hardcoded default name (`CHECK="Build & Test"`) and matched with `grep -F "$CHECK"`
# against `gh pr checks`'s plain-text table. That is wrong for a repo with more than one
# independently-gating check (this kit's own `kit` + `title-gate`, added by #57): no single name
# can be both, so setting CHECK to either one false-greens past the other, and leaving CHECK at
# the default matches nothing at all on such a repo — `state` came back empty, was folded into
# "unknown", and "unknown" polled to MAX_POLLS and exited 1 after up to an hour without ever
# returning a verdict. A guard that stalls or half-fires is worse than one that is obviously
# absent, because it looks like protection.
#
# So this waits on EVERY check `scripts/tracker.sh pr-checks <pr>` reports (#752: the verb, so the
# wait runs on any tracker the profile names; on GitHub it is `gh pr checks <pr> --json
# name,state,bucket`), with no per-repo CHECK override required for correctness. `bucket` is the
# contract's classification of a check's state into `pass`/`fail`/`pending`/`skipping`/`cancel` —
# gh's OWN on GitHub (pinned against `gh pr checks --help` and a real PR — see
# tests/wait-ci/test.sh's header), each backend's mapping elsewhere: a check is final once its
# bucket leaves `pending`, matching this script's pre-existing all_final semantics one level down.
# Reading `bucket` rather than re-deriving it from raw `state` strings (QUEUED, IN_PROGRESS,
# STALE, ACTION_REQUIRED, whatever a host adds next) means this script never has to track a host's
# state vocabulary — that classification is exactly what the field exists for.
#
# Why JSON + jq rather than the old plain-table parse: that table is TAB-separated and check
# names can contain spaces ("Build & Test"), a column-alignment ambiguity a careless edit could
# get wrong again. The verb names each field, so there is nothing left to misalign no matter how
# a check is named. `jq` is a `required` prerequisite (requirements.json).
#
# FINAL IS NECESSARY BUT NOT SUFFICIENT (#413). "Every reported check left `pending`" only holds if
# the reported set is complete — and GitHub creates a check run when its job STARTS, not when the
# workflow is queued. A `needs:`-gated aggregate job (e.g. a `coverage-gate` that `needs:` two test
# jobs and reports under its own name) does not exist at all until its dependencies finish, so a
# poll landing in that window sees every check it CAN see as final and misses the one that matters
# most — aggregation is exactly what makes a check worth requiring in the first place. So this also
# requires the check SET to be stable: on top of "final", the SET OF CHECK NAMES must match the
# previous poll's — not just the count, so a same-size swap (one check replaced by a different one
# within one poll) can't slip past as "stable" either — before returning 0. That costs exactly one
# extra `POLL_SECONDS` on every run, including one that was already all-final on its first poll —
# cheap against a wait that is minutes long, and not something to "optimise away", because that
# confirmation poll is the only thing standing between this script and the false green a
# late-materializing required check would otherwise produce.
#
# Usage:
#   scripts/wait-ci.sh <pr> [pr...]                # waits on every check the tracker reports
#   CHECK="kit,title-gate" scripts/wait-ci.sh 42    # optional allow-list: ignore any check whose
#                                                    # name is not in this comma-separated list —
#                                                    # for a repo that deliberately wants to skip
#                                                    # one known non-gating check, not the default
#
# Exit 0 once every (filtered) check has left the `pending` bucket for every PR; 2 immediately if
# a PR reports zero checks for MAX_ZERO_POLLS consecutive polls (nothing to wait on — most likely
# no CI configured on this branch, not worth a silent hour-long stall); 1 on timeout (MAX_POLLS
# reached with at least one check still pending).
#
# GENUINE zero checks vs a TRANSIENT host failure (rate limit, network blip, an auth hiccup) must
# not be confused: counting a failure toward MAX_ZERO_POLLS would let a couple of unlucky API calls
# produce the same wrong "no CI configured" verdict this script exists to avoid, after as little as
# ~2 polls instead of a real MAX_POLLS timeout. The contract keeps them apart: `pr-checks` prints
# `[]` and exits 0 for a genuine zero, and exits non-zero only on a failed read. (On GitHub that is
# github.sh's concern since #752 — gh FAILS a `--json` call with "no checks reported on the
# '<branch>' branch" when zero checks exist, measured on PR #291 of this repo, and the backend turns
# exactly that wording into `[]`.) So `[]` is a zero-checks poll (counts toward MAX_ZERO_POLLS), and
# ANY non-zero exit is transient, whatever its stderr says — logged, not counted either way, and the
# poll just continues, rather than giving up early with a wrong verdict.

set -uo pipefail

# KIT_ROOT through symlinks, the way skills/merge-pr/scripts/base-run-followup.sh does it: a plugin
# install reaches this file by link, and `pwd -P` alone canonicalizes the directory, not the link,
# so it would look for scripts/tracker.sh beside the LINK. No `readlink -f`: macOS lacks it.
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
TRACKER="$KIT_ROOT/scripts/tracker.sh"

command -v jq > /dev/null 2>&1 || {
  echo "wait-ci: jq is missing — it is a \`required\` prerequisite in requirements.json" >&2
  exit 2
}

CHECK="${CHECK:-}"                     # optional comma-separated allow-list; empty = every check
POLL_SECONDS="${POLL_SECONDS:-60}"
MAX_POLLS="${MAX_POLLS:-60}"           # 60 x 60s = up to 60 min
MAX_ZERO_POLLS="${MAX_ZERO_POLLS:-2}"  # consecutive zero-check polls before failing fast (exit 2)

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <pr> [pr...]   (env: CHECK, POLL_SECONDS, MAX_POLLS, MAX_ZERO_POLLS)" >&2
  exit 2
fi

PRS=("$@")
ZERO_POLLS=()
for _pr in "${PRS[@]}"; do ZERO_POLLS+=(0); done
# Previous poll's (possibly CHECK-filtered) check count and name-set per PR; count -1 = no real
# poll yet. A `needs:`-gated aggregate check does not exist until its dependencies finish, so
# "final" alone (no check pending) is not enough — the set itself must also have stopped changing
# (#413). Comparing NAMES rather than the bare count also catches a same-size swap — one check
# replaced by a different one within a single poll, net count unchanged — which a count-only
# comparison would misread as stable (found by review on the PR that introduced this).
PREV_COUNT=()
PREV_NAMES=()
for _pr in "${PRS[@]}"; do PREV_COUNT+=(-1); PREV_NAMES+=(''); done

# Captures each `pr-checks` call's stderr for the transient-poll log line (see the header). Guarded
# the way survey.sh/guarded-push.sh capture stderr elsewhere in this kit.
GH_ERR_FILE=""
if GH_ERR_FILE="$(mktemp 2>/dev/null)"; then
  trap 'rm -f "$GH_ERR_FILE"' EXIT
fi

# One jq call per PR per poll: applies the optional CHECK allow-list, then reduces the (possibly
# filtered) checks array to four tab-separated fields — how many checks, how many of those are
# still pending, a sorted "name,name,..." signature (identity only, no state — used for the
# stability comparison so a state change alone, e.g. IN_PROGRESS -> SUCCESS, never counts as a
# change of SET), and a "name:state,..." line for the human-readable poll log.
JQ_SUMMARY='
  ( ($allow | if . == "" then [] else (split(",") | map(gsub("^[ \t]+|[ \t]+$";""))) end) ) as $names
  | (if ($names | length) > 0 then map(select(.name as $n | $names | index($n) != null)) else . end) as $f
  | { count: ($f | length),
      pending: ([$f[] | select(.bucket == "pending")] | length),
      namesig: ([$f[] | .name] | sort | join(",")),
      line: ([$f[] | "\(.name):\(.state)"] | join(",")) }
  | "\(.count)\t\(.pending)\t\(.namesig)\t\(.line)"
'

for i in $(seq 1 "$MAX_POLLS"); do
  all_final=1
  all_stable=1
  line=""
  idx=0
  for pr in "${PRS[@]}"; do
    transient=0
    json=$("$TRACKER" pr-checks "$pr" 2>"${GH_ERR_FILE:-/dev/null}") || transient=1
    gh_err=''
    [ -n "$GH_ERR_FILE" ] && gh_err=$(cat -- "$GH_ERR_FILE" 2>/dev/null)
    [ -n "$json" ] || json='[]'

    # Any non-zero exit is a failed read, never "zero checks" — the verb prints `[]` for that.
    if [ "$transient" -eq 1 ]; then
      # Neither confirms nor disconfirms "zero checks": ZERO_POLLS is left exactly as it was, so a
      # blip can't manufacture progress toward MAX_ZERO_POLLS, and can't erase real progress either.
      line="${line} PR${pr}=[gh error, retrying: ${gh_err:-<no output>}]"
      all_final=0
      all_stable=0
      idx=$((idx + 1))
      continue
    fi

    summary=$(printf '%s' "$json" | jq -r --arg allow "$CHECK" "$JQ_SUMMARY" 2>/dev/null) \
      || summary=$'0\t0\t\t'
    count=0; pending=0; namesig=''; checkline=''
    IFS=$'\t' read -r count pending namesig checkline <<< "$summary"

    if [ "${count:-0}" -eq 0 ]; then
      ZERO_POLLS[$idx]=$(( ZERO_POLLS[idx] + 1 ))
      line="${line} PR${pr}=[no checks found]"
      all_final=0
    else
      ZERO_POLLS[$idx]=0
      line="${line} PR${pr}=[${checkline}]"
      [ "${pending:-0}" -eq 0 ] || all_final=0
    fi

    # Stability: this poll's check-name SET must equal the PREVIOUS poll's for this PR — not just
    # "not smaller" (a re-run/cancelled check can shrink the set) and not just "same count" (a
    # same-size swap — one check replaced by a different one within one poll — has an unchanged
    # count but a changed set). Either direction costs one extra poll rather than a false green.
    # PREV_COUNT's -1 sentinel (no prior real poll yet) never matches, so the very first poll can
    # never satisfy stability on its own, however its name-set compares.
    if [ "${PREV_COUNT[$idx]}" -eq -1 ] || [ "${PREV_NAMES[$idx]}" != "$namesig" ]; then
      all_stable=0
    fi
    PREV_COUNT[$idx]="${count:-0}"
    PREV_NAMES[$idx]="$namesig"
    idx=$((idx + 1))
  done

  echo "[$(date -u +%T)Z] poll ${i}:${line}"

  idx=0
  for pr in "${PRS[@]}"; do
    if [ "${ZERO_POLLS[$idx]}" -ge "$MAX_ZERO_POLLS" ]; then
      echo "wait-ci: no checks found for PR ${pr} after ${MAX_ZERO_POLLS} poll(s) — verify CI is configured on this PR/branch" >&2
      exit 2
    fi
    idx=$((idx + 1))
  done

  if [ "$all_final" -eq 1 ] && [ "$all_stable" -eq 1 ]; then
    if [ -n "$CHECK" ]; then
      echo "=== ALL CHECKS IN ALLOW-LIST FINAL (CHECK=${CHECK}) ==="
    else
      echo "=== ALL GATING CHECKS FINAL ==="
    fi
    for pr in "${PRS[@]}"; do
      echo "--- PR ${pr} ---"
      "$TRACKER" pr-checks "$pr" 2>/dev/null | jq -r '.[] | "\(.name)\t\(.state)"' 2>/dev/null | head -10
      "$TRACKER" pr-view "$pr" 2>/dev/null \
        | jq -r '"  state=\(.state) draft=\(.isDraft)"' 2>/dev/null
    done
    exit 0
  fi

  sleep "$POLL_SECONDS"
done

echo "=== TIMEOUT after ${MAX_POLLS} polls (~$((MAX_POLLS * POLL_SECONDS / 60)) min) ==="
exit 1
