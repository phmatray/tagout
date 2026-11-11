---
title: Demo walkthrough
nav_order: 7
nav_group: internals
---

# Demo Walkthrough — LegacyShop, net6.0 → net10.0

A **real** run of the tagout pipeline (2026-07-22), executed with RoselineMCP against a scratch copy of `samples/LegacyShop`. Every number and diff below is captured tool output, not a mock-up.

## Result first

| | Before | After |
|---|--------|-------|
| Target framework | net6.0 (out of support) | **net10.0 (LTS)** |
| RoselineMCP `analyze_solution` (≥ Warning) | 0 errors / 2 warnings | **0 errors / 0 warnings** |
| Tests | 6/6 green (net6.0) | **6/6 green (net10.0)** |
| Runtime output | `total: 116,01` / `Shipped` | identical |

## Phase 1 — Assess

`analyze_solution` (severity ≥ Warning) on the legacy solution:

```json
{"projects": 3, "diagnosticSummary": {"error": 0, "warning": 2},
 "topDiagnostics": [
   {"id": "RCS1102", "file": "Program.cs", "message": "Make class static"},
   {"id": "SYSLIB0014", "file": "PriceCatalogClient.cs",
    "message": "'WebClient.WebClient()' is obsolete ... Use HttpClient instead."}]}
```

Written to `migration/assessment.md` — risk map: net6.0 EOL (high), `WebClient` (medium). Zero files modified.

> Field note: the very first `analyze_solution` returned 344 bogus "System not found" errors — the copy had never been restored. Lesson encoded in the phase guide: **restore before you analyze**.

## Phase 2 — Baseline

`dotnet build` green, `dotnet test`: **6/6 passed**. Gate contract recorded in `migration/baseline.md`: errors = 0, warnings ≤ 2, tests ≥ 6.

## Phase 3 — Retarget

All three csprojs bumped to `net10.0`; test stack to Test SDK 17.14.1, xunit 2.9.3, runner 3.1.1. Rebuild: 0 errors, 1 warning left (SYSLIB0014 — NETSDK1138 disappeared with the TFM). Tests: 6/6 on net10.0.

> Field note (added in 1.10.0): this run predates the phase-5 **xunit v2 → v3** item, so it landed on the v2 line — as the phase-3 guide prescribed at the time. That is exactly the accidental outcome 1.10.0 turns into a decision: `dotnet list package --outdated` proposes `xunit` 2.9.3 and can never propose `xunit.v3`, because the package *identifier* changes. The numbers above are the real run and are left untouched; see `skills/migrate-legacy/references/xunit-v3-migration.md`.

## Phase 4 — Remediate

`list_diagnostics` on Domain: 62 diagnostics — 1 warning (SYSLIB0014) + info-level with registered fixes (`suggestedFixableIds: ["RCS1015","RCS1058","RCS1170"]`).

**Judgment fix** — `WebClient` → shared `HttpClient` via `edit_member` (preview, then apply):

```diff
-            using (var client = new WebClient())
+            return Http.GetStringAsync(url).GetAwaiter().GetResult();
-            {
-                return client.DownloadString(url);
-            }
         }
+
+        private static readonly HttpClient Http = new HttpClient();
```

**Bulk fixes** — one `apply_fixes` call, preview inspected, then applied: `"Applied 16 fixes to 4 files"` (RCS1015 `nameof` ×9, RCS1058 compound assignment ×2, RCS1170 read-only auto-property ×5), plus RCS1102 (`static class Program`) in App. Gate: **0 warnings, 0 errors, 6/6 tests**.

## Phase 5 — Modernize (safe set)

- `ImplicitUsings` + `Nullable` enabled in Domain → rebuild: **0 new warnings** (constructors already guarantee assignment).
- Async end-to-end: `find_references` on `DownloadCatalog` → `totalReferences: 0` (safe) → `rename_symbol` → `DownloadCatalogAsync` (preview matched the reference count, then applied) → `edit_member` made it truly `async Task<string>` with `await ... ConfigureAwait(false)`.
- Gate: build + tests green, `dotnet run` output identical to baseline.

## Phase 6 — Verify

Final `analyze_solution`:

```json
{"projects": 3, "diagnosticSummary": {"error": 0, "warning": 0, "info": 0, "hidden": 0}}
```

`migration/report.md` written; migration branch history is one commit per green gate:

```
2426ae2 migration: phase 6 verified — report
3693776 migration: phase 5 modernize (ImplicitUsings+Nullable, DownloadCatalogAsync)
272dcf3 migration: phase 4 bulk fixes via apply_fixes (x16 + x1)
c93884d migration: phase 4 replace WebClient with shared HttpClient (SYSLIB0014)
21a4f14 migration: phase 3 retarget net6.0 -> net10.0
974a41d migration: phase 1-2 assess + baseline
```

## Spec success criteria — checked

- [x] Plugin manifests valid JSON; `/migrate`, `/migrate-assess`, `/migrate-verify` present in `commands/`.
- [x] Every phase reference names its exact RoselineMCP calls (verified by grep).
- [x] Demo migrated LegacyShop net6.0 → net10.0: build green, 6/6 tests, 0/0 diagnostics vs 0/2 baseline, identical runtime output.

## Reproduce it

```bash
cp -r samples/LegacyShop /tmp/shop && cd /tmp/shop && git init && git add -A && git commit -m legacy
dotnet restore        # ← before any RoselineMCP analysis
claude
> /migrate
```
