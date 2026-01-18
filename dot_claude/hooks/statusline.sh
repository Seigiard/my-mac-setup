#!/bin/bash
input=$(cat)

BOLD='\033[1m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
PURPLE='\033[35m'
DIM='\033[2m'
GRAY='\033[90m'
RESET='\033[0m'

get_context_color() {
    local pct=$1
    if [ "$pct" -ge 85 ]; then echo "$RED"
    elif [ "$pct" -ge 70 ]; then echo "$YELLOW"
    else echo "$GREEN"
    fi
}

progress_bar() {
    local pct=$1
    local color=$2
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
    printf '%b%s%b %d%%' "$color" "$bar" "$RESET" "$pct"
}

get_tool_counts() {
    local transcript="$1"
    [ ! -f "$transcript" ] && return

    local counts
    counts=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' "$transcript" 2>/dev/null \
        | sort | uniq -c | sort -rn | head -4)

    [ -z "$counts" ] && return

    local result=""
    while read -r count name; do
        [ -z "$name" ] && continue
        [ -n "$result" ] && result+=" | "
        result+="✓ ${name} ×${count}"
    done <<< "$counts"

    [ -n "$result" ] && printf ' | %s' "$result"
}

CURRENT_DIR=$(echo "$input" | jq -r '.workspace.current_dir // "."')
MODEL=$(echo "$input" | jq -r '.model.display_name // "Claude"')
TRANSCRIPT=$(echo "$input" | jq -r '.transcript_path // empty')

FOLDER="${CURRENT_DIR##*/}"

GIT_BRANCH=""
if git -C "$CURRENT_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    GIT_BRANCH=$(git -C "$CURRENT_DIR" --no-optional-locks branch --show-current 2>/dev/null)
fi

native_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
if [ -n "$native_pct" ]; then
    CONTEXT_PCT=$(printf "%.0f" "$native_pct")
else
    usage=$(echo "$input" | jq '.context_window.current_usage')
    if [ "$usage" != "null" ]; then
        current=$(echo "$usage" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
        size=$(echo "$input" | jq '.context_window.context_window_size')
        CONTEXT_PCT=$((current * 100 / size))
    else
        CONTEXT_PCT="0"
    fi
fi

COLOR=$(get_context_color "$CONTEXT_PCT")
BAR=$(progress_bar "$CONTEXT_PCT" "$COLOR")
TOOLS=$(get_tool_counts "$TRANSCRIPT")

CC_INFO="${BOLD}${GREEN}${MODEL}${RESET} ${DIM}${BAR}${RESET}${TOOLS}"

FOLDER_INFO="${BOLD}${FOLDER}${RESET}"
[ -n "$GIT_BRANCH" ] && FOLDER_INFO="${FOLDER_INFO} ${PURPLE}[${GIT_BRANCH}]${RESET}"

STATUS_LINE="${FOLDER_INFO}${DIM}${GRAY} ❯ ${RESET}${CC_INFO}"
CLEAN_TEXT=$(printf '%b' "$STATUS_LINE" | sed 's/\x1b\[[0-9;]*m//g')
TEXT_WIDTH=${#CLEAN_TEXT}
UNDERLINE=$(printf '─%.0s' $(seq 1 $TEXT_WIDTH))

printf '%b\n' "${STATUS_LINE}\n "
