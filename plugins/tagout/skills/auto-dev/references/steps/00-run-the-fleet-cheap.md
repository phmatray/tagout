## Token economics — run the fleet cheap

A long run's cost is **~83% per-turn context cache-read, ~16% output** — you pay for *context volume ×
turns*, not for thinking. Apply these rules; full rationale + measurement in
[references/token-economics.md](../token-economics.md).

> **Measured on a real 19-merge run (a .NET/Blazor repo, N=3):** 224 turns/session · context
> 30K → 350K · **181K average context per turn** · **0.55 tool calls per turn**. Cache-read was
> 98.3% of tokens. The run's session and token totals are in
> [references/token-economics.md](../token-economics.md) — **37 sessions / 656M tokens**,
> the accounting two scripts reproduce today. An earlier scan of what is described as the same run
> recorded *21 sessions / 863M tokens*; its tool and scope were not written down, the transcripts are
> no longer on any machine that was checked, and the two do not reconcile in either direction, so
> that figure is **unverifiable and not quoted as this run's** (#386). Cost = **Σ over turns of context size**, so late turns cost
> ~10× early ones and *turn count is superlinear* — it drives both factors at once. Rank levers by
> that, not by intuition.
>
> **That headline counts *worker* sessions — and the orchestrator was a third of the bill.** Folding
> the supervisor's own transcript into the same rollup: one session, 551 assistant messages, **~210K
> average context per message, 33% of the run's list-equivalent cost** — more than every top-tier
> worker session combined — and it **never compacted once** across all 19 merges. Worker spend is
> skewed the same way: **the top 3 of 37 worker sessions were 32% of all worker cost**, and the worst
> was an `effort: medium` issue on the mid tier, so neither label nor tier predicted it. Both
> measurements, and the two counted budgets that bound them, are in
> [references/token-economics.md](../token-economics.md) § *Session length*.

**1. Split each worker into two sub-agents: implement, then merge** — **the one lever that measurably
worked. A/B verified, ~11% of all worker tokens.** Phase 1 (`/auto-dev-worker <N>`) stops at a ready
PR; phase 2 (`/auto-dev-merge <PR>`) lands it in a fresh context.

| merge phase | turns | avg ctx/turn | cacheRead |
|---|---|---|---|
| **before** (18 workers, inside the implement session) | 27 avg | **247K** | **6.6M** per worker |
| **after** (v2 phase 2, fresh session) | 24 | **71K** | **1.7M** |

Near-identical turn counts, so per-turn context is the whole difference: **−74% on the merge phase**,
≈11% of total worker spend. Pass the PR number between phases via a file the phase-1 prompt names
(fall back to parsing the report line, then `"<kit>/scripts/tracker.sh" pr-list --head <branch>`). Bonus: both post-completion wedges
observed in the baseline run happened in the *late* turns of a long session — shorter sessions wedge
less.

**2. Tool-call batching — TRIED AND IT DID NOT WORK. Don't expect a win here.** A hard batching rule
with examples was added to the worker prompt and A/B measured: density went **0.556 → 0.537** calls
per turn (phase 1) — i.e. no change. Keep the rule (it costs nothing) but do not budget savings for it.
The diagnosis: density below 1.0 does **not** mean calls that *could* be batched aren't. ~45% of turns
make **no tool call at all** — they are reasoning/narration turns — and most of the rest are genuinely
sequential (edit → build → read error → fix). The recoverable waste is *turns that produce no tool
call*, which is an output-verbosity problem, not a batching problem. If you attack this, attack
verbosity (thinking length, narration between steps), and measure calls/turn to check you moved it.

**3. Keep big command output out of context** — *measured 4,262 tokens → ~2 per full test run*. Full
`dotnet test` output is ~17K chars and is re-read on every later turn. Mandate: log to a **file**, put
only `EXIT` + counts in context, grep the file only on failure. Explicitly forbid piping the command
through `tail`/`head` — that truncates the *evidence* while still costing turns.
*Honest scope:* the per-run reduction is exact and verified, but the aggregate win depends on how often
a worker runs the suite. Largest single Bash result fell 25.2K → 10.5K chars in the A/B, while total
tool-result volume per turn barely moved (722 → 710 chars) — because the A/B issue was a docs task that
rarely runs tests. Expect the real payoff on test-heavy issues.

**4. Tier the model to the task** — real but **tier-dependent**, per [token-economics.md](../token-economics.md):
**weak between mid and small** ($0.419/Mtok vs $0.168/Mtok ≈ 2.5×);
**strong between top and mid** ($2.376/Mtok vs $0.419/Mtok ≈ 5.7×).
Worth prioritizing for cross-cutting work; less impactful for routine bugs. Route by issue labels
(adapt names to the runtime's small/mid/top trio, e.g. Haiku/Sonnet/Opus):

| Issue shape (by label) | Tier |
|---|---|
| docs/templates/manifest, format & snapshot regen, `priority:low`+`effort:S` one-line guards | **small** (e.g. Haiku) |
| most bugs: emitter/validator/parser guards, studio TS, CLI, LSP — `effort:S/M`; large issues by default | **mid** (e.g. Sonnet) |
| a lower tier failed to green this issue | **top** (e.g. Opus), reactive escalation (once) |
| cross-cutting (many areas/emitters), ambiguous/design — work a maintainer knows is hard | **top** (e.g. Opus), predictive last resort |

The orchestrator (you) stays on the top model, but keep its *per-turn context* small (lever 2).

**5. Shrink what's re-read every turn.**
- **Trim the fixed preamble** — it is paid on *every* turn of *every* worker. `CLAUDE.md` at 44KB (~11K tok) cost **52M tokens in one run from a single file**; move deploy/secrets/kubectl reference material into linked docs and leave a pointer.
- **No per-issue TaskList** — it grows unboundedly and re-injects every turn. The **state file is your only working memory.**
- **Bound the context through the harness — no model can run the compact command itself.** No tool
  runs it; a built-in slash command executes only when a user types it. The context bound has one home,
  [references/token-economics.md](../token-economics.md) § *The two budgets* (the harness's
  own `autoCompactWindow` threshold) — do not restate the number here, `tests/auto-dev-cost-budgets/test.sh`
  fails the build if you do. First action after any compaction / `/clear` / `loop` re-fire: **re-read
  the state file.**
- **Keep worker FINAL REPORTs terse** — they're re-read on every later reconcile turn.
- **Delegate heavy reads to throwaway `Explore` sub-agents** — the file-dump dies with the sub-agent instead of riding your context.
- **Launch the SUPERVISOR session lean** — sub-agents inherit the supervisor's MCP set, so every
  server connected to *your* session rides every turn of every worker. Per-worker MCP stripping is
  no longer available (the Agent tool has no per-spawn MCP config); trim it once, where you launch.

**6. Take fewer turns** (each round-trip re-reads the whole context).
- **Batch independent tool calls** into one turn (parallel reads/greps/`gh`).
- **Let scripts collapse query+classify** — `scripts/survey.sh`, `scripts/reconcile.sh`.
- **Don't poll on a short cadence** unless a merge is imminent — a needless wake re-reads everything, and one past the ~5-min cache TTL pays a full cache *write* (1.25×), not a read (0.1×).
- **Bound the session, not just the turn.** Batching was A/B'd and did not move (lever 2), so per-turn
  optimisation is close to exhausted and **session length is the variable that is left** — the top 3 of 37
  worker sessions were 32% of all worker cost, and neither the effort label nor the tier predicted which
  three. Phase-1 workers therefore carry a **turn budget** (the integer lives in
  [references/token-economics.md](../token-economics.md) § *The two budgets*, not here) and hand off
  at it with `STATUS: PARTIAL`; Step 4 resumes them in a **fresh** sub-agent, which is where the saving is —
  a `SendMessage` resume keeps the context the budget exists to discard. This is lever 1's mechanism, the
  section's one verified win, applied at a *length* seam instead of a *phase* seam.

**Measure it** — never claim a lever works without an A/B. Three scripts, all taking a directory of
session `.jsonl` transcripts:
- `scripts/usage_report.py` — tokens + $-equivalent by model. Track **tokens/merge** and **$/merge**.
  ⚠️ It aggregates the WHOLE project dir including past runs — symlink one run into a temp dir
  first, **keeping the layout**: the supervisor session's `<sid>.jsonl` plus its `<sid>/subagents/`
  directory (`<proj>/<sid>/subagents/agent-*.jsonl` is where every worker transcript lives, so one
  run's fleet sits under one id — pick the id from the state file or `gh` timestamps; **mtime is
  unreliable**). A flat pile of `agent-*.jsonl` symlinks reads as `0 sub-agent` and pairs nothing.
- `scripts/analyze_cache.py` — turns/session, context at start vs peak, avg context per turn, and
  tool-result volume by tool. This is where you see *why* a session is expensive.
- `scripts/measure_phase2.py` — pairs each issue's phase-1 and phase-2 sub-agent transcripts (by
  the `ISSUE:` of their report lines) and splits cost into implement-phase vs merge-phase; on a
  pre-2.0 transcript it finds the in-session merge handoff turn instead. This is what proved lever 1.

Two metrics carry most of the signal: **avg context per turn** (are late turns bloated?) and
**tool calls per turn** (are turns doing any work at all? baseline ~0.55 — see lever 2).
