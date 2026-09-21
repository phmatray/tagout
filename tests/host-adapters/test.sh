#!/usr/bin/env bash
# Golden test for scripts/host-adapters.py — the generator and drift check for the files that carry
# one of the kit's sources to another host (#525, #526): AGENTS.md's rule copies for Cursor,
# Windsurf, Cline, Kiro, GitHub Copilot and Antigravity, the TOML commands and extension manifest
# Gemini CLI reads, and the invariants the plugin manifests and the host table must keep.
#
# What this suite guards:
#   A. the REAL repository                      -> check exits 0, every copy in step
#   B. one copy edited in a scratch tree        -> exit 1, naming that copy and no other
#   C. build in that tree, then check           -> exit 0 — build restores what check refuses
#   D. a copy's whole folder deleted            -> exit 1, naming it; build recreates the folder
#   E. a scratch tree with no AGENTS.md         -> exit 2, no verdict, never a pass
#   F. a copy with CRLF line endings            -> exit 0 (a Windows checkout is not drift)
#  F2. a UTF-16 copy / a UTF-16 AGENTS.md       -> exit 1 naming it / exit 2 — never a traceback
#  F4. a CRLF AGENTS.md                         -> exit 0 (the source is normalised too)
#   G. no subcommand                            -> exit 2 (usage)
#   H. each host's front matter, on the real copies, as the host documents it
#   I. a hooks/hooks.json in the tree           -> exit 1, naming it (Gemini and Copilot auto-load it)
#   J. a manifest naming a hooks map that does not exist -> exit 1, naming the path
#   K. a manifest at another version than the release-please manifest -> exit 1, naming it
#   L. a versioned manifest missing from release-please's extra-files -> exit 1, naming it
#   M. a TOML command edited by hand            -> exit 1, naming it AND the .md it is built from
#   N. a server added to .mcp.json alone        -> exit 1, naming gemini-extension.json
#   O. the live TOML commands parse, carry description + prompt, and spell {{args}}
#  O2. a command body reading $10+ is refused as no verdict, never silently mangled into {{args}}0
#   P. gemini-extension.json, against the shape Gemini CLI documents
#   Q. package.json declares the skills for pi and stays private
#   R. README.md missing a plugin host's install line -> exit 1, naming README.md and the host
#   S. a host table row naming an adapter that does not exist -> exit 1, naming the adapter
#   T. the manifests name the paths their hosts load; both marketplaces name the same plugin
#   U. a TOML command whose .md is gone          -> exit 1, naming the orphan
#   V. package.json naming a pi skills folder that does not exist -> exit 1, naming it
#   W. a RULE_COPIES entry with no host adapter -> exit 1, naming it
#   X. the two plugins' partition (#607): a skill copied into no plugin, a migration skill under the
#      lifecycle plugin, a copy no source accounts for, an .mcp.json under the lifecycle plugin, a
#      <kit>/<path> one of its skills names with nothing to resolve to -> exit 1, naming each
#   Y. a plugin's generated hooks map / command copy / .mcp.json edited by hand -> exit 1 naming
#      it and its source; build restores it
#   Z. the plugin trees are generated FILES (#619, ADR 0017): no committed symlink under plugins/,
#      every shipped skill a directory with a SKILL.md, an edited copy -> exit 1 naming its source,
#      a symlink -> exit 1, and a copy committed at another mode than its source -> exit 1 naming
#      the `git add --chmod` that fixes it
#
# The seam is the check's exit code and its STDOUT: a refusal is named there, and stderr is read
# only to prove no traceback escaped. Expected paths and values are literals here, never read back
# out of the script — a test that recomputed them the way the script does could never disagree with
# it (tautological). Section lines carry a label, never a fraction.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO/scripts/host-adapters.py"
. "$REPO/tests/_lib.sh" || {
  echo "FAIL: cannot source $REPO/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$REPO"
kit_guard kit_guard_samples_unchanged
WORK=$(kit_scratch)

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

COPIES=".cursor/rules/tagout.mdc .windsurf/rules/tagout.md .clinerules/tagout.md .kiro/steering/tagout.md .github/copilot-instructions.md"
# What the invariants read, beside the copies: the manifests, the files their paths name,
# release-please's two files, the host table and the README it is checked against. `skills/` only
# has to exist for a manifest's `skills` path to resolve.
SOURCES=".claude-plugin/plugin.json .github/repo-setup.yml plugins/tagout/.claude-plugin/plugin.json plugins/tagout-migrate/.claude-plugin/plugin.json hooks/tagout-hooks.json hooks/tagout-migrate-hooks.json .codex-plugin/plugin.json .github/plugin/plugin.json gemini-extension.json package.json hooks/claude-hooks.json .mcp.json .release-please-manifest.json release-please-config.json docs/_data/hosts.yml README.md"

# The tree entries the two plugins COPY (ADR 0017, #619) — literals here, like every other
# expectation in this suite: a fixture that read the map out of the script could never disagree
# with it. Only the shape is needed, so the scratch versions are empty but present.
COPY_DIRS="skills/_shared scripts hooks templates decisions tests/auto-dev-never-wait tests/xunit-v3"
COPY_FILES="CONTEXT.md requirements.json docs/backlog.md renovate.json"

# scratch_tree <dir> — a copy of what the check reads, and nothing else. The plugin directories are
# left to `build`, which is what writes them in the real tree too; a case then perturbs one file.
scratch_tree() {
  local d="$1" f s n p
  mkdir -p "$d/skills"
  for s in "$REPO"/skills/*/; do
    n=$(basename "$s"); mkdir -p "$d/skills/$n"
    printf -- '---\nname: %s\n---\n' "$n" > "$d/skills/$n/SKILL.md"
  done
  cp "$REPO/AGENTS.md" "$d/AGENTS.md"
  cp -R "$REPO/commands" "$d/commands"
  for p in tagout tagout-migrate; do
    mkdir -p "$d/plugins/$p"
    cp -R "$REPO/plugins/$p/.claude-plugin" "$d/plugins/$p/.claude-plugin"
    cp -R "$REPO/plugins/$p/commands" "$d/plugins/$p/commands"
  done
  cp "$REPO/plugins/tagout-migrate/.mcp.json" "$d/plugins/tagout-migrate/.mcp.json"
  for f in $COPY_DIRS; do mkdir -p "$d/$f"; done
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/scripts/guard.sh"   # Z5's executable source
  for f in $COPY_FILES; do mkdir -p "$d/$(dirname "$f")"; [ -e "$d/$f" ] || : > "$d/$f"; done
  for f in $COPIES $SOURCES; do
    mkdir -p "$d/$(dirname "$f")"
    cp "$REPO/$f" "$d/$f" 2>/dev/null || true
  done
  cp "$REPO"/hooks/*.sh "$d/hooks/"      # the hook scripts each plugin's map names: the <kit>/ scan reads them
  # The plugin trees, as the real tree has them. The exit status is NOT discarded: a build that
  # exits 2 (an entry named in the copy map but absent from COPY_DIRS/COPY_FILES above) would leave
  # every fixture with no plugin trees at all, and the partition cases would then pass by accident,
  # for the wrong reason.
  python3 "$CHECK" --repo "$d" build > "$d/.build.out" 2>&1 \
    || { echo "FAIL: scratch_tree's build exited $? — the fixture has no plugin trees"; cat "$d/.build.out"; exit 1; }
  rm -f "$d/.build.out"
}

# run_check <repo> [subcommand] — sets OUT (stdout), ERR (stderr) and RC.
run_check() {
  OUT=$(python3 "$CHECK" --repo "$1" "${2:-check}" 2>"$WORK/stderr")
  RC=$?
  ERR=$(cat "$WORK/stderr")
}

names() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
no_traceback() { case "$ERR" in *Traceback*) bad "$1 produced a traceback: $ERR" ;; *) ok "$1: no traceback" ;; esac; }
utf16() { python3 -c 'import sys; open(sys.argv[2], "w", encoding="utf-16").write(open(sys.argv[1], encoding="utf-8").read())' "$1" "$2"; }
crlf() { awk '{ printf "%s\r\n", $0 }' "$1" > "$2"; }
# jedit <file> <python statement on d> — edit one JSON file in place, for a mutation case.
jedit() { python3 -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p, encoding="utf-8")); exec(sys.argv[2]); json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)' "$1" "$2"; }

[ -f "$CHECK" ] || { echo "FAIL: $CHECK does not exist"; exit 1; }

echo "== A. the real repository =="
run_check "$REPO"
[ "$RC" -eq 0 ] && ok "check exits 0 on the live tree" || bad "check exited $RC on the live tree: $OUT $ERR"

echo "== B. one edited copy is refused, by name =="
T="$WORK/b"; scratch_tree "$T"
printf '\nA line nobody generated.\n' >> "$T/.clinerules/tagout.md"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC, want 1: $OUT $ERR"
names ".clinerules/tagout.md" && ok "names .clinerules/tagout.md on stdout" || bad "stdout does not name the edited copy: $OUT"
names ".kiro/steering/tagout.md" && bad "names an untouched copy: $OUT" || ok "names no untouched copy"

echo "== C. build restores it =="
run_check "$T" build
[ "$RC" -eq 0 ] && ok "build exits 0" || bad "build exited $RC: $ERR"
run_check "$T"
[ "$RC" -eq 0 ] && ok "check exits 0 after build" || bad "check exited $RC after build: $OUT"

echo "== D. a copy's whole folder deleted is drift, and build recreates it =="
T="$WORK/d"; scratch_tree "$T"
rm -r "$T/.kiro"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC, want 1: $OUT $ERR"
names ".kiro/steering/tagout.md" && ok "names the missing copy on stdout" || bad "stdout does not name the missing copy: $OUT"
run_check "$T" build
[ "$RC" -eq 0 ] && ok "build recreates the missing folder" || bad "build exited $RC into a missing folder: $ERR"
run_check "$T"
[ "$RC" -eq 0 ] && ok "check exits 0 after build" || bad "check exited $RC after build: $OUT"

echo "== E. no AGENTS.md, no verdict =="
T="$WORK/e"; scratch_tree "$T"
rm "$T/AGENTS.md"
run_check "$T"
[ "$RC" -eq 2 ] && ok "exit 2" || bad "exit $RC, want 2: $OUT $ERR"
no_traceback "a missing AGENTS.md"

echo "== F. CRLF is not drift =="
T="$WORK/f"; scratch_tree "$T"
crlf "$REPO/.clinerules/tagout.md" "$T/.clinerules/tagout.md"
run_check "$T"
[ "$RC" -eq 0 ] && ok "a CRLF copy is in step" || bad "exit $RC on a CRLF copy: $OUT"

echo "== F2. a non-UTF-8 file: a copy is drift, the source is no verdict =="
T="$WORK/f2"; scratch_tree "$T"
utf16 "$REPO/.windsurf/rules/tagout.md" "$T/.windsurf/rules/tagout.md"
run_check "$T"
[ "$RC" -eq 1 ] && ok "a UTF-16 copy exits 1" || bad "a UTF-16 copy exited $RC, want 1: $OUT $ERR"
names ".windsurf/rules/tagout.md" && ok "names the UTF-16 copy on stdout" || bad "stdout does not name the UTF-16 copy: $OUT"
no_traceback "a UTF-16 copy"
T="$WORK/f3"; scratch_tree "$T"
utf16 "$REPO/AGENTS.md" "$T/AGENTS.md"
run_check "$T"
[ "$RC" -eq 2 ] && ok "a UTF-16 AGENTS.md exits 2" || bad "a UTF-16 AGENTS.md exited $RC, want 2: $OUT $ERR"
no_traceback "a UTF-16 AGENTS.md"

echo "== F4. a CRLF AGENTS.md is not drift =="
T="$WORK/f4"; scratch_tree "$T"
crlf "$REPO/AGENTS.md" "$T/AGENTS.md"
run_check "$T"
[ "$RC" -eq 0 ] && ok "LF copies are in step with a CRLF source" || bad "exit $RC with a CRLF AGENTS.md: $OUT"

echo "== G. usage =="
python3 "$CHECK" --repo "$REPO" > /dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "no subcommand exits 2" || bad "no subcommand exited $RC"

echo "== H. each host's front matter =="
[ "$(head -1 "$REPO/.cursor/rules/tagout.mdc")" = "---" ] \
  && grep -qx 'alwaysApply: true' "$REPO/.cursor/rules/tagout.mdc" \
  && ok "Cursor: an always-applied .mdc rule" || bad "Cursor rule lacks 'alwaysApply: true' front matter"
grep -qx 'trigger: always_on' "$REPO/.windsurf/rules/tagout.md" \
  && ok "Windsurf: trigger always_on" || bad "Windsurf rule lacks 'trigger: always_on'"
grep -qx 'inclusion: always' "$REPO/.kiro/steering/tagout.md" \
  && ok "Kiro: inclusion always" || bad "Kiro steering lacks 'inclusion: always'"
for f in .clinerules/tagout.md .github/copilot-instructions.md; do
  [ "$(head -1 "$REPO/$f")" = "# Tagout" ] \
    && ok "$f: no front matter, opens on the heading" || bad "$f does not open on '# Tagout'"
done

echo "== I. the Claude hooks map stays off hooks/hooks.json =="
T="$WORK/i"; scratch_tree "$T"
printf '{"hooks": {}}\n' > "$T/hooks/hooks.json"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with a hooks/hooks.json, want 1: $OUT $ERR"
names "hooks/hooks.json" && ok "names hooks/hooks.json on stdout" || bad "stdout does not name hooks/hooks.json: $OUT"

echo "== J. a manifest naming a hooks map that does not exist =="
T="$WORK/j"; scratch_tree "$T"
jedit "$T/plugins/tagout/.claude-plugin/plugin.json" 'd["hooks"] = "./hooks/nope.json"'
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with a missing hooks map, want 1: $OUT $ERR"
names "./hooks/nope.json" && ok "names the missing path on stdout" || bad "stdout does not name ./hooks/nope.json: $OUT"

echo "== K. a manifest at another version than the release-please manifest =="
T="$WORK/k"; scratch_tree "$T"
jedit "$T/.codex-plugin/plugin.json" 'd["version"] = "0.0.1"'
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with a stale Codex version, want 1: $OUT $ERR"
names ".codex-plugin/plugin.json" && ok "names .codex-plugin/plugin.json on stdout" || bad "stdout does not name the stale manifest: $OUT"

echo "== L. a versioned manifest missing from release-please's extra-files =="
T="$WORK/l"; scratch_tree "$T"
jedit "$T/release-please-config.json" 'd["packages"]["."]["extra-files"] = [e for e in d["packages"]["."]["extra-files"] if e["path"] != ".github/plugin/plugin.json"]'
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with a manifest outside extra-files, want 1: $OUT $ERR"
names ".github/plugin/plugin.json" && ok "names .github/plugin/plugin.json on stdout" || bad "stdout does not name the unbumped manifest: $OUT"

echo "== L2. UNVERSIONED_JSON names the two un-versioned marketplace manifests =="
# Routed through py_module (tests/_lib/py.sh) — the kit's ONE importlib loader (#51) — rather
# than a second hand-rolled by-path module load, which the loader's own golden test
# (tests/xunit-v3/test.sh section 8) refuses by name.
kit_source "$REPO/tests/_lib/py.sh"
COUNT=$(py_module "$CHECK" <<'PY'
print(len(mod.UNVERSIONED_JSON))
PY
)
[ "$COUNT" = "2" ] && ok "UNVERSIONED_JSON has 2 entries" || bad "UNVERSIONED_JSON: got '$COUNT', want 2"

echo "== M. a TOML command edited by hand is refused, naming its source =="
T="$WORK/m"; scratch_tree "$T"
printf '\n# edited by hand\n' >> "$T/commands/migrate.toml"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with an edited TOML command, want 1: $OUT $ERR"
names "commands/migrate.toml" && ok "names commands/migrate.toml on stdout" || bad "stdout does not name the edited command: $OUT"
names "commands/migrate.md" && ok "names its source, commands/migrate.md" || bad "the refusal does not name the TOML's source: $OUT"

echo "== N. a server added to .mcp.json alone leaves gemini-extension.json behind =="
T="$WORK/n"; scratch_tree "$T"
jedit "$T/.mcp.json" 'd["mcpServers"]["extra"] = {"type": "stdio", "command": "dnx", "args": ["Extra", "--yes"]}'
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with a server only in .mcp.json, want 1: $OUT $ERR"
names "gemini-extension.json" && ok "names gemini-extension.json on stdout" || bad "stdout does not name gemini-extension.json: $OUT"

echo "== O. the live TOML commands are what Gemini CLI reads =="
if python3 - "$REPO" > "$WORK/o.out" 2>&1 <<'PY'
import pathlib, re, sys, tomllib
repo = pathlib.Path(sys.argv[1])
mds = sorted((repo / "commands").glob("*.md"))
assert mds, "no commands/*.md"
for md in mds:
    toml = md.with_suffix(".toml")
    data = tomllib.loads(toml.read_text(encoding="utf-8"))
    assert set(data) == {"description", "prompt"}, f"{toml.name}: keys {sorted(data)}"
    assert "$ARGUMENTS" not in data["prompt"], f"{toml.name}: $ARGUMENTS survived"
    # A bare $<digit> that survived, or a digit trailing {{args}} (what an un-refused "$1N" leaves
    # behind once ".replace(\"$1\", \"{{args}}\")" eats the "$1" and strands the "N" — #555) — either
    # shape means a positional token was mangled instead of refused.
    assert not re.search(r"\$\d|\{\{args\}\}\d", data["prompt"]), \
        f"{toml.name}: a positional token survived or was mangled — Gemini fills only {{args}}"
m = tomllib.loads((repo / "commands" / "migrate.toml").read_text(encoding="utf-8"))
want = "Run the full seven-phase legacy upgrade pipeline (assess → verified production) powered by RoselineMCP"
assert m["description"] == want, m["description"]
assert "{{args}}" in m["prompt"], "migrate.toml: no {{args}} in the prompt"
PY
then ok "every commands/*.md has a TOML twin with description and prompt, and {{args}} for \$ARGUMENTS"
else bad "the TOML commands: $(cat "$WORK/o.out")"; fi

echo "== O2. a command body reading \$10+ is refused as no verdict, not silently mangled =="
T="$WORK/o2"; scratch_tree "$T"
printf -- '---\ndescription: scratch fixture for the $10 guard\n---\n\nSet a timer for $10 minutes.\n' \
  > "$T/commands/tenplus.md"
run_check "$T"
[ "$RC" -eq 2 ] && ok "exit 2, no verdict" || bad "exit $RC with a \$10 command body, want 2: $OUT $ERR"
case "$ERR" in *'$10'*) ok "names the token, \$10, on stderr" ;; *) bad "stderr does not name \$10: $ERR" ;; esac
no_traceback "a \$10 command body"

echo "== P. gemini-extension.json, as Gemini CLI documents it =="
if python3 - "$REPO" > "$WORK/p.out" 2>&1 <<'PY'
import json, pathlib, sys
ext = json.loads((pathlib.Path(sys.argv[1]) / "gemini-extension.json").read_text(encoding="utf-8"))
assert ext["name"] == "tagout", ext["name"]
assert ext["contextFileName"] == "AGENTS.md", ext["contextFileName"]
import yaml
want_desc = yaml.safe_load((pathlib.Path(sys.argv[1]) / ".github/repo-setup.yml").read_text(encoding="utf-8"))["settings"]["description"]
assert ext["description"] == want_desc, "gemini-extension.json's description is the repository's (Gemini ships the whole kit), got: " + ext["description"]
assert "No bundled MCP server" not in ext["description"], ext["description"]
assert ext["mcpServers"]["roseline"] == {"command": "dnx", "args": ["RoselineMCP", "--yes"]}, ext["mcpServers"]
assert ext["mcpServers"]["adr"] == {"command": "dnx", "args": ["AdrMcp", "--yes"]}, ext["mcpServers"]
PY
then ok "name, AGENTS.md as context, and the two dnx servers without a type key"
else bad "gemini-extension.json: $(cat "$WORK/p.out")"; fi

echo "== Q. package.json declares the skills for pi, and stays private =="
[ "$(jq -r '.pi.skills[0]' "$REPO/package.json" 2>/dev/null)" = "./skills" ] \
  && [ "$(jq -r '.private' "$REPO/package.json" 2>/dev/null)" = "true" ] \
  && ok "pi.skills is ./skills and the package is private" || bad "package.json does not declare pi.skills ./skills, private"

echo "== R. README.md missing a plugin host's install line =="
T="$WORK/r"; scratch_tree "$T"
grep -vF 'gemini extensions install' "$REPO/README.md" > "$T/README.md"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with Gemini's line gone from README.md, want 1: $OUT $ERR"
names "README.md" && ok "names README.md on stdout" || bad "stdout does not name README.md: $OUT"
names "gemini-cli" && ok "names the host, gemini-cli" || bad "stdout does not name the host: $OUT"

echo "== S. a host table row naming an adapter that does not exist =="
T="$WORK/s"; scratch_tree "$T"
sed 's#adapter: package.json#adapter: nope.json#' "$REPO/docs/_data/hosts.yml" > "$T/docs/_data/hosts.yml"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with a missing adapter, want 1: $OUT $ERR"
names "nope.json" && ok "names the missing adapter on stdout" || bad "stdout does not name nope.json: $OUT"

echo "== T. the manifests name what their hosts load, and both marketplaces the same plugin =="
if python3 - "$REPO" > "$WORK/t.out" 2>&1 <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
def load(rel): return json.loads((root / rel).read_text(encoding="utf-8"))
transition = load(".claude-plugin/plugin.json")
assert transition["name"] == "ai-migration-kit" and transition["hooks"] == "./hooks/claude-hooks.json", "the root manifest is the transition one (#618): the whole kit under its old name until 3.0.0"
assert load("plugins/tagout/.claude-plugin/plugin.json")["hooks"] == "./hooks/tagout-hooks.json", "tagout manifest hooks"
assert load("plugins/tagout-migrate/.claude-plugin/plugin.json")["hooks"] == "./hooks/tagout-migrate-hooks.json", "tagout-migrate manifest hooks"
assert not (root / "plugins" / "tagout" / ".mcp.json").exists(), "the lifecycle plugin ships no .mcp.json"
codex = load(".codex-plugin/plugin.json")
assert (codex["skills"], codex["hooks"], codex["mcpServers"]) == ("./skills/", "./hooks/claude-hooks.json", "./.mcp.json"), codex
copilot = load(".github/plugin/plugin.json")
assert (copilot["skills"], copilot["mcpServers"]) == ("skills/", ".mcp.json"), copilot
assert "hooks" not in copilot and "commands" not in copilot, "Copilot's manifest names no hooks and no commands"
for rel in (".claude-plugin/marketplace.json", ".agents/plugins/marketplace.json"):
    market = load(rel)
    assert market["name"] == "tagout-marketplace", (rel, market["name"])
    assert market["plugins"][0]["name"] == "tagout", (rel, market["plugins"][0]["name"])
claude = load(".claude-plugin/marketplace.json")["plugins"]
assert [(p["name"], p["source"]) for p in claude] == [("tagout", "./plugins/tagout"), ("tagout-migrate", "./plugins/tagout-migrate"), ("ai-migration-kit", "./")], claude
PY
then ok "Claude, Codex and Copilot manifests name their paths; both marketplaces are tagout-marketplace"
else bad "the manifests: $(cat "$WORK/t.out")"; fi

echo "== U. a TOML command whose .md is gone =="
T="$WORK/u"; scratch_tree "$T"
printf 'description = "retired"\nprompt = """x"""\n' > "$T/commands/retired.toml"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with an orphaned TOML command, want 1: $OUT $ERR"
names "commands/retired.toml" && ok "names commands/retired.toml on stdout" || bad "stdout does not name the orphan: $OUT"

echo "== V. package.json naming a pi skills folder that does not exist =="
T="$WORK/v"; scratch_tree "$T"
jedit "$T/package.json" 'd["pi"]["skills"] = ["./nope"]'
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with a missing pi skills folder, want 1: $OUT $ERR"
names "./nope" && ok "names the missing folder on stdout" || bad "stdout does not name ./nope: $OUT"

echo "== W. a RULE_COPIES entry with no host adapter =="
T="$WORK/w"; scratch_tree "$T"
sed '/^- id: cline$/,/^$/d' "$REPO/docs/_data/hosts.yml" > "$T/docs/_data/hosts.yml"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC with a dangling RULE_COPIES entry, want 1: $OUT $ERR"
names ".clinerules/tagout.md" && ok "names the dangling adapter on stdout" || bad "stdout does not name .clinerules/tagout.md: $OUT"

echo "== X. the two plugins' partition, one refusal per rule (#607) =="
T="$WORK/x1"; scratch_tree "$T"
rm -r "$T/plugins/tagout/skills/create-issue"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1 with a skill copied into no plugin" || bad "exit $RC, want 1: $OUT $ERR"
names "plugins/tagout/skills/create-issue is missing" && ok "names the missing copy" || bad "stdout does not name the missing copy: $OUT"
T="$WORK/x2"; scratch_tree "$T"
cp -R "$T/skills/migrate-legacy" "$T/plugins/tagout/skills/migrate-legacy"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1 with a migration skill under the lifecycle plugin" || bad "exit $RC, want 1: $OUT $ERR"
names "plugins/tagout ships skills/migrate-legacy" && ok "names the misplaced skill" || bad "stdout does not name the misplaced skill: $OUT"
T="$WORK/x3"; scratch_tree "$T"
printf 'A file no source in the tree ever wrote.\n' > "$T/plugins/tagout/skills/merge-pr/STRAY.md"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1 with a copy no source accounts for" || bad "exit $RC, want 1: $OUT $ERR"
names "plugins/tagout/skills/merge-pr/STRAY.md has no source in the tree" && ok "names the stray copy" || bad "stdout does not name the stray copy: $OUT"
T="$WORK/x4"; scratch_tree "$T"
cp "$REPO/.mcp.json" "$T/plugins/tagout/.mcp.json"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1 with an .mcp.json under the lifecycle plugin" || bad "exit $RC, want 1: $OUT $ERR"
names "plugins/tagout ships an .mcp.json" && ok "names the server file" || bad "stdout does not name the .mcp.json: $OUT"
T="$WORK/x5"; scratch_tree "$T"
printf 'Read `<kit>/samples/x` first.\n' > "$T/skills/merge-pr/SKILL.md"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1 with a <kit>/<path> nothing resolves" || bad "exit $RC, want 1: $OUT $ERR"
names "plugins/tagout lacks 'samples/x'" && ok "names the unresolved kit path and its plugin" || bad "stdout does not name samples/x: $OUT"
names "plugins/tagout-migrate lacks" && bad "asks the migration plugin for a lifecycle skill's path: $OUT" || ok "only the plugin that ships the skill is asked"

T="$WORK/x6"; scratch_tree "$T"
rm "$T/plugins/tagout/AGENTS.md"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1 with a required link gone" || bad "exit $RC, want 1: $OUT $ERR"
names "plugins/tagout/AGENTS.md is missing" && ok "names the missing required link" || bad "stdout does not name AGENTS.md: $OUT"
T="$WORK/x7"; scratch_tree "$T"
rm "$T/commands/migrate-verify.md" "$T/commands/migrate-verify.toml"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1 with a command copy whose source is gone" || bad "exit $RC, want 1: $OUT $ERR"
names "plugins/tagout-migrate/commands/migrate-verify.md has no commands/migrate-verify.md" && ok "names the orphan copy" || bad "stdout does not name the orphan copy: $OUT"
T="$WORK/x8"; scratch_tree "$T"
printf -- '---\ndescription: scratch fixture\n---\n\nRun the review-followups skill on $ARGUMENTS.\n' > "$T/commands/followups.md"
cp "$T/commands/followups.md" "$T/plugins/tagout/commands/followups.md"
python3 "$CHECK" --repo "$T" build > /dev/null 2>&1   # the TOML twin, so only the skill rule can fire
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1 with a command copy naming a skill its plugin lacks" || bad "exit $RC, want 1: $OUT $ERR"
names "plugins/tagout/commands/followups.md names skills/review-followups" && ok "names the command and the missing skill" || bad "stdout does not name the skill: $OUT"
T="$WORK/x9"; scratch_tree "$T"
grep -vF 'install tagout-migrate@' "$REPO/docs/_data/hosts.yml" > "$T/docs/_data/hosts.yml"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1 with a plugin no host installs" || bad "exit $RC, want 1: $OUT $ERR"
names "installs tagout-migrate" && ok "names the uninstallable plugin" || bad "stdout does not name tagout-migrate: $OUT"

echo "== Y. a plugin's generated files, edited by hand, are refused and rebuilt =="
T="$WORK/y"; scratch_tree "$T"
printf '\n' >> "$T/hooks/tagout-hooks.json"
printf '\nA line nobody generated.\n' >> "$T/plugins/tagout-migrate/commands/migrate.md"
printf '\n' >> "$T/plugins/tagout-migrate/.mcp.json"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC, want 1: $OUT $ERR"
names "hooks/tagout-hooks.json drifted from hooks/claude-hooks.json" && ok "names the hooks map and its source" || bad "stdout does not name the hooks map: $OUT"
names "plugins/tagout-migrate/commands/migrate.md drifted from commands/migrate.md" && ok "names the command copy and its source" || bad "stdout does not name the command copy: $OUT"
names "plugins/tagout-migrate/.mcp.json drifted from .mcp.json" && ok "names the .mcp.json copy and its source" || bad "stdout does not name the .mcp.json copy: $OUT"
run_check "$T" build
[ "$RC" -eq 0 ] && ok "build exits 0" || bad "build exited $RC: $ERR"
run_check "$T"
[ "$RC" -eq 0 ] && ok "check exits 0 after build" || bad "check exited $RC after build: $OUT"
python3 - "$REPO" > "$WORK/y.out" 2>&1 <<'PY' && ok "the lifecycle map carries every block but Read; the migration map carries Read alone" || bad "the hooks maps: $(cat "$WORK/y.out")"
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
full = json.loads((root / "hooks/claude-hooks.json").read_text(encoding="utf-8"))["hooks"]
life = json.loads((root / "hooks/tagout-hooks.json").read_text(encoding="utf-8"))["hooks"]
mig = json.loads((root / "hooks/tagout-migrate-hooks.json").read_text(encoding="utf-8"))["hooks"]
assert life["PreToolUse"] == [b for b in full["PreToolUse"] if b.get("matcher") != "Read"], life
assert mig == {"PreToolUse": [b for b in full["PreToolUse"] if b.get("matcher") == "Read"]}, mig
for ev in ("SessionStart", "Stop"):
    assert life[ev] == full[ev], ev
PY

echo "== Z. the plugin trees are generated FILES, not links (#619) =="
# Z1. the real repository carries no symlink under plugins/ — the defect itself, in one line.
if [ -n "$(git -C "$REPO" ls-files -s plugins | awk '$1 == "120000"')" ]; then
  bad "plugins/ carries a committed symlink (120000): a checkout without symlink support gets a text file where a skill belongs"
else ok "no committed symlink under plugins/"; fi
# Z2. every skill the two plugins ship is a real directory with a real SKILL.md — what the loader
# looks for, and what a Windows checkout of a symlink is NOT.
z2=0
for d in "$REPO"/plugins/*/skills/*/; do
  [ "$(basename "$d")" = "_shared" ] && continue
  [ -f "$d/SKILL.md" ] || { bad "$d has no SKILL.md — the loader discovers a skill by its directory"; z2=1; }
done
[ "$z2" -eq 0 ] && ok "every shipped skill is a directory carrying its SKILL.md"
# Z3. a copy edited by hand is drift, named with its source; build restores it.
T="$WORK/z3"; scratch_tree "$T"
printf '\nA line nobody generated.\n' >> "$T/plugins/tagout/skills/merge-pr/SKILL.md"
run_check "$T"
[ "$RC" -eq 1 ] && ok "exit 1 with an edited skill copy" || bad "exit $RC, want 1: $OUT $ERR"
names "plugins/tagout/skills/merge-pr/SKILL.md drifted from skills/merge-pr/SKILL.md" \
  && ok "names the edited copy and its source" || bad "stdout does not name the edited copy: $OUT"
run_check "$T" build
run_check "$T"
[ "$RC" -eq 0 ] && ok "check exits 0 after build" || bad "check exited $RC after build: $OUT"
# Z4. a symlink under plugins/ is refused by name. Skipped where the filesystem cannot make one —
# which is exactly the configuration this issue is about, and where git makes a text file instead.
T="$WORK/z4"; scratch_tree "$T"
if ln -s ../../../skills/merge-pr "$T/plugins/tagout/skills/relinked" 2>/dev/null && [ -L "$T/plugins/tagout/skills/relinked" ]; then
  run_check "$T"
  [ "$RC" -eq 1 ] && ok "exit 1 with a symlink under plugins/" || bad "exit $RC, want 1: $OUT $ERR"
  names "plugins/tagout/skills/relinked is a symlink" && ok "names the symlink" || bad "stdout does not name the symlink: $OUT"
else
  echo "  skip  symlink case — this filesystem grants no symlinks (the #619 configuration)"
fi
# Z5. a copy committed at a different mode than its source. The INDEX is the seam: on Windows the
# filesystem has no executable bit to read, so only `git ls-files -s` can tell these two apart.
T="$WORK/z5"; scratch_tree "$T"
if git -C "$T" init -q 2>/dev/null && git -C "$T" add -A 2>/dev/null \
   && git -C "$T" add --chmod=+x -- scripts/guard.sh 2>/dev/null; then
  run_check "$T"
  [ "$RC" -eq 1 ] && ok "exit 1 with a copy at another mode than its source" || bad "exit $RC, want 1: $OUT $ERR"
  names "plugins/tagout/scripts/guard.sh is committed 100644 where its source scripts/guard.sh is 100755" \
    && ok "names both modes and the git add --chmod that fixes it" || bad "stdout does not name the mode mismatch: $OUT"
  names "git add --chmod=+x plugins/tagout/scripts/guard.sh" && ok "names the fix" || bad "stdout does not name the fix: $OUT"
else
  echo "  skip  index-mode case — no usable git here"
fi

echo "== AA. gitignored junk a walk finds is not drift (#653) =="
# python3 leaves a `__pycache__` beside any script it imports, and .gitignore keeps it out of the
# repository — so a walk of the tree sees a file git would never ship. The check used to READ it
# (a .pyc is not UTF-8, so: no verdict) and to call the plugin's stray one an orphan, refusing an
# otherwise clean tree over junk. Both halves here: the source side and the plugin side.
T="$WORK/aa"; scratch_tree "$T"
mkdir -p "$T/skills/merge-pr/scripts/__pycache__" "$T/plugins/tagout/scripts/__pycache__"
printf '\363\377\376junk' > "$T/skills/merge-pr/scripts/__pycache__/x.cpython-313.pyc"
printf '\363\377\376junk' > "$T/plugins/tagout/scripts/__pycache__/x.cpython-313.pyc"
run_check "$T"
[ "$RC" -eq 0 ] && ok "a __pycache__ under skills/ and under a plugin is not drift" || bad "exit $RC over gitignored junk: $OUT $ERR"
no_traceback "a __pycache__ .pyc"

if [ "$fails" -eq 0 ]; then
  echo "PASS: host-adapters — live tree, edit, rebuild, missing folder, no source, CRLF, encodings, usage, front matter, hooks map, versions, Gemini commands and extension, pi, host table, manifest paths, orphans, plugin copies"
else
  echo "FAIL: host-adapters — $fails assertion(s) failed"; exit 1
fi
