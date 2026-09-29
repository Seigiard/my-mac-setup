#!/usr/bin/env python3
"""Opt-in real-Herdr conformance probe for launch-claim cleanup ownership."""

import json
import os
import pty
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
from unittest.mock import patch

import intercom_claim_recovery_prototype as recovery_prototype

from intercom_claim_recovery_prototype import (
    LaunchdOwner,
    acknowledge_acquisition,
    atomic_write,
    capture_server_identity,
    process_start_identity,
    socket_identity,
    write_intent,
)


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
OPT_IN = "MMS_LIVE_HERDR_OWNERSHIP_PROBE"
EVIDENCE_DIR = "MMS_LIVE_HERDR_OWNERSHIP_EVIDENCE_DIR"
OLD_SOURCE = "mms-377-old-launch"
CLAUDE_SOURCE = "herdr:claude"
AGENT = "claude"
OWNED_CLIENTS = []


class ProbeError(Exception):
    pass


def native_executable(name):
    result = subprocess.run(
        ["zsh", "-fc", f"whence -pa {name}"], text=True, capture_output=True, check=False
    )
    for path in result.stdout.splitlines():
        if not os.path.isfile(path) or not os.access(path, os.X_OK):
            continue
        if name == "herdr":
            with open(path, "rb") as handle:
                if handle.read(2) == b"#!":
                    continue
        if "herdr-agent-intercom" not in os.path.basename(path):
            return path
    raise ProbeError(f"cannot resolve native {name} executable")


def run(*args, expected=0, env=None, session=None):
    command = ["herdr"]
    if session:
        command.extend(("--session", session))
    command.extend(args)
    result = subprocess.run(command, text=True, capture_output=True, timeout=15, check=False, env=env)
    if expected is not None and result.returncode != expected:
        raise ProbeError(f"{' '.join(args)} returned {result.returncode}, expected {expected}: {result.stderr.strip()}")
    return result


class OwnedHerdr:
    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="mms377-herdr-proof-", dir="/tmp")
        self.session = f"ownership-{os.getpid()}"
        self.client = None
        self.events = []

    @property
    def env(self):
        env = os.environ.copy()
        for name in tuple(env):
            if name == "HERDR_ENV" or name.startswith("HERDR_"):
                env.pop(name)
        env["XDG_CONFIG_HOME"] = self.root
        env["XDG_STATE_HOME"] = os.path.join(self.root, "state")
        return env

    @property
    def socket_path(self):
        return os.path.join(self.root, "herdr", "sessions", self.session, "herdr.sock")

    def run(self, *args, expected=0):
        return run(*args, expected=expected, env=self.env, session=self.session)

    def start(self):
        master, slave = pty.openpty()
        self.client = subprocess.Popen(
            ["herdr", "--session", self.session], stdin=slave, stdout=slave, stderr=slave,
            env=self.env, close_fds=True,
        )
        os.close(slave)
        os.close(master)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            status = subprocess.run(
                ["herdr", "--session", self.session, "status", "server"], text=True,
                capture_output=True, env=self.env, timeout=15, check=False,
            )
            if status.returncode == 0 and "status: running" in status.stdout:
                return self.snapshot()["panes"][0]
            if self.client.poll() is not None:
                raise ProbeError("owned Herdr client exited before its server became ready")
            time.sleep(0.1)
        raise ProbeError("owned Herdr server did not become ready within 10 seconds")

    def snapshot(self):
        result = self.run("api", "snapshot")
        return json.loads(result.stdout)["result"]["snapshot"]

    def raw(self, method, params):
        request = {"id": f"mms377-{len(self.events)}", "method": method, "params": params}
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(15)
            connection.connect(self.socket_path)
            connection.sendall((json.dumps(request) + "\n").encode())
            response = b""
            while not response.endswith(b"\n"):
                chunk = connection.recv(65536)
                if not chunk:
                    raise ProbeError(f"{method} returned an empty socket response")
                response += chunk
        decoded = json.loads(response)
        if "error" in decoded:
            raise ProbeError(f"{method} returned {decoded['error']}")
        return decoded

    def state(self, pane, step):
        result = self.run("agent", "get", pane, expected=None)
        record = None
        if result.returncode == 0:
            record = json.loads(result.stdout)["result"]["agent"]
        elif "agent_not_found" not in result.stderr:
            raise ProbeError(f"agent get failed at {step}: {result.stderr.strip()}")
        explain = self.run("agent", "explain", pane, "--json", expected=None)
        explanation = None
        if explain.returncode == 0:
            try:
                explanation = json.loads(explain.stdout)
            except json.JSONDecodeError as error:
                raise ProbeError(f"agent explain returned invalid JSON at {step}") from error
        elif record is not None:
            explanation = {"unavailable": explain.stderr.strip()}
        observed = {"step": step, "agent": record, "explain": explanation}
        self.events.append(observed)
        session = (record or {}).get("agent_session") or {}
        rule = ((explanation or {}).get("matched_rule") or {}).get("id")
        print(json.dumps({"transition": step, "status": (record or {}).get("agent_status"),
                          "terminal_id": (record or {}).get("terminal_id"),
                          "alias": (record or {}).get("name"),
                          "session_source": session.get("source"), "rule": rule}, sort_keys=True))
        return observed

    def clear_authority(self, pane, source, seq):
        response = self.raw("pane.clear_agent_authority", {"pane_id": pane, "source": source, "seq": seq})
        self.events.append({"clear": {"pane": pane, "source": source, "seq": seq, "response": response}})
        return response

    def close(self):
        errors = []
        try:
            self.run("session", "stop", self.session)
        except ProbeError as error:
            errors.append(str(error))
        if self.client:
            try:
                self.client.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.client.terminate()
                self.client.wait(timeout=5)
        try:
            self.run("session", "delete", self.session)
        except ProbeError as error:
            errors.append(str(error))
        shutil.rmtree(self.root, ignore_errors=True)
        if errors:
            raise ProbeError("; ".join(errors))


def require(observed, condition, message):
    if not condition:
        raise ProbeError(f"{observed['step']}: {message}")


def require_agent(observed, status=None, source=None, terminal=None, alias=None):
    record = observed["agent"]
    require(observed, record is not None, "agent record is missing")
    require(observed, record.get("agent") == AGENT, f"agent is {record.get('agent')!r}")
    if status:
        require(observed, record.get("agent_status") == status, f"status is {record.get('agent_status')!r}")
    if terminal:
        require(observed, record.get("terminal_id") == terminal, "terminal identity changed")
    if alias:
        require(observed, record.get("name") == alias, "alias changed")
    if source:
        session = record.get("agent_session") or {}
        require(observed, session.get("source") == source, f"session source is {session.get('source')!r}")
    return record


def require_rule(observed):
    explanation = observed["explain"] or {}
    rule = (explanation.get("matched_rule") or {}).get("id")
    require(observed, isinstance(rule, str) and rule.strip(), f"matched rule is {rule!r}")
    return rule


def create_pane(owner, root):
    created = owner.run("pane", "split", "--pane", root["pane_id"], "--direction", "down", "--cwd", ROOT, "--no-focus")
    return json.loads(created.stdout)["result"]["pane"]


def report(owner, pane, source, state, seq, session_id=None):
    args = ["pane", "report-agent", pane, "--source", source, "--agent", AGENT, "--state", state, "--seq", str(seq)]
    if session_id:
        args.extend(("--agent-session-id", session_id))
    owner.run(*args)


def release(owner, pane, source, seq):
    owner.run("pane", "release-agent", pane, "--source", source, "--agent", AGENT, "--seq", str(seq))


def wait_for_native_session(owner, pane):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        observed = owner.state(pane, "native-session-poll")
        record = observed["agent"] or {}
        session = record.get("agent_session") or {}
        if session.get("source") == CLAUDE_SOURCE and session.get("value"):
            require_rule(observed)
            return observed
        time.sleep(0.2)
    raise ProbeError("native Claude did not report a Herdr Claude session within 15 seconds")


def start_client(seconds=30):
    client = subprocess.Popen([sys.executable, "-c", f"import time; time.sleep({seconds})"])
    OWNED_CLIENTS.append(client)
    start = process_start_identity(client.pid)
    if not start:
        raise ProbeError("could not capture client process-start identity")
    return client, start


def durable_intent(owner, launchd, pane, sequence, client, start_identity, barrier=None):
    launch_id = f"launch-{client.pid}-{sequence}"
    intent = {
        "launch_id": launch_id,
        "phase": "intent",
        "connection": {
            "config_root": owner.root,
            "session": owner.session,
            "socket_path": owner.socket_path,
            "socket_identity": socket_identity(owner.socket_path),
            "server_identity": capture_server_identity(owner.socket_path),
            "herdr_executable": native_executable("herdr"),
        },
        "terminal": {"pane_id": pane["pane_id"], "terminal_id": pane["terminal_id"]},
        "agent_kind": AGENT,
        "claimant_source": "prototype-launcher",
        "claim": {"source": OLD_SOURCE, "claim_seq": sequence, "release_seq": sequence + 1},
        "client": {"pid": client.pid, "start_identity": start_identity},
        "created_at_ns": time.time_ns(),
    }
    if barrier:
        intent["barrier"] = barrier
    path = write_intent(launchd.intent_dir, intent)
    return path


def wait_for(path, phase, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with open(path, encoding="utf-8") as handle:
            intent = json.load(handle)
        if intent.get("phase") == phase:
            return intent
        time.sleep(0.05)
    raise ProbeError(f"intent did not reach {phase}: {path}; last={intent}")


def case(owner, name, action, verdicts):
    try:
        action()
    except ProbeError as error:
        verdicts.append((name, "FAIL", str(error)))
        print(f"FAIL: {name}: {error}")
    else:
        verdicts.append((name, "PASS", "observed"))
        print(f"PASS: {name}")


def main():
    if os.environ.get(OPT_IN) != "1":
        print(f"REFUSED: set {OPT_IN}=1 to create an isolated owned Herdr server.")
        return 2
    if os.environ.get("HERDR_ENV") != "1":
        print("REFUSED: this probe must run from a Herdr-managed pane.")
        return 2

    owner = OwnedHerdr()
    verdicts = []
    launchd = None
    try:
        native_claude = native_executable("claude")
        root = owner.start()
        launchd = LaunchdOwner(owner.root)
        launchd.start()

        def failed_process_lookup_preserves_live_claim():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            client, start_identity = start_client()
            isolated = SimpleNamespace(intent_dir=os.path.join(owner.root, "identity-checks"))
            intent = durable_intent(owner, isolated, pane, sequence, client, start_identity)
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
            acknowledge_acquisition(intent)
            native_run = subprocess.run

            def unavailable_ps(argv, *args, **kwargs):
                if os.path.basename(argv[0]) == "ps" and argv[1:3] == ["-p", str(client.pid)]:
                    return subprocess.CompletedProcess(argv, 1, "", "temporary process lookup failure")
                return native_run(argv, *args, **kwargs)

            try:
                # A real live-process control first proves that a valid lookup holds the claim.
                recovery_prototype.observe_one(intent)
                held = owner.state(pane["pane_id"], "live-process-control")
                require_agent(held, status="unknown", terminal=pane["terminal_id"])
                with patch.object(recovery_prototype.subprocess, "run", unavailable_ps):
                    recovery_prototype.observe_one(intent)
                uncertain = owner.state(pane["pane_id"], "failed-lookup-live-process")
                require_agent(uncertain, status="unknown", terminal=pane["terminal_id"])
                record = json.load(open(intent, encoding="utf-8"))
                require({"step": "failed-lookup-intent"}, record["phase"] == "acquired", "failed lookup settled a live claim")
                client.terminate()
                client.wait(timeout=5)
                recovery_prototype.observe_one(intent)
                ended = owner.state(pane["pane_id"], "confirmed-exit-control")
                require(ended, ended["agent"] is None, "confirmed exit did not release the claim")
            finally:
                if client.poll() is None:
                    client.terminate()
                    client.wait(timeout=5)

        def observer_exit_restart_and_cleanup():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            client, start_identity = start_client()
            intent = durable_intent(owner, launchd, pane, sequence, client, start_identity)
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
            acknowledge_acquisition(intent)
            alias = f"mms377-owner-{os.getpid()}"
            owner.run("agent", "rename", pane["pane_id"], alias)
            claimed = owner.state(pane["pane_id"], "durable-claim-before-client-exit")
            require_agent(claimed, status="unknown", terminal=pane["terminal_id"], alias=alias)
            old_observer = launchd.kill_observer()
            require({"step": "observer-restarted"}, old_observer["pid"] != 0, "launchd did not restart observer")
            began = time.monotonic()
            client.terminate()
            client.wait(timeout=5)
            settled_intent = wait_for(intent, "settled")
            elapsed = time.monotonic() - began
            settled = owner.state(pane["pane_id"], "launchd-restarted-observer-release")
            require(settled, settled["agent"] is None, "old claim survived restarted owner cleanup")
            owner.events.append({"recovery_latency_seconds": elapsed, "intent": settled_intent})

        def same_source_successor():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
            owner.run("agent", "rename", pane["pane_id"], f"mms377-same-{sequence}")
            report(owner, pane["pane_id"], OLD_SOURCE, "working", sequence + 10)
            successor = owner.state(pane["pane_id"], "same-source-successor")
            require_agent(successor, status="working", terminal=pane["terminal_id"], alias=f"mms377-same-{sequence}")
            release(owner, pane["pane_id"], OLD_SOURCE, sequence + 1)
            preserved = owner.state(pane["pane_id"], "old-release-after-same-source-successor")
            require_agent(preserved, status="working", terminal=pane["terminal_id"], alias=f"mms377-same-{sequence}")
            release(owner, pane["pane_id"], OLD_SOURCE, sequence + 11)
            settled = owner.state(pane["pane_id"], "same-source-successor-own-clear")
            require(settled, settled["agent"] is None, "successor did not settle its own claim")

        def takeover_retires_only_bookkeeping():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            client, start_identity = start_client()
            intent = durable_intent(owner, launchd, pane, sequence, client, start_identity)
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
            acknowledge_acquisition(intent)
            alias = f"mms377-takeover-{client.pid}"
            owner.run("agent", "rename", pane["pane_id"], alias)
            report(owner, pane["pane_id"], "mms-377-actual-owner", "working", sequence)
            wait_for(intent, "retired")
            retained = owner.state(pane["pane_id"], "lifecycle-takeover-retired-intent")
            require_agent(retained, status="working", terminal=pane["terminal_id"], alias=alias)
            require({"step": "takeover-process"}, client.poll() is None, "bookkeeping retirement killed the client")
            client.terminate()
            client.wait(timeout=5)
            release(owner, pane["pane_id"], "mms-377-actual-owner", sequence + 1)

        def moved_terminal_follows_stable_identity():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            client, start_identity = start_client()
            intent = durable_intent(owner, launchd, pane, sequence, client, start_identity)
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
            acknowledge_acquisition(intent)
            move = owner.run("pane", "move", pane["pane_id"], "--new-workspace", "--no-focus")
            moved = json.loads(move.stdout)["result"]["move_result"]["pane"]
            require({"step": "moved-terminal"}, moved["pane_id"] != pane["pane_id"] and moved["terminal_id"] == pane["terminal_id"], "move control did not change coordinates while preserving the terminal")
            client.terminate()
            client.wait(timeout=5)
            receipt = wait_for(intent, "settled")
            require({"step": "moved-receipt"}, receipt["terminal"]["pane_id"] == moved["pane_id"], "observer retired the stale coordinate instead of following its terminal")
            settled = owner.state(moved["pane_id"], "moved-terminal-cleanup")
            require(settled, settled["agent"] is None, "moved terminal retained its abandoned claim")

        def fenced_newer_claim_survives_cleanup():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            client, start_identity = start_client()
            barrier = os.path.join(owner.root, f"fence-{client.pid}")
            intent = durable_intent(owner, launchd, pane, sequence, client, start_identity, barrier)
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
            acknowledge_acquisition(intent)
            client.terminate()
            client.wait(timeout=5)
            deadline = time.monotonic() + 5
            while not os.path.exists(barrier + ".checked") and time.monotonic() < deadline:
                time.sleep(0.05)
            require({"step": "fence"}, os.path.exists(barrier + ".checked"), "observer did not establish pre-release barrier")
            report(owner, pane["pane_id"], OLD_SOURCE, "working", sequence + 10)
            alias = f"mms377-newer-{client.pid}"
            owner.run("agent", "rename", pane["pane_id"], alias)
            open(barrier + ".continue", "w").close()
            time.sleep(0.5)
            survivor = owner.state(pane["pane_id"], "fenced-old-release-after-newer-same-source-claim")
            require_agent(survivor, status="working", terminal=pane["terminal_id"], alias=alias)
            release(owner, pane["pane_id"], OLD_SOURCE, sequence + 11)
            settled = owner.state(pane["pane_id"], "newer-claim-own-release")
            require(settled, settled["agent"] is None, "newer claim did not settle")

        def unavailable_socket_then_recovery_and_stale_pid():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            client, start_identity = start_client()
            intent = durable_intent(owner, launchd, pane, sequence, client, start_identity)
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
            acknowledge_acquisition(intent)
            hidden = owner.socket_path + ".unavailable"
            os.rename(owner.socket_path, hidden)
            try:
                client.terminate()
                client.wait(timeout=5)
                deadline = time.monotonic() + 5
                pending = {}
                while time.monotonic() < deadline:
                    pending = json.load(open(intent, encoding="utf-8"))
                    if "socket unavailable" in pending.get("diagnostic", ""):
                        break
                    time.sleep(0.05)
                require({"step": "socket-unavailable"}, pending.get("phase") == "acquired" and "socket unavailable" in pending.get("diagnostic", ""), f"socket outage was not retained: {pending}")
            finally:
                os.rename(hidden, owner.socket_path)
                if client.poll() is None:
                    client.terminate()
                    client.wait(timeout=5)
            wait_for(intent, "settled")
            settled = owner.state(pane["pane_id"], "socket-recovered-release")
            require(settled, settled["agent"] is None, "claim survived socket recovery")
            replacement, replacement_start = start_client()
            saved_other_start = process_start_identity(os.getpid())
            require({"step": "pid-reuse-control"}, replacement_start != saved_other_start, "control processes need distinct observed start identities")
            replacement_pane = create_pane(owner, root)
            other_sequence = time.time_ns()
            # Model PID reuse with two independently read, real start identities.
            # This does not claim that the kernel recycled a PID during the probe.
            isolated = SimpleNamespace(intent_dir=os.path.join(owner.root, "identity-checks"))
            old_incarnation = durable_intent(owner, isolated, replacement_pane, other_sequence, replacement, saved_other_start)
            report(owner, replacement_pane["pane_id"], OLD_SOURCE, "unknown", other_sequence)
            acknowledge_acquisition(old_incarnation)
            try:
                recovery_prototype.observe_one(old_incarnation)
                gone = owner.state(replacement_pane["pane_id"], "old-incarnation-settled")
                require(gone, gone["agent"] is None, "a different live process kept the dead incarnation's claim")
                require({"step": "replacement-process"}, replacement.poll() is None, "cleanup terminated the replacement process")
            finally:
                replacement.terminate()
                replacement.wait(timeout=5)

        def crash_windows_and_server_change():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            client, start_identity = start_client()
            before = durable_intent(owner, launchd, pane, sequence, client, start_identity)
            client.terminate()
            client.wait(timeout=5)
            deadline = time.monotonic() + 5
            pending = {}
            while time.monotonic() < deadline:
                pending = json.load(open(before, encoding="utf-8"))
                if pending.get("diagnostic") == "pending: acquisition outcome unknown":
                    break
                time.sleep(0.05)
            require({"step": "unacknowledged-acquisition"}, pending.get("phase") == "intent" and pending.get("diagnostic") == "pending: acquisition outcome unknown", "an unacknowledged acquisition was discarded")
            absent = owner.state(pane["pane_id"], "crash-before-claim")
            require(absent, absent["agent"] is None, "intent before claim created a Herdr record")
            # The original request reaches the server after the exit was seen.
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
            wait_for(before, "settled")
            delayed = owner.state(pane["pane_id"], "late-acquisition-recovered")
            require(delayed, delayed["agent"] is None, "a late acquisition escaped cleanup")
            client, start_identity = start_client()
            after_claim = durable_intent(owner, launchd, pane, sequence + 20, client, start_identity)
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence + 20)
            client.terminate()
            client.wait(timeout=5)
            wait_for(after_claim, "settled")
            released = owner.state(pane["pane_id"], "crash-after-claim-before-acknowledgment")
            require(released, released["agent"] is None, "unacknowledged acquired claim survived")
            client, start_identity = start_client()
            renamed = durable_intent(owner, launchd, pane, sequence + 40, client, start_identity)
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence + 40)
            acknowledge_acquisition(renamed)
            owner.run("agent", "rename", pane["pane_id"], f"mms377-win-{sequence % 1_000_000_000}")
            client.terminate()
            client.wait(timeout=5)
            wait_for(renamed, "settled")
            clean = owner.state(pane["pane_id"], "crash-after-rename")
            require(clean, clean["agent"] is None, "renamed claim survived cleanup")

        def source_scoped_clear_limit():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            alias = f"mms377-clear-{os.getpid()}"
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
            owner.run("agent", "rename", pane["pane_id"], alias)
            owner.clear_authority(pane["pane_id"], OLD_SOURCE, sequence + 1)
            stale = owner.state(pane["pane_id"], "source-scoped-clear-after-old-claim")
            record = stale["agent"] or {}
            require(stale, record.get("agent") is None, "clear retained lifecycle authority")
            require(stale, record.get("name") == alias, "clear unexpectedly removed stale alias")

        def pending_managed_native_successor():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            alias = f"mms377-pending-{os.getpid()}"
            barrier = os.path.join(owner.root, "claude-barrier")
            release_barrier = os.path.join(owner.root, "claude-release")
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
            report(owner, pane["pane_id"], "mms-377-successor", "working", sequence + 10)
            release(owner, pane["pane_id"], "mms-377-successor", sequence + 11)
            before = owner.state(pane["pane_id"], "foreign-released-before-pending-launch")
            require(before, before["agent"] is None, "foreign release did not settle old record")
            function = (
                f"function claude() {{ : > {barrier}; while [[ ! -f {release_barrier} ]]; do sleep 0.1; done; "
                f"exec {native_claude} \"$@\"; }}"
            )
            owner.run("pane", "run", pane["pane_id"], function)
            command = ["herdr", "--session", owner.session, "agent", "start", alias, "--kind", "claude",
                       "--pane", pane["pane_id"], "--timeout", "5000"]
            started = subprocess.Popen(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=owner.env)
            deadline = time.monotonic() + 5
            while not os.path.exists(barrier) and time.monotonic() < deadline:
                time.sleep(0.05)
            if not os.path.exists(barrier):
                started.terminate()
                started.wait(timeout=5)
                raise ProbeError("agent start did not invoke the owned Claude barrier")
            pending = owner.state(pane["pane_id"], "managed-native-launch-pending")
            record = pending["agent"] or {}
            require(pending, record.get("terminal_id") == pane["terminal_id"], "pending launch changed terminal")
            require(pending, record.get("name") == alias, "pending launch alias changed")
            require(pending, record.get("agent") is None, "pending launch was already detectable")
            require(pending, record.get("agent_status") == "unknown", "pending launch state is not unknown")
            release(owner, pane["pane_id"], OLD_SOURCE, sequence + 1)
            preserved = owner.state(pane["pane_id"], "old-release-during-managed-pending")
            after = preserved["agent"] or {}
            require(preserved, after.get("terminal_id") == pane["terminal_id"], "old release retargeted pending terminal")
            require(preserved, after.get("name") == alias, "old release removed pending alias")
            require(preserved, after.get("agent") is None and after.get("agent_status") == "unknown", "old release changed pending launch state")
            open(release_barrier, "w").close()
            started.terminate()
            started.wait(timeout=10)

        def repeated_and_closed_resource():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            client, start_identity = start_client()
            intent = durable_intent(owner, launchd, pane, sequence, client, start_identity)
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
            acknowledge_acquisition(intent)
            second_owner = LaunchdOwner(owner.root)
            second_owner.pid_file = os.path.join(owner.root, "observer-second.pid.json")
            second_owner.start()
            client.terminate()
            client.wait(timeout=5)
            try:
                wait_for(intent, "settled")
            finally:
                second_owner.close()
            settled = owner.state(pane["pane_id"], "repeated-clear")
            require(settled, settled["agent"] is None, "repeated clear recreated a claim")
            # Simulate a crash after Herdr accepted the release and before local retirement.
            post_release = json.load(open(intent, encoding="utf-8"))
            post_release["phase"] = "acquired"
            atomic_write(intent, post_release)
            wait_for(intent, "settled")
            owner.run("pane", "close", pane["pane_id"])
            atomic_write(intent, post_release)
            closed = wait_for(intent, "settled")
            require({"step": "closed-terminal"}, closed.get("diagnostic") == "settled: terminal resource gone", "closed terminal was not verified before retirement")

        def real_server_restart_settles_only_gone_terminal():
            nonlocal root
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            client, start_identity = start_client()
            barrier = os.path.join(owner.root, f"server-restart-{client.pid}")
            intent = durable_intent(owner, launchd, pane, sequence, client, start_identity, barrier)
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
            acknowledge_acquisition(intent)
            client.terminate()
            client.wait(timeout=5)
            deadline = time.monotonic() + 5
            while not os.path.exists(barrier + ".checked") and time.monotonic() < deadline:
                time.sleep(0.05)
            require({"step": "server-restart-barrier"}, os.path.exists(barrier + ".checked"), "observer did not read old terminal before restart")
            old_server = capture_server_identity(owner.socket_path)
            owner.run("server", "stop")
            owner.client.wait(timeout=5)
            root = owner.start()
            new_server = capture_server_identity(owner.socket_path)
            require({"step": "server-restart-identity"}, old_server != new_server, f"server process did not change: {old_server}")
            new_pane = create_pane(owner, root)
            new_alias = f"mms377-new-server-{os.getpid()}"
            report(owner, new_pane["pane_id"], "mms-377-new-server-owner", "working", time.time_ns())
            owner.run("agent", "rename", new_pane["pane_id"], new_alias)
            open(barrier + ".continue", "w").close()
            diagnostic = wait_for(intent, "retired")
            require({"step": "real-server-restart"}, diagnostic.get("diagnostic") == "retired: original server instance ended", f"new server was not fenced: {diagnostic}")
            untouched = owner.state(new_pane["pane_id"], "new-server-owner-preserved")
            require_agent(untouched, status="working", terminal=new_pane["terminal_id"], alias=new_alias)
            owner.events.append({"server_before": old_server, "server_after": new_server, "retained_intent": diagnostic})

        case(owner, "failed process lookup preserves a live claim", failed_process_lookup_preserves_live_claim, verdicts)
        case(owner, "launchd restarts killed observer and it cleans actual client exit", observer_exit_restart_and_cleanup, verdicts)
        case(owner, "same-source successor and delayed old clear", same_source_successor, verdicts)
        case(owner, "lifecycle takeover retires bookkeeping without releasing its owner", takeover_retires_only_bookkeeping, verdicts)
        case(owner, "moved pane follows stable terminal identity", moved_terminal_follows_stable_identity, verdicts)
        case(owner, "fenced newer same-source claim survives old cleanup", fenced_newer_claim_survives_cleanup, verdicts)
        case(owner, "unavailable socket retries and stale PID identity is not live", unavailable_socket_then_recovery_and_stale_pid, verdicts)
        case(owner, "crash windows and server instance change retain safe obligation", crash_windows_and_server_change, verdicts)
        case(owner, "source-scoped clear leaves a renamed stale claim", source_scoped_clear_limit, verdicts)
        case(owner, "delayed old release preserves pending managed native successor", pending_managed_native_successor, verdicts)
        case(owner, "repeated cleanup and closed resource", repeated_and_closed_resource, verdicts)
        case(owner, "server restart prevents stale cleanup from retargeting", real_server_restart_settles_only_gone_terminal, verdicts)
        artifact_root = os.environ.get(EVIDENCE_DIR, os.path.join(tempfile.gettempdir(), "mms377-proof"))
        os.makedirs(artifact_root, exist_ok=True)
        artifact = os.path.join(artifact_root, f"ownership-proof-{int(time.time())}.json")
        with open(artifact, "w", encoding="utf-8") as handle:
            json.dump({"version": run("--version").stdout.strip(), "verdicts": verdicts, "transitions": owner.events}, handle, indent=2)
        print(f"EVIDENCE: {artifact}")
        failures = [item for item in verdicts if item[1] != "PASS"]
        if failures:
            return 1
        print("UNVERIFIED: native client controls, Claude/cci relation, OpenCode, Pi, and full gate remain.")
        return 1
    finally:
        for client in OWNED_CLIENTS:
            if client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
        if launchd:
            launchd.close()
        owner.close()
        print(f"CLEANUP: booted out launchd job and stopped owned session {owner.session}; removed {owner.root}.")


if __name__ == "__main__":
    sys.exit(main())
