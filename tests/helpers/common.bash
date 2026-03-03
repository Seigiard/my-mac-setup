# Common test helpers for bats tests

HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${HELPERS_DIR}/bats-libs/bats-support/load.bash" ]]; then
  echo "ERROR: bats-libs not found. Run: git submodule update --init --recursive" >&2
  return 1
fi

load "${HELPERS_DIR}/bats-libs/bats-support/load"
load "${HELPERS_DIR}/bats-libs/bats-assert/load"
load "${HELPERS_DIR}/bats-libs/bats-file/load"

# Source directory for chezmoi (auto-detect from chezmoi config or use default)
if command -v chezmoi >/dev/null 2>&1; then
  CHEZMOI_SOURCE="$(chezmoi source-path 2>/dev/null || echo "$HOME/.local/share/chezmoi")"
else
  CHEZMOI_SOURCE="${CHEZMOI_SOURCE:-$HOME/.local/share/chezmoi}"
fi
export CHEZMOI_SOURCE

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

get_os() {
  case "$(uname -s)" in
    Darwin) echo "darwin" ;;
    Linux)  echo "linux" ;;
    *)      echo "unknown" ;;
  esac
}

is_macos() {
  [[ "$(get_os)" == "darwin" ]]
}

is_linux() {
  [[ "$(get_os)" == "linux" ]]
}

skip_if_no_chezmoi() {
  if ! command_exists chezmoi; then
    skip "chezmoi not installed"
  fi
}

render_template() {
  local template_file="$1"
  chezmoi execute-template < "$template_file"
}

assert_no_template_markers() {
  local file="$1"
  run grep -n '{{.*}}' "$file"
  assert_failure
}
