#!/usr/bin/env bats

load 'helpers/common'
load 'helpers/herdr_task_sync'

teardown() {
  hts_teardown
}

@test "herdr-task-sync descriptor child probe" {
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
  : > "$HTS_WORK/block-herdr"
  hts_release_model pi 1
  hts_wait_for_task_slug "$task" descriptor-probe
  hts_wait_for_record_number "$control" committed_generation "$generation"
  hts_wait_for_file "$HTS_WORK/herdr-blocked"
  hts_record_number \
    "$(hts_namespace "$HTS_DEFAULT_SOCKET")/presentation.claim/owner" pid \
    > "$HTS_DESCRIPTOR_PID_FILE"
}
