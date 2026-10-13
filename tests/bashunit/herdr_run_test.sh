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

state_directory_is_empty() {
  [ ! -e "$HERDR_RUN_DIR" ] && return 0
  [ -d "$HERDR_RUN_DIR" ] || return 1
  [ -z "$(find "$HERDR_RUN_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

write_marker_observer() {
  local observer="$1"
  cat > "$observer" <<'SH'
#!/usr/bin/env bash
exit_file="$1"
marker="$2"
while IFS= read -r line; do
  if [ "$line" = "$marker" ] && [ ! -s "$exit_file" ]; then
    exit 1
  fi
  printf '%s\n' "$line"
done
SH
  chmod +x "$observer"
}

function test_herdr_run_4601_inline_wait_returns_the_inner_status_and_records_it() {
  _bats_test_init 4601 'inline wait returns the inner status and records it'
  # #given
  # #when
  run herdr_run failed --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait -- sh -c 'exit 3'
  # #then
  assert_failure 3
  assert_equal "$(cat "$HERDR_RUN_DIR/failed.exit")" 3

  run herdr_run succeeded --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait -- sh -c 'exit 0'
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
  run herdr_run clean --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait -- sh -c 'printf "out\n"; printf "err\n" >&2'
  # #then
  assert_success
  assert_equal "$(cat "$HERDR_RUN_DIR/clean.log")" $'out\nerr'
  assert_file_contains "$HERDR_RUN_DIR/clean.meta" '^start=[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$'
  assert_file_contains "$HERDR_RUN_DIR/clean.meta" "^head=$head$"
  assert_file_contains "$HERDR_RUN_DIR/clean.meta" '^dirty=0$'
  assert_file_contains "$HERDR_RUN_DIR/clean.meta" "^cwd=$HERDR_RUN_CWD$"

  printf 'untracked\n' > "$HERDR_RUN_CWD/untracked"
  run herdr_run dirty --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait -- sh -c 'exit 0'
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
  local observer="$BATS_TEST_TMPDIR/observe-marker"
  write_marker_observer "$observer"
  rm -f "$HERDR_RUN_DIR/marker.exit" "$HERDR_RUN_DIR/marker.log"

  # #when
  run bash -c 'set -o pipefail; bash "$1" | bash "$2" "$3" "$4"' _ \
    "$HERDR_RUN_DIR/marker.sh" "$observer" "$HERDR_RUN_DIR/marker.exit" 'herdr-run: marker exit=3'
  # #then
  assert_failure 3
  assert_output 'herdr-run: marker exit=3'
  assert_equal "$(cat "$HERDR_RUN_DIR/marker.exit")" 3
  assert_equal "$(cat "$HERDR_RUN_DIR/marker.log")" ''
}

function test_herdr_run_4604_sets_the_launch_environment_and_changes_to_the_requested_directory() {
  _bats_test_init 4604 'sets the launch environment and changes to the requested directory'
  # #given
  # #when
  run herdr_run My.Label --dir "$HERDR_RUN_DIR" --cwd "$HERDR_RUN_CWD" --wait -- \
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
  printf '\342\234\227 first\n\342\234\227 second\nFailed third\n\033[31m\342\234\227 fourth\033[0m\npassed \342\234\223\n' > "$HERDR_RUN_DIR/report.log"
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

  run --separate-stderr herdr_run missing --dir "$HERDR_RUN_DIR" --wait true
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
