#!/usr/bin/env bash
# main-worktree.sh — the one home for "what is this repository's main working tree's root".
#
# Why this exists (#125). skills/_shared/worktree-ignore-check.md and worktrees-ignored.sh's own
# header already state the rule in prose: the worktree-ignore guard must be pointed at the MAIN
# working tree, never at a linked worktree or a subdirectory, or it fails open (measured,
# tests/worktrees-ignored/test.sh case 22). Before this script, every caller re-spelled the
# derivation itself, and two had already drifted from the documented recipe:
#
#   * skills/init/scripts/repo-profile.sh used
#     `git rev-parse --show-toplevel`, which — run from inside a linked worktree, the normal
#     state during implement-issue/merge-pr — answers with the LINKED worktree, not the main
#     checkout. The profile then recorded a MEASURED ignore verdict for the wrong directory as a
#     durable fact about the repository.
#   * skills/merge-pr/references/merge-mechanics.md built a path+branch listing with
#     `awk '{p=$2}'`, which truncates a checkout under a path containing a space
#     (`/Users/x/my repo` -> `/Users/x/my`).
#
# The correct recipe was already documented and tested (tests/worktrees-ignored/test.sh cases
# 23a-23c): `git worktree list --porcelain`, first record's path via
# `sed -n '1s/^worktree //p'` — never `awk '{print $2}'`, which splits on whitespace — and empty
# when the second line is exactly `bare`. This script is that recipe, in one place, so a caller
# invokes it instead of re-deriving it a fifth way.
#
# Usage:
#   main-worktree.sh [-C <repo-path>]
#
# Exit codes:
#   0  a verdict was reached — the main working tree's absolute path on stdout (with a trailing
#      newline), or nothing on stdout when the repository is BARE. Bare has no working tree, so
#      nothing there can stage a worktree and there is no ignore hazard to check — callers branch
#      on the empty string, not on the exit code, to tell "no root" from "root is empty".
#   3  usage error, <repo-path> is not a git repository, or `git worktree list` itself failed for a
#      reason unrelated to bareness (a corrupted `.git/worktrees` admin area, a pre-worktree git, a
#      permissions error) — no verdict was reached, so not a pass
#
# Bare repositories are the reason this cannot be `git rev-parse --show-toplevel` even from the
# main checkout: a bare repo has none, and `rev-parse --show-toplevel` there prints nothing while
# exiting non-zero for a reason unrelated to bareness. `git worktree list --porcelain` instead
# always has a first record — for a bare repo, marked `bare` on line 2 — so the bare case is a
# normal branch of the same parse rather than a separate code path.
#
# Do NOT resolve `-C` against the worktree a caller is about to USE. A linked worktree is its own
# `--show-toplevel`, so deriving the argument from it — instead of from "anywhere in the
# repository" — reproduces exactly the bug this script exists to close. Callers pass whatever path
# they have (the main checkout, a linked worktree, a subdirectory of either); this script always
# resolves to the same main-checkout root regardless of which one it was given.

set -euo pipefail

REPO="."

# Prints the header block above as help text — same convention as worktrees-ignored.sh and the
# guards in skills/implement-issue/scripts: ci.yml greps --help for `Exit codes:`.
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -C) [ -n "${2:-}" ] || { printf 'main-worktree: -C needs a <repo-path>\n' >&2; exit 3; }
        REPO="$2"; shift 2 ;;
    *)  printf 'main-worktree: unexpected argument: %s\n' "$1" >&2; exit 3 ;;
  esac
done

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || {
  printf 'main-worktree: %s is not a git repository\n' "$REPO" >&2; exit 3; }

# `sed -n '1s/^worktree //p'`, not `awk '{print $2}'` — the awk spelling splits on whitespace and
# truncates a path containing a space. The first porcelain record is always the main working tree,
# whether this is asked from the main checkout, a linked worktree, or a subdirectory of either.
#
# Explicit `|| exit 3` here, not left to `set -e`: without it, a `git worktree list` failure that is
# NOT about bareness (a corrupted `.git/worktrees` admin area, a pre-worktree git, a permissions
# error) would propagate git's own arbitrary exit code, empty stdout, no diagnostic of ours — a third
# outcome this script's own contract doesn't document. A caller that only checks `[ -z "$wt_root" ]`
# (as the header above tells callers they may) would then read that empty string as "verified bare,
# nothing to check" instead of "no verdict was reached", turning a real failure into a false pass.
# Keeping every failure path on exit 3 is what makes "callers branch on the empty string" true.
WT_LIST=$(git -C "$REPO" worktree list --porcelain) || {
  printf 'main-worktree: %s: git worktree list failed\n' "$REPO" >&2; exit 3; }
ROOT=$(printf '%s\n' "$WT_LIST" | sed -n '1s/^worktree //p')

# A bare repository's first record has no working tree to stage anything from, and its second
# porcelain line is exactly `bare`. Emit nothing rather than the bare path — feeding that to a
# worktree-ignore check produces an unblockable false refusal (check-ignore cannot run in a bare
# repo at all).
# A herestring, not a pipe into `grep -q`: the read closes the instant it matches, and under
# `pipefail` a `sed` still writing at that instant reports its SIGPIPE as this check's verdict (#391).
SECOND_LINE=$(printf '%s\n' "$WT_LIST" | sed -n '2p')
if grep -qx bare <<<"$SECOND_LINE"; then
  exit 0
fi

printf '%s\n' "$ROOT"
