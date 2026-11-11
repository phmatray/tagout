## Step 1 — Preconditions & profile

Confirm `"<kit>/scripts/tracker.sh" auth` prints your login and you're in the target repo, then ask whether auto-dev can run on this repository's tracker — the registered decision every lifecycle skill's Step 1 asks ([`preconditions.md`](../../../_shared/preconditions.md)):

```bash
"<kit>/scripts/tracker.sh" state auto-dev | "<kit>/scripts/decide.sh" tracker.capable
```

Proceed only on `capable`; on any other answer stop with the one sentence `preconditions.md` prescribes (*`auto-dev` cannot run here: `tracker.capable` answered `<verdict>`*). `capable` for auto-dev implies `capable` for every skill it drives (#753). **Load the repo profile** via the
`init` skill — auto-dev reads every repo-specific fact from it (the effort/priority
**labels** for ordering, the **area** conventions for conflict-avoidance, commit identity, CI gates).
You mainly need its *Labels* and *Architecture grain* sections.

**Capture your own toplevel, once, and hold it for the whole session:**
`SUPERVISOR_TOPLEVEL=$(git rev-parse --show-toplevel)`. Step 3's dispatch-time guard compares every
worker's first-act report against this value, so it has to exist before the first worker is spawned.

**Read the effective context bound.** No model runs the harness's compact command itself — it fires
only when a user types it — so your context is bounded by whatever `autoCompactWindow` the harness is
actually configured with ([references/token-economics.md](../token-economics.md) § *The two
budgets*, `CONTEXT BOUND` — not restated here). Read, in this order, first value wins (a missing or
invalid file, or a key set to `null`/absent, counts as not set there); managed settings are not read,
so say what you *could* see rather than treating a blank as a confirmed default:

```bash
printf '%s\n' "${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-}"
jq -r '.autoCompactWindow // empty' .claude/settings.local.json 2>/dev/null
jq -r '.autoCompactWindow // empty' .claude/settings.json 2>/dev/null
jq -r '.autoCompactWindow // empty' ~/.claude/settings.json 2>/dev/null
```

When none of these is set and you are running on a 1M-context model, **carry on without stopping**
(ADR-0005) and add one line to Step 6's recap naming the setting to add and the file to add it to —
cite the reference section for the value rather than restating it here.
