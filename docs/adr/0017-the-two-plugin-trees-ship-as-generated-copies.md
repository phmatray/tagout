---
id: 17
title: The two plugin trees ship as generated copies
status: accepted
date: 2026-09-15
tags:
- distribution
- packaging
links:
- type: relates-to
  target: 16
code_refs:
- path: scripts/host-adapters.py
- path: tests/host-adapters/test.sh
parent: Architectural Decision Records
nav_order: 17
---

# The two plugin trees ship as generated copies

## Context and Problem Statement

ADR 0016 shipped `plugins/tagout/` and `plugins/tagout-migrate/` as directories of **git symlinks** into the one tree, plus the handful of files `scripts/host-adapters.py build` writes. It kept `skills/` single-homed at no duplication, and it worked wherever git can write a symlink.

Git on Windows cannot, by default. Creating one needs the `SeCreateSymbolicLink` privilege — Developer Mode or an elevated shell — so `core.symlinks` defaults to `false` and every `120000` entry is checked out as a **regular file holding its target path**. Measured on 2026-09-15 against `tagout@tagout-marketplace` 3.0.0 on Windows 11 (#619): 32 of the two plugins' 33 non-manifest entries came down as 24-to-31-byte text files, `plugins/tagout/skills/merge-pr` was a file rather than a directory, and the loader — which discovers a skill by finding a directory with a `SKILL.md` — found **none**. The session offered the plugins' five commands, which #607 already copies rather than links, and not one of their thirteen skills. Nothing named the cause: `/plugin` reported one generic load error.

`scripts/host-adapters.py check` was equally blind there, and for the same reason in reverse: its partition invariant asked `Path.is_symlink()`, which is false for every one of those text files, so on the platform where the defect lives the gate refused a tree that was in fact correct on every other.

ADR 0016 recorded this outcome in its own Consequences and named the remedy as a support answer — "copy-by-`build` is the remedy if a consumer asks". A consumer asked on the first Windows install.

## Considered Options

- **Copy, don't link.** `generated()` grows from three file kinds to every file of every plugin entry; `build` writes them, `check` refuses a copy that drifted from its source, a copy no source accounts for, a symlink that comes back, and a copy committed at another index mode than its source. Works on every platform and every git configuration, with nothing for a consumer to do or know. Chosen.
- **Ship a remedy script** that materializes the copies inside an installed plugin cache, documented in the README and detected by `preflight.sh`. Cheap, and no duplication — but every Windows consumer stays broken by default, learns it only after a silent failure, and re-runs it after every plugin update; `preflight.sh` is itself reached through a broken link, so the detector cannot run where the defect is.
- **Document `core.symlinks`** — tell Windows users to enable Developer Mode and set `git config --global core.symlinks true` before installing. Zero repository change, but it is a prerequisite `requirements.json` never declared, some machines forbid the toggle, and an install made before setting it fails silently rather than refusing.

## Decision Outcome

Each plugin directory is **generated output**: a manifest, plus a real copy of every tree entry it ships. `scripts/host-adapters.py build` writes them from the one tree; `check` holds them to it. The copy map is derived, never hand-listed — the shared entries (`AGENTS.md`, `CONTEXT.md`, `decisions/`, `hooks/`, `requirements.json`, `scripts/`, `skills/_shared/`, `templates/`), each plugin's own skills by the same partition ADR 0016 defined, and its own extras — so a skill added to `skills/` lands in exactly one plugin with no second list to edit. A copy whose source is itself generated takes the generated text, not what is on disk, so one `build` never leaves a copy a version behind its own source.

Four invariants make the copies as safe as the links were: a copy that drifted is refused by name with its source; a file under `plugins/` that no source accounts for is refused as an orphan, the way a `commands/*.toml` outliving its `.md` already is; any symlink under `plugins/` is refused outright; and a copy committed at a different **index mode** than its source is refused with the `git add --chmod` that fixes it — read from `git ls-files -s` rather than the filesystem, because the platform that commits a wrong mode is usually the one that cannot observe it.

`plugins/` is generated output to the gates that walk the whole repository too: `scripts/pinned-literals-check.py` excludes it, since every file under it is a byte-for-byte copy of a file it already scans at its source. The gates that are root-anchored (`decision-check.py`'s `COPY_ROOTS` and `PROSE_SCOPES`, `recap-wiring-check.py`, `ci-wiring-check.py`, `sigpipe-idiom-check.py`, `tracked-exec-globs.txt`'s pathspecs) need no change: none of them reaches under `plugins/`.

## Consequences

Good: an install works on Windows, in a container with a restricted filesystem, and anywhere else git will not write a link — with nothing for the consumer to enable; `check` now passes on Windows, where it refused every correct tree before; the copies are real files, so a plugin's own `scripts/` and `hooks/` run from the installed directory rather than through a link that may not have survived the checkout; and the mechanism is the one the repository already had, widened, rather than a new one.

Bad: `plugins/` carries ~230 tracked files and about 3 MB of duplicated text, so a change under `skills/` shows up twice in a diff and `build` must run before the commit lands — `check` is what makes forgetting it a refusal rather than a silent drift; a reviewer reads the mechanical half of every such PR; and a consumer whose plugin is already installed from a symlinked release must reinstall to pick the files up, since the cache is a copy of what was checked out.

Contract for a copied path whose source carries a version (#710): Renovate edits only what its managers can read, and a bot cannot run `build`, so a bump to the source alone fails `check` (#665). A copied path with a version-bearing source (`templates/**`, `tests/xunit-v3/apply-transform.py`) must therefore also be listed in `renovate.json` — the actions-manager pattern, the regex managers and the `fix` rule — so source and copies move in one branch; `tests/renovate-config/test.sh` section 11 fails when one is dropped.

Unchanged: the partition, the disjointness, the one-version rule and the manifests of ADR 0016; nothing under `skills/` moves, and every `<kit>/…` path still resolves inside its plugin.
