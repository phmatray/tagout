#!/usr/bin/env bash
# Golden test: no dispatch template asks one agent to both push and land (#478).
#
# Two of two CI-restarting dispatches died on one fleet run: each did its work (a conflict
# resolution, a final plan task), pushed — which restarted CI — and then ended its turn to await
# the run its own push had started. The "never dispatch into pending CI" rule as written checks CI
# state at dispatch time, so it answered "not pending" and dispatched. The defect is the
# CONJUNCTION in one prompt: a push verb and a land/merge verb.
#
# Three invariants:
#   1. Every `prompt: "…"` inside an `Agent(` template in skills/auto-dev/SKILL.md is free of the
#      conjunction — checked by a function this suite also drives red over a fixture, so a check
#      that stops matching cannot pass on an empty tree.
#   2. skills/auto-dev/SKILL.md carries the marked push-and-land block: the rule as a property of
#      the dispatch, the split (work → wait-ci → fresh agent), and the #187 cross-reference.
#   3. commands/auto-dev-merge.md tells a phase-2 worker that had to push to stop and report the
#      split by name, never to wait.
#
# Reads only files under skills/auto-dev/ and commands/ — no kit_guard needed.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $1"; exit 1; }

PUSH_VERBS='push|resolve the conflict|re-sync|apply (the|its|the review) fix'
LAND_VERBS='merge|land it|flip .* ready|squash'

# conjunction <text> — exit 0 when the text carries both a push verb and a land verb.
conjunction() {
  grep -qiE "$PUSH_VERBS" <<<"$1" && grep -qiE "$LAND_VERBS" <<<"$1"
}

# Red half: the detector fires on the exact prompt that killed a worker.
conjunction 'Resolve the conflict on PR #1350, push, then merge it once green.' \
  || fail "the conjunction detector does not fire on a push-and-land prompt"
conjunction 'Invoke `auto-dev-merge` with args `<n>`. CI IS ALREADY GREEN — VERIFIED.' \
  && fail "the conjunction detector fires on the phase-2 template, which carries no push verb"

SKILL_MD="$(kit_skill_prose "$KIT" auto-dev)"   # router + references/steps/*.md
[ -f "$SKILL_MD" ] || fail "missing $SKILL_MD"

# 1. Every dispatch template's prompt is free of the conjunction. A template is an `Agent(` call;
#    its prompt runs from `prompt: "` to the closing `")`.
prompts=$(awk '
  /Agent\(/ { inagent = 1 }
  inagent && /prompt: "/ { inprompt = 1; sub(/.*prompt: "/, "") }
  inprompt { buf = buf " " $0 }
  inprompt && /"\)/ { print buf; buf = ""; inprompt = 0; inagent = 0 }
' "$SKILL_MD")
[ -n "$prompts" ] || fail "no Agent( prompt template found in skills/auto-dev/SKILL.md — the extractor is broken"
n=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  n=$((n + 1))
  if conjunction "$line"; then
    fail "a dispatch template asks one agent to both push and land: $line"
  fi
done <<<"$prompts"
echo "ok   $n dispatch template(s) free of the push-and-land conjunction"

# 2. The marked block states the property, the split and the cross-reference.
[ "$(grep -c '<!-- push-and-land:start -->' "$SKILL_MD")" -eq 1 ] \
  || fail "skills/auto-dev/SKILL.md must carry exactly one push-and-land:start marker"
block=$(sed -n '/<!-- push-and-land:start -->/,/<!-- push-and-land:end -->/p' "$SKILL_MD")
grep -qi 'ends in a push' <<<"$block" || fail "push-and-land block does not state the rule as a property of the dispatch"
grep -qF 'wait-ci.sh' <<<"$block" || fail "push-and-land block does not prescribe the supervisor-side wait-ci.sh"
grep -qi 'fresh' <<<"$block" || fail "push-and-land block does not prescribe a fresh agent for the landing"
grep -qi 'non-exhaustive' <<<"$block" || fail "push-and-land block does not mark its dispatch-kind list non-exhaustive"
grep -qF '#187' <<<"$block" || fail "push-and-land block does not cross-reference #187"
grep -qi 'conflict' <<<"$block" || fail "push-and-land block does not name conflict resolution as a CI-restarting kind"

# 3. The phase-2 command tells a worker that pushed to stop and report the split by name.
MERGE_MD="$KIT/commands/auto-dev-merge.md"
[ -f "$MERGE_MD" ] || fail "missing $MERGE_MD"
grep -qF 'CI restarted' "$MERGE_MD" || fail "commands/auto-dev-merge.md does not carry the 'CI restarted' report shape"
grep -qi 'do NOT wait for the run' "$MERGE_MD" || fail "commands/auto-dev-merge.md does not forbid waiting on the run a push started"
grep -qF 'CI restarted' "$SKILL_MD" || fail "skills/auto-dev/SKILL.md does not recognize the 'CI restarted' report shape"

echo "PASS: dispatch-push-and-land"
