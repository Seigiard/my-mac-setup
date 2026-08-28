# Bats compatibility layer for bashunit 0.50.1.
#
# Reproduces the observable bats-core 1.14 test semantics used by this suite so
# that @test bodies can run under bashunit verbatim (see
# .context/bashunit-full-suite/ for the measured semantics matrix):
#
# - Failure detection is a bare ERR trap (no errexit, no set -E) plus the body's
#   final exit status. This matches bats on the same interpreter, including the
#   bash-3.2 quirk where a mid-body `[[ ]]`/`(( ))` false is inert
#   (docs/issues/2026-08-27-002-bare-mid-test-assertions-are-silently-inert-in-bats.md).
# - `run` executes in a command substitution (subshell), captures merged
#   stdout+stderr with trailing newlines stripped, and splits $lines on
#   newlines with empty lines dropped — exactly bats' default capture.
# - `skip` marks the test skipped from any call depth and stops the body via
#   `exit 0`; bashunit's own EXIT handling still runs tear_down afterwards,
#   matching bats' teardown-after-skip guarantee.
# - Converted files adapt setup/teardown through _bats_test_init and a
#   generated tear_down wrapper; tear_down failure fails the test (bats parity).
#
# Must stay bash-3.2-clean: no declare -A, no ${var,,}, no readarray.

status=0
output=""
lines=()

_BATS_ERR_TRAP='_bats_err_trap "$?" "$BASH_COMMAND"'

_bats_err_trap() {
  # Mirrors bats' "`cmd' failed [with status N]" diagnostic for a failing
  # top-level command, then ends the test with that status.
  local st="$1" cmd="$2"
  trap - ERR
  if [ "$st" -eq 1 ]; then
    printf "\`%s' failed\n" "$cmd" >&2
  else
    printf "\`%s' failed with status %s\n" "$cmd" "$st" >&2
  fi
  exit "$st"
}

_bats_assert_pass() {
  trap - ERR
  bashunit::state::add_assertions_passed
  trap "$_BATS_ERR_TRAP" ERR
  return 0
}

_bats_assert_fail() {
  # Print a bats-assert style block and end the test as failed.
  trap - ERR
  bashunit::state::add_assertions_failed
  printf '%s\n' "$1" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Core bats vocabulary
# ---------------------------------------------------------------------------

load() {
  local name="$1" path
  case "$name" in
    */bats-support/load|*/bats-assert/load|*/bats-file/load)
      return 0 ;;  # vocabulary supplied by this shim
  esac
  case "$name" in
    /*) path="$name" ;;
    *)  path="$BATS_TEST_DIRNAME/$name" ;;
  esac
  if [ ! -f "$path" ]; then
    path="$path.bash"
  fi
  # shellcheck disable=SC1090
  source "$path"
}

run() {
  trap - ERR
  status=0
  output=""
  lines=()
  # Subshell for bats-like state isolation, FILE capture for bats-like fd
  # semantics: a daemon left running by the command inherits a writable file,
  # not a pipe that closes when capture ends — a command-substitution capture
  # SIGPIPEs detached continuations that write after run returns.
  local _bats_run_out
  _bats_run_out=$(mktemp "${TMPDIR:-/tmp}/bats-run-out.XXXXXX")
  ( "$@" ) > "$_bats_run_out" 2>&1
  status=$?
  output=$(cat "$_bats_run_out")
  rm -f "$_bats_run_out"
  _bats_split_lines
  trap "$_BATS_ERR_TRAP" ERR
  return 0
}

_bats_split_lines() {
  local had_f=0
  case $- in *f*) had_f=1 ;; esac
  set -f
  local IFS=$'\n'
  # shellcheck disable=SC2206
  lines=( $output )
  if [ "$had_f" -eq 0 ]; then
    set +f
  fi
}

skip() {
  trap - ERR
  bashunit::skip "${1:-}"
  exit 0
}

fail() {
  # bats-support fail(): print to stderr, return 1. At body level the ERR trap
  # turns that into a test failure; helpers rely on the explicit return value.
  printf '%s\n' "${1:-}" >&2
  return 1
}

# ---------------------------------------------------------------------------
# bats-assert subset used by this suite
# ---------------------------------------------------------------------------

assert() {
  # bats-assert generic form: fail unless the given command succeeds.
  if "$@"; then
    _bats_assert_pass
  else
    _bats_assert_fail "-- assertion failed --
command : $*
--"
  fi
}

assert_success() {
  if [ "$status" -ne 0 ]; then
    _bats_assert_fail "-- command failed --
status : $status
output : $output
--"
  fi
  _bats_assert_pass
}

assert_failure() {
  if [ $# -ge 1 ]; then
    if [ "$status" -ne "$1" ]; then
      _bats_assert_fail "-- command failed as expected, but status differs --
expected : $1
actual   : $status
output   : $output
--"
    fi
  elif [ "$status" -eq 0 ]; then
    _bats_assert_fail "-- command succeeded, but it was expected to fail --
output : $output
--"
  fi
  _bats_assert_pass
}

assert_equal() {
  if [ "$1" != "$2" ]; then
    _bats_assert_fail "-- values do not equal --
expected : $2
actual   : $1
--"
  fi
  _bats_assert_pass
}

# Shared matcher: _bats_match <mode> <haystack> <needle>
# mode: exact | partial | regexp ; returns 0 on match.
_bats_match() {
  case "$1" in
    partial) case "$2" in *"$3"*) return 0 ;; esac; return 1 ;;
    regexp)  [[ "$2" =~ $3 ]] ;;
    *)       [ "$2" = "$3" ] ;;
  esac
}

_bats_output_args() {
  # Parses assert_output/refute_output style args.
  # Sets _bats_mode and _bats_expected (reads stdin for `-`/`--stdin`).
  _bats_mode=exact
  _bats_expected=""
  local use_stdin=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -p|--partial) _bats_mode=partial; shift ;;
      -e|--regexp)  _bats_mode=regexp; shift ;;
      -|--stdin)    use_stdin=1; shift ;;
      --)           shift; break ;;
      *)            break ;;
    esac
  done
  if [ "$use_stdin" -eq 1 ]; then
    _bats_expected=$(cat -)
  else
    _bats_expected="${1-}"
  fi
}

assert_output() {
  _bats_output_args "$@"
  if ! _bats_match "$_bats_mode" "$output" "$_bats_expected"; then
    _bats_assert_fail "-- output does not match ($_bats_mode) --
expected : $_bats_expected
actual   : $output
--"
  fi
  _bats_assert_pass
}

refute_output() {
  _bats_output_args "$@"
  if _bats_match "$_bats_mode" "$output" "$_bats_expected"; then
    _bats_assert_fail "-- output should not match ($_bats_mode) --
unexpected : $_bats_expected
actual     : $output
--"
  fi
  _bats_assert_pass
}

_bats_line_args() {
  # Parses assert_line/refute_line args. Sets _bats_mode, _bats_index (or -1),
  # _bats_expected.
  _bats_mode=exact
  _bats_index=-1
  _bats_expected=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--index)   _bats_index="$2"; shift 2 ;;
      -p|--partial) _bats_mode=partial; shift ;;
      -e|--regexp)  _bats_mode=regexp; shift ;;
      --)           shift; break ;;
      *)            break ;;
    esac
  done
  _bats_expected="${1-}"
}

assert_line() {
  _bats_line_args "$@"
  local i
  if [ "$_bats_index" -ge 0 ]; then
    if ! _bats_match "$_bats_mode" "${lines[$_bats_index]-}" "$_bats_expected"; then
      _bats_assert_fail "-- line at index $_bats_index does not match ($_bats_mode) --
expected : $_bats_expected
actual   : ${lines[$_bats_index]-}
--"
    fi
  else
    local found=1
    i=0
    while [ "$i" -lt "${#lines[@]}" ]; do
      if _bats_match "$_bats_mode" "${lines[$i]}" "$_bats_expected"; then
        found=0
        break
      fi
      i=$((i + 1))
    done
    if [ "$found" -ne 0 ]; then
      _bats_assert_fail "-- no output line matches ($_bats_mode) --
expected : $_bats_expected
output   : $output
--"
    fi
  fi
  _bats_assert_pass
}

refute_line() {
  _bats_line_args "$@"
  local i
  if [ "$_bats_index" -ge 0 ]; then
    if _bats_match "$_bats_mode" "${lines[$_bats_index]-}" "$_bats_expected"; then
      _bats_assert_fail "-- line at index $_bats_index should not match ($_bats_mode) --
unexpected : $_bats_expected
actual     : ${lines[$_bats_index]-}
--"
    fi
  else
    i=0
    while [ "$i" -lt "${#lines[@]}" ]; do
      if _bats_match "$_bats_mode" "${lines[$i]}" "$_bats_expected"; then
        _bats_assert_fail "-- an output line should not match ($_bats_mode) --
unexpected : $_bats_expected
line       : ${lines[$i]}
index      : $i
--"
      fi
      i=$((i + 1))
    done
  fi
  _bats_assert_pass
}

# ---------------------------------------------------------------------------
# bats-file subset used by this suite
# ---------------------------------------------------------------------------

# bats-file tests -f (regular file), NOT -e. A directory at the path makes
# assert_file_not_exists vacuously pass — that is oracle behavior and two
# herdr-child scenarios depend on it (the superseded watcher's run DIRECTORY
# survives; see docs/issues/ 2026-08-28 vacuous-file-assertion issue).
assert_file_exists() {
  if [ ! -f "$1" ]; then
    _bats_assert_fail "-- file does not exist --
path : $1
--"
  fi
  _bats_assert_pass
}

assert_file_not_exists() {
  if [ -f "$1" ]; then
    _bats_assert_fail "-- file exists, but it was expected to be absent --
path : $1
--"
  fi
  _bats_assert_pass
}

assert_dir_exists() {
  if [ ! -d "$1" ]; then
    _bats_assert_fail "-- directory does not exist --
path : $1
--"
  fi
  _bats_assert_pass
}

assert_dir_not_exists() {
  if [ -d "$1" ]; then
    _bats_assert_fail "-- directory exists, but it was expected to be absent --
path : $1
--"
  fi
  _bats_assert_pass
}

assert_file_executable() {
  if [ ! -x "$1" ]; then
    _bats_assert_fail "-- file is not executable --
path : $1
--"
  fi
  _bats_assert_pass
}

assert_file_contains() {
  # bats-file: default engine is plain grep (BRE); optional third arg selects
  # grep|egrep|pcregrep.
  local file="$1" regex="$2" cmd="${3:-grep}"
  if ! "$cmd" -q -- "$regex" "$file"; then
    _bats_assert_fail "-- file does not contain regex --
path  : $file
regex : $regex
--"
  fi
  _bats_assert_pass
}

assert_file_permission() {
  local permission="$1" file="$2" actual
  if [[ "$OSTYPE" == darwin* ]]; then
    actual=$(stat -f '%A' "$file")
  else
    actual=$(stat -c '%a' "$file")
  fi
  if [ "$actual" != "$permission" ]; then
    _bats_assert_fail "-- file does not have permissions $permission --
path   : $file
actual : $actual
--"
  fi
  _bats_assert_pass
}

# ---------------------------------------------------------------------------
# Per-test initialization (emitted by the converter as the first body line)
# ---------------------------------------------------------------------------

# _bats_test_init <test-number> <original test name>
# BATS_TEST_FILENAME/BATS_TEST_DIRNAME are set by the generated file header.
_bats_test_init() {
  BATS_TEST_NUMBER="$1"
  BATS_TEST_DESCRIPTION="$2"
  BATS_TEST_NAME="$2"
  bashunit::set_test_title "$2"
  BATS_TEST_TMPDIR="$_BATS_FILE_TMPROOT/test-$1"
  mkdir -p "$BATS_TEST_TMPDIR"
  export BATS_TEST_NUMBER BATS_TEST_DESCRIPTION BATS_TEST_NAME BATS_TEST_TMPDIR
  trap "$_BATS_ERR_TRAP" ERR
  if declare -F setup >/dev/null; then
    setup
  fi
}

# Called from the generated set_up_before_script wrapper.
_bats_file_init() {
  BATS_TEST_FILENAME="$1"
  BATS_TEST_DIRNAME=$(cd "$(dirname "$1")" && pwd)
  BATS_TEST_FILENAME="$BATS_TEST_DIRNAME/$(basename "$1")"
  _BATS_FILE_TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/bats-compat-run.XXXXXX")
  BATS_RUN_TMPDIR="$_BATS_FILE_TMPROOT"
  BATS_FILE_TMPDIR="$_BATS_FILE_TMPROOT/file"
  mkdir -p "$BATS_FILE_TMPDIR"
  export BATS_TEST_FILENAME BATS_TEST_DIRNAME _BATS_FILE_TMPROOT \
    BATS_RUN_TMPDIR BATS_FILE_TMPDIR
}

# Called from the generated tear_down_after_script wrapper.
_bats_file_cleanup() {
  if [ -n "${_BATS_FILE_TMPROOT:-}" ] && [ -d "$_BATS_FILE_TMPROOT" ]; then
    rm -rf "$_BATS_FILE_TMPROOT"
  fi
}

# Generated tear_down wrapper body: run the original teardown with the ERR trap
# off; a failing teardown fails the test through the hook's exit status.
_bats_run_teardown() {
  trap - ERR
  if declare -F teardown >/dev/null; then
    teardown
  fi
}
