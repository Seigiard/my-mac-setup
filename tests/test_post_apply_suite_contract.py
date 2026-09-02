from pathlib import Path
import os
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
MAKEFILE = REPOSITORY / "Makefile"
WORKFLOW = REPOSITORY / ".github" / "workflows" / "test-dotfiles.yml"
COMPOSE = REPOSITORY / "docker" / "docker-compose.yml"
RUNNER = REPOSITORY / "tests" / "run-post-apply.sh"
GENERATED = REPOSITORY / "tests" / "bashunit"


class TestPostApplySuiteContract(unittest.TestCase):
    def test_post_apply_suite_uses_one_wrapper_with_two_explicit_modes(self):
        makefile = MAKEFILE.read_text(encoding="utf-8")
        workflow = WORKFLOW.read_text(encoding="utf-8")
        compose = COMPOSE.read_text(encoding="utf-8")

        self.assertEqual(
            workflow.count("run: tests/run-post-apply.sh full"),
            2,
            "both GitHub Actions post-apply steps must call the shared full-suite wrapper",
        )
        self.assertEqual(
            compose.count("tests/run-post-apply.sh full"),
            2,
            "both Docker full-suite services must call the shared full-suite wrapper",
        )
        self.assertEqual(
            makefile.count("tests/run-post-apply.sh host-safe"),
            1,
            "make test-suite must call the host-safe wrapper mode exactly once",
        )

        suite_files = self.discovered_suite_files()
        self.assertTrue(suite_files, "no post-apply suite files discovered on disk")

        # idempotent_test.sh is the only discovered file whose own hard-fail
        # guard reads both markers together (lines ~178-179): it refuses to
        # run for real unless MMS_DISPOSABLE_HOME=1 *and* it can tell this is
        # a real CI/container environment via GITHUB_ACTIONS. scripts_test.sh
        # also mentions MMS_DISPOSABLE_HOME (it parameterizes an unrelated
        # script under test), but never GITHUB_ACTIONS, so the AND of both
        # markers isolates the file this wrapper must keep host-unsafe
        # without naming it.
        guarded = [
            f
            for f in suite_files
            if "MMS_DISPOSABLE_HOME" in f.read_text(encoding="utf-8")
            and "GITHUB_ACTIONS" in f.read_text(encoding="utf-8")
        ]
        self.assertEqual(
            len(guarded),
            1,
            "exactly one discovered suite file should carry the disposable-home "
            "hard-fail guard, found: %s" % [f.name for f in guarded],
        )
        guarded_path = str(guarded[0])

        full_invocations = self.wrapper_invocations("full")
        host_safe_invocations = self.wrapper_invocations("host-safe")
        self.assert_invocation_shape(full_invocations, "full mode")
        self.assert_invocation_shape(host_safe_invocations, "host-safe mode")

        full_files = [argv[-1] for argv in full_invocations]
        host_safe_files = [argv[-1] for argv in host_safe_invocations]

        self.assertEqual(
            set(full_files),
            {str(f) for f in suite_files},
            "full mode must run every suite file discovered on disk -- a new "
            "tests/bashunit/*_test.sh file must be wired into the runner or "
            "this fails",
        )
        self.assertEqual(
            len(full_files),
            len(set(full_files)),
            "full mode must not run any suite file twice",
        )
        self.assertNotIn(
            guarded_path,
            host_safe_files,
            "host-safe mode must exclude the disposable-home-guarded suite",
        )
        # host-safe's file set is checked against full's *observed* order
        # (not a hardcoded list) so this only asserts the partition
        # relationship, not an order copied from the runner's source.
        self.assertEqual(
            host_safe_files,
            [f for f in full_files if f != guarded_path],
            "host-safe mode must run exactly the full-mode set minus the "
            "guarded suite, in the same relative order",
        )

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

    def wired_outside_the_wrapper(self, name, outside_sources):
        """templates_test.sh is the case in point: the Makefile, workflow,
        and compose file each invoke it directly as a pre-apply gate step
        (`tests/lib/bashunit ... tests/bashunit/templates_test.sh`), never
        through tests/run-post-apply.sh. A suite file with its own direct
        bashunit invocation elsewhere is not part of this wrapper's
        inventory; require the literal binary path so a comment or echo
        line that merely mentions the file's path (e.g. Makefile's
        test-suite NOTE about idempotent_test.sh) does not count."""
        for text in outside_sources:
            for line in text.splitlines():
                stripped = line.strip()
                if stripped.startswith("#") or "run-post-apply.sh" in line:
                    continue
                if "lib/bashunit" in line and name in line:
                    return True
        return False

    def nested_inside_a_sibling(self, name, texts):
        """The herdr/bashunit descriptor probes are driven as a nested
        bashunit invocation from inside scripts_test.sh, wired through
        `$BATS_TEST_DIRNAME/bashunit/<file>`, not by the top-level runner.
        scripts_test.sh also nests a filtered invocation of itself for a
        bounded-pipe regression, so self-references are excluded -- only a
        DIFFERENT sibling wiring a file in this way removes it from the
        top-level inventory."""
        marker = "BATS_TEST_DIRNAME/bashunit/%s" % name
        for other_name, other_text in texts.items():
            if other_name != name and marker in other_text:
                return True
        return False

    def assert_invocation_shape(self, invocations, message):
        for argv in invocations:
            # The report path is a fresh mktemp file per invocation, so assert
            # the flag positions but not the path itself. -j 8 and
            # --report-json are the wrapper's own operational contract
            # (worker count and the bashunit report flag), independent of
            # which suite files exist.
            self.assertEqual(len(argv), 5, message)
            self.assertEqual(argv[0:2], ["-j", "8"], message)
            self.assertEqual(argv[2], "--report-json", message)

    def wrapper_invocations(self, mode):
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
