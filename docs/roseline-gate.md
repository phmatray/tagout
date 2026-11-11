---
title: The roseline gate
nav_order: 5
nav_group: internals
---

# The roseline gate

> Moved here from README.md's Prerequisites section (#325) — the essay is unchanged; the
> README keeps a four-bullet summary and a link back to this page.

### RoselineMCP is shipped *and* enforced

You do not need to `claude mcp add roseline` — the kit ships the server itself in
[`.mcp.json`](../.mcp.json) (`dnx RoselineMCP --yes`), so installing the plugin installs the dependency.

> `dnx` ships with the **.NET 10 SDK**. The pipeline itself only needs `dotnet >= 8`, so on a
> .NET 8/9-only host the server does not launch — and the kit now says so instead of leaving you to
> deduce it. [`requirements.json`](../requirements.json) records the server's own floor
> (`"requiresSdk": "10"`, higher than the pipeline's), phase 0 reports it as a **named degradation**
> rather than a green tick, and the gate below **fails open** whenever `dnx` is absent. So you are
> told what is missing and nothing is blocked in the meantime; install the .NET 10 SDK to get
> roseline itself.

It also **enforces** it. Preflight only ever proved roseline was *connected*; nothing made it
*used*, and in practice `Read`/`Grep` on a `.cs` file stayed the path of least resistance. So
[`hooks/roseline-gate.sh`](../hooks/roseline-gate.sh) runs as a `PreToolUse` hook and **denies** `Read`
on a C# file, naming the roseline tool that replaces it (`search_symbols`, `get_symbol_info`,
`find_references`, …). An advisory reminder was tried first and does not work — the reminder arrives
together with the file content, so the model has already been paid by the time the advice lands.

Four properties keep that safe to have switched on:

- **Inert outside C# projects.** The gate walks *up* from the file looking for a
  `*.sln`/`*.slnx`/`*.csproj`, and no-ops when it finds none — so a globally-installed plugin never
  blocks reads in a repo that has no roseline.
- **A one-shot escape.** Issuing the *identical* `Read` again straight away is allowed through. It
  is consumed rather than latched (a third read denies again) and it expires, so a marker left
  behind by a deny you complied with cannot silently open the file hours later.
- **Fails open, always.** No `jq`, an unparseable payload, an unwritable `TMPDIR`, any internal
  error — the gate exits silently and the `Read` proceeds. It never fails closed.
- **It never enforces a tool that cannot be there.** No `dnx` on `PATH` means the shipped launcher
  cannot have started the server, so the `mcp__roseline__*` tools the deny message names do not
  exist — and the gate lets the `Read` through rather than pointing you at them. That probe is a
  proxy, and it errs in one direction only: it cannot see roseline started by any *other* route, so
  `ROSELINE_GATE=on` is there to say "it is running, enforce anyway" (see below).

`Grep` is deliberately left alone: roseline replaces whole-file reads, but `search_symbols` finds
*symbols*, and grepping a string literal or a comment in `.cs` is a real need it cannot serve.

**Editing a C# file.** `Edit` refuses a file the conversation has not `Read`, and roseline's
`edit_member`/`rename_symbol` cover member bodies and renames but not `using` directives,
file-scoped namespace conversion, attributes above a type, or top-level statements. For those, take
the escape: the denied `Read`, then the identical `Read` again, then `Edit`. The deny message says
so.

**To turn the gate off**, set `ROSELINE_GATE=off` in your environment (also `0`, `false`, `no`,
`disabled`). There is no `Read` matcher to remove from your own settings — the hook is supplied by
the plugin in [`hooks/claude-hooks.json`](../hooks/claude-hooks.json), so the other levers are uninstalling the
plugin or Claude Code's global `disableAllHooks`.

**To turn it *on* regardless**, set `ROSELINE_GATE=on` (also `1`, `true`, `yes`, `enabled`). This is
for the case the `dnx` probe cannot settle: you are running roseline by some route other than the
shipped launcher — a hand-added MCP server, a locally built binary, a wrapper script — or `dnx` is
on your login shell's `PATH` but not on the narrower one Claude Code hands its hooks. Left alone,
the gate would fail open for you permanently and silently; `on` is your word that the server is
there, and enforcement resumes. `off` is still checked first and still wins, so a stale `on`
somewhere in your environment can never override an `off` you have set. Any other value is neither
switch and leaves the probe to decide.

> **Permission prompts are a separate concern.** A Claude Code plugin cannot ship `permissions`
> allow rules — only a settings file can. So if roseline's tool calls prompt you for Accept/Deny,
> add them to your own `~/.claude/settings.json` (or an org `managed-settings.json`) as **per-tool**
> entries, e.g. `mcp__roseline__search_symbols`. That is outside what this plugin can do for you.
