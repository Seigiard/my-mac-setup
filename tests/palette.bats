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
