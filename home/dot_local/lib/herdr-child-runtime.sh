# shellcheck shell=bash
# Foundational runtime helpers for herdr-child lifecycle modules.
# Requires: entrypoint configuration globals when functions are called.
# Owns: CLI errors, JSON predicates, metadata wrappers, and runtime formatting.

usage() {
  cat >&2 <<'EOF'
Usage:
  herdr-child start --kind <claude|opencode|pi> --name <name> [options]
  herdr-child ask <question>
  herdr-child reply --to <name> --pane <pane-id> <decision>
  herdr-child prompt --to <name> --pane <pane-id> (--wait|--detach) [options] <task>
  herdr-child reap [--pane <pane-id>] <name>...

Start options:
  --posture <ro|rw>       Child tool posture (default: ro)
  --cwd <dir>             Child working directory (default: current directory)
  --model <model>         Native model selector
  --effort <level>        Pi thinking level
  --skills <dir>          Skill directory; repeatable
  --agent <name>          Opencode configured agent
  --prompt <text>         Initial task
  --prompt-file <file>    Read the initial task from a file
  --direction <right|down>
  --tab                   Launch in a new tab instead of a split pane (requires HERDR_WORKSPACE_ID)
  --label <text>          Initial tab label; valid only with --tab
  --wait                  Wait for the initial turn to settle (required mode)
  --detach                Arm detached supervision (required mode)
  --timeout <ms>          Start and prompt timeout (default: 30000)
  --supervision-timeout <ms>
                          Detached supervision deadline (default: 3600000)
EOF
}

fail_usage() {
  printf 'herdr-child: %s\n' "$1" >&2
  usage
  exit 2
}

require_herdr() {
  [ "${HERDR_ENV:-}" = "1" ] || {
    printf 'herdr-child: this command requires HERDR_ENV=1\n' >&2
    exit 1
  }
  command -v herdr >/dev/null 2>&1 || {
    printf 'herdr-child: herdr is not on PATH\n' >&2
    exit 1
  }
}

require_parent() {
  require_herdr
  [ -n "${HERDR_PANE_ID:-}" ] || {
    printf 'herdr-child: HERDR_PANE_ID is missing\n' >&2
    exit 1
  }
  [ -z "${HERDR_CHILD_PARENT_PANE:-}" ] || {
    printf 'herdr-child: this parent-side command cannot run from a child pane\n' >&2
    exit 1
  }
}

metadata_report_checked() {
  local pane="$1" expected_generation="$2" expected_terminal="$3" expected_session="$4"
  shift 4
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  python3 -c 'import fcntl, hashlib, json, os, subprocess, sys, tempfile, time
state_dir, pane, expected_generation, expected_terminal, expected_session = sys.argv[1:6]
report_args = sys.argv[6:]
clock = os.environ.get("HERDR_CHILD_TEST_NOW_SEQ")
wall = int(clock) if clock else time.time_ns() // 1000
pane_lock = os.open(os.path.join(state_dir, "metadata-" + hashlib.sha256(pane.encode()).hexdigest() + ".lock"), os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(pane_lock, fcntl.LOCK_EX)
    if expected_generation != "-":
        current = subprocess.run(["herdr", "pane", "get", pane], capture_output=True, text=True, pass_fds=(pane_lock,))
        if current.returncode != 0:
            raise SystemExit(32 if "pane_not_found" in current.stderr else 34)
        try:
            pane_data = json.loads(current.stdout).get("result", {}).get("pane", {})
            tokens = pane_data.get("tokens") or {}
            terminal = pane_data.get("terminal_id", "")
            session = pane_data.get("agent_session", {}).get("value", "")
        except (AttributeError, json.JSONDecodeError):
            raise SystemExit(34)
        if tokens.get("supervision_generation", "") != expected_generation or terminal != expected_terminal or session != expected_session:
            raise SystemExit(20)
    seq_lock = os.open(os.path.join(state_dir, "metadata-seq.lock"), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(seq_lock, fcntl.LOCK_EX)
        counter = os.path.join(state_dir, "metadata-seq")
        try:
            with open(counter, encoding="ascii") as handle:
                previous = int(handle.read())
        except FileNotFoundError:
            previous = 0
        value = max(wall, previous + 1)
        tmp_fd, tmp = tempfile.mkstemp(prefix=".metadata-seq.", dir=state_dir)
        try:
            with os.fdopen(tmp_fd, "w", encoding="ascii") as handle:
                handle.write(str(value))
            os.replace(tmp, counter)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    finally:
        os.close(seq_lock)
    result = subprocess.run(["herdr", "pane", "report-metadata", pane, *report_args, "--seq", str(value)], stdout=subprocess.DEVNULL, pass_fds=(pane_lock,))
    if result.returncode != 0:
        raise SystemExit(result.returncode)
    print(value)
finally:
    os.close(pane_lock)' "$STATE_DIR" "$pane" "$expected_generation" "$expected_terminal" "$expected_session" "$@"
}

metadata_report() {
  local pane="$1"
  shift
  metadata_report_checked "$pane" - - - "$@"
}

metadata_report_if_generation() {
  local run_dir="$1" pane="$2" generation="$3" child_terminal child_session
  shift 3
  child_terminal="$(state_value "$run_dir/launch.state" child_terminal)"
  child_session="$(state_value "$run_dir/launch.state" child_session)"
  metadata_report_checked "$pane" "$generation" "$child_terminal" "$child_session" "$@"
}

now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

atomic_write() {
  local file="$1" content="$2" dir tmp
  dir="$(dirname "$file")"
  [ -d "$dir" ] || return 1
  tmp="$(umask 077; mktemp "$dir/.write.XXXXXX" 2>/dev/null)" || return 1
  if ! printf '%s\n' "$content" > "$tmp" 2>/dev/null || ! mv "$tmp" "$file" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
}

script_path() {
  local self="$0"
  case "$self" in
    */*) ;;
    *) self="$(command -v "$self" 2>/dev/null)" ;;
  esac
  [ -n "$self" ] || return 1
  printf '%s' "$self"
}

generation_nonce() {
  local nonce
  nonce="$(LC_ALL=C od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  case "$nonce" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) printf '%s' "$nonce" ;;
    *) return 1 ;;
  esac
}

json_identity_for_pane() {
  local pane="$1"
  python3 -c 'import json,sys
pane=sys.argv[1]
agents=json.load(sys.stdin).get("result",{}).get("agents",[])
matches=[a for a in agents if a.get("pane_id")==pane]
if len(matches)!=1: raise SystemExit(1)
record=matches[0]
terminal=record.get("terminal_id","")
session=record.get("agent_session",{}).get("value","")
if not terminal: raise SystemExit(2)
print("%s\t%s" % (terminal,session))' "$pane"
}

json_agent_snapshot() {
  python3 -c 'import json,sys
try:
 agent=json.load(sys.stdin).get("result",{}).get("agent",{})
 status=agent["agent_status"]
 seq=agent["state_change_seq"]
 terminal=agent["terminal_id"]
 session=agent.get("agent_session",{}).get("value","")
 pane=agent["pane_id"]
 name=agent.get("name","")
 if status not in ("idle","working","blocked","done","unknown") or not isinstance(seq,int) or not terminal or not session or not pane:
  raise ValueError()
except Exception:
 raise SystemExit(1)
print("%s\t%s\t%s\t%s\t%s\t%s" % (status,seq,terminal,session,name,pane))'
}

json_generation_status() {
  local generation="$1" terminal="$2" session="$3"
  python3 -c 'import json,sys
generation,terminal,session=sys.argv[1:4]
try:
 pane=json.load(sys.stdin).get("result",{}).get("pane",{})
 tokens=pane.get("tokens") or {}
 current=tokens.get("supervision_generation","")
 pane_terminal=pane.get("terminal_id","")
 pane_session=pane.get("agent_session",{}).get("value","")
except Exception:
 raise SystemExit(4)
if current != generation:
 raise SystemExit(3)
if pane_terminal != terminal or pane_session != session:
 raise SystemExit(2)' "$generation" "$terminal" "$session"
}

json_resolve_parent() {
  local terminal="$1" session="$2"
  python3 -c 'import json,sys
terminal,session=sys.argv[1:3]
try:
 agents=json.load(sys.stdin).get("result",{}).get("agents",[])
except Exception:
 raise SystemExit(4)
terminal_matches=[a for a in agents if a.get("terminal_id")==terminal]
if not terminal_matches:
 raise SystemExit(3)
matches=[a for a in terminal_matches if a.get("agent_session",{}).get("value","")==session]
if len(matches)!=1:
 raise SystemExit(2)
pane=matches[0].get("pane_id","")
status=matches[0].get("agent_status","unknown")
if not pane:
 raise SystemExit(4)
print("%s\t%s" % (pane,status))' "$terminal" "$session"
}

json_child_context() {
  python3 -c 'import json,sys
try:
 pane=json.load(sys.stdin).get("result",{}).get("pane",{})
 tokens=pane.get("tokens") or {}
 values=(pane.get("terminal_id",""),pane.get("agent_session",{}).get("value",""),
         tokens.get("child_mode",""),tokens.get("supervision_generation",""),
         tokens.get("supervision_timeout",""),tokens.get("parent_terminal",""),
         tokens.get("parent_session",""),tokens.get("child_terminal",""),
         tokens.get("child_session",""))
except Exception:
 raise SystemExit(1)
print("\t".join(str(value) for value in values))'
}

json_tab_identity() {
  python3 -c 'import json,sys
try:
 result=json.load(sys.stdin)["result"]
 pane=result["root_pane"]["pane_id"]
 terminal=result["root_pane"]["terminal_id"]
 tab=result["tab"]["tab_id"]
 if not pane or not terminal or not tab: raise ValueError()
 print("%s\t%s" % (pane,tab))
except Exception:
 raise SystemExit(1)'
}

json_created_tab_hint() {
  python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("result",{}).get("tab",{}).get("tab_id") or "unknown")
except Exception: print("unknown")'
}

state_value() {
  local file="$1" key="$2"
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -1
}

supervision_reason() {
  local file="$1" reason
  reason="$(state_value "$file" reason)"
  [ -n "$reason" ] || reason="watcher-unavailable"
  printf '%s' "$reason"
}

print_supervision_failure() {
  local name="$1" pane="$2" generation="$3" reason="$4" diagnostic="$5"
  printf '{"agent":"%s","pane":"%s","supervision":{"status":"failed","reason":"%s","generation":"%s","diagnostic":"%s"}}\n' \
    "$name" "$pane" "$reason" "$generation" "$diagnostic"
}

print_supervision_uncertain() {
  local name="$1" pane="$2" generation="$3" reason="$4"
  printf '{"agent":"%s","pane":"%s","supervision":{"status":"uncertain","reason":"%s","generation":"%s","diagnostic":"%s"}}\n' \
    "$name" "$pane" "$reason" "$generation" "$generation"
}

print_start_result() {
  local name="$1" pane="$2" tab="$3" generation="${4:-}" timeout="${5:-}"
  if [ -n "$generation" ]; then
    if [ -n "$tab" ]; then
      printf '{"agent":"%s","pane":"%s","tab":"%s","supervision":{"status":"armed","generation":"%s","timeout_ms":%s}}\n' \
        "$name" "$pane" "$tab" "$generation" "$timeout"
    else
      printf '{"agent":"%s","pane":"%s","supervision":{"status":"armed","generation":"%s","timeout_ms":%s}}\n' \
        "$name" "$pane" "$generation" "$timeout"
    fi
  elif [ -n "$tab" ]; then
    printf '{"agent":"%s","pane":"%s","tab":"%s"}\n' "$name" "$pane" "$tab"
  else
    printf '{"agent":"%s","pane":"%s"}\n' "$name" "$pane"
  fi
}

json_has_name() {
  local name="$1"
  python3 -c 'import json,sys
name=sys.argv[1]
data=json.load(sys.stdin)
agents=data.get("result",{}).get("agents",[])
raise SystemExit(0 if any(a.get("name")==name for a in agents) else 1)' "$name"
}

json_has_pair() {
  local name="$1" pane="$2"
  python3 -c 'import json,sys
name,pane=sys.argv[1:3]
data=json.load(sys.stdin)
agents=data.get("result",{}).get("agents",[])
raise SystemExit(0 if any(a.get("name")==name and a.get("pane_id")==pane for a in agents) else 1)' "$name" "$pane"
}

# Prints "kept:<pane_count>" while a tab exists, "gone" when it does not,
# and "unknown" when Herdr cannot determine its state.
tab_reap_status() {
  local tab_id="$1" err json status
  err="$(mktemp)"
  set +e
  json="$(herdr tab get "$tab_id" 2>"$err")"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    printf 'kept:%s' "$(printf '%s' "$json" | python3 -c 'import json,sys
try:
 print(json.load(sys.stdin).get("result",{}).get("tab",{}).get("pane_count","?"))
except Exception:
 print("?")')"
  elif grep -q '"code":"tab_not_found"' "$err"; then
    printf 'gone'
  else
    printf 'unknown'
  fi
  rm -f "$err"
}
