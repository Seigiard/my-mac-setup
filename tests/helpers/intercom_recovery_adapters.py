"""Test-owned causal host and transport adapters; persistence stays real."""

import copy
import importlib.util
from pathlib import Path


ENGINE = Path(__file__).resolve().parents[2] / "home/dot_local/lib/intercom-claim-recovery.py"
spec = importlib.util.spec_from_file_location("intercom_recovery", ENGINE)
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class FakeHost(recovery.Host):
    def __init__(self):
        self.wall = 1000
        self.tick = 100
        self.current_pid = 11
        self.parents = {11: (10, "bridge"), 10: (1, "launcher")}
        self.processes = {
            10: recovery.ProcessObservation("alive", "Thu Oct 1 12:00:00 2026", state="S"),
            11: recovery.ProcessObservation("alive", "Thu Oct 1 12:00:01 2026", state="S"),
            20: recovery.ProcessObservation("alive", "Thu Oct 1 11:00:00 2026", state="S"),
        }

    def process(self, pid):
        return self.processes.get(pid, recovery.ProcessObservation("exited", reason="process_absent"))

    def pid(self):
        return self.current_pid

    def parent_pid(self):
        return self.parent(self.current_pid)[0]

    def parent(self, pid):
        return self.parents[pid]

    def wall_time(self):
        return self.wall

    def wall_time_ns(self):
        return int(self.wall * 1_000_000_000)

    def monotonic(self):
        return self.tick

    def advance(self, seconds):
        self.wall += seconds
        self.tick += seconds

    def sleep(self, seconds):
        super().sleep(seconds)
        self.tick += seconds


class FakeHerdr:
    """Only model the shallow wire facts measured by the live calibration.

    A schedule runs immediately before or after a request. A delayed request
    captures the request, loses its response, and applies only when deliver runs.
    No source or sequence is disclosed by agent.get.
    """

    def __init__(self):
        self.identity = {"pid": 20, "start_identity": "Thu Oct 1 11:00:00 2026"}
        self.panes = {"w1:p1": {"pane_id": "w1:p1", "terminal_id": "term-1"},
                      "w1:p2": {"pane_id": "w1:p2", "terminal_id": "term-2"}}
        self.records = {}
        self.authority = {}
        self.highwater = {}
        self.events = []
        self.schedules = []
        self.delayed = []
        self.available = True
        self.undeclarable = set()

    def connect(self, socket_path):
        if not self.available:
            raise OSError("socket unavailable")
        return {"socket_path": socket_path, "server_identity": dict(self.identity)}

    def __call__(self, intent):
        server = self

        class Session(recovery.HerdrSession):
            def request(self, method, params):
                if not server.available:
                    raise OSError("socket unavailable")
                if self.intent["connection"]["server_identity"] != server.identity:
                    raise recovery.ServerInstanceChanged("server instance changed")
                return server.request(method, params)

            def replacement(self):
                return server({**self.intent, "connection": server.connect("fake.sock")})

        return Session(intent)

    def schedule(self, method, action, *, after=False):
        self.schedules.append((method, after, action))

    def request(self, method, params):
        self.events.append((method, copy.deepcopy(params)))
        for after in (False, True):
            if after:
                result = self.apply(method, params)
            for index, (scheduled, when, action) in enumerate(self.schedules):
                if scheduled == method and when == after:
                    self.schedules.pop(index)
                    action(method, copy.deepcopy(params))
                    break
        return copy.deepcopy(result)

    def lose_response(self, method, *, delayed=False):
        def lose(name, params):
            if delayed:
                self.delayed.append((name, params))
            raise OSError("response lost")
        self.schedule(method, lose, after=not delayed)

    def deliver(self):
        for method, params in self.delayed:
            self.apply(method, params)
        self.delayed.clear()

    def move(self, pane_id, destination):
        pane = self.panes.pop(pane_id)
        pane["pane_id"] = destination
        self.panes[destination] = pane
        record = self.records.get(pane["terminal_id"])
        if record:
            record["pane_id"] = destination

    def replace(self):
        self.identity = {"pid": 21, "start_identity": "Thu Oct 1 13:00:00 2026"}

    def apply(self, method, params):
        ok = {"result": {"type": "ok"}}
        pane_id = params.get("pane_id", params.get("target"))
        pane = self.panes.get(pane_id)
        if method == "session.snapshot":
            return {"result": {"snapshot": {"panes": list(self.panes.values())}}}
        if method == "agent.list":
            return {"result": {"agents": list(self.records.values())}}
        if pane is None:
            return {"error": {"code": "pane_not_found"}}
        terminal = pane["terminal_id"]
        record = self.records.get(terminal)
        if method == "pane.get":
            return {"result": {"pane": pane}}
        if method == "agent.get":
            return {"result": {"agent": record}} if record else {"error": {"code": "agent_not_found"}}
        if method == "agent.rename":
            if any(item.get("name") == params["name"] and item["terminal_id"] != terminal
                   for item in self.records.values()):
                return {"error": {"code": "agent_name_taken"}}
            if not record:
                return {"error": {"code": "agent_not_found"}}
            record["name"] = params["name"]
            return ok
        if method in ("pane.report_agent", "pane.release_agent"):
            source, sequence = params["source"], params["seq"]
            key = (terminal, source)
            if sequence <= self.highwater.get(key, -1):
                return ok
            self.highwater[key] = sequence
            if method == "pane.report_agent":
                if terminal in self.undeclarable:
                    return ok
                self.authority[terminal] = source
                self.records[terminal] = {**pane, "agent": params["agent"],
                                          "agent_status": params["state"],
                                          "name": (record or {}).get("name")}
            elif self.authority.get(terminal) == source:
                self.records.pop(terminal, None)
                self.authority.pop(terminal, None)
            return ok
        raise AssertionError(f"uncalibrated method: {method}")
