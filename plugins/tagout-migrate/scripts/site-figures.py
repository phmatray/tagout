#!/usr/bin/env python3
"""site-figures.py — read this repository's tracker through gh and write the docs home page's figures.

    python3 scripts/site-figures.py [--repo OWNER/REPO] [--out PATH]

Prints four scalars as YAML (stdout, or --out PATH, whose path is then printed):
  prs_merged                   merged pull requests
  issues_delivered             distinct issues closed by a merged pull request
  median_issue_to_merge_hours  median of (earliest closing PR's mergedAt - issue createdAt), in hours
  as_of                        today's UTC date

Exit 0 written; 1 refused (nothing delivered, --out untouched); 2 gh missing or failing.
"""
import argparse
import json
import statistics
import subprocess
import sys
from datetime import datetime, timezone

sys.stdout.reconfigure(encoding="utf-8", newline="\n")


def gh(args, repo):
    cmd = ["gh"] + args + (["--repo", repo] if repo else [])
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    except OSError as e:
        print(f"gh unavailable ({e}); failing call: {' '.join(cmd)}", file=sys.stderr)
        sys.exit(2)
    if r.returncode != 0:
        print(f"gh failed ({r.returncode}): {' '.join(cmd)}\n{r.stderr}", file=sys.stderr)
        sys.exit(2)
    return json.loads(r.stdout)


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo")
    ap.add_argument("--out")
    a = ap.parse_args()

    prs = gh(["pr", "list", "--state", "merged", "--limit", "5000",
              "--json", "number,mergedAt,closingIssuesReferences"], a.repo)
    issues = gh(["issue", "list", "--state", "all", "--limit", "5000",
                 "--json", "number,createdAt"], a.repo)

    created = {i["number"]: ts(i["createdAt"]) for i in issues}
    earliest = {}  # issue number -> earliest closing PR merge time
    for pr in prs:
        for ref in pr["closingIssuesReferences"]:
            n, m = ref["number"], ts(pr["mergedAt"])
            if n in created and (n not in earliest or m < earliest[n]):
                earliest[n] = m

    if not prs or not earliest:
        print("REFUSED — no merged pull request with a closing issue; figures not written",
              file=sys.stderr)
        sys.exit(1)

    hours = [(earliest[n] - created[n]).total_seconds() / 3600 for n in earliest]
    text = (
        "# Written by scripts/site-figures.py — never edited by hand.\n"
        f"as_of: {datetime.now(timezone.utc).date().isoformat()}\n"
        f"prs_merged: {len(prs)}\n"
        f"issues_delivered: {len(earliest)}\n"
        f"median_issue_to_merge_hours: {statistics.median(hours):.1f}\n"
    )
    if a.out:
        with open(a.out, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print(a.out)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
