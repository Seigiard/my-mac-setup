#!/usr/bin/env bash
# Compose a pair message and deliver it to the partner pane, verifying it was submitted,
# then record the turn in the session file.
#
#   send.sh --partner-pane P --self-role a --partner-role b --kind K --sid S \
#           --ws WS --tab TAB (--body-file F | --body TEXT) [--no-session-update]
#
# Model B: the initiator (role a, claude) sends; the partner (role b) replies in its own
# pane. The header carries peer-role labels (a/b), not agent types, so a claude<->claude
# pair stays distinguishable.
#
# Delivery is verified, not assumed: after send-text + a single Enter (probe-verified to
# submit in both claude and pi TUIs), the partner must leave idle — either it starts
# `working`, or it is already emitting its reply header. If neither happens, Enter is
# retried once; a still-undelivered message is a hard failure and the session is NOT
# updated (a failed send is not a turn).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PARTNER_PANE="" ; SELF_ROLE="" ; PARTNER_ROLE="" ; KIND="" ; SID=""
WS="" ; TAB="" ; BODY_FILE="" ; BODY="" ; NO_SESSION_UPDATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --partner-pane)      PARTNER_PANE="$2" ; shift 2 ;;
    --self-role)         SELF_ROLE="$2"    ; shift 2 ;;
    --partner-role)      PARTNER_ROLE="$2" ; shift 2 ;;
    --kind)              KIND="$2"         ; shift 2 ;;
    --sid)               SID="$2"          ; shift 2 ;;
    --ws)                WS="$2"           ; shift 2 ;;
    --tab)               TAB="$2"          ; shift 2 ;;
    --body-file)         BODY_FILE="$2"    ; shift 2 ;;
    --body)              BODY="$2"         ; shift 2 ;;
    --no-session-update) NO_SESSION_UPDATE=1 ; shift ;;
    *) echo "send.sh: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

command -v herdr >/dev/null || { echo "send.sh: herdr not on PATH" >&2; exit 1; }
# Explicit per-flag checks: bash-3.2-safe (no ${x,,}) and they name the real flag.
[ -n "$PARTNER_PANE" ] || { echo "send.sh: --partner-pane required" >&2; exit 2; }
[ -n "$SELF_ROLE" ]    || { echo "send.sh: --self-role required" >&2; exit 2; }
[ -n "$PARTNER_ROLE" ] || { echo "send.sh: --partner-role required" >&2; exit 2; }
[ -n "$KIND" ]         || { echo "send.sh: --kind required" >&2; exit 2; }
[ -n "$SID" ]          || { echo "send.sh: --sid required" >&2; exit 2; }

# Compose header + body in a temp file so quotes/$/backticks in the body survive.
MSG="$(mktemp)"
trap 'rm -f "$MSG"' EXIT
{
  printf '[pair %s -> %s kind=%s sid=%s]\n\n' "$SELF_ROLE" "$PARTNER_ROLE" "$KIND" "$SID"
  if [ -n "$BODY_FILE" ]; then
    [ -f "$BODY_FILE" ] || { echo "send.sh: --body-file not found: $BODY_FILE" >&2; exit 1; }
    cat "$BODY_FILE"
  else
    printf '%s\n' "$BODY"
  fi
} > "$MSG"

partner_status() {
  herdr pane get "$PARTNER_PANE" 2>/dev/null | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin)["result"]["pane"].get("agent_status") or "unknown")
except Exception:
    print("missing")'
}

# Delivery is proven by an agent-status TRANSITION, never by matching header text in the
# pane: the outgoing message is echoed into the partner pane, and a stale prior reply may
# still be visible, so a text match could "confirm" a non-delivery. The partner leaving
# idle (working, or already finished as done) is the real submit signal.
confirm_delivery() {
  herdr wait agent-status "$PARTNER_PANE" --status working --timeout 4000 >/dev/null 2>&1 && return 0
  case "$(partner_status)" in working|done) return 0 ;; esac
  return 1
}

# Refuse to type into a pane that is not a receptive agent (e.g. a reused bare shell) —
# otherwise the body lines would execute as shell commands.
case "$(partner_status)" in
  idle|done|working) : ;;
  *) echo "send.sh: partner pane $PARTNER_PANE is not a receptive agent; refusing to send" >&2; exit 1 ;;
esac

herdr pane send-text "$PARTNER_PANE" "$(cat "$MSG")"
herdr pane send-keys "$PARTNER_PANE" Enter
if ! confirm_delivery; then
  # Re-press Enter only if the partner is genuinely STILL idle (first Enter didn't submit).
  # If it already left idle, the message submitted and a second Enter would be a stray
  # keystroke into a now-busy agent.
  st="$(partner_status)"
  if [ "$st" = idle ]; then
    herdr pane send-keys "$PARTNER_PANE" Enter
    confirm_delivery || { echo "send.sh: message did not submit after retry" >&2; exit 1; }
  else
    echo "send.sh: could not confirm delivery (partner status: $st)" >&2; exit 1
  fi
fi

if [ "$NO_SESSION_UPDATE" -eq 0 ]; then
  [ -n "$WS" ] && [ -n "$TAB" ] || { echo "send.sh: --ws and --tab required to record the turn (or pass --no-session-update)" >&2; exit 2; }
  bash "$SCRIPT_DIR/session.sh" update --ws "$WS" --tab "$TAB" --role "$SELF_ROLE" --status "$KIND"
fi
