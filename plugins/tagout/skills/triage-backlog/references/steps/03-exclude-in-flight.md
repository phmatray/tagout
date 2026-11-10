## Step 3 — Exclude what's in flight

Before judging anything, remove from consideration every issue somebody is currently working:

```bash
# every issue number an open PR mentions in its title or body
gh pr list --state open --limit 100 --json number,title,body \
  --jq '.[] | "PR #\(.number) → \([ (.title + " " + (.body // "")) | scan("#[0-9]+") ] | unique | join(" "))"'

# issues someone is assigned to
gh issue list --state open --limit 200 --json number,assignees \
  --jq '.[] | select(.assignees | length > 0) | "#\(.number) → \(.assignees | map(.login) | join(", "))"'
```

Scanning for `#N` over-matches — a PR body citing prior art mentions issues it isn't building. That
is the right way round: an over-broad exclusion leaves an issue open one extra cycle, while a missed
one closes work out from under whoever is doing it.

If an `auto-dev` fleet is running, its state file holds the slot→issue map — read it and exclude
those too. This is not caution for its own sake: `auto-dev` workers hold an issue for the whole
lifetime of their PR, and an issue closed underneath one produces a merged PR that closes nothing
and a worker reporting success against a ghost.

Say how many you excluded and why. An owner seeing "6 of 30 are in flight" learns something real
about the queue.
