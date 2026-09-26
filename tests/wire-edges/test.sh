#!/usr/bin/env bash
# Golden test for skills/create-issue/scripts/wire-edges.sh (#315).
#
# The script wires the edges of a decomposed issue on GitHub — each child as a sub-issue of the
# parent, each child's blockers as native `blocked_by` dependencies — and degrades to the text
# lines the bodies already carry when either feature is unavailable. What the suite pins is the
# CONTRACT the create-issue and triage-backlog skills read, at the only seam that matters: the
# script's stdout and exit code through a stubbed `gh` on PATH. Never a sourced function, never
# the id-lookup internals — see skills/_shared/test-seams.md.
#
#   one line per edge:   SUB <parent>←<child> ok|fallback|FAILED …
#                        DEP <child>⇐<blocker> ok|fallback|FAILED …
#   exit 0               every edge ok or fallback (404 = the feature is off on this host)
#   exit 1               any other non-2xx, or an issue whose database id cannot be resolved
#   exit 2               usage — the caller's arguments, not GitHub, are wrong
#   --dry-run            prints the POSTs it would send and makes no API call
#
# The 404 rule is the load-bearing one: sub-issues and dependencies are GA on github.com but may
# 404 on GHES, and a run that treats that as failure leaves every decomposition half-wired with a
# red exit nobody can act on. The text `**Blocked by:**` line is always written by the skill, so
# fallback loses nothing on the body; it only loses the UI-visible frontier.
set -euo pipefail
# A GH_HOST in the developer's or CI's shell would decide the host cases (#514) on its own.
unset GH_HOST
cd "$(dirname "$0")/../.."

SCRIPT="skills/create-issue/scripts/wire-edges.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing"; exit 1; }
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT is not executable"; exit 1; }

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
WORK=$(kit_scratch)
mkdir -p "$WORK/bin"

# ------------------------------------------------------------------------------------ the gh stub
#
# Every invocation is appended to $GH_CALL_LOG, which is how the suite proves --dry-run and a usage
# refusal call nothing. Database ids are 1000 + the issue number, so an assertion can name the id
# it expects in the POST form field and catch a script that posted the issue NUMBER instead — the
# exact mistake the real API rejects with a 404 that would then read as "feature off".
#
# Status per endpoint comes from the environment, the way real gh reports it: a non-2xx prints
# `gh: <message> (HTTP <code>)` on stderr and exits 1, with the JSON body on stdout unless --silent.
#   GH_ISSUE_STATUS   for `gh api repos/o/r/issues/N` (the id lookup)        default 200
#   GH_SUB_STATUS     for POST …/issues/P/sub_issues                        default 201
#   GH_DEP_STATUS     for POST …/issues/C/dependencies/blocked_by           default 201
#   GH_422_MESSAGE    the message a 422 carries                              default "Validation Failed"
#   GH_ISSUE_404_FOR  one issue NUMBER whose id lookup alone answers 404 (the others succeed)
#   GH_PLAIN_ERROR    when set, a non-2xx prints the bare `gh: HTTP <code>` form real gh uses
#                     when the error body is not JSON (a proxy's HTML page), with no message
#
# Each log line carries the GH_HOST the call ran under (#514). `gh auth token --hostname H`, the
# host helper's credential probe, succeeds only for a host listed in $GH_STUB_HOSTS.
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "GH_HOST=${GH_HOST-<unset>} ARGS: $*" >> "$GH_CALL_LOG"
if [ "${1:-}" = auth ] && [ "${2:-}" = token ]; then
  host=""; prev=""
  for a in "$@"; do [ "$prev" = "--hostname" ] && host="$a"; prev="$a"; done
  case " ${GH_STUB_HOSTS:-} " in *" $host "*) echo "gho_stub_token_for_$host"; exit 0 ;; esac
  exit 1
fi
method=GET; endpoint=""; prev=""
for a in "$@"; do
  case "$prev" in
    --method|-X) method="$a" ;;
  esac
  case "$a" in
    repos/*) endpoint="$a" ;;
  esac
  prev="$a"
done
fail() {
  local code="$1" msg
  case "$code" in
    404) msg="Not Found" ;;
    422) msg="${GH_422_MESSAGE:-Validation Failed}" ;;
    *)   msg="Server Error" ;;
  esac
  if [ -n "${GH_PLAIN_ERROR:-}" ]; then
    echo "gh: HTTP $code" >&2
    exit 1
  fi
  printf '{"message":"%s","status":"%s"}' "$msg" "$code"
  echo "gh: $msg (HTTP $code)" >&2
  exit 1
}
if [ "$method" = POST ]; then
  case "$endpoint" in
    */sub_issues)             s="${GH_SUB_STATUS:-201}" ;;
    */dependencies/blocked_by) s="${GH_DEP_STATUS:-201}" ;;
    *) echo "unexpected POST endpoint: $endpoint" >&2; exit 99 ;;
  esac
  case "$s" in 2??) exit 0 ;; *) fail "$s" ;; esac
fi
case "$endpoint" in
  repos/*/issues/[0-9]*)
    s="${GH_ISSUE_STATUS:-200}"
    n="${endpoint##*/issues/}"
    [ "${GH_ISSUE_404_FOR:-}" = "$n" ] && s=404
    case "$s" in 2??) ;; *) fail "$s" ;; esac
    echo $((1000 + n))
    exit 0 ;;
esac
echo "unexpected gh invocation: $*" >&2
exit 99
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

fails=0
case_n=0

# run_case <label> → runs the script with the remaining args; leaves $OUT, $ERR, $RC, $GH_CALL_LOG
run_case() {
  local label="$1"; shift
  case_n=$((case_n + 1))
  GH_CALL_LOG="$WORK/calls.$case_n.log"; export GH_CALL_LOG
  : > "$GH_CALL_LOG"
  OUT="$WORK/out.$case_n"; ERR="$WORK/err.$case_n"
  set +e
  "$SCRIPT" "$@" > "$OUT" 2> "$ERR"
  RC=$?
  set -e
  CASE="$label"
}

expect_rc() {
  if [ "$RC" -ne "$1" ]; then
    echo "FAIL: [$CASE] expected exit $1, got $RC"; echo "--- stdout"; cat "$OUT"; echo "--- stderr"; cat "$ERR"
    fails=$((fails + 1)); return 1
  fi
}
expect_line() {   # a stdout line matching the regex must exist
  if ! grep -qE "$1" "$OUT"; then
    echo "FAIL: [$CASE] stdout lacks a line matching /$1/"; echo "--- stdout"; cat "$OUT"; echo "--- stderr"; cat "$ERR"
    fails=$((fails + 1)); return 1
  fi
}
expect_no_line() {
  if grep -qE "$1" "$OUT"; then
    echo "FAIL: [$CASE] stdout has a line matching /$1/ that must not be there"; echo "--- stdout"; cat "$OUT"
    fails=$((fails + 1)); return 1
  fi
}
expect_call() {   # a recorded gh invocation matching the regex must exist
  if ! grep -qE "$1" "$GH_CALL_LOG"; then
    echo "FAIL: [$CASE] no gh call matching /$1/"; echo "--- calls"; cat "$GH_CALL_LOG"
    fails=$((fails + 1)); return 1
  fi
}
expect_no_calls() {
  if [ -s "$GH_CALL_LOG" ]; then
    echo "FAIL: [$CASE] gh was called, and must not have been:"; cat "$GH_CALL_LOG"
    fails=$((fails + 1)); return 1
  fi
}
ok() { echo "ok   [$CASE] $1"; }

# ----------------------------------------------------------------- 1. every endpoint answers 2xx
run_case "all-2xx" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11 --child 13:blocked-by=11,12
expect_rc 0 \
  && expect_line '^SUB 10←11 ok' && expect_line '^SUB 10←12 ok' && expect_line '^SUB 10←13 ok' \
  && expect_line '^DEP 12⇐11 ok' && expect_line '^DEP 13⇐11 ok' && expect_line '^DEP 13⇐12 ok' \
  && expect_no_line '^(SUB|DEP) .* (fallback|FAILED)' \
  && ok "three sub-issue edges and three blocked_by edges, all ok, exit 0"

# The POSTs carry DATABASE ids (1000+n), the github+json Accept header, and go to the right issue:
# the sub-issue is posted ON THE PARENT, the dependency ON THE CHILD.
expect_call 'POST.*repos/o/r/issues/10/sub_issues.*sub_issue_id=1011' \
  && expect_call 'POST.*repos/o/r/issues/13/dependencies/blocked_by.*issue_id=1012' \
  && expect_call 'Accept: application/vnd.github\+json' \
  && ok "POSTs name the parent/child endpoints with database ids, not issue numbers"

# A dependency is never posted the wrong way round (blocker's endpoint with the child's id).
if grep -qE 'POST.*issues/11/dependencies/blocked_by' "$GH_CALL_LOG"; then
  echo "FAIL: [$CASE] a blocked_by was posted on the BLOCKER (#11), which has no blockers"; fails=$((fails + 1))
else
  ok "no edge posted on an issue that has no blockers"
fi

# An id is looked up once per issue, not once per edge — four issues, four lookups.
lookups=$(grep -cE 'ARGS: api .*repos/o/r/issues/[0-9]+ ' "$GH_CALL_LOG" || true)
if [ "$lookups" -ne 4 ]; then
  echo "FAIL: [$CASE] expected 4 id lookups (one per issue), counted $lookups"; cat "$GH_CALL_LOG"; fails=$((fails + 1))
else
  ok "each issue's database id is resolved exactly once"
fi

# --tracker <name> on wire-edges.sh's own CLI pins the backend outright (#603) — resolve_tracker()
# short-circuits on it instead of re-reading the profile — and produces the identical SUB line the
# flag-less equivalent above does.
run_case "explicit-tracker" --tracker github --repo o/r --parent 10 --child 11
expect_rc 0 && expect_line '^SUB 10←11 ok' \
  && ok "--tracker github explicit on the CLI produces the same SUB line as the flag-less run"

# ----------------------------------------------------- 2. sub-issues endpoint is off (404) → fallback
GH_SUB_STATUS=404 run_case "sub-issues-404" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 0 \
  && expect_line '^SUB 10←11 fallback' && expect_line '^SUB 10←12 fallback' \
  && expect_line '^DEP 12⇐11 ok' \
  && ok "404 on sub_issues prints fallback, dependencies still wire, exit 0"

# ------------------------------------------------- 3. dependencies endpoint is off (404) → fallback
GH_DEP_STATUS=404 run_case "dependencies-404" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 0 \
  && expect_line '^SUB 10←11 ok' && expect_line '^SUB 10←12 ok' \
  && expect_line '^DEP 12⇐11 fallback' \
  && ok "404 on dependencies prints fallback, sub-issues still wire, exit 0"

# ----------------------------------------------------------- 4. any other non-2xx → FAILED, exit 1
GH_DEP_STATUS=500 run_case "dependencies-500" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 1 \
  && expect_line '^SUB 10←11 ok' \
  && expect_line '^DEP 12⇐11 FAILED.*HTTP 500' \
  && ok "a 500 is FAILED with the status quoted, exit 1 — never read as fallback"

# Two children: the script keeps going after a FAILED edge and still reports every edge, and
# the summary line counts them — a script that exits on the first failure would report one.
GH_SUB_STATUS=503 run_case "sub-issues-503" --repo o/r --parent 10 --child 11 --child 12
expect_rc 1 && expect_line '^SUB 10←11 FAILED.*HTTP 503' && expect_line '^SUB 10←12 FAILED.*HTTP 503' \
  && expect_line '^wire-edges: 2 edge\(s\) — 0 ok, 0 fallback, 2 failed' \
  && ok "a 503 on sub_issues is FAILED too, every edge is still reported, exit 1"

# The bare `gh: HTTP <code>` form (non-JSON error body) is still a status: 404 → fallback, 500 → FAILED.
GH_PLAIN_ERROR=1 GH_DEP_STATUS=404 run_case "plain-404" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 0 && expect_line '^DEP 12⇐11 fallback' \
  && ok "a bare 'gh: HTTP 404' (no JSON body) still reads as fallback"
GH_PLAIN_ERROR=1 GH_DEP_STATUS=500 run_case "plain-500" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 1 && expect_line '^DEP 12⇐11 FAILED.*HTTP 500' \
  && ok "a bare 'gh: HTTP 500' is FAILED with the status quoted"

# ------------------------------------------------- 5. 422 "already exists" → ok (idempotent re-run)
# The two messages are the ones github.com actually returned on a second run (measured 2026-08-31
# against phmatray/tagout, throwaway issues #346–#348): the sub-issue one says
# "duplicate", the dependency one says "already been taken". Neither says "exists".
GH_SUB_STATUS=422 GH_DEP_STATUS=422 \
  GH_422_MESSAGE="An error occurred while adding the sub-issue to the parent issue. Issue may not contain duplicate sub-issues and Sub issue may only have one parent" \
  run_case "422-duplicate-sub-issue" --repo o/r --parent 10 --child 11
expect_rc 0 && expect_line '^SUB 10←11 ok' \
  && ok "the live duplicate-sub-issue 422 is ok — re-running the wiring is safe"

GH_DEP_STATUS=422 \
  GH_422_MESSAGE="An error occurred while adding the blocking issue to the issue. Validation failed: Target issue has already been taken" \
  run_case "422-already-blocked" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 0 && expect_line '^SUB 10←11 ok' && expect_line '^DEP 12⇐11 ok' \
  && ok "the live already-taken dependency 422 is ok — re-running the wiring is safe"

# A 422 that is NOT an already-exists (a cycle, a cross-repo refusal) is a real failure.
GH_DEP_STATUS=422 GH_422_MESSAGE="Validation Failed: would create a cycle" \
  run_case "422-other" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 1 && expect_line '^DEP 12⇐11 FAILED.*HTTP 422' \
  && ok "any other 422 is FAILED, exit 1"

# --------------------------------------------------------- 6. an issue whose id cannot be resolved
GH_ISSUE_STATUS=404 run_case "id-lookup-404" --repo o/r --parent 10 --child 11
expect_rc 1 || true
if grep -qE 'POST' "$GH_CALL_LOG"; then
  echo "FAIL: [$CASE] a POST was sent although an id lookup failed"; cat "$GH_CALL_LOG"; fails=$((fails + 1))
else
  ok "an unresolvable issue id stops before any POST, exit 1"
fi

# Only the LAST issue's lookup fails: a script that resolved ids lazily between POSTs would have
# posted the parent←11 edge before discovering #12 — the header promises every id is resolved
# before the first write.
GH_ISSUE_404_FOR=12 run_case "id-lookup-404-late" --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 1 || true
if grep -qE 'POST' "$GH_CALL_LOG"; then
  echo "FAIL: [$CASE] a POST was sent before every id was resolved"; cat "$GH_CALL_LOG"; fails=$((fails + 1))
else
  ok "ids are all resolved before the first POST — a late lookup failure posts nothing"
fi

# ------------------------------------------------------------------------- 7. usage errors → exit 2
run_case "no-parent-with-blocker" --repo o/r --child 7:blocked-by=3
expect_rc 0 && expect_no_line '^SUB ' \
  && expect_line '^DEP 7⇐3 ok' \
  && expect_call 'POST.*repos/o/r/issues/7/dependencies/blocked_by.*issue_id=1003' \
  && ok "AC1: a parent-less --child 7:blocked-by=3 prints one DEP 7⇐3 ok, no SUB, exits 0, POSTs issue_id=1003"

run_case "no-parent-no-blocker" --repo o/r --child 7
expect_rc 2 && expect_no_calls && ok "AC2: a parent-less bare --child 7 exits 2 and calls nothing"

run_case "no-parent-dry-run" --dry-run --repo o/r --child 7:blocked-by=3
expect_rc 0 && expect_no_calls \
  && expect_line '^DRY-RUN POST repos/o/r/issues/7/dependencies/blocked_by' \
  && expect_no_line '/sub_issues' \
  && ok "a parent-less --dry-run prints only DEP POSTs, no sub_issues POST"

run_case "no-repo" --parent 10 --child 11
expect_rc 2 && expect_no_calls && ok "missing --repo is exit 2 and calls nothing"

run_case "no-child" --repo o/r --parent 10
expect_rc 2 && expect_no_calls && ok "no --child at all is exit 2 and calls nothing"

run_case "bad-child-spec" --repo o/r --parent 10 --child 11:blocked-by=eleven
expect_rc 2 && expect_no_calls && ok "a non-numeric blocker is exit 2 and calls nothing"

run_case "child-is-parent" --repo o/r --parent 10 --child 10
expect_rc 2 && expect_no_calls && ok "a child equal to the parent is exit 2 and calls nothing"

run_case "self-blocked" --repo o/r --parent 10 --child 11:blocked-by=11
expect_rc 2 && expect_no_calls && ok "a child blocked by itself is exit 2 and calls nothing"

run_case "blocked-by-parent" --repo o/r --parent 10 --child 11:blocked-by=10
expect_rc 2 && expect_no_calls && ok "a child blocked by the parent is exit 2 and calls nothing"

run_case "empty-blocker" --repo o/r --parent 10 --child 12:blocked-by=,11
expect_rc 2 && expect_no_calls && ok "an empty entry in the blocker list is exit 2 and calls nothing"

run_case "bare-blocked-by" --repo o/r --parent 10 --child 12:blocked-by=
expect_rc 2 && expect_no_calls && ok "a bare blocked-by= is exit 2 and calls nothing"

run_case "unknown-flag" --repo o/r --parent 10 --child 11 --bogus
expect_rc 2 && expect_no_calls && ok "an unknown flag is exit 2 and calls nothing"

# ----------------------------------------------------------------- 8. --dry-run prints, calls nothing
run_case "dry-run" --dry-run --repo o/r --parent 10 --child 11 --child 12:blocked-by=11
expect_rc 0 && expect_no_calls \
  && expect_line 'POST repos/o/r/issues/10/sub_issues' \
  && expect_line 'POST repos/o/r/issues/12/dependencies/blocked_by' \
  && expect_no_line '^(SUB|DEP) .* (ok|fallback|FAILED)' \
  && ok "--dry-run prints the POSTs it would send and never invokes gh"

# ------------------------------------------------------------ 9. the repository's own host (#514)
#
# `gh api` never infers a host, so on a GitHub Enterprise repository the id lookups and every POST
# reached github.com. The seam is the stub's log: the GH_HOST each call ran under, and its endpoint.
expect_stderr_contains() {
  if ! grep -qF -- "$1" "$ERR"; then
    echo "FAIL: [$CASE] stderr lacks: $1"; echo "--- stderr"; cat "$ERR"
    fails=$((fails + 1)); return 1
  fi
}
expect_all_hosted() {   # no API call ran without GH_HOST=ghe.example.com
  if grep -qE '^GH_HOST=<unset> ARGS: api ' "$GH_CALL_LOG"; then
    echo "FAIL: [$CASE] an API call ran without the host:"; cat "$GH_CALL_LOG"
    fails=$((fails + 1)); return 1
  fi
}

# A checkout whose origin is on a GHE host, run by the script's absolute path from inside it. Two
# children, one blocked by the other, so BOTH POST endpoints — sub_issues and blocked_by — are made.
CO_GHE="$WORK/co-ghe"
git init -q "$CO_GHE"
git -C "$CO_GHE" remote add origin git@ghe.example.com:acme/widgets.git
SCRIPT_KEEP="$SCRIPT"; SCRIPT="$KIT_ROOT/$SCRIPT_KEEP"
cd "$CO_GHE"
GH_STUB_HOSTS=ghe.example.com run_case "ghe-origin" --repo acme/widgets --parent 1 --child 2 --child 3:blocked-by=2
cd "$KIT_ROOT"
SCRIPT="$SCRIPT_KEEP"
expect_rc 0 \
  && expect_line '^SUB 1←2 ok' && expect_line '^SUB 1←3 ok' && expect_line '^DEP 3⇐2 ok' \
  && expect_call '^GH_HOST=ghe\.example\.com ARGS: api .*repos/acme/widgets/issues/1 --jq \.id$' \
  && expect_call '^GH_HOST=ghe\.example\.com ARGS: api .*--method POST --silent repos/acme/widgets/issues/1/sub_issues -F sub_issue_id=1002$' \
  && expect_call '^GH_HOST=ghe\.example\.com ARGS: api .*--method POST --silent repos/acme/widgets/issues/3/dependencies/blocked_by -F issue_id=1002$' \
  && expect_all_hosted \
  && ok "a GHE checkout: the id lookups and both POST endpoints ran under GH_HOST=ghe.example.com"

# A HOST/ prefix names the host outright — even from this checkout, whose origin is github.com —
# and the endpoints get OWNER/REPO, never the prefixed slug.
run_case "ghe-prefix" --repo ghe.example.com/acme/widgets --parent 1 --child 2
expect_rc 0 && expect_line '^SUB 1←2 ok' \
  && expect_call '^GH_HOST=ghe\.example\.com ARGS: api .*repos/acme/widgets/issues/2 --jq \.id$' \
  && expect_call '^GH_HOST=ghe\.example\.com ARGS: api .*--method POST --silent repos/acme/widgets/issues/1/sub_issues -F sub_issue_id=1002$' \
  && expect_all_hosted \
  && ok "--repo HOST/OWNER/REPO: every call got repos/acme/widgets/… under GH_HOST=ghe.example.com"
if grep -qF 'repos/ghe.example.com' "$GH_CALL_LOG"; then
  echo "FAIL: [$CASE] the host leaked into an endpoint:"; cat "$GH_CALL_LOG"; fails=$((fails + 1))
fi

# The dry run prints the endpoints the real run would use — the prefix stripped — and a prefix
# resolves without asking gh anything.
run_case "dry-run-ghe-prefix" --dry-run --repo ghe.example.com/acme/widgets --parent 1 --child 2 --child 3:blocked-by=2
expect_rc 0 && expect_no_calls \
  && expect_line 'POST repos/acme/widgets/issues/1/sub_issues' \
  && expect_line 'POST repos/acme/widgets/issues/3/dependencies/blocked_by' \
  && expect_no_line 'repos/ghe\.example\.com' \
  && ok "--dry-run with HOST/OWNER/REPO prints repos/acme/widgets/… and calls nothing"

# Guard: from a GHE checkout the dry run still makes no API call. The one gh it may run is the host
# helper's `gh auth token`, a local credential lookup.
SCRIPT="$KIT_ROOT/$SCRIPT_KEEP"
cd "$CO_GHE"
GH_STUB_HOSTS=ghe.example.com run_case "dry-run-ghe-origin" --dry-run --repo acme/widgets --parent 1 --child 2
cd "$KIT_ROOT"
SCRIPT="$SCRIPT_KEEP"
expect_rc 0 && expect_line 'POST repos/acme/widgets/issues/1/sub_issues' \
  && ok "--dry-run from a GHE checkout prints the plan"
if grep -qvE '^GH_HOST=<unset> ARGS: auth token --hostname ghe\.example\.com$' "$GH_CALL_LOG"; then
  echo "FAIL: [$CASE] the dry run made a call other than the local credential lookup:"; cat "$GH_CALL_LOG"
  fails=$((fails + 1))
else
  ok "--dry-run from a GHE checkout makes no API call"
fi

# Four segments is no slug at all: the host helper refuses it, and gh is never called.
run_case "malformed-slug" --repo a/b/c/d --parent 1 --child 2
expect_rc 2 && expect_no_calls && expect_stderr_contains "malformed repository slug 'a/b/c/d'" \
  && ok "a four-segment --repo is exit 2, named on stderr, calls nothing"

# Admitting HOST/OWNER/REPO must not admit an empty segment with it.
run_case "empty-segment" --repo acme//widgets --parent 1 --child 2
expect_rc 2 && expect_no_calls && ok "a --repo with an empty segment is still exit 2, calls nothing"

# The host helper is part of the install: without it the wiring refuses, naming the missing file,
# rather than falling back to gh's default host — the exact #514 failure.
NOHELPER="$WORK/nohelper/skills/create-issue/scripts"
mkdir -p "$NOHELPER"
cp "$KIT_ROOT/$SCRIPT_KEEP" "$NOHELPER/wire-edges.sh"
chmod +x "$NOHELPER/wire-edges.sh"
SCRIPT="$NOHELPER/wire-edges.sh"
run_case "missing-helper" --repo o/r --parent 1 --child 2
SCRIPT="$SCRIPT_KEEP"
expect_rc 2 && expect_no_calls && expect_stderr_contains "_shared/scripts/_gh-host.sh; reinstall the kit" \
  && ok "without its host helper: exit 2, the missing file named, calls nothing"

# ------------------------------------------ 10. one home for the DRY-RUN format (#603, AC1)
#
# The DRY-RUN line used to be hand-formatted a second time in this script, duplicating the string
# scripts/tracker/github.sh's own issue-link-parent/issue-link-blocked-by --dry-run already prints.
case_n=$((case_n + 1)); CASE="dry-run-format"
if grep -qF 'DRY-RUN POST' "$KIT_ROOT/$SCRIPT_KEEP"; then
  echo "FAIL: [$CASE] $SCRIPT_KEEP still hand-formats a DRY-RUN line — should relay the verb's own"
  fails=$((fails + 1))
else
  ok "the DRY-RUN format has exactly one home (scripts/tracker/github.sh), not two"
fi

# ------------------------------------------------------------------------------------------ verdict
if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "wire-edges golden test: all cases behaved as specified"
