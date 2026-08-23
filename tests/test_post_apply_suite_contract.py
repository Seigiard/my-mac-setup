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
            self.wrapper_argv("full"),
            [
                "--jobs",
                "8",
                "--no-parallelize-across-files",
                "tests/smoke.bats",
                "tests/scripts.bats",
                "tests/palette.bats",
                "tests/platform.bats",
                "tests/idempotent.bats",
            ],
            "full mode must run the complete post-apply suite with the shared parallel flags",
        )
        self.assertEqual(
            self.wrapper_argv("host-safe"),
            [
                "--jobs",
                "8",
                "--no-parallelize-across-files",
                "tests/smoke.bats",
                "tests/scripts.bats",
                "tests/palette.bats",
                "tests/platform.bats",
            ],
            "host-safe mode must keep tests/idempotent.bats excluded behind the shared flags",
        )

    def wrapper_argv(self, mode):
        if not RUNNER.exists():
            self.fail("tests/run-post-apply.sh must own the post-apply bats command")

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            fake_bin = temp_path / "bin"
            fake_bin.mkdir()
            argv_file = temp_path / "argv"
            fake_bats = fake_bin / "bats"
            fake_bats.write_text(
                "#!/bin/sh\n"
                "printf '%s\n' \"$@\" > \"$BATS_ARGV_FILE\"\n"
                "exit 0\n",
                encoding="utf-8",
            )
            fake_bats.chmod(0o755)

            env = os.environ.copy()
            env["BATS_ARGV_FILE"] = str(argv_file)
            env["PATH"] = "%s%s%s" % (fake_bin, os.pathsep, env["PATH"])
            subprocess.run(
                [str(RUNNER), mode],
                cwd=REPOSITORY,
                env=env,
                check=True,
            )
            return argv_file.read_text(encoding="utf-8").splitlines()


if __name__ == "__main__":
    unittest.main()
