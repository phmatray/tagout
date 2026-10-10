#!/usr/bin/env python3
"""check-adrs.py — the structural checks AdrMcp's `validate_adr` performs, run by CI instead.

A mirror of `validate_adr`'s structural checks, because CI cannot start the MCP server; keep the
two in step when AdrMcp's rules change.

That sentence is the whole contract, and the word MIRROR is the load-bearing part: this file is a
second home for rules whose first home is AdrMcp (`AdrValidationService`). Two homes for one rule
is the defect this repository has been bitten by before, so it is accepted here only because the
alternative — no check at all in CI — is worse: an ADR set drifts silently (a renamed file, an id
that never reached the index, a supersession with no trail) and the first person to notice is
whoever tried to READ it, long after the commit that broke it.

Which side each rule came from, so a reader knows what to keep in step with what:

  FROM `validate_adr` (AdrMcp owns these; if its rules change, change them here too)
    * a non-empty `title`, and a `date`
    * the three MADR sections: one of {Context and Problem Statement, Context}, one of
      {Decision Outcome, Decision}, and Consequences
    * `id` unique across the root
    * no `links[].target` naming an ADR that is not there
    * a `superseded` ADR carries a `superseded-by` link

  THE KIT'S OWN ADDITIONS (AdrMcp does not check these; they are about the files on disk)
    * frontmatter is present and carries id/title/status/date/tags at the right types
    * `status` is one of the five wire values
    * the filename is exactly `{id:04d}-{kebab(title)}.md`
    * `<root>/README.md` — the rendered index — mentions every id, so it cannot go stale

The frontmatter shape is what `AdrRepositoryService.Render` writes: key order id, title, status,
date, deciders?, tags, links, code_refs, serialized with OmitNull | OmitEmptyCollections. That last
flag is why an ADR with no links has NO `links:` key at all rather than `links: []` — an absent
`links`, `code_refs` or `deciders` is EMPTY here, never a failure.

Usage:
  check-adrs.py [<adr-root>]        # default: <repo>/docs/adr

Exit codes:
  0  every ADR in the root is structurally sound
  1  REFUSE — one line per failure, ALL of them. A checker that stops at the first defect turns
     one review into N round trips (tests/skills/check-frontmatter.py, same convention).
  2  no verdict was possible — a mis-invocation, or a missing PyYAML. Never spelled 1: "I could
     not look" and "I looked and they are broken" are different answers, and a gate that conflates
     them sends the reader to the wrong place.

Self-test: tests/adr/test.sh drives this file over a valid fixture set and over that set broken in
exactly one way per rule, so a rule that silently stops matching cannot pass CI.
"""

import datetime
import re
import sys
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError:
    # Exit 2, not 1. Exit 1 means "these ADRs are broken"; a missing interpreter dependency means
    # NOTHING WAS READ, and the two must not be spelled the same — scripts/run-all-tests.sh exists
    # because a missing PyYAML once arrived as forty lines of what looked like real regressions.
    print("check-adrs.py: PyYAML is required by this check — install it before this step "
          "(pip install PyYAML)", file=sys.stderr)
    sys.exit(2)

# stdout is pinned, for the reason skills/init/scripts/parse-manifest.py pins it: this
# repository has been bitten at output boundaries by a cp1252 console (an em dash below would
# raise UnicodeEncodeError and turn a REFUSAL into a crash) and by CRLF (which a `grep -qF`
# assertion in the golden suite would then miss). Neither failure is about the rules; both would
# be read as if they were.
sys.stdout.reconfigure(encoding="utf-8", newline="\n")
sys.stderr.reconfigure(encoding="utf-8", newline="\n")

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ADR_ROOT = ROOT / "docs" / "adr"

# The wire vocabulary, lowercase enum names, exactly as the server serializes them.
STATUSES = ("proposed", "accepted", "rejected", "deprecated", "superseded")
LINK_TYPES = ("supersedes", "superseded-by", "relates-to", "conflicts-with")

# An ADR file is `NNNN-<slug>.md`. This pattern DECIDES A VERDICT; it does not select the file set
# (see `check`). A pattern that selected the set would make every rule below opt-in on the filename
# being right already: `008-foo.md`, `8-foo.md` and `adr-8-foo.md` — a contributor typing three
# digits, which is the realistic mistake — would be read by nothing, counted by nothing, and the
# run would print `ADRs OK` over them. The rendered index is the one file exempted by name.
ADR_FILE_RE = re.compile(r"^\d{4}-.+\.md$")
INDEX_NAME = "README.md"
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
HEADING_RE = re.compile(r"^#{1,6}[ \t]+(.+?)[ \t]*$", re.M)

# Each tuple is one requirement, satisfied by ANY of its spellings — `validate_adr` accepts either
# heading of each pair, and a mirror that accepted only the MADR 4.0 spelling would refuse ADRs the
# server itself is happy with.
REQUIRED_SECTIONS = (
    ("context and problem statement", "context"),
    ("decision outcome", "decision"),
    ("consequences",),
)

REQUIRED_KEYS = ("id", "title", "status", "date", "tags")


def kebab(title):
    """The slug half of a filename: lowercase, every run of non-[a-z0-9] to one `-`, trimmed.

    Deliberately not a "smart" slugifier. Punctuation collapses rather than being transliterated,
    so `Squash-only merges: the PR title …` -> `squash-only-merges-the-pr-title-…` and a trailing
    `never claude -p` -> `never-claude-p`. The rule has to be the SAME rule the filenames were
    written by, and a rule this small is one a reader can apply by hand to check.
    """
    return re.sub(r"[^a-z0-9]+", "-", str(title).lower()).strip("-")


def split_frontmatter(text):
    """(frontmatter-text, body) for a `---`-delimited header, or (None, whole text).

    Delimiters are matched as whole LINES: a `---` inside a body (a horizontal rule, a nested YAML
    block) must not be able to close a header it never opened.
    """
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None, text
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return "\n".join(lines[1:i]), "\n".join(lines[i + 1:])
    return None, text


def is_int(value):
    """True for a real integer. `bool` is a subclass of int in Python, and `id: true` is not an id."""
    return isinstance(value, int) and not isinstance(value, bool)


def headings_of(body):
    return set(h.strip().lower() for h in HEADING_RE.findall(body))


def check(adr_root):
    """Every failure the root contains, as one line each, in a stable order."""
    failures = []

    if not adr_root.is_dir():
        return [f"{adr_root}: the ADR root does not exist — no verdict is possible, so this is a "
                f"refusal rather than a pass over nothing"]

    # Every markdown file except the index is CLAIMED as an ADR, and one that is not named like an
    # ADR is refused rather than skipped. "Skipped" and "clean" are the same output, which is the
    # whole failure mode this checker exists to close.
    candidates = sorted(p for p in adr_root.iterdir()
                        if p.is_file() and p.suffix == ".md" and p.name != INDEX_NAME)
    if not candidates:
        return [f"{adr_root}: no ADR files (NNNN-*.md) — refusing rather than passing vacuously; a "
                f"root with nothing in it is the one result a checker must never call clean"]

    files = []
    for path in candidates:
        if ADR_FILE_RE.match(path.name):
            files.append(path)
        else:
            failures.append(f"{adr_root.name}/{path.name}: not an ADR filename — an ADR is "
                            f"`NNNN-<slug>.md` with a FOUR-digit id; nothing in this root is read "
                            f"under any other name, so a file named like this is checked by no "
                            f"rule at all")

    # Pass 1: read every file, so pass 2's cross-file rules see the WHOLE root. Rules that concern
    # one file alone are decided here; the id-dependent ones wait for the full set.
    records = []
    for path in files:
        name = f"{adr_root.name}/{path.name}"
        text = path.read_text(encoding="utf-8")
        fm_text, body = split_frontmatter(text)

        data = {}
        if fm_text is None:
            failures.append(f"{name}: missing frontmatter — a `---` delimited YAML header is what "
                            f"carries id, title, status, date and tags")
        else:
            try:
                loaded = yaml.safe_load(fm_text)
            except yaml.YAMLError as exc:
                loaded = None
                failures.append(f"{name}: unparseable frontmatter — {exc}")
            if loaded is None:
                pass
            elif not isinstance(loaded, dict):
                failures.append(f"{name}: unparseable frontmatter — the header is a "
                                f"{type(loaded).__name__}, not a mapping")
            else:
                data = loaded

        for key in REQUIRED_KEYS:
            if key not in data:
                failures.append(f"{name}: missing frontmatter key: {key}")

        adr_id = data.get("id")
        if "id" in data and not is_int(adr_id):
            failures.append(f"{name}: invalid id — `id` must be an integer, got {adr_id!r}")
            adr_id = None
        elif "id" not in data:
            adr_id = None

        title = data.get("title")
        if "title" in data and (not isinstance(title, str) or not title.strip()):
            failures.append(f"{name}: invalid title — `title` must be a non-empty string, got "
                            f"{title!r}")
            title = None
        elif "title" not in data:
            title = None

        status = data.get("status")
        if "status" in data and status not in STATUSES:
            failures.append(f"{name}: unknown status {status!r} — must be one of "
                            f"{', '.join(STATUSES)}")

        if "date" in data:
            value = data["date"]
            # PyYAML resolves an unquoted `2026-08-31` to a datetime.date; a quoted one, or a
            # calendar-impossible one, arrives as a string. Both spellings are legal on disk, so
            # both are accepted here and only the MEANING is checked.
            if isinstance(value, datetime.date) and not isinstance(value, datetime.datetime):
                pass
            elif isinstance(value, str) and DATE_RE.match(value):
                try:
                    datetime.date.fromisoformat(value)
                except ValueError:
                    failures.append(f"{name}: invalid date {value!r} — not a real calendar date")
            else:
                failures.append(f"{name}: invalid date {value!r} — must be ISO YYYY-MM-DD")

        if "tags" in data:
            tags = data["tags"]
            if not isinstance(tags, list) or not tags:
                failures.append(f"{name}: invalid tags — `tags` must be a non-empty list, got "
                                f"{tags!r}")

        # Rule 4: the filename IS the id and the title, spelled once each.
        if adr_id is not None and title is not None:
            expected = f"{adr_id:04d}-{kebab(title)}.md"
            if path.name != expected:
                failures.append(f"{name}: filename does not match its frontmatter — expected "
                                f"{expected!r} (from id {adr_id} and title {title!r})")

        # The MADR sections `validate_adr` requires of every body.
        heads = headings_of(body)
        for spellings in REQUIRED_SECTIONS:
            if not heads & set(spellings):
                failures.append(f"{name}: missing required section — none of "
                                f"{', '.join(repr(s) for s in spellings)} appears as a heading")

        links = data.get("links", [])
        if links is None:
            links = []
        if not isinstance(links, list):
            failures.append(f"{name}: malformed links — `links` must be a list of mappings, got "
                            f"{type(links).__name__}")
            links = []

        sources = data.get("sources", [])
        if sources is None:
            sources = []
        if not isinstance(sources, list):
            failures.append(f"{name}: malformed sources — `sources` must be a list of file paths, "
                            f"got {type(sources).__name__}")
            sources = []

        records.append({"name": name, "path": path, "id": adr_id, "status": status,
                        "links": links, "sources": sources, "filename": path.name})

    # Pass 2: the rules that need the whole root.
    known_ids = set(r["id"] for r in records if r["id"] is not None)

    seen = {}
    for record in records:
        if record["id"] is None:
            continue
        seen.setdefault(record["id"], []).append(record["name"])
    for adr_id in sorted(seen):
        owners = seen[adr_id]
        if len(owners) > 1:
            failures.append(f"{adr_root.name}: duplicate id {adr_id} — claimed by "
                            f"{', '.join(sorted(owners))}; an id is what every link and the index "
                            f"resolve through, so it can only ever name one ADR")

    for record in records:
        name = record["name"]
        has_superseded_by = False
        for link in record["links"]:
            if not isinstance(link, dict):
                failures.append(f"{name}: malformed link — every entry of `links` is a mapping "
                                f"with `type` and `target`, got {link!r}")
                continue
            link_type = str(link.get("type", "")).strip().lower()
            if link_type == "superseded-by":
                has_superseded_by = True
            if not link_type:
                # Not a skip. A typeless link is how `superseded without superseded-by` gets
                # silenced — the supersession is written down, nothing reads it as one, and the
                # rule that would have caught the missing trail never fires.
                failures.append(f"{name}: malformed link — a link entry has no type: {link!r}; "
                                f"every entry of `links` carries both a `type` and a `target`")
            elif link_type not in LINK_TYPES:
                failures.append(f"{name}: unknown link type {link.get('type')!r} — must be one of "
                                f"{', '.join(LINK_TYPES)}")
            if "target" not in link:
                failures.append(f"{name}: malformed link — a link entry has no `target`: {link!r}")
                continue
            target = link["target"]
            if not is_int(target):
                failures.append(f"{name}: malformed link target {target!r} — a `target` is the "
                                f"integer id of another ADR")
                continue
            if target not in known_ids:
                failures.append(f"{name}: dangling link — target {target} names no ADR in "
                                f"{adr_root}")

        if record["status"] == "superseded" and not has_superseded_by:
            failures.append(f"{name}: superseded without superseded-by — a superseded ADR must "
                            f"carry a link of type `superseded-by` naming what replaced it, or the "
                            f"trail stops here")

    # Rule for sources: verify declared source files exist and mention the ADR back
    for record in records:
        name = record["name"]
        sources = record.get("sources", [])
        if not sources:
            continue  # No sources: key, so this rule does not apply

        for source_path in sources:
            if not isinstance(source_path, str):
                failures.append(f"{name}: malformed source — each entry in `sources` must be a "
                                f"string (file path), got {source_path!r}")
                continue

            source_file = ROOT / source_path
            if not source_file.is_file():
                failures.append(f"{name}: dangling source — {source_path} does not exist or is not "
                                f"a file")
                continue

            # Check that the source file mentions the ADR filename
            try:
                source_text = source_file.read_text(encoding="utf-8")
            except Exception as e:
                failures.append(f"{name}: could not read source file {source_path}: {e}")
                continue

            adr_filename = record["filename"]
            if adr_filename not in source_text:
                failures.append(f"{name}: pointer missing at source — {source_path} does not "
                                f"mention {adr_filename}")

    # Rule 7: the rendered index is not stale.
    readme = adr_root / "README.md"
    if not readme.is_file():
        failures.append(f"{adr_root}/README.md: missing README index — the rendered index is part "
                        f"of the ADR set, and a set nobody can enumerate is a set nobody reads")
    else:
        index_text = readme.read_text(encoding="utf-8")
        for record in records:
            if record["id"] is None:
                continue
            padded = f"{record['id']:04d}"
            if padded not in index_text:
                failures.append(f"{record['name']}: missing from README index — {padded} does not "
                                f"appear in {adr_root}/README.md, so the index is stale")

    return failures


def main(argv):
    args = argv[1:]
    if args and args[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    if len(args) > 1:
        # Exit 2, and never 0. A stray extra word in the add_gate line or the ci.yml step would
        # otherwise read every ADR set as clean, forever, having opened none of them — the
        # absence-shaped green this repository keeps writing guards against.
        print(f"check-adrs.py: expected at most one argument (the ADR root), got "
              f"{len(args)}: {' '.join(repr(a) for a in args)}", file=sys.stderr)
        print("usage: check-adrs.py [<adr-root>]", file=sys.stderr)
        return 2
    adr_root = Path(args[0]) if args else DEFAULT_ADR_ROOT

    failures = check(adr_root)
    if failures:
        for line in failures:
            print(line)
        return 1
    count = len([p for p in adr_root.iterdir() if p.is_file() and ADR_FILE_RE.match(p.name)])
    print(f"ADRs OK: {count} in {adr_root} (frontmatter, status, unique ids, filenames, links, "
          f"supersessions, MADR sections, README index)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
