#!/usr/bin/env bash
# Golden test for evals/behaviour/plan_adherence.py (#739) — how often a plan task's commit touches
# the files the task names.
#
# A rate is the easiest number in the world to get wrong quietly, so what this suite pins is not
# only the two verdicts but everything that must stay OUT of the rate, visibly:
#   * an adherent task and a non-adherent one                 -> the numerator and the denominator
#   * a task whose commit message matches no commit           -> unmatched, counted, not in the rate
#   * a task naming no file                                    -> no_files, counted, not in the rate
#   * a commit that touches ANOTHER task's file                -> not credited to the wrong task
#   * a PR with no issue, a plan with no task block            -> skipped, each with its reason
#   * a bundle in which nothing could be measured              -> NO RATE and exit 3, never "0%" or
#                                                                 "100%" (the #461 refusal)
#   * a file that is not a bundle                              -> exit 2
# `score` runs offline over fixture histories; `collect` (the `gh api` half) is not driven here.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $*"; exit 1; }
is() { [ "$2" = "$3" ] || fail "[$1] expected '$3', got '$2'"; echo "  ok: $1"; }

BENCH="$KIT/evals/behaviour/plan_adherence.py"
FIX="$KIT/tests/plan-adherence/fixtures"
[ -f "$BENCH" ] || fail "$BENCH missing"

echo "== a mixed history =="
rc=0; json=$(python3 -I "$BENCH" score "$FIX/mixed.json" --json) || rc=$?
is "exit 0 when something was measured" "$rc" 0
q() { jq -r "$1" <<<"$json"; }
is "the numerator: adherent tasks"                      "$(q .numerator)" 2
is "the denominator: tasks with a named file AND a matching commit" "$(q .denominator)" 4
is "the rate is the two over the four"                  "$(q .rate)" 0.5
is "an unmatched task is counted outside the rate"      "$(q .tasks_unmatched)" 1
is "a task naming no file is counted outside the rate"  "$(q .tasks_without_files)" 1
is "pull requests read / scored"                        "$(q '"\(.prs_read) \(.prs_scored)"')" "6 4"
verdict() { q ".per_pr[] | select(.pr == $1) | .tasks[] | select(.task == $2) | .verdict"; }
is "PR 1 task 1: its commit touches a named file (the (#N) suffix is not a difference)" "$(verdict 1 1)" adherent
is "PR 2 task 1: its commit touches none of them (a :10-20 anchor is not part of the path)" "$(verdict 2 1)" not_adherent
is "PR 3 task 1: no commit carries its message, though one touches its file" "$(verdict 3 1)" unmatched
is "PR 3 task 2: 'none expected.' names no file"        "$(verdict 3 2)" no_files
is "PR 4 task 1: a file the plan CREATES counts"        "$(verdict 4 1)" adherent
is "PR 4 task 2: its commit touched task 1's file, not its own" "$(verdict 4 2)" not_adherent
is "two pull requests skipped"                          "$(q '.skipped | length')" 2
is "skipped for naming no issue, by reason"             "$(q '.skipped[] | select(.pr == 5) | .reason | test("names no issue")')" true
is "skipped for a plan with no task block, by reason"   "$(q '.skipped[] | select(.pr == 6) | .reason | test("no `### Task N` block")')" true

echo "== the text report carries the denominator and every exclusion =="
text=$(python3 -I "$BENCH" score "$FIX/mixed.json")
for want in 'plan adherence: 2 / 4 tasks (50.0%)' '6 read, 4 scored, 2 skipped' \
            '1 with no matching commit, 1 naming no file' \
            'not adherent: PR #2 task 1' 'not adherent: PR #4 task 2' 'skipped: PR #5' 'skipped: PR #6'; do
  grep -qF -- "$want" <<<"$text" || { echo "$text"; fail "the text report lacks: $want"; }
done
echo "  ok: numerator / denominator, counts and every excluded item are named"

echo "== nothing measured is not a rate =="
rc=0; text=$(python3 -I "$BENCH" score "$FIX/unmeasured.json") || rc=$?
is "exit 3 when no task could be measured" "$rc" 3
grep -qF 'NO RATE' <<<"$text" || fail "an unmeasured bundle must say NO RATE, got: $text"
if grep -qE '[0-9.]+%' <<<"$text"; then fail "an unmeasured bundle printed a percentage: $text"; fi
rc=0; json=$(python3 -I "$BENCH" score "$FIX/unmeasured.json" --json) || rc=$?
is "the JSON rate is null, not 0"          "$(jq -r '.rate' <<<"$json")" null
is "and its denominator says why"          "$(jq -r '.denominator' <<<"$json")" 0
echo "  ok: no percentage is printed without a denominator"

echo "== refusals =="
rc=0; python3 -I "$BENCH" score "$FIX/not-a-bundle.json" >/dev/null 2>&1 || rc=$?
is "a file that is not a bundle exits 2" "$rc" 2
rc=0; python3 -I "$BENCH" score "$FIX/no-such-file.json" >/dev/null 2>&1 || rc=$?
is "a missing file exits 2" "$rc" 2

echo "== the published result is a measurement, and the README quotes it =="
# The bundle a result was scored from is not committed (it is the plans and file lists of every PR
# read, several hundred kB of public data): the result names the pull requests it read, so
# `collect --prs` rebuilds it. What is pinned here is that the result is whole and quoted as is.
RES="$KIT/evals/results/behaviour"
latest=""
for f in "$RES"/plan-adherence-*.json; do [ -f "$f" ] && latest="$f"; done
[ -n "$latest" ] || fail "no published result under evals/results/behaviour/"
jq -e '.metric == "plan-adherence" and (.denominator | type == "number" and . > 0)
       and (.numerator | type == "number") and (.rate | type == "number")
       and (.prs | type == "array" and length > 0) and (.prs | length) == .prs_read
       and (.prs_scored + (.skipped | length)) == .prs_read
       and (.merged_from | type == "string") and (.merged_to | type == "string")' "$latest" >/dev/null \
  || fail "$latest is not a whole result: a rate needs its numerator, its denominator, the pull requests read and every skip"
cell="$(jq -r '"\(.numerator) / \(.denominator)"' "$latest")"
readme=$(cat "$KIT/evals/README.md")
grep -qF -- "$cell" <<<"$readme" || fail "evals/README.md does not carry the published figure '$cell'"
grep -qF -- "$(basename "$latest")" <<<"$readme" || fail "evals/README.md does not link $(basename "$latest")"
unmatched="$(jq -r '.tasks_unmatched' "$latest")"
grep -qF -- "$unmatched with no matching commit" <<<"$readme" \
  || fail "evals/README.md quotes the rate without the $unmatched tasks left outside it"
echo "  ok: the published result is whole, and evals/README.md quotes its figure with what it leaves out"

echo "plan-adherence: OK"
