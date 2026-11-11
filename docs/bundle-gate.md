---
title: The bundle gate
nav_order: 6
nav_group: internals
---

# The bundle-gate — opt-in drift check for a committed front-end bundle

`templates/ci-dotnet.yml` ships four steps (plus a fifth, unarmed detector — see *What arms it*
below) that catch a specific, measured failure: a repo commits
built front-end output (a `dist/` consumed by a .NET project) and a dependency bump changes the
lockfile without rebuilding that output — the CI goes green, the CVE dashboard shows the advisory as
fixed, and the vulnerable code still ships. That is worse than doing nothing: a **false remediation**.

Copy the example below to `.github/bundle-gate.json` and edit `src`/`dist` to arm it:

```json
{
  "src": "src/App/WebUI",
  "dist": "src/App/WebUI/dist"
}
```

The shipped file: [`../templates/bundle-gate.json.example`](../templates/bundle-gate.json.example).

## What arms it

The file's **presence**, and nothing else. `hashFiles('.github/bundle-gate.json')` returns an empty
string when the file does not exist, so on a repo that never commits it the four steps are simply
false-conditioned — they do not run, do not fail, and do not appear in the log as anything but
`skipped`. Deleting the file turns the gate back off, and the deletion shows up in a diff — that is
the entire point of routing this through a committed file instead of repo variables (#96): a repo
that never wanted the gate and a repo that lost it are indistinguishable under repo variables, and
the second one is the one that thinks it is protected.

A fifth step, `Détection — un bundle front committé sans configuration de garde`, runs on the
**absence** of the config — the complement of the four above. It looks for a committed bundle
consumed by a .NET project with no `.github/bundle-gate.json` to arm the gate, and prints a
`::warning::` naming both the bundle it found and the file that would arm the gate. It never fails
the job and stays silent on a repo with no such bundle — a detector that could redden an
unconfigured repo would defeat the opt-in design.

## What it measures

The committed bundle still matches what its sources would produce: the workflow reinstalls Node,
rebuilds the bundle in place, then runs

```console
git status --porcelain --ignored -- <dist>
```

and fails if that prints anything. `--ignored` is load-bearing, not incidental. The normal way to
commit build output is `dist/` in `.gitignore` plus `git add -f`, so a newly generated file the
rebuild produces is **ignored**, not merely untracked — plain `--porcelain` omits ignored paths and
would report a stale bundle as clean.

## Why two paths, not one

The output directory is never derivable from the input — `dist`, `build`, `wwwroot/dist` are all
real shapes — so the config needs a `dist`. But two *independent* settings (say, a repo variable for
each) would be worse than one file: point them at different trees and `npm ci` rebuilds one while the
guard inspects the other. The guard finds no drift, reports green, and the bundle it never touched
stays stale — the same false remediation the gate exists to prevent, produced by the gate itself. One
file, validated as a pair before Node even runs, closes that hole.

## The validation rules

The config step (`Configuration de la garde bundle`) refuses rather than exports a partial or
inconsistent config — an empty path would fall back to the repository root and the guard would find
nothing to report, staying green forever while measuring nothing. Every one of these is a hard
refusal, named in the step's `::error::` output:

- The file must parse as a JSON **object** (`{ "src": "...", "dist": "..." }`) — an array or a
  scalar is refused, even if it parses as valid JSON.
- Both `src` and `dist` must be present and non-empty strings.
- Both must be **relative** — an absolute path (leading `/`) is refused.
- Both are restricted to the charset `A-Za-z0-9._/-` — closes output injection into
  `$GITHUB_OUTPUT` as a side effect.
- Neither may contain a `..` segment (no escaping the repository tree).
- `dist` must not equal `src`. Equality used to pass a naive `case` containment check (`*` matches
  the empty string), and it is not a harmless typo: `npm ci` creates `node_modules` inside that same
  tree, the guard's `--ignored` scan then lists that whole ignored tree, and the step goes red on
  every run with advice that can never make it green.
- `dist` must be **strictly under** `src` — unless `src` is `.` (a front-end project at the
  repository root), in which case every relative `dist` qualifies.
- `src` must carry a git-tracked `package.json` (`<src>/package.json`, or `package.json` when
  `src` is `.`) — otherwise the rebuild would run `npm ci` in a directory with nothing to build.
- `.github/bundle-gate.json` itself must be tracked by git — an untracked config would let the gate
  be "on" locally and silently absent from what CI actually checks out.
- `jq` must be present on the runner — checked explicitly, so a missing `jq` is reported as a runner
  problem rather than misdiagnosed as a broken JSON file.

## How to disable it

Delete `.github/bundle-gate.json`. The four steps stay in the workflow, under test, but return to
being false-conditioned — inert, not removed. The deletion itself is a diff, which is what makes
losing the gate a decision instead of an accident.

## Two preconditions to keep in mind

- **Pin `runs-on:` to a dated image**, not `ubuntu-latest`. The gate depends on a reproducible
  native toolchain (Tailwind v4 and lightningcss ship per-platform native binaries); a floating
  runner image can change the native build output out from under a bundle that never actually
  drifted, and the gate would fail on a correct bundle.
- **Rebuild and commit the bundle in the same PR as a Node major-version bump.** A Node major changes
  the ABI of native modules and therefore the bundler's output. A bump PR alone will fail the gate
  with a message that reads like a stale bundle, when the real cause is the toolchain move — fold the
  rebuild into that PR rather than treating the red run as a separate bug.
