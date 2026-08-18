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

[ $# -ge 2 ] || { usage; exit 2; }
AGENT="$1"
QUESTION="$2"
shift 2
case "$AGENT" in claude|opencode|pi) ;; *) printf "ask.sh: unknown agent '%s' (have: claude opencode pi)\n" "$AGENT" >&2; exit 2 ;; esac

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
    --model) [ $# -ge 2 ] || { usage; exit 2; }; MODEL="$2"; shift 2 ;;
    --effort) [ $# -ge 2 ] || { usage; exit 2; }; EFFORT="$2"; shift 2 ;;
    --cwd) [ $# -ge 2 ] || { usage; exit 2; }; CWD="$2"; shift 2 ;;
    --skills) [ $# -ge 2 ] || { usage; exit 2; }; SKILLS+=("$2"); SKILLS_COUNT=$((SKILLS_COUNT + 1)); shift 2 ;;
    --agent) [ $# -ge 2 ] || { usage; exit 2; }; AGENT_NAME="$2"; shift 2 ;;
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
base="consult-$AGENT-$$"
base="${base:0:32}"
name="$base"
list_json="$(herdr agent list 2>/dev/null || printf '{"result":{"agents":[]}}')"
name_live() {
  printf '%s' "$list_json" | python3 -c 'import json,sys
name=sys.argv[1]
agents=json.load(sys.stdin).get("result",{}).get("agents",[])
raise SystemExit(0 if any(a.get("name")==name for a in agents) else 1)' "$1"
}
if name_live "$name"; then
  suffix=2
  while [ "$suffix" -le 99 ]; do
    tail="-$suffix"
    name="${base:0:$((32 - ${#tail}))}$tail"
    name_live "$name" || break
    suffix=$((suffix + 1))
  done
  if name_live "$name"; then
    printf 'ask.sh: could not derive a unique child name\n' >&2
    status_exit refused 2
  fi
fi

question_file="$(mktemp)"
start_out="$(mktemp)"
start_err="$(mktemp)"
trap 'rm -f "$question_file" "$start_out" "$start_err"' EXIT
printf '%s' "$QUESTION" > "$question_file"

args=(start --kind "$AGENT" --name "$name" --posture "$posture" --cwd "$CWD" \
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

source=recent-unwrapped
[ "$AGENT" != claude ] || source=visible
herdr agent read "$started_name" --source "$source" --lines 200 || true
printf 'ask.sh: consult is in herdr pane %s (left open; close with: herdr pane close %s)\n' "$pane" "$pane" >&2

if [ "$start_status" -eq 124 ]; then
  cat "$start_err" >&2
  status_exit working 124
fi

agent_json="$(herdr agent get "$started_name" 2>/dev/null || true)"
agent_status="$(printf '%s' "$agent_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["agent"]["agent_status"])' 2>/dev/null || true)"
case "$agent_status" in
  idle|done) status_exit answered 0 ;;
  blocked) status_exit blocked 1 ;;
  working|unknown) status_exit working 124 ;;
  *) status_exit undelivered 1 ;;
esac
