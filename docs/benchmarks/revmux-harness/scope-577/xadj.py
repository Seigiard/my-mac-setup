"""Build the #577 cross-arm adjudication inputs: the #249 baseline rounds and the scope-candidate rounds of each pair, shuffled under opaque round ids, plus the sealed key and one prompt per pair."""
import json, os, random, sys
ROOT = os.path.expanduser("~/.local/state/revmux-bench"); S = f"{ROOT}/577-scope"; X = f"{ROOT}/577-xadj"
TEMPLATE = "/Users/andrew.b/Projects/my-mac-setup/docs/benchmarks/revmux-harness/lens-249/adjudication/prompt-template.md"
os.makedirs(f"{X}/in", exist_ok=True); os.makedirs(f"{X}/out", exist_ok=True)
labels = json.load(open(f"{S}/labels.json")); random.seed(577); key = {}
for pair in labels:
    rounds = []
    for arm, d in (("baseline", f"{ROOT}/249-baseline"), ("scope", S)):
        for r in json.load(open(f"{d}/adjudication/in/{pair}.json"))["rounds"]: rounds.append((arm, r))
    random.shuffle(rounds); out = []
    for i, (arm, r) in enumerate(rounds, 1):
        rid = f"{pair}-r{i:02d}"; key[rid] = {"arm": arm, "task": r["task"]}
        rr = dict(r); rr["task"] = rid; out.append(rr)
    json.dump({"pair": pair, "rounds": out}, open(f"{X}/in/{pair}.json", "w"), indent=1)
    prompt = (open(TEMPLATE).read().replace("ROUNDS_FILE", f"{X}/in/{pair}.json").replace("LABEL_TEXT", labels[pair]["defect"])
              .replace("REPO_PATH", "/Users/andrew.b/Projects/my-mac-setup").replace("OUTPUT_PATH", f"{X}/out/{pair}.json")
              .replace("Each round has `task`", "Each round has `task` (an opaque round id)"))
    open(f"{X}/prompt-{pair}.md", "w").write(prompt); print(pair, "rounds", len(out), {a: sum(1 for a2, _ in rounds if a2 == a) for a in ("baseline", "scope")})
json.dump(key, open(f"{X}/key.json", "w"), indent=1)
