#!/usr/bin/env bash
# plan-freshness.sh — a plan promises to MODIFY paths; prove they still exist before building.
#
# Why this exists (#322). `create-issue` writes an implementation plan the day the issue is filed;
# `implement-issue` executes it whenever the issue reaches the front of the queue — weeks later,
# across dozens of merges. #233 and #245 both trace to a `**Files:**` line naming a path `main` no
# longer had. The failure is absence-shaped, the shape this repo keeps closing: nothing reports a
# problem. A per-task subagent opens the named file, does not find it, improvises the nearest
# thing, its filtered test goes green, the box gets ticked, and Step 10 never mentions that the
# plan it just executed described a different tree.
#
# So the question gets asked ONCE, up front, mechanically, before the draft PR exists. Every path
# a plan says it will `modify`, `test`, `delete` or `rename` is resolved against a base ref; a path
# that does not resolve is named, and the exit status says so.
#
# Ported alongside the two-axis review in ../references/spec-review.md from mattpocock/skills
# (MIT) — `engineering/code-review` and `in-progress/implement-spec`.
#
# WHAT IT DELIBERATELY DOES NOT DO. It does not edit the plan, contact GitHub, or decide anything.
# Re-anchoring a stale path through the task's `**Interfaces:**` line is SKILL.md Step 2's job and
# a judgement call; this script only reports. `tick-plan.sh` owns the plan's round-trip contract
# (#199, #215) and is not touched here — freshness is a read of a ref, a separate concern.
#
# Usage:
#   plan-freshness.sh [-C <dir>] [--base <ref>] <plan.md>
#
#   -C <dir>       run git in this directory (default: the current one)
#   --base <ref>   the ref every path is resolved against (default: origin/main)
#   <plan.md>      the plan file the locate recipe already produced (/tmp/plan-<issue>.md)
#
# Output — one line per path named on a `**Files:**` line under a `### Task N` heading:
#
#   OK      modify <path> (Task N)     it resolves against <ref>
#   MISSING modify <path> (Task N)     it does not — the plan is stale here
#   SKIP    create <path> (Task N)     a path the plan is about to CREATE; absence is correct
#   SKIP    test   <path> (Task N)     ditto, marked `(new)`/`(new file)` on a verb other than
#                                      `create` (#433) — same reading, original verb word kept
#   SKIP    rename <path> (Task N)     the NEW name of a `rename` pair (#441) — same reading as
#                                      `create`, the OLD name is checked like `modify` instead
#   SKIP    <verb> <path> (Task N)     an EARLIER task of the plan creates it — absent from <ref>
#                                      by design (#640)
#
# `(Task N)` is on ALL lines, not only on MISSING: the task number is what Step 2 needs to find the
# `**Interfaces:**` line to re-anchor through, and a reader diffing two runs wants the OK lines
# attributable too. It is the wider of the two shapes #322 described and satisfies both.
#
# THE GRAMMAR (decided at triage, #441 — also documented in
# [plan-shape.md](../../_shared/plan-shape.md)'s own `**Files:**` section):
# a path is a BACKTICK-QUOTED span; nothing else on the `**Files:**` line is a path. Four false-
# STALE parses in one day (#403, #419, #433) plus a fourth found the same day, and four more found
# afterwards (#512, #514, #537, #552) all trace to the previous parser answering "where does a path
# end?" by splitting on `, `/`; ` and stripping parens — a question a backtick-quoted span never has
# to ask. So the field is read span-by-span instead of item-by-item:
#
#   - Verbs are `create|modify|test|delete|rename`, a whole word (case-insensitive), carrying
#     forward to every span after it until the next verb word — same as before, but the carry now
#     reads prose between spans rather than a comma-split item.
#   - A backtick-quoted span is a PATH only if it contains `/` or `.` — `guard_hint()`, `t7`,
#     `<kit>`, `CLAUDE_PLUGIN_ROOT` name no file and are silently ignored, not reported and not
#     counted; a span shaped like a real path (has a slash or a dot) is the only kind ever checked.
#     Known, accepted ceiling: an extension-less root file named in backticks with no directory
#     (`Makefile`, `LICENSE`) has neither and is misread as a symbol, same as an unevidenced dotted
#     symbol name would be misread as a path — neither has been observed in a real plan.
#   - A trailing `:NN`, `:NN-MM` or `:NN–MM` (en dash) on a path is a line anchor, stripped before
#     resolving and before it is printed — the kit's own `plan-shape.md` template writes this shape.
#   - `rename` takes the NEXT TWO path-shaped spans as a pair: the first is the existing name,
#     checked like `modify`; the second is the new name, `SKIP`ped like `create` — whatever sits
#     between them (an arrow, in every observed plan).
#   - Everything else on the line — asides in parens, "and", em-dashes, a prose sentence, a bulleted
#     `- Modify: …` line (no longer a legal shape — `plan-shape.md` says so — but still read
#     correctly if an already-filed plan carries one) — is just prose around the paths, never split
#     into items of its own.
#
# The `(new)`/`(new file)` marker (#433) still works the same way: `create-issue`'s own template
# phrases a task's own new test file as `test \`path\` (new)`, not `create \`path\`` — the item is
# "the test for this task", not "a file this task modifies" — and a bare `test`/`modify`/`delete`
# verb otherwise means "resolve this against <ref>", wrong for a path the plan says does not exist
# yet. The marker is read from the prose IMMEDIATELY after a span, and only an EXACT, closed match —
# `(new)` or `(new file)`, nothing else inside — counts; `(new in v2)` is a different aside that
# happens to contain the word "new", and any nested backtick code inside the parenthetical (an aside
# describing where in the file the change goes, e.g. `` `a.sh` (new `guard_hint()` beside `deny()`) ``)
# breaks the match the same way, on purpose — it is prose about the path, not the marker.
#
# The no-file idiom (#403) still applies: `create-issue` has been OBSERVED writing `**Files:** none
# expected.` for a verification-only task (#396's Task 4, #397's Task 4). A field with NO
# backtick-quoted span at all is read this way: if what remains after stripping one leading verb
# word and one trailing aside is exactly `none expected`/`none expected.`, nothing is reported; any
# other text — including a genuine typo like `none-such.md` with no backticks — is still named
# MISSING. This is the regression guard #403 added (a field naming a bare, non-backticked path must
# never silently pass) re-expressed for a grammar where paths are backtick-quoted: a governing verb
# with no backtick-quoted path at all is exactly as suspicious as before.
#
# Exit codes:
#   0  every checked path resolves — the plan still matches the tree
#   5  at least one does not; the MISSING lines name them. The guards' convention: a distinct code
#      for the expected non-success, so a caller can tell "stale" from "could not tell"
#   2  usage / plumbing error — no plan file, an unreadable one, no `### Task` in it, not a git
#      directory, or a base ref that does not resolve. NO VERDICT was reached, which is not a pass
set -euo pipefail

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

die2() { echo "plan-freshness: $1" >&2; exit 2; }

# Trimming and splitting are done with `case` globs and `${…#…}`/`${…%…}` rather than sed: the
# repo runs its scripts under macOS's bash 3.2 AND BSD sed, where `s/…/\n/` in a replacement is not
# a newline, so the portable spelling of "split on two-character separators" is this one.
#
# `\r` is trimmed alongside the spaces, and it is not hypothetical: the plan reaches this script
# through `gh api … --jq .body`, and an issue body authored in GitHub's own web editor is CRLF. A
# surviving carriage return rides on the LAST item of every `**Files:**` line, defeats the trailing
# punctuation strip below, and reports that path MISSING with a diagnostic that looks identical to
# the path it is complaining about — the worst possible spelling of a false stale.
trim() {
  local s="${1-}"
  while :; do case "$s" in ' '*|$'\t'*|$'\r'*) s=${s#?} ;; *) break ;; esac; done
  while :; do case "$s" in *' '|*$'\t'|*$'\r') s=${s%?} ;; *) break ;; esac; done
  printf '%s' "$s"
}

# A whole word — case-insensitive, closed list — updates $CURRENT_VERB and carries forward to every
# span after it until the next verb word (same carry-forward rule the old comma-split reader had,
# read here from the prose between backtick-quoted spans instead of from a split item).
scan_verb() {
  local s="$1" w wl
  while [ -n "$s" ]; do
    case "$s" in
      *' '*) w=${s%% *}; s=${s#* } ;;
      *) w="$s"; s="" ;;
    esac
    case "$w" in *[:,.\;]) w=${w%?} ;; esac
    wl=$(printf '%s' "$w" | tr '[:upper:]' '[:lower:]')
    case "$wl" in
      create|modify|test|delete|rename) CURRENT_VERB="$wl" ;;
    esac
  done
}

# Strip a single leading verb WORD from $1, if present — the no-backtick-span fallback's own tiny
# version of scan_verb's carry-forward, needed there only to build the printed MISSING text.
strip_leading_verb() {
  local s="$1" w rest wl
  case "$s" in
    *' '*) w=${s%% *}; rest=${s#* } ;;
    *) w="$s"; rest="" ;;
  esac
  case "$w" in *[:,.\;]) w=${w%?} ;; esac
  wl=$(printf '%s' "$w" | tr '[:upper:]' '[:lower:]')
  case "$wl" in
    create|modify|test|delete|rename) printf '%s' "$rest" ;;
    *) printf '%s' "$s" ;;
  esac
}

# A backtick-quoted span is a path only if it looks like one: a slash or a dot somewhere in it. A
# symbol/region name (`t7`, `guard_hint()`, `<kit>`, `CLAUDE_PLUGIN_ROOT`) has neither and is not a
# path — see the grammar note above the shebang header for the accepted ceiling this leaves.
looks_like_path() {
  case "$1" in
    */*|*.*) return 0 ;;
    *) return 1 ;;
  esac
}

is_digits() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# A trailing `:NN`, `:NN-MM` or `:NN–MM` (en dash) is a line anchor — plan-shape.md's own task-block
# example writes `exact/path/to/existing.py:123-145` — stripped before the path resolves or prints.
strip_anchor() {
  local s="$1" body anchor pre post
  case "$s" in
    *:*)
      body="${s%:*}"
      anchor="${s##*:}"
      if is_digits "$anchor"; then printf '%s' "$body"; return; fi
      case "$anchor" in
        *-*)
          pre="${anchor%%-*}"; post="${anchor#*-}"
          if is_digits "$pre" && is_digits "$post"; then printf '%s' "$body"; return; fi
          ;;
        *'–'*)
          pre="${anchor%%'–'*}"; post="${anchor#*'–'}"
          if is_digits "$pre" && is_digits "$post"; then printf '%s' "$body"; return; fi
          ;;
      esac
      printf '%s' "$s"
      ;;
    *) printf '%s' "$s" ;;
  esac
}

# $1 = the prose immediately following a span, already trimmed. Exact, closed match only — `(new)`
# or `(new file)`, nothing else inside (#433) — so a genuine aside that merely starts with the word
# "new" (`(new in v2)`, or one carrying nested backtick code) never matches.
is_new_marker() {
  local lc
  lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lc" in
    '(new)'|'(new file)') return 0 ;;
    '(new)'[!a-z0-9]*|'(new file)'[!a-z0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# skip_and_remember <verb> <span> — print the SKIP line for a span already known to be legitimately
# absent (about to be created, or created earlier in this same plan), and record it in $CREATED so a
# LATER task's reference to the same path reads SKIP too, not MISSING (#640). The one place all three
# SKIP-producing sites in handle_span go through, so a fourth one can't add the printf and forget the
# bookkeeping (found in review of #640).
skip_and_remember() {
  local verb path
  verb="$1"; path=$(strip_anchor "$2")
  printf 'SKIP %s %s (Task %s)\n' "$verb" "$path" "$TASK"
  CREATED="$CREATED$path$NL"
}

# forget_created <path> — remove EVERY entry equal to <path> from $CREATED. A plan may legitimately
# name the same new path from two different SKIP-producing sites (`create` in one task, a `(new)`-
# marked mention in another — both legal per plan-shape.md), so $CREATED can hold a path more than
# once; a single `${CREATED//"$NL$path$NL"/$NL}` substitution only erases ONE of two duplicates; the
# two copies share their middle newline, so removing the first pass's match leaves the second copy's
# leading newline behind and it survives (found in review of #640, reproduced against the shipped
# script). So this rebuilds $CREATED by filtering entries instead, which drops every copy in one
# pass regardless of how many there are.
forget_created() {
  local target="$1" rest entry
  target=$(strip_anchor "$target")
  rest="${CREATED#"$NL"}"
  CREATED="$NL"
  while [ -n "$rest" ]; do
    entry="${rest%%"$NL"*}"
    rest="${rest#*"$NL"}"
    [ "$entry" = "$target" ] || CREATED="$CREATED$entry$NL"
  done
}

# check_span <verb> <span> — resolve against $BASE (after stripping a line anchor), print OK/MISSING.
# A path an EARLIER task of this same plan already SKIPped (i.e. is about to be created) is read
# as SKIP here too, never MISSING — $CREATED is the run-wide record skip_and_remember fills in
# (#640). $CREATED is NOT append-only, though: a `rename` or `delete` CONSUMES the name (the path
# stops denoting anything, under that name, from here on), so once it is matched here for one of
# those two verbs every trace of it is forgotten again — otherwise a plan that creates `x`, renames
# it away, then wrongly references `x` a third time would read SKIP forever instead of catching the
# stale reference (found in review of #640: a genuinely stale plan silently waved through).
check_span() {
  local verb path type
  verb="$1"; path=$(strip_anchor "$2")
  # #647: the object name travels on stdin, not argv. Git Bash's MSYS layer rewrites an argv entry
  # holding ':.' (e.g. "origin/main:.github/workflows/ci.yml") before git.exe ever sees it, turning
  # a present dot-prefixed path into a false MISSING — stdin is never touched by that conversion.
  type=$(printf '%s:%s\n' "$BASE" "$path" \
    | git -C "$DIR" cat-file --batch-check='%(objecttype)' 2>/dev/null) || type=
  case "$type" in
    blob|tree|commit|tag)
      printf 'OK %s %s (Task %s)\n' "$verb" "$path" "$TASK"
      ;;
    *)
      case "$CREATED" in
        *"$NL$path$NL"*)
          printf 'SKIP %s %s (Task %s)\n' "$verb" "$path" "$TASK"
          case "$verb" in
            rename|delete) forget_created "$path" ;;
          esac
          return 0
          ;;
      esac
      printf 'MISSING %s %s (Task %s)\n' "$verb" "$path" "$TASK"
      MISSING=$((MISSING + 1))
      ;;
  esac
}

# handle_span <span> <following-prose> — dispatch one backtick-quoted span by $CURRENT_VERB.
# $PEND_SRC (global, reset per field) holds a `rename` verb's first span until its pair's second
# span arrives — see the grammar note above.
handle_span() {
  local span following

  # Filtered exactly as the source branch below is: without it ANY span was consumed as the target,
  # so a backticked aside between the two names was eaten and the real target flushed as MISSING
  # (#599 — shipped by #594, which added this filter to the source branch only). The end-of-field
  # flush stays unconditional: a rename whose target never arrives must still resolve its source.
  span="$1"; following="$2"
  if [ -n "$PEND_SRC" ] && looks_like_path "$span"; then
    check_span rename "$PEND_SRC"
    skip_and_remember rename "$span"
    PEND_SRC=""
    return
  fi

  if [ "$CURRENT_VERB" = rename ] && looks_like_path "$span"; then
    PEND_SRC="$span"
    return
  fi

  looks_like_path "$span" || return 0

  case "$CURRENT_VERB" in
    create)
      skip_and_remember create "$span"
      ;;
    *)
      if is_new_marker "$following"; then
        skip_and_remember "$CURRENT_VERB" "$span"
      else
        check_span "$CURRENT_VERB" "$span"
      fi
      ;;
  esac
}

DIR="."
BASE="origin/main"
PLAN=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -C) [ $# -ge 2 ] || die2 "-C needs a directory"; DIR="$2"; shift 2 ;;
    -C*) DIR="${1#-C}"; shift ;;
    --base) [ $# -ge 2 ] || die2 "--base needs a ref"; BASE="$2"; shift 2 ;;
    --base=*) BASE="${1#--base=}"; shift ;;
    --) shift ;;
    -*) die2 "unknown option '$1'" ;;
    *)
      [ -z "$PLAN" ] || die2 "more than one plan file given ('$PLAN' and '$1')"
      PLAN="$1"; shift ;;
  esac
done

[ -n "$PLAN" ] || die2 "no plan file given — usage: plan-freshness.sh [-C <dir>] [--base <ref>] <plan.md>"
[ -r "$PLAN" ] || die2 "cannot read '$PLAN'"
# Load-bearing, exactly as in the locate recipe this runs after: a failed or rate-limited fetch
# leaves an EMPTY plan file, and an empty file has no `### Task` and no `**Files:**` line — it
# would sail through as "nothing to check, exit 0" and report a stale plan fresh.
[ -s "$PLAN" ] || die2 "'$PLAN' is empty — the plan fetch failed; do not read that as 'nothing stale'"

git -C "$DIR" rev-parse --git-dir > /dev/null 2>&1 || die2 "'$DIR' is not a git repository"
git -C "$DIR" rev-parse --verify --quiet "$BASE^{commit}" > /dev/null 2>&1 \
  || die2 "base ref '$BASE' does not resolve in '$DIR' — fetch it rather than reading this as fresh"

TASK=""
SEEN_TASK=0
MISSING=0
NL=$'\n'
CREATED="$NL"
IN_FIELD=0
PAYLOAD=""
CURRENT_VERB="modify"
PEND_SRC=""
SPANS_FOUND=0

# A **Files:** field is prose meant to be soft-wrapped (`create-issue`'s own template writes it that
# way, and issue #412's own plan wrapped mid-parenthetical). Reading one physical line at a time made
# the verdict depend on where the source happened to wrap — so the field is ACCUMULATED across
# physical lines first, terminated by a blank line, a new `### Task`, a new `**Files:**`/
# `**Files**:` line, or end of file, and only then handed to the grammar below (#419).
flush_files_field() {
  local payload orig prose span rest following item
  payload=$(trim "$1")
  # A `**Files:**` line above the first `### Task` belongs to no task, so there is nothing to
  # report it against and nothing for Step 2 to re-anchor through. Skipping it is deliberate.
  [ "$SEEN_TASK" -eq 1 ] || return 0
  [ -n "$payload" ] || return 0

  orig="$payload"
  CURRENT_VERB="modify"
  PEND_SRC=""
  SPANS_FOUND=0

  while :; do
    case "$payload" in
      *'`'*)
        prose="${payload%%\`*}"
        rest="${payload#*\`}"
        case "$rest" in
          *'`'*)
            span="${rest%%\`*}"
            payload="${rest#*\`}"
            ;;
          *)
            # An unbalanced backtick — no closing tick anywhere in the rest of the field. Read
            # everything left as trailing prose (it can carry a late verb word) and stop; there is
            # no well-formed span left to extract.
            scan_verb "$prose$rest"
            payload=""
            break
            ;;
        esac
        scan_verb "$prose"
        SPANS_FOUND=$((SPANS_FOUND + 1))
        case "$payload" in
          *'`'*) following=$(trim "${payload%%\`*}") ;;
          *) following=$(trim "$payload") ;;
        esac
        handle_span "$span" "$following"
        ;;
      *)
        scan_verb "$payload"
        payload=""
        break
        ;;
    esac
  done

  # A `rename` whose plan named only one span (malformed) — check it rather than drop it silently.
  if [ -n "$PEND_SRC" ]; then
    check_span rename "$PEND_SRC"
    PEND_SRC=""
  fi

  if [ "$SPANS_FOUND" -eq 0 ]; then
    # No backtick-quoted span anywhere in the field — #403's regression guard, re-expressed: a
    # governing verb with nothing backtick-quoted to check is exactly as suspicious as a bare,
    # un-backticked path used to be. Strip one trailing aside, one leading verb word, then compare
    # to the closed no-file idiom; anything else is named MISSING using the raw remaining text.
    item="$orig"
    while :; do case "$item" in *.|*,|*';') item=${item%?} ;; *) break ;; esac; done
    case "$item" in *'('*')') item="${item%(*}" ;; esac
    item=$(trim "$item")
    item=$(trim "$(strip_leading_verb "$item")")
    while :; do case "$item" in *.|*,|*';') item=${item%?} ;; *) break ;; esac; done
    case "$(printf '%s' "$item" | tr '[:upper:]' '[:lower:]')" in
      ''|'none expected') : ;;
      *)
        printf 'MISSING %s %s (Task %s)\n' "$CURRENT_VERB" "$item" "$TASK"
        MISSING=$((MISSING + 1))
        ;;
    esac
  fi
}

while IFS= read -r line || [ -n "$line" ]; do
  line=$(trim "$line")
  case "$line" in
    '### Task '*)
      if [ "$IN_FIELD" -eq 1 ]; then flush_files_field "$PAYLOAD"; IN_FIELD=0; PAYLOAD=""; fi
      rest=${line#'### Task '}
      num=${rest%%[!0-9]*}
      [ -n "$num" ] && TASK="$num" || TASK="?"
      SEEN_TASK=1
      continue
      ;;
    # Both spellings of the bold marker. A `**Files**:` line matching nothing would report its whole
    # task fresh without resolving a single path — a silent un-gating, which is the failure shape
    # this script exists to remove rather than reproduce one line further in. Starting a new field
    # flushes whatever field was already accumulating (a malformed plan with two `**Files:**` lines
    # under one task reads as two separate fields, never a merge of both).
    '**Files:**'*)
      if [ "$IN_FIELD" -eq 1 ]; then flush_files_field "$PAYLOAD"; fi
      PAYLOAD=$(trim "${line#'**Files:**'}")
      IN_FIELD=1
      continue
      ;;
    '**Files**:'*)
      if [ "$IN_FIELD" -eq 1 ]; then flush_files_field "$PAYLOAD"; fi
      PAYLOAD=$(trim "${line#'**Files**:'}")
      IN_FIELD=1
      continue
      ;;
    '')
      if [ "$IN_FIELD" -eq 1 ]; then flush_files_field "$PAYLOAD"; IN_FIELD=0; PAYLOAD=""; fi
      continue
      ;;
    # Any OTHER bold-labelled field under the same task — `**Interfaces:**` is the one every plan
    # carries (plan-shape.md's template), always separated from `**Files:**` by a blank line in
    # every fixture and every real issue plan this repo has — but nothing upstream enforces that
    # blank line, and swallowing it as a continuation would corrupt the Files field with prose that
    # was never part of it (code review, #419). Flush and ignore it, exactly as a plain prose line
    # was always ignored before this field ever started accumulating.
    '**'*)
      if [ "$IN_FIELD" -eq 1 ]; then flush_files_field "$PAYLOAD"; IN_FIELD=0; PAYLOAD=""; fi
      continue
      ;;
    *)
      # A continuation line of the field currently accumulating; joined with a single space, trimmed
      # like every other line. Outside a field, an ordinary prose line — ignored, as before. A
      # bulleted `- Modify: …` line under `**Files:**` lands here too (plan-shape.md forbids writing
      # that shape now, but an already-filed plan can still carry one) — its `- ` marker is harmless
      # prose to the grammar above, which finds its backtick-quoted paths regardless.
      [ "$IN_FIELD" -eq 1 ] && PAYLOAD="$PAYLOAD $line"
      continue
      ;;
  esac
done < "$PLAN"
[ "$IN_FIELD" -eq 1 ] && flush_files_field "$PAYLOAD"

# No `### Task` anywhere is not "a fresh plan"; it is a file that is not a plan. Exit 2 — the
# no-verdict code — so a caller cannot read the silence as an all-clear.
[ "$SEEN_TASK" -eq 1 ] || die2 "no '### Task' heading in '$PLAN' — this is not an implementation plan"

if [ "$MISSING" -gt 0 ]; then
  echo "plan-freshness: $MISSING path(s) named by the plan do not exist at $BASE — the plan is STALE." >&2
  echo "                Re-anchor each through its task's '**Interfaces:**' line (SKILL.md Step 2)," >&2
  echo "                or stop: a path that cannot be re-anchored is 'no usable plan' for that task." >&2
  exit 5
fi
