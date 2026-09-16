#!/usr/bin/env bash
# run-all-tests.sh — one command that verifies what CI's `kit` job verifies (#170).
#
# The documented alternative — `for t in tests/*/test.sh; do "$t" || break; done` — verifies
# STRICTLY LESS than CI: `.github/workflows/ci.yml`'s `kit` job also runs a dozen structural gates
# (worktrees-ignored, ci-wiring-check, parse-sweep, pinned-literals-check, JSON/YAML validity, the
# fixture build...) that are not suites at all and therefore never appear in that loop. Passing the
# loop is not passing CI, and nothing said so.
#
# Exit 2 exists because of a measured incident: on a machine missing PyYAML — a dependency CI
# installs in a workflow step instead of declaring — the loop above and the structural gates each
# reported the absence in their own vocabulary, one of them (tests/ci-wiring) as 14 lines accusing
# its own fixtures of being buggy. Forty-plus failing lines, all one missing prerequisite. So this
# script checks prerequisites FIRST, via scripts/preflight.sh (which requirements.json now declares
# PyYAML to, #170 Task 1), and refuses with a distinct exit code and message before running anything
# whose failure would otherwise be misread as a real regression.
#
# Usage: scripts/run-all-tests.sh [--quick] [--with-network] [--list]
#   --quick        skip the dotnet fixture build/test (samples/LegacyShop) — everything else runs.
#                  Also skips the prerequisites declared `for: run-all-tests` (the .NET 6 runtime,
#                  #642), since that fixture is the only thing on this list that needs it.
#   --with-network adds the renovate.json acceptance gate, which shells out to `npx`, and the
#                  parse sweep under a real bash 3.2, which pulls `bash:3.2` through Docker (#144);
#                  both need network access, so both are skipped by default and this script also
#                  runs offline.
#   --list         print the plan (one `gate <cmd>` / `suite <path>` line per item) and exit 0.
#                  Does not touch prerequisites, so it is cheap and always available — this is what
#                  tests/run-all-tests/test.sh's anti-drift case relies on.
#
# Exit codes:
#   0  everything CI checks passed locally (or --list printed the plan)
#   1  a real failure — the failing item is named, with its last ~25 lines of output
#   2  a prerequisite is missing — nothing was judged, see scripts/preflight.sh's own output. A
#      full run also checks the prerequisites declared `for: run-all-tests` (the .NET 6 runtime
#      samples/LegacyShop needs to RUN, not just build, #642); --quick checks neither those nor
#      anything else this script's own gates/suites need beyond what preflight.sh always checks.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT_DIR="$(cd "$HERE/.." && pwd)"
cd "$KIT_DIR"

QUICK=0
WITH_NETWORK=0
LIST=0
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --with-network) WITH_NETWORK=1 ;;
    --list) LIST=1 ;;
    *) printf 'run-all-tests.sh: unknown flag %s\n' "$arg" >&2; exit 1 ;;
  esac
done

# --- The plan: ONE ordered list, transcribed from .github/workflows/ci.yml's `kit` job in step
# order — gates and suites interleaved exactly as CI declares them, not gates-then-suites, so the
# cheap structural gates ahead of tests/lib/test.sh (etc.) really do run before it, and a failure
# is reported in the same order a GitHub Actions job would report it. A gate's displayed name is
# its command's OWN first line — never retyped separately — so the label shown by --list and the
# command actually executed can never drift from each other.
ITEM_KINDS=()
ITEM_NAMES=()
ITEM_CMDS=()
add_gate() {
  local cmd="$1" name
  name=$(printf '%s\n' "$cmd" | head -n 1)
  ITEM_KINDS+=("gate")
  ITEM_NAMES+=("$name")
  ITEM_CMDS+=("$cmd")
}

add_suite() {
  local path="$1"
  ITEM_KINDS+=("suite")
  ITEM_NAMES+=("$path")
  ITEM_CMDS+=("./$path")
}

DOTNET_CMD="dotnet test samples/LegacyShop --nologo"

# 1–4: the cheap structural gates, ahead of every suite that sources tests/_lib.sh.
add_gate "./scripts/worktrees-ignored.sh"
add_gate "python3 scripts/ci-wiring-check.py"
add_gate "./scripts/parse-sweep.sh"
add_gate "python3 scripts/pinned-literals-check.py"
# The same family, one layer up: those three gate TEXT, this one gates CONTROL FLOW — every
# registered decision is single-homed, invoked by its owner, and unrestated by prose (#208). Cheap
# and structural like its neighbours; its own golden suite runs below with the others.
add_gate "python3 scripts/decision-check.py"
# One more of the same family, on the kit's user-facing ending: every skill closes with the shared
# recap, and the hand-off table agrees with ARCHITECTURE.md's dashed edges (#175).
add_gate "python3 scripts/recap-wiring-check.py"
# One more of the same family (#391): no positive-match `grep -q` is fed by an external streaming
# producer under `pipefail` -- the shape that reported a failure that did not happen on ~22% of
# tests/survey/test.sh runs.
add_gate "python3 scripts/sigpipe-idiom-check.py"

add_suite "tests/lib/test.sh"
add_suite "tests/sigpipe-idiom/test.sh"
add_suite "tests/py-module/test.sh"
add_suite "tests/ci-wiring/test.sh"
add_suite "tests/parse-sweep/test.sh"
add_suite "tests/line-endings/test.sh"
add_suite "tests/pinned-literals/test.sh"
add_suite "tests/recap-wiring/test.sh"

# 5: the frozen fixture — must stay green AND legacy. Skipped by --quick.
[ "$QUICK" -eq 1 ] || add_gate "$DOTNET_CMD"

add_suite "tests/xunit-v3/test.sh"

# 6: JSON manifests are valid JSON — every plugin manifest host-adapters.py's VERSIONED and
# UNVERSIONED_JSON tuples name, plus the four release/requirements files that aren't either (#556).
add_gate "$(cat <<'EOF'
. tests/_lib/py.sh
py_module scripts/host-adapters.py <<'PY'
import json, sys
# A malformed renovate.json does not fail anything visibly: Renovate simply stops
# proposing updates for the repo, and the only symptom is an absence of PRs.
for rel in (*mod.VERSIONED, *mod.UNVERSIONED_JSON,
            'requirements.json', 'release-please-config.json',
            '.release-please-manifest.json', 'renovate.json'):
    try:
        json.load(open(rel, encoding='utf-8'))
    except Exception as e:
        sys.exit(f'{rel}: {e}')
    print(f'ok  {rel}')
PY
EOF
)"

# 7: renovate.json is a config Renovate actually accepts — needs network (npx). Opt-in only.
if [ "$WITH_NETWORK" -eq 1 ]; then
  add_gate "$(cat <<'EOF'
export RENOVATE_VALIDATOR_VERSION=44.29.4
validator_output=$(mktemp)
set +e
npx --yes --package "renovate@$RENOVATE_VALIDATOR_VERSION" -- \
  renovate-config-validator --no-global --strict renovate.json 2>&1 | tee "$validator_output"
validator_status=${PIPESTATUS[0]}
set -e
if grep -q 'RE2 not usable' "$validator_output"; then
  if [ "$validator_status" -eq 0 ]; then
    echo "::error::renovate-config-validator's RE2 engine did not load, so this run validated renovate.json on JS RegExp instead of RE2 — the validator's own success is only trustworthy on RE2, and a matchStrings pattern only RE2 would reject could have passed here silently. See #130."
  else
    echo "::error::renovate-config-validator's RE2 engine did not load, on top of it already rejecting renovate.json for a reason of its own (see the output above) — fix that failure first; regex validation cannot be trusted on JS RegExp alone until RE2 loads. See #130."
  fi
  exit 1
fi
exit "$validator_status"
EOF
)"
fi

# The suite behind that gate shells out to `npx renovate-config-validator` itself, and asserts that
# its RE2 engine loaded — so it is exactly as network-bound as the gate above and follows the same
# switch. Registered unconditionally, it turned every offline `--quick` run red on a host without
# RE2: a missing prerequisite reading as a failed suite, the very shape this script exists to end.
if [ "$WITH_NETWORK" -eq 1 ]; then
  add_suite "tests/renovate-config/test.sh"
fi

# 7b: the parse sweep under a REAL bash 3.2 (#144) — a Docker Hub pull, so it rides the same
# switch as the other network-bound gates. The command is spelled exactly as ci.yml's step, which
# is what tests/run-all-tests/test.sh's drift case compares.
if [ "$WITH_NETWORK" -eq 1 ]; then
  add_gate 'docker run --rm -v "$PWD:/repo" -w /repo bash:3.2 bash scripts/parse-sweep.sh'
fi

# 8: plugin.json's version must match the release-please manifest.
add_gate "$(cat <<'EOF'
plugin=$(python3 -c "import json; print(json.load(open('plugins/tagout/.claude-plugin/plugin.json'))['version'])")
manifest=$(python3 -c "import json; print(json.load(open('.release-please-manifest.json'))['.'])")
if [ "$plugin" != "$manifest" ]; then
  echo "plugin.json is $plugin but .release-please-manifest.json is $manifest"; exit 1
fi
EOF
)"

# 9: every migrate-legacy phase guide names its RoselineMCP tools.
add_gate "$(cat <<'EOF'
bad=$(grep -L 'analyze_solution\|list_diagnostics\|apply_fixes\|edit_member\|rename_symbol\|find_references\|get_call_graph\|get_symbol_at_position\|search_symbols' skills/migrate-legacy/references/phase-*.md || true)
if [ -n "$bad" ]; then echo "Phase guides missing tool names: $bad"; exit 1; fi
EOF
)"

# 10–11: preflight.sh exercised as a regular gate (plain and --json), mirroring ci.yml's own two
# steps. This is IN ADDITION to the exit-2 bootstrap below — that bootstrap is new behaviour this
# script adds on top of what CI does; CI never runs preflight before its other steps, because a
# GitHub-hosted runner already carries every declared prerequisite. Running preflight three times
# in a full local pass (bootstrap + these two) is deliberate fidelity to ci.yml, not an oversight.
add_gate "./scripts/preflight.sh"
add_gate "./scripts/preflight.sh --json | python3 -m json.tool > /dev/null"

add_suite "tests/preflight/test.sh"
add_suite "tests/repo-profile/test.sh"
add_suite "tests/repo-setup/test.sh"
# After repo-profile: the tracker dispatcher reads that script's Tracker line to pick a backend.
add_suite "tests/tracker/test.sh"

# 12: kit scripts run correctly from a foreign working directory (plugin-install simulation).
add_gate "$(cat <<'EOF'
KIT="$PWD"
cd "$(mktemp -d)"
bash "$KIT/scripts/preflight.sh" --json | python3 -m json.tool > /dev/null
bash "$KIT/scripts/audit-inventory.sh" "$KIT/samples/LegacyShop" | python3 -m json.tool > /dev/null
python3 "$KIT/scripts/followups.py" "$KIT/tests/followups/fixture-a" --backlog "$KIT/docs/backlog.md" > /dev/null
out=$(bash "$KIT/skills/profile-repo/scripts/repo-profile.sh" show "$KIT")
[ "$out" = "$(cat "$KIT/.claude/skills/repo-profile.md")" ]
rc=0
out=$(bash "$KIT/skills/profile-repo/scripts/repo-profile.sh" show "$PWD") || rc=$?
[ "$rc" = 3 ] && [ "$out" = "NO_PROFILE" ]
for g in guarded-commit guarded-push guarded-merge; do
  script="$KIT/skills/implement-issue/scripts/$g.sh"
  bash "$script" --help | grep -q 'Exit codes:'
  if bash "$script" -C "$PWD" no-such-branch -- -m x 2>/dev/null; then
    echo "$g.sh accepted a path that is not a git repository"; exit 1
  fi
done
EOF
)"

# 13: skill frontmatter conforms to the guide (requirements.json cross-check included).
add_gate "python3 tests/skills/check-frontmatter.py"

# 13b: every skills/_shared/*.md document that declares its own reach is still linked from every
# consumer, and nothing links it without being declared (#266, generalized to every declaring
# document by #269). Same home as the frontmatter checker — both are absence rules over skills/
# whose red paths ride in tests/skills/test.sh below.
add_gate "python3 tests/skills/check-shared-refs.py"

add_suite "tests/skills/test.sh"

# 14: the inventory script runs and emits valid JSON.
add_gate "./scripts/audit-inventory.sh samples/LegacyShop | python3 -m json.tool > /dev/null"

add_suite "tests/audit-inventory/test.sh"

add_suite "tests/dependency-health/test.sh"

# 15: every template under templates/ is valid YAML.
add_gate "python3 -c \"import yaml, glob; [yaml.safe_load(open(f)) for f in glob.glob('templates/**/*.yml', recursive=True)]\""

add_suite "tests/ci-template/test.sh"
add_suite "tests/report-dashboard/test.sh"
add_suite "tests/followups/test.sh"
add_suite "tests/tick-plan/test.sh"
add_suite "tests/guarded-git/test.sh"
add_suite "tests/finish-task/test.sh"
add_suite "tests/gh-host/test.sh"
add_suite "tests/merge-gate/test.sh"
add_suite "tests/merge-base-ci/test.sh"
add_suite "tests/pr-existence-guard/test.sh"
add_suite "tests/plan-locate-comment-guard/test.sh"
add_suite "tests/merge-freshness/test.sh"
add_suite "tests/approve-runs/test.sh"
add_suite "tests/guard-invocation/test.sh"
add_suite "tests/decisions/test.sh"
add_suite "tests/guarded-pr-merge/test.sh"
add_suite "tests/remote-branch-teardown/test.sh"
add_suite "tests/merge-pr-parent/test.sh"
add_suite "tests/release-title-gate/test.sh"
add_suite "tests/worktrees-ignored/test.sh"
add_suite "tests/main-worktree/test.sh"
add_suite "tests/implement-issue-worktree-step/test.sh"
add_suite "tests/plan-freshness/test.sh"
add_suite "tests/roseline/test.sh"
add_suite "tests/git-gate/test.sh"
add_suite "tests/routing-context/test.sh"
add_suite "tests/host-adapters/test.sh"
add_suite "tests/autodev-stop-gate/test.sh"
add_suite "tests/auto-dev-state-path/test.sh"
add_suite "tests/auto-dev-never-wait/test.sh"
add_suite "tests/dispatch-push-and-land/test.sh"
add_suite "tests/review-angle-isolation/test.sh"
add_suite "tests/auto-dev-takeover-cleanup/test.sh"
add_suite "tests/auto-dev-worktree-field/test.sh"
add_suite "tests/auto-dev-blocked-hold/test.sh"
add_suite "tests/auto-dev-cost-budgets/test.sh"
add_suite "tests/auto-dev-dispatch/test.sh"
add_suite "tests/release-branch/test.sh"
add_suite "tests/wait-ci/test.sh"
add_suite "tests/usage-report/test.sh"
add_suite "tests/survey/test.sh"
add_suite "tests/wire-edges/test.sh"
add_suite "tests/hitl-loop/test.sh"
add_suite "tests/review-sessions/test.sh"
add_suite "tests/deliver-issue/test.sh"
add_suite "tests/create-pr/test.sh"
add_suite "tests/session-retro/test.sh"

# The kit's own ADRs are structurally sound. The gate runs the checker over the REAL
# docs/adr/ — the suite below only drives it over fixtures, so without this line a
# malformed committed ADR would never turn anything red (#316).
add_gate "python3 tests/adr/check-adrs.py"

add_suite "tests/adr/test.sh"

add_suite "tests/rejected-adrs/test.sh"

# 16: the contrast checker itself, pass AND fail paths.
add_gate "$(cat <<'EOF'
python3 scripts/contrast-check.py "#000000:#ffffff:sanité"
if python3 scripts/contrast-check.py "#777777:#888888" >/dev/null 2>&1; then
  echo "contrast-check aurait dû échouer sur une paire illisible"; exit 1
fi
EOF
)"

add_suite "tests/decision-tally/test.sh"

add_suite "tests/run-all-tests/test.sh"

# --- One-line notes for anything the flags left out of the plan above, naming the flag that would
# bring it back in. Printed in both --list and normal-run mode, so the plan is never silently
# smaller than the full CI job without saying why.
[ "$QUICK" -eq 1 ] && printf 'note: skipping "%s" — omit --quick to include it\n' "$DOTNET_CMD" >&2
[ "$WITH_NETWORK" -eq 1 ] || printf 'note: skipping the network-dependent renovate.json acceptance gate — pass --with-network to include it\n' >&2

# --- --list: print the plan and exit 0. No prerequisite check — this must stay cheap and always
# available, since tests/run-all-tests/test.sh's anti-drift case calls it on every run.
if [ "$LIST" -eq 1 ]; then
  for i in "${!ITEM_KINDS[@]}"; do
    printf '%s %s\n' "${ITEM_KINDS[$i]}" "${ITEM_NAMES[$i]}"
  done
  exit 0
fi

# --- The prerequisite guard: refuse before any gate or suite runs. A missing prerequisite is not a
# test failure and must never be reported as one (the incident this whole script exists for). A full
# run also asks for the prerequisites scoped `for: run-all-tests` (the .NET 6 runtime samples/
# LegacyShop needs to RUN, not just build, #642); --quick already skips that one gate, so it asks for
# none of them. $preflight_for is deliberately unquoted below — empty expands to no argument at all,
# which is bash-3.2 safe (#131) and avoids passing preflight.sh a stray empty argument.
preflight_for="--for run-all-tests"
[ "$QUICK" -eq 1 ] && preflight_for=""
if ! preflight_out=$("$HERE/preflight.sh" $preflight_for 2>&1); then
  printf 'PREREQUISITE — nothing was judged. %s\n' "$HERE/preflight.sh reported:" >&2
  printf '%s\n' "$preflight_out" >&2
  exit 2
fi

# --- Run every gate, then every suite, in plan order. Fail-fast: the first failure stops the run
# and decides the exit code, the same way a GitHub Actions job stops at its first red step — and,
# for a multi-line gate transcribed from a ci.yml `run: |` block (JSON manifests, the
# foreign-working-directory simulation, the contrast-checker pass/fail pair), "first failure"
# means the first LINE, not just the first gate. GitHub Actions runs `run:` steps under
# `bash --noprofile --norc -eo pipefail {0}` — errexit and pipefail both on — so a plain
# `bash -c "$cmd"` here would silently run every remaining line after an early one fails and then
# report the LAST line's exit status as the gate's own, which is not "what CI checks" but a
# strictly weaker stand-in for it.
run_item() {
  local name="$1" cmd="$2" out rc
  out=$(bash -eo pipefail -c "$cmd" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'ok   %s\n' "$name"
    return 0
  fi
  printf 'FAIL %s\n' "$name"
  printf '%s\n' "$out" | tail -n 25
  return 1
}

gate_count=0
suite_count=0
for i in "${!ITEM_KINDS[@]}"; do
  if [ "${ITEM_KINDS[$i]}" = gate ]; then gate_count=$((gate_count + 1)); else suite_count=$((suite_count + 1)); fi
  run_item "${ITEM_NAMES[$i]}" "${ITEM_CMDS[$i]}" || exit 1
done

printf 'ok  %d gates, %d suites\n' "$gate_count" "$suite_count"
exit 0
