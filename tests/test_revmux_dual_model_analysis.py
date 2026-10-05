import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
ANALYZER = REPOSITORY / "scripts" / "analyze_revmux_dual_model.py"
GROUPS = ("bugs+impl", "arch+quality", "docs+tests", "adversarial", "lean")
SOURCES = [f"{group}-{model}" for group in GROUPS for model in ("claude", "codex")]


def finding(identifier, source, severity="major", verdict="confirmed"):
    return {
        "id": identifier,
        "title": identifier,
        "body": "fixture",
        "file": "example.py",
        "line": 7,
        "severity": severity,
        "verdict": verdict,
        "sources": [source] if isinstance(source, str) else source,
        "lenses": ["bugs"],
    }


class TestRevmuxDualModelAnalysis(unittest.TestCase):
    def write_round(self, root, task, run, reported=10, degraded=None):
        round_dir = root / task / run
        (round_dir / "stages").mkdir(parents=True)
        agents = [
            {
                "name": source,
                "executor": source.rsplit("-", 1)[-1],
                "raised": 1 if source in ("bugs+impl-claude", "bugs+impl-codex", "docs+tests-codex") else 0,
                "tokens": 10,
            }
            for source in SOURCES
        ]
        manifest = {
            "task": task,
            "run": run,
            "profile": "dual-model",
            "started_at": "2026-10-01T00:00:00Z",
            "duration_ms": 60000,
            "tokens": 150,
            "agents": agents,
            "stages": [
                {"name": "find", "duration_ms": 40000},
                {"name": "synthesis", "duration_ms": 10000},
                {"name": "verify", "duration_ms": 10000},
            ],
        }
        source_summary = {"expected": 10, "reported": reported, "degraded": degraded or []}
        found = {
            "sources": source_summary,
            "findings": [
                finding("c-1", "bugs+impl-claude"),
                finding("x-1", "bugs+impl-codex"),
                finding("x-2", "docs+tests-codex", "minor", "refined"),
            ],
        }
        synthesized = {
            "findings": [
                finding("c-1", ["bugs+impl-claude", "bugs+impl-codex"]),
                finding("x-2", "docs+tests-codex", "minor", "refined"),
            ]
        }
        for path, value in (
            ("manifest.json", manifest),
            ("stages/1-found.json", found),
            ("stages/2-synthesized.json", synthesized),
            ("stages/3-verified.json", synthesized),
            ("findings.json", synthesized),
        ):
            (round_dir / path).write_text(json.dumps(value), encoding="utf-8")
        (round_dir / "events.jsonl").write_text("{}\n", encoding="utf-8")

    def run_analyzer(self, root):
        result = subprocess.run(
            [sys.executable, str(ANALYZER), str(root)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_aggregates_complete_round_and_rejects_degraded_control(self):
        # #given
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self.write_round(root, "accepted", "01-initial")
            self.write_round(root, "rejected", "01-initial", reported=9, degraded=["lean-codex"])
            unreadable = root / "running/01-initial/manifest.json"
            unreadable.parent.mkdir(parents=True)
            unreadable.write_text("", encoding="utf-8")

            # #when
            report = self.run_analyzer(root)

        # #then
        self.assertEqual(
            report["corpus"],
            {
                "dual_model_rounds": 2,
                "eligible_rounds": 1,
                "eligible_tasks": 1,
                "unreadable_manifests": [
                    {
                        "round": str(root / "running/01-initial"),
                        "error": "JSONDecodeError",
                    }
                ],
                "rejected": [
                    {
                        "round": str(root / "rejected/01-initial"),
                        "reasons": ["degraded"],
                    }
                ],
            },
        )
        self.assertEqual(
            report["rounds"],
            [
                {
                    "task": "accepted",
                    "run": "01-initial",
                    "started_at": "2026-10-01T00:00:00Z",
                    "found": 3,
                    "synthesized": 2,
                    "final_actionable": 2,
                    "final_total": 2,
                    "duration_ms": 60000,
                }
            ],
        )
        totals = report["totals"]
        self.assertEqual(totals["found_records"], 3)
        self.assertEqual(totals["synthesized_records"], 2)
        self.assertEqual(totals["find_to_synthesis_reduction"], 1)
        self.assertEqual(totals["verified_records"], 2)
        self.assertEqual(totals["verify_removed_ids"], 0)
        self.assertEqual(totals["final_cross_model_records"], 1)
        self.assertEqual(totals["final_paired_group_records"], {"bugs+impl": 1})
        self.assertEqual(
            totals["single_source_actionable_by_source"], {"docs+tests-codex": 1}
        )
        self.assertEqual(totals["raised_mismatches"], [])
        self.assertEqual(totals["duration_ms"], 60000)
        self.assertEqual(
            totals["stage_duration_ms"],
            {"find": 40000, "synthesis": 10000, "verify": 10000},
        )
        self.assertEqual(
            totals["find_agent_tokens_by_executor"], {"claude": 50, "codex": 50}
        )
        self.assertEqual(totals["pipeline_tokens"], 150)


if __name__ == "__main__":
    unittest.main()
