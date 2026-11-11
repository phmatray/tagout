#!/usr/bin/env bash
# github.sh — the GitHub backend of the tracker contract (#505): a verb in, a normalised reply out.
#
# usage: github.sh <verb> [args…]        (invoked by scripts/tracker.sh, not by hand)
#
# GitHub is the REFERENCE backend. Every other host's backend is written against what this one
# prints, and this one is deliberately never reduced to a lowest common denominator: a verb prints
# what GitHub can actually say, and a host that cannot say it answers NOT_IMPLEMENTED rather than
# everyone answering less.
#
# The repository comes from TRACKER_REPO (`tracker.sh --repo <slug>`, or `-R <slug>` leading the
# verb's own arguments — #668), empty for "this checkout".
# The host is resolved through skills/_shared/scripts/_gh-host.sh (#514) rather than left to gh's
# default: `gh -R OWNER/REPO` takes gh's DEFAULT host even inside a GitHub Enterprise checkout, and
# `gh api` never infers a host at all, so every kit script addressing a repository by a bare
# OWNER/REPO used to reach github.com. tests/gh-host/test.sh sweeps for exactly that omission.
#
# NORMALISATION, which is the whole point of a verb having a contract:
#   * `state` is lower-cased — gh answers "OPEN", the contract says "open", and a second backend
#     must not be free to pick either.
#   * `labels` are bare names, not gh's label objects.
#   * `issue-view` declares `"format":"markdown"` explicitly, so a host whose issue bodies are a
#     different dialect cannot quietly hand them back under the same verb.
#
# Exit codes (the dispatcher passes them through):
#   0  the verb answered
#   1  the host refused or failed — auth, network, a 404
#   2  bad invocation: no verb, a missing argument, a malformed slug
#   3  this backend does not implement the verb
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERB="${1-}"
[ -n "$VERB" ] || { echo "github: no verb given" >&2; exit 2; }
shift

# `verbs` is answered FIRST, before the helper is loaded or any host is resolved. The dispatcher
# calls it to decide whether this backend implements a verb at all, and that question must not need
# gh, a network or a credential — a backend that could only introspect itself when authenticated
# would report "not implemented" for every verb on a machine that is merely logged out.
if [ "$VERB" = verbs ]; then
  printf '%s\n' verbs auth repo issue-view \
    issue-search issue-comments issue-create issue-edit-body \
    issue-add-labels issue-remove-labels issue-reopen issue-comment label-list label-create \
    issue-link-parent issue-link-blocked-by issue-children issue-blocked-by-count \
    pr-create pr-list pr-view pr-edit-body pr-ready pr-commits \
    pr-merge-state pr-checks commit-checks pr-threads pr-thread-resolve pr-merge branch-delete \
    issue-parent pr-closing-issues pr-comment issue-list issue-assign
  exit 0
fi

. "$HERE/../../skills/_shared/scripts/_gh-host.sh" || {
  echo "github: REFUSED — cannot load skills/_shared/scripts/_gh-host.sh; reinstall the kit" >&2
  exit 2; }

# `-R <[host/]owner/repo>` LEADING a verb's arguments (#668). Two of the scripts `merge-pr` reads
# just before it reaches a tracker verb take the repository that way, and the shape was transferred
# here and refused — `github: issue-create: unknown option: -R`, twice in an 18-day window. It is
# lifted out of the argv HERE, once for every verb, rather than added to twelve option loops that
# would each then have to re-resolve the host the line below resolves. Leading only: further in, a
# `-R` is an option's VALUE, which this pass has no arity table to recognise.
while [ $# -gt 0 ]; do
  case "$1" in
    -R)  [ $# -ge 2 ] || { echo "github: -R needs a <[host/]owner/repo>" >&2; exit 2; }
         REPO_FLAG="$2"; shift 2 ;;
    -R*) REPO_FLAG="${1#-R}"; shift ;;
    *)   break ;;
  esac
done
if [ -n "${REPO_FLAG-}" ]; then
  # Both spellings at once is fine while they agree; disagreeing, one of two repositories would be
  # written to and the caller could not tell which.
  if [ -n "${TRACKER_REPO-}" ] && [ "$TRACKER_REPO" != "$REPO_FLAG" ]; then
    echo "github: repository given twice and the two disagree: --repo $TRACKER_REPO and -R $REPO_FLAG" >&2
    exit 2
  fi
  TRACKER_REPO="$REPO_FLAG"
fi

# Sets KIT_REPO_SLUG (empty in, empty out) and exports GH_HOST when a host resolves. Returns 2 on a
# malformed slug, having called nothing.
gh_host_resolve "${TRACKER_REPO-}" || exit 2

# Bare OWNER/REPO when a --repo resolved one; gh api's own {owner}/{repo} placeholder (expanded from
# the checkout's own remote) when it did not — the same fallback the kit's prose already used for a
# repo-less call (references/tracking-issue.md's old `gh api repos/{owner}/{repo}/issues/…`).
_repo_slug() { local s="$KIT_REPO_SLUG"; [ -n "$s" ] || s='{owner}/{repo}'; printf '%s' "$s"; }

# Shared by issue-link-parent and issue-link-blocked-by: the DATABASE id the sub-issues and
# dependencies endpoints key on — never the #number, never the GraphQL node id (wire-edges.sh's own
# header used to state this rule; it moved here with the code). TRACKER_ID_CACHE, when a caller sets
# it to a file (wire-edges.sh, wiring several edges from one run), holds "<number> <id>" lines so an
# issue already resolved this run is never looked up twice, and so every id is proven to resolve
# before wire-edges.sh posts its first edge (its own --resolve-only pass, below). Prints the id on
# success; on failure prints gh's own error text and returns 1 — nothing is cached.
_issue_db_id() {
  local n="$1" id=""
  if [ -n "${TRACKER_ID_CACHE:-}" ] && [ -r "$TRACKER_ID_CACHE" ]; then
    id=$(awk -v n="$n" '$1 == n { print $2; exit }' "$TRACKER_ID_CACHE")
    if [ -n "$id" ]; then printf '%s' "$id"; return 0; fi
  fi
  id=$(gh api -H "Accept: application/vnd.github+json" "repos/$(_repo_slug)/issues/$n" --jq .id 2>&1) \
    || { printf '%s' "$id"; return 1; }
  # A SUCCESSFUL call can still hand back something that is not an id, because the `2>&1` above
  # folds stderr into this value and gh writes to stderr on success too: its update notifier, a
  # deprecation notice, a corporate proxy's banner. Unvalidated, such a value was appended to
  # TRACKER_ID_CACHE as a MULTI-LINE entry, poisoning every later `awk '$1==n {print $2}'` lookup
  # for that number, and then POSTed as `-F sub_issue_id=<garbage>` to a MUTATING endpoint with no
  # refusal. This is the guard wire-edges.sh's own id_of() carried before the code moved here; it
  # was dropped in the move, which is the regression (#507 review). Restored, not reinvented.
  case "$id" in
    ''|*[!0-9]*)
      printf "#%s resolved to '%s', which is not a database id" "$n" "$id"; return 1 ;;
  esac
  [ -n "${TRACKER_ID_CACHE:-}" ] && printf '%s %s\n' "$n" "$id" >> "$TRACKER_ID_CACHE"
  printf '%s' "$id"
}

# The classifier both link verbs share — moved from wire-edges.sh's post() unchanged. `gh api`
# reports a non-2xx as `gh: <message> (HTTP <code>)` on stderr and exit 1 (or a bare
# `gh: HTTP <code>` when the error body was not JSON — a proxy's HTML page in front of a GHES host);
# `--silent` drops the JSON body on stdout for a 2xx. Prints ok | fallback | FAILED (HTTP <code>:
# <message>) and returns 0 for ok/fallback, 1 for FAILED — the calling verb's own exit code.
_link_post() {
  local endpoint="$1" field="$2" err code msg
  if err=$(gh api -H "Accept: application/vnd.github+json" --method POST --silent "$endpoint" -F "$field" 2>&1 >/dev/null); then
    echo "ok"; return 0
  fi
  code=$(printf '%s' "$err" | sed -n 's/.*HTTP \([0-9][0-9][0-9]\))\{0,1\}$/\1/p' | head -1)
  msg=$(printf '%s' "$err" | sed -n 's/^gh: \(.*\) (HTTP [0-9][0-9][0-9])$/\1/p' | head -1)
  [ -n "$msg" ] || msg=$(printf '%s' "$err" | tr '\n' ' ')
  case "$code" in
    404) echo "fallback"; return 0 ;;
    422)
      # Measured on github.com (2026-08-31, throwaway issues #346–#348): a second sub_issues POST
      # answers "Issue may not contain duplicate sub-issues and Sub issue may only have one
      # parent"; a second blocked_by POST answers "Validation failed: Target issue has already
      # been taken". `exists` covers the phrasing drifting. Anything else under 422 is a real
      # refusal — a cycle, a cross-repository edge — and stays FAILED.
      case "$msg" in
        *already*|*Already*|*duplicate*|*Duplicate*|*exists*)
          echo "ok (already wired)"; return 0 ;;
      esac
      echo "FAILED (HTTP 422: $msg)"; return 1 ;;
    '') echo "FAILED (no HTTP status in gh's answer: $msg)"; return 1 ;;
    *)  echo "FAILED (HTTP $code: $msg)"; return 1 ;;
  esac
}

# Both link verbs take the same two private flags plus two positionals, and this loop was
# duplicated verbatim between them: a third flag would have to be added identically in two places,
# and a one-line divergence would silently make one verb accept what the other rejects (#507
# review). Sets DRY, RESOLVE_ONLY and POS for the calling verb.
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

# A branch name as a URL path, URI-encoded PER PATH SEGMENT — moved from
# skills/merge-pr/scripts/remote-branch-teardown.sh (#752), its reasoning with it: git branch names
# may legally contain characters that are significant in a URL — `#` in particular delimits a
# fragment and gh silently drops it and everything after, so an unencoded "feature/x#1" would
# DELETE the wrong (truncated, likely nonexistent) ref while the real branch survives on origin. But
# the kit's own branch names are themselves slash-separated ("fix/185-…" — the routine case, not an
# edge case here), and those slashes are real path separators in the REST route, not data to
# escape: encoding the whole string with a flat `@uri` would turn every `/` into `%2F`, which does
# not decode back to a path separator. Split on `/`, encode each segment, rejoin with a literal `/`.
_uri_path() { jq -rn --arg b "$1" '$b | split("/") | map(@uri) | join("/")'; }

# The review threads of PR $1, as the contract's pr-threads array — the ONE read both pr-threads and
# pr-merge-state answer from. Moved from skills/merge-pr/references/merge-mechanics.md §4 (#752).
# `--paginate` is load-bearing: `reviewThreads(first:100)` sits at GitHub's page maximum, so without
# it a PR whose 101st thread is the unresolved one reads as fully resolved and merges. It needs BOTH
# the `$endCursor` variable and the `pageInfo` selection; drop either and it quietly fetches one page.
# A failed query must never yield an empty list — a failed query and a PR with nothing open spell the
# same `[]`, and one of them merges unreviewed (#294) — so `pipefail` (set at the top of this file)
# carries gh's exit status across the `jq` after it, and the caller discards stdout on a non-zero
# return. GH_HOST, exported by gh_host_resolve, is what reaches a GitHub Enterprise host here; without
# it the query fails with "Could not resolve to a Repository" rather than answering empty.
# `-f` for a named repository (a numeric owner must stay a string), `-F` for gh's own {owner}/{repo}
# placeholders, which only -F expands.
# shellcheck disable=SC2016  # $owner, $pr… are GraphQL variables, not shell expansions
_threads() {
  local s fl=-F
  s=$(_repo_slug)
  [ -n "$KIT_REPO_SLUG" ] && fl=-f
  gh api graphql --paginate -f query='
  query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){ repository(owner:$owner,name:$repo){
    pullRequest(number:$pr){ reviewThreads(first:100, after:$endCursor){
      pageInfo{ hasNextPage endCursor }
      nodes{ id isResolved comments(first:1){ nodes{ path line body } } } } } } }' \
    "$fl" owner="${s%%/*}" "$fl" repo="${s#*/}" -F pr="$1" \
    --jq '.data.repository.pullRequest.reviewThreads.nodes[]
          | {id, path: .comments.nodes[0].path, line: .comments.nodes[0].line,
             body: .comments.nodes[0].body, isResolved}' \
    | jq -sc .
}

# gh's own `pr checks` bucket rule, applied to a check-run's lower-cased conclusion // status so
# commit-checks carries the same buckets pr-checks does. Anything unrecognised — UNKNOWN included —
# is pending: an unmapped state waits, it never reads as clear.
JQ_BUCKET='def bucket: if . == "success" then "pass"
  elif . == "skipped" or . == "neutral" then "skipping"
  elif . == "cancelled" then "cancel"
  elif . == "failure" or . == "timed_out" or . == "action_required" or . == "startup_failure"
       or . == "error" then "fail"
  else "pending" end;'

case "$VERB" in
  auth)
    gh api user --jq .login || exit 1
    ;;

  repo)
    # `gh repo view` takes the slug POSITIONALLY — `--repo`/`-R` is an `issue`/`pr` flag and is
    # rejected here. Omitted entirely when there is no slug, so gh reads the checkout itself.
    out=$(gh repo view ${KIT_REPO_SLUG:+"$KIT_REPO_SLUG"} --json nameWithOwner,defaultBranchRef) \
      || exit 1
    # `origin`'s OWNER/REPO, read LOCALLY rather than from gh (#637): unlike `gh repo view` above,
    # which follows GitHub's rename redirect, the Search API does not — a stale `origin` left over
    # from a rename makes every `--search` call answer empty while this call looks unremarkable.
    # Reported alongside `slug` so a caller can compare them; never itself a source for `slug`.
    # `|| origin_url=""`, not a pipe straight into `sed`: `set -o pipefail` (above) would otherwise
    # propagate a no-such-remote `git` failure through the whole pipeline even though `sed` itself
    # succeeds on empty input — the same hazard skills/_shared/scripts/_gh-host.sh's origin parse
    # guards against for the same reason.
    origin_url=$(git remote get-url origin 2>/dev/null) || origin_url=""
    # One `sed -E` call (two -e expressions): strip a trailing `.git`/slash, then capture the last
    # two `/`-or-`:`-delimited path segments — the same expression `_gh-host.sh` already uses to
    # read OWNER/REPO out of an https, `git@host:` or `ssh://` origin uniformly, case preserved
    # (unlike that file's own lower-cased copy, since this value is reported and recapped verbatim).
    origin_arg=$(printf '%s' "$origin_url" \
      | sed -E -e 's#(\.git)?/*$##' -e 's#.*[:/]([^/:]+)/([^/:]+)$#\1/\2#')
    printf '%s' "$out" | jq -c --arg host "${GH_HOST:-github.com}" --arg origin "$origin_arg" \
      '($origin | split("/")) as $p |
       {slug: .nameWithOwner, host: $host, defaultBranch: (.defaultBranchRef.name // null),
        originSlug: (if ($p | length) == 2 and ($p[0] | length) > 0 and ($p[1] | length) > 0
                     then $origin else null end)}'
    ;;

  issue-view)
    n="${1-}"
    [ -n "$n" ] || { echo "github: issue-view needs an issue number" >&2; exit 2; }
    out=$(gh issue view "$n" ${KIT_REPO_SLUG:+--repo "$KIT_REPO_SLUG"} \
            --json number,title,state,body,labels,url) || exit 1
    printf '%s' "$out" | jq -c \
      '{number, title, state: (.state | ascii_downcase), body,
        labels: [(.labels // [])[].name], url, format: "markdown"}'
    ;;

  issue-search)
    # Every filter is optional — a bare `issue-search` with no --query is valid (Step 3's
    # open-refactor scan filters by --label alone). --label may repeat.
    Q=""; ST=""; LIM=""; LBLS=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --query) Q="${2-}"; shift 2 ;;
        --state) ST="${2-}"; shift 2 ;;
        --label) LBLS+=("${2-}"); shift 2 ;;
        --limit) LIM="${2-}"; shift 2 ;;
        *) echo "github: issue-search: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    ARGS=(issue list --json number,title,state)
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    [ -n "$Q" ] && ARGS+=(--search "$Q")
    [ -n "$ST" ] && ARGS+=(--state "$ST")
    [ -n "$LIM" ] && ARGS+=(--limit "$LIM")
    if [ "${#LBLS[@]}" -gt 0 ]; then
      for l in "${LBLS[@]}"; do ARGS+=(--label "$l"); done
    fi
    out=$(gh "${ARGS[@]}") || exit 1
    printf '%s' "$out" | jq -c '[.[] | {number, title, state: (.state | ascii_downcase)}]'
    ;;

  issue-list)
    # auto-dev's survey (#753): today's `gh issue list` argv plus createdAt, so tests/survey's stub
    # and its flag allow-list (#452) still match. `--limit`, never `--paginate`: gh issue list pages
    # internally up to N and has no --paginate flag at all.
    ST=""; LIM=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --state) ST="${2-}"; shift 2 ;;
        --limit) LIM="${2-}"; shift 2 ;;
        *) echo "github: issue-list: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    case "$ST" in ''|open) ;; *) echo "github: issue-list: --state is open" >&2; exit 2 ;; esac
    ARGS=(issue list --state open)
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    [ -n "$LIM" ] && ARGS+=(--limit "$LIM")
    BASE_FIELDS=number,title,labels,body,comments,createdAt
    # The dependency fields are not universal: gh validates --json field names itself and exits 1
    # with `Unknown JSON field: "blockedBy"` on any build predating issue dependencies — before any
    # jq runs. An empty survey reads as "backlog drained" (#213), so this asks once more with the
    # base fields and degrades LOUDLY: every edge prints null, the frontier rule holds nothing, and
    # the operator is told so on stderr. The error text is read by re-running the call rather than
    # through a temp file — survey's case 9 shadows mktemp on PATH, and a hard $(mktemp) here would
    # turn that infra fallback into an abort.
    if out=$(gh "${ARGS[@]}" --json "$BASE_FIELDS,blockedBy,blocking,subIssues,assignees" 2>/dev/null); then
      FULL=1
    else
      err=$(gh "${ARGS[@]}" --json "$BASE_FIELDS,blockedBy,blocking,subIssues,assignees" 2>&1 >/dev/null) || true
      if printf '%s' "$err" | grep -qi 'unknown json field'; then
        echo "github: issue-list: this gh cannot serve the dependency fields (blockedBy/blocking/subIssues) — falling back to $BASE_FIELDS. Every edge then reads null, so the frontier rule holds NOTHING and a blocked child can be dispatched ahead of its blocker (#317). Upgrade gh to restore it. gh said: $(printf '%s' "$err" | tr '\n' ' ')" >&2
        out=$(gh "${ARGS[@]}" --json "$BASE_FIELDS") || exit 1
        FULL=0
      else
        printf '%s\n' "${err:-github: issue-list: gh issue list failed}" >&2
        exit 1
      fi
    fi
    # Each edge becomes the contract's connection: gh serves GraphQL connections ({nodes,
    # totalCount}), an older build plain arrays (counted by their length), and an absent field null.
    printf '%s' "$out" | jq -c --argjson full "$FULL" '
      def node: if type == "number" then {number: ., state: null}
                else {number: (.number // null), state: (if .state then (.state | ascii_upcase) else null end)} end;
      def edge: if $full == 0 then null
                elif type == "object" then {nodes: [(.nodes // [])[] | node], totalCount: (.totalCount // ((.nodes // []) | length))}
                elif type == "array" then {nodes: map(node), totalCount: length}
                else null end;
      [.[] | {number, title, labels: [(.labels // [])[].name], body, comments: [(.comments // [])[].body],
              createdAt: (.createdAt // null),
              blockedBy: (.blockedBy | edge), blocking: (.blocking | edge), subIssues: (.subIssues | edge),
              assignees: (if $full == 0 then null else [(.assignees // [])[].login] end)}]' || exit 1
    ;;

  issue-assign)
    n=""; DRY=0
    for a in "$@"; do
      case "$a" in
        --dry-run) DRY=1 ;;
        -*) echo "github: issue-assign: unknown option: $a" >&2; exit 2 ;;
        *) n="$a" ;;
      esac
    done
    [ -n "$n" ] || { echo "github: issue-assign needs an issue number" >&2; exit 2; }
    # Today's call, unchanged. gh adds the assignee idempotently, so an assigned issue prints ok too.
    ARGS=(issue edit "$n")
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    ARGS+=(--add-assignee @me)
    if [ "$DRY" -eq 1 ]; then echo "DRY-RUN gh ${ARGS[*]}"; exit 0; fi
    gh "${ARGS[@]}" >/dev/null || exit 1
    echo ok
    ;;

  issue-comments)
    n="${1-}"
    [ -n "$n" ] || { echo "github: issue-comments needs an issue number" >&2; exit 2; }
    out=$(gh issue view "$n" ${KIT_REPO_SLUG:+--repo "$KIT_REPO_SLUG"} --json comments) || exit 1
    printf '%s' "$out" | jq -c '[.comments[].body]'
    ;;

  issue-create)
    TITLE=""; BODY_FILE=""; LBLS=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --title)     TITLE="${2-}"; shift 2 ;;
        --label)     LBLS+=("${2-}"); shift 2 ;;
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        *) echo "github: issue-create: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$TITLE" ] || { echo "github: issue-create needs --title" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "github: issue-create needs a non-empty --body-file" >&2; exit 2; }
    ARGS=(issue create --title "$TITLE" --body-file "$BODY_FILE")
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    # A label not in the live set is passed through UNFILTERED — this verb does not second-guess
    # it. gh's own behaviour on an unknown --label is to FAIL THE WHOLE CALL (exit 1, nothing
    # filed), not to create the issue without it, exactly as a direct `gh issue create --label`
    # does today. The caller (create-issue Step 7) is what checks the live label set first and
    # drops what isn't there, before ever reaching this verb — that pre-filtering is what makes
    # "create without it rather than failing" true, not anything this backend does.
    if [ "${#LBLS[@]}" -gt 0 ]; then
      for l in "${LBLS[@]}"; do ARGS+=(--label "$l"); done
    fi
    url=$(gh "${ARGS[@]}") || exit 1
    num=$(printf '%s' "$url" | grep -oE '[0-9]+$') || {
      echo "github: issue-create: could not read an issue number off of: $url" >&2; exit 1; }
    jq -nc --arg n "$num" --arg u "$url" '{number: ($n | tonumber), url: $u}'
    ;;

  issue-edit-body)
    n="${1-}"; shift || true
    BODY_FILE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        *) echo "github: issue-edit-body: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$n" ] || { echo "github: issue-edit-body needs an issue number" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "github: issue-edit-body refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    gh issue edit "$n" ${KIT_REPO_SLUG:+--repo "$KIT_REPO_SLUG"} --body-file "$BODY_FILE" || exit 1
    ;;

  issue-add-labels)
    n="${1-}"; shift || true
    [ -n "$n" ] || { echo "github: issue-add-labels needs an issue number" >&2; exit 2; }
    [ $# -gt 0 ] || { echo "github: issue-add-labels needs at least one label" >&2; exit 2; }
    ARGS=(issue edit "$n")
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    for l in "$@"; do ARGS+=(--add-label "$l"); done
    gh "${ARGS[@]}" || exit 1
    ;;

  issue-remove-labels)
    n="${1-}"; shift || true
    [ -n "$n" ] || { echo "github: issue-remove-labels needs an issue number" >&2; exit 2; }
    [ $# -gt 0 ] || { echo "github: issue-remove-labels needs at least one label" >&2; exit 2; }
    ARGS=(issue edit "$n")
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    for l in "$@"; do ARGS+=(--remove-label "$l"); done
    gh "${ARGS[@]}" || exit 1
    ;;

  issue-reopen)
    n="${1-}"; shift || true
    BODY_FILE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        *) echo "github: issue-reopen: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$n" ] || { echo "github: issue-reopen needs an issue number" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "github: issue-reopen refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    # gh's own `issue reopen` has no --body-file (only -c/--comment string) — the file is read
    # here, at the backend boundary, rather than asking every caller to pass a multi-kilobyte
    # reopening comment as a command-line argument.
    gh issue reopen "$n" ${KIT_REPO_SLUG:+--repo "$KIT_REPO_SLUG"} --comment "$(cat "$BODY_FILE")" || exit 1
    ;;

  issue-comment)
    n="${1-}"; shift || true
    BODY_FILE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        *) echo "github: issue-comment: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$n" ] || { echo "github: issue-comment needs an issue number" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "github: issue-comment refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    gh issue comment "$n" ${KIT_REPO_SLUG:+--repo "$KIT_REPO_SLUG"} --body-file "$BODY_FILE" || exit 1
    ;;

  label-list)
    ARGS=(label list --json name --limit 100)
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    out=$(gh "${ARGS[@]}") || exit 1
    printf '%s' "$out" | jq -r '.[].name'
    ;;

  # Not one of the nine filing verbs Task 1 (#506) named, but the SAME migration (Step 7's Sub-area
  # bullet grows the taxonomy with `gh label create` when no fitting label exists) — added here
  # rather than left as the one direct `gh label` call AC5 would otherwise still catch.
  label-create)
    NAME="${1-}"; shift || true
    COLOR=""; DESC=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --color)       COLOR="${2-}"; shift 2 ;;
        --description) DESC="${2-}"; shift 2 ;;
        *) echo "github: label-create: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$NAME" ] || { echo "github: label-create needs a name" >&2; exit 2; }
    ARGS=(label create "$NAME")
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    [ -n "$COLOR" ] && ARGS+=(--color "$COLOR")
    [ -n "$DESC" ] && ARGS+=(--description "$DESC")
    gh "${ARGS[@]}" || exit 1
    ;;

  # The two link verbs (#507) — wire-edges.sh's own SUB/DEP edges, moved off its direct `gh api`
  # calls. `--resolve-only` is wire-edges.sh's own private flag, not part of the verb's public
  # contract: it resolves (and, with TRACKER_ID_CACHE set, caches) both ends without posting, which
  # is how wire-edges.sh proves every id in a whole run resolves before it wires its first edge.
  issue-link-parent)
    _parse_link_args "$@"
    P="${POS[0]-}"; C="${POS[1]-}"
    [ -n "$P" ] && [ -n "$C" ] \
      || { echo "github: issue-link-parent needs <parent> <child>" >&2; exit 2; }
    if [ "$DRY" -eq 1 ]; then
      echo "DRY-RUN POST repos/$(_repo_slug)/issues/$P/sub_issues -F sub_issue_id=<database id of #$C>"
      exit 0
    fi
    pid=$(_issue_db_id "$P") \
      || { echo "github: issue-link-parent: cannot resolve the database id of #$P — $pid" >&2; exit 1; }
    cid=$(_issue_db_id "$C") \
      || { echo "github: issue-link-parent: cannot resolve the database id of #$C — $cid" >&2; exit 1; }
    [ "$RESOLVE_ONLY" -eq 1 ] && exit 0
    _link_post "repos/$(_repo_slug)/issues/$P/sub_issues" "sub_issue_id=$cid"
    ;;

  issue-link-blocked-by)
    _parse_link_args "$@"
    C="${POS[0]-}"; B="${POS[1]-}"
    [ -n "$C" ] && [ -n "$B" ] \
      || { echo "github: issue-link-blocked-by needs <child> <blocker>" >&2; exit 2; }
    if [ "$DRY" -eq 1 ]; then
      echo "DRY-RUN POST repos/$(_repo_slug)/issues/$C/dependencies/blocked_by -F issue_id=<database id of #$B>"
      exit 0
    fi
    cid=$(_issue_db_id "$C") \
      || { echo "github: issue-link-blocked-by: cannot resolve the database id of #$C — $cid" >&2; exit 1; }
    bid=$(_issue_db_id "$B") \
      || { echo "github: issue-link-blocked-by: cannot resolve the database id of #$B — $bid" >&2; exit 1; }
    [ "$RESOLVE_ONLY" -eq 1 ] && exit 0
    _link_post "repos/$(_repo_slug)/issues/$C/dependencies/blocked_by" "issue_id=$bid"
    ;;

  issue-children)
    n="${1-}"
    [ -n "$n" ] || { echo "github: issue-children needs a parent issue number" >&2; exit 2; }
    if out=$(gh api -H "Accept: application/vnd.github+json" "repos/$(_repo_slug)/issues/$n/sub_issues" 2>&1); then
      printf '%s' "$out" | jq -c '[.[].number]'
    elif grep -q 'HTTP 404' <<<"$out"; then
      # Two spellings, same as the link verbs' own classifier: `gh: <message> (HTTP 404)` and the
      # bare `gh: HTTP 404` a GHES proxy's non-JSON error body produces — both must read as
      # "the feature is off", not as "no status" (#507 review).
      echo "fallback"
    else
      echo "github: issue-children: $out" >&2; exit 1
    fi
    ;;

  issue-blocked-by-count)
    n="${1-}"
    [ -n "$n" ] || { echo "github: issue-blocked-by-count needs an issue number" >&2; exit 2; }
    if out=$(gh api -H "Accept: application/vnd.github+json" "repos/$(_repo_slug)/issues/$n" \
               --jq '.issue_dependencies_summary.blocked_by // "n/a"' 2>&1); then
      printf '%s\n' "$out"
    elif grep -q 'HTTP 404' <<<"$out"; then
      # 404 is the documented "the dependencies feature is off" answer, read the same way
      # issue-children reads it. Every OTHER failure (401 bad credentials, 403, a network error, a
      # rate limit) is a REAL failure and must not be laundered into that same `n/a`: Step 7's
      # readback exists to be "the proof the edges exist where GitHub reads them", and an `n/a` on
      # an auth error reads as a benign degraded host, so an operator moves on instead of
      # investigating (#507 review).
      printf 'n/a\n'
    else
      echo "github: issue-blocked-by-count: $out" >&2; exit 1
    fi
    ;;

  # The six PR verbs (#751) — implement-issue's draft PR, its plan mirror and its ready-flip. Each
  # issues the same `gh pr …` command the scripts issued before the move, argv order included
  # (number, then --repo, then --json), so a caller's recorded-argv assertion still matches.
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
        *) echo "github: pr-create: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$BASE" ] && [ -n "$HEAD" ] && [ -n "$TITLE" ] \
      || { echo "github: pr-create needs --base, --head and --title" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "github: pr-create refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    ARGS=(pr create)
    [ "$DRAFT" -eq 1 ] && ARGS+=(--draft)
    ARGS+=(--base "$BASE" --head "$HEAD" --title "$TITLE" --body-file "$BODY_FILE")
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    if [ "$DRY" -eq 1 ]; then echo "DRY-RUN gh ${ARGS[*]}"; exit 0; fi
    url=$(gh "${ARGS[@]}") || exit 1
    num=$(printf '%s' "$url" | grep -oE '[0-9]+$') || {
      echo "github: pr-create: could not read a PR number off of: $url" >&2; exit 1; }
    jq -nc --arg n "$num" --arg u "$url" '{number: ($n | tonumber), url: $u}'
    ;;

  pr-list)
    HEAD=""; Q=""; ST=""; LIM=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --head)   HEAD="${2-}"; shift 2 ;;
        --search) Q="${2-}"; shift 2 ;;
        --state)  ST="${2-}"; shift 2 ;;
        --limit)  LIM="${2-}"; shift 2 ;;
        *) echo "github: pr-list: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    case "$ST" in ''|open|merged) ;; *) echo "github: pr-list: --state is open or merged" >&2; exit 2 ;; esac
    ARGS=(pr list)
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    [ -n "$HEAD" ] && ARGS+=(--head "$HEAD")
    # The contract's --search matches the PR BODY (its one caller looks for closing keywords).
    [ -n "$Q" ] && ARGS+=(--search "$Q in:body")
    [ -n "$ST" ] && ARGS+=(--state "$ST")
    [ -n "$LIM" ] && ARGS+=(--limit "$LIM")
    ARGS+=(--json number,title,url,state,isDraft,headRefName,body,mergedAt)
    out=$(gh "${ARGS[@]}") || exit 1
    printf '%s' "$out" | jq -c '[.[] | {number, title, url, state: ((.state // "") | ascii_downcase),
      isDraft, headBranch: .headRefName, body, mergedAt: (.mergedAt // null)}]'
    ;;

  pr-view)
    n="${1-}"
    [ -n "$n" ] || { echo "github: pr-view needs a PR number" >&2; exit 2; }
    out=$(gh pr view "$n" ${KIT_REPO_SLUG:+--repo "$KIT_REPO_SLUG"} \
            --json number,title,url,state,isDraft,body,headRefName,baseRefName,headRefOid,author,mergedAt,mergeCommit) || exit 1
    printf '%s' "$out" | jq -c '{number, title, url, state: (.state | ascii_downcase), isDraft, body,
      headBranch: .headRefName, baseBranch: .baseRefName, headSha: .headRefOid,
      author: (.author.login // null), mergedAt: (.mergedAt // null),
      mergeSha: (.mergeCommit.oid // null)}'
    ;;

  pr-edit-body)
    n="${1-}"; shift || true
    BODY_FILE=""; DRY=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        --dry-run)   DRY=1; shift ;;
        *) echo "github: pr-edit-body: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$n" ] || { echo "github: pr-edit-body needs a PR number" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "github: pr-edit-body refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    ARGS=(pr edit "$n")
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    ARGS+=(--body-file "$BODY_FILE")
    if [ "$DRY" -eq 1 ]; then echo "DRY-RUN gh ${ARGS[*]}"; exit 0; fi
    gh "${ARGS[@]}" || exit 1
    ;;

  pr-ready)
    n=""; DRY=0
    for a in "$@"; do
      case "$a" in
        --dry-run) DRY=1 ;;
        -*) echo "github: pr-ready: unknown option: $a" >&2; exit 2 ;;
        *) n="$a" ;;
      esac
    done
    [ -n "$n" ] || { echo "github: pr-ready needs a PR number" >&2; exit 2; }
    ARGS=(pr ready "$n")
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    if [ "$DRY" -eq 1 ]; then echo "DRY-RUN gh ${ARGS[*]}"; exit 0; fi
    gh "${ARGS[@]}" || exit 1
    ;;

  pr-commits)
    n="${1-}"
    [ -n "$n" ] || { echo "github: pr-commits needs a PR number" >&2; exit 2; }
    out=$(gh pr view "$n" ${KIT_REPO_SLUG:+--repo "$KIT_REPO_SLUG"} --json commits) || exit 1
    printf '%s' "$out" | jq -c '[.commits[].oid]'
    ;;

  # The ten merge-pr verbs (#752). Each sends the argv merge-pr's scripts and prose send today, so
  # tests/merge-base-ci's path-matching stub and tests/guarded-pr-merge's cases still match.
  pr-merge-state)
    n="${1-}"
    [ -n "$n" ] || { echo "github: pr-merge-state needs a PR number" >&2; exit 2; }
    # Every read lands in a variable before anything prints: a failed read is exit 1 with an EMPTY
    # stdout, never a partial state that a caller could hand to merge.step4.
    view=$(gh pr view "$n" ${KIT_REPO_SLUG:+--repo "$KIT_REPO_SLUG"} \
             --json mergeStateStatus,isDraft,reviewDecision,baseRefName,headRefName,headRepositoryOwner,isCrossRepository) || exit 1
    base=$(printf '%s' "$view" | jq -r '.baseRefName // empty')
    head=$(printf '%s' "$view" | jq -r '.headRefName // empty')
    [ -n "$base" ] && [ -n "$head" ] \
      || { echo "github: pr-merge-state: PR #$n reported no base or head branch" >&2; exit 1; }
    # A fork PR's head branch is not in the base repository, so a bare `base...head` 404s there; the
    # compare API names it `<owner>:<head>`.
    headref=$(_uri_path "$head")
    owner=$(printf '%s' "$view" | jq -r 'if .isCrossRepository == true then .headRepositoryOwner.login // empty else empty end')
    [ -n "$owner" ] && headref="$owner:$headref"
    # `base...head` — three dots — gives behind_by relative to the base; reversing it silently
    # inverts the answer. This read and the pr view above are sequential, not atomic: a sibling PR
    # merging between them yields behind_by 0 beside BEHIND, which merge.step4's behind-state rule
    # answers for.
    behind=$(gh api "repos/$(_repo_slug)/compare/$(_uri_path "$base")...$headref" \
               --jq .behind_by) || exit 1
    case "$behind" in
      ''|*[!0-9]*) echo "github: pr-merge-state: compare answered behind_by '$behind'" >&2; exit 1 ;;
    esac
    threads=$(_threads "$n") || {
      echo "github: pr-merge-state: the reviewThreads query failed — an unanswered query is not 'no threads'" >&2
      exit 1; }
    # Paths, not a count, so the recap can say WHICH threads were cleared; a thread with no inline
    # path (a PR-level conversation) still counts, under `(pr-level)`.
    printf '%s' "$view" | jq -c --argjson b "$behind" --argjson t "$threads" \
      '{behind_by: $b, mergeStateStatus, isDraft, reviewDecision,
        unresolved_threads: [$t[] | select(.isResolved == false) | .path // "(pr-level)"]}'
    ;;

  pr-threads)
    n="${1-}"
    [ -n "$n" ] || { echo "github: pr-threads needs a PR number" >&2; exit 2; }
    threads=$(_threads "$n") || {
      echo "github: pr-threads: the reviewThreads query failed — an unanswered query is not 'no threads'" >&2
      exit 1; }
    printf '%s\n' "$threads"
    ;;

  pr-checks)
    n="${1-}"
    [ -n "$n" ] || { echo "github: pr-checks needs a PR number" >&2; exit 2; }
    errf=$(mktemp "${TMPDIR:-/tmp}/github-pr-checks.XXXXXX") || exit 1
    trap 'rm -f "$errf"' EXIT
    if out=$(gh pr checks "$n" ${KIT_REPO_SLUG:+--repo "$KIT_REPO_SLUG"} --json name,state,bucket 2>"$errf"); then
      printf '%s' "$out" | jq -c '[.[] | {name, state, bucket}]'
    elif grep -qi 'no checks reported' "$errf"; then
      # gh answers a PR with no checks at all by FAILING with this message — a genuine zero, the
      # one failure that is an answer (wait-ci.sh used to make this call itself, #752).
      echo '[]'
    else
      cat "$errf" >&2; exit 1
    fi
    ;;

  commit-checks)
    sha="${1-}"
    [ -n "$sha" ] || { echo "github: commit-checks needs a commit sha" >&2; exit 2; }
    # Exactly base-run-verdict.sh's call. Every run, superseded ones included: the #91 reduction
    # (newest run per name, grouped by app) is ci.verdict's job, its one home (#208), not this verb's.
    out=$(gh api "repos/$(_repo_slug)/commits/$sha/check-runs" --paginate --slurp) || exit 1
    [ -n "$out" ] || { echo "github: commit-checks: check-runs answered nothing for $sha" >&2; exit 1; }
    printf '%s' "$out" | jq -c "$JQ_BUCKET"'
      [.[].check_runs[] | (.conclusion // .status // "UNKNOWN") as $s
       | {name, state: $s, bucket: ($s | bucket), id, app: .app.id, html_url}]'
    ;;

  pr-thread-resolve)
    POS=(); BODY_FILE=""; DRY=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift; shift || true ;;
        --dry-run)   DRY=1; shift ;;
        -*) echo "github: pr-thread-resolve: unknown option: $1" >&2; exit 2 ;;
        *)  POS+=("$1"); shift ;;
      esac
    done
    n="${POS[0]-}"; tid="${POS[1]-}"
    [ -n "$n" ] && [ -n "$tid" ] \
      || { echo "github: pr-thread-resolve needs <number> <thread-id>" >&2; exit 2; }
    # The reply is REQUIRED: resolving silently clears the gate and deletes the reason. Reply first,
    # resolve second, always in that order (merge-mechanics.md §6).
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "github: pr-thread-resolve refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    if [ "$DRY" -eq 1 ]; then
      echo "DRY-RUN gh api graphql addPullRequestReviewThreadReply(threadId: $tid, body: @$BODY_FILE) then resolveReviewThread(threadId: $tid) on PR #$n"
      exit 0
    fi
    # shellcheck disable=SC2016  # $id, $body are GraphQL variables, not shell expansions
    gh api graphql -f query='
  mutation($id:ID!,$body:String!){ addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$id, body:$body}){ comment{ id } } }' \
      -f id="$tid" -F body=@"$BODY_FILE" > /dev/null || exit 1
    # shellcheck disable=SC2016
    gh api graphql -f query='
  mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' \
      -f id="$tid" > /dev/null || exit 1
    ;;

  pr-merge)
    n=""; FLAGS=(); BODY_FILE=""; HAS_BODY=0; DRY=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --squash|--delete-branch) FLAGS+=("$1"); shift ;;
        --subject)   [ $# -ge 2 ] || { echo "github: pr-merge: --subject needs a value" >&2; exit 2; }
                     FLAGS+=(--subject "$2"); shift 2 ;;
        --body-file) HAS_BODY=1; BODY_FILE="${2-}"; FLAGS+=(--body-file "$BODY_FILE"); shift; shift || true ;;
        --dry-run)   DRY=1; shift ;;
        -*) echo "github: pr-merge: unknown option: $1 (only --squash, --delete-branch, --subject, --body-file)" >&2; exit 2 ;;
        *)  [ -z "$n" ] || { echo "github: pr-merge: unexpected argument: $1" >&2; exit 2; }
            n="$1"; shift ;;
      esac
    done
    [ -n "$n" ] || { echo "github: pr-merge needs a PR number" >&2; exit 2; }
    if [ "$HAS_BODY" -eq 1 ]; then
      [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
        || { echo "github: pr-merge refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    fi
    # Number, then --repo, then the flags in the order given — the argv guarded-pr-merge.sh sent.
    ARGS=(pr merge "$n")
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    ARGS+=(${FLAGS[@]+"${FLAGS[@]}"})
    if [ "$DRY" -eq 1 ]; then echo "DRY-RUN gh ${ARGS[*]}"; exit 0; fi
    # stdout dropped so a gh status line can never land on a caller's captured stdout; stderr passes
    # through. The exit code is a hint, never the verdict — the caller reads the outcome back
    # through pr-view.
    gh "${ARGS[@]}" > /dev/null || exit 1
    ;;

  branch-delete)
    b=""; DRY=0
    for a in "$@"; do
      case "$a" in
        --dry-run) DRY=1 ;;
        -*) echo "github: branch-delete: unknown option: $a" >&2; exit 2 ;;
        *)  b="$a" ;;
      esac
    done
    [ -n "$b" ] || { echo "github: branch-delete needs a branch name" >&2; exit 2; }
    ep="repos/$(_repo_slug)/git/refs/heads/$(_uri_path "$b")"
    if [ "$DRY" -eq 1 ]; then echo "DRY-RUN gh api -X DELETE $ep"; exit 0; fi
    if err=$(gh api -X DELETE "$ep" 2>&1); then echo ok; exit 0; fi
    # Same tolerance gh's own deleteRemoteBranch() applies: a delete that lost the race against a
    # concurrent delete_branch_on_merge or a slow --delete-branch answers "Reference does not
    # exist", on either a 422 or a 404. Matched on the MESSAGE, not the HTTP code alone — any
    # 422/404 would also swallow a real failure that happens to share a status (a nonexistent repo
    # 404s for a wholly different reason). Anything without this exact phrase is a real failure.
    if grep -qF 'Reference does not exist' <<<"$err"; then echo gone; exit 0; fi
    echo "github: branch-delete: failed to delete $b: $err" >&2; exit 1
    ;;

  issue-parent)
    n="${1-}"
    [ -n "$n" ] || { echo "github: issue-parent needs an issue number" >&2; exit 2; }
    # Moved from skills/merge-pr/scripts/parent-decision-note.sh (#752). REST, not the `parent` JSON
    # field of `gh issue view`: gh 2.87.3 lacks it (#762).
    rc=0
    out=$(gh api -H "Accept: application/vnd.github+json" "repos/$(_repo_slug)/issues/$n/parent" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      case "$out" in
        *"No parent issue found"*) echo none; exit 0 ;;
        *"HTTP 404"*)
          # Any OTHER 404 is the sub-issues API being unavailable on this host, not "no parent"
          # (#762): fallback, so the caller can look for the parent another way.
          echo "github: issue-parent: this host's sub-issues API is unavailable (HTTP 404)" >&2
          echo fallback; exit 0 ;;
      esac
      echo "github: issue-parent: gh api repos/$(_repo_slug)/issues/$n/parent failed: $out" >&2; exit 1
    fi
    printf '%s' "$out" | jq -e . > /dev/null 2>&1 \
      || { echo "github: issue-parent: unparseable answer for #$n: $out" >&2; exit 1; }
    parent=$(printf '%s' "$out" | jq -r '.number // empty')
    [ -n "$parent" ] || { echo none; exit 0; }
    case "$parent" in
      *[!0-9]*) echo "github: issue-parent: #$n's parent resolved to '$parent', which is not an issue number" >&2; exit 1 ;;
    esac
    # A parent in another repository must never be read by number in this one (#781). The REST
    # payload is the parent issue itself: its `repository_url` (else `html_url`) names its
    # repository. A payload with neither is the same-repository shape and passes.
    purl=$(printf '%s' "$out" | jq -r '.repository_url // empty')
    if [ -n "$purl" ]; then
      # api host: https://api.<host>/repos/<o>/<r>; GHES: https://<host>/api/v3/repos/<o>/<r>
      pslug=$(printf '%s' "$purl" | sed -E 's#^.*/repos/([^/]+/[^/]+)/?$#\1#')
    else
      purl=$(printf '%s' "$out" | jq -r '.html_url // empty')
      pslug=""
      [ -z "$purl" ] || pslug=$(printf '%s' "$purl" | sed -E 's#^https?://[^/]+/([^/]+/[^/]+)(/.*)?$#\1#')
    fi
    if [ -n "$purl" ]; then
      own="$KIT_REPO_SLUG"
      # No --repo: the checkout's own repository, read only when there is something to compare.
      [ -n "$own" ] || own=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || exit 1
      if [ "$(printf '%s' "$pslug" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$own" | tr '[:upper:]' '[:lower:]')" ]; then
        echo "github: issue-parent: #$n's parent #$parent lives in '$pslug', not '$own' — refusing a cross-repository parent" >&2
        exit 1
      fi
    fi
    printf '%s\n' "$parent"
    ;;

  pr-closing-issues)
    n="${1-}"
    [ -n "$n" ] || { echo "github: pr-closing-issues needs a PR number" >&2; exit 2; }
    out=$(gh pr view "$n" ${KIT_REPO_SLUG:+--repo "$KIT_REPO_SLUG"} --json closingIssuesReferences) || exit 1
    printf '%s' "$out" | jq -c '[(.closingIssuesReferences // [])[].number]'
    ;;

  pr-comment)
    n=""; BODY_FILE=""; DRY=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift; shift || true ;;
        --dry-run)   DRY=1; shift ;;
        -*) echo "github: pr-comment: unknown option: $1" >&2; exit 2 ;;
        *)  n="$1"; shift ;;
      esac
    done
    [ -n "$n" ] || { echo "github: pr-comment needs a PR number" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "github: pr-comment refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    ARGS=(pr comment "$n")
    [ -n "$KIT_REPO_SLUG" ] && ARGS+=(--repo "$KIT_REPO_SLUG")
    ARGS+=(--body-file "$BODY_FILE")
    if [ "$DRY" -eq 1 ]; then echo "DRY-RUN gh ${ARGS[*]}"; exit 0; fi
    gh "${ARGS[@]}" > /dev/null || exit 1
    ;;

  *)
    echo "github: does not implement '$VERB'" >&2
    exit 3
    ;;
esac
