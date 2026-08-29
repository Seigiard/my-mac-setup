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

        self.assert_invocations(
            self.wrapper_invocations("full"),
            [
                str(GENERATED / "smoke_test.sh"),
                str(GENERATED / "scripts_test.sh"),
                str(GENERATED / "palette_test.sh"),
                str(GENERATED / "platform_test.sh"),
                str(GENERATED / "idempotent_test.sh"),
            ],
            "full mode must run every suite file sequentially with 8 workers",
        )
        self.assert_invocations(
            self.wrapper_invocations("host-safe"),
            [
                str(GENERATED / "smoke_test.sh"),
                str(GENERATED / "scripts_test.sh"),
                str(GENERATED / "palette_test.sh"),
                str(GENERATED / "platform_test.sh"),
            ],
            "host-safe mode must keep the idempotent suite excluded",
        )

    def assert_invocations(self, invocations, expected_files, message):
        self.assertEqual(len(invocations), len(expected_files), message)
        for argv, expected_file in zip(invocations, expected_files):
            # The report path is a fresh mktemp file per invocation, so assert
            # the flag positions and the suite file but not the path itself.
            self.assertEqual(len(argv), 5, message)
            self.assertEqual(argv[0:2], ["-j", "8"], message)
            self.assertEqual(argv[2], "--report-json", message)
            self.assertEqual(argv[4], expected_file, message)

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
