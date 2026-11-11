## Step 6 — The implementation loop

**First, on any resume, reconcile the PR's `### Plan` mirror with the issue's canonical plan**:
any task whose issue block is fully `- [x]` must be ticked in the PR list too. The issue PATCH
and the PR-body edit below aren't atomic — a crash between them in a previous run leaves the
mirror stale, and nothing else ever re-syncs it (recipe: `references/github-mechanics.md` §4).

Then, for each task in plan order whose checkboxes aren't all `- [x]`:

1. **Implement it.** Follow the task's own TDD-first steps (write the failing test → run red →
   implement → run green). Honor the Global Constraints and the profile's *Architecture grain* (touch
   layers in order, don't break invariants). Use the per-task test filter the plan gives. Name new
   files, symbols and test cases from the target repo's root `CONTEXT.md` when it has one; a term
   the glossary lists under `_Avoid_` does not become an identifier.

   **In a target repo with C#, existing code is read and changed through RoselineMCP**, never
   through Read/Grep/Edit on a `.cs` file: `search_symbols` to locate a type or member,
   `get_symbol_info` (`includeSource: true`) to read one, `find_references` before touching an API
   used elsewhere, `edit_member` / `rename_symbol` (preview first) for the change. The kit's own
   `hooks/roseline-gate.sh` denies a `Read` on a `.cs` file and names the replacing tool, so this
   is the rule the gate enforces rather than a preference; `Edit` stays for what roseline cannot
   reach — `using` directives, attributes, file-scoped namespaces, top-level statements
   (`docs/roseline-gate.md`). Hand the same rule to every per-task sub-agent's brief.
   - *Inline mode:* directly, per [`../_shared/tdd-loop.md`](../../../_shared/tdd-loop.md) — red before
     green, one slice at a time, refactoring left to Step 7.
   - *Subagent-per-task mode:* dispatch a subagent with the task block, Global Constraints, repo grain, the target repo's root `CONTEXT.md` (or that it has none), and the **path** to Step 3's `/tmp/issue-$ISSUE-notes.md` (a pointer — it reads them itself); have it implement to a green filtered test run and report a short diff summary.

   **The failing test crosses the seam the plan named for this task** — the preamble's
   `**Seams under test:**` line, and the seam each failing-test step names in the task block itself
   (`create-issue` Step 5 writes both). A test that instead *mocks* that seam, asserts a call count
   across it, or recomputes its expected value the way the code under test computes it is not the
   test the plan asked for: the first two assert the plumbing you wrote rather than the behaviour a
   caller depends on, and the third can never disagree with a bug. Write it at the seam, and if the
   named seam turns out to be the wrong place, say so in the report rather than quietly moving it —
   the substitution is a finding for Step 7's Spec axis. The doctrine, with the worked example in
   this tree, is [`../_shared/test-seams.md`](../../../_shared/test-seams.md).

2. **Verify green before you commit.** Run the task's test filter and confirm it passes — read the
   output, don't assume. A red bar means it isn't done; fix it or stop. Never commit over failing tests.

3. **Close the task in one call** — commit, tick, mirror, push, in that order, each through its
   guard (#499):
   ```bash
   "$GUARDS/finish-task.sh" --repo {owner}/{repo} --issue "$ISSUE" --task <N> --pr "$PR" \
     --worktree "$WORKTREE" --branch "$BRANCH" <commit-identity>
   ```
   It takes the commit message from the task's last step (`Commit: \`…\``; pass `-m` when the
   plan spells it otherwise), flips **only** `### Task <N>`'s `- [ ]` lines, writes the issue plan
   through `tick-plan.sh` (fail-closed, read back) and the PR's `### Plan` mirror through
   the tracker contract's `pr-edit-body`, then pushes through `guarded-push.sh`. Re-running it is safe: a stage
   already done says so and is skipped. `--comment-id <id>` when the plan lives in a comment.

   **When a stage fails, the exit code is that guard's own, and the line names the stage** — read
   it as you would the guard itself:
   - `commit:` exit **2** — HEAD is on the wrong branch, nothing was written; fix that first.
     Exit **3** — the commit exists somewhere else and the message names where.
   - `tick:` — `tick-plan.sh` refused or could not verify. `the PATCH … exceeded 60s and was
     bounded` is informational; `ALERT … re-run the tick` (exit 1) means **re-run finish-task
     unchanged** — it is idempotent. Never restore the plan from a copy: a write that was cut short
     may still arrive, and the restore would silently un-tick it (#135). Both `gh` calls run under
     `TICK_PLAN_PATCH_TIMEOUT` (default 60s); a tick that takes minutes is a bug, not a slow network.
   - `mirror:` — the PR body carries no `### Task <N>` block: resync the mirror (top of this step)
     and re-run.
   - `push:` exit **4** — the remote was **read** and **disagrees**: `… is NOT this HEAD` / `… has
     no '<branch>' to show for it` is the silent mis-push (#172); go and look at what the remote
     holds before pushing again. Exit **6** — verification **never ran** (`push is UNVERIFIED`):
     nothing disproves the push and nothing confirms it; fix what broke the listing, then
     `"$GUARDS/guarded-push.sh" -C "$WORKTREE" --verify-only "$BRANCH"`. Per-condition recovery:
     the Troubleshooting table in `references/github-mechanics.md`.

   The guards it composes are the same ones, callable one at a time when a stage needs a hand:
   `guarded-commit.sh -C "$WORKTREE" <commit-identity> "$BRANCH" -- -am "<message>"`,
   `tick-plan.sh --repo … --issue … --before … --after …` (never `jq | gh api` — that pipeline
   wiped two live issue bodies with exit 0, `references/github-mechanics.md` §4),
   `pr-edit-body --body-file`, `guarded-push.sh -C "$WORKTREE" "$BRANCH"`.

Continue until no task has an unchecked box. The issue's plan now reads all-`- [x]`.
