#!/usr/bin/env bash
# Golden test for skills/_shared/sizing.md and the one line of AGENTS.md's routing section that
# sends a new request through it (#737).
#
# The rule is prose, so what can rot is its SHAPE — and each rot here turns the lighter road into a
# way around the lifecycle rather than a shorter path through it:
#   * the bounded test loses a point             -> a contract change travels with no issue, no plan
#   * the round-up sentence goes                 -> doubt takes the cheap road
#   * `--draft` drops off the bounded road       -> merge-pr lands the PR with no review at all
#   * the one-way-door list is copied, not cited -> two lists, and the copy goes stale
#   * create-issue starts reading the sizing     -> merge-pr and the auto-dev workers call it
#                                                   unattended; a redirect there turns a follow-up
#                                                   into a branch nobody asked for
# So each of those is pinned, and the last one is pinned as an ABSENCE.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

fail() { echo "FAIL: $*"; exit 1; }

SIZING="$KIT/skills/_shared/sizing.md"
AGENTS="$KIT/AGENTS.md"
[ -f "$SIZING" ] || fail "missing $SIZING"

# ------------------------------------------------------------------ 1. the bounded test, whole
bounded=$(sed -n '/^## Bounded$/,/^## Anything else$/p' "$SIZING")
[ -n "$bounded" ] || fail "sizing.md has no '## Bounded' section"
for want in '**Every** point must hold' \
            'one `area:` label' 'one top-level directory' \
            'no new file outside tests' \
            'no behaviour of a contract, a hook, a registered decision or a manifest' \
            'no one-way-door path'; do
  grep -qF -- "$want" <<<"$bounded" || fail "the bounded test lost: $want"
done
points=$(grep -cE '^[0-9]+\. ' <<<"$bounded" || true)
[ "$points" -eq 4 ] || fail "the bounded test has $points numbered points, expected 4 — a point added or dropped changes what travels without an issue; update this suite with it"
echo "  ok: the bounded test carries its four points"

# ------------------------------------------------- 2. the one-way-door list is cited, never copied
grep -qF '(../implement-issue/references/steps/07-review.md)' <<<"$bounded" \
  || fail "the bounded test does not link implement-issue Step 7 for the one-way-door list"
[ -f "$KIT/skills/implement-issue/references/steps/07-review.md" ] || fail "the cited Step 7 file is gone"
door=$(sed -n '/<!-- one-way-door:start -->/,/<!-- one-way-door:end -->/p' "$KIT/skills/implement-issue/references/steps/07-review.md")
[ -n "$door" ] || fail "Step 7 no longer carries the one-way-door block sizing.md cites"
for copied in 'marketplace.json' 'plugin.json' 'webhook'; do
  if grep -qF -- "$copied" "$SIZING"; then
    fail "sizing.md names '$copied' — the one-way-door list is copied here instead of cited"
  fi
done
echo "  ok: the one-way-door list is cited from Step 7, not copied"

# --------------------------------------------------------------- 3. the rule fails towards today
grep -qF 'Any doubt goes up a size' "$SIZING" || fail "sizing.md lost the round-up sentence"
grep -qF 'never down' "$SIZING"               || fail "sizing.md lost 'never down'"
grep -qF 'A request that asks for an issue always files one' "$SIZING" \
  || fail "sizing.md no longer says a direct request for an issue outranks the sizing"
grep -qF 'sized again from the top' "$SIZING"  || fail "sizing.md no longer re-sizes a spike that should be kept"
grep -qF 'sized as bounded' "$SIZING"          || fail "sizing.md no longer asks for the size to be stated in one line"
echo "  ok: round-up, the direct-request rule, the kept spike and the one-line statement"

# ------------------------------------------------ 4. the bounded road opens a DRAFT, in both homes
grep -qF 'create-pr --draft' <<<"$bounded" || fail "sizing.md's bounded road does not open a draft"
routing=$(sed -n '/^## Which kit skill, for what$/,/^## Loading a skill$/p' "$AGENTS")
[ -n "$routing" ] || fail "AGENTS.md has no routing section"
line=$(tr '\n' ' ' <<<"$routing")
for want in 'A new request with no issue' '`<kit>/skills/_shared/sizing.md`' '**bounded**' \
            '`create-pr --draft`' '**spike**' 'any doubt → `create-issue`' \
            'A request for an issue always'; do
  grep -qF -- "$want" <<<"$line" || fail "AGENTS.md's routing section does not carry: $want"
done
echo "  ok: AGENTS.md routes a new request through the sizing, and the bounded road is a draft"

# ----------------------------- 5. the routing line reaches a session through the SessionStart hook
ctx=$(CLAUDE_PLUGIN_ROOT="$KIT" ROUTING_CONTEXT= bash "$KIT/hooks/routing-context.sh" <<<'{}' 2>/dev/null) || true
grep -qF 'sizing.md' <<<"$ctx" || fail "hooks/routing-context.sh does not carry the sizing line into the session"
echo "  ok: the SessionStart routing context carries the sizing line"

# ------------------------------------------------------ 6. create-issue never reads the sizing
if grep -rlF 'sizing.md' "$KIT/skills/create-issue" >/dev/null 2>&1; then
  fail "skills/create-issue cites sizing.md — it is called unattended by merge-pr and the auto-dev workers, and must never redirect"
fi
echo "  ok: create-issue does not cite sizing.md"

echo "sizing: OK"
