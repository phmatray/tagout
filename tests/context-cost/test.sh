#!/usr/bin/env bash
# Golden test for scripts/context-cost.py — the diff of two `/context` captures that documents what
# installing the kit costs every session (docs/install.md, *What the kit costs a session*).
#
# The case this suite exists for: on a host whose skill listing is already at Claude Code's cap, the
# kit's entries add almost nothing to the total and shorten every other skill's description
# instead. A report that only diffs totals calls that free. So the fixtures carry one capped host
# (other skills shrink: the report must say so) and one roomy host (they do not: it must not).
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

SCRIPT="$KIT/scripts/context-cost.py"
FIX="$KIT/tests/context-cost/fixtures"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing"; exit 1; }

fail() { echo "FAIL: $*"; exit 1; }
has() { grep -qF -e "$2" <<<"$1" || { echo "$1"; fail "$3 — output lacks: $2"; }; }
hasnt() { if grep -qF -e "$2" <<<"$1"; then echo "$1"; fail "$3 — output carries: $2"; fi; }

# 1. A capped host: totals, the SessionStart injection in Messages, the kit's own rows, the shrink.
out=$(python3 -I "$SCRIPT" --baseline "$FIX/baseline.md" --with "kit=$FIX/capped.md")
has "$out" "| **Loaded total** | 5.0k | 5.8k (+800) |" "1a total delta"
has "$out" "| Messages | 10 | 834 (+824) |" "1b SessionStart context lands in Messages"
has "$out" "kit skill entries: 2, 470 tokens" "1c the kit's listing rows"
has "$out" "2.0k -> 700 (-1.3k)" "1d other skills' rows, '< 20' counted as 0"
has "$out" "the listing is capped" "1e the shrink is named"
has "$out" 'MCP server `plugin_tagout-migrate_roseline`: 582 tokens' "1f the kit's MCP rows"
echo "ok: capped host — total, Messages, kit rows and the shrink of other skills reported"

# 2. A roomy host: other skills keep their size, so no shrink is claimed.
out=$(python3 -I "$SCRIPT" --baseline "$FIX/baseline.md" --with "kit=$FIX/roomy.md")
has "$out" "2.0k -> 2.0k (0)" "2a other skills unchanged"
hasnt "$out" "the listing is capped" "2b no shrink claimed when nothing shrank"
echo "ok: roomy host — no shrink claimed"

# 2c. A capped host that DROPS a skill instead of shortening it: the skill still counts, as 0, and
#     is named. Comparing only the skills present in both captures would report no shrink for it.
out=$(python3 -I "$SCRIPT" --baseline "$FIX/baseline.md" --with "kit=$FIX/dropped.md")
has "$out" "the 2 other skills the baseline lists: 2.0k -> 700 (-1.3k)" "2c a dropped skill counts as 0"
has "$out" "the listing is capped" "2d the shrink is named when a skill is dropped"
has "$out" "1 dropped from the listing entirely: beta" "2e the dropped skill is named"
hasnt "$(python3 -I "$SCRIPT" --baseline "$FIX/baseline.md" --with "kit=$FIX/capped.md")" "dropped from the listing" "2f nothing dropped, nothing claimed"
echo "ok: dropped skill — counted as 0 and named"

# 3. Refusals: a file /context did not produce, and a --with without LABEL=.
rc=0; python3 -I "$SCRIPT" --baseline "$FIX/not-context.md" --with "kit=$FIX/capped.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "3a a non-/context file must exit 2, got $rc"
rc=0; python3 -I "$SCRIPT" --baseline "$FIX/baseline.md" --with "$FIX/capped.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "3b --with without LABEL= must exit 2, got $rc"
echo "ok: refusals exit 2"

echo "context-cost: all cases passed"
