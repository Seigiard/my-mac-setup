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

# ${HOME:-} rather than $HOME: under `set -u` an unset HOME would abort the
# hook with a non-zero status, which is the opposite of failing open.
CONTEXT_USAGE_LIBRARY="${CONTEXT_USAGE_LIBRARY:-${HOME:-}/.local/lib/context-usage.sh}"
[ -r "$CONTEXT_USAGE_LIBRARY" ] || exit 0
# shellcheck source=home/dot_local/lib/context-usage.sh
. "$CONTEXT_USAGE_LIBRARY" || exit 0

# Run a command with a wall-clock bound, without depending on `timeout` being
# installed. Returns the command's status, or 124 when the bound was reached.
context_threshold_bounded() {
  local seconds="$1" output="$2"
  shift 2
  local pid waited=0 status
  # Job control puts the child in its own process group, so an overrun can be
  # ended together with anything it spawned. Killing the leader alone leaves
  # orphans holding the pipe the caller is waiting on.
  set -m
  # stdin is closed deliberately: the hook has already consumed its payload,
  # and `claude --print` waits three seconds for input it will never get.
  "$@" > "$output" 2>/dev/null < /dev/null &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$seconds" ]; then
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      # A process that ignores TERM would otherwise hold the turn open past
      # the bound the hook exists to enforce. Escalate the way
      # home/dot_local/lib/herdr-child-supervision.sh already does.
      local grace=0
      while kill -0 "$pid" 2>/dev/null && [ "$grace" -lt 3 ]; do
        sleep 1
        grace=$((grace + 1))
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      fi
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
  status=$?
  return "$status"
}

# Reduce whatever the extractor said to something safe to paste after
# `handoff:`. One line, within the word cap, and stripped of the sequences
# that would change what the command means in a shell-adjacent prompt.
context_threshold_normalize_goal() {
  tr '\n\r\t' '   ' |
    tr -d '`$\\"'"'"';|&<>(){}[]' |
    awk '{
      $1 = $1
      n = NF > 20 ? 20 : NF
      out = ""
      for (i = 1; i <= n; i++) out = out (i == 1 ? "" : " ") $i
      print out
    }'
}

# Fork the session and ask a cheap model what it is trying to finish. The fork
# inherits these settings, so its own Stop hook fires; the guard marker keeps
# this hook out of it (KTD6). Any failure returns nothing and the caller
# announces without a goal rather than not announcing at all (R23).
context_threshold_extract_goal() {
  local session="$1" answer extracted status=0
  command -v claude > /dev/null 2>&1 || return 1
  extracted=$(mktemp "${TMPDIR:-/tmp}/context-goal.XXXXXX" 2>/dev/null) || return 1
  trap 'rm -f "$extracted"' RETURN

  context_threshold_bounded "$CONTEXT_USAGE_EXTRACTION_TIMEOUT" "$extracted" \
    env CONTEXT_THRESHOLD_GUARD=1 claude --resume "$session" --fork-session \
    --model haiku --print "$CONTEXT_THRESHOLD_GOAL_PROMPT" || status=$?

  if [ "$status" -ne 0 ] || [ ! -s "$extracted" ]; then
    return 1
  fi
  answer="$(context_threshold_normalize_goal < "$extracted")"
  [ -n "$answer" ] || return 1
  printf '%s' "$answer"
}

CONTEXT_THRESHOLD_GOAL_PROMPT="Name what this session is currently trying to finish, as one short imperative phrase of at most 20 words.

Write the goal, not a summary of what happened. Include a constraint the user gave only when that constraint changes what finishing means. Output the phrase alone, on one line, with no quotes, no punctuation at the end, and no preamble."

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[ -n "$session_id" ] || exit 0
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null) || exit 0

# The library already refuses to propagate a parse failure, but the hook
# must not lose the other dimension even if that ever changes.
turns=$(context_usage_turn_count "$transcript") || turns=0
case "$turns" in '' | *[!0-9]*) turns=0 ;; esac
fullness=$(context_usage_read_fullness "$session_id") || fullness=""

crossing=$(context_usage_evaluate "$session_id" "$fullness" "$turns") || exit 0
level=$(printf '%s' "$crossing" | sed -n 's/^level=//p')
dimensions=$(printf '%s' "$crossing" | sed -n 's/^dimensions=//p')
warn_dimensions=$(printf '%s' "$crossing" | sed -n 's/^warn_dimensions=//p')
[ -n "$level" ] && [ -n "$dimensions" ] || exit 0

# Announcement state is what makes "once per session" true. If it cannot be
# recorded, every later turn would re-extract a goal and re-issue the halt, so
# the hook fails open rather than announcing something it cannot remember.
# Checked here, on the branch that is about to announce, rather than on the
# silent path every turn of every session takes.
context_usage_spend "$session_id" "$level" "" "$turns" > /dev/null 2>&1 || exit 0

# One message names everything that crossed this turn. A dimension that
# reached only the warning level while another reached the limit is reported
# here rather than held over to the next turn (R22).
context_threshold_crossed_at() {
  case ",$2," in
    *,"$1",*) return 0 ;;
  esac
  return 1
}

detail=""
if context_threshold_crossed_at turns "$dimensions"; then
  if [ "$level" = hard ]; then
    detail="$turns turns since the last compaction (limit $CONTEXT_USAGE_TURNS_HARD)"
  else
    detail="$turns turns since the last compaction (warn at $CONTEXT_USAGE_TURNS_WARN)"
  fi
elif context_threshold_crossed_at turns "$warn_dimensions"; then
  detail="$turns turns since the last compaction (warn at $CONTEXT_USAGE_TURNS_WARN)"
fi
if context_threshold_crossed_at fullness "$dimensions"; then
  if [ "$level" = hard ]; then
    detail="${detail:+$detail and }context window ${fullness}% full (limit $CONTEXT_USAGE_FULLNESS_HARD_PCT%)"
  else
    detail="${detail:+$detail and }context window ${fullness}% full (warn at $CONTEXT_USAGE_FULLNESS_WARN_PCT%)"
  fi
elif context_threshold_crossed_at fullness "$warn_dimensions"; then
  detail="${detail:+$detail and }context window ${fullness}% full (warn at $CONTEXT_USAGE_FULLNESS_WARN_PCT%)"
fi

# The goal is extracted once per session and reused by every later
# announcement, including every hard-threshold repeat. Knowing whether the
# goal has changed would require extracting it again, which would fork the
# whole session on every turn of exactly the sessions this hook exists to
# make cheaper. A goal that has gone stale costs the operator one edit.
goal=""
goal_status="$(context_usage_goal_status "$session_id" 2>/dev/null)" || goal_status=""
if [ -n "$goal_status" ]; then
  [ "$goal_status" = ok ] && goal="$(context_usage_goal "$session_id" 2>/dev/null)"
else
  goal="$(context_threshold_extract_goal "$session_id")" || goal=""
  if [ -n "$goal" ]; then
    goal_status=ok
  else
    goal_status=failed
  fi
fi

if [ -n "$goal" ]; then
  command_line="/compact handoff:$goal"
  note=""
else
  command_line="/compact handoff:<what you are trying to finish>"
  note=" Goal extraction failed, so fill the goal in yourself."
fi

if [ "$level" = hard ]; then
  message="Context limit reached: $detail.$note Compact now, editing the goal as you like:
$command_line"
  reason="Stopped at the context limit: $detail. Run $command_line to carry the current goal through compaction, or send another prompt to continue anyway."
  context_usage_spend "$session_id" hard "$dimensions" "$turns" "$goal" "$goal_status" > /dev/null 2>&1 || true
  [ -z "$warn_dimensions" ] ||
    context_usage_spend "$session_id" warn "$warn_dimensions" "$turns" > /dev/null 2>&1 || true
  jq -n --arg message "$message" --arg reason "$reason" \
    '{continue: false, stopReason: $reason, systemMessage: $message}' 2>/dev/null || exit 0
  exit 0
fi

message="Context growing: $detail.$note Compact when convenient, editing the goal as you like:
$command_line"
context_usage_spend "$session_id" warn "$dimensions" "$turns" "$goal" "$goal_status" > /dev/null 2>&1 || true
jq -n --arg message "$message" '{systemMessage: $message}' 2>/dev/null || exit 0
exit 0
