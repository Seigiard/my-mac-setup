"""Score the cross-arm adjudication: decode opaque round ids with key.json and tabulate per pair per arm."""
import json, os, sys
X = os.path.expanduser("~/.local/state/revmux-bench/577-xadj"); key = json.load(open(f"{X}/key.json")); out = {}
for pair in ("pair-2", "pair-3", "pair-4"):
    p = f"{X}/out/{pair}.json"
    if not os.path.exists(p): print(pair, "pending"); continue
    rows = json.load(open(p)); out[pair] = {}
    for arm in ("baseline", "scope"):
        rs = [dict(r, arm=arm, source=key[r["task"]]["task"]) for r in rows if key[r["task"]]["arm"] == arm]
        bad = [r for r in rs if r["stage"] == "bad"]; rep = [r for r in rs if r["stage"] == "repaired"]
        out[pair][arm] = {"bad_rounds": len(bad), "found_hits": sum(bool(r.get("found_hit")) for r in bad), "final_hits": sum(bool(r.get("final_hit")) for r in bad),
                          "lost_in_pipeline": sum(bool(r.get("found_hit")) and not r.get("final_hit") for r in bad), "repaired_rounds": len(rep),
                          "false_positive_rounds": sum(bool(r.get("false_positive")) for r in rep), "false_positives": sum(len(r.get("false_positive") or []) for r in rep), "rows": rs}
        print(pair, arm, {k: v for k, v in out[pair][arm].items() if k != "rows"})
json.dump(out, open(f"{X}/score.json", "w"), indent=1)
