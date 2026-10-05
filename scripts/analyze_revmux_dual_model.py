#!/usr/bin/env python3

import argparse
import collections
import json
from pathlib import Path


GROUPS = ("bugs+impl", "arch+quality", "docs+tests", "adversarial", "lean")
EXPECTED_SOURCES = {
    f"{group}-{model}" for group in GROUPS for model in ("claude", "codex")
}
BUCKETS = ("findings", "pre_existing", "immaterial")
REQUIRED_ARTIFACTS = (
    "stages/1-found.json",
    "stages/2-synthesized.json",
    "stages/3-verified.json",
    "findings.json",
    "events.jsonl",
)


def load_json(path):
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def records(report):
    for bucket in BUCKETS:
        for finding in report.get(bucket, []):
            yield bucket, finding


def normalized(value):
    if isinstance(value, collections.Counter):
        return dict(sorted(value.items()))
    if isinstance(value, dict):
        return {key: normalized(item) for key, item in value.items()}
    if isinstance(value, list):
        return [normalized(item) for item in value]
    return value


def rejection_reasons(round_dir, manifest):
    reasons = []
    if manifest.get("profile") != "dual-model":
        return ["not-dual-model"]
    missing = [path for path in REQUIRED_ARTIFACTS if not (round_dir / path).is_file()]
    if missing:
        reasons.append("missing-artifact")
        return reasons
    agents = manifest.get("agents", [])
    if len(agents) != 10 or {agent.get("name") for agent in agents} != EXPECTED_SOURCES:
        reasons.append("not-full-roster")
    found_sources = load_json(round_dir / "stages/1-found.json").get("sources", {})
    if (
        found_sources.get("expected") != 10
        or found_sources.get("reported") != 10
        or found_sources.get("degraded")
    ):
        reasons.append("degraded")
    if manifest.get("degraded") not in (None, []):
        reasons.append("manifest-degraded")
    if any(agent.get("degraded") for agent in agents):
        reasons.append("agent-degraded")
    return reasons


def analyze(tasks_dir):
    result = {
        "schema_version": 1,
        "tasks_dir": str(tasks_dir),
        "corpus": {
            "dual_model_rounds": 0,
            "eligible_rounds": 0,
            "eligible_tasks": 0,
            "unreadable_manifests": [],
            "rejected": [],
        },
        "rounds": [],
        "totals": {
            "found_records": 0,
            "found_by_source": collections.Counter(),
            "synthesized_records": 0,
            "synthesis_source_memberships": collections.Counter(),
            "find_to_synthesis_reduction": 0,
            "verified_records": 0,
            "verified_buckets": collections.Counter(),
            "verify_removed_ids": 0,
            "final_records": 0,
            "final_buckets": collections.Counter(),
            "final_disposition_severity": collections.Counter(),
            "final_cross_model_records": 0,
            "final_paired_group_records": collections.Counter(),
            "single_source_actionable_by_source": collections.Counter(),
            "single_source_actionable": [],
            "raised_mismatches": [],
            "duration_ms": 0,
            "stage_duration_ms": collections.Counter(),
            "find_agent_tokens_by_executor": collections.Counter(),
            "pipeline_tokens": 0,
        },
    }
    eligible_tasks = set()

    for manifest_path in sorted(tasks_dir.glob("*/*/manifest.json")):
        round_dir = manifest_path.parent
        try:
            manifest = load_json(manifest_path)
        except (json.JSONDecodeError, OSError) as error:
            result["corpus"]["unreadable_manifests"].append(
                {"round": str(round_dir), "error": type(error).__name__}
            )
            continue
        if manifest.get("profile") != "dual-model":
            continue
        result["corpus"]["dual_model_rounds"] += 1
        reasons = rejection_reasons(round_dir, manifest)
        if reasons:
            result["corpus"]["rejected"].append(
                {"round": str(round_dir), "reasons": reasons}
            )
            continue

        found = load_json(round_dir / "stages/1-found.json")
        synthesized = load_json(round_dir / "stages/2-synthesized.json")
        verified = load_json(round_dir / "stages/3-verified.json")
        final = load_json(round_dir / "findings.json")
        found_records = list(records(found))
        synthesized_records = list(records(synthesized))
        verified_records = list(records(verified))
        final_records = list(records(final))
        found_by_source = collections.Counter(
            source
            for _, finding in found_records
            for source in finding.get("sources", [])
        )
        task = manifest.get("task", round_dir.parent.name)
        run = manifest.get("run", round_dir.name)
        eligible_tasks.add(task)
        result["corpus"]["eligible_rounds"] += 1

        for agent in manifest.get("agents", []):
            name = agent["name"]
            if agent.get("raised", 0) != found_by_source[name]:
                result["totals"]["raised_mismatches"].append(
                    {
                        "task": task,
                        "run": run,
                        "source": name,
                        "manifest": agent.get("raised", 0),
                        "stage": found_by_source[name],
                    }
                )
            result["totals"]["find_agent_tokens_by_executor"][
                agent.get("executor", "unknown")
            ] += agent.get("tokens", 0)

        result["rounds"].append(
            {
                "task": task,
                "run": run,
                "started_at": manifest.get("started_at"),
                "found": len(found_records),
                "synthesized": len(synthesized_records),
                "final_actionable": len(final.get("findings", [])),
                "final_total": len(final_records),
                "duration_ms": manifest.get("duration_ms", 0),
            }
        )

        totals = result["totals"]
        totals["found_records"] += len(found_records)
        totals["found_by_source"].update(found_by_source)
        totals["synthesized_records"] += len(synthesized_records)
        totals["find_to_synthesis_reduction"] += len(found_records) - len(
            synthesized_records
        )
        for _, finding in synthesized_records:
            totals["synthesis_source_memberships"].update(finding.get("sources", []))

        totals["verified_records"] += len(verified_records)
        for bucket, _ in verified_records:
            totals["verified_buckets"][bucket] += 1
        synthesized_ids = {finding["id"] for _, finding in synthesized_records}
        verified_ids = {finding["id"] for _, finding in verified_records}
        totals["verify_removed_ids"] += len(synthesized_ids - verified_ids)

        totals["final_records"] += len(final_records)
        for bucket, finding in final_records:
            totals["final_buckets"][bucket] += 1
            totals["final_disposition_severity"][
                f"{bucket}|{finding.get('verdict', '')}|{finding.get('severity', '')}"
            ] += 1
            sources = finding.get("sources", [])
            models = {source.rsplit("-", 1)[-1] for source in sources}
            if {"claude", "codex"} <= models:
                totals["final_cross_model_records"] += 1
            for group in GROUPS:
                if {f"{group}-claude", f"{group}-codex"} <= set(sources):
                    totals["final_paired_group_records"][group] += 1
            if bucket == "findings" and len(sources) == 1:
                source = sources[0]
                totals["single_source_actionable_by_source"][source] += 1
                totals["single_source_actionable"].append(
                    {
                        "task": task,
                        "run": run,
                        "id": finding.get("id", ""),
                        "source": source,
                        "severity": finding.get("severity", ""),
                        "verdict": finding.get("verdict", ""),
                        "title": finding.get("title", ""),
                        "file": finding.get("file", ""),
                        "line": finding.get("line", 0),
                    }
                )

        totals["duration_ms"] += manifest.get("duration_ms", 0)
        totals["pipeline_tokens"] += manifest.get("tokens", 0)
        for stage in manifest.get("stages", []):
            totals["stage_duration_ms"][stage["name"]] += stage.get("duration_ms", 0)

    result["corpus"]["eligible_tasks"] = len(eligible_tasks)
    result["rounds"].sort(key=lambda item: (item.get("started_at") or "", item["task"], item["run"]))
    result["totals"]["single_source_actionable"].sort(
        key=lambda item: (item["task"], item["run"], item["source"], item["id"])
    )
    return normalized(result)


def main():
    parser = argparse.ArgumentParser(
        description="Aggregate complete full-roster revmux dual-model rounds."
    )
    parser.add_argument(
        "tasks_dir",
        nargs="?",
        type=Path,
        default=Path.home() / ".local/state/revmux/tasks",
    )
    args = parser.parse_args()
    print(json.dumps(analyze(args.tasks_dir), indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
