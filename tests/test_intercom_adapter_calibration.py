"""One live oracle, explicitly unverified in ordinary fake-only CI."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest


class AdapterCalibrationTests(unittest.TestCase):
    @unittest.skipUnless(
        os.environ.get("MMS_LIVE_HERDR_CALIBRATION") == "1"
        and os.environ.get("HERDR_ENV") == "1" and shutil.which("herdr"),
        "real Herdr calibration unverified: requires MMS_LIVE_HERDR_CALIBRATION=1 in an owned Herdr pane",
    )
    def test_fake_matches_the_installed_herdr_adapter_contract(self):
        # given an explicitly authorized, installed real oracle
        script = Path(__file__).parent / "helpers/intercom_adapter_calibration.py"
        # when both adapters run the consolidated scenario set
        result = subprocess.run([sys.executable, "-u", str(script)], text=True, capture_output=True)
        # then real conformance and owned cleanup must both complete
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        print(result.stdout, end="", flush=True)


if __name__ == "__main__":
    unittest.main()
