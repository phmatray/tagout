#!/usr/bin/env bash
# skills/merge-pr/scripts/remote-branch-teardown.sh — finish the remote-branch delete that Step 7
# used to assume was already done (#185).
#
# Finding (issue #185, Task 1 — confirmed by reading `pkg/cmd/pr/merge/merge.go`'s `mergeRun` on
# `cli/cli`): gh calls `deleteLocalBranch` before `deleteRemoteBranch`, and the first error
# short-circuits the rest. On the kit's own layout the PR's head branch lives in an
# `implement-issue` worktree, so `deleteLocalBranch`'s `git branch -D <headRefName>` fails — git
# refuses to delete a branch checked out elsewhere — `mergeRun` returns right there, and
# `deleteRemoteBranch` never runs. Step 7's local teardown (Case A/B) recovers the local half; this
# script finishes the remote half instead of assuming Step 5's `--delete-branch` or the repo's
# `delete_branch_on_merge` setting already did.
#
# Decision: this always runs the `ls-remote` check, regardless of what the repo's
# `delete_branch_on_merge` setting says. Reading that setting first would save one round trip on
# the repos that have it on, but the value lives in a profile snapshot that can drift between
# refreshes — a stale "true" would skip a delete that is actually still owed, and a leaked branch
# is permanent while an extra `ls-remote` is one cheap network call. Simplicity and correctness
# both point the same way here, so there is no branch on the setting at all.
#
# Usage: remote-branch-teardown.sh <head-branch> [<host>/]<owner>/<repo>
#   Checks whether <head-branch> still exists on `origin` and deletes it through
#   `scripts/tracker.sh branch-delete` (#752) when it does — `ok` prints deleted, `gone` (the race
#   below, which each backend detects) prints already-gone. Tolerant of the branch already being gone — either before the check (Step 5's
#   --delete-branch, GitHub's own delete_branch_on_merge) or in the race between the check and the
#   delete call (the same 422/404 "Reference does not exist" gh's own deleteRemoteBranch tolerates).
#   Any other delete failure is reported on stderr, not swallowed.
#   <host>/ names a GitHub Enterprise host outright; with a bare <owner>/<repo> the host is the
#   checkout's origin's, when origin is that repository. Resolved once, before the ls-remote, by
#   skills/_shared/scripts/_gh-host.sh (#514) — on GitHub only; another tracker gets the slug as given.
#
# Prints exactly one word to stdout and exits 0 on either non-error outcome: already-gone | deleted
# Exits 2 on a usage/prerequisite error — a malformed slug, a missing host helper and a missing
# scripts/tracker.sh included —
# before touching the network.
# Exits 1 on a genuine delete failure — the branch survived and still needs a human's attention.
set -euo pipefail

usage() {
  echo "usage: remote-branch-teardown.sh <head-branch> [<host>/]<owner>/<repo>" >&2
}

HEAD_BRANCH="${1:-}"
REPO="${2:-}"

if [ -z "$HEAD_BRANCH" ] || [ -z "$REPO" ]; then
  usage
  exit 2
fi

command -v git > /dev/null 2>&1 || {
  echo "remote-branch-teardown: git is missing" >&2
  exit 2
}
command -v jq > /dev/null 2>&1 || {
  echo "remote-branch-teardown: jq is missing" >&2
  exit 2
}

# The repository's own host (#514): `gh api` never infers one, so on a GitHub Enterprise repository
# the DELETE below reached github.com and the branch survived on the real remote. Decided in ONE
# place, the helper below; its exported GH_HOST is what the DELETE inherits. Resolved after every
# check above and before the ls-remote, so a refusal still means nothing was touched.
#
# $0 through any symlinks first, as guarded-commit.sh does: `pwd -P` canonicalizes the directory,
# not the link, and macOS's readlink has no -f.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  _link=$(readlink -- "$SELF") || break
  case "$_link" in
    /*) SELF="$_link" ;;
    *)  SELF="$(dirname -- "$SELF")/$_link" ;;
  esac
done
KIT_ROOT=$(CDPATH= cd -- "$(dirname -- "$SELF")/../../.." && pwd -P) \
  || KIT_ROOT="$(dirname -- "$SELF")/../../.."
GH_HOST_LIB="$KIT_ROOT/skills/_shared/scripts/_gh-host.sh"
# CALLABLE, not merely readable: an empty or truncated helper sources cleanly and defines nothing.
if [ -r "$GH_HOST_LIB" ]; then . "$GH_HOST_LIB" || true; fi
command -v gh_host_resolve > /dev/null 2>&1 || {
  echo "remote-branch-teardown: REFUSED — cannot load $GH_HOST_LIB; reinstall the kit" >&2
  exit 2
}
TRACKER_SH="$KIT_ROOT/scripts/tracker.sh"
[ -x "$TRACKER_SH" ] || {
  echo "remote-branch-teardown: REFUSED — cannot find $TRACKER_SH; reinstall the kit" >&2
  exit 2
}
TRACKER_NAME=$("$TRACKER_SH" state merge-pr 2>/dev/null | jq -r '.tracker // empty') || TRACKER_NAME=""
[ -n "$TRACKER_NAME" ] || {
  echo "remote-branch-teardown: REFUSED — tracker.sh state could not name this repository's tracker" >&2
  exit 2
}
if [ "$TRACKER_NAME" = github ]; then
  gh_host_resolve "$REPO" || exit 2
  REPO="$KIT_REPO_SLUG"
fi

# Fully-qualified, not the bare branch name: `git ls-remote --heads origin <pattern>` matches a
# pattern that is a SUFFIX of the full refname at a `/` boundary, not just an exact name — so a
# bare "$HEAD_BRANCH" also matches an unrelated branch this one's name happens to be the tail of
# (e.g. "185-remote-branch-teardown" matches both itself and "fix/185-remote-branch-teardown").
# A full "refs/heads/…" pattern is always matched exactly.
if ! REMOTE_REF=$(git ls-remote --heads origin "refs/heads/$HEAD_BRANCH" 2>&1); then
  echo "remote-branch-teardown: git ls-remote --heads origin 'refs/heads/$HEAD_BRANCH' failed: $REMOTE_REF" >&2
  exit 1
fi

if [ -z "$REMOTE_REF" ]; then
  echo "already-gone"
  exit 0
fi

# The backend owns the encoding (GitHub's per-segment `@uri`, so a `#` cannot truncate the ref and
# the kit's `fix/…` slashes stay path separators) and the race: a delete that lost to a concurrent
# delete_branch_on_merge or a slow --delete-branch answers `gone` — on GitHub, the "Reference does
# not exist" message on a 422 or a 404, never the status code alone, since a nonexistent repository
# 404s too. Any other failure exits non-zero with the host's own text on stderr.
if OUT=$("$TRACKER_SH" -R "$REPO" branch-delete "$HEAD_BRANCH" 2>&1); then
  case "$(printf '%s\n' "$OUT" | tail -n 1)" in
    ok)   echo "deleted"; exit 0 ;;
    gone) echo "already-gone"; exit 0 ;;
  esac
fi

echo "remote-branch-teardown: failed to delete origin/$HEAD_BRANCH: $OUT" >&2
exit 1
