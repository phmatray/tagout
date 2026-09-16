#!/usr/bin/env bash
# preflight.sh — verifies the required/recommended tooling before any migration (phase 0).
# The prerequisite list lives in requirements.json at the kit root (single source):
# this script reads and evaluates it, it embeds no hard-coded list.
# Usage: preflight.sh [--json] [--for <name>]
# Output: a status table, or structured JSON with --json (to store in migration/report.json).
# --for <name> also checks the entries scoped to that ONE caller (the manifest's `for` field, #642)
# — omitted, every `for`-scoped entry is skipped, which is every consumer's phase 0 and CI.
# Exit code 1 if a REQUIRED item is missing, 0 otherwise.
# Session capabilities (the manifest's sessionSkills) cannot be checked from bash:
# the agent confirms them itself against its skill list (SKILL.md, phase 0, step 2).
set -uo pipefail

JSON=0
FOR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --for)
      shift
      if [ $# -eq 0 ]; then
        echo "usage: preflight.sh [--json] [--for <name>]" >&2
        exit 2
      fi
      FOR="$1"
      shift
      ;;
    *) shift ;;
  esac
done

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REQ="$KIT_DIR/requirements.json"

# Bootstrap: python3 reads the manifest — without it, nothing else is checkable.
if ! command -v python3 >/dev/null 2>&1; then
  echo "MISSING ✗  python3 — required to read requirements.json (and by the kit's scripts)" >&2
  exit 1
fi
[ -f "$REQ" ] || { echo "ERR: manifest not found — $REQ" >&2; exit 2; }

FAIL=0
RESULTS=()
TAB=$'\t'

# status, name, requiredBy ("-" if none), hint — tab-separated (manifest values carry no tabs).
record() { RESULTS+=("$1$TAB$2$TAB$3$TAB$4"); }

# SDK: numeric comparison of the major (>= 8) — no version enumeration that rots with every .NET release.
sdk_ok() {
  command -v dotnet >/dev/null 2>&1 &&
  dotnet --list-sdks 2>/dev/null | awk -F. '($1+0)>=8{f=1} END{exit f?0:1}'
}
# Runtime: numeric comparison of the major only (no patch enumeration to rot) — `dotnet --list-sdks`
# proves a version can be BUILT, not that it can be RUN; `dotnet test` launches the test host on the
# target's runtime, so a fixture pinned to an old TargetFramework (samples/LegacyShop, net6.0) needs
# this probe, not sdk_ok (#642).
runtime_ok() {
  local major="$1"
  command -v dotnet >/dev/null 2>&1 &&
  dotnet --list-runtimes 2>/dev/null | awk -v m="$major" '$1=="Microsoft.NETCore.App" && ($2+0)==m {f=1} END{exit f?0:1}'
}
# jq: numeric comparison of major.minor (>= 1.6, the floor tick-plan.sh's --rawfile round-trip
# check needs, #199) — same "no version enumeration that rots" shape as sdk_ok.
jq_ok() {
  command -v jq >/dev/null 2>&1 &&
  jq --version 2>/dev/null | awk -F'[-.]' '
    { major = $2 + 0; minor = $3 + 0 }
    major > 1 || (major == 1 && minor >= 6) { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

# A configured-but-dead MCP server does not count: its status line must not report a failure.
# `claude mcp list` output is captured into a variable first — a herestring has nothing to close
# early, so there is nothing left for a live producer to SIGPIPE under `pipefail` (#391). The
# `[ -n "$matched" ] &&` guard is load-bearing, not decoration: a herestring of an EMPTY variable
# still feeds one blank line (herestrings always append a newline), and that blank line satisfies
# `grep -v` (it contains none of fail/error/✗) — so without the guard, "$1" absent from the list
# entirely would read back as healthy instead of as the "server not found" it is.
mcp_ok() {
  local out matched
  out=$(claude mcp list 2>/dev/null)
  matched=$(grep -i "$1" <<<"$out")
  [ -n "$matched" ] && grep -qivE 'fail|error|✗' <<<"$matched"
}

# The highest installed SDK major, or empty when dotnet is absent or unreadable. Computed ONCE:
# the requiresSdk check below runs per mcps entry and `dotnet --list-sdks` is a process spawn.
SDK_MAJOR=$(command -v dotnet >/dev/null 2>&1 && dotnet --list-sdks 2>/dev/null | awk -F. '($1+0)>m{m=$1+0} END{if(m>0) print m}')

# An mcps entry may declare `requiresSdk`: the SDK major ITS OWN launcher needs, which can sit above
# the pipeline's floor — roseline is started with `dnx` (.NET 10) while the pipeline accepts >= 8, so
# a .NET 8/9 host used to pass phase 0 with a server that could never start (#112).
# Answers "can this host run it at all", so every uncertain case answers no: an absent field is not
# "floor 0", an unparseable floor is not a verdict, and an unreadable SDK is already reported by the
# tools row above. Saying nothing leaves the entry's behaviour exactly as it was before the field.
sdk_below_floor() {
  local floor="$1"
  [ "$floor" != "-" ] || return 1
  case "$floor" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$SDK_MAJOR" ] || return 1
  [ "$SDK_MAJOR" -lt "$floor" ]
}

# Where the floor is unmet, this is WHY — prefixed to the entry's own hint, so every status line
# that names the server also names the version it wanted. Empty otherwise.
# It changes the MESSAGE, never the VERDICT of an observed absence: a `level: required` server the
# claude CLI can see is not running still hard-fails phase 0. Softening that would swap one silent
# failure for another — green on a host that cannot run it, for a pipeline started without the
# engine every phase of it depends on.
floor_note() {
  sdk_below_floor "$1" || return 0
  printf 'needs a .NET SDK >= %s to start, this host has %s — ' "$1" "$SDK_MAJOR"
}

# An mcps entry may also declare `launcher`: the executable that starts it, spelled as .mcp.json
# invokes it. The floor is a PROXY for this — an SDK at or above roseline's 10 is the only way `dnx`
# gets installed — and a proxy only holds in one direction. The converse does not: a host can carry
# the .NET 10 SDK and still not have `dnx` on the PATH that matters, at which point the floor says
# nothing and the server is just as unstartable (#155). So the launcher is probed directly.
#
# Same uncertainty rule as sdk_below_floor: an absent field ("-") or an empty one is not a launcher
# named "", it is no declaration at all, and it leaves the entry's behaviour exactly as it was.
launcher_missing() {
  local launcher="$1"
  [ "$launcher" != "-" ] || return 1
  [ -n "$launcher" ] || return 1
  ! command -v "$launcher" >/dev/null 2>&1
}

# Where the launcher is missing, this is the VERDICT — the shipped launcher cannot have started the
# server — and it goes FIRST, before floor_note's remedy. "dnx not on PATH" is what is wrong;
# "needs a .NET SDK >= 10, this host has 9" is what to do about it. On a host that clears the floor
# only the first half prints, which is precisely the gap this closes: nothing else would have spoken.
launcher_note() {
  launcher_missing "$1" || return 0
  printf '%s not on PATH — ' "$1"
}

# requirements.json → one tab-separated line per entry: kind, level, name, test/match, requiredBy,
# requiresSdk, launcher, hint, for, tracker. "-" placeholder where a field is empty: an empty field
# would be swallowed by read (tab = IFS whitespace) and shift every field after it left — hint
# gained a `for` neighbour, so it now takes the same "-" placeholder as every other optional field
# rather than "", the empty string that was harmless only while hint was itself second-to-last. Every
# kind prints the SAME number of columns, including the ones that can never carry the field, so the
# `read` below binds the same name to the same position on every line. `for` (#642) names the one
# caller this entry is scoped to (e.g. "run-all-tests") — sits right before tracker, which stays
# LAST because `read` gives the trailing field the remainder.
manifest() {
python3 - "$REQ" <<'PY'
import json, sys
req = json.load(open(sys.argv[1]))
def reqby(e): return ", ".join(e.get("requiredBy", [])) or "-"
for t in req.get("tools", []):
    print("\t".join(["tool", t["level"], t["name"], t["test"], reqby(t), "-", "-",
                     t.get("hint") or "-", t.get("for") or "-", t.get("tracker") or "-"]))
for m in req.get("mcps", []):
    print("\t".join(["mcp", m["level"], m["name"], m["match"], reqby(m),
                     str(m.get("requiresSdk") or "-"), str(m.get("launcher") or "-"),
                     m.get("hint") or "-", m.get("for") or "-", m.get("tracker") or "-"]))
for s in req.get("sessionSkills", []):
    print("\t".join(["skill", s["level"], "skill " + s["name"], "-", reqby(s), "-", "-",
                     s.get("when") or "-", s.get("for") or "-", s.get("tracker") or "-"]))
PY
}

CLAUDE_CLI=1
command -v claude >/dev/null 2>&1 || CLAUDE_CLI=0

# The profile's own Tracker line, first word only ("github", "gitlab", …) — resolved ONCE, here,
# never per-entry. Empty on ANY non-zero exit (no committed profile, no Tracker line, bad dir):
# "no verdict" and "the profile disagrees" must not read alike, so an entry naming a `tracker` is
# skipped only on a POSITIVE mismatch, never on the absence of one.
PROFILE_TRACKER=""
_pt_out="$("$KIT_DIR/skills/profile-repo/scripts/repo-profile.sh" tracker 2>/dev/null)" \
  && PROFILE_TRACKER="${_pt_out%% *}"

while IFS=$'\t' read -r kind level name test reqby floor launcher hint entry_for tracker; do
  # Skip an entry scoped to a caller (#642) unless THIS call names that same caller with --for —
  # never on "no verdict" either side: an entry with no `for` at all is unaffected, checked on
  # every call exactly as before.
  if [ "$entry_for" != "-" ] && [ "$entry_for" != "$FOR" ]; then
    continue
  fi
  # Skip an entry whose declared tracker isn't the profile's — never on "no verdict" either side.
  if [ "$tracker" != "-" ] && [ -n "$PROFILE_TRACKER" ] && [ "$tracker" != "$PROFILE_TRACKER" ]; then
    continue
  fi
  case "$kind" in
    tool)
      if eval "$test" >/dev/null 2>&1; then record ok "$name" "$reqby" ""
      elif [ "$level" = required ]; then record missing "$name" "$reqby" "$hint"; FAIL=1
      else record absent "$name" "$reqby" "$hint"; fi
      ;;
    mcp)
      # A live server is checked FIRST, so an observed connection always beats both probes: they are
      # proxies for "the shipped launcher cannot start it", and a server the user brought up by some
      # other route is running whatever this host's SDK and PATH say.
      note="$(launcher_note "$launcher")$(floor_note "$floor")"
      if [ "$CLAUDE_CLI" -eq 1 ] && mcp_ok "$test"; then record ok "$name" "$reqby" ""
      elif [ "$CLAUDE_CLI" -eq 0 ]; then
        # Nothing can be observed here — but "unknown, confirm in session" is the wrong answer to a
        # question this host has already settled: with the launcher off PATH, or below the floor it
        # needs, the server cannot start, whoever confirms it. That is the silent pass #112 filed
        # and #155 widened, so name it instead.
        if [ -n "$note" ]; then record absent "$name" "$reqby" "$note$hint"
        else record unknown "$name" "$reqby" "claude CLI absent (normal in CI) — confirm in session"; fi
      elif [ "$level" = required ]; then record missing "$name" "$reqby" "$note$hint"; FAIL=1
      else record absent "$name" "$reqby" "$note$hint"; fi
      ;;
    skill)
      record unknown "$name" "$reqby" "session capability — the agent confirms it itself ($hint)"
      ;;
  esac
done < <(manifest)

if [ "$JSON" -eq 1 ]; then
  # JSON is emitted by python3 (real escaping) — never hand-assembled with printf.
  # Results travel as argv (the heredoc already owns stdin for the program itself).
  python3 - "$FAIL" "${RESULTS[@]}" <<'PY'
import json, sys
fail = sys.argv[1] != "0"
checks = []
for line in sys.argv[2:]:
    st, name, reqby, hint = (line.split("\t", 3) + ["", "", ""])[:4]
    check = {"status": st, "name": name, "hint": hint}
    if reqby != "-":
        check["requiredBy"] = [s.strip() for s in reqby.split(",")]
    checks.append(check)
print(json.dumps({"ok": not fail, "checks": checks}, ensure_ascii=False))
PY
  exit "$FAIL"
fi

echo "== tagout preflight (manifest: requirements.json) =="
for r in "${RESULTS[@]}"; do
  IFS=$'\t' read -r st name reqby hint <<<"$r"
  case "$st" in
    ok)      label="OK" ;;
    missing) label="MISSING ✗" ;;
    absent)  label="absent" ;;
    unknown) label="unknown" ;;
  esac
  extra=""
  [ "$reqby" != "-" ] && [ "$st" != ok ] && extra=" [hard-required by: $reqby]"
  printf '%-11s %-28s %s%s\n' "$label" "$name" "$hint" "$extra"
done
echo
if [ "$FAIL" -eq 1 ]; then
  echo "PREFLIGHT FAILED — fix the REQUIRED items before phase 1."
  exit 1
fi
echo "Preflight OK — 'absent/unknown' items degrade the pipeline in a documented way, never silently."
