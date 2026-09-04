# Common test helpers for the bashunit suites

HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sourced directly: this file must stay usable outside the test runner so its
# truth table can be exercised from a plain `bash -c` -- see the `guard:` tests
# in tests/bashunit/idempotent_test.sh.
# shellcheck source=./disposable-home.bash
source "${HELPERS_DIR}/disposable-home.bash"

CHEZMOI_UNATTENDED="$HELPERS_DIR/chezmoi-unattended"
export CHEZMOI_UNATTENDED

chezmoi_unattended() {
  local profile="$1"
  shift
  MMS_CHEZMOI_UNATTENDED=1 "$CHEZMOI_UNATTENDED" \
    --profile "$profile" -- "$@"
}

chezmoi_unattended_finite_stdin() {
  local profile="$1"
  shift
  MMS_CHEZMOI_UNATTENDED=1 "$CHEZMOI_UNATTENDED" \
    --profile "$profile" --finite-stdin -- "$@"
}

chezmoi_full_fixture() {
  MMS_DISPOSABLE_HOME=1 \
    MMS_CHEZMOI_FIXTURE_LINEAR_API_KEY=mms-test-linear-canary \
    MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY=mms-test-tavily-canary \
    MMS_CHEZMOI_FIXTURE_JINA_API_KEY=mms-test-jina-canary \
    MMS_CHEZMOI_FIXTURE_CONTEXT7_API_KEY=mms-test-context7-canary \
    MMS_CHEZMOI_FIXTURE_VECTOR_PRIME_API_KEY=mms-test-vector-prime-canary \
    chezmoi_unattended full-fixture "$@"
}

chezmoi_full_fixture_finite_stdin() {
  MMS_DISPOSABLE_HOME=1 \
    MMS_CHEZMOI_FIXTURE_LINEAR_API_KEY=mms-test-linear-canary \
    MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY=mms-test-tavily-canary \
    MMS_CHEZMOI_FIXTURE_JINA_API_KEY=mms-test-jina-canary \
    MMS_CHEZMOI_FIXTURE_CONTEXT7_API_KEY=mms-test-context7-canary \
    MMS_CHEZMOI_FIXTURE_VECTOR_PRIME_API_KEY=mms-test-vector-prime-canary \
    chezmoi_unattended_finite_stdin full-fixture "$@"
}

chezmoi_host_partial() {
  chezmoi_unattended host-partial "$@"
}

# Source directory for chezmoi (auto-detect from chezmoi config or use default)
if command -v chezmoi >/dev/null 2>&1; then
  CHEZMOI_SOURCE="$(chezmoi_host_partial source-path 2>/dev/null || echo "$HOME/.local/share/chezmoi")"
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
  require_disposable_home
  chezmoi_full_fixture init \
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
# deliberate exception to the skip-on-missing-tool convention.
# The floor is what macOS ships at /usr/bin/python3, the oldest interpreter any
# supported environment provides.
PYTHON3_MIN_VERSION="3.9"

# Each check returns explicitly: the DSL's fail() prints and returns 1, it
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
  [[ "$(get_os)" == "darwin" ]] || return 1
}

is_linux() {
  [[ "$(get_os)" == "linux" ]] || return 1
}

skip_if_no_chezmoi() {
  if ! command_exists chezmoi; then
    skip "chezmoi not installed"
  fi
}

# Gate for any test that runs a chezmoi command which writes. chezmoi's
# --source selects where templates are read from, never where they are written:
# without --destination, the destination is $HOME. So such a test deploys onto
# whatever machine runs it.
#
# The misconfigured verdict asserts instead of skipping -- a deliberate
# exception to the skip-on-missing-tool convention, in the same shape as
# assert_python3_available() above. A missing developer tool is a
# reason to skip. A runner whose $HOME is disposable but which carries no
# marker is a repository misconfiguration that silently removes coverage, and
# the runner exits 0 on skip, so a skip there would be green and untested at once.
require_disposable_home() {
  case "$(mms_disposable_home_verdict)" in
    run)
      return 0
      ;;
    misconfigured)
      fail "MMS_DISPOSABLE_HOME is not 1, but this environment reports a disposable \$HOME (GITHUB_ACTIONS is set, or /.dockerenv exists). Declare the marker at the site that launched this suite, or these tests lose their coverage silently: .github/workflows/test-dotfiles.yml (top-level env: block), and docker/docker-compose.yml (services ubuntu, test-ubuntu, test-full)."
      return 1
      ;;
    *)
      skip "would run a real chezmoi apply against this \$HOME, not a sandbox, so on a workstation it overwrites your live dotfiles and runs the install scripts -- use 'make test-ubuntu' for this coverage, or set MMS_DISPOSABLE_HOME=1 to declare this \$HOME disposable (that opt-in applies --source=\$CHEZMOI_SOURCE, the separate chezmoi clone, not this checkout)"
      ;;
  esac
}

render_template() {
  local template_file="$1"
  chezmoi_full_fixture_finite_stdin --source "$SOURCE_ROOT" execute-template < "$template_file"
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
  chezmoi_full_fixture_finite_stdin execute-template --init \
    --source "$SOURCE_ROOT" < "$SOURCE_ROOT/.chezmoi.yaml.tmpl" > "$out"
}

# Render a template against a specific config file. Neither render_template()
# nor templates_test.sh's render_with_source() can do this — neither passes
# --config, so both read the host's config and cannot select a render mode.
render_with_config() {
  local config_file="$1"
  local template_file="$2"
  chezmoi_full_fixture \
    --config "$config_file" --source "$SOURCE_ROOT" \
    execute-template --file "$template_file"
}
