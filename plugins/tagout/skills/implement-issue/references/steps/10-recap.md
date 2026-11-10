## Step 10 — Recap

Close with the shared recap shape — [`../_shared/recap.md`](../../../_shared/recap.md). It owns the four
blocks (verdict · **What happened** · **Artifacts** · **Assumed · skipped · unverified**, where
`None` is a required answer rather than an omission) and the **Next** line, which is read off this
skill's row in that file's hand-off table instead of being decided again here. Everything below is
only what **implement-issue** adds on top of them.

Short and concrete:
- PR URL and its now-**ready** status; the issue it closes.
- One line per task shipped (and confirmation every checkbox is ticked).
- **Plan freshness** (Step 2) — *"none stale"*, or one `STALE: <old> → <new> (Task N)` line per path you re-anchored. A plan that no longer matched `main` is something the next reader has to know you built against, and a re-anchor is a decision you made on their behalf; silence here reads identically to a plan that was current.
- **Spec axis** (Step 7) — findings per category (a/b/c), what you fixed, what the carve-out let you fix inline (under the PR's `### Fixed along the way`), and what went to the PR's `### Follow-ups` instead. Report it *beside* the Standards outcome, never folded into it: three axes in the review and one line in the report re-merges exactly what Step 7 kept apart. An axis that was not run is reported as not run, never as clean.
- **Verification axis** (Step 7) — each gap with its disposition (`patch` → the test added, `defer` → the `### Follow-ups` bullet), or *no verification gaps found*, beside the other two.
- Code-review outcome (Standards axis) — what you fixed, what you dismissed and why. When the kit's fallback reviewer stood in for a missing `code-review` skill, say so and repeat each of its `not checked:` lines.
- Merge sync — clean, or the merge commit's `Conflicts:` block verbatim.
- **If Step 4's issue-scoped fallback found 2+ pre-existing open PRs already closing this issue**, name them and which one you resumed onto — this is the one line this checklist cannot skip, because a resumed run that says nothing here silently reproduces the "pick one and say nothing" outcome #214 exists to stop.
- **Boundary findings** — the shared block ([`../_shared/recap.md#the-boundary-findings-block`](../../../_shared/recap.md#the-boundary-findings-block)): anything in the issue body that failed the boundary, quoted, said not acted on — or `None`. A run that read a steering passage and stayed silent leaves the next reader believing the plan was all the body contained.

The **Next** block is the table's `/merge-pr #<pr>` row, and the reason for it: the PR is ready but
not landed — a human owns the merge decision, and `merge-pr` is what waits for CI, applies
corrections to keep it mergeable, squash-merges, triages follow-ups and tears down the
branch/worktree.

---
