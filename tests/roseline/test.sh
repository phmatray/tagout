#!/usr/bin/env bash
# Golden test for the roseline integration — the shipped MCP server config and the PreToolUse gate.
#
# Written fail-path-first (like tests/worktrees-ignored/test.sh): a gate whose PASS path is the
# only one exercised proves nothing. Every case drives the real script over a synthetic hook
# payload, because that payload is the gate's entire input contract.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
WORK=$(kit_scratch)

# The gate's one-shot escape keys off marker files under $TMPDIR. Point TMPDIR at the scratch so
# every run starts with none: with the real TMPDIR they survive between runs, and the *second* run
# of this suite would find Foo.cs already marked and watch "first read is denied" pass instead —
# a suite that goes green off a stale file from the run before. Scratch is wiped by kit_cleanup.
export TMPDIR="$WORK"

# The gate probes for `dnx` before it denies anything (#112): that is the launcher .mcp.json starts
# roseline with, it ships only in the .NET 10 SDK, and without it the server cannot be running — so
# enforcing a tool the session cannot call would be worse than letting the Read through. Every DENY
# case below therefore needs one on PATH. Stubbed rather than assumed, because otherwise this
# suite's expectations would silently depend on whether the machine running it has .NET 10.
STUB="$WORK/stub-bin"
mkdir -p "$STUB"
printf '#!/bin/sh\nexit 0\n' > "$STUB/dnx"
chmod +x "$STUB/dnx"
export PATH="$STUB:$PATH"

# ------------------------------------------------------------------ 1. the shipped server config
MCP="$KIT/.mcp.json"
[ -f "$MCP" ] || { echo "FAIL: $MCP missing"; exit 1; }
jq -e . "$MCP" >/dev/null 2>&1 || { echo "FAIL: .mcp.json is not valid JSON"; exit 1; }

got=$(jq -r '.mcpServers.roseline | "\(.type)|\(.command)|\(.args | join(","))"' "$MCP")
want='stdio|dnx|RoselineMCP,--yes'
[ "$got" = "$want" ] || { echo "FAIL: .mcp.json roseline entry is '$got', want '$want'"; exit 1; }
echo "ok: .mcp.json ships roseline as $want"

# ------------------------------------------------------------------------------- 2. the gate
GATE="$KIT/hooks/roseline-gate.sh"
[ -x "$GATE" ] || { echo "FAIL: $GATE missing or not executable"; exit 1; }

# find -print -quit is load-bearing in the gate's project detection; #48 is why this is asserted.
kit_require_find_quit

# Scratch repos. mktemp -d, NOT a counter: `n=$((n+1))` inside a $(...) helper increments a
# subshell's copy and the caller's stays 0, so every "fresh" repo would be the same directory —
# the trap tests/_lib.sh:65-70 documents, and one this suite tripped over before review caught it.
csharp_repo() { local d; d=$(mktemp -d "$WORK/cs.XXXXXX"); : > "$d/App.csproj"; printf '%s' "$d"; }
plain_repo()  { local d; d=$(mktemp -d "$WORK/plain.XXXXXX"); : > "$d/README.md"; printf '%s' "$d"; }
# root/src/Company.Product/Api/Api.csproj — a mainstream layout that sits at depth 4, so a
# downward `find -maxdepth 3` from the repo root never sees it and the gate goes silently off.
nested_repo() {
  local d; d=$(mktemp -d "$WORK/nest.XXXXXX")
  mkdir -p "$d/src/Company.Product/Api"
  : > "$d/src/Company.Product/Api/Api.csproj"
  printf '%s' "$d"
}

# A PATH holding exactly what the gate shells out to, plus whichever stubs are named. Built by
# NAMING the tools rather than by subtracting `dnx` from $PATH, because dnx can live anywhere and a
# .NET 10 dev box has a real one — the "absent" case has to hold on that box too.
# Every extra argument becomes an empty executable, so a case can add `dnx` back without adding a
# real .NET SDK.
shim_path() { # $1 destination dir; $2… stub names
  local d="$1" c p; shift
  mkdir -p "$d"
  for c in bash cat jq dirname basename find touch rm tr cut md5 md5sum; do
    p=$(command -v "$c" 2>/dev/null) || continue
    ln -s "$p" "$d/$c" 2>/dev/null || true
  done
  for c in "$@"; do printf '#!/bin/sh\nexit 0\n' > "$d/$c"; chmod +x "$d/$c"; done
  printf '%s' "$d"
}

# Drives the gate with a synthetic payload. Asserts the exit status, the decision, and — when
# denying — the reason.
# $1 name  $2 expected decision ("deny" or "pass")  $3 substring the reason must contain  $4 payload
# $5 optional PATH the gate runs under (default: this suite's, which carries the dnx stub above).
# $6 optional gate script (default: the shipped one) — the mutation guard in §3d drives a scratch
#    copy of the gate through exactly this driver, so the two cases cannot diverge.
# `env` rather than a `PATH=… bash …` prefix so the lookup of `bash` itself is unambiguously done
# against the PATH the case is testing, not the one it is replacing.
verdict() {
  local name="$1" want="$2" want_msg="$3" payload="$4" gate_path="${5:-$PATH}" gate="${6:-$GATE}" \
        out decision rc=0
  out=$(printf '%s' "$payload" | env PATH="$gate_path" bash "$gate" 2>/dev/null) || rc=$?
  # Exit status is half the PreToolUse contract — exit 2 blocks the tool regardless of stdout. If
  # we only scored stdout, a regression that turned a fail-open path into `exit 2` would be
  # reported here as "pass" while blocking every Read in production.
  [ "$rc" -eq 0 ] || { echo "FAIL [$name]: gate exited $rc; its contract is always exit 0"; exit 1; }
  if [ -z "$out" ]; then decision="pass"; else
    decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null || echo malformed)
  fi
  if [ "$decision" != "$want" ]; then
    echo "FAIL [$name]: expected $want, got $decision"; echo "$out"; exit 1
  fi
  if [ -n "$want_msg" ]; then
    # Herestring, not a pipe into `grep -q` (#391): `jq` can still be writing when the match
    # closes the read end.
    reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
    grep -qF "$want_msg" <<<"$reason" || { echo "FAIL [$name]: reason lacks '$want_msg'"; echo "$out"; exit 1; }
  fi
  echo "ok: $name -> $decision"
}

pay() { # $1 tool  $2 file_path  $3 cwd  $4 session
  jq -nc --arg t "$1" --arg f "$2" --arg c "$3" --arg s "$4" \
    '{session_id:$s, cwd:$c, tool_name:$t, tool_input:{file_path:$f}}'
}

# The marker path the gate will use, so the staleness case can age it.
marker_for() { # $1 file_path  $2 session
  local k
  k=$(printf '%s' "$1" | md5 -q 2>/dev/null || printf '%s' "$1" | md5sum 2>/dev/null | cut -d' ' -f1)
  [ -n "$k" ] || k=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | tail -c 120)
  printf '%s/roseline-gate-kit-%s-%s' "$TMPDIR" "$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_')" "$k"
}

CS=$(csharp_repo); PL=$(plain_repo); NEST=$(nested_repo)
[ "$CS" != "$PL" ] || { echo "FAIL: fixture helpers returned the same directory"; exit 1; }

verdict "first .cs read in a C# repo"  deny "search_symbols" "$(pay Read "$CS/Foo.cs"    "$CS" s1)"
verdict "csproj is not C# source"      pass ""               "$(pay Read "$CS/A.csproj"  "$CS" s1)"
verdict "razor markup"                 pass ""               "$(pay Read "$CS/X.razor"   "$CS" s1)"
verdict "markdown"                     pass ""               "$(pay Read "$CS/README.md" "$CS" s1)"
verdict "no C# project discoverable"   pass ""               "$(pay Read "$PL/Foo.cs"    "$PL" s1)"
verdict "a tool other than Read"       pass ""               "$(pay Grep "$CS/Foo.cs"    "$CS" s1)"
verdict "NotebookRead is not Read"     pass ""               "$(pay NotebookRead "$CS/Foo.cs" "$CS" s1)"
verdict "malformed payload fails open" pass ""               'not json at all'

# The detection must walk UP from the file, not down from cwd: this project file is at depth 4.
verdict "nested project at depth 4 is gated" deny "search_symbols" \
  "$(pay Read "$NEST/src/Company.Product/Api/Foo.cs" "$NEST" s1)"

# ------------------------------------------------------- 3. the one-shot "I really need it" escape
ESC=$(csharp_repo)
P=$(pay Read "$ESC/Bar.cs" "$ESC" escape-session)
verdict "first read is denied"          deny "search_symbols" "$P"
verdict "identical retry passes"        pass ""               "$P"
verdict "third read denies again"       deny "search_symbols" "$P"

# The escape is per-file, not per-session: a different file is still denied after one was let through.
Q=$(pay Read "$ESC/Baz.cs" "$ESC" escape-session)
verdict "a different file is denied"    deny "search_symbols" "$Q"

# ...and per-session, not global: the same file under another session id is denied on ITS first read.
S=$(pay Read "$ESC/Bar.cs" "$ESC" other-session)
verdict "another session is denied"     deny "search_symbols" "$S"

# A marker only ever gets cleared by the retry that consumes it, so the common path — model
# complies, uses roseline, never retries — leaves one behind. It must NOT still open the gate
# later: session ids survive --continue/--resume, so "one-shot" would silently become "latched".
TTL=$(csharp_repo)
TP=$(pay Read "$TTL/Old.cs" "$TTL" ttl-session)
verdict "first read arms the marker"    deny "search_symbols" "$TP"
mk=$(marker_for "$TTL/Old.cs" ttl-session)
[ -f "$mk" ] || { echo "FAIL: expected a marker at $mk"; exit 1; }
touch -t 202001010000 "$mk"
verdict "a stale marker does not open the gate" deny "search_symbols" "$TP"

# ------------------------------------------- 3d. a SECOND hook on the same Read cannot eat the token
# The escape's marker path used to carry no namespace of its own, so it was byte-identical to the
# one `~/.claude/hooks/roseline-gate` builds — the hand-rolled predecessor this gate is a hardened
# rewrite of, still registered on `Read` on any host that ever had it. Both hooks then shared one
# token: one armed it, the other found it and removed it inside the same tool call, the deny won,
# and the retry the deny message instructs found nothing and was denied again. Measured across
# 2,078 sessions: 264 instructed retries, 264 denied (#666). ADR-0002 says this gate never has a
# fail-closed path; this was one.
#
# The sibling is written out as the HISTORICAL consumer, not as a copy of the shipped gate: a copy
# would track the fix and the case would stop meaning anything.
sibling_consume() { # $1 file_path  $2 session — what the predecessor hook does to "its" marker
  local k s
  k=$(printf '%s' "$1" | md5 -q 2>/dev/null || printf '%s' "$1" | md5sum 2>/dev/null | cut -d' ' -f1)
  [ -n "$k" ] || k=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | tail -c 120)
  s=$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_')
  rm -f "$TMPDIR/roseline-gate-$s-$k"
}

COL=$(csharp_repo)
CP=$(pay Read "$COL/Coll.cs" "$COL" collide-session)
verdict "a sibling hook is installed: the first read still denies" deny "search_symbols" "$CP"
sibling_consume "$COL/Coll.cs" collide-session
verdict "…and the instructed retry is STILL allowed through"       pass ""              "$CP"

# The mutation guard: strip the namespace back out of a scratch copy and the two verdicts above
# must stop holding. Without it, a "simplification" that removed `-kit-` would leave this section
# green, because the sibling would once again be removing the marker the gate had just armed.
OLDGATE="$WORK/gate-unnamespaced.sh"
sed 's|roseline-gate-kit-|roseline-gate-|' "$GATE" > "$OLDGATE"
grep -qF 'roseline-gate-kit-' "$OLDGATE" \
  && { echo "FAIL: the mutation did not strip the namespace from the scratch copy"; exit 1; }
MUT=$(csharp_repo)
MP=$(pay Read "$MUT/Mut.cs" "$MUT" mutant-session)
verdict "an un-namespaced gate denies first, as always" deny "search_symbols" "$MP" "$PATH" "$OLDGATE"
sibling_consume "$MUT/Mut.cs" mutant-session
verdict "…and its retry is denied — the collision, reproduced" deny "search_symbols" "$MP" "$PATH" "$OLDGATE"

# ------------------------------------------------------- 3b. the capability probe (fail open, #112)
# preflight green + `dnx` absent + the gate denying anyway is the composed failure this closes: the
# reader is told to use `mcp__roseline__*` by a hook whose own precondition nobody checked. `dnx`
# ships only with the .NET 10 SDK, so its absence proves the shipped launcher cannot have started
# the server — and a gate that cannot confirm the tool it redirects to must let the Read through.
NODNX=$(shim_path "$WORK/nodnx")
WITHDNX=$(shim_path "$WORK/withdnx" dnx)
PROBE=$(csharp_repo)
NP=$(pay Read "$PROBE/Probe.cs" "$PROBE" probe-session)

verdict "no dnx on PATH fails open" pass "" "$NP" "$NODNX"

# The control, and the reason the case above is a measurement rather than a coincidence: the same
# stripped PATH with one empty `dnx` added must still DENY. Without it a "pass" would be equally
# well explained by the shim missing `jq` or `find` — the gate's other fail-open paths — and the
# suite would stay green while the probe was never written at all.
verdict "the same PATH with dnx still denies" deny "search_symbols" "$NP" "$WITHDNX"

# ...and the probe runs BEFORE the marker is armed, so a fail-open Read never consumes the one-shot
# escape it was not going to use. The deny above is therefore this file's FIRST armed read, and the
# retry that follows it is the escape — proving no marker was left behind by the pass.
verdict "the fail-open read armed nothing"  pass ""               "$NP" "$WITHDNX"
verdict "so the next read denies again"     deny "search_symbols" "$NP" "$WITHDNX"

# The documented off-switch has to actually exist.
out=$(printf '%s' "$(pay Read "$CS/Kill.cs" "$CS" ks)" | ROSELINE_GATE=off bash "$GATE" 2>/dev/null || true)
[ -z "$out" ] || { echo "FAIL: ROSELINE_GATE=off did not disable the gate"; exit 1; }
echo "ok: ROSELINE_GATE=off disables the gate"

# ------------------------------------------------- 3c. ROSELINE_GATE=on — the user's own testimony
# The probe above is a proxy, and the case it cannot see is the one that matters most to the people
# who invested most: roseline reached by any route other than the shipped `dnx` launcher — a
# hand-added MCP server, a locally built binary, a wrapper — leaves the gate permanently fail-open
# for them (#155). Preflight settles that class by OBSERVING (a live `mcp_ok` beats every floor); a
# PreToolUse hook is handed only the tool payload and has no such channel, so where it cannot
# observe, the user has to be able to declare. `on` is that declaration.
#
# Driven on the SAME dnx-less shim PATH that fails open two cases above, so the deny here can only
# have come from the override.
ONREPO=$(csharp_repo)
ONP=$(pay Read "$ONREPO/Forced.cs" "$ONREPO" force-session)

out=$(printf '%s' "$ONP" | env PATH="$NODNX" ROSELINE_GATE=on bash "$GATE" 2>/dev/null || true)
# Herestrings, not pipes into `grep -q` (#391): `jq` can still be writing when the match closes
# the read end, and under pipefail that SIGPIPE becomes this check's verdict.
decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)
grep -qx deny <<<"$decision" \
  || { echo "FAIL: ROSELINE_GATE=on did not enforce past the failed probe"; echo "$out"; exit 1; }
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
grep -qF search_symbols <<<"$reason" \
  || { echo "FAIL: the forced deny does not name the roseline tool that replaces the Read"; exit 1; }
echo "ok: ROSELINE_GATE=on enforces where the probe cannot see the server"

# `off` stays the MASTER switch — it is checked first, so a host with `dnx` present (where the probe
# alone would deny) still passes. A user who disabled the gate is never overridden.
OFFP=$(pay Read "$ONREPO/Spared.cs" "$ONREPO" off-session)
out=$(printf '%s' "$OFFP" | env PATH="$WITHDNX" ROSELINE_GATE=off bash "$GATE" 2>/dev/null || true)
[ -z "$out" ] || { echo "FAIL: ROSELINE_GATE=off did not win over a passing probe"; echo "$out"; exit 1; }
echo "ok: ROSELINE_GATE=off outranks a probe that would have denied"

# ROSELINE_GATE holds one value, so `off` and `on` cannot literally both be set; what the spec calls
# "off wins" is the ORDER of the two branches inside the gate. Asserted at the source, because it is
# the only place the invariant exists: with `on` first, a stale `on` in someone's shell rc would
# quietly override the `off` they just typed.
off_line=$(grep -n 'off|0|false|no|disabled' "$GATE" | head -1 | cut -d: -f1)
on_line=$(grep -n 'on|1|true|yes|enabled' "$GATE" | head -1 | cut -d: -f1)
[ -n "$off_line" ] && [ -n "$on_line" ] \
  || { echo "FAIL: the gate does not carry both switch branches (off=$off_line on=$on_line)"; exit 1; }
[ "$off_line" -lt "$on_line" ] \
  || { echo "FAIL: the 'on' branch (line $on_line) precedes 'off' (line $off_line); off must stay the master switch"; exit 1; }
echo "ok: the off branch is checked before the on branch"

# An unrecognised value is neither switch: it falls through to the probe, exactly as an unset
# variable does. Without this, `ROSELINE_GATE=maybe` could match a sloppy `on*` pattern and enforce.
MAYBE=$(pay Read "$ONREPO/Maybe.cs" "$ONREPO" maybe-session)
out=$(printf '%s' "$MAYBE" | env PATH="$NODNX" ROSELINE_GATE=maybe bash "$GATE" 2>/dev/null || true)
[ -z "$out" ] || { echo "FAIL: an unrecognised ROSELINE_GATE value must fall through to the probe"; echo "$out"; exit 1; }
echo "ok: an unrecognised ROSELINE_GATE value falls through to the probe"

# --------------------------------------------------------------------- 4. the hook registration
HJ="$KIT/hooks/claude-hooks.json"
[ -f "$HJ" ] || { echo "FAIL: $HJ missing"; exit 1; }
jq -e . "$HJ" >/dev/null 2>&1 || { echo "FAIL: hooks.json is not valid JSON"; exit 1; }

got=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Read") | .hooks[0].command' "$HJ")
case "$got" in
  *'${CLAUDE_PLUGIN_ROOT}'*roseline-gate.sh) echo "ok: hooks.json wires Read -> $got" ;;
  *) echo "FAIL: Read matcher command is '$got'; must reference \${CLAUDE_PLUGIN_ROOT}/hooks/roseline-gate.sh"; exit 1 ;;
esac

# The path in hooks.json must name a file that actually ships — a typo here is a hook that never
# fires, and a hook that never fires looks exactly like a hook that found nothing to block.
resolved="${got/\$\{CLAUDE_PLUGIN_ROOT\}/$KIT}"
[ -x "$resolved" ] || { echo "FAIL: hooks.json points at '$resolved', which is not an executable file"; exit 1; }
echo "ok: the registered command resolves to a shipped executable"

# ------------------------------------------------- 5. requirements.json stays the source of truth
REQ="$KIT/requirements.json"
hint=$(jq -r '.mcps[] | select(.match=="roseline") | .hint' "$REQ")
printf '%s' "$hint" | grep -qF 'shipped by the tagout-migrate plugin' \
  || { echo "FAIL: roseline hint still tells the user to install it by hand: '$hint'"; exit 1; }
echo "ok: requirements.json records that roseline ships with the plugin"

# jq is a hard dependency of the gate: without it the hook exits at line 1 and enforcement is
# silently off while preflight still reports roseline connected. It has to be declared.
jq -e '.tools[] | select(.name | test("jq"))' "$REQ" >/dev/null \
  || { echo "FAIL: requirements.json does not declare jq, which hooks/roseline-gate.sh requires"; exit 1; }
echo "ok: requirements.json declares jq"

# The manifest declares WHAT starts the server (`launcher`), and preflight probes exactly that. The
# gate reaches the same conclusion by hand, with the name hardcoded, because a PreToolUse hook on
# the hot path of every C# Read cannot afford a file read plus a `jq` to look it up — requirements
# .json says so in its own description. The duplication is necessary; unpinned, it is #155: two
# components answering one question from two facts, free to disagree with nothing red anywhere.
# So it is pinned here, the shape scripts/ci-wiring-check.py and tests/skills/check-frontmatter.py
# already use for the duplications they cannot remove either.
launcher=$(python3 - "$REQ" <<'PY'
import json, sys
req = json.load(open(sys.argv[1]))
print(next((m.get("launcher", "") for m in req["mcps"] if m["match"] == "roseline"), ""))
PY
)
[ -n "$launcher" ] || {
  echo "FAIL: requirements.json declares no launcher for the roseline mcps entry — preflight has nothing to probe"
  exit 1; }

# `command -v` on a name containing a slash tests that literal path instead of searching PATH, so a
# manifest value with one in it would quietly stop being the same question the gate asks.
case "$launcher" in
  */*) echo "FAIL: launcher '$launcher' is a path, not a bare command name"; exit 1 ;;
esac

# Comment lines are stripped before matching: a gate that merely MENTIONS the probe in prose while
# testing something else would satisfy a plain grep, which is precisely the drift being guarded.
gate_probes() { # $1 gate file  $2 launcher name
  # Herestring, not a pipe into `grep -q` (#391): `grep -v` is itself a producer that can still be
  # writing when the second grep's match closes the read end.
  local uncommented
  uncommented=$(grep -v '^[[:space:]]*#' "$1")
  grep -qF "command -v $2" <<<"$uncommented"
}
gate_probes "$GATE" "$launcher" || {
  echo "FAIL: hooks/roseline-gate.sh does not probe 'command -v $launcher', the launcher requirements.json declares"
  exit 1; }

# ...and the pin measures something. A scratch gate that probes a different name must fail the same
# check, or a green above would be saying nothing at all about the real pair. Written into the
# suite's scratch, so kit_cleanup discards it however this run ends.
DRIFT="$WORK/drifted-gate.sh"
sed "s/command -v $launcher/command -v kit-drifted-launcher/" "$GATE" > "$DRIFT"
grep -qF 'command -v kit-drifted-launcher' "$DRIFT" \
  || { echo "FAIL: the drift fixture did not actually change the probe"; exit 1; }
if gate_probes "$DRIFT" "$launcher"; then
  echo "FAIL: the launcher pin passes a gate that probes something else — it measures nothing"; exit 1
fi
echo "ok: the gate's hardcoded probe is pinned to requirements.json's launcher ($launcher)"

grep -qF 'roseline-gate' "$KIT/README.md" \
  || { echo "FAIL: README does not document the roseline gate"; exit 1; }
# The full essay (env switches, permissions caveat) moved to docs/roseline-gate.md (#325); README
# keeps only the four-bullet summary and a link, so these two facts are checked at their new home.
grep -qF 'managed-settings.json' "$KIT/docs/roseline-gate.md" \
  || { echo "FAIL: docs/roseline-gate.md does not say where permission rules must live instead"; exit 1; }
grep -qF 'ROSELINE_GATE=off' "$KIT/docs/roseline-gate.md" \
  || { echo "FAIL: docs/roseline-gate.md does not document the real off-switch"; exit 1; }
echo "ok: README documents the gate; docs/roseline-gate.md documents the off-switch and the permission rules"

echo "roseline golden test OK"
