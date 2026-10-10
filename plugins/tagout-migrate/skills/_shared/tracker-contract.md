# The tracker contract

Every lifecycle skill files against a **tracker** — the issue/PR host a repository lives on. Until
#505 each skill reached that host by calling `gh` directly, in 111 lines across 18 scripts and 189
across 39 prose files, so "does this skill work on GitLab?" had no place to be answered. This file is
that place.

## What a verb is

A **verb** is one named operation against the tracker — `issue-view`, `repo`, `auth` — with one
argument list and one normalised stdout, declared once in
[`scripts/tracker/contract.json`](../../scripts/tracker/contract.json). That file is the verb table's
single home; a verb it does not name does not exist, on any host.

A **backend** implements verbs for one host, at `scripts/tracker/<tracker>.sh`. It answers
`<backend> verbs` with one verb per line — that is how the dispatcher learns what a half-migrated
host actually covers, rather than assuming it covers the table — and `<backend> <verb> [args…]` for
the rest, reading the repository from `TRACKER_REPO` in its environment.

The dispatcher also exports `TRACKER_DETAIL`, the second word of the profile's Tracker line
(`dev.azure.com/acme/Shop`), so a backend does not re-read the profile itself (#693). It is set only
when that line names the tracker being dispatched to, including under an explicit `--tracker`, and
is empty otherwise. A backend that reads it lets it win over `TRACKER_REPO`: today that is
`azure-devops.sh`, whose order is `TRACKER_DETAIL`, then `TRACKER_REPO`, then its own profile read
for a direct call that bypasses the dispatcher. So in a repository whose profile names Azure DevOps,
`--repo` does not override the profile's organisation and project.

`scripts/tracker.sh` routes between them:

```bash
<kit>/scripts/tracker.sh [--tracker <name>] [--repo <slug>] <verb> [args…]
```

The tracker is `--tracker` when given, else the first word of
`skills/init/scripts/repo-profile.sh tracker` (the profile's Tracker line), else `github`
when there is no committed profile. A missing profile is **not** this dispatcher's to report — the
profile load in [`preconditions.md`](./preconditions.md) already names that condition, and defaulting
to `github` is the behaviour every skill had before the contract existed.

## The exits

| Exit | Means | What to do |
|---:|---|---|
| `0` | the verb ran and printed its contract's stdout | use it |
| `1` | the host refused or failed — auth, network, a 404 | the host's problem, not the contract's; retry or report it |
| `2` | bad invocation: an unknown verb, a missing argument, no verdict from the profile probe | fix the call. An unknown verb is exit 2 on **every** host, deliberately: a typo must not read as a gap some backend could fill |
| `3` | `NOT_IMPLEMENTED <tracker> <verb>` — no backend, or a backend that does not list this verb | implement the verb for that host, or run the skill somewhere it exists |

GitHub is the **reference** backend. Every other backend is written against what it prints, and it is
deliberately never reduced to a lowest common denominator: a verb prints what GitHub can actually
say, and a host that cannot say it answers `3` rather than every host answering less.

## The `fallback` rule

Some hosts cannot express a *relation* another host has — a sub-issue edge, a blocked-by link. A verb
for such a relation does not fail there and does not silently skip it: it reports `fallback`, and the
calling skill degrades to the text equivalent it already writes when the GitHub API refuses the edge.
`skills/create-issue/scripts/wire-edges.sh` established that shape before the contract existed — it
prints `ok`, `fallback` or `FAILED` per edge — and the contract keeps it rather than inventing a
second convention. A relation reported `fallback` is recorded in the run's report, because a
degradation nobody is told about is indistinguishable from one that never happened.

## Whether a skill may run at all

That question is a registered decision, `tracker.capable`, and it is not answered by reading this
file. `scripts/tracker.sh state <skill>` reports five facts — the tracker, its detail, the skill, the
verbs the skill `needs` and the verbs the backend `implements` — and
`scripts/tracker/capable.sh` turns that report into one verdict, which Step 1 of every lifecycle
skill asks through `scripts/decide.sh`. The two `null`s are distinct and the verdict depends on
telling them apart: `needs` is null when the skill is not on the contract, `implements` is null when
there is no backend at all.

Every skill answers `capable` on GitHub, including one that has not migrated a single call site,
because its direct `gh` calls are correct there — so this change refuses nothing that worked before
it. The program's own header records the precedence and why each rule outranks the next; that is its
one home, and this file does not restate it.

## Moving a skill onto the contract

1. Add the verbs the skill needs to `scripts/tracker/contract.json` under `verbs`, if they are not
   there yet, and implement them in `scripts/tracker/github.sh`.
2. List the skill under `skills` in the same file, naming exactly the verbs it calls. That is what
   `tracker.capable` reads, so a skill listed with a verb no backend implements is refused on that
   host by construction — before it runs, not inside a step.
3. Replace the skill's direct `gh` calls with `tracker.sh <verb>` calls, one step at a time.
4. Extend `tests/tracker/test.sh` with the new verbs' normalised stdout, under a stub `gh`.

Until step 2 happens for a skill, it is `missing` on every non-GitHub host — which is the honest
answer, not a gap: nothing has established which verbs it needs there.

## Consumers

- `skills/_shared/preconditions.md` — Step 1 asks `tracker.capable` before any skill proceeds
