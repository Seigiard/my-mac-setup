#!/usr/bin/env bash
# post-apply: excluded
# Dedicated one-test file for the herdr-task-sync descriptor probe. The
# bounded-invocation driver in scripts_test.sh runs it under a nested
# tests/lib/bashunit so the guard covers setup plus the probe itself rather
# than the runner parsing the whole scripts suite. Vocabulary (run, assert_*,
# skip, BATS_* contract) comes from tests/bashunit/test-dsl.bash.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/common'
load 'helpers/herdr_task_sync'

teardown() {
  hts_teardown
}

function test_herdr_task_sync_descriptor_child_probe() {
  _bats_test_init 1 'herdr-task-sync descriptor child probe'
  [ -n "${HTS_DESCRIPTOR_PID_FILE:-}" ] || skip "internal descriptor probe"
  hts_setup
  hts_stub_controlled_engine pi
  hts_model_fixture pi 1 descriptor-probe
  local control task generation
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  task="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 descriptor-s)"

  hts_run --agent claude --session descriptor-s <<< 'descriptor probe prompt'
  hts_wait_for_file "$HTS_WORK/models/pi/1/started"
  generation="$(hts_record_number "$control" generation)"
  : > "$HTS_WORK/block-api-snapshot"
  hts_release_model pi 1
  hts_wait_for_task_slug "$task" descriptor-probe
  hts_wait_for_record_number "$control" committed_generation "$generation"
  hts_wait_for_file "$HTS_WORK/herdr-blocked"
  hts_record_number \
    "$(hts_namespace "$HTS_DEFAULT_SOCKET")/presentation.claim/owner" pid \
    > "$HTS_DESCRIPTOR_PID_FILE"
  # The bats original relied on implicit assertions alone; bashunit calls a
  # zero-assertion test risky and fails the run, so assert the completion
  # signal the driver polls for actually landed.
  assert test -s "$HTS_DESCRIPTOR_PID_FILE"
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function tear_down() { _bats_run_teardown; }
