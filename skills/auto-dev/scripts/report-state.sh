#!/usr/bin/env bash
# report-state.sh — turn a worker's final report line into the state `autodev.report` decides on.
#
# A worker's report is one line of ` | `-separated `KEY: value` fields (the grammars are in
# `commands/auto-dev-worker.md` and `commands/auto-dev-merge.md`). The supervisor used to read that
# line by eye and pick one of a dozen prose bullets. This script is the reading half, done by a
# program: it parses the line, adds what only the fleet knows (the worker's tier, and from
# `fleet-counters.sh` how often this issue was resumed and whether its escalation is spent), and
# prints one JSON object. It DECIDES NOTHING — `report-verdict.sh` does, through
# `scripts/decide.sh autodev.report`.
#
# Usage: report-state.sh <state-file> --tier small|mid|top ['<report text>']
#   <state-file>  the fleet's pinned state file (auto-dev Step 2); the counters live beside it.
#   --tier        the tier the reporting worker ran on (recorded in the state file at dispatch).
#   <report text> the worker's final message; read from stdin when omitted. It may be several
#                 lines: the LAST line carrying both `ISSUE:` and `STATUS:` is the report.
#
# Output: {parsed, phase, issue, pr, status, signal, blocked_by, blockers, worktree, tier,
#          escalated, resumes}. `parsed` is false when no line carries a digits-only ISSUE and a
#          STATUS from the grammar — the decision answers `reconcile` for that, so a mangled
#          report is never guessed at.
#
# The report is TEXT A WORKER WROTE, some of it quoted from an issue anyone could open. Nothing in
# it is executed or followed here: fields are matched against fixed spellings, and DETAIL is read
# only for the three refusal signatures the command files spell out by name.
#
# Exit codes:
#   0  a state was printed (including `parsed: false`)
#   2  REFUSED — bad usage, or the counters could not be read
set -euo pipefail

die() { printf 'report-state: REFUSED — %s\n' "$1" >&2; exit 2; }

command -v jq > /dev/null 2>&1 || die "jq is missing — it is a \`required\` prerequisite in requirements.json"

HERE="$(cd "$(dirname "$0")" && pwd)"

[ "$#" -ge 3 ] || die "usage: report-state.sh <state-file> --tier small|mid|top ['<report text>']"
STATE_FILE="$1"
[ "$2" = "--tier" ] || die "the second argument is --tier, got '$2'"
TIER="$3"
case "$TIER" in small|mid|top) ;; *) die "--tier is small, mid or top, got '$TIER'" ;; esac
shift 3
if [ "$#" -ge 1 ]; then TEXT="$1"; else TEXT=$(cat); fi

parsed=$(printf '%s\n' "$TEXT" | jq -Rsc '
  def field($segs; $k):
    ([ $segs[] | select(startswith($k + ":")) | ltrimstr($k + ":") | gsub("^\\s+|\\s+$"; "") ] | first) // null;
  [ split("\n")[] | gsub("`"; "") | select(test("ISSUE:") and test("STATUS:")) ] | last as $line
  | if $line == null then {parsed: false}
    else
      ($line | split("|") | map(gsub("^\\s+|\\s+$"; ""))) as $segs
      | field($segs; "ISSUE") as $issue
      | field($segs; "STATUS") as $status
      | (field($segs; "DETAIL") // "") as $detail
      | (field($segs; "BLOCKED_BY") // "none") as $by
      | field($segs; "WORKTREE") as $wt
      | (field($segs; "PR") // "none") as $pr
      | (if ($segs | index("PHASE1")) != null then 1 else 2 end) as $phase
      | if (($issue // "") | test("^[0-9]+$") | not)
           or ((["READY","PARTIAL","BLOCKED","FAILED","MERGED"] | index($status // "")) == null)
        then {parsed: false}
        else {
          parsed: true,
          phase: $phase,
          issue: $issue,
          pr: (if ($pr | test("^[0-9]+$")) then $pr else null end),
          status: $status,
          signal: (if   ($detail | startswith("worker-toplevel guard:")) then "worker-toplevel-guard"
                   elif ($detail | startswith("branch-held guard:"))     then "branch-held-guard"
                   elif ($detail | test("^pushed [0-9a-f]+, CI restarted")) then "ci-restarted"
                   else "none" end),
          blocked_by: (if   $by == "replan"                     then "replan"
                       elif ($by | test("^#[0-9]+(,\\s*#[0-9]+)*$")) then "issues"
                       else "none" end),
          blockers: (if ($by | test("^#[0-9]+(,\\s*#[0-9]+)*$")) then ($by | split(",") | map(gsub("\\s"; ""))) else [] end),
          worktree: (if $wt == null then "absent"
                     elif ($wt | ascii_downcase | test("^cleaned up\\.?$")) then "clean"
                     else "leftover" end)
        }
        end
    end')

if [ "$(printf '%s' "$parsed" | jq -r '.parsed')" != true ]; then
  printf '%s\n' "$parsed" | jq -c --arg t "$TIER" '. + {tier: $t}'
  exit 0
fi

issue=$(printf '%s' "$parsed" | jq -r '.issue')
counts=$("$HERE/fleet-counters.sh" "$STATE_FILE" issue "$issue") \
  || die "could not read the counters for #$issue — fleet-counters.sh said why, above"

printf '%s' "$parsed" | jq -c --arg t "$TIER" --argjson c "$counts" '. + {tier: $t} + $c'
