#!/usr/bin/env python3
"""Durable OpenCode turns; task acceptance belongs to the calling skill."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys


def save(path, value):
    pending = path.with_name(path.name + ".tmp")
    with pending.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    pending.replace(path)


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def git(cwd, *args):
    result = subprocess.run(["git", "-C", str(cwd), *args], stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace").strip())
    return result.stdout


def porcelain(cwd):
    return git(cwd, "status", "--porcelain=v1", "--untracked-files=all")


def extract(path, major=2):
    sessions, texts, errors = set(), {}, []
    identities = {}
    malformed = False
    for line in path.read_bytes().splitlines():
        try:
            event = json.loads(line)
            if not isinstance(event, dict) or not isinstance(event.get("type"), str):
                raise ValueError("invalid event")
            session = event.get("sessionID")
            if not isinstance(session, str) or not session.strip():
                raise ValueError("missing sessionID")
            sessions.add(session)
            if event["type"] == "error":
                errors.append(event)
            if event["type"] == "text":
                part = event.get("part")
                if not isinstance(part, dict) or not isinstance(part.get("text"), str):
                    raise ValueError("invalid text part")
                message, identity = part.get("messageID"), part.get("id")
                if not isinstance(message, str) or not message or not isinstance(identity, str) or not identity:
                    raise ValueError("missing text identity")
                parts = texts.setdefault(message, {})
                if major == 1:
                    parts[identity] = part["text"]
                    continue
                # V2 reconciliation aliases streamed parts by message/text ordinal.
                prefix = "prt_" + message.removeprefix("msg_") + "_text-"
                if identity.startswith(prefix) and identity[len(prefix):].isdigit():
                    ordinal = int(identity[len(prefix):])
                else:
                    key = (message, identity)
                    if key not in identities:
                        identities[key] = max(parts, default=-1) + 1
                    ordinal = identities[key]
                parts[ordinal] = parts.get(ordinal, "") + part["text"]
        except (ValueError, UnicodeError):
            malformed = True
    answer = "\n".join(parts[key] for parts in texts.values()
                       for key in (sorted(parts) if major == 2 else parts))
    return sessions, answer, errors, malformed


STORAGE_ENV = ("HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME",
               "OPENCODE_DB", "OPENCODE_CONFIG_DIR", "OPENCODE_DISABLE_CHANNEL_DB")


def environment(state):
    env = dict(os.environ, PWD=state["cwd"])
    for key, value in state["storage"].items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = value
    return env


def version(binary, cwd, env):
    result = subprocess.run([binary, "--version"], cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                            capture_output=True, text=True)
    match = re.fullmatch(r"(?:opencode v)?([12])\.(\d+)\.(\d+)", result.stdout.strip())
    if result.returncode or not match:
        raise RuntimeError("cannot identify a supported OpenCode V1/V2 release")
    return match.group(0), int(match.group(1))


def idle(run):
    for path in run.glob("turn-*/process.json"):
        pgid = load(path)["pgid"]
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            continue
        raise RuntimeError(f"process group {pgid} still exists; retain {run}")
    for attempt in run.glob("turn-*"):
        status = attempt / "status.json"
        if not status.exists() or load(status).get("quiescent") is not True:
            raise RuntimeError(f"native work quiescence is unproven at {attempt}; retain state; operator recovery required")


def recover_session(run, state):
    if state.get("sessionID"):
        return state["sessionID"]
    sessions = set()
    for path in sorted(run.glob("turn-*/events.jsonl")):
        sessions.update(extract(path, state["major"])[0])
    if len(sessions) != 1:
        raise RuntimeError("cannot recover one native sessionID; retain logs and state")
    state["sessionID"] = sessions.pop()
    save(run / "state.json", state)
    return state["sessionID"]


def prepare(args, run):
    cwd = Path(args.cwd).resolve(strict=True)
    if not cwd.is_dir():
        raise RuntimeError("cwd must be a directory")
    binary = shutil.which("opencode")
    if not binary:
        raise RuntimeError("opencode is not on PATH")
    state = {"cwd": str(cwd), "model": args.model, "auto": args.auto,
             "binary": str(Path(binary).resolve()), "sessionID": None, "epic": None,
             "storage": {key: os.environ.get(key) for key in STORAGE_ENV}}
    state["storage"]["HOME"] = str(Path.home())
    state["cli_version"], state["major"] = version(state["binary"], cwd, environment(state))
    if args.review_ref:
        epic = Path(os.fsdecode(git(cwd, "rev-parse", "--show-toplevel")).strip()).resolve()
        if run == epic or epic in run.parents:
            raise RuntimeError("review artifacts must be outside the epic checkout")
        git(epic, "rev-parse", "--verify", args.review_ref + "^{commit}")
        state.update(epic=str(epic), cwd=str(run / "worktree"), review_ref=args.review_ref)
    save(run / "state.json", state)
    if state["epic"]:
        (run / "epic.before").write_bytes(porcelain(state["epic"]))
        git(state["epic"], "worktree", "add", "--detach", state["cwd"], args.review_ref)
    return state


def turn(args, run, state, lock):
    prompt = Path(args.prompt_file).read_text(encoding="utf-8")
    if not prompt.strip():
        raise RuntimeError("prompt file is empty")
    files = [str(Path(path).resolve(strict=True)) for path in args.file]
    if any(not Path(path).is_file() for path in files):
        raise RuntimeError("attachments must be files")
    expected = recover_session(run, state) if args.command == "resume" else None
    number = len(list(run.glob("turn-*"))) + 1
    attempt = run / f"turn-{number:04d}"
    attempt.mkdir()
    (attempt / "prompt.md").write_text(prompt, encoding="utf-8")
    argv = [state["binary"], "run", "--format=json", "--model=" + state["model"]]
    if state["major"] == 2:
        argv.insert(2, "--standalone")
    if state["auto"]:
        argv.append("--auto")
    if expected:
        argv.append("--session=" + expected)
    argv.extend("--file=" + path for path in files)
    argv.extend(["--", prompt])
    save(attempt / "request.json", {"argv": argv, "cwd": state["cwd"], "sessionID": expected})
    save(attempt / "status.json", {"classification": "incomplete", "exit_code": None, "quiescent": False})
    env = environment(state)
    if expected:
        export = ([state["binary"], "session", "export", "--standalone", expected] if state["major"] == 2
                  else [state["binary"], "export", expected])
        save(attempt / "session-check.request.json", {"argv": export, "cwd": state["cwd"]})
        try:
            with (attempt / "session-check.json").open("xb") as output, (attempt / "session-check.stderr").open("xb") as errors:
                checked = subprocess.run(export, cwd=state["cwd"], env=env, stdin=subprocess.DEVNULL,
                                         stdout=output, stderr=errors, pass_fds=(lock.fileno(),))
        except OSError as error:
            save(attempt / "status.json", {"classification": "failure", "exit_code": None,
                                           "helper_error": str(error), "quiescent": True})
            raise
        save(attempt / "session-check.status.json", {"exit_code": checked.returncode})
        save(attempt / "status.json", {"classification": "failure", "exit_code": None,
                                       "session_check_exit": checked.returncode, "quiescent": checked.returncode >= 0})
        if checked.returncode:
            raise RuntimeError("session export failed; refusing to create a replacement session")
        data = load(attempt / "session-check.json")
        info = data.get("info") if isinstance(data, dict) else None
        if not isinstance(info, dict):
            raise RuntimeError("invalid session export info")
        location = info.get("location") if state["major"] == 2 else info
        directory = location.get("directory") if isinstance(location, dict) else None
        if (info.get("id") != expected or directory != state["cwd"]
                or not isinstance(data.get("messages"), list) or not data["messages"]):
            raise RuntimeError("session export does not match saved identity, cwd, and history")
    save(attempt / "status.json", {"classification": "incomplete", "exit_code": None, "quiescent": False})
    child = None
    interrupted = None
    forwarded = False

    def forward(signum, _frame):
        nonlocal interrupted, forwarded
        if interrupted is None:
            interrupted = signum
        if child is not None and not forwarded:
            forwarded = True
            try:
                # V2's second SIGINT calls process.exit before scoped teardown.
                child.send_signal(signal.SIGINT)
            except ProcessLookupError:
                pass

    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    previous = {sig: signal.signal(sig, forward) for sig in signals}
    code, launch_error = None, None
    try:
        with (attempt / "events.jsonl").open("xb") as output, (attempt / "stderr.log").open("xb") as errors:
            if interrupted is None:
                child = subprocess.Popen(argv, cwd=state["cwd"], env=env, stdin=subprocess.DEVNULL,
                                         stdout=output, stderr=errors, start_new_session=True,
                                         pass_fds=(lock.fileno(),))
                # The inherited lock also blocks cleanup if this wrapper is killed.
                save(attempt / "process.json", {"pgid": child.pid})
                if interrupted is not None:
                    forward(interrupted, None)
                code = child.wait()
    except OSError as error:
        launch_error = str(error)
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)

    sessions, text, errors, malformed = extract(attempt / "events.jsonl", state["major"])
    session = next(iter(sessions)) if len(sessions) == 1 else None
    if session and (not expected or session == expected):
        state["sessionID"] = session
        save(run / "state.json", state)
    (attempt / "answer.txt").write_text(text, encoding="utf-8")
    save(attempt / "session.json", {"sessionID": session})
    epic_unchanged = None
    if state["epic"]:
        try:
            after = porcelain(state["epic"])
            (attempt / "epic.after").write_bytes(after)
            epic_unchanged = after == (run / "epic.before").read_bytes()
        except (OSError, RuntimeError) as error:
            launch_error = str(error)
    classification = "transport-ok"
    if interrupted or code is None or code < 0 or code in (129, 130, 143):
        classification = "incomplete"
    elif code != 0 or errors or malformed or len(sessions) > 1 or (expected and session != expected):
        classification = "failure"
    elif not session or not text.strip():
        classification = "incomplete"
    if launch_error or epic_unchanged is False:
        classification = "failure"
    result = {"classification": classification, "exit_code": code, "signal": interrupted,
              # The owned CLI closes its scope before normal exits, including 1/130.
              "quiescent": child is None or (code is not None and code >= 0), "cli_version": state["cli_version"],
              "sessionID": session, "model": state["model"], "malformed": malformed,
              "error_events": errors, "helper_error": launch_error, "epic_unchanged": epic_unchanged,
              "attempt": str(attempt), "answer": str(attempt / "answer.txt")}
    save(attempt / "status.json", result)
    print(json.dumps(result), flush=True)
    return 0 if classification == "transport-ok" else 1


def cleanup(run, state):
    if state["epic"]:
        cwd = Path(state["cwd"])
        def registered():
            return b"worktree " + os.fsencode(cwd) in git(state["epic"], "worktree", "list", "--porcelain", "-z").split(b"\0")

        if cwd.exists() or registered():
            git(state["epic"], "worktree", "remove", "--force", str(cwd))
        if cwd.exists() or cwd.is_symlink() or registered():
            raise RuntimeError("worktree remains; recovery state retained")
    (run / "state.json").unlink()
    if (run / "state.json").exists():
        raise RuntimeError("recovery state remains")
    print(json.dumps({"classification": "cleaned", "artifacts": str(run)}))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("launch", "resume", "cleanup"):
        command = commands.add_parser(name)
        command.add_argument("--run", required=True, help="durable artifact directory; launch requires a new path")
        if name != "cleanup":
            command.add_argument("--prompt-file", required=True)
            command.add_argument("-f", "--file", action="append", default=[])
        if name == "launch":
            command.add_argument("--cwd", required=True)
            command.add_argument("--model", required=True)
            command.add_argument("--auto", action="store_true")
            command.add_argument("--review-ref", help="create a disposable detached worktree at this committed ref")
    args = parser.parse_args()
    run = Path(args.run).resolve()
    try:
        if args.command == "launch":
            run.mkdir(mode=0o700)
        with (run / "lock").open("a+") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError("run is active; retain worktree and state") from None
            idle(run)
            if args.command == "launch":
                state = prepare(args, run)
            else:
                state = load(run / "state.json")
                if "cli_version" not in state:
                    raise RuntimeError("legacy run has no server ownership evidence; retain state for operator recovery")
                if args.command == "resume" and version(state["binary"], state["cwd"], environment(state))[0] != state["cli_version"]:
                    raise RuntimeError("OpenCode version changed; retain state and use the recorded binary version")
            if args.command == "cleanup":
                return cleanup(run, state)
            return turn(args, run, state, lock)
    except (OSError, ValueError, RuntimeError) as error:
        print(json.dumps({"classification": "failure", "helper_error": str(error), "run": str(run)}),
              file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
