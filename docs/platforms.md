---
title: Platforms
nav_order: 1.6
---

# Platforms

The kit is written for Claude Code. Every other host reaches the same skills through an
**adapter** — a file in this repository that points the host at them, never a second copy of a
skill ([ADR 0014](adr/0014-the-kit-is-claude-code-first-and-reaches-other-hosts-through-thin-adapters.md)).
How to install on each: [Install](install.md).

## Plugin hosts

The host's own plugin command installs the kit from this repository.

| Host | Skills | Commands | MCP servers | Gates | Sub-agents |
|---|---|---|---|---|---|
{% for host in site.data.hosts %}{% if host.tier == "plugin" %}| {{ host.name }} | {{ host.gets.skills | capitalize }} | {{ host.gets.commands | capitalize }} | {{ host.gets.mcp | capitalize }} | {{ host.gets.hooks | capitalize }} | {{ host.gets.subagents | capitalize }} |
{% endif %}{% endfor %}

## Rule-file hosts

A clone at `~/.tagout` plus a rule file the host reads, which routes each request to a
skill in the clone.

| Host | Skills | Commands | MCP servers | Gates | Sub-agents |
|---|---|---|---|---|---|
{% for host in site.data.hosts %}{% if host.tier == "rules" %}| {{ host.name }} | {{ host.gets.skills | capitalize }} | {{ host.gets.commands | capitalize }} | {{ host.gets.mcp | capitalize }} | {{ host.gets.hooks | capitalize }} | {{ host.gets.subagents | capitalize }} |
{% endif %}{% endfor %}

*Skills* are the kit's `skills/*/SKILL.md`; *commands* are `/migrate` and its siblings; *MCP
servers* are RoselineMCP and AdrMcp, started for you; *gates* are the hooks that refuse a raw
`Read` of a C# file, an unguarded `git` write and an early stop of an `auto-dev` fleet; *sub-agents*
are the fresh-context workers `auto-dev` and `deliver-issue` dispatch. *Partial* is explained
below, host by host.

## What differs on each host

{% for host in site.data.hosts %}
**{{ host.name }}** — {{ host.note }} Adapter: `{{ host.adapter }}`.
{% endfor %}

## What does not travel

Three things are Claude Code's own, and the kit uses them without an abstraction over them:

- **The gates.** They are Claude Code hooks reading Claude Code's hook payload. Codex runs the same
  hook map, so its `Bash` and `Stop` gates fire; other hosts run without them. Every gate fails
  open by design ([ADR 0002](adr/0002-the-roseline-gate-fails-open-always.md)), so a host without
  them loses a guard, never a working command.
- **Sub-agents.** `auto-dev` keeps a fleet of workers in fresh contexts and `deliver-issue` runs
  each phase in one. On a host without sub-agents, run `create-issue`, `implement-issue` and
  `merge-pr` yourself, one after the other.
- **The Standards review.** `implement-issue` Step 7 runs the `code-review` skill. A host without it
  falls back to the kit's own read-only reviewer
  (`skills/implement-issue/references/standards-review-fallback.md`), at the same level.

A new host is one row in `docs/_data/hosts.yml` and one adapter file, checked on every CI run by
`scripts/host-adapters.py` — never a change to a skill.
