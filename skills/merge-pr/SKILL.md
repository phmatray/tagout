---
name: merge-pr
description: >-
  Land an open GitHub pull request. Use whenever the user wants to MERGE, land, ship, or close out
  an open PR: waits for CI, applies corrections until mergeable (red checks, conflicts with the
  latest `main`, unresolved review), squash-merges, triages follow-ups, and tears down the branch
  and worktree. Triggers: "merge PR 279", "land #281", "ship this PR", "get that PR merged once CI's
  green", "wrap up 279 and open follow-ups", « merge la PR 279 », « fais atterrir la 281 », a bare
  PR link with "merge it". Does NOT apply to opening or implementing a PR, to syncing one STILL
  BEING BUILT (implement-issue), to reviewing without merging (code-review), or to filing an issue
  (create-issue).
license: MIT
compatibility: >-
  Requires an authenticated gh CLI with merge/push rights, and git. Files follow-ups via the
  create-issue skill. Reads the committed repo profile (.claude/skills/repo-profile.md) generated
  by init.
metadata:
  author: Philippe Matray
  suite: tagout
---

# Merge a pull request

## What this does

`implement-issue` builds a PR and flips it to ready. This skill is the final step: it **lands** that PR
cleanly and cleans up after itself. The job isn't just `gh pr merge` — a PR that's ready isn't
necessarily *mergeable* minutes later, because `main` moves, CI runs, and reviewers leave comments. So
this skill closes the gap: waits for CI, fixes whatever is actually blocking the merge, squashes the PR
in, turns deferred work into tracked issues, and removes the throwaway branch and worktree.

The shape mirrors `implement-issue`'s tail (sync-with-`main`, the profile's conflict hot-spots, the
commit identity) — reuse that machinery. The one new piece is the **corrections loop**: keep clearing
blockers and re-waiting until GitHub reports the PR `CLEAN`, then merge.

## Autonomy contract

Run **hands-off** once started — the user points at a PR and walks away. See
[ADR 0005](../../docs/adr/0005-the-lifecycle-skills-run-hands-off-triage-backlog-does-not.md) for the
decision scope. Whenever a step *could* stop for a question, pick the reasonable default, state the
assumption, keep going. Stop only for a genuine blocker:

- `gh` not authenticated, or no merge/push rights.
- The PR doesn't exist, is already merged/closed, or the number is ambiguous.
- **CI stays red after a real fix attempt.** Don't merge over a red bar, don't disable a failing test, don't `--admin`-override a required check. Fix it for real or stop and show the failing output.
- **A merge conflict you can't resolve with confidence** — both `main` and the branch rewrote the *same logic*. The mechanical conflicts (version, changelog, snapshots, lockfiles) have known-correct fixes (Step 4) — handle those; stop only for genuinely ambiguous ones, showing both sides.
- **A reviewer requested changes you can't satisfy** without guessing intent, or a branch-protection rule you can't legitimately clear (required approvals you can't self-give).
- **The branch has no writable checkout — not the transient sandbox push failure Step 2/§8 already covers — and GitHub reports `mergeStateStatus == DIRTY` or literal `BEHIND`.** The can't-push fallback (Step 4) only substitutes for the self-imposed staleness check (`behind_by > 0` while `mergeStateStatus` still reports `CLEAN`) — it never pushes anything to the PR's real branch, and only a push clears a real conflict or a GitHub-enforced up-to-date gate. That combination is a genuine blocker: stop and report it.

The merge is the irreversible act — earn it. Merge only when CI is **green on the just-corrected
branch** and GitHub reports the PR mergeable; a textual merge of `main` is not a semantic one, so
re-build/re-test after resolving conflicts. Filing a follow-up and deleting a local branch are
reversible — but a follow-up is cheap to *file* and expensive to *carry*, which is why Step 6 triages
before it files.

## Inputs

- **PR identifier** (required) — a number (`279`), an issue/PR URL, or a `gh` PR link. Resolve to a number (Step 1).
- **`--follow-up "<idea>"`** (optional, repeatable) — follow-up work to file as issues after the merge, e.g. `/merge-pr 279 --follow-up "add Rust snapshot tests" --follow-up "document minimap config"`. *Added to* whatever Step 6 discovers in the PR itself.

## Checklist

Create a task per item and work them in order. Step 4 is a loop — repeat until the PR is mergeable.

1. **Preconditions & resolve the PR** — `gh` works, you're in the target repo, normalize the PR number, confirm it's open, capture its head branch + merge state.
2. **Locate (or create) the branch's worktree** — find the local worktree/branch for the PR's head so corrections land in the right checkout; create one tracking the remote branch if none exists.
3. **Wait for CI** — let the checks finish; read the rollup.
4. **Apply corrections (loop)** — clear each blocker the merge state reports (red CI · behind/dirty vs `main` · unresolved review · draft), push, re-wait until the PR is `CLEAN`.
5. **Merge (squash)** — `<kit>/skills/merge-pr/scripts/guarded-pr-merge.sh` once green and mergeable; it runs the merge and decides the outcome from GitHub's `state`, never from the raw `gh pr merge` exit code. If that call is refused (an agent confined to its worktree, the path resolving outside it), see the fallback in [`_shared/guard-invocation.md`](../_shared/guard-invocation.md).
5b. **Read the base's CI run** — the merge just triggered one on `main`; resolve it **by the squash sha**, wait (bounded), and carry the answer into Step 8. Green, red, or an honest non-verdict — never silence.
5c. **Note a decomposed child's landing on its tracking parent** — when the merge closed an issue that is itself a child of a decomposed tracking parent (#315), append one line to the parent's `## Decisions so far` section; a silent no-op for every merge that isn't part of a decomposition.
6. **Triage follow-ups** — gather inline `--follow-up` args + ones discovered in the PR, cluster them by root cause, fold instances into the issue that already owns them, and file at most 3 new issues via `create-issue`.
7. **Delete the local branch & worktree** — from the main checkout, remove the PR's worktree and local branch.
8. **Recap** — the shared closing shape ([`../_shared/recap.md`](../_shared/recap.md), with its [Boundary findings block](../_shared/recap.md#the-boundary-findings-block)): merged PR URL, corrections applied, follow-ups filed, cleanup done.

Resume-safe: re-running mid-flight is fine. If the PR is already merged, skip to Step 5b (recover
the sha from `gh pr view --json mergeCommit`) and then Step 5c and Steps 6–7 — call Step 5c
unconditionally on a resume too, the same way Step 5b's own base-CI read does; its script is
idempotent per PR number, so a second call on an already-noted parent is a no-op, not a duplicate
line. If the
**local** worktree/branch is already gone, skip Step 7's local cleanup — but still run its remote
check (`remote-branch-teardown.sh`): the local branch being gone says nothing about whether
`origin/<headRefName>` survived (#185), and skipping Step 7 outright on a resume is exactly how
that branch leaks unnoticed.

---

## How to read this skill

**One step file at a time, when you reach it — never all up front.** Every token loaded here is
re-read on every later turn (`skills/auto-dev/references/token-economics.md`: ~83% of a run's
spend is context re-read), so the step bodies live under `references/steps/` and the checklist
above is the whole of what loads with the skill. Open a step when its checklist item starts; the
shared references it names load the same way, from inside that step.

- Step 1 — [`references/steps/01-preconditions.md`](references/steps/01-preconditions.md) · reads [`_shared/preconditions.md`](../_shared/preconditions.md)
- Step 2 — [`references/steps/02-worktree.md`](references/steps/02-worktree.md) · reads [`_shared/guard-invocation.md`](../_shared/guard-invocation.md), [`_shared/worktree-ignore-check.md`](../_shared/worktree-ignore-check.md)
- Step 3 — [`references/steps/03-wait-for-ci.md`](references/steps/03-wait-for-ci.md)
- Step 4 — [`references/steps/04-corrections-loop.md`](references/steps/04-corrections-loop.md) · reads [`_shared/sync-with-main.md`](../_shared/sync-with-main.md), [`_shared/untrusted-input-boundary.md`](../_shared/untrusted-input-boundary.md), [`_shared/worktree-ignore-check.md`](../_shared/worktree-ignore-check.md)
- Step 5 — [`references/steps/05-merge.md`](references/steps/05-merge.md)
- Step 5b — [`references/steps/05b-base-run.md`](references/steps/05b-base-run.md)
- Step 5c — [`references/steps/05c-parent-note.md`](references/steps/05c-parent-note.md)
- Step 6 — [`references/steps/06-follow-ups.md`](references/steps/06-follow-ups.md) · reads [`_shared/filing-bar.md`](../_shared/filing-bar.md), [`_shared/prior-rejections.md`](../_shared/prior-rejections.md), [`_shared/untrusted-input-boundary.md`](../_shared/untrusted-input-boundary.md)
- Step 7 — [`references/steps/07-teardown.md`](references/steps/07-teardown.md)
- Step 8 — [`references/steps/08-recap.md`](references/steps/08-recap.md) · reads [`_shared/recap.md`](../_shared/recap.md)

## Notes on quality

- **The merge is the one irreversible act — gate it hard.** Everything else (follow-up issues, branch deletion) is recoverable. Merge only on green CI **and** a `CLEAN` merge state, never by overriding a failing or required check.
- **Correct, don't paper over.** Fix the red test, resolve the real conflict, address the real review note. Skipping a test, forcing past a check, or hand-stitching a snapshot to clear a conflict all *look* like progress and are worse than stopping.
- **Stay resumable.** Every step keys off live GitHub/git state, so a re-run won't double-merge, double-file, or fail because a branch is already gone.
- **Follow-ups are tracked, not narrated** — deferred work belongs in an issue (via `create-issue`), not buried in the merge report.
- **…but tracked at the root, and rationed.** The failure mode this skill is most likely to cause is not a bad merge, it's a backlog nobody can read: one merge that files a dozen leaf issues, each a symptom of one defect, is a net loss even though every issue is individually accurate. Step 6's triage is the corrective — cluster first, fold into the root second, file last.
