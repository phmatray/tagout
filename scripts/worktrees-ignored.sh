#!/usr/bin/env bash
# worktrees-ignored.sh — assert that an agent worktree can never be committed to this repository.
#
# Why this exists (#43). The harness puts agent worktrees under `.claude/worktrees/`. Unignored,
# any `git add -A` in this repository stages one, so the guarantee has to be mechanical rather
# than remembered.
#
# ⚠️ The original trigger — `skills/_shared/sync-with-main.md` finishing a merge with `git add -A`,
# on the common path of both lifecycle skills — is GONE as of #68: that procedure now stages only
# the conflicted paths, and no skill in this kit runs `add -A` any more. This gate is therefore no
# longer defending against the kit's own command, and the rest of this header should be read that
# way. It still earns its place, for two reasons that outlive the command that prompted it:
#
#   * a human (or another agent) typing `git add -A` in the main checkout is not governed by
#     anything the kit does, and this repo is where the agents run; and
#   * the ignore rule is cheap and the failure is silent and irreversible-ish, which is exactly the
#     trade this gate exists to take.
#
# Do not read the removal as a reason to delete the rule — read it as the reason this header no
# longer names a caller.
#
# WHAT IT ACTUALLY STAGES, measured (git 2.50.1) rather than assumed, because the intuitive answer
# is wrong and sends you looking for the wrong symptom: a linked worktree carries a `.git` FILE,
# so `git add -A` records ONE gitlink —
#     160000 <sha> 0  .claude/worktrees/<branch>
# — not a copy of the tree. Whoever debugs this is not hunting an enormous diff; they are hunting
# a single submodule-shaped entry pointing at a commit no clone can fetch, since there is no
# submodule URL and no remote. git prints "warning: adding embedded git repository", and that
# warning on a busy console is the only thing standing between this and a silent commit.
#
# TWO worktree homes are checked, because two are reachable:
#   .claude/worktrees/  what this harness creates, and what merge-pr hardcodes.
#   .worktrees/         what the superpowers plugin's using-git-worktrees skill falls back to (its
#                       Step 1b) when no native worktree tool exists. The kit's own lifecycle skills
#                       create through skills/implement-issue/scripts/make-worktree.sh (#324), but
#                       a contributor driving that plugin by hand still lands there — and a rule
#                       naming only `.claude/` would pass while that contributor's `git add -A`
#                       staged `.worktrees/<branch>`. Measured: it does.
#
# ONE path must stay VISIBLE: `.claude/skills/repo-profile.md`. init writes it and
# tells consumer repos to commit it, so broadening this rule to all of `.claude/` would make this
# repo — the reference implementation people copy — silently contradict the contract it documents.
# Nothing else catches that: the CI step asserting this repo has no profile tests the file's
# ABSENCE, which a broadened ignore rule leaves undisturbed.
#
# The check is on the PATH, via `git check-ignore`, never a grep of `.gitignore`: a grep passes on
# a commented-out rule, and on a rule that a later `!` negation cancels.
#
# And it is `-q`, never `-v`. Only `-q`'s exit status answers "is this path ignored". With `-v`,
# exit 0 means "some pattern matched" — and a NEGATED pattern matching counts, so
# `!.claude/worktrees/` placed just after the rule makes `check-ignore -v` exit 0 while the path is
# not ignored at all. That is a fail-open in precisely the case check-ignore was chosen to catch.
#
# The paths are queried WITH a trailing slash. `.claude/worktrees/` is a directory-only pattern and
# check-ignore cannot tell a non-existent path is a directory, so on a fresh checkout
# `check-ignore -q .claude/worktrees` answers "not ignored" for a rule that is perfectly correct,
# while `.claude/worktrees/` answers correctly. Querying with the slash is what lets this script
# stay READ-ONLY rather than mkdir-ing scratch directories into the workspace it is auditing.
# tests/worktrees-ignored/test.sh drives that exact case, so dropping the slash goes red.
#
# Usage:
#   worktrees-ignored.sh [-C <repo-path>]
#
# Exit codes:
#   0  every worktree home is ignored, and the rule was not broadened
#   1  a worktree home is NOT ignored — `git add -A` would stage a worktree. THE hazard.
#   2  every home is ignored, but the rule is broad enough to also hide
#      .claude/skills/repo-profile.md. No worktree hazard — a caller about to create one may
#      proceed; what breaks is the repo's ability to carry a profile. Ordered after 1 because it
#      is a different finding, NOT a worse one: do not collapse "non-zero" into "stop".
#   3  usage error, or <repo-path> is not a git repository — no verdict was reached, so not a pass
#
# The repo path must be the MAIN WORKING TREE's root. `.claude/worktrees/` is an anchored pattern (it
# contains a slash), so git resolves it relative to the directory it is asked about: run against a
# subdirectory and a correctly configured repo answers "NOT ignored".
#
# Do NOT pass `git rev-parse --show-toplevel` (this line used to say callers should). Run from inside
# a LINKED worktree that names the worktree itself, not the checkout the hazard is in, and the answer
# can be 0 while the main checkout is genuinely unignored — a fail-open, measured in
# tests/worktrees-ignored/test.sh case 22. Resolve the main working tree instead:
#     git worktree list --porcelain | sed -n '1s/^worktree //p'
# and skip the check entirely when that first entry is marked `bare` — a bare repo has no working
# tree, so nothing there can stage a worktree and `check-ignore` cannot run in it at all.
# skills/_shared/worktree-ignore-check.md states this once, for every caller.

set -euo pipefail

REPO="."

# Print the header block above as the help text, the way the sibling guards in
# skills/implement-issue/scripts do — a hardcoded line range there silently stops documenting the
# exit codes, and ci.yml greps --help for exactly that string.
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -C) [ -n "${2:-}" ] || { printf 'worktrees-ignored: -C needs a <repo-path>\n' >&2; exit 3; }
        REPO="$2"; shift 2 ;;
    *)  printf 'worktrees-ignored: unexpected argument: %s\n' "$1" >&2; exit 3 ;;
  esac
done

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || {
  printf 'worktrees-ignored: %s is not a git repository\n' "$REPO" >&2; exit 3; }

# Trailing slashes are load-bearing — see the header.
WORKTREE_HOMES=".claude/worktrees/ .worktrees/"
MUST_STAY_VISIBLE=".claude/skills/repo-profile.md"

# Where did the matching rule come from, and will anyone else inherit it? `check-ignore` is satisfied
# by `.git/info/exclude` and by `core.excludesFile`, which are MACHINE-LOCAL: the path is genuinely
# ignored for whoever runs this, so the immediate hazard is covered and the verdict stays 0 — but the
# repo itself carries no such rule, and every teammate's and CI's `git add -A` still stages the
# worktree. Callers that write the answer down (init records it as a durable fact about
# the repo) must not turn "ignored here, today" into "this repo ignores it".
#
# `-v` is used ONLY to name the source, never to decide — see the -q/-v note in the header. Its exit
# status is not consulted here; `-q` has already ruled.
#
# `sed` rather than the `rev | cut -d: -f3- | rev` sandwich this used to spell — PORTABILITY, not
# style, so do not reinstate it (#174). `rev` is util-linux and Git Bash does not ship it: the
# pipeline produced nothing there, durability_note() took its "" branch, and a rule committed at
# .gitignore:25 was reported as "rule source unknown", which is the caveat for the case this one is
# meant to be distinguished FROM. `check-ignore -v` prints `<source>:<line>:<pattern>\t<path>`, so
# `cut -f1` already isolates those three fields and the `sed` drops the trailing `:<line>:<pattern>`
# — exactly what the sandwich removed, including for a source path that itself contains colons (a
# Windows `C:/…/excludesFile`), since only the LAST two are anchored off.
rule_source() {
  git -C "$REPO" check-ignore -v "$1" 2>/dev/null | head -1 | cut -f1 | sed 's/:[^:]*:[^:]*$//'
}
durability_note() {
  local src="$1"
  case "$src" in
    "")   printf '  note: rule source unknown — treat "ignored" as unverified beyond this checkout.\n' ;;
    # A Windows absolute path — `C:/Users/…/.config/git/ignore`, or the backslash spelling — is
    # the same answer as `/*`: an excludes file outside the repository. It gets its own arm because
    # it does not start with `/`, so before #174 it fell through to the `*)` branch below and the
    # guard told a Git Bash user to `commit` their global excludes file — on the one host this
    # whole change exists to fix. Unreachable until rule_source() started returning anything there
    # at all, which is exactly why it lands with the rev fix rather than after it.
    /*|[A-Za-z]:/*|[A-Za-z]:\\*)
          printf '  note: the rule lives in %s (a global excludes file), not in this repo — it\n' "$src"
          printf '        protects this machine only; teammates and CI still stage the worktree.\n' ;;
    .git/*) printf '  note: the rule lives in %s, which is NOT committed — it protects this\n' "$src"
          printf '        checkout only; teammates and CI still stage the worktree.\n' ;;
    *)    git -C "$REPO" ls-files --error-unmatch "$src" >/dev/null 2>&1 && return 0
          printf '  note: %s is not tracked by git, so the rule travels with nobody — commit it.\n' "$src" ;;
  esac
}

failed=0
for home in $WORKTREE_HOMES; do
  if git -C "$REPO" check-ignore -q "$home"; then
    printf 'worktrees-ignored: ok — %s is ignored\n' "$home"
    durability_note "$(rule_source "$home")"
  else
    failed=1
    printf 'worktrees-ignored: REFUSED — %s is NOT ignored.\n' "$home" >&2
    printf '  A worktree left there is staged by any `git add -A` run in this repo, as one\n' >&2
    printf '  gitlink (160000) pointing at a commit no clone can fetch — see #43.\n' >&2
    printf '  fix: add "%s" to .gitignore.\n' "$home" >&2
  fi
done
[ "$failed" -eq 0 ] || exit 1

if git -C "$REPO" check-ignore -q "$MUST_STAY_VISIBLE"; then
  printf 'worktrees-ignored: BROADENED — %s is ignored too.\n' "$MUST_STAY_VISIBLE" >&2
  printf '  Every worktree home above IS ignored, so there is no #43 hazard here — 2 is a different\n' >&2
  printf '  verdict from 1, not a worse one, and a caller about to create a worktree may proceed.\n' >&2
  printf '  What it costs: the rule was broadened (most likely to `.claude/`), and consumer repos are\n' >&2
  printf '  told to COMMIT that file — it is how the lifecycle skills read repo facts, so a repo that\n' >&2
  printf '  hides it cannot carry a profile.\n' >&2
  printf '  fix: ignore the worktree homes specifically, not all of .claude/.\n' >&2
  exit 2
fi
printf 'worktrees-ignored: ok — %s is still visible\n' "$MUST_STAY_VISIBLE"
