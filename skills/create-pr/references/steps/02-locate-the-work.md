## Step 2 — Locate the work

Two acts here write, and only those two: switching off the default branch, and — when a dirty tree
remains — one guarded commit. Everything else only reads. A refusal stops the run before either
write happens: no switch, no commit, no push, no PR. It says which rule refused, and Step 4 reports
it with Next `—`.

```bash
DEFAULT=<the profile's *Default branch*>
BRANCH=$(git symbolic-ref --quiet --short HEAD)   # fails on a detached HEAD: refuse, no branch to open from
ISSUE=<N from the request, digits only>
```

**Detached HEAD** → refuse: *"no branch to open from"*.

### On `$DEFAULT` — take the work off it first

A fix `debug-issue` leaves on the default branch — committed there, or still sitting uncommitted —
hands off to this skill directly on `$DEFAULT`. This skill never opens a PR *from* the default
branch itself, so when `$BRANCH` is `$DEFAULT` it moves the work onto a feature branch before
anything else:

```bash
git fetch origin "$DEFAULT" --quiet
```

1. **Refuse on a leftover debug probe** — read the *lines* of `git diff "origin/$DEFAULT"` (never
   grep's exit status: "clean" is grep's exit 1, which trips `pipefail`) for any containing
   `[DEBUG-`, and **name them**. A tagged probe `debug-issue`'s own Phase 4 never got to sweep must
   never reach a PR.
2. **Derive `<type>/<slug>`** from the newest commit already on `$DEFAULT`, and keep its message
   **body** too — when `$ISSUE` is empty, Step 3 quotes it under `## Root cause` in the PR body,
   because that body is where `debug-issue` Phase 4 step 4 already wrote the confirmed hypothesis:
   ```bash
   SUBJECT=$(git log -1 --format=%s)
   ROOT_CAUSE=$(git log -1 --format=%b)
   TYPE=$(printf '%s\n' "$SUBJECT" | sed -nE 's/^([a-z]+)(\([^)]*\))?:.*/\1/p'); TYPE=${TYPE:-fix}
   SLUG=$(printf '%s\n' "$SUBJECT" | sed -E 's/^[a-z]+(\([^)]*\))?:[[:space:]]*//' \
     | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40)
   NEW_BRANCH="$TYPE/$SLUG"; [ -z "$ISSUE" ] || NEW_BRANCH="$TYPE/$ISSUE-$SLUG"
   ```
   The Conventional prefix (`type(scope): subject` or a bare `type: subject`) gives `<type>`,
   falling back to `fix` when the subject carries none. The rest slugifies exactly the way
   [`../../../implement-issue/references/github-mechanics.md` §5](../../../implement-issue/references/github-mechanics.md)
   slugifies an issue title — one recipe, two callers.
3. **Switch**: `git switch -c "$NEW_BRANCH"` — never `-C`, a fresh branch only — at HEAD, carrying
   whatever `$DEFAULT` already had, committed or not. `BRANCH=$NEW_BRANCH` from here on; nothing
   below, and nothing in Step 3, reads `$DEFAULT` again except to fetch it or, at the end, to
   rewind it. Set `FROM_DEFAULT=1` — Step 3 reads it, records the branch-off for the Step 4 recap,
   and is what tells it to run `rewind-default.sh` once the branch is on `origin`.

### Leftover uncommitted changes, on any branch

Whether just switched off `$DEFAULT` or already on a feature branch, a dirty tree no longer refuses
the run — it commits, through the guard, never a bare `git commit`:

```bash
GUARDS=<kit>/skills/implement-issue/scripts
if [ -n "$(git status --porcelain)" ]; then
  "$GUARDS/guarded-commit.sh" -C "$(git rev-parse --show-toplevel)" <commit-identity> "$BRANCH" \
    -- -am "${TYPE:-fix}: commit the outstanding changes create-pr found before opening the PR"
fi
```

What is not committed by this point would not reach the PR.

**Nothing is ahead** — `git rev-list --count "origin/$DEFAULT..HEAD"` prints `0` (fetch
`origin/$DEFAULT` first, unless the default-branch path above already did) → refuse: *"nothing
ahead of origin/$DEFAULT to open a PR for"*.

**Resolve the issue**, when the request above didn't already give one. Take it from a branch named
by the profile's *Branch naming* (`<type>/<N>-<slug>`) — the same shape the switch above just built:

```bash
[ -n "$ISSUE" ] || ISSUE=$(printf '%s\n' "$BRANCH" | sed -nE 's#^[a-z]+/([0-9]+)-.*#\1#p')
[ -z "$ISSUE" ] || "<kit>/scripts/tracker.sh" issue-view "$ISSUE" > "/tmp/create-pr-issue-$ISSUE.json"
```

- `issue-view` exits 0 → keep `$ISSUE`. Step 3 reads the issue's labels from that file to pick the
  title type. Its `state` is `closed` → **refuse**: *"#N is closed"* — a squash-merged branch keeps
  commits `origin/$DEFAULT` never sees, so this is the check that stops it being opened twice.
- It fails for a `#N` the user gave → **stop**: the number names no issue here.
- It fails for a number read from the branch name → the name was only a guess. Clear `ISSUE`, say so
  in the recap, and go on.
- Neither gives a number → `ISSUE` stays empty and the PR links no issue.

**Last, look for an existing PR** — run §1 of [`../_shared/open-pr.md`](../../../_shared/open-pr.md)
with `$BRANCH` and `$ISSUE`. It only reads. It stops on a PR already open for this branch or this
issue → open nothing, push nothing; hand that PR to Step 4. This runs here, before Step 3's push and
*Full test*, so a PR opened elsewhere never gets this branch pushed alongside it.
