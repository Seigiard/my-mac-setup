#!/bin/bash
input=$(cat)

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
CLEAN_TEXT=$(printf '%b' "$STATUS_LINE" | sed 's/\x1b\[[0-9;]*m//g')
TEXT_WIDTH=${#CLEAN_TEXT}
UNDERLINE=$(printf '─%.0s' $(seq 1 $TEXT_WIDTH))

printf '%b\n' "${STATUS_LINE}\n "
