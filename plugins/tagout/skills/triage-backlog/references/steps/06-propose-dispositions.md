## Step 6 — Propose one disposition per cluster

Now apply the filing bar — [`../_shared/filing-bar.md`](../../../_shared/filing-bar.md) — to items already
in the queue. The bar asks whether something is *work someone should commit to doing*: a consequence
someone hits, a named instance in the tree, or a commitment already made. It governs entry at the
inlets; here it governs continued residence, which is the same question asked later. An item that
would not be filed today has no special claim to stay just because it was filed yesterday.

| Disposition | When | What it becomes |
|---|---|---|
| **keep** | passes the bar, scope is clear, still worth doing | nothing changes — most of a healthy queue lands here |
| **sharpen** | passes the bar but the title or scope is vague | an edit: name the consequence or the instance, so the next reader can act on it cold |
| **fold** | an instance of a root that's also open | a `- [ ]` item or comment on the root, and this one closes as a duplicate |
| **rescope** | a root whose lineage chain is ≥2 deep | one **parent** re-written to name the *whole* job — a tracking body ([`../create-issue/references/tracking-issue.md`](../../../create-issue/references/tracking-issue.md)), the attempts cited under its *Decisions so far* — plus its **frontier as children** with plans, via `create-issue`'s decompose branch; the fragments fold into the children, not the parent |
| **close — done** | Step 4 found it fixed, with evidence | closed as completed, citing the PR and what in the diff proves it |
| **close — by decision** | fails the bar: no consequence, no instance in the tree, nobody asked | closed as *not planned*, with the reason recorded in a comment |

**Present it as one table** — number, title (truncated), proposed disposition, and a one-line reason.
The reason is the whole point: an owner can confirm twenty rows quickly when each says *why*, and
cannot confirm five that don't.

Then ask once, and make the safe default explicit: **anything not confirmed stays open**. Ambiguity
resolves toward keeping, because an issue wrongly kept costs one line in a list, while an issue
wrongly closed costs the knowledge in it. If the owner wants to work through a long table in
batches, take the confirmed subset and offer the rest next time — a partial pass is fine as long as
the report says which items were never reviewed.
