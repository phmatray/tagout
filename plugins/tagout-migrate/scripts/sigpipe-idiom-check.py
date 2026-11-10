#!/usr/bin/env python3
"""sigpipe-idiom-check.py -- refuse a positive-match `grep -q` fed by a streaming producer (#391).

Why this exists. `awk '/a/,/b/' f | grep -qF x` under `set -o pipefail`: `grep -q` exits the
instant it matches and closes the read end of the pipe; a producer with a RANGE or a full-file
scan (awk's range pattern, `tail -n +N`, a diff --stat, ...) is often still writing when that
happens, gets SIGPIPE (141), and under `pipefail` that 141 -- not grep's real (successful) exit
code -- becomes the pipeline's status. A positive assertion spelled `PIPE || { FAIL; }` then
reports a failure that did not happen. Measured on `tests/survey/test.sh` case 12d: ~22% of runs
(#391).

#48 shipped the general doctrine (`tests/_lib.sh`'s `first_match`/`any_match`) and #123 widened one
anti-recurrence guard (`tests/xunit-v3/test.sh` section 10) -- but only for the literal producer
`find`, in three files. This gate generalises both: any streaming producer -- external, or the
shell's own `printf`/`echo` (see PRODUCERS) -- anywhere under `tests/`, `scripts/`, `skills/` and
`hooks/` (SCAN_ROOTS), fenced recipes in their markdown included.

THE SHAPE IT FLAGS: a line piping a producer into a `grep` call whose flags include `q`
(quiet -- exit on first match, the thing that races) -- including a producer wrapped in a `sudo`,
an `env`, or one or more `VAR=val` prefixes, and including the same shape one level inside a
`$(...)`/backtick substitution, recursively (#457). THE SHAPE IT DOES NOT FLAG: a `grep -q` that
is negated (`if !`, a leading `!`, `|| true`, `|| :` -- its non-match is the outcome nothing acts
on being wrong), a `grep -q` fed by a command SUBSTITUTION whose own interior has no such pipeline
(the substitution completes before `grep` starts, so there is nothing to race), a comment, or a
line tagged `sigpipe-repro`. The remedy is never `set +o pipefail`: `pipefail` is load-bearing everywhere else
in these suites, and suspending it per-site would reintroduce the swallowed-failure class #48
exists to stop. The remedy is the herestring idiom already used at `tests/lib/test.sh:425` --
capture the pipeline into a variable, then read the variable: `var=$(producer ...); grep -q ...
<<<"$var"`. A variable assignment has nothing to close early, so there is nothing left to race.

Ported alongside `scripts/pinned-literals-check.py` and its three structural siblings -- same
shape: `python3 scripts/sigpipe-idiom-check.py [dir]` exits 0 and prints nothing on a clean tree,
exits 1 naming every offending `path:line` plus the remedy, exits 2 on a usage error.

WHAT IT DELIBERATELY DOES NOT DO. It does not touch `pipefail`, rewrite a call site, or judge
whether a given pipeline has EVER actually raced -- that would need a producer whose output is
large enough, and slow enough, to still be writing when `grep` exits, which is exactly the kind of
thing that is fine 99% of the time and NOT fine on a loaded CI runner. The shape is the hazard;
this gate flags the shape.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

# `printf` and `echo` are on this list although they are shell builtins. The first version of this
# gate exempted them ("one small write, cannot race"), and that was measured wrong: bash's `printf`
# writes a multi-line argument in several writes, so `printf '%s\n' "$out" | grep -q first-line`
# loses the same race -- 3 failures in 3000 on a loaded machine for a 40-line value, every time
# once the value outgrows the pipe buffer -- and about 200 such assertions across 32 suites turned
# a parallel run of the whole plan red about every other time. A builtin gets no exemption: the
# remedy is the same herestring, and it costs nothing.
PRODUCERS = frozenset(
    "awk sed grep tail head sort uniq tr cat jq find git python3 xargs yq printf echo bash sh".split()
)


def is_producer(word):
    """A command whose output can still be in flight when `grep -q` exits.

    The named ones, plus anything that is plainly a script being run: a path held in a variable
    (`"$KIT/$GUARD" --help`), or a `.sh`/`.py` file. `bash "$script" --help | grep -q 'Exit codes:'`
    was the last shape seen failing in a parallel run -- a help text is several lines, and the
    match is on one of the first.
    """
    return word in PRODUCERS or word.startswith("$") or word.endswith((".sh", ".py"))

QUIET_LONG = frozenset(("--quiet", "--silent"))

# Where the shape is looked for. `skills/` and `hooks/` joined `tests/` and `scripts/` once the
# builtin exemption fell: a recipe an agent pastes from a skill reference races exactly like a
# suite does, and three did -- one of them the lookup that decides whether an issue already has a
# worktree, where a lost race reads as "no" and a second worktree gets created.
SCAN_ROOTS = ("tests", "scripts", "skills", "hooks")

SELF_PATH = "scripts/sigpipe-idiom-check.py"
FIXTURE_PREFIX = "tests/sigpipe-idiom/"

NEGATED_RE = re.compile(r"^\s*(if\s+)?!\s")
DISCARDED_RE = re.compile(r"\|\|\s*(true|:)\s*;?\s*$")
LEADING_KEYWORD_RE = re.compile(r"^\s*(if|elif|while|until)\s+")
ASSIGNMENT_TOKEN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# sudo(8) short options that take a following argument -- so producer_word() knows to skip the
# value too, not just the flag (`sudo -u user ...`, #457 review).
SUDO_FLAGS_WITH_ARG = frozenset(("-u", "-g", "-p", "-r", "-t", "-h", "-C", "-D", "-R", "-T", "-U"))

_MARK = "\x00"


def split_pipeline_clauses(line):
    clauses = []
    buf = []
    depth = 0
    in_squote = False
    in_dquote = False
    i, n = 0, len(line)

    def flush_clause():
        text = "".join(buf)
        buf.clear()
        clause = text.split(_MARK)
        if any(seg.strip() for seg in clause):
            clauses.append(clause)

    while i < n:
        c = line[i]
        if in_squote:
            buf.append(c)
            if c == "'":
                in_squote = False
            i += 1
            continue
        if in_dquote:
            if c == "\\" and i + 1 < n:
                buf.append(c)
                buf.append(line[i + 1])
                i += 2
                continue
            buf.append(c)
            if c == '"':
                in_dquote = False
            i += 1
            continue
        if c == "'":
            in_squote = True
            buf.append(c)
            i += 1
            continue
        if c == '"':
            in_dquote = True
            buf.append(c)
            i += 1
            continue
        if c == "(":
            depth += 1
            buf.append(c)
            i += 1
            continue
        if c == ")":
            depth = max(0, depth - 1)
            buf.append(c)
            i += 1
            continue
        if depth == 0:
            if c == ";":
                flush_clause()
                i += 1
                continue
            if c == "&" and ((i > 0 and line[i - 1] == ">") or (i + 1 < n and line[i + 1] == ">")):
                # `2>&1`, `>&2`, `&>file`: a redirection, not a clause separator. Splitting here
                # cut `script --help 2>&1 | grep -q …` in two and hid its producer.
                buf.append(c)
                i += 1
                continue
            if c == "&":
                flush_clause()
                i += 2 if (i + 1 < n and line[i + 1] == "&") else 1
                continue
            if c == "|":
                if i + 1 < n and line[i + 1] == "|":
                    flush_clause()
                    i += 2
                    continue
                buf.append(_MARK)
                i += 1
                continue
        buf.append(c)
        i += 1
    flush_clause()
    return clauses


def grep_dash_q(segment):
    tokens = segment.strip().split()
    if not tokens or tokens[0] != "grep":
        return False
    for tok in tokens[1:]:
        if tok == "--":
            break
        if tok in QUIET_LONG:
            return True
        if len(tok) > 1 and tok[0] == "-" and tok[1] != "-":
            if "q" in tok[1:]:
                return True
            continue
        if tok.startswith("--"):
            continue
        break
    return False


def producer_word(segment, is_clause_head):
    """The command word a pipeline clause actually runs -- skipping a leading `sudo`, a leading
    `env`, any run of `VAR=val` assignment tokens (in any order, repeated), and any flags on a
    `sudo`/`env` invocation itself (`sudo -u user env -i VAR=val cmd`) -- since none of those are
    the producer itself (#457)."""
    if is_clause_head:
        segment = LEADING_KEYWORD_RE.sub("", segment, count=1)
    tokens = segment.strip().split()
    i, n = 0, len(tokens)
    allow_flags = False
    while i < n:
        tok = tokens[i]
        if tok in ("sudo", "env"):
            i += 1
            allow_flags = True
            continue
        if ASSIGNMENT_TOKEN_RE.match(tok):
            i += 1
            allow_flags = False
            continue
        if allow_flags and tok.startswith("-") and tok != "-":
            i += 1
            if tok in SUDO_FLAGS_WITH_ARG and i < n:
                i += 1  # the flag's own value, e.g. the "user" in "-u user"
            continue
        break
    if i >= n:
        return ""
    first = tokens[i].strip("'\"`")
    return os.path.basename(first)


def _scan_paren_span(line, start):
    """Return the index just past the `)` that closes a `$(` opened right before `start`,
    tracking quotes *inside* the substitution so a literal `)` in `grep -q ')'` doesn't close it
    early (#457 review)."""
    n = len(line)
    depth = 1
    j = start
    in_sq = False
    in_dq = False
    while j < n and depth > 0:
        c = line[j]
        if in_sq:
            if c == "'":
                in_sq = False
            j += 1
            continue
        if in_dq:
            if c == "\\" and j + 1 < n:
                j += 2
                continue
            if c == '"':
                in_dq = False
            j += 1
            continue
        if c == "\\" and j + 1 < n:
            j += 2
            continue
        if c == "'":
            in_sq = True
        elif c == '"':
            in_dq = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        j += 1
    return j


def find_substitution_spans(line):
    """Return the interior text of every `$(...)` or `` `...` `` span in `line`, so the offending
    shape can be scanned one level inside a substitution instead of treating it as opaque (#457).
    A single-quoted region suppresses `$(...)`/backtick recognition entirely; a double-quoted
    region does not (bash still expands both inside one), so scanning continues through it rather
    than being swallowed by it -- the fix for a same-line apostrophe (`echo "don't fail"; ...`)
    being misread as opening a single-quoted region (#457 review)."""
    spans = []
    i, n = 0, len(line)
    in_squote = False
    in_dquote = False
    while i < n:
        c = line[i]
        if in_squote:
            if c == "'":
                in_squote = False
            i += 1
            continue
        if in_dquote:
            if c == "\\" and i + 1 < n:
                i += 2
                continue
            if c == '"':
                in_dquote = False
                i += 1
                continue
        elif c == "\\" and i + 1 < n:
            i += 2
            continue
        elif c == "'":
            in_squote = True
            i += 1
            continue
        elif c == '"':
            in_dquote = True
            i += 1
            continue
        if c == "$" and i + 1 < n and line[i + 1] == "(":
            j = _scan_paren_span(line, i + 2)
            spans.append(line[i + 2 : j - 1])
            i = j
            continue
        if c == "`":
            j = line.find("`", i + 1)
            if j == -1:
                break
            spans.append(line[i + 1 : j])
            i = j + 1
            continue
        i += 1
    return spans


def offending_line(line):
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        return False
    if "sigpipe-repro" in line:
        return False
    if NEGATED_RE.match(line):
        return False
    if DISCARDED_RE.search(line.rstrip()):
        return False

    for clause in split_pipeline_clauses(line):
        if len(clause) < 2:
            continue
        if not grep_dash_q(clause[-1]):
            continue
        for idx, segment in enumerate(clause[:-1]):
            if is_producer(producer_word(segment, is_clause_head=(idx == 0))):
                return True

    # A `$(...)`/backtick substitution is opaque to split_pipeline_clauses (its paren-depth
    # tracking exists to stop `$(a | b)` being mis-read as a top-level pipe) -- but the offending
    # shape can sit one or more levels inside it, so recurse into each span's interior text with
    # the same check. A hazard found there is reported at the outer line's number (#457).
    for span in find_substitution_spans(line):
        if offending_line(span):
            return True
    return False


def _trailing_backslash_count(s):
    n = 0
    for ch in reversed(s):
        if ch != "\\":
            break
        n += 1
    return n


def _is_continuation(line):
    # A line ending in an ODD run of backslashes is a real shell line continuation; an even run
    # is that many literal backslashes (the last one escaped by its neighbour), continuing
    # nothing. A comment line's trailing `\` continues no shell statement either.
    if line.strip().startswith("#"):
        return False
    return _trailing_backslash_count(line) % 2 == 1


def logical_lines(text):
    """Yield (reporting_lineno, joined_text) -- a line-continued pipeline is joined into ONE
    logical line before matching, and reported at the line carrying the tail of the pipeline
    (where `grep -q` actually sits), per the shape a continued `producer | \\` / `  grep -q x`
    pipeline has: the reader is what closes early, and the reader is always last."""
    lines = text.splitlines()
    i, n = 0, len(lines)
    while i < n:
        if not _is_continuation(lines[i]):
            yield (i + 1, lines[i])
            i += 1
            continue
        group = []
        j = i
        while j < n and _is_continuation(lines[j]):
            seg = lines[j]
            group.append(seg[: -1] if seg.endswith("\\") else seg)
            j += 1
        if j < n:
            group.append(lines[j])
        last_idx = min(j, n - 1)
        yield (last_idx + 1, " ".join(group))
        i = j + 1


def tracked_files(repo):
    gitbin = "git"
    try:
        out = subprocess.run(
            [gitbin, "-C", str(repo), "ls-files", "-z", "--", *SCAN_ROOTS],
            capture_output=True, check=True,
        ).stdout
        names = [n for n in out.decode("utf-8", "replace").split("\0") if n]
        if names:
            return names
    except (OSError, subprocess.CalledProcessError):
        pass

    names = []
    for sub in SCAN_ROOTS:
        base = repo / sub
        if not base.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if d != ".git")
            for name in sorted(filenames):
                names.append(str(Path(dirpath, name).relative_to(repo)))
    return names


def main():
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.splitlines()[0])
    ap.add_argument("dir", nargs="?", default=".", help="repo root to scan (default: cwd)")
    args = ap.parse_args()

    repo = Path(args.dir).resolve()
    if not repo.is_dir():
        print("sigpipe-idiom-check: %s is not a directory." % repo, file=sys.stderr)
        return 2

    findings = []
    for rel in tracked_files(repo):
        if rel == SELF_PATH or rel.startswith(FIXTURE_PREFIX):
            continue
        path = repo / rel
        try:
            text = path.read_text(encoding="utf-8", errors="strict")
        except (OSError, UnicodeDecodeError):
            continue
        for lineno, joined in logical_lines(text):
            if offending_line(joined):
                findings.append((rel, lineno, joined.strip()))

    if not findings:
        return 0

    for rel, lineno, text in findings:
        print("%s:%d: %s" % (rel, lineno, text))
        print(
            "  remedy: capture the pipeline into a variable first, then read the variable via a "
            "herestring -- var=$(producer ...); grep -q ... <<<\"$var\" (tests/lib/test.sh:425). "
            "A variable assignment has nothing to close early, so there is nothing left to race."
        )
    return 1


if __name__ == "__main__":
    sys.exit(main())
