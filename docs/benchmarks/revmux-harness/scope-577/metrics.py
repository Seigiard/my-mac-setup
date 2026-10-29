"""Join the #249 baseline and candidate arms into metrics.json: per pair hits and false positives, per arm cost."""
import json, glob, os, sys, collections
ROOT = os.path.expanduser("~/.local/state/revmux-bench"); arms = {"baseline": f"{ROOT}/249-baseline", "scope": f"{ROOT}/577-scope"}
out = {"pairs": {}, "cost": {}, "rows": {}}
labels = json.load(open(f"{arms['baseline']}/labels.json"))
for arm, d in arms.items():
    xs = json.load(open(f"{ROOT}/577-xadj/score.json"))
    rows = []
    for pair in labels:
        s = xs[pair][arm]
        out["pairs"].setdefault(pair, {"category": labels[pair]["category"], "defect": labels[pair]["defect"], "basis": labels[pair]["basis"]})[arm] = {k: v for k, v in s.items() if k != "rows"}
        for r in s["rows"]: rows.append({**r, "pair": pair, "task": r["source"]})
    out["rows"][arm] = rows
    c = collections.Counter(); per_case = collections.defaultdict(collections.Counter)
    for m in glob.glob(f"{d}/tasks-rep*/*/01-bench/manifest.json"):
        md = json.load(open(m)); case = os.path.basename(os.path.dirname(os.path.dirname(m))).rsplit("-", 2)[0]
        for k, v in (("rounds", 1), ("tokens", md["tokens"]), ("ms", md["duration_ms"]), ("degraded", int(bool(md["degraded"]))),
                     ("claude", sum(a["tokens"] for a in md["agents"] if a["executor"] == "claude")), ("codex", sum(a["tokens"] for a in md["agents"] if a["executor"] == "codex")),
                     ("docs_tests", sum(a["tokens"] for a in md["agents"] if a["name"] == "docs+tests"))):
            c[k] += v; per_case[case][k] += v
        fin = json.load(open(os.path.join(os.path.dirname(m), "findings.json"))); c["final_findings"] += len(fin.get("findings", [])); per_case[case]["final_findings"] += len(fin.get("findings", []))
    out["cost"][arm] = {"total": dict(c), "per_case": {k: dict(v) for k, v in per_case.items()}}
json.dump(out, open(f"{sys.argv[1]}/metrics.json", "w"), indent=1); print(json.dumps({p: {a: (v[a]["final_hits"], v[a]["found_hits"], v[a]["false_positives"]) for a in arms if a in v} for p, v in out["pairs"].items()}))
