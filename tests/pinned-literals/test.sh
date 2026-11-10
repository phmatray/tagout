#!/usr/bin/env bash
# Golden test for scripts/pinned-literals-check.py — the guard that every spelling of the pinned
# xunit.v3 version is either MARKED as derived from the constant, or RECORDED as historical (#90).
#
# What this suite guards:
#   0. the baseline fixture is genuinely accounted for   -> accept (every mutation below is of it)
#   1. a new copy, neither marked nor recorded           -> REFUSE, naming file:line
#   2. a marked line stating a stale version             -> REFUSE, and never "edit the number"
#   3. a historical line is ignored BECAUSE of its entry -> break the anchor and it refuses
#   4. a HISTORICAL entry that matches nothing           -> REFUSE (a stale allowlist entry lies)
#  4a. a HISTORICAL entry whose anchor still matches,    -> REFUSE, told to RE-MEASURE — never told
#      but the version differs (a legitimate bump)          to re-point or delete a line that is
#                                                            still there
#   5. a HISTORICAL entry covering two lines             -> REFUSE (an over-broad anchor)
#   6. a marker on a line that states no claim           -> REFUSE (it verifies nothing)
#   7. an EXCLUDED path spelling the pin                 -> REFUSE (a copy nothing else looks at)
#   8. no occurrence and no marker anywhere              -> REFUSE rather than pass vacuously
#   9. a directory with no files at all                  -> exit 2, no verdict, never a pass
#  9b. the constant defined more than once               -> exit 2, no verdict, never a guess
#  10. the REAL repository                               -> accept
#  11. a claim wrapped across two physical lines          -> REFUSE, naming the FIRST line, not the 2nd
#  12. a marker on line N does not launder line N+1's own -> both lines refused, independently
#  14. an AGREED pin, two marked occurrences that agree   -> accept
#  15. an AGREED pin, two marked occurrences that disagree -> REFUSE, naming every value seen
#  16. an AGREED pin, exactly one marked occurrence        -> REFUSE (an agreement of one is vacuous)
# 16b. one marked line stating two different values        -> REFUSE on its own, not folded into a
#                                                              disagreement across two occurrences
#  17. an AGREED pin's witness (frozen file, never marked) -> agrees: accept; disagrees: REFUSE,
#                                                              naming it; absent: skipped gracefully
#  18. the check driven to red — mutations, each of which must silence exactly one case above
#
# The refusal cases are the point. #69's `[7e]` sweep covered two files and said, in the issue it
# spawned, that the rest needed a policy rather than a wider regex — and the hazard in getting that
# policy wrong is not a missed copy but a WRONG EDIT: sweeping the deliberately-historical
# `xunit.v3.mtp-v2` enumerations into agreement destroys the distinction MTP_LINE encodes, and
# deriving the scratch .csproj fixture from the constant makes the transform test assert against
# its own output. So both directions are driven here, over fixtures.
#
# ⚠️ The fixtures pin a FAKE version (see $FAKE below), never the repo's real one. A suite that
# spelled the real pin would itself become an unmarked copy — and the check would be right to
# refuse it. It is also why scripts/pinned-literals-check.py excludes this directory, and why
# section 7 proves that exclusion cannot hide a real copy.
#
# Section lines carry a label, never a fraction: a denominator goes stale the moment a section is
# added, and a stale one reads as a run that stopped early.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO/scripts/pinned-literals-check.py"
# Scratch dir and EXIT trap come from the shared preamble (#72). Sourced via $REPO, never $PWD:
# this suite does not cd, and an empty $WORK would resolve every fixture path against / .
. "$REPO/tests/_lib.sh" || {
  echo "FAIL: cannot source $REPO/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$REPO"
kit_guard kit_guard_samples_unchanged
WORK=$(kit_scratch)

fails=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

if [ ! -f "$CHECK" ]; then
  echo "FAIL: $CHECK does not exist — there is no guard to drive."
  exit 1
fi

# The fixtures' pin. Deliberately NOT the repo's real version: see the header.
FAKE=9.9.9
# #158: a second fake, for decorative text that mentions the coverage-ext pin's PACKAGE without
# governing it (this suite tests xunit-v3 only) — spelling the real coverage-ext VERSION here would
# make this EXCLUDED directory a copy of that pin the moment it exists in PINS.
FAKE_COVERAGE=8.8.8
# #158: a third fake, for the frozen-fixture-trio AGREED pins' baseline occurrences. Distinct from
# both $FAKE and $FAKE_COVERAGE: the xunit-v3 pin's literal scan flags ANY unmarked line spelling
# ITS version, regardless of what package name sits near it — reusing $FAKE here would make every
# AGREED-trio line an unmarked xunit-v3 copy too.
FAKE_FROZEN=7.7.7

# Run a checker over a scratch repo; echo its output, return its status. The checker is a
# parameter so section 11 can drive a MUTATED copy through the very same cases.
run_with() { python3 "$1" --repo "$2" 2>&1; }
run_check() { run_with "$CHECK" "$1"; }

# Rewrite one line of a fixture file. `sed -i` is spelled differently on BSD and GNU, so this
# writes a sibling and moves it — the portable form, and the one that fails loudly on a bad path.
rewrite() {
  local file="$1" expr="$2"
  sed "$expr" "$file" > "$file.new" && mv "$file.new" "$file"
}

# --------------------------------------------------------------------------------- the baseline
#
# A miniature repo that is fully accounted for: the constant's own module, one marked line per
# scanned file, and a line for EVERY entry in the check's HISTORICAL table — because those entries
# name real paths and anchors, and an entry that matches nothing is itself a refusal. Building the
# baseline out of the real anchors is deliberate: it means these fixtures exercise the shipped
# table rather than a parallel one that could drift away from it.
scaffold() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root/tests/xunit-v3" "$root/skills/migrate-legacy/references" "$root/templates"

  cat > "$root/tests/xunit-v3/apply-transform.py" <<PY
# The module that DEFINES the pin. Its own definition line is the source, not a copy.
#
#   xunit.v3        $FAKE -> xunit.v3.mtp-v1      -> Microsoft.Testing.Platform 1.9.1  # pinned:xunit-v3
#   xunit.v3.mtp-v2 $FAKE -> xunit.v3.core.mtp-v2 -> Microsoft.Testing.Platform 2.0.2
#
# Both are the same major, and \`xunit.v3.mtp-v2\` $FAKE are STABLE releases — so a map keyed on
# the major is inverted (measured from xunit.v3.core.mtp-v{1,2} $FAKE's nuspecs).
XUNIT_V3_PACKAGE = "xunit.v3"
XUNIT_V3_VERSION = "$FAKE"

# #158: a second, unrelated DERIVED pin in the same module — coverage-widget $FAKE_COVERAGE  # pinned:coverage-ext
COVERAGE_PACKAGE = "coverage-widget"
COVERAGE_EXT_VERSION = "$FAKE_COVERAGE"

# Floating ($FAKE_COVERAGE.*) and build metadata ($FAKE_COVERAGE+build) are accepted deliberately —
# an ILLUSTRATION mirroring the real module's VERSION_RE comment, not a claim about the constant.
# Major as an INT: '0$FAKE_COVERAGE' and '$FAKE_COVERAGE' are the same line — mirrors the real
# module's leading-zero-parsing docstring, same reason.


def validate_pairing(xunit_package, version):
    # an older positional call would refuse a correct pair naming "$FAKE" as the serving package
    # — the slot is the point, not the number.
    return xunit_package, version
PY

  cat > "$root/templates/ci-dotnet.yml" <<YML
# A measurement banner using the short alias — mirrors templates/ci-dotnet.yml's real one.
#   (SDK 10.0.302, xunit.v3 $FAKE, CodeCoverage $FAKE_COVERAGE) :   # pinned:xunit-v3
YML

  cat > "$root/tests/xunit-v3/test.sh" <<SH
#!/usr/bin/env bash
#     Measured (SDK 10.0.302, xunit.v3 $FAKE, CodeCoverage $FAKE_COVERAGE):  # pinned:xunit-v3
#
# Keyed on the package ID (measured: xunit.v3 $FAKE -> MTP 1.9.1,  # pinned:xunit-v3
# xunit.v3.mtp-v2 $FAKE -> MTP 2.0.2), so a version-keyed map would invert every pair below.
cat > "\$scratch/helper.csproj" <<XML
<Project Sdk="Microsoft.NET.Sdk">
  <ItemGroup>
    <PackageReference Include="xunit.v3" Version="$FAKE" />
  </ItemGroup>
</Project>
XML

# #158: one restatement of the fixture's own frozen-style trio (AGREED, no source of truth) — the
# other restatement lives in xunit-v3-migration.md below.
# xunit $FAKE_FROZEN, xunit.runner.visualstudio $FAKE_FROZEN, Microsoft.NET.Test.Sdk $FAKE_FROZEN.  # agreed:frozen-xunit-core agreed:frozen-xunit-runner agreed:frozen-test-sdk

# Test-literal lines mirroring the real section 7's pairing calls — an ILLUSTRATION exercising
# validate_pairing(), not a measurement claim (same reason as apply-transform.py's two above). The
# anchors below match on the PACKAGE's real full id text (not this fixture's fake VERSION), the
# same way scripts/pinned-literals-check.py's own shipped HISTORICAL table does.
# mod.validate_pairing("xunit.v3", "$FAKE_COVERAGE")  # implicit default package, no package= kwarg
#     ("Microsoft.Testing.Extensions.CodeCoverage", "$FAKE_COVERAGE", "9.0.0"),
# mod.validate_pairing("xunit.v3", "$FAKE_COVERAGE", package="microsoft.testing.extensions.codecoverage")
SH

  cat > "$root/skills/migrate-legacy/references/xunit-v3-migration.md" <<MD
# Fixture reference

| xunit test package | resolves through | MTP | CodeCoverage |
|---|---|---|---|
| **\`xunit.v3\`** $FAKE | \`xunit.v3.mtp-v1\` | 1.9.1 | **17.x** <!-- pinned:xunit-v3 --> |
| **\`xunit.v3.mtp-v2\`** $FAKE | \`xunit.v3.core.mtp-v2\` | 2.0.2 | **18.x** |

Both are the same **major**, and \`xunit.v3.mtp-v2\` $FAKE are **stable**, not prerelease — so a
rule keyed on the major refuses the correct pair.

#158's other restatement of the frozen-style trio:
xunit $FAKE_FROZEN, xunit.runner.visualstudio $FAKE_FROZEN, Microsoft.NET.Test.Sdk $FAKE_FROZEN. <!-- agreed:frozen-xunit-core agreed:frozen-xunit-runner agreed:frozen-test-sdk -->
MD
}

# ----------------------------------------------- 0. the baseline is genuinely accounted for
# Every refusal below is a MUTATION of this baseline. If the baseline itself refused, each of them
# would "pass" for a reason that has nothing to do with the defect it names — the fixture-bug
# failure mode tests/ci-wiring/test.sh guards with assert_parsed.
BASE="$WORK/baseline"; scaffold "$BASE"
out=$(run_check "$BASE"); rc=$?
if [ $rc -eq 0 ]; then
  ok "the baseline fixture is fully accounted for (marked + historical)"
else
  bad "the baseline fixture must pass, but the check refused it (rc=$rc): $out"
fi

# ------------------------------------------------ 1. a new copy, neither marked nor recorded
# The case #90 exists for. A copy of the pin appears in a file nobody thought about; the check must
# REFUSE and name file:line, rather than sweep it into agreement (a wrong EDIT) or ignore it (what
# an exclusion list would have done).
R="$WORK/newcopy"; scaffold "$R"
mkdir -p "$R/docs"
printf 'Our CI pins xunit.v3 %s, measured last spring.\n' "$FAKE" > "$R/docs/notes.md"
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] \
   && grep -q 'docs/notes.md:1' <<<"$out" \
   && grep -q 'neither marked nor recorded' <<<"$out"; then
  ok "an unmarked, unrecorded copy is refused, naming file:line"
else
  bad "expected a refusal naming docs/notes.md:1; got rc=$rc: $out"
fi

# ---------------------------------------------------- 2. a marked line that states a stale version
# The drift half, and the reason marking is not circular: this line is found BY ITS MARKER, so it
# is judged even though it no longer spells the current pin. The refusal must also say re-MEASURE
# — never "edit the number" — because these figures carry an MTP version and a CodeCoverage major
# that a real migration depends on ([7e]'s argument).
R="$WORK/stale"; scaffold "$R"
rewrite "$R/skills/migrate-legacy/references/xunit-v3-migration.md" "s/\`xunit.v3\`\*\* $FAKE/\`xunit.v3\`** 1.2.3/"
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] \
   && grep -q 'xunit-v3-migration.md:5' <<<"$out" \
   && grep -q 'states xunit.v3 1.2.3' <<<"$out" \
   && grep -q 'Do NOT simply edit the number' <<<"$out"; then
  ok "a marked line stating a stale version is refused, and told to re-measure"
else
  bad "expected a stale-marked refusal naming the row; got rc=$rc: $out"
fi

# ------------------------------------ 3. a historical line is ignored BECAUSE its entry matched it
# Section 0 shows the historical lines are accepted; on its own that proves nothing, since a line
# nothing looked at is accepted too. Break the ANCHOR only — the version stays — and the very same
# line must now be refused as a new copy. That is what makes the acceptance load-bearing.
R="$WORK/anchor"; scaffold "$R"
rewrite "$R/tests/xunit-v3/test.sh" 's/a version-keyed map would invert/a map keyed that way would flip/'
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] \
   && grep -q 'tests/xunit-v3/test.sh:5' <<<"$out" \
   && grep -q 'neither marked nor recorded' <<<"$out"; then
  ok "a historical line is accepted only because its entry matched it"
else
  bad "expected the un-anchored historical line to be refused; got rc=$rc: $out"
fi

# ------------------------------------------------- 4. a HISTORICAL entry that matches nothing
# A recorded occurrence that no longer exists is a claim about the repo that is no longer true, and
# an allowlist nobody prunes is how the next reader learns to distrust the whole table.
R="$WORK/stalentry"; scaffold "$R"
rewrite "$R/tests/xunit-v3/apply-transform.py" '/are STABLE releases/d'
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] && grep -q 'matches nothing any more' <<<"$out"; then
  ok "a HISTORICAL entry whose line is gone is refused, not silently carried"
else
  bad "expected a stale-entry refusal; got rc=$rc: $out"
fi

# --------------------------- 4a. a HISTORICAL entry whose anchor still matches, but the version
#                                  differs — a legitimate bump nobody re-measured this line for
# #292: the pin's constant moves on and this specific illustrative line just never gets
# re-measured — the anchor's own text (which deliberately carries no version literal, see
# HISTORICAL's header comment) is still right there, sitting on a line that now states some OTHER
# version. That is a different claim than "this line is gone" (section 4): the record is still
# findable, it just needs its number updated. The refusal must say so — RE-MEASURE, never
# re-point-or-delete — or a maintainer chasing #90/#158's wrong instruction wastes time hunting for
# a moved anchor that never moved.
R="$WORK/staleversion"; scaffold "$R"
rewrite "$R/tests/xunit-v3/apply-transform.py" \
  "s/mtp-v2\` $FAKE are STABLE releases/mtp-v2\` 1.2.3 are STABLE releases/"
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] \
   && grep -q 'still finds its line' <<<"$out" \
   && grep -q 're-measure' <<<"$out" \
   && ! grep -qi "are STABLE releases.*matches nothing any more" <<<"$out"; then
  ok "a HISTORICAL entry whose anchor still matches but states a stale version is told to re-measure"
else
  bad "expected a re-measure refusal (not 'matches nothing any more') for the STABLE-releases entry; got rc=$rc: $out"
fi

# ------------------------------------------------------- 5. a HISTORICAL entry covering two lines
# Each entry records ONE occurrence with ONE reason. An anchor broad enough to cover a second would
# swallow the next copy in silence — the exclusion-list failure this whole design rejects, rebuilt
# inside the allowlist.
R="$WORK/broad"; scaffold "$R"
# Read the line out FIRST, then append. `grep pattern f >> f` is a file that is its own output:
# BSD grep (macOS) does it, GNU grep (CI) refuses with "input file is also the output" and appends
# nothing — so the second occurrence never exists and this section passes vacuously on one platform
# while failing on the other. The suite's whole subject is copies of a literal; it must not create
# its own fixture in a way only one grep implementation performs.
dup_line=$(grep 'are STABLE releases' "$R/tests/xunit-v3/apply-transform.py")
[ -n "$dup_line" ] || bad "section 5 fixture: the line to duplicate was not found in the scaffold"
printf '%s\n' "$dup_line" >> "$R/tests/xunit-v3/apply-transform.py"
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] && grep -q 'covers 2 lines' <<<"$out"; then
  ok "a HISTORICAL entry that covers two occurrences is refused as too broad"
else
  bad "expected an over-broad-anchor refusal; got rc=$rc: $out"
fi

# --------------------------------------------------- 6. a marker on a line that states no claim
# A marker that verifies nothing is worse than no marker: it reads, to the next author, as a line
# already under guard.
R="$WORK/noclaim"; scaffold "$R"
mkdir -p "$R/docs"
printf 'A note with no package id at all.  # pinned:xunit-v3\n' > "$R/docs/marked.md"
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] \
   && grep -q 'docs/marked.md:1' <<<"$out" \
   && grep -q 'states no `xunit.v3 <version>` claim' <<<"$out"; then
  ok "a marker on a line carrying no claim is refused"
else
  bad "expected a no-claim refusal; got rc=$rc: $out"
fi

# ------------------------------------------------------- 7. an EXCLUDED path spelling the pin
# Two paths are excluded because they DEFINE and EXERCISE the marker convention. That exclusion is
# a hole of exactly the shape this check closes unless something proves nothing hides in it — so
# an excluded file may name the marker, but never the version.
R="$WORK/excluded"; scaffold "$R"
mkdir -p "$R/tests/pinned-literals"
printf 'A fixture note that leaks the real pin %s.\n' "$FAKE" > "$R/tests/pinned-literals/notes.md"
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] \
   && grep -q 'tests/pinned-literals/notes.md:1' <<<"$out" \
   && grep -q 'EXCLUDED from the scan' <<<"$out"; then
  ok "an excluded path that spells the pin is refused, so the exclusion hides nothing"
else
  bad "expected an excluded-path refusal; got rc=$rc: $out"
fi

# ------------------------------------------------------ 8. no occurrence and no marker anywhere
# The vacuity guard. A repo where the scan finds nothing to judge must REFUSE: "all accounted for"
# over an empty set is the #45 failure — a check nobody notices has stopped looking.
R="$WORK/vacuous"; mkdir -p "$R/tests/xunit-v3"
# COVERAGE_PACKAGE/COVERAGE_EXT_VERSION must be defined too (#158's second DERIVED pin shares this
# same source module) — omitting them would make check_pin_derived die(2) on that pin before ever
# reaching this section's target, xunit-v3's OWN marked==0 vacuity refusal. Both pins go vacuous
# here, and the AGREED pins go vacuous too (they need no source) — this section only asserts that
# AT LEAST ONE 'verified NOTHING' message names the case it drove: nothing carries any marker.
{ printf 'XUNIT_V3_PACKAGE = "xunit.v3"\n'; printf 'XUNIT_V3_VERSION = "%s"\n' "$FAKE";
  printf 'COVERAGE_PACKAGE = "coverage-widget"\n'; printf 'COVERAGE_EXT_VERSION = "%s"\n' "$FAKE_COVERAGE"; } \
  > "$R/tests/xunit-v3/apply-transform.py"
out=$(run_check "$R"); rc=$?
# Scoped to the xunit-v3 marker specifically: with #158's later pins in PINS too, coverage-ext and
# the three AGREED pins ALSO go vacuous over this same bare fixture, each printing its own "verified
# NOTHING" — a bare 'verified NOTHING' grep would pass even with xunit-v3's OWN guard blinded, which
# is exactly what M3 below exists to catch.
if [ $rc -ne 0 ] && grep -q '`pinned:xunit-v3` marker.*verified NOTHING' <<<"$out"; then
  ok "a repo where nothing carries the marker refuses instead of passing vacuously"
else
  bad "expected a vacuity refusal naming the pinned:xunit-v3 marker; got rc=$rc: $out"
fi

# --------------------------------------------------------- 9. a directory with no files at all
# Distinct from section 8 and reported differently: there is no repo to read, so no VERDICT was
# reached. Exit 2 says that; exit 0 would claim a pass, and exit 1 would blame the repo.
R="$WORK/empty"; rm -rf "$R"; mkdir -p "$R"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 2 ] && grep -q 'refusing to report' <<<"$out"; then
  ok "an empty directory yields no verdict (exit 2), never a pass"
else
  bad "expected exit 2 on an empty directory; got rc=$rc: $out"
fi

# ------------------------------------------------------- 9b. the constant defined more than once
# The check compares the WHOLE repo against one value, so which definition it read is not a detail.
# Taking the first would make the verdict depend on file order — a wrong answer that looks like a
# right one — so two definitions are a plumbing error rather than something to resolve.
R="$WORK/twopins"; scaffold "$R"
printf 'XUNIT_V3_VERSION = "1.2.3"\n' >> "$R/tests/xunit-v3/apply-transform.py"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 2 ] && grep -q 'defined more than once' <<<"$out"; then
  ok "two definitions of the constant yield no verdict (exit 2), never a guess"
else
  bad "expected exit 2 on a doubly-defined constant; got rc=$rc: $out"
fi

# ------------------------------------------------------------------- 10. the REAL repository
# The acceptance case. Without it the suite would prove the refusals work and say nothing about
# whether the repository it ships in is actually accounted for.
out=$(run_check "$REPO"); rc=$?
if [ $rc -eq 0 ]; then
  ok "the real repository is fully accounted for: $out"
else
  bad "the real repository must pass the check (rc=$rc): $out"
fi

# ------------------------------------------- 11. a claim wrapped across two physical lines
# The bug #158 exists for: a claim typeset across two physical lines — the package id ending one,
# the version opening the next — with nothing looking at the seam. This actually happened:
# `tests/xunit-v3/test.sh:237` had to be hand-rewrapped onto one line to become checkable (see the
# header of tests/pinned-literals/README.md). The check must see the wrap, AND attribute it to the
# line the package id starts on — never to the line the version happens to land on, which is what a
# naive "does this physical line spell the version" scan would do instead.
R="$WORK/wrapped"; scaffold "$R"
mkdir -p "$R/docs"
printf 'Our CI pins xunit.v3\n%s, measured last spring.\n' "$FAKE" > "$R/docs/wrapped.md"
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] \
   && grep -q 'docs/wrapped.md:1' <<<"$out" \
   && ! grep -q 'docs/wrapped.md:2' <<<"$out" \
   && grep -q 'neither marked nor recorded' <<<"$out"; then
  ok "a claim wrapped across two lines is refused, naming the FIRST line, never the second"
else
  bad "expected a refusal naming docs/wrapped.md:1 only (not :2); got rc=$rc: $out"
fi

# ------------------------------------- 12. a marker on line N does not launder line N+1's claim
# The flip side of section 11's join: it must not let a marker on line N silently cover a claim
# that merely happens to sit on line N+1. The marker still binds to the physical line it is ON —
# line N is refused for stating no claim (section 6's case, unchanged), and line N+1's own,
# unrelated claim is refused independently, never silently verified just because a marker sits one
# line above it. Unlike section 11 this is NOT a wrap: line N+1 states a complete claim entirely by
# itself, with its own package id and version.
R="$WORK/nolaunder"; scaffold "$R"
mkdir -p "$R/docs"
printf 'A pinned line with no package id at all.  # pinned:xunit-v3\nUnrelated: xunit.v3 %s mentioned separately.\n' \
  "$FAKE" > "$R/docs/nolaunder.md"
out=$(run_check "$R"); rc=$?
if [ $rc -ne 0 ] \
   && grep -q 'docs/nolaunder.md:1' <<<"$out" \
   && grep -q 'states no `xunit.v3 <version>` claim' <<<"$out" \
   && grep -q 'docs/nolaunder.md:2' <<<"$out" \
   && grep -q 'neither marked nor recorded' <<<"$out"; then
  ok "a marker on line N does not launder an unrelated claim on line N+1 — both refused independently"
else
  bad "expected independent refusals for docs/nolaunder.md:1 AND :2; got rc=$rc: $out"
fi

# ---------------------------------------- 12b. a MARKED line whose own claim wraps is accepted
# Code review on #158: sections 11–12 proved the wrap join for the UNMARKED literal-scan half, but
# nothing proved it for a marker's OWN claim — and every marker in THIS repo trails at the very end
# of the complete claim (`… CodeCoverage <version>):  # pinned:xunit-v3`), a shape section 11 already
# covers via the literal-scan half (the marker sits on the SAME physical line as the wrap's tail, not
# between the id and the version). The shape this section drives — the marker PRECEDING a claim that
# then wraps onto the next line — is the one line_claims() in the marked branch was written to
# handle, and it needed its own acceptance case: nothing here asserts it is REACHABLE, only that a
# refusal-shaped adversarial case does not slip past it (that is what 12's own case proves).
R="$WORK/markedwrap"; scaffold "$R"
mkdir -p "$R/docs"
printf '# pinned:xunit-v3 -- measured for xunit.v3\n%s exactly.\n' "$FAKE" > "$R/docs/markedwrap.md"
out=$(run_check "$R"); rc=$?
if [ $rc -eq 0 ]; then
  ok "a marker preceding its own wrapped claim is accepted (marker-then-wrap, not id-then-marker)"
else
  bad "a marker whose claim wraps forward onto the next line must be accepted; got rc=$rc: $out"
fi

MUT="$WORK/mutants"; mkdir -p "$MUT"

# ---------------------------------------------------------- AGREED: the engine, exercised
# The shipped PINS table carries no AGREED pin yet — #158's Task 3 is what adds the real ones (the
# frozen-fixture trio). This engine still needs proving before anything depends on it, so these
# sections drive a MUTATED copy of the check carrying one throwaway AGREED pin (package "widget",
# marker "agreed:test-pin"), the same "copy the script, change one thing, run scratch fixtures
# through the copy" technique section 17's mutants use below — just adding a pin instead of
# poisoning a line. `$AGREED` is built once and reused by sections 14–16.
python3 - "$CHECK" "$MUT/agreed-engine.py" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
anchor = "PINS = (\n"
insert = ('    Pin(\n'
          '        name="agreed-test",\n'
          '        marker="agreed:test-pin",\n'
          '        kind="AGREED",\n'
          '        package="widget",\n'
          '    ),\n')
if anchor not in text:
    sys.exit("PINS = ( not found — scripts/pinned-literals-check.py's shape changed")
open(dst, "w", encoding="utf-8").write(text.replace(anchor, anchor + insert, 1))
PY
AGREED="$MUT/agreed-engine.py"
[ -s "$AGREED" ] || { echo "FAIL: could not build the AGREED-engine mutant"; exit 1; }

# ------------------------------------------------- 14. an AGREED pin, two occurrences that agree
R="$WORK/agreed-agree"; scaffold "$R"
mkdir -p "$R/docs"
printf 'The vendor pins widget 1.2.3 in its own doc.  # agreed:test-pin\n' > "$R/docs/widget-a.md"
printf 'Vendor doc: widget 1.2.3, restated here too.  # agreed:test-pin\n' > "$R/docs/widget-b.md"
out=$(run_with "$AGREED" "$R"); rc=$?
if [ $rc -eq 0 ]; then
  ok "an AGREED pin with two agreeing occurrences is accepted"
else
  bad "two agreeing AGREED occurrences must be accepted; got rc=$rc: $out"
fi

# ---------------------------------------------- 15. an AGREED pin, two occurrences that disagree
R="$WORK/agreed-disagree"; scaffold "$R"
mkdir -p "$R/docs"
printf 'The vendor pins widget 1.2.3 in its own doc.  # agreed:test-pin\n' > "$R/docs/widget-a.md"
printf 'Vendor doc: widget 9.9.0, restated here too.  # agreed:test-pin\n' > "$R/docs/widget-b.md"
out=$(run_with "$AGREED" "$R"); rc=$?
if [ $rc -ne 0 ] \
   && grep -q 'occurrences that disagree' <<<"$out" \
   && grep -q 'docs/widget-a.md:1 states 1.2.3' <<<"$out" \
   && grep -q 'docs/widget-b.md:1 states 9.9.0' <<<"$out"; then
  ok "an AGREED pin with disagreeing occurrences is refused, naming every value seen"
else
  bad "expected a disagreement refusal naming both files and both values; got rc=$rc: $out"
fi

# --------------------------------------------------- 16. an AGREED pin, exactly one occurrence
R="$WORK/agreed-single"; scaffold "$R"
mkdir -p "$R/docs"
printf 'The vendor pins widget 1.2.3 in its own doc.  # agreed:test-pin\n' > "$R/docs/widget-a.md"
out=$(run_with "$AGREED" "$R"); rc=$?
if [ $rc -ne 0 ] \
   && grep -q 'exactly ONE marked occurrence' <<<"$out" \
   && grep -q 'docs/widget-a.md:1 states' <<<"$out"; then
  ok "an AGREED pin with exactly one occurrence is refused as vacuous"
else
  bad "expected a vacuous-single-occurrence refusal; got rc=$rc: $out"
fi

# ------------------------------------- 16b. one MARKED line stating two different values
# Code review on #158: without this, a single self-contradictory line silently became TWO
# "occurrences" at the identical file:line, and the disagreement message named that one line twice
# as if a second, independent restatement existed. It must instead be refused on its own, naming
# both values it states — and must NOT also appear in a later disagreement message, since after this
# refusal there is exactly one (still legitimate) occurrence left.
R="$WORK/agreed-multiline"; scaffold "$R"
mkdir -p "$R/docs"
printf 'widget 1.2.3 vs widget 9.9.9 -- one line, two claims.  # agreed:test-pin\n' > "$R/docs/one.md"
printf 'The vendor pins widget 1.2.3 in its own doc.  # agreed:test-pin\n' > "$R/docs/two.md"
out=$(run_with "$AGREED" "$R"); rc=$?
if [ $rc -ne 0 ] \
   && grep -q 'docs/one.md:1 carries the `agreed:test-pin` marker and states 2 different values' <<<"$out" \
   && grep -q '1.2.3, 9.9.9' <<<"$out" \
   && ! grep -q 'occurrences that disagree' <<<"$out"; then
  ok "one marked line stating two different values is refused on its own, not folded into a disagreement across two occurrences"
else
  bad "expected a single-line two-values refusal, and no separate disagreement message; got rc=$rc: $out"
fi

# --------------------------------------------------------- 17. an AGREED pin's witness
# Code review on #158: without a witness, an AGREED pin's marked restatements could agree with EACH
# OTHER while both had drifted from the frozen fact they restate, and the check would still accept —
# verified against the real repo by editing samples/LegacyShop's csproj directly. `$AGREED_W` adds a
# witness pointing at a scratch frozen file that is never marked (nothing may write to it) and is
# read unconditionally for one more occurrence.
python3 - "$CHECK" "$MUT/agreed-engine-witness.py" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
anchor = "PINS = (\n"
insert = ('    Pin(\n'
          '        name="agreed-witness-test",\n'
          '        marker="agreed:witness-test-pin",\n'
          '        kind="AGREED",\n'
          '        package="widget",\n'
          '        witness="frozen/widget.txt",\n'
          '    ),\n')
if anchor not in text:
    sys.exit("PINS = ( not found — scripts/pinned-literals-check.py's shape changed")
open(dst, "w", encoding="utf-8").write(text.replace(anchor, anchor + insert, 1))
PY
AGREED_W="$MUT/agreed-engine-witness.py"
[ -s "$AGREED_W" ] || { echo "FAIL: could not build the AGREED-witness mutant"; exit 1; }

# 17a. the witness agrees with the one marked occurrence -> accept (2 total: witness + 1 marked).
R="$WORK/agreed-witness-agree"; scaffold "$R"
mkdir -p "$R/docs" "$R/frozen"
printf 'The vendor pins widget 1.2.3 in its own doc.  # agreed:witness-test-pin\n' > "$R/docs/widget.md"
printf 'widget 1.2.3\n' > "$R/frozen/widget.txt"
out=$(run_with "$AGREED_W" "$R"); rc=$?
if [ $rc -eq 0 ]; then
  ok "an AGREED pin's witness agreeing with its one marked occurrence is accepted"
else
  bad "witness + one agreeing marked occurrence must be accepted; got rc=$rc: $out"
fi

# 17b. the witness DISAGREES with the marked occurrence -> refuse, naming the witness path.
R="$WORK/agreed-witness-disagree"; scaffold "$R"
mkdir -p "$R/docs" "$R/frozen"
printf 'The vendor pins widget 1.2.3 in its own doc.  # agreed:witness-test-pin\n' > "$R/docs/widget.md"
printf 'widget 9.9.9\n' > "$R/frozen/widget.txt"
out=$(run_with "$AGREED_W" "$R"); rc=$?
if [ $rc -ne 0 ] \
   && grep -q 'occurrences that disagree' <<<"$out" \
   && grep -q 'frozen/widget.txt:1 states 9.9.9' <<<"$out"; then
  ok "an AGREED pin's witness disagreeing with a marked occurrence is refused, naming the witness"
else
  bad "expected a disagreement refusal naming the witness path; got rc=$rc: $out"
fi

# 17c. the witness is ABSENT (no frozen/widget.txt at all) -> gracefully skipped, never a plumbing
# error. This is the shape every OTHER scratch fixture in this suite is in (none of them carry
# samples/LegacyShop), so sections 0–16 already prove it by never failing on a missing witness —
# this case makes that guarantee explicit and names it.
R="$WORK/agreed-witness-absent"; scaffold "$R"
mkdir -p "$R/docs"
printf 'The vendor pins widget 1.2.3 in its own doc.  # agreed:witness-test-pin\n' > "$R/docs/widget-a.md"
printf 'Vendor doc: widget 1.2.3, restated here too.  # agreed:witness-test-pin\n' > "$R/docs/widget-b.md"
out=$(run_with "$AGREED_W" "$R"); rc=$?
if [ $rc -eq 0 ]; then
  ok "an AGREED pin's absent witness is skipped gracefully, never a plumbing error"
else
  bad "a missing witness file must not be an error when two marked occurrences already agree; got rc=$rc: $out"
fi

# -------------------------------------------------------------- 18. the check, driven to red
# Each mutation neuters exactly one branch of the guard, and the case that branch serves must lose
# its evidence. Without this the sections above prove the check refuses SOMETHING — not that any
# particular assertion is load-bearing. The mutants are copies; the shipped script is never edited.

# The mutant path comes back in a GLOBAL, never through `m=$(mutate …)`. Command substitution runs
# the function in a SUBSHELL: a `bad` call inside it would increment $fails in a copy that dies
# with the subshell, AND its FAIL line would be captured into $m instead of printed. A mutation
# whose sed stopped matching would then print nothing and exit 0 — a suite reporting green over an
# assertion it never made, which is the one outcome this repo treats as worse than a red run.
MUTANT=""
mutate() {  # <name> <sed-expr>; sets $MUTANT, returns non-zero if the mutation did not take
  local name="$1" expr="$2"
  MUTANT="$MUT/$name.py"
  cp "$CHECK" "$MUTANT" && rewrite "$MUTANT" "$expr" || {
    bad "mutation '$name' could not be built"; MUTANT=""; return 1; }
  if cmp -s "$CHECK" "$MUTANT"; then
    bad "mutation '$name' changed nothing — its sed no longer matches the check"
    MUTANT=""
    return 1
  fi
  return 0
}

# M6 — stop detecting AGREED disagreement at all. Section 15's refusal must go unnamed. Mutates the
# AGREED-engine copy (built above), not the shipped $CHECK — this is the disagreement check that
# does not exist until the AGREED pin is present, so there is nothing for a plain mutate() of $CHECK
# to poison.
AGREED_BLIND="$MUT/agreed-engine-blind.py"
cp "$AGREED" "$AGREED_BLIND" && rewrite "$AGREED_BLIND" 's/^    if len(values) > 1:$/    if False:/'
if cmp -s "$AGREED" "$AGREED_BLIND"; then
  bad "mutation 'blind-to-disagreement' changed nothing — its sed no longer matches the check"
else
  out=$(run_with "$AGREED_BLIND" "$WORK/agreed-disagree")
  if grep -q 'occurrences that disagree' <<<"$out"; then
    bad "section 15 is not load-bearing: the blinded check still refused the disagreement"
  else
    ok "mutation 'blind-to-disagreement' silences section 15 — that assertion is load-bearing"
  fi
fi

# M1 — stop classifying unmarked lines at all. Section 1's copy must go unnamed.
if mutate blind-to-copies 's/^            if not direct_hit and not wrap_hit:$/            if True:/'; then
  out=$(run_with "$MUTANT" "$WORK/newcopy")
  if grep -q 'docs/notes.md:1' <<<"$out"; then
    bad "section 1 is not load-bearing: the blinded check still named docs/notes.md:1"
  else
    ok "mutation 'blind-to-copies' silences section 1 — that assertion is load-bearing"
  fi
fi

# M2 — stop comparing a marked line's claim to the constant. Section 2 must lose its refusal.
if mutate accept-stale-marks 's/^                stale = sorted(.*)$/                stale = []/'; then
  out=$(run_with "$MUTANT" "$WORK/stale")
  if grep -q 'states xunit.v3 1.2.3' <<<"$out"; then
    bad "section 2 is not load-bearing: the blinded check still refused the stale mark"
  else
    ok "mutation 'accept-stale-marks' silences section 2 — that assertion is load-bearing"
  fi
fi

# M3 — drop the vacuity guard. Section 8's repo must lose its "verified NOTHING" verdict.
#
# Asserted on the MESSAGE rather than on the exit status, deliberately: that fixture is a bare
# two-line module, so every HISTORICAL entry is stale there too and the mutant still exits 1 for
# that unrelated reason. Reading the exit status would let the vacuity guard rot behind a refusal
# it never issued — the same "green for the wrong reason" the parse sweep's CI step warns about.
# Scoped to the pinned:xunit-v3 marker (see section 8's own comment): #158's later pins over the
# same fixture print their OWN unrelated "verified NOTHING" lines, which this mutation does not
# touch — a bare grep would stay green even with xunit-v3's guard blinded.
if mutate no-vacuity-guard 's/^    if marked == 0:$/    if False:/'; then
  out=$(run_with "$MUTANT" "$WORK/vacuous")
  if grep -q '`pinned:xunit-v3` marker.*verified NOTHING' <<<"$out"; then
    bad "section 8 is not load-bearing: the blinded check still reported the vacuity refusal"
  else
    ok "mutation 'no-vacuity-guard' silences section 8 — that assertion is load-bearing"
  fi
fi

# M4 — stop joining physical lines at all. Section 11's wrapped claim must go unnamed at line 1
# (it may still surface, misattributed to line 2, exactly like the pre-#158 behaviour — the point
# is that line 1 loses its evidence, not that the repo goes silent altogether).
if mutate blind-to-wraps 's/^    if next_line is not None:$/    if False:/'; then
  out=$(run_with "$MUTANT" "$WORK/wrapped")
  if grep -q 'docs/wrapped.md:1' <<<"$out"; then
    bad "section 11 is not load-bearing: the un-joined check still named docs/wrapped.md:1"
  else
    ok "mutation 'blind-to-wraps' silences section 11 — that assertion is load-bearing"
  fi
fi

# M5 — drop the "starts within THIS line" guard on a wrap match. Section 12's marker must now
# launder the unrelated claim one line below it: with no boundary check, ANY match anywhere in the
# joined text is attributed to line N, so the marker's line stops stating "no claim" (it silently
# adopts line N+1's claim instead) and line N+1's own occurrence gets marked "consumed" and never
# scanned in its own right either. Both assertions inside section 12 depend on the same guard, so
# losing either is enough to prove it load-bearing.
if mutate no-wrap-boundary 's/^                if m.start() < len(line) < m.end():$/                if True:/'; then
  out=$(run_with "$MUTANT" "$WORK/nolaunder")
  if grep -q 'docs/nolaunder.md:1' <<<"$out" && grep -q 'docs/nolaunder.md:2' <<<"$out"; then
    bad "section 12 is not load-bearing: the boundary-less check still refused both lines"
  else
    ok "mutation 'no-wrap-boundary' silences section 12 — that assertion is load-bearing"
  fi
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "pinned-literals golden test: all sections passed."
else
  echo "pinned-literals golden test: $fails section(s) FAILED."
fi
exit $((fails > 0))
