## Step 5 — Merge (squash)

Only once CI is green **and** `mergeStateStatus == CLEAN`. The profile's *Integration style* sets how to
land; for squash-merge (the `(#NNN)` commits on `main`):

```bash
<kit>/skills/merge-pr/scripts/guarded-pr-merge.sh "$PR" \
  -- --squash --delete-branch --subject "<PR title — already ends in (#issue)> (#$PR)"
  # --subject is optional; omit it (drop the whole -- line down to --delete-branch) to accept the host's default
```

If that call to `guarded-pr-merge.sh` is refused (an agent confined to its worktree, the path
resolving outside it), see the fallback in
[`../../../_shared/guard-invocation.md`](../../../_shared/guard-invocation.md).

`<kit>` is the kit root (the placeholder `references/merge-mechanics.md` defines). When the plugin's
hooks run, it is printed at session start as `Kit root:` and spelled out in every write-gate denial
that names a guard; either way, a guard you cannot find is a reason to resolve `<kit>`, never to run
the merge yourself (`gh pr merge`, or `tracker.sh pr-merge` bare).

The guard merges through `"<kit>/scripts/tracker.sh" pr-merge` and reads the outcome back through
`pr-view` (#752), so the same call lands a PR on GitHub, a merge request on GitLab and a pull request
on Azure DevOps. It accepts only `--squash`, `--delete-branch`, `--subject <s>` and `--body-file <f>`
after `--`; anything else (`--admin`, `--auto`, …) is exit 64 with nothing sent. On a landed merge it
prints `MERGED <sha>`, the sha taken from `pr-view`'s `mergeSha` — keep it as `$MERGE_SHA` for Steps
5b and 6.

**Prefer omitting `--subject`.** `implement-issue` titled the PR `… (#issue)`, and GitHub's default squash
subject is that title with `(#PR)` appended — giving the canonical `… (#issue) (#PR)` shape
automatically. If you override it, keep the `(#issue)` or you drop the link to the originating issue.

### The exit code doesn't decide — GitHub's state does

`gh pr merge` does **two unrelated things**: it merges the PR **on GitHub**, then tidies up **locally**
(check the base branch out, delete the merged branch). One exit code covers both, so it can never say
which half failed — and the local half fails on this kit's *normal* layout, not an exotic one.
`implement-issue` gives every issue its own worktree, so `/merge-pr` is usually run from one; gh then
switches to the base branch, the primary checkout already holds it, and git refuses:

```
$ gh pr merge 176 --squash --delete-branch
failed to run git: fatal: 'main' is already used by worktree at '<path>/tagout'
```

That merge **landed** — only gh's post-merge `git checkout` failed. Run from the primary checkout
instead and you get the *other* message, `failed to delete local branch … used by worktree` (§9's
long-standing row), because gh only needs to switch branches when you are sitting on the head branch.
Two messages, one rule: **the merge call's exit status is advisory.** Its stderr is worth reporting;
it concludes nothing. `guarded-pr-merge.sh` is the one home for that decision (#184) — it runs the
merge, reads the PR's `state` back itself, and exits distinctly per outcome instead of handing you the
raw exit code:

| `guarded-pr-merge.sh` exit | what it means | what to do |
|---|---|---|
| `0` MERGED | the merge landed, whatever `gh pr merge`'s own exit code said | continue to **Step 6**. If that exit code was non-zero, that was local cleanup gh couldn't finish — Step 7 does it, so report it there, not as a failed merge |
| `1` QUEUED | still `OPEN`, but the merge call itself exited 0 — a successful merge-queue enqueue, not a rejection | let it land and re-read later; do not retry the merge |
| `2` REJECTED | still `OPEN` and the merge call exited non-zero — a real rejection | do **not** reach for `--admin`; surface it (the script prints the merge call's stderr) and stop |
| `3` CLOSED | the PR was closed without merging while this ran | Step 1's rule applies — stop and ask. Merging a deliberately closed PR is not a safe default |
| `4` UNCONFIRMED | the state readback itself did not answer after a few attempts | inconclusive — it says neither merged nor rejected. **Stop and report the merge as unconfirmed.** Do *not* fall through into Step 7 — its teardown is destructive and assumes the merge landed. Re-running the skill later is safe: Step 1 routes an already-`MERGED` PR straight on to Steps 6-7 |

Full exit-code contract and the merge-queue disambiguation are in the script's own header comment —
read it there, don't mirror it here; a second copy is exactly what #184 removed.

**Don't corroborate with the remote branch.** Whether `--delete-branch` reached the remote side before
the local step failed is exactly what the exit code won't tell you — and on a repo with GitHub's own
`delete_branch_on_merge` enabled (this one has it), the branch disappears either way. A missing remote
branch proves nothing about the merge, and a surviving one disproves nothing. `state` — read by the
script — is the only signal that answers the question.

Local cleanup is Step 7's either way (gh can't delete a branch checked out in a worktree; its **Case
B** is this same collision one step later). Take the `|| git switch --detach` fallback from
`references/merge-mechanics.md` §8 when you get there — the obvious "switch back to `main`" walks
straight into the collision that got you here. §9 of that reference carries the row keyed on the
literal message.

### Multi-issue PRs: keep the changelog honest

On a repo with release automation (e.g. `release-please`), the version bump and CHANGELOG entries
derive from **Conventional Commits on `main`**. A squash-merge collapses the whole PR into a single
commit, so a PR that closes several issues yields exactly one release-notes line and one bump —
under-reporting the work.

When squash-merging a PR that closes **more than one issue**, write the squash-commit **body** with
one Conventional Commit line per distinct change, e.g.:

    fix(export): use invariant culture in CSV number formatting (#91)

    feat(export): stream large report downloads (#58, #77)
    feat(export): add XLSX export alongside CSV (#90)

Write that body to a file and pass it through the guard — never inline, and never piped:

```bash
<kit>/skills/merge-pr/scripts/guarded-pr-merge.sh "$PR" \
  -- --squash --delete-branch --body-file <squash-body.md>
```

`pr-merge` refuses a missing or empty `--body-file` (exit 2, nothing sent), so an unwritten body file
cannot land a squash with a blank body. A refused guard call takes the same fallback as above,
[`../../../_shared/guard-invocation.md`](../../../_shared/guard-invocation.md). Verify the resulting
release PR lists an entry per line. If the release tooling does not split the body, prefer not
bundling unrelated issues into one squash in the first place.
