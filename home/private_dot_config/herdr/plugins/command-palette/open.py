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

PLUGIN_ID = "seigi.command-palette"


def focused_pane_from_context() -> str:
    raw = os.environ.get("HERDR_PLUGIN_CONTEXT_JSON")
    if not raw:
        return ""
    try:
        context = json.loads(raw)
    except json.JSONDecodeError:
        return ""

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
    raw = os.environ.get("HERDR_PLUGIN_CONTEXT_JSON")
    if not raw:
        return ""
    try:
        context = json.loads(raw)
    except json.JSONDecodeError:
        return ""

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


def main() -> int:
    herdr = os.environ.get("HERDR_BIN_PATH", "herdr")
    plugin_id = os.environ.get("HERDR_PLUGIN_ID", PLUGIN_ID)
    target_pane = (
        focused_pane_from_context()
        or os.environ.get("HERDR_ACTIVE_PANE_ID")
        or os.environ.get("HERDR_PANE_ID")
        or ""
    )

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
        "overlay",
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
