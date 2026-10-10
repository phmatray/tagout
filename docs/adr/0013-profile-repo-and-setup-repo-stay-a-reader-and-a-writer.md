---
id: 13
title: profile-repo and setup-repo stay a reader and a writer
status: superseded
date: 2026-09-02
tags:
- lifecycle
- naming
links:
- type: superseded-by
  target: 18
code_refs:
- path: skills/profile-repo/SKILL.md
- path: skills/setup-repo/SKILL.md
parent: Architectural Decision Records
nav_order: 13
---

# profile-repo and setup-repo stay a reader and a writer

## Context and Problem Statement

`profile-repo` reads a repository's facts into the committed profile; `setup-repo` writes labels,
issue forms and settings from a manifest. They are two front doors to one story — "make this repo
ready for the lifecycle skills" — and the kit's own trigger bench once sent *"configure this repo
for the issue skills"* to the half that cannot create a label (#279). On 2026-09-02 the owner asked
whether the two should be merged. (Recorded from that question; the answer below is a proposal
for the owner, not a decision taken.)

## Considered Options

- Merge them into one skill, `configure-repo`, with three verbs — `detect` · `plan` · `apply`.
- Keep two skills and sharpen the boundary: the eval sets' near-miss negatives, the hand-off from
  `profile-repo`'s recap to `/setup-repo` when an axis is missing, and the description sentence
  *"It WRITES what profile-repo only READS."*
- Keep two skills and add one command, `/configure-repo`, that runs `profile-repo` then
  `setup-repo plan` in sequence.

## Decision Outcome

Keep two skills, for the current major: one is a reader that runs anywhere without rights and
degrades to TODOs, the other a writer that needs an admin token, refuses by name and is
idempotent — the same report/decide split the kit applies everywhere (`survey.sh` reports, the
supervisor decides), and a merge would put the writer inside the reader's trigger surface. A
rename or merge is a breaking change under ADR 0012, and 2.0 has just shipped one. If the boundary
keeps confusing users after the sharpened evals, the merge into `configure-repo` with three verbs
is the shape to take, in the next major.

## Consequences

Two front doors remain, so the *which one?* question stays answerable only by the descriptions and
the README's table; `tests/skills/test.sh`'s eval structure and the `implement-issue` ↔ `merge-pr`
style boundary bench are what keep it answerable. Reopens when: the trigger bench measures
`setup-repo`'s near-miss negatives firing `profile-repo` (or the reverse) above the 0.5 threshold
after a description edit, or when a 3.0 is planned for another breaking reason.
