#!/usr/bin/env python3
"""The managed recovery engine with the live proofs' barriers and trace attached.

Probes import this module, run it in place of the engine, and stage it as a
runtime home's engine. The deployed engine knows nothing of these hooks. They
read a probe-owned control directory, keyed by launch ID, never intent JSON.
"""
import json
import os
from pathlib import Path
import subprocess
import threading


ENGINE = Path(__file__).resolve().parents[2] / "home/dot_local/lib/intercom-claim-recovery.py"
CONTROL_ENV = "INTERCOM_RECOVERY_PROBE_CONTROL"
TRACE_ENV = "INTERCOM_RECOVERY_PROBE_TRACE_DIR"
OWNER_ENV = "INTERCOM_RECOVERY_PROBE_OWNER"
MUTATIONS = {"pane.report_agent", "agent.rename", "pane.release_agent", "pane.clear_agent_authority"}

# Hide this entry's __main__ name until the hooks below replace engine globals.
_entry_name = __name__
__name__ = "intercom_claim_recovery_engine"
exec(compile(ENGINE.read_bytes(), str(ENGINE), "exec"), globals())
__name__ = _entry_name

_engine_bound_request = bound_request
_engine_peer_identity = peer_identity
_engine_observe_one = observe_one
_engine_observe_one_locked = _observe_one_locked
_engine_bind_native_client = _bind_native_client
_engine_atomic_write = atomic_write
_engine_write_intent = write_intent
_engine_observer = observer
_role = None
_pending_mutation = None


def control_path(launch_id, kind):
    root = os.environ.get(CONTROL_ENV)
    return os.path.join(root, f"{launch_id}.{kind}") if root and launch_id else None


def register_control(launch_id, kind, value):
    path = control_path(launch_id, kind)
    if path is None:
        raise RecoveryError(f"{CONTROL_ENV} is required to attach a probe {kind}")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    _engine_atomic_write(path, value)


def control_value(intent, kind):
    path = control_path(intent.get("launch_id"), kind)
    try:
        return read_json(path) if path else None
    except FileNotFoundError:
        return None


def trace_dir(intent):
    return control_value(intent, "trace")


def trace_event(intent, event, unique=False, **details):
    directory = trace_dir(intent)
    if directory:
        suffix = f".{uuid.uuid4().hex}" if unique else ""
        _engine_atomic_write(os.path.join(directory, f"{os.getpid()}.{event}{suffix}.json"),
                             {"pid": os.getpid(), "event": event, "at_ns": time.time_ns(),
                              "monotonic_ns": time.monotonic_ns(), **details})


def probe_barrier(path, checked, timeout=10):
    _engine_atomic_write(checked, {"pid": os.getpid(), "checked_at_ns": time.time_ns()})
    deadline = time.monotonic() + timeout
    while not os.path.exists(path + ".continue"):
        if not os.path.isdir(os.path.dirname(path)):
            raise RecoveryError("probe barrier owner directory disappeared")
        if time.monotonic() >= deadline:
            raise RecoveryError("probe barrier timed out")
        time.sleep(POLL_SECONDS)


def bound_request(intent, method, params):
    exact_release = (_role == "observe" and method == "pane.release_agent" and
                     params.get("seq") == intent.get("claim", {}).get("release_seq"))
    if exact_release:
        barrier = control_value(intent, "barrier")
        if barrier:
            probe_barrier(barrier, barrier + ".checked")
        trace_event(intent, "release_attempt", unique=True, target=params["pane_id"],
                    source=params["source"], seq=params["seq"])
    global _pending_mutation
    _pending_mutation = (intent, method, params) if method in MUTATIONS else None
    try:
        response = _engine_bound_request(intent, method, params)
    finally:
        _pending_mutation = None
    if exact_release:
        trace_event(intent, "release_result", response=response)
    return response


def peer_identity(connection):
    global _pending_mutation
    identity = _engine_peer_identity(connection)
    # Record a mutation once the engine's peer fence will pass, before it sends.
    if _pending_mutation and identity == _pending_mutation[0]["connection"]["server_identity"]:
        intent, method, params = _pending_mutation
        _pending_mutation = None
        trace_event(intent, "mutation_attempt", unique=True, method=method, params=params)
    return identity


def observe_one(path):
    started_monotonic_ns = time.monotonic_ns()
    try:
        preview = read_json(path)
    except FileNotFoundError:
        return
    entry_barrier = control_value(preview, "entry_barrier")
    if entry_barrier:
        probe_barrier(entry_barrier, entry_barrier + f".checked.{os.getpid()}")
    trace_event(preview, "lock_attempt")
    try:
        _engine_observe_one(path)
    finally:
        trace_event(preview, "attempt_complete", started_monotonic_ns=started_monotonic_ns)


def _observe_one_locked(path):
    global _role
    started_monotonic_ns = time.monotonic_ns()
    _role = "observe"
    try:
        _engine_observe_one_locked(path)
    finally:
        _role = None
    trace_event(read_intent(path), "observe_complete", started_monotonic_ns=started_monotonic_ns)


def _bind_native_client(path):
    global _role
    _role = "bind"
    try:
        return _engine_bind_native_client(path)
    finally:
        _role = None


def atomic_write(path, value):
    # Binding writes exactly once, after its live-parent check and under the lock.
    if _role == "bind" and isinstance(value, dict) and "launcher_client" in value:
        barrier = control_value(value, "bind_barrier")
        if barrier:
            probe_barrier(barrier, barrier + ".checked")
    _engine_atomic_write(path, value)


def write_intent(intent_dir, intent):
    # A launcher-created intent joins the trace before any observer can read it.
    if os.environ.get(TRACE_ENV):
        register_control(intent["launch_id"], "trace", os.environ[TRACE_ENV])
    return _engine_write_intent(intent_dir, intent)


def observer(intent_dir, pid_file, job_label=None):
    owner = os.environ.get(OWNER_ENV)
    if owner:
        threading.Thread(target=_watch_probe_owner, args=(json.loads(owner), intent_dir, job_label),
                         daemon=True).start()
    _engine_observer(intent_dir, pid_file, job_label)


def _watch_probe_owner(owner, intent_dir, job_label):
    """Retire a proof job whose controlling probe or scratch tree disappeared."""
    while os.path.isdir(intent_dir):
        try:
            if process_start_identity(owner["pid"]) != owner["start_identity"]:
                break
        except RecoveryError as error:
            print(f"probe owner observation pending: {error}", file=sys.stderr, flush=True)
        time.sleep(POLL_SECONDS)
    if job_label:
        try:
            result = subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{job_label}"],
                                    text=True, capture_output=True, check=False, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            result = None
        if result is None or result.returncode:
            # A failed exit makes launchd restart the observer, which retries the bootout.
            os._exit(1)
    os._exit(0)


if __name__ == "__main__":
    cli()
