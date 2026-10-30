"""Tally the Terra-against-Sol production trial (#576) from the live revmux archive.

Reads every round that ran under the `mixed-terra` profile and, for each codex group, compares the
sol entry with its terra twin: findings raised, majors raised, findings on the final list that name
the entry among their sources, final findings only one twin sourced, findings verification rejected,
and tokens. The two twins of a group carried the same lenses in the same wave, so a difference is
the model's.

    python3 tally.py [tasks-dir] [--since YYYY-MM-DD] [--profile NAME] [--json]

`--profile mixed` tallies the sol entries alone over `mixed` rounds, which is how the script was checked
before the trial produced a round.
"""
import collections, glob, json, os, sys

tasks = os.path.expanduser("~/.local/state/revmux/tasks"); since = ""; as_json = False; profile = "mixed-terra"
args = sys.argv[1:]
while args:
    a = args.pop(0)
    if a == "--since": since = args.pop(0)
    elif a == "--json": as_json = True
    elif a == "--profile": profile = args.pop(0)
    else: tasks = a

GROUPS = ("docs+tests", "bugs+impl", "lean")
def agent_of(fid): return fid.rsplit("-", 1)[0]
def load(path):
    with open(path) as f: return json.load(f)

per = collections.defaultdict(collections.Counter); rounds = []
for mpath in sorted(glob.glob(f"{tasks}/*/*/manifest.json")):
    try: m = load(mpath)
    except (OSError, ValueError): continue
    if m.get("profile") != profile or (since and m.get("started_at", "") < since): continue
    d = os.path.dirname(mpath)
    try:
        found = load(f"{d}/stages/1-found.json")["findings"]; synthesized = load(f"{d}/stages/2-synthesized.json")["findings"]; verified = load(f"{d}/stages/3-verified.json")["findings"]; final = load(f"{d}/findings.json")["findings"]
    except (OSError, ValueError, KeyError): continue
    rounds.append({"task": m["task"], "run": m["run"], "started_at": m.get("started_at"), "duration_ms": m.get("duration_ms"), "degraded": bool(m.get("degraded"))})
    for a in m["agents"]:
        c = per[a["name"]]; c["rounds"] += 1; c["tokens"] += a.get("tokens", 0); c["degraded"] += bool(a.get("degraded"))
        if a.get("actual_model") and a.get("requested_model") and a["requested_model"] not in a["actual_model"]: c["model_mismatch"] += 1
    for f in found:
        c = per[agent_of(f["id"])]; c["raised"] += 1
        if f["severity"] in ("major", "critical"): c["raised_major"] += 1
    # Verification keeps a finding (confirmed or refined) or removes it from the list; a removed one is a rejection.
    kept_ids = {f["id"] for f in verified}
    for f in synthesized:
        if f["id"] not in kept_ids:
            for s in set(f.get("sources", [])): per[s]["verified_rejected"] += 1
    for f in final:
        srcs = set(f.get("sources", []))
        for s in srcs:
            per[s]["final"] += 1
            if f["severity"] in ("major", "critical"): per[s]["final_major"] += 1
        for g in GROUPS:
            sol, terra = f"{g}-codex", f"{g}-terra"
            if sol in srcs and terra not in srcs: per[sol]["final_only_this_twin"] += 1
            if terra in srcs and sol not in srcs: per[terra]["final_only_this_twin"] += 1

if as_json:
    print(json.dumps({"rounds": rounds, "agents": {k: dict(v) for k, v in per.items()}}, indent=1, ensure_ascii=False)); sys.exit()
print(f"{len(rounds)} {profile} rounds" + (f" since {since}" if since else "") + f", {sum(r['degraded'] for r in rounds)} degraded")
cols = ("rounds", "raised", "raised_major", "final", "final_major", "final_only_this_twin", "verified_rejected", "tokens", "model_mismatch")
print("agent".ljust(22) + "".join(c.rjust(len(c) + 2) for c in cols))
for g in GROUPS:
    for name in (f"{g}-codex", f"{g}-terra"):
        c = per.get(name, collections.Counter())
        print(name.ljust(22) + "".join(str(c.get(k, 0)).rjust(len(k) + 2) for k in cols))
