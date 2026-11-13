# Herdr worktree-identity fixtures. Load after helpers/common.

HWI_ENGINE="$SOURCE_ROOT/dot_local/bin/executable_herdr-worktree-identity"
export HWI_ENGINE

HWI_POSITIVE_WAIT_ATTEMPT_BUDGET=200

hwi_setup() {
  HWI_WORK="$(mktemp -d "${BATS_TMPDIR:-/tmp}/hwi.XXXXXX")"
  HWI_MAIN="$HWI_WORK/main"
  HWI_CHECKOUT="$HWI_WORK/checkout"
  HWI_BRANCH='worktree/quiet-stone-fd75'
  HWI_BIN="$HWI_WORK/bin"
  HWI_NO_APP_BIN="$HWI_WORK/no-app-bin"
  HWI_MODEL_CALLS="$HWI_WORK/model.calls"
  HWI_HERDR_CALLS="$HWI_WORK/herdr.calls"
  HWI_APP_CALLS="$HWI_WORK/herdr-app.calls"
  HWI_BACKGROUND_PIDS=''
  HWI_MODEL_RELEASE=''
  HWI_APP_RELEASE=''
  HWI_LIFECYCLE_RELEASE=''
  HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_WORK/state"
  HWI_SYSTEM_PATH="$(dirname "$(command -v git)"):$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)"):/usr/bin:/bin"
  mkdir -p "$HWI_BIN" "$HWI_NO_APP_BIN" "$HWI_MAIN"
  git -C "$HWI_MAIN" init --quiet -b main
  git -C "$HWI_MAIN" config user.email test@example.invalid
  git -C "$HWI_MAIN" config user.name 'Worktree Identity Test'
  printf 'tracked\n' > "$HWI_MAIN/tracked"
  git -C "$HWI_MAIN" add tracked
  git -C "$HWI_MAIN" commit --quiet -m initial
  git -C "$HWI_MAIN" remote add origin https://example.invalid/repository.git
  git -C "$HWI_MAIN" worktree add --quiet -b "$HWI_BRANCH" "$HWI_CHECKOUT"
  printf '%s\n' "$HWI_BRANCH" > "$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  : > "$HWI_MODEL_CALLS"
  : > "$HWI_HERDR_CALLS"
  : > "$HWI_APP_CALLS"
  hwi_install_stubs
  export HWI_WORK HWI_MAIN HWI_CHECKOUT HWI_BRANCH HWI_BIN HWI_NO_APP_BIN HWI_SYSTEM_PATH HWI_MODEL_CALLS HWI_HERDR_CALLS HWI_APP_CALLS HERDR_WORKTREE_IDENTITY_STATE_DIR
}

hwi_install_stubs() {
  cat > "$HWI_BIN/pi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HWI_MODEL_CALLS"
if [ -e "$HWI_WORK/block-model" ]; then
  : > "$HWI_WORK/model.ready"
  while [ ! -e "$HWI_WORK/model.release" ]; do sleep 0.01; done
fi
cat >/dev/null
printf '%s\n' "${HWI_MODEL_REPLY:-{\"branch\":\"model-task\"}}"
SH
  cat > "$HWI_BIN/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HWI_MODEL_CALLS"
if [ -e "$HWI_WORK/block-model" ]; then
  : > "$HWI_WORK/model.ready"
  while [ ! -e "$HWI_WORK/model.release" ]; do sleep 0.01; done
fi
cat >/dev/null
printf '%s\n' "${HWI_MODEL_REPLY:-{\"branch\":\"model-task\"}}"
SH
  cat > "$HWI_BIN/herdr-app" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HWI_APP_CALLS"
checkout_root="$(git -C "$HWI_CHECKOUT" rev-parse --show-toplevel)"
  case "$1 $2" in
    'ls ')
      if [ -e "$HWI_WORK/block-herdr-app-ls" ]; then
        : > "$HWI_WORK/herdr-app-ls.ready"
        while [ ! -e "$HWI_WORK/herdr-app-ls.release" ]; do sleep 0.01; done
      fi
       if [ -e "$HWI_WORK/no-matching-space" ]; then
         printf '{"spaces":[{"id":"sp-other","name":"other","folder":"%s/other"}]}' "$HWI_CHECKOUT"
       elif [ -e "$HWI_WORK/subdirectory-space-first" ]; then
         printf '{"spaces":[{"id":"sp-subdirectory","name":"subdirectory","folder":"%s/subdirectory"},{"id":"sp-matching","name":"generated","folder":"%s"}]}' "$HWI_CHECKOUT" "$checkout_root"
       else
         printf '{"spaces":[{"id":"sp-matching","name":"generated","folder":"%s"}]}' "$checkout_root"
      fi
    ;;
  'do space.rename')
    [ ! -e "$HWI_WORK/fail-herdr-app" ] || exit 1
    ;;
  esac
SH
  cat > "$HWI_BIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HWI_HERDR_CALLS"
SH
  chmod +x "$HWI_BIN/pi" "$HWI_BIN/claude" "$HWI_BIN/herdr-app" "$HWI_BIN/herdr"
  ln -s "$HWI_BIN/pi" "$HWI_NO_APP_BIN/pi"
  ln -s "$HWI_BIN/claude" "$HWI_NO_APP_BIN/claude"
  ln -s "$HWI_BIN/herdr" "$HWI_NO_APP_BIN/herdr"
}

hwi_install_recording_setsid() {
  HWI_SETSID_CALLS="$HWI_WORK/setsid.calls"
  : > "$HWI_SETSID_CALLS"
  cat > "$HWI_BIN/setsid" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$$" "$*" >> "$HWI_SETSID_CALLS"
exec "$@"
SH
  chmod +x "$HWI_BIN/setsid"
  export HWI_SETSID_CALLS
}

hwi_run_worker() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_WORKSPACE_ID \
    PATH="$HWI_BIN:$PATH" \
    bash "$HWI_ENGINE" --worker --agent pi --session "$1" --cwd "$HWI_CHECKOUT" <<< "$2"
}

hwi_run_foreground() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_WORKSPACE_ID \
    PATH="$HWI_BIN:$PATH" \
    bash "$HWI_ENGINE" --agent pi --session "$1" --cwd "$HWI_CHECKOUT" <<< "$2"
}

hwi_run_worker_without_app() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_WORKSPACE_ID \
    PATH="$HWI_NO_APP_BIN:$HWI_SYSTEM_PATH" \
    bash "$HWI_ENGINE" --worker --agent pi --session "$1" --cwd "$HWI_CHECKOUT" <<< "$2"
}

hwi_branch() {
  git -C "$1" branch --show-current
}

hwi_model_call_count() {
  wc -l < "$HWI_MODEL_CALLS" | tr -d ' '
}

hwi_setsid_call_count() {
  wc -l < "$HWI_SETSID_CALLS" | tr -d ' '
}

hwi_worktree_state_file() {
  find "$HERDR_WORKTREE_IDENTITY_STATE_DIR/repositories" -path '*/worktrees/*.state' -type f -print -quit
}

hwi_state_field() {
  local field="$1" state
  state="$(hwi_worktree_state_file)"
  [ -n "$state" ] || return 1
  bash -c '. "$1"; read_state_field "$2" "$3"' _ \
    "$SOURCE_ROOT/dot_local/lib/herdr-worktree-state.sh" "$state" "$field"
}

hwi_write_worktree_state() {
  local outcome="$1" common root state
  common="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-common-dir)"
  root="$(git -C "$HWI_CHECKOUT" rev-parse --show-toplevel)"
  state="$(bash -c '. "$1"; printf "%s/repositories/%s/worktrees/%s.state" "$HERDR_WORKTREE_IDENTITY_STATE_DIR" "$(encode_key "$2")" "$(encode_key "$3")"' _ \
    "$SOURCE_ROOT/dot_local/lib/herdr-worktree-state.sh" "$common" "$root")"
  bash -c '. "$1"; write_identity_state "$2" checkout_root "$3" repository_anchor "$4" original_branch "$5" branch model-task outcome "$6" authorization authorized title model-task slug model-task' _ \
    "$SOURCE_ROOT/dot_local/lib/herdr-worktree-state.sh" "$state" "$root" "$common" "$HWI_BRANCH" "$outcome"
}

hwi_wait_for_setsid_spawn_window() {
  local attempts="$1" attempt
  for ((attempt = 0; attempt < attempts; attempt += 1)); do
    sleep 0.05
  done
}

hwi_wait_for_setsid_calls() {
  local expected="$1" attempt
  for ((attempt = 0; attempt < HWI_POSITIVE_WAIT_ATTEMPT_BUDGET; attempt += 1)); do
    [ "$(hwi_setsid_call_count)" = "$expected" ] && return 0
    sleep 0.05
  done
  return 1
}

hwi_wait_for_setsid_processes() {
  local attempt pid command all_exited
  for ((attempt = 0; attempt < HWI_POSITIVE_WAIT_ATTEMPT_BUDGET; attempt += 1)); do
    all_exited=1
    while read -r pid command; do
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        all_exited=0
      fi
    done < "$HWI_SETSID_CALLS"
    [ "$all_exited" = 1 ] && return 0
    sleep 0.05
  done
  return 1
}

hwi_stop_setsid_processes() {
  local signal="$1" pid command
  while read -r pid command; do
    [ -z "$pid" ] || kill -"$signal" "$pid" 2>/dev/null || true
  done < "$HWI_SETSID_CALLS"
}

hwi_reap_setsid_processes() {
  hwi_wait_for_setsid_processes && return 0
  hwi_stop_setsid_processes TERM
  hwi_wait_for_setsid_processes && return 0
  hwi_stop_setsid_processes KILL
  hwi_wait_for_setsid_processes
}

hwi_herdr_call_count() {
  wc -l < "$HWI_HERDR_CALLS" | tr -d ' '
}

hwi_app_rename_call_count() {
  awk '$1 == "do" && $2 == "space.rename" { count += 1 } END { print count + 0 }' "$HWI_APP_CALLS"
}

hwi_wait_for_model_calls() {
  local expected="$1" attempt
  for ((attempt = 0; attempt < HWI_POSITIVE_WAIT_ATTEMPT_BUDGET; attempt += 1)); do
    [ "$(hwi_model_call_count)" = "$expected" ] && return 0
    sleep 0.05
  done
  return 1
}

hwi_wait_for_app_rename_calls() {
  local expected="$1" attempt
  for ((attempt = 0; attempt < HWI_POSITIVE_WAIT_ATTEMPT_BUDGET; attempt += 1)); do
    [ "$(hwi_app_rename_call_count)" = "$expected" ] && return 0
    sleep 0.05
  done
  return 1
}

hwi_wait_for_branch() {
  local checkout="$1" expected="$2" attempt
  for ((attempt = 0; attempt < HWI_POSITIVE_WAIT_ATTEMPT_BUDGET; attempt += 1)); do
    [ "$(hwi_branch "$checkout")" = "$expected" ] && return 0
    sleep 0.05
  done
  return 1
}

hwi_wait_for_file() {
  local file="$1" attempt
  for ((attempt = 0; attempt < HWI_POSITIVE_WAIT_ATTEMPT_BUDGET; attempt += 1)); do
    [ -e "$file" ] && return 0
    sleep 0.05
  done
  return 1
}

hwi_start_signal_blocked_worker() {
  local name="$1" launcher="${2:-}" ready blocker
  ready="$HWI_WORK/$name.ready"
  blocker="$HWI_WORK/$name.block"
  mkfifo "$blocker" || return 1
  if [ -n "$launcher" ]; then
    "$launcher" bash -c ': > "$1"; while :; do read -r _ < "$2"; done' _ "$ready" "$blocker" &
  else
    bash -c ': > "$1"; while :; do read -r _ < "$2"; done' _ "$ready" "$blocker" &
  fi
  HWI_SIGNAL_BLOCKED_PID=$!
  if ! hwi_wait_for_file "$ready" || ! kill -0 "$HWI_SIGNAL_BLOCKED_PID" 2>/dev/null; then
    kill -TERM "$HWI_SIGNAL_BLOCKED_PID" 2>/dev/null || true
    wait "$HWI_SIGNAL_BLOCKED_PID" 2>/dev/null || true
    return 1
  fi
}

hwi_wait_for_process_exit() {
  local pid="$1" attempt
  for ((attempt = 0; attempt < HWI_POSITIVE_WAIT_ATTEMPT_BUDGET; attempt += 1)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

hwi_wait_for_process_exit_and_collect() {
  local pid="$1"
  HWI_PROCESS_EXIT_STATUS=''
  if hwi_wait_for_process_exit "$pid"; then
    if wait "$pid"; then HWI_PROCESS_EXIT_STATUS=0; else HWI_PROCESS_EXIT_STATUS=$?; fi
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  if ! hwi_wait_for_process_exit "$pid"; then
    kill -KILL "$pid" 2>/dev/null || true
    hwi_wait_for_process_exit "$pid" || return 2
  fi
  if wait "$pid"; then HWI_PROCESS_EXIT_STATUS=0; else HWI_PROCESS_EXIT_STATUS=$?; fi
  return 1
}

hwi_track_process() {
  HWI_BACKGROUND_PIDS="${HWI_BACKGROUND_PIDS:+$HWI_BACKGROUND_PIDS }$1"
}

hwi_reap_tracked_processes() {
  local pid
  for pid in $HWI_BACKGROUND_PIDS; do
    if ! hwi_wait_for_process_exit "$pid"; then
      kill -TERM "$pid" 2>/dev/null || true
      hwi_wait_for_process_exit "$pid" || kill -KILL "$pid" 2>/dev/null || true
      hwi_wait_for_process_exit "$pid" || return 1
    fi
    wait "$pid" 2>/dev/null || true
  done
}

hwi_lifecycle_claim_files() {
  find "$HERDR_WORKTREE_IDENTITY_STATE_DIR" -type f -name '*.lifecycle.claim' -print 2>/dev/null
}

hwi_wait_for_lifecycle_claims_to_clear() {
  local attempt
  for ((attempt = 0; attempt < HWI_POSITIVE_WAIT_ATTEMPT_BUDGET; attempt += 1)); do
    [ -z "$(hwi_lifecycle_claim_files)" ] && return 0
    sleep 0.05
  done
  return 1
}

hwi_lifecycle_claim_field() {
  local claim="$1" field="$2"
  bash -c '. "$1"; read_state_field "$2" "$3"' _ \
    "$SOURCE_ROOT/dot_local/lib/herdr-worktree-state.sh" "$claim" "$field"
}

hwi_lifecycle_claim_pid() {
  local claim="$1" pid
  pid="$(awk -F= '$1 == "pid" { print $2; exit }' "$claim")"
  case "$pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s' "$pid"
}

hwi_reap_lifecycle_claims() {
  local claims claim pid start format
  hwi_wait_for_lifecycle_claims_to_clear && return 0
  claims="$(hwi_lifecycle_claim_files)"
  while IFS= read -r claim; do
    [ -n "$claim" ] || continue
    pid="$(hwi_lifecycle_claim_pid "$claim")" || return 1
    start="$(hwi_lifecycle_claim_field "$claim" process_start)"
    format="$(hwi_lifecycle_claim_field "$claim" identity_format)"
    if kill -0 "$pid" 2>/dev/null; then
      bash -c '. "$1"; process_start_matches "$2" "$3" "$4"' _ \
        "$SOURCE_ROOT/dot_local/lib/herdr-process.sh" "$pid" "$start" "$format" || return 1
      kill -TERM "$pid" 2>/dev/null || return 1
      hwi_wait_for_process_exit "$pid" || kill -KILL "$pid" 2>/dev/null || return 1
      hwi_wait_for_process_exit "$pid" || return 1
    fi
    rm -f "$claim" || return 1
  done <<< "$claims"
  hwi_wait_for_lifecycle_claims_to_clear
}

hwi_write_lifecycle_claim() {
  local claim="$1" pid="$2" owner start
  owner="test.${pid}"
  start="$(bash -c '. "$1"; process_start_marker "$2"' _ \
    "$SOURCE_ROOT/dot_local/lib/herdr-process.sh" "$pid")" || return 1
  mkdir -p "${claim%/*}" || return 1
  bash -c '. "$1"; printf "owner_id=%s\\npid=%s\\nidentity_format=%s\\nprocess_start=%s\\n" "$(encode_value "$2")" "$3" "$(encode_value ps-lstart-c-utc-v1)" "$(encode_value "$4")" > "$5"' _ \
    "$SOURCE_ROOT/dot_local/lib/herdr-worktree-state.sh" "$owner" "$pid" "$start" "$claim"
}

hwi_release_model_when_torn_down() {
  HWI_MODEL_RELEASE="$1"
}

hwi_release_app_when_torn_down() {
  HWI_APP_RELEASE="$1"
}

hwi_release_lifecycle_when_torn_down() {
  HWI_LIFECYCLE_RELEASE="$1"
}

hwi_teardown() {
  [ -z "${HWI_MODEL_RELEASE:-}" ] || : > "$HWI_MODEL_RELEASE"
  [ -z "${HWI_APP_RELEASE:-}" ] || : > "$HWI_APP_RELEASE"
  [ -z "${HWI_LIFECYCLE_RELEASE:-}" ] || : > "$HWI_LIFECYCLE_RELEASE"
  [ -z "${HWI_SETSID_CALLS:-}" ] || hwi_reap_setsid_processes || return 1
  [ -z "${HWI_BACKGROUND_PIDS:-}" ] || hwi_reap_tracked_processes || return 1
  hwi_reap_lifecycle_claims || return 1
  [[ -z "${HWI_WORK:-}" ]] || rm -rf "$HWI_WORK"
  unset HWI_WORK HWI_MAIN HWI_CHECKOUT HWI_BRANCH HWI_BIN HWI_NO_APP_BIN HWI_SYSTEM_PATH HWI_MODEL_CALLS HWI_HERDR_CALLS HWI_APP_CALLS HWI_SETSID_CALLS HWI_BACKGROUND_PIDS HWI_MODEL_RELEASE HWI_APP_RELEASE HWI_LIFECYCLE_RELEASE HWI_PROCESS_EXIT_STATUS HWI_SIGNAL_BLOCKED_PID HERDR_WORKTREE_IDENTITY_STATE_DIR
}
