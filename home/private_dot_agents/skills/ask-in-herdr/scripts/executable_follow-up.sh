#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf 'Usage: follow-up.sh <prompt|reply> <alias> <pane-id> <text> [--skills DIR]...\n' >&2
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
skills_count=0
skills=()
while [ $# -gt 0 ]; do
  case "$1" in
    --skills) [ $# -ge 2 ] || { usage; status_exit refused 2; }; skills+=("$2"); skills_count=$((skills_count + 1)); shift 2 ;;
    *) printf "follow-up.sh: unknown flag '%s'\n" "$1" >&2; status_exit refused 2 ;;
  esac
done

[ "${HERDR_ENV:-}" = 1 ] || { printf 'follow-up.sh: peer consults require HERDR_ENV=1\n' >&2; status_exit refused 2; }
command -v herdr-child >/dev/null 2>&1 \
  || { printf 'follow-up.sh: herdr-child is not on PATH\n' >&2; status_exit refused 2; }
command -v herdr >/dev/null 2>&1 \
  || { printf 'follow-up.sh: herdr is not on PATH\n' >&2; status_exit refused 2; }
command -v pre-external-secret-scan >/dev/null 2>&1 \
  || { printf 'follow-up.sh: pre-external-secret-scan is not on PATH\n' >&2; status_exit refused 2; }

pane_json="$(herdr pane get "$pane")" \
  || { printf 'follow-up.sh: child pane is unavailable\n' >&2; status_exit refused 2; }
cwd="$(printf '%s' "$pane_json" | python3 -c 'import json,sys
pane_id=sys.argv[1]
pane=json.load(sys.stdin).get("result",{}).get("pane",{})
cwd=pane.get("cwd","")
if pane.get("pane_id") != pane_id or not cwd: raise SystemExit(1)
print(cwd)' "$pane")" \
  || { printf 'follow-up.sh: child pane has no trustworthy working directory\n' >&2; status_exit refused 2; }

question_file="$(mktemp)"
trap 'rm -f "$question_file"' EXIT
printf '%s\n' "$question" > "$question_file"
scan_paths=("$cwd" "$question_file")
if [ "$skills_count" -gt 0 ]; then
  set +u
  for skill in "${skills[@]}"; do scan_paths+=("$skill"); done
  set -u
fi
if ! pre-external-secret-scan "${scan_paths[@]}"; then
  status_exit refused 2
fi

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
