#!/usr/bin/env bash
# UserPromptSubmit adapter for herdr-worktree-identity.
#
# The engine's foreground process only persists the prompt and forks its
# worker. The hook timeout therefore bounds that handshake, never model work.
# Every decline is deliberately quiet: Claude includes hook stdout in context.

set -uo pipefail

[ "${HERDR_ENV:-}" = 1 ] || exit 0
[ -z "${HERDR_WORKTREE_IDENTITY_ACTIVE:-}" ] || exit 0

engine="${HERDR_WORKTREE_IDENTITY_ENGINE:-$HOME/.local/bin/herdr-worktree-identity}"
[ -x "$engine" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null)" || exit 0
field() {
  printf '%s' "$input" | jq -r "$1" 2>/dev/null
}

# A subagent belongs to its parent's pane and must not derive a new identity.
[ -z "$(field '.agent_id // empty')" ] || exit 0
session="$(field '.session_id // empty')"
prompt="$(field '.prompt // empty')"
[ -n "$session" ] && [ -n "$prompt" ] || exit 0

args=(--agent claude --session "$session")
[ -z "${HERDR_PANE_ID:-}" ] || args+=(--pane "$HERDR_PANE_ID")
[ -z "${HERDR_WORKSPACE_ID:-}" ] || args+=(--workspace "$HERDR_WORKSPACE_ID")
printf '%s' "$prompt" | "$engine" "${args[@]}" >/dev/null 2>&1 || true

exit 0
