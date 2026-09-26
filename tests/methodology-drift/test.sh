#!/usr/bin/env bash
# tests/methodology-drift/test.sh — docs/methodology.md's "When to call which skill" table is a
# hand-copy of skills/_shared/recap.md's hand-off table (its own header says so), and nothing
# checked the two agreed. #636 changed create-pr and debug-issue's actual behaviour and
# recap.md's row for debug-issue with it; docs/methodology.md kept the pre-#636 wording in three
# spots until #689 fixed them by hand. This pins those three spots so the next such drift is
# caught here instead of rediscovered by hand.
#
# scripts/recap-wiring-check.py already checks docs/methodology.md's SOURCE, recap.md, against
# ARCHITECTURE.md's graph — it does not read docs/methodology.md itself (out of scope for #689,
# see its "Generalizing scripts/recap-wiring-check.py" note). This suite is the narrower, textual
# check: docs/methodology.md must not carry the three strings #636 made stale.
#
# What this suite guards:
#   A. each of the three stale strings, alone in a synthetic fixture         -> REFUSE, naming it
#   A4. the narrative sentence HARD-WRAPPED across two lines, the way        -> REFUSE
#       docs/methodology.md's own prose actually wraps (~100 cols) — a plain single-line grep for
#       the sentence would silently never match this, the real shape of the stale text
#   B. a fixture carrying none of them (today's corrected wording)           -> exit 0, silent
#   C. the real docs/methodology.md in this tree                             -> exit 0, silent
#
# Fail-path-first (A/A4) before the real-tree assertion (C): a check that cannot catch the stale
# text in a fixture built to carry it would pass C for the wrong reason — a check that never runs.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

. "$REPO/tests/_lib.sh" || {
  echo "FAIL: cannot source $REPO/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$REPO"
kit_guard kit_guard_samples_unchanged

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# check_methodology <path> — print one line per stale spot found in that file, nothing on a clean
# one. Exit status mirrors the finding (0 clean, 1 at least one stale spot) — this suite's own
# fixtures are small enough that "grep the output" and "read the exit code" agree, unlike the
# fuller wiring guard this deliberately stays smaller than.
check_methodology() {
  local f="$1" hit=0 line norm

  # Checks 1 and 2 are table rows — markdown constrains a row to one line, so a plain grep -n on
  # the file as written is exact and also gives a useful line number.
  #
  # Check 3 is prose, and docs/methodology.md hard-wraps its prose (~100 cols): the real stale
  # sentence spans two source lines ("...Terminal: it" / "returns to whatever called it, carrying
  # the cause."), so a single-line grep for it would never match the real shape of the drift it
  # exists to catch — only a fixture that artificially puts the whole sentence on one line. $norm
  # collapses every run of whitespace (including the newline the wrap introduces) to one space,
  # so the same substring search works regardless of where docs/methodology.md happens to wrap.
  # `tr -s '[:space:]' ' '` is portable to both BSD and GNU tr — no python3, no GNU-only grep -P.
  norm=$(tr -s '[:space:]' ' ' < "$f")

  # 1. create-pr's "It does NOT do" column: since #636 (skills/create-pr/references/steps/
  #    02-locate-the-work.md's "On $DEFAULT" section) it takes a fix off the default branch itself
  #    rather than refusing there, so the table must not still list that as something it refuses.
  line=$(grep -n 'open from the default branch' "$f") && {
    echo "REFUSE: $f still claims create-pr refuses to open from the default branch (stale since #636):"
    printf '%s\n' "$line"
    hit=1
  }

  # 2. debug-issue's Next column must read the same conditional split
  #    skills/_shared/recap.md's current debug-issue row states, not the old unconditional `—`.
  line=$(grep -n -- '— (returns to whatever called it)' "$f") && {
    echo "REFUSE: $f's debug-issue Next column still reads unconditional (stale since #636):"
    printf '%s\n' "$line"
    hit=1
  }

  # 3. The "### debug-issue" narrative section said the same unconditional thing in prose. The
  #    corrected wording keeps the tail "returns to whatever called it, carrying the cause" (now
  #    preceded by "otherwise it" rather than reachable straight from "Terminal:"), so the search
  #    anchors on the full stale sentence, never on that shared tail alone — a shorter needle would
  #    false-positive on the fix itself.
  case "$norm" in
    *'Terminal: it returns to whatever called it, carrying the cause'*)
      echo "REFUSE: $f's debug-issue narrative still reads unconditional (stale since #636):"
      # Best-effort locator: report the source line "Terminal:" starts on, however it wrapped —
      # $norm proved the match, this just points a human at where to look.
      line=$(grep -n 'Terminal:' "$f" | head -1)
      printf '%s\n' "${line:-  (search near \"### debug-issue\" — the sentence spans a line wrap)}"
      hit=1
      ;;
  esac

  return "$hit"
}

# ---------------------------------------------------------------- A. each stale spot is caught
echo "A. each stale spot, alone in a fixture, is refused"

F=$(kit_scratch)/create-pr-row.md
printf '| a finished feature branch with no PR | `create-pr` | ... | ... | open from the default branch; build a planned issue; land a PR | `/merge-pr #<pr>` |\n' > "$F"
if out=$(check_methodology "$F"); then
  bad "the create-pr stale phrase was not caught"
else
  case "$out" in
    *"open from the default branch"*) ok "the create-pr stale phrase is refused, naming the line" ;;
    *) bad "refused, but without naming the stale phrase"; printf '%s\n' "$out" | sed 's/^/          /' ;;
  esac
fi

F=$(kit_scratch)/debug-issue-row.md
printf '| something broken | `debug-issue` | ... | ... | ... | — (returns to whatever called it) |\n' > "$F"
if out=$(check_methodology "$F"); then
  bad "the debug-issue Next-column stale phrase was not caught"
else
  case "$out" in
    *"unconditional"*) ok "the debug-issue Next-column stale phrase is refused" ;;
    *) bad "refused, but without naming the stale phrase"; printf '%s\n' "$out" | sed 's/^/          /' ;;
  esac
fi

F=$(kit_scratch)/debug-issue-narrative.md
printf '### debug-issue\n\nTerminal: it returns to whatever called it, carrying the cause.\n' > "$F"
if out=$(check_methodology "$F"); then
  bad "the debug-issue narrative stale sentence was not caught"
else
  case "$out" in
    *"unconditional"*) ok "the debug-issue narrative stale sentence is refused" ;;
    *) bad "refused, but without naming the stale sentence"; printf '%s\n' "$out" | sed 's/^/          /' ;;
  esac
fi

echo "A4. the same stale sentence, hard-wrapped across two lines like the real prose"
F=$(kit_scratch)/debug-issue-narrative-wrapped.md
printf '### debug-issue\n\ncommit. Three failed fixes are a signal about the design. Terminal: it\nreturns to whatever called it, carrying the cause.\n' > "$F"
if out=$(check_methodology "$F"); then
  bad "a hard-wrapped stale sentence was not caught (the exact shape #689's review caught)"
else
  case "$out" in
    *"unconditional"*) ok "a hard-wrapped stale sentence is refused too, not just an unwrapped fixture" ;;
    *) bad "refused, but without naming the stale sentence"; printf '%s\n' "$out" | sed 's/^/          /' ;;
  esac
fi

# ---------------------------------------------------------- B. today's corrected wording is clean
echo "B. a fixture carrying today's corrected wording is clean"
F=$(kit_scratch)/clean.md
{
  printf '| a finished feature branch with no PR | `create-pr` | ... | ... | build a planned issue; land a PR | `/merge-pr #<pr>` |\n'
  printf '| something broken | `debug-issue` | ... | ... | ... | `/create-pr` when it ran standalone and left a committed fix, `—` when it returns to its caller |\n'
  printf '\n### debug-issue\n\nTerminal: `/create-pr` when it ran standalone and left a committed fix, otherwise it returns to\nwhatever called it, carrying the cause.\n'
} > "$F"
if out=$(check_methodology "$F"); then
  ok "the corrected wording raises nothing"
else
  bad "the corrected wording was flagged as stale"
  printf '%s\n' "$out" | sed 's/^/          /'
fi

# ------------------------------------------------------------------- C. the real tree is clean
echo "C. docs/methodology.md in this tree carries none of the three stale spots"
if out=$(check_methodology "$REPO/docs/methodology.md"); then
  ok "docs/methodology.md agrees with recap.md's current debug-issue row"
else
  bad "docs/methodology.md still carries stale text"
  printf '%s\n' "$out" | sed 's/^/          /'
fi

# ------------------------------------------------------------------------------------- verdict
echo
if [ "$fails" -eq 0 ]; then
  echo "PASS — docs/methodology.md matches recap.md's current create-pr/debug-issue behaviour"
  exit 0
fi
echo "FAIL — $fails case(s) failed"
exit 1
