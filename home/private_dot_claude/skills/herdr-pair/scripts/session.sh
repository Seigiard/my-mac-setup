#!/usr/bin/env bash
# Atomic per-(workspace, tab) session state for the herdr-pair skill.
#
#   session.sh create --ws WS --tab TAB [--sid SID] \
#       --a-agent T --a-pane P --b-agent T --b-pane P
#   session.sh get    --ws WS --tab TAB
#   session.sh update --ws WS --tab TAB --role a|b --status KIND [--no-progress inc|reset]
#   session.sh trash  --ws WS --tab TAB    # remove only this tab's session dir (on close)
#
# Roles are peer labels (a = initiator, b = partner), decoupled from agent type so a
# claude<->claude pair (identical `agent` field) stays distinguishable. State lives at
# $HERDR_COWORKERS_DIR/<ws>/<tab_slug>/session.json, tab_slug flattening ':' to '_'.
# Two agents race on this file, so every write goes through a temp file + os.replace.
set -euo pipefail

: "${HERDR_COWORKERS_DIR:=$HOME/.herdr-coworkers}"

usage() {
  echo "usage: session.sh create|get|update --ws WS --tab TAB [...]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
CMD="$1"; shift

WS="" ; TAB="" ; SID="" ; ROLE="" ; STATUS="" ; NO_PROGRESS=""
A_AGENT="" ; A_PANE="" ; B_AGENT="" ; B_PANE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ws)          WS="$2"          ; shift 2 ;;
    --tab)         TAB="$2"         ; shift 2 ;;
    --sid)         SID="$2"         ; shift 2 ;;
    --role)        ROLE="$2"        ; shift 2 ;;
    --status)      STATUS="$2"      ; shift 2 ;;
    --no-progress) NO_PROGRESS="$2" ; shift 2 ;;
    --a-agent)     A_AGENT="$2"     ; shift 2 ;;
    --a-pane)      A_PANE="$2"      ; shift 2 ;;
    --b-agent)     B_AGENT="$2"     ; shift 2 ;;
    --b-pane)      B_PANE="$2"      ; shift 2 ;;
    *) echo "session.sh: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$WS" ]  || { echo "session.sh: --ws required" >&2; exit 2; }
[ -n "$TAB" ] || { echo "session.sh: --tab required" >&2; exit 2; }

# WS/TAB build a filesystem path (and `trash` rm -rf's it), so reject anything that could
# escape the store. herdr ids are opaque (e.g. wB, wB:tX) and never contain these; a value
# that does is malformed, not a path to honor. The `:`->`_` slug below cannot introduce a
# '/', so checking the raw values here is sufficient.
for part in "$WS" "$TAB"; do
  case "$part" in
    */* | *..* | -*) echo "session.sh: invalid --ws/--tab value '$part' (no '/', '..', or leading '-')" >&2; exit 2 ;;
  esac
done

TAB_SLUG="${TAB//:/_}"
SESSION_DIR="$HERDR_COWORKERS_DIR/$WS/$TAB_SLUG"
SESSION_FILE="$SESSION_DIR/session.json"

case "$CMD" in
  create)
    for v in A_AGENT A_PANE B_AGENT B_PANE; do
      [ -n "${!v}" ] || { echo "session.sh: create requires --a-agent/--a-pane/--b-agent/--b-pane" >&2; exit 2; }
    done
    if [ -e "$SESSION_FILE" ]; then
      echo "session.sh: session already exists for this tab: $SESSION_FILE (resume or remove it)" >&2
      exit 1
    fi
    [ -n "$SID" ] || SID="$(date +%s)-$(openssl rand -hex 2 2>/dev/null || printf '%04x' "$RANDOM")"
    mkdir -p "$SESSION_DIR"
    CREATED_AT="$(date -u +%FT%TZ)"
    SID="$SID" WS="$WS" TAB="$TAB" \
      A_AGENT="$A_AGENT" A_PANE="$A_PANE" B_AGENT="$B_AGENT" B_PANE="$B_PANE" \
      CREATED_AT="$CREATED_AT" TMP="$SESSION_FILE.tmp.$$" FINAL="$SESSION_FILE" \
      python3 - <<'PY'
import json, os
s = {
    "sid": os.environ["SID"],
    "workspace_id": os.environ["WS"],
    "tab_id": os.environ["TAB"],
    "roles": {
        "a": {"agent_type": os.environ["A_AGENT"], "pane_id": os.environ["A_PANE"]},
        "b": {"agent_type": os.environ["B_AGENT"], "pane_id": os.environ["B_PANE"]},
    },
    "round": 0,
    "last_status": {"a": None, "b": None},
    "no_progress_count": 0,
    "workbench": {"tab_id": None, "server_pane": None, "logs_pane": None},
    "created_at": os.environ["CREATED_AT"],
}
tmp = os.environ["TMP"]
with open(tmp, "w") as f:
    json.dump(s, f, indent=2)
os.replace(tmp, os.environ["FINAL"])
PY
    printf '%s\n' "$SID"
    ;;

  get)
    [ -f "$SESSION_FILE" ] || { echo "session.sh: no session for this tab: $SESSION_FILE" >&2; exit 1; }
    cat "$SESSION_FILE"
    ;;

  update)
    [ -n "$ROLE" ]   || { echo "session.sh: update requires --role a|b" >&2; exit 2; }
    [ "$ROLE" = a ] || [ "$ROLE" = b ] || { echo "session.sh: --role must be 'a' or 'b'" >&2; exit 2; }
    [ -n "$STATUS" ] || { echo "session.sh: update requires --status KIND" >&2; exit 2; }
    if [ -n "$NO_PROGRESS" ] && [ "$NO_PROGRESS" != inc ] && [ "$NO_PROGRESS" != reset ]; then
      echo "session.sh: --no-progress must be 'inc' or 'reset'" >&2; exit 2
    fi
    [ -f "$SESSION_FILE" ] || { echo "session.sh: no session for this tab: $SESSION_FILE" >&2; exit 1; }
    ROLE="$ROLE" STATUS="$STATUS" NO_PROGRESS="$NO_PROGRESS" \
      TMP="$SESSION_FILE.tmp.$$" FINAL="$SESSION_FILE" \
      python3 - <<'PY'
import json, os
final = os.environ["FINAL"]
with open(final) as f:
    s = json.load(f)
s["round"] = s.get("round", 0) + 1
s.setdefault("last_status", {})[os.environ["ROLE"]] = os.environ["STATUS"]
np = os.environ["NO_PROGRESS"]
if np == "inc":
    s["no_progress_count"] = s.get("no_progress_count", 0) + 1
elif np == "reset":
    s["no_progress_count"] = 0
tmp = os.environ["TMP"]
with open(tmp, "w") as f:
    json.dump(s, f, indent=2)
os.replace(tmp, final)
PY
    ;;

  trash)
    # Remove only this tab's session dir. Guard the computed path so a bad WS/TAB can
    # never widen the delete to the store root or above it.
    case "$SESSION_DIR" in
      "$HERDR_COWORKERS_DIR"/*/*) : ;;
      *) echo "session.sh: refusing to trash unexpected path: $SESSION_DIR" >&2; exit 1 ;;
    esac
    rm -rf "$SESSION_DIR"
    ;;

  *) echo "session.sh: unknown subcommand '$CMD' (have: create get update trash)" >&2; exit 2 ;;
esac
