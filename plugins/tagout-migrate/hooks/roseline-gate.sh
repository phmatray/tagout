#!/usr/bin/env bash
# RoselineMCP enforcement gate (Claude Code PreToolUse, matcher: Read).
#
# Decision: this gate fails open, always. See docs/adr/0002-the-roseline-gate-fails-open-always.md
# for the context and consequences — do not re-argue it here.

case "${ROSELINE_GATE:-}" in off|0|false|no|disabled) exit 0 ;; esac

# `on` is the counterpart, and it is deliberately checked SECOND: `off` stays the master switch, so
# a stale `on` in a shell rc can never override the `off` a user just typed. It forces enforcement
# past the `dnx` probe below — the user's testimony that roseline IS running here, by whatever route
# (a hand-added MCP server, a locally built binary, a wrapper script) — and it is the only kind of
# evidence available: preflight settles this class by observing a live server, and a PreToolUse hook
# is handed nothing but the tool payload (#155). Any other value, `maybe` included, is neither
# switch and falls through to the probe exactly as an unset variable does.
FORCE=0
case "${ROSELINE_GATE:-}" in on|1|true|yes|enabled) FORCE=1 ;; esac

payload=$(cat) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Re-checked even though hooks.json matches "Read": the matcher is a regex, so it also catches
# NotebookRead, which this gate has no business blocking.
tool=$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null) || exit 0
[ "$tool" = "Read" ] || exit 0

fp=$(jq -r '.tool_input.file_path // empty' <<<"$payload" 2>/dev/null) || exit 0
case "$fp" in *.cs) ;; *) exit 0 ;; esac

# ------------------------------------------------------- can roseline be running on this host?
# Denying a Read names `mcp__roseline__*` as the replacement, so the gate must not deny when those
# tools cannot exist. `.mcp.json` launches the server with `dnx`, which ships ONLY in the .NET 10
# SDK, while the pipeline itself accepts `dotnet >= 8` — so on a .NET 8/9 host preflight went green,
# the server never started, and the gate blocked every `.cs` Read in favour of tools the session
# could not call (#112). No `dnx`, no shipped launcher, no server: let the Read through.
#
# A proxy, deliberately, and one that errs the safe way. A PreToolUse hook is handed only the tool
# payload on stdin — there is no channel exposing the connected MCP servers — so a live handshake is
# not available at all. This cannot catch a server that started and then crashed; that costs one
# unnecessary deny, recoverable through the retry escape below, whereas the reverse mistake costs
# nothing: the Read simply proceeds.
#
# It also subsumes the SDK floor `requirements.json` declares (`requiresSdk`) rather than reading
# it: `dnx` on PATH implies an SDK at or above 10 by construction, and `command -v` is a shell
# lookup where parsing the manifest would put a `jq` plus a `dotnet --list-sdks` spawn on the path
# of every `.cs` Read.
#
# Placed above the marker write on purpose — a fail-open path must not arm a one-shot escape that
# nothing will ever consume, which would then let the NEXT read of that file through for free.
#
# ROSELINE_GATE=on short-circuits the probe rather than replacing it: a proxy this coarse is wrong
# in exactly one direction — it cannot see a server started by any route other than the shipped
# launcher — and the user is the only authority this hook can consult about that. The declaration
# therefore has to be able to beat the probe, never merely agree with it.
[ "$FORCE" = 1 ] || command -v dnx >/dev/null 2>&1 || exit 0

# ---------------------------------------------------------------- is this .cs inside a project?
# Walk UP from the file's own directory. Upward is the direction that answers the question; a
# downward scan from cwd misses the mainstream src/Company.Product/Api/Api.csproj layout entirely
# (depth 4), leaving the gate silently off in exactly the repos it is meant for.
# `-print -quit` captured into a variable with `|| true`, per the lesson tests/_lib.sh's
# first_match() records (#48, #98): find stops itself on the first hit so nothing can SIGPIPE it,
# and a legitimately-missing path must not abort the gate. Spelled out rather than called: a hook
# runs standalone from any repo, so it cannot source the kit's test helper.
hit=""
dir=$(dirname "$fp")
levels=0
while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ] && [ "$levels" -lt 40 ]; do
  hit=$(find "$dir" -maxdepth 1 \( -name '*.sln' -o -name '*.slnx' -o -name '*.csproj' \) -print -quit 2>/dev/null || true)
  [ -n "$hit" ] && break
  dir=$(dirname "$dir")
  levels=$((levels + 1))
done

# Fallback for a .cs sitting above its project (a loose file at the repo root, say): a shallow
# scan down from the session's cwd.
if [ -z "$hit" ]; then
  cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    hit=$(find "$cwd" -maxdepth 3 \( -name '*.sln' -o -name '*.slnx' -o -name '*.csproj' \) -print -quit 2>/dev/null || true)
  fi
fi
[ -n "$hit" ] || exit 0

# ------------------------------------------------------------------------- the one-shot escape
# An identical repeat Read within the window is allowed through — the documented "I genuinely need
# the exact full text" case, and the only way to Edit a C# file (Edit refuses a file the
# conversation has not Read). Both halves of the key are sanitised: a session id or path with a
# slash in it would otherwise build a marker path pointing somewhere else entirely.
sid=$(jq -r '.session_id // "nosession"' <<<"$payload" 2>/dev/null)
sid=$(printf '%s' "${sid:-nosession}" | tr -c 'A-Za-z0-9._-' '_')
key=$(printf '%s' "$fp" | md5 -q 2>/dev/null || printf '%s' "$fp" | md5sum 2>/dev/null | cut -d' ' -f1)
# No hasher at all (minimal containers — the same hosts kit_require_find_quit worries about) would
# leave the key empty, collapsing the marker to one per session: the escape for Foo.cs would then
# let the next .cs file through on its first read. Fall back to the flattened path.
[ -n "$key" ] || key=$(printf '%s' "$fp" | tr -c 'A-Za-z0-9._-' '_' | tail -c 120)
# The `-kit-` segment is a NAMESPACE, not decoration (#666). Without it this path was byte-identical
# to the one `~/.claude/hooks/roseline-gate` builds — the hand-rolled predecessor this gate is a
# hardened rewrite of, still registered on `Read` on any host that ever had it. Both hooks then
# shared one token: one armed it, the other consumed it inside the same tool call, the deny won, and
# the retry this gate's own message instructs found nothing and was denied again. 264 of 264
# instructed retries across 2,078 sessions. A PreToolUse hook is handed only the tool payload, so
# the sibling cannot be detected; owning the path is the only thing available. Do not shorten it.
marker="${TMPDIR:-/tmp}/roseline-gate-kit-${sid}-${key}"

# Only a RECENT marker counts. A marker is otherwise cleared solely by the retry that consumes it,
# so the common path — model complies, uses roseline, never retries — leaves one behind forever,
# and a Read of that file hours later (or after --resume, which preserves session_id) would be
# silently allowed. The window keeps "issue the identical Read again" meaning immediately.
if [ -f "$marker" ] && [ -n "$(find "$marker" -mmin -2 2>/dev/null || true)" ]; then
  rm -f "$marker" 2>/dev/null
  exit 0
fi

# If the marker cannot be written the escape can never fire, and denying would deadlock the file
# while the message still tells the reader to retry. Fail open instead.
touch "$marker" 2>/dev/null || exit 0

base=$(basename "$fp")
reason="Blocked by the roseline gate: ${base} is C#, and this kit routes all C# analysis through RoselineMCP. Use these instead of Read:
  - file shape / locate a member  -> mcp__roseline__search_symbols (file: \"${base}\")
  - read one member's body        -> mcp__roseline__get_symbol_info (includeSource: true)
  - usages / implementors / calls -> mcp__roseline__find_references, find_implementations, get_call_graph
  - resolve a file:line           -> mcp__roseline__get_symbol_at_position
  - edit a member body, or rename -> mcp__roseline__edit_member, rename_symbol
They return only the structure you need and cost far fewer tokens than the whole file.
If you need the exact full text -- or you are about to Edit this file, which requires having Read it, or the change is outside a member body (usings, namespace, attributes, top-level statements) -- issue the identical Read again straight away and the retry is allowed through."

jq -n --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
exit 0
