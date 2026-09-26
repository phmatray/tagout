# Issue template → markdown mapping

Filing an issue posts a plain markdown body; it does **not** render the GitHub *form* template in
`.github/ISSUE_TEMPLATE/*.yml`. So you read the YAML form and reconstruct an equivalent markdown body
by hand. This file shows how.

## The rule

For each entry in the template's `body:` array:

| YAML `type` | What to emit |
|-------------|--------------|
| `markdown`  | skip — it's instructional text shown to the human, not a field |
| `input`     | `## <attributes.label>` heading + a one-line answer |
| `textarea`  | `## <attributes.label>` heading + a prose/markdown answer |
| `dropdown`  | `## <attributes.label>` heading + the single best `options` value, verbatim |
| `checkboxes`| `## <attributes.label>` heading + a `- [x]` / `- [ ]` list |

Honor `validations.required: true` — every required field needs real, specific content. The
template's top-level `labels:` and the triage labels (the profile's priority / effort / scope) are
**not** written into the body — they're applied via `--label` when the issue is created in SKILL.md
Step 7, picked from the repo's live taxonomy (the profile's *Labels*). The body is just the form fields
below, which become the visible top of the description (the brainstorm/spec/plan sections follow).

## Worked example — `feature_request.yml`

Suppose the repo's feature_request form has required `Problem / motivation`, required
`Proposed solution`, optional `Alternatives considered`, and a required `Area` dropdown (your
repo's form will differ — always read the live YAML). A compliant body:

```markdown
## Problem / motivation

Reports can only be viewed in the browser today. Finance asks for a monthly extract they can
open in a spreadsheet; copy-pasting the HTML table loses number formatting and locale.

## Proposed solution

A new `Services/CsvExportService` selected via an `Accept: text/csv` content negotiation on the
existing report endpoint, mirroring the JSON exporter's split-by-concern layout:

- one row per report line, header row from the column metadata
- culture-invariant number formatting; locale applied client-side
- streaming write for large reports (no full buffering)

Reuse the existing `ReportModel` untouched. Adds `CsvExportService` and a formatter parallel to
the JSON one.

## Alternatives considered

- Generating the CSV client-side from the JSON — rejected, duplicates formatting rules.
- A scheduled email export — heavier, and doesn't answer the ad-hoc need.

## Area

Reporting / export
```

This body is only the form fields. In the real run the brainstorm/spec/plan get appended below it
(SKILL.md Steps 5-6) before the issue is created. Create it with type + priority + effort labels —
all known by SKILL.md Step 7, since the plan already exists:

```bash
"<kit>/scripts/tracker.sh" issue-create --title "Add CSV export" \
  --label "<type>" --label "<priority tier>" --label "<effort size>" \
  --body-file /tmp/issue-csv-export.md
```

## Worked example — the Spec contract

Continuing the same CSV-export issue: the 📋 Spec (SKILL.md Step 5) closes with the three-heading
contract. Criteria are a **numbered list, never `- [ ]`** checkboxes — the Step 7 readback and
`tick-plan.sh` count every checkbox in the body, so a criterion written as one would inflate the
plan's count and could be ticked by a step that never satisfied it.

```markdown
### Acceptance criteria

1. AC1 — `GET /reports/{id}?format=csv` returns `Content-Type: text/csv` with a header row matching
   the report's column metadata.
2. AC2 — numeric columns render with invariant-culture formatting regardless of the request's
   `Accept-Language`.
3. AC3 — a 10,000-row report streams without the process's working-set growing past the JSON
   exporter's baseline (no full buffering).

### Testing decisions

**Seams under test:** `CsvExportService.Export(ReportModel)`'s returned file content — the same
public boundary the existing JSON exporter is tested through, not a private formatting helper.
**Prior art:** `JsonExportServiceTests` already asserts the JSON exporter's `Export()` output the
same way; the CSV tests mirror its shape.
**A good test here:** assert on the returned CSV text (header row, a formatted numeric cell, row
count) — never on which internal method built each cell (see
[`../../_shared/test-seams.md`](../../_shared/test-seams.md)).

### Out of scope

- A `.xlsx` export format — a separate content type, not part of this issue.
- Client-side locale re-formatting of the CSV — the export stays invariant-culture; locale
  formatting is the spreadsheet's job, not this service's.
```

## Worked example — a seeded body (`--seed #N`)

`--seed #N` (SKILL.md Step 7's seed variant) does not build a template-compliant body from scratch —
it **appends** to one somebody else already wrote. The original is preserved byte for byte above a
`---` rule; only what is below the rule is yours, and only the fields the original genuinely lacks
appear there.

Suppose #412 was filed from the GitHub UI and reads, in full:

```markdown
survey.sh miscounts when an issue has two effort labels

Saw QUEUE list #388 twice yesterday. Probably the jq.
```

The seeded body keeps that intact and adds the trail beneath it:

```markdown
survey.sh miscounts when an issue has two effort labels

Saw QUEUE list #388 twice yesterday. Probably the jq.

---

**Related:** #213 (effort tiers read from the manifest, not a hardcoded spelling)

## Area

area: auto-dev

<details>
<summary><b>🧠 Brainstorm</b></summary>

… problem / approaches / recommendation …

</details>

<details>
<summary><b>📋 Spec</b></summary>

… design doc, closing with the three-heading contract above …

</details>

## 🛠️ Implementation plan

> **For agentic workers:** execute this plan task-by-task with `implement-issue` …

### Task 1: …

- [ ] **Step 1:** …
```

Three things this example is showing, all of them rules rather than style:

- **No `## Problem` heading was added.** The original's first two lines already answer that field; a
  second, better-worded copy under the form's spelling would leave the issue stating its problem
  twice, in two voices. Only **Area** — which a UI-filed issue never carries — was synthesized.
- **The original was not corrected.** "Probably the jq" is a guess, and the Brainstorm below is where
  it gets confirmed or refuted. Editing the author's line to match the finding erases the fact that
  they got there first.
- **The plan sits at the bottom, outside every `<details>`**, exactly as on the create path — it is
  what `implement-issue` reads and what the progress meter counts.

The whole file is written to a temp path and pushed with `"<kit>/scripts/tracker.sh" issue-edit-body
"$N" --body-file` behind a `[ -s … ]` guard (the verb refuses on its own too). That flag replaces the
*entire* body, so an empty file does not "fail to update" #412 — it erases it, along with the two
lines the author wrote.

## Area dropdown values (feature_request)

Pick exactly one, copied verbatim from the option list in the live `feature_request.yml`. If the
profile's *Labels* section defines an area axis, pick the dropdown option that agrees with the
`--label` you'll apply.

## bug_report

Only use this template when the user is filing a defect (something emits wrong/crashes), not an idea.
Read `bug_report.yml` the same way and map its fields (repro steps, expected vs actual, version, etc.)
to headings. Its declared labels apply via `--label`.

## GitLab markdown templates (#508)

A GitLab project (the profile's Tracker line reads `gitlab`) has no YAML *form* to translate — its
`.gitlab/issue_templates/*.md` (listed by `repo-profile.sh detect` under *Issue templates*) is
already the plain markdown body a new issue starts from, the same shape `create-issue` writes.

| GitHub YAML form | GitLab markdown template |
|---|---|
| `body:` array of typed fields | a plain `.md` file, opened as-is |
| `type: markdown` (skip, instructional text) | prose ABOVE the first `## ` heading — still skip it, same reason |
| `## <attributes.label>` heading per field | each `## ` heading in the file, verbatim |
| `validations.required: true` | no such flag exists — **every heading in a GitLab template is
  treated as required**, since the template author had no way to mark one optional |
| top-level `labels:` | GitLab templates carry none — labels still apply via `--label` from the
  profile's live taxonomy, exactly as on GitHub, never read from the template file |

Read the `.md` file, fill in the content under each `## ` heading it already has (adding no heading
of your own — unlike a GitHub form's synthesized fields, a GitLab template's headings are the
complete field list), then append the brainstorm/spec/plan sections below it exactly as the GitHub
path does. Filed through the same `tracker.sh issue-create --body-file` call; the backend
(`scripts/tracker/gitlab.sh`) is what turns that into a GitLab REST v4 call, never this file's
concern.
