#!/usr/bin/env python3
"""Record the harness-facing revmux contract without running a review."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys


def option(arguments, name):
    return arguments[arguments.index(name) + 1]


def record(event):
    with Path(os.environ["REVMUX_STANDIN_LOG"]).open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(event) + "\n")


def main():
    arguments = sys.argv[1:]
    command = "new" if arguments and arguments[0] == "new" else "run"
    if command == "new":
        arguments.pop(0)
    task = option(arguments, "--task")
    run = option(arguments, "--run")
    tasks_dir = Path(option(arguments, "--tasks-dir"))
    round_dir = tasks_dir / "stand-in-layout" / task / "rounds" / run
    input_dir = round_dir / "inputs-not-inferred-by-harness"

    if command == "new":
        input_dir.mkdir(parents=True)
        output = {
            "task_dir": str(round_dir.parent.parent),
            "task_file": str(round_dir.parent.parent / "task.md"),
            "round_dir": str(round_dir),
            "input_dir": str(input_dir),
            "scope": str(input_dir / "scope-from-new.md"),
            "goal": str(input_dir / "goal-from-new.md"),
            "profile": str(input_dir / "profile-from-new.md"),
            "context": str(input_dir / "context-from-new"),
        }
        record({"event": "new", "task": task, "run": run, "output": output})
        print(json.dumps(output))
        return

    if command == "run":
        workdir = Path(option(arguments, "--workdir"))
        scope_path = input_dir / "scope-from-new.md"
        goal_path = input_dir / "goal-from-new.md"
        record(
            {
                "event": "run",
                "task": task,
                "run": run,
                "head": subprocess.check_output(
                    ["git", "-C", str(workdir), "rev-parse", "HEAD"], text=True
                ).strip(),
                "scope": scope_path.read_text(encoding="utf-8"),
                "goal": goal_path.read_text(encoding="utf-8"),
                "profile": option(arguments, "--profile"),
                "no_tui": "--no-tui" in arguments,
                "tasks_dir": str(tasks_dir),
                "workdir": str(workdir),
                "cwd": str(Path.cwd()),
                "refs": subprocess.check_output(
                    ["git", "-C", str(workdir), "for-each-ref", "--format=%(refname)"],
                    text=True,
                ).splitlines(),
                "git_common_dir": subprocess.check_output(
                    ["git", "-C", str(workdir), "rev-parse", "--git-common-dir"],
                    text=True,
                ).strip(),
            }
        )
        (round_dir / "manifest.json").write_text("{}", encoding="utf-8")
        exit_status = os.environ.get("REVMUX_STANDIN_EXIT", "1")
        if exit_status == "signal":
            os.kill(os.getpid(), signal.SIGKILL)
        return int(exit_status)

    raise SystemExit(f"unexpected command: {command}")


if __name__ == "__main__":
    raise SystemExit(main())
