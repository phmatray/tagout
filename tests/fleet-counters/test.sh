#!/usr/bin/env bash
# Golden test for skills/auto-dev/scripts/fleet-counters.sh and the registered decision
# `autodev.cadence` that reads its numbers.
#
# The supervisor used to keep four tallies itself — merges since the last survey, PARTIAL resumes
# per issue, the streak of `unverified` base verdicts, issues filed against issues closed — and a
# tally kept by a model comes back from a compaction as whatever the summary kept. This suite pins
# the script that keeps them instead: that each count is exact and idempotent where it has to be,
# that the numbers persist in a file beside the state file, and that the things it must REFUSE
# (a corrupt file, an untrusted base line, a non-issue) are refused rather than counted.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $*"; exit 1; }

FC="$KIT/skills/auto-dev/scripts/fleet-counters.sh"
DECIDE="$KIT/scripts/decide.sh"
[ -x "$FC" ] || fail "$FC missing or not executable"
[ -x "$KIT/skills/auto-dev/scripts/cadence-verdict.sh" ] || fail "cadence-verdict.sh missing or not executable"

scratch=$(kit_scratch)
SF="$scratch/state/github.com/acme/widgets.md"
CF="${SF%.md}.counters.json"
export KIT_DECISION_LOG="$scratch/decision-events.jsonl"

cadence() { "$FC" "$SF" state | "$DECIDE" autodev.cadence --json | jq -r '"\(.verdict) \(.rule)"'; }
is() { [ "$2" = "$3" ] || fail "[$1] expected '$3', got '$2'"; echo "  ok: $1"; }

echo "== counting =="
is "a fleet with no counts yet answers zeros, and writes nothing" \
  "$("$FC" "$SF" state)" '{"merges":0,"merges_at_survey":0,"blocking_pending":false}'
[ ! -e "$CF" ] || fail "a read created the counters file"
is "the first merge" "$("$FC" "$SF" merged 12)" "merges: 1"
[ -f "$CF" ] || fail "merged did not write $CF beside the state file"
is "the same issue reported twice counts once" "$("$FC" "$SF" merged 12)" "merges: 1"
is "a second issue" "$("$FC" "$SF" merged 13)" "merges: 2"
is "a resume" "$("$FC" "$SF" resumed 40)" "PARTIAL ×1"
is "a second resume of the same issue" "$("$FC" "$SF" resumed 40)" "PARTIAL ×2"
is "another issue's resumes are its own" "$("$FC" "$SF" resumed 41)" "PARTIAL ×1"
"$FC" "$SF" escalated 40
is "issue reports both records" "$("$FC" "$SF" issue 40)" '{"resumes":2,"escalated":true}'
is "an issue never seen reports zeros" "$("$FC" "$SF" issue 999)" '{"resumes":0,"escalated":false}'
"$FC" "$SF" filed 90 91; "$FC" "$SF" filed 91 92
is "filed issues are counted once each" "$(jq -c '.filed' "$CF")" '["90","91","92"]'

echo "== the survey cadence is decided from the file, not from memory =="
is "two merges since the survey" "$(cadence)" "steady not-due"
"$FC" "$SF" merged 14 >/dev/null; "$FC" "$SF" merged 15 >/dev/null
is "four merges is still not due" "$(cadence)" "steady not-due"
"$FC" "$SF" merged 16 >/dev/null
is "the fifth merge makes it due" "$(cadence)" "resurvey merge-cadence"
"$FC" "$SF" surveyed
is "surveyed resets the window" "$(cadence)" "steady not-due"
"$FC" "$SF" merged 17 --blocking >/dev/null
is "one merge that was blocking others is due at once" "$(cadence)" "resurvey blocker-landed"
"$FC" "$SF" surveyed
is "surveyed clears the blocking flag too" "$(cadence)" "steady not-due"

echo "== the unverified streak =="
is "one unverified base prints nothing" "$("$FC" "$SF" base 'unverified (query-failed)')" ""
is "two print nothing" "$("$FC" "$SF" base 'unverified (query-failed)')" ""
is "the third is a finding, with the latest reason" "$("$FC" "$SF" base 'unverified (no-run-yet)')" \
  "base health unchecked for 3 merges (no-run-yet)"
is "the fourth keeps counting" "$("$FC" "$SF" base 'unverified (no-run-yet)')" \
  "base health unchecked for 4 merges (no-run-yet)"
is "a RED resets the streak" "$("$FC" "$SF" base 'RED (run-failed)')" ""
is "…so the next unverified starts from one" "$("$FC" "$SF" base 'unverified (cancelled)')" ""

echo "== the summary =="
# 6 merged (12-17), 3 filed: draining.
summary=$("$FC" "$SF" summary)
is "the totals line" "$(printf '%s\n' "$summary" | sed -n 1p)" \
  "merged: 6 · filed by the fleet: 3 · merges since the last survey: 0"
case "$summary" in *"not draining"*) fail "the pressure line printed while merges outnumber filings: $summary" ;; esac
"$FC" "$SF" filed 93 94 95
is "filings meeting merges prints the pressure line" "$("$FC" "$SF" summary | sed -n 2p)" \
  "6 merged, 6 filed — the queue is not draining"

echo "== refusals: nothing is counted, nothing is overwritten =="
refused() {
  local label="$1" needle="$2"; shift 2
  local out rc=0 before after
  before=$(cat "$CF" 2>/dev/null || true)
  out=$("$@" 2>&1) || rc=$?
  after=$(cat "$CF" 2>/dev/null || true)
  [ "$rc" -eq 2 ] || fail "[$label] expected exit 2, got $rc: $out"
  grep -qF -- "$needle" <<<"$out" || fail "[$label] the refusal does not say '$needle': $out"
  [ "$before" = "$after" ] || fail "[$label] a refused call changed the counters file"
  echo "  ok: $label — refused, exit 2, counts untouched"
}
refused "a base line outside the grammar" "re-derive" "$FC" "$SF" base "green"
refused "a paraphrased base line" "re-derive" "$FC" "$SF" base "green, CI passed on main"
refused "an issue with a # in front" "not an issue number" "$FC" "$SF" merged "#12"
refused "an issue that is a word" "not an issue number" "$FC" "$SF" resumed twelve
refused "one bad issue among good ones files none" "not an issue number" "$FC" "$SF" filed 96 x97
refused "a stray flag on merged" "--blocking" "$FC" "$SF" merged 18 --block
refused "an unknown command" "unknown command" "$FC" "$SF" tally
refused "a state file that is not the .md one" "ends in .md" "$FC" "$scratch/state.json" state
refused "no command" "usage:" "$FC" "$SF"
# The one that matters most: a counters file this script did not write is never reset to zero.
cp "$CF" "$scratch/good.json"
echo '{"merged": 4}' > "$CF"
refused "a counters file of the wrong shape" "never reset silently" "$FC" "$SF" merged 18
refused "…and a read of it is refused too" "never reset silently" "$FC" "$SF" state
is "the foreign file is left exactly as found" "$(cat "$CF")" '{"merged": 4}'
cp "$scratch/good.json" "$CF"

echo "== clear =="
"$FC" "$SF" clear
[ ! -e "$CF" ] || fail "clear left the counters file behind"
is "after clear the fleet counts from zero" "$("$FC" "$SF" state)" \
  '{"merges":0,"merges_at_survey":0,"blocking_pending":false}'

echo "== the owner invokes the decision and no longer restates its integer =="
PROSE="$(kit_skill_prose "$KIT" auto-dev)"   # router + references/steps/*.md
grep -qF 'decide.sh autodev.cadence' "$PROSE" || fail "auto-dev never invokes autodev.cadence"
flat=$(tr '\n' ' ' < "$PROSE")
if grep -qE 'every ~?[0-9]+ merges' <<<"$flat"; then
  fail "auto-dev's prose restates the survey cadence — its one home is cadence-verdict.sh"
fi
for cmd in 'merged <issue>' 'resumed <issue>' 'escalated <issue>' "base '<line>'" 'surveyed' 'summary' 'clear'; do
  grep -qF "fleet-counters.sh \"\$STATE_FILE\" $cmd" "$PROSE" \
    || fail "auto-dev's steps never call fleet-counters.sh \"\$STATE_FILE\" $cmd — a count nobody records is a count nobody can trust"
done
echo "  ok: Steps 3, 4 and 6 call every counting command, and name no cadence of their own"

echo "fleet-counters golden test OK"
