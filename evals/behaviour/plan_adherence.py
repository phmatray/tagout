#!/usr/bin/env python3
"""plan_adherence.py — how often a plan task's commit touches the files the task names (#739).

The trigger evals beside this file measure whether a skill FIRES. This measures one thing a skill
DOES once it runs: `implement-issue` executes a plan task by task, each task names its files on a
`**Files:**` line and its commit in its final step, and nothing ever compared the two.

Two commands, split so the arithmetic never needs a network:

  collect --repo OWNER/NAME (--last N | --prs A,B,C) [--out FILE]
      Reads merged pull requests with `gh api` and writes a BUNDLE: for each PR its title, the
      issue it closes, that issue's plan, and every commit of the PR with the files it touched.
      A PR's commits stay readable after its squash merge. Read-only; it writes one local file.

  score BUNDLE [--kit DIR] [--json]
      Scores a bundle. Offline: this is what the golden suite drives and what a reader re-runs.

How a task is scored
  * its paths are read off the `**Files:**` line by `plan-freshness.sh` — the one reader of that
    grammar (`skills/_shared/plan-shape.md`), never a second parser here;
  * its commit is the PR commit whose subject is the message the task's final step gives
    (`Commit: \\`<type>(<scope>): <subject>\\``), with or without a trailing ` (#N)`;
  * it is ADHERENT when that commit touches at least one path the task names.

What is NOT in the rate, and is reported instead of hidden
  * a task naming no path (`**Files:** none expected.`)          -> no_files
  * a task whose commit message matches no commit of the PR       -> unmatched
  * a PR with no issue, an issue with no plan, a plan with no task -> skipped, with the reason

A rate is printed only with its numerator and denominator. With nothing measured there is no
rate: the report says so and the exit status is 3, the same refusal the trigger bench makes for a
result it did not measure (#461).

Exit codes: 0 report printed · 2 usage error or an unreadable bundle · 3 nothing was measured.
"""
import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import tempfile

TASK_RE = re.compile(r"^### Task (\d+)\b[^\n]*$", re.M)
COMMIT_RE = re.compile(r"Commit:\s*`([^`]+)`")
FRESHNESS_RE = re.compile(r"^(OK|MISSING|SKIP)\s+(\w+)\s+(\S+)\s+\(Task (\d+)\)\s*$")
ANCHOR_RE = re.compile(r":\d[\d,\-–]*$")
ISSUE_IN_TITLE_RE = re.compile(r"\(#(\d+)\)")
CLOSES_RE = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)", re.I)
TRAILING_PR_RE = re.compile(r"\s*\(#\d+\)\s*$")
TRUSTED = ("OWNER", "MEMBER", "COLLABORATOR")


def kit_root(explicit=None):
    return explicit or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


# ----------------------------------------------------------------------------------- the plan

def task_commit_messages(plan):
    """{task number: the commit message its final step gives} — the LAST `Commit:` of each block."""
    out = {}
    marks = list(TASK_RE.finditer(plan))
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(plan)
        found = COMMIT_RE.findall(plan[m.end():end])
        out[int(m.group(1))] = found[-1].strip() if found else None
    return out


def task_paths(plan, kit):
    """{task number: [paths]} read by plan-freshness.sh — its exit status is about staleness
    against a ref and is ignored here; only the grammar is borrowed."""
    script = os.path.join(kit, "skills", "implement-issue", "scripts", "plan-freshness.sh")
    if not os.path.isfile(script):
        raise RuntimeError(f"{script} is missing — the **Files:** grammar has one reader and this is it")
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as fh:
        fh.write(plan)
        path = fh.name
    try:
        proc = subprocess.run(["bash", script, "-C", kit, "--base", "HEAD", path],
                              capture_output=True, text=True, encoding="utf-8")
    finally:
        os.unlink(path)
    out = {}
    for line in proc.stdout.splitlines():
        m = FRESHNESS_RE.match(line)
        if m:
            out.setdefault(int(m.group(4)), []).append(ANCHOR_RE.sub("", m.group(3)))
    return out


# ------------------------------------------------------------------------------------ scoring

def norm(subject):
    return " ".join(TRAILING_PR_RE.sub("", subject).split())


def touches(named, touched):
    for want in named:
        for got in touched:
            if got == want or fnmatch.fnmatch(got, want) or (want.endswith("/") and got.startswith(want)):
                return True
    return False


def score_pr(pr, kit):
    """-> ("skipped", reason) or ("scored", [task rows])."""
    if pr.get("skip_reason"):
        return "skipped", pr["skip_reason"]
    plan = pr.get("plan") or ""
    messages = task_commit_messages(plan)
    if not messages:
        return "skipped", "the plan has no `### Task N` block"
    paths = task_paths(plan, kit)
    by_subject = {}
    for c in pr.get("commits") or []:
        by_subject.setdefault(norm(c["subject"]), c)
    rows = []
    for n in sorted(messages):
        named = paths.get(n, [])
        msg = messages[n]
        commit = by_subject.get(norm(msg)) if msg else None
        if not named:
            verdict = "no_files"
        elif commit is None:
            verdict = "unmatched"
        elif touches(named, commit.get("files") or []):
            verdict = "adherent"
        else:
            verdict = "not_adherent"
        rows.append({"task": n, "verdict": verdict, "named": named,
                     "commit": commit["sha"][:8] if commit else None, "message": msg})
    return "scored", rows


def score(bundle, kit):
    counts = {"adherent": 0, "not_adherent": 0, "unmatched": 0, "no_files": 0}
    per_pr, skipped = [], []
    for pr in bundle.get("prs") or []:
        kind, payload = score_pr(pr, kit)
        if kind == "skipped":
            skipped.append({"pr": pr["number"], "reason": payload})
            continue
        for row in payload:
            counts[row["verdict"]] += 1
        per_pr.append({"pr": pr["number"], "issue": pr.get("issue"), "tasks": payload})
    denominator = counts["adherent"] + counts["not_adherent"]
    merged = sorted(p["merged_at"] for p in bundle.get("prs") or [] if p.get("merged_at"))
    return {
        "metric": "plan-adherence",
        "repo": bundle.get("repo"),
        "merged_from": merged[0] if merged else None,
        "merged_to": merged[-1] if merged else None,
        "numerator": counts["adherent"],
        "denominator": denominator,
        "rate": round(counts["adherent"] / denominator, 3) if denominator else None,
        "tasks_unmatched": counts["unmatched"],
        "tasks_without_files": counts["no_files"],
        "prs_read": len(bundle.get("prs") or []),
        "prs_scored": len(per_pr),
        "prs": sorted(p["number"] for p in bundle.get("prs") or []),
        "skipped": skipped,
        "per_pr": per_pr,
    }


def print_report(r):
    if r["denominator"]:
        print(f"plan adherence: {r['numerator']} / {r['denominator']} tasks ({r['rate']:.1%}) — "
              f"the task's commit touches a file its **Files:** line names")
    else:
        print("plan adherence: NO RATE — no task had both a named file and a matching commit")
    print(f"  pull requests: {r['prs_read']} read, {r['prs_scored']} scored, {len(r['skipped'])} skipped")
    print(f"  tasks outside the rate: {r['tasks_unmatched']} with no matching commit, "
          f"{r['tasks_without_files']} naming no file")
    for pr in r["per_pr"]:
        for t in pr["tasks"]:
            if t["verdict"] == "not_adherent":
                print(f"  not adherent: PR #{pr['pr']} task {t['task']} — commit {t['commit']} "
                      f"touches none of {', '.join(t['named'])}")
    for s in r["skipped"]:
        print(f"  skipped: PR #{s['pr']} — {s['reason']}")


# ---------------------------------------------------------------------------------- collecting

def gh(path, paginate=False):
    cmd = ["gh", "api", "-X", "GET", path] + (["--paginate"] if paginate else [])
    proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    if proc.returncode != 0:
        raise RuntimeError(f"gh api {path}: {proc.stderr.strip() or proc.stdout.strip()}")
    return json.loads(proc.stdout)


def find_plan(repo, issue):
    """The issue body when it carries the plan, else the first trusted comment that does."""
    body = gh(f"repos/{repo}/issues/{issue}").get("body") or ""
    if TASK_RE.search(body):
        return body
    for c in gh(f"repos/{repo}/issues/{issue}/comments?per_page=100"):
        if c.get("author_association") in TRUSTED and TASK_RE.search(c.get("body") or ""):
            return c["body"]
    return None


def collect_pr(repo, number):
    pr = gh(f"repos/{repo}/pulls/{number}")
    row = {"number": number, "title": pr.get("title"), "merged_at": pr.get("merged_at")}
    if not pr.get("merged_at"):
        row["skip_reason"] = "not merged"
        return row
    m = ISSUE_IN_TITLE_RE.search(pr.get("title") or "") or CLOSES_RE.search(pr.get("body") or "")
    if not m:
        row["skip_reason"] = "names no issue (no `(#N)` in the title, no `Closes #N` in the body)"
        return row
    row["issue"] = int(m.group(1))
    try:
        plan = find_plan(repo, row["issue"])
    except RuntimeError as err:
        row["skip_reason"] = f"issue #{row['issue']} could not be read ({err})"
        return row
    if plan is None:
        row["skip_reason"] = f"issue #{row['issue']} carries no plan (no `### Task N` block)"
        return row
    row["plan"] = plan
    row["commits"] = []
    for c in gh(f"repos/{repo}/pulls/{number}/commits?per_page=100"):
        detail = gh(f"repos/{repo}/commits/{c['sha']}")
        row["commits"].append({
            "sha": c["sha"],
            "subject": (c["commit"]["message"] or "").split("\n", 1)[0],
            "files": [f["filename"] for f in detail.get("files") or []],
        })
    return row


def collect(repo, last, numbers):
    if numbers is None:
        merged, page = [], 1
        while len(merged) < last and page <= 20:
            batch = gh(f"repos/{repo}/pulls?state=closed&sort=updated&direction=desc&per_page=100&page={page}")
            if not batch:
                break
            merged += [p for p in batch if p.get("merged_at")]
            page += 1
        merged.sort(key=lambda p: p["merged_at"], reverse=True)
        numbers = [p["number"] for p in merged[:last]]
    return {"repo": repo, "prs": [collect_pr(repo, n) for n in numbers]}


# ---------------------------------------------------------------------------------------- main

def main(argv):
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", newline="\n")
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("--repo", required=True)
    which = c.add_mutually_exclusive_group(required=True)
    which.add_argument("--last", type=int)
    which.add_argument("--prs")
    c.add_argument("--out")
    s = sub.add_parser("score")
    s.add_argument("bundle")
    s.add_argument("--kit")
    s.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    if args.cmd == "collect":
        try:
            numbers = [int(x) for x in args.prs.split(",")] if args.prs else None
            if args.last is not None and args.last < 1:
                ap.error("--last takes a positive integer")
            bundle = collect(args.repo, args.last, numbers)
        except (RuntimeError, ValueError, OSError) as err:
            print(f"plan-adherence: {err}", file=sys.stderr)
            return 2
        text = json.dumps(bundle, indent=1, ensure_ascii=False) + "\n"
        if args.out:
            with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text)
        else:
            sys.stdout.write(text)
        return 0

    try:
        with open(args.bundle, encoding="utf-8") as fh:
            bundle = json.load(fh)
        if not isinstance(bundle, dict) or not isinstance(bundle.get("prs"), list):
            raise ValueError("not a bundle: no `prs` list")
        report = score(bundle, kit_root(args.kit))
    except (OSError, ValueError, RuntimeError) as err:
        print(f"plan-adherence: {args.bundle}: {err}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(report, indent=1, ensure_ascii=False))
    else:
        print_report(report)
    return 0 if report["denominator"] else 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
