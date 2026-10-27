#!/usr/bin/env python3
"""Measure findings and dispositions in revmux benchmark rounds."""

import argparse
import collections
import json
import os
import re
import secrets
import sys
import tempfile
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


def _round_directories(tasks_dir):
    """Return archive round directories, including incomplete rounds."""
    round_dirs = set()
    for task_dir in tasks_dir.iterdir() if tasks_dir.exists() else ():
        if not task_dir.is_dir():
            continue
        for round_dir in task_dir.iterdir():
            if round_dir.is_dir() and any((round_dir / marker).exists()
                                          for marker in ("manifest.json", "bench.json", "events.jsonl")):
                round_dirs.add(round_dir)
    return sorted(round_dirs)


def _opaque_code(used):
    code = secrets.token_hex(16)
    while code in used:
        code = secrets.token_hex(16)
    used.add(code)
    return code


def export_blind(tasks_dir, output, key_path):
    """Project an archive into a packet that contains no arm identity."""
    output_resolved = output.resolve()
    key_resolved = key_path.resolve()
    if output.exists():
        raise ValueError(f"refusing to overwrite existing packet path: {output}")
    if key_path.exists():
        raise ValueError(f"refusing to overwrite existing key path: {key_path}")
    if key_resolved == output_resolved or output_resolved in key_resolved.parents:
        raise ValueError(f"refusing key path {key_path}: it is inside packet path {output}")

    packet = {"format": "revmux-bench-blind/1", "rounds": []}
    key = {"rounds": {}, "findings": {}, "agents": {}, "references": {}}
    round_codes = set()
    finding_codes = set()
    agent_tokens = set()
    round_dirs = _round_directories(tasks_dir)
    # Archive identity is public prose, so its replacements must not depend on
    # the round currently being projected.  Collect the vocabulary first and
    # expose it only in the sealed key.
    placeholder_values = {"[arm]": set(), "[case]": set(), "[round]": set()}
    task_names = set()
    relative_rounds = set()
    for round_dir in round_dirs:
        task_names.add(round_dir.parent.name)
        relative_rounds.add(str(round_dir.relative_to(tasks_dir)))
        try:
            bench = load(round_dir / "bench.json")
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            continue
        case, arm, _ = identity(bench)
        if isinstance(case, str) and case:
            placeholder_values["[case]"].add(case)
        if isinstance(arm, str) and arm:
            placeholder_values["[arm]"].add(arm)
    placeholder_values["[round]"].update(task_names)
    placeholder_values["[round]"].update(relative_rounds)
    for form in (str(tasks_dir), os.path.abspath(str(tasks_dir)), str(tasks_dir.resolve())):
        if form:
            placeholder_values["[round]"].add(form)
    key["placeholders"] = {name: sorted(values) for name, values in placeholder_values.items()}
    # Read every readable manifest before projecting any round.  A finding can
    # quote an agent that was not declared by its own round, so redaction must
    # not depend on traversal order.
    collected_agent_names = set()
    for round_dir in round_dirs:
        try:
            manifest = load(round_dir / "manifest.json")
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            continue
        for agent in manifest.get("agents", []):
            name = agent.get("name")
            if isinstance(name, str):
                collected_agent_names.add(name)
    for round_dir in round_dirs:
        round_code = _opaque_code(round_codes)
        relative_round = str(round_dir.relative_to(tasks_dir))
        bench = None
        try:
            bench = load(round_dir / "bench.json")
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            pass
        case, arm, repetition = identity(bench)
        key["rounds"][round_code] = {"case": case, "arm": arm,
                                      "repetition": repetition, "path": relative_round}
        record = {"round_code": round_code}
        if bench is None:
            record["state"] = "unidentified"
            packet["rounds"].append(record)
            continue

        manifest_path = round_dir / "manifest.json"
        try:
            manifest = load(manifest_path)
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            record.update(state="unreadable", unreadable="manifest.json")
            packet["rounds"].append(record)
            continue

        # Agent names are useful to the sealed-key operator, but must never
        # reach the adjudicator's packet, including when cited in prose.
        # Tokens are scoped to this round.  Generate the complete map from the
        # archive-wide name set, even for names absent from this manifest.
        agent_replacements = {}
        for name in sorted(collected_agent_names):
            token = _opaque_code(agent_tokens)
            agent_replacements[name] = token

        paths = {name: round_dir / path for name, path in STAGES}
        failed_path = next((path for path in paths.values() if not path.exists()), None)
        if failed_path is not None:
            record.update(state="unreadable", unreadable=str(failed_path.relative_to(round_dir)))
            packet["rounds"].append(record)
            continue
        try:
            documents = {name: load(path) for name, path in paths.items()}
        except (json.JSONDecodeError, OSError):
            failed_path = next(path for path in paths.values() if not _valid_json(path))
            record.update(state="unreadable", unreadable=str(failed_path.relative_to(round_dir)))
            packet["rounds"].append(record)
            continue

        synthesized = {finding.get("id"): finding
                       for _, finding in records(documents["synthesized"])}
        final = {finding.get("id"): finding
                 for _, finding in records(documents["final"])}
        final_fates = {}
        for bucket in ("findings", "pre_existing", "immaterial", "open_questions"):
            for finding in documents["final"].get(bucket, []):
                if isinstance(finding, dict) and finding.get("id") is not None:
                    final_fates[finding["id"]] = {
                        "findings": "kept",
                        "pre_existing": "pre_existing",
                        "immaterial": "immaterial",
                        "open_questions": "open_question",
                    }[bucket]
        dropped = set()
        events_path = round_dir / "events.jsonl"
        if events_path.exists():
            try:
                for line in events_path.read_text(encoding="utf-8").splitlines():
                    event = json.loads(line)
                    if event.get("kind") == "dropped":
                        dropped.update(item.get("id") for item in event.get("findings", []))
            except (json.JSONDecodeError, OSError):
                record.update(state="unreadable", unreadable="events.jsonl")
                packet["rounds"].append(record)
                continue
        findings = []
        found_ids = [finding.get("id") for _, finding in records(documents["found"])]
        finding_token_by_id = {}
        for finding_id in found_ids:
            if finding_id is not None:
                finding_token_by_id[finding_id] = _opaque_code(finding_codes)

        def redact(value):
            if not isinstance(value, str):
                return value
            # Redact all sensitive targets in one pass over the original
            # text.  In particular, do not replace a reference first: a
            # shorter reference can otherwise split a longer archive path.
            reference_replacements = {}
            replacements = {}
            for raw, replacement in finding_token_by_id.items():
                replacements[raw] = (replacement, True)
            # Foreign finding references share the matcher with every other
            # target.  Their replacement is allocated only if the reference
            # actually occurs in this round.
            for name in collected_agent_names:
                raw = re.escape(name) + r"-\d+"
                replacements.setdefault(raw, (None, "reference"))
            for raw, replacement in agent_replacements.items():
                replacements.setdefault(raw, (replacement, False))
            for raw in placeholder_values["[arm]"]:
                replacements.setdefault(raw, ("[arm]", False))
            for raw in placeholder_values["[case]"]:
                replacements.setdefault(raw, ("[case]", False))
            for raw in placeholder_values["[round]"]:
                replacements.setdefault(raw, ("[round]", False))

            patterns = []
            for raw, (replacement, kind) in replacements.items():
                if kind is True:
                    boundary = (r"(?<![A-Za-z0-9_])" + re.escape(raw) +
                                r"(?![A-Za-z0-9_])")
                elif kind == "reference":
                    boundary = (r"(?<![A-Za-z0-9_+\-])" + raw +
                                r"(?![A-Za-z0-9_+\-])")
                else:
                    boundary = (r"(?<![A-Za-z0-9_+\-])" + re.escape(raw) +
                                r"(?![A-Za-z0-9_+\-])")
                patterns.append((raw, replacement, kind, re.compile(boundary)))
            patterns.sort(key=lambda item: -len(item[0]))
            if not patterns:
                return value
            matcher = re.compile("|".join(
                f"(?P<blind_target_{index}>{pattern.pattern})"
                for index, (_, _, _, pattern) in enumerate(patterns)))

            def replace(match):
                index = next(index for index in range(len(patterns))
                              if match.group(f"blind_target_{index}") is not None)
                raw, replacement, kind, _ = patterns[index]
                matched = match.group(0)
                if kind == "reference":
                    local_code = finding_token_by_id.get(matched)
                    if local_code is not None:
                        return local_code
                    replacement = reference_replacements.get(matched)
                    if replacement is None:
                        replacement = _opaque_code(finding_codes)
                        reference_replacements[matched] = replacement
                        key["references"][replacement] = {
                            "round_code": round_code, "text": matched}
                if raw in agent_replacements:
                    key["agents"][replacement] = {"round_code": round_code, "name": raw}
                return replacement

            return matcher.sub(replace, value)

        for _, finding in records(documents["found"]):
            finding_id = finding.get("id")
            fate = final_fates.get(finding_id)
            if fate is None:
                fate = ("dropped" if finding_id in dropped else
                        "merged" if finding_id not in synthesized else
                        "gone")
            finding_code = finding_token_by_id[finding_id]
            key["findings"][finding_code] = finding_id
            source = final.get(finding_id, finding) if finding_id in final_fates else finding
            projected = {field: source.get(field) for field in
                         ("file", "line", "end_line", "severity", "confidence",
                          "title", "body", "fix")}
            projected = {field: (value if field == "file" else redact(value))
                         for field, value in projected.items()}
            projected["verdict"] = redact(source.get("verdict", ""))
            projected.update(finding_code=finding_code, stage_fate=fate)
            findings.append(projected)
        record.update(state="complete", base=bench.get("base"), head=bench.get("head"),
                      findings=findings)
        packet["rounds"].append(record)

    def atomic_write(path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp",
                                                  dir=path.parent, text=True)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
        except BaseException:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise

    # Codes intentionally carry no archive ordering; sort only after generation.
    packet["rounds"].sort(key=lambda record: record["round_code"])
    atomic_write(key_path, json.dumps(key, indent=2) + "\n")
    output.mkdir(parents=True)
    atomic_write(output / "packet.json", json.dumps(packet, indent=2) + "\n")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "export-blind":
        parser = argparse.ArgumentParser(description="Export an opaque adjudication packet.")
        parser.add_argument("export_blind", help=argparse.SUPPRESS)
        parser.add_argument("--tasks-dir", type=Path, required=True)
        parser.add_argument("--out", type=Path, required=True)
        parser.add_argument("--key", type=Path, required=True)
        args = parser.parse_args()
        try:
            export_blind(args.tasks_dir, args.out, args.key)
        except ValueError as error:
            print(f"error: {error}", file=sys.stderr)
            return 1
        return 0
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
