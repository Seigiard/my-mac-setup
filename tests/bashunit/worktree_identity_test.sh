#!/usr/bin/env bash
# post-apply: 24 host-safe
# The engine operates directly on an isolated linked Git worktree. Its model
# and Herdr-app executables are the only external boundaries replaced here.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/common'
load 'helpers/herdr_worktree_identity'

setup() {
  hwi_setup
}

teardown() {
  hwi_fixture_teardown
}

function test_worktree_identity_001_first_prompt_renames_an_authorized_generated_worktree() {
  _bats_test_init 1 'first prompt gives an authorized generated worktree the model slug and attribution'

  run hwi_run_worker session-1 'Restore branch naming'

  assert_success
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" 'model-task'
  local marker
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  assert_file_contains "$marker" '^worktree/quiet-stone-fd75$'
  assert_file_contains "$marker" '^Intentional rename by herdr-worktree-identity: worktree/quiet-stone-fd75 -> model-task$'
  assert_equal "$(git -C "$HWI_CHECKOUT" config --get branch.model-task.description)" \
    'Intentional rename by herdr-worktree-identity: worktree/quiet-stone-fd75 -> model-task'
  assert_equal "$(hwi_model_call_count)" 1
  assert_equal "$(hwi_herdr_call_count)" 0
}

function test_worktree_identity_002_declines_unowned_branches_with_a_valid_rename_control() {
  _bats_test_init 2 'missing marker, mismatched marker, upstream, and primary checkout keep their original branches'
  local marker
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"

  rm "$marker"
  run hwi_run_worker no-marker 'Must not rename'
  assert_success
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" "$HWI_BRANCH"

  hwi_teardown
  hwi_setup
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  printf 'someone-else\n' > "$marker"
  run hwi_run_worker mismatched-marker 'Must not rename'
  assert_success
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" "$HWI_BRANCH"

  hwi_teardown
  hwi_setup
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  printf '%s\n' "$HWI_BRANCH" > "$marker"
  git -C "$HWI_MAIN" update-ref refs/remotes/origin/main HEAD
  git -C "$HWI_CHECKOUT" branch --set-upstream-to=origin/main "$HWI_BRANCH"
  run hwi_run_worker upstream 'Must not rename'
  assert_success
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" "$HWI_BRANCH"

  hwi_teardown
  hwi_setup
  run env PATH="$HWI_BIN:$PATH" bash "$HWI_ENGINE" --worker --agent pi --session primary --cwd "$HWI_MAIN" <<< 'Must not rename'
  assert_success
  assert_equal "$(hwi_branch "$HWI_MAIN")" 'main'

  hwi_teardown
  hwi_setup
  run hwi_run_worker valid-control 'Rename control'
  assert_success
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" 'model-task'
}

function test_worktree_identity_003_never_renames_the_same_worktree_twice() {
  _bats_test_init 3 'a second prompt in either session leaves the first slug in place'

  run hwi_run_worker session-1 'First name'
  assert_success
  run hwi_run_worker session-1 'Second name'
  assert_success
  run hwi_run_worker session-2 'Third name'
  assert_success

  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" 'model-task'
  assert_equal "$(hwi_model_call_count)" 1
}

function test_worktree_identity_004_labels_the_matching_space_once_without_undoing_a_branch_rename() {
  _bats_test_init 4 'space rename uses the matching folder and is best effort after branch rename'

  : > "$HWI_WORK/fail-herdr-app"
  run hwi_run_worker failed-app 'Name matching space'
  assert_success
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" 'model-task'
  assert_file_contains "$HWI_APP_CALLS" '^do space.rename --id sp-matching --name model-task$'
  assert_equal "$(hwi_app_rename_call_count)" 1

  hwi_teardown
  hwi_setup
  : > "$HWI_WORK/no-matching-space"
  run hwi_run_worker no-matching-space 'Name without a matching space'
  assert_success
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" 'model-task'
  assert_equal "$(hwi_app_rename_call_count)" 0

  hwi_teardown
  hwi_setup
  rm "$HWI_BIN/herdr-app"
  run hwi_run_worker_without_app missing-app 'Name without herdr-app'
  assert_success
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" 'model-task'
}

function test_worktree_identity_005_claude_hook_passes_its_payload_directory_and_ignores_subagents() {
  _bats_test_init 5 'Claude hook is silent, passes cwd, and excludes subagents'
  local hook="$SOURCE_ROOT/private_dot_claude/hooks/executable_herdr-worktree-identity-hook.sh"
  local engine="$HWI_WORK/claude-engine"
  cat > "$engine" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$HWI_WORK/claude.argv"
cat > "$HWI_WORK/claude.stdin"
SH
  chmod +x "$engine"

  run env -u HERDR_ENV HERDR_WORKTREE_IDENTITY_ENGINE="$HWI_WORK/missing-engine" HWI_WORK="$HWI_WORK" \
    bash "$hook" <<< "{\"session_id\":\"claude-session\",\"prompt\":\"Unavailable engine\",\"cwd\":\"$HWI_CHECKOUT\"}"
  assert_success
  assert_output ''

  run env -u HERDR_ENV HERDR_WORKTREE_IDENTITY_ENGINE="$engine" HWI_WORK="$HWI_WORK" \
    bash "$hook" <<< '{not valid json'
  assert_success
  assert_output ''
  assert_file_not_exists "$HWI_WORK/claude.argv"

  run env -u HERDR_ENV HERDR_WORKTREE_IDENTITY_ACTIVE=1 HERDR_WORKTREE_IDENTITY_ENGINE="$engine" HWI_WORK="$HWI_WORK" \
    bash "$hook" <<< "{\"session_id\":\"claude-session\",\"prompt\":\"Recursion guard\",\"cwd\":\"$HWI_CHECKOUT\"}"
  assert_success
  assert_output ''
  assert_file_not_exists "$HWI_WORK/claude.argv"

  run env -u HERDR_ENV HERDR_WORKTREE_IDENTITY_ENGINE="$engine" HWI_WORK="$HWI_WORK" \
    bash "$hook" <<< "{\"session_id\":\"claude-session\",\"prompt\":\"Claude directory sentinel\",\"cwd\":\"$HWI_CHECKOUT\"}"
  assert_success
  assert_output ''
  run cat "$HWI_WORK/claude.argv"
  assert_success
  assert_output $'--agent\nclaude\n--session\nclaude-session\n--cwd\n'"$HWI_CHECKOUT"
  run cat "$HWI_WORK/claude.stdin"
  assert_success
  assert_output 'Claude directory sentinel'

  run env -u HERDR_ENV HERDR_WORKTREE_IDENTITY_ENGINE="$engine" HWI_WORK="$HWI_WORK" \
    bash "$hook" <<< "{\"session_id\":\"child-session\",\"agent_id\":\"child\",\"prompt\":\"Must not hand off\",\"cwd\":\"$HWI_CHECKOUT\"}"
  assert_success
  run cat "$HWI_WORK/claude.argv"
  assert_success
  assert_output $'--agent\nclaude\n--session\nclaude-session\n--cwd\n'"$HWI_CHECKOUT"
}

function test_worktree_identity_007_foreground_ignores_checkouts_that_cannot_rename_before_spawning_a_model() {
  _bats_test_init 7 'foreground makes no worker detachment without a marker or after a mismatched settled marker'
  local marker
  hwi_install_recording_setsid
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  rm "$marker"

  run hwi_run_foreground session-1 'No marker'
  assert_success
  run hwi_wait_for_setsid_spawn_window 20
  assert_success
  assert_equal "$(hwi_model_call_count)" 0
  assert_equal "$(hwi_setsid_call_count)" 0

  hwi_teardown
  hwi_setup
  hwi_install_recording_setsid
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  printf 'settled-elsewhere\n' > "$marker"
  run hwi_run_foreground session-2 'Mismatched marker'
  assert_success
  run hwi_wait_for_setsid_spawn_window 20
  assert_success
  assert_equal "$(hwi_model_call_count)" 0
  assert_equal "$(hwi_setsid_call_count)" 0

  hwi_teardown
  hwi_setup
  hwi_install_recording_setsid
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  printf '%s\n' "$HWI_BRANCH" > "$marker"
  run hwi_run_foreground control 'Enabled control'
  assert_success
  run hwi_wait_for_model_calls 1
  assert_success
  run hwi_wait_for_branch "$HWI_CHECKOUT" model-task
  assert_success
  run hwi_wait_for_app_rename_calls 1
  assert_success
  assert_equal "$(hwi_model_call_count)" 1
  assert_equal "$(hwi_setsid_call_count)" 1
}

function test_worktree_identity_008_uses_a_free_suffix_and_falls_back_from_an_invalid_model_reply() {
  _bats_test_init 8 'branch collisions suffix the model slug and invalid model output falls back to the prompt slug'
  git -C "$HWI_MAIN" branch model-task

  run hwi_run_worker local-collision 'Collision task'
  assert_success
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" 'model-task-2'

  hwi_teardown
  hwi_setup
  run env HWI_MODEL_REPLY='not json' PATH="$HWI_BIN:$PATH" \
    bash "$HWI_ENGINE" --worker --agent pi --session fallback --cwd "$HWI_CHECKOUT" <<< 'Restore branch naming'
  assert_success
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" 'restore-branch-naming'
}

function test_worktree_identity_0081_avoids_a_remote_tracking_branch_name() {
  _bats_test_init 81 'remote-tracking collision receives the next free suffix'
  git -C "$HWI_MAIN" update-ref refs/remotes/origin/model-task HEAD

  run hwi_run_worker remote-collision 'Remote collision task'

  assert_success
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" 'model-task-2'
}

function test_worktree_identity_014_foreground_exits_before_a_blocked_model_worker_completes() {
  _bats_test_init 14 'foreground returns while its detached worker waits for the model'
  : > "$HWI_WORK/block-model"
  hwi_release_model_when_torn_down "$HWI_WORK/model.release"

  env PATH="$HWI_BIN:$PATH" \
    bash "$HWI_ENGINE" --agent pi --session foreground --cwd "$HWI_CHECKOUT" <<< 'Name after model release' &
  local foreground_pid=$!
  hwi_track_process "$foreground_pid"

  run hwi_wait_for_file "$HWI_WORK/model.ready"
  assert_success
  local foreground_wait_status foreground_status
  if hwi_wait_for_process_exit_and_collect "$foreground_pid"; then foreground_wait_status=0; else foreground_wait_status=$?; fi
  assert_equal "$foreground_wait_status" 0
  foreground_status="$HWI_PROCESS_EXIT_STATUS"
  assert_equal "$foreground_status" 0

  : > "$HWI_WORK/model.release"
  run hwi_wait_for_branch "$HWI_CHECKOUT" model-task
  assert_success
  run hwi_wait_for_app_rename_calls 1
  assert_success
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" 'model-task'
}

function test_worktree_identity_015_two_workers_make_exactly_one_branch_mutation_after_a_lifecycle_barrier() {
  _bats_test_init 15 'two workers contend at the lifecycle claim before either can rename'
  local ready="$HWI_WORK/lifecycle.ready" release="$HWI_WORK/lifecycle.release"
  local attempt_ready="$HWI_WORK/lifecycle-attempt.ready"
  hwi_release_lifecycle_when_torn_down "$release"

  env PATH="$HWI_BIN:$PATH" \
    HERDR_WORKTREE_IDENTITY_TEST_LIFECYCLE_READY="$ready" \
    HERDR_WORKTREE_IDENTITY_TEST_LIFECYCLE_RELEASE="$release" \
    bash "$HWI_ENGINE" --worker --agent pi --session session-1 --cwd "$HWI_CHECKOUT" <<< 'First competing prompt' &
  local first_pid=$!
  hwi_track_process "$first_pid"

  run hwi_wait_for_file "$ready"
  assert_success

  env PATH="$HWI_BIN:$PATH" \
    HERDR_WORKTREE_IDENTITY_TEST_LIFECYCLE_ATTEMPT_READY="$attempt_ready" \
    HERDR_WORKTREE_IDENTITY_LIFECYCLE_CLAIM_ATTEMPTS=1 \
    bash "$HWI_ENGINE" --worker --agent pi --session session-2 --cwd "$HWI_CHECKOUT" <<< 'Second competing prompt' &
  local second_pid=$!
  hwi_track_process "$second_pid"

  run hwi_wait_for_file "$attempt_ready"
  assert_success
  local second_wait_status second_status
  if hwi_wait_for_process_exit_and_collect "$second_pid"; then second_wait_status=0; else second_wait_status=$?; fi
  assert_equal "$second_wait_status" 0
  second_status="$HWI_PROCESS_EXIT_STATUS"
  assert_equal "$second_status" 0
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" "$HWI_BRANCH"

  : > "$release"
  local first_wait_status first_status
  if hwi_wait_for_process_exit_and_collect "$first_pid"; then first_wait_status=0; else first_wait_status=$?; fi
  assert_equal "$first_wait_status" 0
  first_status="$HWI_PROCESS_EXIT_STATUS"
  assert_equal "$first_status" 0
  local marker
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" 'model-task'
  assert_equal "$(git -C "$HWI_CHECKOUT" reflog --format='%gs' model-task | grep -c '^Branch: renamed ')" 1
  assert_equal "$(grep -c '^Intentional rename by herdr-worktree-identity:' "$marker")" 1
}

function test_worktree_identity_016_worker_times_out_a_blocked_herdr_app_after_renaming_the_branch() {
  _bats_test_init 16 'a blocked Herdr app cannot outlive its configured worker timeout'
  : > "$HWI_WORK/block-herdr-app-ls"
  hwi_release_app_when_torn_down "$HWI_WORK/herdr-app-ls.release"

  env PATH="$HWI_BIN:$PATH" HERDR_WORKTREE_IDENTITY_HERDR_TIMEOUT=0.1 \
    bash "$HWI_ENGINE" --worker --agent pi --session bounded-app --cwd "$HWI_CHECKOUT" <<< 'Bound Herdr app call' &
  local worker_pid=$!
  hwi_track_process "$worker_pid"

  run hwi_wait_for_file "$HWI_WORK/herdr-app-ls.ready"
  assert_success
  local worker_wait_status worker_status
  if hwi_wait_for_process_exit_and_collect "$worker_pid"; then worker_wait_status=0; else worker_wait_status=$?; fi
  assert_equal "$worker_wait_status" 0
  worker_status="$HWI_PROCESS_EXIT_STATUS"
  assert_equal "$worker_status" 0
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" 'model-task'
}

function test_worktree_identity_018_declines_an_upstream_branch_before_deriving_or_detaching() {
  _bats_test_init 18 'an upstream worktree is declined once and later prompts do not fork workers'
  git -C "$HWI_MAIN" update-ref refs/remotes/origin/main HEAD
  git -C "$HWI_CHECKOUT" branch --set-upstream-to=origin/main "$HWI_BRANCH"

  run hwi_run_worker upstream-worker 'Do not name a tracked branch'
  assert_success
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" "$HWI_BRANCH"
  assert_equal "$(hwi_state_field outcome)" 'declined'
  assert_equal "$(hwi_model_call_count)" 0

  hwi_install_recording_setsid
  run hwi_run_foreground upstream-foreground-1 'Do not name a tracked branch'
  assert_success
  run hwi_run_foreground upstream-foreground-2 'Do not name a tracked branch'
  assert_success
  run hwi_wait_for_setsid_spawn_window 20
  assert_success
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" "$HWI_BRANCH"
  assert_equal "$(hwi_setsid_call_count)" 0
  assert_equal "$(hwi_model_call_count)" 0

  hwi_teardown
  hwi_setup
  hwi_install_recording_setsid
  printf 'settled-elsewhere\n' > "$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  hwi_write_worktree_state prepared
  run hwi_run_foreground prepared-recovery 'Retry prepared attribution'
  assert_success
  run hwi_wait_for_setsid_spawn_window 20
  assert_success
  assert_equal "$(hwi_setsid_call_count)" 1

  hwi_teardown
  hwi_setup
  hwi_install_recording_setsid
  run hwi_run_foreground matching-control 'Name an authorized branch'
  assert_success
  run hwi_wait_for_model_calls 1
  assert_success
  run hwi_wait_for_setsid_processes
  assert_success
  assert_equal "$(hwi_setsid_call_count)" 1
  assert_equal "$(hwi_model_call_count)" 1
}

function test_worktree_identity_019_declines_a_branch_with_a_pruned_upstream_before_deriving_identity() {
  _bats_test_init 19 'a configured but missing remote-tracking ref is still an upstream'
  git -C "$HWI_MAIN" update-ref refs/remotes/origin/main HEAD
  git -C "$HWI_CHECKOUT" branch --set-upstream-to=origin/main "$HWI_BRANCH"
  git -C "$HWI_MAIN" update-ref -d refs/remotes/origin/main

  run hwi_run_worker pruned-upstream 'Do not name a pruned tracked branch'

  assert_success
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" "$HWI_BRANCH"
  assert_equal "$(hwi_state_field outcome)" 'declined'
  assert_equal "$(hwi_model_call_count)" 0
}

function test_worktree_identity_020_prefers_a_checkout_root_space_over_a_subdirectory_space() {
  _bats_test_init 20 'the app space for the checkout root wins over a matching current subdirectory'
  mkdir "$HWI_CHECKOUT/subdirectory"
  : > "$HWI_WORK/subdirectory-space-first"

  run env PATH="$HWI_BIN:$PATH" bash "$HWI_ENGINE" --worker --agent pi --session root-preferred --cwd "$HWI_CHECKOUT/subdirectory" <<< 'Name the checkout root'

  assert_success
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" 'model-task'
  assert_file_contains "$HWI_APP_CALLS" '^do space.rename --id sp-matching --name model-task$'
  assert_equal "$(hwi_app_rename_call_count)" 1
}

function test_worktree_identity_0201_labels_the_root_space_when_the_agent_starts_in_a_subdirectory() {
  _bats_test_init 201 'a subdirectory cwd still finds the checkout root space'
  mkdir "$HWI_CHECKOUT/subdirectory"

  run env PATH="$HWI_BIN:$PATH" bash "$HWI_ENGINE" --worker --agent pi --session subdirectory-root --cwd "$HWI_CHECKOUT/subdirectory" <<< 'Name the checkout root'

  assert_success
  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" 'model-task'
  assert_file_contains "$HWI_APP_CALLS" '^do space.rename --id sp-matching --name model-task$'
}

function test_worktree_identity_021_labels_a_worktree_space_once_across_two_prompts() {
  _bats_test_init 21 'the completed branch outcome suppresses a second space rename'

  run hwi_run_worker first-prompt 'Name this worktree once'
  assert_success
  run hwi_run_worker second-prompt 'Do not label this worktree again'
  assert_success

  assert_equal "$(hwi_branch "$HWI_CHECKOUT")" 'model-task'
  assert_equal "$(hwi_app_rename_call_count)" 1
}

function test_worktree_identity_023_runs_the_pi_and_opencode_adapter_contracts_in_the_post_apply_path() {
  _bats_test_init 23 'the post-apply worktree suite runs both client adapter contracts'

  run bun test "$BATS_TEST_DIRNAME/pi-herdr-worktree-identity.test.ts" "$BATS_TEST_DIRNAME/opencode-herdr-worktree-identity.test.ts"

  assert_success
}

function test_worktree_identity_024_teardown_reaps_recorded_tracked_and_lifecycle_claim_processes_before_removing_the_fixture() {
  _bats_test_init 24 'fixture teardown bounds worker cleanup before it removes the work directory'
  local work="$HWI_WORK" recorded_pid tracked_pid lifecycle_pid released_pid recorded_alive tracked_alive lifecycle_alive released_alive lifecycle_status
  hwi_install_recording_setsid
  hwi_start_signal_blocked_worker recorded "$HWI_BIN/setsid" || fail 'recorded worker did not reach its blocked state'
  run hwi_wait_for_setsid_calls 1
  assert_success
  recorded_pid="$(awk 'NR == 1 { print $1 }' "$HWI_SETSID_CALLS")"
  hwi_start_signal_blocked_worker tracked || fail 'tracked worker did not reach its blocked state'
  tracked_pid="$HWI_SIGNAL_BLOCKED_PID"
  hwi_track_process "$tracked_pid"
  hwi_start_signal_blocked_worker lifecycle || fail 'lifecycle worker did not reach its blocked state'
  lifecycle_pid="$HWI_SIGNAL_BLOCKED_PID"
  hwi_write_lifecycle_claim "$HERDR_WORKTREE_IDENTITY_STATE_DIR/live.lifecycle.claim" "$lifecycle_pid"

  hwi_teardown

  recorded_alive=0
  kill -0 "$recorded_pid" 2>/dev/null && recorded_alive=1
  tracked_alive=0
  kill -0 "$tracked_pid" 2>/dev/null && tracked_alive=1
  lifecycle_alive=0
  kill -0 "$lifecycle_pid" 2>/dev/null && lifecycle_alive=1
  [ "$lifecycle_alive" = 0 ] || kill -TERM "$lifecycle_pid" 2>/dev/null || true
  if wait "$lifecycle_pid"; then lifecycle_status=0; else lifecycle_status=$?; fi
  kill -TERM "$recorded_pid" "$tracked_pid" 2>/dev/null || true
  wait "$recorded_pid" 2>/dev/null || true
  wait "$tracked_pid" 2>/dev/null || true
  assert_dir_not_exists "$work"
  assert_equal "$recorded_alive" 0
  assert_equal "$tracked_alive" 0
  assert_equal "$lifecycle_alive" 0
  assert_equal "$lifecycle_status" 143

  hwi_setup
  work="$HWI_WORK"
  hwi_start_signal_blocked_worker released || fail 'released worker did not reach its blocked state'
  released_pid="$HWI_SIGNAL_BLOCKED_PID"
  hwi_write_lifecycle_claim "$HERDR_WORKTREE_IDENTITY_STATE_DIR/released.lifecycle.claim" "$released_pid"
  rm "$HERDR_WORKTREE_IDENTITY_STATE_DIR/released.lifecycle.claim"

  hwi_teardown

  released_alive=0
  kill -0 "$released_pid" 2>/dev/null && released_alive=1
  kill -TERM "$released_pid" 2>/dev/null || true
  wait "$released_pid" 2>/dev/null || true
  hwi_release_signal_blocked_worker "$released_pid"
  assert_dir_not_exists "$work"
  assert_equal "$released_alive" 1
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function tear_down() { _bats_run_teardown; }
