#!/usr/bin/env bash
# State, claim, and diagnostic primitives for herdr-worktree-identity.

HERDR_WORKTREE_IDENTITY_STATE_DIR="${HERDR_WORKTREE_IDENTITY_STATE_DIR:-$HOME/.cache/herdr-worktree-identity}"

encode_key() {
  printf '%s' "$1" | base64 | tr '/+' '_-' | tr -d '=\n'
}

encode_value() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

namespace_dir() {
  [ -n "${1:-}" ] || return 1
  printf '%s/repositories/%s' "$HERDR_WORKTREE_IDENTITY_STATE_DIR" "$(encode_key "$1")"
}

atomic_write() {
  local file="$1" content="$2" dir tmp
  [ ! -d "$file" ] || return 1
  dir="$(dirname "$file")"
  mkdir -p "$dir" 2>/dev/null || return 1
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
  local file="$1" key="$2" encoded
  [ -f "$file" ] || return 0
  encoded="$(grep -m1 "^${key}=" "$file" 2>/dev/null | cut -d= -f2-)"
  [ -n "$encoded" ] || return 0
  printf '%s' "$encoded" | base64 -d 2>/dev/null || true
}

record_number() {
  local file="$1" key="$2" value
  [ -f "$file" ] || return 0
  value="$(sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -1)"
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
# an unexpected filesystem error. A blank process-start never proves liveness.
recover_claim() {
  local lock="$1" attempt="$2" owner pid start current_start
  owner="$(read_state_field "$lock/owner" owner_id)"
  if [ -z "$owner" ]; then
    [ "$attempt" -ge 3 ] || return 1
    if [ -f "$lock/owner" ] && [ -z "$(read_state_field "$lock/owner" owner_id)" ]; then
      rm -f "$lock/owner" 2>/dev/null || return 2
    fi
    rmdir "$lock" 2>/dev/null && return 0
    [ -d "$lock" ] && return 1
    return 2
  fi
  pid="$(record_number "$lock/owner" pid)"
  start="$(read_state_field "$lock/owner" process_start)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    current_start="$(process_start_token "$pid")"
    if [ -n "$start" ] && [ "$start" = "$current_start" ]; then
      return 1
    fi
  fi
  [ "$(read_state_field "$lock/owner" owner_id)" = "$owner" ] || return 1
  rm -f "$lock/owner" 2>/dev/null || return 2
  rmdir "$lock" 2>/dev/null && return 0
  [ -d "$lock" ] && return 1
  return 2
}

# Return 0 on acquisition, 2 when a live owner exhausts the bound, and 1 for
# invalid input or filesystem failures. Contention is intentionally retryable.
acquire_claim() {
  local lock="$1" attempts="$2" attempt=0 owner start owner_record recovery dir
  case "$attempts" in
    '' | *[!0-9]* | 0) return 1 ;;
  esac
  dir="$(dirname "$lock")"
  mkdir -p "$dir" 2>/dev/null || return 1
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      owner="$$.$RANDOM"
      start="$(process_start_token "$$")"
      owner_record="owner_id=$(encode_value "$owner")
pid=$$
process_start=$(encode_value "$start")"
      if ! atomic_write "$lock/owner" "$owner_record"; then
        rmdir "$lock" 2>/dev/null || true
        return 1
      fi
      # shellcheck disable=SC2034 # The process that sourced this library reads it.
      claim_owner_id="$owner"
      return 0
    fi
    [ -d "$lock" ] || return 1
    recover_claim "$lock" "$((attempt + 1))"
    recovery=$?
    case "$recovery" in
      0) continue ;;
      2) return 1 ;;
    esac
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$attempts" ] || return 2
    sleep 0.01
  done
}

release_claim() {
  local lock="$1" owner="$2"
  [ -n "$owner" ] || return 0
  [ "$(read_state_field "$lock/owner" owner_id)" = "$owner" ] || return 0
  rm -f "$lock/owner" 2>/dev/null || return 1
  rmdir "$lock" 2>/dev/null || return 1
}

# Diagnostics are append-only evidence. No state helper reads this log.
record_diagnostic() {
  local file="$1" reason="$2" observed_state="$3" dir
  dir="$(dirname "$file")"
  mkdir -p "$dir" 2>/dev/null || return 1
  printf 'reason=%s observed_state=%s\n' "$reason" "$observed_state" >> "$file" 2>/dev/null
}
