# Open a pull request

Shared procedure for opening a pull request the way the kit expects. `implement-issue` runs §1 in
Step 4, before it creates a worktree, and the whole of it in Step 5 for its draft PR; `create-pr`
runs §1 in Step 2, before its push, and §2 in Step 3 for a finished feature branch. The caller owns
what comes before (the commit, the guarded push) and what to do about a PR that already exists; the
lookup, the title and `gh pr create` live **here**, once.

Six names have to be in scope, and the caller sets them before it gets here (§1 reads only the
first two):

```bash
BRANCH=<the branch the PR opens from>   # already pushed through guarded-push.sh before §2
ISSUE=<the issue number, digits only>   # or empty for a PR with no issue: no suffix, no Closes, no issue guard
DRAFT=<1 or 0>                          # 1 opens a draft, 0 a PR ready for review
BASE=<the branch the PR merges into>    # the profile's *Default branch*
TITLE_PATHS=<the paths the title gate classifies>
    # a scaffold: the plan's **Files:** paths · real work: git diff --name-only origin/<default>...HEAD
BODY_FILE=<a file holding the PR body>  # carries `Closes #$ISSUE` when $ISSUE is set, none when it is empty
```

---

## 1. Look for an existing PR

**By branch name first** — a live-ref lookup:

```bash
gh pr list --head "$BRANCH" --json number,url,isDraft,headRefName --jq '.[0] // empty'
# `// empty`: `.[0]` of a no-match `[]` is `null`, and jq prints that as the string "null" — output.
```

Any output → a PR is already open from this branch: report it and **stop**. The caller decides
whether to resume onto it.

**Then by issue, when `$ISSUE` is set** (empty → skip to §2: no issue, nothing to close). A branch
name is only a guess at what a prior run called itself (#214), so ask GitHub about the *issue* too.

`$ISSUE` must already be a validated non-empty digit string by this point — the pattern below
concatenates it unescaped, and an empty value would degrade `…#\b` into "closes any issue", matching
PRs unrelated to this one.

Wide net first (a plain search can hit a PR that merely *mentions* the issue), then narrow to PRs
whose body actually closes it via GitHub's closing-keyword set. `gh pr list --jq` cannot take
`--arg`, so the fetch and the filter are two commands — the second one embeds the filter program
directly, the same way `skills/merge-pr/references/merge-mechanics.md` embeds its own marked verdict
program, so there is exactly one copy of it and `tests/pr-existence-guard/test.sh` extracts and runs
the thing this section tells you to paste, not a paraphrase of it:

```bash
case "$ISSUE" in
  ''|*[!0-9]*) echo "REFUSED — \$ISSUE ('$ISSUE') is not a validated non-empty digit string"; exit 1 ;;
esac

# --limit above the default page size (30): an issue that has accumulated several stale/duplicate
# PRs — the exact scenario this guard targets — could otherwise truncate the real closer off the
# first page before the filter below ever sees it.
gh pr list --search "$ISSUE in:body" --state open --limit 100 \
  --json number,headRefName,body,url,isDraft > /tmp/issue-$ISSUE-mentions.json

# A failed or rate-limited fetch leaves an empty file, and jq silently treats empty input as "no
# rows" rather than an error — the "load-bearing, not decoration" lesson of implement-issue's plan
# fetch applies here too: an unchecked empty fetch reads as "0 open PRs found" and lets a duplicate
# PR through on a transient API failure, silently reproducing the bug this guard exists to close.
[ -s /tmp/issue-$ISSUE-mentions.json ] || {
  echo "REFUSED — the PR search returned nothing; retry rather than treat this as '0 found'"; exit 1; }

jq --arg issue "$ISSUE" '
  # >>> issue-scoped PR-existence guard
  # $issue is the numeric issue id, bound above via --arg. `\b…#<n>\b` stops "214" from matching a
  # #2140/#1214 substring. `:?\s*` accepts both "Closes #42" and "Closes: #42" — GitHub recognizes
  # the colon form too — while still requiring the keyword to sit immediately before the number, not
  # just somewhere in the same sentence. `.body // ""` guards a PR with no description: `gh` reports
  # that as JSON `null`, and `test()` throws on `null` rather than treating it as non-matching (#259)
  # — coercing to `""` makes it evaluate to "no match" like any other non-closing body.
  [.[] | select((.body // "") | test("(?i)\\b(close[sd]?|fix(e[sd])?|resolve[sd]?):?\\s*#" + $issue + "\\b"))]
  # <<< issue-scoped PR-existence guard
' /tmp/issue-$ISSUE-mentions.json > /tmp/issue-$ISSUE-closers.json

jq 'length' /tmp/issue-$ISSUE-closers.json
```

⚠️ **Residual limitation, not fixable from this side:** `gh pr list --search` hits GitHub's Search
API, which is *eventually consistent* — unlike the branch-name lookup's `gh pr list --head`, a live-ref
lookup. A PR created seconds ago can still search as absent. This narrows the #195-shaped race, it
does not close it to zero; the branch-name lookup (checked first) is the fast path that still catches
a same-slug race this cannot.

- `0` → nothing found; go on to §2.
- `1` → an open PR already closes this issue: report it (`jq -r '.[0].headRefName'
  /tmp/issue-$ISSUE-closers.json` is its branch) and **stop** — no second `gh pr create`. The caller
  decides whether to resume onto it.
- `2`+ → a pre-existing duplicate pair already on GitHub (the exact #195 shape). The one to resume
  onto is the one with the most commits (`gh pr view <n> --json commits --jq '.commits | length'` — an
  untouched scaffold has exactly one); **on a tie** (e.g. both are still untouched scaffolds), the
  **lowest PR number** — the one created first — so two independent runs of this same recipe converge
  on the same choice instead of diverging further. Report it, name the others, and **stop**; don't
  silently pick one and stay quiet about it.

A PR that once closed this issue but is now closed doesn't count — `--state open` already excludes it.

---

## 2. Open the PR

**Follow the profile's *PR title convention*.** The common shape is a Conventional Commits prefix
_and_ a `(#<issue>)` suffix — two independent constraints, both enforced, e.g.
`feat(export): stream CSV report downloads (#172)`.

- **Prefix** — when the profile notes a Conventional Commits gate, start with `<type>[(scope)]: `,
  where `<type>` is one of `feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert`. A
  semantic-PR-title CI check rejects the PR otherwise, and on a squash-merging repo the PR title
  *becomes* the commit on `main` that release automation (e.g. `release-please`) parses to cut the
  next version — a bare title produces no release. **Issue titles are not conventional** — "CSV
  export: header row missing…" reads like a scope but `CSV export` is not a valid *type* — so supply
  the prefix yourself; never pass the issue title through verbatim.
- **Suffix** — end with `(#<issue>)`, the *issue* number. When the profile's *Integration style* is
  squash-merge, GitHub appends the *PR* number to the squash commit's title — so titling with the *issue*
  number makes the final `main` commit carry **both** (`… (#254) (#274)` — issue first, PR second). Drop
  it and the merged commit records only the PR number, losing the link to the issue. With `$ISSUE`
  empty there is no issue to link: no suffix.

Pick the **type** from the change, not a guess: the issue's type label maps cleanly (`bug` → `fix`,
`enhancement` → `feat`) — use it. When it doesn't map cleanly, build a candidate type from the
change's own shape (`docs:` for prose, `ci:`/`build:` for CI plumbing, `refactor:`/`test:` for a pure
refactor or tests-only change), then **dry-run the real gate against `$TITLE_PATHS`**:
`scripts/release-title-gate.sh "<candidate-type>(<scope>): <subject> (#$ISSUE)" $TITLE_PATHS`.
Never hand-classify a path as "genuinely non-shipped" against a memorized example list — the gate's
actual `NON_SHIPPED`/`SHIPPED_ANYWAY` rules are longer than any such list and carve specific paths
back into "shipped" by name, and a hand-copied approximation has already drifted from them twice
(#233, #245, #258). On exit 1 (refused), retry with `fix:` (or `feat:` when the issue's own label
says enhancement) instead of the rejected type — a shipped-path PR is restricted to
`feat`/`fix`/`perf`/`revert` regardless of how prose-like or mechanical the diff reads. Exit 0 means
the candidate is releasable; use it as-is. `$TITLE_PATHS` expands unquoted, so the shell splits it on
whitespace: a changed path holding a space reaches the gate as fragments it may misclassify — that
is the ceiling, so pass such a path to the gate quoted, by hand. **Exit 2 is not a verdict about the title — it is a broken
call**: `$TITLE_PATHS` yielded no usable path, so the gate had nothing to classify (#470). Do not
pick a type blind; the path list is the defect — for a scaffold, fix the plan's `**Files:**` line (a
task with no files says `none expected.`, the idiom `scripts/plan-freshness.sh` recognizes) and
re-run the dry-run with the paths it then yields. This check runs the moment the PR is opened, so a
bad guess here becomes a red `title-gate` check almost immediately, not a late-stage surprise. Add an
optional **scope** matching the ones already in `git log` for the touched area (the profile's area
names usually fit).
Then write a concise imperative **subject** that summarizes the fix rather than echoing the issue's
symptom wording — so the example issue becomes e.g.
`fix(export): use invariant culture in CSV number formatting (#849)`.

```bash
TITLE="<type>(<scope>): <subject> (#$ISSUE)"   # the title the dry-run accepted; no suffix when $ISSUE is empty
if [ "$DRAFT" = 1 ]; then DRAFT_FLAG=--draft; else DRAFT_FLAG=; fi
gh pr create $DRAFT_FLAG --base "$BASE" --head "$BRANCH" --title "$TITLE" --body-file "$BODY_FILE"

# Read it back: a zero exit is a claim about what gh attempted, not a receipt.
gh pr view "$BRANCH" --json number,url,isDraft,headRefName
```

The readback's `headRefName` must be `$BRANCH` and `isDraft` must match `$DRAFT`; anything else is a
stop, not a retry. Hand `number` and `url` back to the caller.

## Consumers

- `skills/implement-issue/SKILL.md` — Steps 4 and 5 name this recipe in the step index
- `skills/implement-issue/references/github-mechanics.md` — §5 frames the lookup and the draft PR in implement-issue's own terms
- `skills/implement-issue/references/steps/04-worktree.md` — Step 4 runs §1's issue-scoped guard before creating a worktree
- `skills/implement-issue/references/steps/05-open-the-draft-pr.md` — Step 5 opens the draft PR through this recipe
- `skills/create-pr/SKILL.md` — Steps 2 and 3 name this recipe in the step index
- `skills/create-pr/references/steps/02-locate-the-work.md` — Step 2 runs §1 before any push
- `skills/create-pr/references/steps/03-open.md` — Step 3 opens the PR for a finished feature branch through §2
