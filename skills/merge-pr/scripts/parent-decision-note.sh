#!/usr/bin/env bash
# skills/merge-pr/scripts/parent-decision-note.sh — when a merged child's issue belongs to a
# decomposed tracking parent (#315), append one line recording what it settled to the parent's
# `## Decisions so far` section (#365). A no-op for the overwhelming majority of merges, which
# aren't part of a decomposed epic at all.
#
# Usage:
#   parent-decision-note.sh [-R <[host/]owner/repo>] <child-issue-number> <pr-number> [<[host/]owner/repo>]
#
#   The repository is named EITHER by a leading -R, the spelling guarded-pr-merge.sh and
#   base-run-verdict.sh already take and that `merge-pr` reads two calls before this one, OR
#   positionally, the way every existing caller writes it. Both at once is refused rather than
#   silently preferring one (#668).
#
#   HOST/OWNER/REPO names a GitHub Enterprise host outright; with a bare OWNER/REPO the host is the
#   checkout's own origin's, when origin is that repository. Resolved once, before the first
#   tracker call, by skills/_shared/scripts/_gh-host.sh (#514) — on GitHub only; another tracker
#   gets the slug as given.
#
# Every read and write goes through `scripts/tracker.sh` (#752), so this runs on any tracker whose
# backend answers `issue-parent`, `issue-view`, `pr-view` and `issue-edit-body`.
#
# What it does, in order:
#   1. Asks the tracker for the child's parent (`issue-parent`): a number is the parent, `none` →
#      prints `no-parent` and exits 0 (the common path). `fallback` — the host has no native parent
#      link, or its sub-issues API is off — reads the child's body instead: a first line
#      `Part of #N …` names the parent; without one, prints `no-parent` (a stderr note says why).
#      A cross-repository parent is refused inside the backend (#781), and that refusal fails here.
#   2. Parent present → reads the merged PR's title and url (`pr-view`) and the parent's current
#      body (`issue-view`).
#   3. Idempotency: if the body already carries this PR's own marker (`[#<pr>]`), prints
#      `already-noted` and exits 0 without writing anything — a re-run of `merge-pr` on an
#      already-merged PR must not duplicate the line.
#   4. Otherwise appends `- #<child> — <title, trimmed of its trailing "(#issue) (#PR)"> ([#<PR>](<url>))`
#      to the `## Decisions so far` section, creating the section (at the end of the body) if the
#      parent doesn't have one yet. Writes the new body to a temp file and sends it with
#      `issue-edit-body --body-file`, then reads the body back (`issue-view`) to confirm it landed.
#
# Exit codes:
#   0   success — appended, already-noted, or no-parent (all three are success, never confused with
#       a genuine failure by a caller that only checks the exit code)
#   1   a real failure: a tracker call failed, returned unparseable JSON, or the parent's body could
#       not be safely read or the write could not be confirmed. Always a `parent-decision-note:`
#       prefixed line on stderr, under the backend's own.
#   2   usage — bad arguments, a malformed slug, or the kit's host helper or scripts/tracker.sh
#       missing; nothing was called.
#
# bash 3.2 compatible (no associative arrays, no `${var,,}`, no `mapfile`). Tested by
# tests/merge-pr-parent/test.sh through a stubbed `gh` on PATH, behind the real GitHub backend.
set -euo pipefail

TOOL="parent-decision-note"

usage() {
  sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/d;s/^# \{0,1\}//;p;}' "$0"
}

# The one-line shape, printed UNDER every refusal (#668): the refusals already said what was wrong,
# and none of them said what right looks like, so a wrong shape cost a turn instead of a correction.
usage_line() {
  echo "usage: $TOOL.sh [-R <[host/]owner/repo>] <child-issue-number> <pr-number> [<[host/]owner/repo>]" >&2
  echo "       (the repository is given ONE way or the other, never both)" >&2
}

refuse() {
  echo "$TOOL: REFUSED — $*" >&2
  usage_line
  exit 2
}

fail() {
  echo "$TOOL: $*" >&2
  exit 1
}

is_number() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

REPO_OPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -R) [ $# -ge 2 ] || refuse "-R needs a <[host/]owner/repo>"; REPO_OPT="$2"; shift 2 ;;
    -R*) REPO_OPT="${1#-R}"; shift ;;
    --) shift; break ;;
    -*) refuse "unknown option '$1'" ;;
    *) break ;;
  esac
done

if [ -n "$REPO_OPT" ]; then
  # With -R the slug is already in hand, so only the two numbers are left. A third positional is a
  # SECOND repository, which is the shape the field reports carry; refusing it by name beats
  # preferring one of two slugs that may not agree.
  [ $# -ne 3 ] || refuse "repository given twice: -R $REPO_OPT and positional $3"
  [ $# -eq 2 ] || refuse "expected 2 arguments after -R <[host/]owner/repo>, got $#: <child-issue-number> <pr-number>"
  CHILD="$1"
  PR="$2"
  REPO="$REPO_OPT"
else
  # Unchanged, wording included: three field refusals quote this line verbatim.
  [ $# -eq 3 ] || refuse "expected 3 arguments, got $#: <child-issue-number> <pr-number> <[host/]owner/repo>"
  CHILD="$1"
  PR="$2"
  REPO="$3"
fi

is_number "$CHILD" || refuse "'$CHILD' is not an issue number"
is_number "$PR" || refuse "'$PR' is not a PR number"
# HOST/OWNER/REPO is admitted here; the host helper below refuses four segments or more.
case "$REPO" in
  */|/*|*//*|*[[:space:]]*) refuse "'$REPO' is not [<host>/]<owner>/<repo>" ;;
  */*) ;;
  *) refuse "'$REPO' is not [<host>/]<owner>/<repo>" ;;
esac

command -v jq > /dev/null 2>&1 || refuse "jq is missing"

# ---------------------------------------------------------------------- 0. the repository's host
#
# `gh -R OWNER/REPO` takes gh's DEFAULT host, even inside a GitHub Enterprise checkout, so on a GHE
# repository every call below reached github.com (#514). Which host gh talks to is decided in ONE
# place, the helper below; its exported GH_HOST is what every tracker call inherits. Resolved AFTER
# every check above, so a refusal there still means nothing was called, and BEFORE the first call.
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
command -v gh_host_resolve > /dev/null 2>&1 || refuse "cannot load $GH_HOST_LIB; reinstall the kit"
TRACKER_SH="$KIT_ROOT/scripts/tracker.sh"
[ -x "$TRACKER_SH" ] || refuse "cannot find $TRACKER_SH; reinstall the kit"
TRACKER_NAME=$("$TRACKER_SH" state merge-pr 2>/dev/null | jq -r '.tracker // empty') || TRACKER_NAME=""
[ -n "$TRACKER_NAME" ] || refuse "tracker.sh state could not name this repository's tracker"
if [ "$TRACKER_NAME" = github ]; then
  gh_host_resolve "$REPO" || exit 2
  REPO="$KIT_REPO_SLUG"
fi

tracker() { "$TRACKER_SH" -R "$REPO" "$@"; }

# ---------------------------------------------------------------------- 1. does a parent exist?

# The backend's stderr (the #762 sub-issues note, the #781 cross-repository refusal) passes through.
PARENT=$(tracker issue-parent "$CHILD") || fail "issue-parent #$CHILD failed — see the line above"

if [ "$PARENT" = fallback ]; then
  # No native parent link on this host: the child's own `Part of #N` first line names it, if any.
  child_json=$(tracker issue-view "$CHILD") || fail "issue-view #$CHILD failed — see the line above"
  PARENT=$(printf '%s' "$child_json" | jq -r '.body // empty' 2>/dev/null | head -1 \
    | sed -nE 's/^Part of #([0-9]+).*/\1/p') || PARENT=""
  if [ -z "$PARENT" ]; then
    echo "$TOOL: no native parent link here, and #$CHILD's body does not open with 'Part of #N'; reading it as parentless" >&2
    PARENT=none
  fi
fi

if [ "$PARENT" = none ]; then
  echo "no-parent"
  exit 0
fi
is_number "$PARENT" || fail "#$CHILD's parent resolved to '$PARENT', which is not an issue number"

# ---------------------------------------------------------------------- 2. the PR's title + url

pr_json=$(tracker pr-view "$PR") || fail "pr-view #$PR failed — see the line above"
printf '%s' "$pr_json" | jq -e . > /dev/null 2>&1 \
  || fail "pr-view #$PR returned unparseable output: $pr_json"

PR_TITLE=$(printf '%s' "$pr_json" | jq -r '.title // empty')
PR_URL=$(printf '%s' "$pr_json" | jq -r '.url // empty')
[ -n "$PR_TITLE" ] || fail "PR #$PR has no title — nothing to append"
[ -n "$PR_URL" ] || fail "PR #$PR has no url — nothing to append"

# Trim a trailing " (#$PR)" (the squash-appended PR number) then a trailing " (#$CHILD)" (the
# issue-number suffix `implement-issue` gave the PR title) — in that order, since a landed PR
# title reads "<subject> (#$CHILD) (#$PR)".
TRIMMED_TITLE=$(printf '%s' "$PR_TITLE" | sed -E "s/[[:space:]]*\\(#$PR\\)[[:space:]]*\$//")
TRIMMED_TITLE=$(printf '%s' "$TRIMMED_TITLE" | sed -E "s/[[:space:]]*\\(#$CHILD\\)[[:space:]]*\$//")
[ -n "$TRIMMED_TITLE" ] || TRIMMED_TITLE="$PR_TITLE"

NEW_LINE="- #$CHILD — $TRIMMED_TITLE ([#$PR]($PR_URL))"

# ---------------------------------------------------------------------- 3. read the parent's body

OLD_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/parent-decision-note-old.XXXXXX") \
  || fail "cannot create a temp file"
NEW_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/parent-decision-note-new.XXXXXX") \
  || fail "cannot create a temp file"
trap 'rm -f "$OLD_BODY_FILE" "$NEW_BODY_FILE"' EXIT

parent_body_json=$(tracker issue-view "$PARENT") || fail "issue-view #$PARENT failed — see the line above"
printf '%s' "$parent_body_json" | jq -e . > /dev/null 2>&1 \
  || fail "issue-view #$PARENT returned unparseable output: $parent_body_json"

printf '%s' "$parent_body_json" | jq -r '.body // empty' > "$OLD_BODY_FILE"
[ -s "$OLD_BODY_FILE" ] || fail "parent #$PARENT has an empty body — refusing to guess at a write"

# ---------------------------------------------------------------------- 4. idempotency check

if grep -qF "[#$PR]" "$OLD_BODY_FILE"; then
  echo "already-noted"
  exit 0
fi

# ---------------------------------------------------------------------- 5. build the new body

HEADING="## Decisions so far"

if grep -qF "$HEADING" "$OLD_BODY_FILE"; then
  # Insert the new bullet as the FIRST line of the existing section: right after the heading's
  # own blank-line separator when one follows it, otherwise right after the heading itself. This
  # is a single forward pass — no lookahead, no buffering the whole section — so it works the same
  # under any POSIX awk (BSD or GNU), not just gawk.
  awk -v heading="$HEADING" -v newline="$NEW_LINE" '
    BEGIN { after_heading = 0; appended = 0 }
    after_heading == 1 {
      after_heading = 0
      if ($0 == "") {
        print $0
        print newline
        appended = 1
        next
      }
      print newline
      appended = 1
      print $0
      next
    }
    { print $0 }
    $0 == heading { after_heading = 1 }
    END { if (after_heading == 1 && appended == 0) print newline }
  ' "$OLD_BODY_FILE" > "$NEW_BODY_FILE"
else
  # No section yet — add it at the end of the body, separated by exactly one blank line. `$(cat …)`
  # strips the old body's trailing newline(s) so this can't grow a stack of blank lines the more
  # times a body without a trailing newline gets read back and re-appended to.
  printf '%s\n\n%s\n\n%s\n' "$(cat "$OLD_BODY_FILE")" "$HEADING" "$NEW_LINE" > "$NEW_BODY_FILE"
fi

[ -s "$NEW_BODY_FILE" ] || fail "the updated body came out empty — refusing to send it. Nothing sent."
new_bytes=$(wc -c < "$NEW_BODY_FILE" | tr -d ' ')
old_bytes=$(wc -c < "$OLD_BODY_FILE" | tr -d ' ')
[ "$new_bytes" -gt "$old_bytes" ] || fail \
  "the updated body ($new_bytes bytes) is not longer than the original ($old_bytes bytes) — appending a line cannot shrink or hold it steady. Nothing sent."
grep -qF -- "$NEW_LINE" "$NEW_BODY_FILE" || fail "the new line did not make it into the updated body. Nothing sent."

# ---------------------------------------------------------------------- 6. write, then read back

tracker issue-edit-body "$PARENT" --body-file "$NEW_BODY_FILE" > /dev/null \
  || fail "issue-edit-body #$PARENT failed — see the line above"

readback_json=$(tracker issue-view "$PARENT") \
  || fail "the write to #$PARENT may have landed, but the read-back failed — see the line above"
printf '%s' "$readback_json" | jq -e . > /dev/null 2>&1 \
  || fail "the read-back of #$PARENT returned unparseable output: $readback_json"

readback_body=$(printf '%s' "$readback_json" | jq -r '.body // empty')
case "$readback_body" in
  *"$NEW_LINE"*) : ;;
  *) fail "ALERT — parent #$PARENT's body does not show the new line after the write. Nothing here restores it automatically; the pre-write copy is $OLD_BODY_FILE" ;;
esac

echo "appended #$CHILD's PR #$PR to parent #$PARENT's Decisions so far"
exit 0
