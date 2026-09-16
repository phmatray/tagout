#!/usr/bin/env python3
"""CI guard: every shared reference under `skills/_shared/` that declares its own reach stays
linked from every file that must carry it — in both directions.

#266 built this as a single-document checker for `untrusted-input-boundary.md` alone: text the kit
did not author is DATA, never instructions, and that rule is worth exactly as much as the number of
places that still point at it. #269 generalizes it: `skills/_shared/` holds several such
references (`preconditions.md`, `filing-bar.md`, `sync-with-main.md`, `worktree-ignore-check.md`,
alongside the boundary), and a mechanism that only guards one of them is the same failure shape
`scripts/ci-wiring-check.py` was written for — a suite nobody runs looks exactly like a suite that
passes, here applied one level up: a guard covering one instance of its own premise looks exactly
like a guard covering the category.

Each `skills/_shared/*.md` document OPTS IN by declaring a `## Consumers` section; a document
without one is silently SKIPPED, never refused — that is deliberate (not an oversight): a sixth
shared reference must never fail CI for existing, or adopting the section anywhere would train
people to delete it rather than fill it in.

For every document that HAS opted in, the check is BIDIRECTIONAL, and that is the whole design:

  * every path it names under its own `## Consumers` section must link back to it, and
  * every file in the scanned tree that points at it must be named there.

The second half is the one with no positive witness in the tree, and it is what keeps the doc
honest. Without it the consumer list drifts from reality in the direction that looks fine — a
skill grows a new ingest point, links the reference, and the list silently stops describing who
actually reads it.

**The link must RESOLVE, not merely read well.** A consumer whose relative link sits at the wrong
depth (`../_shared/…` from a file that needs `../../_shared/…`) still contains every character a
substring test looks for, while the reminder it is supposed to reach is unreachable — which is the
one regression that empties this guard of meaning while leaving all its text in place. So targets
are resolved against the linking file's own directory and compared to the document's real path, and
a link that names it but lands somewhere else is reported as BROKEN, not missing.

The scan is deliberately wider than `skills/` (#266 review). `commands/auto-dev-worker.md` is read
by a separate sub-agent session that never opens `skills/auto-dev/SKILL.md`, so it is a first-class
consumer; a reverse check that stopped at `skills/` would forward-check it and never notice the
list going stale in the other direction, while the CI step's name promises both.

**A sibling `skills/_shared/*.md` document is not exempt from the reverse scan.** A blanket
exclusion was the first draft's answer to `recap.md` citing `preconditions.md` and
`sync-with-main.md`, and `preconditions.md` citing `worktree-ignore-check.md` — but
`untrusted-input-boundary.md` declares `prior-rejections.md`, itself a `skills/_shared/*.md` file,
as a real consumer, and a blanket exclusion would silently stop catching that declaration dropping
while the link stayed (code-review, #269). So the handful of purely cross-referencing sibling
links are declared as ordinary consumers instead — see each document's own `## Consumers` section.

Each consumer inventory lives in its own document rather than in this script, on purpose. A
hand-maintained list inside the checker is the stale-inventory failure this repo has already paid
for four times in the README (#45); keeping it in the doc means the thing that declares its reach
and the thing that verifies it are one edit apart, and the reverse rule is what stops them
diverging.

Self-test: tests/skills/test.sh drives this file over fixtures that must FAIL, so a guard that
silently stops matching cannot pass CI.
"""
import re
import sys
from functools import lru_cache
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", newline="\n")
sys.stderr.reconfigure(encoding="utf-8", newline="\n")

ROOT = Path(__file__).resolve().parents[2]
SHARED_DIR_REL = "skills/_shared"

# Where a link to a declaring document can legitimately come from. Wider than skills/ so the
# reverse rule covers every surface that can carry one — commands/ above all, which is what a
# dispatched worker actually reads. Root-level prose is included because ARCHITECTURE.md and
# README.md already link some of skills/_shared/'s own documents.
SCAN_DIRS = ("skills", "commands", "templates", "docs")

# Any markdown link target. The name filter happens after extraction, so a link that NAMES a
# declaring document but resolves elsewhere is still seen — that is the BROKEN case, and a
# `.md`-suffix substring test could not tell it from a working one.
LINK_TARGET_RE = re.compile(r'\]\(([^)\s]+)')

errors = []


@lru_cache(maxsize=None)
def read(path: Path):
    """File text, or None when it cannot be decoded or read.

    A single stray non-UTF-8 byte anywhere under the scanned tree would otherwise turn this gate
    into a Python traceback instead of a verdict. tests/skills/test.sh's sibling scanner over the
    same tree takes the same precaution.

    Memoized: the reverse scan below re-visits the same candidate once per declaring document, and
    nothing on disk changes within a run — so N documents cost one read per file, not N.
    """
    try:
        return path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return None


def links_doc(path: Path, text: str, doc: Path, doc_name: str):
    """(names_it, resolves_to_it) for links to `doc` found in `text` (read from `path`).

    `names_it` answers "was this file trying to point at `doc`" — the question the reverse rule
    asks, and one a broken link still answers yes to. `resolves_to_it` answers "can a reader
    actually get there", which is what a consumer has to satisfy.
    """
    names_it = False
    resolves = False
    for target in LINK_TARGET_RE.findall(text):
        target = target.split('#', 1)[0]
        # Basename equality, not `endswith`: a link to a future `session-recap.md` ends with
        # `recap.md` without naming it, and would otherwise be read as a broken link to it.
        if target.rsplit('/', 1)[-1] != doc_name:
            continue
        names_it = True
        try:
            if (path.parent / target).resolve() == doc.resolve():
                resolves = True
        except (OSError, ValueError):
            continue
    return names_it, resolves


def consumers_of(text: str):
    """The paths listed under `## Consumers`, in file order, or None if there is no section.

    `None` is the opt-in signal: a document with no such section is skipped entirely, never
    refused. Only a bullet whose first token is BACKTICKED counts as an entry:
    `- `skills/x/SKILL.md` — …`. Prose bullets are skipped rather than read as paths — the section
    is written for a human, and a reflowed sentence turning into `NO SUCH CONSUMER: … lists
    'Anything'` would be the checker dictating the doc's punctuation instead of verifying its
    claim (#266 review).
    """
    block = re.search(r'^## Consumers\s*$\n(.*?)(?=^## |\Z)', text, re.S | re.M)
    if not block:
        return None
    paths = []
    for line in block.group(1).splitlines():
        line = line.strip()
        if not line.startswith("- "):
            continue
        quoted = re.match(r'`([^`]+)`', line[2:].strip())
        if quoted:
            paths.append(quoted.group(1).strip())
    return paths


shared_docs = sorted(ROOT.glob(SHARED_DIR_REL + "/*.md"))
if not shared_docs:
    print("ERR: no *.md files under %s/ — nothing to check" % SHARED_DIR_REL)
    sys.exit(2)

# Every markdown file in scan scope, read once and reused for every declaring document's reverse
# scan below — checking N documents costs one tree walk, not one per document.
candidates = []
for d in SCAN_DIRS:
    candidates.extend((ROOT / d).glob("**/*.md"))
candidates.extend(ROOT.glob("*.md"))
candidates = sorted(set(candidates))

declaring_count = 0
consumer_count = 0

for doc in shared_docs:
    doc_rel = doc.relative_to(ROOT).as_posix()
    doc_name = doc.name

    text = read(doc)
    if text is None:
        errors.append(
            f"UNREADABLE DOC: {doc_rel} could not be read as UTF-8 — its reach cannot be checked")
        continue

    listed = consumers_of(text)
    if listed is None:
        continue  # opt-in: a document that has not declared its reach is never checked

    declaring_count += 1
    consumer_count += len(listed)

    if not listed:
        errors.append(
            f"EMPTY CONSUMERS SECTION: {doc_rel} declares '## Consumers' and lists no backticked "
            f"path — every would-be consumer is therefore undeclared")

    listed_set = set(listed)

    # Forward rule — every path this document names must link back to it, and the link must
    # actually resolve.
    for rel in listed:
        target = ROOT / rel
        try:
            target.resolve().relative_to(ROOT.resolve())
        except ValueError:
            errors.append(
                f"CONSUMER OUTSIDE THE REPO: {doc_rel} lists '{rel}', which resolves outside the "
                f"repository — the inventory is malformed, not merely wrong")
            continue
        if not target.is_file():
            errors.append(f"NO SUCH CONSUMER: {doc_rel} lists '{rel}', which does not exist")
            continue
        ttext = read(target)
        if ttext is None:
            errors.append(
                f"NO SUCH CONSUMER: '{rel}' could not be read as UTF-8 (declared by {doc_rel})")
            continue
        names_it, resolves = links_doc(target, ttext, doc, doc_name)
        if resolves:
            continue
        if names_it:
            errors.append(
                f"BROKEN LINK: {rel} → {doc_rel} — links it by name, but the target does not "
                f"resolve there — the reminder reads correctly and is unreachable")
        else:
            errors.append(
                f"MISSING LINK: {rel} (declared by {doc_rel}) — contains no link to it, the "
                f"reminder is gone from the step that was supposed to carry it")

    # Reverse rule — every OTHER scanned file that links this document must be named above.
    # Sibling skills/_shared/*.md files are NOT exempted: `untrusted-input-boundary.md` declares
    # `prior-rejections.md` — itself under skills/_shared/ — as a real consumer, and a blanket
    # sibling exclusion would silently stop catching that declaration if it were ever dropped
    # while the link stayed (code-review, #269). The handful of purely cross-referencing sibling
    # links (recap.md citing preconditions.md and sync-with-main.md, preconditions.md citing
    # worktree-ignore-check.md, brainstorm-and-spec.md citing plan-shape.md) are declared as
    # ordinary consumers below instead of carved out here.
    for md in candidates:
        rel = md.relative_to(ROOT).as_posix()
        if rel == doc_rel or rel in listed_set:
            continue
        ttext = read(md)
        if ttext is None:
            continue
        names_it, _ = links_doc(md, ttext, doc, doc_name)
        if names_it:
            errors.append(
                f"UNLISTED LINKER: {rel} ({doc_rel}) — points at it but is absent from its "
                f"'## Consumers' list, which is out of date")

if errors:
    print("\n".join(errors))
    sys.exit(1)
print(f"shared refs OK — {declaring_count} declaring document(s) under {SHARED_DIR_REL}/, "
      f"{consumer_count} consumer link(s), all resolving, none unlisted")
