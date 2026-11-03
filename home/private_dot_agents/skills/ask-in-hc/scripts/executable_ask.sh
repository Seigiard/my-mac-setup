#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf '%s\n' 'Usage: ask.sh <claude|opencode|pi> <question> [--cwd DIR] [--template T] [--rw] [--close]' >&2
}

status_exit() {
  local status="$1" code="$2"
  printf 'ask.sh: status=%s\n' "$status" >&2
  exit "$code"
}

refuse() {
  printf '%s\n' "$1" >&2
  status_exit refused 2
}

[ "$#" -ge 2 ] || { usage; status_exit refused 2; }

agent="$1"
question="$2"
shift 2

case "$agent" in
  claude) template=reviewer ;;
  opencode) template=implementer-medium ;;
  pi) template=consult-pi ;;
  *) refuse "ask.sh: unknown agent '$agent' (have: claude opencode pi)" ;;
esac

cwd="$PWD"
close_terminal=0
read_write=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cwd)
      [ "$#" -ge 2 ] || { usage; status_exit refused 2; }
      cwd="$2"
      shift 2
      ;;
    --template)
      [ "$#" -ge 2 ] || { usage; status_exit refused 2; }
      [ -n "$2" ] || refuse 'ask.sh: --template needs a non-empty template name'
      template="$2"
      shift 2
      ;;
    --rw)
      read_write=1
      shift
      ;;
    --close)
      close_terminal=1
      shift
      ;;
    --model|--effort|--skills|--agent)
      refuse "ask.sh: $1 is fixed by the template; use --template to choose the command"
      ;;
    *)
      refuse "ask.sh: unknown flag '$1'"
      ;;
  esac
done

if [ "$agent" = claude ] && [ "$read_write" -eq 1 ]; then
  refuse 'ask.sh: --rw is not available for claude; use --template for a read-write template'
fi

if [ -z "${HC_TERMINAL_ID:-}" ]; then
  printf '%s\n' 'ask.sh: peer consults require HC_TERMINAL_ID' >&2
  status_exit refused 2
fi
if ! command -v hc-run >/dev/null 2>&1; then
  printf '%s\n' 'ask.sh: hc-run is not on PATH' >&2
  status_exit refused 2
fi
if ! command -v hc >/dev/null 2>&1; then
  printf '%s\n' 'ask.sh: hc is not on PATH' >&2
  status_exit refused 2
fi

report_dir="$(mktemp -d "${TMPDIR:-/tmp}/ask-in-hc.XXXXXX")"
chmod 700 "$report_dir"
report_path="$report_dir/answer.report"
question_file="$(mktemp)"
start_out="$(mktemp)"
start_err="$(mktemp)"
wait_out="$(mktemp)"
wait_err="$(mktemp)"
read_out="$(mktemp)"
read_err="$(mktemp)"
recovery_out="$(mktemp)"
recovery_err="$(mktemp)"
cleanup_err="$(mktemp)"
cleanup_out="$(mktemp)"
retain_transport=0
trap 'if [ "$retain_transport" -eq 0 ]; then rm -f "$question_file"; fi; rm -f "$start_out" "$start_err" "$wait_out" "$wait_err" "$read_out" "$read_err" "$recovery_out" "$recovery_err" "$cleanup_err" "$cleanup_out"; if [ "$retain_transport" -eq 0 ]; then rm -f "$report_path" "$report_path.tmp"; rmdir "$report_dir" 2>/dev/null || true; fi' EXIT

{
  printf '%s\n\n' "$question"
  printf '%s\n' '[report-transport]'
  printf 'Before ending this turn, write your exact complete answer, byte-for-byte, to %s.\n' "$report_path"
  printf 'Use your shell to do it: write the text to %s.tmp and then rename that file to %s.\n' "$report_path" "$report_path"
  printf '%s\n' 'Do not use a file-editing tool. After the file is durable, return the same answer as usual.'
  printf '%s\n' 'Do not write any other file.'
} > "$question_file"

close_hint() {
  printf 'ask.sh: consult is in hc terminal %s (%s) (left open; close with: hc kill %s; hc rm %s)\n' \
    "$address" "$alias" "$address" "$address" >&2
}

set +e
hc-run --cwd "$cwd" "$template" "$(cat "$question_file")" >"$start_out" 2>"$start_err"
start_status=$?
set -e

start_result="$(cat "$start_out")"
address=''
alias=''
read -r address alias _ <<< "$start_result"
if [ "$start_status" -eq 3 ]; then
  cat "$start_err" >&2
  retain_transport=1
  printf 'ask.sh: task kept at %s; resend it after readiness\n' "$question_file" >&2
  if [ -n "$address" ] && [ -n "$alias" ]; then
    close_hint
  fi
  status_exit undelivered 1
fi
if [ "$start_status" -ne 0 ]; then
  cat "$start_err" >&2
  status_exit undelivered 1
fi

if [ -z "$address" ] || [ -z "$alias" ]; then
  cat "$start_err" >&2
  retain_transport=1
  printf 'ask.sh: child may still write its report; transport retained at %s\n' "$report_dir" >&2
  status_exit undelivered 1
fi

retain() {
  retain_transport=1
  printf 'ask.sh: child may still write its report; transport retained at %s\n' "$report_dir" >&2
}

read_screen() {
  : > "$read_out"
  : > "$read_err"
  set +e
  hc read "$address" >"$read_out" 2>"$read_err"
  read_status=$?
  set -e
}

json_wait_fields() {
  python3 - "$1" "${2:-}" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        raw = stream.read().strip()
    data = json.loads(raw)
    if sys.argv[2]:
        nested = data.get(sys.argv[2])
        data = nested if isinstance(nested, dict) else {
            "ended": True,
            "reason": "status",
            "status": data.get("status"),
        }
except (OSError, ValueError, TypeError):
    raise SystemExit(1)

ended = data.get("ended")
if ended is True:
    ended = "true"
elif ended is False:
    ended = "false"
else:
    ended = ""
print("\t".join((ended, str(data.get("reason") or ""), str(data.get("status") or ""))))
PY
}

classify_report() {
  [ ! -L "$report_path" ] || return 5
  if [ -e "$report_path" ] && [ ! -f "$report_path" ]; then
    return 5
  fi
  [ -e "$report_path" ] || return 3
  [ -s "$report_path" ] || return 4
  return 0
}

remaining_wait_timeout() {
  local remaining now
  now="$(date +%s)"
  remaining=$((wait_deadline - now))
  [ "$remaining" -gt 0 ] || remaining=1
  printf '%s' "$remaining"
}

wait_for_child() {
  local timeout command_status
  timeout="$1"
  : > "$wait_out"
  : > "$wait_err"
  command_status=0
  hc wait --json --timeout "$timeout" "$address" >"$wait_out" 2>"$wait_err" || command_status=$?
  return "$command_status"
}

read_wait_fields() {
  wait_fields=''
  wait_fields="$(json_wait_fields "$wait_out" 2>/dev/null)" || true
  wait_ended=''
  wait_reason=''
  wait_state=''
  IFS=$'\t' read -r wait_ended wait_reason wait_state <<< "$wait_fields"
}

wait_deadline=$(( $(date +%s) + 1800 ))
set +e
wait_for_child 1800
wait_status=$?
set -e
if [ "$wait_status" -ne 0 ]; then
  cat "$wait_err" >&2
  retain
  close_hint
  status_exit undelivered 1
fi

read_wait_fields
message_answered=0
report_state=''
while :; do
  if [ "$wait_reason" = message ]; then
    set +e
    classify_report
    report_state=$?
    set -e
    if [ "$report_state" -eq 0 ]; then
      message_answered=1
      break
    fi
    if [ "$report_state" -ne 3 ] && [ "$report_state" -ne 4 ]; then
      read_screen
      [ "$read_status" -eq 0 ] && cat "$read_out"
      [ -s "$read_err" ] && cat "$read_err" >&2
      retain
      close_hint
      status_exit working 124
    fi

    next_wait_timeout="$(remaining_wait_timeout)"
    set +e
    wait_for_child "$next_wait_timeout"
    wait_status=$?
    set -e
    if [ "$wait_status" -ne 0 ]; then
      cat "$wait_err" >&2
      retain
      close_hint
      status_exit undelivered 1
    fi
    read_wait_fields
    continue
  fi

  if [ "$wait_ended" = false ] || [ "$wait_reason" = timeout ]; then
    read_screen
    [ "$read_status" -eq 0 ] && cat "$read_out"
    [ -s "$read_err" ] && cat "$read_err" >&2
    retain
    close_hint
    status_exit working 124
  fi

  if [ -z "$wait_ended" ]; then
    cat "$wait_out" >&2
    retain
    close_hint
    status_exit undelivered 1
  fi

  if [ "$wait_state" = blocked ]; then
    read_screen
    [ "$read_status" -eq 0 ] && cat "$read_out"
    [ -s "$read_err" ] && cat "$read_err" >&2
    retain
    close_hint
    status_exit blocked 1
  fi

  break
done

if [ "$message_answered" -eq 0 ]; then
  settled=0
  if [ "$wait_state" = "idle" ] || [ "$wait_state" = "done" ] || [ "$wait_reason" = "exit" ]; then
    settled=1
  fi
  if [ "$settled" -eq 0 ]; then
    cat "$wait_out" >&2
    retain
    close_hint
    status_exit undelivered 1
  fi

  set +e
  classify_report
  report_state=$?
  set -e

  if [ "$report_state" -ne 0 ] && [ "$wait_state" != "idle" ] && [ "$wait_state" != "done" ]; then
    cat "$wait_out" >&2
    retain
    close_hint
    status_exit undelivered 1
  fi
fi

if [ "$report_state" -eq 3 ] || [ "$report_state" -eq 4 ]; then
  recovery_prompt="The report transport file at $report_path is missing or empty. Write your exact complete previous answer, byte-for-byte, using your shell: write it to $report_path.tmp and then rename that file to $report_path. Do not use a file-editing tool. Then reply with only the path."
  set +e
  hc send --wait --timeout 120 "$address" "$recovery_prompt" --json >"$recovery_out" 2>"$recovery_err"
  recovery_status=$?
  set -e
  [ -s "$recovery_err" ] && cat "$recovery_err" >&2
  set +e
  classify_report
  report_state=$?
  set -e

  if [ "$report_state" -eq 3 ] || [ "$report_state" -eq 4 ]; then
    recovery_fields=""
    recovery_fields="$(json_wait_fields "$recovery_out" wait 2>/dev/null)" || true
    recovery_ended=''
    recovery_reason=''
    recovery_state=''
    IFS=$'\t' read -r recovery_ended recovery_reason recovery_state <<< "$recovery_fields"
    recovery_settled=0
    if [ "$recovery_ended" = "true" ] && { [ "$recovery_state" = "idle" ] || [ "$recovery_state" = "done" ] || [ "$recovery_reason" = "exit" ]; }; then
      recovery_settled=1
    fi
    if [ "$recovery_status" -ne 0 ] || [ "$recovery_settled" -eq 0 ]; then
      retain
      close_hint
      status_exit working 124
    fi
  fi
fi

if [ "$report_state" -ne 0 ]; then
  read_screen
  [ -s "$read_out" ] && cat "$read_out" >&2
  [ -s "$read_err" ] && cat "$read_err" >&2
  close_hint
  case "$report_state" in
    3) status_exit no-report 3 ;;
    4) status_exit empty-report 4 ;;
    *) status_exit bad-report 5 ;;
  esac
fi

cat "$report_path"
if [ "$close_terminal" -eq 1 ]; then
  : > "$cleanup_out"
  : > "$cleanup_err"
  set +e
  hc get "$address" --json >"$cleanup_out" 2>"$cleanup_err"
  get_status=$?
  set -e
  if [ "$get_status" -eq 0 ]; then
    terminal_state="$({
      python3 - "$cleanup_out" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        terminal = json.load(stream)
except (OSError, ValueError, TypeError):
    raise SystemExit(1)

status = terminal.get("status")
if isinstance(status, dict):
    print(status.get("state") or "")
elif terminal.get("state") == "finished":
    print("finished")
PY
    })" || terminal_state=''
    if [ "$terminal_state" = working ] || [ "$terminal_state" = blocked ]; then
      close_hint
      status_exit answered 0
    fi
  else
    [ -s "$cleanup_err" ] && cat "$cleanup_err" >&2
    close_hint
    status_exit answered 0
  fi
  : > "$cleanup_err"
  set +e
  hc kill "$address" >/dev/null 2>"$cleanup_err"
  hc rm "$address" >/dev/null 2>>"$cleanup_err"
  set -e
  [ -s "$cleanup_err" ] && cat "$cleanup_err" >&2
else
  close_hint
fi
status_exit answered 0
