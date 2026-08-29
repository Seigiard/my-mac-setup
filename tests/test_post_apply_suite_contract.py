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

        self.assertEqual(
            self.wrapper_invocations("full"),
            [
                ["-j", "8", str(GENERATED / "smoke_test.sh")],
                ["-j", "8", str(GENERATED / "scripts_test.sh")],
                ["-j", "8", str(GENERATED / "palette_test.sh")],
                ["-j", "8", str(GENERATED / "platform_test.sh")],
                ["-j", "8", str(GENERATED / "idempotent_test.sh")],
            ],
            "full mode must run every converted suite file sequentially with 8 workers",
        )
        self.assertEqual(
            self.wrapper_invocations("host-safe"),
            [
                ["-j", "8", str(GENERATED / "smoke_test.sh")],
                ["-j", "8", str(GENERATED / "scripts_test.sh")],
                ["-j", "8", str(GENERATED / "palette_test.sh")],
                ["-j", "8", str(GENERATED / "platform_test.sh")],
            ],
            "host-safe mode must keep the idempotent suite excluded",
        )

    def test_wrapper_regenerates_the_converted_files_from_bats_sources(self):
        target = GENERATED / "platform_test.sh"
        if target.exists():
            target.unlink()
        self.wrapper_invocations("host-safe")
        self.assertTrue(
            target.exists(),
            "the wrapper must regenerate converted files before running them",
        )

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
