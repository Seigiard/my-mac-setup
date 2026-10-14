#!/usr/bin/env bash
# SessionStart injector for the goal-focused handoff.
#
# After a compaction finishes, place a stored handoff into the model's context
# or show the operator why the builder could not deliver one, then delete it.
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
# Fails open: any missing dependency, unreadable input, or absent store record
# exits 0 and silent. A recognized failure record produces only the operator
# message; it never becomes model context.

set -uo pipefail

command -v jq > /dev/null 2>&1 || exit 0

# ${HOME:-} rather than $HOME: under `set -u` an unset HOME would abort the
# hook with a non-zero status, which is the opposite of failing open.
CONTEXT_USAGE_LIBRARY="${CONTEXT_USAGE_LIBRARY:-${HOME:-}/.local/lib/context-usage.sh}"
[ -r "$CONTEXT_USAGE_LIBRARY" ] || exit 0
# shellcheck source=home/dot_local/lib/context-usage.sh
. "$CONTEXT_USAGE_LIBRARY" || exit 0

HANDOFF_STORE="${HANDOFF_STORE_DIR:-${HOME:-}/.cache/claude-handoff}"

input=$(cat) || exit 0

source_kind=$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null) || exit 0
[ "$source_kind" = compact ] || exit 0

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[ -n "$session_id" ] || exit 0

store="$HANDOFF_STORE/$(context_usage_encode_key "$session_id").json"
[ -f "$store" ] || exit 0

failure_reason=$(jq -r '.failure_reason // empty' < "$store" 2> /dev/null) || exit 0
case "$failure_reason" in
  dependency | fork | timeout | empty | write)
    rm -f "$store" 2> /dev/null || true
    jq -n --arg reason "$failure_reason" \
      '{systemMessage: ("-----\n⚠️ Compact handoff not delivered\n\nreason: " + $reason + "\n-----")}' \
      2> /dev/null || exit 0
    exit 0
    ;;
esac

content=$(jq -r '.handoff_content // empty' < "$store" 2> /dev/null) || exit 0
if [ -z "$content" ]; then
  rm -f "$store" 2> /dev/null || true
  exit 0
fi

rm -f "$store" 2> /dev/null || true

# The operator never sees additionalContext, so show them the one block they
# can check: the goal the extractor settled on. It is read from the `## Goal`
# section of the handoff and stops at the next heading. A handoff without that
# section yields no message rather than a guess.
goal=$(printf '%s\n' "$content" | awk '
  /^## Goal[[:space:]]*$/ { in_goal = 1; next }
  in_goal && (/^## / || /^<\/handoff>/) { exit }
  in_goal { print }
' 2> /dev/null | tr '\n' ' ') || goal=""

# A recognized status is shown beside the goal so the operator can see whether
# the next turn must answer the last request first. Only a Status: line inside
# the Last request section is eligible; ordinary handoff details are not state.
last_request_status=$(printf '%s\n' "$content" | awk '
  /^## Last request[[:space:]]*$/ { in_last_request = 1; next }
  in_last_request && /^## / { exit }
  in_last_request && /^Status:/ {
    sub(/^Status:/, "")
    gsub(/^[[:space:]]+|[[:space:]]+$/, "")
    print
    exit
  }
' 2> /dev/null) || last_request_status=""
case "$last_request_status" in
  Answered | 'Partially answered' | 'Not answered') ;;
  *) last_request_status="" ;;
esac

# systemMessage renders to the operator and never reaches the model, so it
# rides beside additionalContext and never replaces it (KTD8). The cap keeps a
# handoff that broke its own format from filling the screen.
jq -n --arg context "$content" --arg goal "$goal" --arg status "$last_request_status" '
  ($goal | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")) as $g
  | {
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: $context
      }
    }
    + (if $g == "" then {}
        else {systemMessage: ("-----\n🎯 Compact goal\n\n" + (if ($g | length) > 300 then $g[0:300] + "…" else $g end) + (if $status == "" then "" else "\n\nStatus: " + $status end) + "\n-----")}
       end)
' 2>/dev/null || exit 0

exit 0
