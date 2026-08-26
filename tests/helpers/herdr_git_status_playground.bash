# Herdr Git status playground Bats harness.
# Load after helpers/common so SOURCE_ROOT and assertion helpers are available.

HGSP_CONTROLLER="${HGSP_CONTROLLER_OVERRIDE:-$SOURCE_ROOT/dot_local/bin/executable_herdr-git-status-playground}"
HGSP_PYTHON="$(command -v python3)"

hgsp_teardown() {
  local run_id manifest
  if [[ -n "${HGSP_WORK:-}" ]]; then
    : > "$HGSP_WORK/managed-release"
    : > "$HGSP_WORK/start-release"
    : > "$HGSP_WORK/view-release"
    : > "$HGSP_WORK/atomic-release"
    : > "$HGSP_WORK/lease-release"
  fi
  if [[ -x "$HGSP_CONTROLLER" && -d "${HGSP_STATE_ROOT:-}/runs" ]]; then
    for manifest in "$HGSP_STATE_ROOT"/runs/*/manifest.json; do
      [[ -f "$manifest" ]] || continue
      run_id="${manifest%/manifest.json}"
      run_id="${run_id##*/}"
      env PATH="$HGSP_STUB:/bin" \
        XDG_STATE_HOME="$HGSP_XDG_STATE" \
        HERDR_GIT_STATUS_PLAYGROUND_TEST_MODE=1 \
        HERDR_GIT_STATUS_PLAYGROUND_TEST_LOG="$HGSP_ENV_LOG" \
        HERDR_GIT_STATUS_PLAYGROUND_CONTROLLER_TOKEN=controller-canary \
        "$HGSP_PYTHON" "$HGSP_CONTROLLER" stop "$run_id" >/dev/null 2>&1 || true
    done
  fi
  if [[ -n "${HGSP_BG_PIDS:-}" ]]; then
    local pid
    for pid in $HGSP_BG_PIDS; do
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  fi
  [[ -n "${HGSP_WORK:-}" ]] && rm -rf "$HGSP_WORK" || true
  unset HGSP_WORK HGSP_STUB HGSP_STATE_ROOT HGSP_XDG_STATE HGSP_CALL_LOG
  unset HGSP_ENV_LOG HGSP_RUN_IDS HGSP_BG_PIDS HGSP_LAST_RUN_ID HGSP_REMOTE_GIT
  unset HGSP_BYSTANDER_PID
}

hgsp_setup() {
  [[ -z "${HGSP_WORK:-}" ]] || hgsp_teardown
  HGSP_WORK="$(mktemp -d "${BATS_TMPDIR:-/tmp}/hgsp.XXXXXX")"
  HGSP_STUB="$HGSP_WORK/stub"
  HGSP_XDG_STATE="$HGSP_WORK/xdg-state"
  HGSP_STATE_ROOT="$HGSP_XDG_STATE/herdr-git-status-playground"
  HGSP_CALL_LOG="$HGSP_WORK/calls.log"
  HGSP_ENV_LOG="$HGSP_WORK/environments.jsonl"
  HGSP_RUN_IDS=""
  HGSP_BG_PIDS=""
  export HGSP_WORK HGSP_STUB HGSP_CALL_LOG
  mkdir -p "$HGSP_STUB" "$HGSP_XDG_STATE"
  : > "$HGSP_CALL_LOG"
  : > "$HGSP_ENV_LOG"

  # Fixture construction needs real Git behavior; the stub answers preflight's
  # --version probe itself and delegates fixture operations (identified by the
  # fixtures environment's GIT_CEILING_DIRECTORIES) to the real binary, logging
  # them under a distinct prefix so mutation-guard greps stay meaningful.
  # Once hgsp_github_setup installs the remote simulator, controller commands
  # that address an https remote are routed through it (the `git|` prefix keeps
  # mutation-guard greps meaningful) while purely local plumbing runs the real
  # binary under the separate `git-local|` prefix.
  local real_git
  real_git="$(command -v git)"
  cat > "$HGSP_STUB/git" <<SH
#!/bin/sh
if [ -n "\${GIT_CEILING_DIRECTORIES:-}" ]; then
  printf 'git-fixture|%s\n' "\$*" >> "\$HGSP_CALL_LOG"
  exec "$real_git" "\$@"
fi
if [ "\$1" = --version ]; then
  printf 'git|%s\n' "\$*" >> "\$HGSP_CALL_LOG"
  printf 'git version 2.45.0\n'
  exit 0
fi
if [ -f "\${0%/*}/git-remote-sim.py" ]; then
  case " \$* " in
    *" https://"*)
      printf 'git|%s\n' "\$*" >> "\$HGSP_CALL_LOG"
      exec "$HGSP_PYTHON" "\${0%/*}/git-remote-sim.py" "\$@"
      ;;
  esac
  printf 'git-local|%s\n' "\$*" >> "\$HGSP_CALL_LOG"
  exec "$real_git" "\$@"
fi
printf 'git|%s\n' "\$*" >> "\$HGSP_CALL_LOG"
exit 0
SH
  chmod +x "$HGSP_STUB/git"

  local tool
  for tool in cargo gh jq node; do
    cat > "$HGSP_STUB/$tool" <<'SH'
#!/bin/sh
tool=${0##*/}
printf '%s|%s\n' "$tool" "$*" >> "$HGSP_CALL_LOG"
case "$tool:$*" in
  node:--version) printf 'v20.11.0\n' ;;
  git:--version) printf 'git version 2.45.0\n' ;;
  gh:--version) printf 'gh version 2.50.0\n' ;;
  jq:--version) printf 'jq-1.7\n' ;;
  cargo:--version) printf 'cargo 1.80.0\n' ;;
  gh:auth\ status*) exit "${HGSP_GH_AUTH_STATUS:-0}" ;;
esac
exit 0
SH
    chmod +x "$HGSP_STUB/$tool"
  done

  # gh answers preflight probes itself; once hgsp_github_setup installs the API
  # simulator, `gh api` calls run against the shared stateful GitHub model.
  cat > "$HGSP_STUB/gh" <<SH
#!/bin/sh
printf 'gh|%s\n' "\$*" >> "\$HGSP_CALL_LOG"
if [ "\$1" = api ] && [ -f "\${0%/*}/gh-api-sim.py" ]; then
  exec "$HGSP_PYTHON" "\${0%/*}/gh-api-sim.py" "\$@"
fi
case "\$*" in
  --version) printf 'gh version 2.50.0\n' ;;
  auth\ status*)
    if [ -n "\${HGSP_LEAK_TOKEN_IN_STDERR:-}" ]; then
      # Models a real-world hazard: a CLI that echoes the credential it was
      # just handed into its own diagnostic stderr on failure. Proves the
      # controller's redaction scrubs the value wherever it surfaces, not
      # just in fields it deliberately writes (KTD17).
      printf 'gh: authentication failed for token %s\n' "\${GH_TOKEN:-}" >&2
    fi
    exit "\${HGSP_GH_AUTH_STATUS:-0}"
    ;;
esac
exit 0
SH
  chmod +x "$HGSP_STUB/gh"
  ln -s "$HGSP_PYTHON" "$HGSP_STUB/python3"

  # Herdr stub: `--version`, the long-running `server run`, and the long-lived
  # `client attach` all stay in shell (never exec into python) so the
  # controller-owned process image keeps the stub path in its command line,
  # matching what verify_process's identity check requires; every other
  # subcommand runs the stateful profile simulator and exits immediately.
  cat > "$HGSP_STUB/herdr" <<SH
#!/bin/sh
profile="\${XDG_STATE_HOME:-}"
case "\$profile" in
  */runtime/profiles/*/state) profile="\${profile%/state}"; profile="\${profile##*/}" ;;
  *) profile=controller ;;
esac
printf 'herdr|%s|%s\n' "\$profile" "\$*" >> "\$HGSP_CALL_LOG"
if [ "\$1" = --version ]; then
  printf '%s\n' "\${HGSP_HERDR_VERSION:-herdr 0.8.2}"
  exit 0
fi
if [ "\$1" = server ] && [ "\$2" = run ]; then
  state="\$XDG_STATE_HOME/herdr"
  mkdir -p "\$state"
  : > "\$state/session.sock"
  trap 'rm -f "\$state/session.sock"; exit 0' TERM INT HUP
  while [ -d "\$state" ]; do sleep 0.05; done
  rm -f "\$state/session.sock" 2>/dev/null
  exit 0
fi
if [ "\$1" = client ] && [ "\$2" = attach ]; then
  socket="\$("$HGSP_PYTHON" "$HGSP_STUB/herdr-sim.py" "\$@")"
  status=\$?
  if [ "\$status" -ne 0 ]; then
    exit "\$status"
  fi
  state="\$XDG_STATE_HOME/herdr"
  trap 'exit 0' TERM INT HUP
  while [ -e "\$socket" ] && [ -d "\$state" ]; do sleep 0.05; done
  exit 0
fi
exec "$HGSP_PYTHON" "$HGSP_STUB/herdr-sim.py" "\$@"
SH
  chmod +x "$HGSP_STUB/herdr"

  cat > "$HGSP_STUB/plugin-daemon.py" <<'PY'
"""Detached plugin daemon model: writes its own PID record and state file,
then idles until its profile state directory (or, for jmarbutt, the profile
socket) disappears. Spawned with start_new_session so pgid == pid."""
import fcntl
import json
import os
import signal
import sys
import time


def locked_update(path, mutate):
    with open(path, "r+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        value = json.load(handle)
        mutate(value)
        handle.seek(0)
        handle.truncate()
        json.dump(value, handle)
        handle.write("\n")


def main():
    role, state_dir, socket_path = sys.argv[1], sys.argv[2], sys.argv[3]
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    # Model a plugin that drops the injected XDG variables: resolution falls
    # back to HOME, which the guarded child environment points at the profile.
    probe_environment = dict(os.environ)
    for name in ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME"):
        probe_environment.pop(name, None)
    resolved_home_root = os.path.join(probe_environment.get("HOME", os.path.expanduser("~")), ".config", "herdr")

    plugin_dirs = {
        "ezcorp": "plugins/ez-corp.git-status",
        "krystof": "plugins/gitlab-ci-status",
        "jmarbutt": "plugins/jmarbutt.spaces-pr-status",
    }
    records = {"ezcorp": "updater.pid", "krystof": "poller.pid", "jmarbutt": "daemon.json"}
    plugin_dir = os.path.join(state_dir, plugin_dirs[role])
    os.makedirs(plugin_dir, exist_ok=True)
    pid = os.getpid()
    record_path = os.path.join(plugin_dir, records[role])
    with open(record_path, "w", encoding="utf-8") as handle:
        if role == "jmarbutt":
            json.dump({"pid": pid}, handle)
            handle.write("\n")
        else:
            handle.write("%d\n" % pid)

    state = {
        "pid": pid,
        "executable": os.path.realpath(__file__),
        "socket": socket_path,
        "resolved_home_root": resolved_home_root,
        "role": role,
    }
    spaces_path = os.path.join(state_dir, "spaces.json")
    if role == "ezcorp":
        spaces = []
        try:
            with open(spaces_path, encoding="utf-8") as handle:
                spaces = json.load(handle)
        except (OSError, ValueError):
            spaces = []
        omitted = os.environ.get("HGSP_EZCORP_OMIT_SPACE")
        state["spaces"] = [
            entry["label"]
            for entry in spaces
            if not entry.get("worktree_child") and entry["label"] != omitted
        ]
        state["metadata_complete"] = True
    if role == "krystof":
        def decorate(spaces):
            for entry in spaces:
                if not entry["label_text"].endswith(" •ci"):
                    entry["label_text"] = entry["label_text"] + " •ci"
        try:
            locked_update(spaces_path, decorate)
        except (OSError, ValueError):
            pass
    with open(os.path.join(plugin_dir, "state.json"), "w", encoding="utf-8") as handle:
        json.dump(state, handle)
        handle.write("\n")

    while os.path.isdir(state_dir):
        if (
            role == "jmarbutt"
            and not os.environ.get("HGSP_JMARBUTT_STUCK")
            and not os.path.exists(socket_path)
        ):
            break
        time.sleep(0.05)


main()
PY

  cat > "$HGSP_STUB/herdr-sim.py" <<'PY'
"""Stateful Herdr profile simulator: plugin registry, spaces, labels, tokens,
sidebar snapshots, and native plugin actions with their real hazards (a
liveness-only PID record that native paths signal blindly)."""
import fcntl
import json
import os
import subprocess
import sys
import time

STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", ""), "herdr")
DATA_DIR = os.path.join(os.environ.get("XDG_DATA_HOME", ""), "herdr")
CONFIG = os.path.join(os.environ.get("XDG_CONFIG_HOME", ""), "herdr", "config.toml")
SOCKET = os.path.join(STATE_DIR, "session.sock")
SPACES = os.path.join(STATE_DIR, "spaces.json")
REGISTRY = os.path.join(DATA_DIR, "plugins", "registry.json")
TREES = {
    "ez-corp.git-status": "tree-ezcorp",
    "git-detail": "tree-sfroment",
    "gitlab-ci-status": "tree-krystof",
    "jmarbutt.spaces-pr-status": "tree-jmarbutt",
}
PID_RECORDS = {
    "ez-corp.git-status": "updater.pid",
    "gitlab-ci-status": "poller.pid",
    "jmarbutt.spaces-pr-status": "daemon.json",
}
DAEMON_ROLES = {
    "ez-corp.git-status": "ezcorp",
    "gitlab-ci-status": "krystof",
    "jmarbutt.spaces-pr-status": "jmarbutt",
}

GIT_DETAIL_SCRIPT = r'''#!/bin/sh
mode="${1:-watch}"
state_dir="$XDG_STATE_HOME/herdr"
if [ "$mode" = watch ]; then
  trap 'exit 0' TERM INT HUP
  if [ "${HGSP_GIT_DETAIL_MODE:-}" = leak ]; then
    ( trap '' TERM; while [ -d "$state_dir" ]; do sleep 0.05; done ) &
  fi
  while [ -d "$state_dir" ]; do sleep 0.05; done
  exit 0
fi
knob="${HGSP_GIT_DETAIL_MODE:-ok}"
if [ "$knob" = early-exit ]; then exit 0; fi
tab="$(printf '\t')"
herdr space list --plain | while IFS="$tab" read -r label cwd; do
  [ -n "$label" ] || continue
  herdr pane cwd "$label" >/dev/null || continue
  [ "$knob" = silent ] && continue
  porcelain="$(GIT_CEILING_DIRECTORIES="${HGSP_WORK:-/}" git -C "$cwd" status --porcelain 2>/dev/null)" || continue
  staged="$(printf '%s\n' "$porcelain" | grep -c '^[MADRC].')" || true
  unstaged="$(printf '%s\n' "$porcelain" | grep -c '^.[MD]')" || true
  untracked="$(printf '%s\n' "$porcelain" | grep -c '^??')" || true
  value="git_detail=staged:$staged unstaged:$unstaged untracked:$untracked"
  if [ "$knob" = swallow ]; then
    herdr pane publish --inject-fail "$label" "$value" 2>/dev/null || true
    continue
  fi
  herdr pane publish "$label" "$value"
done
exit 0
'''


def log(line):
    path = os.environ.get("HGSP_CALL_LOG")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")


def fail(message, status=1):
    sys.stderr.write("herdr: %s\n" % message)
    raise SystemExit(status)


def require_server():
    if not os.path.exists(SOCKET):
        fail("no running server for this profile (socket missing)")


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def save_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle)
        handle.write("\n")


def native_signal_record(plugin_id):
    """The modelled hazard: native lifecycle paths trust a liveness-only PID
    record and signal whatever process it names."""
    record = os.path.join(STATE_DIR, "plugins", plugin_id, PID_RECORDS[plugin_id])
    if not os.path.exists(record):
        return
    try:
        with open(record, encoding="utf-8") as handle:
            contents = handle.read().strip()
        pid = json.loads(contents)["pid"] if contents.startswith("{") else int(contents)
    except (OSError, ValueError, KeyError):
        return
    log("herdr-native-signal|%s|%s" % (plugin_id, pid))
    try:
        os.kill(int(pid), 15)
    except (OSError, ProcessLookupError, PermissionError):
        pass


def spawn_daemon(plugin_id):
    role = DAEMON_ROLES[plugin_id]
    daemon = os.path.join(os.path.dirname(os.path.realpath(__file__)), "plugin-daemon.py")
    with open(os.devnull, "rb") as null_in, open(os.devnull, "wb") as null_out:
        subprocess.Popen(
            [sys.executable, daemon, role, STATE_DIR, SOCKET],
            stdin=null_in,
            stdout=null_out,
            stderr=null_out,
            start_new_session=True,
            close_fds=True,
        )
    state_path = os.path.join(STATE_DIR, "plugins", plugin_id, "state.json")
    for _ in range(500):
        if os.path.exists(state_path):
            return
        time.sleep(0.01)
    fail("the %s daemon never registered" % plugin_id)


def plugin_run(plugin_id, action):
    injected = os.environ.get("HGSP_PLUGIN_FAIL", "")
    if injected == "%s:%s" % (plugin_id, action):
        fail("injected %s %s failure" % (plugin_id, action))
    if plugin_id == "ez-corp.git-status" and action == "status-enable":
        require_server()
        native_signal_record(plugin_id)
        if os.environ.get("HGSP_EZCORP_NO_DAEMON"):
            return
        spawn_daemon(plugin_id)
        return
    if plugin_id == "ez-corp.git-status" and action in ("status-disable", "metadata-cleanup"):
        native_signal_record(plugin_id)
        state_path = os.path.join(STATE_DIR, "plugins", plugin_id, "state.json")
        try:
            os.unlink(state_path)
        except FileNotFoundError:
            pass
        return
    if plugin_id == "gitlab-ci-status" and action == "start":
        require_server()
        if not load_json(SPACES, []):
            fail("gitlab-ci-status start requires existing spaces")
        native_signal_record(plugin_id)
        spawn_daemon(plugin_id)
        return
    if plugin_id == "gitlab-ci-status" and action == "stop":
        native_signal_record(plugin_id)
        return
    if plugin_id == "jmarbutt.spaces-pr-status" and action == "startup":
        require_server()
        native_signal_record(plugin_id)
        spawn_daemon(plugin_id)
        return
    if plugin_id == "jmarbutt.spaces-pr-status" and action == "refresh":
        require_server()
        if not load_json(SPACES, []):
            fail("refresh requires existing spaces")
        record = load_json(os.path.join(STATE_DIR, "plugins", plugin_id, "daemon.json"), {})
        pid = record.get("pid")
        alive = False
        if isinstance(pid, int):
            try:
                os.kill(pid, 0)
                alive = True
            except (OSError, ProcessLookupError, PermissionError):
                alive = False
        if not alive:
            fail("refresh requires a live daemon")
        state_path = os.path.join(STATE_DIR, "plugins", plugin_id, "state.json")
        state = load_json(state_path, {})
        state["refreshed"] = True
        state["refreshed_at"] = time.time()
        save_json(state_path, state)
        return
    fail("unsupported plugin action %s %s" % (plugin_id, action))


def main():
    args = sys.argv[1:]
    if args[:2] == ["plugin", "fetch"]:
        plugin_id = args[2]
        revision = args[args.index("--revision") + 1]
        print(json.dumps({"plugin_id": plugin_id, "revision": revision, "tree": TREES.get(plugin_id, "")}))
        return
    if args[:2] == ["plugin", "install"]:
        plugin_id = args[2]
        revision = args[args.index("--revision") + 1]
        registry = load_json(REGISTRY, [])
        if any(entry["plugin_id"] == plugin_id for entry in registry):
            fail("plugin %s is already installed" % plugin_id)
        registry.append({"plugin_id": plugin_id, "revision": revision, "enabled": "--disabled" not in args})
        save_json(REGISTRY, registry)
        if plugin_id == "git-detail":
            script = os.path.join(DATA_DIR, "plugins", "git-detail", "git-detail.sh")
            os.makedirs(os.path.dirname(script), exist_ok=True)
            with open(script, "w", encoding="utf-8") as handle:
                handle.write(GIT_DETAIL_SCRIPT)
            os.chmod(script, 0o700)
        planted = os.environ.get("HGSP_PLANT_STALE_PID")
        if planted and plugin_id in PID_RECORDS:
            record = os.path.join(STATE_DIR, "plugins", plugin_id, PID_RECORDS[plugin_id])
            os.makedirs(os.path.dirname(record), exist_ok=True)
            with open(record, "w", encoding="utf-8") as handle:
                if record.endswith(".json"):
                    json.dump({"pid": int(planted)}, handle)
                    handle.write("\n")
                else:
                    handle.write("%s\n" % planted)
            log("herdr-stale-planted|%s|%s" % (plugin_id, planted))
        return
    if args[:2] == ["plugin", "registry"]:
        print(json.dumps(load_json(REGISTRY, [])))
        return
    if args[:2] == ["plugin", "enable"]:
        require_server()
        registry = load_json(REGISTRY, [])
        for entry in registry:
            if entry["plugin_id"] == args[2]:
                entry["enabled"] = True
                save_json(REGISTRY, registry)
                return
        fail("plugin %s is not installed" % args[2])
    if args[:2] == ["plugin", "run"]:
        plugin_run(args[2], args[3])
        return
    if args[:2] == ["space", "create"]:
        require_server()
        label = args[2]
        cwd = args[args.index("--cwd") + 1]
        spaces = load_json(SPACES, [])
        spaces.append(
            {
                "label": label,
                "label_text": label,
                "cwd": cwd,
                "worktree_child": "--worktree-child" in args,
                "tokens": {},
            }
        )
        save_json(SPACES, spaces)
        return
    if args[:2] == ["space", "list"]:
        require_server()
        spaces = load_json(SPACES, [])
        if "--plain" in args:
            for entry in spaces:
                sys.stdout.write("%s\t%s\n" % (entry["label"], entry["cwd"]))
        else:
            print(json.dumps(spaces))
        return
    if args[:3] == ["space", "label", "set"]:
        require_server()
        spaces = load_json(SPACES, [])
        for entry in spaces:
            if entry["label"] == args[3]:
                entry["label_text"] = args[4]
                save_json(SPACES, spaces)
                return
        fail("no space labelled %s" % args[3])
    if args[:2] == ["pane", "cwd"]:
        require_server()
        for entry in load_json(SPACES, []):
            if entry["label"] == args[2]:
                print(entry["cwd"])
                return
        fail("no space labelled %s" % args[2])
    if args[:2] == ["pane", "publish"]:
        require_server()
        rest = args[2:]
        if rest and rest[0] == "--inject-fail":
            fail("injected publication failure")
        label = rest[0]
        spaces = load_json(SPACES, [])
        for entry in spaces:
            if entry["label"] == label:
                for pair in rest[1:]:
                    key, _, value = pair.partition("=")
                    entry["tokens"][key] = value
                save_json(SPACES, spaces)
                return
        fail("no space labelled %s" % label)
    if args[:2] == ["sidebar", "snapshot"]:
        require_server()
        try:
            with open(CONFIG, encoding="utf-8") as handle:
                lines = handle.read().splitlines()
        except OSError:
            fail("no sidebar configuration")
        for line in lines:
            if line.startswith('sidebar_row = "'):
                sys.stdout.write(line[len('sidebar_row = "'):-1] + "\n")
        return
    if args[:2] == ["config", "reload"]:
        require_server()
        return
    if args[:2] == ["space", "focus"]:
        require_server()
        label = args[2]
        if not any(entry["label"] == label for entry in load_json(SPACES, [])):
            fail("no space labelled %s" % label)
        focus_path = os.path.join(STATE_DIR, "focus.json")
        current = load_json(focus_path, {"generation": 0})
        save_json(
            focus_path,
            {
                "label": label,
                "generation": current.get("generation", 0) + 1,
                "previous_label": current.get("label"),
                "previous_generation": current.get("generation"),
            },
        )
        return
    if args[:2] == ["space", "current"]:
        require_server()
        current = load_json(os.path.join(STATE_DIR, "focus.json"), None)
        if current is None:
            fail("no fixture has been focused yet")
        # Test knob: model a client that echoes a cached read from before the
        # most recent focus switch, so causal-freshness tests can prove that
        # an equal stale value is rejected rather than trusted (KTD7).
        if os.environ.get("HGSP_STALE_FOCUS_READ") and current.get("previous_label") is not None:
            print(json.dumps({"label": current["previous_label"], "generation": current["previous_generation"]}))
        else:
            print(json.dumps({"label": current["label"], "generation": current["generation"]}))
        return
    if args[:2] == ["workspace", "create"]:
        require_server()
        name = args[2]
        cwd = args[args.index("--cwd") + 1]
        workspace_path = os.path.join(STATE_DIR, "workspace.json")
        if os.path.exists(workspace_path):
            fail("workspace %s already exists" % name)
        save_json(workspace_path, {"name": name, "cwd": cwd, "panes": {}})
        return
    if args[:2] == ["workspace", "layout"]:
        require_server()
        name = args[2]
        panes_count = int(args[args.index("--panes") + 1])
        columns = int(args[args.index("--columns") + 1])
        rows = int(args[args.index("--rows") + 1])
        if panes_count != 4 or columns % 2 != 0 or rows % 2 != 0:
            fail("only an even 2x2 layout is supported")
        workspace_path = os.path.join(STATE_DIR, "workspace.json")
        workspace = load_json(workspace_path, None)
        if workspace is None or workspace.get("name") != name:
            fail("no workspace named %s" % name)
        width, height = columns // 2, rows // 2
        workspace["layout"] = {"columns": columns, "rows": rows, "width": width, "height": height}
        save_json(workspace_path, workspace)
        print(json.dumps({"panes": [{"width": width, "height": height} for _ in range(panes_count)]}))
        return
    if args[:2] == ["client", "attach"]:
        # Registration only: the sh wrapper that invoked this owns the
        # long-lived idle loop and signal handling, so the recorded launch
        # identity (the stub path) stays in the process image, matching the
        # server-run pattern's identity contract (KTD9's process-verification
        # relies on the stub path appearing in the live process command).
        socket_path = args[args.index("--socket") + 1]
        pane_id = args[args.index("--pane") + 1]
        header = json.loads(args[args.index("--header") + 1])
        if "--nested" not in args or "--no-auto-start" not in args:
            fail("nested client attach requires --nested and --no-auto-start")
        if not os.path.exists(socket_path):
            fail("candidate socket is unavailable: %s" % socket_path)
        workspace_path = os.path.join(STATE_DIR, "workspace.json")
        workspace = load_json(workspace_path, None)
        if workspace is None:
            fail("no viewer workspace to attach into")
        workspace.setdefault("panes", {})[pane_id] = {"header": header, "socket": socket_path}
        save_json(workspace_path, workspace)
        print(socket_path)
        return
    fail("unsupported herdr invocation: %r" % (args,), 97)


main()
PY

  cat > "$HGSP_STUB/managed-probe" <<'SH'
#!/bin/sh
printf 'managed-probe|start|%s\n' "$$" >> "$HGSP_CALL_LOG"
: > "$HGSP_WORK/managed-ready"
trap 'printf "managed-probe|TERM|%s\n" "$$" >> "$HGSP_CALL_LOG"; exit 0' TERM INT HUP
while [ ! -e "$HGSP_WORK/managed-release" ]; do
  sleep 0.01
done
SH
  chmod +x "$HGSP_STUB/managed-probe"

  cat > "$HGSP_WORK/fixture-ownership.json" <<'JSON'
{"host":"github.com","owner":"example","name":"herdr-status-fixtures","repository_id":"R_fixture_1","owned":true}
JSON
  cat > "$HGSP_WORK/audit-attestation.json" <<'JSON'
{"candidates":{"ezcorp":{"revision":"f144c8dac2860e344b6b379d2bcfee229dcf10ad","tree":"tree-ezcorp","approved":true},"sfroment":{"revision":"b726977143adc2847dc25e3327bc0b1b4fc26455","tree":"tree-sfroment","approved":true},"krystof":{"revision":"fe6575a89de9006c35d9d0b9707397839d983cff","tree":"tree-krystof","approved":true},"jmarbutt":{"revision":"8a56c5dce0bd65e47eddc9a1d862ddae870cddc3","tree":"tree-jmarbutt","approved":true}}}
JSON
  cat > "$HGSP_WORK/inherited-environment.json" <<JSON
{"DYLD_INSERT_LIBRARIES":"poison","DYLD_LIBRARY_PATH":"poison","LD_PRELOAD":"poison","LD_LIBRARY_PATH":"poison","PYTHONPATH":"poison","PYTHONHOME":"poison","PYTHONSTARTUP":"poison","NODE_OPTIONS":"poison","RUBYOPT":"poison","HTTP_PROXY":"http://credential@proxy","HTTPS_PROXY":"http://credential@proxy","ALL_PROXY":"http://credential@proxy","PATH":"$HGSP_STUB:/bin:$HGSP_WORK/poison-bin"}
JSON
  chmod 600 "$HGSP_WORK/fixture-ownership.json" "$HGSP_WORK/audit-attestation.json" \
    "$HGSP_WORK/inherited-environment.json"
}

hgsp_env() {
  env \
    PATH="$HGSP_STUB:/bin:$HGSP_WORK/poison-bin" \
    HOME="$HGSP_WORK/live-home" \
    XDG_CONFIG_HOME="$HGSP_WORK/live-config" \
    XDG_STATE_HOME="$HGSP_XDG_STATE" \
    XDG_DATA_HOME="$HGSP_WORK/live-data" \
    NO_COLOR=safe-control \
    HERDR_ENV=poison HERDR_SESSION=poison HERDR_SOCKET_PATH="$HGSP_WORK/live.sock" \
    HERDR_CLIENT_SOCKET_PATH="$HGSP_WORK/live-client.sock" HERDR_CONFIG_PATH="$HGSP_WORK/live-config.toml" \
    GH_TOKEN=ambient-token GH_REPO=wrong/repo GH_HOST=wrong.example \
    GITHUB_TOKEN=ambient-github-token GITHUB_REPOSITORY=wrong/repo \
    SSH_AUTH_SOCK="$HGSP_WORK/agent.sock" GPG_AGENT_INFO=poison \
    GIT_ASKPASS=poison SSH_ASKPASS=poison GIT_CONFIG_GLOBAL="$HGSP_WORK/live-gitconfig" \
    HERDR_GIT_STATUS_PLAYGROUND_CONTROLLER_TOKEN="${HGSP_CONTROLLER_TOKEN:-controller-canary}" \
    HERDR_GIT_STATUS_PLAYGROUND_CANDIDATE_TOKEN=candidate-canary \
    HERDR_GIT_STATUS_PLAYGROUND_TEST_MODE=1 \
    HERDR_GIT_STATUS_PLAYGROUND_TEST_LOG="$HGSP_ENV_LOG" \
    HERDR_GIT_STATUS_PLAYGROUND_TEST_PARENT_ENV="$HGSP_WORK/inherited-environment.json" \
    HERDR_GIT_STATUS_PLAYGROUND_TEST_PROCESS="${HGSP_TEST_PROCESS-$HGSP_STUB/managed-probe}" \
    "$HGSP_PYTHON" "$HGSP_CONTROLLER" "$@"
}

# Run the real candidate lifecycle instead of the U1 foundation test process.
hgsp_candidate_start() {
  HGSP_TEST_PROCESS= hgsp_start "$@"
}

hgsp_profile_root() {
  printf '%s/runs/%s/runtime/profiles/%s\n' "$HGSP_STATE_ROOT" "$1" "$2"
}

# A live process no playground run owns; regressions that signal it kill it.
# It leads its own process group so that a forged plugin record passes every
# liveness-shaped check and only real identity agreement can reject it.
hgsp_start_bystander() {
  "$HGSP_PYTHON" -c 'import os,time; os.setsid(); time.sleep(600)' \
    </dev/null >/dev/null 2>&1 3>&- &
  HGSP_BYSTANDER_PID=$!
  HGSP_BG_PIDS="$HGSP_BG_PIDS $HGSP_BYSTANDER_PID"
}

hgsp_start_args() {
  printf '%s\n' \
    --approved-herdr "$HGSP_STUB/herdr" \
    --fixture-ownership "$HGSP_WORK/fixture-ownership.json" \
    --audit-attestation "$HGSP_WORK/audit-attestation.json"
}

hgsp_start() {
  local args=()
  while IFS= read -r value; do args+=("$value"); done < <(hgsp_start_args)
  hgsp_env start "${args[@]}" "$@"
}

hgsp_json_field() {
  local json="$1" field="$2"
  "$HGSP_PYTHON" -c 'import json,sys; value=json.loads(sys.argv[1]);
for part in sys.argv[2].split("."): value=value[part]
print("true" if value is True else "false" if value is False else value)' "$json" "$field"
}

hgsp_capture_run_id() {
  HGSP_LAST_RUN_ID="$(hgsp_json_field "$output" run_id)"
  HGSP_RUN_IDS="$HGSP_RUN_IDS $HGSP_LAST_RUN_ID"
}

hgsp_manifest() {
  printf '%s/runs/%s/manifest.json\n' "$HGSP_STATE_ROOT" "$1"
}

hgsp_wait_for_file() {
  local file="$1" attempts="${2:-500}"
  while (( attempts > 0 )); do
    [[ -e "$file" ]] && return 0
    attempts=$((attempts - 1))
    sleep 0.01
  done
  fail "timed out waiting for causal marker $file"
}

hgsp_assert_no_launch_or_mutation() {
  run grep -E '^(managed-probe|gh\|api|gh\|pr|gh\|workflow|git\|push)' "$HGSP_CALL_LOG"
  assert_failure
}

hgsp_evidence_index() {
  printf '%s/runs/%s/evidence-index.json\n' "$HGSP_STATE_ROOT" "$1"
}

# Mutate the run's evidence-index.json in place through a Python expression
# bound to `rows` (the list); used to fabricate finalize-time edge cases
# (missing/duplicate/corrupted records) without recapturing real evidence.
hgsp_patch_evidence_index() {
  local run_id="$1" expression="$2"
  "$HGSP_PYTHON" - "$(hgsp_evidence_index "$run_id")" "$expression" <<'PY'
import json
import os
import sys

path, expression = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    index = json.load(handle)
rows = index["rows"]
exec(expression, {"index": index, "rows": rows})
temporary = path + ".fixture"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(index, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.replace(temporary, path)
PY
}

hgsp_patch_manifest() {
  local run_id="$1" expression="$2"
  "$HGSP_PYTHON" - "$(hgsp_manifest "$run_id")" "$expression" <<'PY'
import json
import os
import sys

path, expression = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
exec(expression, {"manifest": manifest})
temporary = path + ".fixture"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.replace(temporary, path)
PY
}

hgsp_set_manifest_lease() {
  local run_id="$1" pid="$2" start_identity="$3"
  "$HGSP_PYTHON" - "$(hgsp_manifest "$run_id")" "$pid" "$start_identity" <<'PY'
import json
import os
import sys

path, pid, start_identity = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
manifest["mutation_lease"] = {
    "owner_id": "fixture",
    "pid": int(pid),
    "start_identity": start_identity,
    "claimed_at": "1970-01-01T00:00:00Z",
}
temporary = path + ".fixture"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.replace(temporary, path)
PY
}

hgsp_process_start_identity() {
  "$HGSP_PYTHON" - "$1" <<'PY'
import subprocess
import sys
print(subprocess.check_output(["ps", "-o", "lstart=", "-p", sys.argv[1]], text=True).strip())
PY
}

# ---- Stateful GitHub simulation (U3) ------------------------------------
# The canonical fixture repository is a real local bare repository, so every
# ref CAS (force-with-lease) uses genuine Git semantics; a JSON state file
# layers the GitHub-only entities (repository identity, permissions, pull
# requests, workflow runs, policy) on top of it.

hgsp_real_git() {
  env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 git "$@"
}

hgsp_remote_git() {
  hgsp_real_git --git-dir "$HGSP_REMOTE_GIT" "$@"
}

hgsp_github_setup() {
  HGSP_REMOTE_GIT="$HGSP_WORK/remote/fixture.git"
  export HGSP_REMOTE_GIT
  mkdir -p "$HGSP_WORK/remote"
  hgsp_real_git init --quiet --bare --initial-branch=main "$HGSP_REMOTE_GIT"
  local decoy seed
  for decoy in decoy-host decoy-repo; do
    hgsp_real_git init --quiet --bare --initial-branch=main "$HGSP_WORK/remote/$decoy.git"
  done
  seed="$(mktemp -d "$HGSP_WORK/seed.XXXXXX")"
  hgsp_real_git init --quiet --initial-branch=main "$seed"
  hgsp_real_git -C "$seed" -c user.name=Decoy -c user.email=decoy@example.invalid \
    commit --quiet --allow-empty -m "decoy baseline"
  hgsp_real_git -C "$seed" push --quiet "$HGSP_WORK/remote/decoy-host.git" main
  hgsp_real_git -C "$seed" push --quiet "$HGSP_WORK/remote/decoy-repo.git" main
  rm -rf "$seed"

  "$HGSP_PYTHON" - "$HGSP_WORK" "$(command -v git)" <<'PY'
import json
import os
import sys

work, real_git = sys.argv[1:]


def repository(name, node_id, url):
    return {
        "node_id": node_id,
        "url": url,
        "git_dir": os.path.join(work, "remote", name),
        "default_branch": "main",
        "secrets_total": 0,
        "environments_total": 0,
        "actions_enabled": True,
        "pulls": [],
        "next_pr_number": 1,
        "workflow_runs": [],
        "next_run_id": 9001,
        "mergeable_settle_polls": 2,
        "decoy_runs": False,
    }


state = {
    "real_git": real_git,
    "tokens": {"controller-canary": "write", "candidate-canary": "read"},
    "repositories": {
        "github.com/example/herdr-status-fixtures": repository(
            "fixture.git", "R_fixture_1", "https://github.com/example/herdr-status-fixtures.git"
        ),
        "wrong.example/example/herdr-status-fixtures": repository(
            "decoy-host.git", "R_decoy_host", "https://wrong.example/example/herdr-status-fixtures.git"
        ),
        "github.com/wrong/repo": repository(
            "decoy-repo.git", "R_decoy_repo", "https://github.com/wrong/repo.git"
        ),
    },
}
path = os.path.join(work, "github-state.json")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle, indent=1)
    handle.write("\n")
os.chmod(path, 0o600)
PY

  cat > "$HGSP_STUB/git-remote-sim.py" <<'PY'
"""Route controller Git commands addressed to an https remote onto the local
bare repository behind it, enforcing credential permissions and modelling the
push-triggered GitHub Actions runs."""
import fcntl
import json
import os
import subprocess
import sys

LEASE_REF = "refs/heads/herdr-playground/lease"


def log(line):
    path = os.environ.get("HGSP_CALL_LOG")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")


def fail(message, status=128):
    sys.stderr.write("fatal: %s\n" % message)
    raise SystemExit(status)


def credential_token(url):
    store = None
    for index in range(int(os.environ.get("GIT_CONFIG_COUNT", "0") or 0)):
        if os.environ.get("GIT_CONFIG_KEY_%d" % index) == "credential.helper":
            value = os.environ.get("GIT_CONFIG_VALUE_%d" % index, "")
            if value.startswith("store --file="):
                store = value[len("store --file="):]
    if not store or not os.path.exists(store):
        return None
    host = url.split("/")[2]
    for line in open(store, encoding="utf-8"):
        line = line.strip()
        if "@%s/" % host in line:
            return line.split("://", 1)[1].split("@", 1)[0].split(":", 1)[1]
    return None


def record_push_effects(state, repo, real_git, argv, url):
    positionals = [argument for argument in argv if not argument.startswith("-")]
    for refspec in positionals[positionals.index(url) + 1:]:
        if ":" not in refspec:
            continue
        source, ref = refspec.split(":", 1)
        if not source:
            log("git-push|%s|deleted" % ref)
            continue
        sha = subprocess.check_output(
            [real_git, "--git-dir", repo["git_dir"], "rev-parse", ref], text=True
        ).strip()
        log("git-push|%s|%s" % (ref, sha))
        if not ref.startswith("refs/heads/herdr-playground/") or ref == LEASE_REF:
            continue
        branch = ref[len("refs/heads/"):]
        conclusion = "failure" if "checks-failed" in branch else "success"
        runs = repo.setdefault("workflow_runs", [])

        def add(name, head_sha, verdict):
            runs.append(
                {
                    "id": repo["next_run_id"],
                    "name": name,
                    "head_branch": branch,
                    "head_sha": head_sha,
                    "status": "completed",
                    "conclusion": verdict,
                    "event": "push",
                }
            )
            repo["next_run_id"] += 1

        add("herdr-git-status-playground", sha, conclusion)
        if repo.get("decoy_runs"):
            flipped = "failure" if conclusion == "success" else "success"
            add("herdr-git-status-playground-nightly", sha, flipped)
            add("herdr-git-status-playground", "f" * 40, flipped)


def main():
    argv = sys.argv[1:]
    work = os.environ.get("HGSP_WORK")
    if not work:
        fail("HGSP_WORK is not available to the git remote simulator")
    with open(os.path.join(work, "github-state.json"), "r+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        state = json.load(handle)
        real_git = state["real_git"]
        url = next((argument for argument in argv if argument.startswith("https://")), None)
        repo = None
        for key, record in state["repositories"].items():
            if record["url"] == url:
                repo_key, repo = key, record
                break
        if repo is None:
            fail("repository not found: %s" % url)
        subcommand = next(argument for argument in argv if not argument.startswith("-"))
        token = credential_token(url) or os.environ.get("HGSP_DIRECT_TOKEN")
        permission = state["tokens"].get(token)
        log("git-auth|%s|%s|token=%s" % (subcommand, repo_key, token or "-"))
        if permission is None:
            fail("authentication required for %s" % url)
        if subcommand == "push" and permission != "write":
            fail("write permission to %s denied for read-only credential" % repo_key, 128)
        rewritten = [repo["git_dir"] if argument == url else argument for argument in argv]
        completed = subprocess.run([real_git] + rewritten)
        if completed.returncode == 0 and subcommand == "clone":
            destination = [argument for argument in argv if not argument.startswith("-")][-1]
            subprocess.run(
                [real_git, "-C", destination, "remote", "set-url", "origin", url], check=True
            )
        if completed.returncode == 0 and subcommand == "push":
            record_push_effects(state, repo, real_git, argv, url)
        handle.seek(0)
        handle.truncate()
        json.dump(state, handle)
        handle.write("\n")
    raise SystemExit(completed.returncode)


main()
PY

  cat > "$HGSP_STUB/gh-api-sim.py" <<'PY'
"""Stateful `gh api` simulator over the shared GitHub model."""
import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import parse_qs


def log(line):
    path = os.environ.get("HGSP_CALL_LOG")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")


def fail(message):
    sys.stderr.write("gh: %s\n" % message)
    raise SystemExit(1)


def pr_json(pull):
    return {
        "number": pull["number"],
        "node_id": pull["node_id"],
        "state": pull["state"],
        "draft": pull["draft"],
        "head": {"ref": pull["head_ref"], "sha": pull["head_sha"]},
        "base": {"ref": pull["base_ref"]},
        "user": {"login": pull["user"]},
        "mergeable": pull.get("mergeable"),
        "mergeable_state": pull.get("mergeable_state", "unknown"),
    }


def isolated_env():
    environment = dict(os.environ)
    environment.update(
        {
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
        }
    )
    return environment


def mature(repo, run):
    """Advance one run per observation: poll-count driven early completion and
    cancellation, so tests prove ordering with counters, not wall clocks."""
    if run.get("status") == "completed":
        return
    polls = run.get("complete_after_polls")
    if polls is not None:
        if polls <= 0:
            run["status"] = "completed"
            run["conclusion"] = "success"
            return
        run["complete_after_polls"] = polls - 1
    if run.get("cancel_requested") and not run.get("uncancellable"):
        remaining = run.get("cancel_pending_polls", 1)
        if remaining <= 0:
            run["status"] = "completed"
            run["conclusion"] = "cancelled"
        else:
            run["cancel_pending_polls"] = remaining - 1


def compute_mergeable(real_git, git_dir, base_ref, head_sha):
    scratch = tempfile.mkdtemp(prefix="hgsp-merge-")
    environment = isolated_env()
    try:
        subprocess.run(
            [real_git, "clone", "--quiet", git_dir, scratch], env=environment, check=True
        )
        subprocess.run(
            [real_git, "-C", scratch, "checkout", "--quiet", base_ref],
            env=environment,
            check=True,
        )
        merge = subprocess.run(
            [
                real_git, "-C", scratch, "-c", "user.name=sim",
                "-c", "user.email=sim@example.invalid",
                "merge", "--no-commit", "--no-ff", head_sha,
            ],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if merge.returncode == 0:
            return True, "clean"
        unmerged = subprocess.check_output(
            [real_git, "-C", scratch, "ls-files", "-u"], env=environment, text=True
        )
        return (False, "dirty") if unmerged.strip() else (True, "clean")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def main():
    args = sys.argv[1:]
    if not args or args[0] != "api":
        fail("unsupported invocation")
    host = "github.com"
    fields = {}
    path = None
    method = None
    index = 1
    while index < len(args):
        argument = args[index]
        if argument == "--hostname":
            host = args[index + 1]
            index += 2
        elif argument in ("-f", "-F"):
            key, _, value = args[index + 1].partition("=")
            if argument == "-F" and value in ("true", "false"):
                value = value == "true"
            fields[key] = value
            index += 2
        elif argument in ("--method", "-X"):
            method = args[index + 1]
            index += 2
        else:
            path = argument
            index += 1
    if method is None:
        method = "POST" if fields else "GET"
    token = os.environ.get("GH_TOKEN", "")
    route, _, query = (path or "").partition("?")
    route = route.strip("/")
    params = parse_qs(query)
    log(
        "gh-sim|method=%s|host=%s|path=%s|token=%s|ghrepo=%s|ghhost=%s"
        % (
            method, host, route, token or "-",
            os.environ.get("GH_REPO", "-"), os.environ.get("GH_HOST", "-"),
        )
    )
    work = os.environ.get("HGSP_WORK")
    if not work:
        fail("HGSP_WORK is not available to the gh simulator")
    with open(os.path.join(work, "github-state.json"), "r+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        state = json.load(handle)
        permission = state["tokens"].get(token)
        if permission is None:
            fail("HTTP 401: authentication failed")
        remaining = state.get("api_fail_after")
        if remaining is not None:
            if remaining <= 0:
                fail(state.get("api_fail_message", "HTTP 403: API rate limit exceeded"))
            state["api_fail_after"] = remaining - 1
        parts = route.split("/")
        if parts[0] != "repos" or len(parts) < 3:
            fail("HTTP 404: unsupported path %s" % route)
        repo = state["repositories"].get("%s/%s/%s" % (host, parts[1], parts[2]))
        if repo is None:
            fail("HTTP 404: repository %s/%s on %s" % (parts[1], parts[2], host))
        real_git = state["real_git"]
        tail = parts[3:]
        if not tail:
            out = {
                "node_id": repo["node_id"],
                "full_name": "%s/%s" % (parts[1], parts[2]),
                "default_branch": repo["default_branch"],
                "permissions": {
                    "push": permission == "write",
                    "pull": True,
                    "admin": permission == "write",
                },
            }
        elif tail == ["actions", "secrets"]:
            out = {"total_count": repo.get("secrets_total", 0)}
        elif tail == ["environments"]:
            out = {"total_count": repo.get("environments_total", 0)}
        elif tail == ["actions", "permissions"]:
            out = {"enabled": repo.get("actions_enabled", True), "allowed_actions": "all"}
        elif tail == ["actions", "runs"]:
            runs = repo.get("workflow_runs", [])
            head_sha = params.get("head_sha", [None])[0]
            if head_sha:
                runs = [run for run in runs if run["head_sha"] == head_sha]
            event = params.get("event", [None])[0]
            if event:
                runs = [run for run in runs if run.get("event") == event]
            branch = params.get("branch", [None])[0]
            if branch:
                runs = [run for run in runs if run.get("head_branch") == branch]
            for run in runs:
                mature(repo, run)
            out = {"total_count": len(runs), "workflow_runs": runs}
        elif len(tail) == 3 and tail[:2] == ["actions", "runs"] and tail[2].isdigit():
            run = next(
                (entry for entry in repo.get("workflow_runs", []) if entry["id"] == int(tail[2])), None
            )
            if run is None:
                fail("HTTP 404: workflow run %s" % tail[2])
            mature(repo, run)
            out = dict(run)
        elif len(tail) == 4 and tail[:2] == ["actions", "runs"] and tail[3] == "cancel":
            if permission != "write":
                fail("HTTP 403: write permission required")
            run = next(
                (entry for entry in repo.get("workflow_runs", []) if entry["id"] == int(tail[2])), None
            )
            if run is None:
                fail("HTTP 404: workflow run %s" % tail[2])
            log("gh-cancel|run=%s" % tail[2])
            if run.get("status") == "completed":
                fail("HTTP 409: cannot cancel a completed workflow run")
            run["cancel_requested"] = True
            run.setdefault("cancel_pending_polls", repo.get("cancel_pending_polls", 1))
            out = None
        elif len(tail) == 4 and tail[:2] == ["actions", "workflows"] and tail[3] == "dispatches":
            if permission != "write":
                fail("HTTP 403: write permission required")
            ref = fields.get("ref")
            probe = subprocess.run(
                [real_git, "--git-dir", repo["git_dir"], "rev-parse", "refs/heads/%s" % ref],
                env=isolated_env(),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            if probe.returncode != 0:
                fail("HTTP 422: no ref %s" % ref)
            if repo.get("dispatch_creates_run") is False:
                out = None
            else:
                queue = repo.get("dispatch_complete_after_polls_queue") or []
                complete_after = queue.pop(0) if queue else None
                run = {
                    "id": repo["next_run_id"],
                    "name": "herdr-git-status-playground %s" % fields.get("inputs[intent]", ""),
                    "head_branch": ref,
                    "head_sha": probe.stdout.strip(),
                    "status": "in_progress",
                    "conclusion": None,
                    "event": "workflow_dispatch",
                    "hold_seconds": fields.get("inputs[hold_seconds]"),
                    "complete_after_polls": complete_after,
                }
                repo["next_run_id"] += 1
                repo.setdefault("workflow_runs", []).append(run)
                log(
                    "gh-dispatch|ref=%s|intent=%s|hold=%s|run=%d"
                    % (ref, fields.get("inputs[intent]", ""), fields.get("inputs[hold_seconds]", ""), run["id"])
                )
                out = None
        elif tail == ["pulls"] and method == "GET":
            pulls = repo.get("pulls", [])
            state_param = params.get("state", ["open"])[0]
            if state_param != "all":
                pulls = [pull for pull in pulls if pull["state"] == state_param]
            head = params.get("head", [None])[0]
            if head:
                branch = head.partition(":")[2]
                pulls = [pull for pull in pulls if pull["head_ref"] == branch]
            out = [pr_json(pull) for pull in pulls]
        elif tail == ["pulls"] and method == "POST":
            if permission != "write":
                fail("HTTP 403: write permission required")
            probe = subprocess.run(
                [
                    real_git, "--git-dir", repo["git_dir"], "rev-parse",
                    "refs/heads/%s" % fields["head"],
                ],
                env=isolated_env(),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            if probe.returncode != 0:
                fail("HTTP 422: head ref %s does not exist" % fields["head"])
            pull = {
                "number": repo["next_pr_number"],
                "node_id": "PR_%s_%d" % (repo["node_id"], repo["next_pr_number"]),
                "state": "open",
                "draft": bool(fields.get("draft", False)),
                "head_ref": fields["head"],
                "head_sha": probe.stdout.strip(),
                "base_ref": fields["base"],
                "user": "playground-controller",
                "mergeable": None,
                "mergeable_state": "unknown",
                "mergeable_polls_remaining": repo.get("mergeable_settle_polls", 2),
                "title": fields.get("title", ""),
            }
            repo["next_pr_number"] += 1
            repo.setdefault("pulls", []).append(pull)
            out = pr_json(pull)
        elif len(tail) == 2 and tail[0] == "pulls":
            number = int(tail[1])
            pull = next(
                (entry for entry in repo.get("pulls", []) if entry["number"] == number), None
            )
            if pull is None:
                fail("HTTP 404: pull %d" % number)
            if pull.get("mergeable") is None:
                remaining = pull.get("mergeable_polls_remaining", 0)
                if remaining > 0:
                    pull["mergeable_polls_remaining"] = remaining - 1
                else:
                    mergeable, mergeable_state = compute_mergeable(
                        real_git, repo["git_dir"], pull["base_ref"], pull["head_sha"]
                    )
                    pull["mergeable"] = mergeable
                    pull["mergeable_state"] = mergeable_state
            out = pr_json(pull)
        else:
            fail("HTTP 404: unsupported path %s" % route)
        handle.seek(0)
        handle.truncate()
        json.dump(state, handle)
        handle.write("\n")
    if out is not None:
        print(json.dumps(out))


main()
PY
}

hgsp_bootstrap() {
  hgsp_env bootstrap --fixture-ownership "$HGSP_WORK/fixture-ownership.json" "$@"
}

hgsp_initialize() {
  hgsp_bootstrap --initialize "$@"
}

hgsp_patch_github_state() {
  "$HGSP_PYTHON" - "$HGSP_WORK/github-state.json" "$1" <<'PY'
import json
import os
import sys

path, expression = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    state = json.load(handle)
exec(expression, {"state": state, "repo": state["repositories"]["github.com/example/herdr-status-fixtures"]})
temporary = path + ".patch"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(state, handle)
    handle.write("\n")
os.replace(temporary, path)
PY
}

hgsp_github_query() {
  "$HGSP_PYTHON" - "$HGSP_WORK/github-state.json" "$1" <<'PY'
import json
import sys

path, expression = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    state = json.load(handle)
value = eval(expression, {"state": state, "repo": state["repositories"]["github.com/example/herdr-status-fixtures"]})
print("true" if value is True else "false" if value is False else value)
PY
}

hgsp_repo_record() {
  printf '%s/repository/github.com/example/herdr-status-fixtures/repository.json\n' "$HGSP_STATE_ROOT"
}

hgsp_record_field() {
  hgsp_json_field "$(cat "$(hgsp_repo_record)")" "$1"
}

# One-call remote foundation for run-level (U4) cases: simulator, explicit
# initialization, and a converged durable fixture catalog.
hgsp_remote_ready() {
  hgsp_github_setup
  run hgsp_initialize
  assert_success
  run hgsp_bootstrap
  assert_success
}

hgsp_host_installation_id() {
  cat "$HGSP_STATE_ROOT/host-installation-id"
}

hgsp_manifest_query() {
  local run_id="$1" expression="$2"
  "$HGSP_PYTHON" - "$(hgsp_manifest "$run_id")" "$expression" <<'PY'
import json
import sys

path, expression = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
value = eval(expression, {"manifest": manifest, "remote": manifest.get("remote")})
print("true" if value is True else "false" if value is False else value)
PY
}

# Force-write a lease commit with the given lease.json payload through real
# Git, bypassing the simulator, to model exited-owner, leaked, and foreign
# repository leases.
hgsp_seed_lease() {
  local payload="$1" scratch
  scratch="$(mktemp -d "$HGSP_WORK/lease.XXXXXX")"
  hgsp_real_git init --quiet --initial-branch=seed "$scratch"
  printf '%s\n' "$payload" > "$scratch/lease.json"
  hgsp_real_git -C "$scratch" add lease.json
  hgsp_real_git -C "$scratch" -c user.name=Holder -c user.email=holder@example.invalid \
    commit --quiet -m "seeded lease"
  hgsp_real_git -C "$scratch" push --quiet --force "$HGSP_REMOTE_GIT" "HEAD:refs/heads/herdr-playground/lease"
  rm -rf "$scratch"
}

# Rewrite one file on the remote default branch through real Git, bypassing
# the simulator, to model drift performed outside the controller.
hgsp_rewrite_default_file() {
  local file="$1" scratch
  scratch="$(mktemp -d "$HGSP_WORK/tamper.XXXXXX")"
  hgsp_real_git clone --quiet "$HGSP_REMOTE_GIT" "$scratch/clone"
  mkdir -p "$scratch/clone/$(dirname "$file")"
  cat > "$scratch/clone/$file"
  hgsp_real_git -C "$scratch/clone" -c user.name=Drift -c user.email=drift@example.invalid add -A
  hgsp_real_git -C "$scratch/clone" -c user.name=Drift -c user.email=drift@example.invalid \
    commit --quiet -m "external rewrite of $file"
  hgsp_real_git -C "$scratch/clone" push --quiet origin HEAD
  rm -rf "$scratch"
}

# Push one commit to an arbitrary remote ref through real Git, bypassing the
# simulator, to model foreign leases, unrelated branches, and drifted heads.
hgsp_seed_remote_ref() {
  local ref="$1" message="${2:-seeded}" base="${3:-}" scratch
  scratch="$(mktemp -d "$HGSP_WORK/seed-ref.XXXXXX")"
  hgsp_real_git init --quiet --initial-branch=seed "$scratch"
  if [[ -n "$base" ]]; then
    hgsp_real_git -C "$scratch" fetch --quiet "$HGSP_REMOTE_GIT" "$base"
    hgsp_real_git -C "$scratch" checkout --quiet -b seeded FETCH_HEAD
  fi
  printf '%s\n' "$message" > "$scratch/seeded.txt"
  hgsp_real_git -C "$scratch" add seeded.txt
  hgsp_real_git -C "$scratch" -c user.name=Foreign -c user.email=foreign@example.invalid \
    commit --quiet -m "$message"
  hgsp_real_git -C "$scratch" push --quiet "$HGSP_REMOTE_GIT" "HEAD:$ref"
  rm -rf "$scratch"
}
