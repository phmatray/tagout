## Step 3 — Open the PR

**Push through the guard**, never a bare push. It asserts the branch, then reads the remote back
(exit codes: `skills/implement-issue/references/steps/05-open-the-draft-pr.md`):

```bash
GUARDS=<kit>/skills/implement-issue/scripts
WORKTREE=$(git rev-parse --show-toplevel)
"$GUARDS/guarded-push.sh" -C "$WORKTREE" "$BRANCH" -- -u origin "$BRANCH"
```

If the call to the guard is itself refused, see
[`../_shared/guard-invocation.md`](../../../_shared/guard-invocation.md).

**Ready or draft:**

- `--draft` in the request → `DRAFT=1`. The *Full test* does not run.
- Otherwise run the profile's *Full test* on this HEAD, from `$WORKTREE`, with its output going to
  `/tmp/create-pr-<short-sha>-full-test.out`. Green → `DRAFT=0`. Red → `DRAFT=1`: **keep that
  file**, because Step 4 quotes its failing tail. A red bar opens a draft, never a ready PR.

**The body** goes in `BODY_FILE=/tmp/create-pr-<short-sha>-body.md`:

- one bullet per commit in `git log --format='- %s' "origin/$DEFAULT..HEAD"`;
- `Closes #$ISSUE.` when `$ISSUE` is set, and no such line when it is empty;
- when `$ISSUE` is empty **and** `$ROOT_CAUSE` is non-empty (Step 2 branched this PR off
  `$DEFAULT`), a `## Root cause` section quoting `$ROOT_CAUSE` verbatim — the confirmed hypothesis
  `debug-issue` Phase 4 step 4 already wrote into that commit's own message body, carried forward
  rather than re-derived;
- on a red *Full test*, one line saying the draft is red and which command failed.

Then **follow §2 of [`../_shared/open-pr.md`](../../../_shared/open-pr.md)** — Step 2 already ran
its §1 — with these names:

```bash
BASE=$DEFAULT
TITLE_PATHS=$(git diff --name-only "origin/$DEFAULT...HEAD")
```

`$BRANCH`, `$ISSUE`, `$DRAFT` and `$BODY_FILE` are set above. When `$ISSUE` is set, the title's type
label comes from `/tmp/create-pr-issue-$ISSUE.json`. The recipe hands back `number` and `url` from its
readback; carry them to Step 4.

### When Step 2 branched this PR off the default

`${FROM_DEFAULT:-0}` being `1` is the record that this run took the work off `$DEFAULT` — carry it
to the Step 4 recap regardless of what follows. Once the readback above has proven `$BRANCH` is on
`origin`, rewind the local default to match:

```bash
if [ "${FROM_DEFAULT:-0}" = 1 ]; then
  "<kit>/skills/create-pr/scripts/rewind-default.sh" -C "$WORKTREE" "$DEFAULT" "$BRANCH"
fi
```

- `0` → `$DEFAULT` now equals `origin/$DEFAULT`; note the old and new sha (the guard's own
  `REWOUND` line) in the recap.
- `3` → the pushed branch does not (yet) carry every commit `$DEFAULT` had — should not happen,
  since Step 2 built `$BRANCH` from `$DEFAULT` and nothing rewound it in between, but if it does:
  **do not retry.** The recap says the default was left ahead of `origin/$DEFAULT` and why, so a
  human decides rather than a guard guessing twice.
- `2` / `4` → see the guard's own header (`skills/create-pr/scripts/rewind-default.sh`); recap the
  same way — report, don't retry.

If the call to `rewind-default.sh` is itself refused before it runs, see
[`../_shared/guard-invocation.md`](../../../_shared/guard-invocation.md).
