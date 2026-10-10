---
id: 12
title: 'Two skill naming rules: verb-object, and family-role'
status: accepted
date: 2026-08-31
tags:
- skills
- naming
- breaking-change
links:
- type: relates-to
  target: 1
- type: relates-to
  target: 3
- type: relates-to
  target: 4
code_refs:
- path: skills/init/SKILL.md
- path: skills/review-followups/SKILL.md
- path: skills/debug-issue/SKILL.md
- path: skills/migrate-legacy/SKILL.md
- path: tests/skills/check-frontmatter.py
parent: Architectural Decision Records
nav_order: 12
---

# Two skill naming rules: verb-object, and family-role

## Context and Problem Statement

A skill's folder name is not a label on the folder — it *is* the identifier, six times over: the
`name:` frontmatter, the `/ai-migration-kit:<name>` invocation a user types, the
`evals/<name>-trigger-eval.json` filename, an entry in each of two literal Python rosters
(`evals/run_all.py`'s `SKILLS` and `evals/trigger_eval.py`'s `DEFAULT_KNOWN`), a row in the
per-skill `area:` taxonomy that `auto-dev` slices worker isolation from, and the string every
cross-referencing `SKILL.md` spells by hand. There is no indirection anywhere;
`tests/skills/check-frontmatter.py` turns the coincidence into a contract by refusing a `name:`
that differs from its folder and by asserting both rosters equal the `skills/*/` folder set (#331).

The ten shipped skills were named three different ways at once. Six read as verb-object
(`create-issue`, `implement-issue`, `merge-pr`, `triage-backlog`, `setup-repo`, `auto-dev`); the
family members read as `<family>-<role>` (`auto-dev-worker`, `auto-dev-merge`; `migrate`,
`migrate-assess`, `migrate-audit`, `migrate-verify`, `migrate-followups`). Four did neither:
`get-repo-profile` was verb-object-object with a redundant `get-`; `followups` was a bare noun that
collided in `grep` with `scripts/followups.py` and `commands/migrate-followups.md`;
`systematic-debugging` named a *style* rather than a job; and `legacy-upgrade` was inverted and, worse,
was the head of the `migrate-*` family that all four of its own commands are named after, so a
contributor grepping `migrate` for the pipeline found the commands and the four siblings and missed
the head. Because the name is the identifier and not a label, that inconsistency was not contained
in one place: measured on `main` it spanned 53 files for `legacy-upgrade`, 49 each for
`get-repo-profile` and `followups`, 19 for `systematic-debugging`. Two of the four also made the
`area:` taxonomy contradict itself at the point where the isolation contract is read — `area: migrate`
covered a folder called `legacy-upgrade`, `area: repo-setup` one called `get-repo-profile`.

## Considered Options

- Do nothing, and document the inconsistency in `ARCHITECTURE.md`.
- Rename, and ship alias folders (or a name-map) so the old invocations keep resolving.
- Rename only `legacy-upgrade` — the one whose name actively misleads — and leave the other three.
- Rename all four, with no aliases, and record the naming rule itself.

## Decision Outcome

Every folder under `skills/` is named by one of exactly two rules — **(1) a standalone skill is
`verb-object`**; **(2) a member of a family is `<family>-<role>`, where `<family>` is itself a rule-1
name or the bare verb that heads the family** — and the four non-compliant folders are renamed in the
2.0 breaking window with **no aliases, shims, redirect folders or deprecation period**
(`get-repo-profile` → `profile-repo`, `followups` → `review-followups`, `systematic-debugging` →
`debug-issue`, `legacy-upgrade` → `migrate-legacy`). Aliases lose on their own mechanics rather than
on taste: `check-frontmatter.py` demands one `evals/<name>-trigger-eval.json` set and two roster
entries per `skills/*/` folder, so each alias would have to carry a duplicate eval set, and the
trigger bench would then score two descriptions competing for the same queries — measurably worse
than the inconsistency it papers over, and an alias *is* a second name for the same skill, which is
the exact thing the rules exist to end.

## Consequences

**Renames happen only in a major.** A skill name is a user-typed invocation and a filename in five
machine-read places, so changing one is a breaking change; outside a major nobody schedules it on its
own, which is how four offenders accumulated. This record makes the wait affordable rather than
arbitrary: a future rule-breaking name is fixed at the next major, not argued about again from
scratch, and the ADR is what a reviewer cites when a new skill is proposed under a third shape.

The rules also make the ten-skill list *predictable* rather than arbitrary. `README.md` and
`ARCHITECTURE.md` now state the two rules and point here instead of explaining why four entries look
different, and a reader who knows the family (`migrate-*`, `auto-dev-*`) can predict the folder name
without opening `skills/`.

The cost is paid once, in this release, and it is real: every old invocation in a user's muscle
memory, notes or scripts stops resolving, with no error that suggests the new name. It is also
paid inside the repo, since the name is spelled by hand in ~120 files — which is precisely the
argument for making the sweep once, under one rule, rather than four separate times. Because the
descriptions themselves are unchanged, a shift in the trigger bench after this lands is measurement
noise rather than a regression, and is re-run before it is acted on (ADR-0007 keeps
`evals/run_all.py` out of the worker fleet, so the owner runs it).
