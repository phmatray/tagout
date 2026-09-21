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
#   checkout's own origin's, when origin is that repository. Resolved once, before the first gh
#   call, by skills/_shared/scripts/_gh-host.sh (#514).
#
# What it does, in order:
#   1. Reads the child issue's native `parent` field (`gh issue view <child> --json parent`).
#      No parent → prints `no-parent` and exits 0. This is the common path.
#   2. Parent present → reads the merged PR's title and url, and the parent's current body.
#   3. Idempotency: if the body already carries this PR's own marker (`[#<pr>]`), prints
#      `already-noted` and exits 0 without writing anything — a re-run of `merge-pr` on an
#      already-merged PR must not duplicate the line.
#   4. Otherwise appends `- #<child> — <title, trimmed of its trailing "(#issue) (#PR)"> ([#<PR>](<url>))`
#      to the `## Decisions so far` section, creating the section (at the end of the body) if the
#      parent doesn't have one yet. Writes via `gh issue edit --body-file -`, then reads the body
#      back to confirm the line landed.
#
# Exit codes:
#   0   success — appended, already-noted, or no-parent (all three are success, never confused with
#       a genuine failure by a caller that only checks the exit code)
#   1   a real failure: a `gh` call failed, returned unparseable JSON, or the parent's body could
#       not be safely read or the write could not be confirmed. Always a `parent-decision-note:`
#       prefixed line on stderr.
#   2   usage — bad arguments, a malformed slug, or the kit's host helper missing; nothing was
#       called.
#
# bash 3.2 compatible (no associative arrays, no `${var,,}`, no `mapfile`). Tested by
# tests/merge-pr-parent/test.sh through a stubbed `gh` on PATH.
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

command -v gh > /dev/null 2>&1 || refuse "gh is missing"
command -v jq > /dev/null 2>&1 || refuse "jq is missing"

# ---------------------------------------------------------------------- 0. the repository's host
#
# `gh -R OWNER/REPO` takes gh's DEFAULT host, even inside a GitHub Enterprise checkout, so on a GHE
# repository every call below reached github.com (#514). Which host gh talks to is decided in ONE
# place, the helper below; its exported GH_HOST is what all five calls inherit. Resolved AFTER every
# check above, so a refusal there still means nothing was called, and BEFORE the first gh call.
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

# ---------------------------------------------------------------------- 1. does a parent exist?

parent_json=$(gh issue view "$CHILD" -R "$REPO" --json parent 2>&1) \
  || fail "gh issue view #$CHILD --json parent failed: $parent_json"

printf '%s' "$parent_json" | jq -e . > /dev/null 2>&1 \
  || fail "gh issue view #$CHILD --json parent returned unparseable output: $parent_json"

PARENT=$(printf '%s' "$parent_json" | jq -r '.parent.number // empty')

if [ -z "$PARENT" ]; then
  echo "no-parent"
  exit 0
fi
is_number "$PARENT" || fail "#$CHILD's parent resolved to '$PARENT', which is not an issue number"

# ---------------------------------------------------------------------- 2. the PR's title + url

pr_json=$(gh pr view "$PR" -R "$REPO" --json title,url 2>&1) \
  || fail "gh pr view #$PR --json title,url failed: $pr_json"
printf '%s' "$pr_json" | jq -e . > /dev/null 2>&1 \
  || fail "gh pr view #$PR --json title,url returned unparseable output: $pr_json"

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
EDIT_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/parent-decision-note-edit-err.XXXXXX") \
  || fail "cannot create a temp file"
trap 'rm -f "$OLD_BODY_FILE" "$NEW_BODY_FILE" "$EDIT_ERR_FILE"' EXIT

parent_body_json=$(gh issue view "$PARENT" -R "$REPO" --json body 2>&1) \
  || fail "gh issue view #$PARENT --json body failed: $parent_body_json"
printf '%s' "$parent_body_json" | jq -e . > /dev/null 2>&1 \
  || fail "gh issue view #$PARENT --json body returned unparseable output: $parent_body_json"

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

if ! gh issue edit "$PARENT" -R "$REPO" --body-file - < "$NEW_BODY_FILE" > /dev/null 2> "$EDIT_ERR_FILE"; then
  fail "gh issue edit #$PARENT --body-file - failed: $(cat "$EDIT_ERR_FILE" 2>/dev/null || true)"
fi

readback_json=$(gh issue view "$PARENT" -R "$REPO" --json body 2>&1) \
  || fail "the write to #$PARENT may have landed, but the read-back failed: $readback_json"
printf '%s' "$readback_json" | jq -e . > /dev/null 2>&1 \
  || fail "the read-back of #$PARENT returned unparseable output: $readback_json"

readback_body=$(printf '%s' "$readback_json" | jq -r '.body // empty')
case "$readback_body" in
  *"$NEW_LINE"*) : ;;
  *) fail "ALERT — parent #$PARENT's body does not show the new line after the write. Nothing here restores it automatically; the pre-write copy is $OLD_BODY_FILE" ;;
esac

echo "appended #$CHILD's PR #$PR to parent #$PARENT's Decisions so far"
exit 0
