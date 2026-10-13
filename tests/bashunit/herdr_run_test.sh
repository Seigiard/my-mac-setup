#!/usr/bin/env bash
# post-apply: 22 host-safe
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/common'

setup() {
  unset HERDR_ENV
  unset HERDR_WORKSPACE_ID
  unset HERDR_PANE_ID
  unset HERDR_RUN_DIR
  HERDR_RUN="$SOURCE_ROOT/dot_local/bin/executable_herdr-run"
  HERDR_RUN_HOME="$BATS_TEST_TMPDIR/home"
  HERDR_RUN_DIR="$BATS_TEST_TMPDIR/state"
  HERDR_RUN_CWD="$BATS_TEST_TMPDIR/cwd"
  mkdir -p "$HERDR_RUN_HOME" "$HERDR_RUN_CWD"
}

herdr_run() {
  env HOME="$HERDR_RUN_HOME" HERDR_RUN_DIR="$HERDR_RUN_DIR" "$HERDR_RUN" "$@"
}

wait_for_run_exit() {
  local exit_file="$1" attempt=0
  while [ ! -s "$exit_file" ] && [ "$attempt" -lt 500 ]; do
    sleep 0.01
    attempt=$((attempt + 1))
  done
  [ -s "$exit_file" ] || fail "run did not write $exit_file"
}

wait_for_run_pid() {
  local pid_file="$1" attempt=0
  while [ ! -s "$pid_file" ] && [ "$attempt" -lt 500 ]; do
    sleep 0.01
    attempt=$((attempt + 1))
  done
  [ -s "$pid_file" ] || fail "run did not write $pid_file"
}

state_directory_is_empty() {
  [ ! -e "$HERDR_RUN_DIR" ] && return 0
  [ -d "$HERDR_RUN_DIR" ] || return 1
  [ -z "$(find "$HERDR_RUN_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

function test_herdr_run_4601_inline_wait_returns_the_inner_status_and_records_it() {
  _bats_test_init 4601 'inline wait returns the inner status and records it'
  # #given
  # #when
  run herdr_run failed --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait --timeout 5 -- sh -c 'exit 3'
  # #then
  assert_failure 3
  assert_equal "$(cat "$HERDR_RUN_DIR/failed.exit")" 3

  run herdr_run succeeded --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait --timeout 5 -- sh -c 'exit 0'
  assert_success
  assert_equal "$(cat "$HERDR_RUN_DIR/succeeded.exit")" 0
}

function test_herdr_run_4602_records_merged_output_and_independent_git_metadata() {
  _bats_test_init 4602 'records merged output and independent git metadata'
  # #given
  git -C "$HERDR_RUN_CWD" init -q
  git -C "$HERDR_RUN_CWD" config user.email test@example.invalid
  git -C "$HERDR_RUN_CWD" config user.name 'Test User'
  printf 'tracked\n' > "$HERDR_RUN_CWD/tracked"
  git -C "$HERDR_RUN_CWD" add tracked
  git -C "$HERDR_RUN_CWD" commit -qm initial
  local head
  head="$(git -C "$HERDR_RUN_CWD" rev-parse HEAD)"

  # #when
  run herdr_run clean --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait --timeout 5 -- sh -c 'printf "out\n"; printf "err\n" >&2'
  # #then
  assert_success
  assert_equal "$(cat "$HERDR_RUN_DIR/clean.log")" $'out\nerr'
  assert_file_contains "$HERDR_RUN_DIR/clean.meta" '^start=[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$'
  assert_file_contains "$HERDR_RUN_DIR/clean.meta" "^head=$head$"
  assert_file_contains "$HERDR_RUN_DIR/clean.meta" '^dirty=0$'
  assert_file_contains "$HERDR_RUN_DIR/clean.meta" "^cwd=$HERDR_RUN_CWD$"

  printf 'untracked\n' > "$HERDR_RUN_CWD/untracked"
  run herdr_run dirty --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait --timeout 5 -- sh -c 'exit 0'
  assert_success
  assert_file_contains "$HERDR_RUN_DIR/dirty.meta" "^head=$head$"
  assert_file_contains "$HERDR_RUN_DIR/dirty.meta" '^dirty=1$'
}

function test_herdr_run_4603_launch_script_ends_with_the_exact_marker_outside_the_log() {
  _bats_test_init 4603 'launch script ends with the exact marker outside the log'
  # #given
  run herdr_run marker --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" -- sh -c 'exit 3'
  assert_success
  wait_for_run_exit "$HERDR_RUN_DIR/marker.exit"
  rm -f "$HERDR_RUN_DIR/marker.exit" "$HERDR_RUN_DIR/marker.log"

  # #when
  local output_file="$BATS_TEST_TMPDIR/marker.stdout" trace_file="$BATS_TEST_TMPDIR/marker.trace"
  run bash -c 'bash -x "$1" > "$2" 2> "$3"' _ \
    "$HERDR_RUN_DIR/marker.sh" "$output_file" "$trace_file"
  # #then
  assert_failure 3
  assert_equal "$(cat "$output_file")" 'herdr-run: marker exit=3'
  assert_equal "$(cat "$HERDR_RUN_DIR/marker.exit")" 3
  assert_equal "$(cat "$HERDR_RUN_DIR/marker.log")" ''
  local exit_write_line marker_line
  exit_write_line="$(grep -nxF "+ printf '%s\\n' 3" "$trace_file" | cut -d: -f1)"
  marker_line="$(grep -nxF "+ printf 'herdr-run: marker exit=%s\\n' 3" "$trace_file" | cut -d: -f1)"
  [ -n "$exit_write_line" ] || fail 'xtrace did not record the exit-file write'
  [ -n "$marker_line" ] || fail 'xtrace did not record the marker print'
  [ "$exit_write_line" -lt "$marker_line" ] || fail 'launch script printed the marker before writing .exit'
}

function test_herdr_run_4604_sets_the_launch_environment_and_changes_to_the_requested_directory() {
  _bats_test_init 4604 'sets the launch environment and changes to the requested directory'
  # #given
  # #when
  run herdr_run My.Label --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait --timeout 5 -- \
    sh -c 'printf "%s\n%s\n%s\n" "$COMPOSE_PROJECT_NAME" "$PATH" "$PWD"'
  # #then
  assert_success
  assert_equal "$(sed -n '1p' "$HERDR_RUN_DIR/My.Label.log")" herdr-run-my-label
  assert_file_contains "$HERDR_RUN_DIR/My.Label.log" "^$HERDR_RUN_HOME/.local/share/mise/shims:"
  assert_equal "$(sed -n '3p' "$HERDR_RUN_DIR/My.Label.log")" "$HERDR_RUN_CWD"
}

function test_herdr_run_4605_timeout_leaves_the_inline_workload_alive_until_it_finishes() {
  _bats_test_init 4605 'timeout leaves the inline workload alive until it finishes'
  # #given
  # #when
  run --separate-stderr herdr_run timeout --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait --timeout 1 -- \
    sh -c 'sleep 2; exit 0'
  # #then
  assert_failure 124
  assert_stderr 'herdr-run: timeout timeout after 1s, workload left running'
  local pid
  pid="$(cat "$HERDR_RUN_DIR/timeout.pid")"
  run kill -0 "$pid"
  assert_success
  wait_for_run_exit "$HERDR_RUN_DIR/timeout.exit"
  assert_equal "$(cat "$HERDR_RUN_DIR/timeout.exit")" 0
}

function test_herdr_run_4606_stall_report_does_not_kill_a_silent_workload() {
  _bats_test_init 4606 'stall report does not kill a silent workload'
  # #given
  local stderr_file="$BATS_TEST_TMPDIR/stalled.stderr" wrapper_pid attempt=0 pid
  # #when
  env HERDR_RUN_STALL_SECONDS=1 HOME="$HERDR_RUN_HOME" "$HERDR_RUN" stalled \
    --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait --timeout 5 -- sh -c 'sleep 2; exit 0' \
    > /dev/null 2> "$stderr_file" &
  wrapper_pid=$!
  while ! grep -Fq 'herdr-run: stalled stall: log idle ' "$stderr_file" \
    && kill -0 "$wrapper_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    sleep 0.01
    attempt=$((attempt + 1))
  done
  # #then
  assert_file_contains "$stderr_file" 'herdr-run: stalled stall: log idle '
  pid="$(cat "$HERDR_RUN_DIR/stalled.pid")"
  run kill -0 "$pid"
  assert_success
  wait "$wrapper_pid"
  assert_equal "$(cat "$HERDR_RUN_DIR/stalled.exit")" 0
}

function test_herdr_run_4607_verdict_reports_complete_running_and_unknown_state() {
  _bats_test_init 4607 'verdict reports complete running and unknown state'
  # #given
  mkdir -p "$HERDR_RUN_DIR"
  printf '%s\n' 'start=2026-10-13T07:40:24Z' 'head=abc123' 'dirty=1' "cwd=$HERDR_RUN_CWD" > "$HERDR_RUN_DIR/report.meta"
  printf '\342\234\227 first\n\342\234\227 second\nFailed third\n\033[31m\342\234\227 fourth\033[0m\npassed \342\234\223\nmid-line \342\234\227 decoy\n' > "$HERDR_RUN_DIR/report.log"
  printf '1\n' > "$HERDR_RUN_DIR/report.exit"

  # #when
  run herdr_run verdict report --dir "$HERDR_RUN_DIR"
  # #then
  assert_failure 1
  assert_output "state=complete
exit=1
head=abc123
dirty=1
cwd=$HERDR_RUN_CWD
failed=4"

  rm "$HERDR_RUN_DIR/report.exit"
  run herdr_run verdict report --dir "$HERDR_RUN_DIR"
  assert_failure 3
  assert_output "state=running
exit=none
head=abc123
dirty=1
cwd=$HERDR_RUN_CWD
failed=4"

  run --separate-stderr herdr_run verdict unknown --dir "$HERDR_RUN_DIR"
  assert_failure 2
}

function test_herdr_run_4608_usage_errors_leave_no_launch_state() {
  _bats_test_init 4608 'usage errors leave no launch state'
  # #given
  # #when
  run --separate-stderr herdr_run
  # #then
  assert_failure 2
  assert_stderr --partial usage
  assert state_directory_is_empty

  run --separate-stderr herdr_run bad/label --dir "$HERDR_RUN_DIR" -- -- true
  assert_failure 2
  assert_stderr --partial usage
  assert state_directory_is_empty

  run --separate-stderr herdr_run timeout --dir "$HERDR_RUN_DIR" --timeout 1 -- -- true
  assert_failure 2
  assert_stderr --partial usage
  assert state_directory_is_empty

  run --separate-stderr herdr_run missing --dir "$HERDR_RUN_DIR" --wait --timeout 1 true
  assert_failure 2
  assert_stderr --partial usage
  assert state_directory_is_empty
}

write_herdr_stub() {
  HERDR_STUB="$BATS_TEST_TMPDIR/herdr-bin"
  HERDR_STUB_CALLS="$BATS_TEST_TMPDIR/herdr.calls"
  mkdir -p "$HERDR_STUB"
  cat > "$HERDR_STUB/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s' "$1" >> "$HERDR_STUB_CALLS"
shift
for argument in "$@"; do
  printf ' %s' "$argument" >> "$HERDR_STUB_CALLS"
done
printf '\n' >> "$HERDR_STUB_CALLS"
if [ "$1" = create ]; then
  printf '%s\n' '{"result":{"root_pane":{"pane_id":"w1:p2"}},"type":"tab_created"}'
fi
SH
  chmod +x "$HERDR_STUB/herdr"
  export HERDR_STUB_CALLS
}

function test_herdr_run_4609_herdr_mode_launches_the_saved_script_in_a_new_tab() {
  _bats_test_init 4609 'herdr mode launches the saved script in a new tab'
  # #given
  write_herdr_stub
  # #when
  run env HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 HOME="$HERDR_RUN_HOME" PATH="$HERDR_STUB:$PATH" \
    "$HERDR_RUN" tabbed --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" -- sh -c 'exit 0'
  # #then
  assert_success
  assert_equal "$(cat "$HERDR_RUN_DIR/tabbed.pane")" w1:p2
  assert_file_exists "$HERDR_RUN_DIR/tabbed.sh"
  assert_file_contains "$HERDR_STUB_CALLS" "^tab create .*--cwd $HERDR_RUN_CWD.*--no-focus$"
  assert_equal "$(sed -n '2p' "$HERDR_STUB_CALLS")" "pane run w1:p2 bash $HERDR_RUN_DIR/tabbed.sh"
}

function test_herdr_run_4613_wait_and_verdict_report_a_workload_killed_without_a_status() {
  _bats_test_init 4613 'wait and verdict report a workload killed without a status'
  # #given
  run herdr_run control --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait --timeout 5 -- sh -c 'sleep 1'
  assert_success

  local stderr_file="$BATS_TEST_TMPDIR/dead.stderr" wrapper_pid workload_pid wait_status
  env HOME="$HERDR_RUN_HOME" HERDR_RUN_DIR="$HERDR_RUN_DIR" "$HERDR_RUN" dead \
    --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait --timeout 2 -- sh -c 'sleep 4' \
    > /dev/null 2> "$stderr_file" &
  wrapper_pid=$!
  wait_for_run_pid "$HERDR_RUN_DIR/dead.pid"
  workload_pid="$(cat "$HERDR_RUN_DIR/dead.pid")"
  run kill -0 "$workload_pid"
  assert_success

  # #when
  kill -KILL "$workload_pid"
  if wait "$wrapper_pid"; then
    wait_status=0
  else
    wait_status=$?
  fi
  # #then
  assert_equal "$wait_status" 125
  assert_file_contains "$stderr_file" "herdr-run: dead workload gone without a status (pid=$workload_pid)"

  run herdr_run verdict dead --dir "$HERDR_RUN_DIR"
  assert_failure 4
  assert_output --partial 'state=dead'
}

function test_herdr_run_4614_resolves_relative_workload_and_state_paths_before_launch() {
  _bats_test_init 4614 'resolves relative workload and state paths before launch'
  # #given
  local absolute_tmp absolute_cwd absolute_state
  absolute_tmp="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  absolute_cwd="$absolute_tmp/cwd"
  absolute_state="$absolute_tmp/state"

  # #when
  run bash -c 'cd "$1" && env HOME="$2" "$3" relative --cwd cwd --dir state --wait --timeout 5 -- sh -c "exit 3"' _ \
    "$BATS_TEST_TMPDIR" "$HERDR_RUN_HOME" "$HERDR_RUN"
  # #then
  assert_failure 3
  assert_file_contains "$absolute_state/relative.meta" "^cwd=$absolute_cwd$"
  assert_file_exists "$absolute_state/relative.exit"
  assert_equal "$(cat "$absolute_state/relative.exit")" 3
}

function test_herdr_run_4615_quotes_a_space_containing_script_path_for_herdr() {
  _bats_test_init 4615 'quotes a space containing script path for herdr'
  # #given
  write_herdr_stub
  local state_dir="$BATS_TEST_TMPDIR/with space" expected_command
  expected_command="$(printf 'bash %q' "$state_dir/quoted.sh")"

  # #when
  run env HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 HOME="$HERDR_RUN_HOME" PATH="$HERDR_STUB:$PATH" \
    "$HERDR_RUN" quoted --dir "$state_dir" --cwd "$HERDR_RUN_CWD" -- sh -c 'exit 0'
  # #then
  assert_success
  assert_equal "$(sed -n '2p' "$HERDR_STUB_CALLS")" "pane run w1:p2 $expected_command"
}

function test_herdr_run_4616_rejects_unusable_state_and_workload_directories_without_launching() {
  _bats_test_init 4616 'rejects unusable state and workload directories without launching'
  # #given
  local state_file="$BATS_TEST_TMPDIR/state-file" missing_cwd="$BATS_TEST_TMPDIR/missing-cwd"
  : > "$state_file"

  # #when
  run --separate-stderr herdr_run missing-cwd --dir "$HERDR_RUN_DIR" --cwd "$missing_cwd" --wait --timeout 5 -- true
  # #then
  assert_failure 2
  assert_stderr --partial 'herdr-run: cwd is not a directory:'
  assert [ ! -e "$HERDR_RUN_DIR/missing-cwd.pid" ]
  assert [ ! -e "$HERDR_RUN_DIR/missing-cwd.pane" ]
  assert [ ! -e "$HERDR_RUN_DIR/missing-cwd.sh" ]

  run --separate-stderr herdr_run state-file --dir "$state_file" --cwd "$HERDR_RUN_CWD" --wait --timeout 5 -- true
  assert_failure 2
  assert_stderr --partial 'herdr-run:'
  assert [ ! -e "$state_file/state-file.pid" ]
  assert [ ! -e "$state_file/state-file.pane" ]
  assert [ ! -e "$state_file/state-file.sh" ]
}

function test_herdr_run_4617_refuses_to_replace_the_state_of_a_live_label() {
  _bats_test_init 4617 'refuses to replace the state of a live label'
  # #given
  run herdr_run live --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" -- sh -c 'sleep 2'
  assert_success
  wait_for_run_pid "$HERDR_RUN_DIR/live.pid"
  local original_pid original_script
  original_pid="$(cat "$HERDR_RUN_DIR/live.pid")"
  original_script="$(cat "$HERDR_RUN_DIR/live.sh")"
  run kill -0 "$original_pid"
  assert_success

  # #when
  run --separate-stderr herdr_run live --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait --timeout 5 -- true
  # #then
  assert_failure 2
  assert_stderr "herdr-run: live is still running (pid=$original_pid); wait for it or choose another label"
  assert_equal "$(cat "$HERDR_RUN_DIR/live.pid")" "$original_pid"
  assert_equal "$(cat "$HERDR_RUN_DIR/live.sh")" "$original_script"
  wait_for_run_exit "$HERDR_RUN_DIR/live.exit"
  assert_equal "$(cat "$HERDR_RUN_DIR/live.exit")" 0
}

function test_herdr_run_46181_launch_script_records_its_own_pid() {
  _bats_test_init 46181 'launch script records its own pid'
  # #given
  run herdr_run script-pid --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" -- sh -c 'exit 0'
  assert_success
  wait_for_run_exit "$HERDR_RUN_DIR/script-pid.exit"
  rm -f "$HERDR_RUN_DIR/script-pid.pid" "$HERDR_RUN_DIR/script-pid.exit" "$HERDR_RUN_DIR/script-pid.log"

  # #when
  run bash -c 'printf "%s\n" "$$"; exec bash "$1"' _ "$HERDR_RUN_DIR/script-pid.sh"
  # #then
  assert_success
  local script_pid
  script_pid="$(printf '%s\n' "$output" | sed -n '1p')"
  assert_file_exists "$HERDR_RUN_DIR/script-pid.pid"
  assert_equal "$(cat "$HERDR_RUN_DIR/script-pid.pid")" "$script_pid"
}

function test_herdr_run_4618_stall_report_includes_the_script_pid_and_its_descendant() {
  _bats_test_init 4618 'stall report includes the script pid and its descendant'
  # #given
  local stderr_file="$BATS_TEST_TMPDIR/descendant.stderr" wrapper_pid attempt=0 script_pid wait_status
  # #when
  env HERDR_RUN_STALL_SECONDS=1 HOME="$HERDR_RUN_HOME" "$HERDR_RUN" descendant \
    --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait --timeout 10 -- bash -c 'sleep 3; true' \
    > /dev/null 2> "$stderr_file" &
  wrapper_pid=$!
  while ! grep -Fq 'herdr-run: descendant stall: log idle ' "$stderr_file" \
    && kill -0 "$wrapper_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    sleep 0.01
    attempt=$((attempt + 1))
  done
  script_pid="$(cat "$HERDR_RUN_DIR/descendant.pid")"
  # #then
  assert_file_contains "$stderr_file" 'herdr-run: descendant stall: log idle '
  run ps -o command= -p "$script_pid"
  assert_success
  assert_output --partial "bash $HERDR_RUN_DIR/descendant.sh"
  assert_file_contains "$stderr_file" '[[:space:]]sleep 3$'
  if wait "$wrapper_pid"; then
    wait_status=0
  else
    wait_status=$?
  fi
  assert_equal "$wait_status" 0
}

function test_herdr_run_4621_prefers_the_recorded_pid_over_a_live_tab_for_liveness() {
  _bats_test_init 4621 'prefers the recorded pid over a live tab for liveness'
  # #given
  write_herdr_stub
  run herdr_run tab-dead --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" -- sh -c 'sleep 5'
  assert_success
  wait_for_run_pid "$HERDR_RUN_DIR/tab-dead.pid"
  local dead_pid
  dead_pid="$(cat "$HERDR_RUN_DIR/tab-dead.pid")"
  printf '%s\n' w1:p2 > "$HERDR_RUN_DIR/tab-dead.pane"
  kill -KILL "$dead_pid"
  printf '%s\n' stale > "$HERDR_RUN_DIR/tab-dead.sh"

  # #when
  run env HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 HOME="$HERDR_RUN_HOME" PATH="$HERDR_STUB:$PATH" \
    "$HERDR_RUN" verdict tab-dead --dir "$HERDR_RUN_DIR"
  # #then
  assert_failure 4
  assert_output "state=dead
exit=none
head=none
dirty=0
cwd=$HERDR_RUN_CWD
failed=0"

  run env HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 HOME="$HERDR_RUN_HOME" PATH="$HERDR_STUB:$PATH" \
    "$HERDR_RUN" tab-dead --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" -- true
  assert_success
  run grep -Fx stale "$HERDR_RUN_DIR/tab-dead.sh"
  assert_failure 1
}

function test_herdr_run_46211_refuses_to_replace_a_live_pid_even_when_its_tab_is_live() {
  _bats_test_init 46211 'refuses to replace a live pid even when its tab is live'
  # #given
  write_herdr_stub
  run herdr_run tab-alive --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" -- sh -c 'sleep 2'
  assert_success
  wait_for_run_pid "$HERDR_RUN_DIR/tab-alive.pid"
  printf '%s\n' w1:p3 > "$HERDR_RUN_DIR/tab-alive.pane"
  run kill -0 "$(cat "$HERDR_RUN_DIR/tab-alive.pid")"
  assert_success

  # #when
  run --separate-stderr env HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 HOME="$HERDR_RUN_HOME" PATH="$HERDR_STUB:$PATH" \
    "$HERDR_RUN" tab-alive --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" -- true
  # #then
  assert_failure 2
  assert_stderr --partial 'is still running'
  wait_for_run_exit "$HERDR_RUN_DIR/tab-alive.exit"
}

function test_herdr_run_4622_stops_waiting_when_the_state_directory_disappears() {
  _bats_test_init 4622 'stops waiting when the state directory disappears'
  # #given
  local stderr_file="$BATS_TEST_TMPDIR/state-gone.stderr" wrapper_pid wait_status
  env HOME="$HERDR_RUN_HOME" HERDR_RUN_DIR="$HERDR_RUN_DIR" "$HERDR_RUN" state-gone \
    --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait --timeout 10 -- sh -c 'sleep 5' \
    > /dev/null 2> "$stderr_file" &
  wrapper_pid=$!
  wait_for_run_pid "$HERDR_RUN_DIR/state-gone.pid"
  rm -rf "$HERDR_RUN_DIR"

  # #when
  if wait "$wrapper_pid"; then
    wait_status=0
  else
    wait_status=$?
  fi
  # #then
  assert_equal "$wait_status" 125
  assert_file_contains "$stderr_file" "herdr-run: state-gone state directory gone: $HERDR_RUN_DIR"
}

function test_herdr_run_4623_persists_sigterm_as_the_workload_status() {
  _bats_test_init 4623 'persists SIGTERM as the workload status'
  # #given
  local wrapper_pid workload_pid wait_status
  env HOME="$HERDR_RUN_HOME" HERDR_RUN_DIR="$HERDR_RUN_DIR" "$HERDR_RUN" term \
    --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait --timeout 10 -- sh -c 'sleep 2' \
    > /dev/null 2> "$BATS_TEST_TMPDIR/term.stderr" &
  wrapper_pid=$!
  wait_for_run_pid "$HERDR_RUN_DIR/term.pid"
  workload_pid="$(cat "$HERDR_RUN_DIR/term.pid")"
  kill -TERM "$workload_pid"

  # #when
  if wait "$wrapper_pid"; then
    wait_status=0
  else
    wait_status=$?
  fi
  # #then
  assert_equal "$wait_status" 143
  assert_equal "$(cat "$HERDR_RUN_DIR/term.exit")" 143
}

function test_herdr_run_4624_rejects_a_directory_where_the_launch_script_must_be_written() {
  _bats_test_init 4624 'rejects a directory where the launch script must be written'
  # #given
  mkdir -p "$HERDR_RUN_DIR/blocked.sh"

  # #when
  run --separate-stderr herdr_run blocked --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" -- true
  # #then
  assert_failure 2
  assert_stderr "herdr-run: cannot write launch script: $HERDR_RUN_DIR/blocked.sh"
  assert [ ! -e "$HERDR_RUN_DIR/blocked.pid" ]
}
