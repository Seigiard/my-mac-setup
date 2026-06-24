#!/usr/bin/env python3
"""Tiny dependency-free TUI command palette for Herdr.

Commands are read from ~/.config/herdr/command-palette/commands.json (or
HERDR_COMMAND_PALETTE_CONFIG), seeded from this plugin's defaults on first run.
The palette deliberately executes only commands from that local config file;
there is no runtime command registration or shell parsing for Herdr argv entries.
"""

from __future__ import annotations

import json
import os
import select
import shlex
import shutil
import subprocess
import sys
import termios
import tty
from dataclasses import dataclass
from pathlib import Path
from typing import Any

DEFAULT_LIMIT = 12
ESC = "\x1b["


@dataclass
class Command:
    title: str
    description: str
    kind: str
    group: str
    raw: dict[str, Any]

    @property
    def search_text(self) -> str:
        return f"{self.group} {self.title} {self.description} {self.kind}"


def xdg_config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))


def user_config_path() -> Path:
    return xdg_config_home() / "herdr" / "command-palette" / "commands.json"


def plugin_config_path() -> Path:
    return Path(
        os.environ.get(
            "HERDR_PLUGIN_CONFIG_DIR",
            xdg_config_home() / "herdr" / "plugins" / "command-palette-config",
        )
    ) / "commands.json"


def bundled_defaults_path() -> Path:
    return Path(os.environ.get("HERDR_PLUGIN_ROOT", Path(__file__).resolve().parent)) / "defaults" / "commands.json"


def command_config_path() -> Path:
    explicit = os.environ.get("HERDR_COMMAND_PALETTE_CONFIG")
    if explicit:
        return Path(explicit)

    user_config = user_config_path()
    legacy_plugin_config = plugin_config_path()
    if user_config.exists() or not legacy_plugin_config.exists():
        return user_config
    return legacy_plugin_config


def ensure_config() -> Path:
    path = command_config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        defaults = bundled_defaults_path()
        if defaults.exists():
            shutil.copyfile(defaults, path)
        else:
            path.write_text("[]\n")
    return path


def load_commands() -> tuple[Path, list[Command]]:
    path = ensure_config()
    data = json.loads(path.read_text())
    if not isinstance(data, list):
        raise ValueError(f"{path} must contain a JSON array")

    commands: list[Command] = []
    for index, item in enumerate(data):
        if not isinstance(item, dict):
            raise ValueError(f"command #{index + 1} must be an object")
        title = str(item.get("title") or "").strip()
        if not title:
            raise ValueError(f"command #{index + 1} is missing title")
        kind = str(item.get("type") or "").strip()
        if kind not in {"herdr", "pane_run", "tab_run", "shell", "overlay_shell", "plugin_action"}:
            raise ValueError(
                f"command '{title}' has unsupported type '{kind}'. "
                "Use herdr, pane_run, tab_run, shell, overlay_shell, or plugin_action."
            )
        group = str(item.get("group") or "Other").strip() or "Other"
        commands.append(
            Command(
                title=title,
                description=str(item.get("description") or "").strip(),
                kind=kind,
                group=group,
                raw=item,
            )
        )
    return path, commands


def fuzzy_score(query: str, text: str) -> float:
    query = query.strip().lower()
    if not query:
        return 1.0
    text = text.lower()
    text_index = 0
    score = 0.0
    streak = 0
    for char in query:
        found = text.find(char, text_index)
        if found == -1:
            return -1.0
        boundary = found == 0 or text[found - 1] in "/-_ .:"
        streak = streak + 1 if found == text_index else 1
        score += 10 + streak * 4 + (8 if boundary else 0) - min(found - text_index, 12)
        text_index = found + 1
    return score - min(len(text) / 50, 10)


def ranked(query: str, commands: list[Command], limit: int) -> list[Command]:
    if not query.strip():
        return commands[:limit]

    scored = [
        (fuzzy_score(query, command.search_text), command)
        for command in commands
    ]
    return [
        command
        for score, command in sorted(scored, key=lambda item: (-item[0], item[1].title.lower()))
        if score >= 0
    ][:limit]


def result_limit_for_rows(rows: int) -> int:
    return max(1, min(DEFAULT_LIMIT, rows - 10))


def visible_commands(query: str, commands: list[Command], rows: int) -> list[Command]:
    return ranked(query, commands, result_limit_for_rows(rows))


def group_count(commands: list[Command]) -> int:
    return len({command.group for command in commands})


def grouped_rows(commands: list[Command]) -> list[tuple[str, str, Command | None]]:
    rows: list[tuple[str, str, Command | None]] = []
    current_group = None
    for command in commands:
        if command.group != current_group:
            current_group = command.group
            rows.append(("header", current_group, None))
        rows.append(("command", "", command))
    return rows


def contains_target_pane_placeholder(value: Any) -> bool:
    if isinstance(value, str):
        return "{target_pane}" in value or "{target_pane_q}" in value
    if isinstance(value, list):
        return any(contains_target_pane_placeholder(item) for item in value)
    if isinstance(value, dict):
        return any(contains_target_pane_placeholder(item) for item in value.values())
    return False




def terminal_size() -> tuple[int, int]:
    size = os.get_terminal_size(sys.stdout.fileno())
    return size.columns, size.lines


def fit(text: str, width: int) -> str:
    if width <= 0:
        return ""
    text = text.replace("\n", " ")
    if len(text) <= width:
        return text
    if width == 1:
        return "…"
    return text[: width - 1] + "…"


def short_path(path: Path) -> str:
    text = str(path)
    home = str(Path.home())
    if text.startswith(home + os.sep):
        return "~" + text[len(home):]
    return text


def clear() -> None:
    sys.stdout.write("\x1b[2J\x1b[H")


def write_line(text: str = "", style: str = "") -> None:
    # tty.setraw disables ONLCR, so bare \n does not return to column 0.
    # Always emit CRLF or the palette draws diagonally across the overlay.
    sys.stdout.write(f"{style}{text}\x1b[K{ESC}0m\r\n")



def render(query: str, commands: list[Command], selected: int, config_path: Path, message: str = "") -> None:
    cols, rows = terminal_size()
    block_width = min(74, max(38, cols - 12))
    pad = max(0, (cols - block_width) // 2)
    max_results = result_limit_for_rows(rows)
    visible = visible_commands(query, commands, rows)
    selected = min(selected, max(0, len(visible) - 1))
    clear()

    def center(text: str = "", style: str = "") -> None:
        sys.stdout.write(" " * pad)
        write_line(fit(text, block_width), style)

    # Keep this intentionally plain. Herdr already provides the temporary
    # overlay pane; drawing another heavy window inside it looks bad.
    display_rows = grouped_rows(visible) if not query else [("command", "", command) for command in visible]
    content_height = 6 + (len(display_rows) if display_rows else 1) + (0 if message else 2)
    top_margin = max(1, min(rows // 4, (rows - content_height) // 2))
    for _ in range(top_margin):
        write_line()

    count = f"{len(visible)}/{len(commands)}" if query else f"{len(commands)} commands · {group_count(commands)} groups"
    title = "Command Palette"
    gap = max(2, block_width - len(title) - len(count))
    center(f"{title}{' ' * gap}{count}", f"{ESC}35m{ESC}1m")
    center("─" * min(block_width, 54), f"{ESC}2m")

    prompt = query if query else "type to search…"
    center(f"❯ {fit(prompt, block_width - 2)}", "" if query else f"{ESC}2m")
    center()

    if message:
        for line in message.strip().splitlines()[: max(1, rows - top_margin - 5)]:
            center(line)
        sys.stdout.flush()
        return

    if not visible:
        center("No matching commands", f"{ESC}2m")
    else:
        kind_width = 10
        group_width = 14
        title_width = max(12, block_width - kind_width - group_width - 6) if query else max(12, block_width - kind_width - 7)
        command_index = 0
        for row_kind, label, command in display_rows:
            if row_kind == "header":
                center(f"  {label}", f"{ESC}36m{ESC}1m")
                continue
            if command is None:
                continue
            active = command_index == selected
            marker = "›" if active else " "
            kind = command.kind.replace("_", "-")
            if query:
                row = (
                    f"{marker} {fit(command.title, title_width):<{title_width}} "
                    f"{fit(command.group, group_width):>{group_width}} "
                    f"{fit(kind, kind_width):>{kind_width}}"
                )
            else:
                row = f"  {marker} {fit(command.title, title_width):<{title_width}} {fit(kind, kind_width):>{kind_width}}"
            center(row, f"{ESC}35m{ESC}1m" if active else "")
            command_index += 1

    center()
    if visible:
        detail = visible[selected].description or visible[selected].kind
    else:
        detail = f"Edit {short_path(config_path)}"
    center(detail, f"{ESC}2m")
    center("Enter run · Esc quit · ↑/↓ or Tab move", f"{ESC}2m")
    sys.stdout.flush()

def read_key() -> str:
    stdin_fd = sys.stdin.fileno()
    data = os.read(stdin_fd, 1)
    if not data:
        return ""
    if data == b"\x1b":
        # Collect common escape sequences without blocking normal Esc. Herdr's
        # PTY can deliver arrow-key bytes slightly later than the leading ESC,
        # so give the first continuation byte a little more time than a local
        # terminal usually needs.
        parts = [data]
        timeout = 0.08
        while select.select([stdin_fd], [], [], timeout)[0]:
            parts.append(os.read(stdin_fd, 1))
            timeout = 0.01
            if len(parts) >= 32:
                break
        return b"".join(parts).decode("utf-8", "ignore")

    first = data[0]
    if first >= 0xC0:
        if first < 0xE0:
            expected = 2
        elif first < 0xF0:
            expected = 3
        elif first < 0xF8:
            expected = 4
        else:
            expected = 1
        while len(data) < expected:
            data += os.read(stdin_fd, 1)
    return data.decode("utf-8", "ignore")


def is_up_key(key: str) -> bool:
    return key in {"\x10", "\x1b[A", "\x1bOA", "\x1b[Z"} or (
        key.startswith("\x1b[") and key.endswith("A")
    )


def is_down_key(key: str) -> bool:
    return key in {"\x0e", "\x09", "\x1b[B", "\x1bOB"} or (
        key.startswith("\x1b[") and key.endswith("B")
    )


def json_result(command: list[str]) -> dict[str, Any]:
    result = subprocess.run(command, text=True, capture_output=True)
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


def target_pane_cwd(herdr: str, target_pane: str) -> str:
    if not target_pane:
        return ""

    pane_info = json_result([herdr, "pane", "get", target_pane])
    pane = pane_info.get("pane")
    if isinstance(pane, dict):
        for key in ("foreground_cwd", "cwd"):
            value = pane.get(key)
            if isinstance(value, str) and value:
                return value

    process_info = json_result([herdr, "pane", "process-info", "--pane", target_pane])
    info = process_info.get("process_info")
    if isinstance(info, dict):
        processes = info.get("foreground_processes")
        if isinstance(processes, list):
            for process in processes:
                if isinstance(process, dict):
                    value = process.get("cwd")
                    if isinstance(value, str) and value:
                        return value
    return ""


def context_vars(config_path: Path, herdr: str | None = None) -> dict[str, str]:
    config = str(config_path)
    config_directory = str(config_path.parent)
    plugin_root = os.environ.get("HERDR_PLUGIN_ROOT", "")
    state_dir = os.environ.get("HERDR_PLUGIN_STATE_DIR", "")
    target_pane = os.environ.get("HERDR_TARGET_PANE_ID", "")
    herdr_bin = herdr or os.environ.get("HERDR_BIN_PATH", "herdr")
    target_cwd = target_pane_cwd(herdr_bin, target_pane)
    return {
        "config_file": config,
        "config_file_q": shlex.quote(config),
        "config_dir": config_directory,
        "config_dir_q": shlex.quote(config_directory),
        "plugin_root": plugin_root,
        "plugin_root_q": shlex.quote(plugin_root),
        "state_dir": state_dir,
        "state_dir_q": shlex.quote(state_dir),
        "target_pane": target_pane,
        "target_pane_q": shlex.quote(target_pane),
        "target_cwd": target_cwd,
        "target_cwd_q": shlex.quote(target_cwd),
    }


def expand(value: Any, variables: dict[str, str]) -> Any:
    if isinstance(value, str):
        expanded = value
        for key, replacement in variables.items():
            expanded = expanded.replace("{" + key + "}", replacement)
        return expanded
    if isinstance(value, list):
        return [str(expand(item, variables)) for item in value]
    return value


def run_command(command: Command, config_path: Path) -> tuple[int, str, bool]:
    herdr = os.environ.get("HERDR_BIN_PATH", "herdr")
    variables = context_vars(config_path, herdr)
    raw = command.raw
    pause = bool(raw.get("pause", False))

    if command.kind == "herdr":
        raw_args = raw.get("args")
        if contains_target_pane_placeholder(raw_args) and not variables["target_pane"]:
            raise ValueError("No target pane found. Open the palette from an active Herdr pane.")
        args = expand(raw_args, variables)
        if not isinstance(args, list):
            raise ValueError(f"{command.title}: herdr commands require args array")
        result = subprocess.run([herdr, *args], text=True, capture_output=True)
        return result.returncode, (result.stdout or "") + (result.stderr or ""), pause

    if command.kind == "pane_run":
        target_pane = os.environ.get("HERDR_TARGET_PANE_ID")
        if not target_pane:
            raise ValueError("No target pane found. Open the palette from an active Herdr pane.")
        pane_command = expand(raw.get("command", ""), variables)
        if not pane_command:
            raise ValueError(f"{command.title}: pane_run requires command")
        result = subprocess.run([herdr, "pane", "run", target_pane, str(pane_command)], text=True, capture_output=True)
        return result.returncode, (result.stdout or "") + (result.stderr or ""), pause

    if command.kind == "tab_run":
        tab_command = expand(raw.get("command", ""), variables)
        if not tab_command:
            raise ValueError(f"{command.title}: tab_run requires command")
        label = expand(raw.get("label", command.title), variables)
        # Herdr restores focus to the pane that opened the overlay when the
        # plugin pane exits. Create the tab unfocused, start the command there,
        # then schedule a tiny delayed focus after the overlay closes.
        create = [herdr, "tab", "create", "--no-focus"]
        if variables["target_cwd"]:
            create.extend(["--cwd", variables["target_cwd"]])
        if label:
            create.extend(["--label", str(label)])
        result = subprocess.run(create, text=True, capture_output=True)
        output = (result.stdout or "") + (result.stderr or "")
        if result.returncode != 0:
            return result.returncode, output, True
        try:
            data = json.loads(result.stdout)
            created = data.get("result", {})
            root_pane = created.get("root_pane", {})
            tab = created.get("tab", {})
            pane_id = root_pane.get("pane_id")
            tab_id = tab.get("tab_id") or root_pane.get("tab_id")
        except (AttributeError, json.JSONDecodeError):
            pane_id = None
            tab_id = None
        if not pane_id:
            return 1, output + "\nCould not find root pane for created tab.", True
        run = subprocess.run([herdr, "pane", "run", str(pane_id), str(tab_command)], text=True, capture_output=True)
        if run.returncode == 0 and tab_id:
            delay = str(raw.get("focus_delay", 0.2))
            subprocess.Popen(
                [
                    "bash",
                    "-lc",
                    f"sleep {shlex.quote(delay)}; exec {shlex.quote(herdr)} tab focus {shlex.quote(str(tab_id))}",
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        return run.returncode, output + (run.stdout or "") + (run.stderr or ""), pause

    if command.kind == "plugin_action":
        action = expand(raw.get("action", ""), variables)
        if not action:
            raise ValueError(f"{command.title}: plugin_action requires action")
        invoke = [herdr, "plugin", "action", "invoke", str(action)]
        plugin = expand(raw.get("plugin", ""), variables)
        if plugin:
            invoke.extend(["--plugin", str(plugin)])
        result = subprocess.run(invoke, text=True, capture_output=True)
        return result.returncode, (result.stdout or "") + (result.stderr or ""), pause

    shell_command = expand(raw.get("command", ""), variables)
    if not shell_command:
        raise ValueError(f"{command.title}: shell command requires command")

    command_cwd = variables["target_cwd"] or None

    if command.kind == "overlay_shell":
        restore_terminal()
        try:
            if command_cwd:
                os.chdir(command_cwd)
            os.execlp("bash", "bash", "-lc", str(shell_command))
        except OSError as exc:
            print(f"failed to launch overlay shell command: {exc}", file=sys.stderr)
            raise SystemExit(1) from exc
        raise AssertionError("unreachable")

    shell_pause = bool(raw.get("pause", True))
    result = subprocess.run(["bash", "-lc", str(shell_command)], cwd=command_cwd, text=True, capture_output=True)
    return result.returncode, (result.stdout or "") + (result.stderr or ""), shell_pause


_original_termios: list[Any] | None = None


def setup_terminal() -> None:
    global _original_termios
    _original_termios = termios.tcgetattr(sys.stdin.fileno())
    sys.stdout.write("\x1b[?1049h\x1b[?25l")
    sys.stdout.flush()
    tty.setraw(sys.stdin.fileno())


def restore_terminal() -> None:
    if _original_termios is not None:
        termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, _original_termios)
    sys.stdout.write("\x1b[?25h\x1b[?1049l\x1b[0m")
    sys.stdout.flush()


def wait_for_key() -> None:
    read_key()


def main() -> int:
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise SystemExit("command palette needs a TTY")

    config_path, commands = load_commands()
    query = ""
    selected = 0
    try:
        setup_terminal()
        while True:
            visible = visible_commands(query, commands, terminal_size()[1])
            if selected >= len(visible):
                selected = max(0, len(visible) - 1)
            render(query, commands, selected, config_path)
            key = read_key()
            if key in {"\x03", "\x04", "\x1b"}:  # Ctrl-C, Ctrl-D, Esc
                return 0
            if key in {"\r", "\n"}:
                if not visible:
                    continue
                chosen = visible[selected]
                render(query, commands, selected, config_path, f"{ESC}33mRunning {chosen.title}…{ESC}0m")
                try:
                    code, output, pause = run_command(chosen, config_path)
                except Exception as exc:
                    code, output, pause = 1, str(exc), True
                if code != 0 or pause:
                    status = f"{ESC}31mfailed ({code}){ESC}0m" if code != 0 else f"{ESC}32mdone{ESC}0m"
                    message = f"{status}\n\n{output.strip()}\n\n{ESC}2mPress any key to close.{ESC}0m"
                    render(query, commands, selected, config_path, message)
                    wait_for_key()
                    return code
                return 0
            if key in {"\x7f", "\b"}:
                query = query[:-1]
                selected = 0
            elif key == "\x15":  # Ctrl-U
                query = ""
                selected = 0
            elif is_up_key(key):  # Up / Ctrl-P / Shift-Tab
                selected = max(0, selected - 1)
            elif is_down_key(key):  # Down / Ctrl-N / Tab
                selected += 1
            elif key == "\x1b[1;2A":
                selected = 0
            elif key and not key.startswith("\x1b") and key.isprintable():
                query += key
                selected = 0
    finally:
        restore_terminal()


if __name__ == "__main__":
    raise SystemExit(main())
