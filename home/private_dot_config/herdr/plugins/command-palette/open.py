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

# How an open palette pane identifies itself.
#
# The pane label cannot do this job. herdr sets it to the manifest title at
# creation and then overwrites it with a cwd-derived label a second or two
# later -- measured on 0.8.0: "Command Palette" at +1s, "~" at +4s -- and an
# explicit `pane rename` is overwritten the same way. Plugin-owned metadata is
# a separate channel that the relabel does not touch, and `herdr pane list`
# returns it, so one call answers "is a palette already open here".
PALETTE_TOKEN = "command_palette"
PALETTE_TOKEN_VALUE = "open"


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


def pane_is_palette(pane: dict[str, Any]) -> bool:
    tokens = pane.get("tokens")
    return isinstance(tokens, dict) and tokens.get(PALETTE_TOKEN) == PALETTE_TOKEN_VALUE


def opened_pane_id(stdout: str) -> str:
    """The pane id from a `herdr plugin pane open` response."""
    try:
        data = json.loads(stdout)
    except (json.JSONDecodeError, TypeError):
        return ""
    if not isinstance(data, dict):
        return ""
    plugin_pane = data.get("result", {}).get("plugin_pane") if isinstance(data.get("result"), dict) else None
    pane = plugin_pane.get("pane") if isinstance(plugin_pane, dict) else None
    pane_id = pane.get("pane_id") if isinstance(pane, dict) else None
    return pane_id if isinstance(pane_id, str) else ""


def mark_palette_pane(herdr: str, pane_id: str) -> None:
    """Stamp a freshly opened palette pane so the next keypress can find it."""
    if not pane_id:
        return
    try:
        subprocess.run(
            [
                herdr,
                "pane",
                "report-metadata",
                pane_id,
                "--source",
                PLUGIN_ID,
                "--token",
                f"{PALETTE_TOKEN}={PALETTE_TOKEN_VALUE}",
            ],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


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
        if not isinstance(pane, dict) or not pane_is_palette(pane):
            continue
        pane_id = pane.get("pane_id")
        if isinstance(pane_id, str) and pane_id:
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
    #
    # The guard matches the palette's own metadata token. It used to substring
    # match "palette.py" against a pane's argv, cmdline and cwd, which an editor
    # with the file open, a grep over it, or an agent discussing it all satisfy.
    current_pane = json_result([herdr, "pane", "get", target_pane]).get("pane") if target_pane else None
    if isinstance(current_pane, dict) and pane_is_palette(current_pane):
        focus_plugin_pane(herdr, target_pane)
        return 0
    workspace_id = current_pane.get("workspace_id") if isinstance(current_pane, dict) else ""
    existing_palette = workspace_palette_pane(herdr, workspace_id if isinstance(workspace_id, str) else "")
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
        "104",
        "--height",
        "34",
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
        opened = subprocess.run(command, check=True, text=True, capture_output=True)
    except Exception as exc:  # pragma: no cover - defensive notification path
        message = str(exc)
        stderr = getattr(exc, "stderr", "") or ""
        if stderr:
            message = f"{message}\n{stderr}"
        try:
            subprocess.run(
                [herdr, "notification", "show", "Command palette failed", "--body", message],
                check=False,
            )
        except Exception:
            pass
        print(message, file=sys.stderr)
        return 1

    mark_palette_pane(herdr, opened_pane_id(opened.stdout))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
