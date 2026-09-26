---
name: debug-issue
description: >-
  Use the moment a user reports something broken or behaving unexpectedly — a bug, failing or flaky
  test, crash, exception, stack trace, regression, build break, or integration failure — and use it
  BEFORE the first command you would run to investigate, not just before the fix. That first look is
  where the symptom gets patched and the cause survives. It applies even when the report is thin
  ("this stack trace", "the deploy fails") and even when the next step seems obvious: gathering what
  is missing is the skill's own first step. Triggers on "fix it", "patch it", "find out why", "get
  to the bottom of it", « ce test est flaky, corrige-le », « ça marchait avant, maintenant ça plante
  ». Not for new code, features, error handling, refactoring code that works, CI/tooling setup, or
  reviewing code that already works.
license: MIT
compatibility: >-
  Harness-agnostic: no tools, MCP servers or repo state required. Ported from the superpowers skill
  `engineering/diagnosing-bugs` (mattpocock/skills, MIT), reworded for trigger precision and
  decoupled from that suite's other skills.
metadata:
  author: Philippe Matray
  suite: tagout
---

# Debug an issue — the root cause before any fix

## Overview

When something breaks, the fastest-feeling move is to change the line where the error appears and re-run. That instinct is usually wrong: it fixes where the problem *surfaces*, not where it *starts*. The symptom goes quiet, the cause stays, and it resurfaces later — often somewhere harder to see.

**Core principle:** Find the root cause before changing code. A fix you can't explain is a guess, and guesses tend to add new variables rather than remove the broken one.

This skill is a process for not-guessing. It is most valuable exactly when guessing is most tempting — under time pressure, when a quick patch looks obvious, or after a fix has already failed.

## The Iron Law

```
NO FIX WITHOUT A ROOT CAUSE YOU CAN EXPLAIN
```

If you cannot say *"this fails because X, and here is the evidence,"* you are not ready to propose a fix. Finish Phase 1 first.

This isn't bureaucracy — it's the one rule that separates debugging from thrashing. Every shortcut around it trades a few minutes now for a latent bug and a longer second session later.

## When to use

Use for any technical issue: failing tests, production bugs, unexpected behavior, performance problems, build failures, integration issues, flaky tests.

The process matters **most** in the moments it feels least affordable:

- **Under time pressure** — an outage or a deadline makes guessing feel responsible. It isn't; a wrong guess extends the outage and you still have to debug afterward.
- **When "just one quick fix" looks obvious** — the obvious fix is often the symptom. Spend two minutes confirming the cause before you spend them patching.
- **After a fix didn't work** — a failed fix is data, not a reason to pile on a second guess.
- **When you don't fully understand the issue** — "I don't understand X yet" is the correct state to be in before Phase 1, not something to paper over.

"It's a simple bug" is not an exception — simple bugs have root causes too, and the process is fast when the bug really is simple.

## The four phases

Complete each phase before moving to the next. The phases exist because skipping one is how guessing sneaks back in.

### Phase 1 — Root cause investigation

Do this *before* touching any code.

1. **Build a feedback loop — this is the phase.** One command that goes red on *this* bug and green once it's fixed. Everything else in Phase 1 feeds it, and everything in Phases 2–4 consumes it. See **`feedback-loop.md`** for the ten ways to construct one, how to tighten it, what to do about non-deterministic bugs, and what to do when you genuinely can't build one.
2. **Read the error carefully.** The message, the full stack trace, line numbers, file paths, error codes. Errors frequently name the cause outright; skimming past them is how easy bugs become hard ones — and they usually tell you which seam the loop should attach to.
3. **Reproduce it consistently.** What are the exact steps? Does it happen every time? Reproduction is the loop going red on demand; if it only happens sometimes, raise the rate rather than hunting for a clean repro (`feedback-loop.md` §3).
4. **Check recent changes.** `git diff`, recent commits, new dependencies, config or environment changes. "It worked before" means *something* changed — find what. Two known states also make a bisection loop possible.
5. **Gather evidence at component boundaries.** When the system has multiple layers (CI → build → sign, request → service → DB), don't guess which layer is at fault. Instrument each boundary — log what enters and exits each component — run once, and let the evidence point to the failing layer. Then investigate *that* layer.
6. **Trace the data flow.** When the error is deep in the call stack, trace the bad value backward to where it originates, and fix it at the source. See `root-cause-tracing.md` for the full backward-tracing technique.

**You're done with Phase 1 when you can name one command you have already run at least once** — show
the invocation and its (redacted) output — that is **red-capable** (drives the real code path and
asserts the user's exact symptom), **deterministic**, **fast**, and **agent-runnable**; *and* you can
state what is failing and why, with evidence from that run rather than from a hunch.

**No red-capable command, no Phase 2.** A cause you inferred by reading is a hypothesis, not evidence
— it belongs in Phase 3, where something can refute it.

### Phase 2 — Pattern analysis

Understand the shape of the problem before you change anything.

1. **Find working examples.** Locate similar code in the same codebase that *does* work. The difference between it and the broken code is your strongest lead.
2. **Read references completely.** If you're following a pattern, library, or reference implementation, read all of it — not the first plausible snippet. Partial understanding is where most "mysterious" bugs come from.
3. **List every difference** between working and broken, however small. Resist "that can't matter" — that's often exactly what mattered.
4. **Understand dependencies and assumptions** — what config, environment, or invariants the code relies on.

### Phase 3 — Hypothesis and test

Apply the scientific method so a confirmed cause, not a coincidence, drives the fix.

1. **Generate 3–5 ranked hypotheses *before* testing any of them.** Producing one hypothesis and testing it anchors you on the first plausible idea — the rest of the session then goes into defending it. Write the list down, most-likely first.
2. **Each hypothesis must be falsifiable — state its prediction.** The shape: *"If X is the cause, then changing Y makes the bug disappear / Z makes it worse."* A hypothesis you cannot state a prediction for is a vibe, not a hypothesis: sharpen it or discard it.
3. **Show the ranked list before you start testing.** Your human partner often re-ranks it instantly ("we deployed a change to #3 yesterday") or has already ruled one out. Cheap checkpoint, large payoff — but don't block on it; proceed with your own ranking if they're away.
4. **Test them in rank order, minimally, one variable at a time.** The smallest change that confirms or refutes the prediction. Changing several things at once means you won't know which one mattered — and the loop from Phase 1 is what reads the verdict.
5. **Check the result.** Confirmed → Phase 4. Refuted → cross it off and take the next one; a refuted hypothesis is evidence that narrows the list, not a reason to invent a sixth on the spot. **All of them refuted → back to Phase 1**, with a sharper loop: a list that is entirely wrong usually means the loop is asserting on the wrong symptom, not that the bug is unknowable.
6. **When you don't know, say so.** "I don't understand X" is a valid, useful state — research it or ask, rather than pretending and patching.

### Phase 4 — Implementation

Fix the cause you confirmed, and prove it.

1. **Instrument to *decide between* hypotheses, never to browse.** Each probe must map to a specific prediction from Phase 3. In order of preference: a **debugger or REPL** if the environment supports one (one breakpoint beats ten log lines); otherwise **targeted logs at the boundaries that distinguish the hypotheses**. Never "log everything and grep" — that buries the signal you came for and changes the timing of the bug you're chasing.
   - **Tag every probe** with a unique marker: `[DEBUG-<4 hex>]`, e.g. `[DEBUG-a4f2]`. Untagged probes survive the fix and rot; tagged ones die in one grep.
   - **Cleanup is that grep, scoped to your own change:** `git diff main | grep '\[DEBUG-'` must name none of your probes before you call it done. Two details that decide whether this catches anything: use the **two-dot** form (`git diff main`, not `main...HEAD`) so it sees the *working tree* — probes you have not committed yet are exactly the ones about to be swept into the fix commit — and read the *lines*, not the exit status, since "clean" is grep's exit 1 and would fail the pipeline under `pipefail`. Scoped to the diff rather than the tree because a fixture, or this file, may contain the string without it being your leftover.
   - **Performance regressions take the other branch:** logs are usually the wrong instrument. Establish a baseline measurement first (timing harness, profiler, query plan), then bisect against it. Measure first, fix second.
2. **Write a failing test first.** The simplest reproduction that fails because of this bug — an automated test where possible, a one-off script otherwise. A test that fails now and passes after is what proves the fix is real rather than coincidental. (Use your project's test-driven-development practice for writing it.) This is usually the Phase 1 loop, minimised and moved somewhere permanent.
3. **Make one fix, at the source.** Address the confirmed root cause, one change at a time. No bundled refactors or "while I'm here" improvements — they muddy what actually resolved the bug.
4. **Verify, and write the cause down where the next debugger will read it.** The new test passes, no other tests broke, the Phase 1 loop no longer goes red, and the tag grep over your diff (step 1) names none of your probes. Then **name the confirmed hypothesis in the commit message** — it is the root cause the Iron Law demanded, and a commit that says *what* changed without *why it was broken* throws that away exactly when it becomes cheap to keep.
5. **If the fix fails, stop and re-examine.** Count your attempts. Under three: return to Phase 1 with the new information. **Three or more failed fixes is a signal in itself** — see below.

### When three or more fixes fail: question the architecture

If each fix reveals a new problem somewhere else, or every fix would need "massive refactoring," you are probably not looking at a stubborn bug — you're looking at a wrong design.

Symptoms of this:
- Each fix surfaces new shared state / coupling / breakage in a different place.
- Fixes keep creating new symptoms elsewhere.

Stop fixing and step back to fundamentals: Is this pattern sound? Are we continuing out of inertia? Should we change the design instead of patching it? **Raise this with your human partner before attempting another fix.** This is a wrong-architecture situation, not a failed-hypothesis one, and more patches won't resolve it.

## Bundled techniques

These references in this directory go deeper on specific situations. Read the one that fits:

- **`feedback-loop.md`** — build the red-capable command Phase 1 ends on: the ten-rung construction ladder, the tighten pass, raising the rate on non-deterministic bugs, and the completion criterion. Read this one first; it's the phase.
- **`scripts/hitl-loop.template.sh`** — the last rung of that ladder: when a human must click, drive them from a script so the loop stays structured and its answers come back as parseable `KEY=VALUE` lines.
- **`root-cause-tracing.md`** — trace a bug backward through the call stack to its original trigger (and how to add instrumentation when you can't trace by reading).
- **`defense-in-depth.md`** — after finding the root cause of an invalid-data bug, add validation at every layer so the bug becomes structurally impossible.
- **`condition-based-waiting.md`** — fix flaky/timing-dependent tests by waiting for the actual condition instead of guessing at a delay.
- **`find-polluter.sh`** — bisection script to find which test is leaving behind state that breaks another test.

## Red flags — stop and return to Phase 1

If you catch yourself thinking any of these, you've drifted into guessing:

- Reading code to build a theory before a red command exists.
- "Quick fix for now, investigate later."
- "Let me just try changing X and see."
- "I'll make several changes and run the tests."
- "Skip the test, I'll check it manually."
- "It's probably X, let me fix that." / "I see the problem" (from the symptom alone).
- "I don't fully understand it, but this might work."
- "The reference is long; I'll adapt the pattern from memory."
- Listing fixes before you've traced the data flow.
- "One more attempt" — when you've already tried two or more.

Any of these means: stop, return to Phase 1. (And three-plus failed fixes means question the architecture, above.)

## Signals from your human partner

Your partner often notices you've started guessing before you do. Treat these as a cue to stop and return to Phase 1:

- *"Is that actually happening?"* → you assumed something without verifying it.
- *"Will that show us where it breaks?"* → you should add evidence-gathering first.
- *"Stop guessing."* → you're proposing fixes without understanding.
- *"Think harder about this."* → question fundamentals, not just the symptom.
- *"Are we stuck?"* (frustrated) → the current approach isn't working; change approach, don't repeat it.

## Common rationalizations

Each of these *feels* reasonable in the moment. The right column is why it costs more than it saves.

| In-the-moment excuse | Why it's wrong |
|---|---|
| "Issue is simple, skip the process" | Simple bugs have root causes too — and the process is fast when they're simple. |
| "Emergency, no time for process" | Systematic debugging is *faster* than guess-and-check thrashing, and doesn't leave latent bugs in an already-bad situation. |
| "Just try this first, then investigate" | The first fix sets the direction. A guess first usually means a second debugging session later. |
| "I'll write the test after I confirm the fix" | Without a failing test, you can't tell a real fix from a coincidence. Untested fixes don't stick. |
| "Several fixes at once saves time" | You won't know which change worked, and you risk introducing new bugs you'll later blame on the old one. |
| "Reference is too long, I'll adapt it" | Partial understanding is the most common source of these bugs. Read it fully. |
| "I see the problem, let me fix it" | Seeing the *symptom* isn't understanding the *cause*. |
| "One hypothesis is enough — I can see it" | The first plausible idea is where anchoring starts. Three to five ranked, falsifiable ones cost minutes and routinely demote the "obvious" one to third. |
| "One more fix attempt" (after 2+) | Three-plus failures points at the architecture, not the bug. Question the design instead of patching again. |

## Quick reference

| Phase | Activities | Done when |
|---|---|---|
| **1. Root cause** | **Build a feedback loop** (`feedback-loop.md`), read errors, reproduce, check recent changes, instrument boundaries, trace data flow | You can name one red-capable command you have **already run** — deterministic, fast, agent-runnable — and say what fails and *why* from its output |
| **2. Pattern** | Find working examples, read references fully, list differences, map dependencies | You know what's different between working and broken |
| **3. Hypothesis** | Rank 3–5 falsifiable hypotheses (each with its prediction), test in order, one variable at a time | One is confirmed against the loop — or all are refuted and the list is narrower |
| **4. Implementation** | Tagged instrumentation per prediction, failing test, single fix at the source, verify | Bug is gone, the new test passes, nothing else broke, `DEBUG-` tags are cleaned up, and the cause is in the commit message |

## When investigation finds no single root cause

Sometimes thorough investigation shows the issue really is environmental, timing-dependent, or external. If so:

1. You've completed the process — that's a legitimate outcome, not a failure.
2. Document what you investigated and ruled out.
3. Implement appropriate handling (retry, timeout, clear error message, condition-based waiting).
4. Add logging/monitoring so a future occurrence leaves evidence.

Be honest with yourself here, though: most "there's no root cause" conclusions are really *"I stopped investigating too early."* Make sure you actually traced the data flow before reaching for this.

## Why this pays off

Guessing feels faster because the first edit is quick. But each unconfirmed change adds a variable instead of removing the broken one, so failed guesses compound — and a symptom patch leaves the real bug to resurface later, usually at a worse time. Finding the cause first is what makes a fix stick, keeps it from spawning new bugs, and leaves the code better understood than before. Done right, the bug doesn't come back and similar bugs get easier to spot.

## Recap

Close with the shared recap shape — [`../_shared/recap.md`](../_shared/recap.md). It owns the four
blocks (verdict · **What happened** · **Artifacts** · **Assumed · skipped · unverified**, where
`None` is a required answer rather than an omission) and the **Next** line, which is read off this
skill's row in that file's hand-off table instead of being decided again here. Everything below is
only what **debug-issue** adds on top of them.

- **What happened** names the root cause and the *red-capable command you already ran* that proves
  it — phase 1's own "done when". A recap that describes the symptom instead has not finished
  phase 1.
- Hypotheses you refuted belong in **What happened** too, not in **Assumed · skipped ·
  unverified**: a refuted hypothesis is a result that narrows the next search. What goes in the
  third block is what you could not test and why.
- **Next** is `/create-pr` when it ran standalone and left a committed fix (or one still sitting
  uncommitted) on the branch it was invoked on; `—` when it returns to its caller (`implement-issue`'s
  "honest effort" loop) instead of deciding a fix on its own.
