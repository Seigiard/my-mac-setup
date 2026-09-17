#!/usr/bin/env bash
# post-apply: 30 host-safe
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"
load 'helpers/common'

setup() {
  if [[ -z "${PALETTE_ROOT:-}" ]]; then
    local roots
    shopt -s nullglob
    roots=("$HOME"/.config/herdr/plugins/github/seigi.command-palette-*)
    shopt -u nullglob
    [[ ${#roots[@]} -eq 1 ]] || fail "expected one installed Command Palette, found ${#roots[@]}"
    PALETTE_ROOT="${roots[0]}"
  fi
  COMMANDS="${COMMANDS:-$HOME/.config/herdr/command-palette/commands.toml}"
  assert_file_exists "$PALETTE_ROOT/palette.py"
  assert_file_exists "$COMMANDS"
  PALETTE_WORK="$(mktemp -d "${BATS_TMPDIR:-/tmp}/palette-config.XXXXXX")"
}

teardown() {
  [[ -n "${PALETTE_WORK:-}" ]] && rm -rf "$PALETTE_WORK" || true
}

argv_logging_herdr_stub() {
  local fixture="$1"
  mkdir -p "$fixture/bin"
  cat > "$fixture/bin/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$fixture/herdr.log"
exit 0
SH
  chmod +x "$fixture/bin/herdr"
}

run_worktree_command() {
  local fixture="$1" title="$2" cwd="$3" value="$4"
  env PYTHONPATH="$PALETTE_ROOT" HERDR_BIN_PATH="$fixture/bin/herdr" \
    HERDR_TARGET_CWD="$cwd" HERDR_COMMAND_PALETTE_CONFIG="$COMMANDS" \
    PALETTE_COMMAND_TITLE="$title" PALETTE_COMMAND_VALUE="$value" python3 - <<'PY'
import os

import palette

herdr = os.environ["HERDR_BIN_PATH"]
config_path, commands = palette.load_commands()
command = next(c for c in commands if c.title == os.environ["PALETTE_COMMAND_TITLE"])
child_raw = palette.interactive_run_raw(command)
child = palette.Command(
    command.title,
    command.description,
    palette.command_kind(child_raw),
    command.group,
    child_raw,
    command.origin,
    command.source,
)
variables = palette.variables_with_value(
    palette.context_vars(config_path, herdr), os.environ["PALETTE_COMMAND_VALUE"]
)
code, output, _ = palette.run_command_with_variables(child, config_path, variables, herdr)
print(f"code={code}")
print(output)
PY
}

function test_palette_config_001_delete_checkout_requires_exact_confirmation() {
  _bats_test_init 1 'Delete worktree checkout requires exact DELETE confirmation'
  local fixture="$PALETTE_WORK/delete-confirmation"
  argv_logging_herdr_stub "$fixture"

  run env PYTHONPATH="$PALETTE_ROOT" HERDR_BIN_PATH="$fixture/bin/herdr" \
    HERDR_WORKSPACE_ID="w1" HERDR_TARGET_CWD="$fixture" \
    HERDR_COMMAND_PALETTE_CONFIG="$COMMANDS" python3 - <<'PY'
from pathlib import Path
import os

import palette

config_path, commands = palette.load_commands()
command = next(item for item in commands if item.title == "Delete worktree checkout")
raw = palette.interactive_run_raw(command)
child = palette.Command(
    command.title,
    command.description,
    palette.command_kind(raw),
    command.group,
    raw,
    command.origin,
    command.source,
)
variables = palette.context_vars(Path(config_path), os.environ["HERDR_BIN_PATH"])

rejected = palette.variables_with_value(variables, "delete")
status, output, _ = palette.run_command_with_variables(
    child, Path(config_path), rejected, os.environ["HERDR_BIN_PATH"]
)
assert status == 1, (status, output)
assert "not deleted" in output, output
assert not Path(os.environ["HERDR_BIN_PATH"]).parent.parent.joinpath("herdr.log").exists()

confirmed = palette.variables_with_value(variables, "DELETE")
status, output, _ = palette.run_command_with_variables(
    child, Path(config_path), confirmed, os.environ["HERDR_BIN_PATH"]
)
assert status == 0, (status, output)
PY
  assert_success

  run cat "$fixture/herdr.log"
  assert_success
  assert_output $'worktree\nremove\n--workspace\nw1'
}

function test_palette_config_002_worktree_commands_use_primary_checkout_and_quote_branch() {
  _bats_test_init 2 'worktree commands use the primary checkout and keep branch input inert'
  local fixture="$PALETTE_WORK/worktree source"
  local primary="$fixture/repo" linked="$fixture/linked"
  mkdir -p "$primary"
  run git init -q -b main "$primary"
  assert_success
  run git -C "$primary" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m init
  assert_success
  run git -C "$primary" worktree add -q -b fixture/linked "$linked"
  assert_success
  argv_logging_herdr_stub "$fixture"

  local expected branch title
  expected="$(git -C "$primary" worktree list --porcelain | head -n 1 | cut -d ' ' -f 2-)"
  branch="feat/a b; touch $PALETTE_WORK/PWNED-002 #"
  for title in "Open worktree" "New worktree"; do
    : > "$fixture/herdr.log"
    run run_worktree_command "$fixture" "$title" "$linked" "$branch"
    assert_success
    assert_line "code=0"

    run cat "$fixture/herdr.log"
    assert_success
    assert_line "--cwd"
    assert_line "$expected"
    assert_line "--branch"
    assert_line "$branch"
    [[ ! -e "$PALETTE_WORK/PWNED-002" ]] || fail "$title executed branch input"
  done
}

function test_palette_config_003_worktree_commands_refuse_non_repo_and_list_checkouts() {
  _bats_test_init 3 'worktree commands refuse non-repositories and list existing checkouts'
  local fixture="$PALETTE_WORK/worktree choices"
  local primary="$fixture/repo" linked="$fixture/linked" plain="$fixture/plain"
  mkdir -p "$primary" "$plain"
  run git init -q -b main "$primary"
  assert_success
  run git -C "$primary" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m init
  assert_success
  run git -C "$primary" worktree add -q -b fixture/linked "$linked"
  assert_success
  argv_logging_herdr_stub "$fixture"

  local title
  for title in "New worktree" "Open worktree"; do
    : > "$fixture/herdr.log"
    run run_worktree_command "$fixture" "$title" "$plain" "some/branch"
    assert_success
    assert_line "code=1"
    [[ ! -s "$fixture/herdr.log" ]] || fail "$title invoked herdr outside a repository"
  done

  run env PYTHONPATH="$PALETTE_ROOT" HERDR_TARGET_CWD="$linked" \
    HERDR_COMMAND_PALETTE_CONFIG="$COMMANDS" \
    EXPECTED_PRIMARY="$(git -C "$primary" rev-parse --show-toplevel)" \
    EXPECTED_LINKED="$(git -C "$linked" rev-parse --show-toplevel)" python3 - <<'PY'
import os

import palette

config_path, commands = palette.load_commands()
command = next(c for c in commands if c.title == "Open worktree")
choices = palette.command_choices(command, palette.context_vars(config_path))
actual = [(choice.value, choice.label, choice.description) for choice in choices]
expected = [
    ("main", "main", os.environ["EXPECTED_PRIMARY"]),
    ("fixture/linked", "fixture/linked", os.environ["EXPECTED_LINKED"]),
]
assert actual == expected, actual
PY
  assert_success
}

function test_palette_config_004_installed_package_keeps_consumed_plugin_contracts() {
  _bats_test_init 4 'installed package keeps the plugin IDs, helper, and immutable revision consumed here'
  local plugin_json registry_home="${HERDR_REGISTRY_HOME:-$HOME}"

  run env -i HOME="$registry_home" PATH="$PATH" \
    HERDR_SOCKET_PATH="/tmp/mms-herdr-plugin-contract-$$.sock" herdr plugin list --json
  assert_success
  plugin_json="$output"

  run env PLUGIN_JSON="$plugin_json" python3 - "$PALETTE_ROOT" <<'PY'
import json
import os
from pathlib import Path
import sys

expected_ref = "9c92d2d0b0d275183880c9033e73657e513d3da1"
plugins = json.loads(os.environ["PLUGIN_JSON"])["result"]["plugins"]
plugin = next(item for item in plugins if item.get("plugin_id") == "seigi.command-palette")
assert Path(plugin["plugin_root"]).resolve() == Path(sys.argv[1]).resolve(), plugin["plugin_root"]
assert plugin.get("source", {}).get("resolved_commit") == expected_ref, plugin.get("source")
assert {item["id"] for item in plugin.get("actions", [])} >= {"open", "smart_close"}, plugin
assert {item["id"] for item in plugin.get("panes", [])} >= {"palette", "lazygit"}, plugin
PY
  assert_success
  assert_file_exists "$PALETTE_ROOT/open_in_zed.py"
}

function test_palette_config_005_repository_scopes_use_package_filtering_and_project_root() {
  _bats_test_init 5 'repository scopes use the installed package filtering and project root'
  local matching="$PALETTE_WORK/matching" other="$PALETTE_WORK/other"
  mkdir -p "$matching/nested" "$other/nested"
  git -C "$matching" init -q -b main
  git -C "$matching" remote add origin git@github.com:Seigiard/my-mac-setup.git
  git -C "$other" init -q -b main
  git -C "$other" remote add origin https://github.com/example/other.git

  run env PYTHONPATH="$PALETTE_ROOT" HERDR_COMMAND_PALETTE_CONFIG="$COMMANDS" \
    MATCHING_CWD="$matching/nested" OTHER_CWD="$other/nested" python3 - <<'PY'
from pathlib import Path
import os

import palette

expected = {"Lint shell scripts", "Chezmoi diff", "Test templates"}

os.environ["HERDR_TARGET_CWD"] = os.environ["MATCHING_CWD"]
config_path, commands = palette.load_commands()
by_title = {command.title: command for command in commands}
assert expected <= by_title.keys(), by_title.keys()
assert all(by_title[title].origin == "Project" for title in expected)
variables = palette.context_vars(Path(config_path))
assert Path(variables["project_root"]).resolve() == Path(os.environ["MATCHING_CWD"]).parent.resolve()

os.environ["HERDR_TARGET_CWD"] = os.environ["OTHER_CWD"]
_, commands = palette.load_commands()
assert expected.isdisjoint(command.title for command in commands), [command.title for command in commands]
PY
  assert_success
}

function test_palette_config_006_kitty_hints_are_accepted_by_package_parser() {
  _bats_test_init 6 'kitty hint records are accepted by the installed package parser'
  is_macos || skip "Not on macOS"
  local config="$HOME/.config/kitty/herdr.conf"
  assert_file_exists "$config"

  run env PYTHONPATH="$PALETTE_ROOT" \
    HERDR_COMMAND_PALETTE_KEYBINDINGS_CONFIG="$config" python3 - <<'PY'
import palette

entries = {
    (group, key, description)
    for group, bindings in palette.load_key_binding_groups()
    for key, description in bindings
}
expected = {
    ("Panes", "⌘⇧P", "Command palette"),
    ("Panes", "⌘W", "Close pane/tab"),
    ("Tabs & workspaces", "⌃Tab", "Next tab"),
}
assert expected <= entries, entries
PY
  assert_success
}

function test_palette_config_007_fzf_meets_installed_package_version_floor() {
  _bats_test_init 7 'fzf meets the installed package version floor'
  run command -v fzf
  assert_success

  run env PYTHONPATH="$PALETTE_ROOT" python3 - <<'PY'
import shutil

import palette

fzf = shutil.which("fzf")
assert fzf, "fzf is not on PATH"
found = palette.fzf_version(fzf)
assert found is not None, f"{fzf} did not report a version"
assert found >= palette.FZF_MIN_VERSION, (found, palette.FZF_MIN_VERSION)
PY
  assert_success
}
