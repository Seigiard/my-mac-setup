#!/usr/bin/env bash
# Thin opencode adapter for ask.sh — no flag parsing of its own. Inputs come from
# the environment (QF, RW, MODEL, CWD, AGENT_NAME) set by ask.sh. opencode loads its
# own config/agents (all its skills); it has no --skill flag, so read-only is
# enforced via prompt framing and --skills dirs (positional args) are ignored.
# --effort does not apply here.
# Runnable standalone: QF=<file> [RW=1] [MODEL=…] [CWD=…] [AGENT_NAME=…] opencode.sh
set -euo pipefail
: "${QF:?opencode.sh: QF env var (question file) required}"

Q="$(cat "$QF")"
if [ "${RW:-0}" -eq 0 ]; then
  echo "ask.sh: opencode read-only is prompt-enforced only (not a hard tool block); for a hard guarantee configure a read-only --agent" >&2
  Q="[Read-only consult from another agent. Do NOT edit, write, create, or delete any files — answer/review only.]

$Q"
fi

# default to GPT-5.5 (opencode's openai provider) for a cross-model second opinion
MODEL="${MODEL:-openai/gpt-5.5}"
args=( run --model "$MODEL" )
[ -n "${AGENT_NAME:-}" ] && args+=( --agent "$AGENT_NAME" )
[ -n "${CWD:-}" ]       && args+=( --dir "$CWD" )

exec opencode "${args[@]}" "$Q"
