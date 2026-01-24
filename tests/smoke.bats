#!/usr/bin/env bats

load 'helpers/common'

# ===========================================
# Core tools (must exist on both platforms)
# ===========================================

@test "zsh is installed" {
  command_exists zsh
}

@test "git is installed" {
  command_exists git
}

@test "curl is installed" {
  command_exists curl
}

# ===========================================
# Chezmoi-managed files exist
# ===========================================

@test ".zshrc exists" {
  [[ -f "$HOME/.zshrc" ]]
}

@test ".aliases exists" {
  [[ -f "$HOME/.aliases" ]]
}

@test ".gitconfig exists" {
  [[ -f "$HOME/.gitconfig" ]]
}

@test ".editorconfig exists" {
  [[ -f "$HOME/.editorconfig" ]]
}

@test "starship.toml exists" {
  [[ -f "$HOME/.config/starship.toml" ]]
}

# ===========================================
# Yazi configuration
# ===========================================

@test "yazi config exists" {
  [[ -d "$HOME/.config/yazi" ]]
}

# ===========================================
# Claude Code configuration
# ===========================================

@test ".claude directory exists" {
  [[ -d "$HOME/.claude" ]]
}

@test ".claude/CLAUDE.md exists" {
  [[ -f "$HOME/.claude/CLAUDE.md" ]]
}

# ===========================================
# macOS-only configs (skipped on Linux)
# ===========================================

@test "hammerspoon config exists (macOS only)" {
  if ! is_macos; then
    skip "Not on macOS"
  fi
  [[ -d "$HOME/.hammerspoon" ]]
}

@test "ghostty config exists (macOS only)" {
  if ! is_macos; then
    skip "Not on macOS"
  fi
  [[ -d "$HOME/.config/ghostty" ]]
}

@test "karabiner config exists (macOS only)" {
  if ! is_macos; then
    skip "Not on macOS"
  fi
  [[ -d "$HOME/.config/karabiner" ]]
}

@test "zed config exists (macOS only)" {
  if ! is_macos; then
    skip "Not on macOS"
  fi
  [[ -d "$HOME/.config/zed" ]]
}

# ===========================================
# Optional tools (installed via package manager)
# These tests are skipped if tool is not installed
# ===========================================

@test "starship is available (if installed)" {
  if ! command_exists starship; then
    skip "starship not installed"
  fi
  starship --version
}

@test "bat is available (if installed)" {
  if ! command_exists bat; then
    skip "bat not installed"
  fi
  bat --version
}

@test "eza is available (if installed)" {
  if ! command_exists eza; then
    skip "eza not installed"
  fi
  eza --version
}

@test "fd is available (if installed)" {
  if ! command_exists fd; then
    skip "fd not installed"
  fi
  fd --version
}

@test "fzf is available (if installed)" {
  if ! command_exists fzf; then
    skip "fzf not installed"
  fi
  fzf --version
}

@test "ripgrep is available (if installed)" {
  if ! command_exists rg; then
    skip "ripgrep not installed"
  fi
  rg --version
}

@test "delta is available (if installed)" {
  if ! command_exists delta; then
    skip "delta not installed"
  fi
  delta --version
}

@test "yazi is available (if installed)" {
  if ! command_exists yazi; then
    skip "yazi not installed"
  fi
  yazi --version
}

@test "lazygit is available (if installed)" {
  if ! command_exists lazygit; then
    skip "lazygit not installed"
  fi
  lazygit --version
}

@test "zoxide is available (if installed)" {
  if ! command_exists zoxide; then
    skip "zoxide not installed"
  fi
  zoxide --version
}

@test "mise is available (if installed)" {
  if ! command_exists mise; then
    skip "mise not installed"
  fi
  mise --version
}
