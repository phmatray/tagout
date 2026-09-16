#!/usr/bin/env bash
# release-branch.sh — free a PR branch that a retired worker's worktree still has checked out, so
# the next dispatch onto that branch can reach it (#510).
#
# Why this exists. An auto-dev worker runs in a worktree of its own (`isolation: "worktree"`, #412),
# and that option only auto-cleans a tree that comes back UNCHANGED — a worker that committed
# anything leaves its tree on disk, still holding the PR branch, until the housekeeping sweep
# (skills/auto-dev/SKILL.md, *Cleanup nuance*). The next dispatch onto that branch — a PARTIAL
# resume, a tier escalation, phase 2, a push-and-land re-dispatch, a restart after a crash — lands
# in a NEW tree, where `git switch <branch>` is refused ("already used by worktree at …") and the
# worker's sandbox refuses every git command that names the other tree. Measured twice in one run:
# both dispatches came back BLOCKED with no code changed.
#
# The worker is the wrong place to fix it: it is the one agent confined to its own tree. So the
# SUPERVISOR runs this before every such dispatch. It finds the holder, proves nothing would be
# stranded, and detaches the holder's HEAD at the same commit. The tree, its files and the harness's
# lock all stay for the sweep; only the branch is let go. A worktree lock does not stop a
# `switch --detach`, so no lock is touched.
#
# Usage:
#   release-branch.sh [-C <repo-path>] <branch>
#
#   -C <repo-path>  anywhere in the repository — the main checkout, a linked worktree, or a
#                   subdirectory of either. Default: the current directory.
#   <branch>        the PR branch the next dispatch will check out, e.g. feat/510-some-slug.
#
# One verdict line on stdout:
#   FREE                          no worktree has refs/heads/<branch> checked out
#   RELEASED <holder>             the holder was clean and its HEAD is contained in origin/<branch>;
#                                 it is now detached at the same commit (tree, files, lock untouched)
#   HELD <holder> dirty           the holder has uncommitted TRACKED changes (untracked files do not
#                                 count: they do not block a detach, and they stay where they are)
#   HELD <holder> unpushed <n>    <n> of the holder's commits are not in origin/<branch> — or there
#                                 is no origin/<branch>, and <n> is HEAD's full commit count
#   HELD <holder> main-checkout   the holder is the repository's main working tree
#   HELD <holder> missing         git lists a holder whose directory is gone
#
# Exit codes:
#   0  FREE or RELEASED — the next dispatch can check the branch out.
#   1  HELD — nothing was changed. Work, or a checkout the kit must not discard, is in the way,
#      and a human decides.
#   2  REFUSED, on stderr as `release-branch: REFUSED — …`, nothing on stdout — no verdict: a usage
#      error, <repo-path> is not a git repository, the holder cannot be read as the worktree git
#      lists or moved during the run, the #469 record cannot be unset, or the detach failed.
#      Nothing was changed — with one exception the message names: a holder that reads back
#      neither on <branch> nor detached at its commit after the detach, to be checked by hand.
#      Never read this as FREE.
#
# On RELEASED, the #469 record `kit.worktree.<branch>.path` that make-worktree.sh writes is gone if
# it named the holder: it is unset BEFORE the detach and put back if the detach fails, so RELEASED
# always means both. The unset keeps RELEASED meaning "no record names the holder" — since #644,
# assert_worktree_live (_assert-branch.sh) would re-record it on the adopting tree's first guarded
# write anyway, so a left-behind record is no longer a refusal, only a stale value the guard heals
# in passing. A record naming any other path is left alone. The read-back, not git's exit status,
# decides RELEASED: `git switch` reports a failing post-checkout hook's status after it has already
# moved HEAD.
#
# "Pushed" is judged against the LOCAL remote-tracking ref refs/remotes/origin/<branch>. Nothing is
# fetched, because a raw fetch can be sandbox-blocked. A stale ref can only produce a false
# `HELD unpushed`, never a false RELEASED over lost work.
#
# What it never does: remove, unlock or prune a worktree (the housekeeping sweep stays the only
# remover), write in any tree but the holder, or touch uncommitted work.

set -euo pipefail

TOOL=release-branch

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

refuse() { printf '%s: REFUSED — %s\n' "$TOOL" "$*" >&2; exit 2; }

# The kit root, resolved the way make-worktree.sh resolves it: follow symlinks first, `pwd -P` on
# the directory only. This file lives at <kit>/skills/auto-dev/scripts/, three levels down.
SELF="$0"
while [ -L "$SELF" ]; do
  _link=$(readlink -- "$SELF") || break
  case "$_link" in
    /*) SELF="$_link" ;;
    *)  SELF="$(dirname -- "$SELF")/$_link" ;;
  esac
done
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$SELF")" && pwd -P) || SCRIPT_DIR=$(dirname -- "$SELF")
KIT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd -P) || refuse "internal: cannot resolve the kit root from $SCRIPT_DIR"
MAIN_WORKTREE_SH="$KIT_ROOT/scripts/main-worktree.sh"

REPO="."
BRANCH=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -C)        [ -n "${2:-}" ] || refuse "-C needs a <repo-path>"
               REPO="$2"; shift 2 ;;
    --)        shift ;;   # the <branch> positional still follows; nothing is passed through
    -*)        refuse "unknown option: $1" ;;
    *)
      [ -z "$BRANCH" ] || refuse "unexpected extra argument: $1 (only one <branch> is accepted)"
      BRANCH="$1"; shift ;;
  esac
done

[ -n "$BRANCH" ] || refuse "a branch name is required: release-branch.sh [-C <repo-path>] <branch>"
[ -x "$MAIN_WORKTREE_SH" ] \
  || refuse "missing or not executable: $MAIN_WORKTREE_SH — this script is not a standalone file; reinstall the kit."
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || refuse "$REPO is not a git repository"
git -C "$REPO" check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || refuse "not a valid branch name: $BRANCH"

# ---------------------------------------------------------------- find the holder
#
# Exact match on the `branch refs/heads/<branch>` line — never a substring, so feat/1-x does not
# find feat/1-x-longer's tree — and `substr($0, 10)` for the path, which keeps a path containing a
# space whole (make-worktree.sh's rule). The FIRST holder only: two trees on one branch take
# --force or --ignore-other-worktrees, which the kit forbids; if it ever happens, the next run
# releases the next holder.
WT_LIST=$(git -C "$REPO" worktree list --porcelain) || refuse "git worktree list failed in $REPO"
HOLDER=$(printf '%s\n' "$WT_LIST" | awk -v b="branch refs/heads/$BRANCH" '
  /^worktree / { path = substr($0, 10) }
  $0 == b && !found { print path; found = 1 }
')

if [ -z "$HOLDER" ]; then
  echo "FREE"
  exit 0
fi

# ---------------------------------------------------------------- what must never be released
#
# main-worktree.sh reads the same porcelain listing, so the two spellings of the path agree. It
# prints nothing for a bare repository, which has no main working tree to protect.
MAIN_ROOT=$("$MAIN_WORKTREE_SH" -C "$REPO") \
  || refuse "the main checkout could not be resolved from $REPO (main-worktree.sh failed) — no verdict"
if [ -n "$MAIN_ROOT" ] && [ "$HOLDER" = "$MAIN_ROOT" ]; then
  echo "HELD $HOLDER main-checkout"
  exit 1
fi

if [ ! -d "$HOLDER" ]; then
  echo "HELD $HOLDER missing"
  exit 1
fi

# The holder has to answer as ITSELF before anything it says is believed. A directory whose `.git`
# link is gone is still a directory, and git run inside it walks UP to whatever checkout encloses
# it — `.claude/worktrees/<name>` sits inside the main checkout, so that is the user's own tree
# (the #469 walk-up). Trusting it here would read the main checkout's status and then detach the
# main checkout. So: its toplevel must be the holder itself, and its HEAD must still be the branch
# the listing said it was. Checked before the reads, and again right before the one write.
HOLDER_PHYS=$(CDPATH= cd -- "$HOLDER" 2>/dev/null && pwd -P) || refuse "cannot enter the holder $HOLDER — no verdict, nothing changed"
SHA=""
assert_holder() {
  local top head now
  top=$(git -C "$HOLDER" rev-parse --show-toplevel 2>/dev/null) \
    || refuse "the holder $HOLDER cannot be read as a worktree — no verdict, nothing changed"
  top=$(CDPATH= cd -- "$top" 2>/dev/null && pwd -P) || top="$top (unreadable)"
  [ "$top" = "$HOLDER_PHYS" ] \
    || refuse "the holder $HOLDER resolves to $top: its link to the repository is gone and git walked up to an enclosing checkout — no verdict, nothing changed"
  head=$(git -C "$HOLDER" symbolic-ref -q HEAD 2>/dev/null) || head=""
  [ "$head" = "refs/heads/$BRANCH" ] \
    || refuse "the holder $HOLDER is no longer on $BRANCH (HEAD: ${head:-detached}); it changed under this run — no verdict, nothing changed"
  # Every verdict below is about ONE commit, read once: a HEAD that moved between the checks and
  # the detach would otherwise be released on the strength of a proof about a different commit.
  if [ -n "$SHA" ]; then
    now=$(git -C "$HOLDER" rev-parse --verify --quiet HEAD 2>/dev/null || true)
    [ "$now" = "$SHA" ] \
      || refuse "the holder $HOLDER moved from $SHA to ${now:-?} during this run — no verdict, nothing changed"
  fi
}
assert_holder
SHA=$(git -C "$HOLDER" rev-parse --verify HEAD) || refuse "cannot read the holder's HEAD — no verdict, nothing changed"

# ---------------------------------------------------------------- would anything be stranded?
DIRTY=$(git -C "$HOLDER" status --porcelain --untracked-files=no) \
  || refuse "cannot read the status of the holder $HOLDER — no verdict, nothing changed"
if [ -n "$DIRTY" ]; then
  echo "HELD $HOLDER dirty"
  exit 1
fi

REMOTE_REF="refs/remotes/origin/$BRANCH"
if git -C "$HOLDER" rev-parse --verify --quiet "$REMOTE_REF" >/dev/null; then
  set +e
  git -C "$HOLDER" merge-base --is-ancestor "$SHA" "$REMOTE_REF"
  anc=$?
  set -e
  case "$anc" in
    0) : ;;
    1)
      n=$(git -C "$HOLDER" rev-list --count "$REMOTE_REF..$SHA") \
        || refuse "cannot count the holder's commits beyond $REMOTE_REF — no verdict, nothing changed"
      echo "HELD $HOLDER unpushed $n"
      exit 1
      ;;
    *) refuse "git merge-base failed in the holder $HOLDER (exit $anc) — no verdict, nothing changed" ;;
  esac
else
  n=$(git -C "$HOLDER" rev-list --count "$SHA") \
    || refuse "cannot count the holder's commits — no verdict, nothing changed"
  echo "HELD $HOLDER unpushed $n"
  exit 1
fi

# ---------------------------------------------------------------- release
#
# The record goes FIRST, so RELEASED always means "detached AND no record naming the holder": a
# record left behind would stop the adopting worker at its first guarded write. If the detach then
# fails, the record is put back and nothing has changed.
assert_holder
RECORD=$(git -C "$REPO" config --get "kit.worktree.${BRANCH}.path" 2>/dev/null || true)
UNSET=""
if [ -n "$RECORD" ]; then
  RECORD_PHYS=$(CDPATH= cd -- "$RECORD" 2>/dev/null && pwd -P) || RECORD_PHYS="$RECORD"
  if [ "$RECORD" = "$HOLDER" ] || [ "$RECORD_PHYS" = "$HOLDER_PHYS" ]; then
    git -C "$REPO" config --unset "kit.worktree.${BRANCH}.path" \
      || refuse "cannot unset kit.worktree.${BRANCH}.path, which names the holder $HOLDER — no verdict, nothing changed"
    UNSET=1
  fi
fi
restore_record() {
  [ -n "$UNSET" ] || return 0
  git -C "$REPO" config "kit.worktree.${BRANCH}.path" "$RECORD" \
    || printf '%s: warning: could not restore kit.worktree.%s.path=%s\n' "$TOOL" "$BRANCH" "$RECORD" >&2
}

set +e
git -C "$HOLDER" switch --quiet --detach "$SHA" >&2
sw=$?
set -e

# A zero exit is not a receipt, and a non-zero one is not a refusal: `git switch` returns a failing
# post-checkout hook's status after HEAD has already moved. The holder, read back, decides.
now=$(git -C "$HOLDER" rev-parse --verify --quiet HEAD 2>/dev/null || true)
still=$(git -C "$HOLDER" symbolic-ref -q HEAD 2>/dev/null || true)
if [ "$now" = "$SHA" ] && [ -z "$still" ]; then
  [ "$sw" -eq 0 ] \
    || printf '%s: warning: git switch exited %s (a post-checkout hook?), but the holder reads back detached at %s — released.\n' \
         "$TOOL" "$sw" "$SHA" >&2
  echo "RELEASED $HOLDER"
  exit 0
fi
restore_record
if [ "$now" = "$SHA" ] && [ "$still" = "refs/heads/$BRANCH" ]; then
  refuse "git switch --detach failed in the holder $HOLDER (exit $sw, git's message above); it is still on $BRANCH — no verdict, nothing changed"
fi
refuse "after the detach the holder $HOLDER reads HEAD=${now:-?} on ${still:-no branch}, neither on $BRANCH nor detached at $SHA — check it by hand"
