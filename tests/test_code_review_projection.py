"""The code-review report projection is a stable caller-facing contract."""

import json
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROJECTION = ROOT / "home/private_dot_agents/skills/code-review/projection.jq"


def project(report):
    with tempfile.TemporaryDirectory() as directory:
        report_path = Path(directory) / "report.json"
        report_path.write_text(json.dumps(report), encoding="utf-8")
        return subprocess.run(
            ["jq", "-r", "-f", str(PROJECTION), str(report_path)],
            capture_output=True,
            check=False,
            text=True,
        )


class CodeReviewProjection(unittest.TestCase):
    def test_projects_sources_and_findings_in_severity_order(self):
        # #given a report with sources and findings from multiple severities
        report = {
            "sources": {
                "expected": 2,
                "reported": 1,
                "degraded": ["docs"],
                "agents": [
                    {"name": "bugs", "raised": 0, "degraded": False},
                    {"name": "docs", "raised": 0, "degraded": True},
                ],
            },
            "findings": [
                {
                    "id": "f2",
                    "file": "a.sh",
                    "line": 3,
                    "end_line": 0,
                    "severity": "minor",
                    "title": "Small",
                    "body": "One.  Two.",
                    "verdict": "confirmed",
                },
                {
                    "id": "f1",
                    "file": "",
                    "line": 0,
                    "end_line": 0,
                    "severity": "major",
                    "title": "Big",
                    "body": "Line\nbreak. Rest.",
                    "verdict": "",
                },
            ],
            "open_questions": [],
            "pre_existing": [{"title": "old"}],
            "immaterial": [],
        }
        # #when
        result = project(report)
        # #then
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            textwrap.dedent(
                """\
                sources: 1/2 reported; degraded: docs; raised 0: bugs
                findings: 2
                f1 [major] (no file) \u2014 Big
                  Line break.
                f2 [minor, confirmed] a.sh:3 \u2014 Small
                  One.
                open_questions: 0
                pre_existing: 1, immaterial: 0
                """
            ),
        )

    def test_projects_missing_lists_questions_locations_and_long_gists(self):
        # #given a report with omitted optional lists and mixed finding shapes
        report = {
            "findings": [
                {
                    "id": "f3",
                    "file": "later.py",
                    "line": 7,
                    "end_line": 9,
                    "severity": "other",
                    "title": "Later",
                    "body": "   spaced\ttext   ",
                },
                {
                    "id": "f1",
                    "file": "first.py",
                    "line": 1,
                    "end_line": 0,
                    "severity": "critical",
                    "title": "First",
                },
            ],
            "open_questions": [
                {
                    "id": "q1",
                    "file": "question.py",
                    "line": 0,
                    "end_line": 8,
                    "severity": "major",
                    "title": "Question",
                    "body": "x" * 201,
                }
            ],
        }
        # #when
        result = project(report)
        # #then
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "findings: 2\n"
            "f1 [critical] first.py:1 \u2014 First\n"
            "f3 [other] later.py:7-9 \u2014 Later\n"
            "  spaced text\n"
            "open_questions: 1\n"
            "q1 [major] question.py \u2014 Question\n"
            f"  {'x' * 200}\u2026\n"
            "pre_existing: 0, immaterial: 0\n",
        )


if __name__ == "__main__":
    unittest.main()
