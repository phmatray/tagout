#!/usr/bin/env bash
# repo-setup.sh — bring a repository to the configuration the lifecycle skills assume (#192).
#
# profile-repo's repo-profile.sh answers "what IS this repo?" and both of its verbs read.
# There was no verb answering "make this repo what the skills need", so a probe that found no
# priority:/effort:/area: axis and no .github/ISSUE_TEMPLATE/ could only print `TODO: <hint>` —
# correct for a fact it cannot read, wrong for a configuration the repo does not HAVE. This script
# is the missing half.
#
#   plan [dir]     Diff the desired state against the live repository and print the delta. Writes
#                  NOTHING, so it is safe against a repo you only read. Exit 1 when drift remains,
#                  which makes it usable as a CI drift gate.
#
#   apply [dir]    Converge it. Idempotent: a second run issues no writes.
#
# Options: --manifest <path>   desired state (default: the target repo's .github/repo-setup.yml,
#                              else the kit's templates/repo-setup.yml)
#          --prune             also DELETE live labels the manifest does not declare — and, when
#                              the manifest declares `topics:`, live topics it does not name
#                              (#400). Never the default: a repo that already runs P1/P2 must not
#                              have its taxonomy renamed out from under it.
#
# Exit codes:
#   0  converged (plan) / applied cleanly (apply)
#   1  drift found (plan only)
#   2  bad usage, a manifest that cannot be read or parsed, or the kit's host helper
#      (skills/_shared/scripts/_gh-host.sh, #514) missing
#   3  partially applied — a surface was refused (no admin scope, no gh auth). The report names it.
#   4  not inside a git repository  (the same meaning repo-profile.sh gives 4, deliberately)
#
# No `set -e`: this script's job is to keep going when ONE surface refuses and report the rest,
# which errexit would turn into an abort. Failures are checked at each call site instead — the
# same reasoning repo-profile.sh states for its own `set -uo pipefail`.
set -uo pipefail

# Resolved BEFORE the cd below: $0 can be relative, and cd-ing into the target repo breaks it.
# Kit root = three levels up from skills/init/scripts. $0 through any symlinks first — a
# plugin install reaches this file by link, and `pwd -P` alone canonicalizes the directory, not the
# link. No `readlink -f`: macOS's readlink has no -f. Same loop base-run-verdict.sh carries (#514,
# #531).
SELF="$0"
while [ -L "$SELF" ]; do
  _link=$(readlink -- "$SELF") || break
  case "$_link" in
    /*) SELF="$_link" ;;
    *)  SELF="$(dirname -- "$SELF")/$_link" ;;
  esac
done
KIT_ROOT=$(CDPATH= cd -- "$(dirname -- "$SELF")/../../.." && pwd -P) \
  || KIT_ROOT="$(dirname -- "$SELF")/../../.."
PARSER="$KIT_ROOT/skills/init/scripts/parse-manifest.py"
PROJECTOR="$KIT_ROOT/skills/init/scripts/project-area-options.py"
FORMS_DIR="$KIT_ROOT/templates/issue-forms"
DEFAULT_MANIFEST="$KIT_ROOT/templates/repo-setup.yml"
REPO_LOCAL_MANIFEST=".github/repo-setup.yml"
FORMS_TARGET=".github/ISSUE_TEMPLATE"

USAGE="usage: repo-setup.sh {plan|apply} [dir] [--manifest <path>] [--prune]"

usage_err() { echo "ERR: $1" >&2; echo "$USAGE" >&2; exit 2; }

# ------------------------------------------------------------------------------ argument parsing

VERB="${1:-}"
[ $# -gt 0 ] && shift

DIR=""
MANIFEST=""
PRUNE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)
      # `[ $# -ge 2 ]` rather than a non-empty test on $2: `--manifest --prune` must be a usage
      # error, not a manifest literally named "--prune", and `--manifest` at end-of-args must not
      # silently become the default.
      [ $# -ge 2 ] || usage_err "--manifest needs a path"
      case "$2" in -*) usage_err "--manifest needs a path, got the option '$2'" ;; esac
      MANIFEST="$2"; shift 2 ;;
    --prune) PRUNE=1; shift ;;
    --) shift ;;
    -*) usage_err "unknown option '$1'" ;;
    *)
      [ -z "$DIR" ] || usage_err "unexpected extra argument '$1'"
      DIR="$1"; shift ;;
  esac
done

case "$VERB" in
  plan|apply) ;;
  "") usage_err "no verb given" ;;
  *)  usage_err "unknown verb '$VERB'" ;;
esac

# ------------------------------------------------------------------------------------ where am I

# An explicit --manifest is resolved against the CALLER's directory, before the cd below. Otherwise
# `repo-setup.sh plan ../other-repo --manifest my.yml` looks for my.yml inside other-repo — a path
# the caller never typed, and one that usually exists nowhere, so the run dies on exit 2 pointing at
# a file the operator did not ask for.
if [ -n "$MANIFEST" ]; then
  case "$MANIFEST" in
    /*|[A-Za-z]:[\\/]*) ;;                      # already absolute, POSIX or Windows drive form
    *) MANIFEST="$PWD/$MANIFEST" ;;
  esac
fi

[ -z "$DIR" ] && DIR="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$DIR" 2>/dev/null || { echo "ERR: cannot cd to '$DIR'" >&2; exit 2; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "ERR: not inside a git repository — nothing to configure." >&2; exit 4; }

# ------------------------------------------------------------------------------- desired state

# Precedence: an explicit --manifest always wins; then the target repo's own copy, so a consumer's
# edits survive a kit upgrade; then the shipped default.
if [ -z "$MANIFEST" ]; then
  if [ -r "$REPO_LOCAL_MANIFEST" ]; then
    MANIFEST="$REPO_LOCAL_MANIFEST"
  else
    MANIFEST="$DEFAULT_MANIFEST"
  fi
fi

[ -r "$MANIFEST" ] || { echo "ERR: cannot read the manifest '$MANIFEST'" >&2; exit 2; }
[ -r "$PARSER" ] || { echo "ERR: parser missing at '$PARSER'" >&2; exit 2; }
[ -r "$PROJECTOR" ] || { echo "ERR: area-options projector missing at '$PROJECTOR'" >&2; exit 2; }

# The parser exits 2 and explains on stderr for every refusal, so its status is carried straight
# through rather than restated. Captured into a variable because the diff below walks it twice.
WORKDIR="$(mktemp -d 2>/dev/null)" || { echo "ERR: cannot create a temp directory" >&2; exit 2; }
# `local rc=$?` FIRST, always: anything above it overwrites the status being reported, which turns
# a failing run into a silent success. Same invariant tests/_lib.sh states for its own handler.
cleanup() { local rc=$?; rm -rf "$WORKDIR"; return $rc; }
trap cleanup EXIT

DESIRED="$WORKDIR/desired.tsv"
# The parser exits 2 and explains on stderr for every refusal, so its status is carried straight
# through rather than restated.
python3 "$PARSER" "$MANIFEST" > "$DESIRED" || exit 2

# --------------------------------------------------------------------------------- live state

DRIFT=0            # +ADD / ~EDIT / -DEL / !TODO items — what `plan` exits 1 for
TODO_COUNT=0       # the !TODO subset of DRIFT — `apply` never resolves these (#198), so the
                   # verdict message below has to say "edit the manifest", not "run apply"
REFUSED=0          # surfaces that could not be read or written — exit 3, and named in the report
DELTA="$WORKDIR/delta.tsv"
: > "$DELTA"

# Every report row — drift or refusal — shares this column layout, so one place fixes it for
# emit()/refuse() at once (#198): two independent `printf '%-8s %-8s %s\n'` calls already had to
# be kept in sync by hand, and %-8s, not %-7s, matters — `!REFUSED` is eight characters, and a
# narrower column pushes every refusal one place right of the rows the reader is comparing it
# against.
_report_line() {
  printf '%-8s %-8s %s\n' "$1" "$2" "$3"
}

# Every report line goes through here so the machine-readable delta cannot fall out of step with
# what the human was shown: one call writes both. `apply` re-reads $DELTA rather than re-deriving
# the diff.
emit() {
  _report_line "$1" "$2" "$3"
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${4:-}" "${5:-}" "${6:-}" >> "$DELTA"
  case "$1" in
    "+ADD"|"~EDIT"|"-DEL"|"!TODO") DRIFT=$((DRIFT + 1)) ;;
  esac
  [ "$1" = "!TODO" ] && TODO_COUNT=$((TODO_COUNT + 1))
}

refuse() {
  _report_line "!REFUSED" "$1" "$2"
  REFUSED=$((REFUSED + 1))
}

# Collapses a possibly-multi-line stderr capture onto one line: every report row is a single line
# by contract, and an embedded newline would split a status row in two (and could spuriously
# satisfy an unrelated `has_line` check reading the report). Shared by gh_refusal() below and the
# OS-level form-copy refusal, which has no HTTP status to classify but still needs its stderr
# flattened the same way.
flatten_err() {
  printf '%s' "$1" | tr '\n' ' ' | sed 's/  */ /g; s/[[:space:]]*$//'
}

# Turns a failed `gh` call's stderr into the cause it actually names, rather than blaming the
# token for every non-zero exit. Built for `gh label create|edit` (#200), generalized (#222) to
# every `gh`-write-and-report site in this file — label delete, the settings PATCH, and (through a
# custom 403 sentence, see the 4th arg) the two reads (label list, settings). Shapes MEASURED
# against this repository with an authenticated token that has full scope:
#   HTTP 403: ...                                       -> no scope on the token — $4, if given,
#                                                           else the sentence below
#   HTTP 422: Validation Failed (...)\n<field message>   -> the manifest's own value; echo the
#                                                           field message(s) GitHub actually gave
#   anything else                                        -> print the raw message, unrecognised
#                                                           status included, rather than guess
# Never retried: a 422 is the same manifest (or the same read) sent again, and would fail the same
# way (#200).
gh_refusal() {
  # $4 (optional): the exact sentence a 403 should print verbatim, for a call site whose 403
  # already has its own established, tested wording (the settings PATCH's "admin rights", the two
  # reads' pre-#222 sentences) — printed as-is, not wrapped in the "could not VERB 'NAME'" shape
  # below, so existing 403 wording survives unchanged (#222 is about the OTHER statuses).
  local verb="$1" name="$2" err="$3" msg403="${4:-}" flat field
  flat="$(flatten_err "$err")"
  case "$err" in
    *"HTTP 403"*)
      if [ -n "$msg403" ]; then
        printf '%s' "$msg403"
      else
        printf "could not %s '%s' — check the token's scope on this repository" "$verb" "$name"
      fi ;;
    *"HTTP 422"*)
      # Every non-blank line other than the "HTTP 422: Validation Failed (...)" status line is
      # GitHub's own field-level detail. Anchored on CONTENT, not a fixed line number: a `sed -n
      # '2p'` reads whatever gh happens to print second, which is wrong the moment something else
      # (a second simultaneous field error, an unrelated notice gh prints ahead of its own output)
      # shifts what "line 2" means — this instead survives both.
      field="$(printf '%s\n' "$err" | grep -v 'HTTP 422' | sed '/^[[:space:]]*$/d' | tr '\n' ';' | sed 's/;/; /g; s/; *$//')"
      printf "could not %s '%s' — refused (422): %s" "$verb" "$name" "${field:-$flat}" ;;
    *)
      # $flat can be EMPTY — gh killed by signal, or a future build that writes nothing to
      # stderr — and an empty cause must never regress below the old universal sentence this
      # replaced, which was always at least a complete, actionable claim.
      if [ -n "$flat" ]; then
        printf "could not %s '%s' — %s" "$verb" "$name" "$flat"
      else
        printf "could not %s '%s' — gh gave no reason; check the token's scope on this repository" "$verb" "$name"
      fi ;;
  esac
}

# Labels no `--prune` may delete, however undeclared they look. Found by running `plan` against
# this kit's own repository: release-please owns `autorelease: pending` / `autorelease: tagged`,
# the repo profile says in as many words that they are never applied by hand — and a single
# `apply --prune` would have deleted both and broken the release pipeline. An opt-in flag whose
# documented use breaks the repo it ships from is not opt-in enough.
KEEP_FILE="$WORKDIR/prune-keep.txt"
awk -F'\t' '$1=="K" {print $2}' "$DESIRED" > "$KEEP_FILE"

# A <…> name is the manifest saying "an axis belongs here and nobody has filled it in" — a SUBSTRING
# test, not an anchored one, so "area: parser <experimental>" counts too, not only the literal
# shipped "area: <your-area>". Shared by the main diff loop below (the `L` case) and the area-labels
# filter just past it (#198) so the two can never independently disagree again: they already did
# once during this change (an anchored pattern in one place, a substring pattern in the other), and
# a label the report `!TODO`'d as never-created still leaked into a copied form's Area dropdown.
is_placeholder_name() {
  case "$1" in
    *"<"*">"*) return 0 ;;
    *) return 1 ;;
  esac
}

# The manifest's own real (non-placeholder) area: labels, in manifest order — built once, here,
# used both to note in the report that a copied form's Area dropdown will be generated, and by
# `apply` to actually generate it (#198). Built straight into the array (no on-disk
# area-labels.txt): the array already IS the single source of truth `[ "${#AREA_ARGS[@]}" -gt 0 ]`
# reads below, so a second on-disk representation would just be one more thing to keep in sync. A
# FILE, not a pipe, is still what's read FROM ($DESIRED) — a `while … done < <(…)` or `… | while`
# would run this body in a subshell, where AREA_ARGS would be built on a copy and vanish.
# A placeholder-only manifest leaves the array empty, and a copied form then keeps the kit's
# shipped placeholder untouched.
AREA_ARGS=()
while IFS="$(printf '\t')" read -r kind f1 f2 f3; do
  [ "$kind" = "L" ] || continue
  case "$f1" in "area: "*) ;; *) continue ;; esac
  is_placeholder_name "$f1" && continue
  AREA_ARGS[${#AREA_ARGS[@]}]="$f1"
done < "$DESIRED"

is_kept() {
  local n="$1" pat
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # $pat is deliberately unquoted: these are globs, so `autorelease: *` covers both of them.
    case "$n" in $pat) return 0 ;; esac
  done < "$KEEP_FILE"
  return 1
}

# The repository's own host (#514). `gh api` never infers a host, so on a GitHub Enterprise checkout
# every `repos/$SLUG…` read and write below reached github.com. The helper is LOADED here, before the
# first gh call, so a kit missing it refuses having called nothing. It RESOLVES once `gh repo view`
# — which does infer the host from origin — has named the repository, and then exports origin's host
# as GH_HOST for every call after it. Decided in ONE place, the helper. KIT_ROOT was resolved before
# the cd, so the helper is the kit's; its origin read is the target repository's. No errexit here,
# so every failure exits explicitly.
GH_HOST_LIB="$KIT_ROOT/skills/_shared/scripts/_gh-host.sh"
# CALLABLE, not merely readable: an empty or truncated helper sources cleanly and defines nothing.
if [ -r "$GH_HOST_LIB" ]; then . "$GH_HOST_LIB" || true; fi
command -v gh_host_resolve >/dev/null 2>&1 \
  || { echo "repo-setup: REFUSED — cannot load $GH_HOST_LIB; reinstall the kit" >&2; exit 2; }

GH_OK=1
command -v gh >/dev/null 2>&1 || GH_OK=0
[ "$GH_OK" = 1 ] && { gh auth status >/dev/null 2>&1 || GH_OK=0; }
command -v jq >/dev/null 2>&1 || { echo "ERR: jq is missing — it is a required prerequisite" >&2; exit 2; }

# Prefer the host `gh repo view --json url` has ALREADY resolved (#530) over the origin-remote
# probe _gh-host.sh falls back to when handed a bare owner/repo: a GHE fork checkout (origin still
# on github.com), a `gh repo set-default` pointed at a different remote, or a renamed repository
# all reach the wrong host under that probe, and `gh repo view` already knows the real one.
SLUG=""; VIEW_HOST=""
if [ "$GH_OK" = 1 ]; then
  SLUG="$(gh repo view --json nameWithOwner 2>/dev/null | jq -r '.nameWithOwner // empty' 2>/dev/null)"
  # Two separate reads, not one TSV split: `.url` can come back empty, and `IFS=$'\t' read` treats
  # a LEADING empty field as whitespace to trim rather than a field boundary — silently
  # misassigning the values after it.
  if [ -n "$SLUG" ]; then
    VIEW_URL="$(gh repo view --json url 2>/dev/null | jq -r '.url // empty' 2>/dev/null)"
    [ -n "$VIEW_URL" ] && VIEW_HOST="$(printf '%s' "$VIEW_URL" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://##; s#/.*$##' | tr '[:upper:]' '[:lower:]')"
  fi
fi
if [ "$GH_OK" = 1 ] && [ -n "$SLUG" ]; then
  # A HOST prefix makes gh_host_resolve take rule 1 outright — no origin match, no credential
  # probe needed — falling back to the pre-#530 origin-probe order only when the url field was
  # unreadable (VIEW_HOST would then be empty too, not just "no host").
  if [ -n "$VIEW_HOST" ]; then
    gh_host_resolve "$VIEW_HOST/$SLUG" || exit 2
  else
    gh_host_resolve "$SLUG" || exit 2
  fi
  SLUG="$KIT_REPO_SLUG"
fi

# The header goes out BEFORE the first probe, because probes can refuse — and a refusal printed
# above "manifest:" reads as though the script failed before it had decided anything.
echo "manifest: $MANIFEST"
[ -n "$SLUG" ] && echo "repo:     $SLUG"
echo ""

LIVE_LABELS="$WORKDIR/live-labels.tsv"
: > "$LIVE_LABELS"
LABELS_READABLE=0
LABEL_LIMIT=200
if [ "$GH_OK" = 0 ]; then
  refuse "labels" "gh is unavailable or unauthenticated — the label axis was not read"
elif list_err="$(gh label list --limit "$LABEL_LIMIT" --json name,color,description 2>&1 >"$WORKDIR/labels.json")"; then
  if jq -r '.[] | "L\t" + .name + "\t" + ((.color // "") | ascii_downcase) + "\t" + (.description // "")' \
       "$WORKDIR/labels.json" > "$LIVE_LABELS" 2>/dev/null; then
    # A full page is indistinguishable from a truncated one, and a truncated read makes every
    # invisible label look absent: `plan` would report +ADD for labels that already exist and
    # `apply` would then fail on each. Refuse rather than diff against a list that may be partial.
    live_count=$(wc -l < "$LIVE_LABELS")
    if [ "$live_count" -ge "$LABEL_LIMIT" ]; then
      refuse "labels" "gh returned the full page of $LABEL_LIMIT labels — the list may be truncated, so the diff cannot be trusted"
    else
      LABELS_READABLE=1
    fi
  else
    refuse "labels" "gh returned a label payload jq could not read"
  fi
else
  # Read-side sibling of #200/#222's write-side fix (#223): a rate-limit or a 5xx used to collapse
  # to the exact same "no access" sentence as an actual 403. The 403 case keeps that sentence
  # verbatim (still the right cause when it really is one); anything else now names what gh
  # actually said instead of guessing "no access".
  refuse "labels" "$(gh_refusal "list" "labels" "$list_err" "gh label list failed — no access to this repository's labels")"
fi

LIVE_SETTINGS="$WORKDIR/live-settings.json"
SETTINGS_READABLE=0
if [ "$GH_OK" = 0 ] || [ -z "$SLUG" ]; then
  [ "$GH_OK" = 1 ] && refuse "settings" "the repository slug is unreadable — settings were not read"
elif settings_read_err="$(gh api "repos/$SLUG" 2>&1 >"$LIVE_SETTINGS")"; then
  SETTINGS_READABLE=1
else
  refuse "settings" "$(gh_refusal "read" "repos/$SLUG" "$settings_read_err" "gh api repos/$SLUG failed — settings were not read")"
fi

# Topics and the Pages site (#400): two more reads, each its own surface with its own refusal, so a
# token that can read settings but not Pages still gets the settings half of the report. Read ONLY
# when the manifest declares the surface: a manifest silent on `topics:` leaves the live topics
# alone — `--prune` included — the way a manifest silent on a setting never PATCHes it.
# `GET repos/{slug}/topics` answers `{"names":[…]}`; `GET repos/{slug}/pages` answers 404 when no
# site exists — a state, not a failure — and 403 without admin, which is a refusal.
LIVE_TOPICS="$WORKDIR/live-topics.txt"
TOPICS_READABLE=0
TOPICS_DECLARED=0
: > "$LIVE_TOPICS"
awk -F'\t' '$1=="O" {found=1} END {exit !found}' "$DESIRED" && TOPICS_DECLARED=1
if [ "$TOPICS_DECLARED" = 1 ] && [ "$GH_OK" = 1 ]; then
  if [ -z "$SLUG" ]; then
    refuse "topics" "the repository slug is unreadable — topics were not read"
  elif topics_err="$(gh api "repos/$SLUG/topics" --jq '.names[]' 2>&1 >"$LIVE_TOPICS")"; then
    TOPICS_READABLE=1
  else
    refuse "topics" "$(gh_refusal "read" "repos/$SLUG/topics" "$topics_err" "gh api repos/$SLUG/topics failed — topics were not read")"
  fi
fi

LIVE_PAGES="$WORKDIR/live-pages.json"
PAGES_READABLE=0          # 1 = the read answered: a site (JSON in $LIVE_PAGES) or none (404)
PAGES_EXISTS=0
PAGES_DECLARED=0
awk -F'\t' '$1=="G" {found=1} END {exit !found}' "$DESIRED" && PAGES_DECLARED=1
if [ "$PAGES_DECLARED" = 1 ] && [ "$GH_OK" = 1 ]; then
  if [ -z "$SLUG" ]; then
    refuse "pages" "the repository slug is unreadable — the Pages site was not read"
  elif pages_err="$(gh api "repos/$SLUG/pages" 2>&1 >"$LIVE_PAGES")"; then
    PAGES_READABLE=1; PAGES_EXISTS=1
  else
    case "$pages_err" in
      *"HTTP 404"*) PAGES_READABLE=1; PAGES_EXISTS=0 ;;
      *) refuse "pages" "$(gh_refusal "read" "repos/$SLUG/pages" "$pages_err" "gh api repos/$SLUG/pages failed — the Pages site was not read")" ;;
    esac
  fi
fi

# ------------------------------------------------------------------------------------- the diff

# Read from a file rather than a pipe: a `while … done < <(…)` or `… | while` runs the body in a
# SUBSHELL, where DRIFT and REFUSED would be incremented on a copy and every count would come back
# zero — a green report over a repo full of drift.
while IFS="$(printf '\t')" read -r kind f1 f2 f3; do
  case "$kind" in
    L)
      name="$f1"; color="$f2"; desc="$f3"
      # Reported on every run so it stays visible — and counted as drift (#198): an unfilled axis
      # is precisely the state that makes the rest of this report's convergence claim a lie, so
      # `plan` exits 1 on it exactly as it would on a real +ADD/~EDIT, until the manifest is filled in.
      if is_placeholder_name "$name"; then
        emit "!TODO" "label" "$name — placeholder, fill it in $MANIFEST"
        continue
      fi
      [ "$LABELS_READABLE" = 1 ] || continue
      live="$(awk -F'\t' -v n="$name" '$1=="L" && $2==n {print $3 "\t" $4; exit}' "$LIVE_LABELS")"
      if [ -z "$live" ]; then
        emit "+ADD" "label" "$name ($color)" "$name" "$color" "$desc"
      else
        live_color="${live%%	*}"
        live_desc="${live#*	}"
        if [ "$live_color" = "$color" ] && [ "$live_desc" = "$desc" ]; then
          emit "=OK" "label" "$name"
        else
          emit "~EDIT" "label" "$name — $live_color/$live_desc -> $color/$desc" "$name" "$color" "$desc"
        fi
      fi
      ;;
    T)
      name="$f1"
      if [ ! -r "$FORMS_DIR/$name" ]; then
        refuse "forms" "$name is declared but the kit ships no templates/issue-forms/$name"
      elif [ -e "$FORMS_TARGET/$name" ]; then
        # Never clobber: a consumer's tuned form outranks the kit's default.
        emit "!SKIP" "form" "$name — already present, left as is"
      elif [ "${#AREA_ARGS[@]}" -gt 0 ]; then
        emit "+ADD" "form" "$name — Area dropdown will be generated from the manifest" "$name"
      else
        emit "+ADD" "form" "$name" "$name"
      fi
      ;;
    S)
      key="$f1"; want="$f2"
      [ "$SETTINGS_READABLE" = 1 ] || continue
      # `!= null` as well as `has`: an unset homepage is JSON null, and `null | tostring` is the
      # string "null" — which would read as a live value in the report instead of <absent>.
      have="$(jq -r --arg k "$key" 'if has($k) and .[$k] != null then (.[$k] | tostring) else "" end' "$LIVE_SETTINGS" 2>/dev/null)"
      if [ "$have" = "$want" ]; then
        emit "=OK" "setting" "$key: $want"
      else
        emit "~EDIT" "setting" "$key: ${have:-<absent>} -> $want" "$key" "$want"
      fi
      ;;
    O)
      name="$f1"
      [ "$TOPICS_READABLE" = 1 ] || continue
      # A set, not a list: GitHub lower-cases and may reorder what it stores, and neither is drift.
      if grep -qxF -- "$name" "$LIVE_TOPICS"; then
        emit "=OK" "topic" "$name"
      else
        emit "+ADD" "topic" "$name" "$name"
      fi
      ;;
    G)
      key="$f1"; want="$f2"
      [ "$PAGES_READABLE" = 1 ] || continue
      if [ "$PAGES_EXISTS" = 0 ]; then
        emit "+ADD" "pages" "$key: $want (no site yet)" "$key" "$want"
      else
        case "$key" in
          source.branch) have="$(jq -r '.source.branch // ""' "$LIVE_PAGES" 2>/dev/null)" ;;
          source.path)   have="$(jq -r '.source.path // ""' "$LIVE_PAGES" 2>/dev/null)" ;;
          build_type)    have="$(jq -r '.build_type // ""' "$LIVE_PAGES" 2>/dev/null)" ;;
          *)             have="" ;;
        esac
        if [ "$have" = "$want" ]; then
          emit "=OK" "pages" "$key: $want"
        else
          emit "~EDIT" "pages" "$key: ${have:-<absent>} -> $want" "$key" "$want"
        fi
      fi
      ;;
  esac
done < "$DESIRED"

# A live label the manifest does not declare is REPORTED and kept. Deleting by default would let a
# kit upgrade quietly rename somebody's taxonomy out from under them.
if [ "$LABELS_READABLE" = 1 ]; then
  while IFS="$(printf '\t')" read -r kind name _rest; do
    [ "$kind" = "L" ] || continue
    [ -n "$name" ] || continue
    if ! awk -F'\t' -v n="$name" '$1=="L" && $2==n {found=1} END {exit !found}' "$DESIRED"; then
      if [ "$PRUNE" = 1 ] && is_kept "$name"; then
        emit "!KEEP" "label" "$name — undeclared but protected by pruneKeep, not deleted"
      elif [ "$PRUNE" = 1 ]; then
        emit "-DEL" "label" "$name — undeclared, queued for deletion (--prune)" "$name" "" ""
      else
        emit "!EXTRA" "label" "$name — live but not declared (kept; --prune would delete it)"
      fi
    fi
  done < "$LIVE_LABELS"
fi

# A live topic the manifest does not declare is reported and kept, like a label; `--prune` drops it
# by writing the declared set alone. No pruneKeep for topics — nothing but the repo owns a topic.
if [ "$TOPICS_READABLE" = 1 ]; then
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! awk -F'\t' -v n="$name" '$1=="O" && $2==n {found=1} END {exit !found}' "$DESIRED"; then
      if [ "$PRUNE" = 1 ]; then
        emit "-DEL" "topic" "$name — undeclared, queued for deletion (--prune)" "$name"
      else
        emit "!EXTRA" "topic" "$name — live but not declared (kept; --prune would delete it)"
      fi
    fi
  done < "$LIVE_TOPICS"
fi

echo ""

# --------------------------------------------------------------------------------------- verdict

if [ "$VERB" = "plan" ]; then
  if [ "$REFUSED" -gt 0 ]; then
    echo "plan: $DRIFT item(s) of drift, $REFUSED surface(s) unreadable — the report names them."
    exit 3
  fi
  if [ "$DRIFT" -gt 0 ]; then
    # "Run apply to converge" is only true advice for the +ADD/~EDIT/-DEL part of $DRIFT — `apply`
    # never creates a `!TODO` placeholder (#198), so a repo whose only remaining drift is an
    # unfilled axis would hit this message, run apply, apply nothing, and see the identical
    # message on the next plan: telling it to do the one thing that never resolves it.
    if [ "$TODO_COUNT" -eq 0 ]; then
      echo "plan: $DRIFT item(s) of drift. Run \`repo-setup.sh apply\` to converge."
    elif [ "$TODO_COUNT" -eq "$DRIFT" ]; then
      echo "plan: $DRIFT item(s) of drift, all unfilled placeholder(s) — \`apply\` never creates one; edit $MANIFEST instead."
    else
      echo "plan: $DRIFT item(s) of drift ($TODO_COUNT unfilled placeholder(s)). Run \`repo-setup.sh apply\` for the rest; edit $MANIFEST for the placeholder(s)."
    fi
    exit 1
  fi
  echo "plan: converged — nothing to do."
  exit 0
fi

# ----------------------------------------------------------------------------------- apply

# One pass over the delta the diff already computed, rather than a second derivation. Two
# derivations of the same decision drift, and a drifted copy of a gate is this repo's recurring
# failure (#141, #163) — here it would mean applying something the operator was never shown.
#
# Nothing below uses `&&` chaining across surfaces: one refusal must not skip the rest. That is
# what exit 3 is for, and it is the difference between "the settings needed admin and the labels
# are in place" and "nothing happened, and you get to guess why".
APPLIED=0
# Settings are batched into ONE PATCH rather than one call per key: GitHub applies them as a single
# object, and a per-key loop would leave a half-configured repo behind whenever the token ran out
# of scope midway. Declared before the loop so it survives it — the loop reads from a file, not a
# pipe, precisely so this stays in the parent shell.
SET_ARGS=()
SET_COUNT=0
# Topics and Pages changes are counted in the loop and written after it, one call per surface,
# for the same reason settings batch: the topics endpoint replaces the whole set (#400).
TOPICS_TOUCHED=0
PAGES_TOUCHED=0

while IFS="$(printf '\t')" read -r action kind f1 f2 f3; do
  case "$action" in
    "+ADD"|"~EDIT"|"-DEL") ;;
    *) continue ;;
  esac
  case "$kind" in
    label)
      [ -n "$f1" ] || continue
      if [ "$action" = "-DEL" ]; then
        if del_err="$(gh label delete "$f1" --yes 2>&1 >/dev/null)"; then
          APPLIED=$((APPLIED + 1))
        else
          refuse "labels" "$(gh_refusal "delete" "$f1" "$del_err")"
        fi
      else
        # +ADD and ~EDIT differ only in which `gh label` subcommand applies — and that word is
        # also exactly the verb gh_refusal() wants, so one variable carries both.
        verb=create
        [ "$action" = "+ADD" ] || verb=edit
        if label_err="$(gh label "$verb" "$f1" --color "$f2" --description "$f3" 2>&1 >/dev/null)"; then
          APPLIED=$((APPLIED + 1))
        else
          refuse "labels" "$(gh_refusal "$verb" "$f1" "$label_err")"
        fi
      fi
      ;;
    form)
      [ -n "$f1" ] || continue
      # Only ever reached for +ADD: an existing form was already classified !SKIP by the diff, and
      # !SKIP is not in the action filter above. The never-clobber rule lives in one place.
      #
      # Not a `gh` call, so there is no HTTP status to classify — just capture whatever the OS
      # actually said (permission denied, disk full, a read-only target) instead of the bare path
      # the old message gave with no cause at all (#222's smaller, OS-level companion to
      # gh_refusal()). Grouped so one `2>&1 >/dev/null` captures either command's stderr.
      if form_err="$( { mkdir -p "$FORMS_TARGET" && cp "$FORMS_DIR/$f1" "$FORMS_TARGET/$f1"; } 2>&1 >/dev/null )"; then
        APPLIED=$((APPLIED + 1))
        # Project the manifest's own areas into the just-copied form, so its dropdown and this
        # repo's labels agree by construction. A placeholder-only manifest leaves the shipped
        # placeholder untouched — $AREA_ARGS is empty and nothing here runs. Built once, above —
        # not rebuilt per form.
        if [ "${#AREA_ARGS[@]}" -gt 0 ]; then
          proj_rc=0
          # ${arr[@]+"${arr[@]}"}, not a bare "${arr[@]}" — the idiom this file uses everywhere
          # under `set -u` on bash 3.2 (see the settings PATCH below). The `-gt 0` guard above
          # already makes this expansion safe today, same as SET_COUNT does for SET_ARGS, but the
          # file's own rule is to use the guarded form regardless, so a later refactor that loosens
          # the guard can't reopen the "unbound variable" abort this idiom exists to prevent.
          proj_err=$(python3 "$PROJECTOR" "$FORMS_TARGET/$f1" ${AREA_ARGS[@]+"${AREA_ARGS[@]}"} 2>&1 >/dev/null) || proj_rc=$?
          # Flattened exactly like gh_refusal()'s $flat above: a PyYAML error is routinely
          # multi-line, and every report row is a single line by contract — an embedded newline
          # would split a status row in two and could spuriously satisfy an unrelated `has_line`
          # check reading the report.
          proj_err="$(printf '%s' "$proj_err" | tr '\n' ' ' | sed 's/  */ /g; s/[[:space:]]*$//')"
          case "$proj_rc" in
            0) : ;; # already reported +ADD by the diff pass above; nothing more to say
            # A projection that was promised (the diff pass's "+ADD … Area dropdown will be
            # generated") and then didn't happen is drift, not a footnote (#240): route it through
            # refuse() like every other partial `apply` result, so it counts toward REFUSED and
            # apply's exit code — never a silent !NOTE at exit 0 that a future `plan`/`apply` has
            # no way to see again once the form exists on disk (#198's #240 follow-up finding 4).
            3) refuse "forms" "$f1 — copied, but its Area dropdown could not be generated ($proj_err)" ;;
            *) refuse "forms" "could not project $f1's Area dropdown: $proj_err" ;;
          esac
        fi
      else
        form_err_flat="$(flatten_err "$form_err")"
        if [ -n "$form_err_flat" ]; then
          refuse "forms" "could not write $FORMS_TARGET/$f1 — $form_err_flat"
        else
          refuse "forms" "could not write $FORMS_TARGET/$f1"
        fi
      fi
      ;;
    setting)
      [ -n "$f1" ] || continue
      # `-F` types its value (true/false/numbers become JSON), which the boolean settings need;
      # `-f` sends a raw string, which the two documented string settings need — a description
      # that happens to be "42" or to start with "@" must reach GitHub as text (#400).
      case "$f1" in
        description|homepage) SET_ARGS[${#SET_ARGS[@]}]="-f" ;;
        *)                    SET_ARGS[${#SET_ARGS[@]}]="-F" ;;
      esac
      SET_ARGS[${#SET_ARGS[@]}]="$f1=$f2"
      SET_COUNT=$((SET_COUNT + 1))
      ;;
    topic)
      TOPICS_TOUCHED=$((TOPICS_TOUCHED + 1))
      ;;
    pages)
      PAGES_TOUCHED=$((PAGES_TOUCHED + 1))
      ;;
  esac
done < "$DELTA"

if [ "$SET_COUNT" -gt 0 ]; then
  if [ "$GH_OK" = 0 ] || [ -z "$SLUG" ]; then
    refuse "settings" "$SET_COUNT setting(s) need gh and a repository slug — not applied"
  # `${arr[@]+"${arr[@]}"}` and not a bare "${arr[@]}": under `set -u`, bash 3.2 treats an empty
  # array expansion as an unbound variable and aborts. SET_COUNT > 0 means it is not empty here,
  # but the idiom is the one this file has to use everywhere, so it is used consistently.
  elif patch_err="$(gh api -X PATCH "repos/$SLUG" ${SET_ARGS[@]+"${SET_ARGS[@]}"} 2>&1 >/dev/null)"; then
    APPLIED=$((APPLIED + SET_COUNT))
  else
    refuse "settings" "$(gh_refusal "update" "repos/$SLUG" "$patch_err" "gh api -X PATCH repos/$SLUG was refused — the token needs admin rights on it")"
  fi
fi

# Topics: ONE PUT carrying the whole set — the union of live and declared, or the declared set alone
# under --prune — because the endpoint REPLACES, never adds; a per-topic loop would drop every topic
# the manifest does not name on the first call. Only when the diff queued a change (#400).
if [ "$TOPICS_TOUCHED" -gt 0 ]; then
  if [ "$GH_OK" = 0 ] || [ -z "$SLUG" ]; then
    refuse "topics" "$TOPICS_TOUCHED topic change(s) need gh and a repository slug — not applied"
  else
    TOPICS_SET="$WORKDIR/topics-set.txt"
    if [ "$PRUNE" = 1 ]; then
      awk -F'\t' '$1=="O" {print $2}' "$DESIRED" > "$TOPICS_SET"
    else
      { awk -F'\t' '$1=="O" {print $2}' "$DESIRED"; cat "$LIVE_TOPICS"; } | awk 'NF && !seen[$0]++' > "$TOPICS_SET"
    fi
    TOPIC_ARGS=()
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      TOPIC_ARGS[${#TOPIC_ARGS[@]}]="-f"
      TOPIC_ARGS[${#TOPIC_ARGS[@]}]="names[]=$name"
    done < "$TOPICS_SET"
    if topics_put_err="$(gh api -X PUT "repos/$SLUG/topics" ${TOPIC_ARGS[@]+"${TOPIC_ARGS[@]}"} 2>&1 >/dev/null)"; then
      APPLIED=$((APPLIED + TOPICS_TOUCHED))
    else
      refuse "topics" "$(gh_refusal "update" "repos/$SLUG/topics" "$topics_put_err" "gh api -X PUT repos/$SLUG/topics was refused — the token needs admin rights on it")"
    fi
  fi
fi

# The Pages site: one POST to create, one PUT to update — the same call shape, the verb decided by
# the read. Never a DELETE: disabling a site is not a converge (#400).
if [ "$PAGES_TOUCHED" -gt 0 ]; then
  if [ "$GH_OK" = 0 ] || [ -z "$SLUG" ]; then
    refuse "pages" "$PAGES_TOUCHED Pages change(s) need gh and a repository slug — not applied"
  else
    PAGES_ARGS=()
    while IFS="$(printf '\t')" read -r kind key val; do
      [ "$kind" = "G" ] || continue
      case "$key" in
        source.branch) PAGES_ARGS[${#PAGES_ARGS[@]}]="-f"; PAGES_ARGS[${#PAGES_ARGS[@]}]="source[branch]=$val" ;;
        source.path)   PAGES_ARGS[${#PAGES_ARGS[@]}]="-f"; PAGES_ARGS[${#PAGES_ARGS[@]}]="source[path]=$val" ;;
        build_type)    PAGES_ARGS[${#PAGES_ARGS[@]}]="-f"; PAGES_ARGS[${#PAGES_ARGS[@]}]="build_type=$val" ;;
      esac
    done < "$DESIRED"
    pages_verb="POST"
    [ "$PAGES_EXISTS" = 1 ] && pages_verb="PUT"
    if pages_write_err="$(gh api -X "$pages_verb" "repos/$SLUG/pages" ${PAGES_ARGS[@]+"${PAGES_ARGS[@]}"} 2>&1 >/dev/null)"; then
      APPLIED=$((APPLIED + PAGES_TOUCHED))
    else
      refuse "pages" "$(gh_refusal "update" "repos/$SLUG/pages" "$pages_write_err" "gh api -X $pages_verb repos/$SLUG/pages was refused — the token needs admin rights on it, and Pages must be available on this repository's plan")"
    fi
  fi
fi

echo ""
if [ "$REFUSED" -gt 0 ]; then
  echo "apply: $APPLIED change(s) applied, $REFUSED surface(s) refused — the report names them."
  exit 3
fi
echo "apply: $APPLIED change(s) applied."
exit 0
