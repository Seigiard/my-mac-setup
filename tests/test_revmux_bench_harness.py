"""The benchmark harness must isolate every repetition from earlier revmux rounds."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
HARNESS = ROOT / "scripts/run_revmux_benchmark.py"
FIXTURE = ROOT / "tests/fixtures/revmux-bench"
FAKE_REVMUX = FIXTURE / "fake_revmux.py"


class RevmuxBenchmarkHarnessTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary_directory.name)
        self.repository = self.directory / "repository"
        self.repository.mkdir()
        self.git("init")
        self.git("config", "user.email", "benchmark@example.test")
        self.git("config", "user.name", "Benchmark Fixture")
        (self.repository / "change.txt").write_text("base\n", encoding="utf-8")
        self.git("add", "change.txt")
        self.git("commit", "-m", "base")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()
        (self.repository / "change.txt").write_text("head\n", encoding="utf-8")
        self.git("commit", "-am", "head")
        self.head = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", self.base)
        self.case_path = self.directory / "case.json"
        self.write_case()
        self.tasks_dir = self.directory / "tasks"
        self.log_path = self.directory / "stand-in.jsonl"

    def tearDown(self):
        self.temporary_directory.cleanup()

    def git(self, *arguments):
        return subprocess.run(["git", "-C", str(self.repository), *arguments], check=True,
                              capture_output=True, text=True)

    def write_case(self, **updates):
        case = json.loads((FIXTURE / "case.json").read_text(encoding="utf-8"))
        case.update({"repository": str(self.repository), "base": self.base, "head": self.head})
        case.update(updates)
        self.case_path.write_text(json.dumps(case), encoding="utf-8")

    def run_harness(self, arm, repetitions, *, exit_status=None, tasks_dir=None, cwd=None,
                    case_path=None, revmux=None):
        environment = {**os.environ, "REVMUX_STANDIN_LOG": str(self.log_path)}
        if exit_status is not None:
            environment["REVMUX_STANDIN_EXIT"] = str(exit_status)
        return subprocess.run(
            ["python3", str(HARNESS), "--case", str(case_path or self.case_path),
             "--profile", "fixed-profile", "--arm", arm, "--repetitions", str(repetitions),
             "--tasks-dir", str(tasks_dir or self.tasks_dir), "--revmux", str(revmux or FAKE_REVMUX)],
            check=False, capture_output=True, text=True, env=environment, cwd=cwd,
        )

    def events(self, kind):
        if not self.log_path.exists():
            return []
        return [json.loads(line) for line in self.log_path.read_text(encoding="utf-8").splitlines()
                if json.loads(line)["event"] == kind]

    def test_isolates_findings_rounds_and_records_their_identity(self):
        # #given two normal-findings arms from a base checkout
        results = [self.run_harness("opaque-a", 2), self.run_harness("opaque-b", 1)]
        self.assertEqual([result.returncode for result in results], [0, 0])
        new, runs = self.events("new"), self.events("run")
        records = [json.loads((Path(event["output"]["round_dir"]) / "bench.json").read_text())
                   for event in new]
        # #when every review exits with revmux's findings status
        observed = {
            "tasks": [event["task"] for event in new], "heads": [event["head"] for event in runs],
            "inputs": [(event["scope"], event["goal"], event["profile"], event["no_tui"])
                       for event in runs],
            "isolated": [not event["refs"] and (Path(event["workdir"]) / event["git_common_dir"])
                         .resolve().is_relative_to(Path(event["workdir"]).resolve()) for event in runs],
            "review_cwds": [event["cwd"] == event["workdir"] for event in runs],
            "distinct": len({event["workdir"] for event in runs}) == 3,
            "records": records,
            "preserved": [Path(event["output"]["round_dir"]).is_dir() for event in new],
            "cleaned": [not Path(event["workdir"]).exists() for event in runs],
        }
        # #then each archive has a unique, detached, reproducible identity
        scope = f"Range: {self.base}..{self.head}\ngit diff {self.base}..{self.head}\n\n# Scope\n\nReview the benchmark fixture change."
        self.assertEqual(observed, {
            "tasks": ["sample-case-opaque-a-1", "sample-case-opaque-a-2", "sample-case-opaque-b-1"],
            "heads": [self.head] * 3,
            "inputs": [(scope, "# Goal\n\nPreserve the fixture behavior.", "fixed-profile", True)] * 3,
            "isolated": [True] * 3, "review_cwds": [True] * 3, "distinct": True,
            "records": [{"case": "sample-case", "arm": arm, "repetition": repetition,
                         "base": self.base, "head": self.head, "profile": "fixed-profile",
                         "cwd": runs[index]["workdir"]}
                        for index, (arm, repetition) in enumerate((("opaque-a", 1), ("opaque-a", 2), ("opaque-b", 1)))],
            "preserved": [True] * 3, "cleaned": [True] * 3,
        })

    def test_resolves_operator_relative_paths_and_abbreviated_revisions(self):
        # #given all launch inputs relative to an operator directory and abbreviated revisions
        operator = self.directory / "operator"
        (operator / "bin").mkdir(parents=True)
        (operator / "bin/fake.py").symlink_to(FAKE_REVMUX)
        abbreviated = self.directory / "abbreviated.json"
        self.write_case(base=self.base[:7], head=self.head[:7])
        self.case_path.replace(abbreviated)
        self.case_path = abbreviated
        result = self.run_harness("relative", 1, tasks_dir=Path("archive"), cwd=operator,
                                  case_path=Path("../abbreviated.json"), revmux=Path("bin/fake.py"))
        self.assertEqual(result.returncode, 0)
        new, runs = self.events("new"), self.events("run")
        record = json.loads((Path(new[0]["output"]["round_dir"]) / "bench.json").read_text())
        # #when the review changes into an isolated checkout
        archive = operator / "archive/stand-in-layout/sample-case-relative-1/rounds/01-bench"
        scope = f"Range: {self.base}..{self.head}\ngit diff {self.base}..{self.head}\n\n# Scope\n\nReview the benchmark fixture change."
        observed = runs[0]["tasks_dir"], archive.is_dir(), runs[0]["head"], runs[0]["scope"], record["base"], record["head"]
        # #then the operator paths and canonical Git revisions survive
        self.assertEqual(observed, (str(operator / "archive"), True, self.head, scope, self.base, self.head))

    def test_reports_non_findings_reviews_and_keeps_later_repetitions(self):
        for exit_status in (2, "signal"):
            with self.subTest(exit_status=exit_status):
                # #given a review failure after each archive is created
                self.log_path.unlink(missing_ok=True)
                result = self.run_harness(f"failure-{exit_status}", 2, exit_status=exit_status)
                self.assertEqual(result.returncode, 1)
                runs = self.events("run")
                # #when the harness handles the failed review status
                tasks = [f"sample-case-failure-{exit_status}-{number}" for number in (1, 2)]
                observed = ([event["task"] for event in runs], all(task in result.stderr for task in tasks),
                            [not Path(event["workdir"]).exists() for event in runs])
                # #then it reports both failures and cleans both checkouts
                self.assertEqual(observed, (tasks, True, [True, True]))

    def test_rejects_an_existing_task_without_writing_another_archive(self):
        # #given a requested task identity that already exists
        existing = self.tasks_dir / "sample-case-rerun-1"
        existing.mkdir(parents=True)
        (existing / "prior.txt").write_text("preserve\n", encoding="utf-8")
        result = self.run_harness("rerun", 1)
        # #when the harness checks its planned archive writes
        self.assertEqual(result.returncode, 1)
        observed = str(existing) in result.stderr, sorted(path.name for path in self.tasks_dir.iterdir()), (existing / "prior.txt").read_text()
        # #then it leaves the archive untouched
        self.assertEqual(observed, (True, ["sample-case-rerun-1"], "preserve\n"))

    def test_records_input_before_reporting_a_revision_resolution_failure(self):
        # #given a case with an unresolved head revision
        self.write_case(head="missing-head")
        expected = subprocess.run(["git", "-C", str(self.repository), "rev-parse", "--verify", "missing-head^{commit}"], check=False, capture_output=True, text=True).stderr.strip()
        result = self.run_harness("checkout-failure", 2)
        self.assertEqual(result.returncode, 1)
        new = self.events("new")
        # #when the harness attempts every requested repetition
        observed = (all(task in result.stderr for task in ("sample-case-checkout-failure-1", "sample-case-checkout-failure-2")), expected in result.stderr, "Traceback" in result.stderr,
                    [(Path(event["output"]["round_dir"]) / "bench.json").is_file() and Path(event["output"]["scope"]).is_file() and Path(event["output"]["goal"]).is_file() for event in new])
        # #then each incomplete round remains identifiable without a traceback
        self.assertEqual(observed, (True, True, False, [True, True]))


if __name__ == "__main__":
    unittest.main()
