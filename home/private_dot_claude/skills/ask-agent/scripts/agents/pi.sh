#!/usr/bin/env bash
# Thin pi adapter for ask.sh — no flag parsing of its own. Inputs come from the
# environment (QF, RW, MODEL, EFFORT, CWD) set by ask.sh; --skills dirs arrive as
# positional args and map to pi's --skill flag. pi auto-discovers its own skills.
# Runnable standalone: QF=<file> [RW=1] [MODEL=…] [EFFORT=…] [CWD=…] pi.sh [SKILL…]
set -euo pipefail
: "${QF:?pi.sh: QF env var (question file) required}"

# default to the latest GPT (different model family than claude) at medium effort.
# fully-qualified provider/model — bare "gpt-5.5" mis-resolves to an unauthed provider.
MODEL="${MODEL:-openai-codex/gpt-5.5}"
EFFORT="${EFFORT:-medium}"
args=( -p --model "$MODEL" --thinking "$EFFORT" )
for s in "$@"; do args+=( --skill "$s" ); done
# read-only = allowlist pi's read/search tools (no bash/edit/write, so it truly cannot mutate).
# pi has no built-in web tool; web is only available via an extension (e.g. pi-agent-browser).
[ "${RW:-0}" -eq 0 ] && args+=( --tools read,grep,find,ls )
[ -n "${CWD:-}" ] && cd "$CWD"

exec pi "${args[@]}" "$(cat "$QF")"
