#!/usr/bin/env python3
"""auto-dev cost accounting — aggregate token usage across the orchestrator + every
background worker session, so you can track tokens/merge and $/merge across runs.

Three transcript layouts land in a project dir, and this script must open all of them —
counting only some silently drops whatever sits in the rest (#281, #309):

  top-level session          <proj>/<session-id>.jsonl — since 2.0 (#314) this is the
                             ORCHESTRATOR only. A pre-2.0 run also left one per worker here,
                             because a worker was then its own process session.
  Agent-tool sub-agent       <proj>/<session-id>/subagents/agent-*.jsonl — since 2.0 EVERY
                             worker (two per issue: the phase-1 implement agent and the
                             phase-2 merge agent), nested under the supervisor session that
                             dispatched it. Kept separate because a sub-agent's tokens are
                             never folded into its dispatcher's top-level transcript — they
                             exist only here, and skipping this layout is how they go
                             uncounted rather than merely mis-attributed.
  workflow-nested sub-agent  <proj>/<session-id>/subagents/workflows/wf_<id>/agent-*.jsonl — the
                             same worker one level deeper, dispatched through the `Workflow`
                             tool's agent() calls. Attributed to the top-level <session-id>, not
                             to wf_<id>: a workflow run is a grouping inside a session, not a
                             dispatchable session of its own (#309).

`<proj>` is  ~/.claude/projects/<url-encoded-worktree-path>.  Every run reports how many of
each kind it found — `SESSIONS: N in <proj>   (X top-level, Y sub-agent)` — so a project dir
with zero Agent-tool workers prints `0 sub-agent` rather than leaving the split to be guessed
from the row count.

Usage:
    python usage_report.py [PROJECT_DIR] [--main SESSION_ID] [--top N]

  PROJECT_DIR   the ~/.claude/projects/<...> dir holding the .jsonl transcripts.
                Defaults to auto-detecting it from $PWD (the encoded worktree path).
  --main        session-id of the orchestrator, to split it out from the workers.
  --top         how many sessions to list (default 40).

IMPORTANT — billing caveat: the $ figures are **API list-price equivalents** computed
from on-disk token counts. On a Max/Pro subscription your marginal cash cost is ~$0
(usage is included, bounded by rate limits). Treat $ as a *relative scalability* signal
— where the tokens go — and as "rate-limit budget consumed", not necessarily a bill.
The authoritative cash number for the CURRENT session is the built-in `/cost` command;
this script is more complete because it also sees the worker sub-agents /cost can't.
"""
import json, glob, os, re, sys

# Per-model pricing, $ / 1M tokens: (input, output, cache_write_5m, cache_read).
# Keyed by a substring of the model id. Update when rates change.
PRICING = {
    "opus":   (15.0, 75.0, 18.75, 1.50),
    "sonnet": ( 3.0, 15.0,  3.75, 0.30),
    "haiku":  ( 1.0,  5.0,  1.25, 0.10),
}
DEFAULT = PRICING["sonnet"]  # unknown model → price conservatively as Sonnet

def rate_for(model):
    if model:
        for key, r in PRICING.items():
            if key in model:
                return r, key
    return DEFAULT, "?"

def encode_project_dir(path):
    # Claude Code names the project dir after the cwd: every non-alphanumeric character → '-'.
    # Twin: skills/review-sessions/scripts/harvest.py (each skill ships self-contained).
    return re.sub(r"[^A-Za-z0-9]", "-", path)

def detect_project_dir():
    home = os.path.expanduser("~")
    enc = encode_project_dir(os.getcwd())
    cand = os.path.join(home, ".claude", "projects", enc)
    if os.path.isdir(cand):
        return cand
    # Fallback: newest project dir under ~/.claude/projects
    base = os.path.join(home, ".claude", "projects")
    dirs = [os.path.join(base, d) for d in os.listdir(base)] if os.path.isdir(base) else []
    dirs = [d for d in dirs if os.path.isdir(d)]
    return max(dirs, key=os.path.getmtime) if dirs else None

def first_user_label(path):
    try:
        with open(path) as f:
            for line in f:
                try: o = json.loads(line)
                except Exception: continue
                if o.get("type") == "user":
                    c = o.get("message", {}).get("content")
                    txt = c if isinstance(c, str) else next(
                        (p.get("text") for p in c if isinstance(p, dict) and p.get("type") == "text"),
                        None) if isinstance(c, list) else None
                    if txt:
                        return " ".join(txt.split())[:80]
    except Exception:
        pass
    return ""

def row_label(path):
    # A sibling <stem>.meta.json — the shape an Agent-tool sub-agent's transcript carries,
    # e.g. subagents/agent-XXXX.jsonl + subagents/agent-XXXX.meta.json — records the
    # dispatcher's own `description` for the task, which is a better label than whatever the
    # sub-agent's first user-turn happens to contain (often the whole forwarded prompt). Prefer
    # it when present; every other transcript falls back to first_user_label() exactly as
    # before, so no behaviour changes where no meta file exists.
    meta_path = path[:-len(".jsonl")] + ".meta.json" if path.endswith(".jsonl") else None
    if meta_path and os.path.isfile(meta_path):
        try:
            with open(meta_path) as f:
                meta = json.load(f)
            desc = meta.get("description")
            if desc:
                return " ".join(str(desc).split())[:80]
        except Exception:
            pass
    return first_user_label(path)

def discover_transcripts(proj):
    """Yield (path, kind, parent) for every transcript this project dir holds.

    kind='top'  <proj>/<session-id>.jsonl               — the orchestrator (or, on a pre-2.0
                                                            run, a process worker); parent=None.
    kind='sub'  <proj>/<session-id>/subagents/*.jsonl    — a worker: since 2.0 every phase-1
                                                            and phase-2 agent is one of these;
                                                            parent=<session-id> of the dir it sits
                                                            under (its dispatcher — may or may not
                                                            be the orchestrator).
    kind='sub'  <proj>/<session-id>/subagents/workflows/wf_<id>/*.jsonl
                                                          — the same worker, one level deeper:
                                                            a sub-agent dispatched by the Workflow
                                                            tool's agent() calls. parent is still
                                                            the top-level <session-id>, NOT wf_<id>
                                                            — a workflow run is a grouping inside a
                                                            session, not a dispatchable session of
                                                            its own (#309).
    """
    for p in sorted(glob.glob(os.path.join(proj, "*.jsonl"))):
        yield p, "top", None
    for p in sorted(glob.glob(os.path.join(proj, "*", "subagents", "*.jsonl"))):
        parent = os.path.basename(os.path.dirname(os.path.dirname(p)))
        yield p, "sub", parent
    # One level deeper than the pattern above: <session-id>/subagents/workflows/wf_<id>/*.jsonl.
    # Walk four directories up (wf_<id> → workflows → subagents → <session-id>) so the parent is
    # the dispatching top-level session, matching the shallower case (#309).
    for p in sorted(glob.glob(os.path.join(proj, "*", "subagents", "workflows", "wf_*", "*.jsonl"))):
        parent = os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(p)))))
        yield p, "sub", parent

def scan(path):
    tin = tout = tcw = tcr = nmsg = 0
    model = None
    with open(path) as f:
        for line in f:
            try: o = json.loads(line)
            except Exception: continue
            msg = o.get("message")
            if not isinstance(msg, dict): continue
            if msg.get("model"): model = msg["model"]
            u = msg.get("usage")
            if not isinstance(u, dict): continue
            tin  += u.get("input_tokens", 0) or 0
            tout += u.get("output_tokens", 0) or 0
            tcw  += u.get("cache_creation_input_tokens", 0) or 0
            tcr  += u.get("cache_read_input_tokens", 0) or 0
            nmsg += 1
    (pi, po, pcw, pcr), mk = rate_for(model)
    cost = tin/1e6*pi + tout/1e6*po + tcw/1e6*pcw + tcr/1e6*pcr
    return dict(tin=tin, tout=tout, tcw=tcw, tcr=tcr, nmsg=nmsg, cost=cost, model=mk)

def main(argv):
    proj = None; main_id = None; top = 40

    def usage(reason):
        print("usage: usage_report.py [PROJECT_DIR] [--main SESSION_ID] [--top N]", file=sys.stderr)
        print(reason, file=sys.stderr)
        return 2

    # Walk argv and CONSUME each option's value. The first parser collected every non-`--` token as
    # a positional, so the documented `--main <sid>` form read <sid> as PROJECT_DIR and failed with
    # "project dir not found: <sid>" (#354).
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--main":
            if i + 1 >= len(argv): return usage("--main needs a SESSION_ID")
            main_id = argv[i + 1]; i += 2; continue
        if a == "--top":
            if i + 1 >= len(argv): return usage("--top needs a number")
            try: top = int(argv[i + 1])
            except ValueError: return usage(f"--top needs a number, got {argv[i + 1]!r}")
            i += 2; continue
        if a.startswith("--"):
            return usage(f"unknown option: {a}")
        if proj is not None:
            return usage(f"unexpected argument: {a} (PROJECT_DIR is already {proj})")
        proj = a; i += 1
    proj = proj or detect_project_dir()
    if not proj or not os.path.isdir(proj):
        print(f"project dir not found: {proj}", file=sys.stderr); return 2

    rows = []
    for p, kind, parent in discover_transcripts(proj):
        sid = os.path.basename(p)[:-6]
        r = scan(p); r["sid"] = sid; r["kind"] = kind; r["parent"] = parent
        r["label"] = row_label(p)
        rows.append(r)
    rows.sort(key=lambda r: r["cost"], reverse=True)
    n_top = sum(1 for r in rows if r["kind"] == "top")
    n_sub = sum(1 for r in rows if r["kind"] == "sub")

    def f(n): return f"{n:,}"
    g = {k: sum(r[k] for r in rows) for k in ("tin","tout","tcw","tcr","nmsg","cost")}
    tot_tok = g["tin"]+g["tout"]+g["tcw"]+g["tcr"]

    # Zero sub-agent transcripts is a fact worth PRINTING, not an absence a reader has to infer
    # from the row count — that silence is exactly what let the original under-count look
    # complete.
    print(f"SESSIONS: {len(rows)} in {proj}   ({n_top} top-level, {n_sub} sub-agent)\n")
    print(f"{'$equiv':>9}  {'model':>6}  {'kind':>3}  {'output':>11}  {'cacheRead':>14}  {'msgs':>5}  session / label")
    print("-"*120)
    for r in rows[:top]:
        tag = "  <<< ORCHESTRATOR" if r["kind"] == "top" and r["sid"] == main_id else ""
        print(f"{r['cost']:9.2f}  {r['model']:>6}  {r['kind']:>3}  {f(r['tout']):>11}  {f(r['tcr']):>14}  {r['nmsg']:>5}  {r['sid'][:8]} {r['label']}{tag}")
    print("-"*120)

    print(f"\n=== GRAND TOTAL ({len(rows)} sessions) ===")
    print(f"  output {f(g['tout'])} | input {f(g['tin'])} | cacheWrite {f(g['tcw'])} | cacheRead {f(g['tcr'])}")
    print(f"  total tokens {f(tot_tok)} | assistant msgs {f(g['nmsg'])}")
    print(f"  EST COST (API list-price equiv): ${g['cost']:,.2f}   [subscription users: ~$0 cash; this = rate-limit budget]")

    # cost by token type (at blended rates actually applied)
    print(f"\n=== COST DRIVERS (share of $equiv) ===")
    parts = []
    for name, tok, price_key in (("cache read", g['tcr'], 3), ("cache write", g['tcw'], 2),
                                  ("output", g['tout'], 1), ("input", g['tin'], 0)):
        # approximate $ using Opus rates only for the *share* illustration is misleading post-tiering;
        # instead report token share, which is model-agnostic.
        parts.append((name, tok))
    for name, tok in parts:
        print(f"  {name:<12}: {f(tok):>16} tok  ({tok/tot_tok*100:4.1f}% of tokens)")

    if main_id:
        # --main names the orchestrator's TOP-LEVEL transcript only. Every 'sub' row counts as a
        # worker even when its parent session IS the orchestrator — the tokens were spent by a
        # worker, and folding them into the parent would restate the original under-count (which
        # dropped them entirely) in the other direction (attributing a worker's cost to the
        # orchestrator it happened to be dispatched from).
        m = next((r for r in rows if r["kind"] == "top" and r["sid"] == main_id), None)
        if m:
            rest = g["cost"] - m["cost"]
            print(f"\n=== ORCHESTRATOR vs WORKERS ===")
            print(f"  orchestrator : ${m['cost']:,.2f}  ({m['cost']/g['cost']*100:.0f}%)")
            print(f"  workers+other: ${rest:,.2f}  ({rest/g['cost']*100:.0f}%) over {len(rows)-1} sessions, avg ${rest/max(1,len(rows)-1):,.2f}")

    # per-model rollup — shows the tiering payoff
    bym = {}
    for r in rows:
        d = bym.setdefault(r["model"], {"n":0,"cost":0.0,"tok":0})
        d["n"]+=1; d["cost"]+=r["cost"]; d["tok"]+=r["tin"]+r["tout"]+r["tcw"]+r["tcr"]
    print(f"\n=== BY MODEL (the tiering payoff) ===")
    for mk, d in sorted(bym.items(), key=lambda kv: kv[1]["cost"], reverse=True):
        print(f"  {mk:>6}: {d['n']:>3} sessions | {f(d['tok']):>16} tok | ${d['cost']:,.2f}")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
