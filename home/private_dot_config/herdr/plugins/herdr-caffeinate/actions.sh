#!/bin/sh
# Herdr manifest actions for the Caffeinate plugin.
#   status  - show whether the wake lock is held and which agents are working
#   stop    - force-release the wake lock now (auto-caffeinate resumes on the
#             next agent status change)
#   test    - self-test: start caffeinate, confirm the pmset assertion, release
set -u

DIR=${HERDR_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
# shellcheck source=lib.sh disable=SC1091
. "$DIR/lib.sh"

list_working() {
    _out=$("$HERDR" agent list 2>/dev/null) || return 0
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$_out" | jq -r --arg want "$AWAKE_STATES" '
            ($want | split(" ") | map(select(. != ""))) as $w
            | .result.agents[]?
            | select(.agent_status as $s | $w | index($s))
            | "  - \(.agent // "agent") [\(.agent_status)] \(.pane_id) \(.cwd // "")"' 2>/dev/null
    fi
}

cmd=${1:-status}
case "$cmd" in
    status)
        if pid=$(caffeinate_pid); then
            if [ "$(caffeinate_mode)" = linger ]; then
                echo "caffeinate: LINGERING (pid $pid, expires <= ${LINGER_SECONDS}s after last agent activity)"
            else
                echo "caffeinate: ACTIVE (pid $pid, flags: $CAFFEINATE_FLAGS)"
            fi
        else
            echo "caffeinate: inactive"
        fi
        echo "awake states: $AWAKE_STATES"
        echo "linger: ${LINGER_SECONDS}s"
        working=$(list_working)
        if [ -n "$working" ]; then
            echo "agents holding the lock awake:"
            echo "$working"
        else
            echo "agents holding the lock awake: none"
        fi
        ;;

    stop)
        acquire_lock
        stop_caffeinate
        release_lock
        echo "Wake lock released. Auto-caffeinate resumes on the next agent status change."
        ;;

    test)
        # Self-contained probe: spins up its OWN short-lived caffeinate (-t auto
        # expiry) and checks that specific pid's assertion. It never touches the
        # live pidfile/lock, so running it while agents work is harmless.
        echo "Self-test: starting a short-lived caffeinate ($CAFFEINATE_FLAGS -t 3)..."
        # shellcheck disable=SC2086
        caffeinate $CAFFEINATE_FLAGS -t 3 >/dev/null 2>&1 &
        tpid=$!
        sleep 1
        if ps -p "$tpid" -o comm= 2>/dev/null | grep -q caffeinate \
           && pmset -g assertions 2>/dev/null | grep -qE "pid $tpid\(caffeinate\)"; then
            echo "  OK: our caffeinate (pid $tpid) holds a PreventUserIdleSystemSleep assertion."
            rc=0
        else
            echo "  WARN: expected caffeinate assertion for pid $tpid not found." >&2
            rc=1
        fi
        kill "$tpid" 2>/dev/null
        echo "  self-test caffeinate released; live wake lock untouched."
        exit $rc
        ;;

    *)
        echo "usage: actions.sh {status|stop|test}" >&2
        exit 2
        ;;
esac
