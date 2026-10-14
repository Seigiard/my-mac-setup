#!/usr/bin/env python3
"""Synthetic transport, not a model. JSONL provenance is in README.md."""

import json
import os
from pathlib import Path
import signal
import sys
import time


args = sys.argv[1:]
mode = os.environ.get("FAKE_MODE", "valid")
major = os.environ.get("FAKE_MAJOR", "2")
if args == ["--version"]:
    print("opencode v2.0.28" if major == "2" else "1.19.0")
    sys.exit(0)
store = Path(os.environ["XDG_DATA_HOME"]) / "fixture-session.json"
if args[:2] == ["session", "export"] or args[:1] == ["export"]:
    if mode == "export-error":
        print("Fixture export failed", file=sys.stderr)
        sys.exit(1)
    if not store.exists():
        print("Session not found", file=sys.stderr)
        sys.exit(1)
    data = json.loads(store.read_text())
    if mode == "wrong-location":
        data["info"]["location"] = {"directory": "/wrong-checkout"}
    if mode == "bad-export":
        data["info"] = []
    if mode == "no-history":
        data["messages"] = []
    print(json.dumps(data))
    sys.exit(0)
session = next((arg.split("=", 1)[1] for arg in args if arg.startswith("--session=")), "ses_fixture")
native_session = session
if mode == "wrong-session":
    session = "ses_other"
observation = Path(os.environ["FAKE_OBSERVATION"])
observation.write_text(json.dumps({"argv": args, "cwd": os.getcwd(), "PWD": os.environ.get("PWD"),
                                   "stdin": sys.stdin.read()}))
store.parent.mkdir(parents=True, exist_ok=True)
info = {"id": native_session, "location": {"directory": os.getcwd()}} if major == "2" else {"id": native_session, "directory": os.getcwd()}
store.write_text(json.dumps({"info": info, "messages": [{"id": "msg_fixture", "type": "user"}]}))


def emit(kind, **data):
    print(json.dumps({"type": kind, "timestamp": 1720000000000, "sessionID": session, **data}), flush=True)


if mode == "empty":
    sys.exit(0)
if mode == "no-session":
    print('{"type":"text","part":{"text":"Unattributed"}}')
    sys.exit(0)
emit("step_start", part={"type": "step-start", "sessionID": session, "messageID": "msg_fixture"})
if mode == "wait":
    interrupted = False

    def interrupt(_signum, _frame):
        global interrupted
        if interrupted:
            os._exit(130)
        interrupted = True
        Path(os.environ["FAKE_READY"] + ".interrupt").touch()

    signal.signal(signal.SIGINT, interrupt)
    Path(os.environ["FAKE_READY"]).touch()
    while not Path(os.environ["FAKE_RELEASE"]).exists():
        time.sleep(0.02)
    Path(os.environ["FAKE_READY"] + ".settled").touch()
    if interrupted:
        sys.exit(130)
if mode == "mutate-epic":
    Path(os.environ["FAKE_EPIC_FILE"]).write_text("unexpected persistent edit\n")
if mode == "suffix":
    # The projected ID/message pair below comes from the retained live V2 JSONL.
    for identity, message, text in [("prt_first", "msg_138f1d3f2001Gg4faoD3R0Gy1E", "Read /tmp/re"),
                                     ("prt_other", "msg_138f1d3f2001Gg4faoD3R0Gy1E", "Token: AB"),
                                     ("prt_later", "msg_next", "Next message"),
                                     ("prt_138f1d3f2001Gg4faoD3R0Gy1E_text-0", "msg_138f1d3f2001Gg4faoD3R0Gy1E", "port.md"),
                                     ("prt_138f1d3f2001Gg4faoD3R0Gy1E_text-1", "msg_138f1d3f2001Gg4faoD3R0Gy1E", "CD"),
                                     ("prt_138f1d3f2001Gg4faoD3R0Gy1E_text-1", "msg_138f1d3f2001Gg4faoD3R0Gy1E", "EF")]:
        emit("text", part={"type": "text", "id": identity, "sessionID": session,
                           "messageID": message, "text": text})
    sys.exit(0)
if mode == "v1-update":
    for text in ["Read /tmp/re", "Read /tmp/report.md"]:
        emit("text", part={"type": "text", "id": "prt_first", "sessionID": session,
                           "messageID": "msg_fixture", "text": text})
    sys.exit(0)
emit("text", part={"type": "text", "id": "prt_first", "sessionID": session, "messageID": "msg_fixture",
                   "text": "Task rejected: missing evidence."})
if mode == "signal":
    os.kill(os.getpid(), signal.SIGTERM)
if mode == "malformed":
    print("{broken")
if mode == "bad-part":
    emit("text", part=[])
if mode in ("error", "provider-error"):
    emit("error", error={"type": "unknown", "message": "Fixture transport error"})
emit("step_finish", part={"type": "step-finish", "sessionID": session, "messageID": "msg_fixture",
                          "reason": "stop", "cost": 0, "tokens": {}})
print("fixture diagnostic on stderr", file=sys.stderr)
sys.exit(1 if mode == "provider-error" else 7 if mode == "nonzero" else 0)
