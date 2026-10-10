# Before using a worktree: prove its home is ignored

Shared by `implement-issue` (Step 4) and `merge-pr` (Steps 2 and 4). One home for the verdicts,
because the first draft of this check spelled them out in four places and they had already drifted
apart by the time anyone read two of them.

## When: before you **use** a worktree — created this run or inherited

Run the check **once, before the create-or-reuse decision**: before `git worktree add` on the create
path, and before the first read or write in an inherited worktree on the reuse path. One call, both
paths (#86).

What changed in #86 is the word *only*. The check was attached to creation, so it verified exactly the
repositories where this particular run happened to create something — and reuse is the steady state,
not the edge case: `implement-issue` is resume-safe by contract, so re-runs adopt the worktree an
earlier run left, and `merge-pr` calls an existing worktree its "usual case". A worktree made by an
earlier run, a bare `git worktree add`, or a harness therefore sat in an unverified home for the rest
of its life.

⛔ **Moving it must not mean running it later.** The precondition is worth having only if a refusal
still prevents something. Deriving the check's argument from `$WORKTREE` looks natural — that is the
variable in hand — but it forces the worktree to exist first, which on the create path means planting
a full checkout in an unignored home and *then* refusing, leaving it on disk with nothing prescribed
to clean it up. The recipe below deliberately takes no worktree path, so the same call works before
one exists.

⚠️ **The inherited worktree is the case with something to find.** Its home was ignored when it was
created, or nobody looked; either way the rule can have been dropped, broadened, or negated since.
Stop **before** the first write — a refusal that arrives after the commit is a report, not a guard.

The redundant re-check on a worktree this run just created costs one `worktree list` plus the guard's
own handful of `git` invocations (it runs up to eight — two homes × `check-ignore -q`, `check-ignore
-v` and `ls-files`, plus `rev-parse` and the profile-path probe). Still cheaper than the second prose
reminder the alternative needs in every skill.

## Why

`.claude/worktrees/` is **this kit's convention, not a fact about the repository you are pointed at**.
A worktree is a full checkout, so where the rule is missing the next `git add -A` stages it — and the
measured shape (#43, git 2.50.1) is a single gitlink:

```
160000 <sha> 0  .claude/worktrees/<branch>
```

not a large diff anyone notices in review, and pointing at a commit no clone can fetch (there is no
submodule URL and no remote). `git` prints `warning: adding embedded git repository`, and on a busy
console that warning is the only thing between this and a silent commit.

⚠️ **Whose `git add -A`?** Not this kit's, as of #68: `sync-with-main.md` now stages only the paths the
merge actually conflicted on, and no skill here runs `add -A` any more. That removes the caller this
check was originally written against, and it does **not** remove the reason for the check — it changes
who the check is for. What remains is everything the kit does not govern: a human, another agent, or a
different tool typing `git add -A` in a repository the kit just planted a worktree in. Leaving an
unignored full checkout lying in someone's tree is the hazard; the kit merely stopped being the one
most likely to trip over it.

The precondition — *"MUST verify directory is ignored before creating worktree"* — is stated by the
worktree skill this kit once delegated creation to (obra/superpowers `using-git-worktrees`, MIT);
`implement-issue` Step 4 now creates through `scripts/make-worktree.sh` (#280, #324). This is that
verification, made mechanical, and #86 **widened** it rather than moving it off creation: still before the worktree
is made, and now also before one that already exists is used.

## The check

Run it against the **main checkout** — the repository the worktree home lives in, and the one whose
`git add -A` can stage it. `<kit>/scripts/main-worktree.sh` is the one home for finding that
directory (#125) — every caller resolves it through there rather than re-deriving it:

```bash
# Ask from anywhere in the repository — the main checkout, or a linked worktree the session happens
# to be sitting in. main-worktree.sh always resolves the MAIN checkout's root, whichever one you
# asked from, and it needs no worktree path of its own: it works before the one you are about to
# create exists.
REPO_ROOT=$(<kit>/scripts/main-worktree.sh -C <anywhere-in-the-repo>)

# A BARE repository has no main working tree — main-worktree.sh prints nothing for one. `git add -A`
# cannot run there, so no worktree home is reachable, and `check-ignore` refuses ("must be run in a
# work tree") — which the guard would otherwise report as a false "NOT ignored". Nothing to verify.
[ -n "$REPO_ROOT" ] && <kit>/scripts/worktrees-ignored.sh -C "$REPO_ROOT"
```

⚠️ **Do not derive it from the worktree you are about to use.** `git -C "$WORKTREE" rev-parse
--show-toplevel` answers with the *linked worktree*, not the checkout the hazard is in — a linked
worktree is its own toplevel. That fails **open**, measured (`tests/worktrees-ignored/test.sh`, case
22): where the ignore rule was committed and later dropped from the main working tree, the guard says
`1` at the main checkout — correctly, `git add -A` there really does stage the `160000` gitlink — and
`0` when asked at the reused worktree, whose checked-out `.gitignore` still carries the rule. Same
guard, same repo, opposite verdicts; only the main-checkout answer is about the directory that can be
committed. It is also the reason `main-worktree.sh` takes no `$WORKTREE`: the argument that would
tempt you is the wrong one. `tests/main-worktree/test.sh` pins the same layouts directly against the
script (linked worktree, bare + linked worktrees, a path containing a space) — `sed -n
'1s/^worktree //p'` inside it, and not `awk '{print $2}'`, is what keeps a spaced path intact.

`<kit>` is the kit root — the directory holding `skills/` and `scripts/` — resolved when the skill
loads, the same placeholder `migrate-legacy` and `review-followups` use for `<kit>/scripts/…`. Do **not**
write it as a shell variable: an unset `$KIT` expands to `/scripts/main-worktree.sh`, i.e. exit
`127`, and a caller that treats every non-zero as "stop" then refuses to use any worktree at all.
`main-worktree.sh` can legitimately be absent on the skills-only adoption path documented below —
that is a missing *tool*, not a failed *verdict*.

**The root matters.** `.claude/worktrees/` contains a slash, so git anchors it and resolves it relative
to the directory it is asked about. Point the guard at a subdirectory and a correctly configured repo
answers "NOT ignored" — and point it at a *linked worktree*, which is the reuse-time reflex, and the
same anchoring quietly answers the wrong question (above).

## The verdicts

Unchanged by #86 — only the moment they are asked for moved. "Use" below means create **or** reuse.

| Exit | Meaning | What to do |
|---:|---|---|
| `0` | both worktree homes are ignored | Use the worktree. |
| `1` | **a worktree home is NOT ignored** | Do not use it — and on the reuse path, stop before the first guarded write. Surface the one-line `.gitignore` addition the guard names, and let the owner take it. |
| `2` | homes are ignored, but the rule is broad enough to hide `.claude/skills/repo-profile.md` | **Use the worktree — there is no worktree hazard here.** Mention that this repo cannot carry a committed profile until the rule is narrowed. |
| `3` | usage error, or not a git repository | No verdict was reached. That is not a pass — fix the invocation. |
| `126`/`127` | the guard is missing or not executable | Same: no verdict. Check `<kit>` resolved. |

⚠️ **`2` is a different finding, not a worse one.** Collapsing this to "anything non-zero → stop" is
the tempting shortcut and it is wrong: a repo whose `.gitignore` holds `.claude/` and `.worktrees/`
has *both* homes covered and zero #43 risk, yet exits `2`. Refusing it would deny service over a
condition unrelated to the hazard being guarded.

## If the kit's `scripts/` is not there

The kit supports a skills-only adoption path ("drop the four skills into a new repo"), and
both the guard and `main-worktree.sh` live at the kit root, so either — or both — can legitimately be
absent. That is a missing *tool*, not a failed *verdict* — don't refuse the worktree over it. Derive
the main checkout's root by hand instead, with the same recipe `main-worktree.sh` wraps (never from
`$WORKTREE` — see the warning above), then check both homes against it:

```bash
WT_LIST=$(git -C <anywhere-in-the-repo> worktree list --porcelain)
REPO_ROOT=$(printf '%s\n' "$WT_LIST" | sed -n '1s/^worktree //p')
printf '%s\n' "$WT_LIST" | sed -n '2p' | grep -qx bare && REPO_ROOT=''   # bare: nothing to check

[ -n "$REPO_ROOT" ] && git -C "$REPO_ROOT" check-ignore -q .claude/worktrees/ \
                    && git -C "$REPO_ROOT" check-ignore -q .worktrees/
```

The trailing slashes and `-q` are both load-bearing: a directory-only pattern does not match a
non-existent path spelled without the slash, and `-v` exits `0` merely because *some* pattern matched
— including a negation, which means the path is **not** ignored.

## Never edit the repository's `.gitignore` unasked

On `1`, propose the line; do not add it yourself. It is someone else's repository, the change belongs
in their history under their review, and an agent quietly rewriting ignore rules to unblock itself is
a worse failure than the one being prevented. With their go-ahead, add it and re-run.

## What a `0` does and does not prove

`git check-ignore` is satisfied by `.git/info/exclude` and by `core.excludesFile`, both **machine-local**.
The path really is ignored for whoever runs the guard — so the immediate hazard is covered and `0` is
correct — but the repository carries no such rule, and every teammate's and CI's `git add -A` still
stages the worktree. The guard prints a `note:` naming that case. Do not promote a `0` carrying such a
note into a durable claim about the repo (`init` records exactly that, so it repeats the
note rather than the verdict alone).

## Consumers

- `skills/implement-issue/SKILL.md` — Step 4 proves the worktree home is ignored before creating or reusing one
- `skills/merge-pr/SKILL.md` — proves the home is ignored before creating a worktree (Step 2) and before reusing one already on disk (Step 4)
- `skills/merge-pr/references/merge-mechanics.md` — states the exact check merge-pr's Steps 2 and 4 are followed through
- `skills/_shared/preconditions.md` — cites this file as sharing the same `<kit>` root placeholder convention
- `skills/implement-issue/references/steps/04-worktree.md` — Step 4 of implement-issue, split out of its SKILL.md for progressive disclosure (#499)
- `skills/merge-pr/references/steps/02-worktree.md` — Step 2 of merge-pr, split out of its SKILL.md for progressive disclosure (#499)
- `skills/merge-pr/references/steps/04-corrections-loop.md` — Step 4 of merge-pr, split out of its SKILL.md for progressive disclosure (#499)
