#!/usr/bin/env python3
"""Durable recovery observer for Intercom launch claims.

It owns only launch-claim cleanup intents. It never supervises a client.
"""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
import plistlib
import re
import signal
import socket
import struct
import subprocess
import sys
import time
import uuid


POLL_SECONDS = 0.10
PENDING_RETRY_SECONDS = 2.0
ARCHIVE_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
ARCHIVE_MAX_RECORDS = 1000
ARCHIVE_PRUNE_SECONDS = 60
TERMINAL_PHASES = {"settled", "retired"}


class RecoveryError(Exception):
    pass


class ServerInstanceChanged(RecoveryError):
    pass


class IntentBusy(RecoveryError):
    pass


@contextmanager
def intent_lock(path, timeout=0, create=False):
    """Late intent callers never recreate a removed sidecar at a new inode."""
    with open(str(path) + ".lock", "a" if create else "r+", encoding="utf-8") as handle:
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


def archived_intent_path(path):
    return os.path.join(os.path.dirname(path), "archive", os.path.basename(path))


def read_intent(path):
    """Read a stable launch handle, including its immutable terminal receipt."""
    try:
        return read_json(path)
    except FileNotFoundError:
        return read_json(archived_intent_path(path))


def active_intent_paths(directory):
    return [os.path.join(directory, entry) for entry in sorted(os.listdir(directory))
            if entry.endswith(".json")]


def intent_handles(directory):
    """Diagnostic inventory; the observer scans only active_intent_paths."""
    active = set(active_intent_paths(directory))
    archive = os.path.join(directory, "archive")
    try:
        active.update(os.path.join(directory, entry) for entry in os.listdir(archive) if entry.endswith(".json"))
    except FileNotFoundError:
        pass
    return sorted(active)


def sync_directory(directory):
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def archive_terminal_intent(path):
    """Caller holds this intent's existing lock; the archived record is immutable."""
    intent = read_json(path)
    if intent["phase"] not in TERMINAL_PHASES:
        return False
    destination = archived_intent_path(path)
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    os.replace(path, destination)
    sync_directory(os.path.dirname(destination))
    sync_directory(os.path.dirname(path))
    # Existing waiters keep the old inode. Later callers open r+, never create,
    # and all callers refuse terminal or absent records. This handle is never reused.
    os.unlink(str(path) + ".lock")
    sync_directory(os.path.dirname(path))
    return True


def prune_intent_archive(directory, now=None, max_age=ARCHIVE_MAX_AGE_SECONDS, max_records=ARCHIVE_MAX_RECORDS):
    archive = os.path.join(directory, "archive")
    try:
        entries = os.listdir(archive)
    except FileNotFoundError:
        return
    records = []
    for entry in entries:
        if not entry.endswith(".json"):
            continue
        path = os.path.join(archive, entry)
        try:
            records.append((os.stat(path).st_mtime, entry))
            # Complete a crash after the durable rename but before sidecar removal.
            if not os.path.exists(os.path.join(directory, entry)):
                try:
                    os.unlink(os.path.join(directory, entry + ".lock"))
                except FileNotFoundError:
                    pass
        except FileNotFoundError:
            continue
    cutoff = (time.time() if now is None else now) - max_age
    changed = False
    for index, (modified, entry) in enumerate(sorted(records, reverse=True)):
        if modified < cutoff or index >= max_records:
            try:
                os.unlink(os.path.join(archive, entry))
                changed = True
            except FileNotFoundError:
                pass
    if changed:
        sync_directory(archive)


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
    # A terminal handle must never be reused, even after its archive expires.
    path = os.path.join(intent_dir, f"{intent['launch_id']}-{uuid.uuid4().hex}.json")
    with open(path + ".lock", "x", encoding="utf-8"):
        pass
    try:
        atomic_write(path, intent)
    except OSError:
        if not os.path.exists(path):
            os.unlink(path + ".lock")
        raise
    return path


def reserve_sequence(directory, source):
    """Persistently reserve claim, handoff and release sequence numbers per source."""
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, f"{source}.sequence.json")
    with intent_lock(path, timeout=5, create=True):
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
    try:
        return _bind_native_client(path)
    except FileNotFoundError:
        return False


def _bind_native_client(path):
    with intent_lock(path, timeout=5):
        intent = read_intent(path)
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
    try:
        _request_handoff(path)
    except FileNotFoundError:
        return  # Archived or expired obligations no longer authorize a handoff.


def _request_handoff(path):
    with intent_lock(path, timeout=5):
        intent = read_intent(path)
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
    try:
        preview = read_json(path)
    except FileNotFoundError:
        return
    entry_barrier = preview.get("entry_barrier")
    if entry_barrier:
        probe_barrier(entry_barrier, entry_barrier + f".checked.{os.getpid()}")
    trace_event(preview, "lock_attempt")
    try:
        with intent_lock(path):
            trace_event(preview, "lock_acquired")
            _observe_one_locked(path)
            archive_terminal_intent(path)
            trace_event(preview, "observe_complete", started_monotonic_ns=started_monotonic_ns)
    except (IntentBusy, FileNotFoundError):
        return
    finally:
        trace_event(preview, "attempt_complete", started_monotonic_ns=started_monotonic_ns)


def _observe_one_locked(path):
    intent = read_intent(path)
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
    os.makedirs(intent_dir, exist_ok=True)
    ready_path = os.path.join(os.path.dirname(intent_dir), "observer.ready")
    identity = process_start_identity(os.getpid())
    receipt = {"pid": os.getpid(), "start_identity": identity,
               "started_at_ns": time.time_ns(), "job_label": job_label,
               "intent_dir": os.path.realpath(intent_dir),
               "python_version": list(sys.version_info[:3]), "engine_digest": engine_digest()}
    atomic_write(pid_file, receipt)
    atomic_write(ready_path, receipt)
    next_prune = 0
    while True:
        if probe_owner:
            try:
                if process_start_identity(probe_owner["pid"]) != probe_owner["start_identity"]:
                    break
            except RecoveryError as error:
                print(f"probe owner observation pending: {error}", file=sys.stderr, flush=True)
        try:
            paths = active_intent_paths(intent_dir)
        except FileNotFoundError:
            if probe_owner:
                break
            print("recovery pending: intent directory is unavailable", file=sys.stderr, flush=True)
            time.sleep(PENDING_RETRY_SECONDS)
            continue
        for path in paths:
            try:
                observe_one(path)
            except (OSError, ValueError, KeyError, RecoveryError) as error:
                print(f"observer pending {os.path.basename(path)}: {error}", file=sys.stderr, flush=True)
        if time.monotonic() >= next_prune:
            try:
                prune_intent_archive(intent_dir)
            except OSError as error:
                print(f"archive maintenance pending: {error}", file=sys.stderr, flush=True)
            next_prune = time.monotonic() + ARCHIVE_PRUNE_SECONDS
        time.sleep(POLL_SECONDS)
    if job_label and probe_owner:
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


def engine_digest():
    with open(__file__, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def launchd_job(domain, label):
    result = subprocess.run(["launchctl", "print", f"{domain}/{label}"],
                            text=True, capture_output=True, check=False, timeout=10)
    if result.returncode:
        if any(text in result.stderr for text in ("Could not find service", "No such process")):
            return None
        raise RecoveryError(f"launchd lookup failed: {result.stderr.strip()}")
    pid = re.search(r"^\s*pid = (\d+)\s*$", result.stdout, re.MULTILINE)
    path = re.search(r"^\s*path = (.+)$", result.stdout, re.MULTILINE)
    return {"pid": int(pid.group(1)) if pid else None,
            "path": os.path.realpath(path.group(1).strip()) if path else None}


def owner_receipt(root, label, job):
    if not job or job["pid"] is None:
        return None
    try:
        receipt = read_json(os.path.join(root, "observer.ready"))
        if (receipt.get("job_label") == label and receipt.get("pid") == job["pid"] and
                receipt.get("intent_dir") == os.path.realpath(os.path.join(root, "intents")) and
                receipt.get("engine_digest") == engine_digest() and
                tuple(receipt.get("python_version", [])) >= (3, 10) and
                receipt.get("start_identity") is not None and
                process_start_identity(job["pid"]) == receipt["start_identity"]):
            return receipt
    except (OSError, ValueError, TypeError, RecoveryError):
        pass
    return None


def ensure_owner(root, label, plist):
    """Start the installed owner and accept readiness only from its live PID."""
    if sys.platform != "darwin":
        raise RecoveryError("automatic claim recovery is unsupported on this host")
    if not os.path.isfile(plist):
        raise RecoveryError("recovery launchd plist is unavailable")
    with open(plist, "rb") as handle:
        configuration = plistlib.load(handle)
    argv = configuration.get("ProgramArguments", [])
    def configured_argument(flag):
        try:
            return argv[argv.index(flag) + 1]
        except (ValueError, IndexError):
            return None
    def configured_path(flag):
        value = configured_argument(flag)
        return os.path.realpath(value) if isinstance(value, str) else None
    intent_dir = os.path.realpath(os.path.join(root, "intents"))
    if (configuration.get("Label") != label or
            configuration.get("RunAtLoad") is not True or
            not isinstance(configuration.get("KeepAlive"), dict) or
            configuration["KeepAlive"].get("SuccessfulExit") is not False or
            configured_path("--observe") != intent_dir or
            configured_argument("--job-label") != label or
            configured_path("--pid-file") != os.path.join(os.path.realpath(root), "observer.pid.json") or
            len(argv) < 2 or os.path.realpath(argv[1]) != os.path.realpath(__file__) or
            not os.access(argv[0], os.X_OK)):
        raise RecoveryError("recovery job does not match the requested engine, state root and restart policy")
    os.makedirs(intent_dir, exist_ok=True)
    domain = f"gui/{os.getuid()}"
    with intent_lock(os.path.join(root, "owner-admission"), timeout=15, create=True):
        job = launchd_job(domain, label)
        if job and job["path"] != os.path.realpath(plist):
            raise RecoveryError("recovery label is owned by another launchd configuration")
        ready = owner_receipt(root, label, job)
        if ready:
            return ready
        if job:
            result = subprocess.run(["launchctl", "bootout", f"{domain}/{label}"],
                                    text=True, capture_output=True, check=False, timeout=10)
            if result.returncode and launchd_job(domain, label) is not None:
                raise RecoveryError(f"stale owner could not stop: {result.stderr.strip()}")
        try:
            os.unlink(os.path.join(root, "observer.ready"))
        except FileNotFoundError:
            pass
        result = subprocess.run(["launchctl", "bootstrap", domain, plist], text=True,
                                capture_output=True, check=False, timeout=10)
        if result.returncode:
            raise RecoveryError(f"launchd bootstrap failed: {result.stderr.strip()}")
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            job = launchd_job(domain, label)
            if job and job["path"] != os.path.realpath(plist):
                raise RecoveryError("launchd owner configuration changed during startup")
            ready = owner_receipt(root, label, job)
            if ready:
                return ready
            time.sleep(POLL_SECONDS)
        raise RecoveryError("launchd recovery owner did not become ready")


def recovery_intent_path():
    return os.environ.get("HERDR_AGENT_INTERCOM_RECOVERY_INTENT") or os.environ.get("MMS377_INTENT")


def prepare_intent(intent_dir, agent, source, launcher_pid=None, launcher_start=None):
    """Persist the fenced launch obligation before the shell claims a pane."""
    if launcher_pid is None:
        raise RecoveryError("launcher PID is required")
    observed_start = process_start_identity(launcher_pid)
    if observed_start is None or (launcher_start is not None and observed_start != launcher_start):
        raise RecoveryError("launcher process identity is unavailable")
    parent = os.getppid()
    for _ in range(64):
        if parent == launcher_pid:
            break
        if parent <= 1:
            raise RecoveryError("admission caller is not a descendant of the launcher")
        result = subprocess.run(["ps", "-p", str(parent), "-o", "ppid="],
                                text=True, capture_output=True, check=False, timeout=2)
        if result.returncode or not result.stdout.strip().isdigit():
            raise RecoveryError("launcher ancestry is unavailable")
        parent = int(result.stdout.strip())
    else:
        raise RecoveryError("launcher ancestry exceeds the supported depth")
    if process_start_identity(launcher_pid) != observed_start:
        raise RecoveryError("launcher incarnation changed during admission")
    pane = os.environ.get("HERDR_PANE_ID")
    socket_path = os.environ.get("HERDR_SOCKET_PATH")
    if not pane or not socket_path:
        raise RecoveryError("current Herdr pane or socket is unavailable")
    connection = {"socket_path": socket_path,
                  "server_identity": capture_server_identity(socket_path),
                  "socket_identity": socket_identity(socket_path)}
    response = bound_request({"connection": connection}, "pane.get", {"pane_id": pane})
    if "error" in response:
        raise RecoveryError(f"launch pane lookup failed: {response['error']}")
    terminal = response["result"]["pane"]
    sequence = reserve_sequence(os.path.join(os.path.dirname(intent_dir), "sequences"), source)
    intent = {
        "launch_id": f"launch-{agent}-{launcher_pid}-{time.time_ns()}",
        "phase": "intent",
        "connection": connection,
        "terminal": {"pane_id": terminal["pane_id"], "terminal_id": terminal["terminal_id"]},
        "agent_kind": agent,
        "claim": {"source": source, "claim_seq": sequence,
                  "handoff_seq": sequence + 1, "release_seq": sequence + 2},
        "client": {"pid": launcher_pid, "start_identity": observed_start},
        "created_at_ns": time.time_ns(),
    }
    if os.environ.get("HERDR_AGENT_INTERCOM_TRACE_DIR"):
        intent["trace_dir"] = os.environ["HERDR_AGENT_INTERCOM_TRACE_DIR"]
    return write_intent(intent_dir, intent), intent


def claim_intent(intent_dir, agent, source, alias, launcher_pid, launcher_start):
    """Create and acknowledge one fenced claim, or retire its own failed try."""
    path, intent = prepare_intent(intent_dir, agent, source, launcher_pid, launcher_start)
    try:
        with intent_lock(path, timeout=5):
            intent = read_json(path)
            if intent["phase"] != "intent" or process_start_identity(launcher_pid) != intent["client"]["start_identity"]:
                raise RecoveryError("launch obligation is no longer eligible for acquisition")
            response = bound_request(intent, "pane.report_agent", {
                "pane_id": intent["terminal"]["pane_id"], "source": source,
                "agent": agent, "state": "unknown", "seq": intent["claim"]["claim_seq"],
            })
            if "error" in response:
                raise RecoveryError(f"claim rejected: {response['error']}")
            trace_event(intent, "claim_report_complete", unique=True, response=response)
            response = bound_request(intent, "agent.rename", {
                "target": intent["terminal"]["pane_id"], "name": alias,
            })
            if "error" in response:
                release = bound_request(intent, "pane.release_agent", {
                    "pane_id": intent["terminal"]["pane_id"], "source": source,
                    "agent": agent, "seq": intent["claim"]["release_seq"],
                })
                if "error" in release:
                    raise RecoveryError(f"rejected alias cleanup failed: {release['error']}")
                state = bound_request(intent, "agent.get", {"target": intent["terminal"]["pane_id"]})
                if state.get("error", {}).get("code") != "agent_not_found":
                    raise RecoveryError("rejected alias cleanup was not observed")
                update_intent(path, intent, "settled", "settled: alias acquisition rejected")
                return {"claimed": False, "error": response["error"], "intent": path,
                        "retry": response["error"].get("code") == "agent_name_taken", "pending": False}
            visible = bound_request(intent, "agent.get", {"target": intent["terminal"]["pane_id"]})
            record = visible.get("result", {}).get("agent", {})
            if ("error" in visible or record.get("name") != alias or record.get("agent") != agent or
                    record.get("terminal_id") != intent["terminal"]["terminal_id"] or
                    record.get("agent_status") != "unknown"):
                raise RecoveryError("claim readback did not match this launch")
            intent["phase"] = "acquired"
            intent["acquired_at_ns"] = time.time_ns()
            atomic_write(path, intent)
            return {"claimed": True, "intent": path, "claim_seq": intent["claim"]["claim_seq"],
                    "handoff_seq": intent["claim"]["handoff_seq"], "release_seq": intent["claim"]["release_seq"]}
    except (OSError, ValueError, KeyError, RecoveryError) as error:
        return {"claimed": False, "intent": path, "error": str(error), "retry": False, "pending": True}


def resolve_existing_alias(root, label, plist, expected_alias):
    """A pending launch claim is not an independently reusable pane identity."""
    directory = os.path.join(root, "intents")
    socket_path = os.environ.get("HERDR_SOCKET_PATH")
    pane_id = os.environ.get("HERDR_PANE_ID")
    if not socket_path or not pane_id:
        raise RecoveryError("existing alias server identity is unavailable")
    connection = {"socket_path": socket_path, "server_identity": capture_server_identity(socket_path)}
    scope = {"connection": connection}
    response = bound_request(scope, "pane.get", {"pane_id": pane_id})
    if "error" in response:
        raise RecoveryError("existing alias terminal identity is unavailable")
    terminal = response["result"]["pane"]

    def pending():
        obligations = []
        for path in active_intent_paths(directory):
            try:
                intent = read_json(path)
            except FileNotFoundError:
                continue  # A completed record moved into the archive.
            if (intent["phase"] not in TERMINAL_PHASES and
                    intent["connection"]["server_identity"] == connection["server_identity"] and
                    intent["terminal"]["terminal_id"] == terminal["terminal_id"]):
                obligations.append(intent)
        return obligations

    obligations = pending()
    if obligations:
        for intent in obligations:
            if process_start_identity(intent["client"]["pid"]) == intent["client"]["start_identity"]:
                raise RecoveryError("existing alias belongs to a live unresolved launch")
        # Only the established observer mutates old claims. Waiting happens
        # before cci/native startup, so cleanup cannot strand this caller's name.
        ensure_owner(root, label, plist)
        deadline = time.monotonic() + 10
        while pending():
            if time.monotonic() >= deadline:
                raise RecoveryError("existing alias cleanup remains pending")
            time.sleep(POLL_SECONDS)
    response = bound_request(scope, "agent.get", {"target": terminal["pane_id"]})
    if response.get("error", {}).get("code") == "agent_not_found":
        return ""  # Re-enter fresh admission instead of borrowing the old alias.
    if "error" in response:
        raise RecoveryError("existing alias readback failed")
    agent = response["result"]["agent"]
    if agent.get("terminal_id") != terminal["terminal_id"] or agent.get("name") != expected_alias:
        raise RecoveryError("existing alias changed during recovery")
    return expected_alias


def main():
    if sys.platform == "darwin" and sys.version_info < (3, 10):
        raise RecoveryError("claim recovery requires Python 3.10 or later on macOS")
    parser = argparse.ArgumentParser()
    parser.add_argument("--observe")
    parser.add_argument("--pid-file")
    parser.add_argument("--probe-owner-pid", type=int)
    parser.add_argument("--probe-owner-start")
    parser.add_argument("--job-label")
    parser.add_argument("--handoff", action="store_true")
    parser.add_argument("--bind-exec")
    parser.add_argument("--prepare-intent")
    parser.add_argument("--acknowledge-intent")
    parser.add_argument("--agent")
    parser.add_argument("--source")
    parser.add_argument("--alias")
    parser.add_argument("--launcher-pid", type=int)
    parser.add_argument("--launcher-start")
    parser.add_argument("--claim-intent")
    parser.add_argument("--ensure-owner", action="store_true")
    parser.add_argument("--reuse-alias")
    parser.add_argument("--owner-root")
    parser.add_argument("--owner-label")
    parser.add_argument("--owner-plist")
    parser.add_argument("bridge_args", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.reuse_alias:
        if not all((arguments.alias, arguments.owner_label, arguments.owner_plist)):
            parser.error("alias reuse requires --alias, --owner-label and --owner-plist")
        print(json.dumps({"alias": resolve_existing_alias(arguments.reuse_alias, arguments.owner_label,
                                                        arguments.owner_plist, arguments.alias)}))
        return
    if arguments.ensure_owner:
        if not all((arguments.owner_root, arguments.owner_label, arguments.owner_plist)):
            parser.error("--owner-root, --owner-label and --owner-plist are required with --ensure-owner")
        print(json.dumps(ensure_owner(arguments.owner_root, arguments.owner_label, arguments.owner_plist)))
        return
    if arguments.prepare_intent:
        if not arguments.agent or not arguments.source:
            parser.error("--agent and --source are required with --prepare-intent")
        path, intent = prepare_intent(arguments.prepare_intent, arguments.agent, arguments.source,
                                      arguments.launcher_pid, arguments.launcher_start)
        print(json.dumps({"intent": path, "claim_seq": intent["claim"]["claim_seq"],
                          "handoff_seq": intent["claim"]["handoff_seq"],
                          "release_seq": intent["claim"]["release_seq"]}))
        return
    if arguments.claim_intent:
        if not all((arguments.agent, arguments.source, arguments.alias, arguments.launcher_pid)):
            parser.error("claim admission requires agent, source, alias and launcher identity")
        print(json.dumps(claim_intent(arguments.claim_intent, arguments.agent, arguments.source,
                                      arguments.alias, arguments.launcher_pid,
                                      arguments.launcher_start)))
        return
    if arguments.acknowledge_intent:
        acknowledge_acquisition(arguments.acknowledge_intent)
        return
    if arguments.handoff:
        path = recovery_intent_path()
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
            path = recovery_intent_path()
            if not path:
                raise RecoveryError("claim binding intent is unavailable")
            bound = bind_native_client(path)
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
    try:
        main()
    except (OSError, ValueError, KeyError, RecoveryError) as error:
        print(f"herdr-agent-intercom recovery: {error}", file=sys.stderr)
        raise SystemExit(1)
