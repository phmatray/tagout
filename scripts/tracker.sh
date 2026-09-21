#!/usr/bin/env bash
# tracker.sh — route a named tracker verb to the backend the profile selects (#505).
#
# usage: tracker.sh [--tracker <name>] [--repo|-R <slug>] <verb> [args…]
#        tracker.sh [--tracker <name>] state <skill>
#        tracker.sh --help
#
# `-R` is an alias of `--repo` (#668). The repository had five spellings across the kit's scripts;
# `-R <[host/]owner/repo>` is the one `guarded-pr-merge.sh` and `base-run-verdict.sh` already take
# and the one `_gh-host.sh` already parses, so it is the one the rest converge on. A verb's own
# arguments take it too — the backend lifts it out before resolving the host.
#
# WHY THIS EXISTS. Every tracker operation in this kit is a direct `gh` call — 111 lines across 18
# scripts, 189 across 39 prose files — and `skills/_shared/preconditions.md` could answer only
# "GitHub, or stop". There was no place a second host's dialect could live, and no way to say
# "`create-issue` works on GitLab, `merge-pr` does not yet". This is the seam: a verb has one name
# here, one row in `scripts/tracker/contract.json`, and one implementation per host under
# `scripts/tracker/<tracker>.sh`.
#
# WHAT IT DOES NOT DO, said here because a header promising more than the code performs stops the
# next reader adding the check that is missing:
#   * it does not move any existing call site. Every skill still calls `gh` directly today; this is
#     the *expand* step, and each skill migrates on its own change (see `skills` in contract.json).
#   * it does not decide whether a skill may run. That is the registered decision `tracker.capable`,
#     which reads the `state` report below. This dispatcher reports; the decision judges.
#   * it does not report a missing profile. `repo-profile.sh tracker` exiting 3 means "no committed
#     profile, or none that names a tracker", and the answer there is `github` — today's behaviour.
#     The missing profile is preconditions' own profile load to report, never this dispatcher's.
#
# ORDER OF OPERATIONS, each step where it is deliberately:
#   1. KIT_ROOT is resolved from $0 THROUGH SYMLINKS, the way scripts/decide.sh does it: a plugin
#      install reaches this file by link, and `pwd -P` alone canonicalizes the directory, not the
#      link, so it would look for the contract beside the LINK.
#   2. THE VERB IS VALIDATED BEFORE THE BACKEND IS RESOLVED. A typo must be exit 2 on every host
#      rather than "not implemented" on the hosts that happen to lack it — otherwise `frobnicate`
#      reads as a gap in the backend and somebody implements it.
#   3. The tracker is resolved only after that, and never from a guess: `--tracker`, else the
#      profile's Tracker line, else `github`.
#   4. A backend is asked what it implements (`<backend> verbs`) rather than being assumed to cover
#      the whole table, so a half-migrated host says so instead of failing inside a verb.
#
# Exit codes:
#   0  the verb ran and printed its contract's stdout
#   1  the host refused or failed (the backend's own failure — auth, network, a 404)
#   2  bad invocation: an unknown verb, a missing argument, no verdict from the profile probe
#   3  NOT IMPLEMENTED: no backend for this tracker, or a backend whose `verbs` lacks this verb
set -euo pipefail

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

die() {
  _rc="$1"; shift
  printf 'tracker: %s\n' "$1" >&2
  shift
  while [ $# -gt 0 ]; do printf '  %s\n' "$1" >&2; shift; done
  exit "$_rc"
}

# ------------------------------------------------------------------------------- 1. self-location
SELF="$0"
while [ -L "$SELF" ]; do
  _link=$(readlink -- "$SELF") || break
  case "$_link" in
    /*) SELF="$_link" ;;
    *)  SELF="$(dirname -- "$SELF")/$_link" ;;
  esac
done
# The `||` fallback is not decoration: this is a plain assignment from a command substitution, so
# under `set -e` a failing cd would kill the script HERE with exit 1 and not a word.
KIT_ROOT=$(CDPATH= cd -- "$(dirname -- "$SELF")/.." && pwd -P) || KIT_ROOT="$(dirname -- "$SELF")/.."
CONTRACT="$KIT_ROOT/scripts/tracker/contract.json"
PROFILE_SH="$KIT_ROOT/skills/profile-repo/scripts/repo-profile.sh"

# ------------------------------------------------------------------------------ 2. the arguments
TRACKER=""
TRACKER_REPO_ARG=""
VERB=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)  usage; exit 0 ;;
    --tracker)  [ $# -ge 2 ] || die 2 "--tracker needs a name"; TRACKER="$2"; shift 2 ;;
    --repo|-R)  [ $# -ge 2 ] || die 2 "$1 needs a slug";        TRACKER_REPO_ARG="$2"; shift 2 ;;
    --)         shift; break ;;
    -*)         die 2 "unexpected option: $1" "usage: tracker.sh [--tracker <name>] [--repo|-R <slug>] <verb> [args…]" ;;
    *)          VERB="$1"; shift; break ;;
  esac
done

[ -n "$VERB" ] || die 2 "no verb given" \
  "usage: tracker.sh [--tracker <name>] [--repo|-R <slug>] <verb> [args…]"

command -v jq > /dev/null 2>&1 || \
  die 2 "jq is missing — it is a \`required\` prerequisite in requirements.json" \
        "The verb table and every normalised reply are read through it."

[ -r "$CONTRACT" ] || \
  die 2 "cannot read $CONTRACT" \
        "The contract is the list of verbs this kit knows. Without it there is nothing to route."
jq -e . "$CONTRACT" > /dev/null 2>&1 || die 2 "$CONTRACT is not valid JSON"

# --------------------------------------------------------------- 3. resolve the tracker (shared)
#
# `--tracker` wins; else the profile's Tracker line; else `github`. Exit 2 from the probe is NOT a
# verdict (it means the directory argument was wrong), so it must not be read as "no profile".
resolve_tracker() {
  DETAIL=""
  if [ -n "$TRACKER" ]; then
    return 0
  fi
  local out="" rc=0
  out=$("$PROFILE_SH" tracker 2>/dev/null) || rc=$?
  case "$rc" in
    0)
      TRACKER=$(printf '%s\n' "$out" | awk 'NR==1 {print $1}')
      DETAIL=$(printf '%s\n' "$out" | awk 'NR==1 {print $2}')
      [ -n "$TRACKER" ] || die 2 "the profile's Tracker line named no tracker" \
        "Read from $PROFILE_SH tracker. Fix the profile, or pass --tracker."
      ;;
    3)
      # No committed profile, or one that names no tracker. Today's behaviour is GitHub.
      TRACKER="github"
      ;;
    *)
      die 2 "the profile probe reached no verdict (exit $rc)" \
            "That is not \"no profile\" — $PROFILE_SH could not answer at all."
      ;;
  esac
}

# --------------------------------------------------------------------- 4. `state` — a report
#
# Not a verb, and deliberately not a decision: it gathers the five facts `tracker.capable` needs and
# judges none of them. `needs` is null when the skill is not on the contract; `implements` is null
# when there is no backend at all — two different absences, and the decision tells them apart.
if [ "$VERB" = state ]; then
  SKILL="${1-}"
  [ -n "$SKILL" ] || die 2 "state needs a skill name" "usage: tracker.sh state <skill>"
  resolve_tracker

  NEEDS=$(jq -c --arg s "$SKILL" '.skills[$s] // null' "$CONTRACT")

  BACKEND="$KIT_ROOT/scripts/tracker/$TRACKER.sh"
  IMPL=null
  if [ -x "$BACKEND" ]; then
    _verbs=$("$BACKEND" verbs 2>/dev/null) || _verbs=""
    IMPL=$(printf '%s' "$_verbs" | jq -R -s 'split("\n") | map(select(length > 0))')
  fi

  jq -n --arg t "$TRACKER" --arg d "$DETAIL" --arg s "$SKILL" \
        --argjson needs "$NEEDS" --argjson implements "$IMPL" \
        '{tracker: $t, detail: $d, skill: $s, needs: $needs, implements: $implements}'
  exit 0
fi

# ------------------------------------------------------- 5. the verb, BEFORE any backend resolves
KNOWN=$(jq -r --arg v "$VERB" 'if (.verbs | has($v)) then "yes" else "no" end' "$CONTRACT")
if [ "$KNOWN" != yes ]; then
  printf 'tracker: unknown verb: %s\n' "$VERB" >&2
  printf '  It is not in %s. Known verbs:\n' "$CONTRACT" >&2
  jq -r '.verbs | keys[]' "$CONTRACT" | sed 's/^/    - /' >&2
  printf '  A verb absent from the contract is a bad invocation on EVERY host, not a gap in one.\n' >&2
  exit 2
fi

# ------------------------------------------------------------------------------ 6. the backend
resolve_tracker
BACKEND="$KIT_ROOT/scripts/tracker/$TRACKER.sh"

not_implemented() {
  printf 'NOT_IMPLEMENTED %s %s\n' "$TRACKER" "$VERB" >&2
  printf '  %s\n' "$1" >&2
  printf '  The verb is on the contract; this host does not answer it yet. See skills/_shared/tracker-contract.md.\n' >&2
  exit 3
}

[ -x "$BACKEND" ] || not_implemented "no backend at scripts/tracker/$TRACKER.sh"

# Ask the backend what it implements rather than assuming it covers the whole table: a half-migrated
# host must say so here, not fail somewhere inside a verb.
IMPLEMENTED=$("$BACKEND" verbs 2>/dev/null) || \
  not_implemented "scripts/tracker/$TRACKER.sh could not list its verbs"

FOUND=no
for _v in $IMPLEMENTED; do
  if [ "$_v" = "$VERB" ]; then
    FOUND=yes
  fi
done
[ "$FOUND" = yes ] || not_implemented "scripts/tracker/$TRACKER.sh does not list '$VERB' among its verbs"

# `--repo` reaches the backend as TRACKER_REPO, which is where every backend takes the repository
# from. Exported for the backend and every gh child it spawns; the backend's exit code is this
# script's exit code, so a host refusal stays a 1 and never reads as a bad invocation.
export TRACKER_REPO="$TRACKER_REPO_ARG"
exec "$BACKEND" "$VERB" "$@"
