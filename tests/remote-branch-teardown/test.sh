#!/usr/bin/env bash
# Golden test for merge-pr's remote-branch-teardown.sh (#185).
#
# Step 7 used to assume the remote head branch was already gone by the time it ran — via Step 5's
# `--delete-branch` or the repo's own `delete_branch_on_merge` — and never checked. On a repo
# without that setting on, and on the kit's own layout (the branch lives in an `implement-issue`
# worktree, so gh's local delete fails first and short-circuits before it ever reaches the remote
# side — confirmed by reading `mergeRun` in `cli/cli`, Task 1 of #185), that assumption is false:
# `origin/<headRefName>` leaks permanently and nothing ever notices.
#
# remote-branch-teardown.sh is not fixture-file driven — it shells out to `git ls-remote` and
# `gh api -X DELETE`, so this suite stubs both (same idiom as tests/guarded-git/test.sh) rather than
# feeding it JSON. Three shapes from the issue's own Task 3, plus the race the script itself
# documents tolerating (a concurrent delete winning between the ls-remote and the DELETE call) and
# the two refusal paths (bad usage, a genuine ls-remote failure).
set -euo pipefail
# A GH_HOST in the developer's or CI's shell would decide the host cases (#514) on its own.
unset GH_HOST
cd "$(dirname "$0")/../.."

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"

SCRIPT="$KIT_ROOT/skills/merge-pr/scripts/remote-branch-teardown.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT is missing or not executable"; exit 1; }

FAILED=0
note_fail() { echo "FAIL: $1"; FAILED=1; }

command -v jq > /dev/null 2>&1 || {
  echo "FAIL: jq is missing — remote-branch-teardown.sh needs it to URI-encode the branch name"
  exit 1; }

STUBS=$(kit_scratch)
GIT_OUT="$STUBS/git-ls-remote.out"
GIT_RC="$STUBS/git-ls-remote.rc"
GIT_ARGS="$STUBS/git-args"
GH_OUT="$STUBS/gh-delete.out"
GH_RC="$STUBS/gh-delete.rc"
GH_CALLED="$STUBS/gh-called"
GH_ARGS="$STUBS/gh-args"
GH_LOG="$STUBS/gh-log"
GIT_ORIGIN="$STUBS/git-origin"

# Stubs read their behaviour from the files above rather than from arguments baked into the script
# text — so a case only has to rewrite the files, never regenerate the stub. Absolute paths are
# baked in at write time (the heredoc is deliberately unquoted); $STUBS never contains a quote or a
# `$`, since kit_scratch built it with mktemp. Both record the FULL argument list they were called
# with, so a case can assert on the exact ref path/pattern the script built, not just its outcome.
#
# The repository's own host (#514): `git remote get-url origin` answers from $GIT_ORIGIN — absent
# (every case but the GHE one) there is no origin — and leaves $GIT_ARGS alone. Every gh call is
# appended to $GH_LOG with the GH_HOST it ran under; `gh auth token --hostname H`, the host
# helper's credential probe, succeeds only for a host listed in $GH_STUB_HOSTS.
cat > "$STUBS/git" <<STUBEOF
#!/usr/bin/env bash
if [ "\$1" = "remote" ] && [ "\${2:-}" = "get-url" ]; then
  [ -f "$GIT_ORIGIN" ] || { echo "error: No such remote '\${3:-}'" >&2; exit 2; }
  cat "$GIT_ORIGIN"
  exit 0
fi
printf '%s\n' "\$*" > "$GIT_ARGS"
if [ "\$1" = "ls-remote" ]; then
  cat "$GIT_OUT" 2>/dev/null
  exit "\$(cat "$GIT_RC")"
fi
echo "unexpected git invocation in remote-branch-teardown suite: \$*" >&2
exit 99
STUBEOF
chmod +x "$STUBS/git"

cat > "$STUBS/gh" <<STUBEOF
#!/usr/bin/env bash
echo "GH_HOST=\${GH_HOST-<unset>} ARGS: \$*" >> "$GH_LOG"
if [ "\$1" = "auth" ] && [ "\${2:-}" = "token" ]; then
  host=""; prev=""
  for a in "\$@"; do [ "\$prev" = "--hostname" ] && host="\$a"; prev="\$a"; done
  case " \${GH_STUB_HOSTS:-} " in *" \$host "*) echo "gho_stub_token_for_\$host"; exit 0 ;; esac
  exit 1
fi
if [ "\$1" = "api" ]; then
  : > "$GH_CALLED"
  printf '%s\n' "\$*" > "$GH_ARGS"
  cat "$GH_OUT" >&2 2>/dev/null
  exit "\$(cat "$GH_RC")"
fi
echo "unexpected gh invocation in remote-branch-teardown suite: \$*" >&2
exit 99
STUBEOF
chmod +x "$STUBS/gh"

BRANCH="fix/185-remote-branch-teardown"
REPO="phmatray/tagout"

# set_git <ls-remote stdout+stderr> <exit code>
set_git() { printf '%s' "$1" > "$GIT_OUT"; printf '%s' "$2" > "$GIT_RC"; }
# set_gh <api stdout+stderr> <exit code>
set_gh()  { printf '%s' "$1" > "$GH_OUT";  printf '%s' "$2" > "$GH_RC"; }

# run_case <name> <want-exit> <what> [gh-must-not-be-called] [branch]
run_case() {
  local name="$1" want_exit="$2" what="$3" forbid_gh="${4:-}" branch="${5:-$BRANCH}"
  local out rc=0
  rm -f "$GH_CALLED"
  out=$(PATH="$STUBS:$PATH" "$SCRIPT" "$branch" "$REPO" 2>&1) || rc=$?
  CASE_OUT="$out"
  if [ "$rc" != "$want_exit" ]; then
    note_fail "$name — $what
      want exit: $want_exit
      got exit:  $rc
      output: $out"
    return 1
  fi
  if [ -n "$forbid_gh" ] && [ -e "$GH_CALLED" ]; then
    note_fail "$name — $what
      gh api was called, but the remote branch was already gone — no delete was owed
      output: $out"
    return 1
  fi
  return 0
}

want_stdout() {
  local name="$1" want="$2" what="$3"
  if [ "$CASE_OUT" != "$want" ]; then
    note_fail "$name — $what
      want stdout: $want
      got:         $CASE_OUT"
    return 1
  fi
  return 0
}

want_contains() {
  local name="$1" needle="$2" what="$3"
  if ! grep -qF -- "$needle" <<<"$CASE_OUT"; then
    note_fail "$name — $what
      want output to contain: $needle
      got: $CASE_OUT"
    return 1
  fi
  return 0
}

want_file_contains() {
  local name="$1" path="$2" needle="$3" what="$4"
  if ! grep -qF -- "$needle" "$path" 2>/dev/null; then
    note_fail "$name — $what
      want $path to contain: $needle
      got: $(cat "$path" 2>/dev/null || echo '<missing>')"
    return 1
  fi
  return 0
}

want_file_not_contains() {
  local name="$1" path="$2" needle="$3" what="$4"
  if grep -qF -- "$needle" "$path" 2>/dev/null; then
    note_fail "$name — $what
      want $path NOT to contain: $needle
      got: $(cat "$path" 2>/dev/null || echo '<missing>')"
    return 1
  fi
  return 0
}

# --- 1. remote branch already gone: a pure no-op, and gh must never be dialed for a delete that
# isn't owed (Step 5's --delete-branch or delete_branch_on_merge already did it).
set_git "" 0
set_gh "gh should not have been called" 99
if run_case already-gone 0 'the branch is already gone on origin — no-op, no DELETE call' forbid_gh; then
  want_stdout already-gone already-gone \
    'prints the exact word already-gone so a caller can branch on it' \
  && echo "ok: already-gone — no-op, gh never dialed"
fi

# --- 2. remote branch present, deletion succeeds: the routine leaked-branch case this issue exists
# to close (the kit's worktree layout makes gh's own --delete-branch fail before it gets here).
# $BRANCH itself carries a "/" (the kit's own naming convention) — this doubles as the regression
# guard for the URI-encoding fix below: the delete call must reach gh with the slash intact.
set_git "$(printf 'deadbeef\trefs/heads/%s' "$BRANCH")" 0
set_gh "" 0
if run_case present-deleted 0 'the branch survived the merge and the DELETE call succeeds'; then
  want_stdout present-deleted deleted \
    'prints the exact word deleted' \
  && want_file_contains present-deleted "$GH_ARGS" "repos/$REPO/git/refs/heads/$BRANCH" \
    'a branch name with a "/" reaches gh with its slash intact — a flat @uri over the whole
      string would turn it into %2F, which does not route as a path separator' \
  && echo "ok: present-deleted — survives, gets deleted, slash preserved in the request"
fi

# --- 3. remote branch present, delete fails for real (permissions, rate limit, a genuine API
# error) — must be reported on stderr, never swallowed as if it were "already gone".
set_git "$(printf 'deadbeef\trefs/heads/%s' "$BRANCH")" 0
set_gh "HTTP 500: Internal Server Error" 1
if run_case present-delete-fails 1 'a real DELETE failure is reported, not silently swallowed'; then
  want_contains present-delete-fails "failed to delete origin/$BRANCH" \
    'names the branch that could not be torn down' \
  && want_contains present-delete-fails "HTTP 500" \
    "carries the API's own error text so a human can act on it" \
  && echo "ok: present-delete-fails — reported, not swallowed"
fi

# --- 4/5. the race the script documents tolerating: a concurrent delete_branch_on_merge or a slow
# --delete-branch wins between the ls-remote check and this call. gh's own deleteRemoteBranch
# reports that race as "Reference does not exist" on either a 422 or a 404 — the MESSAGE decides,
# not the status code alone (see case 6 below for why that distinction is load-bearing).
set_git "$(printf 'deadbeef\trefs/heads/%s' "$BRANCH")" 0
set_gh "HTTP 422: Validation Failed - Reference does not exist" 1
if run_case race-422 0 'a 422 "Reference does not exist" mid-race is tolerated, not a failure'; then
  want_stdout race-422 already-gone \
    'the race resolves to already-gone, same as the no-op path' \
  && echo "ok: race-422 — concurrent delete tolerated"
fi

set_git "$(printf 'deadbeef\trefs/heads/%s' "$BRANCH")" 0
set_gh "HTTP 404: Not Found - Reference does not exist" 1
if run_case race-404 0 'a 404 "Reference does not exist" mid-race is tolerated the same as a 422'; then
  want_stdout race-404 already-gone \
    'the race resolves to already-gone regardless of which of the two codes gh returns' \
  && echo "ok: race-404 — concurrent delete tolerated"
fi

# --- 6. a plain 404 WITHOUT "Reference does not exist" — a genuine failure the message-only check
# must NOT swallow. A status-code-only match (the original implementation) would read this as
# already-gone; the concrete case it stands in for is a malformed "$REPO" hitting a nonexistent
# repo, which also 404s, for an unrelated reason that must surface, not disappear as false success.
set_git "$(printf 'deadbeef\trefs/heads/%s' "$BRANCH")" 0
set_gh "HTTP 404: Not Found" 1
if run_case bare-404-is-a-failure 1 'a 404 without the "Reference does not exist" message is a real failure, not a race'; then
  want_contains bare-404-is-a-failure "failed to delete origin/$BRANCH" \
    'a bare 404 is reported like any other real failure, never silently read as already-gone' \
  && echo "ok: bare-404-is-a-failure — a same-status 404 without the message still fails loudly"
fi

# --- 7. a `#` in the branch name: `gh api` treats it as a URL fragment delimiter and silently
# truncates everything after it unless the segment is percent-encoded first. Verified live against
# the real `gh` CLI (GH_DEBUG=api) during this PR's review — untruncated here since $HEAD_BRANCH
# never reaches a real HTTP layer in this suite, so the assertion is on the REQUEST BUILT, not on
# what a server would do with it.
HASH_BRANCH="feature/what#happened"
set_git "$(printf 'deadbeef\trefs/heads/%s' "$HASH_BRANCH")" 0
set_gh "" 0
if run_case encodes-hash 0 'a "#" in the branch name is percent-encoded before it reaches gh' "" "$HASH_BRANCH"; then
  want_file_contains encodes-hash "$GH_ARGS" "repos/$REPO/git/refs/heads/feature/what%23happened" \
    'the "#" segment is escaped to %23 — an unescaped "#" would be read as a URL fragment and
      dropped, along with everything after it, before the request is even sent' \
  && want_file_not_contains encodes-hash "$GH_ARGS" "what#happened" \
    'the literal unescaped branch name must not reach the request line at all' \
  && echo "ok: encodes-hash — a literal # is percent-encoded, not sent raw"
fi

# --- 8. git ls-remote itself fails (network, auth) — a real failure, and gh must never be dialed
# on top of an unknown remote state.
set_git "fatal: unable to access 'https://github.com/$REPO/': Could not resolve host" 1
set_gh "gh should not have been called" 99
if run_case ls-remote-fails 1 'git ls-remote failing is reported, and gh is never dialed on top of it' forbid_gh; then
  want_contains ls-remote-fails "git ls-remote --heads origin 'refs/heads/$BRANCH' failed" \
    'names the command that failed, not just "something went wrong" — and the FULL "refs/heads/…"
      pattern it actually ran, not the bare branch name' \
  && want_contains ls-remote-fails "Could not resolve host" \
    "carries git's own error text" \
  && echo "ok: ls-remote-fails — reported, gh never dialed"
fi

# --- 9. ls-remote is pinned to the exact ref, not a suffix match: `git ls-remote --heads origin
# <pattern>` treats a bare branch name as matching ANY refname it is a suffix of at a "/" boundary
# — verified live against a real bare repo during this PR's review — so an unrelated branch whose
# name this one's is the tail of would otherwise read as "still present". The fix passes the FULL
# "refs/heads/…" pattern, which git matches exactly; this case pins the request built, since the
# stub can't reproduce git's own suffix-matching behaviour.
set_git "" 0
set_gh "gh should not have been called" 99
if run_case ls-remote-uses-exact-ref 0 'the ls-remote call is pinned to the fully-qualified ref, not a suffix-matchable bare name' forbid_gh; then
  want_file_contains ls-remote-uses-exact-ref "$GIT_ARGS" "refs/heads/$BRANCH" \
    'ls-remote is invoked with the full "refs/heads/<branch>" pattern' \
  && echo "ok: ls-remote-uses-exact-ref — pinned to the fully-qualified ref"
fi

# --- 7. usage error: a script/prerequisite failure, distinct from every teardown outcome above —
# exit 2, never 0 or 1, so a caller can tell "called wrong" apart from "ran and something leaked".
out=$(PATH="$STUBS:$PATH" "$SCRIPT" 2>&1) && rc=0 || rc=$?
if [ "$rc" != 2 ]; then
  note_fail "usage — missing arguments must exit 2, got $rc: $out"
elif ! grep -qF 'usage:' <<<"$out"; then
  note_fail "usage — exit 2 but no usage line: $out"
else
  echo "ok: usage — missing arguments exit 2 with a usage line"
fi

# --- 10. the repository's own host (#514). `gh api` never infers a host, so on a GitHub Enterprise
# repository the DELETE reached github.com and the branch survived on the real remote. The seam is
# the gh stub's log: the GH_HOST each call ran under, and the endpoint it was asked for.
want_no_gh_call() {
  local name="$1" what="$2"
  if [ -s "$GH_LOG" ]; then
    note_fail "$name — $what
      gh was called: $(cat "$GH_LOG")"
    return 1
  fi
  return 0
}
REPO_KEEP="$REPO"
SCRIPT_KEEP="$SCRIPT"

# A HOST/ prefix names the host outright; only OWNER/REPO reaches the endpoint.
set_git "$(printf 'deadbeef\trefs/heads/%s' "$BRANCH")" 0
set_gh "" 0
: > "$GH_LOG"
REPO="ghe.example.com/acme/widgets"
if run_case ghe-prefix 0 'a HOST/OWNER/REPO slug deletes the branch on that host'; then
  want_stdout ghe-prefix deleted 'prints the exact word deleted' \
  && want_file_contains ghe-prefix "$GH_LOG" "GH_HOST=ghe.example.com ARGS: api -X DELETE repos/acme/widgets/git/refs/heads/$BRANCH" \
    'the DELETE runs under GH_HOST=ghe.example.com, against repos/acme/widgets/…' \
  && want_file_not_contains ghe-prefix "$GH_LOG" "repos/ghe.example.com" \
    'the host never leaks into the endpoint' \
  && echo "ok: ghe-prefix — DELETE repos/acme/widgets/… under GH_HOST=ghe.example.com"
fi

# A checkout whose origin is on a GHE host, given a bare OWNER/REPO: the origin's host is used.
set_git "$(printf 'deadbeef\trefs/heads/%s' "$BRANCH")" 0
set_gh "" 0
printf '%s\n' 'git@ghe.example.com:acme/widgets.git' > "$GIT_ORIGIN"
: > "$GH_LOG"
REPO="acme/widgets"
if GH_STUB_HOSTS=ghe.example.com run_case ghe-origin 0 'a checkout on a GHE host deletes the branch on that host'; then
  want_stdout ghe-origin deleted 'prints the exact word deleted' \
  && want_file_contains ghe-origin "$GH_LOG" "GH_HOST=ghe.example.com ARGS: api -X DELETE repos/acme/widgets/git/refs/heads/$BRANCH" \
    "the DELETE runs under the origin's host, GH_HOST=ghe.example.com" \
  && echo "ok: ghe-origin — the origin's GHE host reaches the DELETE"
fi
rm -f "$GIT_ORIGIN"

# A malformed slug is a usage error: exit 2, the slug named, gh never called.
set_git "$(printf 'deadbeef\trefs/heads/%s' "$BRANCH")" 0
set_gh "" 0
: > "$GH_LOG"
REPO="acme"
if run_case malformed-slug 2 'a one-segment slug is a usage error, exit 2'; then
  want_contains malformed-slug "malformed repository slug 'acme'" 'names the slug it refused' \
  && want_no_gh_call malformed-slug 'a malformed slug is refused before any gh call' \
  && echo "ok: malformed-slug — exit 2, the slug named, no gh call"
fi
REPO="$REPO_KEEP"

# The host helper is part of the install: without it the teardown refuses, naming the missing file,
# rather than deleting on gh's default host — the exact #514 failure.
NOHELPER="$STUBS/nohelper/skills/merge-pr/scripts"
mkdir -p "$NOHELPER"
cp "$SCRIPT" "$NOHELPER/remote-branch-teardown.sh"
SCRIPT="$NOHELPER/remote-branch-teardown.sh"
set_git "$(printf 'deadbeef\trefs/heads/%s' "$BRANCH")" 0
set_gh "" 0
: > "$GH_LOG"
if run_case missing-helper 2 'without its host helper the teardown refuses, exit 2'; then
  want_contains missing-helper "_shared/scripts/_gh-host.sh; reinstall the kit" 'names the missing helper' \
  && want_no_gh_call missing-helper 'refused before any gh call' \
  && echo "ok: missing-helper — exit 2, the missing helper named, no gh call"
fi
SCRIPT="$SCRIPT_KEEP"

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "remote-branch-teardown: FAILED"
  exit 1
fi
echo
echo "remote-branch-teardown: OK — already-gone is a no-op, a survivor gets deleted, a real"
echo "failure is reported, the delete_branch_on_merge race is tolerated, and bad input exits 2."
