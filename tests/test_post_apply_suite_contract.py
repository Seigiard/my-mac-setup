from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
MAKEFILE = REPOSITORY / "Makefile"
WORKFLOW = REPOSITORY / ".github" / "workflows" / "test-dotfiles.yml"
COMPOSE = REPOSITORY / "docker" / "docker-compose.yml"
RUNNER = REPOSITORY / "tests" / "run-post-apply.sh"
GENERATED = REPOSITORY / "tests" / "bashunit"
POST_APPLY_DECLARATION = re.compile(
    r"^# post-apply: (?P<order>[1-9][0-9]*) "
    r"(?P<eligibility>host-safe|needs-disposable-home)$"
)


class TestPostApplySuiteContract(unittest.TestCase):
    def test_post_apply_suite_uses_one_wrapper_with_two_explicit_modes(self):
        makefile = MAKEFILE.read_text(encoding="utf-8")
        workflow = WORKFLOW.read_text(encoding="utf-8")

        # Counting occurrences pinned "how many exist today" -- a number with
        # no origin outside the file being read -- and the workflow count also
        # pinned the YAML spelling `run: `, so reformatting a step to `run: |`
        # broke it with no behaviour change. What the wrapper actually owes CI
        # is a relationship between two independently maintained sides:
        # whatever applies the dotfiles must then run the suite against them.
        # The compose side of the same rule is owned by
        # tests/test_docker_contract.py's
        # test_apply_service_scripts_propagate_a_failing_post_apply_suite,
        # which executes each applying service's script against a stubbed
        # wrapper and requires the exit code to survive -- strictly stronger
        # than counting the command's occurrences.
        jobs = re.search(r"^jobs:\n(?P<body>.*)\Z", workflow, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(jobs, "workflow must declare a jobs block")
        job_names = re.findall(r"^  ([a-zA-Z0-9_-]+):\n", jobs.group("body"), re.MULTILINE)
        self.assertTrue(job_names, "no jobs parsed from the workflow")

        applying = []
        for name in job_names:
            block = re.search(
                r"^  %s:\n(?P<body>.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)" % re.escape(name),
                workflow,
                re.MULTILINE | re.DOTALL,
            )
            body = block.group("body")
            if "chezmoi apply" not in body:
                continue
            applying.append(name)
            self.assertIn(
                "tests/run-post-apply.sh full",
                body,
                "job %s applies the dotfiles but never runs the post-apply suite" % name,
            )
        # An empty selection would let the loop above pass vacuously.
        self.assertGreaterEqual(len(applying), 2, "expected at least two applying CI jobs, got %r" % applying)

        # make test-suite is host-safe by design: it must reach the wrapper,
        # and must not reach the full mode, which runs real apply tests.
        recipe = re.search(r"^test-suite:.*?(?=^\S|\Z)", makefile, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(recipe, "Makefile must define the test-suite target")
        self.assertRegex(recipe.group(0), r"(?m)^\t.*tests/run-post-apply\.sh host-safe\b")
        self.assertNotRegex(recipe.group(0), r"(?m)^\t.*tests/run-post-apply\.sh full\b")

        suite_files = self.discovered_suite_files()
        self.assertTrue(suite_files, "no post-apply suite files discovered on disk")

        declarations = {f: self.post_apply_declaration(f) for f in suite_files}
        orders = [order for order, _ in declarations.values()]
        self.assertEqual(len(orders), len(set(orders)), "post-apply order values must be unique")

        # "3" is this test's own value, unrelated to the wrapper's default, so
        # a wrapper that hardcoded its worker count instead of reading
        # MMS_BASHUNIT_JOBS fails here.
        full_invocations = self.wrapper_invocations("full", jobs="3")
        host_safe_invocations = self.wrapper_invocations("host-safe", jobs="3")
        self.assert_invocation_shape(full_invocations, "full mode", "3")
        self.assert_invocation_shape(host_safe_invocations, "host-safe mode", "3")

        # The unset case must still reach bashunit with a positive integer, so
        # the default cannot silently become empty or 0.
        default_invocations = self.wrapper_invocations("host-safe")
        self.assertTrue(default_invocations, "wrapper ran no suite file by default")
        for argv in default_invocations:
            self.assertEqual(argv[0], "-j", "default worker flag")
            self.assertTrue(
                argv[1].isdigit() and int(argv[1]) > 0,
                "default worker count must be a positive integer, got %r" % argv[1],
            )

        full_files = [argv[-1] for argv in full_invocations]
        host_safe_files = [argv[-1] for argv in host_safe_invocations]

        self.assertEqual(
            full_files,
            [str(f) for f in sorted(suite_files, key=lambda f: declarations[f][0])],
            "full mode must run every discovered suite once in declared order -- "
            "a new tests/bashunit/*_test.sh file must be explicitly classified",
        )
        self.assertEqual(
            len(full_files),
            len(set(full_files)),
            "full mode must not run any suite file twice",
        )
        self.assertEqual(
            host_safe_files,
            [
                f
                for f in full_files
                if declarations[Path(f)][1] == "host-safe"
            ],
            "host-safe mode must follow the eligibility declarations consumed "
            "by the runner, in full-mode order",
        )

    def test_runner_rejects_a_malformed_post_apply_declaration(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            (temp_path / "valid_test.sh").write_text(
                "#!/usr/bin/env bash\n# post-apply: 10 host-safe\n",
                encoding="utf-8",
            )
            fake_bashunit = temp_path / "bashunit"
            fake_bashunit.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_bashunit.chmod(0o755)
            env = os.environ.copy()
            env["MMS_BASHUNIT_BIN"] = str(fake_bashunit)
            env["MMS_BASHUNIT_SUITE_DIR"] = str(temp_path)

            control = subprocess.run(
                [str(RUNNER), "full"],
                cwd=REPOSITORY,
                env=env,
                capture_output=True,
                text=True,
            )
            (temp_path / "broken_test.sh").write_text(
                "#!/usr/bin/env bash\n# post-apply: 20a host-safe\n",
                encoding="utf-8",
            )
            completed = subprocess.run(
                [str(RUNNER), "full"],
                cwd=REPOSITORY,
                env=env,
                capture_output=True,
                text=True,
            )

        self.assertEqual(control.returncode, 0, control.stderr)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("invalid post-apply declaration", completed.stderr)

    def test_runner_rejects_a_missing_post_apply_declaration(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            (temp_path / "valid_test.sh").write_text(
                "#!/usr/bin/env bash\n# post-apply: 10 host-safe\n",
                encoding="utf-8",
            )
            (temp_path / "missing_test.sh").write_text(
                "#!/usr/bin/env bash\n# no eligibility declaration\n",
                encoding="utf-8",
            )
            fake_bashunit = temp_path / "bashunit"
            fake_bashunit.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_bashunit.chmod(0o755)
            env = os.environ.copy()
            env["MMS_BASHUNIT_BIN"] = str(fake_bashunit)
            env["MMS_BASHUNIT_SUITE_DIR"] = str(temp_path)

            completed = subprocess.run(
                [str(RUNNER), "full"],
                cwd=REPOSITORY,
                env=env,
                capture_output=True,
                text=True,
            )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("missing post-apply declaration", completed.stderr)

    def discovered_suite_files(self):
        """Suite files this wrapper is responsible for driving, found on disk
        rather than copied from run-post-apply.sh's own file list."""
        candidates = sorted(GENERATED.glob("*_test.sh"))
        texts = {f.name: f.read_text(encoding="utf-8") for f in candidates}
        outside_sources = [
            MAKEFILE.read_text(encoding="utf-8"),
            WORKFLOW.read_text(encoding="utf-8"),
            COMPOSE.read_text(encoding="utf-8"),
        ]
        return [
            f
            for f in candidates
            if not self.wired_outside_the_wrapper(f.name, outside_sources)
            and not self.nested_inside_a_sibling(f.name, texts)
        ]

    def post_apply_declaration(self, path):
        declarations = []
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("# post-apply:"):
                declarations.append(POST_APPLY_DECLARATION.fullmatch(line))
            elif line and not line.startswith("#"):
                break
        self.assertEqual(
            len(declarations),
            1,
            f"{path.name} must have exactly one post-apply declaration",
        )
        self.assertIsNotNone(
            declarations[0],
            f"{path.name} has an invalid post-apply declaration",
        )
        return (
            int(declarations[0].group("order")),
            declarations[0].group("eligibility"),
        )

    def wired_outside_the_wrapper(self, name, outside_sources):
        """templates_test.sh is the case in point: the Makefile, workflow,
        and compose file each invoke it directly as a pre-apply gate step
        (`tests/lib/bashunit ... tests/bashunit/templates_test.sh`), never
        through tests/run-post-apply.sh. A suite file with its own direct
        bashunit invocation elsewhere is not part of this wrapper's
        inventory; require the literal binary path so a comment or echo
        line that merely mentions the file's path (e.g. Makefile's
        test-suite NOTE about idempotent_test.sh) does not count. The name
        match is boundary-bounded (preceded by a path separator/whitespace/
        start-of-line, followed by whitespace or end-of-line) rather than
        a raw substring test, so one suite file's name being a substring of
        another's (e.g. a hypothetical "widget_test.sh" inside
        "other_widget_test.sh") cannot cause a false match."""
        name_pattern = re.compile(r"(?:^|[\s/])%s(?:\s|$)" % re.escape(name))
        for text in outside_sources:
            for line in text.splitlines():
                stripped = line.strip()
                if stripped.startswith("#") or "run-post-apply.sh" in line:
                    continue
                if "lib/bashunit" in line and name_pattern.search(line):
                    return True
        return False

    def nested_inside_a_sibling(self, name, texts):
        """The herdr/bashunit descriptor probes are driven as a nested
        bashunit invocation from inside scripts_test.sh, wired through
        `$BATS_TEST_DIRNAME/bashunit/<file>`, not by the top-level runner.
        scripts_test.sh also nests a filtered invocation of itself for a
        bounded-pipe regression, so self-references are excluded -- only a
        DIFFERENT sibling wiring a file in this way removes it from the
        top-level inventory. Comment lines are skipped (mirroring
        wired_outside_the_wrapper's own comment skip) so an unrelated remark
        that happens to mention the marker text cannot cause a false
        exclusion of a real, unwired suite file -- the exact regression this
        whole discovery mechanism exists to catch."""
        marker = "BATS_TEST_DIRNAME/bashunit/%s" % name
        for other_name, other_text in texts.items():
            if other_name == name:
                continue
            for line in other_text.splitlines():
                if line.strip().startswith("#"):
                    continue
                if marker in line:
                    return True
        return False

    def assert_invocation_shape(self, invocations, message, expected_jobs):
        for argv in invocations:
            # The report path is a fresh mktemp file per invocation, so assert
            # the flag positions but not the path itself. --report-json is the
            # wrapper's own operational contract: its inline failure-name
            # reporter reads that file back.
            #
            # The worker count is asserted against the value THIS TEST chose
            # via MMS_BASHUNIT_JOBS, never against the wrapper's default.
            # run-post-apply.sh declares that default overridable, and CI's
            # macOS job really does set MMS_BASHUNIT_JOBS=4
            # (.github/workflows/test-dotfiles.yml), so pinning the literal 8
            # made this test red for a supported configuration while staying
            # blind to the regression that matters -- the wrapper dropping the
            # operator's cap on the floor.
            self.assertEqual(len(argv), 5, message)
            self.assertEqual(argv[0], "-j", message)
            self.assertEqual(argv[1], expected_jobs, message)
            self.assertEqual(argv[2], "--report-json", message)

    def wrapper_invocations(self, mode, jobs=None):
        if not RUNNER.exists():
            self.fail("tests/run-post-apply.sh must own the post-apply suite command")

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            argv_file = temp_path / "argv"
            fake_bashunit = temp_path / "bashunit"
            fake_bashunit.write_text(
                "#!/bin/sh\n"
                "printf '%s\\036' \"$@\" >> \"$BASHUNIT_ARGV_FILE\"\n"
                "printf '\\037' >> \"$BASHUNIT_ARGV_FILE\"\n"
                "exit 0\n",
                encoding="utf-8",
            )
            fake_bashunit.chmod(0o755)

            env = os.environ.copy()
            env["BASHUNIT_ARGV_FILE"] = str(argv_file)
            env["MMS_BASHUNIT_BIN"] = str(fake_bashunit)
            if jobs is None:
                env.pop("MMS_BASHUNIT_JOBS", None)
            else:
                env["MMS_BASHUNIT_JOBS"] = jobs
            subprocess.run(
                [str(RUNNER), mode],
                cwd=REPOSITORY,
                env=env,
                check=True,
            )
            raw = argv_file.read_text(encoding="utf-8")
            return [
                call.split("\036")[:-1]
                for call in raw.split("\037")
                if call
            ]


if __name__ == "__main__":
    unittest.main()
