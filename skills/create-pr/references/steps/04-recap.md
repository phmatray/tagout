## Step 4 — Recap

Close with the shared recap shape — [`../_shared/recap.md`](../../../_shared/recap.md). It owns the
blocks and the **Next** line, which comes from this skill's row in the hand-off table:
`/merge-pr #<pr>`. Only what **create-pr** adds is listed here:

- **The PR** — its URL, whether it is ready or a draft, and why: `--draft` was asked, or the *Full test*
  was red. For red, name the command and the sha, and quote the failing tail of the kept output.
- **The issue** — `Closes #N`, or that no issue is linked. If a number from the branch name was
  dropped, say so under *Assumed · skipped · unverified*.
- **An existing PR** — when the recipe's §1 stopped the run, name that PR. Next is still
  `/merge-pr #<pr>`, with its number.
- **A refusal** — the rule from Step 2 and what it named (the dirty files, the default branch). Nothing
  was written, and Next is `—`.
