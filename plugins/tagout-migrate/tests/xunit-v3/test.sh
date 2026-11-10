#!/usr/bin/env bash
# xunit v2 -> v3 golden test.
#
# Guards the phase-5 "test platform" item end to end:
#   1. the inventory reports the test stack precisely enough to decide the v2/v3 question;
#   2. the documented transform really produces a running v3 test project;
#   3. the OutputType trap — a v3 project left as a library — is pinned as 0 tests, not 6;
#   4. coverage still reaches the dashboard under the Microsoft Testing Platform — one report per
#      test project, and the template's own step is executed rather than a copy of it;
#   5. the decision is wired into phases 1, 5 and 6, not merely documented in a side file;
#   6. project shapes the fixture does not have (element-form refs, flat indent, multi-TFM,
#      packages.config, central package management) are all handled;
#   7. the xunit.v3 / CodeCoverage version pairing is machine-checked, not remembered — and no
#      ambient environment value can steer the transform, so every override is an explicit flag;
#      `--help` names the package AND the version the transform actually writes (the docstring
#      sends readers there for the pinned value), and every prose claim about that version — in the
#      module's own comments and in the migration reference agents read — is swept for agreement,
#      so a Renovate bump cannot leave a measurement standing that nobody re-took;
#   8. tests/ and scripts/ load kit scripts through exactly one module loader — the shared
#      tests/_lib/py.sh — so the no-__pycache__ invariant that loader carries cannot be lost to a
#      copy-paste, in this file or in any other (#51 widened this from "THIS FILE");
#   9. Renovate can actually SEE those two pins and actually HOLDS their majors — the custom
#      managers are executed against the real file, and the holds are tested for REACH, so a config
#      the engine would reject, or protection that has been scoped away from the pins, fails here
#      instead of surfacing as PRs that silently never appear;
#  10. the find probes report what they FOUND — not how the reader exited, and not whether the
#      starting path happened to exist. A SIGPIPE'd find under `pipefail` used to make two of this
#      file's own checks skip themselves precisely when they had something to report (#48), and the
#      first-match form used to abort the suite AT the assignment, before the diagnostic written
#      directly beneath it could say what had gone wrong (#98).
#
# The committed fixture is never mutated: cleanup() asserts it on every exit path, and CI asserts it
# stays "green AND legacy".
#
# There is exactly ONE completion marker — the final `xunit v3 golden test OK`. Section lines carry a
# label, never a fraction: a denominator goes stale the moment a section is added, and a stale one
# reads as a run that stopped early.
#
# Everything that builds runs on a COPY under $(mktemp -d). samples/LegacyShop is read-only here.
set -euo pipefail
# Resolved BEFORE the cd, because a relative $0 stops resolving once the working directory moves.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/../.."

KIT="$PWD"
FIXTURE="$KIT/samples/LegacyShop"

# Run a Python snippet with a kit script already loaded as `mod`:
#
#   py_module <script-path> [args…] <<'PY'
#   …body; `mod` is the loaded module, sys.argv[1] is <script-path>, argv[2:] are the args…
#   PY
#
# The definition lives in tests/_lib/py.sh since #51 — this suite is no longer its only tenant,
# and a loader that only one file asserts is a loader the OTHER file can quietly copy wrong. The
# PYTHONDONTWRITEBYTECODE=1 it carries is the whole point (see that file); section 8 asserts that
# it is the kit's only one.
#
# Sourced through $KIT, an absolute path, because this script has already cd'd to the kit root —
# a relative path here would resolve against wherever the suite happened to be invoked from.
#
# Both shared files are loaded HERE, together. They used to sit sixty lines apart, and the second
# was sourced BARE while the first was guarded — one file, two answers to "what happens if this
# helper goes missing" (#128). The first line is spelled out because kit_source is defined in the
# file it loads; the second is one call.
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_source "$KIT/tests/_lib/py.sh"

# Print the `run: |` body of a named step of templates/ci-dotnet.yml, so the assertions below
# execute the template VERBATIM instead of a copy that drifts from it. A hand-copied command is
# how the multi-project collision (issue #17) stayed green in this very file: the test proved
# something about its own string, not about the template the kit ships.
#
# Sliced as text rather than parsed as YAML on purpose — this script runs before the CI step
# that installs PyYAML, and a missing import here would look like a test failure.
template_step() {
  python3 - "$KIT/templates/ci-dotnet.yml" "$1" <<'PY'
import sys
path, want = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().splitlines()
start = next((i for i, l in enumerate(lines) if l.strip() == f"- name: {want}"), None)
if start is None:
    sys.exit(f"templates/ci-dotnet.yml has no step named {want!r}")
run = next((i for i in range(start + 1, len(lines)) if lines[i].strip() == "run: |"), None)
if run is None:
    sys.exit(f"step {want!r} has no `run: |` block")
indent = len(lines[run]) - len(lines[run].lstrip()) + 2
body = []
for line in lines[run + 1:]:
    if line.strip() and len(line) - len(line.lstrip()) < indent:
        break
    body.append(line[indent:])
print("\n".join(body).strip("\n"))
PY
}

# The slice above ends at the first line indented less than the block, so a heredoc terminator
# (legal at column 0 inside a YAML literal block) would truncate the command silently — and a
# truncated command that still parses could PASS, which is the one outcome worse than failing.
# `bash -n` catches the truncation without knowing anything about the step's content.
template_step_checked() {
  local body
  body=$(template_step "$1")
  [ -n "$body" ] || { echo "FAIL: extracted an empty body for step '$1'"; exit 1; }
  bash -n <<<"$body" 2>/dev/null || {
    echo "FAIL: the extracted body of step '$1' is not valid bash — the slice truncated it:"
    echo "$body"; exit 1; }
  printf '%s' "$body"
}

# "Is there at least one match?" — one home for the idiom, for the reason #42 gave about the module
# loader: the wrong shape is what gets copied, and two call sites had already copied it (#48).
#
# The scratch dirs, the EXIT trap, the samples/ immutability check and any_match all live in
# tests/_lib.sh since #72 — four suites each carried their own copy, and they had already diverged.
# The invariant that matters (`local rc=$?` FIRST, or a failing suite reports success) is asserted
# once, in tests/lib/test.sh, instead of being restated in four comments.
#
# This suite registers the one guard only it needs: a __pycache__ left beside a kit script. It
# leans on any_match, which is why kit_init proves the host's find supports `-print -quit`.
no_pycache() {
  if any_match "$KIT/scripts" "$KIT/tests" -name '__pycache__' -type d; then
    echo "FAIL: the test left a __pycache__ inside the kit — it must not modify the repo it tests."
    return 1
  fi
}

kit_init "$KIT"
kit_guard kit_guard_samples_unchanged
kit_guard no_pycache

# Every `dotnet test` summary below is PARSED (`Total: N`, `Failed!`), and dotnet prints it in the
# UI language: under a French locale it is `Total : 6`, the count reads as 0 and the suite fails
# with "v3 ran 0 tests" on a tree that is green (#744). Pinned once, for the whole suite.
export DOTNET_CLI_UI_LANGUAGE=en

# ---------------------------------------------------------------------------
# 0. No knob in the transform reads the environment.
#
#    First, before ANY invocation below. This replaced a top-of-file `unset`, and it has to keep
#    that position: every section from 2 onward runs the transform, so a reintroduced env read with
#    a value in the caller's shell would steer those runs and fail there first — sending the reader
#    after a package-resolution bug when the real defect is ambient state.
#
#    A pure source check with no dependencies, so it costs nothing to run first. Section 7c is the
#    end-to-end witness that the rule holds for the script as actually invoked.
# ---------------------------------------------------------------------------
TRANSFORM="$KIT/tests/xunit-v3/apply-transform.py"
[ -f "$TRANSFORM" ] || { echo "FAIL: $TRANSFORM does not exist — this guard would check nothing"; exit 1; }
# `|| true` INSIDE the pipeline: grep exits 1 when it matches nothing — the passing case — and under
# `set -o pipefail` that would abort the assignment, killing the suite with no output at all. The
# zero count is a result, not a failure.
knobs=$( { grep -oE 'os\.environ|getenv' "$TRANSFORM" || true; } | wc -l | tr -d ' ')
if [ "$knobs" -ne 0 ]; then
  echo "FAIL: apply-transform.py reads $knobs value(s) from the environment. Every override must be"
  echo "      an explicit flag — ambient state must never steer a migration:"
  grep -nE 'os\.environ|getenv' "$TRANSFORM"
  exit 1
fi
echo "  [0] the transform takes no knob from the environment"

# ---------------------------------------------------------------------------
# 1. The inventory reports the test stack (phase 1 needs it to decide v2 vs v3).
# ---------------------------------------------------------------------------
inv=$(./scripts/audit-inventory.sh "$FIXTURE")
python3 - "$inv" <<'PY'
import json, sys
inv = json.loads(sys.argv[1])
stack = inv.get("testStack")
assert stack is not None, "audit-inventory.sh emits no testStack key"
assert len(stack) == 1, f"expected 1 test project in the fixture, got {len(stack)}: {stack}"
entry = stack[0]
assert entry["project"].endswith("LegacyShop.Tests.csproj"), entry["project"]
assert entry["targetFrameworks"] == "net6.0", entry["targetFrameworks"]
want = {
    "xunit": "2.4.2",
    "xunit.runner.visualstudio": "2.4.5",
    "Microsoft.NET.Test.Sdk": "17.3.2",
}
for pkg, version in want.items():
    got = entry["packages"].get(pkg)
    assert got == version, f"{pkg}: expected {version}, got {got}"
# The whole point of the key: the major line must be readable without re-parsing versions.
assert entry["xunitMajor"] == 2, entry["xunitMajor"]
PY
echo "  [1] inventory reports the fixture's test stack (xunit 2.4.2, net6.0)"

# ---------------------------------------------------------------------------
# 2. The documented transform produces a test project that actually RUNS.
#
#    "It builds" is explicitly not the gate — the gate is the number of tests that execute,
#    compared to the phase-2 baseline. The fixture's baseline is 6.
# ---------------------------------------------------------------------------
BASELINE_TESTS=6

# A scratch copy, never the fixture itself. kit_scratch's directory is removed at exit, and the
# registered guards then assert the fixture came through untouched.
scratch=$(kit_scratch)
cp -R "$FIXTURE" "$scratch/v3"

# The fixture has no ITestOutputHelper, so the namespace half of the transform would go
# unexercised. Inject the v2 idiom into the COPY so the rewrite is genuinely proven: under v3
# this file only compiles if `Xunit.Abstractions` became `Xunit`.
python3 - "$scratch/v3" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1]) / "tests/LegacyShop.Tests/OrderServiceTests.cs"
t = p.read_text(encoding="utf-8")
t = t.replace("using Xunit;", "using Xunit;\nusing Xunit.Abstractions;")
t = t.replace(
    "        private readonly OrderService _service = new OrderService();",
    "        private readonly OrderService _service = new OrderService();\n"
    "        private readonly ITestOutputHelper _output;\n\n"
    "        public OrderServiceTests(ITestOutputHelper output)\n"
    "        {\n"
    "            _output = output;\n"
    "        }",
)
p.write_text(t, encoding="utf-8")
PY
grep -q 'using Xunit.Abstractions;' "$scratch/v3/tests/LegacyShop.Tests/OrderServiceTests.cs"

python3 "$KIT/tests/xunit-v3/apply-transform.py" "$scratch/v3" > /dev/null

# The namespace rewrite really happened (v3 has no Xunit.Abstractions to resolve).
if grep -q 'using Xunit.Abstractions;' "$scratch/v3/tests/LegacyShop.Tests/OrderServiceTests.cs"; then
  echo "FAIL: the transform left 'using Xunit.Abstractions;' in place"; exit 1
fi

v3_out="$scratch/v3-test.log"
if ! dotnet test "$scratch/v3/tests/LegacyShop.Tests/LegacyShop.Tests.csproj" \
     --nologo > "$v3_out" 2>&1; then
  echo "FAIL: the transformed v3 project did not run green:"; tail -25 "$v3_out"; exit 1
fi
count=$(sed -n 's/.*Total: \([0-9][0-9]*\).*/\1/p' "$v3_out" | head -1)
if [ "${count:-0}" -lt "$BASELINE_TESTS" ]; then
  echo "FAIL: v3 ran ${count:-0} tests, baseline is $BASELINE_TESTS — a build is not a test run:"
  tail -25 "$v3_out"; exit 1
fi
echo "  [2] transform -> xunit.v3 runs $count tests (baseline $BASELINE_TESTS), usings rewritten"

# ---------------------------------------------------------------------------
# 3. The OutputType trap is pinned.
#
#    A v3 test project left as a library must never yield a green 6-test run. On
#    xunit.v3 3.2.2 the package guards this itself, failing the BUILD with an   # pinned:xunit-v3
#    explicit message — so what is asserted here is the guard, not a silent 0-test pass. If a
#    future version drops that guard, this assertion still holds: the run must not come back
#    green with the full test count. That is why the counted-tests gate, not this guard, is the
#    contract.
#
#    The claim above used to wrap between the package id and the version, which made it
#    unreadable to any line-based check — the exact shape #90 exists to close — so it was
#    rewrapped rather than excused.
# ---------------------------------------------------------------------------
cp -R "$FIXTURE" "$scratch/trap"
python3 "$KIT/tests/xunit-v3/apply-transform.py" "$scratch/trap" --skip-output-type > /dev/null
grep -q '<OutputType>Exe</OutputType>' "$scratch/trap/tests/LegacyShop.Tests/LegacyShop.Tests.csproj" \
  && { echo "FAIL: --skip-output-type still emitted OutputType"; exit 1; }

trap_out="$scratch/trap-test.log"
if dotnet test "$scratch/trap/tests/LegacyShop.Tests/LegacyShop.Tests.csproj" \
   --nologo > "$trap_out" 2>&1; then
  trap_count=$(sed -n 's/.*Total: \([0-9][0-9]*\).*/\1/p' "$trap_out" | head -1)
  if [ "${trap_count:-0}" -ge "$BASELINE_TESTS" ]; then
    echo "FAIL: a v3 project without OutputType=Exe reported $trap_count tests green."
    echo "      That means the trap is live and undetectable — the counted-tests gate is the"
    echo "      only thing standing between a migration and a test suite that never runs."
    exit 1
  fi
  echo "  [3] no-Exe variant ran ${trap_count:-0} tests (< baseline) — not a green suite"
else
  grep -qi 'OutputType' "$trap_out" || {
    echo "FAIL: the no-Exe variant failed, but not for the OutputType reason:"; tail -20 "$trap_out"; exit 1
  }
  echo "  [3] no-Exe variant is refused at build time by xunit.v3 (OutputType guard)"
fi

# ---------------------------------------------------------------------------
# 4. Coverage still reaches the dashboard.
#
#    This is the half of the migration nothing else would catch. Under MTP the VSTest
#    collector is IGNORED — `dotnet test --collect:"XPlat Code Coverage"` exits 0, passes every
#    test, and writes no coverage file whatsoever (only a MTP0001 warning). The CI step would
#    then upload an empty artifact and report-dashboard.py would render "no coverage" for a
#    migration that is in fact tested. Both halves are pinned here: the hole, and the fix.
# ---------------------------------------------------------------------------
cd "$scratch/v3"

# 4a. The VSTest incantation produces nothing under MTP. If a future SDK makes it work again,
#     this assertion flips and the template's dual path can be simplified — deliberately loud.
#
#     The run must SUCCEED and report its tests first. Swallowing the exit code and only asking
#     "is there a cobertura file?" would let a restore failure or a build break satisfy the pin
#     without the collector ever having run — a green assertion proving nothing.
rm -rf coverage
if ! dotnet test --nologo --collect:"XPlat Code Coverage" --results-directory coverage \
     > "$scratch/vstest-cov.log" 2>&1; then
  echo "FAIL: the VSTest-collector run failed outright, so 4a would pass for the wrong reason:"
  tail -20 "$scratch/vstest-cov.log"; exit 1
fi
vcount=$(sed -n 's/.*Total: \([0-9][0-9]*\).*/\1/p' "$scratch/vstest-cov.log" | head -1)
if [ "${vcount:-0}" -lt "$BASELINE_TESTS" ]; then
  echo "FAIL: 4a ran ${vcount:-0} tests (baseline $BASELINE_TESTS) — the tests must actually run"
  echo "      for 'no coverage file' to mean the collector was ignored."
  tail -20 "$scratch/vstest-cov.log"; exit 1
fi
# Any cobertura, not the old fixed name: were the collector to start working through MTP's own
# writer, the file would carry a generated name and a narrow `-name` would find nothing — this
# canary would then print "pinned" forever while the hole it pins had closed.
if any_match coverage -name '*.cobertura.xml'; then
  echo "NOTE: --collect:\"XPlat Code Coverage\" now yields cobertura under MTP."
  echo "      templates/ci-dotnet.yml can drop its MTP branch — re-check before simplifying."
  exit 1
fi
grep -q 'MTP0001' "$scratch/vstest-cov.log" \
  || echo "  (warning: MTP0001 no longer emitted — the ignore is now fully silent)"
echo "  [4a] VSTest collector yields no cobertura under MTP — the silent hole, pinned"

# 4b. The template's own step puts it back, in coverage/, where the artifact glob already looks.
#     Running the extracted step rather than a copy of it is what makes 4d below a real gate.
MTP_STEP=$(template_step_checked "Tests + couverture")
rm -rf coverage
if ! SOLUTION='' bash -c "$MTP_STEP" > "$scratch/mtp-cov.log" 2>&1; then
  echo "FAIL: the template's coverage step failed outright:"
  tail -25 "$scratch/mtp-cov.log"; exit 1
fi
# first_match rather than `find … | head -1`: under `pipefail` a SIGPIPE'd find returns 141, and a
# find over a `coverage/` the step never created exits non-zero too — either one aborts the script
# AT this assignment, before the diagnostic below can run (#48, #98).
mtp_file=$(first_match coverage -name '*.cobertura.xml')
[ -n "$mtp_file" ] || {
  echo "FAIL: the MTP coverage path produced no cobertura:"; tail -20 "$scratch/mtp-cov.log"; exit 1
}
py_module "$KIT/scripts/report-dashboard.py" "$PWD/$mtp_file" <<'PY'
cov = mod.parse_cobertura(sys.argv[2], [])
covered = sum(c["covered"] for c in cov["classes"])
assert covered > 0, "parse_cobertura read zero covered lines — the dashboard would show nothing"
assert cov["line_pct"] is not None and cov["line_pct"] > 0, f"line_pct is {cov['line_pct']}"
# Branch coverage is read from `condition-coverage`, an attribute this collector happens to
# emit. Asserting it on a REAL report is what would catch the day it stops.
#
# The `is not None` half is load-bearing, not defensive noise: since #50 `branch_pct` is
# Optional[int] — None means "no branch data at all", rendered `n/d` instead of a fabricated 0 %.
# A bare `> 0` would raise TypeError on None and the diagnostic below would never print, which is
# the one moment it is wanted. Checked SEPARATELY from the value so the two failures read
# differently: absent data and zero coverage are not the same event.
assert cov["branch_pct"] is not None, \
    "branch_pct is None on a real MTP report — condition-coverage went missing, and the root " \
    "branch-rate fallback did not cover it either"
assert cov["branch_pct"] > 0, \
    f"branch_pct is {cov['branch_pct']} on a real MTP report — condition-coverage went missing?"
print(f"  [4b] MTP coverage -> cobertura -> parse_cobertura: "
      f"{covered} covered lines, {cov['line_pct']}% line rate")
PY
cd "$KIT"

# 4c. The template carries both paths and refuses to pass silently on an empty coverage dir.
grep -q 'coverage-output-format cobertura' templates/ci-dotnet.yml \
  || { echo "FAIL: templates/ci-dotnet.yml has no MTP coverage path"; exit 1; }
grep -q 'Aucun rapport de couverture' templates/ci-dotnet.yml \
  || { echo "FAIL: templates/ci-dotnet.yml has no guard against an empty coverage report"; exit 1; }
echo "  [4c] templates/ci-dotnet.yml carries the MTP path and the empty-coverage guard"

# ---------------------------------------------------------------------------
# 4d. SEVERAL test projects: one report each, nothing overwritten (issue #17).
#
#     `--coverage-output` names ONE file, and every MTP test app in the solution obeys it —
#     so with N test projects, N-1 reports are overwritten and the survivor is whichever
#     finished last. Measured on this fixture before the fix: the surviving report showed
#     PriceCatalogClient 4/8 and Order/OrderItem/OrderService at 0, i.e. 5 % coverage for a
#     solution whose tests actually cover 73 %. Not a missing number — a WRONG one, plausible
#     enough to publish. That is why this case is pinned with two projects, not one.
# ---------------------------------------------------------------------------
cd "$KIT"
cp -R "$FIXTURE" "$scratch/multi"

# A second test project, exercising the one domain class the first project never touches.
# Written in v2 form and put through the same transform: hard-coding the v3 package versions
# here would drift from apply-transform.py the day either moves.
mkdir -p "$scratch/multi/tests/LegacyShop.Catalog.Tests"
cat > "$scratch/multi/tests/LegacyShop.Catalog.Tests/LegacyShop.Catalog.Tests.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <TargetFramework>net6.0</TargetFramework>
    <IsPackable>false</IsPackable>
  </PropertyGroup>

  <ItemGroup>
    <!-- Mirrors samples/LegacyShop's own frozen v2 stack, restated as an INPUT to this multi-project
         transform test — the three PackageReference lines below are held to renovate.json's
         description of that frozen fixture by the agreed:frozen-* pins in
         scripts/pinned-literals-check.py (#158), not derived from it (samples/ is frozen; nothing
         may derive FROM it, only restate it and agree). -->
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.3.2" /> <!-- agreed:frozen-test-sdk -->
    <PackageReference Include="xunit" Version="2.4.2" /> <!-- agreed:frozen-xunit-core -->
    <PackageReference Include="xunit.runner.visualstudio" Version="2.4.5" /> <!-- agreed:frozen-xunit-runner -->
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\..\src\LegacyShop.Domain\LegacyShop.Domain.csproj" />
  </ItemGroup>

</Project>
XML
cat > "$scratch/multi/tests/LegacyShop.Catalog.Tests/PriceCatalogClientTests.cs" <<'CS'
using System;
using LegacyShop.Domain;
using Xunit;

namespace LegacyShop.Catalog.Tests
{
    public class PriceCatalogClientTests
    {
        [Fact]
        public void DownloadCatalog_RejectsNull()
        {
            var client = new PriceCatalogClient();

            Assert.Throws<ArgumentNullException>(() => client.DownloadCatalog(null));
        }
    }
}
CS
dotnet sln "$scratch/multi/LegacyShop.sln" add \
  "$scratch/multi/tests/LegacyShop.Catalog.Tests/LegacyShop.Catalog.Tests.csproj" > /dev/null
python3 "$KIT/tests/xunit-v3/apply-transform.py" "$scratch/multi" > /dev/null

# Pristine, transformed, not yet built — 4f and 4g mutate a copy each. Taken HERE rather than
# after the run below so they start from a clean tree: a coverage/ or a bin/ carried over from
# this run would let their assertions read yesterday's artefacts.
cp -R "$scratch/multi" "$scratch/pristine"

cd "$scratch/multi"
rm -rf coverage
if ! SOLUTION='' bash -c "$MTP_STEP" > "$scratch/multi-cov.log" 2>&1; then
  echo "FAIL: the template's coverage step failed on a two-test-project solution:"
  tail -25 "$scratch/multi-cov.log"; exit 1
fi
py_module "$KIT/scripts/report-dashboard.py" "$PWD" <<'PY'
import glob

files = sorted(glob.glob(sys.argv[2] + "/coverage/**/*.cobertura.xml", recursive=True))
assert len(files) == 2, f"expected one cobertura per test project, got {len(files)}: {files}"

covered = lambda paths: {c["name"]: c["covered"] for c in mod.parse_cobertura(paths, [])["classes"]}
each, union = [covered(f) for f in files], covered(files)

# Each project contributes a class the other never exercises. The union must hold both...
assert union.get("OrderService", 0) > 0, f"the union lost LegacyShop.Tests' coverage: {union}"
assert union.get("PriceCatalogClient", 0) > 0, \
    f"the union lost LegacyShop.Catalog.Tests' coverage: {union}"
# ...and no SINGLE report may hold both, or the two projects were never really separated and
# the assertion above would pass even with the old overwrite-into-one-file behaviour.
assert not any(r.get("OrderService", 0) > 0 and r.get("PriceCatalogClient", 0) > 0 for r in each), \
    f"one report already covers both projects — this no longer tests the collision: {each}"

solo = [mod.parse_cobertura(f, [])["line_pct"] for f in files]
both = mod.parse_cobertura(files, [])["line_pct"]
assert both > max(solo), \
    f"the aggregate ({both}%) is no better than the best single report ({max(solo)}%)"
print(f"  [4d] 2 test projects -> {len(files)} reports, aggregate {both}% > {max(solo)}% "
      f"(best single) — nothing overwritten")
PY

# 4e. The empty-coverage guard still fires — the fix widened the pattern it searches for, and a
#     guard that silently stopped matching would be worse than the bug it protects against.
GUARD_STEP=$(template_step_checked "Garde — la couverture a bien été produite")
bash -c "$GUARD_STEP" > /dev/null 2>&1 \
  || { echo "FAIL: the guard rejects a coverage/ that DOES hold per-project reports"; exit 1; }
rm -rf coverage && mkdir -p coverage
if bash -c "$GUARD_STEP" > /dev/null 2>&1; then
  echo "FAIL: the guard accepted an empty coverage/ — a silent collection failure would ship"
  exit 1
fi
echo "  [4e] the empty-coverage guard accepts per-project reports and still refuses nothing"
cd "$KIT"

# ---------------------------------------------------------------------------
# 4f. A test project that CANNOT collect coverage must fail the run, not shrink the report set.
#
#     Issue #31 assumed a project missing Microsoft.Testing.Extensions.CodeCoverage would
#     contribute nothing while its siblings still reported — leaving the job green on a union
#     that is quietly partial, the same wrong-answer shape as #17 one level up.
#
#     Measured instead (2026-08-10, SDK 10.0.302, xunit.v3 3.2.2, CodeCoverage 17.14.2):  # pinned:xunit-v3
#     `--coverage` is an option CONTRIBUTED BY that extension, so without it MTP does not skip
#     collection — it refuses the option, `Unknown option '--coverage'`, and the test app exits
#     non-zero. Under the step's `set -euo pipefail` that fails the step outright, before the
#     guard below ever runs. The report set is never silently partial for this cause.
#
#     So the guarantee #31 asked for already holds — but by ACCIDENT of MTP's argument parsing,
#     with nothing pinning it. An MTP release that downgraded an unknown option to a warning
#     would reopen the hole in silence, and the guard could not see it: one healthy sibling's
#     report satisfies a presence check. This case is that pin.
#
#     It asserts the REASON, not merely a non-zero exit. A restore failure or a build break also
#     exits non-zero and would satisfy a bare `if ! …; then` while proving nothing — the trap 4a
#     documents for itself.
# ---------------------------------------------------------------------------
cp -R "$scratch/pristine" "$scratch/nocov"
python3 - "$scratch/nocov/tests/LegacyShop.Catalog.Tests/LegacyShop.Catalog.Tests.csproj" <<'PY'
import re, sys
path = sys.argv[1]
before = open(path, encoding="utf-8").read()
after = re.sub(r'[ \t]*<PackageReference Include="Microsoft\.Testing\.Extensions\.CodeCoverage"[^\n]*\n',
               '', before)
if after == before:
    sys.exit("no Microsoft.Testing.Extensions.CodeCoverage reference to remove — apply-transform.py "
             "changed shape, and this case would silently test the healthy configuration instead")
open(path, "w", encoding="utf-8").write(after)
PY

cd "$scratch/nocov"
rm -rf coverage
if SOLUTION='' bash -c "$MTP_STEP" > "$scratch/nocov.log" 2>&1; then
  echo "FAIL: the coverage step SUCCEEDED with a test project that cannot collect coverage."
  echo "      #31's hole is then real: green run, silently partial report set. Reports written:"
  echo "      $(find coverage -name '*.cobertura.xml' | wc -l | tr -d ' ') for 2 test projects."
  echo "      The guard cannot catch this — one sibling's report satisfies a presence check."
  tail -20 "$scratch/nocov.log"; exit 1
fi
# The console names the log but not the reason; MTP writes the reason there, in UTF-16.
nocov_detail=$(first_match "$scratch/nocov" -name 'LegacyShop.Catalog.Tests_*.log')
[ -n "$nocov_detail" ] || {
  echo "FAIL: the run failed but MTP wrote no per-project log, so the reason cannot be checked:"
  tail -20 "$scratch/nocov.log"; exit 1; }
python3 - "$nocov_detail" <<'PY'
import sys
raw = open(sys.argv[1], "rb").read()
# Chosen by BOM, never by trial decoding. `raw.decode("utf-16")` does NOT raise on UTF-8 input of
# even length — it returns mojibake — so a try/except chain that puts utf-16 first silently turns
# a readable log into garbage the marker can never be found in, and the case then fails claiming
# the wrong reason. MTP writes UTF-16-LE with a BOM (measured: b"\xff\xfe"); anything else is
# read as UTF-8.
if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
    text = raw.decode("utf-16")
else:
    text = raw.decode("utf-8", errors="replace")
if "Unknown option '--coverage'" not in text:
    sys.exit("the step failed, but NOT because --coverage was refused. A restore failure or a "
             "build break exits non-zero too, so this case would pass for the wrong reason and "
             "stop pinning anything. First 30 lines of MTP's log:\n\n"
             + "\n".join(text.splitlines()[:30]))
PY
echo "  [4f] a test project without the coverage extension is REFUSED (--coverage unknown), not"
echo "       quietly dropped from the report set"
cd "$KIT"

# ---------------------------------------------------------------------------
# 4g. The other candidate cause of a partial report set — a project that runs ZERO tests — also
#     fails the run, and does not even produce a shortfall.
#
#     #31 named this as the cause that would survive if the missing-extension one turned out to
#     be covered. Measured, it is covered twice over: MTP treats "ran 0 tests" as a failure of
#     that test app (`Failed! - Failed: 0, Passed: 0, Skipped: 0, Total: 0`), AND the app still
#     writes its coverage report — so the report count never falls short in the first place.
#
#     Both halves are asserted. The report count matters as much as the exit status: it is the
#     evidence that a count-based guard would have had nothing to catch here, which is the
#     measurement the template's guard comment cites.
# ---------------------------------------------------------------------------
cp -R "$scratch/pristine" "$scratch/zerotests"
python3 - "$scratch/zerotests/tests/LegacyShop.Catalog.Tests/PriceCatalogClientTests.cs" <<'PY'
import sys
path = sys.argv[1]
before = open(path, encoding="utf-8").read()
# Drop the attribute, keep the method: the project still compiles and still references xunit.v3,
# so it is a test app that discovers nothing — not a project that failed to build.
after = before.replace("        [Fact]\n", "")
if after == before:
    sys.exit("no [Fact] attribute to remove — this case would silently test a healthy project")
open(path, "w", encoding="utf-8").write(after)
PY

cd "$scratch/zerotests"
rm -rf coverage
if SOLUTION='' bash -c "$MTP_STEP" > "$scratch/zerotests.log" 2>&1; then
  echo "FAIL: the coverage step SUCCEEDED with a test project that discovers zero tests."
  echo "      A suite that silently stopped running would then ship green."
  tail -20 "$scratch/zerotests.log"; exit 1
fi
grep -q 'Total: 0' "$scratch/zerotests.log" || {
  echo "FAIL: the step failed, but no project reported 'Total: 0' — so it failed for some other"
  echo "      reason and this case pins nothing:"; tail -20 "$scratch/zerotests.log"; exit 1; }
# The half that decides the template's guard shape: no shortfall to count.
zero_reports=$(find coverage -name '*.cobertura.xml' | grep -c . || true)
if [ "$zero_reports" -ne 2 ]; then
  echo "FAIL: a zero-test project now yields $zero_reports report(s) for 2 test projects, where it"
  echo "      used to yield 2. This cause has BECOME a shortfall, so the reasoning recorded on the"
  echo "      guard in templates/ci-dotnet.yml (presence, not count) needs re-measuring — see #31."
  exit 1
fi
echo "  [4g] a zero-test project FAILS the run and still writes its report — never a shortfall"
cd "$KIT"

# ---------------------------------------------------------------------------
# 4h. `$mtp` OVER-COUNTS: it matches csproj files that are not test applications.
#
#     This is the second half of the reasoning recorded on the guard in templates/ci-dotnet.yml,
#     and the one that decides its SHAPE. 4f and 4g show there is no silent shortfall left to
#     catch; this case shows that catching one by counting would refuse a healthy repo.
#
#     A shared test-helper library — a custom FactAttribute, common fixtures, assertion helpers —
#     references xunit.v3, so the discovery grep matches it. It is not a test application, so
#     `dotnet test` correctly never runs it and it never writes a report. Expected 2, actual 1,
#     run perfectly green. `>=` does not rescue that: the defect is in the SOURCE of the expected
#     number, not in the comparison.
#
#     The discovery line is taken FROM THE TEMPLATE rather than retyped. That is the whole point:
#     narrowing that grep is exactly the change that would make a count viable, and this case has
#     to be what notices. A hand-copied grep would keep asserting yesterday's behaviour while the
#     justification on the guard went stale in silence — the trap 4b/4d already document for the
#     step itself.
# ---------------------------------------------------------------------------
cp -R "$FIXTURE" "$scratch/helperlib"
python3 "$KIT/tests/xunit-v3/apply-transform.py" "$scratch/helperlib" > /dev/null
mkdir -p "$scratch/helperlib/tests/LegacyShop.Testing.Common"
cat > "$scratch/helperlib/tests/LegacyShop.Testing.Common/LegacyShop.Testing.Common.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <IsPackable>false</IsPackable>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="xunit.v3" Version="3.2.2" />
  </ItemGroup>
</Project>
XML
cat > "$scratch/helperlib/tests/LegacyShop.Testing.Common/Attributes.cs" <<'CS'
using Xunit;

namespace LegacyShop.Testing.Common
{
    // Shared helper: cites xunit.v3, is deliberately NOT a test application (no OutputType=Exe,
    // no TestingPlatformDotnetTestSupport). The discovery grep cannot tell the difference.
    public sealed class IntegrationFactAttribute : FactAttribute
    {
    }
}
CS
dotnet sln "$scratch/helperlib/LegacyShop.sln" add \
  "$scratch/helperlib/tests/LegacyShop.Testing.Common/LegacyShop.Testing.Common.csproj" > /dev/null

# The template's own project-discovery line, sliced out instead of retyped.
mtp_line=$(grep -E '^[[:space:]]*mtp=\$\(grep ' "$KIT/templates/ci-dotnet.yml" | sed 's/^[[:space:]]*//')
[ -n "$mtp_line" ] || {
  echo "FAIL: no 'mtp=\$(grep …)' discovery line in templates/ci-dotnet.yml — 4h cannot compare"
  echo "      against the template's real grep, so it would prove nothing."; exit 1; }

cd "$scratch/helperlib"
rm -rf coverage
if ! SOLUTION='' bash -c "$MTP_STEP" > "$scratch/helperlib.log" 2>&1; then
  echo "FAIL: the coverage step failed on a solution that is merely carrying a test-helper library."
  echo "      That library is not a test app; nothing here should refuse it:"
  tail -25 "$scratch/helperlib.log"; exit 1
fi
eval "$mtp_line"                       # sets $mtp, exactly as the template's step does
helper_expected=$(printf '%s\n' "$mtp" | grep -c . || true)
helper_actual=$(find coverage -name '*.cobertura.xml' | grep -c . || true)
if [ "$helper_expected" -eq "$helper_actual" ]; then
  echo "FAIL: the discovery grep no longer over-counts — it reports $helper_expected project(s) for"
  echo "      $helper_actual report(s) on a solution holding a non-test xunit.v3 library."
  echo "      Point 2 of the guard's rationale in templates/ci-dotnet.yml has stopped being true:"
  echo "      a count-based guard may now be viable, so re-measure before trusting that comment."
  printf '%s\n' "$mtp" | sed 's/^/        /'
  exit 1
fi
echo "  [4h] a shared xunit.v3 helper library makes \$mtp claim $helper_expected project(s) for"
echo "       $helper_actual report(s) on a GREEN run — counting would refuse a healthy repo"
cd "$KIT"

# ---------------------------------------------------------------------------
# 5. The decision is wired into the pipeline, not just documented in a side file.
#
#    A reference nobody is routed to is a reference nobody reads: phase 1 must surface the line,
#    phase 5 must own the gated item, and phase 6 must make the result land in the report.
# ---------------------------------------------------------------------------
grep -q 'xunitMajor' skills/migrate-legacy/references/phase-1-assess.md \
  || { echo "FAIL: phase-1-assess.md does not record the xunit major line"; exit 1; }
grep -q 'xunit-v3-migration.md' skills/migrate-legacy/references/phase-5-modernize.md \
  || { echo "FAIL: phase-5-modernize.md does not route to xunit-v3-migration.md"; exit 1; }
grep -qi 'baseline' skills/migrate-legacy/references/phase-5-modernize.md \
  || { echo "FAIL: phase-5-modernize.md states no counted-tests gate"; exit 1; }
grep -qi 'test platform\|plateforme de test' skills/migrate-legacy/references/phase-6-verify.md \
  || { echo "FAIL: phase-6-verify.md does not record the test platform"; exit 1; }
grep -qi 'test platform\|plateforme de test' skills/migrate-legacy/references/report-template.md \
  || { echo "FAIL: report-template.md has no slot for the test platform"; exit 1; }
echo "  [5] phases 1, 5 and 6 carry the decision, the route and the recorded outcome"

# ---------------------------------------------------------------------------
# 6. Project shapes the fixture does not have.
#
#    The fixture is one tidy SDK-style csproj with self-closing PackageReferences and two-space
#    indentation. Every assertion above would still pass if the tools only worked on THAT shape.
#    These cases came out of code review, each having silently produced a wrong result:
#    a surviving VSTest adapter, a transform that did nothing, a dropped target framework, an
#    invisible legacy test project, and a null major line under central package management.
# ---------------------------------------------------------------------------
shapes="$scratch/shapes"
mkdir -p "$shapes"

# 6a. `dotnet new xunit` writes the adapter in ELEMENT form with <PrivateAssets> children.
mkdir -p "$shapes/element/p"
cat > "$shapes/element/p/p.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="xunit" Version="2.9.3" />
    <PackageReference Include="xunit.runner.visualstudio" Version="3.1.1">
      <PrivateAssets>all</PrivateAssets>
      <IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
    </PackageReference>
    <PackageReference Include="coverlet.collector" Version="6.0.2">
      <PrivateAssets>all</PrivateAssets>
    </PackageReference>
  </ItemGroup>
</Project>
XML
python3 "$KIT/tests/xunit-v3/apply-transform.py" "$shapes/element" > /dev/null
if grep -q 'xunit.runner.visualstudio\|coverlet.collector' "$shapes/element/p/p.csproj"; then
  echo "FAIL: element-form VSTest packages survived — half-swapped test host:"
  cat "$shapes/element/p/p.csproj"; exit 1
fi
grep -q '<OutputType>Exe</OutputType>' "$shapes/element/p/p.csproj" || {
  echo "FAIL: element-form project got no OutputType"; exit 1; }

# 6b. A csproj that is not indented two spaces must not silently skip the properties.
mkdir -p "$shapes/flat/p"
cat > "$shapes/flat/p/p.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
<PropertyGroup>
<TargetFramework>net8.0</TargetFramework>
</PropertyGroup>
<ItemGroup>
<PackageReference Include="xunit" Version="2.9.3" />
</ItemGroup>
</Project>
XML
python3 "$KIT/tests/xunit-v3/apply-transform.py" "$shapes/flat" > /dev/null
for needle in '<OutputType>Exe</OutputType>' 'TestingPlatformDotnetTestSupport' 'xunit.v3'; do
  grep -q "$needle" "$shapes/flat/p/p.csproj" || {
    echo "FAIL: unindented csproj lost '$needle' — the transform no-opped and claimed success:"
    cat "$shapes/flat/p/p.csproj"; exit 1; }
done

# 6c. Multi-targeting must survive: only the legs below the v3 floor move.
mkdir -p "$shapes/multi/p"
cat > "$shapes/multi/p/p.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFrameworks>net6.0;net8.0</TargetFrameworks>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="xunit" Version="2.9.3" />
  </ItemGroup>
</Project>
XML
python3 "$KIT/tests/xunit-v3/apply-transform.py" "$shapes/multi" > /dev/null
grep -q '<TargetFrameworks>net10.0;net8.0</TargetFrameworks>' "$shapes/multi/p/p.csproj" || {
  echo "FAIL: multi-targeting was collapsed — a published library would lose a target:"
  grep TargetFramework "$shapes/multi/p/p.csproj"; exit 1; }

# 6d. A packages.config test project (legacy .NET Framework — the kit's core audience) must
#     appear in testStack, not vanish behind an empty PackageReference list.
mkdir -p "$shapes/legacy/tests"
cat > "$shapes/legacy/tests/Legacy.Tests.csproj" <<'XML'
<Project ToolsVersion="12.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <TargetFrameworkVersion>v4.7.2</TargetFrameworkVersion>
  </PropertyGroup>
</Project>
XML
cat > "$shapes/legacy/tests/packages.config" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<packages>
  <package id="xunit" version="2.4.1" targetFramework="net472" />
  <package id="xunit.runner.visualstudio" version="2.4.3" targetFramework="net472" />
</packages>
XML
legacy_inv=$("$KIT/scripts/audit-inventory.sh" "$shapes/legacy")
python3 - "$legacy_inv" <<'PY'
import json, sys
stack = json.loads(sys.argv[1]).get("testStack", [])
assert len(stack) == 1, f"packages.config test project invisible in testStack: {stack}"
assert stack[0]["xunitMajor"] == 2, stack[0]
assert stack[0]["packageSource"] == "packages.config", stack[0]
PY

# 6e. Central package management: the version lives in Directory.Packages.props, so a
#     Version-less PackageReference must still yield a major line.
mkdir -p "$shapes/cpm/tests"
cat > "$shapes/cpm/Directory.Packages.props" <<'XML'
<Project>
  <ItemGroup>
    <PackageVersion Include="xunit" Version="2.9.3" />
  </ItemGroup>
</Project>
XML
cat > "$shapes/cpm/tests/Cpm.Tests.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="xunit" />
  </ItemGroup>
</Project>
XML
cpm_inv=$("$KIT/scripts/audit-inventory.sh" "$shapes/cpm")
python3 - "$cpm_inv" <<'PY'
import json, sys
stack = json.loads(sys.argv[1]).get("testStack", [])
assert len(stack) == 1, stack
assert stack[0]["xunitMajor"] == 2, \
    f"CPM version unresolved -> xunitMajor {stack[0]['xunitMajor']}; phase 5 would read 'not applicable'"
PY
echo "  [6] element-form refs, flat indent, multi-TFM, packages.config and CPM all handled"

# 6f. The template refuses a half-migrated repo instead of silently losing half its coverage.
grep -q 'Dépôt MIXTE' templates/ci-dotnet.yml \
  || { echo "FAIL: templates/ci-dotnet.yml does not detect a mixed MTP/VSTest repo"; exit 1; }
echo "  [6f] templates/ci-dotnet.yml refuses a mixed MTP/VSTest repo"

# ---------------------------------------------------------------------------
# 7. The xunit.v3 / CodeCoverage pairing is machine-checked, not remembered.
#
#    The two pinned versions must sit on the same Microsoft.Testing.Platform line, and a mismatch
#    is invisible to every static check: it restores, it compiles, and it dies at RUN time with
#    `TypeLoadException: Could not load type '…IDataConsumer'`. Section 2 would catch it — it
#    executes the tests — but only as a stack trace, which is an expensive way to rediscover a
#    known rule. So the transform states the rule and refuses up front, naming both versions.
# ---------------------------------------------------------------------------
read_const() {  # print one of the transform's constants
  py_module "$KIT/tests/xunit-v3/apply-transform.py" "$1" <<'PY'
print(getattr(mod, sys.argv[2]))
PY
}
xunit_version=$(read_const XUNIT_V3_VERSION)

# Read the pin ONCE; both probe versions below are derived from it, never typed.
pinned_coverage=$(read_const COVERAGE_EXT_VERSION)
pinned_major=${pinned_coverage%%.*}

# The bad version is DERIVED, never hardcoded: one major above whatever the kit currently pins is
# a mismatch by construction, on today's 3.x/17.x pairing and on every future one. A literal
# "18.0.0" here would quietly become the *correct* partner the day xunit.v3 moves to 4.x, and this
# assertion would then fail for a reason that has nothing to do with what it is testing.
bad_coverage="$(( pinned_major + 1 )).0.0"

# 7c's probe, by contrast, must stay on the SAME major as the pin: it tests that an ambient value is
# ignored, and the interesting case is the silent one — a stray value that validate_pairing would
# happily accept. A cross-major literal would instead be REFUSED, aborting the run under `set -e`
# before the assertion could speak, and proving something else entirely.
#
# Derived from the pin by SUFFIX so it can never coincide with it: a bare "$pinned_major.0.99" would
# equal the pin the day the pin becomes 17.0.99, and 7c would then blame environment leakage for a
# value the script itself chose.
ambient_coverage="$pinned_coverage-ambient"

mkdir -p "$shapes/pairing/p"
cat > "$shapes/pairing/p/p.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="xunit" Version="2.9.3" />
  </ItemGroup>
</Project>
XML
cp "$shapes/pairing/p/p.csproj" "$scratch/pairing-before.csproj"

# 7a. A deliberately mismatched pair must be refused, non-zero, before anything is written.
pair_log="$scratch/pairing.log"
if python3 "$KIT/tests/xunit-v3/apply-transform.py" "$shapes/pairing" \
     --coverage-version "$bad_coverage" > "$pair_log" 2>&1; then
  echo "FAIL: the transform accepted CodeCoverage $bad_coverage alongside xunit.v3 $xunit_version."
  echo "      That pair builds clean and dies at run time — the mismatch must be refused here."
  exit 1
fi
# Establish WHICH refusal fired before asserting what it says: an unknown-package-id refusal names
# only the id, so without this the next reader is sent after a message-formatting bug when the real
# defect is a missing MTP_LINE entry.
grep -qF 'incompatible test platform pair' "$pair_log" || {
  echo "FAIL: the transform refused, but not for the pairing reason — the mismatch branch never"
  echo "      ran, so nothing here proves the pairing is checked:"; cat "$pair_log"; exit 1; }
for needle in "$xunit_version" "$bad_coverage"; do
  grep -qF "$needle" "$pair_log" || {
    echo "FAIL: the refusal does not name '$needle' — it must state BOTH versions, or the next"
    echo "      reader is back to diagnosing a TypeLoadException:"; cat "$pair_log"; exit 1; }
done
cmp -s "$shapes/pairing/p/p.csproj" "$scratch/pairing-before.csproj" || {
  echo "FAIL: the bad pair was refused, but only after rewriting the csproj — the check must"
  echo "      run before the transform touches anything."; exit 1; }

# 7b. The map is the contract: the pinned pair satisfies it, and an unmapped major says so
#     instead of guessing a compatible extension.
py_module "$KIT/tests/xunit-v3/apply-transform.py" <<'PY'
# The package/version this kit actually pins agree with the map.
mod.validate_pairing(mod.XUNIT_V3_PACKAGE, mod.COVERAGE_EXT_VERSION)

# The DEFAULT package is the coverage extension — the one the transform writes — so the call with no
# `package=` must behave exactly as the explicit one does. (The version pairs themselves are owned by
# the family table below; duplicating them here would mean keeping two tables in sync by hand.)
mod.validate_pairing("xunit.v3", "17.14.2")  # implicit default package, no package= kwarg
try:
    mod.validate_pairing("xunit.v3", "18.9.0")
except ValueError:
    pass
else:
    raise AssertionError("the default package argument does not check CodeCoverage")

# The rule is keyed on the PACKAGE ID, not the major: `xunit.v3` and `xunit.v3.mtp-v2` are both on
# major 3 today and sit on opposite MTP lines (measured: xunit.v3 3.2.2 -> MTP 1.9.1,  # pinned:xunit-v3
# xunit.v3.mtp-v2 3.2.2 -> MTP 2.0.2), so a version-keyed map would invert every pair below.
#
# The rest of the Microsoft.Testing family splits at the SAME v1/v2 boundary but versions AS the
# platform line (1.x / 2.x). CodeCoverage is the outlier at 17.x / 18.x, inherited from its VSTest
# ancestry — so a model that assumed one numbering would be wrong for whichever group it did not
# describe. Pin both groups, both directions.
for pkg, v1_ok, v2_ok in (
    ("Microsoft.Testing.Extensions.CodeCoverage", "17.14.2", "18.9.0"),
    ("Microsoft.Testing.Extensions.TrxReport.Abstractions", "1.9.1", "2.0.2"),
    ("Microsoft.Testing.Platform", "1.9.1", "2.0.2"),
):
    mod.validate_pairing("xunit.v3", v1_ok, package=pkg)
    mod.validate_pairing("xunit.v3.mtp-v2", v2_ok, package=pkg)
    for xunit_pkg, wrong in (("xunit.v3", v2_ok), ("xunit.v3.mtp-v2", v1_ok)):
        try:
            mod.validate_pairing(xunit_pkg, wrong, package=pkg)
        except ValueError:
            pass
        else:
            raise AssertionError(f"{xunit_pkg} accepted {pkg} {wrong} — it crosses the MTP boundary")

# An extension nobody has enumerated follows the line rather than being refused: refusing here would
# block packages that are perfectly fine, which is the opposite of helpful.
mod.validate_pairing("xunit.v3", "1.0.0", package="Microsoft.Testing.Extensions.NotYetInvented")
mod.validate_pairing("xunit.v3.mtp-v2", "2.0.0", package="Microsoft.Testing.Extensions.NotYetInvented")

# NuGet package ids are case-INSENSITIVE, and these are read out of real csproj text. A lower-case
# spelling of the coverage extension must hit the SAME override, not fall through to the permissive
# branch — falling through would invert the guard for that spelling.
mod.validate_pairing("xunit.v3", "17.14.2", package="microsoft.testing.extensions.codecoverage")
try:
    mod.validate_pairing("xunit.v3", "1.0.0", package="MICROSOFT.TESTING.EXTENSIONS.CODECOVERAGE")
except ValueError:
    pass
else:
    raise AssertionError("a case variant of the coverage extension bypassed EXTENSION_MAJOR")

# Adding an MTP line to MTP_LINE alone must NOT silently give an enumerated exception the platform's
# numbering — a package is listed in EXTENSION_MAJOR precisely because it does not follow it.
saved = dict(mod.MTP_LINE)
try:
    mod.MTP_LINE["xunit.v3.mtp-v3"] = 3
    try:
        mod.validate_pairing("xunit.v3.mtp-v3", "3.0.0")
    except ValueError as exc:
        assert "EXTENSION_MAJOR" in str(exc), f"wrong refusal for an unenumerated line: {exc}"
    else:
        raise AssertionError("a new MTP line silently gave CodeCoverage the platform numbering")
finally:
    mod.MTP_LINE.clear()
    mod.MTP_LINE.update(saved)

# A package id nobody has mapped must be named as such, not silently assumed compatible. Assert on
# a substring unique to THAT branch: both refusals mention the map, so matching on the map name
# alone would keep passing if this case started taking the mismatch branch instead.
try:
    mod.validate_pairing("xunit.v3.mtp-v99", mod.COVERAGE_EXT_VERSION)
except ValueError as exc:
    assert "unknown xunit.v3 package id" in str(exc), f"wrong refusal branch: {exc}"
else:
    raise AssertionError("an unmapped xunit.v3 package id was accepted — the map would be bypassed")
PY
echo "  [7] the MTP/coverage pairing is enforced by the transform, not by memory"

# 7c. Nothing in the environment steers the transform — the override is the FLAG and only the flag.
#
#     Two checks, deliberately at different depths. The static one is the general rule and the one
#     that survives: it holds for every knob anyone adds later, not just this variable. The
#     end-to-end one is the witness that the rule is true of the shipped script as invoked.
#
#     Why it matters: the reference points agents at this script as the executable form of the
#     transform, so a value left in a shell — or in a CI env block — would otherwise redirect a real
#     migration onto a version nobody chose. Worst when it shares the expected major, because
#     validate_pairing then accepts it and the substitution is completely silent.
mkdir -p "$shapes/ambient/p"
cp "$scratch/pairing-before.csproj" "$shapes/ambient/p/p.csproj"
# One-shot prefix, not export/unset: the variable exists only for the child that is meant to see it,
# there is no window in which `set -e` can skip an `unset`, and the caller's own environment is left
# exactly as it was.
XUNIT_V3_COVERAGE_VERSION="$ambient_coverage" \
  python3 "$KIT/tests/xunit-v3/apply-transform.py" "$shapes/ambient" > /dev/null
if grep -qF "$ambient_coverage" "$shapes/ambient/p/p.csproj"; then
  echo "FAIL: an ambient XUNIT_V3_COVERAGE_VERSION ($ambient_coverage) reached the csproj — the"
  echo "      environment must not steer a hand-run transform:"
  grep CodeCoverage "$shapes/ambient/p/p.csproj"; exit 1
fi
grep -qF "$pinned_coverage" "$shapes/ambient/p/p.csproj" || {
  echo "FAIL: the transform did not write its pinned coverage version ($pinned_coverage):"
  grep CodeCoverage "$shapes/ambient/p/p.csproj"; exit 1; }
echo "  [7c] no ambient value steers the transform — overrides are flags only"

#     [7d] `--help` describes the package the transform actually writes.
#
#     renovate.json claims "the transform writes COVERAGE_PACKAGE rather than a literal, so all
#     three move together or the suite fails". That was true of the two spellings the transform
#     WRITES and false of the one it DISPLAYS: the argparse help text carried its own copy of the
#     package id (#69). Nothing compared them, so renaming the constant would leave `--help`
#     describing a package the script no longer touches.
#
#     Asserted against the id read from the module, never against a literal here — a literal in the
#     test would be a fourth copy with the same problem.
#
#     The environment is pinned for two terminal-shaped reasons, neither of which is about the
#     property under test: COLUMNS, because argparse wraps to the terminal width and a narrow one
#     would split the package id across two lines; NO_COLOR, because argparse began colorizing help
#     in Python 3.14 and emits escapes even through a pipe — today only the usage line and option
#     names are colored, but any extension of that into the help body would break these greps.
#
#     Assignments, not argument-position command substitutions: `set -e` does NOT propagate a
#     failing $(...) used as an argument, so a renamed constant would silently pass an empty string
#     and this block would blame the help text for a defect in the module.
coverage_package=$(read_const COVERAGE_PACKAGE)
coverage_version=$(read_const COVERAGE_EXT_VERSION)
help_text=$(COLUMNS=200 NO_COLOR=1 python3 "$TRANSFORM" --help)
grep -qF "$coverage_package" <<<"$help_text" || {
  echo "FAIL: --help never names $coverage_package, the package the transform writes:"
  printf '%s\n' "$help_text" | grep -i 'coverage' ; exit 1; }
# The VERSION too, and this half is load-bearing: the module docstring tells the reader to run
# --help to learn the pinned value, which is only true while `%(default)s` is in the help string.
# Deleting it would leave that pointer leading nowhere — silently, since the id check above would
# still pass.
grep -qF "$coverage_version" <<<"$help_text" || {
  echo "FAIL: --help never prints the pinned version $coverage_version. The module docstring"
  echo "      points readers here for it, so the help string needs '%(default)s':"
  printf '%s\n' "$help_text" | grep -i 'coverage-version' ; exit 1; }
# And no OTHER Microsoft.Testing.* id: a stale hardcoded name would still satisfy the check above
# if it happened to sit alongside the derived one. The class allows digits — CodeCoverage2 would
# otherwise leave a truncated prefix looking like a stale id and fail wholly-derived help text.
# `|| true` sits INSIDE the pipeline, on EACH grep that legitimately exits 1 (the file's idiom, see
# the knobs count above) — on the whole pipeline it would also swallow a real failure of grep or
# sort under pipefail. Both greps return 1 on the PASSING path: the first when the help names no
# Microsoft.Testing.* id at all, the second when every id it found is the expected one.
stale_ids=$( { grep -oE 'Microsoft\.Testing\.[A-Za-z0-9.]+' <<<"$help_text" || true; } \
             | { grep -vxF "$coverage_package" || true; } | sort -u)
[ -z "$stale_ids" ] || {
  echo "FAIL: --help names package id(s) other than $coverage_package: $stale_ids"; exit 1; }
echo "  [7d] --help names the coverage package and version the transform writes, and no other id"

#     [7e] The reference's measured table still has the SHAPE this suite can check, and still
#     names the pinned package.
#
#     #158 split what this section used to do into two halves and gave each ONE owner:
#       - VERSION AGREEMENT — every "<pinned package> <version>" claim across this module and the
#         migration reference agreeing with XUNIT_V3_VERSION — is now scripts/pinned-literals-
#         check.py's job alone (marked lines held to the constant, unmarked ones refused). Duplicating
#         that sweep here meant two mechanisms that could disagree about the SAME invariant; #158's
#         issue named that overlap directly. Removed, not weakened: pinned-literals-check.py runs in
#         CI on every suite, same as this file.
#       - TABLE SHAPE — the reference's measured table must still be a table this suite's other
#         readers (and a migrating agent) can parse, and it must still be ABOUT the package this
#         kit pins. Neither is a version-agreement question: a reshaped table could still agree with
#         the constant on every cell and still be unreadable, which pinned-literals-check.py's
#         line-oriented scan would never notice. That half stays, here.
xunit_package=$(read_const XUNIT_V3_PACKAGE)
python3 - "$xunit_package" "$KIT/skills/migrate-legacy/references/xunit-v3-migration.md" <<'PY'
import os, re, sys

pkg, path = sys.argv[1], sys.argv[2]


def die(msg):
    # NOT `assert`: under python3 -O every assert in this block would vanish while the success
    # line below still printed, reporting a comparison that never happened. This suite treats a
    # false green as the one outcome worse than failing.
    sys.exit(f"FAIL: {msg}")


if not os.path.isfile(path):
    die(f"{path} does not exist — this guard would check nothing. It was moved or renamed; "
        f"re-point it rather than dropping it.")
text = open(path, encoding="utf-8").read()

# The reference's measured table is the load-bearing one, so its SHAPE is pinned: were it
# reshaped, scripts/pinned-literals-check.py's line-oriented scan would quietly find nothing to
# hold to the constant and pass, which is exactly the blind spot this half exists to close.
rows = re.findall(r"^\|\s*\*\*`([^`]+)`\*\*\s+([^\s|]+)\s*\|", text, re.M)
names = [n for n, _ in rows]
if not rows:
    die(f"{path}: the measured version table no longer has the shape this check "
        f"understands (`| **`<package>`** <version> | …`) — re-point this assertion.")
if len(names) != len(set(names)):
    # dict() would silently keep the last, letting a historical table decide the verdict.
    die(f"{path}: the same package appears in more than one measured row {names}; this "
        f"check cannot tell which one is current.")
if pkg not in names:
    die(f"{path}: the measured table covers {sorted(names)}, but the transform pins "
        f"{pkg} — the reference no longer describes the line the kit migrates onto.")

print(f"  [7e] the migration reference's measured table still names {pkg} and parses as a table")
PY

# ---------------------------------------------------------------------------
# 8. The no-__pycache__ invariant lives in exactly one place ACROSS tests/ AND scripts/.
#
#    Loading a kit script through importlib compiles it, and without
#    PYTHONDONTWRITEBYTECODE that drops a __pycache__ next to it — which the no_pycache guard
#    turns into a suite-wide failure, for a reason unrelated to whatever was being tested. The
#    prefix is therefore load-bearing and invisible at the call site, which is exactly the shape
#    that gets lost in a copy-paste. One loader, asserted here, so a new call site cannot
#    reintroduce it.
#
#    #42 could only claim this for THIS FILE, and said so rather than overstating it: the grep
#    read $SELF alone, while tests/report-dashboard/test.sh carried a second loader for its own
#    module. That copy was correct — it did carry the prefix — but nothing asserted it, so an edit
#    dropping the prefix would have stranded a __pycache__ under scripts/ and surfaced it in THIS
#    suite's exit guard, naming a file this suite never touches. Misdirection of exactly the kind
#    section 8 exists to prevent, one directory over (#51).
#
#    So the scope is now tests/ and scripts/, and the single definition must live in the shared
#    helper. Both halves matter: a count alone would be satisfied by any one file keeping a
#    private loader, which is the arrangement this replaced.
# ---------------------------------------------------------------------------
#    The `[l]` is not a typo: it keeps this grep from counting its own pattern — including in this
#    very file, which the recursive scan now reads — so the assertion measures the kit's loaders
#    rather than itself.
#    `|| true` because `grep` exits 1 when there is no match, and under `set -e` an assignment from
#    a failing substitution kills the script — so the one case this block exists to describe (the
#    loader removed or renamed) would abort with no output at all, right where the message is the
#    entire point. The paths are relative to the kit root this script cd'd to before anything else,
#    which is also what makes the reported paths match $LOADER_HOME verbatim.
#
#    Scanned through $KIT — ABSOLUTE — and not through the relative `tests scripts`. The property
#    the old $SELF spelling had, and that a relative operand silently gives up: this suite cd's
#    into scratch copies five times below and only happens to cd back each time. The first section
#    that leaves the cwd elsewhere would make this grep read a scratch tree, or error to stderr —
#    and with `|| true` that reads as ZERO loaders, i.e. a FAIL blaming a removal that never
#    happened. The `$KIT/` prefix is stripped back off before comparing, so $LOADER_HOME stays a
#    repo-relative path a reader can open.
#
#    The pattern is one literal spelling — `spec_from_file_[l]ocation`, bracketed here for the very
#    reason this section exists — and the claim is scoped to match: it is the only loader idiom the
#    kit uses. `__import__`, `importlib.import_module` after
#    a sys.path insert, and runpy would each write bytecode without tripping this grep. Saying so
#    here rather than pretending otherwise is the same honesty #42 applied to its own narrower
#    scope — and broadening the pattern is a follow-up, not a silent widening of a claim.
LOADER_HOME="tests/_lib/py.sh"
loader_sites=$( { grep -rn 'spec_from_file_[l]ocation' "$KIT/tests" "$KIT/scripts" || true; } \
  | sed "s|^$KIT/||")
loaders=$(printf '%s' "$loader_sites" | { grep -c . || true; })
if [ "$loaders" -ne 1 ] || [ "${loader_sites%%:*}" != "$LOADER_HOME" ]; then
  echo "FAIL: $loaders copy/copies of the importlib loader under tests/ and scripts/ — expected"
  echo "      exactly 1, in $LOADER_HOME."
  echo "      Every Python snippet that loads a kit script must go through py_module(), which"
  echo "      carries PYTHONDONTWRITEBYTECODE=1. A copy without it drops a __pycache__ beside the"
  echo "      script it loaded and turns some suite red for a reason unrelated to what it tests:"
  printf '%s\n' "${loader_sites:-  (none found — the loader was removed or renamed)}"
  exit 1
fi
echo "  [8] one module loader, in $LOADER_HOME, carries the no-__pycache__ invariant"

# ---------------------------------------------------------------------------
# 9. Renovate can actually SEE the two pins the transform writes.
#
#    The packageRules that keep the MTP family on one line only fire on updates Renovate proposes,
#    and it proposes nothing it cannot parse: these versions are Python string literals, and no
#    stock manager reads `.py`. A customManagers regex is what puts them in view — but a regex in
#    JSON is exactly the kind of thing that silently stops matching when a constant is renamed, and
#    nothing would say so. So the regexes are not merely declared here, they are EXECUTED against
#    the real file, and must find the versions the module actually reports.
# ---------------------------------------------------------------------------
python3 - "$KIT/renovate.json" "$TRANSFORM" "$(read_const XUNIT_V3_PACKAGE)" \
         "$(read_const XUNIT_V3_VERSION)" "$(read_const COVERAGE_PACKAGE)" \
         "$(read_const COVERAGE_EXT_VERSION)" <<'PY'
import copy, json, re, sys

cfg_path, transform_path = sys.argv[1], sys.argv[2]
want = {sys.argv[3]: sys.argv[4], sys.argv[5]: sys.argv[6]}   # depName -> version the module reports

# Renovate matches file patterns against REPO-RELATIVE paths; transform_path is absolute because
# every other section of this suite needs it that way.
TRANSFORM_REL = "tests/xunit-v3/apply-transform.py"

cfg = json.load(open(cfg_path, encoding="utf-8"))
source = open(transform_path, encoding="utf-8").read()


def to_python(pattern):
    r"""Renovate evaluates these with RE2, where a named group is `(?<name>…)`; Python spells the
    same thing `(?P<name>…)`. Translate for the check.

    Constructs RE2 cannot compile are REJECTED rather than translated: Python supports them, RE2
    does not, so a pattern using one would match happily here while Renovate's own compile throws
    CONFIG_VALIDATION and stops managing the repo entirely — whose only symptom is that no PRs ever
    appear again. A guard that is green on a config the real engine refuses is worse than no guard.

    Everything RE2 omits, it omits for one reason — it guarantees linear-time matching, and every
    construct below needs backtracking. That is a principle, not a list, and the probes here are a
    best effort at covering it rather than a proof: Python keeps ADDING such constructs (atomic
    groups and possessive quantifiers arrived in 3.11 and were missed by the first version of this
    check), so treat it as extendable, not closed.

    The probes are independent of each other — `(?<!` does NOT match the lookahead probe, because
    that one requires `=`/`!` immediately after `(?` where a lookbehind has `<`. Order here is for
    reading, not correctness. (An earlier revision of this comment claimed the opposite and was
    simply wrong; it is checked now rather than asserted, by `_lookbehind` below.)

    The possessive-quantifier probe can in principle false-positive on an escaped `\+` followed by
    `+`. That direction is deliberate: a false positive fails loudly and is fixed in a minute, while
    a false negative ships a config Renovate refuses and shows up only as PRs that never appear."""
    for probe, name in ((r"\(\?<[=!]", "lookbehind"),
                        (r"\(\?[=!]", "lookahead"),
                        (r"\(\?>", "atomic group"),
                        (r"[*+?}]\+", "possessive quantifier"),
                        (r"\\[1-9]", "backreference")):
        assert not re.search(probe, pattern), (
            f"{name} in a matchString: RE2 cannot compile it and Renovate would reject the whole "
            f"config — {pattern!r}"
        )
    return pattern.replace("(?<", "(?P<")


def re2_regex(pattern, ignore_case=False):
    """Compile an RE2 pattern for use here, or return None when this guard cannot read it.

    `to_python` has exactly the right shape for a matchString, where an untranslatable pattern must
    RAISE — the raise IS the verdict, and three negative cases below pin it. In a FILE or PACKAGE
    pattern the same raise killed the whole suite with a traceback instead of returning a verdict:
    `re.search` was handed Renovate's own `(?<name>…)` spelling untranslated and died on
    `unknown extension ?<d` (#99). Here the answer wanted is "this guard could not read it", which
    the callers record in `unevaluated` and `check` refuses on — reported, never raised."""
    try:
        return re.compile(to_python(pattern), re.IGNORECASE if ignore_case else 0)
    except (AssertionError, re.error):
        return None


# Exposing these pins is only SAFE because majors are disabled for the family: a lone CodeCoverage
# 18.x would restore clean, build clean and die at run time. So the rule that makes it safe must
# actually cover the depNames these managers emit — edit a glob and the managers keep working while
# the protection quietly stops applying.
def _name_matches(pattern, dep):
    """One un-negated matchPackageNames / matchDepNames entry against one dependency.
    -> True | False | None (None = a dialect this guard cannot read)

    Renovate resolves a `/…/`-delimited entry as a regex (trailing `i` allowed) and anything else as
    a minimatch glob, of which a bare package id is the degenerate case. A package id carries no
    `/`, so minimatch's segment rules collapse and that glob subset is precisely the one `path_glob`
    already compiles for file scopes — reused here rather than hand-rolled a second time."""
    delimited = re.fullmatch(r"/(.*)/([a-z]*)", pattern, re.DOTALL)
    if delimited:
        if set(delimited.group(2)) - {"i"}:
            return None
        rx = re2_regex(delimited.group(1), "i" in delimited.group(2))
        return None if rx is None else bool(rx.search(dep))
    rx = path_glob(pattern.lower())
    return None if rx is None else bool(rx.match(dep.lower()))


def covers(patterns, dep):
    """Does this matchPackageNames / matchDepNames list select `dep`?  -> (bool, [unevaluated…])

    Renovate's own resolution rather than a simplification of it: any entry may be NEGATED with a
    leading `!`, a negated entry that matches excludes the package outright, and a list made only of
    negations selects everything those negations do not exclude.

    The previous spelling understood a trailing `*` and an exact name and nothing else, so a
    `/regex/` entry and a `!`-negation both read as "this rule says nothing about this package". On
    the rule that HOLDS the majors that mistake is loud — the suite goes red on a valid config, and
    somebody narrows it. On a rule that RE-ENABLES them it is silent, and silence there is a pin
    whose majors are open while this section prints "majors held" (#99)."""
    # The whole list is walked even once an exclusion has decided the answer, for the reason
    # `selects` gives: an entry this guard cannot read is worth reporting whatever the verdict, and
    # returning early would report it only for whichever dependency happened to reach it first.
    unevaluated, excluded, matched, has_positive = [], False, False, False
    for p in patterns:
        negated = p.startswith("!")
        verdict = _name_matches(p[1:] if negated else p, dep)
        if verdict is None:
            unevaluated.append(p)
        elif negated:
            excluded = excluded or verdict     # an explicit exclusion outranks any inclusion
        else:
            has_positive = True
            matched = matched or verdict
    return (not excluded and (matched or not has_positive)), unevaluated


def names_reach(rule, dep):
    """The two keys that narrow a packageRule to particular packages, ANDed as Renovate ANDs them.
    -> (bool, [unevaluated…])

    `matchDepNames` is `matchPackageNames`' sibling, not an exotic key. Reading only the latter left
    a rule scoped by depName looking unscoped — so an unrelated `{matchDepNames: ["Newtonsoft.Json"],
    matchUpdateTypes: ["major"], enabled: true}` re-opened the family's majors as far as this guard
    could see, and turned a correct config red (#99)."""
    unevaluated, reach = [], True
    for key in ("matchPackageNames", "matchDepNames"):
        patterns = rule.get(key)
        if patterns is None:
            continue
        hit, unknown = covers(patterns, dep)
        unevaluated.extend(unknown)
        reach = reach and hit
    return reach, unevaluated


def path_glob(glob):
    """Compile the minimatch subset used for FILE scopes (`matchFileNames`, `ignorePaths`).

    Supported: `**` (any depth, including none, when written `**/`), `*` (one path segment), `?`
    (one character), and literals. Brace expansion, character classes and `!`-negation return None
    and are reported unevaluated by the callers.

    The first version of this understood only an exact path and a `dir/**` prefix, which rejected
    two of the most ordinary valid scopes — `["**"]` and `["tests/xunit-v3/*.py"]` both reach the
    transform, and both failed the suite on a correct config. That direction of error matters: a
    guard that refuses valid input gets deleted by whoever hits it, not narrowed.

    PACKAGE-name globs come through here too (`_name_matches`), and so do bare `managerFilePatterns`
    entries (`selects`). Both are the same minimatch subset, and until #99 each caller either
    hand-rolled its own version of it or refused the dialect outright while this compiler sat
    seventy lines away, unused by two of the three."""
    if any(ch in glob for ch in "{}[]!"):
        return None
    out, i = [], 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out.append("(?:.*/)?")        # `**/` may span zero directories
            i += 3
        elif glob.startswith("**", i):
            out.append(".*")
            i += 2
        elif glob[i] == "*":
            out.append("[^/]*")           # a single `*` never crosses a separator
            i += 1
        elif glob[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(glob[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


# The `match*` keys this section models, between `rule_applies` and its caller. Renovate has a great
# many more (matchCurrentVersion, matchBaseBranches, matchDepTypes, matchCurrentAge, …) and every one
# of them NARROWS the rule that carries it — so a key missing from this set is a rule whose reach
# this guard cannot compute, not a rule that reaches everything.
MODELLED_MATCH_KEYS = frozenset({
    "matchDatasources", "matchManagers", "matchFileNames",
    "matchPackageNames", "matchDepNames", "matchUpdateTypes",
})


def rule_applies(rule, path, datasource):
    """Does this packageRule actually reach `path` at `datasource`?  -> (bool, [unevaluated…])

    A rule that disables majors only protects what it MATCHES. THREE keys narrow that reach and all
    three were once ignored here — so scoping the family rule to `samples/**` (or to the stock
    `nuget` manager, which never sees deps a custom regex manager extracted) left this guard green
    while the transform's pins lost their hold completely. That is exactly the "edit a glob and the
    protection quietly stops applying" failure the comment above warns about (#67).

    Three keys were also all it read, which is the same hole one level up: a family hold narrowed by
    `matchCurrentVersion: "<3"`, `matchBaseBranches` or `matchDepTypes` reaches nothing this suite
    cares about, and every one of them scored as FULL protection (#99). Any `match*` key outside
    MODELLED_MATCH_KEYS therefore makes the rule count as not-reaching AND gets reported: on a hold
    the first half is the safe answer, on a re-enabling rule it is the second, and only reporting is
    safe in both directions.

    ABSENT means "applies everywhere". Getting that inversion backwards would make every rule look
    inapplicable and fail the suite on a perfectly good config, so it is the first thing each branch
    decides. As elsewhere here, a glob this cannot evaluate faithfully is reported rather than
    guessed, and counts as NOT applying — an unreadable scope must never be mistaken for protection."""
    unmodelled = [k for k in sorted(rule) if k.startswith("match") and k not in MODELLED_MATCH_KEYS]
    if unmodelled:
        return False, unmodelled

    unevaluated = []
    datasources = rule.get("matchDatasources")
    if datasources is not None and datasource not in datasources:
        return False, unevaluated

    # These pins reach Renovate through a CUSTOM regex manager, so a rule scoped to the stock nuget
    # manager does not touch them — even though the datasource is nuget. Renovate has spelled this
    # manager both `custom.regex` (v37+) and `regex`; accept either.
    managers = rule.get("matchManagers")
    if managers is not None and not any(m in ("custom.regex", "regex") for m in managers):
        return False, unevaluated

    globs = rule.get("matchFileNames")
    if globs is None:
        return True, unevaluated          # unscoped by path: reaches the whole repo
    for g in globs:
        rx = path_glob(g)
        if rx is None:
            unevaluated.append(g)
        elif rx.match(path):
            return True, unevaluated
    return False, unevaluated


def selects(manager, path):
    """Does this manager's file-pattern list actually select `path`?  -> (bool, [unevaluated…])

    The previous spelling of this check was `any("apply-transform" in p for p in pats)` — a
    substring test on the pattern TEXT, which never once ran the pattern against a path. A typo'd
    directory, or a stale path after a rename, satisfied it while Renovate selected zero files and
    extracted nothing (#67).

    The two keys have different dialects and are not interchangeable:
      * `managerFilePatterns` — a `/…/`-delimited entry is a regex; a bare entry is a minimatch glob.
      * `fileMatch` (legacy)  — always a bare regex, never a glob.

    A bare entry is a minimatch GLOB, and glob is the dialect most people reach for: `["tests/**"]`
    and even the plain path itself select the transform, and both were REFUSED here while
    `path_glob` — which compiles exactly that subset — sat seventy lines above, unused (#99). They
    go through it now, and only what IT cannot compile (brace expansion, character classes) plus
    `!`-negation, which inverts meaning, is reported as unevaluatable.

    A pattern this helper cannot evaluate faithfully is returned in the second element rather than
    raised — including one whose regex RE2 accepts and Python does not, which used to escape
    `re.search` as a traceback and abort the run (#99). `check` refuses on a non-empty list, so an
    unreadable pattern is never mistaken for a manager that does not match."""
    unevaluated = []
    pats = manager.get("managerFilePatterns")
    if pats:
        hit = False
        for p in pats:
            if p.startswith("!"):
                unevaluated.append(p)          # negation inverts the meaning; not modelled here
                continue
            # `/body/flags` — Renovate allows trailing flags, and `/…/i` is ordinary valid config
            # that an earlier revision here rejected outright. Only `i` is understood; any other
            # flag is reported rather than silently dropped, since dropping one changes what matches.
            delimited = re.fullmatch(r"/(.*)/([a-z]*)", p, re.DOTALL)
            if delimited:
                if set(delimited.group(2)) - {"i"}:
                    unevaluated.append(p)
                    continue
                rx = re2_regex(delimited.group(1), "i" in delimited.group(2))
                search = rx.search if rx else None
            else:
                rx = path_glob(p)
                search = rx.match if rx else None    # a glob is anchored; a regex is not
            if search is None:
                unevaluated.append(p)
            elif search(path):
                hit = True
        return hit, unevaluated
    # Legacy key: bare regex by definition, so no delimiters to strip. Every entry is still walked
    # after a hit — an unreadable one later in the list is worth reporting even once something has
    # matched, since `check` refuses on it.
    hit = False
    for p in manager.get("fileMatch") or []:
        rx = re2_regex(p)
        if rx is None:
            unevaluated.append(p)
        elif rx.search(path):
            hit = True
    return hit, unevaluated


def ignored(entry, path):
    """Does this ignorePaths entry suppress extraction from `path`?  -> True | False | None

    Renovate's `filterIgnoredFiles` ignores a file when the entry is a plain SUBSTRING of the path
    (`file.includes(ignorePath)`) OR a minimatch glob that matches it. Only the second question was
    asked here, and only in its fully anchored form, so `["tests"]` and `["tests/xunit-v3"]` were
    ACCEPTED — both of them stop Renovate reading the transform. Brace and character-class globs
    were accepted too, by the None branch the caller read as harmless (#99)."""
    if entry in path:
        return True
    rx = path_glob(entry)
    return None if rx is None else bool(rx.match(path))


def check(cfg):
    """Refuse any config under which Renovate would fail to WATCH, or fail to hold the MAJORS of,
    the two pins the transform writes. Returns the {depName: version} it saw.

    Takes the config as an argument rather than closing over the real one so the negative cases at
    the bottom can drive it with deliberately broken copies. That is the whole point: every hole
    #67 records was a assertion that had never once been executed against a config it should
    refuse, so it was impossible to tell a working guard from a decorative one.

    `unevaluated` is the other half of that contract, and it is one list rather than four: every
    helper that meets a spelling it cannot resolve puts it here, and the assertion at the bottom
    refuses on a non-empty list no matter how well the rest of the config reads. #99 measured what
    the alternative costs — six spellings Renovate honours that this guard accepted, because each
    site decided locally that what it could not read was harmless.

    THE BOUNDARY THIS SECTION DOES NOT CROSS: `cfg` is the UNRESOLVED renovate.json, read straight
    off disk. Renovate resolves `extends` first and merges the preset underneath the local keys, so
    everything a preset contributes is invisible here, and a preset setting `enabledManagers` would
    disable the custom managers repo-wide while every assertion below still passed. This repo
    extends `local>phmatray/.github:renovate-ci` (#99, hole 4).

    Resolving a preset means fetching another repository, which is exactly what this section must
    not do — it is the offline, always-runnable half of the pair.

    WHERE THE BOUNDARY MOVED (#156): `tests/renovate-config/test.sh` section 10 now asks Renovate
    itself, via `renovate --dry-run=extract --print-config`, and asserts the two reach questions
    against the RESOLVED config. That closed hole 4 and immediately found the defect it was built to
    find — the resolved config inherited Renovate's default `ignorePaths`, whose `**/tests/**`
    filtered this very file out of the candidate list before any manager matched it, so both pins
    were unwatched. The fix is the explicit `ignorePaths` renovate.json now carries: the inherited
    list minus that one entry.

    The two halves divide as follows, and NEITHER covers the other:
      * a regression in the FILE is this section's, caught offline on every CI run. The loop below
        is no longer vacuous — renovate.json declares seven `ignorePaths` today, and
        `_ignore_the_whole_tree` pins that a `tests/**`-shaped entry returning to it is refused.
      * a regression in the PRESET is section 10's alone, with its own honest limits: it reads the
        DEFAULT BRANCH as the platform serves it, not the working tree, and it SKIPs when node is
        below renovate's 24.11 floor or no token is available — which is every CI run until
        `actions/setup-node` is wired. A SKIP is not a pass, and nothing offline is a substitute for
        it: no model here can see a preset edit made in another repository."""
    unevaluated = []
    managers = cfg.get("customManagers", [])
    assert managers, "renovate.json declares no customManagers — the pins are invisible to Renovate"

    # ignorePaths is applied BEFORE extraction, so a manager can select the transform perfectly and
    # still see nothing. This config's own description block explains that mechanism (it is why the
    # frozen fixture is disabled rather than ignored), which makes it a plausible edit — and one
    # that would leave every other assertion here green.
    for g in cfg.get("ignorePaths") or []:
        suppresses = ignored(g, TRANSFORM_REL)
        if suppresses is None:
            unevaluated.append(g)
            continue
        assert not suppresses, (
            f"ignorePaths entry {g!r} suppresses extraction from {TRANSFORM_REL} — Renovate never "
            f"reads the file, so the custom managers below are dead no matter how they are written"
        )

    # Only the managers that actually select the transform are this section's business. Asserting
    # over ALL of them meant an unrelated custom manager added elsewhere in the repo would fail the
    # xunit suite, with a message about a transform it has nothing to do with (#67).
    mine = []
    for m in managers:
        hit, unknown = selects(m, TRANSFORM_REL)
        unevaluated.extend(unknown)
        if hit:
            mine.append(m)
    assert mine, (
        f"no customManager selects {TRANSFORM_REL}, so Renovate extracts nothing from it and the "
        f"pins go unwatched"
        + (f" — note that {sorted(set(unevaluated))} could not be evaluated by this guard and were "
           f"treated as non-matching; if one of those is meant to select the transform, teach "
           f"`selects` its dialect" if unevaluated else "")
    )

    found = {}
    for m in mine:
        assert m.get("customType") == "regex", m
        # Asserted per MANAGER, not per match: inside the match loop these never run for a manager
        # whose regex has gone blind, which is exactly the manager worth complaining about.
        assert m.get("datasourceTemplate") == "nuget", f"datasource must be nuget: {m}"
        assert m.get("versioningTemplate") == "nuget", (
            f"versioning must be nuget — the custom-manager default is semver-coerced, which mis-orders "
            f"NuGet's four-segment versions: {m}"
        )
        assert m.get("matchStrings"), f"manager declares no matchStrings — it extracts nothing: {m}"
        for raw in m["matchStrings"]:
            hits = list(re.finditer(to_python(raw), source))
            # Exactly one, asserted per MATCHSTRING rather than per manager (a manager may carry
            # several, each pinning its own constant). Zero means the regex went blind — a renamed
            # constant, the case this section was built for. More than one means Renovate extracts
            # several dependencies where this guard reports a single pin: the extras are invisible
            # here and would still be rewritten on a bump, and `found[dep] = …` would keep only
            # whichever came last.
            assert len(hits) == 1, (
                f"this matchString matched {len(hits)} time(s) in the transform, expected exactly 1 "
                f"— {raw!r}"
            )
            g = hits[0].groupdict()
            # Renovate's precedence, not the intuitive one: depNameTemplate OVERRIDES a captured
            # depName. Reading it the other way round meant that a manager carrying both would be
            # checked under a name Renovate never uses — including by the major-hold check below,
            # which could then pass for a package that has no hold at all.
            dep = m.get("depNameTemplate") or g.get("depName")
            assert dep, f"no depName captured or templated for {raw!r}"
            assert "currentValue" in g, f"{dep}: {raw!r} captures no currentValue"
            found[dep] = g["currentValue"]

    for dep, version in want.items():
        # The unreadable-pattern note belongs HERE too, not only on the `mine`-is-empty branch: when
        # one manager of two selects, this is the assertion that fires, and on its own it accuses
        # apply-transform.py of a renamed constant when the actual edit was in renovate.json (#99).
        assert dep in found, (
            f"the custom manager never matched {dep} — a constant was renamed and the regex went "
            f"quietly blind. Matched: {found}"
            + (f". Note: {sorted(set(unevaluated))} could not be evaluated by this guard and were "
               f"treated as non-matching, so look at renovate.json before the transform"
               if unevaluated else "")
        )
        assert found[dep] == version, (
            f"{dep}: the regex captured {found[dep]!r} but the module reports {version!r}"
        )

    # Every manager in `mine` was asserted to emit nuget deps above, so that is the datasource the
    # holds have to cover.
    #
    # Renovate resolves packageRules LAST-MATCH-WINS, not "any rule that disables it". Asking only
    # whether some rule disables majors meant a later `{matchPackageNames: [...], enabled: true}`
    # silently restored them while this guard still printed "majors held" (#67). So walk the rules
    # in order and keep the last verdict, exactly as Renovate would.
    for dep in found:
        held = False
        for r in cfg.get("packageRules", []):
            types = r.get("matchUpdateTypes")
            if types is not None and "major" not in types:
                continue                       # this rule has nothing to say about majors
            named, unknown = names_reach(r, dep)
            unevaluated.extend(unknown)
            if not named:
                continue                       # …nor about this package
            reaches, unknown = rule_applies(r, TRANSFORM_REL, "nuget")
            unevaluated.extend(unknown)
            if not reaches:
                continue
            if r.get("enabled") is False:
                held = True
            elif r.get("enabled") is True:
                held = False                   # a later rule re-opened it
        assert held, (
            f"{dep} is now visible to Renovate but no rule disables its MAJOR updates — a one-leg bump "
            f"across the Microsoft.Testing.Platform boundary could be proposed and merged green"
            + (f". Note: {sorted(set(unevaluated))} could not be evaluated by this guard, so one of "
               f"them may be the hold — check those before concluding the rule is missing"
               if unevaluated else "")
        )

    # Last, so that it fires even when every check above passed. An entry reaches this list only
    # because some helper met a spelling Renovate resolves and this guard does not, which means the
    # green it would otherwise print is a verdict on a config it only partly read. Until #99 the
    # list was mentioned in one branch of one assertion — the one that runs least often.
    assert not unevaluated, (
        f"{sorted(set(unevaluated))} could not be evaluated by this guard — Renovate resolves these "
        f"spellings and section 9 does not model them, so it cannot say whether the pins stay watched "
        f"and their majors held. It refuses rather than guessing: an unreadable scope must never be "
        f"mistaken for protection. Teach `path_glob`/`covers`/`rule_applies` the form, or write the "
        f"config in one they already read"
    )
    return found


def rejects(why, mutate, because):
    """Assert that `check` REFUSES a deliberately broken copy of the real config, FOR THE STATED
    REASON.

    Each of these corresponds to a way the guard was previously green while Renovate was, or would
    have been, doing nothing. Mutating a deepcopy of the REAL config (rather than hand-building a
    fixture) keeps the negative cases honest: they stay one edit away from what ships, so they
    cannot drift into testing a config shape the repo no longer has.

    `because` is not decoration. A broken regex usually matches nothing, which trips the
    "this manager is dead" assert — so a negative case can go green having never exercised the
    assertion it was written for. Pinning a substring of the refusal message is what separates
    "refused" from "refused for the reason I claimed", and that distinction is the entire subject
    of #67."""
    bad = copy.deepcopy(cfg)
    mutate(bad)
    try:
        check(bad)
    except AssertionError as exc:
        assert because in str(exc), (
            f"section 9 rejected the {why!r} case, but for the WRONG reason — expected a message "
            f"containing {because!r}, got: {exc}"
        )
        return
    raise AssertionError(f"section 9 accepted a config it must reject — {why}")


def accepts(why, mutate):
    """Assert that `check` still PASSES a legitimate variation of the real config.

    The mirror of `rejects`, and just as necessary: a guard that refuses valid configs gets
    loosened by whoever hits it next, usually by deleting the assertion rather than narrowing it."""
    ok = copy.deepcopy(cfg)
    mutate(ok)
    try:
        check(ok)
    except AssertionError as exc:
        raise AssertionError(f"section 9 refused a config it must accept — {why}: {exc}") from None


found = check(cfg)   # the real config: must pass


def _typo_the_path(c):
    # `test/` instead of `tests/` — one character, and Renovate selects zero files.
    c["customManagers"][0]["managerFilePatterns"] = ["/^test/xunit-v3/apply-transform\\.py$/"]


# Refused because the xunit pin ends up unwatched — the actual consequence of the typo. The other
# manager still selects the transform, so `mine` is non-empty and the failure surfaces one step
# later, at the point where it can name the pin that lost its watcher.
rejects("a file pattern that selects nothing (typo'd directory)", _typo_the_path,
        because="never matched xunit.v3")


def _typo_every_path(c):
    # Both managers mis-targeted: nothing selects the transform at all.
    for m in c["customManagers"]:
        m["managerFilePatterns"] = ["/^test/xunit-v3/apply-transform\\.py$/"]


rejects("no manager selecting the transform at all", _typo_every_path,
        because="no customManager selects")


def _transform_manager_in_a_dialect_this_cannot_read(c):
    # The transform's OWN manager written in a dialect this guard cannot evaluate — brace expansion,
    # which minimatch performs and `path_glob` deliberately does not attempt. It must fail closed and
    # say so, never quietly treat the pins as watched.
    #
    # This case used to be spelled `tests/xunit-v3/**`, an ORDINARY minimatch glob that Renovate
    # honours — the suite codified a false red (#99, hole 6). That spelling is now an `accepts` case
    # further down; the fail-closed contract it was really testing lives here, on a form `path_glob`
    # genuinely cannot compile.
    for m in c["customManagers"]:
        m["managerFilePatterns"] = ["tests/{xunit-v3,x}/**"]


rejects("the transform's manager written as an unevaluatable glob",
        _transform_manager_in_a_dialect_this_cannot_read, because="could not be evaluated")


def _lookahead(c):
    # Still matches in Python, so this can only be refused by the RE2 check itself.
    c["customManagers"][0]["matchStrings"] = [
        'XUNIT_V3_PACKAGE = "(?<depName>[^"]+)"\\nXUNIT_V3_VERSION = "(?=3)(?<currentValue>[^"]+)"'
    ]


def _backreference(c):
    # `\1` re-matches the literal "XUNIT" captured by group 1 — legal in Python, rejected by RE2.
    c["customManagers"][0]["matchStrings"] = [
        '(XUNIT)_V3_PACKAGE = "(?<depName>[^"]+)"\\n\\1_V3_VERSION = "(?<currentValue>[^"]+)"'
    ]


def _lookbehind(c):
    # `(?<="` succeeds where the version literal opens, so this too is refused only by the RE2 check
    # — and it must be named LOOKBEHIND, not lookahead, which is why that probe is ordered first.
    c["customManagers"][0]["matchStrings"] = [
        'XUNIT_V3_PACKAGE = "(?<depName>[^"]+)"\\nXUNIT_V3_VERSION = "(?<=")(?<currentValue>[^"]+)"'
    ]


rejects("a lookahead in a matchString", _lookahead, because="lookahead")
rejects("a backreference in a matchString", _backreference, because="backreference")
rejects("a lookbehind in a matchString", _lookbehind, because="lookbehind")


def _unrelated_manager(c):
    # A future manager pinning something else entirely: different dialect (jsonata), different
    # file, no bearing on the transform. This suite must not have an opinion about it.
    c["customManagers"].append({
        "customType": "jsonata",
        "managerFilePatterns": ["/^templates/ci-dotnet\\.yml$/"],
        "matchStrings": ["irrelevant"],
        "datasourceTemplate": "github-tags",
    })


def _unrelated_manager_with_a_glob(c):
    # Same, but written as a minimatch glob — the form `selects` deliberately cannot evaluate. It
    # must read as "not ours", not as a crash and not as a match.
    c["customManagers"].append({
        "customType": "regex",
        "managerFilePatterns": ["templates/**"],
        "matchStrings": ["irrelevant"],
        "datasourceTemplate": "github-tags",
    })


accepts("an unrelated custom manager elsewhere in the repo", _unrelated_manager)
accepts("an unrelated custom manager written as a glob", _unrelated_manager_with_a_glob)


def _template_shadows_capture(c):
    # Both present. Renovate resolves the dep as the TEMPLATE, so the name actually watched is this
    # sentinel — the captured xunit.v3 is not watched at all, and the guard must notice.
    c["customManagers"][0]["depNameTemplate"] = "Sentinel.Not.The.Pin"


def _matches_more_than_once(c):
    # Matches every `= "…"` assignment in the module, not just the coverage pin.
    c["customManagers"][1]["matchStrings"] = ['= "(?<currentValue>[^"]+)"']


rejects("depNameTemplate shadowing a captured depName", _template_shadows_capture,
        because="never matched xunit.v3")
rejects("a matchString that matches more than once", _matches_more_than_once,
        because="expected exactly 1")


def _family_rule(c):
    """The packageRule that holds the MTP family's majors.

    Identified by the packages it names, not by being the first major rule: adding any unrelated
    major-hold ahead of it would otherwise make the mutations below edit the WRONG rule, and the
    negative cases would then report a scoped-away hold that is in fact intact."""
    return next(r for r in c["packageRules"]
                if any("xunit.v3" in g for g in (r.get("matchPackageNames") or [])))


def _scope_the_hold_to_another_path(c):
    # Still enabled:false, still matchUpdateTypes:[major], still the right package globs — but it
    # no longer applies to the file the pins live in, so it protects nothing that matters.
    _family_rule(c)["matchFileNames"] = ["samples/**"]


def _scope_the_hold_to_another_datasource(c):
    # Same, via the other axis: the managers emit nuget deps, this rule now only covers npm.
    _family_rule(c)["matchDatasources"] = ["npm"]


def _scope_the_hold_onto_the_transform(c):
    # The other direction of the same inversion: a hold explicitly scoped to where the pins live is
    # still a hold. Reading "absent"/"present" backwards would fail this perfectly good config, and
    # whoever hit that would delete the assertion rather than narrow it.
    _family_rule(c)["matchFileNames"] = ["tests/**"]


rejects("a major-hold scoped away by matchFileNames", _scope_the_hold_to_another_path,
        because="no rule disables its MAJOR updates")
rejects("a major-hold scoped away by matchDatasources", _scope_the_hold_to_another_datasource,
        because="no rule disables its MAJOR updates")
accepts("a major-hold explicitly scoped to the transform's tree", _scope_the_hold_onto_the_transform)


# --- reach and resolution: the ways a hold stops holding without being deleted ----------------
def _scope_the_hold_to_the_stock_manager(c):
    # nuget datasource, but these deps come from a CUSTOM regex manager, so this reaches nothing.
    _family_rule(c)["matchManagers"] = ["nuget"]


def _reopen_majors_later(c):
    # packageRules are last-match-wins: this undoes the hold above without touching it.
    c["packageRules"].append({"matchPackageNames": ["xunit.v3**"], "enabled": True})


def _ignore_the_whole_tree(c):
    # Applied before extraction — every manager below becomes dead no matter how it is written.
    c["ignorePaths"] = ["tests/**"]


rejects("a major-hold scoped to the stock nuget manager", _scope_the_hold_to_the_stock_manager,
        because="no rule disables its MAJOR updates")
rejects("a later rule re-enabling the majors", _reopen_majors_later,
        because="no rule disables its MAJOR updates")
rejects("ignorePaths suppressing extraction from the transform", _ignore_the_whole_tree,
        because="suppresses extraction")


# --- ignorePaths: every form Renovate honours, not only the one this guard could read (#99) -----
#
# `filterIgnoredFiles` ignores a file when an entry is a plain SUBSTRING of the path
# (`file.includes(ignorePath)`) OR a minimatch glob that matches it — and minimatch expands braces
# and character classes. Four spellings that all suppress extraction from the transform were
# ACCEPTED here: two because this guard only ever asked its anchored-glob question, and two because
# `path_glob` returns None for the dialect while the caller read None as "harmless" — the one
# unevaluatable form in the file that was not even collected into `unevaluated`, contradicting the
# principle its own neighbours state: an unreadable scope must never be mistaken for protection.
def _ignore_by_bare_directory(c):
    c["ignorePaths"] = ["tests"]


def _ignore_by_directory_prefix(c):
    c["ignorePaths"] = ["tests/xunit-v3"]


def _ignore_by_brace_expansion(c):
    c["ignorePaths"] = ["tests/{xunit-v3,x}/**"]


def _ignore_by_character_class(c):
    c["ignorePaths"] = ["tests/[xy]unit-v3/**"]


rejects("ignorePaths naming an ancestor directory", _ignore_by_bare_directory,
        because="suppresses extraction")
rejects("ignorePaths naming the transform's own directory", _ignore_by_directory_prefix,
        because="suppresses extraction")
rejects("ignorePaths written with brace expansion", _ignore_by_brace_expansion,
        because="could not be evaluated")
rejects("ignorePaths written with a character class", _ignore_by_character_class,
        because="could not be evaluated")


# --- packageRules: keys that narrow a rule, and keys that merely look like they do (#99) --------
#
# A hold only protects what it MATCHES, and `rule_applies` read three of the keys that narrow that
# reach. Any OTHER `match*` key was invisible, so a hold Renovate would not apply to xunit.v3 3.2.2  # pinned:xunit-v3
# was scored as full protection. The three below are the ones measured on the issue.
def _narrow_the_hold_by_current_version(c):
    _family_rule(c)["matchCurrentVersion"] = "<3"


def _narrow_the_hold_by_base_branch(c):
    _family_rule(c)["matchBaseBranches"] = ["release"]


def _narrow_the_hold_by_dep_type(c):
    _family_rule(c)["matchDepTypes"] = ["devDependencies"]


rejects("a major-hold narrowed by matchCurrentVersion", _narrow_the_hold_by_current_version,
        because="no rule disables its MAJOR updates")
rejects("a major-hold narrowed by matchBaseBranches", _narrow_the_hold_by_base_branch,
        because="no rule disables its MAJOR updates")
rejects("a major-hold narrowed by matchDepTypes", _narrow_the_hold_by_dep_type,
        because="no rule disables its MAJOR updates")


# --- packageRules: the two matchPackageNames dialects a RE-ENABLING rule can hide behind (#99) --
#
# `covers` understood a trailing `*` and an exact name. Renovate also resolves a `/…/` regex entry
# and a `!`-negated one, and a list of negations alone matches everything they do not exclude. On
# the rule that HOLDS the majors that blindness is loud (the suite goes red on a valid config); on a
# rule that RE-ENABLES them it is silent, which is the direction that ships an unwatched pin.
def _reopen_majors_with_a_regex(c):
    c["packageRules"].append({"matchPackageNames": ["/^xunit\\.v3/"], "enabled": True})


def _reopen_majors_with_a_negation(c):
    c["packageRules"].append({"matchPackageNames": ["!Newtonsoft.Json"], "enabled": True})


rejects("a later rule re-enabling the majors by regex", _reopen_majors_with_a_regex,
        because="no rule disables its MAJOR updates")
rejects("a later rule re-enabling the majors by negation", _reopen_majors_with_a_negation,
        because="no rule disables its MAJOR updates")


def _an_unreadable_pattern_on_an_otherwise_healthy_config(c):
    # Nothing here touches the pins: both managers still select the transform and both holds still
    # hold. The only defect is one file pattern in a dialect this guard cannot read — and that list
    # was surfaced ONLY when `mine` came out completely empty, so a partially-unreadable config
    # passed with a confident green and, when it did fail, blamed the wrong file.
    #
    # Refusing here is deliberate even though the manager is unrelated to the transform: since
    # `selects` falls back to `path_glob`, ordinary globs evaluate fine — `templates/**` is an
    # `accepts` case a hundred lines above — so what reaches this branch is a form nobody has taught
    # the guard yet. Loud is the correct failure mode for that; green is not.
    c["customManagers"].append({
        "customType": "regex",
        "managerFilePatterns": ["templates/{ci-dotnet,ci-node}.yml"],
        "matchStrings": ["irrelevant"],
        "datasourceTemplate": "github-tags",
    })


rejects("one unreadable file pattern on an otherwise healthy config",
        _an_unreadable_pattern_on_an_otherwise_healthy_config, because="could not be evaluated")


def _file_pattern_re2_itself_would_refuse(c):
    # The pattern is translatable in the sense that Python compiles it happily — and that is the
    # problem: RE2 cannot, so Renovate would reject the whole config. Reported as unevaluatable and
    # refused, never raised out of `selects` as a traceback.
    for m in c["customManagers"]:
        if selects(m, TRANSFORM_REL)[0]:
            m["managerFilePatterns"] = ["/^(?=tests)tests\\/xunit-v3\\/apply-transform\\.py$/"]


rejects("a file pattern RE2 itself would refuse", _file_pattern_re2_itself_would_refuse,
        because="could not be evaluated")


# --- valid config this guard must NOT refuse ---------------------------------------------------
def _hold_scoped_with_a_segment_glob(c):
    _family_rule(c)["matchFileNames"] = ["tests/xunit-v3/*.py"]


def _hold_scoped_to_everything(c):
    _family_rule(c)["matchFileNames"] = ["**"]


def _case_insensitive_file_pattern(c):
    # Only the managers that ALREADY select the transform. Rewriting every manager's pattern to
    # the transform path drags unrelated ones into this section's scope — and they legitimately
    # carry a different datasource, so `check` refuses them and this ACCEPT case fails for a
    # reason that has nothing to do with the `/i` flag it is testing. Measured when #66 added a
    # third manager (the Renovate validator pin in ci.yml, datasource npm): section 9 refused a
    # config it must accept. That is hole 3 of #67 again, one level up — the guard body was
    # scoped, the mutations that feed it were not.
    for m in c["customManagers"]:
        if selects(m, TRANSFORM_REL)[0]:
            m["managerFilePatterns"] = ["/^tests/xunit-v3/apply-transform\\.py$/i"]


def _unrelated_major_hold_first(c):
    # Inserted AHEAD of the family rule: _family_rule must still find the right one.
    c["packageRules"].insert(0, {
        "matchPackageNames": ["Newtonsoft.Json"],
        "matchUpdateTypes": ["major"],
        "enabled": False,
    })


def _ignore_somewhere_else(c):
    # The mirror of the ignorePaths cases above. `ignorePaths` is a real key with real legitimate
    # uses, and the substring rule that catches `["tests"]` must not turn every entry into a
    # refusal — or the guard becomes one nobody can satisfy and somebody deletes it.
    c["ignorePaths"] = ["samples/LegacyShop/**"]


def _unrelated_major_rule_by_dep_name(c):
    # matchDepNames is matchPackageNames' sibling, not an unmodelled narrowing key: this rule
    # re-enables majors for Newtonsoft.Json and says nothing whatever about the family. Reading it
    # as "applies to everything" made the suite red on a correct config (#99, hole 2, mirrored).
    c["packageRules"].append({
        "matchDepNames": ["Newtonsoft.Json"],
        "matchUpdateTypes": ["major"],
        "enabled": True,
    })


def _hold_whose_packages_are_named_by_regex(c):
    # The family hold spelled with `/…/` entries is a perfectly good hold — and the mirror of the
    # re-enabling cases above, which is what keeps `covers`' new dialects honest in both directions.
    _family_rule(c)["matchPackageNames"] = ["/^xunit\\.v3/", "/^Microsoft\\.Testing\\./"]


def _transform_manager_as_a_glob(c):
    # An ORDINARY minimatch glob. `managerFilePatterns` takes one wherever it takes a `/…/` regex,
    # and `path_glob` — seventy lines above, and unused by `selects` until #99 — reads it correctly.
    # Only the managers that ALREADY select the transform are rewritten, for the reason
    # _case_insensitive_file_pattern gives below.
    for m in c["customManagers"]:
        if selects(m, TRANSFORM_REL)[0]:
            m["managerFilePatterns"] = ["tests/xunit-v3/**"]


def _transform_manager_as_a_bare_path(c):
    # The simplest valid spelling of all: the path itself, no delimiters, no metacharacters.
    for m in c["customManagers"]:
        if selects(m, TRANSFORM_REL)[0]:
            m["managerFilePatterns"] = ["tests/xunit-v3/apply-transform.py"]


def _file_pattern_with_an_re2_named_group(c):
    # RE2 spells a named group `(?<name>…)`, Python spells it `(?P<name>…)` — the whole reason
    # `to_python` exists. `selects` handed the raw pattern to `re.search`, which raised
    # `unknown extension ?<d` and killed the suite with a traceback instead of returning a verdict
    # (#99, hole 5). Translated, it selects the transform: this is ordinary valid config.
    for m in c["customManagers"]:
        if selects(m, TRANSFORM_REL)[0]:
            m["managerFilePatterns"] = ["/^(?<dir>tests)\\/xunit-v3\\/apply-transform\\.py$/"]


accepts("a hold scoped with a single-segment glob", _hold_scoped_with_a_segment_glob)
accepts("a hold scoped to the whole repo with **", _hold_scoped_to_everything)
accepts("a case-insensitive /…/i file pattern", _case_insensitive_file_pattern)
accepts("an unrelated major-hold ahead of the family rule", _unrelated_major_hold_first)
accepts("ignorePaths scoped to an unrelated tree", _ignore_somewhere_else)
accepts("an unrelated major rule selected by matchDepNames", _unrelated_major_rule_by_dep_name)
accepts("a major-hold whose packages are named by regex", _hold_whose_packages_are_named_by_regex)
accepts("the transform's manager written as a minimatch glob", _transform_manager_as_a_glob)
accepts("the transform's manager written as a bare path", _transform_manager_as_a_bare_path)
accepts("a file pattern using RE2's named-group spelling", _file_pattern_with_an_re2_named_group)

print(f"  [9] Renovate's custom manager sees {len(found)} pin(s), majors held: "
      + ", ".join(f"{d} {v}" for d, v in sorted(found.items())))
PY

# ---------------------------------------------------------------------------
# 10. A "did we find any?" probe reports on what it FOUND, not on how the reader exited.
#
#     `find … | grep -q .` under `set -o pipefail` inverts on large results: grep exits at the
#     first match, find takes SIGPIPE on the closed pipe and returns 141, and pipefail makes that
#     the pipeline's status — so the `if` takes its else-branch, the one that means "nothing
#     there", exactly when something IS there. Two call sites had this shape (#48): section 4a's
#     canary, which exists to be LOUD the day the VSTest collector starts working under MTP, and
#     cleanup()'s __pycache__ guard, which exists to catch a stray .pyc reaching the tree. Both
#     failed silent, and a small result set hides it — one match fits in the pipe buffer and find
#     finishes before grep can close it.
#
#     The negative control used to run the naive pipeline against a 2000-entry fixture on the
#     theory that a listing big enough to overrun the 64 KiB pipe buffer leaves find still writing
#     when grep exits. That is a probability argument, not an ordering one — nothing kept the
#     reader's exit from happening safely after every write — and it was measured to fail as such
#     (#335): a throwaway 500-run harness against this exact fixture returned rc=0 (the failing,
#     uninverted outcome) 110/500 times idle and 292/500 times with every core saturated. The pipe
#     buffer's 64 KiB is also a tunable (/proc/sys/fs/pipe-max-size), not a constant, so no fixture
#     size can make the old shape's guarantee absolute.
#
#     So volume is replaced with an explicit handshake: the writer emits one matching line, waits
#     for PROOF the reader has already exited (a filesystem marker — not a pid or a second pipe;
#     the reader's pid isn't knowable from inside a plain pipeline, and a second pipe used to
#     signal would have the same EPIPE problem this test is about), and only then writes once
#     more. Same harness, same fixture, after this change: 0/500 idle, 0/500 saturated, and a
#     12-run loop of the whole suite under concurrent load also came back 0/12. Two more
#     ordering gaps surfaced past that measurement and are closed here too (#335, code review):
#     (1) the reader used to remove the marker BEFORE closing its own copy of the pipe's read
#     end, so "marker gone" briefly meant "about to be closed", not "closed" — the writer could
#     occasionally win that race and land its write in the pipe buffer instead of hitting EPIPE
#     (reproduced 74/300 with a tight poll); the reader now closes its fd (`exec 0<&-`) BEFORE
#     removing the marker, so "gone" is never observed early. (2) a broken-pipe write from a
#     bash builtin does not reliably kill the process the way it kills an external program like
#     `find` — measured true on this repo's own aarch64 host, measured FALSE on GitHub Actions'
#     ubuntu runner, which reports "write error: Broken pipe" per attempt and keeps going; the
#     writer now explicitly ignores SIGPIPE (`trap '' PIPE`) and checks printf's own exit status,
#     so every host takes the same code path instead of one host's default masking the failure.
#     tests/_lib.sh (first_match/any_match) is untouched by any of this — this is the negative
#     control only, and _lib.sh is a documented conflict hot-spot.
# ---------------------------------------------------------------------------
sigpipe_dir="$scratch/sigpipe-probe"
mkdir -p "$sigpipe_dir"
# Long names on purpose: kept even though the negative control below no longer depends on volume,
# because the positive control (any_match/first_match) and the retained find|grep smoke line still
# want a real, sizeable fixture to run against.
for i in $(seq 1 2000); do
  : > "$sigpipe_dir/padded-so-the-listing-overruns-the-pipe-buffer-$i.cobertura.xml"
done

# The population is measured DIRECTLY rather than inferred from an exit status, because a status
# alone cannot tell "the reader closed the pipe" from "there was nothing to find".
created=$(find "$sigpipe_dir" -name '*.cobertura.xml' -type f | wc -l | tr -d ' ')
if [ "$created" -lt 2000 ]; then
  echo "FAIL: fixture broken — $created matching files created, expected 2000. Section 10 cannot"
  echo "      reproduce #48 without enough entries for the positive control below."
  exit 1
fi

# kit_wait_gone <marker-path> <timeout-seconds> — polls (every $alive_poll_ms) until
# <marker-path> no longer exists; returns 0 once gone, non-zero on timeout. Bounded so a hang in
# the harness (the reader somehow never exiting) cannot spin forever (#135's shape: an unbounded
# read-back turns a bug into a hang). Defined here, not in tests/_lib.sh: this is section 10's
# only caller, and _lib.sh is a documented conflict hot-spot. bash 3.2-safe: no `[[ ]]`, no
# arrays, no `wait -n`. The timeout is REQUIRED (no default) so the one caller and its FAIL
# message can share a single literal instead of three copies drifting apart.
kit_wait_gone() {
  local marker_path="$1"
  local marker_timeout_s="$2"
  local poll_ms="$alive_poll_ms"
  local elapsed_ms=0
  local timeout_ms=$((marker_timeout_s * 1000))
  while [ -e "$marker_path" ]; do
    if [ "$elapsed_ms" -ge "$timeout_ms" ]; then
      return 1
    fi
    sleep "$(printf '0.%03d' "$poll_ms")"
    elapsed_ms=$((elapsed_ms + poll_ms))
  done
  return 0
}

# The negative control itself: order the reader's exit before the writer's remaining write
# instead of hoping volume makes it likely (measured rates in the comment block above). The
# ordering guarantee is the READER CLOSING ITS PIPE FD BEFORE removing the marker — closing first
# (#335 review finding): the marker is the writer's only signal, so if it were removed BEFORE the
# fd is closed, the writer could observe "gone" and still write into a pipe whose read end remains
# technically open for the instant between the two, occasionally landing in the buffer instead of
# hitting a closed pipe (measured: 74/300 under load with a tight poll). Closing first makes
# "marker gone" imply "fd already closed", not just "probably about to be". The reader stage keeps
# `grep -q .` verbatim and preserves ITS OWN status via `exit "$_rc"`, so pipefail still promotes
# the reader's 0 against the writer's non-zero — #48's exact shape. The writer signals a timeout
# with a sentinel status (99) distinct from both the reader's 0 and a real SIGPIPE/EPIPE, so the
# two failure modes below get two different diagnoses instead of sharing one.
alive="$scratch/sigpipe-reader-alive"
alive_poll_ms=50
alive_timeout_s=5
: > "$alive"
set +e
{
  # SIGPIPE is ignored HERE, deliberately: whether a broken-pipe write terminates a bash builtin
  # via the signal, or merely fails and returns, is a host-dependent default (measured, #335: a
  # local aarch64 bash kills this subshell outright on the first bad write; GitHub Actions' ubuntu
  # runner does NOT — printf reports "write error: Broken pipe" to stderr and the shell keeps
  # going, so a design that assumed death-by-signal everywhere never went non-zero there and
  # reported "fixture broken" on every CI run). Ignoring the signal makes every host take the SAME
  # path: printf's own exit status, checked explicitly below, is what decides this — never process
  # death, and never a multi-thousand-line retry loop papering over the difference.
  trap '' PIPE
  printf '%s\n' "$sigpipe_dir/padded-so-the-listing-overruns-the-pipe-buffer-1.cobertura.xml"
  if ! kit_wait_gone "$alive" "$alive_timeout_s"; then
    exit 99
  fi
  # Strictly after the reader has closed its end — one write is enough (no volume needed once the
  # order is real) and it cannot succeed; with SIGPIPE ignored above, "cannot succeed" always means
  # "printf returns non-zero", not "bash dies".
  printf 'line-after-reader-gone\n' 2>/dev/null || exit 1
} | { grep -q .; _rc=$?; exec 0<&-; rm -f "$alive"; exit "$_rc"; }   # sigpipe-repro
naive_rc=$?
set -e
if [ "$naive_rc" -eq 99 ]; then
  echo "FAIL: kit_wait_gone timed out waiting for the reader to exit (marker still present:"
  echo "      $alive, ${alive_timeout_s}s after the writer's first line). This is a hang in the"
  echo "      harness, not the inversion #48 describes — the two diagnoses must not be confused."
  exit 1
fi
if [ "$naive_rc" -eq 0 ]; then
  echo "FAIL: fixture broken — the ordered pipeline succeeded on a write issued strictly after the"
  echo "      reader had already closed its end. With SIGPIPE ignored and printf's own status"
  echo "      checked explicitly, that write must report failure (naive_rc == 1, an EPIPE the"
  echo "      writer itself caught): that inversion is the whole defect of #48, and section 10 is"
  echo "      not reproducing it."
  exit 1
fi

# The real `find` shape is kept as a non-asserting smoke line: it is what #48 actually looked
# like, and the idiom guard below still needs one legitimate `sigpipe-repro`-tagged example to
# exempt. Its status is observed, never asserted on — asserting on it is exactly the
# load-sensitive claim the handshake above replaced.
find "$sigpipe_dir" -name '*.cobertura.xml' 2>/dev/null | grep -q . || true   # sigpipe-repro (smoke only, not asserted)

if ! any_match "$sigpipe_dir" -name '*.cobertura.xml'; then
  echo "FAIL: any_match reported NOTHING FOUND on a directory full of matches — the probe inverts"
  echo "      on large result sets, which is the whole defect of #48."
  exit 1
fi

# …and a path that does not exist must still answer "no", not abort. cleanup() runs on every exit
# path, so an aborting probe there would replace the real exit status with its own.
if any_match "$scratch/definitely-not-here" -name '*.cobertura.xml'; then
  echo "FAIL: any_match reported a match under a directory that does not exist"
  exit 1
fi

# The FIRST-match half of the same idiom owes the same tolerance (#98). Both claims — that a
# missing path does not abort the caller, and that what comes back is empty — are read off ONE
# search: two searches can drift apart in their fixture path and then quietly stop describing the
# same thing.
#
# The condition of an `if` is the only place this can be asserted without taking the suite down
# with it. Under this file's `set -euo pipefail` a bare `x=$(find missing …)` dies AT the
# assignment, so the `[ -n "$x" ] || { echo FAIL; tail -20 "$log"; }` written beneath both call
# sites never runs — and it is that FAIL line and its log tail, not find's own one-line error,
# that make a CI-only failure diagnosable at a distance (#74). `if` suppresses errexit for its
# condition, so the status is caught and reported here instead of inherited.
#
# NOT `if ! ( set -e; x=$(…) )`, which was the first spelling here: that `set -e` is INERT. Bash
# ignores an errexit set inside a compound command already running where errexit is suppressed,
# which the condition of an `if` is — so the subshell reported the failure only because the
# assignment happened to be its last command. Measured on this host: `( set -e; x=$(false); : )`
# exits 0. One appended statement and this case would have gone on passing against a probe with
# its tolerance stripped back out — the regression it exists to catch.
if ! first_hit=$(first_match "$scratch/definitely-not-here" -name '*.cobertura.xml'); then
  echo "FAIL: first_match reported failure on a path that does not exist, so a bare assignment"
  echo "      from it aborts its caller. The emptiness test written under each of its call sites"
  echo "      is only a test if the empty case can actually be reached."
  exit 1
fi
if [ -n "$first_hit" ]; then
  echo "FAIL: first_match returned '$first_hit' under a directory that does not exist"
  exit 1
fi

# The find-shaped stray scan that used to live here (anchored to `find … | grep -q .`, three
# paths) has one home now: scripts/sigpipe-idiom-check.py generalises it to every external
# streaming producer, across all of tests/ and scripts/ — including this file and tests/_lib —
# and its own golden suite (tests/sigpipe-idiom/test.sh, case i) proves the find shape specifically
# (#48, #123, #391).
echo "  [10] the find probes report what they found, not how the reader exited"

# ---------------------------------------------------------------------------
# 11. The prescribed LOCAL flow reaches a report, not just templates/ci-dotnet.yml's CI step
#     (#103, follow-up from #49/#95). #49 aligned report-template.md's documented "../coverage"
#     with where the CI template writes; nothing ever proved phase-6-verify.md's own step 2, run
#     on an agent's machine, produces that directory at all. The command is EXTRACTED from the
#     doc and actually executed against a real (transformed) project — not retyped here — so a
#     future edit to step 2 is what this case tracks, never a copy that can quietly drift from it.
# ---------------------------------------------------------------------------
cd "$KIT"
# `|| true` INSIDE the pipeline, same reason as the knob-scan at the top of this file: grep exits 1
# on no match, and under `set -o pipefail` that failing exit status — not head's or sed's — is what
# the assignment sees, so it would abort HERE under `set -e`, before the diagnostic on the next line
# ever ran. A bare `x=$(grep … | head -1 | sed …)` on a doc that has lost its command would die
# silently instead of naming what broke — exactly the hazard first_match/any_match exist to close.
PHASE6_STEP2=$({ grep -oE '`dotnet test[^`]*`' skills/migrate-legacy/references/phase-6-verify.md \
  || true; } | head -1 | sed 's/^`//; s/`$//')
[ -n "$PHASE6_STEP2" ] || {
  echo "FAIL: phase-6-verify.md step 2 no longer carries a backtick-quoted dotnet test command"
  exit 1
}

cp -R "$FIXTURE" "$scratch/local-flow"
python3 "$KIT/tests/xunit-v3/apply-transform.py" "$scratch/local-flow" > /dev/null
cd "$scratch/local-flow"
rm -rf coverage
local_flow_log="$scratch/local-flow-test.log"
if ! bash -c "$PHASE6_STEP2" > "$local_flow_log" 2>&1; then
  echo "FAIL: phase-6-verify.md step 2's own command ($PHASE6_STEP2) did not run green:"
  tail -25 "$local_flow_log"; exit 1
fi
lcount=$(sed -n 's/.*Total: \([0-9][0-9]*\).*/\1/p' "$local_flow_log" | head -1)
if [ "${lcount:-0}" -lt "$BASELINE_TESTS" ]; then
  echo "FAIL: phase-6-verify.md step 2's command ran ${lcount:-0} tests, baseline is $BASELINE_TESTS:"
  tail -25 "$local_flow_log"; exit 1
fi

# The documented disposition (report-template.md, #49): migration/report.json + "../coverage".
mkdir -p migration
python3 - "$KIT" <<'PY'
import json, pathlib, sys
kit = pathlib.Path(sys.argv[1])
r = json.loads((kit / "tests/report-dashboard/fixture-report.json").read_text(encoding="utf-8"))
r["coverage"] = {"cobertura": "../coverage"}
pathlib.Path("migration/report.json").write_text(json.dumps(r))
PY

report_log="$scratch/local-flow-report.log"
if python3 "$KIT/scripts/report-dashboard.py" migration/report.json -o migration/report.html \
     > "$report_log" 2>&1; then
  echo "  [11] phase-6-verify.md's own local procedure — run as documented — reaches a report"
else
  echo "FAIL: phase-6-verify.md step 2, run exactly as documented, does not reach a report — the"
  echo "      local flow the kit prescribes still can't produce what the config it prescribes reads:"
  cat "$report_log"; exit 1
fi
cd "$KIT"

echo "xunit v3 golden test OK"
