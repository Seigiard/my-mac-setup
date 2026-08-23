import os
from pathlib import Path
import stat
import subprocess
import tempfile
import textwrap
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
WRAPPER = REPOSITORY / "scripts" / "ci" / "macos-bats-flock-bin" / "flock"


class TestMacosBatsFlockWrapper(unittest.TestCase):
    def test_wrapper_maps_directory_lock_target_to_stable_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            capture = root / "lockf.args"
            fake_lockf = fake_bin / "lockf"
            fake_lockf.write_text(
                textwrap.dedent(
                    """\
                    #!/bin/sh
                    printf '%s\n' "$@" > "$CAPTURE"
                    """
                ),
                encoding="utf-8",
            )
            fake_lockf.chmod(fake_lockf.stat().st_mode | stat.S_IXUSR)

            lock_dir = root / "semaphores"
            lock_dir.mkdir()
            env = os.environ.copy()
            env["PATH"] = "%s:%s" % (fake_bin, env.get("PATH", ""))
            env["CAPTURE"] = str(capture)

            subprocess.run(
                [str(WRAPPER), str(lock_dir), "bash", "-c", "true"],
                env=env,
                check=True,
            )

            self.assertEqual(
                capture.read_text(encoding="utf-8").splitlines(),
                ["-k", str(lock_dir / ".bats-lockf.lock"), "bash", "-c", "true"],
            )

    def test_wrapper_rejects_flock_options_it_does_not_implement(self):
        completed = subprocess.run(
            [str(WRAPPER), "-n", "/tmp/example.lock", "true"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(completed.returncode, 64)
        self.assertIn("unsupported flock option", completed.stderr)


if __name__ == "__main__":
    unittest.main()
