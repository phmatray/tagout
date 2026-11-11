#!/usr/bin/env bash
# Golden test for skills/auto-dev/scripts/reconcile.sh (#753) — the supervisor's one-shot ground
# truth, read through the tracker contract (`pr-list`, `pr-merge-state`) instead of a direct
# `gh pr list --json mergeStateStatus`.
#
# Seam: reconcile.sh's STDOUT (the lines the supervisor reads) and the call log of a stub `gh` first
# on PATH, answering the argv the GitHub backend sends. Asserted on the rendered line, never on the
# backend's jq: a draft prints DRAFT with no merge-state call, a failed merge-state read UNKNOWN, and
# a failed list a named line rather than an empty section — "no open PRs" and "could not ask" must
# stay different facts.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"
RECONCILE="$KIT/skills/auto-dev/scripts/reconcile.sh"
[ -x "$RECONCILE" ] || { echo "FAIL: $RECONCILE missing or not executable"; exit 1; }

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
WORK=$(kit_scratch)
FAILED=0
fail() { echo "FAIL: $1"; FAILED=1; }
ok() { echo "ok: $1"; }

mkdir -p "$WORK/bin" "$WORK/cwd"
export GH_CALL_LOG="$WORK/gh.log"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALL_LOG"
jq_expr=""; prev=""
for a in "$@"; do [ "$prev" = --jq ] && jq_expr="$a"; prev="$a"; done
case "$1 $2" in
  "auth token") echo tok; exit 0 ;;
  "pr list")
    case "$*" in
      *"--state open"*)
        [ -z "${GH_OPEN_FAIL:-}" ] || { echo "HTTP 502" >&2; exit 1; }
        payload='[{"number":9,"title":"u","url":"x","state":"OPEN","isDraft":true,"headRefName":"feat/y","body":"","mergedAt":null},
                  {"number":7,"title":"t","url":"x","state":"OPEN","isDraft":false,"headRefName":"feat/x","body":"","mergedAt":null,"mergeStateStatus":"CLEAN"},
                  {"number":8,"title":"v","url":"x","state":"OPEN","isDraft":false,"headRefName":"feat/z","body":"","mergedAt":null}]' ;;
      *"--state merged"*)
        [ -z "${GH_MERGED_FAIL:-}" ] || { echo "HTTP 502" >&2; exit 1; }
        payload='[{"number":5,"title":"t","url":"x","state":"MERGED","isDraft":false,"headRefName":"feat/w","body":"","mergedAt":"2026-11-01T00:00:00Z"}]' ;;
      *) echo "gh stub: unexpected pr list: $*" >&2; exit 1 ;;
    esac ;;
  "pr view")
    case "$3" in
      7) payload='{"mergeStateStatus":"CLEAN","isDraft":false,"reviewDecision":"APPROVED","baseRefName":"main","headRefName":"feat/x","isCrossRepository":false,"headRepositoryOwner":{"login":"o"}}' ;;
      *) echo "HTTP 404" >&2; exit 1 ;;
    esac ;;
  "api repos/"*) payload='{"behind_by":0}' ;;
  "api graphql") exit 0 ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 1 ;;
esac
if [ -n "$jq_expr" ]; then printf '%s' "$payload" | jq -r "$jq_expr"; else printf '%s\n' "$payload"; fi
STUB
chmod +x "$WORK/bin/gh"

run() { : > "$GH_CALL_LOG"; OUT=$(cd "$WORK/cwd" && PATH="$WORK/bin:$PATH" bash "$RECONCILE" 2>"$WORK/err"); }

run
TAB=$(printf '\t')
grep -Fxq "#7${TAB}READY${TAB}CLEAN${TAB}feat/x${TAB}t" <<<"$OUT" \
  && ok "a ready PR prints its pr-merge-state" || fail "ready row missing:
$OUT"
grep -Fxq "#9${TAB}DRAFT${TAB}DRAFT${TAB}feat/y${TAB}u" <<<"$OUT" \
  && ok "a draft prints DRAFT in the merge-state column" || fail "draft row missing:
$OUT"
if grep -q '^pr view 7' "$GH_CALL_LOG"; then fail "a PR whose pr-list carries mergeStateStatus cost a merge-state call: $(cat "$GH_CALL_LOG")"
else ok "a PR whose pr-list carries mergeStateStatus makes no merge-state call"; fi
if grep -q '^pr view 9' "$GH_CALL_LOG"; then fail "a draft cost a merge-state call: $(cat "$GH_CALL_LOG")"
else ok "a draft makes no merge-state call"; fi
grep -Fxq "#8${TAB}READY${TAB}UNKNOWN${TAB}feat/z${TAB}v" <<<"$OUT" \
  && ok "a failed merge-state read prints UNKNOWN" || fail "UNKNOWN row missing:
$OUT"
open_rows=$(awk '/^== OPEN/{f=1;next} /^$/{f=0} f' <<<"$OUT" | cut -f1 | tr '\n' ' ')
[ "$open_rows" = "#7 #8 #9 " ] && ok "open rows sort by number" || fail "open rows out of order: '$open_rows'"
grep -Fxq "#5${TAB}2026-11-01T00:00:00Z${TAB}t" <<<"$OUT" \
  && ok "the merged section prints number, mergedAt and title" || fail "merged row missing:
$OUT"

GH_OPEN_FAIL=1 run
grep -Fq "(tracker.sh pr-list failed — exit 1)" <<<"$OUT" \
  && ok "a failed open pr-list prints a named line, not an empty section" || fail "no pr-list failed line:
$OUT"
grep -Fxq "#5${TAB}2026-11-01T00:00:00Z${TAB}t" <<<"$OUT" \
  && ok "the merged section still prints after the open list failed" || fail "merged section lost:
$OUT"

rc=0; GH_MERGED_FAIL=1 run || rc=$?
[ "$rc" -eq 0 ] && grep -Fq "(tracker.sh pr-list failed — exit 1)" <<<"$(awk '/^== RECENTLY/{f=1} f' <<<"$OUT")" \
  && ok "a failed merged pr-list prints a named line under its header, exit 0" || fail "merged-fail (rc $rc):
$OUT"
grep -Fxq "#7${TAB}READY${TAB}CLEAN${TAB}feat/x${TAB}t" <<<"$OUT" \
  && ok "the open section still prints when the merged list failed" || fail "open section lost:
$OUT"

[ "$FAILED" -eq 0 ] || exit 1
echo "reconcile: all ok"
