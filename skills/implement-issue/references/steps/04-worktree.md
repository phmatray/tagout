## Step 4 — Create **this issue's own** worktree

**This issue gets a worktree of its own, always.** Not "a worktree" — *this* one, created or reused
through `scripts/make-worktree.sh` below (#280), off the repository's real default branch — the
remote's, as it is right now, never a hardcoded or stale local `main` (#678: `BASE=` in the
receipt names what it resolved). Name the branch for the issue, e.g.
`feat/<issue>-<short-slug>` (slug from the issue title).

⛔ **Never implement from the checkout you were launched in**, even when that checkout is already a
worktree. That skill's Step 0 says "already in a linked worktree → skip creation", and a run launched
inside someone else's worktree reads it as permission to work in place — which is precisely the
configuration that produced the incident behind this rule: four agents sharing one checkout, a
concurrent `git checkout` moving HEAD, and a commit landing in another agent's PR with every command
exiting 0. The question is not *am I in a worktree*, it is **am I in the worktree this issue owns**.
If the answer is no, make one and move into it.

So the resume test matches **this issue's own branch**, never the ambient checkout. Derive `$BRANCH`
with the `SLUG` recipe in `references/github-mechanics.md` §5 (don't hand-write it — a literal
`<short-slug>` inside quotes stays literal, and every later guard call would then quote a branch that
does not exist), then:

```bash
# Exact match on the branch column. A bare `grep -F "$BRANCH"` matches substrings and the path
# column too, so `feat/26-guard` would "resume" into feat/26-guarded-git-writes' worktree —
# the wrong-checkout failure this step exists to prevent.
git worktree list --porcelain | grep -Fxq "branch refs/heads/$BRANCH"
```

**Before you either reuse what that finds or create one, prove the worktree's home is ignored** — the
worktree directory is the kit's convention, not a fact about the repository you are pointed at. Run
the check **now**, while both outcomes are still ahead of you: it takes no worktree path, so the one
call covers the branch that creates and the branch that inherits (#86).

⛔ **This step is one call, never a re-spelling — of the check OR of the write.** A phase-1 worker
reached this exact point, composed its own two-line worktree-ignore check instead of calling the
kit's, got a false "NOT ignored" verdict from `git check-ignore -q "$LOCATION"` spelled **without the
trailing slash** on a directory that did not exist yet, and "fixed" it with a `git commit` in the
**main checkout** — landing `chore: ignore .worktrees/` on the user's own local, unpushed branch
(`e0ad515`, 2026-08-27, `docs/desktop-launcher`; #280). Both are named so neither can recur unnoticed:
a hand-written `git check-ignore` in place of the shared check, and **any** `git commit` in the main
checkout at this step, for any reason — there is nothing at this step a commit is ever the answer to.
Call `scripts/make-worktree.sh` (below); do not compose your own version of what it does.

Do not defer the ignore proof until `$WORKTREE` is bound and then derive its argument from that
variable — the recipe is deliberately shaped to prevent it. `git -C "$WORKTREE" rev-parse
--show-toplevel` names the linked worktree rather than the checkout the hazard lives in (it fails
**open**), and waiting until the worktree exists means creating one in an unignored home before
refusing, which leaves it on disk. The recipe, the bare-repository case, the verdicts, the reason `2`
is not a stop, and the rule against editing someone's `.gitignore` unasked all live in
[`../_shared/worktree-ignore-check.md`](../../../_shared/worktree-ignore-check.md) — read it there for the
rationale and the full verdict table, never a copy here, which is how the four copies of this table
drifted apart in the first place (#71). `scripts/make-worktree.sh` is that recipe, made executable
(#280): `0`/`2` go ahead · `1` a home is **not** ignored, so stop — before the worktree and before the
scaffold commit · `3`/`126`/`127` no verdict was reached, which is not a pass.

### If the branch-name check found nothing: check GitHub for the issue, not just the branch

The branch-name check only catches a **matching name**, and a matching name is not guaranteed. It
missed the incident this guard exists for (#214): two sessions scaffolded #195 under **different**
branch names (`fix/195-ci-wiring-check-proves-a-suite-is-invoke` and
`fix/195-ci-wiring-executable-mode`) because the second one never ran the `SLUG` recipe below at all —
it composed its own branch name from its own reading of the issue instead. A worker's own judgment
routinely substitutes a hand-picked, paraphrased branch name for the prescribed one-liner, so two
independent runs against the same issue can diverge in branch name even though the recipe itself is
deterministic. Branch-name matching cannot catch that; asking GitHub whether this **issue** already
has an open PR can — so run this fallback whenever the branch-name check just found nothing, before
creating any worktree.

**Run §1 of [`../_shared/open-pr.md`](../../../_shared/open-pr.md#1-look-for-an-existing-pr) exactly,
and read its 0/1/2+ decision table there** — not a copy here, which is how the worktree-ignore table
drifted apart (#71), and this fallback's own first draft duplicated the same table once already,
immediately going stale when the recipe grew a tie-break rule and an empty-fetch guard. That recipe
queries `gh pr list` for open PRs whose body actually *closes* this issue (GitHub's own closing-keyword
set, not a bare mention) and writes the result to `/tmp/issue-$ISSUE-closers.json`;
`tests/pr-existence-guard/test.sh` proves that program's behavior against fixtures shaped exactly like
#195. The short version: `0` → nothing to resume onto, proceed to "Create or reuse, through the guard"
below; `1` → resume onto it (`references/github-mechanics.md` §5 says how) and skip Step 5's scaffold
entirely; `2`+ → the exact shape of the #195 incident, resume onto the most-implemented one
(`_shared/open-pr.md` has the tie-break) and **name the duplicate in the Step 10 recap** — this is not
a stop-and-ask case under the Autonomy contract, but a standing duplicate PR is worth a human's
attention regardless.

### Create or reuse, through the guard

Whether the branch-name check matched or the fallback above resolved to nothing new to create, hand
the rest to the guard — it is the single call this step now is (#280):

```bash
GUARDS=<this skill's own scripts/ directory>   # skills/implement-issue/scripts, resolved from the
                                                # MAIN checkout — no worktree exists yet to have its own copy
"$GUARDS/make-worktree.sh" -C <anywhere-in-the-repo> "$BRANCH"
```

If a *later* call at this same `$GUARDS` path is refused (Steps 5–9, once you're inside the
worktree — not this `make-worktree.sh` call, which runs before the worktree exists), see the
fallback in [`_shared/guard-invocation.md`](../../../_shared/guard-invocation.md).

`0` → stdout carries, in this order, `WORKTREE=<absolute path>` and `BRANCH=<branch>`; read them and
record the two names every later step needs. `2` → REFUSED, printed on stderr — most often the
ignore-check's `1` (a worktree home is not ignored: the message names the exact `.gitignore` line to
add and stops there, **never** writing it — see the ⛔ clause above) or its `3`/`126`/`127` (no
verdict was reached). Either way: **stop here, before Step 5's scaffold** — this is the Autonomy
contract's genuine blocker, not a default to pick past.

**If the fallback above resumed onto an existing PR whose branch has no local worktree yet**,
`make-worktree.sh` does not cover that case — it only creates fresh off the resolved default branch or reuses an exact
branch-name match. Fetch and check it out by hand instead (existing local branch: `git worktree add`
from it; remote-only: `git worktree add -b "$BRANCH" "origin/$BRANCH"`), into a home the same call
above has already proven ignored.

**If the branch is checked out in another worktree you may not use** — `git worktree list
--porcelain` shows `branch refs/heads/$BRANCH` under a path that is not your own toplevel, and you
are confined to your own tree (an `auto-dev` worker under `isolation: "worktree"`) — none of the
cases above applies: `git switch` refuses a branch another tree holds, and reaching into that tree
is the one thing your confinement forbids. Do not work around it with `--ignore-other-worktrees` or
`--force`; stop before editing and report the `branch-held guard:` signature that
[`commands/auto-dev-worker.md`](../../../../commands/auto-dev-worker.md) spells out — the supervisor
releases the branch with `release-branch.sh` and re-dispatches (#510). An unconfined run can still
`-C` into that tree, as the reuse case in `references/github-mechanics.md` §5 says.

Carry `$BRANCH` forward — Steps 5–9 pass it to the guards **explicitly**, because a guard
that read the branch from `HEAD` would be reading the very value it exists to check, and would agree
with itself no matter which branch was checked out. Pass `-C "$WORKTREE"` just as explicitly: the
guards default to the current directory, which is the ambient checkout this step just told you not
to trust.

Isolation makes the collision rare; it does not make it impossible — a worktree can still be
re-pointed, and any sub-skill that mutates the working tree inherits the hazard (in the same session,
`code-review` ran `git checkout <ref> -- .` in a shared checkout and destroyed an uncommitted delta).
That residue is what the guards below are for.
