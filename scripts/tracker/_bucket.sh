#!/usr/bin/env bash
# _bucket.sh — the ONE `JQ_BUCKET` rule (#807), sourced by the three tracker backends and by
# base-run-verdict.sh's workflow-runs fallback; never executed on its own.
#
# gh's own `pr checks` bucket rule, applied to a check's lower-cased conclusion // status so every
# `commit-checks` list carries the same buckets `pr-checks` does. Anything unrecognised — UNKNOWN
# included — is pending: an unmapped state waits, it never reads as clear. Copying it per backend
# is how the fallback drifted to `bucket: null`.
JQ_BUCKET='def bucket: if . == "success" then "pass"
  elif . == "skipped" or . == "neutral" then "skipping"
  elif . == "cancelled" then "cancel"
  elif . == "failure" or . == "timed_out" or . == "action_required" or . == "startup_failure"
       or . == "error" then "fail"
  else "pending" end;'
