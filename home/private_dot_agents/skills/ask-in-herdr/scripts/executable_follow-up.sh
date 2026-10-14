#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf 'Usage: follow-up.sh <prompt|reply> <alias> <pane-id> <text>\n' >&2
}

status_exit() {
  local status="$1" code="$2"
  printf 'follow-up.sh: status=%s\n' "$status" >&2
  exit "$code"
}

[ $# -ge 4 ] || { usage; status_exit refused 2; }
mode="$1"
name="$2"
pane="$3"
question="$4"
shift 4
case "$mode" in prompt|reply) ;; *) usage; status_exit refused 2 ;; esac
[ "$#" -eq 0 ] || { printf "follow-up.sh: unknown flag '%s'\n" "$1" >&2; status_exit refused 2; }

[ "${HERDR_ENV:-}" = 1 ] || { printf 'follow-up.sh: peer consults require HERDR_ENV=1\n' >&2; status_exit refused 2; }
command -v herdr-child >/dev/null 2>&1 \
  || { printf 'follow-up.sh: herdr-child is not on PATH\n' >&2; status_exit refused 2; }
command -v herdr >/dev/null 2>&1 \
  || { printf 'follow-up.sh: herdr is not on PATH\n' >&2; status_exit refused 2; }

set +e
if [ "$mode" = prompt ]; then
  herdr-child prompt --to "$name" --pane "$pane" --wait "$question"
else
  herdr-child reply --to "$name" --pane "$pane" "$question"
fi
prompt_status=$?
set -e
case "$prompt_status" in
  0) status_exit delivered 0 ;;
  124) status_exit working 124 ;;
  *) status_exit delivery-unknown 1 ;;
esac
