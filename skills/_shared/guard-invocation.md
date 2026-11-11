# When a guard at `$GUARDS` is refused

`$GUARDS` points at the kit's own `skills/implement-issue/scripts/` directory — deliberately, so
there is exactly one copy of `guarded-commit.sh`, `guarded-push.sh` and `guarded-merge.sh` rather
than a copy per consumer that drifts. When the kit runs as an **installed plugin**, that directory
is the plugin cache (`~/.claude/plugins/cache/<marketplace>/tagout/<version>/…`), which
sits outside the repo entirely — and therefore outside the worktree an `auto-dev` or
`implement-issue` worker is confined to. A host or sandbox that pins an agent to one worktree can
then refuse to invoke a script that lives outside it, at the exact moment a commit needs to go
through the guards rather than around them.

The same reachability question applies to `skills/merge-pr/scripts/guarded-pr-merge.sh` — a fourth
guard script, invoked by its literal path rather than through a `$GUARDS=` variable, but sitting in
the same plugin-cache-vs-worktree position as the other three. It is covered by the same fallback
below, with one difference: it sources nothing, so for this script copying the single file is the
whole of step 1 — there is no `_assert-branch.sh`-style sibling to remember.

**This does not apply to `make-worktree.sh`.** That call runs *before* any worktree exists, from the
main checkout, where `$GUARDS` resolving to the kit's own directory is not a problem — there is
nothing yet to be confined to. The fallback below is for the *later* calls —
`guarded-commit.sh`, `guarded-push.sh`, `guarded-merge.sh` — which all run **inside** the worktree
`make-worktree.sh` just created, where the same path can now be the thing that gets refused.

## The fallback

The host's refusal is about the **command text**, not only the path: it refuses what it cannot prove
stays inside the worktree, and it reads the literal string. So the shape of the call matters, and
there are three rungs, tried in order — **one attempt per rung** (#763).

1. **Call the guard by its absolute plugin path, with the worktree as cwd.** This is the first thing
   to do under worktree isolation, before any copy — the shape that worked in measured runs for
   `guarded-commit.sh`, `guarded-push.sh` and `guarded-merge.sh`. One plain command per call, the
   guard's own `-C "$WORKTREE"` left as it is: no `bash -c`, no pipe, no `cd … &&`, no heredoc around
   it, and no kit-invented scratch name or search string spelling the vcs word. A call that came
   back refused in a wrapped form is worth one plain retry, not three variations.
2. **Last resort, only if rung 1 was refused: copy the guards**, and `_assert-branch.sh` alongside
   them, into a scratch directory inside your **own** worktree whose name carries no vcs token —
   `"$WORKTREE/.kit-guards"`. `_assert-branch.sh` is not optional: `guarded-commit.sh`,
   `guarded-push.sh` and `guarded-merge.sh` all source it for the branch assertion itself, and a copy
   that omits it breaks silently rather than loudly. Create the directory in the same block as the
   copy:
   ```bash
   mkdir -p "$WORKTREE/.kit-guards"
   cp "$GUARDS/guarded-commit.sh" "$GUARDS/guarded-push.sh" "$GUARDS/guarded-merge.sh" \
      "$GUARDS/_assert-branch.sh" "$WORKTREE/.kit-guards/"
   ```
   **For `guarded-pr-merge.sh` specifically** — it is invoked by its literal path
   (`<kit>/skills/merge-pr/scripts/guarded-pr-merge.sh`), never through `$GUARDS`, so it is not in
   the `cp` above. Copy just that one file into the same directory (create it first, as above):
   ```bash
   mkdir -p "$WORKTREE/.kit-guards"
   cp <kit>/skills/merge-pr/scripts/guarded-pr-merge.sh "$WORKTREE/.kit-guards/"
   ```
   It sources nothing, so there is no `_assert-branch.sh`-style sibling to bring with it. Run the
   copies from there — same arguments, same `-C "$WORKTREE"`, same `$BRANCH`. Then **delete the
   scratch directory before finishing** — it must never reach the commit or the diff:
   ```bash
   rm -rf "$WORKTREE/.kit-guards"
   ```
   A worktree's ignore rules are a fact about the repository, not something to assume; deleting it
   before the final commit is what keeps it out regardless.
3. **Bounded exit.** If rung 1 and rung 2 were each refused, or a call does not return (a guard run
   from a copy has stayed pending for over an hour with no process behind it), stop: report
   **BLOCKED** with the verbatim refusal text and leave the PR as it stands. No further shapes, no
   open-ended retry, and a hands-off worker never waits on a call it cannot see progressing.

**Report that you left rung 1.** Copying the guards, or exiting BLOCKED, is a deviation from the
documented path, and it belongs in the run's structured report so a supervisor's recap can see it —
a deviation that surfaces nowhere is indistinguishable from one that never happened.

## How a kit script is told which repository

`-R <[host/]owner/repo>`, leading the arguments. `guarded-pr-merge.sh`, `base-run-verdict.sh`,
`parent-decision-note.sh`, `tracker.sh` (where `--repo` is the same thing) and every `tracker.sh`
verb take it that way. Giving the same script a repository twice, by two spellings that disagree, is
refused rather than resolved to one of them.

Everything `git` or `gh` itself would take goes **after `--`** — `-m`, `-F`, `--author`,
`origin/main`, `--squash`. A guard's own options come before it. A wrong shape is refused, and the
refusal prints the script's usage line under it, so the correction is in the same turn (#668).

**Never fall back to a bare — or `GIT_GATE=off`-prefixed — `git commit`, `git push`,
`git merge` or a raw `gh pr merge`.** That is precisely the failure the guards exist to prevent
(#26, #280, #41, #512) — a refused guard is a reason to relocate it, not a reason to bypass it.
