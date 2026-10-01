"""Fenced admission tells the launcher which route a rejected claim leaves open."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock


ENGINE = Path(__file__).resolve().parents[1] / "home/dot_local/lib/intercom-claim-recovery.py"
spec = importlib.util.spec_from_file_location("claim_recovery_admission_test", ENGINE)
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)

LAUNCHER_START = "launcher-start"


class FakeHerdr:
    """Answers admission RPCs the way a live Herdr 0.9.3 pane did.

    The relaunch case in tests/helpers/intercom_claim_client_probe.py checks the
    used-pane answers against a real Herdr.
    """

    def __init__(self, rename_error=None, record=None):
        self.rename_error = rename_error
        self.record = record
        self.calls = []

    def __call__(self, intent, method, params):
        self.calls.append(method)
        if method in ("pane.report_agent", "pane.release_agent"):
            return {"result": {}}
        if method == "agent.rename":
            if self.rename_error:
                return {"error": {"code": self.rename_error}}
            return {"result": {}}
        if method == "agent.get":
            if self.record:
                return {"result": {"agent": self.record}}
            return {"error": {"code": "agent_not_found"}}
        raise AssertionError(f"unexpected RPC {method}")


class ClaimIntentOutcomeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = str(Path(temporary.name) / "intents")

    def prepared(self, *args, **kwargs):
        intent = {
            "launch_id": "launch-claude-control",
            "phase": "intent",
            "terminal": {"pane_id": "w1:p2", "terminal_id": "term-2"},
            "claim": {"claim_seq": 10, "handoff_seq": 11, "release_seq": 12},
            "client": {"pid": 4242, "start_identity": LAUNCHER_START},
        }
        return recovery.write_intent(self.directory, intent), intent

    def claim(self, herdr):
        with mock.patch.object(recovery, "prepare_intent", self.prepared), \
                mock.patch.object(recovery, "process_start_identity", return_value=LAUNCHER_START), \
                mock.patch.object(recovery, "bound_request", herdr):
            return recovery.claim_intent(self.directory, "claude", "test-source", "ochre-okapi", 4242, None)

    def test_ignored_report_on_a_used_pane_is_reported_as_undeclarable(self):
        # given a pane whose earlier client exited: the report succeeds, creates
        # nothing, and the rename finds no record
        herdr = FakeHerdr(rename_error="agent_not_found")
        # when admission tries to claim an alias there
        result = self.claim(herdr)
        # then the launcher learns the pane is undeclarable, with nothing pending
        self.assertEqual(
            {key: result[key] for key in ("claimed", "retry", "undeclarable", "pending")},
            {"claimed": False, "retry": False, "undeclarable": True, "pending": False})
        self.assertEqual(herdr.calls, ["pane.report_agent", "agent.rename", "pane.release_agent", "agent.get"])
        self.assertEqual(recovery.read_intent(result["intent"])["phase"], "settled")

    def test_alias_collision_retries_and_is_not_undeclarable(self):
        # given a pane that accepted the report, but the alias belongs to a peer
        result = self.claim(FakeHerdr(rename_error="agent_name_taken"))
        # then only a retry with another alias is offered
        self.assertEqual(
            {key: result[key] for key in ("claimed", "retry", "undeclarable", "pending")},
            {"claimed": False, "retry": True, "undeclarable": False, "pending": False})

    def test_unconfirmed_cleanup_stays_pending_and_is_not_undeclarable(self):
        # given the same ignored report, but a record is still visible after release
        result = self.claim(FakeHerdr(rename_error="agent_not_found", record={"name": "someone-else"}))
        # then the attempt stays pending and never opens the fallback route
        self.assertFalse(result["claimed"])
        self.assertTrue(result["pending"])
        self.assertNotIn("undeclarable", result)
        self.assertEqual(recovery.read_intent(result["intent"])["phase"], "intent")

    def test_accepted_claim_is_acquired(self):
        # given a fresh pane that keeps the declared record under the alias
        result = self.claim(FakeHerdr(record={"name": "ochre-okapi", "agent": "claude",
                                              "terminal_id": "term-2", "agent_status": "unknown"}))
        # then the claim is acquired, not routed to any fallback
        self.assertTrue(result["claimed"])
        self.assertNotIn("undeclarable", result)


if __name__ == "__main__":
    unittest.main()
