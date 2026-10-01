"""Process evidence is not a boolean liveness guess."""

import importlib.util
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


ENGINE = Path(__file__).resolve().parents[1] / "home/dot_local/lib/intercom-claim-recovery.py"
spec = importlib.util.spec_from_file_location("intercom_host_test", ENGINE)
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class HostTests(unittest.TestCase):
    def test_process_identity_normalizes_internal_whitespace(self):
        # given ps's space-padded day, independently specified by ps lstart
        row = subprocess.CompletedProcess([], 0, "Thu Oct  1 12:34:56 2026 S\n", "")
        with patch.object(subprocess, "run", return_value=row):
            # when recovery reads a live identity
            identity = recovery.Host().start_identity(os.getpid())
        # then the token uses the shared whitespace-normalized format
        self.assertEqual(identity, "Thu Oct 1 12:34:56 2026")

    def test_zombie_is_exit_evidence_with_a_separate_start_token(self):
        row = subprocess.CompletedProcess([], 0, "Thu Oct  1 12:34:56 2026 Z+\n", "")
        with patch.object(subprocess, "run", return_value=row):
            observed = recovery.Host().process(os.getpid())
        self.assertEqual(tuple(observed), ("exited", "Thu Oct 1 12:34:56 2026", None, "Z+"))

    def test_failed_ps_for_live_pid_is_unknown_not_exit(self):
        row = subprocess.CompletedProcess([], 1, "", "lookup failed")
        with patch.object(subprocess, "run", return_value=row):
            observed = recovery.Host().process(os.getpid())
        self.assertEqual((observed.outcome, observed.reason), ("unknown", "process_lookup_failed"))


if __name__ == "__main__":
    unittest.main()
