#!/usr/bin/env bash
# azure-devops.sh — the Azure DevOps backend of the tracker contract (#509): a verb in, a
# normalised reply out, via `az boards` / `az repos` / `az devops invoke`. Decides nothing — same
# contract as scripts/tracker/github.sh, the reference backend; see
# skills/_shared/tracker-contract.md for the vocabulary (verb, backend, fallback).
#
# Every WRITE goes through `az devops invoke` with a JSON-patch document built by
# `jq -n --rawfile`, so a multi-KB description never passes through argv or a shell quoting layer,
# and never through either of `az boards`' own work-item write sub-commands — neither can set
# `multilineFieldsFormat` (azure-devops-cli-extension#1473), and a description written without it
# lands as HTML, where a plan's checkboxes are not checkboxes (AC6 greps for this).
#
# Organisation and project are NOT flags on any verb here — they come from the committed repo
# profile's Tracker line (`skills/profile-repo/scripts/repo-profile.sh tracker`, e.g.
# `azure-devops dev.azure.com/acme/Shop`), or from `$TRACKER_REPO` (`<org>/<project>`) as an
# override when the caller already resolved it.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERB="${1-}"
[ -n "$VERB" ] || { echo "azure-devops: no verb given" >&2; exit 2; }
shift

# `verbs` is answered before anything else loads — no profile read, no network — the contract's
# own introspection call. label-create is on this list because create-issue's contract entry
# (contract.json's skills.create-issue) needs it for `tracker.capable` to answer capable; see its
# case below for why it does no `az` call at all.
if [ "$VERB" = verbs ]; then
  printf '%s\n' verbs auth repo issue-view \
    issue-search issue-comments issue-create issue-edit-body \
    issue-add-labels issue-remove-labels issue-reopen issue-comment label-list label-create \
    issue-link-parent issue-link-blocked-by issue-children issue-blocked-by-count
  exit 0
fi

command -v jq >/dev/null 2>&1 || { echo "azure-devops: jq is missing" >&2; exit 2; }
command -v az >/dev/null 2>&1 || { echo "azure-devops: az CLI is missing" >&2; exit 2; }

# --------------------------------------------------------------------- org/project resolution
ORG=""
PROJECT=""
_org_project() {
  if [ -n "${TRACKER_REPO:-}" ]; then
    ORG="${TRACKER_REPO%%/*}"
    PROJECT="${TRACKER_REPO#*/}"
    [ -n "$ORG" ] && [ -n "$PROJECT" ] && [ "$ORG" != "$TRACKER_REPO" ] && return 0
    echo "azure-devops: \$TRACKER_REPO '$TRACKER_REPO' is not '<org>/<project>'" >&2
    return 1
  fi
  local line detail
  line="$("$HERE/../../skills/profile-repo/scripts/repo-profile.sh" tracker 2>/dev/null)" || {
    echo "azure-devops: no committed repo profile to read the org/project from — run profile-repo" >&2
    return 1
  }
  detail="${line#* }"
  case "$detail" in
    dev.azure.com/*) detail="${detail#dev.azure.com/}" ;;
  esac
  ORG="${detail%%/*}"
  PROJECT="${detail#*/}"
  if [ -z "$ORG" ] || [ -z "$PROJECT" ] || [ "$ORG" = "$detail" ]; then
    echo "azure-devops: could not parse an <org>/<project> out of the profile's Tracker detail '$line'" >&2
    return 1
  fi
}
_org_project || exit 2

_base_url() { printf 'https://dev.azure.com/%s' "$ORG"; }

# --------------------------------------------------------------------- shared helpers

# Runs `az devops invoke …`, printing stdout on success. On failure, prints
# "azure-devops: <context>: <az's error text>" to stderr and returns 1 — the caller decides the
# exit code (some verbs turn a 404 into `fallback`/`n/a` rather than a hard failure).
_invoke() {
  local context="$1"; shift
  local out
  if out=$(az devops invoke --org "$(_base_url)" -o json "$@" 2>&1); then
    printf '%s' "$out"
    return 0
  fi
  AZ_ERR="$out"
  echo "azure-devops: $context: $out" >&2
  return 1
}

# The HTTP status code out of az's error text, when one is present (`Status code: 404`,
# `(HTTP 404)`, or a bare `404` word) — az's own error wording is not pinned by any spec, so this
# matches the shapes az devops invoke is known to use rather than one exact string. Empty when
# none is found, which every caller treats as "not classifiable, don't guess".
_http_code() {
  printf '%s' "$1" | grep -oE '(HTTP |[Ss]tatus code:? ?)[0-9]{3}' | grep -oE '[0-9]{3}' | head -1
}

# System.State values that count as "not open", across all four built-in process templates.
_is_closed_state() {
  case "$1" in
    Closed|Done|Removed) return 0 ;;
    *) return 1 ;;
  esac
}

_wiql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# The project's process template name — Basic | Agile | Scrum | CMMI | anything else (an
# inherited process reports its own name and is refused by name, per the Spec's edge case).
_process_name() {
  az devops project show --org "$(_base_url)" --project "$PROJECT" \
    --query "capabilities.processTemplate.templateName" -o tsv 2>/dev/null
}

# $1 = process name, $2 = 1 when the caller asked for the bug type. Prints the work-item type on
# stdout; returns 1 (nothing printed) for a process this backend does not map.
_wi_type() {
  local proc="$1" bug="${2:-0}"
  if [ "$bug" = 1 ]; then printf 'Bug'; return 0; fi
  case "$proc" in
    Basic) printf 'Issue' ;;
    Agile) printf 'User Story' ;;
    Scrum) printf 'Product Backlog Item' ;;
    CMMI)  printf 'Requirement' ;;
    *) return 1 ;;
  esac
}

# The type's "first state" — where issue-reopen and (were this backend ever asked) issue-create
# would file a new item, keyed by process rather than by type, matching the Spec's own table.
_first_state() {
  case "$1" in
    Basic) printf 'To Do' ;;
    Agile|Scrum) printf 'New' ;;
    CMMI) printf 'Proposed' ;;
    *) return 1 ;;
  esac
}

case "$VERB" in

  # ------------------------------------------------------------------- read verbs

  auth)
    # No per-user login concept mirrors gh's `auth`; this proves the org/project the profile named
    # is actually reachable and prints the pair the rest of this backend resolves against.
    az devops project show --org "$(_base_url)" --project "$PROJECT" --query name -o tsv >/dev/null 2>&1 \
      || { echo "azure-devops: auth: cannot reach $ORG/$PROJECT" >&2; exit 1; }
    printf '%s/%s\n' "$ORG" "$PROJECT"
    ;;

  repo)
    REPO_NAME=""
    if origin=$(git remote get-url origin 2>/dev/null); then
      case "$origin" in
        *dev.azure.com/*/_git/*)
          REPO_NAME="${origin##*/_git/}"; REPO_NAME="${REPO_NAME%.git}" ;;
        *ssh.dev.azure.com:v3/*)
          REPO_NAME="${origin##*/}"; REPO_NAME="${REPO_NAME%.git}" ;;
      esac
    fi
    [ -n "$REPO_NAME" ] || REPO_NAME="$PROJECT"
    out=$(az repos show --org "$(_base_url)" --project "$PROJECT" --repository "$REPO_NAME" -o json) \
      || { echo "azure-devops: repo: cannot read '$REPO_NAME' in $ORG/$PROJECT" >&2; exit 1; }
    printf '%s' "$out" | jq -c --arg origin "${origin:-}" \
      '{slug: (.project.name + "/" + .name), host: "dev.azure.com",
        defaultBranch: (.defaultBranch // "" | sub("^refs/heads/"; "")),
        originSlug: ($origin | if . == "" then null else . end)}'
    ;;

  issue-view)
    n="${1-}"
    [ -n "$n" ] || { echo "azure-devops: issue-view needs a work-item number" >&2; exit 2; }
    out=$(_invoke "issue-view" --area wit --resource workitems \
      --route-parameters project="$PROJECT" id="$n" --query-parameters '$expand=all' \
      --http-method GET --api-version 7.1) || exit 1
    printf '%s' "$out" | jq -c '
      .fields as $f |
      { number: .id, title: $f."System.Title",
        state: ($f."System.State" | ascii_downcase),
        body: ($f."System.Description" // ""),
        labels: (($f."System.Tags" // "") | if . == "" then [] else split("; ") end),
        url: (._links.html.href // (.url // "")),
        format: ((.multilineFieldsFormat."System.Description") // "html") }'
    ;;

  issue-search)
    Q=""; STATE="open"; LIMIT=""; LABELS=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --query) Q="${2-}"; shift 2 ;;
        --state) STATE="${2-}"; shift 2 ;;
        --label) LABELS+=("${2-}"); shift 2 ;;
        --limit) LIMIT="${2-}"; shift 2 ;;
        *) echo "azure-devops: issue-search: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    WIQL="SELECT [System.Id], [System.Title], [System.State] FROM WorkItems WHERE [System.TeamProject] = '$(_wiql_escape "$PROJECT")'"
    [ -n "$Q" ] && WIQL="$WIQL AND [System.Title] CONTAINS WORDS '$(_wiql_escape "$Q")'"
    for l in "${LABELS[@]:-}"; do
      [ -n "$l" ] && WIQL="$WIQL AND [System.Tags] CONTAINS '$(_wiql_escape "$l")'"
    done
    [ "$STATE" = "all" ] || WIQL="$WIQL AND [System.State] NOT IN ('Closed','Done','Removed')"
    out=$(az boards query --org "$(_base_url)" --project "$PROJECT" --wiql "$WIQL" -o json) \
      || { echo "azure-devops: issue-search: query failed" >&2; exit 1; }
    result=$(printf '%s' "$out" | jq -c '[.[] | {number: .id, title: .fields."System.Title", state: (if (.fields."System.State" | IN("Closed","Done","Removed")) then "closed" else "open" end)}]')
    if [ -n "$LIMIT" ]; then
      printf '%s' "$result" | jq -c --argjson n "$LIMIT" '.[0:$n]'
    else
      printf '%s' "$result"
    fi
    printf '\n'
    ;;

  issue-comments)
    n="${1-}"
    [ -n "$n" ] || { echo "azure-devops: issue-comments needs a work-item number" >&2; exit 2; }
    out=$(_invoke "issue-comments" --area wit --resource comments \
      --route-parameters project="$PROJECT" workItemId="$n" \
      --http-method GET --api-version '7.1-preview.4') || exit 1
    printf '%s' "$out" | jq -c '[.comments[]? // .value[]? | .text]'
    ;;

  label-list)
    out=$(_invoke "label-list" --area wit --resource tags \
      --route-parameters project="$PROJECT" \
      --http-method GET --api-version '7.1-preview.1') || exit 1
    printf '%s' "$out" | jq -r '.value[]?.name // empty'
    ;;

  label-create)
    # Azure DevOps tags need no explicit creation: attaching a tag to any work item that does not
    # yet carry it creates the tag as a side effect (issue-add-labels does exactly that). This verb
    # exists only so the contract's needs-vs-implements check (scripts/tracker/capable.sh, rule 4)
    # sees it covered — it makes no `az` call and always succeeds.
    ;;

  # ------------------------------------------------------------------- write verbs
  #
  # Every one of these builds its JSON-patch document with `jq -n --rawfile`/`--arg` and sends it
  # with `az devops invoke … --media-type application/json-patch+json --in-file <file>` — never
  # az's own work-item create/update sub-commands (AC6), and a description's bytes never pass
  # through argv.

  issue-create)
    TITLE=""; BODY_FILE=""; LBLS=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --title)     TITLE="${2-}"; shift 2 ;;
        --label)     LBLS+=("${2-}"); shift 2 ;;
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        *) echo "azure-devops: issue-create: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$TITLE" ] || { echo "azure-devops: issue-create needs --title" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "azure-devops: issue-create needs a non-empty --body-file" >&2; exit 2; }
    PROC=$(_process_name) || true
    BUG=0
    for l in "${LBLS[@]:-}"; do
      case "$(printf '%s' "$l" | tr '[:upper:]' '[:lower:]')" in bug) BUG=1 ;; esac
    done
    WITYPE=$(_wi_type "$PROC" "$BUG") \
      || { echo "azure-devops: issue-create: '$PROC' is not a process this backend maps to a work-item type (Basic, Agile, Scrum, CMMI only)" >&2; exit 2; }
    TAGS=""
    if [ "${#LBLS[@]}" -gt 0 ]; then
      TAGS=$(printf '%s\n' "${LBLS[@]}" | paste -sd';' - | sed 's/;/; /g')
    fi
    PATCH_FILE=$(mktemp)
    jq -n --arg title "$TITLE" --rawfile body "$BODY_FILE" --arg tags "$TAGS" '
      [ {op:"add", path:"/fields/System.Title", value:$title},
        {op:"add", path:"/fields/System.Description", value:$body},
        {op:"add", path:"/multilineFieldsFormat/System.Description", value:"Markdown"} ]
      + (if $tags == "" then [] else [{op:"add", path:"/fields/System.Tags", value:$tags}] end)
    ' > "$PATCH_FILE"
    out=$(_invoke "issue-create" --area wit --resource workitems \
      --route-parameters project="$PROJECT" "type=\$${WITYPE}" \
      --http-method POST --api-version 7.1 \
      --media-type application/json-patch+json --in-file "$PATCH_FILE") \
      || { rm -f "$PATCH_FILE"; exit 1; }
    rm -f "$PATCH_FILE"
    printf '%s' "$out" | jq -c '{number: .id, url: (._links.html.href // .url)}'
    ;;

  issue-edit-body)
    n="${1-}"; shift || true
    BODY_FILE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        *) echo "azure-devops: issue-edit-body: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$n" ] || { echo "azure-devops: issue-edit-body needs a work-item number" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "azure-devops: issue-edit-body refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    PATCH_FILE=$(mktemp)
    jq -n --rawfile body "$BODY_FILE" '
      [ {op:"add", path:"/fields/System.Description", value:$body},
        {op:"add", path:"/multilineFieldsFormat/System.Description", value:"Markdown"} ]
    ' > "$PATCH_FILE"
    _invoke "issue-edit-body" --area wit --resource workitems \
      --route-parameters project="$PROJECT" id="$n" \
      --http-method PATCH --api-version 7.1 \
      --media-type application/json-patch+json --in-file "$PATCH_FILE" >/dev/null
    rc=$?
    rm -f "$PATCH_FILE"
    exit $rc
    ;;

  issue-add-labels|issue-remove-labels)
    OP="$VERB"
    n="${1-}"; shift || true
    [ -n "$n" ] || { echo "azure-devops: $OP needs a work-item number" >&2; exit 2; }
    [ $# -gt 0 ] || { echo "azure-devops: $OP needs at least one label" >&2; exit 2; }
    cur=$(_invoke "$OP: read current tags" --area wit --resource workitems \
      --route-parameters project="$PROJECT" id="$n" --query-parameters 'fields=System.Tags' \
      --http-method GET --api-version 7.1) || exit 1
    EXISTING=$(printf '%s' "$cur" | jq -r '.fields."System.Tags" // ""')
    NEW_TAGS=$(python3 - "$OP" "$EXISTING" "$@" <<'PY'
import sys
op, existing, *labels = sys.argv[1:]
cur = [t.strip() for t in existing.split(";") if t.strip()]
if op == "issue-add-labels":
    for l in labels:
        if l not in cur:
            cur.append(l)
else:
    remove = set(labels)
    cur = [t for t in cur if t not in remove]
print("; ".join(cur))
PY
    )
    PATCH_FILE=$(mktemp)
    jq -n --arg tags "$NEW_TAGS" '[{op:"add", path:"/fields/System.Tags", value:$tags}]' > "$PATCH_FILE"
    _invoke "$OP" --area wit --resource workitems \
      --route-parameters project="$PROJECT" id="$n" \
      --http-method PATCH --api-version 7.1 \
      --media-type application/json-patch+json --in-file "$PATCH_FILE" >/dev/null
    rc=$?
    rm -f "$PATCH_FILE"
    exit $rc
    ;;

  issue-reopen)
    n="${1-}"; shift || true
    BODY_FILE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        *) echo "azure-devops: issue-reopen: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$n" ] || { echo "azure-devops: issue-reopen needs a work-item number" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "azure-devops: issue-reopen refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    PROC=$(_process_name) || true
    STATE=$(_first_state "$PROC") \
      || { echo "azure-devops: issue-reopen: '$PROC' is not a process this backend maps to a first state" >&2; exit 2; }
    PATCH_FILE=$(mktemp)
    jq -n --arg state "$STATE" '[{op:"add", path:"/fields/System.State", value:$state}]' > "$PATCH_FILE"
    _invoke "issue-reopen: state" --area wit --resource workitems \
      --route-parameters project="$PROJECT" id="$n" \
      --http-method PATCH --api-version 7.1 \
      --media-type application/json-patch+json --in-file "$PATCH_FILE" >/dev/null \
      || { rm -f "$PATCH_FILE"; exit 1; }
    rm -f "$PATCH_FILE"
    COMMENT_FILE=$(mktemp)
    jq -n --rawfile text "$BODY_FILE" '{text: $text}' > "$COMMENT_FILE"
    _invoke "issue-reopen: comment" --area wit --resource comments \
      --route-parameters project="$PROJECT" workItemId="$n" \
      --http-method POST --api-version '7.1-preview.4' \
      --media-type application/json --in-file "$COMMENT_FILE" >/dev/null
    rc=$?
    rm -f "$COMMENT_FILE"
    exit $rc
    ;;

  issue-comment)
    n="${1-}"; shift || true
    BODY_FILE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body-file) BODY_FILE="${2-}"; shift 2 ;;
        *) echo "azure-devops: issue-comment: unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$n" ] || { echo "azure-devops: issue-comment needs a work-item number" >&2; exit 2; }
    [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ] \
      || { echo "azure-devops: issue-comment refuses a missing or empty --body-file. Nothing sent." >&2; exit 2; }
    COMMENT_FILE=$(mktemp)
    jq -n --rawfile text "$BODY_FILE" '{text: $text}' > "$COMMENT_FILE"
    _invoke "issue-comment" --area wit --resource comments \
      --route-parameters project="$PROJECT" workItemId="$n" \
      --http-method POST --api-version '7.1-preview.4' \
      --media-type application/json --in-file "$COMMENT_FILE" >/dev/null
    rc=$?
    rm -f "$COMMENT_FILE"
    exit $rc
    ;;

  # ------------------------------------------------------------------- link verbs

  issue-link-parent|issue-link-blocked-by)
    LVERB="$VERB"
    DRY=0; POS=()
    for a in "$@"; do
      case "$a" in
        --dry-run) DRY=1 ;;
        *) POS+=("$a") ;;
      esac
    done
    A="${POS[0]-}"; B="${POS[1]-}"
    if [ "$LVERB" = issue-link-parent ]; then
      RELTYPE="System.LinkTypes.Hierarchy-Reverse"
      [ -n "$A" ] && [ -n "$B" ] || { echo "azure-devops: issue-link-parent needs <parent> <child>" >&2; exit 2; }
      TARGET_ID="$A"; CHILD_ID="$B"
    else
      RELTYPE="System.LinkTypes.Dependency-Reverse"
      [ -n "$A" ] && [ -n "$B" ] || { echo "azure-devops: issue-link-blocked-by needs <child> <blocker>" >&2; exit 2; }
      TARGET_ID="$B"; CHILD_ID="$A"
    fi
    TARGET_URL="$(_base_url)/_apis/wit/workItems/$TARGET_ID"
    if [ "$DRY" -eq 1 ]; then
      echo "DRY-RUN PATCH wit/workitems/$CHILD_ID add relation $RELTYPE -> $TARGET_URL"
      exit 0
    fi
    existing=$(_invoke "$LVERB: read relations" --area wit --resource workitems \
      --route-parameters project="$PROJECT" id="$CHILD_ID" --query-parameters '$expand=relations' \
      --http-method GET --api-version 7.1) || exit 1
    already=$(printf '%s' "$existing" | jq -r --arg rel "$RELTYPE" --arg url "$TARGET_URL" \
      '[.relations[]? | select(.rel == $rel and .url == $url)] | length')
    if [ "$already" -gt 0 ]; then
      echo "ok"
      exit 0
    fi
    PATCH_FILE=$(mktemp)
    jq -n --arg rel "$RELTYPE" --arg url "$TARGET_URL" \
      '[{op:"add", path:"/relations/-", value:{rel:$rel, url:$url}}]' > "$PATCH_FILE"
    if out=$(az devops invoke --org "$(_base_url)" -o json --area wit --resource workitems \
        --route-parameters project="$PROJECT" id="$CHILD_ID" \
        --http-method PATCH --api-version 7.1 \
        --media-type application/json-patch+json --in-file "$PATCH_FILE" 2>&1 >/dev/null); then
      rm -f "$PATCH_FILE"
      echo "ok"
    else
      rm -f "$PATCH_FILE"
      code=$(_http_code "$out")
      if [ -n "$code" ]; then
        echo "FAILED (HTTP $code: $out)"
      else
        echo "FAILED (no HTTP status in az's answer: $out)"
      fi
      exit 1
    fi
    ;;

  issue-children)
    n="${1-}"
    [ -n "$n" ] || { echo "azure-devops: issue-children needs a parent work-item number" >&2; exit 2; }
    WIQL="SELECT [System.Id] FROM WorkItemLinks WHERE ([Source].[System.Id] = $n) AND ([System.Links.LinkType] = 'System.LinkTypes.Hierarchy-Forward') MODE (MustContain)"
    if out=$(az boards query --org "$(_base_url)" --project "$PROJECT" --wiql "$WIQL" -o json 2>&1); then
      printf '%s' "$out" | jq -c '[.[] | select(.target != null) | .target.id] | unique'
    else
      code=$(_http_code "$out")
      if [ "$code" = "404" ]; then
        echo "fallback"
      else
        echo "azure-devops: issue-children: $out" >&2
        exit 1
      fi
    fi
    ;;

  issue-blocked-by-count)
    n="${1-}"
    [ -n "$n" ] || { echo "azure-devops: issue-blocked-by-count needs a work-item number" >&2; exit 2; }
    if ! out=$(az devops invoke --org "$(_base_url)" -o json --area wit --resource workitems \
        --route-parameters project="$PROJECT" id="$n" --query-parameters '$expand=relations' \
        --http-method GET --api-version 7.1 2>&1); then
      code=$(_http_code "$out")
      if [ "$code" = "404" ]; then
        echo "n/a"
        exit 0
      fi
      echo "azure-devops: issue-blocked-by-count: $out" >&2
      exit 1
    fi
    ids=$(printf '%s' "$out" | jq -r '.relations[]? | select(.rel == "System.LinkTypes.Dependency-Reverse") | .url | split("/") | last')
    count=0
    for id in $ids; do
      st=$(az devops invoke --org "$(_base_url)" -o json --area wit --resource workitems \
        --route-parameters project="$PROJECT" id="$id" --query-parameters 'fields=System.State' \
        --http-method GET --api-version 7.1 2>/dev/null | jq -r '.fields."System.State" // empty')
      [ -n "$st" ] && ! _is_closed_state "$st" && count=$((count + 1))
    done
    printf '%s\n' "$count"
    ;;

  *)
    echo "azure-devops: does not implement '$VERB'" >&2
    exit 3
    ;;
esac
