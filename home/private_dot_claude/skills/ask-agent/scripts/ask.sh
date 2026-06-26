#!/usr/bin/env bash
# ask another agent a one-shot question and return its answer.
#
#   ask.sh <claude|opencode|pi> "<question>" [--rw] [--model M] [--effort L] \
#          [--cwd DIR] [--skills DIR]... [--agent NAME] [--headless]
#
# pi defaults to the latest GPT (openai-codex/gpt-5.5) at --effort medium — a genuine
# cross-model second opinion. claude/opencode use their own model; --effort
# applies to pi only.
#
# Mode is auto-detected: inside herdr (HERDR_ENV=1) the consult runs in a visible
# herdr pane beside you (you watch it live, the pane stays for follow-up) and its
# output is captured back here. Outside herdr it runs as a headless subprocess.
# --headless forces the subprocess path even inside herdr.
#
# Default is a READ-ONLY consult (the asked agent answers but does not edit files);
# pass --rw to allow edits. Each agent keeps all of its own skills.
set -euo pipefail

[ $# -ge 2 ] || { sed -n '2,17p' "$0"; exit 2; }
AGENT="$1" ; Q="$2" ; shift 2

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/agents/$AGENT.sh"
[ -f "$SCRIPT" ] || { echo "ask.sh: unknown agent '$AGENT' (have: claude opencode pi)" >&2; exit 2; }

HEADLESS=0 ; PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --headless)                  HEADLESS=1            ; shift   ;;
    --rw)                        PASS+=( --rw )        ; shift   ;;
    --model|--effort|--cwd|--skills|--agent) PASS+=( "$1" "$2" ); shift 2 ;;
    *) echo "ask.sh: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

QF="$(mktemp)" ; printf '%s' "$Q" > "$QF"
trap 'rm -f "$QF"' EXIT

if [ "${HERDR_ENV:-}" = "1" ] && [ "$HEADLESS" -eq 0 ]; then
  command -v herdr >/dev/null || { echo "ask.sh: HERDR_ENV set but herdr not on PATH" >&2; exit 1; }
  OUT="$(mktemp)"
  MARK="ASKEND$$"             # completion marker we wait on
  ESC="ASK''${MARK#ASK}"     # same text, quote-broken, so the typed command line
                              # never matches MARK — only the printed line does
  PANE="$(herdr pane split "$HERDR_PANE_ID" --direction right --no-focus \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')"
  herdr pane run "$PANE" "bash '$SCRIPT' --qf '$QF' ${PASS[*]+${PASS[*]}} 2>&1 | tee '$OUT'; printf '%s\\n' '$ESC'"
  herdr wait output "$PANE" --match "$MARK" --timeout 1800000 >/dev/null || true
  cat "$OUT"
  rm -f "$OUT"
  echo "ask.sh: consult ran in herdr pane $PANE (left open for follow-up; close with: herdr pane close $PANE)" >&2
else
  bash "$SCRIPT" --qf "$QF" ${PASS[@]+"${PASS[@]}"}
fi
