## Step 5c — Note a decomposed child's landing on its tracking parent

`create-issue`'s decompose branch (#315) files one **parent tracking issue** plus several
tracer-bullet **child** issues, wired together with native `blocked_by` edges via
`skills/create-issue/scripts/wire-edges.sh`. Once filed, nothing updated the parent as children
landed — `merge-pr` closed a child via the PR's `Closes #N` and stopped, leaving the parent's body
exactly as it read at filing time. This step is that update: it appends one line to the parent's
`## Decisions so far` section (the tracking-issue shape `skills/create-issue/references/tracking-issue.md`
defines) recording what the just-merged child settled — the "append rule" that reference names as a
`merge-pr` follow-on and defers until this lands.

**Same gate as Step 5b, for the same reason: this runs only on `guarded-pr-merge.sh` exit `0`.** Exits
`1`–`4` mean no merge landed, so there is no closed issue to check a parent for.

Find every issue this merge closed — a PR can close more than one (Step 5's own "Multi-issue PRs"
note above) — and hand each one to the script that does the actual read-then-conditional-edit:

```bash
gh pr view "$PR" --json closingIssuesReferences --jq '.closingIssuesReferences[].number' \
  | while read -r issue; do
      skills/merge-pr/scripts/parent-decision-note.sh "$issue" "$PR" "{owner}/{repo}"
    done
```

`parent-decision-note.sh` does everything from there: reads the issue's parent over REST
(`gh api repos/{owner}/{repo}/issues/{n}/parent` — the `parent` JSON field of `gh issue view` is absent on some
`gh` builds, #762), and:

- **No parent** → prints `no-parent` and exits 0. This is the overwhelming majority of merges — say
  nothing about it in Step 8's recap either, the same way Step 6's "none" follow-up tally stays
  quiet rather than narrating a non-event.
- **Parent present, already noted** → prints `already-noted` and exits 0 without writing anything.
  The script is idempotent **per PR number** (it checks the parent's body for this PR's own marker
  before appending), so a resumed run that reaches this step again for an already-merged PR — the
  routine case per this skill's own "Resume-safe" note — never duplicates the line. Call it
  unconditionally on every resume, exactly as Step 5b's own base-CI read is called unconditionally.
- **Parent present, not yet noted** → appends `- #<child> — <the PR's title, trimmed of its trailing
  "(#issue) (#PR)"> ([#<PR>](<url>))` to the section, creating `## Decisions so far` at the end of the
  parent's body if this is the first child to land, then reads the parent back to confirm the line
  landed.

⛔ **Never stop here, and never block the merge.** The merge already happened (same reasoning as Step
5b's own "never stop here" rule) — a real failure (a `parent-decision-note:`-prefixed non-zero exit:
a `gh` call failed, or the write couldn't be confirmed) is worth naming in Step 8, next to the
follow-up tally, but it never halts the rest of this checklist. An autonomous fleet that stopped a
successful merge's teardown over a tracking-issue bookkeeping failure would strand a slot on work
that already succeeded — the exact failure Step 5b's own gate exists to avoid, one step later.
