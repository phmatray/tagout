# Tagout

Agent skills for two loops: a gate-verified pipeline that takes a legacy .NET application to
verified production, with RoselineMCP doing every C# analysis and edit, and a hands-off GitHub
issue → pull request lifecycle. Guide: https://phmatray.github.io/tagout/

## Which kit skill, for what

Reach for the kit's own skills first, before any third-party plugin's equivalent (`superpowers`):
`<kit>/skills/_shared/` is the one home of their doctrine (#324), `<kit>` being the kit root — the
plugin's install directory, or a clone at `~/.tagout`. Full guide:
`<kit>/docs/methodology.md`. Short form — broken/flaky → `debug-issue`; a new idea →
`create-issue` (`--seed #N` plans a raw issue); a planned issue → `implement-issue #N`; a finished branch → `create-pr`; a ready PR →
`merge-pr #N`; many issues hands-off → `auto-dev`; the queue → `triage-backlog`; profile/labels →
`profile-repo` then `setup-repo`; a legacy .NET app → `/migrate-assess` then `/migrate`; a missing
skill → write it with `skill-creator`, then register it (*Adding a skill* in `<kit>/.claude/CLAUDE.md`).

## Loading a skill

Each skill is a folder under `<kit>/skills/` whose `SKILL.md` says when it applies and what to do.
When a request matches a row above, read that `SKILL.md` and follow it step by step; the files it
links resolve relative to it. A `/migrate…` command is the `migrate-legacy` skill run at a given
scope (`<kit>/commands/`).

`<kit>` is the kit root — the directory holding `skills/`, `scripts/` and `requirements.json`:

- **installed as a plugin** — two directories above the skill's own `SKILL.md`;
- **this text is a rule file in your own project** — a clone at `~/.tagout`
  (`git clone https://github.com/phmatray/tagout ~/.tagout`).

Skill scripts need bash, python3 with PyYAML, git and an authenticated `gh`;
`<kit>/requirements.json` lists every prerequisite and `<kit>/scripts/preflight.sh` checks them.

## MCP servers

The migration pipeline runs on **RoselineMCP** (required: every C# analysis and edit goes through
it) and consults **AdrMcp** (recommended: the architectural decisions under `docs/adr/`). Both start
with `dnx` from the .NET 10 SDK — `dnx RoselineMCP --yes` and `dnx AdrMcp --yes`. A plugin install
starts them from the kit's own manifest; anywhere else, register both in your host's MCP settings.
Without RoselineMCP, `/migrate` stops at its phase-0 preflight; without AdrMcp, the skills grep
`docs/adr/` instead and say so. The issue → pull request skills need neither.

`auto-dev` and `deliver-issue` dispatch sub-agents and need a host that has them. The gates under
`<kit>/hooks/` are Claude Code hooks; elsewhere the skills run without them.
