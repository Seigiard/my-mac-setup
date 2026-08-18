#!/usr/bin/env bats
#
# Behaviour tests for the herdr command palette, run against the chezmoi SOURCE
# tree. tests/smoke.bats also exercises the palette, but from the applied copy
# under $HOME -- which is stale until `chezmoi apply`, a command this repo
# forbids on the host. These tests read $SOURCE_ROOT instead, so they gate an
# uncommitted edit in a bare checkout.

load 'helpers/common'

PALETTE_DIR="$SOURCE_ROOT/private_dot_config/herdr/plugins/command-palette"
REAL_COMMANDS="$SOURCE_ROOT/private_dot_config/herdr/command-palette/commands.toml"

setup() {
  command_exists python3 || skip "python3 not installed"
  export PALETTE_PY="$PALETTE_DIR/palette.py"
  export PALETTE_OPEN_PY="$PALETTE_DIR/open.py"
  export PYTHONPATH="$BATS_TEST_DIRNAME/helpers${PYTHONPATH:+:$PYTHONPATH}"
  PALETTE_WORK="$(mktemp -d "${BATS_TMPDIR:-/tmp}/palette.XXXXXX")"
}

teardown() {
  [[ -n "${PALETTE_WORK:-}" ]] && rm -rf "$PALETTE_WORK" || true
}

# Run a python snippet (read from stdin) with the palette modules importable.
palette_py() {
  local script="$PALETTE_WORK/snippet.py"
  cat > "$script"
  python3 "$script"
}

# ===========================================
# U1 -- the source-tree seam itself
# ===========================================

@test "palette sources under SOURCE_ROOT compile" {
  run python3 -m py_compile \
    "$PALETTE_DIR/palette.py" \
    "$PALETTE_DIR/open.py" \
    "$PALETTE_DIR/smart_close.py"
  assert_success
}

@test "--validate accepts the real commands.toml and names the command count" {
  run python3 "$PALETTE_DIR/palette.py" --validate "$REAL_COMMANDS"
  assert_success
  assert_output --partial "commands)"
}

@test "--validate rejects an unsupported command type" {
  cat > "$PALETTE_WORK/bad.toml" <<'TOML'
name = "Broken"
type = "not_a_type"
command = "echo broken"
TOML

  run python3 "$PALETTE_DIR/palette.py" --validate "$PALETTE_WORK/bad.toml"
  assert_failure
  assert_output --partial "unsupported type"
}

@test "load_commands reads a fixture config from the source tree" {
  cat > "$PALETTE_WORK/commands.toml" <<'TOML'
[[commands]]
group = "Fixture"
title = "Only command"
type = "shell"
command = "true"
TOML

  run env HERDR_COMMAND_PALETTE_CONFIG="$PALETTE_WORK/commands.toml" python3 - <<'PY'
import palette_boot

palette = palette_boot.palette()
config_path, commands = palette.load_commands()
assert config_path.name == "commands.toml", config_path
assert [command.title for command in commands] == ["Only command"], commands
PY
  assert_success
}

# ===========================================
# U3 -- ranking: a literal shortcut tier, then fzf over titles
# ===========================================

# Print the ranked titles for a query against a config, one per line.
rank_in() {
  local config="$1" query="$2"
  env HERDR_COMMAND_PALETTE_CONFIG="$config" python3 - "$query" <<'PY'
import sys

import palette_boot

palette = palette_boot.palette()
_, commands = palette.load_commands()
for command in palette.ranked(sys.argv[1], commands, palette.DEFAULT_LIMIT):
    print(command.title)
PY
}

rank_real() {
  rank_in "$REAL_COMMANDS" "$1"
}

@test "R1: lg ranks Lazygit in popup first" {
  run rank_real lg
  assert_success
  assert_line --index 0 "Lazygit in popup"
}

@test "R1: ws ranks Switch workspace first" {
  run rank_real ws
  assert_success
  assert_line --index 0 "Switch workspace"
}

@test "R1: edit ranks Edit command palette config first" {
  run rank_real edit
  assert_success
  assert_line --index 0 "Edit command palette config"
}

@test "R1: zed ranks Open in Zed first, and returns only it" {
  run rank_real zed
  assert_success
  assert_line --index 0 "Open in Zed"
  assert_equal "${#lines[@]}" 1
}

@test "R1: main ranks Merge main branch first" {
  run rank_real main
  assert_success
  assert_line --index 0 "Merge main branch"
}

@test "R1: lazy ranks Lazygit in popup first" {
  run rank_real lazy
  assert_success
  assert_line --index 0 "Lazygit in popup"
}

@test "R10: the Cyrillic shortcuts rank their command first" {
  run rank_real "дп"
  assert_success
  assert_line --index 0 "Lazygit in popup"
  # No title contains Cyrillic, so the fzf tier adds nothing.
  assert_equal "${#lines[@]}" 1

  run rank_real "дфян"
  assert_success
  assert_line --index 0 "Lazygit in popup"

  run rank_real "цы"
  assert_success
  assert_line --index 0 "Switch workspace"

  run rank_real "яув"
  assert_success
  assert_line --index 0 "Open in Zed"

  run rank_real "увше"
  assert_success
  assert_line --index 0 "Edit command palette config"
}

@test "R10: a half-typed shortcut still matches by prefix" {
  run rank_real "дфя"
  assert_success
  assert_line --index 0 "Lazygit in popup"
}

@test "R10: shortcut matching is case-insensitive" {
  run rank_real "LG"
  assert_success
  assert_line --index 0 "Lazygit in popup"
}

@test "R10: a decoy title cannot displace a shortcut hit" {
  cp "$REAL_COMMANDS" "$PALETTE_WORK/commands.toml"
  cat >> "$PALETTE_WORK/commands.toml" <<'TOML'

[[commands]]
group = "Decoy"
title = "LG something"
type = "shell"
command = "true"
TOML

  run rank_in "$PALETTE_WORK/commands.toml" lg
  assert_success
  assert_line --index 0 "Lazygit in popup"
}

@test "R2: a query matching no title and no shortcut returns nothing" {
  run rank_real "qqzzxx"
  assert_success
  assert_output ""
}

@test "R2: an empty query returns every command in group order" {
  run rank_real ""
  assert_success
  assert_line --index 0 "Lazygit in new tab"
  assert_equal "${#lines[@]}" 10
}

@test "a command with no shortcuts still matches by title" {
  cat > "$PALETTE_WORK/commands.toml" <<'TOML'
[[commands]]
group = "Fixture"
title = "Deploy the widget"
type = "shell"
command = "true"
TOML

  run rank_in "$PALETTE_WORK/commands.toml" widget
  assert_success
  assert_line --index 0 "Deploy the widget"
}

@test "a title containing a tab does not corrupt the index mapping" {
  cat > "$PALETTE_WORK/commands.toml" <<'TOML'
[[commands]]
group = "Fixture"
title = "First command"
type = "shell"
command = "true"

[[commands]]
group = "Fixture"
title = "Tabbed\tcommand"
type = "shell"
command = "true"
TOML

  run rank_in "$PALETTE_WORK/commands.toml" Tabbed
  assert_success
  assert_equal "${#lines[@]}" 1
  assert_output --partial "Tabbed"
}

@test "--validate rejects a malformed shortcuts value" {
  local bad
  for bad in 'shortcuts = "lg"' 'shortcuts = ["lg", 7]' 'shortcuts = [""]' 'shortcuts = ["l g"]'; do
    cat > "$PALETTE_WORK/bad.toml" <<TOML
[[commands]]
title = "Broken shortcut"
type = "shell"
command = "true"
$bad
TOML

    run python3 "$PALETTE_DIR/palette.py" --validate "$PALETTE_WORK/bad.toml"
    assert_failure
    assert_output --partial "Broken shortcut"
    assert_output --partial "shortcut"
  done
}

# Ubuntu CI runs python 3.10, where tomllib does not exist and palette.py falls
# back to its own tiny TOML parser. A shortcuts list must survive that path too.
@test "the fallback TOML parser reads a shortcuts array" {
  run python3 - "$REAL_COMMANDS" <<'PY'
import builtins
import pathlib
import sys

real_import = builtins.__import__


def without_tomllib(name, *args, **kwargs):
    if name == "tomllib":
        raise ModuleNotFoundError(name)
    return real_import(name, *args, **kwargs)


builtins.__import__ = without_tomllib

import palette_boot

palette = palette_boot.palette()
items = palette.load_command_data_file(pathlib.Path(sys.argv[1]))
by_title = {item.get("title"): item for item in items}
assert by_title["Lazygit in popup"]["shortcuts"] == ["lg", "дп", "дфян"], by_title["Lazygit in popup"]
PY
  assert_success
}

@test "select options rank through the same scorer" {
  run python3 - <<'PY'
import palette_boot

palette = palette_boot.palette()
choices = [
    palette.Choice(label="Production", value="prod"),
    palette.Choice(label="Staging", value="stage"),
]
visible = palette.visible_choices("stag", choices, 40)
assert [choice.label for choice in visible] == ["Staging"], visible
PY
  assert_success
}

# ===========================================
# U4 -- the main command list scrolls
# ===========================================

# 40 commands in 8 groups at the real popup height of 34 rows. The old list
# truncated to 24 commands and drew its last row onto the description line.
scroll_fixture() {
  python3 - <<'PY'
import palette_boot

palette = palette_boot.palette()
commands = [
    palette.Command(
        title=f"Command {index:02d}",
        description="",
        kind="shell",
        group=f"Group {index // 5}",
        raw={"type": "shell", "command": "true"},
    )
    for index in range(40)
]
rows, top_margin, body_top = 34, 1, 2

visible = palette.visible_commands("", commands)
print("visible", len(visible))

display_rows = palette.grouped_rows(visible)
print("display_rows", len(display_rows))

command_rows = palette.command_row_indices(display_rows)
reachable = 0
lowest_drawn = 0
for selected in range(len(visible)):
    start, max_visible = palette.palette_scroll_window(display_rows, selected, rows, top_margin, body_top)
    if start <= command_rows[selected] < start + max_visible:
        reachable += 1
    lowest_drawn = max(lowest_drawn, top_margin + body_top + min(max_visible, len(display_rows) - start) - 1)
print("reachable", reachable)
print("lowest_drawn", lowest_drawn)
print("detail_y", rows - 3)

ten = commands[:10]
ten_rows = palette.grouped_rows(palette.visible_commands("", ten))
start, max_visible = palette.palette_scroll_window(ten_rows, 0, rows, top_margin, body_top)
print("ten_start", start)
print("ten_fits", int(max_visible >= len(ten_rows)))

flat = [palette.Command(title=f"Flat {i}", description="", kind="shell", group="One", raw={"type": "shell", "command": "true"}) for i in range(40)]
flat_rows = palette.grouped_rows(flat)
start, max_visible = palette.palette_scroll_window(flat_rows, 39, rows, top_margin, body_top)
print("flat_last_visible", int(start <= 40 < start + max_visible))
PY
}

@test "R3: every command is reachable at 40 commands in 8 groups" {
  run scroll_fixture
  assert_success
  assert_line "visible 40"
  assert_line "reachable 40"
}

@test "R3: the last drawn row never reaches the description line" {
  run scroll_fixture
  assert_success
  local lowest detail
  lowest="$(printf '%s\n' "$output" | awk '/^lowest_drawn /{print $2}')"
  detail="$(printf '%s\n' "$output" | awk '/^detail_y /{print $2}')"
  [ "$lowest" -lt "$detail" ]
}

@test "R3: ten commands still render unscrolled" {
  run scroll_fixture
  assert_success
  assert_line "ten_start 0"
  assert_line "ten_fits 1"
}

@test "R3: a single group with no extra headers still scrolls" {
  run scroll_fixture
  assert_success
  assert_line "flat_last_visible 1"
}

@test "R9: a missing fzf fails loudly, naming fzf, the Brewfile and PATH" {
  local stub="$PALETTE_WORK/nofzf"
  mkdir -p "$stub"
  local tool src
  for tool in python3 bash sh env; do
    src="$(command -v "$tool")" && ln -sf "$src" "$stub/$tool"
  done
  run env -i PATH="$stub:/usr/bin:/bin" HOME="$PALETTE_WORK" \
    HERDR_COMMAND_PALETTE_CONFIG="$REAL_COMMANDS" \
    python3 "$PALETTE_DIR/palette.py"
  assert_failure
  assert_output --partial "fzf"
  assert_output --partial "home/private_dot_config/brewfiles/Brewfile"
  assert_output --partial "PATH"
}

@test "R9: an fzf that never answers leaves the palette alive and empty" {
  local stub="$PALETTE_WORK/slowfzf"
  mkdir -p "$stub"
  cat > "$stub/fzf" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --version) echo "0.74.3 (stub)" ;;
  *) sleep 5 ;;
esac
SH
  chmod +x "$stub/fzf"

  run env PATH="$stub:$PATH" HERDR_COMMAND_PALETTE_CONFIG="$REAL_COMMANDS" python3 - <<'PY'
import palette_boot

palette = palette_boot.palette()
_, commands = palette.load_commands()
result = palette.ranked("qqzz", commands, palette.DEFAULT_LIMIT)
assert result == [], result
assert "timed out" in palette.last_search_status(), palette.last_search_status()
print("survived")
PY
  assert_success
  assert_output --partial "survived"
  refute_output --partial "Traceback"
}
