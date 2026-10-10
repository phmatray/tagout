---
name: profile-repo
description: >-
  Generate or load the per-repo profile (`.claude/skills/repo-profile.md`) that `create-issue`,
  `implement-issue` and `merge-pr` READ for the repo facts they would otherwise hardcode — commit
  identity, build/test/format commands, labels, merge style, conflict hot-spots. Use when no profile
  exists, to PORT those skills to another repository, or to refresh after the toolchain, labels or
  CI changed: "set up the repo profile", "configure this repo for the issue skills", "make these
  skills work in my other repo", "regenerate the profile", « configure le profil du repo », « fais
  marcher create-issue dans ce repo ». Does NOT file issues, implement code, merge PRs, or WRITE
  labels/templates/settings (setup-repo).
license: MIT
compatibility: >-
  Requires git and bash. An authenticated gh CLI is needed for the label / branch-protection /
  identity probes — without it the profile is generated with flagged TODOs instead.
metadata:
  author: Philippe Matray
  suite: tagout
---

# Resolve the repo profile (config for the issue/PR lifecycle skills)

`create-issue`, `implement-issue`, and `merge-pr` are generic *workflows* wrapped around a thin layer of
**repo-specific facts** — the commit author line, how to build and test, which label means "high
priority", whether the repo squashes or rebases, which files conflict and how to resolve them. Hardcoding
those welds the skills to one repo. This skill lifts them into a single committed file,
**`.claude/skills/repo-profile.md`**, that the three skills read at their preconditions step. Drop the
four skills into a new repo, run this once, and the lifecycle skills speak that repo's language.

The profile is **data, not a skill** — plain markdown with no `SKILL.md`, so the loader ignores it; being
committed, it travels with the repo. Because it exists, the lifecycle skills read it with a plain `cat`
and only fall back to this skill when it's missing — so most of the time this skill isn't even invoked.

## Do this

A bundled script does the deterministic work so you spend tokens on judgement, not probing. Run it
from anywhere in the repo (it anchors to the git root). `<skill-dir>` is this skill's base directory
— given when the skill loads:

```bash
bash "<skill-dir>/../init/scripts/repo-profile.sh" show
```

- **It printed the profile** (and no `--refresh` was asked) → **you're done.** Relay the headline values
  (repo slug, commit identity, build/test/format commands, integration style) so the caller sees what's
  in force. Don't regenerate.
- **It printed `NO_PROFILE`** (exit 3), or the user asked to **`--refresh`** / "set up" / "regenerate" →
  this is the rare generation path. **Read `../init/references/generating.md` and follow it.** In short: run
  `../init/scripts/repo-profile.sh detect`, fill `../init/references/profile-template.md` from the facts it emits, write
  the result to `.claude/skills/repo-profile.md`, and report what you wrote + every TODO you left.

## Autonomy contract

Run **hands-off**. The `show` path is a file read — no need for a task list or precondition ceremony. The
generation path is best-effort inference, not interrogation: fill what `detect` proves, and for anything
it couldn't (a `TODO:` line in its output) write a clearly-marked `<!-- TODO: ... -->` placeholder and
flag it in the report rather than stopping. A profile with a few honest TODOs beats no profile; never
invent a value you couldn't verify — a wrong build command or commit identity is worse than a flagged
blank. Stop only for a real blocker: not inside a git repo (nothing to profile — `detect` exits 4), or
`gh` unauthenticated *and* the gh-only facts can't be read another way (tell the user to run
`! gh auth login -h github.com`).

## Inputs

- **`--refresh`** — regenerate even if a profile exists (re-detect everything; preserve any human-edited
  TODO answers you can still see in the current file).
- A path argument — profile a repo other than the current directory (pass it as the `[dir]` arg to the
  script: `repo-profile.sh show /path/to/repo`).

## Recap

Close with the shared recap shape — [`../_shared/recap.md`](../_shared/recap.md). It owns the four
blocks (verdict · **What happened** · **Artifacts** · **Assumed · skipped · unverified**, where
`None` is a required answer rather than an omission) and the **Next** line, which is read off this
skill's row in that file's hand-off table instead of being decided again here. Everything below is
only what **profile-repo** adds on top of them.

- Say which path ran — `show` read a committed profile back, or the generation path wrote one. They
  produce very different confidence, and the caller cannot tell them apart from the file alone.
- Every `<!-- TODO: … -->` placeholder you left goes in **Assumed · skipped · unverified**, by name.
  An honest TODO is the whole point of the degraded generation path; an unmentioned one is a wrong
  value waiting to be trusted.
- Relay the headline facts (default branch, build/test commands, commit identity) in **What
  happened** — the lifecycle skills act on those, and a wrong one is worse than a flagged blank.
