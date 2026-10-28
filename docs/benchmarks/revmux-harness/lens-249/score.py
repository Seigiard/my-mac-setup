"""Score the #249 baseline: per pair, labelled-defect hits at found and final stage on the bad rounds, false positives on the repaired rounds."""
import json, sys, glob, os, collections
B = sys.argv[1]; labels = json.load(open(f"{B}/labels.json")); out = {}
for pair, lab in labels.items():
    path = f"{B}/adjudication/out/{pair}.json"
    if not os.path.exists(path): print(pair, "pending"); continue
    rows = json.load(open(path)); bad = [r for r in rows if r["stage"] == "bad"]; rep = [r for r in rows if r["stage"] == "repaired"]
    s = {"category": lab["category"], "bad_rounds": len(bad), "found_hits": sum(bool(r.get("found_hit")) for r in bad), "final_hits": sum(bool(r.get("final_hit")) for r in bad),
         "lost_in_pipeline": sum(bool(r.get("found_hit")) and not r.get("final_hit") for r in bad),
         "repaired_rounds": len(rep), "false_positive_rounds": sum(bool(r.get("false_positive")) for r in rep), "false_positives": sum(len(r.get("false_positive") or []) for r in rep),
         "notes": {r["task"]: r.get("note") for r in rows}}
    out[pair] = s; print(pair, {k: v for k, v in s.items() if k != "notes"})
json.dump(out, open(f"{B}/score.json", "w"), indent=1)
