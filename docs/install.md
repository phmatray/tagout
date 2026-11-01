---
title: Install
nav_order: 1.5
---

{%- assign plugin_hosts = site.data.hosts | where: "tier", "plugin" -%}
{%- assign rule_hosts = site.data.hosts | where: "tier", "rules" -%}

# Install

The kit is written for Claude Code and installs as a plugin on {{ plugin_hosts.size | minus: 1 }}
more hosts from the same repository. Hosts that read a rules file instead load it from a clone.
On Claude Code it is two plugins — `tagout`, the issue → pull request lifecycle, and
`tagout-migrate`, the .NET migration add-on, installed only to upgrade a legacy .NET application; on
every host but Claude Code the manifest ships the lifecycle and the .NET migration add-on together.
Every command below carries a copy button; the full capability table is on [Platforms](platforms.md).

## Plugin hosts

{% for host in plugin_hosts %}
### {{ host.name }}

```bash
{{ host.install | join: "
" }}
```

{{ host.then }}

{{ host.note }}
{% endfor %}

## Rule-file hosts

Clone the kit once — every rule file below routes its host to the skills in that clone:

```bash
{{ rule_hosts.first.install.first }}
```

{% for host in rule_hosts %}
### {{ host.name }}

```bash
{{ host.install | last }}
```

{{ host.then }}

{{ host.note }}
{% endfor %}

## MCP servers

The migration pipeline runs on RoselineMCP and consults AdrMcp; both start with `dnx` from the
.NET 10 SDK. A plugin host starts them from the kit's own manifest. On a rule-file host, add them
to its MCP settings — most take this shape:

```json
{
  "mcpServers": {
    "roseline": { "command": "dnx", "args": ["RoselineMCP", "--yes"] },
    "adr": {
      "command": "dnx", "args": ["AdrMcp", "--yes"],
      "env": { "DOTNET_hostBuilder__reloadConfigOnChange": "false" }
    }
  }
}
```

The `env` line matters on Linux: AdrMcp runs on the .NET Generic Host, which by default watches its
whole working directory recursively to reload `appsettings.json`. Started from a home directory,
that is one inotify watch per folder, enough to exhaust `fs.inotify.max_user_watches`.

Without RoselineMCP, `/migrate` stops at its phase-0 preflight and says why; the issue → pull
request skills need neither server.

## What the kit costs a session

Installing the kit adds a fixed amount to **every** session on Claude Code, in every repository —
before any kit skill runs. Measured on 2026-11-01 (Claude Code 2.1.316, tagout and tagout-migrate
4.1.0, a 400k-context model), each profile captured twice with identical results:

| Loaded at start | without the kit | `tagout` | `tagout` + `tagout-migrate` |
|---|---:|---:|---:|
| Total | 13.4k | 14.2k (+0.8k) | 14.8k (+1.4k) |
| Messages — the routing table `hooks/routing-context.sh` injects | 10 | 834 (+824) | 834 (+824) |
| MCP server instructions | 0 | 0 | 543 |
| Kit entries in the skill listing | — | 12 skills, 2.6k | 19 skills, 3.2k |
| Every other skill's listing entry (61 skills) | 9.8k | 7.2k (−2.7k) | 6.5k (−3.4k) |
| MCP tool definitions, deferred until used | — | — | 13.3k (roseline 9.7k, adr 3.5k) |

Read the last two rows together. Claude Code caps the skill listing, and the measuring host was
already at the cap, so the kit's 2.6k of entries cost almost nothing in total and **shortened other
skills' descriptions by about as much** — some to under 20 tokens. That is a cost in how reliably
those skills trigger, not in tokens. On a host below the cap, expect the entries to add to the
total instead. The deferred MCP definitions cost nothing until a roseline or adr tool is loaded.

What one **run** of a skill costs is a different measurement: `skills/auto-dev/scripts/usage_report.py`
totals a run's transcripts, sub-agents included, and
[`token-economics.md`](https://github.com/phmatray/tagout/blob/main/skills/auto-dev/references/token-economics.md)
explains where the spend goes (context re-read every turn, not output).

To measure your own host, capture `/context` in a scratch profile without the kit and in one with
it, from a directory with no `CLAUDE.md` above it (memory files would land in both captures):

```bash
P=$(mktemp -d); Q=$(mktemp -d); cd "$(mktemp -d)"
CLAUDE_CONFIG_DIR="$P" claude            # log in once with /login, then quit; same for "$Q"
CLAUDE_CONFIG_DIR="$Q" claude plugin marketplace add phmatray/tagout
CLAUDE_CONFIG_DIR="$Q" claude plugin install tagout@tagout-marketplace
CLAUDE_CONFIG_DIR="$P" claude -p "/context" > without.md
CLAUDE_CONFIG_DIR="$Q" claude -p "/context" > with.md
python3 <kit>/scripts/context-cost.py --baseline without.md --with tagout=with.md
```

## Uninstall

{% for host in site.data.hosts %}{% if host.uninstall %}
- **{{ host.name }}** — `{{ host.uninstall }}`{% elsif host.tier == "plugin" %}
- **{{ host.name }}** — remove it from the host's own plugin list; its documentation names no command for it.{% endif %}{% endfor %}
- **A rule-file host** — delete the rule file you copied, and `~/.tagout` once no project uses it.
