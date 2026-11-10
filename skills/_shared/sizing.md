# Sizing a request: spike, bounded change, or the full cycle

The routing table in `AGENTS.md` picks a skill by **intent** — broken, new idea, planned issue.
This reference adds the one question it does not ask: **how big is it?** The full cycle
(`create-issue` → `implement-issue` → `merge-pr`) costs the same for a typo in a hint string as for
a cross-skill contract, and the kit already ships a lighter road. Sizing only chooses among entry
points that exist; it is not an autonomy level and changes nothing about how much any skill asks or
confirms (ADR-0009).

**It applies in one place: where a new request, with no issue, is first routed.** A session that
goes straight to `create-issue` gets the full cycle, and so does every skill that calls
`create-issue` itself — `merge-pr` filing a follow-up, an `auto-dev` worker capturing an off-scope
finding. `create-issue` never reads this file and never redirects.

## The rule fails towards the full cycle

Anything this page does not clearly recognise takes `create-issue`. **Any doubt goes up a size,
never down.** A request that asks for an issue always files one: a direct request outranks the
sizing, as it outranks the filing bar.

## Spike

The outcome is **a question answered, with no change to keep** — *"does X work on Y?"*.

Road: a throwaway branch, no issue, no PR; the finding goes back to the user. A spike that should
be kept is **sized again from the top**, as a new request — it is not promoted in place.

## Bounded

**Every** point must hold:

1. It fits **one `area:` label** from the profile — or one top-level directory, on a repository
   with no area axis.
2. It adds **no new file outside tests**.
3. It changes **no behaviour of a contract, a hook, a registered decision or a manifest**.
4. It touches **no one-way-door path** — the list is the `one-way-door` block of
   [`implement-issue` Step 7](../implement-issue/references/steps/07-review.md), read there and
   never copied here.

Road: a branch → commits through the guards → `create-pr --draft` → `merge-pr`. No issue, no plan.

- **`--draft` is what keeps the review on this road.** `merge-pr` runs a fresh review only when it
  flips a draft that has none recorded; a PR opened ready would land unreviewed.
- **No issue means no `(#issue)` suffix and no `Closes`** — [`open-pr.md`](open-pr.md) already
  handles an empty issue number.
- The full test and the title gate apply exactly as on any other PR.

## Anything else

A contract, an ADR, more than one area, a one-way door, a new shipped file, or a request that
simply does not fit the two above → `create-issue`, as today, with its ADR lookup and its plan.

## Say the size

State it in **one line** before acting — *"sized as bounded: one file, no contract"* — so the user
can override it. An override in either direction is followed without argument.
