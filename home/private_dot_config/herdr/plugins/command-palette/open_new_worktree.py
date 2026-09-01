#!/usr/bin/env python3
"""Open one modal progress pane for direct worktree creation."""

from __future__ import annotations

import os
import subprocess
import sys
from typing import Any

import open as plugin_open


PLUGIN_ID = "seigi.command-palette"
PANE_TOKEN = "new_worktree_progress"
PANE_TOKEN_VALUE = "open"


def pane_is_progress(pane: dict[str, Any]) -> bool:
    tokens = pane.get("tokens")
    return isinstance(tokens, dict) and tokens.get(PANE_TOKEN) == PANE_TOKEN_VALUE


def workspace_progress_pane(herdr: str, workspace_id: str) -> str:
    if not workspace_id:
        return ""
    panes = plugin_open.json_result([herdr, "pane", "list", "--workspace", workspace_id]).get("panes")
    if not isinstance(panes, list):
        return ""
    for pane in panes:
        if not isinstance(pane, dict) or not pane_is_progress(pane):
            continue
        pane_id = pane.get("pane_id")
        if isinstance(pane_id, str) and pane_id:
            return pane_id
    return ""


def mark_progress_pane(herdr: str, pane_id: str) -> None:
    if not pane_id:
        return
    plugin_open.run_quietly(
        [
            herdr,
            "pane",
            "report-metadata",
            pane_id,
            "--source",
            PLUGIN_ID,
            "--token",
            f"{PANE_TOKEN}={PANE_TOKEN_VALUE}",
        ]
    )


def workspace_label_from_context() -> str:
    value = plugin_open.context_data().get("workspace_label")
    return value if isinstance(value, str) else ""


def main() -> int:
    herdr = os.environ.get("HERDR_BIN_PATH", "herdr")
    plugin_id = os.environ.get("HERDR_PLUGIN_ID", PLUGIN_ID)
    target_pane = (
        plugin_open.focused_pane_from_context()
        or os.environ.get("HERDR_ACTIVE_PANE_ID")
        or os.environ.get("HERDR_PANE_ID")
        or plugin_open.current_pane_id(herdr)
        or ""
    )
    current_pane = plugin_open.json_result([herdr, "pane", "get", target_pane]).get("pane") if target_pane else None
    if isinstance(current_pane, dict) and pane_is_progress(current_pane):
        plugin_open.focus_plugin_pane(herdr, target_pane)
        return 0

    workspace_id = current_pane.get("workspace_id") if isinstance(current_pane, dict) else ""
    existing = workspace_progress_pane(herdr, workspace_id if isinstance(workspace_id, str) else "")
    if existing:
        plugin_open.focus_plugin_pane(herdr, existing)
        return 0

    command = [
        herdr,
        "plugin",
        "pane",
        "open",
        "--plugin",
        plugin_id,
        "--entrypoint",
        "new_worktree_progress",
        "--placement",
        "popup",
        "--width",
        "96",
        "--height",
        "24",
        "--focus",
    ]
    target_cwd = plugin_open.focused_cwd_from_context()
    if target_cwd:
        command.extend(["--env", f"HERDR_TARGET_CWD={target_cwd}"])
    workspace_label = workspace_label_from_context()
    if workspace_label:
        command.extend(["--env", f"HERDR_TARGET_WORKSPACE_LABEL={workspace_label}"])

    try:
        opened = subprocess.run(command, check=True, text=True, capture_output=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        message = getattr(exc, "stderr", "") or str(exc)
        print(message, file=sys.stderr)
        plugin_open.run_quietly(
            [herdr, "notification", "show", "New worktree failed", "--body", message]
        )
        return 1

    mark_progress_pane(herdr, plugin_open.opened_pane_id(opened.stdout))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
