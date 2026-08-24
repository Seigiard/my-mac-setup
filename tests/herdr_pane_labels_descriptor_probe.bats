#!/usr/bin/env bats

load 'helpers/common'
load 'helpers/herdr_pane_labels'

teardown() {
  hpl_teardown
}

@test "herdr-pane-labels descriptor child probe" {
  [ -n "${HPL_DESCRIPTOR_PID_FILE:-}" ] || skip "internal descriptor probe"
  hpl_setup
  hpl_set_process_pane pane-1 tab-1 ws-1 term-1 /tmp old
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old"}'
  hpl_set_process_label pane-1 btop
  hpl_request_only
  : > "$HPL_WORK/block-herdr"
  env PATH="$HPL_STUB:/usr/bin:/bin" \
    HERDR_SOCKET_PATH="$HPL_DEFAULT_SOCKET" \
    HERDR_PANE_LABELS_STATE_DIR="$HPL_STATE" \
    HERDR_PANE_LABELS_GIT_BUDGET="$HPL_GIT_BUDGET" \
    bash "$HPL_ENGINE" --presentation-worker &
  hpl_wait_for_file "$HPL_WORK/herdr-blocked"
  hpl_record_number \
    "$(hpl_namespace "$HPL_DEFAULT_SOCKET")/presentation.claim/owner" pid \
    > "$HPL_DESCRIPTOR_PID_FILE"
}
