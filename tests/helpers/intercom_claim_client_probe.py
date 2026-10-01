#!/usr/bin/env python3
"""Opt-in live-client conformance probe for Intercom launch claims.

This deliberately runs installed clients in a disposable Herdr server. Runtime
cases stage and execute the checkout launcher, recovery engine, bridge, and
native leaf. They discover the durable intent the launcher actually creates.
"""

import argparse
import json
import os
import pathlib
import shlex
import shutil
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import uuid

from intercom_claim_ownership_probe import (
    EVIDENCE_DIR,
    OPT_IN,
    OwnedHerdr,
    ProbeError,
    RecoveryJob,
    native_executable,
    require,
    durable_intent,
    report,
    release,
    OLD_SOURCE,
)
from intercom_claim_recovery_prototype import (
    CONTROL_ENV,
    TRACE_ENV,
    atomic_write,
    bound_request,
    capture_server_identity,
    process_start_identity,
    read_intent as read_json,
    intent_handles,
    reserve_sequence,
    observe_one,
    trace_dir as probe_trace_dir,
)


ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = "mms-377-live-client"
# PR #378's accepted launcher is byte-for-byte identical at this merge commit.
REFERENCE = "dc33b385891fdab07af303037cc1ad2e3e161471"
CLIENTS = ("opencode", "pi", "claude")


class HerdrResponseRelay:
    """Forward real RPCs, optionally losing the first acknowledged rename reply."""

    def __init__(self, path, upstream, drop_rename=False):
        self.path = path
        self.upstream = upstream
        self.drop_rename = drop_rename
        self.dropped = []
        relay = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                line = self.rfile.readline(1024 * 1024)
                if not line:
                    return  # Peer-identity probes connect without sending an RPC.
                request = json.loads(line)
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                    connection.settimeout(5)
                    connection.connect(relay.upstream)
                    connection.sendall(line)
                    with connection.makefile("rb") as stream:
                        response = stream.readline(1024 * 1024)
                if relay.drop_rename and request["method"] == "agent.rename" and not relay.dropped:
                    relay.dropped.append({"request": request, "response": json.loads(response)})
                    return
                self.wfile.write(response)

        self.server = socketserver.ThreadingUnixStreamServer(str(path), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.path.unlink()


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
    stderr_path = os.environ.get("MMS377_DRIVER_STDERR")
    stderr = open(stderr_path, "w", encoding="utf-8") if stderr_path else sys.stderr
    try:
        process = subprocess.Popen(command, cwd=arguments.cwd, stdin=sys.stdin, stdout=sys.stdout, stderr=stderr)
    finally:
        if stderr_path:
            stderr.close()
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


class ClientProbe:
    def __init__(self):
        self.scratch = pathlib.Path(tempfile.mkdtemp(prefix="mms377-client-proof-", dir="/tmp"))
        # Probe-side hooks read the control root from the environment. A nested
        # probe takes it over until its close() hands it back.
        self.control = str(self.scratch / "probe-control")
        self.previous_control = os.environ.get(CONTROL_ENV)
        self.owner = OwnedHerdr()
        self.launchd = None
        self.root_pane = None
        self.results = []
        self.processes = {}
        self.driver_receipts = {}
        self.quit_steps = {}
        self.foreground_groups = {}
        os.environ[CONTROL_ENV] = self.control
        try:
            self.aliases = self.pool_aliases()
            self.launcher = self.scratch / "herdr-agent-intercom"
            self.stage()
        except Exception:
            # No server or client has started while staging these owned files.
            self.restore_control()
            shutil.rmtree(self.scratch)
            shutil.rmtree(self.owner.root)
            raise

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
        self.reference_launcher = self.scratch / "reference-herdr-agent-intercom"
        self.reference_launcher.write_text(launcher.stdout, encoding="utf-8")
        self.reference_launcher.chmod(0o700)
        self.runtime_home = self.scratch / "runtime-home"
        self.runtime_bin = self.runtime_home / ".local/bin"
        self.runtime_lib = self.runtime_home / ".local/lib"
        self.runtime_state = self.runtime_home / ".local/state"
        self.runtime_root = self.runtime_state / "agent-intercom/recovery/v1"
        self.runtime_bin.mkdir(parents=True, exist_ok=True)
        self.runtime_lib.mkdir(parents=True, exist_ok=True)
        for name in ("herdr-agent-intercom", "herdr-agent-intercom-release", "herdr-agent-intercom-claude"):
            target = self.runtime_bin / name
            shutil.copy2(ROOT / "home/dot_local/bin" / ("executable_" + name), target)
            target.chmod(0o700)
        shutil.copy2(ROOT / "home/dot_local/lib/executable_herdr-agent-intercom-native-claude",
                     self.runtime_lib / "herdr-agent-intercom-native-claude")
        (self.runtime_lib / "herdr-agent-intercom-native-claude").chmod(0o700)
        self.launcher = self.runtime_bin / "herdr-agent-intercom"
        self.release_entrypoint = self.runtime_bin / "herdr-agent-intercom-release"
        self.runtime_label = "dev.seigiard.mms377.client." + uuid.uuid4().hex
        # The job stages the probe engine entry as this runtime home's engine.
        self.recovery_job = RecoveryJob(self.runtime_home, self.runtime_label)
        self.runtime_plist = pathlib.Path(self.recovery_job.plist)
        self.claude_settings = self.scratch / "claude-settings.json"
        atomic_write(self.claude_settings, {"hooks": {"UserPromptSubmit": [{"hooks": [{
            "type": "command", "command": str(self.release_entrypoint), "timeout": 10,
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
        self.launchd = self.recovery_job
        self.launchd.start()

    def intent_paths(self):
        return {pathlib.Path(path) for path in intent_handles(self.launchd.intent_dir)}

    def restore_control(self):
        if self.previous_control is None:
            os.environ.pop(CONTROL_ENV, None)
        else:
            os.environ[CONTROL_ENV] = self.previous_control

    def close(self):
        self.restore_control()
        errors = []
        launchd_stopped = True
        for pid, client in self.foreground_groups.items():
            try:
                if process_start_identity(pid) != client["start_identity"]:
                    continue
                if os.getpgid(pid) != client["process_group"]:
                    raise ProbeError("owned client changed process group before cleanup")
                os.killpg(client["process_group"], signal.SIGTERM)
                os.killpg(client["process_group"], signal.SIGCONT)
                try:
                    wait_until(lambda: process_start_identity(pid) != client["start_identity"], 3,
                               f"owned foreground client {pid} exit")
                except ProbeError:
                    if process_start_identity(pid) == client["start_identity"] and os.getpgid(pid) == client["process_group"]:
                        os.killpg(client["process_group"], signal.SIGKILL)
                    wait_until(lambda: process_start_identity(pid) != client["start_identity"], 5,
                               f"owned foreground client {pid} forced cleanup")
            except Exception as error:
                errors.append(f"owned foreground client cleanup failed: {error}")
        if self.launchd:
            # cci may already be gone while the bound native process remains.
            # Its durable identity is still owned, including after handoff.
            for path in self.intent_paths():
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
        exports = exports | {"HERDR_ENV": "1", "HERDR_PANE_ID": pane["pane_id"],
                             "HERDR_SOCKET_PATH": self.owner.socket_path}
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
        exports = {
            "MMS377_ALIAS": alias,
            "HERDR_ALIAS_ALLOCATOR": str(self.scratch / "aliases"),
            "INTERCOM_DIR": str(self.scratch / "intercom"),
            "XDG_CONFIG_HOME": str(self.scratch / "xdg/config"),
            "PI_CODING_AGENT_DIR": str(self.scratch / "pi"),
            "PI_CODING_AGENT_SESSION_DIR": str(self.scratch / "pi/sessions"),
            "MMS377_PI_OBSERVER": str(self.scratch / f"pi-{sequence}.observer.jsonl"),
            "HERDR_AGENT_INTERCOM_BIN_DIR": str(self.runtime_bin),
            "HERDR_AGENT_INTERCOM_LIB_DIR": str(self.runtime_lib),
            "HERDR_AGENT_INTERCOM_RECOVERY_LABEL": self.runtime_label,
            "HERDR_AGENT_INTERCOM_RECOVERY_PLIST": str(self.runtime_plist),
            "HERDR_AGENT_INTERCOM_PYTHON": sys.executable,
            CONTROL_ENV: self.control,
            "XDG_STATE_HOME": str(self.runtime_state),
        }
        # A parent agent's live recovery handle must never authorize this test
        # process. The staged launcher creates the only allowed handle.
        for name in os.environ:
            if name.startswith(("HERDR_AGENT_INTERCOM_", "AGENT_INTERCOM_", "CLAUDE_INTERCOM_")) or name == "OPENCODE_INTERCOM_NAME":
                if name not in exports:
                    exports[name] = ""
        return exports

    def reserve_sequence(self):
        return reserve_sequence(str(self.scratch / "sequences"), SOURCE)

    def launch(self, agent, args, *, interactive=False, alias_index=0, hold_group=False, offline=True, pane=None,
               claude_settings=None, trace=False, claim_required=True, extra_env=None):
        if agent == "claude":
            args = ["--settings", str(claude_settings or self.claude_settings), *args]
        if pane is None:
            pane = self.client_pane()
        alias = self.aliases[alias_index % len(self.aliases)]
        sequence = self.reserve_sequence()
        receipt = self.scratch / f"{agent}-{sequence}.receipt.json"
        log = self.scratch / f"{agent}-{sequence}.log"
        exit_file = self.scratch / f"{agent}-{sequence}.exit"
        command = [str(self.launcher), agent, *args]
        exports = self.foreground_exports(alias, sequence)
        exports.update(extra_env or {})
        if offline:
            exports["PI_OFFLINE"] = "1"
        if hold_group or trace:
            trace_dir = self.scratch / f"trace-{sequence}"
            trace_dir.mkdir()
            exports[TRACE_ENV] = str(trace_dir)
        if hold_group:
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
            driver = wait_until(lambda: value if (value := self.driver_details(receipt)) and "client_pid" in value else None,
                                8, f"{agent} runtime terminal driver") if interactive else None
            terminal_id = pane["terminal_id"]
            def actual_intent():
                matches = []
                for path in self.intent_paths():
                    value = read_json(path)
                    if (value.get("terminal", {}).get("terminal_id") == terminal_id and
                            value.get("agent_kind") == agent and value.get("acquired_at_ns")):
                        matches.append((path, value))
                return matches[0] if len(matches) == 1 else None
            found = wait_until(actual_intent, 12, f"actual {agent} launcher intent") if claim_required else None
            if found:
                path, intent = found
                client = intent.get("launcher_client", intent["client"])
                actual_pid = driver["client_pid"] if interactive else process.pid
                require({"step": f"{agent}-runtime-exec-pid"}, actual_pid == client["pid"],
                        f"runtime intent followed a helper instead of exec client: pid={actual_pid}; intent={intent}")
                atomic_write(receipt, {"pid": actual_pid, "start_identity": client["start_identity"],
                                       "intent": str(path), "alias": alias,
                                       "agent": agent, "stdin_isatty": interactive, "stdout_isatty": interactive,
                                       "pi_observer": exports["MMS377_PI_OBSERVER"]})
            else:
                # Non-TTY utility controls deliberately bypass enrollment.
                actual_pid = driver["client_pid"] if interactive else process.pid
                atomic_write(receipt, {"pid": actual_pid, "intent": None, "alias": alias, "agent": agent,
                                       "stdin_isatty": interactive, "stdout_isatty": interactive,
                                       "pi_observer": exports["MMS377_PI_OBSERVER"]})
        except ProbeError as error:
            contents = log.read_text(encoding="utf-8") if log.exists() else "<no client log>"
            driver = self.driver_receipts.get(str(receipt))
            driver_state = read_json(driver) if driver and driver.exists() else "<no driver receipt>"
            pane_state = self.pane_visible(pane)[-4000:] if interactive else "<noninteractive>"
            raise ProbeError(
                f"{error}; driver={driver_state}; pane={pane_state}; client-log={contents[-4000:]}"
            ) from error
        return pane, receipt, log, exit_file

    def claude_settings_with_hook(self, name, command):
        path = self.scratch / f"claude-settings-{name}.json"
        atomic_write(path, {"hooks": {"UserPromptSubmit": [{"hooks": [{
            "type": "command", "command": command, "timeout": 15,
        }]}]}})
        return path

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
        path = read_json(receipt).get("pi_observer")
        if not path:
            raise ProbeError(f"Pi receipt did not record its observer path: {receipt}")
        observer = pathlib.Path(path)
        if not observer.exists():
            return []
        lines = observer.read_text(encoding="utf-8").splitlines()
        return [json.loads(line) for line in lines]

    def process_state(self, pid):
        result = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], text=True,
                                capture_output=True, check=False)
        return result.stdout.strip() if result.returncode == 0 else None

    def native_input_ready(self, pid):
        result = subprocess.run(["ps", "-p", str(pid), "-o", "tty=,tpgid="], text=True, capture_output=True, check=False)
        fields = result.stdout.split()
        if result.returncode or len(fields) != 2:
            return False
        tty, foreground_group = fields
        if not (tty.startswith("ttys") or tty.startswith("pts/")):
            return False
        try:
            descriptor = os.open("/dev/" + tty, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
            try:
                flags = termios.tcgetattr(descriptor)[3]
                return not flags & (termios.ICANON | termios.ECHO) and int(foreground_group) == os.getpgid(pid)
            finally:
                os.close(descriptor)
        except (OSError, termios.error):
            return False

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

    def resume_shell_job(self, pane, job_pid):
        parent = subprocess.run(["ps", "-p", str(job_pid), "-o", "ppid="], text=True,
                                capture_output=True, check=False)
        require({"step": "resume-shell-parent"}, parent.returncode == 0,
                f"cannot identify the job's shell: {parent.stderr}")
        shell_group = os.getpgid(int(parent.stdout.strip()))
        def shell_foreground():
            result = subprocess.run(["ps", "-p", str(job_pid), "-o", "tpgid="], text=True,
                                    capture_output=True, check=False)
            return result.returncode == 0 and result.stdout.strip() == str(shell_group)
        wait_until(shell_foreground, 5, "shell foreground after suspension")
        def shell_prompt():
            tail = [line for line in self.pane_visible(pane).splitlines() if line.strip()][-3:]
            return any(line.strip().endswith("❯") for line in tail) and not any("──────────" in line for line in tail)
        wait_until(shell_prompt, 10, "owned shell input prompt after suspension")
        # Submit only after the empty shell prompt is visible. A logical Ctrl-U
        # can be Kitty-encoded from the suspended client's modes and become text.
        self.owner.run("pane", "run", pane["pane_id"], "fg")

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
            if not self.native_input_ready(pid):
                return None
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
                client = self.native_process(intent["client"]["pid"], "claude")
            if not client:
                return None
            if not self.native_input_ready(client["pid"]):
                return None
            result = self.owner.run("agent", "explain", pane["pane_id"], "--json", expected=None)
            if result.returncode:
                if "agent_not_found" in result.stderr:
                    return None
                raise ProbeError(f"Claude input readiness lookup failed: {result.stderr}")
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

    def known_upstream_case(self, name, action):
        began = time.monotonic()
        try:
            details = action()
            status = details["classification"]
            require({"step": "suspension-classification"}, status in {"PASS", "KNOWN_UPSTREAM_LIMITATION"},
                    f"unexpected suspension verdict: {status}")
        except ProbeError as error:
            details = {"error": str(error), **getattr(error, "evidence", {})}
            status = "FAIL"
        except Exception as error:
            details = {"error": f"unexpected {type(error).__name__}: {error}"}
            status = "FAIL"
        details["elapsed_seconds"] = round(time.monotonic() - began, 3)
        self.results.append({"case": name, "status": status, "details": details})
        print(f"{status}: {name}: {json.dumps(details, sort_keys=True)}")

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
        before = self.intent_paths()
        pane, receipt, log, exit_file = self.launch("pi", ["--invalid-option"], claim_required=False)
        status = self.wait_exit(log, exit_file, receipt)
        state = self.state(pane)
        require({"step": "pi-non-tty-bypass"}, (state is None or not state.get("name")) and
                self.intent_paths() == before,
                "non-TTY Pi launch entered runtime claim recovery")
        control = subprocess.run([native_executable("pi"), "--version"], text=True, capture_output=True, check=False)
        require({"step": "pi-native-control"}, control.returncode == 0, "native Pi utility control failed")
        return {"status": status, "runtime_bypass": True, "control": {"status": control.returncode,
                "stdout": control.stdout, "stderr": control.stderr}, "log": log.read_text(encoding="utf-8")[-2000:]}

    def pi_known_utility_bypasses_claim(self):
        pane = self.client_pane()
        require({"step": "pi-utility-empty-pane"}, self.state(pane) is None,
                "utility bypass control did not start with an empty pane")
        before = self.intent_paths()
        sequence = self.reserve_sequence()
        receipt = self.scratch / f"pi-utility-{sequence}.receipt.json"
        calls = self.scratch / f"pi-utility-{sequence}.calls.jsonl"
        tap_dir = self.scratch / f"pi-utility-{sequence}.bin"
        tap_dir.mkdir()
        real_herdr = shutil.which("herdr")
        require({"step": "pi-utility-herdr"}, real_herdr is not None, "real Herdr CLI is unavailable")
        tap = tap_dir / "herdr"
        # Record actual CLI invocations, then let the installed server answer.
        # A bare utility may be screen-detected without acquiring any claim.
        tap.write_text(
            f"#!{sys.executable}\nimport json, os, sys\n"
            f"with open({str(calls)!r}, 'a') as log: log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            f"os.execv({real_herdr!r}, [{real_herdr!r}, *sys.argv[1:]])\n",
            encoding="utf-8",
        )
        tap.chmod(0o700)
        exports = self.foreground_exports(self.aliases[2], sequence) | {
            "PATH": str(tap_dir) + os.pathsep + os.environ["PATH"],
        }
        self.start_foreground_driver(pane, receipt, [str(self.launcher), "pi", "--version"],
                                     exports, f"pi-utility-{sequence}")
        status = self.wait_exit(None, None, receipt)
        require({"step": "pi-utility-status"}, status == 0, f"runtime utility exited {status}")
        observed_calls = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
        mutations = [args for args in observed_calls if any(args[index:index + 2] in (
            ["pane", "report-agent"], ["pane", "release-agent"], ["agent", "rename"])
            for index in range(len(args) - 1))]
        require({"step": "pi-utility-no-claim"}, mutations == [],
                f"known Pi utility mode attempted enrollment mutations: {mutations}")
        state = self.state(pane)
        require({"step": "pi-utility-no-alias"}, state is None or not state.get("name"),
                f"known Pi utility mode acquired an alias: {state}")
        after = self.intent_paths()
        require({"step": "pi-utility-no-intent"}, after == before,
                f"known Pi utility mode created durable intent(s): {after - before}")
        return {"status": status, "driver": self.driver_details(receipt), "intent_count": len(after),
                "herdr_calls": observed_calls, "state": state}

    def claude_late_bind_r10_fallback(self):
        native_pane, native_receipt = self.launch_native("claude", ["--no-chrome"])
        self.wait_client_ready("claude", native_pane, native_receipt, native=True)
        native_state = self.state(native_pane)
        require({"step": "r10-native-control"}, native_state is not None and not native_state.get("name"),
                f"bare native Claude unexpectedly has a launcher alias: {native_state}")
        self.send_normal_quit("claude", native_pane, native_receipt, None, None)
        pane = self.client_pane()
        sequence = self.reserve_sequence()
        receipt = self.scratch / f"r10-claude-{sequence}.receipt.json"
        stderr = self.scratch / f"r10-claude-{sequence}.stderr"
        before = self.intent_paths()
        settled = self.scratch / f"r10-settled-{sequence}.json"
        atomic_write(settled, {"phase": "settled"})
        exports = self.foreground_exports("r10-fallback", sequence) | {
            "HERDR_AGENT_INTERCOM_RECOVERY_INTENT": str(settled),
            "AGENT_INTERCOM_CLAUDE_COMMAND": native_executable("claude"),
            "AGENT_INTERCOM_CLAUDE_ARGC": "1", "AGENT_INTERCOM_CLAUDE_ARG_0": "--no-chrome",
            "MMS377_DRIVER_STDERR": str(stderr),
        }
        self.start_foreground_driver(pane, receipt, [str(self.runtime_bin / "herdr-agent-intercom-claude")],
                                     exports, f"r10-claude-{sequence}")
        ready = self.wait_client_ready("claude", pane, receipt, native=True)
        fallback_state = self.state(pane)
        require({"step": "r10-claude-late-bind-no-claim"}, fallback_state is not None and not fallback_state.get("name") and
                self.intent_paths() == before,
                f"late bridge fallback acquired a claim: {fallback_state}")
        warning = stderr.read_text(encoding="utf-8")
        require({"step": "r10-warning"}, "starting native Claude without enrollment" in warning,
                f"late bind did not warn: {warning}")
        status = self.send_normal_quit("claude", pane, receipt, None, None)
        return {"ready": ready, "status": status, "native_state": native_state, "state": fallback_state,
                "driver": self.driver_details(receipt), "warning": stderr.read_text(encoding="utf-8")[-1000:]}

    def initial_admission_failure(self, fault):
        pane = self.client_pane()
        before = self.intent_paths()
        pane_before = self.state(pane)
        require({"step": "admission-fallback-empty-pane"}, pane_before is None,
                f"admission fallback did not start from an empty pane: {pane_before}")
        sequence = self.reserve_sequence()
        receipt = self.scratch / f"admission-r10-{sequence}.receipt.json"
        stderr = self.scratch / f"admission-r10-{sequence}.stderr"
        exports = self.foreground_exports(self.aliases[15 % len(self.aliases)], sequence) | {
            "MMS377_DRIVER_STDERR": str(stderr),
        }
        intent_dir = pathlib.Path(self.launchd.intent_dir)
        displaced = self.scratch / f"admission-intents-backup-{sequence}"
        command = [str(self.launcher), "opencode"]
        if fault in {"server", "client"}:
            fault_bin = self.scratch / f"admission-ps-{sequence}"
            fault_bin.mkdir()
            real_ps = shutil.which("ps")
            require({"step": "admission-fallback-real-ps"}, real_ps is not None, "real ps is unavailable")
            # Fail one actual identity reader; all other ps calls stay real.
            (fault_bin / "ps").write_text(
                "#!/bin/sh\ntarget=$MMS377_FAULT_IDENTITY_PID\n"
                "if [ -n \"${MMS377_FAULT_PID_FILE:-}\" ]; then target=$(cat \"$MMS377_FAULT_PID_FILE\"); fi\n"
                "previous=\nfor argument in \"$@\"; do\n"
                "  if [ \"$previous\" = -p ] && [ \"$argument\" = \"$target\" ]; then exit 1; fi\n"
                "  previous=$argument\ndone\n"
                f"exec {shlex.quote(real_ps)} \"$@\"\n", encoding="utf-8",
            )
            (fault_bin / "ps").chmod(0o700)
            exports.update(MMS377_FAULT_IDENTITY_PID=str(self.owner.server_identity["pid"]),
                           PATH=str(fault_bin) + os.pathsep + os.environ["PATH"])
            if fault == "client":
                pid_file = self.scratch / f"fault-client-{sequence}.pid"
                wrapper = self.scratch / f"fault-client-{sequence}.sh"
                wrapper.write_text("#!/bin/sh\nprintf '%s' \"$$\" > " + shlex.quote(str(pid_file)) +
                                   "\nexec " + shlex.join(command) + "\n", encoding="utf-8")
                wrapper.chmod(0o700)
                exports["MMS377_FAULT_PID_FILE"] = str(pid_file)
                command = [str(wrapper)]
        elif fault == "intent":
            self.launchd.close()
            intent_dir.rename(displaced)
            intent_dir.write_text("not a directory\n", encoding="utf-8")
        elif fault == "owner":
            exports["HERDR_AGENT_INTERCOM_RECOVERY_PLIST"] = str(self.scratch / "missing-owner.plist")
        else:
            raise ProbeError(f"unknown admission fault: {fault}")
        try:
            self.start_foreground_driver(pane, receipt, command, exports, f"admission-r10-{sequence}")
            driver = self.wait_driver(receipt, "running")
            ready = self.wait_client_ready("opencode", pane, receipt, native=True)
            native = ready["native"]
            require({"step": "admission-fallback-pid"}, driver["client_pid"] == native["pid"],
                    f"admission fallback changed the exec PID: {driver}; {native}")
            warning = stderr.read_text(encoding="utf-8")
            require({"step": "admission-fallback-warning"}, "unavailable" in warning,
                    f"admission fallback warning was absent: {warning[-2000:]}")
            fallback_state = self.state(pane)
            require({"step": "admission-fallback-no-alias"}, fallback_state is None or not fallback_state.get("name"),
                    f"admission fallback acquired a launcher alias: {fallback_state}")
            status = self.send_normal_quit("opencode", pane, receipt, None, None)
        finally:
            if displaced.exists():
                intent_dir.unlink()
                displaced.rename(intent_dir)
                self.launchd.start()
        require({"step": "admission-fallback-no-intent"}, self.intent_paths() == before,
                "admission fallback created a durable intent")
        return {"fault": fault, "state": fallback_state, "native": native,
                "warning": warning[-1000:], "status": status, "driver": self.driver_details(receipt)}

    def opencode_initial_admission_r10_fallback(self):
        # A real admitted launch remains the positive control.
        control_pane, control_receipt, control_log, control_exit = self.launch("opencode", [], interactive=True,
                                                                             alias_index=15)
        control = read_json(control_receipt)
        self.wait_client_ready("opencode", control_pane, control_receipt)
        control_state = self.state(control_pane)
        require({"step": "admission-control-claim"}, control_state is not None and
                control_state.get("name") == control["alias"],
                f"successful admission did not publish the expected alias: {control_state}")
        self.send_normal_quit("opencode", control_pane, control_receipt, control_log, control_exit)
        self.wait_settled(control_receipt, control_pane)
        failures = {fault: self.initial_admission_failure(fault) for fault in ("owner", "intent", "server", "client")}
        return {"control": control_state, "failure_controls": failures}

    def alias_reuse_refreshes_a_stale_read(self):
        pane = self.client_pane()
        alias = self.aliases[0]
        command = [sys.executable, str(self.runtime_lib / "intercom-claim-recovery.py"),
                   "--reuse-alias", str(self.runtime_root), "--alias", alias,
                   "--owner-label", self.runtime_label, "--owner-plist", str(self.runtime_plist)]
        env = self.owner.env | {"HERDR_PANE_ID": pane["pane_id"], "HERDR_SOCKET_PATH": self.owner.socket_path}
        try:
            require({"step": "reuse-absent-control"}, self.state(pane) is None, "control pane already has a record")
            absent = subprocess.run(command, env=env, text=True, capture_output=True, timeout=15)
            require({"step": "reuse-refresh-status"}, absent.returncode == 0, f"alias revalidation failed: {absent.stderr}")
            require({"step": "reuse-refresh-absence"}, json.loads(absent.stdout) == {"alias": ""},
                    f"empty recovery directory licensed a stale alias: {absent.stdout}")
            self.owner.run("pane", "report-agent", pane["pane_id"], "--source", "reuse-control",
                           "--agent", "claude", "--state", "working", "--seq", str(self.reserve_sequence()))
            self.owner.run("agent", "rename", pane["pane_id"], alias)
            present = subprocess.run(command, env=env, text=True, capture_output=True, timeout=15)
            require({"step": "reuse-independent-status"}, present.returncode == 0,
                    f"independent identity was rejected: {present.stderr}")
            require({"step": "reuse-independent-alias"}, json.loads(present.stdout) == {"alias": alias},
                    "independent existing alias was not preserved")
            return {"absent": json.loads(absent.stdout), "present": json.loads(present.stdout)}
        finally:
            self.owner.run("pane", "close", pane["pane_id"])

    def alias_reuse_preserves_successor_identity(self):
        from intercom_alias_reuse_probe import run_order
        observations = {}
        for name, early in (("late_observation_after_detection", False), ("late_observation_before_detection", True)):
            isolated = ClientProbe()
            try:
                isolated.start()
                observations[name] = run_order(isolated, early)
            finally:
                isolated.close()
        return observations

    def alias_collision_rolls_back_and_retries(self):
        # Restore base test 1346's stale first candidate, now with real Herdr.
        occupied = self.client_pane()
        first, second = self.aliases[:2]
        sequence = self.reserve_sequence()
        self.owner.run("pane", "report-agent", occupied["pane_id"], "--source", "collision-control",
                       "--agent", "claude", "--state", "working", "--seq", str(sequence))
        self.owner.run("agent", "rename", occupied["pane_id"], first)
        protected = self.state(occupied)
        require({"step": "collision-occupied-control"}, protected is not None and protected.get("name") == first,
                "collision control did not establish the first alias owner")
        stub = self.scratch / f"collision-{sequence}.bin"
        stub.mkdir()
        calls = self.scratch / f"collision-{sequence}.calls"
        peer = stub / "herdr-peer-alias"
        peer.write_text(
            "#!/bin/sh\nshift\n"
            f"printf '%s\\n' \"$*\" >> {shlex.quote(str(calls))}\n"
            "for taken in \"$@\"; do\n"
            f"  [ \"$taken\" != {shlex.quote(first)} ] || {{ printf '%s\\n' {shlex.quote(second)}; exit 0; }}\n"
            "done\n"
            f"printf '%s\\n' {shlex.quote(first)}\n", encoding="utf-8")
        peer.chmod(0o700)
        before = self.intent_paths()
        pane, receipt, log, exit_file = self.launch(
            "claude", ["--no-chrome"], interactive=True, alias_index=1, trace=True,
            extra_env={"PATH": str(stub) + os.pathsep + os.environ["PATH"]})
        self.wait_claude_ready(pane, receipt)
        paths = self.intent_paths() - before
        require({"step": "collision-attempt-count"}, len(paths) == 2,
                f"expected rejected and successful attempts, got {paths}")
        attempts = sorted((read_json(path) for path in paths), key=lambda item: item["claim"]["claim_seq"])
        rejected, acquired = attempts
        require({"step": "collision-rollback"}, rejected["phase"] == "settled" and
                rejected["diagnostic"] == "settled: alias acquisition rejected",
                f"rejected alias was not rolled back: {rejected}")
        require({"step": "collision-next-generation"}, acquired["phase"] == "acquired" and
                acquired["claim"]["claim_seq"] > rejected["claim"]["release_seq"],
                f"retry did not reserve a later generation: {attempts}")
        mutations = [read_json(path) for path in pathlib.Path(probe_trace_dir(rejected)).glob("*.mutation_attempt.*.json")]
        releases = [item for item in mutations if item["method"] == "pane.release_agent"]
        require({"step": "collision-reserved-release"}, len(releases) == 1 and releases[0]["params"] == {
            "pane_id": pane["pane_id"], "source": rejected["claim"]["source"], "agent": "claude",
            "seq": rejected["claim"]["release_seq"]}, "rollback did not use its reserved release")
        require({"step": "collision-excludes-first-candidate"}, calls.read_text() == f"\n{first}\n",
                f"retry did not exclude the rejected candidate: {calls.read_text()!r}")
        state = self.state(pane)
        require({"step": "collision-second-alias"}, state is not None and state.get("name") == second,
                f"client did not enroll under the second alias: {state}")
        after = self.state(occupied)
        keys = ("name", "terminal_id", "agent", "agent_status", "agent_session")
        require({"step": "collision-other-owner-preserved"}, after is not None and
                {key: after.get(key) for key in keys} == {key: protected.get(key) for key in keys},
                f"rollback disturbed the first alias owner: {protected} -> {after}")
        status = self.send_normal_quit("claude", pane, receipt, log, exit_file)
        self.wait_settled(receipt, pane)
        self.owner.run("pane", "close", occupied["pane_id"])
        return {"attempts": attempts, "candidate_calls": calls.read_text(), "successor": state,
                "protected_before": protected, "protected_after": after, "status": status}

    def claude_relaunch_in_used_pane_reconciles(self):
        # tests/test_intercom_claim_admission.py models how a used pane answers a
        # declared claim. This case asks the real Herdr the same question: launch,
        # exit, relaunch in the same pane, then reconcile at the first prompt.
        pane, receipt, log, exit_file = self.launch("claude", ["--no-chrome"], interactive=True, alias_index=17)
        self.wait_claude_ready(pane, receipt)
        self.send_normal_quit("claude", pane, receipt, log, exit_file)
        first = self.wait_completed(receipt, pane)
        used = self.stable_terminal(pane)
        require({"step": "relaunch-used-pane-shape"}, "agent_session" not in used,
                f"pane get still carries the exited client's identity, so the relaunch skips admission: {used}")

        before = self.intent_paths()
        alias = self.aliases[18 % len(self.aliases)]
        stderr = self.scratch / f"relaunch-{time.time_ns()}.stderr"
        _, receipt, log, exit_file = self.launch(
            "claude", ["--no-chrome"], interactive=True, alias_index=18, pane=pane, trace=True,
            claim_required=False, extra_env={"MMS377_DRIVER_STDERR": str(stderr)})
        driver = self.wait_driver(receipt, "running")

        def rejected():
            paths = self.intent_paths() - before
            if len(paths) != 1:
                return None
            value = read_json(next(iter(paths)))
            return value if value.get("phase") == "settled" else None
        intent = wait_until(rejected, 12, "relaunch admission settlement")
        require({"step": "relaunch-claim-rejected"}, intent.get("diagnostic") == "settled: alias acquisition rejected",
                f"relaunch admission did not settle as a rejected claim: {intent}")
        renames = [read_json(path) for path in pathlib.Path(probe_trace_dir(intent)).glob("*.rename_result.*.json")]
        require({"step": "relaunch-rename-not-found"}, [(item["params"]["name"], item["response"].get("error", {}).get("code"))
                                                         for item in renames] == [(alias, "agent_not_found")],
                f"a used pane did not answer the declared rename with agent_not_found: {renames}")

        def native_ready():
            # A fallback launch execs native Claude as the driver's own client.
            candidates = [driver["client_pid"], *(pid for pid, _, _ in self.descendants(driver["client_pid"]))]
            for pid in candidates:
                client = self.native_process(pid, "claude")
                if client and self.native_input_ready(pid):
                    return client
            return None
        client = wait_until(native_ready, 20, "relaunched native Claude input")
        try:
            warnings = stderr.read_text(encoding="utf-8") if stderr.exists() else ""
            require({"step": "relaunch-no-fallback-warning"}, "herdr-agent-intercom:" not in warnings,
                    f"relaunch fell back instead of enrolling: {warnings}")
            pane_key = "".join(character if character.isalnum() else "_" for character in pane["pane_id"])
            note = self.runtime_state / "agent-intercom/reconcile" / pane_key
            require({"step": "relaunch-reconcile-note"}, note.exists() and note.read_text(encoding="utf-8") == alias + "\n",
                    f"relaunch did not record its pending rename to {alias}")
            identity = wait_until(lambda: self.intercom_identity(alias), 15, "relaunched Claude Intercom registration")
            # The hook leaves the rename to a later prompt while no record exists,
            # so prompt only after Claude's own session report created one.
            detected = self.wait_claude_session(pane)
            require({"step": "relaunch-detected-record-unnamed"}, not detected.get("name"),
                    f"the relaunched record already carries a name before reconciliation: {detected}")

            self.owner.run("pane", "send-text", pane["pane_id"], "Reply with OK only.")
            self.owner.run("pane", "send-keys", pane["pane_id"], "enter")
            try:
                reconciled = wait_until(
                    lambda: state if (state := self.state(pane)) and state.get("name") == alias else None,
                    20, "first-prompt rename of the relaunched Claude record",
                )
            except ProbeError as error:
                raise ProbeError(
                    f"{error}; state={self.state(pane)}; note={note.read_text(encoding='utf-8') if note.exists() else None}; "
                    f"pane_get={self.stable_terminal(pane)}; screen={self.pane_visible(pane)[-3000:]}"
                ) from error
            wait_until(lambda: not note.exists(), 5, "reconcile note removal after the rename")
            return {"first": first["intent"]["phase"], "used_pane": used, "intent": intent, "renames": renames,
                    "identity": identity, "detected": detected, "reconciled": reconciled}
        finally:
            if process_start_identity(client["pid"]) == client["start_identity"]:
                os.kill(client["pid"], signal.SIGTERM)
            self.wait_exit(log, exit_file, receipt, timeout=15)

    def runtime_owner_recovers_stale_readiness_and_crash(self):
        ready_path = self.runtime_root / "observer.ready"
        original = read_json(ready_path)
        atomic_write(ready_path, original | {"start_identity": "stale-readiness-control"})
        pane, receipt, log, exit_file = self.launch("opencode", [], interactive=True, trace=True)
        native = self.wait_client_ready("opencode", pane, receipt)["native"]
        admitted = read_json(ready_path)
        require({"step": "stale-ready-replaced"}, admitted["pid"] != original["pid"] and
                process_start_identity(admitted["pid"]) == admitted["start_identity"] and
                process_start_identity(original["pid"]) != original["start_identity"],
                "admission trusted stale readiness or left its former observer alive")
        require({"step": "owned-runtime-observer"}, admitted["job_label"] == self.runtime_label and
                admitted["intent_dir"] == str(pathlib.Path(self.launchd.intent_dir).resolve()),
                "observer receipt does not belong to this isolated runtime")
        os.kill(admitted["pid"], signal.SIGKILL)

        def restarted_owner():
            ready = read_json(ready_path)
            return ready if ready["pid"] != admitted["pid"] and \
                process_start_identity(ready["pid"]) == ready["start_identity"] else None

        restarted = wait_until(restarted_owner, 15, "production launchd observer restart")
        expected = read_json(receipt)
        state = self.state(pane)
        require({"step": "restarted-owner-preserves-client"}, state is not None and
                state.get("name") == expected["alias"] and
                process_start_identity(native["pid"]) == native["start_identity"],
                "observer restart disturbed the live client")
        os.kill(native["pid"], signal.SIGTERM)
        self.wait_exit(log, exit_file, receipt)
        completed = self.wait_settled(receipt, pane)
        return {"original": original, "admitted": admitted, "restarted": restarted,
                "native": native, "completed": completed}

    def partial_admission_preserves_native_startup(self):
        results = []
        for drop_response in (False, True):
            pane = self.client_pane()
            sequence = self.reserve_sequence()
            receipt = self.scratch / f"partial-{sequence}.receipt.json"
            native_env = self.scratch / f"partial-{sequence}.env.json"
            stderr = self.scratch / f"partial-{sequence}.stderr"
            wrapper_dir = self.scratch / f"partial-{sequence}.bin"
            wrapper_dir.mkdir()
            fields = ("OPENCODE_INTERCOM_NAME", "HERDR_AGENT_INTERCOM_ACTIVE",
                      "HERDR_AGENT_INTERCOM_NAME", "HERDR_AGENT_INTERCOM_PANE",
                      "HERDR_AGENT_INTERCOM_RECOVERY_INTENT", "HERDR_AGENT_INTERCOM_PI_LOAD")
            executable = native_executable("opencode")
            wrapper = wrapper_dir / "opencode"
            wrapper.write_text(
                f"#!{sys.executable}\nimport json,os,sys\n"
                f"with open({str(native_env)!r}, 'w') as stream: "
                f"json.dump({{key:os.environ.get(key) for key in {fields!r}}}, stream)\n"
                f"os.execv({executable!r}, [{executable!r}, *sys.argv[1:]])\n", encoding="utf-8")
            wrapper.chmod(0o700)
            inherited = self.scratch / f"parent-{sequence}.json"
            atomic_write(inherited, {"phase": "settled", "sentinel": "another-pane"})
            inherited_before = inherited.read_bytes()
            before = self.intent_paths()
            with HerdrResponseRelay(self.scratch / f"relay-{sequence}.sock",
                                    self.owner.socket_path, drop_response) as relay:
                exports = self.foreground_exports(self.aliases[15], sequence) | {
                    "PATH": str(wrapper_dir) + os.pathsep + os.environ["PATH"],
                    "MMS377_DRIVER_STDERR": str(stderr),
                    "OPENCODE_INTERCOM_NAME": "parent-alias", "HERDR_AGENT_INTERCOM_ACTIVE": "1",
                    "HERDR_AGENT_INTERCOM_NAME": "parent-alias", "HERDR_AGENT_INTERCOM_PANE": "other-pane",
                    "HERDR_AGENT_INTERCOM_RECOVERY_INTENT": str(inherited),
                    "HERDR_AGENT_INTERCOM_PI_LOAD": "parent-load",
                }
                self.start_foreground_driver(pane, receipt,
                                             ["env", f"HERDR_SOCKET_PATH={relay.path}", str(self.launcher), "opencode"], exports,
                                             f"partial-{sequence}")
                native = self.wait_client_ready("opencode", pane, receipt, native=True)["native"]
                driver = self.driver_details(receipt)
                require({"step": "partial-native-pid"}, native["pid"] == driver["client_pid"],
                        "partial acquisition fallback changed the exec PID")
                paths = self.intent_paths() - before
                require({"step": "partial-obligation"}, len(paths) == 1,
                        f"expected one durable launch obligation: {paths}")
                path = paths.pop()
                intent = read_json(path)
                require({"step": "partial-client-correlation"}, intent["client"] == {
                    "pid": native["pid"], "start_identity": native["start_identity"]},
                    "pending obligation lost its actual native process identity")
                environment = read_json(native_env)
                if drop_response:
                    require({"step": "partial-real-rename"}, len(relay.dropped) == 1 and
                            "error" not in relay.dropped[0]["response"],
                            f"fault did not lose a successful real rename response: {relay.dropped}; intent={intent}; stderr={stderr.read_text()}")
                    require({"step": "partial-native-authority"}, environment == dict.fromkeys(fields),
                            f"native fallback inherited enrollment authority: {environment}")
                    require({"step": "partial-pending"}, intent["phase"] == "intent",
                            f"unacknowledged acquisition was marked complete: {intent}")
                    require({"step": "partial-diagnostic"}, "partial claim remains pending" in stderr.read_text(),
                            "partial acquisition did not report its pending obligation")
                else:
                    require({"step": "partial-valid-control"}, intent["phase"] == "acquired" and
                            environment["HERDR_AGENT_INTERCOM_RECOVERY_INTENT"] == str(path) and
                            environment["OPENCODE_INTERCOM_NAME"] == self.aliases[15],
                            f"relay control did not complete real enrollment: {intent}; {environment}")
                state = self.state(pane)
                require({"step": "partial-published-alias"}, state is not None and
                        state.get("name") == self.aliases[15], "real rename did not publish the requested alias")
                require({"step": "partial-parent-preserved"}, inherited.read_bytes() == inherited_before,
                        "launch changed another pane's inherited obligation")
                self.send_normal_quit("opencode", pane, receipt, None, None)
                wait_until(lambda: self.state(pane) is None, 10,
                           "autonomous partial-claim cleanup after native exit")
                # An unacknowledged operation remains pending if Herdr clears
                # the record before the observer can witness its own release.
                after_exit = read_json(path)
                require({"step": "partial-correlation-retained"}, after_exit["client"] == intent["client"] and
                        after_exit["claim"] == intent["claim"],
                        "cleanup lost the unresolved acquisition's durable correlation")
                results.append({"drop_response": drop_response, "native": native, "intent_before_exit": intent,
                                "environment": environment, "dropped": relay.dropped,
                                "intent_after_exit": after_exit})
        return {"controls": results}

    def pi_print_mode_parity(self):
        args = ["--print", "--no-tools", "--no-session", "Reply with exactly PI_PRINT_OK."]
        native = self.native_print("pi", args, alias_index=2)
        require({"step": "pi-native-print-status"}, native.returncode == 0,
                f"native Pi print exited {native.returncode}: {native.stderr[-1000:]}")
        require({"step": "pi-native-print-output"}, native.stdout.strip() == "PI_PRINT_OK",
                f"native Pi print did not return its fixed response: {native.stdout[-1000:]}")
        before = self.intent_paths()
        pane, receipt, log, exit_file = self.launch("pi", args, alias_index=2, offline=False, claim_required=False)
        wrapped_status = self.wait_exit(log, exit_file, receipt, timeout=60)
        output = log.read_text(encoding="utf-8")
        require({"step": "pi-wrapped-print-status"}, wrapped_status == 0,
                f"wrapped Pi print exited {wrapped_status}: {output[-1000:]}")
        require({"step": "pi-wrapped-print-output"}, output.strip() == "PI_PRINT_OK",
                f"wrapped Pi print did not return its fixed response: {output[-1000:]}")
        state = self.state(pane)
        require({"step": "pi-print-runtime-bypass"}, (state is None or not state.get("name")) and
                self.intent_paths() == before,
                "Pi print mode unexpectedly claimed a runtime alias")
        return {"native_status": native.returncode, "wrapped_status": wrapped_status,
                "runtime_bypass": True, "native_output": native.stdout[-1000:], "wrapped_output": output[-1000:]}

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
            raise ProbeError(f"{error}; driver={self.driver_details(receipt)}; receipt={expected}; "
                             f"state={self.state(pane)}; pane={self.pane_output(pane)[-4000:]}") from error
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
                loaders.extend(["--extension", self.pi_loaders[0]])
            loaders.extend(["--extension", self.pi_loaders[1]])
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
                return {"status": self.send_normal_quit(agent, target_pane, target_receipt, target_log, target_exit)}
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
        if action != "normal":
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
        matched_baseline = None
        native_samples = []
        matched_reference = agent in {"pi", "opencode"}
        if matched_reference:
            baseline_observer = read_json(self.launchd.pid_file)
            self.launchd.close()
            require({"step": f"{agent}-matched-observer-stopped"},
                    process_start_identity(baseline_observer["pid"]) != baseline_observer["start_identity"],
                    "recovery is still running for the matched reference control")
            native_pane = self.client_pane()
            label = agent + "-reference-driver-" + uuid.uuid4().hex
            native_receipt = self.scratch / (label + ".receipt.json")
            self.start_foreground_driver(
                native_pane, native_receipt,
                [str(self.reference_launcher), agent, *self.interactive_args(agent, True)],
                self.foreground_exports(self.aliases[0], time.time_ns()), label,
            )
        else:
            native_pane, native_receipt = self.launch_native(agent, self.interactive_args(agent, False))
        native_ready = self.wait_client_ready(agent, native_pane, native_receipt, native=True)
        native = native_ready["native"]
        if matched_reference:
            native_before = wait_until(
                lambda: state if (state := self.state(native_pane)) and
                state.get("name") == self.aliases[0] and
                state.get("terminal_id") == native_pane["terminal_id"] and
                (agent != "pi" or ((state.get("agent_session") or {}).get("source") == "herdr:pi" and
                 state.get("agent_status") in {"idle", "working", "done", "blocked"})) else None,
                15, f"matched reference {agent} identity",
            )

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
            # Match the direct-native baseline: time zero is the observed stop,
            # not the earlier key submission.
            stopped_at = time.monotonic_ns()
            if while_stopped:
                while_stopped(stopped_at)
                self.wait_process_stopped(client["pid"])
            self.resume_shell_job(pane, driver_pid)
            try:
                self.wait_process_live(driver_pid, driver_start)
                live = self.wait_process_live(client["pid"], client["start_identity"])
            except ProbeError as error:
                raise ProbeError(
                    f"{error}; client={client}; driver={self.driver_details(target_receipt)}; "
                    f"client_state={self.process_state(client['pid'])}; pane={self.pane_output(pane)[-4000:]}"
                ) from error
            require({"step": f"{agent}-resumed-group"}, os.getpgid(client["pid"]) == group,
                    "resume changed the native process group")
            return {"mechanism": mechanism, "stopped_at_monotonic_ns": stopped_at,
                    "stopped_state": stopped, "resumed_state": live,
                    "process_group": os.getpgid(client["pid"])}

        def sample_native(stopped_at):
            for _ in range(15):
                require({"step": f"{agent}-matched-stopped-live"},
                        process_start_identity(native["pid"]) == native["start_identity"] and
                        "T" in (self.process_state(native["pid"]) or ""),
                        f"matched reference {agent} left its stopped live state")
                native_samples.append({"elapsed_monotonic_ns": time.monotonic_ns() - stopped_at,
                                       "agent": self.state(native_pane)})
                time.sleep(0.1)

        native_transition = suspend_and_resume(native_pane, native, native_receipt,
                                               while_stopped=sample_native if matched_reference else None)
        self.wait_client_ready(agent, native_pane, native_receipt, native=True)
        if matched_reference:
            native_after = self.state(native_pane)
            native_immediate = native_after
            native_redetection_started = time.monotonic_ns()
            if agent == "opencode":
                native_after = wait_until(lambda: self.state(native_pane), 20, "reference OpenCode redetection after fg")
            native_redetection_ns = time.monotonic_ns() - native_redetection_started
            self.wait_process_live(native["pid"], native["start_identity"])
            matched_baseline = {
                "before": native_before, "native": native,
                "samples_while_stopped": native_samples, "after_resume": native_after,
                "immediate_after_resume": native_immediate,
                "redetection_wait_ns": native_redetection_ns,
                "terminal": self.stable_terminal(native_pane), "transition": native_transition,
                "observer_confirmed_stopped": baseline_observer,
                "baseline_kind": "reference_without_recovery_with_status_driver",
                "reference_commit": REFERENCE, "status_driver_used": True,
            }
        native_status = self.send_normal_quit(agent, native_pane, native_receipt, None, None)
        if matched_reference:
            self.restart_observer()

        pane, receipt, log, exit_file = self.launch(
            agent, self.interactive_args(agent, True), interactive=True, alias_index=alias_index, hold_group=True,
        )
        live_window_start = time.monotonic_ns()
        expected = read_json(receipt)
        wrapped_ready = self.wait_client_ready(agent, pane, receipt)
        wrapped = wrapped_ready["native"]
        try:
            if agent == "pi":
                wait_until(lambda: read_json(expected["intent"])["phase"] == "retired", 15,
                           "Pi lifecycle takeover before suspension")
            pre_suspend = self.state(pane)
            require({"step": f"{agent}-wrapped-pre-suspend-alias"}, pre_suspend is not None and
                    pre_suspend.get("name") == expected["alias"] and
                    pre_suspend.get("terminal_id") == pane["terminal_id"] and
                    (agent != "pi" or (pre_suspend.get("agent_session") or {}).get("source") == "herdr:pi"),
                    f"wrapped {agent} did not publish its expected pre-Ctrl-Z identity: {pre_suspend}")
            observer_pass = None
            retained = None
            release_attempts = None
            retained_samples = []
            def observe_stopped_client(stopped_at):
                nonlocal observer_pass, retained, release_attempts
                def sample_stopped(step):
                    require({"step": step}, process_start_identity(wrapped["pid"]) == wrapped["start_identity"] and
                            "T" in (self.process_state(wrapped["pid"]) or ""),
                            "wrapped client left the stopped/live control")
                    retained_samples.append({"elapsed_monotonic_ns": time.monotonic_ns() - stopped_at,
                                             "agent": self.state(pane)})

                if agent == "pi":
                    retired = read_json(expected["intent"])
                    require({"step": "pi-stopped-takeover"}, retired["phase"] == "retired",
                            "interactive Pi did not retire launcher authority before suspension")
                    observer_pass = {"retired_before_stop": retired}
                    observer = read_json(self.launchd.pid_file)
                    require({"step": "pi-retired-observer-live"},
                            process_start_identity(observer["pid"]) == observer["start_identity"],
                            "recovery observer stopped before the retired-intent control")
                    observer_pass["observer"] = observer
                    for _ in range(15):
                        sample_stopped("pi-stopped-incarnation")
                        time.sleep(0.1)
                    retained = retained_samples[-1]["agent"]
                    release_attempts = []
                    return
                before_observer = time.monotonic_ns()
                observer_pid = read_json(self.launchd.pid_file)["pid"]
                trace_dir = pathlib.Path(probe_trace_dir(read_json(expected["intent"])))
                witness = trace_dir / f"{observer_pid}.observe_complete.json"
                # Keep the first stopped window on the baseline cadence. The
                # observer is then evidence about that same already-sampled run.
                for _ in range(15):
                    sample_stopped(f"{agent}-stopped-live")
                    time.sleep(0.1)
                def observed_or_unsafe():
                    # A bad early release can settle the intent and stop future
                    # observation. Surface that operation rather than time out
                    # waiting for a pass that the regression made impossible.
                    attempts = [read_json(path) for path in trace_dir.glob("*.release_attempt.*.json")]
                    if attempts:
                        return {"unsafe_release_attempts": attempts}
                    if witness.exists():
                        record = read_json(witness)
                        if record.get("started_monotonic_ns", 0) > before_observer:
                            return record
                    return None
                observer_pass = wait_until(observed_or_unsafe, 10, f"observer pass while {agent} was stopped")
                release_attempts = [read_json(path) for path in trace_dir.glob("*.release_attempt.*.json")]
                require({"step": f"{agent}-stopped-no-release"}, not release_attempts,
                        f"observer attempted cleanup while live {agent} was stopped: {release_attempts}")
                retained = self.state(pane)
            wrapped_transition = suspend_and_resume(pane, wrapped, receipt,
                                                      while_stopped=observe_stopped_client)
            require({"step": f"{agent}-stop-mechanism-parity"},
                    native_transition["mechanism"] == wrapped_transition["mechanism"],
                    f"native/wrapped Ctrl-Z mechanism differs: {native_transition} != {wrapped_transition}")
            self.wait_client_ready(agent, pane, receipt)
            after_resume = self.state(pane)
            immediate_after_resume = after_resume
            redetection_started = time.monotonic_ns()
            if agent == "opencode":
                after_resume = wait_until(lambda: self.state(pane), 20, "wrapped OpenCode redetection after fg")
            redetection_ns = time.monotonic_ns() - redetection_started
            self.wait_process_live(wrapped["pid"], wrapped["start_identity"])
            trace_dir = pathlib.Path(probe_trace_dir(read_json(expected["intent"])))
            release_attempts = [read_json(path) for path in trace_dir.glob("*.release_attempt.*.json")]
            require({"step": f"{agent}-resumed-no-release"}, not release_attempts,
                    f"recovery attempted cleanup before this live client quit: {release_attempts}")
            live_mutations = [event for path in trace_dir.glob("*.mutation_attempt.*.json")
                              if (event := read_json(path))["monotonic_ns"] >= live_window_start]
            require({"step": f"{agent}-no-live-mutation"}, not live_mutations,
                    f"recovery mutated the live client's state: {live_mutations}")
            wrapped_status = self.send_normal_quit(agent, pane, receipt, log, exit_file)
            intent = self.wait_completed(receipt, pane)
        finally:
            pathlib.Path(str(receipt) + ".release").touch()
        alias_retained = all(sample["agent"] is not None and sample["agent"].get("name") == expected["alias"]
                             for sample in retained_samples) and retained is not None and \
            retained.get("name") == expected["alias"] and after_resume is not None and \
            after_resume.get("name") == expected["alias"]
        return {"native": native, "native_transition": native_transition, "native_status": native_status,
                "matched_baseline": matched_baseline,
                "wrapped": wrapped, "wrapped_transition": wrapped_transition, "wrapped_status": wrapped_status,
                "observer_pass": observer_pass, "pre_suspend": pre_suspend, "retained": retained,
                "retained_samples": retained_samples, "after_resume": after_resume,
                "immediate_after_resume": immediate_after_resume,
                "redetection_wait_ns": redetection_ns,
                "alias_retained": alias_retained,
                "release_attempts_before_quit": release_attempts,
                "live_window_start_monotonic_ns": live_window_start, "mutations_while_live": live_mutations,
                "intent": intent}

    def restart_observer(self):
        """Give each direct-native control its own positively stopped observer."""
        self.launchd = self.recovery_job
        self.launchd.start()

    def direct_native_suspension(self, agent, attempt_repair=False, reference_launch=False):
        """Observe suspension with recovery stopped; record the exact baseline route."""
        observer = read_json(self.launchd.pid_file)
        self.launchd.close()
        require({"step": "diagnostic-observer"}, process_start_identity(observer["pid"]) != observer["start_identity"],
                "recovery observer is still running")
        pane = self.client_pane()
        pid_file = self.scratch / f"direct-{agent}.pid"
        script = self.scratch / f"direct-{agent}.sh"
        exports = self.foreground_exports(self.aliases[0] if reference_launch else "native-suspension", time.time_ns())
        lines = ["#!/bin/sh", "set -eu"]
        lines.extend(f"export {key}={shlex.quote(value)}" for key, value in exports.items())
        command = ([str(self.reference_launcher), agent] if reference_launch else [native_executable(agent)])
        command.extend(self.interactive_args(agent, reference_launch))
        lines.extend([f"printf '%s' \"$$\" > {shlex.quote(str(pid_file))}", "exec " + shlex.join(command)])
        script.write_text("\n".join(lines) + "\n", encoding="utf-8")
        script.chmod(0o700)
        self.owner.run("pane", "run", pane["pane_id"], str(script))
        wait_until(pid_file.exists, 8, "direct native PID")
        pid = int(pid_file.read_text())
        native = wait_until(lambda: self.native_process(pid, agent), 20, f"direct native {agent} exec")
        self.foreground_groups[pid] = {"start_identity": native["start_identity"], "process_group": os.getpgid(pid)}
        if agent == "claude":
            def prompt_ready():
                if not self.native_input_ready(pid):
                    return None
                result = self.owner.run("agent", "explain", pane["pane_id"], "--json", expected=None)
                if result.returncode:
                    if "agent_not_found" in result.stderr:
                        return False
                    raise ProbeError(f"native readiness lookup failed: {result.stderr}")
                return (json.loads(result.stdout).get("matched_rule") or {}).get("id") == "live_prompt_box"
            readiness = wait_until(prompt_ready, 20, "direct native Claude input prompt")
        elif agent == "opencode":
            def prompt_ready():
                if not self.native_input_ready(pid):
                    return None
                screen = self.pane_visible(pane)
                return "OpenCode input box" if "Ask anything" in screen and "ctrl+p commands" in screen else None
            readiness = wait_until(prompt_ready, 20, "direct native OpenCode input box")
        else:
            def prompt_ready():
                if not self.native_input_ready(pid):
                    return None
                borders = [line for line in self.pane_visible(pane).splitlines()
                           if len(line.strip()) >= 20 and set(line.strip()) == {"─"}]
                return "Pi input box" if len(borders) >= 2 else None
            readiness = wait_until(prompt_ready, 20, "direct native Pi input box")
        alias = self.aliases[0]
        if agent == "pi":
            wait_until(lambda: state if (state := self.state(pane)) and
                       (state.get("agent_session") or {}).get("source") == "herdr:pi" and
                       state.get("agent_status") in {"idle", "done", "working", "blocked"} else None,
                       15, "baseline Pi lifecycle takeover before suspension")
        if not reference_launch:
            self.owner.run("agent", "rename", pane["pane_id"], alias)
        before = self.state(pane)
        require({"step": "native-alias-control"}, before is not None and before.get("name") == alias,
                "native alias was not established")
        self.owner.run("pane", "send-keys", pane["pane_id"], "ctrl+z")
        self.wait_process_stopped(pid)
        stopped_at = time.monotonic_ns()
        samples = []
        for _ in range(15):
            samples.append({"elapsed_monotonic_ns": time.monotonic_ns() - stopped_at,
                            "agent": self.state(pane), "start_identity": process_start_identity(pid),
                            "process_state": self.process_state(pid)})
            time.sleep(0.1)
        connection = {"connection": {"socket_path": self.owner.socket_path,
                      "server_identity": capture_server_identity(self.owner.socket_path)}}
        report = after_report = renamed = after_rename = None
        if attempt_repair:
            report = bound_request(connection, "pane.report_agent", {
                "pane_id": pane["pane_id"], "source": SOURCE, "agent": agent, "state": "unknown", "seq": time.time_ns(),
            })
            after_report = self.state(pane)
            renamed = bound_request(connection, "agent.rename", {"target": pane["pane_id"], "name": alias})
            after_rename = self.state(pane)
        self.resume_shell_job(pane, pid)
        self.wait_process_live(pid, native["start_identity"])
        resumed_readiness = wait_until(prompt_ready, 20, f"direct native {agent} prompt after resume")
        resumed = self.state(pane)
        terminal = self.stable_terminal(pane)
        if agent == "pi":
            self.owner.run("pane", "send-keys", pane["pane_id"], "ctrl+d")
        else:
            self.owner.run("pane", "send-text", pane["pane_id"], "/exit")
            self.owner.run("pane", "send-keys", pane["pane_id"], "enter")
        wait_until(lambda: process_start_identity(pid) != native["start_identity"], 15,
                   f"direct native {agent} normal quit")
        evidence = {"before": before, "native": native, "observer_confirmed_stopped": observer,
                     "stopped_at_monotonic_ns": stopped_at, "samples_while_stopped": samples,
                     "report_attempt": report, "after_report": after_report,
                     "rename_attempt": renamed, "after_rename": after_rename, "after_resume": resumed,
                     "readiness": readiness, "resumed_readiness": resumed_readiness, "terminal": terminal,
                     "direct_native_launch": not reference_launch, "reference_launcher_used": reference_launch,
                     "baseline_kind": "reference_without_recovery" if reference_launch else "direct_native",
                     "reference_commit": REFERENCE if reference_launch else None,
                     "status_driver_used": False, "recovery_observer_running": False,
                     "normal_quit_observed": True, "repair_attempted": attempt_repair}
        retained = all(sample["agent"] and sample["agent"].get("name") == alias for sample in samples)
        retained = bool(retained and resumed and resumed.get("name") == alias)
        require({"step": "native-suspension-control"},
                all(sample["start_identity"] == native["start_identity"] and "T" in sample["process_state"] for sample in samples),
                "native process did not remain alive and stopped")
        evidence["alias_retained"] = retained
        evidence["raw_alias_retention_assertion"] = "PASS" if retained else "FAIL"
        return evidence

    def native_suspension_asserts_retention(self, agent):
        evidence = self.direct_native_suspension(agent, attempt_repair=True)
        if not evidence["alias_retained"]:
            error = ProbeError(f"Herdr lost the stopped native {agent} alias with recovery disabled")
            error.evidence = evidence
            raise error
        return evidence

    def qualify_suspension_exception(self, agent, alias_index):
        """Keep the failed native assertion raw, then classify only attributed loss."""
        # Pi's reference launcher assigns the name before session attachment.
        # A bare Pi renamed after startup is a different ownership baseline.
        native = self.direct_native_suspension(agent, reference_launch=agent == "pi")
        self.restart_observer()
        try:
            wrapped = self.stop_resume(agent, alias_index)
        except ProbeError as error:
            error.evidence = {"native_baseline": native, **getattr(error, "evidence", {})}
            raise
        comparison = wrapped.get("matched_baseline") or native
        def require_comparison(step, predicate, message):
            try:
                require(step, predicate, message)
            except ProbeError as error:
                error.evidence = {"baseline": native, "comparison_baseline": comparison, "wrapped": wrapped}
                raise
        def identity_shape(samples, alias, terminal_id):
            shape = []
            for sample in samples:
                record = sample["agent"]
                require_comparison({"step": f"{agent}-suspension-record-identity"}, record is None or (
                    record.get("name") in (None, alias) and
                    record.get("terminal_id") == terminal_id and
                    record.get("agent") in (None, agent)),
                    f"suspension record belongs to another identity: {record}")
                state = {
                    "record_present": record is not None,
                    "alias_present": bool(record and record.get("name") == alias),
                    "terminal_matches": bool(record and record.get("terminal_id") == terminal_id),
                }
                if not shape or state != shape[-1]:
                    shape.append(state)
            return shape

        baseline_shape = identity_shape(comparison["samples_while_stopped"], self.aliases[0], comparison["terminal"]["terminal_id"])
        wrapped_shape = identity_shape(wrapped["retained_samples"], wrapped["pre_suspend"]["name"], wrapped["pre_suspend"]["terminal_id"])
        baseline_after_resume = identity_shape([{"agent": comparison["after_resume"]}],
                                              self.aliases[0], comparison["terminal"]["terminal_id"])[0]
        wrapped_after_resume = identity_shape([{"agent": wrapped["after_resume"]}],
                                             wrapped["pre_suspend"]["name"], wrapped["pre_suspend"]["terminal_id"])[0]
        require_comparison({"step": f"{agent}-suspension-loss-shape"}, wrapped["alias_retained"] or baseline_shape == wrapped_shape,
                 f"native/wrapped suspension identity loss shape differs: {baseline_shape} != {wrapped_shape}")
        # R4 forbids additional loss, not an improvement over the native control.
        # Herdr may rediscover an unnamed record after fg at different instants.
        require_comparison({"step": f"{agent}-suspension-after-resume-shape"},
                all(not present or wrapped_after_resume[field] for field, present in baseline_after_resume.items()),
                f"wrapped post-resume identity lost more than native: {baseline_after_resume} -> {wrapped_after_resume}")
        baseline_lost_alias = any(not state["alias_present"] for state in baseline_shape) or \
            not baseline_after_resume["alias_present"]
        if not baseline_lost_alias and not wrapped["alias_retained"]:
            error = ProbeError(
                f"comparison {agent} suspension retained its alias; wrapped loss cannot inherit an exception"
            )
            error.evidence = {"baseline": native, "wrapped": wrapped}
            raise error
        return {
            "classification": "PASS" if wrapped["alias_retained"] else "KNOWN_UPSTREAM_LIMITATION",
            "raw_baseline_alias_retention_assertion": native["raw_alias_retention_assertion"],
            "raw_comparison_alias_retention_assertion": "FAIL" if baseline_lost_alias else "PASS",
            "qualification_baseline_kind": comparison["baseline_kind"],
            "baseline": native,
            "baseline_kind": native["baseline_kind"],
            "comparison_baseline": comparison,
            "wrapped": wrapped,
            "wrapped_alias_retained": wrapped["alias_retained"],
            "baseline_loss_shape": baseline_shape,
            "wrapped_loss_shape": wrapped_shape,
            "baseline_after_resume_shape": baseline_after_resume,
            "wrapped_after_resume_shape": wrapped_after_resume,
            "latency_claim": "unresolved: independent runs retain elapsed evidence but supply no timing oracle",
            "recovery_evidence": "stop_resume checks resumed PID/start, release attempts, mutations, and observed normal quit statuses",
        }

    def intercom_identity(self, alias):
        """Read the real private broker's registration through its framed protocol."""
        path = self.scratch / "intercom/broker.sock"
        if not path.exists():
            return None
        require({"step": "private-broker-path"}, path.resolve().is_relative_to(self.scratch.resolve()),
                "broker socket escaped owned scratch")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(5)
            connection.connect(str(path))
            with connection.makefile("rb") as stream:
                def send(message):
                    payload = json.dumps(message).encode()
                    connection.sendall(struct.pack("!I", len(payload)) + payload)
                def receive():
                    header = stream.read(4)
                    require({"step": "broker-frame"}, len(header) == 4, "broker closed before response")
                    length = struct.unpack("!I", header)[0]
                    require({"step": "broker-frame-size"}, 0 < length <= 1024 * 1024, "invalid broker frame length")
                    payload = stream.read(length)
                    require({"step": "broker-frame-body"}, len(payload) == length, "incomplete broker response")
                    return json.loads(payload)
                now = int(time.time() * 1000)
                send({"type": "register", "protocol": "pi-intercom", "version": 3,
                      "sessionId": "proof-audit-" + uuid.uuid4().hex,
                      "session": {"cwd": str(ROOT), "model": "proof-audit", "pid": os.getpid(),
                                  "startedAt": now, "lastActivity": now,
                                  "name": "proof-audit-" + uuid.uuid4().hex[:8]}})
                registered = receive()
                require({"step": "broker-auditor"}, registered.get("type") == "registered",
                        f"private broker refused auditor: {registered}")
                try:
                    request_id = uuid.uuid4().hex
                    send({"type": "list", "requestId": request_id})
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        response = receive()
                        if response.get("requestId") == request_id:
                            break
                    else:
                        raise ProbeError("private broker did not answer its session-list request")
                    require({"step": "broker-list"}, response.get("type") == "sessions", f"broker list failed: {response}")
                    matches = [item for item in response["sessions"] if item.get("name") == alias]
                    if not matches:
                        return None
                    require({"step": "broker-alias"}, len(matches) == 1, "ambiguous successor Intercom identity")
                    require({"step": "broker-session-id"}, isinstance(matches[0].get("id"), str) and bool(matches[0]["id"]),
                            "successor broker registration has no session identity")
                    return {"id": matches[0]["id"], "name": matches[0]["name"]}
                finally:
                    try:
                        send({"type": "unregister"})
                    except OSError:
                        pass  # Closing this private connection also removes its auditor.

    def detected_successor_survives_old_release(self):
        pane = self.client_pane()
        require({"step": "fresh-successor-pane"}, self.state(pane) is None, "successor control did not start with an empty pane")
        old = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(90)"])
        try:
            start = process_start_identity(old.pid)
            require({"step": "old-launch-process"}, start is not None, "old launch process was not observed")
            sequence = time.time_ns()
            trace = self.scratch / ("old-release-trace-" + uuid.uuid4().hex)
            trace.mkdir()
            old_path = durable_intent(self.owner, str(self.scratch / "manual-intents"), pane,
                                      sequence, old, start, trace_dir=str(trace))
            report(self.owner, pane["pane_id"], OLD_SOURCE, "unknown", sequence)
            require({"step": "old-claim"}, self.state(pane)["agent_status"] == "unknown", "old claim did not publish")
            report(self.owner, pane["pane_id"], "foreign-takeover", "working", sequence + 10)
            require({"step": "foreign-takeover"}, self.state(pane)["agent_status"] == "working", "foreign takeover did not publish")
            release(self.owner, pane["pane_id"], "foreign-takeover", sequence + 11)
            require({"step": "foreign-release"}, self.state(pane) is None, "foreign release left an authority record")
            old.terminate()
            old.wait(timeout=5)
            _, receipt, log, exit_file = self.launch("claude", ["--no-chrome"], interactive=True, alias_index=1, pane=pane)
            expected = read_json(receipt)
            readiness = self.wait_claude_ready(pane, receipt)
            self.owner.run("pane", "send-text", pane["pane_id"], "Reply with OK only.")
            self.owner.run("pane", "send-keys", pane["pane_id"], "enter")
            def handed_off():
                state = self.state(pane)
                return state if state and state.get("name") == expected["alias"] and state.get("agent_status") in {"idle", "working", "done", "blocked"} else None
            before = wait_until(handed_off, 20, "real successor lifecycle handoff")
            session = before.get("agent_session") or {}
            require({"step": "native-successor-session"}, session.get("source") == "herdr:claude" and bool(session.get("value")),
                    f"native successor did not publish a session identity: {before}")
            wait_until(lambda: read_json(expected["intent"])["phase"] == "retired", 10, "successor obligation retirement")
            identity = wait_until(lambda: self.intercom_identity(expected["alias"]), 20, "real successor Intercom registration")
            # The old acquisition was never acknowledged locally. This forces
            # its delayed cleanup to reach release rather than retire on status.
            observe_one(old_path)
            attempts = list(trace.glob("*.release_result.json"))
            require({"step": "old-release-witness"}, bool(attempts), "old observer never attempted release")
            response = read_json(attempts[0])["response"]
            require({"step": "old-release-status"}, "error" not in response and response.get("result", {}).get("type") == "ok",
                    f"old release was rejected: {response}")
            old_intent = read_json(old_path)
            repeated = bound_request(old_intent, "pane.release_agent", {"pane_id": pane["pane_id"],
                "source": OLD_SOURCE, "agent": "claude", "seq": old_intent["claim"]["release_seq"]})
            require({"step": "repeated-release-status"}, "error" not in repeated and repeated.get("result", {}).get("type") == "ok",
                    f"repeated old release was rejected: {repeated}")
            after = self.state(pane)
            require({"step": "detected-successor-retained"}, after is not None and
                    all(after.get(key) == before.get(key) for key in ("name", "terminal_id", "agent_session")) and
                    after.get("agent_status") in {"idle", "working", "done", "blocked"},
                    f"old cleanup changed the real successor: {after}")
            broker_after = self.intercom_identity(expected["alias"])
            require({"step": "successor-intercom"}, broker_after == identity, "old cleanup changed the real Intercom identity")
            native = readiness["native"]
            require({"step": "successor-live"}, process_start_identity(native["pid"]) == native["start_identity"], "old cleanup ended the successor")
            self.wait_claude_ready(pane, receipt)
            status = self.send_normal_quit("claude", pane, receipt, log, exit_file)
            return {"before": before, "after": after, "broker_before": identity, "broker_after": broker_after,
                    "release_response": response, "repeated_response": repeated, "native": native, "quit_status": status}
        finally:
            if old.poll() is None:
                old.kill()
                old.wait(timeout=5)

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
        return self.interactive_control("pi", "term", 5)

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
        pane, receipt, log, exit_file = self.launch("claude", ["--no-chrome"], interactive=True, alias_index=7, trace=True)
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
            trace_dir = pathlib.Path(probe_trace_dir(read_json(expected["intent"])))
            observer = read_json(self.launchd.pid_file)
            mutations = [read_json(path) for path in trace_dir.glob("*.mutation_attempt.*.json")]
            require({"step": "handoff-hook-reserved-release"}, any(
                event["pid"] != observer["pid"] and event["method"] == "pane.release_agent" and
                event["params"].get("source") == retired["claim"]["source"] and
                event["params"].get("seq") == retired["claim"]["handoff_seq"]
                for event in mutations
            ), f"first-prompt hook has no source-scoped reserved release trace: {mutations}")
            require({"step": "handoff-client"}, process_start_identity(readiness["native"]["pid"]) ==
                    readiness["native"]["start_identity"], "handoff ended the native client")
            return {"receipt": expected, "handoff": handoff, "driver": self.driver_details(receipt),
                    "retired": retired, "readiness": readiness, "observer": observer, "mutations": mutations}
        finally:
            if process_start_identity(expected["pid"]) == expected["start_identity"]:
                os.kill(expected["pid"], signal.SIGTERM)
            self.wait_exit(log, exit_file, receipt, timeout=15)

    def wait_claude_session(self, pane):
        return wait_until(lambda: state if (state := self.state(pane)) and
                          (state.get("agent_session") or {}).get("source") == "herdr:claude" and
                          state["agent_session"].get("value") else None,
                          15, "outer Claude session identity before handoff control")

    def claude_non_descendant_handoff_is_refused(self):
        pane, receipt, log, exit_file = self.launch("claude", ["--no-chrome"], interactive=True,
                                                    alias_index=16, trace=True)
        expected = read_json(receipt)
        readiness = self.wait_claude_ready(pane, receipt)
        trace_dir = pathlib.Path(probe_trace_dir(read_json(expected["intent"])))
        before = self.wait_claude_session(pane)
        attempts_before = list(trace_dir.glob("*.mutation_attempt.*.json"))
        result = subprocess.run([sys.executable, str(ROOT / "tests/helpers/intercom_claim_recovery_prototype.py"), "--handoff"],
                                cwd=ROOT, env=self.owner.env | {"HERDR_AGENT_INTERCOM_RECOVERY_INTENT": expected["intent"]},
                                text=True, capture_output=True, check=False, timeout=15)
        require({"step": "handoff-non-descendant-refusal"}, result.returncode != 0 and
                "handoff caller is not a descendant" in result.stderr,
                f"non-descendant handoff did not fail closed: {result.returncode}; {result.stderr[-2000:]}")
        after = self.state(pane)
        attempts_after = list(trace_dir.glob("*.mutation_attempt.*.json"))
        require({"step": "handoff-non-descendant-no-mutation"}, attempts_after == attempts_before,
                f"non-descendant handoff attempted a mutation: {attempts_after}")
        require({"step": "handoff-non-descendant-identity"}, after == before,
                f"non-descendant handoff changed the real record: {before} != {after}")
        status = self.send_normal_quit("claude", pane, receipt, log, exit_file)
        return {"native": readiness["native"], "status": status, "before": before, "after": after,
                "stderr": result.stderr[-1000:], "mutation_attempts": len(attempts_after)}

    def claude_handoff_retries_after_socket_restoration(self):
        hook = self.scratch / "handoff-retry-hook.py"
        hook_receipt = self.scratch / "handoff-retry-hook.json"
        release = self.scratch / "handoff-retry-release"
        hidden = self.scratch / "handoff-retry-hidden.sock"
        hook.write_text(
            "import os, pathlib, sys, time\n"
            f"sys.path.insert(0, {str(ROOT / 'tests/helpers')!r})\n"
            "from intercom_claim_recovery_prototype import atomic_write, request_handoff\n"
            "intent = os.environ['HERDR_AGENT_INTERCOM_RECOVERY_INTENT']\n"
            "socket = pathlib.Path(os.environ['HERDR_SOCKET_PATH'])\n"
            f"hidden = pathlib.Path({str(hidden)!r})\n"
            f"receipt = pathlib.Path({str(hook_receipt)!r})\n"
            f"release = pathlib.Path({str(release)!r})\n"
            "os.replace(socket, hidden)\n"
            "try:\n"
            "    request_handoff(intent)\n"
            "    atomic_write(str(receipt), {'pid': os.getpid(), 'intent': intent, 'socket_hidden': str(hidden)})\n"
            "    deadline = time.monotonic() + 15\n"
            "    while not release.exists() and time.monotonic() < deadline: time.sleep(0.05)\n"
            "    if not release.exists(): raise RuntimeError('owned retry release barrier timed out')\n"
            "finally:\n"
            "    if hidden.exists(): os.replace(hidden, socket)\n",
            encoding="utf-8",
        )
        hook.chmod(0o700)
        settings = self.claude_settings_with_hook("handoff-retry", shlex.join([sys.executable, str(hook)]))
        pane, receipt, log, exit_file = self.launch("claude", ["--no-chrome"], interactive=True, alias_index=17,
                                                    claude_settings=settings, trace=True)
        expected = read_json(receipt)
        readiness = self.wait_claude_ready(pane, receipt)
        before = self.state(pane)
        try:
            self.owner.run("pane", "send-text", pane["pane_id"], "Reply with OK only.")
            self.owner.run("pane", "send-keys", pane["pane_id"], "enter")
            hook_state = wait_until(lambda: read_json(hook_receipt) if hook_receipt.exists() else None, 10,
                                    "first-prompt socket-failure hook receipt")
            pending = wait_until(lambda: value if (value := read_json(expected["intent"])).get("handoff_requested_at_ns")
                                 and value.get("handoff_client") == {key: readiness["native"][key]
                                                                     for key in ("pid", "start_identity")} else None, 10,
                                 "durable authorized handoff pending record")
            require({"step": "handoff-retry-socket-hidden"}, hidden.exists() and not pathlib.Path(self.owner.socket_path).exists(),
                    "retry hook did not make only its owned socket temporarily unavailable")
            release.touch()
            wait_until(lambda: pathlib.Path(self.owner.socket_path).exists() and not hidden.exists(), 10,
                       "owned socket restoration")
            def handed_off():
                state = self.state(pane)
                return state if state and state.get("name") == expected["alias"] and \
                    state.get("agent_status") in {"idle", "working", "done", "blocked"} else None
            after = wait_until(handed_off, 20, "observer retry handoff without second prompt")
            retired = wait_until(lambda: value if (value := read_json(expected["intent"])).get("phase") == "retired" else None,
                                 10, "concrete handoff retirement")
            trace_dir = pathlib.Path(probe_trace_dir(read_json(expected["intent"])))
            observer = read_json(self.launchd.pid_file)
            mutations = [read_json(path) for path in trace_dir.glob("*.mutation_attempt.*.json")]
            require({"step": "handoff-retry-observer-mutation"}, any(event["pid"] == observer["pid"] and
                    event["method"] == "pane.release_agent" for event in mutations),
                    f"handoff retry has no observer-owned release trace: {mutations}")
            require({"step": "handoff-retry-same-native"}, process_start_identity(readiness["native"]["pid"]) ==
                    readiness["native"]["start_identity"], "retry changed the native Claude identity")
            return {"before": before, "after": after, "pending": pending, "retired": retired,
                    "hook": hook_state, "observer": observer, "mutations": mutations, "native": readiness["native"]}
        finally:
            release.touch()
            if hidden.exists() and not pathlib.Path(self.owner.socket_path).exists():
                os.replace(hidden, self.owner.socket_path)
            if process_start_identity(expected["pid"]) == expected["start_identity"]:
                os.kill(expected["pid"], signal.SIGTERM)
            self.wait_exit(log, exit_file, receipt, timeout=15)

    def claude_nested_native_handoff_is_refused(self):
        inner_hook = self.scratch / "nested-handoff-inner.py"
        outer_hook = self.scratch / "nested-handoff-outer.py"
        result_path = self.scratch / "nested-handoff-result.json"
        inner_hook.write_text(
            "import os, subprocess, sys\n"
            f"sys.path.insert(0, {str(ROOT / 'tests/helpers')!r})\n"
            "from intercom_claim_recovery_prototype import atomic_write\n"
            f"result = subprocess.run([sys.executable, {str(ROOT / 'tests/helpers/intercom_claim_recovery_prototype.py')!r}, '--handoff'], text=True, capture_output=True, check=False)\n"
            f"atomic_write({str(result_path)!r}, {{'pid': os.getpid(), 'returncode': result.returncode, 'stderr': result.stderr}})\n",
            encoding="utf-8",
        )
        inner_hook.chmod(0o700)
        inner_settings = self.claude_settings_with_hook("nested-inner", shlex.join([sys.executable, str(inner_hook)]))
        outer_hook.write_text(
            "import os, subprocess\n"
            "env = os.environ.copy()\n"
            "env.pop('CLAUDECODE', None)\n"
            f"subprocess.run([{native_executable('claude')!r}, '--settings', {str(inner_settings)!r}, '-p', 'Reply with OK only.'], env=env, check=False)\n",
            encoding="utf-8",
        )
        outer_hook.chmod(0o700)
        outer_settings = self.claude_settings_with_hook("nested-outer", shlex.join([sys.executable, str(outer_hook)]))
        pane, receipt, log, exit_file = self.launch("claude", ["--no-chrome"], interactive=True, alias_index=18,
                                                    claude_settings=outer_settings, trace=True)
        expected = read_json(receipt)
        readiness = self.wait_claude_ready(pane, receipt)
        trace_dir = pathlib.Path(probe_trace_dir(read_json(expected["intent"])))
        before = self.wait_claude_session(pane)
        attempts_before = list(trace_dir.glob("*.mutation_attempt.*.json"))
        try:
            self.owner.run("pane", "send-text", pane["pane_id"], "Reply with OK only.")
            self.owner.run("pane", "send-keys", pane["pane_id"], "enter")
            nested = wait_until(lambda: read_json(result_path) if result_path.exists() else None, 30,
                                "nested native Claude handoff refusal")
            require({"step": "handoff-nested-native-refusal"}, nested["returncode"] != 0 and
                    "nested native client cannot hand off another launch" in nested["stderr"],
                    f"nested native Claude did not reach the image guard: {nested}")
            after = self.state(pane)
            attempts_after = list(trace_dir.glob("*.mutation_attempt.*.json"))
            require({"step": "handoff-nested-native-no-mutation"}, attempts_after == attempts_before,
                    f"nested native handoff attempted a mutation: {attempts_after}")
            identity_keys = ("name", "terminal_id", "agent", "agent_status", "agent_session", "state_change_seq")
            require({"step": "handoff-nested-native-identity"},
                    {key: after.get(key) for key in identity_keys} == {key: before.get(key) for key in identity_keys},
                    f"nested native handoff changed the outer record: {before} != {after}")
            return {"outer_native": readiness["native"], "nested": nested, "before": before, "after": after,
                    "mutation_attempts": len(attempts_after)}
        finally:
            if process_start_identity(expected["pid"]) == expected["start_identity"]:
                os.kill(expected["pid"], signal.SIGTERM)
            self.wait_exit(log, exit_file, receipt, timeout=20)

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
            witness = pathlib.Path(probe_trace_dir(bound)) / f"{observer_pid}.observe_complete.json"
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


def installed_versions():
    herdr = subprocess.run(["herdr", "--version"], text=True, capture_output=True, check=False, timeout=20)
    require({"step": "herdr-version"}, herdr.returncode == 0 and bool(herdr.stdout.strip()),
            f"could not establish Herdr version: {herdr.stderr}")
    versions = {"herdr": herdr.stdout.strip()}
    for agent in CLIENTS:
        result = subprocess.run([native_executable(agent), "--version"], text=True, capture_output=True,
                                check=False, timeout=20)
        require({"step": f"{agent}-version"}, result.returncode == 0 and bool(result.stdout.strip()),
                f"could not establish {agent} version: {result.stderr}")
        versions[agent] = {"status": result.returncode, "stdout": result.stdout.strip(),
                           "stderr": result.stderr.strip()}
    return versions


def write_artifact(probe, prefix, versions):
    artifact_root = pathlib.Path(os.environ.get(EVIDENCE_DIR, pathlib.Path.home() / ".claude/artifacts/377/proof"))
    artifact_root.mkdir(parents=True, exist_ok=True)
    counts = {status: sum(result["status"] == status for result in probe.results)
              for status in ("PASS", "KNOWN_UPSTREAM_LIMITATION", "FAIL", "UNVERIFIED", "SKIP")}
    accepted = {"PASS", "KNOWN_UPSTREAM_LIMITATION"}
    gate = bool(probe.results) and all(result["status"] in accepted for result in probe.results)
    artifact = artifact_root / f"{prefix}-{uuid.uuid4().hex}.json"
    atomic_write(artifact, {"reference": REFERENCE, "versions": versions, "results": probe.results,
                            "counts": counts, "gate": {"status": "PASS" if gate else "FAIL",
                            "accepted_row_statuses": sorted(accepted),
                            "reason": "only PASS and independently qualified known-limit rows satisfy the client gate"}})
    print(f"EVIDENCE: {artifact}")
    return gate


def run_probe(suspension_only=False):
    if os.environ.get(OPT_IN) != "1":
        print(f"REFUSED: set {OPT_IN}=1 to run installed clients in isolated Herdr panes.")
        return 2
    if os.environ.get("HERDR_ENV") != "1":
        print("REFUSED: this probe must be launched from a Herdr-managed pane.")
        return 2
    probe = ClientProbe()
    def run_cases():
        if suspension_only:
            probe.case("direct native Claude suspension retains alias with recovery disabled",
                       lambda: probe.native_suspension_asserts_retention("claude"))
            probe.restart_observer()
            probe.case("direct native OpenCode suspension retains alias with recovery disabled",
                       lambda: probe.native_suspension_asserts_retention("opencode"))
            probe.restart_observer()
            probe.case("direct native Pi suspension retains alias with recovery disabled",
                       lambda: probe.native_suspension_asserts_retention("pi"))
            return
        probe.case("OpenCode early exit releases its unknown claim without successor", probe.opencode_early_exit)
        probe.case("OpenCode TUI exec exits before its first lifecycle report", probe.opencode_no_prompt_quit)
        probe.case("Pi invalid noninteractive launch releases false-positive claim and native control works", probe.pi_non_tty)
        probe.case("Pi reference-launcher utility classification bypasses claim and durable intent",
                   probe.pi_known_utility_bypasses_claim)
        probe.case("Pi valid non-TTY print mode preserves real output, exact status, and cleanup", probe.pi_print_mode_parity)
        probe.case("interactive Pi retains canonical alias and real Herdr takeover", probe.pi_interactive)
        probe.case("native and wrapped Pi preserve normal interactive quit status", probe.pi_normal_quit_parity)
        probe.case("native and wrapped Pi preserve interactive Ctrl-C behavior and status", probe.pi_ctrl_c_parity)
        probe.case("native and wrapped OpenCode preserve foreground PTY Ctrl-C status", probe.opencode_ctrl_c_parity)
        probe.case("native and wrapped OpenCode preserve foreground PTY TERM status", probe.opencode_term_parity)
        probe.case("native and wrapped OpenCode preserve normal TUI quit status", probe.opencode_normal_quit_parity)
        probe.case("native and wrapped Pi preserve foreground PTY TERM status", probe.pi_term_parity)
        probe.case("initial admission failures preserve native startup and ownership",
                   probe.opencode_initial_admission_r10_fallback)
        probe.case("lost acquisition response preserves native startup, pending cleanup, and inherited identity",
                   probe.partial_admission_preserves_native_startup)
        probe.case("runtime owner replaces stale readiness and recovers after SIGKILL",
                   probe.runtime_owner_recovers_stale_readiness_and_crash)
        probe.case("fresh alias collision rolls back and retries without disturbing its owner",
                   probe.alias_collision_rolls_back_and_retries)
        probe.case("Claude relaunch in a used pane enrolls and reconciles its alias at the first prompt",
                   probe.claude_relaunch_in_used_pane_reconciles)
        probe.case("old cleanup settles before successor startup and late observations preserve identity",
                   probe.alias_reuse_preserves_successor_identity)
        probe.case("alias reuse refreshes stale lookup and preserves an independent identity",
                   probe.alias_reuse_refreshes_a_stale_read)
        probe.case("late Claude binding refusal preserves native startup without a claim", probe.claude_late_bind_r10_fallback)
        probe.case("cci crash preserves the bound live native client until its own exit", probe.claude_relation_and_handoff)
        probe.case("real Claude /exit preserves normal native exit status", probe.claude_normal_exit)
        probe.case("real Claude first prompt publishes retained-alias lifecycle handoff", probe.claude_first_prompt_handoff)
        probe.case("non-descendant Claude handoff is rejected without a mutation", probe.claude_non_descendant_handoff_is_refused)
        probe.case("nested native Claude handoff is rejected without a mutation", probe.claude_nested_native_handoff_is_refused)
        probe.case("Claude handoff retries after its first prompt sees an unavailable socket",
                   probe.claude_handoff_retries_after_socket_restoration)
        probe.case("delayed old release preserves a real detected successor and its Intercom identity", probe.detected_successor_survives_old_release)
        probe.case("native and wrapped Claude preserve normal interactive quit status", probe.claude_normal_quit_parity)
        probe.case("native and wrapped Claude preserve interactive Ctrl-C behavior and status", probe.claude_ctrl_c_parity)
        probe.case("native and wrapped Claude preserve TERM behavior and exact cci status", probe.claude_term_parity)
        probe.known_upstream_case("OpenCode recovery-disabled suspension is independently attributed and recovery remains non-interfering",
                                  lambda: probe.qualify_suspension_exception("opencode", 12))
        probe.known_upstream_case("Pi reference-launcher suspension is independently attributed and recovery remains non-interfering",
                                  lambda: probe.qualify_suspension_exception("pi", 13))
        probe.known_upstream_case("Claude native suspension is independently attributed and recovery remains non-interfering",
                                  lambda: probe.qualify_suspension_exception("claude", 14))
    versions = {}
    try:
        probe.start()
        versions = installed_versions()
        run_cases()
        after = installed_versions()
        before_identity = {key: value if isinstance(value, str) else value["stdout"] for key, value in versions.items()}
        after_identity = {key: value if isinstance(value, str) else value["stdout"] for key, value in after.items()}
        require({"step": "stable-client-builds"}, before_identity == after_identity,
                f"installed versions changed during the run: {before_identity} != {after_identity}")
    except Exception as error:
        probe.results.append({"case": "probe execution", "status": "FAIL",
                              "details": {"error": f"{type(error).__name__}: {error}"}})
    finally:
        try:
            probe.close()
            print(f"CLEANUP: removed client scratch {probe.scratch} and stopped isolated Herdr {probe.owner.session}.")
        except Exception as error:
            probe.results.append({"case": "probe cleanup", "status": "FAIL", "details": {"error": str(error)}})
    return 0 if write_artifact(probe, "suspension-proof" if suspension_only else "client-proof", versions) else 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--terminal-driver", action="store_true")
    parser.add_argument("--suspension-diagnostic", action="store_true")
    parser.add_argument("--driver-receipt")
    parser.add_argument("--cwd")
    parser.add_argument("client_args", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    arguments.driver_command = arguments.client_args
    if arguments.terminal_driver:
        return terminal_driver(arguments)
    return run_probe(arguments.suspension_diagnostic)


if __name__ == "__main__":
    sys.exit(main())
