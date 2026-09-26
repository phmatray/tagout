#!/usr/bin/env bash
# Preflight golden test: requirements.json is the single source — the --json output is valid
# JSON, covers every manifest entry, and a missing REQUIRED item fails the run (exit 1).
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
# Registered rather than left unsaid: tests/_lib.sh's contract asks every converted suite to DECIDE
# about this guard, precisely so "forgot to call it" and "decided it does not apply" stop looking
# alike. This one runs kit scripts against the real repo, so it takes the check.
kit_guard kit_guard_samples_unchanged

# 1. The --json output is valid JSON (the preflight may exit 0 or 1 depending on the machine).
out=$(./scripts/preflight.sh --json || true)
echo "$out" | python3 -m json.tool >/dev/null

# 2. Every manifest entry appears in the output — nothing is silently skipped. A `tools` entry
#    carrying `for` (#642) is scoped to one caller and this default call passes no `--for`, so it
#    is expected to be ABSENT here, not present. Likewise a `tracker`-scoped entry (#504, #508,
#    #509) whose tracker isn't THIS repository's own (read the same way preflight.sh itself reads
#    it) is expected to be ABSENT — this repo is github-tracked, so the gitlab-only `glab CLI` and
#    azure-devops-only `az CLI` entries are expected ABSENT here, the github-only `gh CLI` entry
#    expected PRESENT; case 8 below pins the scoping itself against synthetic fixtures and case 11
#    pins the reverse on a gitlab fixture.
profile_tracker=$(./skills/profile-repo/scripts/repo-profile.sh tracker 2>/dev/null | awk 'NR==1{print $1}')
[ -n "$profile_tracker" ] || profile_tracker=github
python3 - "$out" "$profile_tracker" <<'PY'
import json, sys
out = json.loads(sys.argv[1])
profile_tracker = sys.argv[2]
req = json.load(open("requirements.json"))
names = {c["name"] for c in out["checks"]}
def in_scope(entry):
    if entry.get("for"):
        return False
    tracker = entry.get("tracker")
    return not tracker or tracker == profile_tracker
expected = [t["name"] for t in req["tools"] if in_scope(t)] + [m["name"] for m in req["mcps"] if in_scope(m)] \
         + ["skill " + s["name"] for s in req["sessionSkills"]]
missing = [n for n in expected if n not in names]
assert not missing, f"manifest entries absent from the output: {missing}"
# 3. requiredBy survives the round-trip (manifest → preflight → JSON) — skipping any entry this
#    call's own scope (tracker/for) already excluded from the output above.
by_name = {c["name"]: c for c in out["checks"]}
for entry in req["tools"] + req["mcps"] + req["sessionSkills"]:
    is_skill = entry not in req["tools"] + req["mcps"]
    if not is_skill and not in_scope(entry):
        continue
    want = entry.get("requiredBy")
    if want:
        name = entry["name"] if not is_skill else "skill " + entry["name"]
        got = by_name[name].get("requiredBy")
        assert got == want, f"requiredBy mismatch for {name}: {got} != {want}"
PY

# 2b. requirements.json's `for` value and run-all-tests.sh's hardcoded `--for run-all-tests` flag
#     are two independent string literals with nothing else tying them together (#642 verification
#     gap, code-review) — a typo in either would silently stop the .NET 6 runtime from ever being
#     checked on a full run, and case 9's synthetic manifest below can't catch that: it makes up its
#     own `for` value, which is always self-consistent by construction. Prove the two literals agree,
#     against the REAL requirements.json and the REAL preflight.sh, not a copy of either.
grep -qF 'preflight_for="--for run-all-tests"' scripts/run-all-tests.sh || {
  echo "FAIL [for-wiring]: scripts/run-all-tests.sh no longer forwards --for run-all-tests"
  exit 1
}
python3 - <<'PY'
import json
req = json.load(open("requirements.json"))
runtime = [t for t in req["tools"] if t["name"] == ".NET 6 runtime"]
assert len(runtime) == 1, f"requirements.json must declare exactly one .NET 6 runtime tools entry, got {len(runtime)}"
got_for = runtime[0].get("for")
assert got_for == "run-all-tests", \
    f"the .NET 6 runtime entry's for must match run-all-tests.sh's hardcoded --for flag: got {got_for!r}"
PY
for_out=$(./scripts/preflight.sh --for run-all-tests --json || true)
python3 - "$for_out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert ".NET 6 runtime" in {c["name"] for c in d["checks"]}, \
    f".NET 6 runtime must appear when preflight is called with --for run-all-tests: {d}"
PY
echo "  ok: --for wiring — requirements.json's for value and run-all-tests.sh's --for flag agree end-to-end"

# 4. A missing REQUIRED item ⇒ exit 1 and status "missing". PATH reduced to the bare minimum
#    needed to read the manifest (bash + python3 + dirname): git/dotnet become unfindable.
#    The scratch comes from the shared helper, so it is removed on EVERY exit path (#128). The
#    inline `rm -rf` this replaced ran only if the two assertions below passed — a suite that
#    failed here left its directory behind, which is the half of the cost #72 measured away.
tmp=$(kit_scratch)
for c in bash python3 dirname; do ln -s "$(command -v "$c")" "$tmp/$c"; done
if PATH="$tmp" bash ./scripts/preflight.sh --json > "$tmp/out.json" 2>/dev/null; then
  echo "the preflight should have failed without the required tooling"; exit 1
fi
grep -q '"status": "missing"' "$tmp/out.json"
# The .NET SDK is hard-required by ONE skill, and the report says which (#607): a lifecycle-only
# consumer reads `[hard-required by: migrate-legacy]` on that line instead of a bare failure.
jq -e '.checks[] | select(.name == "dotnet SDK >= 8") | .requiredBy == ["migrate-legacy"]' "$tmp/out.json" > /dev/null \
  || { echo "the dotnet SDK check does not name migrate-legacy as the skill that hard-requires it"; exit 1; }

# 5. An `mcps` entry may declare its OWN SDK floor (`requiresSdk`) — a server whose launcher needs a
#    newer SDK than the pipeline does. roseline is exactly that: `.mcp.json` starts it with `dnx`,
#    which ships only with the .NET 10 SDK, while the pipeline itself runs on `dotnet >= 8`. Below
#    the floor the server cannot start, so preflight must NAME it and the version it wants instead
#    of reporting the setup fine (#112). An entry WITHOUT the field is unaffected.
#
#    Driven against a SYNTHETIC kit root, not the real manifest: preflight resolves its manifest as
#    `$(dirname $0)/../requirements.json`, so a copy of the script beside a copy of a manifest is a
#    complete, isolated kit. The host's `dotnet` is stubbed for the same reason — the assertion has
#    to read the same on a .NET 10 machine and on a .NET 8 one.
#    The synthetic root comes from kit_scratch, like section 4's: this suite joined the shared
#    library in #128, so a bare `mktemp -d` here would sit outside KIT_LIB_TMP and nothing would
#    reclaim it (tests/lib section 9 says so by name). #112 landed this block on main while the
#    conversion was in flight, so the two are reconciled here rather than either being dropped.
tmp=$(kit_scratch)
mkdir -p "$tmp/scripts" "$tmp/bin"
cp ./scripts/preflight.sh "$tmp/scripts/preflight.sh"
cat > "$tmp/requirements.json" <<'JSON'
{
  "description": "synthetic manifest — the requiresSdk case",
  "tools": [
    { "name": "dotnet SDK >= 8", "level": "required", "test": "sdk_ok", "hint": "install an LTS .NET SDK" }
  ],
  "mcps": [
    { "name": "floored server", "match": "floored", "level": "required", "requiresSdk": "10", "hint": "launched with a newer-SDK launcher" },
    { "name": "launched server", "match": "launched", "level": "recommended", "requiresSdk": "10", "launcher": "kit-stub-launcher", "hint": "its own launcher starts it" },
    { "name": "unfloored server", "match": "unfloored", "level": "recommended", "hint": "no floor declared" }
  ],
  "sessionSkills": []
}
JSON
# A .NET 9 host: comfortably above the pipeline's own floor of 8, below the server's declared 10.
cat > "$tmp/bin/dotnet" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--list-sdks" ] && echo "9.0.100 [/stub/sdk]"
exit 0
SH
chmod +x "$tmp/bin/dotnet"
# No `claude` on this PATH, so the live MCP probe cannot run — which is the CI case, and the one
# where an unstartable server would otherwise be reported as a shrug ("unknown, confirm in session").
for c in bash python3 dirname awk grep; do ln -s "$(command -v "$c")" "$tmp/bin/$c"; done
if ! out=$(PATH="$tmp/bin" bash "$tmp/scripts/preflight.sh" --json 2>/dev/null); then
  echo "an mcps floor the host misses is a documented degradation, not a phase-0 hard fail"; exit 1
fi
python3 - "$out" <<'PY'
import json, sys
checks = {c["name"]: c for c in json.loads(sys.argv[1])["checks"]}

floored = checks["floored server"]
assert floored["status"] == "absent", \
    f"a server whose declared SDK floor is unmet must degrade loudly, got {floored['status']!r}"
assert "10" in floored["hint"], f"the report must name the required version: {floored['hint']!r}"
assert "9" in floored["hint"], f"...and what this host actually has: {floored['hint']!r}"

# The launcher is the VERDICT, the floor is the REMEDY — a host missing both must be told both, in
# that order. "kit-stub-launcher not on PATH" says the server cannot have started; "needs a .NET
# SDK >= 10, this host has 9" says what to install about it. Either alone leaves the reader stuck.
launched = checks["launched server"]
assert launched["status"] == "absent", \
    f"a declared launcher missing from PATH must degrade loudly, got {launched['status']!r}"
assert "kit-stub-launcher" in launched["hint"], \
    f"the report must name the launcher it probed: {launched['hint']!r}"
assert launched["hint"].index("kit-stub-launcher") < launched["hint"].index("10"), \
    f"the launcher verdict comes before the SDK remedy: {launched['hint']!r}"

# No floor declared ⇒ byte-for-byte the behaviour that shipped before this field existed.
unfloored = checks["unfloored server"]
assert unfloored["status"] == "unknown", \
    f"an entry without requiresSdk must be unaffected, got {unfloored['status']!r}"
assert "claude CLI absent" in unfloored["hint"], \
    f"an entry without requiresSdk must keep its old hint: {unfloored['hint']!r}"
PY

# 5b. The launcher probe on a host that CLEARS the floor — which is the case the floor cannot see,
#     and the reason `launcher` exists as a field of its own (#155). A .NET 10 SDK is present, so
#     `requiresSdk` is satisfied and says nothing; the only remaining question is whether the
#     executable that starts the server is on PATH, and preflight must answer it.
#
#     A second synthetic root rather than a second `dotnet` stub in the first: section 6 re-runs
#     against `$tmp` and asserts the .NET 9 floor note is still there, so raising that host's SDK
#     would quietly delete section 6's subject. Same manifest, copied — one source, two hosts.
tmp10=$(kit_scratch)
mkdir -p "$tmp10/scripts" "$tmp10/bin"
cp ./scripts/preflight.sh "$tmp10/scripts/preflight.sh"
cp "$tmp/requirements.json" "$tmp10/requirements.json"
cat > "$tmp10/bin/dotnet" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--list-sdks" ] && echo "10.0.100 [/stub/sdk]"
exit 0
SH
chmod +x "$tmp10/bin/dotnet"
for c in bash python3 dirname awk grep; do ln -s "$(command -v "$c")" "$tmp10/bin/$c"; done

# `kit-stub-launcher` is a name no host has, so "absent" here is a measurement and not a bet on
# what the machine running the suite happens to have installed.
if ! out=$(PATH="$tmp10/bin" bash "$tmp10/scripts/preflight.sh" --json 2>/dev/null); then
  echo "a launcher the host misses is a documented degradation, not a phase-0 hard fail"; exit 1
fi
python3 - "$out" <<'PY'
import json, sys
checks = {c["name"]: c for c in json.loads(sys.argv[1])["checks"]}

launched = checks["launched server"]
assert launched["status"] == "absent", \
    f"an SDK above the floor does not prove the launcher is on PATH, got {launched['status']!r}"
assert "kit-stub-launcher" in launched["hint"], \
    f"the report must name the launcher it probed: {launched['hint']!r}"
assert "this host has" not in launched["hint"], \
    f"the floor is met here, so it must not be offered as the remedy: {launched['hint']!r}"

# The floor's own entry declares no launcher, so on a host that clears the floor it is back to the
# shrug — proving 5b's `absent` came from the launcher probe and from nothing else.
floored = checks["floored server"]
assert floored["status"] == "unknown", \
    f"a met floor with no launcher declared must be unaffected, got {floored['status']!r}"
assert "claude CLI absent" in floored["hint"], f"...with its old hint: {floored['hint']!r}"

unfloored = checks["unfloored server"]
assert unfloored["status"] == "unknown", \
    f"an entry with neither field must be unaffected, got {unfloored['status']!r}"
PY

# ...and the companion: put that same launcher ON the PATH and the entry is byte-for-byte what it
# was before the field existed. Without this, "absent" above would be equally well explained by
# preflight reporting every entry that declares a launcher as absent.
printf '#!/bin/sh\nexit 0\n' > "$tmp10/bin/kit-stub-launcher"
chmod +x "$tmp10/bin/kit-stub-launcher"
if ! out=$(PATH="$tmp10/bin" bash "$tmp10/scripts/preflight.sh" --json 2>/dev/null); then
  echo "a launcher present on PATH must not fail the preflight"; exit 1
fi
python3 - "$out" <<'PY'
import json, sys
checks = {c["name"]: c for c in json.loads(sys.argv[1])["checks"]}
launched = checks["launched server"]
assert launched["status"] == "unknown", \
    f"a launcher on PATH restores the prior behaviour, got {launched['status']!r}"
assert "claude CLI absent" in launched["hint"], \
    f"...including its hint, unprefixed: {launched['hint']!r}"
PY

# 6. The floor EXPLAINS an absence; it does not excuse one. Give the same host a `claude` that can
#    see the server is not there, and a `level: required` entry must still hard-fail phase 0 — only
#    now the message says which SDK it wanted. Softening that would trade one silent failure for
#    another: green on a host that cannot run it, for a pipeline started without the engine every
#    phase of it depends on.
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/claude"   # a CLI that lists no servers at all
chmod +x "$tmp/bin/claude"
if PATH="$tmp/bin" bash "$tmp/scripts/preflight.sh" --json > "$tmp/seen.json" 2>/dev/null; then
  echo "a REQUIRED mcp the host can SEE is absent must still fail the preflight"; exit 1
fi
python3 - "$tmp/seen.json" <<'PY'
import json, sys
checks = {c["name"]: c for c in json.load(open(sys.argv[1]))["checks"]}
floored = checks["floored server"]
assert floored["status"] == "missing", \
    f"an observed absence at level=required stays a hard fail, got {floored['status']!r}"
assert "10" in floored["hint"], f"...and still names the floor it wanted: {floored['hint']!r}"
PY

# 7. AdrMcp ships the same way roseline does, at a LOWER level: `.mcp.json` starts it with `dnx`
#    (the .NET 10 SDK's launcher), so the manifest declares the launcher and the floor — but the
#    entry is `recommended`, because every consumer degrades to reading `docs/adr/*.md` frontmatter
#    (#316). What is asserted here is the manifest DECLARATION — every field of it can go red on a
#    typo — plus the status preflight actually reported for the entry. That a `recommended` level
#    cannot become a phase-0 hard fail is proven generically by cases 5/5b against a synthetic kit,
#    not re-asserted here where `preflight.sh` only ever emits `missing` for `level = required` and
#    the assertion would hold by construction.
#
#    `$out` from case 1 is long gone by here — cases 5 and 5b rebind it to a SYNTHETIC kit's report —
#    so this case re-runs the REAL preflight rather than reading a stale variable that would assert
#    against the wrong manifest entirely.
real_out=$(./scripts/preflight.sh --json || true)
python3 - "$real_out" <<'PY'
import json, sys
out = json.loads(sys.argv[1])
req = json.load(open("requirements.json"))
adr = [m for m in req["mcps"] if m.get("match") == "adr"]
assert len(adr) == 1, f"requirements.json must declare exactly one `match: adr` mcps entry, got {len(adr)}"
adr = adr[0]
assert adr["name"] == "AdrMcp connected", f"unexpected name: {adr['name']!r}"
assert adr["level"] == "recommended", \
    f"AdrMcp degrades to reading docs/adr/*.md, so it is recommended, not {adr['level']!r}"
assert adr.get("launcher") == "dnx", f"the launcher is how .mcp.json starts it: {adr.get('launcher')!r}"
assert adr.get("requiresSdk") == "10", f"dnx ships with the .NET 10 SDK: {adr.get('requiresSdk')!r}"
assert "docs/adr" in adr["hint"], f"the hint must name the fallback the consumers use: {adr['hint']!r}"
seen = {c["name"]: c for c in out["checks"]}
assert "AdrMcp connected" in seen, "preflight must report the manifest entry"
status = seen["AdrMcp connected"]["status"]
assert status in ("ok", "absent", "unknown"), \
    f"a recommended entry degrades in a documented way; 'missing' would be a phase-0 hard fail, got {status!r}"
PY

# 8. Tracker-scoped prerequisites (#504): an entry naming `tracker` is asked for only when the
#    profile's own Tracker line names that same tracker — never when it names a different one.
#    Same synthetic-kit pattern as case 5: a copy of preflight.sh beside a copy of repo-profile.sh
#    (unmodified — the real script, so this proves the two actually agree) and a synthetic
#    manifest, run against two fixture repos that differ only in their committed Tracker line.
trk=$(kit_scratch)
mkdir -p "$trk/scripts" "$trk/skills/profile-repo/scripts" "$trk/bin"
cp ./scripts/preflight.sh "$trk/scripts/preflight.sh"
cp ./skills/profile-repo/scripts/repo-profile.sh "$trk/skills/profile-repo/scripts/repo-profile.sh"
cat > "$trk/requirements.json" <<'JSON'
{
  "description": "synthetic manifest — the tracker-scoped case",
  "tools": [
    { "name": "dotnet SDK >= 8", "level": "required", "test": "sdk_ok", "hint": "install an LTS .NET SDK" },
    { "name": "gh CLI (authenticated)", "level": "recommended", "test": "gh auth status", "tracker": "github", "hint": "GitHub publishing" },
    { "name": "az CLI + azure-devops extension", "level": "recommended", "test": "az extension show --name azure-devops", "tracker": "azure-devops", "hint": "Azure DevOps work items" },
    { "name": "bare tool", "level": "recommended", "test": "false" }
  ],
  "mcps": [],
  "sessionSkills": []
}
JSON
for c in bash python3 dirname awk grep sed git head cat cut wc find basename tr sort; do
  ln -sf "$(command -v "$c")" "$trk/bin/$c"
done
cat > "$trk/bin/dotnet" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--list-sdks" ] && echo "9.0.100 [/stub/sdk]"
exit 0
SH
chmod +x "$trk/bin/dotnet"
# No `gh` anywhere on this PATH — the case this proves is that a gitlab-tracked repo is never
# asked for it at all, not that a missing `gh` degrades gracefully (case 4 already covers that).

gitlab_fx=$(kit_scratch)
git -C "$gitlab_fx" init -q -b main
mkdir -p "$gitlab_fx/.claude/skills"
printf -- '# Repo profile\n\n## Tracker\n- **Tracker:** gitlab (gitlab.com) — fixture.\n' \
  > "$gitlab_fx/.claude/skills/repo-profile.md"
out=$(cd "$gitlab_fx" && PATH="$trk/bin" bash "$trk/scripts/preflight.sh" --json 2>/dev/null || true)
python3 - "$out" <<'PY'
import json, sys
checks = {c["name"]: c for c in json.loads(sys.argv[1])["checks"]}
assert "gh CLI (authenticated)" not in checks, \
    f"a gitlab-tracked profile must not be asked for the GitHub-only CLI: {checks}"
assert "az CLI + azure-devops extension" not in checks, \
    f"a gitlab-tracked profile must not be asked for the Azure-DevOps-only CLI: {checks}"
# Regression (code-review, #504): an entry with neither `hint` nor `tracker` must still be
# reported, not silently swallowed by the column shift an empty (rather than "-") hint field
# causes once `tracker` sits after it — on ANY host whose profile resolves a tracker, not just
# a github one.
bare = checks.get("bare tool")
assert bare is not None, f"an entry with no hint/tracker must never be dropped: {checks}"
assert bare["status"] == "absent", f"...and checked normally: {bare}"
assert bare["hint"] == "-", f"...with the placeholder hint, not a value shifted from 'tracker': {bare}"
PY

github_fx=$(kit_scratch)
git -C "$github_fx" init -q -b main
mkdir -p "$github_fx/.claude/skills"
printf -- '# Repo profile\n\n## Tracker\n- **Tracker:** github (github.com) — fixture.\n' \
  > "$github_fx/.claude/skills/repo-profile.md"
out=$(cd "$github_fx" && PATH="$trk/bin" bash "$trk/scripts/preflight.sh" --json 2>/dev/null || true)
python3 - "$out" <<'PY'
import json, sys
checks = {c["name"]: c for c in json.loads(sys.argv[1])["checks"]}
assert "gh CLI (authenticated)" in checks, \
    f"a github-tracked profile must still be asked for gh CLI, exactly as before: {checks}"
assert "az CLI + azure-devops extension" not in checks, \
    f"a github-tracked profile must not be asked for the Azure-DevOps-only CLI: {checks}"
bare = checks.get("bare tool")
assert bare is not None, f"an entry with no hint/tracker must never be dropped: {checks}"
assert bare["status"] == "absent", f"...and checked normally: {bare}"
assert bare["hint"] == "-", f"...with the placeholder hint, not a value shifted from 'tracker': {bare}"
PY

azure_fx=$(kit_scratch)
git -C "$azure_fx" init -q -b main
mkdir -p "$azure_fx/.claude/skills"
printf -- '# Repo profile\n\n## Tracker\n- **Tracker:** azure-devops (dev.azure.com/acme/Shop) — fixture.\n' \
  > "$azure_fx/.claude/skills/repo-profile.md"
out=$(cd "$azure_fx" && PATH="$trk/bin" bash "$trk/scripts/preflight.sh" --json 2>/dev/null || true)
python3 - "$out" <<'PY'
import json, sys
checks = {c["name"]: c for c in json.loads(sys.argv[1])["checks"]}
assert "az CLI + azure-devops extension" in checks, \
    f"an azure-devops-tracked profile must be asked for the az CLI: {checks}"
assert "gh CLI (authenticated)" not in checks, \
    f"an azure-devops-tracked profile must not be asked for the GitHub-only CLI: {checks}"
bare = checks.get("bare tool")
assert bare is not None, f"an entry with no hint/tracker must never be dropped: {checks}"
assert bare["status"] == "absent", f"...and checked normally: {bare}"
assert bare["hint"] == "-", f"...with the placeholder hint, not a value shifted from 'tracker': {bare}"
PY

# 9. Archify (#476) is declared the way the other session skills are: a `sessionSkills` entry at
#    level `recommended`, carrying its `when` text and NOTHING else — no `requiredBy`, no `token`.
#    Those two are what tests/skills/check-frontmatter.py cross-checks against a skill's
#    `compatibility` frontmatter, so adding them would misdeclare a recommended capability as some
#    skill's hard precondition and force a token into a compatibility line already near its ceiling.
#
#    The LEVEL is asserted against the MANIFEST and the STATUS against the REPORT — the same split
#    case 7 makes for AdrMcp, and here it is forced: preflight emits {status, name, hint,
#    requiredBy?} and never a `level` field, so "level recommended" is simply not readable back out
#    of --json. Nor is the run's exit code an assertion this case can make: `preflight.sh` exits 1
#    on any host whose REQUIRED roseline entry is unobservable, which is why case 1 above tolerates
#    either code. What proves a diagram can never hard-fail phase 0 is the status being `unknown` —
#    only `level: required` ever reaches `missing`, and the `skill)` branch cannot emit it at all.
real_out=$(./scripts/preflight.sh --json || true)
python3 - "$real_out" <<'PY'
import json, sys
out = json.loads(sys.argv[1])
req = json.load(open("requirements.json"))
arch = [s for s in req["sessionSkills"] if s.get("name") == "archify"]
assert len(arch) == 1, \
    f"requirements.json must declare exactly one `archify` sessionSkills entry, got {len(arch)}"
arch = arch[0]
assert arch["level"] == "recommended", \
    f"archify degrades to the mermaid fence the phase already writes, so it is recommended, not {arch['level']!r}"
assert "requiredBy" not in arch, \
    "archify is hard-required at no preconditions step — a requiredBy would demand a compatibility token"
assert "token" not in arch, \
    "no requiredBy means no compatibility token to cross-check (tests/skills/check-frontmatter.py)"
assert "mermaid" in arch["when"], \
    f"the when text must name the degradation its consumers fall back to: {arch['when']!r}"
seen = {c["name"]: c for c in out["checks"]}
assert "skill archify" in seen, f"preflight must report the manifest entry: {sorted(seen)}"
status = seen["skill archify"]["status"]
assert status == "unknown", \
    f"a session capability is unobservable from bash, so it is unknown, got {status!r}"
assert arch["when"] in seen["skill archify"]["hint"], \
    f"the hint must carry the when text a reader acts on: {seen['skill archify']['hint']!r}"
PY

# 10. A `for`-scoped prerequisite (#642) is checked ONLY when preflight is invoked with a matching
#     `--for <name>` — #504's tracker-scoped shape, applied to a caller instead of a tracker, so a
#     plain `preflight.sh` run (a consumer's phase 0) never sees a fixture-only prerequisite like the
#     .NET 6 runtime that only `run-all-tests.sh` needs. Same synthetic-kit pattern as case 8: a copy
#     of preflight.sh beside a copy of repo-profile.sh (unmodified) and a synthetic manifest, with a
#     stubbed `dotnet` whose `--list-runtimes` output this case flips mid-way to prove the
#     `runtime_ok` probe both ways.
c9=$(kit_scratch)
mkdir -p "$c9/scripts" "$c9/skills/profile-repo/scripts" "$c9/bin"
cp ./scripts/preflight.sh "$c9/scripts/preflight.sh"
cp ./skills/profile-repo/scripts/repo-profile.sh "$c9/skills/profile-repo/scripts/repo-profile.sh"
cat > "$c9/requirements.json" <<'JSON'
{
  "description": "synthetic manifest — the for-scoped case",
  "tools": [
    { "name": "runtime six", "level": "required", "test": "runtime_ok 6", "for": "run-all-tests", "hint": "h" },
    { "name": "bare recommended", "level": "recommended", "test": "false", "hint": "h2" }
  ],
  "mcps": [],
  "sessionSkills": []
}
JSON
cat > "$c9/bin/dotnet" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --list-sdks) echo "9.0.100 [/stub/sdk]" ;;
  --list-runtimes) echo "Microsoft.NETCore.App 8.0.20 [/stub/shared/Microsoft.NETCore.App]" ;;
esac
exit 0
SH
chmod +x "$c9/bin/dotnet"
for c in bash python3 dirname awk grep sed git head cat cut wc find basename tr sort; do
  ln -sf "$(command -v "$c")" "$c9/bin/$c"
done

# (a) no --for: exit 0, and the for-scoped entry never appears.
rc=0
out=$(PATH="$c9/bin" bash "$c9/scripts/preflight.sh" --json 2>/dev/null) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [for-scoped/a]: expected exit 0 with no --for, got $rc"; echo "$out"; exit 1; }
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "runtime six" not in {c["name"] for c in d["checks"]}, d' \
  || { echo "FAIL [for-scoped/a]: 'runtime six' must be absent with no --for"; exit 1; }

# (b) --for run-all-tests, no 6.x runtime yet: exit 1, status missing.
rc=0
out=$(PATH="$c9/bin" bash "$c9/scripts/preflight.sh" --for run-all-tests --json 2>/dev/null) || rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL [for-scoped/b]: expected exit 1, got $rc"; echo "$out"; exit 1; }
printf '%s' "$out" | python3 -c '
import json, sys
checks = {c["name"]: c for c in json.load(sys.stdin)["checks"]}
assert checks["runtime six"]["status"] == "missing", checks["runtime six"]
' || { echo "FAIL [for-scoped/b]: 'runtime six' must be status=missing"; exit 1; }

# (c) same call, once the stub ALSO lists a 6.x runtime: exit 0, status ok.
cat > "$c9/bin/dotnet" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --list-sdks) echo "9.0.100 [/stub/sdk]" ;;
  --list-runtimes)
    echo "Microsoft.NETCore.App 8.0.20 [/stub/shared/Microsoft.NETCore.App]"
    echo "Microsoft.NETCore.App 6.0.36 [/stub/shared/Microsoft.NETCore.App]"
    ;;
esac
exit 0
SH
chmod +x "$c9/bin/dotnet"
rc=0
out=$(PATH="$c9/bin" bash "$c9/scripts/preflight.sh" --for run-all-tests --json 2>/dev/null) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [for-scoped/c]: expected exit 0 once a 6.x runtime is listed, got $rc"; echo "$out"; exit 1; }
printf '%s' "$out" | python3 -c '
import json, sys
checks = {c["name"]: c for c in json.load(sys.stdin)["checks"]}
assert checks["runtime six"]["status"] == "ok", checks["runtime six"]
' || { echo "FAIL [for-scoped/c]: 'runtime six' must be status=ok once the 6.x runtime is listed"; exit 1; }

# (d) a different --for: the entry is skipped exactly as with no --for at all.
rc=0
out=$(PATH="$c9/bin" bash "$c9/scripts/preflight.sh" --for other --json 2>/dev/null) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [for-scoped/d]: expected exit 0 with an unrelated --for, got $rc"; echo "$out"; exit 1; }
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "runtime six" not in {c["name"] for c in d["checks"]}, d' \
  || { echo "FAIL [for-scoped/d]: 'runtime six' must stay absent under an unrelated --for"; exit 1; }

echo "  ok: for-scoped — an entry carrying 'for' is asked for only when --for names it"

# 11. AC6 (#508): the REAL requirements.json's `glab CLI (authenticated)` entry (tracker: gitlab)
#     is asked for on a gitlab-tracked profile, and the REAL `gh CLI (authenticated)` entry
#     (tracker: github) is not — case 8's tracker-scoping mechanism, now pinned against the actual
#     manifest (not a synthetic one) so a wrong or missing `tracker` value on the new entry fails
#     here. No PATH stubbing: like case 1, this tolerates either exit status and reads the report.
gitlab_real_fx=$(kit_scratch)
mkdir -p "$gitlab_real_fx/.claude/skills"
printf -- '# Repo profile\n\n## Tracker\n- **Tracker:** gitlab (gitlab.com) — fixture.\n' \
  > "$gitlab_real_fx/.claude/skills/repo-profile.md"
out=$(cd "$gitlab_real_fx" && "$KIT/scripts/preflight.sh" --json 2>/dev/null || true)
printf '%s' "$out" | python3 -c '
import json, sys
checks = {c["name"]: c for c in json.load(sys.stdin)["checks"]}
assert "glab CLI (authenticated)" in checks, \
    f"a gitlab-tracked profile must be asked for the real glab CLI entry: {checks}"
assert "gh CLI (authenticated)" not in checks, \
    f"a gitlab-tracked profile must not be asked for the GitHub-only gh CLI: {checks}"
' || { echo "FAIL [AC6]: see above"; exit 1; }
echo "  ok: AC6 — a gitlab profile lists glab CLI and not gh CLI (the real requirements.json)"

echo "preflight golden test OK"
