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


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
OPT_IN = "MMS_LIVE_HERDR_OWNERSHIP_PROBE"
EVIDENCE_DIR = "MMS_LIVE_HERDR_OWNERSHIP_EVIDENCE_DIR"
OLD_SOURCE = "mms-377-old-launch"
CLAUDE_SOURCE = "herdr:claude"
AGENT = "claude"


class ProbeError(Exception):
    pass


def native_executable(name):
    result = subprocess.run(
        ["zsh", "-fc", f"whence -p {name}"], text=True, capture_output=True, check=False
    )
    path = result.stdout.strip()
    if result.returncode or not path or not os.path.isfile(path) or not os.access(path, os.X_OK):
        raise ProbeError(f"cannot resolve native {name} executable")
    if "herdr-agent-intercom" in os.path.basename(path):
        raise ProbeError(f"resolved {name} executable is an Intercom wrapper: {path}")
    return path


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


def write_intent(owner, pane, terminal, sequence, operation="release"):
    path = os.path.join(owner.root, "claim-intent.json")
    intent = {
        "config_root": owner.root,
        "session": owner.session,
        "pane": pane,
        "terminal_id": terminal,
        "source": OLD_SOURCE,
        "agent": AGENT,
        "release_seq": sequence,
        "operation": operation,
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(intent, handle)
    return path


def recover(intent_path):
    with open(intent_path, encoding="utf-8") as handle:
        intent = json.load(handle)
    env = os.environ.copy()
    for name in tuple(env):
        if name == "HERDR_ENV" or name.startswith("HERDR_"):
            env.pop(name)
    env["XDG_CONFIG_HOME"] = intent["config_root"]
    owner = OwnedHerdr.__new__(OwnedHerdr)
    owner.root = intent["config_root"]
    owner.session = intent["session"]
    owner.client = None
    owner.events = []
    owner_env = owner.env
    result = run("pane", "get", intent["pane"], env=owner_env, session=owner.session, expected=None)
    if result.returncode:
        if "pane_not_found" not in result.stderr:
            raise ProbeError(f"recovery could not inspect pane: {result.stderr.strip()}")
        print(json.dumps({"recovery": "settled-resource-gone", "pane": intent["pane"]}))
        return 0
    pane = json.loads(result.stdout)["result"]["pane"]
    if pane.get("terminal_id") != intent["terminal_id"]:
        raise ProbeError("recovery refused: terminal identity changed")
    if intent["operation"] == "clear":
        owner.clear_authority(intent["pane"], intent["source"], intent["release_seq"])
    else:
        owner.run("pane", "release-agent", intent["pane"], "--source", intent["source"],
                  "--agent", intent["agent"], "--seq", str(intent["release_seq"]))
    print(json.dumps({"recovery": f"{intent['operation']}-attempted", "pane": intent["pane"]}))
    return 0


def recovery_subprocess(intent_path):
    result = subprocess.run([sys.executable, __file__, "--recover", intent_path], text=True, capture_output=True, timeout=20, check=False)
    if result.returncode:
        raise ProbeError(f"restart owner failed: {result.stdout}{result.stderr}")
    print(result.stdout.strip())


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
    if len(sys.argv) == 3 and sys.argv[1] == "--recover":
        try:
            return recover(sys.argv[2])
        except (OSError, ProbeError, json.JSONDecodeError) as error:
            print(f"RECOVERY FAILED: {error}", file=sys.stderr)
            return 1
    if os.environ.get(OPT_IN) != "1":
        print(f"REFUSED: set {OPT_IN}=1 to create an isolated owned Herdr server.")
        return 2
    if os.environ.get("HERDR_ENV") != "1":
        print("REFUSED: this probe must run from a Herdr-managed pane.")
        return 2

    native_claude = native_executable("claude")
    owner = OwnedHerdr()
    verdicts = []
    try:
        root = owner.start()

        def crash_and_owner_restart():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
            alias = f"mms377-crash-{os.getpid()}"
            owner.run("agent", "rename", pane["pane_id"], alias)
            claimed = owner.state(pane["pane_id"], "old-claim")
            require_agent(claimed, status="unknown", terminal=pane["terminal_id"], alias=alias)
            intent = write_intent(owner, pane["pane_id"], pane["terminal_id"], sequence + 1)
            recovery_subprocess(intent)
            settled = owner.state(pane["pane_id"], "owner-restarted-release")
            require(settled, settled["agent"] is None, "old claim survived restarted owner cleanup")

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

        def native_takeover_and_handoff():
            pane = create_pane(owner, root)
            sequence = time.time_ns()
            alias = f"mms377-native-{os.getpid()}"
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
            claimed = owner.state(pane["pane_id"], "fresh-old-claim-before-native")
            require_agent(claimed, status="unknown", terminal=pane["terminal_id"])
            owner.run("agent", "rename", pane["pane_id"], alias)
            report(owner, pane["pane_id"], "mms-377-successor", "working", sequence + 10)
            takeover = owner.state(pane["pane_id"], "foreign-takeover-working")
            require_agent(takeover, status="working", terminal=pane["terminal_id"], alias=alias)
            owner.clear_authority(pane["pane_id"], OLD_SOURCE, sequence + 1)
            foreign = owner.state(pane["pane_id"], "old-clear-during-foreign-takeover")
            require_agent(foreign, status="working", terminal=pane["terminal_id"], alias=alias)
            owner.run("pane", "run", pane["pane_id"], native_claude)
            native = wait_for_native_session(owner, pane["pane_id"])
            require_agent(native, status="working", source=CLAUDE_SOURCE, terminal=pane["terminal_id"], alias=alias)
            release(owner, pane["pane_id"], "mms-377-successor", sequence + 11)
            handoff = owner.state(pane["pane_id"], "native-handoff")
            require_agent(handoff, terminal=pane["terminal_id"], alias=alias)
            require_rule(handoff)
            release(owner, pane["pane_id"], OLD_SOURCE, sequence + 1)
            delayed = owner.state(pane["pane_id"], "old-release-after-native-handoff")
            require_agent(delayed, terminal=pane["terminal_id"], alias=alias)
            require_rule(delayed)

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
            report(owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
            intent = write_intent(owner, pane["pane_id"], pane["terminal_id"], sequence + 1)
            recovery_subprocess(intent)
            recovery_subprocess(intent)
            settled = owner.state(pane["pane_id"], "repeated-clear")
            require(settled, settled["agent"] is None, "repeated clear recreated a claim")
            owner.run("pane", "close", pane["pane_id"])
            recovery_subprocess(intent)

        case(owner, "crash after declaration and restartable owner", crash_and_owner_restart, verdicts)
        case(owner, "same-source successor and delayed old clear", same_source_successor, verdicts)
        case(owner, "native Claude takeover handoff and delayed old clear", native_takeover_and_handoff, verdicts)
        case(owner, "source-scoped clear leaves a renamed stale claim", source_scoped_clear_limit, verdicts)
        case(owner, "delayed old release preserves pending managed native successor", pending_managed_native_successor, verdicts)
        case(owner, "repeated cleanup and closed resource", repeated_and_closed_resource, verdicts)
        artifact_root = os.environ.get(EVIDENCE_DIR, os.path.join(tempfile.gettempdir(), "mms377-proof"))
        os.makedirs(artifact_root, exist_ok=True)
        artifact = os.path.join(artifact_root, f"ownership-proof-{int(time.time())}.json")
        with open(artifact, "w", encoding="utf-8") as handle:
            json.dump({"version": run("--version").stdout.strip(), "verdicts": verdicts, "transitions": owner.events}, handle, indent=2)
        print(f"EVIDENCE: {artifact}")
        failures = [item for item in verdicts if item[1] != "PASS"]
        if failures:
            return 1
        print("UNVERIFIED: full crash, server, OpenCode, Pi, and terminal-control gate groups remain.")
        return 1
    finally:
        owner.close()
        print(f"CLEANUP: stopped owned session {owner.session} and removed {owner.root}.")


if __name__ == "__main__":
    sys.exit(main())
