#!/usr/bin/env python3
"""Narrow, opt-in launchd-owned recovery observer for the ownership proof.

This is deliberately not launcher code.  It owns only durable claim-cleanup
intents created by the live Herdr proof and has no client-supervision policy.
"""

import argparse
from contextlib import contextmanager
import fcntl
import json
import os
import plistlib
import signal
import socket
import struct
import subprocess
import sys
import time
import uuid


POLL_SECONDS = 0.10
PENDING_RETRY_SECONDS = 2.0


class RecoveryError(Exception):
    pass


class ServerInstanceChanged(RecoveryError):
    pass


class IntentBusy(RecoveryError):
    pass


@contextmanager
def intent_lock(path, timeout=0):
    """The sidecar stays at one inode while JSON records are replaced atomically."""
    with open(str(path) + ".lock", "a", encoding="utf-8") as handle:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError as error:
                if time.monotonic() >= deadline:
                    raise IntentBusy("intent update is in progress") from error
                time.sleep(POLL_SECONDS)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def atomic_write(path, value):
    directory = os.path.dirname(path)
    temporary = f"{path}.{os.getpid()}.{uuid.uuid4().hex}.tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    directory_fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def read_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def process_start_identity(pid):
    if not isinstance(pid, int) or pid <= 0:
        raise RecoveryError("invalid process identity")
    try:
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "lstart=", "-o", "stat="],
            text=True, capture_output=True, check=False, timeout=2,
            env={**os.environ, "LC_ALL": "C", "TZ": "UTC"},
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RecoveryError(f"process lookup unavailable: {error}") from error
    row = result.stdout.strip()
    if result.returncode == 0 and row:
        identity, status = row.rsplit(None, 1)
        return None if status.startswith("Z") else identity
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    except OSError as error:
        raise RecoveryError(f"process liveness unknown: {error}") from error
    raise RecoveryError("process lookup failed for a live process")


def peer_identity(connection):
    if sys.platform == "darwin":
        # LOCAL_PEERPID identifies the server attached to this connected descriptor.
        pid = struct.unpack("i", connection.getsockopt(0, 2, 4))[0]
    elif hasattr(socket, "SO_PEERCRED"):
        pid, _, _ = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    else:
        raise RecoveryError("connected-server identity is unavailable on this platform")
    start = process_start_identity(pid)
    if start is None:
        raise RecoveryError("connected server exited")
    return {"pid": pid, "start_identity": start}


def capture_server_identity(path):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(path)
        return peer_identity(connection)


def bound_request(intent, method, params):
    # Herdr closes each connection after one response. Validate the actual peer
    # on the descriptor used for the mutation; never reconnect after this check.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(intent["connection"]["socket_path"])
        if peer_identity(connection) != intent["connection"]["server_identity"]:
            raise ServerInstanceChanged("server instance changed")
        if method in {"pane.report_agent", "agent.rename", "pane.release_agent", "pane.clear_agent_authority"}:
            trace_event(intent, "mutation_attempt", unique=True, method=method, params=params)
        request = {"id": uuid.uuid4().hex, "method": method, "params": params}
        connection.sendall((json.dumps(request) + "\n").encode())
        with connection.makefile("rb") as stream:
            line = stream.readline(1024 * 1024)
        if not line.endswith(b"\n"):
            raise RecoveryError("incomplete server response")
        response = json.loads(line)
        if response.get("id") != request["id"]:
            raise RecoveryError("server response identity mismatch")
        return response


def socket_identity(path):
    stat = os.stat(path)
    return {"device": stat.st_dev, "inode": stat.st_ino}


def write_intent(intent_dir, intent):
    """Durably record an unresolved obligation before the caller claims Herdr."""
    try:
        os.mkdir(intent_dir)
    except FileExistsError:
        pass
    path = os.path.join(intent_dir, f"{intent['launch_id']}.json")
    atomic_write(path, intent)
    return path


def reserve_sequence(directory, source):
    """Persistently reserve claim, handoff and release sequence numbers per source."""
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, f"{source}.sequence.json")
    with intent_lock(path, timeout=5):
        try:
            previous = read_json(path)["last"]
        except FileNotFoundError:
            previous = -1
        candidate = max(time.time_ns(), previous + 3)
        atomic_write(path, {"last": candidate + 2, "reserved_at_ns": time.time_ns()})
        return candidate


def acknowledge_acquisition(intent_path):
    with intent_lock(intent_path, timeout=5):
        intent = read_json(intent_path)
        if intent["phase"] != "intent":
            raise RecoveryError(f"cannot acknowledge phase {intent['phase']!r}")
        intent["phase"] = "acquired"
        intent["acquired_at_ns"] = time.time_ns()
        atomic_write(intent_path, intent)


def bind_native_client(path):
    """Bind in the bridge's PID before exec, or refuse enrollment after cleanup."""
    with intent_lock(path, timeout=5):
        intent = read_json(path)
        if intent["phase"] not in {"intent", "acquired"} or "launcher_client" in intent:
            return False
        launcher = intent["client"]
        if os.getppid() != launcher["pid"]:
            return False
        if process_start_identity(launcher["pid"]) != launcher["start_identity"]:
            return False
        start = process_start_identity(os.getpid())
        if start is None:
            raise RecoveryError("native bridge process identity is unavailable")
        if intent.get("bind_barrier"):
            barrier = intent["bind_barrier"]
            probe_barrier(barrier, barrier + ".checked")
        intent["launcher_client"] = launcher
        intent["client"] = {"pid": os.getpid(), "start_identity": start}
        intent["native_executable"] = os.environ.get("AGENT_INTERCOM_CLAUDE_COMMAND")
        atomic_write(path, intent)
        return True


def require_client_ancestor(intent):
    """A first-prompt hook must descend from this native client, not a nested one."""
    expected = intent["client"]
    image = intent.get("native_executable")
    if not image:
        raise RecoveryError("handoff intent has no bound native client")
    if process_start_identity(expected["pid"]) != expected["start_identity"]:
        raise RecoveryError("handoff native process identity is unavailable")
    pid = os.getpid()
    for _ in range(64):
        if pid == expected["pid"]:
            return
        result = subprocess.run(["ps", "-p", str(pid), "-o", "ppid=,comm="],
                                text=True, capture_output=True, check=False, timeout=2)
        if result.returncode or not result.stdout.strip():
            break
        parent, command = result.stdout.strip().split(None, 1)
        if os.path.basename(command) == os.path.basename(image):
            raise RecoveryError("nested native client cannot hand off another launch")
        pid = int(parent)
        if pid <= 1:
            break
    raise RecoveryError("handoff caller is not a descendant of the bound native client")


def request_handoff(path):
    with intent_lock(path, timeout=5):
        intent = read_json(path)
        if intent["phase"] in {"settled", "retired"}:
            return
        require_client_ancestor(intent)
        sequence = intent["claim"]["handoff_seq"]
        if not intent["claim"]["claim_seq"] < sequence < intent["claim"]["release_seq"]:
            raise RecoveryError("handoff sequence was not reserved before acquisition")
        # Authorization must survive a failed first RPC and the hook's exit.
        intent["handoff_client"] = dict(intent["client"])
        intent.setdefault("handoff_requested_at_ns", time.time_ns())
        atomic_write(path, intent)
        attempt_handoff(path, intent)


def attempt_handoff(path, intent):
    """Retry an authorized request while holding its per-intent lock."""
    # Callers require the same live client incarnation. A reboot ends it;
    # ordinary observer restarts share this boot's monotonic clock with the hook.
    if intent.get("handoff_acknowledged"):
        return
    if time.monotonic() < intent.get("handoff_retry_after_monotonic", 0):
        return
    intent["handoff_retry_after_monotonic"] = time.monotonic() + PENDING_RETRY_SECONDS
    atomic_write(path, intent)
    try:
        expected = intent["handoff_client"]
        if expected != intent["client"] or process_start_identity(expected["pid"]) != expected["start_identity"]:
            update_intent(path, intent, intent["phase"], "pending: authorized handoff client changed or exited")
            return
        snapshot = bound_request(intent, "session.snapshot", {})
        if "error" in snapshot:
            raise RecoveryError("handoff terminal lookup failed")
        panes = [pane for pane in snapshot["result"]["snapshot"]["panes"]
                 if pane.get("terminal_id") == intent["terminal"]["terminal_id"]]
        if len(panes) != 1:
            raise RecoveryError("handoff terminal identity is unavailable")
        sequence = intent["claim"]["handoff_seq"]
        if not intent["claim"]["claim_seq"] < sequence < intent["claim"]["release_seq"]:
            raise RecoveryError("handoff sequence was not reserved before acquisition")
        intent["terminal"]["pane_id"] = panes[0]["pane_id"]
        intent["handoff_intended_at_ns"] = time.time_ns()
        atomic_write(path, intent)
        response = bound_request(intent, "pane.release_agent", {
            "pane_id": panes[0]["pane_id"], "source": intent["claim"]["source"],
            "agent": intent["agent_kind"], "seq": sequence,
        })
        if "error" in response:
            raise RecoveryError(f"handoff failed: {response['error']}")
        intent["handoff_acknowledged"] = True
        atomic_write(path, intent)
        # An ignored release also succeeds. Only the observer's later concrete
        # state read retires this obligation; the hook does not rename anything.
        update_intent(path, intent, intent["phase"], "pending: handoff awaiting published state")
    except (OSError, RecoveryError) as error:
        record_connection_failure(path, intent, error)


def update_intent(intent_path, intent, phase, diagnostic=None):
    if intent["phase"] == phase and diagnostic == intent.get("diagnostic"):
        return
    intent["phase"] = phase
    intent["updated_at_ns"] = time.time_ns()
    if diagnostic:
        intent["diagnostic"] = diagnostic
    atomic_write(intent_path, intent)


def record_connection_failure(path, intent, error):
    if isinstance(error, ServerInstanceChanged):
        previous = intent["connection"]["server_identity"]
        try:
            old_start = process_start_identity(previous["pid"])
        except RecoveryError:
            old_start = previous["start_identity"]
        if old_start != previous["start_identity"]:
            # A new server may restore terminal records. Read it through a new
            # peer fence, but never mutate it using the previous server's claim.
            try:
                replacement = {**intent, "connection": {**intent["connection"],
                    "server_identity": capture_server_identity(intent["connection"]["socket_path"])}}
                snapshot = bound_request(replacement, "session.snapshot", {})
                if "error" in snapshot:
                    raise RecoveryError("replacement server snapshot unavailable")
                matches = [pane for pane in snapshot["result"]["snapshot"]["panes"]
                           if pane.get("terminal_id") == intent["terminal"]["terminal_id"]]
                if not matches:
                    update_intent(path, intent, "retired", "retired: original terminal absent on replacement server")
                    return
                if len(matches) != 1:
                    raise RecoveryError("replacement terminal identity is ambiguous")
                state = bound_request(replacement, "agent.get", {"target": matches[0]["pane_id"]})
                if state.get("error", {}).get("code") == "agent_not_found":
                    update_intent(path, intent, "retired", "retired: original claim absent on replacement server")
                    return
                raise RecoveryError("replacement server retains a record; old ownership cannot be established")
            except (OSError, RecoveryError) as replacement_error:
                update_intent(path, intent, intent["phase"], f"pending: {replacement_error}")
            return
    update_intent(path, intent, intent["phase"], f"pending: {error}")


def trace_event(intent, event, unique=False, **details):
    directory = intent.get("trace_dir")
    if directory:
        suffix = f".{uuid.uuid4().hex}" if unique else ""
        atomic_write(os.path.join(directory, f"{os.getpid()}.{event}{suffix}.json"),
                     {"pid": os.getpid(), "event": event, "at_ns": time.time_ns(),
                      "monotonic_ns": time.monotonic_ns(), **details})


def probe_barrier(path, checked, timeout=10):
    atomic_write(checked, {"pid": os.getpid(), "checked_at_ns": time.time_ns()})
    deadline = time.monotonic() + timeout
    while not os.path.exists(path + ".continue"):
        if not os.path.isdir(os.path.dirname(path)):
            raise RecoveryError("probe barrier owner directory disappeared")
        if time.monotonic() >= deadline:
            raise RecoveryError("probe barrier timed out")
        time.sleep(POLL_SECONDS)


def observe_one(path):
    started_monotonic_ns = time.monotonic_ns()
    preview = read_json(path)
    if preview["phase"] in {"settled", "retired"}:
        return
    entry_barrier = preview.get("entry_barrier")
    if entry_barrier:
        probe_barrier(entry_barrier, entry_barrier + f".checked.{os.getpid()}")
    trace_event(preview, "lock_attempt")
    try:
        with intent_lock(path):
            trace_event(preview, "lock_acquired")
            _observe_one_locked(path)
            trace_event(preview, "observe_complete", started_monotonic_ns=started_monotonic_ns)
    except IntentBusy:
        return
    finally:
        trace_event(preview, "attempt_complete", started_monotonic_ns=started_monotonic_ns)


def _observe_one_locked(path):
    intent = read_json(path)
    if intent["phase"] in {"settled", "retired"}:
        return
    pid = intent["client"]["pid"]
    expected_start = intent["client"]["start_identity"]
    try:
        actual_start = process_start_identity(pid)
    except RecoveryError as error:
        update_intent(path, intent, intent["phase"], f"pending: {error}")
        return
    client_alive = actual_start == expected_start
    try:
        # Availability only. The connected peer, not this path's inode, fences RPCs.
        os.stat(intent["connection"]["socket_path"])
    except OSError as error:
        update_intent(path, intent, intent["phase"], f"pending: socket unavailable: {error.strerror}")
        return
    pane_id = intent["terminal"]["pane_id"]
    try:
        pane = bound_request(intent, "pane.get", {"pane_id": pane_id})
    except (OSError, RecoveryError) as error:
        record_connection_failure(path, intent, error)
        return
    if "error" in pane and pane["error"].get("code") != "pane_not_found":
        update_intent(path, intent, intent["phase"], f"pending: pane lookup failed: {pane['error']}")
        return
    observed_terminal = pane.get("result", {}).get("pane", {}).get("terminal_id")
    if observed_terminal != intent["terminal"]["terminal_id"]:
        try:
            snapshot = bound_request(intent, "session.snapshot", {})
        except (OSError, RecoveryError) as error:
            record_connection_failure(path, intent, error)
            return
        if "error" in snapshot:
            update_intent(path, intent, intent["phase"], f"pending: terminal lookup failed: {snapshot['error']}")
            return
        matches = [item for item in snapshot["result"]["snapshot"]["panes"]
                   if item.get("terminal_id") == intent["terminal"]["terminal_id"]]
        if not matches:
            update_intent(path, intent, "settled", "settled: terminal resource gone")
            return
        if len(matches) != 1:
            update_intent(path, intent, intent["phase"], "pending: ambiguous terminal identity")
            return
        pane_id = matches[0]["pane_id"]
        intent["terminal"]["pane_id"] = pane_id
        atomic_write(path, intent)
    else:
        resolved_id = pane["result"]["pane"]["pane_id"]
        if resolved_id != pane_id:
            # Herdr can resolve an old qualified ID to the moved terminal.
            pane_id = resolved_id
            intent["terminal"]["pane_id"] = resolved_id
            atomic_write(path, intent)
    try:
        acquisition = bound_request(intent, "agent.get", {"target": pane_id})
    except (OSError, RecoveryError) as error:
        record_connection_failure(path, intent, error)
        return
    if intent["phase"] == "acquired" and "error" not in acquisition:
        state = acquisition["result"]["agent"].get("agent_status")
        # This launch declared only unknown. A newer same-source report or a
        # client report can publish a concrete state; neither belongs to us.
        if acquisition["result"]["agent"].get("agent") and state in {"working", "idle", "done", "blocked"}:
            update_intent(path, intent, "retired", "retired: concrete successor state observed")
            return
    if client_alive:
        if intent.get("handoff_requested_at_ns") and intent.get("handoff_client") == intent["client"]:
            attempt_handoff(path, intent)
        return
    if intent["phase"] == "intent":
        if acquisition.get("error", {}).get("code") == "agent_not_found":
            # The acquisition request may still arrive. Absence now cannot
            # settle an unacknowledged operation on a live server and pane.
            update_intent(path, intent, "intent", "pending: acquisition outcome unknown")
            return
        if "error" in acquisition:
            update_intent(path, intent, "intent", f"pending: acquisition lookup failed: {acquisition['error']}")
            return
    barrier = intent.get("barrier")
    if barrier:
        try:
            probe_barrier(barrier, barrier + ".checked")
        except RecoveryError as error:
            update_intent(path, intent, intent["phase"], f"pending: {error}")
            return
    if time.time() < intent.get("retry_after", 0):
        return
    try:
        trace_event(intent, "release_attempt", unique=True, target=pane_id,
                    source=intent["claim"]["source"], seq=intent["claim"]["release_seq"])
        release = bound_request(intent, "pane.release_agent", {
            "pane_id": pane_id, "source": intent["claim"]["source"],
            "agent": intent["agent_kind"], "seq": intent["claim"]["release_seq"],
        })
        trace_event(intent, "release_result", response=release)
    except (OSError, RecoveryError) as error:
        record_connection_failure(path, intent, error)
        return
    if "error" in release:
        update_intent(path, intent, intent["phase"], f"pending: release failed: {release['error']}")
        return
    try:
        state = bound_request(intent, "agent.get", {"target": pane_id})
    except (OSError, RecoveryError) as error:
        record_connection_failure(path, intent, error)
        return
    if "error" not in state:
        # agent.get exposes no claim source/sequence. Unknown may belong to a
        # newer launch; successful RPC status cannot prove that distinction.
        intent["retry_after"] = time.time() + PENDING_RETRY_SECONDS
        intent["updated_at_ns"] = time.time_ns()
        atomic_write(path, intent)
        update_intent(path, intent, intent["phase"], "pending: release acknowledged but claim still published")
        return
    if state["error"].get("code") != "agent_not_found":
        update_intent(path, intent, intent["phase"], f"pending: state check failed: {state['error']}")
        return
    update_intent(path, intent, "settled", "settled: exact owned release observed")


def observer(intent_dir, pid_file, probe_owner=None, job_label=None):
    if not os.path.isdir(intent_dir):
        return
    atomic_write(pid_file, {"pid": os.getpid(), "start_identity": process_start_identity(os.getpid()), "started_at_ns": time.time_ns()})
    while True:
        if probe_owner:
            try:
                if process_start_identity(probe_owner["pid"]) != probe_owner["start_identity"]:
                    break
            except RecoveryError as error:
                print(f"probe owner observation pending: {error}", file=sys.stderr, flush=True)
        try:
            entries = sorted(os.listdir(intent_dir))
        except FileNotFoundError:
            break
        for entry in entries:
            if entry.endswith(".json"):
                try:
                    observe_one(os.path.join(intent_dir, entry))
                except (OSError, ValueError, KeyError, RecoveryError) as error:
                    print(f"observer pending {entry}: {error}", file=sys.stderr, flush=True)
        time.sleep(POLL_SECONDS)
    if job_label:
        # This is a temporary proof job, not the eventual deployed service.
        # Deregister it if the controlling proof process disappeared.
        subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{job_label}"],
                       text=True, capture_output=True, check=False, timeout=10)


class LaunchdOwner:
    """A temporary per-proof launchd job. launchd is the observer restart owner."""

    def __init__(self, scratch, probe_owner=None):
        self.scratch = scratch
        self.intent_dir = os.path.join(scratch, "intents")
        self.label = f"dev.seigiard.mms377.recovery.{os.getpid()}.{uuid.uuid4().hex[:8]}"
        self.plist = os.path.join(scratch, f"{self.label}.plist")
        self.stdout = os.path.join(scratch, f"{self.label}.stdout.log")
        self.stderr = os.path.join(scratch, f"{self.label}.stderr.log")
        self.pid_file = os.path.join(scratch, f"{self.label}.pid.json")
        self.domain = f"gui/{os.getuid()}"
        self.probe_owner = probe_owner or {"pid": os.getpid(), "start_identity": process_start_identity(os.getpid())}
        os.makedirs(self.intent_dir, exist_ok=True)

    def start(self):
        payload = {
            "Label": self.label,
            "ProgramArguments": [sys.executable, os.path.abspath(__file__), "--observe", self.intent_dir, "--pid-file", self.pid_file,
                                 "--probe-owner-pid", str(self.probe_owner["pid"]), "--probe-owner-start", self.probe_owner["start_identity"],
                                 "--job-label", self.label],
            "RunAtLoad": True,
            "KeepAlive": {"SuccessfulExit": False},
            "ThrottleInterval": 1,
            "ProcessType": "Background",
            "StandardOutPath": self.stdout,
            "StandardErrorPath": self.stderr,
        }
        with open(self.plist, "wb") as handle:
            plistlib.dump(payload, handle)
        result = subprocess.run(["launchctl", "bootstrap", self.domain, self.plist], text=True, capture_output=True, check=False)
        if result.returncode:
            raise RecoveryError(f"launchd bootstrap failed: {result.stderr.strip()}")
        return self.wait_for_pid(None)

    def wait_for_pid(self, previous, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                current = read_json(self.pid_file)
            except (OSError, ValueError):
                time.sleep(POLL_SECONDS)
                continue
            if current.get("pid") != previous and process_start_identity(current.get("pid")) == current.get("start_identity"):
                return current
            time.sleep(POLL_SECONDS)
        raise RecoveryError("launchd observer did not become live")

    def kill_observer(self):
        previous = read_json(self.pid_file)
        os.kill(previous["pid"], signal.SIGKILL)
        return self.wait_for_pid(previous["pid"], timeout=10)

    def close(self):
        try:
            observed = read_json(self.pid_file)
        except FileNotFoundError:
            observed = None
        result = subprocess.run(["launchctl", "bootout", f"{self.domain}/{self.label}"], text=True, capture_output=True, check=False)
        if result.returncode and not any(text in result.stderr for text in ("No such process", "Operation now in progress", "Could not find service")):
            raise RecoveryError(f"launchd bootout failed: {result.stderr.strip()}")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            job = subprocess.run(["launchctl", "print", f"{self.domain}/{self.label}"], text=True, capture_output=True, check=False)
            absent = job.returncode != 0 and any(text in job.stderr for text in ("Could not find service", "No such process"))
            process_gone = observed is None or process_start_identity(observed["pid"]) != observed["start_identity"]
            if absent and process_gone:
                return
            time.sleep(POLL_SECONDS)
        raise RecoveryError("launchd job or observer still present after bootout")


def exec_without_enrollment(command, args, warning):
    """Preserve native startup after admission fails, without inherited authority."""
    for key in tuple(os.environ):
        if key.startswith(("HERDR_AGENT_INTERCOM_", "AGENT_INTERCOM_", "CLAUDE_INTERCOM_")):
            os.environ.pop(key)
    os.environ.pop("MMS377_INTENT", None)
    os.environ.pop("OPENCODE_INTERCOM_NAME", None)
    print(warning, file=sys.stderr, flush=True)
    os.execv(command, [command, *args])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--observe")
    parser.add_argument("--pid-file")
    parser.add_argument("--probe-owner-pid", type=int)
    parser.add_argument("--probe-owner-start")
    parser.add_argument("--job-label")
    parser.add_argument("--handoff", action="store_true")
    parser.add_argument("--bind-exec")
    parser.add_argument("bridge_args", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.handoff:
        path = os.environ.get("MMS377_INTENT")
        if path:
            request_handoff(path)
        return
    if arguments.bind_exec:
        args = arguments.bridge_args
        if args[:1] == ["--"]:
            args = args[1:]
        # cci probes its configured bridge with --version even for MCP mode.
        # That short-lived utility is not the native interactive client.
        if args == ["--version"]:
            os.execv(arguments.bind_exec, [arguments.bind_exec, *args])
        try:
            bound = bind_native_client(os.environ["MMS377_INTENT"])
        except (OSError, ValueError, KeyError, RecoveryError) as error:
            print(f"claim binding unavailable: {error}", file=sys.stderr)
            bound = False
        if bound:
            os.execv(arguments.bind_exec, [arguments.bind_exec, *args])
        # A bridge arriving after cleanup cannot resurrect the old claim. The
        # original native argv still starts, without cci's generated enrollment.
        command = os.environ.get("AGENT_INTERCOM_CLAUDE_COMMAND")
        count = os.environ.get("AGENT_INTERCOM_CLAUDE_ARGC", "")
        try:
            if not command or not os.access(command, os.X_OK) or not count.isdecimal():
                raise ValueError("invalid command or argument count")
            native_args = [os.environ[f"AGENT_INTERCOM_CLAUDE_ARG_{index}"] for index in range(int(count))]
        except (ValueError, KeyError):
            print("herdr-agent-intercom: invalid Claude bridge environment", file=sys.stderr)
            raise SystemExit(1)
        exec_without_enrollment(command, native_args,
                                "claim binding unavailable; starting native Claude without enrollment")
    if not arguments.observe or not arguments.pid_file:
        parser.error("--observe and --pid-file are required")
    probe_owner = None
    if arguments.probe_owner_pid is not None:
        if not arguments.probe_owner_start:
            parser.error("--probe-owner-start is required with --probe-owner-pid")
        probe_owner = {"pid": arguments.probe_owner_pid, "start_identity": arguments.probe_owner_start}
    observer(arguments.observe, arguments.pid_file, probe_owner, arguments.job_label)


if __name__ == "__main__":
    main()
