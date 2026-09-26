#!/usr/bin/env bash
# post-apply: 18 host-safe
# Public contract tests for the read-only Herdr resource-tree CLI.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/common'

TREE_CLI="$SOURCE_ROOT/dot_local/bin/executable_herdr-resource-tree"
HERDR_WRAPPER="$SOURCE_ROOT/dot_local/bin/executable_herdr"
HERDR_CHILD="$SOURCE_ROOT/dot_local/bin/executable_herdr-child"
HRC_OPENCODE_PLUGIN="$SOURCE_ROOT/private_dot_config/opencode/plugins/herdr-resource-context.ts"

setup() {
  TREE_WORK="$BATS_TEST_TMPDIR/resource-tree"
  TREE_BIN="$TREE_WORK/bin"
  TREE_CALLS="$TREE_WORK/herdr.calls"
  TREE_SERVER_PID=""
  TREE_SERVER_EXIT=""
  TREE_LIVE_PANE=""
  TREE_LIVE_TERMINAL=""
  TREE_LIVE_TAB=""
  TREE_LIVE_WORKSPACE=""
  TREE_LIVE_HERDR=""
  mkdir -p "$TREE_BIN"
  : > "$TREE_WORK/herdr.sock"

  cat > "$TREE_WORK/run-bounded" <<'PY'
#!/usr/bin/env python3
import os
import signal
import subprocess
import sys

process = subprocess.Popen(
    sys.argv[1:],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    start_new_session=True,
)
try:
    stdout, stderr = process.communicate(timeout=40)
except subprocess.TimeoutExpired:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        stdout, stderr = process.communicate(timeout=1)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, stderr = process.communicate()
    sys.stdout.buffer.write(stdout)
    sys.stderr.buffer.write(stderr)
    raise SystemExit(124)
sys.stdout.buffer.write(stdout)
sys.stderr.buffer.write(stderr)
if process.returncode < 0:
    raise SystemExit(128 - process.returncode)
raise SystemExit(process.returncode)
PY
  chmod +x "$TREE_WORK/run-bounded"

  cat > "$TREE_WORK/snapshot.json" <<'JSON'
{"id":"cli:api:snapshot","result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"workspaces":[{"workspace_id":"w2","number":2,"label":"Unrelated"},{"workspace_id":"w1","number":1,"label":"Project"}],"tabs":[{"workspace_id":"w2","tab_id":"w2:t1","number":1,"label":"Elsewhere"},{"workspace_id":"w1","tab_id":"w1:t2","number":2,"label":"Shells"},{"workspace_id":"w1","tab_id":"w1:t1","number":1,"label":"Agents"}],"panes":[{"workspace_id":"w1","tab_id":"w1:t2","pane_id":"w1:p2","label":"logs","terminal_id":"term-2"},{"workspace_id":"w2","tab_id":"w2:t1","pane_id":"w2:p1","label":"manual","terminal_id":"term-3"},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","label":"implementation","terminal_id":"term-1"}],"agents":[{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","terminal_id":"term-1","agent":"opencode","name":"red-fox","agent_session":{"agent":"opencode","kind":"id","source":"herdr:opencode","value":"session-1"}},{"workspace_id":"w2","tab_id":"w2:t1","pane_id":"w2:p1","terminal_id":"term-3","agent":"claude","name":"blue-whale"}]}}}
JSON

  cat > "$TREE_BIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TREE_CALLS"
case "${TREE_STUB_MODE:-valid}" in
  valid)
    cat "$TREE_SNAPSHOT"
    ;;
  failed)
    printf 'socket unavailable\n' >&2
    exit 23
    ;;
  malformed)
    printf '{"result":{"type":"session_snapshot","snapshot":{"workspaces":[]}}}\n'
    ;;
  hanging)
    (
      trap '' TERM
      while :; do sleep 30; done
    ) &
    printf '%s\n' "$!" > "$TREE_DESCENDANT_PID"
    trap '' TERM
    while :; do sleep 30; done
    ;;
  scope-changing)
    : > "$TREE_SNAPSHOT_READY"
    for _ in {1..1000}; do
      [[ -e "$TREE_SNAPSHOT_RELEASE" ]] && break
      sleep 0.01
    done
    [[ -e "$TREE_SNAPSHOT_RELEASE" ]] || exit 124
    cat "$TREE_SNAPSHOT"
    ;;
esac
SH
  chmod +x "$TREE_BIN/herdr"
}

tree_stub_run() {
  # Pin every host-supplied input this fixture depends on. A developer shell
  # inside Herdr exports HERDR_BIN_PATH and an XDG state home of its own, and
  # inheriting either points the CLI at the real server and the real registry.
  env PATH="$TREE_BIN:$PATH" TREE_CALLS="$TREE_CALLS" \
    HERDR_BIN_PATH="$TREE_BIN/herdr" \
    HERDR_SOCKET_PATH="$TREE_WORK/herdr.sock" \
    HERDR_RESOURCE_TREE_STATE_DIR="${HERDR_RESOURCE_TREE_STATE_DIR:-$TREE_WORK/state}" \
    TREE_SNAPSHOT="$TREE_WORK/snapshot.json" \
    TREE_DESCENDANT_PID="${TREE_DESCENDANT_PID:-}" \
    TREE_SNAPSHOT_READY="${TREE_SNAPSHOT_READY:-}" \
    TREE_SNAPSHOT_RELEASE="${TREE_SNAPSHOT_RELEASE:-}" \
    TREE_STUB_MODE="${TREE_STUB_MODE:-valid}" "$TREE_CLI" "$@"
}

tree_install_managed_creation_stub() {
  # These fixtures emulate Herdr 0.9.0/protocol 22. Tests 003 and 004 compare
  # the resource/session fields consumed below against the installed binary.
  cat > "$TREE_WORK/caller.json" <<'JSON'
{"id":"cli:pane:current","result":{"type":"pane_current","pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","terminal_id":"term-1","agent":"opencode","agent_session":{"agent":"opencode","kind":"id","source":"herdr:opencode","value":"session-caller"}}}}
JSON
  cat > "$TREE_WORK/split.json" <<'JSON'
{"id":"cli:pane:split","result":{"type":"pane_split","pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p3","terminal_id":"term-4","focused":false,"agent_status":"unknown","revision":1}}}
JSON
  cat > "$TREE_WORK/tab.json" <<'JSON'
{"id":"cli:tab:create","result":{"type":"tab_created","tab":{"workspace_id":"w1","tab_id":"w1:t2","number":2,"label":null,"focused":false,"pane_count":1,"agent_status":"unknown"},"root_pane":{"workspace_id":"w1","tab_id":"w1:t2","pane_id":"w1:p4","terminal_id":"term-5","focused":false,"agent_status":"unknown","revision":1}}}
JSON
  cat > "$TREE_WORK/workspace.json" <<'JSON'
{"id":"cli:workspace:create","result":{"type":"workspace_created","workspace":{"workspace_id":"w2","number":2,"label":null,"focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w2:t1","agent_status":"unknown"},"tab":{"workspace_id":"w2","tab_id":"w2:t1","number":1,"label":null,"focused":false,"pane_count":1,"agent_status":"unknown"},"root_pane":{"workspace_id":"w2","tab_id":"w2:t1","pane_id":"w2:p1","terminal_id":"term-6","focused":false,"agent_status":"unknown","revision":1}}}
JSON
  cat > "$TREE_WORK/created-snapshot.json" <<'JSON'
{"id":"cli:api:snapshot","result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"workspaces":[{"workspace_id":"w1","number":1,"label":"Project"}],"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","number":1,"label":"Agents"}],"panes":[{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","label":"caller","terminal_id":"term-1"},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p2","label":"target","terminal_id":"term-2"},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p3","label":"created","terminal_id":"term-4"}],"agents":[{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","terminal_id":"term-1","agent":"opencode","name":"caller-agent","agent_session":{"agent":"opencode","kind":"id","source":"herdr:opencode","value":"session-caller"}},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p2","terminal_id":"term-2","agent":"claude","name":"target-agent","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"session-target"}}]}}}
JSON
  cat > "$TREE_BIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TREE_CALLS"
case "${1:-}:${2:-}" in
  pane:current) cat "$TREE_CALLER" ;;
  pane:split)
    if [[ "${TREE_NATIVE_SIGNAL:-0}" == 1 ]]; then
      kill -TERM "$$"
    fi
    if [[ "${TREE_NATIVE_FAIL:-0}" == 1 ]]; then
      printf 'native split stdout\n'
      printf 'native split stderr\n' >&2
      exit 23
    fi
    cat "$TREE_SPLIT"
    ;;
  tab:create)
    if [[ "${TREE_NATIVE_FAIL_KIND:-}" == tab ]]; then
      printf 'native tab stdout\n'
      printf 'native tab stderr\n' >&2
      exit 23
    fi
    cat "$TREE_TAB"
    ;;
  workspace:create)
    if [[ "${TREE_NATIVE_FAIL_KIND:-}" == workspace ]]; then
      printf 'native workspace stdout\n'
      printf 'native workspace stderr\n' >&2
      exit 24
    fi
    cat "$TREE_WORKSPACE"
    ;;
  api:snapshot)
    if [[ "${TREE_SNAPSHOT_FAIL:-0}" == 1 ]]; then
      printf 'snapshot unavailable\n' >&2
      exit 23
    fi
    cat "$TREE_CREATED_SNAPSHOT"
    ;;
  *) printf 'unexpected native command: %s\n' "$*" >&2; exit 64 ;;
esac
SH
  chmod +x "$TREE_BIN/herdr"
}

tree_wrapper_fixture_run() {
  env HERDR_BIN_PATH="$TREE_BIN/herdr" \
    HERDR_RESOURCE_TREE_STATE_DIR="${HERDR_RESOURCE_TREE_STATE_DIR:-$TREE_WORK/state}" \
    HERDR_RESOURCE_TREE_TEST_FAIL_FINALIZE="${HERDR_RESOURCE_TREE_TEST_FAIL_FINALIZE:-0}" \
    HERDR_SOCKET_PATH="$TREE_WORK/herdr.sock" \
    TREE_CALLS="$TREE_CALLS" TREE_CALLER="$TREE_WORK/caller.json" \
    TREE_CALLER_NEXT="${TREE_CALLER_NEXT:-$TREE_WORK/caller.json}" \
    TREE_SPLIT="$TREE_WORK/split.json" \
    TREE_TAB="$TREE_WORK/tab.json" TREE_WORKSPACE="$TREE_WORK/workspace.json" \
    TREE_CREATED_SNAPSHOT="$TREE_WORK/created-snapshot.json" \
    TREE_NATIVE_FAIL="${TREE_NATIVE_FAIL:-0}" \
    TREE_NATIVE_FAIL_KIND="${TREE_NATIVE_FAIL_KIND:-}" \
    TREE_NATIVE_SIGNAL="${TREE_NATIVE_SIGNAL:-0}" \
    TREE_SNAPSHOT_FAIL="${TREE_SNAPSHOT_FAIL:-0}" \
    PATH="$(dirname "$HERDR_WRAPPER"):$TREE_BIN:$PATH" "$@"
}

tree_wait_for_file() {
  local path="$1"
  if ! python3 - "$path" <<'PY'
import os
import sys
import time

path = sys.argv[1]
deadline = time.monotonic() + 10
while not os.path.exists(path) and time.monotonic() < deadline:
    time.sleep(0.01)
if not os.path.exists(path):
    raise SystemExit(f"causal barrier was not reached: {path}")
PY
  then
    fail "causal barrier was not reached: $path"
  fi
}

tree_real_env() {
  env -u HERDR_CLIENT_SOCKET_PATH -u HERDR_ENV -u HERDR_PANE_ID \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    HOME="$TREE_WORK/home" \
    XDG_CONFIG_HOME="$TREE_WORK/config" \
    XDG_RUNTIME_DIR="$TREE_WORK/runtime" \
    HERDR_CONFIG_PATH="$TREE_WORK/config/herdr/config.toml" \
    HERDR_SOCKET_PATH="$TREE_SOCKET" \
    "$@"
}

tree_restore_managed_env() {
  # The disposable server itself must not see HERDR_BIN_PATH; only the managed
  # wrapper and the query CLI are pointed at the identity shim.
  local native="$1"
  shift
  tree_real_env env HERDR_BIN_PATH="$TREE_WORK/restore-bin/herdr" \
    HERDR_RESOURCE_TREE_STATE_DIR="$TREE_WORK/restore-state" \
    TREE_RESTORE_NATIVE="$native" "$@"
}

tree_close_inherited_descriptors() {
  local descriptor fd
  for descriptor in /dev/fd/*; do
    fd="${descriptor##*/}"
    case "$fd" in
      0 | 1 | 2 | 255 | *[!0-9]*) continue ;;
    esac
    eval "exec ${fd}>&-" 2>/dev/null || true
  done
}

tree_start_real_server() {
  local log="$1" marker="$2"
  TREE_SERVER_EXIT="$marker"
  rm -f "$marker"
  (
    tree_close_inherited_descriptors
    local server_status=0
    tree_real_env herdr server || server_status=$?
    printf '%s\n' "$server_status" > "$marker"
    exit "$server_status"
  ) < /dev/null > "$log" 2>&1 &
  TREE_SERVER_PID=$!

  python3 - "$TREE_SOCKET" "$TREE_SERVER_PID" "$marker" <<'PY'
import os
import stat
import sys
import time

socket_path, raw_pid, marker = sys.argv[1:]
pid = int(raw_pid)
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    if os.path.exists(socket_path) and stat.S_ISSOCK(os.stat(socket_path).st_mode):
        raise SystemExit(0)
    if os.path.exists(marker):
        raise SystemExit(1)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        raise SystemExit(1)
    time.sleep(0.05)
raise SystemExit(1)
PY
}

teardown() {
  # A failing assertion ends the test body in its own shell, so any pane id held
  # only in a variable never reaches here. Tests that create panes in the
  # developer's live session append them to this file as well.
  if command_exists herdr; then
    local recorded_kind recorded
    for recorded_kind in panes workspaces; do
      [[ -s "${TREE_WORK:-}/live-$recorded_kind" ]] || continue
      while read -r recorded; do
        "$TREE_WORK/run-bounded" "$(command -v herdr)" "${recorded_kind%s}" close \
          "$recorded" >/dev/null 2>&1 || true
      done < "$TREE_WORK/live-$recorded_kind"
    done
  fi
  if [[ -n "${TREE_LIVE_TERMINAL:-}" && -x "${TREE_LIVE_HERDR:-}" ]]; then
    local live_identity live_snapshot
    live_snapshot="$("$TREE_WORK/run-bounded" "$TREE_LIVE_HERDR" api snapshot 2>/dev/null || true)"
    live_identity="$(python3 - "$TREE_LIVE_TERMINAL" "$live_snapshot" <<'PY' 2>/dev/null || true
import json
import sys

terminal = sys.argv[1]
snapshot = json.loads(sys.argv[2])["result"]["snapshot"]
matches = [pane for pane in snapshot["panes"] if pane.get("terminal_id") == terminal]
if len(matches) == 1:
    print("\t".join((matches[0]["pane_id"], matches[0]["workspace_id"])))
PY
)"
    if [[ -n "$live_identity" ]]; then
      IFS=$'\t' read -r TREE_LIVE_PANE TREE_LIVE_WORKSPACE <<< "$live_identity"
    fi
  fi
  if [[ -n "${TREE_LIVE_PANE:-}" && -x "${TREE_LIVE_HERDR:-}" ]]; then
    "$TREE_WORK/run-bounded" "$TREE_LIVE_HERDR" pane close \
      "$TREE_LIVE_PANE" >/dev/null 2>&1 || true
  fi
  if [[ -n "${TREE_LIVE_TAB:-}" && -x "${TREE_LIVE_HERDR:-}" ]]; then
    "$TREE_WORK/run-bounded" "$TREE_LIVE_HERDR" tab close \
      "$TREE_LIVE_TAB" >/dev/null 2>&1 || true
  fi
  if [[ -n "${TREE_LIVE_WORKSPACE:-}" && -x "${TREE_LIVE_HERDR:-}" ]]; then
    "$TREE_WORK/run-bounded" "$TREE_LIVE_HERDR" workspace close \
      "$TREE_LIVE_WORKSPACE" >/dev/null 2>&1 || true
  fi
  if [[ -n "${TREE_SERVER_PID:-}" ]] && kill -0 "$TREE_SERVER_PID" 2>/dev/null; then
    tree_real_env "$TREE_WORK/run-bounded" herdr server stop >/dev/null 2>&1 || \
      kill -TERM "$TREE_SERVER_PID" 2>/dev/null || true
    local attempt=0
    while [[ -n "${TREE_SERVER_EXIT:-}" && ! -e "$TREE_SERVER_EXIT" && "$attempt" -lt 1000 ]]; do
      attempt=$((attempt + 1))
      sleep 0.01
    done
    if [[ -n "${TREE_SERVER_EXIT:-}" && ! -e "$TREE_SERVER_EXIT" ]]; then
      kill -KILL "$TREE_SERVER_PID" 2>/dev/null || true
    fi
    wait "$TREE_SERVER_PID" 2>/dev/null || true
  fi
}

function test_resource_tree_001_human_and_json_views_share_the_complete_fixture_tree() {
  _bats_test_init 1 'human and JSON views share the complete fixture tree'

  # The fixture pins every id and label and generates nothing, so the whole
  # human render is knowable. Substring checks would accept a pane nested under
  # the wrong tab, workspaces emitted out of number order, or an attribution
  # line printed against the wrong resource.
  local expected_human
  expected_human="$(cat <<'RENDER'
local Herdr server (version 0.9.0, protocol 22)
workspace "Project" [w1]
  creator: unknown
  tab "Agents" [w1:t1]
    creator: unknown
    pane "implementation" [w1:p1]
      terminal: term-1
      creator: unknown
      agent: opencode "red-fox"
      session: herdr:opencode/id/session-1
      parent: unknown
  tab "Shells" [w1:t2]
    creator: unknown
    pane "logs" [w1:p2]
      terminal: term-2
      creator: unknown
      agent: none
workspace "Unrelated" [w2]
  creator: unknown
  tab "Elsewhere" [w2:t1]
    creator: unknown
    pane "manual" [w2:p1]
      terminal: term-3
      creator: unknown
      agent: claude "blue-whale"
      session: unknown
      parent: unknown
RENDER
)"
  run tree_stub_run
  assert_success
  assert_output "$expected_human"

  run tree_stub_run --json
  assert_success
  local tree_json="$output"
  run python3 - "$tree_json" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
assert tree["schema_version"] == 3
assert tree["unresolved_operations"] == []
assert tree["scope"] == {"kind": "local-herdr-server", "version": "0.9.0", "protocol": 22}
assert [workspace["id"] for workspace in tree["workspaces"]] == ["w1", "w2"]
assert [tab["id"] for tab in tree["workspaces"][0]["tabs"]] == ["w1:t1", "w1:t2"]
assert [pane["id"] for pane in tree["workspaces"][0]["tabs"][0]["panes"]] == ["w1:p1"]
pane = tree["workspaces"][0]["tabs"][0]["panes"][0]
assert pane["label"] == "implementation"
assert pane["terminal_id"] == "term-1"
assert pane["creator_session"] is None
assert pane["agent"]["presentation_name"] == "red-fox"
assert pane["agent"]["session"] == {
    "agent": "opencode",
    "kind": "id",
    "source": "herdr:opencode",
    "value": "session-1",
}
assert pane["agent"]["parent_session"] is None
unrelated = tree["workspaces"][1]["tabs"][0]["panes"][0]
assert unrelated["id"] == "w2:p1"
assert unrelated["agent"]["session"] is None
assert unrelated["agent"]["parent_session"] is None
assert sum(len(tab["panes"]) for workspace in tree["workspaces"] for tab in workspace["tabs"]) == 3
PY
  assert_success

  run python3 - "$TREE_CALLS" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as calls:
    print(sum(1 for line in calls if line.rstrip("\n") == "api snapshot"))
PY
  assert_success
  assert_output '2'
}

function test_resource_tree_002_snapshot_failures_cannot_look_like_an_empty_tree() {
  _bats_test_init 2 'snapshot failures cannot look like an empty tree'

  TREE_STUB_MODE=failed run tree_stub_run --json
  assert_failure 23
  # Exact, whole output. Each of these paths prints one line and nothing else,
  # so the exact match already proves no tree was emitted -- which is all the
  # '"workspaces": []' refutes beside them used to claim.
  assert_output 'herdr-resource-tree: snapshot retrieval failed: socket unavailable'

  TREE_STUB_MODE=malformed run tree_stub_run --json
  assert_failure 1
  assert_output 'herdr-resource-tree: malformed snapshot: snapshot.tabs must be an array'

  TREE_DESCENDANT_PID="$TREE_WORK/descendant.pid" TREE_STUB_MODE=hanging \
    run tree_stub_run --json
  assert_failure 124
  assert_output 'herdr-resource-tree: snapshot retrieval failed: herdr api snapshot timed out after 10 seconds'
  local descendant_pid
  descendant_pid="$(<"$TREE_WORK/descendant.pid")"
  if kill -0 "$descendant_pid" 2>/dev/null; then
    fail "snapshot timeout left descendant $descendant_pid running"
    return 1
  fi
}

resource_tree_require_real_herdr() {
  command_exists herdr && herdr --version >/dev/null 2>&1 \
    || skip 'a working upstream herdr is not installed, so the native oracle is unavailable'
}

function test_resource_tree_003_real_herdr_snapshot_populates_a_disposable_server_tree() {
  _bats_test_init 3 'real Herdr snapshot populates a disposable server tree'
  resource_tree_require_real_herdr

  TREE_SOCKET="$BATS_RUN_TMPDIR/htr-$BATS_TEST_NUMBER.sock"
  mkdir -p "$TREE_WORK/config/herdr" "$TREE_WORK/runtime" "$TREE_WORK/home"
  cat > "$TREE_WORK/config/herdr/config.toml" <<'TOML'
onboarding = false
[terminal]
default_shell = "/bin/sh"
TOML

  if ! tree_start_real_server "$TREE_WORK/server.log" "$TREE_WORK/server.exit"; then
    fail "disposable Herdr server did not create $TREE_SOCKET: $(<"$TREE_WORK/server.log")"
    return 1
  fi

  run tree_real_env herdr workspace create --cwd "$TREE_WORK/home" --label disposable-resource-tree
  assert_success

  run tree_real_env "$TREE_WORK/run-bounded" herdr api snapshot
  assert_success
  local native_snapshot="$output"
  run python3 - "$native_snapshot" <<'PY'
import json
import sys

print(json.loads(sys.argv[1])["result"]["snapshot"]["panes"][0]["pane_id"])
PY
  assert_success
  local initial_pane="$output" native_herdr
  run python3 - "$native_snapshot" <<'PY'
import json
import sys

print(json.loads(sys.argv[1])["result"]["snapshot"]["workspaces"][0]["workspace_id"])
PY
  assert_success
  local initial_workspace="$output"
  native_herdr="$(command -v herdr)"

  run tree_real_env "$TREE_WORK/run-bounded" env HERDR_BIN_PATH="$native_herdr" \
    PATH="$(dirname "$HERDR_WRAPPER"):$PATH" \
    "$HERDR_WRAPPER" pane split --pane "$initial_pane" --direction right
  assert_success
  local native_split="$output"
  tree_install_managed_creation_stub
  run python3 - "$native_split" "$TREE_WORK/split.json" <<'PY'
import json
import sys

real_pane = json.loads(sys.argv[1])["result"]["pane"]
fake_pane = json.load(open(sys.argv[2], encoding="utf-8"))["result"]["pane"]
for key in ("workspace_id", "tab_id", "pane_id", "terminal_id"):
    assert type(fake_pane[key]) is type(real_pane[key]), key
print(real_pane["pane_id"])
PY
  assert_success
  local created_pane="$output"

  run tree_real_env "$TREE_CLI" --json
  assert_success
  local tree_json="$output"
  run python3 - "$tree_json" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
assert tree["scope"]["kind"] == "local-herdr-server"
assert len(tree["workspaces"]) == 1
workspace = tree["workspaces"][0]
assert workspace["label"] == "disposable-resource-tree"
assert len(workspace["tabs"]) == 1
assert len(workspace["tabs"][0]["panes"]) == 2
for pane in workspace["tabs"][0]["panes"]:
    assert pane["terminal_id"].startswith("term_")
    assert pane["creator_session"] is None
    assert pane["agent"] is None
PY
  assert_success

  run tree_real_env "$TREE_WORK/run-bounded" herdr pane close "$created_pane"
  assert_success

  run tree_real_env "$TREE_WORK/run-bounded" herdr tab create \
    --workspace "$initial_workspace" --no-focus
  assert_success
  local native_tab="$output"
  run python3 - "$native_tab" "$TREE_WORK/tab.json" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])["result"]
fixture = json.load(open(sys.argv[2], encoding="utf-8"))["result"]
assert result["type"] == fixture["type"]
for resource, keys in {
    "tab": ("workspace_id", "tab_id"),
    "root_pane": ("workspace_id", "tab_id", "pane_id", "terminal_id"),
}.items():
    for key in keys:
        assert type(result[resource][key]) is type(fixture[resource][key]), (resource, key)
print(result["tab"]["tab_id"])
PY
  assert_success
  local native_tab_id="$output"
  run tree_real_env "$TREE_WORK/run-bounded" herdr tab close "$native_tab_id"
  assert_success

  run tree_real_env "$TREE_WORK/run-bounded" herdr workspace create \
    --cwd "$TREE_WORK/home" --no-focus
  assert_success
  local native_workspace="$output"
  run python3 - "$native_workspace" "$TREE_WORK/workspace.json" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])["result"]
fixture = json.load(open(sys.argv[2], encoding="utf-8"))["result"]
assert result["type"] == fixture["type"]
for resource, keys in {
    "workspace": ("workspace_id",),
    "tab": ("workspace_id", "tab_id"),
    "root_pane": ("workspace_id", "tab_id", "pane_id", "terminal_id"),
}.items():
    for key in keys:
        assert type(result[resource][key]) is type(fixture[resource][key]), (resource, key)
print(result["workspace"]["workspace_id"])
PY
  assert_success
  local native_workspace_id="$output"
  run tree_real_env "$TREE_WORK/run-bounded" herdr workspace close "$native_workspace_id"
  assert_success

  run tree_real_env "$TREE_WORK/run-bounded" herdr server stop
  assert_success
  tree_wait_for_file "$TREE_SERVER_EXIT"
  if ! wait "$TREE_SERVER_PID"; then
    fail 'disposable Herdr server exited unsuccessfully after stop'
    return 1
  fi
  TREE_SERVER_PID=""
}

function test_resource_tree_004_agent_fixture_matches_the_installed_herdr_boundary() {
  _bats_test_init 4 'agent fixture matches the installed Herdr boundary'
  resource_tree_require_real_herdr

  run python3 - <<'PY'
import json
import os
import signal
import subprocess
import sys

process = subprocess.Popen(
    ["herdr", "api", "snapshot"],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    start_new_session=True,
)
try:
    stdout, stderr = process.communicate(timeout=10)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.communicate()
    print("real Herdr snapshot timed out", file=sys.stderr)
    raise SystemExit(124)
if process.returncode != 0:
    print(stderr.strip() or f"real Herdr exited {process.returncode}", file=sys.stderr)
    # Separate "there is no oracle here" from "the oracle answered and
    # disagreed". Only the first is an environment precondition; folding both
    # into one skip meant a herdr that had started rejecting this call read as
    # an absent server, and the fixture below stayed unadjudicated in a green
    # run (docs/solutions/design-patterns/calibration-skips-need-their-own-verdict.md).
    try:
        if json.loads(stderr)["error"]["code"] == "server_not_running":
            raise SystemExit(78)
    except (KeyError, TypeError, ValueError):
        pass
    raise SystemExit(process.returncode)
sys.stdout.write(stdout)
PY
  # 124 is the wrapper's timeout and 78 its no-running-server verdict. Both are
  # named environment preconditions; every other non-zero status is real Herdr
  # refusing the call, which this calibration must report as red.
  if [[ "$status" -eq 124 || "$status" -eq 78 ]]; then
    skip "no running Herdr server can answer api snapshot: $output"
  fi
  assert_success
  local real_snapshot="$output"
  run "$TREE_WORK/run-bounded" herdr pane current --current
  if [[ "$status" -ne 0 ]] && [[ "$output" == *server_not_running* ]]; then
    skip "no running Herdr server can answer pane current: $output"
  fi
  assert_success
  local real_current="$output"
  run python3 - "$real_current" <<'PY'
import json
import sys

pane = json.loads(sys.argv[1])["result"]["pane"]
if not pane.get("agent") or not pane.get("agent_session"):
    raise SystemExit(77)
PY
  if [[ "$status" -eq 77 ]]; then
    skip 'the current real Herdr pane has no native Agent session identity'
  fi
  assert_success
  tree_install_managed_creation_stub
  run python3 - "$real_snapshot" "$TREE_WORK/snapshot.json" \
    "$real_current" "$TREE_WORK/caller.json" <<'PY'
import json
import sys

real = json.loads(sys.argv[1])["result"]["snapshot"]
fixture = json.load(open(sys.argv[2], encoding="utf-8"))["result"]["snapshot"]
assert fixture["version"] == real["version"]
assert fixture["protocol"] == real["protocol"]
real_agent = next((agent for agent in real["agents"] if agent.get("agent_session")), None)
if real_agent is None:
    raise SystemExit(77)
fixture_agent = next(agent for agent in fixture["agents"] if agent.get("agent_session"))
for key in ("workspace_id", "tab_id", "pane_id", "terminal_id", "agent", "name"):
    assert type(fixture_agent[key]) is type(real_agent[key]), key
for key in ("agent", "kind", "source", "value"):
    assert type(fixture_agent["agent_session"][key]) is type(real_agent["agent_session"][key]), key
real_pane = next(pane for pane in real["panes"] if pane["pane_id"] == real_agent["pane_id"])
fixture_pane = next(pane for pane in fixture["panes"] if pane["pane_id"] == fixture_agent["pane_id"])
for key in ("workspace_id", "tab_id", "pane_id", "terminal_id"):
    assert type(fixture_pane[key]) is type(real_pane[key]), key

real_current = json.loads(sys.argv[3])["result"]["pane"]
fixture_current = json.load(open(sys.argv[4], encoding="utf-8"))["result"]["pane"]
for key in ("pane_id", "terminal_id", "agent"):
    assert type(fixture_current[key]) is type(real_current[key]), key
for key in ("agent", "kind", "source", "value"):
    assert type(fixture_current["agent_session"][key]) is type(real_current["agent_session"][key]), key
PY
  if [[ "$status" -eq 77 ]]; then
    skip 'the running Herdr server has no agent with a native session identity'
  fi
  assert_success
}

function test_resource_tree_005_creation_failures_preserve_the_native_boundary() {
  _bats_test_init 5 'creation failures preserve the native boundary'
  tree_install_managed_creation_stub

  local blocked_state="$TREE_WORK/state-blocker/child"
  : > "$TREE_WORK/state-blocker"
  HERDR_RESOURCE_TREE_STATE_DIR="$blocked_state" run --separate-stderr \
    tree_wrapper_fixture_run "$HERDR_WRAPPER" pane split --pane w1:p2
  assert_failure 69
  assert_output ''
  assert_stderr --partial 'intent recording failed; native creation was not called'
  run python3 - "$TREE_CALLS" <<'PY'
import sys

calls = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert sum(call.startswith("pane split") for call in calls) == 0
PY
  assert_success

  : > "$TREE_CALLS"
  HERDR_RESOURCE_TREE_TEST_FAIL_FINALIZE=1 run --separate-stderr \
    tree_wrapper_fixture_run "$HERDR_WRAPPER" pane split --pane w1:p2
  assert_failure 70
  assert_output "$(<"$TREE_WORK/split.json")"
  # One whole-line match, UUID wildcarded: the operation id is random, every
  # other field is the fixture's own input. Split into per-field partials the
  # block could lose a coordinate, reorder them, or carry a different detail
  # and still pass -- and workspace_created/tab_created were asserted by
  # nothing at all.
  assert_stderr --regexp '^herdr wrapper: creation operation [0-9a-f-]{36} pane_id=w1:p3 terminal_id=term-4 workspace_id=w1 tab_id=w1:t1 workspace_created=0 tab_created=0 succeeded, but provenance finalization failed: injected finalization failure; created resources remain open and automatic creation retry is unsafe; do not retry creation$'
  run tree_wrapper_fixture_run "$TREE_CLI" --branch --json
  assert_success
  local uncertain_branch="$output"
  run python3 - "$uncertain_branch" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
assert tree["schema_version"] == 3
assert tree["workspaces"] == []
assert len(tree["unresolved_operations"]) == 1
operation = tree["unresolved_operations"][0]
assert operation["creation_kind"] == "pane"
assert operation["caller_session"]["value"] == "session-caller"
assert operation["known_resources"] == {
    "pane_id": "w1:p3",
    "tab_id": "w1:t1",
    "terminal_id": "term-4",
    "workspace_id": "w1",
}
assert operation["retry_safe"] is False
PY
  assert_success

  : > "$TREE_CALLS"
  TREE_NATIVE_FAIL=1 run --separate-stderr \
    tree_wrapper_fixture_run "$HERDR_WRAPPER" pane split --pane w1:p2
  assert_failure 23
  assert_output 'native split stdout'
  assert_equal "$stderr" 'native split stderr'
  run python3 - "$TREE_CALLS" <<'PY'
import sys

calls = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert sum(call.startswith("pane split") for call in calls) == 1
PY
  assert_success

  cat > "$TREE_WORK/split.json" <<'JSON'
{"id":"cli:pane:split","result":{"type":"pane_split","pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p3"}}}
JSON
  : > "$TREE_CALLS"
  run --separate-stderr tree_wrapper_fixture_run \
    "$HERDR_WRAPPER" pane split --pane w1:p2
  assert_failure 70
  assert_output "$(<"$TREE_WORK/split.json")"
  assert_stderr --regexp '^herdr wrapper: creation operation [0-9a-f-]{36} pane_id=w1:p3 workspace_id=w1 tab_id=w1:t1 succeeded, but provenance finalization failed: created pane terminal_id must be a non-empty string; created resources remain open and automatic creation retry is unsafe; do not retry creation$'
}

function test_resource_tree_006_human_creations_stay_usable_and_incomplete_agent_identity_is_rejected() {
  _bats_test_init 6 'human creations stay usable and incomplete agent identity is rejected'
  tree_install_managed_creation_stub

  cat > "$TREE_WORK/caller.json" <<'JSON'
{"id":"cli:pane:current","result":{"type":"pane_current","pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","terminal_id":"term-1"}}}
JSON
  run tree_wrapper_fixture_run "$HERDR_WRAPPER" pane split --pane w1:p2
  assert_success
  assert_output "$(<"$TREE_WORK/split.json")"
  run tree_wrapper_fixture_run "$HERDR_WRAPPER" tab create --workspace w1
  assert_success
  assert_output "$(<"$TREE_WORK/tab.json")"
  run tree_wrapper_fixture_run "$HERDR_WRAPPER" workspace create --cwd "$TREE_WORK"
  assert_success
  assert_output "$(<"$TREE_WORK/workspace.json")"
  cat > "$TREE_WORK/created-snapshot.json" <<'JSON'
{"id":"cli:api:snapshot","result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"workspaces":[{"workspace_id":"w1","number":1,"label":"Existing"},{"workspace_id":"w2","number":2}],"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","number":1,"label":"Existing tab"},{"workspace_id":"w1","tab_id":"w1:t2","number":2},{"workspace_id":"w2","tab_id":"w2:t1","number":1}],"panes":[{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","label":"caller","terminal_id":"term-1"},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p2","label":"target","terminal_id":"term-2"},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p3","terminal_id":"term-4"},{"workspace_id":"w1","tab_id":"w1:t2","pane_id":"w1:p4","terminal_id":"term-5"},{"workspace_id":"w2","tab_id":"w2:t1","pane_id":"w2:p1","terminal_id":"term-6"}],"agents":[]}}}
JSON
  run tree_wrapper_fixture_run "$TREE_CLI" --json
  assert_success
  local human_tree="$output"
  run python3 - "$human_tree" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
# Pin the fixture's whole resource set before asserting the property: an empty
# tree, or one missing the created resources, would run zero assertions below.
assert [workspace["id"] for workspace in tree["workspaces"]] == ["w1", "w2"]
tabs = {
    tab["id"]: tab for workspace in tree["workspaces"] for tab in workspace["tabs"]
}
assert set(tabs) == {"w1:t1", "w1:t2", "w2:t1"}
panes = {
    pane["id"]: pane for tab in tabs.values() for pane in tab["panes"]
}
assert set(panes) == {"w1:p1", "w1:p2", "w1:p3", "w1:p4", "w2:p1"}
for resource in [*tree["workspaces"], *tabs.values(), *panes.values()]:
    assert resource["creator_session"] is None, resource["id"]
PY
  assert_success

  cat > "$TREE_WORK/caller.json" <<'JSON'
{"id":"cli:pane:current","result":{"type":"pane_current","pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","terminal_id":"term-1","agent":"opencode"}}}
JSON
  : > "$TREE_CALLS"
  run tree_wrapper_fixture_run "$HERDR_WRAPPER" pane split --pane w1:p2
  assert_failure 69
  assert_output 'herdr wrapper: caller identity unavailable; native creation was not called: current pane agent_session is required for an observed agent'
  run python3 - "$TREE_CALLS" <<'PY'
import sys

calls = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert sum(call.startswith("pane split") for call in calls) == 0
PY
  assert_success
}

function test_resource_tree_007_concurrent_splits_keep_independent_operations_and_creators() {
  _bats_test_init 7 'concurrent splits keep independent operations and creators'

  cat > "$TREE_WORK/concurrent-snapshot.json" <<'JSON'
{"id":"cli:api:snapshot","result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"workspaces":[{"workspace_id":"w1","number":1,"label":"Project"}],"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","number":1,"label":"Agents"}],"panes":[{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pa","label":"created-a","terminal_id":"term-a"},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pb","label":"created-b","terminal_id":"term-b"}],"agents":[]}}}
JSON
  local concurrent_bin="$TREE_WORK/concurrent-bin"
  mkdir -p "$concurrent_bin"
  cat > "$concurrent_bin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TREE_CONCURRENT_CALLS"
case "${1:-}:${2:-}" in
  pane:current)
    printf '{"id":"current","result":{"type":"pane_current","pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:caller-%s","terminal_id":"term-caller-%s","agent":"opencode","agent_session":{"agent":"opencode","kind":"id","source":"herdr:opencode","value":"session-%s"}}}}\n' "$TREE_ID" "$TREE_ID" "$TREE_ID"
    ;;
  pane:split)
    : > "$TREE_READY"
    while [[ ! -e "$TREE_RELEASE" ]]; do sleep 0.01; done
    printf '{"id":"split","result":{"type":"pane_split","pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p%s","terminal_id":"term-%s","focused":false,"agent_status":"unknown","revision":1}}}\n' "$TREE_ID" "$TREE_ID"
    ;;
  api:snapshot) cat "$TREE_CONCURRENT_SNAPSHOT" ;;
  *) exit 64 ;;
esac
SH
  chmod +x "$concurrent_bin/herdr"

  local state="$TREE_WORK/concurrent-state" scope="$TREE_WORK/concurrent.sock"
  local calls_a="$TREE_WORK/calls-a" calls_b="$TREE_WORK/calls-b"
  : > "$scope"
  mkdir -p "$state"
  # The pre-migration operations table as an older herdr-resource-tree shipped
  # it, frozen by history; see test 011, which owns the migration case.
  run python3 - "$state/registry.sqlite3" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute(
    """
    CREATE TABLE operations (
        operation_id TEXT PRIMARY KEY,
        server_scope TEXT NOT NULL,
        caller_session TEXT NOT NULL,
        caller_pane_id TEXT NOT NULL,
        caller_terminal_id TEXT NOT NULL,
        status TEXT NOT NULL,
        native_exit_status INTEGER,
        pane_id TEXT,
        terminal_id TEXT,
        workspace_id TEXT,
        tab_id TEXT
    )
    """
)
connection.commit()
connection.close()
PY
  assert_success
  env HERDR_BIN_PATH="$concurrent_bin/herdr" HERDR_RESOURCE_TREE_STATE_DIR="$state" \
    HERDR_SOCKET_PATH="$scope" TREE_ID=a TREE_CONCURRENT_CALLS="$calls_a" \
    TREE_READY="$TREE_WORK/ready-a" TREE_RELEASE="$TREE_WORK/release-a" \
    TREE_CONCURRENT_SNAPSHOT="$TREE_WORK/concurrent-snapshot.json" \
    PATH="$(dirname "$HERDR_WRAPPER"):$concurrent_bin:$PATH" \
    "$HERDR_WRAPPER" pane split --pane w1:target-a > "$TREE_WORK/out-a" 2> "$TREE_WORK/err-a" &
  local pid_a=$!
  env HERDR_BIN_PATH="$concurrent_bin/herdr" HERDR_RESOURCE_TREE_STATE_DIR="$state" \
    HERDR_SOCKET_PATH="$scope" TREE_ID=b TREE_CONCURRENT_CALLS="$calls_b" \
    TREE_READY="$TREE_WORK/ready-b" TREE_RELEASE="$TREE_WORK/release-b" \
    TREE_CONCURRENT_SNAPSHOT="$TREE_WORK/concurrent-snapshot.json" \
    PATH="$(dirname "$HERDR_WRAPPER"):$concurrent_bin:$PATH" \
    "$HERDR_WRAPPER" pane split --pane w1:target-b > "$TREE_WORK/out-b" 2> "$TREE_WORK/err-b" &
  local pid_b=$!

  tree_wait_for_file "$TREE_WORK/ready-a"
  tree_wait_for_file "$TREE_WORK/ready-b"

  run env HERDR_BIN_PATH="$concurrent_bin/herdr" HERDR_RESOURCE_TREE_STATE_DIR="$state" \
    HERDR_SOCKET_PATH="$scope" TREE_ID=a TREE_CONCURRENT_CALLS="$calls_a" \
    TREE_CONCURRENT_SNAPSHOT="$TREE_WORK/concurrent-snapshot.json" \
    PATH="$(dirname "$HERDR_WRAPPER"):$concurrent_bin:$PATH" "$TREE_CLI" --json
  assert_success
  local in_flight_tree="$output"
  run python3 - "$in_flight_tree" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
panes = [
    pane
    for workspace in tree["workspaces"]
    for tab in workspace["tabs"]
    for pane in tab["panes"]
]
# Pin the fixture's pane set first: an empty tree would satisfy the `all`
# below without ever evaluating the property under test.
assert {pane["id"] for pane in panes} == {"w1:pa", "w1:pb"}
assert all(pane["creator_session"] is None for pane in panes)
PY
  assert_success

  : > "$TREE_WORK/release-b"
  : > "$TREE_WORK/release-a"
  wait "$pid_b"
  wait "$pid_a"

  run env HERDR_BIN_PATH="$concurrent_bin/herdr" HERDR_RESOURCE_TREE_STATE_DIR="$state" \
    HERDR_SOCKET_PATH="$scope" TREE_ID=a TREE_CONCURRENT_CALLS="$calls_a" \
    TREE_CONCURRENT_SNAPSHOT="$TREE_WORK/concurrent-snapshot.json" \
    PATH="$(dirname "$HERDR_WRAPPER"):$concurrent_bin:$PATH" "$TREE_CLI" --json
  assert_success
  local concurrent_tree="$output"
  run python3 - "$concurrent_tree" "$calls_a" "$calls_b" <<'PY'
import json
import re
import sys

tree = json.loads(sys.argv[1])
panes = {
    pane["id"]: pane
    for workspace in tree["workspaces"]
    for tab in workspace["tabs"]
    for pane in tab["panes"]
}
assert panes["w1:pa"]["creator_session"]["value"] == "session-a"
assert panes["w1:pb"]["creator_session"]["value"] == "session-b"
operations = []
for path in sys.argv[2:]:
    text = open(path, encoding="utf-8").read()
    match = re.search(r"HERDR_RESOURCE_OPERATION_ID=([0-9a-f-]+)", text)
    assert match, path
    operations.append(match.group(1))
assert len(set(operations)) == 2
PY
  assert_success
}

function test_resource_tree_008_crash_after_creation_keeps_the_resource_unattributed() {
  _bats_test_init 8 'crash after creation keeps the resource unattributed'
  tree_install_managed_creation_stub
  cat > "$TREE_BIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TREE_CALLS"
case "${1:-}:${2:-}" in
  pane:current) cat "$TREE_CALLER" ;;
  pane:split)
    : > "$TREE_CRASH_READY"
    while [[ ! -e "$TREE_CRASH_RELEASE" ]]; do sleep 0.01; done
    cat "$TREE_SPLIT"
    : > "$TREE_CRASH_DONE"
    ;;
  api:snapshot) cat "$TREE_CREATED_SNAPSHOT" ;;
  *) exit 64 ;;
esac
SH
  chmod +x "$TREE_BIN/herdr"

  env HERDR_BIN_PATH="$TREE_BIN/herdr" HERDR_RESOURCE_TREE_STATE_DIR="$TREE_WORK/state" \
    HERDR_SOCKET_PATH="$TREE_WORK/herdr.sock" TREE_CALLS="$TREE_CALLS" \
    TREE_CALLER="$TREE_WORK/caller.json" TREE_SPLIT="$TREE_WORK/split.json" \
    TREE_CREATED_SNAPSHOT="$TREE_WORK/created-snapshot.json" \
    TREE_CRASH_READY="$TREE_WORK/crash.ready" TREE_CRASH_RELEASE="$TREE_WORK/crash.release" \
    TREE_CRASH_DONE="$TREE_WORK/crash.done" PATH="$(dirname "$HERDR_WRAPPER"):$TREE_BIN:$PATH" \
    "$HERDR_WRAPPER" pane split --pane w1:p2 > "$TREE_WORK/crash.out" 2> "$TREE_WORK/crash.err" &
  local wrapper_pid=$!
  tree_wait_for_file "$TREE_WORK/crash.ready"
  kill -TERM "$wrapper_pid"
  : > "$TREE_WORK/crash.release"
  if wait "$wrapper_pid"; then
    fail 'crashed wrapper unexpectedly returned success'
  fi
  tree_wait_for_file "$TREE_WORK/crash.done"

  run tree_wrapper_fixture_run "$TREE_CLI" --json
  assert_success
  local crash_tree="$output"
  run python3 - "$crash_tree" "$TREE_CALLS" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
created = next(
    pane
    for workspace in tree["workspaces"]
    for tab in workspace["tabs"]
    for pane in tab["panes"]
    if pane["id"] == "w1:p3"
)
assert created["creator_session"] is None
assert len(tree["unresolved_operations"]) == 1
operation = tree["unresolved_operations"][0]
assert operation["creation_kind"] == "pane"
assert operation["caller_session"]["value"] == "session-caller"
assert operation["known_resources"] == {}
assert operation["retry_safe"] is False
calls = open(sys.argv[2], encoding="utf-8").read().splitlines()
assert sum(call.startswith("pane split") for call in calls) == 1
PY
  assert_success

  run tree_wrapper_fixture_run "$TREE_CLI"
  assert_success
  # Whole lines out of the render, UUID wildcarded. The two partials this
  # replaces matched anywhere in the tree and left the reason line, which is
  # what tells the reader why a retry is unsafe, asserted by nothing.
  assert_line --regexp '^unresolved pane creation operation [0-9a-f-]{36}: automatic retry is unsafe$'
  assert_line '  reason: creation ended before a final native outcome was recorded'

  run tree_wrapper_fixture_run "$TREE_CLI" --branch --json
  assert_success
  local crash_branch="$output"
  run python3 - "$crash_branch" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
assert tree["workspaces"] == []
assert len(tree["unresolved_operations"]) == 1
PY
  assert_success
}

function test_resource_tree_009_real_agent_split_is_attributed_and_cleaned_up() {
  _bats_test_init 9 'real Agent split is attributed and cleaned up'
  resource_tree_require_real_herdr

  TREE_LIVE_HERDR="$(command -v herdr)"
  run "$TREE_WORK/run-bounded" "$TREE_LIVE_HERDR" pane current --current
  if [[ "$status" -ne 0 ]]; then
    skip "real Herdr returned no current pane: $output"
  fi
  local current_json="$output"
  run python3 - "$current_json" <<'PY'
import json
import sys

pane = json.loads(sys.argv[1])["result"]["pane"]
session = pane.get("agent_session")
if not pane.get("agent") or not isinstance(session, dict):
    raise SystemExit(77)
for key in ("agent", "kind", "source", "value"):
    assert isinstance(session.get(key), str) and session[key]
print(pane["pane_id"])
PY
  if [[ "$status" -eq 77 ]]; then
    skip 'the current real Herdr pane has no native Agent session identity'
  fi
  assert_success
  local current_pane="$output"

  run "$TREE_WORK/run-bounded" "$TREE_LIVE_HERDR" api snapshot
  assert_success
  local before_split="$output"

  run --separate-stderr "$TREE_WORK/run-bounded" env HERDR_BIN_PATH="$TREE_LIVE_HERDR" \
    HERDR_RESOURCE_TREE_STATE_DIR="$TREE_WORK/live-state" \
    PATH="$(dirname "$HERDR_WRAPPER"):$PATH" \
    "$HERDR_WRAPPER" pane split --pane "$current_pane" --direction right --no-focus
  local split_status="$status" split_stderr="$stderr" split_json="$output"

  # Record the pane the server actually gained, so teardown can close it even
  # when the wrapper failed after creating it. This is bookkeeping, not a
  # verdict: asserting here would report a missing pane instead of the
  # wrapper's own exit status and diagnostic, which is what failed.
  run "$TREE_WORK/run-bounded" "$TREE_LIVE_HERDR" api snapshot
  local after_split="$output"
  # Known cost: if this snapshot fails, the pane the split created is not
  # identified and teardown cannot close it, so it leaks into the live session.
  # A fallback that diffed snapshots was tried and removed -- appearing in the
  # window between two snapshots does not establish that this test created a
  # pane, so the fallback closed panes a sibling test, or the user, had just
  # opened. Leaking a pane the failure message names is cheaper than closing
  # somebody else's.
  TREE_LIVE_PANE="$(python3 - "$before_split" "$after_split" <<'PY'
import json
import sys


def pane_ids(envelope):
    try:
        snapshot = json.loads(envelope)["result"]["snapshot"]
    except (json.JSONDecodeError, KeyError, TypeError):
        return set()
    return {pane["pane_id"] for pane in snapshot["panes"]}


created = pane_ids(sys.argv[2]) - pane_ids(sys.argv[1])
if len(created) == 1:
    print(created.pop())
PY
)"
  if [[ -n "$TREE_LIVE_PANE" ]]; then
    printf '%s\n' "$TREE_LIVE_PANE" >> "$TREE_WORK/live-panes"
  fi

  status="$split_status"
  output="$split_json"
  stderr="$split_stderr"
  assert_success

  # The wrapper must report the pane the server really created, not merely some
  # pane id: the recorded attribution is keyed by what it returns here.
  run python3 - "$split_json" <<'PY'
import json
import sys

print(json.loads(sys.argv[1])["result"]["pane"]["pane_id"])
PY
  assert_success
  assert_output "$TREE_LIVE_PANE"

  run "$TREE_WORK/run-bounded" "$TREE_LIVE_HERDR" pane get "$TREE_LIVE_PANE"
  assert_success
  local created_pane_json="$output"
  run python3 - "$created_pane_json" <<'PY'
import json
import sys

print(json.loads(sys.argv[1])["result"]["pane"]["terminal_id"])
PY
  assert_success
  TREE_LIVE_TERMINAL="$output"
  run "$TREE_WORK/run-bounded" "$TREE_LIVE_HERDR" pane move "$TREE_LIVE_PANE" \
    --new-workspace --no-focus
  assert_success
  local move_json="$output" moved_identity
  run python3 - "$move_json" "$created_pane_json" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])["result"]
move = result.get("move_result", result)
moved = move["pane"]
before = json.loads(sys.argv[2])["result"]["pane"]
assert move["previous_pane_id"] == before["pane_id"]
assert moved["terminal_id"] == before["terminal_id"]
print("\t".join((moved["pane_id"], moved["workspace_id"])))
PY
  assert_success
  moved_identity="$output"
  IFS=$'\t' read -r TREE_LIVE_PANE TREE_LIVE_WORKSPACE <<< "$moved_identity"
  printf '%s\n' "$TREE_LIVE_PANE" >> "$TREE_WORK/live-panes"
  printf '%s\n' "$TREE_LIVE_WORKSPACE" >> "$TREE_WORK/live-workspaces"

  run env HERDR_BIN_PATH="$TREE_LIVE_HERDR" \
    HERDR_RESOURCE_TREE_STATE_DIR="$TREE_WORK/live-state" \
    PATH="$(dirname "$HERDR_WRAPPER"):$PATH" "$TREE_CLI" --branch --json
  assert_success
  local branch_json="$output"
  run python3 - "$branch_json" "$TREE_LIVE_PANE" "$current_json" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
pane_id = sys.argv[2]
session = json.loads(sys.argv[3])["result"]["pane"]["agent_session"]
panes = [
    pane
    for workspace in tree["workspaces"]
    for tab in workspace["tabs"]
    for pane in tab["panes"]
]
assert [pane["id"] for pane in panes] == [pane_id]
assert panes[0]["creator_session"] == session
PY
  assert_success

  run "$TREE_WORK/run-bounded" "$TREE_LIVE_HERDR" pane close "$TREE_LIVE_PANE"
  assert_success
  TREE_LIVE_PANE=""
  TREE_LIVE_TERMINAL=""
}

function test_resource_tree_010_wrapper_delegates_without_recursing_or_changing_the_command() {
  _bats_test_init 10 'wrapper delegates without recursing or changing the command'

  cat > "$TREE_BIN/herdr" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}:${2:-}:${3:-}" == 'pane:split:--help' ]]; then
  printf 'native pane split help\n'
  exit 0
fi
printf 'native stdout:'
printf ' <%s>' "$@"
printf '\n'
printf 'native stderr\n' >&2
exit 42
SH
  chmod +x "$TREE_BIN/herdr"

  run --separate-stderr env HERDR_BIN_PATH="$HERDR_WRAPPER" \
    PATH="$(dirname "$HERDR_WRAPPER"):$TREE_BIN:$PATH" \
    "$HERDR_WRAPPER" status client --json 'argument with spaces'
  assert_failure 42
  assert_output 'native stdout: <status> <client> <--json> <argument with spaces>'
  assert_equal "$stderr" 'native stderr'

  run env HERDR_BIN_PATH="$HERDR_WRAPPER" HERDR_PANE_ID=w1:p1 \
    PATH="$(dirname "$HERDR_WRAPPER"):$TREE_BIN:$PATH" \
    "$HERDR_WRAPPER" pane split --help
  assert_success
  assert_output 'native pane split help'
}

function test_resource_tree_011_split_records_the_caller_and_persists_its_branch() {
  _bats_test_init 11 'split records the caller and persists its branch'

  tree_install_managed_creation_stub
  mkdir -p "$TREE_WORK/state"
  # A registry left by an older herdr-resource-tree: this is the operations
  # table as that version shipped it, frozen by history. It must not be updated
  # to match the current source. The split below is the migration case: against
  # this schema it only succeeds if the CLI adds the columns it now writes.
  run python3 - "$TREE_WORK/state/registry.sqlite3" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute(
    """
    CREATE TABLE operations (
        operation_id TEXT PRIMARY KEY,
        server_scope TEXT NOT NULL,
        caller_session TEXT NOT NULL,
        caller_pane_id TEXT NOT NULL,
        caller_terminal_id TEXT NOT NULL,
        status TEXT NOT NULL,
        native_exit_status INTEGER,
        pane_id TEXT,
        terminal_id TEXT,
        workspace_id TEXT,
        tab_id TEXT
    )
    """
)
connection.commit()
connection.close()
PY
  assert_success
  run tree_wrapper_fixture_run "$HERDR_WRAPPER" pane split --pane w1:p2 --direction right
  assert_success
  assert_output "$(<"$TREE_WORK/split.json")"

  run tree_wrapper_fixture_run "$TREE_CLI" --json
  assert_success
  local overall_json="$output"
  run python3 - "$overall_json" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
panes = {
    pane["id"]: pane
    for workspace in tree["workspaces"]
    for tab in workspace["tabs"]
    for pane in tab["panes"]
}
assert panes["w1:p1"]["creator_session"] is None
assert panes["w1:p2"]["creator_session"] is None
assert panes["w1:p3"]["creator_session"] == {
    "agent": "opencode",
    "kind": "id",
    "source": "herdr:opencode",
    "value": "session-caller",
}
PY
  assert_success

  TREE_SNAPSHOT_FAIL=1 run tree_wrapper_fixture_run "$TREE_CLI" --json
  assert_failure 23
  assert_output 'herdr-resource-tree: snapshot retrieval failed: snapshot unavailable'
  run tree_wrapper_fixture_run "$TREE_CLI" --json
  assert_success
  local recovered_json="$output"
  run python3 - "$recovered_json" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
created = next(
    pane
    for workspace in tree["workspaces"]
    for tab in workspace["tabs"]
    for pane in tab["panes"]
    if pane["id"] == "w1:p3"
)
assert created["creator_session"]["value"] == "session-caller"
PY
  assert_success

  run tree_wrapper_fixture_run "$TREE_CLI" --branch --json
  assert_success
  local branch_json="$output"
  run python3 - "$branch_json" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
assert [workspace["id"] for workspace in tree["workspaces"]] == ["w1"]
assert [tab["id"] for tab in tree["workspaces"][0]["tabs"]] == ["w1:t1"]
assert [pane["id"] for pane in tree["workspaces"][0]["tabs"][0]["panes"]] == ["w1:p3"]
PY
  assert_success

  run python3 - "$TREE_WORK/created-snapshot.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    snapshot = json.load(handle)
body = snapshot["result"]["snapshot"]
body["workspaces"].append({"workspace_id": "w2", "number": 2, "label": "Moved"})
body["tabs"].append(
    {"workspace_id": "w2", "tab_id": "w2:t1", "number": 1, "label": "Moved"}
)
created = next(
    pane
    for pane in body["panes"]
    if pane["pane_id"] == "w1:p3"
)
created.update(workspace_id="w2", tab_id="w2:t1", pane_id="w2:p3")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(snapshot, handle)
PY
  assert_success
  run tree_wrapper_fixture_run "$TREE_CLI" --json
  assert_success
  local moved_json="$output"
  run python3 - "$moved_json" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
moved = next(
    pane
    for workspace in tree["workspaces"]
    for tab in workspace["tabs"]
    for pane in tab["panes"]
    if pane["terminal_id"] == "term-4"
)
assert moved["id"] == "w2:p3"
assert moved["creator_session"]["value"] == "session-caller"
PY
  assert_success

  run python3 - "$TREE_WORK/created-snapshot.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    snapshot = json.load(handle)
created = next(
    pane
    for pane in snapshot["result"]["snapshot"]["panes"]
    if pane["terminal_id"] == "term-4"
)
created["terminal_id"] = "term-reused"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(snapshot, handle)
PY
  assert_success
  run tree_wrapper_fixture_run "$TREE_CLI" --json
  assert_success
  local reused_json="$output"
  run python3 - "$reused_json" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
created = next(
    pane
    for workspace in tree["workspaces"]
    for tab in workspace["tabs"]
    for pane in tab["panes"]
    if pane["id"] == "w2:p3"
)
assert created["label"] == "created"
assert created["creator_session"] is None
PY
  assert_success

  run python3 - "$TREE_WORK/created-snapshot.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    snapshot = json.load(handle)
created = next(
    pane
    for pane in snapshot["result"]["snapshot"]["panes"]
    if pane["pane_id"] == "w2:p3"
)
created["terminal_id"] = "term-4"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(snapshot, handle)
PY
  assert_success
  rm "$TREE_WORK/herdr.sock"
  : > "$TREE_WORK/herdr.sock"
  run tree_wrapper_fixture_run "$TREE_CLI" --json
  assert_success
  local restarted_json="$output"
  run python3 - "$restarted_json" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
created = next(
    pane
    for workspace in tree["workspaces"]
    for tab in workspace["tabs"]
    for pane in tab["panes"]
    if pane["id"] == "w2:p3"
)
assert created["terminal_id"] == "term-4"
assert created["creator_session"] is None
PY
  assert_success

  run python3 - "$TREE_CALLS" <<'PY'
import re
import sys

calls = open(sys.argv[1], encoding="utf-8").read().splitlines()
splits = [call for call in calls if call.startswith("pane split ")]
assert len(splits) == 1, splits
# The operation id must reach the native command: it is how a crashed wrapper's
# resource is later reconciled. Only the generated UUID itself is unstable.
assert re.fullmatch(
    r"pane split --pane w1:p2 --direction right "
    r"--env HERDR_RESOURCE_OPERATION_ID=[0-9a-f-]{36}",
    splits[0],
), splits[0]
PY
  assert_success
}

function test_resource_tree_012_tab_and_workspace_creation_record_only_returned_resources() {
  _bats_test_init 12 'tab and workspace creation record only returned resources'
  tree_install_managed_creation_stub
  cat > "$TREE_WORK/created-snapshot.json" <<'JSON'
{"id":"cli:api:snapshot","result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"workspaces":[{"workspace_id":"w1","number":1,"label":"Existing"},{"workspace_id":"w2","number":2}],"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","number":1,"label":"Existing tab"},{"workspace_id":"w1","tab_id":"w1:t2","number":2},{"workspace_id":"w2","tab_id":"w2:t1","number":1}],"panes":[{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","label":"caller","terminal_id":"term-1"},{"workspace_id":"w1","tab_id":"w1:t2","pane_id":"w1:p4","terminal_id":"term-5"},{"workspace_id":"w1","tab_id":"w1:t2","pane_id":"w1:p5","label":"later sibling","terminal_id":"term-sibling-tab"},{"workspace_id":"w2","tab_id":"w2:t1","pane_id":"w2:p1","terminal_id":"term-6"},{"workspace_id":"w2","tab_id":"w2:t1","pane_id":"w2:p2","label":"later sibling","terminal_id":"term-sibling-workspace"}],"agents":[{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","terminal_id":"term-1","agent":"opencode","name":"caller-agent","agent_session":{"agent":"opencode","kind":"id","source":"herdr:opencode","value":"session-caller"}}]}}}
JSON

  run tree_wrapper_fixture_run "$HERDR_WRAPPER" tab create --workspace w1 --no-focus
  assert_success
  assert_output "$(<"$TREE_WORK/tab.json")"

  run tree_wrapper_fixture_run "$HERDR_WRAPPER" workspace create --cwd "$TREE_WORK" --no-focus
  assert_success
  assert_output "$(<"$TREE_WORK/workspace.json")"

  run tree_wrapper_fixture_run "$TREE_CLI" --json
  assert_success
  local overall_json="$output"
  run python3 - "$overall_json" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
creator = {
    "agent": "opencode",
    "kind": "id",
    "source": "herdr:opencode",
    "value": "session-caller",
}
workspaces = {workspace["id"]: workspace for workspace in tree["workspaces"]}
existing = workspaces["w1"]
created_workspace = workspaces["w2"]
tabs = {tab["id"]: tab for tab in existing["tabs"]}
created_tab = tabs["w1:t2"]
assert existing["creator_session"] is None
assert tabs["w1:t1"]["creator_session"] is None
assert created_tab["creator_session"] == creator
assert {pane["id"]: pane["creator_session"] for pane in created_tab["panes"]} == {
    "w1:p4": creator,
    "w1:p5": None,
}
assert created_workspace["creator_session"] == creator
assert created_workspace["tabs"][0]["creator_session"] == creator
assert {pane["id"]: pane["creator_session"] for pane in created_workspace["tabs"][0]["panes"]} == {
    "w2:p1": creator,
    "w2:p2": None,
}
assert created_workspace["label"] is None
assert created_workspace["tabs"][0]["label"] is None
PY
  assert_success

  run tree_wrapper_fixture_run "$TREE_CLI" --branch --json
  assert_success
  local branch_json="$output"
  run python3 - "$branch_json" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
workspaces = {workspace["id"]: workspace for workspace in tree["workspaces"]}
assert set(workspaces) == {"w1", "w2"}
assert [tab["id"] for tab in workspaces["w1"]["tabs"]] == ["w1:t2"]
assert [pane["id"] for pane in workspaces["w1"]["tabs"][0]["panes"]] == ["w1:p4"]
assert [tab["id"] for tab in workspaces["w2"]["tabs"]] == ["w2:t1"]
assert [pane["id"] for pane in workspaces["w2"]["tabs"][0]["panes"]] == ["w2:p1"]
PY
  assert_success

  run python3 - "$TREE_CALLS" <<'PY'
import sys

calls = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert sum(call.startswith("tab create ") for call in calls) == 1
assert sum(call.startswith("workspace create ") for call in calls) == 1
assert all("HERDR_RESOURCE_OPERATION_ID=" in call for call in calls if call.startswith(("tab create ", "workspace create ")))
PY
  assert_success
}

function test_resource_tree_013_composite_creation_failures_preserve_partial_success() {
  _bats_test_init 13 'composite creation failures preserve partial success'
  tree_install_managed_creation_stub

  local blocked_state="$TREE_WORK/state-blocker/child"
  : > "$TREE_WORK/state-blocker"
  HERDR_RESOURCE_TREE_STATE_DIR="$blocked_state" run --separate-stderr \
    tree_wrapper_fixture_run "$HERDR_WRAPPER" tab create --workspace w1
  assert_failure 69
  assert_output ''
  assert_stderr --partial 'intent recording failed; native creation was not called'

  TREE_NATIVE_FAIL_KIND=tab run --separate-stderr \
    tree_wrapper_fixture_run "$HERDR_WRAPPER" tab create --workspace w1
  assert_failure 23
  assert_output 'native tab stdout'
  assert_equal "$stderr" 'native tab stderr'

  HERDR_RESOURCE_TREE_TEST_FAIL_FINALIZE=1 run --separate-stderr \
    tree_wrapper_fixture_run "$HERDR_WRAPPER" workspace create --cwd "$TREE_WORK"
  assert_failure 70
  assert_output "$(<"$TREE_WORK/workspace.json")"
  # One whole-line match, UUID wildcarded: the operation id is random, every
  # other field is the fixture's own input. Split into per-field partials the
  # block could lose a coordinate, reorder them, or carry a different detail
  # and still pass -- and workspace_created/tab_created were asserted by
  # nothing at all.
  assert_stderr --regexp '^herdr wrapper: creation operation [0-9a-f-]{36} workspace_id=w2 tab_id=w2:t1 pane_id=w2:p1 terminal_id=term-6 workspace_created=1 tab_created=1 succeeded, but provenance finalization failed: injected finalization failure; created resources remain open and automatic creation retry is unsafe; do not retry creation$'

  cat > "$TREE_WORK/tab.json" <<'JSON'
{"id":"cli:tab:create","result":{"type":"tab_created","tab":{"workspace_id":"w1","tab_id":"w1:t2"},"root_pane":{"workspace_id":"wrong-workspace","tab_id":"w1:t2","pane_id":"w1:p4","terminal_id":"term-5"}}}
JSON
  run --separate-stderr tree_wrapper_fixture_run \
    "$HERDR_WRAPPER" tab create --workspace w1
  assert_failure 70
  assert_output "$(<"$TREE_WORK/tab.json")"
  assert_stderr --regexp '^herdr wrapper: creation operation [0-9a-f-]{36} workspace_id=w1 tab_id=w1:t2 pane_id=w1:p4 terminal_id=term-5 succeeded, but provenance finalization failed: created pane workspace_id does not match returned container; created resources remain open and automatic creation retry is unsafe; do not retry creation$'

  cat > "$TREE_WORK/workspace.json" <<'JSON'
{"id":"cli:workspace:create","result":{"type":"workspace_created","workspace":{"workspace_id":"w2"},"tab":{"workspace_id":"w2","tab_id":"w2:t1"},"root_pane":{"workspace_id":"w2","tab_id":"wrong-tab","pane_id":"w2:p1","terminal_id":"term-6"}}}
JSON
  run --separate-stderr tree_wrapper_fixture_run \
    "$HERDR_WRAPPER" workspace create --cwd "$TREE_WORK"
  assert_failure 70
  assert_output "$(<"$TREE_WORK/workspace.json")"
  assert_stderr --regexp '^herdr wrapper: creation operation [0-9a-f-]{36} workspace_id=w2 tab_id=w2:t1 pane_id=w2:p1 terminal_id=term-6 succeeded, but provenance finalization failed: created pane tab_id does not match returned container; created resources remain open and automatic creation retry is unsafe; do not retry creation$'

  run python3 - "$TREE_CALLS" <<'PY'
import sys

calls = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert sum(call.startswith("tab create ") for call in calls) == 2
assert sum(call.startswith("workspace create ") for call in calls) == 2
PY
  assert_success
}

function test_resource_tree_014_real_agent_composite_creations_are_attributed_and_cleaned_up() {
  _bats_test_init 14 'real Agent composite creations are attributed and cleaned up'
  resource_tree_require_real_herdr

  TREE_LIVE_HERDR="$(command -v herdr)"
  run "$TREE_WORK/run-bounded" "$TREE_LIVE_HERDR" pane current --current
  if [[ "$status" -ne 0 ]]; then
    skip "real Herdr returned no current pane: $output"
  fi
  local current_json="$output"
  run python3 - "$current_json" <<'PY'
import json
import sys

pane = json.loads(sys.argv[1])["result"]["pane"]
session = pane.get("agent_session")
if not pane.get("agent") or not isinstance(session, dict):
    raise SystemExit(77)
for key in ("agent", "kind", "source", "value"):
    assert isinstance(session.get(key), str) and session[key]
print(pane["workspace_id"])
PY
  if [[ "$status" -eq 77 ]]; then
    skip 'the current real Herdr pane has no native Agent session identity'
  fi
  assert_success
  local current_workspace="$output"

  run --separate-stderr "$TREE_WORK/run-bounded" env HERDR_BIN_PATH="$TREE_LIVE_HERDR" \
    HERDR_RESOURCE_TREE_STATE_DIR="$TREE_WORK/live-state" \
    PATH="$(dirname "$HERDR_WRAPPER"):$PATH" \
    "$HERDR_WRAPPER" tab create --workspace "$current_workspace" --no-focus
  assert_success
  local tab_json="$output"
  run python3 - "$tab_json" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])["result"]
print(result["tab"]["tab_id"])
PY
  assert_success
  TREE_LIVE_TAB="$output"

  run --separate-stderr "$TREE_WORK/run-bounded" env HERDR_BIN_PATH="$TREE_LIVE_HERDR" \
    HERDR_RESOURCE_TREE_STATE_DIR="$TREE_WORK/live-state" \
    PATH="$(dirname "$HERDR_WRAPPER"):$PATH" \
    "$HERDR_WRAPPER" workspace create --cwd "$TREE_WORK" --no-focus
  assert_success
  local workspace_json="$output"
  run python3 - "$workspace_json" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])["result"]
print(result["workspace"]["workspace_id"])
PY
  assert_success
  TREE_LIVE_WORKSPACE="$output"

  run env HERDR_BIN_PATH="$TREE_LIVE_HERDR" \
    HERDR_RESOURCE_TREE_STATE_DIR="$TREE_WORK/live-state" \
    PATH="$(dirname "$HERDR_WRAPPER"):$PATH" "$TREE_CLI" --branch --json
  assert_success
  local branch_json="$output"
  run python3 - "$branch_json" "$tab_json" "$workspace_json" "$current_json" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
tab_result = json.loads(sys.argv[2])["result"]
workspace_result = json.loads(sys.argv[3])["result"]
session = json.loads(sys.argv[4])["result"]["pane"]["agent_session"]
workspaces = {workspace["id"]: workspace for workspace in tree["workspaces"]}

tab_workspace = workspaces[tab_result["tab"]["workspace_id"]]
tab = next(tab for tab in tab_workspace["tabs"] if tab["id"] == tab_result["tab"]["tab_id"])
assert tab["creator_session"] == session
assert [pane["id"] for pane in tab["panes"]] == [tab_result["root_pane"]["pane_id"]]
assert tab["panes"][0]["creator_session"] == session

workspace = workspaces[workspace_result["workspace"]["workspace_id"]]
assert workspace["creator_session"] == session
assert [tab["id"] for tab in workspace["tabs"]] == [workspace_result["tab"]["tab_id"]]
assert workspace["tabs"][0]["creator_session"] == session
assert [pane["id"] for pane in workspace["tabs"][0]["panes"]] == [workspace_result["root_pane"]["pane_id"]]
assert workspace["tabs"][0]["panes"][0]["creator_session"] == session
PY
  assert_success

  run "$TREE_WORK/run-bounded" "$TREE_LIVE_HERDR" tab close "$TREE_LIVE_TAB"
  assert_success
  TREE_LIVE_TAB=""
  run "$TREE_WORK/run-bounded" "$TREE_LIVE_HERDR" workspace close "$TREE_LIVE_WORKSPACE"
  assert_success
  TREE_LIVE_WORKSPACE=""
}

function test_resource_tree_015_managed_parentage_drives_descendant_branches_without_claiming_occupants() {
  _bats_test_init 15 'managed parentage drives descendant branches without claiming occupants'
  tree_install_managed_creation_stub

  cat > "$TREE_WORK/created-snapshot.json" <<'JSON'
{"id":"cli:api:snapshot","result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"workspaces":[{"workspace_id":"w1","number":1,"label":"Project"}],"tabs":[{"workspace_id":"w1","tab_id":"w1:t1","number":1,"label":"Agents"}],"panes":[{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pA","label":"parent","terminal_id":"term-A"},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pB","label":"child-b","terminal_id":"term-B"},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pC","label":"child-c","terminal_id":"term-C"},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pD","label":"c-server","terminal_id":"term-D"},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pS","label":"sibling","terminal_id":"term-S"},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pX","label":"manual-occupant","terminal_id":"term-X"},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pY","label":"unrelated-child","terminal_id":"term-Y"}],"agents":[{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pA","terminal_id":"term-A","agent":"claude","name":"agent-a","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"session-A"}},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pB","terminal_id":"term-B","agent":"opencode","name":"agent-b","agent_session":{"agent":"opencode","kind":"id","source":"herdr:opencode","value":"session-B"}},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pC","terminal_id":"term-C","agent":"pi","name":"agent-c","agent_session":{"agent":"pi","kind":"id","source":"herdr:pi","value":"session-C"}},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pS","terminal_id":"term-S","agent":"claude","name":"agent-s","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"session-S"}},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pX","terminal_id":"term-X","agent":"opencode","name":"agent-x","agent_session":{"agent":"opencode","kind":"id","source":"herdr:opencode","value":"session-X"}},{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pY","terminal_id":"term-Y","agent":"claude","name":"agent-y","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"session-Y"}}]}}}
JSON

  local parent child pane terminal client child_client child_name child_session_json
  while IFS=$'\t' read -r parent child pane terminal; do
    case "$parent" in
      A | S | Y) client=claude ;;
      B | X) client=opencode ;;
      C) client=pi ;;
    esac
    cat > "$TREE_WORK/caller.json" <<JSON
{"id":"cli:pane:current","result":{"type":"pane_current","pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p$parent","terminal_id":"term-$parent","agent":"$client","agent_session":{"agent":"$client","kind":"id","source":"herdr:$client","value":"session-$parent"}}}}
JSON
    cat > "$TREE_WORK/split.json" <<JSON
{"id":"cli:pane:split","result":{"type":"pane_split","pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"$pane","terminal_id":"$terminal","focused":false,"agent_status":"unknown","revision":1}}}
JSON
    run tree_wrapper_fixture_run "$HERDR_WRAPPER" pane split --pane "w1:p$parent"
    assert_success
    if [ "$child" != - ]; then
      case "$child" in
        A | S | Y) child_client=claude ;;
        B | X) child_client=opencode ;;
        C) child_client=pi ;;
      esac
      child_name="agent-$(printf '%s' "$child" | tr '[:upper:]' '[:lower:]')"
      child_session_json="{\"agent\":\"$child_client\",\"kind\":\"id\",\"source\":\"herdr:$child_client\",\"value\":\"session-$child\"}"
      run tree_wrapper_fixture_run "$TREE_CLI" record-child \
        --pane "$pane" --terminal "$terminal" \
        --child-name "$child_name" --child-session-json "$child_session_json"
      assert_success
    fi
  done <<'CASES'
A	B	w1:pB	term-B
A	S	w1:pS	term-S
B	C	w1:pC	term-C
C	-	w1:pD	term-D
B	-	w1:pX	term-X
X	Y	w1:pY	term-Y
CASES

  cat > "$TREE_WORK/caller.json" <<'JSON'
{"id":"cli:pane:current","result":{"type":"pane_current","pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pB","terminal_id":"term-B","agent":"opencode","agent_session":{"agent":"opencode","kind":"id","source":"herdr:opencode","value":"session-B"}}}}
JSON
  run tree_wrapper_fixture_run "$TREE_CLI" --branch --json
  assert_success
  local branch_json="$output"
  run python3 - "$branch_json" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
assert tree["schema_version"] == 3
assert tree["branch"]["session"]["value"] == "session-B"
assert tree["branch"]["parent"] == {
    "presentation_name": "agent-a",
    "session": {
        "agent": "claude",
        "kind": "id",
        "source": "herdr:claude",
        "value": "session-A",
    },
}
assert [item["session"]["value"] for item in tree["branch"]["descendants"]] == ["session-C"]
panes = {
    pane["id"]: pane
    for workspace in tree["workspaces"]
    for tab in workspace["tabs"]
    for pane in tab["panes"]
}
assert set(panes) == {"w1:pC", "w1:pD", "w1:pX"}
assert panes["w1:pC"]["creator_session"]["value"] == "session-B"
assert panes["w1:pD"]["creator_session"]["value"] == "session-C"
assert panes["w1:pX"]["agent"]["presentation_name"] == "agent-x"
assert panes["w1:pX"]["agent"]["parent_session"] is None
PY
  assert_success

  cat > "$TREE_WORK/caller.json" <<'JSON'
{"id":"cli:pane:current","result":{"type":"pane_current","pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pA","terminal_id":"term-A","agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"session-A"}}}}
JSON
  run tree_wrapper_fixture_run "$TREE_CLI" --branch --json
  assert_success
  local ancestor_branch="$output"
  run python3 - "$ancestor_branch" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
assert {item["session"]["value"] for item in tree["branch"]["descendants"]} == {
    "session-B",
    "session-C",
    "session-S",
}
panes = {
    pane["id"]
    for workspace in tree["workspaces"]
    for tab in workspace["tabs"]
    for pane in tab["panes"]
}
assert panes == {"w1:pB", "w1:pC", "w1:pD", "w1:pS", "w1:pX"}
PY
  assert_success

  run python3 - "$TREE_WORK/created-snapshot.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    envelope = json.load(handle)
agents = envelope["result"]["snapshot"]["agents"]
child = next(agent for agent in agents if agent["pane_id"] == "w1:pC")
child.update(
    agent="opencode",
    name="replacement-z",
    agent_session={
        "agent": "opencode",
        "kind": "id",
        "source": "herdr:opencode",
        "value": "session-Z",
    },
)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(envelope, handle)
PY
  assert_success
  cat > "$TREE_WORK/caller.json" <<'JSON'
{"id":"cli:pane:current","result":{"type":"pane_current","pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pB","terminal_id":"term-B","agent":"opencode","agent_session":{"agent":"opencode","kind":"id","source":"herdr:opencode","value":"session-B"}}}}
JSON
  run tree_wrapper_fixture_run "$TREE_CLI" record-child \
    --pane w1:pC --terminal term-C --child-name agent-c \
    --child-session-json '{"agent":"pi","kind":"id","source":"herdr:pi","value":"session-C"}'
  assert_failure 1
  assert_output 'herdr-resource-tree: parentage verification failed: launched child identity changed before parentage recording'
  run tree_wrapper_fixture_run "$TREE_CLI" --branch --json
  assert_success
  local replacement_branch="$output"
  run python3 - "$replacement_branch" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
assert [item["session"]["value"] for item in tree["branch"]["descendants"]] == ["session-C"]
replacement = next(
    pane["agent"]
    for workspace in tree["workspaces"]
    for tab in workspace["tabs"]
    for pane in tab["panes"]
    if pane["id"] == "w1:pC"
)
assert replacement["session"]["value"] == "session-Z"
assert replacement["parent_session"] is None
PY
  assert_success

  run tree_wrapper_fixture_run "$TREE_CLI" --context \
    --caller-agent opencode --caller-session-id session-B
  assert_success
  # The client contract exposes the parent name only; the parent's native
  # identity would let an adapter reach outside the child's branch.
  # The whole projection, exactly. The fixture fixes every name and id, so
  # anything the render adds, drops, reorders or re-indents shows up here --
  # including the parent's native identity, whose absence the separate refute
  # could only claim for the one string it named.
  assert_output 'Parent agent: "agent-a"
Descendant agent: "agent-c" [herdr:pi/id/session-C]
Resources:
- workspace "Project" [w1] creator=unknown
  - tab "Agents" [w1:t1] creator=unknown
    - pane "child-c" [w1:pC] terminal=term-C creator=herdr:opencode/id/session-B
      occupant=opencode "replacement-z" session=herdr:opencode/id/session-Z parent=unknown
    - pane "c-server" [w1:pD] terminal=term-D creator=herdr:pi/id/session-C
    - pane "manual-occupant" [w1:pX] terminal=term-X creator=herdr:opencode/id/session-B
      occupant=opencode "agent-x" session=herdr:opencode/id/session-X parent=unknown'
  local expected_context="$output"

  cat > "$TREE_WORK/opencode-model-request.ts" <<'TS'
const module = await import(process.env.HRC_OPENCODE_PLUGIN!)
const hooks = await module.HerdrResourceContextPlugin({})
const system = ["base"]
await hooks["experimental.chat.system.transform"](
  { sessionID: process.argv[2], model: {} },
  { system },
)
console.log(JSON.stringify(system))
TS
  HERDR_ENV=1 HERDR_RESOURCE_CONTEXT_CLI="$TREE_CLI" \
    HRC_OPENCODE_PLUGIN="$HRC_OPENCODE_PLUGIN" \
    run tree_wrapper_fixture_run bun "$TREE_WORK/opencode-model-request.ts" session-B
  assert_success
  # The plugin's own contract is the header plus the CLI projection, unchanged.
  # Comparing against the projection asserted exactly above keeps one owner for
  # the render and still fails if the plugin drops, reorders or re-escapes it.
  run python3 - "$output" "$expected_context" <<'PY'
import json
import sys

system = json.loads(sys.argv[1])
assert system == [
    "base",
    "## Herdr Agent Resource Context (generated)\n" + sys.argv[2],
], system
PY
  assert_success

  run tree_wrapper_fixture_run "$TREE_CLI" --context \
    --caller-agent claude --caller-session-id stale-conversation
  assert_failure 1
  assert_output 'herdr-resource-tree: caller identity changed before context projection'

  HERDR_ENV=1 HERDR_RESOURCE_CONTEXT_CLI="$TREE_CLI" \
    HRC_OPENCODE_PLUGIN="$HRC_OPENCODE_PLUGIN" \
    run tree_wrapper_fixture_run bun "$TREE_WORK/opencode-model-request.ts" stale-conversation
  assert_success
  local unavailable_system="$output"
  run jq -e '
    length == 2
    and .[0] == "base"
    and (.[1] | contains("Herdr resource context unavailable"))
    and (.[1] | contains("must not be treated as an empty resource branch"))
  ' <<< "$unavailable_system"
  assert_success

  HERDR_RESOURCE_CONTEXT_MAX_CHARS=320 run tree_wrapper_fixture_run "$TREE_CLI" --context
  assert_success
  assert_output --partial 'Context truncated. Full branch: `herdr-resource-tree --branch`.'
  run python3 - "$output" <<'PY'
import sys

assert len(sys.argv[1]) <= 320
PY
  assert_success

  cat > "$TREE_WORK/caller.json" <<'JSON'
{"id":"cli:pane:current","result":{"type":"pane_current","pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pS","terminal_id":"term-S","agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"session-S"}}}}
JSON
  run tree_wrapper_fixture_run "$TREE_CLI" --context
  assert_success
  assert_output 'Parent agent: "agent-a"'

  cat > "$TREE_WORK/caller.json" <<'JSON'
{"id":"cli:pane:current","result":{"type":"pane_current","pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pB","terminal_id":"term-B","agent":"opencode","agent_session":{"agent":"opencode","kind":"id","source":"herdr:opencode","value":"session-B"}}}}
JSON
  run python3 - "$TREE_WORK/created-snapshot.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    envelope = json.load(handle)
snapshot = envelope["result"]["snapshot"]
snapshot["agents"] = [
    agent for agent in snapshot["agents"] if agent["agent_session"]["value"] != "session-A"
]
resumed = next(
    agent for agent in snapshot["agents"] if agent["agent_session"]["value"] == "session-B"
)
resumed["name"] = "renamed-b"
snapshot["panes"] = [pane for pane in snapshot["panes"] if pane["pane_id"] != "w1:pD"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(envelope, handle)
PY
  assert_success
  run tree_wrapper_fixture_run "$TREE_CLI" --branch --json
  assert_success
  local reconciled_branch="$output"
  run python3 - "$reconciled_branch" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
assert tree["branch"]["presentation_name"] == "renamed-b"
assert tree["branch"]["parent"]["session"]["value"] == "session-A"
assert tree["branch"]["descendants"] == []
PY
  assert_success
}

function test_resource_tree_016_child_launcher_records_parentage_through_the_real_shared_service() {
  _bats_test_init 16 'child launcher records parentage through the real shared service'
  local front_bin="$TREE_WORK/front-bin" native_bin="$TREE_WORK/native-bin"
  mkdir -p "$front_bin" "$native_bin"
  cat > "$front_bin/herdr" <<'SH'
#!/usr/bin/env bash
exec "$TREE_WRAPPER" "$@"
SH
  cat > "$front_bin/herdr-resource-tree" <<'SH'
#!/usr/bin/env bash
exec "$TREE_RESOURCE_CLI" "$@"
SH
  cp "$BATS_TEST_DIRNAME/helpers/herdr_alias_allocator" "$front_bin/herdr-pane-labels"
  chmod +x "$front_bin/herdr" "$front_bin/herdr-resource-tree" "$front_bin/herdr-pane-labels"

  cat > "$native_bin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%q ' "$@" >> "$TREE_CALLS"
printf '\n' >> "$TREE_CALLS"
session() {
  local client="$1" value="$2"
  printf '{"agent":"%s","kind":"id","source":"herdr:%s","value":"%s"}' "$client" "$client" "$value"
}
agent() {
  local name="$1" client="$2" tab="$3" pane="$4" terminal="$5" value="$6"
  printf '{"name":"%s","agent":"%s","workspace_id":"w1","tab_id":"%s","pane_id":"%s","terminal_id":"%s","revision":1,"state_change_seq":1,"agent_session":%s}' \
    "$name" "$client" "$tab" "$pane" "$terminal" "$value"
}
parent_session="$(session claude session-A)"
if [ "${TREE_MODE:-pane}" = tab ]; then
  child_tab=w1:t2 child_pane=w1:pT child_terminal=term-T child_value=session-T
else
  child_tab=w1:t1 child_pane=w1:pB child_terminal=term-B child_value=session-B
fi
child_session="$(session opencode "$child_value")"
started_file="$TREE_WORK/started-${TREE_MODE:-pane}"
case "${1:-}:${2:-}" in
  pane:current)
    if [ "${TREE_CURRENT:-parent}" = child ]; then
      printf '{"result":{"pane":{"workspace_id":"w1","tab_id":"%s","pane_id":"%s","terminal_id":"%s","agent":"opencode","agent_session":%s}}}\n' \
        "$child_tab" "$child_pane" "$child_terminal" "$child_session"
    else
      printf '{"result":{"pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pA","terminal_id":"term-A","agent":"claude","agent_session":%s}}}\n' "$parent_session"
    fi
    ;;
  agent:list)
    parent="$(agent agent-a claude w1:t1 w1:pA term-A "$parent_session")"
    if [ -f "$started_file" ]; then
      child="$(agent "$(cat "$started_file")" opencode "$child_tab" "$child_pane" "$child_terminal" "$child_session")"
      printf '{"result":{"agents":[%s,%s]}}\n' "$parent" "$child"
    else
      printf '{"result":{"agents":[%s]}}\n' "$parent"
    fi
    ;;
  pane:split)
    printf '{"result":{"pane":{"workspace_id":"w1","tab_id":"%s","pane_id":"%s","terminal_id":"%s"}}}\n' \
      "$child_tab" "$child_pane" "$child_terminal"
    ;;
  tab:create)
    printf '{"result":{"tab":{"workspace_id":"w1","tab_id":"%s"},"root_pane":{"workspace_id":"w1","tab_id":"%s","pane_id":"%s","terminal_id":"%s"}}}\n' \
      "$child_tab" "$child_tab" "$child_pane" "$child_terminal"
    ;;
  agent:start)
    printf '%s' "$3" > "$started_file"
    printf '{"result":{"agent":{"interactive_ready":true}}}\n'
    ;;
  pane:get)
    printf '{"result":{"pane":{"pane_id":"%s","terminal_id":"%s","agent_session":%s}}}\n' \
      "$child_pane" "$child_terminal" "$child_session"
    ;;
  pane:report-metadata)
    printf '{"result":{"type":"pane_metadata_reported"}}\n'
    ;;
  agent:prompt)
    printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    ;;
  api:snapshot)
    agents="$(agent agent-a claude w1:t1 w1:pA term-A "$parent_session")"
    tabs='{"workspace_id":"w1","tab_id":"w1:t1","number":1,"label":"Agents"}'
    if [ "${TREE_MODE:-pane}" = tab ]; then
      tabs="$tabs,{\"workspace_id\":\"w1\",\"tab_id\":\"w1:t2\",\"number\":2,\"label\":\"Child\"}"
    fi
    if [ -f "$started_file" ]; then
      child="$(agent "$(cat "$started_file")" opencode "$child_tab" "$child_pane" "$child_terminal" "$child_session")"
      agents="$agents,$child"
    fi
    printf '{"result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"workspaces":[{"workspace_id":"w1","number":1,"label":"Project"}],"tabs":[%s],"panes":[{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:pA","label":"parent","terminal_id":"term-A"},{"workspace_id":"w1","tab_id":"%s","pane_id":"%s","label":"managed-child","terminal_id":"%s"}],"agents":[%s]}}}\n' \
      "$tabs" "$child_tab" "$child_pane" "$child_terminal" "$agents"
    ;;
  *) exit 64 ;;
esac
SH
  chmod +x "$native_bin/herdr"

  run env PATH="$front_bin:$native_bin:$PATH" HERDR_ENV=1 HERDR_PANE_ID=w1:pA \
    HERDR_BIN_PATH="$native_bin/herdr" HERDR_SOCKET_PATH="$TREE_WORK/herdr.sock" \
    HERDR_RESOURCE_TREE_STATE_DIR="$TREE_WORK/integration-state" \
    HERDR_RESOURCE_TREE_CLI="$front_bin/herdr-resource-tree" \
    HERDR_CHILD_STATE_DIR="$TREE_WORK/child-state" HERDR_CHILD_COLD_INITIAL_PROMPT_DELAY=0 \
    HERDR_ALIAS_TEST_SEED=resource-tree TREE_WRAPPER="$HERDR_WRAPPER" \
    TREE_RESOURCE_CLI="$TREE_CLI" TREE_WORK="$TREE_WORK" TREE_CALLS="$TREE_CALLS" \
    bash "$HERDR_CHILD" start --kind opencode --wait --prompt 'test task'
  assert_success
  assert_output --partial '"pane":"w1:pB"'

  run env PATH="$front_bin:$native_bin:$PATH" HERDR_BIN_PATH="$native_bin/herdr" \
    HERDR_SOCKET_PATH="$TREE_WORK/herdr.sock" \
    HERDR_RESOURCE_TREE_STATE_DIR="$TREE_WORK/integration-state" \
    TREE_WRAPPER="$HERDR_WRAPPER" TREE_RESOURCE_CLI="$TREE_CLI" \
    TREE_WORK="$TREE_WORK" TREE_CALLS="$TREE_CALLS" "$TREE_CLI" --branch --json
  assert_success
  local parent_branch="$output"
  run python3 - "$parent_branch" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
assert [item["session"]["value"] for item in tree["branch"]["descendants"]] == ["session-B"]
pane = tree["workspaces"][0]["tabs"][0]["panes"][0]
assert pane["id"] == "w1:pB"
assert pane["creator_session"]["value"] == "session-A"
assert pane["agent"]["parent_session"]["value"] == "session-A"
PY
  assert_success

  run env PATH="$front_bin:$native_bin:$PATH" HERDR_BIN_PATH="$native_bin/herdr" \
    HERDR_SOCKET_PATH="$TREE_WORK/herdr.sock" TREE_CURRENT=child \
    HERDR_RESOURCE_TREE_STATE_DIR="$TREE_WORK/integration-state" \
    TREE_WRAPPER="$HERDR_WRAPPER" TREE_RESOURCE_CLI="$TREE_CLI" \
    TREE_WORK="$TREE_WORK" TREE_CALLS="$TREE_CALLS" "$TREE_CLI" --branch --json
  assert_success
  local child_branch="$output"
  run python3 - "$child_branch" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
assert tree["workspaces"] == []
assert tree["branch"]["session"]["value"] == "session-B"
assert tree["branch"]["parent"]["presentation_name"] == "agent-a"
assert tree["branch"]["parent"]["session"]["value"] == "session-A"
PY
  assert_success

  run env PATH="$front_bin:$native_bin:$PATH" HERDR_ENV=1 HERDR_PANE_ID=w1:pA \
    HERDR_WORKSPACE_ID=w1 HERDR_BIN_PATH="$native_bin/herdr" \
    HERDR_SOCKET_PATH="$TREE_WORK/herdr.sock" TREE_MODE=tab \
    HERDR_RESOURCE_TREE_STATE_DIR="$TREE_WORK/integration-tab-state" \
    HERDR_RESOURCE_TREE_CLI="$front_bin/herdr-resource-tree" \
    HERDR_CHILD_STATE_DIR="$TREE_WORK/child-tab-state" HERDR_CHILD_COLD_INITIAL_PROMPT_DELAY=0 \
    HERDR_ALIAS_TEST_SEED=resource-tree-tab TREE_WRAPPER="$HERDR_WRAPPER" \
    TREE_RESOURCE_CLI="$TREE_CLI" TREE_WORK="$TREE_WORK" TREE_CALLS="$TREE_CALLS" \
    bash "$HERDR_CHILD" start --kind opencode --tab --wait --prompt 'test tab task'
  assert_success
  assert_output --partial '"pane":"w1:pT"'
  assert_output --partial '"tab":"w1:t2"'

  run env PATH="$front_bin:$native_bin:$PATH" HERDR_BIN_PATH="$native_bin/herdr" \
    HERDR_SOCKET_PATH="$TREE_WORK/herdr.sock" TREE_MODE=tab \
    HERDR_RESOURCE_TREE_STATE_DIR="$TREE_WORK/integration-tab-state" \
    TREE_WRAPPER="$HERDR_WRAPPER" TREE_RESOURCE_CLI="$TREE_CLI" \
    TREE_WORK="$TREE_WORK" TREE_CALLS="$TREE_CALLS" "$TREE_CLI" --branch --json
  assert_success
  local tab_branch="$output"
  run python3 - "$tab_branch" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
assert [item["session"]["value"] for item in tree["branch"]["descendants"]] == ["session-T"]
tab = tree["workspaces"][0]["tabs"][0]
assert tab["id"] == "w1:t2"
assert tab["creator_session"]["value"] == "session-A"
assert [pane["id"] for pane in tab["panes"]] == ["w1:pT"]
assert tab["panes"][0]["creator_session"]["value"] == "session-A"
assert tab["panes"][0]["agent"]["parent_session"]["value"] == "session-A"
PY
  assert_success
}

function test_resource_tree_017_query_rejects_a_server_scope_change_during_snapshot() {
  _bats_test_init 17 'query rejects a server scope change during snapshot'

  local ready="$TREE_WORK/snapshot.ready" release="$TREE_WORK/snapshot.release"
  env PATH="$TREE_BIN:$PATH" TREE_CALLS="$TREE_CALLS" \
    HERDR_BIN_PATH="$TREE_BIN/herdr" \
    HERDR_RESOURCE_TREE_STATE_DIR="$TREE_WORK/state" \
    HERDR_SOCKET_PATH="$TREE_WORK/herdr.sock" TREE_SNAPSHOT="$TREE_WORK/snapshot.json" \
    TREE_STUB_MODE=scope-changing TREE_SNAPSHOT_READY="$ready" \
    TREE_SNAPSHOT_RELEASE="$release" "$TREE_CLI" --json \
    > "$TREE_WORK/scope.out" 2> "$TREE_WORK/scope.err" &
  local query_pid=$!
  tree_wait_for_file "$ready"
  rm "$TREE_WORK/herdr.sock"
  : > "$TREE_WORK/herdr.sock"
  : > "$release"
  local scope_status=0
  wait "$query_pid" || scope_status=$?
  assert_equal "$scope_status" 1
  # Any broken query writes to stderr. Only this line says the CLI noticed the
  # socket identity change rather than failing for some unrelated reason.
  assert_equal "$(<"$TREE_WORK/scope.err")" \
    'herdr-resource-tree: provenance lookup failed: server identity changed during snapshot retrieval'
  assert_file_not_contains "$TREE_WORK/scope.out" '"workspaces"'
}

function test_resource_tree_018_a_cold_restore_drops_attribution_from_the_previous_server() {
  _bats_test_init 18 'a cold restore drops attribution from the previous server'
  resource_tree_require_real_herdr

  TREE_SOCKET="$BATS_RUN_TMPDIR/htr-restore-$BATS_TEST_NUMBER.sock"
  mkdir -p "$TREE_WORK/config/herdr" "$TREE_WORK/runtime" "$TREE_WORK/home" \
    "$TREE_WORK/restore-bin" "$TREE_WORK/restore-state"
  cat > "$TREE_WORK/config/herdr/config.toml" <<'TOML'
onboarding = false
[terminal]
default_shell = "/bin/sh"
TOML

  # The disposable server's panes run /bin/sh, so no pane carries a native Agent
  # session and the wrapper would refuse to record a creator. This shim answers
  # only `pane current` with the real root pane plus a grafted Agent identity and
  # forwards every other call, so the creation and the queries below still go to
  # the real server. It drops HERDR_BIN_PATH on the way: the native binary re-execs
  # that path itself, which would send it straight back into this shim.
  cat > "$TREE_WORK/restore-bin/herdr" <<'SH'
#!/usr/bin/env bash
unset HERDR_BIN_PATH
if [[ "${1:-}" == pane && "${2:-}" == current ]]; then
  exec python3 - "$TREE_RESTORE_NATIVE" <<'PY'
import json
import subprocess
import sys

completed = subprocess.run(
    [sys.argv[1], "api", "snapshot"], capture_output=True, text=True, check=True
)
pane = json.loads(completed.stdout)["result"]["snapshot"]["panes"][0]
print(
    json.dumps(
        {
            "id": "cli:pane:current",
            "result": {
                "type": "pane_current",
                "pane": {
                    "workspace_id": pane["workspace_id"],
                    "tab_id": pane["tab_id"],
                    "pane_id": pane["pane_id"],
                    "terminal_id": pane["terminal_id"],
                    "agent": "claude",
                    "agent_session": {
                        "agent": "claude",
                        "kind": "id",
                        "source": "herdr:claude",
                        "value": "session-before-restore",
                    },
                },
            },
        }
    )
)
PY
fi
exec "$TREE_RESTORE_NATIVE" "$@"
SH
  chmod +x "$TREE_WORK/restore-bin/herdr"

  local native_herdr
  native_herdr="$(command -v herdr)"

  if ! tree_start_real_server \
    "$TREE_WORK/server.log" "$TREE_WORK/server-before-restore.exit"; then
    fail "disposable Herdr server did not create $TREE_SOCKET: $(<"$TREE_WORK/server.log")"
    return 1
  fi

  run tree_real_env herdr workspace create --cwd "$TREE_WORK/home" --label restore-probe
  assert_success
  run tree_real_env "$TREE_WORK/run-bounded" herdr api snapshot
  assert_success
  run python3 - "$output" <<'PY'
import json
import sys

panes = json.loads(sys.argv[1])["result"]["snapshot"]["panes"]
assert len(panes) == 1, panes
print(panes[0]["pane_id"])
PY
  assert_success
  local root_pane="$output"

  run tree_restore_managed_env "$native_herdr" \
    "$HERDR_WRAPPER" pane split --pane "$root_pane" --direction right --no-focus
  assert_success
  run python3 - "$output" <<'PY'
import json
import sys

print(json.loads(sys.argv[1])["result"]["pane"]["pane_id"])
PY
  assert_success
  local created_pane="$output"

  # Control: the attribution really exists on this server, so the absence
  # asserted after the restore is a dropped record and not a missing one.
  run tree_restore_managed_env "$native_herdr" "$TREE_CLI" --json
  assert_success
  run python3 - "$output" "$root_pane" "$created_pane" <<'PY'
import json
import sys

tree, root, created = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
panes = {
    pane["id"]: pane
    for workspace in tree["workspaces"]
    for tab in workspace["tabs"]
    for pane in tab["panes"]
}
assert set(panes) == {root, created}, sorted(panes)
assert panes[root]["creator_session"] is None
assert panes[created]["creator_session"] == {
    "agent": "claude",
    "kind": "id",
    "source": "herdr:claude",
    "value": "session-before-restore",
}
PY
  assert_success

  run tree_real_env "$TREE_WORK/run-bounded" herdr server stop
  assert_success
  tree_wait_for_file "$TREE_SERVER_EXIT"
  if ! wait "$TREE_SERVER_PID"; then
    fail 'disposable Herdr server exited unsuccessfully before restore'
    return 1
  fi
  TREE_SERVER_PID=""
  rm -f "$TREE_SOCKET"

  if ! tree_start_real_server \
    "$TREE_WORK/restored-server.log" "$TREE_WORK/server-after-restore.exit"; then
    fail "restored Herdr server did not create $TREE_SOCKET: $(<"$TREE_WORK/restored-server.log")"
    return 1
  fi

  run tree_restore_managed_env "$native_herdr" "$TREE_CLI" --json
  assert_success
  run python3 - "$output" "$root_pane" "$created_pane" <<'PY'
import json
import sys

tree, root, created = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
panes = {
    pane["id"]: pane
    for workspace in tree["workspaces"]
    for tab in workspace["tabs"]
    for pane in tab["panes"]
}
# The restored server reuses the pane ids, so an attribution that outlived the
# restart would reappear here rather than simply vanish with the resource.
assert set(panes) == {root, created}, sorted(panes)
assert panes[created]["creator_session"] is None, panes[created]
assert panes[root]["creator_session"] is None, panes[root]
PY
  assert_success

  run tree_real_env "$TREE_WORK/run-bounded" herdr server stop
  assert_success
  tree_wait_for_file "$TREE_SERVER_EXIT"
  if ! wait "$TREE_SERVER_PID"; then
    fail 'restored disposable Herdr server exited unsuccessfully'
    return 1
  fi
  TREE_SERVER_PID=""
}

function test_resource_tree_019_signal_terminated_creation_remains_unresolved() {
  _bats_test_init 19 'signal-terminated creation remains unresolved'
  tree_install_managed_creation_stub

  TREE_NATIVE_SIGNAL=1 run --separate-stderr \
    tree_wrapper_fixture_run "$HERDR_WRAPPER" pane split --pane w1:p2
  assert_failure 143
  assert_output ''
  assert_stderr --regexp '^herdr wrapper: creation operation [0-9a-f-]{36} may have created a resource, but no recoverable response is available: native creation terminated by signal 15; automatic creation retry is unsafe; do not retry creation$'

  run tree_wrapper_fixture_run "$TREE_CLI" --json
  assert_success
  local uncertain_tree="$output"
  run python3 - "$uncertain_tree" "$TREE_CALLS" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
assert len(tree["unresolved_operations"]) == 1
operation = tree["unresolved_operations"][0]
assert operation["creation_kind"] == "pane"
assert operation["reason"] == "native creation terminated by signal 15"
assert operation["known_resources"] == {}
created = next(
    pane
    for workspace in tree["workspaces"]
    for tab in workspace["tabs"]
    for pane in tab["panes"]
    if pane["id"] == "w1:p3"
)
assert created["creator_session"] is None
calls = open(sys.argv[2], encoding="utf-8").read().splitlines()
assert sum(call.startswith("pane split") for call in calls) == 1
PY
  assert_success
}

function test_resource_tree_020_empty_path_entry_does_not_resolve_the_working_directory() {
  _bats_test_init 20 'empty PATH entry does not resolve the working directory'

  cat > "$TREE_BIN/herdr" <<'SH'
#!/usr/bin/env bash
printf 'native\n'
SH
  chmod +x "$TREE_BIN/herdr"

  local trap_dir="$TREE_WORK/checkout"
  mkdir -p "$trap_dir"
  cat > "$trap_dir/herdr" <<'SH'
#!/usr/bin/env bash
printf 'checkout trap\n'
SH
  chmod +x "$trap_dir/herdr"

  # A leading empty PATH entry means the current directory to a POSIX shell.
  # The wrapper runs wherever the agent works, so a herdr committed to a
  # repository must never win resolution.
  run env HERDR_BIN_PATH="$HERDR_WRAPPER" PATH=":$TREE_BIN:$PATH" \
    bash -c 'cd "$1" && exec "$2" status client' _ "$trap_dir" "$HERDR_WRAPPER"
  assert_success
  assert_output 'native'

  # Control: named explicitly ahead of the native directory, the same binary in
  # the same directory does win, so the assertion above cannot pass by failing
  # to resolve anything.
  run env HERDR_BIN_PATH="$HERDR_WRAPPER" PATH="$trap_dir:$TREE_BIN:$PATH" \
    bash -c 'cd "$1" && exec "$2" status client' _ "$trap_dir" "$HERDR_WRAPPER"
  assert_success
  assert_output 'checkout trap'
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function set_up_before_script() {
  :
}

function tear_down() { _bats_run_teardown; }

function test_resource_tree_021_a_read_only_registry_still_answers_queries() {
  _bats_test_init 21 'a read-only registry still answers queries'

  tree_install_managed_creation_stub
  run tree_wrapper_fixture_run "$HERDR_WRAPPER" pane split --pane w1:p2 --direction right
  assert_success

  # A query writes nothing. Answering one inside a write transaction makes the
  # whole projection unavailable on a registry the process cannot write, and
  # serializes every concurrent query against every creation.
  chmod 0444 "$TREE_WORK/state/registry.sqlite3"
  run tree_wrapper_fixture_run "$TREE_CLI" --json
  chmod 0600 "$TREE_WORK/state/registry.sqlite3"
  assert_success
  local read_only_json="$output"
  run python3 - "$read_only_json" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
created = next(
    pane
    for workspace in tree["workspaces"]
    for tab in workspace["tabs"]
    for pane in tab["panes"]
    if pane["id"] == "w1:p3"
)
assert created["creator_session"]["value"] == "session-caller", created
PY
  assert_success
}

function test_resource_tree_022_a_pane_occupancy_change_during_the_snapshot_fails_the_query() {
  _bats_test_init 22 'a pane occupancy change during the snapshot fails the query'

  tree_install_managed_creation_stub
  # Identity is sampled on both sides of the snapshot it authenticates. This
  # stub hands out the original occupant first and a replacement afterwards.
  cat > "$TREE_BIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TREE_CALLS"
seen="$TREE_CALLS.caller-seen"
case "${1:-}:${2:-}" in
  pane:current)
    if [[ -e "$seen" ]]; then
      cat "$TREE_CALLER_NEXT"
    else
      : > "$seen"
      cat "$TREE_CALLER"
    fi
    ;;
  api:snapshot) cat "$TREE_CREATED_SNAPSHOT" ;;
  *) printf 'unexpected native command: %s\n' "$*" >&2; exit 64 ;;
esac
SH
  chmod +x "$TREE_BIN/herdr"

  cat > "$TREE_WORK/caller-next.json" <<'JSON'
{"id":"cli:pane:current","result":{"type":"pane_current","pane":{"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","terminal_id":"term-1","agent":"opencode","agent_session":{"agent":"opencode","kind":"id","source":"herdr:opencode","value":"session-replacement"}}}}
JSON

  TREE_CALLER_NEXT="$TREE_WORK/caller-next.json" \
    run tree_wrapper_fixture_run "$TREE_CLI" --branch --json
  assert_failure 1
  assert_output 'herdr-resource-tree: caller identity changed during snapshot retrieval'

  # Control: the same fixture with a stable occupant must reach the branch, so
  # the rejection above cannot pass by never projecting at all.
  rm -f "$TREE_CALLS.caller-seen"
  TREE_CALLER_NEXT="$TREE_WORK/caller.json" \
    run tree_wrapper_fixture_run "$TREE_CLI" --branch --json
  assert_success
  # The control has to reach a branch for the stable occupant: the bare token
  # '"branch"' also appears in a projection that resolved to null.
  run python3 - "$output" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
assert tree["branch"]["session"]["value"] == "session-caller", tree["branch"]
PY
  assert_success
}
