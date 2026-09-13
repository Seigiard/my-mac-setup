import json
from pathlib import Path
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
SCRIPT = REPOSITORY / "scripts" / "github_issue_migration.py"
PRODUCTION_MANIFEST = REPOSITORY / "docs" / "migrations" / "github-issues-production" / "manifest.json"


class ProductionManifestTests(unittest.TestCase):
    def load_manifest(self):
        return json.loads(PRODUCTION_MANIFEST.read_text(encoding="utf-8"))

    def run_script(self, *arguments):
        process = subprocess.run(
            ["python3", str(SCRIPT), *arguments],
            cwd=REPOSITORY,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, process.returncode, process.stdout + process.stderr)
        return process

    def test_production_manifest_can_be_recreated_byte_identically_from_bound_commit(self):
        manifest = self.load_manifest()
        with tempfile.TemporaryDirectory() as directory:
            regenerated = Path(directory) / "manifest.json"
            self.run_script(
                "build-production-manifest",
                "--source-commit",
                manifest["source_commit"],
                "--output",
                str(regenerated),
            )
            self.assertEqual(PRODUCTION_MANIFEST.read_bytes(), regenerated.read_bytes())

    def test_production_manifest_binds_the_full_source_corpus_and_only_targets_active_records(self):
        manifest = self.load_manifest()
        corpus = manifest["source_corpus"]
        self.assertEqual(59, corpus["canonical_record_count"])
        self.assertEqual(37, corpus["active_record_count"])
        self.assertEqual(22, corpus["terminal_record_count"])
        self.assertEqual({"done": 20, "open": 37, "wontfix": 2}, corpus["status_counts"])

        entries = manifest["entries"]
        self.assertEqual(59, len(entries))
        active = [entry for entry in entries if entry.get("target")]
        terminal = [entry for entry in entries if not entry.get("target")]
        self.assertEqual(37, len(active))
        self.assertEqual(22, len(terminal))
        for entry in terminal:
            self.assertIn(entry["source"]["status"], {"done", "wontfix"})
            self.assertFalse(entry["retention"]["planned_github_target"])
        for entry in active:
            labels = entry["target"]["labels"]
            self.assertEqual(2, len(labels))
            self.assertEqual(1, len({"bug", "enhancement"}.intersection(labels)))
            self.assertEqual(1, len({"ready-for-agent", "ready-for-human"}.intersection(labels)))
            self.assertIn("Legacy source:", entry["target"]["body_template"])

    def test_production_manifest_surfaces_human_classification_exceptions_and_relation_repairs(self):
        manifest = self.load_manifest()
        review = manifest["classification_review"]
        self.assertTrue(review["approval_required_before_import"])
        self.assertEqual(
            ["2026-08-17-001", "2026-08-18-017", "2026-09-09-001"],
            [entry["source_id"] for entry in review["human_only"]],
        )
        self.assertEqual(
            ["2026-08-18-024"],
            [entry["source_id"] for entry in review["ambiguous_transformations"]],
        )
        self.assertEqual({"active_to_active": 4, "active_to_terminal": 1}, manifest["relation_summary"])

    def test_production_dry_run_is_non_mutating_and_excludes_terminal_records_from_targets(self):
        with tempfile.TemporaryDirectory() as directory:
            dry_run = Path(directory) / "dry-run.json"
            with dry_run.open("w", encoding="utf-8") as output:
                process = subprocess.run(
                    [
                        "python3",
                        str(SCRIPT),
                        "dry-run",
                        "--manifest",
                        str(PRODUCTION_MANIFEST),
                        "--repo",
                        "Seigiard/my-mac-setup",
                    ],
                    cwd=REPOSITORY,
                    text=True,
                    stdout=output,
                    stderr=subprocess.PIPE,
                    check=False,
                )
            self.assertEqual(0, process.returncode, process.stderr)
            value = json.loads(dry_run.read_text(encoding="utf-8"))
        self.assertTrue(value["dry_run"])
        self.assertEqual(0, value["network_mutations"])
        self.assertEqual(37, len(value["target_transformations"]))
        self.assertEqual(22, len(value["retained_provenance"]))


if __name__ == "__main__":
    unittest.main()
