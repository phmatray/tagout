#!/usr/bin/env bash
# Golden test for scripts/run-all-tests.sh (#170): the three exits, plus the guard that keeps its
# hand-written plan from drifting out of step with .github/workflows/ci.yml as CI grows.
set -euo pipefail
cd "$(dirname "$0")/../.."

RUNNER="./scripts/run-all-tests.sh"
[ -x "$RUNNER" ] || { echo "FAIL: $RUNNER missing or not executable"; exit 1; }
KIT="$PWD"

# Scratch dirs and EXIT trap come from the shared preamble (#72).
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"

# ---------------------------------------------------------------- 1. exit 2: missing prerequisite
#
# run-all-tests.sh builds its whole plan as bash arrays of string literals before it ever touches
# the filesystem, and the preflight guard runs before any of them execute — so a stub tree only
# needs the runner itself plus a preflight.sh that refuses. Nothing else in the kit has to exist.
stub=$(kit_scratch)
mkdir -p "$stub/scripts"
cp "$KIT/scripts/run-all-tests.sh" "$stub/scripts/run-all-tests.sh"
cat > "$stub/scripts/preflight.sh" <<'EOF'
#!/usr/bin/env bash
echo "MISSING X  stub prerequisite — always refuses, for the exit-2 golden test" >&2
exit 1
EOF
chmod +x "$stub/scripts/run-all-tests.sh" "$stub/scripts/preflight.sh"

rc=0
stub_out=$(bash "$stub/scripts/run-all-tests.sh" 2>"$stub/stderr.log") || rc=$?
stub_err=$(cat "$stub/stderr.log")
[ "$rc" -eq 2 ] || {
  echo "FAIL [exit-2]: expected exit 2, got $rc"; echo "$stub_out"; echo "$stub_err"; exit 1; }
printf '%s' "$stub_err" | grep -qF 'PREREQUISITE' || {
  echo "FAIL [exit-2]: stderr did not mention PREREQUISITE:"; echo "$stub_err"; exit 1; }
if printf '%s' "$stub_out" | grep -q '^suite '; then
  echo "FAIL [exit-2]: suite output was printed despite the missing prerequisite:"; echo "$stub_out"
  exit 1
fi
echo "  ok: exit-2 — a missing prerequisite refuses before any suite runs, and says so on stderr"

# ---------------------------------------------------------------- 2. exit 1: a failing suite is named
#
# The real plan is hand-written and has no override hook (by design — it must run with no
# dependencies), so proving "a failing suite stops the run and is named" needs a real copy of the
# tree with one suite broken. The worktree this runs from is a LINKED worktree, so .git here is a
# small file rather than the object store — a full copy is a few megabytes, not the whole repo's
# history.
fixture="$(kit_scratch)/kit"
mkdir -p "$fixture"
# bin/ and obj/ are gitignored (not copied by a real clone) but may exist on disk here: this suite
# runs LAST in ci.yml's `kit` job, after the "Fixture LegacyShop" step has already restored and
# built samples/LegacyShop. `git add -A` below would skip them anyway (the fixture inherits
# .gitignore), so copying them first is pure rsync I/O for content nothing downstream reads —
# `--quick` never runs `dotnet test` against this fixture.
rsync -a --exclude='.git' --exclude='.claude/worktrees' --exclude='.worktrees' \
  --exclude='bin/' --exclude='obj/' "$KIT/" "$fixture/"
# Not a clone of KIT's history — a fresh, empty repository, committed once so every file is
# tracked. worktrees-ignored.sh (gate 1) needs to BE a git repo; ci-wiring-check.py (gate 2) needs
# every tests/*/test.sh to be staged, the same signal a real clone gives it.
git -C "$fixture" init -q -b main
cat > "$fixture/tests/lib/test.sh" <<'EOF'
#!/usr/bin/env bash
echo "deliberately broken for the run-all-tests golden test" >&2
exit 1
EOF
chmod +x "$fixture/tests/lib/test.sh"
git -C "$fixture" add -A
git -C "$fixture" -c user.email=t@example.com -c user.name="Golden Test" commit -q -m fixture

rc=0
fixture_out=$(cd "$fixture" && ./scripts/run-all-tests.sh --quick 2>&1) || rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL [exit-1]: expected exit 1, got $rc"; echo "$fixture_out"; exit 1; }
printf '%s' "$fixture_out" | grep -qF 'FAIL tests/lib/test.sh' || {
  echo "FAIL [exit-1]: the failing suite was not named:"; echo "$fixture_out"; exit 1; }
echo "  ok: exit-1 — a failing suite stops the run (fail-fast) and is named"

# ---------------------------------------------------------------- 3. no drift from ci.yml
#
# Every `run:` command in ci.yml's `kit` job must appear in --list's output, except the documented
# skips: `uses:` steps (no `run:` at all), the PyYAML install (a CI setup step, not a check to
# reproduce — preflight.sh is what enforces PyYAML locally), and the network-only renovate
# acceptance gate (only added by --with-network). This is the guard from the issue's rejected
# Approach C, folded in as a TEST rather than as the generation mechanism: the plan stays
# hand-written, but it cannot silently fall behind what CI actually runs.
python3 - "$KIT" <<'PY'
import subprocess, sys, yaml

kit = sys.argv[1]
with open(f"{kit}/.github/workflows/ci.yml") as f:
    doc = yaml.safe_load(f)
steps = doc["jobs"]["kit"]["steps"]

# `--with-network` so the plan lists the renovate acceptance suite too: it is opt-in at run time
# (it needs npx and RE2), but CI runs it, and the drift check is about what the plan CAN run.
listing = subprocess.run(
    [f"{kit}/scripts/run-all-tests.sh", "--list", "--with-network"],
    cwd=kit, capture_output=True, text=True, check=True,
).stdout

DOCUMENTED_SKIPS = {
    "Install Python test dependencies",
    "renovate.json is a config Renovate actually accepts",
}

reproducible = [s for s in steps if "run" in s and s.get("name") not in DOCUMENTED_SKIPS]

# A ci.yml step must match ONE --list ENTRY, exactly — not merely occur somewhere in the output.
#
# The old test asked `needle not in listing`: a substring search over the whole blob. That cannot
# tell two steps apart (#579). Two ci.yml steps sharing a first line both matched the single entry
# that spelled it, and a step whose command is a prefix of a longer entry matched that entry — so a
# step genuinely absent from the plan was reported present, and the guard passed on a coincidence.
#
# Comparing entry-for-entry removes the coincidence: `--list` prints "gate <cmd>" / "suite <cmd>",
# so the kind word is stripped and what remains must equal the step's first line. Both sides are
# normalised for a leading "./" — ci.yml spells a suite "./tests/x/test.sh" while --list prints the
# bare path — and nothing else, so the match stays exact rather than fuzzy.
#
# This is deliberately stricter than "count the substring occurrences": `scripts/parse-sweep.sh` and
# `scripts/preflight.sh` each legitimately occur in TWO entries (the plain gate, and the bash-3.2
# docker gate / the --json gate). Those are distinct steps with distinct entries, and an exact
# comparison pairs each correctly where an occurrence count would refuse both.
def _norm(cmd):
    cmd = cmd.strip()
    return cmd[2:] if cmd.startswith("./") else cmd

entries = []
for line in listing.splitlines():
    parts = line.split(None, 1)          # "gate ./scripts/x.sh" -> ["gate", "./scripts/x.sh"]
    if len(parts) == 2:
        entries.append(_norm(parts[1]))

missing = []
for step in reproducible:
    first_line = step["run"].strip().splitlines()[0]
    needle = _norm(first_line)
    found = entries.count(needle)
    if found != 1:
        missing.append((step.get("name", "(unnamed)"), first_line, found))

if missing:
    print("FAIL [drift]: every ci.yml step must match exactly one run-all-tests.sh --list entry:")
    for name, line, found in missing:
        what = "no entry" if found == 0 else f"{found} entries"
        print(f"  - {name!r}: {line!r} matched {what}")
    sys.exit(1)
print(f"  ok: drift — each of {len(reproducible)} reproducible ci.yml steps matches exactly one --list entry")
PY

# ---------------------------------------------------------------- 4. --for is forwarded, --quick omits it (#642)
#
# A full run must ask preflight.sh for the run-all-tests-scoped prerequisites (the .NET 6 runtime,
# #642) and --quick must not, since --quick already skips the one gate that needs it. The stub
# preflight.sh below records the arguments IT received rather than exercising the real preflight.sh
# (case 1 already covers that script's own refusal path against a genuine PREREQUISITE), so this
# proves only what run-all-tests.sh forwards.
stub4=$(kit_scratch)
mkdir -p "$stub4/scripts"
cp "$KIT/scripts/run-all-tests.sh" "$stub4/scripts/run-all-tests.sh"
cat > "$stub4/scripts/preflight.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/../args.log"
case " $* " in
  *" --for run-all-tests "*) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$stub4/scripts/run-all-tests.sh" "$stub4/scripts/preflight.sh"

rc=0
full_out=$(bash "$stub4/scripts/run-all-tests.sh" 2>"$stub4/stderr.log") || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [for-forward/full]: expected exit 2, got $rc"; cat "$stub4/stderr.log"; exit 1; }
grep -qF 'PREREQUISITE' "$stub4/stderr.log" || {
  echo "FAIL [for-forward/full]: stderr did not mention PREREQUISITE:"; cat "$stub4/stderr.log"; exit 1; }
grep -qF -- '--for run-all-tests' "$stub4/args.log" || {
  echo "FAIL [for-forward/full]: preflight.sh was not called with --for run-all-tests:"; cat "$stub4/args.log"; exit 1; }
if printf '%s' "$full_out" | grep -qE '^(ok|FAIL) '; then
  echo "FAIL [for-forward/full]: a gate/suite line was printed despite the missing prerequisite:"
  echo "$full_out"; exit 1
fi

rm -f "$stub4/args.log"
rc=0
quick_out=$(bash "$stub4/scripts/run-all-tests.sh" --quick 2>"$stub4/quick-stderr.log") || rc=$?
[ "$rc" -ne 2 ] || {
  echo "FAIL [for-forward/quick]: --quick must not refuse over the run-all-tests-scoped prerequisite"
  cat "$stub4/quick-stderr.log"; exit 1; }
if grep -qF -- '--for' "$stub4/args.log"; then
  echo "FAIL [for-forward/quick]: --quick must not ask preflight.sh for the scoped prerequisites:"
  cat "$stub4/args.log"; exit 1
fi
echo "  ok: --for — a full run asks preflight.sh for run-all-tests' own prerequisites, --quick does not"

echo "run-all-tests golden test OK"
