#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf '%s\n' 'Usage: follow-up.sh <address> <text> [--wait] [--force]' >&2
}

status_exit() {
  local status="$1" code="$2"
  printf 'follow-up.sh: status=%s\n' "$status" >&2
  exit "$code"
}

[ "$#" -ge 2 ] || { usage; status_exit refused 2; }

address="$1"
text="$2"
shift 2
wait_for_turn=0
force=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --wait) wait_for_turn=1; shift ;;
    --force) force=1; shift ;;
    *) printf "follow-up.sh: unknown flag '%s'\n" "$1" >&2; status_exit refused 2 ;;
  esac
done

if [ -z "${HC_TERMINAL_ID:-}" ]; then
  printf '%s\n' 'follow-up.sh: peer consults require HC_TERMINAL_ID' >&2
  status_exit refused 2
fi
if ! command -v hc-run >/dev/null 2>&1; then
  printf '%s\n' 'follow-up.sh: hc-run is not on PATH' >&2
  status_exit refused 2
fi
if ! command -v hc >/dev/null 2>&1; then
  printf '%s\n' 'follow-up.sh: hc is not on PATH' >&2
  status_exit refused 2
fi

send_out="$(mktemp)"
send_err="$(mktemp)"
wait_out="$(mktemp)"
wait_err="$(mktemp)"
trap 'rm -f "$send_out" "$send_err" "$wait_out" "$wait_err"' EXIT

args=(send)
if [ "$wait_for_turn" -eq 1 ]; then
  args+=(--wait --timeout 1800)
fi
if [ "$force" -eq 1 ]; then
  args+=(--force)
fi
args+=("$address" "$text")

if [ "$wait_for_turn" -eq 1 ]; then
  wait_deadline=$(( $(date +%s) + 1800 ))
fi

set +e
hc "${args[@]}" >"$send_out" 2>"$send_err"
send_status=$?
set -e
cat "$send_out"
[ -s "$send_err" ] && cat "$send_err" >&2

if [ "$send_status" -eq 9 ]; then
  status_exit blocked 1
fi
if [ "$send_status" -ne 0 ]; then
  status_exit delivery-unknown 1
fi

if [ "$wait_for_turn" -eq 1 ]; then
  json_wait_fields() {
    python3 - "$1" "${2:-}" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        raw = stream.read().strip()
    data = json.loads(raw)
    waited = data
    if sys.argv[2]:
        waited = data.get(sys.argv[2]) or {}
except (OSError, ValueError, TypeError):
    raise SystemExit(1)

ended = waited.get("ended")
if ended is True:
    ended = "true"
elif ended is False:
    ended = "false"
else:
    ended = ""
print("\t".join((ended, str(waited.get("reason") or ""), str(waited.get("status") or ""))))
PY
  }

  remaining_wait_timeout() {
    local remaining now
    now="$(date +%s)"
    remaining=$((wait_deadline - now))
    [ "$remaining" -gt 0 ] || remaining=1
    printf '%s' "$remaining"
  }

  wait_fields=''
  wait_fields="$(json_wait_fields "$send_out" wait 2>/dev/null)" || true
  wait_ended=''
  wait_reason=''
  wait_state=''
  IFS=$'\t' read -r wait_ended wait_reason wait_state <<< "$wait_fields"
  while :; do
    if [ "$wait_reason" = message ]; then
      if [ "$wait_state" = idle ] || [ "$wait_state" = 'done' ]; then
        break
      fi
      wait_timeout="$(remaining_wait_timeout)"
      set +e
      hc wait --json --timeout "$wait_timeout" "$address" >"$wait_out" 2>"$wait_err"
      wait_status=$?
      set -e
      if [ "$wait_status" -ne 0 ]; then
        [ -s "$wait_err" ] && cat "$wait_err" >&2
        status_exit delivery-unknown 1
      fi
      wait_fields=''
      wait_fields="$(json_wait_fields "$wait_out" 2>/dev/null)" || true
      wait_ended=''
      wait_reason=''
      wait_state=''
      IFS=$'\t' read -r wait_ended wait_reason wait_state <<< "$wait_fields"
      continue
    fi
    if [ "$wait_ended" = false ] || [ "$wait_reason" = timeout ]; then
      status_exit working 124
    fi
    break
  done
  if [ "$wait_state" != "idle" ] && [ "$wait_state" != "done" ] && [ "$wait_reason" != "exit" ]; then
    status_exit delivery-unknown 1
  fi
fi

status_exit delivered 0
