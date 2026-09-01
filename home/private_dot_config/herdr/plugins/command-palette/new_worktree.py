#!/usr/bin/env python3
"""Create a timestamp-named Worktrunk checkout and open it as a Herdr workspace."""

from __future__ import annotations

from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Any


def context_data() -> dict[str, Any]:
    try:
        data = json.loads(os.environ.get("HERDR_PLUGIN_CONTEXT_JSON", "{}"))
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def target_cwd() -> str:
    context = context_data()
    for key in ("focused_pane_cwd", "workspace_cwd", "cwd"):
        value = context.get(key)
        if isinstance(value, str) and value:
            return value
    return os.environ.get("HERDR_TARGET_CWD", "")


def run_json(command: list[str], *, cwd: str | None = None) -> dict[str, Any]:
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "command failed"
        raise RuntimeError(message)
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"command returned invalid JSON: {' '.join(command)}") from exc
    if not isinstance(data, dict):
        raise RuntimeError(f"command returned invalid JSON: {' '.join(command)}")
    return data


def notify(herdr: str, message: str) -> None:
    subprocess.run(
        [herdr, "notification", "show", "New worktree failed", "--body", message],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def main() -> int:
    herdr = os.environ.get("HERDR_BIN_PATH", "herdr")
    cwd = target_cwd()
    if not cwd or not Path(cwd).is_dir():
        notify(herdr, "The focused pane has no usable working directory.")
        return 1

    branch = datetime.now().astimezone().strftime("worktree-%Y%m%d-%H%M%S-%f")
    created_path = ""
    try:
        switched = run_json(
            ["wt", "switch", "--create", branch, "--no-cd", "--format=json"],
            cwd=cwd,
        )
        wtpath = switched.get("path")
        resolved_branch = switched.get("branch")
        if not isinstance(wtpath, str) or not wtpath:
            raise RuntimeError("Worktrunk returned no worktree path.")
        created_path = wtpath
        if not isinstance(resolved_branch, str) or not resolved_branch:
            resolved_branch = branch

        worktrees = run_json([herdr, "worktree", "list", "--cwd", cwd, "--json"])
        result = worktrees.get("result")
        source = result.get("source") if isinstance(result, dict) else None
        if not isinstance(source, dict):
            raise RuntimeError("Herdr returned no repository source.")
        repo_root = source.get("repo_root")
        if not isinstance(repo_root, str) or not repo_root:
            raise RuntimeError("Herdr returned no repository root.")

        if not source.get("source_workspace_id"):
            repo_name = source.get("repo_name")
            if isinstance(repo_name, str) and repo_name:
                subprocess.run(
                    [
                        herdr,
                        "workspace",
                        "create",
                        "--cwd",
                        repo_root,
                        "--label",
                        repo_name.removesuffix(".git"),
                        "--no-focus",
                    ],
                    check=True,
                    stdout=subprocess.DEVNULL,
                )

        run_json(
            [
                herdr,
                "worktree",
                "open",
                "--cwd",
                repo_root,
                "--path",
                wtpath,
                "--label",
                resolved_branch,
                "--focus",
                "--json",
            ]
        )
        return 0
    except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        message = str(exc)
        if created_path:
            message = f"Worktree {branch} was created at {created_path}, but Herdr could not open it: {message}"
        print(f"New worktree failed: {message}", file=sys.stderr)
        notify(herdr, message)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
