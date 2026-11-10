## Step 5 — Heartbeat

The wake signals that matter — worker reports and idle notifications — arrive on their own; **don't
poll for them.** Keep one self-paced wakeup armed as a *safety net* for a silently-hung worker. The
natural way to run auto-dev is under `loop` in dynamic mode: each re-fire is a reconcile tick. Use a
**long fallback** (~20–30 min) for the idle heartbeat. **Drop to a short cadence (2–4 min) only while
actively waiting on a specific CI run** to land a merge — that's external GitHub state the harness
can't notify you about; return to the long fallback once it lands. (Cache nuance in Token economics: a
wake past the ~5-min TTL pays a full cache write, so batch pending reconcile work into a long-idle
wake.)

**Every heartbeat wake touches the state file — even one where reconcile finds nothing else to
change** (rewriting the same content, or a plain `touch`, is enough). `hooks/autodev-stop-gate.sh`
reads that file's mtime to tell an actively-cycling supervisor from one that has walked away
(Token economics § *The two budgets*, `SUPERVISED WINDOW`); a quiet-but-alive run that only ever
touches the file "after any change" would let its own mtime drift past that window on a long idle
stretch, which reintroduces the exact false block this mechanism exists to remove.
