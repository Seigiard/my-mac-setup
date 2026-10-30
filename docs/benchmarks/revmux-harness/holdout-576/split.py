"""Split the blind packet into per-case adjudication inputs: every major, every final-stage finding, and the declared minor sample (every fourth merged or dropped minor per round, in packet order)."""
import json, sys, collections, os
packet_path, out_dir = sys.argv[1], sys.argv[2]
p = json.load(open(packet_path))
FINAL = {"kept", "pre_existing", "immaterial", "open_question"}
by_range = collections.defaultdict(list); sampled = 0; pool = 0
for r in p["rounds"]:
    if r["state"] != "complete": continue
    keep = []; minors = 0
    for f in r["findings"]:
        if f["severity"] in ("major", "critical") or f["stage_fate"] in FINAL: keep.append(f); continue
        pool += 1; minors += 1
        if minors % 4 == 0: keep.append(dict(f, sampled_minor=True)); sampled += 1
    by_range[(r["base"], r["head"])].append({**r, "findings": keep})
os.makedirs(out_dir, exist_ok=True)
for i, ((base, head), rounds) in enumerate(sorted(by_range.items()), 1):
    path = f"{out_dir}/case-{i}.json"
    json.dump({"format": p["format"], "base": base, "head": head, "rounds": rounds}, open(path, "w"), indent=1)
    print(path, base[:8], head[:8], "rounds", len(rounds), "findings", sum(len(r["findings"]) for r in rounds))
print("minor sample", sampled, "of", pool)
