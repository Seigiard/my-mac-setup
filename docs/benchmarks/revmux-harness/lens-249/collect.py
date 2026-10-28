"""Collect found and final findings of every #249 round into one file per pair for the label adjudicator."""
import json, sys, os, glob
B = sys.argv[1]; labels = json.load(open(f"{B}/labels.json"))
by_case = {}
for rep in (1, 2, 3):
    for bench in glob.glob(f"{B}/tasks-rep{rep}/*/01-bench/bench.json"):
        d = os.path.dirname(bench); b = json.load(open(bench))
        def stage(name):
            p = f"{d}/stages/{name}"
            if not os.path.exists(p): return []
            doc = json.load(open(p)); items = doc if isinstance(doc, list) else doc.get("findings", doc)
            if isinstance(items, dict): items = [x for v in items.values() if isinstance(v, list) for x in v]
            return [{k: f.get(k) for k in ("id", "file", "line", "severity", "title", "body")} for f in items if isinstance(f, dict)]
        final_doc = json.load(open(f"{d}/findings.json")) if os.path.exists(f"{d}/findings.json") else {}
        final = [{k: f.get(k) for k in ("id", "file", "line", "severity", "title", "body")} for f in final_doc.get("findings", [])]
        by_case.setdefault(b["case"], []).append({"task": os.path.basename(os.path.dirname(d)) + f"#rep{rep}", "case": b["case"], "base": b["base"], "head": b["head"], "findings": {"found": stage("1-found.json"), "final": final}})
os.makedirs(f"{B}/adjudication/in", exist_ok=True)
for pair, lab in labels.items():
    rounds = []
    for cid, st in ((lab["bad"], "bad"), (lab["repaired"], "repaired")):
        for r in by_case.get(cid, []): rounds.append({**r, "stage": st})
    json.dump({"pair": pair, "rounds": rounds}, open(f"{B}/adjudication/in/{pair}.json", "w"), indent=1)
    print(pair, "rounds", len(rounds), "found", sum(len(r["findings"]["found"]) for r in rounds), "final", sum(len(r["findings"]["final"]) for r in rounds))
