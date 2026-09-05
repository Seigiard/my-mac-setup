#!/usr/bin/env bash
# post-apply: excluded
# Dedicated two-test fixture for the test DSL's parallel temp-directory
# isolation. Converted historical test numbers are metadata, not unique IDs.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

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
  assert_parallel_tmpdirs_differ first second
}

function test_parallel_tmpdir_isolation_second() {
  _bats_test_init 1 'parallel temp directory isolation second probe'
  assert_parallel_tmpdirs_differ second first
}

function set_up_before_script() { :; }
function tear_down_after_script() { _bats_file_cleanup; }
function tear_down() { _bats_run_teardown; }
