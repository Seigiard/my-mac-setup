#!/usr/bin/env bash
# Context load measurement for the Claude Code statusline, plus the two file
# primitives the handoff hooks share with it.
#
# Sourcing this file must have no effect beyond defining these functions and
# their defaults — no output, no shell-option or trap changes, no redefinition
# of anything an earlier module declared (KTD1). Every name is prefixed
# `context_usage_` for that reason: `atomic_write` and friends already exist in
# the herdr module family, and the module-hygiene test sources them together.
#
# The library holds no state of its own. It once carried usage and goal records
# for a Stop hook that announced growth and halted the session; the PreCompact
# handoff builder now derives the goal from the session itself at the moment of
# compaction, so nothing has to be measured ahead of time or kept between turns.

# Tokens added to the occupancy Claude Code reports, standing in for the
# system prompt, which it does not report (R2). Absolute rather than a share
# of the window: the system prompt is a fixed cost, so a percentage grew it
# with the window -- 40k tokens against 200k, 200k against 1M.
CONTEXT_USAGE_ALLOWANCE_TOKENS="${CONTEXT_USAGE_ALLOWANCE_TOKENS:-40000}"
case "$CONTEXT_USAGE_ALLOWANCE_TOKENS" in
  '' | *[!0-9]*) CONTEXT_USAGE_ALLOWANCE_TOKENS=40000 ;;
esac

context_usage_encode_key() {
  # Parameter expansion rather than a tr pipeline. This runs on every state
  # path resolution, so the two forks it saves outweigh the work it does.
  # Deleting newlines before translating is safe: the classes '/+' and '=\n'
  # are disjoint, so neither step can see the other's characters.
  local encoded
  encoded="$(printf '%s' "$1" | base64)"
  encoded="${encoded//$'\n'/}"
  encoded="${encoded//\//_}"
  encoded="${encoded//+/-}"
  printf '%s' "${encoded//=/}"
}

context_usage_atomic_write() {
  local file="$1" content="$2" dir tmp
  [ ! -d "$file" ] || return 1
  dir="${file%/*}"
  [ "$dir" != "$file" ] || dir="."
  [ -n "$dir" ] || dir="/"
  # mkdir -p succeeds on an existing directory, so skipping it when the
  # directory is already there drops a fork without changing any failure path.
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$(umask 077; mktemp "$dir/.record.XXXXXX" 2>/dev/null)" || return 1
  if ! printf '%s\n' "$content" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if [ -d "$file" ] || ! mv "$tmp" "$file" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  return 0
}

# The session's context load: the occupancy Claude Code reports plus the
# allowance it does not. Both figures the status line shows are formed from
# this one quantity, so a reader who divides the printed figure by the window
# arrives at the printed percentage (R1, R2).
context_usage_load_tokens() {
  local current="$1"
  case "$current" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s' "$((current + CONTEXT_USAGE_ALLOWANCE_TOKENS))"
}

# The operator's bar: the load as a share of the window, capped at 100. This is
# the only place a percentage is formed.
context_usage_fullness_pct() {
  local current="$1" window="$2" load pct
  load="$(context_usage_load_tokens "$current")" || return 1
  case "$window" in '' | *[!0-9]* | 0) return 1 ;; esac
  pct=$((load * 100 / window))
  [ "$pct" -gt 100 ] && pct=100
  printf '%s' "$pct"
}
