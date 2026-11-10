#!/usr/bin/env bash
# Golden test for scripts/sigpipe-idiom-check.py -- the gate that refuses a positive-match
# `grep -q` fed by a streaming external producer under `pipefail` (#391).
#
# What this suite guards, one fixture file per case:
#   a. an awk RANGE piped into a positive grep -q         -> REFUSED, naming file:line + remedy
#   b. a printf (builtin, one small write) producer        -> accept -- printf cannot race
#   c. `if ! find … | grep -q .; then` (bang-negated)      -> accept -- non-match is the outcome
#   d. the offending shape, but commented out              -> accept
#   e. the offending shape, tagged sigpipe-repro           -> accept
#   f. `grep -v … | grep -qF x` (grep feeding grep)        -> REFUSED -- grep is a producer too
#   g. `grep -q x <<<"$(awk …)"` -- a substitution, not a pipe -> accept, nothing to race
#   h. `|| true` / `|| :` discards the pipeline's status   -> accept
#   i. `find … | grep -q .` present under BOTH tests/ and scripts/ -> both REFUSED
#   j. a clean tree (no offending files at all)            -> exit 0, silent
#   k. a directory that does not exist                     -> exit 2, no verdict
#   l. a pipeline spanning a `\` line continuation          -> REFUSED, on the grep -q line
#   m. a `sudo` prefix on the producer                      -> REFUSED (#457)
#   n. an `env VAR=val` prefix on the producer               -> REFUSED (#457)
#   o. the offending shape inside a `$(...)` substitution    -> REFUSED (#457)
#   p. the offending shape inside a NESTED `$(...)`          -> REFUSED (#457)
#   q. `sudo -u user env VAR=val <producer>`                 -> REFUSED, flags stripped too (#457)
#   r. a `$(...)` after an earlier double-quoted apostrophe  -> REFUSED, not swallowed (#457)
#   s. a quoted `)` inside a `$(...)` span                   -> REFUSED, span not truncated (#457)
#
# Sections are labelled, never fractioned -- a denominator goes stale the moment a case is added.
#
# Fixture files live under a `.git`-free scratch directory, so the checker exercises its plain
# directory-walk fallback (the golden-suite path `pinned-literals-check.py`'s own suite also
# relies on) rather than `git ls-files` -- the same reason the real repo's own scan is proven
# separately, in Task 3, once real sites exist to prove it against.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO/scripts/sigpipe-idiom-check.py"
# Scratch dir and EXIT trap come from the shared preamble (#72).
. "$REPO/tests/_lib.sh" || {
  echo "FAIL: cannot source $REPO/tests/_lib.sh -- refusing to run unguarded"; exit 1; }
kit_init "$REPO"
WORK=$(kit_scratch)

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

if [ ! -f "$CHECK" ]; then
  echo "FAIL: $CHECK does not exist -- there is no guard to drive."
  exit 1
fi

scaffold() {
  rm -rf "$WORK/repo"
  mkdir -p "$WORK/repo/tests/fixture" "$WORK/repo/scripts"
}

run_check() { python3 "$CHECK" "$1" 2>&1; }

# --------------------------------------------------------------------------- a. awk range -> REFUSED
scaffold
printf '%s\n' "awk '/a/,/b/' f | grep -q x" > "$WORK/repo/tests/fixture/a.sh"
out=$(run_check "$WORK/repo"); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'tests/fixture/a.sh:1' \
   && printf '%s' "$out" | grep -qi 'herestring'; then
  ok "a. awk range piped into a positive grep -q -- REFUSED, naming the file:line and the remedy"
else
  bad "a. expected rc=1 naming tests/fixture/a.sh:1 and a herestring remedy, got rc=$rc:"
  printf '%s\n' "$out" | sed 's/^/        /'
fi

# --------------------------------------------------------------- b. printf producer -> REFUSE
scaffold
printf '%s\n' 'printf '"'"'%s'"'"' "$x" | grep -q y' > "$WORK/repo/tests/fixture/b.sh"
out=$(run_check "$WORK/repo"); rc=$?
# A builtin is NOT exempt. This case used to assert the opposite ("one small write, printf cannot
# race"); measured, bash's printf writes a multi-line value in several writes and loses the race
# like any external producer. The same line through a herestring is the accepted form.
[ "$rc" -eq 1 ] && grep -qF 'tests/fixture/b.sh:1' <<<"$out" \
  && ok "b. printf (a builtin) into grep -q -- refused, a multi-line printf races too" \
  || { bad "b. expected rc=1 naming tests/fixture/b.sh:1, got rc=$rc: $out"; }
scaffold
printf '%s\n' 'echo "$x" | grep -q y' > "$WORK/repo/tests/fixture/b2.sh"
out=$(run_check "$WORK/repo"); rc=$?
[ "$rc" -eq 1 ] && grep -qF 'tests/fixture/b2.sh:1' <<<"$out" \
  && ok "b2. echo into grep -q -- refused on the same terms" \
  || { bad "b2. expected rc=1 naming tests/fixture/b2.sh:1, got rc=$rc: $out"; }
scaffold
printf '%s\n' 'grep -q y <<<"$x"' > "$WORK/repo/tests/fixture/b3.sh"
out=$(run_check "$WORK/repo"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  && ok "b3. the herestring form of the same assertion -- accept" \
  || { bad "b3. expected rc=0, silent, got rc=$rc: $out"; }

# --------------------------------------------------------- c. bang-negated find -> accept
scaffold
printf '%s\n' 'if ! find . -name x | grep -q .; then' > "$WORK/repo/tests/fixture/c.sh"
out=$(run_check "$WORK/repo"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  && ok "c. if ! find … | grep -q . -- accept, non-match is the asserted outcome" \
  || { bad "c. expected rc=0, silent, got rc=$rc: $out"; }

# ------------------------------------------------------------------- d. commented out -> accept
scaffold
printf '%s\n' "# awk '/a/,/b/' f | grep -q x" > "$WORK/repo/tests/fixture/d.sh"
out=$(run_check "$WORK/repo"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  && ok "d. the offending shape, commented out -- accept" \
  || { bad "d. expected rc=0, silent, got rc=$rc: $out"; }

# --------------------------------------------------------- e. sigpipe-repro tagged -> accept
scaffold
printf '%s\n' "awk '/a/,/b/' f | grep -q x  # sigpipe-repro" > "$WORK/repo/tests/fixture/e.sh"
out=$(run_check "$WORK/repo"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  && ok "e. the offending shape, tagged sigpipe-repro -- accept" \
  || { bad "e. expected rc=0, silent, got rc=$rc: $out"; }

# ------------------------------------------------------- f. grep feeding grep -q -> REFUSED
scaffold
printf '%s\n' 'grep -v f | grep -qF x' > "$WORK/repo/tests/fixture/f.sh"
out=$(run_check "$WORK/repo"); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'tests/fixture/f.sh:1' \
  && ok "f. grep -v … | grep -qF x -- REFUSED, grep is itself a producer" \
  || { bad "f. expected rc=1 naming tests/fixture/f.sh:1, got rc=$rc: $out"; }

# --------------------------------------------------- g. command substitution, not a pipe -> accept
scaffold
printf '%s\n' 'grep -q x <<<"$(awk '"'"'/a/,/b/'"'"' f)"' > "$WORK/repo/tests/fixture/g.sh"
out=$(run_check "$WORK/repo"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  && ok "g. grep -q fed by \$(…) rather than a pipe -- accept, the substitution already completed" \
  || { bad "g. expected rc=0, silent, got rc=$rc: $out"; }

# ------------------------------------------------------- h. || true / || : -> accept
scaffold
printf '%s\n' "awk '/a/,/b/' f | grep -q x || true" > "$WORK/repo/tests/fixture/h1.sh"
printf '%s\n' "awk '/a/,/b/' f | grep -q x || :" > "$WORK/repo/tests/fixture/h2.sh"
out=$(run_check "$WORK/repo"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  && ok "h. || true / || : -- accept, the pipeline's status is discarded outright" \
  || { bad "h. expected rc=0, silent, got rc=$rc: $out"; }

# ------------------------------------ i0. a recipe in a skill reference, and a hook -> REFUSED
#
# skills/ and hooks/ are scan roots too: a fenced recipe an agent pastes races like a suite does.
scaffold
mkdir -p "$WORK/repo/skills/x/references" "$WORK/repo/hooks"
printf '%s\n' '```bash' 'git worktree list --porcelain | grep -Fxq "branch refs/heads/$BRANCH"' '```' \
  > "$WORK/repo/skills/x/references/recipe.md"
printf '%s\n' 'git status --porcelain | grep -q .' > "$WORK/repo/hooks/gate.sh"
out=$(run_check "$WORK/repo"); rc=$?
if [ "$rc" -eq 1 ] && grep -qF 'skills/x/references/recipe.md:2' <<<"$out" \
   && grep -qF 'hooks/gate.sh:1' <<<"$out"; then
  ok "i0. the shape in a skill's markdown recipe and in a hook -- REFUSED under skills/ and hooks/"
else
  bad "i0. expected rc=1 naming skills/x/references/recipe.md:2 and hooks/gate.sh:1, got rc=$rc: $out"
fi

# --------------------------------------------- i. find piped into grep -q, both scan roots
scaffold
printf '%s\n' 'find "$d" -name x | grep -q .' > "$WORK/repo/tests/fixture/i.sh"
printf '%s\n' 'find "$d" -name x | grep -q .' > "$WORK/repo/scripts/i.sh"
out=$(run_check "$WORK/repo"); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'tests/fixture/i.sh:1' \
   && printf '%s' "$out" | grep -qF 'scripts/i.sh:1'; then
  ok "i. find … | grep -q . -- REFUSED under BOTH tests/ and scripts/"
else
  bad "i. expected rc=1 naming both tests/fixture/i.sh:1 and scripts/i.sh:1, got rc=$rc:"
  printf '%s\n' "$out" | sed 's/^/        /'
fi

# ------------------------------------------------------------------------ j. clean tree -> accept
scaffold
out=$(run_check "$WORK/repo"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  && ok "j. a clean tree -- exit 0, silent" \
  || { bad "j. expected rc=0, silent, got rc=$rc: $out"; }

# ------------------------------------------------------------ k. nonexistent dir -> usage error
out=$(run_check "$WORK/does-not-exist"); rc=$?
[ "$rc" -eq 2 ] \
  && ok "k. a directory that does not exist -- exit 2, no verdict" \
  || { bad "k. expected rc=2, got rc=$rc: $out"; }

# ------------------------------------------- l. line continuation, joined before matching (#391)
# A physical-line-only scan misses this shape entirely: neither line alone carries both a
# producer and a `grep -q` — the reader is where the Spec says to report it (the line it sits on).
scaffold
printf '%s\n%s\n' "awk '/a/,/b/' f | \\" "  grep -q x" > "$WORK/repo/tests/fixture/l.sh"
out=$(run_check "$WORK/repo"); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'tests/fixture/l.sh:2' \
  && ok "l. a pipeline spanning a \\ line continuation -- REFUSED, on line 2 (the grep -q line)" \
  || { bad "l. expected rc=1 naming tests/fixture/l.sh:2, got rc=$rc: $out"; }

# --------------------------------------------------------- m. a sudo-prefixed producer -> REFUSED (#457)
scaffold
printf '%s\n' 'sudo find . -name x | grep -q y' > "$WORK/repo/tests/fixture/m.sh"
out=$(run_check "$WORK/repo"); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'tests/fixture/m.sh:1' \
  && ok "m. sudo find . -name x | grep -q y -- REFUSED, sudo is a transparent prefix (#457)" \
  || { bad "m. expected rc=1 naming tests/fixture/m.sh:1, got rc=$rc: $out"; }

# ---------------------------------------------------- n. an env VAR=val prefixed producer -> REFUSED (#457)
scaffold
printf '%s\n' 'env FOO=bar find . -name x | grep -q y' > "$WORK/repo/tests/fixture/n.sh"
out=$(run_check "$WORK/repo"); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'tests/fixture/n.sh:1' \
  && ok "n. env FOO=bar find . -name x | grep -q y -- REFUSED, env/VAR= is a transparent prefix (#457)" \
  || { bad "n. expected rc=1 naming tests/fixture/n.sh:1, got rc=$rc: $out"; }

# --------------------------------------------- o. the offending shape inside \$(...) -> REFUSED (#457)
scaffold
printf '%s\n' 'n=$(find . -name x | grep -q .)' > "$WORK/repo/tests/fixture/o.sh"
out=$(run_check "$WORK/repo"); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'tests/fixture/o.sh:1' \
  && ok "o. n=\$(find . -name x | grep -q .) -- REFUSED, a substitution is scanned, not opaque (#457)" \
  || { bad "o. expected rc=1 naming tests/fixture/o.sh:1, got rc=$rc: $out"; }

# ------------------------------------------- p. the offending shape inside a NESTED \$(...) -> REFUSED (#457)
scaffold
printf '%s\n' 'n=$(cmd1 $(find . -name x | grep -q .))' > "$WORK/repo/tests/fixture/p.sh"
out=$(run_check "$WORK/repo"); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'tests/fixture/p.sh:1' \
  && ok "p. nested \$(cmd1 \$(find … | grep -q .)) -- REFUSED, recursion has no depth limit (#457)" \
  || { bad "p. expected rc=1 naming tests/fixture/p.sh:1, got rc=$rc: $out"; }

# --------------------------------------- q. sudo with a flag before env -> REFUSED (#457)
scaffold
printf '%s\n' 'sudo -u user env VAR=val find . -name x | grep -q y' > "$WORK/repo/tests/fixture/q.sh"
out=$(run_check "$WORK/repo"); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'tests/fixture/q.sh:1' \
  && ok "q. sudo -u user env VAR=val find … | grep -q y -- REFUSED, sudo's own flags are stripped too (#457)" \
  || { bad "q. expected rc=1 naming tests/fixture/q.sh:1, got rc=$rc: $out"; }

# ------------------------------- r. a $(...) after an earlier double-quoted apostrophe -> REFUSED (#457)
scaffold
printf '%s\n' 'echo "don'"'"'t fail"; x=$(find . -name y | grep -q z)' > "$WORK/repo/tests/fixture/r.sh"
out=$(run_check "$WORK/repo"); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'tests/fixture/r.sh:1' \
  && ok "r. an earlier double-quoted apostrophe does not swallow the real \$(...) (#457)" \
  || { bad "r. expected rc=1 naming tests/fixture/r.sh:1, got rc=$rc: $out"; }

# ------------------------------------------- s. a quoted ) inside a \$(...) span -> REFUSED (#457)
scaffold
printf '%s\n' "x=\$(grep -q ')' file; find . -name y | grep -q z)" > "$WORK/repo/tests/fixture/s.sh"
out=$(run_check "$WORK/repo"); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'tests/fixture/s.sh:1' \
  && ok "s. a quoted ) inside \$(...) does not truncate the span early (#457)" \
  || { bad "s. expected rc=1 naming tests/fixture/s.sh:1, got rc=$rc: $out"; }

echo
if [ "$fails" -eq 0 ]; then
  echo "PASS: sigpipe-idiom-check.py"
  exit 0
else
  echo "FAIL: $fails case(s) failed"
  exit 1
fi
