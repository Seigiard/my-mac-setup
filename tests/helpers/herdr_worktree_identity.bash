# Herdr worktree-identity harness. Load after helpers/common.

HWI_STATE_LIBRARY="$SOURCE_ROOT/dot_local/lib/herdr-worktree-state.sh"
export HWI_STATE_LIBRARY
HWI_ENGINE="$SOURCE_ROOT/dot_local/bin/executable_herdr-worktree-identity"
HWI_WORKTREE_SETUP_PLUGIN="$SOURCE_ROOT/private_dot_config/herdr/plugins/worktree-setup/setup.ts"
export HWI_ENGINE HWI_WORKTREE_SETUP_PLUGIN

hwi_setup() {
  HWI_WORK="$(mktemp -d "${BATS_TMPDIR:-/tmp}/hwi.XXXXXX")"
  HWI_STATE="$HWI_WORK/state"
  HWI_STUB="$HWI_WORK/stub"
  HWI_PANE_JSON="$HWI_WORK/pane.json"
  HWI_SNAPSHOT_JSON="$HWI_WORK/snapshot.json"
  HWI_COMMAND_PATH="$PATH"
  HWI_REAL_GIT="$(command -v git)"
  HWI_REAL_MV="$(command -v mv)"
  HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE"
  mkdir -p "$HWI_STATE" "$HWI_STUB"
  export HWI_WORK HWI_STATE HWI_STUB HWI_PANE_JSON HWI_SNAPSHOT_JSON HWI_COMMAND_PATH HWI_REAL_GIT HWI_REAL_MV
  export HERDR_WORKTREE_IDENTITY_STATE_DIR
  cat > "$HWI_STUB/herdr" <<'SH'
#!/usr/bin/env bash
if [ "$1" = pane ] && [ "$2" = get ]; then
  printf '%s\n' "$*" >> "$HWI_WORK/herdr.calls"
  [ ! -e "$HWI_WORK/fail-pane-get" ] || exit 1
  if [ -e "$HWI_WORK/block-pane-get-with-descendant" ]; then
    bash -c 'trap "" TERM; printf "%s\n" "$$" > "$HWI_WORK/pane-child.pid"; while :; do sleep 1; done' &
    trap 'exit 0' TERM
    : > "$HWI_WORK/pane-get.ready"
    wait
  fi
  if [ -e "$HWI_WORK/block-pane-get" ]; then
    : > "$HWI_WORK/pane-get.ready"
    while [ ! -e "$HWI_WORK/pane-get.release" ]; do sleep 0.01; done
  fi
  cat "$HWI_PANE_JSON"
  exit 0
fi
if [ "$1" = api ] && [ "$2" = snapshot ]; then
  [ ! -e "$HWI_WORK/fail-snapshot" ] || exit 1
  cat "$HWI_SNAPSHOT_JSON"
  exit 0
fi
if [ "$1" = workspace ] && [ "$2" = rename ]; then
  printf '%s\n' "$*" >> "$HWI_WORK/herdr.calls"
  [ ! -e "$HWI_WORK/fail-workspace-rename" ] || exit 1
  printf '%s' "$4" > "$HWI_WORK/workspace.label"
  if [ -e "$HWI_WORK/commit-then-block-workspace-rename" ]; then
    : > "$HWI_WORK/workspace-rename.ready"
    while [ ! -e "$HWI_WORK/workspace-rename.release" ]; do sleep 0.01; done
  fi
  exit 0
fi
if [ "$1" = workspace ] && [ "$2" = get ]; then
  label="$(cat "$HWI_WORK/workspace.label" 2>/dev/null)"
  jq -cn --arg workspace "$3" --arg label "$label" \
    '{result:{type:"workspace_info",workspace:{workspace_id:$workspace,label:$label}}}'
  exit 0
fi
exit 1
SH
  chmod +x "$HWI_STUB/herdr"
}

hwi_write_pane() {
  local pane="$1" agent="$2" session="$3" workspace="$4" cwd="$5"
  jq -cn --arg pane "$pane" --arg agent "$agent" --arg session "$session" \
    --arg workspace "$workspace" --arg cwd "$cwd" \
    '{result:{pane:{pane_id:$pane,agent:$agent,agent_session:{value:$session},workspace_id:$workspace,cwd:$cwd}}}' \
    > "$HWI_PANE_JSON"
}

hwi_write_snapshot_without_match() {
  printf '%s\n' '{"result":{"snapshot":{"panes":[]}}}' > "$HWI_SNAPSHOT_JSON"
}

hwi_write_snapshot_from_pane() {
  jq '{result:{snapshot:{panes:[.result.pane]}}}' "$HWI_PANE_JSON" > "$HWI_SNAPSHOT_JSON"
}

# Build a linked worktree and invoke the production plugin path that creates
# the authorization marker. Tests must not synthesize that marker themselves.
hwi_create_generated_worktree() {
  local root="$HWI_WORK/repository" main="$HWI_WORK/repository/main"
  HWI_MAIN="$main"
  HWI_CHECKOUT="$root/generated"
  HWI_BRANCH="worktree/quiet-stone-fd75"
  HWI_PLUGIN_CONFIG="$HWI_WORK/plugin-config"
  mkdir -p "$main" "$HWI_PLUGIN_CONFIG"
  git -C "$main" init --quiet -b main
  git -C "$main" config user.email test@example.com
  git -C "$main" config user.name 'Test User'
  printf '%s\n' tracked > "$main/tracked"
  git -C "$main" add tracked
  git -C "$main" commit --quiet -m initial
  git -C "$main" remote add origin https://github.com/example/repository.git
  git -C "$main" worktree add --quiet -b "$HWI_BRANCH" "$HWI_CHECKOUT"
  cat > "$HWI_PLUGIN_CONFIG/config.toml" <<'TOML'
[projects."github.com/example/repository"]
fresh-base = false
TOML
  HERDR_PLUGIN_CONFIG_DIR="$HWI_PLUGIN_CONFIG" \
    HERDR_PLUGIN_EVENT_JSON="{\"data\":{\"worktree\":{\"path\":\"$HWI_CHECKOUT\",\"branch\":\"$HWI_BRANCH\"}}}" \
    bun "$HWI_WORKTREE_SETUP_PLUGIN" >/dev/null
  export HWI_MAIN HWI_CHECKOUT HWI_BRANCH HWI_PLUGIN_CONFIG
}

hwi_identity_state_path() {
  local root common
  root="$(git -C "$HWI_CHECKOUT" rev-parse --show-toplevel)" || return 1
  common="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-common-dir)" || return 1
  printf '%s/repositories/%s/worktrees/%s.state' "$HWI_STATE" \
    "$(printf '%s' "$common" | base64 | tr '/+' '_-' | tr -d '=\n')" \
    "$(printf '%s' "$root" | base64 | tr '/+' '_-' | tr -d '=\n')"
}

hwi_branch_description() {
  local branch="${1:-$(git -C "$HWI_CHECKOUT" branch --show-current)}"
  git -C "$HWI_CHECKOUT" config --get "branch.$branch.description"
}

hwi_workspace_rename_count() {
  [ -f "$HWI_WORK/herdr.calls" ] || { printf '0'; return 0; }
  grep -c '^workspace rename ' "$HWI_WORK/herdr.calls" || true
}

hwi_set_upstream() {
  git -C "$HWI_MAIN" update-ref refs/remotes/origin/main HEAD
  git -C "$HWI_CHECKOUT" branch --set-upstream-to=origin/main "$HWI_BRANCH"
}

hwi_add_remote_tracking_branch() {
  git -C "$HWI_MAIN" update-ref "refs/remotes/origin/$1" HEAD
}

hwi_write_git_proxy() {
  cat > "$HWI_STUB/git" <<'SH'
#!/usr/bin/env bash
args=" $* "
if [ -e "$HWI_WORK/fail-git-branch-m" ] && [[ "$args" == *' branch -m '* ]]; then
  exit 1
fi
if [ -e "$HWI_WORK/fail-git-description" ] && [[ "$args" == *' config '* ]] && [[ "$args" == *'.description '* ]]; then
  exit 1
fi
exec "$HWI_REAL_GIT" "$@"
SH
  chmod +x "$HWI_STUB/git"
}

hwi_write_mv_proxy() {
  cat > "$HWI_STUB/mv" <<'SH'
#!/usr/bin/env bash
if [ -e "$HWI_WORK/fail-terminal-state-write" ] && [ -e "$HWI_WORK/workspace.label" ] && [[ "${2:-}" == *.state ]]; then
  exit 1
fi
exec "$HWI_REAL_MV" "$@"
SH
  chmod +x "$HWI_STUB/mv"
}

# A separate Bash process holds a real claim until the caller releases it.
# The ready marker is a causal barrier; the bounded loop below is only a hang
# guard, never the assertion about contention.
hwi_start_claim_holder() {
  local lock="$1" attempt=0
  HWI_HOLDER_READY="$HWI_WORK/claim-holder.ready"
  HWI_HOLDER_RELEASE="$HWI_WORK/claim-holder.release"
  HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" bash -c '
    source "$1"
    acquire_claim "$2" 1 || exit 1
    printf "%s\\n" "$claim_owner_id" > "$3"
    while [ ! -e "$4" ]; do sleep 0.01; done
    release_claim "$2" "$claim_owner_id"
  ' _ "$HWI_STATE_LIBRARY" "$lock" "$HWI_HOLDER_READY" "$HWI_HOLDER_RELEASE" &
  HWI_HOLDER_PID=$!
  while [[ ! -e "$HWI_HOLDER_READY" && "$attempt" -lt 3000 ]]; do
    if ! kill -0 "$HWI_HOLDER_PID" 2>/dev/null; then
      wait "$HWI_HOLDER_PID" 2>/dev/null || true
      return 1
    fi
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [[ -e "$HWI_HOLDER_READY" ]] || return 1
}

hwi_teardown() {
  if [[ -n "${HWI_HOLDER_PID:-}" ]]; then
    [[ -z "${HWI_HOLDER_RELEASE:-}" ]] || : > "$HWI_HOLDER_RELEASE" 2>/dev/null || true
    kill "$HWI_HOLDER_PID" 2>/dev/null || true
    wait "$HWI_HOLDER_PID" 2>/dev/null || true
  fi
  [[ -n "${HWI_WORK:-}" ]] && rm -rf "$HWI_WORK" || true
  unset HWI_WORK HWI_STATE HWI_STUB HWI_PANE_JSON HWI_SNAPSHOT_JSON HWI_COMMAND_PATH HWI_REAL_GIT HWI_REAL_MV HWI_MAIN
  unset HWI_CHECKOUT HWI_BRANCH HWI_PLUGIN_CONFIG HWI_HOLDER_PID HWI_HOLDER_READY HWI_HOLDER_RELEASE
  unset HERDR_WORKTREE_IDENTITY_STATE_DIR
}
