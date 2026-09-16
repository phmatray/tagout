#!/usr/bin/env bash
# _assert-branch.sh — the branch assertion, in one place. SOURCED by the guards, never executed.
#
# Why this file exists (#44). guarded-commit.sh and guarded-push.sh enforce one invariant — HEAD
# must be the branch the caller named — and each carried its own copy of it: refuse(), the usage()
# slice, the is-this-a-repo check, and the whole symbolic-ref pre-flight including its four-line
# comment. Two copies of the security-relevant part of a guard is two things to review and one of
# them to forget. They had already drifted before #30 merged: its /code-review pass found that one
# script validated an option's value and the other did not, so a typo fell through to a bare exit 1
# — the code these scripts document as "git's own failure", which a caller may read as transient and
# retry. This portfolio has been bitten by the shape before: the same IndexError lived in three
# tools in repo-audit, was fixed in one, and stayed live in the other two until someone went looking.
#
# The leading underscore says this is not a command. There is deliberately no `set -euo pipefail`
# here: the callers set it, and re-setting it in a sourced file would mean this file silently
# decides the shell options of every script that loads it.
#
# ---------------------------------------------------------------------------------- the contract
#
#   refuse <tool-name> <message…>
#       Print "<tool-name>: REFUSED — <message>" on stderr and exit 2.
#
#       The tool name is an ARGUMENT and not derived from $0. Deriving it would be free, and would
#       make the message prefix a function of whatever the file happens to be called — while the
#       prefix is a published constant: the golden test matches on it, and so does the
#       troubleshooting table in ../references/github-mechanics.md. A renamed file, a symlink, or a
#       copy must not be able to change it.
#
#   usage
#       Print the caller's own header block, whatever length it happens to be. `$0` stays the
#       SOURCING script inside a sourced file, so one definition documents every guard. Not a
#       hardcoded line range: that silently stops printing before the exit-code table the moment a
#       line is added above it, and --help is exactly what someone reads when they have hit an exit
#       code they do not recognise.
#
#   head_branch_of <repo>
#       Echo the branch HEAD points at, or nothing at all when HEAD is detached. Used by
#       assert_branch below AND by each guard's post-write re-assertion, so the one subtle thing
#       about reading a branch name lives in one function rather than in three places.
#
#   head_sha_of <repo> [<rev>]
#       Echo the ABBREVIATED sha of <rev> (default HEAD), or nothing at all when it cannot be
#       read. The counterpart of head_branch_of, and it exists for the same reason one function
#       later (#129): reading a branch name had a home, reading a sha did not, so every message
#       that wanted one respelled the read — four spellings across four files, and three of them
#       interpolated a bare `$(git … rev-parse …)` straight into a printf argument, where a
#       failure is neither aborted by `set -e` nor reflected in the statement's status. Two of
#       those three were SUCCESS RECEIPTS, so `guarded-commit: a@` was a reachable output with a
#       zero exit: the strongest claim a guard makes, naming no commit.
#
#       Failure-tolerant BY DESIGN, exactly as head_branch_of is, and for the same reason: the
#       callers run under `set -euo pipefail`, and a helper that died on an unreadable HEAD would
#       abort the guard with exit 1 — the ambiguous "git's own failure" code this file exists to
#       avoid — at the very moment it was being asked to explain what went wrong. The emptiness
#       is the answer, and every caller renders it explicitly as `${…:-<unreadable>}` in a
#       statement of its own. NEVER inline this into a printf argument; that is the defect.
#
#       `--verify --quiet` and not a bare `--short <rev>`: the same trap assert_branch documents
#       at the tail of this file. It keeps git's "Needed a single revision" off stderr on the
#       unborn-HEAD path (where the abbreviating form exits 128 with empty stdout), and it makes
#       an unresolvable <rev> answer nothing rather than something. The optional <rev> is what
#       lets guarded-commit.sh abbreviate `$EXPECTED` — a branch, not HEAD — through this same
#       one home instead of opening a fifth spelling.
#
#   head_sha_full_of <repo> [<rev>]
#       Echo the FULL sha of <rev> (default HEAD), or nothing at all when it cannot be read.
#       head_sha_of's counterpart for the WITNESS use rather than the DISPLAY use: a caller
#       that is going to COMPARE a sha (assert_branch's own pre-flight $head_sha, and
#       guarded-push.sh's post-push re-assert) needs the full value, not an abbreviation, and
#       both of those had grown their own copy of the read before this function existed (#161)
#       — the exact "no home, so every caller respells it" shape #129 found in the abbreviating
#       read, one read-kind later.
#
#       Same failure-tolerance as head_sha_of, for the same reason (a witness read that died on
#       an unreadable HEAD would abort the guard with `set -e`'s exit 1 at the moment it was
#       needed to explain what went wrong), and the same trap in the tail of this file: `--verify
#       --quiet`, never a bare `rev-parse HEAD 2>/dev/null || true`, which prints the literal
#       string "HEAD" on an unborn branch and exits 128 (#92) — `|| true` would hand the caller
#       "HEAD" as though it were a sha. NEVER inline this into a printf/echo argument either;
#       that is the same defect head_sha_of's contract already names, in the same shape.
#
#   repo_readable <repo>
#       Succeeds while <repo> can still be read as a git repository. Not a validator — the
#       pre-flight in assert_branch below is that — but the second half of a MEASUREMENT the
#       post-write re-asserts need and used to skip.
#
#   head_state <repo> <branch-as-read>
#       How a message should NAME where HEAD is: the branch it is on, or the word `detached`, or
#       `<unreadable>`.
#
#       It exists because head_branch_of answers with nothing in TWO situations — HEAD is
#       genuinely detached, and the repo cannot be read AT ALL — and only one caller is entitled
#       to collapse them. assert_branch's pre-flight is that caller: it has just proven the path
#       is a git repository, so empty there really does mean detached. Every POST-WRITE re-assert
#       had proven no such thing and still rendered `${now_branch:-detached}`, stating as a
#       definite fact something never measured — when the honest answer may be "the worktree is
#       gone", which is precisely the concurrency class these guards exist for (#129).
#
#       Measured, before the fix: a commit that landed safely on its own branch, with HEAD never
#       leaving it, was reported as detached, "reachable from nothing and will be
#       garbage-collected", with a rescue command to run. Every word false, on the sentence the
#       operator acts on.
#
#       It takes the branch the caller ALREADY read instead of reading it again, so the answer
#       describes the same observation the message is reporting on, and so the readability probe
#       runs once and only when there is something to disambiguate. head_branch_of's own contract
#       is deliberately unchanged: widening it would relax a reading three guards depend on in
#       order to fix a rendering in one of their paths.
#
#   head_state_unreadable <branch-as-read> <state>
#       True when head_state's answer means "this path could not be read", as opposed to a branch
#       name or a genuine detachment. Pure string logic over two values the caller already holds
#       — no second probe — and a FUNCTION rather than the same two-line test written out in each
#       guard, because the same small test written out in each guard is the whole subject of #129.
#
#       BOTH arguments are consulted, and that is the point: head_state only ever answers
#       `<unreadable>` for an EMPTY branch, so pairing them means a branch literally NAMED
#       `<unreadable>` — git's ref rules permit it — cannot make a guard describe a healthy
#       repository as gone.
#
#   assert_worktree_live <tool-name>
#       Refuses (exit 2) when make-worktree.sh recorded a path for $EXPECTED and $REPO's live
#       toplevel is not it — the worktree was destroyed mid-run and discovery walked up to the
#       parent checkout (#469). No record, or an unreadable $REPO: returns 0 and leaves the
#       diagnosis to assert_branch. Every guard calls it immediately BEFORE assert_branch, so a
#       relocation is named as one rather than as a branch mismatch. Contract in full above its
#       definition below.
#
#   assert_branch <tool-name> <detached-message> <mismatch-message>
#       Reads   $REPO      the worktree to inspect
#               $EXPECTED  the branch the caller says this task owns
#       Sets    $head_sha  HEAD's full sha — the witness for the caller's own post-write comparison
#
#       Those two are read as globals, per this file's contract, so a caller that forgets to set
#       one would die on `set -u`'s "unbound variable" with exit 1 — the ambiguous "git's own
#       failure" code this entire file exists to avoid, produced by the one function whose job is
#       to refuse with 2. They are therefore checked, not assumed.
#       Returns 0 only when HEAD is a branch and that branch is $EXPECTED. Every other outcome —
#       $REPO is not a directory, not a git repository, HEAD is detached, HEAD is another branch —
#       refuses with exit 2 and writes nothing.
#
#       The two messages belong to the CALLER because the consequence genuinely differs per tool:
#       an unguarded commit lands work on the wrong branch and a later push carries it into that
#       branch's pull request, while an unguarded push carries it there itself. Flattening both
#       into one generic sentence would trade the only part of a refusal a reader acts on for a
#       slightly smaller diff. In <mismatch-message> the token `{found}` stands for the branch HEAD
#       is actually on, and may appear as often as the prose needs it.
#
#       That token is substituted as a plain string, NOT through printf. A branch name is data from
#       outside this process, and a `%` in one reaching a format string is a bug waiting for the
#       branch that contains it; positional printf specifiers would also have to be trusted to
#       behave identically on every bash the kit runs under.

# Sourced, not run. Without this, a stray `chmod +x` turns the helper into something that looks
# like a command, asserts nothing, and exits 0 — the most misleading thing a guard-shaped file can
# do. `${BASH_SOURCE[0]:-}` because the callers run under `set -u`.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  printf '_assert-branch.sh: this file is sourced by the guarded-* scripts, not run directly.\n' >&2
  exit 2
fi

refuse() {
  local tool="$1"; shift
  printf '%s: REFUSED — %s\n' "$tool" "$*" >&2
  exit 2
}

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

# `symbolic-ref` and not `rev-parse --abbrev-ref HEAD`: on a detached HEAD the latter prints the
# literal string "HEAD", which compares as a plain branch name and would sail past a naive string
# test. symbolic-ref simply fails, which is the answer we want — so an empty answer here means
# "detached", and every caller reads it that way.
head_branch_of() { git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || true; }

# The sha half of the same job — see the contract above for why it answers with nothing rather
# than dying, and why no caller may inline it into a printf argument.
head_sha_of() { git -C "$1" rev-parse --verify --quiet --short "${2:-HEAD}" 2>/dev/null || true; }

# The FULL-sha counterpart, for witness comparisons rather than display — see the contract
# above (#161). `--verify --quiet`, not `--short`: this is the read a caller diffs against a
# value captured earlier, and abbreviating either side independently risks comparing prefixes
# of two different objects instead of the objects themselves.
head_sha_full_of() { git -C "$1" rev-parse --verify --quiet "${2:-HEAD}" 2>/dev/null || true; }

# The disambiguator for head_branch_of's empty answer — see the contract above. Kept here, once,
# rather than as a third copy of the same `if` in each guard: the whole of #129 is what respelling
# a small read at every call site costs.
repo_readable() { git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }

# `${2:-}` and not a bare `$2`: every caller runs under `set -u`, where a function reached with
# one argument dies on "unbound variable" with exit 1 — the ambiguous "git's own failure" code
# this whole file exists to avoid, produced by a helper whose job is to explain what went wrong.
# An absent branch and an empty one mean the same thing here, so the default costs nothing.
head_state() {
  if [ -n "${2:-}" ]; then
    # `printf '%s'` and not `echo`: a branch name is data from outside this process, and this
    # file already refuses to let one reach a format string (see {found}, below).
    printf '%s' "$2"
  elif repo_readable "$1"; then
    printf 'detached'
  else
    printf '<unreadable>'
  fi
}

head_state_unreadable() { [ -z "${1:-}" ] && [ "${2:-}" = '<unreadable>' ]; }

# assert_worktree_live <tool-name>  (#469, healed by #644)
#     Reads   $REPO      the worktree the caller named
#             $EXPECTED  the branch this task owns
#     Returns 0 when make-worktree.sh recorded no path for $EXPECTED (nothing was ever asserted
#             about this branch — every non-kit caller and every pre-existing worktree, byte for
#             byte as before), or when the record equals $REPO's live toplevel. Also 0 when
#             $REPO cannot be read as a repository at all: assert_branch refuses that a moment
#             later with its own diagnosis, and refusing here would only respell it.
#
#     On a mismatch, asks git's own worktree admin — not just the stale record — which tree holds
#     $EXPECTED now: git worktree list --porcelain is read once and walked (paths only, never a
#     field split) to find the 1-based POSITION of the entry whose path resolves to $top. The
#     branch $top itself holds is then read straight off $top through head_branch_of — this file's
#     one home for that read (#129) — rather than trusted from the porcelain listing's own "branch "
#     line, which could go stale if two entries ever resolved to the same physical path.
#       - That entry is a LINKED worktree (not the first/main entry) and head_branch_of says it
#         holds $EXPECTED: the branch legitimately moved trees (a worker's own
#         `git worktree remove` + `switch`, #510's release-branch.sh handing a PR branch to a
#         re-dispatched worker, a harness cleanup) — this is not the #469 relocation. Heal the
#         record to $top, note it on stderr, and return 0: passes.
#       - That entry IS the first/main entry: the #469 relocation — discovery walked up to the
#         parent checkout. Refuses exactly as before, naming the recorded path and $top.
#       - That entry is some OTHER linked worktree, holding neither $EXPECTED nor the main
#         checkout: refuses, naming $top and that it does not hold $EXPECTED — never the
#         "parent checkout" wording, which would misdiagnose it.
#
#     Why the record heals rather than only refusing: the worktree home `.claude/worktrees/` sits
#     INSIDE the main checkout, so a worktree destroyed mid-run (`rm -rf` + `mkdir`, or any
#     sweeper) does not fail — git's upward discovery walks out of the dead tree and lands on the
#     parent, and every command from then on runs in the USER'S checkout with exit 0. Measured
#     2026-09-05: a fleet worker kept going there; assert_branch caught only the commit, by luck
#     (HEAD was `main`, not the task's branch), and diagnosed it as a branch mismatch. The record
#     make-worktree.sh writes lives in the common .git/config, so it survives the tree it
#     describes — but comparing it ONLY to the live toplevel could not tell that relocation from a
#     branch git itself says legitimately moved to another live linked worktree (#644: 3 refusals
#     in 2 fleet runs took exactly that route). Every path comparison goes through `pwd -P`,
#     because `rev-parse --show-toplevel` answers with symlinks resolved.
assert_worktree_live() {
  local tool="$1" recorded recorded_phys shown top
  local entry idx path found_idx
  [ -n "${REPO:-}" ]     || refuse "$tool" "internal: \$REPO is unset — the caller must set it before calling assert_worktree_live."
  [ -n "${EXPECTED:-}" ] || refuse "$tool" "internal: \$EXPECTED is unset — the caller must set it before calling assert_worktree_live."
  repo_readable "$REPO" || return 0
  recorded=$(git -C "$REPO" config --get "kit.worktree.${EXPECTED}.path" 2>/dev/null || true)
  [ -n "$recorded" ] || return 0
  top=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$top" ] || refuse "$tool" "the worktree recorded for '$EXPECTED' at $recorded has no readable toplevel from $REPO — it was destroyed mid-run. Nothing written."
  top=$(CDPATH= cd -- "$top" 2>/dev/null && pwd -P) || true
  # Keep the RAW record intact even when it no longer resolves — recorded_phys, not recorded
  # itself, is what the physical-path cd may fail on. Folding the fallback into `recorded` (the
  # old shape) had already captured the empty command-substitution output by the time `||` fired,
  # so the message read "recorded at  (gone)" with the path itself erased (#644).
  recorded_phys=$(CDPATH= cd -- "$recorded" 2>/dev/null && pwd -P) || recorded_phys=""
  shown=${recorded_phys:-"$recorded (gone)"}
  if [ "$top" = "$recorded_phys" ]; then return 0; fi

  # Mismatch: ask git's own worktree admin which entry $top actually is — only the POSITION
  # matters here (is it the first/main entry, or a linked one?), so this walks paths only. Same
  # idiom as make-worktree.sh's EXISTING lookup — `substr($0, 10)`, never a field split, so a path
  # containing a space survives. The branch $top itself holds is read straight off $top through
  # head_branch_of below — this file's one home for that read (#129) — rather than trusted from a
  # second porcelain "branch " line, which would go stale if two entries ever resolved to the same
  # physical path (a stale/prunable admin record re-registered by `worktree add -f`).
  found_idx="" idx=0 path=""
  while IFS= read -r entry; do
    case "$entry" in
      "worktree "*)
        if [ -n "$path" ] && [ "$(CDPATH= cd -- "$path" 2>/dev/null && pwd -P || true)" = "$top" ]; then
          found_idx=$idx
        fi
        idx=$((idx + 1))
        path=${entry#worktree }
        ;;
    esac
  done <<EOF
$(git -C "$REPO" worktree list --porcelain 2>/dev/null || true)
EOF
  if [ -n "$path" ] && [ "$(CDPATH= cd -- "$path" 2>/dev/null && pwd -P || true)" = "$top" ]; then
    found_idx=$idx
  fi

  if [ -n "$found_idx" ] && [ "$found_idx" -gt 1 ] && [ "$(head_branch_of "$top")" = "$EXPECTED" ]; then
    if git -C "$REPO" config "kit.worktree.${EXPECTED}.path" "$top"; then
      printf '%s: note — kit.worktree.%s.path named %s; %s holds '"'"'%s'"'"' now, record updated.\n' \
        "$tool" "$EXPECTED" "$shown" "$top" "$EXPECTED" >&2
    else
      printf '%s: warning: could not update kit.worktree.%s.path — the liveness guard will keep comparing against the stale record.\n' \
        "$tool" "$EXPECTED" >&2
    fi
    return 0
  fi

  if [ "$found_idx" = "1" ]; then
    refuse "$tool" "the worktree for '$EXPECTED' was recorded at $shown, but $REPO now resolves to $top — the worktree was destroyed mid-run and git discovery walked up to the parent checkout. Nothing written. Recreate the worktree (make-worktree.sh) and retry there."
  fi
  refuse "$tool" "the worktree for '$EXPECTED' was recorded at $shown, but $REPO resolves to $top, a worktree that does not hold '$EXPECTED'. Nothing written."
}

# assert_branch is defined LAST on purpose, and each guard's bootstrap leans on it: that check
# tests for `assert_branch` and `refuse`, the last and the first function here, so a helper
# truncated anywhere in between still fails the check instead of surviving to a `command not
# found` (exit 127) at the first call. Adding a function BELOW this one would quietly break that
# — put new helpers above it. Enforced by tests/guarded-git/test.sh case 33e (#161): it extracts
# this file's top-level function names in order and fails if the first is not `refuse` or the
# last is not `assert_branch`, and it fails separately if any guard's bootstrap stops naming both.
assert_branch() {
  local tool="$1" detached_message="$2" mismatch_message="$3"
  local head_branch

  # The contract's two globals, checked rather than assumed — see the header for why an unbound
  # variable would be the worst possible outcome of a guard's own assertion.
  [ -n "${REPO:-}" ]     || refuse "$tool" "internal: \$REPO is unset — the caller must set it before calling assert_branch."
  [ -n "${EXPECTED:-}" ] || refuse "$tool" "internal: \$EXPECTED is unset — the caller must set it before calling assert_branch."

  [ -d "$REPO" ] || refuse "$tool" "-C path is not a directory: $REPO"

  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
    || refuse "$tool" "not a git repository: $REPO"

  head_branch=$(head_branch_of "$REPO")

  [ -n "$head_branch" ] || refuse "$tool" "$detached_message"

  [ "$head_branch" = "$EXPECTED" ] \
    || refuse "$tool" "${mismatch_message//\{found\}/$head_branch}"

  # Tolerant of failure on purpose: on an unborn branch (freshly `git init`ed, nothing committed)
  # symbolic-ref succeeds while HEAD resolves to no commit, and dying there under the caller's
  # `set -e` would turn a legitimate first commit into an unexplained exit 1. The callers treat an
  # empty $head_sha as "there is no tip yet" — guarded-commit.sh because that is the normal state
  # before a first commit, guarded-push.sh by refusing, because it has nothing to verify.
  #
  # Through head_sha_full_of — see its contract above for why `--verify --quiet` and not a bare
  # `rev-parse HEAD 2>/dev/null || true` (#92) — which is also this witness read's one home (#161):
  # guarded-push.sh's post-push re-assert needs the identical value and reads it through the same
  # function rather than respelling it.
  head_sha=$(head_sha_full_of "$REPO")
}
