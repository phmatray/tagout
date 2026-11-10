---
id: 2
title: The roseline gate fails open, always
status: accepted
date: 2026-08-31
tags:
- hooks
- roseline
code_refs:
- path: hooks/roseline-gate.sh
- path: hooks/git-write-gate.sh
sources:
- hooks/roseline-gate.sh
parent: Architectural Decision Records
nav_order: 2
---

# The roseline gate fails open, always

## Context and Problem Statement

`requirements.json` makes RoselineMCP `level: required`, but preflight can only prove the server is
*connected*; `hooks/roseline-gate.sh` is the PreToolUse hook that proves it is *used*, by denying a
`Read` of a C# file and naming the roseline tool that replaces it. The plugin installs globally, so
that hook runs in every repository the user opens, including ones the kit was never meant to touch.
(Context lifted from the header comment of `hooks/roseline-gate.sh`; #112 and #155 re-derived it.)

## Considered Options

- Fail closed: any uncertainty (no `jq`, an unreadable payload, no launcher on PATH) denies the Read.
- Fail open: any uncertainty exits 0 with no output and lets the Read through.
- Fail closed with a repo allow-list.

## Decision Outcome

Every failure path exits 0 with no output and lets the `Read` through — a missing `jq`, a payload the
hook cannot parse, a path it cannot classify, and "cannot enforce" because roseline's shipped `dnx`
launcher is not on PATH are all the same answer; the gate blocks only where it has positive evidence
that enforcement is meaningful, with `ROSELINE_GATE=off` disabling it outright and `ROSELINE_GATE=on`
overriding the launcher probe (never the off-switch).

## Consequences

A host that has roseline running by some route the probe cannot see (a hand-added server, a locally
built binary) is not enforced unless the user says `ROSELINE_GATE=on` — the price of never
deadlocking an unrelated repository. Because "fails open" is invisible when it fires, it has been
re-derived from scratch twice; that is what this record exists to stop.

This is a decision about **every** hook the plugin ships, not about the roseline one specifically —
the argument is "the plugin installs globally", and nothing in it is about C#. `hooks/git-write-gate.sh`
(#326) is the second hook to inherit it, with `GIT_GATE=off`/`on` as the same two switches in the
same order and the committed `.claude/skills/repo-profile.md` playing the part `dnx` plays here: the
positive evidence that the replacement the denial names can actually exist in this repository. A
third hook takes the same terms; it does not get a second record.

A repo whose only project marker is a `*.slnx` is treated as unmarked (#699): Roseline discovery cannot open it, so the gate lets the Read through.

**Opt-in strict mode (amendment).** `TAGOUT_HOOKS_STRICT=1` inverts one class of paths, in `hooks/git-write-gate.sh` only (the hook that protects writes): when the hook cannot judge a command that looks like a git write, it refuses (exit 2) instead of letting it through. Everything else is unchanged: the default stays fail-open, `GIT_GATE=off` still wins, and once the hook has read the command and its working directory the profile probe still decides where it applies — a judgeable call, an over-long command or one whose quoting it cannot parse all pass in a repository the kit does not manage, so a machine-wide variable never deadlocks an unrelated repository. Before that point (no `jq`, an unreadable payload or cwd) the hook cannot tell a managed repository from another one, so strict mode refuses any git-looking call there too: that is what opting in asks for, and why the kit never sets the variable. "Git-looking" is the gate's own cheap reject (`git`, `gh … merge`, or a backslash); without `jq` it is applied to the raw payload, paths and JSON escapes included, so in practice nearly every Bash call is refused until `jq` is back. A substituted command (`$(...)`, `bash -c`, `eval`) whose own check refuses, dies or cannot start refuses the whole line, and so does a cwd that is missing or not a directory. A command refused because it could not be parsed keeps a per-command escape — a `GIT_GATE=off ` prefix at its very start, on the main thread only — because valid shell the stripper cannot follow (a comment holding `&` and an apostrophe) would otherwise have none. The variable accepts `1`, `on`, `true` or `yes` in any case; any other value is the default. It exists for teams whose change-management control (ISO/IEC 27001:2022, control 8.32) cannot accept an unjudged write. One limit is not closed: a hook that outruns its own `timeout: 5` is killed by the host before it can refuse, and whether the host then proceeds is the host's behaviour, not this hook's. The roseline gate (reads) and the Stop gate are not affected.
