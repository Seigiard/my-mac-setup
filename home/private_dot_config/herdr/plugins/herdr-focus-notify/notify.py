#!/usr/bin/env python3
"""Clickable macOS notification when a herdr agent goes blocked or done.

Event hook for `pane.agent_status_changed`. Herdr passes the event payload in
the HERDR_PLUGIN_EVENT_JSON environment variable; the fields read here
(data.pane_id, data.agent_status, data.agent, data.display_agent) match what
the upstream herdr-focus-notify plugin consumes. Only `blocked` and `done`
notify -- they are the two statuses that need the user's action.

The toast goes through terminal-notifier:
  -group    one notification per pane; a newer status replaces the older toast
  -activate brings the terminal that runs herdr to the front on click
  -execute  runs `herdr agent focus <pane-id>` on click

v1 always notifies: it builds no focus-suppression heuristics, learns no
terminal binding from pane.focused, and does not auto-remove a toast when the
pane gets focused. Ambiguous focus state must produce a notification, and
"always" is the simplest correct reading of that rule.

Fail open: any failure exits 0 so this hook can never break herdr event
dispatch. Errors go to stderr, which `herdr plugin log` captures.
"""

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from typing import List, Optional, Tuple

# The terminal this repo binds herdr to: ghostty's config auto-launches herdr
# (home/private_dot_config/ghostty/config). Override per machine with the
# one-line config file read by terminal_bundle_id().
DEFAULT_TERMINAL_BUNDLE_ID = "com.mitchellh.ghostty"

ACTIONABLE_STATUSES = ("blocked", "done")

NOTIFIER_CANDIDATES = (
    "/opt/homebrew/bin/terminal-notifier",
    "/usr/local/bin/terminal-notifier",
)


def parse_event(raw: str) -> Optional[Tuple[str, str, str]]:
    """(pane_id, status, agent_label) from event JSON, or None to stay quiet."""
    try:
        event = json.loads(raw)
    except ValueError:
        return None
    data = event.get("data") if isinstance(event, dict) else None
    if not isinstance(data, dict):
        return None

    status = str(data.get("agent_status") or "").strip().lower()
    pane_id = str(data.get("pane_id") or "").strip()
    if not pane_id or status not in ACTIONABLE_STATUSES:
        return None

    agent = ""
    for key in ("display_agent", "agent"):
        value = str(data.get(key) or "").strip()
        if value:
            agent = value
            break
    return pane_id, status, agent or "Agent"


def find_notifier() -> Optional[str]:
    override = os.environ.get("HERDR_FOCUS_NOTIFY_NOTIFIER_BIN")
    if override:
        return override if os.access(override, os.X_OK) else None
    found = shutil.which("terminal-notifier")
    if found:
        return found
    for candidate in NOTIFIER_CANDIDATES:
        if os.access(candidate, os.X_OK):
            return candidate
    return None


def resolve_herdr() -> str:
    # HERDR_BIN_PATH is set by herdr for plugin commands. The click command
    # runs later in a bare `sh` with no such environment, so resolve to an
    # absolute path now while the answer is still known.
    configured = os.environ.get("HERDR_BIN_PATH") or "herdr"
    if os.sep in configured:
        return configured
    return shutil.which(configured) or "/opt/homebrew/bin/herdr"


def terminal_bundle_id() -> str:
    override = os.environ.get("HERDR_FOCUS_NOTIFY_ACTIVATE")
    if override:
        return override
    config_dir = os.environ.get("HERDR_PLUGIN_CONFIG_DIR")
    if config_dir:
        path = os.path.join(config_dir, "terminal-bundle-id")
        try:
            with open(path, encoding="utf-8") as handle:
                value = handle.readline().strip()
            if value:
                return value
        except OSError:
            pass
    return DEFAULT_TERMINAL_BUNDLE_ID


def group_id(pane_id: str) -> str:
    """Stable per-pane group so a newer toast replaces the older one."""
    return "herdr-" + re.sub(r"[^A-Za-z0-9]+", "-", pane_id)


def notification_copy(status: str, agent: str) -> Tuple[str, str]:
    if status == "blocked":
        return f"{agent} needs your input", "Open the pane to review and respond."
    return f"{agent} finished", "Open the pane to review the result."


def build_argv(
    notifier: str, pane_id: str, title: str, body: str, herdr_bin: str
) -> List[str]:
    # The -execute value is the one string terminal-notifier hands to `sh`.
    # Both halves are shlex-quoted, so a pane id (or an unusual herdr path)
    # can never be interpreted as shell syntax.
    click_command = "{} agent focus {}".format(
        shlex.quote(herdr_bin), shlex.quote(pane_id)
    )
    return [
        notifier,
        "-title",
        title,
        "-subtitle",
        f"pane {pane_id}",
        "-message",
        body,
        "-group",
        group_id(pane_id),
        "-activate",
        terminal_bundle_id(),
        "-execute",
        click_command,
    ]


def main() -> int:
    if "--test" in sys.argv[1:]:
        pane_id = (
            os.environ.get("HERDR_ACTIVE_PANE_ID")
            or os.environ.get("HERDR_PANE_ID")
            or "test-pane"
        )
        parsed = (pane_id, "blocked", "Focus notify test")
    else:
        raw = os.environ.get("HERDR_PLUGIN_EVENT_JSON")
        if not raw:
            return 0
        parsed = parse_event(raw)
        if parsed is None:
            return 0

    pane_id, status, agent = parsed
    notifier = find_notifier()
    if notifier is None:
        print(
            "herdr-focus-notify: terminal-notifier not found; skipping notification",
            file=sys.stderr,
        )
        return 0

    title, body = notification_copy(status, agent)
    argv = build_argv(notifier, pane_id, title, body, resolve_herdr())
    try:
        subprocess.run(
            argv,
            check=False,
            timeout=15,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.SubprocessError) as err:
        print(f"herdr-focus-notify: notifier failed: {err}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
