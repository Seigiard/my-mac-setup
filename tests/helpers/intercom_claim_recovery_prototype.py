#!/usr/bin/env python3
"""Narrow, opt-in launchd-owned recovery observer for the ownership proof.

This is deliberately not launcher code.  It owns only durable claim-cleanup
intents created by the live Herdr proof and has no client-supervision policy.
"""

import argparse
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


class RecoveryError(Exception):
    pass


class ServerInstanceChanged(RecoveryError):
    pass


def atomic_write(path, value):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
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
    path = os.path.join(intent_dir, f"{intent['launch_id']}.json")
    atomic_write(path, intent)
    return path


def acknowledge_acquisition(intent_path):
    intent = read_json(intent_path)
    if intent["phase"] != "intent":
        raise RecoveryError(f"cannot acknowledge phase {intent['phase']!r}")
    intent["phase"] = "acquired"
    intent["acquired_at_ns"] = time.time_ns()
    atomic_write(intent_path, intent)


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
            update_intent(path, intent, "retired", "retired: original server instance ended")
            return
    update_intent(path, intent, intent["phase"], f"pending: {error}")


def observe_one(path):
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
        socket_identity(intent["connection"]["socket_path"])
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
        # This source only ever declared unknown. A concrete published state
        # witnesses takeover; retiring bookkeeping does not release its owner.
        if state in {"working", "idle", "done", "blocked"}:
            update_intent(path, intent, "retired", "retired: lifecycle takeover observed")
            return
    if client_alive:
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
        atomic_write(barrier + ".checked", {"checked_at_ns": time.time_ns()})
        while not os.path.exists(barrier + ".continue"):
            time.sleep(POLL_SECONDS)
    try:
        release = bound_request(intent, "pane.release_agent", {
            "pane_id": pane_id, "source": intent["claim"]["source"],
            "agent": intent["agent_kind"], "seq": intent["claim"]["release_seq"],
        })
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
        update_intent(path, intent, intent["phase"], "pending: release acknowledged but claim still published")
        return
    if state["error"].get("code") != "agent_not_found":
        update_intent(path, intent, intent["phase"], f"pending: state check failed: {state['error']}")
        return
    update_intent(path, intent, "settled", "settled: exact owned release observed")


def observer(intent_dir, pid_file):
    atomic_write(pid_file, {"pid": os.getpid(), "start_identity": process_start_identity(os.getpid()), "started_at_ns": time.time_ns()})
    while True:
        for entry in sorted(os.listdir(intent_dir)):
            if entry.endswith(".json"):
                try:
                    observe_one(os.path.join(intent_dir, entry))
                except (OSError, ValueError, KeyError, RecoveryError) as error:
                    print(f"observer pending {entry}: {error}", file=sys.stderr, flush=True)
        time.sleep(POLL_SECONDS)


class LaunchdOwner:
    """A temporary per-proof launchd job. launchd is the observer restart owner."""

    def __init__(self, scratch):
        self.scratch = scratch
        self.intent_dir = os.path.join(scratch, "intents")
        self.label = f"dev.seigiard.mms377.recovery.{os.getpid()}.{uuid.uuid4().hex[:8]}"
        self.plist = os.path.join(scratch, f"{self.label}.plist")
        self.stdout = os.path.join(scratch, "observer.stdout.log")
        self.stderr = os.path.join(scratch, "observer.stderr.log")
        self.pid_file = os.path.join(scratch, "observer.pid.json")
        self.domain = f"gui/{os.getuid()}"
        os.makedirs(self.intent_dir, exist_ok=True)

    def start(self):
        payload = {
            "Label": self.label,
            "ProgramArguments": [sys.executable, os.path.abspath(__file__), "--observe", self.intent_dir, "--pid-file", self.pid_file],
            "KeepAlive": True,
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
        result = subprocess.run(["launchctl", "bootout", f"{self.domain}/{self.label}"], text=True, capture_output=True, check=False)
        if result.returncode and "No such process" not in result.stderr:
            raise RecoveryError(f"launchd bootout failed: {result.stderr.strip()}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--observe")
    parser.add_argument("--pid-file")
    arguments = parser.parse_args()
    if not arguments.observe or not arguments.pid_file:
        parser.error("--observe and --pid-file are required")
    observer(arguments.observe, arguments.pid_file)


if __name__ == "__main__":
    main()
