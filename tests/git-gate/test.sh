#!/usr/bin/env bash
# Golden test for the git write-gate — the PreToolUse/Bash hook that routes the three guarded writes
# through the guards and refuses the discards that produced #26 and #280.
#
# Written fail-path-first, the tests/roseline/test.sh shape: a gate whose PASS path is the only one
# exercised proves nothing, and a gate that fails CLOSED anywhere would deadlock every repository
# the plugin is installed in but never used with (ADR 0002). So every case drives the real script
# over a synthetic PreToolUse payload — that payload is the gate's entire input contract — and the
# allow half of the matrix is as long as the deny half on purpose.
#
# NOTHING here runs a destructive git command. The deny cases are payload strings; the scratch
# repositories exist only so the profile probe has something real to answer about.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
WORK=$(kit_scratch)
kit_guard kit_guard_samples_unchanged

GATE="$KIT/hooks/git-write-gate.sh"
[ -x "$GATE" ] || { echo "FAIL: $GATE missing or not executable"; exit 1; }

# The scratch repositories the probe answers about. mktemp -d, NOT a counter: `n=$((n+1))` inside a
# $(...) helper increments a subshell's copy and every "fresh" repo would be the same directory —
# the trap tests/_lib.sh documents and tests/roseline/test.sh already tripped over.
#
# `git init` only; nothing is ever committed and no working tree is ever mutated. The probe reads
# `rev-parse --show-toplevel` plus one `[ -f ]`, which is all these fixtures have to satisfy.
profile_repo() {
  local d; d=$(mktemp -d "$WORK/prof.XXXXXX")
  git -C "$d" init -q >/dev/null 2>&1
  mkdir -p "$d/.claude/skills"
  : > "$d/.claude/skills/repo-profile.md"
  printf '%s' "$d"
}
plain_repo() {
  local d; d=$(mktemp -d "$WORK/plain.XXXXXX")
  git -C "$d" init -q >/dev/null 2>&1
  : > "$d/README.md"
  printf '%s' "$d"
}

# A profiled repo carrying REAL uncommitted state, for #560's named-path-checkout probe — the one
# fixture in this file whose working tree is deliberately dirty:
#   src/Clean.cs        committed, untouched.
#   src/Dirty.cs         committed, then edited UNSTAGED — worktree differs from the index.
#   src/StagedClean.cs  committed, then edited AND staged — index differs from HEAD, but the
#                       worktree matches the index (porcelain's own 2nd/worktree column reads
#                       " "), so a bare `git checkout -- <path>` (index -> worktree, no ref) is a
#                       genuine no-op against it — nothing to discard (#560 review).
dirty_repo() {
  local d; d=$(mktemp -d "$WORK/dirty.XXXXXX")
  git -C "$d" init -q >/dev/null 2>&1
  mkdir -p "$d/.claude/skills" "$d/src"
  : > "$d/.claude/skills/repo-profile.md"
  printf 'clean\n' > "$d/src/Clean.cs"
  printf 'clean\n' > "$d/src/Dirty.cs"
  printf 'v1\n' > "$d/src/StagedClean.cs"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" -c user.email=t@t -c user.name=t commit -q -m seed >/dev/null 2>&1
  printf 'edited, uncommitted\n' > "$d/src/Dirty.cs"
  printf 'v2\n' > "$d/src/StagedClean.cs"
  git -C "$d" add src/StagedClean.cs >/dev/null 2>&1
  printf '%s' "$d"
}

# A PATH holding exactly what the gate shells out to, plus whichever stubs are named — built by
# NAMING the tools rather than by subtracting one from $PATH, so the "absent" case holds on every
# host. Every extra argument becomes an empty executable.
shim_path() { # $1 destination dir; $2… stub names
  local d="$1" c p; shift
  mkdir -p "$d"
  for c in bash cat jq awk git tr printf sed; do
    p=$(command -v "$c" 2>/dev/null) || continue
    ln -s "$p" "$d/$c" 2>/dev/null || true
  done
  for c in "$@"; do printf '#!/bin/sh\nexit 0\n' > "$d/$c"; chmod +x "$d/$c"; done
  printf '%s' "$d"
}

pay() { # $1 tool  $2 command  $3 cwd
  jq -nc --arg t "$1" --arg c "$2" --arg d "$3" \
    '{session_id:"gitgate", cwd:$d, tool_name:$t, tool_input:{command:$c}}'
}

pay_sub() { # pay's arguments; the same payload as a sub-agent's call (Claude Code adds agent_id)
  pay "$@" | jq -c '. + {agent_id:"agent-test"}'
}

# Drives the gate with a synthetic payload. Asserts the exit status, the decision, and — when
# denying — that the reason names the replacement.
# $1 name  $2 expected ("deny"|"pass")  $3 substring the reason must contain  $4 payload
# $5 optional PATH  $6 optional GIT_GATE value  $7 optional CLAUDE_PLUGIN_ROOT value
#
# $7 empty means UNSET, never inherited (#512): the deny text now spells each guard from
# CLAUDE_PLUGIN_ROOT when the file exists there, so a row that inherited whatever root the shell
# running this suite exports would pass or fail on the host rather than on the gate.
verdict() {
  local name="$1" want="$2" want_msg="$3" payload="$4" gate_path="${5:-$PATH}" sw="${6:-}" root="${7:-}"
  local out decision rc=0
  local -a envv
  envv=(PATH="$gate_path")
  if [ -n "$sw" ]; then envv+=(GIT_GATE="$sw"); fi
  if [ -n "$root" ]; then
    out=$(printf '%s' "$payload" | env "${envv[@]}" CLAUDE_PLUGIN_ROOT="$root" bash "$GATE" 2>/dev/null) || rc=$?
  else
    out=$(printf '%s' "$payload" | env -u CLAUDE_PLUGIN_ROOT "${envv[@]}" bash "$GATE" 2>/dev/null) || rc=$?
  fi
  # Exit status is half the PreToolUse contract — a non-zero exit blocks the tool regardless of
  # stdout, so a regression that turned a fail-open path into `exit 2` would be scored "pass" here
  # while blocking every Bash call in production. Matt's script is exactly that shape (`exit 2`).
  [ "$rc" -eq 0 ] || { echo "FAIL [$name]: gate exited $rc; its contract is always exit 0"; exit 1; }
  if [ -z "$out" ]; then decision="pass"; else
    decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null || echo malformed)
  fi
  if [ "$decision" != "$want" ]; then
    echo "FAIL [$name]: expected $want, got $decision"; echo "$out"; exit 1
  fi
  if [ -n "$want_msg" ]; then
    # Herestring, not a pipe into `grep -q` (#391): `jq` can still be writing when the match
    # closes the read end.
    reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
    grep -qF -e "$want_msg" <<<"$reason" || { echo "FAIL [$name]: reason lacks '$want_msg'"; echo "$out"; exit 1; }
      # `-e`, not a bare argument: half the replacements this suite asserts start with `--`
      # (`--force-with-lease`), and grep would read those as its own options.
  fi
  echo "ok: $name -> $decision"
}

PROF=$(profile_repo); PLAIN=$(plain_repo); DIRTY=$(dirty_repo)
[ "$PROF" != "$PLAIN" ] || { echo "FAIL: fixture helpers returned the same directory"; exit 1; }

# ------------------------------------------------------- 1. the deny rows, in a profiled repo (D)
verdict "D1  checkout <ref> -- ."      deny "checkout -- <path>" "$(pay Bash 'git checkout main -- .' "$PROF")"
verdict "D2  checkout ."               deny "checkout -- <path>" "$(pay Bash 'git checkout .' "$PROF")"
verdict "D3  restore --staged --worktree ." deny "git restore <path>" "$(pay Bash 'git restore --staged --worktree .' "$PROF")"
verdict "D4  reset --hard"             deny "git reset --keep"   "$(pay Bash 'git reset --hard HEAD~1' "$PROF")"
verdict "D5  clean -fd"                deny "git clean -n"       "$(pay Bash 'git clean -fd' "$PROF")"
verdict "D6  push --force"             deny "--force-with-lease" "$(pay Bash 'git push --force origin main' "$PROF")"
verdict "D7  bare commit"              deny "guarded-commit.sh"  "$(pay Bash 'git commit -m wip' "$PROF")"
verdict "D8  bare push"                deny "guarded-push.sh"    "$(pay Bash 'git push' "$PROF")"
verdict "D9  -c option skipping"       deny "guarded-commit.sh" \
  "$(pay Bash 'git -c user.email=x -c user.name=y commit -m x' "$PROF")"
verdict "D10 the write is segment 2"   deny "git reset --keep"   "$(pay Bash 'cd sub && git reset --hard' "$PROF")"
# The `-C` path names the repository the command acts on, so it outranks the payload's cwd: a push
# into a profiled repo is that repo's push no matter where the shell happens to be standing.
verdict "D11 -C path outranks cwd"     deny "guarded-push.sh"    "$(pay Bash "git -C $PROF push" "$PLAIN")"
verdict "D12 bare merge"               deny "guarded-merge.sh"   "$(pay Bash 'git merge origin/main' "$PROF")"
verdict "D13 clean --force"            deny "git clean -n"       "$(pay Bash 'git clean --force -d' "$PROF")"
verdict "D14 push -f"                  deny "--force-with-lease" "$(pay Bash 'git push -f' "$PROF")"

# ------------------------------------------------ 1b. meaning, not spelling (#373)
# Each of these is the SAME whole-tree discard as a row above, typed differently — a `./` for `.`,
# a bundled `-fq` for `-f`, a `-note` file name after `--` — and every one of them measured as
# allowed before the arms read a normalised argv. #26's originating incident was literally
# `git checkout <ref> -- .`; `git checkout HEAD -- ./` sailing through was that class, not a nit.
verdict "D15 checkout ./"              deny "checkout -- <path>" "$(pay Bash 'git checkout ./' "$PROF")"
verdict "D16 checkout HEAD -- ./"      deny "checkout -- <path>" "$(pay Bash 'git checkout HEAD -- ./' "$PROF")"
verdict "D17 checkout -fq (bundled)"   deny "checkout -- <path>" "$(pay Bash 'git checkout -fq main' "$PROF")"
verdict "D18 switch -fc (bundled)"     deny "checkout -- <path>" "$(pay Bash 'git switch -fc newb' "$PROF")"
verdict "D19 restore ./"               deny "git restore <path>" "$(pay Bash 'git restore ./' "$PROF")"
verdict "D20 clean -fd -- -note"       deny "git clean -n"       "$(pay Bash 'git clean -fd -- -note' "$PROF")"
verdict "D21 checkout -- :/"           deny "checkout -- <path>" "$(pay Bash 'git checkout -- :/' "$PROF")"

# ------------------------------------ 1c. the replacement is named by absolute path (#512)
# A denial is the one channel shown to reach a dispatched sub-agent — #414's worker quoted it word
# for word — and a kit-relative `skills/…` spelling resolves only when the cwd IS the kit's own
# checkout. In a consumer repository it names nothing: agents guessed the kit's path five times in
# four sessions, and the last miss ended in a raw `gh pr merge`. With CLAUDE_PLUGIN_ROOT set, each
# reason carries the absolute path. Every expected value below is built from $KIT by hand, never
# recomputed through the gate's own helper — that would agree with any bug in it.
EMPTY_ROOT=$(mktemp -d "$WORK/empty-root.XXXXXX")
verdict "K1  commit names guarded-commit.sh by absolute path" \
  deny "$KIT/skills/implement-issue/scripts/guarded-commit.sh" \
  "$(pay Bash 'git commit -m x' "$PROF")" "$PATH" "" "$KIT"
verdict "K2  push names guarded-push.sh by absolute path" \
  deny "$KIT/skills/implement-issue/scripts/guarded-push.sh" \
  "$(pay Bash 'git push' "$PROF")" "$PATH" "" "$KIT"
verdict "K3  merge names guarded-merge.sh by absolute path" \
  deny "$KIT/skills/implement-issue/scripts/guarded-merge.sh" \
  "$(pay Bash 'git merge feature' "$PROF")" "$PATH" "" "$KIT"
verdict "K4  reset --hard names make-worktree.sh by absolute path" \
  deny "$KIT/skills/implement-issue/scripts/make-worktree.sh" \
  "$(pay Bash 'git reset --hard' "$PROF")" "$PATH" "" "$KIT"
# A root that does not hold the guard — a plugin cache an upgrade emptied — and no root at all both
# fall back to the kit-relative spelling. Never an absolute path that does not exist.
verdict "K5  a root lacking the guard keeps the kit-relative spelling" \
  deny 'Use `skills/implement-issue/scripts/guarded-commit.sh' \
  "$(pay Bash 'git commit -m x' "$PROF")" "$PATH" "" "$EMPTY_ROOT"
verdict "K6  no root keeps the kit-relative spelling" \
  deny 'Use `skills/implement-issue/scripts/guarded-commit.sh' \
  "$(pay Bash 'git commit -m x' "$PROF")"
# ...and the absence half, which verdict() cannot express: neither reason names an absolute path.
reason_for() { # $1 payload  $2 CLAUDE_PLUGIN_ROOT ("" = unset)
  if [ -n "$2" ]; then
    printf '%s' "$1" | env CLAUDE_PLUGIN_ROOT="$2" bash "$GATE" 2>/dev/null
  else
    printf '%s' "$1" | env -u CLAUDE_PLUGIN_ROOT bash "$GATE" 2>/dev/null
  fi | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'
}
for c in 'git commit -m x' 'git push' 'git push --force origin main' 'git merge feature' \
         'git reset --hard' 'gh pr merge 12'; do
  r=$(reason_for "$(pay Bash "$c" "$PROF")" "$EMPTY_ROOT")
  case "$r" in ''|*"$EMPTY_ROOT"*)
    echo "FAIL [K5 $c]: under a root holding no guard the reason is empty or names $EMPTY_ROOT: $r"; exit 1 ;; esac
  case "$r" in *'`skills/'*) ;;
    *) echo "FAIL [K5 $c]: under a root holding no guard the reason lacks the kit-relative spelling: $r"; exit 1 ;; esac
  r=$(reason_for "$(pay Bash "$c" "$PROF")" "")
  case "$r" in ''|*"$KIT/skills/"*)
    echo "FAIL [K6 $c]: with no root the reason is empty or names an absolute path: $r"; exit 1 ;; esac
done
echo "ok: K5/K6 every guard-naming denial keeps the kit-relative spelling where the guard does not exist"
verdict "K7  a forced push names guarded-push.sh by absolute path" \
  deny "$KIT/skills/implement-issue/scripts/guarded-push.sh" \
  "$(pay Bash 'git push --force origin main' "$PROF")" "$PATH" "" "$KIT"
# A root holding whitespace is quoted, so the command the reason names still pastes as one word.
SPACED="$WORK/root with space"
mkdir -p "$SPACED/skills/merge-pr/scripts"; : > "$SPACED/skills/merge-pr/scripts/guarded-pr-merge.sh"
verdict "K8  a root with a space is quoted" \
  deny "\"$SPACED/skills/merge-pr/scripts/guarded-pr-merge.sh\"" \
  "$(pay Bash 'gh pr merge 12' "$PROF")" "$PATH" "" "$SPACED"

# ------------------------------------------------------------ 1d. a raw `gh pr merge` (#512)
# #326 left `gh` out of scope on the premise that `gh pr merge` "is already guarded by
# guarded-pr-merge.sh" — true only for an agent that can FIND the guard. Session 62c8dcf7 measured
# one that could not: it ran the raw command, and the gate's `*git*` pre-filter let it through
# without reading a word. The allow rows come FIRST, so a gate without the arm shows them green and
# stops on G1. (GA/G, not H: H1–H7 are the heredoc rows below.)
verdict "GA1 gh pr merge in an unprofiled repo" pass "" "$(pay Bash 'gh pr merge 12' "$PLAIN")"
verdict "GA2 GIT_GATE=off gh pr merge"        pass "" "$(pay Bash 'GIT_GATE=off gh pr merge 12' "$PROF")"
verdict "GA3 the guard itself"                pass "" \
  "$(pay Bash '"$KIT/skills/merge-pr/scripts/guarded-pr-merge.sh" 12 -- --squash' "$PROF")"
verdict "GA4 gh pr view"                      pass "" "$(pay Bash 'gh pr view 12' "$PROF")"
verdict "GA5 gh pr checks"                    pass "" "$(pay Bash 'gh pr checks 12' "$PROF")"
verdict "GA6 gh pr list"                      pass "" "$(pay Bash 'gh pr list --state open' "$PROF")"
verdict "GA7 inside a double-quoted string"   pass "" "$(pay Bash 'echo "gh pr merge 12"' "$PROF")"
verdict "GA8 git log, then gh pr view"        pass "" "$(pay Bash 'git log --oneline -1 && gh pr view 12' "$PROF")"

verdict "G1  gh pr merge --squash --delete-branch" deny "guarded-pr-merge.sh" \
  "$(pay Bash 'gh pr merge 12 --squash --delete-branch' "$PROF")"
verdict "G2  gh pr merge -R o/r"              deny "guarded-pr-merge.sh" "$(pay Bash 'gh pr merge -R o/r 12 --squash' "$PROF")"
verdict "G3  the merge is segment 2"          deny "guarded-pr-merge.sh" "$(pay Bash 'cd sub && gh pr merge 12' "$PROF")"
verdict "G4  gh by absolute path"             deny "guarded-pr-merge.sh" "$(pay Bash '/opt/homebrew/bin/gh pr merge 12' "$PROF")"
verdict "G5  names guarded-pr-merge.sh by absolute path" \
  deny "$KIT/skills/merge-pr/scripts/guarded-pr-merge.sh" \
  "$(pay Bash 'gh pr merge 12 --squash --delete-branch' "$PROF")" "$PATH" "" "$KIT"
verdict "G6  an option between pr and merge"  deny "guarded-pr-merge.sh" "$(pay Bash 'gh pr -R o/r merge 12' "$PROF")"
verdict "G7  GIT_GATE=on forces past the probe" deny "guarded-pr-merge.sh" \
  "$(pay Bash 'gh pr merge 12' "$PLAIN")" "$PATH" on
verdict "G8  the escape names the gh spelling" deny 'GIT_GATE=off gh' "$(pay Bash 'gh pr merge 12' "$PROF")"
# The probe follows `cd` for gh exactly as for git (A40/D29). G3's `sub` never exists, so these two
# are what prove the arm reads the directory the walk moved to.
verdict "GA9 cd into a guard-less repo, then gh pr merge" pass "" "$(pay Bash "cd $PLAIN && gh pr merge 12" "$PROF")"
verdict "G9  cd INTO a profiled repo, then gh pr merge" deny "guarded-pr-merge.sh" \
  "$(pay Bash "cd $PROF && gh pr merge 12" "$PLAIN")"
# A `git init` earlier on the line makes no PR mergeable: the gh arm does not inherit fresh_init.
verdict "G10 git init <path> does not switch the arm off" deny "guarded-pr-merge.sh" \
  "$(pay Bash 'git init scratch-x && gh pr merge 12 --squash' "$PROF")"
verdict "G11 gh pr --repo o/r merge"          deny "guarded-pr-merge.sh" "$(pay Bash 'gh pr --repo o/r merge 12' "$PROF")"
verdict "G12 gh pr --repo=o/r merge"          deny "guarded-pr-merge.sh" "$(pay Bash 'gh pr --repo=o/r merge 12' "$PROF")"
# G13 — the incident itself: session 62c8dcf7's "look for the guard, else merge raw" line. It names
# the guard in its else-branch, which is why guarded-pr-merge.sh is off the whole-line allowlist.
verdict "G13 the 62c8dcf7 fallback line"      deny "guarded-pr-merge.sh" \
  "$(pay Bash 'SKILLS_DIR=/nowhere/.claude/skills; if [ ! -d "$SKILLS_DIR" ]; then echo "Guarded script not found, using gh pr merge directly"; gh pr merge 1340 --squash --delete-branch; else "$SKILLS_DIR/guarded-pr-merge.sh" 1340 -- --squash --delete-branch; fi' "$PROF")"
# ...while a line that calls the guard beside a read-only gh still passes — judged, not allowlisted.
verdict "GA10 gh pr checks, then the guard"   pass "" \
  "$(pay Bash 'gh pr checks 12 --watch && "$KIT/skills/merge-pr/scripts/guarded-pr-merge.sh" 12 -- --squash' "$PROF")"
verdict "GA11 --disable-auto merges nothing"  pass "" "$(pay Bash 'gh pr merge --disable-auto 12' "$PROF")"
verdict "GA12 gh issue"                       pass "" "$(pay Bash 'gh issue view 12' "$PROF")"
# The REST merge endpoint is out of scope (#512): recorded as allowed, not gated.
verdict "GA13 gh api … /merge (out of scope)" pass "" "$(pay Bash 'gh api -X PUT repos/o/r/pulls/12/merge' "$PROF")"
# The gh denial states its own cause and its own escape; a git denial does not advertise gh's.
r=$(reason_for "$(pay Bash 'gh pr merge 12' "$PROF")" "")
case "$r" in *'#26 and #280'*) echo "FAIL [G14]: the gh denial claims the #26/#280 cause: $r"; exit 1 ;; esac
r=$(reason_for "$(pay Bash 'git commit -m x' "$PROF")" "")
case "$r" in *'GIT_GATE=off gh'*) echo "FAIL [G14]: a git denial advertises the gh escape: $r"; exit 1 ;; esac
echo "ok: G14 each denial names its own cause and its own escape"

# ------------------------------------------------- 1e. -R/GH_REPO/URL retarget denies (#533)
# judge_gh's probe answers only for $eff_dir (the payload's cwd, or wherever a followed `cd`
# moved it) — it has no way to tell whether `-R`/`GH_REPO`/a URL points at a repo that IS profiled.
# Resolving that target is out of scope (the issue's own stated assumption); denying outright,
# regardless of cwd, is the safe default instead — so each of these denies from an UNPROFILED cwd,
# where the unadorned `gh pr merge 12` of GA1 passes.
verdict "RT1 -R from an unprofiled cwd"        deny "guarded-pr-merge.sh" \
  "$(pay Bash 'gh pr merge -R owner/profiled-repo 12 --squash' "$PLAIN")"
verdict "RT2 GH_REPO= from an unprofiled cwd"  deny "guarded-pr-merge.sh" \
  "$(pay Bash 'GH_REPO=owner/profiled-repo gh pr merge 12' "$PLAIN")"
verdict "RT3 a pull URL from an unprofiled cwd" deny "guarded-pr-merge.sh" \
  "$(pay Bash 'gh pr merge https://github.com/owner/profiled-repo/pull/12' "$PLAIN")"
# ...and the same three from a PROFILED cwd, so the fix is proven additive rather than a
# probe-bypass regression: G2 already covers plain -R from $PROF, these round out the trio.
verdict "RT4 GH_REPO= from a profiled cwd"     deny "guarded-pr-merge.sh" \
  "$(pay Bash 'GH_REPO=owner/other-repo gh pr merge 12' "$PROF")"
verdict "RT5 a pull URL from a profiled cwd"   deny "guarded-pr-merge.sh" \
  "$(pay Bash 'gh pr merge https://github.com/owner/other-repo/pull/12' "$PROF")"
# `-R` glued directly to its value (`-Rowner/repo`, no space, no `=`) is the same short-flag shape
# gh's own flag parser accepts for `-R owner/repo` — both retarget scans in judge_gh need to
# recognise it, not just the space-separated and `--repo=` forms (found in review).
verdict "RT6 -R glued to its value, unprofiled cwd" deny "guarded-pr-merge.sh" \
  "$(pay Bash 'gh pr merge -Rowner/profiled-repo 12 --squash' "$PLAIN")"
# ...and a non-github.com pull URL (a GHES-shaped host) must retarget the same way — the check is
# "a /pull/<number> path", not "a github.com host" specifically.
verdict "RT7 a pull URL on a non-github.com host" deny "guarded-pr-merge.sh" \
  "$(pay Bash 'gh pr merge https://ghe.example.com/owner/other-repo/pull/12' "$PROF")"

# --------------------------------------------------------------------- 1f. launderings (#533)
# Three ways to defeat the earlier walk's literal word match without touching the write itself:
# an unrecognised wrapper launcher, a backslash defeating alias/function lookup, and a fully
# quoted command word. All from an UNPROFILED cwd first (GA1's bare `gh pr merge 12` passes there),
# so these prove the shape is recognised at all — not merely that the probe already denies.
verdict "L1  an unrecognised launcher (timeout), unprofiled cwd" pass "" \
  "$(pay Bash 'timeout 60 gh pr merge 12 --squash' "$PLAIN")"
verdict "L2  backslash-escaped gh, unprofiled cwd" pass "" "$(pay Bash '\gh pr merge 12' "$PLAIN")"
verdict "L3  quoted \"gh\", unprofiled cwd"    pass "" "$(pay Bash '"gh" pr merge 12' "$PLAIN")"
verdict "L4  gh hidden in \$(...), unprofiled cwd" pass "" "$(pay Bash 'echo $(gh pr merge 12)' "$PLAIN")"
# ...and from a PROFILED cwd, where each shape must now deny exactly as the unwrapped form would.
verdict "L5  timeout 60 gh pr merge --squash"  deny "guarded-pr-merge.sh" \
  "$(pay Bash 'timeout 60 gh pr merge 12 --squash' "$PROF")"
verdict "L6  \\gh pr merge 12"                 deny "guarded-pr-merge.sh" "$(pay Bash '\gh pr merge 12' "$PROF")"
verdict "L7  \"gh\" pr merge 12"               deny "guarded-pr-merge.sh" "$(pay Bash '"gh" pr merge 12' "$PROF")"
verdict "L8  'gh' pr merge 12 (single-quoted)" deny "guarded-pr-merge.sh" "$(pay Bash "'gh' pr merge 12" "$PROF")"
verdict "L9  echo \$(gh pr merge 12)"          deny "guarded-pr-merge.sh" "$(pay Bash 'echo $(gh pr merge 12)' "$PROF")"
# The same three launderings on the GIT side (a bare commit, not gh): \git, "git", and a quoted
# guard path — each must still resolve to the right verdict once unwrapped.
verdict "L10 \\git commit -m x"                deny "guarded-commit.sh" "$(pay Bash '\git commit -m x' "$PROF")"
verdict "L11 \"git\" commit -m x"              deny "guarded-commit.sh" "$(pay Bash '"git" commit -m x' "$PROF")"
verdict "L12 timeout 5 git commit -m x"        deny "guarded-commit.sh" "$(pay Bash 'timeout 5 git commit -m x' "$PROF")"
verdict "L13 nice git commit -m x"             deny "guarded-commit.sh" "$(pay Bash 'nice git commit -m x' "$PROF")"
verdict "L14 a launderable word inside a real message is inert" pass "" \
  "$(pay Bash 'git log -m "note: gh pr merge mentioned" ' "$PROF")"
# A launderable-looking word that is genuinely just message text (not at command-word position)
# must never itself flip a verdict: this quoted content is exactly "gh", but it sits as a `-m`
# value, not as $1, so the segment is judged on its real command word ("git log", unrecognised).
verdict "L15 a quoted \"gh\" as a value, not a command word" pass "" \
  "$(pay Bash 'git log -m "gh"' "$PROF")"
# A backslash escaping one of the SEPARATOR characters (`;`/`&`/`|`) must fall back to the old
# space-substitution, not the literal-keep above: `tr` already turned a real line continuation
# (`git \`, newline, `commit -m x`) into `git \;commit -m x` by the time this scan sees it, and
# literal-keeping that `;` would hand the segment walk a split that was never really there —
# splitting one write into two unrecognisable halves (found in review).
verdict "L16 an escaped line-continuation semicolon is not a real split" deny "guarded-commit.sh" \
  "$(pay Bash "$(printf 'git \\\ncommit -m x')" "$PROF")"
# ...and the mirror: an escaped separator that was never meant to end anything must not be
# reinterpreted as one either — this is one `echo` call, arguments only, git never runs.
verdict "L17 an escaped semicolon inside echo's arguments stays inert" pass "" \
  "$(pay Bash 'echo hi\; git commit -m x' "$PROF")"
# A backslash INSIDE a launcher word (not just before it) still defeats a literal `git`/`gh` match,
# but it ALSO breaks the *raw command*'s contiguous "git"/"gh" substring the cheap fast-reject
# filter (line ~88) looks for before any of this scan ever runs — so that filter has to let any
# command carrying a backslash through to the real parse (found in review).
verdict "L18 a backslash inside the word (not just before it)" deny "guarded-commit.sh" \
  "$(pay Bash 'g\it commit -m x' "$PROF")"
# `timeout`'s own option forms (#562, follow-up to #540): a launcher recognised only in its BARE
# form left every option of its own — value-taking or not — unswallowed, so `-k`/`-v` broke the
# walk before it ever reached git/gh and the segment fell through unrecognised (never denied).
# NOTE: labelled L19-L22 rather than the issue's own L16-L19 — L16-L18 were already taken by the
# escaped-separator cases above by the time this landed; see the PR's "Fixed along the way".
verdict "L19 timeout -k 5 60 git commit -m x (separated value)" deny "guarded-commit.sh" \
  "$(pay Bash 'timeout -k 5 60 git commit -m x' "$PROF")"
verdict "L20 timeout --kill-after=5 60 gh pr merge (long option)" deny "guarded-pr-merge.sh" \
  "$(pay Bash 'timeout --kill-after=5 60 gh pr merge 12 --squash' "$PROF")"
verdict "L21 timeout -v 60 git commit -m x (value-less flag)" deny "guarded-commit.sh" \
  "$(pay Bash 'timeout -v 60 git commit -m x' "$PROF")"
verdict "L22 timeout -k 5 60 git commit -m x, unprofiled cwd" pass "" \
  "$(pay Bash 'timeout -k 5 60 git commit -m x' "$PLAIN")"
# `nice`/`stdbuf`'s own option forms, plus three launchers chained in one segment (#562).
verdict "L23 nice -n 10 git push (separated value)" deny "guarded-push.sh" \
  "$(pay Bash 'nice -n 10 git push' "$PROF")"
verdict "L24 nice -n10 git push (attached value)" deny "guarded-push.sh" \
  "$(pay Bash 'nice -n10 git push' "$PROF")"
verdict "L25 stdbuf -oL -eL git commit -m x (two attached options)" deny "guarded-commit.sh" \
  "$(pay Bash 'stdbuf -oL -eL git commit -m x' "$PROF")"
verdict "L26 stdbuf -o L -e L git commit -m x (separated form)" deny "guarded-commit.sh" \
  "$(pay Bash 'stdbuf -o L -e L git commit -m x' "$PROF")"
verdict "L27 nice -n 10 git push, unprofiled cwd" pass "" \
  "$(pay Bash 'nice -n 10 git push' "$PLAIN")"
verdict "L28 env FOO=1 nice -n 10 timeout 60 git commit -m x (three chained launchers)" deny "guarded-commit.sh" \
  "$(pay Bash 'env FOO=1 nice -n 10 timeout 60 git commit -m x' "$PROF")"
# A $(...)/backtick substitution nested inside a double-quoted argument (#559): real shell still
# expands it there, but the quote-collapsing pass used to swallow it whole into the opaque @Q@
# placeholder instead of extracting it for the recursive gate_subs relay.
verdict "L29 \$(...) hidden inside a double-quoted argument" deny "guarded-pr-merge.sh" \
  "$(pay Bash 'echo "$(gh pr merge 12)"' "$PROF")"
verdict "L30 a backtick sub hidden inside a double-quoted argument" deny "guarded-pr-merge.sh" \
  "$(pay Bash 'echo "`gh pr merge 12`"' "$PROF")"
# Outer verb is `echo`, not `git commit` (the issue's own illustrative example) — a bare `git
# commit` denies unconditionally regardless of its message content (D-series above), so it cannot
# isolate this specific "$5 is not a substitution opener" question, empirically confirmed pre-fix.
verdict "L31 a bare \$ that never opens a substitution stays inert" pass "" \
  "$(pay Bash 'echo "cost is $5, ask gh pr merge team"' "$PROF")"

# --------------------------------------------------------- 1g. the allowlist is per-segment (#533)
# The old allowlist matched `guarded-commit.sh` as a substring ANYWHERE on the line, so a line that
# merely MENTIONED the guard earlier (an `if` condition, a different branch) whitelisted a raw
# write elsewhere on the same line. #533's own incident shape: the guard is named in the `if` and
# the `then` branch, but the `else` branch's raw commit must still deny.
verdict "AL1 the else-branch raw commit still denies" deny "guarded-commit.sh" \
  "$(pay Bash 'if [ -x "$G/guarded-commit.sh" ]; then "$G/guarded-commit.sh" -C x y -- -m x; else git commit -m x; fi' "$PROF")"
# ...while the guard invocation itself, in the very same line, still passes — this is a per-segment
# fix, not a stricter one: nothing that used to pass here should now deny.
r=$(reason_for "$(pay Bash 'if [ -x "$G/guarded-commit.sh" ]; then "$G/guarded-commit.sh" -C x y -- -m x; else git commit -m x; fi' "$PROF")" "")
case "$r" in *'guarded-commit.sh'*) echo "ok: AL2 the same line's guard-calling branch is not what triggers the denial (the else-branch is)" ;;
  *) echo "FAIL [AL2]: expected reason to name guarded-commit.sh: $r"; exit 1 ;; esac
verdict "AL3 a guard mention inside a commit message is not a whole-line allow" deny "guarded-commit.sh" \
  "$(pay Bash 'git commit -m "see guarded-commit.sh for details"' "$PROF")"
# ...even when the quoted message's content ends in the exact guard filename (so it WOULD get the
# @GUARDED_COMMIT@ placeholder from the quote-collapsing pass): it lands as the value of `-m`, not
# as $1, so it has no more effect on the verdict than plain message text would.
verdict "AL4 a message ending in the exact guard name is still just a value" deny "guarded-commit.sh" \
  "$(pay Bash 'git commit -m "see guarded-commit.sh"' "$PROF")"

# ------------------------------------------------------------------ 2. the allow rows (A)
verdict "A1  branch -D after a merge"  pass "" "$(pay Bash 'git branch -D feat/326-x' "$PROF")"
verdict "A2  checkout a branch"        pass "" "$(pay Bash 'git checkout main' "$PROF")"
verdict "A3  switch"                   pass "" "$(pay Bash 'git switch -c feat/x' "$PROF")"
verdict "A4  restore one named path"   pass "" "$(pay Bash 'git restore src/App.cs' "$PROF")"
verdict "A5  checkout -- one clean path" pass "" "$(pay Bash 'git checkout -- src/App.cs' "$PROF")"
# ------------------------------------------------- 1e. the named-path checkout probe, scoped (#560)
# A named-path checkout/switch is exactly as capable of silently overwriting one file's
# uncommitted edit as the whole-tree form is of overwriting all of them — the hook denied only the
# whole-tree shape until now. `$DIRTY` carries a real unstaged edit at `src/Dirty.cs`.
verdict "A43 checkout -- one dirty path" deny "checkout -- <path>" \
  "$(pay Bash 'git checkout -- src/Dirty.cs' "$DIRTY")"
verdict "A44 checkout <ref> -- two paths, one dirty" deny "src/Dirty.cs" \
  "$(pay Bash 'git checkout HEAD -- src/Clean.cs src/Dirty.cs' "$DIRTY")"
# A bare ref before `--` (a branch/commit name, not a path) must never be probed against the
# working tree: that would false-deny an ordinary branch switch that happens to share a name with
# an unrelated dirty file elsewhere in the tree.
verdict "A45 checkout a ref named like a dirty path is still just a ref" pass "" \
  "$(pay Bash 'git checkout src/Dirty.cs' "$DIRTY")"
# A46/A47: a path that is dirty ONLY in the index (staged, worktree already matches) is a no-op
# for the no-ref restore form, but a REAL discard once a ref is named — the ref replaces the
# worktree from itself, not from the index, so the staged edit is lost either way.
verdict "A46 checkout -- a staged-but-worktree-clean path is a no-op" pass "" \
  "$(pay Bash 'git checkout -- src/StagedClean.cs' "$DIRTY")"
verdict "A47 checkout <ref> -- the same staged-clean path still denies" deny "src/StagedClean.cs" \
  "$(pay Bash 'git checkout HEAD -- src/StagedClean.cs' "$DIRTY")"
# A48: FORCE mode (GIT_GATE=on) must not defeat the probe by leaving `dir` pointed at the hook's
# own cwd instead of the repo the payload names — the exact regression an earlier draft of this
# fix shipped (`dir` was resolved only inside the `is_profiled` arm, which FORCE skips entirely).
verdict "A48 GIT_GATE=on still denies a dirty named-path checkout" deny "checkout -- <path>" \
  "$(pay Bash 'git checkout -- src/Dirty.cs' "$DIRTY")" "$PATH" on
verdict "A6  stash -u"                 pass "" "$(pay Bash 'git stash -u' "$PROF")"
verdict "A7  rebase"                   pass "" "$(pay Bash 'git rebase main' "$PROF")"
verdict "A8  reset without --hard"     pass "" "$(pay Bash 'git reset --soft HEAD~1' "$PROF")"
verdict "A9  read-only git"            pass "" "$(pay Bash 'git log --oneline -5 && git status --porcelain' "$PROF")"
verdict "A10 clean -n looks only"      pass "" "$(pay Bash 'git clean -n' "$PROF")"
verdict "A11 merge --abort"            pass "" "$(pay Bash 'git merge --abort' "$PROF")"
verdict "A12 no git in the command"    pass "" "$(pay Bash 'ls -la && rm -rf build' "$PROF")"
# Read-only, or less destructive than the replacement a deny would name (#373): `--staged .`
# unstages and touches no file in the tree; a dry-run push pushes nothing. Both were denied while
# the arms matched spellings, and D3's old form pinned the first one as correct.
verdict "A36 restore --staged . touches no tree file" pass "" "$(pay Bash 'git restore --staged .' "$PROF")"
verdict "A37 push --dry-run"           pass "" "$(pay Bash 'git push --dry-run' "$PROF")"
verdict "A38 push -n"                  pass "" "$(pay Bash 'git push -n' "$PROF")"

# The guards are the whole point: a line that calls one is allowed, INCLUDING the `--force-with-lease`
# the gate refuses on a bare push. Spelled with the quoted `"$GUARDS/…"` every skill actually emits,
# which is why the recognition reads the raw command and not the quote-stripped one.
# `guarded-pr-merge.sh` is off that whole-line list since #512 (G13 is why): A16 passes because its
# line holds neither `git` nor `gh … merge`, and a line pairing the guard with a read-only `gh` is
# judged segment by segment and passes too (GA10).
verdict "A13 guarded-commit.sh line"   pass "" \
  "$(pay Bash '"$GUARDS/guarded-commit.sh" -C "$WORKTREE" -c user.email=a@b -c user.name="A B" main -- -am msg' "$PROF")"
verdict "A14 guarded-push --force-with-lease" pass "" \
  "$(pay Bash '"$GUARDS/guarded-push.sh" -C "$WORKTREE" main -- --force-with-lease' "$PROF")"
verdict "A15 guarded-merge.sh line"    pass "" \
  "$(pay Bash '"$GUARDS/guarded-merge.sh" -C "$WORKTREE" main -- origin/main' "$PROF")"
verdict "A16 guarded-pr-merge.sh line" pass "" \
  "$(pay Bash '"$GUARDS/guarded-pr-merge.sh" 353' "$PROF")"

# Matt's substring greps deny both of these (mattpocock/skills, MIT — prior art, not a port).
verdict "A17 inside a double-quoted string" pass "" "$(pay Bash 'echo "git push --force"' "$PROF")"
verdict "A18 inside a single-quoted string" pass "" "$(pay Bash "printf '%s' 'git reset --hard'" "$PROF")"
verdict "A19 after a # comment"        pass "" "$(pay Bash 'git log --oneline # git reset --hard' "$PROF")"

# --------------------------------------- 2b. the shapes a first tokeniser got wrong (R)
# Every case here is a behaviour a code review REPRODUCED against the first implementation, kept as
# a regression row rather than a note. Together they are the bulk of what an agent actually types.

# `git -C "$WORKTREE" …` is what this kit's own references prescribe over `cd … &&`, and it is the
# dominant idiom across skills/. Deleting the quoted span instead of standing a token in its place
# made `-C` swallow the subcommand, so the gate was blind to the exact incident class it exists for.
verdict "R1  git -C \"quoted\" commit"  deny "guarded-commit.sh" \
  "$(pay Bash 'git -C "$WORKTREE" commit -m "wip"' "$PROF")"
# ...and unquoted, with the variable the hook cannot expand: an unresolvable `-C` is no evidence, so
# the probe falls back to cwd rather than treating it as "not a profiled repo".
verdict "R2  -C names an unresolvable path" deny "guarded-commit.sh" \
  "$(pay Bash 'git -C $WORKTREE commit -m wip' "$PROF")"
# ...whereas a `-C` that DOES resolve, to a repo without a profile, still means what it says.
verdict "R3  -C resolves to an unprofiled repo" pass "" \
  "$(pay Bash "git -C $PLAIN commit -m wip" "$PROF")"

# Grouping and control flow: `(`, `{`, `then`, `do`. A bare write wrapped in any of them used to
# stop the prefix walk on its first token and never be judged at all.
verdict "R4  subshell"                 deny "guarded-commit.sh" "$(pay Bash '(git commit -m x)' "$PROF")"
verdict "R5  brace group"              deny "guarded-commit.sh" "$(pay Bash '{ git commit -m x; }' "$PROF")"
verdict "R6  inside an if"             deny "guarded-commit.sh" "$(pay Bash 'if true; then git commit -m x; fi' "$PROF")"
verdict "R7  inside a for"             deny "guarded-push.sh"   "$(pay Bash 'for f in a b; do git push; done' "$PROF")"

# `#` is a comment only at a word boundary, as in real shell — and the comment ends at the next
# separator, so it can never swallow a command that really would run.
verdict "R8  a # inside a word hides nothing" deny "git reset --keep" \
  "$(pay Bash 'git log --grep=a#b && git reset --hard' "$PROF")"

# The force flags are the same whole-tree discard as a `.` pathspec, spelled without one.
verdict "R9  checkout -f"              deny "git checkout -- <path>" "$(pay Bash 'git checkout -f main' "$PROF")"
verdict "R10 switch --discard-changes" deny "git checkout -- <path>" "$(pay Bash 'git switch --discard-changes main' "$PROF")"

# `git clean -ndf` deletes nothing — it is the command the deny reason recommends, so denying it
# would send the reader in a circle.
verdict "R11 clean -ndf is a dry run"  pass "" "$(pay Bash 'git clean -ndf' "$PROF")"

# A heredoc body is FILE CONTENT. Denying it would make it impossible to WRITE a script, doc or
# test whose text contains one of these lines — which this repository's own suites do — so a
# command carrying `<<` is a parse the gate does not trust, and it fails open.
verdict "R12 a heredoc body is not a command" pass "" \
  "$(pay Bash "cat > t.sh <<'SH'
git commit -m x
SH" "$PROF")"

# --------------------------------------------------- 2c. the write is BEFORE the `<<` (#440)
# The bail-out above discarded the WHOLE command on any `<<`, including the visible git verb before
# it — laundering the natural long-message commit form (`git commit -F - <<'MSG'`) and any other
# destructive write sharing a line with a heredoc straight past the gate. These pin the opening line
# as judged exactly as it would be without the heredoc, while R12 above (unchanged) proves the body
# itself is still never read.
#
# Payloads are captured in PAY_H1..PAY_H4 rather than inlined twice: the revert-detection block below
# (5b) drives the identical commands against a MUTATED gate to prove the pre-#440 behaviour reappears,
# and a payload edited in one spot without the other would silently stop proving what its name claims.
PAY_H1="$(pay Bash "git commit -F - <<'MSG'
a long commit message
MSG" "$PROF")"
PAY_H2="$(pay Bash "git push origin main <<X
body
X" "$PROF")"
PAY_H3="$(pay Bash "git checkout HEAD -- . <<X
body
X" "$PROF")"
PAY_H4="$(pay Bash 'git push <<< x' "$PROF")"
verdict "H1  commit -F - before a heredoc"  deny "guarded-commit.sh" "$PAY_H1"
verdict "H2  push before a heredoc"    deny "guarded-push.sh" "$PAY_H2"
verdict "H3  checkout . before a heredoc" deny "checkout -- <path>" "$PAY_H3"
verdict "H4  push before a here-string" deny "guarded-push.sh" "$PAY_H4"
# The guard whitelist (:162) matches on the RAW command before truncation, and the guard's own name
# sits before the `<<` in every call shape the skills use — truncation must not blind it.
verdict "H5  a guarded call surviving truncation" pass "" \
  "$(pay Bash "\"\$GUARDS/guarded-commit.sh\" -C \"\$WORKTREE\" -c user.email=a@b -c user.name=\"A B\" main -- -F - <<'MSG'
a long commit message
MSG" "$PROF")"

# H6/H7 — `<<` is also unremarkable TEXT inside a real argument (a commit message quoting a diff
# marker), not always a real heredoc opener. A truncation that is not quote-aware cuts the quote in
# half, leaves the KEPT prefix with an unterminated quote, and that fails the awk stripper — which
# fails the WHOLE hook open, laundering everything on the line exactly like #440. These pin that the
# scan only breaks on an UNQUOTED `<<`, so a `<<` inside quotes changes nothing about what gets judged.
verdict "H6  a bare commit whose message merely quotes <<" deny "guarded-commit.sh" \
  "$(pay Bash 'git commit -m "note: <<< merge conflict markers" ' "$PROF")"
verdict "H7  a force push after a message merely quoting <<" deny "guarded-push.sh" \
  "$(pay Bash 'echo "see <<data>>, more" && git push --force origin main' "$PROF")"

# ---------------------------------------------------- 3. inert where the guards cannot exist
# The probe's whole argument (the `dnx` argument of #112, transposed): a denial names a
# `guarded-*.sh` replacement, so it must not fire where that replacement does not exist.
verdict "A20 no profile, no denial"    pass "" "$(pay Bash 'git checkout main -- .' "$PLAIN")"
verdict "A21 no profile, bare commit"  pass "" "$(pay Bash 'git commit -m wip' "$PLAIN")"

# The probe follows a literal `cd` (#372): a write after `cd <guard-less repo>` is that repository's
# write, and denying it names guards that do not exist there. A41 is docs/demo-walkthrough.md's own
# reproduce line — the directory it cds into is created by the `cp` in the same command, so the
# `cd` cannot be resolved; the `git init` that follows is what tells the gate the later segments
# act in a brand-new repository.
verdict "A40 cd into a guard-less repo" pass "" "$(pay Bash "cd $PLAIN && git commit -m x" "$PROF")"
verdict "A41 cp, cd, init, commit (the walkthrough line)" pass "" \
  "$(pay Bash "cp -r samples/LegacyShop $PLAIN/shop && cd $PLAIN/shop && git init && git add -A && git commit -m legacy" "$PROF")"
verdict "A42 GIT_GATE=off as a one-command prefix" pass "" "$(pay Bash 'GIT_GATE=off git commit -m x' "$PROF")"
# ...but only for the main thread (#643): a sub-agent reads the same deny text and cannot ask
# anyone first, so its prefixed write is judged like the bare one — also inside `$( )`.
verdict "A42s sub-agent GIT_GATE=off git commit" deny "guarded-commit.sh" "$(pay_sub Bash 'GIT_GATE=off git commit -m x' "$PROF")"
verdict "G8s sub-agent GIT_GATE=off gh pr merge" deny "guarded-pr-merge.sh" "$(pay_sub Bash 'GIT_GATE=off gh pr merge 12' "$PROF")"
verdict "A42t sub-agent prefix inside \$( )" deny "guarded-commit.sh" "$(pay_sub Bash 'echo $(GIT_GATE=off git commit -m x)' "$PROF")"
verdict "A42u env GIT_GATE=off still wins for a sub-agent" pass "" "$(pay_sub Bash 'git commit -m x' "$PROF")" "$PATH" off
# ...and every cd the hook cannot resolve leaves the probe where it was: a variable, `~`, `cd -`,
# a bare `cd`, `pushd`, and a `cd` inside `( … )` whose directory change dies with the subshell.
verdict "D23 cd \$VAR stays put"        deny "guarded-commit.sh" "$(pay Bash 'cd $ELSEWHERE && git commit -m x' "$PROF")"
verdict "D24 cd ~ stays put"           deny "guarded-commit.sh" "$(pay Bash 'cd ~/elsewhere && git commit -m x' "$PROF")"
verdict "D25 cd - stays put"           deny "guarded-commit.sh" "$(pay Bash 'cd - && git commit -m x' "$PROF")"
verdict "D26 bare cd stays put"        deny "guarded-commit.sh" "$(pay Bash 'cd && git commit -m x' "$PROF")"
verdict "D27 pushd stays put"          deny "guarded-commit.sh" "$(pay Bash "pushd $PLAIN && git commit -m x" "$PROF")"
verdict "D28 a cd inside ( ) dies with its subshell" deny "guarded-commit.sh" \
  "$(pay Bash "(cd $PLAIN) && git commit -m x" "$PROF")"
verdict "D29 cd INTO a profiled repo"  deny "guarded-commit.sh" "$(pay Bash "cd $PROF && git commit -m x" "$PLAIN")"
# The deny text names the two escapes that work and no longer the one that did nothing (#372): an
# `export` typed into a Bash call never reaches a hook the Claude Code process spawns.
reason=$(pay Bash 'git commit -m wip' "$PROF" | bash "$GATE" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
grep -qF 'GIT_GATE=off git' <<<"$reason" \
  || { echo "FAIL: the deny text does not name the per-command GIT_GATE=off prefix"; exit 1; }
grep -qF 'launch Claude with GIT_GATE=off' <<<"$reason" \
  || { echo "FAIL: the deny text does not say the session switch is set where Claude is launched"; exit 1; }
if grep -qF 'for one command or for the session' <<<"$reason"; then
  echo "FAIL: the deny text still advertises an off-switch that does nothing from inside a session (#372)"; exit 1
fi
echo "ok: the deny text names only the escapes that work"
# ...and the pair is a MEASUREMENT rather than a coincidence: the same command in the profiled repo
# denies (D1 above), so A20's pass can only be the probe and not some other fail-open path.

# --------------------------------------------------------------- 4. the switches (off wins)
verdict "A22 GIT_GATE=off"             pass "" "$(pay Bash 'git checkout main -- .' "$PROF")" "$PATH" off
verdict "A23 GIT_GATE=on forces past the probe" deny "checkout -- <path>" \
  "$(pay Bash 'git checkout main -- .' "$PLAIN")" "$PATH" on
verdict "A24 off outranks a probe that would deny" pass "" \
  "$(pay Bash 'git commit -m wip' "$PROF")" "$PATH" off
verdict "A25 an unrecognised value falls through" pass "" \
  "$(pay Bash 'git checkout main -- .' "$PLAIN")" "$PATH" maybe

# GIT_GATE holds one value, so `off` and `on` cannot literally both be set; what the spec calls "off
# wins" is the ORDER of the two branches inside the gate. Asserted at the source, because that order
# is the only place the invariant exists: with `on` first, a stale `on` in a shell rc would quietly
# override the `off` a user just typed.
off_line=$(grep -n 'off|0|false|no|disabled' "$GATE" | head -1 | cut -d: -f1)
on_line=$(grep -n 'on|1|true|yes|enabled' "$GATE" | head -1 | cut -d: -f1)
[ -n "$off_line" ] && [ -n "$on_line" ] \
  || { echo "FAIL: the gate does not carry both switch branches (off=$off_line on=$on_line)"; exit 1; }
[ "$off_line" -lt "$on_line" ] \
  || { echo "FAIL: the 'on' branch (line $on_line) precedes 'off' (line $off_line); off must stay the master switch"; exit 1; }
echo "ok: the off branch is checked before the on branch"

# --------------------------------------------------------- 5. every internal failure fails OPEN
NOJQ=$(shim_path "$WORK/nojq"); rm -f "$NOJQ/jq"
NOAWK=$(shim_path "$WORK/noawk"); rm -f "$NOAWK/awk"
NOGIT=$(shim_path "$WORK/nogit"); rm -f "$NOGIT/git"
FULL=$(shim_path "$WORK/full")

verdict "A26 no jq on PATH"            pass "" "$(pay Bash 'git commit -m wip' "$PROF")" "$NOJQ"
verdict "A27 no awk on PATH"           pass "" "$(pay Bash 'git commit -m wip' "$PROF")" "$NOAWK"
verdict "A28 no git on PATH"           pass "" "$(pay Bash 'git commit -m wip' "$PROF")" "$NOGIT"
# The control for the three above: the SAME stripped PATH, complete, must still deny — otherwise
# each pass is equally well explained by the shim missing something the gate needs, and section 5
# would be green while measuring nothing.
verdict "A29 the same shim, complete, still denies" deny "guarded-commit.sh" \
  "$(pay Bash 'git commit -m wip' "$PROF")" "$FULL"

verdict "A30 malformed payload"        pass "" 'not json at all'
verdict "A31 a tool other than Bash"   pass "" "$(pay NotebookEdit 'git commit -m wip' "$PROF")"
verdict "A32 BashOutput is not Bash"   pass "" "$(pay BashOutput 'git commit -m wip' "$PROF")"
verdict "A33 no command in the payload" pass "" '{"tool_name":"Bash","cwd":"/tmp","tool_input":{}}'
verdict "A34 unterminated quoting is a parse it cannot trust" pass "" \
  "$(pay Bash 'git commit -m "never closed' "$PROF")"
# A command past the size cap is not one of the shapes above; parsing it would outrun the hook's
# 5s timeout, and a timed-out hook is an unpredictable one. The padding goes AFTER an intact
# `git commit -m x`, so the tokeniser has a real write to find: the first spelling ran the whole
# line through `tr ' ' 'y'`, spaces included, and left no `git` token at all — with the cap
# deleted, A35 stayed green and measured nothing (#373).
BIG="git commit -m x $(printf '%*s' 70000 '' | tr ' ' 'y')"
verdict "A35 an oversized command"     pass "" "$(pay Bash "$BIG" "$PROF")"

# --------------------------------------------------- 5b. the fix cannot be reverted silently (#440)
# Every case above drives the REAL, shipped gate — so a later tidy-up that quietly restores the old
# `exit 0` bail-out would leave every one of them green: H1-H4 above assert `deny`, and the reverted
# gate does not deny anything DIFFERENT, it just fails open again on the same inputs, which is a
# `pass` the assertion catches — UNLESS a future edit also softened the `verdict` helper itself. The
# belt-and-braces case below drives a MUTATED COPY of the gate directly, the same scratch-copy
# pattern `profile_repo`/`plain_repo`/`shim_path` already use above: build the fixture in $WORK with
# `mktemp -d`, prove the mutation actually landed, then assert the OLD, broken behaviour reappears
# on that copy — which is the only way to show this suite would have gone red on the original defect
# rather than merely trusting that it currently does.
#
# The mutation INSERTS the pre-#440 bail-out after the cheap `*git*` reject rather than substituting
# a specific line of the fix's own implementation: the fix now lives inside the quote-aware awk scan,
# not as one grep-able line, and a mutation tied to today's implementation shape would itself go
# silently inert the next time that implementation changes, which is exactly the failure mode this
# case exists to catch. Inserting the old whole-command bail-out ahead of everything reproduces the
# pre-#440 behaviour regardless of what the fix looks like downstream.
REVERTED_GATE="$WORK/git-write-gate.reverted.sh"
sed '/# The cheap reject, before any parsing:/a\
case "$cmd" in *'"'"'<<'"'"'*) exit 0 ;; esac' \
  "$GATE" > "$REVERTED_GATE"
diff -q "$GATE" "$REVERTED_GATE" >/dev/null \
  && { echo "FAIL: the sed mutation did not change anything — this case tests nothing"; exit 1; }
grep -qF 'case "$cmd" in *'"'"'<<'"'"'*) exit 0 ;; esac' "$REVERTED_GATE" \
  || { echo "FAIL: the reverted copy does not contain the old bail-out — mutation failed"; exit 1; }

# Drives the MUTATED copy directly (not the `verdict` helper, which is hardwired to `$GATE`) and
# asserts the pre-#440 behaviour: every write that H1-H4 above prove denied on the real gate comes
# back as an *allow* on the reverted one — the exact regression this suite exists to catch.
revert_allows() { # $1 name  $2 payload
  local name="$1" payload="$2" out
  out=$(printf '%s' "$payload" | bash "$REVERTED_GATE" 2>/dev/null) || {
    echo "FAIL [$name]: reverted gate exited non-zero; expected the old fail-open pass"; exit 1; }
  [ -z "$out" ] || { echo "FAIL [$name]: reverted gate did not fail open — got: $out"; exit 1; }
  echo "ok: $name -> pass (on the reverted gate, as the pre-#440 defect predicts)"
}
revert_allows "H1r commit -F - before a heredoc, on the reverted gate" "$PAY_H1"
revert_allows "H2r push before a heredoc, on the reverted gate" "$PAY_H2"
revert_allows "H3r checkout . before a heredoc, on the reverted gate" "$PAY_H3"
revert_allows "H4r push before a here-string, on the reverted gate" "$PAY_H4"

# ---------------------------------------------------------------- 6. structural wiring (S)
# S1 — hooks are outside parse-sweep's default target set (docs/backlog.md records that gap), so the
# sweep is invoked on this file explicitly. bash 3.2 is the floor the sweep enforces.
./scripts/parse-sweep.sh hooks/git-write-gate.sh tests/git-gate/test.sh >/dev/null \
  || { echo "FAIL: parse-sweep rejects the gate or this suite"; exit 1; }
echo "ok: the gate and this suite pass ./scripts/parse-sweep.sh"

# S2 — the registration. A hook that is never invoked looks exactly like a hook that found nothing
# to block, which is the failure scripts/ci-wiring-check.py exists for one level up.
HJ="$KIT/hooks/claude-hooks.json"
jq -e . "$HJ" >/dev/null 2>&1 || { echo "FAIL: hooks.json is not valid JSON"; exit 1; }
n=$(jq '[.hooks.PreToolUse[] | select(.matcher=="Bash")] | length' "$HJ")
[ "$n" = "1" ] || { echo "FAIL: hooks.json has $n Bash matchers, want exactly 1"; exit 1; }
got=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[0].command' "$HJ")
case "$got" in
  *'${CLAUDE_PLUGIN_ROOT}'*git-write-gate.sh) echo "ok: hooks.json wires Bash -> $got" ;;
  *) echo "FAIL: Bash matcher command is '$got'; must reference \${CLAUDE_PLUGIN_ROOT}/hooks/git-write-gate.sh"; exit 1 ;;
esac
tmo=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[0].timeout // empty' "$HJ")
[ -n "$tmo" ] || { echo "FAIL: the Bash hook has no timeout; a hung gate would stall every Bash call"; exit 1; }
resolved="${got/\$\{CLAUDE_PLUGIN_ROOT\}/$KIT}"
[ -x "$resolved" ] || { echo "FAIL: hooks.json points at '$resolved', which is not an executable file"; exit 1; }
echo "ok: the registered command resolves to a shipped executable with timeout=$tmo"

# The Read matcher must survive this PR untouched — the two hooks share one file, and the roseline
# gate going missing would be invisible to every case above.
jq -e '[.hooks.PreToolUse[] | select(.matcher=="Read")] | length == 1' "$HJ" >/dev/null \
  || { echo "FAIL: hooks.json no longer carries exactly one Read matcher"; exit 1; }
echo "ok: the roseline gate's Read matcher is still registered"

# S3 — the registry entry. `scripts/decision-check.py`'s R10 does not enumerate `hooks/` today
# (#307 will widen it); recording the entry now is what makes that widening land green instead of
# red, and it is the class the four `guarded-*.sh` scripts are already recorded under.
python3 - "$KIT/decisions/registry.json" <<'PY' || exit 1
import json, sys
reg = json.load(open(sys.argv[1]))
nd = reg.get("not_decisions", {})
key = "hooks/git-write-gate.sh"
if key not in nd:
    print(f"FAIL: decisions/registry.json not_decisions has no entry for {key}")
    sys.exit(1)
if not nd[key].strip():
    print(f"FAIL: the not_decisions entry for {key} is empty; it must say WHY")
    sys.exit(1)
print(f"ok: decisions/registry.json records {key} under not_decisions")
PY

# S4 — the prerequisite. Without `jq` the hook exits at its first probe and enforcement is silently
# off, so the manifest has to name this gate too, not just the roseline one.
REQ="$KIT/requirements.json"
hint=$(jq -r '.tools[] | select(.name | test("jq")) | .hint' "$REQ")
printf '%s' "$hint" | grep -qF 'git-write-gate.sh' \
  || { echo "FAIL: requirements.json's jq hint does not mention hooks/git-write-gate.sh: '$hint'"; exit 1; }
echo "ok: requirements.json's jq hint names both gates"

# S5 — the documentation. An off-switch nobody can find is not an off-switch.
grep -qF 'git-write-gate' "$KIT/README.md" \
  || { echo "FAIL: README does not document the git write-gate"; exit 1; }
grep -qF 'GIT_GATE=off' "$KIT/README.md" \
  || { echo "FAIL: README does not document GIT_GATE=off"; exit 1; }
echo "ok: README documents the gate and its off-switch"

# S6 — the prior-art credit. Matt Pocock's block-dangerous-git.sh (mattpocock/skills, MIT) is the
# idea's source and is deliberately not copied; the file has to say both.
grep -qF 'mattpocock/skills' "$GATE" \
  || { echo "FAIL: the gate does not credit mattpocock/skills as prior art"; exit 1; }
echo "ok: the gate credits its prior art"

echo "git write-gate golden test OK"
