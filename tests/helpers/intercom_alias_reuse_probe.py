"""Causal old-cleanup/new-Claude ordering against the actual launcher."""

import json
import os
from pathlib import Path
import signal
import shlex
import shutil
import subprocess
import sys

from intercom_claim_client_probe import ROOT, ProbeError, native_executable, read_json, require, wait_until
from intercom_recovery_harness import observe_one, process_start_identity


def check_unsafe_reuse_fallback(probe, pane, first, directory, gate_bin, alias):
    """Live and unverifiable old ownership both preserve bare native startup."""
    executable = native_executable("opencode")
    control = subprocess.run([executable, "--not-a-real-option"], env=probe.owner.env,
                             text=True, capture_output=True, timeout=15)
    require({"step": "reuse-native-fallback-control"}, control.returncode == 1,
            f"native invalid-option control failed unexpectedly: {control.returncode}")
    fields = ("OPENCODE_INTERCOM_NAME", "HERDR_AGENT_INTERCOM_NAME",
              "HERDR_AGENT_INTERCOM_ACTIVE", "HERDR_AGENT_INTERCOM_RECOVERY_INTENT")
    wrapper = gate_bin / "opencode"
    wrapper.write_text(
        f"#!{sys.executable}\nimport json,os,sys\n"
        "with open(os.environ['MMS384_CAPTURE'], 'w') as stream:\n"
        f" json.dump({{'argv':sys.argv[1:],'environment':{{key:os.environ.get(key) for key in {fields!r}}}}},stream)\n"
        f"os.execv({executable!r},[{executable!r},*sys.argv[1:]])\n", encoding="utf-8")
    wrapper.chmod(0o700)
    ps = gate_bin / "ps"
    real_ps = shutil.which("ps")
    require({"step": "reuse-real-ps"}, real_ps is not None, "real process reader is absent")
    ps.write_text(
        "#!/bin/sh\nprevious=\nfor argument in \"$@\"; do\n"
        " if [ \"$previous\" = -p ] && [ \"$argument\" = \"${MMS384_HIDE_PID:-}\" ]; then exit 1; fi\n"
        " previous=$argument\ndone\n"
        f"exec {shlex.quote(real_ps)} \"$@\"\n", encoding="utf-8")
    ps.chmod(0o700)
    observations = {}
    for mode in ("live", "unverifiable"):
        capture = directory / f"fallback-{mode}.json"
        env = probe.owner.env | probe.foreground_exports(alias, 0) | {
            "HERDR_ENV": "1", "HERDR_PANE_ID": pane["pane_id"], "HERDR_SOCKET_PATH": probe.owner.socket_path,
            "PATH": str(gate_bin) + os.pathsep + os.environ["PATH"], "MMS384_CAPTURE": str(capture),
            "MMS384_HIDE_PID": str(first["pid"]) if mode == "unverifiable" else "",
        }
        run = subprocess.run([str(probe.launcher), "opencode", "--not-a-real-option"], env=env,
                             text=True, capture_output=True, timeout=20)
        require({"step": "reuse-fallback-native-status"}, run.returncode == control.returncode,
                f"{mode} reuse changed native exit status: {run.returncode}; {run.stderr}")
        observed = read_json(capture)
        require({"step": "reuse-fallback-no-borrowed-identity"}, observed == {
            "argv": ["--not-a-real-option"], "environment": dict.fromkeys(fields)},
            f"{mode} reuse borrowed the old owner's identity: {observed}")
        state = probe.state(pane)
        require({"step": "reuse-old-live-owner-preserved"}, state is not None and state.get("name") == alias and
                process_start_identity(first["pid"]) == first["start_identity"],
                f"{mode} reuse disturbed the prior live owner: {state}")
        observations[mode] = {"capture": observed, "status": run.returncode, "owner": state}
    return observations


def run_order(probe, request_before_detection):
    result = {"late_observation_before_detection": request_before_detection}
    pane = None
    try:
        directory = probe.scratch / ("reuse-early" if request_before_detection else "reuse-normal")
        directory.mkdir()
        gate_bin = directory / "bin"
        gate_bin.mkdir()
        command = gate_bin / "node"
        executable = shutil.which("node")
        cci = (Path.home() / ".local/share/agent-intercom/node_modules/.bin/cci").resolve()
        require({"step": "reuse-node-control"}, executable is not None and cci.is_file(), "real cci/node is unavailable")
        command.write_text(
            f"#!{sys.executable}\nimport json,os,pathlib,sys,time\n"
            f"sys.path.insert(0, {str(ROOT / 'tests/helpers')!r})\n"
            "from intercom_recovery_harness import atomic_write, process_start_identity\n"
            f"native={executable!r}\n"
            f"if len(sys.argv)>1 and pathlib.Path(sys.argv[1]).resolve()==pathlib.Path({str(cci)!r}):\n"
            " gate=pathlib.Path(os.environ['MMS384_GATE'])\n"
            " keys=('HERDR_AGENT_INTERCOM_NAME','HERDR_AGENT_INTERCOM_ACTIVE','HERDR_AGENT_INTERCOM_RECOVERY_INTENT')\n"
            " atomic_write(str(gate.with_suffix('.checked')),{'pid':os.getpid(),'start_identity':process_start_identity(os.getpid()),'environment':{key:os.environ.get(key) for key in keys}})\n"
            " deadline=time.monotonic()+60\n"
            " while not gate.exists():\n"
            "  if time.monotonic()>deadline: raise SystemExit('owned pre-exec barrier expired')\n"
            "  time.sleep(0.02)\n"
            "os.execv(native,[native,*sys.argv[1:]])\n", encoding="utf-8")
        command.chmod(0o700)
        first_gate, second_gate = directory / "first.go", directory / "second.go"
        env = {"PATH": str(gate_bin) + os.pathsep + os.environ["PATH"]}
        pane, receipt, log, exit_file = probe.launch(
            "claude", ["--no-chrome"], interactive=True, trace=True,
            extra_env=env | {"MMS384_GATE": str(first_gate)})
        probe.wait_driver(receipt, "running")
        wait_until(first_gate.with_suffix(".checked").exists, 15, "old launcher at cci entry")
        first = read_json(first_gate.with_suffix(".checked"))
        intent_path = read_json(receipt)["intent"]
        intent = read_json(intent_path)
        require({"step": "reuse-old-bound-pid"}, intent["client"] == {
            key: first[key] for key in ("pid", "start_identity")}, "old intent did not follow its launcher PID")
        observer = read_json(probe.launchd.pid_file)
        probe.launchd.close()
        require({"step": "reuse-observer-stopped"},
                process_start_identity(observer["pid"]) != observer["start_identity"], "old observer is still live")
        alias = read_json(receipt)["alias"]
        if not request_before_detection:
            result["fallback_controls"] = check_unsafe_reuse_fallback(probe, pane, first, directory, gate_bin, alias)
        os.kill(first["pid"], signal.SIGKILL)
        first_status = probe.wait_exit(log, exit_file, receipt)
        require({"step": "reuse-old-exited"}, process_start_identity(first["pid"]) != first["start_identity"],
                "old pre-exec process did not exit")
        retained = probe.state(pane)
        require({"step": "reuse-retained-old-claim"}, retained is not None and retained.get("name") == alias and
                retained.get("agent_status") == "unknown", f"old unknown claim did not remain: {retained}")
        result.update(old_process=first, old_stage="launcher at cci entry before native exec", old_status=first_status,
                      old_intent=intent, observer_stopped=observer, retained_after_exit=retained,
                      terminal=probe.stable_terminal(pane))
        _, receipt, log, exit_file = probe.launch(
            "claude", ["--no-chrome"], interactive=True, pane=pane, claim_required=False,
            extra_env=env | {"MMS384_GATE": str(second_gate)})
        probe.wait_driver(receipt, "running")
        wait_until(second_gate.with_suffix(".checked").exists, 25, "successor after alias selection before cci")
        second = read_json(second_gate.with_suffix(".checked"))
        selected = second["environment"]["HERDR_AGENT_INTERCOM_NAME"]
        require({"step": "reuse-successor-enrolled"}, bool(selected) and
                second["environment"]["HERDR_AGENT_INTERCOM_ACTIVE"] == "1",
                f"healthy successor lost enrollment: {second}")
        require({"step": "reuse-pre-detection-barrier"}, probe.descendants(second["pid"]) == [],
                "successor cci spawned children before the controlled release")
        result["successor_pre_exec"] = second
        ended = read_json(intent_path)
        require({"step": "reuse-old-obligation-ended"}, ended["phase"] in {"settled", "retired"},
                f"successor started before old cleanup settled: {ended}")
        result["old_intent_at_successor_gate"] = ended
        successor_handle = second["environment"]["HERDR_AGENT_INTERCOM_RECOVERY_INTENT"]
        result["successor_route"] = "fresh_claim" if successor_handle else "independent_alias"
        result["successor_intent_at_gate"] = read_json(successor_handle) if successor_handle else None

        def ready():
            clients = [client for pid, _, _ in probe.descendants(second["pid"])
                       if (client := probe.native_process(pid, "claude"))]
            if len(clients) != 1 or not probe.native_input_ready(clients[0]["pid"]):
                return None
            explanation = probe.owner.run("agent", "explain", pane["pane_id"], "--json", expected=None)
            if explanation.returncode:
                return None
            details = json.loads(explanation.stdout)
            return clients[0] if (details.get("matched_rule") or {}).get("id") == "live_prompt_box" else None

        if not request_before_detection:
            second_gate.touch()
            wait_until(ready, 25, "normal-order native detection")
            result["detected_before_late_observation"] = probe.state(pane)
        observe_one(intent_path)
        result["after_late_observation"] = probe.state(pane)
        result["old_intent_after_late_observation"] = read_json(intent_path)
        second_gate.touch()
        client = wait_until(ready, 25, "successor native input prompt")
        broker = wait_until(lambda: probe.intercom_identity(selected), 20, "successor broker registration")
        state = probe.state(pane)
        result.update(successor_native=client, successor_broker=broker, successor_herdr=state)
        require({"step": "reuse-successor-identity"}, state is not None and state.get("name") == broker["name"],
                f"old cleanup split the successor identity: Herdr={state}; Intercom={broker}")
        result["quit_status"] = probe.send_normal_quit("claude", pane, receipt, log, exit_file)
        return result
    except ProbeError as error:
        error.evidence = result
        raise
    finally:
        if pane is not None:
            probe.owner.run("pane", "close", pane["pane_id"])
        probe.restart_observer()
