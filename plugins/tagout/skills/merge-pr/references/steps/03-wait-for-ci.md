## Step 3 — Wait for CI

Let the checks finish before judging — a half-run pipeline tells you nothing. The **authority** is the
check-runs on the PR's head SHA, not `gh pr checks` — GitHub can surface a *phantom* `skipped`
check-run alongside the real one for the same job (a known GitHub Actions behavior when a draft-gated
job re-triggers), so don't act on its verdict directly. **Run the check-runs recipe from
`references/merge-mechanics.md` §3**: it collects every check-run on the head SHA (paginated),
**reduces them to the latest run of each job** — a SHA carries a *history per job*, not one run per
job (#91) — and derives three sets from that reduced set: `failed` (failure / cancelled / timed_out),
`needs_approval` (action_required — a completed run awaiting a maintainer's approval, neither a
failure nor unstarted, #495) and `pending` (queued / in_progress / waiting / requested / pending) —
the first pair of `pending` is a run under way, the last three are a run that has **not started at
all**, behind an environment protection rule or posted by an app before it begins (#191). None of
those five has a conclusion, so none is evidence of anything; reading them as green is how a gated
`deploy` job merges without ever running.

That reduction **and** the rule that reads it are the registered decision `ci.verdict`, so run it —
do not re-derive it here. `$DECIDE` is Step 2's variable; `commit-checks` is the tracker verb that
reads every check on the sha into one normalised list (#752), on any tracker:

```bash
SHA=$("<kit>/scripts/tracker.sh" pr-view "$PR" | jq -r .headSha)
ci=$("<kit>/scripts/tracker.sh" commit-checks "$SHA" | "$DECIDE" ci.verdict --json)
[ -n "$ci" ] || { echo "check-runs query returned nothing — no verdict; do not merge"; exit 1; }
```

Keep `$ci`: Step 4's state block folds its `failed` and `pending` sets into the merge-state decision,
which is what stops the two steps from asking the same PR two unrelated questions.

While `pending` is non-empty, wait in **one call** to the kit's script — `skills/auto-dev/scripts/wait-ci.sh "$PR"` — never a turn per poll. In a session that can idle, run it in the background and resume when it exits; in a dispatched sub-agent, which must not end its turn to wait, run `POLL_SECONDS=30 MAX_POLLS=18 skills/auto-dev/scripts/wait-ci.sh "$PR"` in the foreground and re-run it while it exits 1 (timeout) — two timeouts with an unchanged table end the wait as the named blocker below. Its table is a wake signal, not the verdict: when it returns, re-run the recipe above **once** and judge —

- **`n_latest` is 0** (no check-runs at all) → the PR has no CI; treat CI as satisfied and let Step 4's
  merge-state be the gate. Ask the JSON for the count — an empty set is the string `[]`, and a
  *failed* query is the empty string, which is a missing answer rather than a green one.
- `failed` non-empty → read which and why before reacting; the failure feeds Step 4's correction (below).
- `failed` empty → Step 4 to confirm mergeability (nothing-failed ≠ mergeable; `main` may have moved).

**A green check-run proves the branch was green against the base it was tested with. If the base has
moved, the proof does not transfer.** Step 3 alone cannot see this — the check-runs it reads are
attached to the head SHA, and they stay green even when `main` has moved on since they last ran (#171,
measured landing #147: green checks, `mergeStateStatus: CLEAN`, six commits and 95 minutes stale).
Step 4's divergence read is what closes that gap, and it outranks the merge state inside the
precedence Step 4 runs — it is not a judgement made afterwards.

**Not every check-run on a SHA is a verdict**, and the ways that bites share one cause: the SHA
carries a job's *history*, and only its newest entry speaks for it. A `skipped` run is neither
`failed` nor `pending`, so the recipe treats it as a non-event; a run that a later run of the same
job superseded never reaches the rules at all, because the reduction has already dropped it. The
cases, and what actually guards each:

<!-- decided-by: ci.verdict -->

| Why a check-run is not the job's verdict | Safe to merge? | What actually guards it |
|---|---|---|
| A draft PR was flipped to ready and its checks never re-ran (`skipped`) | **No** — genuinely untested | The PR being a **draft** — when CI re-triggers on `ready_for_review`, a non-draft PR always has real check-runs for the jobs that were going to run (Step 1 already assumes ready) |
| A phantom `skipped` check-run posted alongside a real one for the same job (GitHub Actions can't retroactively void an already-completed `skipped` run when the job re-triggers) | Yes — the phantom is noise | The *real* check-run for that job also exists and reports its own conclusion. The reduction prefers it **whichever order the two arrive in**: a `skipped` run is only ever kept when a job has nothing else, so it cannot become a verdict by landing last |
| A workflow path filter correctly skips a job the PR's files don't touch (e.g. the back-end test job on a front-end-only PR) | Yes — by design, there's nothing for that job to test | Nothing — this is the legitimate case a naive gate hangs on |
| A run **superseded by a later run of the same job** — `cancel-in-progress` cancels it, and that `cancelled` stays attached to the SHA forever, beside the real conclusion (#91) | Yes, if the job's latest run is green — the superseded run never reached a verdict | The **reduction**: only the newest run per job name is in the set the rules see, so the superseded one cannot vote. Reference §3 records the measurement (three `kit` runs on one SHA, PR #85) |
| A job whose **latest** run is `cancelled` — a human pressing Cancel, or a job cancelled on timeout | **No** — a real cancellation is a non-verdict | Nothing else, which is why the fix is a reduction rather than dropping `cancelled` from the blocking set: after reducing, a latest `cancelled` is still in `failed` and still blocks |
| A job is `waiting` (behind an environment protection rule), `requested` (an app posted the check before starting it), or literally `pending` (a legacy status-API check) | **No** — not safe to merge, it has not run yet | The **`pending` predicate** (#191) — the distinction from `skipped` is `skipped` means this job will not run, `waiting`/`requested`/`pending` means it has not run **yet** |

⏳ **Re-poll a latest `cancelled` once before believing it.** `cancel-in-progress` flips the old
run's check-runs to `cancelled` the moment the new push lands, and the replacement run's check-runs
appear a beat later — later still for a job behind a `needs:` chain. A poll that lands in that
window sees `failed=[<job>]` for a PR that is about to go green, which walks Step 4 into hunting for
a red check that does not exist: the #85 shape again, narrowed to a race. So on a `cancelled` that
is a job's newest run, wait one poll interval and re-derive before entering the corrections loop. If
it is still the newest run, it is a real cancellation and it blocks.

So never hard-code "wait for `<job-name> == success`" — that hangs forever on the path-filter case
and reintroduces the same bug the moment another job grows a path filter. Gate on the shape instead:
nothing failed, nothing pending, PR not a draft. Repo-specific CI quirks of this kind belong in the
profile's *CI gates* section — record them there, not in this skill.

⚠️ **A `waiting`, `requested`, or `pending` job may be waiting on a human** — a required reviewer on a
deployment environment, for instance, or a stale legacy status check nobody will ever update — and
this skill has no way to clear that itself. If a job's state stays in one of those three across
several polls with no change, stop polling silently and **surface it as a named blocker** (job name +
its `html_url`, both already in the reduced set §3 produces — no extra query, and never
`statusCheckRollup`, which is out of scope here) for the user to clear, the same way an unclearable
required-approvals block is surfaced rather than waited on (§5). Polling it to the timeout with no
explanation is the failure this step exists to avoid.

`gh pr checks "$PR" --watch` (GitHub-only) is still fine as a **human-facing convenience** for
watching progress in a terminal, but don't treat its printed verdict as authoritative (the phantom-`skipped` case above) —
re-derive from the check-runs recipe before acting. Failure inspection (failed runs + their links) and the
long-pipeline polling pattern are also in reference §3.

**Related:** #91 fixes a different defect in this same check-runs recipe — *which* check-runs count
(a superseded `cancelled` blocking a green PR). This step's divergence read is about *what they were
run against*. Whoever touches one should check the other; Step 4 below carries the fallback for when
the branch can't be synced to pick up a moved base at all.
