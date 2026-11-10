#!/usr/bin/env bash
# fleet-counters.sh — the fleet's counts, kept by a program instead of by the supervisor's memory.
#
# auto-dev's supervisor used to carry four tallies in its head and in free-form lines of the state
# file: merges since the last survey, PARTIAL resumes per issue, the streak of `unverified` base
# verdicts, and issues filed against issues closed. Each one feeds a threshold, and a tally kept by
# a model does not survive a compaction: the count that comes back is the one the summary happened
# to keep. This script is the one writer of those numbers. It COUNTS and REPORTS; the two
# control-flow choices that read its numbers are registered decisions with programs of their own
# (`autodev.report`, `autodev.cadence`).
#
# Usage: fleet-counters.sh <state-file> <command> [args]
#   <state-file> is the fleet's pinned state file (auto-dev Step 2). The counts live beside it, in
#   <state-file minus .md>.counters.json, so they share its key and its lifetime.
#
#   merged <issue> [--blocking]  record a landed issue (idempotent per issue). --blocking when its
#                                survey row carried `blocking=`. Prints `merges: <n>`.
#   resumed <issue>              record one PARTIAL resume. Prints `PARTIAL ×<k>`.
#   escalated <issue>            record that the issue's one tier escalation has been spent.
#   filed <issue> [<issue>...]   record issues the fleet filed (idempotent per issue).
#   base '<verdict line>'        record a TRUSTED base verdict — `green (…)`, `RED (…)` or
#                                `unverified (…)`, the grammar `base-run-verdict.sh --report-line`
#                                prints. Anything else is refused (exit 2): re-derive it first.
#                                Prints the `base health unchecked …` line once the streak calls
#                                for one, nothing otherwise.
#   surveyed                     record that the queue was just re-surveyed.
#   state                        print {merges, merges_at_survey, blocking_pending} — the input of
#                                `decide.sh autodev.cadence`.
#   issue <issue>                print {resumes, escalated} for one issue — read by report-state.sh.
#   summary                      print the lines Step 4's reports and Step 6's recap quote.
#   clear                        delete the counts (Step 6, with the state file).
#
# Exit codes:
#   0  done
#   2  REFUSED — bad usage, an issue that is not digits, an untrusted base line, or a counters file
#      that is not the JSON this script wrote. A corrupt file is never silently reset to zero: a
#      fleet that forgets its merge count re-surveys late and resumes a stuck issue forever.
set -euo pipefail

die() { printf 'fleet-counters: REFUSED — %s\n' "$1" >&2; exit 2; }

command -v jq > /dev/null 2>&1 || die "jq is missing — it is a \`required\` prerequisite in requirements.json"

[ "$#" -ge 2 ] || die "usage: fleet-counters.sh <state-file> <command> [args] — see the header of this script"
STATE_FILE="$1"; CMD="$2"; shift 2
case "$STATE_FILE" in
  *.md) ;;
  *) die "the first argument is the fleet's state file and ends in .md, got '$STATE_FILE'" ;;
esac
COUNTERS="${STATE_FILE%.md}.counters.json"

EMPTY='{"v":1,"merged":[],"merges_at_survey":0,"blocking_pending":false,"filed":[],"resumes":{},"escalated":[],"unverified_streak":0,"unverified_reason":""}'

load() {
  if [ ! -e "$COUNTERS" ]; then printf '%s\n' "$EMPTY"; return 0; fi
  jq -ce 'select(type == "object" and .v == 1 and (.merged | type) == "array")' "$COUNTERS" 2>/dev/null \
    || die "$COUNTERS is not a counters file this script wrote — inspect it; it is never reset silently"
}

save() {
  mkdir -p "$(dirname "$COUNTERS")"
  printf '%s\n' "$1" > "$COUNTERS.tmp"
  mv "$COUNTERS.tmp" "$COUNTERS"
}

need_issue() {
  case "${1:-}" in
    ''|*[!0-9]*) die "'${1:-}' is not an issue number (digits only, no #)" ;;
  esac
}

# The report line both `base` and `summary` print. One spelling, so the board and the recap agree.
base_health_line() {
  printf '%s' "$1" | jq -r '
    if .unverified_streak >= 3
    then "base health unchecked for \(.unverified_streak) merges (\(.unverified_reason))"
    else empty end'
}

case "$CMD" in
  merged)
    need_issue "${1:-}"; blocking=false
    case "${2:-}" in
      --blocking) blocking=true ;;
      '') ;;
      *) die "merged takes an issue and an optional --blocking, got '$2'" ;;
    esac
    new=$(load | jq -c --arg i "$1" --argjson b "$blocking" '
      .merged = (.merged + [$i] | unique)
      | .blocking_pending = (.blocking_pending or $b)
      | .resumes |= del(.[$i])
      | .escalated -= [$i]')
    save "$new"
    printf '%s' "$new" | jq -r '"merges: \(.merged | length)"'
    ;;
  resumed)
    need_issue "${1:-}"
    new=$(load | jq -c --arg i "$1" '.resumes[$i] = ((.resumes[$i] // 0) + 1)')
    save "$new"
    printf '%s' "$new" | jq -r --arg i "$1" '"PARTIAL ×\(.resumes[$i])"'
    ;;
  escalated)
    need_issue "${1:-}"
    save "$(load | jq -c --arg i "$1" '.escalated = (.escalated + [$i] | unique)')"
    ;;
  filed)
    [ "$#" -ge 1 ] || die "filed takes at least one issue number"
    for n in "$@"; do need_issue "$n"; done
    save "$(load | jq -c '.filed = (.filed + $ARGS.positional | unique)' --args "$@")"
    ;;
  base)
    line="${1:-}"
    printf '%s\n' "$line" | grep -Eq '^(green|RED|unverified) \([a-z-]+\)$' \
      || die "'$line' is not a base verdict line — re-derive it with base-run-verdict.sh --report-line, then record that"
    word="${line%% *}"
    reason="${line#*\(}"; reason="${reason%\)}"
    if [ "$word" = unverified ]; then
      new=$(load | jq -c --arg r "$reason" '.unverified_streak += 1 | .unverified_reason = $r')
    else
      new=$(load | jq -c '.unverified_streak = 0 | .unverified_reason = ""')
    fi
    save "$new"
    base_health_line "$new"
    ;;
  surveyed)
    save "$(load | jq -c '.merges_at_survey = (.merged | length) | .blocking_pending = false')"
    ;;
  state)
    load | jq -c '{merges: (.merged | length), merges_at_survey, blocking_pending}'
    ;;
  issue)
    need_issue "${1:-}"
    load | jq -c --arg i "$1" '{resumes: (.resumes[$i] // 0), escalated: ((.escalated | index($i)) != null)}'
    ;;
  summary)
    cur=$(load)
    printf '%s' "$cur" | jq -r '
      (.merged | length) as $m | (.filed | length) as $f
      | "merged: \($m) · filed by the fleet: \($f) · merges since the last survey: \($m - .merges_at_survey)",
        (if $f >= $m and $f > 0 then "\($m) merged, \($f) filed — the queue is not draining" else empty end)'
    base_health_line "$cur"
    ;;
  clear)
    rm -f "$COUNTERS" "$COUNTERS.tmp"
    ;;
  *)
    die "unknown command '$CMD' — see the header of this script"
    ;;
esac
