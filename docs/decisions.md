---
title: Decisions
nav_order: 3
nav_group: internals
---

# Decisions

A **decision** is a control-flow choice the methodology makes — "is this branch green?", "what
correction does this merge state call for?". This document is about where one is allowed to live.

## The rule

> One id, one program, one home. The agent **invokes** a decision; prose **explains** it and may
> not **restate** it.

Everything below is machinery for making that rule mechanical rather than aspirational.

## Why (#208)

`skills/merge-pr/scripts/merge-verdict.sh` encoded the whole Step 4 precedence, was pinned by
fixtures, and was wired into CI. Nothing called it. `skills/merge-pr/SKILL.md` restated the same
rule as a markdown table, and the agent applied *that*, by hand.

Two homes drift, and these two did: a jq object construction renamed `behind_by` to `behind` while
the script still read `behind_by`, so the freshness guard read `null` forever. A human reviewer
caught it, not CI. And the twin defect one line below survived that fix — composed exactly as Step 4
documented it, the verdict was `wait` for CLEAN, DIRTY and BLOCKED alike.

The lesson is not "be careful". It is that **a rule living in prose cannot go red**, and this repo
had at least ten open issues of that same shape.

## The pieces

| Piece | Job |
|---|---|
| `decisions/registry.json` | every decision: its id, program, owner, suites, declared verdict vocabulary |
| `scripts/decide.sh` | the only way to run one — `decide.sh <id> [--json] [state.json]` |
| `scripts/decision-check.py` | the guard: refuses the ways that arrangement rots |
| `tests/decisions/test.sh` | drives every rule of that guard to red, and pins the dispatcher's verdicts |

A program has one of two **kinds**: `exec` (a script, e.g. `merge-verdict.sh`) or `block` (a marked
jq program living inside a reference file, extracted verbatim — the pattern `tests/merge-gate`
invented, where the thing the test proves green *is* the thing an agent pastes).

## Adding a decision

1. Give the rule one home — a script under `skills/<skill>/scripts/`, or a marked block in a
   reference file. Delete every other copy.
2. Add a row to `decisions/registry.json`: `id`, `program`, `owner` (the file that must invoke it),
   `suites`, and the `verdict.vocabulary` the program can emit.
3. In the owner, replace the restatement with a real call inside a fenced block:
   `"$DECIDE" <id>` or `scripts/decide.sh <id>`.
4. Run `python3 scripts/decision-check.py` and fix what it names.

Adding a script under `scripts/` or `skills/*/scripts/` that is **not** a decision? Record it
instead of registering it: add `"<path>": "<why this is not a control-flow choice>"` under
`not_decisions` in `decisions/registry.json`. R10 refuses it by name otherwise.

## What the guard refuses

| Rule | Refuses |
|---|---|
| R1 | a second copy of the program; a program absent, unstaged, or committed non-executable |
| R2 | a `block` program that does not compile |
| R3 | a `block` program containing a single quote (it is pasted inside a shell `jq '…'`) |
| R4 | a verdict the program emits that the registry never declared |
| R5 | branches whose causes cannot be told apart |
| R6 | a shape block that stopped building what the program reads |
| R7 | an owner that names its decision but never invokes it |
| R8 | prose that re-enumerates the states the program tests |
| R9 | a registry that is not internally coherent |
| R10 | a tracked executable that is neither registered nor recorded as deliberately not a decision |

**R8's token set is derived by regex from the program text**, never listed in the registry. That is
deliberate and it is the whole design: a typed vocabulary in the manifest would be a second copy, in
the manifest of a system whose purpose is to abolish second copies. Grow the program a branch and
restate it, touching the registry not at all, and R8 still fires —
`tests/decisions/test.sh` drives exactly that.

### The escape hatch

A table that explains something no program can may declare itself:

```
<!-- decided-by: merge.step4 -->
```

on its own line just above the table. It costs you the freedom to name a state the program does not
test: an annotated table may enumerate **fewer** states than the program handles, never more. A row
for a state with no branch hides the program's gap instead of making it visible.

## What this does not do

Stated here rather than left to be rediscovered.

- **R8 catches one shape** — a table keyed, in its first column, on tokens the program tests. It is
  blind by construction to a decision restated as prose paragraphs, as a bulleted list, as a mermaid
  diagram, or as a table naming states in its *second* column. Of the ten issues in this class it
  cannot see #175, #161, #163, #158, #144, or #170's own command-list restatement. An author who
  knows the rule can trivially evade it. The claim is "this specific, already-observed restatement
  shape becomes impossible", not "restatement becomes impossible".
- **R10 proves everything real is registered — for one shape.** R1 proves every row in the registry
  is real; R10 (#252) is the converse: every tracked executable matching a pathspec in
  `scripts/tracked-exec-globs.txt` — `scripts/`, `skills/` and `hooks/`, bash and python — must be
  either some decision's `program.path` (**registered**) or a key of the registry's `not_decisions`
  map with a one-line reason (**recorded**) — anything in neither set is refused by name. That
  pathspec list is a FILE rather than a literal inside the guard because `scripts/parse-sweep.sh`
  needs the same answer and kept its own copy of it (#307, for #144). Delete the `merge.step4` row
  and paste the `mergeStateStatus` table back, and R10 now catches exactly what R7 and R8 miss:
  `merge-verdict.sh` drops out of both sets the instant its row is gone, and R10 names the file and
  both remedies. `tests/decisions/test.sh` drives this end to end — deleting a decision's row while
  its program and restating table survive, proving R8 goes silent (the escape) while R10 still fires
  (the close).
  **What R10 still cannot see**: a `block` decision — a marked jq program pasted into a reference
  file rather than a standalone script — has no *path* to enumerate. R10 walks the filesystem for
  executables; a `block` program nobody ever registers in the first place is invisible to it, the
  same way it always was. R10 closes the *exit* (a row deleted out from under a surviving file); it
  does not give a decision-shaped `block` a way to be discovered if it was never entered at all.
  The second, narrower gap that used to be listed here — `hooks/` and a script at a skill's ROOT
  sitting outside the four globs #252 measured with, so `hooks/roseline-gate.sh` needed neither a
  row nor a record — is **closed** (#307): `E` now reads `scripts/tracked-exec-globs.txt`, and both
  files it was hiding are recorded. Where a hook lands once enumerated is
  [ADR 0011](adr/0011-hook-gates-are-recorded-rather-than-registered-decisions.md): **recorded, not
  registered**, because a hook's deny is a PreToolUse `permissionDecision` rather than a verdict
  `decide.sh` dispatches, and there is no owner document for R7 to check.
- **An unanswerable question aborts the run.** An unknown `program.kind` or a `verdict.source` no
  dispatcher implements is refused by `decide.sh` during extraction, so the check exits 2 before
  other rows are evaluated — the build goes red and the cause is named, but the report's usual
  "all of them, not the first" does not hold on that path.

## The event log

Every decision appends one JSON object to `.claude/decision-events.jsonl` in the repo being worked
on (override with `KIT_DECISION_LOG`). Fields: `v`, `ts`, `decision`, `verdict`, `rule`, `program`
(a hash of the program text, so counts reset when the program changes) and `input_sha256`.

It is written fail-open. `skills/auto-dev/scripts/decision-tally.sh` (#318) is its one reader — a
markdown tally `auto-dev` Step 6 pastes into its mandatory `lessons:` block. It exists because the
intended next step is a ratchet that only ever turns prose into code, and that ratchet needs
measurement rather than opinion:

- a rule that never fires is dead weight, or a lie — prune it;
- a rule that fires repeatedly on one cause means the rule upstream of it is wrong — tighten that;
- twenty identical `input_sha256` values are one PR polled twenty times; twenty distinct ones are a
  systematic defect.
