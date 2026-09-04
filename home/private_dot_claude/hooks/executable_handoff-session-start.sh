#!/usr/bin/env bash
# SessionStart injector for the goal-focused handoff.
#
# After a `/compact handoff:<goal>` finishes, place the handoff the PreCompact
# builder produced into the model's context, then delete it and re-arm the
# context-threshold announcements for the emptied window.
#
# Vendored from kylesnowschwartz/claude-handoff at 26f5b4c (MIT, Copyright (c)
# 2025 Kyle Snow Schwartz), inactive since 2026-01-05.
#
# One deliberate departure from upstream, and it is the whole point of
# vendoring: upstream emits `systemMessage`, which Claude Code renders to the
# operator and never places in the model's context. Two controlled runs
# differing only in that field settled it -- the `systemMessage` run could not
# recall the injected token, the `additionalContext` run could. A handoff
# shown on screen has not been handed off (KTD8).
#
# The handoff is looked up by this session's id alone. A handoff belonging to
# another session is left where it is; the session that owns it will consume
# or clear it (R16).
#
# Fails open: any missing dependency, unreadable input, or absent handoff
# exits 0 and silent.

set -uo pipefail

command -v jq > /dev/null 2>&1 || exit 0

CONTEXT_USAGE_LIBRARY="${CONTEXT_USAGE_LIBRARY:-$HOME/.local/lib/context-usage.sh}"
[ -r "$CONTEXT_USAGE_LIBRARY" ] || exit 0
# shellcheck source=home/dot_local/lib/context-usage.sh
. "$CONTEXT_USAGE_LIBRARY" || exit 0

HANDOFF_STORE="${HANDOFF_STORE_DIR:-$HOME/.cache/claude-handoff}"

input=$(cat) || exit 0

source_kind=$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null) || exit 0
[ "$source_kind" = compact ] || exit 0

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[ -n "$session_id" ] || exit 0

# Compaction empties the window, so every announcement budget re-arms and the
# turn count restarts at the boundary the transcript now carries (R11). This
# happens whether or not a handoff was waiting, because a plain `/compact`
# resets the session just as much as a goal-carrying one does.
context_usage_clear "$session_id" > /dev/null 2>&1 || true

store="$HANDOFF_STORE/$(context_usage_encode_key "$session_id").json"
[ -f "$store" ] || exit 0

content=$(jq -r '.handoff_content // empty' < "$store" 2>/dev/null) || exit 0
if [ -z "$content" ]; then
  rm -f "$store" 2> /dev/null || true
  exit 0
fi

rm -f "$store" 2> /dev/null || true

jq -n --arg context "$content" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $context
  }
}' 2>/dev/null || exit 0

exit 0
