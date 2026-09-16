#!/usr/bin/env bash
# post-review-check.sh — proves whether a code-review dispatch wrote past its own report onto
# a worker's live worktree.
#
# implement-issue Step 7 dispatches the Standards-axis review as a forked `code-review` skill
# call — a fork that inherits the parent's full tool access AND its live, guarded worktree.
# Three prior incidents (#477, #560, #578) left the mitigation as prose: "the moment that call
# returns, before you read a single finding, ask what it changed" — three `git` commands the
# caller has to remember to run, compared against a sha recorded several turns earlier. #659
# measured that prose not holding the line: the fork committed twice, through bare `git`, using
# implement-issue's own commit-message idiom for Steps 6 and 8, and a `status --porcelain` /
# `rev-parse HEAD` pair run at the wrong moment — before the fork's commits existed — read as
# "nothing happened". The drift surfaced several turns later, by chance.
#
# This script is the enforceable replacement: hand it the worktree, the branch this task owns,
# and the sha recorded right before the review dispatch, and it refuses loudly — naming exactly
# what changed — instead of leaving the comparison to memory.
#
# Usage:
#   post-review-check.sh -C <repo-path> --branch <expected-branch> --before <sha>
#
#   -C <repo-path>    the worktree to check. Required — this never defaults to the current
#                      directory, the same rule every other guard in this directory follows;
#                      the ambient checkout is exactly what Step 4 says not to trust.
#   --branch <name>   the branch this task owns, spelled out by the caller — never read off
#                      HEAD, which would agree with itself no matter what moved it.
#   --before <sha>    HEAD as recorded right before the review dispatch. Write it into the
#                      report, not a shell variable: every command here runs in a fresh shell,
#                      so a variable set before the dispatch is empty by the time this runs, and
#                      an empty value would make the exit-2 comparison below pass silently — the
#                      exact failure this script exists to catch.
#
# Exit codes:
#   0   clean — HEAD is still <sha>, on <branch>, and the working tree has no changes.
#       Prints `post-review-check: clean - HEAD unchanged at <sha>`.
#   1   the tree is dirty — tracked or untracked. Prints a REFUSED line, `git status
#       --porcelain`, and `git diff --stat`, so the caller sees the change without a second
#       command. Checked BEFORE the HEAD comparison, so a review that left an uncommitted edit
#       at the *same* sha is still caught rather than read as clean.
#   2   HEAD moved off <sha> while still on <branch> — whichever direction; a reset counts the
#       same as an advance, since either means something happened that the caller didn't do.
#       Prints a REFUSED line naming both shas and every new commit's subject line via
#       `git log --oneline <before>..<after>`.
#   3   HEAD is not on <branch>, or is detached. Prints a REFUSED line naming what HEAD is on
#       instead.
#   64  usage error — a missing/unparseable option, `-C` not a git repository, or `--before`
#       not a commit that resolves. Nothing was checked; not a verdict about the review.
#
# Exit 1/2/3 are verdicts about the review's own writes, not about this script's ability to
# run — that distinction is what exit 64 is for. Checks run in this order: branch, then dirty,
# then HEAD — each stop is unconditional on the ones after it, so a wrong-branch tree is never
# also reported dirty, and a dirty tree's HEAD is never compared.
set -euo pipefail

TOOL=post-review-check

usage() {
  echo "usage: $TOOL.sh -C <repo-path> --branch <expected-branch> --before <sha>" >&2
}

refuse_usage() { echo "$TOOL: $1" >&2; usage; exit 64; }

REPO=""
BRANCH=""
BEFORE=""

while [ $# -gt 0 ]; do
  case "$1" in
    -C)        [ -n "${2:-}" ] || refuse_usage "-C needs a path"
               REPO="$2"; shift 2 ;;
    --branch)  [ -n "${2:-}" ] || refuse_usage "--branch needs a name"
               BRANCH="$2"; shift 2 ;;
    --before)  [ -n "${2:-}" ] || refuse_usage "--before needs a sha"
               BEFORE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)         refuse_usage "unknown argument: $1" ;;
  esac
done

[ -n "$REPO" ]   || refuse_usage "-C <repo-path> is required"
[ -n "$BRANCH" ] || refuse_usage "--branch is required"
[ -n "$BEFORE" ] || refuse_usage "--before is required"

git -C "$REPO" rev-parse --git-dir > /dev/null 2>&1 \
  || refuse_usage "'$REPO' is not a git repository"

BEFORE_SHA=$(git -C "$REPO" rev-parse --verify --quiet "$BEFORE^{commit}" 2> /dev/null) \
  || refuse_usage "--before '$BEFORE' does not resolve to a commit"

# 1. Branch — checked first: a tree on the wrong branch entirely is a different failure than a
# dirty or advanced one, and reporting it as either of those would send the caller looking in
# the wrong place.
ACTUAL=$(git -C "$REPO" branch --show-current)
if [ "$ACTUAL" != "$BRANCH" ]; then
  echo "$TOOL: REFUSED - HEAD is on '${ACTUAL:-<detached>}', expected '$BRANCH'" >&2
  exit 3
fi

# 2. Dirty tree — before the HEAD comparison, so an uncommitted write the review left behind at
# the SAME sha is still caught rather than passed as clean.
STATUS=$(git -C "$REPO" status --porcelain)
if [ -n "$STATUS" ]; then
  echo "$TOOL: REFUSED - uncommitted changes since the review:" >&2
  printf '%s\n' "$STATUS" >&2
  git -C "$REPO" diff --stat >&2
  exit 1
fi

# 3. HEAD moved — any difference from --before, whichever direction. Not gated on the commit
# count being positive: a reset that leaves `<before>..<after>` empty still moved HEAD, and is
# still reported as REFUSED rather than silently treated as clean.
AFTER=$(git -C "$REPO" rev-parse HEAD)
if [ "$AFTER" != "$BEFORE_SHA" ]; then
  COMMIT_LOG=$(git -C "$REPO" log --oneline "$BEFORE_SHA..$AFTER")
  N=0
  [ -z "$COMMIT_LOG" ] || N=$(printf '%s\n' "$COMMIT_LOG" | wc -l | tr -d '[:space:]')
  echo "$TOOL: REFUSED - HEAD advanced from $BEFORE_SHA to $AFTER during the review ($N new commit(s)):" >&2
  [ -z "$COMMIT_LOG" ] || printf '%s\n' "$COMMIT_LOG" >&2
  exit 2
fi

echo "$TOOL: clean - HEAD unchanged at $AFTER"
