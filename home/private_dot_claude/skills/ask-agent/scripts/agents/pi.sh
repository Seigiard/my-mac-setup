#!/usr/bin/env bash
# Run a one-shot pi consult. Invoked by ask.sh; runnable standalone.
# pi auto-discovers its own skills (kept on). --skills maps to pi's --skill flag.
set -euo pipefail

QF="" ; RW=0 ; MODEL="" ; EFFORT="" ; CWD="" ; SKILLS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --qf)     QF="$2"      ; shift 2 ;;
    --rw)     RW=1         ; shift   ;;
    --model)  MODEL="$2"   ; shift 2 ;;
    --effort) EFFORT="$2"  ; shift 2 ;;
    --cwd)    CWD="$2"     ; shift 2 ;;
    --skills) SKILLS+=("$2"); shift 2 ;;
    *)        shift ;;
  esac
done
[ -n "$QF" ] || { echo "pi.sh: --qf <question-file> required" >&2; exit 2; }

# default to the latest GPT (different model family than claude) at medium effort.
# fully-qualified provider/model — bare "gpt-5.5" mis-resolves to an unauthed provider.
MODEL="${MODEL:-openai-codex/gpt-5.5}"
EFFORT="${EFFORT:-medium}"
args=( -p --model "$MODEL" --thinking "$EFFORT" )
for s in ${SKILLS[@]+"${SKILLS[@]}"}; do args+=( --skill "$s" ); done
# read-only = allowlist pi's read/search tools (no bash/edit/write, so it truly cannot mutate).
# pi has no built-in web tool; web is only available via an extension (e.g. pi-agent-browser).
[ "$RW" -eq 0 ] && args+=( --tools read,grep,find,ls )
[ -n "$CWD" ] && cd "$CWD"

exec pi "${args[@]}" "$(cat "$QF")"
