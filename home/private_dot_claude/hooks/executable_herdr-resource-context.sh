#!/usr/bin/env bash
# Deliver the shared Herdr resource projection at Claude model-input boundaries.

set -uo pipefail

[ "${HERDR_ENV:-}" = 1 ] || exit 0

input="$(cat 2>/dev/null)" || exit 0

# Herdr's native integration owns the Agent session identity, and creator
# attribution, record-child and branch resolution all fail once it is unknown.
# Delegate before this hook parses anything of its own: the reporter needs no jq
# and discards every event and subagent invocation it does not handle, so a
# missing jq degrades only the projection below.
agent_state_hook="${HERDR_AGENT_STATE_HOOK:-${HOME:-}/.claude/hooks/herdr-agent-state.sh}"
if [ -x "$agent_state_hook" ]; then
  printf '%s' "$input" | "$agent_state_hook" session >/dev/null 2>&1 || true
fi

command -v jq >/dev/null 2>&1 || exit 0
field() {
  printf '%s' "$input" | jq -r "$1" 2>/dev/null
}

event="$(field '.hook_event_name // empty')" || exit 0
case "$event" in
  SessionStart | UserPromptSubmit | PostToolBatch) ;;
  *) exit 0 ;;
esac

# User settings hooks also run inside subagents, whose context belongs to the
# parent pane's Agent session rather than to the subagent conversation.
[ -z "$(field '.agent_id // empty')" ] || exit 0
session="$(field '.session_id // empty')" || exit 0
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0

resource_cli="${HERDR_RESOURCE_CONTEXT_CLI:-${HOME:-}/.local/bin/herdr-resource-tree}"
[ -x "$resource_cli" ] || exit 0
state_dir="${HERDR_RESOURCE_CONTEXT_STATE_DIR:-${HOME:-}/.cache/herdr-resource-context}"
[ -n "$state_dir" ] || exit 0
umask 077
mkdir -p "$state_dir" 2>/dev/null || exit 0
state_file="$state_dir/$session"
unavailable_sentinel='__HERDR_RESOURCE_CONTEXT_UNAVAILABLE__'
write_state() {
  local value="$1" temporary
  temporary="$(mktemp "$state_dir/.${session}.XXXXXX" 2>/dev/null)" || return 1
  printf '%s' "$value" > "$temporary" 2>/dev/null || {
    rm -f "$temporary"
    return 1
  }
  mv -f "$temporary" "$state_file" 2>/dev/null || {
    rm -f "$temporary"
    return 1
  }
}

had_state=false
previous=""
if [ -f "$state_file" ]; then
  had_state=true
  previous="$(cat "$state_file" 2>/dev/null)" || exit 0
fi

if ! context="$("$resource_cli" --context --caller-agent claude --caller-session-id "$session" 2>/dev/null)"; then
  write_state "$unavailable_sentinel" || exit 0
  # A failed query stays failed for a whole conversation when the pane has no
  # observable Agent session, and Claude's transcript is append-only: restating
  # the notice on every tool batch only grows context. A fresh session still
  # needs it, so SessionStart always emits.
  if [ "$event" != SessionStart ] && [ "$had_state" = true ] && \
    [ "$previous" = "$unavailable_sentinel" ]; then
    exit 0
  fi
  context='Agent resource context unavailable: the shared resource query failed. The earlier generated resource context is stale, and this must not be treated as an empty resource branch.'
  jq -n --arg event "$event" --arg context "$context" '{
    hookSpecificOutput: {
      hookEventName: $event,
      additionalContext: $context
    }
  }' 2>/dev/null || exit 0
  exit 0
fi

# Session restoration needs the projection again after resume or compaction.
# Mid-session events only emit when the projection changes, avoiding duplicate
# reminders while preserving a fresh value before the next model request.
if [ "$event" != SessionStart ] && [ "$had_state" = true ] && [ "$context" = "$previous" ]; then
  exit 0
fi

write_state "$context" || exit 0

if [ -z "$context" ]; then
  if [ "$had_state" = true ] && [ -n "$previous" ]; then
    context='Agent resource context update: the earlier generated resource context is stale; there are now no resources or parent to report.'
  else
    exit 0
  fi
elif [ "$had_state" = true ] && [ -n "$previous" ] && [ "$context" != "$previous" ]; then
  context="Agent resource context update (authoritative; earlier generated resource context is stale):
$context"
else
  context="Agent resource context (current):
$context"
fi

jq -n --arg event "$event" --arg context "$context" '{
  hookSpecificOutput: {
    hookEventName: $event,
    additionalContext: $context
  }
}' 2>/dev/null || exit 0

exit 0
