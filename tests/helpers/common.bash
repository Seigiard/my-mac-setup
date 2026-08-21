# Common test helpers for bats tests

HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${HELPERS_DIR}/bats-libs/bats-support/load.bash" ]]; then
  echo "ERROR: bats-libs not found. Run: git submodule update --init --recursive" >&2
  return 1
fi

load "${HELPERS_DIR}/bats-libs/bats-support/load"
load "${HELPERS_DIR}/bats-libs/bats-assert/load"
load "${HELPERS_DIR}/bats-libs/bats-file/load"

# Build a PATH without 1Password CLI for chezmoi commands that render
# all templates (apply, verify). op triggers auth prompts in tests.
# Individual tools remain available via full path.
CHEZMOI_BIN="$(command -v chezmoi 2>/dev/null || true)"
PATH_WITHOUT_OP=""
IFS=':' read -ra _path_dirs <<< "$PATH"
for _dir in "${_path_dirs[@]}"; do
  [[ -d "$_dir" ]] && [[ -x "$_dir/op" ]] && continue
  PATH_WITHOUT_OP="${PATH_WITHOUT_OP:+$PATH_WITHOUT_OP:}$_dir"
done
unset _path_dirs _dir
export CHEZMOI_BIN PATH_WITHOUT_OP

# Source directory for chezmoi (auto-detect from chezmoi config or use default)
if command -v chezmoi >/dev/null 2>&1; then
  CHEZMOI_SOURCE="$(chezmoi source-path 2>/dev/null || echo "$HOME/.local/share/chezmoi")"
else
  CHEZMOI_SOURCE="${CHEZMOI_SOURCE:-$HOME/.local/share/chezmoi}"
fi
export CHEZMOI_SOURCE

# Root of the chezmoi source tree — the repo's `home/` directory.
# Host: tests/ and home/ are repo-root siblings, so the working checkout wins and
# tests read the edits you have not committed yet.
# Docker: home/ mounts at $HOME/dotfiles while tests/ mounts separately, so
# ../home does not exist — fall back to the mount, then to the chezmoi source copy.
#
# Use SOURCE_ROOT to READ files from the source tree.
# Use CHEZMOI_SOURCE to drive chezmoi itself (apply/diff/verify --source=...).
resolve_source_root() {
  local root
  for root in \
    "${HELPERS_DIR}/../../home" \
    "$HOME/dotfiles" \
    "$CHEZMOI_SOURCE"; do
    if [[ -f "$root/.chezmoiignore" ]]; then
      (cd "$root" && pwd)
      return 0
    fi
  done
  echo "$CHEZMOI_SOURCE"
}

SOURCE_ROOT="$(resolve_source_root)"
export SOURCE_ROOT

CHEZMOI_TEST_CONFIG="/tmp/chezmoi-test.yaml"
export CHEZMOI_TEST_CONFIG

chezmoi_test_init() {
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" init \
    --config "$CHEZMOI_TEST_CONFIG" \
    --config-path "$CHEZMOI_TEST_CONFIG" \
    "$@"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# python3 is a declared system requirement of this repository, not an optional
# tool: it is the herdr command palette's interpreter and `chezmoi apply` shells
# out to it. So the files that depend on it assert instead of skipping -- a
# deliberate exception to the skip convention in
# docs/issues/2026-08-20-013-se-blocks-test-hard-fails-without-deps.md.
# The floor is what macOS ships at /usr/bin/python3, the oldest interpreter any
# supported environment provides.
PYTHON3_MIN_VERSION="3.9"

# Each check returns explicitly: bats-support's fail() prints and returns 1, it
# does not abort the function, so falling through would emit a second message
# derived from the state the first one just reported as broken.
assert_python3_available() {
  local readme="the Requirements section of README.md"
  local bin found major minor min_major min_minor

  if ! command_exists python3; then
    fail "python3 is not on PATH. It is the herdr command palette's interpreter and a declared requirement of this repository -- see $readme. Every supported OS ships one, so this repository does not install it."
    return 1
  fi

  bin="$(command -v python3)"
  found="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)" || found=""
  # Validate the shape before any arithmetic. Anything else -- a wrapper that
  # prints "3.8.1", a banner, whitespace, nothing at all -- would reach (( ))
  # as a non-numeric token, and a (( )) syntax error returns non-zero, which
  # reads as "not below the floor" and lets a bad interpreter through.
  if [[ ! "$found" =~ ^[0-9]+\.[0-9]+$ ]]; then
    fail "python3 at $bin answered the version probe with '$found' instead of a major.minor number, so it cannot be checked against the $PYTHON3_MIN_VERSION floor stated in $readme. A wrapper or stub shadowing the real interpreter on PATH looks like this."
    return 1
  fi

  major="${found%%.*}"
  minor="${found#*.}"
  min_major="${PYTHON3_MIN_VERSION%%.*}"
  min_minor="${PYTHON3_MIN_VERSION#*.}"
  # 10# forces base 10: the pattern above admits a leading zero, which bash
  # would otherwise read as an invalid octal literal and error on.
  if (( 10#$major < 10#$min_major || (10#$major == 10#$min_major && 10#$minor < 10#$min_minor) )); then
    fail "python3 at $bin is $found, older than the $PYTHON3_MIN_VERSION this repository requires -- see $readme. The palette's sources are kept compiling on $PYTHON3_MIN_VERSION because that is what macOS ships at /usr/bin/python3."
    return 1
  fi
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
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" execute-template < "$template_file"
}

# Write the config that `chezmoi init` would generate, using the caller's
# environment, to $1. Some data keys bind at init time rather than render time —
# ci_minimal, which selects the CI-minimal Brewfile render, is one — so
# exercising both modes means producing two configs and rendering against each.
#
# Call it with the environment you want bound, e.g.
#   MMS_CI_MINIMAL=1 write_test_config "$cfg"
#
# Deliberately not `chezmoi init --source "$SOURCE_ROOT"`: init creates a .git
# directory inside its source tree. On a host that writes into the repo
# checkout, and in Docker it fails outright, because home/ is mounted read-only
# at /home/testuser/dotfiles. `execute-template --init` renders the same
# template with no side effects and no write access required.
write_test_config() {
  local out="$1"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" execute-template --init \
    --source "$SOURCE_ROOT" < "$SOURCE_ROOT/.chezmoi.yaml.tmpl" > "$out"
}

# Render a template against a specific config file. Neither render_template()
# nor templates.bats' render_with_source() can do this — neither passes
# --config, so both read the host's config and cannot select a render mode.
render_with_config() {
  local config_file="$1"
  local template_file="$2"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" \
    --config "$config_file" --source "$SOURCE_ROOT" \
    execute-template < "$template_file"
}

assert_no_template_markers() {
  local file="$1"
  run grep -n '{{.*}}' "$file"
  assert_failure
}
