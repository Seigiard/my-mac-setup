#!/usr/bin/env bats

load 'helpers/common'

# ===========================================
# Core tools (must exist on both platforms)
# ===========================================

@test "zsh is installed" {
  run command -v zsh
  assert_success
}

@test "git is installed" {
  run command -v git
  assert_success
}

@test "curl is installed" {
  run command -v curl
  assert_success
}

# ===========================================
# Chezmoi-managed files exist
# ===========================================

@test ".zshrc exists" {
  assert_file_exists "$HOME/.zshrc"
}

@test ".aliases exists" {
  assert_file_exists "$HOME/.aliases"
}

@test ".gitconfig exists" {
  assert_file_exists "$HOME/.gitconfig"
}

@test ".editorconfig exists" {
  assert_file_exists "$HOME/.editorconfig"
}

@test "starship.toml exists" {
  assert_file_exists "$HOME/.config/starship.toml"
}

# ===========================================
# Yazi configuration
# ===========================================

@test "yazi config exists" {
  assert_dir_exists "$HOME/.config/yazi"
}

# ===========================================
# Claude Code configuration
# ===========================================

@test ".claude directory exists" {
  assert_dir_exists "$HOME/.claude"
}

@test ".claude/CLAUDE.md exists" {
  assert_file_exists "$HOME/.claude/CLAUDE.md"
}

# ===========================================
# macOS-only configs (skipped on Linux)
# ===========================================

@test "hammerspoon config exists (macOS only)" {
  is_macos || skip "Not on macOS"
  assert_dir_exists "$HOME/.hammerspoon"
}

@test "ghostty config exists (macOS only)" {
  is_macos || skip "Not on macOS"
  assert_dir_exists "$HOME/.config/ghostty"
}

@test "karabiner config exists (macOS only)" {
  is_macos || skip "Not on macOS"
  assert_dir_exists "$HOME/.config/karabiner"
}

@test "zed config exists (macOS only)" {
  is_macos || skip "Not on macOS"
  assert_dir_exists "$HOME/.config/zed"
}

# ===========================================
# Optional tools (installed via package manager)
# ===========================================

@test "starship is available (if installed)" {
  command_exists starship || skip "starship not installed"
  run starship --version
  assert_success
}

@test "bat is available (if installed)" {
  command_exists bat || skip "bat not installed"
  run bat --version
  assert_success
}

@test "eza is available (if installed)" {
  command_exists eza || skip "eza not installed"
  run eza --version
  assert_success
}

@test "fd is available (if installed)" {
  command_exists fd || skip "fd not installed"
  run fd --version
  assert_success
}

@test "fzf is available (if installed)" {
  command_exists fzf || skip "fzf not installed"
  run fzf --version
  assert_success
}

@test "ripgrep is available (if installed)" {
  command_exists rg || skip "ripgrep not installed"
  run rg --version
  assert_success
}

@test "delta is available (if installed)" {
  command_exists delta || skip "delta not installed"
  run delta --version
  assert_success
}

@test "yazi is available (if installed)" {
  command_exists yazi || skip "yazi not installed"
  run yazi --version
  assert_success
}

@test "lazygit is available (if installed)" {
  command_exists lazygit || skip "lazygit not installed"
  run lazygit --version
  assert_success
}

@test "zoxide is available (if installed)" {
  command_exists zoxide || skip "zoxide not installed"
  run zoxide --version
  assert_success
}

@test "mise is available (if installed)" {
  command_exists mise || skip "mise not installed"
  run mise --version
  assert_success
}
