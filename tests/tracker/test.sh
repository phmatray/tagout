#!/usr/bin/env bash
# Golden test for the tracker contract (#505) — scripts/tracker.sh, scripts/tracker/github.sh and
# the registered `tracker.capable` decision.
#
# WHAT THIS PINS, and why each case is a seam rather than an internal.
#
# Every tracker operation in the kit is a direct `gh` call (111 lines in 18 scripts, 189 in 39 prose
# files), so there was no place a second host's dialect could live and no way to say "create-issue
# works here, merge-pr does not yet". This suite pins the two seams that claim now exists:
#
#   A. `tracker.sh`'s STDOUT and EXIT CODE under a stub `gh` first on $PATH. The stub is what makes
#      the backend's normalisation assertable without a network or a real repository: `gh issue view`
#      answers `"OPEN"` and the verb must answer `"open"`, and no live fixture could pin that
#      without also pinning somebody's real issue text.
#   B. the `tracker.capable` verdict through `scripts/decide.sh tracker.capable`, over hand-written
#      state fixtures. Reached through the DISPATCHER, by id — never by calling capable.sh directly.
#      A direct call would test a path no caller uses and would skip the vocabulary refusal that
#      turns an unregistered verdict word into a red build (the same reasoning
#      tests/merge-freshness/test.sh gives for going through decide.sh).
#
# What it deliberately does NOT assert: the dispatcher's internal lookup order. That the verb is
# validated BEFORE the backend is resolved is observable — a typo is exit 2 on every host instead of
# "not implemented" on some — so it is asserted through that observable difference (case 3a/3b) and
# not by reading the script.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TRACKER="$KIT_ROOT/scripts/tracker.sh"
unset GITLAB_HOST # glab's own variable; gitlab.sh reads it (#801), so the suite pins it empty
DECIDE="$KIT_ROOT/scripts/decide.sh"
FIXTURES="$KIT_ROOT/tests/decisions/fixtures/tracker.capable"

. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"

WORK=$(kit_scratch)

# Telemetry into the scratch dir, never the checkout: a suite must not append to the developer's own
# event log, and a refusal about the log would otherwise fold into a captured verdict string.
KIT_DECISION_LOG="$WORK/decision-events.jsonl"
export KIT_DECISION_LOG

# Every gh call the stub answers is appended here when set — AC2's recorded argv, and AC3's proof
# that a refused verb never reaches the stub at all. Cleared with `: > "$GH_CALL_LOG"` before each
# check that reads it, so one check's calls cannot leak into the next.
GH_CALL_LOG="$WORK/gh-calls.log"
export GH_CALL_LOG
: > "$GH_CALL_LOG"

FAILED=0
note_fail() { echo "FAIL: $1"; FAILED=1; }
ok() { echo "  ok: $1"; }

[ -x "$TRACKER" ] || { echo "FAIL: $TRACKER is missing or not executable"; exit 1; }

# ------------------------------------------------------------------------------------ the gh stub
#
# First on $PATH, so the backend's own `gh` calls land here. It applies `--json` and `--jq` the way
# gh does, because that translation is exactly what github.sh delegates to gh and therefore exactly
# what a stub must not fake away. `auth token --hostname` is answered because _gh-host.sh probes it
# when it resolves a host from origin (#514) — without it the helper's rule 3 would fail here for a
# reason that has nothing to do with the verb under test.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

# Every call this stub answers is also logged, one line per call, when GH_CALL_LOG is set — that
# is how AC2 (recorded argv) and AC3 (an empty log = no call was made) are checked without a fake
# that has to re-derive gh's own flag grammar.
if [ -n "${GH_CALL_LOG:-}" ]; then printf '%s\n' "$*" >> "$GH_CALL_LOG"; fi

fail_http() {
  local code="$1" msg
  case "$code" in
    404) msg="${GH_404_MESSAGE:-Not Found}" ;;
    422) msg="${GH_422_MESSAGE:-Validation Failed}" ;;
    *)   msg="Server Error" ;;
  esac
  printf '{"message":"%s"}' "$msg"
  echo "gh: $msg (HTTP $code)" >&2
  exit 1
}

payload=""

# `gh api …` is dispatched on METHOD + ENDPOINT rather than "$1 $2" — the link verbs (#507) and
# their id lookups all start `api -H …`, so the second token is never the endpoint the way it is
# for "issue view"/"label list" below. Status per endpoint comes from the environment, the way
# wire-edges.sh's own (pre-move) stub already proved this out: GH_SUB_STATUS/GH_DEP_STATUS for the
# two POST endpoints, GH_ISSUE_STATUS for a bare issue GET (the id lookup and the
# issue_dependencies_summary read alike), GH_CHILDREN_STATUS for the sub-issues list, GH_422_MESSAGE
# for a 422's body, GH_BLOCKED_BY to populate issue_dependencies_summary.blocked_by (unset = the
# field is absent, the degraded-host shape issue-blocked-by-count reads as "n/a").
method=GET; endpoint=""
if [ "${1-}" = api ]; then
  prev=""
  for a in "$@"; do
    case "$prev" in --method|-X) method="$a" ;; esac
    case "$a" in repos/*) endpoint="$a" ;; esac
    prev="$a"
  done
fi

# Only a `repos/…` endpoint (the link verbs, their id lookups, issue-children,
# issue-blocked-by-count) is dispatched here — a bare `gh api user` (the `auth` verb) has none and
# falls through to the ORIGINAL "$1 $2" dispatch below, unchanged.
if [ -n "$endpoint" ]; then
  case "$method $endpoint" in
    "POST "*/sub_issues)
      s="${GH_SUB_STATUS:-201}"
      case "$s" in 2??) exit 0 ;; *) fail_http "$s" ;; esac ;;
    "POST "*/dependencies/blocked_by)
      s="${GH_DEP_STATUS:-201}"
      case "$s" in 2??) exit 0 ;; *) fail_http "$s" ;; esac ;;
    "GET "*/sub_issues)
      s="${GH_CHILDREN_STATUS:-200}"
      case "$s" in 2??) payload="${GH_CHILDREN_JSON:-[]}" ;; *) fail_http "$s" ;; esac ;;
    # The merge-pr endpoints (#752). /parent before the bare issue GET, which would swallow it.
    # GH_PARENT_STATUS/GH_PARENT_JSON, GH_CHECKRUNS_STATUS and GH_REF_STATUS pick each one's answer.
    "GET repos/"*/issues/[0-9]*/parent)
      s="${GH_PARENT_STATUS:-200}"
      default_parent='{"number":40,"repository_url":"https://api.github.com/repos/acme/widgets"}'
      case "$s" in 2??) payload="${GH_PARENT_JSON:-$default_parent}" ;; *) fail_http "$s" ;; esac ;;
    "GET repos/"*/compare/*)
      payload='{"behind_by":3,"ahead_by":1}' ;;
    "GET repos/"*/commits/*/check-runs)
      s="${GH_CHECKRUNS_STATUS:-200}"
      # Already the --slurp shape (an array of pages): a superseded run of `build`, its rerun, and a
      # run with neither status nor conclusion.
      case "$s" in
        2??) payload='[{"total_count":3,"check_runs":[{"name":"build","id":1,"app":{"id":15368},"html_url":"https://example.invalid/runs/1","status":"completed","conclusion":"failure"},{"name":"build","id":2,"app":{"id":15368},"html_url":"https://example.invalid/runs/2","status":"in_progress","conclusion":null},{"name":"lint","id":3,"app":{"id":15368},"html_url":"https://example.invalid/runs/3","status":null,"conclusion":null}]}]' ;;
        *) fail_http "$s" ;;
      esac ;;
    "DELETE repos/"*/git/refs/heads/*)
      s="${GH_REF_STATUS:-204}"
      case "$s" in 2??) exit 0 ;; *) fail_http "$s" ;; esac ;;
    "GET repos/"*/issues/[0-9]*)
      s="${GH_ISSUE_STATUS:-200}"
      case "$s" in
        2??)
          # A SUCCESSFUL gh call can still write to stderr: its own update notifier, a deprecation
          # notice, a corporate proxy's banner. GH_ISSUE_STDERR reproduces that, which is what makes
          # the "a warning is not a database id" refusal assertable — the backend captures this
          # lookup with `2>&1`, so without a guard the warning becomes part of the id (#507 review).
          [ -n "${GH_ISSUE_STDERR:-}" ] && printf '%s\n' "$GH_ISSUE_STDERR" >&2
          n="${endpoint##*/issues/}"
          if [ -n "${GH_BLOCKED_BY:-}" ]; then
            payload=$(printf '{"id":%s,"issue_dependencies_summary":{"blocked_by":%s}}' "$((1000 + n))" "$GH_BLOCKED_BY")
          else
            payload=$(printf '{"id":%s}' "$((1000 + n))")
          fi ;;
        *) fail_http "$s" ;;
      esac ;;
    *) echo "gh stub: unexpected api call: $method $endpoint" >&2; exit 1 ;;
  esac
else
  case "${1-} ${2-}" in
    "api user")     payload='{"login":"octocat"}' ;;
    "auth token")   echo "gho_stubtoken"; exit 0 ;;
    "repo view")    payload='{"nameWithOwner":"o/r","defaultBranchRef":{"name":"main"}}' ;;
    "issue view")   payload='{"number":7,"title":"A stub issue","state":"OPEN","body":"body text","comments":[{"body":"first comment"},{"body":"second comment"}],"labels":[{"name":"bug"},{"name":"area: skills"}],"url":"https://example.invalid/o/r/issues/7"}' ;;
    # issue-list (#753) asks for createdAt, issue-search never does. GH_LIST_MODE=oldgh rejects
    # the dependency fields the way a gh predating them does, =fail is any other failure.
    "issue list")
      case "$*" in
        *createdAt*)
          case "${GH_LIST_MODE:-}" in
            fail) echo "HTTP 401: Bad credentials" >&2; exit 1 ;;
            oldgh) case "$*" in *blockedBy*) echo 'Unknown JSON field: "blockedBy"' >&2; exit 1 ;; esac
                   payload='[{"number":3,"title":"t3","labels":[{"name":"effort: small"}],"body":"b","comments":[{"body":"c1"}],"createdAt":"2026-11-01T00:00:00Z"}]' ;;
            *) payload='[{"number":3,"title":"t3","labels":[{"name":"effort: small"},{"name":"area: skills"}],"body":"b","comments":[{"body":"c1"},{"body":"c2"}],"createdAt":"2026-11-01T00:00:00Z","blockedBy":{"nodes":[{"number":2,"state":"open"}],"totalCount":2},"blocking":[{"number":4}],"assignees":[{"login":"octocat"}]}]' ;;
          esac ;;
        *) payload='[{"number":12,"title":"A stub closed issue","state":"CLOSED"}]' ;;
      esac ;;
    "issue create") echo "https://example.invalid/o/r/issues/42"; exit 0 ;;
    "issue edit")   exit 0 ;;
    "issue reopen") exit 0 ;;
    "issue comment") exit 0 ;;
    "label list")   payload='[{"name":"bug"},{"name":"area: skills"}]' ;;
    "label create") exit 0 ;;
    # The PR verbs (#751): gh-shaped answers the backend must normalise (headRefName, OPEN, author.login).
    "pr create")    echo "https://example.invalid/o/r/pull/51"; exit 0 ;;
    "pr list")      payload='[{"number":51,"title":"feat: x (#7)","url":"https://example.invalid/o/r/pull/51","state":"OPEN","isDraft":true,"headRefName":"feat/7-x","body":"Closes #7","mergedAt":null}]' ;;
    "pr view")      payload='{"number":51,"title":"feat: x (#7)","url":"https://example.invalid/o/r/pull/51","state":"MERGED","isDraft":false,"body":"Closes #7","headRefName":"feat/7-x","baseRefName":"main","headRefOid":"abc123","author":{"login":"octocat"},"commits":[{"oid":"aaa"},{"oid":"bbb"}],"mergedAt":"2026-11-11T10:00:00Z","mergeCommit":{"oid":"def456"},"mergeStateStatus":"BLOCKED","reviewDecision":"REVIEW_REQUIRED","closingIssuesReferences":[{"number":12},{"number":13}]}'
                    # GH_PR_FORK=<login> makes it a fork PR: its head branch lives in <login>'s repository.
                    if [ -n "${GH_PR_FORK:-}" ]; then
                      payload=$(printf '%s' "$payload" | jq -c --arg o "$GH_PR_FORK" '. + {isCrossRepository: true, headRepositoryOwner: {login: $o}}')
                    else
                      payload=$(printf '%s' "$payload" | jq -c '. + {isCrossRepository: false, headRepositoryOwner: {login: "acme"}}')
                    fi ;;
    "pr edit")      exit 0 ;;
    "pr ready")     exit 0 ;;
    # The merge-pr verbs (#752). GH_CHECKS_MODE=none is gh's "no checks reported", =fail any other
    # failure; GH_GRAPHQL_FAIL fails the reviewThreads query the way a GHES host without
    # --hostname does.
    "pr checks")
      case "${GH_CHECKS_MODE:-}" in
        none) echo "no checks reported on the 'feat/7-x' branch" >&2; exit 1 ;;
        fail) echo "gh: Server Error (HTTP 502)" >&2; exit 1 ;;
      esac
      payload='[{"name":"build","state":"SUCCESS","bucket":"pass"}]' ;;
    "pr merge")     exit 0 ;;
    "pr comment")   exit 0 ;;
    "api graphql")
      case "$*" in
        *addPullRequestReviewThreadReply*|*resolveReviewThread*) exit 0 ;;
        *reviewThreads*)
          if [ -n "${GH_GRAPHQL_FAIL:-}" ]; then
            echo "gh: Could not resolve to a Repository with the name 'acme/widgets'." >&2; exit 1
          fi
          payload='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"T1","isResolved":false,"comments":{"nodes":[{"path":"a.sh","line":3,"body":"fix this"}]}},{"id":"T2","isResolved":true,"comments":{"nodes":[{"path":"b.sh","line":9,"body":"done"}]}},{"id":"T3","isResolved":false,"comments":{"nodes":[{"path":null,"line":null,"body":"overall"}]}}]}}}}}' ;;
        *) echo "gh stub: unsupported graphql call" >&2; exit 1 ;;
      esac ;;
    *)              echo "gh stub: unsupported call: $*" >&2; exit 1 ;;
  esac
fi

# Honour a trailing `--jq <expr>` the way gh does; otherwise hand back the whole object.
jq_expr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jq_expr="${2-}"; shift 2 ;;
    *)    shift ;;
  esac
done

if [ -n "$jq_expr" ]; then
  printf '%s' "$payload" | jq -r "$jq_expr"
else
  printf '%s\n' "$payload"
fi
STUB
chmod +x "$WORK/bin/gh"

# Sanity-check the stub itself: a stub that answers everything proves nothing, so an unsupported
# call must fail rather than silently return an empty success.
if PATH="$WORK/bin:$PATH" gh frobnicate >/dev/null 2>&1; then
  note_fail "the gh stub accepted an unsupported call — every assertion below would be vacuous"
fi

run_tracker() {
  # Runs the dispatcher with the stub first on PATH, from $WORK (never the kit checkout) so the
  # profile lookup is the fixture's, not this repository's.
  local dir="$1"; shift
  OUT=$(cd "$dir" && PATH="$WORK/bin:$PATH" "$TRACKER" "$@" 2>"$WORK/err.log")
  RC=$?
  ERR=$(cat "$WORK/err.log")
}

# A fixture repository carrying a committed profile whose Tracker line names github.
PROFILED="$WORK/profiled"
mkdir -p "$PROFILED/.claude/skills"
printf '%s\n' '# Repo profile' '' '## Tracker' \
  '- **Tracker:** github (github.com) — the lifecycle skills drive GitHub semantics through `gh`.' \
  > "$PROFILED/.claude/skills/repo-profile.md"

# A fixture directory with NO committed profile at all.
BARE="$WORK/bare"
mkdir -p "$BARE"

echo "== A. the dispatcher and the gh backend"

# ------------------------------------------------------------------------------------------- AC1
#
# $PROFILED is outside any git repository (KIT_LIB_TMP is a plain mktemp -d, never nested under
# this checkout), so `git remote get-url origin` finds nothing there — the "no origin" case for
# free, and originSlug must be JSON null, never the string "null" or "" (#637).
run_tracker "$PROFILED" --tracker github repo
if [ "$RC" -ne 0 ]; then
  note_fail "AC1 repo — exited $RC ($ERR)"
elif [ "$OUT" != '{"slug":"o/r","host":"github.com","defaultBranch":"main","originSlug":null}' ]; then
  note_fail "AC1 repo — wrong stdout
      want: {\"slug\":\"o/r\",\"host\":\"github.com\",\"defaultBranch\":\"main\",\"originSlug\":null}
      got:  $OUT"
else
  ok "AC1 repo — normalised {slug, host, defaultBranch, originSlug}, no origin -> null, exit 0"
fi

# ------------------------------------------------------------------------------------------- AC1b/c/d
#
# originSlug is read from the LOCAL `origin` remote, never from the stub `gh repo view` answer
# (which always reports "o/r" regardless) — that is the whole point of the field (#637): it is
# the fact `gh --search` actually uses, which does not follow a rename the way `gh repo view`
# does. Each expected originSlug is a hand-written literal, never re-derived by parsing the same
# URL string the case itself sets (the issue's own "a good test here" testing decision).
ORIGIN_HTTPS="$WORK/origin-https"
mkdir -p "$ORIGIN_HTTPS"
git -C "$ORIGIN_HTTPS" init -q
git -C "$ORIGIN_HTTPS" remote add origin "https://github.com/acme/widgets.git"
run_tracker "$ORIGIN_HTTPS" --tracker github repo
if [ "$RC" -ne 0 ]; then
  note_fail "AC1b repo originSlug (https) — exited $RC ($ERR)"
elif [ "$OUT" != '{"slug":"o/r","host":"github.com","defaultBranch":"main","originSlug":"acme/widgets"}' ]; then
  note_fail "AC1b repo originSlug (https) — wrong stdout
      want: originSlug \"acme/widgets\"
      got:  $OUT"
else
  ok "AC1b repo originSlug — https://github.com/OWNER/REPO.git origin"
fi

ORIGIN_SCP="$WORK/origin-scp"
mkdir -p "$ORIGIN_SCP"
git -C "$ORIGIN_SCP" init -q
git -C "$ORIGIN_SCP" remote add origin "git@github.com:acme/widgets.git"
run_tracker "$ORIGIN_SCP" --tracker github repo
if [ "$RC" -ne 0 ]; then
  note_fail "AC1c repo originSlug (git@) — exited $RC ($ERR)"
elif [ "$OUT" != '{"slug":"o/r","host":"github.com","defaultBranch":"main","originSlug":"acme/widgets"}' ]; then
  note_fail "AC1c repo originSlug (git@) — wrong stdout
      want: originSlug \"acme/widgets\"
      got:  $OUT"
else
  ok "AC1c repo originSlug — git@github.com:OWNER/REPO.git origin"
fi

ORIGIN_SSH="$WORK/origin-ssh"
mkdir -p "$ORIGIN_SSH"
git -C "$ORIGIN_SSH" init -q
git -C "$ORIGIN_SSH" remote add origin "ssh://git@github.com/acme/widgets"
run_tracker "$ORIGIN_SSH" --tracker github repo
if [ "$RC" -ne 0 ]; then
  note_fail "AC1d repo originSlug (ssh://, no .git) — exited $RC ($ERR)"
elif [ "$OUT" != '{"slug":"o/r","host":"github.com","defaultBranch":"main","originSlug":"acme/widgets"}' ]; then
  note_fail "AC1d repo originSlug (ssh://, no .git) — wrong stdout
      want: originSlug \"acme/widgets\"
      got:  $OUT"
else
  ok "AC1d repo originSlug — ssh://git@github.com/OWNER/REPO origin (no .git suffix)"
fi

# ------------------------------------------------------------------------------------- AC1b2/c2/d2
#
# Verification gap (#637 review): skills/_shared/preconditions.md's repoint recipe (the
# prefix/newUrl computation that turns a stale `origin` into the canonical slug) is prose an agent
# runs verbatim — nothing else executes it, so tests/skills/test.sh's keyword-only grep would stay
# green even if the recipe swapped its capture order or dropped the `.git`-suffix restoration. This
# runs that SAME recipe (copied from preconditions.md's fenced block — keep the two in sync) against
# each origin form staged above and asserts the resulting `git remote get-url origin`.
repoint_recipe() {
  # $1: a scratch dir already carrying an `origin` remote; $2: the slug to repoint to.
  local dir="$1" slug="$2" url prefix newUrl
  url=$(git -C "$dir" remote get-url origin)
  prefix=$(printf '%s' "$url" | sed -E 's#(\.git)?/*$##' | sed -E 's#[^:/]+/[^:/]+$##')
  newUrl="$prefix$slug"
  case "$url" in *.git) newUrl="$newUrl.git" ;; esac
  git -C "$dir" remote set-url origin "$newUrl"
  git -C "$dir" remote get-url origin
}

got=$(repoint_recipe "$ORIGIN_HTTPS" "acme/widgets-renamed")
if [ "$got" != "https://github.com/acme/widgets-renamed.git" ]; then
  note_fail "AC1b2 preconditions repoint recipe (https) — want https://github.com/acme/widgets-renamed.git, got $got"
else
  ok "AC1b2 preconditions repoint recipe — https, .git suffix preserved"
fi

got=$(repoint_recipe "$ORIGIN_SCP" "acme/widgets-renamed")
if [ "$got" != "git@github.com:acme/widgets-renamed.git" ]; then
  note_fail "AC1c2 preconditions repoint recipe (git@) — want git@github.com:acme/widgets-renamed.git, got $got"
else
  ok "AC1c2 preconditions repoint recipe — git@, .git suffix preserved"
fi

got=$(repoint_recipe "$ORIGIN_SSH" "acme/widgets-renamed")
if [ "$got" != "ssh://git@github.com/acme/widgets-renamed" ]; then
  note_fail "AC1d2 preconditions repoint recipe (ssh://) — want ssh://git@github.com/acme/widgets-renamed, got $got"
else
  ok "AC1d2 preconditions repoint recipe — ssh://, no .git suffix added"
fi

# ------------------------------------------------------------------------------------------- AC2
#
# `gh issue view` answers `"OPEN"`; the verb's contract is a lower-cased state, labels as bare names
# and an explicit `"format":"markdown"` so a later backend cannot quietly hand back a different
# markup dialect under the same verb.
run_tracker "$PROFILED" --tracker github issue-view 7
if [ "$RC" -ne 0 ]; then
  note_fail "AC2 issue-view — exited $RC ($ERR)"
else
  got=$(printf '%s' "$OUT" | jq -r '[(.number|tostring), .state, .format, (.labels|join("+")), .title] | join("|")' 2>/dev/null) \
    || got="<unparseable: $OUT>"
  want='7|open|markdown|bug+area: skills|A stub issue'
  if [ "$got" != "$want" ]; then
    note_fail "AC2 issue-view — wrong normalisation
      want: $want
      got:  $got"
  else
    ok "AC2 issue-view — state lower-cased, labels as names, format markdown"
  fi
fi

# ------------------------------------------------------------------------------------------- AC3
#
# A verb absent from contract.json is a BAD INVOCATION (2), not a missing implementation (3), and it
# is that on every host — which is only true if the verb is checked before the backend is resolved.
run_tracker "$PROFILED" --tracker github frobnicate
[ "$RC" -eq 2 ] \
  && ok "AC3a unknown verb — exit 2 before any backend runs" \
  || note_fail "AC3a unknown verb — expected exit 2, got $RC ('$OUT')"

# gitlab now has a backend (#508) — a tracker with genuinely no backend file is bitbucket.
run_tracker "$PROFILED" --tracker bitbucket repo
if [ "$RC" -ne 3 ]; then
  note_fail "AC3b missing backend — expected exit 3, got $RC ('$OUT')"
elif ! grep -Fq 'NOT_IMPLEMENTED bitbucket repo' <<<"$OUT"$'\n'"$ERR"; then
  note_fail "AC3b missing backend — exit 3 but no 'NOT_IMPLEMENTED bitbucket repo'
      stdout: $OUT
      stderr: $ERR"
else
  ok "AC3b missing backend — exit 3, NOT_IMPLEMENTED bitbucket repo"
fi

# A verb the contract declares but the RESOLVED backend does not implement is also exit 3, and that
# is a different cause from "no backend file at all" — both must land on 3 rather than one of them
# reading as a bad invocation.
run_tracker "$PROFILED" --tracker github verbs
if [ "$RC" -ne 0 ]; then
  note_fail "verbs — the backend protocol verb exited $RC ($ERR)"
elif ! grep -Fqx 'issue-view' <<<"$OUT"; then
  note_fail "verbs — the backend did not list issue-view: '$OUT'"
else
  ok "verbs — the backend lists what it implements"
fi

run_tracker "$PROFILED" --tracker github auth
[ "$RC" -eq 0 ] && [ "$OUT" = "octocat" ] \
  && ok "auth — prints the login" \
  || note_fail "auth — expected 'octocat' exit 0, got '$OUT' exit $RC ($ERR)"

# --------------------------------------------------------------------- the profile selects the host
#
# No --tracker: the dispatcher reads the profile's Tracker line. With NO committed profile it falls
# back to github, which is today's behaviour — the missing profile is reported by preconditions' own
# profile load, never by this dispatcher.
run_tracker "$PROFILED" repo
[ "$RC" -eq 0 ] \
  && ok "profile — the Tracker line selects the backend with no --tracker" \
  || note_fail "profile — expected exit 0 from the profile's github, got $RC ($ERR)"

run_tracker "$BARE" repo
[ "$RC" -eq 0 ] \
  && ok "no profile — dispatches to github rather than refusing" \
  || note_fail "no profile — expected exit 0 (github default), got $RC ($ERR)"

# --repo reaches the backend as TRACKER_REPO.
run_tracker "$BARE" --repo other/repo repo
[ "$RC" -eq 0 ] \
  && ok "--repo — accepted and forwarded to the backend" \
  || note_fail "--repo — expected exit 0, got $RC ($ERR)"

echo "== A2. the nine filing verbs (#506)"

# ------------------------------------------------------------------------------------------- AC1
#
# A search with --label and no --query is a valid call (Step 3's open-refactor scan) — not
# exercised by number here, but nothing below requires --query either.
run_tracker "$PROFILED" --tracker github issue-search --query "csv export" --state all --limit 10
if [ "$RC" -ne 0 ]; then
  note_fail "AC1 issue-search — exited $RC ($ERR)"
elif [ "$OUT" != '[{"number":12,"title":"A stub closed issue","state":"closed"}]' ]; then
  note_fail "AC1 issue-search — wrong stdout
      want: [{\"number\":12,\"title\":\"A stub closed issue\",\"state\":\"closed\"}]
      got:  $OUT"
else
  ok "AC1 issue-search — state lower-cased over a list, exit 0"
fi

# ------------------------------------------------------------------------------------------- AC2
#
# The recorded argv is the proof the title, both labels and the body file all reached `gh issue
# create` — printed stdout alone could not tell a dropped label from one that was merely
# unasserted.
: > "$GH_CALL_LOG"
BODY_F="$WORK/issue-body.md"
printf 'a body\n' > "$BODY_F"
run_tracker "$PROFILED" --tracker github issue-create --title T --label a --label b --body-file "$BODY_F"
if [ "$RC" -ne 0 ]; then
  note_fail "AC2 issue-create — exited $RC ($ERR)"
elif [ "$OUT" != '{"number":42,"url":"https://example.invalid/o/r/issues/42"}' ]; then
  note_fail "AC2 issue-create — wrong stdout
      want: {\"number\":42,\"url\":\"https://example.invalid/o/r/issues/42\"}
      got:  $OUT"
elif ! grep -Fq -- "issue create --title T --body-file $BODY_F --label a --label b" "$GH_CALL_LOG"; then
  note_fail "AC2 issue-create — gh was not called with the title, both labels and the body file:
      $(cat "$GH_CALL_LOG")"
else
  ok "AC2 issue-create — gh recorded title+labels+body-file, printed {number,url}"
fi

# ------------------------------------------------- -R is an alias of --repo, on both sides (#668)
#
# `guarded-pr-merge.sh` and `base-run-verdict.sh` take the repository as `-R <[host/]owner/repo>`,
# and `merge-pr` reads them a call or two before it reaches a tracker verb — so the shape was
# transferred here and refused: `github: issue-create: unknown option: -R`, twice in the measured
# 18-day window, once on the same day as a `tracker.sh -R` refused by the router. Both positions
# are accepted: the router's, beside `--repo`, and the verb's own argv.
: > "$GH_CALL_LOG"
run_tracker "$BARE" -R other/repo issue-create --title T --body-file "$BODY_F"
if [ "$RC" -ne 0 ]; then
  note_fail "-R before the verb — exited $RC ($ERR)"
elif ! grep -Fq -- "--repo other/repo" "$GH_CALL_LOG"; then
  note_fail "-R before the verb — the slug never reached gh:
      $(cat "$GH_CALL_LOG")"
else
  ok "-R before the verb — an alias of --repo, forwarded to the backend"
fi

: > "$GH_CALL_LOG"
run_tracker "$BARE" issue-create -R other/repo --title T --body-file "$BODY_F"
if [ "$RC" -ne 0 ]; then
  note_fail "-R inside the verb — exited $RC ($ERR)"
elif ! grep -Fq -- "--repo other/repo" "$GH_CALL_LOG"; then
  note_fail "-R inside the verb — the slug never reached gh:
      $(cat "$GH_CALL_LOG")"
else
  ok "-R inside the verb — the field's own shape, accepted and forwarded"
fi

# …and two spellings that DISAGREE are refused, never silently resolved to one of them.
: > "$GH_CALL_LOG"
run_tracker "$BARE" --repo one/repo issue-create -R two/repo --title T --body-file "$BODY_F"
if [ "$RC" -ne 2 ]; then
  note_fail "--repo and -R disagreeing — expected exit 2, got $RC ($ERR)"
elif ! grep -Fq "given twice" <<<"$ERR"; then
  note_fail "--repo and -R disagreeing — the refusal does not say 'given twice': $ERR"
elif [ -s "$GH_CALL_LOG" ]; then
  note_fail "--repo and -R disagreeing — gh was called anyway:
      $(cat "$GH_CALL_LOG")"
else
  ok "--repo and -R disagreeing — refused by name, nothing filed"
fi

# The same slug both ways is not a disagreement, and is not refused.
: > "$GH_CALL_LOG"
run_tracker "$BARE" --repo other/repo issue-create -R other/repo --title T --body-file "$BODY_F"
[ "$RC" -eq 0 ] \
  && ok "--repo and -R agreeing — accepted, not refused on a technicality" \
  || note_fail "--repo and -R agreeing — expected exit 0, got $RC ($ERR)"

# The router's own usage line names -R, so a reader of a refusal sees both spellings.
run_tracker "$BARE" --nope repo
if [ "$RC" -ne 2 ]; then
  note_fail "an unknown router option — expected exit 2, got $RC"
elif ! grep -Fq -- "[--repo|-R <slug>]" <<<"$ERR"; then
  note_fail "the router's usage line does not name -R beside --repo: $ERR"
else
  ok "the router's usage line names -R beside --repo"
fi

# ------------------------------------------------------------------------------------------- AC3
#
# The refusal happens BEFORE any gh call — the empty log is the proof, not just the exit code.
: > "$GH_CALL_LOG"
EMPTY_F="$WORK/empty-body.md"
: > "$EMPTY_F"
run_tracker "$PROFILED" --tracker github issue-edit-body 5 --body-file "$EMPTY_F"
if [ "$RC" -ne 2 ]; then
  note_fail "AC3 issue-edit-body — expected exit 2 on an empty --body-file, got $RC ('$OUT')"
elif [ -s "$GH_CALL_LOG" ]; then
  note_fail "AC3 issue-edit-body — refused, but gh was still called:
      $(cat "$GH_CALL_LOG")"
else
  ok "AC3 issue-edit-body — refuses an empty --body-file, exit 2, no gh call"
fi

# The rest of the nine, one seam each: normalised stdout or (for a pure write) the recorded argv.
run_tracker "$PROFILED" --tracker github issue-comments 7
[ "$RC" -eq 0 ] && [ "$OUT" = '["first comment","second comment"]' ] \
  && ok "issue-comments — a JSON array of comment bodies" \
  || note_fail "issue-comments — expected the two stub comments, got '$OUT' exit $RC ($ERR)"

: > "$GH_CALL_LOG"
run_tracker "$PROFILED" --tracker github issue-add-labels 9 x y
[ "$RC" -eq 0 ] && grep -Fq -- "issue edit 9 --add-label x --add-label y" "$GH_CALL_LOG" \
  && ok "issue-add-labels — both labels reached gh issue edit" \
  || note_fail "issue-add-labels — exit $RC, log: $(cat "$GH_CALL_LOG")"

: > "$GH_CALL_LOG"
run_tracker "$PROFILED" --tracker github issue-remove-labels 9 x
[ "$RC" -eq 0 ] && grep -Fq -- "issue edit 9 --remove-label x" "$GH_CALL_LOG" \
  && ok "issue-remove-labels — the label reached gh issue edit --remove-label" \
  || note_fail "issue-remove-labels — exit $RC, log: $(cat "$GH_CALL_LOG")"

: > "$GH_CALL_LOG"
COMMENT_F="$WORK/comment-body.md"
printf 'still failing\n' > "$COMMENT_F"
run_tracker "$PROFILED" --tracker github issue-reopen 9 --body-file "$COMMENT_F"
[ "$RC" -eq 0 ] && grep -Fq -- "issue reopen 9 --comment still failing" "$GH_CALL_LOG" \
  && ok "issue-reopen — the file's text reached gh issue reopen --comment" \
  || note_fail "issue-reopen — exit $RC, log: $(cat "$GH_CALL_LOG")"

: > "$GH_CALL_LOG"
run_tracker "$PROFILED" --tracker github issue-comment 9 --body-file "$COMMENT_F"
[ "$RC" -eq 0 ] && grep -Fq -- "issue comment 9 --body-file $COMMENT_F" "$GH_CALL_LOG" \
  && ok "issue-comment — the body file reached gh issue comment --body-file" \
  || note_fail "issue-comment — exit $RC, log: $(cat "$GH_CALL_LOG")"

run_tracker "$PROFILED" --tracker github label-list
[ "$RC" -eq 0 ] && [ "$OUT" = $'bug\narea: skills' ] \
  && ok "label-list — one name per line" \
  || note_fail "label-list — expected 'bug\\narea: skills', got '$OUT' exit $RC ($ERR)"

: > "$GH_CALL_LOG"
run_tracker "$PROFILED" --tracker github label-create "area: export" --color c5def5 --description "new sub-area"
[ "$RC" -eq 0 ] && grep -Fq -- 'label create area: export --color c5def5 --description new sub-area' "$GH_CALL_LOG" \
  && ok "label-create — name, color and description reached gh label create" \
  || note_fail "label-create — exit $RC, log: $(cat "$GH_CALL_LOG")"

echo "== A3. the four link verbs (#507)"

# ------------------------------------------------------------------------------------------- AC2
# The three replies AC2 names, over issue-link-blocked-by: a 404 on the POST is fallback (the
# dependencies feature is off, not that either issue is missing — both already resolved by a
# successful GET), a 422 whose message says the edge already exists is ok, and any other 422 is a
# real refusal, FAILED.
: > "$GH_CALL_LOG"
GH_DEP_STATUS=404 run_tracker "$PROFILED" --tracker github --repo o/r issue-link-blocked-by 11 10
[ "$RC" -eq 0 ] && [ "$OUT" = fallback ] \
  && ok "AC2 issue-link-blocked-by — a 404 on the POST is fallback, exit 0" \
  || note_fail "AC2 issue-link-blocked-by 404 — expected 'fallback' exit 0, got '$OUT' exit $RC ($ERR)"

: > "$GH_CALL_LOG"
GH_DEP_STATUS=422 GH_422_MESSAGE="Validation failed: Target issue has already been taken" \
  run_tracker "$PROFILED" --tracker github --repo o/r issue-link-blocked-by 11 10
[ "$RC" -eq 0 ] && [ "$OUT" = "ok (already wired)" ] \
  && ok "AC2 issue-link-blocked-by — an already-exists 422 is ok, exit 0 (re-running converges)" \
  || note_fail "AC2 issue-link-blocked-by already-exists — expected 'ok (already wired)' exit 0, got '$OUT' exit $RC ($ERR)"

: > "$GH_CALL_LOG"
GH_DEP_STATUS=422 GH_422_MESSAGE="Validation Failed: would create a cycle" \
  run_tracker "$PROFILED" --tracker github --repo o/r issue-link-blocked-by 11 10
[ "$RC" -eq 1 ] && [ "$OUT" = "FAILED (HTTP 422: Validation Failed: would create a cycle)" ] \
  && ok "AC2 issue-link-blocked-by — any other 422 is FAILED, exit 1" \
  || note_fail "AC2 issue-link-blocked-by other-422 — expected FAILED exit 1, got '$OUT' exit $RC ($ERR)"

# Both ends resolved by a successful GET before the POST — the id lookups are logged, one per
# issue, and the POST carries the resolved database ids (1000 + the issue number, matching the
# stub — see the wire-edges golden test this mirrors).
: > "$GH_CALL_LOG"
run_tracker "$PROFILED" --tracker github --repo o/r issue-link-parent 10 11
[ "$RC" -eq 0 ] && [ "$OUT" = ok ] \
  && grep -Fq -- 'api -H Accept: application/vnd.github+json repos/o/r/issues/10 --jq .id' "$GH_CALL_LOG" \
  && grep -Fq -- 'api -H Accept: application/vnd.github+json repos/o/r/issues/11 --jq .id' "$GH_CALL_LOG" \
  && grep -Fq -- '--method POST --silent repos/o/r/issues/10/sub_issues -F sub_issue_id=1011' "$GH_CALL_LOG" \
  && ok "AC2 issue-link-parent — both ends resolved by GET, POST carries the database ids, exit 0" \
  || note_fail "AC2 issue-link-parent — exit $RC, out '$OUT', log: $(cat "$GH_CALL_LOG")"

# --dry-run prints the POST it would send and calls gh not at all — not even the id lookups.
: > "$GH_CALL_LOG"
run_tracker "$PROFILED" --tracker github --repo o/r issue-link-parent 10 11 --dry-run
[ "$RC" -eq 0 ] && [ "$OUT" = 'DRY-RUN POST repos/o/r/issues/10/sub_issues -F sub_issue_id=<database id of #11>' ] && [ ! -s "$GH_CALL_LOG" ] \
  && ok "issue-link-parent --dry-run — prints the POST, calls gh not at all" \
  || note_fail "issue-link-parent --dry-run — got '$OUT' exit $RC, log: $(cat "$GH_CALL_LOG")"

# A SUCCESSFUL id lookup that also wrote to stderr must be REFUSED, and must not reach the POST.
# github.sh captures the lookup with `2>&1`, so a warning line lands inside the value; unvalidated,
# that value was appended to TRACKER_ID_CACHE as a multi-line entry (poisoning every later lookup
# for that number) and sent as `-F sub_issue_id=<garbage>` to a MUTATING endpoint. This is the guard
# wire-edges.sh's own id_of() carried before the code moved here, dropped in the move (#507 review).
: > "$GH_CALL_LOG"
GH_ISSUE_STDERR='gh: A new release of gh is available: 2.60.0' \
  run_tracker "$PROFILED" --tracker github --repo o/r issue-link-parent 10 11
if [ "$RC" -eq 0 ]; then
  note_fail "issue-link-parent stderr-on-success — exited 0, so a non-numeric id was accepted (out '$OUT')"
elif grep -q -- '--method POST' "$GH_CALL_LOG"; then
  note_fail "issue-link-parent stderr-on-success — refused, but a POST was still sent: $(cat "$GH_CALL_LOG")"
elif ! grep -q 'not a database id' <<<"$ERR"; then
  note_fail "issue-link-parent stderr-on-success — the refusal does not name the rule: $ERR"
else
  ok "issue-link-parent — a warning on a SUCCESSFUL id lookup is refused, and nothing is POSTed"
fi

# ------------------------------------------------------------------------------------------- AC1
GH_CHILDREN_JSON='[{"number":11},{"number":12}]' run_tracker "$PROFILED" --tracker github --repo o/r issue-children 10
[ "$RC" -eq 0 ] && [ "$OUT" = '[11,12]' ] \
  && ok "issue-children — a JSON array of numbers from a sub-issues reply" \
  || note_fail "issue-children — expected '[11,12]', got '$OUT' exit $RC ($ERR)"

GH_CHILDREN_STATUS=404 run_tracker "$PROFILED" --tracker github --repo o/r issue-children 10
[ "$RC" -eq 0 ] && [ "$OUT" = fallback ] \
  && ok "issue-children — fallback on a 404 (sub-issues feature off)" \
  || note_fail "issue-children 404 — expected 'fallback' exit 0, got '$OUT' exit $RC ($ERR)"

GH_BLOCKED_BY=2 run_tracker "$PROFILED" --tracker github --repo o/r issue-blocked-by-count 9
[ "$RC" -eq 0 ] && [ "$OUT" = 2 ] \
  && ok "issue-blocked-by-count — the open-blocker count" \
  || note_fail "issue-blocked-by-count — expected '2', got '$OUT' exit $RC ($ERR)"

run_tracker "$PROFILED" --tracker github --repo o/r issue-blocked-by-count 9
[ "$RC" -eq 0 ] && [ "$OUT" = n/a ] \
  && ok "issue-blocked-by-count — n/a when issue_dependencies_summary is absent (dependencies feature off)" \
  || note_fail "issue-blocked-by-count missing-field — expected 'n/a', got '$OUT' exit $RC ($ERR)"

# `n/a` means exactly one thing: the dependencies feature is off. A 404 says that; every OTHER
# failure (401, 403, a network error, a rate limit) is a REAL failure and must not be laundered into
# the same word. Step 7's readback exists to be "the proof the edges exist where GitHub reads them",
# and an `n/a` on a bad token reads as a benign degraded host, so an operator moves on instead of
# investigating (#507 review).
GH_ISSUE_STATUS=404 run_tracker "$PROFILED" --tracker github --repo o/r issue-blocked-by-count 9
[ "$RC" -eq 0 ] && [ "$OUT" = n/a ] \
  && ok "issue-blocked-by-count — n/a on a 404 (the dependencies feature is off)" \
  || note_fail "issue-blocked-by-count 404 — expected 'n/a' exit 0, got '$OUT' exit $RC ($ERR)"

GH_ISSUE_STATUS=401 run_tracker "$PROFILED" --tracker github --repo o/r issue-blocked-by-count 9
if [ "$RC" -eq 0 ]; then
  note_fail "issue-blocked-by-count 401 — exited 0 with '$OUT'; a real failure read as a degraded host"
elif [ "$OUT" = n/a ]; then
  note_fail "issue-blocked-by-count 401 — answered 'n/a' for an auth failure"
else
  ok "issue-blocked-by-count — a non-404 failure exits 1 rather than answering n/a"
fi

echo "== A4. the PR verbs (#751)"

# pr_case <label> <want-rc> <want-stdout|-> <want-log-line|EMPTY|-> -- <tracker args…>
# The recorded argv is what proves a flag reached gh; an EMPTY log is the proof a refusal or a
# --dry-run called nothing at all. PR_TRACKER/PR_DIR/PR_LOG let sections E2 and F2 reuse it.
PR_TRACKER=github; PR_DIR="$PROFILED"; PR_LOG="$GH_CALL_LOG"
pr_case() {
  local label="$1" want_rc="$2" want_out="$3" want_log="$4"; shift 5
  : > "$PR_LOG"
  run_tracker "$PR_DIR" --tracker "$PR_TRACKER" "$@"
  if [ "$RC" -ne "$want_rc" ]; then
    note_fail "$label — exited $RC, want $want_rc ($ERR)"
  elif [ "$want_out" != - ] && [ "$OUT" != "$want_out" ]; then
    note_fail "$label — wrong stdout
      want: $want_out
      got:  $OUT"
  elif [ "$want_log" = EMPTY ] && [ -s "$PR_LOG" ]; then
    note_fail "$label — expected no host call, got: $(cat "$PR_LOG")"
  elif [ "$want_log" != - ] && [ "$want_log" != EMPTY ] && ! grep -Fq -- "$want_log" "$PR_LOG"; then
    note_fail "$label — the host did not receive '$want_log'; log: $(cat "$PR_LOG")"
  else
    ok "$label"
  fi
}

# pr_dry_runs <body-file> — --dry-run on the three write verbs prints one DRY-RUN line, calls nothing.
pr_dry_runs() {
  local dry
  for dry in "pr-create --base main --head feat/1-x --title T --body-file $1 --dry-run" \
             "pr-edit-body 51 --body-file $1 --dry-run" "pr-ready 42 --dry-run"; do
    # shellcheck disable=SC2086  # word-split on purpose: each entry is one argv
    pr_case "$PR_TRACKER ${dry%% *} --dry-run — no host call" 0 - EMPTY -- $dry
    if [ "$(printf '%s\n' "$OUT" | grep -c '^DRY-RUN ')" != 1 ] || [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" != 1 ]; then
      note_fail "$PR_TRACKER ${dry%% *} --dry-run — expected exactly one DRY-RUN line, got: $OUT"
    fi
  done
}

# base_verdict <dir> <sha> — base-run-verdict.sh's one-line verdict for a post-merge sha (#807), read
# through the real dispatcher and the stubbed host: mapping, ci.verdict and the verdict mapping together.
base_verdict() {
  (cd "$1" && PATH="$WORK/bin:$PATH" "$KIT_ROOT/skills/merge-pr/scripts/base-run-verdict.sh" "$2" \
    --report-line --timeout 5 --poll-seconds 0 2>"$WORK/base.err") || echo "<exit $?: $(cat "$WORK/base.err")>"
}

PR_BODY="$WORK/pr-body.md"; printf 'Closes #7\n' > "$PR_BODY"
PR_EMPTY="$WORK/pr-empty.md"; : > "$PR_EMPTY"

pr_case "pr-create --draft — gh pr create, {number,url}" 0 \
  '{"number":51,"url":"https://example.invalid/o/r/pull/51"}' \
  "pr create --draft --base main --head feat/1-x --title T --body-file $PR_BODY" -- \
  pr-create --draft --base main --head feat/1-x --title T --body-file "$PR_BODY"
pr_case "pr-list --search — searches the body, normalises state and headBranch" 0 \
  '[{"number":51,"title":"feat: x (#7)","url":"https://example.invalid/o/r/pull/51","state":"open","isDraft":true,"headBranch":"feat/7-x","body":"Closes #7","mergedAt":null}]' \
  "pr list --search 7 in:body --state open --limit 100 --json number,title,url,state,isDraft,headRefName,body,mergedAt" -- \
  pr-list --search 7 --state open --limit 100
pr_case "pr-view — the ten decided keys, plus mergedAt and mergeSha (#752)" 0 \
  '{"number":51,"title":"feat: x (#7)","url":"https://example.invalid/o/r/pull/51","state":"merged","isDraft":false,"body":"Closes #7","headBranch":"feat/7-x","baseBranch":"main","headSha":"abc123","author":"octocat","mergedAt":"2026-11-11T10:00:00Z","mergeSha":"def456"}' \
  "pr view 51 --json number,title,url,state,isDraft,body,headRefName,baseRefName,headRefOid,author,mergedAt,mergeCommit" -- \
  pr-view 51
pr_case "pr-commits — an array of SHAs" 0 '["aaa","bbb"]' "pr view 51 --json commits" -- pr-commits 51
pr_case "pr-ready — exactly gh pr ready <n>" 0 '' "pr ready 42" -- pr-ready 42
if [ "$(cat "$GH_CALL_LOG")" != "pr ready 42" ]; then note_fail "pr-ready — log is not exactly 'pr ready 42': $(cat "$GH_CALL_LOG")"; fi
pr_case "pr-edit-body — gh pr edit --body-file" 0 '' "pr edit 51 --body-file $PR_BODY" -- \
  pr-edit-body 51 --body-file "$PR_BODY"
pr_case "pr-create — refuses an empty --body-file, exit 2, no gh call" 2 - EMPTY -- \
  pr-create --base main --head feat/1-x --title T --body-file "$PR_EMPTY"
pr_case "pr-edit-body — refuses a missing --body-file, exit 2, no gh call" 2 - EMPTY -- \
  pr-edit-body 51 --body-file "$WORK/no-such-file"
pr_dry_runs "$PR_BODY"

echo "== A5. the merge-pr verbs (#752)"

# Every case names the repository, so the recorded argv carries the `--repo <slug>` today's scripts
# send — the argv tests/merge-base-ci and tests/guarded-pr-merge will match once they route here.
R=(--repo acme/widgets)

pr_case "pr-merge-state — behind_by from compare, only unresolved paths, (pr-level) for none" 0 \
  '{"behind_by":3,"mergeStateStatus":"BLOCKED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","unresolved_threads":["a.sh","(pr-level)"]}' \
  "api repos/acme/widgets/compare/main...feat/7-x" -- "${R[@]}" pr-merge-state 7
grep -Fq "pr view 7 --repo acme/widgets --json mergeStateStatus,isDraft,reviewDecision,baseRefName,headRefName" "$GH_CALL_LOG" \
  || note_fail "pr-merge-state — the pr view argv is not today's: $(cat "$GH_CALL_LOG")"
# The threads query paginates: without BOTH the $endCursor variable and the pageInfo selection,
# `--paginate` quietly fetches one page and a 101st unresolved thread reads as resolved.
for frag in 'after:$endCursor' 'pageInfo{ hasNextPage endCursor }'; do
  grep -Fq -- "$frag" "$GH_CALL_LOG" || note_fail "pr-merge-state — the reviewThreads query lacks '$frag': $(cat "$GH_CALL_LOG")"
done
# A fork PR's head branch is not in the base repository: a bare main...feat/7-x 404s there.
export GH_PR_FORK=forker
pr_case "pr-merge-state — a fork PR compares <base>...<owner>:<head>" 0 - \
  "api repos/acme/widgets/compare/main...forker:feat/7-x" -- "${R[@]}" pr-merge-state 7
unset GH_PR_FORK
export GH_GRAPHQL_FAIL=1
pr_case "pr-merge-state — a failed thread read exits 1 and prints nothing" 1 '' - -- "${R[@]}" pr-merge-state 7
pr_case "pr-threads — a failed thread read is exit 1, never []" 1 '' - -- "${R[@]}" pr-threads 7
unset GH_GRAPHQL_FAIL
pr_case "pr-threads — one entry per thread, first comment's path/line/body" 0 \
  '[{"id":"T1","path":"a.sh","line":3,"body":"fix this","isResolved":false},{"id":"T2","path":"b.sh","line":9,"body":"done","isResolved":true},{"id":"T3","path":null,"line":null,"body":"overall","isResolved":false}]' \
  "api graphql --paginate" -- "${R[@]}" pr-threads 7

pr_case "commit-checks — every run on the sha, superseded included, with id and app" 0 \
  '[{"name":"build","state":"failure","bucket":"fail","id":1,"app":15368,"html_url":"https://example.invalid/runs/1"},{"name":"build","state":"in_progress","bucket":"pending","id":2,"app":15368,"html_url":"https://example.invalid/runs/2"},{"name":"lint","state":"UNKNOWN","bucket":"pending","id":3,"app":15368,"html_url":"https://example.invalid/runs/3"}]' \
  - -- "${R[@]}" commit-checks abc123
[ "$(cat "$GH_CALL_LOG")" = "api repos/acme/widgets/commits/abc123/check-runs --paginate --slurp" ] \
  || note_fail "commit-checks — argv is not exactly today's check-runs call: $(cat "$GH_CALL_LOG")"
export GH_CHECKRUNS_STATUS=502
pr_case "commit-checks — a host error is exit 1, never []" 1 '' - -- "${R[@]}" commit-checks abc123
unset GH_CHECKRUNS_STATUS

pr_case "pr-checks — gh pr checks, name/state/bucket" 0 '[{"name":"build","state":"SUCCESS","bucket":"pass"}]' \
  "pr checks 7 --repo acme/widgets --json name,state,bucket" -- "${R[@]}" pr-checks 7
export GH_CHECKS_MODE=none
pr_case "pr-checks — 'no checks reported' is [] and exit 0" 0 '[]' - -- "${R[@]}" pr-checks 7
export GH_CHECKS_MODE=fail
pr_case "pr-checks — any other failure is exit 1" 1 '' - -- "${R[@]}" pr-checks 7
unset GH_CHECKS_MODE

pr_case "pr-thread-resolve — replies, then resolves" 0 '' resolveReviewThread -- \
  "${R[@]}" pr-thread-resolve 7 T1 --body-file "$PR_BODY"
reply_at=$(grep -n addPullRequestReviewThreadReply "$GH_CALL_LOG" | head -1 | cut -d: -f1)
resolve_at=$(grep -n 'resolveReviewThread(' "$GH_CALL_LOG" | head -1 | cut -d: -f1)
if [ -z "$reply_at" ] || [ -z "$resolve_at" ] || [ "$reply_at" -ge "$resolve_at" ]; then
  note_fail "pr-thread-resolve — the reply must be logged before the resolve: $(cat "$GH_CALL_LOG")"
fi

pr_case "pr-merge — exactly gh pr merge <n> --repo <slug> <flags>" 0 '' - -- "${R[@]}" pr-merge 7 --squash --subject s
[ "$(cat "$GH_CALL_LOG")" = "pr merge 7 --repo acme/widgets --squash --subject s" ] \
  || note_fail "pr-merge — argv is not exactly today's: $(cat "$GH_CALL_LOG")"
pr_case "pr-merge — a flag outside the four is exit 2, no gh call" 2 - EMPTY -- "${R[@]}" pr-merge 7 --admin

pr_case "branch-delete — per-segment @uri, ok" 0 ok \
  "api -X DELETE repos/acme/widgets/git/refs/heads/feature/x%231" -- "${R[@]}" branch-delete 'feature/x#1'
export GH_REF_STATUS=422 GH_422_MESSAGE="Reference does not exist"
pr_case "branch-delete — 'Reference does not exist' is gone" 0 gone - -- "${R[@]}" branch-delete feature/x
unset GH_422_MESSAGE
export GH_REF_STATUS=404
pr_case "branch-delete — any other failure is exit 1" 1 '' - -- "${R[@]}" branch-delete feature/x
unset GH_REF_STATUS

pr_case "issue-parent — the parent's number" 0 40 "api -H Accept: application/vnd.github+json repos/acme/widgets/issues/5/parent" -- \
  "${R[@]}" issue-parent 5
export GH_PARENT_STATUS=404 GH_404_MESSAGE="No parent issue found"
pr_case "issue-parent — 'No parent issue found' is none" 0 none - -- "${R[@]}" issue-parent 5
unset GH_404_MESSAGE
pr_case "issue-parent — any other 404 is fallback (#762)" 0 fallback - -- "${R[@]}" issue-parent 5
unset GH_PARENT_STATUS
export GH_PARENT_JSON='{"number":40,"repository_url":"https://api.github.com/repos/acme/other"}'
pr_case "issue-parent — a parent in another repository is exit 1 (#781)" 1 '' - -- "${R[@]}" issue-parent 5
unset GH_PARENT_JSON

pr_case "pr-closing-issues — an array of numbers" 0 '[12,13]' \
  "pr view 7 --repo acme/widgets --json closingIssuesReferences" -- "${R[@]}" pr-closing-issues 7
pr_case "pr-comment — gh pr comment --body-file" 0 '' "pr comment 7 --repo acme/widgets --body-file $PR_BODY" -- \
  "${R[@]}" pr-comment 7 --body-file "$PR_BODY"

for refusal in "pr-thread-resolve 7 T1 --body-file $PR_EMPTY" "pr-thread-resolve 7 T1" \
               "pr-comment 7 --body-file $PR_EMPTY" "pr-comment 7 --body-file $WORK/no-such-file" \
               "pr-merge 7 --squash --body-file $PR_EMPTY"; do
  # shellcheck disable=SC2086  # word-split on purpose: each entry is one argv
  pr_case "${refusal%% *} — refuses a missing or empty --body-file, exit 2, no gh call" 2 - EMPTY -- "${R[@]}" $refusal
done
for dry in "pr-merge 7 --squash --delete-branch --dry-run" "pr-thread-resolve 7 T1 --body-file $PR_BODY --dry-run" \
           "pr-comment 7 --body-file $PR_BODY --dry-run" "branch-delete feature/x --dry-run"; do
  # shellcheck disable=SC2086
  pr_case "${dry%% *} --dry-run — no gh call" 0 - EMPTY -- "${R[@]}" $dry
  if [ "$(printf '%s\n' "$OUT" | grep -c '^DRY-RUN ')" != 1 ] || [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" != 1 ]; then
    note_fail "${dry%% *} --dry-run — expected exactly one DRY-RUN line, got: $OUT"
  fi
done

# merge-pr is on the contract now, so a host whose backend lacks its verbs is missing for THAT
# reason — not because the skill is absent from the contract. Every real backend answers all ten
# since #752, so the report is azure-devops' own with one merge verb struck from `implements`.
run_tracker "$PROFILED" --tracker azure-devops state merge-pr
got=$(printf '%s' "$OUT" | jq -c '.implements -= ["pr-merge"]' \
  | "$DECIDE" tracker.capable --json 2>&1 | jq -r '"\(.verdict)/\(.rule)"' 2>/dev/null) || got="<unparseable>"
[ "$got" = missing/verb-not-implemented ] \
  && ok "state merge-pr, a backend lacking pr-merge — missing/verb-not-implemented" \
  || note_fail "state merge-pr, a backend lacking pr-merge — want missing/verb-not-implemented, got $got"

echo "== A6. the auto-dev verbs (#753)"

# issue-list sends today's survey argv plus createdAt, and normalises gh's shapes to the contract's:
# bare label names, comment bodies, assignee logins, and every edge a {nodes, totalCount} connection
# — a plain array counted by its length, an absent field null, a node's state upper-cased.
PR_TRACKER=github; PR_DIR="$PROFILED"; PR_LOG="$GH_CALL_LOG"
want_list='[{"number":3,"title":"t3","labels":["effort: small","area: skills"],"body":"b","comments":["c1","c2"],"createdAt":"2026-11-01T00:00:00Z","blockedBy":{"nodes":[{"number":2,"state":"OPEN"}],"totalCount":2},"blocking":{"nodes":[{"number":4,"state":null}],"totalCount":1},"subIssues":null,"assignees":["octocat"]}]'
pr_case "issue-list — today's argv plus createdAt, normalised to the contract" 0 "$want_list" \
  "issue list --state open --limit 5 --json number,title,labels,body,comments,createdAt,blockedBy,blocking,subIssues,assignees" -- \
  issue-list --state open --limit 5

# A gh predating the dependency fields: a second call with the base fields, null edges and
# assignees, and survey.sh's old stderr warning, moved here with the fallback.
export GH_LIST_MODE=oldgh
want_old='[{"number":3,"title":"t3","labels":["effort: small"],"body":"b","comments":["c1"],"createdAt":"2026-11-01T00:00:00Z","blockedBy":null,"blocking":null,"subIssues":null,"assignees":null}]'
pr_case "issue-list — an Unknown JSON field gh falls back to the base fields" 0 "$want_old" \
  "issue list --state open --limit 5 --json number,title,labels,body,comments,createdAt" -- issue-list --state open --limit 5
grep -q 'cannot serve the dependency fields' <<<"$ERR" \
  && ok "issue-list — the fallback says so on stderr" \
  || note_fail "issue-list — the fallback did not warn on stderr: '$ERR'"
export GH_LIST_MODE=fail
pr_case "issue-list — any other gh failure exits 1 with empty stdout" 1 '' - -- issue-list --state open --limit 5
grep -q 'HTTP 401' <<<"$ERR" \
  && ok "issue-list — the failure's own text reaches stderr" \
  || note_fail "issue-list — gh's error was swallowed: '$ERR'"
unset GH_LIST_MODE

pr_case "issue-assign — today's gh issue edit --add-assignee @me" 0 ok \
  "issue edit 12 --add-assignee @me" -- issue-assign 12
pr_case "issue-assign --dry-run — no gh call" 0 - EMPTY -- issue-assign 12 --dry-run
if [ "$(printf '%s\n' "$OUT" | grep -c '^DRY-RUN ')" != 1 ] || [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" != 1 ]; then
  note_fail "issue-assign --dry-run — expected exactly one DRY-RUN line, got: $OUT"
fi

# skills.auto-dev is a superset of every skill it drives, so a verb added to one of them later
# cannot leave auto-dev capable on a host that lacks it.
if jq -e '((.skills["create-issue"] + .skills["implement-issue"] + .skills["merge-pr"]) - .skills["auto-dev"] == [])
           and ((.skills["auto-dev"] | length) == (.skills["auto-dev"] | unique | length))' \
     "$KIT_ROOT/scripts/tracker/contract.json" >/dev/null 2>&1; then
  ok "skills.auto-dev contains every verb of create-issue, implement-issue and merge-pr"
else
  note_fail "skills.auto-dev is missing a verb of a skill it drives (or is absent)"
fi

run_tracker "$PROFILED" --tracker github state auto-dev
got=$(printf '%s' "$OUT" | "$DECIDE" tracker.capable --json 2>&1 | jq -r '"\(.verdict)/\(.rule)"' 2>/dev/null) || got="<unparseable>"
[ "$got" = capable/github-reference ] && ok "state auto-dev on github — capable/github-reference" \
  || note_fail "state auto-dev on github — want capable/github-reference, got $got"
# Every real backend answers both verbs since #753, so "missing" is azure-devops' own report with
# one auto-dev verb struck from `implements` — the same synthetic A5 uses for merge-pr.
run_tracker "$PROFILED" --tracker azure-devops state auto-dev
got=$(printf '%s' "$OUT" | jq -c '.implements -= ["issue-list"]' \
  | "$DECIDE" tracker.capable --json 2>&1 | jq -r '"\(.verdict)/\(.rule)"' 2>/dev/null) || got="<unparseable>"
[ "$got" = missing/verb-not-implemented ] && ok "state auto-dev, a backend lacking issue-list — missing/verb-not-implemented" \
  || note_fail "state auto-dev, a backend lacking issue-list — want missing/verb-not-implemented, got $got"

echo "== B. the state report, and the tracker.capable verdict"

# The report itself: five facts, judging none of them. `needs` is null because deliver-issue is not
# on the contract (#753 left it under #750's Out of scope), and that is a different absence from `implements` being null — the
# decision below is what tells them apart, which is only possible if the report keeps them distinct.
run_tracker "$PROFILED" state deliver-issue
if [ "$RC" -ne 0 ]; then
  note_fail "state — exited $RC ($ERR)"
else
  got=$(printf '%s' "$OUT" | jq -r '[.tracker, .skill, (.needs|tostring), (.implements|length|tostring)] | join("|")' 2>/dev/null) \
    || got="<unparseable: $OUT>"
  if [ "$got" != 'github|deliver-issue|null|36' ]; then
    note_fail "state — wrong report
      want: github|deliver-issue|null|36
      got:  $got"
  else
    ok "state — reports {tracker, skill, needs, implements} and judges nothing"
  fi
fi

# The verdict is reached through the DISPATCHER, by id, over hand-written state fixtures. `--json` so
# the RULE is pinned and not only the word: three words cover five causes here, so an assertion on
# the word alone could not tell a mis-ordered precedence from a correct one.
capable() {
  local fixture="$1" want="$2" what="$3"
  local path="$FIXTURES/$fixture" out got rc=0
  if [ ! -r "$path" ]; then
    note_fail "$fixture — fixture missing ($what)"
    return 0
  fi
  out=$("$DECIDE" tracker.capable --json "$path" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    note_fail "$fixture — decide.sh tracker.capable exited $rc ($what):
$(printf '%s\n' "$out" | sed 's/^/      /')"
    return 0
  fi
  got=$(printf '%s' "$out" | jq -r '"\(.verdict)/\(.rule)"' 2>/dev/null) || got="<unparseable: $out>"
  if [ "$got" != "$want" ]; then
    note_fail "$fixture — $what
      want: $want
      got:  $got"
    return 0
  fi
  ok "$fixture — $what"
}

# GitHub is the reference backend and answers capable for EVERY skill, migrated or not: an unmigrated
# skill's direct `gh` calls are correct there, so refusing it would refuse today's working behaviour.
capable github.json capable/github-reference \
  'GitHub answers capable for any skill, because an unmigrated skill is still correct there'

capable bitbucket-no-backend.json unsupported/no-backend \
  'a tracker with no backend at all is unsupported, not merely missing a verb'

capable skill-not-on-contract.json missing/skill-not-on-contract \
  'a skill absent from the contract is missing on a non-GitHub host'

capable verb-not-implemented.json missing/verb-not-implemented \
  'a backend lacking a verb the skill needs is missing'

capable backend-covers-skill.json capable/backend-covers-skill \
  'a backend implementing every verb the skill needs is capable — the rule that makes migration pay'

# AC5, end to end and on this very repository's shape: the report feeds the decision through a pipe,
# which is exactly the invocation preconditions.md Step 1 carries.
out=$(cd "$PROFILED" && PATH="$WORK/bin:$PATH" "$TRACKER" state merge-pr 2>/dev/null | "$DECIDE" tracker.capable 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  note_fail "end-to-end — the Step 1 pipe exited $rc: $out"
elif [ "$out" != "capable" ]; then
  note_fail "end-to-end — expected 'capable' from the Step 1 pipe, got '$out'"
else
  ok "end-to-end — tracker.sh state | decide.sh tracker.capable answers capable here"
fi

# #751: implement-issue is on the contract — its report names the twelve verbs it needs.
run_tracker "$PROFILED" state implement-issue
got=$(printf '%s' "$OUT" | jq -r '.needs | join(" ")' 2>/dev/null) || got="<unparseable: $OUT>"
want_needs='auth repo issue-view issue-search issue-comments issue-edit-body pr-create pr-list pr-view pr-edit-body pr-ready pr-commits'
if [ "$RC" -ne 0 ] || [ "$got" != "$want_needs" ]; then
  note_fail "state implement-issue — wrong needs (rc $RC)
      want: $want_needs
      got:  $got"
else
  ok "state implement-issue — needs names the twelve verbs (#751)"
fi

# #752: merge-pr is on the contract — the ten inherited verbs plus its ten own.
run_tracker "$PROFILED" state merge-pr
got=$(printf '%s' "$OUT" | jq -r '.needs | join(" ")' 2>/dev/null) || got="<unparseable: $OUT>"
want_needs='auth repo issue-view issue-search issue-edit-body issue-reopen issue-comment pr-list pr-view pr-ready pr-merge-state pr-checks commit-checks pr-threads pr-thread-resolve pr-merge branch-delete issue-parent pr-closing-issues pr-comment'
if [ "$RC" -ne 0 ] || [ "$got" != "$want_needs" ]; then
  note_fail "state merge-pr — wrong needs (rc $RC)
      want: $want_needs
      got:  $got"
else
  ok "state merge-pr — needs names the twenty verbs (#752)"
fi

echo "== C. contract coverage over create-issue's prose (#506)"

# AC4. Every `"<kit>/scripts/tracker.sh" <verb>` spelling under a prose tree must be on BOTH the
# verb table (contract.json's `verbs`) and the skill's own declared needs (`skills.<name>`) — a
# verb missing from either is a bad invocation waiting to happen the day this prose actually runs.
# Reads the same spelling AC5's own grep sweep pins, never a paraphrase of it.
CONTRACT_JSON="$KIT_ROOT/scripts/tracker/contract.json"

collect_verbs() {
  grep -rhoE '"<kit>/scripts/tracker\.sh" [A-Za-z][A-Za-z-]*' "$1" 2>/dev/null \
    | awk '{print $2}' | sort -u
}

# check_coverage <dir> <skill> — prints one "gap: <verb>" line per verb the prose invokes that is
# missing from the verb table or from that skill's declared needs; empty output means covered.
check_coverage() {
  local dir="$1" skill="$2" v
  local table needs
  table=$(jq -r '.verbs | keys[]' "$CONTRACT_JSON")
  needs=$(jq -r --arg s "$skill" '.skills[$s] // [] | .[]' "$CONTRACT_JSON")
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    grep -Fxq "$v" <<<"$table" || echo "gap: $v not on contract.json's verb table"
    grep -Fxq "$v" <<<"$needs" || echo "gap: $v not on skills.$skill"
  done <<EOF
$(collect_verbs "$dir")
EOF
}

FIXTURE_DIR="$WORK/create-issue-fixture"
mkdir -p "$FIXTURE_DIR"
cp "$KIT_ROOT/skills/create-issue/references/steps/07-assemble-and-create.md" "$FIXTURE_DIR/"
printf '\n"<kit>/scripts/tracker.sh" issue-frobnicate 5\n' >> "$FIXTURE_DIR/07-assemble-and-create.md"

fixture_out=$(check_coverage "$FIXTURE_DIR" create-issue)
if [ -z "$fixture_out" ]; then
  note_fail "AC4 fixture — a verb absent from the contract should have failed coverage, nothing was reported"
elif ! grep -Fq 'issue-frobnicate' <<<"$fixture_out"; then
  note_fail "AC4 fixture — coverage output did not name issue-frobnicate:
      $fixture_out"
else
  ok "AC4 fixture — a verb absent from the contract fails coverage, named"
fi

real_out=$(check_coverage "$KIT_ROOT/skills/create-issue" create-issue)
if [ -n "$real_out" ]; then
  note_fail "AC4 real tree — coverage reported gaps:
      $real_out"
else
  ok "AC4 real tree — every tracker.sh verb create-issue's prose invokes is on the verb table and skills.create-issue"
fi

echo "== D. no direct gh call under skills/create-issue (#507)"

# AC3's own grep, run verbatim rather than paraphrased: a fixture that reintroduces a `gh api` line
# must fail it (named, by file), and the real tree — now that Task 3 moved the last prose off direct
# calls — must pass it clean.
GUARD_PATTERN='\bgh (api|issue|label|repo|pr)\b'

FIXTURE_GH="$WORK/create-issue-gh-fixture"
mkdir -p "$FIXTURE_GH"
cp "$KIT_ROOT/skills/create-issue/scripts/wire-edges.sh" "$FIXTURE_GH/"
printf '\n# regression: a direct call reintroduced\nid=$(gh api repos/o/r/issues/9 --jq .id)\n' >> "$FIXTURE_GH/wire-edges.sh"

fixture_gh_out=$(grep -rnE "$GUARD_PATTERN" "$FIXTURE_GH" || true)
if [ -z "$fixture_gh_out" ]; then
  note_fail "AC3 fixture — a reintroduced 'gh api' line should have failed the guard, nothing was reported"
elif ! grep -Fq 'wire-edges.sh' <<<"$fixture_gh_out"; then
  note_fail "AC3 fixture — the guard did not name the file:
      $fixture_gh_out"
else
  ok "AC3 fixture — a direct gh call reintroduced into wire-edges.sh fails the guard, file (and line) named"
fi

real_gh_out=$(grep -rnE "$GUARD_PATTERN" "$KIT_ROOT/skills/create-issue" || true)
if [ -n "$real_gh_out" ]; then
  note_fail "AC3 real tree — a direct gh call survives under skills/create-issue:
      $real_gh_out"
else
  ok "AC3 real tree — no gh api|issue|label|repo|pr spelling anywhere under skills/create-issue"
fi

echo "== C2. contract coverage over implement-issue's prose and open-pr.md (#751)"

# The same check as C, over every file implement-issue's tracker calls are spelled in: its own tree
# and the shared PR-open recipe it runs in Steps 4 and 5. A stray verb in a fixture must be named.
II_TREE="$WORK/implement-issue-tree"
mkdir -p "$II_TREE"
cp -R "$KIT_ROOT/skills/implement-issue" "$II_TREE/"
cp "$KIT_ROOT/skills/_shared/open-pr.md" "$II_TREE/"

FIXTURE_II="$WORK/implement-issue-fixture"
mkdir -p "$FIXTURE_II"
cp "$KIT_ROOT/skills/_shared/open-pr.md" "$FIXTURE_II/"
printf '\n"<kit>/scripts/tracker.sh" pr-frobnicate 5\n' >> "$FIXTURE_II/open-pr.md"
fixture_out=$(check_coverage "$FIXTURE_II" implement-issue)
if ! grep -Fq 'pr-frobnicate' <<<"$fixture_out"; then
  note_fail "C2 fixture — a verb absent from the contract was not named: '$fixture_out'"
else
  ok "C2 fixture — a verb absent from the contract fails coverage, named"
fi
real_out=$(check_coverage "$II_TREE" implement-issue)
if [ -n "$real_out" ]; then
  note_fail "C2 real tree — coverage reported gaps:
      $real_out"
elif [ -z "$(collect_verbs "$II_TREE")" ]; then
  note_fail "C2 real tree — no \"<kit>/scripts/tracker.sh\" verb is spelled anywhere; the check is vacuous"
else
  ok "C2 real tree — every tracker.sh verb implement-issue's prose and open-pr.md invoke is on skills.implement-issue"
fi

echo "== D2. no direct gh issue|label|repo|pr call in implement-issue's scripts (#751)"

# `gh api` stays allowed here: the comment-hosted plan path is GitHub-only by name and keeps it.
GUARD_PATTERN_II='\bgh (issue|label|repo|pr)\b'
FIXTURE_GH_II="$WORK/implement-issue-gh-fixture"
mkdir -p "$FIXTURE_GH_II"
cp "$KIT_ROOT/skills/implement-issue/scripts/guarded-ready.sh" "$FIXTURE_GH_II/"
printf '\ngh pr view 7 --json body\n' >> "$FIXTURE_GH_II/guarded-ready.sh"
fixture_gh_out=$(grep -rnE "$GUARD_PATTERN_II" "$FIXTURE_GH_II" || true)
if ! grep -Fq 'guarded-ready.sh' <<<"$fixture_gh_out"; then
  note_fail "D2 fixture — a reintroduced 'gh pr view' line was not named: '$fixture_gh_out'"
else
  ok "D2 fixture — a direct gh pr call reintroduced into guarded-ready.sh fails the guard, named"
fi
real_gh_out=$(grep -rnE "$GUARD_PATTERN_II" "$KIT_ROOT/skills/implement-issue/scripts" \
  "$KIT_ROOT/skills/_shared/scripts/pr-existence-guard.sh" || true)
if [ -n "$real_gh_out" ]; then
  note_fail "D2 real tree — a direct gh call survives:
      $real_gh_out"
else
  ok "D2 real tree — no gh issue|label|repo|pr under skills/implement-issue/scripts or in pr-existence-guard.sh"
fi

echo "== C3. contract coverage over merge-pr's prose (#752)"

FIXTURE_MP="$WORK/merge-pr-fixture"
mkdir -p "$FIXTURE_MP"
cp "$KIT_ROOT/skills/merge-pr/references/merge-mechanics.md" "$FIXTURE_MP/"
printf '\n"<kit>/scripts/tracker.sh" pr-frobnicate 5\n' >> "$FIXTURE_MP/merge-mechanics.md"
fixture_out=$(check_coverage "$FIXTURE_MP" merge-pr)
if ! grep -Fq 'pr-frobnicate' <<<"$fixture_out"; then
  note_fail "C3 fixture — a verb absent from the contract was not named: '$fixture_out'"
else
  ok "C3 fixture — a verb absent from the contract fails coverage, named"
fi
real_out=$(check_coverage "$KIT_ROOT/skills/merge-pr" merge-pr)
# Every verb the Task 6 prose rewrite moves onto the contract must be spelled at least once, so a
# section that silently fell back to a direct `gh` call goes red here rather than staying covered.
missing_spelled=""
for v in pr-view commit-checks pr-merge-state pr-threads pr-thread-resolve pr-closing-issues \
  issue-parent issue-search issue-reopen issue-comment pr-comment; do
  collect_verbs "$KIT_ROOT/skills/merge-pr" | grep -Fxq "$v" || missing_spelled="$missing_spelled $v"
done
if [ -n "$real_out" ]; then
  note_fail "C3 real tree — coverage reported gaps:
      $real_out"
elif [ -n "$missing_spelled" ]; then
  note_fail "C3 real tree — merge-pr's prose never spells these verbs through \"<kit>/scripts/tracker.sh\":$missing_spelled"
else
  ok "C3 real tree — every tracker.sh verb merge-pr's prose invokes is on skills.merge-pr, and each migrated call site spells one"
fi

echo "== D3. no direct gh tracker call in merge-pr's migrated scripts (#752)"

# Comments may still describe gh (the GitHub case is the reference); only executable lines count.
# GitHub-only paths kept direct by name (approve-runs.sh, base-run-verdict.sh's workflow-runs
# fallback, base-run-followup.sh's `gh run list`) match neither alternative.
GUARD_PATTERN_MP='\bgh (issue|label|repo|pr)\b|gh api [^|]*(check-runs|git/refs|/parent|graphql)'
d3_grep() {
  grep -nE "$GUARD_PATTERN_MP" "$@" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true
}
FIXTURE_GH_MP="$WORK/merge-pr-gh-fixture"
mkdir -p "$FIXTURE_GH_MP"
cp "$KIT_ROOT/skills/merge-pr/scripts/guarded-pr-merge.sh" "$FIXTURE_GH_MP/"
printf '\ngh pr view 7 --json state\n' >> "$FIXTURE_GH_MP/guarded-pr-merge.sh"
fixture_gh_out=$(d3_grep "$FIXTURE_GH_MP/guarded-pr-merge.sh" /dev/null)
if ! grep -Fq 'guarded-pr-merge.sh' <<<"$fixture_gh_out"; then
  note_fail "D3 fixture — a reintroduced 'gh pr view' line was not named: '$fixture_gh_out'"
else
  ok "D3 fixture — a direct gh pr call reintroduced into guarded-pr-merge.sh fails the guard, named"
fi
real_gh_out=$(d3_grep "$KIT_ROOT/skills/merge-pr/scripts/guarded-pr-merge.sh" \
  "$KIT_ROOT/skills/merge-pr/scripts/parent-decision-note.sh" \
  "$KIT_ROOT/skills/merge-pr/scripts/remote-branch-teardown.sh" \
  "$KIT_ROOT/skills/merge-pr/scripts/base-run-verdict.sh" \
  "$KIT_ROOT/skills/auto-dev/scripts/wait-ci.sh")
if [ -n "$real_gh_out" ]; then
  note_fail "D3 real tree — a direct gh call survives:
      $real_gh_out"
else
  ok "D3 real tree — no direct gh tracker call in merge-pr's migrated scripts or wait-ci.sh"
fi

echo "== C4. contract coverage over auto-dev's prose and its commands (#753)"

AD_TREE="$WORK/auto-dev-tree"
mkdir -p "$AD_TREE"
cp -R "$KIT_ROOT/skills/auto-dev" "$AD_TREE/"
cp "$KIT_ROOT"/commands/auto-dev-*.md "$AD_TREE/"
FIXTURE_AD="$WORK/auto-dev-fixture"
mkdir -p "$FIXTURE_AD"
cp "$KIT_ROOT/skills/auto-dev/references/steps/04-supervise.md" "$FIXTURE_AD/"
printf '\n"<kit>/scripts/tracker.sh" issue-frobnicate 5\n' >> "$FIXTURE_AD/04-supervise.md"
fixture_out=$(check_coverage "$FIXTURE_AD" auto-dev)
if ! grep -Fq 'issue-frobnicate' <<<"$fixture_out"; then
  note_fail "C4 fixture — a verb absent from the contract was not named: '$fixture_out'"
else
  ok "C4 fixture — a verb absent from the contract fails coverage, named"
fi
real_out=$(check_coverage "$AD_TREE" auto-dev)
missing_spelled=""
for v in auth state issue-list pr-list pr-view pr-merge-state pr-checks issue-view issue-assign; do
  collect_verbs "$AD_TREE" | grep -Fxq "$v" || missing_spelled="$missing_spelled $v"
done
# `state` is the dispatcher's own report, not a verb on the table — strip it before judging gaps.
real_out=$(grep -v 'gap: state ' <<<"$real_out" || true)
if [ -n "$real_out" ]; then
  note_fail "C4 real tree — coverage reported gaps:
      $real_out"
elif [ -n "$missing_spelled" ]; then
  note_fail "C4 real tree — auto-dev's prose never spells these through \"<kit>/scripts/tracker.sh\":$missing_spelled"
else
  ok "C4 real tree — every tracker.sh verb auto-dev's prose and commands invoke is on skills.auto-dev, and each migrated call site spells one"
fi

echo "== D4. no direct gh tracker call in survey.sh or reconcile.sh (#753)"

GUARD_PATTERN_AD='\bgh (issue|label|repo|pr)\b'
d4_grep() {
  grep -nE "$GUARD_PATTERN_AD" "$@" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true
}
FIXTURE_GH_AD="$WORK/auto-dev-gh-fixture"
mkdir -p "$FIXTURE_GH_AD"
cp "$KIT_ROOT/skills/auto-dev/scripts/reconcile.sh" "$FIXTURE_GH_AD/"
printf '\ngh pr list --state open --json number\n' >> "$FIXTURE_GH_AD/reconcile.sh"
cp "$KIT_ROOT/skills/auto-dev/scripts/survey.sh" "$FIXTURE_GH_AD/"
printf '\nISSUES_JSON=$(gh issue list --state open --json number)\n' >> "$FIXTURE_GH_AD/survey.sh"
fixture_gh_out=$(d4_grep "$FIXTURE_GH_AD/reconcile.sh" "$FIXTURE_GH_AD/survey.sh")
if ! grep -Fq 'reconcile.sh' <<<"$fixture_gh_out" || ! grep -Fq 'survey.sh' <<<"$fixture_gh_out"; then
  note_fail "D4 fixture — a reintroduced 'gh pr list' line was not named: '$fixture_gh_out'"
else
  ok "D4 fixture — a direct gh pr list in reconcile.sh and gh issue list in survey.sh each fail the guard, named"
fi
real_gh_out=$(d4_grep "$KIT_ROOT/skills/auto-dev/scripts/survey.sh" "$KIT_ROOT/skills/auto-dev/scripts/reconcile.sh")
if [ -n "$real_gh_out" ]; then
  note_fail "D4 real tree — a direct gh call survives:
      $real_gh_out"
else
  ok "D4 real tree — no gh issue|label|repo|pr outside comments in survey.sh or reconcile.sh"
fi

echo "== E. the gitlab backend (#508)"

# A fixture repository carrying a committed profile whose Tracker line names gitlab.
GITLAB_PROFILED="$WORK/gitlab-profiled"
mkdir -p "$GITLAB_PROFILED/.claude/skills"
printf '%s\n' '# Repo profile' '' '## Tracker' \
  '- **Tracker:** gitlab (gitlab.com) — the lifecycle skills drive GitLab semantics through `glab`.' \
  > "$GITLAB_PROFILED/.claude/skills/repo-profile.md"

GLAB_CALL_LOG="$WORK/glab-calls.log"
export GLAB_CALL_LOG
: > "$GLAB_CALL_LOG"

# Every `-F`/`-f key=@file` field's BYTES, captured to $GLAB_CAPTURE_DIR/<key>.bin — never
# re-derived from the logged argv (a text join), which is exactly the gap AC2 exists to close: a
# body sent as an ARGUMENT rather than read from the file could still look right in a log line.
GLAB_CAPTURE_DIR="$WORK/glab-captures"
export GLAB_CAPTURE_DIR
mkdir -p "$GLAB_CAPTURE_DIR"

cat > "$WORK/bin/glab" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

if [ -n "${GLAB_CALL_LOG:-}" ]; then printf '%s\n' "$*" >> "$GLAB_CALL_LOG"; fi

if [ -n "${GLAB_CAPTURE_DIR:-}" ]; then
  prev=""
  for a in "$@"; do
    case "$prev" in
      -F|--field|-f|--raw-field)
        case "$a" in
          *=@*)
            key="${a%%=@*}"; path="${a#*=@}"
            [ -r "$path" ] && cp "$path" "$GLAB_CAPTURE_DIR/$key.bin" ;;
        esac ;;
    esac
    prev="$a"
  done
fi

fail_http() {
  # Reproduces glab's own two shapes (commands/api/api.go's processResponse): a JSON body with a
  # `message` field prints "glab: <message> (HTTP <code>)"; anything else prints the bare
  # "glab: HTTP <code>" — both on stderr, exit 1. _link_post and issue-blocked-by-count parse
  # exactly these two shapes.
  local code="$1" msg="${2:-}"
  if [ -n "$msg" ]; then printf 'glab: %s (HTTP %s)\n' "$msg" "$code" >&2
  else printf 'glab: HTTP %s\n' "$code" >&2
  fi
  exit 1
}

if [ "${1-}" = auth ] && [ "${2-}" = status ]; then
  exit "${GLAB_AUTH_STATUS_RC:-0}"
fi

[ "${1-}" = api ] || { echo "glab stub: unsupported call: $*" >&2; exit 1; }
shift

method=GET; endpoint=""; prev=""
for a in "$@"; do
  case "$prev" in --method|-X) method="$a" ;; esac
  case "$a" in projects/*|user) endpoint="$a" ;; esac
  prev="$a"
done

# Normalises the project token to the fixed placeholder `:id` for DISPATCH purposes only (the
# stub's own answers never depend on which project was named) — a `--repo` call reaches this stub
# with a percent-encoded `owner%2Frepo` in place of `:id` (gitlab.sh's own `_id()`), and every
# pattern below is written once, against `:id`, rather than duplicated per possible project token.
endpoint_dispatch="$endpoint"
case "$endpoint_dispatch" in
  projects/*)
    rest="${endpoint_dispatch#projects/}"
    proj="${rest%%[/?]*}"
    tail="${rest#"$proj"}"
    endpoint_dispatch="projects/:id$tail"
    ;;
esac

# A literal `{`/`}` inside a `${VAR:-default}` word is NOT nesting-aware in bash — the FIRST
# unescaped `}` (the JSON object's own closing brace) ends the expansion early, truncating the
# fixture and splicing the rest of the source text onto it. `_pl` (pick-literal) sidesteps the
# whole hazard: the fallback is an ordinary single-quoted function ARGUMENT, never nested inside a
# `${...}` construct, so no brace inside it is ever mistaken for the expansion's own delimiter.
_pl() { local v; eval "v=\"\${$1:-}\""; if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi; }

payload=""
case "$method $endpoint_dispatch" in
  "GET user")
    s="${GLAB_AUTH_STATUS:-200}"
    case "$s" in 2??) payload=$(_pl GLAB_USER_JSON '{"username":"glab_stub_user"}') ;; *) fail_http "$s" ;; esac ;;
  "GET projects/:id")
    payload=$(_pl GLAB_PROJECT_JSON '{"id":501,"path_with_namespace":"acme/widgets","default_branch":"main"}') ;;
  "GET projects/:id/issues"\?*)
    payload=$(_pl GLAB_SEARCH_JSON '[{"iid":12,"title":"A stub closed issue","state":"closed"}]') ;;
  "GET projects/:id/issues/"[0-9]*"/notes"\?*)
    payload=$(_pl GLAB_NOTES_JSON '[{"body":"first note","system":false},{"body":"a system note","system":true},{"body":"second note","system":false}]') ;;
  "GET projects/:id/issues/"[0-9]*"/links"|"GET projects/:id/issues/"[0-9]*"/links"\?*)
    s="${GLAB_LINKS_STATUS:-200}"
    case "$s" in 2??) payload=$(_pl GLAB_LINKS_JSON '[]') ;; *) fail_http "$s" "${GLAB_LINKS_MESSAGE:-}" ;; esac ;;
  "GET projects/:id/issues/"[0-9]*)
    payload=$(_pl GLAB_ISSUE_JSON '{"iid":9,"title":"A stub GitLab issue","state":"opened","description":"body text","labels":["bug","area: skills"],"web_url":"https://gitlab.example.invalid/acme/widgets/-/issues/9"}') ;;
  "GET projects/:id/labels"\?*)
    payload=$(_pl GLAB_LABELS_JSON '[{"name":"bug"},{"name":"area: skills"}]') ;;
  "POST projects/:id/issues")
    payload=$(_pl GLAB_CREATE_JSON '{"iid":42,"web_url":"https://gitlab.example.invalid/acme/widgets/-/issues/42"}') ;;
  "PUT projects/:id/issues/"[0-9]*) : ;;
  "POST projects/:id/issues/"[0-9]*"/notes") : ;;
  "POST projects/:id/issues/"[0-9]*"/links")
    s="${GLAB_LINK_STATUS:-201}"
    case "$s" in 2??) : ;; *) fail_http "$s" "${GLAB_LINK_MESSAGE:-}" ;; esac ;;
  "POST projects/:id/labels") : ;;
  # The merge request endpoints behind the six PR verbs (#751). /commits before the bare GET: the
  # bare pattern's `[0-9]*` would swallow it.
  "POST projects/:id/merge_requests")
    payload=$(_pl GLAB_MR_CREATE_JSON '{"iid":51,"web_url":"https://gitlab.example.invalid/acme/widgets/-/merge_requests/51"}') ;;
  "GET projects/:id/merge_requests"|"GET projects/:id/merge_requests"\?*)
    payload=$(_pl GLAB_MR_LIST_JSON '[{"iid":51,"title":"Draft: x","web_url":"https://gitlab.example.invalid/acme/widgets/-/merge_requests/51","state":"merged","draft":false,"source_branch":"feat/7-x","description":"Closes #7","merged_at":"2026-11-01T00:00:00Z"}]') ;;
  "GET projects/:id/merge_requests/"[0-9]*"/commits"*)
    payload='[{"id":"aaa"},{"id":"bbb"}]' ;;
  # The merge verbs (#752). Every sub-resource before the bare MR patterns below, whose `[0-9]*`
  # would swallow it.
  "GET projects/:id/merge_requests/"[0-9]*"/discussions"*)
    s="${GLAB_DISCUSSIONS_STATUS:-200}"
    case "$s" in 2??) payload=$(_pl GLAB_DISCUSSIONS_JSON '[{"id":"d1","notes":[{"body":"fix this","resolvable":true,"resolved":false,"position":{"new_path":"a.sh","new_line":3}}]},{"id":"d2","notes":[{"body":"done","resolvable":true,"resolved":true,"position":{"new_path":"b.sh","new_line":9}}]},{"id":"d3","notes":[{"body":"overall","resolvable":true,"resolved":false}]},{"id":"d4","notes":[{"body":"changed the title","resolvable":false,"system":true}]}]') ;;
      *) fail_http "$s" ;; esac ;;
  "POST projects/:id/merge_requests/"[0-9]*"/discussions/"*"/notes") : ;;
  "PUT projects/:id/merge_requests/"[0-9]*"/discussions/"*) : ;;
  "PUT projects/:id/merge_requests/"[0-9]*"/merge") : ;;
  "GET projects/:id/merge_requests/"[0-9]*"/closes_issues"*)
    payload='[{"iid":12},{"iid":13}]' ;;
  "POST projects/:id/merge_requests/"[0-9]*"/notes") : ;;
  "GET projects/:id/pipelines/"[0-9]*"/jobs"*)
    payload=$(_pl GLAB_JOBS_JSON '[]') ;;
  "GET projects/:id/repository/commits/"*"/statuses"*)
    s="${GLAB_STATUSES_STATUS:-200}"
    case "$s" in 2??) payload=$(_pl GLAB_STATUSES_JSON '[]') ;; *) fail_http "$s" ;; esac ;;
  "DELETE projects/:id/repository/branches/"*)
    s="${GLAB_BRANCH_DELETE_STATUS:-204}"
    case "$s" in 2??) : ;; *) fail_http "$s" "${GLAB_BRANCH_DELETE_MESSAGE:-}" ;; esac ;;
  "GET projects/:id/merge_requests/"[0-9]*)
    payload=$(_pl GLAB_MR_JSON '{"iid":51,"title":"Draft: x","web_url":"https://gitlab.example.invalid/acme/widgets/-/merge_requests/51","state":"opened","draft":true,"description":"Closes #7","source_branch":"feat/7-x","target_branch":"main","sha":"abc123","author":{"username":"gl_user"}}') ;;
  "PUT projects/:id/merge_requests/"[0-9]*) : ;;
  *) echo "glab stub: unexpected api call: $method $endpoint" >&2; exit 1 ;;
esac

[ -n "$payload" ] && printf '%s\n' "$payload"
exit 0
STUB
chmod +x "$WORK/bin/glab"

if PATH="$WORK/bin:$PATH" glab frobnicate >/dev/null 2>&1; then
  note_fail "the glab stub accepted an unsupported call — every assertion below would be vacuous"
fi

# ------------------------------------------------------------------------------------------- AC1
#
# Every verb create-issue needs (contract.json's skills.create-issue, 17 entries — including
# label-create, which the issue's own table omits but Step 7's taxonomy-growth path needs) is on
# gitlab.sh's `verbs` list — the REAL backend, reached through the REAL dispatcher, never a
# hand-written state fixture, so a forgotten verb here fails this test rather than only showing up
# the day create-issue actually reaches it.
out=$(cd "$GITLAB_PROFILED" && PATH="$WORK/bin:$PATH" "$TRACKER" state create-issue 2>/dev/null | "$DECIDE" tracker.capable 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  note_fail "AC1 create-issue on gitlab — the Step 1 pipe exited $rc: $out"
elif [ "$out" != "capable" ]; then
  note_fail "AC1 create-issue on gitlab — expected 'capable', got '$out'"
else
  ok "AC1 create-issue on gitlab — every verb the skill needs is on gitlab.sh's verbs list"
fi

# merge-pr is on the contract (#752) and gitlab.sh answers its twenty verbs: capable (section E3
# drives each of the ten merge verbs through the stub).
out=$(cd "$GITLAB_PROFILED" && PATH="$WORK/bin:$PATH" "$TRACKER" state merge-pr 2>/dev/null | "$DECIDE" tracker.capable 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  note_fail "AC1 merge-pr on gitlab — the Step 1 pipe exited $rc: $out"
elif [ "$out" != "capable" ]; then
  note_fail "AC1 merge-pr on gitlab — expected 'capable', got '$out'"
else
  ok "AC1 merge-pr on gitlab — every verb the skill needs is on gitlab.sh's verbs list"
fi

# #805: -R names the repository the caller targets. A GitLab-profiled checkout reaching a GitHub
# repository gets the GitHub backend; with no -R, or -R at the checkout's own host, it keeps GitLab.
# scripts/tracker-name.sh is the one probe the five merge-pr scripts share.
NAMER="$(dirname "$TRACKER")/tracker-name.sh"
for tc in "|gitlab" "-R acme/widgets|gitlab" "-R github.com/acme/widgets|github" \
          "-R gitlab.com/acme/widgets|gitlab" "-R grp/sub/proj|gitlab" "-R grp/sub.v2/proj/leaf|gitlab"; do
  args=${tc%|*}; want=${tc#*|}
  got=$(cd "$GITLAB_PROFILED" && "$NAMER" $args 2>/dev/null)
  [ "$got" = "$want" ] \
    && ok "#805 tracker-name.sh ${args:-(no -R)} on a gitlab-profiled checkout — $want" \
    || note_fail "#805 tracker-name.sh ${args:-(no -R)} — want $want, got '$got'"
done

# ------------------------------------------------------------------------------------------- repo
run_tracker "$GITLAB_PROFILED" --tracker gitlab repo
if [ "$RC" -ne 0 ]; then
  note_fail "repo — exited $RC ($ERR)"
elif [ "$OUT" != '{"slug":"acme/widgets","host":"gitlab.com","defaultBranch":"main","originSlug":null}' ]; then
  note_fail "repo — wrong stdout
      want: {\"slug\":\"acme/widgets\",\"host\":\"gitlab.com\",\"defaultBranch\":\"main\",\"originSlug\":null}
      got:  $OUT"
else
  ok "repo — path_with_namespace -> slug, default_branch -> defaultBranch, host gitlab.com"
fi

# originSlug keeps the WHOLE project path of origin — a GitLab subgroup project has more than two
# segments (#799). Every expected value is a hand-written literal, never re-derived from the URL.
gl_origin_case() { # <label> <origin-url|""> <want-json-literal>
  local d="$WORK/gl-origin-$1"
  mkdir -p "$d"
  git -C "$d" init -q
  [ -n "$2" ] && git -C "$d" remote add origin "$2"
  run_tracker "$d" --tracker gitlab repo
  local want="{\"slug\":\"acme/widgets\",\"host\":\"gitlab.com\",\"defaultBranch\":\"main\",\"originSlug\":$3}"
  if [ "$RC" -ne 0 ]; then
    note_fail "gitlab originSlug ($1) — exited $RC ($ERR)"
  elif [ "$OUT" != "$want" ]; then
    note_fail "gitlab originSlug ($1) — wrong stdout
      want: $want
      got:  $OUT"
  else
    ok "gitlab originSlug — $1"
  fi
}
gl_origin_case sub-https "https://gitlab.com/group/sub/proj.git" '"group/sub/proj"'
gl_origin_case sub-scp "git@gitlab.com:group/sub/proj.git" '"group/sub/proj"'
gl_origin_case sub-ssh "ssh://git@gitlab.example.com:2222/group/sub/proj.git" '"group/sub/proj"'
gl_origin_case sub-userinfo "https://user:tok@gitlab.com/group/sub/proj.git/" '"group/sub/proj"'
gl_origin_case two-case "https://gitlab.com/Acme/Widgets.git" '"Acme/Widgets"'
gl_origin_case one-seg "https://gitlab.com/proj.git" 'null'
gl_origin_case no-origin "" 'null'

# ---------------------------------------------------------------- --repo/-R: [host/]owner/repo (#668)
#
# The 2-vs-3-segment split gitlab.sh's own header claims (mirroring _gh-host.sh's rule for github),
# exercised through the one seam that is observable either way: `repo`'s own `host` field for the
# 3-segment (explicit host) case, and the call log's percent-encoded project path for both — a
# `projects/:id` call never reaches the stub once --repo names a slug, so a wrong _id() would show
# up as a literal, unencoded `projects/other/widgets` instead.
: > "$GLAB_CALL_LOG"
run_tracker "$GITLAB_PROFILED" --tracker gitlab --repo other/widgets repo
[ "$RC" -eq 0 ] && grep -Fq -- 'projects/other%2Fwidgets' "$GLAB_CALL_LOG" \
  && ok "--repo (2 segments) — owner/repo percent-encoded into the project path, no :id" \
  || note_fail "--repo (2 segments) — exit $RC, log: $(cat "$GLAB_CALL_LOG")"

: > "$GLAB_CALL_LOG"
run_tracker "$GITLAB_PROFILED" --tracker gitlab --repo gitlab.example.com/other/widgets repo
if [ "$RC" -ne 0 ]; then
  note_fail "--repo (3 segments, explicit host) — exited $RC ($ERR)"
elif [ "$OUT" != '{"slug":"acme/widgets","host":"gitlab.example.com","defaultBranch":"main","originSlug":null}' ]; then
  note_fail "--repo (3 segments, explicit host) — wrong stdout: $OUT"
elif ! grep -Fq -- '--hostname gitlab.example.com' "$GLAB_CALL_LOG"; then
  note_fail "--repo (3 segments, explicit host) — --hostname never reached glab:
      $(cat "$GLAB_CALL_LOG")"
else
  ok "--repo (3 segments) — the leading segment is the host, passed as --hostname and reported back"
fi

: > "$GLAB_CALL_LOG"
run_tracker "$GITLAB_PROFILED" --tracker gitlab --repo group/subgroup/project repo
[ "$RC" -eq 0 ] && grep -Fq -- 'projects/group%2Fsubgroup%2Fproject' "$GLAB_CALL_LOG" \
  && ! grep -Fq -- '--hostname' "$GLAB_CALL_LOG" \
  && ok "--repo (3 segments, dotless first) — a subgroup project path, fully encoded, no host (#795)" \
  || note_fail "--repo (subgroup) — exit $RC, log: $(cat "$GLAB_CALL_LOG")"

# A dotless host on a subgroup slug (#801; env case-insensitive): ambiguous with a subgroup, so it is named by GITLAB_HOST.
: > "$GLAB_CALL_LOG"
GITLAB_HOST=LocalHost run_tracker "$GITLAB_PROFILED" --tracker gitlab --repo localhost/group/sub/proj repo
[ "$RC" -eq 0 ] && grep -Fq -- 'projects/group%2Fsub%2Fproj' "$GLAB_CALL_LOG" \
  && grep -Fq -- '--hostname localhost' "$GLAB_CALL_LOG" \
  && ok "--repo (dotless host named by GITLAB_HOST) — host split off, subgroup path kept (#801)" \
  || note_fail "--repo (dotless host) — exit $RC, log: $(cat "$GLAB_CALL_LOG")"

: > "$GLAB_CALL_LOG"
GITLAB_HOST=localhost run_tracker "$GITLAB_PROFILED" --tracker gitlab --repo group/sub/proj repo
[ "$RC" -eq 0 ] && grep -Fq -- 'projects/group%2Fsub%2Fproj' "$GLAB_CALL_LOG" \
  && ! grep -Fq -- '--hostname' "$GLAB_CALL_LOG" \
  && ok "--repo (subgroup slug, GITLAB_HOST set) — the env host is not applied to a slug that does not lead with it (#801)" \
  || note_fail "--repo (subgroup, GITLAB_HOST) — exit $RC, log: $(cat "$GLAB_CALL_LOG")"

: > "$GLAB_CALL_LOG"
run_tracker "$GITLAB_PROFILED" --tracker gitlab --repo gitlab.example.com/a/b/c/d repo
[ "$RC" -eq 0 ] && grep -Fq -- 'projects/a%2Fb%2Fc%2Fd' "$GLAB_CALL_LOG" \
  && grep -Fq -- '--hostname gitlab.example.com' "$GLAB_CALL_LOG" \
  && ok "--repo (host plus subgroups) — host split off, the rest is the project path (#795)" \
  || note_fail "--repo (host plus subgroups) — exit $RC, log: $(cat "$GLAB_CALL_LOG")"

: > "$GLAB_CALL_LOG"
run_tracker "$GITLAB_PROFILED" --tracker gitlab --repo widgets repo
[ "$RC" -eq 2 ] && [ ! -s "$GLAB_CALL_LOG" ] \
  && ok "--repo (1 segment) — malformed slug refused before any glab call, exit 2" \
  || note_fail "--repo (1 segment) — expected exit 2 with no call, got $RC, log: $(cat "$GLAB_CALL_LOG")"

# ------------------------------------------------------------------------------------------- AC5 (issue-view)
run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-view 9
if [ "$RC" -ne 0 ]; then
  note_fail "issue-view — exited $RC ($ERR)"
else
  got=$(printf '%s' "$OUT" | jq -r '[(.number|tostring), .state, .format, (.labels|join("+")), .body] | join("|")' 2>/dev/null) \
    || got="<unparseable: $OUT>"
  want='9|open|markdown|bug+area: skills|body text'
  if [ "$got" != "$want" ]; then
    note_fail "issue-view — wrong normalisation
      want: $want
      got:  $got"
  else
    ok "issue-view — iid -> number, opened -> open, description -> body, format markdown"
  fi
fi

# ------------------------------------------------------------------------------------------- AC5 (issue-search)
GLAB_SEARCH_JSON='[{"iid":12,"title":"A stub closed issue","state":"closed"},{"iid":13,"title":"A stub open issue","state":"opened"}]' \
  run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-search --query "csv export" --state all --limit 10
if [ "$RC" -ne 0 ]; then
  note_fail "AC5 issue-search — exited $RC ($ERR)"
elif [ "$OUT" != '[{"number":12,"title":"A stub closed issue","state":"closed"},{"number":13,"title":"A stub open issue","state":"open"}]' ]; then
  note_fail "AC5 issue-search — wrong stdout
      want: iid 12 stays closed, iid 13 opened -> open, both iid -> number
      got:  $OUT"
else
  ok "AC5 issue-search — opened -> open, iid -> number"
fi

run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-comments 9
[ "$RC" -eq 0 ] && [ "$OUT" = '["first note","second note"]' ] \
  && ok "issue-comments — a system note is dropped" \
  || note_fail "issue-comments — expected the two non-system notes, got '$OUT' exit $RC ($ERR)"

run_tracker "$GITLAB_PROFILED" --tracker gitlab label-list
[ "$RC" -eq 0 ] && [ "$OUT" = $'bug\narea: skills' ] \
  && ok "label-list — one name per line" \
  || note_fail "label-list — expected 'bug\\narea: skills', got '$OUT' exit $RC ($ERR)"

# ------------------------------------------------------------------------------------------- AC2
#
# The captured bytes prove the body reached glab as a FILE (`-F description=@…`), never as an
# argument — a description containing a literal `=` or a newline would otherwise silently corrupt
# under the wrong flag. The call log proves title and the comma-joined labels reached the same call.
: > "$GLAB_CALL_LOG"
rm -f "$GLAB_CAPTURE_DIR/description.bin"
BODY_F_GL="$WORK/gitlab-issue-body.md"
printf 'a body\n' > "$BODY_F_GL"
run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-create --title T --label a --label b --body-file "$BODY_F_GL"
if [ "$RC" -ne 0 ]; then
  note_fail "AC2 issue-create — exited $RC ($ERR)"
elif [ "$OUT" != '{"number":42,"url":"https://gitlab.example.invalid/acme/widgets/-/issues/42"}' ]; then
  note_fail "AC2 issue-create — wrong stdout
      want: {\"number\":42,\"url\":\"https://gitlab.example.invalid/acme/widgets/-/issues/42\"}
      got:  $OUT"
elif ! grep -Fq -- '-f title=T' "$GLAB_CALL_LOG" || ! grep -Fq -- '-f labels=a,b' "$GLAB_CALL_LOG"; then
  note_fail "AC2 issue-create — title/labels did not reach glab as expected:
      $(cat "$GLAB_CALL_LOG")"
elif ! cmp -s "$BODY_F_GL" "$GLAB_CAPTURE_DIR/description.bin" 2>/dev/null; then
  note_fail "AC2 issue-create — description bytes are not byte-identical to the body file"
else
  ok "AC2 issue-create — title, comma-joined labels and a byte-identical description reached glab"
fi

# ------------------------------------------------------------------------------------------- AC3
: > "$GLAB_CALL_LOG"
EMPTY_F_GL="$WORK/gitlab-empty-body.md"
: > "$EMPTY_F_GL"
run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-edit-body 5 --body-file "$EMPTY_F_GL"
if [ "$RC" -ne 2 ]; then
  note_fail "AC3 issue-edit-body — expected exit 2 on an empty --body-file, got $RC ('$OUT')"
elif [ -s "$GLAB_CALL_LOG" ]; then
  note_fail "AC3 issue-edit-body — refused, but glab was still called:
      $(cat "$GLAB_CALL_LOG")"
else
  ok "AC3 issue-edit-body — refuses an empty --body-file, exit 2, no glab call"
fi

: > "$GLAB_CALL_LOG"
run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-add-labels 9 x y
[ "$RC" -eq 0 ] && grep -Fq -- '-f add_labels=x,y' "$GLAB_CALL_LOG" \
  && ok "issue-add-labels — both labels comma-joined into add_labels" \
  || note_fail "issue-add-labels — exit $RC, log: $(cat "$GLAB_CALL_LOG")"

: > "$GLAB_CALL_LOG"
run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-remove-labels 9 x
[ "$RC" -eq 0 ] && grep -Fq -- '-f remove_labels=x' "$GLAB_CALL_LOG" \
  && ok "issue-remove-labels — the label reached remove_labels" \
  || note_fail "issue-remove-labels — exit $RC, log: $(cat "$GLAB_CALL_LOG")"

: > "$GLAB_CALL_LOG"
rm -f "$GLAB_CAPTURE_DIR/body.bin"
COMMENT_F_GL="$WORK/gitlab-comment-body.md"
printf 'still failing\n' > "$COMMENT_F_GL"
run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-reopen 9 --body-file "$COMMENT_F_GL"
if [ "$RC" -ne 0 ]; then
  note_fail "issue-reopen — exited $RC ($ERR)"
elif ! grep -Fq -- '-f state_event=reopen' "$GLAB_CALL_LOG"; then
  note_fail "issue-reopen — state_event=reopen was not sent: $(cat "$GLAB_CALL_LOG")"
elif ! cmp -s "$COMMENT_F_GL" "$GLAB_CAPTURE_DIR/body.bin" 2>/dev/null; then
  note_fail "issue-reopen — the reopening note's body is not byte-identical to the file"
else
  ok "issue-reopen — state_event=reopen PUT, then a byte-identical note POST"
fi

: > "$GLAB_CALL_LOG"
rm -f "$GLAB_CAPTURE_DIR/body.bin"
run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-comment 9 --body-file "$COMMENT_F_GL"
[ "$RC" -eq 0 ] && cmp -s "$COMMENT_F_GL" "$GLAB_CAPTURE_DIR/body.bin" \
  && ok "issue-comment — the body file reached the note as bytes" \
  || note_fail "issue-comment — exit $RC, log: $(cat "$GLAB_CALL_LOG")"

: > "$GLAB_CALL_LOG"
run_tracker "$GITLAB_PROFILED" --tracker gitlab label-create "area: export" --color c5def5 --description "new sub-area"
[ "$RC" -eq 0 ] && grep -Fq -- '-f name=area: export' "$GLAB_CALL_LOG" \
  && grep -Fq -- '-f color=#c5def5' "$GLAB_CALL_LOG" \
  && ok "label-create — name, #-prefixed color and description reached glab" \
  || note_fail "label-create — exit $RC, log: $(cat "$GLAB_CALL_LOG")"

# ------------------------------------------------------------------------------------------- AC4
#
# GitLab has no issue -> issue sub-issue relation reachable this way — always fallback, never a
# request (unlike github.sh's own issue-link-parent, which resolves database ids first).
: > "$GLAB_CALL_LOG"
run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-link-parent 10 11
[ "$RC" -eq 0 ] && [ "$OUT" = fallback ] && [ ! -s "$GLAB_CALL_LOG" ] \
  && ok "AC4 issue-link-parent — fallback, no request logged" \
  || note_fail "AC4 issue-link-parent — got '$OUT' exit $RC, log: $(cat "$GLAB_CALL_LOG")"

: > "$GLAB_CALL_LOG"
run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-children 10
[ "$RC" -eq 0 ] && [ "$OUT" = fallback ] && [ ! -s "$GLAB_CALL_LOG" ] \
  && ok "AC4 issue-children — fallback, no request logged" \
  || note_fail "AC4 issue-children — got '$OUT' exit $RC, log: $(cat "$GLAB_CALL_LOG")"

GLAB_LINK_STATUS=403 run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-link-blocked-by 11 10
[ "$RC" -eq 0 ] && [ "$OUT" = fallback ] \
  && ok "AC4 issue-link-blocked-by — a 403 on the POST is fallback, exit 0" \
  || note_fail "AC4 issue-link-blocked-by 403 — expected 'fallback' exit 0, got '$OUT' exit $RC ($ERR)"

GLAB_LINK_STATUS=500 GLAB_LINK_MESSAGE="Internal Server Error" \
  run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-link-blocked-by 11 10
[ "$RC" -eq 1 ] && [ "$OUT" = "FAILED (HTTP 500: Internal Server Error)" ] \
  && ok "AC4 issue-link-blocked-by — a 500 is FAILED, exit 1" \
  || note_fail "AC4 issue-link-blocked-by 500 — expected FAILED exit 1, got '$OUT' exit $RC ($ERR)"

GLAB_LINK_STATUS=409 run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-link-blocked-by 11 10
[ "$RC" -eq 0 ] && [ "$OUT" = "ok (already linked)" ] \
  && ok "AC4 issue-link-blocked-by — a 409 (already linked) is ok, exit 0" \
  || note_fail "AC4 issue-link-blocked-by 409 — expected 'ok (already linked)' exit 0, got '$OUT' exit $RC ($ERR)"

: > "$GLAB_CALL_LOG"
run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-link-blocked-by 11 10
[ "$RC" -eq 0 ] && [ "$OUT" = ok ] \
  && grep -Fq -- 'projects/:id/issues/11/links -F target_project_id=501 -F target_issue_iid=10 -f link_type=is_blocked_by' "$GLAB_CALL_LOG" \
  && ok "AC4 issue-link-blocked-by — the resolved numeric project id reached target_project_id" \
  || note_fail "AC4 issue-link-blocked-by — exit $RC, out '$OUT', log: $(cat "$GLAB_CALL_LOG")"

: > "$GLAB_CALL_LOG"
run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-link-blocked-by 11 10 --dry-run
[ "$RC" -eq 0 ] \
  && [ "$OUT" = 'DRY-RUN POST projects/:id/issues/11/links -F target_project_id=<numeric project id> -F target_issue_iid=10 -f link_type=is_blocked_by' ] \
  && [ ! -s "$GLAB_CALL_LOG" ] \
  && ok "issue-link-blocked-by --dry-run — prints the POST, calls glab not at all" \
  || note_fail "issue-link-blocked-by --dry-run — got '$OUT' exit $RC, log: $(cat "$GLAB_CALL_LOG")"

# ------------------------------------------------------------------------------------------- (Task 3) issue-blocked-by-count
GLAB_LINKS_JSON='[{"link_type":"is_blocked_by","state":"opened"},{"link_type":"is_blocked_by","state":"opened"},{"link_type":"relates_to","state":"opened"}]' \
  run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-blocked-by-count 9
[ "$RC" -eq 0 ] && [ "$OUT" = 2 ] \
  && ok "issue-blocked-by-count — two open is_blocked_by links out of three" \
  || note_fail "issue-blocked-by-count — expected '2', got '$OUT' exit $RC ($ERR)"

GLAB_LINKS_STATUS=403 run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-blocked-by-count 9
[ "$RC" -eq 0 ] && [ "$OUT" = n/a ] \
  && ok "issue-blocked-by-count — n/a on a 403 (the dependencies feature is off)" \
  || note_fail "issue-blocked-by-count 403 — expected 'n/a' exit 0, got '$OUT' exit $RC ($ERR)"

GLAB_LINKS_STATUS=500 run_tracker "$GITLAB_PROFILED" --tracker gitlab issue-blocked-by-count 9
if [ "$RC" -eq 0 ]; then
  note_fail "issue-blocked-by-count 500 — exited 0 with '$OUT'; a real failure read as a degraded host"
elif [ "$OUT" = n/a ]; then
  note_fail "issue-blocked-by-count 500 — answered 'n/a' for a real failure"
else
  ok "issue-blocked-by-count — a non-403 failure exits 1 rather than answering n/a"
fi

echo "== E2. the PR verbs on gitlab (#751)"

PR_TRACKER=gitlab; PR_DIR="$GITLAB_PROFILED"; PR_LOG="$GLAB_CALL_LOG"
pr_case "gitlab pr-create --draft — Draft: title prefix, description read from the file" 0 \
  '{"number":51,"url":"https://gitlab.example.invalid/acme/widgets/-/merge_requests/51"}' \
  "-f title=Draft: T -F description=@$PR_BODY" -- \
  pr-create --draft --base main --head feat/1-x --title T --body-file "$PR_BODY"
grep -Fq -- '-f source_branch=feat/1-x -f target_branch=main' "$GLAB_CALL_LOG" \
  || note_fail "gitlab pr-create — branches not sent: $(cat "$GLAB_CALL_LOG")"
pr_case "gitlab pr-list --state open --search Closes — state=opened, search in description" 0 \
  '[{"number":51,"title":"Draft: x","url":"https://gitlab.example.invalid/acme/widgets/-/merge_requests/51","state":"merged","isDraft":false,"headBranch":"feat/7-x","body":"Closes #7","mergedAt":"2026-11-01T00:00:00Z"}]' \
  "merge_requests?state=opened&search=Closes&in=description" -- pr-list --state open --search Closes
# A term under 3 characters is ignored by GitLab's search, so it is matched locally, never sent.
pr_case "gitlab pr-list --search 7 — a short term is matched locally, not sent" 0 - \
  "merge_requests?state=opened" -- pr-list --search 7
grep -q 'search=' "$GLAB_CALL_LOG" && note_fail "gitlab pr-list --search 7 — a short term was sent: $(cat "$GLAB_CALL_LOG")"
[ "$(printf '%s' "$OUT" | jq 'length' 2>/dev/null)" = 1 ] || note_fail "gitlab pr-list --search 7 — the matching MR was dropped: $OUT"
pr_case "gitlab pr-list --search 9 — a non-matching short term returns nothing" 0 '[]' - -- pr-list --search 9
# No --state means open (as gh's default): a merged MR on a reused branch must not read as open.
pr_case "gitlab pr-list --head — defaults to state=opened" 0 - \
  "merge_requests?source_branch=feat%2F7-x&state=opened" -- pr-list --head feat/7-x
pr_case "gitlab pr-view — opened→open, sha→headSha, author.username→author" 0 \
  '{"number":51,"title":"Draft: x","url":"https://gitlab.example.invalid/acme/widgets/-/merge_requests/51","state":"open","isDraft":true,"body":"Closes #7","headBranch":"feat/7-x","baseBranch":"main","headSha":"abc123","author":"gl_user","mergedAt":null,"mergeSha":null}' \
  "api projects/:id/merge_requests/51" -- pr-view 51
pr_case "gitlab pr-commits — an array of SHAs" 0 '["aaa","bbb"]' "merge_requests/51/commits?per_page=100" -- pr-commits 51
pr_case "gitlab pr-edit-body — PUT description=@file" 0 '' "-X PUT projects/:id/merge_requests/51 -F description=@$PR_BODY" -- \
  pr-edit-body 51 --body-file "$PR_BODY"
pr_case "gitlab pr-ready on a draft — PUTs the title back without Draft:" 0 '' \
  "-X PUT projects/:id/merge_requests/51 -f title=x" -- pr-ready 51
export GLAB_MR_JSON='{"iid":52,"title":"x","state":"opened","draft":false}'
pr_case "gitlab pr-ready on a non-draft MR — no PUT" 0 '' - -- pr-ready 52
grep -q -- '-X PUT' "$GLAB_CALL_LOG" && note_fail "gitlab pr-ready — a non-draft MR was PUT: $(cat "$GLAB_CALL_LOG")"
export GLAB_MR_JSON='{"iid":53,"title":"[DRAFT]   y","state":"opened","draft":true}'
pr_case "gitlab pr-ready strips [DRAFT] case-insensitively" 0 '' "-f title=y" -- pr-ready 53
unset GLAB_MR_JSON
pr_case "gitlab pr-create — refuses an empty --body-file, no glab call" 2 - EMPTY -- \
  pr-create --base main --head feat/1-x --title T --body-file "$PR_EMPTY"
pr_case "gitlab pr-edit-body — refuses a missing --body-file, no glab call" 2 - EMPTY -- \
  pr-edit-body 51 --body-file "$WORK/no-such-file"
pr_dry_runs "$PR_BODY"

out=$(cd "$GITLAB_PROFILED" && PATH="$WORK/bin:$PATH" "$TRACKER" state implement-issue 2>/dev/null | "$DECIDE" tracker.capable 2>&1)
if [ "$out" != capable ]; then
  note_fail "gitlab state implement-issue — expected 'capable', got '$out'"
else
  ok "gitlab state implement-issue — capable once the six PR verbs land"
fi
echo "== E3. the merge verbs on gitlab (#752)"

# Same pr_case seam as E2: tracker.sh's stdout and exit code, and GLAB_CALL_LOG. Each case feeds a
# raw GitLab reply through the stub and asserts the normalised stdout, never gitlab.sh's own jq.
PR_TRACKER=gitlab; PR_DIR="$GITLAB_PROFILED"; PR_LOG="$GLAB_CALL_LOG"

# detailed_merge_status → mergeStateStatus. CLEAN only on `mergeable`; anything unmapped, including
# a word GitLab adds tomorrow, is UNKNOWN — merge.step4 waits on it rather than merging.
for pair in mergeable:CLEAN need_rebase:BEHIND conflict:DIRTY broken_status:DIRTY draft_status:DRAFT \
            not_approved:BLOCKED discussions_not_resolved:BLOCKED ci_still_running:UNKNOWN \
            checking:UNKNOWN some_new_word:UNKNOWN; do
  export GLAB_MR_JSON="{\"iid\":7,\"draft\":false,\"detailed_merge_status\":\"${pair%%:*}\",\"diverged_commits_count\":3}"
  pr_case "gitlab pr-merge-state — ${pair%%:*} is ${pair#*:}" 0 - \
    "merge_requests/7?include_diverged_commits_count=true&with_merge_status_recheck=true" -- pr-merge-state 7
  got=$(printf '%s' "$OUT" | jq -r .mergeStateStatus 2>/dev/null)
  [ "$got" = "${pair#*:}" ] || note_fail "gitlab pr-merge-state ${pair%%:*} — want ${pair#*:}, got '$got' ($OUT)"
done
export GLAB_MR_JSON='{"iid":7,"draft":false,"detailed_merge_status":"not_approved","diverged_commits_count":3}'
pr_case "gitlab pr-merge-state — diverged_commits_count is behind_by, unresolved resolvable paths, (pr-level) for none" 0 \
  '{"behind_by":3,"mergeStateStatus":"BLOCKED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","unresolved_threads":["a.sh","(pr-level)"]}' \
  "merge_requests/7/discussions" -- pr-merge-state 7
export GLAB_MR_JSON='{"iid":7,"draft":false,"detailed_merge_status":"requested_changes","diverged_commits_count":0}'
pr_case "gitlab pr-merge-state — requested_changes is BLOCKED / CHANGES_REQUESTED" 0 \
  '{"behind_by":0,"mergeStateStatus":"BLOCKED","isDraft":false,"reviewDecision":"CHANGES_REQUESTED","unresolved_threads":["a.sh","(pr-level)"]}' \
  - -- pr-merge-state 7

# AC3 end to end: an UNKNOWN from the verb, projected the way merge-mechanics.md §4 builds the
# merge.step4 state (the five fields by name, plus the CI gate's failed/pending — empty here), must
# answer wait/unknown through the dispatcher, never merge. Reused by F3.
step4_of() {
  printf '%s' "$1" | jq -c '{behind_by, mergeStateStatus, isDraft, reviewDecision, unresolved_threads}
                           + {failed: [], pending: []}' \
    | "$DECIDE" merge.step4 --json 2>&1 | jq -r '"\(.verdict)/\(.rule)"' 2>/dev/null || echo "<unparseable>"
}
export GLAB_MR_JSON='{"iid":7,"draft":false,"detailed_merge_status":"checking","diverged_commits_count":0}' GLAB_DISCUSSIONS_JSON='[]'
pr_case "gitlab pr-merge-state — checking, no threads, not behind" 0 - - -- pr-merge-state 7
got=$(step4_of "$OUT")
[ "$got" = wait/unknown ] && ok "gitlab checking → merge.step4 wait/unknown, never merge" \
  || note_fail "gitlab checking → merge.step4 — want wait/unknown, got $got ($OUT)"
unset GLAB_DISCUSSIONS_JSON
export GLAB_MR_JSON='{"iid":7,"draft":false,"detailed_merge_status":"requested_changes","diverged_commits_count":0}'
export GLAB_DISCUSSIONS_STATUS=500
pr_case "gitlab pr-merge-state — a failed discussions read exits 1 and prints nothing" 1 '' - -- pr-merge-state 7
pr_case "gitlab pr-threads — a failed discussions read is exit 1, never []" 1 '' - -- pr-threads 7
unset GLAB_DISCUSSIONS_STATUS GLAB_MR_JSON
pr_case "gitlab pr-threads — resolvable discussions only, first note's path/line/body" 0 \
  '[{"id":"d1","path":"a.sh","line":3,"body":"fix this","isResolved":false},{"id":"d2","path":"b.sh","line":9,"body":"done","isResolved":true},{"id":"d3","path":null,"line":null,"body":"overall","isResolved":false}]' \
  - -- pr-threads 7

# Commit statuses → check-run words; `all=true` keeps the retried ones (ci.verdict reduces, not the verb).
export GLAB_STATUSES_JSON='[{"id":1,"name":"build","status":"success","allow_failure":false,"target_url":"https://ci.invalid/1"},{"id":2,"name":"lint","status":"failed","allow_failure":true,"target_url":"https://ci.invalid/2"},{"id":3,"name":"test","status":"failed","allow_failure":false,"target_url":null},{"id":4,"name":"deploy","status":"manual","allow_failure":false},{"id":5,"name":"e2e","status":"running"},{"id":6,"name":"odd","status":"some_new_word"}]'
pr_case "gitlab commit-checks — failed+allow_failure is neutral, unknown is UNKNOWN, app null, html_url from target_url" 0 \
  '[{"name":"build","state":"success","bucket":"pass","id":1,"app":null,"html_url":"https://ci.invalid/1"},{"name":"lint","state":"neutral","bucket":"skipping","id":2,"app":null,"html_url":"https://ci.invalid/2"},{"name":"test","state":"failure","bucket":"fail","id":3,"app":null,"html_url":null},{"name":"deploy","state":"waiting","bucket":"pending","id":4,"app":null,"html_url":null},{"name":"e2e","state":"in_progress","bucket":"pending","id":5,"app":null,"html_url":null},{"name":"odd","state":"UNKNOWN","bucket":"pending","id":6,"app":null,"html_url":null}]' \
  "repository/commits/abc123/statuses?all=true" -- commit-checks abc123
# The post-merge base run (#807): a green and a red run on the merge sha, end to end.
export GLAB_STATUSES_JSON='[{"id":1,"name":"build","status":"success","allow_failure":false,"target_url":"https://ci.invalid/1"}]'
got=$(base_verdict "$GITLAB_PROFILED" abc123)
[ "$got" = "green (clear)" ] && ok "gitlab base run — a passing status on the sha is 'green (clear)'" || note_fail "gitlab green base run — got '$got'"
export GLAB_STATUSES_JSON='[{"id":1,"name":"build","status":"success","allow_failure":false,"target_url":"https://ci.invalid/1"},{"id":2,"name":"test","status":"failed","allow_failure":false,"target_url":"https://ci.invalid/2"}]'
got=$(base_verdict "$GITLAB_PROFILED" abc123)
[ "$got" = "RED (failed)" ] && ok "gitlab base run — a failed status on the sha is 'RED (failed)'" || note_fail "gitlab red base run — got '$got'"
unset GLAB_STATUSES_JSON
export GLAB_STATUSES_STATUS=502
pr_case "gitlab commit-checks — a host error is exit 1, never []" 1 '' - -- commit-checks abc123
unset GLAB_STATUSES_STATUS

pr_case "gitlab pr-checks — no head pipeline is [] and exit 0" 0 '[]' - -- pr-checks 7
grep -q '/jobs' "$GLAB_CALL_LOG" && note_fail "gitlab pr-checks — read jobs with no head pipeline: $(cat "$GLAB_CALL_LOG")"
export GLAB_MR_JSON='{"iid":7,"head_pipeline":{"id":88}}'
export GLAB_JOBS_JSON='[{"name":"build","status":"success"},{"name":"lint","status":"failed","allow_failure":true},{"name":"test","status":"failed","allow_failure":false},{"name":"deploy","status":"manual"},{"name":"old","status":"canceled"},{"name":"e2e","status":"running"}]'
pr_case "gitlab pr-checks — the head pipeline's jobs, bucketed" 0 \
  '[{"name":"build","state":"success","bucket":"pass"},{"name":"lint","state":"failed","bucket":"pass"},{"name":"test","state":"failed","bucket":"fail"},{"name":"deploy","state":"manual","bucket":"skipping"},{"name":"old","state":"canceled","bucket":"cancel"},{"name":"e2e","state":"running","bucket":"pending"}]' \
  "pipelines/88/jobs" -- pr-checks 7
unset GLAB_MR_JSON GLAB_JOBS_JSON

pr_case "gitlab pr-thread-resolve — posts the reply, then resolves" 0 '' \
  "-X PUT projects/:id/merge_requests/7/discussions/d1?resolved=true" -- pr-thread-resolve 7 d1 --body-file "$PR_BODY"
note_at=$(grep -n -- '-X POST projects/:id/merge_requests/7/discussions/d1/notes' "$GLAB_CALL_LOG" | head -1 | cut -d: -f1)
put_at=$(grep -n -- '-X PUT projects/:id/merge_requests/7/discussions/d1' "$GLAB_CALL_LOG" | head -1 | cut -d: -f1)
if [ -z "$note_at" ] || [ -z "$put_at" ] || [ "$note_at" -ge "$put_at" ]; then
  note_fail "gitlab pr-thread-resolve — the note POST must be logged before the PUT: $(cat "$GLAB_CALL_LOG")"
fi

MERGE_BODY="$WORK/merge-body.md"; printf 'the body\n' > "$MERGE_BODY"
rm -f "$GLAB_CAPTURE_DIR/squash_commit_message.bin"
pr_case "gitlab pr-merge --squash --delete-branch --subject — PUT merge with squash and branch removal" 0 '' \
  "-X PUT projects/:id/merge_requests/7/merge" -- \
  pr-merge 7 --squash --delete-branch --subject s --body-file "$MERGE_BODY"
for want in "-F squash=true" "-F should_remove_source_branch=true" "-F squash_commit_message=@"; do
  grep -Fq -- "$want" "$GLAB_CALL_LOG" || note_fail "gitlab pr-merge — '$want' not sent: $(cat "$GLAB_CALL_LOG")"
done
grep -q merge_when_pipeline_succeeds "$GLAB_CALL_LOG" && note_fail "gitlab pr-merge — set merge_when_pipeline_succeeds"
[ "$(cat "$GLAB_CAPTURE_DIR/squash_commit_message.bin" 2>/dev/null)" = "$(printf 's\n\nthe body')" ] \
  || note_fail "gitlab pr-merge — the message is not '<subject>, blank line, body': $(cat "$GLAB_CAPTURE_DIR/squash_commit_message.bin" 2>/dev/null)"
pr_case "gitlab pr-merge — a flag outside the four is exit 2, no glab call" 2 - EMPTY -- pr-merge 7 --admin

pr_case "gitlab branch-delete — DELETE the url-encoded branch, ok" 0 ok \
  "-X DELETE projects/:id/repository/branches/feature%2Fx%231" -- branch-delete 'feature/x#1'
export GLAB_BRANCH_DELETE_STATUS=404 GLAB_BRANCH_DELETE_MESSAGE="404 Branch Not Found"
pr_case "gitlab branch-delete — a 404 Branch Not Found is gone" 0 gone - -- branch-delete feature/x
# A wrong project 404s too — that is not the branch being gone.
export GLAB_BRANCH_DELETE_MESSAGE="404 Project Not Found"
pr_case "gitlab branch-delete — a 404 Project Not Found is exit 1, never gone" 1 '' - -- branch-delete feature/x
export GLAB_BRANCH_DELETE_MESSAGE=""
pr_case "gitlab branch-delete — a bare HTTP 404 is exit 1, never gone" 1 '' - -- branch-delete feature/x
export GLAB_BRANCH_DELETE_STATUS=403 GLAB_BRANCH_DELETE_MESSAGE="403 Forbidden"
pr_case "gitlab branch-delete — any other failure is exit 1" 1 '' - -- branch-delete feature/x
unset GLAB_BRANCH_DELETE_STATUS GLAB_BRANCH_DELETE_MESSAGE

pr_case "gitlab issue-parent — fallback, with no request" 0 fallback EMPTY -- issue-parent 5
pr_case "gitlab pr-closing-issues — closes_issues' iids" 0 '[12,13]' "merge_requests/7/closes_issues" -- pr-closing-issues 7
pr_case "gitlab pr-comment — POST an MR note from the file" 0 '' \
  "-X POST projects/:id/merge_requests/7/notes -F body=@$PR_BODY" -- pr-comment 7 --body-file "$PR_BODY"

for refusal in "pr-thread-resolve 7 d1 --body-file $PR_EMPTY" "pr-thread-resolve 7 d1" \
               "pr-comment 7 --body-file $PR_EMPTY" "pr-comment 7 --body-file $WORK/no-such-file" \
               "pr-merge 7 --squash --body-file $PR_EMPTY"; do
  # shellcheck disable=SC2086  # word-split on purpose: each entry is one argv
  pr_case "gitlab ${refusal%% *} — refuses a missing or empty --body-file, exit 2, no glab call" 2 - EMPTY -- $refusal
done
for dry in "pr-merge 7 --squash --delete-branch --subject s --dry-run" \
           "pr-thread-resolve 7 d1 --body-file $PR_BODY --dry-run" \
           "pr-comment 7 --body-file $PR_BODY --dry-run" "branch-delete feature/x --dry-run"; do
  # shellcheck disable=SC2086
  pr_case "gitlab ${dry%% *} --dry-run — no glab call" 0 - EMPTY -- $dry
  if [ "$(printf '%s\n' "$OUT" | grep -c '^DRY-RUN ')" != 1 ] || [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" != 1 ]; then
    note_fail "gitlab ${dry%% *} --dry-run — expected exactly one DRY-RUN line, got: $OUT"
  fi
done

export GLAB_MR_JSON='{"iid":51,"state":"merged","merged_at":"2026-11-11T10:00:00Z","merge_commit_sha":null,"squash_commit_sha":"sq123"}'
pr_case "gitlab pr-view — mergedAt from merged_at, mergeSha falls back to squash_commit_sha" 0 - - -- pr-view 51
[ "$(printf '%s' "$OUT" | jq -c '[.state, .mergedAt, .mergeSha]' 2>/dev/null)" = '["merged","2026-11-11T10:00:00Z","sq123"]' ] \
  || note_fail "gitlab pr-view — merged fields wrong: $OUT"
unset GLAB_MR_JSON

out=$(cd "$GITLAB_PROFILED" && PATH="$WORK/bin:$PATH" "$TRACKER" state merge-pr 2>/dev/null | "$DECIDE" tracker.capable 2>&1)
if [ "$out" = capable ]; then
  ok "gitlab state merge-pr — capable once the ten merge verbs land"
else
  note_fail "gitlab state merge-pr — expected 'capable', got '$out'"
fi
out=$(cd "$GITLAB_PROFILED" && PATH="$WORK/bin:$PATH" "$TRACKER" state implement-issue 2>/dev/null | "$DECIDE" tracker.capable 2>&1)
[ "$out" = capable ] || note_fail "gitlab state implement-issue — expected 'capable' still, got '$out'"

echo "== E4. the auto-dev verbs on gitlab (#753)"

PR_TRACKER=gitlab; PR_DIR="$GITLAB_PROFILED"; PR_LOG="$GLAB_CALL_LOG"
# Two pages of open issues (glab --paginate prints one array per page), each issue's links read.
export GLAB_SEARCH_JSON='[{"iid":3,"title":"t3","labels":["effort: small"],"description":"b3","created_at":"2026-11-01T00:00:00Z","assignees":[{"username":"ann"}]},{"iid":4,"title":"t4","labels":[],"description":"b4","created_at":"2026-11-02T00:00:00Z","assignees":[]}]
[{"iid":5,"title":"t5","labels":[],"description":"b5","created_at":"2026-11-03T00:00:00Z","assignees":[]},{"iid":6,"title":"t6","labels":[],"description":"b6","created_at":"2026-11-04T00:00:00Z","assignees":[]},{"iid":7,"title":"t7","labels":[],"description":"b7","created_at":"2026-11-05T00:00:00Z","assignees":[]}]'
export GLAB_LINKS_JSON='[{"iid":2,"state":"opened","link_type":"is_blocked_by"},{"iid":9,"state":"closed","link_type":"blocks"},{"iid":8,"state":"opened","link_type":"relates_to"}]'
pr_case "gitlab issue-list — every page, state=opened, links read per issue" 0 - \
  "api --paginate projects/:id/issues?state=opened" -- issue-list --state open --limit 10
got=$(printf '%s' "$OUT" | jq -c '.[0]' 2>/dev/null)
want='{"number":3,"title":"t3","labels":["effort: small"],"body":"b3","comments":null,"createdAt":"2026-11-01T00:00:00Z","blockedBy":{"nodes":[{"number":2,"state":"OPEN"}],"totalCount":1},"blocking":{"nodes":[{"number":9,"state":"CLOSED"}],"totalCount":1},"subIssues":null,"assignees":["ann"]}'
[ "$got" = "$want" ] && ok "gitlab issue-list — iid→number, description→body, usernames, null comments and subIssues, link edges" \
  || note_fail "gitlab issue-list — wrong row
      want: $want
      got:  $got"
[ "$(printf '%s' "$OUT" | jq length)" = 5 ] && ok "gitlab issue-list — both pages joined" \
  || note_fail "gitlab issue-list — pages not joined: $OUT"
[ "$(grep -c '/links' "$GLAB_CALL_LOG")" = 5 ] && ok "gitlab issue-list — one links read per issue" \
  || note_fail "gitlab issue-list — links reads: $(grep -c '/links' "$GLAB_CALL_LOG")"
pr_case "gitlab issue-list --limit 3 — three of five" 0 - - -- issue-list --state open --limit 3
[ "$(printf '%s' "$OUT" | jq -c 'map(.number)')" = '[3,4,5]' ] && ok "gitlab issue-list --limit 3 — cut to three" \
  || note_fail "gitlab issue-list --limit 3 — got $OUT"

export GLAB_LINKS_STATUS=403
pr_case "gitlab issue-list — a 403 on links is null edges, not a failure" 0 - - -- issue-list --state open
[ "$(printf '%s' "$OUT" | jq -c '[.[] | [.blockedBy, .blocking]] | unique')" = '[[null,null]]' ] \
  && ok "gitlab issue-list — every row's edges null under a 403" || note_fail "gitlab issue-list 403 — got $OUT"
[ "$(printf '%s\n' "$ERR" | grep -c 'HTTP 403')" = 1 ] && ok "gitlab issue-list — the 403 is said once on stderr" \
  || note_fail "gitlab issue-list 403 — stderr: $ERR"
export GLAB_LINKS_STATUS=500
pr_case "gitlab issue-list — a 500 on links exits 1 with empty stdout" 1 '' - -- issue-list --state open
unset GLAB_LINKS_STATUS GLAB_LINKS_JSON GLAB_SEARCH_JSON

export GLAB_ISSUE_JSON='{"iid":9,"title":"x","state":"opened","assignees":[{"username":"ann"}]}'
pr_case "gitlab issue-assign — an assigned issue is already-assigned, no PUT" 0 already-assigned - -- issue-assign 9
grep -q '^api -X PUT' "$GLAB_CALL_LOG" && note_fail "gitlab issue-assign — wrote to an assigned issue: $(cat "$GLAB_CALL_LOG")"
export GLAB_ISSUE_JSON='{"iid":9,"title":"x","state":"opened","assignees":[]}'
export GLAB_USER_JSON='{"username":"glab_stub_user","id":77}'
pr_case "gitlab issue-assign — unassigned: the user's id, then the PUT" 0 ok \
  "api -X PUT projects/:id/issues/9 -F assignee_id=77" -- issue-assign 9
grep -qx 'api user' "$GLAB_CALL_LOG" || note_fail "gitlab issue-assign — no user read: $(cat "$GLAB_CALL_LOG")"
unset GLAB_ISSUE_JSON GLAB_USER_JSON
pr_case "gitlab issue-assign --dry-run — no glab call" 0 - EMPTY -- issue-assign 9 --dry-run
[ "$(printf '%s\n' "$OUT" | grep -c '^DRY-RUN ')" = 1 ] || note_fail "gitlab issue-assign --dry-run — got: $OUT"

out=$(cd "$GITLAB_PROFILED" && PATH="$WORK/bin:$PATH" "$TRACKER" state auto-dev 2>/dev/null | "$DECIDE" tracker.capable 2>&1)
[ "$out" = capable ] && ok "gitlab state auto-dev — capable once issue-list and issue-assign land" \
  || note_fail "gitlab state auto-dev — expected 'capable', got '$out'"

echo "== F. the Azure DevOps backend (#509)"

# Every az call the stub answers is logged here, one line per call — AC2/AC4's recorded argv and
# AC3's proof that a refused call never reaches the stub at all.
AZ_CALL_LOG="$WORK/az-calls.log"
export AZ_CALL_LOG
: > "$AZ_CALL_LOG"

mkdir -p "$WORK/bin"
cat > "$WORK/bin/az" <<'AZSTUB'
#!/usr/bin/env bash
set -uo pipefail

if [ -n "${AZ_CALL_LOG:-}" ]; then printf '%s\n' "$*" >> "$AZ_CALL_LOG"; fi

fail() { echo "az stub error: $2 (Status code: $1)" >&2; exit 1; }

# Defaults declared as plain variables first — embedding a literal '{'/'}' JSON body directly in a
# `${VAR:-default}` expansion trips bash's own brace-matching (it stops at the first unmatched '}'
# inside the default), truncating the JSON before it ever reaches jq.
default_repo='{"name":"widgets","project":{"name":"Shop"},"defaultBranch":"refs/heads/main"}'
default_workitem_tmpl='{"id":ROUTE_ID,"fields":{}}'
default_create='{"id":42,"_links":{"html":{"href":"https://dev.azure.com/o/p/_workitems/edit/42"}}}'
default_comments='{"comments":[]}'
default_tags='{"value":[]}'

# The PR verbs' JSON bodies travel in --in-file (#751): copy each to $AZ_INFILE_CAPTURE when set.
if [ -n "${AZ_INFILE_CAPTURE:-}" ]; then
  prev=""
  for a in "$@"; do [ "$prev" = --in-file ] && cp "$a" "$AZ_INFILE_CAPTURE"; prev="$a"; done
fi
default_pr='{"pullRequestId":9,"title":"x","status":"active","isDraft":true,"description":"Closes #7","sourceRefName":"refs/heads/feat/7-x","targetRefName":"refs/heads/main","lastMergeSourceCommit":{"commitId":"abc123"},"createdBy":{"uniqueName":"me@acme.example"},"repository":{"name":"widgets","project":{"name":"Shop"}}}'
default_pr_list='[{"pullRequestId":9,"title":"x","status":"completed","isDraft":false,"sourceRefName":"refs/heads/feat/7-x","description":"Closes #7","closedDate":"2026-11-01T00:00:00Z","repository":{"name":"widgets","project":{"name":"Shop"}}}]'
default_pr_create='{"pullRequestId":9,"repository":{"name":"widgets","project":{"name":"Shop"}}}'
# #752: pr-merge's message travels as `@<file>`; copy it to $AZ_MSG_CAPTURE when set.
if [ -n "${AZ_MSG_CAPTURE:-}" ]; then
  prev=""
  for a in "$@"; do [ "$prev" = --merge-commit-message ] && cp "${a#@}" "$AZ_MSG_CAPTURE"; prev="$a"; done
fi
default_threads='{"value":[{"id":1,"status":"active","threadContext":{"filePath":"/src/a.sh","rightFileStart":{"line":3}},"comments":[{"id":1,"content":"fix this","commentType":"text"}]},{"id":2,"status":"fixed","threadContext":{"filePath":"/b.sh","rightFileStart":{"line":9}},"comments":[{"id":1,"content":"done","commentType":"text"}]},{"id":3,"status":"pending","threadContext":null,"comments":[{"id":1,"content":"overall","commentType":"text"}]},{"id":4,"status":"active","comments":[{"id":1,"content":"Policy updated","commentType":"system"}]},{"id":5,"status":"active","isDeleted":true,"comments":[{"id":1,"content":"gone","commentType":"text"}]}]}'
default_wi_show='{"id":5,"relations":[]}'
default_branch_stats='{"behindCount":0}'

# Pull the flags every dispatch below needs, regardless of position.
resource=""; http_method="GET"; route_id=""; route_type=""; capture=0
prev=""
for a in "$@"; do
  case "$a" in
    --route-parameters) capture=1; prev="$a"; continue ;;
    --*) capture=0 ;;
  esac
  if [ "$capture" -eq 1 ]; then
    case "$a" in
      id=*) route_id="${a#id=}" ;;
      workItemId=*) route_id="${a#workItemId=}" ;;
      'type=$'*) route_type="${a#'type=$'}" ;;
    esac
  fi
  case "$prev" in
    --resource) resource="$a" ;;
    --http-method) http_method="$a" ;;
  esac
  prev="$a"
done

case "${1-} ${2-}" in
  "boards query")
    printf '%s' "${AZ_QUERY_JSON:-[]}"
    exit 0 ;;
  "repos show")
    printf '%s' "${AZ_REPO_JSON:-$default_repo}"
    exit 0 ;;
  "repos pr")
    case "${3-}" in
      list)   printf '%s' "${AZ_PR_LIST_JSON:-$default_pr_list}" ;;
      show)   printf '%s' "${AZ_PR_JSON:-$default_pr}" ;;
      update) printf '{}' ;;
      policy)
        [ -z "${AZ_POLICY_FAIL:-}" ] || { echo "az stub: policy list failed" >&2; exit 1; }
        printf '%s' "${AZ_POLICY_JSON:-[]}" ;;
      work-item) printf '%s' "${AZ_PR_WI_JSON:-[]}" ;;
      *) echo "az stub: unsupported call: $*" >&2; exit 1 ;;
    esac
    exit 0 ;;
  "repos ref")
    case "${3-}" in
      list)   printf '%s' "${AZ_REF_JSON:-[]}" ;;
      delete) printf '{"success":true}' ;;
      *) echo "az stub: unsupported call: $*" >&2; exit 1 ;;
    esac
    exit 0 ;;
  "pipelines runs")
    [ -z "${AZ_RUNS_FAIL:-}" ] || { echo "az stub: runs list failed" >&2; exit 1; }
    printf '%s' "${AZ_RUNS_JSON:-[]}"
    exit 0 ;;
  "boards work-item")
    printf '%s' "${AZ_WI_SHOW_JSON:-$default_wi_show}"
    exit 0 ;;
  "devops invoke") : ;;
  "account show") echo "${AZ_ACCOUNT_USER:-me@acme.example}"; exit 0 ;;
  "devops project")
    if [ -n "${AZ_PROJECT_FAIL:-}" ]; then
      echo "az stub: ERROR: Please run 'az login' to setup account." >&2
      exit 1
    fi
    case "$*" in
      *"processTemplate.templateName"*) echo "${AZ_PROCESS:-Agile}" ;;
      *) echo "TestProject" ;;
    esac
    exit 0 ;;
  *) echo "az stub: unsupported call: $*" >&2; exit 1 ;;
esac

case "$resource $http_method" in
  "workitems GET")
    s="${AZ_WORKITEM_STATUS:-200}"
    case "$s" in
      2??)
        if [ -n "${AZ_WORKITEM_JSON:-}" ]; then
          printf '%s' "$AZ_WORKITEM_JSON"
        else
          printf '%s' "${default_workitem_tmpl/ROUTE_ID/$route_id}"
        fi ;;
      *) fail "$s" "work item $route_id" ;;
    esac ;;
  "workitems POST")
    printf '%s' "${AZ_CREATE_JSON:-$default_create}"
    ;;
  "workitems PATCH")
    s="${AZ_PATCH_STATUS:-200}"
    case "$s" in 2??) printf '{}' ;; *) fail "$s" "patch $route_id" ;; esac ;;
  "comments GET")
    printf '%s' "${AZ_COMMENTS_JSON:-$default_comments}"
    ;;
  "comments POST")
    printf '{}'
    ;;
  "tags GET")
    printf '%s' "${AZ_TAGS_JSON:-$default_tags}"
    ;;
  # #753: issue-list's batch read. Each call's id count is appended to $AZ_BATCH_SIZES; the reply is
  # $AZ_BATCH_JSON, or one bare work item per id in the --in-file.
  "workitemsbatch POST")
    [ -z "${AZ_BATCH_FAIL:-}" ] || fail 500 "workitemsbatch"
    inf=""; prev=""
    for a in "$@"; do [ "$prev" = --in-file ] && inf="$a"; prev="$a"; done
    # #811: the edge-state read asks for fields; its reply is $AZ_STATE_JSON, else every id Closed.
    if jq -e 'has("fields")' "$inf" >/dev/null; then
      if [ -n "${AZ_STATE_JSON:-}" ]; then printf '%s' "$AZ_STATE_JSON"
      else jq -c '{value: [.ids[] | {id: ., fields: {"System.State": "Closed"}}]}' "$inf"; fi
      exit 0
    fi
    [ -n "${AZ_BATCH_SIZES:-}" ] && jq '.ids | length' "$inf" >> "$AZ_BATCH_SIZES"
    if [ -n "${AZ_BATCH_JSON:-}" ]; then printf '%s' "$AZ_BATCH_JSON"
    else jq -c '{value: [.ids[] | {id: ., fields: {"System.Title": "t\(.)"}}]}' "$inf"; fi ;;
  "pullRequests POST") printf '%s' "$default_pr_create" ;;
  "pullRequests PATCH") printf '{}' ;;
  "pullRequestCommits GET") printf '%s' '{"value":[{"commitId":"aaa"},{"commitId":"bbb"}]}' ;;
  "branchStats GET") printf '%s' "${AZ_BRANCH_STATS_JSON:-$default_branch_stats}" ;;
  "pullRequestThreads GET")
    s="${AZ_THREADS_STATUS:-200}"
    case "$s" in 2??) printf '%s' "${AZ_THREADS_JSON:-$default_threads}" ;; *) fail "$s" "threads" ;; esac ;;
  "pullRequestThreads POST"|"pullRequestThreads PATCH"|"pullRequestThreadComments POST") printf '{}' ;;
  *) echo "az stub: unsupported invoke: resource=$resource method=$http_method" >&2; exit 1 ;;
esac
AZSTUB
chmod +x "$WORK/bin/az"

if PATH="$WORK/bin:$PATH" az frobnicate >/dev/null 2>&1; then
  note_fail "the az stub accepted an unsupported call — every assertion below would be vacuous"
fi

run_az() {
  # Same shape as run_tracker, but calls the azure-devops backend directly so a test can hand it
  # TRACKER_REPO (via --repo) without needing a fixture profile for every case.
  local dir="$1"; shift
  OUT=$(cd "$dir" && PATH="$WORK/bin:$PATH" "$TRACKER" --tracker azure-devops "$@" 2>"$WORK/err.log")
  RC=$?
  ERR=$(cat "$WORK/err.log")
}

AZBARE="$WORK/az-bare"
mkdir -p "$AZBARE"

# A fixture repository whose committed profile names an Azure DevOps org/project — proves the
# repo-profile.sh reading path, not just the $TRACKER_REPO override every other case below uses.
AZFIX="$WORK/az-profiled"
mkdir -p "$AZFIX/.claude/skills"
printf '%s\n' '# Repo profile' '' '## Tracker' \
  '- **Tracker:** azure-devops (dev.azure.com/acme/Shop) — fixture.' \
  > "$AZFIX/.claude/skills/repo-profile.md"

# verbs — the introspection call, answered before any org/project resolution.
: > "$AZ_CALL_LOG"
run_az "$AZBARE" --repo acme/Shop verbs
if [ "$RC" -ne 0 ] || ! grep -Fxq 'issue-view' <<<"$OUT"; then
  note_fail "verbs — expected issue-view among the verbs, exited $RC: $OUT ($ERR)"
elif [ -s "$AZ_CALL_LOG" ]; then
  note_fail "verbs — must answer without calling az at all: $(cat "$AZ_CALL_LOG")"
else
  ok "verbs — lists every verb this backend implements, without calling az"
fi

# AC1 — a fixture profile naming azure-devops, and needs(create-issue) covered by implements(this
# backend), answers capable through the real Step-1 pipe (tracker.sh state | decide.sh
# tracker.capable) — the same pipe case B's github end-to-end assertion runs.
out=$(cd "$AZFIX" && PATH="$WORK/bin:$PATH" "$TRACKER" state create-issue 2>/dev/null | "$DECIDE" tracker.capable 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  note_fail "AC1 capable — the Step 1 pipe exited $rc: $out"
elif [ "$out" != "capable" ]; then
  note_fail "AC1 capable — expected 'capable' for create-issue on azure-devops, got '$out'"
else
  ok "AC1 capable — tracker.sh state create-issue | decide.sh tracker.capable answers capable via the committed profile"
fi

# repo — org/project + repo name parsed off origin, defaultBranch stripped of refs/heads/.
git -C "$AZBARE" init -q -b main
git -C "$AZBARE" remote add origin "https://dev.azure.com/acme/Shop/_git/widgets"
AZ_REPO_JSON='{"name":"widgets","project":{"name":"Shop"},"defaultBranch":"refs/heads/main"}' \
  run_az "$AZBARE" --repo acme/Shop repo
if [ "$RC" -ne 0 ]; then
  note_fail "repo — exited $RC ($ERR)"
else
  got=$(printf '%s' "$OUT" | jq -c '.' 2>/dev/null) || got="<unparseable: $OUT>"
  want='{"slug":"Shop/widgets","host":"dev.azure.com","defaultBranch":"main","originSlug":"https://dev.azure.com/acme/Shop/_git/widgets"}'
  if [ "$got" != "$want" ]; then
    note_fail "repo — wrong stdout
      want: $want
      got:  $got"
  else
    ok "repo — slug/host/defaultBranch/originSlug, defaultBranch stripped of refs/heads/"
  fi
fi

# #693 — the dispatcher hands the backend the profile detail it resolved, so the backend need not
# re-read repo-profile.sh. The detail names a DIFFERENT org than TRACKER_REPO would, to prove the source.
AZDET="$WORK/az-detail"
mkdir -p "$AZDET/.claude/skills"
printf '%s\n' '# Repo profile' '' '## Tracker' \
  '- **Tracker:** azure-devops (dev.azure.com/detorg/DetProj) — fixture.' \
  > "$AZDET/.claude/skills/repo-profile.md"
AZ_BACKEND="$KIT_ROOT/scripts/tracker/azure-devops.sh"

# AC1 — tracker.sh --tracker azure-devops with a committed profile exports TRACKER_DETAIL.
: > "$AZ_CALL_LOG"
AZ_REPO_JSON='{"name":"w","project":{"name":"DetProj"},"defaultBranch":"refs/heads/main"}' \
  run_az "$AZDET" repo
if [ "$RC" -ne 0 ] || ! grep -Fq 'dev.azure.com/detorg' "$AZ_CALL_LOG" 2>/dev/null; then
  note_fail "#693 AC1 — TRACKER_DETAIL did not reach the backend (rc=$RC, calls: $(cat "$AZ_CALL_LOG"), $ERR)"
else
  ok "#693 AC1 — tracker.sh exports the profile's detail to the backend"
fi

# AC2 — with TRACKER_DETAIL set, no profile is needed (a bare dir would fail the fallback).
OUT=$(cd "$AZBARE" && PATH="$WORK/bin:$PATH" TRACKER_DETAIL=dev.azure.com/detorg/DetProj \
  AZ_REPO_JSON='{"name":"w","project":{"name":"DetProj"},"defaultBranch":"refs/heads/main"}' \
  "$AZ_BACKEND" repo 2>&1) && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  note_fail "#693 AC2 — backend with TRACKER_DETAIL still needed the profile: $OUT"
else
  ok "#693 AC2 — _org_project prefers TRACKER_DETAIL without reading the profile"
fi

# AC3 — a direct call with neither variable still falls back to the profile read.
: > "$AZ_CALL_LOG"
(cd "$AZDET" && PATH="$WORK/bin:$PATH" \
  AZ_REPO_JSON='{"name":"w","project":{"name":"DetProj"},"defaultBranch":"refs/heads/main"}' \
  "$AZ_BACKEND" repo >/dev/null 2>&1) && rc=0 || rc=$?
if [ "$rc" -ne 0 ] || ! grep -Fq 'dev.azure.com/detorg' "$AZ_CALL_LOG"; then
  note_fail "#693 AC3 — direct call lost its repo-profile.sh fallback (rc=$rc)"
else
  ok "#693 AC3 — a direct call still falls back to repo-profile.sh"
fi

# AC5 — issue-view defaults format to html when multilineFieldsFormat is absent (a work item edited
# by hand in the browser), splits System.Tags on '; '.
AZ_WORKITEM_JSON='{"id":7,"fields":{"System.Title":"A stub item","System.State":"Active","System.Description":"body text","System.Tags":"bug; area: skills"}}' \
  run_az "$AZBARE" --repo acme/Shop issue-view 7
if [ "$RC" -ne 0 ]; then
  note_fail "AC5 issue-view — exited $RC ($ERR)"
else
  got=$(printf '%s' "$OUT" | jq -c '.' 2>/dev/null) || got="<unparseable: $OUT>"
  want='{"number":7,"title":"A stub item","state":"open","body":"body text","labels":["bug","area: skills"],"url":"","format":"html"}'
  if [ "$got" != "$want" ]; then
    note_fail "AC5 issue-view — wrong normalisation (default format must be html when multilineFieldsFormat is absent; state open/closed like issue-search, not the raw Azure state)
      want: $want
      got:  $got"
  else
    ok "AC5 issue-view — format defaults to html, System.Tags split on '; ', state open/closed like issue-search"
  fi
fi

# issue-search — Done maps to closed.
AZ_QUERY_JSON='[{"id":12,"fields":{"System.Title":"A stub closed item","System.State":"Done"}}]' \
  run_az "$AZBARE" --repo acme/Shop issue-search --query csv --state all
if [ "$RC" -ne 0 ]; then
  note_fail "issue-search — exited $RC ($ERR)"
else
  got=$(printf '%s' "$OUT" | jq -c '.' 2>/dev/null) || got="<unparseable: $OUT>"
  want='[{"number":12,"title":"A stub closed item","state":"closed"}]'
  if [ "$got" != "$want" ]; then
    note_fail "issue-search — wrong stdout
      want: $want
      got:  $got"
  else
    ok "issue-search — System.State 'Done' normalises to 'closed'"
  fi
fi

# AC2 — issue-create on an Agile project: the patch sets Description + Markdown format + Tags,
# posts to the 'User Story' type, and the normalised reply is {number,url}.
BODY_F="$WORK/body.md"
printf 'a description\n' > "$BODY_F"
: > "$AZ_CALL_LOG"
AZ_PROCESS=Agile run_az "$AZBARE" --repo acme/Shop issue-create --title T \
  --label "priority: high" --label "area: skills" --body-file "$BODY_F"
if [ "$RC" -ne 0 ]; then
  note_fail "AC2 issue-create — exited $RC ($ERR)"
else
  got=$(printf '%s' "$OUT" | jq -c '.' 2>/dev/null) || got="<unparseable: $OUT>"
  want='{"number":42,"url":"https://dev.azure.com/o/p/_workitems/edit/42"}'
  if [ "$got" != "$want" ]; then
    note_fail "AC2 issue-create — wrong stdout
      want: $want
      got:  $got"
  elif ! grep -Fq -- '--route-parameters project=Shop type=$User Story' "$AZ_CALL_LOG" \
    && ! grep -Fq -- 'type=$User' "$AZ_CALL_LOG"; then
    note_fail "AC2 issue-create — az was not asked for the 'User Story' type on an Agile project:
      $(cat "$AZ_CALL_LOG")"
  else
    ok "AC2 issue-create — Agile -> User Story, {number,url} printed"
  fi
fi
PATCH_SEEN=$(cat "$WORK"/*.json 2>/dev/null || true)

# The patch itself: re-run capturing the --in-file this call built, to assert its operations
# directly rather than trusting the stub's canned reply alone.
CAPTURE_DIR=$(kit_scratch)
cat > "$CAPTURE_DIR/az" <<'CAPSTUB'
#!/usr/bin/env bash
set -uo pipefail
prev=""
for a in "$@"; do
  if [ "$prev" = --in-file ]; then cp "$a" "${AZ_PATCH_CAPTURE:?}"; fi
  prev="$a"
done
case "${1-} ${2-}" in
  "devops project") echo "Agile"; exit 0 ;;
  "devops invoke") printf '{"id":42,"_links":{"html":{"href":"https://dev.azure.com/o/p/_workitems/edit/42"}}}'; exit 0 ;;
  *) echo "unsupported"; exit 1 ;;
esac
CAPSTUB
chmod +x "$CAPTURE_DIR/az"
AZ_PATCH_CAPTURE="$WORK/create-patch.json"
export AZ_PATCH_CAPTURE
(cd "$AZBARE" && PATH="$CAPTURE_DIR:$PATH" TRACKER_REPO=acme/Shop \
  "$KIT_ROOT/scripts/tracker/azure-devops.sh" issue-create --title T --label bug --body-file "$BODY_F" >/dev/null 2>&1)
if [ ! -s "$AZ_PATCH_CAPTURE" ]; then
  note_fail "AC2 patch — issue-create sent no --in-file patch to capture"
else
  ops=$(jq -c 'map({op,path})' "$AZ_PATCH_CAPTURE" 2>/dev/null) || ops="<unparseable>"
  want_ops='[{"op":"add","path":"/fields/System.Title"},{"op":"add","path":"/fields/System.Description"},{"op":"add","path":"/multilineFieldsFormat/System.Description"},{"op":"add","path":"/fields/System.Tags"}]'
  if [ "$ops" != "$want_ops" ]; then
    note_fail "AC2 patch — wrong operations
      want: $want_ops
      got:  $ops"
  else
    fmt=$(jq -r '.[] | select(.path == "/multilineFieldsFormat/System.Description") | .value' "$AZ_PATCH_CAPTURE")
    if [ "$fmt" != "Markdown" ]; then
      note_fail "AC2 patch — Description and its Markdown format must be written together: $fmt"
    else
      ok "AC2 patch — Title, Description, Markdown format and Tags all set in the one patch"
    fi
  fi
fi
rm -rf "$CAPTURE_DIR" "$AZ_PATCH_CAPTURE"

# AC3 — an inherited process ("Agile - Custom") is refused by name, and az records no request.
: > "$AZ_CALL_LOG"
AZ_PROCESS="Agile - Custom" run_az "$AZBARE" --repo acme/Shop issue-create --title T --body-file "$BODY_F"
if [ "$RC" -ne 2 ]; then
  note_fail "AC3 issue-create — expected exit 2 for an unmapped process, got $RC ($ERR)"
elif ! grep -Fq 'Agile - Custom' <<<"$ERR"; then
  note_fail "AC3 issue-create — the refusal does not name the process: $ERR"
else
  ok "AC3 issue-create — 'Agile - Custom' exits 2, named, no verdict guessed"
fi

# Basic has no Bug work-item type (only Epic, Issue, Task) — a bug label there still files an Issue
# rather than a type the API would reject (review finding).
: > "$AZ_CALL_LOG"
AZ_PROCESS=Basic run_az "$AZBARE" --repo acme/Shop issue-create --title T --label bug --body-file "$BODY_F"
if [ "$RC" -ne 0 ]; then
  note_fail "issue-create Basic+bug — exited $RC ($ERR)"
elif ! grep -Fq -- 'type=$Issue' "$AZ_CALL_LOG"; then
  note_fail "issue-create Basic+bug — Basic has no Bug type, expected type=\$Issue: $(cat "$AZ_CALL_LOG")"
else
  ok "issue-create Basic+bug — Basic has no Bug type, files an Issue instead (review finding)"
fi

# A failed az call (not logged in, network) while reading the process must surface as a host
# failure (exit 1) — not be swallowed into the same 'unmapped process' exit 2 a genuinely unknown
# process name gets (review finding: the two used to collapse, hiding the real error).
AZ_PROJECT_FAIL=1 run_az "$AZBARE" --repo acme/Shop issue-create --title T --body-file "$BODY_F"
if [ "$RC" -ne 1 ]; then
  note_fail "issue-create az-failure-reading-process — expected exit 1 (host failure), got $RC ($ERR)"
elif ! grep -Fq 'az login' <<<"$ERR"; then
  note_fail "issue-create az-failure-reading-process — the real az error is not surfaced: $ERR"
else
  ok "issue-create az-failure-reading-process — exit 1, the real az error surfaced, not a misleading 'unmapped process'"
fi

# issue-edit-body — an empty file refuses before any az call.
: > "$AZ_CALL_LOG"
EMPTY_F="$WORK/empty.md"
: > "$EMPTY_F"
run_az "$AZBARE" --repo acme/Shop issue-edit-body 7 --body-file "$EMPTY_F"
if [ "$RC" -ne 2 ]; then
  note_fail "issue-edit-body empty file — expected exit 2, got $RC ($ERR)"
elif [ -s "$AZ_CALL_LOG" ]; then
  note_fail "issue-edit-body empty file — az was called anyway: $(cat "$AZ_CALL_LOG")"
else
  ok "issue-edit-body — refuses a missing/empty --body-file before any az call"
fi

# issue-add-labels — the union of existing and new tags is written.
AZ_WORKITEM_JSON='{"id":7,"fields":{"System.Tags":"bug"}}' \
  run_az "$AZBARE" --repo acme/Shop issue-add-labels 7 "area: skills"
if [ "$RC" -ne 0 ]; then
  note_fail "issue-add-labels — exited $RC ($ERR)"
else
  ok "issue-add-labels — reads the current tags and writes the union"
fi

# AC4 — issue-link-parent and issue-link-blocked-by add the right relation and print ok.
AZ_WORKITEM_JSON='{"id":21,"relations":[]}' \
  run_az "$AZBARE" --repo acme/Shop issue-link-parent 20 21
if [ "$RC" -ne 0 ] || [ "$OUT" != "ok" ]; then
  note_fail "AC4 issue-link-parent — expected 'ok' exit 0, got '$OUT' exit $RC ($ERR)"
else
  ok "AC4 issue-link-parent — new relation added, prints ok"
fi

AZ_WORKITEM_JSON='{"id":19,"relations":[]}' \
  run_az "$AZBARE" --repo acme/Shop issue-link-blocked-by 21 19
if [ "$RC" -ne 0 ] || [ "$OUT" != "ok" ]; then
  note_fail "AC4 issue-link-blocked-by — expected 'ok' exit 0, got '$OUT' exit $RC ($ERR)"
else
  ok "AC4 issue-link-blocked-by — new relation added, prints ok"
fi

# An existing relation is idempotent: still 'ok', no PATCH needed (the stub only serves GET for
# 'workitems GET' — a PATCH reaching it here would 400 with 'unsupported invoke', proving none was sent).
AZ_WORKITEM_JSON='{"id":21,"relations":[{"rel":"System.LinkTypes.Hierarchy-Reverse","url":"https://dev.azure.com/acme/_apis/wit/workItems/20"}]}' \
  run_az "$AZBARE" --repo acme/Shop issue-link-parent 20 21
if [ "$RC" -ne 0 ] || [ "$OUT" != "ok" ]; then
  note_fail "AC4 issue-link-parent (already wired) — expected 'ok' exit 0, got '$OUT' exit $RC ($ERR)"
else
  ok "AC4 issue-link-parent — an existing relation is idempotent, still ok, no write sent"
fi

# --dry-run prints the write it would send and calls az not at all.
: > "$AZ_CALL_LOG"
run_az "$AZBARE" --repo acme/Shop issue-link-parent 20 21 --dry-run
if [ "$RC" -ne 0 ]; then
  note_fail "issue-link-parent --dry-run — exited $RC ($ERR)"
elif [ -s "$AZ_CALL_LOG" ]; then
  note_fail "issue-link-parent --dry-run — az was called anyway: $(cat "$AZ_CALL_LOG")"
elif ! grep -Fq 'DRY-RUN' <<<"$OUT"; then
  note_fail "issue-link-parent --dry-run — did not print the write it would send: $OUT"
else
  ok "issue-link-parent --dry-run — prints the write it would send, calls az not at all"
fi

# --resolve-only resolves both ends by a read and writes nothing. Regression: this flag used to be
# filed as a stray positional and silently ignored (github.sh honours it; wire-edges.sh runs an
# up-front --resolve-only pass over every edge so a bad id is reported before anything is sent) —
# falling through to a real write here was exactly the partial-write failure that pass exists to
# prevent (code-review finding, #509).
: > "$AZ_CALL_LOG"
AZ_WORKITEM_JSON='{"id":21,"relations":[]}' \
  run_az "$AZBARE" --repo acme/Shop issue-link-parent 20 21 --resolve-only
if [ "$RC" -ne 0 ]; then
  note_fail "issue-link-parent --resolve-only — exited $RC ($ERR)"
elif grep -q -- '--http-method PATCH' "$AZ_CALL_LOG"; then
  note_fail "issue-link-parent --resolve-only — a write (PATCH) was sent; nothing may ever be written in this mode: $(cat "$AZ_CALL_LOG")"
elif [ "$(grep -c -- '--http-method GET' "$AZ_CALL_LOG")" -lt 2 ]; then
  note_fail "issue-link-parent --resolve-only — expected both ends (child + target) resolved by a GET: $(cat "$AZ_CALL_LOG")"
else
  ok "issue-link-parent --resolve-only — resolves both ends, writes nothing (regression, #509 review)"
fi

# issue-children — a WorkItemLinks reply becomes a de-duplicated array of child ids.
AZ_QUERY_JSON='[{"source":{"id":10},"target":{"id":21}},{"source":{"id":10},"target":{"id":22}}]' \
  run_az "$AZBARE" --repo acme/Shop issue-children 10
if [ "$RC" -ne 0 ]; then
  note_fail "issue-children — exited $RC ($ERR)"
else
  got=$(printf '%s' "$OUT" | jq -c '.' 2>/dev/null) || got="<unparseable: $OUT>"
  if [ "$got" != '[21,22]' ]; then
    note_fail "issue-children — wrong stdout
      want: [21,22]
      got:  $got"
  else
    ok "issue-children — a WorkItemLinks reply becomes [21,22]"
  fi
fi

# issue-blocked-by-count — counts only OPEN predecessors: #19 (Active) counts, #18 (Closed) does not.
CAPTURE_DIR2=$(kit_scratch)
cat > "$CAPTURE_DIR2/az" <<'BLOCKSTUB'
#!/usr/bin/env bash
set -uo pipefail
route_id=""; capture=0
for a in "$@"; do
  case "$a" in
    --route-parameters) capture=1; continue ;;
    --*) capture=0 ;;
  esac
  if [ "$capture" -eq 1 ]; then
    case "$a" in id=*) route_id="${a#id=}" ;; esac
  fi
done
case "$route_id" in
  21) printf '{"id":21,"relations":[{"rel":"System.LinkTypes.Dependency-Reverse","url":"https://dev.azure.com/o/p/_apis/wit/workItems/19"},{"rel":"System.LinkTypes.Dependency-Reverse","url":"https://dev.azure.com/o/p/_apis/wit/workItems/18"}]}' ;;
  19) printf '{"id":19,"fields":{"System.State":"Active"}}' ;;
  18) printf '{"id":18,"fields":{"System.State":"Closed"}}' ;;
  *) echo "blocked-by stub: unexpected id $route_id" >&2; exit 1 ;;
esac
BLOCKSTUB
chmod +x "$CAPTURE_DIR2/az"
run_out=$(cd "$AZBARE" && PATH="$CAPTURE_DIR2:$PATH" TRACKER_REPO=acme/Shop \
  "$KIT_ROOT/scripts/tracker/azure-devops.sh" issue-blocked-by-count 21 2>"$WORK/err2.log")
if [ "$run_out" != "1" ]; then
  note_fail "issue-blocked-by-count — want 1 (only #19 is open), got '$run_out' ($(cat "$WORK/err2.log"))"
else
  ok "issue-blocked-by-count — counts only open predecessors (1 of 2)"
fi
rm -rf "$CAPTURE_DIR2"

# AC6 — never az boards work-item create|update, the only two calls that cannot set
# multilineFieldsFormat and would silently land an HTML description.
if grep -nE 'az boards work-item (create|update)' "$KIT_ROOT/scripts/tracker/azure-devops.sh"; then
  note_fail "AC6 — az boards work-item create|update must never appear in azure-devops.sh"
else
  ok "AC6 — no az boards work-item create|update anywhere in the backend"
fi




echo "== F2. the PR verbs on Azure DevOps (#751)"

PR_TRACKER=azure-devops; PR_DIR="$AZFIX"; PR_LOG="$AZ_CALL_LOG"
AZ_INFILE_CAPTURE="$WORK/az-infile.json"; export AZ_INFILE_CAPTURE
pr_case "azure pr-create --draft — {number,url} with the web URL built" 0 \
  '{"number":9,"url":"https://dev.azure.com/acme/Shop/_git/widgets/pullrequest/9"}' \
  "devops invoke" -- pr-create --draft --base main --head feat/1-x --title T --body-file "$PR_BODY"
got=$(jq -c '[.isDraft, .sourceRefName, .targetRefName, .title, .description]' "$AZ_INFILE_CAPTURE" 2>/dev/null)
if [ "$got" != '[true,"refs/heads/feat/1-x","refs/heads/main","T","Closes #7\n"]' ]; then
  note_fail "azure pr-create — wrong --in-file body: $got"
elif ! grep -Fq '"isDraft": true' "$AZ_INFILE_CAPTURE"; then
  note_fail "azure pr-create — the body does not send \"isDraft\": true"
else
  ok "azure pr-create — --in-file carries isDraft, refs/heads/ refs and the file's description"
fi
pr_case "azure pr-ready — az repos pr update --id <n> --draft false" 0 '' \
  "repos pr update --id 9 --draft false" -- pr-ready 9
pr_case "azure pr-list --state merged — --status completed, closedDate→mergedAt" 0 \
  '[{"number":9,"title":"x","url":"https://dev.azure.com/acme/Shop/_git/widgets/pullrequest/9","state":"merged","isDraft":false,"headBranch":"feat/7-x","body":"Closes #7","mergedAt":"2026-11-01T00:00:00Z"}]' \
  "--status completed" -- pr-list --state merged
pr_case "azure pr-list --search — re-reads each candidate's full description" 0 - \
  "repos pr show" -- pr-list --search 'Closes #7'
[ "$(printf '%s' "$OUT" | jq -r '.[0].body' 2>/dev/null)" = "Closes #7" ] \
  || note_fail "azure pr-list --search — the matching PR was not returned: $OUT"
pr_case "azure pr-view — refs/heads/ stripped, web URL built, author a login" 0 \
  '{"number":9,"title":"x","url":"https://dev.azure.com/acme/Shop/_git/widgets/pullrequest/9","state":"open","isDraft":true,"body":"Closes #7","headBranch":"feat/7-x","baseBranch":"main","headSha":"abc123","author":"me@acme.example","mergedAt":null,"mergeSha":null}' \
  "repos pr show" -- pr-view 9
pr_case "azure pr-commits — an array of SHAs" 0 '["aaa","bbb"]' "pullRequestCommits" -- pr-commits 9
pr_case "azure pr-edit-body — PATCH {description} through --in-file" 0 '' "pullRequestId=9" -- \
  pr-edit-body 9 --body-file "$PR_BODY"
[ "$(jq -c . "$AZ_INFILE_CAPTURE" 2>/dev/null)" = '{"description":"Closes #7\n"}' ] \
  || note_fail "azure pr-edit-body — wrong --in-file body: $(cat "$AZ_INFILE_CAPTURE")"
PR_LONG="$WORK/pr-long.md"; head -c 4001 /dev/zero | tr '\0' 'a' > "$PR_LONG"
pr_case "azure pr-create — a 4001-character description is refused, no az call" 2 - EMPTY -- \
  pr-create --base main --head feat/1-x --title T --body-file "$PR_LONG"
pr_case "azure pr-edit-body — a 4001-character description is refused, no az call" 2 - EMPTY -- \
  pr-edit-body 9 --body-file "$PR_LONG"
pr_case "azure pr-create — refuses an empty --body-file, no az call" 2 - EMPTY -- \
  pr-create --base main --head feat/1-x --title T --body-file "$PR_EMPTY"
pr_case "azure pr-edit-body — refuses a missing --body-file, no az call" 2 - EMPTY -- \
  pr-edit-body 9 --body-file "$WORK/no-such-file"
pr_dry_runs "$PR_BODY"
unset AZ_INFILE_CAPTURE

out=$(cd "$AZFIX" && PATH="$WORK/bin:$PATH" "$TRACKER" state implement-issue 2>/dev/null | "$DECIDE" tracker.capable 2>&1)
if [ "$out" != capable ]; then
  note_fail "azure state implement-issue — expected 'capable', got '$out'"
else
  ok "azure state implement-issue — capable once the six PR verbs land"
fi

echo "== F3. the merge verbs on Azure DevOps (#752)"

# Same pr_case seam as F2: tracker.sh's stdout and exit code, and AZ_CALL_LOG. Each case feeds a raw
# Azure DevOps reply through the stub and asserts the normalised stdout, never azure-devops.sh's jq.
PR_TRACKER=azure-devops; PR_DIR="$AZFIX"; PR_LOG="$AZ_CALL_LOG"
AZ_PR_TMPL='{"pullRequestId":9,"status":"active","isDraft":DRAFT,"mergeStatus":"MS","sourceRefName":"refs/heads/feat/7-x","targetRefName":"refs/heads/main","reviewers":[{"vote":10,"isRequired":true}],"repository":{"name":"widgets","project":{"name":"Shop"}}}'
POL_OK='[{"status":"approved","configuration":{"isBlocking":true,"type":{"displayName":"Build"},"settings":{"displayName":"CI build"}}},{"status":"notApplicable","configuration":{"isBlocking":true,"type":{"displayName":"Work item linking"}}},{"status":"rejected","configuration":{"isBlocking":false,"type":{"displayName":"Comment requirements"}}}]'
POL_REJ='[{"status":"rejected","configuration":{"isBlocking":true,"type":{"displayName":"Build"}}}]'
POL_RUN='[{"status":"running","configuration":{"isBlocking":true,"type":{"displayName":"Build"}}}]'

# mergeStatus + blocking policies → mergeStateStatus. CLEAN only on `succeeded` with every blocking
# policy approved/notApplicable (a non-blocking rejection does not count); anything else is UNKNOWN.
for c in "false:succeeded:OK:CLEAN" "false:conflicts:OK:DIRTY" "false:succeeded:REJ:BLOCKED" \
         "false:rejectedByPolicy:OK:BLOCKED" "false:queued:OK:UNKNOWN" "false:succeeded:RUN:UNKNOWN" \
         "false:someNewWord:OK:UNKNOWN" "true:succeeded:OK:DRAFT"; do
  IFS=: read -r d ms pol want <<<"$c"
  pj=$(printf '%s' "$AZ_PR_TMPL" | sed "s/DRAFT/$d/; s/\"MS\"/\"$ms\"/")
  case "$pol" in OK) pv="$POL_OK" ;; REJ) pv="$POL_REJ" ;; RUN) pv="$POL_RUN" ;; esac
  export AZ_PR_JSON="$pj" AZ_POLICY_JSON="$pv"
  pr_case "azure pr-merge-state — draft=$d $ms + $pol policies is $want" 0 - "repos pr policy list --id 9" -- pr-merge-state 9
  got=$(printf '%s' "$OUT" | jq -r .mergeStateStatus 2>/dev/null)
  [ "$got" = "$want" ] || note_fail "azure pr-merge-state draft=$d $ms/$pol — want $want, got '$got' ($OUT)"
done
# AC3 end to end, as E3: a running blocking policy is UNKNOWN, and merge.step4 waits on it.
AZ_PR_JSON=$(printf '%s' "$AZ_PR_TMPL" | sed 's/DRAFT/false/; s/"MS"/"succeeded"/'); export AZ_PR_JSON
export AZ_POLICY_JSON="$POL_RUN" AZ_THREADS_JSON='{"value":[]}'
pr_case "azure pr-merge-state — a running policy, no threads, not behind" 0 - - -- pr-merge-state 9
got=$(step4_of "$OUT")
[ "$got" = wait/unknown ] && ok "azure running policy → merge.step4 wait/unknown, never merge" \
  || note_fail "azure running policy → merge.step4 — want wait/unknown, got $got ($OUT)"
unset AZ_THREADS_JSON
AZ_PR_JSON=$(printf '%s' "$AZ_PR_TMPL" | sed 's/DRAFT/false/; s/"MS"/"succeeded"/'); export AZ_PR_JSON
export AZ_POLICY_JSON="$POL_OK" AZ_BRANCH_STATS_JSON='{"name":"feat/7-x","aheadCount":2,"behindCount":3}'
pr_case "azure pr-merge-state — behindCount is behind_by, active text threads' paths without the leading /" 0 \
  '{"behind_by":3,"mergeStateStatus":"CLEAN","isDraft":false,"reviewDecision":"APPROVED","unresolved_threads":["src/a.sh","(pr-level)"]}' \
  "branchStats" -- pr-merge-state 9
for want in "name=feat/7-x" "baseVersionDescriptor.version=main"; do
  grep -Fq -- "$want" "$AZ_CALL_LOG" || note_fail "azure pr-merge-state — branch stats not asked for '$want': $(cat "$AZ_CALL_LOG")"
done
unset AZ_BRANCH_STATS_JSON
for c in "-10:true:CHANGES_REQUESTED" "-5:false:CHANGES_REQUESTED" "0:true:REVIEW_REQUIRED" "10:false:null"; do
  IFS=: read -r v req want <<<"$c"
  AZ_PR_JSON=$(printf '%s' "$AZ_PR_JSON" | jq -c --argjson v "$v" --argjson r "$req" '.reviewers = [{vote: $v, isRequired: $r}]')
  pr_case "azure pr-merge-state — a vote of $v (required=$req) is reviewDecision $want" 0 - - -- pr-merge-state 9
  got=$(printf '%s' "$OUT" | jq -r .reviewDecision 2>/dev/null)
  [ "$got" = "$want" ] || note_fail "azure pr-merge-state vote $v/$req — want $want, got '$got' ($OUT)"
done
export AZ_THREADS_STATUS=500
pr_case "azure pr-merge-state — a failed threads read exits 1 and prints nothing" 1 '' - -- pr-merge-state 9
pr_case "azure pr-threads — a failed threads read is exit 1, never []" 1 '' - -- pr-threads 9
unset AZ_THREADS_STATUS
export AZ_POLICY_FAIL=1
pr_case "azure pr-merge-state — a failed policy read exits 1 and prints nothing" 1 '' - -- pr-merge-state 9
pr_case "azure pr-checks — a failed policy read is exit 1, never []" 1 '' - -- pr-checks 9
unset AZ_POLICY_FAIL
pr_case "azure pr-threads — live text threads only, path without the leading /, resolved off active/pending" 0 \
  '[{"id":1,"path":"src/a.sh","line":3,"body":"fix this","isResolved":false},{"id":2,"path":"b.sh","line":9,"body":"done","isResolved":true},{"id":3,"path":null,"line":null,"body":"overall","isResolved":false}]' \
  "pullRequestThreads" -- pr-threads 9

pr_case "azure pr-checks — the PR's policies, by display name, bucketed" 0 \
  '[{"name":"CI build","state":"approved","bucket":"pass"},{"name":"Work item linking","state":"notApplicable","bucket":"skipping"},{"name":"Comment requirements","state":"rejected","bucket":"fail"}]' \
  "repos pr policy list --id 9" -- pr-checks 9
export AZ_POLICY_JSON='[{"status":"queued","configuration":{"isBlocking":true,"type":{"displayName":"Build"}}},{"status":"broken","configuration":{"isBlocking":true,"type":{"displayName":"Status"}}}]'
pr_case "azure pr-checks — broken is fail, anything else pending" 0 \
  '[{"name":"Build","state":"queued","bucket":"pending"},{"name":"Status","state":"broken","bucket":"fail"}]' - -- pr-checks 9
unset AZ_POLICY_JSON
pr_case "azure pr-checks — no policies is [] and exit 0" 0 '[]' - -- pr-checks 9
unset AZ_PR_JSON

# Pipeline runs → check-run words, filtered to the sha: every run on it, unreduced.
export AZ_RUNS_JSON='[{"id":1,"sourceVersion":"abc123","status":"completed","result":"succeeded","definition":{"name":"build"},"_links":{"web":{"href":"https://dev.azure.com/acme/Shop/_build/results?buildId=1"}}},{"id":2,"sourceVersion":"abc123","status":"completed","result":"partiallySucceeded","definition":{"name":"test"}},{"id":3,"sourceVersion":"other","status":"completed","result":"failed","definition":{"name":"build"}},{"id":4,"sourceVersion":"abc123","status":"inProgress","definition":{"name":"lint"}},{"id":5,"sourceVersion":"abc123","status":"completed","result":"none","definition":{"name":"odd"}},{"id":6,"sourceVersion":"abc123","status":"notStarted","definition":{"name":"e2e"}},{"id":7,"sourceVersion":"abc123","status":"completed","result":"canceled","definition":{"name":"old"}},{"id":8,"sourceVersion":"abc123","status":"postponed","definition":{"name":"later"}}]'
pr_case "azure commit-checks — runs on the sha only, partiallySucceeded is failure, unknown is UNKNOWN" 0 \
  '[{"name":"build","state":"success","bucket":"pass","id":1,"app":null,"html_url":"https://dev.azure.com/acme/Shop/_build/results?buildId=1"},{"name":"test","state":"failure","bucket":"fail","id":2,"app":null,"html_url":null},{"name":"lint","state":"in_progress","bucket":"pending","id":4,"app":null,"html_url":null},{"name":"odd","state":"UNKNOWN","bucket":"pending","id":5,"app":null,"html_url":null},{"name":"e2e","state":"queued","bucket":"pending","id":6,"app":null,"html_url":null},{"name":"old","state":"cancelled","bucket":"cancel","id":7,"app":null,"html_url":null},{"name":"later","state":"waiting","bucket":"pending","id":8,"app":null,"html_url":null}]' \
  "pipelines runs list" -- commit-checks abc123
grep -Fq -- "--top 100" "$AZ_CALL_LOG" || note_fail "azure commit-checks — runs list without --top 100: $(cat "$AZ_CALL_LOG")"
# A PR validation build runs on the test merge commit: its sourceVersion is that merge, and the PR
# head merge-pr passes (pr-view's headSha) is only in triggerInfo."pr.sourceSha".
export AZ_RUNS_JSON='[{"id":9,"sourceVersion":"merge999","triggerInfo":{"pr.sourceSha":"abc123"},"status":"completed","result":"succeeded","definition":{"name":"pr-build"}},{"id":10,"sourceVersion":"merge888","triggerInfo":{"pr.sourceSha":"other"},"status":"completed","result":"failed","definition":{"name":"pr-build"}}]'
pr_case "azure commit-checks — a PR build whose triggerInfo pr.sourceSha is the sha counts" 0 \
  '[{"name":"pr-build","state":"success","bucket":"pass","id":9,"app":null,"html_url":null}]' - -- commit-checks abc123
# A sha older than the 100-run window: a full window with no run on it is unverified, never [] (#806).
AZ_RUNS_JSON=$(jq -nc '[range(100) | {id: ., sourceVersion: "newer", status: "completed", result: "succeeded", definition: {name: "build"}}]')
export AZ_RUNS_JSON
pr_case "azure commit-checks — a sha outside a full 100-run window is UNKNOWN pending, never []" 0 \
  '[{"name":"commit-checks: sha not in the 100 newest runs","state":"UNKNOWN","bucket":"pending","id":null,"app":null,"html_url":null}]' \
  - -- commit-checks abc123
export AZ_RUNS_JSON='[{"id":1,"sourceVersion":"other","status":"completed","result":"succeeded","definition":{"name":"build"}}]'
pr_case "azure commit-checks — a short window with no run on the sha is still []" 0 '[]' - -- commit-checks abc123
unset AZ_RUNS_JSON
# The post-merge base run (#807): a green and a red run on the merge sha, end to end.
az_run() { printf '{"id":%s,"sourceVersion":"abc123","status":"completed","result":"%s","definition":{"name":"%s"}}' "$1" "$2" "$3"; }
export AZ_RUNS_JSON="[$(az_run 1 succeeded build)]"
got=$(base_verdict "$AZFIX" abc123)
[ "$got" = "green (clear)" ] && ok "azure base run — a succeeded run on the sha is 'green (clear)'" || note_fail "azure green base run — got '$got'"
export AZ_RUNS_JSON="[$(az_run 1 succeeded build),$(az_run 2 failed test)]"
got=$(base_verdict "$AZFIX" abc123)
[ "$got" = "RED (failed)" ] && ok "azure base run — a failed run on the sha is 'RED (failed)'" || note_fail "azure red base run — got '$got'"
unset AZ_RUNS_JSON
export AZ_RUNS_FAIL=1
pr_case "azure commit-checks — a host error is exit 1, never []" 1 '' - -- commit-checks abc123
unset AZ_RUNS_FAIL

AZ_INFILE_CAPTURE="$WORK/az-infile.json"; export AZ_INFILE_CAPTURE
pr_case "azure pr-thread-resolve — replies, then closes the thread" 0 '' "pullRequestThreads" -- \
  pr-thread-resolve 9 1 --body-file "$PR_BODY"
reply_at=$(grep -n -- '--resource pullRequestThreadComments' "$AZ_CALL_LOG" | grep -- 'POST' | head -1 | cut -d: -f1)
close_at=$(grep -n -- '--resource pullRequestThreads ' "$AZ_CALL_LOG" | grep -- 'PATCH' | head -1 | cut -d: -f1)
if [ -z "$reply_at" ] || [ -z "$close_at" ] || [ "$reply_at" -ge "$close_at" ]; then
  note_fail "azure pr-thread-resolve — the comment POST must be logged before the thread PATCH: $(cat "$AZ_CALL_LOG")"
fi
[ "$(jq -c . "$AZ_INFILE_CAPTURE" 2>/dev/null)" = '{"status":"closed"}' ] \
  || note_fail "azure pr-thread-resolve — the PATCH does not close the thread: $(cat "$AZ_INFILE_CAPTURE")"

MERGE_BODY="$WORK/merge-body.md"; printf 'the body\n' > "$MERGE_BODY"
AZ_MSG_CAPTURE="$WORK/az-merge-msg.txt"; export AZ_MSG_CAPTURE; rm -f "$AZ_MSG_CAPTURE"
pr_case "azure pr-merge --squash --delete-branch --subject — completes with squash and branch deletion" 0 '' \
  "repos pr update --id 9 --status completed --squash true --delete-source-branch true" -- \
  pr-merge 9 --delete-branch --squash --subject s --body-file "$MERGE_BODY"
grep -q -- '--auto-complete' "$AZ_CALL_LOG" && note_fail "azure pr-merge — set auto-complete: $(cat "$AZ_CALL_LOG")"
[ "$(cat "$AZ_MSG_CAPTURE" 2>/dev/null)" = "$(printf 's\n\nthe body')" ] \
  || note_fail "azure pr-merge — the message is not '<subject>, blank line, body': $(cat "$AZ_MSG_CAPTURE" 2>/dev/null)"
unset AZ_MSG_CAPTURE
pr_case "azure pr-merge — a flag outside the four is exit 2, no az call" 2 - EMPTY -- pr-merge 9 --admin

export AZ_REF_JSON='[{"name":"refs/heads/feature/xy","objectId":"111"}]'
pr_case "azure branch-delete — no exact ref is gone, and no delete call" 0 gone "repos ref list" -- branch-delete feature/x
grep -q 'repos ref delete' "$AZ_CALL_LOG" && note_fail "azure branch-delete — deleted with no ref: $(cat "$AZ_CALL_LOG")"
export AZ_REF_JSON='[{"name":"refs/heads/feature/x","objectId":"abc"},{"name":"refs/heads/feature/xy","objectId":"111"}]'
pr_case "azure branch-delete — deletes the exact ref by its objectId, ok" 0 ok \
  "repos ref delete --name heads/feature/x --object-id abc" -- branch-delete feature/x
unset AZ_REF_JSON

export AZ_WI_SHOW_JSON='{"id":5,"relations":[{"rel":"System.LinkTypes.Related","url":"https://dev.azure.com/acme/_apis/wit/workItems/99"},{"rel":"System.LinkTypes.Hierarchy-Reverse","url":"https://dev.azure.com/acme/_apis/wit/workItems/40"}]}'
pr_case "azure issue-parent — the Hierarchy-Reverse id" 0 40 "boards work-item show --id 5" -- issue-parent 5
grep -Fq -- "--expand relations" "$AZ_CALL_LOG" || note_fail "azure issue-parent — no --expand relations: $(cat "$AZ_CALL_LOG")"
unset AZ_WI_SHOW_JSON
pr_case "azure issue-parent — no parent relation is none" 0 none - -- issue-parent 5
export AZ_PR_WI_JSON='[{"id":"12","url":"https://dev.azure.com/acme/_apis/wit/workItems/12"},{"id":"13","url":"x"}]'
pr_case "azure pr-closing-issues — the linked work items' ids" 0 '[12,13]' "repos pr work-item list --id 9" -- pr-closing-issues 9
unset AZ_PR_WI_JSON
pr_case "azure pr-comment — POST a closed one-comment thread from the file" 0 '' "pullRequestThreads" -- \
  pr-comment 9 --body-file "$PR_BODY"
[ "$(jq -c '[.status, (.comments|length), .comments[0].content]' "$AZ_INFILE_CAPTURE" 2>/dev/null)" = '["closed",1,"Closes #7\n"]' ] \
  || note_fail "azure pr-comment — wrong thread body: $(cat "$AZ_INFILE_CAPTURE")"
unset AZ_INFILE_CAPTURE

for refusal in "pr-thread-resolve 9 1 --body-file $PR_EMPTY" "pr-thread-resolve 9 1" \
               "pr-comment 9 --body-file $PR_EMPTY" "pr-comment 9 --body-file $WORK/no-such-file" \
               "pr-merge 9 --squash --body-file $PR_EMPTY"; do
  # shellcheck disable=SC2086  # word-split on purpose: each entry is one argv
  pr_case "azure ${refusal%% *} — refuses a missing or empty --body-file, exit 2, no az call" 2 - EMPTY -- $refusal
done
for dry in "pr-merge 9 --squash --delete-branch --subject s --dry-run" \
           "pr-thread-resolve 9 1 --body-file $PR_BODY --dry-run" \
           "pr-comment 9 --body-file $PR_BODY --dry-run" "branch-delete feature/x --dry-run"; do
  # shellcheck disable=SC2086
  pr_case "azure ${dry%% *} --dry-run — no az call" 0 - EMPTY -- $dry
  if [ "$(printf '%s\n' "$OUT" | grep -c '^DRY-RUN ')" != 1 ] || [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" != 1 ]; then
    note_fail "azure ${dry%% *} --dry-run — expected exactly one DRY-RUN line, got: $OUT"
  fi
done

export AZ_PR_JSON='{"pullRequestId":51,"status":"completed","closedDate":"2026-11-11T10:00:00Z","lastMergeCommit":{"commitId":"sq123"},"repository":{"name":"widgets","project":{"name":"Shop"}}}'
pr_case "azure pr-view — mergedAt from closedDate, mergeSha from lastMergeCommit" 0 - - -- pr-view 51
[ "$(printf '%s' "$OUT" | jq -c '[.state, .mergedAt, .mergeSha]' 2>/dev/null)" = '["merged","2026-11-11T10:00:00Z","sq123"]' ] \
  || note_fail "azure pr-view — merged fields wrong: $OUT"
unset AZ_PR_JSON

out=$(cd "$AZFIX" && PATH="$WORK/bin:$PATH" "$TRACKER" state merge-pr 2>/dev/null | "$DECIDE" tracker.capable 2>&1)
if [ "$out" = capable ]; then
  ok "azure state merge-pr — capable once the ten merge verbs land"
else
  note_fail "azure state merge-pr — expected 'capable', got '$out'"
fi
out=$(cd "$AZFIX" && PATH="$WORK/bin:$PATH" "$TRACKER" state implement-issue 2>/dev/null | "$DECIDE" tracker.capable 2>&1)
[ "$out" = capable ] || note_fail "azure state implement-issue — expected 'capable' still, got '$out'"

echo "== F4. the auto-dev verbs on Azure DevOps (#753)"

PR_TRACKER=azure-devops; PR_DIR="$AZFIX"; PR_LOG="$AZ_CALL_LOG"
export AZ_QUERY_JSON='[{"id":31},{"id":32}]'
export AZ_STATE_JSON='{"value":[{"id":20,"fields":{"System.State":"Active"}},{"id":40,"fields":{"System.State":"Done"}},{"id":41,"fields":{"System.State":"Closed"}}]}'
export AZ_BATCH_JSON='{"count":2,"value":[{"id":32,"fields":{"System.Title":"t32"}},{"id":31,"fields":{"System.Title":"t31","System.Tags":"effort: small; area: skills","System.Description":"<p>b</p><div>- [ ] a &amp; b</div><div>**Blocked by:** #20</div>","System.CreatedDate":"2026-11-01T00:00:00Z","System.AssignedTo":{"uniqueName":"ann@acme.example"}},"relations":[{"rel":"System.LinkTypes.Dependency-Reverse","url":"https://dev.azure.com/acme/_apis/wit/workItems/20"},{"rel":"System.LinkTypes.Dependency-Forward","url":"https://dev.azure.com/acme/_apis/wit/workItems/40"},{"rel":"System.LinkTypes.Hierarchy-Forward","url":"https://dev.azure.com/acme/_apis/wit/workItems/41"},{"rel":"System.LinkTypes.Related","url":"https://dev.azure.com/acme/_apis/wit/workItems/42"}]}]}'
pr_case "azure issue-list — open WIQL, then one workitemsbatch POST" 0 - "--resource workitemsbatch" -- issue-list --state open --limit 10
grep -q "NOT IN ('Closed','Done','Removed')" "$AZ_CALL_LOG" || note_fail "azure issue-list — the WIQL is not the open set: $(cat "$AZ_CALL_LOG")"
want='{"number":31,"title":"t31","labels":["effort: small","area: skills"],"body":"b\n- [ ] a & b\n**Blocked by:** #20","comments":null,"createdAt":"2026-11-01T00:00:00Z","blockedBy":{"nodes":[{"number":20,"state":"open"}],"totalCount":1},"blocking":{"nodes":[{"number":40,"state":"closed"}],"totalCount":1},"subIssues":{"nodes":[{"number":41,"state":"closed"}],"totalCount":1},"assignees":["ann@acme.example"]}'
got=$(printf '%s' "$OUT" | jq -c '.[0]' 2>/dev/null)
[ "$got" = "$want" ] && ok "azure issue-list — tags split, AssignedTo, Dependency and Hierarchy relations as edges" \
  || note_fail "azure issue-list — wrong row
      want: $want
      got:  $got"
[ "$(printf '%s' "$OUT" | jq -c '.[1] | [.number, .labels, .assignees, .blockedBy.totalCount]')" = '[32,[],[],0]' ] \
  && ok "azure issue-list — rows in id order, an untagged item has empty labels" || note_fail "azure issue-list — second row: $OUT"
# #811: a predecessor the read cannot answer for holds the row, never reads as closed.
export AZ_STATE_JSON='{"value":[{"id":20,"fields":{"System.State":"Active"}},null,{"id":41,"fields":{"System.State":"Closed"}}]}'
pr_case "azure issue-list — an unresolvable edge holds its row" 0 - - -- issue-list --state open --limit 10
[ "$(printf '%s' "$OUT" | jq -c 'map(.number)')" = '[32]' ] && ok "azure issue-list — the row with an unresolved edge is held" \
  || note_fail "azure issue-list — unresolved edge not held: $OUT"
unset AZ_BATCH_JSON AZ_STATE_JSON

export AZ_QUERY_JSON
AZ_QUERY_JSON=$(jq -nc '[range(1; 202) | {id: .}]')
export AZ_BATCH_SIZES="$WORK/az-batch-sizes"
: > "$AZ_BATCH_SIZES"
pr_case "azure issue-list — 201 open ids" 0 - - -- issue-list --state open
[ "$(tr '\n' ' ' < "$AZ_BATCH_SIZES")" = "200 1 " ] && ok "azure issue-list — 201 ids make two batch POSTs, of 200 and 1" \
  || note_fail "azure issue-list — batch sizes: $(tr '\n' ' ' < "$AZ_BATCH_SIZES")"
[ "$(printf '%s' "$OUT" | jq length)" = 201 ] || note_fail "azure issue-list — expected 201 rows"
unset AZ_BATCH_SIZES
export AZ_BATCH_FAIL=1
pr_case "azure issue-list — a failing batch exits 1 with empty stdout" 1 '' - -- issue-list --state open
unset AZ_BATCH_FAIL AZ_QUERY_JSON

export AZ_WORKITEM_JSON='{"id":9,"fields":{"System.AssignedTo":{"uniqueName":"ann@acme.example"}}}'
pr_case "azure issue-assign — an assigned item is already-assigned, no PATCH" 0 already-assigned - -- issue-assign 9
grep -q -- '--http-method PATCH' "$AZ_CALL_LOG" && note_fail "azure issue-assign — patched an assigned item: $(cat "$AZ_CALL_LOG")"
export AZ_WORKITEM_JSON='{"id":9,"fields":{}}'
export AZ_INFILE_CAPTURE="$WORK/az-assign-infile.json"
rm -f "$AZ_INFILE_CAPTURE"
pr_case "azure issue-assign — unassigned: a PATCH, prints ok" 0 ok "--http-method PATCH" -- issue-assign 9
[ "$(jq -c '.[0] | [.op, .path, .value]' "$AZ_INFILE_CAPTURE" 2>/dev/null)" = '["add","/fields/System.AssignedTo","me@acme.example"]' ] \
  && ok "azure issue-assign — the in-file adds /fields/System.AssignedTo as the az account user" \
  || note_fail "azure issue-assign — in-file: $(cat "$AZ_INFILE_CAPTURE" 2>/dev/null)"
unset AZ_WORKITEM_JSON AZ_INFILE_CAPTURE
pr_case "azure issue-assign --dry-run — no az call" 0 - EMPTY -- issue-assign 9 --dry-run
[ "$(printf '%s\n' "$OUT" | grep -c '^DRY-RUN ')" = 1 ] || note_fail "azure issue-assign --dry-run — got: $OUT"

out=$(cd "$AZFIX" && PATH="$WORK/bin:$PATH" "$TRACKER" state auto-dev 2>/dev/null | "$DECIDE" tracker.capable 2>&1)
[ "$out" = capable ] && ok "azure state auto-dev — capable once issue-list and issue-assign land" \
  || note_fail "azure state auto-dev — expected 'capable', got '$out'"

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "tracker: FAILED"
  exit 1
fi
echo
echo "tracker: OK — verbs route to a per-host backend, and an absent one is named rather than guessed."
