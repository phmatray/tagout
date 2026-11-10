#!/usr/bin/env bash
# worker-toplevel-guard.sh — did this worker get a worktree of its own? (#412)
#
# A background sub-agent inherits the supervisor's cwd unless `isolation: "worktree"` gave it one,
# and nothing the supervisor can query shows which happened. So the WORKER checks itself, as its
# first act, before it edits anything: its own toplevel must differ from the supervisor's. This was
# a marked bash block in auto-dev's Step 3 that each worker was told to run verbatim; it is a
# script now, so the comparison a worker runs is the one `tests/auto-dev-dispatch/test.sh` drives,
# byte for byte.
#
# Usage: worker-toplevel-guard.sh <SUPERVISOR_TOPLEVEL>
#   Run from the worker's own working directory. <SUPERVISOR_TOPLEVEL> is the value the dispatch
#   prompt carries (the supervisor's `git rev-parse --show-toplevel`, captured at Step 1).
#
# Exit codes, each with one line on stdout:
#   0  PROCEED — the worker's toplevel differs from the supervisor's
#   1  REFUSE  — they are the same tree, or this directory is not in a git work tree at all (there
#                was nothing for `isolation: "worktree"` to create). The worker stops before
#                touching any file and reports `STATUS: BLOCKED | DETAIL: worker-toplevel guard: …`.
#   2  no verdict — the supervisor's toplevel was not passed. Not a PROCEED: report it the same way.
#
# This check is ONE-SHOT: it answers "was this worker dispatched into isolation at all?" and nothing
# about the rest of the run. A worktree destroyed mid-run is covered by the shared git guard (#469).
set -u

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "worker-toplevel guard: no verdict — usage: worker-toplevel-guard.sh <SUPERVISOR_TOPLEVEL>"
  exit 2
fi
SUPERVISOR_TOPLEVEL="$1"

if ! WORKER_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || [ -z "$WORKER_TOPLEVEL" ]; then
  echo "REFUSE — this directory is not inside a git work tree; isolation: \"worktree\" had nothing to create here"
  exit 1
fi

# Compared as git printed both, and again with symlinks resolved: the same tree reached through a
# symlinked path (macOS /tmp, a linked home) must not read as two different ones.
real() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }
if [ "$WORKER_TOPLEVEL" = "$SUPERVISOR_TOPLEVEL" ] || [ "$(real "$WORKER_TOPLEVEL")" = "$(real "$SUPERVISOR_TOPLEVEL")" ]; then
  echo "REFUSE — the worker's toplevel equals the supervisor's; it inherited the shared tree instead of its own"
  exit 1
fi
echo "PROCEED — the worker's toplevel differs from the supervisor's"
exit 0
