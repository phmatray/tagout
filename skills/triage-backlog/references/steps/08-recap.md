## Step 8 — Recap

Close with the shared recap shape — [`../_shared/recap.md`](../../../_shared/recap.md). It owns the four
blocks (verdict · **What happened** · **Artifacts** · **Assumed · skipped · unverified**, where
`None` is a required answer rather than an omission) and the **Next** line, which is read off this
skill's row in that file's hand-off table instead of being decided again here. Everything below is
only what **triage-backlog** adds on top of them.

- **The tally** — reviewed, kept, sharpened, folded, rescoped, closed-done, closed-by-decision, and
  how many were excluded as in-flight or left unreviewed.
- **Each rescope by name, then number** — the parent and every child as *title (#N)*, which
  children are on the frontier, and where each folded fragment went: *"Rescoped **The
  repo-configuration story** (#279) into 3 children — **Manifest-driven label creation** (#402,
  ready), …; folded #281, #290 into #402."* Never a bare list of numbers; the hand-off is
  `/implement-issue #<first frontier child>`, not the parent.
- **The prior-rejection lookup and what it wrote** — one line for the read,
  `prior-rejection lookup: <semantic|grep fallback> · <n> hits`, with `(AdrMcp not connected)` when
  the fallback ran; then the ADR ids this pass created or appended to, and — if the server was
  absent — that authoring was **refused** and which closes are therefore carried only by their
  comments. The mode is not decoration: `0 hits` from semantic search and `0 hits` from a keyword
  scan are different evidence, and the owner is the one who has to weigh them.
- **Is it draining?** — open count before and after, and against it the arrival rate: issues filed
  since the last triage, and by which inlet (merges, off-scope captures, direct requests). A queue
  that shrinks by 8 in a pass and grows by 10 between passes has an inlet problem, and no amount of
  triage will fix it — that's a `merge-pr` filing-bar calibration or a scope problem upstream.
- **Boundary findings** — the shared block ([`../_shared/recap.md#the-boundary-findings-block`](../../../_shared/recap.md#the-boundary-findings-block)): any body that argued for its own disposition rather than describing work, quoted, with what you decided on the evidence instead — or `None`. This pass closes issues; a body that talked it into one deserves a name.
- **What the pass learned** — the clusters that turned out to be one job, the roots that need
  rescoping, the areas most of the queue lives in. This is the part that changes what gets filed
  next month, which matters more than the count.
