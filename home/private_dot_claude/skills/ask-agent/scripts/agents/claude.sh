#!/usr/bin/env bash
# Run a one-shot claude consult. Invoked by ask.sh; runnable standalone.
# claude auto-loads ~/.claude/skills + CLAUDE.md, so it keeps all its own skills.
set -euo pipefail

QF="" ; RW=0 ; MODEL="" ; CWD="" ; SKILLS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --qf)     QF="$2"      ; shift 2 ;;
    --rw)     RW=1         ; shift   ;;
    --model)  MODEL="$2"   ; shift 2 ;;
    --effort) shift 2 ;;   # claude -p has no clean effort flag; effort applies to pi
    --cwd)    CWD="$2"     ; shift 2 ;;
    --skills) SKILLS+=("$2"); shift 2 ;;
    *)        shift ;;
  esac
done
[ -n "$QF" ] || { echo "claude.sh: --qf <question-file> required" >&2; exit 2; }

args=( -p "$(cat "$QF")" )
[ -n "$MODEL" ] && args+=( --model "$MODEL" )
[ -n "$CWD" ]   && args+=( --add-dir "$CWD" )
for s in ${SKILLS[@]+"${SKILLS[@]}"}; do args+=( --add-dir "$s" ); done
# read-only = allowlist read/search/web tools (blocks Bash/Edit/Write); rw = let it edit
if [ "$RW" -eq 1 ]; then args+=( --permission-mode acceptEdits ); else args+=( --allowed-tools Read Grep Glob WebFetch WebSearch ); fi

exec claude "${args[@]}"
