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
import uuid

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
# PR #378's accepted launcher is byte-for-byte identical at this merge commit.
REFERENCE = "dc33b385891fdab07af303037cc1ad2e3e161471"
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


def terminal_membership(pid):
    result = subprocess.run(
        ["ps", "-o", "pid=,ppid=,pgid=,tpgid=,stat=,comm=", "-p", str(pid)],
        text=True, capture_output=True, check=False,
    )
    membership = {"ps": result.stdout.strip(), "ps_status": result.returncode}
    try:
        membership["terminal_foreground_pgid"] = os.tcgetpgrp(0)
    except OSError as error:
        membership["terminal_foreground_pgid_error"] = str(error)
    membership["process_group"] = os.getpgrp()
    return membership


def terminal_driver(arguments):
    """Keep the pane foreground group alive long enough to reap the real client."""
    signal.signal(signal.SIGINT, lambda _signum, _frame: None)
    command = arguments.driver_command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        raise ProbeError("terminal driver needs a client command")
    driver = {
        "driver_pid": os.getpid(), "driver": terminal_membership(os.getpid()),
        "stdio": {"stdin_isatty": os.isatty(0), "stdout_isatty": os.isatty(1), "stderr_isatty": os.isatty(2)},
    }
    atomic_write(arguments.driver_receipt, {"phase": "starting", **driver})
    process = subprocess.Popen(command, cwd=arguments.cwd, stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr)
    atomic_write(arguments.driver_receipt, {
        "phase": "running", **driver, "client_pid": process.pid,
        "client": terminal_membership(process.pid),
    })
    returncode = process.wait()
    atomic_write(arguments.driver_receipt, {
        "phase": "exited", **driver, "client_pid": process.pid,
        "returncode": returncode,
    })
    hold = os.environ.get("MMS377_DRIVER_HOLD")
    if hold:
        # Model return to the shell while keeping a stopped native descendant's
        # process group non-orphaned until the probe explicitly releases it.
        signal.signal(signal.SIGTTOU, signal.SIG_IGN)
        os.tcsetpgrp(0, os.getpgid(os.getppid()))
        wait_until(pathlib.Path(hold).exists, 30, "owned foreground-group release")
    return 0


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
                  "handoff_seq": arguments.sequence + 1, "release_seq": arguments.sequence + 2},
        "client": {"pid": pid, "start_identity": start},
        "created_at_ns": time.time_ns(),
    }
    trace_dir = os.environ.get("MMS377_TRACE_DIR")
    if trace_dir:
        intent["trace_dir"] = trace_dir
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
    published = bound_request(intent, "agent.get", {"target": pane})
    if "error" in published:
        raise ProbeError(f"claim did not become visible: {published['error']}")
    record = published["result"]["agent"]
    require({"step": "prelaunch-claim"},
            record.get("terminal_id") == terminal["terminal_id"]
            and record.get("name") == arguments.alias
            and record.get("agent") == arguments.agent
            and record.get("agent_status") == "unknown",
            f"claim readback did not match this launch: {record}")
    acknowledge_acquisition(path)
    os.environ["MMS377_INTENT"] = str(path)
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
        self.driver_receipts = {}
        self.quit_steps = {}
        self.foreground_groups = {}
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
        prototype = ROOT / "tests/helpers/intercom_claim_recovery_prototype.py"
        bridge = self.scratch / "bound-claude"
        real_bridge = self.scratch / "native-claude-bridge"
        real_bridge.write_text((ROOT / "home/dot_local/bin/executable_herdr-agent-intercom-claude").read_text(), encoding="utf-8")
        real_bridge.chmod(0o700)
        # The reference launcher stays the baseline. Only its bridge entry is
        # replaced by the candidate's before-exec native binding for this proof.
        bridge.write_text("#!/bin/sh\nexec " + shlex.join([
            sys.executable, str(prototype), "--bind-exec", str(real_bridge), "--",
        ]) + ' "$@"\n', encoding="utf-8")
        bridge.chmod(0o700)
        old_bridge = 'bridge="$HOME/.local/bin/herdr-agent-intercom-claude"'
        require({"step": "reference-bridge"}, launcher.stdout.count(old_bridge) == 1,
                "reference launcher bridge entry changed")
        self.launcher.write_text(launcher.stdout.replace(old_bridge, "bridge=" + shlex.quote(str(bridge))), encoding="utf-8")
        self.launcher.chmod(0o755)
        self.claude_settings = self.scratch / "claude-settings.json"
        atomic_write(self.claude_settings, {"hooks": {"UserPromptSubmit": [{"hooks": [{
            "type": "command", "command": shlex.join([sys.executable, str(prototype), "--handoff"]), "timeout": 10,
        }]}]}})
        allocator = self.scratch / "aliases"
        allocator.write_text("#!/bin/sh\nprintf '%s\\n' \"$MMS377_ALIAS\"\n", encoding="utf-8")
        allocator.chmod(0o755)
        # Explicit loaders leave the user's Pi and OpenCode configuration untouched.
        self.pi_loaders = [str(ROOT / "home/dot_pi/agent/extensions/agent-intercom.ts"),
                           str(pathlib.Path.home() / ".pi/agent/extensions/herdr-agent-state.ts")]
        self.pi_observer = self.scratch / "pi-intercom-observer.ts"
        self.pi_observer.write_text(
            """import { writeFileSync } from \"node:fs\";

const path = process.env.MMS377_PI_OBSERVER;
const write = (event, details = {}) => {
  if (path) writeFileSync(path, JSON.stringify({ event, pid: process.pid,
    load: process.env.HERDR_AGENT_INTERCOM_PI_LOAD, details }) + \"\\n\", { flag: \"a\" });
};

export default function (pi) {
  pi.on(\"session_start\", (_event, ctx) => {
    write(\"session_start\", { mode: ctx?.mode,
      tools: pi.getAllTools().map((tool) => tool.name).filter((name) => name.startsWith(\"intercom_\")) });
  });
  pi.on(\"tool_execution_start\", (event) => {
    if (event?.toolName?.startsWith(\"intercom_\")) write(\"tool_execution_start\", { tool: event.toolName });
  });
  pi.on(\"tool_execution_end\", (event) => {
    if (event?.toolName?.startsWith(\"intercom_\")) write(\"tool_execution_end\", { tool: event.toolName });
  });
  pi.on(\"tool_result\", (event) => {
    if (event?.toolName === \"intercom_list\") write(\"tool_result\", {
      tool: event.toolName,
      content: event?.result?.content ?? event?.content ?? null,
      is_error: event?.result?.isError ?? event?.isError ?? null
    });
  });
}
""", encoding="utf-8")
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
        launchd_stopped = True
        for pid, client in self.foreground_groups.items():
            try:
                if process_start_identity(pid) != client["start_identity"]:
                    continue
                if os.getpgid(pid) != client["process_group"]:
                    raise ProbeError("owned client changed process group before cleanup")
                os.killpg(client["process_group"], signal.SIGCONT)
                os.killpg(client["process_group"], signal.SIGTERM)
                wait_until(lambda: process_start_identity(pid) != client["start_identity"], 10,
                           f"owned foreground client {pid} exit")
            except Exception as error:
                errors.append(f"owned foreground client cleanup failed: {error}")
        if self.launchd:
            # cci may already be gone while the bound native process remains.
            # Its durable identity is still owned, including after handoff.
            for path in pathlib.Path(self.launchd.intent_dir).glob("*.json"):
                try:
                    client = read_json(path)["client"]
                    if process_start_identity(client["pid"]) == client["start_identity"]:
                        os.kill(client["pid"], signal.SIGKILL)
                        wait_until(lambda: process_start_identity(client["pid"]) != client["start_identity"],
                                   10, "bound owned client cleanup")
                except Exception as error:
                    errors.append(f"owned intent client cleanup failed: {error}")
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
                launchd_stopped = False
                errors.append(str(error))
        try:
            self.owner.close(remove_root=launchd_stopped)
        except Exception as error:
            errors.append(str(error))
        # The real adapter starts its broker detached from the client group.
        # Bind cleanup to the peer on our private socket, never to a stale pidfile.
        broker_socket = self.scratch / "intercom/broker.sock"
        if broker_socket.exists():
            try:
                if not broker_socket.resolve().is_relative_to(self.scratch.resolve()):
                    raise ProbeError("private broker socket escaped the owned scratch directory")
                broker = capture_server_identity(str(broker_socket))
                if process_start_identity(broker["pid"]) == broker["start_identity"]:
                    os.kill(broker["pid"], signal.SIGTERM)
                    wait_until(lambda: process_start_identity(broker["pid"]) != broker["start_identity"],
                               10, "owned detached broker exit")
            except (ConnectionRefusedError, FileNotFoundError):
                pass
            except Exception as error:
                errors.append(f"private broker cleanup failed: {error}")
        if errors:
            raise ProbeError("; ".join(errors))
        shutil.rmtree(self.scratch)

    def client_pane(self):
        # Repeated splits shrink real TUIs to one row and can hide readiness.
        created = self.owner.run("tab", "create", "--workspace", self.root_pane["workspace_id"],
                                 "--cwd", str(ROOT), "--no-focus")
        return json.loads(created.stdout)["result"]["root_pane"]

    def start_foreground_driver(self, pane, receipt, command, exports, label):
        driver_receipt = self.scratch / f"{label}.driver.json"
        driver_script = self.scratch / f"{label}.driver.sh"
        lines = ["#!/bin/sh", "set -eu"]
        lines.extend(f"export {key}={shlex.quote(value)}" for key, value in exports.items())
        driver = [sys.executable, str(pathlib.Path(__file__).resolve()), "--terminal-driver",
                  "--driver-receipt", str(driver_receipt), "--cwd", str(ROOT), "--", *command]
        lines.append("exec " + shlex.join(driver))
        driver_script.write_text("\n".join(lines) + "\n", encoding="utf-8")
        driver_script.chmod(0o700)
        # Do not replace the pane shell. R1 distinguishes claim cleanup from a
        # terminal disappearing with its foreground client.
        self.owner.run("pane", "run", pane["pane_id"], shlex.quote(str(driver_script)))
        self.driver_receipts[str(receipt)] = driver_receipt
        return driver_receipt

    def foreground_exports(self, alias, sequence):
        return {
            "MMS377_ALIAS": alias,
            "HERDR_ALIAS_ALLOCATOR": str(self.scratch / "aliases"),
            "INTERCOM_DIR": str(self.scratch / "intercom"),
            "XDG_STATE_HOME": str(self.scratch / "xdg/state"),
            "XDG_CONFIG_HOME": str(self.scratch / "xdg/config"),
            "PI_CODING_AGENT_DIR": str(self.scratch / "pi"),
            "PI_CODING_AGENT_SESSION_DIR": str(self.scratch / "pi/sessions"),
            "MMS377_PI_OBSERVER": str(self.scratch / f"pi-{sequence}.observer.jsonl"),
        }

    def launch(self, agent, args, *, interactive=False, alias_index=0, hold_group=False, offline=True):
        if agent == "claude":
            args = ["--settings", str(self.claude_settings), *args]
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
        exports = self.foreground_exports(alias, sequence)
        if offline:
            exports["PI_OFFLINE"] = "1"
        if hold_group:
            trace_dir = self.scratch / f"trace-{sequence}"
            trace_dir.mkdir()
            exports["MMS377_TRACE_DIR"] = str(trace_dir)
            exports["MMS377_DRIVER_HOLD"] = str(receipt) + ".release"
        if interactive:
            # Pi validates provider readiness before opening its TUI. The native
            # authentication remains available; only config/session writes are isolated.
            exports.pop("PI_OFFLINE")
            # This one foreground command avoids a shell `; rc=$?` tail. The
            # driver ignores its own SIGINT, while exec restores the client's
            # normal SIGINT disposition before it joins the same foreground PG.
            # pane.run types text into a shell and has a command-length limit;
            # keep the typed foreground command short and retain all arguments
            # in an owned executable file.
            self.start_foreground_driver(pane, receipt, command, exports, f"{agent}-{sequence}")
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
            driver = self.driver_receipts.get(str(receipt))
            driver_state = read_json(driver) if driver and driver.exists() else "<no driver receipt>"
            pane_state = self.pane_visible(pane)[-4000:] if interactive else "<noninteractive>"
            raise ProbeError(
                f"{error}; driver={driver_state}; pane={pane_state}; client-log={contents[-4000:]}"
            ) from error
        return pane, receipt, log, exit_file

    def launch_native(self, agent, args):
        pane = self.client_pane()
        sequence = time.time_ns()
        receipt = self.scratch / f"native-{agent}-{sequence}.receipt.json"
        exports = self.foreground_exports("native-control", sequence)
        self.start_foreground_driver(pane, receipt, [native_executable(agent), *args], exports,
                                     f"native-{agent}-{sequence}")
        wait_until(lambda: self.driver_details(receipt), 8, f"native {agent} terminal driver")
        return pane, receipt

    def native_print(self, agent, args, alias_index=0):
        sequence = time.time_ns()
        exports = self.foreground_exports(self.aliases[alias_index % len(self.aliases)], sequence)
        environment = os.environ | exports
        environment.pop("PI_OFFLINE", None)
        return subprocess.run([native_executable(agent), *args], cwd=ROOT, env=environment,
                              stdin=subprocess.DEVNULL, text=True, capture_output=True, check=False,
                              timeout=60)

    def state(self, pane):
        result = self.owner.run("agent", "get", pane["pane_id"], expected=None)
        if result.returncode == 0:
            return json.loads(result.stdout)["result"]["agent"]
        if "agent_not_found" in result.stderr:
            return None
        raise ProbeError(f"agent get failed: {result.stderr.strip()}")

    def stable_terminal(self, pane):
        result = self.owner.run("pane", "get", pane["pane_id"])
        current = json.loads(result.stdout)["result"]["pane"]
        require({"step": "stable-terminal"}, current["terminal_id"] == pane["terminal_id"],
                f"client exit changed terminal identity: {pane['terminal_id']} -> {current['terminal_id']}")
        return current

    def pane_output(self, pane):
        result = self.owner.run("pane", "read", pane["pane_id"], "--source", "recent-unwrapped", "--lines", "120",
                                expected=None)
        if result.returncode and "pane_not_found" in result.stderr:
            return "<pane closed after client exit>"
        if result.returncode:
            raise ProbeError(f"pane read failed: {result.stderr.strip()}")
        return result.stdout

    def pane_visible(self, pane):
        result = self.owner.run("pane", "read", pane["pane_id"], "--source", "visible", "--lines", "120", expected=None)
        if result.returncode and "pane_not_found" in result.stderr:
            return "<pane closed after client exit>"
        if result.returncode:
            raise ProbeError(f"pane read failed: {result.stderr.strip()}")
        return result.stdout

    def driver_details(self, receipt):
        path = self.driver_receipts.get(str(receipt))
        return read_json(path) if path and path.exists() else None

    def wait_driver(self, receipt, phase, timeout=15):
        driver = wait_until(
            lambda: details if (details := self.driver_details(receipt)) and details.get("phase") == phase else None,
            timeout, f"foreground driver {phase}",
        )
        if phase == "running":
            client_pid = driver["client_pid"]
            start = process_start_identity(client_pid)
            if start:
                self.foreground_groups[client_pid] = {
                    "start_identity": start,
                    "process_group": os.getpgid(client_pid),
                }
        return driver

    def require_foreground_driver(self, driver, step):
        require({"step": step}, driver["stdio"] == {
            "stdin_isatty": True, "stdout_isatty": True, "stderr_isatty": True,
        }, f"driver did not retain the pane PTY: {driver}")
        membership = driver["driver"]
        require({"step": step}, membership.get("process_group") == membership.get("terminal_foreground_pgid"),
                f"driver was not terminal foreground: {membership}")

    def pi_observations(self, receipt):
        # Receipts embed the launch id; retain the explicit filename search so
        # this diagnostic cannot assume a PID format from the client.
        matches = list(self.scratch.glob("pi-*.observer.jsonl"))
        if not matches:
            return []
        lines = matches[-1].read_text(encoding="utf-8").splitlines()
        return [json.loads(line) for line in lines]

    def process_state(self, pid):
        result = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], text=True,
                                capture_output=True, check=False)
        return result.stdout.strip() if result.returncode == 0 else None

    def wait_process_stopped(self, pid, timeout=5):
        return wait_until(lambda: state if (state := self.process_state(pid)) and "T" in state else None,
                          timeout, f"process {pid} stopped")

    def wait_process_live(self, pid, start, timeout=8):
        def live():
            state = self.process_state(pid)
            if process_start_identity(pid) == start and state and "T" not in state:
                return state
            return None
        return wait_until(live, timeout, f"process {pid} resumed")

    def wait_client_ready(self, agent, pane, receipt, native=False):
        driver = self.wait_driver(receipt, "running")
        self.require_foreground_driver(driver, f"{agent}-foreground")
        if agent == "claude":
            if native:
                return {"driver": driver, **self.wait_claude_ready(pane, receipt, native=True)}
            return {"driver": driver, **self.wait_claude_ready(pane, receipt)}
        expected = read_json(receipt) if not native else None
        pid = driver["client_pid"] if native else expected["pid"]
        client = wait_until(lambda: self.native_process(pid, agent), 20, f"native {agent} input process")
        def input_ready():
            screen = self.pane_visible(pane)
            if agent == "opencode":
                return "OpenCode input box" if "Ask anything" in screen and "ctrl+p commands" in screen else None
            borders = [line for line in screen.splitlines() if len(line.strip()) >= 20 and set(line.strip()) == {"─"}]
            return "Pi input box" if len(borders) >= 2 else None
        readiness = wait_until(input_ready, 20, f"{agent} TUI input box")
        return {"driver": driver, "native": client, "input_readiness": readiness}

    def send_normal_quit(self, agent, pane, receipt, log, exit_file):
        if agent == "pi":
            # Pi's documented app.exit is Ctrl-D on an empty editor. /exit is
            # not its quit command and can autocomplete a skill instead.
            self.owner.run("pane", "send-keys", pane["pane_id"], "ctrl+d")
            steps = ["ctrl+d"]
        else:
            self.owner.run("pane", "send-text", pane["pane_id"], "/exit")
            self.owner.run("pane", "send-keys", pane["pane_id"], "enter")
            steps = ["/exit", "enter"]
        self.quit_steps[str(receipt)] = steps
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            driver = self.driver_details(receipt)
            if driver and driver.get("phase") == "exited":
                status = driver["returncode"]
                break
            screen = self.pane_visible(pane)
            if (agent == "claude" and "Background work is running" in screen
                    and "❯ 1. Exit and stop tasks" in screen and len(steps) == 2):
                # The existing cci inbox monitor triggers Claude's native exit
                # confirmation. Confirm stopping only this owned test session.
                self.owner.run("pane", "send-keys", pane["pane_id"], "enter")
                steps.append("confirm exit and stop owned monitor")
            time.sleep(0.1)
        else:
            raise ProbeError(f"normal quit did not exit; agent={agent}; receipt={receipt}; "
                             f"driver={self.driver_details(receipt)}; state={self.state(pane)}; screen={self.pane_visible(pane)}")
        require({"step": f"{agent}-normal-quit"}, status == 0, f"normal quit returned {status}")
        return status

    def wait_completed(self, receipt, pane, timeout=15):
        intent = pathlib.Path(read_json(receipt)["intent"])
        completed = wait_until(
            lambda: record if (record := read_json(intent)).get("phase") in {"settled", "retired"} else None,
            timeout, "recovery completion",
        )
        wait_until(lambda: self.state(pane) is None, timeout, "client state release")
        return {"intent": completed, "terminal": self.stable_terminal(pane)}

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

    def native_process(self, pid, agent):
        image = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], text=True,
                               capture_output=True, check=False)
        if image.returncode or pathlib.Path(image.stdout.strip()).name != pathlib.Path(native_executable(agent)).name:
            return None
        if agent == "claude":
            command = subprocess.run(["ps", "-p", str(pid), "-o", "args="], text=True,
                                     capture_output=True, check=False)
            if command.returncode or "--version" in shlex.split(command.stdout.strip()):
                return None
        start = process_start_identity(pid)
        return {"pid": pid, "start_identity": start, "image": image.stdout.strip()} if start else None

    def wait_claude_ready(self, pane, receipt, native=False):
        def ready():
            if native:
                client = self.native_process(self.driver_details(receipt)["client_pid"], "claude")
            else:
                intent = read_json(read_json(receipt)["intent"])
                client = self.native_process(intent["client"]["pid"], "claude") if "launcher_client" in intent else None
            if not client:
                return None
            result = self.owner.run("agent", "explain", pane["pane_id"], "--json")
            explanation = json.loads(result.stdout)
            if (explanation.get("matched_rule") or {}).get("id") != "live_prompt_box":
                return None
            return {"native": client, "input_readiness": explanation["matched_rule"]}
        return wait_until(ready, 20, "native Claude input prompt")

    def wait_exit(self, log, exit_file, receipt=None, timeout=20):
        driver_receipt = self.driver_receipts.get(str(receipt)) if receipt else None
        if driver_receipt:
            completed = wait_until(
                lambda: read_json(driver_receipt) if driver_receipt.exists() and
                read_json(driver_receipt).get("phase") == "exited" else None,
                timeout, "foreground terminal driver exit status",
            )
            return completed["returncode"]
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
        return {"intent": read_json(intent), "terminal": self.stable_terminal(pane)}

    def case(self, name, action):
        began = time.monotonic()
        try:
            details = action()
            status = "PASS"
        except ProbeError as error:
            details = {"error": str(error), **getattr(error, "evidence", {})}
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
        status = self.wait_exit(log, exit_file, receipt)
        intent = self.wait_completed(receipt, pane)
        return {"status": status, "intent": intent, "log": log.read_text(encoding="utf-8")[-2000:]}

    def opencode_no_prompt_quit(self):
        pane, receipt, log, exit_file = self.launch("opencode", [], interactive=True, alias_index=3)
        expected = read_json(receipt)
        require({"step": "opencode-pty"}, expected["stdin_isatty"] and expected["stdout_isatty"],
                f"OpenCode prelaunch does not own a PTY: {expected}")
        native = wait_until(lambda: self.native_process(expected["pid"], "opencode"), 20,
                            "native OpenCode exec in the PTY")
        # `visible` includes the alternate screen, unlike command scrollback.
        wait_until(lambda: len(self.pane_visible(pane).strip()) > 0, 10, "OpenCode TUI output")
        observed = self.state(pane)
        require({"step": "opencode-no-report"}, observed is not None and observed.get("agent_status") == "unknown",
                f"the no-report window was not reached: {observed}")
        require({"step": "opencode-alias"}, observed.get("name") == expected["alias"], "OpenCode did not retain canonical alias")
        self.owner.run("pane", "send-keys", pane["pane_id"], "ctrl+c")
        try:
            status = self.wait_exit(log, exit_file, receipt, timeout=5)
            quit_keys = ["ctrl+c"]
        except ProbeError:
            # OpenCode's first Ctrl-C may dismiss the initial input state. Its
            # native TUI receives the same second key in the parity control.
            self.owner.run("pane", "send-keys", pane["pane_id"], "ctrl+c")
            try:
                status = self.wait_exit(log, exit_file, receipt, timeout=15)
                quit_keys = ["ctrl+c", "ctrl+c"]
            except ProbeError as error:
                raise ProbeError(
                    f"{error}; native={native}; state-before-quit={observed}; "
                    f"visible={self.pane_visible(pane)[-4000:]}; recent={self.pane_output(pane)[-4000:]}"
                ) from error
        intent = self.wait_settled(receipt, pane)
        return {"status": status, "receipt": expected, "native": native, "state": observed,
                "quit_keys": quit_keys, "driver": self.driver_details(receipt), "intent": intent,
                "pane": self.pane_output(pane)[-4000:]}

    def pi_non_tty(self):
        # A pipe gives Pi non-TTY stdio while the pane still supplies Herdr identity.
        pane, receipt, log, exit_file = self.launch("pi", ["--invalid-option"])
        status = self.wait_exit(log, exit_file, receipt)
        intent = self.wait_settled(receipt, pane)
        control = subprocess.run([native_executable("pi"), "--version"], text=True, capture_output=True, check=False)
        require({"step": "pi-native-control"}, control.returncode == 0, "native Pi utility control failed")
        return {"status": status, "intent": intent, "control": {"status": control.returncode,
                "stdout": control.stdout, "stderr": control.stderr}, "log": log.read_text(encoding="utf-8")[-2000:]}

    def pi_print_mode_parity(self):
        args = ["--print", "--no-tools", "--no-session", "Reply with exactly PI_PRINT_OK."]
        native = self.native_print("pi", args, alias_index=2)
        require({"step": "pi-native-print-status"}, native.returncode == 0,
                f"native Pi print exited {native.returncode}: {native.stderr[-1000:]}")
        require({"step": "pi-native-print-output"}, "PI_PRINT_OK" in native.stdout,
                f"native Pi print did not return its fixed response: {native.stdout[-1000:]}")
        pane, receipt, log, exit_file = self.launch("pi", args, alias_index=2, offline=False)
        wrapped_status = self.wait_exit(log, exit_file, receipt, timeout=60)
        intent = self.wait_settled(receipt, pane)
        output = log.read_text(encoding="utf-8")
        require({"step": "pi-wrapped-print-status"}, wrapped_status == 0,
                f"wrapped Pi print exited {wrapped_status}: {output[-1000:]}")
        require({"step": "pi-wrapped-print-output"}, "PI_PRINT_OK" in output,
                f"wrapped Pi print did not return its fixed response: {output[-1000:]}")
        require({"step": "pi-print-status-parity"}, native.returncode == wrapped_status,
                f"native/wrapped Pi print status differ: {native.returncode} != {wrapped_status}")
        return {"native_status": native.returncode, "wrapped_status": wrapped_status,
                "intent": intent, "native_output": native.stdout[-1000:], "wrapped_output": output[-1000:]}

    def pi_interactive(self):
        pane, receipt, log, exit_file = self.launch(
            "pi", ["--approve", "--verbose", "--extension", self.pi_loaders[0],
                   "--extension", self.pi_loaders[1], "--extension", str(self.pi_observer),
                   "Use intercom_list exactly once, then reply with its result only."],
            interactive=True, alias_index=1,
        )
        expected = read_json(receipt)
        require({"step": "pi-pty"}, expected["stdin_isatty"] and expected["stdout_isatty"],
                f"Pi prelaunch does not own a PTY: {expected}")
        try:
            observed = wait_until(lambda: next((state for state in [self.state(pane)]
                                                if state and (state.get("agent_session") or {}).get("source") == "herdr:pi"
                                                 and state.get("agent_status") in {"idle", "done", "working", "blocked"}), None), 15,
                                  "Pi lifecycle takeover")
        except ProbeError as error:
            exit_status = exit_file.read_text(encoding="utf-8") if exit_file.exists() else "<still running>"
            raise ProbeError(f"{error}; exit={exit_status}; receipt={expected}; state={self.state(pane)}; pane={self.pane_output(pane)[-4000:]}") from error
        require({"step": "pi-alias"}, observed.get("name") == expected["alias"], "Pi did not retain canonical alias")
        require({"step": "pi-takeover"}, (observed.get("agent_session") or {}).get("source") == "herdr:pi",
                f"Pi integration did not take lifecycle authority: {observed}")
        observations = wait_until(lambda: self.pi_observations(receipt), 10, "Pi observer session start")
        started = next((event for event in observations if event["event"] == "session_start"), None)
        require({"step": "pi-loader-pid"}, started and started["pid"] == expected["pid"] and
                started["load"] == str(expected["pid"]), f"Pi loader identity mismatch: {started}")
        require({"step": "pi-tools"}, "intercom_list" in started["details"]["tools"],
                f"Pi did not register Intercom tools: {started}")
        observations = wait_until(
            lambda: self.pi_observations(receipt)
            if any(event["event"] == "tool_result" and event["details"].get("tool") == "intercom_list" and
                   event["details"].get("is_error") is False and
                   expected["alias"] in json.dumps(event["details"].get("content"), sort_keys=True)
                   for event in self.pi_observations(receipt)) else None,
            30, "successful real Pi intercom_list result content containing its alias",
        )
        os.kill(expected["pid"], signal.SIGTERM)
        status = self.wait_exit(log, exit_file, receipt)
        return {"status": status, "receipt": expected, "state": observed, "observations": observations,
                "driver": self.driver_details(receipt),
                "pane": self.pane_output(pane)[-4000:]}

    def interactive_args(self, agent, wrapped):
        if agent == "pi":
            loaders = ["--approve"]
            if wrapped:
                loaders.extend(["--extension", self.pi_loaders[0], "--extension", self.pi_loaders[1]])
            return loaders
        if agent == "claude":
            return ["--no-chrome"]
        return []

    def interactive_control(self, agent, action, alias_index):
        native_pane, native_receipt = self.launch_native(agent, self.interactive_args(agent, False))
        native_ready = self.wait_client_ready(agent, native_pane, native_receipt, native=True)
        native = native_ready["native"]

        pane, receipt, log, exit_file = self.launch(
            agent, self.interactive_args(agent, True), interactive=True, alias_index=alias_index,
        )
        expected = read_json(receipt)
        wrapped_ready = self.wait_client_ready(agent, pane, receipt)
        wrapped = wrapped_ready["native"]
        if agent == "pi":
            state = wait_until(
                lambda: record if (record := self.state(pane)) and
                (record.get("agent_session") or {}).get("source") == "herdr:pi" else None,
                15, "wrapped Pi lifecycle takeover",
            )
        else:
            state = self.state(pane)
        require({"step": f"wrapped-{agent}-alias"}, state is not None and state.get("name") == expected["alias"],
                f"wrapped {agent} did not retain its canonical alias: {state}")

        def act(target_pane, target_receipt, target_log, target_exit, target_native):
            if action == "normal":
                return {"exited_by_action": True,
                        "status": self.send_normal_quit(agent, target_pane, target_receipt, target_log, target_exit)}
            if action == "term":
                os.kill(target_native["pid"], signal.SIGTERM)
                return {"exited_by_action": True,
                        "status": self.wait_exit(target_log, target_exit, target_receipt, timeout=15)}
            self.owner.run("pane", "send-keys", target_pane["pane_id"], "ctrl+c")
            try:
                return {"exited_by_action": True,
                        "status": self.wait_exit(target_log, target_exit, target_receipt, timeout=4)}
            except ProbeError:
                return {"exited_by_action": False,
                        "status": self.send_normal_quit(agent, target_pane, target_receipt, target_log, target_exit)}

        native_result = act(native_pane, native_receipt, None, None, native)
        wrapped_result = act(pane, receipt, log, exit_file, wrapped)
        intent = self.wait_completed(receipt, pane)
        require({"step": f"{agent}-{action}-effect"}, native_result["exited_by_action"] == wrapped_result["exited_by_action"],
                f"native/wrapped {agent} {action} effect differs: {native_result} != {wrapped_result}")
        require({"step": f"{agent}-{action}-status"}, native_result["status"] == wrapped_result["status"],
                f"native/wrapped {agent} {action} status differ: {native_result} != {wrapped_result}")
        return {"native": native, "native_driver": self.driver_details(native_receipt),
                 "native_result": native_result, "wrapped": wrapped,
                 "wrapped_driver": self.driver_details(receipt), "wrapped_result": wrapped_result,
                "native_quit_steps": self.quit_steps.get(str(native_receipt)),
                "wrapped_quit_steps": self.quit_steps.get(str(receipt)), "state": state, "intent": intent}

    def pi_normal_quit_parity(self):
        return self.interactive_control("pi", "normal", 6)

    def pi_ctrl_c_parity(self):
        return self.interactive_control("pi", "ctrl_c", 7)

    def claude_normal_quit_parity(self):
        return self.interactive_control("claude", "normal", 8)

    def claude_ctrl_c_parity(self):
        return self.interactive_control("claude", "ctrl_c", 9)

    def claude_term_parity(self):
        return self.interactive_control("claude", "term", 10)

    def opencode_normal_quit_parity(self):
        return self.interactive_control("opencode", "normal", 11)

    def stop_resume(self, agent, alias_index):
        native_pane, native_receipt = self.launch_native(agent, self.interactive_args(agent, False))
        native_ready = self.wait_client_ready(agent, native_pane, native_receipt, native=True)
        native = native_ready["native"]

        def suspend_and_resume(pane, client, target_receipt, while_stopped=None):
            group = os.getpgid(client["pid"])
            driver_pid = self.driver_details(target_receipt)["driver_pid"]
            driver_start = process_start_identity(driver_pid)
            require({"step": "job-control-driver"}, driver_start is not None, "status driver exited before suspension")
            self.owner.run("pane", "send-keys", pane["pane_id"], "ctrl+z")
            try:
                stopped = self.wait_process_stopped(client["pid"])
                mechanism = "ctrl_z"
            except ProbeError:
                mechanism = "sigstop_cont_after_ctrl_z_intercept"
            # Some clients stop only themselves. The status driver must also
            # stop before the shell can take the foreground and handle `fg`.
            if "T" not in (self.process_state(driver_pid) or ""):
                os.killpg(group, signal.SIGSTOP)
                mechanism += "+driver_group_stop"
            stopped = self.wait_process_stopped(client["pid"])
            self.wait_process_stopped(driver_pid)
            if while_stopped:
                while_stopped()
                self.wait_process_stopped(client["pid"])
            self.owner.run("pane", "run", pane["pane_id"], "fg")
            self.wait_process_live(driver_pid, driver_start)
            live = self.wait_process_live(client["pid"], client["start_identity"])
            require({"step": f"{agent}-resumed-group"}, os.getpgid(client["pid"]) == group,
                    "resume changed the native process group")
            return {"mechanism": mechanism, "stopped_state": stopped, "resumed_state": live,
                    "process_group": os.getpgid(client["pid"])}

        native_transition = suspend_and_resume(native_pane, native, native_receipt)
        native_status = self.send_normal_quit(agent, native_pane, native_receipt, None, None)

        pane, receipt, log, exit_file = self.launch(
            agent, self.interactive_args(agent, True), interactive=True, alias_index=alias_index, hold_group=True,
        )
        expected = read_json(receipt)
        wrapped_ready = self.wait_client_ready(agent, pane, receipt)
        wrapped = wrapped_ready["native"]
        try:
            if agent == "pi":
                wait_until(lambda: read_json(expected["intent"])["phase"] == "retired", 15,
                           "Pi lifecycle takeover before suspension")
            observer_pass = None
            retained = None
            def observe_stopped_client():
                nonlocal observer_pass, retained
                if agent == "pi":
                    retired = read_json(expected["intent"])
                    require({"step": "pi-stopped-takeover"}, retired["phase"] == "retired",
                            "interactive Pi did not retire launcher authority before suspension")
                    observer_pass = {"retired_before_stop": retired}
                    retained = self.state(pane)
                    require({"step": "pi-stopped-retained"}, retained is not None and retained.get("name") == expected["alias"],
                            "Pi lost its canonical alias while suspended")
                    return
                before_observer = time.monotonic_ns()
                observer_pid = read_json(self.launchd.pid_file)["pid"]
                witness = pathlib.Path(read_json(expected["intent"])["trace_dir"]) / f"{observer_pid}.observe_complete.json"
                observer_pass = wait_until(
                    lambda: read_json(witness) if witness.exists() and
                    read_json(witness).get("started_monotonic_ns", 0) > before_observer else None,
                    10, f"observer pass while {agent} was stopped",
                )
                retained = self.state(pane)
                require({"step": f"{agent}-stopped-retained"}, retained is not None and retained.get("name") == expected["alias"],
                         f"stopped live {agent} lost enrollment: {retained}")
            wrapped_transition = suspend_and_resume(pane, wrapped, receipt,
                                                    while_stopped=observe_stopped_client)
            wrapped_status = self.send_normal_quit(agent, pane, receipt, log, exit_file)
            intent = self.wait_completed(receipt, pane)
        finally:
            pathlib.Path(str(receipt) + ".release").touch()
        require({"step": f"{agent}-stop-resume-status"}, native_status == wrapped_status,
                f"native/wrapped {agent} resumed exit status differ: {native_status} != {wrapped_status}")
        return {"native": native, "native_transition": native_transition, "native_status": native_status,
                "wrapped": wrapped, "wrapped_transition": wrapped_transition, "wrapped_status": wrapped_status,
                "observer_pass": observer_pass, "retained": retained, "intent": intent}

    def opencode_stop_resume(self):
        return self.stop_resume("opencode", 12)

    def pi_stop_resume(self):
        return self.stop_resume("pi", 13)

    def claude_stop_resume(self):
        return self.stop_resume("claude", 14)

    def claude_suspension_without_recovery(self):
        """Attribute alias loss using a direct native launch with no status driver."""
        observer = read_json(self.launchd.pid_file)
        self.launchd.close()
        require({"step": "diagnostic-observer"}, process_start_identity(observer["pid"]) != observer["start_identity"],
                "recovery observer is still running")
        pane = self.client_pane()
        pid_file = self.scratch / "direct-claude.pid"
        script = self.scratch / "direct-claude.sh"
        exports = self.foreground_exports("native-suspension", time.time_ns())
        lines = ["#!/bin/sh", "set -eu"]
        lines.extend(f"export {key}={shlex.quote(value)}" for key, value in exports.items())
        lines.extend([f"printf '%s' \"$$\" > {shlex.quote(str(pid_file))}",
                      "exec " + shlex.join([native_executable("claude"), "--no-chrome"])])
        script.write_text("\n".join(lines) + "\n", encoding="utf-8")
        script.chmod(0o700)
        self.owner.run("pane", "run", pane["pane_id"], str(script))
        wait_until(pid_file.exists, 8, "direct native PID")
        pid = int(pid_file.read_text())
        native = wait_until(lambda: self.native_process(pid, "claude"), 20, "direct native Claude exec")
        self.foreground_groups[pid] = {"start_identity": native["start_identity"], "process_group": os.getpgid(pid)}
        def prompt_ready():
            result = self.owner.run("agent", "explain", pane["pane_id"], "--json", expected=None)
            if result.returncode:
                if "agent_not_found" in result.stderr:
                    return False
                raise ProbeError(f"native readiness lookup failed: {result.stderr}")
            return (json.loads(result.stdout).get("matched_rule") or {}).get("id") == "live_prompt_box"
        wait_until(prompt_ready, 20, "direct native input prompt")
        alias = self.aliases[0]
        self.owner.run("agent", "rename", pane["pane_id"], alias)
        before = self.state(pane)
        require({"step": "native-alias-control"}, before is not None and before.get("name") == alias,
                "native alias was not established")
        self.owner.run("pane", "send-keys", pane["pane_id"], "ctrl+z")
        self.wait_process_stopped(pid)
        samples = []
        for _ in range(15):
            samples.append({"agent": self.state(pane), "start_identity": process_start_identity(pid),
                            "process_state": self.process_state(pid)})
            time.sleep(0.1)
        connection = {"connection": {"socket_path": self.owner.socket_path,
                      "server_identity": capture_server_identity(self.owner.socket_path)}}
        report = bound_request(connection, "pane.report_agent", {
            "pane_id": pane["pane_id"], "source": SOURCE, "agent": "claude", "state": "unknown", "seq": time.time_ns(),
        })
        after_report = self.state(pane)
        renamed = bound_request(connection, "agent.rename", {"target": pane["pane_id"], "name": alias})
        after_rename = self.state(pane)
        self.owner.run("pane", "run", pane["pane_id"], "fg")
        self.wait_process_live(pid, native["start_identity"])
        wait_until(prompt_ready, 20, "direct native prompt after resume")
        resumed = self.state(pane)
        evidence = {"before": before, "native": native, "observer_confirmed_stopped": observer,
                    "samples_while_stopped": samples, "report_attempt": report, "after_report": after_report,
                    "rename_attempt": renamed, "after_rename": after_rename, "after_resume": resumed,
                    "direct_native_launch": True, "status_driver_used": False}
        retained = all(sample["agent"] and sample["agent"].get("name") == alias for sample in samples)
        require({"step": "native-suspension-control"},
                all(sample["start_identity"] == native["start_identity"] and "T" in sample["process_state"] for sample in samples),
                "native process did not remain alive and stopped")
        if not retained:
            error = ProbeError("Herdr lost the stopped native client's alias with recovery disabled")
            error.evidence = evidence
            raise error
        return evidence

    def opencode_ctrl_c_parity(self):
        native_pane, native_receipt = self.launch_native("opencode", [])
        native_driver = self.wait_driver(native_receipt, "running")
        self.require_foreground_driver(native_driver, "native-opencode-foreground")
        native = wait_until(lambda: self.native_process(native_driver["client_pid"], "opencode"), 15,
                            "native OpenCode control")
        self.owner.run("pane", "send-keys", native_pane["pane_id"], "ctrl+c")
        native_status = self.wait_exit(None, None, native_receipt)

        pane, receipt, log, exit_file = self.launch("opencode", [], interactive=True, alias_index=4)
        expected = read_json(receipt)
        wrapped_driver = self.wait_driver(receipt, "running")
        self.require_foreground_driver(wrapped_driver, "wrapped-opencode-foreground")
        wrapped = wait_until(lambda: self.native_process(expected["pid"], "opencode"), 15,
                             "wrapped native OpenCode")
        observed = self.state(pane)
        require({"step": "wrapped-opencode-no-report"}, observed and observed.get("agent_status") == "unknown",
                f"OpenCode reported before control signal: {observed}")
        self.owner.run("pane", "send-keys", pane["pane_id"], "ctrl+c")
        wrapped_status = self.wait_exit(log, exit_file, receipt)
        intent = self.wait_settled(receipt, pane)
        require({"step": "opencode-ctrl-c-status"}, native_status == wrapped_status,
                f"native/wrapped Ctrl-C status differ: {native_status} != {wrapped_status}")
        return {"native": native, "native_driver": self.driver_details(native_receipt), "native_status": native_status,
                "wrapped": wrapped, "wrapped_driver": self.driver_details(receipt), "wrapped_status": wrapped_status,
                "intent": intent}

    def opencode_term_parity(self):
        native_pane, native_receipt = self.launch_native("opencode", [])
        native_driver = self.wait_driver(native_receipt, "running")
        self.require_foreground_driver(native_driver, "native-opencode-term-foreground")
        native = wait_until(lambda: self.native_process(native_driver["client_pid"], "opencode"), 15,
                            "native OpenCode TERM control")
        os.kill(native["pid"], signal.SIGTERM)
        native_status = self.wait_exit(None, None, native_receipt)

        pane, receipt, log, exit_file = self.launch("opencode", [], interactive=True, alias_index=5)
        expected = read_json(receipt)
        wrapped_driver = self.wait_driver(receipt, "running")
        self.require_foreground_driver(wrapped_driver, "wrapped-opencode-term-foreground")
        wrapped = wait_until(lambda: self.native_process(expected["pid"], "opencode"), 15,
                             "wrapped OpenCode TERM control")
        observed = self.state(pane)
        require({"step": "wrapped-opencode-term-no-report"}, observed and observed.get("agent_status") == "unknown",
                f"OpenCode reported before TERM: {observed}")
        os.kill(wrapped["pid"], signal.SIGTERM)
        wrapped_status = self.wait_exit(log, exit_file, receipt)
        intent = self.wait_settled(receipt, pane)
        require({"step": "opencode-term-status"}, native_status == wrapped_status,
                f"native/wrapped TERM status differ: {native_status} != {wrapped_status}")
        return {"native": native, "native_status": native_status, "native_driver": self.driver_details(native_receipt),
                "wrapped": wrapped, "wrapped_status": wrapped_status, "wrapped_driver": self.driver_details(receipt),
                "intent": intent}

    def pi_term_parity(self):
        native_pane, native_receipt = self.launch_native("pi", ["--approve"])
        native_driver = self.wait_driver(native_receipt, "running")
        self.require_foreground_driver(native_driver, "native-pi-foreground")
        os.kill(native_driver["client_pid"], signal.SIGTERM)
        native_status = self.wait_exit(None, None, native_receipt)

        pane, receipt, log, exit_file = self.launch(
            "pi", ["--approve", "--extension", self.pi_loaders[0], "--extension", self.pi_loaders[1]],
            interactive=True, alias_index=5,
        )
        expected = read_json(receipt)
        wrapped_driver = self.wait_driver(receipt, "running")
        self.require_foreground_driver(wrapped_driver, "wrapped-pi-foreground")
        os.kill(expected["pid"], signal.SIGTERM)
        wrapped_status = self.wait_exit(log, exit_file, receipt)
        require({"step": "pi-term-status"}, native_status == wrapped_status,
                f"native/wrapped TERM status differ: {native_status} != {wrapped_status}")
        return {"native_driver": self.driver_details(native_receipt), "native_status": native_status,
                "wrapped_driver": self.driver_details(receipt), "wrapped_status": wrapped_status}

    def claude_normal_exit(self):
        pane, receipt, log, exit_file = self.launch("claude", ["--no-chrome"], interactive=True, alias_index=6)
        expected = read_json(receipt)
        readiness = self.wait_claude_ready(pane, receipt)
        children = [readiness["native"]]
        status = self.send_normal_quit("claude", pane, receipt, log, exit_file)
        quit_keys = self.quit_steps[str(receipt)]
        gone = wait_until(
            lambda: not [child for child in children if process_start_identity(child["pid"]) == child["start_identity"]],
            5, "native Claude exit after /exit",
        )
        return {"status": status, "quit_keys": quit_keys, "receipt": expected, "children": children,
                "driver": self.driver_details(receipt), "children_gone": gone}

    def claude_first_prompt_handoff(self):
        pane, receipt, log, exit_file = self.launch("claude", ["--no-chrome"], interactive=True, alias_index=7)
        expected = read_json(receipt)
        readiness = self.wait_claude_ready(pane, receipt)
        try:
            self.owner.run("pane", "send-text", pane["pane_id"], "Reply with OK only.")
            self.owner.run("pane", "send-keys", pane["pane_id"], "enter")
            try:
                handoff = wait_until(
                    lambda: state if (state := self.state(pane)) and state.get("name") == expected["alias"] and
                    state.get("agent_status") != "unknown" else None,
                    10, "Claude first-prompt lifecycle handoff",
                )
            except ProbeError as error:
                intent = read_json(expected["intent"])
                raise ProbeError(
                    f"{error}; state={self.state(pane)}; driver={self.driver_details(receipt)}; "
                    f"claim={intent['claim']}; pane={self.pane_visible(pane)[-4000:]}"
                ) from error
            retired = wait_until(lambda: value if (value := read_json(expected["intent"]))["phase"] == "retired" else None,
                                 10, "handoff observer retirement")
            require({"step": "handoff-client"}, process_start_identity(readiness["native"]["pid"]) ==
                    readiness["native"]["start_identity"], "handoff ended the native client")
            return {"receipt": expected, "handoff": handoff, "driver": self.driver_details(receipt),
                    "retired": retired, "readiness": readiness}
        finally:
            if process_start_identity(expected["pid"]) == expected["start_identity"]:
                os.kill(expected["pid"], signal.SIGTERM)
            self.wait_exit(log, exit_file, receipt, timeout=15)

    def claude_relation_and_handoff(self):
        pane, receipt, log, exit_file = self.launch("claude", ["--no-chrome"], interactive=True, alias_index=2,
                                                  hold_group=True)
        expected = read_json(receipt)
        require({"step": "claude-pty"}, expected["stdin_isatty"] and expected["stdout_isatty"],
                f"Claude prelaunch does not own a PTY: {expected}")
        def native_children():
            return [record for pid, _, _ in self.descendants(expected["pid"])
                    if (record := self.native_process(pid, "claude"))]
        children = wait_until(native_children, 20, "actual native Claude executable below cci")
        require({"step": "native-count"}, len(children) == 1, f"ambiguous native children: {children}")
        native = children[0]
        try:
            bound = read_json(expected["intent"])
            require({"step": "native-binding"}, bound["client"] == {
                "pid": native["pid"], "start_identity": native["start_identity"],
            }, f"recovery still follows cci: {bound['client']}")
            os.kill(native["pid"], signal.SIGSTOP)
            os.kill(expected["pid"], signal.SIGKILL)
            status = self.wait_exit(log, exit_file, receipt)
            require({"step": "cci-killed"}, status == -signal.SIGKILL, f"cci status was {status}")
            after_exit = time.monotonic_ns()
            observer_pid = read_json(self.launchd.pid_file)["pid"]
            witness = pathlib.Path(bound["trace_dir"]) / f"{observer_pid}.observe_complete.json"
            wait_until(lambda: witness.exists() and read_json(witness)["started_monotonic_ns"] > after_exit,
                       10, "observer pass after cci exit")
            require({"step": "native-survivor"},
                    process_start_identity(native["pid"]) == native["start_identity"],
                    "native survival barrier did not hold")
            held = self.state(pane)
            require({"step": "native-claim"}, held is not None and held.get("name") == expected["alias"]
                    and held.get("terminal_id") == pane["terminal_id"], "cleanup removed a live native client's claim")
            os.kill(native["pid"], signal.SIGKILL)
            wait_until(lambda: process_start_identity(native["pid"]) != native["start_identity"], 10, "native exit")
            settled = self.wait_settled(receipt, pane)
            return {"status": status, "receipt": expected, "native": native, "bound": bound,
                    "held_after_cci_exit": held, "settled_after_native_exit": settled}
        finally:
            if process_start_identity(native["pid"]) == native["start_identity"]:
                os.kill(native["pid"], signal.SIGKILL)
            pathlib.Path(str(receipt) + ".release").touch()


def run_probe(suspension_only=False):
    if os.environ.get(OPT_IN) != "1":
        print(f"REFUSED: set {OPT_IN}=1 to run installed clients in isolated Herdr panes.")
        return 2
    if os.environ.get("HERDR_ENV") != "1":
        print("REFUSED: this probe must be launched from a Herdr-managed pane.")
        return 2
    probe = ClientProbe()
    try:
        probe.start()
        if suspension_only:
            probe.case("direct native suspension retains alias with recovery disabled", probe.claude_suspension_without_recovery)
            artifact_root = pathlib.Path(os.environ.get(EVIDENCE_DIR, pathlib.Path.home() / ".claude/artifacts/377/proof"))
            artifact_root.mkdir(parents=True, exist_ok=True)
            artifact = artifact_root / f"suspension-proof-{uuid.uuid4().hex}.json"
            atomic_write(artifact, {"results": probe.results})
            print(f"EVIDENCE: {artifact}")
            return 0 if all(result["status"] == "PASS" for result in probe.results) else 1
        probe.case("OpenCode early exit releases its unknown claim without successor", probe.opencode_early_exit)
        probe.case("OpenCode TUI exec exits before its first lifecycle report", probe.opencode_no_prompt_quit)
        probe.case("Pi invalid noninteractive launch releases false-positive claim and native control works", probe.pi_non_tty)
        probe.case("Pi valid non-TTY print mode preserves real output, exact status, and cleanup", probe.pi_print_mode_parity)
        probe.case("interactive Pi retains canonical alias and real Herdr takeover", probe.pi_interactive)
        probe.case("native and wrapped Pi preserve normal interactive quit status", probe.pi_normal_quit_parity)
        probe.case("native and wrapped Pi preserve interactive Ctrl-C behavior and status", probe.pi_ctrl_c_parity)
        probe.case("native and wrapped OpenCode preserve foreground PTY Ctrl-C status", probe.opencode_ctrl_c_parity)
        probe.case("native and wrapped OpenCode preserve foreground PTY TERM status", probe.opencode_term_parity)
        probe.case("native and wrapped OpenCode preserve normal TUI quit status", probe.opencode_normal_quit_parity)
        probe.case("native and wrapped Pi preserve foreground PTY TERM status", probe.pi_term_parity)
        probe.case("cci crash preserves the bound live native client until its own exit", probe.claude_relation_and_handoff)
        probe.case("real Claude /exit preserves normal native exit status", probe.claude_normal_exit)
        probe.case("real Claude first prompt publishes retained-alias lifecycle handoff", probe.claude_first_prompt_handoff)
        probe.case("native and wrapped Claude preserve normal interactive quit status", probe.claude_normal_quit_parity)
        probe.case("native and wrapped Claude preserve interactive Ctrl-C behavior and status", probe.claude_ctrl_c_parity)
        probe.case("native and wrapped Claude preserve TERM behavior and exact cci status", probe.claude_term_parity)
        probe.case("OpenCode foreground group stops, survives observation, resumes, and exits", probe.opencode_stop_resume)
        probe.case("Pi foreground group stops, survives observation, resumes, and exits", probe.pi_stop_resume)
        probe.case("Claude foreground group stops, survives observation, resumes, and exits", probe.claude_stop_resume)
        artifact_root = pathlib.Path(os.environ.get(EVIDENCE_DIR, pathlib.Path.home() / ".claude/artifacts/377/proof"))
        artifact_root.mkdir(parents=True, exist_ok=True)
        artifact = artifact_root / f"client-proof-{uuid.uuid4().hex}.json"
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
    parser.add_argument("--terminal-driver", action="store_true")
    parser.add_argument("--suspension-diagnostic", action="store_true")
    parser.add_argument("--driver-receipt")
    parser.add_argument("--cwd")
    parser.add_argument("--agent", choices=CLIENTS)
    parser.add_argument("--sequence", type=int)
    parser.add_argument("--alias")
    parser.add_argument("--intent-dir")
    parser.add_argument("--receipt")
    parser.add_argument("--launcher")
    parser.add_argument("client_args", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    arguments.driver_command = arguments.client_args
    if arguments.terminal_driver:
        return terminal_driver(arguments)
    if arguments.prelaunch:
        if arguments.client_args[:1] == ["--"]:
            arguments.client_args = arguments.client_args[1:]
        prelaunch(arguments)
        return 0
    return run_probe(arguments.suspension_diagnostic)


if __name__ == "__main__":
    sys.exit(main())
