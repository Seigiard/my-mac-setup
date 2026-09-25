from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
MAKEFILE = REPOSITORY / "Makefile"
WORKFLOW = REPOSITORY / ".github" / "workflows" / "test-dotfiles.yml"
RUNNER = REPOSITORY / "tests" / "run-post-apply.sh"
GENERATED = REPOSITORY / "tests" / "bashunit"

# A suite run-post-apply.sh has never seen, with declarations written by hand.
# The expected order and eligibility below are therefore this test's own
# statement of the contract, not a Python re-implementation of the runner's
# parsing applied to the same files the runner reads: a wrapper and a test that
# both misread `needs-disposable-home` would agree, and stay green together.
#
# Declared order (10, 20, 30) deliberately disagrees with both file order and
# alphabetical order, so neither can be mistaken for the declared order.
SYNTHETIC_SUITE = {
    "alpha_test.sh": "# post-apply: 30 host-safe",
    "bravo_test.sh": "# post-apply: 10 needs-disposable-home",
    "charlie_test.sh": "# post-apply: 20 host-safe",
    "delta_test.sh": "# post-apply: excluded",
}
FULL_MODE_ORDER = ["bravo_test.sh", "charlie_test.sh", "alpha_test.sh"]
HOST_SAFE_MODE_ORDER = ["charlie_test.sh", "alpha_test.sh"]

# The launcher invocation each applying CI job must follow with the suite.
POST_APPLY_RUN = "tests/run-post-apply.sh full"
APPLY_LAUNCHER = re.compile(
    r"tests/helpers/chezmoi-unattended\b[^\n]*\s--\s+apply\b"
)


class TestPostApplySuiteContract(unittest.TestCase):
    # -- the wrapper's selection contract ---------------------------------

    def test_full_mode_runs_every_declared_suite_in_declared_order(self):
        # #given / #when
        invocations = self.wrapper_invocations("full")
        # #then
        self.assertEqual([Path(argv[-1]).name for argv in invocations], FULL_MODE_ORDER)

    def test_host_safe_mode_drops_the_suites_that_need_a_disposable_home(self):
        # The same suite, one mode later: only the eligibility word may
        # change the outcome, and the surviving files keep full-mode order.
        invocations = self.wrapper_invocations("host-safe")
        self.assertEqual(
            [Path(argv[-1]).name for argv in invocations], HOST_SAFE_MODE_ORDER
        )

    def test_every_real_suite_file_carries_a_usable_declaration(self):
        """The runner rejects a suite file with a missing, malformed or
        duplicate-order declaration (see the two rejection tests below), so a
        clean full-mode run over the real tests/bashunit is the statement that
        every file there is classified -- without this test re-deriving the
        classification it is checking."""
        with tempfile.TemporaryDirectory() as temp_dir:
            env = self.runner_environment(Path(temp_dir))
            env["MMS_BASHUNIT_SUITE_DIR"] = str(GENERATED)
            completed = subprocess.run(
                [str(RUNNER), "full"],
                cwd=REPOSITORY,
                env=env,
                capture_output=True,
                text=True,
            )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def test_wrapper_forwards_the_operators_worker_cap_to_bashunit(self):
        # "3" is this test's own value, unrelated to the wrapper's default, so
        # a wrapper that hardcoded its worker count instead of reading
        # MMS_BASHUNIT_JOBS fails here. CI's macOS job really does set
        # MMS_BASHUNIT_JOBS=4, so pinning the literal default instead would be
        # red for a supported configuration and blind to the regression that
        # matters -- the wrapper dropping the operator's cap on the floor.
        invocations = self.wrapper_invocations("full", jobs="3")
        # The suite set first: the assertions below are per invocation, so a
        # wrapper that produced none would forward nothing and pass.
        self.assertEqual(
            [Path(argv[-1]).name for argv in invocations], FULL_MODE_ORDER
        )
        for argv in invocations:
            with self.subTest(suite=Path(argv[-1]).name):
                # The report path is a fresh mktemp file per invocation, so
                # the flag is asserted and the path is not. --report-json is
                # the wrapper's own operational contract: its inline
                # failure-name reporter reads that file back.
                self.assertEqual(argv[:3], ["-j", "3", "--report-json"])
                self.assertEqual(len(argv), 5)

    def test_the_default_worker_count_is_a_positive_integer(self):
        # The default is the wrapper's own overridable choice, so its value is
        # not pinned; what must hold is that the unset case still reaches
        # bashunit with a usable count instead of an empty string or 0.
        invocations = self.wrapper_invocations("full")
        self.assertEqual(
            [Path(argv[-1]).name for argv in invocations], FULL_MODE_ORDER
        )
        for argv in invocations:
            with self.subTest(suite=Path(argv[-1]).name):
                self.assertEqual(argv[0], "-j")
                self.assertTrue(
                    argv[1].isdigit() and int(argv[1]) > 0,
                    "default worker count must be a positive integer, got %r" % argv[1],
                )

    # -- the wrapper's rejection contract ---------------------------------

    def test_runner_rejects_a_malformed_post_apply_declaration(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            env = self.runner_environment(temp_path)
            suite_dir = self.write_suite(temp_path, {"valid_test.sh": "# post-apply: 10 host-safe"})
            env["MMS_BASHUNIT_SUITE_DIR"] = str(suite_dir)

            control = subprocess.run(
                [str(RUNNER), "full"], cwd=REPOSITORY, env=env, capture_output=True, text=True
            )
            (suite_dir / "broken_test.sh").write_text(
                "#!/usr/bin/env bash\n# post-apply: 20a host-safe\n", encoding="utf-8"
            )
            completed = subprocess.run(
                [str(RUNNER), "full"], cwd=REPOSITORY, env=env, capture_output=True, text=True
            )

        self.assertEqual(control.returncode, 0, control.stdout + control.stderr)
        self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
        self.assertIn("invalid post-apply declaration", completed.stderr)

    def test_runner_rejects_a_missing_post_apply_declaration(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            env = self.runner_environment(temp_path)
            suite_dir = self.write_suite(temp_path, {"valid_test.sh": "# post-apply: 10 host-safe"})
            env["MMS_BASHUNIT_SUITE_DIR"] = str(suite_dir)

            control = subprocess.run(
                [str(RUNNER), "full"], cwd=REPOSITORY, env=env, capture_output=True, text=True
            )
            (suite_dir / "missing_test.sh").write_text(
                "#!/usr/bin/env bash\n# no eligibility declaration\n", encoding="utf-8"
            )
            completed = subprocess.run(
                [str(RUNNER), "full"], cwd=REPOSITORY, env=env, capture_output=True, text=True
            )

        self.assertEqual(control.returncode, 0, control.stdout + control.stderr)
        self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
        self.assertIn("missing post-apply declaration", completed.stderr)

    # -- who calls the wrapper --------------------------------------------

    def test_every_applying_ci_job_runs_the_post_apply_suite(self):
        # The relationship between two independently maintained sides:
        # whatever applies the dotfiles must then run the suite against them.
        # Asserted on the step's `run:` value, not on the job body, because a
        # comment or an echo naming the command satisfies a body search.
        # The compose side of the same rule is owned by
        # tests/test_docker_contract.py's
        # test_apply_service_scripts_propagate_a_failing_post_apply_suite.
        workflow = WORKFLOW.read_text(encoding="utf-8")
        applying = []
        for name in self.job_names(workflow):
            body = self.job_block(workflow, name)
            if not APPLY_LAUNCHER.search(body):
                continue
            applying.append(name)
            with self.subTest(job=name):
                self.assertEqual(
                    self.step_run(body, "Run post-apply tests"),
                    POST_APPLY_RUN,
                    "job %s applies the dotfiles but never runs the post-apply suite"
                    % name,
                )
        # Which jobs apply, not how many: a job whose launcher line stops
        # matching drops out of the loop above with every assertion in it.
        self.assertEqual(applying, ["test-ubuntu", "test-macos"])

    def test_make_test_suite_reaches_only_the_host_safe_mode(self):
        # make test-suite is host-safe by design: it must reach the wrapper,
        # and must not reach the full mode, which runs real apply tests.
        makefile = MAKEFILE.read_text(encoding="utf-8")
        recipe = re.search(r"^test-suite:.*?(?=^\S|\Z)", makefile, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(recipe, "Makefile must define the test-suite target")
        self.assertEqual(
            [
                line[1:].strip()
                for line in recipe.group(0).splitlines()
                if line.startswith("\t") and not line[1:].lstrip().startswith("@echo")
            ],
            ["tests/run-post-apply.sh host-safe"],
        )

    # -- helpers ----------------------------------------------------------

    def job_names(self, workflow):
        jobs = re.search(r"^jobs:\n(?P<body>.*)\Z", workflow, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(jobs, "workflow must declare a jobs block")
        names = re.findall(r"^  ([a-zA-Z0-9_-]+):\n", jobs.group("body"), re.MULTILINE)
        self.assertTrue(names, "no jobs parsed from the workflow")
        return names

    def job_block(self, workflow, name):
        block = re.search(
            r"^  %s:\n(?P<body>.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)" % re.escape(name),
            workflow,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(block, "%s job is missing" % name)
        return block.group("body")

    def step_run(self, job, step_name):
        """A named step's literal `run:` value."""
        step = re.search(
            r"^      - name: %s\n(?P<body>.*?)(?=^      - name: |\Z)" % re.escape(step_name),
            job,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(step, "%s step is missing" % step_name)
        run = re.search(r"^        run: (?P<command>.+)$", step.group("body"), re.MULTILINE)
        self.assertIsNotNone(run, "%s step must declare a run: command" % step_name)
        return run.group("command").strip()

    def write_suite(self, root, declarations):
        """A suite directory holding one file per declaration."""
        suite_dir = root / "suite"
        suite_dir.mkdir()
        for name, declaration in declarations.items():
            (suite_dir / name).write_text(
                "#!/usr/bin/env bash\n%s\n" % declaration, encoding="utf-8"
            )
        return suite_dir

    def runner_environment(self, root):
        """An environment whose bashunit records its argv and whose `ps` is
        inert.

        The wrapper's suite-end orphan-watcher guard
        (docs/solutions/design-patterns/outliving-processes-hang-the-suite.md)
        scans the live `ps` table and can independently force rc=1 when it
        finds an abandoned herdr-child watcher rooted at this checkout -- a
        real condition in this repo's own herdr-based dev environment. Left
        unstubbed, a control run's failure cannot be told apart from that
        environment artifact.
        """
        stub_dir = root / "stub-bin"
        stub_dir.mkdir()
        (stub_dir / "ps").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        (stub_dir / "ps").chmod(0o755)

        bashunit = root / "bashunit"
        bashunit.write_text(
            "#!/bin/sh\n"
            "printf '%s\\036' \"$@\" >> \"$BASHUNIT_ARGV_FILE\"\n"
            "printf '\\037' >> \"$BASHUNIT_ARGV_FILE\"\n"
            "exit 0\n",
            encoding="utf-8",
        )
        bashunit.chmod(0o755)

        env = os.environ.copy()
        env["PATH"] = str(stub_dir) + os.pathsep + env["PATH"]
        env["MMS_BASHUNIT_BIN"] = str(bashunit)
        env["BASHUNIT_ARGV_FILE"] = str(root / "argv")
        env.pop("MMS_BASHUNIT_JOBS", None)
        return env

    def wrapper_invocations(self, mode, jobs=None):
        """Every bashunit argv the wrapper produced for SYNTHETIC_SUITE."""
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            env = self.runner_environment(root)
            env["MMS_BASHUNIT_SUITE_DIR"] = str(self.write_suite(root, SYNTHETIC_SUITE))
            if jobs is not None:
                env["MMS_BASHUNIT_JOBS"] = jobs
            completed = subprocess.run(
                [str(RUNNER), mode], cwd=REPOSITORY, env=env, capture_output=True, text=True
            )
            self.assertEqual(
                completed.returncode, 0, completed.stdout + completed.stderr
            )
            raw = Path(env["BASHUNIT_ARGV_FILE"]).read_text(encoding="utf-8")
        return [call.split("\036")[:-1] for call in raw.split("\037") if call]


if __name__ == "__main__":
    unittest.main()
