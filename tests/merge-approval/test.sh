#!/usr/bin/env bash
# Golden test for skills/_shared/scripts/merge-approval.sh, the program of the registered decision
# `merge.approval` (#740): may an unattended run land this repository's PRs?
#
# The case this suite exists for is the REFUSAL. A merge control that reads "any value I do not
# know" as "merge unattended" lets `Owner`, `owners`, `owner (ISO 8.32)` or the template's
# placeholder land every PR with no human and no warning. So besides the two spellings that land
# and the one that holds, this suite drives every near-miss and asserts each one HOLDS, by name.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $*"; exit 1; }

DECIDE="$KIT/scripts/decide.sh"
[ -x "$KIT/skills/_shared/scripts/merge-approval.sh" ] || fail "merge-approval.sh missing or not executable"

scratch=$(kit_scratch)
export KIT_DECISION_LOG="$scratch/decision-events.jsonl"

# $1 name  $2 expected "verdict rule"  $3 the profile's Integration style bullets
is() {
  local got
  got=$(printf '## Integration style\n- **Merge mode:** squash\n%s\n- **Branch naming:** x\n' "$3" \
        | "$DECIDE" merge.approval --json | jq -r '"\(.verdict) \(.rule)"') || fail "[$1] decide.sh failed"
  [ "$got" = "$2" ] || fail "[$1] expected '$2', got '$got'"
  echo "  ok: $1 -> $got"
}

echo "== the two answers that land =="
is "no bullet at all (every profile written before #740)" "land not-declared" ""
is "unattended"                         "land unattended" '- **Merge approval:** unattended'
is "unattended, backticked"             "land unattended" '- **Merge approval:** `unattended`'

echo "== owner holds, however it is spelled =="
is "owner"                              "hold owner-approval" '- **Merge approval:** owner'
is "Owner (case is not a difference)"   "hold owner-approval" '- **Merge approval:** Owner'
is "owner, backticked, trailing spaces" "hold owner-approval" '- **Merge approval:** `owner`   '
is "an indented bullet"                 "hold owner-approval" '  - **Merge approval:** owner'

echo "== anything else HOLDS — a merge control does not guess =="
is "a plural"                           "hold unrecognised-value" '- **Merge approval:** owners'
is "a value with a note after it"       "hold unrecognised-value" '- **Merge approval:** owner (ISO 8.32)'
is "the template placeholder, unfilled" "hold unrecognised-value" '- **Merge approval:** <unattended | owner> _(optional)_'
is "an empty value"                     "hold unrecognised-value" '- **Merge approval:**'
is "a synonym"                          "hold unrecognised-value" '- **Merge approval:** manual'
is "two bullets that disagree"          "hold unrecognised-value" "$(printf -- '- **Merge approval:** unattended\n- **Merge approval:** owner')"

echo "== no verdict is not a land =="
rc=0; out=$("$DECIDE" merge.approval </dev/null 2>/dev/null) || rc=$?
[ "$rc" -ne 0 ] || fail "empty input must exit non-zero, got 0 with: $out"
[ -z "$out" ] || fail "empty input must print no verdict, got: $out"
echo "  ok: empty input -> exit $rc, no verdict"

echo "== the shipped template's own bullet holds until the owner fills it =="
tpl_line=$(grep -F '**Merge approval:**' "$KIT/skills/init/references/profile-template.md") \
  || fail "the profile template has no **Merge approval:** bullet"
is "the template line, verbatim" "hold unrecognised-value" "$tpl_line"

echo "== this repository's own profile lands (it carries no bullet) =="
got=$("$KIT/skills/init/scripts/repo-profile.sh" show "$KIT" | "$DECIDE" merge.approval)
[ "$got" = land ] || fail "the kit's own profile answered '$got' — auto-dev would stop merging here"
echo "  ok: the kit's profile -> land"

echo "merge-approval: OK"
