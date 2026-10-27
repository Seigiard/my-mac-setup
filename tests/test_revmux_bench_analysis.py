"""The benchmark analyzer reports hand-adjudicable archive measurements."""

import json
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
ANALYZER = ROOT / "scripts/analyze_revmux_benchmark.py"
ARCHIVE = ROOT / "tests/fixtures/revmux-bench/archive"


class RevmuxBenchmarkAnalysisTest(unittest.TestCase):
    maxDiff = None

    def run_analyzer(self, *arguments):
        return subprocess.run(
            ["python3", str(ANALYZER), "--tasks-dir", str(ARCHIVE), *arguments],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_json_reports_explicit_identities_fates_vendors_and_unreadable_rounds(self):
        # #given hand-authored rounds with explicit identities, real-shaped agents, and faults
        result = self.run_analyzer("--json")
        # #when the analyzer measures the archive
        measurement = json.loads(result.stdout) if result.returncode == 0 else None
        rounds = (
            sorted(measurement["rounds"], key=lambda item: json.dumps(item, sort_keys=True))
            if measurement is not None
            else None
        )
        # #then fixture records, not task-id parsing, determine identity, fate, vendor, and totals
        self.assertEqual(
            (result.returncode, rounds, measurement["aggregates"] if measurement else None),
            (
                0,
                sorted(
                    [
                        {
                            "case": "case-alpha",
                            "arm": "arm-x-1",
                            "repetition": 1,
                            "degraded": False,
                            "verify_failed": False,
                            "stages": {
                                "found": {"critical": 1, "major": 1, "minor": 5},
                                "synthesized": {"major": 2, "minor": 3},
                                "verified": {"major": 2, "minor": 2},
                                "final": {"major": 1},
                            },
                            "found_fates": {"kept": 5, "dropped": 1, "merged": 1},
                            "fates": {
                                "anthropic": {
                                    "findings": 0,
                                    "pre_existing": 1,
                                    "immaterial": 0,
                                    "open_questions": 1,
                                    "gone": 0,
                                },
                                "anthropic+openai": {
                                    "findings": 0,
                                    "pre_existing": 0,
                                    "immaterial": 1,
                                    "open_questions": 0,
                                    "gone": 0,
                                },
                                "openai": {
                                    "findings": 1,
                                    "pre_existing": 0,
                                    "immaterial": 0,
                                    "open_questions": 0,
                                    "gone": 0,
                                },
                                "unknown": {
                                    "findings": 0,
                                    "pre_existing": 0,
                                    "immaterial": 0,
                                    "open_questions": 0,
                                    "gone": 1,
                                },
                            },
                        },
                        {
                            "case": "case-alpha",
                            "arm": "opaque-b",
                            "repetition": 1,
                            "degraded": False,
                            "verify_failed": True,
                            "stages": {
                                "found": {"minor": 1},
                                "synthesized": {"minor": 1},
                                "verified": {"minor": 1},
                                "final": {"minor": 1},
                            },
                            "found_fates": {"kept": 1, "dropped": 0, "merged": 0},
                            "fates": {
                                "anthropic": {
                                    "findings": 1,
                                    "pre_existing": 0,
                                    "immaterial": 0,
                                    "open_questions": 0,
                                    "gone": 0,
                                }
                            },
                        },
                        {
                            "case": "case-alpha",
                            "arm": "opaque-c",
                            "repetition": 1,
                            "degraded": True,
                            "verify_failed": False,
                            "stages": {
                                "found": {"minor": 1},
                                "synthesized": {"minor": 1},
                                "verified": {"minor": 1},
                                "final": {"minor": 1},
                            },
                            "found_fates": {"kept": 1, "dropped": 0, "merged": 0},
                            "fates": {
                                "anthropic": {
                                    "findings": 1,
                                    "pre_existing": 0,
                                    "immaterial": 0,
                                    "open_questions": 0,
                                    "gone": 0,
                                }
                            },
                        },
                        {
                            "case": None,
                            "arm": None,
                            "repetition": None,
                            "degraded": False,
                            "verify_failed": False,
                            "stages": {
                                "found": {"minor": 1},
                                "synthesized": {"minor": 1},
                                "verified": {"minor": 1},
                                "final": {"minor": 1},
                            },
                            "found_fates": {"kept": 1, "dropped": 0, "merged": 0},
                            "fates": {
                                "anthropic": {
                                    "findings": 1,
                                    "pre_existing": 0,
                                    "immaterial": 0,
                                    "open_questions": 0,
                                    "gone": 0,
                                }
                            },
                        },
                        {
                            "round": "missing-manifest/01-bench",
                            "case": "case-incomplete",
                            "arm": "arm-incomplete",
                            "repetition": 1,
                            "unreadable": "manifest.json",
                        },
                        {
                            "round": "missing-stage/01-bench",
                            "unreadable": "stages/2-synthesized.json",
                        },
                    ],
                    key=lambda item: json.dumps(item, sort_keys=True),
                ),
                {
                    "by_case": {
                        "case-alpha": {
                            "rounds": 3,
                            "degraded_rounds": 1,
                            "unreadable_rounds": 0,
                            "verify_failed_rounds": 1,
                            "stages": {
                                "found": {"critical": 1, "major": 1, "minor": 7},
                                "synthesized": {"major": 2, "minor": 5},
                                "verified": {"major": 2, "minor": 4},
                                "final": {"major": 1, "minor": 2},
                            },
                        },
                        "case-incomplete": {
                            "rounds": 0,
                            "degraded_rounds": 0,
                            "unreadable_rounds": 1,
                            "verify_failed_rounds": 0,
                            "stages": {
                                "found": {},
                                "synthesized": {},
                                "verified": {},
                                "final": {},
                            },
                        }
                    },
                    "by_arm": {
                        "arm-x-1": {
                            "rounds": 1,
                            "degraded_rounds": 0,
                            "unreadable_rounds": 0,
                            "verify_failed_rounds": 0,
                            "stages": {
                                "found": {"critical": 1, "major": 1, "minor": 5},
                                "synthesized": {"major": 2, "minor": 3},
                                "verified": {"major": 2, "minor": 2},
                                "final": {"major": 1},
                            },
                        },
                        "opaque-b": {
                            "rounds": 1,
                            "degraded_rounds": 0,
                            "unreadable_rounds": 0,
                            "verify_failed_rounds": 1,
                            "stages": {
                                "found": {"minor": 1},
                                "synthesized": {"minor": 1},
                                "verified": {"minor": 1},
                                "final": {"minor": 1},
                            },
                        },
                        "opaque-c": {
                            "rounds": 1,
                            "degraded_rounds": 1,
                            "unreadable_rounds": 0,
                            "verify_failed_rounds": 0,
                            "stages": {
                                "found": {"minor": 1},
                                "synthesized": {"minor": 1},
                                "verified": {"minor": 1},
                                "final": {"minor": 1},
                            },
                        },
                        "arm-incomplete": {
                            "rounds": 0,
                            "degraded_rounds": 0,
                            "unreadable_rounds": 1,
                            "verify_failed_rounds": 0,
                            "stages": {
                                "found": {},
                                "synthesized": {},
                                "verified": {},
                                "final": {},
                            },
                        },
                    },
                },
            ),
        )

    def test_default_output_lists_complete_unreadable_and_unidentified_rows(self):
        # #given complete, incomplete, and unidentified observations in the frozen archive
        result = self.run_analyzer()
        # #when the analyzer uses its human-readable mode
        # #then the table keeps every denominator record visible without model names
        self.assertEqual(
            (result.returncode, result.stdout),
            (
                0,
                "Case | Arm | Repetition | Status\n"
                "unidentified | unidentified | unidentified | unidentified\n"
                "unidentified | unidentified | unidentified | unreadable\n"
                "case-alpha | arm-x-1 | 1 | no\n"
                "case-alpha | opaque-b | 1 | no\n"
                "case-alpha | opaque-c | 1 | yes\n"
                "case-incomplete | arm-incomplete | 1 | unreadable\n"
                "unreadable: 2, unidentified: 2\n",
            ),
        )


if __name__ == "__main__":
    unittest.main()
