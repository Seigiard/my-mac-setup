#!/usr/bin/env bash
# Thin claude adapter for ask.sh — no flag parsing of its own. Inputs come from the
# environment (QF, RW, MODEL, CWD) set by ask.sh; --skills dirs arrive as positional
# args. claude auto-loads ~/.claude/skills + CLAUDE.md, so it keeps all its own
# skills. --effort does not apply to claude.
# Runnable standalone: QF=<file> [RW=1] [MODEL=…] [CWD=…] claude.sh [DIR…]
set -euo pipefail
: "${QF:?claude.sh: QF env var (question file) required}"

args=( -p "$(cat "$QF")" )
[ -n "${MODEL:-}" ] && args+=( --model "$MODEL" )
[ -n "${CWD:-}" ]   && args+=( --add-dir "$CWD" )
for s in "$@"; do args+=( --add-dir "$s" ); done
# read-only = allowlist read/search/web AND explicitly deny mutating tools. The deny is
# load-bearing: --allowed-tools is additive over settings.json permissions.allow (which
# may already allow Bash), so without --disallowed-tools a "read-only" consult could
# still shell out and write. Deny takes precedence over allow. rw = let it edit.
if [ "${RW:-0}" -eq 1 ]; then args+=( --permission-mode acceptEdits ); else args+=( --allowed-tools Read Grep Glob WebFetch WebSearch --disallowed-tools Bash Edit Write ); fi

exec claude "${args[@]}"
