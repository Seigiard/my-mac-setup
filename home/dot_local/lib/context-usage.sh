#!/usr/bin/env bash
# Context growth measurement shared by the Claude Code statusline and the
# context-threshold Stop hook. One owner for both growth numbers: window
# fullness and turns since the last compaction (R1).
#
# Sourcing this file must have no effect beyond defining these functions and
# their defaults — no output, no shell-option or trap changes, no redefinition
# of anything an earlier module declared (KTD1). Every name is prefixed
# `context_usage_` for that reason: `atomic_write` and friends already exist in
# the herdr module family, and the module-hygiene test sources them together.
#
# Two state files, one writer each (KTD10):
#   usage/<key>    written by the statusline, read by the hook
#   announce/<key> written by the hook, removed by the SessionStart injector
# Both are replaced whole by rename, so a shared file would let one writer
# erase the other's fields.

# ${HOME:-} rather than $HOME: a caller running under `set -u` with no HOME
# must not abort here. Every path built from it is guarded at use.
CONTEXT_USAGE_STATE_DIR="${CONTEXT_USAGE_STATE_DIR:-${HOME:-}/.cache/context-usage}"

# Percentage points added to raw window occupancy to stand in for the system
# prompt, which Claude Code does not report (R2). Empirical; one definition
# serves the bar and the announcement alike.
CONTEXT_USAGE_ALLOWANCE_PCT="${CONTEXT_USAGE_ALLOWANCE_PCT:-20}"

# Thresholds (R5). Turn counts come from the U1 re-derivation of the local
# session-length distribution under the rule this library evaluates.
CONTEXT_USAGE_FULLNESS_WARN_PCT="${CONTEXT_USAGE_FULLNESS_WARN_PCT:-70}"
CONTEXT_USAGE_FULLNESS_HARD_PCT="${CONTEXT_USAGE_FULLNESS_HARD_PCT:-85}"
CONTEXT_USAGE_TURNS_WARN="${CONTEXT_USAGE_TURNS_WARN:-150}"
CONTEXT_USAGE_TURNS_HARD="${CONTEXT_USAGE_TURNS_HARD:-300}"

# Bound on the goal-extraction subprocess (R13). U1 measured 8-9s on real
# 350-turn forks; the default leaves room for a slower model or a larger
# session without letting the hook hang a turn.
CONTEXT_USAGE_EXTRACTION_TIMEOUT="${CONTEXT_USAGE_EXTRACTION_TIMEOUT:-30}"
# The declared Stop-hook timeout is the outer bound. An override above it would
# let the platform truncate a call the hook is already managing, so an
# out-of-range or non-numeric value falls back to the default rather than
# silently taking effect.
CONTEXT_USAGE_EXTRACTION_TIMEOUT_MAX="${CONTEXT_USAGE_EXTRACTION_TIMEOUT_MAX:-40}"
case "$CONTEXT_USAGE_EXTRACTION_TIMEOUT" in
  '' | *[!0-9]* | 0) CONTEXT_USAGE_EXTRACTION_TIMEOUT=30 ;;
esac
[ "$CONTEXT_USAGE_EXTRACTION_TIMEOUT" -le "$CONTEXT_USAGE_EXTRACTION_TIMEOUT_MAX" ] ||
  CONTEXT_USAGE_EXTRACTION_TIMEOUT="$CONTEXT_USAGE_EXTRACTION_TIMEOUT_MAX"

# Ceiling on the transcript excerpt handed to the extractor (R13, R26). Bytes,
# not tokens: the hook has no tokenizer, and the byte-to-token ratio moves by a
# factor of two between English and Cyrillic. 120 KB is about 60k tokens in the
# worst case, which sits well inside the extraction model's window instead of
# aiming at its edge -- a prompt that overshoots is rejected outright, so the
# margin buys a working extraction rather than a slightly better goal.
CONTEXT_USAGE_EXTRACTION_BUDGET_BYTES="${CONTEXT_USAGE_EXTRACTION_BUDGET_BYTES:-120000}"
case "$CONTEXT_USAGE_EXTRACTION_BUDGET_BYTES" in
  '' | *[!0-9]* | 0) CONTEXT_USAGE_EXTRACTION_BUDGET_BYTES=120000 ;;
esac

# A rendered fullness number is trusted only while it can still describe the
# current turn (KTD3). The statusline renders many times per turn, so an older
# file means rendering stopped — a resumed session before its first render, or
# a turn that outran the UI. Fullness then reports unavailable and turn count
# carries the decision alone.
CONTEXT_USAGE_MAX_AGE_SECONDS="${CONTEXT_USAGE_MAX_AGE_SECONDS:-300}"

# Hard-threshold repeat cadence (R25, KTD12). The gap halves for every step of
# distance past the threshold and floors at every turn. Derived from the
# current distance rather than from a stored counter, so a resume or a fork
# cannot carry a stale cadence.
CONTEXT_USAGE_REPEAT_FIRST_GAP="${CONTEXT_USAGE_REPEAT_FIRST_GAP:-8}"
CONTEXT_USAGE_FULLNESS_REPEAT_STEP="${CONTEXT_USAGE_FULLNESS_REPEAT_STEP:-3}"
CONTEXT_USAGE_TURNS_REPEAT_STEP="${CONTEXT_USAGE_TURNS_REPEAT_STEP:-25}"

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

context_usage_encode_value() {
  local encoded
  encoded="$(printf '%s' "$1" | base64)"
  printf '%s' "${encoded//$'\n'/}"
}

context_usage_decode_value() {
  printf '%s' "$1" | base64 -d 2>/dev/null || true
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

context_usage_usage_file() {
  [ -n "${1:-}" ] || return 1
  printf '%s/usage/%s' "$CONTEXT_USAGE_STATE_DIR" "$(context_usage_encode_key "$1")"
}

context_usage_announce_file() {
  [ -n "${1:-}" ] || return 1
  printf '%s/announce/%s' "$CONTEXT_USAGE_STATE_DIR" "$(context_usage_encode_key "$1")"
}

context_usage_field() {
  local file="$1" key="$2" line value=""
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${key}="*) value="${line#*=}"; break ;;
    esac
  done < "$file" 2>/dev/null
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

context_usage_number_field() {
  local value
  value="$(context_usage_field "$1" "$2")" || return 1
  case "$value" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s' "$value"
}

# --- the statusline's side -------------------------------------------------

# Publish the raw numbers Claude Code hands only to the statusline. The
# statusline never learns a threshold; it writes what it was given (KTD2).
context_usage_write_usage() {
  local session="$1" current="$2" window="$3" now="${4:-}" file
  [ -n "$session" ] || return 1
  case "$current" in '' | *[!0-9]*) return 1 ;; esac
  case "$window" in '' | *[!0-9]* | 0) return 1 ;; esac
  [ -n "$now" ] || now="$(date +%s 2>/dev/null)" || return 1
  file="$(context_usage_usage_file "$session")" || return 1
  context_usage_atomic_write "$file" "current_tokens=$current
window_size=$window
written_at=$now"
}

# Raw occupancy plus the system-prompt allowance, capped at 100. The bar and
# the announcement both come through here so they cannot disagree (R1, R2).
context_usage_fullness_pct() {
  local current="$1" window="$2" pct
  case "$current" in '' | *[!0-9]*) return 1 ;; esac
  case "$window" in '' | *[!0-9]* | 0) return 1 ;; esac
  pct=$((current * 100 / window + CONTEXT_USAGE_ALLOWANCE_PCT))
  [ "$pct" -gt 100 ] && pct=100
  printf '%s' "$pct"
}

# --- the hook's side -------------------------------------------------------

# Print the session's fullness percentage, or return 1 for "unavailable".
# Unavailable never degrades to a guess and never silences turn count (KTD3).
context_usage_read_fullness() {
  local session="$1" now="${2:-}" file current window written age
  file="$(context_usage_usage_file "$session")" || return 1
  current="$(context_usage_number_field "$file" current_tokens)" || return 1
  window="$(context_usage_number_field "$file" window_size)" || return 1
  written="$(context_usage_number_field "$file" written_at)" || return 1
  [ "$window" -gt 0 ] || return 1
  [ -n "$now" ] || now="$(date +%s 2>/dev/null)" || return 1
  age=$((now - written))
  [ "$age" -ge 0 ] || return 1
  [ "$age" -le "$CONTEXT_USAGE_MAX_AGE_SECONDS" ] || return 1
  context_usage_fullness_pct "$current" "$window"
}

# Assistant entries in the main transcript after the last compaction boundary
# (KTD4, R3, R18). jq parses each line, so a `"type":"assistant"` sequence
# quoted inside message content cannot be miscounted as a turn — a plain text
# scan of a real transcript overcounts by an order of magnitude.
context_usage_turn_count() {
  local transcript="$1"
  [ -n "$transcript" ] && [ -r "$transcript" ] || { printf '0'; return 0; }
  command -v jq > /dev/null 2>&1 || { printf '0'; return 0; }
  # A malformed line makes jq exit non-zero. The count from the lines that did
  # parse is still the best available answer, and propagating the failure would
  # take the caller's fullness dimension down with it under `set -o pipefail`.
  {
    jq -r 'if (.compactMetadata // null) != null then "C"
           elif .type == "assistant" then "A"
           else empty end' "$transcript" 2>/dev/null || true
  } | awk '/^C$/ { n = 0; next } /^A$/ { n++ } END { printf "%d", n + 0 }'
  return 0
}

# Turns to wait before announcing a hard threshold again, given how far past
# it the session has gone. Halves each step, floors at every turn (R25).
context_usage_repeat_gap() {
  local distance="$1" step="$2" gap="$CONTEXT_USAGE_REPEAT_FIRST_GAP"
  case "$distance" in '' | *[!0-9]*) distance=0 ;; esac
  case "$step" in '' | *[!0-9]* | 0) step=1 ;; esac
  while [ "$distance" -ge "$step" ] && [ "$gap" -gt 1 ]; do
    gap=$((gap / 2))
    distance=$((distance - step))
  done
  [ "$gap" -ge 1 ] || gap=1
  printf '%s' "$gap"
}

# Decide what, if anything, to announce this turn. Read-only: spending the
# budget is a separate call so the announcement file keeps one writer.
#
# Usage: context_usage_evaluate <session> <fullness|""> <turns>
# Prints `level=<warn|hard>` and `dimensions=<comma list>` and returns 0 when
# there is something to announce; returns 1 when there is not.
context_usage_evaluate() {
  local session="$1" fullness="$2" turns="$3"
  local file hard="" warn="" last gap
  file="$(context_usage_announce_file "$session")" || return 1
  case "$turns" in '' | *[!0-9]*) turns=0 ;; esac

  # Hard level first: it outranks warn and, per R22, consumes the warn budget
  # for the same dimension rather than producing a second message.
  if [ -n "$fullness" ] && [ "$fullness" -ge "$CONTEXT_USAGE_FULLNESS_HARD_PCT" ]; then
    gap="$(context_usage_repeat_gap \
      "$((fullness - CONTEXT_USAGE_FULLNESS_HARD_PCT))" "$CONTEXT_USAGE_FULLNESS_REPEAT_STEP")"
    if last="$(context_usage_number_field "$file" hard_fullness_turn)"; then
      if [ "$((turns - last))" -ge "$gap" ]; then
        hard="fullness"
      fi
    else
      hard="fullness"
    fi
  fi
  if [ "$turns" -ge "$CONTEXT_USAGE_TURNS_HARD" ]; then
    gap="$(context_usage_repeat_gap \
      "$((turns - CONTEXT_USAGE_TURNS_HARD))" "$CONTEXT_USAGE_TURNS_REPEAT_STEP")"
    if last="$(context_usage_number_field "$file" hard_turns_turn)"; then
      if [ "$((turns - last))" -ge "$gap" ]; then
        hard="${hard:+$hard,}turns"
      fi
    else
      hard="${hard:+$hard,}turns"
    fi
  fi
  # Warn level: once per session per dimension (R9), and one dimension having
  # spent its budget never suppresses the other (R10).
  if [ -n "$fullness" ] && [ "$fullness" -ge "$CONTEXT_USAGE_FULLNESS_WARN_PCT" ] &&
    ! context_usage_field "$file" warn_fullness_spent > /dev/null; then
    warn="fullness"
  fi
  if [ "$turns" -ge "$CONTEXT_USAGE_TURNS_WARN" ] &&
    ! context_usage_field "$file" warn_turns_spent > /dev/null; then
    warn="${warn:+$warn,}turns"
  fi

  if [ -n "$hard" ]; then
    # R22 allows one message per turn, so a dimension crossing warn in the same
    # turn as another crosses hard is named in that one message rather than
    # held back for the next one. It is reported separately because it did not
    # cross hard and must not record a hard announcement point.
    case ",$hard," in
      *,fullness,*) warn="$(printf '%s' "$warn" | sed -e 's/^fullness,//' -e 's/,fullness$//' -e 's/^fullness$//')" ;;
    esac
    case ",$hard," in
      *,turns,*) warn="$(printf '%s' "$warn" | sed -e 's/^turns,//' -e 's/,turns$//' -e 's/^turns$//')" ;;
    esac
    printf 'level=hard\ndimensions=%s\n' "$hard"
    [ -z "$warn" ] || printf 'warn_dimensions=%s\n' "$warn"
    return 0
  fi

  if [ -n "$warn" ]; then
    printf 'level=warn\ndimensions=%s\n' "$warn"
    return 0
  fi
  return 1
}

# Record an announcement. Read-modify-write of the whole file; the Stop hook is
# its only writer, so no merge with a concurrent writer is possible (KTD10).
#
# Usage: context_usage_spend <session> <level> <dimensions> <turns> [goal] [goal_status]
context_usage_spend() {
  local session="$1" level="$2" dimensions="$3" turns="$4" goal="${5:-}" goal_status="${6:-}"
  local file record="" warn_fullness warn_turns hard_fullness hard_turns stored_goal stored_status
  file="$(context_usage_announce_file "$session")" || return 1
  case "$turns" in '' | *[!0-9]*) turns=0 ;; esac

  warn_fullness="$(context_usage_field "$file" warn_fullness_spent || true)"
  warn_turns="$(context_usage_field "$file" warn_turns_spent || true)"
  hard_fullness="$(context_usage_number_field "$file" hard_fullness_turn || true)"
  hard_turns="$(context_usage_number_field "$file" hard_turns_turn || true)"
  stored_goal="$(context_usage_field "$file" goal || true)"
  stored_status="$(context_usage_field "$file" goal_status || true)"

  case ",$dimensions," in
    *,fullness,*)
      warn_fullness=1
      if [ "$level" = hard ]; then
        hard_fullness="$turns"
      fi
      ;;
  esac
  case ",$dimensions," in
    *,turns,*)
      warn_turns=1
      if [ "$level" = hard ]; then
        hard_turns="$turns"
      fi
      ;;
  esac

  # The goal is extracted once and thereafter reused (KD5, R9). A later call
  # supplying nothing keeps what is already stored.
  if [ -n "$goal_status" ] && [ -z "$stored_status" ]; then
    stored_status="$goal_status"
    stored_goal="$(context_usage_encode_value "$goal")"
  fi

  # An unset field is written as no line at all, so a reader never has to tell
  # an empty value from an unspent budget.
  record="$(
    if [ -n "$warn_fullness" ]; then printf 'warn_fullness_spent=1\n'; fi
    if [ -n "$warn_turns" ]; then printf 'warn_turns_spent=1\n'; fi
    if [ -n "$hard_fullness" ]; then printf 'hard_fullness_turn=%s\n' "$hard_fullness"; fi
    if [ -n "$hard_turns" ]; then printf 'hard_turns_turn=%s\n' "$hard_turns"; fi
    if [ -n "$stored_status" ]; then printf 'goal_status=%s\n' "$stored_status"; fi
    if [ -n "$stored_goal" ]; then printf 'goal=%s\n' "$stored_goal"; fi
  )"
  context_usage_atomic_write "$file" "$record"
}

# Non-zero when no goal has been extracted for this session yet.
context_usage_goal_status() {
  local file
  file="$(context_usage_announce_file "$1")" || return 1
  context_usage_field "$file" goal_status
}

# Prints the cached goal as one line. Returns 1 when none is stored, which is
# how a caller knows to run the extractor rather than reuse (KD5).
context_usage_goal() {
  local file encoded
  file="$(context_usage_announce_file "$1")" || return 1
  encoded="$(context_usage_field "$file" goal)" || return 1
  printf '%s\n' "$(context_usage_decode_value "$encoded")"
}

# Compaction re-arms every budget (R11). The SessionStart injector owns this.
context_usage_clear() {
  local file
  file="$(context_usage_announce_file "$1")" || return 1
  rm -f "$file" 2>/dev/null
  # The post-condition is what matters, not which call removed it. A caller
  # that treats a failed unlink as fatal would leave the budgets spent and the
  # session unable to announce again for the rest of its life.
  [ ! -e "$file" ]
}
