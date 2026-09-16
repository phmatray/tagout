#!/usr/bin/env python3
"""harvest.py — the kit's failure signals, read out of previous sessions' transcripts (#397).

Read-only, stdlib-only, and it decides nothing: it walks the `.jsonl` transcripts under one or
more `~/.claude/projects/<dir>` directories — the top-level session files and every sub-agent
layout `skills/auto-dev/scripts/usage_report.py` discovers — and emits one record per SIGNAL,
attributed to the kit skill that was active at that point of the transcript. `review-sessions`
clusters the records, verifies them against the tree and applies the filing bar; this script only
reports what is there, the way `survey.sh` reports a queue and the supervisor decides.

Usage:
    python3 harvest.py [PROJECT_DIR ...] [--since YYYY-MM-DD] [--json | --markdown] [--kit-name NAME]

  PROJECT_DIR   one or more ~/.claude/projects/<encoded-cwd> directories. Default: the directory
                encoding THIS cwd, plus its `--claude-worktrees-*` siblings (a worktree session
                writes to its own directory, and a review of "this repo's sessions" wants both).
  --since       keep only records stamped on or after that date (UTC date of the transcript line).
  --json        one JSON object per line (the record shape below). --markdown: the tally (default).
                The two are exclusive.
  --kit-name    the plugin's name as it appears in skill ids and cache paths (default: tagout).

The never-wait phrase list is READ from the kit's own tests/auto-dev-never-wait/test.sh (three
directories above this file), never copied here: when that file is not there, no forbidden-wait
record is emitted and the tally's last-but-one line says so.

A record:
    {"kind", "skill", "session", "path", "ts", "excerpt", "tool", "detail", "count"}

kind ∈ tool-error      a Bash tool_result flagged is_error — not a harness `<tool_use_error>` — whose command named a kit path or script
       hook-deny       a PreToolUse deny from one of the kit's two gates (its reason prefix)
       forbidden-wait  an assistant turn in the never-wait shape a worker must never end on
       worker-report   a worker's final report line with STATUS PARTIAL | BLOCKED | FAILED
       suite-fail      a tool_result carrying a kit golden suite's FAIL: line
       guard-refusal   a guard's own "<name>: REFUSED | ALERT | REJECTED" line (guarded-*, tick-plan, make-worktree)
       harness-nudge   "[Request interrupted" or "[Your previous response had no visible output"

Every kind requires the kit to have been INVOKED, never merely mentioned. `tool-error` counts only a
Bash call's own failure — a harness `<tool_use_error>` (a dispatch-depth ceiling, a blocked `sleep`,
a permission rejection) or a non-Bash tool's error (Agent, Edit, Read, Grep, an MCP tool) is the
harness's mechanics, not the kit's. `hook-deny` requires `is_error`, so a test's own printed deny
line is not one. A `guard-refusal` needs a failing Bash call that ran the guard (see `invoked_guard`),
and `names_kit_path` counts `--kit-name` only as a standalone identifier, never as part of a longer
one — a dash-encoded transcript directory or a same-prefixed sibling directory included. And
`forbidden-wait`, `worker-report` and `harness-nudge` each require an UNQUOTED occurrence (see
`quoted`): the character just before the match, skipping `*`/`_` emphasis, must not be a quote mark
— a `Read`/`Grep`/`Glob` result, or prose that quotes a guard, a kit path or a pinned phrase,
produces none of the seven.

Exit 0 (records, or the explicit `no signals` line); 2 on a usage error or an unreadable directory
— never a traceback for a bad argument.

KNOWN LIMITS: `invoked_guard` requires the SAME Bash result to be flagged `is_error` and to name a
guard's basename in its command — a compound command (`cat notes.md && guarded-push.sh …`) whose
unrelated first part fails while a genuine guard call further along it also fails is not
distinguished from the guard's own failure; a `description` field never counts, only `command`.
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import sys

KIT_SKILLS = (
    "auto-dev", "create-issue", "debug-issue", "deliver-issue", "implement-issue", "merge-pr",
    "migrate-legacy", "profile-repo", "review-followups", "review-sessions", "setup-repo",
    "triage-backlog",
)
# A slash command is a skill's other front door; its file is not named after the skill.
COMMAND_SKILL = {
    "migrate": "migrate-legacy", "migrate-assess": "migrate-legacy", "migrate-verify": "migrate-legacy",
    "migrate-audit": "migrate-legacy", "migrate-followups": "review-followups",
    "auto-dev-worker": "auto-dev", "auto-dev-merge": "auto-dev",
}
# The six guard basenames (GUARD_BASENAMES, defined below GUARD_NAMES) plus every other kit script
# not a guard — one list, not two independently hand-kept spellings of the guard names.
NON_GUARD_KIT_SCRIPTS = (
    "plan-freshness.sh", "wait-ci.sh", "survey.sh", "reconcile.sh", "repo-profile.sh",
    "repo-setup.sh", "preflight.sh", "followups.py", "decide.sh", "wire-edges.sh", "merge-verdict.sh",
    "base-run-verdict.sh", "remote-branch-teardown.sh", "parent-decision-note.sh", "audit-inventory.sh",
    "report-dashboard.py", "usage_report.py", "rejected-adrs.sh", "harvest.py",
)
KIT_DIRS_ANYWHERE = ("skills/", "hooks/", "commands/")
KIT_DIRS_IN_KIT = ("scripts/", "tests/", "evals/")
HOOK_DENY_PREFIXES = (
    "Blocked by the git write-gate",
    "Blocked by the roseline gate",
)
# A main session's wording, then a sub-agent's, then a bare permission rejection — all the harness
# (or the person at the keyboard), never the kit.
HARNESS_REFUSAL_PREFIXES = (
    "This session is isolated in the worktree",
    "This agent is isolated in the worktree",
    "The user doesn't want to proceed with this tool use",
)
# The harness wraps some of its own synthetic errors — this refusal and its "Blocked by the …
# gate" denials included — in a `<tool_use_error>` tag (confirmed on real transcripts: 4 of 608
# "isolated in the worktree" tool_result bodies carry it). Strip it before either prefix check
# below, or a wrapped refusal falls through and is misfiled as a kit tool-error — the exact bug
# both checks exist to prevent.
TOOL_USE_ERROR_WRAP = "<tool_use_error>"


TOOL_USE_ERROR_CLOSE = "</tool_use_error>"


def unwrap(body):
    if not body.startswith(TOOL_USE_ERROR_WRAP):
        return body
    body = body[len(TOOL_USE_ERROR_WRAP):]
    if body.endswith(TOOL_USE_ERROR_CLOSE):
        body = body[: -len(TOOL_USE_ERROR_CLOSE)]
    return body


NUDGES = ("[Request interrupted", "[Your previous response had no visible output")
WORKER_REPORT_RE = re.compile(r"\bSTATUS:\s*(PARTIAL|BLOCKED|FAILED)\b")
SUITE_FAIL_RE = re.compile(r"^FAIL[: \[].*", re.M)
# Every guard names itself by a bare `TOOL=<name>` (never `<name>.sh`) and prints
# "<name>: REFUSED|ALERT|REJECTED — …" at the start of a line on stderr (a Bash result's
# "Exit code N\n" prefix still leaves it starting a line, so (?m)^ still matches). `plan-freshness`
# is left off this list: it prints a verdict ("STALE"/"FRESH"), never a refusal word, so it could
# never match here — it is not a guard in the sense CONTEXT.md defines one (it wraps no
# destructive git write).
GUARD_NAMES = ("guarded-commit", "guarded-push", "guarded-merge", "guarded-pr-merge", "tick-plan", "make-worktree")
GUARD_RE = re.compile(
    r"(?m)^(" + "|".join(re.escape(n) for n in GUARD_NAMES) + r"): (REFUSED|ALERT|REJECTED)\b")
# The six basenames as they appear ON A COMMAND LINE (with ".sh"), for invoked_guard below — a
# different spelling than GUARD_RE's, which matches what the guard PRINTS (bare name, no ".sh").
# Precompiled once: this is checked against every Bash tool_result in every transcript line.
GUARD_BASENAMES = tuple(n + ".sh" for n in GUARD_NAMES)
GUARD_BASENAME_RE = re.compile(
    "|".join(r"(?<![\w.-])" + re.escape(b) + r"(?![\w.-])" for b in GUARD_BASENAMES))
KIT_SCRIPTS = GUARD_BASENAMES + NON_GUARD_KIT_SCRIPTS


def invoked_guard(tool, is_error, touched):
    """True when `touched` (a Bash tool_use's `command` string) plausibly RAN a guard, never when a
    Read/Grep/Glob result merely quotes one. Every real guard refusal exits non-zero (checked against
    every guard script's own refusal path), so gating on the SAME result's `is_error` is the
    invocation signal, not a first-word "was this just a read command" heuristic: that heuristic both
    missed a compound command (`cat notes.md && guarded-push.sh …`, first word `cat`) and needed a
    growing allowlist of read-only command names to stay accurate."""
    if tool != "Bash" or not is_error or not touched:
        return False
    return bool(GUARD_BASENAME_RE.search(touched))


def never_wait_phrases(kit_root):
    """The phrase list tests/auto-dev-never-wait/test.sh pins — read at run time, never copied.

    Returns (phrases, source): source is `kit` when the suite was read, `none` when it is not there
    or pins nothing — then no forbidden-wait record can be emitted, and the tally says so rather
    than matching a phrase list this file would otherwise have to carry as a second copy."""
    suite = os.path.join(kit_root or "", "tests", "auto-dev-never-wait", "test.sh")
    try:
        with open(suite, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return [], "none"
    found = re.findall(r'^\s*"(I\'ll [^"]+)"\s*$', text, re.M)
    return found, ("kit" if found else "none")


def default_project_dirs(kit_name):
    home = os.path.expanduser("~")
    base = os.path.join(home, ".claude", "projects")
    enc = os.getcwd().replace("/", "-").replace(".", "-")
    # A worktree session encodes `<repo>--claude-worktrees-<name>`; strip our own suffix so the
    # repo directory and every worktree sibling are found from either kind of cwd.
    stem = enc.split("--claude-worktrees-")[0]
    cands = sorted(d for d in glob.glob(os.path.join(base, stem + "*")) if os.path.isdir(d))
    return cands


def discover_transcripts(proj):
    for p in sorted(glob.glob(os.path.join(proj, "*.jsonl"))):
        yield p, os.path.basename(p)[:-6]
    for p in sorted(glob.glob(os.path.join(proj, "*", "subagents", "*.jsonl"))):
        parent = os.path.basename(os.path.dirname(os.path.dirname(p)))
        yield p, parent + "/" + os.path.basename(p)[:-6]
    for p in sorted(glob.glob(os.path.join(proj, "*", "subagents", "workflows", "wf_*", "*.jsonl"))):
        parent = os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(p)))))
        yield p, parent + "/" + os.path.basename(p)[:-6]


def text_of(content):
    """The text of a content field: a string, or the text blocks of a list."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str):
                parts.append(b["text"])
            elif isinstance(b, str):
                parts.append(b)
        return "\n".join(parts)
    return ""


def excerpt_of(text, needle=None, width=160):
    if needle:
        i = text.find(needle)
        if i >= 0:
            start = text.rfind("\n", 0, i) + 1
            text = text[start:]
    return " ".join(text.split())[:width]


QUOTE_CHARS = ('"', "'", "`", "“", "‘")


def quoted(text, i):
    """True when `text[i:]` is being CITED, not asserted: walk left from `i - 1`, skipping `*`/`_`
    emphasis markers and ASCII space/tab padding, and check whether the next character is a quote
    mark. False at the start of `text` or on any other character. An escaped `\\"` ends in `"` and
    counts the same as a bare one. Deliberately not `.isspace()`: a newline is never skipped, so the
    walk cannot cross into a preceding line's unrelated quote mark."""
    j = i - 1
    while j >= 0 and text[j] in "*_ \t":
        j -= 1
    return j >= 0 and text[j] in QUOTE_CHARS


def names_kit_path(s, in_kit_repo, kit_names):
    if not s:
        return False
    for kit_name in kit_names:
        # A kit name counts only as a PATH SEGMENT or a skill-id prefix: not preceded by another
        # identifier character, and followed by "/", ":" or the end of its line. "~/.tagout" (the
        # documented clone path, AGENTS.md), "/tagout/2.7.0/skills/…" (the plugin cache) and a
        # mention on a line of its own all count; a dash-encoded cwd directory ("-Users-x-tagout")
        # does not, because the char before the name is "-"; neither does a same-prefixed sibling
        # ("tagout.bak", "tagout-archive") — nor, since the rename, the ordinary word in
        # "docs/tagout procedure.md": "tagout" is an industrial-safety term, and a bare-word match
        # would harvest a consumer's own files as kit failures (#611's review).
        if re.search(r"(?<![\w-])" + re.escape(kit_name) + r"(?=[/:]|$)", s, re.M):
            return True
    for d in KIT_DIRS_ANYWHERE:
        if d in s:
            return True
    if in_kit_repo:
        for d in KIT_DIRS_IN_KIT:
            if d in s:
                return True
    return any(name in s for name in KIT_SCRIPTS)


def skill_from_tool_use(block, kit_names):
    """The kit skill a Skill tool_use names, or None."""
    if block.get("name") != "Skill":
        return None
    inp = block.get("input") or {}
    skill = inp.get("skill") if isinstance(inp, dict) else None
    if not isinstance(skill, str):
        return None
    bare = skill.split(":")[-1]
    prefix = skill.split(":")[0] if ":" in skill else None
    if prefix and prefix not in kit_names:
        return None
    if bare in KIT_SKILLS:
        return bare
    return COMMAND_SKILL.get(bare)


def harvest_file(path, session, in_kit_repo, kit_names, phrases, since):
    records = []
    skipped = 0
    active = None
    tool_inputs = {}   # tool_use id → the string that names what it touched
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                o = json.loads(line)
            except Exception:
                skipped += 1
                continue
            if not isinstance(o, dict):
                skipped += 1
                continue
            t = o.get("type")
            if t not in ("user", "assistant"):
                continue
            ts = o.get("timestamp") or ""
            day = ts[:10]
            msg = o.get("message") if isinstance(o.get("message"), dict) else {}
            content = msg.get("content")

            def emit(kind, excerpt, tool=None, detail=None):
                if since and day and day < since:
                    return
                records.append({
                    "kind": kind, "skill": active or "unattributed", "session": session,
                    "path": path, "ts": ts, "excerpt": excerpt, "tool": tool, "detail": detail,
                    "count": 1,
                })

            if t == "assistant" and isinstance(content, list):
                for b in content:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "tool_use":
                        sk = skill_from_tool_use(b, kit_names)
                        if sk:
                            active = sk
                        inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                        # A Bash call's `touched` is its `command` alone, never a `description`
                        # alongside it — invoked_guard's contract is "named in the command that ran",
                        # and a guard basename mentioned only in a description would otherwise flip it.
                        if b.get("name") == "Bash" and isinstance(inp.get("command"), str):
                            touched = inp["command"]
                        else:
                            touched = " ".join(str(v) for v in inp.values() if isinstance(v, str))
                        tool_inputs[b.get("id")] = (b.get("name"), touched)
                    elif b.get("type") == "text" and isinstance(b.get("text"), str):
                        txt = b["text"]
                        for ph in phrases:
                            for m in re.finditer(re.escape(ph), txt):
                                if not quoted(txt, m.start()):
                                    emit("forbidden-wait", excerpt_of(txt, ph), None, ph)
                                    break
                            else:
                                continue
                            break
                        for m in WORKER_REPORT_RE.finditer(txt):
                            if not quoted(txt, m.start()):
                                emit("worker-report", excerpt_of(txt, "STATUS:"), None, m.group(1))
                                break
            elif t == "user":
                # A nudge (an interrupt, a "no visible output") counts only while a kit skill is
                # active: it is the kit's failure to attribute, not a user's change of mind in a
                # session the kit was never driving.
                if isinstance(content, str):
                    for n in NUDGES:
                        for m in re.finditer(re.escape(n), content):
                            if active and not quoted(content, m.start()):
                                emit("harness-nudge", excerpt_of(content, n), None, n)
                                break
                    continue
                if not isinstance(content, list):
                    continue
                for b in content:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "text" and isinstance(b.get("text"), str):
                        for n in NUDGES:
                            for m in re.finditer(re.escape(n), b["text"]):
                                if active and not quoted(b["text"], m.start()):
                                    emit("harness-nudge", excerpt_of(b["text"], n), None, n)
                                    break
                        continue
                    if b.get("type") != "tool_result":
                        continue
                    body = text_of(b.get("content"))
                    tool, touched = tool_inputs.get(b.get("tool_use_id"), (None, ""))
                    is_error = bool(b.get("is_error"))
                    unwrapped = unwrap(body)
                    if unwrapped.startswith(HARNESS_REFUSAL_PREFIXES):
                        continue   # the harness's own worktree isolation, not the kit
                    if is_error and any(unwrapped.startswith(p) or ("\n" + p) in unwrapped for p in HOOK_DENY_PREFIXES):
                        emit("hook-deny", excerpt_of(unwrapped), tool, "gate")
                        continue
                    g = GUARD_RE.search(body) if invoked_guard(tool, is_error, touched) else None
                    if g:
                        emit("guard-refusal", excerpt_of(body, g.group(0)), tool, g.group(1))
                        continue
                    sf = SUITE_FAIL_RE.search(body)
                    if sf and names_kit_path(body, in_kit_repo, kit_names):
                        emit("suite-fail", excerpt_of(sf.group(0)), tool, "FAIL")
                        continue
                    if (
                        is_error
                        and tool == "Bash"
                        and not body.startswith(TOOL_USE_ERROR_WRAP)
                        and names_kit_path(touched, in_kit_repo, kit_names)
                    ):
                        emit("tool-error", excerpt_of(body), tool, excerpt_of(touched, width=100))
    # Collapse a polled command into one record with a count.
    collapsed = {}
    for r in records:
        key = (r["kind"], r["skill"], r["session"], r["excerpt"][:120])
        if key in collapsed:
            collapsed[key]["count"] += 1
        else:
            collapsed[key] = r
    return list(collapsed.values()), skipped


def tally_markdown(records, sessions, skipped, source):
    info = f"skipped {skipped} unparseable line(s) · never-wait phrases: {source}"
    if not records:
        return f"{info}\nno signals across {sessions} session(s)\n"
    out = []
    by_skill = {}
    for r in records:
        by_skill.setdefault(r["skill"], {}).setdefault(r["kind"], []).append(r)
    for skill in sorted(by_skill):
        out.append(f"## {skill}\n")
        out.append("| kind | count | first | last | excerpt |")
        out.append("|---|---:|---|---|---|")
        for kind in sorted(by_skill[skill]):
            rs = by_skill[skill][kind]
            n = sum(r["count"] for r in rs)
            tss = sorted(r["ts"] for r in rs if r["ts"])
            first = tss[0][:19] if tss else "-"
            last = tss[-1][:19] if tss else "-"
            ex = rs[0]["excerpt"].replace("|", "\\|")
            out.append(f"| {kind} | {n} | {first} | {last} | {ex} |")
        out.append("")
    total = sum(r["count"] for r in records)
    out.append(info)
    out.append(f"signals: {total} across {sessions} sessions")
    return "\n".join(out) + "\n"


def main(argv):
    ap = argparse.ArgumentParser(description="the kit's failure signals, out of past transcripts", add_help=True)
    ap.add_argument("project_dirs", nargs="*")
    ap.add_argument("--since")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--markdown", action="store_true")
    # Comma-separated, current name first. The old name rides along by default so transcripts
    # recorded before the rename — "ai-migration-kit:<skill>" ids, a checkout still under
    # …/ai-migration-kit — keep counting (#611's review measured 138 records vs 101 without it);
    # drop it once they have aged out.
    ap.add_argument("--kit-name", default="tagout,ai-migration-kit")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    try:
        sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    except Exception:
        pass
    kit_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
    if args.json and args.markdown:
        print("usage: --json and --markdown are exclusive — pick one", file=sys.stderr)
        return 2
    if args.since:
        try:
            dt.date.fromisoformat(args.since)
        except ValueError:
            print(f"usage: --since takes YYYY-MM-DD, got {args.since!r}", file=sys.stderr)
            return 2
    kit_names = tuple(n.strip() for n in args.kit_name.split(",") if n.strip())
    dirs = args.project_dirs or default_project_dirs(kit_names[0])
    if not dirs:
        print("usage: no PROJECT_DIR given and none detected for this cwd under ~/.claude/projects", file=sys.stderr)
        return 2
    for d in dirs:
        # A directory that exists but cannot be listed would make glob() swallow the
        # PermissionError and report "no signals" with exit 0 — a missing answer read as a clean one.
        if not os.path.isdir(d) or not os.access(d, os.R_OK | os.X_OK):
            print(f"unreadable project dir: {d}", file=sys.stderr)
            return 2
    phrases, source = never_wait_phrases(kit_root)
    records, skipped, sessions = [], 0, 0
    for d in dirs:
        # A dash-encoded project dir ("-Users-x-repo-tagout") names the kit as a whole segment,
        # never as a substring: "-Users-x-tagout-procedures" is not the kit's own checkout.
        base = os.path.basename(os.path.abspath(d))
        in_kit_repo = any(re.search(r"(^|-)" + re.escape(n) + r"(-|$)", base) for n in kit_names)
        for path, session in discover_transcripts(d):
            sessions += 1
            rs, sk = harvest_file(path, session, in_kit_repo, kit_names, phrases, args.since)
            records.extend(rs)
            skipped += sk
    records.sort(key=lambda r: (r["skill"], r["kind"], r["ts"]))
    if args.json:
        for r in records:
            print(json.dumps(r, ensure_ascii=False))
        if not records:
            print(f"no signals across {sessions} session(s)", file=sys.stderr)
        return 0
    sys.stdout.write(tally_markdown(records, sessions, skipped, source))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
