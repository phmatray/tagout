## Step 1 — Preconditions & resolve the PR

**Follow the shared preconditions reference** at [`../_shared/preconditions.md`](../../../_shared/preconditions.md)
to load the repo profile, verify authentication, and prepare the commit identity shorthand.

Throughout this skill, **`<commit-identity>`** stands for the author line from the profile's
*Commit identity* — `-c user.email=<email> -c user.name="<name>"`. Substitute it in every
commit/merge command. In the guarded calls of Step 4 it goes **before** the branch name
(`guarded-commit.sh -C "$WORKTREE" <commit-identity> "$BRANCH" -- …`), which is where the script
forwards it to `git` itself; after `--` it would reach the subcommand, whose own `-c` means something
else entirely.

Normalize the PR identifier to a number (bare number, issue/PR URL, and `gh` link all reduce to the
first run of digits — see `references/merge-mechanics.md` §1), then confirm it's real and open and
capture what drives the rest of the run:

```bash
gh pr view "$PR" --json number,title,state,isDraft,mergeable,mergeStateStatus,reviewDecision,headRefName,baseRefName,url \
  --jq '{number,title,state,isDraft,mergeable,mergeStateStatus,reviewDecision,head:.headRefName,base:.baseRefName,url}'
```

- `state != OPEN` → if `MERGED`, skip to Step 5b and then Steps 6–7 (follow-ups + cleanup). There is no `$MERGE_OUT` on this path, so take the sha from `gh pr view "$PR" --json mergeCommit --jq .mergeCommit.oid`; if that is empty, or the run has aged out of the check-runs history, the answer is `base unverified at <sha> — resumed after the merge`. Report that rather than omitting the line: Step 8 requires one, and `auto-dev` reads it off the report line as `BASE:`, where a blank is indistinguishable from the silence Step 5b exists to end. If `CLOSED` (not merged), stop and ask — merging a deliberately closed PR is not a safe default.
- `isDraft == true` → the user asked to *merge* it, so the flag is almost always stale. Flip it through the guard, never bare: `<kit>/skills/implement-issue/scripts/guarded-ready.sh -C <repo> --branch <headRefName> "$PR"`. Exit 0 → flipped, continue. Exit 1 → the draft carries no recorded review: note *"draft carries no recorded review — reviewing before the flip"*, write `NEEDS_REVIEW=1` into the run's notes (not a shell variable — fresh shells) and continue to Step 2. Exit 2 → a usage error in the call: fix the call, never fall back to a bare ready-flip. (If genuinely unfinished, the CI/corrections loop surfaces it.)
- Capture **`headRefName`** (branch) and **`baseRefName`** (normally `main`) — Steps 2, 4, 7 key off the branch name.
