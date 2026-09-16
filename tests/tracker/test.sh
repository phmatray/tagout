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
    404) msg="Not Found" ;;
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
    "issue list")   payload='[{"number":12,"title":"A stub closed issue","state":"CLOSED"}]' ;;
    "issue create") echo "https://example.invalid/o/r/issues/42"; exit 0 ;;
    "issue edit")   exit 0 ;;
    "issue reopen") exit 0 ;;
    "issue comment") exit 0 ;;
    "label list")   payload='[{"name":"bug"},{"name":"area: skills"}]' ;;
    "label create") exit 0 ;;
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

run_tracker "$PROFILED" --tracker gitlab repo
if [ "$RC" -ne 3 ]; then
  note_fail "AC3b missing backend — expected exit 3, got $RC ('$OUT')"
elif ! printf '%s\n%s\n' "$OUT" "$ERR" | grep -Fq 'NOT_IMPLEMENTED gitlab repo'; then
  note_fail "AC3b missing backend — exit 3 but no 'NOT_IMPLEMENTED gitlab repo'
      stdout: $OUT
      stderr: $ERR"
else
  ok "AC3b missing backend — exit 3, NOT_IMPLEMENTED gitlab repo"
fi

# A verb the contract declares but the RESOLVED backend does not implement is also exit 3, and that
# is a different cause from "no backend file at all" — both must land on 3 rather than one of them
# reading as a bad invocation.
run_tracker "$PROFILED" --tracker github verbs
if [ "$RC" -ne 0 ]; then
  note_fail "verbs — the backend protocol verb exited $RC ($ERR)"
elif ! printf '%s\n' "$OUT" | grep -Fqx 'issue-view'; then
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
elif ! printf '%s' "$ERR" | grep -q 'not a database id'; then
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

echo "== B. the state report, and the tracker.capable verdict"

# The report itself: five facts, judging none of them. `needs` is null because no skill is on the
# contract yet, and that is a different absence from `implements` being null — the decision below is
# what tells them apart, which is only possible if the report keeps them distinct.
run_tracker "$PROFILED" state merge-pr
if [ "$RC" -ne 0 ]; then
  note_fail "state — exited $RC ($ERR)"
else
  got=$(printf '%s' "$OUT" | jq -r '[.tracker, .skill, (.needs|tostring), (.implements|length|tostring)] | join("|")' 2>/dev/null) \
    || got="<unparseable: $OUT>"
  if [ "$got" != 'github|merge-pr|null|18' ]; then
    note_fail "state — wrong report
      want: github|merge-pr|null|18
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

capable gitlab-no-backend.json unsupported/no-backend \
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
    printf '%s\n' "$table" | grep -Fxq "$v" || echo "gap: $v not on contract.json's verb table"
    printf '%s\n' "$needs" | grep -Fxq "$v" || echo "gap: $v not on skills.$skill"
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
elif ! printf '%s\n' "$fixture_out" | grep -Fq 'issue-frobnicate'; then
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
elif ! printf '%s\n' "$fixture_gh_out" | grep -Fq 'wire-edges.sh'; then
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

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "tracker: FAILED"
  exit 1
fi
echo
echo "tracker: OK — verbs route to a per-host backend, and an absent one is named rather than guessed."
