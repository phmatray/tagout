#!/usr/bin/env bash
# approve-runs.sh — approve a run stuck at `needs-approval`, ONLY for this repository's own
# release automation (#495, #622).
#
# WHY THIS EXISTS. `ci.verdict` files a completed run whose conclusion is `action_required` under
# the third, non-terminal verdict `needs-approval` (#495) rather than under `failed` — GitHub uses
# that conclusion for a workflow run awaiting a maintainer's approval (first-time contributors, or
# a bot-authored PR under "require approval for all outside collaborators"). Nothing a push can
# change clears it; only an approval can. Measured on this repo, 2026-09-09: every release-please
# rebase PR lands here (PR #475, runs `ci` 34386269369 and `release-title` 34386269395), so the
# release cut is the one PR the kit's own `merge-pr` could not land without a human's `gh api -X
# POST … /approve` typed by hand.
#
# WHAT IT DOES. Given a PR number, it reads the PR's author and head sha, finds every check-run on
# that sha whose workflow run is stuck `action_required`, and — ONLY when the PR is this
# repository's own release PR — approves each one. That is either a recognised release-bot login, or
# the three-fact conjunction at `is_own_release_pr` below (#622). Otherwise it refuses and prints the
# run ids plus the manual remedy, never approving anything: approving a stranger's workflow run
# executes THEIR code with this repository's secrets (an untrusted PR is exactly the case GitHub
# invented the approval gate for), so the one caller this script trusts is the automation whose
# every PR is generated from this repo's own release-please config, never an external contributor.
#
# WHY BY WORKFLOW RUN, NOT BY CHECK-RUN. The approval gate lives on the *workflow run*
# (`actions/runs/<id>/approve`), and one workflow run can post several check-runs (jobs) — approving
# is idempotent per run, so each run id is approved once even if several of its jobs are
# `action_required`. `actions/runs?head_sha=` is the same sha-keyed endpoint `base-run-verdict.sh`
# already falls back to (#479) — never `gh run list --branch`, which answers by recency and would
# name a sibling PR's run under a merge train.
#
# WHY THE AUTHOR CHECK IS FIRST, AND FAILS CLOSED. `gh pr view --json author` is one read, done
# before any run is even looked at, so an unrecognised caller gets refused before this
# script has learned anything an attacker could use. An unrecognized author, an empty answer, and a
# `gh` failure all refuse identically (exit 2) — ADR 0002's fail-closed default: a write that runs
# arbitrary code on this repository's secrets stays fail-closed, unlike the read-only gates modelled
# on the SAME ADR that fail open.
#
# Exit codes:
#   0   the PR is this repo's own release PR: `approved <id>` per action_required run (0, 1 or many),
#       or `approved 0 run(s)` when the sha carries none
#   1   a `gh` call failed AFTER the author check passed — never retried; the caller re-runs
#   2   REFUSED — the PR is not this repo's own release PR; the run ids and the manual remedy are
#       printed, nothing is approved
#  64   usage error: no PR number, an unparseable option, a malformed -R slug, or
#       skills/_shared/scripts/_gh-host.sh cannot be loaded
set -euo pipefail

TOOL="approve-runs"
RELEASE_BOT="release-please[bot]"

usage() { echo "usage: $TOOL.sh [-R <[host/]owner/repo>] <pr-number>" >&2; }
refuse_usage() { echo "$TOOL: $1" >&2; usage; exit 64; }

# ------------------------------------------------------------------------------ 1. self-location
#
# $0 through any symlinks first (lifted from base-run-verdict.sh, where the loop was debugged): a
# plugin install reaches this file by link, and `pwd -P` alone canonicalizes the directory, not the
# link. No `readlink -f` — macOS's readlink has none.
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

# ------------------------------------------------------------------------------ 2. the arguments
PR=""
REPO=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -R|--repo) REPO="${2:-}"; [ -n "$REPO" ] || refuse_usage "-R needs an <owner/repo>"; shift 2 ;;
    --) shift ;;
    -*) refuse_usage "unexpected option: $1" ;;
    *)
      [ -z "$PR" ] || refuse_usage "two PR numbers given: '$PR' and '$1' — one call approves one PR's runs"
      PR="$1"; shift ;;
  esac
done

[ -n "$PR" ] || refuse_usage "no PR number given"
case "$PR" in ''|*[!0-9]*) refuse_usage "'$PR' is not a PR number" ;; esac

command -v gh > /dev/null 2>&1 || refuse_usage "gh is missing — there is no other way to read or approve a run"

# Same host resolution as base-run-verdict.sh (#514): `gh api` never infers a host, so a GitHub
# Enterprise repo needs it decided once, before any read. CALLABLE, not merely readable.
GH_HOST_LIB="$KIT_ROOT/skills/_shared/scripts/_gh-host.sh"
if [ -r "$GH_HOST_LIB" ]; then . "$GH_HOST_LIB" || true; fi
command -v gh_host_resolve > /dev/null 2>&1 \
  || { echo "$TOOL: REFUSED — cannot load $GH_HOST_LIB; reinstall the kit" >&2; exit 64; }
gh_host_resolve "$REPO" || exit 64

OWNER_REPO="{owner}/{repo}"
[ -n "$REPO" ] && OWNER_REPO="$KIT_REPO_SLUG"
REPO_FLAG=()
[ -n "$REPO" ] && REPO_FLAG=(-R "$REPO")

# --------------------------------------------------------------------- 3. who authored this PR
#
# One read, before anything else is asked — a caller that fails this check learns nothing about
# which runs exist. `gh pr view` takes `-R`; `gh api` does NOT (it has no --repo flag at all, only
# --hostname) — its repository is the one named in the URL path, and GH_HOST, exported by
# gh_host_resolve above, reaches it. Passing -R to `gh api` aborts the call with
# `unknown shorthand flag: 'R'`, which every caller here then reads as a failed API read.
pr_json=$(gh pr view ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} "$PR" --json author,headRefOid,headRefName,files,changedFiles 2>&1) || {
  echo "$TOOL: could not read PR #$PR: $pr_json" >&2
  exit 1
}
author=$(printf '%s' "$pr_json" | jq -r '.author.login // ""')
sha=$(printf '%s' "$pr_json" | jq -r '.headRefOid // ""')
[ -n "$sha" ] || { echo "$TOOL: PR #$PR has no head sha" >&2; exit 1; }

branch=$(printf '%s' "$pr_json" | jq -r '.headRefName // ""' | tr -d '\r')

# --- is this the repository's OWN release automation? --------------------------------------------
#
# release-please posts through the default GITHUB_TOKEN, so its PRs are authored by
# `app/github-actions` and never by `$RELEASE_BOT` — which is why the login check above was dead
# code on its only caller (#622; measured landing 3.0.1, PR #621).
#
# That login is NOT evidence on its own: every workflow using the default token opens PRs under it,
# so accepting it alone would approve any bot-authored PR in the repository. What is accepted here
# is a CONJUNCTION of three facts that an outside contributor cannot hold together:
#
#   1. the author is that login;
#   2. the head branch is named like a release-please branch. On a same-repo PR only something with
#      push access can create that name; on a FORK the name is the contributor's to choose, so this
#      conjunct carries little weight on its own — it is the author and the path set that do the
#      work, and all three must hold.
#   3. EVERY changed path is one this repository's own release-please-config.json declares
#      release-please will touch — its changelog, its extra-files, and the manifest itself.
#
# The config is read from the repository's DEFAULT branch, never from the PR's own head: a PR that
# could widen the allowlist it is judged against would be no allowlist at all. Anything unreadable,
# unparseable, or empty refuses — ADR 0002's fail-closed default, the same posture as the login
# check, because the write being gated still runs a workflow with this repository's secrets.
is_own_release_pr() {
  [ "$author" = "app/github-actions" ] || return 1
  case "$branch" in release-please--*) : ;; *) return 1 ;; esac

  local cfg allow changed undeclared
  cfg=$(gh api           "repos/$OWNER_REPO/contents/release-please-config.json"           -H "Accept: application/vnd.github.raw" 2>/dev/null) || return 1
  [ -n "$cfg" ] || return 1

  # The manifest is release-please's own bookkeeping and is not declared inside the config.
  allow=$(printf '%s' "$cfg" | jq -c '
    [ (.packages // {}) | to_entries[]
      | (if .key == "." then "" else .key + "/" end) as $dir
      | [ $dir + (.value["changelog-path"] // "CHANGELOG.md") ]
        + [ (.value["extra-files"] // [])[]
            | (if type == "string" then . else .path end)
            | select(. != null) | $dir + . ]
      | .[]
    ] | unique' 2>/dev/null) || return 1
  # Checked BEFORE the manifest is appended: a config of `{}` parses fine and declares nothing, and
  # appending first would leave `allow` permanently non-empty, so this guard could never fire on a
  # parseable config. A config that declares no package declares no allowlist.
  case "$allow" in ''|'[]') return 1 ;; esac
  allow=$(printf '%s' "$allow" | jq -c '. + [ ".release-please-manifest.json" ] | unique') || return 1

  # Counted inside jq rather than iterated line by line: one scalar out, so a jq build whose output
  # carries CR (Windows) cannot turn a set comparison into a false accept.
  changed=$(printf '%s' "$pr_json" | jq -r '[ .files[]?.path ] | length' 2>/dev/null | tr -d '\r')
  undeclared=$(printf '%s' "$pr_json" | jq -r --argjson allow "$allow"     '[ .files[]?.path ] - $allow | length' 2>/dev/null | tr -d '\r') || return 1

  # `files` is a PAGE, not the diff: GitHub caps it, and a capped list is one whose undeclared paths
  # are simply not present to be seen — the guard would then approve on the strength of a prefix.
  # `changedFiles` is the authoritative count, so a disagreement between them means the question was
  # never fully answered, and an unanswered question is not a match.
  total=$(printf '%s' "$pr_json" | jq -r '.changedFiles // -1' 2>/dev/null | tr -d '
')

  # A PR that reports NO changed files proves nothing about what it would run; it is not an
  # allowlist match, it is a missing answer.
  case "$changed" in ''|*[!0-9]*) return 1 ;; esac
  case "$undeclared" in ''|*[!0-9]*) return 1 ;; esac
  case "$total" in ''|*[!0-9]*) return 1 ;; esac
  [ "$changed" -eq "$total" ] || return 1
  [ "$changed" -gt 0 ] && [ "$undeclared" -eq 0 ]
}

case "$author" in
  "$RELEASE_BOT"|"app/release-please") : ;;
  *) if is_own_release_pr; then : ; else
    # Find the runs so the refusal names them, but approve nothing — the point of refusing.
    runs_json=$(gh api "repos/$OWNER_REPO/actions/runs?head_sha=$sha&per_page=100" 2>/dev/null) || runs_json=""
    ids=$(printf '%s' "$runs_json" | jq -r '[ .workflow_runs[]? | select(.conclusion == "action_required") | .id ] | join(", ")' 2>/dev/null || true)
    [ -n "$ids" ] || ids="(could not list them)"
    echo "$TOOL: REFUSED — PR #$PR's author is '$author', not the release bot ('$RELEASE_BOT')." >&2
    echo "$TOOL: approving a stranger's workflow run executes their code with this repo's secrets." >&2
    # Without this line a genuine release PR carrying one stray path is told only that its author is
    # wrong — the exact unhelpful message #622 was filed about, one conjunct further along.
    if [ "$author" = "app/github-actions" ]; then
      echo "$TOOL: it is also not recognised as this repo's own release PR: that needs a" >&2
      echo "$TOOL:   release-please--* head branch (this one is '$branch') AND every changed path" >&2
      echo "$TOOL:   declared by release-please-config.json on the default branch." >&2
    fi
    echo "$TOOL: run id(s) awaiting approval: $ids" >&2
    echo "$TOOL: manual remedy: gh api -R $OWNER_REPO -X POST repos/$OWNER_REPO/actions/runs/<id>/approve" >&2
    exit 2
     fi ;;
esac

# ------------------------------------------------------------------- 4. approve, per workflow run
#
# Keyed on the sha, exactly like base-run-verdict.sh's own workflow-runs fallback (#479) — never
# `gh run list --branch`, which answers by recency and would name a sibling PR's run under a merge
# train sharing the same base branch.
runs_json=$(gh api "repos/$OWNER_REPO/actions/runs?head_sha=$sha&per_page=100" 2>&1) || {
  echo "$TOOL: could not list workflow runs for $sha: $runs_json" >&2
  exit 1
}
# `tr -d` on the ids: the Windows jq binary terminates every line with CRLF, so each id would
# reach the loop below as `12345\r` and be POSTed to `…/runs/12345%0D/approve`, which 404s. The
# ids are digits by construction, so stripping CR cannot discard anything meaningful.
ids=$(printf '%s' "$runs_json" | jq -r '[ .workflow_runs[]? | select(.conclusion == "action_required") | .id ] | unique | .[]' | tr -d '\r')

if [ -z "$ids" ]; then
  echo "approved 0 run(s)"
  exit 0
fi

while IFS= read -r id; do
  [ -n "$id" ] || continue
  out=$(gh api -X POST "repos/$OWNER_REPO/actions/runs/$id/approve" 2>&1) || {
    echo "$TOOL: could not approve run $id: $out" >&2
    exit 1
  }
  echo "approved $id"
done <<< "$ids"
