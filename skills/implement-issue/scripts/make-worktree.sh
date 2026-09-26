#!/usr/bin/env bash
# make-worktree.sh — implement-issue's Step 4, as one call that cannot be re-spelled.
#
# Why this exists (#280). A phase-1 worker reached Step 4, composed its own two-line
# worktree-ignore check instead of calling the kit's, got the wrong answer (git check-ignore -q
# without the trailing slash reports a non-existent directory-only pattern as "not ignored" —
# skills/_shared/worktree-ignore-check.md), and "fixed" it by committing a .gitignore edit into
# the MAIN checkout, on the user's own local branch: e0ad515, 2026-08-27, docs/desktop-launcher.
# Step 4 was, until now, entirely prose across three documents — this skill, using-git-worktrees,
# and worktree-ignore-check.md — so a worker that composed its own version instead was refused by
# nothing and was not even detectable afterwards except by reading the main checkout's reflog.
#
# This script closes that gap the way #26 closed the same gap for `git commit`: replace a bare
# command that "exits 0 whatever happens" with a program that asserts, acts, and prints a receipt.
# It runs the ignore proof through worktrees-ignored.sh and no other spelling, then creates or
# reuses this issue's worktree off the remote's real default branch (#678) and prints the
# WORKTREE=/BRANCH=/BASE= receipt Steps 5-9 need.
#
# NEVER writes to the repository's .gitignore. worktree-ignore-check.md's "Never edit the
# repository's .gitignore unasked" applies here precisely: on a refusal the fix belongs in the
# owner's history under their own review, and an agent quietly rewriting ignore rules to unblock
# itself is a worse failure than the one this script exists to prevent. On a refusal it names the
# line to add and stops — it does not add it, and it does not commit anything.
#
# Usage:
#   make-worktree.sh [-C <repo-path>] [--base <branch>] <branch>
#
#   -C <repo-path>  anywhere in the repository (never `cd`s) — the main checkout, or a
#                   subdirectory of it. Never point this at a linked worktree: main-worktree.sh
#                   resolves the main checkout's root regardless of where it is asked from, and
#                   deriving this argument from a worktree instead reproduces the fail-open
#                   worktree-ignore-check.md warns about. Default: the current directory.
#   --base <branch> the branch to create fresh off. Skips the resolution below. Without it,
#                   resolved in order (#678): the tracker's `repo` verb (`defaultBranch`, scoped to
#                   the repository -C names, never this script's own caller's cwd); otherwise
#                   `git ls-remote --symref origin HEAD` (the remote's own advertised default,
#                   asked directly — no `gh`/auth needed, and unlike a local remote-tracking ref it
#                   needs no prior `clone`/`fetch`), falling back to the local, possibly-stale
#                   `refs/remotes/origin/HEAD` only if that call itself cannot run; otherwise, only
#                   when the repository carries no `origin` remote at all, the local branch `main`
#                   (there is no remote to disagree with it); otherwise REFUSED. Whichever source
#                   answers, the branch is fetched (`git fetch -q origin <branch>`) and the
#                   worktree is created off `origin/<branch>` — never a local ref that may be
#                   stale. Ignored entirely on the reuse/attach paths below, which never create
#                   anything off a base.
#   <branch>        the branch this issue owns, already derived via the SLUG recipe
#                   (references/github-mechanics.md §5) — never composed here.
#
# Exit codes:
#   0  a worktree for <branch> exists — created fresh off the resolved default branch, or reused
#      because a worktree already matched <branch> exactly. Prints, in order:
#        WORKTREE=<absolute path>
#        BRANCH=<branch>
#        BASE=<origin/branch>       (only on a fresh create — reuse/attach resolve no base, #678)
#      A `2` (over-broad ignore rule) verdict from worktrees-ignored.sh does not change this exit
#      code — see its own contract: a different finding, not a worse one. Its note is relayed to
#      stderr.
#   2  REFUSED. Nothing was created, nothing was written to .gitignore, nothing was committed.
#        * a worktree home is not ignored (worktrees-ignored.sh's `1`, THE hazard) — the message
#          names the exact .gitignore line to add and says so; it never adds it.
#        * the ignore guard reached no verdict (`3`/`126`/`127`) — explicitly not a pass.
#        * a usage error: `-C` given no path, no <branch>, an unrecognised option, more than one
#          <branch>, <repo-path> is not a git repository, or this script cannot resolve the kit
#          root it needs to find main-worktree.sh/worktrees-ignored.sh.
#        * the default branch could not be resolved (#678): no `--base`, no tracker verdict, no
#          `origin/HEAD`, and the repository DOES carry an `origin` remote (so there is something
#          to fetch from, just no name for it) — the message says to pass `--base`.
#        * `git fetch origin <resolved-branch>` itself failed — the message names the branch.
#   *  git's own exit code, if `git worktree add` itself failed after a clean ignore verdict.
#      Nothing else was done. Kept apart from this script's own `2`, the same way guarded-commit.sh
#      keeps "git failed" apart from "this guard refused" — a caller that retries blindly on `2`
#      would otherwise retry a refusal that will never succeed unchanged.
#
# A worktree home is `.claude/worktrees/<branch>` — what this harness creates and what merge-pr
# hardcodes (worktrees-ignored.sh's own header). `.worktrees/` (the fallback home of the superpowers
# plugin's using-git-worktrees skill, which a contributor may still drive by hand) is still proven
# ignored by the call below, because worktrees-ignored.sh always checks both — this script just never
# creates a worktree there itself.

set -euo pipefail

TOOL=make-worktree
BASE_BRANCH=""
BASE_OVERRIDE=""

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

refuse() { printf '%s: REFUSED — %s\n' "$TOOL" "$*" >&2; exit 2; }

# Resolve the kit root the same way guarded-commit.sh resolves its own directory: follow symlinks
# first, `pwd -P` on the directory only (never on the script link itself), so a plugin install
# that symlinks this file in still finds its siblings. This script lives at
# <kit>/skills/implement-issue/scripts/make-worktree.sh, so three `dirname`s up is the kit root —
# true whether this copy runs from the main checkout's scripts/ or from an identical copy sitting
# inside a linked worktree (same relative layout either way).
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
WORKTREES_IGNORED_SH="$KIT_ROOT/scripts/worktrees-ignored.sh"
[ -x "$MAIN_WORKTREE_SH" ] \
  || refuse "missing or not executable: $MAIN_WORKTREE_SH — the guards are not standalone files; reinstall the kit."
[ -x "$WORKTREES_IGNORED_SH" ] \
  || refuse "missing or not executable: $WORKTREES_IGNORED_SH — the guards are not standalone files; reinstall the kit."

REPO="."
BRANCH=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -C)        [ -n "${2:-}" ] || refuse "-C needs a <repo-path>"
               REPO="$2"; shift 2 ;;
    --base)    [ -n "${2:-}" ] || refuse "--base needs a <branch>"
               BASE_OVERRIDE="$2"; shift 2 ;;
    --)        shift ;;   # NOT `break`: unlike guarded-commit.sh, nothing after `--` is passed
               # through verbatim to a downstream command — it is still this script's own
               # <branch> positional, so parsing must continue rather than stop.
    -*)        refuse "unknown option: $1" ;;
    *)
      [ -z "$BRANCH" ] || refuse "unexpected extra argument: $1 (only one <branch> is accepted)"
      BRANCH="$1"; shift ;;
  esac
done

[ -n "$BRANCH" ] || refuse "a branch name is required: make-worktree.sh [-C <path>] <branch>"

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || refuse "$REPO is not a git repository"

# ---------------------------------------------------------------- resolve the main checkout
#
# Never derived from a linked worktree — see the usage note above and worktree-ignore-check.md's
# own warning. main-worktree.sh is the one home for this derivation (#125); this is a caller, not
# a fifth re-spelling of it.

set +e
REPO_ROOT=$("$MAIN_WORKTREE_SH" -C "$REPO")
mw_rc=$?
set -e
[ "$mw_rc" -eq 0 ] \
  || refuse "the main checkout could not be resolved from $REPO (main-worktree.sh exit $mw_rc) — no verdict was reached"

# ---------------------------------------------------------------- prove the home is ignored
#
# A BARE repository has no main working tree — main-worktree.sh then prints nothing, per its own
# contract. `git add -A` cannot run there, so no worktree home is reachable and there is nothing
# to check (worktree-ignore-check.md's own carve-out). $REPO stands in for the base every later
# command below is run against, resolved to an absolute path the same way the non-bare case
# already is.
if [ -n "$REPO_ROOT" ]; then
  set +e
  ignore_out=$("$WORKTREES_IGNORED_SH" -C "$REPO_ROOT" 2>&1)
  ignore_rc=$?
  set -e

  case "$ignore_rc" in
    0)
      : # every worktree home ignored, the rule was not broadened — nothing to relay
      ;;
    2)
      # A different finding, not a worse one (worktree-ignore-check.md): no #43 hazard here, so
      # proceed — but the note (the profile cost of the broadened rule) still belongs on stderr.
      printf '%s\n' "$ignore_out" | sed 's/^/  /' >&2
      ;;
    1)
      # THE hazard this whole script exists to close. Never add the line ourselves — name it and
      # stop. `homes` can hold one or two lines: worktrees-ignored.sh checks both `.claude/worktrees/`
      # and `.worktrees/` and does not stop at the first failure, so either or both may be missing.
      homes=$(printf '%s\n' "$ignore_out" | sed -n 's/.*fix: add "\(.*\)" to \.gitignore\.$/\1/p')
      {
        printf '%s: REFUSED — a worktree home is not ignored in %s. Add this line yourself and re-run:\n' \
          "$TOOL" "$REPO_ROOT"
        printf '%s\n' "$homes" | sed 's/^/  /'
        printf '\n'
        printf '%s\n' "$ignore_out" | sed 's/^/  /'
      } >&2
      exit 2
      ;;
    *)
      refuse "the ignore guard reached no verdict (exit $ignore_rc), which is not a pass:
$ignore_out"
      ;;
  esac
else
  REPO_ROOT=$(CDPATH= cd -- "$REPO" && pwd -P) || refuse "internal: cannot resolve an absolute path for $REPO"
fi

# ---------------------------------------------------------------- create or reuse
#
# Exact match on the branch column — references/github-mechanics.md §5: a bare `grep -F` matches
# substrings and the path column too, so `feat/26-guard` would "resume" into
# feat/26-guarded-git-writes' worktree. `substr($0, 10)` (not a field split) keeps a path
# containing a space intact, the same reason main-worktree.sh avoids `awk '{print $2}'`.
WT_LIST=$(git -C "$REPO_ROOT" worktree list --porcelain)
EXISTING=$(printf '%s\n' "$WT_LIST" | awk -v b="branch refs/heads/$BRANCH" '
  /^worktree / { path = substr($0, 10) }
  $0 == b { print path; exit }
')

# git's own admin metadata can outlive the directory it names — a hand deletion, a partial
# teardown — and `git worktree list` still reports it for this branch (usually `prunable`).
# Reusing that path blindly would exit 0 naming a WORKTREE Steps 5-9 then fail to -C into, with
# this script itself reporting the false success. Prune the stale record and fall through to
# create fresh, exactly as if the exact-match test above had found nothing.
if [ -n "$EXISTING" ] && [ ! -d "$EXISTING" ]; then
  git -C "$REPO_ROOT" worktree prune
  EXISTING=""
fi

if [ -n "$EXISTING" ]; then
  WORKTREE="$EXISTING"
else
  WORKTREE="$REPO_ROOT/.claude/worktrees/$BRANCH"
  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    # The branch already exists with no worktree attached — most often the prune just above
    # (its worktree was deleted by hand, the branch was not), or a prior run that created the
    # branch and crashed before finishing. `git worktree add -b` REFUSES a branch that already
    # exists, so attach a fresh worktree to it instead of trying to create it again. No base to
    # resolve here — the branch already has a tip, and attaching must not move it.
    set +e
    git -C "$REPO_ROOT" worktree add -q "$WORKTREE" "$BRANCH"
    add_rc=$?
    set -e
    if [ "$add_rc" -ne 0 ]; then
      printf '%s: git worktree add failed (exit %s) attaching existing branch %s. Nothing else was done.\n' \
        "$TOOL" "$add_rc" "$BRANCH" >&2
      exit "$add_rc"
    fi
  else
    # ---------------------------------------------------------- resolve the base branch (#678)
    #
    # Never a hardcoded local `main`: a repository whose real default branch is something else, or
    # whose local `main` is a stale leftover ref, otherwise gets a fresh worktree built on the
    # wrong commit — silently, since `git worktree add -b … main` only fails when `main` is
    # entirely absent. Order: `--base` wins; otherwise the tracker's own `repo` verb
    # (`defaultBranch`); otherwise the remote's own advertised HEAD; otherwise, only when this
    # repository carries NO `origin` remote at all, today's local `main` (there is no remote to
    # disagree with it); otherwise refuse rather than guess.
    HAS_ORIGIN=0
    git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1 && HAS_ORIGIN=1

    if [ -n "$BASE_OVERRIDE" ]; then
      BASE_BRANCH="$BASE_OVERRIDE"
    else
      TRACKER_SH="$KIT_ROOT/scripts/tracker.sh"
      if [ -x "$TRACKER_SH" ] && command -v jq >/dev/null 2>&1; then
        # Scoped to $REPO_ROOT via a subshell `cd` — tracker.sh has no `-C` of its own and reads
        # the repository from cwd; left unscoped, this call would answer for whatever directory
        # invoked make-worktree.sh (e.g. a caller's own checkout) instead of the repository -C
        # names.
        set +e
        TRACKER_OUT=$(cd "$REPO_ROOT" && "$TRACKER_SH" repo 2>/dev/null)
        tracker_rc=$?
        set -e
        if [ "$tracker_rc" -eq 0 ]; then
          # `set +e`/`set -e` around the parse too, like every other fallible call in this block:
          # `jq -r` exits non-zero (5) on stdout that fails to parse as JSON, and a bare assignment
          # under `set -euo pipefail` would let a malformed tracker response kill this script with
          # jq's own exit code instead of falling through to the ls-remote/origin-HEAD/refuse chain
          # below (a future non-github backend is exactly the case the kit's own header names).
          set +e
          BASE_BRANCH=$(printf '%s' "$TRACKER_OUT" | jq -r '.defaultBranch // empty' 2>/dev/null)
          set -e
        fi
      fi
      if [ -z "$BASE_BRANCH" ] && [ "$HAS_ORIGIN" -eq 1 ]; then
        # Ask the remote directly rather than trust a local cache: `refs/remotes/origin/HEAD` is
        # only ever written by `git clone` or `git remote set-head` — a remote added by hand and
        # pushed to (never cloned) leaves nothing there even though the remote itself answers
        # immediately. `ls-remote --symref` asks it, one lightweight round trip (or none at all for
        # a local path), no `gh`/auth needed, and it also self-heals a rename `origin/HEAD` missed.
        set +e
        SYMREF_OUT=$(git -C "$REPO_ROOT" ls-remote --symref origin HEAD 2>/dev/null)
        set -e
        BASE_BRANCH=$(printf '%s\n' "$SYMREF_OUT" | awk '$1=="ref:"{print $2; exit}')
        BASE_BRANCH="${BASE_BRANCH#refs/heads/}"
      fi
      if [ -z "$BASE_BRANCH" ]; then
        # Last-ditch offline fallback if `ls-remote` itself could not be run.
        set +e
        HEAD_REF=$(git -C "$REPO_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
        set -e
        BASE_BRANCH="${HEAD_REF#origin/}"
      fi
      if [ -z "$BASE_BRANCH" ]; then
        if [ "$HAS_ORIGIN" -eq 0 ]; then
          BASE_BRANCH=main   # no remote to distrust — today's exact behaviour, unchanged
        else
          refuse "could not resolve the default branch; pass --base"
        fi
      fi
    fi

    if [ "$HAS_ORIGIN" -eq 1 ]; then
      git -C "$REPO_ROOT" fetch -q origin "$BASE_BRANCH" \
        || refuse "could not fetch origin/$BASE_BRANCH — check the branch name and the remote"
      BASE_REF="origin/$BASE_BRANCH"
    else
      BASE_REF="$BASE_BRANCH"
    fi

    set +e
    git -C "$REPO_ROOT" worktree add -q "$WORKTREE" -b "$BRANCH" "$BASE_REF"
    add_rc=$?
    set -e
    if [ "$add_rc" -ne 0 ]; then
      printf '%s: git worktree add failed (exit %s) for %s off %s. Nothing else was done.\n' \
        "$TOOL" "$add_rc" "$BRANCH" "$BASE_REF" >&2
      exit "$add_rc"
    fi
  fi
fi

# Record the tree's absolute path in the COMMON .git/config, keyed by branch, so the guards can
# tell a destroyed-and-relocated worktree from a healthy one (#469): the record outlives the tree
# it describes, which is the whole point. The `.path` third component keeps a `/` in the branch
# name inside git's subsection, where any character is allowed. Not fatal — this script's
# contract is to produce a worktree — but never silent.
WORKTREE_ABS=$(CDPATH= cd -- "$WORKTREE" && pwd -P) || WORKTREE_ABS="$WORKTREE"
git -C "$REPO_ROOT" config "kit.worktree.${BRANCH}.path" "$WORKTREE_ABS" \
  || printf '%s: warning: could not record kit.worktree.%s.path — the mid-run liveness guard (#469) will not cover this tree.\n' \
       "$TOOL" "$BRANCH" >&2

printf 'WORKTREE=%s\n' "$WORKTREE"
printf 'BRANCH=%s\n' "$BRANCH"
# Only meaningful when this run actually built the branch off a base — reuse and attach keep the
# branch's existing tip and resolve no base at all. An `if`, not a trailing `&&`: as the script's
# last statement, a bare `[ -n … ] && printf …` would leave the FAILED `[ -n … ]` as the last
# command actually executed whenever there is no base to report, and bash then exits with ITS
# status (1) instead of the 0 this whole run earned.
if [ -n "${BASE_REF:-}" ]; then
  printf 'BASE=%s\n' "$BASE_REF"
fi
