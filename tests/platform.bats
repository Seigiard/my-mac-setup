#!/usr/bin/env bats

load 'helpers/common'

setup() {
  skip_if_no_chezmoi
}

# ===========================================
# .chezmoiignore platform filtering
# ===========================================

@test "chezmoiignore filters macOS files on Linux" {
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

@test "chezmoiignore includes macOS files on macOS" {
  is_macos || skip "Only relevant on macOS"
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" managed --source "$SOURCE_ROOT"
  assert_success
  assert_output --partial ".hammerspoon"
  assert_output --partial ".config/ghostty"
  assert_output --partial ".config/kitty"
  assert_output --partial ".config/karabiner"
  assert_output --partial ".config/zed"
}
