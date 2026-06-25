#!/usr/bin/env python3
"""Tiny dependency-free TUI command palette for Herdr.

Global commands are read from ~/.config/herdr/command-palette/commands.toml (or
HERDR_COMMAND_PALETTE_CONFIG) plus other root-level *.toml files. Project-local commands
are read from .herdr/command-palette/ under the pane's working directory. The
palette deliberately executes only commands from those trusted local files;
there is no runtime command registration or shell parsing for Herdr argv entries.
"""

from __future__ import annotations

import json
import locale
import os
import select
import shlex
import shutil
import subprocess
import sys
import termios
import tty
import ast
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import quote_plus

DEFAULT_LIMIT = 12
ESC = "\x1b["
RUNNABLE_KINDS = {"herdr", "pane_run", "tab_run", "workspace_picker", "shell", "overlay_shell", "plugin_action"}
COMMAND_KINDS = RUNNABLE_KINDS | {"select", "form"}

try:
    locale.setlocale(locale.LC_ALL, "")
except locale.Error:
    pass


@dataclass
class Command:
    title: str
    description: str
    kind: str
    group: str
    raw: dict[str, Any]
    origin: str = "Global"
    source: str = ""

    @property
    def search_text(self) -> str:
        return f"{self.origin} {self.group} {self.title} {self.description} {self.kind}"

    @property
    def display_group(self) -> str:
        return self.group


@dataclass
class Choice:
    label: str
    value: str
    description: str = ""
    heading: str = ""

    @property
    def selectable(self) -> bool:
        return bool(self.label)

    @property
    def search_text(self) -> str:
        return f"{self.label} {self.description} {self.value}"


def xdg_config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))


def user_config_path() -> Path:
    return xdg_config_home() / "herdr" / "command-palette" / "commands.toml"


def plugin_config_path() -> Path:
    return Path(
        os.environ.get(
            "HERDR_PLUGIN_CONFIG_DIR",
            xdg_config_home() / "herdr" / "plugins" / "command-palette-config",
        )
    ) / "commands.toml"


def bundled_defaults_path() -> Path:
    return Path(os.environ.get("HERDR_PLUGIN_ROOT", Path(__file__).resolve().parent)) / "defaults" / "commands.toml"


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
            path.write_text("\n")
    return path


def strip_toml_comment(line: str) -> str:
    in_single = False
    in_double = False
    escaped = False
    for index, char in enumerate(line):
        if char == "\\" and in_double and not escaped:
            escaped = True
            continue
        if char == "'" and not in_double:
            in_single = not in_single
        elif char == '"' and not in_single and not escaped:
            in_double = not in_double
        elif char == "#" and not in_single and not in_double:
            return line[:index]
        escaped = False
    return line


def parse_toml_value(value: str) -> Any:
    value = value.strip()
    if value in {"true", "false"}:
        return value == "true"
    if value.startswith(("'", '"', "[")):
        try:
            return ast.literal_eval(value)
        except (SyntaxError, ValueError):
            return value.strip('"').strip("'")
    try:
        return int(value)
    except ValueError:
        return value


def parse_toml_action(path: Path) -> dict[str, Any]:
    """Parse the small TOML subset command-palette action files use.

    Python's tomllib is only available on newer Python versions. Use it when it
    exists, then fall back to a deliberately tiny parser that supports the action
    shape we document: scalar keys, [form], and repeated [[options]] tables.
    """
    try:
        import tomllib  # type: ignore[import-not-found]

        with path.open("rb") as file:
            data = tomllib.load(file)
        return data if isinstance(data, dict) else {}
    except ModuleNotFoundError:
        pass

    data: dict[str, Any] = {}
    current_command: dict[str, Any] = data
    current: dict[str, Any] = current_command
    for raw_line in path.read_text().splitlines():
        line = strip_toml_comment(raw_line).strip()
        if not line:
            continue
        if line == "[[commands]]":
            command: dict[str, Any] = {}
            commands = data.setdefault("commands", [])
            if isinstance(commands, list):
                commands.append(command)
            current_command = command
            current = current_command
            continue
        if line in {"[[options]]", "[[commands.options]]"}:
            option: dict[str, Any] = {}
            options = current_command.setdefault("options", [])
            options.append(option)
            current = option
            continue
        if line in {"[form]", "[commands.form]"}:
            form: dict[str, Any] = {}
            current_command["form"] = form
            current = form
            continue
        if line in {"[run]", "[commands.run]"}:
            run: dict[str, Any] = {}
            current_command["run"] = run
            current = run
            continue
        if line.startswith("["):
            current = current_command
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        current[key.strip()] = parse_toml_value(value)
    return data


def load_command_data_file(path: Path) -> list[dict[str, Any]]:
    data = parse_toml_action(path)
    commands = data.get("commands")
    if isinstance(commands, list):
        return [command for command in commands if isinstance(command, dict)]
    if data:
        return [data]
    return []


def command_data_files(base_dir: Path, main_file: Path | None = None) -> list[Path]:
    files: list[Path] = []
    if main_file and main_file.exists():
        files.append(main_file)

    for path in sorted(base_dir.glob("*.toml")):
        if main_file and path == main_file:
            continue
        files.append(path)
    return files


def project_command_dir(cwd: str) -> Path | None:
    if not cwd:
        return None
    try:
        start = Path(cwd).expanduser().resolve()
    except OSError:
        return None
    for path in (start, *start.parents):
        candidate = path / ".herdr" / "command-palette"
        if candidate.is_dir():
            return candidate
    return None


def launch_cwd() -> str:
    return os.environ.get("HERDR_TARGET_CWD", "")


def command_kind(raw: dict[str, Any]) -> str:
    kind = str(raw.get("type") or "").strip()
    if not kind and raw.get("command"):
        return "shell"
    if kind == "command":
        return "shell"
    return kind


def validate_command_raw(raw: dict[str, Any], title: str, source: str) -> None:
    kind = command_kind(raw)
    if kind not in COMMAND_KINDS:
        raise ValueError(
            f"command '{title}' ({source}) has unsupported type '{kind}'. "
            "Use herdr, pane_run, tab_run, workspace_picker, shell, overlay_shell, plugin_action, select, or form."
        )
    if kind in {"select", "form"}:
        run = raw.get("run")
        if isinstance(run, dict):
            run_kind = command_kind(run) or "shell"
        else:
            run_kind = str(raw.get("run_type") or "shell").strip()
            if run_kind == "command":
                run_kind = "shell"
        if run_kind in {"select", "form"} or run_kind not in RUNNABLE_KINDS:
            raise ValueError(f"command '{title}' ({source}) has unsupported interactive run type '{run_kind}'")
        if kind == "select":
            options = raw.get("options")
            if not isinstance(options, list) or not any(isinstance(option, dict) and option.get("label") for option in options):
                raise ValueError(f"command '{title}' ({source}) select commands need at least one labeled option")


def command_from_raw(item: dict[str, Any], source: str, origin: str) -> Command:
    title = str(item.get("title") or item.get("name") or "").strip()
    if not title:
        raise ValueError(f"command in {source} is missing title")
    validate_command_raw(item, title, source)
    group = str(item.get("group") or "Other").strip() or "Other"
    return Command(
        title=title,
        description=str(item.get("description") or "").strip(),
        kind=command_kind(item),
        group=group,
        raw=item,
        origin=origin,
        source=source,
    )


def load_commands_from_dir(base_dir: Path, origin: str, main_file: Path | None = None) -> list[Command]:
    commands: list[Command] = []
    for path in command_data_files(base_dir, main_file):
        items = load_command_data_file(path)
        for index, item in enumerate(items):
            if not isinstance(item, dict):
                raise ValueError(f"command #{index + 1} in {path} must be an object")
            commands.append(command_from_raw(item, f"{path}#{index + 1}", origin))
    return commands


def validate_command_file(path: Path) -> int:
    items = load_command_data_file(path)
    if not items:
        raise ValueError(f"{path} does not define any commands")
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValueError(f"command #{index + 1} in {path} must be an object")
        command_from_raw(item, f"{path}#{index + 1}", "Validation")
    return len(items)


def validate_command_files(paths: list[Path]) -> list[tuple[Path, int]]:
    results: list[tuple[Path, int]] = []
    for path in paths:
        if not path.exists():
            raise ValueError(f"{path} does not exist")
        if not path.is_file():
            raise ValueError(f"{path} is not a file")
        results.append((path, validate_command_file(path)))
    return results


def validate_cli(args: list[str]) -> int:
    paths = [Path(arg).expanduser() for arg in args] if args else [bundled_defaults_path()]
    try:
        results = validate_command_files(paths)
    except Exception as exc:
        print(f"command palette config invalid: {exc}", file=sys.stderr)
        return 1
    for path, count in results:
        print(f"ok {path} ({count} command{'s' if count != 1 else ''})")
    return 0


def load_commands() -> tuple[Path, list[Command]]:
    path = ensure_config()
    commands: list[Command] = []
    project_dir = project_command_dir(launch_cwd())
    if project_dir:
        commands.extend(load_commands_from_dir(project_dir, "Project", project_dir / "commands.toml"))
    commands.extend(load_commands_from_dir(path.parent, "Global", path))
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
    include_origin = len({command.origin for command in commands}) > 1
    return len({display_group_label(command, include_origin) for command in commands})


def display_group_label(command: Command, include_origin: bool) -> str:
    return f"{command.origin} · {command.group}" if include_origin and command.origin else command.group


def grouped_rows(commands: list[Command]) -> list[tuple[str, str, Command | None]]:
    rows: list[tuple[str, str, Command | None]] = []
    current_group = None
    include_origin = len({command.origin for command in commands}) > 1
    for command in commands:
        label = display_group_label(command, include_origin)
        if label != current_group:
            current_group = label
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


def format_workspace_list(output: str) -> str:
    try:
        data = json.loads(output)
        workspaces = data.get("result", {}).get("workspaces", [])
    except (AttributeError, json.JSONDecodeError):
        return output
    if not isinstance(workspaces, list):
        return output
    if not workspaces:
        return "No workspaces"

    rows = []
    for workspace in workspaces:
        if not isinstance(workspace, dict):
            continue
        rows.append({
            "current": "*" if workspace.get("focused") else " ",
            "number": str(workspace.get("number", "?")),
            "label": str(workspace.get("label") or workspace.get("workspace_id") or "untitled"),
            "tabs": str(workspace.get("tab_count", 0)),
            "panes": str(workspace.get("pane_count", 0)),
            "status": str(workspace.get("agent_status") or "unknown"),
        })
    if not rows:
        return output

    number_width = max(len("#"), *(len(row["number"]) for row in rows))
    label_width = max(len("Workspace"), *(len(row["label"]) for row in rows))
    tabs_width = max(len("Tabs"), *(len(row["tabs"]) for row in rows))
    panes_width = max(len("Panes"), *(len(row["panes"]) for row in rows))

    lines = [
        f"  {'#':>{number_width}}  {'Workspace':<{label_width}}  {'Tabs':>{tabs_width}}  {'Panes':>{panes_width}}  Status"
    ]
    for row in rows:
        lines.append(
            f"{row['current']} {row['number']:>{number_width}}  "
            f"{row['label']:<{label_width}}  "
            f"{row['tabs']:>{tabs_width}}  "
            f"{row['panes']:>{panes_width}}  "
            f"{row['status']}"
        )
    return "\n".join(lines)


def format_output(raw: dict[str, Any], output: str) -> str:
    output_format = str(raw.get("format") or "").strip()
    if output_format == "workspace_list":
        return format_workspace_list(output)
    if output_format == "json":
        try:
            return json.dumps(json.loads(output), indent=2, ensure_ascii=False)
        except json.JSONDecodeError:
            return output
    return output




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


def key_bindings_config_path() -> Path:
    explicit = os.environ.get("HERDR_COMMAND_PALETTE_KEYBINDINGS_CONFIG")
    if explicit:
        return Path(explicit).expanduser()
    return xdg_config_home() / "ghostty" / "config"


def load_key_binding_groups() -> list[tuple[str, list[tuple[str, str]]]]:
    """Read palette keybinding hints from Ghostty config comments.

    Hints use a deliberately simple inline format on keybind lines:

        # palette: Group | Key label | Description

    If no hints are found, return an empty list. The palette then omits the
    right-hand keybinding panel instead of falling back to hardcoded data.
    """
    path = key_bindings_config_path()
    if not path.exists():
        return []

    groups: list[tuple[str, list[tuple[str, str]]]] = []
    group_index: dict[str, int] = {}
    seen: set[tuple[str, str, str]] = set()
    try:
        lines = path.read_text(errors="ignore").splitlines()
    except OSError:
        return []

    for line in lines:
        if "# palette:" not in line:
            continue
        hint = line.split("# palette:", 1)[1].strip()
        parts = [part.strip() for part in hint.split("|", 2)]
        if len(parts) != 3:
            continue
        group, key, description = parts
        if not group or not key or not description:
            continue
        marker = (group, key, description)
        if marker in seen:
            continue
        seen.add(marker)
        if group not in group_index:
            group_index[group] = len(groups)
            groups.append((group, []))
        groups[group_index[group]][1].append((key, description))
    return groups


def key_binding_rows(width: int, groups: list[tuple[str, list[tuple[str, str]]]]) -> list[str]:
    if width <= 0:
        return []
    key_width = min(12, max(8, width // 3))
    action_width = max(8, width - key_width - 3)
    rows = ["Key bindings", "─" * min(width, 24)]
    for group, bindings in groups:
        rows.append(group)
        for key, action in bindings:
            rows.append(f"  {fit(key, key_width):<{key_width}} {fit(action, action_width)}")
    return rows


def curses_palette_attrs() -> dict[str, int]:
    import curses

    attrs = {
        "normal": curses.A_NORMAL,
        "muted": curses.A_DIM,
        "accent": curses.A_BOLD,
        "header": curses.A_BOLD,
        "active": curses.A_BOLD,
    }
    if not curses.has_colors():
        return attrs
    try:
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_MAGENTA, -1)
        curses.init_pair(2, curses.COLOR_CYAN, -1)
        attrs["accent"] = curses.color_pair(1) | curses.A_BOLD
        attrs["active"] = curses.color_pair(1) | curses.A_BOLD
        attrs["header"] = curses.color_pair(2) | curses.A_BOLD
    except curses.error:
        pass
    return attrs


def curses_add(stdscr: Any, y: int, x: int, text: str = "", attr: int = 0) -> None:
    import curses

    rows, cols = stdscr.getmaxyx()
    if y < 0 or y >= rows or x >= cols:
        return
    x = max(0, x)
    available = max(0, cols - x - 1)
    if available <= 0:
        return
    try:
        stdscr.addstr(y, x, fit(text, available), attr)
    except curses.error:
        # Writing into the lower-right terminal cell raises on some curses
        # builds. Since every frame is redrawn, dropping that last cell is fine.
        pass


def curses_center(stdscr: Any, y: int, pad: int, width: int, text: str = "", attr: int = 0) -> None:
    curses_add(stdscr, y, pad, fit(text, width), attr)


def render_curses_palette(
    stdscr: Any,
    query: str,
    commands: list[Command],
    selected: int,
    config_path: Path,
    key_binding_groups: list[tuple[str, list[tuple[str, str]]]],
    attrs: dict[str, int],
) -> tuple[list[Command], int]:
    rows, cols = stdscr.getmaxyx()
    show_keybindings = cols >= 110 and bool(key_binding_groups)
    block_width = min(128 if show_keybindings else 74, max(38, cols - 12))
    column_separator = "  │ " if show_keybindings else ""
    right_width = 38 if show_keybindings else 0
    left_width = block_width - right_width - len(column_separator)
    pad = max(0, (cols - block_width) // 2)
    visible = visible_commands(query, commands, rows)
    selected = min(selected, max(0, len(visible) - 1))
    display_rows = grouped_rows(visible) if not query else [("command", "", command) for command in visible]
    bindings = key_binding_rows(right_width, key_binding_groups) if show_keybindings else []
    body_height = max(len(display_rows) if display_rows else 1, len(bindings) - 2 if bindings else 0)
    content_height = 6 + body_height + 2
    top_margin = max(1, min(rows // 4, (rows - content_height) // 2))

    stdscr.erase()

    def center_at(offset: int, text: str = "", attr: int = attrs["normal"]) -> None:
        curses_center(stdscr, top_margin + offset, pad, block_width, text, attr)

    def two_column_at(offset: int, left: str = "", right: str = "", attr: int = attrs["normal"]) -> None:
        if not show_keybindings:
            center_at(offset, left, attr)
            return
        line = f"{fit(left, left_width):<{left_width}}{column_separator}{fit(right, right_width):<{right_width}}"
        center_at(offset, line, attr)

    count = f"{len(visible)}/{len(commands)}" if query else f"{len(commands)} commands · {group_count(commands)} groups"
    title = "Command Palette"
    gap = max(2, block_width - len(title) - len(count))
    center_at(0, f"{title}{' ' * gap}{count}", attrs["accent"])
    center_at(1, "─" * min(block_width, 54), attrs["muted"])

    prompt = query if query else "type to search…"
    prompt_attr = attrs["normal"] if query else attrs["muted"]
    if show_keybindings:
        two_column_at(2, f"❯ {fit(prompt, left_width - 2)}", bindings[0] if bindings else "", prompt_attr)
        two_column_at(3, "", bindings[1] if len(bindings) > 1 else "", attrs["muted"])
    else:
        center_at(2, f"❯ {fit(prompt, block_width - 2)}", prompt_attr)
        center_at(3)

    body_top = 4
    if not visible:
        if show_keybindings:
            two_column_at(body_top, "No matching commands", bindings[2] if len(bindings) > 2 else "", attrs["muted"])
            for index in range(3, len(bindings)):
                two_column_at(body_top + index - 2, "", bindings[index])
        else:
            center_at(body_top, "No matching commands", attrs["muted"])
    else:
        kind_width = 10
        group_width = 14
        include_origin = len({command.origin for command in visible}) > 1
        title_width = max(12, left_width - kind_width - group_width - 6) if query else max(12, left_width - kind_width - 7)
        command_index = 0
        for row_index in range(max(len(display_rows), max(0, len(bindings) - 2))):
            y_offset = body_top + row_index
            right = bindings[row_index + 2] if row_index + 2 < len(bindings) else ""
            if row_index >= len(display_rows):
                two_column_at(y_offset, "", right)
                continue
            row_kind, label, command = display_rows[row_index]
            if row_kind == "header":
                two_column_at(y_offset, f"  {label}", right, attrs["header"])
                continue
            if command is None:
                continue
            active = command_index == selected
            marker = "›" if active else " "
            kind = command.kind.replace("_", "-")
            if query:
                row = (
                    f"{marker} {fit(command.title, title_width):<{title_width}} "
                    f"{fit(display_group_label(command, include_origin), group_width):>{group_width}} "
                    f"{fit(kind, kind_width):>{kind_width}}"
                )
            else:
                row = f"  {marker} {fit(command.title, title_width):<{title_width}} {fit(kind, kind_width):>{kind_width}}"
            two_column_at(y_offset, row, right, attrs["active"] if active else attrs["normal"])
            command_index += 1

    detail_y = min(rows - 3, top_margin + body_top + body_height + 1)
    if visible:
        detail = visible[selected].description or visible[selected].kind
    else:
        detail = f"Edit {short_path(config_path)}"
    curses_center(stdscr, detail_y, pad, block_width, detail, attrs["muted"])
    curses_center(stdscr, detail_y + 1, pad, block_width, "Enter run · Esc quit · ↑/↓ or Tab move", attrs["muted"])
    stdscr.refresh()
    return visible, selected


def command_palette_curses_loop(stdscr: Any, config_path: Path, commands: list[Command]) -> Command | None:
    import curses

    if hasattr(curses, "set_escdelay"):
        curses.set_escdelay(25)
    curses.cbreak()
    curses.noecho()
    stdscr.keypad(True)
    try:
        curses.curs_set(0)
    except curses.error:
        pass

    attrs = curses_palette_attrs()
    key_binding_groups = load_key_binding_groups()
    query = ""
    selected = 0

    while True:
        visible, selected = render_curses_palette(stdscr, query, commands, selected, config_path, key_binding_groups, attrs)
        try:
            key = stdscr.get_wch()
        except curses.error:
            continue

        if key in {"\x03", "\x04", "\x1b"}:  # Ctrl-C, Ctrl-D, Esc
            return None
        if key in {"\r", "\n"} or key == curses.KEY_ENTER:
            if visible:
                return visible[selected]
            continue
        if key in {"\x7f", "\b"} or key == curses.KEY_BACKSPACE:
            query = query[:-1]
            selected = 0
        elif key == "\x15":  # Ctrl-U
            query = ""
            selected = 0
        elif key in {"\x1b[1;2A"} or key in {curses.KEY_HOME, getattr(curses, "KEY_SR", -1)}:  # Shift-Up / Home
            selected = 0
        elif key in {"\x10"} or key in {curses.KEY_UP, curses.KEY_BTAB}:  # Ctrl-P / Up / Shift-Tab
            selected = max(0, selected - 1)
        elif key in {"\x0e", "\t"} or key == curses.KEY_DOWN:  # Ctrl-N / Down / Tab
            selected += 1
        elif key == curses.KEY_RESIZE:
            continue
        elif isinstance(key, str) and key and key.isprintable():
            query += key
            selected = 0


def pick_command_curses(config_path: Path, commands: list[Command]) -> Command | None:
    import curses

    return curses.wrapper(command_palette_curses_loop, config_path, commands)



def render_message(message: str) -> None:
    cols, rows = terminal_size()
    lines = message.strip().splitlines() or [""]
    block_width = min(74, max(38, cols - 12))
    pad = max(0, (cols - block_width) // 2)
    content_height = max(1, len(lines))
    top_margin = max(1, min(rows // 4, (rows - content_height) // 2))
    clear()

    for _ in range(top_margin):
        write_line()
    for line in lines[: max(1, rows - top_margin - 1)]:
        sys.stdout.write(" " * pad)
        write_line(fit(line, block_width))
    sys.stdout.flush()


def workspace_list(herdr: str) -> list[dict[str, Any]]:
    result = json_result([herdr, "workspace", "list"])
    workspaces = result.get("workspaces", [])
    return [workspace for workspace in workspaces if isinstance(workspace, dict)] if isinstance(workspaces, list) else []


def render_workspace_picker(workspaces: list[dict[str, Any]], selected: int) -> None:
    cols, rows = terminal_size()
    block_width = min(74, max(38, cols - 12))
    pad = max(0, (cols - block_width) // 2)
    selected = min(selected, max(0, len(workspaces) - 1))
    clear()

    def center(text: str = "", style: str = "") -> None:
        sys.stdout.write(" " * pad)
        write_line(fit(text, block_width), style)

    content_height = 7 + max(1, len(workspaces))
    top_margin = max(1, min(rows // 4, (rows - content_height) // 2))
    for _ in range(top_margin):
        write_line()

    title = "Switch Workspace"
    count = f"{len(workspaces)} workspaces"
    gap = max(2, block_width - len(title) - len(count))
    center(f"{title}{' ' * gap}{count}", f"{ESC}35m{ESC}1m")
    center("─" * min(block_width, 54), f"{ESC}2m")
    center("Choose a workspace…", f"{ESC}2m")
    center()

    if not workspaces:
        center("No workspaces", f"{ESC}2m")
    else:
        number_width = max(1, *(len(str(workspace.get("number", "?"))) for workspace in workspaces))
        label_width = max(12, block_width - number_width - 28)
        for index, workspace in enumerate(workspaces):
            active = index == selected
            marker = "›" if active else " "
            current = "*" if workspace.get("focused") else " "
            number = str(workspace.get("number", "?"))
            label = str(workspace.get("label") or workspace.get("workspace_id") or "untitled")
            tabs = workspace.get("tab_count", 0)
            panes = workspace.get("pane_count", 0)
            status = str(workspace.get("agent_status") or "unknown")
            row = (
                f"{marker} {current} {number:>{number_width}} "
                f"{fit(label, label_width):<{label_width}} "
                f"{tabs}t {panes}p {status}"
            )
            center(row, f"{ESC}35m{ESC}1m" if active else "")

    center()
    center("Enter switch · Esc cancel · ↑/↓ or Tab move", f"{ESC}2m")
    sys.stdout.flush()


def pick_workspace(herdr: str) -> tuple[int, str, bool]:
    workspaces = workspace_list(herdr)
    if not workspaces:
        return 1, "No workspaces found", True

    selected = next((index for index, workspace in enumerate(workspaces) if workspace.get("focused")), 0)
    while True:
        selected = max(0, min(selected, len(workspaces) - 1))
        render_workspace_picker(workspaces, selected)
        key = read_key()
        if key in {"\x03", "\x04", "\x1b"}:
            return 0, "", False
        if key in {"\r", "\n"}:
            workspace_id = workspaces[selected].get("workspace_id")
            if not workspace_id:
                return 1, "Selected workspace has no id", True
            subprocess.Popen(
                [
                    "bash",
                    "-lc",
                    f"sleep 0.2; exec {shlex.quote(herdr)} workspace focus {shlex.quote(str(workspace_id))}",
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return 0, "", False
        if is_up_key(key):
            selected -= 1
        elif is_down_key(key):
            selected += 1


def command_choices(command: Command) -> list[Choice]:
    options = command.raw.get("options")
    if not isinstance(options, list):
        return []
    choices: list[Choice] = []
    for option in options:
        if not isinstance(option, dict):
            continue
        label = str(option.get("label") or "")
        value = str(option.get("value") or label)
        choices.append(
            Choice(
                label=label,
                value=value,
                description=str(option.get("description") or ""),
                heading=str(option.get("heading") or ""),
            )
        )
    return choices


def visible_choices(query: str, choices: list[Choice], rows: int) -> list[Choice]:
    if not query.strip():
        return choices[: result_limit_for_rows(rows)]
    selectable = [choice for choice in choices if choice.selectable]
    scored = [(fuzzy_score(query, choice.search_text), choice) for choice in selectable]
    return [choice for score, choice in sorted(scored, key=lambda item: (-item[0], item[1].label.lower())) if score >= 0][
        : result_limit_for_rows(rows)
    ]


def selectable_index_at_or_after(choices: list[Choice], selected: int) -> int:
    if not choices:
        return 0
    selected = max(0, min(selected, len(choices) - 1))
    if choices[selected].selectable:
        return selected
    for index in range(selected + 1, len(choices)):
        if choices[index].selectable:
            return index
    for index in range(selected - 1, -1, -1):
        if choices[index].selectable:
            return index
    return selected


def move_choice(choices: list[Choice], selected: int, delta: int) -> int:
    index = selected + delta
    while 0 <= index < len(choices):
        if choices[index].selectable:
            return index
        index += delta
    return selected


def render_choice_picker(command: Command, query: str, choices: list[Choice], selected: int) -> None:
    cols, rows = terminal_size()
    block_width = min(74, max(38, cols - 12))
    pad = max(0, (cols - block_width) // 2)
    visible = visible_choices(query, choices, rows)
    selected = selectable_index_at_or_after(visible, selected)
    clear()

    def center(text: str = "", style: str = "") -> None:
        sys.stdout.write(" " * pad)
        write_line(fit(text, block_width), style)

    content_height = 7 + max(1, len(visible))
    top_margin = max(1, min(rows // 4, (rows - content_height) // 2))
    for _ in range(top_margin):
        write_line()

    count = f"{sum(1 for choice in visible if choice.selectable)}/{sum(1 for choice in choices if choice.selectable)}"
    gap = max(2, block_width - len(command.title) - len(count))
    center(f"{command.title}{' ' * gap}{count}", f"{ESC}35m{ESC}1m")
    center("─" * min(block_width, 54), f"{ESC}2m")
    prompt = query if query else "type to filter options…"
    center(f"❯ {fit(prompt, block_width - 2)}", "" if query else f"{ESC}2m")
    center()

    if not visible:
        center("No matching options", f"{ESC}2m")
    else:
        desc_width = 22
        label_width = max(12, block_width - desc_width - 5)
        for index, choice in enumerate(visible):
            if not choice.selectable:
                heading = choice.heading or choice.description
                if heading:
                    center(f"  {heading}", f"{ESC}36m{ESC}1m")
                else:
                    center()
                continue
            active = index == selected
            marker = "›" if active else " "
            row = f"{marker} {fit(choice.label, label_width):<{label_width}} {fit(choice.description, desc_width):>{desc_width}}"
            center(row, f"{ESC}35m{ESC}1m" if active else "")

    center()
    center("Enter select · Esc back · ↑/↓ or Tab move", f"{ESC}2m")
    sys.stdout.flush()


def pick_choice(command: Command) -> str | None:
    choices = command_choices(command)
    query = ""
    selected = selectable_index_at_or_after(choices, 0)
    while True:
        visible = visible_choices(query, choices, terminal_size()[1])
        selected = selectable_index_at_or_after(visible, selected)
        render_choice_picker(command, query, choices, selected)
        key = read_key()
        if key in {"\x03", "\x04"}:
            return None
        if key == "\x1b":
            return None
        if key in {"\r", "\n"}:
            if visible and visible[selected].selectable:
                return visible[selected].value
            continue
        if key in {"\x7f", "\b"}:
            query = query[:-1]
            selected = 0
        elif key == "\x15":
            query = ""
            selected = 0
        elif is_up_key(key):
            selected = move_choice(visible, selected, -1)
        elif is_down_key(key):
            selected = move_choice(visible, selected, 1)
        elif key and not key.startswith("\x1b") and key.isprintable():
            query += key
            selected = 0


def render_form(command: Command, value: str) -> None:
    cols, rows = terminal_size()
    block_width = min(74, max(38, cols - 12))
    pad = max(0, (cols - block_width) // 2)
    form = command.raw.get("form") if isinstance(command.raw.get("form"), dict) else {}
    prompt = str(form.get("prompt") or command.raw.get("prompt") or "Enter a value")
    placeholder = str(form.get("placeholder") or command.raw.get("placeholder") or "type a value…")
    clear()

    def center(text: str = "", style: str = "") -> None:
        sys.stdout.write(" " * pad)
        write_line(fit(text, block_width), style)

    top_margin = max(1, min(rows // 4, (rows - 8) // 2))
    for _ in range(top_margin):
        write_line()

    center(command.title, f"{ESC}35m{ESC}1m")
    center("─" * min(block_width, 54), f"{ESC}2m")
    center(prompt, f"{ESC}2m")
    center()
    shown = value if value else placeholder
    center(f"❯ {fit(shown, block_width - 2)}", "" if value else f"{ESC}2m")
    center()
    center("Enter submit · Esc back", f"{ESC}2m")
    sys.stdout.flush()


def read_form_value(command: Command) -> str | None:
    value = ""
    while True:
        render_form(command, value)
        key = read_key()
        if key in {"\x03", "\x04", "\x1b"}:
            return None
        if key in {"\r", "\n"}:
            return value.strip()
        if key in {"\x7f", "\b"}:
            value = value[:-1]
        elif key == "\x15":
            value = ""
        elif key and not key.startswith("\x1b") and key.isprintable():
            value += key


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
    target_cwd = os.environ.get("HERDR_TARGET_CWD") or target_pane_cwd(herdr_bin, target_pane)
    local_command_dir = project_command_dir(target_cwd)
    project_root = str(local_command_dir.parent.parent) if local_command_dir else ""
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
        "project_root": project_root,
        "project_root_q": shlex.quote(project_root),
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


def variables_with_value(variables: dict[str, str], value: str) -> dict[str, str]:
    updated = dict(variables)
    updated["value"] = value
    updated["value_q"] = shlex.quote(value)
    updated["value_url"] = quote_plus(value)
    return updated


def command_environment(variables: dict[str, str]) -> dict[str, str]:
    env = os.environ.copy()
    mapping = {
        "HERDR_COMMAND_PALETTE_CONFIG_FILE": "config_file",
        "HERDR_COMMAND_PALETTE_CONFIG_DIR": "config_dir",
        "HERDR_COMMAND_PALETTE_PLUGIN_ROOT": "plugin_root",
        "HERDR_COMMAND_PALETTE_STATE_DIR": "state_dir",
        "HERDR_COMMAND_PALETTE_TARGET_PANE": "target_pane",
        "HERDR_COMMAND_PALETTE_TARGET_CWD": "target_cwd",
        "HERDR_COMMAND_PALETTE_PROJECT_ROOT": "project_root",
        "HERDR_COMMAND_PALETTE_VALUE": "value",
    }
    for env_key, var_key in mapping.items():
        if var_key in variables:
            env[env_key] = variables[var_key]
    return env


def interactive_run_raw(command: Command) -> dict[str, Any]:
    run = command.raw.get("run")
    if isinstance(run, dict):
        merged = dict(run)
    else:
        merged = {key: value for key, value in command.raw.items() if key not in {"options", "form", "prompt", "placeholder"}}
        merged["type"] = command.raw.get("run_type") or "shell"
    merged.setdefault("title", command.title)
    merged.setdefault("description", command.description)
    merged.setdefault("group", command.group)
    return merged


def run_command(command: Command, config_path: Path) -> tuple[int, str, bool]:
    herdr = os.environ.get("HERDR_BIN_PATH", "herdr")
    variables = context_vars(config_path, herdr)
    raw = command.raw
    pause = bool(raw.get("pause", False))

    if command.kind == "select":
        value = pick_choice(command)
        if value is None:
            return 0, "", False
        child_raw = interactive_run_raw(command)
        child = Command(command.title, command.description, command_kind(child_raw), command.group, child_raw, command.origin, command.source)
        return run_command_with_variables(child, config_path, variables_with_value(variables, value), herdr)

    if command.kind == "form":
        value = read_form_value(command)
        if value is None:
            return 0, "", False
        child_raw = interactive_run_raw(command)
        child = Command(command.title, command.description, command_kind(child_raw), command.group, child_raw, command.origin, command.source)
        return run_command_with_variables(child, config_path, variables_with_value(variables, value), herdr)

    return run_command_with_variables(command, config_path, variables, herdr)


def run_command_with_variables(command: Command, config_path: Path, variables: dict[str, str], herdr: str) -> tuple[int, str, bool]:
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
        output = (result.stdout or "") + (result.stderr or "")
        return result.returncode, format_output(raw, output), pause

    if command.kind == "workspace_picker":
        return pick_workspace(herdr)

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

    raw_shell_command = raw.get("command", "")
    shell_command = expand(raw_shell_command, variables)
    if not shell_command:
        raise ValueError(f"{command.title}: shell command requires command")
    if variables.get("value") and "{value" not in str(raw_shell_command) and raw.get("append_value", True):
        shell_command = f"{shell_command} {shlex.quote(variables['value'])}"

    command_cwd = variables["target_cwd"] or None

    if command.kind == "overlay_shell":
        restore_terminal()
        try:
            if command_cwd:
                os.chdir(command_cwd)
            os.execlpe("bash", "bash", "-lc", str(shell_command), command_environment(variables))
        except OSError as exc:
            print(f"failed to launch overlay shell command: {exc}", file=sys.stderr)
            raise SystemExit(1) from exc
        raise AssertionError("unreachable")

    shell_pause = bool(raw.get("pause", True))
    result = subprocess.run(["bash", "-lc", str(shell_command)], cwd=command_cwd, env=command_environment(variables), text=True, capture_output=True)
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
    if len(sys.argv) > 1 and sys.argv[1] == "--validate":
        return validate_cli(sys.argv[2:])

    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise SystemExit("command palette needs a TTY")

    config_path, commands = load_commands()
    # The curses picker tears itself down (endwin) before we run anything: the
    # select/form/workspace sub-pickers still use raw-mode read_key + ANSI
    # rendering and cannot run inside an active curses session. Do not keep
    # curses alive across run_command — it will break interactive commands.
    chosen = pick_command_curses(config_path, commands)
    if chosen is None:
        return 0

    try:
        setup_terminal()
        render_message(f"{ESC}33mRunning {chosen.title}…{ESC}0m")
        try:
            code, output, pause = run_command(chosen, config_path)
        except Exception as exc:
            code, output, pause = 1, str(exc), True
        if code != 0 or pause:
            status = f"{ESC}31mfailed ({code}){ESC}0m" if code != 0 else f"{ESC}32mdone{ESC}0m"
            message = f"{status}\n\n{output.strip()}\n\n{ESC}2mPress any key to close.{ESC}0m"
            render_message(message)
            wait_for_key()
            return code
        return 0
    finally:
        restore_terminal()


if __name__ == "__main__":
    raise SystemExit(main())
