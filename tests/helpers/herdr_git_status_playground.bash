# Herdr Git status playground Bats harness.
# Load after helpers/common so SOURCE_ROOT and assertion helpers are available.

HGSP_CONTROLLER="$SOURCE_ROOT/dot_local/bin/executable_herdr-git-status-playground"
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
  unset HGSP_ENV_LOG HGSP_RUN_IDS HGSP_BG_PIDS HGSP_LAST_RUN_ID
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
  local real_git
  real_git="$(command -v git)"
  cat > "$HGSP_STUB/git" <<SH
#!/bin/sh
if [ -n "\${GIT_CEILING_DIRECTORIES:-}" ]; then
  printf 'git-fixture|%s\n' "\$*" >> "\$HGSP_CALL_LOG"
  exec "$real_git" "\$@"
fi
printf 'git|%s\n' "\$*" >> "\$HGSP_CALL_LOG"
case "\$1" in
  --version) printf 'git version 2.45.0\n'; exit 0 ;;
esac
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
  ln -s "$HGSP_PYTHON" "$HGSP_STUB/python3"

  cat > "$HGSP_STUB/herdr" <<'SH'
#!/bin/sh
printf 'herdr|%s\n' "$*" >> "$HGSP_CALL_LOG"
if [ "$1" = --version ]; then
  printf '%s\n' "${HGSP_HERDR_VERSION:-herdr 0.8.2}"
  exit 0
fi
exit 97
SH
  chmod +x "$HGSP_STUB/herdr"

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
{"candidates":{"ezcorp":{"revision":"f144c8dac2860e344b6b379d2bcfee229dcf10ad","tree":"tree-ezcorp"},"sfroment":{"revision":"b726977143adc2847dc25e3327bc0b1b4fc26455","tree":"tree-sfroment"},"krystof":{"revision":"fe6575a89de9006c35d9d0b9707397839d983cff","tree":"tree-krystof"},"jmarbutt":{"revision":"8a56c5dce0bd65e47eddc9a1d862ddae870cddc3","tree":"tree-jmarbutt"}}}
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
    HERDR_GIT_STATUS_PLAYGROUND_CONTROLLER_TOKEN=controller-canary \
    HERDR_GIT_STATUS_PLAYGROUND_CANDIDATE_TOKEN=candidate-canary \
    HERDR_GIT_STATUS_PLAYGROUND_TEST_MODE=1 \
    HERDR_GIT_STATUS_PLAYGROUND_TEST_LOG="$HGSP_ENV_LOG" \
    HERDR_GIT_STATUS_PLAYGROUND_TEST_PARENT_ENV="$HGSP_WORK/inherited-environment.json" \
    HERDR_GIT_STATUS_PLAYGROUND_TEST_PROCESS="$HGSP_STUB/managed-probe" \
    "$HGSP_PYTHON" "$HGSP_CONTROLLER" "$@"
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
