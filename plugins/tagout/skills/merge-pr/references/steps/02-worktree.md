## Step 2 — Locate (or create) the branch's worktree

Corrections (Step 4) edit code, so they must land in a checkout of the PR's **head branch** — not
whatever worktree you're in now. Find it:

```bash
git worktree list --porcelain        # match the entry whose branch == headRefName
```

- **A worktree for the branch exists** (usual case — `implement-issue` left one): use it. Pull first: `git -C <path> pull --ff-only`.
- **No local worktree/branch** (PR built elsewhere, or already cleaned): create one **only if** Step 4 needs corrections or Step 1 noted `NEEDS_REVIEW=1` (an unrecorded draft needs the review run in a worktree). If the PR is already `CLEAN` with green CI and not a `NEEDS_REVIEW` draft, merge without checking out locally. When needed, create an isolated worktree tracking the remote branch with `git worktree add <path> <branch>` (reference §2). Remember the path; Step 7 removes it.

**As soon as you know a worktree will be involved — whether you found one above or will create one
here or in Step 4 — prove its home is ignored, before touching it.** This repo is not the kit's, and
`.claude/worktrees/` is the kit's convention, not a fact about someone else's checkout. Run the check
from [`../_shared/worktree-ignore-check.md`](../../../_shared/worktree-ignore-check.md); it takes no
worktree path, so the same call serves the found worktree and the one not yet created.

`0` go ahead · `1` a home is **not** ignored, so stop before pulling into it or creating one · `2`
ignored but over-broad, so **do** go ahead and mention the profile cost · `3`/`127` no verdict, which
is not a pass. Full verdict table, the bare-repository case, why `2` is not a stop, and the
never-edit-their-`.gitignore` rule are all in that one file. Skipping this is how #43 reproduces in a
customer repo — silently, as a single gitlink rather than a diff anyone spots.

⚠️ **Reuse is the usual case here, so the check cannot hang off creation** (#86) — but it still runs
*before* the worktree is touched, not after. The bullet above calls an existing worktree the normal
outcome, and a guard that only fired on `git worktree add` would skip precisely those repos; one that
fired after the `pull --ff-only` below would be writing into the unignored home it was about to
refuse. **No worktree, no check** stays true — a PR that is already `CLEAN` merges without a local
checkout and has nothing to verify.

Don't run corrections from the current session's worktree if it isn't the PR's branch — you'd edit the
wrong checkout (a known footgun here). Use `git -C <path>` rather than `cd` (a `cd` in a compound
command gets reset between calls). Raw `git fetch`/`git push` may be sandbox-blocked even though `gh`
works (a `port 443` timeout) — re-run just those with the sandbox disabled; local git needs no network.
See `references/merge-mechanics.md` §9.

**The moment a worktree is in hand — here, or later in Step 4 if this step deferred creating one —**
record the four names Step 4's guarded writes need. Same convention `implement-issue` Step 4 defines,
so the shared main-sync procedure reads the same variables from either skill:

```bash
BRANCH=<headRefName from Step 1>
WORKTREE=<absolute path of that branch's worktree>
GUARDS=<the kit's skills/implement-issue/scripts directory>
DECIDE=<the kit's scripts/decide.sh>   # runs a registered decision by id — Steps 3 and 4 call it
BASE=<baseRefName from Step 1>     # NOT assumed to be main — plenty of repos default to dev
```

The ignore check above is a **precondition of this block**, not part of it: it has already run by the
time `$WORKTREE` has a value, which is why its recipe never asks for one.

If a guard call at `$GUARDS` is refused (an agent confined to this worktree, `$GUARDS` resolving
outside it), see the fallback in [`../_shared/guard-invocation.md`](../../../_shared/guard-invocation.md).

Record them at whichever point the worktree appears: this step skips creation when the PR looks
`CLEAN`, and Step 4 then creates one only if corrections turn out to be needed. Reaching a guarded
command with these unset is not a soft failure — `"$GUARDS/guarded-commit.sh"` expands to
`/guarded-commit.sh`, i.e. "No such file or directory".

Every write in Step 4 passes `"$BRANCH"` and `-C "$WORKTREE"` **explicitly**. "Edited the wrong
checkout" is exactly the failure this skill already warns about; a guard that derived the branch from
`HEAD` would read the very value under suspicion and agree with itself either way.
