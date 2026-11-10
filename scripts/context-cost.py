#!/usr/bin/env python3
"""context-cost.py — what installing the kit costs every session, read off `/context` captures.

Usage:
  scripts/context-cost.py --baseline <context.md> --with <label>=<context.md> [--with …] [--kit <substring>]

Each file is the Markdown that `claude -p "/context"` prints, captured once in a scratch profile
without the kit and once per profile with it (docs/install.md, *What the kit costs a session*,
gives the recipe). The script never starts a session itself: it only diffs what was captured, so
it runs offline and in CI.

It reports three things a plain total hides:
  1. the per-category delta (a SessionStart hook's `additionalContext` lands in *Messages*);
  2. the kit's own rows — skill-listing entries and MCP tools whose source/server contains --kit;
  3. what the kit's skill entries did to EVERY OTHER skill's entry. Claude Code caps the skill
     listing, so on a host already at the cap the kit's entries add little to the total and
     shorten other skills' descriptions instead — a cost in triggering, not in tokens, and the
     one a total alone reports as "free".

Rows shown as `< N` (a description cut to almost nothing) count as 0, and so does a skill the
baseline lists that a capture no longer lists at all — it is named as dropped. Deferred categories are
loaded on demand and are reported, never added to the loaded total.
Exit codes: 0 report printed · 2 usage error or a file /context did not produce.
"""
import argparse
import re
import sys

_NUM = re.compile(r"^[~<]?\s*([\d.]+)(k?)$")


def tokens(cell):
    """'14.2k' -> 14200, '834' -> 834, '~230' -> 230, '< 20' -> 0."""
    cell = cell.strip()
    if cell.startswith("<"):
        return 0
    m = _NUM.match(cell)
    if not m:
        return None
    return round(float(m.group(1)) * (1000 if m.group(2) else 1))


def parse(path):
    """One /context capture -> {'total', 'categories', 'skills', 'mcp'}."""
    out = {"total": None, "categories": {}, "skills": {}, "mcp": {}}
    section = ""
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("**Tokens:**"):
                out["total"] = tokens(line.split("**Tokens:**", 1)[1].split("/", 1)[0])
            elif line.startswith("### "):
                section = line[4:].strip().lower()
            elif line.startswith("| ") and not line.startswith("|--"):
                cells = [c.strip() for c in line.strip().strip("|").split("|")]
                if "usage by category" in section and len(cells) == 3:
                    value = tokens(cells[1])
                    if value is not None:
                        out["categories"][cells[0]] = value
                elif section.startswith("skills") and len(cells) == 3:
                    value = tokens(cells[2])
                    if value is not None:
                        out["skills"][cells[0]] = (cells[1], value)
                elif section.startswith("mcp") and len(cells) == 3:
                    value = tokens(cells[2])
                    if value is not None:
                        out["mcp"][cells[0]] = (cells[1], value)
    if out["total"] is None:
        raise ValueError(f"{path}: no '**Tokens:**' line — not a /context capture")
    return out


def k(n):
    return f"{n / 1000:.1f}k" if abs(n) >= 1000 else str(n)


def signed(n):
    return ("+" if n > 0 else "") + k(n)


def report(base, runs, kit):
    labels = [label for label, _ in runs]
    print("| | baseline | " + " | ".join(labels) + " |")
    print("|---|---:|" + "---:|" * len(runs))
    print("| **Loaded total** | " + k(base["total"]) + " | "
          + " | ".join(f"{k(r['total'])} ({signed(r['total'] - base['total'])})" for _, r in runs) + " |")
    cats = list(base["categories"])
    for _, r in runs:
        cats += [c for c in r["categories"] if c not in cats]
    for c in cats:
        if c in ("Free space", "Autocompact buffer"):
            continue
        b = base["categories"].get(c, 0)
        row = [f"{k(r['categories'].get(c, 0))} ({signed(r['categories'].get(c, 0) - b)})" for _, r in runs]
        print(f"| {c} | {k(b)} | " + " | ".join(row) + " |")
    print()
    for label, r in runs:
        mine = {n: v for n, (src, v) in r["skills"].items() if kit in src}
        # Every non-kit skill the baseline listed. One the capture no longer lists was cut from the
        # listing entirely — the hardest form of the shrink — so it counts as 0, never as "absent
        # from the comparison".
        others = [n for n in base["skills"] if kit not in base["skills"][n][0]]
        dropped = [n for n in others if n not in r["skills"]]
        before = sum(base["skills"][n][1] for n in others)
        after = sum(r["skills"][n][1] for n in others if n in r["skills"])
        servers = {}
        for _, (server, v) in r["mcp"].items():
            if kit in server:
                servers[server] = servers.get(server, 0) + v
        print(f"**{label}** — kit skill entries: {len(mine)}, {k(sum(mine.values()))} tokens; "
              f"the {len(others)} other skills the baseline lists: {k(before)} -> {k(after)} ({signed(after - before)})"
              + (" — the listing is capped, so the kit's entries shortened other skills' descriptions"
                 if after < before else "")
              + (f"; {len(dropped)} dropped from the listing entirely: {', '.join(sorted(dropped))}"
                 if dropped else ""))
        for server, v in sorted(servers.items()):
            print(f"  - MCP server `{server}`: {k(v)} tokens of tool definitions (deferred unless loaded)")


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--with", dest="runs", action="append", required=True, metavar="LABEL=FILE")
    ap.add_argument("--kit", default="tagout", help="substring of a skill source or MCP server that marks the kit's rows")
    args = ap.parse_args(argv)
    try:
        base = parse(args.baseline)
        runs = []
        for spec in args.runs:
            label, sep, path = spec.partition("=")
            if not sep or not label or not path:
                ap.error(f"--with expects LABEL=FILE, got {spec!r}")
            runs.append((label, parse(path)))
    except (OSError, ValueError) as err:
        print(f"context-cost: {err}", file=sys.stderr)
        return 2
    report(base, runs, args.kit)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
