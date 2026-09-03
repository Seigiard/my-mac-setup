# Herdr worktree-identity harness. Load after helpers/common.

HWI_STATE_LIBRARY="$SOURCE_ROOT/dot_local/lib/herdr-worktree-state.sh"
export HWI_STATE_LIBRARY

hwi_setup() {
  HWI_WORK="$(mktemp -d "${BATS_TMPDIR:-/tmp}/hwi.XXXXXX")"
  HWI_STATE="$HWI_WORK/state"
  HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE"
  mkdir -p "$HWI_STATE"
  export HWI_WORK HWI_STATE HERDR_WORKTREE_IDENTITY_STATE_DIR
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
  unset HWI_WORK HWI_STATE HWI_HOLDER_PID HWI_HOLDER_READY HWI_HOLDER_RELEASE
  unset HERDR_WORKTREE_IDENTITY_STATE_DIR
}
