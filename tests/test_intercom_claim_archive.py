"""Terminal launch receipts leave the hot scan without reviving old authority."""

import os
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock


from helpers.intercom_recovery_adapters import FakeHerdr, FakeHost, recovery


class IntentArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name) / "intents"
        self.engine = recovery.RecoveryEngine(self.temporary.name)

    def record(self, phase):
        host, server = FakeHost(), FakeHerdr()
        host.ensure_owner = lambda root: True
        host.alias_candidates = lambda seed: ["archive-control"]
        engine = recovery.RecoveryEngine(self.temporary.name, host=host, sessions=server)
        if phase == "intent":
            server.lose_response("pane.report_agent", delayed=True)
        claim = engine.admit(socket_path="fake.sock", pane_id="w1:p1", agent="claude", launcher_pid=10)
        if phase in ("settled", "retired"):
            if phase == "settled":
                host.processes.pop(10)
            else:
                server.request("pane.report_agent", {"pane_id": "w1:p1", "source": "native",
                               "agent": "claude", "state": "working", "seq": 1})
            # Crash at the real filesystem rename boundary, after terminal
            # evidence is persisted but before its archive move completes.
            replace = os.replace
            def interrupted_archive(source, destination):
                if Path(destination).parent.name == "archive":
                    raise OSError("interrupted archive rename")
                return replace(source, destination)
            with mock.patch.object(os, "replace", interrupted_archive):
                self.assertEqual(engine.observe_one(claim.intent_id).outcome, "unavailable")
        return str(self.directory / (claim.intent_id + ".json"))

    def test_observation_returns_repeatable_terminal_results_and_unavailable_after_pruning(self):
        # given completed receipts in the engine's real local storage
        engine = recovery.RecoveryEngine(self.temporary.name)
        for phase in ("settled", "retired"):
            path = self.record(phase)
            handle = Path(path).stem
            # when observation archives a receipt and reads it again
            first = engine.observe_one(handle)
            again = engine.observe_one(handle)
            # then completion is repeatable until retention removes the receipt
            self.assertEqual((first.phase, first.outcome), (phase, phase))
            self.assertEqual(again, first)
            recovery.prune_intent_archive(str(self.directory), max_records=0)
            missing = engine.observe_one(handle)
            self.assertEqual((missing.phase, missing.outcome, missing.reason_code,
                              missing.next_attempt_deadline),
                             (None, "unavailable", "intent_unavailable", None))
            self.assertFalse(Path(path).exists())
            self.assertFalse(Path(path + ".lock").exists())

    def test_legacy_identity_is_preserved_until_its_format_is_known(self):
        # given a real engine-produced record persisted with an unsupported format
        host, server = FakeHost(), FakeHerdr()
        host.ensure_owner = lambda root: True
        host.alias_candidates = lambda seed: ["legacy-control"]
        engine = recovery.RecoveryEngine(self.temporary.name, host=host, sessions=server)
        claim = engine.admit(socket_path="fake.sock", pane_id="w1:p1", agent="claude", launcher_pid=10)
        path = self.directory / (claim.intent_id + ".json")
        original = path.read_bytes()
        legacy = json.loads(original)
        legacy.pop("identity_format")
        path.write_text(json.dumps(legacy))
        host.processes.pop(10)
        # when a later observer cannot interpret that recorded process identity
        result = engine.observe_one(claim.intent_id)
        # then absence of format evidence cannot authorize cleanup
        self.assertEqual((result.phase, result.outcome, result.reason_code),
                         ("acquired", "waiting", "identity_format_unknown"))
        self.assertEqual(server.request("agent.get", {"target": "w1:p1"})["result"]["agent"]["name"],
                         "legacy-control")
        # Nearby valid control: the original versioned record can prove exit.
        path.write_bytes(original)
        self.assertEqual(engine.observe_one(claim.intent_id).outcome, "settled")
        self.assertEqual(server.request("agent.get", {"target": "w1:p1"}),
                         {"error": {"code": "agent_not_found"}})

    def test_busy_observation_does_not_read_phase_or_wait_for_lock(self):
        # given an intent locked by another operation
        engine = recovery.RecoveryEngine(self.temporary.name)
        path = self.record("acquired")
        with recovery.intent_lock(path):
            # when the supported observation step attempts this handle
            result = engine.observe_one(Path(path).stem)
        # then no unread phase or deadline is invented
        self.assertEqual((result.phase, result.outcome, result.reason_code,
                          result.next_attempt_deadline), (None, "busy", "intent_busy", None))

    def test_terminal_records_leave_the_active_scan_and_late_calls_refuse(self):
        # given terminal receipts beside an unresolved obligation
        pending = self.record("intent")
        terminal = [self.record(phase) for phase in ("settled", "retired")]
        # when the real observer visits the completed records
        for path in terminal:
            self.engine.observe_one(Path(path).stem)
        # then only the unresolved record remains in the hot scan
        self.assertEqual(recovery.active_intent_paths(str(self.directory)), [pending])
        self.assertEqual(set(recovery.intent_handles(str(self.directory))), {pending, *terminal})
        for path, phase in zip(terminal, ("settled", "retired")):
            self.assertFalse(Path(path).exists())
            self.assertEqual(recovery.read_intent(path)["phase"], phase)
            self.assertFalse(self.engine.bind(Path(path).stem, None))
            self.assertEqual(self.engine.handoff(Path(path).stem).outcome, phase)
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
                result.append(self.engine.bind(Path(path).stem, None))
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
            self.engine.observe_one(Path(path).stem)
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
            self.assertFalse(self.engine.bind(Path(path).stem, None))
            self.assertEqual(self.engine.handoff(Path(path).stem).outcome, "unavailable")
            self.assertFalse(Path(path + ".lock").exists())


if __name__ == "__main__":
    unittest.main()
