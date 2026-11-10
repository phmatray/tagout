# Shared Filing Bar: what earns an issue

This reference is used by every inlet that can create issues on its own initiative — `merge-pr`
Step 6 (follow-ups from a merge), `create-issue` Step 3 (an idea it discovered rather than one it
was handed), and the `auto-dev` workers' off-scope capture. One bar in one place, because two
inlets applying different bars is how a backlog stops meaning anything.

## Why there is a bar at all

An issue is a **commitment to do work**. An observation is a **record that something is true**. Both
are worth keeping; only one of them belongs in a queue someone is expected to drain.

The arithmetic is unforgiving. Filing costs seconds and resolving costs a PR, so an inlet that files
everything it noticed adds work faster than any loop can remove it — and the queue's signal drops as
it grows, because the item that actually matters is now sitting behind twenty that don't. A backlog
nobody can triage is functionally the same as no backlog, except it also generates guilt.

So the bar is not a quality judgement on the finding. A true, well-argued, genuinely-correct
observation can fail it. The question is never *"is this real?"* — it is **"is this work someone
should commit to doing?"**

## Before the bar: the inline-fix carve-out

The bar decides whether a finding someone *deferred* earns an issue. One test runs before it, and it
is stated in exactly one place — `implement-issue`'s *Don't widen the blast radius* bullet, mirrored
word for word in `commands/auto-dev-worker.md`'s off-scope protocol (`tests/skills/test.sh` pins the two
identical), never paraphrased here: a finding
that is both **local** and **small** in that bullet's sense is fixed inline, in its own commit, and
never reaches this bar — there is nothing left to file. A finding that fails either half reaches the
bar unchanged; the three gates and the veto below apply to it as they always did (#410).

## The bar: pass one of three, and file

**1. Consequence — someone gets a wrong result.** You can name, in one sentence, what breaks for a
user of the kit or a migration it runs: a wrong output, a failed run, a gate that passes when it
should have gone red. *"On Windows two local gates refuse every suite they scan"* names it. *"This
could be more robust"* does not.

**2. A named instance already in the tree.** The gap is not hypothetical: you can point at the file,
symbol, or config that exhibits it today. *"The pinned-literals check covers exactly one pin — the
repo has three more"* passes, because the three exist and can be listed. *"A future copy of this
idiom would slip past the guard"* does not — no such copy exists yet, so there is nothing to fix,
only something to watch.

**3. Commitment already made.** The owner asked for it, or the PR itself deferred it as part of its
own declared scope (*"lands the parser, adornments in a follow-up"*). The decision to do this work
has already been taken; the issue is just where it now lives.

Pass one gate and the finding earns an issue. Pass none and it is an observation.

## 4. Already declined — the one clause that overrules the other three

The three gates above are **gates**: pass any one and file. This clause is a **veto**: an idea that
matches a prior rejection fails the bar **however many of the three it passed**.

It has to work that way, because gate 2 is exactly what a declined idea passes. *"A named instance
already in the tree"* is satisfied every time the idea returns — the instance is real, the argument is
sound, and the decision not to do it was taken anyway. Three gates alone cannot tell "nobody has
looked at this" from "this was looked at and declined", so they file both.

A prior rejection is an ADR with `status: rejected` under the profile's *ADRs* root. Look it up before
applying the gates, by **concept and not keyword** — the recurring idea arrives under new vocabulary
every time, which is why the lookup is semantic and the fallback matches on word overlap rather than
on the title. The recipe, both modes, and the recap line each inlet owes are in
[`prior-rejections.md`](./prior-rejections.md).

**The one exception is written into the ADR itself.** Its *Consequences* section names the condition
that reopens it. If that condition **now holds** — and you can say in one sentence what changed and
where to see it — the veto lifts and the finding faces gates 1–3 normally; cite the ADR either way.
"This still seems like a good idea" is not that condition, and neither is a new name for the same
mechanism.

**A direct request from the user still outranks everything, this clause included.** Someone asking for
the issue is gate 3, and it is not a skill's place to tell them their own decision was already made.
File it, cite the ADR in the body, and append the new number to the ADR's *Prior requests* — the veto
governs what the pipeline files **on its own initiative**, which is the only channel that can run away.

## Where a finding goes when it fails the bar

Record it — retrievable later, costing nothing to ignore in the meantime:

```bash
gh pr comment "$PR" --body "Noted while merging: … (recorded, not filed — no action planned)."
```

This is not a consolation prize. The day a hypothetical acquires a real instance, the comment is
right there in the PR that first noticed it, and *then* it passes gate 2 and earns its issue. Filing
early doesn't make that day come sooner; it just carries the item until then.

## The two edges worth getting right

**A direct request from the user always outranks the bar.** When someone says *"file an issue for
this"*, that is gate 3 — they have made the commitment, and it is not the skill's place to relitigate
it. The bar exists to govern what the pipeline files **on its own initiative**, which is the only
channel that can run away. If you think a requested issue is thin, file it and say why in one
sentence; don't refuse.

**Hardening work is not exempt, but it isn't disqualified either.** Much of what a careful reviewer
finds is second-order — tests about tests, gates about gates. That work is legitimate and this bar
does not exist to suppress it. Gate 2 is what keeps it honest: a hardening finding with a named
instance in the tree is real work; one written against a shape nobody has committed is a watch item.
The distinction is checkable, which is why it is the gate rather than a judgement call about
"importance".

## Applying it

Apply the bar **after** clustering by root cause, never before. A cluster of three symptoms is one
finding, and it is the *cluster* that faces the bar — judging symptoms individually is how three
weak items get filed separately when the one root behind them would have passed on its own merits.

Run the prior-rejection lookup **before** the gates, on the cluster, for the same reason: a symptom
carries the vocabulary the reporter used, and the root carries the concept the ADR was written about.

Report what the bar did, in the skill's closing recap: *"7 observations · 2 filed · 4 recorded · 1
already declined (ADR-0008)"*. The count is what tells the owner whether the inlet is calibrated —
all-filed means the bar isn't being applied, all-recorded means it is being used to avoid work — and
the declined column is named separately because it is the one refusal the owner has already ruled on:
seeing it is how they notice a concept being re-proposed every week, and decide whether the ADR still
holds. The lookup states its own mode on its own line
([`prior-rejections.md`](./prior-rejections.md)) — a `0 hits` from the grep fallback is weaker
evidence than a `0 hits` from semantic search, and the recap has to let the owner tell them apart.

## Consumers

- `skills/auto-dev/SKILL.md` — a worker's off-scope capture, and the retro's recorded-not-filed candidates, both face the bar before anything is filed
- `skills/auto-dev/references/steps/06-stop-and-recap.md` — Step 6 of auto-dev, split out of its SKILL.md for progressive disclosure: the retro's `lessons:` candidates are recorded, not filed
- `skills/create-issue/SKILL.md` — an idea discovered rather than handed in faces the bar before it becomes an issue
- `skills/merge-pr/SKILL.md` — Step 6c puts each cluster of follow-ups to the bar before routing it
- `skills/review-sessions/SKILL.md` — Step 6 applies the bar to every still-present cluster before filing
- `skills/triage-backlog/SKILL.md` — Step 6 applies the bar to items already in the queue before deciding their disposition
- `skills/triage-backlog/references/steps/06-propose-dispositions.md` — Step 6 of triage-backlog, split out of its SKILL.md for progressive disclosure
- `ARCHITECTURE.md` — the *Skill call graph* section's cycle paragraph cites the bar as what closes the "three inlets, no outlet" loop
- `README.md` — the "Why these skills exist" table cites the bar as the standard shared by every inlet
- `skills/create-issue/references/steps/03-duplicates-and-root-causes.md` — Step 3 of create-issue, split out of its SKILL.md for progressive disclosure (#499)
- `skills/merge-pr/references/steps/06-follow-ups.md` — Step 6 of merge-pr, split out of its SKILL.md for progressive disclosure (#499)
