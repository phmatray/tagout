# GitHub / git mechanics for `merge-pr`

The fiddly `gh`/`git`/`jq`/GraphQL snippets the main workflow leans on. Read the section you need when
you hit it. `{owner}/{repo}` is a literal `gh` placeholder it resolves from `origin` (the repo the
profile names) — paste it as-is. And `git <commit-identity>` is the author line from the profile's
*Commit identity* (SKILL.md Step 1) — substitute its `-c user.email=… -c user.name="…"` flags below.

---

## 1. Resolve the PR number from whatever the user gave you

A bare number, a PR/issue URL, or a `gh` link all reduce to the first run of digits:

```bash
ARG="$1"   # e.g. 279 | https://github.com/<owner>/<repo>/pull/279 | "#279"
PR=$(printf '%s' "$ARG" | grep -oE '[0-9]+' | head -1)
```

Strip any `--follow-up "…"` args before this so their text can't contribute stray digits — parse the
command into the PR token and the list of follow-up strings first, then run the digit extraction on the
PR token alone.

Confirm it's a real, open PR before doing anything irreversible:

```bash
gh pr view "$PR" --json number,title,state,isDraft,mergeStateStatus,headRefName,baseRefName,url \
  --jq '"\(.number) [\(.state)\(if .isDraft then "/draft" else "" end)] \(.mergeStateStatus) \(.headRefName) — \(.title)"'
```

---

## 2. Find — or create — the branch's worktree

Corrections must land in a checkout of the PR's head branch. List worktrees and match the branch:

```bash
HEAD_BRANCH=$(gh pr view "$PR" --json headRefName --jq .headRefName)

# Print "<path> <branch>" per worktree, then grep the branch. `substr($0, N)` — not `$2` — for both
# fields: splitting on whitespace truncates a checkout under a path containing a space
# (`/Users/x/my repo` -> `/Users/x/my`), measured (#125). `scripts/main-worktree.sh` does not fit
# here — it names only the FIRST (main) worktree, and this needs every record so it can grep the
# one matching branch.
git worktree list --porcelain \
  | awk '/^worktree /{p=substr($0,10)} /^branch /{b=substr($0,8); sub("refs/heads/","",b); print p, b}' \
  | grep -E " ${HEAD_BRANCH}$"
```

Whichever branch you are on — a worktree was found, or Step 4 shows corrections are needed and one
must be created — establish the precondition **first**, and BRANCH ON IT; the guard's refusal has to
stop the next line, or it is decoration:

```bash
# `<kit>` is the kit root (holds skills/ and scripts/), resolved when the skill loads; the guard
# judges the repo at -C, so an installed plugin works.
#
# The recipe (main working tree, bare repositories, and why it must NOT be derived from a worktree
# path) is stated once in ../../_shared/worktree-ignore-check.md — run it from there.
REPO_ROOT=<per _shared/worktree-ignore-check.md — empty for a bare repo, which has nothing to check>
if [ -n "$REPO_ROOT" ]; then
  rc=0; <kit>/scripts/worktrees-ignored.sh -C "$REPO_ROOT" || rc=$?
  case "$rc" in
    0|2) : ;;                                  # 2 = ignored but over-broad: no worktree hazard, proceed
    *)   echo "worktree home not verified (exit $rc) — not creating or using one"; exit 1 ;;
  esac
fi
```

Only then take one of the two branches:

```bash
# Found: the path column of the matching line above.
WORKTREE=<absolute path of the matched worktree>
git -C "$WORKTREE" pull --ff-only

# Or created by hand — implement-issue's make-worktree.sh only creates fresh off the repository's
# resolved default branch (#678), never from an arbitrary remote branch, so a PR built elsewhere is
# checked out this way:
git fetch origin "$HEAD_BRANCH"
WORKTREE="$REPO_ROOT/.claude/worktrees/merge-$PR"   # same root the guard just cleared
git worktree add "$WORKTREE" "$HEAD_BRANCH"    # checks out the existing branch (tracks origin/$HEAD_BRANCH)
```

**Why the check covers use, not just creation** (#86) — and why it still runs *before* either branch.
Reuse is this skill's usual case: `implement-issue` normally left a worktree behind, so a check wired
to `git worktree add` verifies only the runs that happen to build one, and never the repo that keeps
getting worked in. A worktree that already exists is also the one with something to find — its home
was ignored once, or nobody looked, and the rule can have been dropped or negated since. But widening
*when* it applies must not delay *where* it sits: run it after `git worktree add` and a refusal has
already planted a full checkout in the unignored home, with nothing prescribed to remove it; run it
after `pull --ff-only` and it has already written there. Hence one call, ahead of both. (No worktree
at all — the already-`CLEAN` merge — means nothing to check; that stays true.)

⚠️ **`$REPO_ROOT` is also the root the worktree is created under**, deliberately: deriving the
creation path from the ambient `git rev-parse --show-toplevel` while verifying a different root lets
the two disagree whenever the session sits in a linked worktree — which this skill warns is common —
so the guard would clear one directory while `git worktree add` planted the checkout in another.

**Why it must be checked.** `.claude/worktrees/` is this kit's convention, and a convention is not
a fact about *someone else's* repository. A worktree is a full checkout, so where the rule is absent
**any** `git add -A` run in that repo stages it — measured shape (#43): one
`160000 <sha> 0 .claude/worktrees/<branch>` gitlink pointing at a commit no clone can fetch, not a
large diff anyone notices in review. Not the kit's own command any more (#68 narrowed the only one it
had), which changes *whose* mistake this catches, not whether it is worth catching — see
[`../../_shared/worktree-ignore-check.md`](../../_shared/worktree-ignore-check.md). This file used to
state the guarantee as settled ("the repo's conventional (git-ignored) home") while nothing
established it; the lines above are what make it true rather than hopeful.

The verdicts — including why `2` proceeds and `1` does not, and the rule against editing someone
else's `.gitignore` unasked — are in
[`../../_shared/worktree-ignore-check.md`](../../_shared/worktree-ignore-check.md). They are stated
once, there, because the first version of this change spelled them out in four files and they had
already drifted apart.

Keep `$WORKTREE` — Step 4's guarded writes take it, and Step 7 removes that path.

---

## 3. Waiting on CI

The authority is the **check-runs on the PR's head SHA**, not `gh pr checks` — the latter can print a
phantom `skipped` check-run alongside the real one for the same job (a known GitHub Actions behavior
when a draft-gated job re-triggers), so its verdict can't be trusted directly:

```bash
SHA=$(gh pr view "$PR" --json headRefOid --jq .headRefOid)
# --slurp piped into the dispatcher (gh's --jq can't combine with --slurp) flattens every page's
# {total_count, check_runs:[...]} into one list — safe even if check-runs ever exceed a page.
#
# The reduction and the rules are NOT pasted here any more (#208). `decide.sh` extracts them from
# the marked block below and runs THAT, so the program applied to a real PR is byte-for-byte the
# one tests/merge-gate/test.sh pins over fixtures — a pasted copy could drift from it, and a
# drifted copy of a gate is the failure this whole reduction exists to prevent, wearing a passing
# test. `--json` asks for the whole object, because the counts read below are part of it.
verdict=$(gh api "repos/{owner}/{repo}/commits/$SHA/check-runs" --hostname <host> --paginate --slurp | "$DECIDE" ci.verdict --json)

# A failed query prints nothing, and without `pipefail` the pipeline still exits 0 — at which point
# an empty verdict reads as "this SHA has no check-runs", i.e. as a pass. No verdict is not a pass.
# `decide.sh` makes the same refusal one layer down (exit 2 on empty input); this line is what
# catches a `gh` that failed BEFORE the pipe, where the dispatcher was never reached at all.
[ -n "$verdict" ] || { echo "check-runs query returned nothing — no verdict; do not merge"; exit 1; }

latest=$(printf '%s' "$verdict"  | jq .latest)   # one run per job — the set the rules apply to
failed=$(printf '%s' "$verdict"  | jq .failed)
pending=$(printf '%s' "$verdict" | jq .pending)

# Ask the JSON how many, never the shell string: an empty set is the four bytes `[]`, which every
# `[ -z "$x" ]` test in sight reports as non-empty.
n_latest=$(printf  '%s' "$verdict" | jq '.latest  | length')
n_failed=$(printf  '%s' "$verdict" | jq '.failed  | length')
n_pending=$(printf '%s' "$verdict" | jq '.pending | length')

# The same object carries the decision's own answer and the name of the rule that produced it —
# no-ci | pending | failed | clear. The counts above are what the prose below explains; this is
# the word to act on, and `decide.sh` has already refused any word outside that vocabulary.
ci_verdict=$(printf '%s' "$verdict" | jq -r .verdict)
```

**The rules themselves are the registered decision `ci.verdict`** (#170, #208): one id, one
program, one home — and this file is the home. `scripts/decide.sh` extracts everything between the
two markers and runs it; `tests/merge-gate/test.sh` obtains it through that same call before
driving it over thirteen fixtures, so there is exactly one extraction in the repo and a bug in it
reddens both places at once. Read this here. Never copy it anywhere — `scripts/decision-check.py`
R1 refuses a second copy of these markers, because two homes for a gate is how a gate drifts.

```jq
  # >>> decision ci.verdict rule — extracted verbatim and run over fixtures by tests/merge-gate/test.sh >>>
  # One SHA carries a HISTORY PER JOB, not one run per job, so reduce before judging: keep the
  # newest run of each job and apply the rules to that alone.
  [ .[].check_runs[] | {name, id, app: .app.id, started_at, html_url, state: (.conclusion // .status)} ]
  # A job is identified by the check name AND the app that posted it. Two products can both
  # publish a check called build — GitHub Actions and a CI app — and grouping on the name alone
  # would let whichever posted later silently retire the other one verdict.
  | group_by([.name, .app])
  # Ordered by .id, not .started_at. A check-run id is assigned when the run is CREATED, so the
  # greatest id is the newest run of that job, which is the question being asked. started_at is
  # weaker on three counts: it is nullable, so a queued run that has not begun sorts FIRST and
  # loses to the stale success it is meant to supersede; it is compared here as a string, so a
  # producer emitting a UTC offset rather than Z orders wrongly; and a job held behind needs: can
  # start later than a job from a newer run.
  | map(sort_by(.id)
        # A skipped run is not a verdict, so it must not become one by arriving last. Prefer the
        # newest run that reached a real conclusion, and fall back to a skipped one only when the
        # job has nothing else — the path-filter case, which stays a non-event.
        | ((map(select(.state != "skipped")) | last) // last))
  | { latest: .,
      failed:  [ .[] | select(.state == "failure" or .state == "cancelled" or .state == "timed_out") ],
      # A completed run whose conclusion is `action_required` (#495) is a third state, neither
      # failed nor pending: GitHub uses it for a workflow run awaiting approval (first-time
      # contributors, or a bot-authored PR under "require approval for all outside collaborators").
      # Nothing a push can change clears it — only an approval can — so it must not be filed under
      # `failed`, where a correction loop would hunt forever for a fix that does not exist.
      needs_approval: [ .[] | select(.state == "action_required") ],
      # queued/in_progress are a run under way; waiting/requested/pending are a run that has not
      # started at all (behind an environment protection rule, or an app posting the check before
      # it begins). None of the five has a conclusion, and none is skipped, so none is evidence of
      # anything — merging on it would be merging on a job that never ran. This is an ENUMERATION
      # of the check-run status enum, not a proof: a status GitHub adds later still falls in the
      # unhandled default and reads as green. Re-check https://docs.github.com/rest/checks/runs
      # when this gate is next touched.
      pending: [ .[] | select(.state == "queued" or .state == "in_progress" or .state == "waiting" or .state == "requested" or .state == "pending") ] }
  # Same program, one more question: the reduction above, and the verdict a caller acts on. Purely
  # additive — .latest, .failed and .pending are untouched, so every fixture assertion in
  # tests/merge-gate keeps its exact meaning. The rule name is what the event log attributes a
  # cause to; no-checks and clear are different silences and must not share one name.
  #
  # The widened `pending` above (#191) and this tail were written on separate branches and compose
  # exactly: #191 decides WHICH runs count as pending, this decides what a caller DOES about them.
  # A waiting deployment gate therefore now reaches verdict:"pending" rather than falling through
  # to clear — which was the whole point of #191, carried into the registered decision.
  #
  # `needs-approval` sits between `pending` and `failed` (#495): like `pending` it is non-terminal
  # (a remedy exists — approve the run) and like `failed` it must not be masked by an unrelated
  # job still in flight, which is why `pending` is still checked first — a PR that is BOTH waiting
  # on a slow job AND awaiting approval reports the one a caller can do nothing about yet.
  | . + (if   (.latest | length) == 0        then {verdict:"no-ci",          rule:"no-checks"}
         elif (.pending | length) > 0        then {verdict:"pending",        rule:"pending"}
         elif (.needs_approval | length) > 0 then {verdict:"needs-approval", rule:"needs-approval"}
         elif (.failed  | length) > 0        then {verdict:"failed",         rule:"failed"}
         else                                     {verdict:"clear",          rule:"clear"} end)
  # <<< decision ci.verdict rule <<<
```

Merge is permitted (CI-wise) when `failed` is empty **and** `pending` is empty **and** the PR is not a
draft — not when one named job reports `success`. A `skipped` check-run is neither `failed` nor
`pending`, so it's simply not evidence of anything; treating it as a blanket "CI didn't run" hangs
forever when a workflow path filter legitimately skips a job the PR's files don't touch (see
`SKILL.md` Step 3 for the full breakdown of why a check-run may not be its job's verdict).

**Why the runs are reduced first (#91).** GitHub attaches a *history per job* to a SHA, not one run
per job — and this repo's own `ci.yml` manufactures those histories deliberately: `cancel-in-progress`
(#27/#29) exists so a retitle cannot leave two runs racing to publish the same `kit` check. Its
unavoidable consequence is that a **superseded `cancelled` stays attached to the head SHA forever**,
beside the real `success` for the same job. Pushing twice in quick succession, editing a PR body, or
retargeting a stacked PR all produce one.

Measured on PR #85 — head sha `8c58eb2` carried three check-runs, all named `kit`:

| started | conclusion | what it was |
|---|---|---|
| 09:34:38 | `cancelled` | superseded when the next push landed |
| 09:35:07 | `success` | the real verdict |
| 09:48:09 | `success` | re-run after the base retargeted to `main` when #76 merged |

GitHub itself reported `mergeStateStatus: CLEAN` / `mergeable: MERGEABLE` throughout. Read as a flat
set that PR is **failed**: SKILL.md Step 4's corrections loop would have gone hunting for a red check, found
nothing to fix, exhausted its rounds and refused a PR that was green on two separate runs. The
symmetric hazard was equally unguarded and is the worse one — a stale `success` sitting beside a
newer `failure` for the same job, where "some run succeeded" reads as fine. One reduction closes
both, and it is the argument `SKILL.md` Step 3 already makes about phantom `skipped` runs applied to
the case it used to miss.

⚠️ **This is not "ignore `cancelled`".** A cancellation *superseded by a later run of the same job* is
noise; a cancellation that **is** the job's latest run — a human pressing Cancel, a job cancelled on
timeout — is a genuine non-verdict and still blocks. `tests/merge-gate/test.sh` extracts the program
above from this file and drives both cases over fixtures, so a rewrite that weakens the gate into
blanket-ignoring cancellations goes red instead of quiet.

Inspect failures via the rollup (gives the log URL to read):

```bash
gh pr view "$PR" --json statusCheckRollup \
  --jq '.statusCheckRollup[] | select(.conclusion=="FAILURE") | {name, detailsUrl}'
```

- **`n_latest` is 0** (no check-runs at all) → the PR has no CI; treat CI as satisfied and let
  `mergeStateStatus` (§4) be the only gate. This is the *reduced* set, so it is 0 exactly when the
  SHA carries no check-runs — every run belongs to some job. It is 0 only when the query above
  actually answered; that is what the `-n "$verdict"` refusal is for, since "the call failed" and
  "there is no CI" are opposite verdicts that an unguarded empty string spells identically.
- **Long pipelines** → re-poll the check-runs recipe rather than busy-looping. If you'd rather not hold
  the turn open, come back later (e.g. via `ScheduleWakeup`).
- `gh pr checks "$PR" --watch` is still useful as a **human-facing** progress view in a terminal, but
  don't wire its exit code or printed verdict into the gate — re-derive from the check-runs recipe above.

The repo's CI gates (so you can reproduce a red check locally) are the profile's *CI gates* — its build,
test, and format/lint **verify** commands, plus any prerequisite the profile flags (a workload, a
toolchain). The format/lint gate trips on style/analyzer diffs that compile fine; run the profile's
format/lint **apply** command, then its **verify** command to confirm it's clean. Heed the profile's
caveats — some analyzer diagnostics can't be auto-fixed and must be hand-corrected.

### Measuring divergence from the base (#171)

The check-runs above speak only to the head SHA — they say nothing about whether `main` has moved
since they ran. That is a separate read, and it is **not written out here**: it is one of the four
reads §4's shape block composes, and this file deliberately builds that state in exactly one place.
A second copy of the `compare` call in this file is how the `behind` / `behind_by` rename got past
review the first time.

Why it matters, which §4's block cannot say for itself: `behind_by > 0` outranks `mergeStateStatus`
in the precedence, because GitHub's own `BEHIND` state is only emitted when the base branch requires
branches to be up to date before merging. Without that rule a stale branch reports `CLEAN`, and the
check-runs recipe above still calls the head SHA green — correctly, and misleadingly, since the base
it was green against no longer exists.

### The base's own run, after the merge (SKILL.md Step 5b, #355)

Everything above points **backwards**, at the branch. The half-second after the merge is the other
direction: the merge commit is on the base, CI starts on it, and the only agent that still knows
which change to blame is this one. `dce7d5b` and `f17c85c` (2026-08-30) are what happens when it
walks away first — see SKILL.md Step 5b for the incident.

The recipe is the **same check-runs query as above**, asked about the squash sha instead of the head
sha, and fed to the same registered decision. It is not restated here — it is packaged, because a
post-merge caller also has to poll and has to map four pre-merge words onto a post-merge report:

```bash
# guarded-pr-merge.sh prints `MERGED <sha>` on exit 0; that sha is the whole input.
skills/merge-pr/scripts/base-run-verdict.sh "$BASE_SHA" \
  [--timeout <s>] [--poll-seconds <s>] [--settle <s>] [-R <owner/repo>]
# -> {"verdict":"green|red|unverified","reason":"<slug>","sha":"<sha>","runs":[{name,html_url,state}]}
#    exit 0 on every outcome; exit 64 for a usage error (no sha, an unparseable option, a
#    non-numeric bound, a malformed -R slug) OR skills/_shared/scripts/_gh-host.sh missing (#530)
```

Three things about it are load-bearing, and each is pinned by `tests/merge-base-ci/test.sh`:

- **It resolves by sha.** `gh run list --branch "$BASE"` would answer with whatever ran most
  recently, and under a merge train that is a sibling merge's run seconds later. The check-runs
  endpoint is keyed on the sha by construction, which is why §3's query is the one reused rather
  than a new `run list` call. The suite arms a deliberately wrong `gh run list` answer, so a rewrite
  that reaches for one goes red instead of quietly attributing the wrong change.
- **It reuses `ci.verdict`, and adds no second rule set.** The per-job reduction (#91) is precisely
  what the merge-train case needs: three `kit` runs on one sha, only the newest votes. `decide.sh`
  extracts that program from the marked block above, so there is one home for it and no drift (#208).
- **A cancelled latest run is a non-verdict, not a pass and not a breakage.** `ci.verdict` files
  `cancelled` under `.failed` because pre-merge it is a reason not to merge; post-merge the merge has
  already landed and a cancelled run recorded nothing about it. The helper is where those two
  meanings are separated — the shared decision is not taught a caller-specific one. `cancel-in-progress`
  (#27/#29) makes this the *routine* outcome under a fleet, not an edge case, which is why an
  `unverified` has to reach the report rather than being smoothed into a success.

- **Neither `clear` nor `no-ci` is answered on the first reading.** This runs seconds after
  `gh pr merge` returned, and GitHub posts check-runs on its own schedule, so the first reading of a
  healthy merge is routinely *nothing yet* (`no-ci`, indistinguishable from a base with no CI) or
  *only the fast jobs* (`clear`, indistinguishable from a green graph). `no-ci` is retried until
  `--settle` expires (default 90 s, clamped to `--timeout`); `clear` is taken only once the reduced
  job set matches the previous poll's — the same "wait one poll interval and re-derive" argument §3
  makes for the pre-merge gate, where the window is narrower than it is here. `failed` is answered
  at once: a job that failed does not become un-failed when a later job posts.

A timeout is `unverified`, never `red`: reporting a slow run as a breakage would file bugs against
healthy merges. And nothing in this path writes anything — no revert, no re-run, no branch touched.

---

## 4. The merge-state decision (SKILL.md Step 4)

Step 4 does not read `mergeStateStatus` and work out what to do about it. It builds one state object
and hands it to the registered decision **`merge.step4`** (#208), whose program is
`skills/merge-pr/scripts/merge-verdict.sh` and whose precedence — fourteen named rules, in order —
is written in that file's header, once.

The **shape** below is the other half of that contract, and the reason it carries markers: the
program reads seven fields by name — `behind_by`, `mergeStateStatus`, `isDraft`, `reviewDecision`,
`failed`, `pending`, `unresolved_threads` — and this block is what has to build them. They are
listed rather than counted because a bare number goes stale in silence and a list can be checked. They drifted apart once
already — a `--jq` object construction renamed `behind_by` to `behind` while the script still read
`behind_by`, so the freshness guard read `null` forever and a human reviewer, not CI, caught it
(#171 / #147). `scripts/decision-check.py` R6 now compares the two mechanically: every field the
program reads at the head of a path must be a key this block constructs, so a rename that touches
only one side is a red build rather than a guard that silently stops guarding.

```bash
# >>> decision merge.step4 shape >>>
# The thread read is its OWN statement with its OWN failure branch, deliberately not a fourth line
# inside the group below: a query that fails there contributes nothing, `unresolved_threads`
# defaults to empty, and empty reads as "no threads" — which merges. That is #294 wearing the
# fix's clothes. On a GitHub Enterprise host add `--hostname <host>`; without it this query fails
# with "Could not resolve to a Repository", and the `||` branch is what stops that reading as a
# clean bill of health.
threads=$( set -o pipefail
           gh api graphql --paginate -f query='
  query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){ repository(owner:$owner,name:$repo){
    pullRequest(number:$pr){ reviewThreads(first:100, after:$endCursor){
      pageInfo{ hasNextPage endCursor }
      nodes{ isResolved comments(first:1){ nodes{ path } } } } } } }' \
             -F owner='{owner}' -F repo='{repo}' -F pr="$PR" \
             --jq '.data.repository.pullRequest.reviewThreads.nodes[]
                   | select(.isResolved == false)
                   | .comments.nodes[0].path // "(pr-level)"' \
           | jq -Rsc 'split("\n") | map(select(length > 0))' ) \
  || { echo "merge-pr: the reviewThreads query failed — an unanswered query is not 'no threads'" >&2
       exit 1; }
state=$( { gh api "repos/{owner}/{repo}/compare/$BASE...$BRANCH" --hostname <host> \
             --jq '{behind_by, ahead_by}'
           gh pr view "$PR" --json mergeStateStatus,isDraft,reviewDecision \
             --jq '{mergeStateStatus, isDraft, reviewDecision}'
           printf '%s' "$ci" | jq '{failed: [.failed[].name], pending: [.pending[].name]}'
           printf '%s' "$threads" | jq '{unresolved_threads: .}'
         } | jq -s add )
printf '%s' "$state" | jq -e 'has("unresolved_threads")' > /dev/null \
  || { echo "merge-pr: the assembled state carries no unresolved_threads key — the read above did" >&2
       echo "  not reach it (empty \$threads, or a different shell). Do NOT decide on this state." >&2
       exit 1; }
# <<< decision merge.step4 shape <<<
verdict=$(printf '%s' "$state" | "$DECIDE" merge.step4)
```

`$ci` is §3's `$verdict`, the check-runs object. That is what gives the two decisions a real
composition instead of two unrelated reads of the same PR: the CI gate's *reduced* `failed` and
`pending` sets are inputs to the merge-state precedence, not a separate question asked afterwards.

`$BASE...$BRANCH` — three dots — gives `behind_by` relative to the base; reversing it silently
inverts the answer.

`unresolved_threads` carries the threads' **paths**, not a count — the same way `failed` and
`pending` carry job names rather than a tally, so the Step 8 recap can say *which* threads were
cleared. Only the length decides; the strings are for the human. A thread with no inline path (a
PR-level conversation) still counts, under `(pr-level)`.

⚠️ **A failed thread query must abort the state build, never yield an empty list.** This is
`decide.sh`'s own doctrine — *no verdict is not a pass* — applied one layer earlier: a failed query
and a PR with nothing open spell the same `[]`, and one of them merges unreviewed. That equivalence
is what made #294 survivable for two PRs, so the read is a separate statement with an explicit
`|| … exit 1`, and `set -o pipefail` is what carries `gh`'s exit status across the `jq` after it.

⚠️ **The `has("unresolved_threads")` assertion is not belt-and-braces — it is the only check that
survives this block being run in pieces.** `printf '%s' "" | jq '{unresolved_threads: .}'` prints
*nothing* and exits 0, so an empty `$threads` does not yield an empty list: it drops the key
entirely, and `// []` then reads that as "no threads". An agent that runs the read and the assembly
as two separate commands loses `$threads` between them and lands exactly there. The assertion
inspects the artifact actually being handed to the decision, which no amount of care upstream
substitutes for.

⚠️ **`--paginate` is load-bearing.** `reviewThreads(first:100)` sits at GitHub's page maximum, so
without it a PR whose 101st thread is the unresolved one reads as fully resolved and merges — a
fail-open of precisely the shape this section exists to close. `--paginate` needs *both* the
`$endCursor` variable and the `pageInfo` selection; drop either and it quietly fetches one page.

⚠️ **The compare read and the pr-view read are sequential and not atomic.** A sibling PR merging
between them yields `behind_by: 0` beside a merge state of `BEHIND`, which is precisely why the
program carries a `behind-state` rule as well as a `behind` one. Neither read can be made to answer
for the other, so the program answers for both.

`mergeable` is deliberately **not** fetched. Step 4 used to ask for it and nothing ever read it —
and a field that is fetched and unread is the same shape as a field that is read and never fetched,
which is the bug above.

The verdict is one of six words — `merge`, `sync`, `fix-check`, `wait`, `ready`, `review` — and
`decide.sh` has already refused anything outside that list. SKILL.md Step 4 is where each word maps
to an action; this file is where the state that produces it is built.

---

## 5. Sync with `main` and resolve conflicts (a stale branch, or `DIRTY`)

Clears a branch the corrections loop finds stale — `behind_by > 0` (§3), or a `DIRTY` merge state
(SKILL.md Step 4): merge the latest base into the branch and resolve conflicts so the PR is mergeable
again, then loop back to wait for CI (§3).

The procedure — merge-not-rebase, the union/regenerate/take-the-higher rule-of-thumb keyed off the
profile's *Conflict hot-spots* table, sourcing the other side's intent for a genuinely semantic
conflict, and finish-and-verify — is shared with `implement-issue` and lives in
[`../../_shared/sync-with-main.md`](../../_shared/sync-with-main.md). Never push a merge you haven't
at least built.

Its writes are guarded, so pass `$BRANCH`, `$WORKTREE`, `$GUARDS` and `$BASE` (SKILL.md Step 2)
through to it. Two things bite here specifically:

- **`$BASE` is `baseRefName`, not `main`.** Step 1 captures it because a PR's base is only *normally*
  `main`. Sync from the wrong one and the PR stays `BEHIND` no matter how many times this loop runs.
- **Exit 5 from `guarded-merge.sh` means conflicts — keep going, don't re-run.** It is the expected
  outcome of a `DIRTY` sync, not an error: resolve, then complete the merge with
  `guarded-commit.sh … -- -F "$MERGE_MSG"` (the `mktemp`'d `Conflicts:` message file
  `_shared/sync-with-main.md` prescribes). Re-running the merge instead gets refused (exit 2), because
  the index still carries the unfinished one.

### The fallback when the branch can't be pushed (#147)

A sync needs to push, which needs the branch checked out somewhere writable — not guaranteed: it may
sit in another agent's worktree, or this run may be pinned to a different one. #147 hit exactly this:
the branch was checked out elsewhere, so the only honest option was to verify the merge by hand rather
than push and re-wait CI.

1. Merge the base into a scratch branch in the agent's own checkout — not the PR's branch, so nothing
   is pushed and nothing on GitHub changes.
2. Run the profile's *Build & test* and *CI gates* against that merged tree, the same commands §3's
   "reproduce a red check locally" note already points at.
3. Merge (SKILL.md Step 5) only if it comes back green; otherwise stop and report the sticking point.

This is strictly stronger than a sync-and-re-wait for catching semantic breakage — it is what actually
happened by hand while landing #147 — but it moves the verdict off CI and onto the agent's machine,
which this skill otherwise refuses to do. That trade is why it is a **fallback**, not the default path,
and why SKILL.md Step 8 requires it to be named in the report as a deviation.

This fallback only covers the self-imposed staleness check (`behind_by > 0` while `mergeStateStatus`
still reports `CLEAN`) — GitHub doesn't block that merge either way. It does not cover a real
GitHub-side gate: a PR reported `DIRTY` needs its conflict resolution pushed to the real branch, and a
PR reported literal `BEHIND` (base requires branches to be up to date) needs the real branch actually
updated — `gh pr merge` won't succeed on either without that push. If the branch has no writable
checkout (not the transient sandbox push failure of Step 2/§8, which is just a retry) and
`mergeStateStatus` is `DIRTY` or `BEHIND`, that combination is a genuine blocker: stop and report it
rather than running this fallback.

---

## 6. Unresolved review threads (`blocked-changes-requested` / `unresolved-threads`)

Where SKILL.md Step 4 sends you when `merge.step4` answers `review` with either of those two rules.
§4's shape block already counted the open threads; this section is how you read and clear them.

The overall decision — useful context, **not** the gate:

```bash
gh pr view "$PR" --json reviewDecision --jq .reviewDecision   # APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | null
```

⚠️ **`reviewDecision` is empty for a `COMMENTED` review, and that is the common case.** A review bot
— GitHub's code-quality bot among them — posts `COMMENTED`, which sets no review decision and leaves
the merge state clean. Until #294 that meant its findings reached no gate at all: two PRs merged with
four and one unresolved thread on them. Read the threads, not the decision.

⚠️ **`gh pr view --json reviews` shows those bot reviews with an EMPTY `body`.** The substance is
only in the inline `reviewThreads` below. "Empty review body" must never be read as "no feedback" —
that reading is what made the merges look defensible afterwards.

Inline review comments (REST — quick read of what reviewers said and where):

```bash
gh api "repos/{owner}/{repo}/pulls/$PR/comments" --hostname <host> --paginate \
  --jq '.[] | {path, line, user:.user.login, body}'
```

Unresolved **threads** need GraphQL (REST doesn't expose `isResolved`):

```bash
gh api graphql -f query='
  query($owner:String!,$repo:String!,$pr:Int!){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        reviewThreads(first:100){
          nodes{ id isResolved isOutdated
            comments(first:1){ nodes{ path body author{login} } } } } } } }' \
  -F owner='{owner}' -F repo='{repo}' -F pr="$PR" \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false) | {id, path:.comments.nodes[0].path, body:.comments.nodes[0].body}'
```

⚠️ **On a GitHub Enterprise host `gh api graphql` needs an explicit `--hostname <host>`.** Without it
the query fails with *"Could not resolve to a Repository"* — which reads exactly like "this PR has no
threads" to anyone who does not check the exit code. Check it: an unanswered query is not an empty
answer. §4's shape block aborts the whole state build on this path for the same reason.

Fix the legitimate asks in the worktree, commit + push (project identity). Then either reply to the
thread explaining the fix, or resolve it once addressed (`THREAD_ID` from the query above):

```bash
gh api graphql -f query='
  mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' \
  -F id="$THREAD_ID"
```

**A thread has two honest exits, and the `unresolved-threads` rule accepts both.** This matters more
than it looks: the rule blocks the merge, so a gate clearable only by changing code would hang an
autonomous run forever on the first finding the agent judges wrong or cannot satisfy.

1. **Fix the ask**, push, then resolve the thread.
2. **Reply on the thread with your reasoning, then resolve it.** Disagreeing is a legitimate
   outcome of review.

What is forbidden is resolving *silently*: it clears the gate and deletes the reason. Reply first,
resolve second, always in that order — the reply is the artifact a human reads later to decide
whether the agent was right.

The goal is that no thread is left both open and unanswered — not that `reviewDecision` flips, which
for a `COMMENTED` review it never will. A required-approvals block you can't self-clear, or a thread
you can neither satisfy nor honestly answer, is a genuine blocker — surface it.

---

## 7. Discovering follow-ups in the PR

Two sources beyond the inline `--follow-up` args:

**PR body** — look for a deferred-work section:

```bash
gh pr view "$PR" --json body --jq .body \
  | grep -iA12 -E '^#+ *(follow[ -]?ups?|deferred|out[ -]of[ -]scope|future work)'
```

**Review comments that defer work** — phrases that explicitly punt to a later change:

```bash
gh api "repos/{owner}/{repo}/pulls/$PR/comments" --hostname <host> --paginate --jq '.[].body' \
  | grep -iE 'follow[ -]?up|separate (pr|issue)|in a (later|future) (pr|change)|out of scope|TODO.*(later|future)'
```

Only treat as a follow-up something **explicitly flagged as deferred** — not every `// TODO` in the
diff. De-dup against the inline args (don't file the same idea twice), then **triage** the survivors
per SKILL.md Step 6 before any of them becomes an issue.

**Find the root issue for a cluster.** Search by the *file or subsystem* the findings touch, not by
the symptom's wording — a root issue is phrased in terms of the cause ("converge the two render
paths") while its symptoms are phrased in terms of what broke ("date fields drop the adornment"), so
the two share almost no vocabulary and a keyword search on the symptom misses the very issue you want:

```bash
# root causes are usually refactors — read the open ones first
gh issue list --state open --label "type:refactor" --limit 30 \
  --json number,title --jq '.[] | "#\(.number) \(.title)"'

# then search on the file the findings land in — CLOSED ones too (see below)
gh issue list --state all --search "<TheFile> in:title,body" --limit 15 \
  --json number,title,state,url --jq '.[] | "#\(.number) [\(.state)] \(.title)"'
```

**Why this one search spans closed issues.** The findings you are triaging came out of the PR you
just merged, so they land in code a *recent fix* touched — and that fix closed its issue on the way
in. Restricted to open issues the search structurally cannot see that ancestor, so the finding files
as a sibling: `#93 → #166 (merged) → #172` is three rows for one unfinished job. Widening the state
is what makes the chain visible; `create-issue` Step 3 already spans `all` on its keyword search for
exactly this reason.

**A closed ancestor means the fix was incomplete — say so rather than starting over.** When the match
is closed and the finding is that same job resurfacing:

```bash
gh issue reopen "$ANCESTOR" \
  --comment "Reopening: #$PR closed this, but <what still fails> — \`<file>:<symbol>\`."
```

Reopen when the original scope still describes the work. File fresh only when the finding is a
genuinely *different* job in the same code — and then open its body with `Continues #<ancestor>.`, so
the lineage reads as one thread instead of N unrelated rows.

**Two ancestors deep is a scope problem, not a filing problem.** If the chain already runs
`root → fix → finding → fix → finding`, the root is mis-scoped and a fourth issue fails the same way.
That is an owner decision (hand it to `triage-backlog`), not another `create-issue` run.

**Fold an instance into that root** instead of filing a leaf — the comment carries the evidence:

```bash
gh issue comment "$ROOT" --body "Another instance, found merging #$PR: <what broke> (\`<file>:<symbol>\`)."
```

If the root issue carries an implementation-plan checklist, add the instance as a `- [ ]` item in the
body instead — those boxes drive the progress meter and `implement-issue` ticks them as it goes.

**Record — don't file — an observation** that's worth retrieving but not worth doing:

```bash
gh pr comment "$PR" --body "Noted while merging: … (recorded, not filed — no action planned)."
```

Then hand only the clusters that earned an issue to the `create-issue` skill, noting the source PR
for traceability.

---

## 8. Teardown — remove the worktree and local branch

You can't remove a worktree or delete a branch you're standing in, so the move depends on **where** the
PR's branch is checked out. Decide the case from §2's worktree listing.

### Case A — the PR's branch is in a *different* worktree (the usual case)

Move to the main checkout, remove the PR's worktree, then delete its local branch:

```bash
# Same spelling as the root recipe in §2 (one idiom, not two): `awk '{print $2}'` truncates a
# checkout under a path containing a space — measured on `/Users/x/my repo`.
MAIN=$(git worktree list --porcelain | sed -n '1s/^worktree //p')   # first entry = primary working tree
cd "$MAIN"

# Remove the PR's worktree — $WORKTREE, the path §2 recorded (force only if it has dirty/untracked
# leftovers, which a merged PR shouldn't).
git worktree remove "$WORKTREE" 2>/dev/null || git worktree remove --force "$WORKTREE" 2>/dev/null || true
git worktree prune

# Delete the local branch. -D (not -d): after a squash-merge the branch isn't "merged" in git's view,
# so -d refuses. Tolerate "not found" — gh pr merge --delete-branch may already have removed it.
git branch -D "$HEAD_BRANCH" 2>/dev/null || true
```

### Case B — the PR's branch is checked out in *this session's own* worktree

This happens when `/merge-pr` is invoked from inside the very worktree that holds the PR branch.
**Don't remove this worktree** — it's the session's live workspace, not a throwaway, and git won't let
you delete a directory you're standing in anyway. The disposable thing is the *branch*. So switch this
worktree off it (back to its prior branch, or detach), then delete the merged branch:

```bash
# A native ExitWorktree/equivalent is the harness-aware way to leave the current worktree — prefer it.
# Manual fallback: switch off the merged branch, then delete it.
git -C "$THIS_WORKTREE" switch "$PRIOR_BRANCH" 2>/dev/null || git -C "$THIS_WORKTREE" switch --detach
git -C "$THIS_WORKTREE" branch -D "$HEAD_BRANCH" 2>/dev/null || true
```

Tip: if the branch was *created* in this worktree this session (no meaningful prior branch), detaching
is cleanest. Re-fetching `origin/main` and switching to a fresh branch off it is also fine if you need
the post-merge tree (e.g. to keep working).

### Both cases

Guards matter — this step runs after the irreversible merge, so it must never *fail the run* just
because something was already cleaned up. "Already gone" is success. The **remote** branch is *usually*
gone by now — via Step 5's `--delete-branch`, or GitHub's own `delete_branch_on_merge` — but don't
bank on it: when gh's local step fails first, `--delete-branch` may never reach the remote side (SKILL
Step 5, *The exit code doesn't decide*). gh leaves the **local** side untouched when the branch is
checked out in a worktree (you'll see `failed to delete local branch … used by worktree` or `'main'
is already used by worktree`), which is exactly why this step exists.

**Confirmed, not assumed (#185):** reading gh's own `mergeRun` (`pkg/cmd/pr/merge/merge.go`,
`cli/cli@trunk`) shows `deleteLocalBranch` runs before `deleteRemoteBranch`, and the first error
short-circuits the rest — the local-worktree failure above *is* that first error on this kit's usual
layout, so the remote delete is skipped, not merely delayed. And `delete_branch_on_merge` is `false`
by GitHub's own default; a repo the profile targets may not have turned it on the way this one has.
So finish the job here instead of assuming either mechanism reached it:

```bash
skills/merge-pr/scripts/remote-branch-teardown.sh "$HEAD_BRANCH" "{owner}/{repo}"
```

It runs `git ls-remote --heads origin <headRefName>` and, only if the branch is still there, `gh api
-X DELETE repos/{owner}/{repo}/git/refs/heads/<headRefName>` — tolerant of the same race gh's own
`deleteRemoteBranch` tolerates (a 422/404 "Reference does not exist" from a concurrent
`delete_branch_on_merge` or a slow `--delete-branch` winning first). It always runs this check
regardless of the repo's `delete_branch_on_merge` setting: that value is read from a profile
snapshot that can go stale between refreshes, where a wrongly-trusted `true` would leave a branch
leaked forever, against the cost of one extra `ls-remote` call when it is genuinely `true`. Prints
`already-gone` or `deleted` and exits 0 either way; a genuine API failure exits 1 with the error —
report it, don't swallow it (§9).

**Safety:** never remove `$MAIN` or a worktree whose branch isn't the PR's head. Match the path to the
branch (via §2's listing) before removing — a wrong `git worktree remove --force` throws away someone
else's in-progress work.

---

## 9. Troubleshooting (error → cause → solution)

| Error | Cause | Solution |
|---|---|---|
| `Failed to connect to github.com port 443` on `git push`/`fetch` while `gh` works | Sandbox blocks raw git network traffic (not an outage — `gh` proves the host is reachable) | Re-run just that command with the sandbox disabled; local git (merge, commit, worktree remove, branch -D) needs no network |
| `fatal: '<base>' is already used by worktree at …` — a non-zero exit from `guarded-pr-merge.sh` | `gh pr merge` merges on GitHub and *then* checks the base branch out locally; git refuses because another worktree — normally the primary checkout, sitting on `main` — already holds it. One exit code covers both halves, so it cannot say which one failed | **Don't read this as a rejection** — it is local cleanup. `guarded-pr-merge.sh` already reads the PR back and decides on `state` for you (exit 0 = MERGED regardless of this message, per SKILL Step 5); let Step 7 tidy up. Step 7's **Case B** is this very collision one step later — same base branch held elsewhere, the feature branch instead of the base |
| `failed to delete local branch … used by worktree` after the merge | `gh pr merge --delete-branch` can't touch a branch checked out in a worktree | Expected — that's what Step 7 handles: remove the worktree, then `git branch -D` |
| `git branch -d` refuses: "not fully merged" | After a squash-merge the branch isn't "merged" by git's reckoning | Use `-D` (force) — the squash commit on `main` carries the work |
| `mergeable=UNKNOWN` right after `main` moved | GitHub is recomputing the merge state | Not a blocker — re-poll shortly; nudge a main-sync only if it persists |
| Commands act on the wrong checkout | A `cd` in a compound command gets reset between tool calls | Use `git -C <path>` / absolute paths — especially the teardown, which must run against `$MAIN`, not the worktree being deleted |
| `guarded-merge: CONFLICTS on <branch>` (exit 5) | **Not an error** — the expected outcome of a `DIRTY` sync. HEAD is still your branch and the conflicts are in the working tree | Resolve per the rule-of-thumb (§5, sourcing the other side's intent for a semantic one), then **complete** the merge: `guarded-commit.sh … -- -F "$MERGE_MSG"`. To walk away instead, `guarded-merge.sh … -- --abort` |
| `guarded-merge: REFUSED — the index … already carries an UNRESOLVED merge` (exit 2) | A previous sync stopped at exit 5 and was never finished; git refuses a second merge on an unmerged index (its own exit 128) | **Nothing merged.** Finish the one in flight (resolve + `guarded-commit … -- -F "$MERGE_MSG"`) or abandon it (`-- --abort`), then sync again |
| `guarded-commit.sh: No such file or directory` in the corrections loop | `$GUARDS`/`$WORKTREE`/`$BRANCH` were never recorded — Step 2 deferred the worktree and Step 4 created one without setting them | Record all four names (Step 2's block) at the point the worktree appears, then re-run the correction |
| `guarded-*: REFUSED — HEAD is on 'X' but this task owns 'Y'` (exit 2) | Prevention working: the corrections are being run from the wrong checkout | **Nothing was written.** Move to the PR branch's own worktree (§2) and retry — never "just commit anyway" |
| `remote-branch-teardown: failed to delete origin/<branch>: …` (exit 1) | The remote branch survived the merge (Step 5's `--delete-branch` never reached it, and `delete_branch_on_merge` is off or didn't fire) and the DELETE call itself failed for a reason other than "already gone" — permissions, rate limit, network | **Not tolerable — a real leak, not a race.** Read the API error, fix what it names, and re-run `remote-branch-teardown.sh` with the same two arguments; it's idempotent (an already-gone branch on retry is just another `already-gone`) |
| `remote-branch-teardown: usage: … <head-branch> <owner>/<repo>` (exit 2) | Called without both arguments — a script/prerequisite error, not a merge or teardown failure | Supply `$HEAD_BRANCH` (§2 already resolved it) and `{owner}/{repo}` (this file's own `gh` placeholder, top of file — resolved from `origin`) and re-run |
