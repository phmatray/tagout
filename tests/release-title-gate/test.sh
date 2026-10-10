#!/usr/bin/env bash
# Golden test for release-title-gate.sh — the check that a PR touching SHIPPED PLUGIN CONTENT
# carries a PR title release-please will actually release. (It was scoped to skills/** until #55
# widened it; "shipped" is now defined by exclusion in the script's NON_SHIPPED list.)
#
# Written fail-path-first, on purpose: #16 removed a `metadata.version` field that "looked
# authoritative precisely because a test appeared to guard it". A gate that cannot be shown to
# fail is that same bug wearing a CI badge — so every refusal below asserts both the non-zero
# exit AND that the message says which type it refused and why.
set -euo pipefail
cd "$(dirname "$0")/../.."

GATE="./scripts/release-title-gate.sh"
[ -x "$GATE" ] || { echo "FAIL: $GATE missing or not executable"; exit 1; }

# Asserts: the gate refused (exit 1) AND explained itself, naming the given substring.
refuses() {
  local name="$1" want="$2"; shift 2
  local out rc=0
  out=$("$GATE" "$@" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL [$name]: expected a refusal, got exit 0"; echo "$out"; exit 1
  fi
  if [ "$rc" -ne 1 ]; then
    echo "FAIL [$name]: expected exit 1 (refusal), got exit $rc"; echo "$out"; exit 1
  fi
  if ! printf '%s' "$out" | grep -qF -- "$want"; then
    echo "FAIL [$name]: refusal did not mention '$want':"; echo "$out"; exit 1
  fi
  echo "  ok: $name — refused, message names '$want'"
}

# Asserts: the gate passed (exit 0).
passes() {
  local name="$1"; shift
  local out rc=0
  out=$("$GATE" "$@" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL [$name]: expected exit 0, got exit $rc"; echo "$out"; exit 1
  fi
  echo "  ok: $name — passed"
}

# ---------------------------------------------------------------- refusals

# 1. The measured production case. PR #20's own branch commit was exactly this title, changing
#    six skills/*/SKILL.md. It shipped only because the PR *title* was retyped `fix(skills):`
#    by hand — two unenforced conventions were the whole guarantee (see #27).
refuses chore-skills 'chore' \
  "chore(skills): drop the per-skill version" skills/merge-pr/SKILL.md

# 2. A PR touching skills/** AND other paths still gates on skills/**.
refuses mixed-changeset 'chore' \
  "chore(skills): tidy the guides" skills/create-issue/SKILL.md README.md

# 3. Renames and deletions under skills/** count as touching it — CI passes both sides of a
#    rename (--no-renames), and a deleted path is still a path.
refuses deleted-skill-file 'chore' \
  "chore(skills): retire the old reference" skills/migrate-legacy/references/phase-9.md

# 4. The exact mistake implement-issue warns about: an issue-derived title whose subject reads
#    like a scope. 'CSV export' is not a type, so this is not a Conventional Commits header.
refuses subject-in-type-position 'Conventional Commits' \
  "CSV export: header row missing" skills/merge-pr/SKILL.md

# 5. No prefix at all — fail closed, do not guess an intent.
refuses no-prefix 'Conventional Commits' \
  "update stuff" skills/merge-pr/SKILL.md

# 6. release-please matches types case-sensitively, so `Fix` is not `fix` and releases nothing.
#    Must say *that*, rather than reading as "not conventional".
refuses uppercase-type 'lowercase' \
  "Fix(skills): stop dropping the follow-up list" skills/merge-pr/SKILL.md

# 7. Other hidden types are refused the same way, naming themselves. Asserted on the quoted type
#    so a two-letter type like `ci` cannot pass by matching some unrelated substring.
#    The hidden set comes from release-please's DEFAULT_CHANGELOG_SECTIONS
#    (src/util/filter-commits.ts): chore, docs, style, refactor, test, build, ci.
refuses docs-skills     "'docs'"     "docs(skills): clarify the trigger list" skills/review-followups/SKILL.md
refuses ci-skills       "'ci'"       "ci(skills): reorder the steps"          skills/review-followups/SKILL.md
refuses refactor-skills "'refactor'" "refactor(skills): extract the helper"   skills/review-followups/SKILL.md

# 8. `feature` is in NEITHER the visible nor the hidden list of that table, so filter-commits.ts
#    drops it and it cuts no release — despite looking like a synonym for `feat`.
refuses feature-skills "'feature'" "feature(skills): add a harvester" skills/merge-pr/SKILL.md

# 8b. skills/** was only ever a proxy (#55). A consumer installs a version-keyed cache that is a
#     whole-repo checkout of the tagged commit, so these are every bit as install-time as skills/:
#     scripts/ (migrate-legacy mandates them by name), commands/ (the five slash commands the
#     plugin exposes), templates/ (the workflows the kit hands to migrated repos) and
#     requirements.json (the single source preflight reads). A chore: fix to any of them cut no
#     release and reached nobody, while the gate printed "not applicable" and exited 0.
refuses chore-scripts      "'chore'" "chore(ci): tidy the inventory script"   scripts/audit-inventory.sh
refuses chore-commands     "'chore'" "chore: reword the migrate command"     commands/migrate.md
refuses chore-templates    "'chore'" "chore: bump the workflow action"       templates/ci-dotnet.yml
refuses chore-requirements "'chore'" "chore: add a prerequisite"             requirements.json
refuses chore-hooks        "'chore'" "chore: adjust the hook"                hooks/claude-hooks.json
# The Copilot CLI plugin manifest lives under .github/, which is otherwise not shipped — yet it is
# what `copilot plugin install` reads (#526), so a chore: edit to it must still cut a release.
refuses chore-copilot-manifest "'chore'" "chore: reword the Copilot manifest" .github/plugin/plugin.json

# 8c. One shipped path is enough — a mixed changeset gates on the shipped half, exactly as the old
#     anchor gated a skills/+README changeset.
refuses mixed-shipped-and-docs "'chore'" \
  "chore: tidy up" scripts/audit-inventory.sh docs/migrate-legacy.md

# 8d. THE EXCEPTIONS. A top-level directory is the wrong granularity for these two: their directory
#     is excluded, but a shipped skill resolves them out of the install cache BY NAME, so taking
#     the directory's word for it would reopen #55 inside the list that closed it.
#       - skills/migrate-legacy/references/xunit-v3-migration.md calls
#         `<kit>/tests/xunit-v3/apply-transform.py` "the witness", and its XUNIT_V3_VERSION /
#         COVERAGE_EXT_VERSION constants land in EVERY migrated csproj (renovate.json watches this
#         exact file, #36).
#       - skills/review-followups/SKILL.md rule 7 mandates `--backlog "<kit>/docs/backlog.md"`.
refuses shipped-anyway-transform "'chore'" \
  "chore(deps): update xunit.v3 to 3.2.3" tests/xunit-v3/apply-transform.py
refuses shipped-anyway-backlog "'chore'" \
  "chore: add a backlog entry" docs/backlog.md

# 8e. The exception is exact, not a prefix — its siblings stay excluded, or `tests/` would be
#     gated wholesale and every golden-test tweak would have to cut a release.
passes sibling-of-exception-still-excluded \
  "chore: tighten the xunit golden test" tests/xunit-v3/test.sh

# 8f. FAIL CLOSED on unknown paths, in BOTH branches of is_shipped: an unknown directory (the `*/`
#     prefix branch) and an unknown root file (the exact-match branch). Without the second, a
#     regression turning the exact match into a prefix test — excluding README.md.bak — would keep
#     the whole suite green.
refuses unknown-toplevel  "'chore'" "chore: add a thing"      newthing/x.md
refuses unknown-root-file "'chore'" "chore: add a thing"      newthing.md
refuses near-miss-suffix  "'chore'" "chore: leave a backup"   README.md.bak
refuses near-miss-manifest "'chore'" "chore: leave a backup"  .release-please-manifest.json.bak

# 8g. .claude/ must not swallow .claude-plugin/ — marketplace.json is shipped metadata, and
#     plugin.json is only exempt for release-please's own PR (8h), never for a human edit.
refuses marketplace-is-shipped "'chore'" \
  "chore: register a command" .claude-plugin/marketplace.json
refuses plugin-json-human-edit "'chore'" \
  "chore: reword the plugin description" plugins/tagout/.claude-plugin/plugin.json

# 8h. NESTED evals/ FIXTURES UNDER skills/** (#58). is_shipped() was root-anchored, so its `evals/`
#     entry excluded only the repo-root harness: skills/review-followups/evals/evals.json matched no rule,
#     hit the fail-closed default, and was gated as shipped content — forcing a release for a
#     trigger-eval fixture no consumer can ever observe. Fail-closed stays right; the fix teaches
#     the classifier the nested-fixture SHAPE (a rule keyed on the `evals/` path segment), not a
#     second literal list.
passes nested-evals-directly-under-skill "chore: retune eval fixtures" \
  skills/evals/case.md
passes nested-evals-under-a-skill "chore(skills): retune the review-followups eval cases" \
  skills/review-followups/evals/evals.json
passes nested-evals-deeper-under-a-skill "chore(skills): retune a nested eval case" \
  skills/review-followups/references/evals/case.md

# The anchoring must hold in BOTH directions, or the rule trades one false positive for another:

# ...a sibling directory merely NAMED evals-runner is a different path segment, not `evals`, and
#    must stay shipped — this is the exact false-positive a bare substring match on "evals" would
#    have introduced.
refuses evals-runner-still-shipped "'chore'" \
  "chore(skills): reword the runner" skills/evals-runner/SKILL.md

# ...an `evals/` segment OUTSIDE skills/ must stay shipped — the rule is anchored on the `skills/`
#    prefix, same as every other rule in is_shipped(). The witness has to be a path that no OTHER
#    rule excludes: docs/skills/evals/… would pass via the `docs/` prefix whether or not the new
#    rule matched it, so it cannot tell an anchored pattern from an unanchored `*/evals/*`.
#    scripts/ is shipped and has no rule of its own, so only the anchor keeps this refused.
refuses evals-outside-skills-still-shipped "'chore'" \
  "chore(scripts): retune a fixture" scripts/evals/fixture.sh

# ---------------------------------------------------------------- passes

# 9. The releasable types — the four VISIBLE sections of DEFAULT_CHANGELOG_SECTIONS. perf and
#    revert really do cut a release, so refusing them would block a legitimate PR while telling
#    the author something false about release-please.
passes fix-skills    "fix(skills): stop dropping the follow-up list" skills/merge-pr/SKILL.md
passes feat-skills   "feat(skills): add a follow-up harvester"       skills/merge-pr/SKILL.md
passes perf-skills   "perf(skills): stop re-reading the profile"     skills/merge-pr/SKILL.md
passes revert-skills "revert(skills): undo the trigger rewrite"      skills/merge-pr/SKILL.md

# 9. A breaking marker releases whatever the type is (major bump), so it passes.
passes breaking-feat     "feat(skills)!: drop the legacy plan comment path" skills/create-issue/SKILL.md
passes breaking-non-feat "refactor(skills)!: rename the profile contract"   skills/init/SKILL.md

# 10. Not applicable: a chore PR that touches no skills path is fine — validating those was an
#     explicit non-goal (#27), a chore(deps) bump releasing nothing is correct behaviour.
passes chore-no-skills "chore(deps): update actions/checkout action to v7" .github/workflows/ci.yml README.md

# 11. The skills/** match is anchored at the repo root: docs/skills/ and .claude/skills/ are not
#     the shipped skills, so they must not trip the gate.
passes nested-skills-dir "docs: rewrite the walkthrough" docs/skills/guide.md .claude/skills/repo-profile.md

# 12. A releasable title is fine even with no skills path — the gate never *requires* a type.
passes fix-no-skills "fix(ci): pin the runner image" .github/workflows/ci.yml

# ------------------------------------------------- the deny-list boundaries (#55)
# The exclusions really do exclude: a change confined to them cuts no release and should not.
passes docs-only  "chore: fix a typo in the walkthrough" docs/migrate-legacy.md
passes tests-only "chore: tighten a golden assertion"    tests/preflight/test.sh
passes evals-reviews-samples-only "chore: refresh the fixtures" \
  evals/skills/case.md reviews/pr-29.md samples/LegacyShop/README.md
passes root-markdown-only "docs: rewrite the intro" README.md ARCHITECTURE.md CHANGELOG.md

# Development-only root config. Gating these would force repo-hygiene PRs (#43 gitignored a
# directory) to cut a release whose changelog entry would be false to consumers. renovate.json is
# here twice over: Renovate's own onboarding PR is titled `Configure Renovate`, not a Conventional
# Commits header at all, so gating it would refuse a PR no bot can retitle.
passes dev-config-only "chore: ignore the worktree dir" \
  .gitignore .editorconfig LICENSE renovate.json release-please-config.json
passes renovate-onboarding-title "Configure Renovate" renovate.json

# Anchored at the repo root: `docs/skills/…` is excluded because it is under docs/, not because it
# contains `skills`.
passes docs-skills-nested "docs: rewrite the walkthrough" docs/skills/guide.md

# LOAD-BEARING BYPASS: release-please's own release PR is titled `chore(main): release X.Y.Z` by
# construction and touches only its manifest, its changelog and the files its extra-files bump. If
# it were refused, no release could ever merge and the gate would deadlock the mechanism it exists
# to protect. Drive the real shape.
passes release-please-pr "chore(main): release 1.11.0" \
  plugins/tagout/.claude-plugin/plugin.json .release-please-manifest.json CHANGELOG.md
passes release-please-pr-subset "chore(main): release 2.0.0" \
  .release-please-manifest.json CHANGELOG.md
# ...and the release PR the LIVE config would open (#526): every extra-files path, the manifest and
# the changelog, read from release-please-config.json itself. A manifest added to extra-files but
# not to RELEASE_PR_FILES — the three host manifests of #526 were, first — goes red here instead
# of on the next release PR.
live_release_files=$(python3 -c 'import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))["packages"]["."]
print(" ".join([e["path"] for e in c.get("extra-files", [])] + [".release-please-manifest.json", c.get("changelog-path", "CHANGELOG.md")]))' \
  "$(cd "$(dirname "$0")/../.." && pwd)/release-please-config.json")
# One path per word, split on purpose.
# shellcheck disable=SC2086
passes release-please-pr-live-config "chore(main): release 2.5.0" $live_release_files

# …and BOTH halves of that exemption are required, or it becomes the blanket path-exclusion it was
# written not to be. Wrong title with the release changeset, and release-please's title with an
# extra shipped file, must each still gate.
refuses release-files-wrong-title "'chore'" \
  "chore: bump the version by hand" plugins/tagout/.claude-plugin/plugin.json .release-please-manifest.json
refuses release-title-extra-file "'chore'" \
  "chore(main): release 1.11.0" plugins/tagout/.claude-plugin/plugin.json skills/merge-pr/SKILL.md

# ---------------------------------------------------------------- plumbing must fail closed

# 13. No paths at all is a broken caller, not an empty diff. Answering "not applicable" there
#     would reopen the hole from the other end, so it is exit 2, distinct from a refusal.
rc=0; out=$("$GATE" "chore(skills): x" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [no-paths]: expected exit 2, got $rc"; echo "$out"; exit 1; }
printf '%s' "$out" | grep -qF 'plumbing failure' \
  || { echo "FAIL [no-paths]: message does not name the plumbing failure:"; echo "$out"; exit 1; }
echo "  ok: no-paths — exit 2, named as a plumbing failure"

# 14. No arguments at all — usage, exit 2.
rc=0; "$GATE" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL [no-args]: expected exit 2, got $rc"; exit 1; }
echo "  ok: no-args — exit 2"

# 15. `--help` must not be reachable through the PR-title argument. CI passes the title in $1,
#     so an unguarded help case let a PR *titled* `--help` print usage and exit 0.
for h in --help -h; do
  rc=0; out=$("$GATE" "$h" skills/merge-pr/SKILL.md 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { echo "FAIL [title-$h]: a PR titled '$h' passed the gate"; echo "$out"; exit 1; }
done
echo "  ok: title-as-flag — '--help'/'-h' as a PR title is refused, not treated as a flag"

# 16. Runs from a foreign working directory (plugin-install simulation, cf. ci.yml). The gate
#     reads no files, so this must hold for both the pass and the refuse path.
KIT="$PWD"
# Scratch dir and EXIT trap come from the shared preamble (#72). Sourced here, deep in the file,
# because that is where this suite's only scratch directory is needed.
. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
WORK=$(kit_scratch)
( cd "$WORK" && bash "$KIT/$GATE" "fix(skills): x" skills/merge-pr/SKILL.md >/dev/null 2>&1 ) \
  || { echo "FAIL [foreign-cwd]: a valid title was refused from another directory"; exit 1; }
if ( cd "$WORK" && bash "$KIT/$GATE" "chore(skills): x" skills/merge-pr/SKILL.md >/dev/null 2>&1 ); then
  echo "FAIL [foreign-cwd]: a chore title passed from another directory"; exit 1
fi
echo "  ok: foreign cwd — same verdict either way"

# ------------------------------------------------- the CI glue: release-title-diff.sh
# This half exists because the first version of the glue lived inline in ci.yml, where nothing
# could test it — and it failed OPEN: `mapfile -t x < <(git diff …)` discards git's exit status,
# so a missing sha produced an empty list that read as "nothing to gate". Every case below is
# one the yaml could not express a test for.

DIFF="./scripts/release-title-diff.sh"
[ -x "$DIFF" ] || { echo "FAIL: $DIFF missing or not executable"; exit 1; }
KIT="$PWD"

FIX="$WORK/repo"
mkdir -p "$FIX"
git -C "$FIX" init -q
git -C "$FIX" config user.email t@example.com
git -C "$FIX" config user.name  "Golden Test"
mkdir -p "$FIX/skills/alpha"
printf 'x\n' > "$FIX/skills/alpha/SKILL.md"
printf 'y\n' > "$FIX/README.md"
git -C "$FIX" add -A
git -C "$FIX" commit -qm base
FIX_BASE=$(git -C "$FIX" rev-parse HEAD)

# A rename *out of* skills/** must still report the old path — moving a skill away is a change
# to skills/**, and default rename detection would report only the destination.
git -C "$FIX" mv skills/alpha/SKILL.md moved.md
git -C "$FIX" commit -qm move
FIX_MOVED=$(git -C "$FIX" rev-parse HEAD)
paths=$( cd "$FIX" && bash "$KIT/$DIFF" "$FIX_BASE" "$FIX_MOVED" | tr '\0' '\n' )
printf '%s\n' "$paths" | grep -qx 'skills/alpha/SKILL.md' \
  || { echo "FAIL [diff-rename]: the old skills/ path is absent:"; printf '%s\n' "$paths"; exit 1; }
echo "  ok: diff-rename — a rename out of skills/** still reports the old path"

# A path holding a double quote is C-quoted by --name-only and would stop matching skills/*.
# With -z it arrives verbatim, and the gate refuses as it should.
printf 'z\n' > "$FIX/skills/alpha/we\"ird name.md"
git -C "$FIX" add -A
git -C "$FIX" commit -qm quoted
FIX_QUOTED=$(git -C "$FIX" rev-parse HEAD)
paths=$( cd "$FIX" && bash "$KIT/$DIFF" "$FIX_MOVED" "$FIX_QUOTED" | tr '\0' '\n' )
printf '%s\n' "$paths" | grep -qx 'skills/alpha/we"ird name.md' \
  || { echo "FAIL [diff-quoting]: the path came back escaped:"; printf '%s\n' "$paths"; exit 1; }
echo "  ok: diff-quoting — a quote in the path survives verbatim, so the anchor still matches"

# THE fail-open. An unreachable sha must exit non-zero — never an empty list, which the caller
# would read as "nothing to gate" and pass.
rc=0
out=$( cd "$FIX" && bash "$KIT/$DIFF" 0000000000000000000000000000000000000000 "$FIX_QUOTED" 2>&1 ) || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL [diff-unreachable]: exit 0 on a missing sha — the fail-open is back"; exit 1; }
[ -z "$(printf '%s' "$out" | tr -d '\n' | tr -d ' ')" ] || printf '%s' "$out" | grep -q 'not present' \
  || { echo "FAIL [diff-unreachable]: message does not name the missing commit:"; echo "$out"; exit 1; }
echo "  ok: diff-unreachable — non-zero, never a silent empty list"

# A genuinely empty diff: exit 0 with no output. This is the case CI is allowed to pass on, and
# it must be distinguishable from the one above by exit status alone.
rc=0
out=$( cd "$FIX" && bash "$KIT/$DIFF" "$FIX_QUOTED" "$FIX_QUOTED" ) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL [diff-empty]: expected exit 0, got $rc"; exit 1; }
[ -z "$out" ] || { echo "FAIL [diff-empty]: expected no output, got:"; echo "$out"; exit 1; }
echo "  ok: diff-empty — exit 0 and empty, distinguishable from a failure by status alone"

# Wrong arity is a caller error, not an empty answer.
rc=0; ( cd "$FIX" && bash "$KIT/$DIFF" "$FIX_QUOTED" >/dev/null 2>&1 ) || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL [diff-arity]: one argument was accepted"; exit 1; }
echo "  ok: diff-arity — refuses a missing argument"

echo "release-title-gate golden test OK"
