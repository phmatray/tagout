## Step 7 — Review on three axes: Standards, Spec, Verification

Stage the diff **once, to a file** — `git -C "$WORKTREE" fetch origin main --quiet && git -C "$WORKTREE" diff origin/main...HEAD > "/tmp/issue-$ISSUE.diff"`,
non-empty or stop — and hand sub-agents that path, never the diff text and never a worktree they
could write to (#477). Then review the **whole feature branch** (`origin/main...HEAD`, not just the last
commit) along **three axes, run in parallel and never merged**:

- **Standards** — is this good code by this repo's lights? Correctness bugs, missed reuse, cross-task
  inconsistencies, the profile's *Coding standards*. Run the **`code-review` skill** over
  `origin/main...HEAD` with an explicit level sized by the plan's breadth (Step 3) —
  `/code-review medium origin/main...HEAD` for a small, localized plan, `/code-review high origin/main...HEAD` for
  a broad/deep one. Pass the level every time: with no level, `code-review` reuses the last level
  typed in any session, and one bare call inherited `xhigh` and spent 106.8M tokens on 25 review
  sub-agents (2026-09-07). `ultra` is never prescribed — it is a cloud review the user launches and
  pays for, which no agent can start. **Never `--fix`**: read the findings and apply them yourself.
- **Spec** — is this what the issue *promised*? Dispatch **one sub-agent** with the brief in
  [`references/spec-review.md`](../spec-review.md): the diff file, the commit list and the
  issue's 📋 Spec as a second file **read after the diff**, reporting (a) requirements missing or
  partial, (b) behaviour never asked for (scope creep), (c) requirements implemented but wrong —
  **quoting the Spec line for each**, under 400 words.
- **Verification** — would a test fail if this broke *where it is used*? Dispatch **one sub-agent**
  with the brief in [`references/verification-gap-review.md`](../verification-gap-review.md):
  the diff file and the worktree for reading, reporting each behavioural change whose consumer no
  running assertion protects, with the test it read or the searches it ran.

<!-- review-dispatch:start -->
**Every review sub-agent is read-only by construction and isolated: `subagent_type: Explore`,
`isolation: "worktree"`.** A fork inherits the parent's full tool access and its checkout, so a
prompt saying "report only" competes with the `--fix` it also inherited — on one fleet run six
write-capable review forks edited one worker's live tree concurrently and one pushed to the PR
branch (#477). The agent type removes `Edit`/`Write`; the isolation puts any stray write in a
throwaway tree; the guards refuse the push. Review sub-agents return findings as text and **the
parent applies them** — one writer per worktree, always.
<!-- review-dispatch:end -->

A change can pass one axis and fail another: code that follows every convention and implements the
wrong feature passes Standards and fails Spec; code that does exactly what was asked, tested at its
own seam, and whose real callers no assertion protects passes both and fails Verification. The task loop makes that likelier here than elsewhere,
because each task is verified only by *its own* filtered test written from *its own* block — nothing
in Step 6 ever compares the whole against the promise. A PR can reach Step 9 all-green having built
the wrong feature to the letter, and this axis is the only thing that looks.

The Standards axis earns its keep most when green tests can't see the whole truth: a **code generator**
whose target toolchain is absent (conformance logs INCONCLUSIVE), a snapshot suite that captures output
without executing it — anything where "tests pass" proves the C# ran but not that the *emitted*
artifact is valid. Point the review at the generated output in those cases.

**Report the three verbatim, under their own headings, and do not rerank across them.** One merged list
lets a Standards nit outrank a missing acceptance criterion, and the reader acts on the top of the
list — that masking is what the separation exists to prevent. Close with a one-line tally per axis and
the worst item *within* each, never a single winner across them.

Then act on the disposition (the full table is in the reference):

| Finding | What happens |
|---|---|
| Standards findings, and Spec **(a) missing** / **(c) wrong** | fix **before** the ready-flip, commit on this branch |
| Verification `patch` | write the named test **before** the ready-flip; a red one is a bug found, fix it too |
| Verification `defer` | a bullet under `### Follow-ups` in the **PR description** |
| Spec **(b) not asked for** (scope creep) | the carve-out under *Don't widen the blast radius* (Notes on quality) decides: **local and small** → fix it inline, in its own commit, with a line under `### Fixed along the way`; anything else → a bullet under `### Follow-ups` in the **PR description** — create the section if absent |

`### Follow-ups` and not the session report: that heading is where `merge-pr` Step 6 harvests deferred
work and files it as tracked issues, so a creep finding recorded anywhere else is lost at merge. Do not
widen this PR to justify the creep beyond what the carve-out admits, and do not delete a sibling PR's
work on a hunch.

Triage the findings: a sub-agent reports, it never grades. For **each** finding, verify at the cited
file and line and write **one verdict** in your report — `real` (fixed, or deferred under
`### Follow-ups` with why), `false` (what disproves it there; a true fact about nearby code is not a
refutation), or `unclear` (what would settle it; goes to `### Follow-ups`). Never drop, merge or
silently skip one, and never comply performatively with a wrong one. Then commit and push:

```bash
"$GUARDS/guarded-commit.sh" -C "$WORKTREE" <commit-identity> "$BRANCH" \
  -- -am "fix: address code-review findings"
"$GUARDS/guarded-push.sh" -C "$WORKTREE" "$BRANCH"
```

Spec-axis fixes commit the same way, as `fix: address spec-review findings`, and Verification ones as
`test: close verification gap …`, so the three axes stay legible in the history.

The guards matter here more than anywhere: `code-review` is a sub-skill that **mutates the working
tree** (it has run `git checkout <ref> -- .` in a shared checkout and destroyed an uncommitted delta),
so this is the commit most likely to be made from a tree that moved under you.

If an axis is clean, say which one and skip its fix commit. **"Clean" is a result, not a default**: an
axis that was never run is not clean, and Step 10 recaps the three separately for exactly that reason.

**If the diff touches a path an accepted ADR names in its `code_refs`, propose the ADR update.**
Run `suggest_adr_from_change` over `git diff origin/main...HEAD` through the `adr` server and put the
returned draft under the PR's `## Follow-ups` heading as *ADR proposal*; without the server, grep
`docs/adr/*.md` frontmatter for a `code_refs` path this diff touches and write the proposal by hand
from the ADR it names, saying AdrMcp was not connected. It is a **proposal for the owner**: do not
`create_adr` it, do not `set_status` anything, and do not edit the ADR in this PR.
