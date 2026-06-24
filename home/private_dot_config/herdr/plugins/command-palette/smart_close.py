#!/usr/bin/env python3
"""Close the focused pane/tab without closing the workspace.

Behavior:
- If the current tab has multiple panes: close the focused pane.
- Else if the current workspace has multiple tabs: close the current tab.
- Else: keep the last tab/pane and notify the user.

This makes Cmd-W behave like a safe macOS-style close action while leaving
workspace destruction to Herdr's explicit close-workspace binding.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Any


def run_json(command: list[str]) -> dict[str, Any]:
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout or "command failed").strip())
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid JSON from {' '.join(command)}") from exc
    if not isinstance(data, dict):
        raise RuntimeError(f"unexpected response from {' '.join(command)}")
    response = data.get("result")
    return response if isinstance(response, dict) else {}


def notify(herdr: str, title: str, body: str) -> None:
    subprocess.run([herdr, "notification", "show", title, "--body", body], check=False)


def current_pane(herdr: str) -> dict[str, Any]:
    result = run_json([herdr, "pane", "current", "--current"])
    pane = result.get("pane")
    if not isinstance(pane, dict):
        raise RuntimeError("could not determine current pane")
    return pane


def list_tabs(herdr: str, workspace_id: str) -> list[dict[str, Any]]:
    result = run_json([herdr, "tab", "list", "--workspace", workspace_id])
    tabs = result.get("tabs")
    return [tab for tab in tabs if isinstance(tab, dict)] if isinstance(tabs, list) else []


def close_safely(herdr: str) -> int:
    pane = current_pane(herdr)
    pane_id = str(pane.get("pane_id") or "")
    tab_id = str(pane.get("tab_id") or "")
    workspace_id = str(pane.get("workspace_id") or "")
    if not pane_id or not tab_id or not workspace_id:
        raise RuntimeError("current pane response is missing pane/tab/workspace id")

    tabs = list_tabs(herdr, workspace_id)
    current_tab = next((tab for tab in tabs if tab.get("tab_id") == tab_id), None)
    pane_count = int((current_tab or {}).get("pane_count") or 1)

    if pane_count > 1:
        subprocess.run([herdr, "pane", "close", pane_id], check=True)
        return 0

    if len(tabs) > 1:
        subprocess.run([herdr, "tab", "close", tab_id], check=True)
        return 0

    notify(
        herdr,
        "Keeping last tab",
        "Cmd-W will not close the last tab in a workspace. Use the explicit close-workspace shortcut if you want to close the workspace.",
    )
    return 0


def main() -> int:
    herdr = os.environ.get("HERDR_BIN_PATH", "herdr")
    try:
        return close_safely(herdr)
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        notify(herdr, "Smart close failed", str(exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
