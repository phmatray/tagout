#!/usr/bin/env bash
# gitlab.sh — the GitLab backend of the tracker contract (#505, #508): a verb in, a normalised
# reply out. Written against scripts/tracker/github.sh, the REFERENCE backend, and against
# scripts/tracker/contract.json's verb table — never a lowest common denominator: a verb prints
# what GitLab can actually say, and a relation GitLab has no equivalent for answers `fallback`.
#
# usage: gitlab.sh <verb> [args…]        (invoked by scripts/tracker.sh, not by hand)
#
# Step 1 confirmation (Task 1): `glab` is not installed in this development environment, so
# `glab api --help` could not be run here. The flags this file depends on are instead confirmed
# against GitLab's own CLI documentation (docs.gitlab.com/cli, gitlab-org/cli source
# commands/api/api.go, commands/api/http.go — fetched 2026-09-26):
#   * `-X`/`--method` sets the HTTP verb; with no `-f`/`-F` the default is GET, WITH one it
#     defaults to POST — every read verb below therefore builds its query string INTO the
#     endpoint argument (exactly as this file's own table does) rather than passing filters as
#     `-f` fields, so a read never needs an explicit `-X GET` to stay a GET.
#   * `-f`/`--raw-field key=value` sends a plain string (no JSON parsing) — used for every
#     write verb's plain fields (title, labels, state_event…).
#   * `-F`/`--field key=value` infers a type and, when the value starts with `@`, reads it from
#     a FILE — `-F description=@<file>` is this backend's one way to send an issue body, and it
#     is never interpolated into an argument.
#   * `:id` (and `:fullpath`, `:namespace`, `:repo`, `:branch`) in the endpoint argument resolve
#     from the current directory's git repository; `--hostname` overrides which GitLab instance is
#     addressed, defaulting to the current directory's authenticated host, else gitlab.com.
#   * On a non-2xx reply, `glab api` writes `glab: <message> (HTTP <code>)` when the body carries
#     a JSON `message` string, else the bare `glab: HTTP <code>` — the same two-shape contract
#     `_link_post` below and github.sh's own classifier both already parse, `gh:` swapped for
#     `glab:`.
# THIS IS DOCUMENTATION EVIDENCE, NOT A LIVE PROBE — unlike github.sh's dated header notes (each
# one a real call against github.com), nothing here was exercised against a live GitLab host in
# this environment. Task 4 Step 5's live acceptance run is where that gap gets closed; until then
# treat every HTTP-status mapping below as "per the issue's design table", not "measured".
#
# TRACKER_REPO carries `[host/]owner/repo` (tracker.sh's `--repo`/`-R`, #668) — GitLab's own nested
# subgroups make a longer path genuinely ambiguous with a leading host segment, so — exactly like
# github.sh's `_gh-host.sh` — only the 2-segment (`owner/repo`) and 3-segment (`host/owner/repo`)
# shapes are accepted; a caller naming a project under a subgroup passes no host, or is unsupported
# until a future issue is worth writing for it. Empty is the common case: create-issue runs inside
# the project's own checkout, and `:id`/`glab`'s own default host cover it with no extra call.
#
# Exit codes (the dispatcher passes them through), matching github.sh's:
#   0  the verb answered
#   1  the host refused or failed — auth, network, a 404
#   2  bad invocation: no verb, a missing argument, a malformed slug
#   3  this backend does not implement the verb
set -euo pipefail

VERB="${1-}"
[ -n "$VERB" ] || { echo "gitlab: no verb given" >&2; exit 2; }
shift

# `verbs` is answered FIRST, before any repository resolution — the dispatcher calls it to decide
# whether this backend implements a verb at all, and that question must not need `glab`, a network
# or a credential (same rule as github.sh).
if [ "$VERB" = verbs ]; then
  printf '%s\n' verbs auth repo issue-view \
    issue-search issue-comments issue-create issue-edit-body \
    issue-add-labels issue-remove-labels issue-reopen issue-comment label-list label-create \
    issue-link-parent issue-link-blocked-by issue-children issue-blocked-by-count
  exit 0
fi

command -v glab > /dev/null 2>&1 || {
  echo "gitlab: glab is missing — it is a \`recommended\` prerequisite in requirements.json for a GitLab tracker" >&2
  exit 1
}

# ------------------------------------------------------------------------------- repo resolution
#
# Sets GITLAB_HOST (empty = let `glab` pick its own default) and PROJECT_PATH (empty = let `:id`
# resolve from the current directory). Mirrors _gh-host.sh's 2-vs-3-segment split; see the header.
GITLAB_HOST=""
PROJECT_PATH=""
if [ -n "${TRACKER_REPO:-}" ]; then
  _slug="$TRACKER_REPO"
  case "$_slug" in
    /*|*/|*//*)
      echo "gitlab: malformed repository slug '$_slug' — expected [HOST/]OWNER/REPO" >&2; exit 2 ;;
  esac
  _segments=1; _rest="$_slug"
  while :; do
    case "$_rest" in
      */*) _rest="${_rest#*/}"; _segments=$((_segments + 1)) ;;
      *) break ;;
    esac
  done
  case "$_segments" in
    2) PROJECT_PATH="$_slug" ;;
    3) GITLAB_HOST=$(printf '%s' "${_slug%%/*}" | tr '[:upper:]' '[:lower:]')
       PROJECT_PATH="${_slug#*/}" ;;
    *) echo "gitlab: malformed repository slug '$_slug' — expected [HOST/]OWNER/REPO (GitLab" \
            "subgroups are not supported through --repo/-R yet)" >&2
       exit 2 ;;
  esac
fi

# glab's own JSON-array %-encoding for a project path (owner/repo → owner%2Frepo); `:id` is left
# untouched for `glab` itself to resolve from the working directory.
_id() {
  if [ -n "$PROJECT_PATH" ]; then
    printf '%s' "$PROJECT_PATH" | sed 's#/#%2F#g'
  else
    printf ':id'
  fi
}

_api() {
  if [ -n "$GITLAB_HOST" ]; then
    glab api --hostname "$GITLAB_HOST" "$@"
  else
    glab api "$@"
  fi
}

# URL-encodes one query-string VALUE (never a whole endpoint) — jq's `@uri`, already a required
# prerequisite, is exact on the characters that matter here (space, `:`, `,`) where a hand-rolled
# `sed` table would only be another way to get it slightly wrong.
_urlenc() { jq -rn --arg v "$1" '$v | @uri'; }

# Joins "$@" with commas — GitLab's own field grammar for `labels`/`add_labels`/`remove_labels`,
# used instead of `${array[*]}` with a temporary `IFS` so the join never depends on a shell that
# has not just been told what its word-splitting character is.
_join_comma() {
  local out="" a
  for a in "$@"; do
    if [ -z "$out" ]; then out="$a"; else out="$out,$a"; fi
  done
  printf '%s' "$out"
}

# Shared by the read verbs: GitLab spells a state "opened", the contract spells it "open" — the
# same normalisation github.sh applies by lower-casing GitHub's OPEN/CLOSED.
_state_open() { if [ "$1" = opened ]; then echo open; else printf '%s' "$1"; fi; }

# The numeric project id the issue-links endpoint's `target_project_id` field wants (GitLab types
# it an integer, not a path) — resolved once per invocation and cached, the same shape as
# github.sh's `_issue_db_id` for the same reason: a placeholder is for a URL, not a JSON field.
GITLAB_PROJECT_ID=""
_project_id() {
  if [ -n "$GITLAB_PROJECT_ID" ]; then printf '%s' "$GITLAB_PROJECT_ID"; return 0; fi
  local raw id
  # `glab api` (unlike `gh api`) has no built-in `--jq` filter (docs.gitlab.com/cli/api, 2026-09-26)
  # — the documented pattern is piping its raw JSON through the standalone `jq`, which every verb
  # in this file already does for its own normalisation.
  raw=$(_api "projects/$(_id)" 2>&1) || { printf '%s' "$raw"; return 1; }
  id=$(printf '%s' "$raw" | jq -r '.id' 2>/dev/null)
  case "$id" in
    ''|*[!0-9]*) printf "project resolved to '%s', which is not a numeric id" "$id"; return 1 ;;
  esac
  GITLAB_PROJECT_ID="$id"
  printf '%s' "$id"
}

# The classifier issue-link-blocked-by shares with nothing else (issue-link-parent never posts):
# prints ok | fallback | FAILED (HTTP <code>: <message>) and returns 0 for ok/fallback, 1 for
# FAILED. `glab api` reports a non-2xx as `glab: <message> (HTTP <code>)` on stderr and exit 1, or
# the bare `glab: HTTP <code>` when the body carried no JSON `message` string (see the header).
_link_post() {
  local endpoint="$1"; shift
  local -a fields=()
  local f
  for f in "$@"; do fields+=(-f "$f"); done
  local err code msg
  if err=$(_api -X POST --silent "$endpoint" "${fields[@]}" 2>&1 >/dev/null); then
    echo "ok"; return 0
  fi
  code=$(printf '%s' "$err" | sed -n \
    -e 's/.*(HTTP \([0-9][0-9][0-9]\))$/\1/p' \
    -e 's/^glab: HTTP \([0-9][0-9][0-9]\)$/\1/p' | head -1)
  msg=$(printf '%s' "$err" | sed -n 's/^glab: \(.*\) (HTTP [0-9][0-9][0-9])$/\1/p' | head -1)
  [ -n "$msg" ] || msg=$(printf '%s' "$err" | tr '\n' ' ')
  case "$code" in
    403|404) echo "fallback"; return 0 ;;
    409) echo "ok (already linked)"; return 0 ;;
    '') echo "FAILED (no HTTP status in glab's answer: $msg)"; return 1 ;;
    *)  echo "FAILED (HTTP $code: $msg)"; return 1 ;;
  esac
}

# Both link verbs take the same two private flags plus positionals — copied from github.sh's own
# `_parse_link_args` so a third flag is added once, not twice.
_parse_link_args() {
  DRY=0; RESOLVE_ONLY=0; POS=()
  local a
  for a in "$@"; do
    case "$a" in
      --dry-run) DRY=1 ;;
      --resolve-only) RESOLVE_ONLY=1 ;;
      *) POS+=("$a") ;;
    esac
  done
}

case "$VERB" in
  auth)
    if [ -n "$GITLAB_HOST" ]; then
      glab auth status --hostname "$GITLAB_HOST" > /dev/null 2>&1 || exit 1
    fi
    out=$(_api user) || exit 1
    printf '%s' "$out" | jq -r .username
    ;;

  repo)
    out=$(_api "projects/$(_id)") || exit 1
    origin_url=$(git remote get-url origin 2>/dev/null) || origin_url=""
    origin_arg=$(printf '%s' "$origin_url" \
      | sed -E -e 's#(\.git)?/*$##' -e 's#.*[:/]([^/:]+)/([^/:]+)$#\1/\2#')
    printf '%s' "$out" | jq -c --arg host "${GITLAB_HOST:-gitlab.com}" --arg origin "$origin_arg" \
      '($origin | split("/")) as $p |
       {slug: .path_with_namespace, host: $host, defaultBranch: (.default_branch // null),
        originSlug: (if ($p | length) == 2 and ($p[0] | length) > 0 and ($p[1] | length) > 0
                     then $origin else null end)}'
    ;;

  issue-view)
    n="${1-}"
    [ -n "$n" ] || { echo "gitlab: issue-view needs an issue number" >&2; exit 2; }
    out=$(_api "projects/$(_id)/issues/$n") || exit 1
    printf '%s' "$out" | jq -c \
      '{number: .iid, title, state: (if .state == "opened" then "open" else .state end),
        body: .description, labels: (.labels // []), url: .web_url, format: "markdown"}'
    ;;

  issue-search)
    Q=""; ST=""; LIM=""; LBLS=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --query) Q="${2-}"; shift 2 ;;
        --state) ST="${2-}"; shift 2 ;;
        --label) LBLS+=("${2-}"); shift 2 ;;
        --limit) LIM="${2-}"; shift 2 ;;
        *) echo "gitlab: issue-search: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    ep="projects/$(_id)/issues?in=title,description"
    [ -n "$Q" ] && ep="$ep&search=$(_urlenc "$Q")"
    case "$ST" in
      open) ep="$ep&state=opened" ;;
      closed) ep="$ep&state=closed" ;;
      all|"") ;;
      *) echo "gitlab: issue-search: unknown --state: $ST" >&2; exit 2 ;;
    esac
    if [ "${#LBLS[@]}" -gt 0 ]; then
      ep="$ep&labels=$(_urlenc "$(_join_comma "${LBLS[@]}")")"
    fi
    [ -n "$LIM" ] && ep="$ep&per_page=$(_urlenc "$LIM")"
    out=$(_api "$ep") || exit 1
    printf '%s' "$out" | jq -c '[.[] | {number: .iid, title, state: (if .state == "opened" then "open" else .state end)}]'
    ;;

  issue-comments)
    n="${1-}"
    [ -n "$n" ] || { echo "gitlab: issue-comments needs an issue number" >&2; exit 2; }
    out=$(_api "projects/$(_id)/issues/$n/notes?sort=asc&per_page=100") || exit 1
    printf '%s' "$out" | jq -c '[.[] | select(.system == false) | .body]'
    ;;

  issue-create)
    TITLE=""; BODY_FILE=""; LBLS=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --title)     TITLE="${2-}"; shift 2 ;;
        --label)     LBLS+=("${2-}"); shift 2 ;;
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        *) echo "gitlab: issue-create: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$TITLE" ] || { echo "gitlab: issue-create needs --title" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "gitlab: issue-create needs a non-empty --body-file" >&2; exit 2; }
    ARGS=(-X POST "projects/$(_id)/issues" -f "title=$TITLE" -F "description=@$BODY_FILE")
    [ "${#LBLS[@]}" -gt 0 ] && ARGS+=(-f "labels=$(_join_comma "${LBLS[@]}")")
    out=$(_api "${ARGS[@]}") || exit 1
    printf '%s' "$out" | jq -c '{number: .iid, url: .web_url}'
    ;;

  issue-edit-body)
    n="${1-}"; shift || true
    BODY_FILE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        *) echo "gitlab: issue-edit-body: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$n" ] || { echo "gitlab: issue-edit-body needs an issue number" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "gitlab: issue-edit-body refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    _api -X PUT "projects/$(_id)/issues/$n" -F "description=@$BODY_FILE" > /dev/null || exit 1
    ;;

  issue-add-labels)
    n="${1-}"; shift || true
    [ -n "$n" ] || { echo "gitlab: issue-add-labels needs an issue number" >&2; exit 2; }
    [ $# -gt 0 ] || { echo "gitlab: issue-add-labels needs at least one label" >&2; exit 2; }
    _api -X PUT "projects/$(_id)/issues/$n" -f "add_labels=$(_join_comma "$@")" > /dev/null || exit 1
    ;;

  issue-remove-labels)
    n="${1-}"; shift || true
    [ -n "$n" ] || { echo "gitlab: issue-remove-labels needs an issue number" >&2; exit 2; }
    [ $# -gt 0 ] || { echo "gitlab: issue-remove-labels needs at least one label" >&2; exit 2; }
    _api -X PUT "projects/$(_id)/issues/$n" -f "remove_labels=$(_join_comma "$@")" > /dev/null || exit 1
    ;;

  issue-reopen)
    n="${1-}"; shift || true
    BODY_FILE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        *) echo "gitlab: issue-reopen: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$n" ] || { echo "gitlab: issue-reopen needs an issue number" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "gitlab: issue-reopen refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    _api -X PUT "projects/$(_id)/issues/$n" -f "state_event=reopen" > /dev/null || exit 1
    _api -X POST "projects/$(_id)/issues/$n/notes" -F "body=@$BODY_FILE" > /dev/null || exit 1
    ;;

  issue-comment)
    n="${1-}"; shift || true
    BODY_FILE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        *) echo "gitlab: issue-comment: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$n" ] || { echo "gitlab: issue-comment needs an issue number" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "gitlab: issue-comment refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    _api -X POST "projects/$(_id)/issues/$n/notes" -F "body=@$BODY_FILE" > /dev/null || exit 1
    ;;

  label-list)
    out=$(_api "projects/$(_id)/labels?per_page=100") || exit 1
    printf '%s' "$out" | jq -r '.[].name'
    ;;

  label-create)
    NAME="${1-}"; shift || true
    COLOR=""; DESC=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --color)       COLOR="${2-}"; shift 2 ;;
        --description) DESC="${2-}"; shift 2 ;;
        *) echo "gitlab: label-create: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$NAME" ] || { echo "gitlab: label-create needs a name" >&2; exit 2; }
    ARGS=(-X POST "projects/$(_id)/labels" -f "name=$NAME")
    if [ -n "$COLOR" ]; then
      case "$COLOR" in
        "#"*) ;;
        *) COLOR="#$COLOR" ;;
      esac
      ARGS+=(-f "color=$COLOR")
    fi
    [ -n "$DESC" ] && ARGS+=(-f "description=$DESC")
    _api "${ARGS[@]}" > /dev/null || exit 1
    ;;

  # GitLab issues have no issue→issue sub-issue relation reachable this way (Premium+'s epics are a
  # different object entirely) — always `fallback`, and never a request, matching AC4.
  issue-link-parent)
    _parse_link_args "$@"
    P="${POS[0]-}"; C="${POS[1]-}"
    [ -n "$P" ] && [ -n "$C" ] \
      || { echo "gitlab: issue-link-parent needs <parent> <child>" >&2; exit 2; }
    echo "fallback"
    ;;

  issue-link-blocked-by)
    _parse_link_args "$@"
    C="${POS[0]-}"; B="${POS[1]-}"
    [ -n "$C" ] && [ -n "$B" ] \
      || { echo "gitlab: issue-link-blocked-by needs <child> <blocker>" >&2; exit 2; }
    if [ "$DRY" -eq 1 ]; then
      echo "DRY-RUN POST projects/$(_id)/issues/$C/links -f target_project_id=<numeric project id> -f target_issue_iid=$B -f link_type=is_blocked_by"
      exit 0
    fi
    pid=$(_project_id) \
      || { echo "gitlab: issue-link-blocked-by: cannot resolve this project's numeric id — $pid" >&2; exit 1; }
    [ "$RESOLVE_ONLY" -eq 1 ] && exit 0
    _link_post "projects/$(_id)/issues/$C/links" \
      "target_project_id=$pid" "target_issue_iid=$B" "link_type=is_blocked_by"
    ;;

  # No sub-issue relation (see issue-link-parent) — nothing to list, and never a request.
  issue-children)
    n="${1-}"
    [ -n "$n" ] || { echo "gitlab: issue-children needs a parent issue number" >&2; exit 2; }
    echo "fallback"
    ;;

  issue-blocked-by-count)
    n="${1-}"
    [ -n "$n" ] || { echo "gitlab: issue-blocked-by-count needs an issue number" >&2; exit 2; }
    if out=$(_api "projects/$(_id)/issues/$n/links" 2>&1); then
      printf '%s' "$out" | jq -c '[.[] | select(.link_type == "is_blocked_by" and .state == "opened")] | length'
    elif printf '%s' "$out" | grep -qE '\(HTTP 403\)|^glab: HTTP 403$'; then
      printf 'n/a\n'
    else
      echo "gitlab: issue-blocked-by-count: $out" >&2; exit 1
    fi
    ;;

  *)
    echo "gitlab: does not implement '$VERB'" >&2
    exit 3
    ;;
esac
