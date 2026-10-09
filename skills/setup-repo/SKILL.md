---
name: setup-repo
description: >-
  Bring a GitHub repository to the configuration the issue/PR lifecycle skills assume — label
  taxonomy, issue forms under .github/ISSUE_TEMPLATE/, repository settings (delete-branch-on-merge,
  squash-only merges, description, homepage), topics and the GitHub Pages source — deterministic
  and idempotent: `plan` prints drift, `apply` converges it. Use when a repo needs configuring or
  has drifted: "set up the labels", "create the issue templates", "set the repo description and
  topics", "enable GitHub Pages from docs/", "configure this repository the way the kit expects",
  « configure les labels du repo », « active GitHub Pages ». It WRITES what profile-repo only
  READS. Does NOT file issues, implement code, or merge PRs.
license: MIT
compatibility: >-
  Requires git, python3 with PyYAML, jq, and an authenticated gh CLI. Without gh the label and
  settings surfaces are reported as refused and the run exits 3 with the local issue-form copy
  still applied. The settings surface additionally needs a token with admin rights on the target
  repository; without one it is refused by name rather than silently skipped. The topics and Pages
  surfaces need the same admin rights, and Pages must be available on the repository's plan.
metadata:
  author: Philippe Matray
  suite: tagout
---

# Configure a repository for the lifecycle skills

`create-issue`, `implement-issue`, `merge-pr` and `auto-dev` are generic workflows wrapped around a
thin layer of repo-specific facts. `profile-repo` records those facts — and when it finds none,
its only outlet is a `TODO:` line. That is the right answer for a fact it cannot read and the wrong
one for a **configuration the repo does not have**, which is what four of its TODOs always are:

| What the profile reports | What it actually means | What silently degrades |
|---|---|---|
| no `priority:` axis | the labels were never created | `create-issue` omits the axis |
| no `effort:` axis | the labels were never created | `auto-dev`'s "small first, then medium" ordering has nothing to sort on |
| no `area:` axis | the labels were never created | `auto-dev` cannot give parallel workers non-overlapping areas |
| no `.github/ISSUE_TEMPLATE/` | the directory was never created | `create-issue` has no form to obey |

This skill is the missing verb. It does not describe a repo; it makes one.

The same manifest also carries the four surfaces a **public** repository is judged by before
anyone opens a file (#400): `settings.description`, `settings.homepage`, `topics:` and `pages:`.
The description and homepage ride the settings PATCH; topics are one `PUT` that replaces the
whole set, so `apply` writes the union of live and declared; the Pages source is one `POST` to
create the site or one `PUT` to update it — never a `DELETE`.

## Do this

A bundled script does the deterministic work. Run it from anywhere in the target repo (it anchors
to the git root). `<skill-dir>` is this skill's base directory — given when the skill loads:

```bash
bash "<skill-dir>/../init/scripts/repo-setup.sh" plan
```

`plan` writes nothing, so it is safe against a repository you only read. Show the operator the
delta it prints, then converge:

```bash
bash "<skill-dir>/../init/scripts/repo-setup.sh" apply
```

Read the exit code — it is the report, and each value means one thing:

| Exit | Meaning | What to do |
|---|---|---|
| 0 | converged | Say so. Nothing to do. |
| 1 | `plan` found drift | Show the delta, then run `apply` — **except** a `!TODO` line: `apply` never creates a placeholder, so fill it into the manifest instead (#198). |
| 2 | bad usage, or an unreadable/unparseable manifest | Fix the manifest; never partially apply. |
| 3 | a surface was refused | Relay **which** surface and why — the report names it. The rest did land. |
| 4 | not inside a git repository | Say so and stop. |

## The desired state

`templates/repo-setup.yml` in the kit is the shipped default. A consumer repo overrides it by
committing its own `.github/repo-setup.yml`, which `repo-setup.sh` prefers — so a consumer's
taxonomy survives a kit upgrade. `--manifest <path>` overrides both.

Six rules govern what `apply` will and will not do, and they are worth relaying to the operator
before the first run against a repo that already has labels:

- **Additive.** A live label the manifest does not declare is reported `!EXTRA` and **kept**. Only
  `--prune` deletes anything. A repo already running `P1`/`P2` must not have its taxonomy renamed
  out from under it.
- **`pruneKeep` outranks `--prune`.** Labels a *tool* owns look undeclared because no human
  declares them, and deleting them breaks the automation that reads them. The manifest's
  `pruneKeep` globs — seeded with release-please's `autorelease: *` and Renovate's `dependencies` —
  are reported `!KEEP` and never deleted. Add the repo's own bot labels there before running
  `--prune` on it.
- **Never clobber.** An issue form that already exists is reported `!SKIP`. A tuned form outranks
  the kit's default.
- **A name in angle brackets is a placeholder** — never created, and reported `!TODO` **and counted
  as drift** on every run (`plan` exits 1), so an unfilled axis stays visible instead of looking
  converged (#198). The `area:` axis ships this way because it names the consumer's code, not the
  kit's: fill it in before `auto-dev` runs a fleet — `apply` will not resolve this one for you.
- **Topics are additive, like labels** — and only when the manifest declares `topics:` at all. A
  live topic the manifest does not name is reported `!EXTRA` and kept; `--prune` drops it. A
  manifest silent on topics never reads or writes them, `--prune` included.
- **The Pages site is created or updated, never disabled.** A 404 on the read means *no site
  yet* and plans a `+ADD`; a 403 is a refusal by name, like every other surface. Disabling a
  site is not a converge, so this skill never issues that `DELETE`.

## Autonomy contract

Run **hands-off**. `plan` is a read — no task list or precondition ceremony. Before `apply`, show
the delta and get a yes when the repo is not the user's own or the run includes `--prune`; a
straightforward `apply` on their own repo needs no gate.

Never invent a taxonomy. If the manifest lacks an axis the repo needs, edit the **manifest** and
re-run — an axis created by hand with `gh label create` is exactly the non-deterministic setup this
skill exists to replace. When a surface is refused, report it and move on: a partially configured
repo with a named gap beats an abort that leaves the operator guessing which half landed.

## Afterwards

`profile-repo --refresh` — this skill's row in the hand-off table, and the reason for it: the
four TODOs are facts now, so the profile records the real axes and the lifecycle skills start
applying them.

`plan` exiting 1 on drift makes it usable as a CI step, if the repo wants configuration drift to go
red the way code drift does.

## Recap

Close with the shared recap shape — [`../_shared/recap.md`](../_shared/recap.md). It owns the four
blocks (verdict · **What happened** · **Artifacts** · **Assumed · skipped · unverified**, where
`None` is a required answer rather than an omission) and the **Next** line, which is read off this
skill's row in that file's hand-off table instead of being decided again here. Everything below is
only what **setup-repo** adds on top of them.

- Name each surface separately — labels, issue forms, repository settings, topics, the Pages
  site — and whether it
  converged, was already converged, or was **refused** (and by what: missing admin rights, an
  unfilled `area:` placeholder, `gh` unauthenticated). A partially configured repo with a named gap
  is a result; an unqualified "done" over a refused surface is not.
- Say whether `--prune` ran. It deletes labels, including the six undeclared GitHub defaults, so it
  is never a silent detail.
