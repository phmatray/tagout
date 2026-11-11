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
# TRACKER_REPO carries `[host/]owner[/subgroup…]/repo` (tracker.sh's `--repo`/`-R`, #668, #795): a
# leading segment with a dot is the host when there are 3+ segments (`host.tld/owner/repo`,
# `host.tld/group/subgroup/project`); otherwise the whole slug is the project path, so
# `group/subgroup/project` addresses a project under a subgroup. A dotless host (`localhost`) is
# named by exporting `GITLAB_HOST=localhost`; a leading segment equal to it is then the host (#801). Empty is the common case: create-issue runs inside
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
    issue-link-parent issue-link-blocked-by issue-children issue-blocked-by-count \
    pr-create pr-list pr-view pr-edit-body pr-ready pr-commits \
    pr-merge-state pr-checks commit-checks pr-threads pr-thread-resolve pr-merge branch-delete \
    issue-parent pr-closing-issues pr-comment
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
# An inherited GITLAB_HOST (glab's own variable) is read, only to name the host: it is the one route to a dotless host
# (localhost) on a subgroup slug, which the dot rule below cannot tell from a subgroup (#801).
_env_host=$(printf '%s' "${GITLAB_HOST:-}" | tr '[:upper:]' '[:lower:]')
GITLAB_HOST=""
PROJECT_PATH=""
if [ -n "${TRACKER_REPO:-}" ]; then
  _slug="$TRACKER_REPO"
  case "$_slug" in
    /*|*/|*//*)
      echo "gitlab: malformed repository slug '$_slug' — expected [HOST/]OWNER[/SUBGROUP…]/REPO" >&2; exit 2 ;;
  esac
  _segments=1; _rest="$_slug"
  while :; do
    case "$_rest" in
      */*) _rest="${_rest#*/}"; _segments=$((_segments + 1)) ;;
      *) break ;;
    esac
  done
  # 2 segments: owner/repo. 3 or more: a leading segment with a dot is the host (host/owner/repo,
  # host/group/subgroup/project); without one the whole slug is a project path under subgroups.
  # A dotless host (localhost) is indistinguishable from a subgroup, so it is named by exporting
  # GITLAB_HOST=localhost: a leading segment equal to it is then split off like a dotted host.
  _first="${_slug%%/*}"
  if [ "$_segments" -lt 2 ]; then
    echo "gitlab: malformed repository slug '$_slug' — expected [HOST/]OWNER[/SUBGROUP…]/REPO" >&2; exit 2
  elif [ "$_segments" -ge 3 ] && _lf=$(printf '%s' "$_first" | tr '[:upper:]' '[:lower:]') \
    && case "$_lf" in *.*) true ;; "$_env_host") [ -n "$_lf" ] ;; *) false ;; esac; then
    GITLAB_HOST="$_lf"
    PROJECT_PATH="${_slug#*/}"
  else
    PROJECT_PATH="$_slug"
  fi
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

# Same shape as _join_comma, `&`-separated — issue-search's own query-string parameters, built as
# an array precisely so a filter that is absent never leaves a stray leading/trailing separator.
_join_amp() {
  local out="" a
  for a in "$@"; do
    if [ -z "$out" ]; then out="$a"; else out="$out&$a"; fi
  done
  printf '%s' "$out"
}

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
  # A field prefixed "F:" goes through -F (typed — an integer stays an integer, per the header's
  # own note that target_project_id/target_issue_iid are GitLab-typed integers, not paths);
  # anything else goes through -f (a plain string), the same split every other verb in this file
  # already makes between an id and a label.
  for f in "$@"; do
    case "$f" in
      F:*) fields+=(-F "${f#F:}") ;;
      *)   fields+=(-f "$f") ;;
    esac
  done
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

# A list read, every page: `--paginate` fetches them, and `jq -s add` joins them whether glab hands
# back one array or one per page. `pipefail` carries glab's failure past the jq — a failed read is
# never an empty list.
_list() { _api --paginate "$1" | jq -sc 'add // []'; }

# The resolvable discussions of MR $1, as the contract's pr-threads array — the one read pr-threads
# and pr-merge-state both answer from (github.sh's `_threads`). A system note is not resolvable.
_threads() {
  _list "projects/$(_id)/merge_requests/$1/discussions?per_page=100" | jq -c \
    '[.[] | select(.notes[0].resolvable == true) | .notes[0] as $n
      | {id, path: ($n.position.new_path // null), line: ($n.position.new_line // null),
         body: $n.body, isResolved: ($n.resolved == true)}]'
}

# The `commit-checks` bucket rule lives once, in _bucket.sh (#807).
. "$(dirname -- "${BASH_SOURCE[0]}")/_bucket.sh"

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
    # The whole project path of origin (scheme, userinfo, host and :port dropped), so a subgroup
    # project keeps every segment (#799); fewer than two segments is JSON null.
    origin_arg=$(printf '%s' "$origin_url" \
      | sed -E -e 's#(\.git)?/*$##' -e 's#^([A-Za-z][A-Za-z0-9+.-]*://[^/]*/|[^:/]*:)##')
    printf '%s' "$out" | jq -c --arg host "${GITLAB_HOST:-gitlab.com}" --arg origin "$origin_arg" \
      '($origin | split("/")) as $p |
       {slug: .path_with_namespace, host: $host, defaultBranch: (.default_branch // null),
        originSlug: (if ($p | length) >= 2 and all($p[]; length > 0)
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
    # `in` scopes `search` and GitLab documents it as meaningless without one — sent only
    # alongside a `search=` term, never on a bare label/state-only search (Step 3's open-refactor
    # scan calls this with --label and no --query, exactly the case that must stay a plain list).
    # Built as an array and `&`-joined so an absent filter never leaves a stray leading `&` or `?`
    # in the query string, whichever filters are present.
    qp=()
    [ -n "$Q" ] && qp+=("in=title,description" "search=$(_urlenc "$Q")")
    case "$ST" in
      open) qp+=("state=opened") ;;
      closed) qp+=("state=closed") ;;
      all|"") ;;
      *) echo "gitlab: issue-search: unknown --state: $ST" >&2; exit 2 ;;
    esac
    [ "${#LBLS[@]}" -gt 0 ] && qp+=("labels=$(_urlenc "$(_join_comma "${LBLS[@]}")")")
    [ -n "$LIM" ] && qp+=("per_page=$(_urlenc "$LIM")")
    ep="projects/$(_id)/issues"
    [ "${#qp[@]}" -gt 0 ] && ep="$ep?$(_join_amp "${qp[@]}")"
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
      echo "DRY-RUN POST projects/$(_id)/issues/$C/links -F target_project_id=<numeric project id> -F target_issue_iid=$B -f link_type=is_blocked_by"
      exit 0
    fi
    pid=$(_project_id) \
      || { echo "gitlab: issue-link-blocked-by: cannot resolve this project's numeric id — $pid" >&2; exit 1; }
    [ "$RESOLVE_ONLY" -eq 1 ] && exit 0
    _link_post "projects/$(_id)/issues/$C/links" \
      "F:target_project_id=$pid" "F:target_issue_iid=$B" "link_type=is_blocked_by"
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
    if out=$(_api "projects/$(_id)/issues/$n/links?per_page=100" 2>&1); then
      printf '%s' "$out" | jq -c '[.[] | select(.link_type == "is_blocked_by" and .state == "opened")] | length'
    elif grep -qE '\(HTTP 403\)|^glab: HTTP 403$' <<<"$out"; then
      printf 'n/a\n'
    else
      echo "gitlab: issue-blocked-by-count: $out" >&2; exit 1
    fi
    ;;

  # The six PR verbs (#751), on merge requests. A draft is GitLab's `Draft: ` title prefix: pr-create
  # adds it, pr-ready strips it (any of `Draft:`, `[Draft]`, `(Draft)`, case-insensitive). `-f`
  # (raw field) for every string, so a title or branch that looks like a number stays a string.
  pr-create)
    BASE=""; HEAD=""; TITLE=""; BODY_FILE=""; DRAFT=0; DRY=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --base)      BASE="${2-}"; shift 2 ;;
        --head)      HEAD="${2-}"; shift 2 ;;
        --title)     TITLE="${2-}"; shift 2 ;;
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        --draft)     DRAFT=1; shift ;;
        --dry-run)   DRY=1; shift ;;
        *) echo "gitlab: pr-create: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$BASE" ] && [ -n "$HEAD" ] && [ -n "$TITLE" ] \
      || { echo "gitlab: pr-create needs --base, --head and --title" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "gitlab: pr-create refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    [ "$DRAFT" -eq 1 ] && TITLE="Draft: $TITLE"
    ARGS=(-X POST "projects/$(_id)/merge_requests" -f "source_branch=$HEAD" -f "target_branch=$BASE"
          -f "title=$TITLE" -F "description=@$BODY_FILE")
    if [ "$DRY" -eq 1 ]; then echo "DRY-RUN glab api ${ARGS[*]}"; exit 0; fi
    out=$(_api "${ARGS[@]}") || exit 1
    printf '%s' "$out" | jq -c '{number: .iid, url: .web_url}'
    ;;

  pr-list)
    HEAD=""; Q=""; ST=""; LIM=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --head)   HEAD="${2-}"; shift 2 ;;
        --search) Q="${2-}"; shift 2 ;;
        --state)  ST="${2-}"; shift 2 ;;
        --limit)  LIM="${2-}"; shift 2 ;;
        *) echo "gitlab: pr-list: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    qp=()
    [ -n "$HEAD" ] && qp+=("source_branch=$(_urlenc "$HEAD")")
    # No --state means open, as `gh pr list` defaults: a merged MR on a reused branch name must not
    # read as "a PR is already open" to open-pr.md §1.
    case "$ST" in
      open|"") qp+=("state=opened") ;;
      merged)  qp+=("state=merged") ;;
      *) echo "gitlab: pr-list: --state is open or merged" >&2; exit 2 ;;
    esac
    # GitLab's `search` ignores a term under 3 characters (an issue number like 42), so a short term
    # is matched here, against each description, instead of being sent.
    if [ -n "$Q" ] && [ "${#Q}" -ge 3 ]; then qp+=("search=$(_urlenc "$Q")" "in=description"); fi
    [ -n "$LIM" ] && qp+=("per_page=$(_urlenc "$LIM")")
    ep="projects/$(_id)/merge_requests"
    [ "${#qp[@]}" -gt 0 ] && ep="$ep?$(_join_amp "${qp[@]}")"
    out=$(_api "$ep") || exit 1
    printf '%s' "$out" | jq -c --arg q "$Q" '[.[] | select((.description // "") | contains($q))]
      | [.[] | {number: .iid, title, url: .web_url,
      state: (if .state == "opened" then "open" else .state end),
      isDraft: (.draft // .work_in_progress // false), headBranch: .source_branch,
      body: .description, mergedAt: (.merged_at // null)}]'
    ;;

  pr-view)
    n="${1-}"
    [ -n "$n" ] || { echo "gitlab: pr-view needs a merge request iid" >&2; exit 2; }
    out=$(_api "projects/$(_id)/merge_requests/$n") || exit 1
    printf '%s' "$out" | jq -c '{number: .iid, title, url: .web_url,
      state: (if .state == "opened" then "open" else .state end),
      isDraft: (.draft // .work_in_progress // false), body: .description,
      headBranch: .source_branch, baseBranch: .target_branch, headSha: .sha,
      author: (.author.username // null), mergedAt: (.merged_at // null),
      mergeSha: (.merge_commit_sha // .squash_commit_sha // null)}'
    ;;

  pr-edit-body)
    n="${1-}"; shift || true
    BODY_FILE=""; DRY=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        --dry-run)   DRY=1; shift ;;
        *) echo "gitlab: pr-edit-body: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$n" ] || { echo "gitlab: pr-edit-body needs a merge request iid" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "gitlab: pr-edit-body refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    ARGS=(-X PUT "projects/$(_id)/merge_requests/$n" -F "description=@$BODY_FILE")
    if [ "$DRY" -eq 1 ]; then echo "DRY-RUN glab api ${ARGS[*]}"; exit 0; fi
    _api "${ARGS[@]}" > /dev/null || exit 1
    ;;

  pr-ready)
    n=""; DRY=0
    for a in "$@"; do
      case "$a" in
        --dry-run) DRY=1 ;;
        -*) echo "gitlab: pr-ready: unknown option: $a" >&2; exit 2 ;;
        *) n="$a" ;;
      esac
    done
    [ -n "$n" ] || { echo "gitlab: pr-ready needs a merge request iid" >&2; exit 2; }
    if [ "$DRY" -eq 1 ]; then
      echo "DRY-RUN glab api -X PUT projects/$(_id)/merge_requests/$n -f title=<the title without its Draft: prefix>"
      exit 0
    fi
    out=$(_api "projects/$(_id)/merge_requests/$n") || exit 1
    title=$(printf '%s' "$out" | jq -r '.title') || exit 1
    ready=$(printf '%s' "$out" | jq -r '.title | sub("^(\\[draft\\]|\\(draft\\)|draft:)\\s*"; ""; "i")') || exit 1
    # A merge request that is not a draft is already ready: nothing to send.
    [ "$ready" = "$title" ] && exit 0
    _api -X PUT "projects/$(_id)/merge_requests/$n" -f "title=$ready" > /dev/null || exit 1
    ;;

  pr-commits)
    n="${1-}"
    [ -n "$n" ] || { echo "gitlab: pr-commits needs a merge request iid" >&2; exit 2; }
    out=$(_api "projects/$(_id)/merge_requests/$n/commits?per_page=100") || exit 1
    printf '%s' "$out" | jq -c '[.[].id]'
    ;;

  # The ten merge-pr verbs (#752), mapped as the Spec's GitLab column says. merge_when_pipeline_succeeds
  # (and so a merge train) is never set: pr-merge merges now or fails.
  pr-merge-state)
    n="${1-}"
    [ -n "$n" ] || { echo "gitlab: pr-merge-state needs a merge request iid" >&2; exit 2; }
    # Every read lands in a variable before anything prints: a failed read is exit 1 with an EMPTY
    # stdout, never a partial state a caller could hand to merge.step4.
    view=$(_api "projects/$(_id)/merge_requests/$n?include_diverged_commits_count=true&with_merge_status_recheck=true") || exit 1
    behind=$(printf '%s' "$view" | jq -r '.diverged_commits_count // empty')
    case "$behind" in
      ''|*[!0-9]*) echo "gitlab: pr-merge-state: MR !$n answered diverged_commits_count '$behind'" >&2; exit 1 ;;
    esac
    threads=$(_threads "$n") || {
      echo "gitlab: pr-merge-state: the discussions read failed — an unanswered read is not 'no threads'" >&2
      exit 1; }
    # CLEAN only on GitLab's own `mergeable`; a word not in this table (checking, ci_still_running,
    # one GitLab adds tomorrow) is UNKNOWN, which merge.step4 waits on.
    printf '%s' "$view" | jq -c --argjson b "$behind" --argjson t "$threads" '
      .detailed_merge_status as $s
      | {behind_by: $b,
         mergeStateStatus: (
           if $s == "mergeable" then "CLEAN"
           elif $s == "need_rebase" then "BEHIND"
           elif $s == "conflict" or $s == "broken_status" then "DIRTY"
           elif $s == "draft_status" then "DRAFT"
           elif (["not_approved", "requested_changes", "discussions_not_resolved", "blocked_status",
                  "external_status_checks", "jira_association_missing", "security_policy_violations",
                  "locked_paths", "locked_lfs_files", "title_regex", "merge_request_blocked"]
                 | any(. == $s)) then "BLOCKED"
           else "UNKNOWN" end),
         isDraft: (.draft // .work_in_progress // false),
         reviewDecision: (if $s == "requested_changes" then "CHANGES_REQUESTED"
                          elif $s == "not_approved" then "REVIEW_REQUIRED" else null end),
         unresolved_threads: [$t[] | select(.isResolved == false) | .path // "(pr-level)"]}'
    ;;

  pr-threads)
    n="${1-}"
    [ -n "$n" ] || { echo "gitlab: pr-threads needs a merge request iid" >&2; exit 2; }
    threads=$(_threads "$n") || {
      echo "gitlab: pr-threads: the discussions read failed — an unanswered read is not 'no threads'" >&2
      exit 1; }
    printf '%s\n' "$threads"
    ;;

  pr-checks)
    n="${1-}"
    [ -n "$n" ] || { echo "gitlab: pr-checks needs a merge request iid" >&2; exit 2; }
    mr=$(_api "projects/$(_id)/merge_requests/$n") || exit 1
    pid=$(printf '%s' "$mr" | jq -r '.head_pipeline.id // empty')
    # No head pipeline is the genuine "no checks" answer; anything that fails below is exit 1.
    [ -n "$pid" ] || { echo '[]'; exit 0; }
    jobs=$(_list "projects/$(_id)/pipelines/$pid/jobs?per_page=100") || exit 1
    printf '%s' "$jobs" | jq -c '[.[] | {name, state: .status, bucket: (
      if .status == "success" then "pass"
      elif .status == "failed" then (if .allow_failure == true then "pass" else "fail" end)
      elif .status == "canceled" then "cancel"
      elif .status == "skipped" or .status == "manual" then "skipping"
      else "pending" end)}]'
    ;;

  commit-checks)
    sha="${1-}"
    [ -n "$sha" ] || { echo "gitlab: commit-checks needs a commit sha" >&2; exit 2; }
    # `all=true` keeps retried statuses: every run on the sha, unreduced — the #91 reduction is
    # ci.verdict's job, not this verb's.
    out=$(_list "projects/$(_id)/repository/commits/$sha/statuses?all=true&per_page=100") || exit 1
    printf '%s' "$out" | jq -c "$JQ_BUCKET"'
      [.[] | .status as $g | (.allow_failure == true) as $af
       | (if $g == "success" then "success"
          elif $g == "failed" then (if $af then "neutral" else "failure" end)
          elif $g == "canceled" then "cancelled"
          elif $g == "skipped" then "skipped"
          elif $g == "running" then "in_progress"
          elif $g == "pending" or $g == "created" or $g == "preparing" then "queued"
          elif $g == "waiting_for_resource" or $g == "scheduled" then "waiting"
          elif $g == "manual" then (if $af then "skipped" else "waiting" end)
          else "UNKNOWN" end) as $s
       | {name, state: $s, bucket: ($s | bucket), id, app: null, html_url: (.target_url // null)}]'
    ;;

  pr-thread-resolve)
    POS=(); BODY_FILE=""; DRY=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift; shift || true ;;
        --dry-run)   DRY=1; shift ;;
        -*) echo "gitlab: pr-thread-resolve: unknown option: $1" >&2; exit 2 ;;
        *)  POS+=("$1"); shift ;;
      esac
    done
    n="${POS[0]-}"; tid="${POS[1]-}"
    [ -n "$n" ] && [ -n "$tid" ] \
      || { echo "gitlab: pr-thread-resolve needs <iid> <discussion-id>" >&2; exit 2; }
    # The reply is REQUIRED (merge-mechanics.md §6: never resolve silently). Reply first, resolve second.
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "gitlab: pr-thread-resolve refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    ep="projects/$(_id)/merge_requests/$n/discussions/$tid"
    if [ "$DRY" -eq 1 ]; then
      echo "DRY-RUN glab api -X POST $ep/notes -F body=@$BODY_FILE then -X PUT $ep?resolved=true"
      exit 0
    fi
    _api -X POST "$ep/notes" -F "body=@$BODY_FILE" > /dev/null || exit 1
    _api -X PUT "$ep?resolved=true" > /dev/null || exit 1
    ;;

  pr-merge)
    n=""; SUBJECT=""; BODY_FILE=""; HAS_BODY=0; DRY=0; FIELDS=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --squash)        FIELDS+=(-F squash=true); shift ;;
        --delete-branch) FIELDS+=(-F should_remove_source_branch=true); shift ;;
        --subject)   [ $# -ge 2 ] || { echo "gitlab: pr-merge: --subject needs a value" >&2; exit 2; }
                     SUBJECT="$2"; shift 2 ;;
        --body-file) HAS_BODY=1; BODY_FILE="${2-}"; shift; shift || true ;;
        --dry-run)   DRY=1; shift ;;
        -*) echo "gitlab: pr-merge: unknown option: $1 (only --squash, --delete-branch, --subject, --body-file)" >&2; exit 2 ;;
        *)  [ -z "$n" ] || { echo "gitlab: pr-merge: unexpected argument: $1" >&2; exit 2; }
            n="$1"; shift ;;
      esac
    done
    [ -n "$n" ] || { echo "gitlab: pr-merge needs a merge request iid" >&2; exit 2; }
    if [ "$HAS_BODY" -eq 1 ]; then
      [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
        || { echo "gitlab: pr-merge refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    fi
    ARGS=(-X PUT "projects/$(_id)/merge_requests/$n/merge" ${FIELDS[@]+"${FIELDS[@]}"})
    HAS_MSG=0; { [ -n "$SUBJECT" ] || [ "$HAS_BODY" -eq 1 ]; } && HAS_MSG=1
    if [ "$DRY" -eq 1 ]; then
      if [ "$HAS_MSG" -eq 1 ]; then
        echo "DRY-RUN glab api ${ARGS[*]} -F squash_commit_message=@<subject, a blank line, the body file>"
      else
        echo "DRY-RUN glab api ${ARGS[*]}"
      fi
      exit 0
    fi
    if [ "$HAS_MSG" -eq 1 ]; then
      # The message goes through a file, never an argument: `<subject>`, a blank line, the body.
      msgf=$(mktemp "${TMPDIR:-/tmp}/gitlab-merge-msg.XXXXXX") || exit 1
      trap 'rm -f "$msgf"' EXIT
      if [ -n "$SUBJECT" ] && [ "$HAS_BODY" -eq 1 ]; then
        { printf '%s\n\n' "$SUBJECT"; cat "$BODY_FILE"; } > "$msgf"
      elif [ -n "$SUBJECT" ]; then
        printf '%s\n' "$SUBJECT" > "$msgf"
      else
        cat "$BODY_FILE" > "$msgf"
      fi
      ARGS+=(-F "squash_commit_message=@$msgf")
    fi
    # The exit code is a hint, never the verdict — the caller reads the outcome back through pr-view.
    _api "${ARGS[@]}" > /dev/null || exit 1
    ;;

  branch-delete)
    b=""; DRY=0
    for a in "$@"; do
      case "$a" in
        --dry-run) DRY=1 ;;
        -*) echo "gitlab: branch-delete: unknown option: $a" >&2; exit 2 ;;
        *)  b="$a" ;;
      esac
    done
    [ -n "$b" ] || { echo "gitlab: branch-delete needs a branch name" >&2; exit 2; }
    # The whole name is one path segment here (GitLab wants `/` as %2F), unlike github.sh's ref path.
    ep="projects/$(_id)/repository/branches/$(_urlenc "$b")"
    if [ "$DRY" -eq 1 ]; then echo "DRY-RUN glab api -X DELETE $ep"; exit 0; fi
    if err=$(_api -X DELETE "$ep" 2>&1); then echo ok; exit 0; fi
    # A 404 naming the branch is one already gone (a concurrent should_remove_source_branch). A wrong
    # project 404s too ("Project Not Found", or a bare 404) — that, and anything else, is real.
    if grep -qE 'Branch Not Found \(HTTP 404\)$' <<<"$err"; then echo gone; exit 0; fi
    echo "gitlab: branch-delete: failed to delete $b: $err" >&2; exit 1
    ;;

  # No issue→issue parent relation (see issue-link-parent): `fallback`, and never a request.
  issue-parent)
    n="${1-}"
    [ -n "$n" ] || { echo "gitlab: issue-parent needs an issue number" >&2; exit 2; }
    echo "fallback"
    ;;

  pr-closing-issues)
    n="${1-}"
    [ -n "$n" ] || { echo "gitlab: pr-closing-issues needs a merge request iid" >&2; exit 2; }
    out=$(_list "projects/$(_id)/merge_requests/$n/closes_issues?per_page=100") || exit 1
    printf '%s' "$out" | jq -c '[.[].iid]'
    ;;

  pr-comment)
    n=""; BODY_FILE=""; DRY=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift; shift || true ;;
        --dry-run)   DRY=1; shift ;;
        -*) echo "gitlab: pr-comment: unknown option: $1" >&2; exit 2 ;;
        *)  n="$1"; shift ;;
      esac
    done
    [ -n "$n" ] || { echo "gitlab: pr-comment needs a merge request iid" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "gitlab: pr-comment refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    ARGS=(-X POST "projects/$(_id)/merge_requests/$n/notes" -F "body=@$BODY_FILE")
    if [ "$DRY" -eq 1 ]; then echo "DRY-RUN glab api ${ARGS[*]}"; exit 0; fi
    _api "${ARGS[@]}" > /dev/null || exit 1
    ;;

  *)
    echo "gitlab: does not implement '$VERB'" >&2
    exit 3
    ;;
esac
