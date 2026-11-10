#!/usr/bin/env bash
# report-verdict.sh — what does the supervisor do with this worker's report? The program of the
# registered decision `autodev.report`.
#
# It is not called by hand: `scripts/decide.sh autodev.report` runs it, logs the branch that fired,
# and refuses a word outside the vocabulary declared in `decisions/registry.json`. auto-dev's Step 4
# reaches it by piping `report-state.sh` — which parses the worker's final line and reads this
# fleet's counters — into it.
#
# Usage: report-verdict.sh < state.json
#   Reads the object `report-state.sh` prints — {parsed, phase, issue, pr, status, signal,
#   blocked_by, blockers, worktree, tier, escalated, resumes} — from stdin. Prints ONE line of JSON
#   on stdout: the verdict word, and the name of the precedence rule that produced it.
#   Verdict words: reconcile | redispatch | release-branch | wait-ci | refill | refill-sweep |
#                  resume | hold-prereq | hold-replan | escalate | retire
#
# THIS PROGRAM READS NO FILES AND RUNS NO COMMANDS. It sees only the state it is handed, so
# `tests/report-verdict/test.sh` pins every branch with a fixture. It also never asks GitHub: a
# verdict says what the REPORT calls for, and Step 4 still checks a `MERGED` against the real merge
# state before acting on `refill`.
#
# Precedence, top to bottom — the FIRST matching rule decides:
#
#    #  when                                                   verdict         rule name
#    1  no report line could be parsed                         reconcile       unparseable-report
#    2  the status does not belong to the phase that sent it   reconcile       status-outside-phase
#    3  BLOCKED, naming the worker-toplevel guard              redispatch      isolation-defect
#    4  BLOCKED, naming the branch-held guard                  release-branch  branch-held
#    5  BLOCKED, "pushed <sha>, CI restarted"                  wait-ci         pushed-ci-restarted
#    6  MERGED, worktree reported clean                        refill          merged-clean
#    7  MERGED, anything else in WORKTREE (or no field)        refill-sweep    merged-leftover
#    8  READY                                                  wait-ci         ready-pr
#    9  PARTIAL, fewer resumes so far than the cap             resume          partial-within-cap
#   10  PARTIAL                                                retire          partial-cap-reached
#   11  BLOCKED, BLOCKED_BY names issues                       hold-prereq     blocked-by-issues
#   12  BLOCKED, BLOCKED_BY: replan                            hold-replan     blocked-by-replan
#   13  BLOCKED/FAILED, below the top tier, never escalated    escalate        lower-tier-first-failure
#   14  anything else                                          retire          blocked-after-escalation
#
# The orderings, decided once here rather than re-derived by whoever reads the prose next:
#
#   * THE THREE NAMED SIGNALS (3-5) OUTRANK EVERYTHING A BLOCKED REPORT CAN OTHERWISE MEAN. Each
#     is a dispatch defect or the push-and-land split reporting itself — never something wrong with
#     the issue — so none may reach rule 13 and spend the fleet's one escalation on a stronger
#     model that would meet the same shared tree, the same held branch or the same pending CI.
#   * RULES 11-12 SIT ABOVE 13 for the same reason: a stronger model reading the same open
#     prerequisite or the same disproven plan changes nothing.
#   * RULE 7 IS THE DEFAULT FOR A MERGE, NOT RULE 6. A missing or free-text WORKTREE field is
#     non-clean, never evidence of success; the cost of being wrong in this direction is one line
#     under `## Needs manual sweep`.
#   * THE RESUME CAP (9-10) LIVES HERE AND NOWHERE ELSE. Rule 10 retires without escalating: a
#     budget exhaustion is a length failure, not a "the model was too weak" one.
#   * RULE 13 SAYS THE ESCALATION IS AVAILABLE, not that it is warranted. Step 4 still declines it
#     for a genuine hard blocker (an un-mergeable conflict, a missing approval, no plan).
set -euo pipefail

json=$(cat)

command -v jq > /dev/null 2>&1 || {
  echo "report-verdict: jq is missing — it is a \`required\` prerequisite in requirements.json" >&2
  exit 2
}

verdict=$(printf '%s' "$json" | jq -c '
  (.status == "BLOCKED") as $blocked
  | (.status == "BLOCKED" or .status == "FAILED") as $stopped
  | if   .parsed != true                                    then {verdict:"reconcile",      rule:"unparseable-report"}
    elif (.phase == 1 and .status == "MERGED")
      or (.phase == 2 and (.status == "READY" or .status == "PARTIAL"))
                                                            then {verdict:"reconcile",      rule:"status-outside-phase"}
    elif $blocked and .signal == "worker-toplevel-guard"    then {verdict:"redispatch",     rule:"isolation-defect"}
    elif $blocked and .signal == "branch-held-guard"        then {verdict:"release-branch", rule:"branch-held"}
    elif $blocked and .signal == "ci-restarted"             then {verdict:"wait-ci",        rule:"pushed-ci-restarted"}
    elif .status == "MERGED" and .worktree == "clean"       then {verdict:"refill",         rule:"merged-clean"}
    elif .status == "MERGED"                                then {verdict:"refill-sweep",   rule:"merged-leftover"}
    elif .status == "READY"                                 then {verdict:"wait-ci",        rule:"ready-pr"}
    elif .status == "PARTIAL" and (.resumes < 3)            then {verdict:"resume",         rule:"partial-within-cap"}
    elif .status == "PARTIAL"                               then {verdict:"retire",         rule:"partial-cap-reached"}
    elif $blocked and .blocked_by == "issues"               then {verdict:"hold-prereq",    rule:"blocked-by-issues"}
    elif $blocked and .blocked_by == "replan"               then {verdict:"hold-replan",    rule:"blocked-by-replan"}
    elif $stopped and .tier != "top" and .escalated != true then {verdict:"escalate",       rule:"lower-tier-first-failure"}
    else                                                         {verdict:"retire",         rule:"blocked-after-escalation"}
    end
')

printf '%s\n' "$verdict"
