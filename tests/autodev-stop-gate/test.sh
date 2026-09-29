#!/usr/bin/env bash
# Golden test for the auto-dev Stop gate — #417's answer to "auto-dev's never-wait invariant is a
# grep over prompt wording": a `Stop` hook that refuses the stop only on POSITIVE evidence that an
# auto-dev fleet in THIS repository has undrained work (the pinned state file, #417 Task 2), never
# on the wording of anything a model said.
#
# Written fail-path-first, the tests/git-gate/test.sh and tests/roseline/test.sh shape: a gate whose
# PASS (fail-open) path is the only one exercised proves nothing, and ADR 0002 (inherited here
# verbatim — every hook this plugin ships fails open) means the fail-open half has to be at least as
# thorough as the refusal half. Every case drives the REAL script over a synthetic Stop payload on
# stdin plus env vars — that is the hook's entire input contract.
#
# NOTHING here touches this session's own hooks or a real state file — every fixture is a scratch git
# repo (a real `origin` remote so the hook's owner/repo derivation has something to parse) plus a
# scratch AUTODEV_STATE_DIR the hook is pointed at via env, never the real
# $XDG_STATE_HOME/$HOME/.local/state a live fleet would use.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
WORK=$(kit_scratch)
kit_guard kit_guard_samples_unchanged

GATE="$KIT/hooks/autodev-stop-gate.sh"
[ -x "$GATE" ] || { echo "FAIL: $GATE missing or not executable"; exit 1; }

# A scratch repo with a real `origin` remote, so the hook's owner/repo derivation has something to
# read. `git init` only; nothing is ever committed.
repo_with_remote() { # $1 remote URL
  local d; d=$(mktemp -d "$WORK/repo.XXXXXX")
  git -C "$d" init -q >/dev/null 2>&1
  git -C "$d" remote add origin "$1" >/dev/null 2>&1
  printf '%s' "$d"
}
repo_no_remote() {
  local d; d=$(mktemp -d "$WORK/norigin.XXXXXX")
  git -C "$d" init -q >/dev/null 2>&1
  printf '%s' "$d"
}

# The exact path the hook is specified to derive — <owner> and <repo> are two path SEGMENTS, never
# joined into one filename with a separator (a dash-joined `auto-dev-<owner>-<repo>.md` collided:
# `-` is legal inside both a GitHub owner and repo name, so `foo-bar/baz` and `foo/bar-baz` both
# flattened to the same `auto-dev-foo-bar-baz.md`):
# ${AUTODEV_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}/tagout/auto-dev/<host>/<owner>/<repo>.md
state_path() { # $1 AUTODEV_STATE_DIR base  $2 host  $3 owner  $4 repo
  printf '%s/tagout/auto-dev/%s/%s/%s.md' "$1" "$2" "$3" "$4"
}

pay() { # $1 cwd  $2 stop_hook_active (true|false)  $3 optional session_id
  jq -nc --arg d "$1" --argjson a "$2" --arg s "${3:-gate-test}" \
    '{session_id:$s, cwd:$d, hook_event_name:"Stop", stop_hook_active:$a}'
}

# Drives the gate with a synthetic payload + env. Asserts exit code and (for a refusal) that the
# stderr names the given substrings.
# $1 name  $2 want_rc (0|2)  $3 payload  $4 AUTODEV_STATE_DIR  $5 AUTODEV_GATE  $6... substrings stderr must contain
verdict() {
  local name="$1" want_rc="$2" payload="$3" state_dir="$4" sw=""
  if [ "$#" -ge 5 ]; then sw="$5"; shift 5; else shift 4; fi
  local out rc=0
  out=$(printf '%s' "$payload" | env AUTODEV_STATE_DIR="$state_dir" AUTODEV_GATE="$sw" bash "$GATE" 2>&1 1>/dev/null) || rc=$?
  if [ "$rc" != "$want_rc" ]; then
    echo "FAIL [$name]: expected exit $want_rc, got $rc"; echo "$out"; exit 1
  fi
  if [ "$want_rc" = 0 ] && [ -n "$out" ]; then
    echo "FAIL [$name]: fail-open path printed output — must be silent: $out"; exit 1
  fi
  local sub
  for sub in "$@"; do
    grep -qF -- "$sub" <<<"$out" || { echo "FAIL [$name]: stderr lacks '$sub' — got: $out"; exit 1; }
  done
  echo "ok: $name -> exit $rc"
}

REPO=$(repo_with_remote "https://github.com/acme/widgets.git")
NOREMOTE=$(repo_no_remote)
SDIR=$(mktemp -d "$WORK/state.XXXXXX")
SPATH=$(state_path "$SDIR" github.com acme widgets)
mkdir -p "$(dirname "$SPATH")"

# `date -r <epoch>` (BSD/macOS) falling back to `date -d @<epoch>` (GNU/Linux) is the portable way
# to render an arbitrary past epoch into `touch -t`'s [[CC]YY]MMDDhhmm[.ss] form — there is no
# single `date` flag both platforms share for this (issue #548).
epoch_touch() { # $1 path  $2 epoch seconds
  local ts
  ts=$(date -r "$2" +%Y%m%d%H%M 2>/dev/null) || ts=$(date -d "@$2" +%Y%m%d%H%M 2>/dev/null) \
    || { echo "FAIL: epoch_touch could not render epoch $2 on this platform's date(1)"; exit 1; }
  touch -t "$ts" "$1"
}
age_past_window() { epoch_touch "$1" "$(( $(date +%s) - 3600 ))"; } # 60min: > SUPERVISED WINDOW, < 24h

write_state() { # $1 in-flight body  $2 queue body
  cat > "$SPATH" <<EOF
# auto-dev state — acme/widgets, N=3 · merges: 1
## In flight
$1
## Queue — SMALL (then MEDIUM), eligible & area-tagged
$2
## Completed
EOF
  # Every OTHER case in this suite is about owner/repo derivation, counting, or the off-switches —
  # not about issue #548's new recency check — so a state file this helper writes must land PAST
  # the new SUPERVISED WINDOW by default, or every existing "-> REFUSE" case below would flip to
  # ALLOW purely because `cat >` just gave it a fresh mtime. The dedicated 6b/6c cases override this
  # explicitly to test the window itself.
  age_past_window "$SPATH"
}

# --------------------------------------------------------------- 1. no state file at all (AC1)
rm -f "$SPATH"
verdict "AC1 no state file"          0 "$(pay "$REPO" false)" "$SDIR"

# ------------------------------------------------------- 2. state file, both sections empty (AC2)
write_state "" ""
verdict "AC2 empty in-flight and queue" 0 "$(pay "$REPO" false)" "$SDIR"

# ------------------------- 2b. only a PR held for the owner -> ALLOW (#694: a hold is drained work)
write_state "" ""
printf '## Held for owner\n- #42 → PR #43 — one-way door: .claude-plugin/marketplace.json\n' >> "$SPATH"
age_past_window "$SPATH"
verdict "#694 held-for-owner only" 0 "$(pay "$REPO" false)" "$SDIR"

# --------------------------------------------------- 3. one in-flight slot -> REFUSE (AC3)
write_state "- Slot A → #123 (auto-dev) — implementing" ""
verdict "AC3 one in-flight slot refuses" 2 "$(pay "$REPO" false)" "$SDIR" "" \
  "acme/widgets" "1" "AUTODEV_GATE=off"

# --------------------------------------- 3b. a slot line naming TWO #NNN tokens counts as ONE slot
# skills/auto-dev/SKILL.md's own template lets a slot's phase read "PR #<pr> ready→merging" — the
# issue number and the PR number on the SAME line. in_flight_count must count slot LINES, not `#`
# tokens, or this one slot reports as two.
write_state "- Slot A → #123 (auto-dev) — PR #456 ready→merging" ""
out=$(printf '%s' "$(pay "$REPO" false)" | env AUTODEV_STATE_DIR="$SDIR" AUTODEV_GATE="" bash "$GATE" 2>&1 1>/dev/null) || true
grep -qF '1 in-flight slot(s)' <<<"$out" \
  || { echo "FAIL [two-# slot line]: expected '1 in-flight slot(s)', got: $out"; exit 1; }
grep -qF '2 in-flight slot(s)' <<<"$out" \
  && { echo "FAIL [two-# slot line]: overcounted — a slot naming issue+PR read as two slots: $out"; exit 1; }
echo "ok: a slot naming both #issue and #PR counts as one in-flight slot"
write_state "- Slot A → #123 (auto-dev) — implementing" ""  # restore for what follows

# ----------------------------------------------- 4. same state, AUTODEV_GATE=off -> allow (AC4)
verdict "AC4 AUTODEV_GATE=off allows"  0 "$(pay "$REPO" false)" "$SDIR" off

# ------------------------------------------- 5. same state, stop_hook_active:true -> allow (AC5)
verdict "AC5 stop_hook_active true allows" 0 "$(pay "$REPO" true)" "$SDIR"

# ------------------------------------------------- 6. same state, but STALE mtime -> allow (AC6)
# A timestamp far enough in the past that no plausible staleness bound reads it as fresh.
touch -t 202001010000 "$SPATH"
verdict "AC6 stale state file allows"  0 "$(pay "$REPO" false)" "$SDIR"
write_state "- Slot A → #123 (auto-dev) — implementing" ""  # restore a fresh copy for what follows

# --------------------------------------- 6b/6c. issue #548 — the SUPERVISED WINDOW recency check.
# A state file freshly touched (the supervisor is actively cycling) allows the stop even with
# undrained work; one older than the window but still within the existing 24h bound still refuses,
# unchanged (write_state's own default via age_past_window, defined above).

# 6b (AC1). Freshly touched (now) — well inside any plausible SUPERVISED WINDOW (30 min). Overrides
# write_state's default backdating on purpose: this is the one case that tests the fresh path.
write_state "- Slot A → #123 (auto-dev) — implementing" ""
touch "$SPATH"
verdict "issue-548 AC1 fresh mtime within the supervised window allows" 0 "$(pay "$REPO" false)" "$SDIR"

# 6c (AC2). 60 minutes old (write_state's default) — past the 30-minute window, comfortably inside
# the 24h (1440-minute) staleness bound. Must still refuse and still name the undrained counts,
# exactly as case 3 does.
write_state "- Slot A → #123 (auto-dev) — implementing" ""
verdict "issue-548 AC2 mtime past the window but within 24h still refuses" 2 "$(pay "$REPO" false)" "$SDIR" "" \
  "acme/widgets" "1" "AUTODEV_GATE=off"

# --------------------------------------------------- 7. malformed payload / no jq -> allow (AC7)
verdict "AC7 payload is not JSON"      0 "not json at all" "$SDIR"

NOJQ=$(mktemp -d "$WORK/nojq.XXXXXX")
for c in bash cat awk grep git find date sed; do
  p=$(command -v "$c" 2>/dev/null) || continue
  ln -s "$p" "$NOJQ/$c" 2>/dev/null || true
done
out=$(printf '%s' "$(pay "$REPO" false 2>/dev/null || echo '{}')" \
  | env PATH="$NOJQ" AUTODEV_STATE_DIR="$SDIR" AUTODEV_GATE="" bash "$GATE" 2>&1 1>/dev/null) || rc=$?
rc=${rc:-0}
[ "$rc" = 0 ] || { echo "FAIL [AC7 no jq]: expected exit 0, got $rc: $out"; exit 1; }
[ -z "$out" ] || { echo "FAIL [AC7 no jq]: expected silence, got: $out"; exit 1; }
echo "ok: AC7 no jq on PATH -> exit 0, silent"

# --------------------------------------------------------------- 8. queue-only also refuses
write_state "" "#10 (compiler), #11 (studio)"
verdict "queue-only refuses, names depth" 2 "$(pay "$REPO" false)" "$SDIR" "" "2" "AUTODEV_GATE=off"

# --------------------------------------------------------- 9. no remote / can't derive -> allow
write_state "- Slot A → #123 (auto-dev) — implementing" ""
verdict "no origin remote allows (nothing to derive)" 0 "$(pay "$NOREMOTE" false)" "$SDIR"

# ------------------------------------------- 9b. the other two remote URL forms the header comment
# claims ("matches https://host/owner/repo(.git), git@host:owner/repo(.git) and
# ssh://git@host/owner/repo(.git)") — same owner/repo, so they resolve to the SAME $SPATH the https
# fixture above already seeded, and must refuse identically.
SSHCOLON=$(repo_with_remote "git@github.com:acme/widgets.git")
verdict "git@host:owner/repo(.git) form refuses"  2 "$(pay "$SSHCOLON" false)" "$SDIR" "" "acme/widgets"
SSHURL=$(repo_with_remote "ssh://git@github.com/acme/widgets.git")
verdict "ssh://git@host/owner/repo(.git) form refuses" 2 "$(pay "$SSHURL" false)" "$SDIR" "" "acme/widgets"

# ------------------------------------------------- 9c. trailing slash, no .git -> refuses correctly
# The owner/repo derivation strips a trailing slash before capturing (0b4e66f) — without that fix
# this fell through as an unparsed owner_repo and either exited 0 (nothing to derive) or, worse,
# produced a garbled state-file path instead of the real one. Must refuse identically to 9b.
TRAILSLASH=$(repo_with_remote "https://github.com/acme/widgets/")
verdict "trailing-slash remote refuses (not garbled)" 2 "$(pay "$TRAILSLASH" false)" "$SDIR" "" "acme/widgets"

# --------------------------------------------- 9d. malformed remote (no owner/repo shape) -> allow
MALFORMED=$(repo_with_remote "not-a-url-at-all")
verdict "malformed remote allows (nothing to derive)" 0 "$(pay "$MALFORMED" false)" "$SDIR"

# --------------------------------------------------- 9e. two owner/repo pairs that DASH-JOIN to the
# SAME key must resolve to DIFFERENT state files. `foo-bar/baz` and `foo/bar-baz` both flattened to
# `auto-dev-foo-bar-baz.md` under the old scheme — the exact collision this test exists to refuse.
COLL_A=$(repo_with_remote "https://github.com/foo-bar/baz.git")
COLL_B=$(repo_with_remote "https://github.com/foo/bar-baz.git")
COLL_A_PATH=$(state_path "$SDIR" github.com foo-bar baz)
COLL_B_PATH=$(state_path "$SDIR" github.com foo bar-baz)
[ "$COLL_A_PATH" != "$COLL_B_PATH" ] \
  || { echo "FAIL [collision]: state_path itself collides for foo-bar/baz and foo/bar-baz"; exit 1; }
mkdir -p "$(dirname "$COLL_A_PATH")"
cat > "$COLL_A_PATH" <<'EOF'
# auto-dev state — foo-bar/baz, N=1 · merges: 0
## In flight
- Slot A → #1 (auto-dev) — implementing
## Queue
## Completed
EOF
age_past_window "$COLL_A_PATH"  # written fresh above; age it past issue #548's SUPERVISED WINDOW
rm -f "$COLL_B_PATH"
verdict "collision A (foo-bar/baz) refuses on its own file" 2 "$(pay "$COLL_A" false)" "$SDIR" "" "foo-bar/baz"

# ---------------------------------------------------- 9f. same owner/repo on two HOSTS must resolve
# to DIFFERENT files (#471): the two-segment key dropped the host, so a fleet on github.com could
# refuse a stop in gitlab.example.com's checkout of an identically named repository.
HOST_A=$(repo_with_remote "https://github.com/acme/widgets.git")
HOST_B=$(repo_with_remote "https://gitlab.example.com/acme/widgets.git")
HOST_B_PATH=$(state_path "$SDIR" gitlab.example.com acme widgets)
[ "$SPATH" != "$HOST_B_PATH" ] || { echo "FAIL [host]: state_path collides across hosts"; exit 1; }
rm -f "$HOST_B_PATH"
verdict "host A (github.com) refuses on its own undrained file" 2 "$(pay "$HOST_A" false)" "$SDIR" "" "acme/widgets"
verdict "host B (gitlab.example.com) allows — the other host's file is not its evidence" 0 "$(pay "$HOST_B" false)" "$SDIR"
# Case in the host is not a different host: `GitHub.COM` keys the same file as `github.com`.
HOST_UPPER=$(repo_with_remote "https://GitHub.COM/acme/widgets.git")
verdict "host case-folds (GitHub.COM == github.com)" 2 "$(pay "$HOST_UPPER" false)" "$SDIR" "" "acme/widgets"
verdict "collision B (foo/bar-baz) allows — no file of its own, unaffected by A" 0 "$(pay "$COLL_B" false)" "$SDIR"

# -------------------------------------------- 9g. multi-@ in userinfo (credential with literal '@' in password)
# When a credential URL contains an unescaped @ inside the password portion, the host derivation
# needs to fail open rather than derive a garbled host. Seed state files at multiple plausible
# derived paths to catch the wrong host regardless of which mis-derivation the code takes.
MULTI_AT=$(repo_with_remote "https://user:p@ssword@host/owner/repo")
# State file paths for plausible mis-derivations of the multi-@ URL
WRONG_HOST_PATH_1=$(state_path "$SDIR" "ssword@host" owner repo)  # mis-derived host
WRONG_HOST_PATH_2=$(state_path "$SDIR" "user" owner repo)          # other possible mis-derivation
RIGHT_HOST_PATH=$(state_path "$SDIR" host owner repo)              # the correct host
mkdir -p "$(dirname "$WRONG_HOST_PATH_1")" "$(dirname "$WRONG_HOST_PATH_2")"
# Seed state files at the wrong derivations to force a refusal if the old code hits them
cat > "$WRONG_HOST_PATH_1" <<'EOF'
# auto-dev state — wrong-host-1, N=1
## In flight
- Slot A → #1 (auto-dev) — implementing
## Queue
## Completed
EOF
age_past_window "$WRONG_HOST_PATH_1"  # so a mis-derivation bug would still refuse, not fail-open
cat > "$WRONG_HOST_PATH_2" <<'EOF'
# auto-dev state — wrong-host-2, N=1
## In flight
- Slot A → #1 (auto-dev) — implementing
## Queue
## Completed
EOF
age_past_window "$WRONG_HOST_PATH_2"
# The correct path should have no state file (so no refusal from it)
rm -f "$RIGHT_HOST_PATH"
# Verdict: multi-@ credentials should fail open (exit 0) regardless of which host derives
verdict "multi-@ in credential (user:p@ssword@host) fails open" 0 "$(pay "$MULTI_AT" false)" "$SDIR"
# Clean up for what follows
rm -f "$WRONG_HOST_PATH_1" "$WRONG_HOST_PATH_2"

# ------------------------------------------------- 9h. credentialed origin — the userinfo-strip
# clause must cross a `:` (#532): on `https://user:token@host/…` the middle sed clause used to stop
# at the FIRST `:` (inside `user:token@`) rather than crossing it, so `$host` resolved to the
# credential's username instead of the real host. Pin the real host's state file and expect the
# SAME refusal every other credentialed/uncredentialed origin gets above — a `host=x-access-token`
# derivation would look at a file that doesn't exist and wrongly ALLOW instead.
CRED=$(repo_with_remote "https://x-access-token:ghp_abc123@ghe.example.com/acme/widgets.git")
CRED_PATH=$(state_path "$SDIR" ghe.example.com acme widgets)
mkdir -p "$(dirname "$CRED_PATH")"
cat > "$CRED_PATH" <<'EOF'
# auto-dev state — acme/widgets, N=1 · merges: 0
## In flight
- Slot A → #1 (auto-dev) — implementing
## Queue
## Completed
EOF
age_past_window "$CRED_PATH"  # written fresh above; age it past the SUPERVISED WINDOW
verdict "credentialed origin (user:token@) resolves the real host, not the userinfo" 2 \
  "$(pay "$CRED" false)" "$SDIR" "" "acme/widgets"
rm -f "$CRED_PATH"

# ------------------------------------------------- 9i. plain userinfo, no token (Spec AC2 / edge
# case) — `https://user@host/owner/repo` has no `:` before its `@`, so both the old and the fixed
# clause already stripped it the same way; pinned explicitly since the Spec names this exact shape
# as a required regression check, not just the SSH forms above that happen to share it.
PLAINUSER=$(repo_with_remote "https://user@github.com/acme/widgets.git")
verdict "plain userinfo (user@, no token) resolves the host unaffected" 2 \
  "$(pay "$PLAINUSER" false)" "$SDIR" "" "acme/widgets"

# --------------------------------------------------------------- 10. a repo with no cwd at all
verdict "empty cwd allows" 0 "$(jq -nc '{session_id:"x",hook_event_name:"Stop",stop_hook_active:false}')" "$SDIR"

# --------------------------------------------- 9i. the userinfo-strip clause must match _gh-host.sh
# #516's sibling parser already carries this exact fix and says so in its own comment ("the stop gate
# keeps that miss") — pin the two clauses identical so a future edit to either drifts apart loudly,
# not silently, the way this bug did in the first place.
GHHOST="$KIT/skills/_shared/scripts/_gh-host.sh"
grep -qF 's#^[^@/]*@##' "$GATE" \
  || { echo "FAIL: $GATE's userinfo-strip clause is missing or has drifted from the fix"; exit 1; }
grep -qF 's#^[^@/]*@##' "$GHHOST" \
  || { echo "FAIL: $GHHOST's userinfo-strip clause is missing or has drifted from the fix"; exit 1; }
echo "ok: autodev-stop-gate.sh's userinfo-strip clause matches _gh-host.sh's (#532)"

# ------------------------------------------------------------------------- 11. structural wiring
./scripts/parse-sweep.sh hooks/autodev-stop-gate.sh tests/autodev-stop-gate/test.sh >/dev/null \
  || { echo "FAIL: parse-sweep rejects the gate or this suite"; exit 1; }
echo "ok: the gate and this suite pass ./scripts/parse-sweep.sh"

HJ="$KIT/hooks/claude-hooks.json"
jq -e . "$HJ" >/dev/null 2>&1 || { echo "FAIL: hooks.json is not valid JSON"; exit 1; }
n=$(jq '[.hooks.Stop[]?] | length' "$HJ")
[ "$n" = "1" ] || { echo "FAIL: hooks.json has $n Stop hook entries, want exactly 1"; exit 1; }
got=$(jq -r '.hooks.Stop[0].hooks[0].command' "$HJ")
case "$got" in
  *'${CLAUDE_PLUGIN_ROOT}'*autodev-stop-gate.sh) echo "ok: hooks.json wires Stop -> $got" ;;
  *) echo "FAIL: Stop hook command is '$got'; must reference \${CLAUDE_PLUGIN_ROOT}/hooks/autodev-stop-gate.sh"; exit 1 ;;
esac
tmo=$(jq -r '.hooks.Stop[0].hooks[0].timeout // empty' "$HJ")
[ -n "$tmo" ] || { echo "FAIL: the Stop hook has no timeout; a hung gate would stall every stop attempt"; exit 1; }
resolved="${got/\$\{CLAUDE_PLUGIN_ROOT\}/$KIT}"
[ -x "$resolved" ] || { echo "FAIL: hooks.json points at '$resolved', which is not an executable file"; exit 1; }
echo "ok: the registered command resolves to a shipped executable with timeout=$tmo"

# The other three hooks must survive this PR untouched.
jq -e '[.hooks.PreToolUse[]? | select(.matcher=="Read")] | length == 1' "$HJ" >/dev/null \
  || { echo "FAIL: hooks.json no longer carries exactly one Read matcher"; exit 1; }
jq -e '[.hooks.PreToolUse[]? | select(.matcher=="Bash")] | length == 1' "$HJ" >/dev/null \
  || { echo "FAIL: hooks.json no longer carries exactly one Bash matcher"; exit 1; }
jq -e '[.hooks.SessionStart[]?] | length == 1' "$HJ" >/dev/null \
  || { echo "FAIL: hooks.json no longer carries exactly one SessionStart entry"; exit 1; }
echo "ok: the other three hooks are still registered"

# S3 — the registry entry (ADR 0011: recorded in not_decisions, never registered as a decision).
python3 - "$KIT/decisions/registry.json" <<'PY' || exit 1
import json, sys
reg = json.load(open(sys.argv[1]))
nd = reg.get("not_decisions", {})
key = "hooks/autodev-stop-gate.sh"
if key not in nd:
    print(f"FAIL: decisions/registry.json not_decisions has no entry for {key}")
    sys.exit(1)
if not nd[key].strip():
    print(f"FAIL: the not_decisions entry for {key} is empty; it must say WHY")
    sys.exit(1)
print(f"ok: decisions/registry.json records {key} under not_decisions")
PY

# S4 — the off-switch is documented somewhere a reader can find it.
grep -qF 'AUTODEV_GATE' "$KIT/README.md" \
  || { echo "FAIL: README does not document AUTODEV_GATE"; exit 1; }
echo "ok: README documents AUTODEV_GATE"

echo "autodev-stop-gate golden test OK"
