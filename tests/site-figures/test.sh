#!/usr/bin/env bash
# Golden test for scripts/site-figures.py (#788): it reads the tracker through gh and writes the four
# figures the docs home page renders. A stubbed gh on PATH serves fixture JSON; the suite reads what
# a caller reads — exit code, stdout, stderr, the --out file.
#
#   happy    three merged PRs (two close an issue, one none) -> 0, the three counts and the median
#   refusal  no merged PR -> 1, REFUSED on stderr, an existing --out file byte-identical
#   no-gh    no gh on PATH -> 2
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"
SCRIPT="$KIT/scripts/site-figures.py"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
WORK=$(kit_scratch)
PY=$(command -v python3)

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") printf '%s\n' "$GH_PRS_FIXTURE" ;;
  "issue list") printf '%s\n' "$GH_ISSUES_FIXTURE" ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/gh"

PRS='[{"number":10,"mergedAt":"2026-01-02T10:00:00Z","closingIssuesReferences":[{"number":1}]},
{"number":11,"mergedAt":"2026-01-03T20:00:00Z","closingIssuesReferences":[{"number":2}]},
{"number":12,"mergedAt":"2026-01-04T00:00:00Z","closingIssuesReferences":[]}]'
ISSUES='[{"number":1,"createdAt":"2026-01-02T00:00:00Z"},{"number":2,"createdAt":"2026-01-03T00:00:00Z"},{"number":3,"createdAt":"2026-01-03T00:00:00Z"}]'

fail() { echo "FAIL: $1"; exit 1; }

# happy
rc=0
out=$(PATH="$WORK/bin:$PATH" GH_PRS_FIXTURE="$PRS" GH_ISSUES_FIXTURE="$ISSUES" "$PY" "$SCRIPT" 2>"$WORK/err") || rc=$?
[ "$rc" = 0 ] || fail "happy case exited $rc: $(cat "$WORK/err")"
for want in "prs_merged: 3" "issues_delivered: 2" "median_issue_to_merge_hours: 15.0"; do
  grep -qx "$want" <<<"$out" || fail "happy case: stdout lacks '$want'"
done
grep -q '^as_of: [0-9]\{4\}-[0-9][0-9]-[0-9][0-9]$' <<<"$out" || fail "happy case: no as_of line"
[ "${out%%$'\n'*}" = "# Written by scripts/site-figures.py — never edited by hand." ] || fail "happy case: first line is not the script comment"

# refusal: an existing --out file stays byte-identical
printf 'keep me\n' > "$WORK/figures.yml"
cp "$WORK/figures.yml" "$WORK/figures.before"
rc=0
PATH="$WORK/bin:$PATH" GH_PRS_FIXTURE='[]' GH_ISSUES_FIXTURE="$ISSUES" "$PY" "$SCRIPT" --out "$WORK/figures.yml" >/dev/null 2>"$WORK/err" || rc=$?
[ "$rc" = 1 ] || fail "refusal case exited $rc, expected 1"
grep -q 'REFUSED' "$WORK/err" || fail "refusal case: no REFUSED line on stderr"
cmp -s "$WORK/figures.yml" "$WORK/figures.before" || fail "refusal case: --out file changed"

# --out writes the file and prints its path
PATH="$WORK/bin:$PATH" GH_PRS_FIXTURE="$PRS" GH_ISSUES_FIXTURE="$ISSUES" "$PY" "$SCRIPT" --out "$WORK/figures.yml" >"$WORK/out2" 2>/dev/null || fail "--out case failed"
grep -qx "prs_merged: 3" "$WORK/figures.yml" || fail "--out case: file lacks prs_merged"
grep -qx "$WORK/figures.yml" "$WORK/out2" || fail "--out case: path not printed"

# no gh
mkdir -p "$WORK/empty"
rc=0
PATH="$WORK/empty" "$PY" "$SCRIPT" >/dev/null 2>"$WORK/err" || rc=$?
[ "$rc" = 2 ] || fail "no-gh case exited $rc, expected 2"

echo "PASS: site-figures"
