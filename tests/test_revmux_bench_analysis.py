"""The benchmark analyzer reports hand-adjudicable archive measurements."""

import copy
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ANALYZER = ROOT / "scripts/analyze_revmux_benchmark.py"
FIXTURE_ARCHIVE = ROOT / "tests/fixtures/revmux-bench/archive"


class RevmuxBenchmarkAnalysisTest(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.archive = Path(self.temporary_directory.name) / "archive"
        shutil.copytree(FIXTURE_ARCHIVE, self.archive)
        self.real = self.archive / "real-round/01-real"
        self.companion = self.archive / "companion-round/01-companion"
        self.template = self.load(self.real / "stages/1-found.json")["findings"][0]

    def tearDown(self):
        self.temporary_directory.cleanup()

    def load(self, path):
        return json.loads(path.read_text(encoding="utf-8"))

    def save(self, path, document):
        path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")

    def copy_round(self, source, name):
        destination = self.archive / name / "01-bench"
        shutil.copytree(source, destination)
        return destination

    def bench(self, directory, case, arm, repetition=1):
        self.save(directory / "bench.json", {"case": case, "arm": arm, "repetition": repetition,
                  "base": "base", "head": "head", "profile": "fixed", "cwd": "/fixture"})

    def finding(self, identifier, severity, sources, verdict=""):
        result = copy.deepcopy(self.template)
        result.update(id=identifier, severity=severity, sources=sources, verdict=verdict)
        return result

    def stage(self, directory, name, findings, **buckets):
        path = directory / ("findings.json" if name == "final" else f"stages/{name}.json")
        document = self.load(path)
        document["sources"]["degraded"] = buckets.pop("degraded", [])
        document["findings"] = findings
        for bucket in ("pre_existing", "immaterial", "open_questions"):
            if bucket in document:
                document[bucket] = buckets.get(bucket, [])
        self.save(path, document)

    def configure_measurement_archive(self):
        self.bench(self.real, "case-alpha", "arm-x-1")
        keep = self.finding("keep", "major", ["bugs+impl-codex"], "refined")
        old = self.finding("old", "major", ["adversarial-claude"])
        noise = self.finding("noise", "minor", ["bugs+impl-codex", "adversarial-claude"])
        question = self.finding("question", "minor", ["adversarial-claude"])
        gone = self.finding("gone", "minor", ["unknown-agent"])
        dropped = self.finding("dropped", "minor", ["bugs+impl-codex"])
        merged = self.finding("merged", "minor", ["adversarial-claude"])
        self.stage(self.real, "1-found", [self.finding("keep", "critical", keep["sources"]), old, noise, question, gone, dropped, merged])
        self.stage(self.real, "2-synthesized", [keep, old, noise, question, gone])
        self.stage(self.real, "3-verified", [keep], pre_existing=[old], immaterial=[noise], open_questions=[question])
        self.stage(self.real, "final", [keep])
        (self.real / "events.jsonl").write_text(json.dumps({"kind": "dropped", "findings": [dropped]}) + "\n", encoding="utf-8")
        companion_manifest = self.load(self.companion / "manifest.json")
        companion_manifest["agents"] = [agent for agent in companion_manifest["agents"] if agent["name"] == "bugs+impl-codex"]
        self.save(self.companion / "manifest.json", companion_manifest)
        self.bench(self.companion, "case-alpha", "opaque-b")
        minor = self.finding("unverified", "minor", ["bugs+impl-codex"], "unverified")
        for name in ("1-found", "2-synthesized", "3-verified", "final"):
            self.stage(self.companion, name, [minor])
        degraded = self.copy_round(self.companion, "degraded-round")
        self.bench(degraded, "case-alpha", "opaque-c")
        for name in ("1-found", "2-synthesized", "3-verified", "final"):
            self.stage(degraded, name, [self.finding("degraded", "minor", ["bugs+impl-codex"])], degraded=["stand-in"])
        legacy = self.copy_round(self.companion, "legacy-round")
        (legacy / "bench.json").unlink()
        legacy_final = self.load(legacy / "findings.json")
        legacy_final["findings"][0]["verdict"] = ""
        self.save(legacy / "findings.json", legacy_final)
        missing_manifest = self.copy_round(self.companion, "missing-manifest")
        self.bench(missing_manifest, "case-incomplete", "arm-incomplete")
        (missing_manifest / "manifest.json").unlink()
        missing_stage = self.copy_round(self.real, "missing-stage")
        (missing_stage / "bench.json").unlink()
        (missing_stage / "stages/2-synthesized.json").unlink()

    def add_prompt_stages(self):
        prompt_stages = self.real / "prompts/stages"
        prompt_stages.mkdir(parents=True)
        (prompt_stages / "synthesis.md").write_text("You are merging a review panel's findings into one set.\n", encoding="utf-8")

    def run_analyzer(self, *arguments):
        return subprocess.run(["python3", str(ANALYZER), "--tasks-dir", str(self.archive), *arguments],
                              check=False, capture_output=True, text=True)

    def test_measures_identity_fates_vendors_independent_round_states_and_ignores_prompt_stages(self):
        # #given a copied real round and temporary mutations for every exceptional scenario
        self.configure_measurement_archive()
        self.add_prompt_stages()
        result = self.run_analyzer("--json")
        self.assertEqual(result.returncode, 0)
        measurement = json.loads(result.stdout)
        rounds = sorted(measurement["rounds"], key=lambda item: json.dumps(item, sort_keys=True))
        # #when the analyzer reads bench identities and archive outcomes
        observed = rounds, measurement["aggregates"]
        # #then fates, vendors, unreadable rounds, and independent flags retain their records
        self.assertEqual(observed, (sorted([
            {"case": "case-alpha", "arm": "arm-x-1", "repetition": 1, "degraded": False, "verify_failed": False,
             "stages": {"found": {"critical": 1, "major": 1, "minor": 5}, "synthesized": {"major": 2, "minor": 3}, "verified": {"major": 2, "minor": 2}, "final": {"major": 1}},
             "found_fates": {"kept": 5, "dropped": 1, "merged": 1},
             "fates": {"claude": {"findings": 0, "pre_existing": 1, "immaterial": 0, "open_questions": 1, "gone": 0}, "claude+codex": {"findings": 0, "pre_existing": 0, "immaterial": 1, "open_questions": 0, "gone": 0}, "codex": {"findings": 1, "pre_existing": 0, "immaterial": 0, "open_questions": 0, "gone": 0}, "unknown": {"findings": 0, "pre_existing": 0, "immaterial": 0, "open_questions": 0, "gone": 1}}},
            {"case": "case-alpha", "arm": "opaque-b", "repetition": 1, "degraded": False, "verify_failed": True,
             "stages": {name: {"minor": 1} for name in ("found", "synthesized", "verified", "final")}, "found_fates": {"kept": 1, "dropped": 0, "merged": 0}, "fates": {"codex": {"findings": 1, "pre_existing": 0, "immaterial": 0, "open_questions": 0, "gone": 0}}},
            {"case": "case-alpha", "arm": "opaque-c", "repetition": 1, "degraded": True, "verify_failed": False,
             "stages": {name: {"minor": 1} for name in ("found", "synthesized", "verified", "final")}, "found_fates": {"kept": 1, "dropped": 0, "merged": 0}, "fates": {"codex": {"findings": 1, "pre_existing": 0, "immaterial": 0, "open_questions": 0, "gone": 0}}},
            {"case": None, "arm": None, "repetition": None, "degraded": False, "verify_failed": False,
             "stages": {name: {"minor": 1} for name in ("found", "synthesized", "verified", "final")}, "found_fates": {"kept": 1, "dropped": 0, "merged": 0}, "fates": {"codex": {"findings": 1, "pre_existing": 0, "immaterial": 0, "open_questions": 0, "gone": 0}}},
            {"round": "missing-manifest/01-bench", "case": "case-incomplete", "arm": "arm-incomplete", "repetition": 1, "unreadable": "manifest.json"},
            {"round": "missing-stage/01-bench", "unreadable": "stages/2-synthesized.json"},
        ], key=lambda item: json.dumps(item, sort_keys=True)), {
            "by_case": {"case-alpha": {"rounds": 3, "degraded_rounds": 1, "unreadable_rounds": 0, "verify_failed_rounds": 1, "stages": {"found": {"critical": 1, "major": 1, "minor": 7}, "synthesized": {"major": 2, "minor": 5}, "verified": {"major": 2, "minor": 4}, "final": {"major": 1, "minor": 2}}}, "case-incomplete": {"rounds": 0, "degraded_rounds": 0, "unreadable_rounds": 1, "verify_failed_rounds": 0, "stages": {name: {} for name in ("found", "synthesized", "verified", "final")}}},
            "by_arm": {"arm-x-1": {"rounds": 1, "degraded_rounds": 0, "unreadable_rounds": 0, "verify_failed_rounds": 0, "stages": {"found": {"critical": 1, "major": 1, "minor": 5}, "synthesized": {"major": 2, "minor": 3}, "verified": {"major": 2, "minor": 2}, "final": {"major": 1}}}, "opaque-b": {"rounds": 1, "degraded_rounds": 0, "unreadable_rounds": 0, "verify_failed_rounds": 1, "stages": {name: {"minor": 1} for name in ("found", "synthesized", "verified", "final")}}, "opaque-c": {"rounds": 1, "degraded_rounds": 1, "unreadable_rounds": 0, "verify_failed_rounds": 0, "stages": {name: {"minor": 1} for name in ("found", "synthesized", "verified", "final")}}, "arm-incomplete": {"rounds": 0, "degraded_rounds": 0, "unreadable_rounds": 1, "verify_failed_rounds": 0, "stages": {name: {} for name in ("found", "synthesized", "verified", "final")}}},
        }))

    def test_default_table_distinguishes_unidentified_and_unreadable_rounds(self):
        # #given the same complete and exceptional archive observations
        self.configure_measurement_archive()
        result = self.run_analyzer()
        # #when the human-readable table is rendered
        self.assertEqual(result.returncode, 0)
        observed = result.stdout
        # #then unreadable and unidentified remain distinct and counted
        self.assertEqual(observed, "Case | Arm | Repetition | Status\n"
            "unidentified | unidentified | unidentified | unidentified\n"
            "unidentified | unidentified | unidentified | unreadable\n"
            "case-alpha | arm-x-1 | 1 | no\ncase-alpha | opaque-b | 1 | no\ncase-alpha | opaque-c | 1 | yes\n"
            "case-incomplete | arm-incomplete | 1 | unreadable\nunreadable: 2, unidentified: 2\n")


if __name__ == "__main__":
    unittest.main()
