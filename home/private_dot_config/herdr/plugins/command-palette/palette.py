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

DEFAULT_LIMIT = 40
ESC = "\x1b["
RUNNABLE_KINDS = {"herdr", "pane_run", "tab_run", "workspace_picker", "shell", "overlay_shell", "plugin_action"}
COMMAND_KINDS = RUNNABLE_KINDS | {"select", "form"}

# fzf scores; the palette renders. 0.56 is the release that added --accept-nth,
# which is how a match finds its way back to a Command object.
FZF_MIN_VERSION = (0, 56)
# Measured at 3.0-3.2 ms median across 10/100/1000 rows on this machine: the
# cost is process spawn, not search, so it does not grow with the command list.
# Two seconds is ~600x that, unreachable by a slow machine and reached only by a
# hung binary.
FZF_TIMEOUT_SECONDS = 2
# A herdr CLI call goes over a local unix socket; anything slower than this is a
# stuck server, not a busy one.
HERDR_CALL_TIMEOUT_SECONDS = 2

# open.py stamps the palette's pane with this token so a second press of the
# keybinding finds the open palette instead of nesting a new one. Both values
# must match the ones in open.py.
PALETTE_PLUGIN_ID = "seigi.command-palette"
PALETTE_TOKEN = "command_palette"

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
    shortcuts: tuple[str, ...] = ()

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


SHELL_BEARING_KINDS = {"shell", "overlay_shell", "pane_run", "tab_run"}
BARE_VALUE_PLACEHOLDER = "{value}"


def forwards_to_shell(args: list[Any]) -> bool:
    """Does this herdr argv hand a command string to a shell on the far side?

    `herdr pane run <pane> <cmd>` does: Python never shell-parses the argv, but
    herdr runs the last argument in the pane's shell. So a bare {value} there
    reaches a shell just as surely as it does in a `shell` command.
    """
    return [str(item) for item in args[:2]] == ["pane", "run"]


def shell_bearing_strings(raw: dict[str, Any], kind: str) -> list[str]:
    """Every string in a command that a shell will parse."""
    values: list[str] = []
    if kind in SHELL_BEARING_KINDS:
        command = raw.get("command")
        if isinstance(command, str):
            values.append(command)
    if kind == "herdr":
        args = raw.get("args")
        if isinstance(args, list) and forwards_to_shell(args):
            values.extend(str(item) for item in args)
    return values


def interactive_child_raw(raw: dict[str, Any]) -> dict[str, Any]:
    """The nested command a select/form runs once it has a value."""
    run = raw.get("run")
    if isinstance(run, dict):
        return dict(run)
    child = {key: value for key, value in raw.items() if key not in {"options", "options_command", "form", "prompt", "placeholder"}}
    child["type"] = raw.get("run_type") or "shell"
    return child


def validate_value_quoting(raw: dict[str, Any], title: str, source: str, kind: str) -> None:
    """Refuse a form or select value interpolated into a shell string unquoted.

    Reproduced: a value of `a; touch /tmp/PWNED #` turns `echo {value}` into
    `echo a; touch /tmp/PWNED #`. `{value_q}` shell-quotes it and `{value_url}`
    percent-encodes it, so both stay inside their argument.
    """
    if kind in {"select", "form"}:
        child = interactive_child_raw(raw)
        targets = shell_bearing_strings(child, command_kind(child) or "shell")
    else:
        targets = shell_bearing_strings(raw, kind)

    for text in targets:
        if BARE_VALUE_PLACEHOLDER in text:
            raise ValueError(
                f"command '{title}' ({source}) interpolates a bare {BARE_VALUE_PLACEHOLDER} "
                "into a shell command. Use {value_q}: a value containing a space, a quote or a "
                "semicolon otherwise changes the command that runs."
            )


def validate_shortcuts(raw: dict[str, Any], title: str, source: str) -> tuple[str, ...]:
    """Read and check the optional per-command `shortcuts` list.

    A silently ignored shortcut is worse than a rejected one: the user's muscle
    memory stops working and nothing says why. So every malformed shape is an
    error at load time. Whitespace is banned because the query is never split,
    so a shortcut with a space could not be reached by prefix anyway.
    """
    value = raw.get("shortcuts")
    if value is None:
        return ()
    if not isinstance(value, list):
        raise ValueError(f"command '{title}' ({source}) shortcuts must be a list of strings")
    shortcuts: list[str] = []
    for entry in value:
        if not isinstance(entry, str):
            raise ValueError(f"command '{title}' ({source}) shortcut {entry!r} must be a string")
        if not entry.strip():
            raise ValueError(f"command '{title}' ({source}) has an empty shortcut")
        if any(char.isspace() for char in entry):
            raise ValueError(f"command '{title}' ({source}) shortcut '{entry}' must not contain whitespace")
        shortcuts.append(entry)
    return tuple(shortcuts)


def validate_command_raw(raw: dict[str, Any], title: str, source: str) -> tuple[str, tuple[str, ...]]:
    """Check a raw command and return the kind and shortcuts it resolved to."""
    shortcuts = validate_shortcuts(raw, title, source)
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
        if run_kind in {"select", "form", "workspace_picker"} or run_kind not in RUNNABLE_KINDS:
            raise ValueError(f"command '{title}' ({source}) has unsupported interactive run type '{run_kind}'")
        if kind == "select":
            options = raw.get("options")
            has_static = isinstance(options, list) and any(isinstance(option, dict) and option.get("label") for option in options)
            options_command = raw.get("options_command")
            has_dynamic = isinstance(options_command, str) and options_command.strip() != ""
            if not has_static and not has_dynamic:
                raise ValueError(
                    f"command '{title}' ({source}) select commands need at least one labeled option "
                    "or an options_command"
                )
    validate_value_quoting(raw, title, source, kind)
    return kind, shortcuts


def command_from_raw(item: dict[str, Any], source: str, origin: str) -> Command:
    title = str(item.get("title") or item.get("name") or "").strip()
    if not title:
        raise ValueError(f"command in {source} is missing title")
    kind, shortcuts = validate_command_raw(item, title, source)
    group = str(item.get("group") or "Other").strip() or "Other"
    return Command(
        title=title,
        description=str(item.get("description") or "").strip(),
        kind=kind,
        group=group,
        raw=item,
        origin=origin,
        source=source,
        shortcuts=shortcuts,
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
    paths = [Path(arg).expanduser() for arg in args] if args else [command_config_path()]
    try:
        results = validate_command_files(paths)
    except Exception as exc:
        print(f"command palette config invalid: {exc}", file=sys.stderr)
        return 1
    for path, count in results:
        print(f"ok {path} ({count} command{'s' if count != 1 else ''})")
    return 0


def normalize_group_order(commands: list[Command]) -> list[Command]:
    order: dict[tuple[str, str], int] = {}
    for command in commands:
        order.setdefault((command.origin, command.group), len(order))
    return sorted(commands, key=lambda command: order[(command.origin, command.group)])


def load_commands() -> tuple[Path, list[Command]]:
    path = ensure_config()
    commands: list[Command] = []
    project_dir = project_command_dir(launch_cwd())
    if project_dir:
        commands.extend(load_commands_from_dir(project_dir, "Project", project_dir / "commands.toml"))
    commands.extend(load_commands_from_dir(path.parent, "Global", path))
    return path, normalize_group_order(commands)


def fzf_requirement_message(reason: str) -> str:
    """The one place the missing/too-old fzf text lives.

    Both rendering paths in fail_hard_dependency read it, so they cannot drift,
    and tests/palette.bats pins the three facts that make the failure fixable:
    what is missing, where it is declared, and that PATH can hide it.
    """
    return "\n".join(
        [
            f"command palette cannot start: {reason}",
            "",
            "fzf is the palette's matcher and there is no fallback. A second,",
            "untested matcher would hide a broken deployment instead of showing it.",
            "",
            "fzf is declared in home/private_dot_config/brewfiles/Brewfile.tmpl",
            "in the dotfiles repo, which chezmoi renders and deploys to",
            "~/.config/brewfiles/Brewfile. To install it now:",
            "",
            "    brew bundle --file=~/.config/brewfiles/Brewfile",
            "",
            "If fzf is already installed, PATH is the problem: a bare",
            "/usr/bin:/bin PATH hides an fzf that lives in /opt/homebrew/bin.",
        ]
    )


def fail_hard_dependency(message: str) -> None:
    """Report a missing dependency where the user is actually looking.

    The palette runs in a popup pane opened by a keybinding. A process that
    writes to stderr and exits leaves a pane that flashes and vanishes, so the
    message is never read. On a TTY, draw it and wait for a key. Off a TTY --
    under bats, or piped -- print to stderr and exit, so no test can hang here.
    """
    if sys.stdin.isatty() and sys.stdout.isatty():
        try:
            setup_terminal()
            render_message(f"{ESC}31m{message}{ESC}0m\n\n{ESC}2mPress any key to close.{ESC}0m")
            wait_for_key()
        finally:
            restore_terminal()
    else:
        print(message, file=sys.stderr)
    raise SystemExit(1)


def fzf_version(fzf: str) -> tuple[int, int] | None:
    try:
        result = subprocess.run([fzf, "--version"], text=True, capture_output=True, timeout=FZF_TIMEOUT_SECONDS)
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    parts = (result.stdout or "").split()
    if not parts:
        return None
    numbers = parts[0].split(".")
    try:
        return int(numbers[0]), int(numbers[1])
    except (IndexError, ValueError):
        return None


_fzf_binary: str | None = None


def resolve_fzf() -> str:
    """Return the fzf path, or fail loudly. Resolved once per process."""
    global _fzf_binary
    if _fzf_binary is not None:
        return _fzf_binary

    fzf = shutil.which("fzf")
    if not fzf:
        fail_hard_dependency(fzf_requirement_message("fzf was not found on PATH."))
    version = fzf_version(fzf)
    if version is None:
        fail_hard_dependency(fzf_requirement_message(f"{fzf} did not report a version."))
    elif version < FZF_MIN_VERSION:
        fail_hard_dependency(
            fzf_requirement_message(
                f"fzf {version[0]}.{version[1]} at {fzf} is too old; "
                f"--accept-nth needs {FZF_MIN_VERSION[0]}.{FZF_MIN_VERSION[1]} or newer."
            )
        )
    _fzf_binary = fzf
    return fzf


_search_status = ""


def last_search_status() -> str:
    """The status line for the most recent search, empty when it went fine."""
    return _search_status


def sanitize_field(text: str) -> str:
    """Keep a value inside its own TSV column."""
    for char in ("\t", "\n", "\r"):
        text = text.replace(char, " ")
    return text


def fzf_filter(query: str, values: list[str], fzf: str) -> list[int] | None:
    """Rank `values` against `query`, best first, and return their indices.

    Rows are `<index>\\t<value>`; --nth 2 searches the value column only and
    --accept-nth {1} returns the index, so what is matched and what is returned
    stay independent of what is displayed. --delimiter is not optional: fzf's
    default is AWK whitespace, which would split a value with a space in it.
    -i is not optional either: fzf defaults to smart case, so an uppercase
    letter in the query would switch it to case-sensitive matching while the
    shortcut tier keeps case-folding, and `Git` would find nothing.

    None means the call produced no well-formed answer: it timed out, the binary
    would not run, or it exited with a code that is neither a match (0) nor a
    clean miss (1). The caller keeps the palette and the typed query alive
    rather than tearing both down over one bad call, and last_search_status()
    carries what went wrong. Nothing here raises into the curses loop -- an
    exception there ends as a traceback in a popup pane that no one can read.
    """
    global _search_status

    if not values:
        return []

    rows = "\n".join(f"{index}\t{sanitize_field(value)}" for index, value in enumerate(values))
    try:
        result = subprocess.run(
            [fzf, "--filter", query, "-i", "--delimiter", "\t", "--nth", "2", "--accept-nth", "{1}"],
            input=rows,
            text=True,
            capture_output=True,
            timeout=FZF_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        _search_status = f"fzf did not answer within {FZF_TIMEOUT_SECONDS}s — press a key to retry"
        return None
    except (OSError, subprocess.SubprocessError) as exc:
        _search_status = f"fzf could not run: {exc} — press a key to retry"
        return None

    # Exit 1 is "nothing matched" -- a legitimate result for a typo, not a
    # failure. Anything else means the binary is broken; say so and keep going.
    if result.returncode == 1:
        return []
    if result.returncode != 0:
        detail = (result.stderr or "").strip().splitlines()
        _search_status = f"fzf failed ({result.returncode}): {detail[0] if detail else 'no output'}"
        return None

    indices: list[int] = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.isdigit():
            indices.append(int(line))
    return indices


def shortcut_rank(query: str, command: Command) -> int | None:
    """0 for an exact shortcut, 1 for a prefix of one, None for no hit.

    Prefix, never fuzzy: the whole value of a shortcut is that `lg` means one
    command forever, and a fuzzy match would make that depend on what else
    happens to be in the list.
    """
    best: int | None = None
    for shortcut in command.shortcuts:
        folded = shortcut.casefold()
        if folded == query:
            return 0
        if folded.startswith(query):
            best = 1
    return best


def shortcut_matches(query: str, commands: list[Command]) -> list[Command]:
    hits = [
        (rank, order, command)
        for order, command in enumerate(commands)
        for rank in (shortcut_rank(query, command),)
        if rank is not None
    ]
    hits.sort(key=lambda item: (item[0], item[1]))
    return [command for _, _, command in hits]


def ranked(query: str, commands: list[Command], limit: int) -> list[Command]:
    """Two tiers: literal shortcuts in Python, then fuzzy titles in fzf.

    Neither the group nor the description is ever searched. Both were measured
    and both regress the acceptance queries -- the "Editor" group makes `edit`
    select "Open in Zed" -- and the shortcut tier covers what they were meant to.
    """
    global _search_status
    _search_status = ""

    folded = query.strip().casefold()
    if not folded:
        return commands[:limit]

    hits = shortcut_matches(folded, commands)
    matched = {id(command) for command in hits}
    remainder = [command for command in commands if id(command) not in matched]

    indices = fzf_filter(query.strip(), [command.title for command in remainder], resolve_fzf())
    if indices is None:
        # fzf_filter already set the status line. Keep whatever the shortcut
        # tier found -- it costs no subprocess and is still correct.
        return hits[:limit]

    hits.extend(remainder[index] for index in indices if 0 <= index < len(remainder))
    return hits[:limit]


def result_limit_for_rows(rows: int) -> int:
    return max(1, min(DEFAULT_LIMIT, rows - 10))


def visible_commands(query: str, commands: list[Command]) -> list[Command]:
    """Every match, in rank order.

    The main list scrolls, so the terminal height no longer decides which
    commands exist. Truncating by height was what made command 25 of 40
    unreachable by keyboard.
    """
    return ranked(query, commands, len(commands))


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


def command_row_indices(display_rows: list[tuple[str, str, Command | None]]) -> list[int]:
    """Display-row index of each command, skipping the group headers."""
    return [index for index, (row_kind, _, _) in enumerate(display_rows) if row_kind == "command"]


def palette_scroll_window(
    display_rows: list[tuple[str, str, Command | None]],
    selected: int,
    rows: int,
    top_margin: int,
    body_top: int,
) -> tuple[int, int]:
    """Window the main list on DISPLAY rows, not on commands.

    grouped_rows inserts a header per group, and counting only commands is what
    put the last row on the description line: 40 commands in 8 groups draw 48
    display rows, not 40.
    """
    command_rows = command_row_indices(display_rows)
    selected_row = command_rows[selected] if 0 <= selected < len(command_rows) else 0
    start, max_visible, _ = curses_scroll_window(rows, top_margin, body_top, len(display_rows), selected_row)
    return start, max_visible


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


def running_under_kitty() -> bool:
    """Detect kitty as the host terminal of this Herdr pane.

    Herdr panes inherit the environment of the terminal that started the
    Herdr server. kitty does not set TERM_PROGRAM, so it is recognised by
    the variables it does export into every child process.
    """
    return bool(os.environ.get("KITTY_WINDOW_ID") or os.environ.get("KITTY_PID"))


def key_bindings_config_paths() -> list[Path]:
    """Return the terminal config files that may carry palette hints.

    The host terminal's files come first, so its key labels win when both
    Ghostty and kitty are installed. kitty keeps its Herdr bindings in a
    separate included file, so both kitty files are listed.
    """
    explicit = os.environ.get("HERDR_COMMAND_PALETTE_KEYBINDINGS_CONFIG")
    if explicit:
        return [Path(explicit).expanduser()]

    config_home = xdg_config_home()
    ghostty = [config_home / "ghostty" / "config"]
    kitty = [
        config_home / "kitty" / "herdr.conf",
        config_home / "kitty" / "kitty.conf",
    ]
    if running_under_kitty():
        return kitty + ghostty
    return ghostty + kitty


def load_key_binding_groups() -> list[tuple[str, list[tuple[str, str]]]]:
    """Read palette keybinding hints from terminal config comments.

    Ghostty and kitty are both supported. Hints use a deliberately simple
    inline format on keybinding lines:

        # palette: Group | Key label | Description

    If no hints are found, return an empty list. The palette then omits the
    right-hand keybinding panel instead of falling back to hardcoded data.
    """
    groups: list[tuple[str, list[tuple[str, str]]]] = []
    group_index: dict[str, int] = {}
    seen: set[tuple[str, str, str]] = set()

    for path in key_bindings_config_paths():
        if not path.exists():
            continue
        try:
            lines = path.read_text(errors="ignore").splitlines()
        except OSError:
            continue

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


def key_binding_lines(width: int, groups: list[tuple[str, list[tuple[str, str]]]]) -> list[tuple[str, str]]:
    if width <= 0:
        return []
    key_width = min(12, max(8, width // 3))
    action_width = max(8, width - key_width - 3)
    lines: list[tuple[str, str]] = [("Key bindings", "accent"), ("", "normal")]
    for index, (group, bindings) in enumerate(groups):
        if index > 0:
            lines.append(("", "normal"))
        lines.append((group, "header"))
        for key, action in bindings:
            lines.append((f"  {fit(key, key_width):<{key_width}} {fit(action, action_width)}", "normal"))
    return lines


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


def init_curses_screen(stdscr: Any) -> None:
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


def curses_key_action(key: Any) -> str:
    import curses

    if key in {"\x03", "\x04", "\x1b"}:  # Ctrl-C, Ctrl-D, Esc
        return "cancel"
    if key in {"\r", "\n"} or key == curses.KEY_ENTER:
        return "enter"
    if key in {"\x7f", "\b"} or key == curses.KEY_BACKSPACE:
        return "backspace"
    if key == "\x15":  # Ctrl-U
        return "clear"
    if key in {"\x1b[1;2A"} or key in {curses.KEY_HOME, getattr(curses, "KEY_SR", -1)}:
        return "home"
    if key in {"\x10"} or key in {curses.KEY_UP, curses.KEY_BTAB}:  # Ctrl-P / Up / Shift-Tab
        return "up"
    if key in {"\x0e", "\t"} or key == curses.KEY_DOWN:  # Ctrl-N / Down / Tab
        return "down"
    if key == curses.KEY_RESIZE:
        return "resize"
    if isinstance(key, str) and key and key.isprintable():
        return "text"
    return ""


def curses_scroll_window(rows: int, top_margin: int, body_top: int, total: int, selected: int) -> tuple[int, int, int]:
    max_visible = max(1, rows - top_margin - body_top - 3)
    if total <= max_visible:
        start = 0
    else:
        half = max_visible // 2
        start = max(0, min(selected - half, total - max_visible))
    visible_count = max(1, min(total, max_visible))
    footer_y = min(rows - 2, top_margin + body_top + visible_count + 1)
    return start, max_visible, footer_y


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
    column_separator = "    "
    left_width = 57
    right_width = 38
    keybindings_block = left_width + len(column_separator) + right_width
    show_keybindings = cols >= keybindings_block and bool(key_binding_groups)
    if not show_keybindings:
        column_separator = ""
        right_width = 0
        left_width = min(74, max(38, cols - 4))
    block_width = left_width + len(column_separator) + right_width
    pad = max(0, (cols - block_width) // 2)
    visible = visible_commands(query, commands)
    selected = min(selected, max(0, len(visible) - 1))
    display_rows = grouped_rows(visible) if not query else [("command", "", command) for command in visible]
    kb_lines = key_binding_lines(right_width, key_binding_groups) if show_keybindings else []
    top_margin = 1
    body_top = 2
    start, max_visible = palette_scroll_window(display_rows, selected, rows, top_margin, body_top)

    stdscr.erase()

    def center_at(offset: int, text: str = "", attr: int = attrs["normal"]) -> None:
        curses_center(stdscr, top_margin + offset, pad, block_width, text, attr)

    def left_at(offset: int, text: str = "", attr: int = attrs["normal"]) -> None:
        width = left_width if show_keybindings else block_width
        curses_add(stdscr, top_margin + offset, pad, fit(text, width), attr)

    prompt = query if query else "type to search…"
    prompt_attr = attrs["normal"] if query else attrs["muted"]
    left_at(0, f"❯ {fit(prompt, left_width - 2)}", prompt_attr)

    if not visible:
        left_at(body_top, "No matching commands", attrs["muted"])
    else:
        group_width = 14
        include_origin = len({command.origin for command in visible}) > 1
        title_width = max(12, left_width - group_width - 3) if query else max(12, left_width - 4)
        command_index = sum(1 for row_kind, _, _ in display_rows[:start] if row_kind == "command")
        for row_index, (row_kind, label, command) in enumerate(display_rows[start : start + max_visible]):
            y_offset = body_top + row_index
            if row_kind == "header":
                left_at(y_offset, f"  {label}", attrs["header"])
                continue
            if command is None:
                continue
            active = command_index == selected
            marker = "›" if active else " "
            if query:
                row = (
                    f"{marker} {fit(command.title, title_width):<{title_width}} "
                    f"{fit(display_group_label(command, include_origin), group_width):>{group_width}}"
                )
            else:
                row = f"  {marker} {fit(command.title, title_width):<{title_width}}"
            left_at(y_offset, row, attrs["active"] if active else attrs["normal"])
            command_index += 1

    if show_keybindings:
        separator_x = pad + left_width + 2
        right_x = pad + left_width + len(column_separator)
        for y in range(top_margin, rows - 3):
            curses_add(stdscr, y, separator_x, "│", attrs["muted"])
        for index, (text, style) in enumerate(kb_lines):
            y = top_margin + index
            if y >= rows - 3:
                break
            if text:
                curses_add(stdscr, y, right_x, text, attrs[style])

    detail_y = rows - 3
    status = last_search_status()
    if status:
        detail = status
    elif visible:
        detail = visible[selected].description or visible[selected].kind
    else:
        detail = f"Edit {short_path(config_path)}"
    curses_center(stdscr, detail_y, pad, block_width, detail, attrs["muted"])
    curses_center(stdscr, detail_y + 1, pad, block_width, "Enter run · Esc quit · ↑/↓ or Tab move", attrs["muted"])
    stdscr.refresh()
    return visible, selected


def command_palette_curses_loop(stdscr: Any, config_path: Path, commands: list[Command]) -> Command | None:
    import curses

    init_curses_screen(stdscr)
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

        action = curses_key_action(key)
        if action == "cancel":
            return None
        if action == "enter":
            if visible:
                return visible[selected]
            continue
        if action == "backspace":
            query = query[:-1]
            selected = 0
        elif action == "clear":
            query = ""
            selected = 0
        elif action == "home":
            selected = 0
        elif action == "up":
            selected = max(0, selected - 1)
        elif action == "down":
            selected += 1
        elif action == "resize":
            continue
        elif action == "text" and isinstance(key, str):
            query += key
            selected = 0


def pick_command_curses(config_path: Path, commands: list[Command]) -> Command | None:
    import curses

    try:
        return curses.wrapper(command_palette_curses_loop, config_path, commands)
    except KeyboardInterrupt:
        return None



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


def render_curses_workspace_picker(stdscr: Any, workspaces: list[dict[str, Any]], selected: int, attrs: dict[str, int]) -> int:
    rows, cols = stdscr.getmaxyx()
    block_width = min(74, max(38, cols - 12))
    pad = max(0, (cols - block_width) // 2)
    selected = min(selected, max(0, len(workspaces) - 1))
    content_height = 7 + max(1, len(workspaces))
    top_margin = max(1, min(rows // 4, (rows - content_height) // 2))

    stdscr.erase()

    def center_at(offset: int, text: str = "", attr: int = attrs["normal"]) -> None:
        curses_center(stdscr, top_margin + offset, pad, block_width, text, attr)

    title = "Switch Workspace"
    count = f"{len(workspaces)} workspaces"
    gap = max(2, block_width - len(title) - len(count))
    center_at(0, f"{title}{' ' * gap}{count}", attrs["accent"])
    center_at(1, "─" * min(block_width, 54), attrs["muted"])
    center_at(2, "Choose a workspace…", attrs["muted"])
    center_at(3)

    body_top = 4
    if not workspaces:
        center_at(body_top, "No workspaces", attrs["muted"])
    else:
        number_width = max(1, *(len(str(workspace.get("number", "?"))) for workspace in workspaces))
        label_width = max(12, block_width - number_width - 28)
        start, max_visible, footer_y = curses_scroll_window(rows, top_margin, body_top, len(workspaces), selected)
        for row_index, workspace in enumerate(workspaces[start : start + max_visible]):
            index = start + row_index
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
            center_at(body_top + row_index, row, attrs["active"] if active else attrs["normal"])
    if not workspaces:
        _, _, footer_y = curses_scroll_window(rows, top_margin, body_top, 0, selected)
    curses_center(stdscr, footer_y, pad, block_width, "Enter switch · Esc cancel · ↑/↓ or Tab move", attrs["muted"])
    stdscr.refresh()
    return selected


def workspace_picker_curses_loop(stdscr: Any, workspaces: list[dict[str, Any]], selected: int) -> dict[str, Any] | None:
    import curses

    init_curses_screen(stdscr)
    attrs = curses_palette_attrs()
    while True:
        selected = render_curses_workspace_picker(stdscr, workspaces, selected, attrs)
        try:
            key = stdscr.get_wch()
        except curses.error:
            continue

        action = curses_key_action(key)
        if action == "cancel":
            return None
        if action == "enter":
            return workspaces[selected] if workspaces else None
        if action == "home":
            selected = 0
        elif action == "up":
            selected = max(0, selected - 1)
        elif action == "down":
            selected = min(len(workspaces) - 1, selected + 1)
        elif action == "resize":
            continue


def pick_workspace_curses(workspaces: list[dict[str, Any]], selected: int) -> dict[str, Any] | None:
    import curses

    try:
        return curses.wrapper(workspace_picker_curses_loop, workspaces, selected)
    except KeyboardInterrupt:
        return None


def pick_workspace(herdr: str) -> tuple[int, str, bool]:
    workspaces = workspace_list(herdr)
    if not workspaces:
        return 1, "No workspaces found", True

    selected = next((index for index, workspace in enumerate(workspaces) if workspace.get("focused")), 0)
    workspace = pick_workspace_curses(workspaces, selected)
    if workspace is None:
        return 0, "", False
    workspace_id = workspace.get("workspace_id")
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


OPTIONS_COMMAND_TIMEOUT = 10


def dynamic_choices(command: Command, variables: dict[str, str]) -> list[Choice]:
    """Run a select command's `options_command` and read its rows.

    The rows are tab-separated `value<TAB>label<TAB>description`; a row with no
    tab is its own label and value. A failing command raises instead of showing
    an empty list, because "no options" and "the lister is broken" are different
    problems and only one of them is the user's to fix.
    """
    options_command = command.raw.get("options_command")
    if not isinstance(options_command, str) or not options_command.strip():
        return []
    script = str(expand(options_command, variables))
    try:
        result = subprocess.run(
            script,
            shell=True,
            text=True,
            capture_output=True,
            env=command_environment(variables),
            cwd=variables.get("target_cwd") or None,
            timeout=OPTIONS_COMMAND_TIMEOUT,
        )
    except subprocess.TimeoutExpired as exc:
        raise ValueError(f"{command.title}: options_command timed out after {OPTIONS_COMMAND_TIMEOUT}s") from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise ValueError(f"{command.title}: options_command failed ({result.returncode}). {detail}".rstrip())

    choices: list[Choice] = []
    for line in (result.stdout or "").splitlines():
        if not line.strip():
            continue
        fields = line.split("\t")
        value = fields[0].strip()
        label = fields[1].strip() if len(fields) > 1 and fields[1].strip() else value
        description = fields[2].strip() if len(fields) > 2 else ""
        if not value:
            continue
        choices.append(Choice(label=label, value=value, description=description, heading=""))
    return choices


def command_choices(command: Command, variables: dict[str, str] | None = None) -> list[Choice]:
    options = command.raw.get("options")
    if not isinstance(options, list):
        return list(dynamic_choices(command, variables)) if variables is not None else []
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
    if variables is not None:
        choices.extend(dynamic_choices(command, variables))
    return choices


def visible_choices(query: str, choices: list[Choice], rows: int) -> list[Choice]:
    """Rank a select command's options through the same scorer as the main list.

    A Choice has no group and no shortcuts, so only the label is searched --
    the direct reading of the palette's "titles only" rule.
    """
    global _search_status
    _search_status = ""

    limit = result_limit_for_rows(rows)
    if not query.strip():
        return choices[:limit]

    selectable = [choice for choice in choices if choice.selectable]
    indices = fzf_filter(query.strip(), [choice.label for choice in selectable], resolve_fzf())
    if indices is None:
        # A search that never answered is not "nothing matched". Show the
        # unfiltered options and let last_search_status() say why, rather than
        # telling the user their query found nothing.
        return selectable[:limit]
    return [selectable[index] for index in indices if 0 <= index < len(selectable)][:limit]


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


def render_curses_choice_picker(
    stdscr: Any,
    command: Command,
    query: str,
    choices: list[Choice],
    selected: int,
    attrs: dict[str, int],
) -> tuple[list[Choice], int]:
    rows, cols = stdscr.getmaxyx()
    block_width = min(74, max(38, cols - 12))
    pad = max(0, (cols - block_width) // 2)
    visible = visible_choices(query, choices, rows)
    selected = selectable_index_at_or_after(visible, selected)
    content_height = 7 + max(1, len(visible))
    top_margin = max(1, min(rows // 4, (rows - content_height) // 2))

    stdscr.erase()

    def center_at(offset: int, text: str = "", attr: int = attrs["normal"]) -> None:
        curses_center(stdscr, top_margin + offset, pad, block_width, text, attr)

    count = f"{sum(1 for choice in visible if choice.selectable)}/{sum(1 for choice in choices if choice.selectable)}"
    gap = max(2, block_width - len(command.title) - len(count))
    center_at(0, f"{command.title}{' ' * gap}{count}", attrs["accent"])
    center_at(1, "─" * min(block_width, 54), attrs["muted"])
    prompt = query if query else "type to filter options…"
    center_at(2, f"❯ {fit(prompt, block_width - 2)}", attrs["normal"] if query else attrs["muted"])
    center_at(3)

    body_top = 4
    if not visible:
        center_at(body_top, "No matching options", attrs["muted"])
    else:
        desc_width = 22
        label_width = max(12, block_width - desc_width - 5)
        start, max_visible, footer_y = curses_scroll_window(rows, top_margin, body_top, len(visible), selected)
        for row_index, choice in enumerate(visible[start : start + max_visible]):
            index = start + row_index
            if not choice.selectable:
                heading = choice.heading or choice.description
                center_at(body_top + row_index, f"  {heading}" if heading else "", attrs["header"] if heading else attrs["normal"])
                continue
            active = index == selected
            marker = "›" if active else " "
            row = f"{marker} {fit(choice.label, label_width):<{label_width}} {fit(choice.description, desc_width):>{desc_width}}"
            center_at(body_top + row_index, row, attrs["active"] if active else attrs["normal"])
    if not visible:
        _, _, footer_y = curses_scroll_window(rows, top_margin, body_top, 0, selected)
    footer = last_search_status() or "Enter select · Esc back · ↑/↓ or Tab move"
    curses_center(stdscr, footer_y, pad, block_width, footer, attrs["muted"])
    stdscr.refresh()
    return visible, selected


def choice_picker_curses_loop(stdscr: Any, command: Command, choices: list[Choice]) -> str | None:
    import curses

    init_curses_screen(stdscr)
    attrs = curses_palette_attrs()
    query = ""
    selected = selectable_index_at_or_after(choices, 0)

    while True:
        visible, selected = render_curses_choice_picker(stdscr, command, query, choices, selected, attrs)
        try:
            key = stdscr.get_wch()
        except curses.error:
            continue

        action = curses_key_action(key)
        if action == "cancel":
            return None
        if action == "enter":
            if visible and visible[selected].selectable:
                return visible[selected].value
            continue
        if action == "backspace":
            query = query[:-1]
            selected = 0
        elif action == "clear":
            query = ""
            selected = 0
        elif action == "home":
            selected = selectable_index_at_or_after(visible, 0)
        elif action == "up":
            selected = move_choice(visible, selected, -1)
        elif action == "down":
            selected = move_choice(visible, selected, 1)
        elif action == "resize":
            continue
        elif action == "text" and isinstance(key, str):
            query += key
            selected = 0


def pick_choice(command: Command, variables: dict[str, str] | None = None) -> str | None:
    import curses

    choices = command_choices(command, variables)
    try:
        return curses.wrapper(choice_picker_curses_loop, command, choices)
    except KeyboardInterrupt:
        return None


def render_curses_form(stdscr: Any, command: Command, value: str, attrs: dict[str, int]) -> None:
    rows, cols = stdscr.getmaxyx()
    block_width = min(74, max(38, cols - 12))
    pad = max(0, (cols - block_width) // 2)
    form = command.raw.get("form") if isinstance(command.raw.get("form"), dict) else {}
    prompt = str(form.get("prompt") or command.raw.get("prompt") or "Enter a value")
    placeholder = str(form.get("placeholder") or command.raw.get("placeholder") or "type a value…")
    top_margin = max(1, min(rows // 4, (rows - 8) // 2))

    stdscr.erase()

    def center_at(offset: int, text: str = "", attr: int = attrs["normal"]) -> None:
        curses_center(stdscr, top_margin + offset, pad, block_width, text, attr)

    center_at(0, command.title, attrs["accent"])
    center_at(1, "─" * min(block_width, 54), attrs["muted"])
    center_at(2, prompt, attrs["muted"])
    center_at(3)
    shown = value if value else placeholder
    center_at(4, f"❯ {fit(shown, block_width - 2)}", attrs["normal"] if value else attrs["muted"])
    center_at(5)
    center_at(6, "Enter submit · Esc back", attrs["muted"])
    stdscr.refresh()


def form_curses_loop(stdscr: Any, command: Command) -> str | None:
    import curses

    init_curses_screen(stdscr)
    attrs = curses_palette_attrs()
    value = ""

    while True:
        render_curses_form(stdscr, command, value, attrs)
        try:
            key = stdscr.get_wch()
        except curses.error:
            continue

        action = curses_key_action(key)
        if action == "cancel":
            return None
        if action == "enter":
            return value.strip()
        if action == "backspace":
            value = value[:-1]
        elif action == "clear":
            value = ""
        elif action == "resize":
            continue
        elif action == "text" and isinstance(key, str):
            value += key


def read_form_value(command: Command) -> str | None:
    import curses

    try:
        return curses.wrapper(form_curses_loop, command)
    except KeyboardInterrupt:
        return None


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


def json_result(command: list[str], timeout: float | None = None) -> dict[str, Any]:
    """Run a herdr command and return its `result` object, or {} for anything else.

    The timeout is opt-in so the pre-existing untimed call sites keep their
    behaviour. A caller that must fail closed passes one: an empty dict is how
    "no well-formed answer" reaches it, and waiting forever never produces that.
    """
    try:
        result = subprocess.run(command, text=True, capture_output=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
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


def pane_agent(herdr: str, pane_id: str) -> str | None:
    """Who owns a pane: the agent's name, "" for nobody, None if unknown.

    None is deliberately not "nobody". A lookup that produced no well-formed
    answer is not evidence that the pane is free, and the caller must refuse
    rather than type a shell line into someone's agent on a guess. The timeout
    is part of that: a guard that waits forever on a stuck server has not
    failed closed, it has stopped.
    """
    pane = json_result([herdr, "pane", "get", pane_id], timeout=HERDR_CALL_TIMEOUT_SECONDS).get("pane")
    if not isinstance(pane, dict):
        return None
    agent = pane.get("agent")
    return agent.strip() if isinstance(agent, str) else ""


def refuse_if_agent_owns(herdr: str, pane_id: str, title: str) -> tuple[int, str, bool] | None:
    """Refuse to type into a pane an agent owns. None means it is safe to run.

    `herdr pane run <pane> <cmd>` types the line into the pane, and when an
    agent owns that pane herdr submits it as a prompt. Every command shape that
    reaches that call goes through here, not just kind == "pane_run".
    """
    if not pane_id:
        return None
    agent = pane_agent(herdr, pane_id)
    if agent is None:
        message = f"Could not read pane {pane_id}, so {title} was not run."
        notify(herdr, "Command palette: pane unreadable", message)
        return 1, message, True
    if agent:
        message = f"Pane {pane_id} is owned by the {agent} agent, so {title} was not run."
        notify(herdr, "Command palette: pane belongs to an agent", message)
        return 1, message, True
    return None


def clear_palette_token(herdr: str) -> None:
    """Drop the palette's pane token before this process is replaced.

    An overlay_shell command execs a shell over the palette, and the pane
    outlives the palette process. A token left behind makes the next press of
    the keybinding focus that shell instead of opening the palette.
    """
    pane_id = os.environ.get("HERDR_PANE_ID", "")
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
                os.environ.get("HERDR_PLUGIN_ID", PALETTE_PLUGIN_ID),
                "--clear-token",
                PALETTE_TOKEN,
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=HERDR_CALL_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        pass


def notify(herdr: str, title: str, body: str) -> None:
    """Best-effort user-visible notice. Never raises; never blocks the caller."""
    try:
        subprocess.run(
            [herdr, "notification", "show", title, "--body", body],
            check=False,
            capture_output=True,
            text=True,
            timeout=HERDR_CALL_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        pass


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
    merged = interactive_child_raw(command.raw)
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
        value = pick_choice(command, variables)
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
        # `herdr pane run <pane> <cmd>` reaches a pane's shell whichever command
        # kind spells it, so the agent guard follows the argv, not the kind.
        if forwards_to_shell(args):
            refusal = refuse_if_agent_owns(herdr, str(args[2]) if len(args) > 2 else "", command.title)
            if refusal:
                return refusal
        result = subprocess.run([herdr, *args], text=True, capture_output=True)
        output = (result.stdout or "") + (result.stderr or "")
        return result.returncode, format_output(raw, output), pause

    if command.kind == "workspace_picker":
        # Workspace picker opens its own short curses session and focuses the
        # selected workspace asynchronously. It intentionally ignores pause.
        return pick_workspace(herdr)

    if command.kind == "pane_run":
        target_pane = os.environ.get("HERDR_TARGET_PANE_ID")
        if not target_pane:
            raise ValueError("No target pane found. Open the palette from an active Herdr pane.")
        pane_command = expand(raw.get("command", ""), variables)
        if not pane_command:
            raise ValueError(f"{command.title}: pane_run requires command")

        refusal = refuse_if_agent_owns(herdr, target_pane, command.title)
        if refusal:
            return refusal

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
        clear_palette_token(herdr)
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
        # Validation reads config; it never searches. Keep it usable without fzf.
        return validate_cli(sys.argv[2:])

    # Before the TTY check, so a broken deployment is named rather than reported
    # as a missing terminal.
    resolve_fzf()

    # A command the validator rejects raises here, on every open -- not only
    # under --validate. Without this the message is a traceback in a popup pane
    # that flashes and vanishes, and the palette is how the user would edit the
    # offending file back. Like the fzf preflight, it runs before the TTY check
    # so the real problem is named instead of "needs a TTY".
    try:
        config_path, commands = load_commands()
    except ValueError as exc:
        fail_hard_dependency(f"command palette config is invalid: {exc}")
        raise AssertionError("unreachable") from exc

    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise SystemExit("command palette needs a TTY")

    # The main curses picker tears itself down (endwin) before we run anything.
    # Interactive sub-pickers open their own short curses sessions; post-run
    # output screens still use legacy raw ANSI rendering. Do not keep curses
    # alive across run_command — it will break interactive commands.
    chosen = pick_command_curses(config_path, commands)
    if chosen is None:
        return 0

    if chosen.kind in {"select", "form", "workspace_picker"}:
        # Interactive sub-pickers are curses-based. Run them directly after the
        # main curses picker has ended instead of entering the legacy raw ANSI
        # mode used by post-run output screens.
        try:
            code, output, pause = run_command(chosen, config_path)
        except Exception as exc:
            code, output, pause = 1, str(exc), True
        if code != 0 or pause:
            try:
                setup_terminal()
                status = f"{ESC}31mfailed ({code}){ESC}0m" if code != 0 else f"{ESC}32mdone{ESC}0m"
                message = f"{status}\n\n{output.strip()}\n\n{ESC}2mPress any key to close.{ESC}0m"
                render_message(message)
                wait_for_key()
            finally:
                restore_terminal()
        return code

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
