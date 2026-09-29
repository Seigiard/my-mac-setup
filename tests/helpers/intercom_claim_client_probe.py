#!/usr/bin/env python3
"""Opt-in live-client conformance probe for Intercom launch claims.

This deliberately runs installed clients in a disposable Herdr server. It is
not a launcher test double: the prelaunch process records an intent, acquires
an actual pool alias, then execs the audited #378 launcher in that same PID.
"""

import argparse
import json
import os
import pathlib
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from intercom_claim_ownership_probe import (
    AGENT,
    EVIDENCE_DIR,
    OPT_IN,
    OwnedHerdr,
    ProbeError,
    create_pane,
    native_executable,
    require,
)
from intercom_claim_recovery_prototype import (
    LaunchdOwner,
    acknowledge_acquisition,
    atomic_write,
    bound_request,
    capture_server_identity,
    process_start_identity,
    socket_identity,
    write_intent,
)


ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = "mms-377-live-client"
REFERENCE = "2ea1c0d346896c1735ffe2c0ed88b879abbcc2e6"
CLIENTS = ("opencode", "pi", "claude")


def read_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def wait_until(predicate, timeout, description):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(0.1)
    raise ProbeError(f"timed out waiting for {description}; last={last!r}")


def prelaunch(arguments):
    """Record/acquire before exec so recovery follows the real client PID."""
    pane = os.environ.get("HERDR_PANE_ID")
    socket_path = os.environ.get("HERDR_SOCKET_PATH")
    if not pane or not socket_path:
        raise ProbeError("prelaunch is not running in a Herdr pane")
    connection = {"socket_path": socket_path, "server_identity": capture_server_identity(socket_path)}
    terminal_response = bound_request({"connection": connection}, "pane.get", {"pane_id": pane})
    if "error" in terminal_response:
        raise ProbeError(f"could not read launch pane: {terminal_response['error']}")
    terminal = terminal_response["result"]["pane"]
    pid = os.getpid()
    start = process_start_identity(pid)
    if not start:
        raise ProbeError("could not capture prelaunch process identity")
    intent = {
        "launch_id": f"live-{arguments.agent}-{pid}-{time.time_ns()}",
        "phase": "intent",
        "connection": {**connection, "socket_identity": socket_identity(socket_path)},
        "terminal": {"pane_id": pane, "terminal_id": terminal["terminal_id"]},
        "agent_kind": arguments.agent,
        "claim": {"source": SOURCE, "claim_seq": arguments.sequence,
                  "release_seq": arguments.sequence + 1},
        "client": {"pid": pid, "start_identity": start},
        "created_at_ns": time.time_ns(),
    }
    path = write_intent(arguments.intent_dir, intent)
    response = bound_request(intent, "pane.report_agent", {
        "pane_id": pane, "source": SOURCE, "agent": arguments.agent,
        "state": "unknown", "seq": arguments.sequence,
    })
    if "error" in response:
        raise ProbeError(f"claim rejected: {response['error']}")
    response = bound_request(intent, "agent.rename", {"target": pane, "name": arguments.alias})
    if "error" in response:
        raise ProbeError(f"alias rejected: {response['error']}")
    acknowledge_acquisition(path)
    atomic_write(arguments.receipt, {"pid": pid, "start_identity": start, "intent": path,
                                     "alias": arguments.alias, "agent": arguments.agent,
                                     "stdin_isatty": os.isatty(0), "stdout_isatty": os.isatty(1)})
    os.execv(arguments.launcher, [arguments.launcher, arguments.agent, *arguments.client_args])


class ClientProbe:
    def __init__(self):
        self.scratch = pathlib.Path(tempfile.mkdtemp(prefix="mms377-client-proof-", dir="/tmp"))
        self.owner = OwnedHerdr()
        self.launchd = None
        self.root_pane = None
        self.results = []
        self.processes = {}
        self.aliases = self.pool_aliases()
        self.launcher = self.scratch / "herdr-agent-intercom"
        self.stage()

    def pool_aliases(self):
        result = subprocess.run(["herdr-pane-labels", "--alias-candidates", "intercom-validation"],
                                text=True, capture_output=True, check=False)
        aliases = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if result.returncode or not aliases:
            raise ProbeError(f"pool alias control failed: {result.stderr.strip()}")
        return aliases

    def stage(self):
        launcher = subprocess.run(
            ["git", "show", f"{REFERENCE}:home/dot_local/bin/executable_herdr-agent-intercom"],
            cwd=ROOT, text=True, capture_output=True, check=False,
        )
        if launcher.returncode:
            raise ProbeError(f"could not read audited launcher: {launcher.stderr.strip()}")
        self.launcher.write_text(launcher.stdout, encoding="utf-8")
        self.launcher.chmod(0o755)
        allocator = self.scratch / "aliases"
        allocator.write_text("#!/bin/sh\nprintf '%s\\n' \"$MMS377_ALIAS\"\n", encoding="utf-8")
        allocator.chmod(0o755)
        # Explicit loaders leave the user's Pi and OpenCode configuration untouched.
        self.pi_loaders = [str(ROOT / "home/dot_pi/agent/extensions/agent-intercom.ts"),
                           str(pathlib.Path.home() / ".pi/agent/extensions/herdr-agent-state.ts")]
        self.opencode_config = self.scratch / "xdg/config/opencode/plugins"
        self.opencode_config.mkdir(parents=True)
        shutil.copy(pathlib.Path.home() / ".config/opencode/plugins/herdr-agent-state.js",
                    self.opencode_config / "herdr-agent-state.js")
        shutil.copy(pathlib.Path.home() / ".config/opencode/herdr-tui-session.js",
                    self.opencode_config / "herdr-tui-session.js")
        shutil.copy(ROOT / "home/private_dot_config/opencode/plugins/agent-intercom.ts",
                    self.opencode_config / "agent-intercom.ts")

    def start(self):
        self.root_pane = self.owner.start()
        self.launchd = LaunchdOwner(self.owner.root)
        self.launchd.start()

    def close(self):
        errors = []
        for process, handle in self.processes.values():
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            handle.close()
        if self.launchd:
            try:
                self.launchd.close()
            except Exception as error:  # cleanup must still stop isolated Herdr
                errors.append(str(error))
        try:
            self.owner.close()
        except Exception as error:
            errors.append(str(error))
        shutil.rmtree(self.scratch, ignore_errors=True)
        if errors:
            raise ProbeError("; ".join(errors))

    def client_pane(self):
        return create_pane(self.owner, self.root_pane)

    def launch(self, agent, args, *, interactive=False, alias_index=0):
        pane = self.client_pane()
        alias = self.aliases[alias_index % len(self.aliases)]
        sequence = time.time_ns()
        receipt = self.scratch / f"{agent}-{sequence}.receipt.json"
        log = self.scratch / f"{agent}-{sequence}.log"
        exit_file = self.scratch / f"{agent}-{sequence}.exit"
        command = [sys.executable, str(pathlib.Path(__file__).resolve()), "--prelaunch",
                   "--agent", agent, "--sequence", str(sequence), "--alias", alias,
                   "--intent-dir", self.launchd.intent_dir, "--receipt", str(receipt),
                   "--launcher", str(self.launcher), "--", *args]
        exports = {
            "MMS377_ALIAS": alias,
            "HERDR_ALIAS_ALLOCATOR": str(self.scratch / "aliases"),
            "INTERCOM_DIR": str(self.scratch / "intercom"),
            "XDG_STATE_HOME": str(self.scratch / "xdg/state"),
            "XDG_CONFIG_HOME": str(self.scratch / "xdg/config"),
            "PI_CODING_AGENT_DIR": str(self.scratch / "pi"),
            "PI_CODING_AGENT_SESSION_DIR": str(self.scratch / "pi/sessions"),
            "PI_OFFLINE": "1",
        }
        if interactive:
            # Pi validates provider readiness before opening its TUI. The native
            # authentication remains available; only config/session writes are isolated.
            exports.pop("PI_OFFLINE")
            script = self.scratch / f"{agent}-{sequence}.run.sh"
            lines = ["#!/bin/bash", "set -u"]
            lines.extend(f"export {key}={shlex.quote(value)}" for key, value in exports.items())
            lines.append(f"cd {shlex.quote(str(ROOT))}")
            lines.append("exec " + " ".join(shlex.quote(value) for value in command))
            script.write_text("\n".join(lines) + "\n", encoding="utf-8")
            script.chmod(0o700)
            # Keep this typed command short: the client itself owns the pane PTY.
            outer = f"bash {shlex.quote(str(script))}; rc=$?; printf '%s' \"$rc\" > {shlex.quote(str(exit_file))}"
            self.owner.run("pane", "run", pane["pane_id"], outer)
        else:
            env = self.owner.env | exports | {
                "HERDR_ENV": "1", "HERDR_PANE_ID": pane["pane_id"],
                "HERDR_SOCKET_PATH": self.owner.socket_path,
            }
            handle = open(log, "w", encoding="utf-8")
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=handle, stderr=subprocess.STDOUT,
                                       env=env, cwd=ROOT, text=True)
            process.stdin.close()
            self.processes[str(log)] = (process, handle)
        try:
            wait_until(receipt.exists, 8, f"{agent} prelaunch receipt")
        except ProbeError as error:
            contents = log.read_text(encoding="utf-8") if log.exists() else "<no client log>"
            raise ProbeError(f"{error}; client-log={contents[-4000:]}") from error
        return pane, receipt, log, exit_file

    def state(self, pane):
        result = self.owner.run("agent", "get", pane["pane_id"], expected=None)
        if result.returncode == 0:
            return json.loads(result.stdout)["result"]["agent"]
        if "agent_not_found" in result.stderr:
            return None
        raise ProbeError(f"agent get failed: {result.stderr.strip()}")

    def pane_output(self, pane):
        return self.owner.run("pane", "read", pane["pane_id"], "--source", "recent-unwrapped", "--lines", "120").stdout

    def descendants(self, parent):
        listing = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], text=True, capture_output=True, check=False)
        rows = []
        for line in listing.stdout.splitlines():
            fields = line.strip().split(None, 2)
            if len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit():
                rows.append((int(fields[0]), int(fields[1]), fields[2]))
        wanted = {parent}
        descendants = []
        while True:
            found = [row for row in rows if row[1] in wanted and row[0] not in wanted]
            if not found:
                return descendants
            descendants.extend(found)
            wanted.update(row[0] for row in found)

    def wait_exit(self, log, exit_file, timeout=20):
        if str(log) not in self.processes:
            wait_until(exit_file.exists, timeout, "interactive client exit status")
            return int(exit_file.read_text(encoding="utf-8"))
        process, handle = self.processes[str(log)]
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            raise ProbeError(f"client did not exit within {timeout}s") from error
        handle.close()
        return status

    def wait_settled(self, receipt, pane, timeout=15):
        intent = pathlib.Path(read_json(receipt)["intent"])
        wait_until(lambda: read_json(intent).get("phase") == "settled", timeout, "recovery settlement")
        require({"step": "client-cleanup"}, self.state(pane) is None, "exited client left an agent claim")
        return read_json(intent)

    def case(self, name, action):
        began = time.monotonic()
        try:
            details = action()
            status = "PASS"
        except ProbeError as error:
            details = {"error": str(error)}
            status = "FAIL"
        except Exception as error:
            details = {"error": f"unexpected {type(error).__name__}: {error}"}
            status = "FAIL"
        details["elapsed_seconds"] = round(time.monotonic() - began, 3)
        self.results.append({"case": name, "status": status, "details": details})
        print(f"{status}: {name}: {json.dumps(details, sort_keys=True)}")

    def unverified(self, name, reason):
        self.results.append({"case": name, "status": "UNVERIFIED", "details": {"reason": reason}})
        print(f"UNVERIFIED: {name}: {reason}")

    def opencode_early_exit(self):
        pane, receipt, log, exit_file = self.launch("opencode", ["--not-a-real-option"])
        claim = wait_until(lambda: self.state(pane), 8, "OpenCode unknown claim")
        require({"step": "opencode-claim"}, claim["agent_status"] == "unknown", "claim was replaced before client exit")
        status = self.wait_exit(log, exit_file)
        intent = self.wait_settled(receipt, pane)
        return {"status": status, "intent": intent, "log": log.read_text(encoding="utf-8")[-2000:]}

    def opencode_no_prompt_quit(self):
        pane, receipt, log, exit_file = self.launch("opencode", ["--mini"], interactive=True, alias_index=3)
        expected = read_json(receipt)
        require({"step": "opencode-pty"}, expected["stdin_isatty"] and expected["stdout_isatty"],
                f"OpenCode prelaunch does not own a PTY: {expected}")
        observed = wait_until(lambda: next((state for state in [self.state(pane)]
                                            if state and (state.get("agent_session") or {}).get("source") == "herdr:opencode"
                                            and state.get("agent_status") in {"idle", "working", "blocked"}), None), 20,
                              "OpenCode TUI lifecycle readiness")
        require({"step": "opencode-alias"}, observed.get("name") == expected["alias"], "OpenCode did not retain canonical alias")
        self.owner.run("pane", "send-keys", pane["pane_id"], "ctrl+c")
        status = self.wait_exit(log, exit_file, timeout=20)
        return {"status": status, "receipt": expected, "state": observed, "pane": self.pane_output(pane)[-4000:]}

    def pi_non_tty(self):
        # A pipe gives Pi non-TTY stdio while the pane still supplies Herdr identity.
        pane, receipt, log, exit_file = self.launch("pi", ["--invalid-option"])
        status = self.wait_exit(log, exit_file)
        intent = self.wait_settled(receipt, pane)
        control = subprocess.run([native_executable("pi"), "--version"], text=True, capture_output=True, check=False)
        require({"step": "pi-native-control"}, control.returncode == 0, "native Pi utility control failed")
        return {"status": status, "intent": intent, "control": {"status": control.returncode,
                "stdout": control.stdout, "stderr": control.stderr}, "log": log.read_text(encoding="utf-8")[-2000:]}

    def pi_interactive(self):
        pane, receipt, log, exit_file = self.launch("pi", ["--verbose", "--extension", self.pi_loaders[0],
                                                  "--extension", self.pi_loaders[1]], interactive=True, alias_index=1)
        expected = read_json(receipt)
        require({"step": "pi-pty"}, expected["stdin_isatty"] and expected["stdout_isatty"],
                f"Pi prelaunch does not own a PTY: {expected}")
        try:
            observed = wait_until(lambda: next((state for state in [self.state(pane)]
                                                if state and (state.get("agent_session") or {}).get("source") == "herdr:pi"
                                                and state.get("agent_status") in {"idle", "working", "blocked"}), None), 15,
                                  "Pi lifecycle takeover")
        except ProbeError as error:
            exit_status = exit_file.read_text(encoding="utf-8") if exit_file.exists() else "<still running>"
            raise ProbeError(f"{error}; exit={exit_status}; receipt={expected}; state={self.state(pane)}; pane={self.pane_output(pane)[-4000:]}") from error
        require({"step": "pi-alias"}, observed.get("name") == expected["alias"], "Pi did not retain canonical alias")
        require({"step": "pi-takeover"}, (observed.get("agent_session") or {}).get("source") == "herdr:pi",
                f"Pi integration did not take lifecycle authority: {observed}")
        os.kill(expected["pid"], signal.SIGTERM)
        status = self.wait_exit(log, exit_file)
        return {"status": status, "receipt": expected, "state": observed,
                "pane": self.pane_output(pane)[-4000:]}

    def claude_relation_and_handoff(self):
        pane, receipt, log, exit_file = self.launch("claude", ["--no-chrome"], interactive=True, alias_index=2)
        expected = read_json(receipt)
        require({"step": "claude-pty"}, expected["stdin_isatty"] and expected["stdout_isatty"],
                f"Claude prelaunch does not own a PTY: {expected}")
        descendants = wait_until(lambda: next((rows for rows in [self.descendants(expected["pid"])]
                                                if any("claude" in command for _, _, command in rows)), None), 15,
                                 "cci native Claude child readiness")
        child_pids = [pid for pid, _, command in descendants if "claude" in command]
        os.kill(expected["pid"], signal.SIGTERM)
        status = self.wait_exit(log, exit_file, timeout=30)
        still_live = [pid for pid in child_pids if process_start_identity(pid)]
        require({"step": "cci-parent-child"}, not still_live, f"native Claude child survived parent termination: {still_live}")
        intent = self.wait_settled(receipt, pane)
        return {"status": status, "receipt": expected, "child_pids": child_pids, "intent": intent,
                "pane": self.pane_output(pane)[-4000:]}


def run_probe():
    if os.environ.get(OPT_IN) != "1":
        print(f"REFUSED: set {OPT_IN}=1 to run installed clients in isolated Herdr panes.")
        return 2
    if os.environ.get("HERDR_ENV") != "1":
        print("REFUSED: this probe must be launched from a Herdr-managed pane.")
        return 2
    probe = ClientProbe()
    try:
        probe.start()
        probe.case("OpenCode early exit releases its unknown claim without successor", probe.opencode_early_exit)
        probe.case("OpenCode TUI opens without prompt, publishes lifecycle, then quits", probe.opencode_no_prompt_quit)
        probe.case("Pi invalid noninteractive launch releases false-positive claim and native control works", probe.pi_non_tty)
        probe.case("interactive Pi retains canonical alias and real Herdr takeover", probe.pi_interactive)
        probe.case("cci observes native child lifetime and cleanup", probe.claude_relation_and_handoff)
        probe.unverified(
            "native and wrapped PTY, Ctrl-C, TERM, and exact exit-status parity",
            "The completed utility control covers only non-TTY Pi output/status. Interactive Pi did not take over Herdr, so a PTY/signal parity result would not prove the required wrapped lifecycle.",
        )
        probe.unverified(
            "real Claude prompt handoff publishes state and retains canonical alias",
            "The installed cci child survived TERM sent to its observed parent in this run. Prompt-hook handoff cannot be attributed safely until the actual native-child lifetime predicate is established.",
        )
        artifact_root = pathlib.Path(os.environ.get(EVIDENCE_DIR, pathlib.Path.home() / ".claude/artifacts/377/proof"))
        artifact_root.mkdir(parents=True, exist_ok=True)
        artifact = artifact_root / f"client-proof-{int(time.time())}.json"
        atomic_write(artifact, {"reference": REFERENCE, "results": probe.results,
                                "herdr_version": subprocess.run(["herdr", "--version"], text=True, capture_output=True).stdout.strip()})
        print(f"EVIDENCE: {artifact}")
        return 0 if all(result["status"] == "PASS" for result in probe.results) else 1
    finally:
        probe.close()
        print(f"CLEANUP: removed client scratch {probe.scratch} and stopped isolated Herdr {probe.owner.session}.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prelaunch", action="store_true")
    parser.add_argument("--agent", choices=CLIENTS)
    parser.add_argument("--sequence", type=int)
    parser.add_argument("--alias")
    parser.add_argument("--intent-dir")
    parser.add_argument("--receipt")
    parser.add_argument("--launcher")
    parser.add_argument("client_args", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.prelaunch:
        if arguments.client_args[:1] == ["--"]:
            arguments.client_args = arguments.client_args[1:]
        prelaunch(arguments)
        return 0
    return run_probe()


if __name__ == "__main__":
    sys.exit(main())
