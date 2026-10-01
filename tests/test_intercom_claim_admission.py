"""PR401 used-pane regression through complete engine admission."""

from pathlib import Path
import contextlib
import io
import tempfile
import unittest

from helpers.intercom_recovery_adapters import FakeHerdr, FakeHost, recovery


class ClaimIntentOutcomeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.host = FakeHost()
        self.host.alias_candidates = lambda seed: ["ochre-okapi", "silver-ibis"]
        self.host.ensure_owner = lambda root: True
        self.server = FakeHerdr()
        self.engine = recovery.RecoveryEngine(self.root / "recovery/v1", host=self.host, sessions=self.server)

    def admit(self, agent="claude"):
        return self.engine.admit(socket_path="fake.sock", pane_id="w1:p1", agent=agent, launcher_pid=10)

    def test_ignored_report_on_a_used_pane_is_reported_as_undeclarable(self):
        # given the measured 0.9.3 used pane with no visible agent_session
        self.server.undeclarable.add("term-1")
        # when admission owns the attempted declaration and its rollback
        result = self.admit()
        # then Claude enrolls with a durable deferred name and no pending claim
        self.assertEqual(result, recovery.Admission(recovery.Launch("enrolled", "deferred_rename", "ochre-okapi")))
        self.assertEqual((self.root / "reconcile/w1_p1").read_text(), "ochre-okapi\n")
        self.assertEqual([method for method, _ in self.server.events if method in
                          {"pane.report_agent", "agent.rename", "pane.release_agent"}],
                         ["pane.report_agent", "agent.rename", "pane.release_agent"])
        for agent in ("opencode", "pi"):
            self.assertEqual(self.admit(agent), recovery.Admission(recovery.Launch("native", reason_code="used_pane")))

    def test_alias_collision_retries_and_is_not_undeclarable(self):
        # given a peer taking the first candidate after the initial list
        def collide(method, params):
            self.server.apply("pane.report_agent", {"pane_id": "w1:p2", "agent": "pi",
                              "source": "native", "state": "working", "seq": 1})
            self.server.apply("agent.rename", {"target": "w1:p2", "name": params["name"]})
        self.server.schedule("agent.rename", collide)
        # when admission retries a confirmed collision rollback
        result = self.admit()
        # then it acquires the next alias without a deferred note or peer damage
        self.assertEqual(result.launch, recovery.Launch("enrolled", "claimed", "silver-ibis"))
        self.assertEqual(self.engine.observe_one(result.intent_id).phase, "acquired")
        self.assertFalse((self.root / "reconcile/w1_p1").exists())
        self.assertEqual(self.server.request("agent.get", {"target": "w1:p2"})["result"]["agent"]["name"], "ochre-okapi")

    def test_unconfirmed_cleanup_stays_pending_and_is_not_undeclarable(self):
        # given an ignored declaration followed by a newer record before rollback
        self.server.undeclarable.add("term-1")
        def successor(method, params):
            self.server.undeclarable.clear()
            self.server.apply("pane.report_agent", {**params, "seq": params["seq"] + 1, "state": "unknown"})
            self.server.apply("agent.rename", {"target": "w1:p1", "name": "someone-else"})
        self.server.schedule("pane.release_agent", successor)
        # when the successful release leaves that newer record visible
        diagnostics = io.StringIO()
        with contextlib.redirect_stderr(diagnostics):
            result = self.admit()
        # then no deferred enrollment is authorized and the obligation survives
        self.assertEqual(result.launch.kind, "native")
        self.assertEqual(self.engine.observe_one(result.intent_id).phase, "intent")
        self.assertEqual(diagnostics.getvalue(), "admission unavailable: partial claim remains pending for recovery\n")
        self.assertFalse((self.root / "reconcile/w1_p1").exists())
        self.assertEqual(self.server.request("agent.get", {"target": "w1:p1"})["result"]["agent"]["name"], "someone-else")

    def test_accepted_claim_is_acquired(self):
        # given a fresh declarable pane
        # when admission claims its alias
        result = self.admit()
        # then the supported claim route, not deferred rename, owns cleanup
        self.assertEqual(result.launch, recovery.Launch("enrolled", "claimed", "ochre-okapi"))
        self.assertEqual(self.engine.observe_one(result.intent_id).phase, "acquired")
        self.assertFalse((self.root / "reconcile/w1_p1").exists())

    def test_other_clean_rejection_neither_defers_nor_claims_pending_cleanup(self):
        # given a rename rejection unrelated to a used pane or collision
        apply = self.server.apply
        self.server.apply = lambda method, params: (
            {"error": {"code": "invalid_name"}} if method == "agent.rename" else apply(method, params))
        # when rollback confirms that nothing remains
        diagnostics = io.StringIO()
        with contextlib.redirect_stderr(diagnostics):
            result = self.admit()
        # then native startup has no outstanding claim or pending warning
        self.assertEqual(result, recovery.Admission(recovery.Launch("native", reason_code="acquisition_unconfirmed")))
        self.assertEqual(diagnostics.getvalue(), "admission unavailable: the rejected claim was rolled back\n")
        self.assertFalse((self.root / "reconcile/w1_p1").exists())


if __name__ == "__main__":
    unittest.main()
