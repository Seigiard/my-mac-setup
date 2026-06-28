#!/usr/bin/env bash
# Split a pane, launch the pair partner there with the peer protocol injected, and wait
# until it is ready to receive. Prints the new partner pane_id on stdout.
#
#   spawn-partner.sh --agent claude|pi --proto PATH [--self PANE] [--cwd DIR] [--timeout MS]
#
# Model B (initiator-driven): the partner only ever REPLIES in its own pane; the initiator
# (claude) drives all transport. So the partner just needs the protocol injected plus its
# own normal coding tools (a pair edits files by design) — no tool restriction here.
#
# No retry on launch failure (base hard rule): a failed launch surfaces recent pane output
# and exits non-zero so the caller can hand off to the user.
#
# Probe-verified (2026-06-28, herdr 0.7.1): claude takes a real file path via
# --append-system-prompt-file; pi has no -file variant but its --append-system-prompt
# auto-reads a file path. pi/opencode are zsh FUNCTIONS, not PATH binaries, so the partner
# command is run through the pane's interactive shell (herdr pane run), never resolved with
# `command -v`.
#
# A pair edits files by design (R9), so the partner must be able to act without prompting.
# claude is launched with --permission-mode acceptEdits — otherwise it can inherit plan
# mode and refuse to do work (E2E-verified). pi gets its full default toolset already.
set -euo pipefail

AGENT="" ; PROTO="" ; SELF="${HERDR_PANE_ID:-}" ; CWD="" ; TIMEOUT=60000
while [ $# -gt 0 ]; do
  case "$1" in
    --agent)   AGENT="$2"   ; shift 2 ;;
    --proto)   PROTO="$2"   ; shift 2 ;;
    --self)    SELF="$2"    ; shift 2 ;;
    --cwd)     CWD="$2"     ; shift 2 ;;
    --timeout) TIMEOUT="$2" ; shift 2 ;;
    *) echo "spawn-partner.sh: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

command -v herdr >/dev/null || { echo "spawn-partner.sh: herdr not on PATH" >&2; exit 1; }
[ -n "$AGENT" ] || { echo "spawn-partner.sh: --agent claude|pi required" >&2; exit 2; }
[ -n "$SELF" ]  || { echo "spawn-partner.sh: no self pane (set HERDR_PANE_ID or pass --self)" >&2; exit 2; }
[ -n "$PROTO" ] || { echo "spawn-partner.sh: --proto PATH required" >&2; exit 2; }
[ -f "$PROTO" ] || { echo "spawn-partner.sh: protocol file not found: $PROTO" >&2; exit 1; }

case "$AGENT" in
  claude) PCMD="claude --permission-mode acceptEdits --append-system-prompt-file $(printf %q "$PROTO")" ;;
  pi)     PCMD="pi --append-system-prompt $(printf %q "$PROTO")" ;;
  *) echo "spawn-partner.sh: unsupported agent '$AGENT' (have: claude pi)" >&2; exit 2 ;;
esac

split_args=( "$SELF" --direction right --no-focus )
[ -n "$CWD" ] && split_args+=( --cwd "$CWD" )
PANE="$(herdr pane split "${split_args[@]}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')"
[ -n "$PANE" ] || { echo "spawn-partner.sh: failed to split a partner pane" >&2; exit 1; }

herdr pane run "$PANE" "$PCMD"

# Readiness: agent-status idle (probe-verified reliable for claude v6 and pi v2). If it
# never settles, surface recent output and fail — do not retry the spawn.
if ! herdr wait agent-status "$PANE" --status idle --timeout "$TIMEOUT" >/dev/null 2>&1; then
  echo "spawn-partner.sh: partner ($AGENT) did not reach idle within ${TIMEOUT}ms in pane $PANE:" >&2
  herdr pane read "$PANE" --source recent --lines 40 >&2 || true
  exit 1
fi

printf '%s\n' "$PANE"
