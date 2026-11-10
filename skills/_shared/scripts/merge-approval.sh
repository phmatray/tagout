#!/usr/bin/env bash
# merge-approval.sh — may an unattended run land this repository's PRs, or does every merge wait for
# a human? The program of the registered decision `merge.approval` (#740).
#
# It is not called by hand: `scripts/decide.sh merge.approval` runs it. The two places an agent
# merges with nobody watching — auto-dev's phase-2 dispatch and deliver-issue's Step 5 — pipe the
# committed profile into it before they dispatch a merge:
#
#   <kit>/skills/init/scripts/repo-profile.sh show | <kit>/scripts/decide.sh merge.approval
#
# Usage: merge-approval.sh < repo-profile.md
#   Reads the profile TEXT from stdin and looks at its `- **Merge approval:** <value>` bullet(s).
#   Prints ONE line of JSON: the verdict word and the rule that produced it.
#   Verdict words: land | hold
#
# THIS PROGRAM READS NO FILES AND RUNS NO COMMANDS — repo-profile.sh reads, this decides.
#
# Precedence, top to bottom — the FIRST matching rule decides:
#
#    #  when                                              verdict  rule name
#    1  the profile carries no such bullet                land     not-declared
#    2  every bullet says `unattended`                    land     unattended
#    3  every bullet says `owner`                         hold     owner-approval
#    4  anything else                                     hold     unrecognised-value
#
#   * RULE 4 IS THE POINT. This is a merge control, so a value it does not know fails CLOSED:
#     `owners`, `owner (ISO 8.32)`, the template's placeholder left unfilled, two bullets that
#     disagree — each holds and is named, where "any other value = unattended" would have merged
#     with no human and no warning. Backticks, case and trailing spaces are not differences.
#   * A CALLER THAT GETS NO VERDICT HOLDS TOO. decide.sh exits non-zero on empty input, and a
#     non-zero exit is not a `land`.
set -euo pipefail

profile=$(cat)

command -v jq > /dev/null 2>&1 || {
  echo "merge-approval: jq is missing — it is a \`required\` prerequisite in requirements.json" >&2
  exit 2
}

verdict=$(jq -Rsc '
  [ split("\n")[]
    | select(test("^\\s*-\\s*\\*\\*Merge approval:\\*\\*"))
    | sub("^\\s*-\\s*\\*\\*Merge approval:\\*\\*"; "")
    | gsub("`"; "") | gsub("^\\s+|\\s+$"; "") | ascii_downcase
  ] | unique as $declared
  | if   ($declared | length) == 0       then {verdict:"land", rule:"not-declared"}
    elif $declared == ["unattended"]     then {verdict:"land", rule:"unattended"}
    elif $declared == ["owner"]          then {verdict:"hold", rule:"owner-approval"}
    else                                      {verdict:"hold", rule:"unrecognised-value"}
    end
' <<<"$profile")

printf '%s\n' "$verdict"
