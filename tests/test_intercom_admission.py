"""Complete launch decisions at the owner-confirmed engine seam."""

import tempfile
import unittest
import contextlib
import io
from pathlib import Path
from unittest.mock import patch

from helpers.intercom_recovery_adapters import FakeHerdr, FakeHost, recovery


class AdmissionHost(FakeHost):
    def alias_candidates(self, seed):
        return ["ochre-okapi", "silver-ibis", "violet-tern"]

    def ensure_owner(self, root):
        return True


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.host = AdmissionHost()
        self.server = FakeHerdr()
        self.engine = recovery.RecoveryEngine(Path(self.root.name) / "recovery/v1", host=self.host, sessions=self.server)

    def admit(self, pane="w1:p1", agent="claude", launcher_pid=10):
        return self.engine.admit(socket_path="fake.sock", pane_id=pane,
                                 agent=agent, launcher_pid=launcher_pid)

    def test_collision_rolls_back_then_retries_without_changing_other_owner(self):
        # given an alias acquired after the candidate list was read
        def collide(method, params):
            self.server.apply("pane.report_agent", {"pane_id": "w1:p2", "agent": "pi",
                              "source": "native", "state": "working", "seq": 1})
            self.server.apply("agent.rename", {"target": "w1:p2", "name": params["name"]})
        self.server.schedule("agent.rename", collide)
        # when admission owns the whole retry
        result = self.admit()
        # then the second candidate enrolls and the other owner is intact
        self.assertEqual((result.launch.kind, result.launch.route, result.launch.alias),
                         ("enrolled", "claimed", "silver-ibis"))
        self.assertEqual(self.engine.observe_one(result.intent_id).phase, "acquired")
        other = self.server.request("agent.get", {"target": "w1:p2"})["result"]["agent"]
        self.assertEqual((other["name"], other["agent_status"]), ("ochre-okapi", "working"))

    def collision(self):
        def collide(method, params):
            self.server.apply("pane.report_agent", {"pane_id": "w1:p2", "agent": "pi",
                              "source": "native", "state": "working", "seq": 1})
            self.server.apply("agent.rename", {"target": "w1:p2", "name": params["name"]})
        self.server.schedule("agent.rename", collide)

    def test_uncertain_rollback_stops_retry_and_keeps_obligation(self):
        # given a collision whose release response is lost
        self.collision()
        self.server.lose_response("pane.release_agent")
        # when admission tries to reserve an alias
        result = self.admit()
        # then it starts natively with a handle, never a second acquisition
        self.assertEqual(result.launch.kind, "native")
        self.assertEqual(self.engine.observe_one(result.intent_id).phase, "intent")
        self.assertEqual([params["name"] for method, params in self.server.events
                          if method == "agent.rename"], ["ochre-okapi"])
        self.assertEqual(self.server.request("agent.get", {"target": "w1:p2"})["result"]["agent"]["name"],
                         "ochre-okapi")

    def test_ineffective_rollback_cannot_authorize_retry(self):
        self.collision()
        self.server.schedule("pane.release_agent", lambda method, params: self.server.apply(
            "pane.report_agent", {**params, "seq": params["seq"] + 1, "state": "unknown"}))
        result = self.admit()
        self.assertEqual(result.launch.kind, "native")
        self.assertEqual(self.engine.observe_one(result.intent_id).phase, "intent")
        self.assertEqual([params["name"] for method, params in self.server.events
                          if method == "agent.rename"], ["ochre-okapi"])

    def test_lost_acquisition_response_is_native_with_recoverable_handle(self):
        self.server.lose_response("pane.report_agent", delayed=True)
        result = self.admit()
        self.assertEqual((result.launch.kind, result.launch.alias), ("native", None))
        self.host.processes.pop(10)
        self.assertEqual(self.engine.observe_one(result.intent_id).reason_code, "acquisition_unknown")
        self.server.deliver()
        self.assertEqual(self.engine.observe_one(result.intent_id).outcome, "settled")

    def independent_alias(self, name="ochre-okapi"):
        self.server.apply("pane.report_agent", {"pane_id": "w1:p1", "agent": "claude",
                          "source": "native", "state": "working", "seq": 1})
        self.server.apply("agent.rename", {"target": "w1:p1", "name": name})

    def test_independent_alias_reuses_without_owner_or_claim(self):
        self.independent_alias()
        def unavailable(root):
            raise recovery.RecoveryError("owner absent")
        self.host.ensure_owner = unavailable
        result = self.admit()
        self.assertEqual(result, recovery.Admission(recovery.Launch("enrolled", "reused", "ochre-okapi")))

    def test_foreign_name_is_preserved_and_not_enrolled(self):
        self.independent_alias("not-in-pool")
        self.assertEqual(self.admit().launch.kind, "native")
        self.assertEqual(self.server.request("agent.get", {"target": "w1:p1"})["result"]["agent"]["name"],
                         "not-in-pool")

    def test_live_and_unknown_obligations_refuse_reuse(self):
        claim = self.admit()
        self.assertEqual(claim.launch.route, "claimed")
        self.assertEqual(self.admit().launch.kind, "native")
        self.host.processes[10] = recovery.ProcessObservation("unknown", reason="lookup_failed")
        self.host.processes[12] = recovery.ProcessObservation("alive", "new-launcher", state="S")
        self.host.parents[11] = (12, "engine")
        self.assertEqual(self.admit(launcher_pid=12).launch.kind, "native")
        self.assertEqual(self.engine.observe_one(claim.intent_id).outcome, "waiting")

    def test_dead_obligation_is_completed_before_alias_is_reread(self):
        old = self.admit()
        self.host.processes[10] = recovery.ProcessObservation("alive", "new-launcher", state="S")
        def cleanup(seconds):
            self.assertEqual(self.engine.observe_one(old.intent_id).outcome, "settled")
            self.host.advance(seconds)
        self.host.sleep = cleanup
        result = self.admit()
        self.assertEqual(result.launch.route, "claimed")
        self.assertNotEqual(result.intent_id, old.intent_id)

    def test_alias_changed_during_cleanup_is_not_borrowed(self):
        self.independent_alias()
        self.server.schedule("agent.get", lambda method, params: self.server.schedule(
            "agent.get", lambda method, params: self.server.apply(
                "agent.rename", {"target": "w1:p1", "name": "silver-ibis"})), after=True)
        self.assertEqual(self.admit().launch.kind, "native")

    def test_used_pane_claude_records_deferred_rename_without_a_claim(self):
        for prior in ("claude", "opencode", "pi"):
            with self.subTest(prior=prior):
                self.server.panes["w1:p1"]["agent_session"] = {"agent": prior}
                result = self.admit()
                self.assertEqual(result, recovery.Admission(recovery.Launch("enrolled", "deferred_rename", "ochre-okapi")))
                self.assertTrue((Path(self.root.name) / "reconcile/w1_p1").is_file())
                self.assertEqual((Path(self.root.name) / "reconcile/w1_p1").read_text(), "ochre-okapi\n")
        for client in ("opencode", "pi"):
            self.assertEqual(self.admit(agent=client), recovery.Admission(recovery.Launch("native", reason_code="used_pane")))

    def test_failed_reconciliation_write_keeps_native_startup(self):
        self.server.panes["w1:p1"]["agent_session"] = {"agent": "pi"}
        (Path(self.root.name) / "reconcile").write_text("not a directory")
        self.assertEqual(self.admit().launch.kind, "native")

    def test_unavailable_owner_and_replaced_server_acquire_nothing(self):
        def unavailable(root):
            raise recovery.RecoveryError("owner absent")
        self.host.ensure_owner = unavailable
        self.assertEqual(self.admit().launch.kind, "native")
        self.host.ensure_owner = lambda root: self.server.replace()
        self.assertEqual(self.admit().launch.kind, "native")
        self.assertEqual(self.server.records, {})

    def test_launcher_identity_change_before_claim_refuses_enrollment(self):
        self.host.ensure_owner = lambda root: self.host.processes.update(
            {10: recovery.ProcessObservation("alive", "reused-pid", state="S")})
        self.assertEqual(self.admit().launch.kind, "native")
        self.assertEqual(self.server.records, {})

    def test_three_collisions_exhaust_admission_without_a_pending_obligation(self):
        self.host.alias_candidates = lambda seed: ["ochre-okapi", "silver-ibis", "violet-tern", "fourth"]
        def collide(method, params):
            self.server.apply("pane.report_agent", {"pane_id": "w1:p2", "agent": "pi",
                              "source": "native", "state": "working", "seq": len(self.server.events)})
            self.server.apply("agent.rename", {"target": "w1:p2", "name": params["name"]})
            self.server.schedule("agent.rename", collide)
        self.server.schedule("agent.rename", collide)
        result = self.admit()
        self.assertEqual(result, recovery.Admission(recovery.Launch("native", reason_code="alias_exhausted")))
        self.assertEqual([params["name"] for method, params in self.server.events if method == "agent.rename"],
                         ["ochre-okapi", "silver-ibis", "violet-tern"])

    def test_cli_emits_the_exact_reuse_record_and_zero_for_native_fallback(self):
        self.independent_alias()
        argv = ["engine", "--admit", self.engine.state_root, "--agent", "claude", "--launcher-pid", "10",
                "--socket-path", "fake.sock", "--pane-id", "w1:p1"]
        output = io.StringIO()
        with patch.object(recovery.sys, "argv", argv), contextlib.redirect_stdout(output):
            status = recovery.main(engine_factory=lambda root: self.engine)
        self.assertIsNone(status)
        self.assertEqual(output.getvalue(), "v1\tenrolled\treused\tochre-okapi\t-\tok\n")
        self.server.available = False
        output = io.StringIO()
        with patch.object(recovery.sys, "argv", argv), contextlib.redirect_stdout(output):
            status = recovery.main(engine_factory=lambda root: self.engine)
        self.assertIsNone(status)
        self.assertEqual(output.getvalue(), "v1\tnative\t-\t-\t-\tadmission_unavailable\n")


if __name__ == "__main__":
    unittest.main()
