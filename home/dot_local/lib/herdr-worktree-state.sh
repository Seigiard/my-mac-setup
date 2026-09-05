#!/usr/bin/env bash
# State, claim, and diagnostic primitives for herdr-worktree-identity.

HERDR_WORKTREE_IDENTITY_STATE_DIR="${HERDR_WORKTREE_IDENTITY_STATE_DIR:-$HOME/.cache/herdr-worktree-identity}"

encode_key() {
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

encode_value() {
  local encoded
  encoded="$(printf '%s' "$1" | base64)"
  printf '%s' "${encoded//$'\n'/}"
}

namespace_dir() {
  [ -n "${1:-}" ] || return 1
  printf '%s/repositories/%s' "$HERDR_WORKTREE_IDENTITY_STATE_DIR" "$(encode_key "$1")"
}

atomic_write() {
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

read_state_field() {
  # One in-process scan instead of grep|cut. resolve_pane_location reads seven
  # fields per pane and location_state_matches eight, so the old form grepped a
  # ten-line file fifteen times per pane. Keys are literal identifiers, so
  # dropping grep's regex semantics is not observable, and the trailing
  # `|| [ -n "$line" ]` keeps a final line that has no newline.
  local file="$1" key="$2" line encoded=""
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${key}="*) encoded="${line#*=}"; break ;;
    esac
  done < "$file" 2>/dev/null
  [ -n "$encoded" ] || return 0
  printf '%s' "$encoded" | base64 -d 2>/dev/null || true
}

record_number() {
  local file="$1" key="$2" line value=""
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${key}="*) value="${line#*=}"; break ;;
    esac
  done < "$file" 2>/dev/null
  case "$value" in
    '' | *[!0-9]*) return 0 ;;
  esac
  printf '%s' "$value"
}

process_start_token() {
  ps -p "$1" -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# shellcheck disable=SC2034 # Callers read the owner selected by acquire_claim.
claim_owner_id=""

# Return 0 when a stale claim was removed, 1 when it remains owned, and 2 on
# an unexpected filesystem error. Claim files are fully written before an
# atomic hard link publishes them, so readers never observe a live blank owner.
recover_claim() {
  local lock="$1" attempt="$2" owner pid start current_start observed
  [ -f "$lock" ] || {
    [ -e "$lock" ] && return 2
    return 0
  }
  observed="$(cat "$lock" 2>/dev/null)" || return 2
  owner="$(read_state_field "$lock" owner_id)"
  if [ -z "$owner" ]; then
    [ "$attempt" -ge 3 ] || return 1
    [ "$(cat "$lock" 2>/dev/null)" = "$observed" ] || return 1
    rm -f "$lock" 2>/dev/null && return 0
    [ -e "$lock" ] && return 1
    return 2
  fi
  pid="$(record_number "$lock" pid)"
  start="$(read_state_field "$lock" process_start)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    current_start="$(process_start_token "$pid")"
    [ -n "$current_start" ] || return 1
    if [ -n "$start" ] && [ "$start" = "$current_start" ]; then
      return 1
    fi
  fi
  [ "$(cat "$lock" 2>/dev/null)" = "$observed" ] || return 1
  rm -f "$lock" 2>/dev/null && return 0
  [ -e "$lock" ] && return 1
  return 2
}

# Return 0 on acquisition, 2 when a live owner exhausts the bound, and 1 for
# invalid input or filesystem failures. Contention is intentionally retryable.
acquire_claim() {
  local lock="$1" attempts="$2" attempt=0 owner start owner_record recovery dir candidate delay=0.01
  case "$attempts" in
    '' | *[!0-9]* | 0) return 1 ;;
  esac
  dir="${lock%/*}"
  [ "$dir" != "${lock}" ] || dir="."
  [ -n "$dir" ] || dir="/"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 1
  while :; do
    if [ -e "$lock" ]; then
      recover_claim "$lock" "$((attempt + 1))"
      recovery=$?
      case "$recovery" in
        0) continue ;;
        2) return 1 ;;
      esac
      attempt=$((attempt + 1))
      [ "$attempt" -lt "$attempts" ] || return 2
      sleep "$delay"
      case "$delay" in
        0.01) delay=0.02 ;;
        0.02) delay=0.04 ;;
        0.04) delay=0.08 ;;
        0.08) delay=0.16 ;;
        *) delay=0.25 ;;
      esac
      continue
    fi
    owner="$$.$RANDOM"
    start="$(process_start_token "$$")"
    [ -n "$start" ] || return 1
    owner_record="owner_id=$(encode_value "$owner")
pid=$$
process_start=$(encode_value "$start")"
    candidate="$dir/.claim.$$.$RANDOM"
    if ! (umask 077; printf '%s\n' "$owner_record" > "$candidate") 2>/dev/null; then
      rm -f "$candidate" 2>/dev/null || true
      return 1
    fi
    if [ -d "$lock" ]; then
      rm -f "$candidate" 2>/dev/null || true
      return 1
    fi
    if ln "$candidate" "$lock" 2>/dev/null; then
      rm -f "$candidate" 2>/dev/null || true
      # shellcheck disable=SC2034 # The process that sourced this library reads it.
      claim_owner_id="$owner"
      return 0
    fi
    rm -f "$candidate" 2>/dev/null || true
    [ -e "$lock" ] || return 1
  done
}

release_claim() {
  local lock="$1" owner="$2"
  [ -n "$owner" ] || return 0
  [ "$(read_state_field "$lock" owner_id)" = "$owner" ] || return 0
  rm -f "$lock" 2>/dev/null || return 1
}

# Diagnostics are append-only evidence. No state helper reads this log.
record_diagnostic() {
  local file="$1" reason="$2" observed_state="$3" dir
  dir="${file%/*}"
  [ "$dir" != "${file}" ] || dir="."
  [ -n "$dir" ] || dir="/"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 1
  printf 'reason=%s observed_state=%s\n' "$reason" "$observed_state" >> "$file" 2>/dev/null
}
