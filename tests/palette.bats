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
  # Docker mounts the source tree read-only, so __pycache__ cannot live beside
  # the sources. py_compile reports that as a failure; redirect the cache.
  export PYTHONPYCACHEPREFIX="$PALETTE_WORK/pycache"
}

teardown() {
  [[ -n "${PALETTE_WORK:-}" ]] && rm -rf "$PALETTE_WORK" || true
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

# ===========================================
# U5 -- pane_run refuses a pane an agent owns
# ===========================================

# A `herdr` on PATH that logs its argv and answers `pane get` with the agent
# ownership the test wants. AGENT_JSON is the `agent` field, verbatim JSON.
stub_herdr() {
  local dir="$1" agent_json="$2"
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'LOG=%s/herdr.log\n' "$dir"
    printf 'AGENT=%s\n' "$(printf '%q' "$agent_json")"
  } > "$dir/herdr"
  cat >> "$dir/herdr" <<'SH'
printf '%s\n' "$*" >> "$LOG"
case "$1 $2" in
  "pane get")
    [ "$AGENT" = "unreachable" ] && exit 1
    printf '{"result":{"pane":{"pane_id":"%s","agent":%s}}}\n' "$3" "$AGENT" ;;
  "pane run") printf 'ran\n' ;;
  "notification show") : ;;
  *) exit 2 ;;
esac
exit 0
SH
  chmod +x "$dir/herdr"
}

# Run the `Edit command palette config` pane_run command against a stub herdr.
run_pane_run() {
  local dir="$1"
  env HERDR_BIN_PATH="$dir/herdr" HERDR_TARGET_PANE_ID="w1:p1" \
    HERDR_TARGET_CWD="$dir" HERDR_COMMAND_PALETTE_CONFIG="$REAL_COMMANDS" \
    python3 - <<'PY'
import pathlib

import palette_boot

palette = palette_boot.palette()
config_path, commands = palette.load_commands()
command = next(c for c in commands if c.kind == "pane_run")
code, output, _ = palette.run_command(command, config_path)
print(f"code={code}")
print(output)
PY
}

@test "R4: pane_run refuses a pane an agent owns and says why" {
  stub_herdr "$PALETTE_WORK/agent" '"claude"'
  run run_pane_run "$PALETTE_WORK/agent"
  assert_success
  refute_line --partial "code=0"
  assert_output --partial "w1:p1"
  assert_output --partial "claude"

  run cat "$PALETTE_WORK/agent/herdr.log"
  assert_success
  refute_output --partial "pane run"
  assert_output --partial "notification show"
}

@test "R4: pane_run proceeds when no agent owns the pane" {
  stub_herdr "$PALETTE_WORK/free" 'null'
  run run_pane_run "$PALETTE_WORK/free"
  assert_success
  assert_line "code=0"

  run cat "$PALETTE_WORK/free/herdr.log"
  assert_success
  assert_output --partial "pane run"
  refute_output --partial "notification show"
}

@test "R4: a failed pane lookup is reported, not treated as a free pane" {
  stub_herdr "$PALETTE_WORK/broken" 'unreachable'
  run run_pane_run "$PALETTE_WORK/broken"
  assert_success
  refute_line "code=0"
  assert_output --partial "w1:p1"

  run cat "$PALETTE_WORK/broken/herdr.log"
  assert_success
  refute_output --partial "pane run"
}

@test "R4: tab_run is unaffected by the pane_run guard" {
  run python3 - <<'PY'
import inspect

import palette_boot

palette = palette_boot.palette()
source = inspect.getsource(palette.run_command_with_variables)
tab_run = source.split('command.kind == "tab_run"', 1)[1]
assert "pane_agent" not in tab_run, "the agent guard leaked into tab_run"
print("tab_run clean")
PY
  assert_success
  assert_output --partial "tab_run clean"
}

# ===========================================
# U6 -- finding an already-open palette
# ===========================================

# A `herdr` on PATH for open.py. MODE decides what `pane list` reports:
#   token -- a pane carrying the palette's own metadata token
#   argv  -- a pane that merely MENTIONS palette.py (an editor, a grep, an agent)
#   none  -- no palette anywhere
stub_opener_herdr() {
  local dir="$1" mode="$2"
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'LOG=%s/herdr.log\n' "$dir"
    printf 'MODE=%s\n' "$mode"
  } > "$dir/herdr"
  cat >> "$dir/herdr" <<'SH'
printf '%s\n' "$*" >> "$LOG"
case "$1 $2" in
  "pane current") printf '{"result":{"pane":{"pane_id":"w1:p1","workspace_id":"w1"}}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s","workspace_id":"w1","tokens":{}}}}\n' "$3" ;;
  "pane list")
    case "$MODE" in
      token) printf '{"result":{"panes":[{"pane_id":"w1:pP","label":"~","tokens":{"command_palette":"open"}}]}}\n' ;;
      argv)  printf '{"result":{"panes":[{"pane_id":"w1:pE","label":"nvim palette.py","terminal_title":"python3 /x/command-palette/palette.py","tokens":{}}]}}\n' ;;
      *)     printf '{"result":{"panes":[{"pane_id":"w1:p1","label":"zsh","tokens":{}}]}}\n' ;;
    esac ;;
  "pane process-info")
    # Only the argv mode answers this, and it answers the way the old
    # substring guard was fooled: a process that merely mentions palette.py.
    [ "$MODE" = argv ] && printf '{"result":{"process_info":{"foreground_processes":[{"argv":["nvim","palette.py"],"cwd":"/x/command-palette"}]}}}\n'
    ;;
  "pane report-metadata") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3" ;;
  "plugin pane")
    [ "$3" = open ] && printf '{"result":{"plugin_pane":{"pane":{"pane_id":"w1:pNEW","workspace_id":"w1"}}}}\n'
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$dir/herdr"
}

run_opener() {
  local dir="$1"
  env HERDR_BIN_PATH="$dir/herdr" HERDR_PANE_ID="w1:p1" python3 "$PALETTE_DIR/open.py"
}

@test "R6: an open palette is found and focused instead of opening a second" {
  stub_opener_herdr "$PALETTE_WORK/token" token
  run run_opener "$PALETTE_WORK/token"
  assert_success

  run cat "$PALETTE_WORK/token/herdr.log"
  assert_success
  assert_output --partial "plugin pane focus w1:pP"
  refute_output --partial "plugin pane open"
}

@test "R6: a pane that merely mentions palette.py is not the palette" {
  stub_opener_herdr "$PALETTE_WORK/argv" argv
  run run_opener "$PALETTE_WORK/argv"
  assert_success

  run cat "$PALETTE_WORK/argv/herdr.log"
  assert_success
  assert_output --partial "plugin pane open"
  refute_output --partial "plugin pane focus"
}

@test "R6: with no palette pane present, one is opened and marked" {
  stub_opener_herdr "$PALETTE_WORK/none" none
  run run_opener "$PALETTE_WORK/none"
  assert_success

  run cat "$PALETTE_WORK/none/herdr.log"
  assert_success
  assert_output --partial "plugin pane open"
  assert_output --partial "pane report-metadata w1:pNEW"
  assert_output --partial "command_palette=open"
}

@test "R6: the lookup costs one pane list and no process-info calls" {
  stub_opener_herdr "$PALETTE_WORK/count" token
  run run_opener "$PALETTE_WORK/count"
  assert_success

  run grep -c '^pane list' "$PALETTE_WORK/count/herdr.log"
  assert_success
  assert_output "1"

  run grep -c 'process-info' "$PALETTE_WORK/count/herdr.log"
  assert_failure
}

# ===========================================
# U8 -- a form value must not be interpolated into a shell string unquoted
# ===========================================

validate_fixture() {
  cat > "$PALETTE_WORK/fixture.toml"
  python3 "$PALETTE_DIR/palette.py" --validate "$PALETTE_WORK/fixture.toml"
}

@test "R7: a bare {value} in a shell command is rejected, naming {value_q}" {
  run validate_fixture <<'TOML'
name = "Search"
type = "form"
command = "echo {value}"

[form]
prompt = "Search for"
TOML
  assert_failure
  assert_output --partial "{value_q}"
  assert_output --partial "Search"
}

@test "R7: {value_q} and {value_url} are accepted" {
  run validate_fixture <<'TOML'
name = "Quoted"
type = "form"
command = "echo {value_q}"

[form]
prompt = "Search for"
TOML
  assert_success

  run validate_fixture <<'TOML'
name = "Url"
type = "form"
command = "open 'https://example.com/?q={value_url}'"

[form]
prompt = "Search for"
TOML
  assert_success
}

@test "R7: a bare {value} in a herdr argv array is accepted" {
  run validate_fixture <<'TOML'
name = "Rename"
type = "form"
run_type = "herdr"
args = ["pane", "rename", "{value}"]

[form]
prompt = "New label"
TOML
  assert_success
}

@test "R7: a bare {value} in a herdr argv array that runs a shell is rejected" {
  run validate_fixture <<'TOML'
name = "Run there"
type = "form"
run_type = "herdr"
args = ["pane", "run", "{target_pane}", "{value}"]

[form]
prompt = "Command"
TOML
  assert_failure
  assert_output --partial "{value_q}"
}

@test "R7: a bare {value} in a nested [run] table is rejected" {
  run validate_fixture <<'TOML'
name = "Nested"
type = "select"

[[options]]
label = "One"
value = "one"

[run]
type = "tab_run"
command = "echo {value}"
TOML
  assert_failure
  assert_output --partial "{value_q}"
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
  assert_output --partial "PATH"
  # Both Brewfile paths: the repo one says where to edit the declaration, the
  # deployed one is what the install command can actually be run against.
  assert_output --partial "home/private_dot_config/brewfiles/Brewfile"
  assert_output --partial "brew bundle --file=~/.config/brewfiles/Brewfile"
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
