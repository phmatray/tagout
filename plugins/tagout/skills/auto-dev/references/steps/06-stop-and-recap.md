## Step 6 — Stop & recap

Close with the shared recap shape — [`../_shared/recap.md`](../../../_shared/recap.md). It owns the four
blocks (verdict · **What happened** · **Artifacts** · **Assumed · skipped · unverified**, where
`None` is a required answer rather than an omission) and the **Next** line, which is read off this
skill's row in that file's hand-off table instead of being decided again here. Everything below is
only what **auto-dev** adds on top of them.

Stop dispatching when the eligible queue is empty (or the user says stop). Let the in-flight workers
finish and land, retire them, then summarize: issues merged (with PR numbers), follow-ups filed, anything
blocked or skipped (with reasons), what remains (e.g. held L/XL items), a `base health unchecked for
N merges` line whenever the board carries one (#479), and any `## Needs manual
sweep` entries still on the state file — that section has no automated reader anywhere else in this
skill, so the final summary is the only place a human reliably sees a leftover worktree/branch before
the state file is discarded. Also name any `## Held on a prerequisite` entries: an `edge ok` or
`replan` entry clears itself once its blocker lands or a person re-plans and unassigns (`survey.sh`
picks it back up as `QUEUE` on its own), but a `fallback` entry wired nothing durable and will
re-queue as eligible on the very next survey regardless — call those out by name, since this
summary is the only place anyone sees that before the file is discarded. Name every
`## Held for owner` PR too, each with Next `/merge-pr #<pr>`: a one-way door, or a merge the
profile reserves for the owner, that the fleet deliberately did not land, and the stop gate does not count it as undrained.

**Remove the state file** at its pinned path (Step 2) once the queue has fully drained — `rm -f
"${AUTODEV_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}/tagout/auto-dev/<host>/<owner>/<repo>.md"`
— and its counts with it, after quoting them: `scripts/fleet-counters.sh "$STATE_FILE" summary` for
the totals this recap reports, then `scripts/fleet-counters.sh "$STATE_FILE" clear`.
This is what `hooks/autodev-stop-gate.sh` (#417) reads as "no fleet is running here": its positive
evidence is the file's presence, so leaving a drained fleet's file behind would leave the gate
believing work is still undrained the next time a session tries to stop in this repo. Don't remove it
on a mid-run stop (the user says stop while workers are still in flight) — only once the drain above
is actually complete.

**Boundary findings** — the shared block ([`../_shared/recap.md#the-boundary-findings-block`](../../../_shared/recap.md#the-boundary-findings-block)), collected from the workers: every `DETAIL:` field
that reported a passage failing the boundary goes in this summary, by issue number, or `None`. A
worker's report line is the only part of its session anyone reads, and this summary is the only
place those lines are aggregated — so a finding that stops here is a finding nobody ever sees.

**Cost accounting.** Run `scripts/usage_report.py <project-transcript-dir> --main <orchestrator-session-id>`
to aggregate tokens + $-equivalent across the orchestrator and every worker, broken down by model.
Report **tokens/merge**, **$/merge**, and **orchestrator share of total**.

⚠️ **A supervisor running in a git worktree writes its transcript to a *different* project directory
than its workers.** The transcript dir is keyed off the working directory, so a fleet whose workers
run from the main checkout while the supervisor sits in `…/.claude/worktrees/<branch>` is split
across two of them — and the naive single-directory invocation then reports **worker cost only**,
silently, with the orchestrator's share simply absent from a total that looks complete. This skill
already warns that a worker's transcript dir differs from the checkout; the supervisor's own does
too, and that is the half that goes missing. Point the script at **both** (symlink the supervisor
session's `<sid>.jsonl` *and* its `<sid>/subagents/` directory into the one temp dir, keeping the
layout — the ⚠️ under *Measure it* in Token economics has the recipe), then read the header's
`SESSIONS: N … (X top-level, Y sub-agent)` line back and check it against the fleet you actually
ran.

**Orchestrator share is a first-class number, not a curiosity.** It was **33% in one measured run,
from a single session** — the largest single cost centre in the fleet, more than every top-tier
worker combined. Report it explicitly; when it comes in materially above that, the finding is that
Step 4's counted compaction cadence did not fire often enough, and the cadence in
[references/token-economics.md](../token-economics.md) is what to re-measure and move. (Auto-detects the transcript dir from `$PWD`; dollar figures
are API list-price equivalents — on a subscription they're rate-limit budget, not cash; the
authoritative cash figure is `/cost`.) It classifies transcripts by layout: `top`
(`<proj>/<session-id>.jsonl`) is the orchestrator only — or a pre-2.0 run's process workers; every
worker is `sub`, a sub-agent transcript one level under the supervisor session
(`<proj>/<supervisor-session>/subagents/agent-*.jsonl`), attributed to the WORKERS side of
`ORCHESTRATOR vs WORKERS` even though its parent session is the orchestrator (#281). A
sub-agent dispatched through the `Workflow` tool nests one level deeper still
(`subagents/workflows/wf_*/agent-*.jsonl`) and is counted the same way — `sub`, on the WORKERS
side, attributed to the top-level `<session-id>` rather than to the `wf_<id>` grouping (#309).
Read the header's `SESSIONS: N in <proj>   (X top-level, Y sub-agent)` line before trusting the
totals below it: that split is the check that the scan saw the whole fleet — a `0 sub-agent`
count on a fleet means transcripts are missing, not that none were spawned.

**Lessons — mandatory.** Run `scripts/decision-tally.sh` and paste its table. Then write the
`lessons:` block below it, one entry per candidate, `category` from
[`references/retro-taxonomy.md`](../retro-taxonomy.md)'s seven fixed categories
(`navigation`, `automated-checks`, `coding-standards`, `steering`, `tool-economy`, `no-ops`,
`information-access`), `evidence` a report line, issue/PR or tally row, `candidate` one sentence
pre-shaped for `create-issue`:

```markdown
## Lessons
<decision tally table from scripts/decision-tally.sh>

lessons:
  - category: <one of the seven>
    evidence: <issue/PR/worker report line, or a tally row>
    candidate: <one sentence, pre-shaped for create-issue>
```

The fleet's reports are half the evidence: the transcripts hold the other half (a worker's tool
errors, the gate denials it met, the never-wait shape it died in), and `review-sessions` harvests
those across every session — point the owner at it when a `lessons:` entry needs the transcript
side. `lessons: none — <why>` is the **only** accepted empty form — a run with no candidates still says so,
naming why, rather than omitting the block. Candidates are **recorded, not filed**: each faces
[`../_shared/filing-bar.md`](../../../_shared/filing-bar.md) before anyone opens an issue for it, so the
retro never becomes another inlet that outruns the work (the *treading water* rule in Step 4). Write
the block to `<state-dir>/auto-dev-retro-<date>.md`, next to the state file, and echo it in the final
report; for a run that targets the kit itself, commit it as
`docs/case-studies/auto-dev/<date>-<repo>.md` instead (the kit cannot write into a consumer repo's
`docs/`, so for any other repo the report names the file and the owner decides where it goes).
