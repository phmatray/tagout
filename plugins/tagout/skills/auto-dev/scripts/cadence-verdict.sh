#!/usr/bin/env bash
# cadence-verdict.sh — is the queue due a fresh survey? The program of the registered decision
# `autodev.cadence`.
#
# It is not called by hand: `scripts/decide.sh autodev.cadence` runs it. auto-dev's Step 4 reaches
# it by piping `fleet-counters.sh <state-file> state` into it after every merge it records.
#
# Usage: cadence-verdict.sh < state.json
#   Reads {merges, merges_at_survey, blocking_pending} from stdin. Prints ONE line of JSON: the
#   verdict word and the rule that produced it.
#   Verdict words: resurvey | steady
#
# THIS PROGRAM READS NO FILES AND RUNS NO COMMANDS — `fleet-counters.sh` counts, this decides.
#
# Precedence, top to bottom — the FIRST matching rule decides:
#
#    #  when                                                  verdict   rule name
#    1  a merged issue was blocking others since the survey   resurvey  blocker-landed
#    2  five or more merges since the survey                  resurvey  merge-cadence
#    3  anything else                                         steady    not-due
#
#   * RULE 1 OUTRANKS THE COUNT: the blockees entered the frontier the moment their blocker landed,
#     and waiting out the counter leaves them held and slots idle.
#   * THE CADENCE INTEGER LIVES HERE AND NOWHERE ELSE. It is a floor, not a ceiling: Step 4 may
#     survey sooner (refills clustering in one area, a queue that looks empty), never later.
set -euo pipefail

json=$(cat)

command -v jq > /dev/null 2>&1 || {
  echo "cadence-verdict: jq is missing — it is a \`required\` prerequisite in requirements.json" >&2
  exit 2
}

verdict=$(printf '%s' "$json" | jq -c '
  if   .blocking_pending == true                then {verdict:"resurvey", rule:"blocker-landed"}
  elif (.merges - .merges_at_survey) >= 5       then {verdict:"resurvey", rule:"merge-cadence"}
  else                                               {verdict:"steady",   rule:"not-due"}
  end
')

printf '%s\n' "$verdict"
