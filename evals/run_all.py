#!/usr/bin/env python3
"""Run every lifecycle-skill trigger-eval set + the boundary, refresh the baseline.

Thin orchestration over `trigger_eval.py`: runs each `<skill>-trigger-eval.json`
set, writes per-skill results to `evals/results/<skill>.json`, runs the shared
boundary set against both `implement-issue` and `merge-pr`, and writes a compact
`evals/results/baseline.json` summary. See evals/README.md for the diagnosis,
safety model, and how the numbers are read.
"""

import argparse
import json
import shutil
from contextlib import contextmanager
from pathlib import Path

import trigger_eval as te

# Every skill under skills/ — the trigger contract has one home per skill now
# (evals/<skill>-trigger-eval.json), and tests/skills/check-frontmatter.py fails CI if
# one is missing, so the "! skipping" branch below can no longer fire for a real skill (#331).
SKILLS = ["auto-dev", "create-issue", "create-pr", "debug-issue", "deliver-issue", "implement-issue",
          "merge-pr", "migrate-legacy", "profile-repo", "review-followups",
          "review-sessions", "setup-repo", "triage-backlog"]
EVALS_DIR = Path(__file__).resolve().parent
RESULTS_DIR = EVALS_DIR / "results"


@contextmanager
def skills_visible(project_root, skills):
    """Stage every skill under test into `<project_root>/.claude/skills/` for the run.

    Why the bench cannot be left to whatever is installed. Detection matches the CANONICAL
    installed skill name as well as the synthetic command file (see README, "Why a local
    runner"), so a skill this machine's plugin cache does not carry can only ever fire through
    the synthetic half — and measures far lower for that reason alone, with nothing in the
    numbers to say so. Measured on `review-sessions`, which the installed 2.0.0 plugin predates:
    recall **0.11** uninstalled, **1.00** the moment it was linked in. Same description, same
    queries, same day; the only variable was the plugin version in the cache.

    A specificity of 1.00 next to a collapsed recall is that fingerprint, and it is
    indistinguishable by eye from a genuinely weak description — which is how a stale cache
    would get a good description rewritten. So the bench stops asking the environment: the
    repo's own `skills/<name>/SKILL.md` is what runs, always.

    Only what this created is removed. A real directory, or a link somebody else put there,
    is left exactly as found.
    """
    dest_dir = Path(project_root) / ".claude" / "skills"
    dest_dir.mkdir(parents=True, exist_ok=True)
    made = []
    for skill in skills:
        source = Path(project_root) / "skills" / skill
        dest = dest_dir / skill
        # A leftover from a crashed run is skipped, as it always was — but the consequence changed
        # with the mechanism: a leftover SYMLINK still resolved to the live source, while a leftover
        # COPY is frozen at the moment it was made. So a crash between staging and teardown can now
        # leave the bench measuring a stale SKILL.md — the same class of silent mis-measurement this
        # staging exists to prevent, one directory closer. Deleting it unasked is the worse trade
        # (it is indistinguishable from a contributor's own .claude/skills entry, which must survive
        # untouched), so it is named here rather than guessed at; see the PR's follow-ups.
        if not source.is_dir() or dest.exists() or dest.is_symlink():
            continue
        # COPIED, not linked (#624). A symlink needs SeCreateSymbolicLink on Windows — Developer
        # Mode or elevation — which most machines do not grant, so `symlink_to` raised
        # `OSError: [WinError 1314]` and the run died before one trigger contract was measured.
        # #619 removed the same assumption from the two plugin trees by copying (ADR 0017); this
        # was the runtime caller left. A skill is a small tree of text, so the copy is cheap, and
        # the bench reads it read-only for the duration of one run.
        shutil.copytree(source, dest)
        made.append(dest)
    if made:
        print(f"staged {len(made)} skill(s) into .claude/skills/ for the run")
    try:
        yield
    finally:
        for dest in made:
            # `made` holds ONLY what this call created, which is what keeps the promise above: a
            # real directory, or a link somebody else put there, was skipped by the `dest.exists()
            # or dest.is_symlink()` guard and never reaches this loop. So everything here is a
            # directory this call copied, and rmtree is the whole teardown.
            shutil.rmtree(dest, ignore_errors=True)


def broken_detector(summary, results) -> str | None:
    """Say why this result cannot be believed, or None if it can.

    A run that measures nothing looks EXACTLY like a description that fires nothing:
    every positive misses, every negative passes, `recall 0.0` beside `specificity 1.0`.
    evals/README.md has documented that fingerprint since #370 as the signature of a
    broken detector — and the runner still wrote it to disk and exited 0. Measured on
    2026-09-05: a 5-runs-per-query sweep degraded partway through and reported recall
    0.0 for SIX consecutive skills; every one of them fired first try when probed by
    hand a minute later. Nothing in the run said so, and `baseline.json` was overwritten
    with the lot.

    So the run refuses to publish a result of that shape. The cost of being wrong is
    asymmetric and not close: a false alarm costs one re-run, while a published 0.0
    sends someone to rewrite a description that was never the problem.
    """
    positives = [r for r in results if r["should_trigger"]]
    if positives and summary["recall"] == 0.0 and summary["specificity"] == 1.0:
        return (f"recall 0.0 beside specificity 1.0 over {len(positives)} positives — the "
                f"documented fingerprint of a detector that measured nothing, not of a "
                f"description that fires nothing")
    timed_out = sum(1 for r in results if r.get("timed_out"))
    if timed_out and timed_out > len(results) // 4:
        return f"{timed_out} of {len(results)} queries timed out — the run was starved, not measured"
    return None


def _run(skill, eval_set, project_root, runs, workers, timeout, threshold, model, known=None):
    description = te.read_skill_description(project_root, skill)
    return te.run_eval(
        eval_set=eval_set, skill_name=skill, description=description,
        known=known or list(te.DEFAULT_KNOWN), workers=workers, timeout=timeout,
        project_root=project_root, runs_per_query=runs, threshold=threshold, model=model,
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs-per-query", type=int, default=3)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--timeout", type=int, default=90)
    ap.add_argument("--threshold", type=float, default=0.5)
    ap.add_argument("--model", default=None)
    ap.add_argument("--skills", default=None, help="Comma list to limit which skills run")
    args = ap.parse_args()

    project_root = te.find_project_root()
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    selected = args.skills is not None
    skills = [s.strip() for s in args.skills.split(",")] if selected else SKILLS

    # Merge into the existing baseline rather than overwrite it, so a scoped run
    # (`--skills create-issue`) refreshes only that entry and leaves the other
    # committed skills/boundary intact instead of dropping them.
    baseline_path = RESULTS_DIR / "baseline.json"
    baseline = json.loads(baseline_path.read_text()) if baseline_path.exists() else {}
    baseline["runs_per_query"] = args.runs_per_query
    baseline["threshold"] = args.threshold
    baseline.setdefault("skills", {})
    refused = []

    # Every skill is linked in, not just the selected ones, so a scoped run and a full run
    # measure the same environment.
    with skills_visible(project_root, SKILLS):
        for skill in skills:
            eval_path = EVALS_DIR / f"{skill}-trigger-eval.json"
            if not eval_path.exists():
                print(f"! skipping {skill}: no {eval_path.name}")
                continue
            eval_set = json.loads(eval_path.read_text())
            out = _run(skill, eval_set, project_root, args.runs_per_query, args.workers,
                       args.timeout, args.threshold, args.model)
            why = broken_detector(out["summary"], out["results"])
            if why:
                print(f"! REFUSED [{skill}]: {why}")
                print(f"  Nothing written; evals/results/{skill}.json keeps its committed value.")
                refused.append(skill)
                continue
            (RESULTS_DIR / f"{skill}.json").write_text(json.dumps(out, indent=2) + "\n")
            s = out["summary"]
            baseline["skills"][skill] = {
                "passed": s["passed"], "total": s["total"],
                "recall": s["recall"], "specificity": s["specificity"],
            }
            print(f"[{skill}] {s['passed']}/{s['total']}  recall={s['recall']}  specificity={s['specificity']}")

        # Boundary: same queries, both skills. Each query carries a per-skill expectation.
        # Skip it on a scoped run that excludes both boundary skills, so `--skills
        # create-issue` doesn't fire the real boundary queries or churn its artifacts.
        boundary_path = EVALS_DIR / "boundary-trigger-eval.json"
        run_boundary = boundary_path.exists() and (
            not selected or bool({"implement-issue", "merge-pr"} & set(skills)))
        if run_boundary:
            boundary = json.loads(boundary_path.read_text())
            bres = {}
            for skill in ("implement-issue", "merge-pr"):
                eval_set = [{"query": q["query"], "should_trigger": q["expect"][skill], "note": q.get("note", "")}
                            for q in boundary]
                out = _run(skill, eval_set, project_root, args.runs_per_query, args.workers,
                           args.timeout, args.threshold, args.model,
                           known=["implement-issue", "merge-pr", "create-issue", "profile-repo"])
                (RESULTS_DIR / f"boundary-{skill}.json").write_text(json.dumps(out, indent=2) + "\n")
                bres[skill] = out["summary"]
                print(f"[boundary→{skill}] {out['summary']['passed']}/{out['summary']['total']}")
            baseline["boundary"] = bres

        (RESULTS_DIR / "baseline.json").write_text(json.dumps(baseline, indent=2) + "\n")
    print(f"\nWrote {RESULTS_DIR}/baseline.json")
    if refused:
        # Non-zero, because a sweep that could not measure part of what it was asked to
        # measure did not succeed — and a caller that reads only the exit code must not
        # be told otherwise.
        print(f"\n! {len(refused)} skill(s) unmeasurable this run: {', '.join(refused)}")
        print("  Re-run them alone (--skills …); a starved sweep is the usual cause.")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
