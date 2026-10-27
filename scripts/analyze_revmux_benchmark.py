#!/usr/bin/env python3
"""Measure findings and dispositions in revmux benchmark rounds."""

import argparse
import collections
import json
from pathlib import Path


STAGES = (("found", "stages/1-found.json"), ("synthesized", "stages/2-synthesized.json"),
          ("verified", "stages/3-verified.json"), ("final", "findings.json"))
FATES = ("findings", "pre_existing", "immaterial", "open_questions", "gone")


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def records(document):
    for bucket, values in document.items():
        if bucket == "sources" or not isinstance(values, list):
            continue
        for finding in values:
            yield bucket, finding


def identity(bench):
    if not bench:
        return None, None, None
    return bench.get("case"), bench.get("arm"), bench.get("repetition")


def analyze(tasks_dir):
    rounds = []
    # A round is exactly <task>/<run>, and must have at least one round marker.
    round_dirs = set()
    for task_dir in tasks_dir.iterdir() if tasks_dir.exists() else ():
        if not task_dir.is_dir():
            continue
        for round_dir in task_dir.iterdir():
            if round_dir.is_dir() and any((round_dir / marker).exists()
                                          for marker in ("manifest.json", "bench.json", "events.jsonl")):
                round_dirs.add(round_dir)
    for round_dir in sorted(round_dirs):
        relative_round = str(round_dir.relative_to(tasks_dir))
        paths = {name: round_dir / path for name, path in STAGES}
        manifest_path = round_dir / "manifest.json"
        bench_path = round_dir / "bench.json"
        try:
            bench = load(bench_path) if bench_path.exists() else None
        except (json.JSONDecodeError, OSError):
            bench = None
        case, arm, repetition = identity(bench)
        try:
            manifest = load(manifest_path)
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            item = {"round": relative_round, "unreadable": "manifest.json"}
            if bench is not None:
                item.update(case=case, arm=arm, repetition=repetition)
            rounds.append(item)
            continue
        failed_path = next((path for path in paths.values() if not path.exists()), None)
        if failed_path is not None:
            item = {"round": relative_round,
                    "unreadable": str(failed_path.relative_to(round_dir))}
            if bench is not None:
                item.update(case=case, arm=arm, repetition=repetition)
            rounds.append(item)
            continue
        try:
            documents = {name: load(path) for name, path in paths.items()}
        except (json.JSONDecodeError, OSError):
            # Identify the first invalid stage deterministically.
            failed_path = next(path for path in paths.values()
                               if not _valid_json(path))
            item = {"round": relative_round,
                    "unreadable": str(failed_path.relative_to(round_dir))}
            if bench is not None:
                item.update(case=case, arm=arm, repetition=repetition)
            rounds.append(item)
            continue
        stages = {}
        for name, document in documents.items():
            counts = collections.Counter(finding.get("severity", "") for _, finding in records(document))
            stages[name] = dict(sorted(counts.items()))
        synthesized = {finding["id"]: finding for _, finding in records(documents["synthesized"])}
        dropped = set()
        events_path = round_dir / "events.jsonl"
        if events_path.exists():
            for line in events_path.read_text(encoding="utf-8").splitlines():
                event = json.loads(line)
                if event.get("kind") == "dropped":
                    dropped.update(item.get("id") for item in event.get("findings", []))
        found_fates = collections.Counter()
        for _, finding in records(documents["found"]):
            finding_id = finding.get("id")
            found_fates["kept" if finding_id in synthesized else
                        "dropped" if finding_id in dropped else "merged"] += 1
        verified = {finding["id"]: bucket for bucket, finding in records(documents["verified"])}
        fates = collections.defaultdict(collections.Counter)
        agents = {agent.get("name"): agent.get("executor", "unknown")
                  for agent in manifest.get("agents", [])}
        for finding in synthesized.values():
            fate = verified.get(finding["id"], "gone")
            vendors = sorted({agents.get(source, "unknown") for source in finding.get("sources", [])})
            fates["+".join(vendors)][fate] += 1
        fates = {vendor: {fate: counts.get(fate, 0) for fate in FATES}
                 for vendor, counts in fates.items()}
        rounds.append({"case": case, "arm": arm, "repetition": repetition,
                       "degraded": bool(documents["found"].get("sources", {}).get("degraded")),
                       "verify_failed": any(finding.get("verdict") == "unverified"
                                            for _, finding in records(documents["final"])),
                       "stages": stages,
                       "found_fates": {fate: found_fates[fate] for fate in ("kept", "dropped", "merged")},
                       "fates": {key: value for key, value in sorted(fates.items())}})
    rounds.sort(key=lambda item: (item.get("case") or "", item.get("arm") or "",
                                  item.get("repetition") or 0, item.get("round", "")))
    aggregates = {"by_case": {}, "by_arm": {}}
    for group_name, key in (("by_case", "case"), ("by_arm", "arm")):
        groups = {}
        for round_data in rounds:
            if round_data.get("case") is None or round_data.get("arm") is None:
                continue
            group = groups.setdefault(round_data[key], {"rounds": 0, "degraded_rounds": 0,
                                                         "unreadable_rounds": 0, "verify_failed_rounds": 0,
                                                         "stages": {name: collections.Counter() for name, _ in STAGES}})
            if "unreadable" in round_data:
                group["unreadable_rounds"] += 1
                continue
            group["rounds"] += 1
            group["degraded_rounds"] += int(round_data["degraded"])
            group["verify_failed_rounds"] += int(round_data["verify_failed"])
            for stage, counts in round_data["stages"].items():
                group["stages"][stage].update(counts)
        aggregates[group_name] = {name: {"rounds": value["rounds"], "degraded_rounds": value["degraded_rounds"],
                                          "unreadable_rounds": value["unreadable_rounds"],
                                          "verify_failed_rounds": value["verify_failed_rounds"],
                                          "stages": {stage: dict(sorted(counts.items())) for stage, counts in value["stages"].items()}}
        for name, value in sorted(groups.items())}
    return {"rounds": rounds, "aggregates": aggregates}


def _valid_json(path):
    try:
        load(path)
    except (json.JSONDecodeError, OSError):
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tasks-dir", type=Path, required=True)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    measurement = analyze(args.tasks_dir)
    if args.json:
        print(json.dumps(measurement, indent=2, sort_keys=False))
    else:
        print("Case | Arm | Repetition | Status")
        for item in measurement["rounds"]:
            if "unreadable" in item:
                case = item.get("case") or "unidentified"
                arm = item.get("arm") or "unidentified"
                repetition = item.get("repetition") or "unidentified"
                print(f"{case} | {arm} | {repetition} | unreadable")
            else:
                if item.get("case") is None or item.get("arm") is None:
                    print("unidentified | unidentified | unidentified | unidentified")
                else:
                    print(f"{item['case']} | {item['arm']} | {item['repetition']} | {'yes' if item['degraded'] else 'no'}")
        unreadable = sum("unreadable" in item for item in measurement["rounds"])
        unidentified = sum(item.get("case") is None or item.get("arm") is None
                           for item in measurement["rounds"])
        print(f"unreadable: {unreadable}, unidentified: {unidentified}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
