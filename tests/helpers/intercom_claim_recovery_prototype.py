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
import subprocess
import sys
import time
import uuid


POLL_SECONDS = 0.10


class RecoveryError(Exception):
    pass


def clean_env(config_root):
    env = os.environ.copy()
    for name in tuple(env):
        if name == "HERDR_ENV" or name.startswith("HERDR_"):
            env.pop(name)
    env["XDG_CONFIG_HOME"] = config_root
    return env


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
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart="], text=True, capture_output=True, check=False
    )
    identity = result.stdout.strip()
    return identity if result.returncode == 0 and identity else None


def socket_identity(path):
    stat = os.stat(path)
    return {"device": stat.st_dev, "inode": stat.st_ino}


def command(intent, *args):
    return subprocess.run(
        [intent["connection"]["herdr_executable"], "--session", intent["connection"]["session"], *args],
        text=True,
        capture_output=True,
        timeout=15,
        check=False,
        env=clean_env(intent["connection"]["config_root"]),
    )


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
    intent["phase"] = phase
    intent["updated_at_ns"] = time.time_ns()
    if diagnostic:
        intent["diagnostic"] = diagnostic
    atomic_write(intent_path, intent)


def observe_one(path):
    intent = read_json(path)
    if intent["phase"] in {"settled", "retired"}:
        return
    pid = intent["client"]["pid"]
    expected_start = intent["client"]["start_identity"]
    actual_start = process_start_identity(pid)
    if actual_start == expected_start:
        return
    try:
        current_socket = socket_identity(intent["connection"]["socket_path"])
    except OSError as error:
        retry_path = intent["connection"].get("retry_socket_path")
        if retry_path and os.path.exists(path + ".retry-socket"):
            intent["connection"]["socket_path"] = retry_path
            intent["connection"].pop("retry_socket_path", None)
            atomic_write(path, intent)
            return
        update_intent(path, intent, intent["phase"], f"pending: socket unavailable: {error.strerror}")
        return
    if current_socket != intent["connection"]["socket_identity"]:
        update_intent(path, intent, intent["phase"], "pending: server instance changed")
        return
    pane_id = intent["terminal"]["pane_id"]
    pane = command(intent, "pane", "get", pane_id)
    if pane.returncode:
        if "pane_not_found" in pane.stderr:
            update_intent(path, intent, "settled", "settled: terminal resource gone")
            return
        update_intent(path, intent, intent["phase"], f"pending: pane lookup failed: {pane.stderr.strip()}")
        return
    observed_terminal = json.loads(pane.stdout)["result"]["pane"].get("terminal_id")
    if observed_terminal != intent["terminal"]["terminal_id"]:
        update_intent(path, intent, intent["phase"], "pending: terminal identity changed")
        return
    barrier = intent.get("barrier")
    if barrier:
        atomic_write(barrier + ".checked", {"checked_at_ns": time.time_ns()})
        while not os.path.exists(barrier + ".continue"):
            time.sleep(POLL_SECONDS)
    release = command(
        intent,
        "pane",
        "release-agent",
        pane_id,
        "--source",
        intent["claim"]["source"],
        "--agent",
        intent["agent_kind"],
        "--seq",
        str(intent["claim"]["release_seq"]),
    )
    if release.returncode:
        update_intent(path, intent, intent["phase"], f"pending: release failed: {release.stderr.strip()}")
        return
    state = command(intent, "agent", "get", pane_id)
    if state.returncode == 0:
        update_intent(path, intent, intent["phase"], "pending: release acknowledged but claim still published")
        return
    if "agent_not_found" not in state.stderr:
        update_intent(path, intent, intent["phase"], f"pending: state check failed: {state.stderr.strip()}")
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
