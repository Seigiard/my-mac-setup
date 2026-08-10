#!/usr/bin/env bash
# Claude Code adapter for herdr-task-sync.
#
# Wired to three events, each passing its name as the first argument, the same
# dispatch shape herdr's own ~/.claude/hooks/herdr-agent-state.sh uses:
#   prompt   UserPromptSubmit — name the session from the submitted prompt
#   session  SessionStart     — name a resumed session before any prompt
#   compact  PreCompact       — re-derive the name around context compaction
#
# `session` and `compact` run the engine in transcript mode: no prompt on
# stdin, the naming context comes from the transcript file instead.
#
# Every path writes nothing to stdout and exits 0. Claude Code injects a
# UserPromptSubmit hook's stdout into the conversation on exit 0, so a stray
# byte here would end up in the user's context.

set -uo pipefail

action="${1:-prompt}"

engine="$(command -v herdr-task-sync 2>/dev/null)"
[ -n "$engine" ] || engine="$HOME/.local/bin/herdr-task-sync"

input="$(cat 2>/dev/null)"

[ -x "$engine" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

field() {
  printf '%s' "$input" | jq -r "$1" 2>/dev/null
}

# Subagent traffic carries agent_id; the pane belongs to the main session.
[ -z "$(field '.agent_id // empty')" ] || exit 0

session_id="$(field '.session_id // empty')"
[ -n "$session_id" ] || exit 0
transcript_path="$(field '.transcript_path // empty')"

case "$action" in
  prompt)
    field '.prompt // empty' \
      | "$engine" --agent claude --session "$session_id" \
        --transcript "$transcript_path" >/dev/null 2>&1
    ;;
  session|compact)
    [ -n "$transcript_path" ] || exit 0
    "$engine" --agent claude --session "$session_id" \
      --transcript "$transcript_path" </dev/null >/dev/null 2>&1
    ;;
esac

exit 0
