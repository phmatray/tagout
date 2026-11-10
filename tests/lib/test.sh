#!/usr/bin/env bash
# tests/_lib.sh golden test.
#
# The helper exists so ten suites stop each carrying their own EXIT trap (#72). The invariant it
# centralises is one line — `local rc=$?` must be the FIRST statement in the handler — and getting
# it wrong turns a FAILING suite into a silent green. Every suite that sources this file now
# depends on that being right here, so it is driven for real rather than restated in a comment.
#
# What is asserted:
#   1. a failing suite still exits non-zero — the invariant, and the reason this file exists;
#   2. a passing suite exits zero, and its scratch directories are gone;
#   3. a registered guard that fails turns a PASSING suite red, and prints its own message;
#   4. a registered guard that passes leaves the status alone;
#   5. `kit_guard_samples_unchanged` catches a mutated samples/ and is silent otherwise;
#   6. `first_match`/`any_match` answer correctly, do NOT trip SIGPIPE with many matches (#48),
#      and tolerate a starting path that does not exist instead of aborting the caller (#98);
#   7. sourcing is loud when the helper is missing — a suite must never run unguarded;
#   8. no suite hand-rolls the EXIT trap again — the anti-recurrence check;
#   9. a suite that uses the helper takes its scratch from it, per occurrence;
#  10. a suite that does NOT use it still leaves no scratch obtained from `mktemp` behind — so §9
#      and §10 together cover every suite's `mktemp` usage, and nothing falls between them (#128);
#      narrowed to that instrument in #160, which is also what §13 exists to cover the remainder of;
#  11. `kit_source` loads a helper and refuses, by name, one it cannot;
#  12. no suite sources a shared helper unguarded — the anti-recurrence check for §11;
#  13. no suite writes a literal `/tmp/…` path — a text-keyed lint, not a coverage claim (#160);
#  14. a forked child killed before bash resets its inherited EXIT trap does not run the handler —
#      the scratch tree survives a watchdog that is killed the instant it is started.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
LIB="$KIT/tests/_lib.sh"
[ -r "$LIB" ] || { echo "FAIL: $LIB is missing"; exit 1; }

# Sourced for its functions, but WITHOUT kit_init — this suite must own its own EXIT trap, or it
# would be testing the handler while depending on it, and a broken handler could then hide its own
# failure. That is the one place in the kit where not using the helper is the point.
. "$LIB"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# Run a throwaway suite that sources the real helper. $1 = body. Prints "<exit>|<output>".
run_suite() {
  local body="$1" f="$scratch/suite-$RANDOM.sh" out rc
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    echo "cd '$KIT'"
    echo ". '$LIB'"
    echo 'kit_init "$PWD"'
    echo "$body"
  } > "$f"
  set +e
  out=$(bash "$f" 2>&1); rc=$?
  set -e
  printf '%s|%s' "$rc" "$out"
}

# ---------------------------------------------------------------------------
# 1. The invariant. A suite that fails must still report failure through the handler.
# ---------------------------------------------------------------------------
r=$(run_suite 's=$(kit_scratch); echo "SCRATCH:$s"; exit 3')
[ "${r%%|*}" = "3" ] || { echo "FAIL: a failing suite reported ${r%%|*}, not 3 — the handler ate the status"; exit 1; }
# …and the scratch dir is gone on the FAILURE path too. This is the whole advantage kit_scratch
# claims over an inline `rm -rf` at the end of a suite, and nothing else here drives it: section 2
# only inspects a passing run. Move the removal behind an `[ "$rc" -eq 0 ]` and every failing run
# of every converted suite would strand its tree, silently.
failed_dir=$(printf '%s' "${r#*|}" | sed -n 's/^SCRATCH://p')
[ -n "$failed_dir" ] || { echo "FAIL: could not read the scratch path back: ${r#*|}"; exit 1; }
[ -d "$failed_dir" ] && { echo "FAIL: a FAILING suite left its scratch dir behind: $failed_dir"; exit 1; }
# Backticks would be command substitution inside double quotes, so `set -e` would run as a command
# and the message would print with a blank subject — on the very assertion this file exists for.
r=$(run_suite 's=$(kit_scratch); false')
[ "${r%%|*}" = "1" ] || { echo 'FAIL: a `set -e` failure reported '"${r%%|*}"', not 1'; exit 1; }
echo "  [1] a failing suite exits non-zero, and its scratch dir is removed on that path too"

# ---------------------------------------------------------------------------
# 2. A passing suite exits 0 and leaves no scratch behind.
# ---------------------------------------------------------------------------
r=$(run_suite 'a=$(kit_scratch); b=$(kit_scratch); echo "$a" > "'"$scratch"'/dirs"; echo "$b" >> "'"$scratch"'/dirs"; :')
[ "${r%%|*}" = "0" ] || { echo "FAIL: a passing suite exited ${r%%|*}: ${r#*|}"; exit 1; }
while read -r d; do
  [ -d "$d" ] && { echo "FAIL: scratch dir survived the run: $d"; exit 1; }
done < "$scratch/dirs"
echo "  [2] a passing suite exits 0, and every scratch dir it took is removed"

# ---------------------------------------------------------------------------
# 3+4. A registered guard can fail a run that would otherwise have passed — and
#      must not disturb one that passes.
# ---------------------------------------------------------------------------
r=$(run_suite 'bad() { echo "FAIL: the extra assertion fired"; return 1; }; kit_guard bad; :')
[ "${r%%|*}" != "0" ] || { echo "FAIL: a failing guard left the run green: ${r#*|}"; exit 1; }
case "${r#*|}" in *"the extra assertion fired"*) : ;; *)
  echo "FAIL: the guard failed but its message never reached the output: ${r#*|}"; exit 1 ;;
esac
r=$(run_suite 'ok() { return 0; }; kit_guard ok; :')
[ "${r%%|*}" = "0" ] || { echo "FAIL: a passing guard changed the status to ${r%%|*}"; exit 1; }
echo "  [3-4] a registered guard can fail the run, and a passing one leaves it alone"

# ---------------------------------------------------------------------------
# 5. The samples/ guard: catches a mutation, silent otherwise.
#
#    Driven on a scratch git repo, never on the kit's own samples/ — a test that had to dirty the
#    real fixture to prove the guard works would be the very accident the guard prevents.
# ---------------------------------------------------------------------------
repo="$scratch/fixture-repo"
mkdir -p "$repo/samples/Frozen"
git init -q "$repo"
echo "original" > "$repo/samples/Frozen/file.txt"
git -C "$repo" add -A
git -C "$repo" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm init

check_guard() { ( set +e; . "$LIB"; KIT_LIB_ROOT="$repo"; kit_guard_samples_unchanged; echo "rc=$?" ); }
[ "$(check_guard | tail -1)" = "rc=0" ] || { echo "FAIL: the guard fired on an untouched fixture"; exit 1; }
echo "mutated" > "$repo/samples/Frozen/file.txt"
out=$(check_guard)
case "$out" in *"rc=1"*) : ;; *) echo "FAIL: the guard missed a mutated fixture: $out"; exit 1 ;; esac
case "$out" in *"samples/Frozen/file.txt"*) : ;; *)
  echo "FAIL: the guard fired but never named the file: $out"; exit 1 ;; esac
echo "  [5] the samples/ guard catches a mutation, names it, and is silent otherwise"

# ---------------------------------------------------------------------------
# 6. first_match / any_match: correct answers, no SIGPIPE at scale, no abort on a missing path.
#
#    The bug it replaces (#48) is a RACE — `find … | grep -q .` only returns 141 when find is still
#    writing as grep exits — so the negative case needs enough matches to provoke it, not one.
# ---------------------------------------------------------------------------
many="$scratch/many"
# One process, not 301. This suite is a prerequisite of ten others and pays this on every run.
mkdir -p "$many"/d{1..300}/__pycache__
if ! any_match "$many" -name '__pycache__' -type d; then
  echo "FAIL: any_match said 'nothing found' with 300 matches present — the SIGPIPE bug is back"
  exit 1
fi
empty="$scratch/empty"; mkdir -p "$empty"
if any_match "$empty" -name '__pycache__' -type d; then
  echo "FAIL: any_match found something in an empty tree"; exit 1
fi
# A path that does not exist must answer "no", not explode the caller under `set -e`.
#
# No `2>/dev/null` here any more: silence on this call is now a promise the probe makes (#124), and
# a redirect on the one call whose quiet is under test would hide the regression it is under test
# for. The promise itself is asserted below; this line just stops covering for it.
if any_match "$scratch/does-not-exist" -name '*'; then
  echo "FAIL: any_match found something under a nonexistent path"; exit 1
fi

# first_match is the half any_match is now built on, so its own contract is driven HERE, beside the
# file that declares it, rather than only downstream in the heaviest suite in the matrix (#98).
# The `if !` IS the assertion, not a style choice: errexit is suppressed for an `if` condition, so a
# probe that reports failure is caught and named here instead of aborting this suite — which is
# precisely what it used to do at its two former call sites, taking their diagnostics down with it.
if ! first_hit=$(first_match "$scratch/does-not-exist" -name '*'); then
  echo "FAIL: first_match reported failure on a path that does not exist. A bare assignment from"
  echo "      it then aborts its caller under 'set -e', before the caller's own '…but it was"
  echo "      empty' diagnostic — the thing that explains the failure — can run."
  exit 1
fi
[ -z "$first_hit" ] || {
  echo "FAIL: first_match returned '$first_hit' under a path that does not exist"; exit 1; }
# …and it must actually return the match when there IS one, or the emptiness above proves nothing.
first_hit=$(first_match "$many" -name '__pycache__' -type d)
case "$first_hit" in
  "$many"/*/__pycache__) : ;;
  *) echo "FAIL: first_match returned '$first_hit', not a matching path under $many"; exit 1 ;;
esac

# The tolerance above must not extend to failures nobody asked to ignore (#124). `2>/dev/null` used
# to cover every one of them, so a typo'd predicate, an unreadable directory or a find that died on
# something real all came back empty and quiet — indistinguishable from "no match". The emptiness
# test written beneath each call site is only a test if empty means one thing; otherwise the FAIL
# message goes on to accuse whatever it was written to accuse. That is the #74 concern — a CI-only
# failure whose published evidence explains the wrong thing — inverted.
if ! noisy_out=$(first_match "$empty" -nmae 'no-such-primary' 2>/dev/null); then
  echo "FAIL: first_match reported failure on a bad predicate. Its status is load-bearing at zero:"
  echo "      a bare 'x=\$(first_match …)' under 'set -e' aborts the caller AT the assignment (#98)."
  exit 1
fi
[ -z "$noisy_out" ] || {
  echo "FAIL: first_match printed '$noisy_out' on stdout for a find that failed"; exit 1; }
noisy_err=$(first_match "$empty" -nmae 'no-such-primary' 2>&1 >/dev/null)
[ -n "$noisy_err" ] || {
  echo "FAIL: first_match swallowed a find failure that is NOT a missing starting path, so the"
  echo "      caller's own '…but it was empty' diagnostic is the only thing the reader gets and it"
  echo "      names the wrong culprit (#124). find's complaint has to reach the console."
  exit 1; }

# …and the quiet half stays quiet. This is the binding constraint, not a nicety: any_match is
# registered from kit_guard, which runs on EVERY exit path including the successful one, so a single
# line of noise here shows up on every clean run of every suite that guards anything.
quiet_err=$(first_match "$scratch/does-not-exist" -name '*' 2>&1 >/dev/null)
[ -z "$quiet_err" ] || {
  echo "FAIL: first_match complained about an absent starting path: $quiet_err"; exit 1; }
any_err=$( { any_match "$scratch/does-not-exist" -name '*' || true; } 2>&1 >/dev/null )
[ -z "$any_err" ] || {
  echo "FAIL: any_match complained about an absent starting path: $any_err"
  echo "      It runs from kit_guard on every exit path — this would print on clean runs too."
  exit 1; }

# A starting path that is absent AND one that yields a match: the complaint is suppressed and the
# match is still returned. Measured on macOS find, this is also the case that proves the status can
# never be read as "found nothing" — find exits 1 here while printing a real hit.
mixed=$(first_match "$scratch/does-not-exist" "$many" -name '__pycache__' -type d 2>&1)
case "$mixed" in
  "$many"/*/__pycache__) : ;;
  *) echo "FAIL: with one absent and one good starting path, first_match produced '$mixed'"; exit 1 ;;
esac

# The suppression rule reads find's message TEXT, so the wordings this host cannot produce are
# driven directly rather than assumed. BSD, GNU (quoted two ways depending on locale), busybox and
# bfs each phrase the same complaint differently; a rule verified on one platform's string can lapse
# silently on another — permissively, which re-opens the noise, or strictly, which restores the
# silence #124 is removing. Both directions are asserted.
while IFS= read -r msg; do
  [ -n "$msg" ] || continue
  kit_find_err_is_absent_path_only "$msg" || {
    echo "FAIL: an absent-path complaint was not recognised, so first_match would print it on every"
    echo "      clean run of every kit_guard: $msg"
    exit 1; }
done <<'ABSENT'
find: /nope: No such file or directory
find: '/nope': No such file or directory
find: ‘/nope’: No such file or directory
bfs: error: /nope: No such file or directory.
ABSENT
while IFS= read -r msg; do
  [ -n "$msg" ] || continue
  if kit_find_err_is_absent_path_only "$msg"; then
    echo "FAIL: a real find failure was classified as an absent starting path and would be"
    echo "      swallowed — the silence this exists to remove: $msg"
    echo "      (The last of these only fails when the phrase is matched UNANCHORED: a path whose"
    echo "      own name ends in it, carrying a different error entirely.)"
    exit 1
  fi
done <<'REAL'
find: -nmae: unknown primary or operator
find: unknown predicate `-nmae'
find: /root/private: Permission denied
bfs: error: Unknown argument; did you mean -name?
find: /x/No such file or directory: Permission denied
REAL
# Mixed: one absent-path line beside a real one must come out FALSE, or the real complaint is
# suppressed by the company it keeps. A whole-string test rather than a per-line one gets this wrong.
kit_find_err_is_absent_path_only "$(printf 'find: /nope: No such file or directory\nfind: /root: Permission denied\n')" && {
  echo "FAIL: a capture mixing an absent-path complaint with a REAL failure was suppressed whole"
  exit 1; }
echo "  [6] first_match/any_match: correct at 300 matches, on empty, and on a missing path;"
echo "      a find failure that is not a missing path reaches stderr, and only that one is quiet"

# ---------------------------------------------------------------------------
# 7. A suite whose helper is missing must FAIL, not run unguarded.
#
#    The opposite choice to skills/implement-issue/scripts/_assert-branch.sh, deliberately: those
#    guards fail open because a guard that cannot start must not block a commit. A test that cannot
#    load its assertions has nothing to offer, and a green one would be a lie.
# ---------------------------------------------------------------------------
f="$scratch/orphan.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo ". '$scratch/no-such-lib.sh'"
  echo 'echo "the suite kept going"'
} > "$f"
set +e
out=$(bash "$f" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: a suite with no helper exited 0: $out"; exit 1; }
case "$out" in *"the suite kept going"*)
  echo "FAIL: the suite ran its body without the helper: $out"; exit 1 ;; esac
echo "  [7] a missing helper stops the suite instead of letting it run unguarded"

# ---------------------------------------------------------------------------
# 8. No suite hand-rolls the trap again.
#
#    Extraction removes today's duplication; this is what stops tomorrow's. The count reached four
#    before anyone noticed, and the fourth (tests/renovate-config) was written by the same author
#    who had just read the other three — copy-paste is not a thing people decide to do.
#
#    Enumerated from the filesystem, never from a list in this file: a hardcoded roster is the
#    stale-inventory failure #45 filed, where the README named three suites and CI ran eight.
# ---------------------------------------------------------------------------
#    The patterns are UNANCHORED on purpose. The first version keyed on `^trap .* EXIT` and shipped
#    blind to the two live copies already in the tree — `tests/worktrees-ignored` and
#    `tests/release-title-gate` both write `WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT`, where
#    the trap is not at column 0. A guard whose whole job is catching a ninth copy could not see
#    the eighth.
#
#    COMMENT-AWARE since #159, sharing code_of with §9:
#
#    CATCHES:
#      * a real `cleanup() { … }` or `trap … EXIT`, anywhere outside a comment, unanchored per above.
#
#    DOES NOT CATCH, and cannot from here:
#      * a handler armed indirectly — through a variable holding the trap command, or `eval`. That
#        gap is unchanged by #159; it was §8's blind spot before comment-awareness and stays one
#        after it, because stripping comments narrows what counts as prose, not what counts as a
#        literal `trap`/`cleanup` spelling. See the brainstorm on #159 for why closing it (running
#        each suite and inspecting the handler it actually installs) is not worth the cost today.

# The file's CODE only: whole-line comments dropped, then trailing comments. Shared by
# hand_rolls_handler (here) and suite_is_member (§9) so the call/mention distinction — a comment
# must never decide a verdict — has one home instead of a second copy that could drift from the
# first, which is exactly how #128 and this section's own defect diverged from each other (#159).
code_of() {
  sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]]#.*$//' "$1"
}

# Does $1 hand-roll its own EXIT handler instead of using tests/_lib.sh's kit_guard? A call, never
# a mention — comments are stripped through code_of first, so prose explaining why a suite uses
# kit_guard cannot itself read as hand-rolling one.
hand_rolls_handler() {
  local body
  body=$(code_of "$1")
  grep -qE '(^|[[:space:];])(cleanup|function cleanup)[[:space:]]*(\(\))?[[:space:]]*\{' <<<"$body" \
    || grep -qE '(^|[[:space:];])trap[[:space:]].*EXIT' <<<"$body"
}

# --- the predicate, driven on fixtures rather than on the tree -------------
# Each of these pins one direction the raw-text grep gets wrong: prose ABOUT the mechanism must
# not enrol a compliant suite, and a REAL hand-rolled handler must still be caught even with a
# trailing comment on its line.
hr_mention_only="$scratch/hr-mention-only.sh"
{
  echo '#!/usr/bin/env bash'
  echo '# see kit_init, which arms a trap on EXIT for you'
} > "$hr_mention_only"

hr_cleanup_in_comment="$scratch/hr-cleanup-in-comment.sh"
{
  echo '#!/usr/bin/env bash'
  echo '# the old shape was: cleanup() { rm -rf "$d"; }'
} > "$hr_cleanup_in_comment"

hr_real_handler="$scratch/hr-real-handler.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'trap "rm -rf $d" EXIT   # cleans up on exit'
} > "$hr_real_handler"

if hand_rolls_handler "$hr_mention_only"; then
  echo "FAIL: a comment MENTIONING trap/EXIT was read as hand-rolling the handler."
  echo "      Prose about the mechanism must not fail the build."
  exit 1
fi
if hand_rolls_handler "$hr_cleanup_in_comment"; then
  echo "FAIL: a comment showing 'cleanup() {' was read as hand-rolling the handler."
  echo "      Prose about the mechanism must not fail the build."
  exit 1
fi
if ! hand_rolls_handler "$hr_real_handler"; then
  echo "FAIL: a REAL hand-rolled trap, with a trailing comment on its line, was not caught."
  exit 1
fi

# --- and now the tree -------------------------------------------------------
offenders=""
for f in tests/*/test.sh; do
  # This suite is the documented exception — it owns its trap so it can test the shared one.
  [ "$f" = "tests/lib/test.sh" ] && continue
  hand_rolls_handler "$f" && offenders="$offenders $f"
done
if [ -n "$offenders" ]; then
  echo "FAIL: these suites define their own EXIT trap instead of using tests/_lib.sh:$offenders"
  echo "      That is how the ten copies this helper replaced came to diverge — one lost the"
  echo "      samples/ check entirely. Use kit_init + kit_guard, or add a documented exception."
  exit 1
fi
echo "  [8] no suite hand-rolls the EXIT trap (tests/lib is the documented exception)"

# ---------------------------------------------------------------------------
# 9. A suite that USES the helper must take its scratch from it.
#
#    Membership is DECLARED BY BEHAVIOUR: a suite is audited when it CALLS kit_init, the thing that
#    actually arms the handler. It used to be inferred from whether the text of the file happened to
#    contain the string `_lib.sh` (#128). That was cheap while there was one shared file with one
#    obvious name; #51 added tests/_lib/py.sh, whose name differs by one character in a position
#    nobody reads, and the audit's reach then depended on spelling. Both halves were wrong, and both
#    were measured:
#
#      * appending the comment `# voir tests/_lib.sh` to a suite that manages its own scratch turned
#        THIS file red — four offenders — for a reason unrelated to the edit;
#      * tests/report-dashboard/test.sh deliberately avoided the substring, and sat in the audit's
#        blind spot while leaking a directory on every run. §9 exists to catch exactly that, and by
#        construction never could. That leak is fixed in the same change.
#
#    A suite may legitimately want py_module without the preamble, so sourcing tests/_lib/py.sh is
#    NOT membership — another distinction a filename match cannot draw.
#
#    Not every suite is a member. Those that manage their own scratch with an inline `rm -rf` are
#    out of scope here; the real difference, for whoever converts one, is that an inline `rm -rf` at
#    the end runs only on the success path, so a suite that fails midway leaves its directory
#    behind, whereas kit_scratch's is removed on every exit path. Worth doing; the audit does not
#    fail over it.
#
#    Within a member suite, though, a stray `mktemp -d` IS a leak — kit_cleanup only removes what
#    lives under its own parent directory.
#
#    Checked PER OCCURRENCE, not per file. Exempting a whole file the moment it mentions
#    `kit_scratch` anywhere is the opposite of the leak described above, and it had a live
#    instance: tests/audit-inventory ran `( cd "$(mktemp -d)" && … )` for its foreign-cwd case, a
#    directory outside KIT_LIB_TMP that nothing removes, in a suite this change converted.
#
#    Both halves are FUNCTIONS so the fixtures below can drive them directly. The real tree cannot
#    tell a right rule from a wrong one here: every live suite answers the same way under either,
#    which is precisely how a wrong rule survived (#128).

# Is $1 a member of the shared library — i.e. does it CALL kit_init?
#
# A call, never a mention. BOTH kinds of comment are dropped first — the whole-line kind and the
# trailing kind — and the name must then sit at a command position, so prose about the helper (this
# file is full of it, and so are the suites) cannot decide who gets audited. That is the defect
# class #128 is about, so reproducing it here would be a poor joke, and dropping only whole-line
# comments would have reproduced exactly half of it: a mention pushed to the end of a code line
# still sits after whitespace, which is a command position to any pattern that looks for one.
#
# The trailing strip keys on whitespace before the `#`, which is what keeps it from eating the
# shell's other uses of that character: `${x#*|}`, `$((n + 1))`-style arithmetic and quoted paths
# have no space in front of theirs. The residue it accepts is a `kit_init` written AFTER a quoted
# `#` on one line — a false NEGATIVE, so a suite would have to hide itself from an audit it opted
# into, and no suite in the tree writes anything of the sort.
#
# Pipe-free on purpose. `grep -v … | grep -q …` lets the reader exit on the first hit; under the
# `set -o pipefail` at the top of this file the writer's SIGPIPE (141) becomes the pipeline's
# status, and "found it" reads back as "not a member" (#48). An audit is the last place that should
# go unnoticed: the failure mode is a silently empty roster, which looks exactly like a clean run.
suite_is_member() {
  local body
  body=$(code_of "$1")
  grep -qE '(^|[[:space:];&|(){}])kit_init([[:space:]]|$)' <<<"$body"
}

# The `mktemp -d` calls in $1 that sit outside kit_scratch's tree, one "    <file>: <n>:<text>"
# line each. A `mktemp -d` rooted under a kit_scratch result is fine — that IS inside KIT_LIB_TMP.
#
# Comments are dropped the SAME two ways suite_is_member drops them, and for the same reason: a
# call and a mention of a call must not look alike. The glob this replaces — `[[:space:]]*\#*` —
# read as "one whitespace character, anything, a `#`, anything", because `*` after a bracket
# expression is a wildcard and not a repetition. Measured: `    d=$(mktemp -d) # note` was skipped
# AS A COMMENT while the same line unindented was flagged, so an indented stray directory escaped
# the audit the moment anyone appended a trailing note to its line. That is a false NEGATIVE in the
# section whose entire job is to find leaks — the failure it produces is a clean-looking run.
# The CODE portion of a single line of text (no leading `<n>:`), comments stripped — empty when the
# whole line is a comment. Strip the leading whitespace properly (`${text%%[![:space:]]*}` is the
# run of it), then a first char of `#` means the whole line is prose. Then the TRAILING kind, keyed
# on whitespace before the `#` so `${x#*|}` and friends survive.
#
# Shared by stray_scratch and (#160) literal_tmp_paths, so the call/mention distinction — a comment
# must never count as code — has one home instead of a second copy that could drift from the first.
code_only() {
  local text="$1" lead
  lead=${text%%[![:space:]]*}
  text=${text#"$lead"}
  case "$text" in \#*) return 0 ;; esac
  printf '%s' "${text%%[[:space:]]#*}"
}

stray_scratch() {
  local line code
  while IFS= read -r line; do
    # `<n>:<text>` from grep -n.
    code=$(code_only "${line#*:}")
    case "$code" in *'mktemp -d'*) : ;; *) continue ;; esac
    # The exemptions read the CODE, not the comment — otherwise a line could exempt itself by
    # mentioning kit_scratch in a note, which is the same defect one column over.
    case "$code" in
      *kit_scratch*|*'$WORK'*|*'$scratch'*) continue ;;
      *) printf '%s\n' "    $1: $line" ;;
    esac
  done < <(grep -n 'mktemp -d' "$1" || true)
}

# --- the predicate, driven on fixtures rather than on the tree ---------------
# Each of these two fails under a substring rule, in OPPOSITE directions — which is what makes
# them worth writing: one is dragged in by prose, the other is invisible despite being a member.
mentions_only="$scratch/mentions-only.sh"
{
  echo '#!/usr/bin/env bash'
  echo '# Prose naming tests/_lib.sh and kit_init, calling neither. A comment is not a call.'
  echo 'd=$(mktemp -d); rm -rf "$d"'
} > "$mentions_only"

# The same mention, moved to the END of a code line. Dropping whole-line comments alone does not
# reach it, and the mention then sits at a command position for any `kit_init` pattern to match —
# so this fixture enrolls a non-member unless trailing comments are stripped too. It is the
# original defect at one remove: prose still deciding who gets audited, just further right.
trailing_mention="$scratch/trailing-mention.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'd=$(mktemp -d)   # the shared preamble would arm kit_init here'
  echo 'rm -rf "$d"'
} > "$trailing_mention"

# Sources the helper through a VARIABLE, so its filename never appears literally: a real member
# that a substring rule cannot see. That is the shape the leak §9 exists to catch was hiding in.
calls_it="$scratch/calls-kit-init.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'lib="$KIT/tests/$helper"'
  echo '. "$lib"'
  echo 'kit_init "$PWD"'
  echo 'd=$(mktemp -d)'
} > "$calls_it"

uses_helper="$scratch/uses-kit-scratch.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'kit_init "$PWD"'
  echo 'd=$(kit_scratch)'
} > "$uses_helper"

if suite_is_member "$mentions_only"; then
  echo "FAIL: a suite that only MENTIONS the shared helper was enrolled in the scratch audit."
  echo "      Membership must follow a kit_init CALL; a filename in the text is not a declaration,"
  echo "      and keying on one turns an unrelated comment into a red run."
  exit 1
fi
if suite_is_member "$trailing_mention"; then
  echo "FAIL: a mention of kit_init in a TRAILING comment enrolled the suite. Dropping whole-line"
  echo "      comments is not enough — a comment that starts mid-line is still a comment, and the"
  echo "      audit's reach would again depend on prose an editor added for unrelated reasons."
  exit 1
fi
if ! suite_is_member "$calls_it"; then
  echo "FAIL: a suite that CALLS kit_init was left out of the scratch audit — the blind spot a"
  echo "      leaking directory sat in for as long as its file avoided spelling the helper's name."
  exit 1
fi
[ -n "$(stray_scratch "$calls_it")" ] || {
  echo "FAIL: the per-occurrence audit missed a bare 'mktemp -d'"; exit 1; }
[ -z "$(stray_scratch "$uses_helper")" ] || {
  echo "FAIL: the per-occurrence audit flagged a directory taken from kit_scratch"; exit 1; }

# The same comment/call distinction, now for the OCCURRENCE audit rather than for membership, and
# in both directions. These two fixtures differ by one trailing note and must come out opposite.
#
# An INDENTED stray directory whose line carries a trailing comment. Under the glob this replaces it
# was skipped as though the whole line were a comment — measured — so appending a note to a leaky
# line removed it from the audit. Every real suite indents; this is the shape the defect had.
indented_trailing="$scratch/indented-trailing-comment.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'kit_init "$PWD"'
  echo 'if true; then'
  echo '    d=$(mktemp -d) # kept until the end of the block'
  echo 'fi'
} > "$indented_trailing"
[ -n "$(stray_scratch "$indented_trailing")" ] || {
  echo "FAIL: an INDENTED 'mktemp -d' with a trailing comment was skipped as if the whole line"
  echo "      were a comment. A note appended to a leaky line must not remove it from the audit —"
  echo "      that is a false negative in the one section whose job is to find leaks."
  exit 1; }

# And the converse: `mktemp -d` named only inside a trailing comment is prose, not a call. Without
# this the fix above could be "flag everything", which passes the fixture above and fails the tree.
comment_only="$scratch/mktemp-only-in-comment.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'kit_init "$PWD"'
  echo '    d=$(kit_scratch)   # never a bare mktemp -d here'
} > "$comment_only"
[ -z "$(stray_scratch "$comment_only")" ] || {
  echo "FAIL: the audit flagged a 'mktemp -d' that appears only inside a trailing comment — prose"
  echo "      about the rule read as a breach of it: $(stray_scratch "$comment_only")"
  exit 1; }

# --- and now the tree -------------------------------------------------------
leaky=""
for f in tests/*/test.sh; do
  [ "$f" = "tests/lib/test.sh" ] && continue
  suite_is_member "$f" || continue
  # Command substitution eats trailing newlines, so the separator is added here rather than
  # relying on one surviving the capture — otherwise two offenders would print on one line.
  hits=$(stray_scratch "$f")
  [ -n "$hits" ] && leaky="$leaky
$hits"
done
if [ -n "$leaky" ]; then
  echo "FAIL: these mktemp -d calls sit outside kit_scratch's tree, so kit_cleanup cannot remove"
  echo "      what they take:$leaky"
  exit 1
fi
echo "  [9] a suite that uses the helper takes its scratch from it"

# ---------------------------------------------------------------------------
# 10. A suite that is NOT a member must not leak scratch obtained from `mktemp` either.
#
#     NARROWED (#160): this section's instrument is the `mktemp` shim below, so its claim is about
#     scratch obtained THAT WAY, not about every temp artefact a suite might produce. That gap had a
#     live instance — tests/followups/test.sh wrote two FIXED `/tmp` paths, calling `mktemp` never,
#     so this section's ledger stayed empty and it reported clean while the suite leaked on every
#     run. §9 does not cover it either (it audits `mktemp -d` calls inside members). A fixed path is
#     invisible to both, by construction, until it is spelled literally — which is what §13's lint is
#     for; that is a text-keyed anti-recurrence measure, not a wider version of this section's claim.
#
#     §9 covers the members: kit_cleanup removes what kit_scratch took, on every exit path. A suite
#     that manages its own scratch is outside that guarantee, and nothing ever measured it — which
#     is how tests/report-dashboard/test.sh came to leak a directory on every single run, unnoticed
#     (#128). It was in §9's blind spot by construction, since §9 keyed on a filename that suite
#     deliberately avoided spelling. The two sections together now cover every suite's `mktemp`
#     scratch, so a change that moves a suite from one side to the other cannot drop it out of both.
#
#     BEHAVIOURAL, not textual: the suite is run for real, every path `mktemp` hands it is recorded,
#     and the ones that still exist afterwards are the leak. A suite that cleans up correctly comes
#     out clean whichever spelling it used, and there is no pattern to keep in step with the code —
#     which is the whole point, after a rule keyed on spelling missed a real leak.
#
#     The live loop visits every NON-MEMBER, with no further gate — the `grep -q mktemp` that used
#     to stand in front of it is gone, because deciding who gets measured by whether four letters
#     appear in the file is the inference #128 exists to delete, and it had already reduced this
#     loop to zero suites (see the roster note below).
#
#     The FIXTURES are what keep this honest when that roster is empty, which it legitimately can
#     be: convert every suite and §9 owns them all. Driving a deliberately leaky suite through the
#     same harness proves the detector still detects — and it earned its place twice during #128,
#     catching both of the wrong mechanisms tried before this one. The count of suites actually
#     inspected is printed, so a section that measured nothing says so instead of implying it did.
# ---------------------------------------------------------------------------
# What NOT to do, both measured rather than reasoned about:
#
#   * "run it with TMPDIR pointing somewhere private, then look in there." `mktemp -d` with no
#     template — the form every self-managing suite uses — honours $TMPDIR under GNU coreutils and
#     IGNORES it under BSD/macOS, which takes the per-user temp dir regardless. On a maintainer's
#     Mac the check would have measured an empty directory and printed OK.
#   * "…and re-root it with -p so both mktemps comply." That works, but everything ELSE that reads
#     TMPDIR writes there too: probing for `node` and `dotnet` in tests/preflight deposited
#     `node-compile-cache` and `NuGetScratch`, and the suite was accused of leaking them.
#
# So the ledger: a one-file `mktemp` shim, first on PATH, appends every path the real mktemp returns
# and otherwise behaves identically. Attribution is then exact — these are the paths THIS suite was
# handed — and it needs no environment override at all, so the suite runs in its normal conditions.
shim_dir="$scratch/shim"
mkdir -p "$shim_dir"
real_mktemp=$(command -v mktemp)
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo "real='$real_mktemp'"
  # Status and stderr are the real mktemp's; only stdout is observed on the way past. `-u` names a
  # path without creating it, which simply never shows up as a leftover — no special case needed.
  echo 'out=$("$real" "$@")'
  # `:-` and an `if`, not a bare `$MKTEMP_SHIM_LEDGER`. The shim runs under `set -u` inside whatever
  # environment the suite hands its children, and a suite that drops the variable while keeping the
  # shim on PATH (`env -u`, an explicit `unset`, `env -i PATH="$PATH"`) made it abort with
  # `MKTEMP_SHIM_LEDGER: unbound variable` — measured. leftovers_of discards both streams, so that
  # surfaced only as a non-zero rc, and the message below then blamed the SUITE for a defect the
  # harness had created. A measurement apparatus must never be able to fail its subject.
  #
  # Passing the path through unrecorded is the lesser wrong: what is lost is attribution for that
  # one call, and the warning names the shim so the loss is not silent. Being aborted by the ruler
  # you are being measured with is not recoverable from at all.
  #
  # An `if`, because `[ -n "$l" ] && printf …` IS the whole statement here: with an empty ledger the
  # compound returns 1 and `set -e` kills the shim — reintroducing the abort by another route.
  echo 'ledger="${MKTEMP_SHIM_LEDGER:-}"'
  echo 'if [ -n "$ledger" ]; then'
  echo '  printf "%s\n" "$out" >> "$ledger"'
  echo 'else'
  echo '  echo "mktemp shim: MKTEMP_SHIM_LEDGER is not set; this path is NOT attributed" >&2'
  echo 'fi'
  echo 'printf "%s\n" "$out"'
} > "$shim_dir/mktemp"
chmod +x "$shim_dir/mktemp"

# Prints "<rc>|<leftover paths, newline-separated>" for the suite at $1. Whatever it leaked is
# REMOVED here: a leak detector that leaves the leak behind makes every later run of this file
# noisier than the last, and tests/lib is a prerequisite of ten other suites.
leftovers_of() {
  local ledger rc left p
  ledger=$(mktemp "$scratch/ledger.XXXXXX")
  set +e
  PATH="$shim_dir:$PATH" MKTEMP_SHIM_LEDGER="$ledger" bash "$1" >/dev/null 2>&1
  rc=$?
  set -e
  left=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -e "$p" ] || continue
    if [ -n "$left" ]; then left="$left
$p"; else left="$p"; fi
    rm -rf "$p"
  done < "$ledger"
  rm -f "$ledger"
  printf '%s|%s' "$rc" "$left"
}

# The exact shape the leak had: the directory is never even bound to a variable, so no `rm -rf`
# anywhere in the file could have removed it.
leaky_suite="$scratch/leaks-a-tmpdir.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'f="$(mktemp -d)/artifact.html"'
  echo ': > "$f"'
} > "$leaky_suite"
r=$(leftovers_of "$leaky_suite")
[ "${r%%|*}" = "0" ] || { echo "FAIL: the leaky fixture did not even run: ${r#*|}"; exit 1; }
[ -n "${r#*|}" ] || {
  echo "FAIL: the leak detector saw nothing under a suite that never removes its mktemp -d."
  echo "      Every OK line this section prints would then be meaningless."
  exit 1; }

tidy_suite="$scratch/removes-its-tmpdir.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'd=$(mktemp -d)'
  echo 'rm -rf "$d"'
} > "$tidy_suite"
r=$(leftovers_of "$tidy_suite")
[ "${r%%|*}" = "0" ] || { echo "FAIL: the tidy fixture did not even run: ${r#*|}"; exit 1; }
[ -z "${r#*|}" ] || { echo "FAIL: the detector flagged a suite that removes what it took: ${r#*|}"; exit 1; }

# A suite that drops MKTEMP_SHIM_LEDGER from a child's environment while the shim is still on PATH.
# The shim runs under `set -u`, so it used to abort with `unbound variable` — and because
# leftovers_of discards both streams, that reached the loop below as a bare non-zero rc and was
# reported as the SUITE having failed. The apparatus must not be able to fail its subject: the run
# is expected to succeed, and to be reported clean.
scrubbing_suite="$scratch/scrubs-the-ledger.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'd=$(env -u MKTEMP_SHIM_LEDGER mktemp -d)'
  echo 'rm -rf "$d"'
} > "$scrubbing_suite"
r=$(leftovers_of "$scrubbing_suite")
[ "${r%%|*}" = "0" ] || {
  echo "FAIL: a suite that drops MKTEMP_SHIM_LEDGER from a child's environment was aborted by the"
  echo "      ledger shim (exit ${r%%|*}) — and would then be blamed below for a failure the"
  echo "      measurement created. The shim must pass the path through unrecorded instead."
  exit 1; }

# --- the tree, and the roster it actually inspected -------------------------
# NO `grep -q mktemp` gate here any more. That gate was the same spelling-keyed inference #128 was
# filed to delete: a non-member taking its scratch through `python3 -c 'tempfile.mkdtemp()'`,
# `install -d` or a wrapper was skipped because the four letters did not appear, which is exactly
# the blind spot report-dashboard's leak lived in. The ledger costs nothing on a suite that takes no
# temp directory — an empty ledger is an empty answer — so there is nothing to gate on.
#
# `inspected` is counted and REPORTED. Every suite is claimed by exactly one of §9 and §10, and both
# rosters are printed, because the state this section reached in review was a loop over zero suites
# that still printed a confident OK line: `tests/followups` was the only non-member and it does not
# spell `mktemp`, so the gate skipped the one suite the section existed for while the header claimed
# the two sections covered the tree between them. An empty roster is legitimate — convert every
# suite and §9 owns them all — but it must SAY it inspected nothing rather than let the OK line
# imply otherwise. The fixtures above are what still assert in that state.
inspected=0
for f in tests/*/test.sh; do
  [ "$f" = "tests/lib/test.sh" ] && continue
  suite_is_member "$f" && continue           # §9 owns the members
  inspected=$((inspected + 1))
  r=$(leftovers_of "$f")
  [ "${r%%|*}" = "0" ] || {
    echo "FAIL: $f exited ${r%%|*} under the mktemp ledger shim — a run that failed proves nothing"
    echo "      about what it cleans up. Fix that suite first; this section measures successful"
    echo "      runs. (The shim only records what mktemp returned; it overrides no TMPDIR, so a"
    echo "      failure here is the suite's own and not an artefact of how it was measured.)"
    exit 1; }
  [ -z "${r#*|}" ] || {
    echo "FAIL: $f manages its own scratch and left this behind after a SUCCESSFUL run:"
    printf '%s\n' "${r#*|}" | sed 's/^/        /'
    echo "      Remove it before the suite returns, or take it from kit_scratch, which is removed"
    echo "      on every exit path including the failing one."
    exit 1; }
done
if [ "$inspected" -eq 0 ]; then
  echo "  [10] no suite manages its own scratch — every suite is a member, so §9 covers the tree"
  echo "       on its own. The leak detector itself is still asserted, on fixtures."
else
  echo "  [10] $inspected suite(s) manage their own scratch and leave no temp directory behind"
fi

# ---------------------------------------------------------------------------
# 11. kit_source: a helper that cannot be loaded stops the suite, by name.
#
#     The guarded-source preamble
#
#         . "$KIT/tests/_lib.sh" || {
#           echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
#
#     was copy-pasted across ten suites, in four spellings of the root variable and two languages,
#     and tests/xunit-v3/test.sh guarded one of its two shared sources and left the other bare —
#     inconsistent inside a single file (#128). Same argument as py_module (#42, #51) and the trap
#     handler (#72), applied to the mechanism that loads them.
#
#     One source per suite must still be spelled out: kit_source lives in the file it would have to
#     load. That bootstrap line is the only one, and every source AFTER it is one call.
#
#     Driven through run_suite, so the refusal is observed as a suite would experience it — the exit
#     status AND the fact that the body never ran. A guard that printed and continued would be worse
#     than none, since the suite would then assert nothing and say OK.
# ---------------------------------------------------------------------------
r=$(run_suite 'kit_source "'"$scratch"'/no-such-helper.sh"; echo "the suite kept going"')
[ "${r%%|*}" != "0" ] || {
  echo "FAIL: kit_source exited 0 on a helper that does not exist: ${r#*|}"; exit 1; }
case "${r#*|}" in *"the suite kept going"*)
  echo "FAIL: kit_source printed a complaint and let the suite run on unguarded: ${r#*|}"; exit 1 ;;
esac
case "${r#*|}" in *no-such-helper.sh*) : ;; *)
  echo "FAIL: kit_source refused without naming the file it could not load: ${r#*|}"; exit 1 ;;
esac

# A helper that is READABLE but does not PARSE — what a dropped `fi` or an unclosed quote produces.
# The `|| {` after the source cannot reach it: bash aborts inside the source itself (measured on
# 3.2 — exit 2, the branch never runs), which is why kit_source parses in a child shell FIRST.
#
# The assertion worth making is not "it stopped": bash stops too, and names the file while it is at
# it. It is that NOTHING IN THE HELPER RAN. `source` executes a file as it parses it, so with the
# error on line 3 the top-level commands on lines 1-2 have already taken effect by the time the
# shell dies — measured, the fixture's side effect printed and THEN the syntax error. A
# half-executed helper is the state this file exists to make impossible, and not reaching it is the
# one thing the pre-parse buys. Key the fixture on that, or it passes with or without the guard.
printf 'echo "HELPER SIDE EFFECT RAN"\nkit_source_probe() { echo hi; }\nthis is a ( parse error\n' \
  > "$scratch/unparsable-helper.sh"
r=$(run_suite 'kit_source "'"$scratch"'/unparsable-helper.sh"; echo "the suite kept going"')
[ "${r%%|*}" != "0" ] || {
  echo "FAIL: kit_source exited 0 on a helper that does not parse: ${r#*|}"; exit 1; }
case "${r#*|}" in *"the suite kept going"*)
  echo "FAIL: kit_source let the suite run on after a helper that does not parse: ${r#*|}"; exit 1 ;;
esac
case "${r#*|}" in *"HELPER SIDE EFFECT RAN"*)
  echo "FAIL: an unparsable helper's top-level commands ran before the shell noticed. source"
  echo "      executes as it parses, so the helper took effect up to the broken line and left the"
  echo "      suite in a state nobody wrote down. Parse it before sourcing it: ${r#*|}"
  exit 1 ;;
esac
case "${r#*|}" in *unparsable-helper.sh*) : ;; *)
  echo "FAIL: kit_source refused an unparsable helper without naming it: ${r#*|}"; exit 1 ;;
esac

# The passing path, or the refusal above proves only that kit_source can say no. A helper it loads
# must actually have taken effect — a definition from it is callable afterwards.
printf 'kit_source_probe() { echo "probe-loaded"; }\n' > "$scratch/loadable-helper.sh"
r=$(run_suite 'kit_source "'"$scratch"'/loadable-helper.sh"; kit_source_probe')
[ "${r%%|*}" = "0" ] || { echo "FAIL: kit_source refused a readable helper: ${r#*|}"; exit 1; }
case "${r#*|}" in *probe-loaded*) : ;; *)
  echo "FAIL: kit_source returned 0 but the helper's definitions are not in scope: ${r#*|}"; exit 1 ;;
esac

# bash is DYNAMICALLY scoped, so every `local` in kit_source is in scope while the helper is being
# sourced. A helper setting a top-level global that collides with one of those locals writes the
# local instead, and the value evaporates the moment kit_source returns — the helper appears to load
# fine and its global is simply not there, which surfaces far away as an unset variable. `f` was the
# collision in reach: it is what kit_source's own parameter used to be called and what every loop in
# this repo calls its file. Measured before the rename: `f` came out UNSET after a helper set it.
printf 'f=helper-global\n' > "$scratch/sets-f-helper.sh"
r=$(run_suite 'kit_source "'"$scratch"'/sets-f-helper.sh"; echo "f=[${f:-<unset>}]"')
[ "${r%%|*}" = "0" ] || { echo "FAIL: kit_source refused a helper that sets a global: ${r#*|}"; exit 1; }
case "${r#*|}" in *"f=[helper-global]"*) : ;; *)
  echo "FAIL: a global the helper set did not survive kit_source — one of its locals shadowed the"
  echo "      name while the helper was sourced, and bash's dynamic scoping put the assignment"
  echo "      there instead: ${r#*|}"
  exit 1 ;;
esac
echo "  [11] kit_source loads a helper, and refuses one it cannot read or parse, naming it"

# ---------------------------------------------------------------------------
# 12. No suite loads a shared helper unguarded.
#
#     §11 proves kit_source refuses; this proves nothing skipped it. The failure it prevents is
#     silent by construction: `. missing.sh` under `set -e` stops the suite with bash's own
#     line-number complaint and no mention of which helper — but a suite that sources a helper
#     BARE and keeps going asserts less than it claims to while still printing OK, which is the
#     outcome this whole file exists to make impossible.
#
#     It had a live instance when this was written: tests/xunit-v3/test.sh guarded one of its two
#     shared sources and left the other bare, sixty lines apart, in a file its own author had just
#     written both halves of (#128) — the same "copy-paste is not a thing people decide to do"
#     argument §8 makes about the trap.
#
#     Enumerated from the filesystem, never from a list here (#45), and over the shared helpers as
#     well as the suites — a rule its own subjects are exempt from is not a rule. tests/lib/test.sh
#     is the one exemption: it sources the file under test deliberately, guarded by its own `[ -r ]`
#     check at the top, and the illustrative preamble in §11's comment above would otherwise match.
# ---------------------------------------------------------------------------
# The unguarded sources in $1, one "<n>:<text>" line each.
#
# Three things this pattern deliberately does NOT key on, each of them a way the check could have
# held for the form nobody types and lapsed for the form they do — the shape of #128's original
# defect, which would be a poor thing to reproduce in the section written to prevent recurrence:
#
#   * the SPELLING of the builtin. Both `.` and `source`; `source` is what a newcomer reaches for.
#   * the PATH. The old pattern required the literal text `tests/_lib` on the line, so
#     `lib="$KIT/tests/_lib.sh"; . "$lib"` — the variable form, and the very shape §9's `calls_it`
#     fixture uses to show a member hiding from a substring rule — sailed through unguarded. There
#     is no reason to source anything in a suite without a guard, so the rule is now simply "every
#     source is guarded" and there is no path to be blind to.
#   * WHICH FILES get scanned. tests/_lib.sh and tests/_lib/*.sh are shared helpers that may source
#     shared helpers; scanning only tests/*/test.sh left them out of their own rule.
#
# What it must not catch is `source = open(…)` inside a Python heredoc — an assignment, not a
# builtin — hence the "next character is neither `=` nor blank" tail.
bare_sources() {
  local hit n text guarded probe stop line trimmed
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    n=${hit%%:*}
    text=${hit#*:}
    guarded=0
    # A guard may sit on the source line itself, or open with `|| {` and close some lines later.
    # The lookahead runs to the end of that block rather than to the next line: kit_source's own
    # guarded source carries three comment lines before its `exit 1`, and a one-line lookahead
    # reported the kit's canonical guarded form as unguarded the moment this rule reached it.
    case "$text" in *"exit 1"*) guarded=1 ;; esac
    if [ "$guarded" -eq 0 ]; then
      case "$text" in *'|| {'*)
        probe=$((n + 1)); stop=$((n + 20))
        while [ "$probe" -le "$stop" ]; do
          line=$(sed -n "${probe}p" "$1")
          case "$line" in *"exit 1"*) guarded=1; break ;; esac
          trimmed=${line#"${line%%[![:space:]]*}"}
          case "$trimmed" in '}'*) break ;; esac
          probe=$((probe + 1))
        done ;;
      esac
    fi
    if [ "$guarded" -eq 1 ]; then continue; fi
    printf '%s\n' "    $1:$hit"
  done < <(grep -nE '^[[:space:]]*(\.|source)[[:space:]]+[^=[:space:]]' "$1" || true)
}

# Fixtures first, for the same reason as §9 and §10: the tree currently answers "all guarded", so
# it cannot tell a working check from one that matches nothing at all.
bare_fixture="$scratch/sources-bare.sh"
printf '. "$KIT/tests/_lib.sh"\nkit_init "$PWD"\n' > "$bare_fixture"
[ -n "$(bare_sources "$bare_fixture")" ] || {
  echo "FAIL: the bare-source check did not flag a bare '. \$KIT/tests/_lib.sh'"; exit 1; }

# `source` is bash's other spelling of `.`, and it is the one a newcomer reaches for. A check that
# polices only the dot leaves the commoner spelling unpoliced, so the anti-recurrence guarantee
# would hold for the form nobody types and lapse for the form they do — the same "the reach depends
# on how it was written" hole §9 was rewritten to close.
bare_keyword_fixture="$scratch/sources-bare-keyword.sh"
printf 'source "$KIT/tests/_lib.sh"\nkit_init "$PWD"\n' > "$bare_keyword_fixture"
[ -n "$(bare_sources "$bare_keyword_fixture")" ] || {
  echo "FAIL: the bare-source check did not flag a bare 'source \$KIT/tests/_lib.sh' — only the"
  echo "      dot spelling was policed, so the guard lapses on the form most people write."
  exit 1; }

# The path in a VARIABLE, so the helper's filename never appears on the source line. The old rule
# required the literal text `tests/_lib` there and so could not see this at all — the identical
# blind spot §9 was rewritten to remove, sitting in the section whose job is to prevent its return.
# It is not a hypothetical shape: §9's own `calls_it` fixture is written exactly this way, because
# it is how the leak that started #128 stayed invisible.
bare_variable_fixture="$scratch/sources-bare-variable.sh"
printf 'lib="$KIT/tests/_lib.sh"\n. "$lib"\nkit_init "$PWD"\n' > "$bare_variable_fixture"
[ -n "$(bare_sources "$bare_variable_fixture")" ] || {
  echo "FAIL: a bare source of a path held in a VARIABLE was not flagged. The check still keys on"
  echo "      the helper's name appearing literally on the line, which is the inference #128 exists"
  echo "      to delete — and the one shape a suite hiding from this rule would actually use."
  exit 1; }

guarded_fixture="$scratch/sources-guarded.sh"
{
  echo '. "$KIT/tests/_lib.sh" || {'
  echo '  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }'
} > "$guarded_fixture"
[ -z "$(bare_sources "$guarded_fixture")" ] || {
  echo "FAIL: the bare-source check flagged the guarded bootstrap form"; exit 1; }

# The guard block may run to several lines — kit_source's own does, with comments between the `|| {`
# and its `exit 1`. A one-line lookahead called that unguarded, i.e. reported the kit's canonical
# form as a breach of the kit's own rule.
guarded_block_fixture="$scratch/sources-guarded-block.sh"
{
  echo 'lib="$KIT/tests/_lib.sh"'
  echo '. "$lib" || {'
  echo '  # why this refuses rather than warns'
  echo '  echo "FAIL: cannot source $lib"'
  echo '  exit 1'
  echo '}'
} > "$guarded_block_fixture"
[ -z "$(bare_sources "$guarded_block_fixture")" ] || {
  echo "FAIL: a source guarded by a multi-line '|| { … exit 1; }' block was flagged as bare:"
  echo "      $(bare_sources "$guarded_block_fixture")"
  exit 1; }

# `source = open(…)` in a Python heredoc is an assignment, not the builtin. Broadening the rule to
# every source line is only safe if it can still tell those apart — tests/xunit-v3/test.sh has one.
python_assignment_fixture="$scratch/python-source-assignment.sh"
printf 'python3 <<PY\nsource = open("x").read()\nPY\n' > "$python_assignment_fixture"
[ -z "$(bare_sources "$python_assignment_fixture")" ] || {
  echo "FAIL: 'source = open(…)' in a Python heredoc was read as the shell's source builtin:"
  echo "      $(bare_sources "$python_assignment_fixture")"
  exit 1; }

# Suites AND the shared helpers themselves. tests/_lib.sh sources through kit_source, and a rule
# that exempts the file defining the rule is not one.
unguarded=""
for f in tests/*/test.sh tests/_lib.sh tests/_lib/*.sh; do
  [ "$f" = "tests/lib/test.sh" ] && continue
  [ -f "$f" ] || continue
  hits=$(bare_sources "$f")
  [ -n "$hits" ] && unguarded="$unguarded
$hits"
done
if [ -n "$unguarded" ]; then
  echo "FAIL: these files source another file without refusing to run when it cannot be loaded."
  echo "      Use kit_source, or the two-line bootstrap form, but never a bare dot:$unguarded"
  exit 1
fi
echo "  [12] every source is guarded — kit_source, or the bootstrap form (helpers included)"

# ---------------------------------------------------------------------------
# 13. No suite writes a literal `/tmp/…` path — the lint §10 was narrowed FOR (#160).
#
#     Text-keyed, not behavioural: it greps for the four characters `/tmp/`, so a suite that hides
#     the same string in a variable (`t=/tmp; f="$t/x"`) sails through unseen. §10 does NOT close
#     that gap either: its instrument is the `mktemp` shim, so a suite that builds a hidden path this
#     way and creates it with anything other than `mktemp` (`mkdir -p "$f"`, `install -d`, …) leaves
#     no trace in either section's ledger — both report clean while the directory leaks forever. That
#     residual gap is real and unclosed; catching it would need value tracking through variables,
#     which is a taint-analysis problem this text-keyed lint does not attempt. What THIS section does
#     catch is the hazard at the moment a fixed path is WRITTEN LITERALLY, whether or not the run that
#     follows happens to leak or collide on it. A lint, not a coverage claim, and it must not be read
#     as a wider one than §10 was just narrowed to.
#
#     A line may carry the `tmp-lint:allow` marker — a bare token, the same shape as
#     pinned-literals-check.py's `pinned:<pin>` — to record a DELIBERATE literal. The marker sits on
#     the line it excuses, in a trailing comment, so the exemption cannot drift out of step with what
#     it is exempting: tests/renovate-config/test.sh sets a config's `baseDir` to `/tmp/renovate` to
#     prove the validator rejects it — the string is test DATA, not a path this suite writes to.
# ---------------------------------------------------------------------------
# The literal `/tmp/…` occurrences in $1 that are CODE, not prose or an exempted deliberate case —
# one "    <file>:<n>:<text>" line each. The marker is read from the RAW line, not the comment-
# stripped code: it typically lives inside the very trailing comment code_only would strip, e.g.
# `cfg["baseDir"] = "/tmp/renovate"  # tmp-lint:allow — …`.
literal_tmp_paths() {
  local line text code
  while IFS= read -r line; do
    text=${line#*:}
    case "$text" in *'tmp-lint:allow'*) continue ;; esac
    code=$(code_only "$text")
    case "$code" in *'/tmp/'*) printf '%s\n' "    $1: $line" ;; esac
  done < <(grep -n '/tmp/' "$1" || true)
}

tmp_literal_fixture="$scratch/writes-tmp-literal.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'f=/tmp/x'
  echo ': > "$f"'
} > "$tmp_literal_fixture"
[ -n "$(literal_tmp_paths "$tmp_literal_fixture")" ] || {
  echo "FAIL: literal_tmp_paths did not flag a bare '/tmp/x'"; exit 1; }

# Prose mentioning /tmp only inside a comment is not a path the suite writes — the same call/mention
# distinction §9's suite_is_member draws, one level down.
tmp_prose_fixture="$scratch/mentions-tmp-in-comment.sh"
{
  echo '#!/usr/bin/env bash'
  echo '# scratch used to live under /tmp/whatever before kit_scratch existed'
  echo 'd=$(kit_scratch)'
} > "$tmp_prose_fixture"
[ -z "$(literal_tmp_paths "$tmp_prose_fixture")" ] || {
  echo "FAIL: literal_tmp_paths flagged a '/tmp/' mentioned only in a comment: $(literal_tmp_paths "$tmp_prose_fixture")"
  exit 1; }

# The marker exempts a deliberate literal — a config value under test, not a path this suite writes.
tmp_exempt_fixture="$scratch/exempted-tmp-literal.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'cfg_baseDir=/tmp/renovate  # tmp-lint:allow — a config VALUE under test, not a written path'
} > "$tmp_exempt_fixture"
[ -z "$(literal_tmp_paths "$tmp_exempt_fixture")" ] || {
  echo "FAIL: literal_tmp_paths flagged a line carrying its own exemption marker: $(literal_tmp_paths "$tmp_exempt_fixture")"
  exit 1; }

# And the converse of the marker: without it, the very same literal must still be flagged — otherwise
# the fixture above proves nothing about the marker specifically.
tmp_unexempt_fixture="$scratch/unexempted-tmp-literal.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'cfg_baseDir=/tmp/renovate'
} > "$tmp_unexempt_fixture"
[ -n "$(literal_tmp_paths "$tmp_unexempt_fixture")" ] || {
  echo "FAIL: literal_tmp_paths did not flag the same literal once the marker was removed"; exit 1; }

tmp_offenders=""
for f in tests/*/test.sh; do
  [ "$f" = "tests/lib/test.sh" ] && continue
  hits=$(literal_tmp_paths "$f")
  [ -n "$hits" ] && tmp_offenders="$tmp_offenders
$hits"
done
if [ -n "$tmp_offenders" ]; then
  echo "FAIL: these lines write a literal /tmp/… path — move it into kit_scratch, or mark the line"
  echo "      'tmp-lint:allow' with a reason if it is deliberate:$tmp_offenders"
  exit 1
fi
echo "  [13] no suite writes an un-exempted literal /tmp/… path"

# ---------------------------------------------------------------------------
# 14. The handler runs in the shell that armed it, and in no forked child of it.
# ---------------------------------------------------------------------------
# The watchdog shape `( sleep N; kill "$pid" ) &` followed at once by `kill "$dog"`: a SIGTERM that
# lands between the fork and bash resetting the child's traps runs the PARENT's EXIT trap in the
# child. Before the owner check, that removed the suite's whole scratch tree mid-run — measured on
# tests/plan-freshness C20 under load, and at round 16 of a 300-round fork-then-kill loop.
#
# Driven deterministically rather than by racing a signal: the handler is CALLED in a subshell,
# which is exactly the state the race produces (same function, different process). The tree must
# survive it, and the subshell must still leave with its own status. bash 3.2 has no BASHPID, so
# the owner check is skipped there by design and this case has nothing to assert.
if [ -n "${BASHPID:-}" ]; then
  r=$(run_suite '
s=$(kit_scratch)
: > "$s/evidence"
sub=0
( kit_cleanup ) || sub=$?
[ -f "$s/evidence" ] && echo "SCRATCH-SURVIVED sub=$sub" || echo "SCRATCH-GONE sub=$sub"
')
  case "$r" in
    0\|*"SCRATCH-SURVIVED sub=0"*) : ;;
    *) echo "FAIL: kit_cleanup run in a forked child removed the scratch tree or changed the status: $r"; exit 1 ;;
  esac
  # And the owner itself still cleans up: the check must not turn the handler off altogether.
  r=$(run_suite 's=$(kit_scratch); echo "TMP=$KIT_LIB_TMP"')
  tmp_dir=${r#*TMP=}
  [ -n "$tmp_dir" ] && [ ! -e "$tmp_dir" ] || {
    echo "FAIL: the owning shell no longer removes its scratch tree at exit: $r"; exit 1; }
fi
echo "  [14] the handler run in a forked child leaves the scratch tree alone; the owner still removes it"

echo "tests/_lib.sh golden test OK"
