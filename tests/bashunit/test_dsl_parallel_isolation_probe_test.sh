#!/usr/bin/env bash
# post-apply: excluded
# Dedicated two-test fixture for the test DSL's parallel temp-directory
# isolation. Converted historical test numbers are metadata, not unique IDs.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

# The two tests rendezvous through marker files, so a sequential run stalls
# 5s polling for a marker the other test never wrote, then fails misleadingly.
# The driver (test_scripts_259 in scripts_test.sh) runs this file with -j 2;
# skip unless the runner actually enabled parallel execution.
skip_unless_parallel_run() {
  if declare -F bashunit::parallel::is_enabled >/dev/null; then
    bashunit::parallel::is_enabled && return 0
  elif [ "${BASHUNIT_PARALLEL_RUN:-}" = "true" ]; then
    return 0
  fi
  skip "requires the parallel driver (test_scripts_259 runs this file with -j 2)"
}

assert_parallel_tmpdirs_differ() {
  local own="$1" other="$2" attempt=0
  printf '%s\n' "$BATS_TEST_TMPDIR" > "$_BATS_FILE_TMPROOT/$own"
  while [ ! -f "$_BATS_FILE_TMPROOT/$other" ] && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$_BATS_FILE_TMPROOT/$other"
  run test "$(< "$_BATS_FILE_TMPROOT/$own")" != "$(< "$_BATS_FILE_TMPROOT/$other")"
  assert_success
}

function test_parallel_tmpdir_isolation_first() {
  _bats_test_init 1 'parallel temp directory isolation first probe'
  skip_unless_parallel_run
  assert_parallel_tmpdirs_differ first second
}

function test_parallel_tmpdir_isolation_second() {
  _bats_test_init 1 'parallel temp directory isolation second probe'
  skip_unless_parallel_run
  assert_parallel_tmpdirs_differ second first
}

function set_up_before_script() { :; }
function tear_down_after_script() { _bats_file_cleanup; }
function tear_down() { _bats_run_teardown; }
