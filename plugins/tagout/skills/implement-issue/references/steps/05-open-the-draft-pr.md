## Step 5 — Open the draft PR

**Skip this step entirely if Step 4's issue-scoped fallback resumed onto an existing PR** — that PR
already carries a scaffold commit (or real work), and opening another one is exactly the failure this
guard exists to prevent. Go straight to Step 6.

Otherwise: the PR should be visible as a **draft before** the implementation loop. A PR needs the
branch ahead of `main`, so land an empty scaffold commit, push, then open it through
[`../_shared/open-pr.md`](../../../_shared/open-pr.md) — the title rules, the gate dry-run and
`gh pr create` live there, never a copy here.

Every commit and push **in Steps 5–9** goes through the guards in `scripts/` — never a bare
`git commit` or `git push`. They take `$BRANCH` explicitly, refuse (exit 2) when HEAD is anything else
or detached, and prove afterwards that the commit landed on that branch (exit 3 if not) and that the
remote really carries this HEAD (exit 4 if it does not — or if the guard could not find out; Step 6
says how to tell those apart). `-c user.email=… -c user.name="…"` is the profile's
*Commit identity*; it goes **before** `$BRANCH`, because those are options to `git`, not to
`git commit`.

Step 8 is no exception: it delegates to
[`../_shared/sync-with-main.md`](../../../_shared/sync-with-main.md), whose merge, completing commit and
push all go through the same three guards (#41) — `guarded-merge.sh` included, since a merge commit
is the largest single write in this flow. That file reads `$BRANCH`, `$WORKTREE` and `$GUARDS`, which
is why Step 4 records them.

```bash
"$GUARDS/guarded-commit.sh" -C "$WORKTREE" <commit-identity> "$BRANCH" \
  -- --allow-empty -m "chore(#$ISSUE): scaffold draft PR for <title>"
"$GUARDS/guarded-push.sh" -C "$WORKTREE" "$BRANCH" -- -u origin "$BRANCH"

DRAFT=1
TITLE_PATHS=<the plan's **Files:** paths, parsed in Step 2>   # no real diff yet: the scaffold changes no file
BODY_FILE=/tmp/issue-$ISSUE-pr-body.md
# Quoted delimiter: plan task names carry backticks, which an unquoted heredoc would execute.
{ printf 'Implements #%s.\n\nCloses #%s.\n\n' "$ISSUE" "$ISSUE"; cat <<'BODY'; } > "$BODY_FILE"
Executing the implementation plan task-by-task; the checklist below — and the plan on the issue — are
ticked as each task lands. Opened as a draft — will be marked ready after the final task and a
code-review pass.

### Plan
- [ ] Task 1: <name>
- [ ] Task 2: <name>
BODY
```

The `### Plan` list carries one `- [ ] Task N: <name>` line per `### Task N` heading in the plan. Then
follow [`../_shared/open-pr.md`](../../../_shared/open-pr.md) with those three names and `$BRANCH`,
`$ISSUE` from Step 4.

Capture the PR URL/number from its readback. (If it stops on a PR that already exists, reuse it.) The PR's `### Plan` list
is a task-level mirror (coarser than the issue's per-step boxes) for at-a-glance reviewer progress; Step
6 keeps it in lock-step. The issue plan stays the **canonical** source of truth — it's what a resumed
run reads.
