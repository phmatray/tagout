## Step 3 — Pick the execution mode

You can't change this session's reasoning-effort setting, so "Extra vs Ultracode" is a choice of
**execution strategy**, sized to the plan. State which you picked and why, then proceed — don't ask.

- **Inline ("Extra")** — implement here, one task at a time, in this session. For a **single-task** plan in one area (e.g. one module + its tests), no cross-layer churn.
- **Subagent-per-task ("Ultracode")** — dispatch **one fresh-context sub-agent per task, sequentially and in the foreground**, through the Agent tool (`subagent_type: general-purpose`; the same substrate `auto-dev` spawns its workers on since #314) — consume each report before dispatching the next, because tasks build on each other (the plan is a TDD chain, do NOT parallelize). Each sub-agent gets its task block, the Global Constraints, the repo grain and the pointer Step 6 describes, implements to a green filtered test run per [`../_shared/tdd-loop.md`](../../../_shared/tdd-loop.md), and reports a short diff summary; you verify the diff it left, not the summary it wrote. For **every plan of two or more tasks**. A **broad/deep** plan — ~4+ tasks, OR multiple layers of the *Architecture grain*, OR a whole new subsystem/target, OR a long file-touch list — also escalates the Step 7 review to `/code-review high origin/main...HEAD`.

When it's a toss-up, prefer subagent-per-task — fresh context per task keeps quality high on the longer
plans. Either way **this skill stays the parent**: it owns the worktree, draft PR, per-task ticking,
review, and ready-flip; a subagent implements a task and reports back.

### In subagent mode: explore ONCE, then implement

*Ported from mattpocock/skills `in-progress/implement-spec` (MIT), whose exploration subagent "saves
its markdown notes in a directory outside the repo, accessible by all future subagents".*

Fresh context per task is the point of this mode and also its bill: every subagent starts knowing
nothing, so task 4's re-reads the files task 1's already mapped. That re-exploration is paid **per
task**, and `commands/auto-dev-worker.md` measures what per-turn context costs. Pay it once instead:

> **Before task 1** — so after Step 4, with `$WORKTREE` bound — dispatch **one** `Explore` sub-agent
> at **`$WORKTREE`**, with the plan, the issue's 📋 Spec and the profile's *Architecture grain*. Name
> the tree explicitly, the way every other dispatch in Steps 5–9 passes `-C "$WORKTREE"`: a sub-agent
> left to infer it explores whichever checkout it woke up in, which is the Step 4 hazard one level
> out. It writes `/tmp/issue-$ISSUE-notes.md` and reports only that it
> did — per task: the files and symbols involved, the tests that already exist at each seam named on
> the plan preamble's `**Seams under test:**` line, and the conventions the task must follow. It
> implements nothing and changes nothing.
>
> Each per-task sub-agent then receives its task block, the Global Constraints, and **that path** —
> a **pointer, not the notes** — and is told to read it first. Pasting the notes into every dispatch
> reintroduces the cost the single pass just removed.

`/tmp` and not the worktree, deliberately: the notes are scratch for this run, they must not reach
the diff, and every sub-agent can read them wherever their own cwd happens to be. **Inline mode skips
this** — it explores as it goes, in the one context that is doing the work.

The notes are *this run's* reading of the tree, not an authority: a sub-agent that finds them wrong
follows the tree, and says so in its report.
