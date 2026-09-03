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

# The transport directory must exist before the question is composed, so the
# question can name the report path. Mirrors PEER_REPORT_DIR in
# ~/.claude/shared/herdr-peer-launch.md, the only file-backed answer path
# in this repository that works today.
report_dir="$(mktemp -d "${TMPDIR:-/tmp}/ask-in-herdr.XXXXXX")"
chmod 700 "$report_dir"
report_path="$report_dir/answer.report"

question_file="$(mktemp)"
start_out="$(mktemp)"
start_err="$(mktemp)"
read_out="$(mktemp)"
read_err="$(mktemp)"
pane_out="$(mktemp)"
agent_out="$(mktemp)"
agent_err="$(mktemp)"
trap 'rm -f "$question_file" "$start_out" "$start_err" "$read_out" "$read_err" "$pane_out" "$agent_out" "$agent_err"; [ "${RETAIN_TRANSPORT:-0}" = 1 ] || { rm -f "$report_path" "$report_path.tmp"; rmdir "$report_dir" 2>/dev/null || true; }' EXIT
# A read-only child has no file-writing tool: the ro posture strips Edit, Write
# and NotebookEdit from claude and denies edit for opencode. Both keep the shell,
# so the instruction names shell commands. Verified on 2026-09-03 with one
# read-only child of each kind.
{
  printf '%s\n\n' "$QUESTION"
  printf '%s\n' '[report-transport]'
  printf 'Before ending this turn, write your exact complete answer, byte-for-byte, to %s.\n' "$report_path"
  printf 'Use your shell to do it: write the text to %s.tmp and then rename that file to %s.\n' "$report_path" "$report_path"
  printf 'Do not use a file-editing tool. After the file is durable, return the same answer as usual.\n'
  printf 'Do not write any other file.\n'
} > "$question_file"

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
close_hint() {
  printf 'ask.sh: consult is in herdr pane %s (left open; close with: herdr-child reap --to %s --pane %s)\n' \
    "$pane" "$started_name" "$pane" >&2
}

# The child can still write its report on every non-terminal outcome, so the
# transport outlives this script there. Removing it while the child works
# leaves the child writing into a path that no longer exists.
retain_transport() {
  RETAIN_TRANSPORT=1
  printf 'ask.sh: child may still write its report; transport retained at %s\n' "$report_dir" >&2
}

# 0 usable, 3 absent, 4 present but empty, 5 present but not a regular file.
# A child that can write the transport can leave a symlink there. This is a
# coherence guard against a misbehaving child, not a containment boundary: a
# same-user child is not contained by it.
classify_report() {
  [ ! -L "$report_path" ] || return 5
  if [ -e "$report_path" ] && [ ! -f "$report_path" ]; then return 5; fi
  [ -e "$report_path" ] || return 3
  [ -s "$report_path" ] || return 4
  return 0
}

if [ "$start_status" -eq 124 ]; then
  cat "$read_out"
  close_hint
  cat "$start_err" >&2
  retain_transport
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
  cat "$read_out"
  close_hint
  retain_transport
  status_exit blocked 1
fi

if [ "$agent_get_status" -ne 0 ]; then
  cat "$agent_err" >&2
  status_exit undelivered 1
fi
agent_status="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["agent"]["agent_status"])' < "$agent_out" 2>/dev/null || true)"
case "$agent_status" in
  idle|done)
    set +e
    classify_report
    report_state=$?
    set -e
    if [ "$report_state" -eq 3 ] || [ "$report_state" -eq 4 ]; then
      # One bounded request to persist an answer the child already produced,
      # mirroring recover_peer_report in ~/.claude/shared/herdr-peer-launch.md.
      herdr-child prompt --to "$started_name" --pane "$pane" --wait --timeout 120000 \
        "The report transport file at $report_path is missing or empty. Write your exact complete previous answer, byte-for-byte, using your shell: write it to $report_path.tmp and then rename that file to $report_path. Do not use a file-editing tool. Then reply with only the path." \
        >/dev/null 2>&1 || true
      set +e
      classify_report
      report_state=$?
      set -e
    fi
    if [ "$report_state" -ne 0 ]; then
      # The pane text is evidence of what happened, never the answer.
      cat "$read_out" >&2
      close_hint
      case "$report_state" in
        3) status_exit no-report 3 ;;
        4) status_exit empty-report 4 ;;
        *) status_exit bad-report 5 ;;
      esac
    fi
    cat "$report_path"
    close_hint
    printf -v reminder '%s\n\n%s\n%s\n%s\n%s\n%s' \
      "[child-settled v1 agent=$started_name pane=$pane]" \
      "The child is $agent_status and its initial answer has been read." \
      'If another turn may have run, read its current output before reaping.' \
      'If no follow-up is needed, run:' \
      "herdr-child reap --to $started_name --pane $pane" \
      "If you need a follow-up, run: herdr-child prompt --to $started_name --pane $pane --wait '<task>'."
    if ! herdr agent prompt "$HERDR_PANE_ID" "$reminder" >/dev/null 2>&1; then
      printf 'ask.sh: warning: could not queue the cleanup reminder for %s in pane %s\n' "$started_name" "$pane" >&2
    fi
    status_exit answered 0
    ;;
  blocked) cat "$read_out"; close_hint; retain_transport; status_exit blocked 1 ;;
  working|unknown) cat "$read_out"; close_hint; retain_transport; status_exit working 124 ;;
  *) cat "$read_out" >&2; close_hint; status_exit undelivered 1 ;;
esac
