## Step 4 — Supervise (the loop)

**A worker-toplevel guard REFUSE (Step 3) is handled the moment it's seen, not folded into the
per-slot outcomes below.** It fires right after dispatch, before the worker has done anything a
per-slot outcome could apply to: stop that sub-agent, re-dispatch it correctly (with `isolation:
"worktree"` actually applied this time), and never record the issue as BLOCKED for it — it is a
dispatch defect, not something wrong with the issue or the worker's work.

You're woken by a worker's report, an **idle notification**, or your heartbeat. On every wake,
**reconcile against GitHub** — never trust a worker's silence or even its "done" without checking. Run
`scripts/reconcile.sh` (one call: open PRs with draft/ready + `mergeStateStatus`, plus the last 10
merged) rather than re-typing the gh queries each tick. Three verbs apply to a slot, and which one
depends on whether its sub-agent is **still running** or has **returned** (its report arrived):

- **Retire** a slot — MERGED and cleaned, BLOCKED/FAILED after escalation, or a takeover — by
  stopping its sub-agent explicitly (`TaskStop`) **if it is still running**; one that already
  returned has nothing left to stop.
- **Message** a slot whose agent is still running — a real `SendMessage` to that live agent.
- **Re-dispatch** when the agent has returned — a fresh Agent spawn in Step 3's form. A returned
  deferral cannot be messaged: it returned.

Then, per slot:

- **Reported MERGED** (GitHub agrees) → before refilling, read the worker's `WORKTREE` field from its
  final report line. `merge-pr`'s own Step 7 is documented as tolerant of partial local cleanup (e.g.
  `git worktree remove` needing `--force` on a dirty leftover, or a `git branch -D` racing something
  else), so a worker can honestly report `STATUS: MERGED` alongside a `WORKTREE` value that isn't
  fully cleaned up — and a **missing** `WORKTREE` field is treated the same way, as non-clean, never
  as evidence of success. If it reads as fully cleaned up — worktree and branch gone, whether removed
  by this run or already absent (`merge-pr` Step 7 treats "already gone" as success too) — proceed
  exactly as before: **retire the slot** (a phase-2 agent that reported MERGED has returned — no
  shutdown needed; stop it only if it is somehow still running) and **refill the slot** —
  pick the next queued issue whose area isn't currently held, dispatch a fresh worker (Step 3). Keeps
  the fleet at N. Otherwise, add a line to the state file's `## Needs manual sweep` section naming the
  issue, PR, and the `WORKTREE` text verbatim — then **still end the agent and refill the slot
  regardless** (the same retirement as above — stop it only if it is still running): the PR is merged, only local cleanup is outstanding, and nothing about that blocks the
  fleet. Either way, the issue still moves to `## Completed` right away — unlike the takeover bullet
  below, nothing here re-dispatches a sub-agent to close the gap, so there is no future report to defer
  that entry for; `## Needs manual sweep` tracks the outstanding local housekeeping separately, it
  does not gate `## Completed`.
- **Idle, but PR is READY and unmerged** → it stalled at "ready" — unless the PR sits under `## Held for owner`, which is a one-way door held on purpose (Step 3): never re-drive that one. **First check whether CI was still pending when you dispatched it** — if so this is your dispatch-timing bug, not the worker's: run `scripts/wait-ci.sh <pr>`, then re-dispatch phase 2 with the finished check table inline (see *NEVER dispatch phase 2 while CI is pending* in Step 3). Re-dispatching into the same pending CI just loses another sub-agent. Otherwise, `SendMessage` the live agent — or, if it has returned, dispatch a fresh phase-2 sub-agent — to run `merge-pr <PR>` now and not idle until merged. `mergeable=UNKNOWN` is usually a transient recompute after `main` moved — its `merge-pr` will sync and resolve; nudge a main-sync if it persists. If a worker idles at "ready" **twice** with CI already final, take over: run the kit's
`<kit>/skills/merge-pr/scripts/guarded-pr-merge.sh <PR> -- --squash --delete-branch` and decide the
slot's fate from its exit code, never from a bare `gh pr merge`'s (this kit's normal layout — the
worker's `implement-issue` worktree still holding the head branch while the supervisor sits on
`main` — makes gh's own local-cleanup half fail routinely, on a merge that landed regardless). If
that call is refused (an agent confined to its worktree, the path resolving outside it), see the
fallback in [`_shared/guard-invocation.md`](../../../_shared/guard-invocation.md). What
each code means is the script's own header comment and `merge-pr` SKILL.md Step 5's table (#184) —
one home, not restated here — but what **auto-dev** specifically does with each outcome is:
`0` (MERGED) → retire the slot and refill it (same as any other retirement, right away — don't
wait on anything below to do this part). **Separately**, dispatch a cleanup sub-agent the way Step 3 spawns phase 2 —
`Agent(model: <small tier>, run in background, prompt: "Invoke `auto-dev-merge` with args `<PR>`. …")`
(cheap tier: there is no blocker left to clear, only follow-up triage and teardown; the rest of the
spawn form is Step 3's, not restated here). This sub-agent holds no area and is **not** one of the
fleet's N worker slots — it is supervisor-owned plumbing,
the same as the takeover step itself, so running it alongside a freshly-dispatched replacement
worker is not the N+1 exception reserved for Large issues below; nothing needs to converge back.
Its `merge-pr <PR>` call runs into that skill's own Step 1 resume contract, which sees
`state == MERGED` and routes straight to Steps 6-7 — follow-up triage, then the worker's
`implement-issue` worktree/branch teardown — so it can never attempt a second merge; it only
finishes the half `guarded-pr-merge.sh`'s own header comment explicitly leaves to the caller.
Recognize it's done from the same structured report line every phase-2 worker already emits
(`ISSUE: … | PR: … | STATUS: MERGED|BLOCKED|FAILED | … | WORKTREE: … | BASE: …`), and only then move this
issue's `## Completed` line — the slot was already refilled, but the entry isn't truly closed
until that report confirms the local half landed too. If the cleanup sub-agent fails or times out,
don't block the fleet on it: `merge-pr` is resume-safe, so treat it like any other stalled
dispatched sub-agent (Step 4's own reconcile loop already re-derives real state from GitHub rather
than trusting an agent's silence) and just re-dispatch the same call next heartbeat — the PR
itself stayed merged regardless, only the local teardown is still outstanding. `1` (QUEUED) → leave the slot held, do not
retry the merge, re-check next heartbeat. `2` (REJECTED) or `3` (CLOSED) → a real problem the
takeover didn't cause and can't fix by retrying — leave the slot held (do **not** refill it; the
issue isn't actually done), surface it to a human, and don't dispatch a fresh worker onto it until
it's resolved. `4` (UNCONFIRMED) → leave the slot held and re-run the takeover next heartbeat
instead of guessing.
  - **Alive vs returned.** `SendMessage` reaches a sub-agent that is still running, with its context intact. One that has returned **cannot be messaged** — its run is over, and a returned deferral is not a paused agent — so "message it" becomes *dispatch a fresh sub-agent*. Either way a correction is a **tail prompt**: state what is already done and must be kept, the one thing to change, then the finish sequence. Do not re-run `implement-issue` from scratch and lose good work.
- **Idle with a draft PR whose plan checkboxes are all ticked, and a deferral-shaped final line** → this is a phase-1 worker **killed by an in-worker wait**, not stalled work. It dispatched a subagent or background command (a code-review pass still consolidating, a golden-suite run) and ended its turn to await it — and a sub-agent that ends its turn has returned, not paused; the deferral arrived as its report. Recognize the signature from the PR itself and the idle notification (**never the raw transcript file** — same rule as above): **every task's plan checkboxes ticked** `[x]`, and the worker's last visible message reads as a deferral (the forbidden shapes are *"I'll pause here and wait for..."*, *"I'll pick this back up automatically once it completes"*, *"I'll stop issuing further tool calls now and wait"*). This is a supervisor judgment call, not a string match to over-fit a regex to — "wait" used in an unrelated, non-deferring sense does not count. **Recover with a tail prompt, never a restart** — re-running `implement-issue` re-plans from scratch and can redo or conflict with already-committed work. The agent has returned, so the tail prompt goes into a fresh dispatch (Step 3's form, same tier). State what is already done (read off the PR body/commits), give only the finish sequence (e.g. "the review that was running has since finished, its findings are below — apply them" / "confirm the suite's actual result and proceed"), and forbid waiting again.
  - **All checkboxes ticked but no deferral-shaped line at all — e.g. the worker went silent or was cut off** → treat it the same way. A draft PR with every task done and no `PHASE1 | …` report line ever emitted is itself the load-bearing signal; the deferral phrasing is confirmation, not a requirement. Don't leave a finished worker in the generic "still implementing" bucket below just because its last line doesn't quote-match.
  - **Mid-implementation, not all boxes ticked** → same recovery shape, but read "what's already done" off the boxes actually ticked and the latest commit — do not assume the plan is complete; the tail prompt names exactly which task is next.
  - **What it was waiting on genuinely failed** (a real CI/test failure, not merely something slow) → check the actual check/test state yourself before writing "just finish" — the tail prompt must resume investigation of the failure, not tell the next session to declare victory over a red bar.
- **Idle with a draft PR / no PR yet** → still implementing; leave it. If long with no progress, `SendMessage` a one-line status ping (don't read its transcript). If it has been grinding for a long time and the ping confirms it is still mid-implementation, spend one more `SendMessage` to **invoke the turn budget explicitly** — *"you are past the turn budget: take on no new scope, finish the task in hand to green, push, and report `PARTIAL` naming the boxes you did not reach"*. This is the one supervisor-side cost lever the pre-2.0 process-per-worker substrate could not offer, and it costs you a single turn. It is a judgment call on elapsed time and silence, **not** a measurement: you cannot see a worker's turn count without reading its transcript, and that costs exactly the money the budget is saving.
- **Reported PARTIAL** → the worker hit its **turn budget**
([references/token-economics.md](../token-economics.md) § *The two budgets*) and handed off.
**Nothing is wrong** — this is not `BLOCKED`; the budget simply ran out. Its tree is green, its
commits are pushed, its draft PR is open, and its `DETAIL:` names the plan checkboxes it did not
reach. **Do not retire the slot and do not move the issue to `## Completed`.** Dispatch a **fresh**
phase-1 sub-agent against the same issue at the same tier, in Step 3's form: `implement-issue`'s own
Step 4 resume contract re-enters the existing branch and PR and starts again at ~30K context, which
is the entire saving. It has to be a fresh dispatch — a `SendMessage` would resume the agent *with
the context the budget exists to discard*, so the hand-off would have cost a turn and saved nothing
(and the agent has returned anyway; a returned sub-agent cannot be messaged). Record the phase as
`PARTIAL ×<k>` in the state file so a `loop` re-fire can reconstruct it, and **cap consecutive
resumes at 3**: a fourth means the issue is genuinely stuck rather than merely long, so surface and
retire it on the BLOCKED path below instead of resuming again — but **skip that path's tier
escalation**. A budget exhaustion is by construction a *length* failure, not a "the model wasn't
strong enough" one; this run's own outlier was an `effort: medium` issue that succeeded on the mid
tier and simply took 434 turns, so promoting it to the top model would put the fleet's most
expensive issue on its most expensive tier for no reason.
- **Reported BLOCKED with `DETAIL: pushed <sha>, CI restarted`** → not a block: the phase-2 worker had to push (conflict, re-sync, fix) and stopped instead of waiting (#478). Run `scripts/wait-ci.sh <pr>`, then re-dispatch phase 2 with the finished check table inline. Never tier-escalate it.
- **Reported BLOCKED with `DETAIL: branch-held guard: …`** → not a block on the issue: the worker woke in a fresh tree while an earlier tree still held its PR branch, so this dispatch skipped (or raced) Step 3's release guard (#510). Run `scripts/release-branch.sh <pr-branch>` and act on its verdict exactly as that guard says: on `FREE`/`RELEASED`, re-dispatch the **same** phase at the **same** tier — never tier-escalate it (a stronger model meets the same held branch) and don't count it against the `PARTIAL ×3` cap (nothing was attempted); on `HELD`, record the line under `## Needs manual sweep` and retire the slot.
- **Reported BLOCKED with a `BLOCKED_BY:` field naming an issue or `replan`** → write the verdict back as a native hold instead of guessing at a fix, so the next survey honours it rather than a re-dispatched worker re-finding the same block from scratch. **Never tier-escalate a `BLOCKED_BY` report of either shape** — a stronger model reading the same open prerequisite or the same disproven plan changes nothing.
  - **`BLOCKED_BY: #a[,#b]`** (prerequisite-blocked) — first check each named issue is still OPEN (`gh issue view <n> --json state`); one already closed holds nothing, so drop it from the list. A lookup that errors outright (bad number, transient API failure) is not a CLOSED verdict — treat it the same as a `wire-edges.sh` failure below: surface it and fall through to the generic bullet rather than guessing. None left open → treat the row as `BLOCKED_BY: none` below instead. For the open ones, call `skills/create-issue/scripts/wire-edges.sh --repo <owner>/<repo> --child <issue>:blocked-by=<open ones>` — its parent-less mode (#511): this issue is being held, not decomposed, so there is no `--parent`. A multi-blocker call prints one `DEP` line per blocker, and they can disagree, so read each line's own verdict rather than the call's exit code alone: every one `ok`/`ok (already wired)` → every blocker is wired natively; add a line to the state file's `## Held on a prerequisite` section naming the issue and its blocker(s). Any `fallback` among them (the host's `blocked_by` dependencies API is off — a 404) → nothing durable got written for that blocker (no edge, no `**Blocked by:**` body line — this call never touches the issue body), so add the line anyway but mark the whole entry `fallback`, and flag it in the Step 6 recap: this hold is good for **this run only** and will simply re-queue as eligible the next time `survey.sh` runs, whatever the blocker's state. Either way (all `ok`, or a `fallback` mixed in), retire the slot. Any `FAILED` line, or the call's own exit 1 (a real failure — a cycle, a cross-repo refusal) → surface it and record/retire exactly as the generic BLOCKED/FAILED bullet already does — do **not** add a `## Held on a prerequisite` entry for a call that never wired anything.
  - **`BLOCKED_BY: replan`** — the plan itself is disproven (already attempted and failed, assumes work that does not exist, or is otherwise unimplementable as written); only a person re-planning it can unblock it. Run `gh issue edit <issue> --add-assignee @me` so `survey.sh` holds it as `deps=assigned` until a person re-plans and unassigns; on success add a line to `## Held on a prerequisite` and retire the slot; if the assignment itself fails (the operator login can't be assigned), surface that `gh` error and retire the slot exactly as the generic BLOCKED/FAILED bullet does.
- **Reported BLOCKED/FAILED with `BLOCKED_BY: none`** (or no `BLOCKED_BY:` field at all — an older
  worker's report reads the same way) → first **tier-escalate if it was on a lower model**: if the
  failure looks like the model wasn't strong enough (rather than a genuine hard blocker —
  un-mergeable conflict, missing approval, no plan), re-dispatch the *same* issue **once** on the top
  model. If already on top, or it fails again → record it, surface it, retire the slot (it
  reported, so it has returned — nothing to stop), refill the slot (don't let one blocked issue
  stall the fleet). This escalation is what makes cheap-by-default tiering safe.

After any change, update the state file (in flight, completed, filed, queue).

**Merge sequencing for same-area PRs.** If two workers' PRs touch the same area, let them land one at a
time — the second's `merge-pr` will sync the freshly-moved `main` and resolve. Don't block; just expect
a transient conflict and re-nudge if needed.

**Re-survey the backlog every ~5 merges — the queue is NOT static.** Every PR you land tends to spawn
more issues: `merge-pr` files deferred work as follow-ups and workers file off-scope discoveries. So
the open-issue set *grows as you drain it*, and newcomers are often small and in areas your current
workers don't hold — exactly what breaks a same-area logjam. Re-run the Step 2 survey roughly every 5
merges (or sooner if refills cluster into one area or the queue looks empty), fold newcomers in (small-
first, area-tagged, eligibility-checked), and note what changed. Keep a **merge counter** in the state
file (record the count at the last refresh) so a `loop` re-fire knows when the next refresh is due.

**The harness compacts you — you don't compact yourself.** No model has a tool that runs it; a
built-in slash command fires only when a user types it, so the supervisor's context is bounded instead by the
`autoCompactWindow` threshold read at Step 1
([references/token-economics.md](../token-economics.md) § *The two budgets* — `CONTEXT
BOUND`, not restated here). The one standing rule: the first action after any compaction / `/clear` /
`loop` re-fire is to **re-read the state file** — that is what turns a reset into a clean base
instead of amnesia. A compaction landing mid-dispatch is not a new hazard — Step 3's dispatch-time
guard exists precisely because one can land between dispatching a worker and recording it.

**Re-survey at once — not at the next ~5 — when a merged issue's row carried `blocking=`.** That
issue was holding its blockees, and they entered the frontier the moment it landed. Waiting out the
usual counter leaves them held and up to N-1 slots idle, which on a small backlog is the whole
fleet. Same for an issue you see get unassigned. The `deps=` column is what tells you which merges
are worth an immediate refresh and which are not.

**Report the pressure, don't act on it.** At each re-survey, note two numbers since the run started:
issues **closed by merges** and issues **filed by the fleet**. When filings meet or exceed closes, the
run is treading water — the fleet is converting one queue into another, and no amount of parallelism
fixes that. Say it in the next report (*"12 merged, 13 filed — the queue is not draining"*) and let the
owner decide; the fix is a triage pass (`triage-backlog`) or a rescoped root, and both are decisions
that belong to them. Don't respond by suppressing filings — a worker that silently drops off-scope
finds breaks the guarantee that makes the backlog truthful, and trades a visible problem for an
invisible one.

**Keep your own context lean** (Token economics lever 5): the state file is your only working memory
(**no per-issue TaskList**), worker reports stay terse, and you **compact on the counted cadence** — the
merge-counter check in this step's per-wake bookkeeping above, whose integer lives in
[references/token-economics.md](../token-economics.md) and is deliberately not restated here.
