#!/usr/bin/env bash
# post-apply: 30 host-safe
# palette post-apply suite — bashunit source. Vocabulary (run, assert_*,
# skip, BATS_* contract) comes from tests/bashunit/test-dsl.bash.
# Migrated from palette.bats; parity evidence: docs/benchmarks/bashunit-full-suite-experiment.md.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

#
# Behaviour tests for the herdr command palette, run against the chezmoi SOURCE
# tree. tests/bashunit/smoke_test.sh also exercises the palette, but from the applied copy
# under $HOME -- which is stale until `chezmoi apply`, a command this repo
# forbids on the host. These tests read $SOURCE_ROOT instead, so they gate an
# uncommitted edit in a bare checkout.

load 'helpers/common'

PALETTE_DIR="$SOURCE_ROOT/private_dot_config/herdr/plugins/command-palette"
REAL_COMMANDS="$SOURCE_ROOT/private_dot_config/herdr/command-palette/commands.toml"

setup() {
  # No `command_exists python3 || skip` here. python3 is a declared requirement
  # (README.md, Requirements), so its absence must fail rather than silence all
  # 58 tests in this file from inside setup(). Deliberate exception to the skip
  # convention in docs/issues/2026-08-20-013-se-blocks-test-hard-fails-without-deps.md;
  # the first test below is what names the cause.
  export PALETTE_PY="$PALETTE_DIR/palette.py"
  export PALETTE_OPEN_PY="$PALETTE_DIR/open.py"
  export OPEN_IN_ZED_PY="$PALETTE_DIR/open_in_zed.py"
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
# python3 -- the declared interpreter
# ===========================================

# First, so a missing or too-old interpreter states its own cause instead of
# leaving a wall of identical `python3: command not found` failures below.
function test_palette_001_python3_is_present_and_at_least_3_9_the_floor_re() {
  _bats_test_init 1 'python3 is present and at least 3.9, the floor README.md declares'
  run assert_python3_available
  assert_success
}

function test_palette_002_a_missing_python3_is_rejected() {
  _bats_test_init 2 'a missing python3 is rejected'
  local stub="$PALETTE_WORK/nopython" saved="$PATH"
  mkdir -p "$stub"

  PATH="$stub"
  run assert_python3_available
  PATH="$saved"

  assert_failure
  assert_output --partial "python3 is not on PATH"
}

# The gate has to reject, not fall through. Before the shape check in
# assert_python3_available, a stub printing "3.8.1" made the minor component
# "8.1", which is an arithmetic syntax error -- (( )) returned non-zero, the
# too-old branch was skipped, and a Python 3.8 stub passed the 3.9 floor.
# Stubbed on PATH the same way the missing-fzf test further down this file does.
function test_palette_003_a_python3_below_the_floor_or_one_answering_with() {
  _bats_test_init 3 'a python3 below the floor, or one answering with junk, is rejected'
  local stub="$PALETTE_WORK/badpy" saved="$PATH"
  mkdir -p "$stub"

  # Well-formed but too old: the ordinary floor rejection.
  printf '#!/bin/sh\necho "3.8"\nexit 0\n' > "$stub/python3"
  chmod +x "$stub/python3"
  PATH="$stub:$saved"
  run assert_python3_available
  PATH="$saved"
  assert_failure
  assert_output --partial "3.8"
  assert_output --partial "3.9"

  # Three components: the shape that used to pass.
  printf '#!/bin/sh\necho "3.8.1"\nexit 0\n' > "$stub/python3"
  PATH="$stub:$saved"
  run assert_python3_available
  PATH="$saved"
  assert_failure
  assert_output --partial "3.8.1"

  # Not a version at all.
  printf '#!/bin/sh\necho "Python 3.9.6 (stub)"\nexit 0\n' > "$stub/python3"
  PATH="$stub:$saved"
  run assert_python3_available
  PATH="$saved"
  assert_failure
  assert_output --partial "python3"
}

# ===========================================
# U1 -- the source-tree seam itself
# ===========================================

function test_palette_004_palette_sources_under_source_root_compile() {
  _bats_test_init 4 'palette sources under SOURCE_ROOT compile'
  run python3 -m py_compile \
    "$PALETTE_DIR/palette.py" \
    "$PALETTE_DIR/open.py" \
    "$PALETTE_DIR/open_in_zed.py" \
    "$PALETTE_DIR/smart_close.py"
  assert_success
}

function test_palette_005_open_in_zed_resolves_a_nested_repository_directo() {
  _bats_test_init 5 'Open in Zed resolves a nested repository directory and reuses the Zed window'
  local repository="$PALETTE_WORK/repository"
  local nested="$repository/packages/app"
  local fake_zed="$PALETTE_WORK/zed"
  local calls="$PALETTE_WORK/zed.calls"

  git init -q "$repository"
  repository="$(cd "$repository" && pwd -P)"
  nested="$repository/packages/app"
  mkdir -p "$nested"
  cat > "$fake_zed" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$ZED_CALLS"
SH
  chmod +x "$fake_zed"

  run env ZED_BIN="$fake_zed" ZED_CALLS="$calls" python3 "$OPEN_IN_ZED_PY" "$nested"
  assert_success
  run cat "$calls"
  assert_success
  assert_line --index 0 -- "-e"
  assert_line --index 1 "$repository"
}

function test_palette_006_open_in_zed_falls_back_to_a_valid_non_git_direct() {
  _bats_test_init 6 'Open in Zed falls back to a valid non-Git directory'
  local directory="$PALETTE_WORK/plain-directory"
  local fake_zed="$PALETTE_WORK/zed"
  local calls="$PALETTE_WORK/zed.calls"

  mkdir -p "$directory"
  directory="$(cd "$directory" && pwd -P)"
  cat > "$fake_zed" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$ZED_CALLS"
SH
  chmod +x "$fake_zed"

  run env ZED_BIN="$fake_zed" ZED_CALLS="$calls" python3 "$OPEN_IN_ZED_PY" "$directory"
  assert_success
  run cat "$calls"
  assert_success
  assert_line --index 0 -- "-e"
  assert_line --index 1 "$directory"
}

function test_palette_007_open_in_zed_rejects_an_empty_directory_before_st() {
  _bats_test_init 7 'Open in Zed rejects an empty directory before starting Zed'
  local fake_zed="$PALETTE_WORK/zed"
  local calls="$PALETTE_WORK/zed.calls"

  cat > "$fake_zed" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$ZED_CALLS"
SH
  chmod +x "$fake_zed"

  run env ZED_BIN="$fake_zed" ZED_CALLS="$calls" python3 "$OPEN_IN_ZED_PY" ""
  assert_failure
  assert_output --partial "directory must not be empty"
  [ ! -e "$calls" ]
}

function test_palette_008_open_in_zed_rejects_a_missing_directory_before_s() {
  _bats_test_init 8 'Open in Zed rejects a missing directory before starting Zed'
  local fake_zed="$PALETTE_WORK/zed"
  local calls="$PALETTE_WORK/zed.calls"

  cat > "$fake_zed" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$ZED_CALLS"
SH
  chmod +x "$fake_zed"

  run env ZED_BIN="$fake_zed" ZED_CALLS="$calls" python3 "$OPEN_IN_ZED_PY" "$PALETTE_WORK/missing"
  assert_failure
  assert_output --partial "not a directory"
  [ ! -e "$calls" ]
}

function test_palette_009_open_in_zed_resolves_zed_from_path_and_returns_i() {
  _bats_test_init 9 'Open in Zed resolves Zed from PATH and returns its exit status'
  local directory="$PALETTE_WORK/plain-directory"
  local bin="$PALETTE_WORK/bin"

  mkdir -p "$directory" "$bin"
  cat > "$bin/zed" <<'SH'
#!/bin/sh
exit 7
SH
  chmod +x "$bin/zed"

  run env -u ZED_BIN PATH="$bin:$PATH" python3 "$OPEN_IN_ZED_PY" "$directory"
  assert_equal "$status" 7
}

function test_palette_010_open_in_zed_rejects_an_invalid_configured_execut() {
  _bats_test_init 10 'Open in Zed rejects an invalid configured executable'
  local directory="$PALETTE_WORK/plain-directory"
  mkdir -p "$directory"

  run env ZED_BIN="$PALETTE_WORK/missing-zed" python3 "$OPEN_IN_ZED_PY" "$directory"
  assert_failure
  assert_output --partial "ZED_BIN is not executable"
}

function test_palette_011_open_in_zed_reports_its_bounded_timeout() {
  _bats_test_init 11 'Open in Zed reports its bounded timeout'
  local directory="$PALETTE_WORK/plain-directory"
  local fake_zed="$PALETTE_WORK/zed"
  mkdir -p "$directory"
  cat > "$fake_zed" <<'SH'
#!/bin/sh
sleep 1
SH
  chmod +x "$fake_zed"

  run env OPEN_IN_ZED_PY="$OPEN_IN_ZED_PY" DIRECTORY="$directory" ZED_BIN="$fake_zed" python3 - <<'PY'
import importlib.util
import os
import sys

path = os.environ["OPEN_IN_ZED_PY"]
spec = importlib.util.spec_from_file_location("open_in_zed", path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
module.COMMAND_TIMEOUT_SECONDS = 0.01
raise SystemExit(module.main([path, os.environ["DIRECTORY"]]))
PY
  assert_equal "$status" 124
  assert_output --partial "Zed did not respond"
}

# What this proves is the branch, not the path: with sys.platform forced to
# darwin and nothing named `zed` on PATH, resolve_zed() falls back to
# MACOS_ZED_CLI instead of raising or returning the PATH lookup. The value of
# MACOS_ZED_CLI is overwritten with a fake below, so the shipped literal
# (/Applications/Zed.app/...) is deliberately NOT asserted here: only a macOS
# host with Zed actually installed could observe it, and this suite runs on
# Linux too. No test in this repo owns that literal.
function test_palette_012_resolve_zed_falls_back_to_the_macos_cli_when_zed_is_not_on_path() {
  _bats_test_init 12 'resolve_zed falls back to the macOS CLI path when zed is not on PATH'
  local fake_zed="$PALETTE_WORK/zed"
  touch "$fake_zed"
  chmod +x "$fake_zed"

  run env -u ZED_BIN OPEN_IN_ZED_PY="$OPEN_IN_ZED_PY" FAKE_ZED="$fake_zed" python3 - <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

path = os.environ["OPEN_IN_ZED_PY"]
spec = importlib.util.spec_from_file_location("open_in_zed", path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
module.sys.platform = "darwin"
module.shutil.which = lambda _: None
module.MACOS_ZED_CLI = Path(os.environ["FAKE_ZED"])
assert module.resolve_zed() == os.environ["FAKE_ZED"]
PY
  assert_success
}

function test_palette_013_validate_accepts_the_real_commands_toml_and_name() {
  _bats_test_init 13 '--validate accepts the real commands.toml and names the command count'
  run python3 "$PALETTE_DIR/palette.py" --validate "$REAL_COMMANDS"
  assert_success
  # The count is what the name claims, so read it back out of the report
  # instead of pinning "commands)", a fragment of palette.py's own f-string
  # that no consumer parses. The expectation is a second, independent count of
  # the `[[commands]]` table headers in the same file: when the validator's
  # parser silently drops, merges, or duplicates an entry, the two counts
  # diverge. Editing commands.toml moves both sides together, so a config
  # change cannot silently rewrite this expectation.
  local reported expected
  reported="$(printf '%s\n' "$output" | sed -n 's/.*(\([0-9][0-9]*\) command.*/\1/p')"
  expected="$(grep -c '^\[\[commands\]\]' "$REAL_COMMANDS")"
  [[ "$expected" -gt 0 ]] || fail "no [[commands]] entries found in $REAL_COMMANDS"
  assert_equal "$reported" "$expected"
}

function test_palette_014_validate_rejects_an_unsupported_command_type() {
  _bats_test_init 14 '--validate rejects an unsupported command type'
  cat > "$PALETTE_WORK/bad.toml" <<'TOML'
name = "Broken"
type = "not_a_type"
command = "echo broken"
TOML

  run python3 "$PALETTE_DIR/palette.py" --validate "$PALETTE_WORK/bad.toml"
  assert_failure
  assert_output --partial "unsupported type"
}

function test_palette_015_load_commands_reads_a_fixture_config_from_the_so() {
  _bats_test_init 15 'load_commands reads a fixture config from the source tree'
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
_, commands = palette.load_commands()
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

function test_palette_016_r1_lg_ranks_lazygit_in_popup_first() {
  _bats_test_init 16 'R1: lg ranks Lazygit in popup first'
  run rank_real lg
  assert_success
  assert_line --index 0 "Lazygit in popup"
}

function test_palette_017_r1_ws_ranks_switch_workspace_first() {
  _bats_test_init 17 'R1: ws ranks Switch workspace first'
  run rank_real ws
  assert_success
  assert_line --index 0 "Switch workspace"
}

function test_palette_018_r1_edit_ranks_edit_command_palette_config_first() {
  _bats_test_init 18 'R1: edit ranks Edit command palette config first'
  run rank_real edit
  assert_success
  assert_line --index 0 "Edit command palette config"
}

function test_palette_019_r1_zed_ranks_open_in_zed_first_and_returns_only() {
  _bats_test_init 19 'R1: zed ranks Open in Zed first, and returns only it'
  run rank_real zed
  assert_success
  assert_line --index 0 "Open in Zed"
  assert_equal "${#lines[@]}" 1
}

function test_palette_020_r1_main_ranks_merge_main_branch_first() {
  _bats_test_init 20 'R1: main ranks Merge main branch first'
  run rank_real main
  assert_success
  assert_line --index 0 "Merge main branch"
}

function test_palette_021_r1_lazy_ranks_lazygit_in_popup_first() {
  _bats_test_init 21 'R1: lazy ranks Lazygit in popup first'
  run rank_real lazy
  assert_success
  assert_line --index 0 "Lazygit in popup"
}

function test_palette_022_r10_the_cyrillic_shortcuts_rank_their_command_fi() {
  _bats_test_init 22 'R10: the Cyrillic shortcuts rank their command first'
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

# fzf defaults to smart case, so an uppercase letter would switch the title tier
# to case-sensitive matching while the shortcut tier keeps case-folding.
function test_palette_023_r1_the_title_tier_is_case_insensitive() {
  _bats_test_init 23 'R1: the title tier is case-insensitive'
  local upper lower
  for lower in main config workspace lazy; do
    upper="$(printf '%s' "$lower" | tr '[:lower:]' '[:upper:]')"
    run rank_real "$lower"
    assert_success
    lower_out="$output"

    run rank_real "$upper"
    assert_success
    assert_equal "$output" "$lower_out"
    refute_output ""
  done
}

function test_palette_024_r10_a_half_typed_shortcut_still_matches_by_prefi() {
  _bats_test_init 24 'R10: a half-typed shortcut still matches by prefix'
  run rank_real "дфя"
  assert_success
  assert_line --index 0 "Lazygit in popup"
}

function test_palette_025_r10_shortcut_matching_is_case_insensitive() {
  _bats_test_init 25 'R10: shortcut matching is case-insensitive'
  run rank_real "LG"
  assert_success
  assert_line --index 0 "Lazygit in popup"
}

function test_palette_026_r10_a_decoy_title_cannot_displace_a_shortcut_hit() {
  _bats_test_init 26 'R10: a decoy title cannot displace a shortcut hit'
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

function test_palette_027_r2_a_query_matching_no_title_and_no_shortcut_ret() {
  _bats_test_init 27 'R2: a query matching no title and no shortcut returns nothing'
  run rank_real "qqzzxx"
  assert_success
  assert_output ""
}

# Ranked against a test-owned fixture, like tests 029/030 below. Against the
# production commands.toml the expected count was just a restatement of that
# file's `[[commands]]` entries: commit 4adc681 deleted four commands and
# rewrote the expectation in the same patch, so the test could not have caught
# a ranking regression that dropped entries. The fixture also interleaves two
# groups, which pins the "group order" half of the claim -- commands come back
# regrouped by first-seen group, not in file order.
function test_palette_028_r2_an_empty_query_returns_every_command_in_group() {
  _bats_test_init 28 'R2: an empty query returns every command in group order'
  cat > "$PALETTE_WORK/commands.toml" <<'TOML'
[[commands]]
group = "Alpha"
title = "First alpha"
type = "shell"
command = "true"

[[commands]]
group = "Beta"
title = "Only beta"
type = "shell"
command = "true"

[[commands]]
group = "Alpha"
title = "Second alpha"
type = "shell"
command = "true"
TOML

  run rank_in "$PALETTE_WORK/commands.toml" ""
  assert_success
  assert_equal "${#lines[@]}" 3
  assert_line --index 0 "First alpha"
  assert_line --index 1 "Second alpha"
  assert_line --index 2 "Only beta"
}

function test_palette_029_a_command_with_no_shortcuts_still_matches_by_tit() {
  _bats_test_init 29 'a command with no shortcuts still matches by title'
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

function test_palette_030_a_title_containing_a_tab_does_not_corrupt_the_in() {
  _bats_test_init 30 'a title containing a tab does not corrupt the index mapping'
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

function test_palette_031_validate_rejects_a_malformed_shortcuts_value() {
  _bats_test_init 31 '--validate rejects a malformed shortcuts value'
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
#
# The fixture is written here rather than read from commands.toml: production
# config is mutable and unrelated to this parser branch, so copying its values
# ties a parser regression test to an operator's shortcut choices -- edit the
# entry and the expectation silently rewrites itself, delete it and the test
# fails for a reason unrelated to the parser. This fixture pins the array shape
# plus the adjacent scalar and multi-command shapes the fallback parser must
# handle to read a shortcuts array correctly, including non-ASCII entries --
# Cyrillic shortcuts are why this test exists; keep them.
function test_palette_032_the_fallback_toml_parser_reads_a_shortcuts_array() {
  _bats_test_init 32 'the fallback TOML parser reads a shortcuts array'
  cat > "$PALETTE_WORK/commands.toml" <<'TOML'
[[commands]]
group = "Fixture"
title = "Shortcut command"
type = "shell"
command = "true"
shortcuts = ["lg", "дп", "дфян"]
description = "a key that follows the shortcuts array"

[[commands]]
group = "Fixture"
title = "No shortcuts command"
type = "shell"
command = "true"
TOML

  run python3 - "$PALETTE_WORK/commands.toml" <<'PY'
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
assert by_title["Shortcut command"]["shortcuts"] == ["lg", "дп", "дфян"], by_title["Shortcut command"]
assert by_title["Shortcut command"]["description"] == "a key that follows the shortcuts array", by_title["Shortcut command"]
assert by_title["No shortcuts command"].get("shortcuts") is None, by_title["No shortcuts command"]
PY
  assert_success

  # Control, paired with the valid fixture above: the fallback parser's array
  # branch must still hand validate_shortcuts a rejectable shape. validate_cli
  # returns exit 1 for every failure in its validation chain, so status alone
  # cannot tell this rejection apart from an unrelated one -- pin the message
  # to the shortcuts-specific reason too, the same way test_palette_031 does
  # for the tomllib-backed path.
  cat > "$PALETTE_WORK/bad-shortcuts.toml" <<'TOML'
[[commands]]
title = "Broken shortcut"
type = "shell"
command = "true"
shortcuts = ["lg", 7]
TOML

  run python3 - "$PALETTE_WORK/bad-shortcuts.toml" <<'PY'
import builtins
import sys

real_import = builtins.__import__


def without_tomllib(name, *args, **kwargs):
    if name == "tomllib":
        raise ModuleNotFoundError(name)
    return real_import(name, *args, **kwargs)


builtins.__import__ = without_tomllib

import palette_boot

palette = palette_boot.palette()
sys.exit(palette.validate_cli([sys.argv[1]]))
PY
  assert_failure
  assert_output --partial "Broken shortcut"
  assert_output --partial "shortcut"
}

function test_palette_033_select_options_rank_through_the_same_scorer() {
  _bats_test_init 33 'select options rank through the same scorer'
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

function test_palette_034_r3_every_command_is_reachable_at_40_commands_in() {
  _bats_test_init 34 'R3: every command is reachable at 40 commands in 8 groups'
  run scroll_fixture
  assert_success
  assert_line "visible 40"
  assert_line "reachable 40"
}

function test_palette_035_r3_the_last_drawn_row_never_reaches_the_descript() {
  _bats_test_init 35 'R3: the last drawn row never reaches the description line'
  run scroll_fixture
  assert_success
  local lowest detail
  lowest="$(printf '%s\n' "$output" | awk '/^lowest_drawn /{print $2}')"
  detail="$(printf '%s\n' "$output" | awk '/^detail_y /{print $2}')"
  [ "$lowest" -lt "$detail" ]
}

function test_palette_036_r3_ten_commands_still_render_unscrolled() {
  _bats_test_init 36 'R3: ten commands still render unscrolled'
  run scroll_fixture
  assert_success
  assert_line "ten_start 0"
  assert_line "ten_fits 1"
}

function test_palette_037_r3_a_single_group_with_no_extra_headers_still_sc() {
  _bats_test_init 37 'R3: a single group with no extra headers still scrolls'
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
  "tab create") printf '{"result":{"tab":{"tab_id":"w1:t9"},"root_pane":{"pane_id":"w1:p9","tab_id":"w1:t9"}}}\n' ;;
  "tab focus") : ;;
  "notification show") : ;;
  *) exit 2 ;;
esac
exit 0
SH
  chmod +x "$dir/herdr"
}

# Run the `Edit command palette config` pane_run command against a stub herdr.
# Run the first command of `kind` from a fixture config against a stub herdr.
# The fixture is local so the test does not depend on which shipped command
# happens to use that type today.
run_kind() {
  local dir="$1" kind="$2"
  cat > "$dir/commands.toml" <<'TOML'
[[commands]]
group = "Fixture"
title = "Edit in place"
type = "pane_run"
command = "vi /tmp/x"

[[commands]]
group = "Fixture"
title = "Run there"
type = "herdr"
args = ["pane", "run", "{target_pane}", "vi /tmp/x"]

[[commands]]
group = "Fixture"
title = "Run in a tab"
type = "tab_run"
command = "vi /tmp/x"
TOML

  env HERDR_BIN_PATH="$dir/herdr" HERDR_TARGET_PANE_ID="w1:p1" \
    HERDR_TARGET_CWD="$dir" HERDR_COMMAND_PALETTE_CONFIG="$dir/commands.toml" \
    python3 - "$kind" <<'PY'
import sys

import palette_boot

palette = palette_boot.palette()
config_path, commands = palette.load_commands()
command = next(c for c in commands if c.kind == sys.argv[1])
code, output, _ = palette.run_command(command, config_path)
print(f"code={code}")
print(output)
PY
}

run_pane_run() {
  run_kind "$1" pane_run
}

function test_palette_038_r4_pane_run_refuses_a_pane_an_agent_owns_and_say() {
  _bats_test_init 38 'R4: pane_run refuses a pane an agent owns and says why'
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

function test_palette_039_r4_pane_run_proceeds_when_no_agent_owns_the_pane() {
  _bats_test_init 39 'R4: pane_run proceeds when no agent owns the pane'
  stub_herdr "$PALETTE_WORK/free" 'null'
  run run_pane_run "$PALETTE_WORK/free"
  assert_success
  assert_line "code=0"

  run cat "$PALETTE_WORK/free/herdr.log"
  assert_success
  assert_output --partial "pane run"
  refute_output --partial "notification show"
}

function test_palette_040_r4_a_failed_pane_lookup_is_reported_not_treated() {
  _bats_test_init 40 'R4: a failed pane lookup is reported, not treated as a free pane'
  stub_herdr "$PALETTE_WORK/broken" 'unreachable'
  run run_pane_run "$PALETTE_WORK/broken"
  assert_success
  refute_line "code=0"
  assert_output --partial "w1:p1"

  run cat "$PALETTE_WORK/broken/herdr.log"
  assert_success
  refute_output --partial "pane run"
}

# The guard follows the argv, not the command kind: `herdr pane run` reaches a
# pane's shell whether it is spelled as a pane_run command or a herdr one.
function test_palette_041_r4_a_herdr_argv_pane_run_is_refused_for_an_agent() {
  _bats_test_init 41 'R4: a herdr argv pane run is refused for an agent-owned pane too'
  stub_herdr "$PALETTE_WORK/argv-agent" '"claude"'
  run run_kind "$PALETTE_WORK/argv-agent" herdr
  assert_success
  refute_line "code=0"
  assert_output --partial "w1:p1"
  assert_output --partial "claude"

  run cat "$PALETTE_WORK/argv-agent/herdr.log"
  assert_success
  refute_output --partial "pane run w1:p1 vi"
  assert_output --partial "notification show"
}

function test_palette_042_r4_a_herdr_argv_pane_run_proceeds_when_no_agent() {
  _bats_test_init 42 'R4: a herdr argv pane run proceeds when no agent owns the pane'
  stub_herdr "$PALETTE_WORK/argv-free" 'null'
  run run_kind "$PALETTE_WORK/argv-free" herdr
  assert_success
  assert_line "code=0"

  run cat "$PALETTE_WORK/argv-free/herdr.log"
  assert_success
  assert_output --partial "pane run w1:p1 vi"
}

function test_palette_043_r4_tab_run_creates_a_tab_and_never_consults_the() {
  _bats_test_init 43 'R4: tab_run creates a tab and never consults the agent guard'
  stub_herdr "$PALETTE_WORK/tabrun" '"claude"'
  run run_kind "$PALETTE_WORK/tabrun" tab_run
  assert_success

  run cat "$PALETTE_WORK/tabrun/herdr.log"
  assert_success
  assert_output --partial "tab create"
  refute_output --partial "pane get"
  refute_output --partial "notification show"
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

function test_palette_044_r6_an_open_palette_is_found_and_focused_instead() {
  _bats_test_init 44 'R6: an open palette is found and focused instead of opening a second'
  stub_opener_herdr "$PALETTE_WORK/token" token
  run run_opener "$PALETTE_WORK/token"
  assert_success

  run cat "$PALETTE_WORK/token/herdr.log"
  assert_success
  assert_output --partial "plugin pane focus w1:pP"
  refute_output --partial "plugin pane open"
}

function test_palette_045_r6_a_pane_that_merely_mentions_palette_py_is_not() {
  _bats_test_init 45 'R6: a pane that merely mentions palette.py is not the palette'
  stub_opener_herdr "$PALETTE_WORK/argv" argv
  run run_opener "$PALETTE_WORK/argv"
  assert_success

  run cat "$PALETTE_WORK/argv/herdr.log"
  assert_success
  assert_output --partial "plugin pane open"
  refute_output --partial "plugin pane focus"
}

function test_palette_046_r6_with_no_palette_pane_present_one_is_opened_an() {
  _bats_test_init 46 'R6: with no palette pane present, one is opened and marked'
  stub_opener_herdr "$PALETTE_WORK/none" none
  run run_opener "$PALETTE_WORK/none"
  assert_success

  run cat "$PALETTE_WORK/none/herdr.log"
  assert_success
  assert_output --partial "plugin pane open"
  assert_output --partial "pane report-metadata w1:pNEW"
  assert_output --partial "command_palette=open"
}

# The pane outlives the palette process when an overlay_shell command execs a
# shell over it. A token left behind makes the next keypress focus that shell.
function test_palette_047_r6_overlay_shell_clears_the_palette_token_before() {
  _bats_test_init 47 'R6: overlay_shell clears the palette token before it execs'
  stub_herdr "$PALETTE_WORK/overlay" 'null'
  run env HERDR_BIN_PATH="$PALETTE_WORK/overlay/herdr" HERDR_PANE_ID="w1:pP" \
    HERDR_COMMAND_PALETTE_CONFIG="$REAL_COMMANDS" python3 - <<'PY'
import palette_boot

palette = palette_boot.palette()
palette.clear_palette_token(palette.os.environ["HERDR_BIN_PATH"])
print("cleared")
PY
  assert_success

  run cat "$PALETTE_WORK/overlay/herdr.log"
  assert_success
  assert_output --partial "pane report-metadata w1:pP"
  assert_output --partial "--clear-token command_palette"
}

function test_palette_048_r6_the_lookup_costs_one_pane_list_and_no_process() {
  _bats_test_init 48 'R6: the lookup costs one pane list and no process-info calls'
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

function test_palette_049_r7_a_bare_value_in_a_shell_command_is_rejected_n() {
  _bats_test_init 49 'R7: a bare {value} in a shell command is rejected, naming {value_q}'
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

function test_palette_050_r7_value_q_and_value_url_are_accepted() {
  _bats_test_init 50 'R7: {value_q} and {value_url} are accepted'
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

function test_palette_051_r7_a_bare_value_in_a_herdr_argv_array_is_accepte() {
  _bats_test_init 51 'R7: a bare {value} in a herdr argv array is accepted'
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

function test_palette_052_r7_a_bare_value_in_a_herdr_argv_array_that_runs() {
  _bats_test_init 52 'R7: a bare {value} in a herdr argv array that runs a shell is rejected'
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

function test_palette_053_r7_a_bare_value_in_a_nested_run_table_is_rejecte() {
  _bats_test_init 53 'R7: a bare {value} in a nested [run] table is rejected'
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

function test_palette_054_r9_a_missing_fzf_fails_loudly_naming_fzf_the_bre() {
  _bats_test_init 54 'R9: a missing fzf fails loudly, naming fzf, the Brewfile and PATH'
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
  # Both Brewfile paths are instructions a human follows, so neither is pinned
  # as prose copied from palette.py. Each is read back out of the message and
  # checked against the tree: the repo path must name a file that really
  # declares fzf (the oracle is the Brewfile itself), and the install command's
  # deployed path must be that same managed file's chezmoi destination
  # (home/private_dot_config/... renders to ~/.config/...). Either path going
  # stale -- a moved Brewfile, a dropped fzf declaration -- turns this red.
  local repo_rel deployed repo_file
  repo_rel="$(printf '%s\n' "$output" | grep -oE 'home/[A-Za-z0-9_./-]+Brewfile[A-Za-z0-9.]*' | head -1)"
  deployed="$(printf '%s\n' "$output" | grep -oE '~/[A-Za-z0-9_./-]+Brewfile' | head -1)"
  [[ -n "$repo_rel" && -n "$deployed" ]] || fail "the fzf message named no repo and deployed Brewfile paths: $output"
  repo_file="$SOURCE_ROOT/${repo_rel#home/}"
  assert_file_exists "$repo_file"
  assert_file_contains "$repo_file" "fzf"
  assert_equal "home/private_dot_${deployed#\~/.}.tmpl" "$repo_rel"
}

# The only path that could raise out of the curses loop. A traceback there is a
# popup pane that flashes and vanishes, so it must degrade like the timeout does.
function test_palette_055_r9_an_fzf_that_fails_leaves_the_palette_alive_an() {
  _bats_test_init 55 'R9: an fzf that fails leaves the palette alive and says so'
  local stub="$PALETTE_WORK/brokenfzf"
  mkdir -p "$stub"
  cat > "$stub/fzf" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --version) echo "0.74.3 (stub)" ;;
  *) echo "fzf: unknown option --accept-nth" >&2; exit 2 ;;
esac
SH
  chmod +x "$stub/fzf"

  run env PATH="$stub:$PATH" HERDR_COMMAND_PALETTE_CONFIG="$REAL_COMMANDS" python3 - <<'PY'
import palette_boot

palette = palette_boot.palette()
_, commands = palette.load_commands()
result = palette.ranked("main", commands, palette.DEFAULT_LIMIT)
assert result == [], result
status = palette.last_search_status()
assert "fzf failed (2)" in status, status
choices = [palette.Choice(label="Production", value="prod")]
assert palette.visible_choices("prod", choices, 40) == choices
print("survived")
PY
  assert_success
  assert_output --partial "survived"
  refute_output --partial "Traceback"
}

function test_palette_056_r9_a_config_the_validator_rejects_is_reported_no() {
  _bats_test_init 56 'R9: a config the validator rejects is reported, not raised'
  cat > "$PALETTE_WORK/commands.toml" <<'TOML'
[[commands]]
title = "Broken shortcut"
type = "shell"
command = "true"
shortcuts = ["l g"]
TOML

  run env HERDR_COMMAND_PALETTE_CONFIG="$PALETTE_WORK/commands.toml" \
    python3 "$PALETTE_DIR/palette.py"
  assert_failure
  assert_output --partial "config is invalid"
  assert_output --partial "Broken shortcut"
  refute_output --partial "Traceback"
}

function test_palette_057_r9_an_fzf_that_never_answers_leaves_the_palette() {
  _bats_test_init 57 'R9: an fzf that never answers leaves the palette alive and empty'
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
assert "did not answer" in palette.last_search_status(), palette.last_search_status()
print("survived")
PY
  assert_success
  assert_output --partial "survived"
  refute_output --partial "Traceback"
}

function test_palette_058_delete_checkout_requires_exact_confirmation() {
  _bats_test_init 58 'Delete worktree checkout requires exact DELETE confirmation'
  local stub="$PALETTE_WORK/delete-confirmation"
  mkdir -p "$stub"
  cat > "$stub/herdr" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HERDR_CALLS"
SH
  chmod +x "$stub/herdr"

  run env HERDR_BIN_PATH="$stub/herdr" HERDR_CALLS="$stub/herdr.calls" \
    HERDR_WORKSPACE_ID="w1" HERDR_COMMAND_PALETTE_CONFIG="$REAL_COMMANDS" python3 - <<'PY'
from pathlib import Path

import palette_boot

palette = palette_boot.palette()
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
variables = palette.context_vars(Path(config_path), palette.os.environ["HERDR_BIN_PATH"])

rejected = palette.variables_with_value(variables, "delete")
status, output, _ = palette.run_command_with_variables(
    child, Path(config_path), rejected, palette.os.environ["HERDR_BIN_PATH"]
)
assert status == 1, (status, output)
assert "not deleted" in output, output
assert not Path(palette.os.environ["HERDR_CALLS"]).exists()

confirmed = palette.variables_with_value(variables, "DELETE")
status, output, _ = palette.run_command_with_variables(
    child, Path(config_path), confirmed, palette.os.environ["HERDR_BIN_PATH"]
)
assert status == 0, (status, output)
assert Path(palette.os.environ["HERDR_CALLS"]).read_text().strip() == "worktree remove --workspace w1"
PY
  assert_success
}

function test_palette_063_herdr_loads_the_command_palette_manifest_and_actions() {
  _bats_test_init 63 'Herdr loads the command palette manifest and actions'
  command_exists herdr || skip "herdr is not installed"
  local home="$PALETTE_WORK/herdr-home"
  mkdir -p "$home"

  run env HOME="$home" herdr plugin link "$PALETTE_DIR" --enabled
  assert_success

  # assert_success above owns the real regression: herdr refusing a manifest
  # its own parser rejects. The action ids are then compared against the other,
  # independently maintained side of the same relationship -- the keybindings
  # in herdr's config.toml, which dispatch `<plugin_id>.<action_id>`. herdr
  # surfaces a dangling binding only at keypress time, so nothing else here
  # catches a renamed or deleted action. Asserting that the link report echoes
  # an id typed in the manifest it just read would prove nothing.
  run env PALETTE_LINK_JSON="$output" \
    HERDR_CONFIG="$SOURCE_ROOT/private_dot_config/herdr/config.toml" python3 - <<'PY'
import json
import os
import re

raw = os.environ["PALETTE_LINK_JSON"]
line = next(l for l in reversed(raw.splitlines()) if l.startswith("{"))
report = json.loads(line)["result"]["plugin"]
plugin_id = report["plugin_id"]
reported = {action["id"] for action in report["actions"]}
assert reported, report

with open(os.environ["HERDR_CONFIG"], encoding="utf-8") as handle:
    config = handle.read()
bound = set(re.findall(re.escape(plugin_id) + r"\.([A-Za-z0-9_]+)", config))
assert bound, f"config.toml binds no {plugin_id} action"
dangling = bound - reported
assert not dangling, f"config.toml binds actions herdr does not report: {sorted(dangling)}"
print(f"bound={sorted(bound)} reported={sorted(reported)}")
PY
  assert_success
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function tear_down() { _bats_run_teardown; }
