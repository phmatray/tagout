#!/usr/bin/env bash
# guarded-ready.sh — flips a PR draft -> ready only if implement-issue's Step 7 review ran.
#
# Step 7's review is mandatory and prose alone did not hold it (#728: two workers in a row
# skipped it). post-review-check.sh records `kit.review.<branch>.sha` in the common git config
# when the review comes back clean; this guard refuses the flip without that record.
#
# Usage:  guarded-ready.sh -C <repo-path> --branch <branch> <pr-number>
#   -C is required, never defaulted — the rule every guard in this directory follows.
#
# Exit codes:
#   0  record present: runs `gh pr ready <pr>`, prints `guarded-ready: OK — review recorded at <sha>`.
#   1  no record: prints REFUSED, never calls gh.
#   2  usage error.
set -euo pipefail

TOOL=guarded-ready
usage() { echo "usage: $TOOL.sh -C <repo-path> --branch <branch> <pr-number>" >&2; }
refuse_usage() { echo "$TOOL: $1" >&2; usage; exit 2; }

REPO=""; BRANCH=""; PR=""
while [ $# -gt 0 ]; do
  case "$1" in
    -C)       [ -n "${2:-}" ] || refuse_usage "-C needs a path"; REPO="$2"; shift 2 ;;
    --branch) [ -n "${2:-}" ] || refuse_usage "--branch needs a name"; BRANCH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*)       refuse_usage "unknown argument: $1" ;;
    *)        [ -z "$PR" ] || refuse_usage "unexpected argument: $1"; PR="$1"; shift ;;
  esac
done

[ -n "$REPO" ]   || refuse_usage "-C <repo-path> is required"
[ -n "$BRANCH" ] || refuse_usage "--branch is required"
[ -n "$PR" ]     || refuse_usage "a PR number is required"
case "$PR" in *[!0-9]*) refuse_usage "PR number must be digits: $PR" ;; esac

SHA=$(git -C "$REPO" config --get "kit.review.${BRANCH}.sha" 2> /dev/null || true)
if [ -z "$SHA" ]; then
  echo "$TOOL: REFUSED — no review recorded for $BRANCH; run implement-issue Step 7 (code-review + post-review-check.sh) first" >&2
  exit 1
fi

gh pr ready "$PR"
echo "$TOOL: OK — review recorded at $SHA"
