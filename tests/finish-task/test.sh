#!/usr/bin/env bash
# Golden test for skills/implement-issue/scripts/finish-task.sh (#499): one call closes a task —
# commit through guarded-commit.sh, tick that task's boxes through tick-plan.sh, mirror them on
# the PR body, push through guarded-push.sh — in that order, with the refusal paths of the guards
# it composes still refusing.
#
# Real git (a bare remote + a clone), a `gh` stub on PATH that stores what it is sent and serves
# it back, so tick-plan.sh's read-back and the PR mirror are exercised rather than assumed.
set -euo pipefail
# A GH_HOST in the developer's or CI's shell would decide the host cases (#514) on its own.
unset GH_HOST

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
WORK=$(kit_scratch)
FINISH="$KIT_ROOT/skills/implement-issue/scripts/finish-task.sh"
fail() { echo "FAIL [$1]: $2"; exit 1; }

# --- the gh stub: an issue store, a PR store, a call log ------------------------------------------
# Each log line carries the GH_HOST the call ran under (#514). `gh auth token --hostname H`, the
# host helper's credential probe, succeeds only for a host listed in $GH_STUB_HOSTS.
export GH_ISSUE="$WORK/issue.md" GH_PR="$WORK/pr.md" GH_LOG="$WORK/gh.log"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "GH_HOST=${GH_HOST-<unset>} ARGS: $*" >> "$GH_LOG"
if [ "${1:-}" = auth ] && [ "${2:-}" = token ]; then
  host=""; prev=""
  for a in "$@"; do [ "$prev" = "--hostname" ] && host="$a"; prev="$a"; done
  case " ${GH_STUB_HOSTS:-} " in *" $host "*) echo "gho_stub_token_for_$host"; exit 0 ;; esac
  exit 1
fi
case "$*" in
  *"-X PATCH"*)
    f=""; prev=""; for a in "$@"; do [ "$prev" = "--input" ] && f="$a"; prev="$a"; done
    jq -r .body < "$f" > "$GH_ISSUE"; exit 0 ;;
  "api repos/"*"--jq .body")   cat "$GH_ISSUE" ;;
  # The body path and the PR mirror go through the tracker contract's github backend (#751):
  # `issue edit --body-file` / `issue view --json`, and `pr view --json`, answered as gh's JSON.
  "issue edit"*)
    f=""; prev=""; for a in "$@"; do [ "$prev" = "--body-file" ] && f="$a"; prev="$a"; done
    cp "$f" "$GH_ISSUE" ;;
  "issue view"*)
    jq -Rs '{number: 42, title: "t", state: "OPEN", url: "u", labels: [], body: .}' < "$GH_ISSUE" ;;
  "pr view"*)
    jq -Rs '{number: 7, title: "t", url: "u", state: "OPEN", isDraft: true, body: ., headRefName: "fix/42",
             baseRefName: "main", headRefOid: "x", author: {login: "a"}}' < "$GH_PR" ;;
  "pr edit"*)
    f=""; prev=""; for a in "$@"; do [ "$prev" = "--body-file" ] && f="$a"; prev="$a"; done
    cp "$f" "$GH_PR" ;;
  *) echo "stub: unexpected gh $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

cat > "$GH_ISSUE" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: the first slice

**Files:** create `a.txt`.

- [ ] **Step 1:** Write the failing test.
- [ ] **Step 2:** Make it pass.
- [ ] **Step 3:** Commit: `feat(x): first slice`

### Task 2: the second slice

**Files:** create `b.txt`.

- [ ] **Step 1:** Write the failing test.
- [ ] **Step 2:** Commit: `feat(x): second slice`
PLAN
printf 'Closes #42.\n\n### Plan\n- [ ] Task 1: the first slice\n- [ ] Task 2: the second slice\n' > "$GH_PR"

# --- real git: a bare remote and a clone on the task's branch --------------------------------------
git init -q --bare "$WORK/remote.git"
git -C "$WORK" clone -q "$WORK/remote.git" wt 2>/dev/null
WT="$WORK/wt"
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$WT" push -q origin HEAD:main 2>/dev/null
git -C "$WT" checkout -q -b fix/42
git -C "$WT" push -q -u origin fix/42 2>/dev/null
printf 'work\n' > "$WT/a.txt"

# ---------------------------------------------------------------------------------------------
echo "== 1. one call: commit, tick task 1 on the issue AND the PR, push =="
out=$("$FINISH" --repo o/r --issue 42 --task 1 --pr 7 --worktree "$WT" --branch fix/42 -c user.email=t@t -c user.name=t 2>&1) \
  || fail happy "expected exit 0, got $? — $out"
msg=$(git -C "$WT" log -1 --format=%s)
[ "$msg" = "feat(x): first slice" ] || fail happy-msg "commit message should come from Task 1's last step, got '$msg'"
[ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$WORK/remote.git" rev-parse fix/42)" ] || fail happy-push "remote fix/42 is not HEAD"
[ "$(grep -c '^- \[x\]' "$GH_ISSUE")" -eq 3 ] || fail happy-tick "issue: expected 3 ticked boxes, got $(grep -c '^- \[x\]' "$GH_ISSUE")"
grep -q '^- \[ \] \*\*Step 1:\*\* Write the failing test.$' "$GH_ISSUE" || fail happy-scope "Task 2's boxes must stay unticked on the issue"
grep -q '^- \[x\] Task 1: the first slice$' "$GH_PR" || fail happy-mirror "PR mirror: Task 1 line not ticked"
grep -q '^- \[ \] Task 2: the second slice$' "$GH_PR" || fail happy-mirror-scope "PR mirror: Task 2 line must stay unticked"
grep -q '^Closes #42' "$GH_PR" || fail happy-mirror-head "the PR body's head was lost in the mirror"
echo "  ok: committed '$msg', 3 boxes ticked on the issue, Task 1 line ticked on the PR, remote == HEAD, Task 2 untouched"

echo "== 2. re-run is idempotent: nothing recommitted, nothing re-ticked, exit 0 =="
before=$(git -C "$WT" rev-parse HEAD)
out=$("$FINISH" --repo o/r --issue 42 --task 1 --pr 7 --worktree "$WT" --branch fix/42 2>&1) || fail idem "expected exit 0, got $? — $out"
[ "$(git -C "$WT" rev-parse HEAD)" = "$before" ] || fail idem-commit "a second run created a commit"
grep -q 'already committed' <<<"$out" || fail idem-say "should say already committed: $out"
grep -q 'already ticked' <<<"$out"    || fail idem-tick "should say already ticked: $out"
echo "  ok: already committed, already ticked, no second write"

echo "== 3. a task the plan does not have: exit 65, nothing written anywhere =="
printf 'more\n' > "$WT/b.txt"
: > "$GH_LOG"; before=$(git -C "$WT" rev-parse HEAD)
rc=0; out=$("$FINISH" --repo o/r --issue 42 --task 9 --worktree "$WT" --branch fix/42 2>&1) || rc=$?
[ "$rc" -eq 65 ] || fail absent "expected exit 65, got $rc — $out"
[ "$(git -C "$WT" rev-parse HEAD)" = "$before" ] || fail absent-commit "a missing task still produced a commit"
grep -q 'PATCH\|pr edit\|issue edit' "$GH_LOG" && fail absent-write "a missing task still wrote to GitHub"
echo "  ok: refused by name, no commit, no write"

echo "== 4. the worktree is on another branch: guarded-commit refuses (2) BEFORE any tick =="
git -C "$WT" checkout -q -b elsewhere
: > "$GH_LOG"
rc=0; out=$("$FINISH" --repo o/r --issue 42 --task 2 --worktree "$WT" --branch fix/42 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail branch "expected guarded-commit's exit 2, got $rc — $out"
grep -q '^finish-task: commit:' <<<"$out" || fail branch-name "the failing stage must be named: $out"
grep -q 'PATCH\|issue edit' "$GH_LOG" && fail branch-order "the tick ran although the commit was refused"
grep -q '^- \[ \] \*\*Step 2:\*\* Commit: `feat(x): second slice`' "$GH_ISSUE" || fail branch-tick "Task 2 was ticked without a commit"
echo "  ok: commit refused, stage named, tick never ran"

echo "== 5. --dry-run writes nothing and names every stage =="
git -C "$WT" checkout -q fix/42
: > "$GH_LOG"
out=$("$FINISH" --repo o/r --issue 42 --task 2 --pr 7 --worktree "$WT" --branch fix/42 --dry-run 2>&1) || fail dry "expected exit 0, got $? — $out"
grep -q 'would commit' <<<"$out" && grep -q 'would flip 2 box' <<<"$out" && grep -q 'would push' <<<"$out" \
  || fail dry-say "dry-run must name the three stages: $out"
grep -q 'PATCH\|pr edit\|issue edit' "$GH_LOG" && fail dry-write "dry-run wrote to GitHub"
porcelain=$(git -C "$WT" status --porcelain)
grep -q 'b.txt' <<<"$porcelain" || fail dry-commit "dry-run committed the tree"
echo "  ok: three stages named, nothing written"

# --- the repository's own host (#514) -------------------------------------------------------------
# `gh api` never infers a host, and `gh -R OWNER/REPO` takes gh's default one, so on a GitHub
# Enterprise repository every call below reached github.com. The seam is the stub's log: the
# GH_HOST each call ran under, and what it was asked for.
has_call() {  # has_call <name> <ERE> — the gh log holds a line matching <ERE>
  grep -qE -- "$2" "$GH_LOG" || fail "$1" "gh was never called as /$2/ — log: $(cat "$GH_LOG")"
}

echo "== 6. a checkout on a GHE host: the read, the tick-plan it spawns, and the PR mirror all reach it =="
CO_GHE="$WORK/co-ghe"
git init -q "$CO_GHE"
git -C "$CO_GHE" remote add origin git@ghe.example.com:acme/widgets.git
: > "$GH_LOG"
out=$(cd "$CO_GHE" && GH_STUB_HOSTS=ghe.example.com "$FINISH" --repo acme/widgets --issue 42 --task 2 --pr 7 \
        --worktree "$WT" --branch fix/42 -c user.email=t@t -c user.name=t 2>&1) \
  || fail ghe-origin "expected exit 0, got $? — $out"
has_call ghe-origin '^GH_HOST=ghe\.example\.com ARGS: issue view 42 --repo acme/widgets --json '
has_call ghe-origin '^GH_HOST=ghe\.example\.com ARGS: issue edit 42 --repo acme/widgets --body-file '
has_call ghe-origin '^GH_HOST=ghe\.example\.com ARGS: pr view 7 --repo acme/widgets '
has_call ghe-origin '^GH_HOST=ghe\.example\.com ARGS: pr edit 7 --repo acme/widgets '
grep -qE '^GH_HOST=<unset> ARGS: (api|pr|issue) ' "$GH_LOG" && fail ghe-origin-all "a call ran without the host: $(cat "$GH_LOG")"
echo "  ok: read, PATCH, read-back, pr view and pr edit all ran under GH_HOST=ghe.example.com"

echo "== 7. --repo HOST/OWNER/REPO: OWNER/REPO reaches every call, and tick-plan inherits the host =="
# Run from a checkout with no origin, so the spawned tick-plan, handed a bare OWNER/REPO, has no
# host of its own to find: only the one finish-task exported can reach its PATCH.
printf '\n### Task 3: the third slice\n\n- [ ] **Step 1:** Commit: `feat(x): third slice`\n' >> "$GH_ISSUE"
printf '%s\n' '- [ ] Task 3: the third slice' >> "$GH_PR"
CO_NONE="$WORK/co-none"
git init -q "$CO_NONE"
: > "$GH_LOG"
out=$(cd "$CO_NONE" && "$FINISH" --repo ghe.example.com/acme/widgets --issue 42 --task 3 --pr 7 \
        --worktree "$WT" --branch fix/42 2>&1) \
  || fail ghe-prefix "expected exit 0, got $? — $out"
has_call ghe-prefix '^GH_HOST=ghe\.example\.com ARGS: issue edit 42 --repo acme/widgets --body-file '
has_call ghe-prefix '^GH_HOST=ghe\.example\.com ARGS: pr edit 7 --repo acme/widgets '
grep -qE '^GH_HOST=<unset> ARGS: (api|pr|issue) ' "$GH_LOG" && fail ghe-prefix-all "a call ran without the host: $(cat "$GH_LOG")"
grep -q 'ghe\.example\.com/acme' "$GH_LOG" && fail ghe-prefix-slug "the host leaked into a repository argument: $(cat "$GH_LOG")"
echo "  ok: every call got acme/widgets under GH_HOST=ghe.example.com, the spawned tick-plan's PATCH included"

echo "== 8. a malformed --repo: exit 64, the slug named, gh never called =="
: > "$GH_LOG"
rc=0; out=$("$FINISH" --repo acme --issue 42 --task 2 --worktree "$WT" --branch fix/42 --dry-run 2>&1) || rc=$?
[ "$rc" -eq 64 ] || fail malformed "expected exit 64, got $rc — $out"
grep -qF "malformed repository slug 'acme'" <<<"$out" || fail malformed-say "stderr must name the slug: $out"
[ ! -s "$GH_LOG" ] || fail malformed-call "gh was called: $(cat "$GH_LOG")"
echo "  ok: exit 64, slug named, no gh call"

echo "== 9. without its host helper: exit 64, the missing file named, gh never called =="
NOHELPER="$WORK/nohelper/skills/implement-issue/scripts"
mkdir -p "$NOHELPER"
cp "$FINISH" "$NOHELPER/finish-task.sh"
: > "$GH_LOG"
rc=0; out=$(bash "$NOHELPER/finish-task.sh" --repo o/r --issue 42 --task 2 --worktree "$WT" --branch fix/42 --dry-run 2>&1) || rc=$?
[ "$rc" -eq 64 ] || fail missing-helper "expected exit 64, got $rc — $out"
grep -qF '_shared/scripts/_gh-host.sh; reinstall the kit' <<<"$out" || fail missing-helper-say "stderr must name the helper: $out"
[ ! -s "$GH_LOG" ] || fail missing-helper-call "gh was called: $(cat "$GH_LOG")"
echo "  ok: exit 64, the missing helper named, no gh call"

echo "== 10. a task's own **Files:** line: create is staged, an unrelated untracked file is left out and named (#536) =="
printf '\n### Task 4: stage only its own files\n\n**Files:** create `new.sh`; modify `README.md`.\n\n- [ ] **Step 1:** Commit: `feat(x): fourth slice`\n' >> "$GH_ISSUE"
printf 'readme\n' > "$WT/README.md"
git -C "$WT" add README.md
git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m "chore: add README"
printf '#!/bin/sh\necho hi\n' > "$WT/new.sh"
printf 'readme v2\n' >> "$WT/README.md"
printf 'scratch\n' > "$WT/stray.md"
: > "$GH_LOG"
out=$("$FINISH" --repo o/r --issue 42 --task 4 --worktree "$WT" --branch fix/42 -c user.email=t@t -c user.name=t 2>&1) \
  || fail files "expected exit 0, got $? — $out"
committed=$(git -C "$WT" show --name-only --format= HEAD)
grep -qx 'new.sh' <<<"$committed" || fail files-create "new.sh (declared create) missing from the commit: $committed"
grep -qx 'README.md' <<<"$committed" || fail files-modify "README.md (tracked edit) missing from the commit: $committed"
grep -qx 'stray.md' <<<"$committed" && fail files-stray "stray.md (undeclared) must not be in the commit: $committed"
grep -qF 'finish-task: commit: left untracked: stray.md' <<<"$out" || fail files-say "stderr must name stray.md: $out"
[ -e "$WT/stray.md" ] || fail files-left "stray.md should remain on disk, merely uncommitted"
echo "  ok: new.sh and README.md committed, stray.md left untracked and named on stderr"

echo "== 11. idempotent re-run: an unrelated stray on disk does not turn 'already committed' into a hard failure (#536) =="
before=$(git -C "$WT" rev-parse HEAD)
out=$("$FINISH" --repo o/r --issue 42 --task 4 --worktree "$WT" --branch fix/42 -c user.email=t@t -c user.name=t 2>&1) \
  || fail files-idem "expected exit 0, got $? — $out"
[ "$(git -C "$WT" rev-parse HEAD)" = "$before" ] || fail files-idem-commit "a re-run with a stray present created a commit"
grep -qF 'already committed' <<<"$out" || fail files-idem-say "should say already committed: $out"
echo "  ok: re-run with stray.md still on disk stays a no-op, no hard failure"

echo "== 12. a (new) marker on a non-create verb is read the same as create (#536) =="
printf '\n### Task 5: recognize the (new) marker\n\n**Files:** test `new_test.sh` (new).\n\n- [ ] **Step 1:** Commit: `feat(x): fifth slice`\n' >> "$GH_ISSUE"
printf '#!/bin/sh\necho test\n' > "$WT/new_test.sh"
: > "$GH_LOG"
out=$("$FINISH" --repo o/r --issue 42 --task 5 --worktree "$WT" --branch fix/42 -c user.email=t@t -c user.name=t 2>&1) \
  || fail newmark "expected exit 0, got $? — $out"
committed=$(git -C "$WT" show --name-only --format= HEAD)
grep -qx 'new_test.sh' <<<"$committed" || fail newmark-create "new_test.sh (marked (new)) missing from the commit: $committed"
grep -qF 'left untracked: new_test.sh' <<<"$out" && fail newmark-say "new_test.sh should not be reported as a stray: $out"
echo "  ok: a (new)-marked path on a non-create verb is staged like a declared create"

echo "== 13. an undeclared untracked file with no tracked edits: named on stderr, tick still lands, no hard failure (#536) =="
printf '\n### Task 6: no Files line at all\n\n- [ ] **Step 1:** Commit: `feat(x): sixth slice`\n' >> "$GH_ISSUE"
printf 'undeclared\n' > "$WT/undeclared.txt"
before=$(git -C "$WT" rev-parse HEAD)
: > "$GH_LOG"
out=$("$FINISH" --repo o/r --issue 42 --task 6 --worktree "$WT" --branch fix/42 -c user.email=t@t -c user.name=t 2>&1) \
  || fail undeclared "expected exit 0, got $? — $out"
[ "$(git -C "$WT" rev-parse HEAD)" = "$before" ] || fail undeclared-commit "an undeclared file must not be committed as a task's own work"
grep -qF 'left untracked: undeclared.txt' <<<"$out" || fail undeclared-say "stderr must name undeclared.txt: $out"
grep -qF 'already committed' <<<"$out" || fail undeclared-idem "no tracked/declared work: should say already committed: $out"
grep -q '^- \[x\] \*\*Step 1:\*\* Commit: `feat(x): sixth slice`' "$GH_ISSUE" || fail undeclared-tick "Task 6 should still be ticked even with nothing to commit"
[ -e "$WT/undeclared.txt" ] || fail undeclared-left "undeclared.txt should remain on disk"
echo "  ok: undeclared file left untracked and named, task still ticked, no hard failure"

echo "== 14. reached through a symlink to the script itself (#531): resolves the real kit root, not the symlink's own directory =="
SYMROOT="$WORK/symlinked/skills/implement-issue/scripts"
mkdir -p "$SYMROOT"
ln -s "$FINISH" "$SYMROOT/finish-task.sh"
: > "$GH_LOG"
rc=0; out=$(bash "$SYMROOT/finish-task.sh" --repo acme --issue 42 --task 2 --worktree "$WT" --branch fix/42 --dry-run 2>&1) || rc=$?
[ "$rc" -eq 64 ] || fail symlink "expected exit 64 (malformed slug, same as a direct run), got $rc — $out"
grep -qF "malformed repository slug 'acme'" <<<"$out" || fail symlink-say "the real _gh-host.sh must load and validate through the symlink: $out"
grep -qF 'cannot load' <<<"$out" && fail symlink-broken "refused to load _gh-host.sh even though it exists at the real kit root: $out"
[ ! -s "$GH_LOG" ] || fail symlink-call "gh was called for a malformed slug: $(cat "$GH_LOG")"
echo "  ok: reached through a symlinked script, the real kit root (not the symlink's) is resolved"

echo "== 15. a comment-hosted plan on GitLab is refused by name, nothing sent (#751) =="
GL_WT="$WORK/gl-wt"
mkdir -p "$GL_WT/.claude/skills"
git init -q "$GL_WT"
printf '%s\n' '# Repo profile' '' '## Tracker' '- **Tracker:** gitlab (gitlab.com)' \
  > "$GL_WT/.claude/skills/repo-profile.md"
export GLAB_LOG="$WORK/glab.log"; : > "$GLAB_LOG"
printf '#!/usr/bin/env bash\necho "$*" >> "$GLAB_LOG"\nexit 1\n' > "$WORK/bin/glab"; chmod +x "$WORK/bin/glab"
: > "$GH_LOG"
rc=0; out=$("$FINISH" --repo g/p --issue 42 --task 2 --comment-id 5 --worktree "$GL_WT" --branch fix/42 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail gitlab-comment "a comment plan on GitLab was not refused — $out"
grep -qF 'a plan hosted in a comment is a GitHub-only shape (#750)' <<<"$out" || fail gitlab-comment-say "the refusal must name the shape: $out"
[ ! -s "$GH_LOG" ] && [ ! -s "$GLAB_LOG" ] || fail gitlab-comment-call "a host was called: $(cat "$GH_LOG" "$GLAB_LOG")"
echo "  ok: refused by name, no gh call, no glab call"


echo "== 16. a GitLab subgroup slug reaches glab as one full project path (#795) =="
: > "$GLAB_LOG"
rc=0; out=$(PATH="$WORK/bin:$PATH" bash "$FINISH" --repo group/subgroup/project --issue 42 --task 1 --worktree "$GL_WT" --branch fix/42 2>&1) || rc=$?
grep -qF 'projects/group%2Fsubgroup%2Fproject' "$GLAB_LOG" || fail subgroup "glab never got the full project path: $(cat "$GLAB_LOG") — $out"
grep -qF 'malformed' <<<"$out" && fail subgroup-slug "the slug was refused: $out"
echo "  ok: group/subgroup/project forwarded unchanged"
echo "finish-task golden test: all cases behaved as specified"
