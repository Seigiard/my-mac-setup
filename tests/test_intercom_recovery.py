"""Recovery decisions exercised through the same operations as CLI callers."""

import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest import mock

from helpers.intercom_recovery_adapters import FakeHerdr, FakeHost, recovery


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.host = FakeHost()
        self.host.ensure_owner = lambda root: True
        self.server = FakeHerdr()
        self.engine = recovery.RecoveryEngine(self.root.name, host=self.host, sessions=self.server)

    def acquire(self, pane="w1:p1", alias="first"):
        self.host.alias_candidates = lambda seed: [alias]
        result = self.engine.admit(socket_path="fake.sock", pane_id=pane, agent="claude", launcher_pid=10)
        return {"claimed": result.launch.kind == "enrolled", "intent_id": result.intent_id}

    def observe(self, claim):
        return self.engine.observe_one(claim["intent_id"])

    def exit(self):
        self.host.processes.pop(10)

    def state(self, pane="w1:p1"):
        return self.server.request("agent.get", {"target": pane})

    def test_acquisition_alive_stopped_unknown_and_confirmed_exit(self):
        # given a successfully acquired claim, not a hand-built intent
        claim = self.acquire()
        self.assertEqual(claim["claimed"], True)
        self.assertEqual(self.state()["result"]["agent"]["name"], "first")
        # when live, stopped, and unknown evidence are observed
        for evidence, reason in ((recovery.ProcessObservation("alive", "Thu Oct 1 12:00:00 2026", state="S"), "client_alive"),
                                 (recovery.ProcessObservation("alive", "Thu Oct 1 12:00:00 2026", state="T"), "client_alive"),
                                 (recovery.ProcessObservation("unknown", reason="lookup_failed"), "client_identity_unknown")):
            self.host.processes[10] = evidence
            result = self.observe(claim)
            self.assertEqual((result.phase, result.outcome, result.reason_code), ("acquired", "waiting", reason))
            self.assertEqual(self.state()["result"]["agent"]["name"], "first")
        # then only confirmed exit releases the claim
        self.exit()
        self.assertEqual(self.observe(claim).outcome, "settled")
        self.assertEqual(self.state(), {"error": {"code": "agent_not_found"}})
        self.assertEqual(self.observe(claim).outcome, "settled")

    def test_concrete_successor_retires_without_release(self):
        claim = self.acquire()
        self.server.request("pane.report_agent", {"pane_id": "w1:p1", "source": "native",
                            "agent": "claude", "state": "working", "seq": 1})
        self.exit()
        self.server.events.clear()
        self.assertEqual(self.observe(claim).outcome, "retired")
        self.assertEqual([method for method, _ in self.server.events if method == "pane.release_agent"], [])
        self.assertEqual(self.state()["result"]["agent"]["agent_status"], "working")

    def test_unknown_newer_owner_survives_successful_ineffective_release(self):
        claim = self.acquire()
        def successor(method, params):
            self.server.apply("pane.report_agent", {**params, "state": "unknown", "seq": params["seq"] + 1})
        self.server.schedule("pane.release_agent", successor)
        self.exit()
        result = self.observe(claim)
        self.assertEqual((result.phase, result.outcome, result.reason_code, result.deadline_clock),
                         ("acquired", "waiting", "release_still_published", "wall"))
        self.assertEqual(self.state()["result"]["agent"]["name"], "first")

    def test_lost_response_and_delayed_application_keep_responsibility(self):
        self.server.lose_response("pane.report_agent", delayed=True)
        claim = self.acquire()
        self.assertEqual(claim["claimed"], False)
        self.exit()
        self.assertEqual(self.observe(claim).reason_code, "acquisition_unknown")
        self.server.deliver()
        self.assertEqual(self.observe(claim).outcome, "settled")
        self.assertEqual(self.state(), {"error": {"code": "agent_not_found"}})

    def test_restart_after_release_before_readback(self):
        claim = self.acquire()
        self.exit()
        self.server.lose_response("pane.release_agent")
        self.assertEqual(self.observe(claim).outcome, "waiting")
        self.engine = recovery.RecoveryEngine(self.root.name, host=self.host, sessions=self.server)
        self.assertEqual(self.observe(claim).outcome, "settled")

    def test_replacement_server_retained_record_is_read_only(self):
        claim = self.acquire()
        self.exit()
        self.host.processes.pop(20)
        self.server.replace()
        self.server.events.clear()
        self.assertEqual(self.observe(claim).reason_code, "replacement_ownership_unknown")
        self.assertEqual([name for name, _ in self.server.events if name == "pane.release_agent"], [])
        self.server.records.clear()
        self.assertEqual(self.observe(claim).outcome, "retired")

    def test_relocated_terminal_is_released_at_new_address(self):
        claim = self.acquire()
        self.server.move("w1:p1", "w2:p1")
        self.exit()
        self.assertEqual(self.observe(claim).outcome, "settled")
        self.assertEqual(self.state("w2:p1"), {"error": {"code": "agent_not_found"}})

    def test_bound_native_outlives_launcher_and_late_binding_cannot_revive(self):
        claim = self.acquire()
        self.host.parents[11] = (1, "bridge")
        self.assertEqual(self.engine.bind(claim["intent_id"], "/bin/native"), False)
        self.host.parents[11] = (10, "bridge")
        self.assertEqual(self.engine.bind(claim["intent_id"], "/bin/native"), True)
        self.exit()
        self.assertEqual(self.observe(claim).reason_code, "client_alive")
        self.host.processes.pop(11)
        self.assertEqual(self.observe(claim).outcome, "settled")
        self.assertEqual(self.engine.bind(claim["intent_id"], "/bin/native"), False)

    def test_binding_and_cleanup_serialize_on_the_real_lock(self):
        # given a native bridge paused after checking its live launcher
        claim = self.acquire()
        checked, proceed = threading.Event(), threading.Event()
        original = self.host.start_identity
        def observe_process(pid):
            result = original(pid)
            if pid == 11:
                checked.set()
                if not proceed.wait(3):
                    raise AssertionError("binding barrier timed out")
            return result
        self.host.start_identity = observe_process
        results = []
        def bind():
            try:
                results.append(self.engine.bind(claim["intent_id"], "/bin/native"))
            except Exception as error:
                results.append(error)
        thread = threading.Thread(target=bind)
        thread.start()
        try:
            self.assertTrue(checked.wait(3), "binding never reached live-parent check")
            # when the launcher exits while binding owns the real filesystem lock
            self.exit()
            observed = self.observe(claim)
            self.assertEqual((observed.phase, observed.outcome), (None, "busy"))
        finally:
            proceed.set()
            thread.join(4)
        # then binding finishes and observation follows the native incarnation
        self.assertFalse(thread.is_alive())
        self.assertEqual(results, [True])
        self.assertEqual(self.observe(claim).reason_code, "client_alive")

    def test_authorized_handoff_retries_after_outage_on_monotonic_clock(self):
        claim = self.acquire()
        self.assertEqual(self.engine.bind(claim["intent_id"], "/bin/native"), True)
        self.server.available = False
        result = self.engine.handoff(claim["intent_id"])
        self.assertEqual((result.outcome, result.deadline_clock, result.next_attempt_deadline),
                         ("waiting", "monotonic", 102))
        self.server.available = True
        self.host.wall -= 100
        self.host.tick += 3
        self.assertEqual(self.observe(claim).reason_code, "handoff_awaiting_state")
        self.assertEqual(self.state(), {"error": {"code": "agent_not_found"}})

    def test_handoff_requires_native_ancestry(self):
        # given a bound native client and a foreign hook process
        claim = self.acquire()
        self.assertEqual(self.engine.bind(claim["intent_id"], "/bin/native"), True)
        self.host.current_pid = 12
        self.host.processes[12] = recovery.ProcessObservation("alive", "Thu Oct 1 12:00:02 2026", state="S")
        self.host.parents[12] = (1, "hook")
        # when the unrelated caller requests handoff
        with self.assertRaises(recovery.RecoveryError):
            self.engine.handoff(claim["intent_id"])
        self.host.parents[12] = (11, "/bin/native")
        with self.assertRaises(recovery.RecoveryError):
            self.engine.handoff(claim["intent_id"])
        # then its refusal preserves the claim; a real descendant may release it
        self.assertEqual(self.state()["result"]["agent"]["name"], "first")
        self.host.parents[12] = (11, "hook")
        self.assertEqual(self.engine.handoff(claim["intent_id"]).reason_code, "handoff_awaiting_state")
        self.assertEqual(self.state(), {"error": {"code": "agent_not_found"}})

    def test_mismatched_alias_readback_does_not_authorize_enrollment(self):
        # given a rename racing this acquisition's readback
        self.server.schedule("agent.rename", lambda method, params: self.server.apply(
            method, {**params, "name": "changed"}), after=True)
        # when the engine checks its requested alias
        claim = self.acquire()
        # then it retains responsibility without authorizing enrollment
        self.assertEqual(claim["claimed"], False)
        self.assertEqual(self.observe(claim).phase, "intent")
        self.assertEqual(self.acquire("w1:p2", "control")["claimed"], True)

    def test_sequence_reservations_survive_wall_clock_rollback(self):
        first = self.acquire()
        self.exit()
        self.assertEqual(self.observe(first).outcome, "settled")
        self.host.processes[10] = recovery.ProcessObservation("alive", "Thu Oct 1 12:00:03 2026", state="S")
        self.host.wall -= 100
        second = self.acquire()
        self.assertEqual(second["claimed"], True)
        reports = [params["seq"] for method, params in self.server.events if method == "pane.report_agent"]
        releases = [params["seq"] for method, params in self.server.events if method == "pane.release_agent"]
        self.assertGreater(reports[1], releases[0])

    def test_concurrent_acquisitions_reserve_disjoint_operations(self):
        # given a first allocator paused after reading the previous high-water mark
        first_read, release_first, second_attempt = threading.Event(), threading.Event(), threading.Event()
        host = FakeHost()
        host.ensure_owner = lambda root: True
        host.alias_candidates = lambda seed: ["first"]
        clock = host.wall_time_ns
        clock_reads = 0
        def first_clock():
            nonlocal clock_reads
            clock_reads += 1
            if clock_reads == 1:
                return clock()  # Admission's alias seed precedes reservation.
            first_read.set()
            if not release_first.wait(3):
                raise AssertionError("first reservation did not resume")
            return clock()
        host.wall_time_ns = first_clock
        first_engine = recovery.RecoveryEngine(self.root.name, host=host, sessions=self.server)
        flock = recovery.fcntl.flock
        def observed_flock(*args):
            try:
                return flock(*args)
            except BlockingIOError:
                second_attempt.set()
                raise
        with mock.patch.object(recovery.fcntl, "flock", observed_flock), ThreadPoolExecutor(2) as workers:
            first = workers.submit(first_engine.admit, socket_path="fake.sock", pane_id="w1:p1",
                                   agent="claude", launcher_pid=10)
            try:
                self.assertTrue(first_read.wait(3), "first acquisition did not reach sequence reservation")
                second = workers.submit(self.acquire, "w1:p2", "second")
                # A broken lock permits completion; a real lock reports contention.
                # Either event releases the first writer, with one final assertion.
                second.add_done_callback(lambda _: second_attempt.set())
                self.assertTrue(second_attempt.wait(3), "second acquisition never reached the shared sequence store")
            finally:
                release_first.set()
            results = [first.result(timeout=4), second.result(timeout=4)]
        # then distinct launch obligations never reserve the same operation number
        self.assertEqual((results[0].launch.route, results[1]["claimed"]), ("claimed", True))
        claims = [params["seq"] for method, params in self.server.events if method == "pane.report_agent"]
        numbers = [number + offset for number in claims for offset in (0, 1, 2)]
        self.assertEqual(len(set(numbers)), 6)


if __name__ == "__main__":
    unittest.main()
