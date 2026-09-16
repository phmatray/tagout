#!/usr/bin/env python3
"""decision-check.py — every registered decision is single-homed, invoked, and unrestated by prose.

Why this exists (#208). A control-flow decision in this kit had TWO homes: `merge-verdict.sh`
encoded the whole Step 4 precedence, was pinned by fixtures and wired into CI — and nothing called
it, while `skills/merge-pr/SKILL.md` restated the same rule as a markdown table the agent applied by
hand. Two homes drift, and these two did: a `--jq` object construction renamed `behind_by` to
`behind` while the script still read `behind_by`, so the freshness guard read `null` forever. A
human reviewer caught it, not CI, and the twin defect one line below survived the fix — composed
exactly as Step 4 documented it, the verdict was `wait` for CLEAN, DIRTY and BLOCKED alike.

So a decision now gets ONE id, ONE program and ONE home, listed in `decisions/registry.json`.
`scripts/decide.sh` runs them. THIS script is what refuses the four ways that arrangement rots:

  * a second copy of the program                          (R1)
  * a program that no longer compiles, or cannot be
    pasted where it is pasted                             (R2, R3)
  * a vocabulary that has drifted from the registry, or
    branches whose causes are indistinguishable           (R4, R5)
  * a shape that stopped building what the program reads  (R6)   <- the live bug above
  * an owner that stopped invoking its own decision       (R7)
  * prose that re-enumerates the states the program tests (R8)
  * a registry that is not internally coherent            (R9)
  * a tracked executable that is neither registered nor
    recorded as deliberately not a decision               (R10)

Every program's text is obtained by running `scripts/decide.sh --program <id>`. That is deliberate:
one home for extraction. A second implementation of the marker walk here would agree with the
dispatcher right up until the day it did not, and the disagreement would surface as this guard
passing over a program nobody actually runs.

Scope for the prose rules (R7, R8): `skills/**/*.md`, `commands/**/*.md`, `.claude/skills/*.md`.
`docs/`, `ARCHITECTURE.md`, `README.md`, `tests/**`, `templates/**` and `samples/**` are OUT of
scope — they are human-facing, or fixtures that legitimately contain these tokens. `docs/decisions.md`
in particular explains R8 with an illustrative table, and a guard that refused its own documentation
would be uninstallable.

------------------------------------------------------------------ WHAT THIS GUARD CANNOT SEE

Stated here rather than left to be rediscovered, per the doctrine `tests/_lib.sh` states about its
own contract: a docstring promising prevention the code does not perform is worse than no
docstring, because it stops the next reader adding the check that is missing.

R8 catches ONE SHAPE: a decision written as a markdown table keyed, in its first column, on a small
set of literal tokens the program tests. It is blind by construction to a decision restated as prose
paragraphs, as a bulleted list (`SKILL.md`'s precedence-in-bullet-clothing is exactly that), as a
mermaid diagram, or as a table that names states in its *second* column. Of the ten issues in this
defect class it cannot see #175 (a mermaid hand-off chain), #161 (a function-ordering comment), #163
(two duplicated `case` statements inside isolated workflow `run:` shells), #158 (version literals),
#144 (a bash-3.2 emulator) or #170's own command-list restatement. An author who knows the rule can
trivially evade it. The claim is "this specific, already-observed restatement shape becomes
impossible", not "restatement becomes impossible".

And the counter-guard, closed by R10 (#252):

R1 proves everything IN the registry is real. R10 is the converse: every tracked executable
matching a pathspec in `scripts/tracked-exec-globs.txt` — `scripts/`, `skills/` and `hooks/`, bash
and python — must be either some decision's `program.path` (registered), or a key of the registry's
`not_decisions` map with a one-line reason (recorded). Anything in neither set is refused BY NAME.
That list is a file rather than a literal here because `scripts/parse-sweep.sh` needs the same
answer and had its own copy of it (#307, for #144); the four globs it replaces left `hooks/` and a
script at a skill's ROOT outside `E` entirely, which is how a live PreToolUse gate went unnoticed. Delete the
`merge.step4` row and paste the `mergeStateStatus` table back — the #252 escape this whole file
documented as its own known hole — and `merge-verdict.sh` drops out of both sets: R10 now refuses
it, naming the file and both remedies (register it, or record it).

There is still no discovery predicate for "this script is a decision", and a heuristic one would be
worse than the manifest: it would either miss the next decision or cry wolf on every helper, and
both teach the reader to stop believing it. R10 takes the `scripts/pinned-literals-check.py` shape
instead — a recorded-exception list, `not_decisions`, living in `decisions/registry.json` itself so
one file answers "what is a decision here?" in both directions.

WHAT R10 STILL CANNOT SEE: a `block` decision (a marked jq program pasted into a reference file,
never a standalone script) has no PATH to enumerate — R10 walks the filesystem for executables, and
a `block` program that nobody ever registers is invisible to it by construction, exactly as it was
before. R10 closes the exit (delete a row, keep the file); it does not close the never-entered case
for a `block`-shaped decision that was never given a row to begin with.

R6 is over-approximated on purpose in the direction of silence: a field constructed by a NESTED
object inside the shape counts as emitted, so R6 misses some real mismatches but never false-alarms.
A decision whose `shape` is null is not checked by R6 at all, and is printed BY ID as uncovered on
the success line — a guard that cannot answer must say so rather than serve silence as a pass.

R4, R5 and R8's TOKEN_RE derivation all read the program through `strip_comments` (see its own
docstring for what it does and its known, currently-unobserved limits): a comment that documents what
the program emits or tests is prose about the program, not a branch of it, and none of the three may
count it as one. This was NOT true of TOKEN_RE at first — an earlier draft left it reading the raw
text on the theory that a wider, comment-inflated token set only ever WIDENS R8's refusals, never
narrows them. That is true of R8's un-annotated-table path (`hit = found_tokens(cells,
tokens_by_id[did])`, more tokens can only mean more matches), but false of its ANNOTATED-table path
(`extra = run_candidates(cells, all_tokens) - tokens_by_id[ann]`): there the decision's OWN token set
is SUBTRACTED, so a comment-derived phantom token in a decision's own program can silently swallow a
real gap — an annotated table naming a state the program never actually tests, passing because a
comment happened to mention it. R2 (jq compiles) and R3 (no single quote) stay on the raw text
deliberately: both validate the program's literal, pasted-verbatim text, comments included, not a
derived vocabulary — stripping would validate a program CI never actually runs.

R6's READ_RE reads the same stripped view (#261), and its emit side (`emitted_keys`, fed the shape
`block`) does too (#274): both close the identical comment-as-phantom-token exposure R4/R5/R8 close,
and neither is a considered exception like R2/R3.

Usage:
  decision-check.py [--repo <path>] [--registry <path>]

Exit codes:
  0  every decision is well-formed, single-homed, invoked by its owner, and unrestated by prose —
     and every tracked executable is registered or recorded (R10)
  1  REFUSE — one or more of R1..R10. ALL failures are reported, never the first one only
  2  no verdict is possible — the registry is unreadable or not JSON, `decisions` is empty,
     `not_decisions` is not an object, a declared home cannot be read, or `decide.sh --program`
     could not produce a program (which is also how a missing `jq` arrives here)
"""

import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

# A decision id: a lowercase family, then at least one dotted segment. Matches the registry's own
# documented shape, and is checked rather than assumed because ids end up in filenames, log lines
# and `--only`-style filters where a stray space or capital is a silent miss.
ID_RE = re.compile(r"^[a-z][a-z0-9]*(\.[a-z0-9-]+)+$")

# The only index mode CI can execute a program at. Read from the INDEX, never the filesystem: a
# checkout with core.filemode=false reports its working copy as executable no matter what git
# actually recorded, which is what makes the defect invisible on the machine that introduced it.
REQUIRED_MODE = "100755"

# `verdict.source` values this kit can run. `exit-map` is the planned second kind (#170's local
# half, #163); it is validated here so that adding it later is a registry row plus a dispatcher
# branch, not a redesign — and so a row that declares it today goes red instead of being run as if
# it were JSON.
VERDICT_SOURCES = ("stdout-json",)

# Where a marked block may be copied to. The declared home is excluded from its own search.
COPY_ROOTS = ("skills", "scripts", "tests", "commands")

# The prose R7 and R8 read. Everything else is human-facing or a fixture — see the docstring.
PROSE_SCOPES = (("skills", "**/*.md"), ("commands", "**/*.md"), (".claude/skills", "*.md"))

# A field read at the HEAD of a path: `.foo`, but not `x.foo`, not `)[0].foo`, not `"a".foo`. The
# lookbehind is what keeps `merge-verdict.sh` and `registry.json` from parsing as field reads.
READ_RE = re.compile(r'(?<![A-Za-z0-9_)\]"])\.([A-Za-z_][A-Za-z0-9_]*)')

# `verdict:"x"` / `rule:"x"` inside a jq object construction. The `-` in the lookbehind matters:
# without it, `merge-verdict: cannot read ...` in an error message parses as a verdict literal.
VERDICT_LIT_RE = re.compile(r'(?<![A-Za-z0-9_-])verdict\s*:\s*"([^"]*)"')
RULE_LIT_RE = re.compile(r'(?<![A-Za-z0-9_-])rule\s*:\s*"([^"]*)"')

# R8's token derivation: every string compared against inside the program. Derived FROM THE PROGRAM,
# never listed in the registry, so the token list cannot drift away from the thing it describes.
TOKEN_RE = re.compile(r'[=!]=\s*"([^"]*)"')

# A shouted state literal in a table cell — `CLEAN`, `BEHIND`, `CHANGES_REQUESTED`, `MERGEABLE`.
# Only ever used INSIDE an annotated run, for the subset check; see `run_candidates`.
SHOUTED_RE = re.compile(r"(?<![A-Za-z0-9_-])([A-Z][A-Z0-9_]{3,})(?![A-Za-z0-9_-])")

ANNOTATION_RE = re.compile(r"^<!--\s*decided-by:\s*([^\s]+)\s*-->$")

# How far above a table run its annotation may sit. Three lines covers "blank line, comment, blank
# line" and nothing looser: an annotation five paragraphs up would not be read as belonging to the
# table by anyone editing it, so it must not be read that way here either.
ANNOTATION_LOOKBACK = 3


def strip_comments(text):
    """Strip a `#`-to-end-of-line comment from each line, without touching `#` inside a
    single- or double-quoted string.

    Feeds R4, R5 (VERDICT_LIT_RE / RULE_LIT_RE) and R8's TOKEN_RE derivation: those rules judge what
    a program EMITS or TESTS, and a comment documenting that (`# emits verdict:"stop" when …`) is
    prose about the program, not a branch of it — counting it invents a phantom cause R5 refuses
    for, or a phantom token that can hide a real R8 gap (a comment-derived token is SUBTRACTED on
    R8's annotated-table path, so a wider raw token set there is not the safe direction it is on R8's
    un-annotated path). R6's `emitted_keys()` reads this stripped view too, on the shape `block`
    rather than on `prog` (#274) — and single quotes MUST be tracked there: a shape block is
    ordinary bash/jq (`merge.step4`'s own registered shape embeds `gh api graphql -f query='…'`),
    never protected by R3's "no single quote" refusal the way a `kind=="block"` program is, so a `#`
    genuinely can hide inside one on shape text in a way it structurally cannot on `prog`.

    Every registered program is `#`-commented (jq and bash agree on that), so a line-oriented,
    quote-tracking scan handles every program this repo has today; tracking BOTH quote kinds
    independently (a quote of one kind is inert while a span of the other is open) also closes the
    inverse failure a single-quote-blind scanner has on `emitted_keys()`'s new caller: an odd number
    of `"` embedded inside a `'…'` string used to desync the double-quote parity and leave a genuine
    trailing `# comment` un-stripped — the exact phantom-emit bug #274 exists to close, reachable
    through a second quoting path.

    A third quoting path closed by the same bug family (#306): bash's standard idiom for embedding a
    literal apostrophe inside a single-quoted string, `'\''` (close the string, an escaped literal
    quote, reopen the string — e.g. `printf '%s' 'it'\''s'`), used to desync `in_sq` the same way —
    each of the idiom's two inner quote characters toggled `in_sq` on its own, leaving the scanner one
    toggle short by the end of the line and believing a string was still open. The scan special-cases
    the whole four-character span (closing `'`, the escaped `\'`, and the reopening `'`) as a single
    inert unit that leaves `in_sq` exactly as it was — a real close followed by a real reopen nets to
    no change — rather than letting its two literal `'` characters toggle independently. An earlier
    draft tracked backslash-escapes while *inside* a string instead, but that half-measure mishandled
    exactly the outside-a-string case this idiom lives in without being exercised by any registered
    program either way, so it was removed rather than kept as untested complexity (see
    `tests/decisions/test.sh`'s own doctrine: every rule here is proved by breaking a working kit,
    never by reading the guard and believing it) — the fix here only special-cases the specific `'\''`
    span, not backslash-escapes generally.

    Known gaps, none observed in a registered program — extend the scanner if one arrives, rather
    than special-casing a caller: a quoted string (either kind) spanning more than one physical line
    desyncs the per-line quote state, since it resets at every line break; a bare `#` from bash's
    `${#arr[@]}` / `$#` length idiom is read as a comment start; and a backslash-escaped quote
    occurring outside any already-open string (rather than the `'\''` close/reopen shape handled
    above) can still toggle the quote state unexpectedly.

    R6's READ_RE also reads this stripped view (#261).
    """
    out = []
    for line in text.split("\n"):
        in_dq = False
        in_sq = False
        cut = len(line)
        n = len(line)
        i = 0
        while i < n:
            ch = line[i]
            # The '\'' embedded-apostrophe idiom: while inside a single-quoted string, a closing `'`
            # immediately followed by an escaped literal quote (`\'`, 3 chars total — `line[i+1:i+3]`
            # is the escape pair) always closes the string here and consumes the escape pair without
            # letting its literal `'` retoggle `in_sq` — that retoggle is what desynced `in_sq` before
            # #306. Whatever follows is then read normally: a genuine reopening `'` (the common
            # `'\''` shape) toggles `in_sq` back on, netting to "unchanged", exactly as before; but
            # anything else — end of line, a bare char, a `#` — is now read with the CORRECT (closed)
            # state instead of being blindly swallowed as if a reopening quote were guaranteed to
            # follow.
            if ch == "'" and in_sq and line[i + 1 : i + 3] == "\\'":
                in_sq = False
                i += 3
                continue
            if ch == '"' and not in_sq:
                in_dq = not in_dq
            elif ch == "'" and not in_dq:
                in_sq = not in_sq
            elif ch == "#" and not in_dq and not in_sq:
                cut = i
                break
            i += 1
        out.append(line[:cut])
    return "\n".join(out)


class Unanswerable(Exception):
    """A condition under which no verdict is possible — exit 2, never a pass."""


# --------------------------------------------------------------------------------- the registry


def load_registry(path):
    """The registry document, and its `decisions` list, validated.

    Returns `(doc, decisions)` — the whole parsed document, not just the list — because R10 (#252)
    reads a second top-level key, `not_decisions`, from the same file. One document answers "what
    is a decision here?" in both directions; a function that discarded everything but `decisions`
    would force a second, separate read of the same file for the other half of that question.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise Unanswerable(f"cannot read the registry {path}: {exc}")
    try:
        doc = json.loads(text)
    except json.JSONDecodeError as exc:
        raise Unanswerable(f"{path} is not valid JSON: {exc}")
    if not isinstance(doc, dict):
        raise Unanswerable(f"{path} must be a JSON object, got {type(doc).__name__}")
    decisions = doc.get("decisions")
    if not isinstance(decisions, list) or not decisions:
        # The #45 refusal, one file over: reporting "all clean" over an empty manifest is how a
        # registry that lost its contents reads exactly like a registry with nothing to complain
        # about.
        raise Unanswerable(
            f"{path} declares no decisions — refusing to report 'all single-homed' over an "
            "empty set. An empty registry is not 'nothing to do'; it is a registry that lost "
            "its contents."
        )
    return doc, decisions


def load_not_decisions(doc, rel_registry):
    """The `not_decisions` map: `{<path>: <reason>}`, read from the same document as `decisions`.

    Absent entirely reads as `{}` — a registry that predates R10, or one with nothing yet recorded,
    is not a schema violation on its own; `check_r10` is what has an opinion about which paths that
    leaves uncovered. A present-but-malformed value (not an object) IS a plumbing error: there is no
    single row to blame it on, unlike a bad entry inside it, which `check_r10` refuses by key.
    """
    raw = doc.get("not_decisions", {})
    if not isinstance(raw, dict):
        raise Unanswerable(
            f"{rel_registry}: not_decisions must be an object of {{path: reason}}, got "
            f"{type(raw).__name__}"
        )
    return raw


# The bash that runs `decide.sh`, resolved rather than left to the OS to find (#623).
#
# `subprocess.run(["bash", ...])` hands argv[0] to the platform's own search. On Windows that is
# CreateProcess, which reaches System32's own bash.exe — the WSL launcher — before the Git
# Bash every other script in this kit runs under. WSL then sees neither `C:\...` (it eats the
# backslashes as escapes, so every separator vanishes from the path) nor `C:/...` (it wants
# /mnt/c/...), and the extraction fails with a 127 that reads like a missing dispatcher. Rewriting
# the path does not help — only naming the interpreter does. `shutil.which` honours PATH, so it
# finds the same bash the caller's shell would; on POSIX it resolves to the same /bin/bash a bare
# "bash" always did, which is why this changes nothing there.
BASH = shutil.which("bash") or "bash"


def program_text(repo, did):
    """The decision's program, obtained the one way this repo extracts a program."""
    decide = repo / "scripts" / "decide.sh"
    if not decide.is_file():
        raise Unanswerable(f"{decide} does not exist — there is no way to extract a program.")
    try:
        proc = subprocess.run(
            [BASH, str(decide), "--program", did],
            capture_output=True,
            text=True,
            encoding="utf-8",
            cwd=str(repo),
        )
    except OSError as exc:
        raise Unanswerable(f"could not run {decide}: {exc}")
    if proc.returncode != 0:
        raise Unanswerable(
            f"`decide.sh --program {did}` exited {proc.returncode}, so its program is unknown:\n"
            + "\n".join("    " + l for l in proc.stderr.strip().splitlines())
        )
    return proc.stdout


def index_modes(repo, paths):
    """The git INDEX mode of each path. Returns (modes, error); an unreadable index is an error.

    The filesystem mode is the wrong authority: `chmod +x` on a checkout with core.filemode=false
    never reaches the index, so the working copy reports itself executable while CI receives 100644
    and dies with "Permission denied". `-z` because git C-quotes any path it considers unusual,
    which would silently miss the lookup rather than refuse.
    """
    if not paths:
        return {}, None
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo), "ls-files", "-s", "-z", "--", *paths],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
    except OSError as exc:
        return {}, f"git is not available ({exc})"
    if proc.returncode != 0:
        return {}, proc.stderr.strip() or f"git ls-files exited {proc.returncode}"
    modes = {}
    for record in proc.stdout.split("\0"):
        if not record:
            continue
        meta, _, path = record.partition("\t")
        modes[path] = meta.split()[0]
    return modes, None


# ------------------------------------------------------------------------------ marked blocks


def marker_lines(marker):
    return f"# >>> decision {marker}", f"# <<< decision {marker}"


def extract_marked(text, marker):
    """The lines from the begin marker through the end marker, inclusive, or a reason it failed.

    Fixed-string PREFIX matching, the same rule `decide.sh` applies, so free text may follow the
    marker on its line — the shipped `ci.verdict` block carries an em-dash sentence naming the
    suite that runs it.
    """
    begin, end = marker_lines(marker)
    lines = text.splitlines()
    starts = [i for i, l in enumerate(lines) if begin in l]
    ends = [i for i, l in enumerate(lines) if end in l]
    if len(starts) != 1 or len(ends) != 1:
        return None, (
            f"found {len(starts)} '{begin}' and {len(ends)} '{end}'; each must appear exactly "
            "once. Two blocks means two homes for the gate, and a gate with two homes drifts."
        )
    if ends[0] < starts[0]:
        return None, f"'{end}' appears before '{begin}'"
    return "\n".join(lines[starts[0] : ends[0] + 1]), None


def marked_regions(text):
    """Line numbers (1-based, inclusive) covered by ANY `>>> decision` / `<<< decision` pair.

    R8 exempts them: those lines are the program itself, and a program that tests seven states is
    not prose restating them.
    """
    regions, open_at = [], None
    for n, line in enumerate(text.splitlines(), start=1):
        if "# >>> decision " in line and open_at is None:
            open_at = n
        elif "# <<< decision " in line and open_at is not None:
            regions.append((open_at, n))
            open_at = None
    if open_at is not None:
        regions.append((open_at, 10**9))
    return regions


def emitted_keys(block):
    """Top-level keys of every `{...}` object construction in the block, over-approximated.

    Over-approximated because a NESTED construction's keys count too: the walk does not track which
    braces are top-level for the shape as a whole, only which text sits inside a matched pair. That
    direction is chosen deliberately — R6 may therefore MISS a mismatch, but it will not invent one,
    and a guard that cries wolf gets disabled while a guard that occasionally stays quiet only
    fails to help.
    """
    keys = set()
    text = block
    i, n = 0, len(text)
    while i < n:
        if text[i] != "{":
            i += 1
            continue
        depth, j, quote = 0, i, None
        while j < n:
            ch = text[j]
            if quote:
                if ch == "\\":
                    j += 2
                    continue
                if ch == quote:
                    quote = None
            elif ch in "\"'":
                quote = ch
            elif ch in "{[(":
                depth += 1
            elif ch in "}])":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        if j >= n:
            break
        for part in _split_depth0(text[i + 1 : j]):
            key = _key_of(part)
            if key:
                keys.add(key)
        i += 1
    return keys


def _split_depth0(text):
    parts, depth, quote, buf = [], 0, None, []
    for ch in text:
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
        elif ch in "{[(":
            depth += 1
        elif ch in "}])":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append("".join(buf))
            buf = []
            continue
        buf.append(ch)
    parts.append("".join(buf))
    return parts


def _key_of(part):
    """`a` -> a, `a: .b` -> a, `.c` -> c. Anything else contributes no key."""
    head = part.split(":", 1)[0].strip()
    head = head.lstrip(".").strip()
    m = re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", head)
    return m.group(0) if m else None


# ------------------------------------------------------------------------------- prose scanning


def prose_files(repo):
    found = []
    for root, pattern in PROSE_SCOPES:
        base = repo / root
        if base.is_dir():
            found.extend(sorted(base.glob(pattern)))
    return found


def fence_flags(lines):
    """Per line: is this line inside a fenced code block? Toggling on any ``` line."""
    flags, inside = [], False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("```"):
            flags.append(False)  # the fence line itself is not content
            inside = not inside
            continue
        flags.append(inside)
    return flags


def table_runs(lines):
    """Maximal runs of >=2 consecutive lines starting with `|`, as (begin, end, first_cells)."""
    i, n = 0, len(lines)
    while i < n:
        if re.match(r"^\s*\|", lines[i]):
            j = i
            while j < n and re.match(r"^\s*\|", lines[j]):
                j += 1
            if j - i >= 2:
                cells = " | ".join(
                    l.split("|")[1] for l in lines[i:j] if len(l.split("|")) >= 3
                )
                yield i + 1, j, cells
            i = j
        else:
            i += 1


def annotation_for(lines, begin):
    """The id in a `<!-- decided-by: <id> -->` within ANNOTATION_LOOKBACK lines above the run."""
    for k in range(begin - 2, max(begin - 2 - ANNOTATION_LOOKBACK, -1), -1):
        m = ANNOTATION_RE.match(lines[k].strip())
        if m:
            return m.group(1)
    return None


def found_tokens(cells, tokens):
    """The tokens present in `cells`, matched on identifier boundaries.

    The boundaries are what keep `skips` from matching `skipped` and `cancel-in-progress` from
    matching `in_progress`. Without them the rule fires on ordinary English and gets turned off.
    """
    return {
        t
        for t in tokens
        if t
        and re.search(
            r"(?<![A-Za-z0-9_-])" + re.escape(t) + r"(?![A-Za-z0-9_-])", cells
        )
    }


def run_candidates(cells, all_tokens):
    """The state literals an ANNOTATED run enumerates, for R8's subset check.

    Two sources, and the second one is an interpretation this file owns rather than inherits: a
    token of any registered decision (so `skipped` and `cancelled` count), plus any SHOUTED
    identifier of four characters or more (so `MERGEABLE` and `BEHIND` count even though no program
    tests them — which is the entire point of the subset rule: prose may enumerate FEWER states than
    the program handles, never MORE).

    The cost, stated because it is real: an annotated table whose first column happens to shout an
    unrelated word gets refused. That is opt-in blast radius — only a run someone deliberately
    annotated is subject to it — and the remedy is to not shout in a first cell.
    """
    return found_tokens(cells, all_tokens) | set(SHOUTED_RE.findall(cells))


def invocation_re(did):
    """A CALL to the dispatcher for `did`, not a mention of it.

    The spelling accepted is `decide.sh <id>` or the `$DECIDE` variable an owner establishes for
    the same script, followed by the id. See the divergence note in `docs/decisions.md`: the
    criterion is "the owner INVOKES it", and a kit whose own convention is `"$GUARDS/guarded-*.sh"`
    reaches its scripts through a variable. The fence requirement is what carries the guarantee —
    prose naming a script is still not calling it.
    """
    dispatcher = r'(?:decide\.sh|"\$\{?DECIDE\}?"|\$\{?DECIDE\}?)'
    return re.compile(dispatcher + r"\s+" + re.escape(did) + r"(?![A-Za-z0-9_.-])")


# ------------------------------------------------------------------------------- R10: completeness

# `E` — the enumeration R10 holds complete — is whatever this pathspec set matches, and the set is
# DATA rather than a literal here (#307): `scripts/tracked-exec-globs.txt` is the ONE list, so
# `scripts/parse-sweep.sh` (#144's half, which has the identical gap for the identical reason) can
# read the same answer instead of keeping a second copy that drifts. See that file's header for the
# full reasoning, the format, and what git's pathspec globbing actually covers — its `*` crosses a
# `/`, unlike a shell glob's, which is why `skills/*.sh` needs no `**` to reach a skill's root, its
# `scripts/` subdirectory and any deeper nesting alike.
#
# What #252's four globs missed, and why it mattered: they were copied verbatim from the `git
# ls-files` invocation its own Problem section measured "32 executables" with, and that measurement
# never claimed to cover `hooks/`. A Claude Code gate that branches on `ROSELINE_GATE` and a
# launcher probe to allow or deny a Read was therefore outside `E` by construction — it needed
# neither a registry row nor a `not_decisions` record, and the guard never noticed it existed.
TRACKED_EXEC_GLOBS_FILE = pathlib.Path(__file__).resolve().parent / "tracked-exec-globs.txt"


def tracked_exec_globs(path=TRACKED_EXEC_GLOBS_FILE):
    """The pathspecs of `E`, read from the one list. Missing or empty is UNANSWERABLE, not empty.

    Resolved against THIS script, never against `--repo`: `E`'s shape is a property of the guard,
    exactly as the four literal globs it replaces were, and the scratch kits
    `tests/decisions/test.sh` builds carry no copy of the list to read.

    A missing or comment-only list would otherwise make R10 enumerate NOTHING and report every
    executable in the repo as covered — the #45 shape, a guard serving "all clean" over an empty
    set. So it raises instead: a guard that cannot answer has to say so.
    """
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise Unanswerable(f"could not read R10's pathspec list at {path}: {exc}")
    globs = tuple(s for s in (line.split("#", 1)[0].strip() for line in lines) if s)
    if not globs:
        raise Unanswerable(
            f"{path} declares no pathspecs — R10 would enumerate nothing and pass everything"
        )
    return globs


def tracked_executables(repo):
    """Every tracked path matching `tracked_exec_globs()` — the enumeration `E` R10 holds complete.

    `git ls-files`, not a filesystem walk: a walk would also see whatever this kit's OWN worktree
    convention plants under `.claude/worktrees/` (an agent's linked worktree, a full second
    checkout) and a path staged for deletion but still present on disk. `-z` so a spaced path
    round-trips intact; git's pathspec globbing does the matching itself (see
    `scripts/tracked-exec-globs.txt`'s own header on what that globbing actually covers), so the
    pathspecs are handed through verbatim rather than re-implemented.
    """
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo), "ls-files", "-z", "--", *tracked_exec_globs()],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
    except OSError as exc:
        raise Unanswerable(f"could not enumerate tracked executables for R10: {exc}")
    if proc.returncode != 0:
        raise Unanswerable(
            f"git ls-files exited {proc.returncode} while enumerating R10's scope: "
            f"{proc.stderr.strip()}"
        )
    return sorted(p for p in proc.stdout.split("\0") if p)


def check_r10(repo, rel_registry, registered_paths, not_decisions, refuse):
    """R10: every tracked executable is registered as a program or recorded as deliberately not
    one — the converse of R1. Let `E` be `tracked_executables(repo)`, `R` be `registered_paths`
    (every `program.path` of an `exec`-kind decision) and `N` be `not_decisions`'s keys.

    Refuses:
      * `E - R - N` non-empty  — an executable neither registered nor recorded, named individually.
      * `N ∩ R` non-empty      — a path cannot be both a registered program and a recorded
                                  non-decision; that is one file making two contradictory claims.
      * a key of `N` that does not exist on disk — a stale record outliving its file.
      * a `not_decisions` value that is empty or not a string — the reason IS the whole value of
        the record; a record with no reason verifies nothing.
    """
    tracked = tracked_executables(repo)

    for path, reason in sorted(not_decisions.items()):
        if not isinstance(reason, str) or not reason.strip():
            refuse("R10", rel_registry,
                   f"not_decisions[{path!r}] has no reason (or an empty one)",
                   "The reason is the whole value of the record — state why this executable is "
                   "deliberately not a decision, or remove the entry.")
        # `pathlib`'s `/` operator DISCARDS the left side the moment the right side is absolute —
        # `repo / "/etc/hosts"` is `Path("/etc/hosts")`, not an error — so an absolute key would
        # silently check a path on the real filesystem instead of inside the repo, and would also
        # never match a relative path out of tracked_executables(), leaving it permanently inert in
        # both directions. Every path in this registry is documented as repo-relative; refuse an
        # absolute one outright rather than let `is_file()` answer a question about the wrong root.
        if pathlib.PurePosixPath(path).is_absolute() or not (repo / path).is_file():
            refuse("R10", rel_registry,
                   f"not_decisions records '{path}', which no longer exists",
                   "A stale record outliving its file is a claim about this repo that is no "
                   "longer true. Delete the entry, or restore the file (paths here are always "
                   "repo-relative, never absolute).")
        if path in registered_paths:
            refuse("R10", rel_registry,
                   f"'{path}' is BOTH a registered program and recorded in not_decisions",
                   "One file, two contradictory claims. Remove it from whichever side is wrong: "
                   "if it is a decision's program, it cannot also be deliberately not one.")

    uncovered = sorted(set(tracked) - registered_paths - set(not_decisions))
    for path in uncovered:
        refuse("R10", path,
               "is neither a registered decision's program nor recorded in not_decisions",
               f"Register it — add a row to {rel_registry} naming this as some decision's "
               "program.path; or record it — add an entry under not_decisions there, "
               f'e.g. "{path}": "<why this is deliberately not a decision>".')


# ------------------------------------------------------------------------------------- the check


def check(repo, registry_path):
    rel_registry = _rel(repo, registry_path)
    doc, decisions = load_registry(registry_path)
    not_decisions = load_not_decisions(doc, rel_registry)
    failures = []

    def refuse(rule, where, message, *remedy):
        failures.append((rule, where, message, remedy))

    # ------------------------------------------------------------------- R9 registry integrity
    seen = {}
    for row in decisions:
        did = row.get("id")
        if not isinstance(did, str) or not ID_RE.match(did):
            refuse("R9", rel_registry, f"decision id {did!r} is missing or malformed",
                   "Ids match ^[a-z][a-z0-9]*(\\.[a-z0-9-]+)+$ — e.g. merge.step4.")
            continue
        if did in seen:
            refuse("R9", rel_registry, f"decision id '{did}' is declared more than once",
                   "One id, one program, one home. Two rows is two answers to one question.")
        seen[did] = row

    for did, row in seen.items():
        source = (row.get("verdict") or {}).get("source")
        if source not in VERDICT_SOURCES:
            refuse("R9", rel_registry,
                   f"'{did}' declares verdict.source={source!r}, which no dispatcher implements",
                   "Only 'stdout-json' exists in slice one. 'exit-map' is the planned extension "
                   "point and is deliberately NOT implemented — build it in decide.sh before "
                   "registering a row that needs it.")
        owner = row.get("owner")
        if not owner or not (repo / owner).is_file():
            refuse("R9", rel_registry, f"'{did}' names an owner that cannot be read: {owner!r}",
                   "The owner is the file that must INVOKE this decision (R7).")
        for suite in row.get("suites") or []:
            if not (repo / suite).is_file():
                refuse("R9", rel_registry, f"'{did}' names a suite that does not exist: {suite}",
                       "A suite listed but absent is an assertion nobody makes.")
        # Wiring of those suites is deliberately NOT re-checked here: ci-wiring-check.py already
        # guarantees every tests/<name>/test.sh is enforced by a step that can fail the build, and
        # one rule gets one implementation.

    # ------------------------------------------------------------- per-decision program checks
    programs, tokens_by_id, shaped = {}, {}, []
    exec_paths = []
    for did, row in seen.items():
        programs[did] = program_text(repo, did)
        prog = programs[did]
        prog_emitted = strip_comments(prog)
        tokens_by_id[did] = set(TOKEN_RE.findall(prog_emitted))
        kind = (row.get("program") or {}).get("kind")

        # ------------------------------------------------------------------------ R1 ONE HOME
        if kind == "exec":
            exec_paths.append((did, (row.get("program") or {}).get("path")))
        elif kind == "block":
            home = (row.get("program") or {}).get("home")
            marker = (row.get("program") or {}).get("marker")
            home_path = repo / home
            if not home_path.is_file():
                raise Unanswerable(f"'{did}' declares its home as {home}, which cannot be read.")
            begin, _end = marker_lines(marker)
            for other in _marker_copies(repo, begin, exclude=home_path):
                refuse("R1", _rel(repo, other),
                       f"a second copy of '{did}'s marked block lives here",
                       f"Its one home is {home}. Delete this copy — two homes for a gate is how "
                       "a gate drifts, and the copy that is not run is the one that goes wrong.")
            _text, err = extract_marked(home_path.read_text(encoding="utf-8"), marker)
            if err:
                refuse("R1", home, f"'{did}': {err}")

            # --------------------------------------------------- R2 IT COMPILES (block only)
            complaint = _jq_compiles(prog)
            if complaint is not None:
                refuse("R2", home, f"'{did}'s program does not compile:\n{complaint}",
                       "jq compiles the whole program before it reads any input, so this is a "
                       "pure parse failure — the program could never have run at all.")

            # ------------------------------------------------ R3 NO SINGLE QUOTE (block only)
            if "'" in prog:
                bad = [str(n) for n, l in enumerate(prog.splitlines(), 1) if "'" in l]
                refuse("R3", home,
                       f"'{did}'s program contains a single quote (line(s) {', '.join(bad)})",
                       "The block is pasted inside a shell `jq '…'` argument, so a single quote "
                       "closes that string early: the pasted snippet would not be the tested "
                       "snippet — it would not even run. Rewrite the line without one.")
        else:
            refuse("R9", rel_registry, f"'{did}' declares program.kind={kind!r}",
                   "Known kinds: exec (a script) and block (a marked jq program in a reference).")

        # ------------------------------------------------------------ R4 VOCABULARY IS EXACT
        declared = set((row.get("verdict") or {}).get("vocabulary") or [])
        emitted = set(VERDICT_LIT_RE.findall(prog_emitted))
        for word in sorted(emitted - declared):
            refuse("R4", _program_where(repo, row),
                   f"'{did}' can answer {word!r}, which is not in its declared vocabulary",
                   f"Add it to {rel_registry}, or stop emitting it. `decide.sh` REFUSES an "
                   "unregistered word at run time (exit 1), so shipping this is a broken gate.")
        for word in sorted(declared - emitted):
            refuse("R4", rel_registry,
                   f"'{did}' declares {word!r}, which no branch of its program can emit",
                   "A dead word in the vocabulary is a branch someone deleted without saying so. "
                   "Remove it, or restore the branch.")

        # ------------------------------------------------------------ R5 CAUSES ARE DISTINCT
        verdict_lits = VERDICT_LIT_RE.findall(prog_emitted)
        rule_lits = RULE_LIT_RE.findall(prog_emitted)
        if len(verdict_lits) != len(rule_lits):
            refuse("R5", _program_where(repo, row),
                   f"'{did}' has {len(verdict_lits)} verdict literal(s) but {len(rule_lits)} "
                   "rule literal(s)",
                   "Every branch names both. Without the rule name the event log cannot attribute "
                   "a cause, and two branches answering one word become indistinguishable.")
        dupes = sorted({r for r in rule_lits if rule_lits.count(r) > 1})
        if dupes:
            refuse("R5", _program_where(repo, row),
                   f"'{did}' reuses rule name(s): {', '.join(dupes)}",
                   "Rule names are the identity of a branch. Two branches sharing one name make "
                   "the event log's central signal — does this gate redden on ONE cause? — noise.")

        # -------------------------------------------------------------- R6 READS SUBSET EMITS
        shape = row.get("shape")
        if not shape:
            continue
        shaped.append(did)
        shome = repo / shape["home"]
        if not shome.is_file():
            raise Unanswerable(
                f"'{did}' declares its shape home as {shape['home']}, which cannot be read."
            )
        block, err = extract_marked(shome.read_text(encoding="utf-8"), shape["marker"])
        if err:
            refuse("R6", shape["home"], f"'{did}'s shape block: {err}")
            continue
        emits = emitted_keys(strip_comments(block))
        reads = set(READ_RE.findall(prog_emitted))
        missing = sorted(reads - emits)
        if missing:
            refuse("R6", shape["home"],
                   f"'{did}' reads {', '.join('.' + m for m in missing)}, which the shape block "
                   "does not build",
                   f"program: {_program_where(repo, row)}   shape: {shape['home']} "
                   f"(marker '{shape['marker']}')",
                   f"The shape builds: {', '.join(sorted(emits)) or '(nothing)'}.",
                   "This is the live bug that made this engine necessary: a renamed key on one "
                   "side only, read as null forever, with every test still green.")

    # --------------------------------------------------------------- R1, the index-mode half
    modes, mode_error = index_modes(repo, [p for _d, p in exec_paths if p])
    for did, path in exec_paths:
        if not path or not (repo / path).is_file():
            refuse("R1", rel_registry, f"'{did}' names a program that does not exist: {path!r}",
                   "Restore the file, or remove the row.")
            continue
        mode = modes.get(path)
        if mode is None:
            if not mode_error:
                refuse("R1", path, f"'{did}'s program is not in the git index",
                       "An untracked program is not what CI or a plugin install receives. "
                       f"`git add {path}`.")
        elif mode != REQUIRED_MODE:
            refuse("R1", path,
                   f"'{did}'s program is committed at index mode {mode}, not {REQUIRED_MODE}",
                   f"`git update-index --chmod=+x {path}` — a checkout with core.filemode=false "
                   "makes the working copy lie, so chmod alone never reaches the index, and "
                   "`decide.sh` refuses a program it cannot execute.")
    if mode_error:
        # Reported ALONGSIDE the rules above, never instead of them: the prose verdicts are
        # independent of git entirely, so an unreadable index must not hide an unrelated defect.
        refuse("R1", rel_registry, f"the git index could not be read: {mode_error}",
               "No program's executability is knowable. An unanswerable question is not a pass.")

    # ------------------------------------------------------------- R10 registry completeness
    registered_paths = {path for _did, path in exec_paths if path}
    check_r10(repo, rel_registry, registered_paths, not_decisions, refuse)

    # ---------------------------------------------------------------------- R7 and R8, prose
    all_tokens = set()
    for toks in tokens_by_id.values():
        all_tokens |= toks

    for did, row in seen.items():
        owner = row.get("owner")
        if not owner or not (repo / owner).is_file():
            continue  # already refused by R9
        lines = (repo / owner).read_text(encoding="utf-8").splitlines()
        flags = fence_flags(lines)
        pattern = invocation_re(did)
        if not any(flag and pattern.search(line) for line, flag in zip(lines, flags)):
            refuse("R7", owner,
                   f"is the registered owner of '{did}' but never invokes it",
                   "Prose naming a script is not calling it. Put the call inside a fenced code "
                   f"block, e.g. `\"$DECIDE\" {did}` or `scripts/decide.sh {did}`.",
                   "Without this rule a contributor can delete the invocation, re-derive the "
                   "verdict by hand, and every other rule here stays green.")

    for path in prose_files(repo):
        rel = _rel(repo, path)
        text = path.read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()
        exempt = marked_regions(text)
        for begin, end, cells in table_runs(lines):
            if any(a <= begin and end <= b for a, b in exempt):
                continue
            ann = annotation_for(lines, begin)
            if ann is None:
                for did in seen:
                    hit = found_tokens(cells, tokens_by_id[did])
                    if len(hit) >= 2:
                        refuse("R8", f"{rel}:{begin}-{end}",
                               f"this table re-enumerates states '{did}' tests: "
                               f"{', '.join(sorted(hit))}",
                               "The program owns WHICH correction; a table may own HOW to apply "
                               "one, keyed on the VERDICT words, never on the states. Delete the "
                               f"enumeration, or — if it explains something no program can — put "
                               f"`<!-- decided-by: {did} -->` on its own line just above the "
                               "table, which costs you the freedom to name a state the program "
                               "does not test.")
                continue
            if ann not in seen:
                refuse("R8", f"{rel}:{begin}-{end}",
                       f"annotated `<!-- decided-by: {ann} -->`, but no such decision is registered",
                       f"Registered ids: {', '.join(sorted(seen)) or '(none)'}.")
                continue
            extra = sorted(run_candidates(cells, all_tokens) - tokens_by_id[ann])
            if extra:
                refuse("R8", f"{rel}:{begin}-{end}",
                       f"annotated for '{ann}', but names state(s) its program never tests: "
                       f"{', '.join(extra)}",
                       "Prose may enumerate FEWER states than the program handles, never more. "
                       "A row for a state with no branch hides the program's gap instead of "
                       "making it visible — add the branch, or drop the row.")

    return failures, sorted(seen), shaped


def _jq_compiles(prog):
    """None when the program compiles, else jq's own complaint, indented.

    Run over EMPTY input, which makes this a pure parse check: jq compiles the whole program before
    it reads anything, and with zero inputs the filter is never applied even once — so a non-zero
    exit here can only be a compile error, never a runtime one. Same idiom, and the same reason,
    as `tests/merge-gate/test.sh`'s parse gate.
    """
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp) / "program.jq"
        path.write_text(prog, encoding="utf-8")
        try:
            proc = subprocess.run(
                ["jq", "-f", str(path)],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                encoding="utf-8",
            )
        except OSError as exc:
            raise Unanswerable(
                f"jq is not available ({exc}) — it is a `required` prerequisite in "
                "requirements.json, and every registered decision is read or run through it."
            )
    if proc.returncode == 0:
        return None
    return "\n".join("    " + l for l in (proc.stderr.strip() or "(no message)").splitlines())


def _marker_copies(repo, begin, exclude):
    for root in COPY_ROOTS:
        base = repo / root
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if not path.is_file() or path == exclude:
                continue
            try:
                if begin in path.read_text(encoding="utf-8", errors="replace"):
                    yield path
            except OSError:
                continue


def _rel(repo, path):
    try:
        return str(pathlib.Path(path).relative_to(repo))
    except ValueError:
        return str(path)


def _program_where(repo, row):
    prog = row.get("program") or {}
    return prog.get("path") or f"{prog.get('home')} ({prog.get('marker')})"


def report(failures, ids, shaped):
    if failures:
        print("decision-check: REFUSED.\n")
        for rule, where, message, remedy in failures:
            print(f"  {rule}  {where}")
            print(f"      {message}")
            for line in remedy:
                print(f"      → {line}")
            print()
        print(f"decision-check: {len(failures)} refusal(s) above. All of them, not the first.")
        return 1
    uncovered = [i for i in ids if i not in shaped]
    print(
        f"decision-check: {len(ids)} decisions, {len(shaped)} with a shape block, all "
        "single-homed, invoked and unrestated."
    )
    if uncovered:
        # Counted rather than silent: R6 cannot speak for these, and a guard that cannot answer
        # must say which questions it did not answer.
        print(
            "  no shape block, so R6 does not cover them: " + ", ".join(uncovered)
        )
    return 0


def main():
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.splitlines()[0])
    ap.add_argument("--repo", default=".", help="kit root (default: cwd)")
    ap.add_argument("--registry", default=None, help="registry path (default: <repo>/decisions/registry.json)")
    args = ap.parse_args()

    # Pin both streams before anything is written to them (#623). Every verdict this script prints
    # carries characters outside cp1252 - the refusal lines interpolate a U+2192 arrow - and on a
    # Windows host a PIPED stdout defaults to the locale encoding, so `python3 scripts/decision-check.py`
    # raised UnicodeEncodeError from inside report() and exited 1 with a traceback instead of
    # printing its verdict. `tests/decisions/test.sh` reads this output through a command
    # substitution, which is exactly such a pipe. Same reasoning, and same idiom, as
    # skills/setup-repo/scripts/parse-manifest.py - the repo profile's "pin both halves" gotcha.
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    sys.stderr.reconfigure(encoding="utf-8", newline="\n")

    repo = pathlib.Path(args.repo).resolve()
    registry = pathlib.Path(args.registry).resolve() if args.registry \
        else repo / "decisions" / "registry.json"
    try:
        failures, ids, shaped = check(repo, registry)
    except Unanswerable as exc:
        print(f"decision-check: {exc}", file=sys.stderr)
        print("  No verdict is possible, which is not a pass.", file=sys.stderr)
        return 2
    return report(failures, ids, shaped)


if __name__ == "__main__":
    sys.exit(main())
