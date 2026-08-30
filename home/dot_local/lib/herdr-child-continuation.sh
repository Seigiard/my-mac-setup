# shellcheck shell=bash
# Requires: runtime, supervision, and entrypoint configuration globals.
# Owns: ask, reply, prompt, callback receipt, and continuation handoff.

wait_for_fresh_settlement() {
  local pane="$1" baseline_seq="$2" baseline_status="$3" child_terminal="$4" child_session="$5" timeout="$6"
  local deadline snapshot_json snapshot status seq terminal session observed_pane
  local observed_new_working=0
  deadline=$(( $(now_ms) + timeout ))
  while :; do
    snapshot_json="$(herdr agent get "$pane" 2>/dev/null)" || return 1
    snapshot="$(printf '%s' "$snapshot_json" | json_agent_snapshot)" || return 1
    IFS=$'\t' read -r status seq terminal session _ observed_pane <<EOF
$snapshot
EOF
    [ "$terminal" = "$child_terminal" ] && [ "$session" = "$child_session" ] && [ "$observed_pane" = "$pane" ] || return 1
    if [ "$seq" -gt "$baseline_seq" ]; then
      [ "$status" != working ] || observed_new_working=1
      case "$status" in
        idle|done|blocked)
          if [ "$baseline_status" != working ] || [ "$observed_new_working" -eq 1 ] || [ "$seq" -gt $((baseline_seq + 1)) ]; then
            return 0
          fi
          ;;
      esac
    fi
    [ "$(now_ms)" -lt "$deadline" ] || return 124
    sleep "$POLL_INTERVAL"
  done
}

managed_detached_prompt() {
  local name="$1" pane="$2" text="$3" supervision_timeout="$4"
  local parent_terminal="$5" parent_session="$6" child_terminal="$7" child_session="$8"
  local old_generation="${9:-}"
  local baseline_json baseline_snapshot baseline_seq generation run_dir self watcher_pid
  local prompt_out prompt_err prompt_pid="" prompt_status takeover_complete=0

  [ "${HERDR_CHILD_TEST_BASELINE_FAIL:-0}" != 1 ] || {
    printf 'herdr-child: child baseline state could not be read before detached prompt\n' >&2
    return 1
  }
  baseline_json="$(herdr agent get "$pane")" || {
    printf 'herdr-child: child baseline state could not be read before detached prompt\n' >&2
    return 1
  }
  baseline_snapshot="$(printf '%s' "$baseline_json" | json_agent_snapshot)" || {
    printf 'herdr-child: child baseline state was malformed before detached prompt\n' >&2
    return 1
  }
  local baseline_terminal baseline_session baseline_pane
  IFS=$'\t' read -r _ baseline_seq baseline_terminal baseline_session _ baseline_pane <<EOF
$baseline_snapshot
EOF
  if [ "$baseline_terminal" != "$child_terminal" ] || [ "$baseline_session" != "$child_session" ] || [ "$baseline_pane" != "$pane" ]; then
    printf 'herdr-child: child identity changed before detached prompt\n' >&2
    return 1
  fi

  generation="$(generation_nonce)" || {
    printf 'herdr-child: could not generate a continuation supervision identity\n' >&2
    return 1
  }
  umask 077
  mkdir -p "$STATE_DIR/runs" || return 1
  chmod 700 "$STATE_DIR" "$STATE_DIR/runs" 2>/dev/null || true
  run_dir="$STATE_DIR/runs/$generation"
  mkdir "$run_dir" || return 1
  write_launch_state "$run_dir/launch.state" "$generation" "$supervision_timeout" \
    "$HERDR_PANE_ID" "$parent_terminal" "$parent_session" "$name" "$pane" \
    "$child_terminal" "$child_session" "$baseline_seq" || { remove_supervision_run "$run_dir"; return 1; }
  if [ "${HERDR_CHILD_TEST_SETUP_FAIL:-0}" = 1 ]; then
    remove_supervision_run "$run_dir"
    printf 'herdr-child: detached continuation setup failed before supervision takeover\n' >&2
    return 1
  fi

  self="$(script_path)" || { remove_supervision_run "$run_dir"; return 1; }
  set -m
  nohup bash "$self" __watcher --run-dir "$run_dir" --pane "$pane" \
    --generation "$generation" --timeout "$supervision_timeout" \
    --launcher-pid "$$" --deferred-activation </dev/null >/dev/null 2>&1 &
  watcher_pid=$!
  set +m
  set +e
  wait_for_watcher_state "$run_dir/prepared.state" "$run_dir/failed.state" "$watcher_pid"
  local prepared_status=$?
  set -e
  if [ "$prepared_status" -ne 0 ]; then
    local prepared_reason="watcher-readiness-failed"
    [ "$prepared_status" -ne 2 ] || prepared_reason="$(supervision_reason "$run_dir/failed.state")"
    stop_owned_watcher "$run_dir" "$watcher_pid" "$prepared_reason"
    printf 'herdr-child: detached continuation watcher failed before supervision takeover: %s\n' "$prepared_reason" >&2
    return 1
  fi

  continuation_signal_handler() {
    local signal="$1" status=1 reason="continuation-signal-$1" abort_status
    case "$signal" in HUP) status=129 ;; INT) status=130 ;; TERM) status=143 ;; esac
    [ -z "$prompt_pid" ] || kill -TERM "$prompt_pid" 2>/dev/null || true
    [ -z "$prompt_pid" ] || wait "$prompt_pid" 2>/dev/null || true
    if [ "$takeover_complete" -eq 0 ]; then
      stop_owned_watcher "$run_dir" "$watcher_pid" "$reason"
      printf 'herdr-child: %s before supervision takeover; prior supervision remains active\n' "$signal" >&2
    else
      set +e
      request_watcher_abort "$run_dir" "$reason"
      abort_status=$?
      set -e
      if [ "$abort_status" -eq 0 ]; then
        print_start_result "$name" "$pane" "" "$generation" "$supervision_timeout"
      else
        report_signal_supervision "$name" "$pane" "" "$run_dir" "$generation" "$supervision_timeout" "$reason" "$watcher_pid"
      fi
    fi
    trap - HUP INT TERM
    exit "$status"
  }
  trap 'continuation_signal_handler HUP' HUP
  trap 'continuation_signal_handler INT' INT
  trap 'continuation_signal_handler TERM' TERM

  if ! metadata_report "$pane" --source "$SOURCE_ID" --clear-state-labels \
    --token 'child_mode=detach' --token "supervision_generation=$generation" \
    --token "supervision_timeout=$supervision_timeout" \
    --token "supervision_baseline_seq=$baseline_seq" \
    --token "parent_terminal=$parent_terminal" --token "parent_session=$parent_session" \
    --token "child_terminal=$child_terminal" --token "child_session=$child_session" \
    --clear-token supervision_failure_reason --clear-token supervision_failure_generation \
    --clear-token supervision_failure_diagnostic >/dev/null; then
    stop_owned_watcher "$run_dir" "$watcher_pid" metadata-publish-failed
    printf 'herdr-child: detached continuation metadata could not be published\n' >&2
    trap - HUP INT TERM
    return 1
  fi
  if [ -n "${HERDR_CHILD_TEST_TAKEOVER_METADATA_PUBLISHED:-}" ]; then
    : > "$HERDR_CHILD_TEST_TAKEOVER_METADATA_PUBLISHED"
  fi
  takeover_complete=1
  if ! invalidate_generation "$old_generation" managed-continuation; then
    publish_supervision_recovery "$name" "$pane" "$generation" handoff-invalidation-failed "$run_dir" "$watcher_pid"
    trap - HUP INT TERM
    return 1
  fi
  if ! atomic_write "$run_dir/takeover.state" 'takeover=1'; then
    publish_supervision_recovery "$name" "$pane" "$generation" takeover-write-failed "$run_dir" "$watcher_pid"
    trap - HUP INT TERM
    return 1
  fi
  set +e
  wait_for_watcher_state "$run_dir/ready.state" "$run_dir/failed.state" "$watcher_pid"
  local ready_status=$?
  set -e
  if [ "$ready_status" -ne 0 ]; then
    local ready_reason="watcher-unavailable"
    [ "$ready_status" -ne 2 ] || ready_reason="$(supervision_reason "$run_dir/failed.state")"
    printf 'herdr-child: detached continuation takeover failed during activation; child preserved for recovery\n' >&2
    publish_supervision_recovery "$name" "$pane" "$generation" "$ready_reason" "$run_dir" "$watcher_pid"
    trap - HUP INT TERM
    return 1
  fi
  prompt_out="$(mktemp)"
  prompt_err="$(mktemp)"
  set +e
  herdr agent prompt "$name" "$text" >"$prompt_out" 2>"$prompt_err" &
  prompt_pid=$!
  wait "$prompt_pid"
  prompt_status=$?
  set -e
  rm -f "$prompt_out" "$prompt_err"
  if [ "$prompt_status" -ne 0 ]; then
    atomic_write "$run_dir/abort.state" 'reason=prompt-result-ambiguous' || true
    wait_for_watcher_state "$run_dir/failed.state" "" "$watcher_pid" || true
    print_supervision_failure "$name" "$pane" "$generation" prompt-result-ambiguous "$generation"
    trap - HUP INT TERM
    return "$prompt_status"
  fi
  if ! atomic_write "$run_dir/accepted.state" 'accepted=1'; then
    atomic_write "$run_dir/abort.state" 'reason=acceptance-write-failed' || true
    wait_for_watcher_state "$run_dir/failed.state" "" "$watcher_pid" || true
    print_supervision_failure "$name" "$pane" "$generation" acceptance-write-failed "$generation"
    trap - HUP INT TERM
    return 1
  fi
  set +e
  wait_for_watcher_state "$run_dir/armed.state" "$run_dir/failed.state" "$watcher_pid"
  local arm_status=$?
  set -e
  if [ "$arm_status" -ne 0 ]; then
    local arm_reason="watcher-unavailable"
    [ "$arm_status" -ne 2 ] || arm_reason="$(supervision_reason "$run_dir/failed.state")"
    print_supervision_failure "$name" "$pane" "$generation" "$arm_reason" "$generation"
    trap - HUP INT TERM
    return 1
  fi
  trap - HUP INT TERM
  print_start_result "$name" "$pane" "" "$generation" "$supervision_timeout"
}

persist_callback_state() {
  local run_dir="$1" status="$2" event="$3"
  [ -d "$run_dir" ] || return 1
  atomic_write "$run_dir/callback.state" "status=$status
event=$event"
}

ask_parent() {
  require_herdr
  [ $# -eq 1 ] || fail_usage 'ask requires one question argument'
  [ -n "${HERDR_CHILD_NAME:-}" ] || { printf 'herdr-child: HERDR_CHILD_NAME is missing\n' >&2; exit 1; }
  [ -n "${HERDR_CHILD_PARENT_PANE:-}" ] || { printf 'herdr-child: HERDR_CHILD_PARENT_PANE is missing\n' >&2; exit 1; }
  [ -n "${HERDR_PANE_ID:-}" ] || { printf 'herdr-child: HERDR_PANE_ID is missing\n' >&2; exit 1; }

  local seq list_json message parent_pane="$HERDR_CHILD_PARENT_PANE" event
  local pane_json context pane_terminal pane_session mode generation run_dir
  local supervision_timeout stored_parent_terminal stored_parent_session
  local stored_child_terminal stored_child_session route_terminal="" route_session=""
  seq="$(metadata_report "$HERDR_PANE_ID" --source "$SOURCE_ID" \
    --state-label 'blocked=waiting for parent' --ttl-ms "$WAITING_TTL_MS")"

  pane_json="$(herdr pane get "$HERDR_PANE_ID" 2>/dev/null || true)"
  context="$(printf '%s' "$pane_json" | json_child_context 2>/dev/null || true)"
  IFS=$'\t' read -r pane_terminal pane_session mode generation supervision_timeout \
    stored_parent_terminal stored_parent_session stored_child_terminal stored_child_session <<EOF
$context
EOF
  event="callback-$seq"
  if [ "$mode" = detach ] || [ -n "$generation" ] || [ -n "$stored_parent_terminal" ] || \
     [ -n "$stored_parent_session" ] || [ -n "$stored_child_terminal" ] || [ -n "$stored_child_session" ]; then
    if [ "$mode" != detach ] || [ -z "$generation" ] || [ -z "$stored_parent_terminal" ] || \
       [ -z "$stored_parent_session" ] || [ -z "$stored_child_terminal" ] || [ -z "$stored_child_session" ] || \
       [ "$pane_terminal" != "$stored_child_terminal" ] || [ "$pane_session" != "$stored_child_session" ]; then
      printf 'herdr-child: detached child metadata is unavailable or inconsistent; waiting label remains published\n' >&2
      exit 1
    fi
    run_dir="$STATE_DIR/runs/$generation"
    if [ "$(state_value "$run_dir/launch.state" generation)" != "$generation" ] || \
       [ "$(state_value "$run_dir/launch.state" parent_terminal)" != "$stored_parent_terminal" ] || \
       [ "$(state_value "$run_dir/launch.state" parent_session)" != "$stored_parent_session" ] || \
       [ "$(state_value "$run_dir/launch.state" child_terminal)" != "$stored_child_terminal" ] || \
       [ "$(state_value "$run_dir/launch.state" child_session)" != "$stored_child_session" ]; then
      printf 'herdr-child: detached child supervision state is unavailable or inconsistent; waiting label remains published\n' >&2
      exit 1
    fi
    if { [ -n "${HERDR_CHILD_PARENT_TERMINAL:-}" ] || [ -n "${HERDR_CHILD_PARENT_SESSION:-}" ]; } && \
       { [ "${HERDR_CHILD_PARENT_TERMINAL:-}" != "$stored_parent_terminal" ] || \
         [ "${HERDR_CHILD_PARENT_SESSION:-}" != "$stored_parent_session" ]; }; then
      printf 'herdr-child: captured parent identity conflicts with detached metadata; waiting label remains published\n' >&2
      exit 1
    fi
    route_terminal="$stored_parent_terminal"
    route_session="$stored_parent_session"
    if ! persist_callback_state "$run_dir" in-progress "$event"; then
      printf 'herdr-child: callback intent could not be persisted; waiting label remains published\n' >&2
      exit 1
    fi
    message="[child-ask v2 generation=$generation event=$event agent=$HERDR_CHILD_NAME pane=$HERDR_PANE_ID]

$1"
  else
    if [ "${HERDR_CHILD_LAUNCH_MODE:-}" = detach ] || \
       { [ -z "${HERDR_CHILD_LAUNCH_MODE:-}" ] && [ -n "${HERDR_CHILD_PARENT_TERMINAL:-}" ]; }; then
      printf 'herdr-child: detached child metadata is unavailable; waiting label remains published\n' >&2
      exit 1
    fi
    run_dir=""
    if [ -n "${HERDR_CHILD_PARENT_TERMINAL:-}" ] || [ -n "${HERDR_CHILD_PARENT_SESSION:-}" ]; then
      if [ -z "${HERDR_CHILD_PARENT_TERMINAL:-}" ] || [ -z "${HERDR_CHILD_PARENT_SESSION:-}" ]; then
        printf 'herdr-child: captured parent identity is incomplete; waiting label remains published\n' >&2
        exit 1
      fi
      route_terminal="$HERDR_CHILD_PARENT_TERMINAL"
      route_session="$HERDR_CHILD_PARENT_SESSION"
    fi
    message="[child-ask v1 agent=$HERDR_CHILD_NAME pane=$HERDR_PANE_ID]

$1"
  fi
  list_json="$(herdr agent list)" || {
    [ -z "$run_dir" ] || persist_callback_state "$run_dir" failed "$event" || true
    printf 'herdr-child: parent lookup failed; waiting label remains published\n' >&2
    exit 1
  }
  if [ -n "$route_terminal" ]; then
    set +e
    local parent_record
    parent_record="$(printf '%s' "$list_json" | json_resolve_parent \
      "$route_terminal" "$route_session")"
    local parent_status=$?
    set -e
    [ "$parent_status" -eq 0 ] || {
      persist_callback_state "$run_dir" failed "$event" || true
      printf 'herdr-child: captured parent identity could not be resolved; waiting label remains published\n' >&2
      exit 1
    }
    IFS=$'\t' read -r parent_pane _ <<EOF
$parent_record
EOF
  elif ! printf '%s' "$list_json" | python3 -c 'import json,sys
pane=sys.argv[1]
agents=json.load(sys.stdin).get("result",{}).get("agents",[])
raise SystemExit(0 if any(a.get("pane_id")==pane for a in agents) else 1)' "$HERDR_CHILD_PARENT_PANE"; then
      printf 'herdr-child: no live parent occupies pane %s; waiting label remains published\n' "$HERDR_CHILD_PARENT_PANE" >&2
      exit 1
  fi
  if ! herdr agent prompt "$parent_pane" "$message" >/dev/null; then
    [ -z "$run_dir" ] || persist_callback_state "$run_dir" failed "$event" || true
    printf 'herdr-child: delivery to parent failed; waiting label remains published\n' >&2
    exit 1
  fi
  if [ -n "$run_dir" ]; then
    if [ -n "${HERDR_CHILD_TEST_CALLBACK_RECEIPT_BARRIER:-}" ]; then
      : > "$HERDR_CHILD_TEST_CALLBACK_RECEIPT_BARRIER.ready"
      while [ ! -e "$HERDR_CHILD_TEST_CALLBACK_RECEIPT_BARRIER.release" ]; do sleep 0.01; done
    fi
    if ! persist_callback_state "$run_dir" confirmed "$event"; then
      persist_callback_state "$run_dir" failed "$event" || rm -f "$run_dir/callback.state" 2>/dev/null || true
      printf 'herdr-child: callback receipt was not persisted; an exact duplicate may arrive\n' >&2
    fi
  fi
  printf 'Question delivered. End this turn and wait for the parent reply.\n'
}

prompt_child() {
  require_parent
  local name="" pane="" text="" mode="" mode_count=0 timeout=30000
  local supervision_timeout="$DEFAULT_SUPERVISION_TIMEOUT" supervision_timeout_set=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) [ $# -ge 2 ] || fail_usage '--to needs a value'; name="$2"; shift 2 ;;
      --pane) [ $# -ge 2 ] || fail_usage '--pane needs a value'; pane="$2"; shift 2 ;;
      --wait|--detach)
        [ "$mode_count" -eq 0 ] || fail_usage 'prompt requires exactly one of --wait or --detach'
        mode="${1#--}"; mode_count=1; shift ;;
      --timeout) [ $# -ge 2 ] || fail_usage '--timeout needs a value'; timeout="$2"; shift 2 ;;
      --supervision-timeout) [ $# -ge 2 ] || fail_usage '--supervision-timeout needs a value'; supervision_timeout="$2"; supervision_timeout_set=1; shift 2 ;;
      --*) fail_usage "unknown prompt option: $1" ;;
      *) [ -z "$text" ] || fail_usage 'prompt accepts one task argument'; text="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || fail_usage 'prompt requires --to'
  [ -n "$pane" ] || fail_usage 'prompt requires --pane'
  [ -n "$text" ] || fail_usage 'prompt requires a task'
  [ "$mode_count" -eq 1 ] || fail_usage 'prompt requires exactly one of --wait or --detach'
  case "$timeout" in '' | 0 | *[!0-9]*) fail_usage '--timeout must be a positive integer' ;; esac
  if [ "$mode" = wait ] && [ "$supervision_timeout_set" -eq 1 ]; then
    fail_usage '--supervision-timeout requires --detach'
  fi
  case "$supervision_timeout" in '' | 0 | *[!0-9]*) fail_usage '--supervision-timeout must be between 1 and 86400000 milliseconds' ;; esac
  [ "$supervision_timeout" -le "$MAX_SUPERVISION_TIMEOUT" ] || \
    fail_usage '--supervision-timeout must be between 1 and 86400000 milliseconds'

  local list_json child_identity parent_identity child_terminal child_session
  local parent_terminal parent_session pane_json context old_mode old_generation
  list_json="$(herdr agent list)" || { printf 'herdr-child: could not list children\n' >&2; return 1; }
  printf '%s' "$list_json" | json_has_pair "$name" "$pane" || {
    printf 'herdr-child: child name and pane do not identify the same live agent\n' >&2
    return 1
  }
  child_identity="$(printf '%s' "$list_json" | json_identity_for_pane "$pane")" || {
    printf 'herdr-child: child identity is unavailable or ambiguous\n' >&2
    return 1
  }
  IFS=$'\t' read -r child_terminal child_session <<EOF
$child_identity
EOF
  [ -n "$child_session" ] || { printf 'herdr-child: child agent_session is unavailable\n' >&2; return 1; }
  pane_json="$(herdr pane get "$pane")" || { printf 'herdr-child: child pane metadata could not be read\n' >&2; return 1; }
  context="$(printf '%s' "$pane_json" | json_child_context)" || { printf 'herdr-child: child pane metadata was malformed\n' >&2; return 1; }
  IFS=$'\t' read -r _ _ old_mode old_generation _ _ _ _ _ <<EOF
$context
EOF

  if [ "$mode" = detach ]; then
    parent_identity="$(printf '%s' "$list_json" | json_identity_for_pane "$HERDR_PANE_ID")" || {
      printf 'herdr-child: parent identity is unavailable or ambiguous\n' >&2
      return 1
    }
    IFS=$'\t' read -r parent_terminal parent_session <<EOF
$parent_identity
EOF
    [ -n "$parent_session" ] || { printf 'herdr-child: parent agent_session is unavailable\n' >&2; return 1; }
    managed_detached_prompt "$name" "$pane" "[parent-prompt v1 pane=$HERDR_PANE_ID]

$text" \
      "$supervision_timeout" "$parent_terminal" "$parent_session" "$child_terminal" "$child_session" \
      "$old_generation"
    return
  fi

  local baseline_json baseline_snapshot baseline_seq status observed_terminal observed_session observed_pane
  baseline_json="$(herdr agent get "$pane")" || { printf 'herdr-child: child baseline state could not be read\n' >&2; return 1; }
  baseline_snapshot="$(printf '%s' "$baseline_json" | json_agent_snapshot)" || { printf 'herdr-child: child baseline state was malformed\n' >&2; return 1; }
  IFS=$'\t' read -r status baseline_seq observed_terminal observed_session _ observed_pane <<EOF
$baseline_snapshot
EOF
  if [ "$observed_terminal" != "$child_terminal" ] || [ "$observed_session" != "$child_session" ] || [ "$observed_pane" != "$pane" ]; then
    printf 'herdr-child: child identity changed before prompt\n' >&2
    return 1
  fi
  if ! herdr agent prompt "$name" "[parent-prompt v1 pane=$HERDR_PANE_ID]

$text" >/dev/null; then
    printf 'herdr-child: prompt delivery failed\n' >&2
    return 1
  fi
  if [ "$old_mode" = detach ] && [ -n "$old_generation" ]; then
    invalidate_generation "$old_generation" attached-prompt || {
      printf 'herdr-child: prompt was accepted but prior supervision could not be invalidated; child remains on the prior generation\n' >&2
      print_supervision_failure "$name" "$pane" "$old_generation" handoff-invalidation-failed "$old_generation"
      return 1
    }
    clear_supervision_metadata "$pane" || true
  fi
  set +e
  wait_for_fresh_settlement "$pane" "$baseline_seq" "$status" "$child_terminal" "$child_session" "$timeout"
  local wait_status=$?
  set -e
  if [ "$wait_status" -eq 124 ]; then
    printf 'herdr-child: prompt was delivered, but the fresh-state wait timed out\n' >&2
    return 124
  fi
  [ "$wait_status" -eq 0 ] || { printf 'herdr-child: prompt fresh-state wait failed\n' >&2; return 1; }
  printf 'Prompt completed for %s in %s.\n' "$name" "$pane"
}

reply_child() {
  require_parent
  local name="" pane="" text="" list_json="" message=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) [ $# -ge 2 ] || fail_usage '--to needs a value'; name="$2"; shift 2 ;;
      --pane) [ $# -ge 2 ] || fail_usage '--pane needs a value'; pane="$2"; shift 2 ;;
      --*) fail_usage "unknown reply option: $1" ;;
      *) [ -z "$text" ] || fail_usage 'reply accepts one decision argument'; text="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || fail_usage 'reply requires --to'
  [ -n "$pane" ] || fail_usage 'reply requires --pane'
  [ -n "$text" ] || fail_usage 'reply requires a decision'

  list_json="$(herdr agent list)" || { printf 'herdr-child: could not list children\n' >&2; exit 1; }
  if ! printf '%s' "$list_json" | json_has_pair "$name" "$pane"; then
    printf 'herdr-child: child name and pane do not identify the same live agent\n' >&2
    exit 1
  fi

  local pane_json context mode generation supervision_timeout
  local stored_parent_terminal stored_parent_session stored_child_terminal stored_child_session
  pane_json="$(herdr pane get "$pane" 2>/dev/null)" || {
    printf 'herdr-child: child pane metadata could not be read\n' >&2
    return 1
  }
  context="$(printf '%s' "$pane_json" | json_child_context 2>/dev/null)" || {
    printf 'herdr-child: child pane metadata was malformed\n' >&2
    return 1
  }
  IFS=$'\t' read -r _ _ mode generation supervision_timeout stored_parent_terminal \
    stored_parent_session stored_child_terminal stored_child_session <<EOF
$context
EOF
  if [ "$mode" = detach ] && [ -n "$generation" ]; then
    local parent_identity child_identity parent_terminal parent_session child_terminal child_session
    parent_identity="$(printf '%s' "$list_json" | json_identity_for_pane "$HERDR_PANE_ID")" || {
      printf 'herdr-child: parent identity is unavailable or ambiguous\n' >&2
      return 1
    }
    child_identity="$(printf '%s' "$list_json" | json_identity_for_pane "$pane")" || {
      printf 'herdr-child: child identity is unavailable or ambiguous\n' >&2
      return 1
    }
    IFS=$'\t' read -r parent_terminal parent_session <<EOF
$parent_identity
EOF
    IFS=$'\t' read -r child_terminal child_session <<EOF
$child_identity
EOF
    if [ "$parent_terminal" != "$stored_parent_terminal" ] || [ "$parent_session" != "$stored_parent_session" ]; then
      printf 'herdr-child: caller does not match the detached parent identity\n' >&2
      return 1
    fi
    if [ "$child_terminal" != "$stored_child_terminal" ] || [ "$child_session" != "$stored_child_session" ]; then
      printf 'herdr-child: child identity changed before reply\n' >&2
      return 1
    fi
    case "$supervision_timeout" in '' | 0 | *[!0-9]*) supervision_timeout="$DEFAULT_SUPERVISION_TIMEOUT" ;; esac
    managed_detached_prompt "$name" "$pane" "[parent-reply v2 pane=$HERDR_PANE_ID]

$text" \
      "$supervision_timeout" "$parent_terminal" "$parent_session" "$child_terminal" "$child_session" \
      "$generation"
    return
  fi

  message="[parent-reply v1 pane=$HERDR_PANE_ID]

$text"
  if ! herdr agent prompt "$name" "$message" >/dev/null; then
    printf 'herdr-child: reply delivery failed; waiting label remains published\n' >&2
    exit 1
  fi
  if ! metadata_report "$pane" --source "$SOURCE_ID" --clear-state-labels >/dev/null; then
    printf 'herdr-child: reply delivered to %s in %s, but the waiting label could not be cleared\n' "$name" "$pane" >&2
    exit 1
  fi
  printf 'Reply delivered to %s in %s.\n' "$name" "$pane"
}
