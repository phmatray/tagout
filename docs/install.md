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
    "adr": { "command": "dnx", "args": ["AdrMcp", "--yes"] }
  }
}
```

Without RoselineMCP, `/migrate` stops at its phase-0 preflight and says why; the issue → pull
request skills need neither server.

## Uninstall

{% for host in site.data.hosts %}{% if host.uninstall %}
- **{{ host.name }}** — `{{ host.uninstall }}`{% elsif host.tier == "plugin" %}
- **{{ host.name }}** — remove it from the host's own plugin list; its documentation names no command for it.{% endif %}{% endfor %}
- **A rule-file host** — delete the rule file you copied, and `~/.tagout` once no project uses it.
