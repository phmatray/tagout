#!/usr/bin/env bash
# guarded-pr-merge.sh — merge a PR on the tracker, then decide the outcome from the PR's `state`
# read back through `tracker.sh pr-view`, never from the merge call's own exit code (#184).
#
# Both calls go through `scripts/tracker.sh` (#752): `pr-merge` to merge, `pr-view`'s lower-case
# `state`, `mergedAt` and `mergeSha` to read the outcome back. On GitHub the backend sends the argv
# this script used to send itself (`gh pr merge <n> [--repo …] <flags>`), so the text below, written
# against gh, still describes the GitHub case exactly; another tracker answers the same two verbs.
#
# `gh pr merge` does two unrelated things: it merges the PR **on GitHub**, then tidies up
# **locally** (check the base branch out, delete the merged head branch). One exit code covers
# both, so it can never say which half failed — and the local half fails on this kit's *normal*
# layout, not an exotic one: `implement-issue` gives every issue its own worktree, so the base
# branch is usually already checked out somewhere else, and gh's post-merge `git checkout`/branch
# delete then fails with a non-zero exit even though the merge landed. `merge-pr` Step 5 already
# reads the PR back for this reason ("The exit code doesn't decide — GitHub's state does", #178);
# this script is the one home for that decision, so a second caller (the auto-dev supervisor's
# takeover merge, #184) cannot carry its own — divergent — copy of the same table.
#
# The OPEN case needs a SECOND signal, not just `state`: on a repo with a merge queue, a
# successful enqueue exits 0 and leaves the PR `OPEN` until the queue lands it later, which looks
# identical to a genuine rejection if you only look at `state`. So this script also remembers
# whether the `gh pr merge` call itself exited 0, and uses that to tell the two apart.
#
# Usage:
#   guarded-pr-merge.sh [-R <[host/]owner/repo>] <PR-number> [-- <merge flags…>]
#
#   -R <[host/]owner/repo>  passed to `tracker.sh` for both `pr-merge` and `pr-view` — needed when
#                    this runs outside a git checkout of the target repo (gh cannot infer it then).
#                    On GitHub, routed through skills/_shared/scripts/_gh-host.sh (#514/#530): a bare `owner/repo`
#                    (no host prefix) used to reach `gh`'s own DEFAULT host — github.com — even
#                    inside a GitHub Enterprise checkout; a `host/owner/repo` prefix now resolves
#                    that host outright and GH_HOST is exported before either gh call either way.
#   <PR-number>      the pull request to merge.
#   --               the merge flags, passed to `tracker.sh pr-merge`. Only `--squash`,
#                    `--delete-branch`, `--subject <s>` and `--body-file <f>` are accepted;
#                    anything else (`--admin`, `--auto`, …) is refused with exit 64 before any call
#                    (#752) — a guard that forwarded any flag would forward the one that bypasses
#                    branch protection. Defaults to
#                    `--squash --delete-branch` when omitted OR given with nothing after it —
#                    every caller in this kit wants squash-merge (enforced server-side here; see
#                    the repo profile), so there is no caller-visible difference between the two.
#
# Stdout carries EXACTLY one line, the verdict — safe for a caller to capture with
# `out=$(guarded-pr-merge.sh …)` and match verbatim. Every diagnostic, including `gh pr merge`'s
# own stderr, goes to this script's stderr instead; `gh pr merge`'s stdout is discarded rather
# than interleaved, so a status line gh happens to print there can never land ahead of the verdict.
#
# Exit codes — read the printed verdict line, not just the code, when scripting around this:
#   0  MERGED      — the merge landed on GitHub, whatever `gh pr merge`'s own exit code said.
#                    Prints `MERGED <merge-commit-sha>`. Local cleanup (branch/worktree teardown)
#                    is the caller's job, same as it always was — this script only decides.
#   1  QUEUED      — PR is still `OPEN`, but the merge call itself exited 0: a successful
#                    merge-queue enqueue, not a rejection. Prints `QUEUED`. Not landed yet; poll
#                    again later, do not retry the merge and do not treat this as a failure.
#   2  REJECTED    — PR is still `OPEN` and the merge call exited non-zero: a real rejection
#                    (failing required checks, conflicts, permissions, …). Prints `REJECTED` plus
#                    the merge call's stderr. Do not force-merge; surface it and stop.
#   3  CLOSED      — the PR was closed without merging. Prints `CLOSED`. Stop and ask — merging
#                    (or retrying a merge of) a deliberately closed PR is not a safe default.
#   4  UNCONFIRMED — the state readback itself did not answer after a few attempts, or answered
#                    with something this script does not recognise. Prints `UNCONFIRMED`. This is
#                    inconclusive, not a rejection: do not tear anything down (branch, worktree,
#                    worker slot) on this exit — re-run the readback later instead of guessing.
#   64 usage/precondition error (bad arguments or merge flags, the tracker dispatcher or jq
#                    missing, a missing --body-file, a bad env override) — nothing was
#                    attempted; stdout is empty. Deliberately its own code, distinct from every
#                    outcome above (in particular 2/REJECTED): a caller branching on the exit code
#                    alone must not read "I could not even try" as "GitHub said no".
set -euo pipefail

TOOL=guarded-pr-merge

usage() {
  echo "usage: $TOOL.sh [-R <[host/]owner/repo>] <PR-number> [-- <merge flags…>]" >&2
  echo "       merge flags: --squash --delete-branch --subject <s> --body-file <f>" >&2
}

refuse() { echo "$TOOL: $1" >&2; usage; exit 64; }

# Self-location, same recipe as base-run-verdict.sh (#514/#530): follow symlinks first, `pwd -P`
# on the directory only, so a plugin install that symlinks this file in still finds
# skills/_shared/scripts/_gh-host.sh three `dirname`s up.
SELF="$0"
while [ -L "$SELF" ]; do
  _link=$(readlink -- "$SELF") || break
  case "$_link" in
    /*) SELF="$_link" ;;
    *)  SELF="$(dirname -- "$SELF")/$_link" ;;
  esac
done
# A pre-set KIT_ROOT wins: a copy run from outside the kit (guard-invocation.md's worktree-confined
# fallback) cannot find scripts/tracker.sh three dirs up from itself.
if [ -z "${KIT_ROOT:-}" ]; then
  KIT_ROOT=$(CDPATH= cd -- "$(dirname -- "$SELF")/../../.." && pwd -P) \
    || KIT_ROOT="$(dirname -- "$SELF")/../../.."
fi

# Overridable so the golden suite (tests/guarded-pr-merge/test.sh) can exercise the UNCONFIRMED
# and retry paths without real sleeps; production callers get the defaults. Validated, not just
# defaulted: a bad override must refuse loudly (exit 64) rather than reach `sleep` or `[ -le ]`
# with a value neither can make sense of — a non-numeric READBACK_SLEEP previously reached `sleep`
# as the LAST command in an `&&` chain, where `set -e` treats its failure as the whole script's.
READBACK_ATTEMPTS="${GUARDED_PR_MERGE_READBACK_ATTEMPTS:-3}"
READBACK_SLEEP="${GUARDED_PR_MERGE_READBACK_SLEEP:-2}"
case "$READBACK_ATTEMPTS" in
  ''|*[!0-9]*) refuse "GUARDED_PR_MERGE_READBACK_ATTEMPTS must be a whole number, got '$READBACK_ATTEMPTS'" ;;
esac
[ "$READBACK_ATTEMPTS" -ge 1 ] || refuse "GUARDED_PR_MERGE_READBACK_ATTEMPTS must be at least 1, got '$READBACK_ATTEMPTS'"
case "$READBACK_SLEEP" in
  ''|*[!0-9]*) refuse "GUARDED_PR_MERGE_READBACK_SLEEP must be a whole number of seconds, got '$READBACK_SLEEP'" ;;
esac

REPO=""
PR=""
MERGE_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -R)        [ -n "${2:-}" ] || refuse "-R needs an <owner/repo>"
               REPO="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; MERGE_ARGS=("$@"); break ;;
    -*)        refuse "unknown option: $1" ;;
    *)
      [ -z "$PR" ] || refuse "unexpected extra argument: $1 (merge flags go after --)"
      PR="$1"; shift ;;
  esac
done

[ -n "$PR" ] || refuse "a PR number is required"
case "$PR" in
  ''|*[!0-9]*) refuse "'$PR' is not a PR number" ;;
esac

# No `--`, or `--` followed by nothing: both mean "no opinion", so both get the kit's default.
[ "${#MERGE_ARGS[@]}" -eq 0 ] && MERGE_ARGS=(--squash --delete-branch)

# The allow-list (#752): checked before anything is called, so a refused flag means nothing ran.
set -- "${MERGE_ARGS[@]}"
while [ $# -gt 0 ]; do
  case "$1" in
    --squash|--delete-branch) shift ;;
    --subject)   [ -n "${2:-}" ] || refuse "--subject needs a value"; shift 2 ;;
    --body-file) [ -n "${2:-}" ] && [ -s "$2" ] || refuse "--body-file needs an existing, non-empty file, got '${2:-}'"
                 shift 2 ;;
    *) refuse "merge flag '$1' is not accepted — only --squash, --delete-branch, --subject <s>, --body-file <f>" ;;
  esac
done

TRACKER_SH="$KIT_ROOT/scripts/tracker.sh"
[ -x "$TRACKER_SH" ] || refuse "cannot find $TRACKER_SH; reinstall the kit"
command -v jq > /dev/null 2>&1 || refuse "jq is missing — it is a \`required\` prerequisite in requirements.json"

# The repository's own host (#514/#530): a bare `-R owner/repo` reaches gh's DEFAULT host —
# github.com — even inside a GitHub Enterprise checkout, since `-R` alone gives gh no local
# checkout to infer a host from. Decided in ONE place, before either gh call, so its exported
# GH_HOST reaches both. A `host/owner/repo` prefix on -R names the host outright and is stripped
# to OWNER/REPO for the flag gh itself receives; with no -R at all this falls through to the
# checkout's own origin host, same as every other caller of this helper.
# On GitHub only (#752, as #792 did): another tracker has no GH_HOST to resolve, so its -R is
# handed to tracker.sh as given.
GH_HOST_LIB="$KIT_ROOT/skills/_shared/scripts/_gh-host.sh"
if [ -r "$GH_HOST_LIB" ]; then . "$GH_HOST_LIB" || true; fi
command -v gh_host_resolve > /dev/null 2>&1 || refuse "cannot load $GH_HOST_LIB; reinstall the kit"
TRACKER_NAME=$("$KIT_ROOT/scripts/tracker-name.sh" ${REPO:+-R "$REPO"}) || TRACKER_NAME=""
[ -n "$TRACKER_NAME" ] || refuse "tracker.sh state could not name this repository's tracker"
if [ "$TRACKER_NAME" = github ]; then
  gh_host_resolve "$REPO" || exit 64
  REPO="$KIT_REPO_SLUG"   # empty in, empty out
fi

# ---------------------------------------------------------------- merge (exit code is a HINT,
# not a verdict — kept only to disambiguate the OPEN case below, never trusted on its own)
#
# stdout is discarded (`>/dev/null`) so a status line `gh pr merge` prints there can never land
# ahead of this script's own verdict on a caller's captured stdout. stderr is captured via the
# `2>&1 1>/dev/null` swap inside the command substitution — no temp file, so nothing to clean up
# on an early exit either.
set +e
merge_err=$("$TRACKER_SH" ${REPO:+-R "$REPO"} pr-merge "$PR" "${MERGE_ARGS[@]}" 2>&1 1>/dev/null)
merge_rc=$?
set -e

# ---------------------------------------------------------------- read the tracker's state back
attempt=1
state=""
merged_at=""
merge_sha=""
while [ "$attempt" -le "$READBACK_ATTEMPTS" ]; do
  set +e
  view_json=$("$TRACKER_SH" ${REPO:+-R "$REPO"} pr-view "$PR" 2>/dev/null \
    | jq -r '[.state, (.mergedAt // ""), (.mergeSha // "")] | @tsv' 2>/dev/null)
  view_rc=$?
  set -e
  if [ "$view_rc" -eq 0 ] && [ -n "$view_json" ]; then
    # One `jq` call above already reduced the readback to a single TSV line; `IFS=$'\t' read`
    # splits it locally with no further subprocess. `read` itself can fail (e.g. no trailing
    # newline on some shells) — `set +e` around it, same reasoning as the old per-field jq calls
    # it replaces: a malformed line is one more failed attempt, not a `set -e` abort.
    set +e
    IFS=$'\t' read -r state merged_at merge_sha <<< "$view_json"
    set -e
    [ -n "$state" ] && break
  fi
  attempt=$((attempt + 1))
  if [ "$attempt" -le "$READBACK_ATTEMPTS" ]; then
    sleep "$READBACK_SLEEP"
  fi
done

if [ -z "$state" ]; then
  echo "$TOOL: UNCONFIRMED — tracker.sh pr-view did not answer after $READBACK_ATTEMPTS attempts." >&2
  echo "       the merge call exited $merge_rc; nothing here says whether it landed. Do not tear" >&2
  echo "       anything down on this — re-run the readback later instead of guessing." >&2
  echo "UNCONFIRMED"
  exit 4
fi

case "$state" in
  merged)
    echo "$TOOL: MERGED — landed on the tracker (mergedAt=$merged_at), whatever the merge call's own" >&2
    echo "       exit code said (it was $merge_rc). Local cleanup is the caller's job." >&2
    # gh pr merge's stderr is worth reporting even on a landed merge: this is exactly the #184
    # shape (the local-cleanup half failing after the merge already succeeded), and this text is
    # what tells the reader WHICH collision it was.
    if [ "$merge_rc" -ne 0 ] && [ -n "$merge_err" ]; then
      echo "       the merge call's own stderr (informational — the merge landed regardless):" >&2
      printf '%s\n' "$merge_err" | sed 's/^/       /' >&2
    fi
    echo "MERGED ${merge_sha:-<unknown-sha>}"
    exit 0
    ;;
  open)
    if [ "$merge_rc" -eq 0 ]; then
      echo "$TOOL: QUEUED — still OPEN, but the merge call exited 0: a successful merge-queue" >&2
      echo "       enqueue, not a rejection. Not landed yet — poll again later." >&2
      echo "QUEUED"
      exit 1
    else
      echo "$TOOL: REJECTED — still OPEN and the merge call exited $merge_rc:" >&2
      [ -n "$merge_err" ] && printf '%s\n' "$merge_err" | sed 's/^/       /' >&2
      echo "       Do not force-merge; surface this and stop." >&2
      echo "REJECTED"
      exit 2
    fi
    ;;
  closed)
    echo "$TOOL: CLOSED — the PR was closed without merging while this ran." >&2
    echo "       Stop and ask; merging a deliberately closed PR is not a safe default." >&2
    echo "CLOSED"
    exit 3
    ;;
  *)
    echo "$TOOL: UNCONFIRMED — tracker.sh pr-view returned an unrecognised state '$state'." >&2
    echo "       the merge call exited $merge_rc; do not tear anything down on this." >&2
    echo "UNCONFIRMED"
    exit 4
    ;;
esac
