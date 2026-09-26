#!/usr/bin/env bash
# rewind-default.sh — move the local default branch back to origin/<default>, only once the
# pushed branch provably already carries every commit the default had (#636).
#
# Why this exists. create-pr can now open a PR straight off a fix debug-issue left on the default
# branch (02-locate-the-work.md switches the work onto a feature branch first). Once that branch is
# pushed, the local default is left AHEAD of origin/<default> unless something winds it back — and
# the next `git pull` there would then report a divergence the squash merge is about to resolve
# anyway. So: after the push, move the local default ref back to what origin already has, but only
# when the pushed branch is a proven superset of it. Never a `reset --hard` (that would also touch
# the working tree, and this never runs from a checkout OF <default> — see the HEAD check below)
# and never a force-push (this only ever moves a LOCAL ref).
#
# Usage:
#   rewind-default.sh -C <repo-path> <default> <branch>
#
#   -C <repo-path>  the worktree to operate in (default: the current directory). Passed to
#                   `git -C`; this script never `cd`s.
#   <default>       the local branch to move back, e.g. main
#   <branch>        the pushed branch that must already carry every commit <default> had
#
# Exit codes:
#   0  <default> moved to origin/<default>; prints `REWOUND <default> <old-sha> -> <new-sha>`
#   2  REFUSED before anything moved — bad arguments, not a repository, detached HEAD, or HEAD is
#      still <default> (this only runs AFTER the work has moved off it onto <branch>)
#   3  REFUSED — origin/<branch> does not contain <default>'s current tip. <default> untouched.
#   4  the move was made but <default> did NOT read back equal to origin/<default> afterwards —
#      reported as an ALERT rather than silently trusted
#
# A destructive act — it moves a branch ref — so it follows the guard convention: refuse before
# writing, verify after writing, and never trust git's own exit code as the whole story (the same
# argument skills/implement-issue/scripts/guarded-commit.sh makes for a commit).

set -euo pipefail

TOOL=rewind-default
GUARD_USAGE="rewind-default.sh -C <repo-path> <default> <branch>"

refuse() {
  printf '%s: REFUSED — %s\n' "$TOOL" "$*" >&2
  printf 'usage: %s\n' "$GUARD_USAGE" >&2
  exit 2
}

REPO="."
while [ $# -gt 0 ]; do
  case "$1" in
    -C)        [ -n "${2:-}" ] || refuse "-C needs a <repo-path>"
               REPO="$2"; shift 2 ;;
    -h|--help) printf '%s\n' "$GUARD_USAGE"; exit 0 ;;
    --)        shift; break ;;
    -*)        refuse "unknown option: $1" ;;
    *)         break ;;
  esac
done

[ $# -eq 2 ] || refuse "exactly two arguments are required: <default> <branch> (got $#)"
DEFAULT="$1"
BRANCH="$2"
[ -n "$DEFAULT" ] && [ -n "$BRANCH" ] || refuse "<default> and <branch> must both be non-empty"

[ -d "$REPO" ] || refuse "-C path is not a directory: $REPO"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || refuse "not a git repository: $REPO"

# `symbolic-ref`, not `rev-parse --abbrev-ref HEAD`: the latter prints the literal string "HEAD" on
# a detached checkout, which would sail past a naive string comparison — same trap
# _assert-branch.sh documents for the guarded-*.sh scripts.
head_branch=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ -n "$head_branch" ] || refuse "HEAD is detached in $REPO — nothing to rewind from. '$DEFAULT' untouched."
[ "$head_branch" != "$DEFAULT" ] || refuse "HEAD is still '$DEFAULT' in $REPO — this only rewinds the default AFTER the work has moved off it onto '$BRANCH'. '$DEFAULT' untouched."

old_sha=$(git -C "$REPO" rev-parse --verify --quiet "refs/heads/$DEFAULT" 2>/dev/null || true)
[ -n "$old_sha" ] || refuse "'$DEFAULT' has no local branch ref in $REPO. Nothing untouched to report."

origin_default=$(git -C "$REPO" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT" 2>/dev/null || true)
[ -n "$origin_default" ] || refuse "origin/$DEFAULT has no ref in $REPO — fetch it first. '$DEFAULT' untouched."

# The one real question: does the branch just pushed already carry everything the local default
# had? If not, rewinding now would make the default regress commits nothing else holds.
if ! git -C "$REPO" merge-base --is-ancestor "$DEFAULT" "origin/$BRANCH" 2>/dev/null; then
  printf '%s: REFUSED — origin/%s does not (yet) contain every commit %s has (currently %s). %s untouched.\n' \
    "$TOOL" "$BRANCH" "$DEFAULT" "$old_sha" "$DEFAULT" >&2
  exit 3
fi

git -C "$REPO" branch -f "$DEFAULT" "origin/$DEFAULT"

# A zero exit from `git branch -f` is not a receipt — read the ref back rather than trust it, the
# same argument guarded-push.sh makes for the remote side of a push.
new_sha=$(git -C "$REPO" rev-parse --verify --quiet "refs/heads/$DEFAULT" 2>/dev/null || true)
if [ "$new_sha" != "$origin_default" ]; then
  printf '%s: ALERT — %s did not read back equal to origin/%s after the move (now %s, expected %s).\n' \
    "$TOOL" "$DEFAULT" "$DEFAULT" "${new_sha:-<unreadable>}" "$origin_default" >&2
  exit 4
fi

printf '%s: REWOUND %s %s -> %s\n' "$TOOL" "$DEFAULT" "$old_sha" "$new_sha"
