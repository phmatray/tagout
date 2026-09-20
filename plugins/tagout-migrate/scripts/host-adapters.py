#!/usr/bin/env python3
"""host-adapters.py — build, and check, the files that carry one of the kit's sources to another host.

Why this exists (#525, #526). The kit is written for Claude Code and reaches every other host through
adapters: rule copies of `AGENTS.md` for hosts that read a rules folder (Cursor, Windsurf, Cline,
Kiro, GitHub Copilot, Antigravity), and plugin manifests for hosts that install one (Codex, Copilot
CLI, Gemini CLI, Antigravity CLI, pi). Copies kept by hand drift, and the drift is silent: every
host still loads something, just yesterday's. ponytail, which ships the same shape to twenty hosts,
keeps its copies honest with a compare script (dietrichgebert/ponytail,
`scripts/check-rule-copies.js`). This is the kit's, with one difference: `build` WRITES every derived
file from its source, and `check` computes the same bytes in memory and refuses any file on disk
that differs — so a derived file is never edited, only rebuilt, and has exactly one author.

Two kinds of thing are checked:

  generated  `generated(repo)` returns {relative path: (source, text)} — the rule copies (from
             AGENTS.md), each `commands/<name>.toml` Gemini CLI reads (from `commands/<name>.md`),
             `gemini-extension.json` (from `plugins/tagout/.claude-plugin/plugin.json` and `.mcp.json`),
             and every file of the two Claude Code plugin trees (from the tree entry of the same
             relative name — ADR 0017, #619: a plugin directory ships real FILES, because git on a
             Windows checkout turns a symlink into a text file and the loader then finds no skill).
  invariants what cannot be generated but must hold (`invariants(repo, files)`, one REFUSE line each): the
             Claude hooks map stays off `hooks/hooks.json`, the path Gemini CLI and Copilot CLI
             auto-load in formats of their own; every plugin manifest carries the release-please
             version and is one of its `extra-files`; every path a manifest names resolves; every
             adapter the host table (`docs/_data/hosts.yml`) names exists; and every install line
             of a `tier: plugin` host appears in README.md, so the front page never lags the table.

Line endings: text is compared after CRLF -> LF, so a Windows checkout is not drift; `build` always
writes LF, the repository's own convention (`.gitattributes`).

Usage:
  host-adapters.py [--repo <path>] build
  host-adapters.py [--repo <path>] check

Exit codes:
  0  build wrote every generated file · check found every file in step and every invariant holding
  1  REFUSE (check) — one line per drifted file or broken invariant, naming it and the fix
  2  usage or plumbing — a source could not be read or parsed, so no verdict is possible. NOT a pass.
"""
import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys

FIX = "run python3 scripts/host-adapters.py build"

# (path, front matter). Each front matter is that host's own contract for an always-on rule:
# Cursor's .mdc `alwaysApply`, Windsurf's `trigger`, Kiro's steering `inclusion`. The other three
# hosts read a plain Markdown file.
RULE_COPIES = (
    (".cursor/rules/tagout.mdc",
     "---\n"
     "description: Tagout — which kit skill to use, how to load it, and its MCP servers\n"
     "alwaysApply: true\n"
     "---\n\n"),
    (".windsurf/rules/tagout.md", "---\ntrigger: always_on\n---\n\n"),
    (".clinerules/tagout.md", ""),
    (".kiro/steering/tagout.md", "---\ninclusion: always\n---\n\n"),
    (".github/copilot-instructions.md", ""),
)

# Every plugin manifest that carries a version. release-please bumps each through `extra-files`;
# one missing from that list is a manifest that silently stays behind on the next release.
VERSIONED = (
    "plugins/tagout/.claude-plugin/plugin.json",
    "plugins/tagout-migrate/.claude-plugin/plugin.json",
    ".claude-plugin/plugin.json",   # the TRANSITION manifest (#618): the whole kit under its old name until 3.0.0
    ".codex-plugin/plugin.json",
    ".github/plugin/plugin.json",
    "gemini-extension.json",
)

# The two plugin marketplace manifests, which carry no version of their own (#556) — named here so
# CI's JSON-validity check has one source for "every manifest the kit ships", the same way VERSIONED
# already is that source for the versioned ones.
UNVERSIONED_JSON = (
    ".claude-plugin/marketplace.json",
    ".agents/plugins/marketplace.json",
)

HOSTS = "docs/_data/hosts.yml"
OLD_HOOKS = "hooks/hooks.json"

# The two Claude Code plugins (ADR 0016), each a GENERATED COPY of the tree entries it ships (ADR
# 0017). The root is NOT a plugin: a `skills/` directory at a plugin root is always discovered in
# full and a manifest's `skills` list only ADDS (#607, measured), so the only way to ship ten skills
# of twelve is a root whose `skills/` holds exactly ten.
#
# Copies, not symlinks, since #619: git on Windows defaults to `core.symlinks=false` — it has no
# privilege to write one — so every linked entry was checked out as a TEXT FILE holding its target
# path, the loader found no skill directory at all, and an install offered its commands and nothing
# else. `build` writes the files; `check` refuses one that drifted, one whose source is gone, and
# any symlink that comes back.
PLUGINS = ("plugins/tagout", "plugins/tagout-migrate")
MIGRATION_PLUGIN = "plugins/tagout-migrate"
LIFECYCLE_PLUGIN = "plugins/tagout"
MIGRATION_SKILLS = frozenset({"migrate-legacy", "review-followups"})
MIGRATION_COMMANDS = re.compile(r"^migrate")
KIT_PATH = re.compile(r"<kit>/([A-Za-z0-9_./-]+)")
HOOKS_SOURCE = "hooks/claude-hooks.json"
# What every plugin directory must carry for its scripts and hooks to run from the installed copy —
# the kit root's own definition (AGENTS.md: skills/, scripts/, requirements.json) plus what the
# hooks read from ${CLAUDE_PLUGIN_ROOT}. An entry that goes missing is invisible to the copy loop
# (it only sees what the map names), so these are named.
REQUIRED_LINKS = ("skills", "scripts", "hooks", "AGENTS.md", "requirements.json")
# What BOTH plugins copy out of the tree beside their own skills: the shared doctrine their skills
# read, the scripts and hooks they call, and the manifests a skill resolves at runtime.
SHARED_COPIES = ("AGENTS.md", "CONTEXT.md", "decisions", "hooks", "requirements.json", "scripts",
                 "skills/_shared", "templates")
# What each plugin copies on its own account: the golden fixture its skills name as <kit>/tests/…,
# and — the migration plugin — the backlog and the Renovate config `review-followups` reads.
PLUGIN_EXTRAS = {
    LIFECYCLE_PLUGIN: ("tests/auto-dev-never-wait",),
    MIGRATION_PLUGIN: ("docs/backlog.md", "renovate.json", "tests/xunit-v3"),
}
# `__pycache__` is gitignored, so it is junk in the working tree rather than a source: copying it
# would turn a stray .pyc into `build`'s exit 2 for the whole repository, and READING one did the
# same to `check` on an otherwise clean tree — a .pyc is not UTF-8 (#653). Every walk in this file
# goes through `is_junk`, which is what keeps `build` and `check` agreeing about what is a source.
JUNK_DIRS = frozenset({"__pycache__"})


def is_junk(path):
    """A path a walk of the working tree finds but git never ships."""
    return bool(JUNK_DIRS & set(path.parts))
REPO_SETUP = ".github/repo-setup.yml"


class NoVerdict(Exception):
    """A source is unreadable or unparseable: exit 2, never a pass."""


# `$1` is a substring of `$10`, `$11`, … (and `$100`+), so the guard and the replacement below share
# this one regex-defined token boundary — a digit-string `in` check and a bare `.replace("$1", ...)`
# could (and did, #555) disagree about what counts as "the token $1".
POSITIONAL = re.compile(r"\$([1-9]\d*)")


def read_source(repo, rel):
    try:
        return (repo / rel).read_text(encoding="utf-8").replace("\r\n", "\n")
    except UnicodeDecodeError as exc:
        raise NoVerdict(f"{rel} is not UTF-8 ({exc.reason})") from exc
    except OSError as exc:
        raise NoVerdict(f"cannot read {rel}: {exc.strerror or exc}") from exc


def read_json(repo, rel):
    try:
        return json.loads(read_source(repo, rel))
    except json.JSONDecodeError as exc:
        raise NoVerdict(f"{rel} is not valid JSON: {exc}") from exc


def toml_command(repo, md_rel):
    """A Claude Code command (`commands/<name>.md`) as the TOML command Gemini CLI reads."""
    text = read_source(repo, md_rel)
    if not text.startswith("---\n") or "\n---\n" not in text[4:]:
        raise NoVerdict(f"{md_rel} has no front matter to read a description from")
    front, body = text[4:].split("\n---\n", 1)
    fields = dict(line.split(":", 1) for line in front.splitlines() if ":" in line)
    description = fields.get("description", "").strip()
    if not description:
        raise NoVerdict(f"{md_rel} front matter carries no description")
    # Claude Code fills `$ARGUMENTS` with the whole argument string and `$1` with the first; Gemini
    # has one placeholder, `{{args}}`. Every kit command takes a single argument, so both map to it
    # — and a command reading a second positional argument cannot be expressed at all.
    for match in POSITIONAL.finditer(body):
        if match.group(1) != "1":
            raise NoVerdict(f"{md_rel} reads ${match.group(1)} — Gemini commands take one argument, {{{{args}}}}")
    prompt = POSITIONAL.sub(lambda m: "{{args}}" if m.group(1) == "1" else m.group(0),
                             body.lstrip("\n").replace("$ARGUMENTS", "{{args}}"))
    # A TOML literal string cannot contain its own closing delimiter, and nothing can escape it.
    if "'''" in prompt:
        raise NoVerdict(f"{md_rel} contains ''' — it cannot be written as a TOML literal string")
    return (f"# Generated from {md_rel} by scripts/host-adapters.py — edit the .md and rebuild.\n"
            f"description = {json.dumps(description, ensure_ascii=False)}\n"
            f"prompt = '''\n{prompt}'''\n")


def hooks_map(repo, plugin):
    """The plugin's hooks map, split out of the one Claude map: the Read gate belongs to the
    migration plugin alone, every other block to the lifecycle plugin."""
    full = read_json(repo, HOOKS_SOURCE)
    is_read = lambda block: block.get("matcher") == "Read"
    hooks = {}
    for event, blocks in full.get("hooks", {}).items():
        keep = [b for b in blocks if is_read(b) == (plugin == MIGRATION_PLUGIN)]
        if keep:
            hooks[event] = keep
    return json.dumps({"hooks": hooks}, indent=2, ensure_ascii=False) + "\n"


def plugin_for_command(stem):
    return MIGRATION_PLUGIN if MIGRATION_COMMANDS.match(stem) else LIFECYCLE_PLUGIN


def repo_description(repo):
    """The repository's own description, from the repo-setup manifest — the one home of it."""
    try:
        import yaml  # PyYAML: a required prerequisite (requirements.json)
    except ImportError as exc:
        raise NoVerdict("PyYAML is not installed — see requirements.json") from exc
    try:
        manifest = yaml.safe_load(read_source(repo, REPO_SETUP)) or {}
    except yaml.YAMLError as exc:
        raise NoVerdict(f"{REPO_SETUP} is not valid YAML: {exc}") from exc
    description = (manifest.get("settings") or {}).get("description", "")
    if not description:
        raise NoVerdict(f"{REPO_SETUP} carries no settings.description for gemini-extension.json to use")
    return description


def gemini_extension(repo):
    """gemini-extension.json: the plugin's identity, AGENTS.md as context, `.mcp.json`'s servers.
    Gemini ships the WHOLE kit (both plugins' skills, commands and servers), so its description is
    the repository's, never one plugin's half."""
    plugin = read_json(repo, f"{LIFECYCLE_PLUGIN}/.claude-plugin/plugin.json")
    servers = read_json(repo, ".mcp.json").get("mcpServers", {})
    # Gemini's server entries have no `type` (it infers stdio from `command`), and an empty `env`
    # says nothing — both are dropped so the block holds only what Gemini reads.
    mcp = {name: {k: v for k, v in cfg.items() if k != "type" and not (k == "env" and not v)}
           for name, cfg in servers.items()}
    ext = {
        "name": plugin["name"],
        "version": plugin["version"],
        "description": repo_description(repo),
        "contextFileName": "AGENTS.md",
        "mcpServers": mcp,
    }
    return json.dumps(ext, indent=2, ensure_ascii=False) + "\n"


def generated(repo):
    """Every file this script owns, computed from its source: {relative path: (source, text)}."""
    agents = read_source(repo, "AGENTS.md")
    files = {path: ("AGENTS.md", front + agents) for path, front in RULE_COPIES}
    for md in sorted((repo / "commands").glob("*.md")):
        md_rel = f"commands/{md.name}"
        files[f"commands/{md.stem}.toml"] = (md_rel, toml_command(repo, md_rel))
    files["gemini-extension.json"] = (f"{LIFECYCLE_PLUGIN}/.claude-plugin/plugin.json, {REPO_SETUP} and .mcp.json",
                                      gemini_extension(repo))
    # The two plugins' generated halves: a hooks map each, a copy of every command on its own side,
    # and the migration plugin's .mcp.json (the lifecycle plugin launches no server, so it has none).
    files["hooks/tagout-hooks.json"] = (HOOKS_SOURCE, hooks_map(repo, LIFECYCLE_PLUGIN))
    files["hooks/tagout-migrate-hooks.json"] = (HOOKS_SOURCE, hooks_map(repo, MIGRATION_PLUGIN))
    for md in sorted((repo / "commands").glob("*.md")):
        md_rel = f"commands/{md.name}"
        files[f"{plugin_for_command(md.stem)}/commands/{md.name}"] = (md_rel, read_source(repo, md_rel))
    files[f"{MIGRATION_PLUGIN}/.mcp.json"] = (".mcp.json", read_source(repo, ".mcp.json"))
    files.update(plugin_copies(repo, files))
    return files


def skill_names(repo):
    """Every skill in the one tree, by name — the partition's left-hand side."""
    root = repo / "skills"
    return sorted(d.name for d in root.iterdir() if d.is_dir()) if root.is_dir() else []


def plugin_for_skill(name):
    return MIGRATION_PLUGIN if name in MIGRATION_SKILLS else LIFECYCLE_PLUGIN


def copy_map(repo):
    """{plugin: the tree entries it copies}. Derived from the partition, never hand-listed: a skill
    added to `skills/` lands in exactly one plugin without anyone editing a second list."""
    return {plugin: sorted(SHARED_COPIES + PLUGIN_EXTRAS[plugin]
                           + tuple(f"skills/{name}" for name in skill_names(repo)
                                   if name != "_shared" and plugin_for_skill(name) == plugin))
            for plugin in PLUGINS}


def entry_files(repo, entry):
    """The files of one copied tree entry — git-first, as `pinned-literals-check.py` and
    `decision-check.py` already read the index rather than walking.

    A walk sees everything that is merely PRESENT: a conflicted merge's `.orig`, an editor's
    scratch file, a stray binary. `build` would copy each into both plugin trees and `check` would
    then refuse a clean tree over it, so the enumeration is what git would ship. The walk stays as
    the fallback for the golden suite's scratch fixtures, which are plain directories rather than
    repositories, and for a host with no usable git.
    """
    git = shutil.which("git")
    if git is not None:
        try:
            proc = subprocess.run([git, "-C", str(repo), "ls-files", "-z", "--", entry],
                                  capture_output=True, text=True, encoding="utf-8")
        except OSError:
            proc = None
        if proc is not None and proc.returncode == 0:
            tracked = sorted(p for p in proc.stdout.split("\0") if p)
            if tracked:
                return [repo / p for p in tracked]
    source = repo / entry
    if source.is_dir():
        return [p for p in sorted(source.rglob("*"))
                if p.is_file() and not is_junk(p)]
    return [source] if source.is_file() else []


def plugin_copies(repo, files):
    """Every file the two plugins copy out of the one tree — {plugin path: (source, text)}.

    The source of a copy is the tree entry of the SAME relative name, which is what makes the map
    checkable rather than a second hand-kept inventory. A copy whose source is itself generated (a
    plugin's hooks map) takes the text `generated()` just computed, never what is on disk: reading
    the file would leave the copy one `build` behind its own source, and `check` would refuse it
    right after a build that claimed to fix it.
    """
    copies = {}
    for plugin, entries in copy_map(repo).items():
        for entry in entries:
            if not (repo / entry).exists():
                raise NoVerdict(f"{plugin} copies {entry}, which does not exist")
            for path in entry_files(repo, entry):
                rel = path.relative_to(repo).as_posix()
                copies[f"{plugin}/{rel}"] = (rel, files[rel][1] if rel in files
                                             else read_source(repo, rel))
    return copies


def load_hosts(repo):
    try:
        import yaml  # PyYAML: a required prerequisite (requirements.json)
    except ImportError as exc:
        raise NoVerdict("PyYAML is not installed — see requirements.json") from exc
    try:
        hosts = yaml.safe_load(read_source(repo, HOSTS))
    except yaml.YAMLError as exc:
        raise NoVerdict(f"{HOSTS} is not valid YAML: {exc}") from exc
    if not isinstance(hosts, list):
        raise NoVerdict(f"{HOSTS} is not a list of hosts")
    return hosts


def invariants(repo, files):
    """Everything that must hold but is not generated — one REFUSE line per breach."""
    refusals = []
    if (repo / OLD_HOOKS).exists():
        refusals.append(f"REFUSE: {OLD_HOOKS} exists — Gemini CLI and Copilot CLI auto-load that path in "
                        f"formats of their own; the Claude map lives at hooks/claude-hooks.json")

    version = read_json(repo, ".release-please-manifest.json").get(".")
    extra = {entry.get("path") for entry in
             read_json(repo, "release-please-config.json")["packages"]["."].get("extra-files", [])}
    for rel in VERSIONED:
        manifest = read_json(repo, rel)
        if manifest.get("version") != version:
            refusals.append(f"REFUSE: {rel} is at version {manifest.get('version')!r}, the release-please "
                            f"manifest at {version!r} — never bump by hand; take the manifest's value")
        if rel not in extra:
            refusals.append(f"REFUSE: {rel} is not in release-please-config.json's extra-files — "
                            f"the next release would leave it behind")
    # A manifest's paths resolve from ITS root: the repo for the other hosts' manifests, the plugin
    # directory (through its symlinks) for the two Claude Code plugins.
    for base, rel in ((p, f"{p}/.claude-plugin/plugin.json") for p in PLUGINS):
        manifest = read_json(repo, rel)
        for key in ("skills", "hooks", "mcpServers"):
            target = manifest.get(key)
            if isinstance(target, str) and not (repo / base / target.removeprefix("./")).exists():
                refusals.append(f"REFUSE: {rel} names {key} {target!r}, which does not exist under {base}")
    for rel in (".claude-plugin/plugin.json", ".codex-plugin/plugin.json", ".github/plugin/plugin.json"):
        manifest = read_json(repo, rel)
        for key in ("skills", "hooks", "mcpServers"):
            target = manifest.get(key)
            if isinstance(target, str) and not (repo / target.removeprefix("./")).exists():
                refusals.append(f"REFUSE: {rel} names {key} {target!r}, which does not exist")
    refusals.extend(plugin_invariants(repo, files))
    refusals.extend(mode_invariants(repo, files))

    # A TOML command outlives a deleted .md otherwise — build never touches it again, and Gemini keeps
    # offering a command the kit no longer has.
    for toml in sorted((repo / "commands").glob("*.toml")):
        if not toml.with_suffix(".md").exists():
            refusals.append(f"REFUSE: commands/{toml.name} has no commands/{toml.stem}.md to be built "
                            f"from — delete it")
    for target in read_json(repo, "package.json").get("pi", {}).get("skills", []):
        if not (repo / target.removeprefix("./")).exists():
            refusals.append(f"REFUSE: package.json names pi skills {target!r}, which does not exist")

    readme = read_source(repo, "README.md")
    hosts = load_hosts(repo)

    # Forward check: every host adapter exists
    for host in hosts:
        hid = host.get("id", "?")
        adapter = host.get("adapter", "")
        if not adapter or not (repo / adapter).exists():
            refusals.append(f"REFUSE: {HOSTS} host {hid} names adapter {adapter!r}, which does not exist")
        if host.get("tier") == "plugin":
            for line in host.get("install", []):
                if line not in readme:
                    refusals.append(f"REFUSE: README.md does not carry {hid}'s install line: {line}")

    # Reverse check: every RULE_COPIES entry is named by some host adapter
    adapters = {host.get("adapter", "") for host in hosts}
    for rel, _front in RULE_COPIES:
        if rel not in adapters:
            refusals.append(f"REFUSE: RULE_COPIES names {rel!r}, which no {HOSTS} host names as its adapter")

    return refusals


def index_modes(repo):
    """{tracked path: index mode}, or None when git cannot answer (no git, no work tree — the
    scratch fixtures the golden suite builds are plain directories).

    The INDEX, never the filesystem, for the reason `ci-wiring-check.py` reads it too: the machine
    that commits a wrong mode is usually the one that cannot observe it. On Windows the filesystem
    has no executable bit at all, and a `120000` entry looks like an ordinary text file — the index
    is the only place either fact survives.
    """
    git = shutil.which("git")
    if git is None:
        return None
    try:
        proc = subprocess.run([git, "-C", str(repo), "ls-files", "-s", "-z"],
                              capture_output=True, text=True, encoding="utf-8")
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    modes = {}
    for entry in proc.stdout.split("\0"):
        if not entry:
            continue
        meta, _, path = entry.partition("\t")
        modes[path] = meta.split()[0]
    return modes


def mode_invariants(repo, files):
    """No tracked symlink under `plugins/`, and every copy committed at its source's mode.

    A `120000` under `plugins/` is #619 itself: git checks it out as a text file wherever symlinks
    are unavailable, and the plugin then loads nothing. An executable source copied as `100644` is
    the quieter half — the copy exists, and every `<kit>/scripts/…` call a skill makes against it
    fails at the shell instead.
    """
    modes = index_modes(repo)
    if modes is None:
        return []
    refusals = []
    for path, mode in sorted(modes.items()):
        if mode == "120000" and path.startswith("plugins/"):
            refusals.append(f"REFUSE: {path} is committed as a symlink (120000) — a plugin directory "
                            f"ships real files (ADR 0017), or a checkout without symlink support "
                            f"gets a text file where a skill belongs (#619); {FIX}, then "
                            f"`git add -A plugins`")
    for rel, (source, _text) in sorted(files.items()):
        if not rel.startswith("plugins/") or rel not in modes or source not in modes:
            continue
        if modes[rel] != modes[source]:
            refusals.append(f"REFUSE: {rel} is committed {modes[rel]} where its source {source} is "
                            f"{modes[source]} — fix: git add --chmod="
                            f"{'+x' if modes[source] == '100755' else '-x'} {rel}")
    return refusals


def plugin_invariants(repo, files):
    """The partition the two plugins keep (ADR 0016): every skill linked from exactly one plugin
    (`_shared` from both), every link pointing at its namesake in the tree, no server under the
    lifecycle plugin, and every `<kit>/<path>` a plugin's skills or the shared scripts name resolving
    inside that plugin. Also: every plugin links what its scripts and hooks need (REQUIRED_LINKS); a command copy
    whose source is gone, or that sits on the wrong side, is refused (check()'s byte comparison
    only sees copies generated() still emits); a command copy naming a skill its plugin does not
    link is refused; and every plugin is installable by a line in the host table."""
    refusals = []
    skills = sorted(d.name for d in (repo / "skills").iterdir() if d.is_dir()) if (repo / "skills").is_dir() else []
    for name in skills:
        expected = set(PLUGINS) if name == "_shared" else (
            {MIGRATION_PLUGIN} if name in MIGRATION_SKILLS else {LIFECYCLE_PLUGIN})
        for plugin in PLUGINS:
            present = (repo / plugin / "skills" / name).is_dir()
            if plugin in expected and not present:
                refusals.append(f"REFUSE: {plugin}/skills/{name} is missing — every skill is copied into "
                                f"{'both plugins' if name == '_shared' else 'exactly one plugin'}, and skills/{name} belongs to {plugin}")
            if plugin not in expected and present:
                refusals.append(f"REFUSE: {plugin} ships skills/{name}, which belongs to "
                                f"{(expected - {plugin}).pop()} — the two plugins are disjoint")
    hosts_install = " ".join(line for host in load_hosts(repo) if host.get("tier") == "plugin"
                             for line in host.get("install", []))
    for plugin in PLUGINS:
        root = repo / plugin
        if not root.is_dir():
            refusals.append(f"REFUSE: {plugin} does not exist")
            continue
        for rel in REQUIRED_LINKS:
            if not (root / rel).exists():
                refusals.append(f"REFUSE: {plugin}/{rel} is missing — the plugin's scripts and hooks read it from the installed copy")
        name = read_json(repo, f"{plugin}/.claude-plugin/plugin.json").get("name", "")
        if f"install {name}@" not in hosts_install:
            refusals.append(f"REFUSE: no install line in {HOSTS} installs {name} — a plugin nobody is told to install ships to nobody")
        # A command copy outlives its source, or lands on the wrong side, and nothing else notices:
        # generated() only emits copies for sources that still exist.
        for copy in sorted(root.glob("commands/*.md")):
            if not (repo / "commands" / copy.name).exists():
                refusals.append(f"REFUSE: {plugin}/commands/{copy.name} has no commands/{copy.name} to be built from — delete it")
            elif plugin_for_command(copy.stem) != plugin:
                refusals.append(f"REFUSE: {plugin}/commands/{copy.name} belongs to {plugin_for_command(copy.stem)} — delete it")
            else:
                # The skill a command dispatches must ship in the same plugin, or the slash command
                # names a skill that is not there.
                body = read_source(repo, f"{plugin}/commands/{copy.name}")
                for skill in skills:
                    if skill != "_shared" and re.search(r"(?<![\w-])" + re.escape(skill) + r"(?![\w-])", body) \
                            and not (root / "skills" / skill).exists():
                        refusals.append(f"REFUSE: {plugin}/commands/{copy.name} names skills/{skill}, which {plugin} does not link")
        # A plugin directory is generated output: nothing under it is a symlink, and nothing under it
        # is unaccounted for. The first is #619 coming back — a link the loader cannot follow on a
        # Windows checkout; the second is a copy that outlived the source it was written from, the
        # way an orphaned `commands/*.toml` outlives its `.md`.
        for path in sorted(p for p in root.rglob("*") if p.is_symlink() and not is_junk(p)):
            refusals.append(f"REFUSE: {plugin}/{path.relative_to(root).as_posix()} is a symlink — a "
                            f"plugin directory ships real files (ADR 0017); a checkout without "
                            f"symlink support gets a text file where a skill belongs (#619); {FIX}")
        for path in sorted(p for p in root.rglob("*")
                           if p.is_file() and not p.is_symlink() and not is_junk(p)):
            rel = f"{plugin}/{path.relative_to(root).as_posix()}"
            if rel not in files and rel != f"{plugin}/.claude-plugin/plugin.json":
                refusals.append(f"REFUSE: {rel} has no source in the tree — delete it; every other "
                                f"file a plugin directory carries is written by {FIX}")
        if plugin == LIFECYCLE_PLUGIN and (root / ".mcp.json").exists():
            refusals.append(f"REFUSE: {plugin} ships an .mcp.json — the lifecycle plugin launches no server (ADR 16)")
        # Every <kit>/<path> the plugin's own skills and the hooks name must exist under the plugin
        # once its links are followed. Deliberately NOT scanned: `skills/_shared/` (doctrine written
        # for the lifecycle skills — it names their guards, which the migration plugin has no use
        # for) and `scripts/` (a `<kit>/…` in a script is a comment about the tree, not a call — the
        # release-title gate's prose names the migration fixture). The plugin's own skills are where a
        # runtime path is spelled to be executed.
        # Read the TREE's copy of each skill this plugin ships, never the plugin's own: a copy that
        # has drifted is refused above by name, and reading it here would ask yesterday's text which
        # paths today's skill needs.
        scanned = []
        for name in skills:
            if name == "_shared" or plugin_for_skill(name) != plugin:
                continue
            scanned += [p for p in (repo / "skills" / name).rglob("*")
                        if p.is_file() and not is_junk(p)
                        and (p.suffix == ".md" or "scripts" in p.parts)]
        # Only the hook scripts this plugin's own map names — each hook ships in one plugin.
        hooks_map_rel = read_json(repo, f"{plugin}/.claude-plugin/plugin.json").get("hooks", "")
        map_rel = f"{plugin}/{hooks_map_rel.removeprefix('./')}" if hooks_map_rel else ""
        # A map the manifest names but that does not exist is already refused above, by name.
        map_text = read_source(repo, map_rel) if map_rel and (repo / map_rel).exists() else ""
        scanned += [repo / "hooks" / name for name in re.findall(r"hooks/([A-Za-z0-9_.-]+\.sh)", map_text)]
        seen = set()
        for path in scanned:
            # An unreadable source is no verdict (read_source raises NoVerdict), never a pass.
            text = read_source(repo, str(path.relative_to(repo)) if path.is_relative_to(repo) else str(path))
            for kit_rel in KIT_PATH.findall(text):
                kit_rel = kit_rel.rstrip(".")
                if kit_rel in seen:
                    continue
                seen.add(kit_rel)
                if not (root / kit_rel).exists():
                    shown = path.relative_to(repo) if path.is_relative_to(repo) else path
                    refusals.append(f"REFUSE: {plugin} lacks '{kit_rel}', which {shown} names as <kit>/{kit_rel}")
    return refusals


def build(repo):
    # A DIRECTORY symlink left over from before ADR 0017 (a rebase, a `git checkout <old-sha> --
    # plugins`, a hand-restored link) cannot be written through: `mkdir(parents=True)` succeeds
    # THROUGH it and `write_text` would land in the tree entry it points at, leaving `check`
    # refusing forever while `build` claims to have fixed it. So the links go first — `unlink`
    # removes the link, never its target.
    for plugin, entries in copy_map(repo).items():
        for entry in entries:
            link = repo / plugin / entry
            if link.is_symlink():
                link.unlink()
                print(f"removed the symlink {plugin}/{entry}")
    for rel, (source, text) in generated(repo).items():
        path = repo / rel
        if path.is_symlink():
            # #619's own residue: a link where a file belongs. `write_text` would follow it and
            # write THROUGH it, into the tree entry it points at.
            path.unlink()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")
        # A copy of an executable source is executable. On Windows `os.chmod` cannot say so and git
        # records 100644 anyway — `check`'s index-mode invariant names the `git add --chmod=+x` that
        # fixes it there, from the one platform that can see the mode.
        src = repo / source
        if os.name != "nt" and src.is_file() and os.stat(src).st_mode & 0o111:
            os.chmod(path, os.stat(path).st_mode | 0o111)
        print(f"wrote {rel}")
    return 0


def check(repo):
    refusals = []
    files = generated(repo)
    for rel, (source, want) in files.items():
        # A generated file that is missing or not UTF-8 is drift like any other — build rewrites it —
        # while a SOURCE that cannot be read is no verdict at all (read_source, exit 2).
        try:
            have = (repo / rel).read_text(encoding="utf-8").replace("\r\n", "\n")
        except FileNotFoundError:
            refusals.append(f"REFUSE: {rel} is missing — {FIX}")
            continue
        except UnicodeDecodeError:
            refusals.append(f"REFUSE: {rel} is not UTF-8 — {FIX}")
            continue
        except OSError as exc:
            raise NoVerdict(f"cannot read {rel}: {exc.strerror or exc}") from exc
        if have != want:
            refusals.append(f"REFUSE: {rel} drifted from {source} — {FIX}")
    refusals.extend(invariants(repo, files))
    for line in refusals:
        print(line)
    if refusals:
        return 1
    print(f"host-adapters: {len(files)} generated files in step with their sources; every invariant holds")
    return 0


def main():
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    sys.stderr.reconfigure(encoding="utf-8", newline="\n")
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", default=".", help="repo root (default: cwd)")
    ap.add_argument("command", choices=("build", "check"))
    args = ap.parse_args()  # a usage error exits 2 — argparse's code, and this script's
    repo = pathlib.Path(args.repo)
    if not repo.is_dir():
        print(f"host-adapters: no verdict — --repo {args.repo} is not a directory", file=sys.stderr)
        return 2
    try:
        return build(repo) if args.command == "build" else check(repo)
    except NoVerdict as exc:
        print(f"host-adapters: no verdict — {exc}", file=sys.stderr)
        return 2
    except (KeyError, TypeError, AttributeError) as exc:
        print(f"host-adapters: no verdict — a manifest is missing a field it must carry ({exc!r})",
              file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
