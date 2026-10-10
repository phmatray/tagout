---
id: 1
title: The repo profile is committed data, not a skill
status: accepted
date: 2026-08-31
tags:
- repo-profile
- lifecycle
code_refs:
- path: skills/profile-repo/SKILL.md
- path: skills/init/scripts/repo-profile.sh
parent: Architectural Decision Records
nav_order: 1
---

# The repo profile is committed data, not a skill

## Context and Problem Statement

Every lifecycle skill needs the same repo-specific facts — commit identity, build and test commands,
the label taxonomy, the CI gates, the conflict hot-spots — and hardcoding them made each skill wrong
in a second repository. The obvious home in a Claude Code plugin is another skill, since skills are
what the loader already knows how to find. (Context lifted from `skills/profile-repo/SKILL.md`,
"The profile is data, not a skill"; the committed-file half is #157.)

## Considered Options

- A skill that answers the questions on demand, invoked by every lifecycle skill at its Step 1.
- A plain committed markdown file the lifecycle skills read directly, with a skill that only
  *generates* it.
- Per-skill hardcoded defaults with per-repo overrides.

## Decision Outcome

The profile is plain markdown at `.claude/skills/repo-profile.md` with no `SKILL.md` beside it, so
the loader ignores it and it costs no context until something reads it; it is **committed**, so it
travels with the repo and a linked worktree sees the same file the main checkout does; and the
lifecycle skills read it through `skills/init/scripts/repo-profile.sh show`, falling back
to the `profile-repo` skill only when the file is genuinely absent — which means the generating
skill is usually never loaded at all.

## Consequences

The profile can go stale without anything noticing, so `profile-repo --refresh` exists and the
file says at the top when to re-run it. Reading it needs a helper rather than a `cat`, because a bare
`cat` of a missing profile is indistinguishable from a silent one and the skills then infer the
identity and gates from the repository instead — invisible in the successful case, which is what made
it worth a named condition (#157).
