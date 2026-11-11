---
version: 1
slug: "docs-index-md"
primary_target: "docs/index.md"
related_targets: ["docs/_layouts/default.html","docs/methodology.md"]
---

# Surface brief: docs/index.md (home) and the docs/ site theme

Scope: complete redesign of the docs/ GitHub Pages site with its own Jekyll layouts (the
just-the-docs remote theme is dropped). Home page is Persuade; every inner page is Read.
Audience and job: a developer already inside an agent host, arriving from GitHub, who wants to
install the kit and run a first command. Proof on hand: four migrated apps with measured minutes,
the gate scripts, fifteen ADRs, the journal. Constraints: Pages-native Jekyll (github-pages gem,
libsass), no build step, no JavaScript required to read or install, WCAG AA on both schemes,
hosts rendered from docs/_data/hosts.yml only, every page titled, facts fixed, copy free.
References the owner named: 10k+ star agent-tool sites (spec-kit, BMAD, Claude Code docs, Gemini
CLI, opencode, Aider, Cline, goose); their craft level is the bar, their arrangement is the rut.

## Direction contract

THESIS: A gate that refuses by name is a lock-out tag hung on the machine: who locked it, why,
and what clears it. The home page is that tag and the group hasp its seven locks hang on. It
refuses the category's dark centered hero with the install line pushed below the fold.

OWN-WORLD: White card stock on a concrete-grey ground (on a black bench in the dark scheme). Tag
red #d1202f owns every header band; safety yellow #ffd100 marks the locked state and the hasp;
brass #b08d57 is the grommet; ink #111111 the text. Neutrals come from one eleven-step grey ramp
(g0 white to g10 ink), nothing else. Display and tag headers in Big Shoulders Display black caps;
body in Archivo; typewritten labels, dates and single values in Courier Prime; prose of more than one line in the body face; code in Red Hat
Mono. Controls are tags and punched windows; state is a mark, never a hue: chosen renders filled in ink,
alternatives outlined. Every dimension is a whole 8px grommet module; seams are drawn as 1px rules,
never hidden. No gradient, no glass, no eyebrow labels over headings.

STORY: The visitor reads a real refusal (the roseline gate denying a Read of a .cs file and naming
the RoselineMCP tool instead), understands that every step of both loops is gated and measured,
picks their host, and pastes one command. Below the fold the four apps and their minutes prove it.

FIRST VIEWPORT: Top bar, one row: wordmark left, Methodology / Install / Platforms / GitHub right,
scheme toggle. Left two thirds: one tag at monumental scale, its red band reading the headline
("Every step runs behind a gate that refuses by name"), its body the denial as typewritten fields:
LOCKED BY roseline-gate.sh · ON Read of Program.cs · REASON C# is analysed through RoselineMCP ·
USE INSTEAD mcp__roseline__search_symbols / get_symbol_info. A brass grommet punched top-left.
Right third: the install window, a white punched card: the host tabs (Claude Code filled, the rest
outlined), the chosen host's command in Red Hat Mono with a copy button, "then" line under it. This
window is the primary action. Below both, full width: the group hasp, a yellow bar with seven
padlocks named assess to deliver, and the measured minutes (18 min, ~30 min, ~1 h) set at the
largest size on the page after the tag band.

FORM: Lock-out / tag-out tag, candidate 4 of 7 on the grounded list, seed key b9ea9e8e, code-led.
Signature interaction: on load the hasp's seven locks release in sequence, left to right, one
authored moment with exponential ease-out and a physical settle; with reduced motion they render
released. The host picker swaps filled and outlined with a 160ms settle. Inner pages carry the world
as a thin red header rule, Courier Prime meta fields, ADR status stamps, and the journal as tags
stapled over earlier tags, newest on top and older ones still legible.

Raises kept from the hand: one grey ramp (exposure record); minutes at monumental scale (crisis
wall); history stays open as a record (flyer wall); chosen solid, alternatives dashed (sewing
pattern); whole-unit grid with drawn seams (azulejo).

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the
verdict, DESIGN.md, and every shipping raster carrying its provenance.

## Unresolved
- Search is dropped with the theme; not rebuilt in this round.
- Favicon is redrawn in the new world (a red tag with a grommet), replacing the verdigris gate mark.
