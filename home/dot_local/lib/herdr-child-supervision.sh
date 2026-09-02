# shellcheck shell=bash
# Shared synchronization kernel for herdr-child lifecycle modules.
# Requires: herdr-child-runtime.sh and entrypoint configuration globals.
# Owns: transition locks, watcher state, retry policy, and reap recovery.

REAP_OWNER_GUARD_PID=""
REAP_OWNER_TOKEN=""

wait_for_watcher_state() {
  local wanted="$1" failed="$2" pid="$3" attempt=0
  while [ "$attempt" -lt 500 ]; do
    [ -z "$failed" ] || [ ! -f "$failed" ] || return 2
    [ ! -f "$wanted" ] || return 0
    kill -0 "$pid" 2>/dev/null || return 1
    attempt=$((attempt + 1))
    sleep 0.01
  done
  return 1
}

wait_for_watcher_failure() {
  wait_for_watcher_state "$1" "" "$2"
}

remove_supervision_run() {
  local run_dir="$1" file
  [ -n "$run_dir" ] && [ -d "$run_dir" ] || return 0
  rmdir "$run_dir/arm.guard" 2>/dev/null || true
  for file in "$run_dir"/* "$run_dir"/.write.*; do
    [ ! -e "$file" ] || rm -f "$file" 2>/dev/null || true
  done
  rmdir "$run_dir" 2>/dev/null || true
}

acquire_arm_guard() {
  local run_dir="$1" attempt=0
  while ! mkdir "$run_dir/arm.guard" 2>/dev/null; do
    [ -d "$run_dir" ] || return 1
    attempt=$((attempt + 1))
    [ "$attempt" -lt 500 ] || return 1
    sleep 0.01
  done
}

release_arm_guard() {
  rmdir "$1/arm.guard" 2>/dev/null || true
}

begin_supervision_transition() {
  local operation="$1" run_dir="$2" subject="${3:--}"
  python3 -c 'import fcntl, os, subprocess, sys, tempfile
operation, run_dir, subject, owner_pid = sys.argv[1:5]

def read_state(path):
    try:
        with open(path, encoding="ascii") as handle:
            return dict(line.rstrip("\n").split("=", 1) for line in handle if "=" in line)
    except (OSError, ValueError):
        return {}

def process_start(pid):
    env = dict(os.environ, LC_ALL="C")
    result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="], capture_output=True, text=True, env=env)
    return result.stdout.strip() if result.returncode == 0 else ""

def atomic_write(name, content):
    fd, tmp = tempfile.mkstemp(prefix=".write.", dir=run_dir)
    try:
        with os.fdopen(fd, "w", encoding="ascii") as handle:
            handle.write(content + "\n")
        os.replace(tmp, os.path.join(run_dir, name))
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

try:
    lock = os.open(os.path.join(run_dir, "transition.lock"), os.O_CREAT | os.O_RDWR, 0o600)
except FileNotFoundError:
    raise SystemExit(20 if operation == "delivery" else 2)
try:
    fcntl.flock(lock, fcntl.LOCK_EX)
    invalidated = os.path.join(run_dir, "invalidated.state")
    pending = os.path.join(run_dir, "delivery-pending.state")
    if operation == "delivery":
        if os.path.isfile(subject):
            try: os.unlink(pending)
            except FileNotFoundError: pass
            raise SystemExit(2)
        if os.path.isfile(invalidated):
            raise SystemExit(13 if read_state(invalidated).get("reason") == "reap" else 20)
        start = process_start(owner_pid)
        if not start:
            raise SystemExit(1)
        atomic_write("delivery-pending.state", f"owner_pid={owner_pid}\nowner_start={start}")
    else:
        if os.path.isfile(pending):
            state = read_state(pending)
            pid = state.get("owner_pid", "")
            start = state.get("owner_start", "")
            if pid.isdigit() and start and process_start(pid) == start:
                raise SystemExit(1)
            os.unlink(pending)
        atomic_write("reap-pending.state", f"status=pending\nowner_pid={owner_pid}\nowner_token={subject}")
        atomic_write("invalidated.state", "reason=reap")
finally:
    os.close(lock)' "$operation" "$run_dir" "$subject" "$$"
}

finish_delivery_transition() {
  rm -f "$1/delivery-pending.state" 2>/dev/null || true
}

request_watcher_abort() {
  local run_dir="$1" reason="$2" status=0
  acquire_arm_guard "$run_dir" || return 1
  if [ -f "$run_dir/failed.state" ]; then
    release_arm_guard "$run_dir"
    return 2
  fi
  if [ -f "$run_dir/armed.state" ]; then
    release_arm_guard "$run_dir"
    return 0
  fi
  atomic_write "$run_dir/abort.state" "reason=$reason" || status=1
  release_arm_guard "$run_dir"
  [ "$status" -eq 0 ] || return 1
  return 2
}

report_signal_supervision() {
  local name="$1" pane="$2" tab="$3" run_dir="$4" generation="$5" timeout="$6" reason="$7" pid="$8"
  local state_status failure_reason
  set +e
  wait_for_watcher_state "$run_dir/armed.state" "$run_dir/failed.state" "$pid"
  state_status=$?
  set -e
  case "$state_status" in
    0) print_start_result "$name" "$pane" "$tab" "$generation" "$timeout" ;;
    2)
      failure_reason="$(supervision_reason "$run_dir/failed.state")"
      print_supervision_failure "$name" "$pane" "$generation" "$failure_reason" "$generation"
      ;;
    *) print_supervision_uncertain "$name" "$pane" "$generation" "$reason" ;;
  esac
}

stop_owned_watcher() {
  local run_dir="$1" pid="$2" reason="$3" preserve_state="${4:-0}" attempt=0
  [ -n "$run_dir" ] || return 0
  atomic_write "$run_dir/abort.state" "reason=$reason" || true
  case "$pid" in '' | *[!0-9]*) remove_supervision_run "$run_dir"; return 0 ;; esac
  while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    attempt=0
    while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 100 ]; do
      attempt=$((attempt + 1))
      sleep 0.01
    done
  fi
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  [ "$preserve_state" -eq 1 ] || remove_supervision_run "$run_dir"
}

watcher_preflight_fail() {
  local run_dir="$1" reason="$2"
  atomic_write "$run_dir/failed.state" "reason=$reason" || true
  exit 1
}

publish_supervision_recovery() {
  local name="$1" pane="$2" generation="$3" reason="$4" run_dir="$5" watcher_pid="$6"
  stop_owned_watcher "$run_dir" "$watcher_pid" "$reason" 1
  watcher_publish_failed "$run_dir" "$pane" "$generation" "$reason" || true
  atomic_write "$run_dir/failed.state" "reason=$reason" || true
  print_supervision_failure "$name" "$pane" "$generation" "$reason" "$generation"
}

watcher_invalidation_action() {
  local run_dir="$1" pane="$2" generation="$3" reason attempt=0 pane_err owner_pid
  local owner_token lock_status
  [ -f "$run_dir/invalidated.state" ] || return 1
  reason="$(supervision_reason "$run_dir/invalidated.state")"
  [ "$reason" = reap ] || return 20
  owner_pid="$(state_value "$run_dir/reap-pending.state" owner_pid)"
  owner_token="$(state_value "$run_dir/reap-pending.state" owner_token)"
  case "$owner_pid" in '' | *[!0-9]*) return 21 ;; esac
  case "$owner_token" in *[!0-9a-f]* | '') return 21 ;; esac
  [ "${#owner_token}" -eq 32 ] || return 21
  while :; do
    [ -d "$run_dir" ] || return 20
    [ ! -f "$run_dir/reap-closed.state" ] || return 20
    pane_err="$run_dir/reap-pane-get.err"
    if herdr pane get "$pane" >/dev/null 2>"$pane_err"; then
      rm -f "$pane_err"
    elif grep -q '"code":"pane_not_found"' "$pane_err" 2>/dev/null; then
      rm -f "$pane_err"
      return 20
    else
      rm -f "$pane_err"
    fi
    if [ $((attempt % 100)) -eq 0 ]; then
      if reap_owner_recovery_status "$run_dir" "$owner_token"; then lock_status=0; else lock_status=$?; fi
      case "$lock_status" in
        0)
          [ -z "${HERDR_CHILD_TEST_REAP_OWNER_VERIFIED:-}" ] ||
            : > "$HERDR_CHILD_TEST_REAP_OWNER_VERIFIED"
          ;;
        1|10)
          refresh_supervision_liveness "$pane" "$generation" || return 21
          return 0
          ;;
        3) return 0 ;;
        20) return 20 ;;
        *) return 21 ;;
      esac
    fi
    attempt=$((attempt + 1))
    if [ $((attempt % 3000)) -eq 0 ]; then
      refresh_supervision_liveness "$pane" "$generation" || return 21
    fi
    sleep 0.01
  done
}

watcher_generation_current() {
  local run_dir="$1" pane="$2" generation="$3" pane_json status err
  local child_terminal child_session
  child_terminal="$(state_value "$run_dir/launch.state" child_terminal)"
  child_session="$(state_value "$run_dir/launch.state" child_session)"
  err="$run_dir/pane-get.err"
  if pane_json="$(herdr pane get "$pane" 2>"$err")"; then
    rm -f "$err"
  else
    if grep -q '"code":"pane_not_found"' "$err" 2>/dev/null; then
      rm -f "$err"
      return 32
    fi
    rm -f "$err"
    return 34
  fi
  set +e
  printf '%s' "$pane_json" | json_generation_status "$generation" "$child_terminal" "$child_session"
  status=$?
  set -e
  case "$status" in
    0) return 0 ;;
    2|3) return 20 ;;
    *) return 34 ;;
  esac
}

# Test-only barrier holds are bounded (docs/issues/2026-08-28-001): an
# expired hold means the harness died without releasing the barrier.
watcher_hold_expired() {
  [ $((SECONDS - $1)) -ge "${HERDR_CHILD_TEST_HOLD_TIMEOUT_SECONDS:-120}" ]
}

watcher_publish_failed() {
  local run_dir="$1" pane="$2" generation="$3" reason="$4" preserve_waiting="${5:-0}"
  local current_status hold_started
  # watcher_generation_current re-enables errexit internally, clobbering any
  # set +e bracket; conditional invocation keeps its nonzero return non-fatal.
  if watcher_generation_current "$run_dir" "$pane" "$generation"; then
    current_status=0
  else
    current_status=$?
  fi
  [ "$current_status" -eq 0 ] || return "$current_status"
  if [ -n "${HERDR_CHILD_TEST_FAILURE_PUBLISH_BARRIER:-}" ]; then
    : > "$HERDR_CHILD_TEST_FAILURE_PUBLISH_BARRIER.ready"
    hold_started="$SECONDS"
    while [ ! -e "$HERDR_CHILD_TEST_FAILURE_PUBLISH_BARRIER.release" ]; do
      if watcher_hold_expired "$hold_started"; then
        remove_supervision_run "$run_dir"
        exit 1
      fi
      sleep 0.01
    done
  fi
  if [ "$preserve_waiting" -eq 1 ]; then
    metadata_report_if_generation "$run_dir" "$pane" "$generation" \
      --source "$SOURCE_ID" --clear-state-labels \
      --state-label 'blocked=waiting for parent' \
      --state-label "supervision failed=$reason" \
      --token "supervision_failure_reason=$reason" \
      --token "supervision_failure_generation=$generation" \
      --token "supervision_failure_diagnostic=$generation" >/dev/null 2>&1
  else
    metadata_report_if_generation "$run_dir" "$pane" "$generation" \
      --source "$SOURCE_ID" --clear-state-labels \
      --state-label "supervision failed=$reason" \
      --token "supervision_failure_reason=$reason" \
      --token "supervision_failure_generation=$generation" \
      --token "supervision_failure_diagnostic=$generation" >/dev/null 2>&1
  fi
}

watcher_fail() {
  local run_dir="$1" pane="$2" generation="$3" reason="$4" preserve_waiting="${5:-0}"
  local publish_status
  release_arm_guard "$run_dir"
  rm -f "$run_dir/ready.state" "$run_dir/accepted.state" "$run_dir/abort.state" 2>/dev/null || true
  # watcher_publish_failed re-enables errexit internally, clobbering any
  # set +e bracket; conditional invocation keeps its nonzero return non-fatal.
  if watcher_publish_failed "$run_dir" "$pane" "$generation" "$reason" "$preserve_waiting"; then
    publish_status=0
  else
    publish_status=$?
  fi
  if [ "$publish_status" -eq 20 ]; then
    remove_supervision_run "$run_dir"
    exit 0
  fi
  atomic_write "$run_dir/failed.state" "reason=$reason" || true
  exit 1
}

watcher_fail_without_publish() {
  local run_dir="$1"
  remove_supervision_run "$run_dir"
  exit 0
}

clear_supervision_metadata() {
  local pane="$1"
  metadata_report "$pane" --source "$SOURCE_ID" --clear-state-labels \
    --clear-token child_mode --clear-token supervision_generation \
    --clear-token supervision_timeout --clear-token supervision_baseline_seq \
    --clear-token parent_terminal --clear-token parent_session \
    --clear-token child_terminal --clear-token child_session \
    --clear-token supervision_failure_reason \
    --clear-token supervision_failure_generation \
    --clear-token supervision_failure_diagnostic >/dev/null 2>&1
}

clear_supervision_state_labels() {
  local pane="$1"
  metadata_report "$pane" --source "$SOURCE_ID" --clear-state-labels >/dev/null 2>&1
}

preserve_callback_waiting_label() {
  local pane="$1"
  metadata_report "$pane" --source "$SOURCE_ID" --clear-state-labels \
    --state-label 'blocked=waiting for parent' --ttl-ms "$WAITING_TTL_MS" >/dev/null 2>&1
}

refresh_supervision_liveness() {
  local pane="$1" generation="$2"
  metadata_report "$pane" --source "$SOURCE_ID" \
    --state-label "supervised=$generation" --ttl-ms "$SUPERVISED_TTL_MS" >/dev/null 2>&1
}

delivery_retry_pause() {
  local delay="$1"
  if [ -n "${HERDR_CHILD_TEST_RETRY_LOG:-}" ]; then
    printf '%s\n' "$delay" >> "$HERDR_CHILD_TEST_RETRY_LOG"
  fi
  [ "${HERDR_CHILD_TEST_SKIP_RETRY_SLEEP:-0}" = 1 ] || sleep "$delay"
}

next_delivery_retry_delay() {
  local delay="$1" next
  next=$((delay * 2))
  [ "$next" -le "$DELIVERY_RETRY_MAX" ] || next="$DELIVERY_RETRY_MAX"
  printf '%s' "$next"
}

invalidate_generation() {
  local generation="$1" reason="$2" run_dir
  [ -n "$generation" ] || return 0
  run_dir="$STATE_DIR/runs/$generation"
  [ ! -d "$run_dir" ] || atomic_write "$run_dir/invalidated.state" "reason=$reason"
}

begin_reap_invalidation() {
  local generation="$1" run_dir transition_status
  run_dir="$STATE_DIR/runs/$generation"
  [ -d "$run_dir" ] || return 2
  start_reap_owner_guard "$run_dir" || return 1
  if begin_supervision_transition reap "$run_dir" "$REAP_OWNER_TOKEN"; then
    return 0
  else
    transition_status=$?
    stop_reap_owner_guard "$run_dir"
    return "$transition_status"
  fi
}

start_reap_owner_guard() {
  local run_dir="$1" ready release gone
  local attempt=0
  REAP_OWNER_TOKEN="$(generation_nonce)" || return 1
  ready="$run_dir/reap-owner-$REAP_OWNER_TOKEN.ready"
  release="$run_dir/reap-owner-$REAP_OWNER_TOKEN.release"
  gone="$run_dir/reap-owner-$REAP_OWNER_TOKEN.gone"
  rm -f "$ready" "$release" "$gone" 2>/dev/null || return 1
  python3 -c 'import fcntl, os, sys, time
lock_path, ready_path, release_path, gone_path, parent_pid = sys.argv[1:]
run_dir = os.path.dirname(release_path)
lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit(3)
os.close(os.open(ready_path, os.O_CREAT | os.O_WRONLY, 0o600))
while os.getppid() == int(parent_pid) and os.path.isdir(run_dir) and not os.path.exists(release_path):
    time.sleep(0.01)
if os.path.isdir(run_dir) and not os.path.exists(release_path):
    os.close(os.open(gone_path, os.O_CREAT | os.O_WRONLY, 0o600))
os.close(lock_fd)' "$run_dir/reap-owner.lock" "$ready" "$release" "$gone" "$$" &
  REAP_OWNER_GUARD_PID=$!
  while [ ! -f "$ready" ] && kill -0 "$REAP_OWNER_GUARD_PID" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  if [ -f "$ready" ] && kill -0 "$REAP_OWNER_GUARD_PID" 2>/dev/null; then
    return 0
  fi
  kill "$REAP_OWNER_GUARD_PID" 2>/dev/null || true
  wait "$REAP_OWNER_GUARD_PID" 2>/dev/null || true
  REAP_OWNER_GUARD_PID=""
  rm -f "$ready" "$release" "$gone" 2>/dev/null || true
  REAP_OWNER_TOKEN=""
  return 1
}

stop_reap_owner_guard() {
  local run_dir="$1" token="$REAP_OWNER_TOKEN"
  [ -n "$token" ] || return 0
  : > "$run_dir/reap-owner-$token.release" 2>/dev/null ||
    kill "$REAP_OWNER_GUARD_PID" 2>/dev/null || true
  [ -z "$REAP_OWNER_GUARD_PID" ] || wait "$REAP_OWNER_GUARD_PID" 2>/dev/null || true
  REAP_OWNER_GUARD_PID=""
  REAP_OWNER_TOKEN=""
  rm -f "$run_dir/reap-owner-$token.ready" "$run_dir/reap-owner-$token.release" \
    "$run_dir/reap-owner-$token.gone" 2>/dev/null || true
}

reap_owner_recovery_status() {
  local run_dir="$1" owner_token="$2"
  python3 -c 'import fcntl, os, sys
run_dir, expected_token = sys.argv[1:]

def state_value(path, key):
    try:
        with open(path, encoding="ascii") as handle:
            for line in handle:
                if line.startswith(key + "="):
                    return line.rstrip("\n").split("=", 1)[1]
    except OSError:
        return ""
    return ""

def remove(*names):
    try:
        for name in names:
            os.unlink(os.path.join(run_dir, name))
    except OSError:
        raise SystemExit(2)

try:
    lock_fd = os.open(os.path.join(run_dir, "reap-owner.lock"), os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit(0)
except OSError:
    raise SystemExit(2)
if state_value(os.path.join(run_dir, "reap-pending.state"), "owner_token") != expected_token:
    raise SystemExit(3)
if os.path.exists(os.path.join(run_dir, "reap-closed.state")):
    raise SystemExit(20)
if os.path.exists(os.path.join(run_dir, "reap-restore.state")):
    remove("invalidated.state", "reap-pending.state", "reap-restore.state")
    raise SystemExit(10)
gone = "reap-owner-" + expected_token + ".gone"
if not os.path.exists(os.path.join(run_dir, gone)):
    raise SystemExit(2)
remove("invalidated.state", "reap-pending.state", gone)
raise SystemExit(1)' "$run_dir" "$owner_token"
}

signal_reap_transition() {
  local generation="$1" outcome="$2" run_dir
  run_dir="$STATE_DIR/runs/$generation"
  [ -d "$run_dir" ] || return 1
  atomic_write "$run_dir/reap-$outcome.state" "status=$outcome"
}

publish_reap_recovery() {
  local pane="$1" generation="$2"
  metadata_report "$pane" --source "$SOURCE_ID" \
    --state-label 'supervision failed=reap-close-failed' \
    --token 'supervision_failure_reason=reap-close-failed' \
    --token "supervision_failure_generation=$generation" \
    --token "supervision_failure_diagnostic=$generation" >/dev/null 2>&1
}
