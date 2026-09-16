## Step 3 — Open the PR

**Push through the guard**, never a bare push. It asserts the branch, then reads the remote back
(exit codes: `skills/implement-issue/references/steps/05-open-the-draft-pr.md`). If the call to the
guard is itself refused, see [`../_shared/guard-invocation.md`](../../../_shared/guard-invocation.md):

```bash
GUARDS=<kit>/skills/implement-issue/scripts
WORKTREE=$(git rev-parse --show-toplevel)
"$GUARDS/guarded-push.sh" -C "$WORKTREE" "$BRANCH" -- -u origin "$BRANCH"
```

**Ready or draft:**

- `--draft` in the request → `DRAFT=1`. The *Full test* does not run.
- Otherwise run the profile's *Full test* on this HEAD, from `$WORKTREE`, with its output going to
  `/tmp/create-pr-<short-sha>-full-test.out`. Green → `DRAFT=0`. Red → `DRAFT=1`: **keep that
  file**, because Step 4 quotes its failing tail. A red bar opens a draft, never a ready PR.

**The body** goes in `BODY_FILE=/tmp/create-pr-<short-sha>-body.md`:

- one bullet per commit in `git log --format='- %s' "origin/$DEFAULT..HEAD"`;
- `Closes #$ISSUE.` when `$ISSUE` is set, and no such line when it is empty;
- on a red *Full test*, one line saying the draft is red and which command failed.

Then **follow [`../_shared/open-pr.md`](../../../_shared/open-pr.md)** with these names:

```bash
BASE=$DEFAULT
TITLE_PATHS=$(git diff --name-only "origin/$DEFAULT...HEAD")
```

`$BRANCH`, `$ISSUE`, `$DRAFT` and `$BODY_FILE` are set above. When `$ISSUE` is set, the title's type
label comes from `/tmp/create-pr-issue-$ISSUE.json`.

- The recipe's §1 finds a PR already open → open nothing. Hand that PR to Step 4.
- Otherwise it hands back `number` and `url` from its readback. Carry them to Step 4.
