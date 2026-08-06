#!/usr/bin/env bash
# PreToolUse reminder for WebFetch.
#
# The tool table names /markdown-new as the primary path for a URL, but past
# sessions show WebFetch at 51 calls against 3 for the skill. This hook does
# not block: WebFetch is sometimes the only path that works. It injects one
# line of context so the choice is deliberate.
#
# Fails open: any missing dependency, unreadable input, or parse error exits 0
# and the call proceeds.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat) || exit 0

url=$(printf '%s' "$input" | jq -r '.tool_input.url // empty' 2>/dev/null) || exit 0
[ -n "$url" ] || exit 0

case "$url" in
*markdown.new*) exit 0 ;;
esac

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: "Reminder: /markdown-new returns cleaner markdown for this URL, needs no API key, and handles JS-heavy pages that WebFetch renders as an empty shell. Keep WebFetch only if the skill already failed on this page or the content is plain HTML."
  }
}'
