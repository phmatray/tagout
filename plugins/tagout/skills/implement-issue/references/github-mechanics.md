# GitHub mechanics for `implement-issue`

The fiddly, easy-to-get-wrong `gh`/`jq`/`git` snippets the main workflow leans on. Read this when
you hit any of: resolving the issue from a weird input, locating the plan (in the issue body or, on
older issues, a comment), ticking a single task's checkboxes without touching the others, or resuming
onto an existing branch/PR.

Throughout, `{owner}/{repo}` is a literal `gh` placeholder it resolves from the repo's `origin`
(the repo the profile names) — you can paste it as-is. And `<commit-identity>` is shorthand for the
author line from the profile's *Commit identity* (SKILL.md Step 1) — substitute its `-c user.email=… -c
user.name="…"` flags in the commit/merge commands below. In a `guarded-commit.sh` call it goes before
the branch name, not after `--`, since those are options to `git` rather than to `git commit`.

---

## 1. Resolve the issue number from whatever the user gave you

The user may pass a bare number, an issue URL, or a link to the plan comment. Normalize to a number.

```bash
ARG="$1"   # e.g. 21  |  https://github.com/<owner>/<repo>/issues/21
           #          |  https://github.com/<owner>/<repo>/issues/21#issuecomment-3098…
ISSUE=$(printf '%s' "$ARG" | grep -oE '[0-9]+' | head -1)   # first run of digits = issue number
```

If the link is a comment permalink (`#issuecomment-<id>`), you can also pull that comment id
directly and skip the search in §2:

```bash
COMMENT_ID=$(printf '%s' "$ARG" | sed -n 's/.*issuecomment-\([0-9]*\).*/\1/p')   # empty if not a comment link
```

Confirm the issue exists and is the right one before doing anything destructive:

```bash
gh issue view "$ISSUE" --json number,title,state --jq '"\(.number) [\(.state)] \(.title)"'
```

---

## 2. Locate the plan (issue body first, comment fallback)

`create-issue` writes the plan into the **issue body**, so look there first — and when the plan lives
in the body, you tick boxes by PATCHing the issue itself (§4), no comment id needed. Only fall back to
the comment trail for issues filed by older versions.

```bash
# Preferred: the plan is in the description. Fetch to a PRISTINE copy, check it, then work on a
# duplicate — §4 needs the untouched original both to validate the write and to restore from.
gh api "repos/{owner}/{repo}/issues/$ISSUE" --hostname <host> --jq .body > /tmp/plan-$ISSUE.orig.md
[ -s /tmp/plan-$ISSUE.orig.md ] || { echo "empty fetch for #$ISSUE — do NOT write anything back"; exit 1; }
cp /tmp/plan-$ISSUE.orig.md /tmp/plan-$ISSUE.md

if grep -q '🛠️ Implementation plan' /tmp/plan-$ISSUE.md; then
  PLAN_SRC=body
else
  PLAN_SRC=comment
fi
```

⚠️ **The `[ -s ]` check is load-bearing, not decoration.** A failed or rate-limited fetch leaves an
empty file, and every downstream step happily turns that into a valid empty body — which is exactly
how two live issue bodies were destroyed. Never edit-and-write a plan file you have not proved was
fetched.

When `PLAN_SRC=comment`, you need the comment's **numeric REST id** (the database id) — that's what
the PATCH endpoint in §4 edits. `gh issue view --json comments` returns GraphQL **node ids** (`IC_kw…`),
which the REST PATCH rejects. Always go through the REST comments endpoint:

```bash
if [ "$PLAN_SRC" = comment ]; then
  # All comments, newest-relevant plan comment wins. The marker is the bold header create-issue posted.
  # --slurp piped to a separate jq (gh's --jq can't combine with --slurp) flattens every page's
  # array into one list before `last` picks the actual latest match — `--paginate --jq` alone runs
  # the filter independently per page and concatenates the results, so `last` only sees whichever
  # page happens to print after the others.
  PLAN_COMMENT_ID=$(gh api "repos/{owner}/{repo}/issues/$ISSUE/comments" --hostname <host> --paginate --slurp \
    | jq -r '
      # >>> plan-locate marker-comment guard
      # `.body // ""` is a defensive guard, not a confirmed crash fix: GitHub's REST schema types
      # `issue-comment.body` as a plain non-nullable string (unlike the PR/issue `body` the sibling
      # `test()` guard in _shared/open-pr.md fixed for #259, which IS documented nullable) — so a `null` comment body
      # is not known-reachable through this endpoint. `contains()` still throws on `null` if one ever
      # arrives, exactly the way `test()` did before #259, so this coerces to `""` for the same
      # "no match" outcome as any other non-marker body, at effectively no cost (#278).
      # `last | .id` alone renders a genuine zero-match as the literal jq value `null`, and `jq -r`
      # prints that as the four-character string "null" — not empty output. The surrounding bash
      # gates on `[ -z "$PLAN_COMMENT_ID" ]`, which is false for a non-empty string, so without
      # `// empty` the fallback scan and the "no plan" stop below never fire on an ordinary
      # zero-match comment set (#286).
      [.[][] | select((.body // "") | contains("🛠️ Implementation plan"))] | last | .id // empty
      # <<< plan-locate marker-comment guard
      ')

  # Fallback if no marker (older/hand-written plan): latest comment that has checkbox lines.
  if [ -z "$PLAN_COMMENT_ID" ]; then
    PLAN_COMMENT_ID=$(gh api "repos/{owner}/{repo}/issues/$ISSUE/comments" --hostname <host> --paginate --slurp \
      | jq -r '
        # >>> plan-locate checkbox-fallback guard
        # Same defensive null-body guard as the marker-comment scan above, applied to the
        # checkbox-line fallback (#278).
        # Same `// empty` fix as the marker-comment guard above, for the same reason (#286).
        [.[][] | select((.body // "") | (contains("- [ ]") or contains("- [x]")))] | last | .id // empty
        # <<< plan-locate checkbox-fallback guard
        ')
  fi

  # Nothing in the body AND nothing in comments? Stop — there is no plan to execute (Autonomy contract).
  [ -z "$PLAN_COMMENT_ID" ] && { echo "No implementation plan on #$ISSUE"; exit 1; }

  # Pull the comment body to the same working files (pristine original + working copy).
  gh api "repos/{owner}/{repo}/issues/comments/$PLAN_COMMENT_ID" --hostname <host> --jq .body > /tmp/plan-$ISSUE.orig.md
  [ -s /tmp/plan-$ISSUE.orig.md ] || { echo "empty fetch for comment $PLAN_COMMENT_ID — write nothing back"; exit 1; }
  cp /tmp/plan-$ISSUE.orig.md /tmp/plan-$ISSUE.md
fi
```

`--paginate` matters: a busy issue can have >30 comments and the plan may not be on page one. And it
must be `--paginate --slurp` piped to a separate `jq`, not `--paginate --jq` — `gh api`'s `--jq` runs
its filter independently *per page* and concatenates the results rather than merging pages first, so a
`last | .id` filter picks the last match on whichever page happens to print last, not the true latest
match across the whole comment history; `--slurp` (which can't combine with `--jq`) flattens every
page into one array before `jq` sees it. Either way `/tmp/plan-$ISSUE.md` now holds the plan
text; a body-sourced file also carries the template fields and collapsed brainstorm/spec above it,
which is fine — §3/§4 only ever touch `### Task` checkbox lines.

### 2b. Is that plan still fresh? (#322)

The file you just fetched describes the tree as it was when the issue was **filed**. Ask whether it
still describes `main` before anything is built — the shipped script does it, so the answer is an
exit code rather than a judgement:

```bash
REPO=$(git rev-parse --show-toplevel)          # the checkout you were launched in — the MAIN one
SCRIPTS=<this skill's own scripts/ directory>  # what Step 4 later binds as $GUARDS

# Both are named here rather than reused because this runs BEFORE Step 4: there is no $WORKTREE and
# no $GUARDS yet, and the freshness question has to be answered before either exists.
# origin/main must be up to date first: a stale remote-tracking ref would report a path as MISSING
# because the local ref predates the commit that added it — a false stale, which is worse than none.
git -C "$REPO" fetch origin main --quiet

FRESH=0
"$SCRIPTS/plan-freshness.sh" -C "$REPO" --base origin/main \
  "/tmp/plan-$ISSUE.md" > "/tmp/plan-$ISSUE-freshness.txt" 2>&1 || FRESH=$?

case "$FRESH" in
  0) : ;;                                                   # every checked path resolves
  5) grep '^MISSING ' "/tmp/plan-$ISSUE-freshness.txt" ;;    # the paths to re-anchor, below
  *) echo "no verdict (exit $FRESH) — fix the invocation; do NOT read this as fresh"; exit 1 ;;
esac
```

Exit **2** is the no-verdict code, not a pass: an empty `/tmp/plan-$ISSUE.md` (the failed-fetch case
§2 guards), a file with no `### Task`, a directory that is not a repository, or a `--base` that does
not resolve. Reading it as `0` restores exactly the silence the script was added to remove.

**Re-anchoring a `MISSING` path.** Each `### Task N` block carries an `**Interfaces:**` line naming
the symbol the task is about; that symbol, not the path, is the durable identity. Search for it on the
base ref and let the count decide — this is the whole rule, and it is deliberately unforgiving:

```bash
# One task's symbol, taken verbatim from its **Interfaces:** line. -l because it is the FILE COUNT
# that decides, and `git grep -l` already emits each file exactly once however many times it hits —
# so no `sort -u`, and no `-n`, which `-l` would suppress anyway. -F: a symbol is a literal, and an
# interface name carrying `(`, `.` or `[` would otherwise be read as a regex against itself.
git -C "$REPO" grep -l -F -- '<symbol from the task Interfaces line>' origin/main \
  > "/tmp/plan-$ISSUE-anchor.txt"
wc -l < "/tmp/plan-$ISSUE-anchor.txt"
```

| files found | verdict |
|---:|---|
| `1` | the path moved. Record `STALE: <old> → <new> (Task N)` and use the new path. Step 10 recaps the list. |
| `0` or `2`+ | you cannot tell where the work belongs. That task has **no usable plan** — stop before the worktree and the scaffold, and report the path and what the search returned. |

Do **not** repair the plan on the issue. `tick-plan.sh` accepts a body that differs from the original
in checkbox characters and nothing else (§4), so rewriting a path there would be refused — correctly.
The `STALE:` list lives in the run and reaches the reader through Step 10 and the PR body.

---

## 3. Decide which tasks are already done (resume + progress)

A task is **done** when every checkbox in its block is ticked. Quick whole-comment progress:

```bash
done=$(grep -c '^- \[x\]' /tmp/plan-$ISSUE.md)
todo=$(grep -c '^- \[ \]' /tmp/plan-$ISSUE.md)
echo "$done done / $((done+todo)) steps"
[ "$todo" -eq 0 ] && echo "All tasks already complete."
```

To find the first unchecked task, scan `### Task` headings and look for the first block that still
contains a `- [ ]` line. Implement from there; skip blocks that are all `- [x]`.

---

## 4. Tick one task's checkboxes — precisely

**Never** `sed -i 's/\[ \]/[x]/g'` the whole file — that ticks unfinished tasks too and turns the
issue's progress board into a lie. Flip only the lines belonging to the task you just committed.

Preferred: edit `/tmp/plan-$ISSUE.md` line by line with the **Edit tool**, changing each of
that task's `- [ ] **Step k:** …` lines to `- [x] **Step k:** …`. The step text is unique, so each
Edit targets exactly one line and fails loudly if something drifted — which is the safety you want.

Then write the whole body back — the **issue** when the plan lives in its description, or the
**comment** on a legacy issue — **through `tick-plan.sh`**:

```bash
if [ "$PLAN_SRC" = body ]; then
  ./skills/implement-issue/scripts/tick-plan.sh \
    --repo {owner}/{repo} --issue "$ISSUE" \
    --before /tmp/plan-$ISSUE.orig.md --after /tmp/plan-$ISSUE.md
else
  ./skills/implement-issue/scripts/tick-plan.sh \
    --repo {owner}/{repo} --issue "$ISSUE" --comment-id "$PLAN_COMMENT_ID" \
    --before /tmp/plan-$ISSUE.orig.md --after /tmp/plan-$ISSUE.md
fi
```

It wraps the file with `jq -Rs` (a JSON string, so backticks, quotes and newlines survive intact),
writes that payload to a temp file, and PATCHes with **`--input <file>`** — far more robust than
`-f body=...` for large, Markdown-heavy bodies, and deliberately **not** `--input -`: the stdin pipe
is what made a PATCH of a ~30KB body take 25–35 minutes to return from a write GitHub had already
applied in seconds (#113). Don't "simplify" it back into a pipe. The body-sourced file holds the
*whole* description, so flipping only this task's checkbox lines leaves the template fields and
brainstorm/spec untouched. After the write, the issue re-renders with this task's boxes ticked — and
because the plan is in the body, the progress meter advances too. The script then re-reads the issue
and asserts the stored body matches what it sent.

**Every `gh` call** in the script runs under a deadline — `TICK_PLAN_PATCH_TIMEOUT` seconds, default
**60**, overridable mainly so the golden suite need not wait a minute per case. **Expiry is not
failure.** Killing the call does not un-send it, so the script falls through to the read-back and
*that* decides: a bounded call whose stored body matches is a success (the output says it was
bounded), one whose body differs is an `ALERT`, and one that cannot be read back at all is an
`ALERT` too, because then nothing confirms anything. The read-back — not the PATCH's exit status —
is the authority.

Both legs, not just the write (#135). Bounding one call does not remove #113's failure mode, it
relocates it: expiry on the PATCH is a *deliberate* handover to the read-back, so the bounded path
guarantees the read-back runs next — and an unbounded authority is precisely where the stall then
lands. A read-back that was cut short is therefore treated as a read-back that **failed**: either
way the authority did not answer, so it routes to the outcome the contract already defines for "no
answer" rather than to a fourth verdict.

Two properties of that deadline are easy to assume and were both wrong before #135:

- **It bounds the whole job, not the pid.** The call is launched under `set -m` so it gets a process
  group of its own, and the TERM/grace/KILL escalation signals the group. Killing only the pid bash
  returns leaves any descendant alive holding the stdout/stderr it inherited, so a caller reading
  the script *through a pipe* — which is how an agent harness runs it — blocks for the full duration
  of the call the deadline just reported bounding.
- **It cannot bound what is not a `gh` call.** The stall that actually produced "hangs after a
  successful PATCH, needs `kill -9`" was `[ -z "${got//[[:space:]]/}" ]` on the fetched body: bash
  3.2's pattern substitution is O(n²) in the subject, measured at 5s for 4KB, 33s for 8KB and 247s
  for a live 15.8KB issue body — pure CPU, after the write had landed, with no deadline over it.
  It is a `case` glob now. Keep body-sized work out of bash string operators.

### ⛔ Never pipe `jq` straight into a mutating `gh api`

The recipe this replaced —

```bash
jq -Rs '{body: .}' /tmp/plan-$ISSUE.md | gh api ".../issues/$ISSUE" -X PATCH --input -   # DESTROYED TWO ISSUES
```

— wiped the full body of two live issues in a single unattended run, silently, exiting `0`. The
mechanism is worth knowing because the obvious fix does not work:

| plan file | `jq` exit | what `jq` prints | pipeline exit |
|---|---|---|---|
| missing | 2 | `{"body": ""}` — **well-formed, not empty output** | **0** |
| empty | **0** | `{"body": ""}` | **0** |

`jq -Rs` slurps *nothing* into the empty string and faithfully builds a valid payload, so `gh` is
never handed anything malformed to reject. And because `jq` exits **0** on the empty-file path,
**`set -o pipefail` does not catch it** — the reflex fix closes only the top row of that table.

There is no guard on the *transport* that helps; the **body** has to be checked. `tick-plan.sh`
does it exactly rather than heuristically: ticking is a one-character substitution, so with every
box normalised back to `[ ]` the new body must be **byte-identical** to the old one. Missing, empty,
truncated, rewritten, un-ticked or no-op bodies all fail that test, and none of them reach GitHub.
Covered by `tests/tick-plan/test.sh` in CI.

**The PR description's mirror list** gets the same treatment — flip *this task's* `- [ ] Task N: …`
line in the PR's `### Plan` list, then write it back:

```bash
gh pr view $PR_NUMBER --json body --jq .body > /tmp/pr-$ISSUE.md
[ -s /tmp/pr-$ISSUE.md ] || { echo "empty PR body fetch — do NOT write it back"; exit 1; }
# Edit-tool per line: flip only this task's "- [ ] Task N:" line to "- [x] Task N:".
[ -s /tmp/pr-$ISSUE.md ] && gh pr edit $PR_NUMBER --body-file /tmp/pr-$ISSUE.md
```

⚠️ **`gh pr edit --body-file` on an empty file blanks the PR description** — the same defect as §4's
issue PATCH, one endpoint over. It is less costly (the PR list is a mirror; the issue is canonical)
but it is the same mistake, so it gets the same `[ -s ]` guard on both the read and the write.

Re-fetch isn't needed within a single run — you own the source and hold the canonical copy in the
temp file. (If you ever suspect a concurrent edit, re-fetch, re-apply your flips, re-PATCH.)

---

## 5. Worktree, branch, draft PR — and reusing them on resume

Branch naming ties the worktree, branch, and PR to the issue:

```bash
SLUG=$(gh issue view "$ISSUE" --json title --jq .title \
  | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40)
BRANCH="feat/$ISSUE-$SLUG"
```

Before creating anything, check whether a prior run already set things up (resume). Match on
**`$BRANCH`** — this issue's own name. "Am I already in a worktree?" is the wrong question and the
one that produced the incident in Step 4: being in *someone else's* worktree passes it.

```bash
# --porcelain + grep -Fxq matches the branch column EXACTLY. A bare `grep -F "$BRANCH"` matches
# substrings and the path column as well, so `feat/26-guard` would "resume" into
# feat/26-guarded-git-writes' worktree — the wrong-checkout failure this is meant to prevent.
git worktree list --porcelain | grep -Fxq "branch refs/heads/$BRANCH"   # THIS issue's worktree?
gh pr list --head "$BRANCH" --json number,url,isDraft --jq '.[0]'       # PR already open?

WORKTREE=<absolute path of that worktree>
GUARDS=<this skill's own scripts/ directory>       # skills/implement-issue/scripts from the kit root
```

If they exist, work in that worktree (with `git -C`) and reuse the PR — don't open a second one.
If a guard call at `$GUARDS` is refused from inside that worktree, see the fallback in
[`../../_shared/guard-invocation.md`](../../_shared/guard-invocation.md).

**If the branch-name match found nothing, don't assume there's no PR — a branch name is only a guess
at what a prior run called itself.** Ask GitHub about the *issue* directly before creating anything
(#214 — two sessions scaffolded #195 under two different branch names because the second one never
ran the `SLUG` recipe above, it invented its own). `$ISSUE` is already a validated digit string here
(Step 1's locator gates on `gh issue view "$ISSUE"` succeeding): run the issue-scoped guard in
[`../../_shared/open-pr.md` §1](../../_shared/open-pr.md#1-look-for-an-existing-pr) and read its
0/1/2+ table there — the recipe and `tests/pr-existence-guard/test.sh`'s one marked copy live in
that file, never here.

When it stops on an existing PR (`1`, or the one its `2`+ tie-break picks), resume onto that PR's
`headRefName` the same way as a branch-name match: fetch it, `git worktree add` from it (existing
local branch) or from `origin/<branch>` with `-b` (remote-only), set `BRANCH` to it, and skip straight
to Step 6 — no second scaffold, no second `gh pr create`. If resuming onto an existing *local* branch,
also `git branch --set-upstream-to="origin/$BRANCH" "$BRANCH" 2>/dev/null || true` before Step 6's
push — a branch left over from a session that created it but crashed before its first push has no
upstream configured, and that push has no `-u` of its own to fall back on. On `2`+, name the others
in the final report.

Otherwise create the worktree via `scripts/make-worktree.sh` (`implement-issue/SKILL.md` Step 4 —
never a hand-rolled worktree/ignore check, #280), then the draft PR (empty scaffold commit so the
branch is ahead of `main`):

```bash
"$GUARDS/guarded-commit.sh" -C "$WORKTREE" <commit-identity> "$BRANCH" \
  -- --allow-empty -m "chore(#$ISSUE): scaffold draft PR"
"$GUARDS/guarded-push.sh" -C "$WORKTREE" "$BRANCH" -- -u origin "$BRANCH"
```

Then open it through [`../../_shared/open-pr.md`](../../_shared/open-pr.md) with `DRAFT=1`, `BASE=main`,
`TITLE_PATHS` = the plan's `**Files:**` paths and `BODY_FILE` holding Step 5's `### Plan` mirror body.

The guards take `$BRANCH` explicitly and refuse (exit 2) if HEAD is anything else; `guarded-push.sh`
additionally reads the remote back and exits 4 if it does not carry this HEAD. **Always pass
`-C "$WORKTREE"`** — without it they default to the current directory, which is the ambient checkout
this whole section tells you not to trust. And pass `--remote <name>` whenever the push targets
something other than `origin`, or the guard verifies a ref the push never wrote.

---

## 6. Mark ready (only after green)

```bash
gh pr ready "$PR_NUMBER"          # number from `gh pr create`, or `gh pr list --head "$BRANCH"`
```

`gh pr ready` with no extra flag flips draft → ready-for-review. There's no separate "approve" — the
human reviewer takes it from there.

---

## 7. Sync with `main` and resolve conflicts (before the ready-flip)

Issues run in parallel and `main` advances while the PR sits in draft, so it drifts out of
mergeability. Before the ready-flip, merge the latest `main` into the branch, resolve conflicts, and
re-verify on the merged tree.

The procedure itself — merge-not-rebase, the union/regenerate/take-the-higher rule-of-thumb keyed off
the profile's *Conflict hot-spots* table, sourcing the other side's intent for a genuinely semantic
conflict, and the finish-and-verify step — is shared with `merge-pr` and lives in
[`../../_shared/sync-with-main.md`](../../_shared/sync-with-main.md). Follow it, then continue to
Step 9 (full build/tests + format gate) — never push a merge you haven't at least built.

Its three writes are guarded like every other write in this skill, so pass `$BRANCH`, `$WORKTREE` and
`$GUARDS` (Step 4) through to it. The code to know is **exit 5 from `guarded-merge.sh`: conflicts —
the normal outcome of a real sync, not an error.** Resolve them and *complete* the merge with
`guarded-commit.sh … -- -F "$MERGE_MSG"` (the `mktemp`'d `Conflicts:` message file
`_shared/sync-with-main.md` prescribes); re-running the merge on a 5 is the one wrong move.

---

## Gotchas, collected

- **Body first, comment fallback.** `create-issue` writes the plan into the issue **body** now, so
  `PLAN_SRC=body` is the normal path and you PATCH the issue (`.../issues/$ISSUE`). The comment path
  is only for issues filed by older versions. Ticking a body plan also advances the progress meter,
  which a comment plan never did.
- **Node id vs REST id (comment path only).** `gh issue view --json comments` → GraphQL `IC_kw…` ids;
  the PATCH endpoint needs the **numeric** id from `gh api .../comments`. Mixing them up is the #1 way
  the comment tick fails. Irrelevant when the plan is in the body.
- **Pagination (comment path only).** Always `--paginate` the comments call; the plan comment may be
  past comment 30.
- **The emoji marker is the anchor.** `create-issue` writes `## 🛠️ Implementation plan` (older issues:
  a `**🛠️ Implementation plan**` comment). Match on the `🛠️ Implementation plan` substring; keep the
  §2 checkbox fallback for hand-written plans.
- **`jq -Rs` for the body — inside `tick-plan.sh`, never in a bare pipe.** Hand-building the JSON
  (or `-f body=`) mangles plans full of backticks, code fences, and `<` `>`; `jq -Rs '{body:.}'` is
  lossless. But it is lossless about *whatever it was given*, including nothing — piping it straight
  into a mutating `gh api` is what destroyed two issue bodies (§4).
- **Keep the pristine fetch.** `/tmp/plan-$ISSUE.orig.md` is never edited. Without an untouched copy
  there is nothing to validate the new body against and nothing to restore from.
- **Whole-file sed is forbidden.** Tick per task, not per repo — see §4.
- **Reconcile the mirror on resume.** The issue PATCH and the PR-body edit aren't atomic; a crash
  between them leaves the PR's `### Plan` line unticked forever unless the next run re-syncs it
  from the issue state (the canonical source) before entering the loop.
- **Empty commit is intentional.** It exists only so a draft PR can open before any code lands; the
  first real task commit immediately makes it meaningful. Don't squash it away mid-run.
- **A branch-name match is a guess, not a guarantee.** §5's fallback exists because a worker's own
  judgment can pick a different branch name for the same issue on a different run (#214) — never skip
  the issue-scoped `gh pr list --search "$ISSUE in:body"` check just because the branch-name check
  came back empty. Scope the search's *filter* to a real closing keyword (`Closes`/`Fixes`/`Resolves
  #$ISSUE`), not a bare mention — GitHub's text search alone returns PRs that merely reference the
  number.
- **Sync before ready — merge, not rebase.** The full procedure (and the why) is in
  [`../../_shared/sync-with-main.md`](../../_shared/sync-with-main.md), summarized at §7; the one thing
  to remember here is that a clean text merge can still be a broken compile, so re-build after resolving.
- **Use `git -C <path>` rather than `cd <path> && …`** — a `cd` in a compound command gets reset
  between calls here.

---

## Troubleshooting (error → cause → solution)

| Error | Cause | Solution |
|---|---|---|
| `404 Not Found` on the comment PATCH | A GraphQL node id (`IC_kw…`) was used where the endpoint needs the **numeric REST id** | Re-fetch the id via the REST comments endpoint (§2), re-PATCH |
| `Failed to connect to github.com port 443` on `git push`/`fetch` while `gh` works | Sandbox blocks raw git network traffic (not an outage — `gh` proves the host is reachable) | Re-run just that command with the sandbox disabled; local git (merge, commit, worktree) needs no network |
| "No implementation plan on #N" | The issue carries no plan in its body or comments | Stop (Autonomy contract) — nothing to execute; seed a plan via `create-issue` if the user insists |
| PATCH succeeded but the progress meter didn't move | The plan lives in a comment (meter counts body checkboxes only), or the wrong task's lines were flipped | Verify which source was PATCHed (§2's `PLAN_SRC`); re-flip with the Edit tool per line (§4) |
| `tick-plan: REFUSED — body length changed` / `differs outside the checkboxes` | Something rewrote the working file beyond flipping boxes (a stray Edit, a re-fetch mid-task, an agent "tidying" the body) | **Nothing was sent — the issue is intact.** Re-copy `/tmp/plan-$ISSUE.orig.md` over the working file, re-apply only this task's flips, re-run |
| `tick-plan: REFUSED — --after file is empty` / `does not exist` | The fetch failed, or the working file was clobbered. This is the wipe (Koine#1813) being caught | **Nothing was sent.** Re-fetch via §2 and restart the tick; never hand-PATCH around the script |
| `tick-plan: REFUSED — no checkbox was ticked` | The per-line Edit didn't land (step text drifted from what the plan actually says) | Re-read the working file, match the real step text, re-flip. A no-op write would look like progress |
| `tick-plan: the PATCH to … exceeded Ns and was bounded` | **Not an error, and not a failure** (#113). The PATCH outran `TICK_PLAN_PATCH_TIMEOUT` (default 60s) and was killed, which does not un-send it | **Nothing to do — read the next line.** The read-back decides; if it printed `body verified intact … [PATCH bounded …]` the tick landed and the run continues |
| `tick-plan: ALERT — … does not hold what was sent, and the PATCH was cut short` | The call was bounded *and* GitHub still holds the old body — most likely the write never left | **Re-run the tick** (`--before`/`--after` unchanged; it is idempotent). Do **not** restore from `/tmp/plan-$ISSUE.orig.md` — the write may still arrive and the restore would un-tick it |
| `tick-plan: ALERT — the PATCH was bounded at Ns and the read-back failed or was bounded` | The write was cut short **and** the authority did not answer — it errored, or it outran the same deadline. Nothing establishes what the issue now holds | Re-run the tick once connectivity is back; it reports the true state. Never assume either outcome — that is the whole reason this path refuses rather than warns |
| `tick-plan: WARNING — PATCH reported success but the read-back failed or was bounded` | The write went through on its own, but the verification call did not answer. The body almost certainly landed; nothing *proved* it | **Not a failure** — rc is 0 and the run continues. The summary says `body NOT verified`, so don't quote it as verified. Re-run the tick (idempotent) if you need the proof |
| `tick-plan` returns, but the *caller* hangs for minutes after it | Pre-#135 shape: the escalation killed only the launched pid, so a descendant kept the inherited stdout/stderr open and a piped caller waited out the whole call | Fixed by launching under `set -m` and signalling the process group. If you see it again, check that `run_bounded` still has exactly one escalation and that it targets `-"$pid"`, not `"$pid"` |
| The tick burns minutes of **CPU** after the PATCH has landed | Pre-#135 shape: `[ -z "${got//[[:space:]]/}" ]` on the whole body — bash 3.2 pattern substitution is O(n²) (247s on a 15.8KB body). No deadline covers it; it is not a `gh` call | Fixed by the `case` glob. The tell is `time` reporting ~100% CPU with almost no system time — a network stall shows the opposite |
| `tick-plan: REFUSED — TICK_PLAN_PATCH_TIMEOUT must be …` | The deadline override is not a whole number of seconds ≥ 1 | **Nothing was sent.** Unset it for the 60s default, or pass whole seconds |
| A commit landed on **another branch** (and a push carried it into someone else's PR) | A concurrent checkout switched HEAD in a shared working tree between the branch creation and the commit. `git commit` never re-checks the branch, so it exits 0 | Cherry-pick the commit onto the branch it belongs to, then `git revert` it on the branch it wrongly landed on. **Never force-push a branch you do not own** — its author may already have built on it. Then move to this issue's own worktree (Step 4) and route every write through the guards |
| `guarded-commit: REFUSED — HEAD is on 'X' but this task owns 'Y'` (exit 2) | Prevention working: something checked out `X` in this worktree | **Nothing was committed.** Check out `Y` — better, move to `Y`'s own worktree — and re-run. Do not "just commit anyway" |
| `guarded-commit: ALERT — the commit was made, but HEAD is now …` (exit 3) | HEAD moved *during* the commit; the work is on the branch the message names | Recover exactly as in the first row. The commit is not lost, only misfiled |
| `guarded-merge: CONFLICTS on <branch>` (exit 5) | **Not an error** — the expected outcome of a real sync. HEAD is still your branch and the conflicts are in the working tree | Resolve per the rule-of-thumb (sourcing the other side's intent for a semantic one), then **complete** the merge: `guarded-commit.sh … -- -F "$MERGE_MSG"`. Never re-run the merge on a 5 — to walk away instead, `guarded-merge.sh … -- --abort` |
| `guarded-merge: ALERT — HEAD is now …` (exit 3) | HEAD moved *during* the call. **Read the message before acting**: it says whether git wrote anything — if git failed, the other branch took nothing and must not be touched | **Stop and surface it**; recovery is a human call, not a step to automate. Never resolve conflicts or reset from here — the branch that moved is somebody else's, and `merge --abort`/reset are theirs to run. Get back onto your own branch, in a worktree of its own, before anything else |
| `guarded-push: ALERT — … HEAD moved while it ran` (exit 4) | HEAD changed between the pre-flight assert and the push. `git push` sends the **current** branch, so what reached the remote may be another task's work. Caught before the remote is read at all — this 4 is about your local checkout and says nothing about what the remote now holds | Recover as in the *"A commit landed on another branch"* row above (the same one the exit-3 row points at): find where the commit went before pushing again, and **never force-push a branch you do not own**. If the message adds that the repo can no longer be read as a git repository, HEAD may never have moved at all — a worktree removed or renamed under the command reads exactly the same way |
| `guarded-push: ALERT — … could not be listed` / `push is UNVERIFIED` (exit **6**, #172 — was 4) | **Verification never ran.** `git ls-remote` failed — a `--remote` naming a remote the push did not write to, a network drop, an expired credential — so nothing about the remote was read. Neither this nor exit 4 disproves the push (#93); this is the one that also doesn't confirm it | **Do not conclude anything from this code alone** — the check failed, not necessarily the push, and the ALERT says so in as many words: *don't assume it landed, don't assume it didn't*. Fix the check (pass `--remote <name>` for the remote you actually pushed to, restore connectivity/auth), then **re-run with `--verify-only`** (`guarded-push.sh -C <path> [--remote <name>] --verify-only <branch>`) — it repeats the branch assertion and the remote read-back without pushing again, which is the precise way to find out (#172). A full re-push is also safe (a re-push of work the remote already holds is a no-op), but `--verify-only` is the more precise of the two. The ALERT quotes git's own stderr — read it, it says which |
| `guarded-push: ALERT — … is NOT this HEAD` / `… has no '<branch>' to show for it` (exit 4) | The remote **was** listed and contradicts the push: `git push` exited 0 without delivering this HEAD (a `remote.<name>.push` refspec, a `--dry-run`, a rejected-then-retried push), or the branch is not on the remote at all. Since #172, exit 4 makes only this one claim — a positive contradiction, together with the HEAD-moved row above, never "verification could not run" (that split out to exit 6, above) | Treat the work as **unpushed**. Find what the remote branch actually holds before pushing again; the exit code claimed a delivery the remote does not confirm |
| `guarded-commit:` / `guarded-push: REFUSED — cannot load its branch assertion` (exit 2) | Both guards source `_assert-branch.sh` from beside themselves, so the invariant has one home (#44). It is absent, unreadable, or **present but truncated** — a partial install, an interrupted write, or a guard copied out of the kit on its own. The guard tests that the assertion is *callable*, not merely that the file exists, so an empty helper refuses here instead of dying later with `command not found` (127) | **Nothing was written / sent.** The guards are not standalone files. Reinstall the plugin, or restore `_assert-branch.sh` in `skills/implement-issue/scripts/`. Do not work around it by calling `git commit`/`git push` directly — those are the unguarded calls the guards replaced |
| `tick-plan: ALERT — … now has an EMPTY body` | A body was written empty despite the guards (should be unreachable) | Restore immediately from `/tmp/plan-$ISSUE.orig.md`, then file a bug — the guard has a hole |
