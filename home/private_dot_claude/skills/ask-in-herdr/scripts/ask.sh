#!/usr/bin/env bash
# Start a live peer consult through the shared herdr child contract.
#
# Usage: ask.sh <claude|opencode|pi> <question> [--rw] [--model M]
#               [--effort L] [--cwd DIR] [--skills DIR]... [--agent NAME]

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: ask.sh <claude|opencode|pi> <question> [flags]
Flags: --rw --model M --effort L --cwd DIR --skills DIR --agent NAME
EOF
}

status_exit() {
  local status="$1" code="$2"
  printf 'ask.sh: status=%s\n' "$status" >&2
  exit "$code"
}

[ $# -ge 2 ] || { usage; status_exit refused 2; }
AGENT="$1"
QUESTION="$2"
shift 2
case "$AGENT" in claude|opencode|pi) ;; *) printf "ask.sh: unknown agent '%s' (have: claude opencode pi)\n" "$AGENT" >&2; status_exit refused 2 ;; esac

RW=0
MODEL=""
EFFORT=""
CWD="$PWD"
AGENT_NAME=""
SKILLS_COUNT=0
SKILLS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rw) RW=1; shift ;;
    --model) [ $# -ge 2 ] || { usage; status_exit refused 2; }; MODEL="$2"; shift 2 ;;
    --effort) [ $# -ge 2 ] || { usage; status_exit refused 2; }; EFFORT="$2"; shift 2 ;;
    --cwd) [ $# -ge 2 ] || { usage; status_exit refused 2; }; CWD="$2"; shift 2 ;;
    --skills) [ $# -ge 2 ] || { usage; status_exit refused 2; }; SKILLS+=("$2"); SKILLS_COUNT=$((SKILLS_COUNT + 1)); shift 2 ;;
    --agent) [ $# -ge 2 ] || { usage; status_exit refused 2; }; AGENT_NAME="$2"; shift 2 ;;
    *) printf "ask.sh: unknown flag '%s'\n" "$1" >&2; status_exit refused 2 ;;
  esac
done

if [ "${HERDR_ENV:-}" != "1" ]; then
  printf 'ask.sh: peer consults require HERDR_ENV=1\n' >&2
  status_exit refused 2
fi
if ! command -v herdr-child >/dev/null 2>&1; then
  printf 'ask.sh: herdr-child is not on PATH; apply the child launch contract first\n' >&2
  status_exit refused 2
fi
if ! command -v herdr >/dev/null 2>&1; then
  printf 'ask.sh: herdr is not on PATH\n' >&2
  status_exit refused 2
fi

posture=ro
[ "$RW" -eq 0 ] || posture=rw

question_file="$(mktemp)"
start_out="$(mktemp)"
start_err="$(mktemp)"
read_out="$(mktemp)"
read_err="$(mktemp)"
pane_out="$(mktemp)"
agent_out="$(mktemp)"
agent_err="$(mktemp)"
trap 'rm -f "$question_file" "$start_out" "$start_err" "$read_out" "$read_err" "$pane_out" "$agent_out" "$agent_err"' EXIT
printf '%s' "$QUESTION" > "$question_file"

args=(start --kind "$AGENT" --posture "$posture" --cwd "$CWD" \
  --prompt-file "$question_file" --wait --timeout 1800000)
[ -z "$MODEL" ] || args+=(--model "$MODEL")
[ -z "$EFFORT" ] || args+=(--effort "$EFFORT")
[ -z "$AGENT_NAME" ] || args+=(--agent "$AGENT_NAME")
if [ "$SKILLS_COUNT" -gt 0 ]; then
  set +u
  for skill in "${SKILLS[@]}"; do args+=(--skills "$skill"); done
  set -u
fi

set +e
herdr-child "${args[@]}" >"$start_out" 2>"$start_err"
start_status=$?
set -e

if [ "$start_status" -eq 2 ]; then
  cat "$start_err" >&2
  status_exit refused 2
fi
if [ "$start_status" -ne 0 ] && [ "$start_status" -ne 124 ]; then
  cat "$start_err" >&2
  status_exit undelivered 1
fi

result="$(cat "$start_out")"
pane="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pane"])' 2>/dev/null || true)"
started_name="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["agent"])' 2>/dev/null || true)"
if [ -z "$pane" ] || [ -z "$started_name" ]; then
  cat "$start_err" >&2
  status_exit undelivered 1
fi

captured_terminal="$(herdr-child verify --to "$started_name" --pane "$pane" 2>/dev/null)" || {
  printf 'ask.sh: returned child alias and pane are not one live agent\n' >&2
  status_exit undelivered 1
}

source=recent-unwrapped
[ "$AGENT" != claude ] || source=visible
set +e
herdr agent read "$started_name" --source "$source" --lines 200 >"$read_out" 2>"$read_err"
read_status=$?
herdr pane get "$pane" >"$pane_out" 2>/dev/null
pane_status=$?
herdr agent get "$started_name" >"$agent_out" 2>"$agent_err"
agent_get_status=$?
set -e

fresh_terminal="$(herdr-child verify --to "$started_name" --pane "$pane" 2>/dev/null)" || true
if [ "$fresh_terminal" != "$captured_terminal" ]; then
  printf 'ask.sh: child alias, pane, or terminal changed while output was captured; output discarded\n' >&2
  status_exit undelivered 1
fi

if [ "$read_status" -ne 0 ]; then
  cat "$read_err" >&2
  status_exit undelivered 1
fi
cat "$read_out"
printf 'ask.sh: consult is in herdr pane %s (left open; close with: herdr-child reap --to %s --pane %s)\n' "$pane" "$started_name" "$pane" >&2

if [ "$start_status" -eq 124 ]; then
  cat "$start_err" >&2
  status_exit working 124
fi

waiting_label=""
if [ "$pane_status" -eq 0 ]; then
  waiting_label="$(python3 -c 'import json,sys
pane=json.load(sys.stdin).get("result",{}).get("pane",{})
labels=pane.get("state_labels") or {}
raise SystemExit(0 if any(str(v)=="waiting for parent" for v in labels.values()) else 1)' < "$pane_out" 2>/dev/null && printf yes || true)"
fi
if [ "$waiting_label" = yes ]; then
  status_exit blocked 1
fi

if [ "$agent_get_status" -ne 0 ]; then
  cat "$agent_err" >&2
  status_exit undelivered 1
fi
agent_status="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["agent"]["agent_status"])' < "$agent_out" 2>/dev/null || true)"
case "$agent_status" in
  idle|done)
    printf -v reminder '%s\n\n%s\n%s\n%s\n%s\n%s' \
      "[child-settled v1 agent=$started_name pane=$pane]" \
      "The child is $agent_status and its initial answer has been read." \
      'If another turn may have run, read its current output before reaping.' \
      'If no follow-up is needed, run:' \
      "herdr-child reap --to $started_name --pane $pane" \
      "If you need a follow-up, leave the pane open and prompt $started_name."
    if ! herdr agent prompt "$HERDR_PANE_ID" "$reminder" >/dev/null 2>&1; then
      printf 'ask.sh: warning: could not queue the cleanup reminder for %s in pane %s\n' "$started_name" "$pane" >&2
    fi
    status_exit answered 0
    ;;
  blocked) status_exit blocked 1 ;;
  working|unknown) status_exit working 124 ;;
  *) status_exit undelivered 1 ;;
esac
