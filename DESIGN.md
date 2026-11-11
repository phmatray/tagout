---
name: Tagout
description: A gate that refuses by name is a lock-out tag hung on the machine; the docs site is that tag.
colors:
  g0: "#ffffff"
  g1: "#f2f2f0"
  g2: "#e4e4e1"
  g3: "#cfcfcb"
  g4: "#b3b3ae"
  g5: "#8c8c87"
  g6: "#6b6b66"
  g7: "#4d4d49"
  g8: "#33332f"
  g9: "#1f1f1d"
  g10: "#111111"
  tag-red: "#d1202f"
  tag-red-deep: "#a8161f"
  safety-yellow: "#ffd100"
  brass: "#b08d57"
  brass-deep: "#7f6337"
  bench: "#0c0c0b"
  code-ground-dark: "#060606"
  link-dark: "#f38c93"
  link-hover-dark: "#f7a9ae"
typography:
  display:
    fontFamily: "Big Shoulders Display, Archivo Narrow, Arial Narrow, sans-serif"
    fontSize: "clamp(2.5rem, 4.3vw, 3.875rem)"
    fontWeight: 900
    lineHeight: 0.92
    letterSpacing: "0.005em"
  headline:
    fontFamily: "Big Shoulders Display, Archivo Narrow, Arial Narrow, sans-serif"
    fontSize: "clamp(2rem, 4vw, 3rem)"
    fontWeight: 800
    lineHeight: 0.98
    letterSpacing: "0.002em"
  section-title:
    fontFamily: "Big Shoulders Display, Archivo Narrow, Arial Narrow, sans-serif"
    fontSize: "clamp(1.75rem, 3vw, 2.5rem)"
    fontWeight: 900
    lineHeight: 0.95
    letterSpacing: "0.005em"
  figure:
    fontFamily: "Big Shoulders Display, Archivo Narrow, Arial Narrow, sans-serif"
    fontSize: "clamp(2rem, 4.5vw, 3.5rem)"
    fontWeight: 900
    lineHeight: 0.9
    letterSpacing: "normal"
  stamp:
    fontFamily: "Big Shoulders Display, Archivo Narrow, Arial Narrow, sans-serif"
    fontSize: "0.9375rem"
    fontWeight: 900
    lineHeight: 1
    letterSpacing: "0.12em"
  title:
    fontFamily: "Archivo, system-ui, -apple-system, Segoe UI, sans-serif"
    fontSize: "1.5rem"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "normal"
  body:
    fontFamily: "Archivo, system-ui, -apple-system, Segoe UI, sans-serif"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.6
    letterSpacing: "normal"
  type:
    fontFamily: "Courier Prime, Courier New, Courier, monospace"
    fontSize: "0.9375rem"
    fontWeight: 400
    lineHeight: 1.45
    letterSpacing: "0.01em"
  label:
    fontFamily: "Courier Prime, Courier New, Courier, monospace"
    fontSize: "0.75rem"
    fontWeight: 400
    lineHeight: 1.4
    letterSpacing: "0.06em"
  code:
    fontFamily: "Red Hat Mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "0.875rem"
    fontWeight: 400
    lineHeight: 1.55
    letterSpacing: "normal"
rounded:
  sm: "2px"
spacing:
  u05: "4px"
  u075: "6px"
  u0875: "7px"
  u1: "8px"
  u125: "10px"
  u15: "12px"
  u175: "14px"
  u2: "16px"
  u25: "20px"
  u275: "22px"
  u3: "24px"
  u4: "32px"
  u5: "40px"
  u6: "48px"
  u7: "56px"
  u8: "64px"
  u9: "72px"
  u10: "80px"
  u12: "96px"
  section-gap: "clamp(64px, 8vw, 112px)"
components:
  tag:
    backgroundColor: "{colors.g0}"
    textColor: "{colors.g10}"
    rounded: "{rounded.sm}"
    padding: "{spacing.u3}"
  tag-band:
    backgroundColor: "{colors.tag-red}"
    textColor: "{colors.g0}"
    typography: "{typography.display}"
    padding: "16px 24px 16px 48px"
  tag-band-ink:
    backgroundColor: "{colors.g10}"
    textColor: "{colors.g0}"
    typography: "{typography.display}"
    padding: "16px 24px 14px 48px"
  grommet:
    backgroundColor: "{colors.g1}"
    size: "16px"
  chip:
    backgroundColor: "transparent"
    textColor: "{colors.g7}"
    typography: "{typography.label}"
    rounded: "{rounded.sm}"
    padding: "6px 10px"
  chip-hover:
    backgroundColor: "transparent"
    textColor: "{colors.g10}"
  chip-solid:
    backgroundColor: "{colors.g10}"
    textColor: "{colors.g0}"
  stamp:
    textColor: "{colors.g10}"
    typography: "{typography.stamp}"
    rounded: "3px"
    padding: "6px 8px 4px"
  stamp-rejected:
    textColor: "{colors.tag-red}"
  stamp-superseded:
    textColor: "{colors.g6}"
  stamp-proposed:
    textColor: "{colors.g7}"
  hasp:
    backgroundColor: "{colors.safety-yellow}"
    textColor: "{colors.g10}"
    rounded: "{rounded.sm}"
  scheme-toggle:
    backgroundColor: "{colors.g0}"
    textColor: "{colors.g10}"
    typography: "{typography.label}"
    rounded: "{rounded.sm}"
    padding: "4px 8px 4px 22px"
  copy:
    backgroundColor: "{colors.g10}"
    textColor: "{colors.g2}"
    typography: "{typography.label}"
    rounded: "{rounded.sm}"
    padding: "6px 10px"
  copy-done:
    backgroundColor: "{colors.safety-yellow}"
    textColor: "{colors.g10}"
  code-block:
    backgroundColor: "{colors.g10}"
    textColor: "{colors.g1}"
    typography: "{typography.code}"
    rounded: "{rounded.sm}"
    padding: "16px 72px 16px 20px"
  code-inline:
    backgroundColor: "{colors.g1}"
    rounded: "{rounded.sm}"
    padding: "0.05em 0.35em"
  record-time:
    textColor: "{colors.g10}"
    typography: "{typography.figure}"
  link:
    textColor: "{colors.tag-red}"
  link-hover:
    textColor: "{colors.tag-red-deep}"
  denial:
    backgroundColor: "{colors.g1}"
    padding: "16px 20px"
---

# Design System: Tagout

## Overview

**Creative North Star: "The Lock-out Tag"**

A gate that refuses by name is a lock-out / tag-out tag hung on a machine: who locked it, why, and what clears it. The site is built from that one object. A white card with a 1.5px ink rule, a brass grommet punched top-left, a red header band, and typewritten fields filled in below; the home page hangs the tag at monumental scale next to a punched install window, and under both a safety-yellow group hasp with seven padlocks, one per pipeline phase. Every inner page carries the same object smaller: a short red rule over the title, Courier Prime meta fields, an ADR status stamp, and a journal of release tags stapled one over the next.

The surface is a workshop, not a brochure. The ground is concrete grey (a black bench in the dark scheme) and everything on it is card stock, ink, and printed colour. Neutrals come from one eleven-step grey ramp; the only chroma is tag red, safety yellow, and the brass of the grommet, and each appears only where it means something. Density is that of a filled-in form: ruled rows, dotted field lines, tabular numerals, and measured minutes set as the largest type after the band. Seams are drawn (1px and 1.5px rules), never hidden behind gradients, glass, or shadows doing structural work.

The build is Pages-native Jekyll with libsass: one stylesheet, custom properties for every token, radio inputs for the host picker, and JavaScript only as enhancement. The dark scheme is the same token set re-bound; the tag itself refuses to go dark, because card stock is white in any light.

**Key Characteristics:**
- One object, the tag, reused at every scale: hero, install window, ADR header, journal entry, chip, toggle.
- One grey ramp (g0 white to g10 ink) for every neutral; red, yellow, and brass each have one job.
- Four faces with four jobs: Big Shoulders Display for what is printed on the tag, Archivo for reading, Courier Prime for what is typed onto it, Red Hat Mono for code.
- State is a mark, not a hue: chosen is filled in ink, unchosen outlined; accepted is ink, rejected red, superseded faded, proposed dashed.
- Sections are ruled, not boxed; tables are ruled, not gridded; the tag is the only thing with a border and a shadow.
- One authored motion moment (the locks release) and 160ms settles everywhere else.

## Colors

Card stock, ink, concrete, and three printed colours, each measured against its ground.

### Primary
- **Tag Red** (`{colors.tag-red}`): the header band of every red tag (hero, favicon, wordmark mark), links in the light scheme, the current-page dot in the side navigation, the active rule in the on-page contents, the underline of the current top-nav item, the 6px rule above every article title, the refusal mark (a circle-slash), the journal version number, the caret and form accent. Rejected stamps are red. 5.30:1 on white in either direction.
- **Tag Red Deep** (`{colors.tag-red-deep}`): link hover only.

### Secondary
- **Safety Yellow** (`{colors.safety-yellow}`): the locked state. The hasp bar, the padlock keyway, text selection, the 3px focus ring, the skip link, the scheme toggle's pressed dot, the copy chip once copied, and syntax keywords on the ink code ground. Yellow always carries g10 ink (12.92:1).

### Tertiary
- **Brass** (`{colors.brass}`) and **Brass Deep** (`{colors.brass-deep}`): the grommet's 3px ring and its 1px drop edge. Brass is never text and never a fill.

### Neutral
The ramp is the whole neutral vocabulary; semantic aliases bind steps to roles, and the dark scheme rebinds the aliases, not the ramp.
- **g0 white**: card (light), band ink, the tag in both schemes.
- **g1**: ground (light), field grey inside tags (denial block, inline code), code ink on the ink ground; ink in the dark scheme.
- **g2**: copy chip text on ink, punctuation in code; dark code ink.
- **g3**: rules (light), the dotted lines under denial fields.
- **g4**: the dotted field line under every `dd`, `td`, record and refusal row; comments in code; dark ink-soft.
- **g6**: ink-faint in the light scheme and inside any tag: contents title, nav counts, superseded stamp, hidden heading anchors. Measured 5.36:1 on card and 4.78:1 on ground (AA at every size it is used at).
- **g5**: ink-faint in the dark scheme (4.89:1 on g9, 5.79:1 on the bench), and in both schemes the chip's outline and the scrollbar thumb, which are marks, not text.
- **g6**: defined, not bound to any role.
- **g7**: ink-soft (light): section leads, field labels, table heads, meta, the typed "from" column.
- **g8**: hasp secondary text on yellow (8.68:1); dark rules and dark field grey.
- **g9**: dark card (reading surfaces, side navigation hover).
- **g10**: ink, strong rules, tag borders, the code ground, the install band, solid chips, padlock bodies.
- **Bench** (`{colors.bench}`) and **Code Ground Dark** (`{colors.code-ground-dark}`): the two dark-scheme grounds that sit below the ramp; the bench is the dark page ground, the code ground is the dark scheme's code block.
- **Link Dark** (`{colors.link-dark}`) and **Link Hover Dark** (`{colors.link-hover-dark}`): tints of tag red used only as link colour on dark surfaces (7.06:1 on g9).

### Named Rules
**The One Ramp Rule.** Every neutral is a step of g0..g10 bound through an alias (`--ground`, `--card`, `--ink`, `--ink-soft`, `--ink-faint`, `--rule`, `--rule-strong`, `--field`). New surfaces pick a step; they do not mix a new grey.

**The Colour Means Something Rule.** Red is a band, a link, a current marker, or a refusal. Yellow is locked, selected, or focused. Brass is the grommet. No other use, and no other hue, on the page; the Rouge syntax set on the ink code ground is the one shipped exception.

**The Card Stock Rule.** In the dark scheme the bench, rules, and reading surfaces go dark; `.kit-tag` re-scopes card, ink, rule, field, and link back to their daylight values and stays white.

## Typography

**Display Font:** Big Shoulders Display 700/800/900 (with Archivo Narrow, Arial Narrow, sans-serif)
**Body Font:** Archivo 400/600/700 and italic 400 (with system-ui, sans-serif)
**Label/Mono Font:** Courier Prime 400 for what is typed onto the tag; Red Hat Mono 400 for code

**Character:** A stencil-cut condensed black for what the tag says, a plain grotesque for the explanation, and a typewriter for what a hand filled in. Root size is 17px (16px under 40rem); body runs at 1rem/1.6 on a 44rem measure; numerals are tabular everywhere (`tnum`).

### Hierarchy
- **Display** (900, `clamp(2.5rem, 4.3vw, 3.875rem)`, 0.92, uppercase, max 15ch): the hero tag band. Section titles use the same face at `clamp(1.75rem, 3vw, 2.5rem)`/0.95; the install band at 1.5rem; the hasp label and hasp minutes at 1.75rem; the wordmark at 1.25rem with 0.04em tracking; lock names at 1.0625rem with 0.04em.
- **Figure** (900, `clamp(2rem, 4.5vw, 3.5rem)`, 0.9, uppercase, tabular): the measured minutes in the lock-out record; the largest type after the band.
- **Headline** (800, `clamp(2rem, 4vw, 3rem)`, 0.98, mixed case, max 22ch): the article title on every Read page, under a 6px red rule 96px wide.
- **Title** (Archivo 700, 1.5rem, 1.2): article h2, opened by a 1px rule above and 56px of air. h3 is 700 at 1.1875rem/1.25; h4 at 1rem; h5 and h6 at 0.9375rem.
- **Body** (Archivo 400, 1rem, 1.6): running text on a 44rem measure; the hero lead runs at 1.0625rem/1.5 on 58ch; field values that run to more than one line (the plugin descriptions, every value in the denial) take the body face at the field's size; UI text (top nav, side nav, actions, notes) at 0.9375rem; side-nav children, footnotes and "then" lines at 0.875rem.
- **Type** (Courier Prime 400, 0.9375rem, 1.45, 0.01em): single-value fields in `dl.kit-fields`, the record's "from" column, and dates. Meta rows, journal dates, chips, footer and contents run at 0.8125rem.
- **Label** (Courier Prime 400, 0.75rem, 0.06em to 0.08em, uppercase): field names (`dt`), table heads (`th`), the contents title, the denial title, prev/next captions, ADR tag pills, the scheme toggle; the lock gate line runs at 0.6875rem.
- **Stamp** (900, 0.9375rem, 1, 0.12em, uppercase): the ADR status word.
- **Code** (Red Hat Mono 400, 0.875rem, 1.55): code blocks; inline code at 0.875em of its context.

### Named Rules
**The Printed / Typed Rule.** What the tag was printed with is Big Shoulders in caps (bands, section titles, stamps, lock names, minutes). What was typed onto it afterwards is Courier Prime (labels, dates, single values, meta). Archivo is for the reader, not the tag: prose of more than one line is set in the body face even inside a field, because a typewriter paragraph reads as a form to fill in. Nothing on the page is set in a system face.

**The Field Label Rule.** A Courier Prime uppercase label at 0.75rem sits above a value, a table column, or a list; it never sits above a heading.

## Layout

A single 8px unit (`--unit`) with two widths: the reading measure 44rem (`--measure`, about 72 characters), and the page 84rem (`--wide`) for the top bar, home, footer and the Read grid. Section rhythm is set in whole units: sections on the home page are `--section-gap` apart (`clamp(64px, 8vw, 112px)`: 112px on a desktop, 64px on a phone), the one section-spacing token, section heads close with a 1.5px ink rule 24px below and 16px of padding; article heads carry 32px below and a 1.5px rule; h2 gets 56px above; prev/next 64px above. Component interiors step in half and quarter units (4, 6, 7, 10, 12, 14, 20, 22px) for field rows, chips, and toggles.

The Read grid is one column under 60rem, `15rem minmax(0,1fr)` from 60rem with the side navigation sticky at 80px, and `15rem minmax(0,1fr) 13rem` from 84rem with the on-page contents sticky on the right. The home hero is cut in three, in DOM order: the tag's pitch (band, lead, tagline), the install window, then `.kit-hero-more` (the plugin list, the refusal, the actions). From 64rem it is `2fr minmax(20rem,1fr)` over `auto 1fr` with the areas `"tag install" "more install"` and no row gap: the pitch and `.kit-hero-more` join into one tag (no border, no radius and no shadow across the seam, the lower half's shadow clipped at it) and the install window runs beside both. Under 64rem the three stack 16px apart in DOM order, so on a phone the command follows the pitch; under 40rem the band tightens to 16px 20px 16px 40px, the pitch body to 16px 20px with a 12px gap, and the page's top padding to 16px, which puts the install command inside the first 390x844 viewport. Under 40rem the rest of the home page tightens so it stays a pitch (at most 5,600px tall at 390px): the run's numerals sit in a 40px column beside their step, the three figures stay side by side at 2.25rem, section heads close 16px below with 12px of padding, section leads and command rows run at 0.9375rem/1.45, refusal, command and site-index rows drop to 16px, 8px and 8px of vertical padding, and site-index descriptions to 0.875rem/1.45. The hasp is `minmax(15rem,1.4fr) repeat(7, 1fr)`; under 64rem the label spans the row and the locks wrap in fours; under 30rem in twos. Under 40rem the root drops to 16px, the record table collapses to two-column rows with the minutes on the right, and prev/next stacks. Under 48rem the top nav reduces to Docs and GitHub. Under 30rem field lists drop to one column.

The body's children are capped at the measure; tables, code, figures, tags, and mermaid diagrams may take the full column. Page padding is 24px horizontal; the top bar is 56px tall, sticky, on the ground colour with a 1px rule beneath. Scroll padding is 80px.

## Elevation & Depth

The page is flat. The only thing that leaves the ground is the tag: one diffuse shadow (`0 8px 24px -12px rgba(17,17,17,0.35)`) lifts every card and the hasp off the concrete; a hovered journal tag rises 3px onto the lift shadow (`0 16px 32px -14px rgba(17,17,17,0.45)`). The grommet carries a 1px inset and a 1px brass-deep edge so it reads as punched. Depth otherwise is drawn: a 1.5px ink border on tags, 1px rules between rows, dotted g4 lines under fields, and the stacked journal tags overlapping by 12px with a 0..2 unit step so older tags stay legible. Nothing uses a gradient, backdrop filter, or hard offset shadow beyond the grommet's 1px brass edge.

### Shadow Vocabulary
- **Tag** (`box-shadow: 0 8px 24px -12px rgba(17, 17, 17, 0.35)`; dark `0 8px 24px -12px rgba(0, 0, 0, 0.8)`): every `.kit-tag` and the hasp at rest.
- **Lift** (`box-shadow: 0 16px 32px -14px rgba(17, 17, 17, 0.45)`; dark `0 16px 32px -14px rgba(0, 0, 0, 0.9)`): a journal tag on hover, with `translateY(-3px)` over 220ms.
- **Grommet** (`inset 0 1px 2px rgba(17, 17, 17, 0.35), 0 1px 0 var(--brass-deep)`): the punched hole.
- **Focus** (`outline: 3px solid var(--yellow); outline-offset: 2px; box-shadow: 0 0 0 5px var(--ink)`): every focusable element, and the chip whose hidden radio is focused.

### Named Rules
**The Drawn Seam Rule.** Where two things meet, a rule is drawn: 1px g3 between page regions, 1.5px ink around and inside a tag, 1px dotted g4 under a field. No seam is implied by tone alone.

## Shapes

Square with the corners knocked off: one radius of 2px on tags, chips, code, inline code, the toggle, and ADR tag pills (the stamp alone rounds to 3px, the favicon to 4). Circles are reserved for holes and marks: the grommet (16px, 3px brass ring), the side-nav current dot (6px red), the toggle's state dot (9px), the refusal mark (32px red circle with a 45-degree slash). Borders are 1.5px ink on any tag and any strong seam, 1px g3 on soft seams, 1.5px solid g5 on an unchosen chip, 2.5px on a stamp (dashed only when proposed). The stamp is rotated -4 degrees from its bottom-left corner and masked with an inline SVG turbulence so its ink breaks up. Padlocks are 44x56 SVGs: a 5px round-capped shackle stroke, a 36x28 body with a 2px radius, a yellow keyway. Chevrons are 8px or 9px borders rotated, not glyphs. No icon fonts and no raster anywhere in the interface; a case-study report may embed its own screenshot as content.

## Components

### Tag
The site's one object; everything else is a smaller tag or a ruled row.
- **Shape:** 1.5px ink border, 2px radius, tag shadow, white card in both schemes.
- **Grommet:** 16px circle at 12px from the top-left, ground-coloured hole with a 3px brass ring.
- **Band:** tag red with white ink, 16px 24px 16px 48px padding (the left inset clears the grommet), a 1.5px ink rule beneath; the title is Display in caps. The install window's band is ink (g10) with card-coloured text at 1.5rem: an ink band means a tool, a red band means the tag.
- **Body:** 24px padding; the hero body 24px 32px with a 20px gap, `.kit-hero-more` continuing it at 0 32px 24px.
- **Fields (`dl.kit-fields`):** two-column grid `max-content 1fr` with no column gap (the `dt` carries 16px of right padding so the dotted line runs unbroken under label and value), Courier Prime 0.9375rem (values that wrap, as in the hero's plugin list and denial, in Archivo); `dt` uppercase 0.75rem 0.06em ink-soft; both cells 10px vertical padding over a 1px dotted g4 line; one column under 30rem. Inside the denial block (field grey, 1px g3 border, 16px 20px padding) the rows tighten to 7px and the last row loses its line.

### Chips
A small tag used as a control: host tabs, the copy button.
- **Style:** Courier Prime 0.8125rem uppercase 0.02em, 6px 10px padding, 1.5px solid g5 border, ink-soft text, transparent ground, 2px radius; 160ms ease-out on border, background and colour.
- **State:** hover turns the border and text ink; chosen (`.is-solid`, `:active`, or the checked radio's label) is a solid ink fill with card text. On the ink code ground the copy chip is outlined in g5 with g2 text, brightening to g0 on hover, and turns solid safety yellow with ink text for 1.6s once copied.

### Stamp
Status as a mark, never a hue.
- **Style:** Big Shoulders 900 0.9375rem uppercase 0.12em, 2.5px border in currentColor, 3px radius, 6px 8px 4px padding, rotated -4 degrees, ink broken by an SVG turbulence mask.
- **State:** accepted is ink; rejected is tag red; superseded is ink-faint; proposed is a dashed ink-soft outline with the mask off.

### Hasp
The group lockout: a safety-yellow bar, 1.5px ink border, tag shadow, seven padlocks, one per cell, separated by 1.5px rules at 25% ink; no rail is drawn (a line through the shackles read as an artifact and was removed 2026-09-14).
- **Label column:** Display 1.75rem, a Courier Prime 0.8125rem g8 line, and the measured minutes (`dl.kit-hasp-times`, minutes in Display 1.75rem tabular over 1px 35% ink rules).
- **Lock:** a 44x56 SVG on a `56px auto 1fr` row grid with 6px gaps, 16px 8px 12px padding, 1.5px 25% ink rules between locks; name in Display 1.0625rem, gate line in Courier Prime 0.6875rem g8.
- **Motion:** the one authored moment. Each shackle transitions `transform 700ms cubic-bezier(0.16, 1, 0.3, 1)` to `translateY(-9px) rotate(-28deg)` from its bottom-left; the script adds `.is-open` lock by lock at 350ms + 140ms per lock once 15% of the hasp is in view; under `prefers-reduced-motion` the hasp renders `.is-released` with no transition.

### Inputs / Fields
The host picker is radio inputs, visually hidden, whose labels are chips; the chosen panel shows with `kit-settle` (opacity 0 to 1, 2px rise, 160ms ease-out), none under reduced motion. Focus on the hidden radio lights its chip with the yellow ring. There are no text inputs on the site.

### Navigation
- **Top bar:** sticky, ground-coloured, 56px, 1px rule beneath; wordmark in Display 900 1.25rem caps with a 22px red tag mark; links Archivo 600 0.9375rem with a 2px transparent bottom border that turns red on hover and on the current page; the scheme toggle is a tiny white tag in Courier Prime 0.75rem with a 9px ring that fills safety yellow when pressed.
- **Side navigation:** 0.9375rem Archivo, entries separated by 1px g3 rules; each link carries a 6px dot that is transparent until the current page, where it turns red and the row goes bold on the card colour; hover uses the card colour; sections are native `details` with a rotated 8px chevron, a Courier Prime 0.75rem count, and 0.875rem ink-soft children. Under 60rem the whole list folds under a bordered "Documentation" button.
- **On-page contents:** from 84rem, 0.8125rem, a Courier Prime "On this page" label over a 1px rule, links on a 1px transparent left border that turns red when active.
- **Prev / next:** 64px above, 1.5px ink rule, Courier Prime 0.75rem uppercase captions, ink links that turn red on hover.

### Tables and rows
Ruled, never boxed. Heads are Courier Prime 0.75rem uppercase ink-soft over a 1px ink rule; each row sits on one 1px dotted g4 line drawn on the `tr`, never per cell (per-cell dots never share a phase and tick at the joins), 10px vertical padding in articles, 16px in the record, 12px in the command table; the last row has no line. The record's app link is 700 at 1.125rem, its minutes are Figure type right-aligned with a Courier Prime 0.75rem 0.06em caption; the command column is Red Hat Mono 0.875rem. Refusals, child lists, and the site index follow the same dotted-row rule, refusals with a 32px red circle-slash mark in the first column.

### Journal stack
One tag per release in a reversed list: `auto 1fr auto` grid, 16px 24px 16px 48px padding, each tag overlapping the one above by 12px and stepping right by 0, 8, or 16px (one column, no step, under 40rem); the version in Display 900 1.5rem tag red on a 7ch tabular column so titles align, the title Archivo 700 1.0625rem, the date Courier Prime 0.8125rem; hover lifts 3px onto the lift shadow over 220ms.

### Code
Blocks on ink (g10, g1 text; `#060606`, g2 in the dark scheme) with a 1.5px ink border, 2px radius, 16px 20px padding plus 72px on the right for the copy chip, Red Hat Mono 0.875rem/1.55, wrapped. Inline code on field grey with a 1px g3 border at 0.875em. Syntax on the ink ground: comments g4 italic, keywords safety yellow, punctuation g2, strings `#9be29b`, names `#9ecbff`, numbers `#f0b27a`.

## Do's and Don'ts

### Do:
- **Do** build any new surface from the tag: 1.5px ink border, 2px radius, tag shadow, grommet at 12px, band with a 48px left inset.
- **Do** pick every neutral from g0..g10 through its alias, and rebind aliases (not the ramp) for the dark scheme; keep `.kit-tag` white.
- **Do** set what the tag says in Big Shoulders caps, what was typed on it in Courier Prime, and the reading text in Archivo at 1rem/1.6 on a 44rem measure.
- **Do** draw every seam: 1px g3 between regions, 1.5px ink on and inside tags, 1px dotted g4 under rows.
- **Do** show state as a mark: filled versus outlined for chosen, ink / red / faded / dashed for stamps, a red dot or rule for the current item.
- **Do** keep motion to 160ms ease-out settles; the lock release (700ms, 140ms stagger) is the page's one authored moment and renders released under reduced motion.
- **Do** keep the whole site legible with no script, no image, and no colour: radios for the picker, media query for the scheme, text for every state.

### Don't:
- **Don't** put a kicker or eyebrow above an h1 or h2; the Courier Prime label belongs above fields, columns, and lists.
- **Don't** use the tag or any bordered card as page structure; sections are separated by rules and `--section-gap` of air.
- **Don't** box tables or zebra rows; a 1px ink head rule and dotted row lines are the whole grid.
- **Don't** add a gradient, glass, backdrop filter, hard offset shadow (beyond the grommet's 1px brass edge), or raster image; the tag shadow and the grommet inset are the only depth.
- **Don't** use red, yellow, or brass for decoration, and don't introduce a fifth colour beyond the shipped Rouge syntax set on the code ground; red is band, link, current marker, or refusal; yellow is locked, selected, or focused; brass is the grommet only.
- **Don't** set any text in a system face or an icon font; padlocks, the wordmark mark, and chevrons are inline SVG or CSS.
