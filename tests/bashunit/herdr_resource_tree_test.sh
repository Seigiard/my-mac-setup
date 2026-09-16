#!/usr/bin/env bash
# post-apply: 18 host-safe
# Public contract tests for the read-only Herdr resource-tree CLI.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/common'

TREE_CLI="$SOURCE_ROOT/dot_local/bin/executable_herdr-resource-tree"

setup() {
  TREE_WORK="$BATS_TEST_TMPDIR/resource-tree"
  TREE_BIN="$TREE_WORK/bin"
  TREE_CALLS="$TREE_WORK/herdr.calls"
  TREE_SERVER_PID=""
  mkdir -p "$TREE_BIN"

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
esac
SH
  chmod +x "$TREE_BIN/herdr"
}

tree_stub_run() {
  env PATH="$TREE_BIN:$PATH" TREE_CALLS="$TREE_CALLS" \
    TREE_SNAPSHOT="$TREE_WORK/snapshot.json" \
    TREE_DESCENDANT_PID="${TREE_DESCENDANT_PID:-}" \
    TREE_STUB_MODE="${TREE_STUB_MODE:-valid}" "$TREE_CLI" "$@"
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

teardown() {
  if [[ -n "${TREE_SERVER_PID:-}" ]] && kill -0 "$TREE_SERVER_PID" 2>/dev/null; then
    tree_real_env herdr server stop >/dev/null 2>&1 || kill -TERM "$TREE_SERVER_PID" 2>/dev/null || true
    wait "$TREE_SERVER_PID" 2>/dev/null || true
  fi
}

function test_resource_tree_001_human_and_json_views_share_the_complete_fixture_tree() {
  _bats_test_init 1 'human and JSON views share the complete fixture tree'

  run tree_stub_run
  assert_success
  assert_output --partial 'workspace "Project" [w1]'
  assert_output --partial 'tab "Agents" [w1:t1]'
  assert_output --partial 'pane "implementation" [w1:p1]'
  assert_output --partial 'terminal: term-1'
  assert_output --partial 'agent: opencode "red-fox"'
  assert_output --partial 'session: herdr:opencode/id/session-1'
  assert_output --partial 'creator: unknown'
  assert_output --partial 'tab "Shells" [w1:t2]'
  assert_output --partial 'pane "logs" [w1:p2]'
  assert_output --partial 'terminal: term-2'
  assert_output --partial 'workspace "Unrelated" [w2]'
  assert_output --partial 'tab "Elsewhere" [w2:t1]'
  assert_output --partial 'pane "manual" [w2:p1]'
  assert_output --partial 'terminal: term-3'
  assert_output --partial 'session: unknown'
  assert_output --partial 'parent: unknown'

  run tree_stub_run --json
  assert_success
  local tree_json="$output"
  run python3 - "$tree_json" <<'PY'
import json
import sys

tree = json.loads(sys.argv[1])
assert tree["schema_version"] == 1
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
  assert_output --partial 'herdr-resource-tree: snapshot retrieval failed: socket unavailable'
  refute_output --partial '"workspaces": []'

  TREE_STUB_MODE=malformed run tree_stub_run --json
  assert_failure
  assert_output --partial 'herdr-resource-tree: malformed snapshot:'
  refute_output --partial '"workspaces": []'

  TREE_DESCENDANT_PID="$TREE_WORK/descendant.pid" TREE_STUB_MODE=hanging \
    run tree_stub_run --json
  assert_failure 124
  assert_output --partial 'snapshot retrieval failed: herdr api snapshot timed out after 10 seconds'
  local descendant_pid
  descendant_pid="$(<"$TREE_WORK/descendant.pid")"
  if kill -0 "$descendant_pid" 2>/dev/null; then
    fail "snapshot timeout left descendant $descendant_pid running"
    return 1
  fi
}

function test_resource_tree_003_real_herdr_snapshot_populates_a_disposable_server_tree() {
  _bats_test_init 3 'real Herdr snapshot populates a disposable server tree'
  command_exists herdr || skip 'herdr is not installed, so the native snapshot oracle is unavailable'

  TREE_SOCKET="$BATS_RUN_TMPDIR/htr-$BATS_TEST_NUMBER.sock"
  mkdir -p "$TREE_WORK/config/herdr" "$TREE_WORK/runtime" "$TREE_WORK/home"
  cat > "$TREE_WORK/config/herdr/config.toml" <<'TOML'
onboarding = false
[terminal]
default_shell = "/bin/sh"
TOML

  (
    tree_close_inherited_descriptors
    tree_real_env herdr server
  ) < /dev/null > "$TREE_WORK/server.log" 2>&1 &
  TREE_SERVER_PID=$!
  local ready=0 attempt=0
  while [[ "$attempt" -lt 100 ]]; do
    if [[ -S "$TREE_SOCKET" ]]; then
      ready=1
      break
    fi
    if ! kill -0 "$TREE_SERVER_PID" 2>/dev/null; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 0.05
  done
  if [[ "$ready" -ne 1 ]]; then
    fail "disposable Herdr server did not create $TREE_SOCKET: $(<"$TREE_WORK/server.log")"
    return 1
  fi

  run tree_real_env herdr workspace create --cwd "$TREE_WORK/home" --label disposable-resource-tree
  assert_success

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
assert len(workspace["tabs"][0]["panes"]) == 1
pane = workspace["tabs"][0]["panes"][0]
assert pane["terminal_id"].startswith("term_")
assert pane["creator_session"] is None
assert pane["agent"] is None
PY
  assert_success

  run tree_real_env herdr server stop
  assert_success
  if ! wait "$TREE_SERVER_PID"; then
    fail 'disposable Herdr server exited unsuccessfully after stop'
    return 1
  fi
  TREE_SERVER_PID=""
}

function test_resource_tree_004_agent_fixture_matches_the_installed_herdr_boundary() {
  _bats_test_init 4 'agent fixture matches the installed Herdr boundary'
  command_exists herdr || skip 'herdr is not installed, so the native agent oracle is unavailable'

  run python3 - <<'PY'
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
    raise SystemExit(process.returncode)
sys.stdout.write(stdout)
PY
  if [[ "$status" -ne 0 ]]; then
    skip "real Herdr returned no snapshot: $output"
  fi
  local real_snapshot="$output"
  run python3 - "$real_snapshot" "$TREE_WORK/snapshot.json" <<'PY'
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
PY
  if [[ "$status" -eq 77 ]]; then
    skip 'the running Herdr server has no agent with a native session identity'
  fi
  assert_success
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function set_up_before_script() {
  :
}

function tear_down() { _bats_run_teardown; }
