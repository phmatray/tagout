## Step 5b — Read the CI run your own merge triggered on the base

Step 5 ended at *the PR is MERGED*. That is one run too early. A green PR check-run only ever proved
the branch was green **against the base it was tested with** — §3's whole reduction is about the head
sha — and #171 already established that a base which moves *before* the merge invalidates that proof.
This is the other half: two PRs each green against their own base can still break `main` when both
land, and the only artifact that records it is the push run on `main`.

Measured here on 2026-08-30: `dce7d5b` (#338) had its `main` run **cancelled**, superseded 2m39s
later by the next merge; `f17c85c` (#342) had run `33346395704` record the failure. Both PRs had
already reported MERGED and torn down, so nobody read either. `main` was red ~40 minutes, every
in-flight PR in the fleet inherited the red bar, and PR #340's own CI failed on a diff that had
nothing to do with it. A human noticed; #352 was filed by hand.

**This step runs only on `guarded-pr-merge.sh` exit `0`.** Exits `1`–`4` route elsewhere and none of
them means a merge commit exists on the base — there is no sha to resolve. Take the sha from that
call's own stdout, which is `MERGED <sha>`:

```bash
BASE_SHA=$(printf '%s' "$MERGE_OUT" | awk '$1 == "MERGED" { print $2 }')

# The guard reads the sha back itself when it can't, and prints the literal `<unknown-sha>` rather
# than nothing — a null `mergeSha` on a readback taken seconds after the merge. That string
# is not a sha, so recover it before spending a poll on it; the helper would refuse it (exit 64),
# which is the one case where it does NOT answer.
case "$BASE_SHA" in
  *[!0-9a-fA-F]*|"") BASE_SHA=$("<kit>/scripts/tracker.sh" pr-view "$PR" | jq -r '.mergeSha // ""') ;;
esac

# An empty $BASE_SHA has nothing to resolve, and the helper refuses it (exit 64, no stdout) rather
# than answer — the one case where it does NOT answer. Don't call it: that would leave $BASE_LINE
# empty, breaking the "BASE: field IS $BASE_LINE" guarantee below. Compose the non-verdict directly,
# in the same grammar, instead. (Exit 64 also covers a malformed -R slug or a missing
# skills/_shared/scripts/_gh-host.sh, #530 — neither reachable from THIS call, which passes no -R
# and runs from an install a much earlier preflight step already proved has the helper.)
if [ -n "$BASE_SHA" ]; then
  BASE_LINE=$(skills/merge-pr/scripts/base-run-verdict.sh "$BASE_SHA" --timeout 240 --report-line)
else
  BASE_LINE="unverified (no-sha)"
fi
base_verdict_word=${BASE_LINE%% *}                                # green | RED | unverified — for
                                                                   # branching only; never re-derived
```

**Give the call room, and treat a killed call as a non-verdict.** The helper waits for a run that
takes minutes, so run this Bash call with a timeout comfortably above the `--timeout` you pass
(300000 ms for the 240 s above) — the tool's own 120 s default would kill it mid-poll, and an empty
`$BASE_LINE` satisfies none of the three branches below. If it *is* cut short, that is
`base unverified at <sha> — the wait was cut short`, not a missing line and not a green.

⛔ **The `BASE:` value every report from this step carries — the recap here, and the phase-2 report's
`BASE:` field — IS `$BASE_LINE`, copied verbatim.** Never composed, never summarized, never
cross-checked against a second source. #455 measured 5 of 17 merges on one fleet run reporting a
premature `green` in this field because a worker *paraphrased* the helper's answer instead of
quoting it — some of them, after being told the exact workflow and command to read, cited job names
from a **different** workflow's run (`release-please`'s or GitHub Pages' `pages-build-deployment`,
whose jobs are named `build`/`deploy`/`report-build-status`) as their evidence. **Never call `gh run
list` for this step, and never infer this merge's base verdict from another workflow's job names —
`release-please` and `pages-build-deployment` are not this merge's CI and prove nothing about it.**
The one sanctioned exception is `base-run-followup.sh` below (#561), invoked only on a `timeout`
reason and only from that one prescribed call site — it never composes its own ad hoc question,
and its answer *replaces* `$BASE_LINE` rather than being weighed alongside it.
`$BASE_LINE` is the only source of truth `--report-line` was built to make un-paraphrasable
(`tests/merge-base-ci/test.sh` pins this exact trap: a fabricated `pages-build-deployment` success
armed alongside a real failure for this sha, asserting the line still reads `RED (failed)`).

**By the sha, never by recency.** `gh run list --branch main` answers "the newest run on the branch",
which under a merge train — the ordinary `auto-dev` shape — is routinely a *sibling* merge's run
landing seconds later. That would blame this merge for someone else's red, and hide this merge's red
behind someone else's green. The helper asks `tracker.sh commit-checks`, which is keyed on the sha by
construction, and delegates the rules to the registered `ci.verdict` decision rather than growing a
second CI reader. The resolution recipe lives beside §3's in `references/merge-mechanics.md`; the
`gh run list` trap is pinned red by `tests/merge-base-ci/test.sh`.

**When check-runs fails, the helper falls back to the workflow-runs endpoint — still by sha
(`actions/runs?head_sha=<sha>`), never by branch (#479).** That fallback is a GitHub Enterprise
workaround and stays a direct, GitHub-only `gh` call (#752); on any other tracker it is skipped. On GitHub Enterprise Server the
check-runs endpoint 404s on a just-created squash sha while the run is already visible; twelve
merges of one fleet run reported `unverified (query-failed)` that way and a base that went red
twice was never seen. A verdict from the fallback says so: `green (base-run)`, `RED (base-run)`,
`unverified (no-run-yet)`. **A repeated `unverified` is a finding, not a default** — one is an
honest answer about one merge; the same reason three merges running means the base has no
health check at all, and the recap says that in those words rather than recording another
quiet row.

**On a `timeout` reason only, spend one bounded, non-polling follow-up before treating
`$BASE_LINE` as final (#561).** `timeout` means the poll loop's own convergence criterion — two
consecutive identical job-name signatures — never settled inside the budget; under several
`auto-dev` workers sharing the same CI runners the job graph for one sha can keep shifting long
enough that this never happens even while the run is genuinely converging toward green. Measured
2026-09-12: two merges in a 5-worker fleet run answered `unverified (timeout)` for a base that had
already finished cleanly by the time a human re-checked, minutes later, with exactly this lookup.
This is the ONE case a second lookup is sanctioned — never for `green`/`RED`, and never for any
other `unverified` reason (`api-404`, `query-failed`, `no-run-yet`, `decision-failed`, `cancelled`
are already-settled or already-decided answers; #479 decided how those are handled and this
changes nothing about them):

```bash
case "$BASE_LINE" in
  "unverified (timeout)")
    # $BASE is the baseBranch Step 1 already captured. One `gh run list` call, no sleep, no
    # re-poll of base-run-verdict.sh itself — never a second poll loop. GitHub-only (#752): on
    # any other tracker the helper calls nothing and prints `unverified (timeout)`.
    BASE_LINE=$(skills/merge-pr/scripts/base-run-followup.sh "$BASE" "$BASE_SHA")
    base_verdict_word=${BASE_LINE%% *}
    ;;
esac
```

The helper prints one of `green (base-run)` / `RED (base-run)` / `unverified (timeout)` (unchanged,
if its own lookup is *also* inconclusive) and always exits `0`. `$BASE_LINE` is reassigned to
*its* answer outright, never composed alongside the original — the ⛔ rule above still holds:
whichever line is now current is quoted verbatim, never both.

Then act on `$base_verdict_word` — three outcomes, and all three are reported as `$BASE_LINE`:

- **`green`** → nothing to do. Continue to Step 6 unchanged.
- **`RED`** → the merge is done and **is not being reverted**. File it once, as a `bug`, through the
  same `create-issue` inlet Step 6 already uses, carrying the base sha, the run URL, this PR and its
  issue, and the failing job name(s) — read those off `commit-checks` directly, a single
  non-polling read (the run is already settled, so there is nothing left to wait for — this is not a
  second `base-run-verdict.sh` call, which would re-run its whole poll loop for no reason):
  ```bash
  "<kit>/scripts/tracker.sh" commit-checks "$BASE_SHA" | jq -r '.[] | select(.bucket == "fail") | .name' | sort -u
  ```
  **Fold on the breakage, not on the sha.** A sibling merge in the train produces a *different*
  squash sha and inherits the same red, so a sha-keyed search never matches and three workers file
  three bugs for one root cause: look instead for an open bug about the base branch failing
  **the same job(s)**, and if one exists add your sha, run URL and PR to it as a comment. Then
  continue to Step 6; the merge itself is not in question.
- **`unverified`** → report `$BASE_LINE` as-is. Its `(<reason>)` names which silence it was: the run
  was cancelled by the next merge in the train, the base runs no CI on push, the bound expired, or
  the query never answered. **This is the step working, not failing** — a non-verdict reported is
  exactly what nobody had on 2026-08-30.

⛔ **Never revert.** The red may be *inherited* from a merge seconds earlier, and an autonomous revert
of somebody else's change is a strictly worse failure than a filed bug. Report and file.

⛔ **Never stop here either.** This step cannot block the merge — the merge already happened — and
adding a post-merge stop would hand an autonomous fleet a brand-new way to strand a slot on work that
succeeded. Its worst case is a stated non-verdict, which is why the helper exits `0` on every outcome.
