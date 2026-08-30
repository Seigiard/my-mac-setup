# shellcheck shell=bash
# Requires: runtime, supervision, and entrypoint configuration globals.
# Owns: settled-child selection, pane cleanup, and reap transitions.

reap_children() {
  require_parent
  local expected_pane=""
  if [ "${1:-}" = "--pane" ]; then
    [ $# -ge 3 ] || fail_usage 'reap --pane requires a pane ID and child name'
    expected_pane="$2"
    [ -n "$expected_pane" ] || fail_usage 'reap --pane requires a non-empty pane ID'
    shift 2
    [ $# -eq 1 ] || fail_usage 'reap --pane accepts exactly one child name'
  fi
  [ $# -gt 0 ] || fail_usage 'reap requires at least one child name'
  local list_json name record pane status focused pane_json label_status fresh_list_json fresh_status
  local generation own_tab child_tab close_err tab_state metadata reap_transition
  list_json="$(herdr agent list)" || { printf 'herdr-child: could not list children\n' >&2; exit 1; }

  for name in "$@"; do
    set +e
    record="$(printf '%s' "$list_json" | python3 -c 'import json,sys
try:
 data=json.load(sys.stdin)
except Exception:
 raise SystemExit(2)
name=sys.argv[1]
agents=data.get("result",{}).get("agents",[])
match=next((a for a in agents if a.get("name")==name), None)
if match is None:
 raise SystemExit(1)
print("%s\t%s\t%s" % (match.get("pane_id",""), match.get("agent_status","unknown"), str(bool(match.get("focused"))).lower()))' "$name")"
    fresh_status=$?
    set -e
    case "$fresh_status" in
      0) ;;
      1) printf '%s: skipped; no live agent has this name\n' "$name"; continue ;;
      *) printf '%s: kept; live agent state could not be parsed\n' "$name"; continue ;;
    esac
    IFS=$'\t' read -r pane status focused <<< "$record"
    if [ -n "$expected_pane" ] && [ "$pane" != "$expected_pane" ]; then
      printf '%s: kept; expected pane %s, current pane is %s\n' "$name" "$expected_pane" "$pane"
      continue
    fi
    case "$status" in
      done|idle) ;;
      *) printf '%s: kept; status is %s\n' "$name" "$status"; continue ;;
    esac
    if [ "$focused" = true ]; then
      printf '%s: kept; pane %s is focused\n' "$name" "$pane"
      continue
    fi
    pane_json="$(herdr pane get "$pane")" || {
      printf '%s: kept; pane metadata could not be read\n' "$name"
      continue
    }
    set +e
    printf '%s' "$pane_json" | python3 -c 'import json,sys
try:
 pane=json.load(sys.stdin).get("result",{}).get("pane",{})
except Exception:
 raise SystemExit(2)
labels=pane.get("state_labels")
if labels is None or labels == {}:
 raise SystemExit(1)
if isinstance(labels, dict):
 blocking=[key for key in labels if key not in ("supervised","supervision failed")]
 raise SystemExit(0 if blocking else 1)
raise SystemExit(2)'
    label_status=$?
    set -e
    case "$label_status" in
      0) printf '%s: kept; pane %s has a waiting state label\n' "$name" "$pane"; continue ;;
      1) ;;
      *) printf '%s: kept; pane metadata could not be read\n' "$name"; continue ;;
    esac
    fresh_list_json="$(herdr agent list)" || {
      printf '%s: kept; live agent state could not be read\n' "$name"
      continue
    }
    set +e
    printf '%s' "$fresh_list_json" | python3 -c 'import json,sys
try:
 data=json.load(sys.stdin)
except Exception:
 raise SystemExit(2)
name,pane=sys.argv[1:3]
agents=data.get("result",{}).get("agents",[])
match=next((a for a in agents if a.get("name")==name and a.get("pane_id")==pane), None)
if match is None:
 raise SystemExit(1)
status=match.get("agent_status","unknown")
focused=str(bool(match.get("focused"))).lower()
if status not in ("done","idle"):
 raise SystemExit(3)
if focused == "true":
 raise SystemExit(4)' "$name" "$pane"
    fresh_status=$?
    set -e
    case "$fresh_status" in
      0) ;;
      1) printf '%s: kept; child name and pane no longer identify the same live agent\n' "$name"; continue ;;
      2) printf '%s: kept; live agent state could not be parsed\n' "$name"; continue ;;
      3) printf '%s: kept; current status is not settled\n' "$name"; continue ;;
      4) printf '%s: kept; pane %s is now focused\n' "$name" "$pane"; continue ;;
      *) printf '%s: kept; live agent state could not be read\n' "$name"; continue ;;
    esac
    metadata="$(printf '%s' "$pane_json" | python3 -c 'import json,sys
try:
 pane=json.load(sys.stdin).get("result",{}).get("pane",{})
 tokens=pane.get("tokens") or {}
 print("%s\t%s\t%s" % (tokens.get("supervision_generation") or "-", pane.get("tab_id") or "-", tokens.get("child-tab") or "-"))
except Exception:
 raise SystemExit(1)' 2>/dev/null)" || {
      printf '%s: kept; supervision metadata could not be parsed\n' "$name"
      continue
    }
    IFS=$'\t' read -r generation own_tab child_tab <<< "$metadata"
    [ "$generation" != - ] || generation=""
    [ "$own_tab" != - ] || own_tab=""
    [ "$child_tab" != - ] || child_tab=""
    if [ -n "$child_tab" ] && [ "$child_tab" != "$own_tab" ]; then
      printf '%s: kept; pane %s tab ownership is ambiguous\n' "$name" "$pane"
      continue
    fi
    reap_transition="none"
    if [ -n "$generation" ]; then
      set +e
      begin_reap_invalidation "$generation"
      local reap_status=$?
      set -e
      if [ "$reap_status" -eq 1 ]; then
        printf '%s: kept; supervision generation could not be invalidated\n' "$name"
        continue
      fi
      if [ "$reap_status" -eq 0 ]; then
        reap_transition="pending"
        if [ -n "${HERDR_CHILD_TEST_REAP_INVALIDATED_BARRIER:-}" ]; then
          local barrier_hold_started="$SECONDS"
          : > "$HERDR_CHILD_TEST_REAP_INVALIDATED_BARRIER.ready"
          while [ ! -e "$HERDR_CHILD_TEST_REAP_INVALIDATED_BARRIER.release" ]; do
            if watcher_hold_expired "$barrier_hold_started"; then
              signal_reap_transition "$generation" restore || true
              stop_reap_owner_guard "$STATE_DIR/runs/$generation"
              return 1
            fi
            sleep 0.01
          done
        fi
      fi
    fi
    close_err="$(mktemp)"
    if herdr pane close "$pane" >/dev/null 2>"$close_err"; then
      [ "$reap_transition" != pending ] || signal_reap_transition "$generation" closed || true
      if [ -z "$child_tab" ]; then
        printf '%s: closed pane %s\n' "$name" "$pane"
      else
        tab_state="$(tab_reap_status "$child_tab")"
        case "$tab_state" in
          kept:*) printf '%s: closed pane %s; tab %s kept with %s panes\n' "$name" "$pane" "$child_tab" "${tab_state#kept:}" ;;
          gone) printf '%s: closed pane %s and tab %s\n' "$name" "$pane" "$child_tab" ;;
          *) printf '%s: closed pane %s; tab %s status could not be confirmed\n' "$name" "$pane" "$child_tab" ;;
        esac
      fi
    elif [ -n "$child_tab" ] && grep -q '"code":"pane_not_found"' "$close_err"; then
      [ "$reap_transition" != pending ] || signal_reap_transition "$generation" closed || true
      tab_state="$(tab_reap_status "$child_tab")"
      case "$tab_state" in
        kept:*) printf '%s: kept; pane %s already gone but tab %s still has %s panes\n' "$name" "$pane" "$child_tab" "${tab_state#kept:}" ;;
        gone) printf '%s: already cleaned; pane %s and tab %s are gone\n' "$name" "$pane" "$child_tab" ;;
        *) printf '%s: already cleaned; pane %s is gone, tab %s status could not be confirmed\n' "$name" "$pane" "$child_tab" ;;
      esac
    else
      if [ "$reap_transition" = pending ] && signal_reap_transition "$generation" restore; then
        printf '%s: kept; pane %s could not be closed; supervision recovery requested\n' "$name" "$pane"
      elif [ -n "$generation" ] && publish_reap_recovery "$pane" "$generation"; then
        printf '%s: kept; pane %s could not be closed; supervision is recoverable through managed prompt or reap\n' "$name" "$pane"
      else
        printf '%s: kept; pane %s could not be closed; supervision recovery could not be published\n' "$name" "$pane"
      fi
    fi
    [ "$reap_transition" != pending ] || stop_reap_owner_guard "$STATE_DIR/runs/$generation"
    rm -f "$close_err"
  done
}
