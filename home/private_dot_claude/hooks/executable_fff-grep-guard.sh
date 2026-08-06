#!/usr/bin/env bash
# PreToolUse guard for mcp__fff__grep.
#
# fff grep matches one literal line, so a query of several bare words finds
# nothing. Measured over 1736 past sessions: 74 of 146 calls were multi-token
# and 49 of those returned "0 exact matches". The multi-token calls that did
# work were path-scoped ("KnowledgeContextField console/"), so path and glob
# tokens are not counted here.
#
# Fails open: any missing dependency, unreadable input, or parse error exits 0
# and the call proceeds.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat) || exit 0

query=$(printf '%s' "$input" | jq -r '.tool_input.query // empty' 2>/dev/null) || exit 0
[ -n "$query" ] || exit 0

bare_tokens=$(printf '%s' "$query" | tr '[:space:]' '\n' | grep -v '[/*]' | grep -c '.')
[ "${bare_tokens:-0}" -ge 2 ] || exit 0

reason="fff grep matches ONE literal line, so the query '${query}' will return \"0 exact matches\". Pick one: search a single identifier with mcp__fff__grep; search several identifiers with mcp__fff__multi_grep and a JSON array of patterns; or use the built-in Grep for a regex or a quoted phrase. Adding a path token such as 'console/' also passes this guard."

jq -n --arg reason "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
