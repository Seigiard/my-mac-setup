#!/usr/bin/env python3
"""Opt-in conformance probe for Herdr lifecycle-release ownership.

This intentionally exits nonzero while the full ownership gate remains incomplete.
It creates and removes an isolated Herdr session and its disposable pane.
"""

import json
import os
import pty
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
OPT_IN = "MMS_LIVE_HERDR_OWNERSHIP_PROBE"
OLD_SOURCE = "mms-377-old-launch"
SUCCESSOR_SOURCE = "mms-377-successor"
AGENT = "claude"


class ProbeError(Exception):
    pass


class OwnedHerdr:
    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="mms377-herdr-proof-", dir="/tmp")
        self.session = f"ownership-{os.getpid()}"
        self.process = None

    @property
    def env(self):
        env = os.environ.copy()
        for name in tuple(env):
            if name == "HERDR_ENV" or name.startswith("HERDR_"):
                env.pop(name)
        env["XDG_CONFIG_HOME"] = self.root
        return env

    def start(self):
        master, slave = pty.openpty()
        self.process = subprocess.Popen(
            ["herdr", "--session", self.session],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=self.env,
            close_fds=True,
        )
        os.close(slave)
        os.close(master)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            status = subprocess.run(
                ["herdr", "--session", self.session, "status", "server"],
                text=True,
                capture_output=True,
                env=self.env,
                timeout=15,
                check=False,
            )
            if status.returncode == 0 and "status: running" in status.stdout:
                snapshot = self.run("api", "snapshot")
                return json.loads(snapshot.stdout)["result"]["snapshot"]["panes"][0]
            if self.process.poll() is not None:
                raise ProbeError("owned Herdr client exited before its server became ready")
            time.sleep(0.1)
        raise ProbeError("owned Herdr server did not become ready within 10 seconds")

    def run(self, *args, expected=0):
        return run(*args, expected=expected, env=self.env, session=self.session)

    def close(self):
        errors = []
        try:
            self.run("session", "stop", self.session)
        except ProbeError as error:
            errors.append(str(error))
        if self.process is not None:
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=5)
        try:
            self.run("session", "delete", self.session)
        except ProbeError as error:
            errors.append(str(error))
        shutil.rmtree(self.root, ignore_errors=True)
        if errors:
            raise ProbeError("; ".join(errors))


def run(*args, expected=0, env=None, session=None):
    command = ["herdr"]
    if session is not None:
        command.extend(("--session", session))
    command.extend(args)
    result = subprocess.run(
        command, text=True, capture_output=True, timeout=15, check=False, env=env
    )
    if expected is not None and result.returncode != expected:
        raise ProbeError(
            f"{' '.join(args)} returned {result.returncode}, expected {expected}: "
            f"{result.stderr.strip()}"
        )
    return result


def json_result(owner, *args, expected=0):
    result = owner.run(*args, expected=expected)
    if not result.stdout.strip():
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ProbeError(f"{' '.join(args)} returned invalid JSON: {error}") from error


def agent(owner, pane, expected_present):
    result = owner.run("agent", "get", pane, expected=0 if expected_present else 1)
    if expected_present:
        try:
            return json.loads(result.stdout)["result"]["agent"]
        except (KeyError, TypeError, json.JSONDecodeError) as error:
            raise ProbeError(f"agent get {pane} did not return an agent record") from error
    if "agent_not_found" not in result.stderr:
        raise ProbeError(f"agent get {pane} failed for an unexpected reason: {result.stderr}")
    return None


def wait_for_screen_detection(owner, pane):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        result = owner.run("agent", "get", pane, expected=None)
        if result.returncode == 0:
            try:
                record = json.loads(result.stdout)["result"]["agent"]
            except (KeyError, TypeError, json.JSONDecodeError):
                record = None
            if record and record.get("agent") == AGENT:
                explain = owner.run("agent", "explain", pane)
                if "rule: none" not in explain.stdout:
                    return record
        time.sleep(0.1)
    raise ProbeError("Herdr did not screen-detect the disposable claude process within 10 seconds")


def assert_same_terminal(before, after, context):
    if before.get("terminal_id") != after.get("terminal_id"):
        raise ProbeError(f"{context}: terminal identity changed")
    if after.get("agent") != AGENT:
        raise ProbeError(f"{context}: successor agent changed to {after.get('agent')!r}")
    if before.get("name") != after.get("name"):
        raise ProbeError(f"{context}: successor alias changed")


def main():
    if os.environ.get(OPT_IN) != "1":
        print(f"REFUSED: set {OPT_IN}=1 to create a disposable owned Herdr pane.")
        return 2
    if os.environ.get("HERDR_ENV") != "1":
        print("REFUSED: this probe must run from a Herdr-managed pane.")
        return 2

    version = run("--version").stdout.strip()
    owner = OwnedHerdr()
    case = "delayed old release after takeover handoff to screen detection"

    try:
        root_pane = owner.start()
        created = json_result(
            owner,
            "pane",
            "split",
            "--pane",
            root_pane["pane_id"],
            "--direction",
            "down",
            "--cwd",
            ROOT,
            "--no-focus",
        )
        pane_info = created["result"]["pane"]
        pane = pane_info["pane_id"]
        initial_terminal = pane_info["terminal_id"]
        print(f"CASE: {case} (owned session {owner.session}, pane {pane})")
        # Use the installed client, not a process-name fake, for screen detection.
        owner.run("pane", "run", pane, "claude")
        detected = wait_for_screen_detection(owner, pane)
        if detected.get("terminal_id") != initial_terminal:
            raise ProbeError("screen detection targeted a different terminal")
        alias = f"mms377-proof-{os.getpid()}"
        owner.run("agent", "rename", pane, alias)
        detected = agent(owner, pane, expected_present=True)
        if detected.get("name") != alias:
            raise ProbeError("Herdr did not retain the owned successor alias")

        base = time.time_ns()
        owner.run("pane", "report-agent", pane, "--source", OLD_SOURCE, "--agent", AGENT,
                  "--state", "unknown", "--seq", str(base))
        owner.run("pane", "report-agent", pane, "--source", SUCCESSOR_SOURCE, "--agent", AGENT,
                  "--state", "working", "--seq", str(base + 10))
        owner.run("pane", "release-agent", pane, "--source", SUCCESSOR_SOURCE, "--agent", AGENT,
                  "--seq", str(base + 11))

        successor = wait_for_screen_detection(owner, pane)
        assert_same_terminal(detected, successor, "after successor handoff")

        # This is the old launch's reserved next sequence, not a fresh timestamp.
        owner.run("pane", "release-agent", pane, "--source", OLD_SOURCE, "--agent", AGENT,
                  "--seq", str(base + 1))
        survivor = agent(owner, pane, expected_present=True)
        assert_same_terminal(successor, survivor, "after delayed old release")
        print(f"PASS: {case}: old release preserved successor {alias} on {initial_terminal}.")
        print(f"INCOMPLETE: {version}; only the first required ownership case group was sampled.")
        return 1
    except ProbeError as error:
        print(f"UNVERIFIED: {case}: {error}")
        print(f"BLOCKED: {version}; no safe protocol was demonstrated.")
        return 1
    finally:
        try:
            owner.close()
            print(f"CLEANUP: stopped owned session {owner.session} and removed {owner.root}.")
        except ProbeError as error:
            print(f"CLEANUP FAILED: owned session {owner.session}: {error}", file=sys.stderr)
            raise


if __name__ == "__main__":
    sys.exit(main())
