---
id: 18
title: profile-repo and setup-repo merge into init
status: accepted
date: 2026-10-09
tags:
- lifecycle
- naming
- breaking-change
links:
- type: supersedes
  target: 13
- type: relates-to
  target: 12
- type: relates-to
  target: 1
code_refs:
- path: skills/init/SKILL.md
parent: Architectural Decision Records
nav_order: 18
---

# profile-repo and setup-repo merge into init

## Context and Problem Statement

ADR 0013 (2026-09-02, proposed) kept `profile-repo` — the reader that records a repository's facts
in `.claude/skills/repo-profile.md` — and `setup-repo` — the writer that converges labels, issue
forms, settings, topics and the Pages source from a manifest — as two skills, and named the shape to
take "if the boundary keeps confusing users": a merge, in the next major. Making a repository ready
for the lifecycle skills still takes two front doors and a third invocation nothing executes
(`setup-repo` ends on *"re-run `profile-repo --refresh`"*), and every place a newcomer meets the kit
— the `AGENTS.md` routing line, the README's "A new repo for these skills" row, the methodology's two
rows — spells it as "`profile-repo` then `setup-repo`". On 2026-10-09 the owner decided the merge,
under the name `init`: clearer for users, one command fewer (#700).

## Considered Options

- One skill, `init`, over the two unchanged scripts, with three paths — the whole story by default,
  `--plan` that writes nothing on GitHub, `--profile-only` that is today's `profile-repo`. Chosen.
- Keep two skills and add an `/init` command that runs both in sequence. Declined: it adds a front
  door instead of removing one, and the routing table would name three entries for one step.
- Merge under `configure-repo`, the name ADR 0013 pre-computed. Declined as the primary name — it is
  not the one the owner chose — and kept as the fallback below.

## Decision Outcome

`profile-repo` and `setup-repo` become one skill, `init`, in three slices — `init` lands beside them
(#701), their scripts move under `skills/init/` with names and CLIs unchanged (#702), and the old
skills are deleted with no alias in a `feat(init)!:` major (#703, ADR 0012's no-alias rule). ADR
0013's two arguments survive inside the one skill rather than between two: the profile path still
runs without rights and degrades to TODOs, and the writer runs only on a request to set up,
configure or converge (or a bare `/tagout:init`) — a request to read or regenerate the profile, or
to check drift, takes `--profile-only` or `--plan`. `init` is a bare verb, a named exception to
ADR 0012's rule 1 (`verb-object`): its object, the repository, is implicit, the way the bare verb
`migrate` heads its family; rules 1 and 2 stand for every other skill.

## Consequences

One front door: the routing line, the README and the methodology name `init` alone, and the
profile refresh after `apply` is a step of the skill rather than advice. The cost is a breaking
release — every `/tagout:profile-repo` and `/tagout:setup-repo` in a user's notes stops resolving,
which the 4.0.0 notes announce — and a name Claude Code already uses: its built-in `/init` writes a
`CLAUDE.md`, so the kit's skill is typed `/tagout:init`, and `evals/init-trigger-eval.json` carries
"create a CLAUDE.md for this repo" as a should-not-trigger near-miss. Reopens when the owner-run
trigger bench measures that near-miss — or any built-in-`/init` phrasing — firing `init` above the
0.5 threshold after a description edit; the rename to `configure-repo` is then the shape to take,
at the next major.
