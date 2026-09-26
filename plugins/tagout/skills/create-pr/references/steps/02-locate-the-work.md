## Step 2 — Locate the work

Two acts here write, and only those two: one guarded commit, when a dirty tree remains, and
switching off the default branch. Everything else only reads. A refusal stops the run before either
write happens: no commit, no switch, no push, no PR. It says which rule refused, and Step 4 reports
it with Next `—`.

```bash
DEFAULT=<the profile's *Default branch*>
BRANCH=$(git symbolic-ref --quiet --short HEAD)   # fails on a detached HEAD: refuse, no branch to open from
ISSUE=<N from the request, digits only>
```

**Detached HEAD** → refuse: *"no branch to open from"*.

Every commit below goes through the guard, never a bare `git commit`:

```bash
GUARDS=<kit>/skills/implement-issue/scripts
```

If a call at `$GUARDS` is refused, see
[`../_shared/guard-invocation.md`](../../../_shared/guard-invocation.md).

### On `$DEFAULT` — take the work off it first

A fix `debug-issue` leaves on the default branch — committed there, or still sitting uncommitted —
hands off to this skill directly on `$DEFAULT`. This skill never opens a PR *from* the default
branch itself, so when `$BRANCH` is `$DEFAULT` it moves the work onto a feature branch before
anything else:

```bash
git fetch origin "$DEFAULT" --quiet
```

1. **Refuse on a leftover debug probe** — read the *lines* of `git diff "origin/$DEFAULT"` (never
   grep's exit status: "clean" is grep's exit 1, which trips `pipefail`; this diff already spans
   both committed and uncommitted changes) for any containing `[DEBUG-`, and **name them**. A
   tagged probe `debug-issue`'s own Phase 4 never got to sweep must never reach a PR — before it
   can be committed by the next step, not after.
2. **Commit a dirty tree now, before deriving anything from it.** When `debug-issue` leaves the fix
   *uncommitted*, `HEAD` is still whatever `$DEFAULT` had before the fix — deriving a branch name or
   a `## Root cause` from that commit would name the wrong one. Commit first, onto `$DEFAULT` itself
   (still `HEAD`), so the step below always reads the fix, never its predecessor:
   ```bash
   if [ -n "$(git status --porcelain)" ]; then
     "$GUARDS/guarded-commit.sh" -C "$(git rev-parse --show-toplevel)" <commit-identity> "$DEFAULT" \
       -- -am "fix: <a Conventional subject summarizing THIS diff — read git diff --stat and the
                changed hunks and describe what they do, never a fixed placeholder>"
   fi
   ```
3. **Derive `<type>/<slug>`** from the newest commit now on `$DEFAULT` (the fix itself, per step 2),
   and keep its message **body** too — when `$ISSUE` is empty, Step 3 quotes it under
   `## Root cause` in the PR body, because that body is where `debug-issue` Phase 4 step 4 already
   wrote the confirmed hypothesis:
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
   slugifies an issue title — one recipe, two callers. **Never fold a `#N` into `$NEW_BRANCH` unless
   `$ISSUE` came from the request above** — an auto-derived slug can start with digits of its own
   (`fix/500-error-on-missing-header`), and the branch-name lookup below only re-derives `$ISSUE`
   from `<type>/<N>-<slug>` names Step 4 itself builds this way, never from a slug's own accidental
   numerals.
4. **Switch**: `git switch -c "$NEW_BRANCH"` — never `-C`, a fresh branch only — at HEAD, carrying
   whatever `$DEFAULT` now has (step 2 already committed anything loose). `BRANCH=$NEW_BRANCH` from
   here on; nothing below, and nothing in Step 3, reads `$DEFAULT` again except to fetch it or, at
   the end, to rewind it. Set `FROM_DEFAULT=1` — Step 3 reads it, records the branch-off for the
   Step 4 recap, and is what tells it to run `rewind-default.sh` once the branch is on `origin`, and
   it is also what the issue-resolution fallback below reads to know its branch name was
   auto-derived rather than assigned by `create-issue`/`implement-issue`.

### Leftover uncommitted changes, on an already-existing feature branch

The case above already committed a dirty `$DEFAULT` before switching. When `$BRANCH` was never
`$DEFAULT` to begin with — the ordinary `create-pr` call on a feature branch someone built by hand —
a dirty tree no longer refuses the run either; it commits the same way:

```bash
if [ "${FROM_DEFAULT:-0}" != 1 ] && [ -n "$(git status --porcelain)" ]; then
  "$GUARDS/guarded-commit.sh" -C "$(git rev-parse --show-toplevel)" <commit-identity> "$BRANCH" \
    -- -am "fix: <a Conventional subject summarizing THIS diff, never a fixed placeholder>"
fi
```

What is not committed by this point would not reach the PR.

**Nothing is ahead** — `git rev-list --count "origin/$DEFAULT..HEAD"` prints `0` (fetch
`origin/$DEFAULT` first, unless the default-branch path above already did) → refuse: *"nothing
ahead of origin/$DEFAULT to open a PR for"*.

**Resolve the issue**, when the request above didn't already give one **and** this branch was not
just auto-derived (`${FROM_DEFAULT:-0}` is `1`, above, means `$NEW_BRANCH` never carries a `#N`
unless `$ISSUE` was already set — re-parsing it here would only risk reading a slug's own leading
digits as an issue number). Otherwise take it from a branch named by the profile's *Branch naming*
(`<type>/<N>-<slug>`):

```bash
if [ -z "$ISSUE" ] && [ "${FROM_DEFAULT:-0}" != 1 ]; then
  ISSUE=$(printf '%s\n' "$BRANCH" | sed -nE 's#^[a-z]+/([0-9]+)-.*#\1#p')
fi
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
