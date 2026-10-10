---
name: init
description: >-
  Make a repository ready for the issue/PR lifecycle skills in one command — record its facts in
  the committed profile (`.claude/skills/repo-profile.md`: commit identity, build/test commands,
  labels, merge style, conflict hot-spots), converge its labels, issue forms, settings, topics and
  Pages source from a manifest, then refresh the profile. Use for a new repo or one that drifted:
  "init this repo for the kit", "set up the repo profile", "set up the labels", "configure this
  repository the way the kit expects", « initialise ce repo pour les skills », « configure les
  labels du repo ». `--plan` writes nothing on GitHub; `--profile-only` only reads or regenerates
  the profile. Does NOT write a CLAUDE.md, file issues, implement code, or merge PRs.
license: MIT
compatibility: >-
  Requires git and bash; the manifest half also needs python3 with PyYAML, jq and an authenticated
  gh CLI. Without gh the profile is generated with flagged TODOs and the GitHub surfaces are
  reported as not converged. The settings, topics and Pages surfaces need admin rights on the
  repository; without them each is refused by name while the rest still lands.
metadata:
  author: Philippe Matray
  suite: tagout
---

# Make a repository ready for the lifecycle skills

`create-issue`, `implement-issue`, `merge-pr` and `auto-dev` are generic workflows wrapped around a
thin layer of repo-specific facts. This skill does the whole setup story in one pass: it **records**
those facts in a committed profile, **converges** the configuration they describe (labels, issue
forms, settings, topics, Pages source) from a declarative manifest, and **refreshes** the profile so
it reports what now exists. Decision record: [ADR 0018](../../docs/adr/0018-profile-repo-and-setup-repo-merge-into-init.md).

The profile is data, not a skill ([ADR 0001](../../docs/adr/0001-the-repo-profile-is-committed-data-not-a-skill.md)):
the lifecycle skills read it at their Step 1, and only reach for this skill when it is missing.

## Three paths

| Invocation | Does | Writes on GitHub |
|---|---|---|
| `/tagout:init` | profile → `plan` → `apply` when it found drift → refresh the profile | yes — labels, forms, settings, topics, Pages |
| `/tagout:init --plan` | profile → `plan`; prints the drift | no |
| `/tagout:init --profile-only` | show the profile, or generate it when missing (add `--refresh` to regenerate) | no |

**Pick the path from the request, not only from the flag.** A request to *read*, *show* or
*regenerate* the profile takes `--profile-only`; one to *check* or *list* drift takes `--plan`.
`apply` runs only on a request to set up, configure or converge the repository, or on a bare
`/tagout:init` — the writer never fires from a read-only question (ADR 0018).

## Do this

Two bundled scripts do the deterministic work; run them from anywhere in the target repo (each
anchors to the git root). `<skill-dir>` is this skill's base directory — given when the skill loads.

### 1. The profile

```bash
bash "<skill-dir>/scripts/repo-profile.sh" show
```

- **It printed the profile** (and no `--refresh` was asked) → keep it; relay the headline values
  (repo slug, commit identity, build/test commands, integration style).
- **It printed `NO_PROFILE`** (exit 3), or `--refresh` was asked → the generation path (on `--plan`, which
  writes nothing locally, say the profile is missing instead and go on to step 2). Read
  [`references/generating.md`](references/generating.md) and follow
  it: run `repo-profile.sh detect`, fill
  [`references/profile-template.md`](references/profile-template.md)
  from the facts it emits, write `.claude/skills/repo-profile.md`, and list every TODO you left.
- **Exit 4** → not inside a git repository: say so and stop.

On `--profile-only`, stop here and recap.

### 2. The manifest

```bash
bash "<skill-dir>/scripts/repo-setup.sh" plan
```

`plan` writes nothing. On `--plan`, show the delta and stop. Otherwise, when it found drift, converge:

```bash
bash "<skill-dir>/scripts/repo-setup.sh" apply
```

The manifest is the repo's own `.github/repo-setup.yml` when it has one, else the kit's
`templates/repo-setup.yml`; `--manifest <path>` overrides both. The rules `apply` follows (additive,
`pruneKeep`, never clobber a form, placeholders reported `!TODO`, topics additive, Pages never
disabled) are spelled out in [`references/desired-state.md`](references/desired-state.md) —
relay them before a first run against a repo that already has labels.

| Exit | Meaning | What to do |
|---|---|---|
| 0 | converged | Say so. |
| 1 | `plan` found drift | Show the delta, then `apply` — **except** a `!TODO` line: `apply` never creates a placeholder, so fill it into the manifest instead. |
| 2 | bad usage, or an unreadable manifest | Fix the manifest; never partially apply. |
| 3 | a surface was refused | Relay which one and why — the rest did land. Carry on to step 3. |
| 4 | not inside a git repository | Say so and stop. |

### 3. Refresh the profile

After an `apply` that followed a `plan` exit 1 (drift — `apply` itself exits 0 either way), re-run step 1 on its generation path: the label axes and
issue forms the profile reported as missing exist now, so the profile must record them before a
lifecycle skill reads it. This step is part of the run, not advice to the user.

## Autonomy contract

Run **hands-off**. `show` and `plan` are reads — no ceremony. The generation path is best-effort
inference: fill what `detect` proves and write a marked `<!-- TODO: … -->` for the rest rather than
inventing a value. Before `apply`, get a yes only when the repo is not the user's own or the run
includes `--prune`. Never invent a taxonomy: a missing axis is a manifest edit and a re-run, never a
hand-made `gh label create`. A refused surface is reported and the run moves on. Stop only for a
real blocker: not inside a git repo, or `gh` unauthenticated when the request needs GitHub (tell the
user to run `! gh auth login -h github.com`).

## Inputs

- **`--plan`** — profile, then `plan`; nothing is written on GitHub.
- **`--profile-only`** — the profile alone; with **`--refresh`**, regenerate it even if one exists.
- **`--prune`** — passed to `apply`: delete labels the manifest does not declare (never the
  `pruneKeep` ones). Never implied.
- **`--manifest <path>`** — a manifest other than the repo's own or the kit's default.
- A path argument — a repo other than the current directory, passed as the scripts' `[dir]`.

## Recap

Close with the shared recap shape — [`../_shared/recap.md`](../_shared/recap.md). It owns the four
blocks (verdict · **What happened** · **Artifacts** · **Assumed · skipped · unverified**, where
`None` is a required answer rather than an omission) and the **Next** line, which is read off this
skill's row in that file's hand-off table instead of being decided again here. Everything below is
only what **init** adds on top of them.

- Say which path ran (`/tagout:init`, `--plan`, `--profile-only`) and whether the profile was read
  back or generated — they carry very different confidence.
- Name each GitHub surface separately — labels, issue forms, settings, topics, Pages — and whether
  it converged, was already converged, or was **refused** (and by what).
- Every `<!-- TODO: … -->` left in the profile goes in **Assumed · skipped · unverified**, by name,
  and so does whether `--prune` ran.
