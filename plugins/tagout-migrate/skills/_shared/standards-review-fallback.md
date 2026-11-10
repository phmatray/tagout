# The Standards review without a `code-review` skill

`implement-issue` Step 7 and `merge-pr`'s `ready` correction run the **`code-review` skill** for the
Standards review. Claude Code ships it; the other hosts the kit serves (`docs/platforms.md`) may
not. This brief is the kit's own reviewer for that case, so the review is never skipped and never
replaced by a self-congratulating glance.

## When it applies

Only when there is **no `code-review` skill in this session** — it is not in the session's skill
list, or the `Skill` call answers that it does not exist. When the skill is present, use it at the
explicit level the calling step names (`/code-review medium …` or `/code-review high …`). This
file never runs beside it and never overrides it.

## What the reviewer is handed

Use the **same level** the calling step chose:

| Level | Report |
|---|---|
| `medium` | high-confidence findings only — a finding you would stake the PR on |
| `high` | exhaustive — every finding the grid below turns up, confident or not |

The reviewer reads, and never writes. It is handed:

1. **the staged diff file** — `implement-issue` Step 7 has already written `/tmp/issue-$ISSUE.diff`;
   from `merge-pr`, write `git -C <worktree> diff origin/<base>...HEAD` to a file of your own
   first. Always the path, never the diff text (#477);
2. **the repo profile** — `.claude/skills/repo-profile.md`, the *Coding standards* section;
3. **the checkout, for reading only** — to search for a helper or pattern the diff may have
   rewritten by hand. Without it the *Missed reuse* line of the grid cannot fire on a helper that
   lives in a file the diff does not touch;
4. **the issue's plan, when there is one** — the task list the diff was built from. Without it
   the *Cross-task inconsistency* line has nothing to compare against.

**Who runs it depends on what the host can guarantee:**

- **A read-only sub-agent** — on Claude Code, `subagent_type: Explore` with `isolation: "worktree"`
  (the `review-dispatch` rule in `implement-issue` Step 7). Another host qualifies only if its
  sub-agents can be denied write tools; a "report only" sentence in a prompt is not that.
- **Inline, in this session** — on every host that cannot give that guarantee (`subagents: partial`
  or `no` in `docs/_data/hosts.yml`): do the same examination yourself and write nothing. The
  post-review check below is what proves nothing was written, on either path.

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

`severity` is `high`, `medium` or `low`. The reviewer **never writes**: no edit, no commit, no
`--fix` — it reports and **the parent applies** the findings.

**It also returns what it could not check.** A grid line whose input was missing — no plan (always
the case from `merge-pr` on a PR with no issue), no readable checkout — is reported as
`not checked: <line> — <the missing input>`, never folded into *no findings*. An empty list is a
valid answer only for the lines that were actually examined.

## After it

Run `post-review-check.sh` exactly as after `code-review` — same call, same exit codes, same
recorded sha that `guarded-ready.sh` later demands:

```bash
"$GUARDS/post-review-check.sh" -C "$WORKTREE" --branch "$BRANCH" --before <the sha you wrote down>
```

The one-way-door rule is unchanged too. The recap line for this review reads *Standards review:
kit fallback reviewer (no code-review skill in this session)*, followed by every `not checked`
line — so the reader knows which reviewer stood behind it and what it did not look at.
