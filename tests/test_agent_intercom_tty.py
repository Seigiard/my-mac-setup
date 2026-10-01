"""The PTY fixture preserves command status and bounds inherited output handles."""

from pathlib import Path
import subprocess
import sys
import unittest


RUNNER = Path(__file__).resolve().parent / "helpers/agent_intercom_tty.py"


class PtyRunnerTests(unittest.TestCase):
    def test_command_output_and_nonzero_status_survive_the_pty(self):
        # given a command that deliberately exits with status seven
        command = [sys.executable, "-c", "print('PTY_OK'); raise SystemExit(7)"]
        # when the real fixture runs it
        result = subprocess.run([sys.executable, str(RUNNER), *command], text=True,
                                capture_output=True, timeout=15)
        # then neither output nor status is normalized into success
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(result.stdout, "PTY_OK\n")

    @unittest.skipUnless(sys.platform == "linux", "Linux preserves the PTY slave held by a SIGHUP-ignoring descendant")
    def test_descendant_output_handle_cannot_outlive_the_selected_bound(self):
        # given a main command that exits while a child holds the slave open
        command = """import os, signal, time
r, w = os.pipe()
if os.fork() == 0:
    os.close(r)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    os.write(w, b'ready')
    os.close(w)
    time.sleep(2)
    os._exit(0)
os.close(w)
os.read(r, 5)
os.close(r)
print('MAIN_FINISHED', flush=True)
"""
        entry = (
            "import importlib.util,sys; path=sys.argv.pop(1); "
            "spec=importlib.util.spec_from_file_location('pty_runner',path); "
            "runner=importlib.util.module_from_spec(spec); spec.loader.exec_module(runner); "
            "runner.main(timeout_seconds=0.25)"
        )
        # when the bound is shorter than the descendant's finite lifetime
        result = subprocess.run([sys.executable, "-c", entry, str(RUNNER), sys.executable, "-c", command],
                                text=True, capture_output=True, timeout=10)
        # then the fixture reports timeout after reaching the intended main exit
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, "MAIN_FINISHED\n")
        self.assertIn("TimeoutError", result.stderr)


if __name__ == "__main__":
    unittest.main()
