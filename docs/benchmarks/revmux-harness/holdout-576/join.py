"""Join key, manifests, analyzer records and adjudication lines into per-arm and per-pair metrics."""
import json, sys, os, collections, glob, re
B = sys.argv[1]
key = json.load(open(f"{B}/key.json")); packet = json.load(open(f"{B}/packet/packet.json"))
sampled = {(r["round_code"], f["finding_code"]) for path in glob.glob(f"{B}/adjudication/in/case-*.json") for r in json.load(open(path))["rounds"] for f in r["findings"] if f.get("sampled_minor")}
analysis = json.load(open(f"{B}/analysis.json"))
adj = {}
for path in glob.glob(f"{B}/adjudication/out/case-*.json"):
    for line in json.load(open(path)):
        adj[(line["round_code"], line["finding_code"])] = line
rounds = {}
for code, meta in key["rounds"].items():
    m = json.load(open(f"{B}/archive/{meta['path']}/manifest.json"))
    rounds[code] = {**meta, "tokens": m["tokens"], "duration_ms": m["duration_ms"], "degraded": m["degraded"],
                    "claude_tokens": sum(a["tokens"] for a in m["agents"] if a["executor"] == "claude"),
                    "codex_tokens": sum(a["tokens"] for a in m["agents"] if a["executor"] == "codex"),
                    "actual": sorted({(a["executor"], a["actual_model"]) for a in m["agents"]})}
per_arm = collections.defaultdict(lambda: collections.Counter())
causes = collections.defaultdict(lambda: collections.defaultdict(set))  # case -> arm -> set(cause)
valid_causes = collections.defaultdict(lambda: collections.defaultdict(set))
finding_rows = []
for r in packet["rounds"]:
    meta = rounds[r["round_code"]]; arm, case = meta["arm"], meta["case"]
    per_arm[arm]["rounds"] += 1; per_arm[arm]["tokens"] += meta["tokens"]; per_arm[arm]["claude_tokens"] += meta["claude_tokens"]; per_arm[arm]["codex_tokens"] += meta["codex_tokens"]; per_arm[arm]["duration_ms"] += meta["duration_ms"]; per_arm[arm]["degraded"] += bool(meta["degraded"])
    for f in r.get("findings", []):
        archive_id = key["findings"][f["finding_code"]]; vendor = "claude" if archive_id.rsplit("-", 1)[0].endswith("claude") else "codex"
        group = re.sub(r"-(claude|codex)-\d+$", "", archive_id)
        per_arm[arm]["found"] += 1; per_arm[arm][f"found_{f['severity']}"] += 1; per_arm[arm][f"fate_{f['stage_fate']}"] += 1; per_arm[arm][f"found_{vendor}"] += 1
        a = adj.get((r["round_code"], f["finding_code"]))
        row = {"case": case, "arm": arm, "rep": meta["repetition"], "group": group, "vendor": vendor, "severity": f["severity"], "fate": f["stage_fate"], "title": f["title"], "file": f["file"], "line": f["line"], "sampled_minor": (r["round_code"], f["finding_code"]) in sampled}
        if a:
            per_arm[arm]["adjudicated"] += 1; per_arm[arm][f"verdict_{a['verdict']}"] += 1
            if a["verdict"] == "valid" and f["severity"] in ("major", "critical"): per_arm[arm]["valid_major"] += 1
            if a["verdict"] == "valid" and f["stage_fate"] == "kept": per_arm[arm]["valid_kept"] += 1
            if a["verdict"] == "invalid" and f["stage_fate"] == "kept": per_arm[arm]["invalid_kept"] += 1
            causes[case][arm].add(a["cause"])
            if a["verdict"] == "valid": valid_causes[case][arm].add(a["cause"])
            row.update({k: a[k] for k in ("cause", "basis", "verdict", "severity_agree", "note")})
        finding_rows.append(row)
pairs = {}
for cand in ("terra",):
    agg = collections.Counter(); detail = {}
    for case in valid_causes:
        b, c = valid_causes[case]["baseline"], valid_causes[case][cand]
        detail[case] = {"baseline_only": sorted(b - c), "candidate_only": sorted(c - b), "shared": sorted(b & c)}
        agg["baseline_only"] += len(b - c); agg["candidate_only"] += len(c - b); agg["shared"] += len(b & c)
    pairs[cand] = {"aggregate": dict(agg), "by_case": detail}
side_causes = collections.defaultdict(set)
for row in finding_rows:
    if row.get("verdict") == "valid": side_causes[(row["case"], row["arm"], row["vendor"])].add(row["cause"])
def side_pair(arm_a, arm_b, vendor):
    agg = collections.Counter(); detail = {}
    for case in sorted({k[0] for k in side_causes}):
        a, b = side_causes[(case, arm_a, vendor)], side_causes[(case, arm_b, vendor)]
        detail[case] = {"a_only": sorted(a - b), "b_only": sorted(b - a), "shared": sorted(a & b)}
        agg["a_only"] += len(a - b); agg["b_only"] += len(b - a); agg["shared"] += len(a & b)
    return {"aggregate": dict(agg), "by_case": detail}
side_pairs = {"codex: sol (baseline) vs terra": side_pair("baseline", "terra", "codex"),
              "control, claude: opus (baseline) vs opus (terra arm)": side_pair("baseline", "terra", "claude")}
# Pre-registered gates (#576 comment of 2026-10-29): per vendor side, per arm, invalid findings per round and invalid findings on a final list.
side_counts = collections.defaultdict(collections.Counter)
for row in finding_rows:
    k = (row["arm"], row["vendor"]); side_counts[k]["found"] += 1
    if "verdict" in row:
        side_counts[k]["adjudicated"] += 1; side_counts[k][f"verdict_{row['verdict']}"] += 1
        if row["verdict"] == "invalid" and row["fate"] == "kept": side_counts[k]["invalid_kept"] += 1
        if row["verdict"] == "valid" and row["severity"] in ("major", "critical"): side_counts[k]["valid_major"] += 1
        if row.get("severity_agree") is True: side_counts[k]["severity_agree"] += 1
        if row.get("sampled_minor"): side_counts[k]["sampled_minor"] += 1
rounds_per_arm = {a: per_arm[a]["rounds"] for a in per_arm}
codex = side_pairs["codex: sol (baseline) vs terra"]["aggregate"]; ctl = side_pairs["control, claude: opus (baseline) vs opus (terra arm)"]["aggregate"]
terra_side = side_counts[("terra", "codex")]
gates = {"margin": 3,
         "gate1_unique_causes": {"terra_only": codex.get("b_only", 0), "sol_only": codex.get("a_only", 0), "shared": codex.get("shared", 0), "pass": codex.get("b_only", 0) >= codex.get("a_only", 0) - 3},
         "gate2_invalid": {"terra_invalid": terra_side.get("verdict_invalid", 0), "terra_rounds": rounds_per_arm.get("terra", 0), "per_round": (terra_side.get("verdict_invalid", 0) / rounds_per_arm["terra"]) if rounds_per_arm.get("terra") else None,
                           "terra_invalid_kept": terra_side.get("invalid_kept", 0), "pass": rounds_per_arm.get("terra") and terra_side.get("verdict_invalid", 0) / rounds_per_arm["terra"] <= 0.5 and terra_side.get("invalid_kept", 0) <= 1},
         "gate3_control": {"opus_baseline_only": ctl.get("a_only", 0), "opus_terra_arm_only": ctl.get("b_only", 0), "shared": ctl.get("shared", 0), "ranked": abs(ctl.get("a_only", 0) - ctl.get("b_only", 0)) <= 3}}
gates["verdict"] = "unranked" if not gates["gate3_control"]["ranked"] else ("accepted" if gates["gate1_unique_causes"]["pass"] and gates["gate2_invalid"]["pass"] else "not accepted")
side_verdicts = {f"{arm} / {vendor}": dict(c) for (arm, vendor), c in sorted(side_counts.items())}
# per-cause stability: in how many of the 3 repetitions of an arm did a valid cause appear
stability = {}
for case in valid_causes:
    per_rep = collections.defaultdict(lambda: collections.defaultdict(set))
    for row in finding_rows:
        if row["case"] == case and row.get("verdict") == "valid": per_rep[row["arm"]][row["cause"]].add(row["rep"])
    stability[case] = {arm: {cause: len(reps) for cause, reps in cs.items()} for arm, cs in per_rep.items()}
out = {"rounds": rounds, "per_arm": {a: dict(c) for a, c in per_arm.items()}, "pairs": pairs, "side_pairs": side_pairs, "side_verdicts": side_verdicts, "gates": gates, "stability": stability, "findings": finding_rows, "analyzer": analysis["aggregates"]}
json.dump(out, open(f"{B}/metrics.json", "w"), indent=1)
print(json.dumps(out["per_arm"], indent=1)); print(json.dumps({k: v["aggregate"] for k, v in side_pairs.items()})); print(json.dumps(gates, indent=1))
