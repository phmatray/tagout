## Step 9 — Verify, format, then mark ready

Marking a PR ready says "this is done." Earn it: build and tests green **on the just-merged tree**, and
**the same gates CI runs** clean. The exact commands are the profile's *Build & test* and *CI gates* —
run those, not hardcoded ones.

**1. Build + tests.** Run the profile's *Build* then *Full test*. If the profile flags a prerequisite
that can't be satisfied locally (a workload, a toolchain), run the plan's per-task test filters plus the
build instead, and say so in the report.

**2. Format/lint gate (CI enforces it — so must you).** The profile's *CI gates* include a format/lint
**verify** command that **fails the build** on any diff. New code routinely trips style/analyzer rules
that compile fine but the gate rejects. So before the ready-flip, run the profile's format/lint **apply**
command (scoped to the files/projects you touched), then its whole-repo **verify** (must exit clean — that's
the CI check). Heed the profile's caveats — some analyzer diagnostics can't be auto-fixed. Commit:

```bash
"$GUARDS/guarded-commit.sh" -C "$WORKTREE" <commit-identity> "$BRANCH" \
  -- -am "style: satisfy the format/lint gate" \
  && "$GUARDS/guarded-push.sh" -C "$WORKTREE" "$BRANCH"
```

**3. Mark ready** — only once build, tests, and the format/lint verify gate are all green:

```bash
"$GUARDS/guarded-ready.sh" -C "$WORKTREE" --branch "$BRANCH" <pr-number>
```

A REFUSED means Step 7's `post-review-check.sh` never came back clean on this branch: go back to
Step 7. "Small" sizes the review (a lower review level), it does not skip it.
