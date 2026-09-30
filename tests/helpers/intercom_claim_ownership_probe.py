#!/usr/bin/env python3
"""Opt-in real-Herdr conformance probe for launch-claim cleanup ownership."""

import argparse
import json
import fcntl
import os
import pty
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import uuid
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
AGENT = "claude"
OWNED_CLIENTS = []
OWNED_OBSERVERS = []


class ProbeError(Exception):
    pass


def native_executable(name):
    result = subprocess.run(
        ["zsh", "-fc", f"whence -pa {name}"], text=True, capture_output=True, check=False
    )
    for path in result.stdout.splitlines():
        if not os.path.isfile(path) or not os.access(path, os.X_OK):
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
        self.master = None
        self.master_reader = None
        self.server_identity = None
        self.events = []

    @property
    def env(self):
        env = os.environ.copy()
        for name in tuple(env):
            if name.startswith(("HERDR_", "AGENT_INTERCOM_", "CLAUDE_INTERCOM_")) or name in {
                "MMS377_INTENT", "OPENCODE_INTERCOM_NAME",
            }:
                env.pop(name)
        env["XDG_CONFIG_HOME"] = self.root
        env["XDG_STATE_HOME"] = os.path.join(self.root, "state")
        env["COLUMNS"] = "160"
        env["LINES"] = "40"
        return env

    @property
    def socket_path(self):
        return os.path.join(self.root, "herdr", "sessions", self.session, "herdr.sock")

    def run(self, *args, expected=0):
        return run(*args, expected=expected, env=self.env, session=self.session)

    def start(self):
        pty_errors = []
        self._close_master(pty_errors)
        if pty_errors:
            raise ProbeError("; ".join(pty_errors))
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 160, 0, 0))
        self.master = master
        def own_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        self.client = subprocess.Popen(
            ["herdr", "--session", self.session], stdin=slave, stdout=slave, stderr=slave,
            env=self.env, close_fds=True, preexec_fn=own_terminal,
        )
        os.close(slave)
        self.master_reader = threading.Thread(target=self._drain_master, args=(master,), daemon=True)
        self.master_reader.start()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            status = subprocess.run(
                ["herdr", "--session", self.session, "status", "server"], text=True,
                capture_output=True, env=self.env, timeout=15, check=False,
            )
            if status.returncode == 0 and "status: running" in status.stdout:
                self.server_identity = capture_server_identity(self.socket_path)
                return self.snapshot()["panes"][0]
            if self.client.poll() is not None:
                raise ProbeError("owned Herdr client exited before its server became ready")
            time.sleep(0.1)
        raise ProbeError("owned Herdr server did not become ready within 10 seconds")

    def _drain_master(self, master):
        try:
            while os.read(master, 65536):
                pass
        except OSError:
            pass

    def _close_master(self, errors):
        if self.master is not None:
            try:
                os.close(self.master)
            except OSError as error:
                errors.append(f"could not close owned Herdr PTY: {error}")
            self.master = None
        if self.master_reader:
            self.master_reader.join(timeout=5)
            if self.master_reader.is_alive():
                errors.append("owned Herdr PTY reader did not exit")
            self.master_reader = None

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

    def close(self, remove_root=True):
        errors = []
        try:
            self.run("session", "stop", self.session)
        except Exception as error:
            errors.append(str(error))
            try:
                self.run("server", "stop")
            except Exception as stop_error:
                errors.append(str(stop_error))
        if self.client:
            try:
                self.client.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    self.client.terminate()
                    self.client.wait(timeout=5)
                except (subprocess.TimeoutExpired, OSError) as error:
                    errors.append(f"owned Herdr client did not exit: {error}")
                    try:
                        self.client.kill()
                        self.client.wait(timeout=5)
                    except (subprocess.TimeoutExpired, OSError) as kill_error:
                        errors.append(f"owned Herdr client could not be reaped: {kill_error}")
        self._close_master(errors)
        try:
            self.run("session", "delete", self.session)
        except Exception as error:
            errors.append(str(error))
        server_gone = False
        if self.server_identity:
            deadline = time.monotonic() + 5
            try:
                while time.monotonic() < deadline:
                    server_gone = process_start_identity(self.server_identity["pid"]) != self.server_identity["start_identity"]
                    if server_gone:
                        break
                    time.sleep(0.05)
            except recovery_prototype.RecoveryError as error:
                errors.append(str(error))
        else:
            server_gone = not os.path.exists(self.socket_path)
        if remove_root:
            if not server_gone or (self.client and self.client.poll() is None):
                errors.append("preserved owned Herdr tree because its server/client exit is unconfirmed")
            elif not errors:
                shutil.rmtree(self.root)
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


def start_client(seconds=30):
    client = subprocess.Popen([sys.executable, "-c", f"import time; time.sleep({seconds})"])
    OWNED_CLIENTS.append(client)
    start = process_start_identity(client.pid)
    if not start:
        raise ProbeError("could not capture client process-start identity")
    return client, start


def durable_intent(owner, intent_dir, pane, sequence, client, start_identity, barrier=None,
                   entry_barrier=None, trace_dir=None):
    launch_id = f"launch-{client.pid}-{sequence}-{uuid.uuid4().hex}"
    intent = {
        "launch_id": launch_id,
        "phase": "intent",
        "connection": {
            "session": owner.session,
            "socket_path": owner.socket_path,
            "socket_identity": socket_identity(owner.socket_path),
            "server_identity": capture_server_identity(owner.socket_path),
        },
        "terminal": {"pane_id": pane["pane_id"], "terminal_id": pane["terminal_id"]},
        "agent_kind": AGENT,
        "claim": {"source": OLD_SOURCE, "claim_seq": sequence,
                  "handoff_seq": sequence + 1, "release_seq": sequence + 2},
        "client": {"pid": client.pid, "start_identity": start_identity},
        "created_at_ns": time.time_ns(),
    }
    if barrier:
        intent["barrier"] = barrier
    if entry_barrier:
        intent["entry_barrier"] = entry_barrier
    if trace_dir:
        intent["trace_dir"] = trace_dir
    path = write_intent(intent_dir, intent)
    return path


def wait_for(path, phase, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        intent = recovery_prototype.read_intent(path)
        if intent.get("phase") == phase:
            return intent
        time.sleep(0.05)
    raise ProbeError(f"intent did not reach {phase}: {path}; last={intent}")


def wait_for_file(path, description, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            return path
        time.sleep(0.05)
    raise ProbeError(f"timed out waiting for {description}: {path}")


def wait_for_trace_event(trace_dir, suffix, description, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        matches = [entry for entry in os.listdir(trace_dir) if entry.endswith(suffix)]
        if matches:
            return json.load(open(os.path.join(trace_dir, matches[-1]), encoding="utf-8"))
        time.sleep(0.05)
    raise ProbeError(f"timed out waiting for {description} in {trace_dir}")


def wait_for_entries(directory, predicate, count, description, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        entries = [entry for entry in os.listdir(directory) if predicate(entry)]
        if len(entries) >= count:
            return entries
        time.sleep(0.05)
    raise ProbeError(f"timed out waiting for {count} {description} in {directory}")




def claim_and_confirm(owner, pane, source, sequence, step):
    report(owner, pane["pane_id"], source, "unknown", sequence)
    claimed = owner.state(pane["pane_id"], step)
    # A custom claim has no agent_session. That field identifies a client's
    # session integration, not the source that holds lifecycle authority.
    require_agent(claimed, status="unknown", terminal=pane["terminal_id"])
    return claimed


def claim_and_acknowledge(owner, intent, pane, source, sequence, step):
    claimed = claim_and_confirm(owner, pane, source, sequence, step)
    acknowledge_acquisition(intent)
    return claimed


def case(owner, name, action, verdicts):
    try:
        action()
    except Exception as error:
        verdicts.append((name, "FAIL", f"{type(error).__name__}: {error}"))
        print(f"FAIL: {name}: {type(error).__name__}: {error}")
    else:
        verdicts.append((name, "PASS", "observed"))
        print(f"PASS: {name}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--case", choices=("all", "allocator-controls"), default="all")
    parser.add_argument("--allocator-implementation", choices=("shared", "legacy"), default="shared")
    arguments = parser.parse_args()
    if os.environ.get(OPT_IN) != "1":
        print(f"REFUSED: set {OPT_IN}=1 to create an isolated owned Herdr server.")
        return 2
    if os.environ.get("HERDR_ENV") != "1":
        print("REFUSED: this probe must run from a Herdr-managed pane.")
        return 2

    owner = OwnedHerdr()
    verdicts = []
    launchd = None
    artifact_root = os.environ.get(EVIDENCE_DIR, os.path.join(tempfile.gettempdir(), "mms377-proof"))
    os.makedirs(artifact_root, exist_ok=True)
    artifact = os.path.join(artifact_root, f"ownership-proof-{uuid.uuid4().hex}.json")
    outcome = 1
    try:
        root = owner.start()
        launchd = LaunchdOwner(owner.root)
        OWNED_OBSERVERS.append(launchd)
        launchd.start()

        def native_binding_serializes_with_cleanup():
            pane = create_pane(owner, root)
            key = os.path.join(owner.root, "bind-" + uuid.uuid4().hex)
            gate, result_path, barrier = key + ".start", key + ".result", key + ".barrier"
            trace_dir = key + ".trace"
            os.mkdir(trace_dir)
            binder_code = (
                "import os,sys,time; "
                f"sys.path.insert(0,{os.path.dirname(__file__)!r}); "
                "import intercom_claim_recovery_prototype as p; "
                "bound=p.bind_native_client(sys.argv[1]); "
                "p.atomic_write(sys.argv[2],{'bound':bound,'pid':os.getpid(),"
                "'start_identity':p.process_start_identity(os.getpid())}); "
                "os.execv(sys.executable,[sys.executable,'-c','import time; time.sleep(30)'])"
            )
            launcher_code = (
                "import json,os,subprocess,sys,time\n"
                "deadline=time.monotonic()+10\n"
                "while not os.path.exists(sys.argv[1]):\n"
                " if time.monotonic()>deadline: raise SystemExit(2)\n"
                " time.sleep(0.05)\n"
                "data=json.load(open(sys.argv[1]))\n"
                "child=subprocess.Popen([sys.executable,'-c',sys.argv[2],data['intent'],data['result']])\n"
                "child.wait()\n"
            )
            launcher = subprocess.Popen([sys.executable, "-c", launcher_code, gate, binder_code],
                                        env={**os.environ, "AGENT_INTERCOM_CLAUDE_COMMAND": sys.executable})
            OWNED_CLIENTS.append(launcher)
            sequence = time.time_ns()
            intent_path = durable_intent(owner, launchd.intent_dir, pane, sequence, launcher,
                                         process_start_identity(launcher.pid), trace_dir=trace_dir)
            binder = None
            try:
                with recovery_prototype.intent_lock(intent_path, timeout=5):
                    intent = recovery_prototype.read_json(intent_path)
                    intent["bind_barrier"] = barrier
                    atomic_write(intent_path, intent)
                claim_and_acknowledge(owner, intent_path, pane, OLD_SOURCE, sequence, "native-binding-claimed")
                atomic_write(gate, {"intent": intent_path, "result": result_path})
                wait_for_file(barrier + ".checked", "binding after live-parent check")
                binder_pid = recovery_prototype.read_json(barrier + ".checked")["pid"]
                binder = {"pid": binder_pid, "start_identity": process_start_identity(binder_pid)}
                launcher.kill()
                launcher.wait(timeout=5)
                after_exit = time.monotonic_ns()
                observer_pid = recovery_prototype.read_json(launchd.pid_file)["pid"]
                attempt_path = os.path.join(trace_dir, f"{observer_pid}.attempt_complete.json")
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if os.path.exists(attempt_path) and recovery_prototype.read_json(attempt_path)["started_monotonic_ns"] > after_exit:
                        break
                    time.sleep(0.05)
                else:
                    raise ProbeError("observer did not contend with native binding after launcher exit")
                held = owner.state(pane["pane_id"], "binding-lock-preserves-claim")
                require_agent(held, status="unknown", terminal=pane["terminal_id"])
                open(barrier + ".continue", "w").close()
                wait_for_file(result_path, "native binding result")
                result = recovery_prototype.read_json(result_path)
                require({"step": "native-binding-result"}, result["bound"] is True, "binding lost the live native process")
                saved = recovery_prototype.read_json(intent_path)
                require({"step": "native-binding-owner"}, saved["client"] == binder, "binding did not replace the launcher identity")
                require({"step": "native-binding-live"}, process_start_identity(binder_pid) == binder["start_identity"],
                        "native process did not survive launcher exit")
                recovery_prototype.observe_one(intent_path)
                require_agent(owner.state(pane["pane_id"], "bound-live-native"), status="unknown", terminal=pane["terminal_id"])
                os.kill(binder_pid, signal.SIGKILL)
                wait_for(intent_path, "settled")
                ended = owner.state(pane["pane_id"], "bound-native-exited")
                require(ended, ended["agent"] is None, "native exit did not settle its claim")
                owner.events.append({"native_binding": result, "launcher_pid": launcher.pid})
            finally:
                open(barrier + ".continue", "w").close()
                if binder and process_start_identity(binder["pid"]) == binder["start_identity"]:
                    os.kill(binder["pid"], signal.SIGKILL)
                if launcher.poll() is None:
                    launcher.kill()
                    launcher.wait(timeout=5)

        def late_native_binding_is_refused():
            pane = create_pane(owner, root)
            launcher, start = start_client()
            sequence = time.time_ns()
            path = durable_intent(owner, os.path.join(owner.root, "identity-checks"),
                                  pane, sequence, launcher, start)
            claim_and_acknowledge(owner, path, pane, OLD_SOURCE, sequence, "late-binding-claimed")
            launcher.terminate()
            launcher.wait(timeout=5)
            code = (
                "import json,sys; "
                f"sys.path.insert(0,{os.path.dirname(__file__)!r}); "
                "import intercom_claim_recovery_prototype as p; "
                "print(json.dumps({'bound':p.bind_native_client(sys.argv[1])}))"
            )
            for phase in ("acquired", "settled"):
                before = recovery_prototype.read_intent(path)
                require({"step": "late-binding-phase"}, before["phase"] == phase, "late binding control has the wrong phase")
                attempt = subprocess.run([sys.executable, "-c", code, path], text=True, capture_output=True, timeout=10)
                require({"step": "late-binding-status"}, attempt.returncode == 0, f"late binder failed to execute: {attempt.stderr}")
                require({"step": "late-binding-refused"}, json.loads(attempt.stdout) == {"bound": False},
                        "a late bridge adopted the exited launch")
                require({"step": "late-binding-record"}, recovery_prototype.read_intent(path) == before,
                        "a refused bridge changed the durable intent")
                recovery_prototype.observe_one(path)
            ended = owner.state(pane["pane_id"], "late-binding-old-claim-settled")
            require(ended, ended["agent"] is None, "refused late binding prevented cleanup")

        def probe_owner_exit_unregisters_observer():
            controller, start = start_client()
            temporary = LaunchdOwner(owner.root, {"pid": controller.pid, "start_identity": start})
            OWNED_OBSERVERS.append(temporary)
            try:
                observed = temporary.start()
                controller.terminate()
                controller.wait(timeout=5)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    job = subprocess.run(["launchctl", "print", f"{temporary.domain}/{temporary.label}"],
                                         text=True, capture_output=True, check=False, timeout=5)
                    absent = job.returncode != 0 and "Could not find service" in job.stderr
                    exited = process_start_identity(observed["pid"]) != observed["start_identity"]
                    if absent and exited:
                        break
                    time.sleep(0.1)
                else:
                    raise ProbeError("abandoned proof observer did not unregister and exit")
                owner.events.append({"abandoned_probe_owner": {"pid": controller.pid, "start_identity": start},
                                     "unregistered_job": temporary.label, "exited_observer": observed})
            finally:
                temporary.close()
                OWNED_OBSERVERS.remove(temporary)

        def failed_process_lookup_preserves_live_claim():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            client, start_identity = start_client()
            intent = durable_intent(owner, os.path.join(owner.root, "identity-checks"), pane, sequence, client, start_identity)
            claim_and_acknowledge(owner, intent, pane, OLD_SOURCE, sequence, "failed-lookup-claimed")
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
                record = recovery_prototype.read_intent(intent)
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
            intent = durable_intent(owner, launchd.intent_dir, pane, sequence, client, start_identity)
            claim_and_acknowledge(owner, intent, pane, OLD_SOURCE, sequence, "restart-claimed")
            alias = f"mms377-owner-{os.getpid()}"
            owner.run("agent", "rename", pane["pane_id"], alias)
            claimed = owner.state(pane["pane_id"], "durable-claim-before-client-exit")
            require_agent(claimed, status="unknown", terminal=pane["terminal_id"], alias=alias)
            killed_observer = json.load(open(launchd.pid_file, encoding="utf-8"))
            restarted_observer = launchd.kill_observer()
            require({"step": "observer-restarted"}, restarted_observer["pid"] != killed_observer["pid"], "launchd did not replace its observer")
            owner.events.append({"killed_observer": killed_observer, "restarted_observer": restarted_observer})
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
            release(owner, pane["pane_id"], OLD_SOURCE, sequence + 2)
            preserved = owner.state(pane["pane_id"], "old-release-after-same-source-successor")
            require_agent(preserved, status="working", terminal=pane["terminal_id"], alias=f"mms377-same-{sequence}")
            release(owner, pane["pane_id"], OLD_SOURCE, sequence + 11)
            settled = owner.state(pane["pane_id"], "same-source-successor-own-clear")
            require(settled, settled["agent"] is None, "successor did not settle its own claim")

        def takeover_retires_only_bookkeeping():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            client, start_identity = start_client()
            intent = durable_intent(owner, launchd.intent_dir, pane, sequence, client, start_identity)
            claim_and_acknowledge(owner, intent, pane, OLD_SOURCE, sequence, "takeover-claimed")
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
            intent = durable_intent(owner, launchd.intent_dir, pane, sequence, client, start_identity)
            claim_and_acknowledge(owner, intent, pane, OLD_SOURCE, sequence, "move-claimed")
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
            trace_dir = os.path.join(owner.root, f"fence-trace-{uuid.uuid4().hex}")
            os.mkdir(trace_dir)
            intent = durable_intent(owner, launchd.intent_dir, pane, sequence, client, start_identity, barrier, trace_dir=trace_dir)
            claim_and_acknowledge(owner, intent, pane, OLD_SOURCE, sequence, "fence-claimed")
            try:
                client.terminate()
                client.wait(timeout=5)
                wait_for_file(barrier + ".checked", "the fenced observer read")
                report(owner, pane["pane_id"], OLD_SOURCE, "working", sequence + 10)
                alias = f"mms377-newer-{client.pid}"
                owner.run("agent", "rename", pane["pane_id"], alias)
                open(barrier + ".continue", "w").close()
                release_result = wait_for_trace_event(trace_dir, ".release_result.json", "the fenced release result")
                response = release_result["response"]
                require({"step": "fenced-release"}, "error" not in response and response.get("result", {}).get("type") == "ok",
                        f"fenced release was rejected: {response}")
                survivor = owner.state(pane["pane_id"], "fenced-old-release-after-newer-same-source-claim")
                require_agent(survivor, status="working", terminal=pane["terminal_id"], alias=alias)
                release(owner, pane["pane_id"], OLD_SOURCE, sequence + 11)
                settled = owner.state(pane["pane_id"], "newer-claim-own-release")
                require(settled, settled["agent"] is None, "newer claim did not settle")
            finally:
                open(barrier + ".continue", "a").close()

        def unknown_newer_claim_stays_pending_and_preserved():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            client, start_identity = start_client()
            barrier = os.path.join(owner.root, f"unknown-successor-{client.pid}")
            intent = durable_intent(owner, launchd.intent_dir, pane, sequence, client, start_identity, barrier)
            claim_and_acknowledge(owner, intent, pane, OLD_SOURCE, sequence, "unknown-successor-claimed")
            try:
                client.terminate()
                client.wait(timeout=5)
                wait_for_file(barrier + ".checked", "old observation before unknown successor")
                report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence + 10)
                successor = owner.state(pane["pane_id"], "unknown-newer-claim-published")
                require_agent(successor, status="unknown", terminal=pane["terminal_id"])
                open(barrier + ".continue", "w").close()
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    pending = recovery_prototype.read_intent(intent)
                    if pending.get("diagnostic") == "pending: release acknowledged but claim still published":
                        break
                    time.sleep(0.05)
                require({"step": "unknown-newer-claim"}, pending.get("phase") == "acquired", "unknown newer claim was retired without an ownership witness")
                require({"step": "unknown-newer-claim"}, pending.get("diagnostic") == "pending: release acknowledged but claim still published", "unknown newer claim did not retain explicit uncertainty")
                preserved = owner.state(pane["pane_id"], "unknown-newer-claim-preserved")
                require_agent(preserved, status="unknown", terminal=pane["terminal_id"])
            finally:
                open(barrier + ".continue", "a").close()
                release(owner, pane["pane_id"], OLD_SOURCE, sequence + 11)

        def unavailable_socket_then_recovery_and_stale_pid():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            client, start_identity = start_client()
            intent = durable_intent(owner, launchd.intent_dir, pane, sequence, client, start_identity)
            claim_and_acknowledge(owner, intent, pane, OLD_SOURCE, sequence, "socket-claimed")
            hidden = owner.socket_path + ".unavailable"
            os.rename(owner.socket_path, hidden)
            try:
                client.terminate()
                client.wait(timeout=5)
                deadline = time.monotonic() + 5
                pending = {}
                while time.monotonic() < deadline:
                    pending = recovery_prototype.read_intent(intent)
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
            saved_start = replacement_start
            modeled_replacement_start = f"modeled-replacement-{uuid.uuid4().hex}"
            replacement_pane = create_pane(owner, root)
            other_sequence = time.time_ns()
            # The kernel keeps replacement.pid alive. The seam models a later
            # incarnation of that same PID with a distinct independently saved token.
            old_incarnation = durable_intent(owner, os.path.join(owner.root, "identity-checks"), replacement_pane,
                                            other_sequence, replacement, saved_start)
            claim_and_acknowledge(owner, old_incarnation, replacement_pane, OLD_SOURCE, other_sequence, "old-incarnation-claimed")
            try:
                native_process_reader = recovery_prototype.process_start_identity

                def modeled_process_reader(pid):
                    if pid == replacement.pid:
                        return modeled_replacement_start
                    return native_process_reader(pid)

                with patch.object(recovery_prototype, "process_start_identity", modeled_process_reader):
                    recovery_prototype.observe_one(old_incarnation)
                require({"step": "real-process-identity"}, recovery_prototype.process_start_identity(replacement.pid) == saved_start,
                        "the incarnation seam changed the real process")
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
            delayed_barrier = os.path.join(owner.root, f"delayed-acquisition-{uuid.uuid4().hex}")
            before = durable_intent(owner, launchd.intent_dir, pane, sequence, client, start_identity, delayed_barrier)
            client.terminate()
            client.wait(timeout=5)
            deadline = time.monotonic() + 5
            pending = {}
            while time.monotonic() < deadline:
                pending = recovery_prototype.read_intent(before)
                if pending.get("diagnostic") == "pending: acquisition outcome unknown":
                    break
                time.sleep(0.05)
            require({"step": "unacknowledged-acquisition"}, pending.get("phase") == "intent" and pending.get("diagnostic") == "pending: acquisition outcome unknown", "an unacknowledged acquisition was discarded")
            absent = owner.state(pane["pane_id"], "crash-before-claim")
            require(absent, absent["agent"] is None, "intent before claim created a Herdr record")
            # The original request reaches the server after the exit was seen.
            try:
                report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
                wait_for_file(delayed_barrier + ".checked", "the delayed acquisition pre-release barrier", timeout=5)
                late_claim = owner.state(pane["pane_id"], "late-acquisition-claimed")
                require_agent(late_claim, status="unknown", terminal=pane["terminal_id"])
                open(delayed_barrier + ".continue", "w").close()
                wait_for(before, "settled")
            finally:
                open(delayed_barrier + ".continue", "a").close()
            delayed = owner.state(pane["pane_id"], "late-acquisition-recovered")
            require(delayed, delayed["agent"] is None, "a late acquisition escaped cleanup")
            client, start_identity = start_client()
            after_claim = durable_intent(owner, launchd.intent_dir, pane, sequence + 20, client, start_identity)
            claim_and_confirm(owner, pane, OLD_SOURCE, sequence + 20, "crash-after-claim-before-acknowledgment")
            client.terminate()
            client.wait(timeout=5)
            wait_for(after_claim, "settled")
            released = owner.state(pane["pane_id"], "crash-after-claim-before-acknowledgment")
            require(released, released["agent"] is None, "unacknowledged acquired claim survived")
            client, start_identity = start_client()
            renamed = durable_intent(owner, launchd.intent_dir, pane, sequence + 40, client, start_identity)
            claim_and_acknowledge(owner, renamed, pane, OLD_SOURCE, sequence + 40, "crash-after-rename-claimed")
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
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
            report(owner, pane["pane_id"], "mms-377-successor", "working", sequence + 10)
            release(owner, pane["pane_id"], "mms-377-successor", sequence + 11)
            before = owner.state(pane["pane_id"], "foreign-released-before-pending-launch")
            require(before, before["agent"] is None, "foreign release did not settle old record")
            function = (
                f"function claude() {{ : > {barrier}; while :; do sleep 0.1; done; }}"
            )
            owner.run("pane", "run", pane["pane_id"], function)
            command = ["herdr", "--session", owner.session, "agent", "start", alias, "--kind", "claude",
                       "--pane", pane["pane_id"], "--timeout", "5000"]
            started = subprocess.Popen(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=owner.env)
            try:
                wait_for_file(barrier, "the pending native-launch barrier", timeout=5)
                pending = owner.state(pane["pane_id"], "managed-native-launch-pending")
                record = pending["agent"] or {}
                require(pending, record.get("terminal_id") == pane["terminal_id"], "pending launch changed terminal")
                require(pending, record.get("name") == alias, "pending launch alias changed")
                require(pending, record.get("agent") is None, "pending launch was already detectable")
                require(pending, record.get("agent_status") == "unknown", "pending launch state is not unknown")
                release(owner, pane["pane_id"], OLD_SOURCE, sequence + 2)
                preserved = owner.state(pane["pane_id"], "old-release-during-managed-pending")
                after = preserved["agent"] or {}
                require(preserved, after.get("terminal_id") == pane["terminal_id"], "old release retargeted pending terminal")
                require(preserved, after.get("name") == alias, "old release removed pending alias")
                require(preserved, after.get("agent") is None and after.get("agent_status") == "unknown", "old release changed pending launch state")
            finally:
                owner.run("pane", "close", pane["pane_id"], expected=None)
                if started.poll() is None:
                    started.terminate()
                try:
                    started.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    started.kill()
                    started.wait(timeout=5)

        def repeated_and_closed_resource():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            client, start_identity = start_client()
            entry_barrier = os.path.join(owner.root, f"concurrent-entry-{uuid.uuid4().hex}")
            trace_dir = os.path.join(owner.root, f"concurrent-trace-{uuid.uuid4().hex}")
            os.mkdir(trace_dir)
            intent = durable_intent(owner, launchd.intent_dir, pane, sequence, client, start_identity,
                                   entry_barrier=entry_barrier, trace_dir=trace_dir)
            claim_and_acknowledge(owner, intent, pane, OLD_SOURCE, sequence, "concurrent-claimed")
            before_retirement = recovery_prototype.read_intent(intent)
            second_owner = LaunchdOwner(owner.root)
            OWNED_OBSERVERS.append(second_owner)
            try:
                second_owner.start()
                client.terminate()
                client.wait(timeout=5)
                wait_for_entries(owner.root, lambda entry: entry.startswith(os.path.basename(entry_barrier) + ".checked."), 2,
                                           "observer entry barriers")
                open(entry_barrier + ".continue", "w").close()
                wait_for_entries(trace_dir, lambda entry: entry.endswith(".lock_attempt.json"), 2, "lock attempts")
                release_result = wait_for_trace_event(trace_dir, ".release_result.json", "an exact release result")
                response = release_result["response"]
                require({"step": "concurrent-release"}, "error" not in response and response.get("result", {}).get("type") == "ok",
                        f"concurrent release was rejected: {response}")
                wait_for(intent, "settled")
            finally:
                open(entry_barrier + ".continue", "a").close()
                second_owner.close()
                OWNED_OBSERVERS.remove(second_owner)
            settled = owner.state(pane["pane_id"], "repeated-clear")
            require(settled, settled["agent"] is None, "repeated clear recreated a claim")
            # Simulate a crash after Herdr accepted the release and before local retirement.
            # Replay the persisted pre-retirement image through the real writer.
            # Archived handles are immutable and their removed locks cannot be recreated.
            intent = write_intent(launchd.intent_dir, before_retirement)
            wait_for(intent, "settled")
            owner.run("pane", "close", pane["pane_id"])
            intent = write_intent(launchd.intent_dir, before_retirement)
            closed = wait_for(intent, "settled")
            require({"step": "closed-terminal"}, closed.get("diagnostic") == "settled: terminal resource gone", "closed terminal was not verified before retirement")

        def real_server_restart_settles_only_gone_terminal():
            nonlocal root
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            client, start_identity = start_client()
            barrier = os.path.join(owner.root, f"server-restart-{client.pid}")
            intent = durable_intent(owner, launchd.intent_dir, pane, sequence, client, start_identity, barrier)
            claim_and_acknowledge(owner, intent, pane, OLD_SOURCE, sequence, "server-restart-claimed")
            try:
                client.terminate()
                client.wait(timeout=5)
                wait_for_file(barrier + ".checked", "the observer old-terminal read", timeout=5)
                old_server = capture_server_identity(owner.socket_path)
                owner.run("server", "stop")
                owner.client.wait(timeout=5)
                root = owner.start()
                new_server = capture_server_identity(owner.socket_path)
                require({"step": "server-restart-identity"}, old_server != new_server, f"server process did not change: {old_server}")
                original = owner.state(pane["pane_id"], "original-terminal-absent-after-server-restart")
                require(original, original["agent"] is None, "original terminal record survived server restart")
                new_pane = create_pane(owner, root)
                new_alias = f"mms377-new-server-{os.getpid()}"
                report(owner, new_pane["pane_id"], "mms-377-new-server-owner", "working", time.time_ns())
                owner.run("agent", "rename", new_pane["pane_id"], new_alias)
                open(barrier + ".continue", "w").close()
                diagnostic = wait_for(intent, "retired")
                require({"step": "real-server-restart"}, diagnostic.get("diagnostic", "").startswith("retired:"), f"new server was not fenced: {diagnostic}")
                untouched = owner.state(new_pane["pane_id"], "new-server-owner-preserved")
                require_agent(untouched, status="working", terminal=new_pane["terminal_id"], alias=new_alias)
                owner.events.append({"server_before": old_server, "server_after": new_server, "retained_intent": diagnostic})
            finally:
                open(barrier + ".continue", "a").close()

        def ten_claims_meet_healthy_budget():
            cohort = []
            for index in range(10):
                pane = create_pane(owner, root)
                client, start = start_client(seconds=90)
                sequence = time.time_ns()
                path = durable_intent(owner, launchd.intent_dir, pane, sequence, client, start)
                claim_and_acknowledge(owner, path, pane, OLD_SOURCE, sequence, f"burst-{index}-claimed")
                cohort.append({"pane": pane, "client": client, "intent": path})
            published = json.loads(owner.run("agent", "list").stdout)["result"]["agents"]
            targets = {item["pane"]["pane_id"] for item in cohort}
            require({"step": "burst-presence"}, targets.issubset({item["pane_id"] for item in published}),
                    "burst did not establish all ten live claims")
            for item in cohort:
                item["client"].terminate()
                item["client"].wait(timeout=5)
                item["exit_observed"] = time.monotonic()
            latencies = {}
            deadline = time.monotonic() + 30
            while len(latencies) < len(cohort) and time.monotonic() < deadline:
                published = json.loads(owner.run("agent", "list").stdout)["result"]["agents"]
                live = {item["pane_id"] for item in published}
                observed = time.monotonic()
                for item in cohort:
                    pane_id = item["pane"]["pane_id"]
                    if pane_id not in live and pane_id not in latencies:
                        latencies[pane_id] = observed - item["exit_observed"]
                time.sleep(0.05)
            require({"step": "burst-absence"}, len(latencies) == 10, "not all burst claims disappeared")
            require({"step": "healthy-budget"}, max(latencies.values()) <= 10,
                    f"ten-second healthy recovery budget exceeded: {latencies}")
            for item in cohort:
                wait_for(item["intent"], "settled")
            owner.events.append({"healthy_budget_seconds": 10, "concurrent_claims": 10,
                                 "verified_absence_seconds": latencies})

        def allocator_controls():
            source = f"mms-377-allocator-{uuid.uuid4().hex}"
            sequence_dir = os.path.join(owner.root, "allocator-sequences")
            def reserve(wall_clock):
                with patch.object(recovery_prototype.time, "time_ns", return_value=wall_clock):
                    if arguments.allocator_implementation == "legacy":
                        # The former algorithm used the wall clock without a counter.
                        return time.time_ns()
                    return recovery_prototype.reserve_sequence(sequence_dir, source)

            old_sequence = reserve(9_000)
            later_sequence = reserve(1_000)
            owner.events.append({"allocator_reservations": {
                "implementation": arguments.allocator_implementation,
                "old_sequence": old_sequence,
                "later_sequence": later_sequence,
            }})
            pane = create_pane(owner, root)
            report(owner, pane["pane_id"], source, "unknown", old_sequence)
            report(owner, pane["pane_id"], source, "working", later_sequence)
            release(owner, pane["pane_id"], source, old_sequence + 2)
            survivor = owner.state(pane["pane_id"], "allocator-old-release-after-later-claim")
            require_agent(survivor, status="working", terminal=pane["terminal_id"])
            try:
                reservation_code = (
                    "import sys; "
                    "sys.path.insert(0, sys.argv[1]); "
                    "import intercom_claim_recovery_prototype as p; "
                    "p.time.time_ns = lambda: int(sys.argv[4]); "
                    "print(p.reserve_sequence(sys.argv[2], sys.argv[3]))"
                )

                def reserve_in_process(directory, reservation_source, wall_clock):
                    completed = subprocess.run(
                        [sys.executable, "-c", reservation_code, os.path.dirname(__file__),
                         directory, reservation_source, str(wall_clock)],
                        text=True, capture_output=True, timeout=10, check=False,
                    )
                    require({"step": "allocator-process-status"}, completed.returncode == 0,
                            f"reservation process failed: {completed.stderr.strip()}")
                    return int(completed.stdout.strip())

                restart_source = source + "-restart"
                restarted = [
                    reserve_in_process(sequence_dir, restart_source, 500),
                    reserve_in_process(sequence_dir, restart_source, 100),
                ]
                require({"step": "allocator-restart-persistence"}, restarted[1] > restarted[0] + 2,
                         f"process restart lost high-water state: {restarted}")
                concurrent_source = source + "-concurrent"
                processes = []
                for _ in range(4):
                    process = subprocess.Popen(
                        [sys.executable, "-c", reservation_code, os.path.dirname(__file__),
                         sequence_dir, concurrent_source, "200"],
                        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    )
                    processes.append(process)
                    OWNED_CLIENTS.append(process)
                concurrent = []
                for process in processes:
                    stdout, stderr = process.communicate(timeout=10)
                    require({"step": "allocator-concurrent-status"}, process.returncode == 0,
                            f"concurrent reservation failed: {stderr.strip()}")
                    concurrent.append(int(stdout.strip()))
                reserved = {sequence + offset for sequence in concurrent for offset in (0, 1, 2)}
                require({"step": "allocator-concurrent-reservations"}, len(reserved) == 12,
                         f"four concurrent three-operation reservations overlapped: {concurrent}")
                owner.events.append({"allocator": {
                    "implementation": arguments.allocator_implementation,
                    "old_sequence": old_sequence,
                    "later_sequence": later_sequence,
                    "restart_reservations": restarted,
                    "concurrent_reservations": sorted(concurrent),
                }})
            finally:
                release(owner, pane["pane_id"], source, later_sequence + 2)

        cases = [
            ("native binding serializes with cleanup after launcher death", native_binding_serializes_with_cleanup),
            ("late native binding cannot adopt an exited or settled launch", late_native_binding_is_refused),
            ("failed process lookup preserves a live claim", failed_process_lookup_preserves_live_claim),
            ("launchd restarts killed observer and it cleans actual client exit", observer_exit_restart_and_cleanup),
            ("abandoned proof owner unregisters its temporary observer", probe_owner_exit_unregisters_observer),
            ("same-source successor and delayed old clear", same_source_successor),
            ("lifecycle takeover retires bookkeeping without releasing its owner", takeover_retires_only_bookkeeping),
            ("moved pane follows stable terminal identity", moved_terminal_follows_stable_identity),
            ("fenced newer same-source claim survives old cleanup", fenced_newer_claim_survives_cleanup),
            ("unknown newer claim stays pending and preserved", unknown_newer_claim_stays_pending_and_preserved),
            ("unavailable socket retries and stale PID identity is not live", unavailable_socket_then_recovery_and_stale_pid),
            ("crash windows retain a safe obligation", crash_windows_and_server_change),
            ("source-scoped clear leaves a renamed stale claim", source_scoped_clear_limit),
            ("delayed old release preserves pending managed native successor", pending_managed_native_successor),
            ("repeated cleanup and closed resource", repeated_and_closed_resource),
            ("server restart prevents stale cleanup from retargeting", real_server_restart_settles_only_gone_terminal),
            ("ten simultaneous claims meet the healthy recovery budget", ten_claims_meet_healthy_budget),
            ("allocator controls preserve a later claim across wall-clock rollback", allocator_controls),
        ]
        for name, action in cases:
            if arguments.case == "all" or name.startswith("allocator controls"):
                case(owner, name, action, verdicts)
        failures = [item for item in verdicts if item[1] != "PASS"]
        if failures:
            outcome = 1
        else:
            print("UNVERIFIED: native client controls, Claude/cci relation, OpenCode, Pi, and full gate remain.")
            outcome = 3
    except Exception as error:
        verdicts.append(("probe setup", "FAIL", f"{type(error).__name__}: {error}"))
        print(f"FAIL: probe setup: {type(error).__name__}: {error}")
    finally:
        for client in OWNED_CLIENTS:
            if client.poll() is None:
                try:
                    client.terminate()
                    client.wait(timeout=5)
                except (OSError, subprocess.TimeoutExpired) as error:
                    verdicts.append(("client cleanup", "FAIL", f"{type(error).__name__}: {error}"))
                    try:
                        client.kill()
                        client.wait(timeout=5)
                    except (OSError, subprocess.TimeoutExpired) as kill_error:
                        verdicts.append(("client cleanup", "FAIL", f"could not reap child: {kill_error}"))
        launchd_stopped = True
        for observer in tuple(OWNED_OBSERVERS):
            try:
                observer.close()
            except Exception as error:
                launchd_stopped = False
                verdicts.append(("launchd cleanup", "FAIL", f"{type(error).__name__}: {error}"))
        if not launchd_stopped:
            verdicts.append(("launchd cleanup", "FAIL", "preserved scratch tree because observer could not be confirmed stopped"))
        try:
            owner.close(remove_root=launchd_stopped)
        except Exception as error:
            verdicts.append(("owned Herdr cleanup", "FAIL", f"{type(error).__name__}: {error}"))
        try:
            version = run("--version", expected=None).stdout.strip()
        except Exception as error:
            version = f"unavailable: {type(error).__name__}: {error}"
        try:
            with open(artifact, "w", encoding="utf-8") as handle:
                json.dump({"version": version, "verdicts": verdicts, "transitions": owner.events}, handle, indent=2)
            print(f"EVIDENCE: {artifact}")
        except OSError as error:
            print(f"FAIL: evidence write: {error}")
            outcome = 1
        if any(item[1] != "PASS" for item in verdicts):
            outcome = 1
        remaining = os.path.exists(owner.root)
        print(f"CLEANUP: {'preserved' if remaining else 'removed'} owned session tree {owner.root}; failures are recorded in the artifact.")
    return outcome


if __name__ == "__main__":
    sys.exit(main())
