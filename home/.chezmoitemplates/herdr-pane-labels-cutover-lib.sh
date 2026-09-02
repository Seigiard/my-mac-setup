# shellcheck shell=bash
# Both wrappers include the complete library, so each intentionally leaves the
# other phase's public functions unused.
# shellcheck disable=SC2329
# Shared by the before/after pane-label cutover scripts. The functions fail
# closed around live processes: a PID is signaled only after its cache record,
# socket, process start, and exact command family agree twice.

HPL_CUTOVER_OLD_ENGINE="$HOME/.local/bin/herdr-task-sync"
HPL_CUTOVER_NEW_ENGINE="$HOME/.local/bin/herdr-pane-labels"
HPL_CUTOVER_CHILD="$HOME/.local/bin/herdr-child"
HPL_CUTOVER_OLD_CACHE="$HOME/.cache/herdr-task-sync"
HPL_CUTOVER_NEW_CACHE="$HOME/.cache/herdr-pane-labels"
HPL_CUTOVER_PLUGIN_ID="seigi.pane-labels"
# Used by the including after-script.
# shellcheck disable=SC2034
HPL_CUTOVER_PLUGIN_DIR="$HOME/.config/herdr/plugins/herdr-pane-labels"
HPL_CUTOVER_WORK=""
HPL_CUTOVER_SOCKETS=""
HPL_CUTOVER_BACKUP=""
HPL_CUTOVER_BACKUP_MODE=""
HPL_CUTOVER_CHILD_BACKUP=""
HPL_CUTOVER_CHILD_BACKUP_MODE=""
HPL_CUTOVER_CHILD_BACKED_UP=0
HPL_CUTOVER_ROLLBACK_DIR=""
HPL_CUTOVER_STATE_FILE=""
HPL_CUTOVER_PHASE="prepared"
HPL_CUTOVER_FROZEN=0
HPL_CUTOVER_PLUGIN_DISABLED=0
HPL_CUTOVER_PLUGIN_LINKED=0
HPL_CUTOVER_ROLLBACK_ENGINE=""
HPL_CUTOVER_ROLLBACK_CACHE=""

hpl_cutover_log() {
  printf '%s\n' "herdr pane-label cutover: $*"
}

hpl_cutover_error() {
  printf '%s\n' "herdr pane-label cutover: $*" >&2
}

hpl_cutover_trace() {
  [ -z "${HERDR_PANE_LABELS_CUTOVER_TRACE:-}" ] || \
    printf '%s\n' "$1" >> "$HERDR_PANE_LABELS_CUTOVER_TRACE"
}

hpl_cutover_hook() {
  [ -z "${HERDR_PANE_LABELS_CUTOVER_TEST_HOOK:-}" ] || \
    "$HERDR_PANE_LABELS_CUTOVER_TEST_HOOK" "$1"
}

hpl_cutover_setup() {
  HPL_CUTOVER_WORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/herdr-pane-label-cutover.XXXXXX")" || return 1
  HPL_CUTOVER_HERDR_PRESENT=0
  command -v herdr >/dev/null 2>&1 && HPL_CUTOVER_HERDR_PRESENT=1
  HPL_CUTOVER_SOCKETS="$HPL_CUTOVER_WORK/sockets"
  HPL_CUTOVER_ROLLBACK_DIR="${HERDR_PANE_LABELS_CUTOVER_ROLLBACK_DIR:-$HPL_CUTOVER_NEW_CACHE/cutover-rollback}"
  HPL_CUTOVER_BACKUP="$HPL_CUTOVER_ROLLBACK_DIR/herdr-task-sync.backup"
  HPL_CUTOVER_CHILD_BACKUP="$HPL_CUTOVER_ROLLBACK_DIR/herdr-child.backup"
  HPL_CUTOVER_STATE_FILE="$HPL_CUTOVER_ROLLBACK_DIR/state"
  : > "$HPL_CUTOVER_SOCKETS"
  hpl_cutover_cleanup_tombstones || return 1
  hpl_cutover_load_transaction
}

# Invoked through the including script's EXIT trap.
# shellcheck disable=SC2329
hpl_cutover_cleanup() {
  [ -z "$HPL_CUTOVER_WORK" ] || [ ! -d "$HPL_CUTOVER_WORK" ] || {
    rm -f "$HPL_CUTOVER_WORK"/* 2>/dev/null || true
    rmdir "$HPL_CUTOVER_WORK" 2>/dev/null || true
  }
}

hpl_cutover_encode_key() {
  printf '%s' "$1" | base64 | tr '/+' '_-' | tr -d '=\n'
}

hpl_cutover_encode_value() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

hpl_cutover_raw_field() {
  local file="$1" key="$2" count value
  [ -f "$file" ] || return 1
  count="$(grep -c "^${key}=" "$file" 2>/dev/null || true)"
  [ "$count" = 1 ] || return 1
  value="$(grep "^${key}=" "$file" 2>/dev/null)"
  printf '%s' "${value#*=}"
}

hpl_cutover_text_field() {
  local raw
  raw="$(hpl_cutover_raw_field "$1" "$2")" || return 1
  printf '%s' "$raw" | base64 -d 2>/dev/null
}

hpl_cutover_number_field() {
  local value
  value="$(hpl_cutover_raw_field "$1" "$2")" || return 1
  case "$value" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s' "$value"
}

hpl_cutover_process_start() {
  ps -p "$1" -o lstart= 2>/dev/null | \
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

hpl_cutover_process_command() {
  ps -ww -p "$1" -o command= 2>/dev/null | \
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

hpl_cutover_pid_is_live() {
  local state
  kill -0 "$1" 2>/dev/null || return 1
  state="$(ps -p "$1" -o stat= 2>/dev/null)" || return 0
  case "$state" in
    *Z*) return 1 ;;
    *) return 0 ;;
  esac
}

hpl_cutover_wait_pid_gone() {
  local pid="$1" attempts=0
  while hpl_cutover_pid_is_live "$pid"; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 200 ] || return 1
    sleep "${HERDR_PANE_LABELS_CUTOVER_POLL:-0.05}"
  done
}

hpl_cutover_command_matches() {
  local command="$1" engine="$2" family="$3" prefix rest
  for prefix in bash /bin/bash /usr/bin/bash; do
    rest="${command#"$prefix $engine "}"
    [ "$rest" != "$command" ] || continue
    case "$family:$rest" in
      daemon:--sweep-daemon) return 0 ;;
      presentation:--presentation-worker | presentation:--sweep | presentation:--sweep-daemon) return 0 ;;
      naming:--worker\ *) return 0 ;;
      old-writer:--worker\ * | old-writer:--agent\ * | old-writer:--event | old-writer:--presentation-worker | old-writer:--sweep | old-writer:--sweep-daemon) return 0 ;;
      new-writer:--event | new-writer:--presentation-worker | new-writer:--sweep | new-writer:--sweep-daemon) return 0 ;;
    esac
  done
  return 1
}

hpl_cutover_socket_for_namespace() {
  local namespace="$1" state socket expected lines
  state="$namespace/socket.state"
  [ -f "$state" ] || return 1
  lines="$(wc -l < "$state" 2>/dev/null | tr -d '[:space:]')" || return 1
  [ "$lines" = 1 ] || return 1
  grep -Ev '^socket_path=' "$state" >/dev/null 2>&1 && return 1
  socket="$(hpl_cutover_text_field "$state" socket_path)" || return 1
  [ -n "$socket" ] || return 1
  expected="$(hpl_cutover_encode_key "$socket")" || return 1
  [ "${namespace##*/}" = "$expected" ] || return 1
  printf '%s' "$socket"
}

hpl_cutover_remove_stale_lock() {
  local lock="$1" identity_file="$2" identity="$3"
  [ "$(cat "$identity_file" 2>/dev/null)" = "$identity" ] || return 1
  rm -f "$identity_file" 2>/dev/null || return 1
  rmdir "$lock" 2>/dev/null || return 1
  hpl_cutover_trace "stale-lock:${lock#"$HOME"/}"
}

# Return 0 for owner-free/stale, 10 after signaling a verified owner, and 1
# when a live record cannot be proved safe to signal.
hpl_cutover_drain_daemon_lock() {
  local lock="$1" engine="$2" socket="$3" pid start command
  local current_pid current_start current_command attempt=0
  while { [ ! -f "$lock/pid" ] || [ ! -s "$lock/pid" ]; } && [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    sleep "${HERDR_PANE_LABELS_CUTOVER_POLL:-0.05}"
  done
  if [ ! -f "$lock/pid" ] || [ ! -s "$lock/pid" ]; then
    # Daemon startup is mkdir followed by a PID write. Removing an empty PID
    # record makes a racing daemon fail its own ownership check before sweeping.
    rm -f "$lock/pid" 2>/dev/null || return 1
    if rmdir "$lock" 2>/dev/null; then
      hpl_cutover_trace "stale-lock:${lock#"$HOME"/}"
      return 10
    fi
    return 10
  fi
  pid="$(cat "$lock/pid" 2>/dev/null)"
  case "$pid" in '' | *[!0-9]*)
    hpl_cutover_error "unverifiable daemon PID in $lock"
    return 1
    ;;
  esac
  if ! hpl_cutover_pid_is_live "$pid"; then
    hpl_cutover_remove_stale_lock "$lock" "$lock/pid" "$pid" || return 1
    return 0
  fi
  start="$(hpl_cutover_process_start "$pid")"
  command="$(hpl_cutover_process_command "$pid")"
  if [ -z "$start" ] || ! hpl_cutover_command_matches "$command" "$engine" daemon; then
    hpl_cutover_error "refusing unrelated or unverifiable daemon PID $pid from $lock"
    return 1
  fi

  # Immediate second identity read closes the PID-reuse and record-replacement
  # interval before TERM.
  hpl_cutover_hook "before-term-daemon:$pid" || return 1
  current_pid="$(cat "$lock/pid" 2>/dev/null)"
  if ! hpl_cutover_pid_is_live "$pid"; then
    [ "$current_pid" != "$pid" ] || hpl_cutover_remove_stale_lock "$lock" "$lock/pid" "$pid" || return 1
    return 0
  fi
  current_start="$(hpl_cutover_process_start "$pid")"
  current_command="$(hpl_cutover_process_command "$pid")"
  if [ "$current_pid" != "$pid" ] || [ "$current_start" != "$start" ] || \
    [ "$current_command" != "$command" ] || \
    ! hpl_cutover_command_matches "$current_command" "$engine" daemon; then
    hpl_cutover_error "daemon identity changed before TERM for PID $pid ($socket)"
    return 1
  fi
  hpl_cutover_trace "term:daemon:$socket:$pid"
  kill -TERM "$pid" 2>/dev/null || return 1
  hpl_cutover_wait_pid_gone "$pid" || {
    hpl_cutover_error "daemon PID $pid survived TERM ($socket)"
    return 1
  }
  return 10
}

hpl_cutover_claim_family() {
  case "$1" in
    */presentation.claim) printf '%s' presentation ;;
    */worker.claim) printf '%s' naming ;;
    *) printf '%s' "$2-writer" ;;
  esac
}

hpl_cutover_drain_claim() {
  local lock="$1" engine="$2" kind="$3" namespace="$4" owner_file owner
  local pid stored_start stored_socket socket start command family
  local current_owner current_pid current_stored_start current_socket current_command second_start attempt=0
  owner_file="$lock/owner"
  while [ ! -f "$owner_file" ] && [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    sleep "${HERDR_PANE_LABELS_CUTOVER_POLL:-0.05}"
  done
  if [ ! -f "$owner_file" ]; then
    # Claim creation is mkdir followed by atomic owner publication. Removing a
    # directory that is still ownerless either clears a stale lock or makes the
    # racing publisher fail its ownership acquisition; a published malformed
    # owner record below remains a hard failure.
    if rmdir "$lock" 2>/dev/null; then
      hpl_cutover_trace "stale-lock:${lock#"$HOME"/}"
      return 10
    fi
    return 10
  fi
  owner="$(hpl_cutover_text_field "$owner_file" owner_id)" || {
    hpl_cutover_error "unverifiable owner record in $lock"
    return 1
  }
  pid="$(hpl_cutover_number_field "$owner_file" pid)" || {
    hpl_cutover_error "unverifiable owner PID in $lock"
    return 1
  }
  stored_start="$(hpl_cutover_text_field "$owner_file" process_start)" || return 1
  stored_socket="$(hpl_cutover_text_field "$owner_file" socket_path)" || return 1
  socket="$(hpl_cutover_socket_for_namespace "$namespace")" || {
    hpl_cutover_error "invalid socket state for $lock"
    return 1
  }
  [ -n "$owner" ] && [ -n "$stored_start" ] && [ "$stored_socket" = "$socket" ] || {
    hpl_cutover_error "owner identity does not match socket for $lock"
    return 1
  }
  if ! hpl_cutover_pid_is_live "$pid"; then
    [ "$(hpl_cutover_text_field "$owner_file" owner_id 2>/dev/null)" = "$owner" ] || return 10
    rm -f "$owner_file" 2>/dev/null || return 1
    rmdir "$lock" 2>/dev/null || return 1
    hpl_cutover_trace "stale-lock:${lock#"$HOME"/}"
    return 0
  fi
  start="$(hpl_cutover_process_start "$pid")"
  command="$(hpl_cutover_process_command "$pid")"
  family="$(hpl_cutover_claim_family "$lock" "$kind")"
  if [ -z "$start" ] || [ "$start" != "$stored_start" ] || \
    ! hpl_cutover_command_matches "$command" "$engine" "$family"; then
    hpl_cutover_error "refusing unrelated or unverifiable owner PID $pid from $lock"
    return 1
  fi

  hpl_cutover_hook "before-term-claim:$pid" || return 1
  current_owner="$(hpl_cutover_text_field "$owner_file" owner_id 2>/dev/null)"
  current_pid="$(hpl_cutover_number_field "$owner_file" pid 2>/dev/null)"
  current_stored_start="$(hpl_cutover_text_field "$owner_file" process_start 2>/dev/null)"
  current_socket="$(hpl_cutover_text_field "$owner_file" socket_path 2>/dev/null)"
  second_start="$(hpl_cutover_process_start "$pid")"
  current_command="$(hpl_cutover_process_command "$pid")"
  if ! hpl_cutover_pid_is_live "$pid"; then return 10; fi
  if [ "$current_owner" != "$owner" ] || [ "$current_pid" != "$pid" ] || \
    [ "$current_stored_start" != "$stored_start" ] || [ "$second_start" != "$start" ] || \
    [ "$current_socket" != "$socket" ] || \
    [ "$current_command" != "$command" ] || \
    ! hpl_cutover_command_matches "$current_command" "$engine" "$family"; then
    hpl_cutover_error "owner identity changed before TERM for PID $pid ($socket)"
    return 1
  fi
  hpl_cutover_trace "term:${family}:$socket:$pid"
  kill -TERM "$pid" 2>/dev/null || return 1
  hpl_cutover_wait_pid_gone "$pid" || {
    hpl_cutover_error "owner PID $pid survived TERM ($socket)"
    return 1
  }
  return 10
}

hpl_cutover_drain_root_scan() {
  local root="$1" engine="$2" kind="$3" lock namespace socket status found=0
  [ -d "$root" ] || return 0

  lock="$root/sweep.lock"
  if [ -d "$lock" ]; then
    found=1
    hpl_cutover_drain_daemon_lock "$lock" "$engine" legacy || status=$?
    status="${status:-0}"
    [ "$status" -ne 1 ] || return 1
  fi
  for lock in "$root"/sockets/*/sweep.lock; do
    [ -d "$lock" ] || continue
    found=1
    namespace="${lock%/sweep.lock}"
    socket="$(hpl_cutover_socket_for_namespace "$namespace")" || {
      hpl_cutover_error "invalid socket state for $lock"
      return 1
    }
    status=0
    hpl_cutover_drain_daemon_lock "$lock" "$engine" "$socket" || status=$?
    [ "$status" -ne 1 ] || return 1
  done
  for lock in \
    "$root"/sockets/*/presentation.claim \
    "$root"/sockets/*/presentation-inbox.lock \
    "$root"/sockets/*/panes/*/worker.claim \
    "$root"/sockets/*/panes/*/control.lock; do
    [ -d "$lock" ] || continue
    found=1
    case "$lock" in
      */panes/*/*) namespace="${lock%%/panes/*}" ;;
      *) namespace="${lock%/*}" ;;
    esac
    status=0
    hpl_cutover_drain_claim "$lock" "$engine" "$kind" "$namespace" || status=$?
    [ "$status" -ne 1 ] || return 1
  done
  [ "$found" -eq 0 ] && return 0
  return 10
}

hpl_cutover_any_live_pid() {
  local root="$1" lock pid
  for lock in "$root/sweep.lock" "$root"/sockets/*/sweep.lock; do
    [ -d "$lock" ] || continue
    pid="$(cat "$lock/pid" 2>/dev/null)"
    case "$pid" in '' | *[!0-9]*) return 0 ;; esac
    hpl_cutover_pid_is_live "$pid" && return 0
  done
  for lock in "$root"/sockets/*/*.claim "$root"/sockets/*/*.lock "$root"/sockets/*/panes/*/*.claim "$root"/sockets/*/panes/*/*.lock; do
    [ -d "$lock" ] || continue
    pid="$(hpl_cutover_number_field "$lock/owner" pid 2>/dev/null)" || return 0
    hpl_cutover_pid_is_live "$pid" && return 0
  done
  return 1
}

hpl_cutover_drain_fixed_point() {
  local free=0 scans=0 old_status new_status
  while [ "$free" -lt 2 ]; do
    scans=$((scans + 1))
    [ "$scans" -le 128 ] || {
      hpl_cutover_error "owner drain did not reach a fixed point"
      return 1
    }
    old_status=0
    new_status=0
    hpl_cutover_drain_root_scan "$HPL_CUTOVER_OLD_CACHE" "$HPL_CUTOVER_OLD_ENGINE" old || old_status=$?
    [ "$old_status" -ne 1 ] || return 1
    hpl_cutover_drain_root_scan "$HPL_CUTOVER_NEW_CACHE" "$HPL_CUTOVER_NEW_ENGINE" new || new_status=$?
    [ "$new_status" -ne 1 ] || return 1
    if hpl_cutover_any_live_pid "$HPL_CUTOVER_OLD_CACHE" || \
      hpl_cutover_any_live_pid "$HPL_CUTOVER_NEW_CACHE"; then
      free=0
    else
      free=$((free + 1))
      hpl_cutover_trace "owner-free:$free"
      hpl_cutover_hook "owner-free-$free" || return 1
    fi
    sleep "${HERDR_PANE_LABELS_CUTOVER_POLL:-0.05}"
  done
}

hpl_cutover_capture_with_deadline() {
  local output="$1" error="$2" deadline pid status=0 wait_status=0 polls=0 max_polls poll
  shift 2
  deadline="${HERDR_PANE_LABELS_CUTOVER_DEADLINE:-10}"
  case "$deadline" in '' | *[!0-9]*) deadline=10 ;; esac
  poll=0.05
  max_polls=$((deadline * 20))
  "$@" </dev/null >"$output" 2>"$error" &
  pid=$!
  while hpl_cutover_pid_is_live "$pid"; do
    polls=$((polls + 1))
    if [ "$polls" -ge "$max_polls" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      hpl_cutover_pid_is_live "$pid" && kill -KILL "$pid" 2>/dev/null || true
      status=124
      break
    fi
    sleep "$poll"
  done
  wait "$pid" || wait_status=$?
  [ "$status" -eq 124 ] || status="$wait_status"
  return "$status"
}

hpl_cutover_run_with_deadline() {
  local output error status=0
  output="$(umask 077; mktemp "$HPL_CUTOVER_WORK/.command.XXXXXX")" || return 1
  error="$output.err"
  hpl_cutover_capture_with_deadline "$output" "$error" "$@" || status=$?
  cat "$output"
  [ "$status" -eq 0 ] || cat "$error" >&2
  rm -f "$output" "$error"
  return "$status"
}

hpl_cutover_run_for_sessions() {
  local socket failed=0
  while IFS= read -r socket; do
    [ -n "$socket" ] || continue
    hpl_cutover_run_with_deadline env HERDR_SOCKET_PATH="$socket" "$@" || failed=1
  done < "$HPL_CUTOVER_SOCKETS"
  return "$failed"
}

hpl_cutover_mark_plugin_linked() {
  HPL_CUTOVER_PLUGIN_LINKED=1
}

hpl_cutover_refresh_sessions() {
  local payload payload_file error_file tmp running_sockets
  if ! command -v herdr >/dev/null 2>&1; then
    if [ "${HPL_CUTOVER_HERDR_PRESENT:-0}" -eq 1 ]; then
      hpl_cutover_error "herdr became unreachable mid-run"
      return 1
    fi
    return 0
  fi
  payload_file="$HPL_CUTOVER_WORK/sessions.json"
  error_file="$HPL_CUTOVER_WORK/sessions.err"
  hpl_cutover_capture_with_deadline "$payload_file" "$error_file" herdr session list --json || {
    hpl_cutover_error "cannot inspect running Herdr sessions"
    return 1
  }
  payload="$(cat "$payload_file")"
  tmp="$HPL_CUTOVER_WORK/sockets.tmp"
  # One pass validates the shape and collects running sockets into a JSON
  # array; jq -e reads false/null on the array itself, not on an exploded
  # empty stream, so a valid session list with no running sockets still
  # exits 0. A second, cheap pass explodes that small array to lines --
  # it never re-scans or re-validates the original payload.
  if ! running_sockets="$(printf '%s' "$payload" | jq -er '
      (.result.sessions // .sessions) as $sessions
      | if ($sessions | type == "array")
             and all($sessions[];
               (.running | type == "boolean")
               and (.running == false or (.socket_path | type == "string" and length > 0)))
        then [$sessions[] | select(.running == true) | .socket_path]
        else error("malformed herdr session list")
        end' 2>/dev/null)"; then
    hpl_cutover_error "malformed herdr session list"
    return 1
  fi
  printf '%s' "$running_sockets" | jq -r '.[]' | LC_ALL=C sort -u > "$tmp"
  hpl_cutover_persist_sockets "$tmp" || return 1
  mv "$tmp" "$HPL_CUTOVER_SOCKETS"
}

hpl_cutover_has_sessions() {
  [ -s "$HPL_CUTOVER_SOCKETS" ]
}

hpl_cutover_load_transaction() {
  local plugin_disabled child_backed_up
  [ -e "$HPL_CUTOVER_ROLLBACK_DIR" ] || return 0
  [ -d "$HPL_CUTOVER_ROLLBACK_DIR" ] && [ -f "$HPL_CUTOVER_BACKUP" ] && [ -f "$HPL_CUTOVER_STATE_FILE" ] || {
    hpl_cutover_error "invalid persistent rollback transaction in $HPL_CUTOVER_ROLLBACK_DIR"
    return 1
  }
  HPL_CUTOVER_BACKUP_MODE="$(hpl_cutover_raw_field "$HPL_CUTOVER_STATE_FILE" mode)" || return 1
  HPL_CUTOVER_PHASE="$(hpl_cutover_raw_field "$HPL_CUTOVER_STATE_FILE" phase)" || return 1
  plugin_disabled="$(hpl_cutover_raw_field "$HPL_CUTOVER_STATE_FILE" plugin_disabled)" || return 1
  child_backed_up="$(hpl_cutover_raw_field "$HPL_CUTOVER_STATE_FILE" child_backed_up)" || return 1
  HPL_CUTOVER_CHILD_BACKUP_MODE="$(hpl_cutover_raw_field "$HPL_CUTOVER_STATE_FILE" child_mode)" || return 1
  case "$HPL_CUTOVER_BACKUP_MODE" in '' | *[!0-7]*) return 1 ;; esac
  case "$HPL_CUTOVER_PHASE" in prepared | deployed) ;; *) return 1 ;; esac
  case "$plugin_disabled" in 0 | 1) HPL_CUTOVER_PLUGIN_DISABLED="$plugin_disabled" ;; *) return 1 ;; esac
  case "$child_backed_up" in 0 | 1) HPL_CUTOVER_CHILD_BACKED_UP="$child_backed_up" ;; *) return 1 ;; esac
  if [ "$HPL_CUTOVER_CHILD_BACKED_UP" -eq 1 ]; then
    [ -f "$HPL_CUTOVER_CHILD_BACKUP" ] || return 1
    case "$HPL_CUTOVER_CHILD_BACKUP_MODE" in '' | *[!0-7]*) return 1 ;; esac
  fi
  [ ! -f "$HPL_CUTOVER_ROLLBACK_DIR/sockets" ] || cp "$HPL_CUTOVER_ROLLBACK_DIR/sockets" "$HPL_CUTOVER_SOCKETS"
}

hpl_cutover_snapshot_is_complete() {
  jq -e '
    def safe_string: type == "string" and (test("[\u0000-\u001f\u007f]") | not);
    def nonempty_string: safe_string and length > 0;
    def optional_safe_string: . == null or safe_string;
    def finite_number: type == "number" and (tostring | test("nan|infinite"; "i") | not);
    def optional_session:
      (has("agent_session") | not) or .agent_session == null or
      ((.agent_session | type) == "object" and
       (.agent_session.agent | nonempty_string) and
       (.agent_session.kind | nonempty_string) and
       (.agent_session.source | nonempty_string) and
       (.agent_session.value | nonempty_string));
    .result.snapshot as $s
    | ($s | type) == "object"
      and ($s.panes | type) == "array"
      and ($s.tabs | type) == "array"
      and ($s.agents | type) == "array"
      and ($s.layouts | type) == "array"
      and ($s.workspaces | type) == "array"
      and all($s.panes[];
        (.pane_id | nonempty_string) and (.terminal_id | nonempty_string) and
        (.tab_id | nonempty_string) and (.workspace_id | nonempty_string) and
        (.revision | finite_number) and (.label | safe_string) and
        ((has("agent") | not) or .agent == null or (.agent | nonempty_string)) and optional_session)
      and all($s.tabs[];
        (.tab_id | nonempty_string) and (.workspace_id | nonempty_string) and (.label | safe_string))
      and all($s.workspaces[];
        (.workspace_id | nonempty_string) and
        ((has("label") | not) or (.label | optional_safe_string)) and
        ((has("name") | not) or (.name | optional_safe_string)))
      and all($s.agents[];
        (.pane_id | nonempty_string) and (.agent | nonempty_string) and
        (.terminal_id | nonempty_string) and (.revision | finite_number) and
        (.state_change_seq | finite_number) and
        ((has("tab_id") | not) or .tab_id == null or (.tab_id | nonempty_string)) and
        ((has("workspace_id") | not) or .workspace_id == null or (.workspace_id | nonempty_string)) and
        ((has("name") | not) or (.name | nonempty_string)) and optional_session)
      and (($s.panes | map(.pane_id) | length) == ($s.panes | map(.pane_id) | unique | length))
      and (($s.panes | map(.terminal_id) | length) == ($s.panes | map(.terminal_id) | unique | length))
      and (($s.tabs | map(.tab_id) | length) == ($s.tabs | map(.tab_id) | unique | length))
      and (($s.workspaces | map(.workspace_id) | length) == ($s.workspaces | map(.workspace_id) | unique | length))
      and (($s.agents | map(.pane_id) | length) == ($s.agents | map(.pane_id) | unique | length))
      and (($s.agents | map(.terminal_id) | length) == ($s.agents | map(.terminal_id) | unique | length))
      and (($s.agents | map(select(has("name")) | .name) | length) ==
           ($s.agents | map(select(has("name")) | .name) | unique | length))
      and all($s.panes[]; . as $p |
        ([$s.tabs[] | select(.tab_id == $p.tab_id and .workspace_id == $p.workspace_id)] | length) == 1)
      and all($s.tabs[]; . as $t |
        ([$s.workspaces[] | select(.workspace_id == $t.workspace_id)] | length) == 1)
      and all($s.panes[]; . as $p |
        if (($p.agent // "") != "") then
          ([$s.agents[] | select(.pane_id == $p.pane_id)] | length) == 1 and
          ([$s.agents[] | select(.pane_id == $p.pane_id)][0] as $a |
            $a.agent == $p.agent and $a.terminal_id == $p.terminal_id and
            (($a.tab_id // $p.tab_id) == $p.tab_id) and
            (($a.workspace_id // $p.workspace_id) == $p.workspace_id) and
            (($a.agent_session // null) == ($p.agent_session // null)))
        else ([$s.agents[] | select(.pane_id == $p.pane_id)] | length) == 0 end)
      and all($s.agents[]; . as $a |
        ([$s.panes[] | select(.pane_id == $a.pane_id and (.agent // "") == $a.agent and
          .terminal_id == $a.terminal_id)] | length) == 1)
  ' >/dev/null 2>&1
}

hpl_cutover_disable_plugin() {
  hpl_cutover_has_sessions || return 0
  HPL_CUTOVER_PLUGIN_DISABLED=1
  hpl_cutover_set_transaction_state "$HPL_CUTOVER_PHASE" 1 || return 1
  hpl_cutover_run_for_sessions herdr plugin disable "$HPL_CUTOVER_PLUGIN_ID" >/dev/null 2>&1 || {
    hpl_cutover_error "failed to disable $HPL_CUTOVER_PLUGIN_ID"
    return 1
  }
  hpl_cutover_trace plugin-disabled
}

hpl_cutover_mode_for_engine() {
  case "$1" in
    "$HPL_CUTOVER_OLD_ENGINE") printf '%s' --ensure-daemon ;;
    "$HPL_CUTOVER_NEW_ENGINE") printf '%s' --ensure-sweep-daemon ;;
    *) return 1 ;;
  esac
}

hpl_cutover_freeze_old_entry() {
  local tmp stage parent child_mode child_backed_up=0
  if [ -e "$HPL_CUTOVER_ROLLBACK_DIR" ]; then
    if { [ "$HPL_CUTOVER_PHASE" = deployed ] || [ ! -e "$HPL_CUTOVER_OLD_ENGINE" ]; } && [ -x "$HPL_CUTOVER_NEW_ENGINE" ]; then
      HPL_CUTOVER_PHASE=deployed
      hpl_cutover_set_transaction_state deployed "$HPL_CUTOVER_PLUGIN_DISABLED" || return 1
      HPL_CUTOVER_FROZEN=0
      HPL_CUTOVER_ROLLBACK_ENGINE="$HPL_CUTOVER_NEW_ENGINE"
      HPL_CUTOVER_ROLLBACK_CACHE="$HPL_CUTOVER_NEW_CACHE"
      return 0
    fi
    HPL_CUTOVER_FROZEN=1
    HPL_CUTOVER_ROLLBACK_ENGINE="$HPL_CUTOVER_OLD_ENGINE"
    HPL_CUTOVER_ROLLBACK_CACHE="$HPL_CUTOVER_OLD_CACHE"
    [ -e "$HPL_CUTOVER_OLD_ENGINE" ] || return 0
  fi
  [ -e "$HPL_CUTOVER_OLD_ENGINE" ] || return 0
  [ -f "$HPL_CUTOVER_OLD_ENGINE" ] || {
    hpl_cutover_error "$HPL_CUTOVER_OLD_ENGINE is not a regular file"
    return 1
  }
  HPL_CUTOVER_BACKUP_MODE="$(stat -f '%Lp' "$HPL_CUTOVER_OLD_ENGINE" 2>/dev/null)" || \
    HPL_CUTOVER_BACKUP_MODE=""
  case "$HPL_CUTOVER_BACKUP_MODE" in
    '' | *[!0-7]*)
      HPL_CUTOVER_BACKUP_MODE="$(stat -c '%a' "$HPL_CUTOVER_OLD_ENGINE" 2>/dev/null)" || return 1
      ;;
  esac
  case "$HPL_CUTOVER_BACKUP_MODE" in '' | *[!0-7]*) return 1 ;; esac
  if [ ! -f "$HPL_CUTOVER_BACKUP" ]; then
    parent="${HPL_CUTOVER_ROLLBACK_DIR%/*}"
    mkdir -p "$parent" || return 1
    chmod 700 "$parent" 2>/dev/null || true
    stage="$(umask 077; mktemp -d "$parent/.cutover-rollback.XXXXXX")" || return 1
    cp -p "$HPL_CUTOVER_OLD_ENGINE" "$stage/herdr-task-sync.backup" || { rmdir "$stage" 2>/dev/null; return 1; }
    child_mode=""
    if [ -e "$HPL_CUTOVER_CHILD" ]; then
      [ -f "$HPL_CUTOVER_CHILD" ] || return 1
      child_mode="$(stat -f '%Lp' "$HPL_CUTOVER_CHILD" 2>/dev/null)" || child_mode=""
      case "$child_mode" in
        '' | *[!0-7]*) child_mode="$(stat -c '%a' "$HPL_CUTOVER_CHILD" 2>/dev/null)" || return 1 ;;
      esac
      case "$child_mode" in '' | *[!0-7]*) return 1 ;; esac
      cp -p "$HPL_CUTOVER_CHILD" "$stage/herdr-child.backup" || return 1
      child_backed_up=1
    fi
    printf 'mode=%s\nphase=prepared\nplugin_disabled=0\nchild_backed_up=%s\nchild_mode=%s\n' \
      "$HPL_CUTOVER_BACKUP_MODE" "$child_backed_up" "$child_mode" > "$stage/state" || {
      rm -f "$stage/herdr-task-sync.backup"; rmdir "$stage" 2>/dev/null; return 1;
    }
    : > "$stage/sockets" || {
      rm -f "$stage/herdr-task-sync.backup" "$stage/state"; rmdir "$stage" 2>/dev/null; return 1;
    }
    mv "$stage" "$HPL_CUTOVER_ROLLBACK_DIR" || {
      rm -f "$stage/herdr-task-sync.backup" "$stage/herdr-child.backup" "$stage/state" "$stage/sockets"; rmdir "$stage" 2>/dev/null; return 1;
    }
    HPL_CUTOVER_CHILD_BACKED_UP="$child_backed_up"
    HPL_CUTOVER_CHILD_BACKUP_MODE="$child_mode"
  fi
  tmp="$HPL_CUTOVER_OLD_ENGINE.cutover.$$"
  (umask 022; printf '%s\n' '#!/bin/sh' 'exit 0' > "$tmp") || return 1
  chmod "$HPL_CUTOVER_BACKUP_MODE" "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$HPL_CUTOVER_OLD_ENGINE" || { rm -f "$tmp"; return 1; }
  HPL_CUTOVER_FROZEN=1
  HPL_CUTOVER_ROLLBACK_ENGINE="$HPL_CUTOVER_OLD_ENGINE"
  HPL_CUTOVER_ROLLBACK_CACHE="$HPL_CUTOVER_OLD_CACHE"
  hpl_cutover_trace old-entry-frozen
  hpl_cutover_hook old-entry-frozen || return 1
}

hpl_cutover_freeze_child_entry() {
  local tmp
  [ "$HPL_CUTOVER_CHILD_BACKED_UP" -eq 1 ] || return 0
  [ -f "$HPL_CUTOVER_CHILD" ] || {
    hpl_cutover_error "$HPL_CUTOVER_CHILD is not a regular file"
    return 1
  }
  tmp="$HPL_CUTOVER_CHILD.cutover.$$"
  (umask 022; printf '%s\n' '#!/bin/sh' \
    'printf "%s\\n" "herdr-child: unavailable during pane-label cutover" >&2' 'exit 1' > "$tmp") || return 1
  chmod "$HPL_CUTOVER_CHILD_BACKUP_MODE" "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$HPL_CUTOVER_CHILD" || { rm -f "$tmp"; return 1; }
  hpl_cutover_trace child-entry-frozen
}

hpl_cutover_select_rollback_engine() {
  if [ -x "$HPL_CUTOVER_OLD_ENGINE" ]; then
    HPL_CUTOVER_ROLLBACK_ENGINE="$HPL_CUTOVER_OLD_ENGINE"
    HPL_CUTOVER_ROLLBACK_CACHE="$HPL_CUTOVER_OLD_CACHE"
  elif [ -x "$HPL_CUTOVER_NEW_ENGINE" ]; then
    HPL_CUTOVER_ROLLBACK_ENGINE="$HPL_CUTOVER_NEW_ENGINE"
    HPL_CUTOVER_ROLLBACK_CACHE="$HPL_CUTOVER_NEW_CACHE"
  fi
}

hpl_cutover_restore_old_entry() {
  local tmp
  [ "$HPL_CUTOVER_FROZEN" -eq 1 ] || return 0
  tmp="$HPL_CUTOVER_OLD_ENGINE.restore.$$"
  cp -p "$HPL_CUTOVER_BACKUP" "$tmp" || return 1
  mv "$tmp" "$HPL_CUTOVER_OLD_ENGINE" || { rm -f "$tmp"; return 1; }
  cmp -s "$HPL_CUTOVER_BACKUP" "$HPL_CUTOVER_OLD_ENGINE" || return 1
  HPL_CUTOVER_FROZEN=0
  hpl_cutover_trace old-entry-restored
}

hpl_cutover_restore_child_entry() {
  local tmp
  [ "$HPL_CUTOVER_CHILD_BACKED_UP" -eq 1 ] || return 0
  tmp="$HPL_CUTOVER_CHILD.restore.$$"
  cp -p "$HPL_CUTOVER_CHILD_BACKUP" "$tmp" || return 1
  mv "$tmp" "$HPL_CUTOVER_CHILD" || { rm -f "$tmp"; return 1; }
  cmp -s "$HPL_CUTOVER_CHILD_BACKUP" "$HPL_CUTOVER_CHILD" || return 1
  hpl_cutover_trace child-entry-restored
}

hpl_cutover_set_transaction_state() {
  local phase="$1" plugin_disabled="$2"
  [ -d "$HPL_CUTOVER_ROLLBACK_DIR" ] || return 0
  hpl_cutover_atomic_write "$HPL_CUTOVER_STATE_FILE" "mode=$HPL_CUTOVER_BACKUP_MODE
phase=$phase
plugin_disabled=$plugin_disabled
child_backed_up=$HPL_CUTOVER_CHILD_BACKED_UP
child_mode=$HPL_CUTOVER_CHILD_BACKUP_MODE"
}

hpl_cutover_persist_sockets() {
  local source="$1" tmp
  [ -d "$HPL_CUTOVER_ROLLBACK_DIR" ] || return 0
  tmp="$HPL_CUTOVER_ROLLBACK_DIR/.sockets.$$"
  cp "$source" "$tmp" || return 1
  mv "$tmp" "$HPL_CUTOVER_ROLLBACK_DIR/sockets" || { rm -f "$tmp"; return 1; }
}

hpl_cutover_mark_deployed() {
  if [ "$HPL_CUTOVER_CHILD_BACKED_UP" -eq 1 ]; then
    [ -x "$HPL_CUTOVER_CHILD" ] && ! cmp -s "$HPL_CUTOVER_CHILD_BACKUP" "$HPL_CUTOVER_CHILD" || {
      hpl_cutover_error "managed herdr-child was not deployed before the after phase"
      return 1
    }
    HPL_CUTOVER_CHILD_BACKED_UP=0
    HPL_CUTOVER_CHILD_BACKUP_MODE=""
  fi
  HPL_CUTOVER_PHASE=deployed
  hpl_cutover_set_transaction_state deployed "$HPL_CUTOVER_PLUGIN_DISABLED" || return 1
  rm -f "$HPL_CUTOVER_CHILD_BACKUP"
}

hpl_cutover_cleanup_tombstones() {
  local tombstone
  for tombstone in "$HPL_CUTOVER_NEW_CACHE"/cutover-rollback.done.* "$HPL_CUTOVER_NEW_CACHE"/.cutover-rollback.*; do
    [ -d "$tombstone" ] || continue
    rm -f "$tombstone"/* "$tombstone"/.cutover.* "$tombstone"/.sockets.* 2>/dev/null || return 1
    rmdir "$tombstone" 2>/dev/null || return 1
  done
}

hpl_cutover_clear_rollback_artifact() {
  local tombstone
  [ -d "$HPL_CUTOVER_ROLLBACK_DIR" ] || return 0
  tombstone="$HPL_CUTOVER_NEW_CACHE/cutover-rollback.done.$$"
  mv "$HPL_CUTOVER_ROLLBACK_DIR" "$tombstone" || return 1
  rm -f "$tombstone"/* "$tombstone"/.cutover.* "$tombstone"/.sockets.* || return 1
  rmdir "$tombstone"
}

hpl_cutover_commit() {
  hpl_cutover_clear_rollback_artifact || {
    hpl_cutover_error "could not clear the persistent rollback artifact"
    return 1
  }
  hpl_cutover_trace cutover-committed
}

hpl_cutover_validate_aliases() {
  local socket snapshot rows alias pane
  hpl_cutover_has_sessions || return 0
  herdr_alias_validate_pool || return 1
  while IFS= read -r socket; do
    [ -n "$socket" ] || continue
    snapshot="$(hpl_cutover_run_with_deadline env HERDR_SOCKET_PATH="$socket" herdr api snapshot 2>/dev/null)" || return 1
    printf '%s' "$snapshot" | hpl_cutover_snapshot_is_complete || return 1
    rows="$(printf '%s' "$snapshot" | jq -r '
      .result.snapshot.agents[]
      | select((.name // "") != "")
      | [.name,.pane_id] | @tsv')" || return 1
    while IFS="$(printf '\t')" read -r alias pane; do
      [ -n "$alias" ] || continue
      if ! herdr_alias_in_pool "$alias"; then
        hpl_cutover_error "registered non-pool alias '$alias' on pane '$pane' blocks cutover"
        return 1
      fi
    done <<EOF
$rows
EOF
  done < "$HPL_CUTOVER_SOCKETS"
}

hpl_cutover_atomic_write() {
  local file="$1" content="$2" dir tmp
  [ ! -d "$file" ] || return 1
  dir="${file%/*}"
  mkdir -p "$dir" || return 1
  tmp="$(umask 077; mktemp "$dir/.cutover.XXXXXX")" || return 1
  printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  [ -f "$file" ]
}

hpl_cutover_validate_location_file() {
  local file="$1" expected_pane="$2" key value lines
  lines="$(wc -l < "$file" | tr -d '[:space:]')"
  [ "$lines" = 7 ] || return 1
  for key in pane checkout_root repository_anchor repo branch is_linked sha; do
    value="$(hpl_cutover_text_field "$file" "$key")" || return 1
    if [ "$key" = pane ] && [ "$value" != "$expected_pane" ]; then return 1; fi
    if [ "$key" = is_linked ]; then
      case "$value" in '' | 1) ;; *) return 1 ;; esac
    fi
  done
  grep -Ev '^(pane|checkout_root|repository_anchor|repo|branch|is_linked|sha)=' "$file" >/dev/null 2>&1 && return 1
  return 0
}

hpl_cutover_migrate_location_state() {
  local old_namespace new_namespace socket socket_record old_reconcile new_reconcile
  local location_metadata checkout_root repository_anchor retained_location content
  local old_location pane pane_key new_location
  [ -d "$HPL_CUTOVER_OLD_CACHE/sockets" ] || return 0
  for old_namespace in "$HPL_CUTOVER_OLD_CACHE"/sockets/*; do
    [ -d "$old_namespace" ] || continue
    socket="$(hpl_cutover_socket_for_namespace "$old_namespace")" || {
      hpl_cutover_trace "migration-skipped-invalid-socket:${old_namespace##*/}"
      continue
    }
    new_namespace="$HPL_CUTOVER_NEW_CACHE/sockets/$(hpl_cutover_encode_key "$socket")"
    mkdir -p "$new_namespace/panes" || return 1
    chmod 700 "$HPL_CUTOVER_NEW_CACHE" "$HPL_CUTOVER_NEW_CACHE/sockets" "$new_namespace" 2>/dev/null || true
    socket_record="socket_path=$(hpl_cutover_encode_value "$socket")"
    if [ -f "$new_namespace/socket.state" ]; then
      [ "$(hpl_cutover_socket_for_namespace "$new_namespace")" = "$socket" ] || return 1
    else
      hpl_cutover_atomic_write "$new_namespace/socket.state" "$socket_record" || return 1
    fi

    old_reconcile="$old_namespace/reconcile.state"
    new_reconcile="$new_namespace/reconcile.state"
    if [ ! -f "$new_reconcile" ] && [ -f "$old_reconcile" ]; then
      if location_metadata="$(hpl_cutover_number_field "$old_reconcile" location_metadata_high_water)" && \
        checkout_root="$(hpl_cutover_text_field "$old_reconcile" checkout_root)" && \
        repository_anchor="$(hpl_cutover_text_field "$old_reconcile" repository_anchor)" && \
        retained_location="$(hpl_cutover_text_field "$old_reconcile" retained_location)"; then
        content="pending_generation=0
completed_generation=0
location_metadata_high_water=$location_metadata
checkout_root=$(hpl_cutover_encode_value "$checkout_root")
repository_anchor=$(hpl_cutover_encode_value "$repository_anchor")
retained_location=$(hpl_cutover_encode_value "$retained_location")"
        hpl_cutover_atomic_write "$new_reconcile" "$content" || return 1
      else
        hpl_cutover_trace "migration-skipped-invalid-reconcile:${old_namespace##*/}"
      fi
    fi

    for old_location in "$old_namespace"/panes/*/location.state; do
      [ -f "$old_location" ] || continue
      pane="$(hpl_cutover_text_field "$old_location" pane 2>/dev/null)" || continue
      [ -n "$pane" ] || continue
      pane_key="$(hpl_cutover_encode_key "$pane")"
      [ "${old_location%/location.state}" = "$old_namespace/panes/$pane_key" ] || continue
      hpl_cutover_validate_location_file "$old_location" "$pane" || continue
      new_location="$new_namespace/panes/$pane_key/location.state"
      [ -f "$new_location" ] || hpl_cutover_atomic_write "$new_location" "$(cat "$old_location")" || return 1
    done
  done
  hpl_cutover_trace location-state-migrated
}

hpl_cutover_clear_task_tokens() {
  local socket snapshot panes pane fresh
  while IFS= read -r socket; do
    [ -n "$socket" ] || continue
    snapshot="$(hpl_cutover_run_with_deadline env HERDR_SOCKET_PATH="$socket" herdr api snapshot 2>/dev/null)" || return 1
    printf '%s' "$snapshot" | hpl_cutover_snapshot_is_complete || return 1
    panes="$(printf '%s' "$snapshot" | jq -r '
      .result.snapshot.panes[] | .pane_id' 2>/dev/null)" || return 1
    while IFS= read -r pane; do
      [ -n "$pane" ] || continue
      hpl_cutover_run_with_deadline env HERDR_SOCKET_PATH="$socket" herdr pane report-metadata "$pane" \
        --source task-sync --clear-token task >/dev/null 2>&1 || return 1
      hpl_cutover_trace "task-token-cleared:$socket:$pane"
    done <<EOF
$panes
EOF
    fresh="$(hpl_cutover_run_with_deadline env HERDR_SOCKET_PATH="$socket" herdr api snapshot 2>/dev/null)" || return 1
    printf '%s' "$fresh" | hpl_cutover_snapshot_is_complete || return 1
    printf '%s' "$fresh" | jq -e '
      .result.snapshot.panes | all(.[]; ((.tokens // {}) | has("task") | not))' \
      >/dev/null 2>&1 || {
        hpl_cutover_error "task token remained after clear on $socket"
        return 1
      }
    hpl_cutover_trace "task-token-verified:$socket"
  done < "$HPL_CUTOVER_SOCKETS"
}

hpl_cutover_verify_daemon() {
  local socket="$1" engine="$2" cache="$3" namespace lock pid start command
  local tries=0 second_start second_command
  namespace="$cache/sockets/$(hpl_cutover_encode_key "$socket")"
  lock="$namespace/sweep.lock"
  while [ "$tries" -lt 100 ]; do
    tries=$((tries + 1))
    pid="$(cat "$lock/pid" 2>/dev/null)"
    case "$pid" in '' | *[!0-9]*) sleep "${HERDR_PANE_LABELS_CUTOVER_POLL:-0.05}"; continue ;; esac
    if hpl_cutover_pid_is_live "$pid"; then break; fi
    sleep "${HERDR_PANE_LABELS_CUTOVER_POLL:-0.05}"
  done
  case "${pid:-}" in '' | *[!0-9]*) return 1 ;; esac
  hpl_cutover_pid_is_live "$pid" || return 1
  [ "$(hpl_cutover_socket_for_namespace "$namespace")" = "$socket" ] || return 1
  start="$(hpl_cutover_process_start "$pid")"
  command="$(hpl_cutover_process_command "$pid")"
  [ -n "$start" ] && hpl_cutover_command_matches "$command" "$engine" daemon || return 1
  [ "$(cat "$lock/pid" 2>/dev/null)" = "$pid" ] || return 1
  second_start="$(hpl_cutover_process_start "$pid")"
  second_command="$(hpl_cutover_process_command "$pid")"
  [ "$second_start" = "$start" ] && [ "$second_command" = "$command" ] || return 1
  hpl_cutover_trace "daemon-verified:$socket:$pid:$start"
}

# A strict sweep compares the whole snapshot identity across its pass, so a
# concurrent agent state change in any pane fails it even when every label
# converged. That condition is transient: the next attempt reads a fresh
# snapshot. A pass that genuinely cannot converge fails every attempt, so the
# retries cost a real failure only the pauses between them.
hpl_cutover_strict_sweep() {
  local socket="$1" attempt=1 attempts pause
  attempts="${HERDR_PANE_LABELS_CUTOVER_SWEEP_ATTEMPTS:-4}"
  pause="${HERDR_PANE_LABELS_CUTOVER_SWEEP_PAUSE:-2}"
  case "$attempts" in '' | 0 | *[!0-9]*) attempts=4 ;; esac
  while :; do
    if hpl_cutover_run_with_deadline env HERDR_SOCKET_PATH="$socket" HERDR_PANE_LABELS_STRICT_SWEEP=1 \
      "$HPL_CUTOVER_NEW_ENGINE" --sweep >/dev/null; then
      hpl_cutover_trace "first-pass:$socket"
      return 0
    fi
    [ "$attempt" -lt "$attempts" ] || {
      hpl_cutover_error "strict pane-label sweep did not converge for $socket in $attempt attempts"
      return 1
    }
    hpl_cutover_trace "strict-sweep-retry:$socket:$attempt"
    attempt=$((attempt + 1))
    [ "$pause" = 0 ] || sleep "$pause"
  done
}

hpl_cutover_ensure_all() {
  local engine="$1" cache="$2" mode socket
  [ -x "$engine" ] || return 1
  mode="$(hpl_cutover_mode_for_engine "$engine")"
  while IFS= read -r socket; do
    [ -n "$socket" ] || continue
    hpl_cutover_trace "ensure:$socket:$mode"
    hpl_cutover_run_with_deadline env HERDR_SOCKET_PATH="$socket" "$engine" "$mode" >/dev/null 2>&1 || return 1
    hpl_cutover_verify_daemon "$socket" "$engine" "$cache" || {
      hpl_cutover_error "failed to verify one daemon for $socket"
      return 1
    }
  done < "$HPL_CUTOVER_SOCKETS"
}

hpl_cutover_rollback() {
  local failed=0
  hpl_cutover_restore_old_entry || failed=1
  hpl_cutover_restore_child_entry || failed=1
  if [ "$HPL_CUTOVER_PLUGIN_DISABLED" -eq 1 ] && command -v herdr >/dev/null 2>&1; then
    hpl_cutover_run_for_sessions herdr plugin enable "$HPL_CUTOVER_PLUGIN_ID" >/dev/null 2>&1 || failed=1
    hpl_cutover_run_for_sessions herdr server reload-config >/dev/null 2>&1 || failed=1
    hpl_cutover_trace plugin-reenabled
  fi
  if hpl_cutover_has_sessions && [ -n "$HPL_CUTOVER_ROLLBACK_ENGINE" ]; then
    hpl_cutover_ensure_all "$HPL_CUTOVER_ROLLBACK_ENGINE" "$HPL_CUTOVER_ROLLBACK_CACHE" || failed=1
  fi
  [ "$failed" -ne 0 ] || hpl_cutover_clear_rollback_artifact || failed=1
  [ "$failed" -eq 0 ] || hpl_cutover_error "rollback could not restore every old daemon"
  return "$failed"
}

# Used only by the including after-script.
# shellcheck disable=SC2329
hpl_cutover_fail_after_deploy() {
  local failed=0
  if command -v herdr >/dev/null 2>&1; then
    hpl_cutover_run_for_sessions herdr plugin disable "$HPL_CUTOVER_PLUGIN_ID" >/dev/null 2>&1 || failed=1
    if [ "$HPL_CUTOVER_PLUGIN_LINKED" -eq 1 ]; then
      hpl_cutover_run_with_deadline env -u HERDR_SOCKET_PATH herdr plugin link \
        "$HPL_CUTOVER_PLUGIN_DIR" --disabled >/dev/null 2>&1 || failed=1
    fi
  fi
  hpl_cutover_drain_fixed_point >/dev/null 2>&1 || failed=1
  [ "$failed" -eq 0 ] || hpl_cutover_error "post-deploy cleanup could not disable and drain every writer"
  return "$failed"
}
