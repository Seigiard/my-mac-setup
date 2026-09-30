"""Terminal launch receipts leave the hot scan without reviving old authority."""

import importlib.util
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock


ENGINE = Path(__file__).resolve().parents[1] / "home/dot_local/lib/intercom-claim-recovery.py"
spec = importlib.util.spec_from_file_location("claim_recovery_archive_test", ENGINE)
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class IntentArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name) / "intents"

    def record(self, phase):
        return recovery.write_intent(str(self.directory), {"launch_id": "launch-control", "phase": phase})

    def test_terminal_records_leave_the_active_scan_and_late_calls_refuse(self):
        # given terminal receipts beside an unresolved obligation
        pending = self.record("intent")
        terminal = [self.record(phase) for phase in ("settled", "retired")]
        # when the real observer visits the completed records
        for path in terminal:
            recovery.observe_one(path)
        # then only the unresolved record remains in the hot scan
        self.assertEqual(recovery.active_intent_paths(str(self.directory)), [pending])
        self.assertEqual(set(recovery.intent_handles(str(self.directory))), {pending, *terminal})
        for path, phase in zip(terminal, ("settled", "retired")):
            self.assertFalse(Path(path).exists())
            self.assertEqual(recovery.read_intent(path)["phase"], phase)
            self.assertFalse(recovery.bind_native_client(path))
            self.assertIsNone(recovery.request_handoff(path))
            self.assertFalse(Path(path + ".lock").exists())

    def test_pending_and_acquired_records_are_never_archived(self):
        # given obligations whose ownership is still unresolved
        paths = [self.record(phase) for phase in ("intent", "acquired")]
        # when archive maintenance is requested under their real locks
        for path in paths:
            with recovery.intent_lock(path):
                self.assertFalse(recovery.archive_terminal_intent(path))
        # then their active records and lock inodes remain available
        self.assertEqual(set(recovery.active_intent_paths(str(self.directory))), set(paths))
        self.assertFalse((self.directory / "archive").exists())

    def test_caller_waiting_on_the_old_lock_cannot_revive_an_archived_intent(self):
        # given a late caller contending on the existing lock inode
        path = self.record("settled")
        blocked = threading.Event()
        result = []
        real_flock = recovery.fcntl.flock

        def observed_flock(*args):
            try:
                return real_flock(*args)
            except BlockingIOError:
                blocked.set()
                raise

        def late_bind():
            try:
                result.append(recovery.bind_native_client(path))
            except Exception as error:
                result.append(error)

        with recovery.intent_lock(path):
            with mock.patch.object(recovery.fcntl, "flock", observed_flock):
                caller = threading.Thread(target=late_bind)
                caller.start()
                self.assertTrue(blocked.wait(2), "late caller never contended on the old lock")
                # when completion moves the receipt while that caller waits
                self.assertTrue(recovery.archive_terminal_intent(path))
        caller.join(6)
        # then the queued caller reads terminal state and no new lock is created
        self.assertFalse(caller.is_alive())
        self.assertEqual(result, [False])
        self.assertEqual(recovery.read_intent(path)["phase"], "settled")
        self.assertFalse(Path(path + ".lock").exists())
        self.assertEqual(recovery.active_intent_paths(str(self.directory)), [])

    def test_archive_retention_expires_old_records_and_caps_recent_records(self):
        # given old diagnostics, excess recent diagnostics, and pending work
        pending = self.record("intent")
        paths = [self.record("settled") for _ in range(4)]
        for path, modified in zip(paths, (10, 950, 960, 970)):
            recovery.observe_one(path)
            os.utime(recovery.archived_intent_path(path), (modified, modified))
        # when age is decisive and the count cap cannot remove anything
        recovery.prune_intent_archive(str(self.directory), now=1000, max_age=100, max_records=10)
        self.assertEqual({item.name for item in (self.directory / "archive").iterdir()},
                         {Path(path).name for path in paths[1:]})
        # when only count is decisive, the two newest receipts survive
        recovery.prune_intent_archive(str(self.directory), now=1000, max_age=10000, max_records=2)
        remaining = {item.name for item in (self.directory / "archive").iterdir()}
        self.assertEqual(remaining, {Path(path).name for path in paths[2:]})
        self.assertEqual(recovery.active_intent_paths(str(self.directory)), [pending])
        for path in paths[:2]:
            self.assertFalse(recovery.bind_native_client(path))
            self.assertIsNone(recovery.request_handoff(path))
            self.assertFalse(Path(path + ".lock").exists())


if __name__ == "__main__":
    unittest.main()
