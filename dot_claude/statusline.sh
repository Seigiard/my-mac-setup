#!/bin/bash
input=$(cat)

BOLD='\033[1m'
CYAN='\033[36m'
PURPLE='\033[35m'
DIM='\033[2m'
RESET='\033[0m'

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
    CONTEXT_PCT="$((current * 100 / size))%"
else
    CONTEXT_PCT="0%"
fi

TOTAL_INPUT=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
TOTAL_OUTPUT=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
TOTAL_TOKENS=$((TOTAL_INPUT + TOTAL_OUTPUT))

if [ "$TOTAL_TOKENS" -ge 1000000 ]; then
    TOTAL_DISPLAY="$((TOTAL_TOKENS / 1000000))M"
elif [ "$TOTAL_TOKENS" -ge 1000 ]; then
    TOTAL_DISPLAY="$((TOTAL_TOKENS / 1000))k"
else
    TOTAL_DISPLAY="$TOTAL_TOKENS"
fi

OUTPUT="${BOLD}${CYAN}${FOLDER}${RESET}"
[ -n "$GIT_BRANCH" ] && OUTPUT="${OUTPUT} ${DIM}${PURPLE}[${GIT_BRANCH}]${RESET}"
OUTPUT="${OUTPUT}${DIM} ❯ ${MODEL} · ${CONTEXT_PCT} ctx · ${TOTAL_DISPLAY} tok${RESET}"

printf '%b\n' "$OUTPUT"
