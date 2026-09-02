#!/usr/bin/env bash
# PreToolUse guard for Bash.
#
# Thin Claude Code adapter over ~/.local/bin/zsh-reserved-name-guard: feeds the
# proposed command to the shared engine and denies the call when it assigns to
# a parameter zsh reserves. The engine owns the name list, the command-position
# rule, the heredoc skip, and the "zsh-ok:" escape hatch, so all agent clients
# enforce one contract.
#
# Fails open: any missing dependency, unreadable input, or parse error exits 0
# and the call proceeds.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

guard="$HOME/.local/bin/zsh-reserved-name-guard"
[ -x "$guard" ] || exit 0

input=$(cat) || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

if reason=$(printf '%s' "$cmd" | "$guard" 2>/dev/null); then
  exit 0
fi
[ -n "$reason" ] || exit 0

jq -n --arg reason "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
