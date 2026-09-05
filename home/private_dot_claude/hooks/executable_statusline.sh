#!/bin/bash
input=$(cat)

# herdr labels an agent pane from the pane's OS working directory, which never
# moves when a session enters a worktree — the claude process stays put while
# the session works elsewhere. This payload knows better, so record the
# session's real directory where herdr-worktree-identity can read it. Keyed by
# session id, which herdr also carries on the pane. Writing a file is the whole
# contract: herdr-worktree-identity owns its identity state.
herdr_record_session_cwd() {
    [ "${HERDR_ENV:-}" = 1 ] || return 0
    local dir key root state_library tmp
    IFS=$'\t' read -r dir key <<< "$(printf '%s' "$input" |
        jq -r '[(.workspace.current_dir // ""), (.session_id // "")] | @tsv' 2>/dev/null)"
    [ -n "$dir" ] && [ -n "$key" ] || return 0
    root="${HERDR_WORKTREE_IDENTITY_STATE_DIR:-$HOME/.cache/herdr-worktree-identity}/agent-cwd"
    state_library="${HERDR_WORKTREE_IDENTITY_STATE_LIBRARY:-$HOME/.local/lib/herdr-worktree-state.sh}"
    [ -r "$state_library" ] || return 0
    # shellcheck source=home/dot_local/lib/herdr-worktree-state.sh
    . "$state_library"
    mkdir -p "$root" 2>/dev/null || return 0
    key="$(encode_key "$key")" || return 0
    # Rename into place so a sweep reading mid-write never sees a partial path.
    tmp="$root/.$key.$$"
    printf '%s\n' "$dir" > "$tmp" 2>/dev/null && mv -f "$tmp" "$root/$key" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    return 0
}
herdr_record_session_cwd

# The shared context-usage library owns the system-prompt allowance and the
# state file the context-threshold Stop hook reads (R1, R2, KTD2). Sourcing it
# is best-effort: a partially applied home must still render a status line.
# There is no second definition of the allowance here -- an unsourced library
# means no allowance is known, not that 20 is assumed somewhere else too.
CONTEXT_USAGE_LIBRARY="${CONTEXT_USAGE_LIBRARY:-$HOME/.local/lib/context-usage.sh}"
if [ -r "$CONTEXT_USAGE_LIBRARY" ]; then
    # shellcheck source=home/dot_local/lib/context-usage.sh
    . "$CONTEXT_USAGE_LIBRARY"
fi

BOLD='\033[1m'
GREEN='\033[32m'
PURPLE='\033[35m'
DIM='\033[2m'
GRAY='\033[90m'
RESET='\033[0m'

progress_bar() {
    local pct=$1
    local bar=""
    for ((i=0; i<10; i++)); do
        local seg_start=$((i * 10))
        local seg_end=$(((i + 1) * 10))
        if [ "$pct" -ge "$seg_end" ]; then
            bar+="▓"
        elif [ "$pct" -le "$seg_start" ]; then
            bar+="░"
        else
            local fill=$(((pct - seg_start) * 10))
            if [ "$fill" -le 20 ]; then
                bar+="░"
            elif [ "$fill" -le 66 ]; then
                bar+="▒"
            else
                bar+="▓"
            fi
        fi
    done
    printf '%s' "$bar"
}

CURRENT_DIR=$(echo "$input" | jq -r '.workspace.current_dir // "."')
MODEL=$(echo "$input" | jq -r '.model.display_name // "Claude"')

FOLDER="${CURRENT_DIR##*/}"

GIT_BRANCH=""
if git -C "$CURRENT_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    GIT_BRANCH=$(git -C "$CURRENT_DIR" --no-optional-locks branch --show-current 2>/dev/null)
fi

usage=$(echo "$input" | jq '.context_window.current_usage')
if [ "$usage" != "null" ]; then
    current=$(echo "$usage" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
    size=$(echo "$input" | jq '.context_window.context_window_size')
    raw_pct=$((current * 100 / size))
    adjusted_pct=$((raw_pct + ${CONTEXT_USAGE_ALLOWANCE_PCT:-0}))
    [ "$adjusted_pct" -gt 100 ] && adjusted_pct=100
    CONTEXT_PCT="$adjusted_pct"
    # Claude Code hands these counts to the status line and to nothing else, so
    # publishing them is the only way the Stop hook can see fullness at all.
    # A failed write costs the hook one dimension and the bar nothing.
    if command -v context_usage_write_usage > /dev/null 2>&1; then
        SESSION_ID=$(echo "$input" | jq -r '.session_id // ""')
        [ -n "$SESSION_ID" ] &&
            context_usage_write_usage "$SESSION_ID" "$current" "$size" > /dev/null 2>&1
    fi
else
    CONTEXT_PCT="0"
fi

BAR=$(progress_bar "$CONTEXT_PCT")

CC_INFO="${BOLD}${GREEN}${MODEL}${RESET} ${DIM}${GREEN}${BAR}${RESET}"

FOLDER_INFO="${BOLD}${FOLDER}${RESET}"
[ -n "$GIT_BRANCH" ] && FOLDER_INFO="${FOLDER_INFO} ${PURPLE}[${GIT_BRANCH}]${RESET}"

STATUS_LINE="${FOLDER_INFO}${DIM}${GRAY} ❯ ${RESET}${CC_INFO}"

printf '%b\n' "${STATUS_LINE}\n "
