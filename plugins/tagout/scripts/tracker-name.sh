#!/usr/bin/env bash
# tracker-name.sh — print the tracker backend (`github`, `gitlab`, …) a script should drive (#805).
#
# usage: tracker-name.sh [-R <[host/]owner/repo>]
#
# The one home of the probe the merge-pr scripts used to copy. `-R` names the repository the caller
# targets, and tracker.sh honours it: a repository other than the checkout's own is not on the
# checkout profile's tracker. Without `-R` the answer is the checkout profile's. Prints nothing when
# tracker.sh cannot answer — callers refuse on an empty name.
set -euo pipefail
"$(dirname -- "$0")/tracker.sh" "$@" state merge-pr 2>/dev/null | jq -r '.tracker // empty'
