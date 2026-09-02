#!/usr/bin/env bash
# PreToolUse guard for Edit|Write|MultiEdit on test files.
#
# Thin Claude Code adapter over ~/.local/bin/test-oracle-guard: extracts the
# target path and the proposed new content from the tool input and denies the
# call when the shared engine flags an unjustified negative assertion. The
# engine owns the patterns, the test-file filter, and the "oracle:" escape
# hatch, so all agent clients enforce one contract.
#
# Fails open: any missing dependency, unreadable input, or parse error exits 0
# and the call proceeds.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

guard="$HOME/.local/bin/test-oracle-guard"
[ -x "$guard" ] || exit 0

input=$(cat) || exit 0

path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[ -n "$path" ] || exit 0

content=$(printf '%s' "$input" | jq -r '
  [.tool_input.content // empty,
   .tool_input.new_string // empty,
   ((.tool_input.edits // []) | map(.new_string // empty) | join("\n"))]
  | map(select(. != "")) | join("\n")' 2>/dev/null) || exit 0
[ -n "$content" ] || exit 0

if reason=$(printf '%s' "$content" | "$guard" "$path" 2>/dev/null); then
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
