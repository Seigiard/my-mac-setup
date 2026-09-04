#!/usr/bin/env bash
# Stop hook: announce when a session has outgrown itself, and halt at the
# hard threshold.
#
# Auto-compact is off in this setup, so a session that reaches the context
# limit loses the conversation. Two independent signs are watched: how full
# the window is, and how many turns have accumulated since the last
# compaction. Either one is enough to act on.
#
# The announcement is addressed to the operator, not the model.
# `systemMessage` renders in the operator's UI and never enters model
# context, so it costs no tokens and the agent does not react to it. At the
# hard level the same message is emitted alongside `continue: false`, because
# Claude Code discards a Stop-hook halt on several end-turn paths while still
# rendering the hook's message -- the message survives exactly the path that
# swallows the halt.
#
# This hook runs at the end of every turn of every session. Everything before
# the announcement is file reads and integer arithmetic; the model call
# happens once or twice in a session's life.
#
# Fails open: any missing dependency, unreadable input, parse error, or
# unreadable state exits 0 and silent. The hard threshold's halt is the one
# deliberate exception and the only non-silent path.

set -uo pipefail

command -v jq > /dev/null 2>&1 || exit 0

# Re-entrancy, first. The goal extraction is a `claude` process inheriting
# these same settings, so its own Stop hook fires; a fork of an already-long
# session would meet the threshold immediately and extract again.
[ "${CONTEXT_THRESHOLD_GUARD:-}" = 1 ] && exit 0

input=$(cat) || exit 0

stop_hook_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0
[ "$stop_hook_active" = true ] && exit 0

# Non-interactive, second, and on a positive marker only. Claude Code sets
# CLAUDE_CODE_ENTRYPOINT to `cli` in a TUI session and to `sdk-cli` under
# `claude -p`; this repository runs headless legs routinely and halting one
# mid-task would be a regression in unrelated work with no human to read the
# message. A missing statusline state file is never read as headless -- that
# is the resumed interactive session this feature exists for.
case "${CLAUDE_CODE_ENTRYPOINT:-cli}" in
  sdk-* | mcp-cli) exit 0 ;;
esac

CONTEXT_USAGE_LIBRARY="${CONTEXT_USAGE_LIBRARY:-$HOME/.local/lib/context-usage.sh}"
[ -r "$CONTEXT_USAGE_LIBRARY" ] || exit 0
# shellcheck source=home/dot_local/lib/context-usage.sh
. "$CONTEXT_USAGE_LIBRARY" || exit 0

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[ -n "$session_id" ] || exit 0
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null) || exit 0

turns=$(context_usage_turn_count "$transcript") || exit 0
fullness=$(context_usage_read_fullness "$session_id") || fullness=""

crossing=$(context_usage_evaluate "$session_id" "$fullness" "$turns") || exit 0
level=$(printf '%s' "$crossing" | sed -n 's/^level=//p')
dimensions=$(printf '%s' "$crossing" | sed -n 's/^dimensions=//p')
[ -n "$level" ] && [ -n "$dimensions" ] || exit 0

# One message per turn, however many dimensions or levels crossed.
detail=""
case ",$dimensions," in
  *,turns,*)
    if [ "$level" = hard ]; then
      detail="$turns turns since the last compaction (limit $CONTEXT_USAGE_TURNS_HARD)"
    else
      detail="$turns turns since the last compaction (warn at $CONTEXT_USAGE_TURNS_WARN)"
    fi
    ;;
esac
case ",$dimensions," in
  *,fullness,*)
    if [ "$level" = hard ]; then
      detail="${detail:+$detail and }context window ${fullness}% full (limit $CONTEXT_USAGE_FULLNESS_HARD_PCT%)"
    else
      detail="${detail:+$detail and }context window ${fullness}% full (warn at $CONTEXT_USAGE_FULLNESS_WARN_PCT%)"
    fi
    ;;
esac

# Goal extraction lands in a later change. Until then the command is correctly
# formed and the operator supplies the goal.
command_line="/compact handoff:<what you are trying to finish>"

if [ "$level" = hard ]; then
  message="Context limit reached: $detail. Compact now, editing the goal as you like:
$command_line"
  reason="Stopped at the context limit: $detail. Run $command_line to carry the current goal through compaction, or send another prompt to continue anyway."
  context_usage_spend "$session_id" hard "$dimensions" "$turns" > /dev/null 2>&1 || true
  jq -n --arg message "$message" --arg reason "$reason" \
    '{continue: false, stopReason: $reason, systemMessage: $message}' 2>/dev/null || exit 0
  exit 0
fi

message="Context growing: $detail. Compact when convenient, editing the goal as you like:
$command_line"
context_usage_spend "$session_id" warn "$dimensions" "$turns" > /dev/null 2>&1 || true
jq -n --arg message "$message" '{systemMessage: $message}' 2>/dev/null || exit 0
exit 0
