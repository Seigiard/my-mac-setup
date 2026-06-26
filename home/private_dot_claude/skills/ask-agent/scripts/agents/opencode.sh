#!/usr/bin/env bash
# Run a one-shot opencode consult. Invoked by ask.sh; runnable standalone.
# opencode loads its own config/agents (all its skills). It has no --skill flag,
# so read-only is enforced via prompt framing; --skills is accepted but unused.
set -euo pipefail

QF="" ; RW=0 ; MODEL="" ; CWD="" ; AGENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --qf)     QF="$2"    ; shift 2 ;;
    --rw)     RW=1       ; shift   ;;
    --model)  MODEL="$2" ; shift 2 ;;
    --cwd)    CWD="$2"   ; shift 2 ;;
    --agent)  AGENT="$2" ; shift 2 ;;
    --effort) shift 2 ;;   # opencode here has no GPT/effort wiring; effort applies to pi
    --skills) shift 2 ;;
    *)        shift ;;
  esac
done
[ -n "$QF" ] || { echo "opencode.sh: --qf <question-file> required" >&2; exit 2; }

Q="$(cat "$QF")"
if [ "$RW" -eq 0 ]; then
  Q="[Read-only consult from another agent. Do NOT edit, write, create, or delete any files — answer/review only.]

$Q"
fi

# default to GPT-5.5 (opencode's openai provider) for a cross-model second opinion
MODEL="${MODEL:-openai/gpt-5.5}"
args=( run --model "$MODEL" )
[ -n "$AGENT" ] && args+=( --agent "$AGENT" )
[ -n "$CWD" ]   && args+=( --dir "$CWD" )

exec opencode "${args[@]}" "$Q"
