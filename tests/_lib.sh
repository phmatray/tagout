#!/usr/bin/env bash
# tests/_lib.sh — the golden suites' shared preamble. SOURCED, never executed.
#
# Why this file exists (#72). Ten suites each carried their own scratch directory, their own EXIT
# trap and their own copy of the samples/ immutability check — including their own restatement of
# the invariant that `local rc=$?` must be the FIRST statement in the handler. Anything before it
# overwrites the status being reported, which turns a failing suite into a silent green: the one
# outcome worse than a red one.
#
# That is the same hazard tests/xunit-v3/test.sh §8 was written to prevent for the importlib
# loader — an invisible, load-bearing prefix that a copy-paste drops with no symptom — applied to
# the trap handler instead. #42 gave the loader one home; this gives the trap one.
#
# They had already diverged before this landed, which is the usual first sign. The issue counted
# three; a survey found EIGHT; the anti-recurrence check in tests/lib/test.sh then found two more
# that spell the trap as a one-liner. Measured on the four that carried a full `cleanup()`:
#
#     suite              scratch      samples/ check   __pycache__   other
#     audit-inventory    $scratch     yes              no (argued)   —
#     ci-template        $scratch     yes              no            hashes the template
#     renovate-config    $scratch     NO               no            —
#     xunit-v3           ${scratch:-} yes              yes           —
#
# Three spellings of one check, one suite silently missing it, and two spellings of the same
# guard against an unset variable.
#
# ---------------------------------------------------------------------------------- the contract
#
#   kit_source <path>
#       Load another shared helper, or stop the suite NAMING the file it could not load. What it
#       refuses over, and what it cannot, are different lists — and the second one is written down
#       because a docstring promising prevention the code does not perform is worse than no
#       docstring: it is what stops the next reader from adding the check that is missing.
#
#       REFUSES, by name, before the helper can affect the suite:
#         * a path it cannot read;
#         * a path that does not PARSE (`bash -n`), which is what an edit that drops a `fi`, a
#           quote or a brace produces. Bare `. broken.sh` dies inside the source with bash's own
#           `syntax error near unexpected token` and no mention of the helper — measured on bash
#           3.2, exit 2, with the `||` branch never reached — and, because source executes a file
#           as it parses it, only AFTER the helper's earlier top-level commands have run. Both are
#           why the guard has to sit before the source rather than after it.
#
#       DOES NOT prevent, and cannot from here:
#         * a helper whose top level FAILS while executing. Under the caller's `set -e` the shell
#           dies inside the source (measured: exit 1, `||` branch never runs), so the suite stops —
#           loudly, but without kit_source naming the file. Stopping is the safe half; the missing
#           name is the cost.
#         * a helper whose failing command sits in an errexit-exempt context (`if`, `&&`, `||`).
#           The source returns 0, kit_source returns 0, and the suite proceeds with the helper only
#           PARTIALLY loaded — the "runs with half its assertions missing" outcome this helper is
#           otherwise about. Nothing at this level can see it; the failure surfaces later as
#           `<helper-function>: command not found`. §11 pins the paths that ARE guarded so this
#           list cannot quietly grow.
#
#       The FIRST shared file a suite loads is still sourced explicitly — this function lives in
#       one of them, so it cannot load the file that defines it. That bootstrap line is the only
#       one; every source after it is a single call (#128).
#
#   kit_init <kit-root>
#       Arm the EXIT trap. Call once, after the suite's `cd` to the kit root, before any work.
#
#   kit_scratch
#       Print a fresh scratch directory, removed at exit. Call as often as needed, including from
#       a command substitution — see kit_init for why that is not the trap it looks like.
#
#   kit_guard <function-name>
#       Register an extra assertion to run at exit, after the scratch dirs are removed. The
#       function prints its own FAIL message and returns non-zero to fail the run. This is how a
#       suite adds what only it cares about — the template hash, the __pycache__ check — WITHOUT
#       re-implementing the handler around it.
#
#   kit_guard_samples_unchanged
#       The check every suite that builds anything wants: samples/ must come out untouched. Not
#       registered automatically — a suite says so, because "forgot to call it" and "decided it
#       does not apply" must not look the same. That ambiguity is exactly how renovate-config ended
#       up without it.
#
#   first_match <find-args…>
#       Print the FIRST matching path, or nothing — and say why, when there is a reason worth
#       hearing:
#
#           case                     stdout       stderr               exit
#           a match exists           first path   —                    0
#           path exists, no match    (empty)      —                    0
#           starting path absent     (empty)      —                    0
#           any other find failure   (empty)      find's own message   0
#
#       Exit status is ALWAYS 0, on every row. Callers assign in a bare `x=$(first_match …)` under
#       `set -e`, where a non-zero status aborts the caller AT the assignment — before the caller's
#       own "…but it was empty" diagnostic can run (#98). The signal is the stderr, never the
#       status.
#
#       Row 3 is that tolerance, and it stays exactly as quiet as it was: any_match is registered
#       from kit_guard, so a complaint about a legitimately-absent path would print on EVERY exit
#       path, including the successful one. Row 4 is what #124 took back. `2>/dev/null` used to
#       cover it too, so a typo'd predicate or an unreadable directory came back empty and silent,
#       indistinguishable from "no match" — and the caller's diagnostic then sent the reader to
#       investigate the step that was supposed to produce the file. The emptiness test written
#       beneath each call site is only a test if empty means one thing.
#
#       `-quit` stops the walk at the first hit, so what this reports is what the probe SAW before
#       stopping, not a whole-tree verdict: a later unreadable directory may never be visited.
#
#   kit_find_err_is_absent_path_only <stderr-text>
#       True when EVERY line of that text is find's "that starting path is not there" complaint —
#       the one failure first_match suppresses. Split out and named so tests/lib/test.sh can drive
#       it on the wordings a given host cannot produce: BSD, GNU (whose quoting varies with the
#       locale), busybox and bfs each phrase it differently, and a rule verified on one platform's
#       string can lapse silently on another — permissively, re-opening the noise, or strictly,
#       restoring the silence #124 removed.
#
#       What it CANNOT tell apart, and no text rule can: a `-exec`'d command that does not exist.
#       GNU find reports that as `find: 'cmd': No such file or directory` — byte-identical to the
#       complaint about an absent starting path — so it would be suppressed. No call site in this
#       repo passes `-exec` (they are all `-name`/`-type`/`-path` probes), and one that needs to
#       must not read its verdict out of this helper. Written down rather than left to be
#       rediscovered, per the same argument kit_source's contract makes about its own residue.
#
#   any_match <find-args…>
#       The same search read as a yes/no question, without tripping SIGPIPE.
#       `find … | grep -q .` exits 141 under `pipefail` when grep closes the pipe early, and the
#       caller's `if` then reads the failure as "found nothing" — an intermittently disabled
#       guard (#48). Defined in terms of first_match: one home for the tolerance, too.
#
# There is deliberately no `set -euo pipefail` here: the callers set it, and re-setting it in a
# sourced file would mean this file silently decides the shell options of every suite that loads it
# (the reason skills/implement-issue/scripts/_assert-branch.sh gives for the same omission).

KIT_LIB_ROOT=""
KIT_LIB_TMP=""
KIT_LIB_GUARDS=()

kit_source() {
  # NOT named `f`. bash is dynamically scoped, so this local is in scope while the helper below is
  # sourced: a helper assigning a top-level global of the same name would write THIS variable
  # instead, the value would evaporate when kit_source returned, and kit_source's own error message
  # would then quote whatever the helper had put there rather than the path it was given. `f` is
  # the likeliest name for that collision — it is what every loop in this repo calls its file — so
  # the prefix is the point, not the length.
  local _kit_src_path="${1:?kit_source needs a path}"
  local _kit_src_err
  # Readability is checked BEFORE the source, and separately from it, so the two failures do not
  # get one message. `. missing.sh` under `set -e` aborts with bash's own line-number complaint and
  # nothing about which helper or why; a suite that stops without naming the file it wanted is a
  # CI-only failure nobody can diagnose at a distance (#74).
  [ -r "$_kit_src_path" ] || {
    echo "FAIL: cannot read $_kit_src_path — refusing to run unguarded"
    echo "      A suite that loses a shared helper loses its assertions with it, and would then"
    echo "      report OK having checked nothing."
    exit 1
  }
  # Parse BEFORE sourcing, in a child shell, because the `|| {` below cannot catch a syntax error:
  # bash aborts inside the source itself (measured on 3.2 — exit 2, the branch never runs). Worse
  # than the missing name is WHERE it dies: `source` executes a file as it parses it, so with the
  # error halfway down, the helper's earlier top-level commands have already taken effect and the
  # suite is left in a state nobody wrote down. `-n` only parses; nothing in the helper runs here.
  #
  # `${BASH:-bash}` and not a bare `bash`: the parse must be done by the interpreter that is about
  # to source the file, not by whatever `bash` PATH resolves to. This repo runs its suites under
  # macOS's bash 3.2 AND under a modern bash, and the two do not accept exactly the same grammar —
  # checking with the wrong one would either miss a real error or invent one.
  #
  # Captured with `if !` rather than `|| { … }`: the failing branch has to quote bash's own message,
  # and re-running the parse to obtain it would be a second, separately-failing pipeline inside a
  # block where errexit is live — which would replace this function's exit status with the parser's.
  if ! _kit_src_err=$("${BASH:-bash}" -n "$_kit_src_path" 2>&1); then
    echo "FAIL: $_kit_src_path does not parse — refusing to run unguarded"
    echo "      Sourcing it would abort the suite partway through the helper, with bash's own"
    echo "      syntax error and no mention of which file caused it:"
    printf '%s\n' "$_kit_src_err" | sed 's/^/        /'
    exit 1
  fi
  # shellcheck source=/dev/null
  . "$_kit_src_path" || {
    # Reachable only when the helper's LAST command returns non-zero from an errexit-exempt
    # position; a top-level failure kills the shell before this runs. See the contract above —
    # this branch is the tail of the guarantee, not the whole of it.
    echo "FAIL: $_kit_src_path was read but failed to load — refusing to run unguarded"
    exit 1
  }
}

kit_init() {
  KIT_LIB_ROOT="${1:?kit_init needs the kit root}"
  # ONE parent directory, created here, removed whole at exit. Every scratch dir is a child of it.
  #
  # The obvious design — `kit_scratch` appends to an array — is broken in a way that is invisible
  # at the call site: suites write `s=$(kit_scratch)`, and command substitution runs the function
  # in a SUBSHELL, so the append lands in a copy of the array that dies with it. The parent never
  # learns the directory exists and never removes it. Caught by tests/lib/test.sh section 2 the
  # first time it ran; a suite would only ever have shown it as a slow leak of /tmp entries.
  #
  # A parent directory has no such failure mode: the child is created inside a path the parent
  # already knows, so nothing has to be communicated back out of the subshell.
  # A caller-supplied root replaces what used to be a hardcoded `git -C "$KIT"` per suite, so a
  # wrong argument now silently disables every guard that depends on it. Prove it is a repository
  # here, once, loudly — rather than letting kit_guard_samples_unchanged report "clean" about a
  # directory it never measured.
  if ! git -C "$KIT_LIB_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
    echo "FAIL: kit_init was given '$KIT_LIB_ROOT', which is not a git repository."
    echo "      The samples/ guard would then report clean without measuring anything."
    exit 1
  fi
  # Trap FIRST, then the probe: the probe can exit 1, and a directory created before the handler is
  # armed is stranded on the one path that is meant to be loud — eight suites' worth per CI run.
  # Who armed the handler — see kit_cleanup for the forked child this is compared against. Empty on
  # bash 3.2, which has no BASHPID; the comparison is then skipped and the handler behaves as before.
  KIT_LIB_OWNER="${BASHPID:-}"
  trap kit_cleanup EXIT
  KIT_LIB_TMP=$(mktemp -d)
  kit_require_find_quit
}

kit_scratch() {
  mktemp -d "${KIT_LIB_TMP:?kit_scratch called before kit_init}/scratch.XXXXXX"
}

kit_guard() {
  KIT_LIB_GUARDS+=("${1:?kit_guard needs a function name}")
}

# kit_skill_prose <kit-root> <skill> — print the path of a scratch file holding the skill's WHOLE
# prose: SKILL.md followed by references/steps/*.md in order. A skill split for progressive
# disclosure (#499) keeps only its router in SKILL.md and one file per `## Step N`; a suite that
# pins a step's wording reads this assembly, so the pin survives the split and a step file that
# goes missing fails the assertion the same way a deleted paragraph would.
kit_skill_prose() {
  local root="${1:?kit_skill_prose needs the kit root}" skill="${2:?kit_skill_prose needs a skill}" out
  out="$(kit_scratch)/$skill-prose.md"
  cat "$root/skills/$skill/SKILL.md" > "$out"
  if [ -d "$root/skills/$skill/references/steps" ]; then
    local f
    for f in "$root/skills/$skill/references/steps/"*.md; do
      [ -f "$f" ] || continue
      printf '\n' >> "$out"; cat "$f" >> "$out"
    done
  fi
  printf '%s\n' "$out"
}

kit_cleanup() {
  # FIRST statement, always. A `rm`, an `echo`, even a `local d` with a command substitution in it
  # would replace the status this handler exists to report.
  local rc=$?
  local g failed=0
  # Only the shell that armed this handler may run it. A forked child — `( sleep 10; kill "$pid" ) &`,
  # the watchdog shape — still carries the parent's EXIT trap for the instant between the fork and
  # bash resetting it, and a SIGTERM landing in that instant runs THIS handler in the child: the
  # suite's whole scratch tree is removed while the suite is still using it. Measured on
  # tests/plan-freshness case C20 (the case whose script exits soonest, so its watchdog is killed
  # soonest): `out.txt: No such file or directory`, 1 of 10 runs of the whole plan at 8 jobs, and
  # 128 of 300 on a bare fork-then-kill loop under bash 5.2.
  if [ -n "${BASHPID:-}" ] && [ -n "${KIT_LIB_OWNER:-}" ] && [ "$BASHPID" != "$KIT_LIB_OWNER" ]; then
    exit "$rc"
  fi
  [ -n "$KIT_LIB_TMP" ] && rm -rf "$KIT_LIB_TMP"
  # EVERY guard runs, then the status is decided. Exiting on the first failure hides the rest: with
  # ci-template's two guards registered in the order samples-then-template, a run that damaged BOTH
  # printed only the samples message and never named the template — the reverse of what the inline
  # handler this replaced used to report.
  for g in ${KIT_LIB_GUARDS+"${KIT_LIB_GUARDS[@]}"}; do
    "$g" || failed=1
  done
  [ "$failed" -eq 0 ] || exit 1
  exit "$rc"
}

kit_guard_samples_unchanged() {
  local dirty
  dirty=$(git -C "$KIT_LIB_ROOT" status --porcelain -- samples/ 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    echo "FAIL: the committed fixture was mutated — a suite must not write to samples/:"
    echo "$dirty"
    return 1
  fi
}

kit_find_err_is_absent_path_only() {
  local _kit_fe_line
  # PER LINE, never on the text as a whole. find keeps going after a starting path it cannot open,
  # so one capture can hold an absent-path complaint AND a real failure at once — measured: with
  # `find /nope /good -name x -print -quit`, /nope's complaint and /good's hit both arrive. A
  # whole-string test matches the first phrase it sees and suppresses the pair, which is the exact
  # silence #124 exists to remove, reintroduced one level down.
  #
  # A here-STRING, not a here-doc: `<<EOF` re-expands its body, so a find message containing `$` or
  # a backtick — an unreadable path is allowed to have either — would be run as code. `<<<` expands
  # the word once, to the value it already holds, and never again.
  while IFS= read -r _kit_fe_line; do
    [ -n "$_kit_fe_line" ] || continue
    case "$_kit_fe_line" in
      # The phrase, ANCHORED AT THE END of the line. Everything to its left is the part that varies
      # — BSD writes `find: /nope: No such file or directory`, GNU quotes the path (with `'` under
      # C, with typographic quotes under a UTF-8 locale), bfs prefixes its own name — so keying on
      # any of it is how the rule lapses on somebody else's host. The `.` alternative is bfs, the
      # one implementation that punctuates.
      #
      # Unanchored (`*"…"*`) it also swallowed a DIFFERENT error about a path whose own name ends
      # in the phrase — `find: /x/No such file or directory: Permission denied`. Contrived, but the
      # anchor costs nothing and the two failure directions are not symmetric: a variant this rule
      # stops recognising prints one line per probe, which someone notices on the next clean run,
      # whereas a real failure it swallows is the silence #124 exists to remove and nobody ever
      # sees it. When in doubt, be loud.
      *"No such file or directory"|*"No such file or directory".) ;;
      *) return 1 ;;
    esac
  done <<< "${1:-}"
  return 0
}

first_match() {
  # `-print -quit` rather than a pipe: find stops itself on the first hit, so nothing can close the
  # pipe under it — the defect #48 pinned, where a SIGPIPE'd find returned 141 and `pipefail`
  # promoted that to the pipeline's status, making "found something" read as "found nothing".
  #
  # Discarding find's STATUS is load-bearing, not sloppiness: find exits non-zero on a path that
  # legitimately does not exist, and a bare `x=$(find missing …)` under `set -e` aborts the caller
  # AT the assignment. Two call sites in tests/xunit-v3/test.sh spelled the search out inline
  # without that tolerance, so the `[ -n "$x" ] || { echo FAIL; tail -20 "$log"; }` written directly
  # beneath each one could never run (#98). For a probe called from a guard registered with
  # kit_guard it is worse still, since the abort lands on EVERY exit path, including the successful
  # one. And the status could not be read even in principle: with several starting paths, find exits
  # 1 for the absent one while printing a real hit from another — measured.
  #
  # What is NOT discarded any more is find's stderr (#124). `2>/dev/null` covered every failure
  # mode, not just the missing start path, so a typo'd predicate or an unreadable directory came
  # back empty and quiet — and the caller's "…but it was empty" diagnostic then accused whatever it
  # was written to accuse, sending the reader to investigate a healthy step. So: capture it, stay
  # silent for the one case the tolerance was written for, re-emit anything else.
  local _kit_fm_err
  # stdout passes STRAIGHT THROUGH to the caller rather than being captured and re-printed: fd 3 is
  # this function's own stdout, which for the `x=$(first_match …)` call shape is the capture pipe.
  # Only stderr is held back for inspection, so nothing rewrites the one stream the contract is
  # about — and there is no temp file, hence nothing to clean up and no dependency on kit_init
  # having run (tests/lib/test.sh sources this file without arming the trap, on purpose).
  #
  # The `|| true` sits on the ASSIGNMENT, which is where errexit would otherwise fire.
  #
  # LC_ALL=C because the classifier below reads find's message text and GNU findutils translates
  # it. On a French host the not-found complaint would stop matching and every clean run of every
  # kit_guard would start printing it — this tolerance defeated by the environment rather than by
  # any change to the code.
  { _kit_fm_err=$(LC_ALL=C find "$@" -print -quit 2>&1 1>&3) || true; } 3>&1
  if [ -n "$_kit_fm_err" ] && ! kit_find_err_is_absent_path_only "$_kit_fm_err"; then
    # The WHOLE capture, not the offending lines alone: when one of several starting paths is also
    # absent, its complaint is the context that lets the reader place the real one.
    printf '%s\n' "$_kit_fm_err" >&2
  fi
  # Explicit, because "always 0" is the contract and not an accident of what the `if` above happens
  # to return when its condition is false.
  return 0
}

any_match() {
  # "Is there at least one?" is the same search read as a yes/no, so it is the same code rather
  # than a second copy of the tolerance above — the one-home argument of #48 applied to its own
  # other half (#98). The answer comes from the OUTPUT being non-empty and never from an exit
  # status: first_match discards find's status deliberately, which is exactly what stops a reader's
  # early exit — the SIGPIPE 141 of #48 — from ever being read back as "found nothing".
  [ -n "$(first_match "$@")" ]
}

kit_require_find_quit() {
  # `-print -quit` is what makes first_match safe, so prove this host's find HAS it — once, loudly.
  # Otherwise the discarded STATUS above cuts both ways: on a find without `-quit` (busybox, some
  # minimal containers) every call answers "nothing found". A guard leaning on any_match then
  # reports clean from the very first exit path, which is what lets a stray .pyc reach the tree; and
  # a direct first_match caller is handed an empty string, so ITS diagnostic goes on to accuse the
  # step that was supposed to produce the file. #124 means the complaint is now re-emitted rather
  # than swallowed — it is not an absent starting path — but that turns one silent wrong answer into
  # a line of noise on every single probe, which is a worse way to learn this than being told here.
  if ! find "${KIT_LIB_ROOT:-.}" -maxdepth 0 -print -quit >/dev/null 2>&1; then
    echo "FAIL: this host's find does not support '-print -quit', which first_match depends on."
    echo "      Every first_match() call — and so every any_match() call — would answer 'nothing"
    echo "      found' regardless of what is there."
    exit 1
  fi
}
