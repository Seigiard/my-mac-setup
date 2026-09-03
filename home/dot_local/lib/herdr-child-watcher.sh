# shellcheck shell=bash
# Parent delivery and external watcher loop for herdr-child supervision.
# Requires: herdr-process.sh, runtime, supervision, and entrypoint globals.
# Owns: watcher polling, event delivery, and delivery receipts.

DELIVERY_REASON=""
deliver_supervision_event() {
  local run_dir="$1" generation="$2" event="$3" outcome="$4" reason="$5"
  local child_name="$6" child_pane="$7" parent_terminal="$8" parent_session="$9"
  local receipt="$run_dir/delivered.$event" list_json parent_record parent_pane parent_status message
  local pane_json generation_status child_terminal child_session pane_err invalidation_reason transition_status
  DELIVERY_REASON=""
  [ ! -f "$receipt" ] || return 0
  if [ -f "$run_dir/invalidated.state" ]; then
    invalidation_reason="$(supervision_reason "$run_dir/invalidated.state")"
    [ "$invalidation_reason" != reap ] || return 13
    return 20
  fi

  if [ "$event" != child-gone ]; then
    child_terminal="$(state_value "$run_dir/launch.state" child_terminal)"
    child_session="$(state_value "$run_dir/launch.state" child_session)"
    pane_err="$run_dir/delivery-pane-get.err"
    if pane_json="$(herdr pane get "$child_pane" 2>"$pane_err")"; then
      rm -f "$pane_err"
    elif grep -q '"code":"pane_not_found"' "$pane_err" 2>/dev/null; then
      rm -f "$pane_err"
      DELIVERY_REASON="child-gone"
      return 32
    else
      rm -f "$pane_err"
      DELIVERY_REASON="wait-error"
      return 12
    fi
    if printf '%s' "$pane_json" | json_generation_status "$generation" "$child_terminal" "$child_session"; then
      generation_status=0
    else
      generation_status=$?
    fi
    case "$generation_status" in
      0) ;;
      2) DELIVERY_REASON="child-identity-mismatch"; return 33 ;;
      3) return 20 ;;
      *) DELIVERY_REASON="malformed-state"; return 34 ;;
    esac
  fi

  list_json="$(herdr agent list 2>/dev/null)" || {
    DELIVERY_REASON="parent-not-found"
    return 30
  }
  local resolve_status
  if parent_record="$(printf '%s' "$list_json" | json_resolve_parent "$parent_terminal" "$parent_session")"; then
    resolve_status=0
  else
    resolve_status=$?
  fi
  case "$resolve_status" in
    0) ;;
    2) DELIVERY_REASON="parent-session-mismatch"; return 31 ;;
    *) DELIVERY_REASON="parent-not-found"; return 30 ;;
  esac
  IFS=$'\t' read -r parent_pane parent_status <<EOF
$parent_record
EOF
  if [ "$parent_status" = blocked ]; then
    DELIVERY_REASON="parent-blocked"
    return 10
  fi

  if begin_supervision_transition delivery "$run_dir" "$receipt"; then
    transition_status=0
  else
    transition_status=$?
  fi
  case "$transition_status" in
    0) ;;
    2) return 0 ;;
    13|20) return "$transition_status" ;;
    *) DELIVERY_REASON="prompt-error"; return 11 ;;
  esac

  message="[child-supervision v1 generation=$generation event=$event outcome=$outcome reason=${reason:-none} agent=$child_name pane=$child_pane]

This is an observed child lifecycle state, not a task-success verdict. Verify the live pair, child output, requested commits, worktree state, tests, and artifacts."
  if herdr agent prompt "$parent_pane" "$message" >/dev/null 2>&1 && \
     atomic_write "$receipt" "generation=$generation
event=$event"; then
    finish_delivery_transition "$run_dir"
    return 0
  fi
  finish_delivery_transition "$run_dir"
  DELIVERY_REASON="prompt-error"
  return 11
}

watch_child() {
  local run_dir="" pane="" generation="" timeout="" launcher_pid="" deferred_activation=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-dir) run_dir="${2:-}"; shift 2 ;;
      --pane) pane="${2:-}"; shift 2 ;;
      --generation) generation="${2:-}"; shift 2 ;;
      --timeout) timeout="${2:-}"; shift 2 ;;
      --launcher-pid) launcher_pid="${2:-}"; shift 2 ;;
      --deferred-activation) deferred_activation=1; shift ;;
      *) exit 2 ;;
    esac
  done
  [ -d "$run_dir" ] && [ -n "$pane" ] && [ -n "$generation" ] || exit 2
  case "$MAX_DELIVERY_RETRIES" in '' | 0 | *[!0-9]*) MAX_DELIVERY_RETRIES=12 ;; esac
  case "$DELIVERY_RETRY_INITIAL" in '' | 0 | *[!0-9]*) DELIVERY_RETRY_INITIAL=1 ;; esac
  case "$DELIVERY_RETRY_MAX" in '' | 0 | *[!0-9]*) DELIVERY_RETRY_MAX=15 ;; esac
  [ "$DELIVERY_RETRY_MAX" -ge "$DELIVERY_RETRY_INITIAL" ] || DELIVERY_RETRY_MAX="$DELIVERY_RETRY_INITIAL"
  case "$WAIT_SLICE_MS" in '' | 0 | *[!0-9]*) WAIT_SLICE_MS=30000 ;; esac
  [ "$WAIT_SLICE_MS" -le 30000 ] || WAIT_SLICE_MS=30000
  close_inherited_descriptors
  umask 077
  local launch_state="$run_dir/launch.state"
  local child_name child_terminal child_session parent_terminal parent_session baseline_seq
  child_name="$(state_value "$launch_state" child_name)"
  child_terminal="$(state_value "$launch_state" child_terminal)"
  child_session="$(state_value "$launch_state" child_session)"
  parent_terminal="$(state_value "$launch_state" parent_terminal)"
  parent_session="$(state_value "$launch_state" parent_session)"
  baseline_seq="$(state_value "$launch_state" baseline_seq)"
  [ -n "$child_name" ] && [ -n "$child_terminal" ] && [ -n "$child_session" ] && \
    [ -n "$parent_terminal" ] && [ -n "$parent_session" ] || exit 2
  case "$baseline_seq" in '' | *[!0-9]*) exit 2 ;; esac
  if [ -n "${HERDR_CHILD_TEST_WATCHER_PID_FILE:-}" ]; then
    printf '%s\n' "$$" > "$HERDR_CHILD_TEST_WATCHER_PID_FILE"
  fi
  trap 'watcher_fail "$run_dir" "$pane" "$generation" watcher-signal-HUP' HUP
  trap 'watcher_fail "$run_dir" "$pane" "$generation" watcher-signal-INT' INT
  trap 'watcher_fail "$run_dir" "$pane" "$generation" watcher-signal-TERM' TERM

  if [ "$deferred_activation" -eq 1 ]; then
    [ "${HERDR_CHILD_TEST_PREPARE_FAIL:-0}" != 1 ] || watcher_preflight_fail "$run_dir" watcher-readiness-failed
    atomic_write "$run_dir/prepared.state" "pid=$$" || watcher_preflight_fail "$run_dir" readiness-write-failed
    while [ ! -f "$run_dir/takeover.state" ]; do
      [ ! -f "$run_dir/abort.state" ] || watcher_preflight_fail "$run_dir" "$(supervision_reason "$run_dir/abort.state")"
      kill -0 "$launcher_pid" 2>/dev/null || watcher_preflight_fail "$run_dir" launcher-lost-before-takeover
      sleep 0.01
    done
  fi

  refresh_supervision_liveness "$pane" "$generation" || watcher_fail "$run_dir" "$pane" "$generation" liveness-publish-failed
  atomic_write "$run_dir/ready.state" "pid=$$" || watcher_fail "$run_dir" "$pane" "$generation" readiness-write-failed

  while [ ! -f "$run_dir/accepted.state" ]; do
    if [ -f "$run_dir/abort.state" ]; then
      watcher_fail "$run_dir" "$pane" "$generation" "$(supervision_reason "$run_dir/abort.state")"
    fi
    kill -0 "$launcher_pid" 2>/dev/null || watcher_fail "$run_dir" "$pane" "$generation" launcher-lost-before-acceptance
    sleep 0.01
  done
  if [ -n "${HERDR_CHILD_TEST_ARM_BARRIER:-}" ]; then
    : > "$HERDR_CHILD_TEST_ARM_BARRIER.ready"
    local arm_hold_started="$SECONDS"
    while [ ! -e "$HERDR_CHILD_TEST_ARM_BARRIER.release" ] && [ ! -f "$run_dir/abort.state" ]; do
      # A live holder of this pre-arm barrier always has a live launcher
      # blocked on armed.state; a dead launcher means the harness is gone.
      kill -0 "$launcher_pid" 2>/dev/null || \
        watcher_fail "$run_dir" "$pane" "$generation" launcher-lost-before-arm
      if watcher_hold_expired "$arm_hold_started"; then
        remove_supervision_run "$run_dir"
        exit 1
      fi
      sleep 0.01
    done
  fi
  acquire_arm_guard "$run_dir" || watcher_fail "$run_dir" "$pane" "$generation" watcher-arm-guard-failed
  if [ -f "$run_dir/abort.state" ]; then
    local abort_reason
    abort_reason="$(supervision_reason "$run_dir/abort.state")"
    release_arm_guard "$run_dir"
    watcher_fail "$run_dir" "$pane" "$generation" "$abort_reason"
  fi
  if [ "${HERDR_CHILD_TEST_ARM_FAIL:-0}" = 1 ]; then
    release_arm_guard "$run_dir"
    watcher_fail "$run_dir" "$pane" "$generation" watcher-arm-failed
  fi
  if ! atomic_write "$run_dir/armed.state" "pid=$$"; then
    release_arm_guard "$run_dir"
    watcher_fail "$run_dir" "$pane" "$generation" armed-write-failed
  fi
  release_arm_guard "$run_dir"

  local now deadline next_refresh
  now="$(now_ms)"
  deadline=$((now + timeout))
  next_refresh=$((now + 30000))

  # Existing descriptor tests hold the watcher at this explicit boundary.
  if [ -n "${HERDR_CHILD_TEST_WATCHER_RELEASE:-}" ]; then
    local release_hold_started="$SECONDS"
    while [ ! -e "$HERDR_CHILD_TEST_WATCHER_RELEASE" ]; do
      # The launcher legitimately exits before this hold is released, so the
      # only abandonment signals are torn-down run state and the hold bound.
      [ -d "$run_dir" ] || exit 1
      if watcher_hold_expired "$release_hold_started"; then
        remove_supervision_run "$run_dir"
        exit 1
      fi
      if [ -f "$run_dir/invalidated.state" ]; then
        set +e
        watcher_invalidation_action "$run_dir" "$pane" "$generation"
        local invalidation_status=$?
        set -e
        case "$invalidation_status" in
          0) continue ;;
          20) remove_supervision_run "$run_dir"; exit 0 ;;
          *) watcher_fail "$run_dir" "$pane" "$generation" reap-recovery-failed ;;
        esac
      fi
      now="$(now_ms)"
      if [ "$now" -ge "$next_refresh" ]; then
        refresh_supervision_liveness "$pane" "$generation" || watcher_fail "$run_dir" "$pane" "$generation" liveness-refresh-failed
        next_refresh=$((now + 30000))
      fi
      sleep 0.1
    done
    clear_supervision_metadata "$pane" || true
    remove_supervision_run "$run_dir"
    exit 0
  fi

  local pane_json generation_status snapshot_json snapshot snapshot_status pane_err
  local child_status child_seq observed_terminal observed_session observed_name observed_pane
  local event="" outcome="" reason="" timeout_delivered=0 delivery_failures=0 pending_event=""
  local delivery_status pane_get_status get_status wait_status wait_output slice remaining
  local wait_phase=0 retry_delay="$DELIVERY_RETRY_INITIAL" callback_status preserve_waiting
  while :; do
    # Externally removed run state means supervision was torn down (test
    # teardown or reap); without this check a dead run dir turns the herdr
    # error path below into a permanent poll loop, because the pane_err
    # redirection fails and every iteration looks transient
    # (docs/solutions/design-patterns/outliving-processes-hang-the-suite.md).
    [ -d "$run_dir" ] || exit 1
    if [ -f "$run_dir/invalidated.state" ]; then
      set +e
      watcher_invalidation_action "$run_dir" "$pane" "$generation"
      local invalidation_status=$?
      set -e
      case "$invalidation_status" in
        0) continue ;;
        20) remove_supervision_run "$run_dir"; exit 0 ;;
        *) watcher_fail "$run_dir" "$pane" "$generation" reap-recovery-failed ;;
      esac
    fi
    if [ -f "$run_dir/abort.state" ]; then
      rm -f "$run_dir/abort.state" 2>/dev/null || true
    fi

    event=""
    outcome=""
    reason=""
    pane_err="$run_dir/pane-get.err"
    set +e
    pane_json="$(herdr pane get "$pane" 2>"$pane_err")"
    pane_get_status=$?
    set -e
    if [ "$pane_get_status" -ne 0 ]; then
      if grep -q '"code":"pane_not_found"' "$pane_err" 2>/dev/null; then
        event="child-gone"
        outcome="child-gone"
        reason="child-gone"
      else
        rm -f "$pane_err"
        sleep "$POLL_INTERVAL"
        continue
      fi
      rm -f "$pane_err"
    else
      rm -f "$pane_err"
      set +e
      printf '%s' "$pane_json" | json_generation_status "$generation" "$child_terminal" "$child_session"
      generation_status=$?
      set -e
      case "$generation_status" in
        0) ;;
        2) watcher_fail_without_publish "$run_dir" child-identity-mismatch ;;
        3) remove_supervision_run "$run_dir"; exit 0 ;;
        *) watcher_fail "$run_dir" "$pane" "$generation" malformed-state ;;
      esac

      set +e
      snapshot_json="$(herdr agent get "$pane" 2>/dev/null)"
      get_status=$?
      set -e
      [ "$get_status" -eq 0 ] || watcher_fail "$run_dir" "$pane" "$generation" wait-error
      set +e
      snapshot="$(printf '%s' "$snapshot_json" | json_agent_snapshot)"
      snapshot_status=$?
      set -e
      [ "$snapshot_status" -eq 0 ] || watcher_fail "$run_dir" "$pane" "$generation" malformed-state
      IFS=$'\t' read -r child_status child_seq observed_terminal observed_session observed_name observed_pane <<EOF
$snapshot
EOF
      if [ "$observed_terminal" != "$child_terminal" ] || [ "$observed_session" != "$child_session" ] || [ "$observed_pane" != "$pane" ]; then
        watcher_fail_without_publish "$run_dir" child-identity-mismatch
      fi
      [ -z "$observed_name" ] || child_name="$observed_name"

      if [ "$child_seq" -gt "$baseline_seq" ]; then
        case "$child_status" in
          idle|done) event="settled-$child_seq"; outcome="$child_status" ;;
          blocked) event="blocked-$child_seq"; outcome="blocked"; reason="blocked" ;;
          working) wait_phase=1 ;;
        esac
      fi
    fi

    now="$(now_ms)"
    if [[ "$event" = blocked-* ]]; then
      callback_status="$(state_value "$run_dir/callback.state" status)"
      case "$callback_status" in
        in-progress)
          sleep "$POLL_INTERVAL"
          continue
          ;;
        confirmed)
          preserve_callback_waiting_label "$pane" || true
          remove_supervision_run "$run_dir"
          exit 0
          ;;
      esac
    fi
    if [ -z "$event" ] && [ "$timeout_delivered" -eq 0 ] && [ "$now" -ge "$deadline" ]; then
      event="timeout"
      outcome="timeout"
      reason="timeout"
    fi

    if [ -n "$event" ]; then
      if [ "$pending_event" != "$event" ]; then
        delivery_failures=0
        retry_delay="$DELIVERY_RETRY_INITIAL"
        pending_event="$event"
      fi
      set +e
      deliver_supervision_event "$run_dir" "$generation" "$event" "$outcome" "$reason" \
        "$child_name" "$pane" "$parent_terminal" "$parent_session"
      delivery_status=$?
      set -e
      preserve_waiting=0
      if [[ "$event" = blocked-* ]] && [ "$(state_value "$run_dir/callback.state" status)" = failed ]; then
        preserve_waiting=1
      fi
      case "$delivery_status" in
        0)
          delivery_failures=0
          if [ "$event" = timeout ]; then
            timeout_delivered=1
          else
            [ "$event" = child-gone ] || clear_supervision_state_labels "$pane" || true
            remove_supervision_run "$run_dir"
            exit 0
          fi
          ;;
        10|11)
          delivery_failures=$((delivery_failures + 1))
          if [ "$delivery_failures" -ge "$MAX_DELIVERY_RETRIES" ]; then
            watcher_fail "$run_dir" "$pane" "$generation" "$DELIVERY_REASON" "$preserve_waiting"
          fi
          delivery_retry_pause "$retry_delay"
          retry_delay="$(next_delivery_retry_delay "$retry_delay")"
          ;;
        12) sleep "$POLL_INTERVAL"; continue ;;
        13) continue ;;
        20) remove_supervision_run "$run_dir"; exit 0 ;;
        *) watcher_fail "$run_dir" "$pane" "$generation" "$DELIVERY_REASON" "$preserve_waiting" ;;
      esac
    fi

    if [ -z "$event" ] && [ "$wait_phase" -eq 1 ]; then
      now="$(now_ms)"
      if [ "$timeout_delivered" -eq 0 ]; then
        remaining=$((deadline - now))
        [ "$remaining" -gt 0 ] || continue
        slice="$remaining"
        [ "$slice" -le "$WAIT_SLICE_MS" ] || slice="$WAIT_SLICE_MS"
      else
        slice="$WAIT_SLICE_MS"
      fi
      set +e
      wait_output="$(herdr agent wait "$pane" --timeout "$slice" 2>&1)"
      wait_status=$?
      set -e
      if [ "$wait_status" -ne 0 ] && ! printf '%s' "$wait_output" | grep -q '"code":"timeout"'; then
        watcher_fail "$run_dir" "$pane" "$generation" wait-error
      fi
      # watcher_generation_current re-enables errexit internally, clobbering any
      # set +e bracket; conditional invocation keeps its nonzero return non-fatal.
      if watcher_generation_current "$run_dir" "$pane" "$generation"; then
        generation_status=0
      else
        generation_status=$?
      fi
      case "$generation_status" in
        0) ;;
        20) remove_supervision_run "$run_dir"; exit 0 ;;
        *) sleep "$POLL_INTERVAL"; continue ;;
      esac
      refresh_supervision_liveness "$pane" "$generation" || watcher_fail "$run_dir" "$pane" "$generation" liveness-refresh-failed
      now="$(now_ms)"
      next_refresh=$((now + 30000))
      continue
    fi

    if [ "$now" -ge "$next_refresh" ]; then
      refresh_supervision_liveness "$pane" "$generation" || watcher_fail "$run_dir" "$pane" "$generation" liveness-refresh-failed
      next_refresh=$((now + 30000))
    fi
    sleep "$POLL_INTERVAL"
  done
}
