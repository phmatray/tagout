#!/usr/bin/env bash
# Golden test for skills/merge-pr/scripts/approve-runs.sh (#495).
#
# WHAT THIS PINS. `ci.verdict` now files a run stuck `action_required` under the non-terminal
# verdict `needs-approval` rather than `failed` — nothing a push can change clears it, only an
# approval can. This script is the one thing allowed to send that approval, and ONLY for this
# repository's own release bot: approving a stranger's workflow run executes their code with this
# repo's secrets, which is exactly the case GitHub's approval gate exists to stop. So the refusal
# path is exercised BEFORE the happy path — a script whose refusal is untested is the same defect
# #208 already closed for the decision engine, one layer up.
#
# The stub is the same idiom as tests/remote-branch-teardown/test.sh and
# tests/merge-base-ci/test.sh: `gh` is a real script on a prepended PATH, keyed on the invocation
# shape rather than fed fixture files, because this script's whole job is three small `gh` calls in
# sequence (view, list, approve) rather than a jq reduction over a big JSON blob.
set -euo pipefail
# A GH_HOST in the developer's or CI's shell would decide the host cases (#514) on its own.
unset GH_HOST
cd "$(dirname "$0")/../.."

SCRIPT="./skills/merge-pr/scripts/approve-runs.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT is missing or not executable"; exit 1; }

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
kit_guard kit_guard_samples_unchanged

command -v jq > /dev/null 2>&1 || {
  echo "FAIL: jq is missing — it is a \`required\` prerequisite in requirements.json, and this
        script uses it to read gh's JSON."
  exit 1; }

FAILED=0
note_fail() { echo "FAIL: $1"; FAILED=1; }

STUBS=$(kit_scratch)
PR_JSON="$STUBS/pr.json"          # what `gh pr view` answers
RUNS_JSON="$STUBS/runs.json"      # what `gh api actions/runs?head_sha=` answers
APPROVE_RC="$STUBS/approve.rc"    # exit code the approve POST should return
APPROVE_OUT="$STUBS/approve.out"  # its stderr on failure
APPROVED_LOG="$STUBS/approved"    # every run id the stub was asked to POST /approve for
GH_ARGS_LOG="$STUBS/gh-args"      # every invocation, one per line — proves what was (not) called
RP_CFG="$STUBS/rp-config.json"    # what `gh api …/contents/release-please-config.json` answers

# The stub answers three questions and refuses anything else, the same fail-loud-on-the-unscripted
# posture as the prior-art stubs above: an invocation this suite never armed is a suite bug, not a
# silent pass.
cat > "$STUBS/gh" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_ARGS_LOG"
if [ "\$1" = "auth" ] && [ "\${2:-}" = "token" ]; then
  exit 1   # no stubbed host credential — approve-runs.sh must still resolve OWNER_REPO from -R
fi
if [ "\$1" = "api" ]; then
  # Faithful to the real gh: \`gh api\` has no --repo/-R flag, only --hostname. Refusing it here is
  # what makes every case below a guard against the flag creeping back onto an api call (#622).
  for a in "\$@"; do
    case "\$a" in -R|--repo) echo "unknown shorthand flag: 'R' in -R" >&2; exit 1 ;; esac
  done
fi
if [ "\$1" = "pr" ] && [ "\${2:-}" = "view" ]; then
  cat "$PR_JSON"
  exit 0
fi
case "\$*" in
  *"-X POST"*"/approve"*)
    url=""
    for a in "\$@"; do
      case "\$a" in */runs/*/approve) url="\$a" ;; esac
    done
    id="\${url##*/runs/}"; id="\${id%%/approve*}"
    echo "\$id" >> "$APPROVED_LOG"
    cat "$APPROVE_OUT" >&2 2>/dev/null
    exit "\$(cat "$APPROVE_RC")"
    ;;
  *"actions/runs?head_sha="*)
    cat "$RUNS_JSON"
    exit 0
    ;;
  *"contents/release-please-config.json"*)
    # An absent config is a 404, not an empty file — the distinction the fail-closed path turns on.
    [ -s "$RP_CFG" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    cat "$RP_CFG"
    exit 0
    ;;
esac
echo "unexpected gh invocation in approve-runs suite: \$*" >&2
exit 99
STUBEOF
chmod +x "$STUBS/gh"

REPO="phmatray/tagout"
SHA="deadbeef00000000000000000000000000000000"

set_pr()      { printf '%s' "$1" > "$PR_JSON"; }
set_runs()    { printf '%s' "$1" > "$RUNS_JSON"; }
set_approve() { printf '%s' "${2:-}" > "$APPROVE_OUT"; printf '%s' "$1" > "$APPROVE_RC"; }

# pr_json <author> [head-branch] [changed-paths…] — the two optional tails default to a shape that
# CANNOT satisfy the release-automation conjunction, so every pre-existing single-argument call
# still exercises exactly what it exercised before.
pr_json() {
  local author="$1" branch="${2:-feature/something}"; shift 2 2>/dev/null || shift
  local files="[]" p
  for p in "$@"; do files=$(printf '%s' "$files" | jq -c --arg p "$p" '. + [{"path":$p}]'); done
  local n; n=$(printf '%s' "$files" | jq 'length')
  printf '{"author":{"login":"%s"},"headRefOid":"%s","headRefName":"%s","files":%s,"changedFiles":%s}'     "$author" "$SHA" "$branch" "$files" "${PR_CHANGED_FILES:-$n}"
}

# The eight paths release-please actually touched on this repo's PR #621, and the config that
# declares them. The allowlist is DERIVED from this config, never hard-coded, so adding an
# extra-files entry here is all a future release file needs.
RP_BRANCH="release-please--branches--main--components--tagout"
RP_FILES=".release-please-manifest.json CHANGELOG.md .claude-plugin/plugin.json .codex-plugin/plugin.json .github/plugin/plugin.json gemini-extension.json plugins/tagout/.claude-plugin/plugin.json plugins/tagout-migrate/.claude-plugin/plugin.json"
set_rp_config() {
  cat > "$RP_CFG" <<'RPEOF'
{
  "packages": {
    ".": {
      "changelog-path": "CHANGELOG.md",
      "extra-files": [
        { "type": "json", "path": "plugins/tagout/.claude-plugin/plugin.json" },
        { "type": "json", "path": "plugins/tagout-migrate/.claude-plugin/plugin.json" },
        { "type": "json", "path": ".claude-plugin/plugin.json" },
        { "type": "json", "path": ".codex-plugin/plugin.json" },
        { "type": "json", "path": ".github/plugin/plugin.json" },
        { "type": "json", "path": "gemini-extension.json" }
      ]
    }
  }
}
RPEOF
}
clear_rp_config() { : > "$RP_CFG"; }
run_entry() { printf '{"id":%s,"name":"%s","conclusion":"%s"}' "$1" "$2" "$3"; }

reset_case() { : > "$GH_ARGS_LOG"; : > "$APPROVED_LOG"; set_approve 0; set_rp_config; unset PR_CHANGED_FILES; }

# run <name> <want-exit> <what>
run() {
  local name="$1" want_exit="$2" what="$3" out rc=0
  out=$(PATH="$STUBS:$PATH" "$SCRIPT" -R "$REPO" "$4" 2>&1) || rc=$?
  CASE_OUT="$out"
  if [ "$rc" != "$want_exit" ]; then
    note_fail "$name — $what
      want exit: $want_exit
      got exit:  $rc
      output: $out"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------- 1. refusal (not the bot)
#
# The author check runs BEFORE any run is even listed — a caller who is not the release bot gets
# refused having taught this script nothing an attacker could use. `gh api …/actions/runs` IS still
# called (to name the ids in the refusal message), but the POST must never fire.
reset_case
set_pr "$(pr_json someone)"
set_runs "$(printf '{"workflow_runs":[%s]}' "$(run_entry 111 release-title action_required)")"
if run refusal 2 'an author who is not the release bot is refused' 42; then
  case "$CASE_OUT" in
    *"111"*) : ;;
    *) note_fail "refusal — the run id was not named in the refusal message:
      $CASE_OUT" ;;
  esac
  case "$CASE_OUT" in
    *"approve"*) : ;;
    *) note_fail "refusal — no manual remedy printed:
      $CASE_OUT" ;;
  esac
  [ -s "$APPROVED_LOG" ] && note_fail "refusal — approve-runs POSTed an approval for a non-bot author: $(cat "$APPROVED_LOG")"
  echo "ok: refusal — author 'someone' is refused, nothing approved, run id named"
fi

# -------------------------------------------------------------------------- 2. happy path (the bot)
#
# Two action_required runs on the sha (the measured PR #475 shape: `ci` and `release-title` both
# stuck) plus one job that is not action_required at all (must not be approved). Exactly those two
# ids get POSTed, and the script prints `approved <id>` for each.
reset_case
set_pr "$(pr_json 'release-please[bot]')"
set_runs "$(printf '{"workflow_runs":[%s,%s,%s]}' \
  "$(run_entry 111 release-title action_required)" \
  "$(run_entry 222 ci action_required)" \
  "$(run_entry 333 title-gate success)")"
if run happy 0 'the release bot`s two action_required runs are both approved, the success run is not' 42; then
  case "$CASE_OUT" in
    *"approved 111"*) : ;;
    *) note_fail "happy — 'approved 111' missing from: $CASE_OUT" ;;
  esac
  case "$CASE_OUT" in
    *"approved 222"*) : ;;
    *) note_fail "happy — 'approved 222' missing from: $CASE_OUT" ;;
  esac
  approved=$(sort -u "$APPROVED_LOG" | tr '\n' ' ')
  [ "$approved" = "111 222 " ] || note_fail "happy — approved exactly {111,222}, got: $approved"
  echo "ok: happy — release-please[bot]'s action_required runs (111, 222) are approved; the success run (333) is not"
fi

# ------------------------------------------------------------------ 2b. no `-R` — the normal call
#
# `merge-pr` never passes `-R`: it calls this script from the PR's own checkout and lets `gh`
# resolve the repository itself, the same way every other read in the skill does. `REPO_FLAG=()`
# is then an EMPTY array expanded under `set -u` — bash <4.4 (this repo's own parse-sweep target,
# and macOS's shipped /bin/bash) raises "unbound variable" on a bare `"${arr[@]}"` when the array
# is empty, unless the expansion uses the `${arr[@]+"${arr[@]}"}` guard. This case is the one that
# would have caught it: every other case above always passes `-R`, so it never exercises the empty
# array at all.
reset_case
set_pr "$(pr_json 'release-please[bot]')"
set_runs "$(printf '{"workflow_runs":[%s]}' "$(run_entry 111 release-title action_required)")"
out=$(PATH="$STUBS:$PATH" "$SCRIPT" 42 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  note_fail "no-repo-flag — expected exit 0 with no -R, got $rc: $out"
elif [ "$out" != "approved 111" ]; then
  note_fail "no-repo-flag — expected 'approved 111' with no -R, got: $out"
else
  echo "ok: no-repo-flag — an empty REPO_FLAG array does not trip 'unbound variable' under set -u"
fi

# -------------------------------------------------------------- 3. the bot, but nothing to approve
#
# `ci.verdict` only ever calls this after seeing needs-approval, but the script must still answer
# sanely if the sha's action_required run was itself approved and re-run between the two reads.
reset_case
set_pr "$(pr_json 'release-please[bot]')"
set_runs "$(printf '{"workflow_runs":[%s]}' "$(run_entry 333 title-gate success)")"
if run no-runs 0 'the release bot, but the sha carries no action_required run any more' 42; then
  [ "$CASE_OUT" = "approved 0 run(s)" ] || note_fail "no-runs — expected 'approved 0 run(s)', got: $CASE_OUT"
  [ -s "$APPROVED_LOG" ] && note_fail "no-runs — a POST was sent when nothing needed approving"
  echo "ok: no-runs — release-please[bot] with nothing action_required prints 'approved 0 run(s)', POSTs nothing"
fi

# --------------------------------------------------------------------------- 4. the API call fails
#
# The approve endpoint answers 403 when the caller cannot approve (Spec's own edge case). The
# script must exit 1 with the API's message and never retry — retrying a write is not this
# script's call to make.
reset_case
set_pr "$(pr_json 'release-please[bot]')"
set_runs "$(printf '{"workflow_runs":[%s]}' "$(run_entry 111 release-title action_required)")"
set_approve 1 "HTTP 403: Resource not accessible by integration"
if run api-failure 1 'a 403 from the approve endpoint exits 1, not 0 and not a silent pass' 42; then
  case "$CASE_OUT" in
    *"403"*) : ;;
    *) note_fail "api-failure — the API's own error message did not reach the caller: $CASE_OUT" ;;
  esac
  n=$(grep -c '^111$' "$APPROVED_LOG" || true)
  [ "$n" -eq 1 ] || note_fail "api-failure — expected exactly one approve attempt for run 111, saw $n"
  echo "ok: api-failure — a 403 on the approve call exits 1 with the API message, and is not retried"
fi

# ------------------------------------------- 6. this repository's own release automation (#622)
#
# release-please posts its PR through the default GITHUB_TOKEN, so the author is `app/github-actions`
# and never `release-please[bot]` — the guard #495 wrote was dead code on its only caller, and the
# release cut was the one PR the kit could not land (measured landing 3.0.1, PR #621).
#
# The login alone is NOT evidence: any workflow using the default token opens PRs under it. So the
# accept path is a CONJUNCTION of three facts no outside contributor can hold at once — the author,
# a release-please head branch, and a diff confined to the paths this repo's OWN
# release-please-config.json declares. Each refusal below removes exactly one conjunct, so no single
# fact can ever carry the approval by itself.

reset_case
set_pr "$(pr_json 'app/github-actions' "$RP_BRANCH" $RP_FILES)"
set_runs "$(printf '{"workflow_runs":[%s,%s]}'   "$(run_entry 111 release-title action_required)" "$(run_entry 222 ci action_required)")"
if run "release-accept" 0 "the repo's own release PR is approved" 42; then
  approved=$(sort -u "$APPROVED_LOG" | tr '\n' ' ')
  [ "$approved" = "111 222 " ] || note_fail "release-accept — approved exactly {111,222}, got: $approved"
  # The allowlist must be read from the repository's DEFAULT branch. Reading it at `?ref=<head>`
  # would let a PR widen the very allowlist it is judged against — and every other case here would
  # still pass, because the stub answers the contents call whatever ref it names. So the ABSENCE of
  # a ref is asserted directly, on the recorded invocation.
  cfg_call=$(grep 'contents/release-please-config.json' "$GH_ARGS_LOG" || true)
  [ -n "$cfg_call" ] || note_fail "release-accept — the config was never read; the allowlist cannot have been derived"
  case "$cfg_call" in
    *ref=*) note_fail "release-accept — the allowlist was read at a ref: $cfg_call
      It must come from the default branch: a PR that picks its own ref picks its own allowlist." ;;
  esac
  echo "ok: release-accept — author+branch+declared-paths together approve the release PR (#622)"
  echo "ok: release-accept — the allowlist is read from the default branch, not the PR's head (#622)"
fi

reset_case
set_pr "$(pr_json 'app/github-actions' "$RP_BRANCH" $RP_FILES scripts/decide.sh)"
set_runs "$(printf '{"workflow_runs":[%s]}' "$(run_entry 111 ci action_required)")"
if run "release-refuse-path" 2 "one path outside the declared set refuses the whole PR" 42; then
  [ -s "$APPROVED_LOG" ] && note_fail "release-refuse-path — an approval was POSTed: $(cat "$APPROVED_LOG")"
  echo "ok: release-refuse-path — a single undeclared path (scripts/decide.sh) refuses it (#622)"
fi

reset_case
set_pr "$(pr_json 'app/github-actions' 'feature/not-a-release' $RP_FILES)"
set_runs "$(printf '{"workflow_runs":[%s]}' "$(run_entry 111 ci action_required)")"
if run "release-refuse-branch" 2 "release-shaped diff on a non-release branch refuses" 42; then
  [ -s "$APPROVED_LOG" ] && note_fail "release-refuse-branch — an approval was POSTed: $(cat "$APPROVED_LOG")"
  echo "ok: release-refuse-branch — the declared paths alone do not carry it (#622)"
fi

reset_case
set_pr "$(pr_json 'someone' "$RP_BRANCH" $RP_FILES)"
set_runs "$(printf '{"workflow_runs":[%s]}' "$(run_entry 111 ci action_required)")"
if run "release-refuse-author" 2 "a stranger on a release-shaped branch and diff refuses" 42; then
  [ -s "$APPROVED_LOG" ] && note_fail "release-refuse-author — an approval was POSTed: $(cat "$APPROVED_LOG")"
  echo "ok: release-refuse-author — branch and paths alone do not carry it (#622)"
fi

reset_case
clear_rp_config
set_pr "$(pr_json 'app/github-actions' "$RP_BRANCH" $RP_FILES)"
set_runs "$(printf '{"workflow_runs":[%s]}' "$(run_entry 111 ci action_required)")"
if run "release-refuse-noconfig" 2 "no release-please-config.json means no allowlist, so refuse" 42; then
  [ -s "$APPROVED_LOG" ] && note_fail "release-refuse-noconfig — an approval was POSTed: $(cat "$APPROVED_LOG")"
  echo "ok: release-refuse-noconfig — an unreadable config fails CLOSED, never open (ADR 0002) (#622)"
fi

reset_case
# GitHub caps `files`; a capped page's undeclared paths are simply absent, so a guard that trusts
# the page approves on the strength of a prefix. changedFiles is the authoritative count.
PR_CHANGED_FILES=9999
set_pr "$(pr_json 'app/github-actions' "$RP_BRANCH" $RP_FILES)"
set_runs "$(printf '{"workflow_runs":[%s]}' "$(run_entry 111 ci action_required)")"
if run "release-refuse-truncated" 2 "a truncated file list cannot prove the whole diff" 42; then
  [ -s "$APPROVED_LOG" ] && note_fail "release-refuse-truncated — an approval was POSTed: $(cat "$APPROVED_LOG")"
  echo "ok: release-refuse-truncated — files is a page, not the diff; a short page refuses (#622)"
fi

reset_case
printf '{}' > "$RP_CFG"
set_pr "$(pr_json 'app/github-actions' "$RP_BRANCH" .release-please-manifest.json)"
set_runs "$(printf '{"workflow_runs":[%s]}' "$(run_entry 111 ci action_required)")"
if run "release-refuse-emptyconfig" 2 "a config declaring no package declares no allowlist" 42; then
  [ -s "$APPROVED_LOG" ] && note_fail "release-refuse-emptyconfig — an approval was POSTed: $(cat "$APPROVED_LOG")"
  echo "ok: release-refuse-emptyconfig — '{}' parses but declares nothing, so it refuses (#622)"
fi

reset_case
printf 'this is not json' > "$RP_CFG"
set_pr "$(pr_json 'app/github-actions' "$RP_BRANCH" $RP_FILES)"
set_runs "$(printf '{"workflow_runs":[%s]}' "$(run_entry 111 ci action_required)")"
if run "release-refuse-badconfig" 2 "an unparseable config yields no allowlist, so refuse" 42; then
  [ -s "$APPROVED_LOG" ] && note_fail "release-refuse-badconfig — an approval was POSTed: $(cat "$APPROVED_LOG")"
  echo "ok: release-refuse-badconfig — malformed JSON refuses; it is not read as 'nothing to check' (#622)"
fi

# A second package, and an extra-files entry in its plain-string form: both shapes release-please
# accepts, and both are what the $dir join and the string/object branch exist for. Without this the
# two branches are untested speculation.
reset_case
cat > "$RP_CFG" <<'RPEOF'
{
  "packages": {
    ".":      { "changelog-path": "CHANGELOG.md" },
    "pkg/sub": { "changelog-path": "CHANGELOG.md", "extra-files": ["version.txt"] }
  }
}
RPEOF
set_pr "$(pr_json 'app/github-actions' "$RP_BRANCH" .release-please-manifest.json CHANGELOG.md pkg/sub/CHANGELOG.md pkg/sub/version.txt)"
set_runs "$(printf '{"workflow_runs":[%s]}' "$(run_entry 111 ci action_required)")"
if run "release-multipackage" 0 "a second package's paths are joined to its directory" 42; then
  echo "ok: release-multipackage — per-package dirs and string extra-files resolve (#622)"
fi

reset_case
set_pr "$(pr_json 'app/github-actions' "$RP_BRANCH")"
set_runs "$(printf '{"workflow_runs":[%s]}' "$(run_entry 111 ci action_required)")"
if run "release-refuse-nofiles" 2 "a PR reporting no changed files proves nothing, so refuse" 42; then
  [ -s "$APPROVED_LOG" ] && note_fail "release-refuse-nofiles — an approval was POSTed: $(cat "$APPROVED_LOG")"
  echo "ok: release-refuse-nofiles — an empty file list is not an empty allowlist check (#622)"
fi

# ---------------------------------------------------------------------------------------- verdict
if [ "$FAILED" -ne 0 ]; then
  echo
  echo "approve-runs: FAILED"
  exit 1
fi
echo
echo "approve-runs: OK — approves only the release bot's action_required runs, refuses every other author."
