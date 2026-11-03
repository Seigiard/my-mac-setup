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
trap 'rm -f "$send_out" "$send_err"' EXIT

args=(send)
if [ "$wait_for_turn" -eq 1 ]; then
  args+=(--wait --timeout 1800)
fi
if [ "$force" -eq 1 ]; then
  args+=(--force)
fi
args+=("$address" "$text")

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
  wait_fields=''
  wait_fields="$(python3 - "$send_out" 2>/dev/null <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        raw = stream.read().strip()
    try:
        data = json.loads(raw)
    except ValueError:
        if not raw.endswith("}"):
            raise SystemExit(1)
        data = json.loads(raw[:-1])
    waited = data.get("wait") or {}
except (OSError, ValueError):
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
)" || true
  wait_ended=''
  wait_reason=''
  wait_state=''
  IFS=$'\t' read -r wait_ended wait_reason wait_state <<< "$wait_fields"
  if [ "$wait_ended" = false ] || [ "$wait_reason" = timeout ] || [ "$wait_reason" = message ]; then
    status_exit working 124
  fi
  if [ "$wait_state" != "idle" ] && [ "$wait_state" != "done" ] && [ "$wait_reason" != "exit" ]; then
    status_exit delivery-unknown 1
  fi
fi

status_exit delivered 0
