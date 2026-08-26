#!/usr/bin/env bats

load 'helpers/common'
load 'helpers/herdr_task_sync'
load 'helpers/herdr_git_status_playground'

setup() {
  unset HERDR_CHILD_NAME
  unset HERDR_CHILD_PARENT_PANE
}

teardown() {
  hgsp_teardown
  hts_teardown
  [[ -n "${BATS_TEST_TMPFILE:-}" ]] && rm -f "$BATS_TEST_TMPFILE" || true
  [[ -n "${CHILD_STUB:-}" ]] && rm -rf "$CHILD_STUB" || true
}

# ===========================================
# herdr-git-status-playground controller (U1)
# ===========================================

@test "herdr-git-status-playground rejects invalid CLI input without state" {
  hgsp_setup
  run hgsp_env
  assert_failure 2
  assert_output --partial "usage:"
  assert_file_not_exists "$HGSP_STATE_ROOT"

  run hgsp_env status --unknown
  assert_failure 2
  assert_output --partial "unrecognized arguments"
  assert_file_not_exists "$HGSP_STATE_ROOT"
}

@test "herdr-git-status-playground isolates profiles and child environments" {
  hgsp_setup
  run hgsp_start
  assert_failure 1
  hgsp_capture_run_id
  assert_equal "$(hgsp_json_field "$output" lifecycle_state)" provisioning
  assert_equal "$(hgsp_json_field "$output" error.code)" FOUNDATION_PROCESS_RUNNING

  run "$HGSP_PYTHON" - "$HGSP_ENV_LOG" "$(hgsp_manifest "$HGSP_LAST_RUN_ID")" "$HGSP_WORK" <<'PY'
import json
import os
import sys

env_log, manifest_path, work = sys.argv[1:]
records = [json.loads(line) for line in open(env_log, encoding="utf-8") if line.strip()]
by_class = {record["class"]: record["environment"] for record in records}
required = {"controller-git", "controller-gh", "candidate-build", "candidate-runtime", "viewer"}
assert required <= by_class.keys(), by_class.keys()
poisoned = {
    "HERDR_ENV", "HERDR_SESSION", "HERDR_SOCKET_PATH", "HERDR_CLIENT_SOCKET_PATH",
    "HERDR_CONFIG_PATH", "GH_REPO", "GH_HOST", "GITHUB_REPOSITORY", "GITHUB_TOKEN",
    "SSH_AUTH_SOCK", "GPG_AGENT_INFO", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH",
    "LD_PRELOAD", "LD_LIBRARY_PATH", "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP",
    "NODE_OPTIONS", "RUBYOPT", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "SSH_ASKPASS",
}
for name, child in by_class.items():
    assert poisoned.isdisjoint(child), (name, poisoned & child.keys())
    assert child["NO_COLOR"] == "safe-control", (name, child)
    assert work + "/poison-bin" not in child["PATH"], (name, child["PATH"])
assert "GH_TOKEN" not in by_class["candidate-build"]
assert "GH_TOKEN" not in by_class["viewer"]
assert by_class["controller-gh"]["GH_TOKEN"] == "<redacted>"
assert by_class["candidate-runtime"]["GH_TOKEN"] == "<redacted>"
git = by_class["controller-git"]
assert git["GIT_CONFIG_SYSTEM"] == "/dev/null"
assert git["GIT_TERMINAL_PROMPT"] == "0"
assert git["HOME"].startswith(work + "/xdg-state/herdr-git-status-playground/runs/")
assert git["GIT_CONFIG_GLOBAL"].startswith(git["HOME"])
assert git["HERDR_PLAYGROUND_CANONICAL_REMOTE"] == "https://github.com/example/herdr-status-fixtures.git"
assert git["GIT_CONFIG_KEY_0"] == "credential.helper"
controller_root = os.path.dirname(git["HOME"])
assert git["GIT_CONFIG_VALUE_0"].startswith("store --file=" + controller_root + "/")
assert not os.path.exists(git["GIT_CONFIG_VALUE_0"].removeprefix("store --file="))
assert git["GIT_ASKPASS"] != "poison"
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
assert manifest["canonical_remote"] == "https://github.com/example/herdr-status-fixtures.git"
profiles = manifest["profiles"]
assert len(profiles) == 5
keys = ("home", "config_home", "state_home", "data_home", "socket")
for key in keys:
    values = [profile[key] for profile in profiles.values()]
    assert len(values) == len(set(values)), (key, values)
live_roots = [work + "/live-config/herdr", work + "/xdg-state/herdr", work + "/live-data/herdr"]
for profile in profiles.values():
    for key in keys:
        path = os.path.realpath(profile[key])
        assert all(os.path.commonpath([path, root]) != root for root in live_roots), (path, live_roots)
run_root = os.path.dirname(manifest_path)
for directory, _, files in os.walk(run_root):
    for name in files:
        contents = open(os.path.join(directory, name), "rb").read()
        assert b"controller-canary" not in contents, os.path.join(directory, name)
        assert b"candidate-canary" not in contents, os.path.join(directory, name)
PY
  assert_success
}

@test "herdr-git-status-playground rejects every missing dependency before launch" {
  hgsp_setup
  local tool expected
  for tool in cargo node jq gh git python3; do
    mv "$HGSP_STUB/$tool" "$HGSP_STUB/$tool.off"
    run hgsp_start
    assert_failure 1
    expected="$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')_NOT_FOUND"
    assert_equal "$(hgsp_json_field "$output" error.code)" "$expected"
    hgsp_assert_no_launch_or_mutation
    mv "$HGSP_STUB/$tool.off" "$HGSP_STUB/$tool"
  done
}

@test "herdr-git-status-playground pins Herdr 0.8.2 to its approved path" {
  hgsp_setup
  mv "$HGSP_STUB/herdr" "$HGSP_STUB/herdr.off"
  run hgsp_start
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" HERDR_NOT_FOUND
  hgsp_assert_no_launch_or_mutation
  mv "$HGSP_STUB/herdr.off" "$HGSP_STUB/herdr"

  HGSP_HERDR_VERSION='herdr 0.8.3' run hgsp_start
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" HERDR_VERSION_UNAPPROVED
  hgsp_assert_no_launch_or_mutation

  cp "$HGSP_STUB/herdr" "$HGSP_STUB/herdr-approved"
  chmod +x "$HGSP_STUB/herdr-approved"
  local args=()
  while IFS= read -r value; do args+=("$value"); done < <(hgsp_start_args)
  args[1]="$HGSP_STUB/herdr-approved"
  run hgsp_env start "${args[@]}"
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" HERDR_PATH_CHANGED
  hgsp_assert_no_launch_or_mutation

  run hgsp_start
  assert_failure 1
  hgsp_capture_run_id
  assert_equal "$(hgsp_json_field "$output" error.code)" FOUNDATION_PROCESS_RUNNING
  hgsp_wait_for_file "$HGSP_WORK/managed-ready"
  run grep '^managed-probe|start|' "$HGSP_CALL_LOG"
  assert_success
}

@test "herdr-git-status-playground rejects unproved ownership audit and auth" {
  hgsp_setup
  local valid_fixture valid_audit
  valid_fixture="$HGSP_WORK/fixture-ownership.json"
  valid_audit="$HGSP_WORK/audit-attestation.json"

  printf '%s\n' '{"host":"github.com","owner":"example","name":"my-mac-setup","repository_id":"R_wrong","owned":true}' > "$valid_fixture"
  run hgsp_start
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" FIXTURE_OWNERSHIP_UNPROVED
  hgsp_assert_no_launch_or_mutation

  hgsp_setup
  printf '%s\n' '{"candidates":{}}' > "$HGSP_WORK/audit-attestation.json"
  run hgsp_start
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" AUDIT_ATTESTATION_INVALID
  hgsp_assert_no_launch_or_mutation

  hgsp_setup
  HGSP_GH_AUTH_STATUS=1 run hgsp_start
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" CONTROLLER_AUTH_FAILED
  hgsp_assert_no_launch_or_mutation

  hgsp_setup
  valid_fixture="$HGSP_WORK/fixture-ownership.json"
  valid_audit="$HGSP_WORK/audit-attestation.json"
  run env PATH="$HGSP_STUB:/bin" XDG_STATE_HOME="$HGSP_XDG_STATE" \
    HERDR_GIT_STATUS_PLAYGROUND_CONTROLLER_TOKEN=same \
    HERDR_GIT_STATUS_PLAYGROUND_CANDIDATE_TOKEN=same \
    HERDR_GIT_STATUS_PLAYGROUND_TEST_MODE=1 \
    "$HGSP_PYTHON" "$HGSP_CONTROLLER" start \
    --approved-herdr "$HGSP_STUB/herdr" --fixture-ownership "$valid_fixture" \
    --audit-attestation "$valid_audit"
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" CREDENTIAL_AUTHORITY_INVALID
  hgsp_assert_no_launch_or_mutation
}

@test "herdr-git-status-playground atomically replaces private manifests" {
  hgsp_setup
  run hgsp_start
  assert_failure 1
  hgsp_capture_run_id
  local manifest marker release background_output
  manifest="$(hgsp_manifest "$HGSP_LAST_RUN_ID")"
  marker="$HGSP_WORK/atomic-ready"
  release="$HGSP_WORK/atomic-release"

  HERDR_GIT_STATUS_PLAYGROUND_TEST_ATOMIC_MARKER="$marker" \
  HERDR_GIT_STATUS_PLAYGROUND_TEST_ATOMIC_RELEASE="$release" \
    hgsp_env stop "$HGSP_LAST_RUN_ID" > "$HGSP_WORK/stop.out" 2>&1 &
  HGSP_BG_PIDS="$HGSP_BG_PIDS $!"
  hgsp_wait_for_file "$marker"
  run "$HGSP_PYTHON" - "$manifest" <<'PY'
import json,sys
for _ in range(500):
    with open(sys.argv[1], encoding="utf-8") as handle:
        value = json.load(handle)
    assert isinstance(value["generation"], int)
    assert value["run_id"]
PY
  assert_success
  : > "$release"
  wait ${HGSP_BG_PIDS##* }
  HGSP_BG_PIDS=""
  background_output="$(<"$HGSP_WORK/stop.out")"
  assert_equal "$(hgsp_json_field "$background_output" lifecycle_state)" stopped
  run "$HGSP_PYTHON" -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$manifest"
  assert_success
  assert_output 600
}

@test "herdr-git-status-playground blocks spawn when intent persistence fails" {
  hgsp_setup
  local point
  for point in permission write space replace; do
    HERDR_GIT_STATUS_PLAYGROUND_TEST_FAILPOINT="intent-$point" run hgsp_start
    assert_failure 1
    hgsp_capture_run_id
    local expected
    expected="INTENT_$(printf '%s' "$point" | tr '[:lower:]' '[:upper:]')_FAILED"
    assert_equal "$(hgsp_json_field "$output" error.code)" "$expected"
    assert_equal "$(hgsp_json_field "$output" next_command)" "stop $HGSP_LAST_RUN_ID"
    hgsp_assert_no_launch_or_mutation
    run "$HGSP_PYTHON" -m json.tool "$(hgsp_manifest "$HGSP_LAST_RUN_ID")"
    assert_success
  done
}

@test "herdr-git-status-playground crash boundaries preserve recoverable intents" {
  hgsp_setup
  local point run_id manifest
  for point in before-spawn after-spawn before-identity-commit; do
    HERDR_GIT_STATUS_PLAYGROUND_TEST_FAILPOINT="$point" run hgsp_start
    assert_failure 1
    hgsp_capture_run_id
    run_id="$HGSP_LAST_RUN_ID"
    manifest="$(hgsp_manifest "$run_id")"
    assert_equal "$(hgsp_json_field "$output" run_id)" "$run_id"
    assert_equal "$(hgsp_json_field "$output" lifecycle_state)" provisioning
    run "$HGSP_PYTHON" - "$manifest" <<'PY'
import json,sys
manifest=json.load(open(sys.argv[1], encoding="utf-8"))
assert manifest["launch_intents"]
assert next(iter(manifest["launch_intents"].values()))["phase"] in {"intent-committed", "spawn-attempted"}
PY
    assert_success

    run hgsp_env status "$run_id"
    assert_success
    assert_equal "$(hgsp_json_field "$output" run_id)" "$run_id"
    run hgsp_env stop "$run_id"
    if [[ "$point" == after-spawn || "$point" == before-identity-commit ]]; then
      assert_success
    else
      assert_success
    fi
    assert_equal "$(hgsp_json_field "$output" lifecycle_state)" stopped
  done
}

@test "herdr-git-status-playground serializes mutations without elapsed-time lease stealing" {
  hgsp_setup
  run hgsp_start
  assert_failure 1
  hgsp_capture_run_id
  local run_id marker release first_pid current_start generation
  run_id="$HGSP_LAST_RUN_ID"
  marker="$HGSP_WORK/lease-held"
  release="$HGSP_WORK/lease-release"
  generation="$(hgsp_json_field "$output" generation)"

  HERDR_GIT_STATUS_PLAYGROUND_TEST_LEASE_MARKER="$marker" \
  HERDR_GIT_STATUS_PLAYGROUND_TEST_LEASE_RELEASE="$release" \
    hgsp_env stop "$run_id" > "$HGSP_WORK/first-stop.out" 2>&1 &
  first_pid=$!
  HGSP_BG_PIDS="$HGSP_BG_PIDS $first_pid"
  hgsp_wait_for_file "$marker"
  run hgsp_env stop "$run_id"
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" RUN_BUSY
  run hgsp_env status "$run_id"
  assert_success
  [[ "$(hgsp_json_field "$output" generation)" -gt "$generation" ]]
  : > "$release"
  wait "$first_pid"
  HGSP_BG_PIDS=""

  run hgsp_start
  assert_failure 1
  hgsp_capture_run_id
  run_id="$HGSP_LAST_RUN_ID"
  current_start="$(hgsp_process_start_identity "$$")"
  hgsp_set_manifest_lease "$run_id" "$$" "$current_start"
  run hgsp_env stop "$run_id"
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" RUN_BUSY

  hgsp_patch_manifest "$run_id" "manifest['mutation_lease']['start_identity']='mismatched-start-identity'"
  run hgsp_env stop "$run_id"
  assert_success
  assert_equal "$(hgsp_json_field "$output" lifecycle_state)" stopped
}

@test "herdr-git-status-playground discovers and stops partial runs by ID" {
  hgsp_setup
  HERDR_GIT_STATUS_PLAYGROUND_TEST_FAILPOINT=after-spawn run hgsp_start
  assert_failure 1
  hgsp_capture_run_id
  local run_id="$HGSP_LAST_RUN_ID"

  run hgsp_env status --all
  assert_success
  run_id="$run_id" "$HGSP_PYTHON" -c 'import json,os,sys; rows=json.loads(sys.argv[1])["runs"]; assert os.environ["run_id"] in [row["run_id"] for row in rows]' "$output"
  assert_success

  local manifest_before manifest_after
  manifest_before="$($HGSP_PYTHON -c 'import hashlib,os,sys; p=sys.argv[1]; print(hashlib.sha256(open(p,"rb").read()).hexdigest(), os.stat(p).st_mtime_ns)' "$(hgsp_manifest "$run_id")")"
  run hgsp_env status "$run_id"
  assert_success
  assert_equal "$(hgsp_json_field "$output" effective_state)" provisioning
  manifest_after="$($HGSP_PYTHON -c 'import hashlib,os,sys; p=sys.argv[1]; print(hashlib.sha256(open(p,"rb").read()).hexdigest(), os.stat(p).st_mtime_ns)' "$(hgsp_manifest "$run_id")")"
  assert_equal "$manifest_after" "$manifest_before"
  run hgsp_env stop "$run_id"
  assert_success
  assert_equal "$(hgsp_json_field "$output" lifecycle_state)" stopped
  assert_file_not_exists "$HGSP_STATE_ROOT/runs/$run_id/runtime"

  run hgsp_env stop "$run_id"
  assert_success
  assert_equal "$(hgsp_json_field "$output" lifecycle_state)" stopped
}

@test "herdr-git-status-playground interruption tears down start but only detaches view" {
  hgsp_setup
  local marker="$HGSP_WORK/start-waiting" start_pid run_id generation
  HERDR_GIT_STATUS_PLAYGROUND_TEST_START_MARKER="$marker" \
  HERDR_GIT_STATUS_PLAYGROUND_TEST_START_RELEASE="$HGSP_WORK/start-release" \
    hgsp_start > "$HGSP_WORK/start.out" 2>&1 &
  start_pid=$!
  HGSP_BG_PIDS="$HGSP_BG_PIDS $start_pid"
  hgsp_wait_for_file "$marker"
  local controller_pid
  controller_pid="$(<"$marker")"
  kill -INT "$controller_pid"
  wait "$start_pid" || true
  HGSP_BG_PIDS=""
  local start_output="$(<"$HGSP_WORK/start.out")"
  run_id="$(hgsp_json_field "$start_output" run_id)"
  HGSP_RUN_IDS="$HGSP_RUN_IDS $run_id"
  assert_equal "$(hgsp_json_field "$start_output" error.code)" START_INTERRUPTED
  run hgsp_env status "$run_id"
  assert_success
  assert_equal "$(hgsp_json_field "$output" lifecycle_state)" stopped

  run hgsp_start
  assert_failure 1
  hgsp_capture_run_id
  run_id="$HGSP_LAST_RUN_ID"
  generation="$(hgsp_json_field "$output" generation)"
  marker="$HGSP_WORK/view-waiting"
  HERDR_GIT_STATUS_PLAYGROUND_TEST_VIEW_MARKER="$marker" \
  HERDR_GIT_STATUS_PLAYGROUND_TEST_VIEW_RELEASE="$HGSP_WORK/view-release" \
    hgsp_env view "$run_id" > "$HGSP_WORK/view.out" 2>&1 &
  local view_pid=$!
  HGSP_BG_PIDS="$HGSP_BG_PIDS $view_pid"
  hgsp_wait_for_file "$marker"
  controller_pid="$(<"$marker")"
  kill -HUP "$controller_pid"
  wait "$view_pid" || true
  HGSP_BG_PIDS=""
  local view_output="$(<"$HGSP_WORK/view.out")"
  assert_equal "$(hgsp_json_field "$view_output" error.code)" VIEW_DETACHED
  run hgsp_env status "$run_id"
  assert_success
  assert_equal "$(hgsp_json_field "$output" generation)" "$generation"
  run grep 'managed-probe|TERM' "$HGSP_CALL_LOG"
  assert_failure
}

@test "herdr-git-status-playground never signals unknown or mismatched processes" {
  hgsp_setup
  run hgsp_start
  assert_failure 1
  hgsp_capture_run_id
  local run_id="$HGSP_LAST_RUN_ID"
  hgsp_wait_for_file "$HGSP_WORK/managed-ready"
  local unknown_pid
  unknown_pid="$($HGSP_PYTHON -c 'import json,sys; print(next(iter(json.load(open(sys.argv[1]))["processes"].values()))["pid"])' "$(hgsp_manifest "$run_id")")"
  hgsp_patch_manifest "$run_id" "manifest['processes']={}; next(iter(manifest['launch_intents'].values()))['claim']='runtime/launch/foundation-supervisor/missing-claim.json'"

  run hgsp_env stop "$run_id"
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" PROCESS_IDENTITY_UNRESOLVED
  run grep 'managed-probe|TERM' "$HGSP_CALL_LOG"
  assert_failure
  run hgsp_env stop "$run_id"
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" PROCESS_IDENTITY_UNRESOLVED
  run grep 'managed-probe|TERM' "$HGSP_CALL_LOG"
  assert_failure
  run hgsp_env status --all
  assert_success
  run_id="$run_id" "$HGSP_PYTHON" -c 'import json,os,sys; assert os.environ["run_id"] in [row["run_id"] for row in json.loads(sys.argv[1])["runs"]]' "$output"
  assert_success
  : > "$HGSP_WORK/managed-release"
  run "$HGSP_PYTHON" - "$unknown_pid" <<'PY'
import os,sys,time
pid=int(sys.argv[1])
for _ in range(500):
    try: os.kill(pid, 0)
    except ProcessLookupError: break
    time.sleep(0.01)
else: raise SystemExit("unrecorded fixture process did not exit after causal release")
PY
  assert_success

  hgsp_setup
  run hgsp_start
  assert_failure 1
  hgsp_capture_run_id
  run_id="$HGSP_LAST_RUN_ID"
  hgsp_wait_for_file "$HGSP_WORK/managed-ready"
  hgsp_patch_manifest "$run_id" "next(iter(manifest['processes'].values()))['start_identity']='mismatched'"

  run hgsp_env stop "$run_id"
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" lifecycle_state)" cleanup-incomplete
  assert_equal "$(hgsp_json_field "$output" error.code)" PROCESS_IDENTITY_MISMATCH
  run grep 'managed-probe|TERM' "$HGSP_CALL_LOG"
  assert_failure

  run hgsp_env stop "$run_id"
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" PROCESS_IDENTITY_MISMATCH
  run grep 'managed-probe|TERM' "$HGSP_CALL_LOG"
  assert_failure
  : > "$HGSP_WORK/managed-release"
}

@test "herdr-git-status-playground extensionless Python is excluded from shellcheck by shebang" {
  hgsp_setup
  local stubdir="$HGSP_WORK/lint-stub"
  mkdir -p "$stubdir"
  cat > "$stubdir/shellcheck" <<'SH'
#!/bin/sh
for argument in "$@"; do
  case "$argument" in
    *executable_herdr-git-status-playground) exit 99 ;;
  esac
done
exit 0
SH
  chmod +x "$stubdir/shellcheck"
  run env PATH="$stubdir:$PATH" make -C "$BATS_TEST_DIRNAME/.." lint
  assert_success
}

# ===========================================
# herdr-git-status-playground local fixtures (U2)
# ===========================================

@test "herdr-git-status-playground core fixtures match independent Git measurement" {
  hgsp_setup
  run hgsp_start
  assert_failure 1
  hgsp_capture_run_id
  run "$HGSP_PYTHON" - "$HGSP_STATE_ROOT/runs/$HGSP_LAST_RUN_ID" <<'PY'
import json
import os
import subprocess
import sys

run_dir = sys.argv[1]


def load(name):
    with open(os.path.join(run_dir, "ground-truth", name + ".json"), encoding="utf-8") as handle:
        return json.load(handle)


def git(path, *arguments, check=True):
    environment = dict(os.environ)
    environment.update(
        {
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
        }
    )
    completed = subprocess.run(
        ["git", "-C", path] + list(arguments),
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if check:
        assert completed.returncode == 0, (path, arguments, completed.stderr)
    return completed


# #then clean fixtures stay clean after every harness metadata write
for name in ("checkout-clean", "worktree-clean"):
    record = load(name)
    assert git(record["path"], "status", "--porcelain=v1").stdout == "", name
    head = git(record["path"], "rev-parse", "HEAD").stdout.strip()
    assert record["head"] == head, (name, record["head"], head)
    for family in ("staged_paths", "unstaged_paths", "untracked_paths", "unmerged_paths"):
        assert record[family] == [], (name, family, record[family])

# #then the worktree fixture is a real linked worktree by Git metadata
worktree = load("worktree-clean")
git_dir = git(worktree["path"], "rev-parse", "--git-dir").stdout.strip()
common_dir = git(worktree["path"], "rev-parse", "--git-common-dir").stdout.strip()
resolved = [os.path.realpath(os.path.join(worktree["path"], value)) for value in (git_dir, common_dir)]
assert resolved[0] != resolved[1], resolved
assert worktree["linked_worktree"] is True
assert load("checkout-clean")["linked_worktree"] is False

# #then both mixed-dirty fixtures hold one staged, one unstaged, one untracked path
for name in ("checkout-dirty", "worktree-dirty"):
    record = load(name)
    lines = sorted(line for line in git(record["path"], "status", "--porcelain=v1").stdout.splitlines() if line)
    assert lines == sorted(["A  staged.txt", " M tracked.txt", "?? untracked.txt"]), (name, lines)
    assert record["staged_paths"] == ["staged.txt"], record
    assert record["unstaged_paths"] == ["tracked.txt"], record
    assert record["untracked_paths"] == ["untracked.txt"], record
assert load("worktree-dirty")["linked_worktree"] is True
assert load("checkout-dirty")["linked_worktree"] is False
PY
  assert_success
}

@test "herdr-git-status-playground diagnostic fixtures attribute state without missing families" {
  hgsp_setup
  run hgsp_start
  assert_failure 1
  hgsp_capture_run_id
  run "$HGSP_PYTHON" - "$HGSP_STATE_ROOT/runs/$HGSP_LAST_RUN_ID" <<'PY'
import json
import os
import subprocess
import sys

run_dir = sys.argv[1]


def load(name):
    with open(os.path.join(run_dir, "ground-truth", name + ".json"), encoding="utf-8") as handle:
        return json.load(handle)


def git(path, *arguments, check=True):
    environment = dict(os.environ)
    environment.update(
        {
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
        }
    )
    completed = subprocess.run(
        ["git", "-C", path] + list(arguments),
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if check:
        assert completed.returncode == 0, (path, arguments, completed.stderr)
    return completed


# #then the conflict fixture holds verified unmerged index entries
conflict = load("conflict")
unmerged = sorted({line.split("\t")[-1] for line in git(conflict["path"], "ls-files", "-u").stdout.splitlines()})
assert unmerged == ["contested.txt"], unmerged
assert conflict["unmerged_paths"] == ["contested.txt"], conflict

# #then the diverged fixture proves positive ahead and behind counts and a nonempty stash
diverged = load("diverged-stash")
counts = git(diverged["path"], "rev-list", "--left-right", "--count", "origin/main...HEAD").stdout.split()
behind, ahead = int(counts[0]), int(counts[1])
assert ahead >= 1 and behind >= 1, counts
assert diverged["ahead"] == ahead and diverged["behind"] == behind, diverged
stash_lines = [line for line in git(diverged["path"], "stash", "list").stdout.splitlines() if line]
assert stash_lines and diverged["stash_count"] == len(stash_lines), (diverged, stash_lines)

# #then the detached fixture records the expected commit and no symbolic branch
detached = load("detached")
assert git(detached["path"], "symbolic-ref", "-q", "HEAD", check=False).returncode != 0
head = git(detached["path"], "rev-parse", "HEAD").stdout.strip()
assert detached["head"] == head and detached["branch"] is None, detached

# #then the non-git fixture has no Git parent within the disposable root
non_git = load("non-git")
assert git(non_git["path"], "rev-parse", "--git-dir", check=False).returncode != 0
probe = os.path.realpath(non_git["path"])
boundary = os.path.realpath(run_dir)
while True:
    assert not os.path.exists(os.path.join(probe, ".git")), probe
    if probe == boundary:
        break
    probe = os.path.dirname(probe)

# #then every record shares one schema; unsupported families read not applicable, never missing
order = ["checkout-clean", "checkout-dirty", "worktree-clean", "worktree-dirty",
         "conflict", "diverged-stash", "detached", "non-git"]
records = {name: load(name) for name in order}
key_sets = {frozenset(record) for record in records.values()}
assert len(key_sets) == 1, key_sets
assert records["non-git"]["repository"] == "none"
for key, value in records["non-git"].items():
    if key in ("schema_version", "label", "path", "measured_at", "repository"):
        continue
    assert value == "not applicable", (key, value)
for name in ("checkout-clean", "conflict", "detached"):
    assert records[name]["ahead"] == "not applicable", name
    assert records[name]["behind"] == "not applicable", name
assert isinstance(records["diverged-stash"]["ahead"], int)
assert isinstance(records["diverged-stash"]["behind"], int)
PY
  assert_success
}

@test "herdr-git-status-playground refuses ground truth when one premise property is sabotaged" {
  hgsp_setup
  local entry point expected_code sabotaged control
  for entry in \
    "dirty:FIXTURE_CHECKOUT_DIRTY_INCOMPLETE:checkout-dirty:checkout-clean" \
    "conflict:FIXTURE_CONFLICT_MISSING:conflict:worktree-dirty" \
    "diverged:FIXTURE_DIVERGENCE_MISSING:diverged-stash:conflict" \
    "detached:FIXTURE_DETACHED_INVALID:detached:diverged-stash" \
    "non-git:FIXTURE_NON_GIT_CONTAMINATED:non-git:detached"; do
    IFS=: read -r point expected_code sabotaged control <<< "$entry"
    HERDR_GIT_STATUS_PLAYGROUND_TEST_FAILPOINT="sabotage-$point" run hgsp_start
    assert_failure 1
    hgsp_capture_run_id
    assert_equal "$(hgsp_json_field "$output" error.code)" "$expected_code"
    assert_file_not_exists "$HGSP_STATE_ROOT/runs/$HGSP_LAST_RUN_ID/ground-truth/$sabotaged.json"
    assert_file_exists "$HGSP_STATE_ROOT/runs/$HGSP_LAST_RUN_ID/ground-truth/$control.json"
    run hgsp_env stop "$HGSP_LAST_RUN_ID"
    assert_success
    assert_equal "$(hgsp_json_field "$output" lifecycle_state)" stopped
  done
}

@test "herdr-git-status-playground fixture interruption never publishes partial ground truth" {
  hgsp_setup
  local fixtures="checkout-clean checkout-dirty worktree-clean worktree-dirty conflict diverged-stash detached non-git"
  local index=0 name run_id expected_code
  for name in $fixtures; do
    HERDR_GIT_STATUS_PLAYGROUND_TEST_FAILPOINT="fixture-$name" run hgsp_start
    assert_failure 1
    hgsp_capture_run_id
    run_id="$HGSP_LAST_RUN_ID"
    expected_code="INJECTED_FIXTURE_$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')"
    assert_equal "$(hgsp_json_field "$output" error.code)" "$expected_code"
    run "$HGSP_PYTHON" - "$HGSP_STATE_ROOT/runs/$run_id" "$index" <<'PY'
import json
import os
import sys

run_dir, index = sys.argv[1], int(sys.argv[2])
order = ["checkout-clean", "checkout-dirty", "worktree-clean", "worktree-dirty",
         "conflict", "diverged-stash", "detached", "non-git"]
directory = os.path.join(run_dir, "ground-truth")
present = sorted(os.listdir(directory)) if os.path.isdir(directory) else []
assert present == sorted(name + ".json" for name in order[:index]), (present, index)
with open(os.path.join(run_dir, "manifest.json"), encoding="utf-8") as handle:
    manifest = json.load(handle)
assert sorted(manifest.get("local_fixtures", {})) == sorted(order[:index]), manifest.get("local_fixtures")
assert "fixture_assignments" not in manifest
PY
    assert_success
    run hgsp_env stop "$run_id"
    assert_success
    assert_equal "$(hgsp_json_field "$output" lifecycle_state)" stopped
    index=$((index + 1))
  done

  run hgsp_start
  assert_failure 1
  hgsp_capture_run_id
  run "$HGSP_PYTHON" - "$HGSP_STATE_ROOT/runs/$HGSP_LAST_RUN_ID" <<'PY'
import json
import os
import sys

run_dir = sys.argv[1]
order = ["checkout-clean", "checkout-dirty", "worktree-clean", "worktree-dirty",
         "conflict", "diverged-stash", "detached", "non-git"]
present = sorted(os.listdir(os.path.join(run_dir, "ground-truth")))
assert present == sorted(name + ".json" for name in order), present
with open(os.path.join(run_dir, "manifest.json"), encoding="utf-8") as handle:
    manifest = json.load(handle)
assert sorted(manifest["local_fixtures"]) == sorted(order)
assert "fixture_assignments" in manifest
PY
  assert_success
}

@test "herdr-git-status-playground assigns identical ordered catalogs to candidates and a workspace to the viewer" {
  hgsp_setup
  run hgsp_start
  assert_failure 1
  hgsp_capture_run_id
  run "$HGSP_PYTHON" - "$HGSP_STATE_ROOT/runs/$HGSP_LAST_RUN_ID" <<'PY'
import json
import os
import sys

run_dir = sys.argv[1]
with open(os.path.join(run_dir, "manifest.json"), encoding="utf-8") as handle:
    manifest = json.load(handle)
assignments = manifest["fixture_assignments"]
assert sorted(assignments) == ["ezcorp", "jmarbutt", "krystof", "sfroment"], sorted(assignments)
order = ["checkout-clean", "checkout-dirty", "worktree-clean", "worktree-dirty",
         "conflict", "diverged-stash", "detached", "non-git"]
reference = assignments["ezcorp"]
assert [entry["label"] for entry in reference] == order, reference
canonical = json.dumps(reference, sort_keys=True)
for profile_id, catalog in assignments.items():
    assert json.dumps(catalog, sort_keys=True) == canonical, profile_id
for entry in reference:
    assert os.path.isdir(entry["path"]), entry
    assert os.path.basename(entry["path"]) == entry["label"], entry
workspace = os.path.realpath(manifest["viewer_workspace"])
viewer_root = os.path.realpath(os.path.dirname(manifest["profiles"]["viewer"]["home"]))
assert os.path.commonpath([workspace, viewer_root]) == viewer_root, (workspace, viewer_root)
assert os.path.isdir(workspace)
fixture_paths = {os.path.realpath(entry["path"]) for entry in reference}
assert workspace not in fixture_paths
for path in fixture_paths:
    assert os.path.commonpath([path, workspace]) != workspace, (path, workspace)
PY
  assert_success
}

# ===========================================
# herdr-git-status-playground GitHub fixtures (U3)
# ===========================================

@test "herdr-git-status-playground initialization refuses foreign, nonempty, unauthorized, and mismatched repositories" {
  hgsp_setup
  hgsp_github_setup

  printf '%s\n' '{"host":"github.com","owner":"example","name":"my-mac-setup","repository_id":"R_fixture_1","owned":true}' > "$HGSP_WORK/fixture-ownership.json"
  run hgsp_initialize
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" FIXTURE_OWNERSHIP_UNPROVED

  printf '%s\n' '{"host":"github.com","owner":"example","name":"herdr-status-fixtures","repository_id":"R_other","owned":true}' > "$HGSP_WORK/fixture-ownership.json"
  run hgsp_initialize
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" REPOSITORY_ID_MISMATCH

  printf '%s\n' '{"host":"github.com","owner":"example","name":"herdr-status-fixtures","repository_id":"R_fixture_1","owned":true}' > "$HGSP_WORK/fixture-ownership.json"
  hgsp_patch_github_state 'state["tokens"]["controller-canary"] = "read"'
  run hgsp_initialize
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" REPOSITORY_PERMISSION_INSUFFICIENT
  hgsp_patch_github_state 'state["tokens"]["controller-canary"] = "write"'

  hgsp_seed_remote_ref refs/heads/unrelated-topic "unrelated operator content"
  run hgsp_initialize
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" REPOSITORY_NOT_EMPTY
  run hgsp_remote_git rev-parse refs/heads/main
  assert_failure
  assert_file_not_exists "$(hgsp_repo_record)"

  # #then the nearby valid control reaches the success path once the repository is empty
  hgsp_remote_git update-ref -d refs/heads/unrelated-topic
  run hgsp_initialize
  assert_success
  assert_equal "$(hgsp_json_field "$output" initialized)" true
  assert_file_exists "$(hgsp_repo_record)"
}

@test "herdr-git-status-playground first initialization claims atomically and a concurrent initializer loses without mutation" {
  hgsp_setup
  hgsp_github_setup
  hgsp_seed_remote_ref refs/heads/herdr-playground/lease "foreign concurrent lease"
  run hgsp_initialize
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" INITIALIZE_LEASE_LOST
  run hgsp_remote_git rev-parse refs/heads/main
  assert_failure
  assert_file_not_exists "$(hgsp_repo_record)"

  hgsp_remote_git update-ref -d refs/heads/herdr-playground/lease
  run hgsp_initialize
  assert_success
  assert_equal "$(hgsp_json_field "$output" lease)" released
  # #then the lease acquisition demanded the absent-ref compare-and-swap form
  run grep -E -- '--force-with-lease=refs/heads/herdr-playground/lease:$' "$HGSP_CALL_LOG"
  assert_success
  # #then one atomic claim created the default branch with marker plus workflow
  run hgsp_remote_git rev-list --count refs/heads/main
  assert_success
  assert_output 1
  run hgsp_remote_git show refs/heads/main:.herdr-git-status-playground.json
  assert_success
  local marker="$output"
  assert_equal "$(hgsp_json_field "$marker" repository_id)" R_fixture_1
  assert_equal "$(hgsp_json_field "$marker" host)" github.com
  assert_equal "$(hgsp_json_field "$marker" namespace)" "herdr-playground/"
  run hgsp_remote_git show refs/heads/main:.github/workflows/herdr-git-status-playground.yml
  assert_success
  # #then the exact lease was verified and conditionally deleted
  run hgsp_remote_git rev-parse refs/heads/herdr-playground/lease
  assert_failure
  # #then durable controller state never retains a credential canary
  run grep -r controller-canary "$HGSP_STATE_ROOT"
  assert_failure
  run grep -r candidate-canary "$HGSP_STATE_ROOT"
  assert_failure
}

@test "herdr-git-status-playground installs an inert pinned workflow and blocks bootstrap on policy drift" {
  hgsp_setup
  hgsp_github_setup
  run hgsp_initialize
  assert_success
  hgsp_remote_git show refs/heads/main:.github/workflows/herdr-git-status-playground.yml > "$HGSP_WORK/installed-workflow.yml"
  run "$HGSP_PYTHON" - "$HGSP_WORK/installed-workflow.yml" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
assert "permissions: {}" in text, text
assert "timeout-minutes:" in text
assert "concurrency:" in text
for forbidden in ("secret", "environment", "pull_request", "issue_comment", "workflow_run", "repository_dispatch", "schedule"):
    assert forbidden not in text, forbidden
assert "push:" in text and "workflow_dispatch:" in text
for line in text.splitlines():
    if "uses:" in line:
        pinned = line.split("@")[-1].strip().strip('"')
        assert re.fullmatch(r"[0-9a-f]{40}", pinned), line
PY
  assert_success

  hgsp_patch_github_state 'repo["secrets_total"] = 1'
  run hgsp_bootstrap
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" REPOSITORY_POLICY_DRIFT
  assert_equal "$(hgsp_json_field "$output" lease)" not-acquired
  run hgsp_remote_git rev-parse refs/heads/herdr-playground/lease
  assert_failure
  hgsp_patch_github_state 'repo["secrets_total"] = 0'

  hgsp_patch_github_state 'repo["environments_total"] = 2'
  run hgsp_bootstrap
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" REPOSITORY_POLICY_DRIFT
  hgsp_patch_github_state 'repo["environments_total"] = 0'

  # #then the nearby control converges once policy drift is repaired
  run hgsp_bootstrap
  assert_success
}

@test "herdr-git-status-playground repeated bootstrap converges without duplicates or unrelated branch changes" {
  hgsp_setup
  hgsp_github_setup
  run hgsp_initialize
  assert_success
  hgsp_seed_remote_ref refs/heads/unrelated-topic "operator branch outside the namespace"
  local unrelated_sha
  unrelated_sha="$(hgsp_remote_git rev-parse refs/heads/unrelated-topic)"

  run hgsp_bootstrap
  assert_success
  assert_equal "$(hgsp_json_field "$output" lease)" released
  assert_equal "$(hgsp_github_query 'len(repo["pulls"])')" 4
  cp "$(hgsp_repo_record)" "$HGSP_WORK/first-record.json"

  run hgsp_bootstrap
  assert_success
  assert_equal "$(hgsp_github_query 'len(repo["pulls"])')" 4
  assert_equal "$(hgsp_github_query 'len([p for p in repo["pulls"] if p["state"] == "open"])')" 4
  run "$HGSP_PYTHON" -c 'import json,sys; a=json.load(open(sys.argv[1]))["fixtures"]; b=json.load(open(sys.argv[2]))["fixtures"]; assert a==b, (a,b)' \
    "$HGSP_WORK/first-record.json" "$(hgsp_repo_record)"
  assert_success
  assert_equal "$(hgsp_remote_git rev-parse refs/heads/unrelated-topic)" "$unrelated_sha"
  run hgsp_remote_git rev-parse refs/heads/herdr-playground/lease
  assert_failure
}

@test "herdr-git-status-playground releases its lease on clean outcomes and retains it across partial mutation" {
  hgsp_setup
  hgsp_github_setup
  run hgsp_initialize
  assert_success

  HERDR_GIT_STATUS_PLAYGROUND_TEST_FAILPOINT=bootstrap-pre-mutation run hgsp_bootstrap
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" INJECTED_BOOTSTRAP_PRE_MUTATION
  assert_equal "$(hgsp_json_field "$output" lease)" released
  run hgsp_remote_git rev-parse refs/heads/herdr-playground/lease
  assert_failure
  assert_equal "$(hgsp_record_field recovery)" None

  HERDR_GIT_STATUS_PLAYGROUND_TEST_FAILPOINT=bootstrap-partial-draft run hgsp_bootstrap
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" INJECTED_BOOTSTRAP_PARTIAL
  assert_equal "$(hgsp_json_field "$output" lease)" retained
  run hgsp_remote_git rev-parse refs/heads/herdr-playground/lease
  assert_success
  run "$HGSP_PYTHON" - "$(hgsp_repo_record)" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))
recovery = record["recovery"]
assert recovery and recovery["operation_kind"] == "bootstrap", recovery
assert recovery["operation_id"], recovery
mutations = recovery["mutations"]
assert mutations, recovery
for mutation in mutations:
    assert mutation["ref"].startswith("refs/heads/herdr-playground/"), mutation
    assert len(mutation["new_sha"]) == 40, mutation
    assert "fixture" in mutation and "expected" in mutation, mutation
PY
  assert_success

  # #then resuming converges forward through matched compare-and-swap state
  run hgsp_bootstrap
  assert_success
  assert_equal "$(hgsp_json_field "$output" lease)" released
  assert_equal "$(hgsp_github_query 'len(repo["pulls"])')" 4
  assert_equal "$(hgsp_github_query 'len([p for p in repo["pulls"] if p["state"] == "open"])')" 4
  run hgsp_remote_git rev-parse refs/heads/herdr-playground/lease
  assert_failure
  assert_equal "$(hgsp_record_field recovery)" None

  # #then a foreign lease fails closed with exact inspection guidance
  hgsp_seed_remote_ref refs/heads/herdr-playground/lease "foreign holder"
  run hgsp_bootstrap
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" REPOSITORY_LEASE_HELD
  assert_output --partial "git ls-remote"
  hgsp_remote_git update-ref -d refs/heads/herdr-playground/lease
  run hgsp_bootstrap
  assert_success
}

@test "herdr-git-status-playground ambient selectors cannot redirect queries or mutations" {
  hgsp_setup
  hgsp_github_setup
  local decoy_host_sha decoy_repo_sha poison_cwd
  decoy_host_sha="$(hgsp_real_git --git-dir "$HGSP_WORK/remote/decoy-host.git" rev-parse main)"
  decoy_repo_sha="$(hgsp_real_git --git-dir "$HGSP_WORK/remote/decoy-repo.git" rev-parse main)"
  poison_cwd="$HGSP_WORK/poison-cwd"
  hgsp_real_git init --quiet --initial-branch=main "$poison_cwd"
  hgsp_real_git -C "$poison_cwd" remote add origin "https://wrong.example/example/herdr-status-fixtures.git"

  cd "$poison_cwd"
  run hgsp_initialize
  assert_success
  run hgsp_bootstrap
  assert_success
  cd "$BATS_TEST_DIRNAME"

  run "$HGSP_PYTHON" - "$HGSP_CALL_LOG" <<'PY'
import sys

lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.startswith("gh-sim|")]
assert lines
for line in lines:
    fields = dict(part.split("=", 1) for part in line.split("|")[1:])
    assert fields["host"] == "github.com", line
    assert fields["path"].startswith("repos/example/herdr-status-fixtures"), line
    assert fields["ghrepo"] == "-", line
    assert fields["ghhost"] == "-", line
PY
  assert_success
  assert_equal "$(hgsp_real_git --git-dir "$HGSP_WORK/remote/decoy-host.git" rev-parse main)" "$decoy_host_sha"
  assert_equal "$(hgsp_real_git --git-dir "$HGSP_WORK/remote/decoy-repo.git" rev-parse main)" "$decoy_repo_sha"
  run "$HGSP_PYTHON" -c 'import json,sys; s=json.load(open(sys.argv[1]))["repositories"]; assert not s["wrong.example/example/herdr-status-fixtures"]["pulls"]; assert not s["github.com/wrong/repo"]["pulls"]' "$HGSP_WORK/github-state.json"
  assert_success
  run grep -E 'git-auth\|[a-z-]+\|(wrong\.example|github\.com/wrong)' "$HGSP_CALL_LOG"
  assert_failure
}

@test "herdr-git-status-playground blocks startup on marker, workflow, default-branch, and namespace drift" {
  hgsp_setup
  hgsp_github_setup
  run hgsp_initialize
  assert_success
  local original_marker original_workflow
  original_marker="$(hgsp_remote_git show refs/heads/main:.herdr-git-status-playground.json)"
  original_workflow="$(hgsp_remote_git show refs/heads/main:.github/workflows/herdr-git-status-playground.yml)"

  hgsp_patch_github_state 'repo["default_branch"] = "trunk"'
  run hgsp_bootstrap
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" DEFAULT_BRANCH_MISMATCH
  assert_output --partial "inspect"
  hgsp_patch_github_state 'repo["default_branch"] = "main"'

  printf 'not json at all\n' | hgsp_rewrite_default_file .herdr-git-status-playground.json
  run hgsp_bootstrap
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" MARKER_INVALID
  assert_output --partial "inspect"

  "$HGSP_PYTHON" -c 'import json,sys; marker=json.loads(sys.argv[1]); marker["namespace"]="other/"; print(json.dumps(marker))' "$original_marker" \
    | hgsp_rewrite_default_file .herdr-git-status-playground.json
  run hgsp_bootstrap
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" NAMESPACE_MISMATCH
  printf '%s\n' "$original_marker" | hgsp_rewrite_default_file .herdr-git-status-playground.json

  printf '%s\n# drifted outside the controller\n' "$original_workflow" | hgsp_rewrite_default_file .github/workflows/herdr-git-status-playground.yml
  run hgsp_bootstrap
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" WORKFLOW_DRIFT
  assert_output --partial "inspect"
  printf '%s\n' "$original_workflow" | hgsp_rewrite_default_file .github/workflows/herdr-git-status-playground.yml

  # #then the nearby control converges after external repair
  run hgsp_bootstrap
  assert_success
}

@test "herdr-git-status-playground no-pr fixture rotates away from closed pull-request history" {
  hgsp_setup
  hgsp_github_setup
  run hgsp_initialize
  assert_success
  run hgsp_bootstrap
  assert_success
  local v1_branch
  v1_branch="$(hgsp_record_field fixtures.no-pr.branch)"
  assert_equal "$v1_branch" "herdr-playground/no-pr/v1"

  hgsp_patch_github_state "repo['pulls'].append({'number': repo['next_pr_number'], 'node_id': 'PR_history', 'state': 'closed', 'draft': False, 'head_ref': '$v1_branch', 'head_sha': '0'*40, 'base_ref': 'main', 'user': 'playground-controller', 'mergeable': None, 'mergeable_state': 'unknown'}); repo['next_pr_number'] += 1"
  run hgsp_bootstrap
  assert_success
  local v2_branch
  v2_branch="$(hgsp_record_field fixtures.no-pr.branch)"
  assert_equal "$v2_branch" "herdr-playground/no-pr/v2"
  run "$HGSP_PYTHON" -c 'import json,sys; repo=json.load(open(sys.argv[1]))["repositories"]["github.com/example/herdr-status-fixtures"]; assert not [p for p in repo["pulls"] if p["head_ref"] == sys.argv[2]], "rotated branch has history"' \
    "$HGSP_WORK/github-state.json" "$v2_branch"
  assert_success
  assert_equal "$(hgsp_github_query 'len([p for p in repo["pulls"] if p["state"] == "closed"])')" 1
  assert_equal "$(hgsp_record_field fixtures.no-pr.checkout.branch)" "$v2_branch"

  # #then the retired branch does not read as foreign drift on the next pass
  run hgsp_bootstrap
  assert_success
  assert_equal "$(hgsp_record_field fixtures.no-pr.branch)" "$v2_branch"
}

@test "herdr-git-status-playground selects exact workflow records and settles mergeability authority" {
  hgsp_setup
  hgsp_github_setup
  run hgsp_initialize
  assert_success
  hgsp_patch_github_state 'repo["decoy_runs"] = True'
  hgsp_patch_github_state "repo['workflow_runs'].append({'id': 8000, 'name': 'herdr-git-status-playground', 'head_branch': 'herdr-playground/checks-passed/head', 'head_sha': 'e'*40, 'status': 'completed', 'conclusion': 'failure', 'event': 'push'})"
  run hgsp_bootstrap
  assert_success
  run "$HGSP_PYTHON" - "$(hgsp_repo_record)" "$HGSP_WORK/github-state.json" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))
repo = json.load(open(sys.argv[2], encoding="utf-8"))["repositories"]["github.com/example/herdr-status-fixtures"]
runs = {run["id"]: run for run in repo["workflow_runs"]}
for name, conclusion in (("checks-passed", "success"), ("checks-failed", "failure"), ("draft", "success")):
    fixture = record["fixtures"][name]
    run = runs[fixture["workflow_run_id"]]
    assert run["name"] == "herdr-git-status-playground", run
    assert run["head_branch"] == fixture["branch"], (run, fixture)
    assert run["head_sha"] == fixture["head_sha"], (run, fixture)
    assert run["conclusion"] == conclusion, run
conflict = record["fixtures"]["merge-conflict"]
assert conflict["mergeable"] is False, conflict
assert conflict["mergeable_state"] == "dirty", conflict
pull = [p for p in repo["pulls"] if p["number"] == conflict["pr_number"]][0]
assert pull["mergeable"] is False and pull["mergeable_state"] == "dirty", pull
PY
  assert_success
  # #then mergeability was polled until the authority settled, never assumed
  run grep -cF "path=repos/example/herdr-status-fixtures/pulls/$(hgsp_record_field fixtures.merge-conflict.pr_number)|" "$HGSP_CALL_LOG"
  assert_success
  [[ "$output" -ge 3 ]]
}

@test "herdr-git-status-playground treats unrecorded owned-namespace changes as drift, never overwriting" {
  hgsp_setup
  hgsp_github_setup
  run hgsp_initialize
  assert_success
  run hgsp_bootstrap
  assert_success

  hgsp_seed_remote_ref refs/heads/herdr-playground/draft/head "unrecorded commit" refs/heads/herdr-playground/draft/head
  local drifted_sha
  drifted_sha="$(hgsp_remote_git rev-parse refs/heads/herdr-playground/draft/head)"
  run hgsp_bootstrap
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" OWNERSHIP_DRIFT
  assert_equal "$(hgsp_remote_git rev-parse refs/heads/herdr-playground/draft/head)" "$drifted_sha"
  hgsp_remote_git update-ref refs/heads/herdr-playground/draft/head "$(hgsp_record_field fixtures.draft.head_sha)"
  run hgsp_bootstrap
  assert_success

  hgsp_patch_github_state "[p for p in repo['pulls'] if p['head_ref'] == 'herdr-playground/draft/head'][0].update({'user': 'intruder'})"
  run hgsp_bootstrap
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" OWNERSHIP_DRIFT
  hgsp_patch_github_state "[p for p in repo['pulls'] if p['head_ref'] == 'herdr-playground/draft/head'][0].update({'user': 'playground-controller'})"

  hgsp_patch_github_state "pr = [p for p in repo['pulls'] if p['head_ref'] == 'herdr-playground/checks-passed/head'][0]; pr['state'] = 'closed'; repo['pulls'].append(dict(pr, number=repo['next_pr_number'], node_id='PR_replaced', state='open')); repo['next_pr_number'] += 1"
  run hgsp_bootstrap
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" OWNERSHIP_DRIFT
  hgsp_patch_github_state "repo['pulls'] = [p for p in repo['pulls'] if p['node_id'] != 'PR_replaced']; [p for p in repo['pulls'] if p['head_ref'] == 'herdr-playground/checks-passed/head'][0].update({'state': 'open'})"

  local run_id
  run_id="$(hgsp_record_field fixtures.checks-passed.workflow_run_id)"
  hgsp_patch_github_state "[r for r in repo['workflow_runs'] if r['id'] == $run_id][0]['conclusion'] = 'failure'"
  run hgsp_bootstrap
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" OWNERSHIP_DRIFT
  hgsp_patch_github_state "[r for r in repo['workflow_runs'] if r['id'] == $run_id][0]['conclusion'] = 'success'"

  hgsp_seed_remote_ref refs/heads/herdr-playground/foreign "foreign namespace branch"
  run hgsp_bootstrap
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" OWNERSHIP_DRIFT
  hgsp_remote_git update-ref -d refs/heads/herdr-playground/foreign

  # #then the nearby control converges once drift is externally resolved
  run hgsp_bootstrap
  assert_success
}

@test "herdr-git-status-playground records verified fixture checkouts under controller-only credentials" {
  hgsp_setup
  hgsp_github_setup
  run hgsp_initialize
  assert_success
  run hgsp_bootstrap
  assert_success

  # #then every remote fixture has a recorded checkout with exact origin, branch, and head
  run "$HGSP_PYTHON" - "$(hgsp_repo_record)" <<'PY'
import json
import os
import subprocess
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))
environment = dict(os.environ)
environment.update(
    {
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
    }
)


def git(path, *arguments):
    return subprocess.check_output(["git", "-C", path] + list(arguments), env=environment, text=True).strip()


fixtures = record["fixtures"]
assert sorted(fixtures) == ["checks-failed", "checks-passed", "draft", "merge-conflict", "no-pr"], sorted(fixtures)
for name, fixture in fixtures.items():
    checkout = fixture["checkout"]
    path = checkout["path"]
    assert os.path.isdir(path), path
    assert git(path, "remote", "get-url", "origin") == "https://github.com/example/herdr-status-fixtures.git", name
    assert git(path, "symbolic-ref", "--short", "HEAD") == checkout["branch"] == fixture["branch"], name
    assert git(path, "rev-parse", "HEAD") == checkout["head_sha"] == fixture["head_sha"], name
PY
  assert_success

  # #then bootstrap authenticated exclusively with the scoped controller credential
  run "$HGSP_PYTHON" - "$HGSP_CALL_LOG" <<'PY'
import sys

lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8")]
gh = [line for line in lines if line.startswith("gh-sim|")]
auth = [line for line in lines if line.startswith("git-auth|")]
assert gh and auth
for line in gh + auth:
    assert "candidate-canary" not in line, line
    assert "token=controller-canary" in line, line
PY
  assert_success
  run grep -r candidate-canary "$HGSP_STATE_ROOT"
  assert_failure
  run grep -r controller-canary "$HGSP_STATE_ROOT"
  assert_failure

  # #then the candidate-read credential cannot mutate the repository
  local refs_before
  refs_before="$(hgsp_remote_git for-each-ref)"
  HGSP_CONTROLLER_TOKEN=candidate-canary run hgsp_bootstrap
  assert_failure 1
  assert_equal "$(hgsp_json_field "$output" error.code)" REPOSITORY_PERMISSION_INSUFFICIENT
  assert_equal "$(hgsp_remote_git for-each-ref)" "$refs_before"
}

@test "herdr-git-status-playground defers approved and changes-requested states silently" {
  hgsp_setup
  hgsp_github_setup
  run hgsp_initialize
  assert_success
  run hgsp_bootstrap
  assert_success
  assert_equal "$(hgsp_json_field "$output" error)" None
  summary="$output" "$HGSP_PYTHON" -c 'import json,os; out=json.loads(os.environ["summary"]); assert sorted(out["fixtures"]) == ["checks-failed", "checks-passed", "draft", "merge-conflict", "no-pr"], out; text=json.dumps(out).lower(); assert "approved" not in text; assert "changes-requested" not in text; assert "changes_requested" not in text'
  run grep -iE 'approved|changes.requested' "$(hgsp_repo_record)"
  assert_failure
}

# ===========================================
# python3 -- the declared interpreter
# ===========================================

# First, so a missing or too-old interpreter states its own cause instead of
# leaving the bare `python3` call sites below to fail without naming it.
@test "python3 is present and at least 3.9, the floor README.md declares" {
  assert_python3_available
}

# ===========================================
# Repository linting
# ===========================================

@test "lint target propagates shellcheck failures" {
  local repo_root="$BATS_TEST_DIRNAME/.."
  [[ -f "$repo_root/Makefile" ]] || skip "repo-root Makefile is not available in this environment"

  local stubdir
  stubdir="$(mktemp -d)"
  printf '#!/bin/sh\nexit 1\n' > "$stubdir/shellcheck"
  chmod +x "$stubdir/shellcheck"

  run env PATH="$stubdir:$PATH" make -C "$repo_root" lint
  rm -rf "$stubdir"
  assert_failure
}

# ===========================================
# install-packages script
# ===========================================

# --source is load-bearing here, not decoration. This script's `include`
# directives resolve against the chezmoi source directory, so without it the
# script is read from the checkout under test while its includes are read from
# whatever tree the host's chezmoi config points at. Those are the same
# directory in CI and in Docker, which is why this passed for so long; they are
# different in a git worktree, and the mismatch surfaced the moment the
# Brewfiles were renamed in one tree and not the other.
render_install_packages() {
  local config_args=()
  if [[ -n "${1:-}" ]]; then
    config_args=(--config "$1")
  fi
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" "${config_args[@]}" \
    --source "$SOURCE_ROOT" execute-template \
    < "$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl"
}

@test "CI-minimal Linux render skips Homebrew but keeps the remaining setup" {
  skip_if_no_chezmoi
  local cfg="$BATS_TEST_TMPDIR/minimal-linux.yaml"
  MMS_CI_MINIMAL=1 write_test_config "$cfg"
  sed -i.bak 's/^  is_linux: .*/  is_linux: true/' "$cfg"

  run render_install_packages "$cfg"
  assert_success
  refute_output --partial 'Installing Homebrew'
  refute_output --partial 'brew bundle --file='
  assert_output --partial 'Installing Oh My Zsh'
  assert_output --partial 'Installing fff-mcp'
}

@test "full Linux render keeps Homebrew package installation" {
  skip_if_no_chezmoi
  local cfg="$BATS_TEST_TMPDIR/full-linux.yaml"
  MMS_CI_MINIMAL="" write_test_config "$cfg"
  sed -i.bak 's/^  is_linux: .*/  is_linux: true/' "$cfg"

  run render_install_packages "$cfg"
  assert_success
  assert_output --partial 'Installing Homebrew'
  assert_output --partial 'brew bundle --file="$BREWFILES_DIR/Brewfile"'
}

@test "CI-minimal non-Linux render keeps Homebrew package installation" {
  skip_if_no_chezmoi
  local cfg="$BATS_TEST_TMPDIR/minimal-non-linux.yaml"
  MMS_CI_MINIMAL=1 write_test_config "$cfg"
  sed -i.bak 's/^  is_linux: .*/  is_linux: false/' "$cfg"

  run render_install_packages "$cfg"
  assert_success
  assert_output --partial 'Installing Homebrew'
  assert_output --partial 'brew bundle --file="$BREWFILES_DIR/Brewfile"'
}

@test "install-packages script renders as valid bash" {
  skip_if_no_chezmoi
  BATS_TEST_TMPFILE="$BATS_TEST_TMPDIR/install-packages.sh"
  render_install_packages > "$BATS_TEST_TMPFILE"
  run bash -n "$BATS_TEST_TMPFILE"
  assert_success
}

# ===========================================
# macOS tunes script
# ===========================================

@test "macos-tunes script is valid bash" {
  local script="$SOURCE_ROOT/.chezmoiscripts/darwin/run_once_after_macos-tunes.sh"
  run bash -n "$script"
  assert_success
}

@test "darwin scripts excluded from managed list on Linux" {
  is_linux || skip "Only relevant on Linux"
  skip_if_no_chezmoi
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" managed
  refute_output --partial "run_once_after_macos-tunes"
}

# ===========================================
# ask-in-herdr skill script
# ===========================================

ASK_HERDR_DIR="$SOURCE_ROOT/private_dot_claude/skills/ask-in-herdr/scripts"

ask_live_stub() {
  CHILD_STUB="$(mktemp -d)"
  export CHILD_STUB
  cat > "$CHILD_STUB/herdr-child" <<'SH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$CHILD_STUB/child.log"; printf '\n' >> "$CHILD_STUB/child.log"
name=""
while [ $# -gt 0 ]; do
  case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac
done
printf '{"agent":"%s","pane":"wT:p9"}\n' "$name"
[ "${STUB_CHILD_STATUS:-0}" -eq 0 ] || { printf 'child-start-error\n' >&2; exit "$STUB_CHILD_STATUS"; }
SH
  cat > "$CHILD_STUB/herdr" <<'SH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$CHILD_STUB/herdr.log"; printf '\n' >> "$CHILD_STUB/herdr.log"
case "$1 $2" in
  "agent list")
    if [ "${STUB_NAME_COLLISION:-0}" = 1 ]; then
      parent="$PPID"
      grandparent="$(ps -o ppid= -p "$parent" | tr -d ' ')"
      printf '{"result":{"agents":[{"name":"consult-claude-%s","pane_id":"wT:p8"},{"name":"consult-claude-%s","pane_id":"wT:p7"}]}}\n' "$parent" "$grandparent"
    else printf '{"result":{"agents":[]}}\n'; fi ;;
  "agent read") [ "${STUB_READ_FAIL:-0}" = 1 ] && { printf 'read failed\n' >&2; exit 1; }; printf 'ANSWER from child\n' ;;
  "agent get") printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "${STUB_AGENT_STATUS:-idle}" ;;
  "agent prompt")
    [ "${STUB_PARENT_PROMPT_FAIL:-0}" = 1 ] && { printf 'prompt failed\n' >&2; exit 1; }
    printf '%s' "$4" > "$CHILD_STUB/parent-prompt"
    printf '{"result":{"agent":{"agent_status":"working"}}}\n'
    ;;
  "pane get")
    if [ "${STUB_WAITING_LABEL:-0}" = 1 ]; then
      printf '{"result":{"pane":{"state_labels":{"blocked":"waiting for parent"}}}}\n'
    else printf '{"result":{"pane":{}}}\n'; fi ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$CHILD_STUB/herdr-child" "$CHILD_STUB/herdr"
}

@test "ask-in-herdr script requires arguments" {
  run bash "$ASK_HERDR_DIR/ask.sh"
  assert_failure 2
  assert_output --partial "Usage:"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=refused"
}

@test "ask.sh rejects unknown agents and the removed headless flag" {
  run bash "$ASK_HERDR_DIR/ask.sh" bogus question
  assert_failure 2
  assert_output --partial "claude opencode pi"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=refused"

  run bash "$ASK_HERDR_DIR/ask.sh" claude question --model
  assert_failure 2
  assert_output --partial "Usage:"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=refused"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" claude question --headless
  assert_failure 2
  assert_output --partial "unknown flag '--headless'"
  assert_output --partial "ask.sh: status=refused"
  [ ! -f "$CHILD_STUB/child.log" ]
}

@test "ask.sh refuses outside herdr and when herdr-child is absent" {
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV= HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" claude question
  assert_failure 2
  assert_output --partial "status=refused"
  [ ! -f "$CHILD_STUB/child.log" ]

  local no_child; no_child="$(mktemp -d)"
  cp "$CHILD_STUB/herdr" "$no_child/herdr"
  run env PATH="$no_child:/usr/bin:/bin" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" claude question
  assert_failure 2
  assert_output --partial "herdr-child is not on PATH"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=refused"
  rm -rf "$no_child"
}

@test "ask.sh starts a read-only live child and returns its answer" {
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" claude "hi there"
  assert_success
  assert_output --partial "ANSWER from child"
  assert_output --partial "close with: herdr-child reap --pane wT:p9 consult-claude-"
  assert_output --partial "ask.sh: status=answered"
  run grep -E -- '^start --kind claude --name consult-claude-[0-9]+ --posture ro ' "$CHILD_STUB/child.log"
  assert_success
  run grep -E -- '--prompt-file .* --wait --timeout 1800000' "$CHILD_STUB/child.log"
  assert_success
  run grep -E -- '^agent read consult-claude-[0-9]+ --source visible --lines 200' "$CHILD_STUB/herdr.log"
  assert_success
  assert_file_contains "$CHILD_STUB/parent-prompt" '^\[child-settled v1 agent=consult-claude-[0-9][0-9]* pane=wT:p9\]$'
  assert_file_contains "$CHILD_STUB/parent-prompt" 'initial answer has been read'
  assert_file_contains "$CHILD_STUB/parent-prompt" 'read its current output before reaping'
  assert_file_contains "$CHILD_STUB/parent-prompt" 'herdr-child reap --pane wT:p9 consult-claude-[0-9][0-9]*'
  assert_file_contains "$CHILD_STUB/herdr.log" '^agent prompt wT:p0 '
}

@test "ask.sh keeps a settled answer when the parent reminder cannot be queued" {
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENT_STATUS=done STUB_PARENT_PROMPT_FAIL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$ASK_HERDR_DIR/ask.sh" claude question
  assert_success
  assert_output --partial "ANSWER from child"
  assert_output --partial "warning: could not queue the cleanup reminder"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=answered"
  assert_file_not_exists "$CHILD_STUB/parent-prompt"
}

@test "ask.sh forwards posture and every native caller option" {
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" pi question --rw --model M --effort high \
      --cwd "$PWD" --skills A --skills B --agent N
  assert_success
  run grep -E -- '--posture rw' "$CHILD_STUB/child.log"
  assert_success
  run grep -E -- '--model M --effort high --agent N --skills A --skills B' "$CHILD_STUB/child.log"
  assert_success

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" opencode question
  assert_success
  run grep -q -- '--model' "$CHILD_STUB/child.log"
  assert_failure
}

@test "ask.sh retries a colliding derived name with a valid suffix" {
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_NAME_COLLISION=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" claude question
  assert_success
  run grep -E -- '--name consult-claude-[0-9]+-2' "$CHILD_STUB/child.log"
  assert_success
}

@test "ask.sh reports blocked children after printing their answer" {
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENT_STATUS=blocked HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" opencode question
  assert_failure 1
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=blocked"
  assert_file_contains "$CHILD_STUB/herdr.log" '^agent read .*--source recent-unwrapped'
  assert_file_not_exists "$CHILD_STUB/parent-prompt"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_WAITING_LABEL=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" pi question --rw
  assert_failure 1
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=blocked"
  assert_file_not_exists "$CHILD_STUB/parent-prompt"
}

@test "ask.sh reports undelivered when child output cannot be read" {
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_READ_FAIL=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" claude question
  assert_failure 1
  assert_output --partial "read failed"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=undelivered"
}

@test "ask.sh reports a still-working child with exit 124" {
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_CHILD_STATUS=124 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" claude question
  assert_failure 124
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=working"
  assert_file_not_exists "$CHILD_STUB/parent-prompt"
}

@test "ask.sh classifies successful waits with working, unknown, and fallback statuses" {
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENT_STATUS=working HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" claude question
  assert_failure 124
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=working"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENT_STATUS=unknown HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" claude question
  assert_failure 124
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=working"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENT_STATUS=surprised HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" claude question
  assert_failure 1
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=undelivered"
}

@test "ask.sh maps child start failures to refused or undelivered" {
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_CHILD_STATUS=2 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" pi question
  assert_failure 2
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=refused"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_CHILD_STATUS=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" claude question
  assert_failure 1
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=undelivered"
}

# ===========================================
# herdr-child launch and return contract
# ===========================================

HERDR_CHILD="$SOURCE_ROOT/dot_local/bin/executable_herdr-child"

child_stub_herdr() {
  CHILD_STUB="$(mktemp -d)"
  export CHILD_STUB
  cat > "$CHILD_STUB/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%q ' "$@" >> "$CHILD_STUB/calls.log"
printf '\n' >> "$CHILD_STUB/calls.log"
case "${1:-} ${2:-}" in
  "agent list")
    if [ -n "${STUB_AGENTS_JSON_FIRST:-}" ] && [ ! -f "$CHILD_STUB/list-once" ]; then
      : > "$CHILD_STUB/list-once"
      printf '%s\n' "$STUB_AGENTS_JSON_FIRST"
    elif [ -n "${STUB_AGENTS_JSON_SECOND:-}" ]; then
      printf '%s\n' "$STUB_AGENTS_JSON_SECOND"
    elif [ -n "${STUB_AGENTS_JSON:-}" ]; then printf '%s\n' "$STUB_AGENTS_JSON"
    else printf '{"result":{"agents":[]}}\n'
    fi ;;
  "pane split")
    [ "${STUB_SPLIT_FAIL:-0}" = 1 ] && exit 1
    : > "$CHILD_STUB/split-seen"
    printf '{"result":{"pane":{"pane_id":"wT:p9"}}}\n' ;;
  "agent start")
    if [ "${STUB_REQUIRE_SPLIT:-0}" = 1 ] && [ ! -f "$CHILD_STUB/split-seen" ]; then
      printf 'agent start before pane split\n' >&2
      exit 1
    fi
    if [ "${STUB_START_MODE:-ok}" = busy-once ] && [ ! -f "$CHILD_STUB/start-once" ]; then
      : > "$CHILD_STUB/start-once"
      printf '{"error":{"code":"agent_pane_busy","message":"not an available shell"}}\n' >&2
      exit 1
    fi
    if [ "${STUB_START_MODE:-ok}" = busy ]; then
      printf '{"error":{"code":"agent_pane_busy","message":"not an available shell"}}\n' >&2
      exit 1
    fi
    if [ "${STUB_START_MODE:-ok}" = error ]; then
      printf '{"error":{"code":"timeout","message":"startup timed out"}}\n' >&2
      exit 1
    fi
    printf '{"result":{"agent":{"interactive_ready":true}}}\n' ;;
  "agent prompt")
    [ "${STUB_PROMPT_FAIL:-0}" = 1 ] && { printf '{"error":{"code":"agent_prompt_stalled"}}\n' >&2; exit 1; }
    [ "${STUB_PROMPT_TIMEOUT:-0}" = 1 ] && { printf '{"error":{"code":"timeout"}}\n' >&2; exit 1; }
    printf '{"result":{"agent":{"agent_status":"idle"}}}\n' ;;
  "pane report-metadata") [ "${STUB_REPORT_FAIL:-0}" = 1 ] && exit 1; printf '{"result":{"type":"pane_metadata_reported"}}\n' ;;
  "pane get")
    if [ "${STUB_PANE_GET_MALFORMED:-0}" = 1 ]; then
      printf 'not json\n'
    elif [ "${STUB_LABEL:-0}" = 1 ]; then
      printf '{"result":{"pane":{"state_labels":{"blocked":"waiting for parent"}}}}\n'
    else
      printf '{"result":{"pane":{}}}\n'
    fi ;;
  "pane close") exit "${STUB_CLOSE_STATUS:-0}" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$CHILD_STUB/herdr"
}

child_start() {
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" start "$@" --prompt "test task"
}

@test "herdr-child requires a subcommand and herdr environment" {
  run bash "$HERDR_CHILD"
  assert_failure 2
  assert_output --partial "Usage:"

  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV= HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" start --kind claude --name child-a --prompt task
  assert_failure
  [ ! -f "$CHILD_STUB/calls.log" ]
}

@test "herdr-child refuses pi read-only before splitting a pane" {
  child_stub_herdr
  run child_start --kind pi --name child-pi --posture ro
  assert_failure 2
  assert_output --partial "return channel requires bash"
  [ ! -f "$CHILD_STUB/calls.log" ]
}

@test "herdr-child rejects invalid and live names before splitting" {
  child_stub_herdr
  run child_start --kind claude --name Invalid
  assert_failure 2
  [ ! -f "$CHILD_STUB/calls.log" ]

  STUB_AGENTS_JSON='{"result":{"agents":[{"name":"child-a","pane_id":"wT:p8"}]}}' \
    run child_start --kind claude --name child-a
  assert_failure 2
  assert_output --partial "already live"
  run grep -q '^pane split' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child maps claude postures and skill directories" {
  child_stub_herdr
  run child_start --kind claude --name child-ro --skills A --skills B
  assert_success
  assert_output '{"agent":"child-ro","pane":"wT:p9"}'
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--add-dir A --add-dir B.*--disallowed-tools Edit Write NotebookEdit AskUserQuestion'

  : > "$CHILD_STUB/calls.log"
  run child_start --kind claude --name child-rw --posture rw
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--disallowed-tools AskUserQuestion'
  run grep -q 'disallowed-tools Edit' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child maps opencode permissions, model, and configured agent" {
  child_stub_herdr
  run child_start --kind opencode --name child-open --agent reviewer
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'OPENCODE_PERMISSION=.*question.*deny.*edit.*deny'
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--model openai/gpt-5.5 --agent reviewer'

  : > "$CHILD_STUB/calls.log"
  run child_start --kind opencode --name child-open-rw --posture rw
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'OPENCODE_PERMISSION=.*question.*deny'
  run grep -q 'OPENCODE_PERMISSION=.*edit' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child maps pi model, effort, skills, and question exclusion" {
  child_stub_herdr
  run child_start --kind pi --name child-pi --posture rw --skills A --skills B
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--exclude-tools ask_user --model openai-codex/gpt-5.5 --thinking medium --skill A --skill B'

  : > "$CHILD_STUB/calls.log"
  run child_start --kind pi --name child-pi-high --posture rw --model custom/model --effort high
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--model custom/model --thinking high'
}

@test "herdr-child rejects native options that the selected kind cannot map" {
  child_stub_herdr
  run child_start --kind claude --name child-a --effort high
  assert_failure 2
  assert_output --partial "--effort is not supported for claude"
  run child_start --kind pi --name child-b --posture rw --agent reviewer
  assert_failure 2
  assert_output --partial "--agent is not supported for pi"
  run child_start --kind opencode --name child-c --skills A
  assert_failure 2
  assert_output --partial "--skills is not supported for opencode"
  [ ! -f "$CHILD_STUB/calls.log" ]
}

@test "herdr-child splits, starts, and prompts in order with both coordinates" {
  child_stub_herdr
  STUB_REQUIRE_SPLIT=1 run child_start --kind claude --name child-a --wait --timeout 5000
  assert_success
  local call1 call2 call3 call4
  call1="$(sed -n '1p' "$CHILD_STUB/calls.log")"
  call2="$(sed -n '2p' "$CHILD_STUB/calls.log")"
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  call4="$(sed -n '4p' "$CHILD_STUB/calls.log")"
  [[ "$call1" == agent\ list* ]]
  [[ "$call2" == pane\ split*HERDR_CHILD_NAME=child-a*HERDR_CHILD_PARENT_PANE=wT:p0* ]]
  [[ "$call3" == agent\ start* ]]
  [[ "$call4" == agent\ prompt*child-a*wT:p9*wT:p0*--wait*--timeout\ 5000* ]]
}

@test "herdr-child caps startup timeout while preserving a long prompt wait" {
  child_stub_herdr
  run child_start --kind claude --name child-a --wait --timeout 1800000
  assert_success
  local start_call prompt_call
  start_call="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  prompt_call="$(sed -n '4p' "$CHILD_STUB/calls.log")"
  [[ "$start_call" == *--timeout\ 300000* ]]
  [[ "$prompt_call" == *--timeout\ 1800000* ]]
}

@test "herdr-child retries only the pane-readiness start failure" {
  child_stub_herdr
  STUB_START_MODE=busy-once run child_start --kind claude --name child-a
  assert_success
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 2

  child_stub_herdr
  STUB_START_MODE=error run child_start --kind claude --name child-b
  assert_failure
  assert_output --partial "agent start failed"
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 1
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

@test "herdr-child closes its pane after three readiness failures" {
  child_stub_herdr
  STUB_START_MODE=busy run child_start --kind claude --name child-a
  assert_failure
  assert_output --partial "three agent start attempts"
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 3
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

@test "herdr-child distinguishes a stalled initial prompt" {
  child_stub_herdr
  STUB_PROMPT_FAIL=1 run child_start --kind claude --name child-a --wait
  assert_failure
  assert_output --partial "initial prompt stalled"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

@test "herdr-child preserves a working pane when the wait times out" {
  child_stub_herdr
  STUB_PROMPT_TIMEOUT=1 run child_start --kind claude --name child-a --wait
  assert_failure 124
  assert_output --partial '{"agent":"child-a","pane":"wT:p9"}'
  assert_output --partial "wait timed out"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child ask requires every injected child coordinate" {
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_NAME=child-a bash "$HERDR_CHILD" ask question
  assert_failure
  assert_output --partial "HERDR_CHILD_PARENT_PANE is missing"
  [ ! -f "$CHILD_STUB/calls.log" ]
}

@test "herdr-child ask publishes before delivery and uses the versioned marker" {
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"parent","pane_id":"wT:p0"}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 \
    HERDR_PANE_ID=wT:p9 HERDR_CHILD_NAME=child-a HERDR_CHILD_PARENT_PANE=wT:p0 \
    bash "$HERDR_CHILD" ask "Which path?"
  assert_success
  local call1 call2 call3
  call1="$(sed -n '1p' "$CHILD_STUB/calls.log")"
  call2="$(sed -n '2p' "$CHILD_STUB/calls.log")"
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  [[ "$call1" == pane\ report-metadata*wT:p9*--source\ child-agent*--state-label*--ttl-ms\ 3600000* ]]
  [[ "$call2" == agent\ list* ]]
  [[ "$call3" == agent\ prompt*wT:p0*child-ask*agent=child-a*pane=wT:p9* ]]
  [[ "$call3" != *--wait* ]]
}

@test "herdr-child ask leaves the label when parent lookup or delivery fails" {
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_NAME=child-a HERDR_CHILD_PARENT_PANE=wT:p0 \
    bash "$HERDR_CHILD" ask question
  assert_failure
  assert_file_contains "$CHILD_STUB/calls.log" '^pane report-metadata'
  run grep -q 'clear-state-labels' "$CHILD_STUB/calls.log"
  assert_failure

  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"parent","pane_id":"wT:p0"}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PROMPT_FAIL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p9 HERDR_CHILD_NAME=child-a HERDR_CHILD_PARENT_PANE=wT:p0 \
    bash "$HERDR_CHILD" ask question
  assert_failure
  assert_output --partial "waiting label remains published"
}

@test "herdr-child reply validates the live pair, delivers, then clears" {
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"child-a","pane_id":"wT:p9"}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reply --to child-a --pane wT:p9 "Use path A"
  assert_success
  local call2 call3
  call2="$(sed -n '2p' "$CHILD_STUB/calls.log")"
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  [[ "$call2" == agent\ prompt*parent-reply*pane=wT:p0* ]]
  [[ "$call3" == pane\ report-metadata*wT:p9*--clear-state-labels* ]]

  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_REPORT_FAIL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reply --to child-a --pane wT:p9 decision
  assert_failure
  assert_output --partial "reply delivered to child-a in wT:p9"
  assert_output --partial "waiting label could not be cleared"

  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reply --to child-a --pane wT:p8 decision
  assert_failure
  run grep -q '^agent prompt' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child ask and reply publish strictly increasing label sequences" {
  child_stub_herdr
  local parent_agents='{"result":{"agents":[{"name":"parent","pane_id":"wT:p0"}]}}'
  env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$parent_agents" HERDR_ENV=1 \
    HERDR_PANE_ID=wT:p9 HERDR_CHILD_NAME=child-a HERDR_CHILD_PARENT_PANE=wT:p0 \
    bash "$HERDR_CHILD" ask question >/dev/null
  local child_agents='{"result":{"agents":[{"name":"child-a","pane_id":"wT:p9"}]}}'
  env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$child_agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reply --to child-a --pane wT:p9 decision >/dev/null
  local first_seq second_seq
  first_seq="$(grep '^pane report-metadata' "$CHILD_STUB/calls.log" | sed -n '1s/.*--seq \([0-9]*\).*/\1/p')"
  second_seq="$(grep '^pane report-metadata' "$CHILD_STUB/calls.log" | sed -n '2s/.*--seq \([0-9]*\).*/\1/p')"
  [ -n "$first_seq" ]
  [ "$second_seq" -gt "$first_seq" ]
}

@test "herdr-child reply keeps the label when delivery fails and refuses child callers" {
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"child-a","pane_id":"wT:p9"}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PROMPT_FAIL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reply --to child-a --pane wT:p9 decision
  assert_failure
  run grep -q 'clear-state-labels' "$CHILD_STUB/calls.log"
  assert_failure

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_PARENT_PANE=wT:p0 bash "$HERDR_CHILD" reply --to child-a --pane wT:p9 decision
  assert_failure
  assert_output --partial "parent-side"
}

@test "herdr-child reap closes only settled, unfocused, non-waiting panes" {
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"done-a","pane_id":"wT:p1","agent_status":"done","focused":false},{"name":"work-a","pane_id":"wT:p2","agent_status":"working","focused":false},{"name":"focus-a","pane_id":"wT:p3","agent_status":"idle","focused":true}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap done-a missing-a work-a focus-a
  assert_success
  assert_output --partial "done-a: closed pane wT:p1"
  assert_output --partial "missing-a: skipped"
  assert_output --partial "work-a: kept; status is working"
  assert_output --partial "focus-a: kept"
  run grep -c '^agent list' "$CHILD_STUB/calls.log"
  assert_output 2
  run grep -c '^pane close' "$CHILD_STUB/calls.log"
  assert_output 1
}

@test "herdr-child reap closes an unfocused idle pane" {
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"idle-a","pane_id":"wT:p1","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --pane wT:p1 idle-a
  assert_success
  assert_output --partial "idle-a: closed pane wT:p1"
  refute_output --partial "--pane: skipped"
  run grep -c '^pane close wT:p1' "$CHILD_STUB/calls.log"
  assert_output 1
}

@test "herdr-child reap rejects an empty expected pane" {
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"idle-a","pane_id":"wT:p1","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --pane "" idle-a
  assert_failure 2
  assert_output --partial "reap --pane requires a non-empty pane ID"
  assert_file_not_exists "$CHILD_STUB/calls.log"
}

@test "herdr-child reap preserves a reused name outside the expected pane" {
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"reused-a","pane_id":"wT:p2","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --pane wT:p1 reused-a
  assert_success
  assert_output --partial "reused-a: kept; expected pane wT:p1, current pane is wT:p2"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child reap preserves a pane when fresh state no longer matches" {
  child_stub_herdr
  local initial='{"result":{"agents":[{"name":"stale-a","pane_id":"wT:p1","agent_status":"done","focused":false}]}}'
  local fresh='{"result":{"agents":[{"name":"stale-a","pane_id":"wT:p2","agent_status":"done","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON_FIRST="$initial" STUB_AGENTS_JSON_SECOND="$fresh" \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap stale-a
  assert_success
  assert_output --partial "stale-a: kept; child name and pane no longer identify the same live agent"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child reap refuses outside herdr and from a child pane" {
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV= HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap child-a
  assert_failure
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_PARENT_PANE=wT:p0 bash "$HERDR_CHILD" reap child-a
  assert_failure
  assert_output --partial "parent-side"
}

@test "herdr-child reap preserves a settled pane with a waiting label" {
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"wait-a","pane_id":"wT:p1","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_LABEL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap wait-a
  assert_success
  assert_output --partial "has a waiting state label"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child reap preserves a settled pane when pane metadata is malformed" {
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"bad-meta-a","pane_id":"wT:p1","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PANE_GET_MALFORMED=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap bad-meta-a
  assert_success
  assert_output --partial "bad-meta-a: kept; pane metadata could not be read"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

# ===========================================
# herdr-integrations run-script
# ===========================================

HERDR_INTEGRATIONS_TMPL="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_3-setup-herdr-integrations.sh.tmpl"

@test "herdr-integrations script exits 0 and skips when herdr is absent" {
  skip_if_no_chezmoi
  [[ -f "$HERDR_INTEGRATIONS_TMPL" ]] || skip "herdr-integrations script not found"
  BATS_TEST_TMPFILE="$BATS_TEST_TMPDIR/herdr-integrations.sh"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" execute-template < "$HERDR_INTEGRATIONS_TMPL" > "$BATS_TEST_TMPFILE"
  run env PATH="/usr/bin:/bin" bash "$BATS_TEST_TMPFILE"
  assert_success
  assert_output --partial "skipping agent-state integration refresh"
}

# ===========================================
# Claude Code PreToolUse hooks
# ===========================================

HOOKS_DIR="$SOURCE_ROOT/private_dot_claude/hooks"
FFF_GUARD="$HOOKS_DIR/executable_fff-grep-guard.sh"
WEBFETCH_HINT="$HOOKS_DIR/executable_webfetch-markdown-hint.sh"

@test "fff-grep-guard denies a query of several bare words" {
  command -v jq >/dev/null || skip "jq not available"
  run bash "$FFF_GUARD" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"TODO FIXME scheduling launchd cron"}}
EOF
  assert_success
  assert_output --partial '"permissionDecision": "deny"'
  assert_output --partial "mcp__fff__multi_grep"
}

@test "fff-grep-guard stays silent on a single identifier" {
  command -v jq >/dev/null || skip "jq not available"
  run bash "$FFF_GUARD" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"AGENT_PROFILES"}}
EOF
  assert_success
  assert_output ""
}

# Path-scoped and glob-scoped queries were the multi-token calls that actually
# returned hits, so the guard must let them through.
@test "fff-grep-guard stays silent on a path-scoped or glob-scoped query" {
  command -v jq >/dev/null || skip "jq not available"
  run bash "$FFF_GUARD" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"KnowledgeContextField console/"}}
EOF
  assert_success
  assert_output ""
  run bash "$FFF_GUARD" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"useRouter *.tsx"}}
EOF
  assert_success
  assert_output ""
}

@test "fff-grep-guard fails open on malformed input" {
  run bash "$FFF_GUARD" <<<'not json at all'
  assert_success
  assert_output ""
}

@test "webfetch-markdown-hint adds context for a plain URL" {
  command -v jq >/dev/null || skip "jq not available"
  run bash "$WEBFETCH_HINT" <<'EOF'
{"tool_name":"WebFetch","tool_input":{"url":"https://smithers.sh/docs"}}
EOF
  assert_success
  assert_output --partial '"additionalContext"'
  assert_output --partial "/markdown-new"
  refute_output --partial "permissionDecision"
}

@test "webfetch-markdown-hint stays silent when the URL already uses markdown.new" {
  command -v jq >/dev/null || skip "jq not available"
  run bash "$WEBFETCH_HINT" <<'EOF'
{"tool_name":"WebFetch","tool_input":{"url":"https://markdown.new/https://smithers.sh/docs"}}
EOF
  assert_success
  assert_output ""
}

@test "settings template registers both PreToolUse hooks with their matchers" {
  skip_if_no_chezmoi
  local tmpl="$SOURCE_ROOT/private_dot_claude/private_settings.json.tmpl"
  BATS_TEST_TMPFILE="$BATS_TEST_TMPDIR/claude-settings.json"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" execute-template < "$tmpl" > "$BATS_TEST_TMPFILE"
  run python3 - "$BATS_TEST_TMPFILE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
matchers = {e["matcher"]: e for e in s["hooks"]["PreToolUse"]}
assert "mcp__fff__grep" in matchers, matchers.keys()
assert "WebFetch" in matchers, matchers.keys()
assert "fff-grep-guard.sh" in matchers["mcp__fff__grep"]["hooks"][0]["command"]
assert "webfetch-markdown-hint.sh" in matchers["WebFetch"]["hooks"][0]["command"]
PY
  assert_success
}

# ===========================================
# herdr-task-sync engine
# ===========================================

@test "herdr-task-sync descriptor probe lives in a one-test Bats file" {
  local descriptor_probe_file="$BATS_TEST_DIRNAME/herdr_task_sync_descriptor_probe.bats"
  assert_file_exists "$descriptor_probe_file"
  run bats --count "$descriptor_probe_file"
  assert_success
  assert_output "1"
}

@test "herdr-task-sync bounded Bats invocation exits after detached work" {
  # No python3 skip guard: it is a declared requirement (README.md,
  # Requirements), a deliberate exception to the skip convention in
  # docs/issues/2026-08-20-013-se-blocks-test-hard-fails-without-deps.md.
  local bats_bin release_file="$BATS_TEST_TMPDIR/release-herdr"
  local pid_file="$BATS_TEST_TMPDIR/descriptor-worker.pid"
  local blocked_pid_file="$BATS_TEST_TMPDIR/blocked-herdr.pid"
  local descriptor_probe_file="$BATS_TEST_DIRNAME/herdr_task_sync_descriptor_probe.bats"
  bats_bin="$(command -v bats)"
  export HTS_DESCRIPTOR_RELEASE_FILE="$release_file"
  export HTS_DESCRIPTOR_PID_FILE="$pid_file"
  export HTS_DESCRIPTOR_BLOCKED_PID_FILE="$blocked_pid_file"
  # This is the only test whose stub must stay blocked across a whole nested Bats
  # run, so it is the only one that gets the raised ceiling.
  export HTS_BLOCKED_HERDR_POLLS
  run python3 - "$bats_bin" "$descriptor_probe_file" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

# Two bounds, not one, and they measure different things. See the
# HTS_INNER_BATS_* comments in this file's constants block for why the single
# budget this replaced was a latent flake.
#
# PROGRESS covers the nested run up to the probe writing its pid file. That run
# now targets a dedicated one-test file, so the guard covers setup and the probe
# itself rather than Bats parsing every test in tests/scripts.bats.
#
# EXIT covers what happens after that signal: the nested Bats must exit AND its
# output pipes must reach end-of-file. That pair is the property under test.
# Waiting on process exit alone would not detect the regression -- a detached
# worker that inherited the pipes keeps them open after Bats itself is gone, so
# EOF, not exit, is what a leaked descriptor withholds. The pipes are also why
# the nested run must never be given temp files instead: a worker holding a file
# descriptor blocks nothing, and the test would pass unconditionally.
progress_budget = int(os.environ.get("HTS_INNER_BATS_PROGRESS_SECONDS", "60"))
exit_budget = int(os.environ.get("HTS_INNER_BATS_EXIT_SECONDS", "30"))

# Distinct status per failure mode, so the outer test's failure block names which
# bound fired without reading the message. Avoid 126 and 127: the shell reserves
# them for "not executable" and "not found", and bats reports a misleading BW01
# warning when a `run` command exits with either.
EXIT_HANG_GUARD = 124     # never reached its completion signal
EXIT_REGRESSION = 125     # exited, then held its pipes open -- the guarded bug
EXIT_EARLY = 3            # ended before completing its test
EXIT_VACUOUS = 4          # the fixture gave up; nothing was being held
EXIT_WORKER_STUCK = 5     # detached worker outlived its release
EXIT_NESTED_FAILED = 7    # the nested test failed on its own terms

release_file = Path(os.environ["HTS_DESCRIPTOR_RELEASE_FILE"])
pid_file = Path(os.environ["HTS_DESCRIPTOR_PID_FILE"])
blocked_pid_file = Path(os.environ["HTS_DESCRIPTOR_BLOCKED_PID_FILE"])
gave_up_file = Path(str(blocked_pid_file) + ".gave-up")


def fixture_gave_up():
    """The blocked herdr stub hit its ceiling and stopped holding its descriptor.
    Whatever else this run observed, it did not observe the property under test."""
    return gave_up_file.exists()


VACUOUS = (
    "the blocked herdr stub hit HTS_BLOCKED_HERDR_CEILING_SECONDS and gave up, so "
    "nothing held a descriptor while the inner Bats exited -- this run proved nothing"
)

proc = subprocess.Popen(
    [sys.argv[1], sys.argv[2], "--filter", "^herdr-task-sync descriptor child probe$"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)

# Drain both pipes from launch in their own threads. Nothing may leave a pipe
# unread: the nested run blocks on a full pipe buffer otherwise, and on the
# nested-test-failure path Bats echoes the failed test's captured output, which
# is exactly when that output is largest. An unread pipe there would stall the
# pid file forever and report a plain test failure as a progress-phase hang.
captured = {}


def drain(name, stream):
    captured[name] = stream.read()
    stream.close()


readers = [
    threading.Thread(target=drain, args=("stdout", proc.stdout), daemon=True),
    threading.Thread(target=drain, args=("stderr", proc.stderr), daemon=True),
]
for reader in readers:
    reader.start()


def report(message, code):
    """Fail without stranding a blocked worker or an unreaped process."""
    release_file.touch()
    if proc.poll() is None:
        proc.kill()
    proc.wait()
    for reader in readers:
        reader.join(timeout=5)
    sys.stdout.write(captured.get("stdout") or "")
    sys.stderr.write(captured.get("stderr") or "")
    print(message, file=sys.stderr)
    raise SystemExit(code)


def worker_pid():
    """The probe writes this with a shell redirect, so the file exists empty
    before its contents land -- and stays empty if the write failed."""
    try:
        return int(pid_file.read_text().strip())
    except (FileNotFoundError, ValueError):
        return None


# Phase 1: wait for the probe's completion signal, which it writes as its last
# statement. Its arrival proves the nested test body finished -- in the healthy
# case and in the regression case alike, since a leaked descriptor only shows up
# afterwards, at exit.
# Back the poll off rather than holding 10 ms for the whole phase. The signal is
# seconds away -- the nested run still has to start Bats, source the harness, and
# run the probe -- so a fixed 10 ms interval spends wakeups and file reads waiting
# for something that cannot arrive yet, and it spends them competing with the
# other tests this suite runs alongside under --jobs.
#
# The cap is low on purpose, and it is a trade rather than a free win. Noticing
# late inflates the exit-phase measurement below by up to one interval, because
# the pipes may already have closed by the time we look -- and that measurement
# is what HTS_INNER_BATS_EXIT_SECONDS gets recalibrated against. 50 ms keeps the
# distortion smaller than the values being measured while still cutting the
# wakeup count roughly fivefold. Raising it trades measurement sharpness for
# CPU that Bats' own parsing dwarfs anyway.
poll_interval = 0.01
poll_interval_cap = 0.05

progress_deadline = time.monotonic() + progress_budget
pid = None
while pid is None:
    pid = worker_pid()
    if pid is not None:
        break
    if proc.poll() is not None:
        # The nested run ended. Re-read once before calling this an early exit:
        # the regression exits too, and only its pipes stay open, so "exited"
        # and "signal present" are both true there, separated by teardown.
        pid = worker_pid()
        if pid is None:
            # A give-up collapses the fixture too -- the coordinator's pass fails
            # and releases its claim, so the probe records no owner pid. Name that
            # cause rather than reporting it as an unexplained early exit.
            if fixture_gave_up():
                report(VACUOUS, EXIT_VACUOUS)
            report(
                f"inner Bats exited with status {proc.returncode} before its test "
                "completed; it never wrote the descriptor pid file",
                EXIT_EARLY,
            )
        break
    if time.monotonic() > progress_deadline:
        report(
            f"inner Bats did not reach its completion signal within "
            f"{progress_budget} seconds (hang guard)",
            EXIT_HANG_GUARD,
        )
    time.sleep(poll_interval)
    poll_interval = min(poll_interval * 1.5, poll_interval_cap)

# Phase 2: the property. Exit and EOF must both arrive, and quickly -- only
# teardown remains.
#
# Both are one condition, not two. A leaked descriptor does not merely keep the
# pipes open after Bats exits: Bats' own formatter reads that pipeline to EOF, so
# a descendant holding the write end stops the whole nested invocation from
# finishing. Rehearsal confirms it -- with close_inherited_descriptors neutered,
# it is the process wait that times out, not the reader join. Splitting these
# into separate faults would file the real regression under "Bats is stuck, which
# is not the descriptor bug" and send the next reader after the wrong thing. The
# message names whichever symptom was observed; the cause is the same.
exit_started = time.monotonic()
# Enforce the budget from here -- monotonic, immune to clock skew -- but measure
# from when the probe actually wrote its signal. The backoff above means we can
# notice up to one poll interval late, and by then the pipes may already have
# closed; measuring from detection would report our own latency as the exit cost
# and quietly render the recalibration number meaningless.
try:
    completed_at = pid_file.stat().st_mtime
except OSError:
    completed_at = None

symptom = None
try:
    proc.wait(timeout=exit_budget)
except subprocess.TimeoutExpired:
    symptom = "the Bats process never exited"

if symptom is None:
    for reader in readers:
        remaining = exit_budget - (time.monotonic() - exit_started)
        reader.join(timeout=max(remaining, 0))
    if any(reader.is_alive() for reader in readers):
        symptom = "Bats exited but its output pipes never reached EOF"

if symptom is not None:
    report(
        f"{symptom} within {exit_budget} seconds of its test completing -- a "
        "detached descendant is holding an inherited descriptor open",
        EXIT_REGRESSION,
    )
if completed_at is None:
    exit_elapsed = time.monotonic() - exit_started
else:
    exit_elapsed = max(time.time() - completed_at, 0.0)

sys.stdout.write(captured.get("stdout") or "")
sys.stderr.write(captured.get("stderr") or "")
# Printed on every run, passing runs included, so the next recalibration of
# HTS_INNER_BATS_EXIT_SECONDS reads a number out of CI instead of reconstructing
# one from TAP print-order gaps.
print(f"inner Bats exit phase took {exit_elapsed:.3f}s", file=sys.stderr)

# Non-vacuity: the herdr stub must STILL be blocked right now. Everything above
# only proves the nested Bats exited and closed its pipes -- which is unremarkable
# if nothing was holding a descriptor at the time. The stub gives up on its own
# after HTS_BLOCKED_HERDR_CEILING_SECONDS, and if it did, this run proved nothing.
#
# Check the stub's own pid, not the detached worker's. The worker is the stub's
# parent and outlives its give-up, so a live worker does not imply a blocked
# stub -- checking the worker here passes on exactly the vacuous run this guard
# exists to catch.
if fixture_gave_up():
    report(VACUOUS, EXIT_VACUOUS)

# Backstop for a stub that vanished without recording a give-up (killed, crashed).
# The durable marker above is the primary signal; polling liveness is a race this
# would usually lose on its own.
try:
    blocked_pid = int(blocked_pid_file.read_text().strip())
except (FileNotFoundError, ValueError):
    report(
        "the blocked herdr stub never published its pid; this run cannot show "
        "anything was holding a descriptor",
        EXIT_VACUOUS,
    )

try:
    os.kill(blocked_pid, 0)
except ProcessLookupError:
    report(
        f"blocked herdr stub {blocked_pid} was gone before release without recording "
        "a give-up; nothing held a descriptor while the inner Bats exited",
        EXIT_VACUOUS,
    )
except PermissionError:
    # Alive, just not ours to signal. Treated as alive on purpose: raising here
    # would abort with a traceback whose status matches no EXIT_* code, so the
    # failure block could not say which bound fired.
    pass

release_file.touch()
for _ in range(500):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        break
    time.sleep(0.01)
else:
    # Kill it before reporting. This is the one path that names a still-running
    # process, and leaving it behind would strand a detached worker past the end
    # of the test -- the same thing every other failure path here cleans up.
    try:
        os.kill(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    print(f"detached worker {pid} did not exit after release", file=sys.stderr)
    raise SystemExit(EXIT_WORKER_STUCK)

# Last, so a nested failure after the completion signal is still reported -- but
# only once the worker above has been released and reaped.
if proc.returncode != 0:
    # Carry the nested status in the message rather than as our own exit code:
    # forwarding it raw could coincide with one of the codes above and claim a
    # failure mode that did not happen.
    print(f"inner Bats exited with status {proc.returncode}", file=sys.stderr)
    raise SystemExit(EXIT_NESTED_FAILED)
PY
  unset HTS_DESCRIPTOR_RELEASE_FILE HTS_DESCRIPTOR_PID_FILE
  # `run` captures the driver's measurement into $output, which bats discards on
  # a passing test -- so forward it to the console descriptor. The number is only
  # useful if a green CI run carries it: it is what
  # HTS_INNER_BATS_EXIT_SECONDS gets recalibrated against, and reconstructing it
  # from TAP print-order gaps is what made the previous bound guesswork.
  printf '%s\n' "$output" | grep -F 'inner Bats exit phase took' >&3 || true
  assert_success
  assert_output --partial "ok 1 herdr-task-sync descriptor child probe"
}

# Guards the guard. The test above can only prove anything while the herdr stub
# is still blocked -- if the stub gives up first, nothing holds a descriptor and
# a green run means nothing. That was not a hypothetical: the first version of
# the non-vacuity check watched the stub's parent, which outlives the give-up, so
# it passed on exactly the vacuous run it was written to catch.
#
# Pinning the stub to give up immediately must therefore turn the test red. This
# costs one extra nested Bats run, which is the expensive thing in this file
# (docs/issues/2026-08-21-021), and it buys the one property no other test here
# can assert: that the guard above still fails when it should.
@test "herdr-task-sync bounded Bats invocation refuses a vacuous run" {
  local bats_bin release_file="$BATS_TEST_TMPDIR/release-herdr"
  local pid_file="$BATS_TEST_TMPDIR/descriptor-worker.pid"
  local blocked_pid_file="$BATS_TEST_TMPDIR/blocked-herdr.pid"
  bats_bin="$(command -v bats)"
  export HTS_DESCRIPTOR_RELEASE_FILE="$release_file"
  export HTS_DESCRIPTOR_PID_FILE="$pid_file"
  export HTS_DESCRIPTOR_BLOCKED_PID_FILE="$blocked_pid_file"
  # One poll: the stub records its give-up before the driver ever looks.
  export HTS_BLOCKED_HERDR_POLLS=1

  run bats "$BATS_TEST_FILENAME" \
    --filter '^herdr-task-sync bounded Bats invocation exits after detached work$'

  unset HTS_DESCRIPTOR_RELEASE_FILE HTS_DESCRIPTOR_PID_FILE
  unset HTS_DESCRIPTOR_BLOCKED_PID_FILE HTS_BLOCKED_HERDR_POLLS
  assert_failure
  assert_output --partial "this run proved nothing"
}

@test "herdr-task-sync harness fresh reads follow pane and tab mutations" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_set_pane "$HTS_DEFAULT_SOCKET" \
    '{"pane_id":"pane-1","tab_id":"tab-1","terminal_id":"term-1","cwd":"/repo/one","label":"old","tokens":{}}'
  hts_set_tab "$HTS_DEFAULT_SOCKET" \
    '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-tab"}'

  run hts_socket_run "$HTS_DEFAULT_SOCKET" pane rename pane-1 new
  assert_success
  run hts_socket_run "$HTS_DEFAULT_SOCKET" tab rename tab-1 new-tab
  assert_success
  run hts_socket_run "$HTS_DEFAULT_SOCKET" pane get pane-1
  assert_success
  assert_output --partial '"label":"new"'
  run hts_socket_run "$HTS_DEFAULT_SOCKET" tab get tab-1
  assert_success
  assert_output --partial '"label":"new-tab"'
  run hts_socket_run "$HTS_DEFAULT_SOCKET" api snapshot
  assert_success
  assert_output --partial '"tabs":[{"tab_id":"tab-1"'

  hts_snapshot_complete "$HTS_DEFAULT_SOCKET" false
  run hts_socket_run "$HTS_DEFAULT_SOCKET" api snapshot
  assert_success
  refute_output --partial '"tabs"'
}

@test "herdr-task-sync harness controls reverse model completion by generation" {
  hts_setup
  hts_stub_controlled_engine pi
  hts_model_fixture pi 1 older
  hts_model_fixture pi 2 newer

  printf '%s\n' first | "$HTS_STUB/pi" > "$HTS_WORK/model-1.out" &
  local first_pid=$!
  hts_wait_for_file "$HTS_WORK/models/pi/1/started"
  printf '%s\n' second | "$HTS_STUB/pi" > "$HTS_WORK/model-2.out" &
  local second_pid=$!
  hts_wait_for_file "$HTS_WORK/models/pi/2/started"

  hts_release_model pi 2
  hts_wait_for_file "$HTS_WORK/models/pi/2/completed"
  wait "$second_pid"
  assert_file_not_exists "$HTS_WORK/models/pi/1/completed"
  hts_release_model pi 1
  hts_wait_for_file "$HTS_WORK/models/pi/1/completed"
  wait "$first_pid"
  assert_equal "$(cat "$HTS_WORK/model-1.out")" older
  assert_equal "$(cat "$HTS_WORK/model-2.out")" newer
}

@test "herdr-task-sync harness isolates colliding sanitized socket names" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local socket_one="$HTS_WORK/a-b.sock" socket_two="$HTS_WORK/a_b.sock"
  local dir_one dir_two sanitized_one sanitized_two
  sanitized_one="$(printf '%s' "$socket_one" | sed 's/[^[:alnum:]]/_/g')"
  sanitized_two="$(printf '%s' "$socket_two" | sed 's/[^[:alnum:]]/_/g')"
  assert_equal "$sanitized_one" "$sanitized_two"
  dir_one="$(hts_socket_dir "$socket_one")"
  dir_two="$(hts_socket_dir "$socket_two")"
  [[ "$dir_one" != "$dir_two" ]]
  hts_set_pane "$socket_one" '{"pane_id":"pane-1","label":"one","tokens":{}}'
  hts_set_pane "$socket_two" '{"pane_id":"pane-1","label":"two","tokens":{}}'

  run hts_socket_run "$socket_one" api snapshot
  assert_success
  assert_output --partial '"label":"one"'
  run hts_socket_run "$socket_two" api snapshot
  assert_success
  assert_output --partial '"label":"two"'
  hts_wait_for_socket_call "$dir_one" 1
  hts_wait_for_socket_completion "$dir_one" 1
  hts_wait_for_socket_call "$dir_two" 1
  hts_wait_for_socket_completion "$dir_two" 1
  mkdir "$dir_one/locks/held" "$dir_two/locks/held"
  assert_dir_exists "$dir_one/locks/held"
  assert_dir_exists "$dir_two/locks/held"
  assert_dir_exists "$dir_one/locks"
  assert_dir_exists "$dir_two/locks"
  assert_equal "$(wc -l < "$(hts_socket_log "$socket_one")" | tr -d ' ')" 1
  assert_equal "$(wc -l < "$(hts_socket_log "$socket_two")" | tr -d ' ')" 1
}

@test "herdr-task-sync harness applies source metadata sequence and clear rules" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_set_pane "$HTS_DEFAULT_SOCKET" '{"pane_id":"pane-1","label":"agent","tokens":{}}'

  hts_socket_run "$HTS_DEFAULT_SOCKET" pane report-metadata --source location pane-1 --seq 2 --token repo=alpha
  hts_socket_run "$HTS_DEFAULT_SOCKET" pane report-metadata --source task pane-1 --seq 1 --token task=review
  hts_socket_run "$HTS_DEFAULT_SOCKET" pane report-metadata --source location pane-1 --seq 1 --clear-token repo
  local state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.metadata["pane-1"].location.tokens.repo' "$state")" alpha
  assert_equal "$(jq -r '.panes[0].tokens.task' "$state")" review

  hts_socket_run "$HTS_DEFAULT_SOCKET" pane report-metadata --source location pane-1 --seq 3 --clear-token repo
  assert_equal "$(jq -r '.metadata["pane-1"].location.seq' "$state")" 3
  assert_equal "$(jq -r '.metadata["pane-1"].location.tokens.repo // "cleared"' "$state")" cleared
  assert_equal "$(jq -r '.panes[0].tokens.repo // "cleared"' "$state")" cleared
  assert_equal "$(jq -r '.panes[0].tokens.task' "$state")" review
}

@test "herdr-task-sync harness models target loss move reuse and final-read change" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_set_pane "$HTS_DEFAULT_SOCKET" \
    '{"pane_id":"pane-1","tab_id":"tab-1","terminal_id":"term-1","cwd":"/repo/one","label":"one","tokens":{}}'
  hts_remove_pane "$HTS_DEFAULT_SOCKET" pane-1
  run hts_socket_run "$HTS_DEFAULT_SOCKET" pane get pane-1
  assert_failure
  run grep -q '^pane rename' "$HTS_LOG"
  assert_failure

  hts_set_pane "$HTS_DEFAULT_SOCKET" \
    '{"pane_id":"pane-1","tab_id":"tab-2","terminal_id":"term-2","cwd":"/repo/two","label":"two","tokens":{}}'
  run hts_socket_run "$HTS_DEFAULT_SOCKET" pane get pane-1
  assert_success
  assert_output --partial '"tab_id":"tab-2"'
  assert_output --partial '"terminal_id":"term-2"'

  local state next_state
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  next_state="$(jq -c '.panes[0].terminal_id = "term-3" | .panes[0].cwd = "/repo/three" | .panes[0].label = "three"' "$state")"
  hts_after_next_call_state "$HTS_DEFAULT_SOCKET" "$next_state"
  run hts_socket_run "$HTS_DEFAULT_SOCKET" pane get pane-1
  assert_success
  assert_output --partial '"terminal_id":"term-2"'
  hts_socket_run "$HTS_DEFAULT_SOCKET" pane rename pane-1 stale-write
  run hts_socket_run "$HTS_DEFAULT_SOCKET" pane get pane-1
  assert_output --partial '"terminal_id":"term-3"'
  assert_output --partial '"label":"stale-write"'
  hts_socket_run "$HTS_DEFAULT_SOCKET" pane rename pane-1 converged
  run hts_socket_run "$HTS_DEFAULT_SOCKET" pane get pane-1
  assert_output --partial '"label":"converged"'
}

@test "herdr-task-sync latest committed request survives stale completion and a third request" {
  hts_setup
  hts_stub_controlled_engine pi
  hts_model_fixture pi 1 stale-first
  hts_model_fixture pi 2 newest-third

  hts_run --agent claude --session s1 <<< 'first request'
  hts_wait_for_file "$HTS_WORK/models/pi/1/started"
  hts_run --agent claude --session s1 <<< 'second request'
  hts_run --agent claude --session s1 <<< 'third request'

  hts_release_model pi 1
  hts_wait_for_file "$HTS_WORK/models/pi/2/started"
  hts_release_model pi 2

  local control task
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  task="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 s1)"
  hts_wait_for_quiescence "$control"
  hts_wait_for_task_slug "$task" newest-third
  assert_equal "$(hts_record_text "$task" latest_prompt)" "third request"
  assert_equal "$(hts_record_text "$task" first_prompt)" "first request"
  assert_equal "$(hts_record_number "$control" generation)" \
    "$(hts_record_number "$control" committed_generation)"
  local reconcile="$(hts_namespace "$HTS_DEFAULT_SOCKET")/reconcile.state"
  assert_equal "$(hts_record_number "$control" presentation_generation)" \
    "$(hts_record_number "$reconcile" pending_generation)"
  assert_equal "$(hts_record_number "$control" task_metadata_high_water)" \
    "$(hts_record_number "$reconcile" task_metadata_high_water)"
  assert_file_not_exists "$HTS_WORK/models/pi/3/started"
  hts_wait_for_publish
  run grep -c -- '--token task=' "$HTS_LOG"
  assert_output "1"
}

@test "herdr-task-sync active native session fences reused pane and session identifiers" {
  hts_setup
  hts_stub_controlled_engine pi
  hts_model_fixture pi 1 stale-old-session

  hts_run --agent claude --session reused <<< 'old native session prompt'
  hts_wait_for_file "$HTS_WORK/models/pi/1/started"
  hts_run --agent pi --session reused --set 'fresh native session' < /dev/null
  hts_release_model pi 1

  local control fresh stale
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  fresh="$(hts_task_file "$HTS_DEFAULT_SOCKET" pi pane-1 reused)"
  stale="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 reused)"
  hts_wait_for_quiescence "$control"
  hts_wait_for_task_slug "$fresh" fresh-native-session
  assert_file_not_exists "$stale"
  assert_equal "$(hts_record_text "$control" active_agent)" pi
  assert_equal "$(hts_record_text "$control" active_session)" reused
  hts_wait_for_publish
  run grep -c -- '--token task=' "$HTS_LOG"
  assert_output "1"
}

@test "herdr-task-sync prompt transcript and direct set share one committed-generation contract" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_stub_engine pi model-task 0 0
  local transcript="$HTS_WORK/transcript.jsonl"
  printf '%s\n' \
    '{"type":"user","message":{"role":"user","content":"transcript first"}}' \
    '{"type":"user","message":{"role":"user","content":"transcript latest"}}' > "$transcript"

  hts_run --pane pane-prompt --agent claude --session prompt-s <<< 'prompt request'
  hts_wait_for_task_slug \
    "$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-prompt prompt-s)" model-task
  hts_run --pane pane-transcript --agent claude --session transcript-s \
    --transcript "$transcript" < /dev/null
  hts_wait_for_task_slug \
    "$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-transcript transcript-s)" model-task
  hts_run --pane pane-direct --agent pi --session direct-s --set 'Direct Task' < /dev/null
  hts_wait_for_task_slug \
    "$(hts_task_file "$HTS_DEFAULT_SOCKET" pi pane-direct direct-s)" direct-task

  local mode pane control task
  for mode in prompt transcript direct; do
    pane="pane-$mode"
    control="$(hts_control_file "$HTS_DEFAULT_SOCKET" "$pane")"
    hts_wait_for_quiescence "$control"
    assert_equal "$(hts_record_number "$control" generation)" \
      "$(hts_record_number "$control" committed_generation)"
    [[ "$(hts_record_number "$control" presentation_generation)" -gt 0 ]]
  done
  task="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-transcript transcript-s)"
  assert_equal "$(hts_record_text "$task" first_prompt)" "transcript first"
  assert_equal "$(hts_record_text "$task" latest_prompt)" "transcript latest"
}

@test "herdr-task-sync failed latest model retains newest context and prior slug" {
  hts_setup
  hts_run --agent claude --session s1 --set baseline-task < /dev/null
  local control task before failed_generation
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  task="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 s1)"
  hts_wait_for_task_slug "$task" baseline-task
  before="$(hts_record_number "$control" generation)"

  hts_run --agent claude --session s1 <<< 'failed model context'
  hts_wait_for_record_number "$control" generation $((before + 1))
  hts_wait_for_quiescence "$control"
  failed_generation="$(hts_record_number "$control" generation)"
  assert_equal "$(hts_record_text "$task" slug)" baseline-task
  assert_equal "$(hts_record_text "$task" first_prompt)" "failed model context"
  assert_equal "$(hts_record_text "$task" latest_prompt)" "failed model context"

  hts_stub_engine pi recovered-task 0 0
  hts_run --agent claude --session s1 <<< 'request after failure'
  hts_wait_for_record_number "$control" generation $((failed_generation + 1))
  hts_wait_for_task_slug "$task" recovered-task
  run cat "$HTS_WORK/pi-stdin.txt"
  assert_output --partial "Current name: baseline-task"
  assert_output --partial "failed model context"
  assert_output --partial "request after failure"
}

@test "herdr-task-sync atomic records never expose truncation or mixed fields" {
  hts_setup
  local task control reconcile stop="$HTS_WORK/stop-reader" bad="$HTS_WORK/bad-reader" reader i poll
  task="$(hts_task_file "$HTS_DEFAULT_SOCKET" pi pane-1 atomic-s)"
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  reconcile="$(hts_namespace "$HTS_DEFAULT_SOCKET")/reconcile.state"
  (
    while [[ ! -e "$stop" ]]; do
      if [[ -f "$task" ]]; then
        [[ "$(grep -c '^generation=' "$task" 2>/dev/null)" = 1 ]] || : > "$bad"
        [[ "$(grep -c '^slug=' "$task" 2>/dev/null)" = 1 ]] || : > "$bad"
        [[ "$(grep -c '^first_prompt=' "$task" 2>/dev/null)" = 1 ]] || : > "$bad"
        [[ "$(grep -c '^latest_prompt=' "$task" 2>/dev/null)" = 1 ]] || : > "$bad"
        hts_record_text "$task" slug >/dev/null 2>&1 || : > "$bad"
        hts_record_number "$task" generation | grep -Eq '^[0-9]+$' || : > "$bad"
      fi
      if [[ -f "$control" ]]; then
        [[ "$(grep -c '^generation=' "$control" 2>/dev/null)" = 1 ]] || : > "$bad"
        [[ "$(grep -c '^committed_generation=' "$control" 2>/dev/null)" = 1 ]] || : > "$bad"
        [[ "$(grep -c '^active_agent=' "$control" 2>/dev/null)" = 1 ]] || : > "$bad"
        hts_record_text "$control" active_agent >/dev/null 2>&1 || : > "$bad"
      fi
      if [[ -f "$reconcile" ]]; then
        [[ "$(grep -c '^pending_generation=' "$reconcile" 2>/dev/null)" = 1 ]] || : > "$bad"
        [[ "$(grep -c '^task_metadata_high_water=' "$reconcile" 2>/dev/null)" = 1 ]] || : > "$bad"
        [[ "$(grep -c '^repository_anchor=' "$reconcile" 2>/dev/null)" = 1 ]] || : > "$bad"
      fi
      sleep 0.005
    done
  ) &
  reader=$!
  # Teardown owns the reader from here: a failed assertion below would skip the
  # stop/wait pair, and the orphaned loop then races teardown's rm -rf of
  # HTS_WORK forever (its stop file can no longer be created), spraying
  # misleading ENOENT noise over the real failure.
  HTS_READER_PID=$reader
  for i in $(seq 1 40); do
    hts_run --agent pi --session atomic-s --set "atomic-$i" < /dev/null
  done
  # The engine's inbox is fail-open by design: an enqueue or a worker commit
  # that loses its bounded control.lock window (INBOX_LOCK_ATTEMPTS) drops the
  # request silently rather than stall the callback. The 40-set burst above is
  # exactly the load that provokes those drops, so delivery of the final set is
  # not guaranteed in one shot — under CI --jobs contention the sentinel
  # vanished and this wait ran to its ceiling. Re-enqueue the sentinel until it
  # commits; every re-enqueue spawns a fresh worker, which also drains a
  # pending generation whose own worker aborted. The atomicity assertions the
  # reader collects stay as strict as before.
  for i in $(seq 1 10); do
    for poll in $(seq 1 200); do
      [[ "$(hts_record_text "$task" slug 2>/dev/null || true)" = atomic-40 ]] && break 2
      sleep 0.01
    done
    hts_run --agent pi --session atomic-s --set atomic-40 < /dev/null
  done
  hts_wait_for_task_slug "$task" atomic-40
  : > "$stop"
  wait "$reader"
  unset HTS_READER_PID
  assert_file_not_exists "$bad"
}

@test "herdr-task-sync one-way legacy import is atomic idempotent and ignores late legacy writes" {
  hts_setup
  local legacy task marker task_two marker_two malformed task_three marker_three
  legacy="$(hts_legacy_state_file claude-pane-1-s1)"
  task="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 s1)"
  marker="$(hts_migration_marker "$HTS_DEFAULT_SOCKET" claude pane-1 s1)"
  hts_write_legacy_state "$legacy" legacy-task 'legacy first' 'legacy latest'

  HERDR_TASK_SYNC_TEST_NO_WORKER=1 hts_run --agent claude --session s1 <<< 'new request'
  assert_equal "$(hts_record_text "$task" slug)" legacy-task
  assert_file_exists "$marker"
  hts_write_legacy_state "$legacy" late-old-worker changed changed
  HERDR_TASK_SYNC_TEST_NO_WORKER=1 hts_run --agent claude --session s1 <<< 'later request'
  assert_equal "$(hts_record_text "$task" slug)" legacy-task

  task_two="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 s2)"
  marker_two="$(hts_migration_marker "$HTS_DEFAULT_SOCKET" claude pane-1 s2)"
  mkdir -p "$(dirname "$task_two")"
  hts_write_legacy_state "$task_two" canonical-before-marker 'canonical first' 'canonical latest'
  hts_write_legacy_state "$(hts_legacy_state_file claude-pane-1-s2)" should-not-replace old old
  HERDR_TASK_SYNC_TEST_NO_WORKER=1 hts_run --agent claude --session s2 <<< 'resume after crash'
  assert_equal "$(hts_record_text "$task_two" slug)" canonical-before-marker
  assert_file_exists "$marker_two"

  malformed="$(hts_legacy_state_file claude-pane-1-s3)"
  task_three="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 s3)"
  marker_three="$(hts_migration_marker "$HTS_DEFAULT_SOCKET" claude pane-1 s3)"
  printf 'slug=%%%s\n' broken > "$malformed"
  HERDR_TASK_SYNC_TEST_NO_WORKER=1 hts_run --agent claude --session s3 <<< 'malformed import'
  assert_file_exists "$marker_three"
  assert_file_not_exists "$task_three"
  hts_write_legacy_state "$malformed" too-late late late
  HERDR_TASK_SYNC_TEST_NO_WORKER=1 hts_run --agent claude --session s3 <<< 'second start'
  assert_file_not_exists "$task_three"
}

@test "herdr-task-sync restart recovers accepted and interrupted worker generations" {
  hts_setup
  hts_stub_controlled_engine pi
  hts_model_fixture pi 1 abandoned-result
  hts_model_fixture pi 2 recovered-result
  local control task first_worker first_owner second_worker worker_claim
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  task="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 restart-s)"

  HERDR_TASK_SYNC_TEST_NO_WORKER=1 hts_run --agent claude --session restart-s <<< 'restart request'
  [[ "$(hts_record_number "$control" generation)" -gt \
    "$(hts_record_number "$control" committed_generation)" ]]
  hts_worker_run &
  first_worker=$!
  hts_wait_for_file "$HTS_WORK/models/pi/1/started"
  worker_claim="$(hts_pane_state_dir "$HTS_DEFAULT_SOCKET" pane-1)/worker.claim/owner"
  first_owner="$(hts_record_number "$worker_claim" pid)"
  kill "$first_owner" 2>/dev/null || true
  wait "$first_worker" 2>/dev/null || true

  hts_worker_run &
  second_worker=$!
  hts_wait_for_file "$HTS_WORK/models/pi/2/started"
  hts_release_model pi 2
  wait "$second_worker"
  hts_wait_for_task_slug "$task" recovered-result
  hts_wait_for_quiescence "$control"
  hts_release_model pi 1
  assert_equal "$(hts_record_text "$task" slug)" recovered-result
}

@test "herdr-task-sync clock rollback and restart cannot lower generation or task high-water" {
  hts_setup
  local control task first_generation first_high_water first_task_metadata first_presentation
  local second_generation second_high_water second_task_metadata second_presentation
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  task="$(hts_task_file "$HTS_DEFAULT_SOCKET" pi pane-1 clock-s)"

  HERDR_TASK_SYNC_TEST_NOW_SEQ=9000 HERDR_TASK_SYNC_TEST_NO_WORKER=1 \
    hts_run --agent pi --session clock-s --set first-clock < /dev/null
  first_generation="$(hts_record_number "$control" generation)"
  HERDR_TASK_SYNC_TEST_NOW_SEQ=9000 HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 hts_worker_run
  assert_equal "$(hts_record_number "$control" committed_generation)" "$first_generation"
  assert_equal "$(hts_record_number "$task" generation)" "$first_generation"
  first_high_water="$(hts_record_number "$control" task_metadata_high_water)"
  first_task_metadata="$(hts_record_number "$task" metadata_seq)"
  first_presentation="$(hts_record_number "$control" presentation_generation)"

  HERDR_TASK_SYNC_TEST_NOW_SEQ=100 HERDR_TASK_SYNC_TEST_NO_WORKER=1 \
    hts_run --agent pi --session clock-s --set second-clock < /dev/null
  second_generation="$(hts_record_number "$control" generation)"
  [[ "$second_generation" -gt "$first_generation" ]]
  HERDR_TASK_SYNC_TEST_NOW_SEQ=100 HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 hts_worker_run
  assert_equal "$(hts_record_number "$control" committed_generation)" "$second_generation"
  assert_equal "$(hts_record_number "$task" generation)" "$second_generation"

  second_high_water="$(hts_record_number "$control" task_metadata_high_water)"
  second_task_metadata="$(hts_record_number "$task" metadata_seq)"
  second_presentation="$(hts_record_number "$control" presentation_generation)"
  [[ "$second_high_water" -gt "$first_high_water" ]] || \
    fail "task metadata high-water did not advance: first=$first_high_water second=$second_high_water generation=$second_generation"
  [[ "$second_task_metadata" -gt "$first_task_metadata" ]] || \
    fail "task metadata sequence did not advance: first=$first_task_metadata second=$second_task_metadata generation=$second_generation"
  [[ "$second_presentation" -gt "$first_presentation" ]] || \
    fail "presentation generation did not advance: first=$first_presentation second=$second_presentation generation=$second_generation"
  [[ "$second_high_water" -ge "$second_generation" ]]
}

@test "herdr-task-sync exact socket namespaces survive legacy sanitized-name collisions" {
  hts_setup
  local socket_one="$HTS_WORK/a-b.sock" socket_two="$HTS_WORK/a_b.sock"
  local task_one task_two namespace_one namespace_two
  namespace_one="$(hts_namespace "$socket_one")"
  namespace_two="$(hts_namespace "$socket_two")"
  [[ "$namespace_one" != "$namespace_two" ]]

  # This test owns task namespace isolation only. A successful task commit normally
  # starts a detached presentation pass, and that pass legitimately advances the
  # location high-water before this task-only assertion can read it under load.
  HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 \
    hts_run_for_socket "$socket_one" --agent pi --session same --set socket-one < /dev/null
  HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 \
    hts_run_for_socket "$socket_two" --agent pi --session same --set socket-two < /dev/null
  task_one="$(hts_task_file "$socket_one" pi pane-1 same)"
  task_two="$(hts_task_file "$socket_two" pi pane-1 same)"
  hts_wait_for_task_slug "$task_one" socket-one
  hts_wait_for_task_slug "$task_two" socket-two
  hts_wait_for_quiescence "$(hts_control_file "$socket_one" pane-1)"
  hts_wait_for_quiescence "$(hts_control_file "$socket_two" pane-1)"
  assert_equal "$(hts_record_text "$task_one" slug)" socket-one
  assert_equal "$(hts_record_text "$task_two" slug)" socket-two
  assert_equal "$(hts_record_text "$namespace_one/socket.state" socket_path)" "$socket_one"
  assert_equal "$(hts_record_text "$namespace_two/socket.state" socket_path)" "$socket_two"
  [[ "$(hts_record_number "$namespace_one/reconcile.state" task_metadata_high_water)" -gt 0 ]]
  assert_equal "$(hts_record_number "$namespace_one/reconcile.state" location_metadata_high_water)" 0
  [[ "$(hts_record_number "$namespace_two/reconcile.state" task_metadata_high_water)" -gt 0 ]]
  assert_equal "$(hts_record_number "$namespace_two/reconcile.state" location_metadata_high_water)" 0
  grep -q '^checkout_root=' "$namespace_one/reconcile.state"
  grep -q '^repository_anchor=' "$namespace_one/reconcile.state"
}

@test "herdr-task-sync fail-open guard ignores terminal input and preserves redirected input" {
  hts_setup
  local helper="$BATS_TEST_DIRNAME/helpers/herdr_task_sync.bash"

  run python3 - "$helper" <<'PY'
import os
import pty
import signal
import subprocess
import sys

master, slave = pty.openpty()
proc = subprocess.Popen(
    [
        "bash",
        "-c",
        'source "$1"; hts_run_fail_open_guard true',
        "bash",
        sys.argv[1],
    ],
    stdin=slave,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    start_new_session=True,
)
os.close(slave)
try:
    output, _ = proc.communicate(timeout=10)
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGKILL)
    output, _ = proc.communicate()
    sys.stdout.write(output)
    print("fail-open guard read from its interactive terminal for 10 seconds", file=sys.stderr)
    raise SystemExit(124)
finally:
    os.close(master)

sys.stdout.write(output)
raise SystemExit(proc.returncode)
PY

  assert_success

  run hts_run_fail_open_guard cat <<< 'redirected payload'

  assert_success
  assert_output 'redirected payload'
}

@test "herdr-task-sync fail-open deadline rejects late success before the hang guard" {
  hts_setup
  local HTS_FAIL_OPEN_BEHAVIOR_SECONDS=1
  local HTS_FAIL_OPEN_BASELINE_MULTIPLIER=1
  local HTS_FAIL_OPEN_MAX_SECONDS=5

  run hts_run_fail_open_guard sleep 2

  assert_failure 124
  assert_output --partial "exceeded fail-open behavioral deadline"
}

@test "herdr-task-sync fail-open guard uses the greater baseline" {
  run hts_fail_open_behavior_baseline_ms 200 8 1000
  assert_success
  assert_output 1600

  run hts_fail_open_behavior_baseline_ms 100 8 1000
  assert_success
  assert_output 1000
}

@test "herdr-task-sync fails open for missing tools contention write failure and malformed input" {
  hts_setup
  local pane_dir namespace control task_file
  local baseline_start baseline_end baseline_status
  run hts_run_fail_open_guard env PATH="/usr/bin:/bin" HERDR_ENV=1 HERDR_PANE_ID=pane-1 \
    HERDR_SOCKET_PATH="$HTS_DEFAULT_SOCKET" HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    bash "$HTS_ENGINE" --agent claude --session missing <<< 'missing herdr'
  assert_success

  hts_setup
  pane_dir="$(hts_pane_state_dir "$HTS_DEFAULT_SOCKET" pane-1)"
  mkdir -p "$pane_dir/control.lock"
  HERDR_TASK_SYNC_LOCK_ATTEMPTS=1
  run hts_run --agent claude --session locked <<< 'contention'
  unset HERDR_TASK_SYNC_LOCK_ATTEMPTS
  assert_success
  assert_file_not_exists "$pane_dir/control.state"
  assert_file_not_exists "$HTS_WORK/pi-stdin.txt"

  hts_setup
  printf 'not-a-directory\n' > "$HTS_STATE/sockets"
  run hts_run --agent claude --session write-failure <<< 'state write failure'
  assert_success

  hts_setup
  HERDR_TASK_SYNC_TEST_NO_WORKER=1 hts_run \
    --agent pi --session worker-write-failure --set pending-task < /dev/null
  namespace="$(hts_namespace "$HTS_DEFAULT_SOCKET")"
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  rmdir "$namespace/tasks"
  printf 'not-a-directory\n' > "$namespace/tasks"
  run hts_run_fail_open_guard hts_worker_run
  assert_success
  [[ "$(hts_record_number "$control" generation)" -gt \
    "$(hts_record_number "$control" committed_generation)" ]]

  hts_setup
  HERDR_TASK_SYNC_TEST_NO_WORKER=1 hts_run \
    --agent pi --session commit-write-control --set pending-task < /dev/null
  HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1
  baseline_start="$(hts_millis)"
  baseline_status=0
  hts_worker_run || baseline_status=$?
  baseline_end="$(hts_millis)"
  assert_equal "$baseline_status" 0
  local HTS_FAIL_OPEN_REFERENCE_MILLIS=$((baseline_end - baseline_start))

  HERDR_TASK_SYNC_TEST_NO_WORKER=1 hts_run \
    --agent pi --session commit-write-failure --set pending-task < /dev/null
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  task_file="$(hts_task_file "$HTS_DEFAULT_SOCKET" pi pane-1 commit-write-failure)"
  mkdir "$task_file"
  run hts_run_fail_open_guard hts_worker_run
  assert_success
  [[ "$(hts_record_number "$control" generation)" -gt \
    "$(hts_record_number "$control" committed_generation)" ]]
  assert_dir_not_exists "$(hts_pane_state_dir "$HTS_DEFAULT_SOCKET" pane-1)/worker.claim"

  hts_setup
  run hts_run --agent '' --session malformed <<< 'bad agent'
  assert_success
  run hts_run --agent claude --session '' --transcript "$HTS_WORK/missing.jsonl" < /dev/null
  assert_success
  hts_run --agent pi --session malformed-set --set '!!!' < /dev/null
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  hts_wait_for_quiescence "$control"
  assert_equal "$(hts_record_number \
    "$(hts_namespace "$HTS_DEFAULT_SOCKET")/reconcile.state" pending_generation)" 0
  assert_file_not_exists "$HTS_WORK/pi-stdin.txt"
}

@test "herdr-task-sync orders adapter calls by inbox commit rather than invocation start" {
  hts_setup
  local fifo="$HTS_WORK/delayed-input" release="$HTS_WORK/delayed-input-release"
  local first_pid writer_pid task control first_generation
  task="$(hts_task_file "$HTS_DEFAULT_SOCKET" pi pane-1 commit-order)"
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  mkfifo "$fifo"
  # Opening a fifo for reading blocks until a writer opens the other end, so the
  # first invocation's engine does not start until this writer runs. Gate that on
  # the second invocation having actually committed rather than on a fixed sleep:
  # under full-suite load the second invocation can outlast any timer, which
  # silently inverts the very ordering this test asserts.
  { while [ ! -e "$release" ]; do sleep 0.01; done; printf 'delayed stdin' > "$fifo"; } &
  writer_pid=$!
  hts_run --agent pi --session commit-order --set invoked-first-committed-second < "$fifo" &
  first_pid=$!

  hts_run --agent pi --session commit-order --set invoked-second-committed-first < /dev/null
  hts_wait_for_task_slug "$task" invoked-second-committed-first
  hts_wait_for_quiescence "$control"
  first_generation="$(hts_record_number "$control" committed_generation)"
  : > "$release"
  wait "$writer_pid"
  wait "$first_pid"
  hts_wait_for_task_slug "$task" invoked-first-committed-second
  hts_wait_for_quiescence "$control"
  [[ "$(hts_record_number "$control" committed_generation)" -gt "$first_generation" ]]
}

@test "herdr-task-sync adapters return when a direct engine hangs" {
  command -v bun >/dev/null || skip "bun not available"
  local pi_adapter="$SOURCE_ROOT/dot_pi/agent/extensions/herdr-task-sync.ts"
  local opencode_adapter="$SOURCE_ROOT/private_dot_config/opencode/plugins/herdr-task-sync.ts"
  local home="$BATS_TEST_TMPDIR/adapter-timeout-home"
  local driver="$home/adapter-timeout-driver.ts"
  mkdir -p "$home/.local/bin"
  cat > "$home/.local/bin/herdr-task-sync" <<'SH'
#!/bin/sh
agent=
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--agent" ] && [ "$#" -gt 1 ]; then
    agent="$2"
    break
  fi
  shift
done
[ -n "$agent" ] || exit 2
started="$HOME/$agent.started"
terminated="$HOME/$agent.terminated"
trap 'touch "$terminated"; exit 0' TERM
touch "$started"
cat >/dev/null
while :; do sleep 0.05; done
SH
  chmod +x "$home/.local/bin/herdr-task-sync"

  cat > "$driver" <<'TS'
const piHandlers = {}
const piExtension = (await import(`file://${process.env.PI_ADAPTER_PATH}`)).default
piExtension({
  getSessionName: () => undefined,
  on: (event, handler) => { piHandlers[event] = handler },
})
const context = {
  hasUI: true,
  sessionManager: { getSessionId: () => "pi-root" },
}
await piHandlers.session_start({}, context)
await piHandlers.before_agent_start({ prompt: "hung pi engine" }, context)

const { HerdrTaskSyncPlugin } = await import(`file://${process.env.OPENCODE_ADAPTER_PATH}`)
const hooks = await HerdrTaskSyncPlugin()
await hooks["chat.message"](
  { sessionID: "opencode-root" },
  { parts: [{ type: "text", text: "hung opencode engine" }] },
)
TS

  run python3 - "$home" "$driver" "$pi_adapter" "$opencode_adapter" <<'PY'
import os
import signal
import subprocess
import sys

home, driver, pi_adapter, opencode_adapter = sys.argv[1:]
env = os.environ.copy()
env.update(
    HOME=home,
    HERDR_ENV="1",
    PI_ADAPTER_PATH=pi_adapter,
    OPENCODE_ADAPTER_PATH=opencode_adapter,
)
proc = subprocess.Popen(
    ["bun", driver],
    env=env,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    start_new_session=True,
)
try:
    output, _ = proc.communicate(timeout=30)
except subprocess.TimeoutExpired:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    output, _ = proc.communicate()
    sys.stdout.write(output)
    print("adapter timeout fixture exceeded its 30-second hang guard", file=sys.stderr)
    raise SystemExit(124)

sys.stdout.write(output)
raise SystemExit(proc.returncode)
PY
  assert_success
  assert_file_exists "$home/pi.started"
  assert_file_exists "$home/pi.terminated"
  assert_file_exists "$home/opencode.started"
  assert_file_exists "$home/opencode.terminated"
}

@test "herdr-task-sync opencode forgets a deleted child session" {
  command -v bun >/dev/null || skip "bun not available"
  local adapter="$SOURCE_ROOT/private_dot_config/opencode/plugins/herdr-task-sync.ts"
  local home log
  hts_setup
  home="$HTS_WORK/adapter-home"
  log="$HTS_WORK/adapter.log"
  mkdir -p "$home/.local/bin"
  cat > "$home/.local/bin/herdr-task-sync" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HTS_ADAPTER_LOG"
cat >/dev/null
SH
  chmod +x "$home/.local/bin/herdr-task-sync"

  run env HOME="$home" HERDR_ENV=1 HTS_ADAPTER_LOG="$log" ADAPTER_PATH="$adapter" bun -e '
    const { HerdrTaskSyncPlugin } = await import(`file://${process.env.ADAPTER_PATH}`)
    const hooks = await HerdrTaskSyncPlugin()
    await hooks.event({ event: { type: "session.created", properties: { info: { id: "child-1", parentID: "root-1" } } } })
    await hooks["chat.message"]({ sessionID: "child-1" }, { parts: [{ type: "text", text: "ignored child prompt" }] })
    await hooks.event({ event: { type: "session.deleted", properties: { info: { id: "child-1" } } } })
    await hooks["chat.message"]({ sessionID: "child-1" }, { parts: [{ type: "text", text: "new root prompt" }] })
  '
  assert_success
  hts_wait_for_file_match "$log" "--agent opencode --session child-1"
  run cat "$log"
  assert_output "--agent opencode --session child-1"
}

@test "herdr-task-sync presentation coordinates concurrent panes in one shared tab" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_set_pane "$HTS_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":"claude","agent_session":{"agent":"claude","kind":"id","value":"s1"},"label":"","tokens":{}}'
  hts_set_pane "$HTS_DEFAULT_SOCKET" '{"pane_id":"pane-2","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-2","agent":"pi","agent_session":{"agent":"pi","kind":"id","value":"s2"},"label":"","tokens":{}}'
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'

  hts_run --pane pane-1 --agent claude --session s1 --set first-task < /dev/null
  hts_run --pane pane-2 --agent pi --session s2 --set second-task < /dev/null
  hts_wait_for_task_slug "$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 s1)" first-task
  hts_wait_for_task_slug "$(hts_task_file "$HTS_DEFAULT_SOCKET" pi pane-2 s2)" second-task
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"

  local state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .label' "$state")" cc:first-task
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-2") | .label' "$state")" pi:second-task
  assert_equal "$(jq -r '.tabs[] | select(.tab_id == "tab-1") | .label' "$state")" "cc:first-task · pi:second-task"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.task' "$state")" first-task
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-2") | .tokens.task' "$state")" second-task
}

@test "herdr-task-sync presentation accepts pi jsonl path sessions that end with the active session id" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local state tmp task
  hts_run --agent pi --session 01abc --set session-path-task < /dev/null
  task="$(hts_task_file "$HTS_DEFAULT_SOCKET" pi pane-1 01abc)"
  hts_wait_for_task_slug "$task" session-path-task
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"

  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  tmp="$state.tmp"
  jq '.panes[0].agent_session.value = "/tmp/2026-08-20T00-00-00_01abc.jsonl" | .panes[0].label = ""' \
    "$state" > "$tmp" && mv "$tmp" "$state"
  hts_location_pass

  assert_equal "$(jq -r '.panes[0].label' "$state")" pi:session-path-task
}

@test "herdr-task-sync presentation labels a detected agent without task state" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_set_pane "$HTS_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":"claude","agent_session":{"agent":"claude","kind":"id","value":"untracked"},"label":"~","tokens":{}}'
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"~"}'

  hts_event_run
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"

  local state
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].label' "$state")" cc
  assert_equal "$(jq -r '.tabs[0].label' "$state")" cc
}

@test "herdr-task-sync presentation publishes only the newest accepted generation" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_stub_controlled_engine pi
  hts_model_fixture pi 1 stale-first
  hts_model_fixture pi 2 newest-second

  hts_run --agent claude --session latest-s <<< 'first request'
  hts_wait_for_file "$HTS_WORK/models/pi/1/started"
  hts_run --agent claude --session latest-s <<< 'second request'
  hts_release_model pi 1
  hts_wait_for_file "$HTS_WORK/models/pi/2/started"
  hts_release_model pi 2

  local control task state
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  task="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 latest-s)"
  hts_wait_for_quiescence "$control"
  hts_wait_for_task_slug "$task" newest-second
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.task' "$state")" newest-second
  assert_equal "$(jq -r '.panes[0].label' "$state")" cc:newest-second
  assert_equal "$(jq -r '.tabs[0].label' "$state")" cc:newest-second
  run grep -c '^pane report-metadata' "$HTS_LOG"
  assert_output "1"
}

@test "herdr-task-sync presentation coalesces event bursts into an active pass and rerun" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_set_pane "$HTS_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old","tokens":{}}'
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old"}'
  hts_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  : > "$HTS_WORK/block-herdr"
  hts_event_run
  hts_wait_for_file "$HTS_WORK/herdr-blocked"
  hts_event_run
  hts_event_run
  hts_event_run
  : > "$HTS_WORK/release-herdr"
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"

  run grep -c '^api snapshot' "$HTS_LOG"
  assert_output "2"
  run grep -c '^pane rename pane-1 btop$' "$HTS_LOG"
  assert_output "1"
  run grep -c '^tab rename tab-1 btop$' "$HTS_LOG"
  assert_output "1"
}

@test "herdr-task-sync presentation retries a newer invalidation after transient pass failure" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_set_pane "$HTS_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old","tokens":{}}'
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old"}'
  hts_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  local dir="$(hts_socket_dir "$HTS_DEFAULT_SOCKET")"
  : > "$dir/fail-next-snapshot"
  : > "$HTS_WORK/block-herdr"
  hts_event_run
  hts_wait_for_file "$HTS_WORK/herdr-blocked"
  HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 hts_event_run
  : > "$HTS_WORK/release-herdr"
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  run grep -c '^api snapshot' "$HTS_LOG"
  assert_output "2"
  assert_equal "$(jq -r '.panes[0].label' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" btop
}

@test "herdr-task-sync presentation release recheck does not lose a pending invalidation" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_set_pane "$HTS_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old","tokens":{}}'
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old"}'
  hts_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  local pause="$HTS_WORK/release-edge"
  HERDR_TASK_SYNC_TEST_PAUSE_BEFORE_RELEASE="$pause" hts_event_run
  hts_wait_for_file "$pause.reached"
  # The second event only has to make an invalidation pending; letting it also
  # start a presentation of its own races the paused pass under load, which
  # adds a third snapshot and reads as a lost invalidation when it is not.
  # Suppressing it keeps the recheck the only route to the second snapshot, so
  # the exact count below still means what the test name says.
  HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 hts_event_run
  : > "$pause.release"
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  run grep -c '^api snapshot' "$HTS_LOG"
  assert_output "2"
}

@test "herdr-task-sync event presentation leaves the hook process group" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_set_pane "$HTS_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old","tokens":{}}'
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old"}'
  hts_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  local pause="$HTS_WORK/process-group" claim worker_pid worker_pgid hook_pgid

  HERDR_TASK_SYNC_TEST_PAUSE_BEFORE_RELEASE="$pause" hts_event_run
  hts_wait_for_file "$pause.reached"
  claim="$(hts_namespace "$HTS_DEFAULT_SOCKET")/presentation.claim/owner"
  worker_pid="$(hts_record_number "$claim" pid)"
  worker_pgid="$(ps -p "$worker_pid" -o pgid= | tr -d '[:space:]')"
  hook_pgid="$(ps -p "$$" -o pgid= | tr -d '[:space:]')"
  : > "$pause.release"
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"

  [ -n "$worker_pgid" ]
  [ "$worker_pgid" != "$hook_pgid" ]
}

@test "herdr-task-sync presentation automatically corrects divergent pane and tab labels" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_run --agent claude --session correction-s --set automatic-task < /dev/null
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  hts_socket_run "$HTS_DEFAULT_SOCKET" pane rename pane-1 divergent-pane
  : > "$HTS_LOG"
  hts_event_run
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  run grep '^pane rename' "$HTS_LOG"
  assert_output "pane rename pane-1 cc:automatic-task"
  run grep -c '^tab rename' "$HTS_LOG"
  assert_failure

  hts_socket_run "$HTS_DEFAULT_SOCKET" pane rename pane-1 divergent-again
  hts_socket_run "$HTS_DEFAULT_SOCKET" tab rename tab-1 divergent-tab
  : > "$HTS_LOG"
  hts_event_run
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  assert_file_contains "$HTS_LOG" '^pane rename pane-1 cc:automatic-task$'
  assert_file_contains "$HTS_LOG" '^tab rename tab-1 cc:automatic-task$'
  run grep -E 'owner|reclaim|notification' "$HTS_LOG"
  assert_failure
}

@test "herdr-task-sync presentation drops a malformed-width record and keeps labeling the rest" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # A FIELD_SEPARATOR smuggled into a pane field would shift every later
  # positional field and surface as a wrong label. The width guard must drop
  # only that pane's record; the other pane and the tab still get labeled.
  hts_set_pane "$HTS_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"bad\u001flabel","tokens":{}}'
  hts_set_pane "$HTS_DEFAULT_SOCKET" '{"pane_id":"pane-2","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old","tokens":{}}'
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-tab"}'
  hts_proc_info pane-2 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  hts_event_run
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  local state
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-2") | .label' "$state")" btop
  run grep '^pane rename pane-1' "$HTS_LOG"
  assert_failure
  assert_file_contains "$HTS_LOG" '^tab rename tab-1 btop$'
}

@test "herdr-task-sync presentation skips pre-read deletion and repairs the post-read race next pass" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_set_pane "$HTS_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old","tokens":{}}'
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old"}'
  hts_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  local state missing next dir
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  missing="$(jq -c '.panes = []' "$state")"
  hts_after_next_call_state "$HTS_DEFAULT_SOCKET" "$missing"
  hts_event_run
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  run grep -c '^pane rename' "$HTS_LOG"
  assert_failure

  hts_set_pane "$HTS_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-2","agent":null,"label":"wrong","tokens":{}}'
  : > "$HTS_LOG"
  dir="$(hts_socket_dir "$HTS_DEFAULT_SOCKET")"
  next=$(( $(cat "$dir/call-seq") + 3 ))
  hts_after_call_script "$HTS_DEFAULT_SOCKET" "$next" "printf '%s' '{\"result\":{\"process_info\":{\"shell_pid\":100,\"foreground_process_group_id\":300,\"foreground_processes\":[{\"pid\":300,\"name\":\"cargo\",\"argv0\":\"cargo\",\"argv\":[\"cargo\",\"test\"]}]}}}' > '$dir/proc-pane-1.json'"
  hts_event_run
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  assert_equal "$(jq -r '.panes[0].label' "$state")" btop
  hts_event_run
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  assert_equal "$(jq -r '.panes[0].label' "$state")" "cargo test"
}

@test "herdr-task-sync presentation skips reused pane and tab identities at the final read" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_set_pane "$HTS_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old-pane","tokens":{}}'
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-tab"}'
  hts_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  local state next_state
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  next_state="$(jq -c '
    .panes[0].terminal_id = "term-2"
    | .panes[0].label = "reused-pane"
    | .tabs[0].workspace_id = "ws-2"
    | .tabs[0].label = "reused-tab"
  ' "$state")"
  hts_after_next_call_state "$HTS_DEFAULT_SOCKET" "$next_state"

  hts_event_run
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  assert_equal "$(jq -r '.panes[0].label' "$state")" reused-pane
  assert_equal "$(jq -r '.tabs[0].label' "$state")" reused-tab
  run grep -E '^(pane|tab) rename' "$HTS_LOG"
  assert_failure

  hts_event_run
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  assert_equal "$(jq -r '.panes[0].label' "$state")" btop
  assert_equal "$(jq -r '.tabs[0].label' "$state")" btop
}

@test "herdr-task-sync age cleanup removes only inactive task payloads" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local old_task old_marker active_task active_control active_high_water
  HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 hts_run \
    --agent claude --session expired-session --set expired-task < /dev/null
  old_task="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 expired-session)"
  old_marker="$(hts_migration_marker "$HTS_DEFAULT_SOCKET" claude pane-1 expired-session)"
  hts_wait_for_task_slug "$old_task" expired-task

  HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 hts_run \
    --agent claude --session active-session --set active-task < /dev/null
  active_task="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 active-session)"
  active_control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  active_high_water="$(hts_pane_state_dir "$HTS_DEFAULT_SOCKET" pane-1)/high-water.state"
  hts_wait_for_task_slug "$active_task" active-task
  hts_wait_for_quiescence "$active_control"
  touch -t 200001010000 "$old_task" "$active_task"

  HERDR_TASK_SYNC_STATE_MAX_AGE_DAYS=0 hts_location_pass

  assert_file_not_exists "$old_task"
  assert_file_exists "$old_marker"
  assert_file_exists "$active_task"
  assert_file_exists "$active_control"
  assert_file_exists "$active_high_water"
}

@test "herdr-task-sync presentation preserves state on incomplete and transient snapshots" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 hts_run --agent pi --session retained-s --set retained-task < /dev/null
  local task="$(hts_task_file "$HTS_DEFAULT_SOCKET" pi pane-1 retained-s)"
  hts_wait_for_task_slug "$task" retained-task
  hts_wait_for_record_number "$(hts_namespace "$HTS_DEFAULT_SOCKET")/reconcile.state" pending_generation 1
  touch -t 202001010000 "$task"
  hts_snapshot_complete "$HTS_DEFAULT_SOCKET" false
  run hts_presentation_run
  assert_success
  assert_file_exists "$task"
  assert_equal "$(cat "$HTS_LOG")" "api snapshot"

  hts_snapshot_complete "$HTS_DEFAULT_SOCKET" true
  printf 'not-json\n' > "$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  : > "$HTS_LOG"
  run hts_presentation_run
  assert_success
  assert_file_exists "$task"
  run grep -E 'rename|report-metadata' "$HTS_LOG"
  assert_failure
}

@test "herdr-task-sync naming worker never age-cleans tasks without safe snapshot ownership" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 hts_run \
    --pane pane-old --agent pi --session old-s --set old-task < /dev/null
  local old_task active_task socket_dir
  old_task="$(hts_task_file "$HTS_DEFAULT_SOCKET" pi pane-old old-s)"
  active_task="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 active-s)"
  socket_dir="$(hts_socket_dir "$HTS_DEFAULT_SOCKET")"
  hts_wait_for_task_slug "$old_task" old-task
  touch -t 202001010000 "$old_task"

  hts_snapshot_complete "$HTS_DEFAULT_SOCKET" false
  HERDR_TASK_SYNC_TEST_NO_WORKER=1 HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 hts_run \
    --agent claude --session active-s --set active-one < /dev/null
  HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 run hts_worker_run
  assert_success
  hts_wait_for_task_slug "$active_task" active-one
  assert_file_exists "$old_task"
  assert_file_exists "$active_task"

  hts_snapshot_complete "$HTS_DEFAULT_SOCKET" true
  : > "$socket_dir/fail-next-snapshot"
  HERDR_TASK_SYNC_TEST_NO_WORKER=1 HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 hts_run \
    --agent claude --session active-s --set active-two < /dev/null
  HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 run hts_worker_run
  assert_success
  hts_wait_for_task_slug "$active_task" active-two
  run hts_presentation_run
  assert_success
  assert_file_exists "$old_task"
  assert_file_exists "$active_task"

  run hts_presentation_run
  assert_success
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  assert_file_exists "$old_task"
  assert_file_exists "$active_task"
  assert_equal "$(hts_record_text "$active_task" slug)" active-two
}

@test "herdr-task-sync presentation isolates exact colliding socket identities" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local socket_one="$HTS_WORK/a-b.sock" socket_two="$HTS_WORK/a_b.sock"
  hts_set_pane "$socket_one" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1a","agent":null,"label":"old-one","tokens":{}}'
  hts_set_tab "$socket_one" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-one"}'
  hts_set_pane "$socket_two" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1b","agent":null,"label":"old-two","tokens":{}}'
  hts_set_tab "$socket_two" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-two"}'
  hts_proc_info_for_socket "$socket_one" pane-1 '{"result":{"process_info":{"shell_pid":1,"foreground_process_group_id":2,"foreground_processes":[{"pid":2,"argv":["one"]}]}}}'
  hts_proc_info_for_socket "$socket_two" pane-1 '{"result":{"process_info":{"shell_pid":1,"foreground_process_group_id":2,"foreground_processes":[{"pid":2,"argv":["two"]}]}}}'
  hts_event_run_for_socket "$socket_one"
  hts_event_run_for_socket "$socket_two"
  hts_wait_for_presentation_quiescence "$socket_one"
  hts_wait_for_presentation_quiescence "$socket_two"
  assert_equal "$(jq -r '.panes[0].label' "$(hts_socket_state "$socket_one")")" one
  assert_equal "$(jq -r '.panes[0].label' "$(hts_socket_state "$socket_two")")" two
  [[ "$(hts_namespace "$socket_one")" != "$(hts_namespace "$socket_two")" ]]
}

@test "herdr-task-sync presentation recovers stale and half-created owner claims" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_run --agent pi --session recovery-s --set recovery-task < /dev/null
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  local namespace claim owner start
  namespace="$(hts_namespace "$HTS_DEFAULT_SOCKET")"
  claim="$namespace/presentation.claim"
  hts_socket_run "$HTS_DEFAULT_SOCKET" pane rename pane-1 wrong
  HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 hts_event_run
  mkdir "$claim"
  owner="stale-owner"
  cat > "$claim/owner" <<EOF
owner_id=$(printf '%s' "$owner" | base64 | tr -d '\n')
pid=$$
process_start=$(printf '%s' 'not-this-process' | base64 | tr -d '\n')
socket_path=$(printf '%s' "$HTS_DEFAULT_SOCKET" | base64 | tr -d '\n')
EOF
  run hts_presentation_run
  assert_success
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  assert_dir_not_exists "$claim"

  hts_socket_run "$HTS_DEFAULT_SOCKET" pane rename pane-1 wrong-again
  HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 hts_event_run
  mkdir "$claim"
  run hts_presentation_run
  assert_success
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  assert_dir_not_exists "$claim"

  hts_socket_run "$HTS_DEFAULT_SOCKET" pane rename pane-1 release-race
  local pause="$HTS_WORK/owner-release" predecessor_pid successor_start
  HERDR_TASK_SYNC_TEST_PAUSE_BEFORE_RELEASE="$pause" hts_event_run
  hts_wait_for_file "$pause.reached"
  predecessor_pid="$(hts_record_number "$claim/owner" pid)"
  successor_start="$(ps -p $$ -o lstart= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  cat > "$claim/owner" <<EOF
owner_id=$(printf '%s' successor-owner | base64 | tr -d '\n')
pid=$$
process_start=$(printf '%s' "$successor_start" | base64 | tr -d '\n')
socket_path=$(printf '%s' "$HTS_DEFAULT_SOCKET" | base64 | tr -d '\n')
EOF
  : > "$pause.release"
  for _ in $(seq 1 $HTS_WAIT_POLLS); do
    kill -0 "$predecessor_pid" 2>/dev/null || break
    sleep 0.01
  done
  run kill -0 "$predecessor_pid"
  assert_failure
  assert_dir_exists "$claim"
  assert_equal "$(hts_record_text "$claim/owner" owner_id)" successor-owner
  rm -f "$claim/owner"
  rmdir "$claim"

  mkdir "$claim"
  start="$(ps -p $$ -o lstart= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  cat > "$claim/owner" <<EOF
owner_id=$(printf '%s' live-owner | base64 | tr -d '\n')
pid=$$
process_start=$(printf '%s' "$start" | base64 | tr -d '\n')
socket_path=$(printf '%s' "$HTS_DEFAULT_SOCKET" | base64 | tr -d '\n')
EOF
  HERDR_TASK_SYNC_LOCK_ATTEMPTS=1 run hts_presentation_run
  assert_success
  assert_dir_exists "$claim"
  assert_equal "$(hts_record_text "$claim/owner" owner_id)" live-owner
}

@test "herdr-task-sync presentation resumes safely across durable crash boundaries" {
  command -v jq >/dev/null || skip "jq not available"
  local boundary
  for boundary in metadata pane-rename pending-complete; do
    hts_setup
    HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 hts_run --agent claude --session "crash-$boundary" --set "task-$boundary" < /dev/null
    local task="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 "crash-$boundary")"
    hts_wait_for_task_slug "$task" "task-$boundary"
    hts_wait_for_record_number "$(hts_namespace "$HTS_DEFAULT_SOCKET")/reconcile.state" pending_generation 1
    HERDR_TASK_SYNC_TEST_CRASH_AFTER="$boundary" run hts_presentation_run
    assert_failure 97
    run hts_presentation_run
    assert_success
    hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
    assert_equal "$(jq -r '.panes[0].tokens.task' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" "task-$boundary"
    assert_equal "$(jq -r '.panes[0].label' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" "cc:task-$boundary"
  done
}

@test "herdr-task-sync presentation self-events converge to a no-op" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_run --agent claude --session self-event-s --set self-event-task < /dev/null
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  : > "$HTS_LOG"
  hts_event_run
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  run grep -E 'rename|report-metadata' "$HTS_LOG"
  assert_failure
  run grep -c '^api snapshot' "$HTS_LOG"
  assert_output "1"
}

@test "herdr-task-sync presentation fails closed without an exact socket" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_set_pane "$HTS_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"unchanged","tokens":{}}'
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"unchanged"}'
  hts_proc_info pane-1 '{"result":{"process_info":{"shell_pid":1,"foreground_process_group_id":2,"foreground_processes":[{"pid":2,"argv":["changed"]}]}}}'
  run env -u HERDR_SOCKET_PATH PATH="$HTS_STUB:/usr/bin:/bin" HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" bash "$HTS_ENGINE" --event
  assert_success
  run env -u HERDR_SOCKET_PATH PATH="$HTS_STUB:/usr/bin:/bin" HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" bash "$HTS_ENGINE" --sweep
  assert_success
  assert_equal "$(cat "$HTS_LOG")" ""
  assert_equal "$(jq -r '.panes[0].label' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" unchanged
}

@test "herdr-task-sync presentation restart recomputes durable pending intent without a label ledger" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 hts_run --agent pi --session restart-presentation --set restart-task < /dev/null
  local reconcile="$(hts_namespace "$HTS_DEFAULT_SOCKET")/reconcile.state"
  hts_wait_for_record_number "$reconcile" pending_generation 1
  [[ "$(hts_record_number "$reconcile" pending_generation)" -gt "$(hts_record_number "$reconcile" completed_generation 2>/dev/null || printf 0)" ]]
  run hts_presentation_run
  assert_success
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  assert_equal "$(jq -r '.panes[0].label' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" pi:restart-task
  run grep -ER 'intended_label|applied_label|manual_owner|reclaim|server_epoch|prepare_rollback' "$(hts_namespace "$HTS_DEFAULT_SOCKET")"
  assert_failure
}

@test "herdr-task-sync location resolves main linked nested and administrative paths with strict foreground semantics" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local main="$HTS_WORK/checkouts/repository" linked="$HTS_WORK/linked/feature"
  local common="$main/.git" nongit="$HTS_WORK/outside" state
  mkdir -p "$main/src/nested" "$common/objects" "$common/worktrees/feature/logs" "$linked/deep/path" "$nongit"
  hts_mark_linked_worktree "$linked" "$common/worktrees/feature"
  printf '%s/.git\n' "$linked" > "$common/worktrees/feature/gitdir"
  hts_git_location_fixture "$main/src/nested" "$main" "$common" refs/heads/main
  hts_git_location_fixture "$main" "$main" "$common" refs/heads/main
  hts_git_location_fixture "$linked" "$linked" "$common" refs/heads/feature
  hts_git_location_fixture "$linked/deep/path" "$linked" "$common" refs/heads/feature
  hts_git_fixture "$nongit" "" 1 ready 'fatal: not a git repository'

  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json main-nested tab-1 "$main" present "$main/src/nested")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json main-admin tab-1 "$main" present "$common/objects")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json linked-admin tab-1 "$linked" present "$common/worktrees/feature/logs")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json fallback tab-1 "$linked/deep/path" absent)"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json foreground-wins tab-1 "$linked/deep/path" present "$nongit")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json agent-ignores-foreground tab-1 "$linked/deep/path" present "$nongit" | jq -c '.agent = "pi"')"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repository"}'
  for pane_id in main-nested main-admin linked-admin fallback foreground-wins agent-ignores-foreground; do hts_set_process_label "$pane_id" "$pane_id"; done
  LANG=fr_FR.UTF-8 LC_ALL= hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"

  assert_equal "$(jq -r '.panes[] | select(.pane_id == "main-nested" or .pane_id == "main-admin") | .tokens.repo' "$state" | sort -u)" repository
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "main-nested" or .pane_id == "main-admin") | .tokens.worktree' "$state" | sort -u)" repository
  # Main checkout: branch icon; folder qualifier suppressed because the
  # worktree token equals the workspace name.
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "main-nested" or .pane_id == "main-admin") | .tokens.git_ref' "$state" | sort -u)" "$HTS_ICON_BRANCH main"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "linked-admin" or .pane_id == "fallback") | .tokens.branch' "$state" | sort -u)" feature
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "linked-admin" or .pane_id == "fallback") | .tokens.worktree' "$state" | sort -u)" feature
  # Linked worktree (.git file at root): worktree icon; folder qualifier
  # suppressed because the worktree token equals the branch.
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "linked-admin" or .pane_id == "fallback") | .tokens.git_ref' "$state" | sort -u)" "$HTS_ICON_WORKTREE feature"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "agent-ignores-foreground") | .tokens.branch' "$state")" feature
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "agent-ignores-foreground") | .tokens.worktree' "$state")" feature
  run jq -e '.panes[] | select(.pane_id == "foreground-wins") | (.tokens.repo == null and .tokens.worktree == null and .tokens.branch == null and .tokens.git_ref == null)' "$state"
  assert_success
  assert_equal "$(cat "$(hts_git_fixture_dir "$nongit")/locale")" C
}

@test "herdr-task-sync dangling administrative gitdir retains stale location" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local main="$HTS_WORK/checkouts/repository" linked="$HTS_WORK/linked/feature"
  local common="$main/.git" admin="$common/worktrees/feature/logs" state
  mkdir -p "$common/worktrees/feature/logs" "$linked"
  hts_mark_linked_worktree "$linked" "$common/worktrees/feature"
  printf '%s/.git\n' "$linked" > "$common/worktrees/feature/gitdir"
  hts_git_location_fixture "$linked" "$linked" "$common" refs/heads/feature
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$linked" present "$linked")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_process_label pane-1 worker
  hts_location_pass

  printf '%s\n' "$HTS_WORK/missing/.git" > "$common/worktrees/feature/gitdir"
  hts_set_pane_location "$HTS_DEFAULT_SOCKET" pane-1 "$linked" "$admin"
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.worktree' "$state")" feature
  assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" feature
  assert_equal "$(jq -r '.panes[0].tokens.location_status' "$state")" stale
  # Retained stale evidence keeps the worktree place icon and renders stale
  # as a suffix icon on $git_ref, not as a separate row or text marker.
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_WORKTREE feature $HTS_ICON_STALE"
}

@test "herdr-task-sync location detached publishes a commit ref and non-Git clears are source-local with monotonic restart high-water" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/repo" common="$HTS_WORK/repo.git"
  local branch="$root/branch" detached="$root/detached" nongit="$HTS_WORK/non-git" state first_seq second_seq
  mkdir -p "$branch" "$detached" "$nongit" "$common" "$root/.git"
  hts_git_location_fixture "$branch" "$root" "$common" refs/heads/topic
  hts_git_location_fixture "$detached" "$root" "$common" HEAD a1b2c3d
  hts_git_fixture "$nongit" "" 1 ready 'fatal: not a git repository'
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$branch")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hts_set_process_label pane-1 worker
  hts_socket_run "$HTS_DEFAULT_SOCKET" pane report-metadata pane-1 --source task-sync --token task=kept-task --seq 900

  HERDR_TASK_SYNC_TEST_NOW_SEQ=1000 hts_location_pass
  first_seq="$(hts_location_source_seq "$HTS_DEFAULT_SOCKET" pane-1)"
  hts_set_pane_location "$HTS_DEFAULT_SOCKET" pane-1 "$detached" "$detached"
  HERDR_TASK_SYNC_TEST_NOW_SEQ=1 hts_location_pass
  second_seq="$(hts_location_source_seq "$HTS_DEFAULT_SOCKET" pane-1)"
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  [[ "$second_seq" -gt "$first_seq" ]]
  assert_equal "$(jq -r '.panes[0].tokens.repo' "$state")" repo.git
  assert_equal "$(jq -r '.panes[0].tokens.worktree' "$state")" repo
  # Detached HEAD keeps the location: commit icon plus 7-char short SHA, no
  # stale marker, and no branch token.
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_COMMIT a1b2c3d"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" worker
  run jq -e '.panes[0].tokens.branch == null and .panes[0].tokens.location_status == null and .panes[0].tokens.task == "kept-task"' "$state"
  assert_success

  hts_set_pane_location "$HTS_DEFAULT_SOCKET" pane-1 "$nongit" "$nongit"
  HERDR_TASK_SYNC_TEST_NOW_SEQ=0 hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  # pane_inline is deferred by the plan and never published; the non-Git arm
  # clears any stale copy, so only the task token survives.
  assert_equal "$(jq -c '.panes[0].tokens' "$state")" '{"task":"kept-task"}'
  [[ "$(hts_location_source_seq "$HTS_DEFAULT_SOCKET" pane-1)" -gt "$second_seq" ]]
}

@test "herdr-task-sync location real probe shape pays the second sha call only when detached" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/repo" common="$HTS_WORK/repo.git"
  local branch="$root/branch" detached="$root/detached" state branch_fixture detached_fixture
  mkdir -p "$branch" "$detached" "$common" "$root/.git"
  # given: real-git probe shape — three lines from the first call, the short
  # SHA only from a separate `rev-parse --short=7 HEAD` answered via the
  # stub's stdout.short selector.
  hts_git_fixture "$branch" "$(printf '%s\n%s\n%s' "$root" "$common" refs/heads/topic)"
  hts_git_fixture "$detached" "$(printf '%s\n%s\n%s' "$root" "$common" HEAD)"
  branch_fixture="$(hts_git_fixture_dir "$branch")"
  detached_fixture="$(hts_git_fixture_dir "$detached")"
  printf 'e4f5a6b\n' > "$branch_fixture/stdout.short"
  printf 'e4f5a6b\n' > "$detached_fixture/stdout.short"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$branch")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hts_set_process_label pane-1 worker

  # when: a branch pane resolves
  HERDR_TASK_SYNC_TEST_NOW_SEQ=1000 hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  # then: the ref came from the 3-line probe alone — no --short call fired
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_BRANCH topic"
  run grep -c -- '--short=7' "$branch_fixture/calls"
  assert_failure

  # when: the same pane moves to a detached checkout
  hts_set_pane_location "$HTS_DEFAULT_SOCKET" pane-1 "$detached" "$detached"
  HERDR_TASK_SYNC_TEST_NOW_SEQ=1001 hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  # then: exactly one second budgeted call fetched the SHA
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_COMMIT e4f5a6b"
  assert_equal "$(grep -c -- '--short=7' "$detached_fixture/calls")" 1
}

@test "herdr-task-sync location detached sha failure retains prior identity as stale and never publishes a malformed git_ref" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/repo" common="$HTS_WORK/repo.git"
  local branch="$root/branch" empty_sha="$root/empty-sha" bad_sha="$root/bad-sha" state target fixture
  mkdir -p "$branch" "$empty_sha" "$bad_sha" "$common" "$root/.git"
  # given: real-git probe shape — the detached probes answer 3 lines, and the
  # second `rev-parse --short=7` call yields an empty or non-hex SHA.
  hts_git_fixture "$branch" "$(printf '%s\n%s\n%s' "$root" "$common" refs/heads/topic)"
  hts_git_fixture "$empty_sha" "$(printf '%s\n%s\n%s' "$root" "$common" HEAD)"
  hts_git_fixture "$bad_sha" "$(printf '%s\n%s\n%s' "$root" "$common" HEAD)"
  : > "$(hts_git_fixture_dir "$empty_sha")/stdout.short"
  printf 'not-a-sha\n' > "$(hts_git_fixture_dir "$bad_sha")/stdout.short"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$branch")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hts_set_process_label pane-1 worker
  # given: prior canonical identity from a healthy branch resolve
  hts_location_pass
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" "$HTS_ICON_BRANCH topic"

  for target in "$empty_sha" "$bad_sha"; do
    # when: the pane moves to a detached checkout whose SHA fetch fails
    hts_set_pane_location "$HTS_DEFAULT_SOCKET" pane-1 "$target" "$target"
    hts_location_pass
    state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
    # then: the second call fired, and the pane retains the prior branch
    # identity as stale — no commit ref built from a malformed SHA.
    fixture="$(hts_git_fixture_dir "$target")"
    assert_equal "$(grep -c -- '--short=7' "$fixture/calls")" 1
    assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_BRANCH topic $HTS_ICON_STALE"
    assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" topic
    assert_equal "$(jq -r '.panes[0].tokens.location_status' "$state")" stale
  done
}

@test "herdr-task-sync location detached sha budget failure with no prior state renders no git location and self-heals" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/repo" common="$HTS_WORK/repo.git"
  local detached="$root/detached" fixture state
  mkdir -p "$detached" "$common" "$root/.git"
  # given: real-git probe shape — the first call answers 3 lines in budget,
  # and block.short stalls the second --short=7 call past LOCATION_GIT_BUDGET.
  hts_git_fixture "$detached" "$(printf '%s\n%s\n%s' "$root" "$common" HEAD)"
  fixture="$(hts_git_fixture_dir "$detached")"
  printf 'e4f5a6b\n' > "$fixture/stdout.short"
  : > "$fixture/block.short"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$detached")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hts_set_process_label pane-1 worker
  # when: the very first pass for this pane — no prior location state exists
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  # then: the SHA probe fired, its budget failure discarded the freshly
  # resolved root, and with nothing prior to retain the pane renders with no
  # git location this pass — no half-built commit ref, no stale marker.
  assert_equal "$(grep -c -- '--short=7' "$fixture/calls")" 1
  run jq -e '.panes[0].tokens | (.repo == null and .worktree == null and .branch == null and .location_status == null and .git_ref == null)' "$state"
  assert_success
  assert_equal "$(jq -r '.tabs[0].label' "$state")" worker
  # when: the next sweep finds a responsive SHA probe
  : > "$fixture/release"
  hts_location_pass
  # then: the pane self-heals to the commit ref without manual repair
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" "$HTS_ICON_COMMIT e4f5a6b"
}

@test "herdr-task-sync location clears the retired location_label token on both publish and non-git clear paths" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/repo" common="$HTS_WORK/repo.git" nongit="$HTS_WORK/non-git" state
  mkdir -p "$root" "$common" "$nongit"
  hts_git_location_fixture "$root" "$root" "$common" refs/heads/topic
  hts_git_fixture "$nongit" "" 1 ready 'fatal: not a git repository'
  # given: panes still carrying the legacy location_label token published by
  # the previously deployed version
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root" | jq -c '.tokens.location_label = "legacy label"')"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-2 tab-1 "$nongit" | jq -c '.tokens = {location_label:"legacy label", git_ref:"stale ref"}')"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hts_set_process_label pane-1 worker
  hts_set_process_label pane-2 shell
  # when: one location/presentation pass runs
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  # then: the Git publish path sheds the legacy token while publishing git_ref
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.git_ref' "$state")" "$HTS_ICON_BRANCH topic"
  run jq -e '.panes[] | select(.pane_id == "pane-1") | .tokens.location_label == null' "$state"
  assert_success
  # then: the non-Git clear path sheds it alongside the other location tokens
  run jq -e '.panes[] | select(.pane_id == "pane-2") | (.tokens.location_label == null and .tokens.git_ref == null)' "$state"
  assert_success
}

@test "herdr-task-sync location transient modes retain identity as stale without foreground fallback" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/repo" common="$HTS_WORK/repo.git"
  local fallback="$root/fallback" fresh="$root/fresh" permission="$HTS_WORK/permission" unavailable="$HTS_WORK/unavailable"
  local malformed="$HTS_WORK/malformed" blocked="$HTS_WORK/blocked" missing="$HTS_WORK/missing" state
  mkdir -p "$fresh" "$fallback" "$permission" "$unavailable" "$malformed" "$blocked" "$common"
  hts_git_location_fixture "$fresh" "$root" "$common" refs/heads/main
  hts_git_location_fixture "$fallback" "$root" "$common" refs/heads/main
  hts_git_fixture "$permission" "denied" 126
  hts_git_fixture "$unavailable" "missing" 127
  hts_git_fixture "$malformed" "only-one-line" 0
  hts_git_fixture "$blocked" "never" 0 block
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$fallback" present "$fresh")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-2 tab-1 "$fallback" present "$fresh")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_process_label pane-1 primary
  hts_set_process_label pane-2 repaired
  hts_location_pass

  local transient
  for transient in "$missing" "$permission" "$unavailable" "$malformed"; do
    hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$fallback" present "$transient")"
    hts_location_pass
    state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
    assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.worktree' "$state")" repo
    assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.location_status' "$state")" stale
  done

  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$fallback" present "")"
  hts_location_pass
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.location_status' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" stale

  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$fallback" present "$blocked")"
  hts_socket_run "$HTS_DEFAULT_SOCKET" pane rename pane-2 externally-wrong
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.location_status' "$state")" stale
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-2") | .label' "$state")" repaired

  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$fallback" present "$fresh")"
  hts_location_pass
  run jq -e '.panes[] | select(.pane_id == "pane-1") | .tokens.location_status == null' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_success
}

@test "herdr-task-sync coordinator resolves eight pane locations concurrently within one event envelope" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local i root common cwd fixture blocked_fixture state pane stale_label
  local reconcile pending completed coordinator_pid deadline_pid deadline="$HTS_WORK/coordinator-deadline"
  for i in $(seq 1 8); do
    root="$HTS_WORK/repos/repo-$i"
    common="$HTS_WORK/repos/repo-$i.git"
    cwd="$root/work"
    mkdir -p "$cwd" "$common" "$root/.git"
    if [ "$i" -eq 1 ]; then
      hts_git_location_fixture "$cwd" "$root" "$common" refs/heads/initial-1
    else
      hts_git_fixture "$cwd" "" 1 ready 'fatal: not a git repository'
    fi
    pane="$(hts_process_pane_json "pane-$i" tab-1 "$cwd")"
    pane="$(jq -c --arg label "stable-$i" '.agent = "claude" | .label = $label' <<< "$pane")"
    hts_set_pane "$HTS_DEFAULT_SOCKET" "$pane"
  done
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_location_pass

  rm -f "$HTS_WORK/git-started"/*
  for i in $(seq 1 8); do
    root="$HTS_WORK/repos/repo-$i"
    common="$HTS_WORK/repos/repo-$i.git"
    cwd="$root/work"
    fixture="$(hts_git_fixture_dir "$cwd")"
    rm -f "$fixture/started" "$fixture/completed"
    if [ "$i" -eq 1 ]; then
      : > "$fixture/block"
      blocked_fixture="$fixture"
    fi
  done

  stale_label="$HTS_ICON_BRANCH initial-1 $HTS_ICON_STALE stable-1"
  for i in $(seq 2 8); do stale_label="$stale_label · stable-$i"; done
  hts_set_tab "$HTS_DEFAULT_SOCKET" "$(jq -cn --arg label "$stale_label" \
    '{tab_id:"tab-1",workspace_id:"ws-1",label:$label}')"
  HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 hts_event_run
  reconcile="$(hts_namespace "$HTS_DEFAULT_SOCKET")/reconcile.state"
  pending="$(hts_record_number "$reconcile" pending_generation)"
  export HERDR_TASK_SYNC_TEST_LOCATION_BARRIER="$HTS_WORK/location-probes-started"
  export HERDR_TASK_SYNC_TEST_LOCATION_BARRIER_COUNT=8
  export HERDR_TASK_SYNC_TEST_LOCATION_BARRIER_RELEASE="$HTS_WORK/location-probes-release"
  export HERDR_TASK_SYNC_GIT_BUDGET=$HTS_GIT_BUDGET
  hts_presentation_run &
  coordinator_pid=$!
  # The barrier is what proves concurrency: every probe publishes its marker and then
  # spins until all eight exist, so serial probes deadlock on the first one and this
  # wait fails the test before the release below ever happens. The deadline is only a
  # hang guard for that release path, never a performance budget -- a wall-clock bound
  # here measured the serial presentation tail after the probes (~78% of the window),
  # so it went red on slower CI runners without any regression behind it.
  for i in $(seq 1 8); do
    hts_wait_for_file "$HERDR_TASK_SYNC_TEST_LOCATION_BARRIER/$(hts_key "pane-$i")"
  done
  (sleep 30; : > "$deadline") &
  deadline_pid=$!
  : > "$HERDR_TASK_SYNC_TEST_LOCATION_BARRIER_RELEASE"
  while :; do
    completed="$(hts_record_number "$reconcile" completed_generation 2>/dev/null || true)"
    if [ "$completed" = "$pending" ]; then
      break
    fi
    if [ -e "$deadline" ]; then
      kill "$coordinator_pid" 2>/dev/null || true
      wait "$coordinator_pid" 2>/dev/null || true
      fail "coordinator generation did not complete within 30s"
    fi
    sleep 0.005
  done
  kill "$deadline_pid" 2>/dev/null || true
  wait "$deadline_pid" 2>/dev/null || true
  wait "$coordinator_pid"
  unset HERDR_TASK_SYNC_TEST_LOCATION_BARRIER \
    HERDR_TASK_SYNC_TEST_LOCATION_BARRIER_COUNT \
    HERDR_TASK_SYNC_TEST_LOCATION_BARRIER_RELEASE HERDR_TASK_SYNC_GIT_BUDGET

  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  run jq -e '.panes[] | select(.pane_id == "pane-1") | .tokens.branch == "initial-1" and .tokens.location_status == "stale"' "$state"
  assert_success
  for i in $(seq 2 8); do
    run jq -e --arg pane "pane-$i" \
      '.panes[] | select(.pane_id == $pane) | (.tokens.repo == null and .tokens.worktree == null and .tokens.branch == null and .tokens.location_status == null and .tokens.git_ref == null)' "$state"
    assert_success
    fixture="$(hts_git_fixture_dir "$HTS_WORK/repos/repo-$i/work")"
    assert_file_exists "$fixture/started"
    assert_file_exists "$fixture/completed"
  done
  assert_file_exists "$blocked_fixture/started"
  assert_file_not_exists "$blocked_fixture/completed"
}

@test "herdr-task-sync no-op location event preserves the state file" {
  command -v jq >/dev/null || skip "jq not available"
  command -v perl >/dev/null || skip "perl not available"
  hts_setup
  local root="$HTS_WORK/repo" common="$HTS_WORK/repo.git" cwd="$HTS_WORK/repo/work"
  local location_file before_link before_mtime after_mtime
  mkdir -p "$cwd" "$common"
  hts_git_location_fixture "$cwd" "$root" "$common" refs/heads/main
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$cwd")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_process_label pane-1 task
  hts_location_pass

  location_file="$(hts_pane_state_dir "$HTS_DEFAULT_SOCKET" pane-1)/location.state"
  before_link="$HTS_WORK/location-before.state"
  touch -t 200001010000 "$location_file"
  ln "$location_file" "$before_link"
  before_mtime="$(perl -e 'print((stat shift)[9])' "$location_file")"
  hts_location_pass
  after_mtime="$(perl -e 'print((stat shift)[9])' "$location_file")"

  [ "$location_file" -ef "$before_link" ]
  assert_equal "$after_mtime" "$before_mtime"
}

@test "herdr-task-sync transient location preserves live token-only identity when retained state is unavailable" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local missing_one="$HTS_WORK/missing-one" unavailable="$HTS_WORK/unavailable"
  local outside="$HTS_WORK/outside" pane_one pane_two location_two state
  mkdir -p "$outside" "$unavailable"
  hts_git_fixture "$outside" "" 1 ready 'fatal: not a git repository'
  hts_git_fixture "$unavailable" unavailable 127
  pane_one="$(hts_process_pane_json pane-1 tab-1 "$missing_one")"
  pane_one="$(jq -c '.tokens = {repo:"live-repo",worktree:"live-token",branch:"topic-one",pane_inline:"· one"}' <<< "$pane_one")"
  pane_two="$(hts_process_pane_json pane-2 tab-1 "$unavailable")"
  pane_two="$(jq -c '.tokens = {repo:"live-repo",worktree:"live-token",location_status:"current"}' <<< "$pane_two")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$pane_one"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$pane_two"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-3 tab-1 "$outside")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_process_label pane-1 one
  hts_set_process_label pane-2 two
  hts_set_process_label pane-3 three
  location_two="$(hts_pane_state_dir "$HTS_DEFAULT_SOCKET" pane-2)/location.state"
  mkdir -p "$(dirname "$location_two")"
  printf '%s\n' not-a-location-record > "$location_two"

  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  # Token-only evidence carries no is_linked proof, so the place icon falls
  # back to the branch icon; without any ref evidence the folder icon plus
  # worktree token is the whole $git_ref.
  run jq -e \
    --arg ref_one "$HTS_ICON_BRANCH topic-one $HTS_ICON_FOLDER live-token $HTS_ICON_STALE" \
    --arg ref_two "$HTS_ICON_FOLDER live-token $HTS_ICON_STALE" '
    (.panes[] | select(.pane_id == "pane-1") | .tokens == {repo:"live-repo",worktree:"live-token",branch:"topic-one",location_status:"stale",git_ref:$ref_one})
    and (.panes[] | select(.pane_id == "pane-2") | .tokens == {repo:"live-repo",worktree:"live-token",location_status:"stale",git_ref:$ref_two})
  ' "$state"
  assert_success
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "one · two · three"
  assert_file_not_exists "$(hts_pane_state_dir "$HTS_DEFAULT_SOCKET" pane-1)/location.state"
  assert_equal "$(cat "$location_two")" not-a-location-record
}

@test "herdr-task-sync location authoritative worktree deletion clears retained evidence" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/linked/deleted" common="$HTS_WORK/main/.git"
  local live="$root/live" missing="$root/gone"
  mkdir -p "$live" "$common"
  hts_git_location_fixture "$live" "$root" "$common" refs/heads/deleted
  hts_git_fixture "gitdir:$common" "worktree $HTS_WORK/main\nHEAD 123456\nbranch refs/heads/main" 0
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$live")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_process_label pane-1 worker
  hts_location_pass
  assert_equal "$(jq -r '.panes[0].tokens.worktree' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" deleted
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$missing")"
  hts_location_pass
  run jq -e '.panes[0].tokens.repo == null and .panes[0].tokens.worktree == null and .panes[0].tokens.branch == null and .panes[0].tokens.location_status == null and .panes[0].tokens.git_ref == null' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_success
}

@test "herdr-task-sync formatter keeps Git refs in metadata and tab labels names-only" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/project" common="$HTS_WORK/project/.git"
  local one="$root/one" two="$root/two" missing="$root/missing" outside="$HTS_WORK/outside" state
  mkdir -p "$one" "$two" "$outside" "$common"
  hts_git_location_fixture "$one" "$root" "$common" refs/heads/main
  hts_git_location_fixture "$two" "$root" "$common" refs/heads/main
  hts_git_fixture "$outside" "" 1 ready 'fatal: not a git repository'
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$one")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-2 tab-1 "$two")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"project"}'
  hts_set_process_label pane-1 alpha
  hts_set_process_label pane-2 beta
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"
  assert_equal "$(jq -r '.panes[] | .tokens.git_ref' "$state" | sort -u)" "$HTS_ICON_BRANCH main"

  # Stale state changes only the sidebar metadata, not the tab identity.
  hts_set_pane_location "$HTS_DEFAULT_SOCKET" pane-2 "$two" "$missing"
  hts_location_pass
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"

  hts_set_pane_location "$HTS_DEFAULT_SOCKET" pane-1 "$outside" "$outside"
  hts_set_pane_location "$HTS_DEFAULT_SOCKET" pane-2 "$outside" "$outside"
  hts_location_pass
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"
}

@test "herdr-task-sync formatter renders a main checkout ref in metadata only" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # Main checkout (.git directory at the root), branch main, and checkout
  # folder equal to the Herdr workspace name.
  local root="$HTS_WORK/my-mac-setup" state
  mkdir -p "$root/.git"
  hts_git_location_fixture "$root" "$root" "$root/.git" refs/heads/main
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"my-mac-setup"}'
  hts_set_process_label pane-1 task
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_BRANCH main"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" task
}

@test "herdr-task-sync formatter renders a worktree ref in metadata only" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # A linked worktree in a folder named exactly like its branch. The worktree
  # icon alone carries the place; a folder qualifier would only repeat the ref.
  local root="$HTS_WORK/feature" common="$HTS_WORK/repository/.git" state
  mkdir -p "$root" "$common"
  hts_mark_linked_worktree "$root" "$common/worktrees/feature"
  hts_git_location_fixture "$root" "$root" "$common" refs/heads/feature
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"my-mac-setup"}'
  hts_set_process_label pane-1 task
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_WORKTREE feature"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" task
}

@test "herdr-task-sync formatter keeps a Git-backed all-idle tab names-only" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/repository" state
  mkdir -p "$root/.git"
  hts_git_location_fixture "$root" "$root" "$root/.git" refs/heads/main
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-2 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[{"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hts_proc_info pane-2 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[{"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "~ 1"
  assert_equal "$(jq -r '.panes[] | .label' "$state" | sort -u)" "~"
  assert_equal "$(jq -r '.panes[] | .tokens.git_ref' "$state" | sort -u)" "$HTS_ICON_BRANCH main $HTS_ICON_FOLDER repository"
}

@test "herdr-task-sync Git-only location changes do not rename a names-only tab" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local one="$HTS_WORK/one" two="$HTS_WORK/two" state
  mkdir -p "$one/.git" "$two/.git"
  hts_git_location_fixture "$one" "$one" "$one/.git" refs/heads/one
  hts_git_location_fixture "$two" "$two" "$two/.git" refs/heads/two
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$one")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_process_label pane-1 worker
  hts_location_pass
  : > "$HTS_LOG"

  hts_set_pane_location "$HTS_DEFAULT_SOCKET" pane-1 "$two" "$two"
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" worker
  assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" two
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_BRANCH two"
  run grep '^tab rename' "$HTS_LOG"
  assert_failure
}

@test "herdr-task-sync formatter keeps the folder qualifier on a main checkout in a differently-named folder" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # Plan decision 5 describes the typical main checkout, whose folder repeats
  # the branch or the workspace name. When the folder differs from BOTH it is
  # real location information, so the sidebar qualifier stays — the same
  # suppression rule as every other checkout, no main-checkout special case.
  local root="$HTS_WORK/setup-copy" state
  mkdir -p "$root/.git"
  hts_git_location_fixture "$root" "$root" "$root/.git" refs/heads/main
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"my-mac-setup"}'
  hts_set_process_label pane-1 task
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_BRANCH main $HTS_ICON_FOLDER setup-copy"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" task
}

@test "herdr-task-sync formatter reads the workspace display name from the legacy name field when label is absent" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # Older snapshot shapes carry the workspace display name as `name`; the
  # (.label // .name // "") read must still suppress the folder qualifier when
  # the worktree token merely repeats that name.
  local root="$HTS_WORK/legacy-ws" state
  mkdir -p "$root/.git"
  hts_git_location_fixture "$root" "$root" "$root/.git" refs/heads/topic
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","name":"legacy-ws"}'
  hts_set_process_label pane-1 task
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_BRANCH topic"
}

@test "herdr-task-sync formatter gives a detached HEAD inside a linked worktree the commit icon" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # The commit place deliberately wins over the worktree place: the detached
  # short SHA locates the pane more precisely than worktree-ness does, and the
  # folder qualifier still names the linked worktree in the sidebar.
  local root="$HTS_WORK/wt-detached" common="$HTS_WORK/repository/.git" state
  mkdir -p "$root" "$common"
  hts_mark_linked_worktree "$root" "$common/worktrees/wt-detached"
  hts_git_location_fixture "$root" "$root" "$common" HEAD a1b2c3d
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repository"}'
  hts_set_process_label pane-1 task
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_COMMIT a1b2c3d $HTS_ICON_FOLDER wt-detached"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" task
}

@test "herdr-task-sync formatter qualifies a divergent worktree folder in metadata only" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # A divergent folder remains useful in the sidebar while the tab stays
  # limited to the two pane labels.
  local root="$HTS_WORK/wt-hotfix" common="$HTS_WORK/repository/.git" state
  mkdir -p "$root" "$common"
  hts_mark_linked_worktree "$root" "$common/worktrees/wt-hotfix"
  hts_git_location_fixture "$root" "$root" "$common" refs/heads/fix-login
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-2 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"my-mac-setup"}'
  hts_set_process_label pane-1 alpha
  hts_set_process_label pane-2 beta
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[] | .tokens.git_ref' "$state" | sort -u)" "$HTS_ICON_WORKTREE fix-login $HTS_ICON_FOLDER wt-hotfix"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"
}

@test "herdr-task-sync formatter keeps mixed Git identities out of tabs and repairs external labels" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root_a="$HTS_WORK/a" root_b="$HTS_WORK/b" common_a="$HTS_WORK/a/.git" common_b="$HTS_WORK/b/.git"
  local cwd_a="$root_a/work" cwd_b="$root_b/work" outside="$HTS_WORK/outside" missing="$root_b/missing" state
  mkdir -p "$cwd_a" "$cwd_b" "$outside" "$common_a" "$common_b"
  hts_git_location_fixture "$cwd_a" "$root_a" "$common_a" refs/heads/dev
  hts_git_location_fixture "$cwd_b" "$root_b" "$common_b" refs/heads/main
  hts_git_fixture "$outside" "" 1 ready 'fatal: not a git repository'
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$cwd_a")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-2 tab-1 "$cwd_b")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_process_label pane-1 first
  hts_set_process_label pane-2 second
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "first · second"

  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-2 tab-1 "$cwd_b" present "$missing")"
  hts_socket_run "$HTS_DEFAULT_SOCKET" pane rename pane-1 divergent-pane
  hts_socket_run "$HTS_DEFAULT_SOCKET" tab rename tab-1 divergent-tab
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .label' "$state")" first
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "first · second"

  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-2 tab-1 "$outside")"
  hts_location_pass
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "first · second"
}

@test "herdr-task-sync formatter joins only pane labels when three panes span two repositories" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root_a="$HTS_WORK/a" root_b="$HTS_WORK/b" state
  mkdir -p "$root_a/.git" "$root_b/.git"
  hts_git_location_fixture "$root_a" "$root_a" "$root_a/.git" refs/heads/dev
  hts_git_location_fixture "$root_b" "$root_b" "$root_b/.git" refs/heads/main
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root_a")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-2 tab-1 "$root_a")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-3 tab-1 "$root_b")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_process_label pane-1 one
  hts_set_process_label pane-2 two
  hts_set_process_label pane-3 three
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" \
    "one · two · three"
}

@test "herdr-task-sync worktree tokens use shortest unique slash suffixes for basename collisions" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local one="$HTS_WORK/team/feature" two="$HTS_WORK/release/feature" common="$HTS_WORK/repository/.git" state
  mkdir -p "$one" "$two" "$common"
  hts_mark_linked_worktree "$one" "$common/worktrees/one"
  hts_mark_linked_worktree "$two" "$common/worktrees/two"
  hts_git_location_fixture "$one" "$one" "$common" refs/heads/one
  hts_git_location_fixture "$two" "$two" "$common" refs/heads/two
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$one")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-2 tab-1 "$two")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_process_label pane-1 alpha
  hts_set_process_label pane-2 beta
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.worktree' "$state")" team/feature
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-2") | .tokens.worktree' "$state")" release/feature
  # The slash-suffix folder token appears only in the sidebar qualifier.
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.git_ref' "$state")" "$HTS_ICON_WORKTREE one $HTS_ICON_FOLDER team/feature"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-2") | .tokens.git_ref' "$state")" "$HTS_ICON_WORKTREE two $HTS_ICON_FOLDER release/feature"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"
}

@test "herdr-task-sync worktree tokens digest overlong roots and extend colliding digest prefixes" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local unique="$HTS_WORK/extraordinarily-long-worktree"
  local one="$HTS_WORK/parent-component-that-is-long-one/shared-overlong-name"
  local two="$HTS_WORK/parent-component-that-is-long-two/shared-overlong-name"
  local common="$HTS_WORK/repository/.git" digests="$HTS_WORK/digests" state token_one token_two
  mkdir -p "$unique" "$one" "$two" "$common"
  hts_git_location_fixture "$unique" "$unique" "$common" refs/heads/unique
  hts_git_location_fixture "$one" "$one" "$common" refs/heads/one
  hts_git_location_fixture "$two" "$two" "$common" refs/heads/two
  printf '%s\037%s\n%s\037%s\n' "$one" abcdef00000000000000000000000000 "$two" abcdef10000000000000000000000000 > "$digests"
  export HERDR_TASK_SYNC_TEST_DIGEST_FILE="$digests"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$unique")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-2 tab-1 "$one")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-3 tab-1 "$two")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  for pane_id in pane-1 pane-2 pane-3; do hts_set_process_label "$pane_id" task; done
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  run jq -e '[.panes[].tokens.worktree | select(length <= 18 and test("^[A-Za-z0-9._/-]+~[0-9a-f]{6,}$"))] | length == 3' "$state"
  assert_success
  token_one="$(jq -r '.panes[] | select(.pane_id == "pane-2") | .tokens.worktree' "$state")"
  token_two="$(jq -r '.panes[] | select(.pane_id == "pane-3") | .tokens.worktree' "$state")"
  [[ "$token_one" != "$token_two" ]]
  [[ "$token_one" = *abcdef || "$token_two" = *abcdef ]]
  [[ "$token_one" = *abcdef0 || "$token_two" = *abcdef1 ]]
}

@test "herdr-task-sync worktree token ordinal fallback is unique and stable under pane reordering" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local common="$HTS_WORK/repository/.git" digests="$HTS_WORK/digests" panes='[]' before after i root
  mkdir -p "$common"
  : > "$digests"
  for i in $(seq 1 12); do
    root="$HTS_WORK/parent-component-that-is-deliberately-long-$i/shared-overlong-name"
    mkdir -p "$root"
    hts_git_location_fixture "$root" "$root" "$common" "refs/heads/b$i"
    printf '%s\037%s\n' "$root" ffffffffffffffffffffffffffffffff >> "$digests"
    panes="$(jq -c --argjson pane "$(hts_process_pane_json "pane-$i" tab-1 "$root")" '. + [$pane]' <<< "$panes")"
    hts_set_process_label "pane-$i" task
  done
  export HERDR_TASK_SYNC_TEST_DIGEST_FILE="$digests"
  hts_pane_list "$(jq -cn --argjson panes "$panes" '{result:{panes:$panes}}')"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_location_pass
  before="$(jq -c '[.panes | sort_by(.pane_id)[] | [.pane_id,.tokens.worktree]]' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")"
  run jq -e '[.panes[].tokens.worktree] | length == 12 and (unique | length == 12) and all(.[]; length <= 18)' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_success
  local state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")" tmp="$HTS_WORK/reversed.json"
  jq '.panes |= reverse' "$state" > "$tmp" && mv "$tmp" "$state"
  hts_location_pass
  after="$(jq -c '[.panes | sort_by(.pane_id)[] | [.pane_id,.tokens.worktree]]' "$state")"
  assert_equal "$after" "$before"
}

@test "herdr-task-sync long branch refs stay in metadata and do not alter the tab label" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/worktree" common="$HTS_WORK/repository/.git" state
  local long_ref="feature/very-long-branch-name-that-overflows"
  mkdir -p "$root" "$common"
  hts_mark_linked_worktree "$root" "$common/worktrees/one"
  hts_git_location_fixture "$root" "$root" "$common" "refs/heads/$long_ref"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_process_label pane-1 task
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" task
  assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" "$long_ref"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_WORKTREE $long_ref $HTS_ICON_FOLDER worktree"
}

@test "herdr-task-sync long repository names do not alter a multi-repo tab label" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local one="$HTS_WORK/integration-platform-connectors"
  local two="$HTS_WORK/internal-developer-tooling"
  local common_one="$one/.git" common_two="$two/.git" state
  mkdir -p "$common_one" "$common_two"
  hts_git_location_fixture "$one" "$one" "$common_one" refs/heads/feat/connector-runtime-rewrite
  hts_git_location_fixture "$two" "$two" "$common_two" refs/heads/fix/oauth-refresh-loop-retry
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$one")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-2 tab-1 "$two")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_process_label pane-1 first
  hts_set_process_label pane-2 second
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "first · second"
  assert_equal "$(jq -r '.panes[] | .tokens.repo' "$state" | sort)" $'integration-platform-connectors\ninternal-developer-tooling'
}

@test "herdr-task-sync location clears a retired location_label even when every published token already matches" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/repository" common="$HTS_WORK/repository/.git" state
  mkdir -p "$common"
  hts_git_location_fixture "$root" "$root" "$common" refs/heads/topic
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_process_label pane-1 worker
  # given: one pass has already published every current token
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_BRANCH topic $HTS_ICON_FOLDER repository"
  assert_equal "$(jq -r '.panes[0].tokens.location_label // ""' "$state")" ""
  # given: a stale daemon of the retired version puts location_label back while
  # leaving every token this version compares untouched. It reports under the
  # same source at the sequence the last pass used, which is what an old daemon
  # sharing the generation counter does.
  local legacy_seq
  legacy_seq="$(jq -r '.metadata["pane-1"]["location-sync"].seq' "$state")"
  hts_socket_run "$HTS_DEFAULT_SOCKET" pane report-metadata pane-1 \
    --source location-sync --seq "$legacy_seq" --token 'location_label=repository/topic'
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.location_label' "$state")" repository/topic
  # when: the next pass computes identical tokens and would otherwise skip
  hts_location_pass
  # then: the legacy token is gone and the live tokens are unharmed
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.location_label // ""' "$state")" ""
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_BRANCH topic $HTS_ICON_FOLDER repository"
  assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" topic
}

@test "herdr-task-sync location and formatter add only approved static icon glyphs and no forbidden ownership state" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/plain-worktree" common="$HTS_WORK/repository/.git" state
  mkdir -p "$root" "$common"
  hts_mark_linked_worktree "$root" "$common/worktrees/plain"
  hts_git_location_fixture "$root" "$root" "$common" refs/heads/plain
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_process_label pane-1 plain-task
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  run grep -ER 'manual_owner|reclaim|label_ledger|server_epoch|takeover|prepare_rollback' "$(hts_namespace "$HTS_DEFAULT_SOCKET")"
  assert_failure
  # After removing every approved codicon glyph, only plain ASCII (plus the
  # label separator and ellipsis) may remain in published labels and tokens.
  run jq -e --arg icons "$HTS_ICON_BRANCH$HTS_ICON_WORKTREE$HTS_ICON_COMMIT$HTS_ICON_FOLDER$HTS_ICON_STALE" '
    [.panes[0].label, .tabs[0].label, .panes[0].tokens.worktree, .panes[0].tokens.git_ref]
    | all(.[]; (. // "") | explode - ($icons | explode) | implode | test("^[A-Za-z0-9._:/ ~\u00b7\u2026-]*$"))
  ' "$state"
  assert_success
  assert_equal "$(jq -r '.tabs[0].label' "$state")" plain-task
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_WORKTREE plain $HTS_ICON_FOLDER plain-worktree"
  # pane_inline stays deferred per the label-system plan: no pass publishes it.
  assert_equal "$(jq -r '.panes[0].tokens.pane_inline // ""' "$state")" ""
}

@test "herdr-task-sync plugin exposes only the approved pane and tab invalidations" {
  local manifest="$HTS_PLUGIN_DIR/herdr-plugin.toml"
  run awk '
    /^on = "/ {
      event = $0
      sub(/^on = "/, "", event)
      sub(/"$/, "", event)
      next
    }
    /^command = / && event != "" {
      command = $0
      sub(/^command = /, "", command)
      print event "|" command
      event = ""
    }
  ' "$manifest"
  assert_success
  assert_output $'pane.created|["sh", "ensure.sh", "--event"]\npane.moved|["sh", "ensure.sh", "--event"]\npane.exited|["sh", "ensure.sh", "--event"]\npane.closed|["sh", "ensure.sh", "--event"]\npane.agent_detected|["sh", "ensure.sh", "--event"]\npane.agent_status_changed|["sh", "ensure.sh", "--event"]\ntab.created|["sh", "ensure.sh", "--event"]\ntab.closed|["sh", "ensure.sh", "--event"]\ntab.moved|["sh", "ensure.sh", "--event"]\ntab.renamed|["sh", "ensure.sh", "--event"]'
  assert_file_contains "$manifest" '^min_herdr_version = "0\.8\.0"$'
  assert_file_contains "$manifest" '^id = "sweep"$'
  assert_file_contains "$manifest" '^title = "Pane labels: refresh now"$'
  assert_file_contains "$manifest" '^command = \["sh", "sweep\.sh"\]$'
  run grep -E '^on = ".*\*|^on = "(pane\.updated|workspace\.focused|tab\.focused|pane\.focused)"|reclaim' "$manifest"
  assert_failure
}

@test "herdr-task-sync plugin wrappers invoke one engine mode and isolate failures" {
  local home="$BATS_TEST_TMPDIR/home" engine_log="$BATS_TEST_TMPDIR/plugin-engine.log"
  mkdir -p "$home/.local/bin"
  cat > "$home/.local/bin/herdr-task-sync" <<'SH'
#!/bin/sh
printf '%s|%s|%s\n' "${HTS_PLUGIN_CASE:-}" "$1" "${HERDR_SOCKET_PATH:-}" >> "$HTS_PLUGIN_ENGINE_LOG"
printf 'unexpected stdout\n'
printf 'unexpected stderr\n' >&2
[ "${HTS_PLUGIN_FAIL_ARG:-}" != "$1" ] || exit 23
exit 0
SH
  chmod +x "$home/.local/bin/herdr-task-sync"

  run env HOME="$home" HERDR_SOCKET_PATH=/tmp/u5.sock \
    HTS_PLUGIN_ENGINE_LOG="$engine_log" HTS_PLUGIN_CASE=startup \
    HTS_PLUGIN_FAIL_ARG=--ensure-daemon sh "$HTS_PLUGIN_DIR/ensure.sh"
  assert_success
  assert_output ""
  run env HOME="$home" HERDR_SOCKET_PATH=/tmp/u5.sock \
    HTS_PLUGIN_ENGINE_LOG="$engine_log" HTS_PLUGIN_CASE=event-fails \
    HTS_PLUGIN_FAIL_ARG=--event sh "$HTS_PLUGIN_DIR/ensure.sh" --event
  assert_success
  assert_output ""
  run env HOME="$home" HERDR_SOCKET_PATH=/tmp/u5.sock \
    HTS_PLUGIN_ENGINE_LOG="$engine_log" HTS_PLUGIN_CASE=sweep \
    HTS_PLUGIN_FAIL_ARG=--sweep sh "$HTS_PLUGIN_DIR/sweep.sh"
  assert_success
  assert_output ""
  run cat "$engine_log"
  assert_output $'startup|--ensure-daemon|/tmp/u5.sock\nevent-fails|--event|/tmp/u5.sock\nsweep|--sweep|/tmp/u5.sock'
}

@test "herdr-task-sync event requests reconciliation and ensures the daemon fail-open" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local namespace reconcile sweep_lock pending pid owner start socket_record
  namespace="$(hts_namespace "$HTS_DEFAULT_SOCKET")"
  reconcile="$namespace/reconcile.state"
  sweep_lock="$namespace/sweep.lock"

  HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 hts_event_run
  pending="$(hts_record_number "$reconcile" pending_generation)"
  mkdir "$namespace/presentation-inbox.lock"
  owner="event-test-owner"
  start="$(ps -p "$$" -o lstart= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  socket_record="owner_id=$(printf '%s' "$owner" | base64 | tr -d '\n')
pid=$$
process_start=$(printf '%s' "$start" | base64 | tr -d '\n')
socket_path=$(printf '%s' "$HTS_DEFAULT_SOCKET" | base64 | tr -d '\n')"
  printf '%s\n' "$socket_record" > "$namespace/presentation-inbox.lock/owner"

  export HERDR_TASK_SYNC_TEST_NO_DAEMON=
  export HERDR_TASK_SYNC_LOCK_ATTEMPTS=1
  run hts_event_run
  unset HERDR_TASK_SYNC_TEST_NO_DAEMON HERDR_TASK_SYNC_LOCK_ATTEMPTS
  assert_success
  hts_wait_for_file "$sweep_lock/pid"
  assert_equal "$(hts_record_number "$reconcile" pending_generation)" "$pending"
  pid="$(cat "$sweep_lock/pid")"
  kill "$pid" 2>/dev/null || true
  rm -f "$namespace/presentation-inbox.lock/owner"
  rmdir "$namespace/presentation-inbox.lock"

}

@test "herdr-task-sync sweep repairs an external pane rename without pane.updated" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_run --agent claude --session sweep-correction --set automatic-task < /dev/null
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  hts_socket_run "$HTS_DEFAULT_SOCKET" pane rename pane-1 external-label
  assert_equal "$(jq -r '.panes[0].label' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" external-label

  : > "$HTS_LOG"
  run hts_sweep_run --sweep
  assert_success
  assert_equal "$(jq -r '.panes[0].label' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" cc:automatic-task
  assert_file_contains "$HTS_LOG" '^pane rename pane-1 cc:automatic-task$'
}

@test "herdr-task-sync sweep repairs process and CWD changes through the presentation coordinator" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local old="$HTS_WORK/repos/old" new="$HTS_WORK/repos/new-worktree" common="$HTS_WORK/repos/.git"
  mkdir -p "$old" "$new" "$common"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$old" present "$old")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_git_location_fixture "$old" "$old" "$common" refs/heads/old
  hts_set_process_label pane-1 btop
  # hts_location_pass, not bare hts_event_run: this pass asserts a worktree
  # token, so its git probe needs the calibrated HTS_GIT_BUDGET instead of the
  # shipped 75 ms bound (killed probe -> tokens.worktree null under load).
  hts_location_pass
  assert_equal "$(jq -r '.panes[0].label' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" btop
  assert_equal "$(jq -r '.panes[0].tokens.worktree' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" old

  hts_git_location_fixture "$new" "$new" "$common" refs/heads/new-branch
  hts_set_pane_location "$HTS_DEFAULT_SOCKET" pane-1 "$new" "$new"
  hts_set_process_label pane-1 'cargo test'
  : > "$HTS_LOG"
  run hts_sweep_run --sweep
  assert_success

  local state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].label' "$state")" "cargo test"
  assert_equal "$(jq -r '.panes[0].tokens.worktree' "$state")" new-worktree
  assert_file_contains "$HTS_LOG" '^api snapshot$'
  assert_file_contains "$HTS_LOG" '^pane rename pane-1 cargo test$'
}

@test "herdr-task-sync stays silent outside herdr" {
  hts_setup
  hts_stub_engine pi never-used 0 0
  run env -u HERDR_ENV PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_PANE_ID=pane-1 HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    bash "$HTS_ENGINE" --agent claude --session s1 <<< 'review the cache layer'
  assert_success
  sleep 2
  assert_equal "$(cat "$HTS_LOG")" ""
}

@test "herdr-task-sync publishes the engine slug and stores it (R4, R7)" {
  hts_setup
  hts_stub_engine pi cache-review 0 0
  run hts_run --agent claude --session s1 <<< 'review the cache layer please'
  assert_success
  hts_wait_for_publish
  assert_equal "$(hts_token)" "cache-review"
  local state; state="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 s1)"
  assert_file_exists "$state"
  assert_equal "$(hts_state_field "$state" slug)" "cache-review"
  assert_equal "$(hts_state_field "$state" first_prompt)" "review the cache layer please"
}

# AE1: a continuation prompt must not rename the session. The model decides
# stability (KTD6), so the stub stands in for a model that repeats the name.
@test "herdr-task-sync keeps the slug on a continuation prompt (AE1)" {
  hts_setup
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_worker_exit
  local state control generation
  state="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 s1)"
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  generation="$(hts_record_number "$control" generation)"
  : > "$HTS_LOG"
  hts_run --agent claude --session s1 <<< 'продолжай'
  hts_wait_for_record_number "$control" generation $((generation + 1))
  hts_wait_for_quiescence "$control"
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  assert_equal "$(hts_record_text "$state" slug)" "cache-review"
  run grep -E 'report-metadata|rename' "$HTS_LOG"
  assert_failure
  # The naming call sees the session's first prompt, not only the newest one.
  run cat "$HTS_WORK/pi-stdin.txt"
  assert_output --partial "Current name: cache-review"
  assert_output --partial "review the cache layer please"
}

# AE3: with no usable naming engine the pane keeps whatever it had.
@test "herdr-task-sync publishes nothing when no engine is usable (AE3, R5)" {
  hts_setup
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_worker_exit
  local state before_slug control generation
  state="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 s1)"
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  before_slug="$(hts_record_text "$state" slug)"
  generation="$(hts_record_number "$control" generation)"

  rm -f "$HTS_STUB/pi"
  : > "$HTS_LOG"
  run hts_run --agent claude --session s1 <<< 'now fix the flaky login test'
  assert_success
  hts_wait_for_record_number "$control" generation $((generation + 1))
  hts_wait_for_quiescence "$control"
  assert_equal "$(cat "$HTS_LOG")" ""
  assert_equal "$(hts_record_text "$state" slug)" "$before_slug"
  assert_equal "$(hts_record_text "$state" first_prompt)" "review the cache layer please"
  assert_equal "$(hts_record_text "$state" latest_prompt)" "now fix the flaky login test"
}

@test "herdr-task-sync resets the stored context on a new session id" {
  hts_setup
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_worker_exit
  : > "$HTS_LOG"
  hts_run --agent claude --session s2 <<< 'now fix the flaky login test'
  local state control
  state="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 s2)"
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  # The second session's own state file, not the log: with two sessions in
  # play only a session-scoped signal proves whose worker got this far.
  hts_wait_for_state "$state"
  hts_wait_for_quiescence "$control"
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  assert_equal "$(hts_state_field "$state" first_prompt)" "now fix the flaky login test"
  run cat "$HTS_WORK/pi-stdin.txt"
  assert_output --partial "Current name: (none)"
}

# R8: the adapter's call must not wait on the model.
#
# The property is causal, not temporal, so assert it causally. The controlled
# engine blocks until its release marker exists, so an entry point that waited
# on the model could not return at all -- the regression turns this test red by
# hanging, not by exceeding a number. The previous form timed the entry point
# against a wall-clock bound while the stub slept a fixed 4 s, which only
# discriminates while the bound stays under 4 s; once the bound moved to the
# suite's load-tolerant ceiling a synchronous wait passed it comfortably.
@test "herdr-task-sync returns before the naming engine finishes (R8)" {
  hts_setup
  hts_stub_controlled_engine pi
  hts_model_fixture pi 1 late-slug
  run hts_run --agent claude --session s1 <<< 'a slow substantive prompt'
  assert_success
  # Not vacuous: the engine really was invoked, and it really had not finished
  # when the entry point returned.
  hts_wait_for_file "$HTS_WORK/models/pi/1/started"
  assert_file_not_exists "$HTS_WORK/models/pi/1/completed"
  hts_release_model pi 1
  hts_wait_for_publish
  assert_equal "$(hts_token)" "late-slug"
}

# KTD8: the token reaching herdr and the sidebar is bounded whatever the model
# returns — no shell metacharacters, no ANSI escapes, no newlines. The stub's
# output normalizes to five hyphen-separated words, the engine's cap for a
# published slug; wordier output is treated as a failed naming call instead.
@test "herdr-task-sync normalizes a hostile engine slug (KTD8)" {
  hts_setup
  # Unique per test so concurrent tests cannot collide, and deliberately a
  # single slug word: the payload normalizes to cache-touch-tmp-htspwnN-review,
  # exactly SLUG_MAX_WORDS. A longer path (a $BATS_TEST_TMPDIR one, say) adds
  # words, the engine reads the answer as prose and publishes nothing, and this
  # test then fails waiting for a publish rather than on what it asserts.
  # rm -f clears any file a previous run's payload managed to create.
  local pwn="/tmp/htspwn$BATS_TEST_NUMBER"
  rm -f "$pwn"
  cat > "$HTS_STUB/pi" <<SH
#!/usr/bin/env bash
cat >/dev/null
printf '\n  cache \$(touch $pwn) \033[31mREVIEW\nsecond line\n'
SH
  chmod +x "$HTS_STUB/pi"
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_publish
  run bash -c "printf '%s' '$(hts_token)' | grep -Eq '^[a-z0-9-]{1,40}\$'"
  assert_success
  assert_file_not_exists "$pwn"
}

# KTD7: a naming call that fires the agent's own hooks must not recurse.
@test "herdr-task-sync exits under the recursion guard (KTD7)" {
  hts_setup
  hts_stub_engine pi never-used 0 0
  run env PATH="$HTS_STUB:/usr/bin:/bin" HERDR_ENV=1 HERDR_PANE_ID=pane-1 \
    HERDR_TASK_SYNC_ACTIVE=1 HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    bash "$HTS_ENGINE" --agent claude --session s1 <<< 'review the cache layer'
  assert_success
  sleep 2
  assert_equal "$(cat "$HTS_LOG")" ""
}

# KTD1 chain order: pi first, claude second, then nothing.
@test "herdr-task-sync falls back to claude when pi fails (KTD1)" {
  hts_setup
  hts_stub_engine pi '' 1 0
  hts_stub_engine claude flaky-login-test 0 0
  hts_run --agent claude --session s1 <<< 'now fix the flaky login test'
  hts_wait_for_publish
  assert_equal "$(hts_token)" "flaky-login-test"
}

@test "herdr-task-sync publishes nothing when both engines time out (KTD1)" {
  hts_setup
  hts_stub_engine pi slow-one 0 5
  hts_stub_engine claude slow-two 0 5
  HTS_TIMEOUT=1 hts_run --agent claude --session s1 <<< 'a substantive prompt here'
  sleep 6
  assert_equal "$(cat "$HTS_LOG")" ""
}

@test "herdr-task-sync creates its state directory with mode 700 (KTD3)" {
  hts_setup
  rmdir "$HTS_STATE"
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_publish
  run bash -c "ls -ld '$HTS_STATE' | cut -c1-10"
  assert_output "drwx------"
}

# AE5: a resumed Claude Code session is named from its transcript, before any
# prompt arrives.
@test "herdr-task-sync names a session from its transcript (AE5)" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_stub_engine pi uploader-retry 0 0
  local transcript="$HTS_WORK/transcript.jsonl"
  {
    printf '%s\n' '{"type":"user","isMeta":true,"message":{"role":"user","content":"<command-name>/init</command-name>"}}'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"add retry logic to the uploader"}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"also add a test"}]}}'
  } > "$transcript"
  hts_run --agent claude --session s1 --transcript "$transcript" < /dev/null
  hts_wait_for_publish
  assert_equal "$(hts_token)" "uploader-retry"
  run cat "$HTS_WORK/pi-stdin.txt"
  assert_output --partial "add retry logic to the uploader"
  refute_output --partial "<command-name>"
}

@test "herdr-task-sync publishes nothing for an empty prompt without a transcript" {
  hts_setup
  hts_stub_engine pi never-used 0 0
  run hts_run --agent claude --session s1 < /dev/null
  assert_success
  sleep 2
  assert_equal "$(cat "$HTS_LOG")" ""
}

# AE6: the pi session-name seed path publishes without a model call.
@test "herdr-task-sync --set publishes a normalized name with no engine call (AE6)" {
  hts_setup
  hts_stub_engine pi never-used 0 0
  hts_run --agent pi --session pis1 --set 'Fix CI Flake!' < /dev/null
  hts_wait_for_publish
  assert_equal "$(hts_token)" "fix-ci-flake"
  local state; state="$(hts_task_file "$HTS_DEFAULT_SOCKET" pi pane-1 pis1)"
  assert_equal "$(hts_state_field "$state" slug)" "fix-ci-flake"
  assert_file_not_exists "$HTS_WORK/pi-stdin.txt"
}

# The pane label opens with a short ASCII prefix for the agent, so it renders
# the same on any terminal, patched font or not.
@test "herdr-task-sync names the pane with the agent prefix" {
  hts_setup
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_call 'pane rename'
  assert_equal "$(hts_pane_label)" "cc:cache-review"
}

# An agent outside the known set still gets a readable label: its first letter.
@test "herdr-task-sync falls back to a letter prefix for an unknown agent" {
  hts_setup
  hts_stub_engine pi cache-review 0 0
  hts_run --agent aider --session s1 <<< 'review the cache layer please'
  hts_wait_for_call 'pane rename'
  assert_equal "$(hts_pane_label)" "a:cache-review"
}

# Herdr keeps one label per tab and composes nothing itself. The engine joins
# normalized labels for the tab's own agent panes; another tab's panes stay out.
@test "herdr-task-sync rebuilds the tab label from the pane labels" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","label":"first"},
    {"pane_id":"pane-2","tab_id":"tab-1","agent":"pi","label":"second"},
    {"pane_id":"pane-3","tab_id":"tab-1","agent":"opencode","label":null},
    {"pane_id":"pane-4","tab_id":"tab-2","agent":"claude","label":"other tab"}]}}'
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_call 'tab rename'
  run grep -m1 '^tab rename' "$HTS_LOG"
  assert_output "tab rename tab-1 cc:cache-review · pi · oc"
}

# A pane with no agent is named after its command. The name belongs to the
# leader of the foreground process group (pid 200 here), not to the `node`
# child that `bun run dev` spawns and that the payload lists first.
@test "herdr-task-sync names a command pane after the process group leader" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","label":"agent-label"},
    {"pane_id":"pane-2","tab_id":"tab-1","agent":null,"label":null}]}}'
  hts_proc_info pane-2 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[
      {"pid":201,"name":"node","argv0":"node","argv":["node","-e","timer"]},
      {"pid":200,"name":"bun","argv0":"bun","argv":["bun","run","dev"]}]}}}'
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_call 'tab rename'
  assert_equal "$(hts_pane_label pane-2)" "bun run dev"
  run grep -m1 '^tab rename' "$HTS_LOG"
  assert_output "tab rename tab-1 cc:cache-review · bun run dev"
}

# A pane whose foreground process group is its own shell runs nothing. It keeps
# its slot in the tab label under a placeholder instead of disappearing.
@test "herdr-task-sync names an idle pane with the placeholder" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","label":"agent-label"},
    {"pane_id":"pane-2","tab_id":"tab-1","agent":null,"label":"btop"}]}}'
  hts_proc_info pane-2 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_call 'tab rename'
  assert_equal "$(hts_pane_label pane-2)" "~"
  run grep -m1 '^tab rename' "$HTS_LOG"
  assert_output "tab rename tab-1 cc:cache-review · ~"
}

# The session coordinator knows tab position, so task invalidation and sweeps
# use the same numbered placeholder for an all-idle tab.
@test "herdr-task-sync presentation numbers an all-idle tab" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":null,"label":null}]}}'
  hts_proc_info pane-1 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_call 'tab rename tab-1 ~ 1'
  assert_equal "$(hts_pane_label pane-1)" "~"
}

# One pane must not eat the whole tab label, so a long command name is cut to
# 24 characters with a trailing ellipsis. Flags and paths drop out entirely.
@test "herdr-task-sync truncates a long command name" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":null,"label":null}]}}'
  hts_proc_info pane-1 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[
      {"pid":200,"name":"long","argv0":"/opt/bin/averyveryverylongcommandname",
       "argv":["/opt/bin/averyveryverylongcommandname","--flag","/tmp/path","sub"]}]}}}'
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_call 'tab rename'
  run grep -m1 '^tab rename' "$HTS_LOG"
  assert_output "tab rename tab-1 averyveryverylongcomman…"
}

# A naming call refreshes only its own tab, so a command that ends and an agent
# that quits leave a stale label behind. The sweep is the observer for both: it
# walks every tab herdr knows, not just the one that triggered it.
@test "herdr-task-sync --sweep relabels every tab" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_tab_list '{"result":{"tabs":[
    {"tab_id":"tab-1","label":"1"},
    {"tab_id":"tab-2","label":"2"}]}}'
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","label":"agent-label"},
    {"pane_id":"pane-2","tab_id":"tab-2","agent":null,"label":null}]}}'
  hts_proc_info pane-2 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[
      {"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  run hts_sweep_run --sweep
  assert_success
  run grep -c '^tab rename' "$HTS_LOG"
  assert_output "2"
  run grep '^tab rename tab-2' "$HTS_LOG"
  assert_output "tab rename tab-2 btop"
}

# The daemon sweeps every few seconds. Renaming a tab to the label it already
# carries would churn the tab row and the socket for nothing.
@test "herdr-task-sync --sweep leaves an unchanged tab label alone" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_tab_list '{"result":{"tabs":[{"tab_id":"tab-1","label":"btop"}]}}'
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":null,"label":"btop"}]}}'
  hts_proc_info pane-1 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[
      {"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  run hts_sweep_run --sweep
  assert_success
  run cat "$HTS_LOG"
  refute_output --partial "tab rename"
  refute_output --partial "pane rename"
}

# An all-idle tab is numbered instead of skipped, or its last composed label
# would outlive the pane that produced it. The number counts tabs inside one
# workspace, because a tab row shows one workspace at a time.
@test "herdr-task-sync --sweep numbers all-idle tabs per workspace" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_tab_list '{"result":{"tabs":[
    {"tab_id":"tab-1","workspace_id":"ws-1","label":"1"},
    {"tab_id":"tab-2","workspace_id":"ws-1","label":"stale name"},
    {"tab_id":"tab-3","workspace_id":"ws-2","label":"2"}]}}'
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":null,"label":null},
    {"pane_id":"pane-2","tab_id":"tab-2","agent":null,"label":null},
    {"pane_id":"pane-3","tab_id":"tab-3","agent":null,"label":null}]}}'
  hts_proc_info pane-1 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hts_proc_info pane-2 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hts_proc_info pane-3 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  run hts_sweep_run --sweep
  assert_success
  run grep '^tab rename' "$HTS_LOG"
  assert_line "tab rename tab-1 ~ 1"
  assert_line "tab rename tab-2 ~ 2"
  assert_line "tab rename tab-3 ~ 1"
}

# herdr fires the plugin hook on every agent state change, so the guard has to
# be cheap and exact: one daemon per machine, however often it is called.
@test "herdr-task-sync --ensure-daemon keeps a single daemon" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  sleep 30 &
  local live=$! sweep_lock="$(hts_namespace "$HTS_DEFAULT_SOCKET")/sweep.lock"
  mkdir -p "$sweep_lock"
  printf '%s' "$live" > "$sweep_lock/pid"
  run hts_sweep_run --ensure-daemon
  assert_success
  assert_equal "$(cat "$sweep_lock/pid")" "$live"
  kill "$live" 2>/dev/null || true
}

# A daemon killed with its herdr session leaves the lock behind. The next hook
# must clear it and start a new daemon, or labels stay frozen until a restart.
@test "herdr-task-sync --ensure-daemon replaces a dead daemon" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_tab_list '{"result":{"tabs":[{"tab_id":"tab-1","label":"1"}]}}'
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","label":"agent-label"}]}}'
  local sweep_lock="$(hts_namespace "$HTS_DEFAULT_SOCKET")/sweep.lock"
  mkdir -p "$sweep_lock"
  # A pid that cannot be running: process ids are allocated from 1 upwards.
  printf '%s' "999999" > "$sweep_lock/pid"
  run hts_sweep_run --ensure-daemon
  assert_success
  hts_wait_for_call 'tab rename'
  local pid; pid="$(cat "$sweep_lock/pid" 2>/dev/null)"
  [ -n "$pid" ] && [ "$pid" != "999999" ]
  kill "$pid" 2>/dev/null || true
}

@test "herdr-task-sync --restart-daemon replaces a live daemon" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_tab_list '{"result":{"tabs":[{"tab_id":"tab-1","label":"1"}]}}'
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","label":"agent-label"}]}}'
  local sweep_lock="$(hts_namespace "$HTS_DEFAULT_SOCKET")/sweep.lock" old_pid new_pid i
  HTS_SWEEP_INTERVAL=30 hts_sweep_run --ensure-daemon
  hts_wait_for_file "$sweep_lock/pid"
  old_pid="$(cat "$sweep_lock/pid")"

  HTS_SWEEP_INTERVAL=30 run hts_sweep_run --restart-daemon
  assert_success
  for i in $(seq 1 "$HTS_WAIT_POLLS"); do
    new_pid="$(cat "$sweep_lock/pid" 2>/dev/null || true)"
    [ -n "$new_pid" ] && [ "$new_pid" != "$old_pid" ] && break
    sleep 0.01
  done

  [ -n "$new_pid" ]
  [ "$new_pid" != "$old_pid" ]
  ! kill -0 "$old_pid" 2>/dev/null
  kill "$new_pid" 2>/dev/null || true
}

@test "herdr-task-sync --restart-daemon refuses an unrelated lock owner" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  sleep 30 &
  local live=$! sweep_lock="$(hts_namespace "$HTS_DEFAULT_SOCKET")/sweep.lock"
  mkdir -p "$sweep_lock"
  printf '%s' "$live" > "$sweep_lock/pid"

  run hts_sweep_run --restart-daemon

  assert_failure
  assert_output --partial "refusing to stop unrelated sweep lock owner $live"
  kill -0 "$live"
  kill "$live" 2>/dev/null || true
}

@test "herdr-task-sync sweep daemon exits after three unreachable snapshots" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local dir daemon_pid i
  dir="$(hts_socket_dir "$HTS_DEFAULT_SOCKET")"
  : > "$dir/fail-snapshot"
  HTS_SWEEP_INTERVAL=0.01 hts_sweep_run --sweep-daemon &
  daemon_pid=$!
  for i in $(seq 1 $HTS_WAIT_POLLS); do
    kill -0 "$daemon_pid" 2>/dev/null || break
    sleep 0.01
  done
  if kill -0 "$daemon_pid" 2>/dev/null; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    fail "sweep daemon kept polling an unreachable socket"
  fi
  wait "$daemon_pid"
  run grep -c '^api snapshot$' "$HTS_LOG"
  assert_output "3"
  assert_dir_not_exists "$(hts_namespace "$HTS_DEFAULT_SOCKET")/sweep.lock"
}

# ===========================================
# herdr-task-sync Claude Code hook
# ===========================================

HTS_HOOK="$HOOKS_DIR/executable_herdr-task-sync-hook.sh"

# Put a recording stub named `herdr-task-sync` on PATH so the hook's own
# argument handling can be checked without running the real engine.
hts_hook_setup() {
  hts_setup
  cat > "$HTS_STUB/herdr-task-sync" <<SH
#!/usr/bin/env bash
{ printf 'ARGS[%s]\n' "\$*"; printf 'STDIN[%s]\n' "\$(cat)"; } >> "$HTS_WORK/engine.log"
SH
  chmod +x "$HTS_STUB/herdr-task-sync"
}

hts_hook_run() {
  env PATH="$HTS_STUB:/usr/bin:/bin" bash "$HTS_HOOK" "$@"
}

# Claude Code injects a UserPromptSubmit hook's stdout into the conversation,
# so the hook must stay silent on every path. This one drives the real engine
# with HERDR_ENV unset: the guard lives there, not in the hook.
@test "herdr-task-sync hook stays silent and publishes nothing outside herdr" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # A copy, not a symlink: the source file is mode 644 and only chezmoi's
  # `executable_` prefix makes the deployed engine executable.
  cp "$HTS_ENGINE" "$HTS_STUB/herdr-task-sync"
  chmod +x "$HTS_STUB/herdr-task-sync"
  run env -u HERDR_ENV PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_PANE_ID=pane-1 HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    bash "$HTS_HOOK" prompt <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"s1","transcript_path":"/tmp/none.jsonl","prompt":"review the cache layer"}
EOF
  assert_success
  assert_output ""
  sleep 2
  assert_equal "$(cat "$HTS_LOG")" ""
}

@test "herdr-task-sync hook writes nothing to stdout when the engine runs" {
  command -v jq >/dev/null || skip "jq not available"
  hts_hook_setup
  run hts_hook_run prompt <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"s1","transcript_path":"/tmp/none.jsonl","prompt":"review the cache layer"}
EOF
  assert_success
  assert_output ""
}

@test "herdr-task-sync hook forwards the prompt, session, and transcript" {
  command -v jq >/dev/null || skip "jq not available"
  hts_hook_setup
  hts_hook_run prompt <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"s1","transcript_path":"/tmp/t.jsonl","prompt":"review the cache layer"}
EOF
  run cat "$HTS_WORK/engine.log"
  assert_output --partial "--agent claude --session s1 --transcript /tmp/t.jsonl"
  assert_output --partial "STDIN[review the cache layer]"
}

# KTD9: session start and pre-compact name the session from the transcript,
# with no prompt on stdin.
@test "herdr-task-sync hook calls transcript mode on session start and compact" {
  command -v jq >/dev/null || skip "jq not available"
  hts_hook_setup
  hts_hook_run session <<'EOF'
{"hook_event_name":"SessionStart","session_id":"s1","transcript_path":"/tmp/t.jsonl","source":"resume"}
EOF
  hts_hook_run compact <<'EOF'
{"hook_event_name":"PreCompact","session_id":"s1","transcript_path":"/tmp/t.jsonl","trigger":"manual"}
EOF
  run cat "$HTS_WORK/engine.log"
  assert_output --partial "--transcript /tmp/t.jsonl"
  assert_output --partial "STDIN[]"
  refute_output --partial "STDIN[review"
}

# agent_id is present only when a hook fires inside a subagent call, so the
# pane's task name never follows subagent traffic (R3).
@test "herdr-task-sync hook drops subagent traffic (R3)" {
  command -v jq >/dev/null || skip "jq not available"
  hts_hook_setup
  run hts_hook_run prompt <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"s1","agent_id":"agent-abc123","transcript_path":"/tmp/t.jsonl","prompt":"subagent prompt"}
EOF
  assert_success
  assert_file_not_exists "$HTS_WORK/engine.log"
}

@test "herdr-task-sync hook survives malformed stdin" {
  hts_hook_setup
  run hts_hook_run prompt <<< 'not json at all'
  assert_success
  assert_output ""
}

@test "se pipeline --setup-cmd lands in the workflow input JSON" {
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local plan
  plan="$BATS_TEST_TMPDIR/se-dryrun-plan.md"
  printf -- '---\nartifact_contract: ce-unified-plan/v1\n---\n# t\n' > "$plan"
  run env SE_DRY_RUN=1 "$se_bin" pipeline "$plan" --setup-cmd 'bun install && bunx turbo run build --filter=@x/y'
  assert_success
  assert_output --partial '"setupCmd":"bun install && bunx turbo run build --filter=@x/y"'
}

@test "se flow --dry-run lands spec path, budget, and setup-cmd in the workflow input JSON" {
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local spec
  spec="$BATS_TEST_TMPDIR/se-flow-spec.json"
  printf '{"task":{"description":"x"},"repo":"/tmp/r","blocks":[{"id":"scan","block":"secret-scan","retries":0,"timeoutMs":120000}]}' > "$spec"
  run env "$se_bin" flow "$spec" --budget 12 --setup-cmd 'make setup' --dry-run
  assert_success
  assert_output --partial 'workflows/se-flow.tsx'
  assert_output --partial '"budgetUsd":12'
  assert_output --partial '"setupCmd":"make setup"'
  assert_output --partial '"specPath":"'
  assert_output --partial 'se-flow-spec.json'
}

@test "se flow --validate-cmd lands the operator's command in the workflow input JSON" {
  # The run-validate block and the simplify subflow read the command from the
  # run, never from the spec. Without this flag the workflow default is empty
  # and run-validate can only ever record exitCode null.
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local spec
  spec="$BATS_TEST_TMPDIR/se-flow-spec.json"
  printf '{"task":{"description":"x"},"repo":"/tmp/r","blocks":[{"id":"scan","block":"secret-scan","retries":0,"timeoutMs":120000}]}' > "$spec"
  run env "$se_bin" flow "$spec" --validate-cmd 'bun test' --dry-run
  assert_success
  assert_output --partial '"validateCmd":"bun test"'
}

@test "se flow without --validate-cmd sends an empty command, not a missing key" {
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local spec
  spec="$BATS_TEST_TMPDIR/se-flow-spec.json"
  printf '{"task":{"description":"x"},"repo":"/tmp/r","blocks":[{"id":"scan","block":"secret-scan","retries":0,"timeoutMs":120000}]}' > "$spec"
  run env "$se_bin" flow "$spec" --dry-run
  assert_success
  assert_output --partial '"validateCmd":""'
}

@test "se flow --dry-run prints the composed flow with a cost estimate (R10)" {
  # The operator sees what a launch will run and what it may cost before it
  # starts. A bare command line does not carry that.
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local spec
  spec="$BATS_TEST_TMPDIR/se-flow-spec.json"
  cat > "$spec" <<'JSON'
{"task":{"description":"printout fixture"},"repo":"/tmp/r","blocks":[
 {"id":"implement","block":"work","input":{"prompt":"x"},"retries":0,"timeoutMs":600000,"after":[],"bindTo":[]},
 {"id":"scan","block":"secret-scan","input":{},"retries":0,"timeoutMs":120000,"after":["implement"],"bindTo":["implement"]}]}
JSON
  run env "$se_bin" flow "$spec" --dry-run
  assert_success
  assert_output --partial 'flow: printout fixture'
  assert_output --partial '2 blocks, estimated ~$'
  assert_output --partial 'implement'
  assert_output --partial 'scan'
}

@test "se flow refuses a spec the validator rejects, before launching" {
  # A publish with no secret-scan ancestor must stop at the CLI, not at the
  # interpreter's gate-0 after a run has already been created.
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local spec
  spec="$BATS_TEST_TMPDIR/se-flow-spec.json"
  cat > "$spec" <<'JSON'
{"task":{"description":"unscanned publish"},"repo":"/tmp/r","blocks":[
 {"id":"implement","block":"work","input":{"prompt":"x"},"retries":0,"timeoutMs":600000,"after":[],"bindTo":[]},
 {"id":"ship","block":"pr","input":{"title":"t"},"retries":0,"timeoutMs":300000,"after":["implement"],"bindTo":["implement"]}]}
JSON
  run env "$se_bin" flow "$spec" --dry-run
  assert_failure
  assert_output --partial 'scan-before-external'
}

@test "se flow rejects a non-numeric budget" {
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local spec
  spec="$BATS_TEST_TMPDIR/se-flow-spec.json"
  printf '{}' > "$spec"
  run env "$se_bin" flow "$spec" --budget abc --dry-run
  assert_failure
}

# Builds a runtime dir with a stub smithers binary and a smithers.db holding one
# pending approval, so `se show` / `se approve` can be exercised without an
# engine. Echoes the dir path.
se_fake_runtime() {
  local dir="$BATS_TEST_TMPDIR/se-runtime" title=$1 summary=$2
  mkdir -p "$dir/node_modules/.bin"
  # Records its argv so a test can assert what se asked the engine to do.
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/calls.log"\necho null\n' "$dir" \
    > "$dir/node_modules/.bin/smithers"
  chmod +x "$dir/node_modules/.bin/smithers"
  sqlite3 "$dir/smithers.db" "
    CREATE TABLE summary (run_id TEXT, verdict TEXT, branch TEXT, plan_path TEXT,
      report_dir TEXT, total_tokens REAL, est_cost_usd REAL, notes TEXT);
    CREATE TABLE _smithers_approvals (run_id TEXT, node_id TEXT, iteration INTEGER,
      status TEXT, requested_at_ms INTEGER, request_json TEXT);
    INSERT INTO _smithers_approvals VALUES ('run-1', 'approve-work-1', 0, 'pending', 1,
      json_object('title', '$title', 'summary', '$summary'));
    CREATE TABLE _smithers_runs (run_id TEXT, status TEXT, runtime_owner_id TEXT, workflow_path TEXT);
    INSERT INTO _smithers_runs VALUES ('run-1', 'waiting-event', '', '/x/se-pipeline.tsx');
    CREATE TABLE gate0 (run_id TEXT, repo_path TEXT);
    INSERT INTO gate0 VALUES ('run-1', '/tmp/target-repo');"
  printf '%s' "$dir"
}

@test "se show prints the pending approval's title and reasons, not just a status word" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 is required"
  command -v jq >/dev/null 2>&1 || skip "jq is required"
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local dir
  dir="$(se_fake_runtime 'work gate is failed — approve ONE extra attempt; deny aborts the run' 'validate-cmd exited with code 1')"

  run env SE_SMITHERS_DIR="$dir" "$se_bin" show run-1

  assert_success
  assert_output --partial 'DECISION REQUIRED: approve-work-1'
  assert_output --partial 'work gate is failed'
  assert_output --partial 'validate-cmd exited with code 1'
}

@test "se approve prints what is being decided before recording the decision" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 is required"
  command -v jq >/dev/null 2>&1 || skip "jq is required"
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local dir
  dir="$(se_fake_runtime 'work failed the extra attempt — abort only: approve stops the run WITH a report' 'no content change')"

  run env SE_SMITHERS_DIR="$dir" "$se_bin" approve run-1

  # The operator must see that approve STOPS this run rather than continuing it.
  assert_output --partial 'approve stops the run WITH a report'
}

@test "se show on a run with no pending approval prints no decision block" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 is required"
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local dir
  dir="$(se_fake_runtime 'unused' 'unused')"
  sqlite3 "$dir/smithers.db" "UPDATE _smithers_approvals SET status='approved';"

  run env SE_SMITHERS_DIR="$dir" "$se_bin" show run-1

  assert_success
  refute_output --partial 'DECISION REQUIRED'
}

@test "se approve resumes a parked run that nothing is driving" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 is required"
  command -v jq >/dev/null 2>&1 || skip "jq is required"
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local dir
  dir="$(se_fake_runtime 'work gate is failed' 'boom')"

  # #given a parked run with no owner (the owner process exits when a run parks)
  # #when the operator approves
  run env SE_SMITHERS_DIR="$dir" "$se_bin" approve run-1

  # #then the decision is recorded AND the run is driven onward, no manual resume
  assert_success
  assert_file_contains "$dir/calls.log" '^approve run-1'
  assert_file_contains "$dir/calls.log" 'resume true'
}

@test "se approve --no-resume records the decision without driving the run" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 is required"
  command -v jq >/dev/null 2>&1 || skip "jq is required"
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local dir
  dir="$(se_fake_runtime 'work gate is failed' 'boom')"

  run env SE_SMITHERS_DIR="$dir" "$se_bin" approve run-1 --no-resume

  assert_success
  assert_file_contains "$dir/calls.log" '^approve run-1'
  run grep -c 'resume true' "$dir/calls.log"
  assert_failure
}

@test "se approve refuses to resume a run a live process already owns" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 is required"
  command -v jq >/dev/null 2>&1 || skip "jq is required"
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local dir
  dir="$(se_fake_runtime 'work gate is failed' 'boom')"
  # #given the run is owned by this very shell, which is unquestionably alive:
  # two engines on one run corrupt its state, so the resume must be declined.
  sqlite3 "$dir/smithers.db" \
    "UPDATE _smithers_runs SET status='running', runtime_owner_id='pid:$$:abc';"

  run env SE_SMITHERS_DIR="$dir" "$se_bin" approve run-1

  assert_success
  assert_output --partial 'owned by a live process'
  run grep -c 'resume true' "$dir/calls.log"
  assert_failure
}

@test "se approve does not resume a run that already finished" {
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 is required"
  command -v jq >/dev/null 2>&1 || skip "jq is required"
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local dir
  dir="$(se_fake_runtime 'work gate is failed' 'boom')"
  sqlite3 "$dir/smithers.db" "UPDATE _smithers_runs SET status='finished';"

  run env SE_SMITHERS_DIR="$dir" "$se_bin" approve run-1

  assert_success
  run grep -c 'resume true' "$dir/calls.log"
  assert_failure
}

@test "se approve usage does not promise that approve continues the run" {
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  run env "$se_bin" --help
  assert_success
  refute_output --partial 'approve a paused run (continue past the gate)'
  assert_output --partial 'ONE more attempt'
}

@test "se blocks --json emits the composable block catalog" {
  local smithers_dir="$SOURCE_ROOT/private_dot_claude/dot_smithers"
  local se_bin="$smithers_dir/bin/executable_se"
  # Unlike the other se tests this one drives the real binary, which only exists
  # after `bun install` in $smithers_dir. CI always installs it and asserts it is
  # executable in a separate workflow step, so skipping here cannot hide a broken
  # install -- it only keeps a fresh local checkout from reporting a false failure.
  [ -x "$smithers_dir/node_modules/.bin/smithers" ] || \
    skip "smithers deps not installed (run bun install in $smithers_dir)"
  run env SE_SMITHERS_DIR="$smithers_dir" "$se_bin" blocks --json
  assert_success
  assert_output --partial '"secret-scan"'
  assert_output --partial '"code-review"'
  # KTD6 JSON-Schema limitation note travels with the catalog.
  assert_output --partial 'runtime-parses'
}

# ===========================================
# Pi settings modifier
# ===========================================

@test "Pi settings modifier selects the terminal theme and exact extension packages" {
  local modifier="$SOURCE_ROOT/dot_pi/agent/modify_settings.json"
  local input='{"theme":"light","lastChangelogVersion":"0.84.2","packages":["npm:pi-ask-user","npm:obsolete-extension","npm:unexpected-extension"],"skills":["~/custom/skills"]}'

  run bash "$modifier" <<< "$input"

  assert_success
  run jq -e '
    [
      "npm:@ff-labs/pi-fff",
      "npm:@howaboua/pi-codex-conversion",
      "npm:pi-subagents",
      "npm:pi-agent-browser-native",
      "git:github.com/EveryInc/compound-engineering-plugin",
      "npm:pi-ask-user",
      "npm:@trevonistrevon/pi-loop",
      "npm:pi-web-access",
      "npm:pi-context-view"
    ] as $extensions |
    .theme == "terminal" and
    .lastChangelogVersion == "0.84.2" and
    (.packages == $extensions) and
    (.skills | index("~/.claude/skills") != null) and
    (.skills | index("~/custom/skills") != null)
  ' <<< "$output"
  assert_success
}

@test "Pi settings modifier is idempotent" {
  local modifier="$SOURCE_ROOT/dot_pi/agent/modify_settings.json"
  local input='{"packages":["npm:@ff-labs/pi-fff","npm:@howaboua/pi-codex-conversion","npm:pi-subagents","npm:pi-agent-browser-native","git:github.com/EveryInc/compound-engineering-plugin","npm:pi-ask-user","npm:@trevonistrevon/pi-loop","npm:pi-web-access","npm:pi-context-view"],"skills":["~/.claude/skills"]}'

  run bash "$modifier" <<< "$input"

  assert_success
  run jq -e '
    [
      "npm:@ff-labs/pi-fff",
      "npm:@howaboua/pi-codex-conversion",
      "npm:pi-subagents",
      "npm:pi-agent-browser-native",
      "git:github.com/EveryInc/compound-engineering-plugin",
      "npm:pi-ask-user",
      "npm:@trevonistrevon/pi-loop",
      "npm:pi-web-access",
      "npm:pi-context-view"
    ] as $extensions |
    (.theme == "terminal") and
    (.packages == $extensions) and
    ([.skills[] | select(. == "~/.claude/skills")] | length == 1)
  ' <<< "$output"
  assert_success
}

@test "Pi terminal theme uses only terminal palette colors" {
  local theme="$SOURCE_ROOT/dot_pi/agent/themes/terminal.json"

  run jq -e '
    .name == "terminal" and
    .colors.text == "" and
    .colors.userMessageBg == "" and
    ([.vars[]] | all(type == "number" and . >= 0 and . <= 15)) and
    ([.colors[] | select(type == "string" and startswith("#"))] | length == 0)
  ' "$theme"
  assert_success
}

@test "Claude Code daltonized theme extends light ANSI with terminal colors" {
  local theme="$SOURCE_ROOT/private_dot_claude/themes/light-ansi-daltonized.json"

  run jq -e '
    .base == "light-ansi" and
    (.overrides | length > 0) and
    ([.overrides[] | select(startswith("ansi:") | not)] | length == 0)
  ' "$theme"
  assert_success
}

# ===========================================
# morning-cleanup script
# ===========================================

@test "morning-cleanup trashes stale .omc state and stamps the day" {
  local script="$SOURCE_ROOT/dot_local/bin/executable_morning-cleanup.sh"
  local fake_home="$BATS_TEST_TMPDIR/mc-home"
  mkdir -p "$fake_home/Projects/demo/.omc"
  printf '{}' > "$fake_home/Projects/demo/.omc/state.json"
  touch -t 202001010000 "$fake_home/Projects/demo/.omc/state.json"

  run env HOME="$fake_home" MORNING_CLEANUP_NO_NOTIFY=1 bash "$script"
  assert_success
  [ ! -d "$fake_home/Projects/demo/.omc" ]
  [ -f "$fake_home/.local/state/morning-cleanup/last-run" ]
}

@test "morning-cleanup keeps a recently active .omc dir" {
  local script="$SOURCE_ROOT/dot_local/bin/executable_morning-cleanup.sh"
  local fake_home="$BATS_TEST_TMPDIR/mc-home-live"
  mkdir -p "$fake_home/Projects/demo/.omc"
  printf '{}' > "$fake_home/Projects/demo/.omc/state.json"

  run env HOME="$fake_home" MORNING_CLEANUP_NO_NOTIFY=1 bash "$script"
  assert_success
  [ -d "$fake_home/Projects/demo/.omc" ]
}

@test "morning-cleanup is a no-op on its second run of the day" {
  local script="$SOURCE_ROOT/dot_local/bin/executable_morning-cleanup.sh"
  local fake_home="$BATS_TEST_TMPDIR/mc-home-stamp"
  mkdir -p "$fake_home/Projects"
  run env HOME="$fake_home" MORNING_CLEANUP_NO_NOTIFY=1 bash "$script"
  assert_success

  mkdir -p "$fake_home/Projects/late/.omc"
  printf '{}' > "$fake_home/Projects/late/.omc/state.json"
  touch -t 202001010000 "$fake_home/Projects/late/.omc/state.json"
  run env HOME="$fake_home" MORNING_CLEANUP_NO_NOTIFY=1 bash "$script"
  assert_success
  [ -d "$fake_home/Projects/late/.omc" ]
}

@test "morning-cleanup keeps fresh trash entries" {
  local script="$SOURCE_ROOT/dot_local/bin/executable_morning-cleanup.sh"
  local fake_home="$BATS_TEST_TMPDIR/mc-home-trash"
  mkdir -p "$fake_home/Projects" "$fake_home/.scratchpad/fresh-entry"
  printf 'x' > "$fake_home/.scratchpad/fresh-entry/file"

  run env HOME="$fake_home" MORNING_CLEANUP_NO_NOTIFY=1 bash "$script"
  assert_success
  [ -d "$fake_home/.scratchpad/fresh-entry" ]
}
