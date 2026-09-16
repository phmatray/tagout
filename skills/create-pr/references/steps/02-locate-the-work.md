## Step 2 — Locate the work

Every check here only reads. A refusal stops the run **before any write**: no push, no PR. It says
which rule refused, and Step 4 reports it with Next `—`.

```bash
DEFAULT=<the profile's *Default branch*>
BRANCH=$(git symbolic-ref --quiet --short HEAD)   # fails on a detached HEAD: refuse, no branch to open from
```

Refuse, in this order:

1. **`$BRANCH` is `$DEFAULT`** → *"nothing to open from the default branch"*. A PR needs a feature
   branch; this skill never creates one.
2. **The tree is dirty** — `git status --porcelain` prints anything → refuse and **name the files**
   it printed. What is not committed would not reach the PR, and this skill commits nothing.
3. **Nothing is ahead** — after `git fetch origin "$DEFAULT"`, `git rev-list --count "origin/$DEFAULT..HEAD"`
   prints `0` → *"nothing ahead of origin/$DEFAULT to open a PR for"*.

**Resolve the issue.** Take it from `#N` in the request. If there is none, take it from a branch named
by the profile's *Branch naming* (`<type>/<N>-<slug>`):

```bash
ISSUE=<N from the request, digits only>
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
