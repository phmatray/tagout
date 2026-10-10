# Skill-triggering evals

A **safe, repeatable** regression check for **every** skill's *description* — all twelve of
[`auto-dev`](../skills/auto-dev), [`create-issue`](../skills/create-issue),
[`debug-issue`](../skills/debug-issue), [`create-pr`](../skills/create-pr), [`deliver-issue`](../skills/deliver-issue),
[`implement-issue`](../skills/implement-issue), [`init`](../skills/init), [`merge-pr`](../skills/merge-pr),
[`migrate-legacy`](../skills/migrate-legacy),
[`review-followups`](../skills/review-followups), [`review-sessions`](../skills/review-sessions),
and [`triage-backlog`](../skills/triage-backlog) —
the roster `run_all.py`'s `SKILLS` holds and `tests/skills/check-frontmatter.py` cross-checks.

`<skill>-trigger-eval.json` here is a skill's **triggering contract**, and its only home (#331).
It used to have two: these sets, plus a per-skill bullet list under `tests/skills/` that CI
guarded and nothing ran. The two drifted — `create-issue` carried 8 bullets against 11 different
JSON queries, and five skills had a bullet list and no eval set at all, so "re-run the evals" left
half the kit unmeasured while CI reported every contract present. The markdown lists are retired;
the sets absorbed every bullet they were missing, near-miss annotations included (that is what the
`note` field is for).

Each skill's close boundaries are carried as negatives **inside its own set** — `init` vs
Claude Code's built-in `/init` (the repo's configuration vs a `CLAUDE.md`), `auto-dev` vs its own children (many issues vs one),
`review-followups` vs `triage-backlog` (report.json queues vs GitHub issues), `debug-issue` vs
new-code work. `boundary-trigger-eval.json` stays what it always was: specifically the
`implement-issue` ↔ `merge-pr` pair, with a runner written around exactly those two.

> **Moved here from `Atypical-Consulting/Koine` on 2026-07-25**, when these four skills were
> consolidated into this repo as the canonical, profile-driven copies and Koine switched to
> consuming them as a plugin. The evals follow what they measure. `read_skill_description` now
> reads `skills/<name>/SKILL.md` instead of `.claude/skills/<name>/SKILL.md` — the only change
> the move required.

A skill's `description` is the *only* thing deciding when it fires, and the four boundaries are
deliberately close (e.g. `implement-issue` "sync an **in-flight** PR" vs `merge-pr` "sync **as part of
landing**"). With no automated coverage, a description edit can silently start over- or under-firing.
These evals catch that: each skill has a set of should-trigger phrasings and near-miss negatives, and
[`trigger_eval.py`](trigger_eval.py) measures the trigger rate of the *installed* description.

> Tooling/test-infra only — no product code. Issue #372 (builds on #370); widened to all
> ten skills, and made the single home for the triggering contract, by #331.

## Why a local runner (the `run_eval` 0-trigger diagnosis)

skill-creator ships `scripts/run_eval.py`, which tests a description by writing it as a **uniquified**
synthetic command file `<skill>-skill-<uuid>.md` and counting a trigger only when that exact
uuid-suffixed name appears in the model's `Skill`/`Read` tool input. During #370 it reported **0
triggers for every query across every description** here — the fingerprint of a broken detector, not a
weak description.

**Root cause:** where the diagnosis was made (Koine), all four lifecycle skills were *already
installed* under `.claude/skills/`.
So a should-trigger query makes the model invoke the **canonical** skill — `Skill(skill="init")` —
never the uuid-suffixed `init-skill-<uuid>` the matcher waits for. The substring test
`clean_name in accumulated_json` therefore never matches → 0 triggers, regardless of description
quality. (Confirmed three ways: a raw `claude -p` capture of the real-skill query, a faithful
synthetic-command reproduction, and running the real `run_eval.py` — all fire the canonical name; the
uuid-suffixed name is absent. The stream event *shapes* — `stream_event` / `content_block_start` /
`content_block_delta` — match the detector exactly; only the matcher's expected *name* is wrong.)

**The fix** (`trigger_eval.py`): match the **canonical installed skill name** in addition to the
synthetic uuid-suffixed one. Detection then registers real triggers. The runner also records *which*
skill fired, so the `implement-issue` vs `merge-pr` boundary can be read off a single run.

## What recall here actually measures

**"Does the skill fire within the model's first `MAX_TOOLS` moves"** — three, as of #450.

It used to mean less than that. The runner killed the subprocess at the *first* tool-use intent, so
a query the model answered by orienting itself — a `Grep` for the symbol, a `Read` of the file —
was recorded as a miss although nothing had yet decided against the skill. That penalised exactly
the queries a debugging or migration skill exists for, the ones that invite a look before a plan:
*"this test fails intermittently, can you fix it?"* scored a hard zero under the old rule and
**triggers** under this one, unchanged description.

Three moves, not more: the window has to stay small enough that a model wandering off is still a
miss rather than eventually stumbling into the skill and scoring a pass.

The tools really run now, so the CLI is given an **allowlist** — `Skill`, `Read`, `Grep`, `Glob` —
rather than the old denylist of the four mutating tools. A denylist was sound while nothing ever
executed; the moment something does, it silently admits every tool nobody thought to name (`Task`
spends tokens on a sub-agent, `WebFetch`/`WebSearch` are network egress from a bench, `Artifact`
publishes a page). Measured: a query instructed to create a file has its `Bash` call refused and the
file is never created.

A specificity below 1.00 is still the unambiguous half: that one means the description is genuinely
over-firing, and no window size excuses it.

## The noise floor — read differences, not digits

The entrance is **intrinsically stochastic**, and the bench cannot hide it. Measured on the
committed sets: **19 of 253 queries (8%) did not agree with themselves across three runs**. Each of
those is a coin flip at `threshold 0.5`, so a set of ~20 queries carries roughly **±2 to ±3
queries — about ±0.10 of recall — from nothing but re-running it**.

The cleanest demonstration is `implement-issue`'s *"build the feature from issue #129 and open a
PR"*, run five times against one unchanged description: **2 fired, 3 did not**. Widening the
observation window from one tool call to three moved the twelve sets by +2 and −7 queries in total,
under a strictly more permissive rule — which is only possible if the −7 was noise.

So:

- **Act on gaps, not on digits.** 1.00 versus 0.55 is a finding. 0.82 versus 0.73 is the same
  number measured twice.
- **`--runs-per-query 5` for a committed baseline**, 3 for a quick look. More runs narrow the
  interval; nothing makes it zero.
- **Specificity is the exception.** It sits at 1.00 across every set and has never moved, so a
  single point below it is signal on its first appearance.

The consequence worth stating plainly: no amount of description tuning makes skill entry
deterministic. It shifts a probability. A mechanism that does not depend on the model choosing is a
different design question, and it is not this bench's to answer.

Two shapes of row cannot pass at all, and they are noise rather than signal:

- **A slash-command query.** A command is expanded into the prompt by the client, not invoked as a
  tool, so there is no tool-use intent to observe. `SKILL_COMMANDS` maps a command a skill owns back
  to the skill, which covers the model *reaching for* the command file; it cannot cover the user
  typing one. Four such rows existed (`/migrate`, `/migrate-assess`, `/migrate-verify`,
  `/migrate-followups`) and were the whole of `migrate-legacy`'s 0.33; they are **deleted**, and
  `tests/skills/check-frontmatter.py` now refuses a `/`-prefixed query so none comes back. The
  routing they were reaching for is asserted structurally instead, by the same file: every
  `commands/*.md` names the skill it dispatches to.
- **A skill the running Claude Code has no plugin for.** `run_all.py` closes that one by linking
  every skill under test into `.claude/skills/` for the run — see `skills_visible`.

## Safety (why this is safe even for the action skills)

A should-trigger query like *"merge PR 279"* makes the model invoke the **real** `merge-pr` skill — we
must never let it run. Safety comes from **killing the `claude -p` subprocess the instant a tool-use
intent is detected in the stream**, which is emitted while the assistant message is still streaming —
strictly *before* the harness executes the tool. At most one tool-use is ever observed per run, and the
process is killed before it executes. The synthetic command file is kept for faithfulness to the
skill-creator approach, but it is the **early kill** — not the command file — that makes this safe when
the real skills are installed. The runner never runs a skill body; it only observes the *intent* to.

As defense-in-depth, each subprocess runs with `--disallowedTools Bash Edit Write NotebookEdit`, so
even if the early kill ever lost the race (e.g. a future CLI stopped emitting partial tool-use events),
an action skill still could not mutate anything — the tools that do are denied. This does not change
*which* skill the model invokes (what we measure): the `Skill` tool stays allowed and fires first.

## How to run

Requires the `claude` CLI on `PATH` and run from inside the repo (the runner strips `CLAUDECODE` so
`claude -p` can nest inside a Claude Code session). Each skill has a `<skill>-trigger-eval.json` set:

```bash
# one skill
python3 evals/trigger_eval.py --skill init \
  --eval-set evals/init-trigger-eval.json \
  --runs-per-query 3 --out evals/results/init.json

# all ten + the boundary, refreshing the committed baseline
python3 evals/run_all.py --runs-per-query 3
```

Eval-set entries are `{"query": "...", "should_trigger": true|false, "note": "..."}`. A skill **passes**
a query when its trigger rate is `≥ threshold` (default 0.5) for should-trigger entries, and `< threshold`
for should-not entries. Treat run-to-run flakiness with `--runs-per-query ≥ 3`.

To re-check after a description edit: re-run the affected skill's set and compare `recall` /
`specificity` against the committed baseline in [`results/`](results). A scoped
`python3 evals/run_all.py --skills <name>` *merges* into the committed `baseline.json` (it refreshes
only that skill and leaves the others intact), so it is safe to re-run one skill at a time.

## The CI contract

CI enforces the sets **structurally**, never by running them.
[`tests/skills/check-frontmatter.py`](../tests/skills/check-frontmatter.py) fails the build unless,
for every `skills/<name>/SKILL.md`, `evals/<name>-trigger-eval.json`:

- exists;
- parses as JSON and is a non-empty **list of objects**;
- uses only the runner's keys — `query`, `should_trigger`, optional `note` (a stray key such as the
  boundary set's `expect` is a copy-paste the runner would silently ignore);
- gives every entry a non-empty string `query` and a boolean `should_trigger`;
- repeats no `query` — a duplicated one inflates recall for free;
- gives every `note` that is present a string value;
- carries **both** polarities: at least one `should_trigger: true` and at least one `false`.

It also pins the roster itself: `run_all.py`'s `SKILLS` and `trigger_eval.py`'s `DEFAULT_KNOWN`
must each list **exactly** the `skills/*/` folders. Without that, a skill added with a valid set
passes every rule above while `run_all.py` never runs it — the same "CI reports every contract
present, half the kit unmeasured" failure, one edit away.

That is the whole of what CI checks, and it is deliberate. **The bench itself stays manual**: each
query spawns a real `claude -p` (× `--runs-per-query` × ten skills), it needs an authenticated CLI
on the runner, it costs tokens, and by design it kills real skills mid-stream (§Safety above).
Structural in CI, measured on demand. A skill added later without a set fails CI by name, with the
path to create — [`tests/skills/test.sh`](../tests/skills/test.sh) cases `T1`–`T11` are the witness
that each of those refusals still fires.

**Slash-command queries.** A skill's command file is not named after the skill (`/migrate` opens
`commands/migrate.md`, which contains no "migrate-legacy"), so `trigger_eval.py` carries a
`SKILL_COMMANDS` map and counts a command file this skill owns as the skill firing. Without it a
slash-command entry would read 0/N forever and depress recall for a reason unrelated to the
description.

## Baseline

Captured with `--runs-per-query 3`, threshold 0.5 (full data in [`results/`](results); summary in
[`results/baseline.json`](results/baseline.json)). A description edit that moves any of these is the
signal to look at.

| Skill | Queries | Pass | Recall (should-trigger) | Specificity (should-not) |
|-------|--------:|-----:|:-----------------------:|:------------------------:|
| `create-issue`     | 23 | 18/18 † | 1.0 † | 1.0 † |
| `implement-issue`  | 21 | 18/18 † | 1.0 † | 1.0 † |
| `merge-pr`         | 20 | 18/18 † | 1.0 † | 1.0 † |
| `init`             | 24 | 19/24 | 0.67 | 1.0 |
| `triage-backlog`   | 20 | — ‡ | — ‡ | — ‡ |
| `auto-dev`         | 19 | — ‡ | — ‡ | — ‡ |
| `review-followups` | 19 | — ‡ | — ‡ | — ‡ |
| `migrate-legacy`   | 20 | — ‡ | — ‡ | — ‡ |
| `debug-issue`      | 19 | — ‡ | — ‡ | — ‡ |

† Last measured over the **18** queries these sets held before #331 grew them; the ported negatives
are not in that number, so re-run the skill before quoting it as current.
‡ **Not yet measured.** These sets are new (or, for `triage-backlog`, were in `SKILLS` without ever
being run). Refresh one at a time — `python3 evals/run_all.py --skills <name> --runs-per-query 3`
merges into the committed `baseline.json` rather than overwriting it.

`review-followups` is expected to sit **at the floor** in a headless probe: without repo context it barely
fires at all (positives ≈ 0/3 — see the "Optimisation du déclenchement du skill `review-followups`" entry
in [`docs/backlog.md`](../docs/backlog.md), where the skill-creator loop measured it). Whatever that
run records **is** its baseline, not a target to hit; the reliable signal there is the other half —
zero over-triggering across its near-miss negatives.

Specificity is *real*, not just "nothing fired": each near-miss negative fires the **expected sibling**
skill (e.g. `implement issue 47` → `implement-issue`, `file an issue …` → `create-issue`,
`set up the repo profile` → `init`), recorded in each result's `fired` histogram.

## The description budget (#323)

A `description` is **always-loaded** context: every session with the plugin installed pays for all
ten on every turn, whether or not a skill fires. That makes it the one piece of a skill that earns
harder pruning than its body — and the reason `tests/skills/check-frontmatter.py` prints

```
WARN <skill>: description is N characters — over the 700-char soft ceiling (#323)
```

above **750** characters, exit code unchanged. The guide's 1024 stays the hard error; 750 is the
tripwire far enough below it that accretion is visible while it is still a sentence.

**Cut rules** (the pointer-writing discipline of `mattpocock/skills` `productivity/writing-for-agents`,
MIT — ported from mattpocock/skills):

1. Lead with the trigger, not the identity — *"Land an open GitHub pull request …"*, not *"the
   'ship it' counterpart to implement-issue"*. The body already carries the identity, and the body
   is not loaded until the skill fires.
2. **One trigger phrase per branch**, one FR form per branch. Seven synonyms for *file an issue* are
   one branch written seven times.
3. Cut examples that restate a branch already named in the same sentence.
4. Keep, always: every distinct trigger branch, every `« … »` French form, the *"Does NOT apply"*
   clause — that clause is what the eval sets' **negatives** lean on, so shortening it is how
   specificity silently reopens — and every phrase an eval query pins **verbatim** with no other
   anchor in the text. Rule 2 folds *synonyms*; a phrase a query names exactly is not a synonym.
   The settings query `"turn on auto-delete merged branches"` was the worked example: the settings
   parenthetical says `delete-branch-on-merge`, which is the API's name for it and not the user's.

**Measured on 2026-08-31** (#323), whitespace-normalised, the same count the checker uses:

| | before | after |
|---|---:|---:|
| Total across the ten skills | 8,518 | 6,645 |
| Largest single description | 1,018 (`auto-dev`) | 752 (`triage-backlog`) |
| Over the 750 soft ceiling | 7 | 1 |

`debug-issue` is the one that **grew** (513 → 593): it was the only skill with no French
trigger form, though its eval set carries two French positives, so it gained them here.

The `after` column was re-measured after the 2.0 skill rename (#389), which spends characters no
one chose: `triage-backlog` went 745 → 752 purely because its description names two other skills,
and `followups` → `review-followups` is +7. That is the one standing WARN — it is a **naming** cost,
not a trigger-wording one, and trimming it here would change a description the rename deliberately
left alone, so it is tracked separately rather than absorbed into the rename.

**The stored results under `results/` were rewritten by that rename too.** Every skill name in
`baseline.json` and the per-skill result files now reads with its 2.0 spelling, so the owner's next
run compares against the same baseline instead of treating a renamed skill as brand new — but the
measurements themselves predate the rename, `fired` histograms included.

**What the cut removed, precisely.** Not "nothing" — the honest list is: identity the body already
carries (*"the 'ship it' counterpart to `implement-issue`"*), per-step mechanism the body already
carries, and synonyms restating a branch named in the same sentence (`create-issue`'s seven verbs
for *file an issue* became five; the profile skill stopped enumerating every section of the profile
it writes). No French form, no *"Does NOT apply"* clause and no verbatim eval-query phrase was
dropped — four that had been were restored in review (`« suivis »`, `"next steps"`,
`"turn on auto-delete merged branches"`, `"regenerate the profile"`, `"clean up the open issues"`).

⚠️ **The cuts are NOT bench-proven.** Conservative is an argument, not a measurement. Before the next
release, run `python3 evals/run_all.py --runs-per-query 3` and compare every skill against
[`results/baseline.json`](results/baseline.json); the `implement-issue` ↔ `merge-pr` boundary run
must stay 6/6 each. Only once that passes is the ceiling worth tightening toward the ~450 #323 aimed
at — a limit below what the bench has cleared teaches a reader to ignore a standing warning.

## The `implement-issue` ↔ `merge-pr` boundary (#370)

> ⚠️ **Measured against the pre-#323 descriptions.** Both `implement-issue` and `merge-pr` were
> rewritten by #323, which could not re-run the bench. The 3/3 figures and the "no follow-up needed"
> verdict below therefore describe the *previous* text; the in-flight/land-now wording they turn on
> was kept deliberately (`IN-FLIGHT … while it is still being built` vs `STILL BEING BUILT
> (implement-issue)`), but that is an argument, not a re-measurement. Re-run the boundary set before
> quoting these numbers as current.

The deliberately-close boundary #370's description edits targeted — sync an **in-flight** PR
(→ `implement-issue`) vs sync **as part of landing** (→ `merge-pr`) — is measured by
[`boundary-trigger-eval.json`](boundary-trigger-eval.json), run against **both** skills
([`results/boundary-implement-issue.json`](results/boundary-implement-issue.json),
[`results/boundary-merge-pr.json`](results/boundary-merge-pr.json)):

| Intent framing | Example | Fires | Result |
|----------------|---------|-------|--------|
| **In-flight** ("still building it, sync the branch / rebase / keep it mergeable") | *"rebase my in-flight feature branch on main and resolve the conflicts while I keep adding tasks"* | `implement-issue` | 3/3 ✓ |
| **Land-now** ("merge it now, resolve conflicts as part of landing / squash-merge") | *"land #281: fix the conflicts with main and squash-merge it"* | `merge-pr` | 3/3 ✓ |

All six framings resolve to exactly one skill, 3/3 each — **#370's edits cleanly separate the two
intents.** The genuinely *unmarked* query (no in-flight/land-now cue), `"the PR conflicts with main,
fix it"`, defaults to **`implement-issue`** (the sync interpretation) — `merge-pr` never fired for it —
so a bare "fix the conflicts" never accidentally *lands* a PR. No description gap found; no follow-up
needed.
