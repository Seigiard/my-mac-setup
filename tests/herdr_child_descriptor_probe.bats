#!/usr/bin/env bats

load 'helpers/common'

@test "herdr-child detached watcher closes launcher descriptors and owns a process group" {
  local work="$BATS_TEST_TMPDIR/herdr-child-descriptor"
  local stub="$work/bin"
  mkdir -p "$stub" "$work/tmp"
  cat > "$stub/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "agent list")
    if [ -f "$HCD_WORK/started-name" ]; then
      child="$(cat "$HCD_WORK/started-name")"
      printf '{"result":{"agents":[{"name":"parent","pane_id":"wT:p0","terminal_id":"term-parent","agent_session":{"value":"parent-session"}},{"name":"%s","pane_id":"wT:p9","terminal_id":"term-child","agent_session":{"value":"child-session"}}]}}\n' "$child"
    else
      printf '{"result":{"agents":[{"name":"parent","pane_id":"wT:p0","terminal_id":"term-parent","agent_session":{"value":"parent-session"}}]}}\n'
    fi
    ;;
  "pane split")
    printf '{"result":{"pane":{"pane_id":"wT:p9"}}}\n'
    ;;
  "agent start")
    printf '%s' "$3" > "$HCD_WORK/started-name"
    printf '{"result":{"agent":{"interactive_ready":true}}}\n'
    ;;
  "agent prompt")
    printf '{"result":{"agent":{"agent_status":"working"}}}\n'
    ;;
  "pane report-metadata")
    if printf '%s\n' "$*" | grep -q 'supervised'; then
      : > "$HCD_WORK/liveness-started"
      while [ ! -e "$HCD_WORK/release-liveness" ]; do sleep 0.01; done
    fi
    printf '{"result":{"type":"pane_metadata_reported"}}\n'
    ;;
  "pane close")
    : > "$HCD_WORK/pane-closed"
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$stub/herdr"

  run env HCD_WORK="$work" HCD_STUB="$stub" HCD_CHILD="$SOURCE_ROOT/dot_local/bin/executable_herdr-child" \
    TMPDIR="$work/tmp" \
    python3 - <<'PY'
import os
from pathlib import Path
import select
import signal
import subprocess
import time

work = Path(os.environ["HCD_WORK"])
env = os.environ.copy()
env.update({
    "PATH": os.environ["HCD_STUB"] + os.pathsep + env["PATH"],
    "HERDR_ENV": "1",
    "HERDR_PANE_ID": "wT:p0",
    "HERDR_CHILD_STATE_DIR": str(work / "state"),
    "HERDR_CHILD_TEST_WATCHER_PID_FILE": str(work / "watcher.pid"),
    "HERDR_CHILD_TEST_WATCHER_RELEASE": str(work / "release-watcher"),
})
control_read, control_write = os.pipe()
os.set_inheritable(control_write, True)
proc = subprocess.Popen(
    ["bash", os.environ["HCD_CHILD"], "start", "--kind", "claude", "--name",
     "descriptor-child", "--detach", "--prompt", "descriptor task"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=env,
    pass_fds=(control_write,),
)
os.close(control_write)

def wait_for(path, message):
    for _ in range(1000):
        if path.exists() and path.stat().st_size > 0:
            return
        time.sleep(0.01)
    raise AssertionError(message)

wait_for(work / "watcher.pid", "watcher never published its pid")
watcher_pid = int((work / "watcher.pid").read_text().strip())
for _ in range(1000):
    if (work / "liveness-started").exists():
        break
    time.sleep(0.01)
else:
    raise AssertionError("watcher never reached the blocked liveness boundary")

if proc.poll() is not None:
    raise AssertionError("launcher returned before the watcher published readiness")
launcher_pgid = os.getpgid(proc.pid)
watcher_pgid = os.getpgid(watcher_pid)
if launcher_pgid == watcher_pgid:
    raise AssertionError("watcher shares the launcher's process group")

(work / "release-liveness").touch()
try:
    stdout, stderr = proc.communicate(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
    proc.wait()
    raise AssertionError("launcher exited without output-pipe EOF; watcher retained an inherited descriptor")
if proc.returncode != 0:
    raise AssertionError("launcher failed: %s" % stderr)
if '"supervision":{"status":"armed"' not in stdout:
    raise AssertionError("launcher did not return an armed record: %s" % stdout)
readable, _, _ = select.select([control_read], [], [], 1)
if not readable or os.read(control_read, 1) != b"":
    raise AssertionError("watcher retained the inherited control descriptor after launcher exit")
os.close(control_read)

run_dirs = list((work / "state" / "runs").iterdir())
if len(run_dirs) != 1:
    raise AssertionError("watcher did not retain exactly one owned run directory")
if (run_dirs[0].stat().st_mode & 0o777) != 0o700:
    raise AssertionError("watcher run directory is not owner-only")

try:
    os.kill(watcher_pid, 0)
except ProcessLookupError:
    raise AssertionError("watcher was gone when launcher output reached EOF")

(work / "release-watcher").touch()
for _ in range(1000):
    try:
        os.kill(watcher_pid, 0)
    except ProcessLookupError:
        break
    time.sleep(0.01)
else:
    os.kill(watcher_pid, signal.SIGTERM)
    raise AssertionError("watcher did not exit after its controlled release")

if list((work / "state" / "runs").iterdir()):
    raise AssertionError("watcher left successful run state behind")
if list((work / "tmp").iterdir()):
    raise AssertionError("launcher left temporary prompt or agent-start files behind")

if (work / "pane-closed").exists():
    raise AssertionError("successful detached launch closed the child pane")
PY
  assert_success
}
