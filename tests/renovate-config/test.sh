#!/usr/bin/env bash
# renovate.json is judged by the engine that consumes it.
#
# CI proved this file PARSES (#34 added it to the json.tool step). Parsing is not acceptance:
# `customManagers` must compile under RE2, `managerFilePatterns` regexes are validated, and any
# unknown key raises CONFIG_VALIDATION. When Renovate rejects a config it stops managing the WHOLE
# repository, and the only symptom is an absence — no PRs, no Dependency Dashboard updates, nothing
# in a log anyone reads. That is the failure shape #34 was filed for; this closes the half it left.
#
# What is asserted:
#   1. the pinned validator accepts the real renovate.json;
#   2. it REJECTS a config carrying an unknown key — without this, a validator that always exited 0
#      would score as a pass;
#   3. ci.yml pins the validator to an exact version, and that pin is >= the measured floor;
#   4. the pin is managed — a customManager exists that Renovate can bump it through;
#   5. ci.yml invokes the validator with BOTH --no-global and --strict (see below);
#   6. it REJECTS a repo config carrying a global-only option (what --no-global buys);
#   7. it REJECTS a config that still needs migration (what --strict buys);
#   8. the validator's RE2 engine actually loaded — see below, and #130;
#   9. ci.yml's OWN step still fails the build when RE2 fails to load — see below.
#
# Why the two flags, measured against renovate@44.23.3 in #79 rather than read off the docs:
#   --no-global — passing a filename positionally makes the validator judge it as a GLOBAL
#     self-hosted config ("Validating renovate.json as global config"). This file is a REPO config.
#     `autodiscover` and `baseDir`, which Renovate ignores outright in a repo config, PASS without
#     the flag and fail with it — the silent-ignore failure this gate exists to catch, found inside
#     the gate itself.
#   --strict — NOT what catches an unknown key: a mistyped key inside customManagers already exits 1
#     unflagged, because renovate 44 sets returnVal=1 on warnings too. `strict` is consulted in one
#     branch only, `if (isMigrated)`, so it means "fail if the config needs migration" — the only
#     thing that catches a stale `fileMatch` spelling. Measured 0 without, 1 with.
#   Cases 6 and 7 are golden tests for exactly those two claims, so a future edit that drops a flag
#   fails here instead of quietly widening the hole again. Case 5 catches the drop in ci.yml itself.
#
# Case 8, and #130: RE2 is an OPTIONAL native module. When it fails to load, the validator falls
# back to JS RegExp and logs "RE2 not usable, falling back to RegExp: regex validation may be
# inaccurate" as a bare WARN that does NOT affect the exit code — measured: exit 0 either way, by
# forcing `require('re2')` to throw (a NODE_OPTIONS require-shim; renaming the installed module's
# native binary reproduces the identical warning and exit code, but the shim needs no write access
# to whatever tree npx happened to install into). A matchStrings pattern only RE2 would reject can
# then pass silently, forever. Case 8 fails the SUITE on that warning; case 8-control proves the
# assertion actually fires by reproducing the degraded engine on purpose — a guard never seen
# failing is not known to work. Cases 8/8-control prove the mechanism against this suite's OWN
# `run_validator` calls, though — neither one ever reads ci.yml. Case 9 is what closes that gap:
# the same "a flag silently dropped from ci.yml would leave 6/7 green" hazard case 5 exists for
# applies here too, so ci.yml's actual script is parsed to confirm the `grep -q 'RE2 not usable'`
# gate is still there and still exits 1 — not just that this suite could detect the warning itself.
#
# Why the pin is load-bearing, measured in #66:
#   `npx --yes --package renovate -- …` with NO version resolved 37.440.7, a major predating
#   `managerFilePatterns` (the successor to `fileMatch`). It reported 8 Configuration Errors against
#   a config the real Renovate accepts. An unpinned gate is therefore not merely fragile — it is red
#   on correct input, and its obvious "fix" (renaming back to fileMatch) silently downgrades the
#   config for the Renovate that actually runs. Floor measured at major 40; 39 and below reject.
#
# Network: this suite shells out to npx. When the registry is unreachable it SKIPS with a clear
# message rather than passing — a validator that could not run has not validated anything.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
CI="$KIT/.github/workflows/ci.yml"
FLOOR=40

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
# This suite only reads ci.yml and renovate.json and shells out to npx, so it registers no extra
# guard. Saying so beats leaving it unsaid: before #72 this was the one suite silently missing the
# samples/ check, and "decided it does not apply" looked exactly like "forgot".
scratch=$(kit_scratch)

# ---------------------------------------------------------------------------
# 3. ci.yml pins an exact version, at or above the measured floor.
#    Asserted BEFORE the network work, so a missing pin fails fast and offline.
# ---------------------------------------------------------------------------
PIN=$(python3 - "$CI" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
# The apostrophe is spelled \x27 rather than \' on purpose: bash 3.2 (macOS's /bin/bash) scans a
# $( … ) command substitution WITHOUT honouring heredoc quoting, so a lone apostrophe in this body
# opens a shell string that never closes and the whole file fails to parse (#131). \x27 is the same
# character to the regex engine and invisible to bash's scanner. scripts/parse-sweep.sh guards it.
m = re.search(r'RENOVATE_VALIDATOR_VERSION:\s*["\x27]?([0-9]+(?:\.[0-9]+)*)["\x27]?', text)
print(m.group(1) if m else "")
PY
)
if [ -z "$PIN" ]; then
  echo "FAIL: ci.yml does not pin RENOVATE_VALIDATOR_VERSION to an exact version."
  echo "      An unpinned 'npx --package renovate' resolved 37.440.7 when this was measured,"
  echo "      and reported 8 Configuration Errors against a config Renovate accepts."
  exit 1
fi
MAJOR=${PIN%%.*}
if [ "$MAJOR" -lt "$FLOOR" ]; then
  echo "FAIL: the pinned validator is major $MAJOR, below the measured floor of $FLOOR."
  echo "      Majors under $FLOOR reject 'managerFilePatterns' and would redden a correct config."
  exit 1
fi
echo "  [3] ci.yml pins the validator to $PIN (>= floor $FLOOR)"

# ---------------------------------------------------------------------------
# 4. The pin is MANAGED. A version pinned and then forgotten is #35 all over again —
#    the shipped workflows that sat three majors stale while the repo's own CI stayed
#    current. Renovate must be able to bump this one.
# ---------------------------------------------------------------------------
python3 - "$KIT/renovate.json" "$CI" <<'PY'
import json, re, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
managers = cfg.get("customManagers") or []
ci_rel = ".github/workflows/ci.yml"
owning = []
for m in managers:
    pats = m.get("managerFilePatterns") or m.get("fileMatch") or []
    if not any(re.search(p.strip("/"), ci_rel) for p in pats):
        continue
    blob = json.dumps(m)
    if "renovate" in blob and "npm" in blob:
        owning.append(m)
assert owning, (
    "no customManager claims the validator pin in ci.yml — nothing would ever bump it, "
    "which is exactly the stale-shipped-config failure of #35"
)
# The manager must actually capture the pin we wrote, not merely mention the file.
#
# Renovate evaluates matchStrings with RE2, where a named group is `(?<name>…)`; Python spells the
# same thing `(?P<name>…)`. Same translation as tests/xunit-v3/test.sh's `to_python()` — a third
# copy of that helper, which is one more tenant for the shared tests/_lib.sh proposed in #72.
# No lookbehind assertion here: the pinned validator above now judges RE2 compatibility for real,
# which is strictly better than a second hand-written model of somebody else's grammar.
def to_python(pattern):
    return pattern.replace("(?<", "(?P<")


text = open(sys.argv[2], encoding="utf-8").read()
hit = False
for m in owning:
    for s in m.get("matchStrings", []):
        if re.search(to_python(s), text, re.M | re.S):
            hit = True
assert hit, "the customManager's matchStrings do not match the pin as written in ci.yml"
PY
echo "  [4] the pin is claimed by a customManager whose matchStrings actually match it"

# ---------------------------------------------------------------------------
# 5. ci.yml passes BOTH flags. Cases 6/7 below prove what each one buys, but they prove it about
#    the validator, not about the command CI actually runs — a flag silently dropped from ci.yml
#    would leave 6/7 green while the real gate went back to accepting the bad configs. Asserted
#    offline, before the network work, for the same reason as [3].
# ---------------------------------------------------------------------------
# awk, not a python heredoc: the two `$(python3 - … <<PY … PY)` blocks above are the one construct
# bash 3.2 (still /bin/bash on macOS) mis-parses, so this deliberately does not add a third.
# It joins backslash continuations into logical lines first — the flags may sit on either side of
# the break — then picks the line that invokes the validator.
#
# Comment lines are dropped before the match, and that is not fussiness: the step in ci.yml is
# wrapped in prose explaining why each flag is load-bearing, and prose in this repo names the tool
# it is about. Without the filter the first `#` line mentioning renovate-config-validator wins the
# `head -1`, and this assertion starts grading a comment instead of the command — passing while the
# real invocation has lost a flag, which is precisely the failure it exists to prevent.
validator_invocation=$(awk '
  { line = buf $0
    if (line ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", line); buf = line; next }
    buf = ""; print line }
' "$CI" | grep -v '^[[:space:]]*#' | grep -F 'renovate-config-validator' | head -1)
if [ -z "$validator_invocation" ]; then
  echo "FAIL: ci.yml no longer invokes renovate-config-validator at all."
  exit 1
fi
for flag in --no-global --strict; do
  # -F and the -- guard: the needle itself starts with dashes.
  if ! printf '%s' "$validator_invocation" | grep -qF -- "$flag"; then
    echo "FAIL: ci.yml invokes the validator without $flag:"
    echo "        $validator_invocation"
    if [ "$flag" = "--no-global" ]; then
      echo "      Without --no-global the file is judged as a GLOBAL self-hosted config, and"
      echo "      global-only options (autodiscover, baseDir) pass despite being ignored in a"
      echo "      repo config — the silent-ignore failure this gate exists to catch."
    else
      echo "      Without --strict a config that still needs migration (e.g. fileMatch for"
      echo "      managerFilePatterns) is silently accepted and exits 0."
    fi
    exit 1
  fi
done
echo "  [5] ci.yml invokes the validator with --no-global and --strict"

# ---------------------------------------------------------------------------
# 1+2. The pinned validator accepts the real config and rejects a bogus one.
# ---------------------------------------------------------------------------
# Mirrors ci.yml exactly — flags included. A suite that validated with a different command than the
# gate runs would be testing something nobody ships; [5] above keeps the two spellings in step.
run_validator() {
  npx --yes --package "renovate@$PIN" -- \
    renovate-config-validator --no-global --strict "$1" > "$2" 2>&1
}

if ! run_validator "$KIT/renovate.json" "$scratch/real.txt"; then
  if grep -qiE 'ENOTFOUND|ETIMEDOUT|EAI_AGAIN|network|registry\.npmjs\.org.*failed' "$scratch/real.txt"; then
    echo "  [1-2] SKIPPED — npm registry unreachable; the validator could not run."
    echo "        (A validator that could not run has not validated anything.)"
    exit 0
  fi
  echo "FAIL: the pinned validator ($PIN) rejects the repo's own renovate.json:"
  cat "$scratch/real.txt"
  exit 1
fi
echo "  [1] renovate@$PIN accepts renovate.json"

python3 - "$KIT/renovate.json" "$scratch/bogus.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
cfg["totallyBogusKeyThatRenovateMustReject"] = 1
json.dump(cfg, open(sys.argv[2], "w", encoding="utf-8"))
PY
if run_validator "$scratch/bogus.json" "$scratch/bogus.txt"; then
  echo "FAIL: the validator ACCEPTED a config with an unknown key — it would pass anything,"
  echo "      and this gate would be decoration:"
  cat "$scratch/bogus.txt"
  exit 1
fi
echo "  [2] it rejects a config carrying an unknown key"

# ---------------------------------------------------------------------------
# 6. What --no-global buys: a repo config carrying a GLOBAL-only option must be rejected.
#    Measured in #79 — without the flag this exact file exits 0, because the validator judges it
#    against the global schema where these options are legal. Renovate ignores them in a repo
#    config, so the config is quietly not what it says it is: absence-of-PRs, no error anywhere.
# ---------------------------------------------------------------------------
python3 - "$KIT/renovate.json" "$scratch/global-only.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
# Both are self-hosted/global options, meaningless inside a repository's renovate.json.
cfg["autodiscover"] = True
cfg["baseDir"] = "/tmp/renovate"  # tmp-lint:allow — a config VALUE under test, not a path this suite writes
json.dump(cfg, open(sys.argv[2], "w", encoding="utf-8"))
PY
if run_validator "$scratch/global-only.json" "$scratch/global-only.txt"; then
  echo "FAIL: the validator ACCEPTED a repo config carrying global-only options."
  echo "      That means --no-global is not in effect and the file is being judged as a GLOBAL"
  echo "      self-hosted config — options Renovate ignores in a repo config score as valid:"
  cat "$scratch/global-only.txt"
  exit 1
fi
# Non-zero alone is not proof: npx exits non-zero when the registry is unreachable too, and that
# would let an outage score as a passing rejection — "a validator that could not run has not
# validated anything" applies to the negative cases as much as the positive one. Assert the REASON.
if ! grep -q 'is a global option reserved' "$scratch/global-only.txt"; then
  echo "FAIL: the validator rejected the global-only config, but not for being global-only."
  echo "      Expected the \"is a global option reserved\" diagnostic; got:"
  cat "$scratch/global-only.txt"
  exit 1
fi
echo "  [6] it rejects a repo config carrying global-only options (--no-global is in effect)"

# ---------------------------------------------------------------------------
# 7. What --strict buys: a config that still needs migration must be rejected.
#    `fileMatch` is the pre-managerFilePatterns spelling. Renovate migrates it silently and exits 0
#    unflagged; --strict turns that into a failure. This is the "rename landing on the wrong side of
#    a Renovate major" bullet from #79, and the only case that distinguishes the flag.
# ---------------------------------------------------------------------------
python3 - "$KIT/renovate.json" "$scratch/needs-migration.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
managers = cfg.get("customManagers") or []
# Pick the first manager that actually carries the modern spelling, rather than assuming [0] does —
# a bare managers[0].pop() would raise KeyError and surface as an opaque crash instead of this
# message the day someone reorders the list or hand-writes one with `fileMatch` already.
target = next((m for m in managers if "managerFilePatterns" in m), None)
assert target is not None, (
    "no customManager in renovate.json uses 'managerFilePatterns', so there is nothing to downgrade "
    "to the superseded 'fileMatch' spelling — rewrite this case against whatever migration is current"
)
# Downgrade that one manager; everything else stays valid, so the ONLY reason to fail is migration.
target["fileMatch"] = target.pop("managerFilePatterns")
json.dump(cfg, open(sys.argv[2], "w", encoding="utf-8"))
PY
if run_validator "$scratch/needs-migration.json" "$scratch/needs-migration.txt"; then
  echo "FAIL: the validator ACCEPTED a config still using the superseded 'fileMatch' spelling."
  echo "      --strict is what makes a needed migration fatal; without it the config is silently"
  echo "      migrated in-memory and scores as valid:"
  cat "$scratch/needs-migration.txt"
  exit 1
fi
# Same reasoning as [6]: prove it failed for the migration, not because npx could not reach npm.
if ! grep -q 'Config migration necessary' "$scratch/needs-migration.txt"; then
  echo "FAIL: the validator rejected the unmigrated config, but not for needing migration."
  echo "      Expected the \"Config migration necessary\" diagnostic; got:"
  cat "$scratch/needs-migration.txt"
  exit 1
fi
echo "  [7] it rejects a config that still needs migration (--strict is in effect)"

# ---------------------------------------------------------------------------
# 8. The validator's OWN report on its regex engine must be trusted, not assumed. RE2 is an
#    OPTIONAL native module (see the file header, and #130): when it fails to load, the validator
#    keeps validating on JS RegExp and keeps exiting 0 — the marker lives ONLY in a WARN line that
#    nothing here has checked until now. [1]'s run already captured that combined output; reuse it
#    rather than shelling out again.
# ---------------------------------------------------------------------------
if grep -q 'RE2 not usable' "$scratch/real.txt"; then
  echo "FAIL: the pinned validator's RE2 engine did not load on this host — regex validation ran"
  echo "      on JS RegExp instead, which accepts matchStrings patterns RE2 would reject:"
  cat "$scratch/real.txt"
  exit 1
fi
echo "  [8] the validator reports a usable RE2 engine"

# 8-control. A guard never seen failing is not known to work — the same rule cases 6 and 7 apply to
# their own diagnostics. Force the degraded engine ON PURPOSE and prove [8]'s check would have
# caught it, by requiring the SAME marker to appear once the engine is actually unavailable.
#
# The shim intercepts module resolution rather than touching whatever tree npx installed into: the
# latter needs write access to a path this suite does not own and does not choose (a fresh CI cache
# may not even hold a copy yet), where the shim works identically everywhere and needs nothing on
# disk beyond kit_scratch.
force_re2_off="$scratch/force-re2-unavailable.js"
cat > "$force_re2_off" <<'JS'
const Module = require("module");
const orig = Module._resolveFilename;
Module._resolveFilename = function (request) {
  if (request === "re2") {
    const err = new Error("Cannot find module 're2' (forced by tests/renovate-config/test.sh)");
    err.code = "MODULE_NOT_FOUND";
    throw err;
  }
  return orig.apply(this, arguments);
};
JS
NODE_OPTIONS="${NODE_OPTIONS:-} --require $force_re2_off" run_validator "$KIT/renovate.json" "$scratch/re2-forced-off.txt" || true
if ! grep -q 'RE2 not usable' "$scratch/re2-forced-off.txt"; then
  echo "FAIL: forcing require('re2') to fail did not reproduce the 'RE2 not usable' warning, so"
  echo "      case [8] has never been proven to catch a real degraded engine:"
  cat "$scratch/re2-forced-off.txt"
  exit 1
fi
echo "  [8-control] forcing the engine off DOES print the marker — case [8] would have failed"

# ---------------------------------------------------------------------------
# 9. ci.yml's OWN gate must still be wired, not merely provably correct in the abstract. Cases 8
#    and 8-control show that the "RE2 not usable" marker is real and that a run_validator call
#    written right here would catch it — but neither one ever reads ci.yml, so a future edit that
#    drops or breaks the `grep -q 'RE2 not usable' … exit 1` block in the real CI step would leave
#    every case above green while the gate silently reverted to #130. Same hazard case 5 closes
#    for --no-global/--strict, applied to the check that sits alongside them.
# ---------------------------------------------------------------------------
re2_gate_line=$(grep -n "RE2 not usable" "$CI" | grep -v '^[0-9]*:[[:space:]]*#' | grep -F 'grep -q' | head -1)
if [ -z "$re2_gate_line" ]; then
  echo "FAIL: ci.yml no longer greps its validator output for 'RE2 not usable' anywhere — the"
  echo "      degraded-engine gate from #130 has been silently dropped from the real CI step,"
  echo "      even though this suite's own cases 8 and 8-control still pass."
  exit 1
fi
re2_gate_lineno=${re2_gate_line%%:*}
# Depth-matched to the block's own `if`/`fi`, not a fixed line count: the branch below it prints
# two DIFFERENT messages (one per validator_status), so "exit 1" can sit an arbitrary number of
# lines — and nested if/fi pairs — below the line found above. Anchoring on whole-line `if`/`fi`
# keywords (leading whitespace only) rather than a substring match is deliberate: this file's own
# prose uses "fix", "first" and "config" throughout, all of which CONTAIN "fi" as a substring, and
# a bare `grep -c fi` would count those as closes and stop scanning early — silently underscoring
# the exact kind of check this suite exists to distrust.
re2_gate_has_exit=$(awk -v start="$re2_gate_lineno" '
  NR < start { next }
  {
    if ($0 ~ /^[[:space:]]*if[[:space:]]/) depth++
    if ($0 ~ /exit 1/) found = 1
    if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) {
      depth--
      if (depth == 0) { print (found ? "yes" : "no"); exit }
    }
  }
' "$CI")
if [ "$re2_gate_has_exit" != "yes" ]; then
  echo "FAIL: ci.yml checks for 'RE2 not usable' but its if-block does not exit 1 — the"
  echo "      degraded-engine gate from #130 no longer fails the build even when it fires."
  exit 1
fi
echo "  [9] ci.yml's own step still fails the build when RE2 fails to load, not just this suite"

# ---------------------------------------------------------------------------
# 10. The RESOLVED config — the document Renovate actually obeys (#156).
#
#     Cases 1-9 hand the validator this repo's renovate.json straight off disk, and section 9 of
#     tests/xunit-v3/test.sh models Renovate's reach questions in Python. NEITHER resolves
#     `extends`, so everything the shared preset contributes is invisible to both — hole 4 of #99,
#     recorded there and never fixed. The consequence is not hypothetical in shape: the preset is
#     maintained in a DIFFERENT repository, so an edit that switches off this repo's pin-watching is
#     an edit no CI run here would ever see.
#
#     So ask the engine instead of modelling it. `renovate --dry-run=extract --print-config`
#     resolves the whole preset chain and reports both halves of what this case needs: the config it
#     actually obeys, and the files each manager extracted from. The two reach questions — "is the
#     transform watched?" and "is its path ignored?" — are then answered by Renovate rather than by
#     a second hand-written model of somebody else's grammar.
#
#     Measured against renovate@44.75.1 rather than read off the docs:
#       * `--platform=local` CANNOT answer this. `local>` presets resolve through the platform API,
#         and this chain NESTS one (renovate-ci -> local>renovate-base), so the local platform fails
#         with "Preset caused unexpected error" no matter what token is supplied. Hence --platform=github.
#       * The EXIT CODE IS WORTHLESS. A config-validation failure exits 0, and so does an unhandled
#         rejection. Every verdict below is read out of the log RECORDS; `$?` is never consulted.
#         This is the same lesson as case 8 — a failure that lives only in a log line nobody greps.
#       * Renovate's own `engines` require node ^24.11.0. Below it the process dies with
#         "RegExp.escape is not a function" — and exits 0. Hence the node floor and its SKIP.
#       * LOG_FORMAT=json makes every record one line, so the resolved config is parsed as JSON
#         rather than scraped out of a pretty-printed dump.
#
#     THE HONEST LIMIT, stated because the next reader will need it: this reads the config on the
#     DEFAULT BRANCH as GitHub serves it, not the working tree. A branch's own renovate.json is not
#     what Renovate obeys until it lands — and the document hole 4 is about is precisely the one
#     Renovate obeys, so that is the right target here. It also means a renovate.json fix on a
#     branch turns this case green only once it merges.
#
#     Network: like cases 1-2 this needs the network, and SKIPs loudly when it is unavailable. A
#     preset that cannot be RESOLVED is a different thing and FAILS — it means the config this repo
#     declares cannot be assembled at all.
# ---------------------------------------------------------------------------
TRANSFORM_REL="tests/xunit-v3/apply-transform.py"
REPO_SLUG="phmatray/tagout"
NODE_FLOOR_MAJOR=24
NODE_FLOOR_MINOR=11

resolved_skip=""
if ! command -v node > /dev/null 2>&1; then
  resolved_skip="node is not on PATH, so renovate proper cannot run"
else
  # `node -p` rather than `node --version`, to avoid parsing the leading "v".
  node_ver=$(node -p 'process.versions.node' 2>/dev/null || true)
  node_major=${node_ver%%.*}
  node_rest=${node_ver#*.}
  node_minor=${node_rest%%.*}
  # `:*` and `*:` are the EMPTY-field arms, and they are the ones that matter: when `node -p` fails
  # or prints nothing, both fields are empty and the subject is a bare ":", which matches neither
  # '' nor either `*[!0-9]*` arm — every one of those needs a character to land on. Without them the
  # subject fell through to the numeric arm, where `[ "" -lt 24 ]` prints "integer expression
  # expected" and returns 2, so the `if` read FALSE and the SKIP this block exists to set was never
  # set: renovate then ran anyway, on the broken node the guard had just failed to notice.
  case "$node_major:$node_minor" in
    ''|:*|*:|*[!0-9]*:*|*:*[!0-9]*)
      resolved_skip="could not read node's version (got '$node_ver')" ;;
    *)
      if [ "$node_major" -lt "$NODE_FLOOR_MAJOR" ] ||
         { [ "$node_major" -eq "$NODE_FLOOR_MAJOR" ] && [ "$node_minor" -lt "$NODE_FLOOR_MINOR" ]; }; then
        resolved_skip="node $node_ver is below renovate@$PIN's engines floor of ${NODE_FLOOR_MAJOR}.${NODE_FLOOR_MINOR} (below it renovate dies with 'RegExp.escape is not a function' and exits 0)"
      fi ;;
  esac
fi

# Resolving a `local>` preset reads another repository through the platform API, which is
# rate-limited to almost nothing unauthenticated — measured: "Rate limit exceeded for
# api.github.com". Any of the three usual sources will do; none is created here.
resolved_token="${RENOVATE_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -z "$resolved_token" ] && command -v gh > /dev/null 2>&1; then
  resolved_token=$(gh auth token 2>/dev/null || true)
fi
if [ -z "$resolved_skip" ] && [ -z "$resolved_token" ]; then
  resolved_skip="no GitHub token in RENOVATE_TOKEN, GITHUB_TOKEN or 'gh auth token' — the preset chain cannot be fetched"
fi

if [ -n "$resolved_skip" ]; then
  echo "  [10] SKIPPED — $resolved_skip."
  echo "        (Nothing was asserted about the RESOLVED config. A skip is not a pass.)"
else
  resolved_log="$scratch/resolved.ndjson"
  # --autodiscover=false with an explicit slug: this must read ONE repository, never wander.
  # --base-dir keeps renovate's clone inside kit_scratch, which kit_cleanup removes.
  # The token goes in the environment, not on the command line, so it stays out of any process list.
  RENOVATE_TOKEN="$resolved_token" \
  GITHUB_COM_TOKEN="$resolved_token" \
  LOG_FORMAT=json \
  LOG_LEVEL=info \
    npx --yes --package "renovate@$PIN" -- renovate \
      --platform=github --dry-run=extract --print-config --autodiscover=false \
      --base-dir "$scratch/renovate-base" "$REPO_SLUG" > "$resolved_log" 2>&1 || true

  # Exit code deliberately discarded above (`|| true`) — see the header. The python below decides,
  # and it distinguishes three outcomes: 0 pass, 3 skip (could not reach), 1 fail.
  set +e
  python3 - "$resolved_log" "$TRANSFORM_REL" "$REPO_SLUG" <<'PY'
import json, sys

log_path, transform, slug = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(log_path, encoding="utf-8", errors="replace").read()

records = []
for line in raw.splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        records.append(json.loads(line))
    except ValueError:
        continue


def messages():
    for r in records:
        m = r.get("msg")
        if isinstance(m, str):
            yield r, m


# --- could not reach: SKIP, never a pass. Checked FIRST, because an unreachable API also
# --- produces a preset error, and reporting that as a failure would make an outage look like a
# --- broken config (the same trap cases 6 and 7 avoid by asserting the REASON).
for needle in ("Rate limit exceeded", "ENOTFOUND", "ETIMEDOUT", "EAI_AGAIN",
               "getaddrinfo", "ECONNREFUSED", "ECONNRESET"):
    if needle in raw:
        print("  [10] SKIPPED — renovate could not reach the GitHub API (%s)." % needle)
        print("        (Nothing was asserted about the RESOLVED config. A skip is not a pass.)")
        sys.exit(3)

# --- a preset that cannot be RESOLVED is a failure, not a skip: the config this repo declares
# --- cannot be assembled at all, which is exactly the state nothing here could previously see.
for marker in ("Preset caused unexpected error", "Cannot find preset"):
    if marker in raw:
        detail = next((m for _, m in messages() if marker in m), marker)
        print("FAIL: the preset chain this repo declares could not be resolved: %s" % detail)
        print("      renovate.json extends a preset in ANOTHER repository; if it was deleted or")
        print("      renamed, this repo's whole config stops assembling and Renovate manages nothing.")
        sys.exit(1)

resolved, extracted = None, None
for r, m in messages():
    if m.startswith("Full resolved config"):
        resolved = r.get("config")
    elif m == "Extracted dependencies":
        extracted = r.get("packageFiles")

# Never print the resolved config wholesale: `hostRules` travels in it. Renovate redacts tokens,
# but a CI log is the wrong place to bet on that. Only the specific keys under test are echoed.
if resolved is None:
    print("FAIL: renovate printed no resolved-config record for %s." % slug)
    print("      --print-config was passed, so its absence means the run never got that far —")
    print("      and renovate exits 0 regardless, which is why this is asserted on the record.")
    sys.exit(1)

if extracted is None:
    print("FAIL: renovate printed no extraction record for %s, so nothing can be said about" % slug)
    print("      which files its managers actually read.")
    sys.exit(1)

# --- reach question 1: is the transform WATCHED? Asked of the engine's own extraction result,
# --- which is the whole point: this is what Renovate read, not what a model predicts it would.
watched = []
for manager, files in (extracted or {}).items():
    for entry in files or []:
        if entry.get("packageFile") == transform:
            deps = [d.get("depName") for d in (entry.get("deps") or [])]
            watched.append((manager, deps))

if not watched:
    print("FAIL: under the RESOLVED config, Renovate extracts NOTHING from %s." % transform)
    print("      The two pins that file carries (#36) are therefore unwatched: no update is ever")
    print("      proposed for them, and the packageRules that hold their majors cannot fire on")
    print("      dependencies that were never extracted. Nothing in this repo could see this")
    print("      before, because every other check reads the UNRESOLVED renovate.json.")
    print("      Resolved ignorePaths: %s" % json.dumps(resolved.get("ignorePaths")))
    print("      Resolved enabledManagers: %s" % json.dumps(resolved.get("enabledManagers")))
    print("      Files the managers DID read: %s"
          % json.dumps(sorted(e.get("packageFile")
                              for fs in (extracted or {}).values() for e in fs or [])))
    sys.exit(1)

# --- reach question 2: does anything in the resolved config DISABLE the manager that reads it?
# --- `enabledManagers`, when set, is an allow-list: a preset setting it without the custom regex
# --- manager would disable these pins repo-wide while every other assertion here still passed.
enabled = resolved.get("enabledManagers") or []
if enabled and not any(m in ("custom.regex", "regex") for m in enabled):
    print("FAIL: the RESOLVED enabledManagers allow-list omits the custom regex manager: %s"
          % json.dumps(enabled))
    print("      It is an ALLOW-LIST, so omission disables the managers that watch %s." % transform)
    sys.exit(1)

print("  [10] the RESOLVED config watches %s — %s"
      % (transform,
         "; ".join("%s: %s" % (mgr, ", ".join(d for d in deps if d)) for mgr, deps in watched)))
PY
  resolved_rc=$?
  set -e
  # 3 is the suite's SKIP path and must not fail the run; anything else non-zero is a real refusal.
  if [ "$resolved_rc" -ne 0 ] && [ "$resolved_rc" -ne 3 ]; then
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 11. The generated plugin copies are reachable by the same managers and rules as their sources
#     (#710). ADR 0017 makes plugins/*/templates/** and plugins/tagout-migrate/tests/xunit-v3/
#     apply-transform.py byte copies of a source. When Renovate bumps only the source, `kit` refuses
#     the drift and no bot can run `host-adapters build` (#665). The fix is that Renovate edits source
#     and copies in one branch, so each copy path must match the same actions-manager pattern, both
#     regex managers, and the `fix` semanticCommitType rule. Static, offline: section 10 reads the
#     DEFAULT branch, so it cannot confirm a branch's own config until it merges.
# ---------------------------------------------------------------------------
python3 - "$KIT/renovate.json" <<'PY'
import fnmatch, json, re, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
import glob
# Every copied workflow, walked rather than listed: a new template must be reachable too.
tmpl = sorted(glob.glob("plugins/*/templates/**/*.y*ml", recursive=True))
assert tmpl, "no generated template copies found under plugins/*/templates"
xf = "plugins/tagout-migrate/tests/xunit-v3/apply-transform.py"
rx = lambda pats, f: any(re.search(p.strip("/"), f) for p in pats)
bad = []
gha = cfg.get("github-actions", {}).get("managerFilePatterns", [])
for f in tmpl:
    if not rx(gha, f): bad.append("github-actions.managerFilePatterns misses " + f)
py = [m for m in cfg["customManagers"] if "apply-transform" in json.dumps(m.get("managerFilePatterns"))]
if len(py) != 2: bad.append("expected 2 apply-transform.py regex managers, found %d" % len(py))
for m in py:
    if not rx(m["managerFilePatterns"], xf): bad.append("a regex manager misses " + xf)
fix = [r for r in cfg["packageRules"] if r.get("semanticCommitType") == "fix"]
globs = [g for r in fix for g in r.get("matchFileNames", [])]
for f in tmpl + [xf]:
    if not any(fnmatch.fnmatch(f, g) for g in globs): bad.append("fix rule matchFileNames misses " + f)
if bad:
    print("FAIL: generated copies are not reachable by Renovate (#710):")
    for b in bad: print("      " + b)
    sys.exit(1)
PY
echo "  [11] the generated plugin copies are reachable by the actions manager, both regex managers and the fix rule"

echo "renovate-config golden test OK"
