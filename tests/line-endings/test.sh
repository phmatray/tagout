#!/usr/bin/env bash
# Golden test for the repo-root .gitattributes — the `eol=lf` rule the raw-line gates depend on
# (#174).
#
# Why this suite exists. Three of the kit's gates read their own repository line by line, and each
# one compares a raw line against a literal: parse-sweep.sh matches a heredoc terminator against the
# delimiter it captured, ci-wiring-check.py matches a suite path against the string a workflow
# spells. On a checkout whose working copy is CRLF — the default on Windows with `core.autocrlf=true`
# and no attribute to say otherwise — every one of those comparisons is against a line carrying a
# trailing CR, and the gates refuse a tree that is perfectly fine. Measured at ce23b73: 11 suites
# REFUSED by the sweep, 19 by the wiring check, on a tree CI was green on.
#
# The fix is not per-script CR tolerance — teaching parse-sweep to accept `PY\r` would make it AGREE
# with a file the bash 3.2 it emulates still chokes on. The fix is to remove the premise: pin the
# working copy to LF, for every checkout, in a committed file.
#
# What each section can go RED on, here on Linux, without a Windows host:
#   1. a blob committed with CRLF                    — the content half, which no checkout rule fixes
#   2. the eol attribute unset for a gate-read file  — RED today: there is no .gitattributes
#   3. .gitattributes untracked                      — a rule nobody inherits is not a rule
#   4. the rule failing to govern a real CHECKOUT    — a `core.autocrlf=true` fixture, which is
#                                                      reproducible on Linux and is exactly the
#                                                      Windows condition
#   5. the consequence, demonstrated                 — parse-sweep REFUSES a CRLF copy of a file it
#                                                      passes as LF, so the premise cannot rot into
#                                                      folklore
#
# Sections 1-3 assert the rule; 4 proves it does what it claims; 5 proves it is worth claiming.
# Section lines carry a label, never a fraction: a denominator goes stale the moment a section is
# added, and a stale one reads as a run that stopped early.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SWEEP="$REPO/scripts/parse-sweep.sh"

# Scratch dir and EXIT trap come from the shared preamble (#72). Sourced via $REPO, never $PWD:
# this suite does not cd, so it can be run from anywhere.
. "$REPO/tests/_lib.sh" || {
  echo "FAIL: cannot source $REPO/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$REPO"
WORK=$(kit_scratch)

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# A CR anywhere in the file. `grep $'\r'` is not portable to every grep the kit runs under, and a
# command substitution cannot carry a bare CR back reliably, so this asks awk.
has_cr() { LC_ALL=C awk '/\r/ { found = 1 } END { exit !found }' "$1"; }

# A scratch repo with an identity, so commits work under any ambient git config.
new_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name "Golden Test"
}

# ---------------------------------------------------------------- 1. no tracked blob carries CRLF
# The index is what every clone and CI checkout starts from. `.gitattributes` governs the working
# copy; it does not rewrite a blob already committed with CRLF, so this half has to be asserted
# separately — and it is the half that would survive `git add --renormalize .` being skipped.
crlf_blobs=$(git -C "$REPO" ls-files --eol | awk '$1 == "i/crlf" { print $NF }')
if [ -z "$crlf_blobs" ]; then
  ok "no tracked blob is stored with CRLF"
else
  bad "these blobs are stored with CRLF, so no checkout rule can save the gates: $crlf_blobs"
fi

# ------------------------------------------------ 2. the checkout rule is DECLARED, not inherited
# `git check-attr` answers `unspecified` when nothing declares the attribute — which is the state
# this suite was written red against. An answer of `lf` that came from a machine's `core.autocrlf`
# is not possible here: core.autocrlf is a config setting, not an attribute, so a passing verdict
# means a committed rule is doing the work.
#
# The list is the files the raw-line gates READ, plus this suite: it is the reason each one is
# named, and a reader adding a fourth raw-line gate should add it here.
for f in scripts/parse-sweep.sh \
         scripts/ci-wiring-check.py \
         scripts/worktrees-ignored.sh \
         .github/workflows/ci.yml \
         tests/line-endings/test.sh; do
  attr=$(git -C "$REPO" check-attr eol -- "$f" | sed 's/.*: //')
  if [ "$attr" = "lf" ]; then
    ok "eol=lf is declared for $f"
  else
    bad "the eol attribute for $f is '$attr', expected 'lf' — is there a .gitattributes?"
  fi
done

# ------------------------------------------------------------------- 3. the rule travels with git
# An untracked .gitattributes governs this checkout and nobody else's — the same distinction
# worktrees-ignored.sh draws between .gitignore and .git/info/exclude, and for the same reason:
# a caller may write the verdict down as a fact about the REPOSITORY.
if git -C "$REPO" ls-files --error-unmatch .gitattributes >/dev/null 2>&1; then
  ok ".gitattributes is tracked, so every clone inherits the rule"
else
  bad ".gitattributes is not tracked by git — the rule protects this checkout only"
fi

# ------------------------------------------------------- 4. the rule governs a real CHECKOUT (CRLF)
# The Windows condition, reproduced on Linux: `core.autocrlf=true` makes git write CRLF into the
# working copy on checkout while storing LF in the index — `i/lf w/crlf`, exactly what
# `git ls-files --eol` reported on the host in #174.
#
# Asserted as a PAIR, and the pair is the point. "the working copy came out LF" proves nothing on
# its own — it is also what a repo with autocrlf off would show — so the control comes first: the
# same repo, same setting, no .gitattributes, must come back CRLF. Only then does the second half
# mean the rule did the work.
r="$WORK/checkout"
new_repo "$r"
git -C "$r" config core.autocrlf true
printf 'line one\nline two\n' > "$r/f.sh"
# stderr is dropped for this ONE call: with core.autocrlf=true git prints "LF will be replaced by
# CRLF the next time Git touches it", which is the fixture working as designed and reads in the
# suite's output like a failure. Nothing else here is silenced.
git -C "$r" add f.sh 2>/dev/null
git -C "$r" commit -qm base

rm -f "$r/f.sh"
git -C "$r" checkout -q -- f.sh
if has_cr "$r/f.sh"; then
  ok "control — core.autocrlf=true really does check out CRLF on this host"

  if [ -f "$REPO/.gitattributes" ]; then
    cp "$REPO/.gitattributes" "$r/.gitattributes"
    git -C "$r" add .gitattributes
    git -C "$r" commit -qm attrs
    rm -f "$r/f.sh"
    git -C "$r" checkout -q -- f.sh
    if has_cr "$r/f.sh"; then
      bad "the kit's .gitattributes did not stop core.autocrlf=true from checking out CRLF"
    else
      ok "the kit's .gitattributes pins the working copy to LF against core.autocrlf=true"
    fi
  else
    bad "there is no .gitattributes at the repo root — nothing pins the working copy"
  fi
else
  bad "control invalid — core.autocrlf=true did not produce a CRLF working copy, so this"
  bad "  section cannot distinguish a working rule from an absent hazard"
fi

# --------------------------------------------------- 5. the consequence the rule exists to prevent
# Mechanism 1 of #174, reproduced here rather than described. The fixture is the shape the kit's
# suites are full of — a heredoc with a QUOTED delimiter opened inside a `$( … )`:
#
#     x=$(python3 - <<'PY'
#     print("ok")
#     PY
#     )
#
# The quoting matters. parse-sweep captures the delimiter by stripping to the closing quote, so it
# gets `PY`, while the terminator line on a CRLF copy is `PY` + CR. They never compare equal, the
# scan runs off the end of the file, and the sweep does what it is designed to do when a scan cannot
# complete: refuse, loudly. The refusal is correct behaviour on a false premise — which is why the
# fix is the premise, and why parse-sweep itself is deliberately NOT changed by #174.
lf_fixture="$WORK/lf-suite.sh"
crlf_fixture="$WORK/crlf-suite.sh"
printf '%s\n' "x=\$(python3 - <<'PY'" 'print("ok")' 'PY' ')' > "$lf_fixture"
LC_ALL=C awk '{ printf "%s\r\n", $0 }' "$lf_fixture" > "$crlf_fixture"

if has_cr "$crlf_fixture" && ! has_cr "$lf_fixture"; then
  bash "$SWEEP" "$lf_fixture" >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    out=$(bash "$SWEEP" "$crlf_fixture" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && grep -q 'never terminated' <<<"$out"; then
      ok "a CRLF working copy really does make parse-sweep refuse a file it passes as LF"
    else
      bad "the CRLF fixture was not refused (rc=$rc) — if parse-sweep learned CR tolerance, this"
      bad "  suite's premise is gone and #174's non-goal was reversed; check that deliberately"
    fi
  else
    bad "control invalid — the LF fixture does not pass the sweep, so a refusal proves nothing"
  fi
else
  bad "fixture bug — the CRLF/LF pair did not come out as intended"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "line-endings golden test: all sections passed."
else
  echo "line-endings golden test: $fails section(s) FAILED."
fi
exit $((fails > 0))
