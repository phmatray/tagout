#!/usr/bin/env bash
# auto-dev reconcile — one-shot ground truth from the tracker for the supervisor loop (Step 4).
#
# Why this exists: on EVERY wake the supervisor must reconcile its slots against the
# real merge state on the tracker. Doing that as natural-language reasoning (emit two
# queries + jq, read them, classify) is a deterministic sequence re-derived every tick —
# and every supervisor turn re-reads the whole context from cache (the dominant cost).
# Collapsing the query+classify into one command removes those turns. The supervisor
# still does the judgment (cross-ref the state file, decide end/refill/nudge/escalate).
#
# Reads through scripts/tracker.sh (#753): `pr-list` for both sections; a ready PR's merge state
# is its `mergeStateStatus` field, and only a host whose pr-list leaves it null pays one
# `pr-merge-state` call per PR. A draft prints DRAFT there without a call (GitHub's own word for a draft),
# a failed merge-state read UNKNOWN, and a failed list a named line under its header — so "no open
# PRs" and "could not ask" stay different facts.
#
# Usage: scripts/reconcile.sh
# Prints: open PRs (draft/ready + mergeStateStatus) and recently merged PRs.

set -euo pipefail

# Same convention as survey.sh: dirname "$0", deliberately not symlink-resolved.
KIT_ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd -P)"
TRACKER="$KIT_ROOT/scripts/tracker.sh"

echo "== OPEN PRs (number | DRAFT/READY | mergeState | branch | title) =="
rc=0
open=$("$TRACKER" pr-list --state open --limit 50) || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "(tracker.sh pr-list failed — exit $rc)"
else
  # join, not @tsv: @tsv escapes a backslash in a title and `read -r` would print it doubled.
  { printf '%s' "$open" | jq -r '.[] | [.number, .isDraft, .headBranch, (.mergeStateStatus // "-"), .title] | map(tostring) | join("\t")' \
    | while IFS="$(printf '\t')" read -r n draft branch mstate title; do
        if [ "$draft" = true ]; then
          kind=DRAFT; state=DRAFT
        else
          kind=READY; state=$mstate   # "-" is a null (a tab-read cannot hold an empty field)
          # A list can answer UNKNOWN for a mergeability not yet computed; pr-merge-state recomputes it.
          { [ "$state" != - ] && [ "$state" != UNKNOWN ]; } || state=$("$TRACKER" pr-merge-state "$n" 2>/dev/null </dev/null | jq -r '.mergeStateStatus // "UNKNOWN"' 2>/dev/null) || state=""
          [ -n "$state" ] || state=UNKNOWN
        fi
        printf '#%s\t%s\t%s\t%s\t%s\n' "$n" "$kind" "$state" "$branch" "$title"
      done | sort -t '#' -k2 -n; } || echo "(tracker.sh pr-list printed unreadable output)"
fi

echo
echo "== RECENTLY MERGED (last 10: number | mergedAt | title) =="
rc=0
merged=$("$TRACKER" pr-list --state merged --limit 10) || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "(tracker.sh pr-list failed — exit $rc)"
else
  printf '%s' "$merged" | jq -r '.[] | "#\(.number)\t\(.mergedAt)\t\(.title)"' \
    || echo "(tracker.sh pr-list printed unreadable output)"
fi
