#!/usr/bin/env bash
# base-run-followup.sh — one bounded, non-polling follow-up lookup for a timeout-reasoned
# unverified base verdict (#561).
#
# WHY THIS EXISTS. `base-run-verdict.sh`'s poll loop treats two different situations as
# `timeout`: CI genuinely still pending, and CI clear but the reduced job-name signature hasn't
# repeated across two consecutive polls (the partially-posted-job-graph guard #355 already
# argues for). Under a single worker that converges inside the default 600s budget; under several
# `auto-dev` workers all pushing to the same base and sharing the same CI runners, the job graph
# for one sha can keep shifting long enough that two identical readings never happen inside the
# budget, even though the run is genuinely converging toward green. Measured on this repo,
# 2026-09-12: a 5-worker fleet run answered `unverified (timeout)` for two merges (PR #543/#521,
# PR #549/#520) whose base run had in fact already finished cleanly by the time a human
# re-checked by hand, minutes later, with exactly the lookup this script now makes.
#
# WHAT IT DOES. Exactly ONE `gh run list` lookup for the base branch, resolved BY THE EXACT SHA
# (never by recency — multiple matches resolve to the newest `createdAt`, mirroring
# `base-run-verdict.sh`'s own "reduced, newest wins" rule) — never a second poll loop, never a
# sleep. Maps the result into the SAME report-line grammar (`^(green|RED|unverified) \([a-z-]+\)$`,
# #455) `base-run-verdict.sh` already emits for its own workflow-runs fallback:
#
#   a completed, successful run for the sha           -> green (base-run)
#   a completed, failed run for the sha                -> RED (base-run)
#   no match, or the matched run has no conclusion yet
#     (still queued/in_progress), or the lookup itself
#     fails                                             -> unverified (timeout)
#   a tracker other than GitHub (#752) — no call at all  -> unverified (timeout)
#
# Any other completed conclusion (`cancelled`, `skipped`, `neutral`, `timed_out`,
# `action_required`, `stale`) falls into the last bucket too — this script's whole point is one
# extra free look at a run that was still converging, not a second CI-rule engine; a cancelled or
# otherwise inconclusive run is not evidence the base broke, so it stays a non-verdict rather than
# a fabricated red (the same doctrine `base-run-verdict.sh`'s own cancelled-run handling states).
#
# ACROSS EVERY WORKFLOW ON THE SHA, NEVER JUST THE NEWEST OVERALL. `gh run list --branch` lists
# every workflow that ran on that branch, and a push to it commonly triggers more than one
# (this repo's own `ci` and `release-please` both fire on a push to `main`, at the same sha).
# Taking the single newest entry regardless of which workflow it belongs to would let a fast,
# unrelated workflow's `success` (release-please, GitHub Pages) stand in for the actual CI run —
# exactly the `pages-build-deployment`/`release-please` trap `05b-base-run.md` already forbids one
# paragraph above this script's own call site. So matches are grouped BY WORKFLOW NAME first (the
# newest per group, mirroring `base-run-verdict.sh`'s own per-job `.latest` reduction, extended to
# workflow granularity since `gh run list` cannot see individual jobs); the verdict is `green` only
# when EVERY workflow's latest run for the sha succeeded, `RED` the instant any one of them failed,
# and `unverified (timeout)` when any is inconclusive (still running, or no run at all) — so a
# quick, unrelated workflow's `success` never launders a genuinely slow or broken one.
#
# `merge-pr` Step 5b calls this ONLY when `base-run-verdict.sh --report-line`'s own reason was
# exactly `timeout`; every other verdict/reason is unaffected and this script is never invoked for
# them. It invents no CI rule of its own — decisions/registry.json's `not_decisions` records why,
# the same reasoning as `base-run-verdict.sh`'s own entry.
#
# Usage:
#   base-run-followup.sh [-R <owner/repo>] <base-branch> <sha>
#
# ALWAYS prints exactly one report-line and exits 0 — a non-verdict is a valid answer, not a
# failure, for the same reason `base-run-verdict.sh` documents: a post-merge read must never give
# an autonomous fleet a new way to get stuck on a merge that already landed. The one refusal,
# exit 64, is a usage error before any `gh` call: no base branch, no sha, an unparseable option, or
# (mirroring `base-run-verdict.sh`) a kit whose host helper will not load (#514).
set -euo pipefail

TOOL="base-run-followup"
usage() { echo "usage: $TOOL.sh [-R <owner/repo>] <base-branch> <sha>" >&2; }
refuse() { echo "$TOOL: $1" >&2; usage; exit 64; }

# ------------------------------------------------------------------------------ self-location
#
# $0 through any symlinks first — a plugin install reaches this file by link, and `pwd -P` alone
# canonicalizes the directory, not the link. No `readlink -f`: macOS's readlink has no -f. The same
# loop `base-run-verdict.sh` (and, before it, guarded-commit.sh) already carries.
SELF="$0"
while [ -L "$SELF" ]; do
  _link=$(readlink -- "$SELF") || break
  case "$_link" in
    /*) SELF="$_link" ;;
    *)  SELF="$(dirname -- "$SELF")/$_link" ;;
  esac
done
KIT_ROOT=$(CDPATH= cd -- "$(dirname -- "$SELF")/../../.." && pwd -P) \
  || KIT_ROOT="$(dirname -- "$SELF")/../../.."

REPO=""
BASE=""
SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -R|--repo) REPO="${2:-}"; [ -n "$REPO" ] || refuse "-R needs an <owner/repo>"; shift 2 ;;
    --)        shift ;;
    -*)        refuse "unexpected option: $1" ;;
    *)
      if   [ -z "$BASE" ]; then BASE="$1"
      elif [ -z "$SHA" ];  then SHA="$1"
      else refuse "unexpected extra argument: $1 (usage: <base-branch> <sha>)"
      fi
      shift ;;
  esac
done

[ -n "$BASE" ] || refuse "no base branch given"
[ -n "$SHA" ]  || refuse "no sha given"
case "$SHA" in
  *[!0-9a-fA-F]*) refuse "'$SHA' is not a hex sha" ;;
esac

command -v jq > /dev/null 2>&1 || refuse "jq is missing — it is a \`required\` prerequisite in requirements.json"
answer() { printf '%s\n' "$1"; exit 0; }

# `gh run list` is a GitHub-only lookup (#752, kept direct like approve-runs.sh): on any other
# tracker — or one `state` cannot name — there is nothing to ask, so the answer is the non-verdict
# this script gives for every lookup that cannot speak, and nothing is called. `state` reads the
# committed profile only; it costs no network.
TRACKER_NAME=$("$KIT_ROOT/scripts/tracker-name.sh" ${REPO:+-R "$REPO"}) \
  || TRACKER_NAME=""
[ "$TRACKER_NAME" = github ] || answer "unverified (timeout)"

command -v gh > /dev/null 2>&1 || refuse "gh is missing — there is no other way to read run list"

# The repository's own host (#514): `gh run list -R OWNER/REPO` takes gh's DEFAULT host even
# inside a GitHub Enterprise checkout — the exact failure `base-run-verdict.sh`'s own header cites
# — so this resolves it the same one way every sibling script in this skill does, once, before the
# call. With no -R it keeps `KIT_REPO_SLUG` empty and `gh run list` (no -R) reads the ambient
# checkout's own remote directly, which already names the right host on its own.
GH_HOST_LIB="$KIT_ROOT/skills/_shared/scripts/_gh-host.sh"
if [ -r "$GH_HOST_LIB" ]; then . "$GH_HOST_LIB" || true; fi
command -v gh_host_resolve > /dev/null 2>&1 \
  || { echo "$TOOL: REFUSED — cannot load $GH_HOST_LIB; reinstall the kit" >&2; exit 64; }
gh_host_resolve "$REPO" || exit 64

GH_ARGS=(run list --branch "$BASE" --json headSha,conclusion,workflowName,createdAt --limit 100)
[ -n "$KIT_REPO_SLUG" ] && GH_ARGS=(-R "$KIT_REPO_SLUG" "${GH_ARGS[@]}")

# A failed or empty lookup is not evidence about the base — it is the same "nothing to act on"
# non-verdict as no match at all. `set +e` around it: this is a deliberate single try, not a poll
# loop, so nothing here should ever kill the script under `set -e`.
raw=""
rc=0
set +e
raw=$(gh "${GH_ARGS[@]}" 2>/dev/null)
rc=$?
set -e
[ "$rc" -eq 0 ] && [ -n "$raw" ] || answer "unverified (timeout)"

# Grouped by workflow, newest per group, ALL groups must have succeeded for green — see the
# ACROSS EVERY WORKFLOW comment above. An unparseable response is the same non-verdict as no
# response; `group_by` on an empty match list yields an empty array, and `all(empty[]; …)` is
# vacuously true in jq, so the empty case is named explicitly rather than falling into that trap.
word=$(printf '%s' "$raw" | jq -r --arg sha "$SHA" '
  [ .[]? | select(.headSha == $sha) ]
  | group_by(.workflowName)
  | map(sort_by(.createdAt) | last)
  | if length == 0 then "unverified"
    elif any(.[]; .conclusion == "failure") then "RED"
    elif all(.[]; .conclusion == "success") then "green"
    else "unverified"
    end
' 2>/dev/null) || word=""

case "$word" in
  green) answer "green (base-run)" ;;
  RED)   answer "RED (base-run)" ;;
  *)     answer "unverified (timeout)" ;;   # no match, still running, or the response/lookup
                                             # itself was unparseable/empty
esac
