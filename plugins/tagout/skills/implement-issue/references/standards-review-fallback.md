# The Standards axis without a `code-review` skill

`implement-issue` Step 7 runs the **`code-review` skill** for the Standards axis. Claude Code ships
it; the other hosts the kit serves (`docs/platforms.md`) may not. This brief is the kit's own
reviewer for that case, so the axis is never skipped and never replaced by a self-congratulating
glance.

## When it applies

Only when there is **no `code-review` skill in this session** — it is not in the session's skill
list, or the `Skill` call answers that it does not exist. When the skill is present, use it:
`/code-review medium origin/main...HEAD` or `/code-review high origin/main...HEAD`, exactly as
Step 7 says. This file never runs beside it and never overrides it.

## How to run it

Use the **same level** Step 7 chose (the plan's breadth, raised to `high` by a one-way door):

| Level | Report |
|---|---|
| `medium` | high-confidence findings only — a finding you would stake the PR on |
| `high` | exhaustive — every finding the grid below turns up, confident or not |

Hand **one read-only sub-agent** (`subagent_type: Explore`, `isolation: "worktree"` — the
`review-dispatch` rule in Step 7) exactly two paths and nothing else:

1. the diff Step 7 already staged — `/tmp/issue-$ISSUE.diff` — never the diff text, never a
   worktree path it could write to (#477);
2. the repo profile — `.claude/skills/repo-profile.md`, the *Coding standards* section.

On a host with no sub-agents, do the same examination inline, in the same two files, and write
nothing.

## The grid

Read the diff once, then ask of each changed hunk:

- **Correctness** — a bug: wrong condition, off-by-one, unhandled null or empty case, a race.
- **Missed reuse** — a helper, component or pattern the repo already has, rewritten by hand.
- **Cross-task inconsistency** — two tasks naming, shaping or ordering the same thing differently.
- **Coding standards** — a rule the profile's *Coding standards* section states, broken.
- **Untested behaviour** — new behaviour with no test in the diff that would fail if it broke.
- **Error handling** — an error swallowed, a failure path that reports success, a missing boundary check.

## What it returns

A list, one line per finding, in text:

```
<severity> · <file>:<line> · <one sentence> · <suggested fix>
```

`severity` is `high`, `medium` or `low`. An empty list is a valid answer and is said as *no
findings*. The reviewer **never writes**: no edit, no commit, no `--fix` — it reports and **the
parent applies** the findings, as for every Step 7 axis.

## After it

Run `post-review-check.sh` exactly as after `code-review` — same call, same exit codes, same
recorded sha that `guarded-ready.sh` later demands:

```bash
"$GUARDS/post-review-check.sh" -C "$WORKTREE" --branch "$BRANCH" --before <the sha you wrote down>
```

The one-way-door rule is unchanged too. The Step 10 recap line for this axis reads
*Standards axis: kit fallback reviewer (no code-review skill in this session)* — so the reader
knows which reviewer stood behind it.
