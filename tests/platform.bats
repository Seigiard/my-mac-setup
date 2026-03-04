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
  run chezmoi managed
  refute_output --partial ".hammerspoon"
  refute_output --partial "Library"
  refute_output --partial ".config/ghostty"
  refute_output --partial ".config/karabiner"
  refute_output --partial ".config/zed"
}

@test "chezmoiignore includes macOS files on macOS" {
  is_macos || skip "Only relevant on macOS"
  run chezmoi managed
  assert_output --partial ".hammerspoon"
  assert_output --partial ".config/ghostty"
  assert_output --partial ".config/karabiner"
  assert_output --partial ".config/zed"
}

# ===========================================
# Platform-specific file presence after apply
# ===========================================

@test "hammerspoon absent on Linux" {
  is_linux || skip "Only relevant on Linux"
  assert_dir_not_exists "$HOME/.hammerspoon"
}

@test "Library absent on Linux" {
  is_linux || skip "Only relevant on Linux"
  assert_dir_not_exists "$HOME/Library"
}

@test "ghostty config absent on Linux" {
  is_linux || skip "Only relevant on Linux"
  assert_dir_not_exists "$HOME/.config/ghostty"
}
