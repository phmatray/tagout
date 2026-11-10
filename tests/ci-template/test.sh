#!/usr/bin/env bash
# templates/ci-dotnet.yml — the OPT-IN committed-bundle drift gate.
#
# The hazard, measured on Ninjadog (2026-07-26): `Ninjadog.CLI.csproj` embeds `WebUI/dist/**` as an
# EmbeddedResource, `dist/` is committed, and no MSBuild target calls npm. Bumping the vulnerable
# JS dependency therefore changed the lockfile and NOT ONE BYTE of the shipped binary — while the
# PR closed and the Dependency Dashboard showed the advisory as fixed. That is worse than leaving
# it unfixed: it manufactures a FALSE REMEDIATION.
#
# The steps ship INERT, and that is a measured decision, not timidity (issue #32): across 193 local
# .NET repos, exactly 3 commit build output and exactly 1 has it consumed by the .NET build. A step
# that RAN by default on the other 192 would be deleted or `continue-on-error`'d, which teaches a
# team to ignore a red step — strictly worse than absent.
#
# Inert used to mean "commented out". Since #70 it means an `if:` on live YAML, because a comment
# cost more than it saved: Renovate's github-actions manager cannot see a commented action
# reference. Measured with its own extractor — 5 dependencies from this file with the block as
# text, 7 with it live, the two extra being `actions/setup-node` and `node 26.5.0`. The gate's
# second precondition is a PINNED toolchain (Tailwind v4 and lightningcss ship per-platform native
# binaries), so leaving that pin unmaintainable undercut the very guarantee the step exists to
# provide. Going live also deleted this file's sentinel slicer and un-commenter: the steps are now
# read the way GitHub reads them.
#
# What arms it moved once more, in #96. It was `vars.BUNDLE_DIST != ''` — two repo variables, which
# is *invisible settings state*: a settings tidy-up, a repo transfer (variables do not travel with
# the code), an org policy change or a fork PR makes all three steps evaluate `'' != ''`, they show
# as skipped, and the job is green forever measuring nothing. A repo that never wanted the gate and
# one that LOST it were indistinguishable, and the second is the repo that thinks it is protected.
# So the arming condition is now a COMMITTED file, `.github/bundle-gate.json`, carrying both paths:
# enabling and disabling are diffs again, the config travels with the code, and a fork PR sees it.
#
# What is asserted:
#   1. four live steps — config, setup-node, rebuild, guard — in that order, each gated on the
#      committed config file, with Node pinned to an EXACT version;
#  1c. the config step REFUSES a malformed, untracked, absent or self-inconsistent config rather
#      than exporting nothing and letting the rest of the block run on empty paths;
#  1e. the shipped `templates/bundle-gate.json.example` — the file an adopter copies — is itself a
#      config the gate would accept, not merely valid JSON;
#  1d. a fifth step runs on the ABSENCE of the config and reports a repo that carries a committed
#      bundle consumed by a project — so losing the config stops looking like never wanting it —
#      while staying silent, and green, on the 192 repos that have no such bundle;
#   2. the guard FAILS on a bundle that no longer matches its sources;
#   3. it fails on the content-hash rename (delete + UNTRACKED add), and 3b on the real-world
#      shape where the bundle dir is gitignored and force-added — both invisible to plain
#      `--porcelain`/`git diff`, which is why `--porcelain --ignored` is mandatory;
#   4. the guard PASSES on a bundle that does match — a gate that always fails is not a gate;
#  5b. a misconfigured path is REFUSED rather than passing quietly on nothing, and 5c a directory
#      that exists but holds no tracked file likewise;
#   5. as shipped all four are inert, by a condition that is false when the config file is absent —
#      and nothing outside the gate references the config or the paths it exports;
#  6-9. the coverage artifact step (pre-existing assertions, unrelated to the bundle gate);
#   10. the coverage guard still reports on what it FOUND when the step runs under
#       `set -euo pipefail` — the configuration in which the shipped `find … | grep -q .` idiom
#       inverts and fails the build precisely when coverage WAS produced (#97).
#
# Needs PyYAML, which ci.yml installs before every test step.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
TEMPLATE="$KIT/templates/ci-dotnet.yml"

# The template must come out of this run byte-identical. Compared against a hash taken HERE, not
# against git HEAD: the PR that adds or edits this test may also edit the template, so a
# `git status` check would report the author's own work as damage and fail every run of a correct
# test.
TEMPLATE_BEFORE=$(shasum -a 256 "$TEMPLATE" | cut -d' ' -f1)
template_unchanged() {
  local after
  after=$(shasum -a 256 "$TEMPLATE" | cut -d' ' -f1)
  if [ "$after" != "$TEMPLATE_BEFORE" ]; then
    echo "FAIL: this test modified templates/ci-dotnet.yml — it must only read it."
    return 1
  fi
}

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
kit_guard kit_guard_samples_unchanged
kit_guard template_unchanged

scratch=$(kit_scratch)

# The path of the committed file that ARMS the gate. Spelled once, here, because both the shell
# sections and the embedded python assert against it and a drifted copy would assert nothing.
CONFIG=".github/bundle-gate.json"

# The opt-in steps are LIVE YAML now, so they are read the way GitHub reads them — no
# sentinel slicer, no un-commenter, no "every line inside the markers must be a comment" check.
# #70 measured why the text form had to go: a commented action reference is INVISIBLE to
# Renovate's github-actions manager. Running its own extractor over this file found 5 dependencies
# and no setup-node; with the step live it finds 7, including `node 26.5.0`. The gate depends on a
# pinned toolchain (per-platform native binaries in Tailwind v4 / lightningcss), and that pin could
# never be maintained while it lived in a comment.
step_named() {
  python3 - "$TEMPLATE" "$1" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
step = next((s for s in doc["jobs"]["test"]["steps"] if s.get("name") == sys.argv[2]), None)
if step is None:
    sys.exit(f"templates/ci-dotnet.yml has no step named {sys.argv[2]!r}")
sys.stdout.write(step.get("run") or "")
PY
}

# ---------------------------------------------------------------------------
# 1. The four steps are present, ordered, and inert by default.
#
#    Order is load-bearing: config, then setup-node, then rebuild, then guard. A guard that ran
#    before the rebuild would measure a tree nothing regenerated and pass on a stale bundle — the
#    exact failure it exists to catch. And the config step must come FIRST, because it is what
#    publishes the two paths the rebuild and the guard consume: `if:` and `working-directory:` are
#    evaluated before a step runs and cannot read a file, so the paths have to reach them as step
#    outputs or not at all.
# ---------------------------------------------------------------------------
python3 - "$TEMPLATE" "$CONFIG" <<'PY'
import re, sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
config = sys.argv[2]
steps = doc["jobs"]["test"]["steps"]
names = [s.get("name") for s in steps]
want = ["Configuration de la garde bundle",
        "Setup Node (bundle front committé)",
        "Reconstruire le bundle front committé",
        "Garde — le bundle front committé correspond toujours à ses sources"]
# Index by POSITION, never by name: a duplicated step name would silently collapse in a
# name->step dict, so the assertions below would inspect the last copy while `names.index()`
# still found the first — an ungated duplicate could pass every check here.
named = [n for n in names if n is not None]   # `uses:`-only steps carry no name; that is fine
assert len(named) == len(set(named)), \
    f"duplicate step names make these assertions unsound: {names}"
for w in want:
    assert w in names, f"missing step {w!r}: {names}"
idx = [names.index(w) for w in want]
assert idx == sorted(idx), f"config -> setup-node -> rebuild -> guard is out of order: {idx}"
by = {names[i]: steps[i] for i in idx}
for w in want:
    cond = str(by[w].get("if", ""))
    assert f"hashFiles('{config}')" in cond, (
        f"step {w!r} is not gated on the committed config {config!r} — it would RUN on every repo "
        f"that takes this template, including the ones with no bundle at all: if={cond!r}")
# The config step is the only source of the two paths, so it needs an id the others can name.
cfg_step = by["Configuration de la garde bundle"]
assert cfg_step.get("id"), f"the config step carries no id, so nothing can read its outputs: {cfg_step}"
CFG_ID = str(cfg_step["id"])
# A hyphen in a step id is legal but cannot be dereferenced as `steps.<id>.outputs.x` — it would
# have to be `steps['a-b']`, which nothing here writes. Refuse the id shape that silently yields
# an empty path, because an empty path is how this gate goes green over a stale bundle.
assert re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", CFG_ID), (
    f"step id {CFG_ID!r} is not dot-dereferenceable in an expression; `steps.{CFG_ID}.outputs.src` "
    f"would not resolve and the rebuild would run in the repository root")
# The condition arms the gate on one path and the body reads another variable for it. They must be
# the SAME string — the two-sources-of-truth trap of section 5d, one level up: armed by a file the
# step never opens, the step would refuse forever or, worse, read a different file.
cfg_env = str((cfg_step.get("env") or {}).get("BUNDLE_GATE_CONFIG", ""))
assert cfg_env == config, (
    f"the config step's BUNDLE_GATE_CONFIG ({cfg_env!r}) is not the path the gate is armed on "
    f"({config!r}): the condition and the body would disagree about which file configures this")
# The pinned action and the exact Node version are precisely what Renovate can now maintain.
node = by["Setup Node (bundle front committé)"]
assert str(node.get("uses", "")).startswith("actions/setup-node@"), node
ver = str((node.get("with") or {}).get("node-version", ""))
# `N.N.N` of digits and nothing else. A looser check (first char a digit, two dots) accepts
# `26.5.x`, `26.5.*` and `26.5.0 - 26.9.0` — every one of which lets setup-node resolve a
# different patch per run, which is exactly the drift the pin exists to remove.
assert re.fullmatch(r"\d+\.\d+\.\d+", ver), (
    f"node-version must be an EXACT N.N.N, not a range: {ver!r}. Precondition 2 of this gate — "
    f"per-platform native binaries in the front-end toolchain — collapses if Node floats.")
# The rebuild must be driven by the SAME configuration as the guard. A hardcoded
# working-directory beside a variable-driven guard is two sources of truth: point them at
# different trees and npm rebuilds one while the guard inspects the other, so the step goes
# GREEN over a stale bundle — the false remediation this whole gate exists to prevent.
wd = str(by["Reconstruire le bundle front committé"].get("working-directory", ""))
assert f"steps.{CFG_ID}.outputs.src" in wd, (
    f"the rebuild's working-directory must come from the same committed configuration as the "
    f"guard, not be hardcoded in the template and not read a second source: {wd!r}")
PY
echo "  [1] four live steps, ordered, gated on the committed config, Node pinned N.N.N"

# ---------------------------------------------------------------------------
# 1b. The plumbing itself — `env: BUNDLE_DIST: ${{ steps.<cfg>.outputs.dist }}` — is the SUBJECT of
#     this design, and every other section injects the values itself, so nothing would notice if the
#     wiring were deleted or misspelled. Then the one repo that opted in gets a guard that either
#     reds out on every run or silently measures the wrong directory.
#
#     The guard's own env NAMES do not move (`BUNDLE_DIST`, `BUNDLE_SRC`): what #96 changes is where
#     the two paths COME FROM, not the contract between the template and the guard body. Keeping the
#     names is what lets every behavioural section below drive the shipped body unchanged.
# ---------------------------------------------------------------------------
python3 - "$TEMPLATE" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = doc["jobs"]["test"]["steps"]
cfg_id = next(s for s in steps if s.get("name") == "Configuration de la garde bundle")["id"]
guard = next(s for s in steps
             if s.get("name") == "Garde — le bundle front committé correspond toujours à ses sources")
env = guard.get("env") or {}
for var, out in (("BUNDLE_DIST", "dist"), ("BUNDLE_SRC", "src")):
    assert var in env, f"the guard does not receive {var} from the committed config: env={env}"
    assert f"steps.{cfg_id}.outputs.{out}" in str(env[var]), \
        f"{var} is not wired to the config step's {out!r} output: {env[var]!r}"
PY
echo "  [1b] the guard receives both paths from the committed config, by name"

step_named "Garde — le bundle front committé correspond toujours à ses sources" > "$scratch/guard.sh"
[ -s "$scratch/guard.sh" ] || { echo "FAIL: the guard step has an empty run: body"; exit 1; }
bash -n "$scratch/guard.sh" || { echo "FAIL: the guard body is not valid bash"; exit 1; }

# The scratch repositories below commit a bundle under `dist/`, and a developer's personal git
# excludes commonly list `dist/` — `git add -A` then stages nothing and the commit stops with
# "nothing to commit" (#744). BOTH halves are needed: git reads `$XDG_CONFIG_HOME/git/ignore` by
# default, and a `~/.gitconfig` can name another file through `core.excludesFile`.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$scratch/xdg"

# One place for the identity/gpgsign workaround every scratch commit below needs.
# `commit.gpgsign=false` is not decoration: with signing on globally and no usable key in this
# shell, the commit fails, `set -e` aborts, and every section below reports as broken with a gpg
# error rather than a template defect. CI never sees it, which is what makes it a local-only
# trap. tests/guarded-git/test.sh already solved this the same way.
git_commit_all() {   # $1 = repo path · $2 = commit message
  git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm "$2"
}

# A scratch git repo carrying a committed bundle. `$1` = path, `$2` = asset filename.
mk_repo() {
  local root="$1" asset="$2"
  mkdir -p "$root/web/dist/assets"
  git -C "$root" init -q 2>/dev/null || git init -q "$root"
  printf 'console.log(1)\n' > "$root/web/dist/assets/$asset"
  printf '<script src="/assets/%s"></script>\n' "$asset" > "$root/web/dist/index.html"
  git -C "$root" add -A
  git_commit_all "$root" "commit the bundle"
}

# The bundle really is in the commit — not silently dropped by an excludes file this suite did not
# write. Every section below reasons from a committed `web/dist`.
mk_repo "$scratch/excludes-probe" "probe.js"
[ "$(git -C "$scratch/excludes-probe" ls-files web/dist/index.html)" = "web/dist/index.html" ] || {
  echo "FAIL: mk_repo did not commit web/dist/index.html — a personal git excludes file is leaking into the scratch repositories"; exit 1; }

# ---------------------------------------------------------------------------
# 1c. The config step is the whole point of #96, so it is driven, not merely read.
#
#     It is the one step that turns a committed FILE into the two paths every other step consumes.
#     If it ever exported empty strings instead of refusing, `working-directory:` would fall back
#     to the repository root and the guard would inspect `''` — `git status --porcelain -- ''`
#     exits 0 with empty output, so the block would be green forever while measuring nothing. That
#     is the failure this issue exists to remove, so every way the config can be wrong is refused
#     here rather than exported.
#
#     Driven by executing the shipped `run:` body against scratch repositories, exactly as the
#     guard body is below — the template is the subject, not a description of one.
# ---------------------------------------------------------------------------
step_named "Configuration de la garde bundle" > "$scratch/config.sh"
[ -s "$scratch/config.sh" ] || { echo "FAIL: the config step has an empty run: body"; exit 1; }
bash -n "$scratch/config.sh" || { echo "FAIL: the config body is not valid bash"; exit 1; }

# A scratch repo shaped like the one consumer that has a bundle: a front-end project carrying
# package.json and a committed `dist/`, plus the committed config that arms the gate.
#   $1 = repo path · $2 = raw contents of the config file · $3 = "untracked" to leave it uncommitted
mk_config_repo() {
  local root="$1" cfg_text="$2" tracked="${3:-tracked}"
  mk_repo "$root" "index-KKKKKKKK.js"
  printf '{ "name": "web", "private": true }\n' > "$root/web/package.json"
  mkdir -p "$root/$(dirname "$CONFIG")"
  printf '%s\n' "$cfg_text" > "$root/$CONFIG"
  if [ "$tracked" = tracked ]; then
    git -C "$root" add -A
  else
    git -C "$root" add -A -- web
  fi
  git_commit_all "$root" "commit the front-end project and its gate config"
}

# Runs the shipped config body in `$1`, leaving the exit status in $config_rc, the console output
# in $scratch/out-config.txt and whatever it published in $1/gh-output.txt. Not `return $rc`: the
# callers run under `set -e`, where a non-zero return would abort the suite on the refusal cases
# that are supposed to be non-zero.
config_rc=0
run_config() {
  set +e
  ( cd "$1" && GITHUB_OUTPUT="$1/gh-output.txt" BUNDLE_GATE_CONFIG="$CONFIG" \
      bash "$scratch/config.sh" ) > "$scratch/out-config.txt" 2>&1
  config_rc=$?
  set -e
}

# The happy path first — without it, "always refuses" would score as a pass.
CGOOD="$scratch/config-valid"
mk_config_repo "$CGOOD" '{ "src": "web", "dist": "web/dist" }'
run_config "$CGOOD"
if [ "$config_rc" -ne 0 ]; then
  echo "FAIL: the config step refused a valid $CONFIG:"; cat "$scratch/out-config.txt"; exit 1
fi
grep -qx 'src=web' "$CGOOD/gh-output.txt" || {
  echo "FAIL: the config step did not publish src=web:"; cat "$CGOOD/gh-output.txt"; exit 1; }
grep -qx 'dist=web/dist' "$CGOOD/gh-output.txt" || {
  echo "FAIL: the config step did not publish dist=web/dist:"; cat "$CGOOD/gh-output.txt"; exit 1; }
echo "  [1c] a valid committed config publishes both paths as step outputs"

# Every way the file can be wrong. Each must be REFUSED — a skipped-looking green is the defect.
# `dist` outside `src` is the correlation #87 had to check at runtime; it is checked on the file
# now, BEFORE npm has rebuilt anything, and the guard body keeps its own copy of the check (5d).
config_refuses() {   # $1 = case label · $2 = config contents · $3 = "untracked" (optional)
  local label="$1" text="$2" tracked="${3:-tracked}"
  local root="$scratch/config-bad-$(printf '%s' "$label" | tr -c 'a-z0-9' '-')"
  mk_config_repo "$root" "$text" "$tracked"
  run_config "$root"
  if [ "$config_rc" -eq 0 ]; then
    echo "FAIL: the config step ACCEPTED $label — it would arm the gate on a configuration that"
    echo "      cannot describe a bundle, and the run would be green while measuring nothing:"
    cat "$scratch/out-config.txt"
    exit 1
  fi
  # -F: the path is a literal, and its dots would otherwise be regex wildcards — a message naming
  # some OTHER `Xgithub/bundle-gateXjson` would satisfy a regex match and prove nothing.
  grep -qF "$CONFIG" "$scratch/out-config.txt" || {
    echo "FAIL: refused $label but never named $CONFIG, so nobody knows what to fix:"
    cat "$scratch/out-config.txt"; exit 1; }
  # A refusal must publish nothing: a half-written output file is an empty path by another name.
  if [ -s "$root/gh-output.txt" ]; then
    echo "FAIL: the config step refused $label yet still published outputs:"
    cat "$root/gh-output.txt"; exit 1
  fi
}

config_refuses "malformed json"     '{ "src": "web", '
config_refuses "a json array"       '["web", "web/dist"]'
config_refuses "a missing dist key" '{ "src": "web" }'
config_refuses "a missing src key"  '{ "dist": "web/dist" }'
config_refuses "an empty dist"      '{ "src": "web", "dist": "" }'
config_refuses "an absolute dist"   '{ "src": "/web", "dist": "/web/dist" }'
config_refuses "a dot-dot escape"   '{ "src": "web", "dist": "web/../../etc" }'
# `web/dist/assets`, not `web/dist`, so this case exercises the missing-package.json path and only
# that: spelled with dist == src it is now refused one check earlier, by the equality rule below,
# and would have stopped covering the check its label names.
config_refuses "a src with no package.json" '{ "src": "web/dist", "dist": "web/dist/assets" }'
config_refuses "an untracked config" '{ "src": "web", "dist": "web/dist" }' untracked
echo "  [1c] refuses every malformed, self-inconsistent or uncommitted config instead of arming"

# ---------------------------------------------------------------------------
# 1c-bis. ONE table of containment cases, driven against BOTH shipped copies of the rule — the
#     config step here, the guard body in 5d. The two copies are deliberate (see the template's
#     own argument), but #151 proved they were maintained by RETYPING: the review found the same
#     `case "$dist/" in "$src"/*)` hole — `*` matches the empty string — in both, and it had to
#     be fixed twice. A second line of defence that is a copy of the first, bug included, is not
#     defence in depth. Adding a row below now costs one line and proves it against both.
#
#     Also folds in the two individually-written cases this replaces: "dist outside src" (a
#     different tree entirely — the docs-site/web/dist row) and the front-end-at-the-repository-
#     root pair ("." / "dist" and "./" / "./dist/") that used to be a bespoke loop below.
# ---------------------------------------------------------------------------
CONTAINMENT_ROWS=$(printf '%s\n' \
  "web	web/dist	accept" \
  "web	web	refuse" \
  "web	web/	refuse" \
  "web	./web	refuse" \
  "web	web2/dist	refuse" \
  "docs-site	web/dist	refuse" \
  "web	.	refuse" \
  ".	dist	accept" \
  "./	./dist/	accept" \
  ".	./	refuse" \
  "web	web/../secret	refuse")

# Reports which COPY disagreed, and on which row. A shared table whose failure says only
# "row 4 failed" reintroduces the two-sources problem one level up.
containment_fail() {   # $1 = copy · $2 = src · $3 = dist · $4 = wanted · $5 = got · $6 = log
  echo "FAIL: the $1 copy of the dist-under-src rule disagrees with the shared table."
  echo "      src='$2' dist='$3' — table says $4, this copy said $5"
  echo "      The OTHER copy is in the same template; #151 is the incident where both carried"
  echo "      the same hole and the review, not the suite, was what caught it."
  cat "$6"
  exit 1
}

# $1 = repo path · $2 = src · $3 = dist · $4 = raw config contents. Generalises mk_config_repo so
# src/dist are parameters instead of hardcoded web / web/dist.
mk_config_repo_for() {
  local root="$1" s="$2" d="$3" cfg_text="$4"
  # Strip the './' and trailing '/' spellings only when building the TREE — the config file
  # keeps the row's raw spelling, which is exactly what is under test.
  local sdir="${s#./}"; sdir="${sdir%/}"; [ -n "$sdir" ] || sdir=.
  local ddir="${d#./}"; ddir="${ddir%/}"; [ -n "$ddir" ] || ddir=.
  mkdir -p "$root/$sdir" "$root/$ddir/assets"
  git init -q "$root"
  printf '{ "name": "app", "private": true }\n' > "$root/$sdir/package.json"
  printf 'console.log(1)\n' > "$root/$ddir/assets/index-NNNNNNNN.js"
  mkdir -p "$root/$(dirname "$CONFIG")"
  printf '%s\n' "$cfg_text" > "$root/$CONFIG"
  git -C "$root" add -A
  git_commit_all "$root" "a scratch repo shaped for one containment row"
}

# The SAME './'-strip and trailing-'/'-strip the config step itself applies before comparing
# (templates/ci-dotnet.yml lines ~464-481), so an ACCEPT row's expected output can be computed
# from the row rather than hand-retyped per row.
containment_normalise() {   # $1 = raw src or dist -> echoes the normalised spelling
  local v="$1"
  v="${v#./}"
  while [ "$v" != "${v%/}" ]; do v="${v%/}"; done
  printf '%s' "$v"
}

row_n=0
while IFS="$(printf '\t')" read -r r_src r_dist r_want; do
  [ -n "$r_src" ] || continue
  row_n=$((row_n + 1))
  R="$scratch/containment-cfg-$row_n"
  mk_config_repo_for "$R" "$r_src" "$r_dist" "{ \"src\": \"$r_src\", \"dist\": \"$r_dist\" }"
  run_config "$R"
  got=accept; [ "$config_rc" -eq 0 ] || got=refuse
  [ "$got" = "$r_want" ] || containment_fail "config step" "$r_src" "$r_dist" \
      "$r_want" "$got" "$scratch/out-config.txt"
  if [ "$r_want" = refuse ]; then
    if [ -s "$R/gh-output.txt" ]; then
      echo "FAIL: the config step refused src='$r_src' dist='$r_dist' yet still published outputs:"
      cat "$R/gh-output.txt"; exit 1
    fi
  else
    # An accept row must publish the NORMALISED pair — the assertion the old hand-written
    # root-project loop made (`grep -qxF 'src=.'` / `'dist=dist'`), and the one a review of this
    # table caught missing: a config that ACCEPTS is not yet proven to publish the right thing,
    # only to publish SOMETHING. Two differently-spelled accept rows for the same tree (raw,
    # './'-prefixed, trailing-'/') must converge on the identical pair, or the rebuild and the
    # guard would run against two different paths for what is supposed to be one tree.
    exp_src=$(containment_normalise "$r_src"); [ -n "$exp_src" ] || exp_src=.
    exp_dist=$(containment_normalise "$r_dist")
    grep -qxF "src=$exp_src" "$R/gh-output.txt" || {
      echo "FAIL: src='$r_src' dist='$r_dist' did not publish the normalised src=$exp_src :"
      cat "$R/gh-output.txt"; exit 1; }
    grep -qxF "dist=$exp_dist" "$R/gh-output.txt" || {
      echo "FAIL: src='$r_src' dist='$r_dist' did not publish the normalised dist=$exp_dist :"
      cat "$R/gh-output.txt"; exit 1; }
  fi
done <<EOF
$CONTAINMENT_ROWS
EOF
echo "  [1c] every containment case in the shared table, against the config step"

# The one refusal in the config step with no executable witness: `command -v jq` at
# templates/ci-dotnet.yml:433. It is diagnostic quality, not a gate — it stops a jq-less runner
# from blaming a perfectly valid JSON file — but "verified by reading" is the state every other
# branch of this step left behind, and it is the state #151's two identical holes came from.
NOJQ="$scratch/nojq-bin"
mkdir -p "$NOJQ"
# Symlink every binary the body actually needs, and only those. Deleting PATH entries instead
# would take `git` with `jq` on most machines, and the step would refuse for the wrong reason.
for b in git bash sh env; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$NOJQ/$b"
done
CJQ="$scratch/config-no-jq"
mk_config_repo "$CJQ" '{ "src": "web", "dist": "web/dist" }'
set +e
( cd "$CJQ" && PATH="$NOJQ" GITHUB_OUTPUT="$CJQ/gh-output.txt" BUNDLE_GATE_CONFIG="$CONFIG" \
    bash "$scratch/config.sh" ) > "$scratch/out-nojq.txt" 2>&1
jq_rc=$?
set -e
command -v jq > /dev/null 2>&1 || { echo "SKIP: jq is absent from this machine's PATH too,"; \
  echo "      so the shim proves nothing here — CI has jq and does run this."; }
if [ "$jq_rc" -eq 0 ]; then
  echo "FAIL: the config step armed the gate on a runner with no jq:"
  cat "$scratch/out-nojq.txt"; exit 1
fi
grep -qF "$CONFIG" "$scratch/out-nojq.txt" || {
  echo "FAIL: refused for want of jq but never named $CONFIG:"; cat "$scratch/out-nojq.txt"; exit 1; }
grep -q 'jq' "$scratch/out-nojq.txt" || {
  echo "FAIL: refused without saying jq was the missing piece, so the reader would go and edit"
  echo "      a perfectly valid JSON file:"; cat "$scratch/out-nojq.txt"; exit 1; }
if [ -s "$CJQ/gh-output.txt" ]; then
  echo "FAIL: refused for want of jq yet still published outputs:"
  cat "$CJQ/gh-output.txt"; exit 1
fi
echo "  [1c] a runner without jq is refused, and told it is the runner and not the file"

# ---------------------------------------------------------------------------
# 1e. The shipped example is the file an adopter copies, so it must be a file the config step
#     would accept. A doc page going stale is visible to whoever reads it; a malformed example
#     is not — it fails in the adopter's CI, in a repo this kit does not have.
# ---------------------------------------------------------------------------
EXAMPLE="$KIT/templates/bundle-gate.json.example"
[ -f "$EXAMPLE" ] || { echo "FAIL: $EXAMPLE is not shipped"; exit 1; }
python3 - "$EXAMPLE" <<'PY'
import json, sys

def die(msg):
    # NOT `assert`: under python3 -O every assert in this block would vanish while the success
    # line below still printed, reporting a check that never happened — the same false-green
    # trap tests/xunit-v3/test.sh already guards against.
    sys.exit(f"FAIL: {msg}")

cfg = json.load(open(sys.argv[1], encoding="utf-8"))
if not isinstance(cfg, dict):
    die(f"the example must be a JSON object, got {type(cfg).__name__}")
for k in ("src", "dist"):
    if not (isinstance(cfg.get(k), str) and cfg[k]):
        die(f"the example has no usable {k!r}: {cfg!r}")
# The one correlation the config step enforces, restated where the example lives: an example
# the shipped validator would refuse is worse than no example.
if cfg["dist"] == cfg["src"]:
    die(f"the example has dist == src: {cfg!r}")
if not cfg["dist"].startswith(cfg["src"] + "/"):
    die(f"the example's dist is not under src: {cfg!r}")
PY
echo "  [1e] the shipped example config is a config the gate would accept"

# ---------------------------------------------------------------------------
# 1d. A repo that never wanted the gate and one that LOST its config must stop being the same
#     observable run.
#
#     Moving the switch into the repository (1c) makes losing it a DIFF, which is most of the fix.
#     It is not all of it: the deletion still lands green, because the whole block simply turns
#     off — the "looks tended, measures nothing" shape one level up, which is what #96 is about.
#
#     So a fifth step runs on the COMPLEMENT of the gate: no config file. It reports a repo that
#     carries a committed bundle consumed by a .NET project and yet has no config — the exact
#     1-in-193 shape from #32 — and says nothing at all on the other 192. It WARNS rather than
#     fails, and that is deliberate: a detection heuristic that can be wrong must not be able to
#     red a repo that never opted in, which is the reason #70's brainstorm rejected auto-arming
#     (approach C) outright. Reporting is the part of C that is safe to keep.
#
#     Both halves are asserted: it speaks when it should, and — the one that keeps it deletable —
#     it is silent on a repo with no bundle at all.
# ---------------------------------------------------------------------------
python3 - "$TEMPLATE" "$CONFIG" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
config = sys.argv[2]
steps = doc["jobs"]["test"]["steps"]
disarmed = [s for s in steps
            if f"hashFiles('{config}')" in str(s.get("if", ""))
            and ("== ''" in str(s["if"]) or '== ""' in str(s["if"]))]
assert len(disarmed) == 1, (
    f"expected exactly one step running on the ABSENCE of {config} — the one that tells a repo "
    f"that lost its config from a repo that never wanted one apart; got {len(disarmed)}")
det = disarmed[0]
assert "always()" not in str(det["if"]), f"an always() gate would run it on armed repos too: {det['if']}"
assert str((det.get("env") or {}).get("BUNDLE_GATE_CONFIG", "")) == config, (
    f"the detection step names a different config than the one it is gated on: {det.get('env')}")
# It must not be able to fail the job on its own terms: `continue-on-error` would be the wrong
# spelling of that (it hides real failures too), so what is asserted is that the body never exits
# non-zero — driven below, not declared here.
assert "continue-on-error" not in det, (
    "the detection step must be harmless because its body is, not because failures are swallowed: "
    "continue-on-error would also swallow a genuine bug in it")
PY
echo "  [1d] one step runs on the absence of the config, and cannot be armed at the same time"

step_named "Détection — un bundle front committé sans configuration de garde" > "$scratch/detect.sh"
[ -s "$scratch/detect.sh" ] || { echo "FAIL: the detection step has an empty run: body"; exit 1; }
bash -n "$scratch/detect.sh" || { echo "FAIL: the detection body is not valid bash"; exit 1; }

# The shape measured on Ninjadog (2026-07-26): a csproj that embeds a SIBLING front-end bundle,
# committed, with no MSBuild target calling npm. Written with the csproj's own separator, because
# that is how MSBuild spells it and a detector that only looks for '/' finds nothing on the one
# repo it exists for.
mk_consumer_repo() {   # $1 = root · $2 = "consumed" | "orphan" | "bare"
  local root="$1" kind="$2"
  mkdir -p "$root/src/tools/App"
  git init -q "$root"
  if [ "$kind" != bare ]; then
    mkdir -p "$root/src/tools/App/WebUI/dist/assets"
    printf '{ "name": "webui", "private": true }\n' > "$root/src/tools/App/WebUI/package.json"
    printf 'console.log(1)\n' > "$root/src/tools/App/WebUI/dist/assets/index-LLLLLLLL.js"
  fi
  {
    printf '<Project Sdk="Microsoft.NET.Sdk">\n  <ItemGroup>\n'
    if [ "$kind" = consumed ]; then
      printf '    <EmbeddedResource Include="WebUI\\dist\\**" />\n'
    fi
    printf '  </ItemGroup>\n</Project>\n'
  } > "$root/src/tools/App/App.csproj"
  git -C "$root" add -A
  git -C "$root" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
      commit -qm "a repo shaped like the one consumer"
}

detect_rc=0
run_detect() {   # $1 = repo root
  set +e
  ( cd "$1" && BUNDLE_GATE_CONFIG="$CONFIG" bash "$scratch/detect.sh" ) \
    > "$scratch/out-detect.txt" 2>&1
  detect_rc=$?
  set -e
}

DCONSUMED="$scratch/detect-consumed"
mk_consumer_repo "$DCONSUMED" consumed
run_detect "$DCONSUMED"
if [ "$detect_rc" -ne 0 ]; then
  echo "FAIL: the detection step failed the job. It reports, it does not gate — a heuristic that"
  echo "      can red a repo that never opted in is the auto-arming design #70 rejected:"
  cat "$scratch/out-detect.txt"; exit 1
fi
grep -q '::warning::' "$scratch/out-detect.txt" || {
  echo "FAIL: a committed bundle consumed by a csproj, and no gate config, passed in SILENCE."
  echo "      That repo is indistinguishable from one that never wanted the gate — the whole"
  echo "      point of #96:"; cat "$scratch/out-detect.txt"; exit 1; }
grep -qF 'WebUI/dist' "$scratch/out-detect.txt" || {
  echo "FAIL: warned but never named the bundle it found:"; cat "$scratch/out-detect.txt"; exit 1; }
grep -qF "$CONFIG" "$scratch/out-detect.txt" || {
  echo "FAIL: warned but never named the file that would fix it:"
  cat "$scratch/out-detect.txt"; exit 1; }
echo "  [1d] a committed bundle consumed by a project, with no config, is reported"

# The other side, and the one that decides whether this step is shippable at all: 192 of 193 repos
# must see nothing. A detector that cries on them teaches its own dismissal, which is strictly
# worse than absent — the measurement behind the whole opt-in design (#32).
for kind in bare orphan; do
  DQ="$scratch/detect-$kind"
  mk_consumer_repo "$DQ" "$kind"
  run_detect "$DQ"
  if [ "$detect_rc" -ne 0 ]; then
    echo "FAIL: the detection step failed on a '$kind' repo:"; cat "$scratch/out-detect.txt"; exit 1
  fi
  if grep -qE '::(warning|error)::' "$scratch/out-detect.txt"; then
    echo "FAIL: the detection step annotated a '$kind' repo — one with no committed bundle"
    echo "      consumed by any project. It must leave those 192 completely untouched:"
    cat "$scratch/out-detect.txt"; exit 1
  fi
done
echo "  [1d] silent on a repo with no bundle, and on one whose bundle no project consumes"

# The third way to be wrong, and the one a reader would not predict: git's `*package.json`
# pathspec is a glob over the WHOLE path, so it also matches `mypackage.json`. Read as "a
# front-end project at the repository root", that sends the detector hunting for a root `dist/`
# with nothing to do with it — and warns a repo that has no bundle at all.
DECOY="$scratch/detect-decoy"
mkdir -p "$DECOY/dist"
git init -q "$DECOY"
printf '{ "name": "not-a-project" }\n' > "$DECOY/mypackage.json"
printf 'x\n' > "$DECOY/dist/thing.txt"
printf '<Project Sdk="Microsoft.NET.Sdk">\n  <ItemGroup>\n    <Content Include="dist\\**" />\n  </ItemGroup>\n</Project>\n' \
  > "$DECOY/App.csproj"
git -C "$DECOY" add -A
git -C "$DECOY" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm "a decoy"
run_detect "$DECOY"
if [ "$detect_rc" -ne 0 ]; then
  echo "FAIL: the detection step failed on the decoy repo:"; cat "$scratch/out-detect.txt"; exit 1
fi
if grep -qE '::(warning|error)::' "$scratch/out-detect.txt"; then
  echo "FAIL: 'mypackage.json' was read as a front-end project at the repository root, so the"
  echo "      detector warned a repo that never had a bundle:"
  cat "$scratch/out-detect.txt"; exit 1
fi
echo "  [1d] 'mypackage.json' is not a project — git's *package.json glob is not the filter"

# The fourth way, and one the node_modules filter introduced itself: `*/node_modules/*` requires a
# `/` BEFORE node_modules, so a vendored `node_modules/` at the repository ROOT slipped past it. A
# vendored root node_modules is a real shape in the legacy .NET repos this template targets, and a
# csproj that embeds one of its packages' `dist/` was enough to have the detector report a
# dependency's bundle as this repository's own.
DNM="$scratch/detect-root-node-modules"
mkdir -p "$DNM/node_modules/pkg/dist"
git init -q "$DNM"
printf '{ "name": "pkg" }\n' > "$DNM/node_modules/pkg/package.json"
printf 'console.log(1)\n' > "$DNM/node_modules/pkg/dist/bundle.js"
printf '<Project Sdk="Microsoft.NET.Sdk">\n  <ItemGroup>\n    <Content Include="node_modules\\pkg\\dist\\**" />\n  </ItemGroup>\n</Project>\n' \
  > "$DNM/App.csproj"
# `-f`: a global core.excludesFile ignoring node_modules is common on a developer machine, and
# without it this repo would commit nothing under node_modules — the suite would then pass here
# for the wrong reason, on every machine that has such a file and no other.
git -C "$DNM" add -A -f
git -C "$DNM" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
    commit -qm "a vendored node_modules at the repository root"
run_detect "$DNM"
if [ "$detect_rc" -ne 0 ]; then
  echo "FAIL: the detection step failed on a repo with a vendored root node_modules:"
  cat "$scratch/out-detect.txt"; exit 1
fi
if grep -qE '::(warning|error)::' "$scratch/out-detect.txt"; then
  echo "FAIL: a dependency's own bundle under a ROOT node_modules/ was reported as this repo's"
  echo "      committed front-end bundle — '*/node_modules/*' needs a slash before it, so the"
  echo "      root-level case needs its own alternative:"
  cat "$scratch/out-detect.txt"; exit 1
fi
echo "  [1d] a vendored node_modules at the repository root is not a front-end project"

# ---------------------------------------------------------------------------
# 2. The content-hash rename: the old asset disappears and a differently-named one
#    appears UNTRACKED. `git diff` is not blind here — a deleted TRACKED file is a
#    diff — but it reports only the disappearance and never names the replacement,
#    so nothing diff-based can tell "the build dropped a file" from "the build
#    produced a different bundle". The guard must fail, and must name the new file.
# ---------------------------------------------------------------------------
D="$scratch/renamed"
mk_repo "$D" "index-AAAAAAAA.js"
rm "$D/web/dist/assets/index-AAAAAAAA.js"
printf 'console.log(2)\n' > "$D/web/dist/assets/index-BBBBBBBB.js"

# Herestring, not a pipe into `grep -q`: `git diff` can still be writing when the match closes the
# read end, and under pipefail that SIGPIPE becomes this check's verdict (#391).
diffstat=$(git -C "$D" diff --stat -- web/dist)
if grep -q 'index-BBBBBBBB' <<<"$diffstat"; then
  echo "FAIL: git diff named the untracked replacement; the template's rationale is stale"
  exit 1
fi
set +e
( cd "$D" && BUNDLE_SRC=web BUNDLE_DIST=web/dist bash "$scratch/guard.sh" ) > "$scratch/out-renamed.txt" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: the guard passed on a renamed bundle — it would ship the stale one:"
  cat "$scratch/out-renamed.txt"; exit 1
fi
grep -q 'index-BBBBBBBB' "$scratch/out-renamed.txt" || {
  echo "FAIL: the guard failed but never named the replacement — git diff's exact weakness:"
  cat "$scratch/out-renamed.txt"; exit 1; }
echo "  [2] fails on a content-hash rename, and names the replacement git diff never shows"

# ---------------------------------------------------------------------------
# 3. The actual blind spot: a rebuild that only ADDS. A new code-split chunk, or a
#    newly imported asset, while every existing file keeps its name and content.
#    Nothing tracked changed, so `git diff` reports the tree CLEAN — a diff-based
#    gate goes green on a bundle that is genuinely out of date. Only --porcelain,
#    which covers untracked files, sees it.
#
#    This is the case that makes --porcelain mandatory rather than merely tidier,
#    so it is asserted separately from the rename above.
# ---------------------------------------------------------------------------
A="$scratch/added-only"
mk_repo "$A" "index-CCCCCCCC.js"
printf 'console.log(3)\n' > "$A/web/dist/assets/chunk-DDDDDDDD.js"

git -C "$A" diff --quiet -- web/dist || {
  echo "FAIL: the premise no longer holds — git diff saw a pure untracked addition."
  echo "      If git changed, the porcelain rationale in the template needs rewriting."
  exit 1; }
set +e
( cd "$A" && BUNDLE_SRC=web BUNDLE_DIST=web/dist bash "$scratch/guard.sh" ) > "$scratch/out-added.txt" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: the guard passed on a bundle with an untracked new chunk — this is exactly"
  echo "      the drift git diff cannot see, and the reason --porcelain is required:"
  cat "$scratch/out-added.txt"; exit 1
fi
echo "  [3] fails on a pure untracked addition — the drift git diff reports as clean"

# ---------------------------------------------------------------------------
# 3b. The same drift, in the shape real repos actually have: `dist/` listed in
#     .gitignore and force-added. That is the NORMAL way a built bundle gets
#     committed — you ignore the output directory, then `git add -f` the artefact.
#
#     A new chunk is then not merely untracked but IGNORED, and plain
#     `--porcelain` omits ignored files: it prints nothing, both preconditions
#     pass, and the guard reports "à jour" on a stale bundle. Measured before this
#     case was written — `git check-ignore` confirms the file is ignored, and only
#     `--porcelain --ignored` surfaces it.
#
#     This is the one that would have shipped a green gate over a false remediation.
# ---------------------------------------------------------------------------
I="$scratch/gitignored"
mkdir -p "$I/web/dist/assets"
git init -q "$I"
printf 'dist/\n' > "$I/.gitignore"
printf 'console.log(1)\n' > "$I/web/dist/assets/index-FFFFFFFF.js"
git -C "$I" add -f web/dist .gitignore
git -C "$I" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
    commit -qm "commit an ignored-but-force-added bundle"
printf 'console.log(9)\n' > "$I/web/dist/assets/chunk-GGGGGGGG.js"

git -C "$I" check-ignore -q web/dist/assets/chunk-GGGGGGGG.js || {
  echo "FAIL: the premise no longer holds — the new chunk is not ignored here."; exit 1; }
set +e
( cd "$I" && BUNDLE_SRC=web BUNDLE_DIST=web/dist bash "$scratch/guard.sh" ) > "$scratch/out-ignored.txt" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: the guard passed on a stale bundle whose new chunk is GITIGNORED."
  echo "      Plain --porcelain omits ignored files, so this is a green gate over a"
  echo "      false remediation — the exact outcome the step exists to prevent:"
  cat "$scratch/out-ignored.txt"
  exit 1
fi
grep -q 'chunk-GGGGGGGG' "$scratch/out-ignored.txt" || {
  echo "FAIL: failed, but never named the ignored file:"; cat "$scratch/out-ignored.txt"; exit 1; }
echo "  [3b] fails when the bundle dir is gitignored and force-added — the real-world shape"

# ---------------------------------------------------------------------------
# 4. A matching bundle passes. Without this, "always red" would score as a pass.
# ---------------------------------------------------------------------------
M="$scratch/matching"
mk_repo "$M" "index-CCCCCCCC.js"
set +e
( cd "$M" && BUNDLE_SRC=web BUNDLE_DIST=web/dist bash "$scratch/guard.sh" ) > "$scratch/out-match.txt" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "FAIL: the guard failed on a bundle that matches its sources:"
  cat "$scratch/out-match.txt"
  exit 1
fi
echo "  [4] passes on a bundle that matches its sources"

# ---------------------------------------------------------------------------
# 5b. A MISCONFIGURED guard must fail loudly, never pass quietly.
#
#     `git status --porcelain -- does/not/exist` exits 0 with EMPTY output. So a consumer who
#     enables the block but leaves the placeholder path — or renames the bundle directory later —
#     gets a step that is green on every run while checking nothing at all. That is the exact
#     "looks tended, measures nothing" failure this whole issue is about, reproduced inside its
#     own fix, and it is invisible precisely because green is the expected colour.
#
#     Measured, not assumed: the bare `git status` behaviour above was probed before this guard
#     clause was written.
# ---------------------------------------------------------------------------
for bad in "" "does/not/exist"; do
  B="$scratch/misconfigured-$(echo "$bad" | tr -c 'a-z' '-')"
  mk_repo "$B" "index-EEEEEEEE.js"
  set +e
  ( cd "$B" && BUNDLE_SRC="$bad" BUNDLE_DIST="$bad" bash "$scratch/guard.sh" ) > "$scratch/out-bad.txt" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: the guard PASSED with BUNDLE_DIST='$bad' — it would be green forever while"
    echo "      measuring nothing, which is the failure this issue exists to prevent:"
    cat "$scratch/out-bad.txt"
    exit 1
  fi
done
echo "  [5b] refuses a misconfigured path instead of passing quietly on nothing"

# ---------------------------------------------------------------------------
# 5c. The third misconfiguration: the directory EXISTS but git tracks nothing in it.
#
#     Both cases above short-circuit on the `-z` / `-d` clauses, so the guard's
#     `git ls-files --error-unmatch` precondition was never actually executed by the
#     suite whose whole purpose is that this block cannot rot untested. This drives it.
#
#     The shape is real: a bundle directory present on the runner (built, or left by a
#     cache restore) that nobody ever committed. The guard must refuse rather than
#     compare a committed bundle that does not exist.
# ---------------------------------------------------------------------------
U="$scratch/untracked-dist"
mk_repo "$U" "index-HHHHHHHH.js"
mkdir -p "$U/other/dist"
printf 'x\n' > "$U/other/dist/nothing-committed.js"
set +e
( cd "$U" && BUNDLE_SRC=other BUNDLE_DIST=other/dist bash "$scratch/guard.sh" ) > "$scratch/out-untracked.txt" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: the guard accepted a directory git tracks nothing in — it would compare a"
  echo "      committed bundle that does not exist, and stay green forever:"
  cat "$scratch/out-untracked.txt"
  exit 1
fi
echo "  [5c] refuses a directory that exists but holds no tracked file"

# ---------------------------------------------------------------------------
# 5d. The two variables must describe the SAME tree — the guard's OWN copy of the containment
#     rule, driven against the SAME `CONTAINMENT_ROWS` table as 1c.
#
#     Splitting the configuration in two created a way for the gate to certify a bundle nothing
#     rebuilt: point BUNDLE_SRC at one project and BUNDLE_DIST at another's output, and npm
#     regenerates the first while the guard inspects the second, finds it unchanged, and reports
#     "à jour" on a stale bundle — the false remediation this whole step exists to prevent,
#     produced by the step. Cheap to get wrong, too: two settings edited months apart.
#
#     Fed the RAW spelling, not the normalised pair the config step would publish: the whole
#     argument for keeping this second copy is that it must hold when the values arrive from
#     somewhere else (a matrix, a second config path, a hand-edit in an adopter's repo — #96's own
#     discussion). Verified by executing the shipped guard body, exactly as 1c drives the config
#     step — not asserted from reading.
#
#     #285 fixed two rows that used to disagree between the copies when fed that raw spelling,
#     because the guard's own check — unlike the config step's (which strips a leading './' and a
#     trailing '/' before comparing, lines ~464-481 of the template) — never normalised
#     BUNDLE_SRC/BUNDLE_DIST at all. The guard body now carries the same two-line normalisation, so
#     every row of the shared table drives straight off `$r_want` with no per-copy exclusion or
#     override — `CONTAINMENT_ROWS` means exactly what its own comment claims: same row, same
#     verdict, both copies.
# ---------------------------------------------------------------------------

# One fixture, reused for every row: `guard.sh` only READS the tree (`git status`), never
# mutates it, so there is nothing a later row could see left over from an earlier one — the
# per-row rebuild the config-step loop needs (each row's tracked package.json/bundle differs)
# does not apply here, since only the BUNDLE_SRC/BUNDLE_DIST env vars change per row.
G="$scratch/containment-guard"
mk_repo "$G" "index-GGGGGGGG.js"
mkdir -p "$G/docs-site"; : > "$G/docs-site/package.json"
# A tracked root-level "dist" too, for the src='.'/'./ ' rows — mk_repo alone only ships web/dist.
mkdir -p "$G/dist/assets"
printf 'console.log(1)\n' > "$G/dist/assets/index-GGGGGGGG.js"
printf '<script src="/assets/index-GGGGGGGG.js"></script>\n' > "$G/dist/index.html"
git -C "$G" add -A
git_commit_all "$G" "a root-level dist alongside web/dist, for every containment row"

# Same table, same loop shape as 1c, same $r_want compared directly — no per-copy exclusion or
# override. #285 normalised the guard body to match the config step, so every row now gives the
# same verdict from both copies with nothing pulled out here.
while IFS="$(printf '\t')" read -r r_src r_dist r_want; do
  [ -n "$r_src" ] || continue
  set +e
  ( cd "$G" && BUNDLE_SRC="$r_src" BUNDLE_DIST="$r_dist" bash "$scratch/guard.sh" ) \
    > "$scratch/out-guard-row.txt" 2>&1
  rc=$?
  set -e
  got=accept; [ "$rc" -eq 0 ] || got=refuse
  [ "$got" = "$r_want" ] || containment_fail "guard body" "$r_src" "$r_dist" \
      "$r_want" "$got" "$scratch/out-guard-row.txt"
  # A refusal must be ACTIONABLE, not merely non-zero: the reader needs to know which variable
  # to fix, with the RIGHT value attached to it. A bare `grep -q "BUNDLE_SRC"` (this check's
  # predecessor) passes identically whether the message reads `BUNDLE_SRC ('web')` or mislabels
  # it `BUNDLE_DIST ('web')` while the literal word "BUNDLE_SRC" still shows up unattached
  # elsewhere in the same refusal — #293 shipped exactly that swap, caught only by code review,
  # not by this suite (#302). So assert the labelled fragment, not the bare word, for every row
  # whose refusal actually pairs BUNDLE_SRC with a value: the "not under src", ".." traversal and
  # "dist empty" refusals all print `BUNDLE_SRC ('<value>')` verbatim. The one shape that can't
  # carry that fragment is the equality refusal (normalised src == normalised dist): only ONE
  # path value exists there, printed once, with no second value nearby to confuse it with — for
  # that shape the bare substring is the whole promise the message makes.
  if [ "$r_want" = refuse ]; then
    exp_src=$(containment_normalise "$r_src"); [ -n "$exp_src" ] || exp_src=.
    exp_dist=$(containment_normalise "$r_dist")
    if [ "$exp_dist" = "$exp_src" ]; then
      grep -q "BUNDLE_SRC" "$scratch/out-guard-row.txt" || {
        echo "FAIL: src='$r_src' dist='$r_dist' — the guard refused but never named BUNDLE_SRC:"
        cat "$scratch/out-guard-row.txt"; exit 1; }
    else
      grep -qF "BUNDLE_SRC ('$exp_src')" "$scratch/out-guard-row.txt" || {
        echo "FAIL: src='$r_src' dist='$r_dist' — the guard refused but did not name BUNDLE_SRC"
        echo "      ('$exp_src') exactly — a bare 'BUNDLE_SRC' substring is not enough here:"
        cat "$scratch/out-guard-row.txt"; exit 1; }
    fi
  fi
done <<EOF
$CONTAINMENT_ROWS
EOF
echo "  [5d] every containment case in the shared table, against the guard body"

# ---------------------------------------------------------------------------
# 5. As shipped the four steps are PRESENT but INERT — and inert by the one mechanism GitHub
#    actually evaluates, not by being text.
#
#    The measurement that forces this: of 193 local .NET repos, 3 commit build output and 1 has it
#    consumed by the build. A step that RAN by default on the other 192 would be deleted or
#    `continue-on-error`'d, which teaches a team to ignore a red step — worse than absent.
#
#    So "inert" is checked as: every one of the four carries a condition that is false when the
#    config file is absent, and none of them is `if: always()`-style unconditional. GitHub's
#    expression reference is what makes `hashFiles` usable here — "If the `path` pattern does not
#    match any files, this returns an empty string" — so the 192 get a false condition, never an
#    error. The same page is why the path is written repo-relative: "The `path` is relative to the
#    `GITHUB_WORKSPACE` directory and can only include files inside of the `GITHUB_WORKSPACE`."
# ---------------------------------------------------------------------------
python3 - "$TEMPLATE" "$CONFIG" <<'PY'
import sys, yaml
raw = open(sys.argv[1], encoding="utf-8").read()
config = sys.argv[2]
doc = yaml.safe_load(raw)
steps = doc["jobs"]["test"]["steps"]
def cmp_empty(cond, op):
    return f"{op} ''" in cond or f'{op} ""' in cond

# Every step the gate owns, armed (four) or disarmed (the detection one). Each must compare the
# hash to the empty string EXPLICITLY: `if: ${{ hashFiles(...) }}` would also work in GitHub for
# the armed half, but `!= ''` says the intent out loud, cannot be misread as a boolean flag, and
# leaves the disarmed half with a spelling — `== ''` — that has no truthy equivalent at all.
own = [i for i, s in enumerate(steps) if f"hashFiles('{config}')" in str(s.get("if", ""))]
armed = [i for i in own if cmp_empty(str(steps[i]["if"]), "!=")]
assert len(armed) == 4, f"expected exactly 4 bundle steps ARMED by {config}, got {len(armed)}"
assert len(own) == len(armed) + 1, (
    f"expected the four armed steps plus exactly one running on the config's absence, "
    f"got {len(own)} steps keyed on {config}")
for i in own:
    cond = str(steps[i]["if"])
    assert cmp_empty(cond, "!=") or cmp_empty(cond, "=="), \
        f"the gate must compare hashFiles to empty, so its state is never a guess: {cond}"
    assert "always()" not in cond, f"an always() gate would defeat the opt-in entirely: {cond}"
# Nothing OUTSIDE those steps may depend on the config or on the paths it publishes — a repo that
# never commits it must get exactly the run it gets today. Checked against the whole document, not
# just `steps`: the workflow already keeps `SOLUTION` in a top-level `env:`, and `jobs.test.env`,
# `defaults.run` and a second job are all places a reference could hide from a steps-only scan.
cfg_id = next(s for s in steps if s.get("name") == "Configuration de la garde bundle")["id"]
# `own` (above) is keyed off the `if:` naming the config rather than off step names, so a renamed
# step cannot slip out of this check — and the detection step, gated on the same config by its
# ABSENCE, is excluded here for the same reason the four armed ones are.
rest = dict(doc)
rest["jobs"] = {k: (dict(v, steps=[s for i, s in enumerate(v["steps"]) if i not in own])
                    if k == "test" else v)
               for k, v in doc["jobs"].items()}
leaked = [ln for ln in yaml.safe_dump(rest, allow_unicode=True).splitlines()
          if config in ln or f"steps.{cfg_id}" in ln
          or "BUNDLE_DIST" in ln or "BUNDLE_SRC" in ln]
assert not leaked, f"the bundle gate is referenced outside its own steps: {leaked}"
PY
echo "  [5] shipped inert — four gated steps, and nothing outside them references the config"

# ---------------------------------------------------------------------------
# 6. The coverage artifact is uploaded on the FAILURE path too (issue #74).
#
#    Every step in this job runs under the implicit `success()` condition, so the upload step is
#    skipped the moment an earlier step fails. `Tests + couverture` runs under `set -euo pipefail`,
#    so a test host that exits non-zero ends the job there — and the artifact that would carry the
#    diagnostic is never produced. The artifact therefore existed only for runs where nothing went
#    wrong, which is precisely when nobody needs it.
#
#    Asserted on the SHIPPED template (the artifact step is active, not part of the opt-in block).
# ---------------------------------------------------------------------------
python3 - "$TEMPLATE" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = doc["jobs"]["test"]["steps"]
want = "Publier la couverture en artefact de build"
step = next((s for s in steps if s.get("name") == want), None)
assert step is not None, f"no step named {want!r}: {[s.get('name') for s in steps]}"

cond = step.get("if")
assert cond is not None, (
    "the coverage artifact step carries no `if:`, so GitHub applies the implicit success() and "
    "skips it whenever an earlier step failed. The one run whose artifact matters — the failed "
    "one — therefore uploads nothing (issue #74)."
)
# A WHITELIST, not a blacklist. This step has to run on BOTH paths, and the two ways to get that
# wrong are symmetric: `success()` (implicit or written) drops the failed run — the hole #74 is
# about — while `failure()` drops every GREEN run, which is where the dashboard's coverage
# actually comes from. An earlier version of this assertion only rejected the first, so editing
# the template to `if: failure()` passed the whole suite while silently ending coverage
# publication on success. Naming the accepted spellings makes a future change deliberate.
ALLOWED = {"always()", "${{always()}}", "!cancelled()", "${{!cancelled()}}"}
normalised = str(cond).replace(" ", "")
assert normalised in ALLOWED, (
    f"the artifact step's condition is `if: {cond}`, which is not one of the conditions known to "
    f"run on BOTH the success and the failure path: {sorted(ALLOWED)}.\n"
    "  `success()` (or no `if:` at all) skips the failed run — that is issue #74.\n"
    "  `failure()` skips every green run — that is the same defect mirrored, and it would stop\n"
    "  publishing the coverage the dashboard is built from.\n"
    "  If you mean a new spelling, add it here deliberately rather than widening the test."
)
PY
echo "  [6] the coverage artifact step runs on both the success and the failure path"

# ---------------------------------------------------------------------------
# 7. The artifact patterns cover the log's FALLBACK location (issue #74).
#
#    MTP writes the log that explains a failure next to its results. `--results-directory` is what
#    puts that under coverage/ — but it is passed in the SAME argument list as `--coverage`, so a
#    project without Microsoft.Testing.Extensions.CodeCoverage has BOTH refused, and the log falls
#    back under `<proj>/bin/<config>/<tfm>/TestResults/`. Measured in #31/#60. The console names
#    that file and nothing else, so if the patterns miss it the failure is undiagnosable remotely.
#
#    The patterns are EXECUTED against representative paths, not eyeballed: a `path:` list is a
#    glob, and "it looks like it covers that" is how #17 shipped a pattern that matched nothing.
#    The translator is itself self-tested first — a wrong one would make every assertion below
#    vacuous, and the failure would be invisible because the expected colour is green.
# ---------------------------------------------------------------------------
python3 - "$TEMPLATE" <<'PY'
import re, sys, yaml

def glob_to_regex(pattern):
    """Translate an @actions/glob pattern: `**` spans zero or more path segments, `*` stays
    inside one segment. Python's fnmatch is unusable here — its `*` crosses `/`, which would
    make `coverage/*.log` appear to match a nested path and turn this whole section green."""
    out, i, n = [], 0, len(pattern)
    while i < n:
        if pattern.startswith("**/", i):
            out.append("(?:[^/]*/)*")          # zero or more segments
            i += 3
        elif pattern.startswith("**", i) and i + 2 == n:
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")

# --- the translator must be right before it can judge anything ---------------
for pat, path, expected in [
    ("coverage/**/*.log", "coverage/a.log", True),            # ** matches ZERO segments
    ("coverage/**/*.log", "coverage/x/y/a.log", True),        # ...and more than one
    ("coverage/**/*.log", "other/a.log", False),
    ("coverage/*.log", "coverage/a/b.log", False),            # * must not cross '/'
    ("**/TestResults/*.log", "a/b/TestResults/c.log", True),
    ("**/TestResults/*.log", "a/b/TestResults/c/d.log", False),
]:
    got = bool(glob_to_regex(pat).match(path))
    assert got is expected, f"glob translator wrong: {pat!r} vs {path!r} -> {got}, want {expected}"

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = doc["jobs"]["test"]["steps"]


def patterns_of(step_name):
    step = next((s for s in steps if s.get("name") == step_name), None)
    assert step is not None, f"no step named {step_name!r}: {[s.get('name') for s in steps]}"
    pats = [p.strip() for p in str(step["with"]["path"]).splitlines() if p.strip()]
    assert pats, f"{step_name!r} declares no path patterns"
    return pats


cov = patterns_of("Publier la couverture en artefact de build")
fallback_step = "Publier les logs MTP restés sous bin/ (diagnostic d'échec)"
logs = patterns_of(fallback_step)

# --- the coverage artifact's SHAPE is part of its contract ------------------
# upload-artifact roots the archive at the least common ancestor of everything it matches. While
# every pattern lives under coverage/, entries land flat (`X.cobertura.xml`); the moment one
# matches outside it, the root becomes the workspace and the same reports arrive as
# `coverage/X.cobertura.xml`. That would break a consumer running
# `reportgenerator -reports:*.cobertura.xml`, and — because the fallback log only exists on some
# runs — it would break it INTERMITTENTLY. Hence the second artifact, and hence this assertion.
for p in cov:
    assert p.startswith("coverage/"), (
        f"the coverage artifact matches {p!r}, outside coverage/. That moves the artifact's root "
        "to the workspace and re-shapes every cobertura entry, conditionally on whether the "
        "out-of-tree file happens to exist. Put such paths in their own artifact instead."
    )

# --- the case this issue is about: --coverage refused, --results-directory refused with it ---
fallback = ("tests/LegacyShop.Catalog.Tests/bin/Debug/net10.0/TestResults/"
            "LegacyShop.Catalog.Tests_net10.0_arm64.log")
assert any(glob_to_regex(p).match(fallback) for p in logs), (
    f"no pattern of {fallback_step!r} matches the log's fallback location:\n"
    f"    {fallback}\n"
    f"  patterns: {logs}\n"
    "  That file carries `Unknown option '--coverage'` — the only explanation of the failure — and\n"
    "  the console prints nothing but its path. Uncollected, a CI-only failure of this kind cannot\n"
    "  be diagnosed without pushing commits to bisect it (issue #74)."
)
# ...and it must stay anchored under bin/, so a TestResults/ a legacy repo COMMITTED in its
# sources is never swept into the artifact (nor deleted by the cleanup that mirrors this pattern).
tracked = "tests/LegacyShop.Tests/TestResults/committed_by_the_repo.log"
assert not any(glob_to_regex(p).match(tracked) for p in logs), (
    f"the fallback pattern also matches a repo-tracked path ({tracked!r}): {logs}. Anchor it "
    "under */bin/* so it only ever collects build output."
)

# --- positive controls: what already worked must keep working ---------------
for control in ("coverage/LegacyShop.Empty.Tests_net10.0_arm64.log",
                "coverage/4f276e85-4f13-4ee4-8809-4d67dc0cd80a.cobertura.xml",
                "coverage/abc-guid/coverage.cobertura.xml"):
    assert any(glob_to_regex(p).match(control) for p in cov), \
        f"a coverage pattern that used to cover {control!r} no longer does: {cov}"
PY
echo "  [7] coverage artifact stays coverage-rooted; the bin/ fallback has its own, bin-anchored"

# ---------------------------------------------------------------------------
# 8. The artifact step warns that those logs are UTF-16 (issue #74).
#
#    Collecting the log is only half of it. Measured: MTP writes them UTF-16-LE with a BOM, in
#    BOTH locations — so `grep "Unknown option" <log>` on the downloaded artifact returns nothing.
#    Not "the log is empty": a UTF-8 reader sees no text in it. That failure mode LOOKS like an
#    empty file, so without a warning the reader concludes the log is worthless and goes back to
#    bisecting by pushing commits — the cost this whole issue exists to remove.
#
#    A comment is the only place that warning can live (a workflow cannot annotate an artifact),
#    so this asserts it is present — comments are exactly what a later tidy-up drops silently.
# ---------------------------------------------------------------------------
python3 - "$TEMPLATE" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
start = next((i for i, l in enumerate(lines)
              if l.strip() == "- name: Publier la couverture en artefact de build"), None)
assert start is not None, "the artifact step is gone — section 6 should have caught this first"
# The step's own block, and ONLY it — bounded by INDENT, not by the next `- name:`.
# Both of the obvious boundaries have failed here historically, silently and by over-reaching:
#   * "next `- name:`" — while the opt-in block was commented out, the next `- name:` was inside
#     it and therefore invisible, so the scan ran to EOF and swallowed 130 unrelated lines. #70
#     made those steps live, so today that boundary would in fact stop at the MTP-log step — but
#     it stops there by accident of the current layout, not by construction, and the next
#     commented step anywhere above would break it again.
#   * "next `--8<--` sentinel" — that sentinel is gone since #70, and even while it existed the
#     opt-in section opened with ~40 lines of comment ABOVE it, at the step's own indent, which
#     still got absorbed.
# Everything belonging to this step is indented deeper than its `- name:`, so the first non-blank
# line back at that indent is the true end. The assertions below then quote this step or nothing.
indent = len(lines[start]) - len(lines[start].lstrip())
end = next((i for i in range(start + 1, len(lines))
            if lines[i].strip() and (len(lines[i]) - len(lines[i].lstrip())) <= indent),
           len(lines))
block = "\n".join(lines[start:end])
# Prove the slice really is one step, so a future boundary regression surfaces here rather than
# silently widening what the assertions below are allowed to match.
assert "Setup Node" not in block, "the extracted block leaked into the opt-in steps"
assert "À N'ACTIVER" not in block, "the extracted block absorbed the opt-in section's preamble"
assert end - start < 40, f"the artifact step slice is {end - start} lines — it over-reached"

assert "UTF-16" in block, (
    "the artifact step no longer says its .log files are UTF-16. Someone downloading the artifact "
    "will grep them as UTF-8, get no output, and read that as 'the log is empty' — which is the "
    "one wrong conclusion available here (issue #74)."
)
assert "iconv" in block or "encoding=" in block, (
    "the UTF-16 warning names no way to actually read the file. State the decode command "
    "(iconv -f UTF-16) or the Python codec, or the warning leaves the reader exactly as stuck."
)
PY
echo "  [8] the artifact step warns that MTP's logs are UTF-16, and says how to read them"

# ---------------------------------------------------------------------------
# 9. The bin/ fallback is CLEANED before the run, exactly as coverage/ is.
#
#    Publishing a location makes its hygiene part of the contract. The test step already does
#    `rm -rf coverage`, and says why: a self-hosted runner reuses its workspace, so yesterday's
#    files read as today's. The bin/ fallback now ships in an artifact too — and left uncleaned it
#    is worse than coverage/ ever was, because the SAME project's log moves between the two
#    locations depending on the outcome (measured, #74): a run that fails writes it under bin/, and
#    a later GREEN run writes under coverage/ while the stale failure log sits there and gets
#    uploaded. The artifact would then explain a failure that did not happen — a wrong answer, not
#    a missing one.
#
#    Executed as a real shell, not grepped for: the assertion is that stale logs are GONE, which a
#    substring match cannot establish.
# ---------------------------------------------------------------------------
CLEAN_STEP=$(python3 - "$TEMPLATE" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
start = next(i for i, l in enumerate(lines) if l.strip() == "- name: Tests + couverture")
run = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == "run: |")
indent = len(lines[run]) - len(lines[run].lstrip()) + 2
body = []
for line in lines[run + 1:]:
    if line.strip() and len(line) - len(line.lstrip()) < indent:
        break
    body.append(line[indent:])
# Only the hygiene prologue: everything before the platform detection. Running the whole step
# would invoke dotnet, which this suite has no business doing.
out = []
for line in body:
    if line.strip().startswith("mtp="):
        break
    out.append(line)
print("\n".join(out).strip("\n"))
PY
)
[ -n "$CLEAN_STEP" ] || { echo "FAIL: could not slice the hygiene prologue of 'Tests + couverture'"; exit 1; }
bash -n <<<"$CLEAN_STEP" 2>/dev/null || { echo "FAIL: the sliced prologue is not valid bash:"; echo "$CLEAN_STEP"; exit 1; }

hyg="$scratch/hygiene"
rm -rf "$hyg" && mkdir -p "$hyg"
# Stale build output from an earlier, failed run…
mkdir -p "$hyg/tests/Proj.Tests/bin/Debug/net10.0/TestResults"
echo stale > "$hyg/tests/Proj.Tests/bin/Debug/net10.0/TestResults/Proj.Tests_net10.0_x64.log"
# …a stale coverage/ …
mkdir -p "$hyg/coverage" && echo stale > "$hyg/coverage/old.cobertura.xml"
# …and a TestResults/ the repo COMMITTED in its sources, which must survive untouched.
mkdir -p "$hyg/tests/Proj.Tests/TestResults"
echo tracked > "$hyg/tests/Proj.Tests/TestResults/committed.log"

( cd "$hyg" && bash -c "$CLEAN_STEP" ) > /dev/null 2>&1 || {
  echo "FAIL: the hygiene prologue of 'Tests + couverture' exited non-zero"; exit 1; }

# first_match, not `find … | grep -q .`: this file runs under `set -euo pipefail` (line 29), where
# grep's exit-at-first-match SIGPIPEs find into a 141 that pipefail promotes to the pipeline's
# status — so the `if` takes its else-branch precisely when stale logs DID survive, skipping the
# very failure it exists to report (#48). This was the third site to spell the same four tokens out
# inline; the probe and its tolerance now live once in tests/_lib.sh, which this suite already
# sources (#98) — so there is no longer a copy here that can drift from the other two.
stale_bin_log=$(first_match "$hyg" -path '*/bin/*' -name '*.log')
if [ -n "$stale_bin_log" ]; then
  echo "FAIL: a stale MTP log under bin/ survived the cleanup. Since that location is now"
  echo "      published as an artifact, a green run would ship the previous run's failure log"
  echo "      and the artifact would explain a failure that never happened (issue #74):"
  find "$hyg" -path '*/bin/*' -name '*.log'
  exit 1
fi
[ -f "$hyg/tests/Proj.Tests/TestResults/committed.log" ] || {
  echo "FAIL: the cleanup deleted a repo-tracked TestResults/ file. It must only ever remove"
  echo "      build output — anchor it under */bin/*."; exit 1; }
[ -d "$hyg/coverage" ] && [ -z "$(ls -A "$hyg/coverage")" ] || {
  echo "FAIL: coverage/ was not reset to an empty directory by the prologue"; exit 1; }
echo "  [9] stale bin/ logs are cleaned before the run; a committed TestResults/ is left alone"

# ---------------------------------------------------------------------------
# 10. The coverage guard reports on what it FOUND — under `pipefail` too (issue #97).
#
#     The shipped guard is the last `find … | grep -q .` in the kit. It is correct today only by
#     ACCIDENT: GitHub's default step shell is `bash -e {0}`, which has no `pipefail`, so `find`'s
#     status is discarded and the pipeline reports `grep`'s. Two ordinary edits arm it — adding
#     `set -euo pipefail` to this step's body, which the sibling step "Tests + couverture" in the
#     same file ALREADY does, or setting `defaults.run.shell: bash`, which GitHub maps to
#     `bash -eo pipefail`.
#
#     Armed, the guard inverts: `grep -q` exits at the first match, `find` dies on the closed pipe,
#     `pipefail` promotes that to the pipeline's status, and the NEGATED condition takes its
#     then-branch — so the step fails with "Aucun rapport de couverture produit" precisely when
#     coverage WAS produced. In every repo that took the template.
#
#     Three things make this case easy to write wrongly, and all three are why it is shaped as it is:
#
#     * The fixture must OVERRUN the pipe buffer. With less output `find` finishes writing before
#       `grep` closes the pipe, never sees EPIPE, and the bug is simply not reachable — the test
#       would pass against the broken guard and prove nothing. Hence the long path components:
#       they buy the byte volume without tens of thousands of inodes.
#     * A byte threshold alone does NOT establish that. "64 KiB" is Linux's `PIPE_DEF_BUFFERS`
#       (16) x PAGE_SIZE, so on a 64 KiB-page arm64 kernel the capacity is 1 MiB and a 350 KB
#       listing fits entirely — `grep -q` never closes the pipe under a still-writing `find`, the
#       BROKEN guard exits 0, and a test that only checked its own fixture size would go green over
#       a reverted fix. So the naive pipeline is RUN FIRST and required to fail: the reproduction
#       is proven on the host at hand rather than inferred from a constant. Same control as
#       tests/xunit-v3/test.sh section 10, for the same reason.
#     * The fixture's population is proven by COUNTING files, never by reading an exit status.
#       Measured while fixing #48, the status is not even the same on both platforms: BSD find is
#       killed by SIGPIPE (141), GNU find catches EPIPE and returns 1 — and 1 is also what an empty
#       directory yields, so a status-reading test cannot tell "the bug fired" from "I built no
#       fixture". Counting first is what makes the non-zero status unambiguous.
#
#     And it is run under the THREE shells this step can actually get, because "correct under
#     `set -euo pipefail`" is not the property the goal asks for — shell-option INDEPENDENCE is:
#       * `bash -e`            — GitHub's default step shell, what the template ships into today;
#       * `bash -eo pipefail`  — what `defaults.run.shell: bash` maps to;
#       * `bash -euo pipefail` — the sibling step "Tests + couverture"'s own prologue.
#     Testing only the armed one would let a regression that is correct there and broken under bare
#     `bash -e` ship in the configuration every repo actually runs.
# ---------------------------------------------------------------------------
COV_GUARD=$(step_named "Garde — la couverture a bien été produite")
[ -n "$COV_GUARD" ] || { echo "FAIL: the coverage guard step has an empty run: body"; exit 1; }
bash -n <<<"$COV_GUARD" 2>/dev/null || {
  echo "FAIL: the coverage guard body is not valid bash — the slice truncated it:"
  echo "$COV_GUARD"; exit 1; }

cov="$scratch/pipefail-coverage"
rm -rf "$cov" && mkdir -p "$cov"
# Two ~200-char components (well under the 255-byte per-component limit) put each printed path at
# ~440 bytes, so a few hundred files clear 64 KiB several times over.
long_a=$(printf 'a%.0s' $(seq 1 200))
long_b=$(printf 'b%.0s' $(seq 1 200))
mkdir -p "$cov/coverage/$long_a/$long_b"
for i in $(seq 1 800); do
  : > "$cov/coverage/$long_a/$long_b/report-$i.cobertura.xml"
done

# Measure the fixture the way the guard will see it — relative to the step's working directory,
# and REDIRECTED TO A FILE so no pipe exists and nothing can SIGPIPE the measurement itself.
( cd "$cov" && find coverage -name '*.cobertura.xml' -type f ) > "$scratch/cov-listing.txt"
cov_files=$(wc -l < "$scratch/cov-listing.txt" | tr -d ' ')
cov_bytes=$(wc -c < "$scratch/cov-listing.txt" | tr -d ' ')
[ "$cov_files" -eq 800 ] || {
  echo "FAIL: fixture broken — $cov_files matching files, expected 800. Counted directly rather"
  echo "      than inferred from an exit status, so the control below is unambiguous."; exit 1; }

# THE control: the naive pipeline must actually invert HERE, on this host, before anything below
# is worth asserting. A byte threshold cannot establish that — pipe capacity is PAGE_SIZE-derived,
# so a 64 KiB-page kernel swallows this whole listing and the broken guard would exit 0. If this
# pipeline succeeds, the fixture is too small for THIS machine and the case is proving nothing.
set +e
( cd "$cov" && set -o pipefail && find coverage -name '*.cobertura.xml' 2>/dev/null | grep -q . )  # sigpipe-repro
naive_rc=$?
set -e
[ "$naive_rc" -ne 0 ] || {
  echo "FAIL: fixture broken — the naive pipeline SUCCEEDED on $cov_files matches"
  echo "      ($cov_bytes bytes of paths). It must fail here (141 on BSD find, 1 on GNU find's"
  echo "      'Broken pipe'): that inversion is the whole defect of #97, and without it this case"
  echo "      would go green against a reverted fix. This host's pipe capacity is larger than the"
  echo "      listing — lengthen the path components or add files until it inverts."; exit 1; }

# Every shell this step can actually get. `run_cov_guard <log> <bash-flags…>` runs the step's OWN
# extracted body, nothing re-typed, so these assertions are about the shipped template.
run_cov_guard() {
  local log="$1"; shift
  ( cd "$cov" && bash "$@" -c "$COV_GUARD" ) > "$log" 2>&1
}
# `-e` alone is GitHub's default step shell and therefore the configuration EVERY repo that took
# this template runs today; the other two are the two documented ways it gets armed.
COV_SHELLS=("-e" "-eo pipefail" "-euo pipefail")

# `assert_cov_guard <expect: refuse|accept> <label>` — one assertion for every per-shell
# refuse/accept row, so a fix to the diagnosis check (or to the shell matrix) lands for every
# caller at once instead of some of them (#141). Runs the guard under every shell in
# `COV_SHELLS` against whatever fixture the caller already built under `$cov/coverage`, and
# asserts both the exit status AND that the `Aucun rapport de couverture produit` diagnosis is
# present exactly when the guard refuses — never on a status check alone, since a guard that
# dies on find's own error under errexit also exits non-zero, but WITHOUT ever reaching the
# message a real refusal prints.
assert_cov_guard() {
  local expect="$1" label="$2"
  local opts tag log rc

  for opts in "${COV_SHELLS[@]}"; do
    tag=$(printf '%s' "$opts" | tr -d ' -')
    log="$scratch/cov-$(printf '%s' "$label" | tr -cs 'a-zA-Z0-9' '-')-$tag.log"
    # shellcheck disable=SC2086
    if run_cov_guard "$log" $opts; then rc=0; else rc=1; fi

    if [ "$expect" = refuse ]; then
      [ "$rc" -ne 0 ] || {
        echo "FAIL: under \`bash $opts\` the guard ACCEPTED $label — a silent collection failure"
        echo "      would ship as a green run. Guard output:"
        sed 's/^/        /' "$log"; exit 1; }
      grep -q 'Aucun rapport de couverture produit' "$log" || {
        echo "FAIL: under \`bash $opts\` the guard refused $label WITHOUT its diagnosis — it died"
        echo "      on find's own error under errexit instead. Keep the \`2>/dev/null || true\`"
        echo "      tolerance so the emptiness test, not find's exit status, decides. Output:"
        sed 's/^/        /' "$log"; exit 1; }
    elif [ "$expect" = accept ]; then
      [ "$rc" -eq 0 ] || {
        echo "FAIL: under \`bash $opts\` the guard REFUSED $label — a working repo told its"
        echo "      coverage was never produced. \`find\` does not follow symlinks by default, so"
        echo "      the guard's \`-L\` is load-bearing and not decoration. Guard output:"
        sed 's/^/        /' "$log"; exit 1; }
      grep -q 'Aucun rapport de couverture produit' "$log" && {
        echo "FAIL: under \`bash $opts\` the guard exited 0 over $label but still PRINTED its"
        echo "      missing-coverage diagnosis — a green step carrying a false message."
        sed 's/^/        /' "$log"; exit 1; }
    else
      echo "FAIL: assert_cov_guard called with expect='$expect' — must be 'refuse' or 'accept'"
      exit 1
    fi
  done
  # Explicit, and load-bearing: without it the function's return status is whatever its LAST
  # internal command left behind — and on the (correct, intended) path where the closing
  # `grep -q … && { FAIL…; }` finds NO match, that `&&` list itself evaluates non-zero. Under
  # `set -e` a bare `assert_cov_guard …` call at the callsite then dies right there, silently —
  # no FAIL was ever printed, because nothing actually failed; the good outcome's own exit
  # status leaked out as if the function itself had.
  return 0
}

for opts in "${COV_SHELLS[@]}"; do
  tag=$(printf '%s' "$opts" | tr -d ' -')
  # --- coverage present: the guard must PASS ---
  # shellcheck disable=SC2086
  if run_cov_guard "$scratch/cov-ok-$tag.log" $opts; then :; else
    echo "FAIL: under \`bash $opts\` the coverage guard FAILED over $cov_files cobertura reports"
    echo "      ($cov_bytes bytes of paths) — it must succeed when coverage was produced. The"
    echo "      find|grep -q shape reports find's death on the closed pipe instead of what it"
    echo "      found; capture the first match and test it for emptiness instead:"
    echo "          found=\$(find coverage -name '*.cobertura.xml' -print -quit 2>/dev/null || true)"
    echo "          if [ -z \"\$found\" ]; then"
    echo "      Guard output:"
    sed 's/^/        /' "$scratch/cov-ok-$tag.log"
    exit 1
  fi
  grep -q 'Aucun rapport de couverture produit' "$scratch/cov-ok-$tag.log" && {
    echo "FAIL: under \`bash $opts\` the guard exited 0 but still PRINTED its missing-coverage"
    echo "      diagnosis over $cov_files reports — a green step carrying a false message."
    sed 's/^/        /' "$scratch/cov-ok-$tag.log"; exit 1; }
done

# The inverse direction, under the same three shells: coverage genuinely absent must still FAIL,
# and fail WITH the diagnosis. Section [4e] of tests/xunit-v3/test.sh pins this under one unarmed
# shell; it is re-pinned here because the `2>/dev/null || true` that makes the fix option-proof is
# also precisely what could swallow a real absence — and because that sibling suite needs the .NET
# SDK, so this is the copy that runs everywhere.
#
# Two shapes, and the difference is not cosmetic. EMPTY is what the step actually meets in CI: the
# sibling step "Tests + couverture" opens with `rm -rf coverage && mkdir -p coverage`, so the
# directory always exists by the time the guard runs. MISSING is the shape that exercises the
# tolerance itself — there `find` exits non-zero and writes to stderr, so a guard without
# `2>/dev/null || true` dies under errexit on find's own message instead of reaching the
# diagnosis. The empty case cannot see that, because there `find` exits 0.
for shape in empty missing; do
  rm -rf "$cov/coverage"
  [ "$shape" = empty ] && mkdir -p "$cov/coverage"
  assert_cov_guard refuse "a $shape coverage/"
done

echo "  [10] the coverage guard reports what it found under bash -e, -eo pipefail and -euo pipefail"\
     "— $cov_files reports ($cov_bytes bytes, naive pipeline confirmed inverting) accepted;"\
     "empty and missing coverage/ still refused, with their diagnosis"

# WHAT QUALIFIES AS ONE MATCH (#126). The two shapes above vary how MANY entries `coverage/` holds;
# these vary what KIND of entry it holds, which the guard used not to ask about at all. `find`
# matches by NAME and has no opinion about type, so ANY entry called `*.cobertura.xml` satisfied a
# bare `-name` test — a directory a collector left behind, or a symlink pointing nowhere on a
# self-hosted runner reusing its workspace (the reason the sibling step opens with
# `rm -rf coverage && mkdir -p coverage`). The step then went green having proved only that a NAME
# exists, and the artifact shipped with nothing parsable in it: the very fail-open this guard was
# written to close, and the same shape as #96 — a green run indistinguishable from a healthy one.
#
# The middle row is why the fix is `find -L … -type f` and NOT the obvious `-type f`. `find` does
# not follow symlinks by default, so `-type f` alone would start refusing a LEGITIMATE report
# reached through a symlink — trading a fail-open for a fail-closed, which is strictly worse
# because the new failure is loud, misleading, and hits working setups. Measured (#126) against
# the shipped expression and both candidates — the three-row table is templates/ci-dotnet.yml's
# own (its "entrée sous coverage/" rationale, read below rather than retyped in English here: #141
# found the two copies asserting against each other, one in French and one in English, with
# nothing to keep them in sync when either changed).
#
# so the symlinked-report row is the one that distinguishes the two candidates, and the regression
# a later "simplification" to a bare `-type f` would introduce. Presence semantics are untouched:
# #31 settled that this guard tests presence and not COUNT, and nothing here compares reports to
# projects.
#
# The symlink's TARGET deliberately lives OUTSIDE `coverage/`. Put it inside and `find` would reach
# the real file directly, the case would pass for a reason that has nothing to do with following
# the link, and a bare `-type f` would survive it — leaving the one row that matters unpinned.
mkdir -p "$cov/real"
: > "$cov/real/genuine.cobertura.xml"

# The fixture set this suite actually exercises — declared here, ahead of the extraction below,
# so the row-count assertion can check against ITS length rather than a hardcoded number: a table
# row added without a matching fixture (or removed while a fixture still expects it) must redden,
# not silently pass because the count assertion was a separate literal that happened to agree.
ENTRY_KINDS=(directory dangling-symlink symlinked-report)

# The template's own table, sliced out rather than retyped (#141), following case 4h's precedent
# in tests/xunit-v3/test.sh:629-631 (`mtp_line=$(grep -E … ci-dotnet.yml)`, `eval`'d under a
# `[ -n … ]` guard): find the "entrée sous coverage/" header and take every comment line that
# follows it up to the first BLANK comment line (the table's own trailing `#`) — open-ended, not
# capped at today's row count, so a row added to the table without a matching entry in
# `ENTRY_KINDS` changes the extracted count and reddens below, rather than being silently dropped
# by a cap that only ever reads "the first N".
cov_table_rows=$(awk '
  found {
    line = $0
    sub(/^[[:space:]]*#[[:space:]]*/, "", line)
    if (line == "") { exit }
    print line
    next
  }
  /entrée sous coverage\// { found=1 }
' templates/ci-dotnet.yml)
[ -n "$cov_table_rows" ] && [ "$(printf '%s\n' "$cov_table_rows" | grep -c .)" -eq "${#ENTRY_KINDS[@]}" ] || {
  echo "FAIL: templates/ci-dotnet.yml's coverage-guard table (after its 'entrée sous coverage/'"
  echo "      header) has $(printf '%s\n' "$cov_table_rows" | grep -c .) row(s), but this suite has"
  echo "      fixtures for ${#ENTRY_KINDS[@]} entry kind(s) (${ENTRY_KINDS[*]}). Rows found:"
  printf '%s\n' "$cov_table_rows"
  echo "      A table row without a matching fixture (or a fixture without a matching row) must"
  echo "      fail loudly here rather than let 'expect' silently fall back to nothing."; exit 1; }

# <row-label substring> — the row's LAST column (the "-L … -type f" one: what the shipped guard
# actually runs), normalized from the table's French 'matche'/'refusé'/'REFUSÉ' to accept/refuse.
# A row that does not contain the substring, or whose last column is neither spelling, is a loud
# FAIL naming the table and the expected shape — never a default.
#
# ⚠ Every caller reads this through `expect=$(cov_table_expect …)`, a command substitution — so
# anything this function writes to STDOUT is captured into `expect`, never seen in the log. A FAIL
# echoed there (as every other FAIL in this suite is) would still exit the script under `set -e`
# (an assignment's command substitution failing DOES trigger errexit, unlike a bare command), but
# SILENTLY: the diagnostic would be swallowed into a variable nothing ever reads. So every FAIL
# line here goes to STDERR (`>&2`), and only the final `accept`/`refuse` verdict goes to stdout.
cov_table_expect() {
  local label="$1" line col
  line=$(printf '%s\n' "$cov_table_rows" | grep -F "$label")
  [ -n "$line" ] || {
    echo "FAIL: no row in templates/ci-dotnet.yml's coverage-guard table contains '$label' —" >&2
    echo "      re-point this extraction if the table's row wording changed. Rows found:" >&2
    printf '%s\n' "$cov_table_rows" >&2; exit 1; }
  col=$(printf '%s\n' "$line" | awk '{print $NF}')
  case "$col" in
    matche) echo accept ;;
    refusé|REFUSÉ) echo refuse ;;
    *)
      echo "FAIL: the '$label' row's last column ('$col') in templates/ci-dotnet.yml's" >&2
      echo "      coverage-guard table is neither 'matche' nor 'refusé'/'REFUSÉ' — re-point this" >&2
      echo "      extraction if the table's spelling changed." >&2; exit 1 ;;
  esac
}

for entry in "${ENTRY_KINDS[@]}"; do
  rm -rf "$cov/coverage" && mkdir -p "$cov/coverage"
  case "$entry" in
    directory)
      mkdir -p "$cov/coverage/bogus.cobertura.xml"
      target="$cov/coverage/bogus.cobertura.xml"; expect=$(cov_table_expect "dossier")
      [ -d "$target" ] && [ ! -f "$target" ] || {
        echo "FAIL: fixture broken — $target is not a directory, so the case below would assert"
        echo "      nothing about the entry type it is named for."; exit 1; } ;;
    dangling-symlink)
      ln -s ../nowhere/absent.cobertura.xml "$cov/coverage/dangling.cobertura.xml"
      target="$cov/coverage/dangling.cobertura.xml"; expect=$(cov_table_expect "cassé")
      [ -L "$target" ] && [ ! -e "$target" ] || {
        echo "FAIL: fixture broken — $target must be a symlink whose target does NOT exist;"
        echo "      a resolvable one would be testing the row below instead."; exit 1; } ;;
    symlinked-report)
      ln -s ../real/genuine.cobertura.xml "$cov/coverage/linked.cobertura.xml"
      target="$cov/coverage/linked.cobertura.xml"; expect=$(cov_table_expect "vrai rapport")
      [ -L "$target" ] && [ -f "$target" ] || {
        echo "FAIL: fixture broken — $target must be a symlink that RESOLVES to a regular file;"
        echo "      that is the row separating \`-L -type f\` from a bare \`-type f\`."; exit 1; } ;;
  esac

  assert_cov_guard "$expect" "a coverage/ holding only a $entry named *.cobertura.xml"
done

echo "  [10b] and it asks what KIND of entry it found: ${#ENTRY_KINDS[@]} entry kinds under"\
     "coverage/ (${ENTRY_KINDS[*]}) — a directory or dangling symlink named *.cobertura.xml is"\
     "refused, a symlink to a real report is accepted — the row that keeps the -L on the -type f"

# The fix leans on `-print -quit`, so the shipped step must SAY SO when the host's find lacks it.
# tests/_lib.sh:kit_require_find_quit exists for exactly this reason on the kit's own side — on a
# find without `-quit` (busybox, minimal containers) the probe answers "nothing found" with the
# error discarded. In the template that surfaces as the missing-coverage message and a pointer at
# Microsoft.Testing.Extensions.CodeCoverage: a real failure, diagnosed as the wrong cause, on
# somebody else's runner. The shipped copy gets no `kit_require_find_quit`, so it must carry the
# check itself.
grep -q -- '-print -quit' templates/ci-dotnet.yml || {
  echo "FAIL: the coverage guard no longer uses '-print -quit'"; exit 1; }

cov_expr=$(grep -m1 -F 'found=$(find ' templates/ci-dotnet.yml)
cov_probe=$(grep -m1 -F 'maxdepth 0' templates/ci-dotnet.yml)
[ -n "$cov_expr" ] || {
  echo "FAIL: could not locate the coverage guard's find expression in templates/ci-dotnet.yml, so"
  echo "      the probe assertion below would silently prove nothing. Re-point this extraction."
  exit 1; }
[ -n "$cov_probe" ] || {
  echo "FAIL: the guard depends on '-print -quit' but never proves this runner's find supports it."
  echo "      Without that probe an unsupported predicate is indistinguishable from absent"
  echo "      coverage, and the step blames the collector for the runner's find — see"
  echo "      tests/_lib.sh:kit_require_find_quit, which exists for that exact failure."; exit 1; }

# The probe must cover EVERY predicate the expression it guards leans on, not just the last one to
# be added (#126). A probe NARROWER than its expression guards nothing: on a find that rejects `-L`
# or `-type`, the expression exits non-zero, the `2>/dev/null || true` swallows the error, `$found`
# comes back empty — and the probe still SUCCEEDS, so the step skips its "your find lacks the
# predicate" branch and tells a repo with perfectly good coverage that its collector was silently
# skipped. That is the exact misdiagnosis the probe exists to prevent, reopened by widening the
# expression without widening the probe. Derived from the shipped expression rather than a hardcoded
# list, so a future predicate is covered the day it is added.
for pred in '-L' '-type' '-print -quit'; do
  case " $cov_expr " in *" $pred"*) ;; *) continue ;; esac
  case " $cov_probe " in
    *" $pred"*) ;;
    *)
      echo "FAIL: the coverage guard's expression uses '$pred' but its capability probe does not."
      echo "      A find rejecting '$pred' fails the expression, the '2>/dev/null || true' hides it,"
      echo "      and the probe still passes — so the step prints its missing-coverage diagnosis at"
      echo "      a repo whose coverage WAS produced. Widen the probe with every predicate the"
      echo "      expression depends on."
      echo "      expression: $cov_expr"
      echo "      probe:      $cov_probe"; exit 1 ;;
  esac
done
echo "  [10c] and its capability probe tests every predicate that expression depends on"\
     "(-L, -type, -print -quit), so an unsupported one cannot masquerade as absent coverage"

echo "ci-dotnet template opt-in bundle gate golden test OK"
