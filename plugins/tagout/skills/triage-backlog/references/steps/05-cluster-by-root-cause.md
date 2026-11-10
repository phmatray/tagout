## Step 5 — Cluster by root cause

Run the same clustering `merge-pr` 6a does, but across the whole open queue rather than one merge's
findings: group items by the file or subsystem they land in, and name the shared cause where several
share one. A queue accumulated over months hides much bigger clusters than any single merge sees —
five issues filed weeks apart against the same guard are one job that nobody recognized as one,
precisely because they arrived separately.

Clustering here does double duty. It shrinks the queue honestly (five rows become one root plus four
folded instances), and it exposes the roots that are **mis-scoped**: a root with a lineage chain two
deep has now failed twice, and filing attempt four against it is not a plan.
