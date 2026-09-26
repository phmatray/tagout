#!/usr/bin/env bash
# wire-edges.sh — wire a decomposed issue's edges on GitHub: every child as a SUB-ISSUE of the
# parent, every child's blockers as native BLOCKED_BY dependencies. Second pass of create-issue's
# decompose branch (#315): issues need numbers before they can reference each other, so the skill
# files the parent and the children first (blockers before the children they block) and then runs
# this once with the numbers it got back.
#
#   wire-edges.sh --repo <[host/]owner/repo> [--parent <N>] --child <C>[:blocked-by=<A>[,<B>…]] …
#     [--tracker <name>] [--dry-run]
#
#   Without --parent, no SUB-ISSUE edge is wired at all — only the DEP (blocked_by) edges — so
#   every --child in that mode must carry a blocked-by=; a --child with no blocker and no parent
#   has nothing to wire and is a usage error (exit 2), same as any other malformed --child.
#
#   HOST/OWNER/REPO names a GitHub Enterprise host outright; with a bare OWNER/REPO the host is the
#   checkout's own origin's, when origin is that repository. Resolved once, before the first gh
#   call, by skills/_shared/scripts/_gh-host.sh (#514).
#
# Output, one line per edge, on stdout:
#
#   SUB <parent>←<child>    ok | fallback | FAILED (HTTP <code>: <message>)
#   DEP <child>⇐<blocker>   ok | fallback | FAILED (HTTP <code>: <message>)
#
# Exit codes:
#   0   every edge is ok or fallback — the decomposition is wired as far as this host allows
#   1   any edge FAILED, or an issue's database id could not be resolved (nothing was posted after
#       that point: a POST built on a guessed id is worse than no POST)
#   2   usage — the arguments are wrong, the slug is malformed, or the kit's host helper is
#       missing; nothing was called
#
# The rules that matter:
#
#   * `fallback` is a 404 on the POST. Sub-issues and issue dependencies are GA on github.com and
#     may be absent on GHES; either endpoint answering 404 means the FEATURE is off, not that the
#     issue is missing — every issue number was already resolved to its database id through a
#     successful GET before any POST, so "issue not found" cannot reach here as a 404. The child
#     body's text `**Blocked by:** #a, #b` line (which the skill always writes, wired or not) is
#     the representation that survives, and the skill's report says so.
#   * A 422 whose message says the edge already exists is `ok`: re-running the wiring after a
#     partial run must converge, not fail. Any OTHER 422 (a cycle, a cross-repo refusal) is FAILED.
#   * Ids are DATABASE ids (resolved by the tracker's `issue-link-parent`/`issue-link-blocked-by`
#     verbs — scripts/tracker/github.sh, #507), never the `#number` and never the GraphQL node_id —
#     the dependency endpoint rejects both, and it rejects the number with a 404 that a careless
#     reader would file under "feature off".
#   * `--dry-run` prints the POSTs it would send and makes no API call — not even the id lookups —
#     so a skill can show the plan before a single write. The host helper's one gh call, `gh auth
#     token`, is a local credential lookup, so --dry-run still touches nothing on GitHub. The line
#     itself is the tracker verb's own `--dry-run` output (issue-link-parent/issue-link-blocked-by,
#     scripts/tracker/github.sh), relayed rather than re-formatted here — one home for the string.
#   * `--tracker <name>` pins the backend outright, skipping the one-time profile probe below
#     (mainly a test seam; a caller that already knows the tracker may use it too).
#
# Sources: ported from mattpocock/skills (MIT) — `engineering/to-tickets` (publish blockers first
# so edges can reference real identifiers; native blocking where the tracker has it) and
# `engineering/setup-matt-pocock-skills/issue-tracker-github.md` (the exact endpoints, and the
# database-id rule). Credit belongs to Matt Pocock; the fallback contract and the exit-code table
# are this kit's.
#
# bash 3.2 compatible (no associative arrays, no `${var,,}`, no `mapfile`). Tested by
# tests/wire-edges/test.sh through a stubbed `gh` on PATH.
set -euo pipefail

TOOL="wire-edges"

usage() {
  sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/d;s/^# \{0,1\}//;p;}' "$0"
}

refuse() {
  echo "$TOOL: REFUSED — $*" >&2
  exit 2
}

is_number() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

REPO=""
PARENT=""
DRY_RUN=0
TRACKER=""
CHILD_SPECS=""      # newline-separated "<child> <blocker> <blocker>…" records (bash 3.2: no arrays of arrays)
CHILD_COUNT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || refuse "--repo needs a value"
      REPO="$2"; shift 2 ;;
    --parent)
      [ $# -ge 2 ] || refuse "--parent needs a value"
      PARENT="$2"; shift 2 ;;
    --child)
      [ $# -ge 2 ] || refuse "--child needs a value"
      spec="$2"; shift 2
      child="${spec%%:*}"
      blockers=""
      if [ "$child" != "$spec" ]; then
        rest="${spec#*:}"
        case "$rest" in
          blocked-by=*)
            list="${rest#blocked-by=}"
            # An empty entry (`blocked-by=`, `blocked-by=,12`, a `$C1` that came back empty from a
            # failed create) must not silently wire one blocker fewer and print ok.
            case ",$list," in
              *,,*) refuse "--child '$spec': empty blocker in the list" ;;
            esac
            blockers=$(printf '%s' "$list" | tr ',' ' ') ;;
          *) refuse "--child '$spec': expected <N> or <N>:blocked-by=<A>[,<B>…]" ;;
        esac
      fi
      is_number "$child" || refuse "--child '$spec': '$child' is not an issue number"
      for b in $blockers; do
        is_number "$b" || refuse "--child '$spec': blocker '$b' is not an issue number"
        [ "$b" != "$child" ] || refuse "--child '$spec': #$child cannot be blocked by itself"
      done
      CHILD_SPECS="$CHILD_SPECS$child $blockers
"
      CHILD_COUNT=$((CHILD_COUNT + 1)) ;;
    --dry-run) DRY_RUN=1; shift ;;
    --tracker)
      [ $# -ge 2 ] || refuse "--tracker needs a value"
      TRACKER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) refuse "unknown argument '$1' (see --help)" ;;
  esac
done

[ -n "$REPO" ] || refuse "--repo <[host/]owner/repo> is required"
# HOST/OWNER/REPO is admitted here; the host helper below refuses four segments or more.
case "$REPO" in
  */|/*|*//*|*[[:space:]]*) refuse "--repo '$REPO' is not [<host>/]<owner>/<repo>" ;;
  */*) ;;
  *) refuse "--repo '$REPO' is not [<host>/]<owner>/<repo>" ;;
esac
if [ -n "$PARENT" ]; then
  is_number "$PARENT" || refuse "--parent '$PARENT' is not an issue number"
fi
[ "$CHILD_COUNT" -gt 0 ] || refuse "at least one --child is required"
printf '%s' "$CHILD_SPECS" | while read -r child blockers; do
  [ -n "$child" ] || continue
  if [ -n "$PARENT" ]; then
    [ "$child" != "$PARENT" ] || { echo "$TOOL: REFUSED — child #$child is the parent" >&2; exit 2; }
    for b in $blockers; do
      [ "$b" != "$PARENT" ] || { echo "$TOOL: REFUSED — child #$child is blocked by the parent #$PARENT; the parent is a tracking issue, never a blocker" >&2; exit 2; }
    done
  else
    [ -n "$blockers" ] || { echo "$TOOL: REFUSED — --child $child has no blockers and --parent is absent; nothing to wire" >&2; exit 2; }
  fi
done || exit 2

# -------------------------------------------------------------------- the repository's own host
#
# A direct call never infers a host, so on a GitHub Enterprise repository the id lookups and every
# POST below reached github.com (#514). Which host is talked to is decided in ONE place, the helper
# below; its exported GH_HOST is what every call inherits — including the tracker's, since this
# script's own `--repo` is already resolved to a bare OWNER/REPO by the time it reaches
# `tracker.sh --repo` (#507). Resolved AFTER every check above, so a refusal there still means
# nothing was called, and BEFORE the dry run, so it prints the normalised OWNER/REPO endpoints the
# real run would use.
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
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$SELF")" && pwd -P) || SCRIPT_DIR=$(dirname -- "$SELF")
GH_HOST_LIB="$SCRIPT_DIR/../../_shared/scripts/_gh-host.sh"
# CALLABLE, not merely readable: an empty or truncated helper sources cleanly and defines nothing.
if [ -r "$GH_HOST_LIB" ]; then . "$GH_HOST_LIB" || true; fi
command -v gh_host_resolve > /dev/null 2>&1 || refuse "cannot load $GH_HOST_LIB; reinstall the kit"
gh_host_resolve "$REPO" || exit 2
REPO="$KIT_REPO_SLUG"

# The tracker contract (#507): every edge below asks it rather than calling a host directly, so a
# GitLab or Azure DevOps backend has something to answer with instead of nothing.
TRACKER_SH="$SCRIPT_DIR/../../../scripts/tracker.sh"
[ -x "$TRACKER_SH" ] || refuse "cannot find $TRACKER_SH; reinstall the kit"

# ---------------------------------------------------------------- resolve the tracker, once (#603)
#
# Every "$TRACKER_SH" call below re-resolves the backend from the committed profile unless told
# otherwise (tracker.sh's own resolve_tracker(), which re-reads and re-parses
# .claude/skills/repo-profile.md) — one profile probe per edge, for no benefit, since the answer
# is the same every time within a single run. Resolved here ONCE — via the `state` verb, which runs
# that exact resolution and reports what it decided — and threaded through every later call as
# `--tracker`, which resolve_tracker() short-circuits on instantly. --tracker on this script's own
# command line pins it outright and skips this probe entirely.
if [ -z "$TRACKER" ]; then
  state=$("$TRACKER_SH" state create-issue) || refuse "cannot resolve the tracker: $state"
  TRACKER=$(printf '%s' "$state" | jq -r '.tracker // empty')
  [ -n "$TRACKER" ] || refuse "the tracker state probe named no tracker"
fi

# ------------------------------------------------------------------------------------- dry run
#
# Each line is the tracker verb's own --dry-run output (issue-link-parent/issue-link-blocked-by),
# relayed rather than reformatted here — one home for that line's shape, not two.
if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s' "$CHILD_SPECS" | while read -r child blockers; do
    [ -n "$child" ] || continue
    if [ -n "$PARENT" ]; then
      "$TRACKER_SH" --tracker "$TRACKER" --repo "$REPO" issue-link-parent "$PARENT" "$child" --dry-run
    fi
    for b in $blockers; do
      "$TRACKER_SH" --tracker "$TRACKER" --repo "$REPO" issue-link-blocked-by "$child" "$b" --dry-run
    done
  done
  echo "$TOOL: dry run — nothing was sent"
  exit 0
fi

# ---------------------------------------------------------------------- resolve every id, up front
#
# Database-id resolution now lives in the tracker's two link verbs (contract.json, #507) — each
# proves its own two numbers resolve before it ever posts. This pass runs the SAME edges through
# them with --resolve-only (private to this script, not part of the verb's public contract) so
# EVERY id in the whole run is proven to resolve, and cached, before the first edge is wired — a
# missing issue is reported before the first write rather than between two of them, and an issue
# named on several edges (the usual case: the parent, a blocker shared by two children) costs one
# lookup, not one per edge. TRACKER_ID_CACHE is a file of "<number> <id>" lines both this pass and
# the real wiring pass below read and grow, so no id already resolved this run is looked up twice.
IDS=$(mktemp "${TMPDIR:-/tmp}/wire-edges-ids.XXXXXX") || { echo "$TOOL: cannot create a temp file" >&2; exit 1; }
trap 'rm -f "$IDS"' EXIT
export TRACKER_ID_CACHE="$IDS"

while read -r child blockers; do
  [ -n "$child" ] || continue
  if [ -n "$PARENT" ]; then
    out=$("$TRACKER_SH" --tracker "$TRACKER" --repo "$REPO" issue-link-parent "$PARENT" "$child" --resolve-only 2>&1) \
      || { echo "$TOOL: cannot resolve the database id of #$PARENT or #$child — $out" >&2; exit 1; }
  fi
  for b in $blockers; do
    out=$("$TRACKER_SH" --tracker "$TRACKER" --repo "$REPO" issue-link-blocked-by "$child" "$b" --resolve-only 2>&1) \
      || { echo "$TOOL: cannot resolve the database id of #$child or #$b — $out" >&2; exit 1; }
  done
done <<EOF
$CHILD_SPECS
EOF

# ------------------------------------------------------------------------------------ the POSTs
#
# Each edge is now one call to the matching link verb, which prints exactly ok | fallback | FAILED
# (HTTP <code>: <message>) and exits 0 for ok/fallback, 1 for FAILED — this script only relays that
# verdict onto its own SUB/DEP line and counts it; the classification itself (the 404 → fallback
# rule, the already-wired 422) lives with the verb now (scripts/tracker/github.sh).
n_ok=0; n_fallback=0; n_failed=0
count() {
  case "$1" in
    ok*) n_ok=$((n_ok + 1)) ;;
    fallback) n_fallback=$((n_fallback + 1)) ;;
    *) n_failed=$((n_failed + 1)) ;;
  esac
}

# The loop reads from a here-string rather than a pipe so the counters survive it (a piped
# `while` runs in a subshell under bash 3.2 and 4 alike).
while read -r child blockers; do
  [ -n "$child" ] || continue
  if [ -n "$PARENT" ]; then
    verdict=$("$TRACKER_SH" --tracker "$TRACKER" --repo "$REPO" issue-link-parent "$PARENT" "$child") || true
    # Braced on purpose: macOS /bin/bash 3.2 reads the UTF-8 bytes of the arrow that follows a bare
    # `$PARENT` as part of the variable name and dies under `set -u` ("PARENT�: unbound variable")
    # — every edge, every run, while CI's bash 5 printed the line fine. `bash -n` cannot see this.
    echo "SUB ${PARENT}←${child} $verdict"
    count "$verdict"
  fi
  for b in $blockers; do
    verdict=$("$TRACKER_SH" --tracker "$TRACKER" --repo "$REPO" issue-link-blocked-by "$child" "$b") || true
    echo "DEP ${child}⇐${b} $verdict"
    count "$verdict"
  done
done <<EOF
$CHILD_SPECS
EOF

echo "$TOOL: $((n_ok + n_fallback + n_failed)) edge(s) — $n_ok ok, $n_fallback fallback, $n_failed failed"
[ "$n_failed" -eq 0 ] || exit 1
exit 0
