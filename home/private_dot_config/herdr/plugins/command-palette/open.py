#!/usr/bin/env python3
"""Open the command-palette overlay pane.

This action is the keybinding target. It captures the pane that was focused when
invoked and passes it into the overlay, so selected commands can run back in the
original pane instead of inside the palette itself.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Any

PLUGIN_ID = "seigi.command-palette"
PALETTE_SCRIPT = "palette.py"


def context_data() -> dict[str, Any]:
    raw = os.environ.get("HERDR_PLUGIN_CONTEXT_JSON")
    if not raw:
        return {}
    try:
        context = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return context if isinstance(context, dict) else {}


def focused_pane_from_context() -> str:
    context = context_data()

    for key in ("focused_pane_id", "pane_id"):
        value = context.get(key)
        if isinstance(value, str) and value:
            return value

    focused_pane = context.get("focused_pane")
    if isinstance(focused_pane, dict):
        value = focused_pane.get("pane_id") or focused_pane.get("id")
        if isinstance(value, str) and value:
            return value

    return ""


def focused_cwd_from_context() -> str:
    context = context_data()

    for key in ("focused_pane_cwd", "workspace_cwd", "cwd"):
        value = context.get(key)
        if isinstance(value, str) and value:
            return value

    focused_pane = context.get("focused_pane")
    if isinstance(focused_pane, dict):
        for key in ("foreground_cwd", "cwd"):
            value = focused_pane.get(key)
            if isinstance(value, str) and value:
                return value

    return ""


def json_result(command: list[str]) -> dict[str, Any]:
    try:
        result = subprocess.run(command, text=True, capture_output=True)
    except Exception:
        return {}
    if result.returncode != 0:
        return {}
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {}
    if not isinstance(data, dict):
        return {}
    result_data = data.get("result")
    return result_data if isinstance(result_data, dict) else {}


def process_is_palette(process: dict[str, Any]) -> bool:
    argv = process.get("argv")
    argv_text = " ".join(str(item) for item in argv) if isinstance(argv, list) else ""
    cmdline = str(process.get("cmdline") or "")
    cwd = str(process.get("cwd") or "")
    combined = " ".join(part for part in (argv_text, cmdline, cwd) if part)
    return PALETTE_SCRIPT in combined and "command-palette" in combined


def pane_runs_palette(herdr: str, pane_id: str) -> bool:
    if not pane_id:
        return False
    info = json_result([herdr, "pane", "process-info", "--pane", pane_id]).get("process_info")
    if not isinstance(info, dict):
        return False
    processes = info.get("foreground_processes")
    if not isinstance(processes, list):
        return False
    return any(isinstance(process, dict) and process_is_palette(process) for process in processes)


def pane_workspace_id(herdr: str, pane_id: str) -> str:
    if not pane_id:
        return ""
    pane = json_result([herdr, "pane", "get", pane_id]).get("pane")
    if not isinstance(pane, dict):
        return ""
    workspace_id = pane.get("workspace_id")
    return workspace_id if isinstance(workspace_id, str) else ""


def current_pane_id(herdr: str) -> str:
    pane = json_result([herdr, "pane", "current"]).get("pane")
    if not isinstance(pane, dict):
        return ""
    pane_id = pane.get("pane_id")
    return pane_id if isinstance(pane_id, str) else ""


def workspace_palette_pane(herdr: str, workspace_id: str) -> str:
    if not workspace_id:
        return ""
    result = json_result([herdr, "pane", "list", "--workspace", workspace_id])
    panes = result.get("panes")
    if not isinstance(panes, list):
        return ""
    for pane in panes:
        if not isinstance(pane, dict):
            continue
        pane_id = pane.get("pane_id")
        if isinstance(pane_id, str) and pane_runs_palette(herdr, pane_id):
            return pane_id
    return ""


def focus_plugin_pane(herdr: str, pane_id: str) -> None:
    if not pane_id:
        return
    try:
        subprocess.run(
            [herdr, "plugin", "pane", "focus", pane_id],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


def main() -> int:
    herdr = os.environ.get("HERDR_BIN_PATH", "herdr")
    plugin_id = os.environ.get("HERDR_PLUGIN_ID", PLUGIN_ID)
    target_pane = (
        focused_pane_from_context()
        or os.environ.get("HERDR_ACTIVE_PANE_ID")
        or os.environ.get("HERDR_PANE_ID")
        or current_pane_id(herdr)
        or ""
    )

    # The keybinding remains active while the overlay has focus. Without this
    # guard, pressing Cmd-Shift-P inside the palette opens another palette, and
    # the process can repeat indefinitely. If the focused/current pane is the
    # palette, or this workspace already has one, just keep/focus the existing
    # overlay instead of creating a nested one.
    if pane_runs_palette(herdr, target_pane):
        focus_plugin_pane(herdr, target_pane)
        return 0
    existing_palette = workspace_palette_pane(herdr, pane_workspace_id(herdr, target_pane))
    if existing_palette:
        focus_plugin_pane(herdr, existing_palette)
        return 0

    command = [
        herdr,
        "plugin",
        "pane",
        "open",
        "--plugin",
        plugin_id,
        "--entrypoint",
        "palette",
        "--placement",
        "popup",
        "--width",
        "80%",
        "--height",
        "50%",
        "--focus",
    ]
    if target_pane:
        command.extend(["--env", f"HERDR_TARGET_PANE_ID={target_pane}"])

    target_cwd = focused_cwd_from_context()
    if target_cwd:
        command.extend(["--env", f"HERDR_TARGET_CWD={target_cwd}"])

    test_config = os.environ.get("HERDR_COMMAND_PALETTE_CONFIG")
    if test_config:
        command.extend(["--env", f"HERDR_COMMAND_PALETTE_CONFIG={test_config}"])

    try:
        subprocess.run(command, check=True)
    except Exception as exc:  # pragma: no cover - defensive notification path
        message = str(exc)
        try:
            subprocess.run(
                [herdr, "notification", "show", "Command palette failed", "--body", message],
                check=False,
            )
        except Exception:
            pass
        print(message, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
