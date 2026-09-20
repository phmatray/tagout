#!/usr/bin/env bash
# Golden test for skills/merge-pr/scripts/parent-decision-note.sh (#365).
#
# When `merge-pr` squash-merges a decomposed child's PR, this script is the only thing that keeps
# the tracking parent's `## Decisions so far` section current — the overwhelming majority of merges
# aren't part of a decomposition (#315) at all, so the common case has to be a true no-op, and a
# re-run on an already-merged PR (`merge-pr` is resume-safe) must not duplicate the line it already
# wrote. The suite stubs `gh` (never a real issue, per this kit's testing rule — see
# skills/_shared/test-seams.md and the fixture/stub-only instruction this issue was worked under)
# and keeps a scratch FILE standing in for "the parent issue's body on GitHub", updated by the
# script's own `gh issue edit --body-file -` call and read back by the next `gh issue view`, so the
# suite exercises the real read-modify-write-readback cycle rather than a canned response per call.
set -euo pipefail
# A GH_HOST in the developer's or CI's shell would decide the host cases (#514) on its own.
unset GH_HOST
cd "$(dirname "$0")/../.."

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"

SCRIPT="$KIT_ROOT/skills/merge-pr/scripts/parent-decision-note.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT is missing or not executable"; exit 1; }

command -v jq > /dev/null 2>&1 || { echo "FAIL: jq is missing"; exit 1; }

WORK=$(kit_scratch)
mkdir -p "$WORK/bin"
STATE_BODY="$WORK/state-body.txt"

# ------------------------------------------------------------------------------------ the gh stub
#
# Routed on the NOUN/VERB and, for `issue view`, the requested --json fields — never on the issue
# number — because the script queries the CHILD (`--json parent`) and the PARENT (`--json body`)
# through the identically-shaped `gh issue view <n> -R <repo> --json <fields>` call.
#
#   GH_PARENT_JSON          raw JSON for `gh issue view <child> --json parent`  default {"parent":null}
#   GH_PARENT_MALFORMED=1   that call answers with non-JSON garbage instead
#   GH_PARENT_VIEW_STATUS   non-zero to make the parent-lookup call itself fail (gh exit code)
#   GH_BODY_VIEW_STATUS     non-zero to make every `--json body` read fail
#   GH_PR_JSON              raw JSON for `gh pr view <pr> --json title,url`     default {}
#   GH_PR_VIEW_STATUS       non-zero to make the PR lookup fail
#   GH_ISSUE_EDIT_STATUS    non-zero to make `gh issue edit --body-file -` fail
#
# `$STATE_BODY` is the fake GitHub: seeded by the test before each run, read by every
# `--json body` view, and overwritten by `gh issue edit`'s stdin. That is what lets the
# idempotent-rerun and second-child cases assert against what the FIRST call actually produced,
# not a hand-written expectation of it.
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

noun="${1:-}"; shift || true
case "$noun" in
  issue)
    verb="${1:-}"; shift || true
    case "$verb" in
      view)
        shift || true   # the issue number — routing never keys on it, see the header above
        fields=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --json) fields="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        case "$fields" in
          parent)
            [ "${GH_PARENT_VIEW_STATUS:-0}" = 0 ] || { echo "gh: simulated failure" >&2; exit "$GH_PARENT_VIEW_STATUS"; }
            if [ "${GH_PARENT_MALFORMED:-0}" = 1 ]; then
              echo 'not-json-at-all {{{'
              exit 0
            fi
            printf '%s\n' "${GH_PARENT_JSON:-NULL_PARENT}" | sed 's/^NULL_PARENT$/{"parent":null}/'
            exit 0 ;;
          body)
            [ "${GH_BODY_VIEW_STATUS:-0}" = 0 ] || { echo "gh: simulated failure" >&2; exit "$GH_BODY_VIEW_STATUS"; }
            body=$(cat "$STATE_BODY" 2>/dev/null || true)
            jq -n --arg b "$body" '{body: $b}'
            exit 0 ;;
          *) echo "unexpected --json fields for issue view: '$fields'" >&2; exit 99 ;;
        esac ;;
      edit)
        shift || true   # the issue number
        while [ $# -gt 0 ]; do
          case "$1" in
            --body-file) shift 2 ;;
            *) shift ;;
          esac
        done
        newbody=$(cat)
        [ "${GH_ISSUE_EDIT_STATUS:-0}" = 0 ] || { echo "gh: simulated edit failure" >&2; exit "$GH_ISSUE_EDIT_STATUS"; }
        printf '%s' "$newbody" > "$STATE_BODY"
        exit 0 ;;
      *) echo "unexpected issue verb: $verb" >&2; exit 99 ;;
    esac ;;
  pr)
    verb="${1:-}"; shift || true
    case "$verb" in
      view)
        [ "${GH_PR_VIEW_STATUS:-0}" = 0 ] || { echo "gh: simulated failure" >&2; exit "$GH_PR_VIEW_STATUS"; }
        printf '%s\n' "${GH_PR_JSON:-EMPTY_PR}" | sed 's/^EMPTY_PR$/{}/'
        exit 0 ;;
      *) echo "unexpected pr verb: $verb" >&2; exit 99 ;;
    esac ;;
  *) echo "unexpected gh invocation: $noun $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
export STATE_BODY

fails=0
case_n=0

run_case() {   # run_case <label> <child> <pr> <repo>
  local label="$1" child="$2" pr="$3" repo="$4"
  case_n=$((case_n + 1))
  GH_CALL_LOG="$WORK/calls.$case_n.log"; export GH_CALL_LOG
  : > "$GH_CALL_LOG"
  OUT="$WORK/out.$case_n"; ERR="$WORK/err.$case_n"
  set +e
  "$SCRIPT" "$child" "$pr" "$repo" > "$OUT" 2> "$ERR"
  RC=$?
  set -e
  CASE="$label"
}

run_argv() {   # run_argv <label> <argv…> — the raw command line, for the option-shape cases
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
expect_stdout() {
  if [ "$(cat "$OUT")" != "$1" ]; then
    echo "FAIL: [$CASE] expected stdout '$1', got '$(cat "$OUT")'"
    fails=$((fails + 1)); return 1
  fi
}
expect_stderr_contains() {
  if ! grep -qF -- "$1" "$ERR"; then
    echo "FAIL: [$CASE] stderr lacks: $1"; echo "--- stderr"; cat "$ERR"
    fails=$((fails + 1)); return 1
  fi
}
expect_no_calls() {
  if [ -s "$GH_CALL_LOG" ]; then
    echo "FAIL: [$CASE] gh was called, and must not have been:"; cat "$GH_CALL_LOG"
    fails=$((fails + 1)); return 1
  fi
}
expect_body_contains() {
  if ! grep -qF -- "$1" "$STATE_BODY"; then
    echo "FAIL: [$CASE] the parent body lacks: $1"; echo "--- body"; cat "$STATE_BODY"
    fails=$((fails + 1)); return 1
  fi
}
expect_body_count() {   # expect_body_count <needle> <n>
  local got
  got=$(grep -cF -- "$1" "$STATE_BODY" || true)
  if [ "$got" != "$2" ]; then
    echo "FAIL: [$CASE] expected '$1' to appear $2 time(s) in the parent body, got $got"
    echo "--- body"; cat "$STATE_BODY"
    fails=$((fails + 1)); return 1
  fi
}
ok() { echo "ok   [$CASE] $1"; }

REPO="o/r"

# --------------------------------------------------------------------- 1. no parent: pure no-op
GH_PARENT_JSON='{"parent":null}' \
  run_case "no-parent" 42 99 "$REPO"
expect_rc 0 && expect_stdout "no-parent" \
  && ok "a child with no parent is a no-op, exit 0, prints 'no-parent'"
if grep -qE 'ARGS: pr view|ARGS: issue edit' "$GH_CALL_LOG"; then
  echo "FAIL: [$CASE] a PR lookup or issue edit happened despite no parent"; fails=$((fails + 1))
else
  ok "no PR lookup and no write when there is no parent — the common path stays cheap"
fi

# ---------------------------------------------------------- 2. first child appends the section
printf '## Destination\n\nShip the epic.\n\n## Notes\n\nSome notes.\n' > "$STATE_BODY"
GH_PARENT_JSON='{"parent":{"number":100,"title":"Tracking epic","url":"https://github.com/o/r/issues/100"}}' \
  GH_PR_JSON='{"title":"feat(x): first slice (#42) (#76)","url":"https://github.com/o/r/pull/76"}' \
  run_case "first-child-appends-section" 42 76 "$REPO"
expect_rc 0 \
  && expect_stdout "appended #42's PR #76 to parent #100's Decisions so far" \
  && expect_body_contains "## Decisions so far" \
  && expect_body_contains "- #42 — feat(x): first slice ([#76](https://github.com/o/r/pull/76))" \
  && ok "no existing section: the heading and the first line are both added"

# --------------------------------------- 3. second child appends a line, not a second section
GH_PARENT_JSON='{"parent":{"number":100,"title":"Tracking epic","url":"https://github.com/o/r/issues/100"}}' \
  GH_PR_JSON='{"title":"fix(y): second slice (#55) (#88)","url":"https://github.com/o/r/pull/88"}' \
  run_case "second-child-appends-line" 55 88 "$REPO"
expect_rc 0 \
  && expect_body_contains "- #55 — fix(y): second slice ([#88](https://github.com/o/r/pull/88))" \
  && expect_body_contains "- #42 — feat(x): first slice ([#76](https://github.com/o/r/pull/76))" \
  && expect_body_count "## Decisions so far" 1 \
  && ok "a second landed child adds a second line under the SAME heading, not a new section"

# --------------------------------------------------------------- 4. idempotent re-run: no-op
GH_PARENT_JSON='{"parent":{"number":100,"title":"Tracking epic","url":"https://github.com/o/r/issues/100"}}' \
  GH_PR_JSON='{"title":"feat(x): first slice (#42) (#76)","url":"https://github.com/o/r/pull/76"}' \
  run_case "idempotent-rerun" 42 76 "$REPO"
expect_rc 0 && expect_stdout "already-noted" \
  && expect_body_count "- #42 — feat(x): first slice ([#76](https://github.com/o/r/pull/76))" 1 \
  && ok "re-running on the same child+PR is idempotent — one line, not two"
if grep -qE 'ARGS: issue edit' "$GH_CALL_LOG"; then
  echo "FAIL: [$CASE] a write happened on an idempotent re-run"; fails=$((fails + 1))
else
  ok "the idempotent path never calls gh issue edit at all"
fi

# --------------------------------------------------------------- 5. malformed parent JSON refuses
GH_PARENT_MALFORMED=1 run_case "malformed-parent-json" 42 76 "$REPO"
expect_rc 1 && expect_stderr_contains "parent-decision-note:" \
  && ok "unparseable JSON from the parent-lookup call is a refusal, not a silent no-parent"
if grep -qE 'ARGS: issue edit' "$GH_CALL_LOG"; then
  echo "FAIL: [$CASE] a write happened despite malformed input"; fails=$((fails + 1))
else
  ok "nothing was written after a malformed parent-lookup response"
fi

# --------------------------------------------------------------------------- 6. usage errors
run_argv "usage-wrong-arg-count" 42 "$REPO"   # only 2 positionals — the 3rd (repo) is missing
expect_rc 2 && expect_no_calls && ok "2 arguments instead of 3 is exit 2 and calls gh not at all"
expect_stderr_contains "expected 3 arguments, got 2" \
  && ok "…and the no-flag refusal keeps its wording, the one three field reports quote"

run_case "usage-non-numeric-child" abc 76 "$REPO"
expect_rc 2 && expect_no_calls && ok "a non-numeric child issue number is exit 2, calls nothing"

run_case "usage-non-numeric-pr" 42 abc "$REPO"
expect_rc 2 && expect_no_calls && ok "a non-numeric PR number is exit 2, calls nothing"

run_case "usage-bad-repo" 42 76 "not-a-repo"
expect_rc 2 && expect_no_calls && ok "a repo not shaped like owner/repo is exit 2, calls nothing"

# ------------------------------- 6b. -R names the repository, the way its two siblings take it (#668)
# `guarded-pr-merge.sh` and `base-run-verdict.sh` both take `-R <[host/]owner/repo>`, and `merge-pr`
# reads all three in sequence — so the shape used a call ago was transferred to this one, which took
# the slug positionally, and the turn was lost. Measured: 11 refusals across 5 scripts in 18 days,
# three of them this exact call, all under 3.1.0.
GH_PARENT_JSON='{"parent":{"number":100,"title":"Tracking epic","url":"https://github.com/o/r/issues/100"}}' \
  GH_PR_JSON='{"title":"fix(z): third slice (#66) (#99)","url":"https://github.com/o/r/pull/99"}' \
  run_argv "flag-repo-appends" -R "$REPO" 66 99
expect_rc 0 \
  && expect_body_contains "- #66 — fix(z): third slice ([#99](https://github.com/o/r/pull/99))" \
  && ok "-R <repo> <child> <pr> does exactly what <child> <pr> <repo> does"

run_argv "flag-repo-twice" -R "$REPO" 42 76 "$REPO"
expect_rc 2 && expect_no_calls && expect_stderr_contains "repository given twice" \
  && ok "a repository given both ways is refused by name, never silently preferred"

run_argv "usage-line-under-refusal" 42 76
expect_rc 2 && expect_stderr_contains "usage: parent-decision-note.sh [-R <[host/]owner/repo>]" \
  && ok "a wrong shape prints the script's own usage line under the refusal"

run_argv "unknown-option" --toplevel-check 42 76 "$REPO"
expect_rc 2 && expect_no_calls && expect_stderr_contains "unknown option" \
  && ok "an option the script does not have is named, not read as a positional"

# ------------------------------------------------------ 7. a genuine gh failure is a real refusal
GH_PARENT_VIEW_STATUS=1 run_case "parent-lookup-gh-failure" 42 76 "$REPO"
expect_rc 1 && expect_stderr_contains "parent-decision-note:" \
  && ok "a failing parent-lookup gh call is a refusal (exit 1), never read as no-parent"

printf '## Destination\n\nShip the epic.\n' > "$STATE_BODY"
GH_PARENT_JSON='{"parent":{"number":200}}' GH_PR_VIEW_STATUS=1 \
  run_case "pr-lookup-gh-failure" 42 76 "$REPO"
expect_rc 1 && expect_stderr_contains "parent-decision-note:" \
  && ok "a failing PR lookup is a refusal, and the parent body is left untouched"
if [ "$(cat "$STATE_BODY")" != "$(printf '## Destination\n\nShip the epic.')" ]; then
  echo "FAIL: [$CASE] the parent body was mutated despite the PR lookup failing"; fails=$((fails + 1))
fi

# ------------------------------------------------------------ 8. the repository's own host (#514)
#
# `gh -R OWNER/REPO` takes gh's DEFAULT host, even inside a GitHub Enterprise checkout, so on a GHE
# repository every call this script makes reached github.com. The seam is the stub's log: the
# GH_HOST each call ran under, and the -R it was given.
expect_call() {   # expect_call <ERE> — the case's gh log holds a line matching <ERE>
  if ! grep -qE -- "$1" "$GH_CALL_LOG"; then
    echo "FAIL: [$CASE] gh was never called as /$1/"; echo "--- calls"; cat "$GH_CALL_LOG"
    fails=$((fails + 1)); return 1
  fi
}
expect_all_hosted() {   # every issue/pr call ran under GH_HOST=ghe.example.com, none without it
  if grep -qE '^GH_HOST=<unset> ARGS: (issue|pr) ' "$GH_CALL_LOG"; then
    echo "FAIL: [$CASE] an issue/pr call ran without the host:"; cat "$GH_CALL_LOG"
    fails=$((fails + 1)); return 1
  fi
}

# A checkout whose origin is on a GHE host: all five calls — the parent lookup, the PR lookup, the
# body read, the write and the read-back — reach that host.
CO_GHE="$WORK/co-ghe"
git init -q "$CO_GHE"
git -C "$CO_GHE" remote add origin git@ghe.example.com:acme/widgets.git
printf '## Destination\n\nShip the epic.\n' > "$STATE_BODY"
cd "$CO_GHE"
GH_STUB_HOSTS=ghe.example.com \
  GH_PARENT_JSON='{"parent":{"number":300}}' \
  GH_PR_JSON='{"title":"feat(z): ghe slice (#61) (#91)","url":"https://ghe.example.com/acme/widgets/pull/91"}' \
  run_case "ghe-origin" 61 91 "acme/widgets"
cd "$KIT_ROOT"
expect_rc 0 \
  && expect_stdout "appended #61's PR #91 to parent #300's Decisions so far" \
  && expect_call '^GH_HOST=ghe\.example\.com ARGS: issue view 61 -R acme/widgets --json parent$' \
  && expect_call '^GH_HOST=ghe\.example\.com ARGS: pr view 91 -R acme/widgets --json title,url$' \
  && expect_call '^GH_HOST=ghe\.example\.com ARGS: issue view 300 -R acme/widgets --json body$' \
  && expect_call '^GH_HOST=ghe\.example\.com ARGS: issue edit 300 -R acme/widgets --body-file -$' \
  && expect_all_hosted \
  && ok "a GHE checkout: all five issue/pr calls ran under GH_HOST=ghe.example.com"

# A HOST/ prefix names the host outright — even from this checkout, whose origin is github.com —
# and the calls get OWNER/REPO, never the prefixed slug.
printf '## Destination\n\nShip the epic.\n' > "$STATE_BODY"
GH_PARENT_JSON='{"parent":{"number":300}}' \
  GH_PR_JSON='{"title":"feat(z): prefixed slice (#62) (#92)","url":"https://ghe.example.com/acme/widgets/pull/92"}' \
  run_case "ghe-prefix" 62 92 "ghe.example.com/acme/widgets"
expect_rc 0 \
  && expect_stdout "appended #62's PR #92 to parent #300's Decisions so far" \
  && expect_call '^GH_HOST=ghe\.example\.com ARGS: issue view 62 -R acme/widgets --json parent$' \
  && expect_call '^GH_HOST=ghe\.example\.com ARGS: issue edit 300 -R acme/widgets --body-file -$' \
  && expect_all_hosted \
  && ok "HOST/OWNER/REPO is accepted: every call got -R acme/widgets under GH_HOST=ghe.example.com"
if grep -qF -- '-R ghe.example.com/' "$GH_CALL_LOG"; then
  echo "FAIL: [$CASE] the host leaked into a -R value:"; cat "$GH_CALL_LOG"; fails=$((fails + 1))
fi

# Four segments is no slug at all: the host helper refuses it, and gh is never called.
run_case "malformed-slug" 42 76 "a/b/c/d"
expect_rc 2 && expect_no_calls && expect_stderr_contains "malformed repository slug 'a/b/c/d'" \
  && ok "a four-segment slug is exit 2, named on stderr, calls nothing"

# Admitting HOST/OWNER/REPO must not admit an empty segment with it.
run_case "empty-segment" 42 76 "acme//widgets"
expect_rc 2 && expect_no_calls && ok "a slug with an empty segment is still exit 2, calls nothing"

# The host helper is part of the install: without it the note refuses, naming the missing file,
# rather than falling back to gh's default host — the exact #514 failure.
NOHELPER="$WORK/nohelper/skills/merge-pr/scripts"
mkdir -p "$NOHELPER"
cp "$SCRIPT" "$NOHELPER/parent-decision-note.sh"
SCRIPT_KEEP="$SCRIPT"; SCRIPT="$NOHELPER/parent-decision-note.sh"
run_case "missing-helper" 42 76 "$REPO"
SCRIPT="$SCRIPT_KEEP"
expect_rc 2 && expect_no_calls && expect_stderr_contains "_shared/scripts/_gh-host.sh; reinstall the kit" \
  && ok "without its host helper: exit 2, the missing file named, calls nothing"

# ----------------------------------------------------------------------------------- verdict
if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "merge-pr-parent golden test: all cases behaved as specified"
