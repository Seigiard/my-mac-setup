# Common test helpers for bats tests

# Source directory for chezmoi (auto-detect from chezmoi config or use default)
if command -v chezmoi >/dev/null 2>&1; then
  CHEZMOI_SOURCE="$(chezmoi source-path 2>/dev/null || echo "$HOME/.local/share/chezmoi")"
else
  CHEZMOI_SOURCE="${CHEZMOI_SOURCE:-$HOME/.local/share/chezmoi}"
fi
export CHEZMOI_SOURCE

# Check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Get OS type
get_os() {
  case "$(uname -s)" in
    Darwin) echo "darwin" ;;
    Linux)  echo "linux" ;;
    *)      echo "unknown" ;;
  esac
}

# Check if running on macOS
is_macos() {
  [[ "$(get_os)" == "darwin" ]]
}

# Check if running on Linux
is_linux() {
  [[ "$(get_os)" == "linux" ]]
}
