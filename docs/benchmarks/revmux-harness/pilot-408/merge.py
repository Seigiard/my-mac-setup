"""Merge the three repetition directories into one archive: rep k's '<case>-<arm>-1' becomes '<case>-<arm>-k' with bench.json repetition k."""
import json, shutil, sys, os
B = sys.argv[1]; out = f"{B}/archive"; os.makedirs(out, exist_ok=True)
for rep, src in ((1, "tasks"), (2, "tasks-rep2"), (3, "tasks-rep3")):
    d = f"{B}/{src}"
    if not os.path.isdir(d): continue
    for task in sorted(os.listdir(d)):
        if not task.endswith("-1"): continue
        new = task[:-2] + f"-{rep}"
        if os.path.exists(f"{out}/{new}"): continue
        shutil.copytree(f"{d}/{task}", f"{out}/{new}")
        bench = f"{out}/{new}/01-bench/bench.json"
        b = json.load(open(bench)); b["repetition"] = rep; json.dump(b, open(bench, "w"), indent=1)
        print("merged", new)
