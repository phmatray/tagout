#!/usr/bin/env bash
# guarded-merge.sh — merge into the branch you named, and prove the merge landed there.
#
# Replaces the bare call `_shared/sync-with-main.md` used to make, which BOTH lifecycle skills
# read (implement-issue Step 8, merge-pr Step 4):
#
#     git fetch origin main
#     git merge origin/main
#
# Measured failure mode of the sibling calls (#26, incident of 2026-08-10): four agents shared
# one checkout, a concurrent `git checkout` moved HEAD between the branch creation and the
# write, and the write landed on the OTHER agent's branch with every command exiting 0. #30
# guarded the commit and the push. This is the same race on the largest write in the flow: a
# merge commit carries the whole of `main` into whatever branch HEAD happens to name, and
# reverting one out of somebody else's pull request is materially worse than moving a single
# misfiled commit.
#
# The window is also the widest here, which is why guarding only the endpoints is worth MORE
# for a merge than for a commit: `git merge` and the `git commit --no-edit` that completes a
# conflicted merge can be minutes apart, with a human or an agent editing files in between.
# Both ends of that window are guarded — this script for the merge, guarded-commit.sh for the
# completion.
#
# The branch is taken as an ARGUMENT, never derived from HEAD — deriving it would read the very
# value under suspicion, and would agree with itself no matter which branch was checked out.
#
# Usage:
#   guarded-merge.sh [-C <repo-path>] [-c <key>=<value>]… <expected-branch> -- <git merge args…>
#
#   -C <repo-path>  the worktree to merge in (default: the current directory). Passed to
#                   `git -C`; the script never `cd`s, so it works from any working directory.
#   -c <key>=<val>  a git-level config override, repeatable, passed to `git` BEFORE the
#                   subcommand — this is how the commit identity travels to the merge commit
#                   git creates on its own: `-c user.email=… -c user.name="…"`. It cannot go
#                   after `--`: `git merge` has no `-c` of its own and would reject it.
#   <expected-branch>  the branch this task owns, spelled out by the caller
#   --              everything after it goes to `git merge` verbatim (e.g. `origin/main`,
#                   `--abort`, `--continue`, `--quit`, `--no-commit`). Those first three are
#                   MERGE-STATE VERBS: they act on a merge already in flight, so they are the
#                   one case allowed to run against an unmerged index — see exit 2 below.
#
# Exit codes:
#   0  merged on <expected-branch>; prints <branch>@<short-sha>
#   2  REFUSED before merging — HEAD is another branch, or detached, or not a repo, or the index
#      already carries an unresolved merge. Nothing was written.
#   3  HEAD was NOT <expected-branch> afterwards: something moved the branch under this process.
#      The message says whether git actually wrote anything, and names where it went if so.
#   5  CONFLICTS — the expected outcome of a real sync, not a failure. HEAD is still on
#      <expected-branch> and the conflicts are left in the working tree for the caller to
#      resolve; complete the merge with `guarded-commit.sh <branch> -- --no-edit`. Never retry
#      the merge blindly on this code.
#   *  git merge's own exit code, if the merge failed for any other reason. Nothing else was
#      done.
#
# Conflicts get a code of their own precisely BECAUSE `git merge` returns 1 for them and for
# unrelated failures alike. Reusing 2 would make "refused, nothing written" ambiguous — the
# defect the review of #30 flagged for git's propagated codes. The witness is not the exit
# code but `git ls-files --unmerged`, read from the index itself — snapshotted BEFORE the merge
# as well as after, so a conflict that was already there cannot be reported as one this call
# created (git refuses such a merge outright with exit 128, and relabelling that as "a normal
# sync outcome" would send the caller to complete the WRONG merge).
#
# That is also why every path here prints a line starting `guarded-merge:` — propagating git's
# status is what the contract asks for, but git (or a hook, or a wrapper on $PATH) can itself
# return 2, 3 or 5, which would otherwise be indistinguishable from this script's own verdicts.
# **Read the message, not only the code**: a git failure always says "git merge failed (exit N)".
#
# ⚠ Unlike guarded-commit.sh, this guard does NOT require the branch to advance. "Already up to
# date" is the single most common outcome of a real sync, and `--no-commit`, `--abort` and
# `--quit` all legitimately leave the tip exactly where it was. Requiring an advance would turn
# every one of those into a false alarm, so the receipt reports the tip and lets the caller
# compare. What is asserted is where HEAD is — before and after — which is the claim the
# incident falsified.

set -euo pipefail

TOOL=guarded-merge
NOTHING="Nothing merged."

# refuse(), usage() and the branch assertion itself live in _assert-branch.sh, so all THREE guards
# share ONE definition of the invariant rather than a copy each (#44). This guard arrived with #41,
# after #44's extraction was already written against the other two, so for a while the "single
# home" had a third occupant — exactly the drift that issue predicted. This bootstrap is the one
# part that cannot be shared (it is what loads the shared part), so it is kept mechanical and
# identical to its siblings: no hand-aligned prose to drift between the three copies.
SELF="$0"
while [ -L "$SELF" ]; do
  _link=$(readlink -- "$SELF") || break
  case "$_link" in
    /*) SELF="$_link" ;;
    *)  SELF="$(dirname -- "$SELF")/$_link" ;;
  esac
done

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$SELF")" && pwd -P) || SCRIPT_DIR=$(dirname -- "$SELF")
ASSERT="$SCRIPT_DIR/_assert-branch.sh"

# Fail CLOSED, in this script's own voice — refuse() is in the file that may be missing. The test
# is whether the assertion is CALLABLE, not whether the file is readable: a truncated helper
# sources without error and defines nothing, and the first call would die with bash's exit 127,
# which appears in no exit-code table.
if [ -r "$ASSERT" ]; then . "$ASSERT" || true; fi
if ! command -v assert_branch >/dev/null 2>&1 || ! command -v refuse >/dev/null 2>&1; then
  printf '%s: REFUSED — cannot load its branch assertion, so it cannot guard anything:\n  %s\n  %s The guards are not standalone files: reinstall the kit, or restore _assert-branch.sh beside this script.\n' \
    "$TOOL" "$ASSERT" "$NOTHING" >&2
  exit 2
fi

# Printed under every refusal by the shared refuse() (#668) — the same line as the `# Usage:`
# header above, which is what a reader gets from --help.
GUARD_USAGE="guarded-merge.sh [-C <repo-path>] [-c <key>=<value>]… <expected-branch> -- <git merge args…>"

REPO="."
EXPECTED=""
GIT_OPTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -C)        [ -n "${2:-}" ] || refuse "$TOOL" "-C needs a <repo-path>"
               REPO="$2"; shift 2 ;;
    -c)        [ -n "${2:-}" ] || refuse "$TOOL" "-c needs a <key>=<value>"
               GIT_OPTS+=(-c "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; break ;;
    -*)        refuse "$TOOL" "unknown option: $1" ;;
    *)
      [ -z "$EXPECTED" ] || refuse "$TOOL" "unexpected extra argument: $1 (git merge args go after --)"
      EXPECTED="$1"; shift ;;
  esac
done

[ -n "$EXPECTED" ] || refuse "$TOOL" "an expected branch name is required: guarded-merge.sh [-C <path>] <branch> -- <git merge args…>"
[ $# -gt 0 ]       || refuse "$TOOL" "no git merge arguments given (expected: -- origin/main)"

# ---------------------------------------------------------------- assert, before anything
#
# The checks and their order live in _assert-branch.sh; the two messages stay here, because what
# an unguarded MERGE costs is not what an unguarded commit or push costs — it carries the whole of
# the merged ref into someone else's branch in one write.
# A destroyed worktree is named as one, not as a branch mismatch (#469) — see _assert-branch.sh.
assert_worktree_live "$TOOL"

assert_branch "$TOOL" \
  "HEAD is detached in $REPO — it belongs to no branch, so this merge has nowhere safe to
             land. Expected '$EXPECTED'. $NOTHING" \
  "HEAD is on '{found}' but this task owns '$EXPECTED'.
             Something checked out another branch in $REPO. Merging now would carry the whole
             of the merged ref into '{found}' and a later push would deliver it into that
             branch's pull request — the largest write this flow makes, in the wrong place.
             $NOTHING Re-check out '$EXPECTED' (in a worktree of its own) and retry."

before_sha="$head_sha"

# ---------------------------------------------------------------- assert the index, too
#
# `git ls-files --unmerged` is the witness for exit 5, and read only AFTER the merge it cannot tell
# conflicts THIS call created from conflicts that were already sitting in the index. git refuses to
# start a second merge on an unresolved one ("Merging is not possible because you have unmerged
# files", exit 128) — and relabelling that refusal as "CONFLICTS, a normal sync outcome" is worse
# than silence: the caller resolves and completes the OLD merge believing the freshly fetched base
# is now in the branch. It is not, the PR stays behind, and the build gets verified against the
# wrong base. So the index is snapshotted here, before anything runs.
#
# The merge-state verbs are the deliberate exception: `--abort`, `--continue` and `--quit` are
# precisely what you run WHEN the index is unmerged, and `--quit` even leaves it that way on
# purpose. They are recognised by exact match — a substring test would catch `--continue-on-error`
# or a branch literally named `--quit`-something in a way the caller never intended.
STATE_VERB=0
for arg in "$@"; do
  case "$arg" in
    --abort|--continue|--quit) STATE_VERB=1 ;;
  esac
done

before_conflicts=$(git -C "$REPO" ls-files --unmerged 2>/dev/null || true)

if [ -n "$before_conflicts" ] && [ "$STATE_VERB" -eq 0 ]; then
  refuse "$TOOL" "the index in $REPO already carries an UNRESOLVED merge, so this one cannot start
             (git would refuse it too, with its own exit 128). Nothing merged. Finish the merge
             that is already in flight — resolve, then
                 guarded-commit.sh -C '$REPO' <identity> '$EXPECTED' -- --no-edit
             — or abandon it with
                 guarded-merge.sh -C '$REPO' '$EXPECTED' -- --abort
             and only then sync again."
fi

# ---------------------------------------------------------------- merge

# `${GIT_OPTS[@]+…}` and not a bare `${GIT_OPTS[@]}`: under `set -u`, bash 3.2 (which is what
# /bin/bash still is on macOS) treats an empty array expansion as an unbound variable.
set +e
git -C "$REPO" ${GIT_OPTS[@]+"${GIT_OPTS[@]}"} merge "$@"
merge_rc=$?
set -e

# ---------------------------------------------------------------- assert again, after
#
# Before interpreting git's exit code, find out where HEAD is. A merge that conflicted on
# somebody else's branch is not a conflict to resolve, it is a misfiled write — and the
# conflicted working tree belongs to whoever owns that branch now.

now_branch=$(head_branch_of "$REPO")

# …and how to NAME that answer. An empty $now_branch means "detached" OR "this path can no longer
# be read as a repository at all", and after a write nothing here has ruled the second one out;
# rendering `${now_branch:-detached}` stated the first as a fact (#129). head_state measures which;
# the raw $now_branch stays the value the comparison below is made on, and head_state_unreadable
# is the shared decision the ALERT branches on — one home for it rather than a copy per guard,
# which is the mistake this issue exists to undo.
now_state=$(head_state "$REPO" "$now_branch")
unreadable=0
if head_state_unreadable "$now_branch" "$now_state"; then unreadable=1; fi

conflicts=$(git -C "$REPO" ls-files --unmerged 2>/dev/null || true)

# Collected here, with `|| true`, rather than piped into the exit-5 report below. Under
# `set -euo pipefail` a failing `git diff` (or `sed`) in that report is the LAST command of its
# block, so `set -e` would abort the script with git's status — 1 — before `exit 5` ever ran,
# and 1 is the documented "git's own failure" bucket. The caller would read the one outcome
# that means "keep going" as the one that means "stop", which is the exact ambiguity exit 5
# exists to remove. Same lesson as guarded-push.sh's `ls-remote`: verification that fails is
# not verification that passes.
conflicted_files=$(git -C "$REPO" diff --name-only --diff-filter=U 2>/dev/null || true)

if [ "$now_branch" != "$EXPECTED" ]; then
  # The sha is printed unconditionally, and FIRST. A detached HEAD is the one case where the
  # merge commit is reachable from no ref at all and will eventually be garbage-collected, so
  # it is precisely the case where withholding the sha loses the work.
  # Through the shared reader, then rendered — one spelling for the read, and the rendering as a
  # step of its own so it cannot drift from the receipt's at the bottom of the file (#129). The
  # rendered text is unchanged. `expected_now` below is a different read-kind: the EXISTENCE and
  # full sha of a branch ref, which is what the comparison against `before_sha` needs.
  head_now=$(head_sha_of "$REPO")
  new_sha=${head_now:-<unreadable>}
  expected_now=$(git -C "$REPO" rev-parse --quiet --verify "refs/heads/$EXPECTED" 2>/dev/null || true)
  {
    echo "guarded-merge: ALERT — HEAD is now '$now_state', not '$EXPECTED'."
    echo "               Something moved under this command while it was running."
    echo "               HEAD is now at: $new_sha"
    if [ -n "$now_branch" ]; then
      echo "               It is on branch '$now_branch'."
    elif [ "$unreadable" -eq 0 ]; then
      echo "               HEAD is DETACHED, so no branch points at it — it is reachable from"
      echo "               nothing and will be garbage-collected. Save it NOW:"
      echo "                   git -C '$REPO' branch <rescue-name> $new_sha"
    else
      # The third answer, which used to be printed as the second one. Everything the branch above
      # says would be false here: the merge most likely sits exactly where it was asked to go, and
      # what vanished is the PATH.
      echo "               $REPO can no longer be read as a git repository, so this guard cannot"
      echo "               say where the merge went, and must not guess. What moved may well be"
      echo "               the worktree itself — removed or renamed under this command — in which"
      echo "               case the merge is on '$EXPECTED' exactly as asked. Find the worktree"
      echo "               before you abort, reset or force-push anything."
    fi
    # Whether anything was WRITTEN is git's exit code to answer, not something to assume from
    # the branch having moved. Claiming "the merge ran" after git refused would send the caller
    # to reset an innocent branch that took nothing — the guard's own advice causing the damage
    # it exists to prevent. guarded-commit.sh consults its rc before reporting for this reason.
    if [ "$merge_rc" -eq 0 ]; then
      # `$expected_now` came back empty on an unreadable repo because the READ failed, not
      # because the branch stood still — so it may not be compared there. Same reason the
      # recovery paragraph below is withheld: every command in it names a path that is gone.
      if [ "$unreadable" -eq 1 ]; then
        echo "               git merge SUCCEEDED, but which ref carries it cannot be read from"
        echo "               here — see above."
      elif [ "$expected_now" = "$before_sha" ]; then
        echo "               git merge SUCCEEDED, and '$EXPECTED' did NOT advance — the merge"
        echo "               landed on '$now_state' instead."
      else
        echo "               git merge SUCCEEDED. Check which of the two branches carries it."
      fi
      if [ -n "$conflicts" ]; then
        echo "               The working tree also carries unresolved conflicts, and they are now"
        echo "               sitting in '$now_state'. Do not resolve them here."
      fi
      if [ "$unreadable" -eq 0 ]; then
        echo "               Recovery is a judgement call and belongs to whoever owns that branch:"
        echo "                   git -C '$REPO' merge --abort   (if the merge is still in progress)"
        echo "               or resetting it to its pre-merge tip. Do neither unless you own it,"
        echo "               and never force-push a branch you do not own."
      fi
    else
      echo "               git merge FAILED (exit $merge_rc), so THIS call wrote nothing —"
      echo "               '$now_state' took no merge and must not be reset."
      echo "               The alarming part is only that something moved under a running command."
      echo "               Get back onto '$EXPECTED' in a worktree of its own before retrying."
    fi
  } >&2
  exit 3
fi

if [ "$merge_rc" -ne 0 ]; then
  # Conflicts are the EXPECTED outcome of a real sync, so they are not folded into git's
  # failure bucket. The index is the witness, not the exit code: `git merge` answers 1 for a
  # conflict and for half a dozen unrelated refusals alike. The pre-flight above proved the
  # index was clean before this call, so anything unmerged now was created by THIS merge.
  if [ "$STATE_VERB" -eq 0 ] && [ -n "$conflicts" ]; then
    {
      echo "guarded-merge: CONFLICTS on $EXPECTED — this is a normal sync outcome, not a failure."
      echo "               HEAD is still '$EXPECTED' and the conflicted files are in the working"
      echo "               tree. Resolve them, then COMPLETE the merge (do not re-run it):"
      echo "                   guarded-commit.sh -C '$REPO' <identity> '$EXPECTED' -- --no-edit"
      echo "               To walk away instead: guarded-merge.sh -C '$REPO' '$EXPECTED' -- --abort"
      # An `if`, not `[ … ] && …`: a bare test that comes out false is a failing command, and
      # as the last one in this block it would abort the script under `set -e` — reintroducing
      # the very bug this rewrite removes, in the case where there is simply nothing to list.
      if [ -n "$conflicted_files" ]; then
        printf '%s\n' "$conflicted_files" | sed 's/^/                   /' || true
      fi
    } >&2
    exit 5
  fi
  printf 'guarded-merge: git merge failed (exit %s) on %s. Nothing else was done.\n' \
    "$merge_rc" "$EXPECTED" >&2
  exit "$merge_rc"
fi

# A zero exit with conflict entries in the index should not be reachable for a real merge, but
# "should not" is how the incident started. Report it rather than certify it.
#
# `--quit` is excluded because leaving the index unmerged is exactly what it is for: it drops
# MERGE_HEAD and keeps the conflicted files. Calling that "incomplete, resolve and complete it"
# contradicted this script's own header, which lists --quit as tip-preserving and successful —
# and would have had the caller commit a half-abandoned merge state.
if [ "$STATE_VERB" -eq 0 ] && [ -n "$conflicts" ]; then
  {
    echo "guarded-merge: CONFLICTS on $EXPECTED, even though git merge exited 0."
    echo "               Treat the merge as incomplete: resolve, then complete it with"
    echo "                   guarded-commit.sh -C '$REPO' <identity> '$EXPECTED' -- --no-edit"
  } >&2
  exit 5
fi

# No "did the branch advance?" assertion here, deliberately — see the ⚠ note in the header.
#
# The receipt is this guard's strongest claim, so it gets the shared reader and an explicit
# fallback in a statement of its own rather than a substitution inlined into printf: inlined, a
# failing read is neither aborted by `set -e` nor reflected in the statement's status, and an
# unreadable HEAD rendered `guarded-merge: a@` with a zero exit — a receipt naming no commit
# (measured, #129). Same defect, same place, as the one #116 removed from guarded-push.sh.
receipt_sha=$(head_sha_of "$REPO")
printf 'guarded-merge: %s@%s\n' "$EXPECTED" "${receipt_sha:-<unreadable>}"
