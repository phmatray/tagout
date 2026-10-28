#!/usr/bin/env bash
# Golden test for guarded-ready.sh (#728) — refusal first, then the happy path, with a stubbed gh.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT_ROOT="$PWD"
GUARD="$KIT_ROOT/skills/implement-issue/scripts/guarded-ready.sh"
PRC="$KIT_ROOT/skills/implement-issue/scripts/post-review-check.sh"
. "$KIT_ROOT/tests/_lib.sh" || { echo "FAIL: cannot source _lib.sh"; exit 1; }
kit_init "$KIT_ROOT"
WORK=$(kit_scratch)
fail() { echo "FAIL [$1]: $2"; [ -f "${OUT:-}" ] && sed 's/^/    | /' "$OUT"; exit 1; }

mkdir "$WORK/bin"
cat > "$WORK/bin/gh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$WORK/gh.log"
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

R="$WORK/repo"
git init -q "$R"
git -C "$R" symbolic-ref HEAD refs/heads/feat/42-x
git -C "$R" config user.email t@example.com
git -C "$R" config user.name T
git -C "$R" config commit.gpgsign false
git -C "$R" config core.hooksPath "$R/.git/hooks"
git -C "$R" commit -q --allow-empty -m seed
B=feat/42-x
run() { OUT="$WORK/out"; set +e; "$@" > "$OUT" 2>&1; RC=$?; set -e; }

# refusal: no record -> exit 1, REFUSED, gh never called
run "$GUARD" -C "$R" --branch "$B" 42
[ "$RC" -eq 1 ] || fail refuse "expected exit 1, got $RC"
grep -q "guarded-ready: REFUSED — no review recorded for $B; run implement-issue Step 7" "$OUT" || fail refuse "missing REFUSED line"
[ ! -s "$WORK/gh.log" ] || fail refuse "gh was called"

# happy: a clean post-review-check records, the guard flips
HEAD_SHA=$(git -C "$R" rev-parse HEAD)
run "$PRC" -C "$R" --branch "$B" --before "$HEAD_SHA"
[ "$RC" -eq 0 ] || fail record "post-review-check expected 0, got $RC"
run "$GUARD" -C "$R" --branch "$B" 42
[ "$RC" -eq 0 ] || fail ok "expected exit 0, got $RC"
grep -q "guarded-ready: OK — review recorded at $HEAD_SHA" "$OUT" || fail ok "missing OK line"
grep -qx "pr ready 42" "$WORK/gh.log" || fail ok "gh not called with 'pr ready 42'"

# usage errors -> 2
run "$GUARD" --branch "$B" 42;          [ "$RC" -eq 2 ] || fail usage "missing -C: got $RC"
run "$GUARD" -C "$R" 42;                [ "$RC" -eq 2 ] || fail usage "missing --branch: got $RC"
run "$GUARD" -C "$R" --branch "$B";     [ "$RC" -eq 2 ] || fail usage "missing PR: got $RC"
run "$GUARD" -C "$R" --branch "$B" 4x;  [ "$RC" -eq 2 ] || fail usage "non-digit PR: got $RC"

# wiring: Step 9 calls the guard, no bare gh pr ready line
S9="$KIT_ROOT/skills/implement-issue/references/steps/09-verify-and-mark-ready.md"
grep -q 'guarded-ready.sh' "$S9" || fail wiring "Step 9 does not name guarded-ready.sh"
! grep -q '^gh pr ready' "$S9" || fail wiring "Step 9 still has a bare gh pr ready line"

echo "OK: guarded-ready.sh — refusal/record+flip/usage/wiring all verified"
