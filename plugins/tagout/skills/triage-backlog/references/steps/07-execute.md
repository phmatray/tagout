## Step 7 — Execute the confirmed dispositions

Comment first, then act. The comment is the record; the state change without it is the silent
deletion the doctrine forbids:

```bash
# close by decision — the reason lives in the comment, the state in GitHub
gh issue comment "$N" --body "Not pursued by decision (<YYYY-MM-DD>): <the reason, in one or two sentences>."
gh issue close "$N" --reason "not planned"

# close as done — the evidence is the diff, so name it
gh issue comment "$N" --body "Fixed by #<PR> — <what in the diff closes it>."
gh issue close "$N" --reason completed

# fold — the root carries the evidence, the instance closes as a duplicate
gh issue comment "$ROOT" --body "Folds in #$N: <the instance, in one line>."
gh issue close "$N" --reason "not planned" --comment "Folded into #$ROOT — one job, tracked there."
```

### A close-by-decision on an enhancement also writes a rejected ADR

The comment above is the record for *this issue*. It is not a record of the **concept**, and that is
why the same idea kept coming back: a comment on a closed issue is per-request, invisible to every
inlet's sweep, and phrased in the vocabulary of the request rather than of the decision. So on every
confirmed *close — by decision* of an issue labelled `enhancement`, also write the decision where it
can be found — the authoring half of
[`../_shared/prior-rejections.md`](../../../_shared/prior-rejections.md): `search_adrs` for the concept,
`update_adr` to append a *Prior requests* bullet on a hit, `create_adr` + `set_status rejected`
(`previewOnly: false` — the owner just confirmed) on a miss, then `validate_adr`. The close comment
names the ADR id. The files go on a `docs/adr-<YYYY-MM-DD>` branch through `guarded-commit.sh` with
the profile's identity, and a PR titled `docs(adr): record <n> rejection(s) from triage <date>`.

**Only enhancements, and only rejections.** A *close — done*, a fold, a rescope, and anything labelled
`bug` write **nothing** here. This is not tidiness: recording a built feature or a duplicate as a
rejection **poisons the dedup**, so the next time someone asks for the thing that exists, the lookup
in Step 4 tells them it was declined. Same rule for a deferral — "not now" is a comment on the issue,
never an ADR.

**Without the `adr` server, refuse to author.** Print the MADR body for the owner, say
`prior-rejection ADR: not written (AdrMcp not connected)`, and close the issue anyway — its comment is
the record until the ADR exists. A rejection nobody can search is not a record, and writing a file
that looks like one is worse than not writing it. This is the one asymmetry with Step 4, which
degrades to the grep fallback rather than refusing.

**Rescope** is the one disposition that writes a new shape rather than a comment. A chain two deep
means the job was never named whole, and one wider issue is the same mistake with more words — it
would still be a single `effort: large` plan no worker can carry. The shape is `create-issue`'s
**decompose branch**: one **parent** carrying the tracking body and **N children** carrying the
plans, wired with native edges:

```bash
# 1. The parent: run create-issue with --seed on the root when its own text carries no plan
#    token (it BECOMES the parent, its original text kept above the --- rule) — a root that still
#    holds its old `## 🛠️ Implementation plan` cannot, and is folded under a FRESH parent instead
#    (create-issue Step 7 checks this and says so). Either way the parent's body ends in the
#    tracking sections —
#    Destination / Notes / Decisions so far / Not yet ticketed / Out of scope — and carries NO plan
#    token. `Decisions so far` is where the attempts go, one line each, by NAME then number:
#      - [Attempt title](link) (#N): <what it got done, and what it left>
# 2. The children: the frontier, filed in dependency order with their plans, each `Part of #P`.
# 3. The edges — the same second pass create-issue uses:
skills/create-issue/scripts/wire-edges.sh --repo {owner}/{repo} --parent "$P" \
  --child "$C1" --child "$C2:blocked-by=$C1"
# 4. The fragments fold into the CHILD that owns each one (a `- [ ]` on its plan, or a comment),
#    then close as duplicates naming that child — never into the parent, which stays plan-less.
gh issue close "$FRAG" --reason "not planned" --comment "Folded into <Child title> (#$C1) — one slice of <Parent title> (#$P)."
```

Read the parent back the way `create-issue` Step 7 does — `grep -cE 'Implementation plan|### Task|- \[ \]'`
over its body must print `0` — before closing a single fragment: a parent that trips it would be
dispatched whole, which is the failure the rescope exists to end.

Apply a `wontfix`-style label **only** if the profile's Labels section says this repo uses one and its
convention allows a second label on an issue. Where it doesn't, the `not planned` reason is already
the record — GitHub renders it, `gh issue list --state closed` filters on it, and it can't drift from
a label taxonomy nobody maintains.

Read back what you changed (`gh issue view "$N" --json state,stateReason`) the same way `create-issue`
reads back its labels — a `gh` call that prints nothing is not proof it worked.
