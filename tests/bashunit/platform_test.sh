#!/usr/bin/env bash
# post-apply: 40 host-safe
# platform post-apply suite — bashunit source. Vocabulary (run, assert_*,
# skip, BATS_* contract) comes from tests/bashunit/test-dsl.bash.
# Migrated from platform.bats; parity evidence: docs/benchmarks/bashunit-full-suite-experiment.md.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"


load 'helpers/common'

setup() {
  skip_if_no_chezmoi
}

# ===========================================
# .chezmoiignore platform filtering
# ===========================================

function test_platform_001_chezmoiignore_filters_macos_files_on_linux() {
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

function test_platform_002_chezmoiignore_includes_macos_files_on_macos() {
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
