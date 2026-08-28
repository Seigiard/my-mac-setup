#!/usr/bin/env bash
# Generated from tests/platform.bats by scripts/bats2bashunit.py — DO NOT EDIT.
source "$(dirname "${BASH_SOURCE[0]}")/bats-compat.bash"
_bats_file_init "$(dirname "${BASH_SOURCE[0]}")/../platform.bats"


load 'helpers/common'

setup() {
  skip_if_no_chezmoi
}

# ===========================================
# .chezmoiignore platform filtering
# ===========================================

function test_001_chezmoiignore_filters_macos_files_on_linux() {
  _bats_test_init 1 'chezmoiignore filters macOS files on Linux'
  is_linux || skip "Only relevant on Linux"
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" managed --source "$SOURCE_ROOT"
  assert_success
  refute_output --partial ".hammerspoon"
  refute_output --partial "Library"
  refute_output --partial ".config/ghostty"
  refute_output --partial ".config/kitty"
  refute_output --partial ".config/karabiner"
  refute_output --partial ".config/zed"
}

function test_002_chezmoiignore_includes_macos_files_on_macos() {
  _bats_test_init 2 'chezmoiignore includes macOS files on macOS'
  is_macos || skip "Only relevant on macOS"
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" managed --source "$SOURCE_ROOT"
  assert_success
  assert_output --partial ".hammerspoon"
  assert_output --partial ".config/ghostty"
  assert_output --partial ".config/kitty"
  assert_output --partial ".config/karabiner"
  assert_output --partial ".config/zed"
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

