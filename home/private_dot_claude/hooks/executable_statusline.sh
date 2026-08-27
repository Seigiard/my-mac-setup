#!/bin/bash
input=$(cat)

# herdr labels an agent pane from the pane's OS working directory, which never
# moves when a session enters a worktree — the claude process stays put while
# the session works elsewhere. This payload knows better, so record the
# session's real directory where herdr-task-sync can read it. Keyed by session
# id, which herdr also carries on the pane. Writing a file is the whole
# contract: herdr-task-sync stays the only process that publishes pane tokens.
herdr_record_session_cwd() {
    [ "${HERDR_ENV:-}" = 1 ] || return 0
    local dir key root tmp
    IFS=$'\t' read -r dir key <<< "$(printf '%s' "$input" |
        jq -r '[(.workspace.current_dir // ""), (.session_id // "")] | @tsv' 2>/dev/null)"
    [ -n "$dir" ] && [ -n "$key" ] || return 0
    root="${HERDR_TASK_SYNC_STATE_DIR:-$HOME/.cache/herdr-task-sync}/agent-cwd"
    mkdir -p "$root" 2>/dev/null || return 0
    key=$(LC_ALL=C printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-64)
    # Rename into place so a sweep reading mid-write never sees a partial path.
    tmp="$root/.$key.$$"
    printf '%s\n' "$dir" > "$tmp" 2>/dev/null && mv -f "$tmp" "$root/$key" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    return 0
}
herdr_record_session_cwd

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
    adjusted_pct=$((raw_pct + 20))
    [ "$adjusted_pct" -gt 100 ] && adjusted_pct=100
    CONTEXT_PCT="$adjusted_pct"
else
    CONTEXT_PCT="0"
fi

BAR=$(progress_bar "$CONTEXT_PCT")

CC_INFO="${BOLD}${GREEN}${MODEL}${RESET} ${DIM}${GREEN}${BAR}${RESET}"

FOLDER_INFO="${BOLD}${FOLDER}${RESET}"
[ -n "$GIT_BRANCH" ] && FOLDER_INFO="${FOLDER_INFO} ${PURPLE}[${GIT_BRANCH}]${RESET}"

STATUS_LINE="${FOLDER_INFO}${DIM}${GRAY} ❯ ${RESET}${CC_INFO}"

printf '%b\n' "${STATUS_LINE}\n "
