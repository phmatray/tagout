# Product

<!-- impeccable:product-schema 1 -->

Scope: the docs site under `docs/`, published at https://phmatray.github.io/tagout/.
By the owner's decision (2026-09-14) the generated migration dashboard
(`scripts/report-dashboard.py` → `migration/report.html`) and the README banner are out of scope.

## Platform

web

## Users

A developer who already works inside an agent host (Claude Code first; Codex, Copilot CLI,
Gemini CLI, Cursor and the other hosts in `docs/_data/hosts.yml`), arriving from the GitHub
repository or a shared link. They want to install the kit and run a first command. Success is a
completed install and a first `/migrate-assess`, `create-issue` or similar run, not time on site.

No other audience is confirmed. Evaluators costing a .NET portfolio and peer skill authors visit
too, but were not chosen as an audience to design for.

## Product Purpose

Tagout is MIT-licensed agent skills for two loops, shipped on Claude Code as two plugins. `tagout`
is a hands-off GitHub issue → pull request lifecycle for any repository (create-issue →
implement-issue → merge-pr, with auto-dev, deliver-issue and triage-backlog around them).
`tagout-migrate` is the .NET add-on: a seven-phase, gate-verified pipeline that takes a legacy .NET
application to verified production (assess → baseline → retarget → remediate → modernize → verify →
deliver), with RoselineMCP doing every C# analysis and edit. The site is the methodology's public
home: it explains the method, proves it ran, and installs it on each host.

## Positioning

No green tag, no merge. Every step of both loops runs behind a gate that refuses by name: guarded
git writes check the branch before and after and a hook denies the raw command; a red
build/test/diagnostics gate stops the pipeline; a hook denies a raw `Read` of a C# file and names
the RoselineMCP tool that replaces it. Pipeline times are read from gate commits, not a stopwatch. A
neighbouring "upgrade prompt" or skill pack cannot truthfully claim measured, gate-enforced
verification.

## Operating Context

- The visitor's tool is a terminal or an IDE chat; the site's job ends when a command is pasted.
- Install differs per host and is data-driven: `docs/_data/hosts.yml` is the one home of hosts,
  install lines and capabilities; the home page picker, Install and Platforms pages render it.
- The method is documented at length in `docs/methodology.md`, `ARCHITECTURE.md`, ADRs under
  `docs/adr/`, and a release journal under `docs/journal/`.
- Domain vocabulary (gate, guard, inlet, outlet, filing bar, seed, fold) is defined once in
  `CONTEXT.md`; the site uses those words, not synonyms.

## Capabilities and Constraints

- GitHub Pages builds `docs/` from `main` with native Jekyll (github-pages gem, libsass) and the
  site's own layouts under `docs/_layouts` (no remote theme since 2026-09-14). There is no build
  step, no Gemfile, and no preview on a branch: a broken Sass partial takes the whole site down.
  Build locally with the `ghcr.io/actions/jekyll-build-pages` image before pushing.
- The site's own includes supply navigation (from front matter), heading anchors, mermaid (pinned
  10.9.0, loaded only on pages with a fence) and a copy button on every fenced block; there is no
  search. `tests/skills/test.sh` refuses an untitled `docs/` page, a bare glob in `_config.yml`'s
  `exclude`, a default naming a missing layout, and a Sass import with no partial.
- The site must work without JavaScript: the dark scheme follows `prefers-color-scheme` in CSS and
  the host picker is radio inputs, not script; the toggle, copy buttons, contents list and the hasp
  motion are enhancements in `docs/assets/js/site.js`.
- Light and dark schemes are one token set (`docs/_sass/kit/_tokens.scss`), chosen by system
  preference and a stored toggle (`kit-scheme` in localStorage, `data-kit-scheme` on the root).
- Token cost is an existential concern for the owner: docs changes must not bloat pages the skills
  or agents read, and the site carries no client-side framework.
- No decision yet on imagery beyond the favicon; the only raster the site ships is the case-study
  captures under `docs/case-studies/winrt-portfolio/captures/` (published since 2026-09-14 so
  the Sokoban report's screenshot resolves).

## Brand Commitments

- Name: **Tagout**, repository `phmatray/tagout`, author Philippe Matray.
- Existing assets: `.github/banner.png` (README, still the old mark), `docs/assets/favicon.svg` (the red tag).
- The visual world was replaced on 2026-09-14 by the lock-out tag direction (`DESIGN.md` records the
  system; `.impeccable/surfaces/docs-index-md.md` holds the direction contract). The earlier
  scheme (Atkinson Hyperlegible, verdigris, the gate bar) was evidence only and is gone from the
  tree; the favicon was redrawn as a red tag.
- Voice as written today: declarative, concrete, no marketing adjectives; French source quote on
  the README (« Mise à niveau complète, parfaite, facile et rapide… ») is the kit's motto.

## Evidence on Hand

- Four real migrations, live on GitHub Pages, with per-app reports and a portfolio audit:
  `docs/case-studies/winrt-portfolio/`. Measured pipeline times exist for Chords, Les Fleurs du
  Mal and Pokédex G; Sokoban's first wave was not timed.
- An auto-dev fleet case study: `docs/case-studies/auto-dev/`.
- Twelve hosts with install lines and per-capability support: `docs/_data/hosts.yml`.
- The gates themselves as readable scripts: `hooks/`, and `docs/roseline-gate.md`.
- Fifteen ADRs (`docs/adr/`), a release journal (`docs/journal/`), and `CHANGELOG.md`.
- WCAG AA contrast measured by `scripts/contrast-check.py` for both schemes.
- **Absent, never to be invented:** testimonials, named customers, adoption or download counts,
  third-party benchmarks, press, pricing (it is free, MIT), and any pipeline time not read from
  gate commits.

## Product Principles

1. Prove, do not claim: every number on the site traces to a commit, a script or a live app.
2. The shortest path is install: the visitor should reach their host's command from the first
   viewport in one choice.
3. One home per fact: hosts, decisions, vocabulary and prerequisites each live in one file the
   site renders, never in copy that can drift.
4. Legible without help: no JavaScript, no image and no colour is required to understand a page.
5. Cheap to read for machines too: pages stay lean because agents and skills read this repository.

## Accessibility & Inclusion

WCAG AA contrast is an existing measured gate on both schemes (`scripts/contrast-check.py`) and
must be preserved. The site follows `prefers-color-scheme` and keeps a no-script path for the
scheme and the picker.
