# Shared Preconditions: Profile Load, Auth, & Commit Identity

This reference is used by every lifecycle skill to establish preconditions at Step 1. Each skill
links here and adds only its skill-specific extras.

## Load the repo profile

The repo profile is the single source of truth for repo-specific facts — commit identity, labels, CI
gates, conflict hot-spots, architecture grain. It lives, committed, at
**`.claude/skills/repo-profile.md`**; read it through the helper that already knows how to say it is
not there:

```bash
<kit>/skills/profile-repo/scripts/repo-profile.sh show
```

`<kit>` is the kit root — the directory holding `skills/` and `scripts/` — resolved when the skill
loads, the same placeholder [`worktree-ignore-check.md`](./worktree-ignore-check.md) and
`migrate-legacy` use. Do **not** write it as a shell variable: an unset `$KIT` expands to
`/skills/…`, i.e. exit `127`, which is a missing tool being read as a verdict.

The helper takes an optional directory and otherwise anchors itself to the repo root, so it resolves
from any subdirectory — and from a linked worktree, where the profile is present because it is
tracked.

### The outcomes

| Exit | Output | What it means | What to do |
|---:|---|---|---|
| `0` | the profile | it is committed and readable | Use it. Every repo-specific value below comes from it. |
| `3` | `NO_PROFILE` | this repository has **no committed profile** | Run **`profile-repo`** to generate one, then re-read. |
| `2` | `ERR: cannot cd …` | the directory argument is wrong | No verdict was reached — fix the invocation, don't read it as "no profile". |
| `126`/`127` | shell error | the helper is missing or not executable | Also **no verdict** — check that `<kit>` resolved. `profile-repo` documents a skills-only adoption path, so the script can legitimately be absent; open `.claude/skills/repo-profile.md` yourself in that case, and treat an unreadable one as `NO_PROFILE` below. |

Only `0` and `3` are **verdicts**. The rest mean the question was never answered — and "no verdict" is
not "no profile", which is the whole distinction this call exists to preserve.

**Why not just read the file.** A bare `cat` of a missing profile writes one line to *stderr*, nothing
to stdout, and returns a status nobody reads — so "this repo has no profile" and "this repo's profile
is silent" look identical, and the skill proceeds to infer the commit identity, the CI gates and the
label set from the repository instead. That inference is usually right, which is exactly what makes it
dangerous: it is invisible in the successful case (#157). `show` turns the same situation into a named
condition with a named remedy.

**`NO_PROFILE` is informative, not fatal.** A repository may legitimately not carry one — a first run,
or a team that has chosen not to commit it. Generating one is the remedy; if that is genuinely
impossible, **say so in the report, name the values you had to infer and where you got them**, and
carry on. Do not stop the run over it, and do not infer silently.

## Verify authentication

Check that your `gh` authentication works and you're targeting the correct repo:

```bash
gh api user --jq .login                                  # prints a login, or 401 → not authed
gh repo view --json nameWithOwner --jq .nameWithOwner    # confirm it's the repo the profile names
```

`gh repo view` follows a GitHub rename redirect, so it reports the canonical repository even through
a stale `origin`. The Search API every `gh … --search` call relies on does **not** follow that
redirect (#637): a repository renamed since this checkout's `origin` was set makes every search
silently answer `[]` while both checks above still pass. Compare `origin`'s own slug against the
canonical one and repoint it before any search runs:

```bash
repoData=$("<kit>/scripts/tracker.sh" repo)
slug=$(printf '%s' "$repoData" | jq -r '.slug')
originSlug=$(printf '%s' "$repoData" | jq -r '.originSlug // empty')
```

When `originSlug` is non-empty and differs from `slug` case-insensitively (compare with
`tr '[:upper:]' '[:lower:]'` on both sides), repoint `origin` — same scheme and host, only the
`OWNER/REPO` path replaced — and read it back to confirm the write landed:

```bash
url=$(git remote get-url origin)
prefix=$(printf '%s' "$url" | sed -E 's#(\.git)?/*$##' | sed -E 's#[^:/]+/[^:/]+$##')
newUrl="$prefix$slug"
case "$url" in *.git) newUrl="$newUrl.git" ;; esac
git remote set-url origin "$newUrl"
git remote get-url origin
```

Report it in the recap: `origin repointed <old> → <new> — searches were returning []`. A fork whose
`origin` is the fork itself (not the repository the profile names) reports the same slug for both,
so nothing changes; a case-only difference is likewise a no-op. This comparison only ever runs
against the call above **without** `--repo` — a `--repo`-scoped lookup names a different repository
on purpose and is never compared against `origin`.

If the auth check fails with a 401 error, stop and tell the user to run this in the prompt:

```bash
! gh auth login -h github.com
```

The `!` prefix runs the command in the current session, so the token lands in your environment. Then
re-check the `gh api user` command before continuing.

Whether **this** skill can run against **this** repository's tracker is a registered decision, not a
judgement to make here. Ask it — the report feeds the verdict:

```bash
<kit>/scripts/tracker.sh state <this skill> | <kit>/scripts/decide.sh tracker.capable
```

Proceed only on `capable`. On any other answer, stop with one sentence that quotes the verdict and
names the tracker — *`merge-pr` cannot run here: `tracker.capable` answered `unsupported`* — and
point at #503, which tracks the remaining backends. Do not infer a substitute, and do not re-derive
the answer from the Tracker line yourself: [`tracker-contract.md`](./tracker-contract.md) explains
what each verdict means and what clears it, and `scripts/tracker/capable.sh` is the only thing that
produces one.

**On a GitHub host other than github.com** (a Tracker line of `github (<host>)`, e.g. GitHub
Enterprise), the kit's own scripts reach the repository's host by themselves: each one resolves it
through `skills/_shared/scripts/_gh-host.sh` (#514) — from a `HOST/OWNER/REPO` slug, a `GH_HOST`
already set, or the checkout's `origin` host when origin is that same repository and `gh` holds a
stored credential for its host. A `gh api` command
written in skill prose does not: spell `--hostname <host>` on that call, and give a prose `gh … -R`
the `HOST/OWNER/REPO` form. Each Bash call is a fresh shell, so an `export GH_HOST=…` made in an
earlier call never reaches a later one.

## Commit identity shorthand

Throughout the skill's commands, **`git <commit-identity>`** is a shorthand that expands to the
author line from the profile's *Commit identity* section. It looks like:

```bash
git -c user.email=<email> -c user.name="<name>"
```

Substitute it in every commit/merge/rebase command. Example:

```bash
git <commit-identity> commit -m "message here"
```

In the issue/PR lifecycle skills those writes go through the guards rather than through bare `git`,
and there the flags travel **without** the leading `git` and **before** the branch name — that is
where the script forwards them to `git` itself:

```bash
"$GUARDS/guarded-commit.sh" -C "$WORKTREE" <commit-identity> "$BRANCH" -- -m "message here"
"$GUARDS/guarded-merge.sh"  -C "$WORKTREE" <commit-identity> "$BRANCH" -- origin/main
```

This ensures commits are authored with the canonical identity (usually GitHub, not work email).

---

**Each lifecycle skill's Step 1 links to this file and adds only its own required profile sections.**

## Consumers

- `skills/create-issue/SKILL.md` — Step 1 loads the repo profile and verifies authentication
- `skills/deliver-issue/SKILL.md` — Step 1 loads the repo profile and verifies authentication
- `skills/implement-issue/SKILL.md` — Step 1 loads the repo profile, verifies authentication, and prepares the commit-identity shorthand
- `skills/merge-pr/SKILL.md` — Step 1 loads the repo profile, verifies authentication, and prepares the commit-identity shorthand
- `skills/review-sessions/SKILL.md` — Step 1 loads the repo profile (the *ADRs* root and the *Identity* slug feed later steps)
- `skills/triage-backlog/SKILL.md` — Step 1 loads the repo profile, verifies authentication, and prepares the commit-identity shorthand
- `skills/_shared/recap.md` — cites this file as an example reference the skills link rather than `cat`
- `skills/implement-issue/references/steps/01-preconditions.md` — Step 1 of implement-issue, split out of its SKILL.md for progressive disclosure (#499)
- `skills/create-issue/references/steps/01-preconditions.md` — Step 1 of create-issue, split out of its SKILL.md for progressive disclosure (#499)
- `skills/merge-pr/references/steps/01-preconditions.md` — Step 1 of merge-pr, split out of its SKILL.md for progressive disclosure (#499)
- `skills/create-pr/SKILL.md` — Step 1 loads the repo profile, verifies authentication, and prepares the commit-identity shorthand
- `skills/create-pr/references/steps/01-preconditions.md` — Step 1 of create-pr, one step file at a time (#499)
- `skills/_shared/tracker-contract.md` — explains the `tracker.capable` verdict this file asks for at Step 1, and what clears each answer (#505)
