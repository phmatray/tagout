#!/usr/bin/env bash
# pr-existence-guard.sh — does an open PR already close this issue? (#214)
#
# A branch name is only a guess at what a prior run called itself; "does this issue already have a
# closing PR" does not depend on guessing right. This used to be a block of bash and jq in
# `skills/_shared/open-pr.md` §1 that every caller was told to paste verbatim — and a pasted block
# is one a model can paraphrase, truncate or run half of. It is a script now: the callers run it,
# and `tests/pr-existence-guard/test.sh` extracts the marked filter below and runs the script
# against a stub `gh`, so the thing proven green is the thing that executes.
#
# It reaches the host through the tracker contract (#751): `scripts/tracker.sh pr-list` and
# `pr-commits`, so the same guard runs on GitHub, GitLab and Azure DevOps.
#
# Usage: pr-existence-guard.sh <issue>
#   <issue>  the issue number, digits only (no #). Runs against the repository of the current
#            directory, whose profile names the tracker.
#
# Output (stdout), on exit 0:
#   line 1   the number of open PRs whose body closes the issue with one of GitHub's closing
#            keywords — a bare mention does not count
#   then     one TAB-separated row per such PR:
#              RESUME  #<pr>  <head branch>  draft|ready  <url>     the one to resume onto
#              ALSO    #<pr>  <head branch>  draft|ready  <url>     every other — a duplicate
#            With two or more, RESUME is the PR with the most commits (an untouched scaffold has
#            exactly one); on a tie, the lowest PR number — the one created first — so two
#            independent runs converge on the same choice instead of diverging further.
#
# Exit codes:
#   0  a count was printed (0 is an answer: nothing found)
#   2  REFUSED — no verdict. `REFUSED — <why>` is printed on stdout AND stderr. The issue is not
#      digits, the search came back empty (a failed or rate-limited fetch reads exactly like "no
#      rows" to jq, and an unchecked empty fetch would let a duplicate PR through), or a commit
#      count could not be read. Retry it; never read a refusal as 0.
#
# Residual limitation, not fixable from this side: on GitHub, `pr-list --search` hits the Search API,
# which is eventually consistent. A PR created seconds ago can still search as absent, so this
# narrows the #195-shaped race, it does not close it to zero.
set -euo pipefail

refuse() { printf 'REFUSED — %s\n' "$1"; printf 'REFUSED — %s\n' "$1" >&2; exit 2; }

command -v jq > /dev/null 2>&1 || refuse "jq is missing — it is a \`required\` prerequisite in requirements.json"
# The dispatcher sits three directories up, found through any symlink (a plugin install links here).
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  _link=$(readlink -- "$SELF") || break
  case "$_link" in /*) SELF="$_link" ;; *) SELF="$(dirname -- "$SELF")/$_link" ;; esac
done
KIT=$(CDPATH= cd -- "$(dirname -- "$SELF")/../../.." && pwd -P) || refuse "cannot resolve the kit root"
TRACKER_SH="$KIT/scripts/tracker.sh"
[ -x "$TRACKER_SH" ] || refuse "$TRACKER_SH is missing — the search cannot be made; reinstall the kit"

[ "$#" -eq 1 ] || refuse "usage: pr-existence-guard.sh <issue> (one argument, digits only)"
ISSUE="$1"
# The filter concatenates $ISSUE unescaped, and an empty value would degrade `…#\b` into "closes
# any issue", matching PRs unrelated to this one.
case "$ISSUE" in
  ''|*[!0-9]*) refuse "\$ISSUE ('$ISSUE') is not a validated non-empty digit string" ;;
esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pr-existence-guard.XXXXXX") || refuse "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# Wide net first (a plain search can hit a PR that merely MENTIONS the issue), then narrow. --limit
# above the default page size (30): an issue that has accumulated several stale/duplicate PRs — the
# exact scenario this guard targets — could otherwise truncate the real closer off the first page.
"$TRACKER_SH" pr-list --search "$ISSUE" --state open --limit 100 \
  > "$WORK/mentions.json" 2> "$WORK/gh.err" || true

[ -s "$WORK/mentions.json" ] \
  || refuse "the PR search returned nothing; retry rather than treat this as '0 found'"

jq --arg issue "$ISSUE" '
  # >>> issue-scoped PR-existence guard
  # $issue is the numeric issue id, bound above via --arg. `\b…#<n>\b` stops "214" from matching a
  # #2140/#1214 substring. `:?\s*` accepts both "Closes #42" and "Closes: #42" — GitHub recognizes
  # the colon form too — while still requiring the keyword to sit immediately before the number, not
  # just somewhere in the same sentence. `.body // ""` guards a PR with no description: `gh` reports
  # that as JSON `null`, and `test()` throws on `null` rather than treating it as non-matching (#259)
  # — coercing to `""` makes it evaluate to "no match" like any other non-closing body.
  [.[] | select((.body // "") | test("(?i)\\b(close[sd]?|fix(e[sd])?|resolve[sd]?):?\\s*#" + $issue + "\\b"))]
  # <<< issue-scoped PR-existence guard
' "$WORK/mentions.json" > "$WORK/closers.json" \
  || refuse "the PR search did not return the JSON list the filter reads; retry"

count=$(jq 'length' "$WORK/closers.json")

# Which one to resume onto is only a question with two or more; one closer needs no extra call.
if [ "$count" -ge 2 ]; then
  : > "$WORK/commits.tsv"
  for n in $(jq -r '.[].number' "$WORK/closers.json"); do
    c=$("$TRACKER_SH" pr-commits "$n" 2>/dev/null | jq 'length' 2>/dev/null) || c=""
    case "$c" in
      ''|*[!0-9]*) refuse "could not read the commit count of PR #$n; retry rather than pick a PR to resume onto blind" ;;
    esac
    printf '%s\t%s\n' "$n" "$c" >> "$WORK/commits.tsv"
  done
else
  jq -r '.[] | "\(.number)\t0"' "$WORK/closers.json" > "$WORK/commits.tsv"
fi

printf '%s\n' "$count"
jq -r --rawfile commits "$WORK/commits.tsv" '
  ($commits | split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber)})
   | from_entries) as $c
  | sort_by(-($c[(.number | tostring)] // 0), .number)
  | to_entries[]
  | [ (if .key == 0 then "RESUME" else "ALSO" end),
      "#\(.value.number)", .value.headBranch,
      (if .value.isDraft then "draft" else "ready" end), .value.url ]
  | @tsv' "$WORK/closers.json"
