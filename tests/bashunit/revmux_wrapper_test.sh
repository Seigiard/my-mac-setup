#!/usr/bin/env bash
# post-apply: 26 host-safe
# revmux wrapper contract: which auth and arguments the real revmux receives.
# A fake revmux on PATH prints what reached it; the wrapper is the only logic
# under test.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/common'

setup() {
  WRAP_DIR="$BATS_TEST_TMPDIR/wrap"
  FAKE_DIR="$BATS_TEST_TMPDIR/fake"
  mkdir -p "$WRAP_DIR" "$FAKE_DIR"
  cp "$SOURCE_ROOT/dot_local/bin/executable_revmux" "$WRAP_DIR/revmux"
  chmod +x "$WRAP_DIR/revmux"
  cat > "$FAKE_DIR/revmux" <<'FAKE'
#!/usr/bin/env bash
printf 'ANTHROPIC_API_KEY=%s\n' "${ANTHROPIC_API_KEY-unset}"
printf 'arg=%s\n' "$@"
[ "${1:-}" != --preserve-anthropic-api-key ] || shift
[ "${1:-}" != fail ] || exit 7
FAKE
  chmod +x "$FAKE_DIR/revmux"
  WITH_REAL="$WRAP_DIR:$FAKE_DIR:/usr/bin:/bin"
}

function tear_down_after_script() {
  _bats_file_cleanup
}

wrapped_revmux() {
  env -u ANTHROPIC_API_KEY -u REVMUX_ANTHROPIC_API_KEY "$@"
}

function test_revmux_wrapper_7301_routes_the_key_and_the_preserve_flag_to_the_real_binary() {
  _bats_test_init 7301 'routes the key and the preserve flag to the real binary'
  # #given
  local expected
  expected="$(printf '%s\n' 'ANTHROPIC_API_KEY=key-canary' 'arg=--preserve-anthropic-api-key' \
    'arg=--task' 'arg=t' 'arg=--run' 'arg=r' 'arg=--no-tui')"
  # #when
  run wrapped_revmux PATH="$WITH_REAL" REVMUX_ANTHROPIC_API_KEY=key-canary \
    "$WRAP_DIR/revmux" --task t --run r --no-tui
  # #then
  assert_success
  assert_output "$expected"
}

function test_revmux_wrapper_7302_runs_the_real_binary_unchanged_without_the_key() {
  _bats_test_init 7302 'runs the real binary unchanged without the key'
  # #given
  # #when
  run wrapped_revmux PATH="$WITH_REAL" "$WRAP_DIR/revmux" config
  # #then
  assert_success
  assert_output "$(printf '%s\n' 'ANTHROPIC_API_KEY=unset' 'arg=config')"

  # a shell-wide ANTHROPIC_API_KEY passes through untouched; revmux itself decides its fate
  run wrapped_revmux PATH="$WITH_REAL" ANTHROPIC_API_KEY=outer "$WRAP_DIR/revmux" config
  assert_success
  assert_output "$(printf '%s\n' 'ANTHROPIC_API_KEY=outer' 'arg=config')"
}

function test_revmux_wrapper_7303_returns_the_real_binary_exit_status() {
  _bats_test_init 7303 'returns the real binary exit status'
  # #given
  # #when
  run wrapped_revmux PATH="$WITH_REAL" REVMUX_ANTHROPIC_API_KEY=key-canary "$WRAP_DIR/revmux" fail
  # #then
  assert_failure 7
}

function test_revmux_wrapper_7304_fails_instead_of_calling_itself_when_no_binary_follows() {
  _bats_test_init 7304 'fails instead of calling itself when no binary follows'
  # #given
  # #when
  run wrapped_revmux PATH="$WRAP_DIR:/usr/bin:/bin" "$WRAP_DIR/revmux" --version
  # #then
  assert_failure 127
  assert_output 'revmux: no revmux binary in PATH after this wrapper'
}
