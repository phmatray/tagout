#!/usr/bin/env bash
# auto-dev Stop gate (Claude Code Stop hook). #417.
#
# `auto-dev`'s never-wait invariant — a background worker or supervisor must never end its turn to
# wait for something it dispatched itself — used to be enforced only by
# `tests/auto-dev-never-wait/test.sh`, which greps `commands/auto-dev-worker.md` for two forbidden
# phrasings. That proves the PROMPT contains a prohibition; it cannot observe a RUN. Eleven recorded
# stalls (and five more the day this hook was written) all died at execution time, in sessions that
# suite never sees, none of them matching either forbidden phrase. This hook is the mechanism behind
# the prohibition instead of a denylist of wordings: it refuses a `Stop` event only on POSITIVE
# evidence — the fleet's own pinned state file (skills/auto-dev/SKILL.md Step 2, #417 Task 2) — that
# an auto-dev fleet in THIS repository still has undrained work.
#
# It fails OPEN, always — the decision recorded in
# docs/adr/0002-the-roseline-gate-fails-open-always.md, which applies here verbatim (its argument is
# explicitly general: "a third hook takes the same terms; it does not get a second record"). This is
# the kit's FIRST hook that can block a USER action rather than a model one, and the plugin installs
# into every repository the user opens — so its positive evidence has to be narrow and repo-scoped:
# every path that is not "an auto-dev fleet has undrained work, here, now" exits 0 with no output.
# `AUTODEV_GATE=off` (also `0|false|no|disabled`) is the off-switch, in the same position
# `ROSELINE_GATE`/`GIT_GATE` occupy in the other two hooks — checked FIRST, same reason: a stale
# override in a shell rc must never fight the value a user just typed. There is no `=on` counterpart:
# unlike the other two gates, there is no probe here for a declaration to override — the state file
# itself is the only evidence, and there's nothing to force past.
#
# Per ADR 0011, this hook is RECORDED in decisions/registry.json's `not_decisions` map — it is a
# fixed, mechanical gate with no branch a human would call a "decision" — never registered as one.
#
# ------------------------------------------------------------------ the loop-breaker (stop_hook_active)
# A `Stop` hook that refuses a stop causes Claude Code to retry the turn; on that retry the payload
# carries `stop_hook_active: true`, and honouring it here is what stops a refusal from looping
# forever — verified live against the harness before this script was written (issue #417 Task 1: a
# throwaway probe hook confirmed both the field and the exit-2-refuses contract empirically).
case "${AUTODEV_GATE:-}" in off|0|false|no|disabled) exit 0 ;; esac

payload=$(cat) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v awk >/dev/null 2>&1 || exit 0
command -v find >/dev/null 2>&1 || exit 0

# One jq invocation for both fields — this runs on every Stop event in every repo the plugin is
# installed in (the common case has no fleet at all), so the universal hot path is worth not
# forking jq twice for it. The `||` guards jq's own exit status on the assignment itself — putting
# it on a `read <<EOF` heredoc line instead (an earlier draft did) makes it dead text fed to `read`
# as data, not a shell operator, so a failed jq call falls through with `cwd` corrupted rather than
# actually exiting.
tsv=$(jq -r '[(.stop_hook_active // false), (.cwd // "")] | @tsv' <<<"$payload" 2>/dev/null) || exit 0
read -r active cwd <<<"$tsv"
[ "$active" = "true" ] && exit 0
[ -n "$cwd" ] && [ -d "$cwd" ] || exit 0

# ---------------------------------------------------------------- which repository is this?
# The state file is keyed by host/owner/repo, not by worktree path, so every worktree of the same
# repository resolves to the SAME file (skills/auto-dev/SKILL.md Step 2). A repo with no `origin`
# remote, or no git at all at this cwd, gives the hook nothing to key the file on — fail open.
# skills/auto-dev/SKILL.md's Step 2 spells this SAME derivation for whatever writes the file, so
# the two sides of the key agree by construction rather than by two authors reading one template.
remote_url=$(git -C "$cwd" remote get-url origin 2>/dev/null) || exit 0
[ -n "$remote_url" ] || exit 0
# One sed, two edits: drop a trailing `.git` AND any trailing slash first (`https://host/owner/repo/`
# — a bare trailing slash otherwise survives to the capture below and the whole URL falls through as
# "unparsed" instead of resolving), then take the last two `/`- or `:`-separated segments — matches
# `https://host/owner/repo(.git)`, `git@host:owner/repo(.git)` and `ssh://git@host/owner/repo(.git)`.
owner_repo=$(printf '%s' "$remote_url" | sed -E -e 's#(\.git)?/*$##' -e 's#.*[:/]([^/:]+)/([^/:]+)$#\1/\2#')
# Both halves must be non-empty and free of the two characters the join below relies on being
# absent — `/` (the field separator this line just removed) and NUL. A malformed remote (no `:` or
# `/` before the capture, or a capture that swallowed the whole string) leaves `owner_repo` equal to
# the untouched `$remote_url`, which is exactly what `*/*` alone let through when the URL itself
# still contained a `/` (a bare `https://github.com/acme/widgets/` matched `*/*` on its own trailing
# slash before this fix). Splitting and checking each half is what a single `*/*` cannot do.
owner="${owner_repo%%/*}"
repo="${owner_repo#*/}"
case "$owner_repo" in */*) ;; *) exit 0 ;; esac
[ -n "$owner" ] && [ -n "$repo" ] || exit 0
case "$repo" in */*) exit 0 ;; esac

# The HOST is a third, leading segment (#471): owner/repo alone keys `github.com/acme/widgets` and
# `gitlab.example.com/acme/widgets` to ONE file, so a fleet in one could refuse a stop in the other
# — the same collision class #417's dash-join fix closed, one level up the URL. The authority part
# is what sits after an optional `scheme://` and an optional `user@`, up to the first `:` or `/`
# — the same three remote shapes as above. Lowercased, because DNS names are case-insensitive and
# a path segment is not. No host derivable → fail open, like an underivable owner/repo.
#
# When a credential contains an unescaped `@` inside the userinfo (e.g., a password with a literal
# `@` character), the userinfo parsing becomes ambiguous — per RFC 3986 such characters must be
# percent-encoded, but if they aren't, we have no unambiguous way to extract the host. Fail open
# (treat the host as underivable) rather than derive a garbled one.
authority=$(printf '%s' "$remote_url" | sed -E -e 's#^[A-Za-z][A-Za-z0-9+.-]*://##' -e 's#/.*$##')
case "$authority" in *@*@*) exit 0 ;; esac
host=$(printf '%s' "$remote_url" | sed -E -e 's#^[A-Za-z][A-Za-z0-9+.-]*://##' -e 's#^[^@/]*@##' -e 's#[:/].*$##' | tr '[:upper:]' '[:lower:]')
[ -n "$host" ] || exit 0
case "$host" in */*) exit 0 ;; esac

# Nested as TWO path segments, never flattened into one filename with a separator: `-` is legal
# inside both a GitHub owner and repo name, so `foo-bar/baz` and `foo/bar-baz` would both dash-join
# to `foo-bar-baz` and collide on one file — and any other ASCII separator has the same problem,
# since it is also legal in one or the other. `/` is the one character illegal in both (case
# "$repo" in */*) above already refuses a `repo` containing it; `owner` cannot contain it either,
# being the first `[^/:]+` capture group), so the filesystem is the separator instead of a string.
state_base="${AUTODEV_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}"
state_file="$state_base/tagout/auto-dev/$host/$owner/$repo.md"
[ -r "$state_file" ] || exit 0

# ---------------------------------------------------------- supervised window (#548)
# A background supervisor ends its turn between dispatching workers and being woken by their
# report — the documented, correct behaviour (skills/auto-dev/SKILL.md Step 4) — and that turn-end
# fires this same Stop event. Undrained work existing is no longer evidence nobody is watching it
# (#314 / ADR 0007 made workers addressable background sub-agents), so a state file touched this
# recently means the supervisor is actively cycling, not walked away: exit 0 before even reading
# the undrained-work sections below. SUPERVISED_MINUTES is owned by
# skills/auto-dev/references/token-economics.md's "SUPERVISED WINDOW" bullet — change it there, not
# here. Placed ahead of the 24h STALE_MINUTES check below (same `find -mmin` idiom, shorter bound).
SUPERVISED_MINUTES=30
[ -n "$(find "$state_file" -mmin -"$SUPERVISED_MINUTES" 2>/dev/null)" ] && exit 0

# ------------------------------------------------------------------- staleness bound (24h)
# A crashed supervisor leaves the file behind forever otherwise. 24 hours is generous against a
# genuinely long-running fleet (auto-dev is meant to run hands-off, often overnight) while still
# releasing a file nobody is going to come back and clean up. `find -mmin`, not `stat`: BSD and GNU
# `stat` take incompatible flags, and this kit's own convention (hooks/roseline-gate.sh's one-shot
# marker) already uses `find … -mmin` for the same reason.
STALE_MINUTES=1440
[ -n "$(find "$state_file" -mmin -"$STALE_MINUTES" 2>/dev/null)" ] || exit 0

# --------------------------------------------------------------- read the two sections
# Between a heading and the next `## ` line (exclusive). `## Queue` is a PREFIX match — the real
# heading carries extra prose ("## Queue — SMALL (then MEDIUM), eligible & area-tagged").
section() { # $1 file  $2 heading regex (anchored at line start)
  awk -v pat="$2" '
    $0 ~ pat { found=1; next }
    found && /^## / { exit }
    found { print }
  ' "$1"
}

in_flight=$(section "$state_file" '^## In flight')
queue=$(section "$state_file" '^## Queue')

# In flight is counted by LIVE SLOT LINE, not by bullet and not by `#NNN` token (#764). A slot is
# `- Slot <id> → #<n>` (skills/auto-dev/references/steps/02-build-the-work-queue.md's template);
# a slot whose phase reads merged/done is drained work, and a note or recap bullet ("- Last: #1
# after #2") is no evidence at all — the supervisor annotates this file, so counting any bullet
# refused a finished fleet. A live slot written in a drifted shape is missed: the gate fails open
# (ADR 0002). Lines, not tokens: a phase can carry two refs ("PR #<pr> ready→merging").
# Queue rows carry exactly one issue ref each with no PR-number companion, so token-counting is
# still correct there.
live=$(printf '%s\n' "$in_flight" | grep -E '^- Slot [^ ]+ → #[0-9]+' | grep -viwE 'merged|done' || true)
in_flight_count=0
[ -z "$live" ] || in_flight_count=$(printf '%s\n' "$live" | wc -l | tr -d ' ')
queue_count=$(printf '%s\n' "$queue" | grep -oE '#[0-9]+' | wc -l | tr -d ' ')

[ "$((in_flight_count + queue_count))" -gt 0 ] || exit 0

# --------------------------------------------------------------------------- refuse, naming the evidence
detail=$live
{
  echo "Blocked by the auto-dev stop gate: an auto-dev fleet has undrained work in ${owner_repo} —"
  echo "${in_flight_count} in-flight slot(s), ${queue_count} queued issue(s)."
  [ -n "$detail" ] && printf '%s\n' "$detail"
  echo "A slot that has landed belongs under ## Completed, not ## In flight — move it there first."
  echo "If you mean to stop anyway, set AUTODEV_GATE=off (an \`export\` inside a Bash call never"
  echo "reaches this hook — launch Claude with it set, or use it as a one-shot prefix on a command"
  echo "that stops the fleet's own supervision loop)."
} >&2
exit 2
