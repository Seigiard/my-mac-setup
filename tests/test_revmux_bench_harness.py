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
        case = json.loads((FIXTURE / "case.json").read_text(encoding="utf-8"))
        case.update(
            repository=str(self.repository), base=self.base, head=self.head
        )
        self.case_path = self.directory / "case.json"
        self.case_path.write_text(json.dumps(case), encoding="utf-8")
        self.tasks_dir = self.directory / "tasks"
        self.log_path = self.directory / "stand-in.jsonl"

    def tearDown(self):
        self.temporary_directory.cleanup()

    def git(self, *arguments):
        return subprocess.run(
            ["git", "-C", str(self.repository), *arguments],
            check=True,
            capture_output=True,
            text=True,
        )

    def run_harness(
        self,
        arm,
        repetitions,
        *,
        standin_exit=None,
        tasks_dir=None,
        cwd=None,
        case_path=None,
        revmux=None,
    ):
        environment = {**os.environ, "REVMUX_STANDIN_LOG": str(self.log_path)}
        if standin_exit is not None:
            environment["REVMUX_STANDIN_EXIT"] = str(standin_exit)
        tasks_dir = self.tasks_dir if tasks_dir is None else tasks_dir
        case_path = self.case_path if case_path is None else case_path
        revmux = FAKE_REVMUX if revmux is None else revmux
        return subprocess.run(
            [
                "python3",
                str(HARNESS),
                "--case",
                str(case_path),
                "--profile",
                "fixed-profile",
                "--arm",
                arm,
                "--repetitions",
                str(repetitions),
                "--tasks-dir",
                str(tasks_dir),
                "--revmux",
                str(revmux),
            ],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
            cwd=cwd,
        )

    def test_keeps_findings_rounds_in_fresh_head_worktrees_with_identity_records(self):
        # #given a two-commit case checked out at base and a stand-in that exits 1 for findings
        first = self.run_harness("opaque-a", 2)
        second = self.run_harness("opaque-b", 1)
        events = (
            [
                json.loads(line)
                for line in self.log_path.read_text(encoding="utf-8").splitlines()
            ]
            if self.log_path.exists()
            else []
        )
        new_events = [event for event in events if event["event"] == "new"]
        run_events = [event for event in events if event["event"] == "run"]
        bench_records = [
            (
                json.loads(bench_path.read_text(encoding="utf-8"))
                if bench_path.exists()
                else None
            )
            for event in new_events
            for bench_path in [Path(event["output"]["round_dir"]) / "bench.json"]
        ]
        workdir_at = lambda index: (
            run_events[index]["workdir"] if index < len(run_events) else None
        )
        # #when the harness completes both blind arms despite normal findings exits
        observed = {
            "return_codes": [first.returncode, second.returncode],
            "task_ids": [event["task"] for event in new_events],
            "heads": [event["head"] for event in run_events],
            "scope_texts": [event["scope"] for event in run_events],
            "goal_texts": [event["goal"] for event in run_events],
            "profiles": [event["profile"] for event in run_events],
            "no_tui": [event["no_tui"] for event in run_events],
            "review_cwds": [event["cwd"] for event in run_events],
            "worktrees_distinct": len({event["workdir"] for event in run_events}) == 3,
            "review_ref_lists": [event["refs"] for event in run_events],
            "common_dirs_inside_review": [
                (
                    Path(event["workdir"]) / event["git_common_dir"]
                ).resolve().is_relative_to(Path(event["workdir"]).resolve())
                for event in run_events
            ],
            "identity_records": bench_records,
            "archives_preserved": [
                Path(event["output"]["round_dir"]).is_dir() for event in new_events
            ],
            "worktrees_removed": [
                not Path(event["workdir"]).exists() for event in run_events
            ],
        }
        # #then each run has a unique task, frozen range, head checkout, and identity record
        self.assertEqual(
            observed,
            {
                "return_codes": [0, 0],
                "task_ids": [
                    "sample-case-opaque-a-1",
                    "sample-case-opaque-a-2",
                    "sample-case-opaque-b-1",
                ],
                "heads": [self.head, self.head, self.head],
                "scope_texts": [
                    f"Range: {self.base}..{self.head}\n"
                    f"git diff {self.base}..{self.head}\n\n"
                    "# Scope\n\nReview the benchmark fixture change.",
                    f"Range: {self.base}..{self.head}\n"
                    f"git diff {self.base}..{self.head}\n\n"
                    "# Scope\n\nReview the benchmark fixture change.",
                    f"Range: {self.base}..{self.head}\n"
                    f"git diff {self.base}..{self.head}\n\n"
                    "# Scope\n\nReview the benchmark fixture change.",
                ],
                "goal_texts": [
                    "# Goal\n\nPreserve the fixture behavior.",
                    "# Goal\n\nPreserve the fixture behavior.",
                    "# Goal\n\nPreserve the fixture behavior.",
                ],
                "profiles": ["fixed-profile", "fixed-profile", "fixed-profile"],
                "no_tui": [True, True, True],
                "review_cwds": [event["workdir"] for event in run_events],
                "worktrees_distinct": True,
                "review_ref_lists": [[], [], []],
                "common_dirs_inside_review": [True, True, True],
                "identity_records": [
                    {
                        "case": "sample-case",
                        "arm": "opaque-a",
                        "repetition": 1,
                        "base": self.base,
                        "head": self.head,
                        "profile": "fixed-profile",
                        "cwd": workdir_at(0),
                    },
                    {
                        "case": "sample-case",
                        "arm": "opaque-a",
                        "repetition": 2,
                        "base": self.base,
                        "head": self.head,
                        "profile": "fixed-profile",
                        "cwd": workdir_at(1),
                    },
                    {
                        "case": "sample-case",
                        "arm": "opaque-b",
                        "repetition": 1,
                        "base": self.base,
                        "head": self.head,
                        "profile": "fixed-profile",
                        "cwd": workdir_at(2),
                    },
                ],
                "archives_preserved": [True, True, True],
                "worktrees_removed": [True, True, True],
            },
        )

    def test_resolves_relative_tasks_dir_before_review_changes_directory(self):
        # #given a relative task directory from an operator directory
        result = self.run_harness(
            "relative-tasks", 1, tasks_dir=Path("tasks"), cwd=self.directory
        )
        events = [
            json.loads(line)
            for line in self.log_path.read_text(encoding="utf-8").splitlines()
        ]
        run_events = [event for event in events if event["event"] == "run"]
        # #when the review runs from its isolated checkout
        observed = {
            "return_code": result.returncode,
            "recorded_tasks_dirs": [event["tasks_dir"] for event in run_events],
            "archive_preserved": [
                (self.tasks_dir / "stand-in-layout" / "sample-case-relative-tasks-1"
                 / "rounds" / "01-bench").is_dir()
            ],
        }
        # #then both revmux calls retain the operator's absolute archive location
        self.assertEqual(
            observed,
            {
                "return_code": 0,
                "recorded_tasks_dirs": [str(self.tasks_dir)],
                "archive_preserved": [True],
            },
        )

    def test_reports_tool_failures_after_cleaning_every_repetition_worktree(self):
        # #given a stand-in that exits 2 after creating each round archive
        result = self.run_harness("tool-error", 2, standin_exit=2)
        events = [
            json.loads(line)
            for line in self.log_path.read_text(encoding="utf-8").splitlines()
        ]
        run_events = [event for event in events if event["event"] == "run"]
        # #when the harness completes its requested repetitions
        observed = {
            "failed": result.returncode != 0,
            "reported_tasks": [
                task in result.stderr
                for task in ("sample-case-tool-error-1", "sample-case-tool-error-2")
            ],
            "all_repetitions_ran": [event["task"] for event in run_events],
            "worktrees_removed": [
                not Path(event["workdir"]).exists() for event in run_events
            ],
        }
        # #then every tool failure is reported and cleanup does not stop the later repetition
        self.assertEqual(
            observed,
            {
                "failed": True,
                "reported_tasks": [True, True],
                "all_repetitions_ran": [
                    "sample-case-tool-error-1",
                    "sample-case-tool-error-2",
                ],
                "worktrees_removed": [True, True],
            },
        )

    def test_reports_signal_terminated_reviews_as_tool_failures(self):
        # #given a stand-in whose completed setup is killed by a signal during review
        result = self.run_harness("signal-error", 2, standin_exit="signal")
        events = [
            json.loads(line)
            for line in self.log_path.read_text(encoding="utf-8").splitlines()
        ]
        run_events = [event for event in events if event["event"] == "run"]
        # #when the harness completes its requested repetitions
        observed = {
            "failed": result.returncode != 0,
            "reported_tasks": [
                task in result.stderr
                for task in ("sample-case-signal-error-1", "sample-case-signal-error-2")
            ],
            "all_repetitions_ran": [event["task"] for event in run_events],
            "worktrees_removed": [
                not Path(event["workdir"]).exists() for event in run_events
            ],
        }
        # #then signal exits are tool failures and do not skip cleanup or a later repetition
        self.assertEqual(
            observed,
            {
                "failed": True,
                "reported_tasks": [True, True],
                "all_repetitions_ran": [
                    "sample-case-signal-error-1",
                    "sample-case-signal-error-2",
                ],
                "worktrees_removed": [True, True],
            },
        )

    def test_resolves_relative_operator_inputs_before_creating_a_review_checkout(self):
        # #given a case and stand-in that are both relative to an operator directory
        operator_directory = self.directory / "operator"
        (operator_directory / "bin").mkdir(parents=True)
        (operator_directory / "bin" / "fake-revmux.py").symlink_to(FAKE_REVMUX)
        result = self.run_harness(
            "operator-relative",
            1,
            tasks_dir=Path("archive"),
            cwd=operator_directory,
            case_path=Path("../case.json"),
            revmux=Path("bin/fake-revmux.py"),
        )
        events = (
            [json.loads(line) for line in self.log_path.read_text(encoding="utf-8").splitlines()]
            if self.log_path.exists()
            else []
        )
        run_events = [event for event in events if event["event"] == "run"]
        # #when the harness runs from outside the case directory
        observed = {
            "return_code": result.returncode,
            "recorded_tasks_dirs": [event["tasks_dir"] for event in run_events],
            "archive_preserved": [
                (operator_directory / "archive" / "stand-in-layout"
                 / "sample-case-operator-relative-1" / "rounds" / "01-bench").is_dir()
            ],
            "review_heads": [event["head"] for event in run_events],
        }
        # #then every relative input remains relative to the operator's launch directory
        self.assertEqual(
            observed,
            {
                "return_code": 0,
                "recorded_tasks_dirs": [str(operator_directory / "archive")],
                "archive_preserved": [True],
                "review_heads": [self.head],
            },
        )

    def test_resolves_abbreviated_case_revisions_to_full_shas_before_review(self):
        # #given a case that names valid abbreviated revisions
        abbreviated_case = json.loads(self.case_path.read_text(encoding="utf-8"))
        abbreviated_case.update(base=self.base[:7], head=self.head[:7])
        abbreviated_case_path = self.directory / "abbreviated-case.json"
        abbreviated_case_path.write_text(json.dumps(abbreviated_case), encoding="utf-8")
        result = self.run_harness("abbreviated", 1, case_path=abbreviated_case_path)
        events = (
            [json.loads(line) for line in self.log_path.read_text(encoding="utf-8").splitlines()]
            if self.log_path.exists()
            else []
        )
        new_events = [event for event in events if event["event"] == "new"]
        run_events = [event for event in events if event["event"] == "run"]
        bench_records = [
            json.loads((Path(event["output"]["round_dir"]) / "bench.json").read_text(encoding="utf-8"))
            for event in new_events
            if (Path(event["output"]["round_dir"]) / "bench.json").exists()
        ]
        # #when the harness fetches and reviews the case
        observed = {
            "return_code": result.returncode,
            "review_heads": [event["head"] for event in run_events],
            "scope_texts": [event["scope"] for event in run_events],
            "bench_revisions": [
                {"base": record["base"], "head": record["head"]}
                for record in bench_records
            ],
        }
        # #then Git's canonical revisions reach both the review and the round record
        self.assertEqual(
            observed,
            {
                "return_code": 0,
                "review_heads": [self.head],
                "scope_texts": [
                    f"Range: {self.base}..{self.head}\n"
                    f"git diff {self.base}..{self.head}\n\n"
                    "# Scope\n\nReview the benchmark fixture change."
                ],
                "bench_revisions": [{"base": self.base, "head": self.head}],
            },
        )

    def test_rejects_an_existing_task_before_writing_the_tasks_directory(self):
        # #given a task identity already present in the requested archive
        existing_task = self.tasks_dir / "sample-case-rerun-1"
        existing_task.mkdir(parents=True)
        (existing_task / "prior-round.txt").write_text("preserve me\n", encoding="utf-8")
        result = self.run_harness("rerun", 1)
        # #when the same identity is requested again
        observed = {
            "failed": result.returncode != 0,
            "names_existing_task": str(existing_task) in result.stderr,
            "tasks_dir_entries": sorted(path.name for path in self.tasks_dir.iterdir()),
            "prior_round": (existing_task / "prior-round.txt").read_text(encoding="utf-8"),
        }
        # #then the harness reports the collision without adding an archive entry
        self.assertEqual(
            observed,
            {
                "failed": True,
                "names_existing_task": True,
                "tasks_dir_entries": ["sample-case-rerun-1"],
                "prior_round": "preserve me\n",
            },
        )

    def test_reports_checkout_failure_after_recording_each_repetition_input(self):
        # #given a case whose head cannot be fetched from the fixture repository
        failed_case = json.loads(self.case_path.read_text(encoding="utf-8"))
        failed_case["head"] = "missing-head"
        failed_case_path = self.directory / "missing-head-case.json"
        failed_case_path.write_text(json.dumps(failed_case), encoding="utf-8")
        expected_git_failure = subprocess.run(
            ["git", "-C", str(self.repository), "rev-parse", "--verify",
             "missing-head^{commit}"],
            check=False,
            capture_output=True,
            text=True,
        ).stderr.strip()
        result = self.run_harness("checkout-failure", 2, case_path=failed_case_path)
        events = (
            [json.loads(line) for line in self.log_path.read_text(encoding="utf-8").splitlines()]
            if self.log_path.exists()
            else []
        )
        new_events = [event for event in events if event["event"] == "new"]
        # #when Git rejects the case after revmux creates each round
        observed = {
            "failed": result.returncode != 0,
            "task_failures_reported": [
                task in result.stderr
                for task in ("sample-case-checkout-failure-1", "sample-case-checkout-failure-2")
            ],
            "git_stderr_reported": expected_git_failure in result.stderr,
            "traceback_reported": "Traceback" in result.stderr,
            "round_inputs": [
                {
                    "bench": (Path(event["output"]["round_dir"]) / "bench.json").is_file(),
                    "scope": Path(event["output"]["scope"]).is_file(),
                    "goal": Path(event["output"]["goal"]).is_file(),
                }
                for event in new_events
            ],
        }
        # #then each failed round remains identifiable and the second repetition still runs
        self.assertEqual(
            observed,
            {
                "failed": True,
                "task_failures_reported": [True, True],
                "git_stderr_reported": True,
                "traceback_reported": False,
                "round_inputs": [
                    {"bench": True, "scope": True, "goal": True},
                    {"bench": True, "scope": True, "goal": True},
                ],
            },
        )


if __name__ == "__main__":
    unittest.main()
