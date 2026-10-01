#!/usr/bin/env python3
"""Live-probe adapters around supported recovery operations.

Scheduling and trace files belong to the probe, not the deployed protocol.
The CLI and these operations execute the same RecoveryEngine implementation.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import uuid

from intercom_recovery_adapters import recovery

CONTROL_ENV = "INTERCOM_RECOVERY_PROBE_CONTROL"
TRACE_ENV = "INTERCOM_RECOVERY_PROBE_TRACE_DIR"
OWNER_ENV = "INTERCOM_RECOVERY_PROBE_OWNER"
RecoveryError = recovery.RecoveryError
MUTATIONS = {"pane.report_agent", "agent.rename", "pane.release_agent", "pane.clear_agent_authority"}


def atomic_write(path, value):
    temporary = str(path) + "." + uuid.uuid4().hex
    with open(temporary, "w", encoding="utf-8") as stream:
        json.dump(value, stream)
    os.replace(temporary, path)


def read_json(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def read_intent(path):
    try:
        return read_json(path)
    except FileNotFoundError:
        return read_json(Path(path).parent / "archive" / Path(path).name)


def intent_handles(directory):
    root = Path(directory)
    return sorted(str(root / item.name) for item in list(root.glob("*.json")) + list((root / "archive").glob("*.json")))


def process_start_identity(pid):
    return recovery.Host().start_identity(pid)


def capture_server_identity(path):
    return recovery.HerdrSession.connect(path)["server_identity"]


def bound_request(scope, method, params):
    return recovery.HerdrSession(scope).request(method, params)


def probe_sequence():
    """Sequence for probe-owned external reports, never engine allocator proof."""
    return time.time_ns()


def register_control(launch_id, kind, value):
    root = os.environ[CONTROL_ENV]
    os.makedirs(root, exist_ok=True)
    atomic_write(os.path.join(root, f"{launch_id}.{kind}"), value)


def observation_receipt(intent_id):
    os.makedirs(os.environ[CONTROL_ENV], exist_ok=True)
    return os.path.join(os.environ[CONTROL_ENV], intent_id + ".observation.json")


def passive_observation(path):
    try:
        receipt = read_json(observation_receipt(Path(path).stem))
        return recovery.Observation(**receipt["observation"])
    except FileNotFoundError:
        return None


def control_value(intent, kind):
    root = os.environ.get(CONTROL_ENV)
    if not root:
        return None
    try:
        return read_json(os.path.join(root, f"{intent['launch_id']}.{kind}"))
    except FileNotFoundError:
        return None


def trace_dir(intent):
    return control_value(intent, "trace")


def trace_event(intent, event, unique=False, **details):
    directory = trace_dir(intent)
    if directory:
        suffix = "." + uuid.uuid4().hex if unique else ""
        atomic_write(os.path.join(directory, f"{os.getpid()}.{event}{suffix}.json"),
                     {"pid": os.getpid(), "event": event, "at_ns": time.time_ns(),
                      "monotonic_ns": time.monotonic_ns(), **details})


def barrier(path, checked):
    atomic_write(checked, {"pid": os.getpid(), "checked_at_ns": time.time_ns()})
    deadline = time.monotonic() + 10
    while not os.path.exists(path + ".continue"):
        if time.monotonic() >= deadline or not os.path.isdir(os.path.dirname(path)):
            raise RecoveryError("probe barrier timed out or owner disappeared")
        time.sleep(.05)


class ProbeHost(recovery.Host):
    binding = None

    def start_identity(self, pid):
        identity = super().start_identity(pid)
        if self.binding is not None and pid == os.getpid():
            gate = control_value(self.binding, "bind_barrier")
            if gate:
                barrier(gate, gate + ".checked")
        return identity


class ProbeSession(recovery.HerdrSession):
    def request(self, method, params):
        intent = self.intent
        if "launch_id" in intent and os.environ.get(TRACE_ENV):
            register_control(intent["launch_id"], "trace", os.environ[TRACE_ENV])
        release = method == "pane.release_agent" and params["seq"] == intent.get("claim", {}).get("release_seq")
        if release:
            gate = control_value(intent, "barrier")
            if gate:
                barrier(gate, gate + ".checked")
            trace_event(intent, "release_attempt", unique=True, target=params["pane_id"],
                        source=params["source"], seq=params["seq"])
        response = super().request(method, params)
        if method in MUTATIONS:
            trace_event(intent, "mutation_attempt", unique=True, method=method, params=params)
        if release:
            trace_event(intent, "release_result", response=response)
        return response


class ProbeEngine(recovery.RecoveryEngine):
    def __init__(self, root, **kwargs):
        super().__init__(root, host=kwargs.pop("host", ProbeHost()),
                         sessions=kwargs.pop("sessions", ProbeSession), **kwargs)

    def observe_one(self, intent_id):
        path = Path(self.intent_dir) / (intent_id + ".json")
        try:
            intent = read_intent(path)
        except FileNotFoundError:
            return super().observe_one(intent_id)
        gate = control_value(intent, "entry_barrier")
        if gate:
            barrier(gate, gate + f".checked.{os.getpid()}")
        started = time.monotonic_ns()
        trace_event(intent, "lock_attempt")
        result = super().observe_one(intent_id)
        if os.environ.get(CONTROL_ENV) and result.outcome != "busy":
            atomic_write(observation_receipt(intent_id),
                         {"pid": os.getpid(), "observation": result._asdict()})
        trace_event(intent, "attempt_complete", started_monotonic_ns=started)
        if result.outcome != "busy":
            trace_event(intent, "observe_complete", started_monotonic_ns=started)
        return result

    def bind(self, intent_id, native_executable):
        try:
            self.host.binding = read_intent(Path(self.intent_dir) / (intent_id + ".json"))
        except FileNotFoundError:
            pass
        try:
            return super().bind(intent_id, native_executable)
        finally:
            self.host.binding = None


def engine_for(path):
    engine = ProbeEngine(Path(path).parent.parent)
    engine.intent_dir = str(Path(path).parent)
    return engine


def observe_one(path):
    return engine_for(path).observe_one(Path(path).stem)


def bind_native_client(path):
    return engine_for(path).bind(Path(path).stem, os.environ.get("AGENT_INTERCOM_CLAUDE_COMMAND"))


def request_handoff(path):
    return engine_for(path).handoff(Path(path).stem)


def launchd_job(domain, label):
    result = subprocess.run(["launchctl", "print", f"{domain}/{label}"],
                            text=True, capture_output=True, timeout=10)
    if result.returncode:
        if any(text in result.stderr for text in ("Could not find service", "No such process")):
            return None
        raise RecoveryError(result.stderr)
    return {"present": True}


def watch_owner(owner, label, directory):
    while os.path.isdir(directory):
        try:
            if process_start_identity(owner["pid"]) != owner["start_identity"]:
                break
        except RecoveryError as error:
            print(f"probe owner observation pending: {error}", file=sys.stderr, flush=True)
        time.sleep(.1)
    try:
        result = subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{label}"],
                                capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        result = None
    # Failure asks launchd to restart the observer and retry its owned bootout.
    os._exit(0 if result is not None and result.returncode == 0 else 1)


if __name__ == "__main__":
    if os.environ.get(OWNER_ENV) and "--job-label" in sys.argv:
        label = sys.argv[sys.argv.index("--job-label") + 1]
        directory = sys.argv[sys.argv.index("--observe") + 1]
        threading.Thread(target=watch_owner, args=(json.loads(os.environ[OWNER_ENV]), label, directory), daemon=True).start()
    recovery.main(engine_factory=ProbeEngine)
