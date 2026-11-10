## Step 1 — Preconditions & scope

**Follow the shared preconditions reference** at [`../_shared/preconditions.md`](../../../_shared/preconditions.md)
to load the repo profile, verify authentication, and prepare the commit identity shorthand.

From the profile you specifically need the **Labels** section. Two things there drive Step 7: whether
this repo has a `wontfix`-style label at all, and its **convention in practice** — a repo whose issues
carry exactly one label should not suddenly grow two-label issues because a triage pass ran. When the
convention forbids a second label, the close reason alone carries the decision; GitHub's native
`not planned` state is the record, and the label was only ever a convenience.

You also need the profile's ***ADRs*** and ***Out-of-scope records*** sections, because this pass is
the only one that both **reads** and **writes** prior rejections. *ADRs* names the root; `none` there
means there is nothing to consult and nowhere to write, which is a sentence for the Step 8 recap
rather than a step to skip in silence. Then find out whether the `adr` MCP server is connected in
*this* session — it is a session fact, not a repo fact — because that decides which half of
[`../_shared/prior-rejections.md`](../../../_shared/prior-rejections.md) runs: `search_adrs` in semantic
mode, or the grep fallback plus a **refusal to author**.

Resolve the scope from the user's words. No scope given means every open issue — which is usually what
"the backlog never shrinks" is about.
