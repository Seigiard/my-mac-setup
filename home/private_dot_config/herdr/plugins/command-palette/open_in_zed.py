#!/usr/bin/env python3
"""Open a pane directory's Git root in the existing Zed window."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys

COMMAND_TIMEOUT_SECONDS = 5
MACOS_ZED_CLI = Path("/Applications/Zed.app/Contents/MacOS/cli")


def resolve_target(raw_path: str) -> Path:
    if not raw_path.strip():
        raise ValueError("directory must not be empty")

    target = Path(raw_path).expanduser().resolve()
    if not target.is_dir():
        raise ValueError(f"not a directory: {target}")

    try:
        result = subprocess.run(
            ["git", "-C", str(target), "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=COMMAND_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return target

    if result.returncode != 0:
        return target

    root_text = result.stdout.strip()
    if not root_text:
        return target

    root = Path(root_text).expanduser().resolve()
    return root if root.is_dir() else target


def resolve_zed() -> str:
    configured = os.environ.get("ZED_BIN")
    if configured is not None:
        configured = configured.strip()
        if not configured:
            raise ValueError("ZED_BIN must be a non-empty executable path")
        path = Path(configured).expanduser()
        if not path.is_file() or not os.access(path, os.X_OK):
            raise ValueError(f"ZED_BIN is not executable: {path}")
        return str(path)

    executable = shutil.which("zed")
    if executable:
        return executable

    if sys.platform == "darwin" and MACOS_ZED_CLI.is_file() and os.access(MACOS_ZED_CLI, os.X_OK):
        return str(MACOS_ZED_CLI)

    raise ValueError("Zed CLI not found; install `zed` or set ZED_BIN")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {Path(argv[0]).name} DIRECTORY", file=sys.stderr)
        return 2

    try:
        target = resolve_target(argv[1])
        zed = resolve_zed()
        result = subprocess.run(
            [zed, "-e", str(target)],
            timeout=COMMAND_TIMEOUT_SECONDS,
            check=False,
        )
    except ValueError as error:
        print(error, file=sys.stderr)
        return 2
    except subprocess.TimeoutExpired:
        print(f"Zed did not respond within {COMMAND_TIMEOUT_SECONDS} seconds", file=sys.stderr)
        return 124
    except OSError as error:
        print(f"failed to start Zed: {error}", file=sys.stderr)
        return 1

    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
