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

    def bench(self, directory, case, arm, repetition=1, base="base", head="head"):
        self.save(directory / "bench.json", {"case": case, "arm": arm, "repetition": repetition,
                   "base": base, "head": head, "profile": "fixed", "cwd": "/fixture"})

    def finding(self, identifier, severity, sources, verdict="", **fields):
        result = copy.deepcopy(self.template)
        result.update(id=identifier, severity=severity, sources=sources, verdict=verdict)
        result.update(fields)
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

    def export_blind(self, packet_directory, key_path):
        return subprocess.run(["python3", str(ANALYZER), "export-blind", "--tasks-dir", str(self.archive),
                               "--out", str(packet_directory), "--key", str(key_path)],
                              check=False, capture_output=True, text=True)

    def configure_blind_export_archive(self):
        self.bench(self.real, "case-alpha", "arm-cobalt", base="frozen-alpha-base", head="frozen-alpha-head")
        kept = self.finding("adversarial-claude-1", "minor", [], "found-kept",
                            file="found-kept.py", line=11, end_line=12, confidence=51,
                            title="Found kept title", body="Found kept body", fix="Found kept fix")
        kept_final = self.finding("adversarial-claude-1", "critical", [], "confirmed",
                                  file="final-kept.py", line=101, end_line=102, confidence=91,
                                  title="Final kept title", body="Final kept body", fix="Final kept fix")
        merged = self.finding("bugs+impl-codex-2", "major", [], "found-merged",
                              file="merged.py", line=21, end_line=22, confidence=61,
                              title="Merged title", body="Merged body", fix="Merged fix")
        dropped = self.finding("adversarial-claude-3", "blocker", [], "found-dropped",
                               file="dropped.py", line=31, end_line=32, confidence=71,
                               title="Dropped title", body="Dropped body", fix="Dropped fix")
        self.stage(self.real, "1-found", [kept, merged, dropped])
        self.stage(self.real, "2-synthesized", [kept])
        self.stage(self.real, "3-verified", [kept])
        self.stage(self.real, "final", [kept_final])
        (self.real / "events.jsonl").write_text(
            json.dumps({"kind": "dropped", "findings": [dropped]}) + "\n", encoding="utf-8")

        self.bench(self.companion, "case-alpha", "arm-umber", repetition=2,
                   base="frozen-alpha-base", head="frozen-alpha-head")
        companion = self.finding("adversarial-claude-4", "low", [], "found-companion",
                                 file="found-companion.py", line=41, end_line=42, confidence=81,
                                 title="Found companion title", body="Found companion body",
                                 fix="Found companion fix")
        companion_final = self.finding("adversarial-claude-4", "info", [], "refined",
                                       file="final-companion.py", line=141, end_line=142, confidence=99,
                                       title="Final companion title", body="Final companion body",
                                       fix="Final companion fix")
        for name in ("1-found", "2-synthesized", "3-verified"):
            self.stage(self.companion, name, [companion])
        self.stage(self.companion, "final", [companion_final])

        unreadable = self.copy_round(self.companion, "unreadable-round")
        self.bench(unreadable, "case-beta", "arm-ochre", base="frozen-beta-base", head="frozen-beta-head")
        (unreadable / "manifest.json").unlink()

        unidentified = self.copy_round(self.companion, "unidentified-round")
        (unidentified / "bench.json").unlink()

    def configure_blind_fates_archive(self):
        self.configure_blind_export_archive()
        kept = self.finding("adversarial-claude-1", "minor", [])
        merged = self.finding("bugs+impl-codex-2", "major", [])
        dropped = self.finding("adversarial-claude-3", "blocker", [])
        pre_existing = self.finding("bugs+impl-codex-5", "low", [])
        immaterial = self.finding("adversarial-claude-6", "info", [])
        open_question = self.finding("bugs+impl-codex-7", "minor", [])
        gone = self.finding("adversarial-claude-8", "major", [])
        kept_final = self.finding("adversarial-claude-1", "critical", [], "confirmed")
        pre_existing_final = self.finding(
            "bugs+impl-codex-5", "critical", [], "pre-existing-final",
            file="final-pre-existing.py", line=201, end_line=202, confidence=81,
            title="Final pre-existing title", body="Final pre-existing body",
            fix="Final pre-existing fix")
        immaterial_final = self.finding(
            "adversarial-claude-6", "major", [], "immaterial-final",
            file="final-immaterial.py", line=211, end_line=212, confidence=82,
            title="Final immaterial title", body="Final immaterial body",
            fix="Final immaterial fix")
        open_question_final = self.finding(
            "bugs+impl-codex-7", "blocker", [], "open-question-final",
            file="final-open-question.py", line=221, end_line=222, confidence=83,
            title="Final open-question title", body="Final open-question body",
            fix="Final open-question fix")
        self.stage(self.real, "1-found", [kept, merged, dropped, pre_existing, immaterial,
                                             open_question, gone])
        self.stage(self.real, "2-synthesized", [kept, gone])
        self.stage(self.real, "3-verified", [kept])
        self.stage(self.real, "final", [kept_final], pre_existing=[pre_existing_final],
                    immaterial=[immaterial_final], open_questions=[open_question_final])
        (self.real / "events.jsonl").write_text(
            json.dumps({"kind": "dropped", "findings": [dropped]}) + "\n", encoding="utf-8")

    def expected_blind_finding(self, fate, **fields):
        return fields | {"stage_fate": fate}

    def normalize_blind_packet(self, packet, key):
        normalized = []
        for round_record in packet["rounds"]:
            record = dict(round_record)
            round_code = record.pop("round_code")
            record["round"] = key["rounds"][round_code]
            if "findings" in record:
                findings = []
                for finding in record["findings"]:
                    item = dict(finding)
                    finding_code = item.pop("finding_code")
                    item["id"] = key["findings"][finding_code]
                    findings.append(item)
                record["findings"] = sorted(findings, key=lambda item: item["id"])
            normalized.append(record)
        return sorted(normalized, key=lambda item: item["round"]["path"])

    def assert_packet_hides(self, packet_directory, identifiers):
        packet_text = "\n".join(path.read_text(encoding="utf-8")
                                  for path in sorted(packet_directory.rglob("*")) if path.is_file())
        self.assertEqual([identifier for identifier in identifiers if identifier in packet_text], [])

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

    def test_export_blind_projects_distinct_final_fields_round_states_and_sealed_key(self):
        # #given fixture round variants whose final records disagree with found records in every projected field
        self.configure_blind_export_archive()
        packet_directory = Path(self.temporary_directory.name) / "packet"
        key_path = Path(self.temporary_directory.name) / "sealed-key.json"
        result = self.export_blind(packet_directory, key_path)
        self.assertEqual(result.returncode, 0, result.stderr)
        packet = self.load(packet_directory / "packet.json")
        key = self.load(key_path)
        # #when the adjudicator opens the packet and the operator opens its separate key
        observed = self.normalize_blind_packet(packet, key), sorted(packet_directory.iterdir()), key_path.exists()
        # #then every finding keeps its hand-authored final or found fields and fate while the key restores its archive identity
        self.assertEqual(observed, ([
            {"state": "complete", "base": "frozen-alpha-base", "head": "frozen-alpha-head", "findings": [
                self.expected_blind_finding(
                    "kept", file="final-companion.py", line=141, end_line=142, severity="info",
                    confidence=99, title="Final companion title", body="Final companion body",
                    fix="Final companion fix", verdict="refined") | {"id": "adversarial-claude-4"},
            ], "round": {"case": "case-alpha", "arm": "arm-umber", "repetition": 2,
                            "path": "companion-round/01-companion"}},
            {"state": "complete", "base": "frozen-alpha-base", "head": "frozen-alpha-head", "findings": [
                self.expected_blind_finding(
                    "kept", file="final-kept.py", line=101, end_line=102, severity="critical",
                    confidence=91, title="Final kept title", body="Final kept body",
                    fix="Final kept fix", verdict="confirmed") | {"id": "adversarial-claude-1"},
                self.expected_blind_finding(
                    "dropped", file="dropped.py", line=31, end_line=32, severity="blocker",
                    confidence=71, title="Dropped title", body="Dropped body", fix="Dropped fix",
                    verdict="found-dropped") | {"id": "adversarial-claude-3"},
                self.expected_blind_finding(
                    "merged", file="merged.py", line=21, end_line=22, severity="major",
                    confidence=61, title="Merged title", body="Merged body", fix="Merged fix",
                    verdict="found-merged") | {"id": "bugs+impl-codex-2"},
            ], "round": {"case": "case-alpha", "arm": "arm-cobalt", "repetition": 1,
                            "path": "real-round/01-real"}},
            {"state": "unidentified", "round": {"case": None, "arm": None, "repetition": None,
                                                      "path": "unidentified-round/01-bench"}},
            {"state": "unreadable", "unreadable": "manifest.json",
              "round": {"case": "case-beta", "arm": "arm-ochre", "repetition": 1,
                        "path": "unreadable-round/01-bench"}},
        ], [packet_directory / "packet.json"], True))

    def test_export_blind_sorts_each_packet_by_opaque_round_code(self):
        # #given two exports with eight round records and independent random round codes
        self.configure_blind_export_archive()
        for number in range(4):
            extra_round = self.copy_round(self.companion, f"order-round-{number}")
            self.bench(extra_round, "case-order", f"arm-order-{number}", repetition=number + 3)
        exports = []
        for number in range(2):
            packet_directory = Path(self.temporary_directory.name) / f"packet-{number}"
            key_path = Path(self.temporary_directory.name) / f"key-{number}.json"
            result = self.export_blind(packet_directory, key_path)
            self.assertEqual(result.returncode, 0, result.stderr)
            packet = self.load(packet_directory / "packet.json")
            key = self.load(key_path)
            exports.append((
                [record["round_code"] for record in packet["rounds"]],
                [key["rounds"][record["round_code"]]["path"] for record in packet["rounds"]],
            ))
        # #when the adjudicator reads records without opening the sealed keys
        observed = ([codes == sorted(codes) for codes, _ in exports],
                    len({tuple(paths) for _, paths in exports}))
        # #then packet order follows random codes and changes between independent exports
        self.assertEqual(observed, ([True, True], 2))

    def test_export_blind_hides_identifiers_and_uses_new_opaque_codes_per_export(self):
        # #given two exports of the same two-arm fixture archive
        self.configure_blind_export_archive()
        first_packet_directory = Path(self.temporary_directory.name) / "packet-one"
        first_key_path = Path(self.temporary_directory.name) / "key-one.json"
        second_packet_directory = Path(self.temporary_directory.name) / "packet-two"
        second_key_path = Path(self.temporary_directory.name) / "key-two.json"
        first_result = self.export_blind(first_packet_directory, first_key_path)
        second_result = self.export_blind(second_packet_directory, second_key_path)
        self.assertEqual((first_result.returncode, second_result.returncode), (0, 0),
                         (first_result.stderr, second_result.stderr))
        first_packet = self.load(first_packet_directory / "packet.json")
        second_packet = self.load(second_packet_directory / "packet.json")
        first_key = self.load(first_key_path)
        second_key = self.load(second_key_path)
        first_round_codes = {round_record["round_code"] for round_record in first_packet["rounds"]}
        second_round_codes = {round_record["round_code"] for round_record in second_packet["rounds"]}
        first_finding_codes = {finding["finding_code"] for round_record in first_packet["rounds"]
                               for finding in round_record.get("findings", [])}
        second_finding_codes = {finding["finding_code"] for round_record in second_packet["rounds"]
                                for finding in round_record.get("findings", [])}
        identifying_strings = ["arm-cobalt", "arm-umber", "arm-ochre", "claude", "codex", "opus",
                                "claude-opus-5-5", "gpt-6.1-sol", "adversarial-claude", "bugs+impl-codex",
                                "adversarial", "bugs", "impl", "1410293", "114035", "3858208",
                                "2026-10-15T11:35:27.145785+02:00", "real-round", "companion-round",
                                "unreadable-round", "unidentified-round", str(first_key_path), str(second_key_path)]
        identifying_strings.extend(["adversarial-claude-1", "bugs+impl-codex-2",
                                    "adversarial-claude-3", "adversarial-claude-4",
                                    "case-alpha", "arm-cobalt", "case-alpha-arm-cobalt-1",
                                    str(self.archive)])
        # #when the adjudicator sees only packet files rather than the keys
        self.assert_packet_hides(first_packet_directory, identifying_strings)
        self.assert_packet_hides(second_packet_directory, identifying_strings)
        observed = (first_round_codes, second_round_codes, first_finding_codes, second_finding_codes,
                    first_key["rounds"].keys(), second_key["rounds"].keys(),
                    first_key["findings"].keys(), second_key["findings"].keys())
        # #then codes are key-backed only within their export and no code set carries across exports
        self.assertEqual(observed, (set(first_key["rounds"]), set(second_key["rounds"]),
                                    set(first_key["findings"]), set(second_key["findings"]),
                                    first_key["rounds"].keys(), second_key["rounds"].keys(),
                                    first_key["findings"].keys(), second_key["findings"].keys()))
        self.assertFalse(first_round_codes & second_round_codes)
        self.assertFalse(first_finding_codes & second_finding_codes)
        self.assertEqual(len({code[:8] for code in first_round_codes}), len(first_round_codes))

    def test_export_blind_rejects_a_packet_or_key_that_already_exists(self):
        # #given a packet directory and a key file with sentinel contents
        self.configure_blind_export_archive()
        existing_packet_directory = Path(self.temporary_directory.name) / "existing-packet"
        existing_packet_directory.mkdir()
        packet_sentinel = existing_packet_directory / "sentinel.txt"
        packet_sentinel.write_text("do not replace\n", encoding="utf-8")
        packet_key_path = Path(self.temporary_directory.name) / "packet-key.json"
        existing_key_packet_directory = Path(self.temporary_directory.name) / "new-packet"
        existing_key_path = Path(self.temporary_directory.name) / "existing-key.json"
        existing_key_path.write_text("do not replace\n", encoding="utf-8")
        packet_result = self.export_blind(existing_packet_directory, packet_key_path)
        key_result = self.export_blind(existing_key_packet_directory, existing_key_path)
        # #when the operator attempts either write
        observed = (packet_result.returncode, key_result.returncode, packet_sentinel.read_text(encoding="utf-8"),
                    existing_key_path.read_text(encoding="utf-8"), packet_key_path.exists(),
                    existing_key_packet_directory.exists(), str(existing_packet_directory) in packet_result.stderr,
                    str(existing_key_path) in key_result.stderr)
        # #then both commands fail without replacing their existing destination or writing the other output
        self.assertEqual(observed, (1, 1, "do not replace\n", "do not replace\n", False, False, True, True))

    def test_export_blind_rejects_a_key_inside_its_packet_directory(self):
        # #given key destinations nested in and equal to their packet destination
        self.configure_blind_export_archive()
        nested_packet_directory = Path(self.temporary_directory.name) / "nested-packet"
        nested_key_path = nested_packet_directory / "sealed-key.json"
        equal_packet_directory = Path(self.temporary_directory.name) / "equal-packet"
        nested_result = self.export_blind(nested_packet_directory, nested_key_path)
        equal_result = self.export_blind(equal_packet_directory, equal_packet_directory)
        # #when the operator starts either ambiguous export
        observed = (nested_result.returncode, equal_result.returncode,
                    nested_packet_directory.exists(), nested_key_path.exists(), equal_packet_directory.exists(),
                    str(nested_packet_directory) in nested_result.stderr,
                    str(nested_key_path) in nested_result.stderr,
                    str(equal_packet_directory) in equal_result.stderr)
        # #then both commands reject the overlapping outputs before writing either one
        self.assertEqual(observed, (1, 1, False, False, False, True, True, True))

    def test_export_blind_marks_invalid_events_as_an_unreadable_round(self):
        # #given a round with valid findings and one malformed event line
        self.configure_blind_export_archive()
        (self.real / "events.jsonl").write_text('{"kind": "dropped", "findings": []}\nnot json\n',
                                                 encoding="utf-8")
        packet_directory = Path(self.temporary_directory.name) / "packet"
        key_path = Path(self.temporary_directory.name) / "sealed-key.json"
        result = self.export_blind(packet_directory, key_path)
        self.assertEqual(result.returncode, 0, result.stderr)
        packet = self.load(packet_directory / "packet.json")
        key = self.load(key_path)
        # #when the adjudicator receives the partial export
        observed = self.normalize_blind_packet(packet, key)
        # #then only the corrupt archive is marked unreadable and other rounds remain available
        self.assertEqual(observed, [
            {"state": "complete", "base": "frozen-alpha-base", "head": "frozen-alpha-head", "findings": [
                self.expected_blind_finding(
                    "kept", file="final-companion.py", line=141, end_line=142, severity="info",
                    confidence=99, title="Final companion title", body="Final companion body",
                    fix="Final companion fix", verdict="refined") | {"id": "adversarial-claude-4"},
            ], "round": {"case": "case-alpha", "arm": "arm-umber", "repetition": 2,
                            "path": "companion-round/01-companion"}},
            {"state": "unreadable", "unreadable": "events.jsonl",
             "round": {"case": "case-alpha", "arm": "arm-cobalt", "repetition": 1,
                       "path": "real-round/01-real"}},
            {"state": "unidentified", "round": {"case": None, "arm": None, "repetition": None,
                                                      "path": "unidentified-round/01-bench"}},
            {"state": "unreadable", "unreadable": "manifest.json",
             "round": {"case": "case-beta", "arm": "arm-ochre", "repetition": 1,
                       "path": "unreadable-round/01-bench"}},
        ])

    def test_export_blind_projects_every_found_stage_fate(self):
        # #given final finding buckets with records distinct from their found-stage counterparts
        self.configure_blind_fates_archive()
        packet_directory = Path(self.temporary_directory.name) / "packet"
        key_path = Path(self.temporary_directory.name) / "sealed-key.json"
        result = self.export_blind(packet_directory, key_path)
        self.assertEqual(result.returncode, 0, result.stderr)
        packet = self.load(packet_directory / "packet.json")
        key = self.load(key_path)
        # #when the adjudicator receives the projected round
        normalized = self.normalize_blind_packet(packet, key)
        real_round = next(record for record in normalized
                          if record["round"]["path"] == "real-round/01-real")
        findings = {finding["id"]: finding for finding in real_round["findings"]}
        final_finding_ids = ("bugs+impl-codex-5", "adversarial-claude-6", "bugs+impl-codex-7")
        observed = (
            {identifier: (finding["stage_fate"], finding["verdict"])
             for identifier, finding in findings.items()},
            {identifier: tuple(findings[identifier][field] for field in (
                "file", "line", "end_line", "severity", "confidence", "title", "body", "fix", "verdict"))
             for identifier in final_finding_ids},
        )
        # #then final buckets, events, and absent records retain their distinct fates and verdict sources
        self.assertEqual(observed, ({
            "adversarial-claude-1": ("kept", "confirmed"),
            "bugs+impl-codex-2": ("merged", ""),
            "adversarial-claude-3": ("dropped", ""),
            "bugs+impl-codex-5": ("pre_existing", "pre-existing-final"),
            "adversarial-claude-6": ("immaterial", "immaterial-final"),
            "bugs+impl-codex-7": ("open_question", "open-question-final"),
            "adversarial-claude-8": ("gone", ""),
        }, {
            "bugs+impl-codex-5": (
                "final-pre-existing.py", 201, 202, "critical", 81, "Final pre-existing title",
                "Final pre-existing body", "Final pre-existing fix", "pre-existing-final"),
            "adversarial-claude-6": (
                "final-immaterial.py", 211, 212, "major", 82, "Final immaterial title",
                "Final immaterial body", "Final immaterial fix", "immaterial-final"),
            "bugs+impl-codex-7": (
                "final-open-question.py", 221, 222, "blocker", 83, "Final open-question title",
                "Final open-question body", "Final open-question fix", "open-question-final"),
        }))

    def test_export_blind_replaces_found_identifiers_and_agent_names_in_text(self):
        # #given found text cites local identifiers and companion text cites a foreign finding identifier
        self.configure_blind_export_archive()
        found = self.load(self.real / "stages/1-found.json")
        target = next(finding for finding in found["findings"]
                      if finding["id"] == "bugs+impl-codex-2")
        raw_ids = ("adversarial-claude-1", "bugs+impl-codex-2", "adversarial-claude-3")
        agent_names = ("adversarial-claude", "bugs+impl-codex")
        target["title"] = "Title cites " + " and ".join(raw_ids + agent_names) + "."
        target["body"] = "Body cites " + " and ".join(raw_ids + agent_names) + "."
        target["fix"] = "Fix cites " + " and ".join(raw_ids + agent_names) + "."
        self.save(self.real / "stages/1-found.json", found)
        companion_final = self.load(self.companion / "findings.json")
        companion_final["findings"][0]["body"] = "Companion quotes bugs+impl-codex-2."
        self.save(self.companion / "findings.json", companion_final)
        packet_directory = Path(self.temporary_directory.name) / "packet"
        key_path = Path(self.temporary_directory.name) / "sealed-key.json"
        result = self.export_blind(packet_directory, key_path)
        self.assertEqual(result.returncode, 0, result.stderr)
        packet = self.load(packet_directory / "packet.json")
        key = self.load(key_path)
        # #when the adjudicator opens packet text and the operator opens the sealed key
        finding_codes = {
            raw_id: next((code for code, identifier in key["findings"].items() if identifier == raw_id),
                         f"<missing-{raw_id}>")
            for raw_id in raw_ids
        }
        agent_tokens = {
            agent_name: next((token for token, entry in key.get("agents", {}).items()
                               if (entry.get("name") if isinstance(entry, dict) else entry) == agent_name),
                             f"<missing-{agent_name}>")
            for agent_name in agent_names
        }
        projected = next(finding for round_record in packet["rounds"]
                          for finding in round_record.get("findings", [])
                          if key["findings"].get(finding["finding_code"]) == "bugs+impl-codex-2")
        companion_record = next(round_record for round_record in packet["rounds"]
                                if key["rounds"][round_record["round_code"]]["path"]
                                == "companion-round/01-companion")
        companion_body = companion_record["findings"][0]["body"]
        references = key.get("references", {})
        reference_tokens = [
            token for token, entry in references.items()
            if entry == {"round_code": companion_record["round_code"], "text": "bugs+impl-codex-2"}
        ]
        reference_token = reference_tokens[0] if len(reference_tokens) == 1 else "<missing-foreign-reference>"
        packet_text = (packet_directory / "packet.json").read_text(encoding="utf-8")
        expected_text = {
            field: f"{prefix} cites "
                   + " and ".join([*(finding_codes[raw_id] for raw_id in raw_ids),
                                    *(agent_tokens[agent_name] for agent_name in agent_names)]) + "."
            for field, prefix in (("title", "Title"), ("body", "Body"), ("fix", "Fix"))
        }
        agent_key_names = {
            token: entry.get("name") if isinstance(entry, dict) else entry
            for token, entry in key.get("agents", {}).items()
        }
        observed = ({field: projected[field] for field in expected_text}, agent_key_names,
                    [identifier for identifier in (*raw_ids, *agent_names) if identifier in packet_text],
                    companion_body, references,
                    reference_token != finding_codes["bugs+impl-codex-2"],
                    reference_token not in agent_key_names)
        # #then packet prose uses opaque codes while the key alone restores agents and foreign references
        self.assertEqual(observed, (expected_text,
                                      {agent_tokens[name]: name for name in agent_names}, [],
                                      f"Companion quotes {reference_token}.",
                                      {reference_token: {
                                          "round_code": companion_record["round_code"],
                                          "text": "bugs+impl-codex-2",
                                      }},
                                      True, True))

    def test_export_blind_scopes_agent_tokens_to_their_rounds(self):
        # #given two rounds cite one shared name and the companion cites a name declared only by the real manifest
        self.configure_blind_export_archive()
        real_final = self.load(self.real / "findings.json")
        real_final["findings"][0]["body"] = "Real cites bugs+impl-codex."
        self.save(self.real / "findings.json", real_final)
        companion_final = self.load(self.companion / "findings.json")
        companion_final["findings"][0]["body"] = (
            "Companion cites bugs+impl-codex and adversarial-claude.")
        self.save(self.companion / "findings.json", companion_final)
        packet_directory = Path(self.temporary_directory.name) / "packet"
        key_path = Path(self.temporary_directory.name) / "sealed-key.json"
        result = self.export_blind(packet_directory, key_path)
        self.assertEqual(result.returncode, 0, result.stderr)
        packet = self.load(packet_directory / "packet.json")
        key = self.load(key_path)
        # #when the adjudicator reads both rounds and the operator opens their sealed agent entries
        round_records = {
            key["rounds"][record["round_code"]]["path"]: record
            for record in packet["rounds"] if record["state"] == "complete"
        }
        real_record = round_records["real-round/01-real"]
        companion_record = round_records["companion-round/01-companion"]
        real_shared_token = real_record["findings"][0]["body"].removeprefix("Real cites ").removesuffix(".")
        companion_shared_token, companion_external_token = (
            companion_record["findings"][0]["body"].removeprefix("Companion cites ").removesuffix(".").split(" and ")
        )
        expected_agents = {
            real_shared_token: {"round_code": real_record["round_code"], "name": "bugs+impl-codex"},
            companion_shared_token: {"round_code": companion_record["round_code"], "name": "bugs+impl-codex"},
            companion_external_token: {
                "round_code": companion_record["round_code"], "name": "adversarial-claude"},
        }
        packet_text = (packet_directory / "packet.json").read_text(encoding="utf-8")
        observed = (
            real_shared_token != companion_shared_token,
            key.get("agents", {}),
            [name for name in ("bugs+impl-codex", "adversarial-claude") if name in packet_text],
        )
        # #then each round's token is unique and the key records its owning round and source name
        self.assertEqual(observed, (True, expected_agents, []))

    def test_export_blind_redacts_identifiers_inside_text_paths(self):
        # #given packet prose with archive identifiers in markdown labels and path segments
        self.configure_blind_export_archive()
        task_name = "case-alpha-arm-cobalt-1"
        self.real = self.real.parent.rename(self.archive / task_name) / self.real.name
        found = self.load(self.real / "stages/1-found.json")
        target = next(finding for finding in found["findings"]
                      if finding["id"] == "bugs+impl-codex-2")
        target.update(
            file="src/file.py",
            title="See [adversarial-claude-1](src/file.py)",
            body=("tasks/case-alpha-arm-cobalt-1/01-real/input/goal.md and "
                  "agents/bugs+impl-codex.jsonl; cleanup stays; "
                  "adversarial-claude/bugs+impl-codex agree. "
                  f"See {self.archive}/case-alpha-arm-cobalt-1/01-real/input/goal.md."),
            fix="case-alpha arm-cobalt case-alpha-arm-cobalt-1.",
            verdict="case-alpha-arm-cobalt-1/01-real",
        )
        self.save(self.real / "stages/1-found.json", found)
        packet_directory = Path(self.temporary_directory.name) / "packet"
        key_path = Path(self.temporary_directory.name) / "sealed-key.json"
        result = self.export_blind(packet_directory, key_path)
        self.assertEqual(result.returncode, 0, result.stderr)
        packet = self.load(packet_directory / "packet.json")
        key = self.load(key_path)
        # #when the adjudicator receives the placeholder-redacted record and the operator opens its key
        real_record = next(record for record in packet["rounds"]
                           if key["rounds"][record["round_code"]]["path"]
                           == "case-alpha-arm-cobalt-1/01-real")
        round_code = real_record["round_code"]
        agent_tokens = {
            entry["name"]: token
            for token, entry in key["agents"].items()
            if entry["round_code"] == round_code
        }
        finding_codes = {
            raw_id: next(code for code, identifier in key["findings"].items() if identifier == raw_id)
            for raw_id in ("adversarial-claude-1", "bugs+impl-codex-2")
        }
        projected = next(finding for round_record in packet["rounds"]
                         for finding in round_record.get("findings", [])
                         if key["findings"].get(finding["finding_code"]) == "bugs+impl-codex-2")
        packet_text = (packet_directory / "packet.json").read_text(encoding="utf-8")
        identifiers = (
            "adversarial-claude-1", "bugs+impl-codex-2", "adversarial-claude",
            "bugs+impl-codex", task_name, "arm-cobalt", "case-alpha", str(self.archive),
        )
        observed = (
            tuple(projected[field] for field in ("file", "title", "body", "fix", "verdict")),
            [identifier for identifier in identifiers if identifier in packet_text],
        )
        # #then archive identity becomes shared placeholders while finding and agent identities stay opaque
        self.assertEqual(observed, ((
            "src/file.py",
            f"See [{finding_codes['adversarial-claude-1']}](src/file.py)",
            (f"tasks/[round]/input/goal.md and agents/{agent_tokens['bugs+impl-codex']}.jsonl; "
             f"cleanup stays; {agent_tokens['adversarial-claude']}/"
             f"{agent_tokens['bugs+impl-codex']} agree. See [round]/[round]/input/goal.md."),
            "[case] [arm] [round].",
            "[round]",
        ), []))

    def test_export_blind_replaces_archive_identity_with_shared_placeholders(self):
        # #given two arms with identical prose and their own task and round paths
        self.configure_blind_export_archive()
        rounds = (("case-identical-lean-1", "lean", self.real),
                  ("case-identical-mixed-1", "mixed", self.companion))
        for task_name, arm, round_directory in rounds:
            task_directory = round_directory.parent.rename(self.archive / task_name)
            round_directory = (task_directory / round_directory.name).rename(task_directory / "01-bench")
            self.bench(round_directory, "case-identical", arm)
            final = self.load(round_directory / "findings.json")
            final["findings"][0]["body"] = (
                f"The lean helper has mixed line endings. See tasks/{task_name}/01-bench/input/goal.md.")
            self.save(round_directory / "findings.json", final)
        packet_directory = Path(self.temporary_directory.name) / "packet"
        key_path = Path(self.temporary_directory.name) / "sealed-key.json"
        result = self.export_blind(packet_directory, key_path)
        self.assertEqual(result.returncode, 0, result.stderr)
        packet = self.load(packet_directory / "packet.json")
        key = self.load(key_path)
        # #when the adjudicator reads each matching finding without its sealed key
        bodies = {
            key["rounds"][round_record["round_code"]]["path"]: round_record["findings"][0]["body"]
            for round_record in packet["rounds"] if round_record["state"] == "complete"
        }
        # #then arm, case, task, and relative-round words use one literal vocabulary in every round
        self.assertEqual(bodies, {
            "case-identical-lean-1/01-bench": (
                "The [arm] helper has [arm] line endings. See tasks/[round]/input/goal.md."),
            "case-identical-mixed-1/01-bench": (
                "The [arm] helper has [arm] line endings. See tasks/[round]/input/goal.md."),
        })

    def test_export_blind_replaces_a_task_before_an_arm_named_agent_reference(self):
        # #given a round whose arm and declared agent name are both lean
        self.configure_blind_export_archive()
        task_name = "case-identical-lean-1"
        task_directory = self.real.parent.rename(self.archive / task_name)
        self.real = (task_directory / self.real.name).rename(task_directory / "01-bench")
        self.bench(self.real, "case-identical", "lean")
        manifest = self.load(self.real / "manifest.json")
        manifest["agents"] = [{"name": "lean"}]
        self.save(self.real / "manifest.json", manifest)
        finding = self.finding(
            "lean-1", "minor", [], "confirmed",
            body=("Evidence in tasks/case-identical-lean-1/01-bench/stages/1-found.json "
                  "and task case-identical-lean-1; see lean-1."),
        )
        for name in ("1-found", "2-synthesized", "3-verified", "final"):
            self.stage(self.real, name, [finding])
        packet_directory = Path(self.temporary_directory.name) / "packet"
        key_path = Path(self.temporary_directory.name) / "sealed-key.json"
        result = self.export_blind(packet_directory, key_path)
        self.assertEqual(result.returncode, 0, result.stderr)
        packet = self.load(packet_directory / "packet.json")
        key = self.load(key_path)
        # #when the adjudicator reads a task name containing a finding reference
        round_record = next(record for record in packet["rounds"]
                            if key["rounds"][record["round_code"]]["path"]
                            == "case-identical-lean-1/01-bench")
        finding_code = next(code for code, identifier in key["findings"].items()
                            if identifier == "lean-1")
        body = round_record["findings"][0]["body"]
        packet_text = (packet_directory / "packet.json").read_text(encoding="utf-8")
        # #then the whole task is opaque before its arm-named finding reference
        self.assertEqual((body, "case-identical" in packet_text), (
            f"Evidence in tasks/[round]/stages/1-found.json and task [round]; see {finding_code}.",
            False,
        ))

    def test_export_blind_pins_the_packet_record_shape(self):
        # #given complete, unreadable, and unidentified fixture rounds
        self.configure_blind_export_archive()
        packet_directory = Path(self.temporary_directory.name) / "packet"
        key_path = Path(self.temporary_directory.name) / "sealed-key.json"
        result = self.export_blind(packet_directory, key_path)
        self.assertEqual(result.returncode, 0, result.stderr)
        packet = self.load(packet_directory / "packet.json")
        # #when a maintainer inspects the public packet schema
        complete = next(record for record in packet["rounds"] if record["state"] == "complete")
        observed = (set(packet),
                    {state: set(next(record for record in packet["rounds"] if record["state"] == state))
                     for state in ("complete", "unreadable", "unidentified")},
                    set(complete["findings"][0]))
        # #then only the versioned packet, round, and finding fields are accepted
        self.assertEqual(observed, (
            {"format", "rounds"},
            {
                "complete": {"round_code", "state", "base", "head", "findings"},
                "unreadable": {"round_code", "state", "unreadable"},
                "unidentified": {"round_code", "state"},
            },
            {"finding_code", "file", "line", "end_line", "severity", "confidence", "title", "body",
             "fix", "verdict", "stage_fate"},
        ))


if __name__ == "__main__":
    unittest.main()
