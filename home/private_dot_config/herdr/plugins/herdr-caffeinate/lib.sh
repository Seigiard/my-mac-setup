# shellcheck shell=sh
# Shared helpers for the herdr Caffeinate plugin.
# Sourced by reconcile.sh and actions.sh. POSIX sh; macOS-only.

# --- Paths ------------------------------------------------------------------
PLUGIN_DIR=${HERDR_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
STATE_DIR=${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-caffeinate}
CONFIG_DIR=${HERDR_PLUGIN_CONFIG_DIR:-$HOME/.config/herdr-caffeinate}
PIDFILE="$STATE_DIR/caffeinate.pid"
MODEFILE="$STATE_DIR/caffeinate.mode"
LOCK="$STATE_DIR/lock"
HERDR=${HERDR_BIN_PATH:-herdr}

mkdir -p "$STATE_DIR" 2>/dev/null || true
mkdir -p "$CONFIG_DIR" 2>/dev/null || true

# --- Config -----------------------------------------------------------------
# Defaults; overridden by $CONFIG_DIR/config.sh (auto-seeded on first run).
AWAKE_STATES="working"      # space-separated agent_status values that hold the lock
CAFFEINATE_FLAGS="-di"      # prevent system idle sleep AND keep the display on
LINGER_SECONDS=1200         # stay awake this long after the last agent goes quiet (0 = release immediately)

if [ ! -f "$CONFIG_DIR/config.sh" ] && [ -f "$PLUGIN_DIR/config.example.sh" ]; then
    cp "$PLUGIN_DIR/config.example.sh" "$CONFIG_DIR/config.sh" 2>/dev/null || true
fi
# shellcheck disable=SC1090
[ -f "$CONFIG_DIR/config.sh" ] && . "$CONFIG_DIR/config.sh"

# --- Locking (atomic mkdir, self-healing) -----------------------------------
LOCK_HELD=0

acquire_lock() {
    _n=0
    while ! mkdir "$LOCK" 2>/dev/null; do
        # Break a stale lock left by a crashed reconcile (>15s old).
        if _mt=$(stat -f %m "$LOCK" 2>/dev/null); then
            _now=$(date +%s)
            [ $((_now - _mt)) -gt 15 ] && { rmdir "$LOCK" 2>/dev/null; continue; }
        fi
        _n=$((_n + 1))
        [ "$_n" -ge 30 ] && return 1   # give up after ~3s
        sleep 0.1
    done
    LOCK_HELD=1
    trap 'release_lock' EXIT INT TERM HUP
    return 0
}

release_lock() {
    [ "$LOCK_HELD" = 1 ] || return 0
    rmdir "$LOCK" 2>/dev/null
    LOCK_HELD=0
}

# --- caffeinate process management ------------------------------------------
# Echo the tracked caffeinate PID if it is alive and really caffeinate.
# Returns non-zero (and echoes nothing) otherwise. Guards against PID reuse.
caffeinate_pid() {
    [ -f "$PIDFILE" ] || return 1
    _pid=$(cat "$PIDFILE" 2>/dev/null)
    case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
    _comm=$(ps -p "$_pid" -o comm= 2>/dev/null) || return 1
    case "$_comm" in *caffeinate) printf '%s' "$_pid"; return 0 ;; esac
    return 1
}

start_caffeinate() {
    _hpid=$(pgrep -x herdr 2>/dev/null | head -1)
    # -w <herdr pid>: auto-release the wake lock if herdr itself dies.
    # nohup + detach so the assertion outlives this short-lived hook process.
    if [ -n "$_hpid" ]; then
        # shellcheck disable=SC2086
        nohup caffeinate $CAFFEINATE_FLAGS -w "$_hpid" >/dev/null 2>&1 &
    else
        # shellcheck disable=SC2086
        nohup caffeinate $CAFFEINATE_FLAGS >/dev/null 2>&1 &
    fi
    echo $! > "$PIDFILE"
    echo hold > "$MODEFILE"
}

# Time-limited caffeinate for the linger window after the last agent goes
# quiet. No -w: if herdr dies mid-linger the assertion still expires on its
# own after $LINGER_SECONDS.
start_linger() {
    # shellcheck disable=SC2086
    nohup caffeinate $CAFFEINATE_FLAGS -t "$LINGER_SECONDS" >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    echo linger > "$MODEFILE"
}

caffeinate_mode() {
    cat "$MODEFILE" 2>/dev/null
}

stop_caffeinate() {
    if _pid=$(caffeinate_pid); then
        kill "$_pid" 2>/dev/null
    fi
    rm -f "$PIDFILE" "$MODEFILE"
}

# --- State query ------------------------------------------------------------
# Echo "yes" if any agent's status is in $AWAKE_STATES, else "no".
any_agent_working() {
    _out=$("$HERDR" agent list 2>/dev/null) || { echo no; return; }

    if command -v jq >/dev/null 2>&1; then
        _res=$(printf '%s' "$_out" | jq -r --arg want "$AWAKE_STATES" '
            ($want | split(" ") | map(select(. != ""))) as $w
            | [.result.agents[]?.agent_status]
            | any(. as $s | $w | index($s))
            | if . then "yes" else "no" end' 2>/dev/null)
        [ -n "$_res" ] && { echo "$_res"; return; }
    fi

    # Fallback (no jq): match compact JSON keys after stripping whitespace.
    _flat=$(printf '%s' "$_out" | tr -d ' \t\n')
    for _s in $AWAKE_STATES; do
        case "$_flat" in
            *"\"agent_status\":\"$_s\""*) echo yes; return ;;
        esac
    done
    echo no
}

# --- Reconcile: make caffeinate match desired state -------------------------
reconcile() {
    acquire_lock || return 0
    case "$LINGER_SECONDS" in ''|*[!0-9]*) LINGER_SECONDS=0 ;; esac
    if [ "$(any_agent_working)" = yes ]; then
        if ! caffeinate_pid >/dev/null 2>&1 || [ "$(caffeinate_mode)" != hold ]; then
            stop_caffeinate
            start_caffeinate
        fi
    elif [ "$LINGER_SECONDS" -eq 0 ]; then
        caffeinate_pid >/dev/null 2>&1 && stop_caffeinate
    elif caffeinate_pid >/dev/null 2>&1; then
        # An expiring linger keeps its original deadline; only a full hold
        # converts, so repeated idle events never restart the 20-minute clock.
        if [ "$(caffeinate_mode)" = hold ]; then
            stop_caffeinate
            start_linger
        fi
    else
        rm -f "$PIDFILE" "$MODEFILE"
    fi
    release_lock
}
