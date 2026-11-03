#!/usr/bin/env bash
# post-apply: 29 host-safe
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/common'

setup() {
  HC_RUN="$SOURCE_ROOT/dot_local/bin/executable_hc-run"
  HC_RUN_CWD="$BATS_TEST_TMPDIR/cwd"
  mkdir -p "$HC_RUN_CWD"
  write_hc_stub
  write_herdr_app_stub
  write_aliases_lib
}

write_hc_stub() {
  HC_STUB="$BATS_TEST_TMPDIR/hc-bin"
  HC_STUB_CALLS="$BATS_TEST_TMPDIR/hc.calls"
  HC_STUB_RUN_COUNT="$BATS_TEST_TMPDIR/hc.run-count"
  HC_RUN_EVENT_LOG="$BATS_TEST_TMPDIR/hc-run.events"
  mkdir -p "$HC_STUB"
  : > "$HC_STUB_CALLS"
  : > "$HC_STUB_RUN_COUNT"
  : > "$HC_RUN_EVENT_LOG"
  cat > "$HC_STUB/hc" <<'SH'
#!/usr/bin/env bash
command="$1"
printf '%s' "$1" >> "$HC_STUB_CALLS"
shift
for argument in "$@"; do
  printf ' %s' "$argument" >> "$HC_STUB_CALLS"
done
printf '\n' >> "$HC_STUB_CALLS"
printf 'hc %s' "$command" >> "$HC_RUN_EVENT_LOG"
for argument in "$@"; do
  printf ' %s' "$argument" >> "$HC_RUN_EVENT_LOG"
done
printf '\n' >> "$HC_RUN_EVENT_LOG"

case "$command" in
  ls)
    printf '%s\n' "${HC_STUB_LS_JSON:-{\"hidden_finished\":0,\"terminals\":[]}}"
    ;;
  run)
    count="$(cat "$HC_STUB_RUN_COUNT")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$HC_STUB_RUN_COUNT"
    case "${HC_STUB_RUN_PLAN:-success}:$count" in
      name_taken,success:1)
        printf '%s\n' '{"error":{"kind":"name_taken"}}' >&2
        exit 1
        ;;
      invalid_params:*)
        printf '%s\n' '{"error":{"kind":"invalid_params"}}' >&2
        exit 6
        ;;
    esac
    alias=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --name ]; then
        alias="$2"
        break
      fi
      shift
    done
    printf '{"address":"t11","agent":"sleep","cwd":"/tmp","name":"%s","state":"live","turn":0}\n' "$alias"
    ;;
esac
SH
  chmod +x "$HC_STUB/hc"
  export HC_STUB_CALLS HC_STUB_RUN_COUNT HC_RUN_EVENT_LOG
}

write_herdr_app_stub() {
  HERDR_APP_STUB="$BATS_TEST_TMPDIR/herdr-app-bin"
  HERDR_APP_STUB_CALLS="$BATS_TEST_TMPDIR/herdr-app.calls"
  mkdir -p "$HERDR_APP_STUB"
  : > "$HERDR_APP_STUB_CALLS"
  cat > "$HERDR_APP_STUB/herdr-app" <<'SH'
#!/usr/bin/env bash
command="$1"
printf '%s' "$command" >> "$HERDR_APP_STUB_CALLS"
shift
for argument in "$@"; do
  printf ' %s' "$argument" >> "$HERDR_APP_STUB_CALLS"
done
printf '\n' >> "$HERDR_APP_STUB_CALLS"
printf 'herdr-app %s' "$command" >> "$HC_RUN_EVENT_LOG"
for argument in "$@"; do
  printf ' %s' "$argument" >> "$HC_RUN_EVENT_LOG"
done
printf '\n' >> "$HC_RUN_EVENT_LOG"
printf '%s\n' '{"space":"w1","tab":"tab1","terminal":"t12"}'
SH
  chmod +x "$HERDR_APP_STUB/herdr-app"
  export HERDR_APP_STUB_CALLS
}

write_aliases_lib() {
  HC_RUN_ALIASES_LIB="$BATS_TEST_TMPDIR/herdr-aliases.sh"
  cat > "$HC_RUN_ALIASES_LIB" <<'SH'
HERDR_ALIAS_COLORS=(red blue green)
HERDR_ALIAS_ANIMALS=(wolf fox otter)
herdr_alias_candidates() {
  printf '%s\n' red-wolf blue-fox green-otter
}
SH
  export HC_RUN_ALIASES_LIB
}

hc_run() {
  env PATH="$HC_STUB:$HERDR_APP_STUB:$PATH" HC_RUN_ALIASES_LIB="$HC_RUN_ALIASES_LIB" "$HC_RUN" "$@"
}

hc_run_from() {
  local cwd="$1"
  shift
  (
    cd "$cwd" || exit 1
    hc_run "$@"
  )
}

function test_hc_run_4701_skips_live_names_and_starts_the_first_free_alias_from_the_default_directory() {
  _bats_test_init 4701 'skips live names and starts the first free alias from the default directory'
  # #given
  local live_names='{"hidden_finished":0,"terminals":[{"address":"t1","agent":"sleep","cwd":"/tmp","state":"live","turn":0,"name":"red-wolf"},{"address":"t2","agent":"sleep","cwd":"/tmp","state":"live","turn":0}]}'
  export HC_STUB_LS_JSON="$live_names"

  # #when
  run --separate-stderr hc_run_from "$HC_RUN_CWD" planner 'write report'
  # #then
  assert_success
  assert_output 't11 blue-fox'
  assert_stderr ''
  assert_equal "$(cat "$HC_STUB_CALLS")" "ls --json
run --bg --name blue-fox --cwd $HC_RUN_CWD planner write report"
  assert_equal "$(cat "$HERDR_APP_STUB_CALLS")" ''
}

function test_hc_run_4702_uses_the_requested_directory_in_the_hc_run_argv() {
  _bats_test_init 4702 'uses the requested directory in the hc run argv'
  # #given
  local requested_cwd="$BATS_TEST_TMPDIR/requested cwd"
  mkdir -p "$requested_cwd"

  # #when
  run --separate-stderr hc_run --cwd "$requested_cwd" planner 'write report'
  # #then
  assert_success
  assert_output 't11 red-wolf'
  assert_stderr ''
  assert_equal "$(cat "$HC_STUB_CALLS")" "ls --json
run --bg --name red-wolf --cwd $requested_cwd planner write report"
}

function test_hc_run_4703_retries_the_next_free_alias_after_hc_reports_name_taken() {
  _bats_test_init 4703 'retries the next free alias after hc reports name taken'
  # #given
  local run_plan=name_taken,success

  # #when
  run --separate-stderr env HC_STUB_RUN_PLAN="$run_plan" PATH="$HC_STUB:$HERDR_APP_STUB:$PATH" \
    HC_RUN_ALIASES_LIB="$HC_RUN_ALIASES_LIB" "$HC_RUN" --cwd "$HC_RUN_CWD" planner 'write report'
  # #then
  assert_success
  assert_output 't11 blue-fox'
  assert_stderr ''
  assert_equal "$(cat "$HC_STUB_CALLS")" "ls --json
run --bg --name red-wolf --cwd $HC_RUN_CWD planner write report
run --bg --name blue-fox --cwd $HC_RUN_CWD planner write report"
}

function test_hc_run_4704_rejects_missing_template_or_task_without_calling_hc() {
  _bats_test_init 4704 'rejects missing template or task without calling hc'
  # #given
  local usage='usage: hc-run [--cwd DIR] [--tab] <template> <task>'

  # #when
  run --separate-stderr hc_run
  # #then
  assert_failure 2
  assert_output ''
  assert_stderr "$usage"
  assert_equal "$(cat "$HC_STUB_CALLS")" ''

  : > "$HC_STUB_CALLS"
  run --separate-stderr hc_run planner
  assert_failure 2
  assert_output ''
  assert_stderr "$usage"
  assert_equal "$(cat "$HC_STUB_CALLS")" ''
}

function test_hc_run_4705_passes_through_a_non_name_taken_hc_failure() {
  _bats_test_init 4705 'passes through a non name taken hc failure'
  # #given
  local error='{"error":{"kind":"invalid_params"}}'

  # #when
  run --separate-stderr env HC_STUB_RUN_PLAN=invalid_params PATH="$HC_STUB:$HERDR_APP_STUB:$PATH" \
    HC_RUN_ALIASES_LIB="$HC_RUN_ALIASES_LIB" "$HC_RUN" --cwd "$HC_RUN_CWD" planner 'write report'
  # #then
  assert_failure 6
  assert_output ''
  assert_stderr "$error"
  assert_equal "$(cat "$HC_STUB_CALLS")" "ls --json
run --bg --name red-wolf --cwd $HC_RUN_CWD planner write report"
}

function test_hc_run_4706_rejects_a_missing_aliases_library_without_starting_a_child() {
  _bats_test_init 4706 'rejects a missing aliases library without starting a child'
  # #given
  local missing_lib="$BATS_TEST_TMPDIR/missing-herdr-aliases.sh"

  # #when
  run --separate-stderr env PATH="$HC_STUB:$HERDR_APP_STUB:$PATH" HC_RUN_ALIASES_LIB="$missing_lib" \
    "$HC_RUN" --cwd "$HC_RUN_CWD" planner 'write report'
  # #then
  assert_failure 1
  assert_output ''
  assert_stderr "hc-run: aliases library not found: $missing_lib"
  assert_equal "$(sed -n '/^run /p' "$HC_STUB_CALLS")" ''
}

function test_hc_run_4707_opens_an_attach_tab_after_starting_the_named_child() {
  _bats_test_init 4707 'opens an attach tab after starting the named child'
  # #given
  local tab_request='{"name":"red-wolf","argv":["hc","attach","t11"]}'

  # #when
  run --separate-stderr hc_run --tab --cwd "$HC_RUN_CWD" planner 'write report'
  # #then
  assert_success
  assert_output 't11 red-wolf'
  assert_stderr ''
  assert_equal "$(cat "$HC_STUB_CALLS")" "ls --json
run --bg --name red-wolf --cwd $HC_RUN_CWD planner write report"
  assert_equal "$(cat "$HERDR_APP_STUB_CALLS")" "do tab.new $tab_request"
  assert_equal "$(cat "$HC_RUN_EVENT_LOG")" "hc ls --json
hc run --bg --name red-wolf --cwd $HC_RUN_CWD planner write report
herdr-app do tab.new $tab_request"
}
