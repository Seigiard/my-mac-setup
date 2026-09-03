#!/usr/bin/env bash
# post-apply: 20 host-safe
# scripts post-apply suite — bashunit source. Vocabulary (run, assert_*,
# skip, BATS_* contract) comes from tests/bashunit/test-dsl.bash.
# Migrated from scripts.bats; parity evidence: docs/benchmarks/bashunit-full-suite-experiment.md.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/common'
load 'helpers/herdr_pane_labels'
load 'helpers/herdr_worktree_identity'

setup() {
  unset HERDR_CHILD_NAME
  unset HERDR_CHILD_PARENT_PANE
  unset HERDR_CHILD_STATE_DIR
  unset HERDR_WORKSPACE_ID
  unset HERDR_CHILD_MAX_DELIVERY_RETRIES
  unset HERDR_CHILD_TEST_RETRY_LOG
  unset HERDR_CHILD_TEST_FAILURE_PUBLISH_BARRIER
  unset HERDR_CHILD_TEST_CALLBACK_RECEIPT_BARRIER
  unset HERDR_CHILD_TEST_REAP_INVALIDATED_BARRIER
  unset HERDR_CHILD_TEST_REAP_OWNER_VERIFIED
  unset HERDR_CHILD_TEST_NOW_SEQ
  unset HERDR_CHILD_TEST_TAKEOVER_METADATA_PUBLISHED
  unset CHILD_REAP_PID
}

teardown() {
  hpl_teardown
  hwi_teardown
  if [[ -n "${CHILD_STUB:-}" ]]; then
    if [[ -e "$CHILD_STUB/reap-invalidated.ready" ]]; then
      : > "$CHILD_STUB/reap-invalidated.release"
    fi
    if [[ -n "${CHILD_REAP_PID:-}" ]]; then
      local reap_attempt=0
      while kill -0 "$CHILD_REAP_PID" 2>/dev/null && [[ "$reap_attempt" -lt 100 ]]; do
        reap_attempt=$((reap_attempt + 1))
        sleep 0.01
      done
      if kill -0 "$CHILD_REAP_PID" 2>/dev/null; then
        kill -TERM "$CHILD_REAP_PID" 2>/dev/null || true
      fi
      wait "$CHILD_REAP_PID" 2>/dev/null || true
      CHILD_REAP_PID=""
    fi
    [[ ! -e "$CHILD_STUB/release-watcher" ]] || true
    : > "$CHILD_STUB/release-watcher" 2>/dev/null || true
    local pid_file watcher_pid
    for pid_file in watcher.pid new-watcher.pid reply.pid; do
      [[ -s "$CHILD_STUB/$pid_file" ]] || continue
      watcher_pid="$(cat "$CHILD_STUB/$pid_file" 2>/dev/null || true)"
      if [[ -n "$watcher_pid" ]]; then
        kill -TERM "$watcher_pid" 2>/dev/null || true
        local attempt=0
        while kill -0 "$watcher_pid" 2>/dev/null && [[ "$attempt" -lt 100 ]]; do
          attempt=$((attempt + 1))
          sleep 0.01
        done
        # A watcher that survives TERM (e.g., stuck publishing through a
        # deleted stub) must not outlive the test (docs/issues/2026-08-28-001).
        if kill -0 "$watcher_pid" 2>/dev/null; then
          kill -KILL "$watcher_pid" 2>/dev/null || true
        fi
      fi
    done
  fi
  [[ -n "${BATS_TEST_TMPFILE:-}" ]] && rm -f "$BATS_TEST_TMPFILE" || true
  [[ -n "${CHILD_STUB:-}" ]] && rm -rf "$CHILD_STUB" || true
}

# ===========================================
# herdr-worktree-identity state library
# ===========================================

function test_scripts_1134_worktree_identity_state_library_claims_live_owners_and_recovers_dead_owners() {
  _bats_test_init 1134 'worktree identity claims live owners and recovers dead owners'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  local lock="$HWI_STATE/repositories/test/identity.claim" owner

  hwi_start_claim_holder "$lock" || fail 'second process did not acquire its claim'
  run acquire_claim "$lock" 3
  assert_failure 2
  run kill -0 "$HWI_HOLDER_PID"
  assert_success

  kill -KILL "$HWI_HOLDER_PID"
  wait "$HWI_HOLDER_PID" 2>/dev/null || true
  HWI_HOLDER_PID=""
  acquire_claim "$lock" 3 || fail 'dead owner claim was not recovered'
  owner="$claim_owner_id"
  release_claim "$lock" "$owner"
  assert_dir_not_exists "$lock"
}

function test_scripts_1135_worktree_identity_state_library_recovers_malformed_claims_and_distinguishes_errors() {
  _bats_test_init 1135 'worktree identity recovers malformed claims and distinguishes contention from errors'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  local malformed="$HWI_STATE/malformed.claim" held="$HWI_STATE/held.claim"
  mkdir -p "$malformed"
  atomic_write "$malformed/owner" "owner_id=$(encode_value malformed-owner)
pid=$$
process_start=$(encode_value '')"

  acquire_claim "$malformed" 3 || fail 'empty process-start claim was not recovered'
  release_claim "$malformed" "$claim_owner_id"

  hwi_start_claim_holder "$held" || fail 'second process did not acquire its claim'
  run acquire_claim "$held" 1
  assert_failure 2
  : > "$HWI_WORK/not-a-directory"
  run acquire_claim "$HWI_WORK/not-a-directory" 1
  assert_failure 1
}

function test_scripts_1136_worktree_identity_state_library_appends_diagnostics_and_preserves_preexisting_records() {
  _bats_test_init 1136 'worktree identity diagnostics append and failed pre-rename writes preserve records'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  local diagnostics="$HWI_STATE/worktree/diagnostics.log" record="$HWI_STATE/worktree/state"
  local stub="$HWI_WORK/stub"

  record_diagnostic "$diagnostics" marker-missing 'checkout=/tmp/first'
  record_diagnostic "$diagnostics" contended 'claim=repository'
  assert_file_contains "$diagnostics" '^reason=marker-missing observed_state=checkout=/tmp/first$'
  assert_file_contains "$diagnostics" '^reason=contended observed_state=claim=repository$'
  assert_equal "$(wc -l < "$diagnostics" | tr -d ' ')" 2

  atomic_write "$record" previous
  mkdir -p "$stub"
  cat > "$stub/mv" <<'SH'
#!/bin/sh
exit 1
SH
  chmod +x "$stub/mv"
  run env PATH="$stub:/usr/bin:/bin" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash -c 'source "$1"; atomic_write "$2" replacement' _ "$HWI_STATE_LIBRARY" "$record"
  assert_failure
  assert_file_contains "$record" '^previous$'
  run find "$(dirname "$record")" -name '.record.*' -print
  assert_success
  assert_output ''
}

# ===========================================
# herdr-worktree-identity engine (U2)
# ===========================================

function test_scripts_1137_worktree_identity_authorizes_a_real_plugin_marker_and_reentry_after_rename() {
  _bats_test_init 1137 'worktree identity authorizes the plugin marker after a real branch rename'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'name this task'
  assert_success
  local state marker
  state="$(hwi_identity_state_path)"
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  assert_file_contains "$marker" "^$HWI_BRANCH$"
  assert_equal "$(read_state_field "$state" original_branch)" "$HWI_BRANCH"
  assert_equal "$(read_state_field "$state" authorization)" authorized

  git -C "$HWI_CHECKOUT" branch -m task-derived-name
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'name this task again'
  assert_success
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" task-derived-name
  assert_equal "$(read_state_field "$state" original_branch)" "$HWI_BRANCH"
  assert_equal "$(read_state_field "$state" authorization)" authorized
}

function test_scripts_1138_worktree_identity_declines_missing_or_mismatched_markers_without_ref_mutation() {
  _bats_test_init 1138 'worktree identity declines absent and mismatched generated-worktree markers'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  local marker before state diagnostics
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  rm "$marker"
  before="$(git -C "$HWI_CHECKOUT" branch --show-current)"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'missing marker'
  assert_success
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$before"
  state="$(hwi_identity_state_path)"
  diagnostics="${state%.state}.diagnostics.log"
  assert_equal "$(read_state_field "$state" outcome)" declined
  assert_file_contains "$diagnostics" 'reason=marker-missing .*checkout='

  printf '%s\n' different-branch > "$marker"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'mismatched marker'
  assert_success
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$before"
  assert_file_contains "$diagnostics" 'reason=marker-mismatched .*marker_branch=different-branch'
}

function test_scripts_1139_worktree_identity_keeps_unresolved_events_retryable_and_prefers_reported_cwd() {
  _bats_test_init 1139 'worktree identity records unresolved pane reads and prefers reported working directories'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  : > "$HWI_WORK/fail-pane-get"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'retry later'
  assert_success
  local unresolved="$HWI_STATE/sessions/$(printf '%s' session-1 | base64 | tr '/+' '_-' | tr -d '=\n').state"
  assert_equal "$(read_state_field "$unresolved" outcome)" unresolved
  assert_file_contains "${unresolved%.state}.diagnostics.log" 'reason=pane-unreachable'

  rm "$HWI_WORK/fail-pane-get"
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_MAIN"
  mkdir -p "$HWI_STATE/agent-cwd"
  printf '%s\n' "$HWI_CHECKOUT" > "$HWI_STATE/agent-cwd/$(printf '%s' session-1 | base64 | tr '/+' '_-' | tr -d '=\n')"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'retry now'
  assert_success
  local state="$(hwi_identity_state_path)"
  assert_equal "$(read_state_field "$state" checkout_root)" "$(git -C "$HWI_CHECKOUT" rev-parse --show-toplevel)"
  assert_equal "$(read_state_field "$state" authorization)" authorized
}

function test_scripts_1140_worktree_identity_declines_primary_checkouts_and_unmatched_sessions() {
  _bats_test_init 1140 'worktree identity declines primary checkouts and records unmatched sessions as unresolved'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_MAIN"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'primary checkout'
  assert_success
  local state="$HWI_STATE/sessions/$(printf '%s' session-1 | base64 | tr '/+' '_-' | tr -d '=\n').state"
  assert_equal "$(read_state_field "$state" outcome)" declined
  assert_file_contains "${state%.state}.diagnostics.log" 'reason=primary-checkout .*checkout='

  hwi_write_snapshot_without_match
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-2 --workspace workspace-1 <<< 'no pane for this session'
  assert_success
  state="$HWI_STATE/sessions/$(printf '%s' session-2 | base64 | tr '/+' '_-' | tr -d '=\n').state"
  assert_equal "$(read_state_field "$state" outcome)" unresolved
  assert_file_contains "${state%.state}.diagnostics.log" 'reason=pane-unresolved .*pane=missing'

  hwi_write_pane pane-2 codex session-3 workspace-1 "$HWI_CHECKOUT"
  hwi_write_snapshot_from_pane
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-3 --workspace workspace-1 <<< 'resolve from snapshot'
  assert_success
  assert_equal "$(read_state_field "$(hwi_identity_state_path)" authorization)" authorized
}

function test_scripts_1141_worktree_identity_foreground_hands_off_to_a_detached_worker() {
  _bats_test_init 1141 'worktree identity foreground hands prompt processing to a detached worker'
  hwi_setup
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  : > "$HWI_WORK/block-pane-get"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'do not place this prompt on argv'
  assert_success
  local attempt=0
  while [[ ! -e "$HWI_WORK/pane-get.ready" && "$attempt" -lt 3000 ]]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$HWI_WORK/pane-get.ready"
  assert_file_not_contains "$HWI_WORK/herdr.calls" 'do not place this prompt on argv'
  : > "$HWI_WORK/pane-get.release"
}

# ===========================================
# python3 -- the declared interpreter
# ===========================================

# First, so a missing or too-old interpreter states its own cause instead of
# leaving the bare `python3` call sites below to fail without naming it.
function test_scripts_001_python3_is_present_and_at_least_3_9_the_floor_re() {
  _bats_test_init 1 'python3 is present and at least 3.9, the floor README.md declares'
  run assert_python3_available
  assert_success
}

# ===========================================
# Repository linting
# ===========================================

# Writes a shellcheck stub that appends its argv to $2 and exits with $3, so a
# test can tell "make lint failed because shellcheck failed" apart from "make
# lint failed for some other reason".
write_shellcheck_stub() {
  local dir="$1" log="$2" code="$3"
  cat > "$dir/shellcheck" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$log"
exit $code
STUB
  chmod +x "$dir/shellcheck"
}

function test_scripts_002_lint_target_propagates_shellcheck_failures() {
  _bats_test_init 2 'lint target propagates shellcheck failures'
  local repo_root="$BATS_TEST_DIRNAME/.."
  [[ -f "$repo_root/Makefile" ]] || skip "repo-root Makefile is not available in this environment"

  # `make lint` runs three shellcheck sweeps plus a python checker, so a bare
  # assert_failure is also satisfied by a broken Makefile or a failing python
  # step -- neither of which is this test's subject. The stub records that it
  # was reached, and the exit-0 leg is the control proving the target reaches
  # success when shellcheck is happy, so a `|| true` on the shellcheck lines
  # cannot keep both legs green.
  local stubdir="$BATS_TEST_TMPDIR/lint-stub"
  local invocations="$BATS_TEST_TMPDIR/shellcheck.invocations"
  mkdir -p "$stubdir"

  write_shellcheck_stub "$stubdir" "$invocations" 1
  run env PATH="$stubdir:$PATH" make -C "$repo_root" lint
  assert_failure
  assert_file_exists "$invocations"

  write_shellcheck_stub "$stubdir" "$invocations" 0
  run env PATH="$stubdir:$PATH" make -C "$repo_root" lint
  assert_success
}

# Herdr alias allocator
# ===========================================

HERDR_ALIASES="$SOURCE_ROOT/dot_local/lib/herdr-aliases.sh"

function test_scripts_1001_herdr_alias_library_parses_and_exposes_its_source_api() {
  _bats_test_init 1001 'herdr alias library parses and exposes its source API'
  run bash -n "$HERDR_ALIASES"
  assert_success

  run bash -c '
    source "$1"
    declare -F herdr_alias_is_valid >/dev/null
    declare -F herdr_alias_in_pool >/dev/null
    declare -F herdr_alias_validate_pool >/dev/null
    declare -F herdr_alias_candidates >/dev/null
  ' _ "$HERDR_ALIASES"
  assert_success
}

function test_scripts_1002_herdr_alias_grammar_validation_is_separate_from_exact_p() {
  _bats_test_init 1002 'herdr alias grammar validation is separate from exact pool membership'
  source "$HERDR_ALIASES"

  run herdr_alias_is_valid red-wolf
  assert_success
  run herdr_alias_in_pool red-wolf
  assert_success

  run herdr_alias_is_valid chartreuse-wombat
  assert_success
  run herdr_alias_in_pool chartreuse-wombat
  assert_failure

  local alias
  for alias in Red-wolf red_wolf red-wolf-extra red- 'abcdefghijklmnopqrstuvwxyzabcdefg-wolf'; do
    run herdr_alias_is_valid "$alias"
    assert_failure
    run herdr_alias_in_pool "$alias"
    assert_failure
  done
}

function test_scripts_1003_herdr_alias_pool_has_at_least_1024_unique_grammar_safe_() {
  _bats_test_init 1003 'herdr alias pool has at least 1024 unique grammar-safe candidates'
  source "$HERDR_ALIASES"
  run herdr_alias_validate_pool
  assert_success

  local aliases="$BATS_TEST_TMPDIR/herdr-alias-pool"
  local color animal alias
  local pool_size=$((${#HERDR_ALIAS_COLORS[@]} * ${#HERDR_ALIAS_ANIMALS[@]}))
  [ "$pool_size" -ge 1024 ]

  : > "$aliases"
  for color in "${HERDR_ALIAS_COLORS[@]}"; do
    [[ "$color" =~ ^[a-z]+$ ]] || fail "invalid color word: $color"
    for animal in "${HERDR_ALIAS_ANIMALS[@]}"; do
      [[ "$animal" =~ ^[a-z]+$ ]] || fail "invalid animal word: $animal"
      alias="$color-$animal"
      [[ "$alias" =~ ^[a-z]+-[a-z]+$ ]] || fail "invalid alias grammar: $alias"
      [ "${#alias}" -le 32 ] || fail "alias exceeds 32 characters: $alias"
      printf '%s\n' "$alias" >> "$aliases"
    done
  done

  local unique_count
  unique_count="$(LC_ALL=C sort -u "$aliases" | wc -l | tr -d ' ')"
  assert_equal "$unique_count" "$pool_size"
}

function test_scripts_1004_herdr_alias_fixed_test_seed_produces_one_stable_full_se() {
  _bats_test_init 1004 'herdr alias fixed test seed produces one stable full sequence without state'
  source "$HERDR_ALIASES"
  local first_sequence="$BATS_TEST_TMPDIR/herdr-alias-sequence-1"
  local second_sequence="$BATS_TEST_TMPDIR/herdr-alias-sequence-2"
  local state_home="$BATS_TEST_TMPDIR/herdr-alias-home"
  mkdir -p "$state_home"

  HOME="$state_home" HERDR_ALIAS_TEST_SEED=u1-fixed-seed \
    herdr_alias_candidates ignored-first-seed > "$first_sequence"
  HOME="$state_home" HERDR_ALIAS_TEST_SEED=u1-fixed-seed \
    herdr_alias_candidates ignored-second-seed > "$second_sequence"

  run cmp "$first_sequence" "$second_sequence"
  assert_success
  local pool_size=$((${#HERDR_ALIAS_COLORS[@]} * ${#HERDR_ALIAS_ANIMALS[@]}))
  local sequence_count unique_count
  sequence_count="$(wc -l < "$first_sequence" | tr -d ' ')"
  unique_count="$(LC_ALL=C sort -u "$first_sequence" | wc -l | tr -d ' ')"
  assert_equal "$sequence_count" "$pool_size"
  assert_equal "$unique_count" "$pool_size"

  local checksum_line checksum offset expected first
  checksum_line="$(printf '%s' u1-fixed-seed | cksum)"
  checksum="${checksum_line%%[[:space:]]*}"
  offset=$((checksum % pool_size))
  expected="${HERDR_ALIAS_COLORS[$((offset / ${#HERDR_ALIAS_ANIMALS[@]}))]}-${HERDR_ALIAS_ANIMALS[$((offset % ${#HERDR_ALIAS_ANIMALS[@]}))]}"
  IFS= read -r first < "$first_sequence"
  assert_equal "$first" "$expected"

  run find "$state_home" -mindepth 1 -print
  assert_success
  assert_output ""
}

function test_scripts_1005_herdr_alias_traversal_wraps_to_the_last_free_candidate_() {
  _bats_test_init 1005 'herdr alias traversal wraps to the last free candidate and exhausts once'
  source "$HERDR_ALIASES"
  local sequence="$BATS_TEST_TMPDIR/herdr-alias-wrap-sequence"
  local seed=u1-wraparound-seed
  herdr_alias_candidates "$seed" > "$sequence"

  local pool_size=$((${#HERDR_ALIAS_COLORS[@]} * ${#HERDR_ALIAS_ANIMALS[@]}))
  local checksum_line checksum offset final_index expected_final
  checksum_line="$(printf '%s' "$seed" | cksum)"
  checksum="${checksum_line%%[[:space:]]*}"
  offset=$((checksum % pool_size))
  [ "$offset" -gt 0 ]
  final_index=$((offset - 1))
  expected_final="${HERDR_ALIAS_COLORS[$((final_index / ${#HERDR_ALIAS_ANIMALS[@]}))]}-${HERDR_ALIAS_ANIMALS[$((final_index % ${#HERDR_ALIAS_ANIMALS[@]}))]}"

  local candidate selected="" last="" visited=0
  while IFS= read -r candidate; do
    visited=$((visited + 1))
    last="$candidate"
    # The consumer treats every earlier candidate as occupied.
    if [ "$candidate" = "$expected_final" ]; then
      selected="$candidate"
      break
    fi
  done < "$sequence"
  assert_equal "$visited" "$pool_size"
  assert_equal "$selected" "$expected_final"
  assert_equal "$last" "$expected_final"

  selected=""
  visited=0
  while IFS= read -r candidate; do
    visited=$((visited + 1))
    # Every candidate is occupied, so no selection is made.
  done < "$sequence"
  assert_equal "$visited" "$pool_size"
  assert_equal "$selected" ""
}

function test_scripts_1006_herdr_alias_allocation_consults_no_herdr_model_or_netwo() {
  _bats_test_init 1006 'herdr alias allocation consults no Herdr model or network command'
  local stub_dir="$BATS_TEST_TMPDIR/herdr-alias-stubs"
  local call_log="$BATS_TEST_TMPDIR/herdr-alias-calls"
  local binary
  mkdir -p "$stub_dir"
  for binary in herdr claude opencode pi codex curl wget; do
    cat > "$stub_dir/$binary" <<'SH'
#!/bin/sh
printf '%s\n' "${0##*/}" >> "$HERDR_ALIAS_CALL_LOG"
exit 97
SH
    chmod +x "$stub_dir/$binary"
  done

  run env PATH="$stub_dir:$PATH" HERDR_ALIAS_CALL_LOG="$call_log" \
    HERDR_ALIAS_TEST_SEED=u1-no-services \
    bash -c 'source "$1"; herdr_alias_candidates ignored >/dev/null' _ "$HERDR_ALIASES"
  assert_success
  [ ! -e "$call_log" ]
}

# ===========================================

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

function test_scripts_003_ci_minimal_linux_render_skips_homebrew_but_keeps() {
  _bats_test_init 3 'CI-minimal Linux render skips Homebrew but keeps the remaining setup'
  skip_if_no_chezmoi
  local cfg="$BATS_TEST_TMPDIR/minimal-linux.yaml"
  MMS_CI_MINIMAL=1 write_test_config "$cfg"
  sed -i.bak 's/^  is_linux: .*/  is_linux: true/' "$cfg"

  run render_install_packages "$cfg"
  assert_success
  # Progress banners ("Installing Oh My Zsh...") are prose nothing consumes: a
  # reworded echo reddens the test while the install still runs, and deleting
  # the install while keeping the echo stays green. The upstream installer URLs
  # below are third-party constants this repo does not define, so they move
  # only when the install itself moves.
  refute_output --partial 'Homebrew/install/HEAD/install.sh'
  refute_output --partial 'brew bundle --file='
  assert_output --partial 'ohmyzsh/ohmyzsh/master/tools/install.sh'
  assert_output --partial 'fff.nvim/main/install-mcp.sh'
}

function test_scripts_004_full_linux_render_keeps_homebrew_package_install() {
  _bats_test_init 4 'full Linux render keeps Homebrew package installation'
  skip_if_no_chezmoi
  local cfg="$BATS_TEST_TMPDIR/full-linux.yaml"
  MMS_CI_MINIMAL="" write_test_config "$cfg"
  sed -i.bak 's/^  is_linux: .*/  is_linux: true/' "$cfg"

  run render_install_packages "$cfg"
  assert_success
  assert_output --partial 'Homebrew/install/HEAD/install.sh'
  assert_output --partial 'brew bundle --file="$BREWFILES_DIR/Brewfile"'
}

function test_scripts_005_ci_minimal_non_linux_render_keeps_homebrew_packa() {
  _bats_test_init 5 'CI-minimal non-Linux render keeps Homebrew package installation'
  skip_if_no_chezmoi
  local cfg="$BATS_TEST_TMPDIR/minimal-non-linux.yaml"
  MMS_CI_MINIMAL=1 write_test_config "$cfg"
  sed -i.bak 's/^  is_linux: .*/  is_linux: false/' "$cfg"

  run render_install_packages "$cfg"
  assert_success
  assert_output --partial 'Homebrew/install/HEAD/install.sh'
  assert_output --partial 'brew bundle --file="$BREWFILES_DIR/Brewfile"'
}

function test_scripts_006_install_packages_script_renders_as_valid_bash() {
  _bats_test_init 6 'install-packages script renders as valid bash'
  skip_if_no_chezmoi
  BATS_TEST_TMPFILE="$BATS_TEST_TMPDIR/install-packages.sh"
  render_install_packages > "$BATS_TEST_TMPFILE"
  run bash -n "$BATS_TEST_TMPFILE"
  assert_success
}

# ===========================================
# macOS tunes script
# ===========================================

function test_scripts_007_macos_tunes_script_is_valid_bash() {
  _bats_test_init 7 'macos-tunes script is valid bash'
  local script="$SOURCE_ROOT/.chezmoiscripts/darwin/run_once_after_macos-tunes.sh"
  run bash -n "$script"
  assert_success
}

function test_scripts_008_darwin_scripts_excluded_from_managed_list_on_lin() {
  _bats_test_init 8 'darwin scripts excluded from managed list on Linux'
  is_linux || skip "Only relevant on Linux"
  skip_if_no_chezmoi
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" managed
  # A failed `chezmoi managed` emits an error string that would satisfy the
  # refutation, so status and a known-managed line come first.
  assert_success
  assert_output --partial ".gitconfig"
  refute_output --partial "run_once_after_macos-tunes"
}

function test_scripts_0081_retired_se_cleanup_migration_preserves_an_independent_skill() {
  _bats_test_init 81 'retired se-cleanup migration preserves an independently owned skill'
  local script="$SOURCE_ROOT/.chezmoiscripts/run_once_after_remove-retired-se-cleanup.sh"
  local agents="$BATS_TEST_TMPDIR/home/.agents/skills/se-cleanup"
  local claude="$BATS_TEST_TMPDIR/home/.claude/skills/se-cleanup"
  local orphan_home="$BATS_TEST_TMPDIR/orphan-home"
  mkdir -p "$agents" "$claude"
  printf '%s\n' 'independently managed skill' > "$agents/SKILL.md"
  printf '%s\n' 'user-owned content' > "$agents/notes.md"
  ln -s "$agents/SKILL.md" "$claude/SKILL.md"

  run env HOME="$BATS_TEST_TMPDIR/home" sh "$script"
  assert_success
  assert_file_contains "$agents/SKILL.md" '^independently managed skill$'
  assert_file_exists "$agents/notes.md"
  assert_dir_exists "$agents"
  assert_file_exists "$claude/SKILL.md"

  mkdir -p "$orphan_home/.claude/skills/se-cleanup"
  ln -s ../../../.agents/skills/se-cleanup/SKILL.md \
    "$orphan_home/.claude/skills/se-cleanup/SKILL.md"
  run env HOME="$orphan_home" sh "$script"
  assert_success
  assert_dir_not_exists "$orphan_home/.claude/skills/se-cleanup"
}

function test_scripts_0082_worktree_setup_uses_one_repository_keyed_config() {
  _bats_test_init 82 'worktree setup uses one repository-keyed config for copy and setup steps'
  local plugin="$SOURCE_ROOT/private_dot_config/herdr/plugins/worktree-setup/setup.ts"
  local root="$BATS_TEST_TMPDIR/worktree-setup" main worktree config marker
  main="$root/main"
  worktree="$root/feature"
  config="$root/config"
  mkdir -p "$main" "$config"
  git -C "$main" init --quiet -b main
  git -C "$main" config user.email test@example.com
  git -C "$main" config user.name 'Test User'
  printf '%s\n' tracked > "$main/tracked"
  printf '%s\n' secret > "$main/.env"
  git -C "$main" add tracked
  git -C "$main" commit --quiet -m initial
  git -C "$main" remote add origin git@github.com:membranehq/platform.git
  git -C "$main" worktree add --quiet -b feature "$worktree"
  cat > "$config/config.toml" <<'TOML'
[projects."github.com/membranehq/platform"]
fresh-base = false
copy = [".env"]
steps = ["printf '%s' \"$HERDR_BRANCH\" > setup-ran"]
TOML

  run env HERDR_PLUGIN_CONFIG_DIR="$config" \
    HERDR_PLUGIN_EVENT_JSON="{\"data\":{\"worktree\":{\"path\":\"$worktree\",\"branch\":\"feature\"}}}" \
    bun "$plugin"
  assert_success
  assert_file_contains "$worktree/.env" '^secret$'
  assert_file_contains "$worktree/setup-ran" '^feature$'
  marker="$(git -C "$worktree" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  assert_file_contains "$marker" '^feature$'
}

function test_scripts_0083_worktree_setup_refreshes_a_new_branch_from_origin_head() {
  _bats_test_init 83 'worktree setup refreshes an untouched new branch from origin HEAD'
  local plugin="$SOURCE_ROOT/private_dot_config/herdr/plugins/worktree-setup/setup.ts"
  local root="$BATS_TEST_TMPDIR/worktree-fresh" origin main worktree dirty config expected old
  origin="$root/origin.git"
  main="$root/main"
  worktree="$root/feature"
  dirty="$root/dirty"
  config="$root/config"
  mkdir -p "$root" "$config"
  git init --quiet --bare "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git init --quiet -b main "$main"
  git -C "$main" config user.email test@example.com
  git -C "$main" config user.name 'Test User'
  printf '%s\n' old > "$main/tracked"
  git -C "$main" add tracked
  git -C "$main" commit --quiet -m old
  git -C "$main" remote add origin "$origin"
  git -C "$main" push --quiet -u origin main
  git -C "$main" worktree add --quiet -b feature "$worktree"
  old="$(git -C "$worktree" rev-parse HEAD)"
  git -C "$main" worktree add --quiet -b dirty "$dirty" "$old"
  printf '%s\n' local > "$dirty/untracked"
  printf '%s\n' new > "$main/tracked"
  git -C "$main" commit --quiet -am new
  git -C "$main" push --quiet
  expected="$(git -C "$main" rev-parse HEAD)"
  cat > "$config/config.toml" <<TOML
[projects."${origin%.git}"]
fresh-base = true
TOML

  run env HERDR_PLUGIN_CONFIG_DIR="$config" \
    HERDR_PLUGIN_EVENT_JSON="{\"data\":{\"worktree\":{\"path\":\"$worktree\",\"branch\":\"feature\"}}}" \
    bun "$plugin"
  assert_success
  run git -C "$worktree" rev-parse HEAD
  assert_success
  assert_output "$expected"

  run env HERDR_PLUGIN_CONFIG_DIR="$config" \
    HERDR_PLUGIN_EVENT_JSON="{\"data\":{\"worktree\":{\"path\":\"$dirty\",\"branch\":\"dirty\"}}}" \
    bun "$plugin"
  assert_success
  run git -C "$dirty" rev-parse HEAD
  assert_success
  assert_output "$old"
}

function test_scripts_0084_retired_worktrunk_migration_removes_only_managed_files() {
  _bats_test_init 84 'retired Worktrunk migration removes only formerly managed files'
  local script="$SOURCE_ROOT/.chezmoiscripts/run_once_after_remove-retired-worktrunk.sh"
  local home="$BATS_TEST_TMPDIR/worktrunk-home"
  mkdir -p \
    "$home/.config/worktrunk" \
    "$home/.config/herdr/plugins/config/worktrunk" \
    "$home/.config/herdr/plugins/command-palette"
  printf '%s\n' old > "$home/.config/worktrunk/config.toml"
  printf '%s\n' old > "$home/.config/herdr/plugins/config/worktrunk/config.toml"
  printf '%s\n' old > "$home/.config/herdr/plugins/command-palette/new_worktree.py"
  printf '%s\n' old > "$home/.config/herdr/plugins/command-palette/open_new_worktree.py"
  printf '%s\n' keep > "$home/.config/worktrunk/user-note"

  run env HOME="$home" sh "$script"
  assert_success
  assert_file_not_exists "$home/.config/worktrunk/config.toml"
  assert_file_not_exists "$home/.config/herdr/plugins/config/worktrunk/config.toml"
  assert_file_not_exists "$home/.config/herdr/plugins/command-palette/new_worktree.py"
  assert_file_not_exists "$home/.config/herdr/plugins/command-palette/open_new_worktree.py"
  assert_file_exists "$home/.config/worktrunk/user-note"
}

function test_scripts_0085_worktree_setup_relink_uses_the_herdr_cli_contract() {
  _bats_test_init 85 'worktree setup relink uses the Herdr CLI contract'
  local script="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_4-link-herdr-worktree-setup.sh.tmpl"
  local home="$BATS_TEST_TMPDIR/worktree-link-home"
  local stub="$BATS_TEST_TMPDIR/worktree-link-bin"
  mkdir -p "$home/.config/herdr/plugins/worktree-setup" "$stub"
  printf '%s\n' 'id = "seigi.worktree-setup"' \
    > "$home/.config/herdr/plugins/worktree-setup/herdr-plugin.toml"
  cat > "$stub/herdr" <<'SH'
#!/bin/sh
expected="$HOME/.config/herdr/plugins/worktree-setup"
if [ "$#" -eq 3 ] && [ "$1" = plugin ] && [ "$2" = link ] && [ "$3" = "$expected" ]; then
  : > "$HOME/plugin-linked"
  exit 0
fi
exit 2
SH
  chmod +x "$stub/herdr"

  run env HOME="$home" PATH="$stub:$PATH" bash "$script"
  assert_success
  assert_file_exists "$home/plugin-linked"
}

# ask-in-herdr skill script
# ===========================================

ASK_HERDR_DIR="$SOURCE_ROOT/private_dot_agents/skills/ask-in-herdr/scripts"
ASK_HERDR_SCRIPT="$ASK_HERDR_DIR/executable_ask.sh"

ask_live_stub() {
  CHILD_STUB="$(mktemp -d)"
  export CHILD_STUB
  cat > "$CHILD_STUB/herdr-child" <<'SH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$CHILD_STUB/child.log"; printf '\n' >> "$CHILD_STUB/child.log"
printf 'child ' >> "$CHILD_STUB/order.log"; printf '%q ' "$@" >> "$CHILD_STUB/order.log"; printf '\n' >> "$CHILD_STUB/order.log"
case "${1:-}" in
  start)
    printf '{"agent":"red-wolf","pane":"wT:p9"}\n'
    [ "${STUB_CHILD_STATUS:-0}" -eq 0 ] || { printf 'child-start-error\n' >&2; exit "$STUB_CHILD_STATUS"; }
    ;;
  verify)
    count=0; [ ! -f "$CHILD_STUB/verify-count" ] || read -r count < "$CHILD_STUB/verify-count"
    count=$((count + 1)); printf '%s\n' "$count" > "$CHILD_STUB/verify-count"
    [ "${STUB_PAIR_FAIL_AT:-0}" -ne "$count" ] || exit 1
    if [ "${STUB_PAIR_TERMINAL_CHANGE_AT:-0}" -eq "$count" ]; then
      printf 'term-replaced\n'
    else
      printf 'term-child\n'
    fi
    ;;
  *) exit 2 ;;
esac
SH
  cat > "$CHILD_STUB/herdr" <<'SH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$CHILD_STUB/herdr.log"; printf '\n' >> "$CHILD_STUB/herdr.log"
printf 'herdr ' >> "$CHILD_STUB/order.log"; printf '%q ' "$@" >> "$CHILD_STUB/order.log"; printf '\n' >> "$CHILD_STUB/order.log"
case "$1 $2" in
  "agent list")
    count=0; [ ! -f "$CHILD_STUB/list-count" ] || read -r count < "$CHILD_STUB/list-count"
    count=$((count + 1)); printf '%s\n' "$count" > "$CHILD_STUB/list-count"
    if [ "${STUB_PAIR_FAIL_AT:-0}" -eq "$count" ]; then
      printf '{"result":{"agents":[{"name":"red-wolf","pane_id":"wT:p8","agent":"claude","terminal_id":"term-other","revision":2,"state_change_seq":2}]}}\n'
    elif [ "${STUB_PAIR_TERMINAL_CHANGE_AT:-0}" -eq "$count" ]; then
      printf '{"result":{"agents":[{"name":"red-wolf","pane_id":"wT:p9","agent":"claude","terminal_id":"term-replaced","revision":2,"state_change_seq":2}]}}\n'
    else
      printf '{"result":{"agents":[{"name":"red-wolf","pane_id":"wT:p9","agent":"claude","terminal_id":"term-child","revision":1,"state_change_seq":1}]}}\n'
    fi ;;
  "agent read") [ "${STUB_READ_FAIL:-0}" = 1 ] && { printf 'read failed\n' >&2; exit 1; }; printf 'ANSWER from child\n' ;;
  "agent get") printf '{"result":{"agent":{"name":"red-wolf","pane_id":"wT:p9","agent":"claude","terminal_id":"term-child","revision":1,"state_change_seq":1,"agent_status":"%s"}}}\n' "${STUB_AGENT_STATUS:-idle}" ;;
  "agent prompt")
    [ "${STUB_PARENT_PROMPT_FAIL:-0}" = 1 ] && { printf 'prompt failed\n' >&2; exit 1; }
    printf '%s' "$4" > "$CHILD_STUB/parent-prompt"
    printf '{"result":{"agent":{"agent_status":"working"}}}\n'
    ;;
  "pane get")
    if [ "${STUB_WAITING_LABEL:-0}" = 1 ]; then
      printf '{"result":{"pane":{"pane_id":"wT:p9","terminal_id":"term-child","state_labels":{"blocked":"waiting for parent"}}}}\n'
    else printf '{"result":{"pane":{"pane_id":"wT:p9","terminal_id":"term-child"}}}\n'; fi ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$CHILD_STUB/herdr-child" "$CHILD_STUB/herdr"
}

function test_scripts_1051_ask_in_herdr_script_requires_arguments() {
  _bats_test_init 1051 'ask-in-herdr script requires arguments'
  run bash "$ASK_HERDR_SCRIPT"
  assert_failure 2
  assert_output --partial "Usage:"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=refused"
}

function test_scripts_1052_ask_sh_rejects_unknown_agents_and_the_removed_headless_() {
  _bats_test_init 1052 'ask.sh rejects unknown agents and the removed headless flag'
  run bash "$ASK_HERDR_SCRIPT" bogus question
  assert_failure 2
  assert_output --partial "claude opencode pi"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=refused"

  run bash "$ASK_HERDR_SCRIPT" claude question --model
  assert_failure 2
  assert_output --partial "Usage:"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=refused"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question --headless
  assert_failure 2
  assert_output --partial "unknown flag '--headless'"
  assert_output --partial "ask.sh: status=refused"
  [ ! -f "$CHILD_STUB/child.log" ]
}

function test_scripts_1053_ask_sh_refuses_outside_herdr_and_when_herdr_child_is_ab() {
  _bats_test_init 1053 'ask.sh refuses outside herdr and when herdr-child is absent'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV= HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 2
  assert_output --partial "status=refused"
  [ ! -f "$CHILD_STUB/child.log" ]

  local no_child; no_child="$(mktemp -d)"
  cp "$CHILD_STUB/herdr" "$no_child/herdr"
  run env PATH="$no_child:/usr/bin:/bin" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 2
  assert_output --partial "herdr-child is not on PATH"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=refused"
  rm -rf "$no_child"
}

function test_scripts_1054_ask_sh_starts_a_read_only_live_child_and_returns_its_an() {
  _bats_test_init 1054 'ask.sh starts a read-only live child and returns its answer'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude "hi there"
  assert_success
  assert_output --partial "ANSWER from child"
  assert_output --partial "close with: herdr-child reap --to red-wolf --pane wT:p9"
  assert_output --partial "ask.sh: status=answered"
  run grep -E -- '^start --kind claude --posture ro ' "$CHILD_STUB/child.log"
  assert_success
  run grep -E -- '--prompt-file .* --wait --timeout 1800000' "$CHILD_STUB/child.log"
  assert_success
  run grep -E -- '^agent read red-wolf --source visible --lines 200' "$CHILD_STUB/herdr.log"
  assert_success
  assert_file_contains "$CHILD_STUB/parent-prompt" '^\[child-settled v1 agent=red-wolf pane=wT:p9\]$'
  assert_file_contains "$CHILD_STUB/parent-prompt" 'initial answer has been read'
  assert_file_contains "$CHILD_STUB/parent-prompt" 'read its current output before reaping'
  assert_file_contains "$CHILD_STUB/parent-prompt" 'herdr-child reap --to red-wolf --pane wT:p9'
  assert_file_contains "$CHILD_STUB/herdr.log" '^agent prompt wT:p0 '
}

function test_scripts_1055_ask_sh_keeps_a_settled_answer_when_the_parent_reminder_() {
  _bats_test_init 1055 'ask.sh keeps a settled answer when the parent reminder cannot be queued'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENT_STATUS=done STUB_PARENT_PROMPT_FAIL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$ASK_HERDR_SCRIPT" claude question
  assert_success
  assert_output --partial "ANSWER from child"
  assert_output --partial "warning: could not queue the cleanup reminder"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=answered"
  assert_file_not_exists "$CHILD_STUB/parent-prompt"
}

function test_scripts_1056_ask_sh_forwards_posture_and_every_native_caller_option() {
  _bats_test_init 1056 'ask.sh forwards posture and every native caller option'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" pi question --rw --model M --effort high \
      --cwd "$PWD" --skills A --skills B --agent N
  assert_success
  run grep -E -- '--posture rw' "$CHILD_STUB/child.log"
  assert_success
  run grep -E -- '--model M --effort high --agent N --skills A --skills B' "$CHILD_STUB/child.log"
  assert_success

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" opencode question
  assert_success
  run grep -q -- '--model' "$CHILD_STUB/child.log"
  assert_failure
}

function test_scripts_1057_ask_sh_performs_no_agent_list_preflight_or_query_and_ve() {
  _bats_test_init 1057 'ask.sh performs no agent-list preflight or query and verifies the returned pair twice'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_success
  refute_output --partial "consult-claude"
  run grep -q -- '--name' "$CHILD_STUB/child.log"
  assert_failure
  run sed -n '1p' "$CHILD_STUB/order.log"
  assert_output --partial "child start"
  run grep -c '^herdr agent list' "$CHILD_STUB/herdr.log"
  assert_failure
  assert_output 0
  run grep -c '^verify --to red-wolf --pane wT:p9 ' "$CHILD_STUB/child.log"
  assert_success
  assert_output 2
  run grep -q 'herdr agent list' "$ASK_HERDR_SCRIPT"
  assert_failure
}

function test_scripts_1058_ask_sh_discards_buffered_output_when_either_pair_valida() {
  _bats_test_init 1058 'ask.sh discards buffered output when either pair validation fails'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_PAIR_FAIL_AT=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 1
  refute_output --partial "ANSWER from child"
  assert_output --partial "status=undelivered"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_PAIR_TERMINAL_CHANGE_AT=2 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 1
  refute_output --partial "ANSWER from child"
  assert_output --partial "output discarded"
}

function test_scripts_1059_ask_sh_reports_blocked_children_after_printing_their_an() {
  _bats_test_init 1059 'ask.sh reports blocked children after printing their answer'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENT_STATUS=blocked HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" opencode question
  assert_failure 1
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=blocked"
  assert_file_contains "$CHILD_STUB/herdr.log" '^agent read .*--source recent-unwrapped'
  assert_file_not_exists "$CHILD_STUB/parent-prompt"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_WAITING_LABEL=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" pi question --rw
  assert_failure 1
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=blocked"
  assert_file_not_exists "$CHILD_STUB/parent-prompt"
}

function test_scripts_1060_ask_sh_reports_undelivered_when_child_output_cannot_be_() {
  _bats_test_init 1060 'ask.sh reports undelivered when child output cannot be read'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_READ_FAIL=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 1
  assert_output --partial "read failed"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=undelivered"
}

function test_scripts_1061_ask_sh_reports_a_still_working_child_with_exit_124() {
  _bats_test_init 1061 'ask.sh reports a still-working child with exit 124'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_CHILD_STATUS=124 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 124
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=working"
  assert_file_not_exists "$CHILD_STUB/parent-prompt"
}

function test_scripts_1062_ask_sh_classifies_successful_waits_with_working_unknown() {
  _bats_test_init 1062 'ask.sh classifies successful waits with working, unknown, and fallback statuses'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENT_STATUS=working HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 124
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=working"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENT_STATUS=unknown HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 124
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=working"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENT_STATUS=surprised HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 1
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=undelivered"
}

function test_scripts_1063_ask_sh_maps_child_start_failures_to_refused_or_undelive() {
  _bats_test_init 1063 'ask.sh maps child start failures to refused or undelivered'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_CHILD_STATUS=2 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" pi question
  assert_failure 2
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=refused"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_CHILD_STATUS=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 1
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=undelivered"
}

# ===========================================

# ===========================================
# herdr-child launch and return contract
# ===========================================

HERDR_CHILD="$SOURCE_ROOT/dot_local/bin/executable_herdr-child"

child_stub_herdr() {
  export HERDR_ALIAS_TEST_SEED=tests
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
    elif [ "${STUB_START_CONTEXT:-0}" = 1 ] && [ -f "$CHILD_STUB/started-name" ]; then
      child_name="$(cat "$CHILD_STUB/started-name")"
      if [ "${STUB_CHILD_SESSION_MISSING:-0}" = 1 ]; then
        printf '{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p0","terminal_id":"term-parent","revision":1,"state_change_seq":1,"agent_session":{"value":"parent-session"}},{"name":"%s","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10}]}}\n' "$child_name"
      elif [ "${STUB_PARENT_SESSION_MISSING:-0}" = 1 ]; then
        printf '{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p0","terminal_id":"term-parent","revision":1,"state_change_seq":1},{"name":"%s","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10,"agent_session":{"value":"child-session"}}]}}\n' "$child_name"
      else
        printf '{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p0","terminal_id":"term-parent","revision":1,"state_change_seq":1,"agent_session":{"value":"parent-session"}},{"name":"%s","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10,"agent_session":{"value":"child-session"}}]}}\n' "$child_name"
      fi
    elif [ "${STUB_START_CONTEXT:-0}" = 1 ] && [ "${STUB_PARENT_SESSION_MISSING:-0}" = 1 ]; then
      printf '{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p0","terminal_id":"term-parent","revision":1,"state_change_seq":1}]}}\n'
    elif [ "${STUB_START_CONTEXT:-0}" = 1 ]; then
      printf '{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p0","terminal_id":"term-parent","revision":1,"state_change_seq":1,"agent_session":{"value":"parent-session"}}]}}\n'
    else
      printf '{"result":{"agents":[]}}\n'
    fi ;;
  "pane split")
    [ "${STUB_SPLIT_FAIL:-0}" = 1 ] && exit 1
    : > "$CHILD_STUB/split-seen"
    printf '{"result":{"pane":{"pane_id":"wT:p9","terminal_id":"term-child"}}}\n' ;;
  "tab create")
    [ "${STUB_TAB_CREATE_FAIL:-0}" = 1 ] && exit 1
    : > "$CHILD_STUB/split-seen"
    if [ "${STUB_TAB_CREATE_MALFORMED:-0}" = 1 ]; then
      printf '{"result":{"root_pane":{"pane_id":"","terminal_id":""},"tab":{"tab_id":"wT:tA"}}}\n'
    elif [ "${STUB_TAB_CREATE_NO_TERMINAL:-0}" = 1 ]; then
      printf '{"result":{"root_pane":{"pane_id":"wT:p9","terminal_id":""},"tab":{"tab_id":"wT:tA"}}}\n'
    else
      printf '{"result":{"root_pane":{"pane_id":"wT:p9","terminal_id":"term-child"},"tab":{"tab_id":"wT:tA"}}}\n'
    fi ;;
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
    printf '%s' "${3:-child}" > "$CHILD_STUB/started-name"
    printf '{"result":{"agent":{"interactive_ready":true}}}\n' ;;
  "agent get")
    child_name="$(cat "$CHILD_STUB/started-name" 2>/dev/null || printf child)"
    printf '{"result":{"agent":{"name":"%s","pane_id":"wT:p9","terminal_id":"term-child","agent_session":{"value":"child-session"},"agent_status":"working","state_change_seq":10}}}\n' "$child_name" ;;
  "agent prompt")
    : > "$CHILD_STUB/prompt-seen"
    if [ "${STUB_PROMPT_BLOCK:-0}" = 1 ]; then
      trap 'exit 143' HUP INT TERM
      # Bounded so an orphaned stub prompt cannot poll forever after a killed
      # harness (docs/issues/2026-08-28-001).
      attempt=0
      while [ ! -e "$CHILD_STUB/release-prompt" ]; do
        [ -d "$CHILD_STUB" ] || exit 1
        attempt=$((attempt + 1))
        [ "$attempt" -lt 12000 ] || exit 1
        sleep 0.01
      done
    fi
    [ "${STUB_PROMPT_FAIL:-0}" = 1 ] && { printf '{"error":{"code":"agent_prompt_stalled"}}\n' >&2; exit 1; }
    [ "${STUB_PROMPT_TIMEOUT:-0}" = 1 ] && { printf '{"error":{"code":"timeout"}}\n' >&2; exit 1; }
    printf '{"result":{"agent":{"agent_status":"idle"}}}\n' ;;
  "pane report-metadata")
    [ "${STUB_REPORT_FAIL:-0}" = 1 ] && exit 1
    if printf '%s\n' "$*" | grep -q 'supervised'; then
      if [ "${STUB_SUPERVISION_REPORT_BLOCK:-0}" = 1 ]; then
        : > "$CHILD_STUB/liveness-started"
        trap 'exit 143' HUP INT TERM
        # Bounded so an orphaned stub cannot poll forever after a killed
        # harness (docs/issues/2026-08-28-001).
        attempt=0
        while [ ! -e "$CHILD_STUB/release-liveness" ]; do
          [ -d "$CHILD_STUB" ] || exit 1
          attempt=$((attempt + 1))
          [ "$attempt" -lt 12000 ] || exit 1
          sleep 0.01
        done
      fi
      [ "${STUB_SUPERVISION_REPORT_FAIL:-0}" != 1 ] || exit 1
    fi
    for arg in "$@"; do
      case "$arg" in
        supervision_generation=*) printf '%s\n' "${arg#*=}" > "$CHILD_STUB/generation" ;;
      esac
    done
    if printf '%s\n' "$*" | grep -q 'supervised=' && [ -f "$CHILD_STUB/fail-supervision-report" ]; then
      exit 1
    fi
    printf '{"result":{"type":"pane_metadata_reported"}}\n' ;;
  "pane get")
    if [ "${STUB_PANE_GET_MALFORMED:-0}" = 1 ]; then
      printf 'not json\n'
    elif [ "${STUB_LABEL:-0}" = 1 ]; then
      printf '{"result":{"pane":{"pane_id":"%s","terminal_id":"term-child","state_labels":{"blocked":"waiting for parent"}}}}\n' "${3:-wT:p9}"
    elif [ -n "${STUB_PANE_TAB_ID:-}" ]; then
      printf '{"result":{"pane":{"pane_id":"%s","terminal_id":"term-child","tab_id":"%s","tokens":{"child-tab":"%s"}}}}\n' \
        "${3:-wT:p9}" "$STUB_PANE_TAB_ID" "${STUB_PANE_CHILD_TAB_TOKEN:-$STUB_PANE_TAB_ID}"
    elif [ -f "$CHILD_STUB/generation" ]; then
      generation="$(cat "$CHILD_STUB/generation")"
      printf '{"result":{"pane":{"pane_id":"wT:p9","terminal_id":"term-child","agent_session":{"value":"child-session"},"tokens":{"supervision_generation":"%s"}}}}\n' "$generation"
    else
      printf '{"result":{"pane":{"pane_id":"%s","terminal_id":"term-child"}}}\n' "${3:-wT:p9}"
    fi ;;
  "pane close")
    [ "${STUB_CLOSE_NOT_FOUND:-0}" = 1 ] && { printf '{"error":{"code":"pane_not_found","message":"pane not found"}}\n' >&2; exit 1; }
    exit "${STUB_CLOSE_STATUS:-0}" ;;
  "tab get")
    [ "${STUB_TAB_GET_FAIL:-0}" = 1 ] && { printf '{"error":{"code":"tab_not_found","message":"tab not found"}}\n' >&2; exit 1; }
    [ "${STUB_TAB_GET_TRANSIENT:-0}" = 1 ] && { printf '{"error":{"code":"internal_error","message":"transient failure"}}\n' >&2; exit 1; }
    printf '{"result":{"tab":{"pane_count":%s}}}\n' "${STUB_TAB_PANE_COUNT:-1}" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$CHILD_STUB/herdr"
  cat > "$CHILD_STUB/ps" <<'SH'
#!/usr/bin/env bash
if [ -f "$CHILD_STUB/observe-ps-locale" ]; then
  printf '%s\n' "${LC_ALL:-unset}" >> "$CHILD_STUB/ps-locales.log"
fi
exec /bin/ps "$@"
SH
  chmod +x "$CHILD_STUB/ps"
}

child_start() {
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    STUB_START_CONTEXT=1 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_TEST_WATCHER_RELEASE="$CHILD_STUB/release-watcher" \
    bash "$HERDR_CHILD" start "$@" --prompt "test task"
}

child_lifecycle_stub_herdr() {
  child_stub_herdr
  printf 'working 10\n' > "$CHILD_STUB/baseline-state"
  printf 'working 10\n' > "$CHILD_STUB/child-state"
  printf 'wT:p0\n' > "$CHILD_STUB/parent-pane"
  printf 'parent-session\n' > "$CHILD_STUB/parent-session"
  printf 'term-child\n' > "$CHILD_STUB/child-terminal"
  printf 'child-session\n' > "$CHILD_STUB/child-session"
  cat > "$CHILD_STUB/herdr" <<'SH'
#!/usr/bin/env bash
set -u

printf '%q ' "$@" >> "$CHILD_STUB/calls.log"
printf '\n' >> "$CHILD_STUB/calls.log"

read_value() {
  local file="$1" fallback="$2" value
  value="$(cat "$CHILD_STUB/$file" 2>/dev/null || true)"
  printf '%s' "${value:-$fallback}"
}

agent_json() {
  local name="$1" pane="$2" terminal="$3" session="$4" status="$5" seq="$6"
  printf '{"name":"%s","agent":"claude","pane_id":"%s","terminal_id":"%s","revision":1,"agent_session":{"value":"%s"},"agent_status":"%s","state_change_seq":%s,"focused":false}' \
    "$name" "$pane" "$terminal" "$session" "$status" "$seq"
}

case "${1:-} ${2:-}" in
  "agent list")
    parent_pane="$(read_value parent-pane 'wT:p0')"
    parent_session="$(read_value parent-session parent-session)"
    parent_status="$(read_value parent-status working)"
    if [ "$parent_status" = blocked ] && [ -f "$CHILD_STUB/generation" ]; then
      : > "$CHILD_STUB/parent-blocked-observed"
    fi
    parent="$(agent_json parent "$parent_pane" term-parent "$parent_session" "$parent_status" 1)"
    if [ -f "$CHILD_STUB/started-name" ] && [ ! -f "$CHILD_STUB/child-gone" ]; then
      child_name="$(cat "$CHILD_STUB/started-name")"
      child_terminal="$(read_value child-terminal term-child)"
      child_session="$(read_value child-session child-session)"
      read -r child_status child_seq < "$CHILD_STUB/child-state"
      child_status="$(read_value child-list-status "$child_status")"
      child="$(agent_json "$child_name" wT:p9 "$child_terminal" "$child_session" "$child_status" "$child_seq")"
      printf '{"result":{"agents":[%s,%s]}}\n' "$parent" "$child"
    else
      printf '{"result":{"agents":[%s]}}\n' "$parent"
    fi
    ;;
  "pane split")
    printf '{"result":{"pane":{"pane_id":"wT:p9","terminal_id":"term-child"}}}\n'
    ;;
  "tab create")
    printf '{"result":{"root_pane":{"pane_id":"wT:p9","terminal_id":"term-child"},"tab":{"tab_id":"wT:tA"}}}\n'
    ;;
  "agent start")
    printf '%s' "${3:-child}" > "$CHILD_STUB/started-name"
    printf '{"result":{"agent":{"interactive_ready":true}}}\n'
    ;;
  "agent get")
    count="$(read_value get-count 0)"
    count=$((count + 1))
    printf '%s\n' "$count" > "$CHILD_STUB/get-count"
    if [ "$count" -gt 1 ] && [ -f "$CHILD_STUB/child-gone" ]; then
      printf '{"error":{"code":"agent_not_found"}}\n' >&2
      exit 1
    fi
    if [ "$count" -gt 1 ] && [ -f "$CHILD_STUB/malformed-state" ]; then
      printf 'not-json\n'
      exit 0
    fi
    state_file=baseline-state
    [ "$count" -eq 1 ] || state_file=child-state
    read -r child_status child_seq < "$CHILD_STUB/$state_file"
    if [ "$count" -gt 1 ] && [ -f "$CHILD_STUB/block-agent-get" ]; then
      : > "$CHILD_STUB/agent-get.ready"
      attempt=0
      while [ ! -f "$CHILD_STUB/agent-get.release" ]; do
        [ -d "$CHILD_STUB" ] || exit 1
        attempt=$((attempt + 1))
        [ "$attempt" -lt 12000 ] || exit 1
        sleep 0.01
      done
    fi
    child_name="$(read_value started-name child)"
    child_terminal="$(read_value child-terminal term-child)"
    child_session="$(read_value child-session child-session)"
    child="$(agent_json "$child_name" wT:p9 "$child_terminal" "$child_session" "$child_status" "$child_seq")"
    if [ "$child_status" = working ] && [ "$child_seq" -gt 10 ]; then
      : > "$CHILD_STUB/fresh-working-observed"
    elif [ "$child_status" = blocked ]; then
      : > "$CHILD_STUB/blocked-observed"
    elif [ "$child_seq" -gt 10 ]; then
      : > "$CHILD_STUB/settlement-observed"
    fi
    printf '{"result":{"agent":%s}}\n' "$child"
    ;;
  "agent wait")
    : > "$CHILD_STUB/wait-observed"
    if [ -f "$CHILD_STUB/wait-block" ]; then
      # Bounded so an orphaned stub cannot poll forever after a killed
      # harness (docs/issues/2026-08-28-001).
      attempt=0
      while [ ! -f "$CHILD_STUB/wait-release" ]; do
        [ -d "$CHILD_STUB" ] || exit 1
        attempt=$((attempt + 1))
        [ "$attempt" -lt 12000 ] || exit 1
        sleep 0.01
      done
    fi
    if [ -f "$CHILD_STUB/wait-error" ]; then
      printf '{"error":{"code":"internal_error","message":"transient wait failure"}}\n' >&2
      exit 1
    fi
    read -r child_status _ < "$CHILD_STUB/child-state"
    case "$child_status" in
      idle|done|blocked) printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$child_status" ;;
      *) printf '{"error":{"code":"timeout","message":"wait timed out"}}\n'; exit 1 ;;
    esac
    ;;
  "agent prompt")
    target="${3:-}"
    if [[ "$target" == wT:* ]]; then
      if [ -f "$CHILD_STUB/prompt-fail-count" ]; then
        failures="$(cat "$CHILD_STUB/prompt-fail-count")"
        if [ "$failures" -gt 0 ]; then
          printf '%s\n' $((failures - 1)) > "$CHILD_STUB/prompt-fail-count"
          printf '{"error":{"code":"transport_error"}}\n' >&2
          exit 1
        fi
      fi
      if [ -f "$CHILD_STUB/block-parent-prompt" ]; then
        : > "$CHILD_STUB/parent-prompt-accepted"
        # Bounded so an orphaned stub cannot poll forever after a killed
        # harness (docs/issues/2026-08-28-001).
        attempt=0
        while [ ! -f "$CHILD_STUB/release-parent-prompt" ]; do
          [ -d "$CHILD_STUB" ] || exit 1
          attempt=$((attempt + 1))
          [ "$attempt" -lt 12000 ] || exit 1
          sleep 0.01
        done
      fi
      printf '%s\n' "${4:-}" >> "$CHILD_STUB/successful-prompts.log"
    elif [ -f "$CHILD_STUB/advance-on-prompt" ]; then
      printf 'idle 12\n' > "$CHILD_STUB/child-state"
    fi
    printf '{"result":{"agent":{"agent_status":"working"}}}\n'
    ;;
  "pane report-metadata")
    clear_labels=0
    waiting_label=0
    clear_next=0
    seq_next=0
    seq_value=
    for arg in "$@"; do
      if [ "$seq_next" -eq 1 ]; then
        seq_value="$arg"
        seq_next=0
        continue
      fi
      [ "$arg" != --seq ] || seq_next=1
    done
    if [ -n "$seq_value" ] && [ -f "$CHILD_STUB/metadata-seq" ] && \
       [ "$seq_value" -le "$(cat "$CHILD_STUB/metadata-seq")" ]; then
      printf '{"result":{"type":"pane_metadata_reported"}}\n'
      exit 0
    fi
    [ -z "$seq_value" ] || printf '%s\n' "$seq_value" > "$CHILD_STUB/metadata-seq"
    for arg in "$@"; do
      if [ "$clear_next" -eq 1 ]; then
        case "$arg" in
          supervision_generation)
            rm -f "$CHILD_STUB/generation"
            : > "$CHILD_STUB/generation-invalidated"
            ;;
          supervision_failure_reason) rm -f "$CHILD_STUB/failure-reason" ;;
          supervision_failure_generation) rm -f "$CHILD_STUB/failure-generation" ;;
          supervision_failure_diagnostic) rm -f "$CHILD_STUB/failure-diagnostic" ;;
        esac
        clear_next=0
        continue
      fi
      [ "$arg" != --clear-token ] || { clear_next=1; continue; }
      case "$arg" in
        supervision_generation=*) printf '%s\n' "${arg#*=}" > "$CHILD_STUB/generation" ;;
        supervision_failure_reason=*) printf '%s\n' "${arg#*=}" > "$CHILD_STUB/failure-reason" ;;
        supervision_failure_generation=*) printf '%s\n' "${arg#*=}" > "$CHILD_STUB/failure-generation" ;;
        supervision_failure_diagnostic=*) printf '%s\n' "${arg#*=}" > "$CHILD_STUB/failure-diagnostic" ;;
        child-tab=*) printf '%s\n' "${arg#*=}" > "$CHILD_STUB/child-tab" ;;
        --clear-state-labels) clear_labels=1 ;;
        blocked=waiting\ for\ parent) waiting_label=1 ;;
        supervision\ failed=*) : > "$CHILD_STUB/failure-label" ;;
      esac
    done
    [ "$clear_labels" -eq 0 ] || rm -f "$CHILD_STUB/waiting-label" "$CHILD_STUB/failure-label"
    [ "$waiting_label" -eq 0 ] || : > "$CHILD_STUB/waiting-label"
    printf '{"result":{"type":"pane_metadata_reported"}}\n'
    ;;
  "pane get")
    if [ -f "$CHILD_STUB/block-delivery-pane-get" ] && \
       [ -f "$CHILD_STUB/settlement-observed" ] && \
       [ ! -f "$CHILD_STUB/delivery-pane-get.ready" ]; then
      : > "$CHILD_STUB/delivery-pane-get.ready"
      attempt=0
      while [ ! -f "$CHILD_STUB/delivery-pane-get.release" ]; do
        [ -d "$CHILD_STUB" ] || exit 1
        attempt=$((attempt + 1))
        [ "$attempt" -lt 12000 ] || exit 1
        sleep 0.01
      done
    fi
    if [ -f "$CHILD_STUB/observe-reap-invalidation" ] && \
       [ -f "$CHILD_STUB/pane-close.ready" ]; then
      for run_dir in "$HERDR_CHILD_STATE_DIR"/runs/*; do
        [ ! -f "$run_dir/invalidated.state" ] || : > "$CHILD_STUB/reap-invalidation-consumed"
      done
      if [ -f "$CHILD_STUB/block-reap-pane-get" ]; then
        : > "$CHILD_STUB/reap-pane-get.ready"
        attempt=0
        while [ ! -f "$CHILD_STUB/reap-pane-get.release" ]; do
          [ -d "$CHILD_STUB" ] || exit 1
          attempt=$((attempt + 1))
          [ "$attempt" -lt 12000 ] || exit 1
          sleep 0.01
        done
      fi
    fi
    if [ -f "$CHILD_STUB/child-gone" ]; then
      printf '{"error":{"code":"pane_not_found","message":"pane not found"}}\n' >&2
      exit 1
    fi
    if [ -f "$CHILD_STUB/pane-get-transient-next" ]; then
      rm -f "$CHILD_STUB/pane-get-transient-next"
      : > "$CHILD_STUB/pane-get-transient-observed"
      printf '{"error":{"code":"internal_error","message":"transient pane read"}}\n' >&2
      exit 1
    fi
    if [ -f "$CHILD_STUB/pane-transient-after-settlement" ] && \
       [ -f "$CHILD_STUB/settlement-observed" ] && \
       [ ! -f "$CHILD_STUB/pane-get-transient-observed" ]; then
      : > "$CHILD_STUB/pane-get-transient-observed"
      printf '{"error":{"code":"internal_error","message":"transient pane read"}}\n' >&2
      exit 1
    fi
    if [ -f "$CHILD_STUB/pane-malformed" ]; then
      printf 'not-json\n'
      exit 0
    fi
    child_terminal="$(read_value child-terminal term-child)"
    child_session="$(read_value child-session child-session)"
    generation="$(read_value generation '')"
    child_tab="$(read_value child-tab '')"
    tab_token=""
    tab_field=""
    if [ -n "$child_tab" ]; then
      tab_token=",\"child-tab\":\"$child_tab\""
      tab_field=",\"tab_id\":\"$child_tab\""
    fi
    if [ -n "$generation" ]; then
      tokens="{\"child_mode\":\"detach\",\"supervision_generation\":\"$generation\",\"supervision_timeout\":\"5000\",\"parent_terminal\":\"term-parent\",\"parent_session\":\"parent-session\",\"child_terminal\":\"term-child\",\"child_session\":\"child-session\"$tab_token}"
    elif [ -n "$child_tab" ]; then
      tokens="{\"child-tab\":\"$child_tab\"}"
    else
      tokens='{}'
    fi
    labels='{}'
    [ ! -f "$CHILD_STUB/waiting-label" ] || labels='{"blocked":"waiting for parent"}'
    printf '{"result":{"pane":{"pane_id":"wT:p9","terminal_id":"%s","agent_session":{"value":"%s"},"tokens":%s,"state_labels":%s%s}}}\n' \
      "$child_terminal" "$child_session" "$tokens" "$labels" "$tab_field"
    ;;
  "pane close")
    if [ -f "$CHILD_STUB/require-reap-invalidation" ]; then
      invalidation_found=0
      for run_dir in "$HERDR_CHILD_STATE_DIR"/runs/*; do
        [ ! -f "$run_dir/invalidated.state" ] || invalidation_found=1
      done
      if [ "$invalidation_found" -eq 1 ]; then
        : > "$CHILD_STUB/reap-invalidation-observed"
      else
        : > "$CHILD_STUB/close-before-invalidation"
      fi
    fi
    if [ -f "$CHILD_STUB/block-pane-close" ]; then
      : > "$CHILD_STUB/pane-close.ready"
      attempt=0
      while [ ! -f "$CHILD_STUB/pane-close.release" ]; do
        [ -d "$CHILD_STUB" ] || exit 1
        attempt=$((attempt + 1))
        [ "$attempt" -lt 12000 ] || exit 1
        sleep 0.01
      done
    fi
    if [ -f "$CHILD_STUB/close-fail" ]; then
      printf '{"error":{"code":"internal_error","message":"close failed"}}\n' >&2
      exit 1
    fi
    : > "$CHILD_STUB/pane-closed"
    ;;
  "tab get")
    if [ -f "$CHILD_STUB/pane-closed" ]; then
      printf '{"error":{"code":"tab_not_found","message":"tab not found"}}\n' >&2
      exit 1
    fi
    printf '{"result":{"tab":{"pane_count":1}}}\n'
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$CHILD_STUB/herdr"
}

child_lifecycle_start() {
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_REAP_OWNER_VERIFIED="${HERDR_CHILD_TEST_REAP_OWNER_VERIFIED:-}" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_POLL_INTERVAL=0.01 HERDR_CHILD_TEST_SKIP_RETRY_SLEEP=1 \
    bash "$HERDR_CHILD" start --kind claude --detach \
    --prompt "test task" "$@"
}

child_wait_for_log() {
  local pattern="$1" file="${2:-$CHILD_STUB/calls.log}" attempt=0
  while [ "$attempt" -lt 500 ]; do
    grep -q -- "$pattern" "$file" 2>/dev/null && return 0
    attempt=$((attempt + 1))
    sleep 0.01
  done
  printf 'pattern not observed: %s\n' "$pattern" >&2
  cat "$file" >&2
  return 1
}

child_wait_for_get_count() {
  local wanted="$1" attempt=0 count
  while [ "$attempt" -lt 500 ]; do
    count="$(cat "$CHILD_STUB/get-count" 2>/dev/null || printf 0)"
    [ "$count" -lt "$wanted" ] || return 0
    attempt=$((attempt + 1))
    sleep 0.01
  done
  return 1
}

child_wait_for_file() {
  local file="$1" attempt=0
  while [ "$attempt" -lt 500 ]; do
    [ ! -e "$file" ] || return 0
    attempt=$((attempt + 1))
    sleep 0.01
  done
  printf 'file not observed: %s\n' "$file" >&2
  return 1
}

function test_scripts_021_herdr_child_requires_a_subcommand_and_herdr_envi() {
  _bats_test_init 21 'herdr-child requires a subcommand and herdr environment'
  run bash "$HERDR_CHILD"
  assert_failure 2
  assert_output --partial "Usage:"

  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV= HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" start --kind claude --wait --prompt task
  assert_failure
  [ ! -f "$CHILD_STUB/calls.log" ]
}

function test_scripts_022_herdr_child_refuses_pi_read_only_before_splittin() {
  _bats_test_init 22 'herdr-child refuses pi read-only before splitting a pane'
  child_stub_herdr
  run child_start --kind pi --posture ro --wait
  assert_failure 2
  assert_output --partial "return channel requires bash"
  [ ! -f "$CHILD_STUB/calls.log" ]
}

function test_scripts_023_herdr_child_start_requires_exactly_one_explicit() {
  _bats_test_init 23 'herdr-child start requires exactly one explicit mode before Herdr mutation'
  child_stub_herdr

  run child_start --kind claude
  assert_failure 2
  assert_output --partial "exactly one of --wait or --detach"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --wait --detach
  assert_failure 2
  assert_output --partial "exactly one of --wait or --detach"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --wait --wait
  assert_failure 2
  assert_output --partial "mode flag may be specified only once"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --detach --detach
  assert_failure 2
  assert_output --partial "mode flag may be specified only once"
  assert_file_not_exists "$CHILD_STUB/calls.log"
}

function test_scripts_024_herdr_child_validates_tab_placement_before_herdr() {
  _bats_test_init 24 'herdr-child validates tab placement before Herdr mutation'
  child_stub_herdr

  HERDR_WORKSPACE_ID=w1 run child_start --kind claude --tab --direction right --wait
  assert_failure 2
  assert_output --partial "--tab cannot be combined with --direction"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --label mylabel --wait
  assert_failure 2
  assert_output --partial "--label is only valid with --tab"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --tab --wait
  assert_failure 2
  assert_output --partial "--tab requires HERDR_WORKSPACE_ID"
  assert_file_not_exists "$CHILD_STUB/calls.log"
}

function test_scripts_025_herdr_child_validates_launch_and_supervision_tim() {
  _bats_test_init 25 'herdr-child validates launch and supervision timeouts before Herdr mutation'
  child_stub_herdr

  run child_start --kind claude --wait --timeout 0
  assert_failure 2
  assert_output --partial "--timeout must be a positive integer"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --wait --supervision-timeout 10
  assert_failure 2
  assert_output --partial "--supervision-timeout requires --detach"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --wait --supervision-timeout 3600000
  assert_failure 2
  assert_output --partial "--supervision-timeout requires --detach"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  local value
  for value in 0 86400001 malformed; do
    run child_start --kind claude --detach --supervision-timeout "$value"
    assert_failure 2
    assert_output --partial "--supervision-timeout must be between 1 and 86400000 milliseconds"
    assert_file_not_exists "$CHILD_STUB/calls.log"
  done

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" start --kind claude --detach \
    --prompt "test task" --supervision-timeout
  assert_failure 2
  assert_output --partial "--supervision-timeout needs a value"
  assert_file_not_exists "$CHILD_STUB/calls.log"
}

function test_scripts_026_herdr_child_attached_mode_starts_no_watcher() {
  _bats_test_init 26 'herdr-child attached mode starts no watcher'
  child_stub_herdr
  run child_start --kind claude --wait
  assert_success
  assert_output '{"agent":"orange-panda","pane":"wT:p9"}'
  assert_file_not_exists "$CHILD_STUB/watcher.pid"
  assert_file_contains "$CHILD_STUB/calls.log" 'pane split.*HERDR_CHILD_LAUNCH_MODE=wait'
  assert_file_contains "$CHILD_STUB/calls.log" 'pane split.*HERDR_CHILD_PARENT_TERMINAL=term-parent'
  assert_file_contains "$CHILD_STUB/calls.log" 'pane split.*HERDR_CHILD_PARENT_SESSION=parent-session'
  run grep -q 'supervised' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_027_herdr_child_detached_mode_fails_closed_without_a() {
  _bats_test_init 27 'herdr-child detached mode fails closed without a parent session'
  child_stub_herdr
  STUB_PARENT_SESSION_MISSING=1 run child_start --kind claude --detach
  assert_failure
  assert_output --partial "parent agent_session is unavailable"
  assert_file_contains "$CHILD_STUB/calls.log" '^agent list'
  run grep -Eq '^(pane split|agent start|agent prompt|pane report-metadata)' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_028_herdr_child_detached_mode_closes_only_its_new_pa() {
  _bats_test_init 28 'herdr-child detached mode closes only its new pane without a child session'
  child_stub_herdr
  STUB_CHILD_SESSION_MISSING=1 run child_start --kind claude --detach
  assert_failure
  assert_output --partial "child agent_session is unavailable"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
  run grep -q '^agent prompt' "$CHILD_STUB/calls.log"
  assert_failure
  assert_file_not_exists "$CHILD_STUB/watcher.pid"
}

function test_scripts_029_herdr_child_detached_mode_returns_only_after_liv() {
  _bats_test_init 29 'herdr-child detached mode returns only after liveness and causal watcher arming'
  child_stub_herdr
  run child_start --kind claude --detach --supervision-timeout 60000
  assert_success
  assert_output --partial '"agent":"orange-panda"'
  assert_output --partial '"supervision":{"status":"armed"'
  assert_output --partial '"timeout_ms":60000'
  assert_file_exists "$CHILD_STUB/watcher.pid"
  local generation
  generation="$(cat "$CHILD_STUB/generation")"
  run cat "$CHILD_STUB/state/runs/$generation/launch.state"
  assert_success
  assert_output "$(printf '%s\n' 'mode=detach' "generation=$generation" 'timeout_ms=60000' \
    'parent_pane=wT:p0' 'parent_terminal=term-parent' 'parent_session=parent-session' \
    'child_name=orange-panda' 'child_pane=wT:p9' 'child_terminal=term-child' \
    'child_session=child-session' 'baseline_seq=10')"

  local metadata_call prompt_call
  metadata_call="$(grep -n 'state-label supervised=' "$CHILD_STUB/calls.log" | cut -d: -f1)"
  prompt_call="$(grep -n '^agent prompt' "$CHILD_STUB/calls.log" | cut -d: -f1)"
  [ -n "$metadata_call" ]
  [ "$metadata_call" -lt "$prompt_call" ]
  assert_file_contains "$CHILD_STUB/calls.log" 'pane report-metadata.*--token child_mode=detach'
  assert_file_contains "$CHILD_STUB/calls.log" 'pane report-metadata.*--token parent_session=parent-session'
  assert_file_contains "$CHILD_STUB/calls.log" 'pane report-metadata.*--token child_session=child-session'
}

function test_scripts_030_herdr_child_detached_arm_failure_preserves_the_c() {
  _bats_test_init 30 'herdr-child detached arm failure preserves the child and returns recovery JSON'
  child_stub_herdr
  HERDR_CHILD_TEST_ARM_FAIL=1 run child_start --kind claude --detach
  assert_failure
  assert_output --partial '"agent":"orange-panda","pane":"wT:p9"'
  assert_output --partial '"supervision":{"status":"failed","reason":"watcher-arm-failed"'
  assert_file_contains "$CHILD_STUB/calls.log" '^agent prompt'
  assert_file_contains "$CHILD_STUB/calls.log" 'state-label supervision\\ failed='
  set -- "$CHILD_STUB/state/runs/"*
  [ "$#" -eq 1 ]
  assert_file_exists "$1/failed.state"
  assert_file_permission 700 "$1"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_031_herdr_child_signal_before_prompt_submission_clos() {
  _bats_test_init 31 'herdr-child signal before prompt submission closes owned state and pane'
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 STUB_START_CONTEXT=1 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    STUB_SUPERVISION_REPORT_BLOCK=1 CHILD_SCRIPT="$HERDR_CHILD" python3 - <<'PY'
import os
from pathlib import Path
import select
import signal
import subprocess
import time

stub = Path(os.environ["CHILD_STUB"])
proc = subprocess.Popen(
    ["bash", os.environ["CHILD_SCRIPT"], "start", "--kind", "claude", "--detach", "--prompt", "test task"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=os.environ.copy(),
)
for _ in range(1000):
    if (stub / "liveness-started").exists():
        break
    time.sleep(0.01)
else:
    proc.kill()
    raise AssertionError("watcher never reached its pre-submission liveness boundary")

watcher_pid = int((stub / "watcher.pid").read_text().strip())
proc.send_signal(signal.SIGTERM)
stdout, stderr = proc.communicate(timeout=10)
if proc.returncode == 0:
    raise AssertionError("signaled launcher returned success")
if stdout:
    raise AssertionError("pre-submission signal returned a detached success or recovery record")
calls = (stub / "calls.log").read_text()
if "pane close wT:p9" not in calls or "agent prompt" in calls:
    raise AssertionError("pre-submission signal did not close only the owned pane: %s" % calls)
for _ in range(1000):
    try:
        os.kill(watcher_pid, 0)
    except ProcessLookupError:
        break
    time.sleep(0.01)
else:
    raise AssertionError("owned watcher survived pre-submission cancellation")
run_root = stub / "state" / "runs"
if run_root.exists() and list(run_root.iterdir()):
    raise AssertionError("pre-submission cancellation left orphan run state")
PY
  assert_success
}

function test_scripts_032_herdr_child_catchable_launch_signals_preserve_ow() {
  _bats_test_init 32 'herdr-child catchable launch signals preserve ownership after prompt submission'
  local signal signal_name calls
  for signal in HUP INT TERM; do
    child_stub_herdr
    signal_name="$(printf '%s' "$signal" | tr '[:upper:]' '[:lower:]')"
    run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 STUB_START_CONTEXT=1 \
      HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
      HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
      HERDR_CHILD_TEST_WATCHER_RELEASE="$CHILD_STUB/release-watcher" \
      STUB_PROMPT_BLOCK=1 CHILD_SIGNAL="$signal" CHILD_SIGNAL_NAME="$signal_name" \
      CHILD_SCRIPT="$HERDR_CHILD" python3 - <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import time

stub = Path(os.environ["CHILD_STUB"])
child_signal = getattr(signal, "SIG" + os.environ["CHILD_SIGNAL"])
# Parallel Bats workers ignore SIGINT; reset it while spawning so Bash can install the trap.
previous_handler = signal.signal(child_signal, signal.SIG_DFL)
try:
    proc = subprocess.Popen(
        ["bash", os.environ["CHILD_SCRIPT"], "start", "--kind", "claude", "--detach", "--prompt", "test task"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=os.environ.copy(),
    )
finally:
    signal.signal(child_signal, previous_handler)
for _ in range(1000):
    if (stub / "prompt-seen").exists():
        break
    time.sleep(0.01)
else:
    proc.kill()
    raise AssertionError("prompt submission never reached its barrier")

proc.send_signal(child_signal)
try:
    # prompt-seen proves signal ordering; this only guards a stuck cleanup/exit path.
    stdout, stderr = proc.communicate(timeout=30)
except subprocess.TimeoutExpired:
    proc.kill()
    proc.wait()
    raise AssertionError("launcher exceeded the 30-second cleanup hang guard")
if proc.returncode == 0:
    raise AssertionError("signaled launcher returned success")
expected = '"supervision":{"status":"failed","reason":"launch-signal-' + os.environ["CHILD_SIGNAL"]
if expected not in stdout or '"pane":"wT:p9"' not in stdout:
    raise AssertionError("missing recovery JSON: stdout=%r stderr=%r" % (stdout, stderr))
calls = (stub / "calls.log").read_text()
if "pane close" in calls:
    raise AssertionError("signaled launcher closed the preserved child")
(stub / "release-watcher").touch()
PY
    assert_success
    calls="$CHILD_STUB"
    CHILD_STUB=""
    rm -rf "$calls"
  done
}

function test_scripts_033_herdr_child_signal_and_arm_handshake_resolves_ab() {
  _bats_test_init 33 'herdr-child signal and arm handshake resolves abort before reporting supervision'
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 STUB_START_CONTEXT=1 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_TEST_ARM_BARRIER="$CHILD_STUB/arm" \
    CHILD_SCRIPT="$HERDR_CHILD" python3 - <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import time

stub = Path(os.environ["CHILD_STUB"])
proc = subprocess.Popen(
    ["bash", os.environ["CHILD_SCRIPT"], "start", "--kind", "claude", "--detach", "--prompt", "test task"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=os.environ.copy())
for _ in range(1000):
    if (stub / "arm.ready").exists():
        break
    time.sleep(0.01)
else:
    proc.kill()
    raise AssertionError("watcher did not reach the pre-arm barrier")
proc.send_signal(signal.SIGTERM)
stdout, stderr = proc.communicate(timeout=10)
if proc.returncode == 0:
    raise AssertionError("signaled launcher returned success")
if '"supervision":{"status":"failed","reason":"launch-signal-TERM"' not in stdout:
    raise AssertionError("abort was not confirmed before the failure record: %r %r" % (stdout, stderr))
if '"status":"armed"' in stdout:
    raise AssertionError("pre-arm abort was also reported as armed")
PY
  assert_success

  teardown
  setup
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 STUB_START_CONTEXT=1 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_TEST_WATCHER_RELEASE="$CHILD_STUB/release-watcher" \
    HERDR_CHILD_TEST_LAUNCH_POST_ARM_BARRIER="$CHILD_STUB/post-arm" \
    CHILD_SCRIPT="$HERDR_CHILD" python3 - <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import time

stub = Path(os.environ["CHILD_STUB"])
proc = subprocess.Popen(
    ["bash", os.environ["CHILD_SCRIPT"], "start", "--kind", "claude", "--detach", "--prompt", "test task"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=os.environ.copy())
for _ in range(1000):
    if (stub / "post-arm.ready").exists():
        break
    time.sleep(0.01)
else:
    proc.kill()
    raise AssertionError("launcher did not reach the post-arm barrier")
proc.send_signal(signal.SIGTERM)
stdout, stderr = proc.communicate(timeout=10)
if proc.returncode == 0:
    raise AssertionError("signaled launcher returned success")
if '"supervision":{"status":"armed"' not in stdout:
    raise AssertionError("confirmed watcher arm was not reported: %r %r" % (stdout, stderr))
if '"status":"failed"' in stdout:
    raise AssertionError("confirmed watcher arm was falsely reported as failed")
(stub / "release-watcher").touch()
PY
  assert_success
}

function test_scripts_034_herdr_child_detached_watcher_ignores_stale_settl() {
  _bats_test_init 34 'herdr-child detached watcher ignores stale settlement and delivers a fresh observed outcome'
  child_lifecycle_stub_herdr
  printf 'idle 10\n' > "$CHILD_STUB/child-state"

  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  child_wait_for_get_count 3
  run grep 'event=' "$CHILD_STUB/calls.log"
  assert_failure

  printf 'done 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'event=settled-11'
  run grep -c 'event=settled-11' "$CHILD_STUB/calls.log"
  assert_success
  assert_output 1
  assert_file_contains "$CHILD_STUB/calls.log" 'not\ a\ task-success\ verdict'
  run grep -Eiq 'task_succeeded=true|task completed successfully' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_035_herdr_child_detached_timeout_wakes_once_and_late() {
  _bats_test_init 35 'herdr-child detached timeout wakes once and later settlement wakes the same generation'
  child_lifecycle_stub_herdr

  run child_lifecycle_start --supervision-timeout 50
  assert_success
  child_wait_for_log 'event=timeout'
  run grep -c 'event=timeout' "$CHILD_STUB/calls.log"
  assert_success
  assert_output 1
  assert_file_not_exists "$CHILD_STUB/pane-closed"

  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'event=settled-11'
  run grep 'event=' "$CHILD_STUB/calls.log"
  assert_line --partial 'event=timeout'
  assert_line --partial 'event=settled-11'
  run grep -c 'event=' "$CHILD_STUB/calls.log"
  assert_success
  assert_output 2
}

function test_scripts_036_herdr_child_detached_delivery_follows_parent_ter() {
  _bats_test_init 36 'herdr-child detached delivery follows parent terminal identity and fails closed on session replacement'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  printf 'wT:p7\n' > "$CHILD_STUB/parent-pane"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'agent prompt wT:p7.*event=settled-11'
  run grep -q 'agent prompt wT:p0.*event=' "$CHILD_STUB/calls.log"
  assert_failure

  teardown
  setup
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  printf 'replaced-session\n' > "$CHILD_STUB/parent-session"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'parent-session-mismatch'
  run grep -q 'event=' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_037_herdr_child_detached_delivery_retries_temporary() {
  _bats_test_init 37 'herdr-child detached delivery retries temporary parent blockage and prompt transport failure'
  child_lifecycle_stub_herdr
  printf 'blocked\n' > "$CHILD_STUB/parent-status"
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  local attempt=0
  while [ ! -e "$CHILD_STUB/parent-blocked-observed" ] && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$CHILD_STUB/parent-blocked-observed"
  assert_file_not_exists "$CHILD_STUB/successful-prompts.log"
  printf 'working\n' > "$CHILD_STUB/parent-status"
  child_wait_for_log 'event=settled-11'
  run grep -c 'event=settled-11' "$CHILD_STUB/successful-prompts.log"
  assert_success
  assert_output 1

  teardown
  setup
  child_lifecycle_stub_herdr
  printf '1\n' > "$CHILD_STUB/prompt-fail-count"
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'event=settled-11'
  attempt=0
  while [ ! -s "$CHILD_STUB/successful-prompts.log" ] && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$CHILD_STUB/successful-prompts.log"
  run grep -c 'event=settled-11' "$CHILD_STUB/successful-prompts.log"
  assert_success
  assert_output 1
}

function test_scripts_038_herdr_child_detached_delivery_uses_capped_increa() {
  _bats_test_init 38 'herdr-child detached delivery uses capped increasing retry backoff and one terminal failure'
  child_lifecycle_stub_herdr
  export HERDR_CHILD_MAX_DELIVERY_RETRIES=4
  export HERDR_CHILD_TEST_RETRY_LOG="$CHILD_STUB/retry.log"
  printf '20\n' > "$CHILD_STUB/prompt-fail-count"
  run child_lifecycle_start --supervision-timeout 5000
  assert_success

  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'supervision_failure_reason=prompt-error'
  run cat "$CHILD_STUB/retry.log"
  assert_success
  assert_output $'1\n2\n4'
  run grep -c 'supervision_failure_reason=prompt-error' "$CHILD_STUB/calls.log"
  assert_success
  assert_output 1
}

function test_scripts_039_herdr_child_transient_pane_reads_never_become_ch() {
  _bats_test_init 39 'herdr-child transient pane reads never become child-gone and delivery continues'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success

  : > "$CHILD_STUB/pane-get-transient-next"
  child_wait_for_file "$CHILD_STUB/pane-get-transient-observed"
  rm -f "$CHILD_STUB/pane-get-transient-observed"
  : > "$CHILD_STUB/pane-transient-after-settlement"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/pane-get-transient-observed"
  child_wait_for_log 'event=settled-11'
  run grep -q 'event=child-gone' "$CHILD_STUB/calls.log"
  assert_failure
  run grep -c 'event=settled-11' "$CHILD_STUB/successful-prompts.log"
  assert_success
  assert_output 1
}

function test_scripts_040_herdr_child_superseded_watcher_cannot_publish_fa() {
  _bats_test_init 40 'herdr-child superseded watcher cannot publish failure metadata over a new generation'
  child_lifecycle_stub_herdr
  local old_generation old_run new_generation watcher_pid new_watcher_pid reply_pid reply_status attempt=0
  export HERDR_CHILD_TEST_FAILURE_PUBLISH_BARRIER="$CHILD_STUB/failure-publish"
  export HERDR_CHILD_TEST_NOW_SEQ=100
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  old_generation="$(cat "$CHILD_STUB/generation")"
  old_run="$CHILD_STUB/state/runs/$old_generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  printf 'new-generation\n' > "$CHILD_STUB/generation"
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_dir_not_exists "$old_run"

  teardown
  setup
  child_lifecycle_stub_herdr
  export HERDR_CHILD_TEST_FAILURE_PUBLISH_BARRIER="$CHILD_STUB/failure-publish"
  export HERDR_CHILD_TEST_NOW_SEQ=100
  export HERDR_CHILD_MAX_DELIVERY_RETRIES=1
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  old_generation="$(cat "$CHILD_STUB/generation")"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  attempt=0

  printf '12\n' > "$CHILD_STUB/prompt-fail-count"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/failure-publish.ready"
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/new-watcher.pid" \
    HERDR_CHILD_TEST_TAKEOVER_METADATA_PUBLISHED="$CHILD_STUB/takeover-metadata-published" \
    HERDR_CHILD_POLL_INTERVAL=0.01 HERDR_CHILD_RETRY_INTERVAL=0.01 \
    bash "$HERDR_CHILD" reply --to orange-panda --pane wT:p9 "Use path A" \
    >"$CHILD_STUB/reply.out" 2>"$CHILD_STUB/reply.err" &
  reply_pid=$!
  printf '%s\n' "$reply_pid" > "$CHILD_STUB/reply.pid"
  child_wait_for_file "$CHILD_STUB/takeover-metadata-published"
  : > "$CHILD_STUB/failure-publish.release"
  if wait "$reply_pid"; then reply_status=0; else reply_status=$?; fi
  assert_equal 0 "$reply_status"
  new_generation="$(cat "$CHILD_STUB/generation")"
  run test "$new_generation" != "$old_generation"
  assert_success
  run grep -q 'supervision_failure_reason=prompt-error' "$CHILD_STUB/calls.log"
  assert_failure
  assert_file_not_exists "$CHILD_STUB/failure-label"
  assert_file_not_exists "$CHILD_STUB/failure-reason"
  assert_file_not_exists "$CHILD_STUB/failure-generation"
  assert_file_not_exists "$CHILD_STUB/failure-diagnostic"
  wait "$watcher_pid" 2>/dev/null || true
  printf 'done 12\n' > "$CHILD_STUB/child-state"
  child_wait_for_log "generation=$new_generation.*event=settled-12"
  new_watcher_pid="$(cat "$CHILD_STUB/new-watcher.pid")"
  while kill -0 "$new_watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  run kill -0 "$new_watcher_pid"
  assert_failure
}

function test_scripts_041_herdr_child_watcher_switches_from_fresh_polling() {
  _bats_test_init 41 'herdr-child watcher switches from fresh polling to sliced agent wait'
  child_lifecycle_stub_herdr
  : > "$CHILD_STUB/wait-block"
  run child_lifecycle_start --supervision-timeout 60000
  assert_success

  printf 'working 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/fresh-working-observed"
  child_wait_for_file "$CHILD_STUB/wait-observed"
  local wait_line refresh_line
  assert_file_contains "$CHILD_STUB/calls.log" 'agent wait wT:p9 --timeout 30000'

  printf 'idle 12\n' > "$CHILD_STUB/child-state"
  : > "$CHILD_STUB/wait-release"
  child_wait_for_log 'event=settled-12'
  wait_line="$(grep -n '^agent wait' "$CHILD_STUB/calls.log" | cut -d: -f1 | head -1)"
  refresh_line="$(grep -n 'state-label supervised=' "$CHILD_STUB/calls.log" | cut -d: -f1 | tail -1)"
  [ "$refresh_line" -gt "$wait_line" ]
}

function test_scripts_042_herdr_child_sliced_wait_revalidates_generation_b() {
  _bats_test_init 42 'herdr-child sliced wait revalidates generation before liveness refresh'
  child_lifecycle_stub_herdr
  : > "$CHILD_STUB/wait-block"
  run child_lifecycle_start --supervision-timeout 60000
  assert_success
  local old_generation old_run watcher_pid attempt=0 wait_line
  old_generation="$(cat "$CHILD_STUB/generation")"
  old_run="$CHILD_STUB/state/runs/$old_generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"

  printf 'working 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/wait-observed"
  wait_line="$(grep -n '^agent wait' "$CHILD_STUB/calls.log" | cut -d: -f1 | head -1)"
  printf 'new-generation\n' > "$CHILD_STUB/generation"
  : > "$CHILD_STUB/wait-release"
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  assert_dir_not_exists "$old_run"
  run bash -c 'line=$1; file=$2; ! sed -n "$((line + 1)),\$p" "$file" | grep -q "state-label supervised="' _ \
    "$wait_line" "$CHILD_STUB/calls.log"
  assert_success
}

function test_scripts_043_herdr_child_sliced_wait_publishes_one_typed_non() {
  _bats_test_init 43 'herdr-child sliced wait publishes one typed non-timeout failure'
  child_lifecycle_stub_herdr
  : > "$CHILD_STUB/wait-error"
  run child_lifecycle_start --supervision-timeout 60000
  assert_success

  printf 'working 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/wait-observed"
  child_wait_for_log 'supervision_failure_reason=wait-error'
  run grep -c 'supervision_failure_reason=wait-error' "$CHILD_STUB/calls.log"
  assert_success
  assert_output 1
}

function test_scripts_044_herdr_child_detached_watcher_rejects_malformed_s() {
  _bats_test_init 44 'herdr-child detached watcher rejects malformed state and child identity replacement'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  : > "$CHILD_STUB/malformed-state"
  child_wait_for_log 'malformed-state'
  run grep -q 'event=' "$CHILD_STUB/calls.log"
  assert_failure

  teardown
  setup
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  printf 'replacement-session\n' > "$CHILD_STUB/child-session"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  local watcher_pid attempt=0
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  run grep -q 'event=' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_045_herdr_child_reap_invalidates_before_close_while() {
  _bats_test_init 45 'herdr-child reap invalidates before close while spontaneous loss wakes the parent'
  # The deadline is not what this scenario proves; keep it out of reach so a
  # loaded run cannot race reap (issues 2026-08-29-004, 2026-08-30-001).
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/require-reap-invalidation"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reap --to orange-panda --pane wT:p9
  assert_success
  assert_file_exists "$CHILD_STUB/reap-invalidation-observed"
  assert_file_not_exists "$CHILD_STUB/close-before-invalidation"
  assert_file_exists "$CHILD_STUB/pane-closed"
  run grep -q 'event=child-gone' "$CHILD_STUB/calls.log"
  assert_failure

  teardown
  setup
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  : > "$CHILD_STUB/child-gone"
  child_wait_for_log 'event=child-gone'
  run grep -c 'event=child-gone' "$CHILD_STUB/calls.log"
  assert_success
  assert_output 1
}

function test_scripts_046_herdr_child_failed_reap_restores_supervision_for() {
  _bats_test_init 46 'herdr-child failed or stale reap restores supervision for the kept child'
  child_lifecycle_stub_herdr
  HERDR_CHILD_TEST_REAP_OWNER_VERIFIED="$CHILD_STUB/reap-owner-verified"
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  local generation run_dir watcher_pid reap_pid attempt=0
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/block-agent-get"
  : > "$CHILD_STUB/block-pane-close"
  : > "$CHILD_STUB/observe-reap-invalidation"
  : > "$CHILD_STUB/close-fail"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/agent-get.ready"

  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reap --to orange-panda --pane wT:p9 >"$CHILD_STUB/reap.out" 2>&1 &
  reap_pid=$!
  child_wait_for_file "$CHILD_STUB/pane-close.ready"
  assert_file_contains "$run_dir/invalidated.state" '^reason=reap$'
  : > "$CHILD_STUB/agent-get.release"
  child_wait_for_file "$CHILD_STUB/reap-invalidation-consumed"
  child_wait_for_file "$CHILD_STUB/reap-owner-verified"
  assert_file_exists "$run_dir/invalidated.state"
  assert_file_not_exists "$CHILD_STUB/parent-prompt-accepted"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reap --to orange-panda --pane wT:p9
  assert_success
  assert_output --partial 'supervision generation could not be invalidated'
  assert_file_exists "$run_dir/invalidated.state"
  : > "$CHILD_STUB/block-reap-pane-get"
  child_wait_for_file "$CHILD_STUB/reap-pane-get.ready"
  : > "$CHILD_STUB/block-parent-prompt"
  : > "$CHILD_STUB/pane-close.release"
  if ! wait "$reap_pid"; then
    cat "$CHILD_STUB/reap.out" >&2
    return 1
  fi
  assert_file_contains "$CHILD_STUB/reap.out" 'supervision recovery requested'
  assert_file_not_exists "$CHILD_STUB/pane-closed"
  : > "$CHILD_STUB/reap-pane-get.release"
  while [ -f "$run_dir/invalidated.state" ] && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  child_wait_for_file "$CHILD_STUB/parent-prompt-accepted"
  kill -0 "$watcher_pid"

  : > "$CHILD_STUB/release-parent-prompt"
  child_wait_for_file "$CHILD_STUB/successful-prompts.log"
  run grep -c 'event=settled-11' "$CHILD_STUB/successful-prompts.log"
  assert_success
  assert_output 1
  run grep -q 'event=child-gone' "$CHILD_STUB/calls.log"
  assert_failure

  teardown
  setup
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  : > "$CHILD_STUB/block-agent-get"
  : > "$CHILD_STUB/block-parent-prompt"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/agent-get.ready"

  local stale_token=00000000000000000000000000000001
  printf 'status=pending\nowner_pid=%s\nowner_token=%s\n' "$$" "$stale_token" > "$run_dir/reap-pending.state"
  printf 'reason=reap\n' > "$run_dir/invalidated.state"
  : > "$run_dir/reap-owner-$stale_token.gone"
  : > "$CHILD_STUB/agent-get.release"
  attempt=0
  while [ -f "$run_dir/invalidated.state" ] && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  child_wait_for_file "$CHILD_STUB/parent-prompt-accepted"
  kill -0 "$watcher_pid"

  : > "$CHILD_STUB/release-parent-prompt"
  child_wait_for_file "$CHILD_STUB/successful-prompts.log"
  run grep -c 'event=settled-11' "$CHILD_STUB/successful-prompts.log"
  assert_success
  assert_output 1
}

function test_scripts_047_herdr_child_detached_ask_follows_parent_identity() {
  _bats_test_init 47 'herdr-child detached ask follows parent identity and suppresses its ordinary blocked wake'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  local generation watcher_pid attempt=0
  generation="$(cat "$CHILD_STUB/generation")"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  printf 'wT:p7\n' > "$CHILD_STUB/parent-pane"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_NAME=orange-panda \
    HERDR_CHILD_PARENT_PANE=wT:p0 HERDR_CHILD_PARENT_TERMINAL=term-parent \
    HERDR_CHILD_PARENT_SESSION=parent-session \
    bash "$HERDR_CHILD" ask "Which path?"
  assert_success
  assert_file_contains "$CHILD_STUB/successful-prompts.log" "generation=$generation"
  assert_file_contains "$CHILD_STUB/successful-prompts.log" 'event=callback-'

  printf 'blocked 11\n' > "$CHILD_STUB/child-state"
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  run grep -q 'event=blocked-11' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_048_herdr_child_attached_ask_follows_captured_parent() {
  _bats_test_init 48 'herdr-child attached ask follows captured parent identity after the parent moves'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p7","terminal_id":"term-parent","revision":1,"state_change_seq":1,"agent_session":{"value":"parent-session"}},{"name":"orange-panda","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 \
    HERDR_PANE_ID=wT:p9 HERDR_CHILD_NAME=orange-panda HERDR_CHILD_PARENT_PANE=wT:p0 \
    HERDR_CHILD_LAUNCH_MODE=wait HERDR_CHILD_PARENT_TERMINAL=term-parent \
    HERDR_CHILD_PARENT_SESSION=parent-session \
    bash "$HERDR_CHILD" ask "Which path?"
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent prompt wT:p7.*child-ask\ v1'
  run grep -q 'agent prompt wT:p0' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_049_herdr_child_callback_intent_suppresses_blocked_w() {
  _bats_test_init 49 'herdr-child callback intent suppresses blocked wake until confirmed receipt'
  child_lifecycle_stub_herdr
  export HERDR_CHILD_TEST_CALLBACK_RECEIPT_BARRIER="$CHILD_STUB/callback-receipt"
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  local generation run_dir ask_pid watcher_pid attempt=0
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"

  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_NAME=orange-panda \
    HERDR_CHILD_PARENT_PANE=wT:p0 HERDR_CHILD_PARENT_TERMINAL=term-parent \
    HERDR_CHILD_PARENT_SESSION=parent-session \
    bash "$HERDR_CHILD" ask "Which path?" >"$CHILD_STUB/ask.out" 2>"$CHILD_STUB/ask.err" &
  ask_pid=$!
  child_wait_for_file "$CHILD_STUB/callback-receipt.ready"
  assert_file_contains "$run_dir/callback.state" '^status=in-progress$'
  assert_file_contains "$CHILD_STUB/successful-prompts.log" 'event=callback-'

  printf 'blocked 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/blocked-observed"
  run grep -q 'event=blocked-11' "$CHILD_STUB/calls.log"
  assert_failure
  kill -0 "$watcher_pid"

  : > "$CHILD_STUB/callback-receipt.release"
  wait "$ask_pid"
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  run grep -q 'event=blocked-11' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_050_herdr_child_callback_delivery_exhaustion_keeps_d() {
  _bats_test_init 50 'herdr-child callback delivery exhaustion keeps decision waiting and blocks reap'
  local generation run_dir
  child_lifecycle_stub_herdr
  export HERDR_CHILD_MAX_DELIVERY_RETRIES=3
  printf '20\n' > "$CHILD_STUB/prompt-fail-count"
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  run cat "$CHILD_STUB/generation"
  assert_success
  generation="$output"
  run_dir="$CHILD_STUB/state/runs/$generation"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_NAME=orange-panda \
    HERDR_CHILD_PARENT_PANE=wT:p0 HERDR_CHILD_PARENT_TERMINAL=term-parent \
    HERDR_CHILD_PARENT_SESSION=parent-session \
    bash "$HERDR_CHILD" ask "Which path?"
  assert_failure
  assert_file_exists "$CHILD_STUB/waiting-label"

  printf 'blocked 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$run_dir/failed.state"
  run grep -qx 'reason=prompt-error' "$run_dir/failed.state"
  assert_success
  assert_file_exists "$CHILD_STUB/waiting-label"
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reap --to orange-panda --pane wT:p9
  assert_success
  assert_output --partial 'has a waiting state label'
  assert_file_not_exists "$CHILD_STUB/pane-closed"
}

function test_scripts_051_herdr_child_detached_callbacks_fail_closed_when() {
  _bats_test_init 51 'herdr-child detached callbacks fail closed when supervision metadata is unreadable'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  rm -f "$CHILD_STUB/generation"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_NAME=orange-panda \
    HERDR_CHILD_PARENT_PANE=wT:p0 HERDR_CHILD_PARENT_TERMINAL=term-parent \
    HERDR_CHILD_PARENT_SESSION=parent-session \
    bash "$HERDR_CHILD" ask "Which path?"
  assert_failure
  assert_output --partial 'detached child metadata is unavailable'
  assert_file_not_exists "$CHILD_STUB/successful-prompts.log"

  teardown
  setup
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  : > "$CHILD_STUB/pane-malformed"
  local prompts_before
  prompts_before="$(grep -c '^agent prompt' "$CHILD_STUB/calls.log")"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reply --to orange-panda --pane wT:p9 "Use path A"
  assert_failure
  assert_output --partial 'pane metadata was malformed'
  run grep -c '^agent prompt' "$CHILD_STUB/calls.log"
  assert_output "$prompts_before"
}

function test_scripts_052_herdr_child_detached_reply_advances_generation_a() {
  _bats_test_init 52 'herdr-child detached reply advances generation and rearms later settlement'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  local old_generation new_generation
  old_generation="$(cat "$CHILD_STUB/generation")"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'event=settled-11'

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_POLL_INTERVAL=0.01 HERDR_CHILD_RETRY_INTERVAL=0.01 \
    bash "$HERDR_CHILD" reply --to orange-panda --pane wT:p9 "Use path A"
  assert_success
  new_generation="$(cat "$CHILD_STUB/generation")"
  [ "$new_generation" != "$old_generation" ]
  assert_output --partial '"supervision":{"status":"armed"'

  printf 'idle 12\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'event=settled-12'
  assert_file_contains "$CHILD_STUB/calls.log" "generation=$new_generation.*event=settled-12"
}

function test_scripts_053_herdr_child_managed_prompt_requires_a_mode_and_a() {
  _bats_test_init 53 'herdr-child managed prompt requires a mode and attached wait observes a newer sequence'
  child_lifecycle_stub_herdr
  printf 'orange-panda' > "$CHILD_STUB/started-name"
  : > "$CHILD_STUB/advance-on-prompt"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" prompt --to orange-panda --pane wT:p9 "next task"
  assert_failure 2
  assert_output --partial 'exactly one of --wait or --detach'

  : > "$CHILD_STUB/calls.log"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" prompt --to orange-panda --pane wT:p9 --wait --timeout 1000 "next task"
  assert_success
  assert_output --partial 'Prompt completed for orange-panda in wT:p9.'
  run grep -q 'state-label supervised=' "$CHILD_STUB/calls.log"
  assert_failure
  assert_file_not_exists "$CHILD_STUB/watcher.pid"
}

function test_scripts_054_herdr_child_attached_prompt_wait_rejects_the_fir() {
  _bats_test_init 54 'herdr-child attached prompt wait rejects the first one-step settlement after a working baseline'
  child_lifecycle_stub_herdr
  printf 'orange-panda' > "$CHILD_STUB/started-name"
  printf 'working 10\n' > "$CHILD_STUB/baseline-state"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"

  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_POLL_INTERVAL=0.01 \
    bash "$HERDR_CHILD" prompt --to orange-panda --pane wT:p9 --wait --timeout 5000 \
    "sequence-sensitive task" >"$CHILD_STUB/prompt.out" 2>"$CHILD_STUB/prompt.err" &
  local prompt_pid=$!
  child_wait_for_get_count 3
  kill -0 "$prompt_pid"

  printf 'working 12\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/fresh-working-observed"
  printf 'idle 13\n' > "$CHILD_STUB/child-state"
  wait "$prompt_pid"
  assert_file_contains "$CHILD_STUB/prompt.out" 'Prompt completed for orange-panda in wT:p9.'
}

function test_scripts_055_herdr_child_managed_detached_prompt_advances_gen() {
  _bats_test_init 55 'herdr-child managed detached prompt advances generation, invalidates the old watcher, and preserves the child on rearm failure'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  local old_generation new_generation
  old_generation="$(cat "$CHILD_STUB/generation")"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'event=settled-11'

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_POLL_INTERVAL=0.01 HERDR_CHILD_RETRY_INTERVAL=0.01 \
    bash "$HERDR_CHILD" prompt --to orange-panda --pane wT:p9 --detach \
    --supervision-timeout 5000 "ordinary follow-up"
  assert_success
  new_generation="$(cat "$CHILD_STUB/generation")"
  [ "$new_generation" != "$old_generation" ]
  run cat "$CHILD_STUB/state/runs/$new_generation/launch.state"
  assert_success
  assert_output "$(printf '%s\n' 'mode=detach' "generation=$new_generation" 'timeout_ms=5000' \
    'parent_pane=wT:p0' 'parent_terminal=term-parent' 'parent_session=parent-session' \
    'child_name=orange-panda' 'child_pane=wT:p9' 'child_terminal=term-child' \
    'child_session=child-session' 'baseline_seq=11')"
  printf 'done 12\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'event=settled-12'

  teardown
  setup
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  old_generation="$(cat "$CHILD_STUB/generation")"
  local old_run="$CHILD_STUB/state/runs/$old_generation"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_TEST_ARM_FAIL=1 HERDR_CHILD_POLL_INTERVAL=0.01 \
    bash "$HERDR_CHILD" prompt --to orange-panda --pane wT:p9 --detach \
    --supervision-timeout 5000 "ordinary follow-up"
  assert_failure
  assert_output --partial '"supervision":{"status":"failed","reason":"watcher-arm-failed"'
  [ ! -d "$old_run" ] || [ -f "$old_run/invalidated.state" ]
  run cat "$CHILD_STUB/generation"
  assert_success
  refute_output "$old_generation"
  assert_file_not_exists "$CHILD_STUB/pane-closed"

  teardown
  setup
  child_lifecycle_stub_herdr
  HERDR_CHILD_TEST_WATCHER_RELEASE="$CHILD_STUB/release-watcher" \
    HERDR_CHILD_TEST_HOLD_TIMEOUT_SECONDS=120 \
    run child_lifecycle_start --supervision-timeout 5000
  assert_success
  old_generation="$(cat "$CHILD_STUB/generation")"
  old_run="$CHILD_STUB/state/runs/$old_generation"
  local old_watcher old_watcher_identity attempt=0
  old_watcher="$(cat "$CHILD_STUB/watcher.pid")"
  kill -0 "$old_watcher"
  old_watcher_identity="$(LC_ALL=C /bin/ps -o lstart= -o command= -p "$old_watcher")"
  case "$old_watcher_identity" in
    *"$HERDR_CHILD __watcher"*"--run-dir $old_run"*) ;;
    *) printf 'old watcher identity was not observable: %s\n' "$old_watcher_identity" >&2; return 1 ;;
  esac
  old_watcher_is_alive() {
    local current_identity
    current_identity="$(LC_ALL=C /bin/ps -o lstart= -o command= -p "$old_watcher" 2>/dev/null)" || return 1
    [ "$current_identity" = "$old_watcher_identity" ]
  }
  assert_dir_exists "$old_run"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/new-watcher.pid" \
    HERDR_CHILD_TEST_WATCHER_RELEASE="$CHILD_STUB/release-watcher" \
    HERDR_CHILD_TEST_HOLD_TIMEOUT_SECONDS=120 HERDR_CHILD_POLL_INTERVAL=0.01 \
    bash "$HERDR_CHILD" prompt --to orange-panda --pane wT:p9 --detach \
    --supervision-timeout 5000 "take over held watcher"
  assert_success
  assert_file_not_exists "$CHILD_STUB/release-watcher"
  while { old_watcher_is_alive || [ -d "$old_run" ]; } && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  if [ "$attempt" -ge 500 ]; then
    old_watcher_is_alive && printf 'stale watcher identity retained: %s\n' "$old_watcher" >&2
    [ ! -d "$old_run" ] || printf 'stale watcher run directory retained: %s\n' "$old_run" >&2
    return 1
  fi
  run old_watcher_is_alive
  assert_failure
  assert_dir_not_exists "$old_run"
  assert_file_not_exists "$CHILD_STUB/release-watcher"
  rm -f "$CHILD_STUB/watcher.pid"
}

function test_scripts_056_herdr_child_continuation_preflight_failures_pres() {
  _bats_test_init 56 'herdr-child continuation preflight failures preserve the prior generation'
  local old_generation old_run old_watcher

  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  old_generation="$(cat "$CHILD_STUB/generation")"
  old_run="$CHILD_STUB/state/runs/$old_generation"
  old_watcher="$(cat "$CHILD_STUB/watcher.pid")"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_TEST_BASELINE_FAIL=1 \
    bash "$HERDR_CHILD" prompt --to orange-panda --pane wT:p9 --detach "next task"
  assert_failure
  assert_output --partial 'baseline state could not be read'
  assert_file_not_exists "$old_run/invalidated.state"
  run cat "$CHILD_STUB/generation"
  assert_output "$old_generation"
  kill -0 "$old_watcher"

  teardown
  setup
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  old_generation="$(cat "$CHILD_STUB/generation")"
  old_run="$CHILD_STUB/state/runs/$old_generation"
  old_watcher="$(cat "$CHILD_STUB/watcher.pid")"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_TEST_SETUP_FAIL=1 \
    bash "$HERDR_CHILD" prompt --to orange-panda --pane wT:p9 --detach "next task"
  assert_failure
  assert_output --partial 'setup failed before supervision takeover'
  assert_file_not_exists "$old_run/invalidated.state"
  run cat "$CHILD_STUB/generation"
  assert_output "$old_generation"
  kill -0 "$old_watcher"

  teardown
  setup
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  old_generation="$(cat "$CHILD_STUB/generation")"
  old_run="$CHILD_STUB/state/runs/$old_generation"
  old_watcher="$(cat "$CHILD_STUB/watcher.pid")"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_TEST_PREPARE_FAIL=1 \
    bash "$HERDR_CHILD" prompt --to orange-panda --pane wT:p9 --detach "next task"
  assert_failure
  assert_output --partial 'watcher failed before supervision takeover'
  assert_file_not_exists "$old_run/invalidated.state"
  run cat "$CHILD_STUB/generation"
  assert_output "$old_generation"
  kill -0 "$old_watcher"
}

function test_scripts_057_herdr_child_attached_child_promoted_to_detach_as() {
  _bats_test_init 57 'herdr-child attached child promoted to detach asks through validated metadata'
  child_lifecycle_stub_herdr
  printf 'orange-panda' > "$CHILD_STUB/started-name"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_POLL_INTERVAL=0.01 \
    bash "$HERDR_CHILD" prompt --to orange-panda --pane wT:p9 --detach \
    --supervision-timeout 5000 "promote this child"
  assert_success
  local generation
  generation="$(cat "$CHILD_STUB/generation")"
  printf 'wT:p7\n' > "$CHILD_STUB/parent-pane"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_NAME=orange-panda \
    HERDR_CHILD_PARENT_PANE=wT:p0 HERDR_CHILD_LAUNCH_MODE=wait \
    HERDR_CHILD_PARENT_TERMINAL=term-parent HERDR_CHILD_PARENT_SESSION=parent-session \
    bash "$HERDR_CHILD" ask "Which promoted path?"
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent prompt wT:p7.*child-ask\ v2'
  assert_file_contains "$CHILD_STUB/successful-prompts.log" "generation=$generation"
  assert_file_contains "$CHILD_STUB/successful-prompts.log" 'child-ask v2'
}

# Reduce a marker to its field-key skeleton: "[child-ask v2 generation=... pane=x]"
# becomes "[child-ask v2 generation= pane=]", so documented placeholders and
# emitted values compare as one shape.
child_marker_skeleton() {
  sed -E 's/=[^] ]+/=/g' <<<"$1"
}

# The marker lines in child-agent-contract.md are a consumed wire format: parents
# validate [child-supervision v1 ...] and [child-ask v2 ...] bodies field by field,
# so the emitted markers must round-trip the documented shapes.
function test_scripts_058_herdr_child_markers_round_trip_documented_shape() {
  _bats_test_init 58 'herdr-child emitted markers round-trip the documented wire shapes'
  local contract="$SOURCE_ROOT/private_dot_claude/shared/child-agent-contract.md"
  local skill="$SOURCE_ROOT/private_dot_agents/skills/herdr/SKILL.md"
  local consult="$SOURCE_ROOT/private_dot_agents/skills/ask-in-herdr/SKILL.md"

  # #given — a detached child settles, so the watcher prompts the parent
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  printf 'done 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'event=settled-11' "$CHILD_STUB/successful-prompts.log"

  # #then — the delivered supervision marker matches the documented shape
  local emitted documented
  emitted="$(grep -o '\[child-supervision v1 generation=[^]]*\]' "$CHILD_STUB/successful-prompts.log" | head -n1)"
  documented="$(grep -o '\[child-supervision v1 generation=[^]]*\]' "$contract" | head -n1)"
  [ -n "$emitted" ] || fail "no child-supervision marker was delivered to the parent"
  [ -n "$documented" ] || fail "contract no longer documents the child-supervision marker shape"
  assert_equal "$(child_marker_skeleton "$documented")" "$(child_marker_skeleton "$emitted")"
  grep -Eq '^\[child-supervision v1 generation=[^ ]+ event=(timeout|settled-[0-9]+|blocked-[0-9]+|child-gone) outcome=[^ ]+ reason=[^ ]+ agent=[^ ]+ pane=[^] ]+\]$' \
    <<<"$emitted" || fail "supervision marker values break the documented grammar: $emitted"

  # #given — a detached child calls back through ask
  child_lifecycle_stub_herdr
  printf 'orange-panda' > "$CHILD_STUB/started-name"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_POLL_INTERVAL=0.01 \
    bash "$HERDR_CHILD" prompt --to orange-panda --pane wT:p9 --detach \
    --supervision-timeout 5000 "detached task"
  assert_success
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_NAME=orange-panda \
    HERDR_CHILD_PARENT_PANE=wT:p0 HERDR_CHILD_LAUNCH_MODE=wait \
    HERDR_CHILD_PARENT_TERMINAL=term-parent HERDR_CHILD_PARENT_SESSION=parent-session \
    bash "$HERDR_CHILD" ask "Which path?"
  assert_success

  # #then — the delivered callback marker matches the documented shape
  emitted="$(grep -o '\[child-ask v2 generation=[^]]*\]' "$CHILD_STUB/successful-prompts.log" | head -n1)"
  documented="$(grep -o '\[child-ask v2 generation=[^]]*\]' "$contract" | head -n1)"
  [ -n "$emitted" ] || fail "no child-ask v2 marker was delivered to the parent"
  [ -n "$documented" ] || fail "contract no longer documents the child-ask v2 marker shape"
  assert_equal "$(child_marker_skeleton "$documented")" "$(child_marker_skeleton "$emitted")"
  grep -Eq '^\[child-ask v2 generation=[^ ]+ event=callback-[0-9]+ agent=[^ ]+ pane=[^] ]+\]$' \
    <<<"$emitted" || fail "child-ask marker values break the documented grammar: $emitted"

  # #then — every subcommand the docs reference is one the CLI accepts
  local tokens token
  tokens="$(grep -ohE 'herdr-child [a-z][a-z-]*' "$contract" "$skill" "$consult" \
    | awk '{print $2}' | sort -u)"
  [ -n "$tokens" ] || fail "docs reference no herdr-child subcommands; the sync sweep would no-op"
  for token in $tokens; do
    # Without a herdr environment every real subcommand fails for an env
    # reason; only a token the CLI dropped fails with "unknown subcommand".
    run env PATH="$CHILD_STUB:$PATH" HERDR_ENV= HERDR_PANE_ID= bash "$HERDR_CHILD" "$token"
    assert_failure
    refute_output --partial 'unknown subcommand'
  done
}

function test_scripts_060_herdr_child_maps_claude_postures_and_skill_direc() {
  _bats_test_init 60 'herdr-child maps claude postures and skill directories'
  child_stub_herdr
  run child_start --kind claude --skills A --skills B --wait
  assert_success
  assert_output '{"agent":"orange-panda","pane":"wT:p9"}'
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--add-dir A --add-dir B.*--disallowed-tools Edit Write NotebookEdit AskUserQuestion'

  : > "$CHILD_STUB/calls.log"
  run child_start --kind claude --posture rw --wait
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--disallowed-tools AskUserQuestion'
  run grep -q 'disallowed-tools Edit' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_061_herdr_child_maps_opencode_permissions_model_and() {
  _bats_test_init 61 'herdr-child maps opencode permissions, model, and configured agent'
  child_stub_herdr
  run child_start --kind opencode --agent reviewer --wait
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'OPENCODE_PERMISSION=.*question.*deny.*edit.*deny'
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--model openai/gpt-5.5 --agent reviewer'

  : > "$CHILD_STUB/calls.log"
  run child_start --kind opencode --posture rw --wait
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'OPENCODE_PERMISSION=.*question.*deny'
  run grep -q 'OPENCODE_PERMISSION=.*edit' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_062_herdr_child_maps_pi_model_effort_skills_and_ques() {
  _bats_test_init 62 'herdr-child maps pi model, effort, skills, and question exclusion'
  child_stub_herdr
  run child_start --kind pi --posture rw --skills A --skills B --wait
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--exclude-tools ask_user --model openai-codex/gpt-5.5 --thinking medium --skill A --skill B'

  : > "$CHILD_STUB/calls.log"
  run child_start --kind pi --posture rw --model custom/model --effort high --wait
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--model custom/model --thinking high'
}

function test_scripts_063_herdr_child_rejects_native_options_that_the_sele() {
  _bats_test_init 63 'herdr-child rejects native options that the selected kind cannot map'
  child_stub_herdr
  run child_start --kind claude --effort high --wait
  assert_failure 2
  assert_output --partial "--effort is not supported for claude"
  run child_start --kind pi --posture rw --agent reviewer --wait
  assert_failure 2
  assert_output --partial "--agent is not supported for pi"
  run child_start --kind opencode --skills A --wait
  assert_failure 2
  assert_output --partial "--skills is not supported for opencode"
  [ ! -f "$CHILD_STUB/calls.log" ]
}

function test_scripts_064_herdr_child_splits_starts_and_prompts_in_order_w() {
  _bats_test_init 64 'herdr-child splits, starts, and prompts in order with both coordinates'
  child_stub_herdr
  STUB_REQUIRE_SPLIT=1 run child_start --kind claude --wait --timeout 5000
  assert_success
  local call1 call2 call3 call4 call5 call6
  call1="$(sed -n '1p' "$CHILD_STUB/calls.log")"
  call2="$(sed -n '2p' "$CHILD_STUB/calls.log")"
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  call4="$(sed -n '4p' "$CHILD_STUB/calls.log")"
  call5="$(sed -n '5p' "$CHILD_STUB/calls.log")"
  call6="$(sed -n '6p' "$CHILD_STUB/calls.log")"
  [[ "$call1" == agent\ list* ]] || fail "unexpected first herdr-child call: $call1"
  [[ "$call2" == pane\ split*HERDR_CHILD_NAME=orange-panda*HERDR_CHILD_PARENT_PANE=wT:p0* ]] || fail "unexpected second herdr-child call: $call2"
  [[ "$call3" == agent\ start* ]] || fail "unexpected third herdr-child call: $call3"
  [[ "$call4" == agent\ list* ]] || fail "unexpected fourth herdr-child call: $call4"
  [[ "$call5" == pane\ get*wT:p9* ]] || fail "unexpected fifth herdr-child call: $call5"
  [[ "$call6" == agent\ prompt*orange-panda*wT:p9*wT:p0*--wait*--timeout\ 5000* ]] || fail "unexpected sixth herdr-child call: $call6"
}

function test_scripts_065_herdr_child_tab_mode_records_ownership_before_st() {
  _bats_test_init 65 'herdr-child tab mode records ownership before starting an attached child'
  child_stub_herdr
  STUB_REQUIRE_SPLIT=1 HERDR_WORKSPACE_ID=w1 run child_start \
    --kind claude --tab --label mylabel --wait
  assert_success
  assert_output '{"agent":"orange-panda","pane":"wT:p9","tab":"wT:tA"}'
  local call1 call2 call3 call4 call5 call6 call7
  call1="$(sed -n '1p' "$CHILD_STUB/calls.log")"
  call2="$(sed -n '2p' "$CHILD_STUB/calls.log")"
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  call4="$(sed -n '4p' "$CHILD_STUB/calls.log")"
  call5="$(sed -n '5p' "$CHILD_STUB/calls.log")"
  call6="$(sed -n '6p' "$CHILD_STUB/calls.log")"
  call7="$(sed -n '7p' "$CHILD_STUB/calls.log")"
  [[ "$call1" == agent\ list* ]] || fail "unexpected first tab-mode call: $call1"
  [[ "$call2" == tab\ create*--workspace\ w1*HERDR_CHILD_NAME=orange-panda*HERDR_CHILD_PARENT_PANE=wT:p0*--label\ mylabel* ]] || fail "unexpected second tab-mode call: $call2"
  [[ "$call3" == pane\ report-metadata\ wT:p9\ --source\ child-agent-tab*child-tab=wT:tA* ]] || fail "unexpected third tab-mode call: $call3"
  [[ "$call4" == agent\ start* ]] || fail "unexpected fourth tab-mode call: $call4"
  [[ "$call5" == agent\ list* ]] || fail "unexpected fifth tab-mode call: $call5"
  [[ "$call6" == pane\ get*wT:p9* ]] || fail "unexpected sixth tab-mode call: $call6"
  [[ "$call7" == agent\ prompt*--wait* ]] || fail "unexpected seventh tab-mode call: $call7"
}

function test_scripts_066_herdr_child_tab_launch_signal_closes_a_parsed_cr() {
  _bats_test_init 66 'herdr-child tab launch signal closes a parsed creation before ownership publication'
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_WORKSPACE_ID=w1 STUB_START_CONTEXT=1 \
    HERDR_CHILD_TEST_TAB_CREATED_BARRIER="$CHILD_STUB/tab-created" \
    CHILD_SCRIPT="$HERDR_CHILD" python3 - <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import time

stub = Path(os.environ["CHILD_STUB"])
proc = subprocess.Popen(
    ["bash", os.environ["CHILD_SCRIPT"], "start", "--kind", "claude", "--tab", "--wait", "--prompt", "test task"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=os.environ.copy())
for _ in range(1000):
    if (stub / "tab-created.ready").exists():
        break
    time.sleep(0.01)
else:
    proc.kill()
    raise AssertionError("launcher did not reach the post-create ownership barrier")
proc.send_signal(signal.SIGTERM)
stdout, stderr = proc.communicate(timeout=10)
if proc.returncode == 0:
    raise AssertionError("signaled tab launcher returned success")
calls = (stub / "calls.log").read_text()
if "pane close wT:p9" not in calls:
    raise AssertionError("owned tab root pane was not closed: %s" % calls)
if "pane report-metadata" in calls or "agent start" in calls:
    raise AssertionError("signal crossed the ownership publication barrier: %s" % calls)
if "manual cleanup" in stderr:
    raise AssertionError("parseable identity was reported as unknown: %s" % stderr)
PY
  assert_success
}

function test_scripts_067_herdr_child_tab_mode_composes_with_detached_supe() {
  _bats_test_init 67 'herdr-child tab mode composes with detached supervision'
  child_lifecycle_stub_herdr
  HERDR_WORKSPACE_ID=w1 run child_lifecycle_start --tab --supervision-timeout 5000
  assert_success
  assert_output --partial '"tab":"wT:tA"'
  assert_output --partial '"supervision":{"status":"armed"'
  assert_file_contains "$CHILD_STUB/calls.log" '^tab create --workspace w1'
  assert_file_contains "$CHILD_STUB/calls.log" 'pane report-metadata wT:p9 --source child-agent-tab.*child-tab=wT:tA'
  assert_file_contains "$CHILD_STUB/calls.log" 'pane report-metadata wT:p9 --source child-agent.*child_mode=detach'
}

function test_scripts_068_herdr_child_tab_mode_preserves_malformed_creatio() {
  _bats_test_init 68 'herdr-child tab mode preserves malformed creations and cleans owned failures'
  child_stub_herdr
  STUB_TAB_CREATE_MALFORMED=1 HERDR_WORKSPACE_ID=w1 run child_start \
    --kind claude --tab --wait
  assert_failure 1
  assert_output --partial "tab wT:tA was preserved"
  run grep -Eq '^(pane report-metadata|agent start|pane close)' "$CHILD_STUB/calls.log"
  assert_failure

  teardown
  setup
  child_stub_herdr
  STUB_REPORT_FAIL=1 HERDR_WORKSPACE_ID=w1 run child_start \
    --kind claude --tab --wait
  assert_failure 1
  assert_output --partial "could not record tab ownership"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
  run grep -q '^agent start' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_069_herdr_child_tab_mode_reports_the_tab_on_timeout() {
  _bats_test_init 69 'herdr-child tab mode reports the tab on timeout and names it on launch failure'
  child_stub_herdr
  STUB_PROMPT_TIMEOUT=1 HERDR_WORKSPACE_ID=w1 run child_start \
    --kind claude --tab --wait
  assert_failure 124
  assert_output --partial '{"agent":"orange-panda","pane":"wT:p9","tab":"wT:tA"}'
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure

  teardown
  setup
  child_stub_herdr
  STUB_START_MODE=busy HERDR_WORKSPACE_ID=w1 run child_start \
    --kind claude --tab --wait
  assert_failure
  assert_output --partial "three agent start attempts (tab wT:tA)"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

function test_scripts_070_herdr_child_caps_startup_timeout_while_preservin() {
  _bats_test_init 70 'herdr-child caps startup timeout while preserving a long prompt wait'
  child_stub_herdr
  run child_start --kind claude --wait --timeout 1800000
  assert_success
  local start_call prompt_call
  start_call="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  prompt_call="$(grep '^agent prompt' "$CHILD_STUB/calls.log")"
  [[ "$start_call" == *--timeout\ 300000* ]] || fail "startup timeout was not capped: $start_call"
  [[ "$prompt_call" == *--timeout\ 1800000* ]] || fail "prompt timeout was not preserved: $prompt_call"
}

function test_scripts_071_herdr_child_retries_only_the_pane_readiness_star() {
  _bats_test_init 71 'herdr-child retries only the pane-readiness start failure'
  child_stub_herdr
  STUB_START_MODE=busy-once run child_start --kind claude --wait
  assert_success
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 2

  child_stub_herdr
  STUB_START_MODE=error run child_start --kind claude --wait
  assert_failure
  assert_output --partial "agent start failed"
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 1
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

function test_scripts_072_herdr_child_closes_its_pane_after_three_readines() {
  _bats_test_init 72 'herdr-child closes its pane after three readiness failures'
  child_stub_herdr
  STUB_START_MODE=busy run child_start --kind claude --wait
  assert_failure
  assert_output --partial "three agent start attempts"
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 3
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

function test_scripts_073_herdr_child_distinguishes_a_stalled_initial_prom() {
  _bats_test_init 73 'herdr-child distinguishes a stalled initial prompt'
  child_stub_herdr
  STUB_PROMPT_FAIL=1 run child_start --kind claude --wait
  assert_failure
  assert_output --partial "initial prompt stalled"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

function test_scripts_074_herdr_child_preserves_a_working_pane_when_the_wa() {
  _bats_test_init 74 'herdr-child preserves a working pane when the wait times out'
  child_stub_herdr
  STUB_PROMPT_TIMEOUT=1 run child_start --kind claude --wait
  assert_failure 124
  assert_output --partial '{"agent":"orange-panda","pane":"wT:p9"}'
  assert_output --partial "wait timed out"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_075_herdr_child_ask_requires_every_injected_child_co() {
  _bats_test_init 75 'herdr-child ask requires every injected child coordinate'
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_NAME=orange-panda bash "$HERDR_CHILD" ask question
  assert_failure
  assert_output --partial "HERDR_CHILD_PARENT_PANE is missing"
  [ ! -f "$CHILD_STUB/calls.log" ]
}

function test_scripts_076_herdr_child_ask_publishes_before_delivery_and_us() {
  _bats_test_init 76 'herdr-child ask publishes before delivery and uses the versioned marker'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p0","terminal_id":"term-parent","revision":1,"state_change_seq":1},{"name":"orange-panda","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 \
    HERDR_PANE_ID=wT:p9 HERDR_CHILD_NAME=orange-panda HERDR_CHILD_PARENT_PANE=wT:p0 \
    bash "$HERDR_CHILD" ask "Which path?"
  assert_success
  local call1 call2 call3 call4
  call1="$(sed -n '1p' "$CHILD_STUB/calls.log")"
  call2="$(sed -n '2p' "$CHILD_STUB/calls.log")"
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  call4="$(sed -n '4p' "$CHILD_STUB/calls.log")"
  [[ "$call1" == pane\ report-metadata*wT:p9*--source\ child-agent*--state-label*--ttl-ms\ 3600000* ]] || fail "waiting label was not published first: $call1"
  [[ "$call2" == agent\ list* ]] || fail "live aliases were not read second: $call2"
  [[ "$call3" == pane\ get*wT:p9* ]] || fail "child metadata was not read third: $call3"
  [[ "$call4" == agent\ prompt*wT:p0*child-ask*agent=orange-panda*pane=wT:p9* ]] || fail "callback was not delivered fourth: $call4"
  [[ "$call4" != *--wait* ]] || fail "callback delivery unexpectedly waited: $call4"
}

function test_scripts_077_herdr_child_ask_leaves_the_label_when_parent_loo() {
  _bats_test_init 77 'herdr-child ask leaves the label when parent lookup or delivery fails'
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_NAME=orange-panda HERDR_CHILD_PARENT_PANE=wT:p0 \
    bash "$HERDR_CHILD" ask question
  assert_failure
  assert_file_contains "$CHILD_STUB/calls.log" '^pane report-metadata'
  run grep -q 'clear-state-labels' "$CHILD_STUB/calls.log"
  assert_failure

  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"parent","pane_id":"wT:p0"}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PROMPT_FAIL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p9 HERDR_CHILD_NAME=orange-panda HERDR_CHILD_PARENT_PANE=wT:p0 \
    bash "$HERDR_CHILD" ask question
  assert_failure
  assert_output --partial "waiting label remains published"
}

function test_scripts_078_herdr_child_reply_validates_the_live_pair_delive() {
  _bats_test_init 78 'herdr-child reply validates the live pair, delivers, then clears'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"orange-panda","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reply --to orange-panda --pane wT:p9 "Use path A"
  assert_success
  local call2 call3 call4
  call2="$(sed -n '2p' "$CHILD_STUB/calls.log")"
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  call4="$(sed -n '4p' "$CHILD_STUB/calls.log")"
  [[ "$call2" == pane\ get*wT:p9* ]] || fail "child metadata was not read before reply: $call2"
  [[ "$call3" == agent\ prompt*parent-reply*pane=wT:p0* ]] || fail "reply was not delivered after validation: $call3"
  [[ "$call4" == pane\ report-metadata*wT:p9*--clear-state-labels* ]] || fail "waiting label was not cleared after delivery: $call4"

  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_REPORT_FAIL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reply --to orange-panda --pane wT:p9 decision
  assert_failure
  assert_output --partial "reply delivered to orange-panda in wT:p9"
  assert_output --partial "waiting label could not be cleared"

  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reply --to orange-panda --pane wT:p8 decision
  assert_failure
  run grep -q '^agent prompt' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_079_herdr_child_ask_and_reply_publish_strictly_incre() {
  _bats_test_init 79 'herdr-child ask and reply publish strictly increasing label sequences'
  child_stub_herdr
  local parent_agents='{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p0","terminal_id":"term-parent","revision":1,"state_change_seq":1},{"name":"orange-panda","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10}]}}'
  env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$parent_agents" HERDR_ENV=1 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_TEST_NOW_SEQ=200 \
    HERDR_PANE_ID=wT:p9 HERDR_CHILD_NAME=orange-panda HERDR_CHILD_PARENT_PANE=wT:p0 \
    bash "$HERDR_CHILD" ask question >/dev/null
  local child_agents='{"result":{"agents":[{"name":"orange-panda","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10}]}}'
  env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$child_agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_TEST_NOW_SEQ=100 \
    bash "$HERDR_CHILD" reply --to orange-panda --pane wT:p9 decision >/dev/null
  local first_seq second_seq
  first_seq="$(grep '^pane report-metadata' "$CHILD_STUB/calls.log" | sed -n '1s/.*--seq \([0-9]*\).*/\1/p')"
  second_seq="$(grep '^pane report-metadata' "$CHILD_STUB/calls.log" | sed -n '2s/.*--seq \([0-9]*\).*/\1/p')"
  run test -n "$first_seq"
  assert_success
  run test "$second_seq" -gt "$first_seq"
  assert_success
}

function test_scripts_080_herdr_child_reply_keeps_the_label_when_delivery() {
  _bats_test_init 80 'herdr-child reply keeps the label when delivery fails and refuses child callers'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"orange-panda","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PROMPT_FAIL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reply --to orange-panda --pane wT:p9 decision
  assert_failure
  run grep -q 'clear-state-labels' "$CHILD_STUB/calls.log"
  assert_failure

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_PARENT_PANE=wT:p0 bash "$HERDR_CHILD" reply --to orange-panda --pane wT:p9 decision
  assert_failure
  assert_output --partial "parent-side"
}

function test_scripts_082_herdr_child_reap_closes_an_unfocused_idle_pane() {
  _bats_test_init 82 'herdr-child reap closes an unfocused idle pane'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"idle-a","pane_id":"wT:p1","terminal_id":"term-child","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --to idle-a --pane wT:p1
  assert_success
  assert_output --partial "idle-a: closed pane wT:p1"
  refute_output --partial "--pane: skipped"
  run grep -c '^pane close wT:p1' "$CHILD_STUB/calls.log"
  assert_output 1
}

function test_scripts_083_herdr_child_reap_rejects_an_empty_expected_pane() {
  _bats_test_init 83 'herdr-child reap rejects an empty expected pane'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"idle-a","pane_id":"wT:p1","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --to idle-a --pane ""
  assert_failure 2
  assert_output --partial "reap requires --pane"
  assert_file_not_exists "$CHILD_STUB/calls.log"
}

function test_scripts_084_herdr_child_reap_preserves_a_reused_name_outside() {
  _bats_test_init 84 'herdr-child reap preserves a reused name outside the expected pane'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"reused-a","pane_id":"wT:p2","terminal_id":"term-child","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --to reused-a --pane wT:p1
  assert_success
  assert_output --partial "reused-a: kept; expected pane wT:p1, current pane is wT:p2"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_085_herdr_child_reap_preserves_a_pane_when_fresh_sta() {
  _bats_test_init 85 'herdr-child reap preserves a pane when fresh state no longer matches'
  child_stub_herdr
  local initial='{"result":{"agents":[{"name":"stale-a","pane_id":"wT:p1","terminal_id":"term-child","agent_status":"done","focused":false}]}}'
  local fresh='{"result":{"agents":[{"name":"stale-a","pane_id":"wT:p2","terminal_id":"term-child","agent_status":"done","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON_FIRST="$initial" STUB_AGENTS_JSON_SECOND="$fresh" \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to stale-a --pane wT:p1
  assert_success
  assert_output --partial "stale-a: kept; child name and pane no longer identify the same live agent"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_086_herdr_child_reap_refuses_outside_herdr_and_from() {
  _bats_test_init 86 'herdr-child reap refuses outside herdr and from a child pane'
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV= HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --to orange-panda --pane wT:p9
  assert_failure
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_PARENT_PANE=wT:p0 bash "$HERDR_CHILD" reap --to orange-panda --pane wT:p9
  assert_failure
  assert_output --partial "parent-side"
}

function test_scripts_087_herdr_child_reap_preserves_a_settled_pane_with_a() {
  _bats_test_init 87 'herdr-child reap preserves a settled pane with a waiting label'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"wait-a","pane_id":"wT:p1","terminal_id":"term-child","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_LABEL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to wait-a --pane wT:p1
  assert_success
  assert_output --partial "has a waiting state label"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_088_herdr_child_reap_preserves_a_settled_pane_when_p() {
  _bats_test_init 88 'herdr-child reap preserves a settled pane when pane metadata is malformed'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"bad-meta-a","pane_id":"wT:p1","terminal_id":"term-child","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PANE_GET_MALFORMED=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to bad-meta-a --pane wT:p1
  assert_success
  assert_output --partial "bad-meta-a: kept; pane metadata could not be read"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_089_herdr_child_reap_closes_a_positively_owned_one_p() {
  _bats_test_init 89 'herdr-child reap closes a positively owned one-pane tab'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"tab-a","pane_id":"wT:p1","terminal_id":"term-child","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PANE_TAB_ID=wT:tA \
    STUB_TAB_GET_FAIL=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to tab-a --pane wT:p1
  assert_success
  assert_output --partial "tab-a: closed pane wT:p1 and tab wT:tA"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p1'
  assert_file_contains "$CHILD_STUB/calls.log" '^tab get wT:tA'
}

function test_scripts_090_herdr_child_reap_closes_the_child_pane_but_repor() {
  _bats_test_init 90 'herdr-child reap closes the child pane but reports a surviving multi-pane tab'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"tab-a","pane_id":"wT:p1","terminal_id":"term-child","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PANE_TAB_ID=wT:tA \
    STUB_TAB_PANE_COUNT=2 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to tab-a --pane wT:p1
  assert_success
  assert_output --partial "tab-a: closed pane wT:p1; tab wT:tA kept with 2 panes"
}

function test_scripts_091_herdr_child_reap_preserves_ambiguous_tab_ownersh() {
  _bats_test_init 91 'herdr-child reap preserves ambiguous tab ownership'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"tab-a","pane_id":"wT:p1","terminal_id":"term-child","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PANE_TAB_ID=wT:tA \
    STUB_PANE_CHILD_TAB_TOKEN=wT:tOTHER HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --to tab-a --pane wT:p1
  assert_success
  assert_output --partial "tab-a: kept; pane wT:p1 tab ownership is ambiguous"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_092_herdr_child_tab_reap_invalidates_detached_superv() {
  _bats_test_init 92 'herdr-child tab reap invalidates detached supervision before close'
  child_lifecycle_stub_herdr
  HERDR_WORKSPACE_ID=w1 run child_lifecycle_start --tab --supervision-timeout 5000
  assert_success
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/require-reap-invalidation"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reap --to orange-panda --pane wT:p9
  assert_success
  assert_output --partial "closed pane wT:p9 and tab wT:tA"
  assert_file_exists "$CHILD_STUB/reap-invalidation-observed"
  assert_file_not_exists "$CHILD_STUB/close-before-invalidation"
}

# ===========================================
# herdr-peer-alias allocator
# ===========================================

PEER_ALIAS_SCRIPT="$SOURCE_ROOT/dot_local/bin/executable_herdr-peer-alias"
ALIAS_LIB="$SOURCE_ROOT/dot_local/lib/herdr-aliases.sh"

# The pool library owns the candidate order and the validity rule; the test
# reads both from it so the expectation never comes from the allocator itself.
peer_alias_candidate() {
  bash -c 'source "$1"; herdr_alias_candidates "$2"' _ "$ALIAS_LIB" "$1" | sed -n "$2p"
}

peer_alias_stub() {
  local stub="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stub"
  cat > "$stub/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list") printf '%s\n' "$STUB_AGENT_LIST" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$stub/herdr"
  printf '%s' "$stub"
}

function test_scripts_1401_herdr_peer_alias_skips_live_and_reserved_aliase() {
  _bats_test_init 1401 'herdr-peer-alias skips live and reserved aliases'
  command -v jq >/dev/null || skip "jq not available"
  local seed="claude|peer-alias-suite|$BATS_TEST_TMPDIR"
  local stub live reserved expected allocated
  stub="$(peer_alias_stub)"
  live="$(peer_alias_candidate "$seed" 1)"
  reserved="$(peer_alias_candidate "$seed" 2)"
  expected="$(peer_alias_candidate "$seed" 3)"

  run env PATH="$stub:$PATH" \
    STUB_AGENT_LIST="{\"result\":{\"agents\":[{\"name\":\"$live\",\"pane_id\":\"wT:p1\"},{\"name\":null,\"pane_id\":\"wT:p2\"}]}}" \
    bash "$PEER_ALIAS_SCRIPT" "$seed" "$reserved"
  assert_success
  assert_output "$expected"
  allocated="$output"

  run bash -c 'source "$1"; herdr_alias_in_pool "$2"' _ "$ALIAS_LIB" "$allocated"
  assert_success
}

# An agent record missing pane_id is a truncated list: its alias may be live
# and invisible here, so handing out any alias risks a duplicate registration.
function test_scripts_1402_herdr_peer_alias_fails_closed_on_an_incomplete_() {
  _bats_test_init 1402 'herdr-peer-alias fails closed on an incomplete agent list'
  command -v jq >/dev/null || skip "jq not available"
  local seed="claude|peer-alias-suite|$BATS_TEST_TMPDIR"
  local stub
  stub="$(peer_alias_stub)"

  run env PATH="$stub:$PATH" \
    STUB_AGENT_LIST='{"result":{"agents":[{"name":"amber-badger"}]}}' \
    bash "$PEER_ALIAS_SCRIPT" "$seed"
  assert_failure
  assert_output --partial "malformed herdr agent list"

  run env PATH="$stub:$PATH" \
    STUB_AGENT_LIST='{"result":{}}' \
    bash "$PEER_ALIAS_SCRIPT" "$seed"
  assert_failure
  assert_output --partial "malformed herdr agent list"
}

# ===========================================
# herdr-integrations run-script
# ===========================================

HERDR_INTEGRATIONS_TMPL="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_3-setup-herdr-integrations.sh.tmpl"

function test_scripts_093_herdr_integrations_script_exits_0_and_skips_when() {
  _bats_test_init 93 'herdr-integrations script exits 0 and skips when herdr is absent'
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

function test_scripts_094_fff_grep_guard_denies_a_query_of_several_bare_wo() {
  _bats_test_init 94 'fff-grep-guard denies a query of several bare words'
  command -v jq >/dev/null || skip "jq not available"
  run bash "$FFF_GUARD" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"TODO FIXME scheduling launchd cron"}}
EOF
  assert_success
  assert_output --partial '"permissionDecision": "deny"'
  assert_output --partial "mcp__fff__multi_grep"
}

function test_scripts_095_fff_grep_guard_stays_silent_on_a_single_identifi() {
  _bats_test_init 95 'fff-grep-guard stays silent on a single identifier'
  command -v jq >/dev/null || skip "jq not available"
  run bash "$FFF_GUARD" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"AGENT_PROFILES"}}
EOF
  assert_success
  assert_output ""
}

# Path-scoped and glob-scoped queries were the multi-token calls that actually
# returned hits, so the guard must let them through.
function test_scripts_096_fff_grep_guard_stays_silent_on_a_path_scoped_or() {
  _bats_test_init 96 'fff-grep-guard stays silent on a path-scoped or glob-scoped query'
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

function test_scripts_097_fff_grep_guard_fails_open_on_malformed_input() {
  _bats_test_init 97 'fff-grep-guard fails open on malformed input'
  run bash "$FFF_GUARD" <<<'not json at all'
  assert_success
  assert_output ""
}

function test_scripts_098_webfetch_markdown_hint_adds_context_for_a_plain() {
  _bats_test_init 98 'webfetch-markdown-hint adds context for a plain URL'
  command -v jq >/dev/null || skip "jq not available"
  run bash "$WEBFETCH_HINT" <<'EOF'
{"tool_name":"WebFetch","tool_input":{"url":"https://example.com/docs"}}
EOF
  assert_success
  assert_output --partial '"additionalContext"'
  assert_output --partial "/markdown-new"
  refute_output --partial "permissionDecision"
}

function test_scripts_099_webfetch_markdown_hint_stays_silent_when_the_url() {
  _bats_test_init 99 'webfetch-markdown-hint stays silent when the URL already uses markdown.new'
  command -v jq >/dev/null || skip "jq not available"
  run bash "$WEBFETCH_HINT" <<'EOF'
{"tool_name":"WebFetch","tool_input":{"url":"https://markdown.new/https://example.com/docs"}}
EOF
  assert_success
  assert_output ""
}

function test_scripts_100_settings_template_registers_both_pretooluse_hook() {
  _bats_test_init 100 'settings template registers both PreToolUse hooks with their matchers'
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

# herdr-pane-labels engine
# ===========================================

function test_scripts_1103_herdr_pane_labels_descriptor_probe_closes_worker_pipes() {
  _bats_test_init 1103 'herdr-pane-labels descriptor probe closes detached worker pipes'
  local probe_file="$BATS_TEST_DIRNAME/bashunit/herdr_pane_labels_descriptor_probe_test.sh"
  local release_file="$BATS_TEST_TMPDIR/release-herdr"
  local pid_file="$BATS_TEST_TMPDIR/descriptor-worker.pid"
  local blocked_pid_file="$BATS_TEST_TMPDIR/blocked-herdr.pid"
  assert_file_exists "$probe_file"

  run env HPL_DESCRIPTOR_RELEASE_FILE="$release_file" \
    HPL_DESCRIPTOR_PID_FILE="$pid_file" \
    HPL_DESCRIPTOR_BLOCKED_PID_FILE="$blocked_pid_file" \
    HPL_BLOCKED_HERDR_POLLS="$HPL_BLOCKED_HERDR_POLLS" \
    BASHUNIT_BIN="$BATS_TEST_DIRNAME/lib/bashunit" PROBE_FILE="$probe_file" \
    python3 - <<'PY'
import os
from pathlib import Path
import select
import signal
import subprocess
import time

release = Path(os.environ["HPL_DESCRIPTOR_RELEASE_FILE"])
worker_file = Path(os.environ["HPL_DESCRIPTOR_PID_FILE"])
blocked_file = Path(os.environ["HPL_DESCRIPTOR_BLOCKED_PID_FILE"])
gave_up = Path(str(blocked_file) + ".gave-up")
control_read, control_write = os.pipe()
os.set_inheritable(control_write, True)
proc = subprocess.Popen(
    [os.environ["BASHUNIT_BIN"], os.environ["PROBE_FILE"], "--no-parallel"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=os.environ.copy(),
    pass_fds=(control_write,),
)
os.close(control_write)

def read_pid(path):
    try:
        return int(path.read_text().strip())
    except (FileNotFoundError, ValueError):
        return None

try:
    deadline = time.monotonic() + 60
    worker_pid = None
    while worker_pid is None and time.monotonic() < deadline:
        worker_pid = read_pid(worker_file)
        if worker_pid is None:
            if proc.poll() is not None:
                raise AssertionError("nested probe exited before publishing its worker pid")
            time.sleep(0.02)
    if worker_pid is None:
        raise AssertionError("nested probe did not publish its worker pid")

    blocked_pid = read_pid(blocked_file)
    if gave_up.exists() or blocked_pid is None:
        raise AssertionError("blocked Herdr fixture gave up before the EOF check")
    os.kill(blocked_pid, 0)

    try:
        stdout, stderr = proc.communicate(timeout=30)
    except subprocess.TimeoutExpired as error:
        raise AssertionError("detached worker retained the nested runner output pipes") from error
    if proc.returncode != 0:
        raise AssertionError(f"nested probe failed: {stderr}\n{stdout}")
    if "1 passed" not in stdout:
        raise AssertionError(f"nested probe did not report its passing test: {stdout}")
    readable, _, _ = select.select([control_read], [], [], 1)
    if not readable or os.read(control_read, 1) != b"":
        raise AssertionError("detached worker retained the inherited control pipe")

    release.touch()
    for _ in range(500):
        try:
            os.kill(worker_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.01)
    else:
        os.kill(worker_pid, signal.SIGKILL)
        raise AssertionError("detached worker survived its release")
finally:
    os.close(control_read)
    release.touch()
    if proc.poll() is None:
        proc.kill()
        proc.wait()
PY
  assert_success
}

function test_scripts_1104_herdr_pane_labels_harness_fresh_reads_follow_pane_and_t() {
  _bats_test_init 1104 'herdr-pane-labels harness fresh reads follow pane and tab mutations'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" \
    '{"pane_id":"pane-1","tab_id":"tab-1","terminal_id":"term-1","cwd":"/repo/one","label":"old","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" \
    '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-tab"}'

  run hpl_socket_run "$HPL_DEFAULT_SOCKET" pane rename pane-1 new
  assert_success
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" tab rename tab-1 new-tab
  assert_success
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" pane get pane-1
  assert_success
  assert_output --partial '"label":"new"'
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" tab get tab-1
  assert_success
  assert_output --partial '"label":"new-tab"'
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" api snapshot
  assert_success
  assert_output --partial '"tabs":[{"tab_id":"tab-1"'

  hpl_snapshot_complete "$HPL_DEFAULT_SOCKET" false
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" api snapshot
  assert_success
  refute_output --partial '"tabs"'
}

function test_scripts_1105_herdr_pane_labels_harness_isolates_colliding_sanitized_() {
  _bats_test_init 1105 'herdr-pane-labels harness isolates colliding sanitized socket names'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # a-b.sock and a_b.sock collided under the retired sanitized-name scheme;
  # exact socket paths must now map to separate harness directories.
  local socket_one="$HPL_WORK/a-b.sock" socket_two="$HPL_WORK/a_b.sock"
  local dir_one dir_two
  dir_one="$(hpl_socket_dir "$socket_one")"
  dir_two="$(hpl_socket_dir "$socket_two")"
  run test "$dir_one" != "$dir_two"
  assert_success
  hpl_set_pane "$socket_one" '{"pane_id":"pane-1","label":"one","tokens":{}}'
  hpl_set_pane "$socket_two" '{"pane_id":"pane-1","label":"two","tokens":{}}'

  run hpl_socket_run "$socket_one" api snapshot
  assert_success
  assert_output --partial '"label":"one"'
  run hpl_socket_run "$socket_two" api snapshot
  assert_success
  assert_output --partial '"label":"two"'
  hpl_wait_for_socket_call "$dir_one" 1
  hpl_wait_for_socket_completion "$dir_one" 1
  hpl_wait_for_socket_call "$dir_two" 1
  hpl_wait_for_socket_completion "$dir_two" 1
  # A failing mkdir trips the ERR trap, so this probes both independent locks
  # parents without restating the resulting directory existence.
  mkdir "$dir_one/locks/held" "$dir_two/locks/held"
  assert_equal "$(wc -l < "$(hpl_socket_log "$socket_one")" | tr -d ' ')" 1
  assert_equal "$(wc -l < "$(hpl_socket_log "$socket_two")" | tr -d ' ')" 1
}

function test_scripts_1106_herdr_pane_labels_harness_applies_source_metadata_seque() {
  _bats_test_init 1106 'herdr-pane-labels harness applies source metadata sequence and clear rules'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","label":"agent","tokens":{}}'

  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane report-metadata --source location pane-1 --seq 2 --token repo=alpha
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane report-metadata --source foreign pane-1 --seq 1 --token foreign=review
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane report-metadata --source location pane-1 --seq 1 --clear-token repo
  local state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.metadata["pane-1"].location.tokens.repo' "$state")" alpha
  assert_equal "$(jq -r '.panes[0].tokens.foreign' "$state")" review

  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane report-metadata --source location pane-1 --seq 3 --clear-token repo
  assert_equal "$(jq -r '.metadata["pane-1"].location.seq' "$state")" 3
  assert_equal "$(jq -r '.metadata["pane-1"].location.tokens.repo // "cleared"' "$state")" cleared
  assert_equal "$(jq -r '.panes[0].tokens.repo // "cleared"' "$state")" cleared
  assert_equal "$(jq -r '.panes[0].tokens.foreign' "$state")" review
}

function test_scripts_1107_herdr_pane_labels_harness_models_target_loss_move_reuse() {
  _bats_test_init 1107 'herdr-pane-labels harness models target loss move reuse and final-read change'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" \
    '{"pane_id":"pane-1","tab_id":"tab-1","terminal_id":"term-1","cwd":"/repo/one","label":"one","tokens":{}}'
  hpl_remove_pane "$HPL_DEFAULT_SOCKET" pane-1
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" pane get pane-1
  assert_failure
  run grep -q '^pane rename' "$HPL_LOG"
  assert_failure

  hpl_set_pane "$HPL_DEFAULT_SOCKET" \
    '{"pane_id":"pane-1","tab_id":"tab-2","terminal_id":"term-2","cwd":"/repo/two","label":"two","tokens":{}}'
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" pane get pane-1
  assert_success
  assert_output --partial '"tab_id":"tab-2"'
  assert_output --partial '"terminal_id":"term-2"'

  local state next_state
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  next_state="$(jq -c '.panes[0].terminal_id = "term-3" | .panes[0].cwd = "/repo/three" | .panes[0].label = "three"' "$state")"
  hpl_after_next_call_state "$HPL_DEFAULT_SOCKET" "$next_state"
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" pane get pane-1
  assert_success
  assert_output --partial '"terminal_id":"term-2"'
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane rename pane-1 stale-write
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" pane get pane-1
  assert_success
  assert_output --partial '"terminal_id":"term-3"'
  assert_output --partial '"label":"stale-write"'
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane rename pane-1 converged
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" pane get pane-1
  assert_success
  assert_output --partial '"label":"converged"'
}

function test_scripts_1108_herdr_pane_labels_assigns_distinct_aliases_and_renders_() {
  _bats_test_init 1108 'herdr-pane-labels assigns distinct aliases and renders known and fallback runtime prefixes'
  command -v jq >/dev/null || skip "jq not available"
  source "$HERDR_ALIASES"
  hpl_setup
  export HERDR_ALIAS_TEST_SEED=u2-prefixes
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude review-auth
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-2 tab-1 ws-1 term-2 opencode CORE-42
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-3 tab-1 ws-1 term-3 pi consult-pi
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-4 tab-1 ws-1 term-4 codex manual-name
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-5 tab-1 ws-1 term-5 gemini tracker-name

  hpl_request_only
  hpl_presentation_run

  local state names aliases alias
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  names="$(jq -r '.agents[].name' "$state")"
  aliases=0
  while IFS= read -r alias; do
    herdr_alias_in_pool "$alias"
    aliases=$((aliases + 1))
  done <<EOF
$names
EOF
  assert_equal "$aliases" 5
  assert_equal "$(printf '%s\n' "$names" | sort -u | wc -l | tr -d ' ')" 5
  assert_equal "$(jq -r '[.panes[].label] | join("|")' "$state")" \
    "cc:$(jq -r '.agents[] | select(.pane_id == "pane-1").name' "$state")|oc:$(jq -r '.agents[] | select(.pane_id == "pane-2").name' "$state")|pi:$(jq -r '.agents[] | select(.pane_id == "pane-3").name' "$state")|cx:$(jq -r '.agents[] | select(.pane_id == "pane-4").name' "$state")|g:$(jq -r '.agents[] | select(.pane_id == "pane-5").name' "$state")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "$(jq -r '[.panes[].label] | join(" · ")' "$state")"
  unset HERDR_ALIAS_TEST_SEED
}

function test_scripts_1109_herdr_pane_labels_preserves_a_unique_pool_alias_across_() {
  _bats_test_init 1109 'herdr-pane-labels preserves a unique pool alias across events and sweeps'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
  hpl_sweep_run --sweep
  assert_equal "$(jq -r '.agents[0].name' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" red-wolf
  assert_equal "$(jq -r '.panes[0].label' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" cc:red-wolf

  : > "$HPL_LOG"
  hpl_sweep_run --sweep
  run grep -E '^(agent|pane|tab) rename' "$HPL_LOG"
  assert_failure
}

function test_scripts_1110_herdr_pane_labels_accepts_independent_pane_and_agent_re() {
  _bats_test_init 1110 'herdr-pane-labels accepts independent pane and agent revisions in a complete join'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
  hpl_transform_state "$HPL_DEFAULT_SOCKET" '.panes[0].revision = 7 | .agents[0].revision = 42'

  hpl_sweep_run --sweep

  local state
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].revision' "$state")" 7
  assert_equal "$(jq -r '.agents[0].revision' "$state")" 42
  assert_equal "$(jq -r '.panes[0].label' "$state")" cc:red-wolf
  assert_equal "$(jq -r '.tabs[0].label' "$state")" cc:red-wolf
  run grep '^agent rename' "$HPL_LOG"
  assert_failure
}

function test_scripts_1111_herdr_pane_labels_rejects_unsafe_snapshot_strings_befor() {
  _bats_test_init 1111 'herdr-pane-labels rejects unsafe snapshot strings before every write'
  command -v jq >/dev/null || skip "jq not available"
  local mutation namespace pending completed
  for mutation in \
    '.panes[0].pane_id = "bad\npane" | .agents[0].pane_id = "bad\npane"' \
    '.panes[0].terminal_id = "bad\u001fterminal" | .agents[0].terminal_id = "bad\u001fterminal"' \
    '.panes[0].tab_id = "bad\ntab" | .agents[0].tab_id = "bad\ntab" | .tabs[0].tab_id = "bad\ntab"' \
    '.panes[0].workspace_id = "bad\u001fworkspace" | .agents[0].workspace_id = "bad\u001fworkspace" | .tabs[0].workspace_id = "bad\u001fworkspace" | .workspaces[0].workspace_id = "bad\u001fworkspace"' \
    '.panes[0].agent = "bad\nruntime" | .agents[0].agent = "bad\nruntime"' \
    '.panes[0].label = "bad\u001flabel"' \
    '.panes[0].tokens = {repo:"bad\nrepo",worktree:"bad\u001fworktree",branch:"bad\nbranch",location_status:"bad\u001fstatus",git_ref:"bad\nref",location_label:"bad\u001flocation"}' \
    '.tabs[0].label = "bad\nlabel"' \
    '.workspaces[0].label = "bad\u001flabel"' \
    '.agents[0].name = "bad\nalias"' \
    '({source:"bad\u001fsource",agent:"claude",kind:"id",value:"session"}) as $session | .panes[0].agent_session = $session | .agents[0].agent_session = $session'; do
    hpl_setup
    hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
    hpl_transform_state "$HPL_DEFAULT_SOCKET" "$mutation"
    run hpl_sweep_run --sweep
    assert_failure

    run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
    assert_failure
    namespace="$(hpl_namespace "$HPL_DEFAULT_SOCKET")"
    pending="$(hpl_record_number "$namespace/reconcile.state" pending_generation)"
    completed="$(hpl_record_number "$namespace/reconcile.state" completed_generation)"
    run test "$pending" -gt "$completed"
    assert_success
    run find "$namespace/panes" -name location.state -print
    assert_output ""
    hpl_teardown
  done
}

function test_scripts_1112_herdr_pane_labels_sources_the_alias_library_relative_to() {
  _bats_test_init 1112 'herdr-pane-labels sources the alias library relative to its deployed path'
  local deployed="$BATS_TEST_TMPDIR/deployed-herdr-pane-labels"
  mkdir -p "$deployed/bin" "$deployed/lib"
  cp "$HPL_ENGINE" "$deployed/bin/herdr-pane-labels"
  cp "$HERDR_ALIASES" "$deployed/lib/herdr-aliases.sh"

  run env PATH="$deployed/bin:/usr/bin:/bin" bash "$deployed/bin/herdr-pane-labels" --help
  assert_success
  assert_output --partial 'Usage: herdr-pane-labels'
}

function test_scripts_1113_herdr_pane_labels_terminates_without_writes_when_every_() {
  _bats_test_init 1113 'herdr-pane-labels terminates without writes when every alias is occupied'
  command -v jq >/dev/null || skip "jq not available"
  source "$HERDR_ALIASES"
  hpl_setup
  local pool state
  pool="$(herdr_alias_candidates u2-exhausted | jq -Rsc 'split("\n")[:-1]')"
  state="$(jq -cn --argjson pool "$pool" '
    ($pool | to_entries) as $entries
    | {complete:true,protocol:19,
       panes:([$entries[] | {
         pane_id:("pane-" + (.key|tostring)),tab_id:"tab-1",workspace_id:"ws-1",
         terminal_id:("term-" + (.key|tostring)),revision:1,agent:"claude",label:"old",tokens:{}}]
         + [{pane_id:"target",tab_id:"tab-1",workspace_id:"ws-1",terminal_id:"target-term",
             revision:1,agent:"pi",label:"old",tokens:{}}]),
       tabs:[{tab_id:"tab-1",workspace_id:"ws-1",label:"old-tab"}],
       agents:([$entries[] | {
         pane_id:("pane-" + (.key|tostring)),tab_id:"tab-1",workspace_id:"ws-1",
         terminal_id:("term-" + (.key|tostring)),revision:1,state_change_seq:1,
         agent:"claude",name:.value}]
         + [{pane_id:"target",tab_id:"tab-1",workspace_id:"ws-1",terminal_id:"target-term",
             revision:1,state_change_seq:1,agent:"pi",name:"semantic-name"}]),
       layouts:[],workspaces:[{workspace_id:"ws-1",label:"ws-1"}],metadata:{}}')"
  hpl_replace_state "$HPL_DEFAULT_SOCKET" "$state"

  run hpl_sweep_run --sweep
  assert_failure

  run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure
  assert_equal "$(jq -r '.agents[] | select(.pane_id == "target").name' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" semantic-name
}

function test_scripts_1114_herdr_pane_labels_retries_only_an_exact_confirmed_agent() {
  _bats_test_init 1114 'herdr-pane-labels retries only an exact confirmed agent_name_taken conflict'
  command -v jq >/dev/null || skip "jq not available"
  source "$HERDR_ALIASES"
  hpl_setup
  export HERDR_ALIAS_TEST_SEED=u2-conflict
  local first second occupied state raced
  first="$(herdr_alias_candidates ignored | sed -n '1p')"
  second="$(herdr_alias_candidates ignored | sed -n '2p')"
  occupied=red-wolf
  [[ "$occupied" != "$first" && "$occupied" != "$second" ]] || occupied=blue-otter
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-2 tab-1 ws-1 term-2 pi "$occupied"
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  raced="$(jq -c --arg candidate "$first" '.agents |= map(if .pane_id == "pane-2" then .name = $candidate else . end)' "$state")"
  hpl_after_call_state "$HPL_DEFAULT_SOCKET" 3 "$raced"
  hpl_fail_next_agent_rename "$HPL_DEFAULT_SOCKET" agent_name_taken

  hpl_request_only
  hpl_presentation_run

  assert_equal "$(jq -r '.agents[] | select(.pane_id == "pane-1").name' "$state")" "$second"
  assert_equal "$(jq -r '.agents[] | select(.pane_id == "pane-2").name' "$state")" "$first"
  assert_file_contains "$HPL_LOG" "^agent rename pane-1 $first$"
  assert_file_contains "$HPL_LOG" "^agent rename pane-1 $second$"

  hpl_teardown
  hpl_setup
  export HERDR_ALIAS_TEST_SEED=u2-generic
  first="$(herdr_alias_candidates ignored | sed -n '1p')"
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-2 tab-1 ws-1 term-2 pi red-wolf
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  raced="$(jq -c --arg candidate "$first" '.agents |= map(if .pane_id == "pane-2" then .name = $candidate else . end)' "$state")"
  hpl_after_call_state "$HPL_DEFAULT_SOCKET" 3 "$raced"
  hpl_fail_next_agent_rename "$HPL_DEFAULT_SOCKET" internal_error
  hpl_request_only
  hpl_presentation_run
  assert_equal "$(jq -r '.agents[] | select(.pane_id == "pane-1").name' "$state")" semantic-name
  assert_equal "$(grep -c '^agent rename pane-1' "$HPL_LOG")" 1
  run grep -E '^(pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure
  unset HERDR_ALIAS_TEST_SEED
}

function test_scripts_1115_herdr_pane_labels_never_renames_a_stale_target_that_exi() {
  _bats_test_init 1115 'herdr-pane-labels never renames a stale target that exits moves or changes before validation'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
  local state changed
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  changed="$(jq -c '.panes = [] | .agents = []' "$state")"
  hpl_after_call_state "$HPL_DEFAULT_SOCKET" 1 "$changed"
  hpl_request_only
  hpl_presentation_run
  run grep '^agent rename' "$HPL_LOG"
  assert_failure

  hpl_teardown
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  changed="$(jq -c '
    .panes[0].pane_id = "pane-2" | .panes[0].terminal_id = "term-2"
    | .panes[0].revision = 2
    | .agents[0].pane_id = "pane-2" | .agents[0].terminal_id = "term-2"
    | .agents[0].revision = 2 | .agents[0].state_change_seq = 2' "$state")"
  hpl_after_call_state "$HPL_DEFAULT_SOCKET" 1 "$changed"
  hpl_request_only
  hpl_presentation_run
  run grep '^agent rename pane-1' "$HPL_LOG"
  assert_failure
  run cat "$HPL_WORK/presentation.trace"
  assert_output --partial retry-stale-generation
  run cat "$HPL_LOG"
  assert_output --partial 'agent rename pane-2 '

  hpl_teardown
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  changed="$(jq -c '
    .panes[0].agent = "opencode" | .panes[0].revision = 2
    | .agents[0].agent = "opencode" | .agents[0].revision = 2 | .agents[0].state_change_seq = 2' "$state")"
  hpl_after_call_state "$HPL_DEFAULT_SOCKET" 1 "$changed"
  hpl_request_only
  hpl_presentation_run
  run grep -c '^agent rename pane-1' "$HPL_LOG"
  assert_output 1
  assert_equal "$(jq -r '.panes[0].label' "$state")" "oc:$(jq -r '.agents[0].name' "$state")"
}

function test_scripts_1116_herdr_pane_labels_accepts_a_same_pane_replacement_in_th() {
  _bats_test_init 1116 'herdr-pane-labels accepts a same-pane replacement in the rename command interval'
  command -v jq >/dev/null || skip "jq not available"
  source "$HERDR_ALIASES"
  hpl_setup
  export HERDR_ALIAS_TEST_SEED=u2-command-interval
  local candidate state replacement
  candidate="$(herdr_alias_candidates ignored | sed -n '1p')"
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  replacement="$(jq -c --arg candidate "$candidate" '
    .panes[0].agent = "pi" | .panes[0].revision = 2
    | .agents[0].agent = "pi" | .agents[0].revision = 2
    | .agents[0].state_change_seq = 2 | .agents[0].name = $candidate' "$state")"
  hpl_after_call_state "$HPL_DEFAULT_SOCKET" 3 "$replacement"
  hpl_request_only
  hpl_presentation_run
  assert_equal "$(jq -r '.agents[0].name' "$state")" "$candidate"
  assert_equal "$(jq -r '.panes[0].label' "$state")" "pi:$candidate"
  run grep -c '^agent rename pane-1' "$HPL_LOG"
  assert_output 1
  unset HERDR_ALIAS_TEST_SEED
}

function test_scripts_1117_herdr_pane_labels_rejects_incomplete_malformed_duplicat() {
  _bats_test_init 1117 'herdr-pane-labels rejects incomplete malformed duplicate and contradictory snapshots before writes'
  command -v jq >/dev/null || skip "jq not available"
  local mutation baseline state
  for mutation in \
    'del(.agents[0].revision)' \
    '.panes[0].terminal_id = 7' \
    '.agents += [(.agents[0] | .name = "blue-otter")]' \
    '.agents[0].terminal_id = "contradiction"' \
    '.agents[0].tab_id = "other-tab"'; do
    hpl_setup
    hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
    state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
    baseline="$(jq -c . "$state")"
    hpl_transform_state "$HPL_DEFAULT_SOCKET" "$mutation"
    run hpl_sweep_run --sweep
    assert_failure
    run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
    assert_failure

    hpl_replace_state "$HPL_DEFAULT_SOCKET" "$baseline"
    : > "$HPL_LOG"
    hpl_sweep_run --sweep
    assert_file_contains "$HPL_LOG" '^agent rename pane-1 '
    hpl_teardown
  done

  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-2 tab-1 ws-1 term-2 pi red-wolf
  run hpl_sweep_run --sweep
  assert_failure
  run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure
  hpl_transform_state "$HPL_DEFAULT_SOCKET" '.agents[1].name = "blue-otter"'
  : > "$HPL_LOG"
  run hpl_sweep_run --sweep
  assert_success
  assert_file_contains "$HPL_LOG" '^pane rename pane-1 cc:red-wolf$'
  assert_file_contains "$HPL_LOG" '^pane rename pane-2 pi:blue-otter$'

  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
  hpl_snapshot_complete "$HPL_DEFAULT_SOCKET" false
  run hpl_sweep_run --sweep
  assert_failure
  run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure

  hpl_snapshot_complete "$HPL_DEFAULT_SOCKET" true
  : > "$HPL_LOG"
  : > "$(hpl_socket_dir "$HPL_DEFAULT_SOCKET")/malformed-next-snapshot"
  run hpl_sweep_run --sweep
  assert_failure
  run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure
  : > "$HPL_LOG"
  hpl_sweep_run --sweep
  assert_file_contains "$HPL_LOG" '^agent rename pane-1 '
}

function test_scripts_1118_herdr_pane_labels_rejects_a_complete_stale_post_rename_() {
  _bats_test_init 1118 'herdr-pane-labels rejects a complete stale post-rename snapshot and converges later'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
  local state stale
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  stale="$(jq -c '.agents[0].name = "stale-result"' "$state")"
  hpl_after_call_state "$HPL_DEFAULT_SOCKET" 3 "$stale"
  hpl_request_only
  hpl_presentation_run
  assert_equal "$(jq -r '.panes[0].label' "$state")" old
  run grep -E '^(pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure

  : > "$HPL_LOG"
  hpl_request_only
  hpl_presentation_run
  assert_file_contains "$HPL_LOG" '^agent rename pane-1 '
  run grep -q '^cc:' <<<"$(jq -r '.panes[0].label' "$state")"
  assert_success
}

function test_scripts_1119_herdr_pane_labels_contains_no_semantic_naming_or_retire() {
  _bats_test_init 1119 'herdr-pane-labels contains no semantic naming or retired worker interface'
  run grep -E 'prompt|transcript|model|task|--worker|--agent|--session|--set|HERDR_TASK_SYNC' "$HPL_ENGINE"
  assert_failure
  run grep -E -- '--event|--sweep|--sweep-daemon|--ensure-sweep-daemon|--presentation-worker' "$HPL_ENGINE"
  assert_success

  local retired
  for retired in --agent --session --transcript --set --worker; do
    run bash "$HPL_ENGINE" "$retired"
    assert_failure 2
    assert_output --partial 'Usage: herdr-pane-labels'
  done
}


function test_scripts_1121_herdr_pane_labels_presentation_coalesces_event_bursts_i() {
  _bats_test_init 1121 'herdr-pane-labels presentation coalesces event bursts into an active pass and rerun'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old"}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  : > "$HPL_WORK/block-herdr"
  hpl_event_run
  hpl_wait_for_file "$HPL_WORK/herdr-blocked"
  hpl_event_run
  hpl_event_run
  hpl_event_run
  : > "$HPL_WORK/release-herdr"
  hpl_wait_for_presentation_quiescence "$HPL_DEFAULT_SOCKET"

  run grep -c '^api snapshot' "$HPL_LOG"
  # One read belongs to the generation invalidated by the burst; the latest
  # generation then performs its required initial and final complete reads.
  assert_output "3"
  run grep -c '^pane rename pane-1 btop$' "$HPL_LOG"
  assert_output "1"
  run grep -c '^tab rename tab-1 btop$' "$HPL_LOG"
  assert_output "1"
}

function test_scripts_1122_herdr_pane_labels_presentation_retries_a_newer_invalida() {
  _bats_test_init 1122 'herdr-pane-labels presentation retries a newer invalidation after transient pass failure'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old"}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  local dir="$(hpl_socket_dir "$HPL_DEFAULT_SOCKET")"
  : > "$dir/fail-next-snapshot"
  : > "$HPL_WORK/block-herdr"
  hpl_event_run
  hpl_wait_for_file "$HPL_WORK/herdr-blocked"
  HERDR_PANE_LABELS_TEST_NO_PRESENTATION=1 hpl_event_run
  : > "$HPL_WORK/release-herdr"
  hpl_wait_for_presentation_quiescence "$HPL_DEFAULT_SOCKET"
  run grep -c '^api snapshot' "$HPL_LOG"
  # The failed read is followed by initial and final complete reads.
  assert_output "3"
  assert_equal "$(jq -r '.panes[0].label' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" btop
}

function test_scripts_1123_herdr_pane_labels_presentation_release_recheck_does_not() {
  _bats_test_init 1123 'herdr-pane-labels presentation release recheck does not lose a pending invalidation'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old"}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  local pause="$HPL_WORK/release-edge"
  HERDR_PANE_LABELS_TEST_PAUSE_BEFORE_RELEASE="$pause" hpl_event_run
  hpl_wait_for_file "$pause.reached"
  # The second event only has to make an invalidation pending; letting it also
  # start a presentation of its own races the paused pass under load, which
  # adds a third snapshot and reads as a lost invalidation when it is not.
  # Suppressing it keeps the recheck the only route to the second snapshot, so
  # the exact count below still means what the test name says.
  HERDR_PANE_LABELS_TEST_NO_PRESENTATION=1 hpl_event_run
  : > "$pause.release"
  hpl_wait_for_presentation_quiescence "$HPL_DEFAULT_SOCKET"
  run grep -c '^api snapshot' "$HPL_LOG"
  # Both successful generations perform initial and final complete reads.
  assert_output "4"
}

function test_scripts_1124_herdr_pane_labels_event_presentation_leaves_the_hook_pr() {
  _bats_test_init 1124 'herdr-pane-labels event presentation leaves the hook process group'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old"}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  local pause="$HPL_WORK/process-group" claim worker_pid worker_pgid hook_pgid

  HERDR_PANE_LABELS_TEST_PAUSE_BEFORE_RELEASE="$pause" hpl_event_run
  hpl_wait_for_file "$pause.reached"
  claim="$(hpl_namespace "$HPL_DEFAULT_SOCKET")/presentation.claim/owner"
  worker_pid="$(hpl_record_number "$claim" pid)"
  worker_pgid="$(ps -p "$worker_pid" -o pgid= | tr -d '[:space:]')"
  hook_pgid="$(ps -p "$$" -o pgid= | tr -d '[:space:]')"
  : > "$pause.release"
  hpl_wait_for_presentation_quiescence "$HPL_DEFAULT_SOCKET"

  run test -n "$worker_pgid"
  assert_success
  run test "$worker_pgid" != "$hook_pgid"
  assert_success
}

function test_scripts_1125_herdr_pane_labels_presentation_automatically_corrects_d() {
  _bats_test_init 1125 'herdr-pane-labels presentation automatically corrects divergent pane and tab labels'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
  hpl_sweep_run --sweep
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane rename pane-1 divergent-pane
  : > "$HPL_LOG"
  hpl_event_run
  hpl_wait_for_presentation_quiescence "$HPL_DEFAULT_SOCKET"
  run grep '^pane rename' "$HPL_LOG"
  assert_output "pane rename pane-1 cc:red-wolf"
  run grep -c '^tab rename' "$HPL_LOG"
  assert_failure

  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane rename pane-1 divergent-again
  hpl_socket_run "$HPL_DEFAULT_SOCKET" tab rename tab-1 divergent-tab
  : > "$HPL_LOG"
  hpl_event_run
  hpl_wait_for_presentation_quiescence "$HPL_DEFAULT_SOCKET"
  assert_file_contains "$HPL_LOG" '^pane rename pane-1 cc:red-wolf$'
  assert_file_contains "$HPL_LOG" '^tab rename tab-1 cc:red-wolf$'
  run grep -E 'owner|reclaim|notification' "$HPL_LOG"
  assert_failure
}

function test_scripts_1126_herdr_pane_labels_presentation_rejects_an_unsafe_row_wi() {
  _bats_test_init 1126 'herdr-pane-labels presentation rejects an unsafe row without reducing pass scope'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # A FIELD_SEPARATOR in one pane must abort the whole pass. Labeling only the
  # other pane would turn malformed data into an apparently successful pass.
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"bad\u001flabel","tokens":{}}'
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-2","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-2","agent":null,"label":"old","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-tab"}'
  hpl_proc_info pane-2 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  hpl_request_only
  hpl_presentation_run
  local state namespace pending completed
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-2") | .label' "$state")" old
  assert_equal "$(jq -r '.tabs[0].label' "$state")" old-tab
  run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure
  namespace="$(hpl_namespace "$HPL_DEFAULT_SOCKET")"
  pending="$(hpl_record_number "$namespace/reconcile.state" pending_generation)"
  completed="$(hpl_record_number "$namespace/reconcile.state" completed_generation)"
  run test "$pending" -gt "$completed"
  assert_success
}

function test_scripts_1127_herdr_pane_labels_aborts_unsafe_process_and_git_derived() {
  _bats_test_init 1127 'herdr-pane-labels aborts unsafe process and Git-derived positional rows'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_process_pane pane-1 tab-1 ws-1 term-1 /tmp old
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-tab"}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":1,"foreground_process_group_id":2,"foreground_processes":[{"pid":2,"argv":["bad\u001fcommand"]}]}}}'
  hpl_request_only
  hpl_presentation_run

  local namespace pending completed root common unsafe_root
  namespace="$(hpl_namespace "$HPL_DEFAULT_SOCKET")"
  pending="$(hpl_record_number "$namespace/reconcile.state" pending_generation)"
  completed="$(hpl_record_number "$namespace/reconcile.state" completed_generation)"
  run test "$pending" -gt "$completed"
  assert_success
  run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure
  run find "$namespace/panes" -name location.state -print
  assert_output ""

  hpl_teardown
  hpl_setup
  root="$HPL_WORK/repository"
  common="$root/.git"
  unsafe_root="bad$(printf '\037')root"
  mkdir -p "$root" "$common"
  hpl_git_location_fixture "$root" "$unsafe_root" "$common" refs/heads/main
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-tab"}'
  hpl_set_process_label pane-1 worker
  hpl_request_only
  HERDR_PANE_LABELS_GIT_BUDGET="$HPL_GIT_BUDGET" hpl_presentation_run

  namespace="$(hpl_namespace "$HPL_DEFAULT_SOCKET")"
  pending="$(hpl_record_number "$namespace/reconcile.state" pending_generation)"
  completed="$(hpl_record_number "$namespace/reconcile.state" completed_generation)"
  run test "$pending" -gt "$completed"
  assert_success
  run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure
  run find "$namespace/panes" -name location.state -print
  assert_output ""
}

function test_scripts_1128_herdr_pane_labels_presentation_skips_pre_read_deletion_() {
  _bats_test_init 1128 'herdr-pane-labels presentation skips pre-read deletion and repairs the post-read race next pass'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old"}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  local state missing next dir
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  missing="$(jq -c '.panes = []' "$state")"
  hpl_after_next_call_state "$HPL_DEFAULT_SOCKET" "$missing"
  hpl_request_only
  hpl_presentation_run
  run grep -c '^pane rename' "$HPL_LOG"
  assert_failure

  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-2","agent":null,"label":"wrong","tokens":{}}'
  : > "$HPL_LOG"
  dir="$(hpl_socket_dir "$HPL_DEFAULT_SOCKET")"
  next=$(( $(cat "$dir/call-seq") + 3 ))
  hpl_after_call_script "$HPL_DEFAULT_SOCKET" "$next" "printf '%s' '{\"result\":{\"process_info\":{\"shell_pid\":100,\"foreground_process_group_id\":300,\"foreground_processes\":[{\"pid\":300,\"name\":\"cargo\",\"argv0\":\"cargo\",\"argv\":[\"cargo\",\"test\"]}]}}}' > '$dir/proc-pane-1.json'"
  hpl_request_only
  hpl_presentation_run
  assert_equal "$(jq -r '.panes[0].label' "$state")" btop
  hpl_request_only
  hpl_presentation_run
  assert_equal "$(jq -r '.panes[0].label' "$state")" "cargo test"
}

function test_scripts_1129_herdr_pane_labels_presentation_skips_reused_pane_and_ta() {
  _bats_test_init 1129 'herdr-pane-labels presentation skips reused pane and tab identities at the final read'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old-pane","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-tab"}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  local state next_state
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  next_state="$(jq -c '
    .panes[0].terminal_id = "term-2"
    | .panes[0].workspace_id = "ws-2"
    | .panes[0].label = "reused-pane"
    | .tabs[0].workspace_id = "ws-2"
    | .tabs[0].label = "reused-tab"
    | .workspaces += [{"workspace_id":"ws-2","label":"ws-2"}]
  ' "$state")"
  hpl_after_next_call_state "$HPL_DEFAULT_SOCKET" "$next_state"

  hpl_request_only
  hpl_presentation_run
  assert_equal "$(jq -r '.panes[0].label' "$state")" reused-pane
  assert_equal "$(jq -r '.tabs[0].label' "$state")" reused-tab
  run grep -E '^(pane|tab) rename' "$HPL_LOG"
  assert_failure

  hpl_request_only
  hpl_presentation_run
  assert_equal "$(jq -r '.panes[0].label' "$state")" btop
  assert_equal "$(jq -r '.tabs[0].label' "$state")" btop
}

function test_scripts_1130_herdr_pane_labels_presentation_isolates_exact_colliding() {
  _bats_test_init 1130 'herdr-pane-labels presentation isolates exact colliding socket identities'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local socket_one="$HPL_WORK/a-b.sock" socket_two="$HPL_WORK/a_b.sock"
  hpl_set_pane "$socket_one" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1a","agent":null,"label":"old-one","tokens":{}}'
  hpl_set_tab "$socket_one" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-one"}'
  hpl_set_pane "$socket_two" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1b","agent":null,"label":"old-two","tokens":{}}'
  hpl_set_tab "$socket_two" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-two"}'
  hpl_proc_info_for_socket "$socket_one" pane-1 '{"result":{"process_info":{"shell_pid":1,"foreground_process_group_id":2,"foreground_processes":[{"pid":2,"argv":["one"]}]}}}'
  hpl_proc_info_for_socket "$socket_two" pane-1 '{"result":{"process_info":{"shell_pid":1,"foreground_process_group_id":2,"foreground_processes":[{"pid":2,"argv":["two"]}]}}}'
  hpl_event_run_for_socket "$socket_one"
  hpl_event_run_for_socket "$socket_two"
  hpl_wait_for_presentation_quiescence "$socket_one"
  hpl_wait_for_presentation_quiescence "$socket_two"
  assert_equal "$(jq -r '.panes[0].label' "$(hpl_socket_state "$socket_one")")" one
  assert_equal "$(jq -r '.panes[0].label' "$(hpl_socket_state "$socket_two")")" two
  run test "$(hpl_namespace "$socket_one")" != "$(hpl_namespace "$socket_two")"
  assert_success
}

function test_scripts_1131_herdr_pane_labels_presentation_fails_closed_without_an_() {
  _bats_test_init 1131 'herdr-pane-labels presentation fails closed without an exact socket'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"unchanged","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"unchanged"}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":1,"foreground_process_group_id":2,"foreground_processes":[{"pid":2,"argv":["changed"]}]}}}'
  run env -u HERDR_SOCKET_PATH PATH="$HPL_STUB:/usr/bin:/bin" HERDR_PANE_LABELS_STATE_DIR="$HPL_STATE" bash "$HPL_ENGINE" --event
  assert_success
  run env -u HERDR_SOCKET_PATH PATH="$HPL_STUB:/usr/bin:/bin" HERDR_PANE_LABELS_STATE_DIR="$HPL_STATE" bash "$HPL_ENGINE" --sweep
  assert_success
  assert_equal "$(cat "$HPL_LOG")" ""
  assert_equal "$(jq -r '.panes[0].label' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" unchanged
}

function test_scripts_1132_herdr_pane_labels_location_resolves_main_linked_nested_() {
  _bats_test_init 1132 'herdr-pane-labels location resolves main linked nested and administrative paths with strict foreground semantics'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local main="$HPL_WORK/checkouts/repository" linked="$HPL_WORK/linked/feature"
  local common="$main/.git" nongit="$HPL_WORK/outside" state
  mkdir -p "$main/src/nested" "$common/objects" "$common/worktrees/feature/logs" "$linked/deep/path" "$nongit"
  hpl_mark_linked_worktree "$linked" "$common/worktrees/feature"
  printf '%s/.git\n' "$linked" > "$common/worktrees/feature/gitdir"
  hpl_git_location_fixture "$main/src/nested" "$main" "$common" refs/heads/main
  hpl_git_location_fixture "$main" "$main" "$common" refs/heads/main
  hpl_git_location_fixture "$linked" "$linked" "$common" refs/heads/feature
  hpl_git_location_fixture "$linked/deep/path" "$linked" "$common" refs/heads/feature
  hpl_git_fixture "$nongit" "" 1 ready 'fatal: not a git repository'

  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json main-nested tab-1 "$main" present "$main/src/nested")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json main-admin tab-1 "$main" present "$common/objects")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json linked-admin tab-1 "$linked" present "$common/worktrees/feature/logs")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json fallback tab-1 "$linked/deep/path" absent)"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json foreground-wins tab-1 "$linked/deep/path" present "$nongit")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json agent-ignores-foreground tab-1 "$linked/deep/path" present "$nongit" | jq -c '.agent = "pi"')"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repository"}'
  for pane_id in main-nested main-admin linked-admin fallback foreground-wins agent-ignores-foreground; do hpl_set_process_label "$pane_id" "$pane_id"; done
  LANG=fr_FR.UTF-8 LC_ALL= hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"

  assert_equal "$(jq -r '.panes[] | select(.pane_id == "main-nested" or .pane_id == "main-admin") | .tokens.repo' "$state" | sort -u)" repository
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "main-nested" or .pane_id == "main-admin") | .tokens.worktree' "$state" | sort -u)" repository
  # Main checkout: branch icon; folder qualifier suppressed because the
  # worktree token equals the workspace name.
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "main-nested" or .pane_id == "main-admin") | .tokens.git_ref' "$state" | sort -u)" "$HPL_ICON_BRANCH main"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "linked-admin" or .pane_id == "fallback") | .tokens.branch' "$state" | sort -u)" feature
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "linked-admin" or .pane_id == "fallback") | .tokens.worktree' "$state" | sort -u)" feature
  # Linked worktree (.git file at root): worktree icon; folder qualifier
  # suppressed because the worktree token equals the branch.
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "linked-admin" or .pane_id == "fallback") | .tokens.git_ref' "$state" | sort -u)" "$HPL_ICON_WORKTREE feature"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "agent-ignores-foreground") | .tokens.branch' "$state")" feature
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "agent-ignores-foreground") | .tokens.worktree' "$state")" feature
  run jq -e '.panes[] | select(.pane_id == "foreground-wins") | (.tokens.repo == null and .tokens.worktree == null and .tokens.branch == null and .tokens.git_ref == null)' "$state"
  assert_success
  assert_equal "$(cat "$(hpl_git_fixture_dir "$nongit")/locale")" C
}

function test_scripts_1133_herdr_pane_labels_dangling_administrative_gitdir_retain() {
  _bats_test_init 1133 'herdr-pane-labels dangling administrative gitdir retains stale location'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local main="$HPL_WORK/checkouts/repository" linked="$HPL_WORK/linked/feature"
  local common="$main/.git" admin="$common/worktrees/feature/logs" state
  mkdir -p "$common/worktrees/feature/logs" "$linked"
  hpl_mark_linked_worktree "$linked" "$common/worktrees/feature"
  printf '%s/.git\n' "$linked" > "$common/worktrees/feature/gitdir"
  hpl_git_location_fixture "$linked" "$linked" "$common" refs/heads/feature
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$linked" present "$linked")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 worker
  hpl_location_pass

  printf '%s\n' "$HPL_WORK/missing/.git" > "$common/worktrees/feature/gitdir"
  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-1 "$linked" "$admin"
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.worktree' "$state")" feature
  assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" feature
  assert_equal "$(jq -r '.panes[0].tokens.location_status' "$state")" stale
  # Retained stale evidence keeps the worktree place icon and renders stale
  # as a suffix icon on $git_ref, not as a separate row or text marker.
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_WORKTREE feature $HPL_ICON_STALE"
}

function test_scripts_1134_herdr_pane_labels_location_detached_publishes_a_commit_() {
  _bats_test_init 1134 'herdr-pane-labels location detached publishes a commit ref and non-Git clears are source-local with monotonic restart high-water'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/repo" common="$HPL_WORK/repo.git"
  local branch="$root/branch" detached="$root/detached" nongit="$HPL_WORK/non-git" state first_seq second_seq
  mkdir -p "$branch" "$detached" "$nongit" "$common" "$root/.git"
  hpl_git_location_fixture "$branch" "$root" "$common" refs/heads/topic
  hpl_git_location_fixture "$detached" "$root" "$common" HEAD a1b2c3d
  hpl_git_fixture "$nongit" "" 1 ready 'fatal: not a git repository'
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$branch")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hpl_set_process_label pane-1 worker
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane report-metadata pane-1 --source foreign-source --token foreign=kept --seq 900

  HERDR_PANE_LABELS_TEST_NOW_SEQ=1000 hpl_location_pass
  first_seq="$(hpl_location_source_seq "$HPL_DEFAULT_SOCKET" pane-1)"
  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-1 "$detached" "$detached"
  HERDR_PANE_LABELS_TEST_NOW_SEQ=1 hpl_location_pass
  second_seq="$(hpl_location_source_seq "$HPL_DEFAULT_SOCKET" pane-1)"
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  run test "$second_seq" -gt "$first_seq"
  assert_success
  assert_equal "$(jq -r '.panes[0].tokens.repo' "$state")" repo.git
  assert_equal "$(jq -r '.panes[0].tokens.worktree' "$state")" repo
  # Detached HEAD keeps the location: commit icon plus 7-char short SHA, no
  # stale marker, and no branch token.
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_COMMIT a1b2c3d"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" worker
  run jq -e '.panes[0].tokens.branch == null and .panes[0].tokens.location_status == null and .panes[0].tokens.foreign == "kept"' "$state"
  assert_success

  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-1 "$nongit" "$nongit"
  HERDR_PANE_LABELS_TEST_NOW_SEQ=0 hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  # The non-Git arm clears only presentation-owned location tokens.
  assert_equal "$(jq -c '.panes[0].tokens' "$state")" '{"foreign":"kept"}'
  run test "$(hpl_location_source_seq "$HPL_DEFAULT_SOCKET" pane-1)" -gt "$second_seq"
  assert_success
}

function test_scripts_1135_herdr_pane_labels_location_real_probe_shape_pays_the_se() {
  _bats_test_init 1135 'herdr-pane-labels location real probe shape pays the second sha call only when detached'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/repo" common="$HPL_WORK/repo.git"
  local branch="$root/branch" detached="$root/detached" state branch_fixture detached_fixture
  mkdir -p "$branch" "$detached" "$common" "$root/.git"
  # given: real-git probe shape — three lines from the first call, the short
  # SHA only from a separate `rev-parse --short=7 HEAD` answered via the
  # stub's stdout.short selector.
  hpl_git_fixture "$branch" "$(printf '%s\n%s\n%s' "$root" "$common" refs/heads/topic)"
  hpl_git_fixture "$detached" "$(printf '%s\n%s\n%s' "$root" "$common" HEAD)"
  branch_fixture="$(hpl_git_fixture_dir "$branch")"
  detached_fixture="$(hpl_git_fixture_dir "$detached")"
  printf 'e4f5a6b\n' > "$branch_fixture/stdout.short"
  printf 'e4f5a6b\n' > "$detached_fixture/stdout.short"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$branch")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hpl_set_process_label pane-1 worker

  # when: a branch pane resolves
  HERDR_PANE_LABELS_TEST_NOW_SEQ=1000 hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  # then: the ref came from the 3-line probe alone — no --short call fired
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_BRANCH topic"
  run grep -c -- '--short=7' "$branch_fixture/calls"
  assert_failure

  # when: the same pane moves to a detached checkout
  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-1 "$detached" "$detached"
  HERDR_PANE_LABELS_TEST_NOW_SEQ=1001 hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  # then: exactly one second budgeted call fetched the SHA
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_COMMIT e4f5a6b"
  assert_equal "$(grep -c -- '--short=7' "$detached_fixture/calls")" 1
}

function test_scripts_1136_herdr_pane_labels_location_detached_sha_failure_retains() {
  _bats_test_init 1136 'herdr-pane-labels location detached sha failure retains prior identity as stale and never publishes a malformed git_ref'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/repo" common="$HPL_WORK/repo.git"
  local branch="$root/branch" empty_sha="$root/empty-sha" bad_sha="$root/bad-sha" state target fixture
  mkdir -p "$branch" "$empty_sha" "$bad_sha" "$common" "$root/.git"
  # given: real-git probe shape — the detached probes answer 3 lines, and the
  # second `rev-parse --short=7` call yields an empty or non-hex SHA.
  hpl_git_fixture "$branch" "$(printf '%s\n%s\n%s' "$root" "$common" refs/heads/topic)"
  hpl_git_fixture "$empty_sha" "$(printf '%s\n%s\n%s' "$root" "$common" HEAD)"
  hpl_git_fixture "$bad_sha" "$(printf '%s\n%s\n%s' "$root" "$common" HEAD)"
  : > "$(hpl_git_fixture_dir "$empty_sha")/stdout.short"
  printf 'not-a-sha\n' > "$(hpl_git_fixture_dir "$bad_sha")/stdout.short"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$branch")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hpl_set_process_label pane-1 worker
  # given: prior canonical identity from a healthy branch resolve
  hpl_location_pass
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" "$HPL_ICON_BRANCH topic"

  for target in "$empty_sha" "$bad_sha"; do
    # when: the pane moves to a detached checkout whose SHA fetch fails
    hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-1 "$target" "$target"
    hpl_location_pass
    state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
    # then: the second call fired, and the pane retains the prior branch
    # identity as stale — no commit ref built from a malformed SHA.
    fixture="$(hpl_git_fixture_dir "$target")"
    assert_equal "$(grep -c -- '--short=7' "$fixture/calls")" 1
    assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_BRANCH topic $HPL_ICON_STALE"
    assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" topic
    assert_equal "$(jq -r '.panes[0].tokens.location_status' "$state")" stale
  done
}

function test_scripts_1137_herdr_pane_labels_location_detached_sha_budget_failure_() {
  _bats_test_init 1137 'herdr-pane-labels location detached sha budget failure with no prior state renders no git location and self-heals'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/repo" common="$HPL_WORK/repo.git"
  local detached="$root/detached" fixture state
  mkdir -p "$detached" "$common" "$root/.git"
  # given: real-git probe shape — the first call answers 3 lines in budget,
  # and block.short stalls the second --short=7 call past LOCATION_GIT_BUDGET.
  hpl_git_fixture "$detached" "$(printf '%s\n%s\n%s' "$root" "$common" HEAD)"
  fixture="$(hpl_git_fixture_dir "$detached")"
  printf 'e4f5a6b\n' > "$fixture/stdout.short"
  : > "$fixture/block.short"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$detached")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hpl_set_process_label pane-1 worker
  # when: the very first pass for this pane — no prior location state exists
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  # then: the SHA probe fired, its budget failure discarded the freshly
  # resolved root, and with nothing prior to retain the pane renders with no
  # git location this pass — no half-built commit ref, no stale marker.
  assert_equal "$(grep -c -- '--short=7' "$fixture/calls")" 1
  run jq -e '.panes[0].tokens | (.repo == null and .worktree == null and .branch == null and .location_status == null and .git_ref == null)' "$state"
  assert_success
  assert_equal "$(jq -r '.tabs[0].label' "$state")" worker
  # when: the next sweep finds a responsive SHA probe
  : > "$fixture/release"
  hpl_location_pass
  # then: the pane self-heals to the commit ref without manual repair
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" "$HPL_ICON_COMMIT e4f5a6b"
}

function test_scripts_1138_herdr_pane_labels_location_clears_the_retired_location_() {
  _bats_test_init 1138 'herdr-pane-labels location clears the retired location_label token on both publish and non-git clear paths'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/repo" common="$HPL_WORK/repo.git" nongit="$HPL_WORK/non-git" state
  mkdir -p "$root" "$common" "$nongit"
  hpl_git_location_fixture "$root" "$root" "$common" refs/heads/topic
  hpl_git_fixture "$nongit" "" 1 ready 'fatal: not a git repository'
  # given: panes still carrying the legacy location_label token published by
  # the previously deployed version
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root" | jq -c '.tokens.location_label = "legacy label"')"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$nongit" | jq -c '.tokens = {location_label:"legacy label", git_ref:"stale ref"}')"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hpl_set_process_label pane-1 worker
  hpl_set_process_label pane-2 shell
  # when: one location/presentation pass runs
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  # then: the Git publish path sheds the legacy token while publishing git_ref
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.git_ref' "$state")" "$HPL_ICON_BRANCH topic"
  run jq -e '.panes[] | select(.pane_id == "pane-1") | .tokens.location_label == null' "$state"
  assert_success
  # then: the non-Git clear path sheds it alongside the other location tokens
  run jq -e '.panes[] | select(.pane_id == "pane-2") | (.tokens.location_label == null and .tokens.git_ref == null)' "$state"
  assert_success
}

function test_scripts_1139_herdr_pane_labels_location_transient_modes_retain_ident() {
  _bats_test_init 1139 'herdr-pane-labels location transient modes retain identity as stale without foreground fallback'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/repo" common="$HPL_WORK/repo.git"
  local fallback="$root/fallback" fresh="$root/fresh" permission="$HPL_WORK/permission" unavailable="$HPL_WORK/unavailable"
  local malformed="$HPL_WORK/malformed" blocked="$HPL_WORK/blocked" missing="$HPL_WORK/missing" state
  mkdir -p "$fresh" "$fallback" "$permission" "$unavailable" "$malformed" "$blocked" "$common"
  hpl_git_location_fixture "$fresh" "$root" "$common" refs/heads/main
  hpl_git_location_fixture "$fallback" "$root" "$common" refs/heads/main
  hpl_git_fixture "$permission" "denied" 126
  hpl_git_fixture "$unavailable" "missing" 127
  hpl_git_fixture "$malformed" "only-one-line" 0
  hpl_git_fixture "$blocked" "never" 0 block
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$fallback" present "$fresh")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$fallback" present "$fresh")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 primary
  hpl_set_process_label pane-2 repaired
  hpl_location_pass

  local transient
  for transient in "$missing" "$permission" "$unavailable" "$malformed"; do
    hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$fallback" present "$transient")"
    hpl_location_pass
    state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
    assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.worktree' "$state")" repo
    assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.location_status' "$state")" stale
  done

  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$fallback" present "")"
  hpl_location_pass
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.location_status' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" stale

  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$fallback" present "$blocked")"
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane rename pane-2 externally-wrong
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.location_status' "$state")" stale
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-2") | .label' "$state")" repaired

  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$fallback" present "$fresh")"
  hpl_location_pass
  run jq -e '.panes[] | select(.pane_id == "pane-1") | .tokens.location_status == null' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_success
}

function test_scripts_1140_herdr_pane_labels_coordinator_resolves_eight_pane_locat() {
  _bats_test_init 1140 'herdr-pane-labels coordinator resolves eight pane locations concurrently within one event envelope'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local i root common cwd fixture blocked_fixture state pane stale_label
  local reconcile pending completed coordinator_pid deadline_pid deadline="$HPL_WORK/coordinator-deadline"
  for i in $(seq 1 8); do
    root="$HPL_WORK/repos/repo-$i"
    common="$HPL_WORK/repos/repo-$i.git"
    cwd="$root/work"
    mkdir -p "$cwd" "$common" "$root/.git"
    if [ "$i" -eq 1 ]; then
      hpl_git_location_fixture "$cwd" "$root" "$common" refs/heads/initial-1
    else
      hpl_git_fixture "$cwd" "" 1 ready 'fatal: not a git repository'
    fi
    pane="$(hpl_process_pane_json "pane-$i" tab-1 "$cwd")"
    pane="$(jq -c --arg label "stable-$i" '.agent = "claude" | .label = $label' <<< "$pane")"
    hpl_set_pane "$HPL_DEFAULT_SOCKET" "$pane"
  done
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_location_pass

  rm -f "$HPL_WORK/git-started"/*
  for i in $(seq 1 8); do
    root="$HPL_WORK/repos/repo-$i"
    common="$HPL_WORK/repos/repo-$i.git"
    cwd="$root/work"
    fixture="$(hpl_git_fixture_dir "$cwd")"
    rm -f "$fixture/started" "$fixture/completed"
    if [ "$i" -eq 1 ]; then
      : > "$fixture/block"
      blocked_fixture="$fixture"
    fi
  done

  stale_label="$HPL_ICON_BRANCH initial-1 $HPL_ICON_STALE stable-1"
  for i in $(seq 2 8); do stale_label="$stale_label · stable-$i"; done
  hpl_set_tab "$HPL_DEFAULT_SOCKET" "$(jq -cn --arg label "$stale_label" \
    '{tab_id:"tab-1",workspace_id:"ws-1",label:$label}')"
  HERDR_PANE_LABELS_TEST_NO_PRESENTATION=1 hpl_event_run
  reconcile="$(hpl_namespace "$HPL_DEFAULT_SOCKET")/reconcile.state"
  pending="$(hpl_record_number "$reconcile" pending_generation)"
  export HERDR_PANE_LABELS_TEST_LOCATION_BARRIER="$HPL_WORK/location-probes-started"
  export HERDR_PANE_LABELS_TEST_LOCATION_BARRIER_COUNT=8
  export HERDR_PANE_LABELS_TEST_LOCATION_BARRIER_RELEASE="$HPL_WORK/location-probes-release"
  export HERDR_PANE_LABELS_GIT_BUDGET=$HPL_GIT_BUDGET
  hpl_presentation_run &
  coordinator_pid=$!
  # The barrier is what proves concurrency: every probe publishes its marker and then
  # spins until all eight exist, so serial probes deadlock on the first one and this
  # wait fails the test before the release below ever happens. The deadline is only a
  # hang guard for that release path, never a performance budget -- a wall-clock bound
  # here measured the serial presentation tail after the probes (~78% of the window),
  # so it went red on slower CI runners without any regression behind it.
  for i in $(seq 1 8); do
    hpl_wait_for_file "$HERDR_PANE_LABELS_TEST_LOCATION_BARRIER/$(hpl_key "pane-$i")"
  done
  (sleep 30; : > "$deadline") &
  deadline_pid=$!
  : > "$HERDR_PANE_LABELS_TEST_LOCATION_BARRIER_RELEASE"
  while :; do
    completed="$(hpl_record_number "$reconcile" completed_generation 2>/dev/null || true)"
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
  unset HERDR_PANE_LABELS_TEST_LOCATION_BARRIER \
    HERDR_PANE_LABELS_TEST_LOCATION_BARRIER_COUNT \
    HERDR_PANE_LABELS_TEST_LOCATION_BARRIER_RELEASE HERDR_PANE_LABELS_GIT_BUDGET

  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  run jq -e '.panes[] | select(.pane_id == "pane-1") | .tokens.branch == "initial-1" and .tokens.location_status == "stale"' "$state"
  assert_success
  for i in $(seq 2 8); do
    run jq -e --arg pane "pane-$i" \
      '.panes[] | select(.pane_id == $pane) | (.tokens.repo == null and .tokens.worktree == null and .tokens.branch == null and .tokens.location_status == null and .tokens.git_ref == null)' "$state"
    assert_success
    fixture="$(hpl_git_fixture_dir "$HPL_WORK/repos/repo-$i/work")"
    assert_file_exists "$fixture/started"
    assert_file_exists "$fixture/completed"
  done
  assert_file_exists "$blocked_fixture/started"
  assert_file_not_exists "$blocked_fixture/completed"
}

function test_scripts_1141_herdr_pane_labels_no_op_location_event_preserves_the_st() {
  _bats_test_init 1141 'herdr-pane-labels no-op location event preserves the state file'
  command -v jq >/dev/null || skip "jq not available"
  command -v perl >/dev/null || skip "perl not available"
  hpl_setup
  local root="$HPL_WORK/repo" common="$HPL_WORK/repo.git" cwd="$HPL_WORK/repo/work"
  local location_file before_link before_mtime after_mtime
  mkdir -p "$cwd" "$common"
  hpl_git_location_fixture "$cwd" "$root" "$common" refs/heads/main
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$cwd")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 task
  hpl_location_pass

  location_file="$(hpl_pane_state_dir "$HPL_DEFAULT_SOCKET" pane-1)/location.state"
  before_link="$HPL_WORK/location-before.state"
  touch -t 200001010000 "$location_file"
  ln "$location_file" "$before_link"
  before_mtime="$(perl -e 'print((stat shift)[9])' "$location_file")"
  hpl_location_pass
  after_mtime="$(perl -e 'print((stat shift)[9])' "$location_file")"

  [ "$location_file" -ef "$before_link" ]
  assert_equal "$after_mtime" "$before_mtime"
}

function test_scripts_1142_herdr_pane_labels_transient_location_preserves_live_tok() {
  _bats_test_init 1142 'herdr-pane-labels transient location preserves live token-only identity when retained state is unavailable'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local missing_one="$HPL_WORK/missing-one" unavailable="$HPL_WORK/unavailable"
  local outside="$HPL_WORK/outside" pane_one pane_two location_two state
  mkdir -p "$outside" "$unavailable"
  hpl_git_fixture "$outside" "" 1 ready 'fatal: not a git repository'
  hpl_git_fixture "$unavailable" unavailable 127
  pane_one="$(hpl_process_pane_json pane-1 tab-1 "$missing_one")"
  pane_one="$(jq -c '.tokens = {repo:"live-repo",worktree:"live-token",branch:"topic-one",pane_inline:"· one"}' <<< "$pane_one")"
  pane_two="$(hpl_process_pane_json pane-2 tab-1 "$unavailable")"
  pane_two="$(jq -c '.tokens = {repo:"live-repo",worktree:"live-token",location_status:"current"}' <<< "$pane_two")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$pane_one"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$pane_two"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-3 tab-1 "$outside")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 one
  hpl_set_process_label pane-2 two
  hpl_set_process_label pane-3 three
  location_two="$(hpl_pane_state_dir "$HPL_DEFAULT_SOCKET" pane-2)/location.state"
  mkdir -p "$(dirname "$location_two")"
  printf '%s\n' not-a-location-record > "$location_two"

  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  # Token-only evidence carries no is_linked proof, so the place icon falls
  # back to the branch icon; without any ref evidence the folder icon plus
  # worktree token is the whole $git_ref.
  run jq -e \
    --arg ref_one "$HPL_ICON_BRANCH topic-one $HPL_ICON_FOLDER live-token $HPL_ICON_STALE" \
    --arg ref_two "$HPL_ICON_FOLDER live-token $HPL_ICON_STALE" '
    (.panes[] | select(.pane_id == "pane-1") | .tokens == {repo:"live-repo",worktree:"live-token",branch:"topic-one",location_status:"stale",git_ref:$ref_one})
    and (.panes[] | select(.pane_id == "pane-2") | .tokens == {repo:"live-repo",worktree:"live-token",location_status:"stale",git_ref:$ref_two})
  ' "$state"
  assert_success
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "one · two · three"
  assert_file_not_exists "$(hpl_pane_state_dir "$HPL_DEFAULT_SOCKET" pane-1)/location.state"
  assert_equal "$(cat "$location_two")" not-a-location-record
}

function test_scripts_1143_herdr_pane_labels_location_authoritative_worktree_delet() {
  _bats_test_init 1143 'herdr-pane-labels location authoritative worktree deletion clears retained evidence'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/linked/deleted" common="$HPL_WORK/main/.git"
  local live="$root/live" missing="$root/gone"
  mkdir -p "$live" "$common"
  hpl_git_location_fixture "$live" "$root" "$common" refs/heads/deleted
  hpl_git_fixture "gitdir:$common" "worktree $HPL_WORK/main\nHEAD 123456\nbranch refs/heads/main" 0
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$live")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 worker
  hpl_location_pass
  assert_equal "$(jq -r '.panes[0].tokens.worktree' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" deleted
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$missing")"
  hpl_location_pass
  run jq -e '.panes[0].tokens.repo == null and .panes[0].tokens.worktree == null and .panes[0].tokens.branch == null and .panes[0].tokens.location_status == null and .panes[0].tokens.git_ref == null' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_success
}

function test_scripts_1144_herdr_pane_labels_formatter_keeps_git_refs_in_metadata_() {
  _bats_test_init 1144 'herdr-pane-labels formatter keeps Git refs in metadata and tab labels names-only'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/project" common="$HPL_WORK/project/.git"
  local one="$root/one" two="$root/two" missing="$root/missing" outside="$HPL_WORK/outside" state
  mkdir -p "$one" "$two" "$outside" "$common"
  hpl_git_location_fixture "$one" "$root" "$common" refs/heads/main
  hpl_git_location_fixture "$two" "$root" "$common" refs/heads/main
  hpl_git_fixture "$outside" "" 1 ready 'fatal: not a git repository'
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$one")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$two")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"project"}'
  hpl_set_process_label pane-1 alpha
  hpl_set_process_label pane-2 beta
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"
  assert_equal "$(jq -r '.panes[] | .tokens.git_ref' "$state" | sort -u)" "$HPL_ICON_BRANCH main"

  # Stale state changes only the sidebar metadata, not the tab identity.
  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-2 "$two" "$missing"
  hpl_location_pass
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"

  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-1 "$outside" "$outside"
  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-2 "$outside" "$outside"
  hpl_location_pass
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"
}

function test_scripts_1145_herdr_pane_labels_formatter_renders_a_main_checkout_ref() {
  _bats_test_init 1145 'herdr-pane-labels formatter renders a main checkout ref in metadata only'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # Main checkout (.git directory at the root), branch main, and checkout
  # folder equal to the Herdr workspace name.
  local root="$HPL_WORK/my-mac-setup" state
  mkdir -p "$root/.git"
  hpl_git_location_fixture "$root" "$root" "$root/.git" refs/heads/main
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"my-mac-setup"}'
  hpl_set_process_label pane-1 task
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_BRANCH main"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" task
}

function test_scripts_1146_herdr_pane_labels_formatter_renders_a_worktree_ref_in_m() {
  _bats_test_init 1146 'herdr-pane-labels formatter renders a worktree ref in metadata only'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # A linked worktree in a folder named exactly like its branch. The worktree
  # icon alone carries the place; a folder qualifier would only repeat the ref.
  local root="$HPL_WORK/feature" common="$HPL_WORK/repository/.git" state
  mkdir -p "$root" "$common"
  hpl_mark_linked_worktree "$root" "$common/worktrees/feature"
  hpl_git_location_fixture "$root" "$root" "$common" refs/heads/feature
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"my-mac-setup"}'
  hpl_set_process_label pane-1 task
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_WORKTREE feature"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" task
}

function test_scripts_1147_herdr_pane_labels_formatter_keeps_a_git_backed_all_idle() {
  _bats_test_init 1147 'herdr-pane-labels formatter keeps a Git-backed all-idle tab names-only'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/repository" state
  mkdir -p "$root/.git"
  hpl_git_location_fixture "$root" "$root" "$root/.git" refs/heads/main
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[{"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hpl_proc_info pane-2 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[{"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "~ 1"
  assert_equal "$(jq -r '.panes[] | .label' "$state" | sort -u)" "~"
  assert_equal "$(jq -r '.panes[] | .tokens.git_ref' "$state" | sort -u)" "$HPL_ICON_BRANCH main $HPL_ICON_FOLDER repository"
}

function test_scripts_1148_herdr_pane_labels_git_only_location_changes_do_not_rena() {
  _bats_test_init 1148 'herdr-pane-labels Git-only location changes do not rename a names-only tab'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local one="$HPL_WORK/one" two="$HPL_WORK/two" state
  mkdir -p "$one/.git" "$two/.git"
  hpl_git_location_fixture "$one" "$one" "$one/.git" refs/heads/one
  hpl_git_location_fixture "$two" "$two" "$two/.git" refs/heads/two
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$one")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 worker
  hpl_location_pass
  : > "$HPL_LOG"

  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-1 "$two" "$two"
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" worker
  assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" two
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_BRANCH two"
  run grep '^tab rename' "$HPL_LOG"
  assert_failure
}

function test_scripts_1149_herdr_pane_labels_formatter_keeps_the_folder_qualifier_() {
  _bats_test_init 1149 'herdr-pane-labels formatter keeps the folder qualifier on a main checkout in a differently-named folder'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # Plan decision 5 describes the typical main checkout, whose folder repeats
  # the branch or the workspace name. When the folder differs from BOTH it is
  # real location information, so the sidebar qualifier stays — the same
  # suppression rule as every other checkout, no main-checkout special case.
  local root="$HPL_WORK/setup-copy" state
  mkdir -p "$root/.git"
  hpl_git_location_fixture "$root" "$root" "$root/.git" refs/heads/main
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"my-mac-setup"}'
  hpl_set_process_label pane-1 task
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_BRANCH main $HPL_ICON_FOLDER setup-copy"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" task
}

function test_scripts_1150_herdr_pane_labels_formatter_reads_the_workspace_display() {
  _bats_test_init 1150 'herdr-pane-labels formatter reads the workspace display name from the legacy name field when label is absent'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # Older snapshot shapes carry the workspace display name as `name`; the
  # (.label // .name // "") read must still suppress the folder qualifier when
  # the worktree token merely repeats that name.
  local root="$HPL_WORK/legacy-ws" state
  mkdir -p "$root/.git"
  hpl_git_location_fixture "$root" "$root" "$root/.git" refs/heads/topic
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","name":"legacy-ws"}'
  hpl_set_process_label pane-1 task
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_BRANCH topic"
}

function test_scripts_1151_herdr_pane_labels_formatter_gives_a_detached_head_insid() {
  _bats_test_init 1151 'herdr-pane-labels formatter gives a detached HEAD inside a linked worktree the commit icon'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # The commit place deliberately wins over the worktree place: the detached
  # short SHA locates the pane more precisely than worktree-ness does, and the
  # folder qualifier still names the linked worktree in the sidebar.
  local root="$HPL_WORK/wt-detached" common="$HPL_WORK/repository/.git" state
  mkdir -p "$root" "$common"
  hpl_mark_linked_worktree "$root" "$common/worktrees/wt-detached"
  hpl_git_location_fixture "$root" "$root" "$common" HEAD a1b2c3d
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repository"}'
  hpl_set_process_label pane-1 task
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_COMMIT a1b2c3d $HPL_ICON_FOLDER wt-detached"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" task
}

function test_scripts_1152_herdr_pane_labels_formatter_qualifies_a_divergent_workt() {
  _bats_test_init 1152 'herdr-pane-labels formatter qualifies a divergent worktree folder in metadata only'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # A divergent folder remains useful in the sidebar while the tab stays
  # limited to the two pane labels.
  local root="$HPL_WORK/wt-hotfix" common="$HPL_WORK/repository/.git" state
  mkdir -p "$root" "$common"
  hpl_mark_linked_worktree "$root" "$common/worktrees/wt-hotfix"
  hpl_git_location_fixture "$root" "$root" "$common" refs/heads/fix-login
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"my-mac-setup"}'
  hpl_set_process_label pane-1 alpha
  hpl_set_process_label pane-2 beta
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[] | .tokens.git_ref' "$state" | sort -u)" "$HPL_ICON_WORKTREE fix-login $HPL_ICON_FOLDER wt-hotfix"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"
}

function test_scripts_1153_herdr_pane_labels_formatter_keeps_mixed_git_identities_() {
  _bats_test_init 1153 'herdr-pane-labels formatter keeps mixed Git identities out of tabs and repairs external labels'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root_a="$HPL_WORK/a" root_b="$HPL_WORK/b" common_a="$HPL_WORK/a/.git" common_b="$HPL_WORK/b/.git"
  local cwd_a="$root_a/work" cwd_b="$root_b/work" outside="$HPL_WORK/outside" missing="$root_b/missing" state
  mkdir -p "$cwd_a" "$cwd_b" "$outside" "$common_a" "$common_b"
  hpl_git_location_fixture "$cwd_a" "$root_a" "$common_a" refs/heads/dev
  hpl_git_location_fixture "$cwd_b" "$root_b" "$common_b" refs/heads/main
  hpl_git_fixture "$outside" "" 1 ready 'fatal: not a git repository'
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$cwd_a")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$cwd_b")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 first
  hpl_set_process_label pane-2 second
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "first · second"

  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$cwd_b" present "$missing")"
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane rename pane-1 divergent-pane
  hpl_socket_run "$HPL_DEFAULT_SOCKET" tab rename tab-1 divergent-tab
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .label' "$state")" first
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "first · second"

  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$outside")"
  hpl_location_pass
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "first · second"
}

function test_scripts_1154_herdr_pane_labels_formatter_joins_only_pane_labels_when() {
  _bats_test_init 1154 'herdr-pane-labels formatter joins only pane labels when three panes span two repositories'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root_a="$HPL_WORK/a" root_b="$HPL_WORK/b" state
  mkdir -p "$root_a/.git" "$root_b/.git"
  hpl_git_location_fixture "$root_a" "$root_a" "$root_a/.git" refs/heads/dev
  hpl_git_location_fixture "$root_b" "$root_b" "$root_b/.git" refs/heads/main
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root_a")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$root_a")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-3 tab-1 "$root_b")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 one
  hpl_set_process_label pane-2 two
  hpl_set_process_label pane-3 three
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" \
    "one · two · three"
}

function test_scripts_1155_herdr_pane_labels_worktree_tokens_use_shortest_unique_s() {
  _bats_test_init 1155 'herdr-pane-labels worktree tokens use shortest unique slash suffixes for basename collisions'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local one="$HPL_WORK/team/feature" two="$HPL_WORK/release/feature" common="$HPL_WORK/repository/.git" state
  mkdir -p "$one" "$two" "$common"
  hpl_mark_linked_worktree "$one" "$common/worktrees/one"
  hpl_mark_linked_worktree "$two" "$common/worktrees/two"
  hpl_git_location_fixture "$one" "$one" "$common" refs/heads/one
  hpl_git_location_fixture "$two" "$two" "$common" refs/heads/two
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$one")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$two")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 alpha
  hpl_set_process_label pane-2 beta
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.worktree' "$state")" team/feature
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-2") | .tokens.worktree' "$state")" release/feature
  # The slash-suffix folder token appears only in the sidebar qualifier.
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.git_ref' "$state")" "$HPL_ICON_WORKTREE one $HPL_ICON_FOLDER team/feature"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-2") | .tokens.git_ref' "$state")" "$HPL_ICON_WORKTREE two $HPL_ICON_FOLDER release/feature"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"
}

function test_scripts_1156_herdr_pane_labels_worktree_tokens_digest_overlong_roots() {
  _bats_test_init 1156 'herdr-pane-labels worktree tokens digest overlong roots and extend colliding digest prefixes'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local unique="$HPL_WORK/extraordinarily-long-worktree"
  local one="$HPL_WORK/parent-component-that-is-long-one/shared-overlong-name"
  local two="$HPL_WORK/parent-component-that-is-long-two/shared-overlong-name"
  local common="$HPL_WORK/repository/.git" digests="$HPL_WORK/digests" state token_one token_two
  mkdir -p "$unique" "$one" "$two" "$common"
  hpl_git_location_fixture "$unique" "$unique" "$common" refs/heads/unique
  hpl_git_location_fixture "$one" "$one" "$common" refs/heads/one
  hpl_git_location_fixture "$two" "$two" "$common" refs/heads/two
  printf '%s\037%s\n%s\037%s\n' "$one" abcdef00000000000000000000000000 "$two" abcdef10000000000000000000000000 > "$digests"
  export HERDR_PANE_LABELS_TEST_DIGEST_FILE="$digests"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$unique")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$one")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-3 tab-1 "$two")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  for pane_id in pane-1 pane-2 pane-3; do hpl_set_process_label "$pane_id" task; done
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  run jq -e '[.panes[].tokens.worktree | select(length <= 18 and test("^[A-Za-z0-9._/-]+~[0-9a-f]{6,}$"))] | length == 3' "$state"
  assert_success
  token_one="$(jq -r '.panes[] | select(.pane_id == "pane-2") | .tokens.worktree' "$state")"
  token_two="$(jq -r '.panes[] | select(.pane_id == "pane-3") | .tokens.worktree' "$state")"
  run test "$token_one" != "$token_two"
  assert_success
  run grep -Eq 'abcdef$' <<<"$token_one
$token_two"
  assert_success
  run grep -Eq 'abcdef[01]$' <<<"$token_one
$token_two"
  assert_success
}

function test_scripts_1157_herdr_pane_labels_worktree_token_ordinal_fallback_is_un() {
  _bats_test_init 1157 'herdr-pane-labels worktree token ordinal fallback is unique and stable under pane reordering'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local common="$HPL_WORK/repository/.git" digests="$HPL_WORK/digests" panes='[]' before after i root
  mkdir -p "$common"
  : > "$digests"
  for i in $(seq 1 12); do
    root="$HPL_WORK/parent-component-that-is-deliberately-long-$i/shared-overlong-name"
    mkdir -p "$root"
    hpl_git_location_fixture "$root" "$root" "$common" "refs/heads/b$i"
    printf '%s\037%s\n' "$root" ffffffffffffffffffffffffffffffff >> "$digests"
    panes="$(jq -c --argjson pane "$(hpl_process_pane_json "pane-$i" tab-1 "$root")" '. + [$pane]' <<< "$panes")"
    hpl_set_process_label "pane-$i" task
  done
  export HERDR_PANE_LABELS_TEST_DIGEST_FILE="$digests"
  hpl_pane_list "$(jq -cn --argjson panes "$panes" '{result:{panes:$panes}}')"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_location_pass
  before="$(jq -c '[.panes | sort_by(.pane_id)[] | [.pane_id,.tokens.worktree]]' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")"
  run jq -e '[.panes[].tokens.worktree] | length == 12 and (unique | length == 12) and all(.[]; length <= 18)' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_success
  local state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")" tmp="$HPL_WORK/reversed.json"
  jq '.panes |= reverse' "$state" > "$tmp" && mv "$tmp" "$state"
  hpl_location_pass
  after="$(jq -c '[.panes | sort_by(.pane_id)[] | [.pane_id,.tokens.worktree]]' "$state")"
  assert_equal "$after" "$before"
}

function test_scripts_1158_herdr_pane_labels_long_branch_refs_stay_in_metadata_and() {
  _bats_test_init 1158 'herdr-pane-labels long branch refs stay in metadata and do not alter the tab label'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/worktree" common="$HPL_WORK/repository/.git" state
  local long_ref="feature/very-long-branch-name-that-overflows"
  mkdir -p "$root" "$common"
  hpl_mark_linked_worktree "$root" "$common/worktrees/one"
  hpl_git_location_fixture "$root" "$root" "$common" "refs/heads/$long_ref"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 task
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" task
  assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" "$long_ref"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_WORKTREE $long_ref $HPL_ICON_FOLDER worktree"
}

function test_scripts_1159_herdr_pane_labels_long_repository_names_do_not_alter_a_() {
  _bats_test_init 1159 'herdr-pane-labels long repository names do not alter a multi-repo tab label'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local one="$HPL_WORK/integration-platform-connectors"
  local two="$HPL_WORK/internal-developer-tooling"
  local common_one="$one/.git" common_two="$two/.git" state
  mkdir -p "$common_one" "$common_two"
  hpl_git_location_fixture "$one" "$one" "$common_one" refs/heads/feat/connector-runtime-rewrite
  hpl_git_location_fixture "$two" "$two" "$common_two" refs/heads/fix/oauth-refresh-loop-retry
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$one")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$two")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 first
  hpl_set_process_label pane-2 second
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "first · second"
  assert_equal "$(jq -r '.panes[] | .tokens.repo' "$state" | sort)" $'integration-platform-connectors\ninternal-developer-tooling'
}

function test_scripts_1160_herdr_pane_labels_location_clears_a_retired_location_la() {
  _bats_test_init 1160 'herdr-pane-labels location clears a retired location_label even when every published token already matches'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/repository" common="$HPL_WORK/repository/.git" state
  mkdir -p "$common"
  hpl_git_location_fixture "$root" "$root" "$common" refs/heads/topic
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 worker
  # given: one pass has already published every current token
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_BRANCH topic $HPL_ICON_FOLDER repository"
  assert_equal "$(jq -r '.panes[0].tokens.location_label // ""' "$state")" ""
  # given: a stale daemon of the retired version puts location_label back while
  # leaving every token this version compares untouched. It reports under the
  # same source at the sequence the last pass used, which is what an old daemon
  # sharing the generation counter does.
  local legacy_seq
  legacy_seq="$(jq -r '.metadata["pane-1"]["location-sync"].seq' "$state")"
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane report-metadata pane-1 \
    --source location-sync --seq "$legacy_seq" --token 'location_label=repository/topic'
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.location_label' "$state")" repository/topic
  # when: the next pass computes identical tokens and would otherwise skip
  hpl_location_pass
  # then: the legacy token is gone and the live tokens are unharmed
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.location_label // ""' "$state")" ""
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_BRANCH topic $HPL_ICON_FOLDER repository"
  assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" topic
}

function test_scripts_1161_herdr_pane_labels_location_and_formatter_add_only_appro() {
  _bats_test_init 1161 'herdr-pane-labels location and formatter add only approved static icon glyphs and no forbidden ownership state'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/plain-worktree" common="$HPL_WORK/repository/.git" state
  mkdir -p "$root" "$common"
  hpl_mark_linked_worktree "$root" "$common/worktrees/plain"
  hpl_git_location_fixture "$root" "$root" "$common" refs/heads/plain
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 plain-task
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  run grep -ER 'manual_owner|reclaim|label_ledger|server_epoch|takeover|prepare_rollback' "$(hpl_namespace "$HPL_DEFAULT_SOCKET")"
  assert_failure
  # After removing every approved codicon glyph, only plain ASCII (plus the
  # label separator and ellipsis) may remain in published labels and tokens.
  run jq -e --arg icons "$HPL_ICON_BRANCH$HPL_ICON_WORKTREE$HPL_ICON_COMMIT$HPL_ICON_FOLDER$HPL_ICON_STALE" '
    [.panes[0].label, .tabs[0].label, .panes[0].tokens.worktree, .panes[0].tokens.git_ref]
    | all(.[]; (. // "") | explode - ($icons | explode) | implode | test("^[A-Za-z0-9._:/ ~\u00b7\u2026-]*$"))
  ' "$state"
  assert_success
  assert_equal "$(jq -r '.tabs[0].label' "$state")" plain-task
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_WORKTREE plain $HPL_ICON_FOLDER plain-worktree"
  # pane_inline stays deferred per the label-system plan: no pass publishes it.
  assert_equal "$(jq -r '.panes[0].tokens.pane_inline // ""' "$state")" ""
}

function test_scripts_1162_herdr_pane_labels_plugin_exposes_only_the_approved_pane() {
  _bats_test_init 1162 'herdr-pane-labels plugin exposes only the approved pane and tab invalidations'
  local manifest="$HPL_PLUGIN_DIR/herdr-plugin.toml"
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
  assert_output $'pane.created|["sh", "ensure.sh", "--event"]\npane.moved|["sh", "ensure.sh", "--event"]\npane.exited|["sh", "ensure.sh", "--event"]\npane.closed|["sh", "ensure.sh", "--event"]\npane.agent_detected|["sh", "ensure.sh", "--event"]\npane.agent_status_changed|["sh", "ensure.sh", "--event"]\ntab.created|["sh", "ensure.sh", "--event"]\ntab.closed|["sh", "ensure.sh", "--event"]\ntab.moved|["sh", "ensure.sh", "--event"]\ntab.renamed|["sh", "ensure.sh", "--event"]\nworktree.created|["sh", "ensure.sh", "--event"]\nworktree.opened|["sh", "ensure.sh", "--event"]'
  assert_file_contains "$manifest" '^min_herdr_version = "0\.8\.2"$'
  assert_file_contains "$manifest" '^id = "sweep"$'
  assert_file_contains "$manifest" '^title = "Pane labels: refresh now"$'
  assert_file_contains "$manifest" '^command = \["sh", "sweep\.sh"\]$'
  run grep -E '^on = ".*\*|^on = "(pane\.updated|workspace\.focused|tab\.focused|pane\.focused)"|reclaim' "$manifest"
  assert_failure
}

function test_scripts_1163_herdr_pane_labels_plugin_wrappers_invoke_one_engine_mod() {
  _bats_test_init 1163 'herdr-pane-labels plugin wrappers invoke one engine mode and isolate failures'
  local home="$BATS_TEST_TMPDIR/home" engine_log="$BATS_TEST_TMPDIR/plugin-engine.log"
  mkdir -p "$home/.local/bin"
  cat > "$home/.local/bin/herdr-pane-labels" <<'SH'
#!/bin/sh
printf '%s|%s|%s\n' "${HPL_PLUGIN_CASE:-}" "$1" "${HERDR_SOCKET_PATH:-}" >> "$HPL_PLUGIN_ENGINE_LOG"
printf 'unexpected stdout\n'
printf 'unexpected stderr\n' >&2
[ "${HPL_PLUGIN_FAIL_ARG:-}" != "$1" ] || exit 23
exit 0
SH
  chmod +x "$home/.local/bin/herdr-pane-labels"

  run env HOME="$home" HERDR_SOCKET_PATH=/tmp/u5.sock \
    HPL_PLUGIN_ENGINE_LOG="$engine_log" HPL_PLUGIN_CASE=startup \
    HPL_PLUGIN_FAIL_ARG=--ensure-sweep-daemon sh "$HPL_PLUGIN_DIR/ensure.sh"
  assert_success
  assert_output ""
  run env HOME="$home" HERDR_SOCKET_PATH=/tmp/u5.sock \
    HPL_PLUGIN_ENGINE_LOG="$engine_log" HPL_PLUGIN_CASE=event-fails \
    HPL_PLUGIN_FAIL_ARG=--event sh "$HPL_PLUGIN_DIR/ensure.sh" --event
  assert_success
  assert_output ""
  run env HOME="$home" HERDR_SOCKET_PATH=/tmp/u5.sock \
    HPL_PLUGIN_ENGINE_LOG="$engine_log" HPL_PLUGIN_CASE=sweep \
    HPL_PLUGIN_FAIL_ARG=--sweep sh "$HPL_PLUGIN_DIR/sweep.sh"
  assert_success
  assert_output ""
  run cat "$engine_log"
  assert_output $'startup|--ensure-sweep-daemon|/tmp/u5.sock\nevent-fails|--event|/tmp/u5.sock\nsweep|--sweep|/tmp/u5.sock'
}

function test_scripts_1164_herdr_pane_labels_event_requests_reconciliation_and_ens() {
  _bats_test_init 1164 'herdr-pane-labels event requests reconciliation and ensures the daemon fail-open'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local namespace reconcile sweep_lock pending pid owner start socket_record
  namespace="$(hpl_namespace "$HPL_DEFAULT_SOCKET")"
  reconcile="$namespace/reconcile.state"
  sweep_lock="$namespace/sweep.lock"

  HERDR_PANE_LABELS_TEST_NO_PRESENTATION=1 hpl_event_run
  pending="$(hpl_record_number "$reconcile" pending_generation)"
  mkdir "$namespace/presentation-inbox.lock"
  owner="event-test-owner"
  start="$(ps -p "$$" -o lstart= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  socket_record="owner_id=$(printf '%s' "$owner" | base64 | tr -d '\n')
pid=$$
process_start=$(printf '%s' "$start" | base64 | tr -d '\n')
socket_path=$(printf '%s' "$HPL_DEFAULT_SOCKET" | base64 | tr -d '\n')"
  printf '%s\n' "$socket_record" > "$namespace/presentation-inbox.lock/owner"

  export HERDR_PANE_LABELS_TEST_NO_DAEMON=
  export HERDR_PANE_LABELS_LOCK_ATTEMPTS=1
  run hpl_event_run
  unset HERDR_PANE_LABELS_TEST_NO_DAEMON HERDR_PANE_LABELS_LOCK_ATTEMPTS
  assert_success
  hpl_wait_for_file "$sweep_lock/pid"
  assert_equal "$(hpl_record_number "$reconcile" pending_generation)" "$pending"
  pid="$(cat "$sweep_lock/pid")"
  kill "$pid" 2>/dev/null || true
  rm -f "$namespace/presentation-inbox.lock/owner"
  rmdir "$namespace/presentation-inbox.lock"

}

function test_scripts_1165_herdr_pane_labels_sweep_repairs_an_external_pane_rename() {
  _bats_test_init 1165 'herdr-pane-labels sweep repairs an external pane rename without pane.updated'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
  hpl_sweep_run --sweep
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane rename pane-1 external-label
  assert_equal "$(jq -r '.panes[0].label' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" external-label

  : > "$HPL_LOG"
  run hpl_sweep_run --sweep
  assert_success
  assert_equal "$(jq -r '.panes[0].label' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" cc:red-wolf
  assert_file_contains "$HPL_LOG" '^pane rename pane-1 cc:red-wolf$'
}

function test_scripts_1166_herdr_pane_labels_sweep_repairs_process_and_cwd_changes() {
  _bats_test_init 1166 'herdr-pane-labels sweep repairs process and CWD changes through the presentation coordinator'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local old="$HPL_WORK/repos/old" new="$HPL_WORK/repos/new-worktree" common="$HPL_WORK/repos/.git"
  mkdir -p "$old" "$new" "$common"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$old" present "$old")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_git_location_fixture "$old" "$old" "$common" refs/heads/old
  hpl_set_process_label pane-1 btop
  # hpl_location_pass, not bare hpl_event_run: this pass asserts a worktree
  # token, so its git probe needs the calibrated HPL_GIT_BUDGET instead of the
  # shipped 75 ms bound (killed probe -> tokens.worktree null under load).
  hpl_location_pass
  assert_equal "$(jq -r '.panes[0].label' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" btop
  assert_equal "$(jq -r '.panes[0].tokens.worktree' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" old

  hpl_git_location_fixture "$new" "$new" "$common" refs/heads/new-branch
  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-1 "$new" "$new"
  hpl_set_process_label pane-1 'cargo test'
  : > "$HPL_LOG"
  run hpl_sweep_run --sweep
  assert_success

  local state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].label' "$state")" "cargo test"
  assert_equal "$(jq -r '.panes[0].tokens.worktree' "$state")" new-worktree
  assert_file_contains "$HPL_LOG" '^api snapshot$'
  assert_file_contains "$HPL_LOG" '^pane rename pane-1 cargo test$'
}

function test_scripts_1167_herdr_pane_labels_names_a_command_pane_after_the_proces() {
  _bats_test_init 1167 'herdr-pane-labels names a command pane after the process group leader'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","name":"red-wolf","label":"agent-label"},
    {"pane_id":"pane-2","tab_id":"tab-1","agent":null,"label":null}]}}'
  hpl_proc_info pane-2 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[
      {"pid":201,"name":"node","argv0":"node","argv":["node","-e","timer"]},
      {"pid":200,"name":"bun","argv0":"bun","argv":["bun","run","dev"]}]}}}'
  hpl_sweep_run --sweep
  assert_equal "$(hpl_pane_label pane-2)" "bun run dev"
  run grep -m1 '^tab rename' "$HPL_LOG"
  assert_output "tab rename tab-1 cc:red-wolf · bun run dev"
}

# A pane whose foreground process group is its own shell runs nothing. It keeps
# its slot in the tab label under a placeholder instead of disappearing.
function test_scripts_1168_herdr_pane_labels_names_an_idle_pane_with_the_placehold() {
  _bats_test_init 1168 'herdr-pane-labels names an idle pane with the placeholder'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","name":"red-wolf","label":"agent-label"},
    {"pane_id":"pane-2","tab_id":"tab-1","agent":null,"label":"btop"}]}}'
  hpl_proc_info pane-2 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hpl_sweep_run --sweep
  assert_equal "$(hpl_pane_label pane-2)" "~"
  run grep -m1 '^tab rename' "$HPL_LOG"
  assert_output "tab rename tab-1 cc:red-wolf · ~"
}

# The session coordinator knows tab position, so task invalidation and sweeps
# use the same numbered placeholder for an all-idle tab.
function test_scripts_1169_herdr_pane_labels_presentation_numbers_an_all_idle_tab() {
  _bats_test_init 1169 'herdr-pane-labels presentation numbers an all-idle tab'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":null,"label":null}]}}'
  hpl_proc_info pane-1 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hpl_sweep_run --sweep
  assert_equal "$(hpl_pane_label pane-1)" "~"
}

# One pane must not eat the whole tab label, so a long command name is cut to
# 24 characters with a trailing ellipsis. Flags and paths drop out entirely.
function test_scripts_1170_herdr_pane_labels_truncates_a_long_command_name() {
  _bats_test_init 1170 'herdr-pane-labels truncates a long command name'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":null,"label":null}]}}'
  hpl_proc_info pane-1 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[
      {"pid":200,"name":"long","argv0":"/opt/bin/averyveryverylongcommandname",
       "argv":["/opt/bin/averyveryverylongcommandname","--flag","/tmp/path","sub"]}]}}}'
  hpl_sweep_run --sweep
  run grep -m1 '^tab rename' "$HPL_LOG"
  assert_output "tab rename tab-1 averyveryverylongcomman…"
}

# A naming call refreshes only its own tab, so a command that ends and an agent
# that quits leave a stale label behind. The sweep is the observer for both: it
# walks every tab herdr knows, not just the one that triggered it.
function test_scripts_1171_herdr_pane_labels_sweep_relabels_every_tab() {
  _bats_test_init 1171 'herdr-pane-labels --sweep relabels every tab'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_tab_list '{"result":{"tabs":[
    {"tab_id":"tab-1","label":"1"},
    {"tab_id":"tab-2","label":"2"}]}}'
  hpl_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","label":"agent-label"},
    {"pane_id":"pane-2","tab_id":"tab-2","agent":null,"label":null}]}}'
  hpl_proc_info pane-2 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[
      {"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  run hpl_sweep_run --sweep
  assert_success
  run grep -c '^tab rename' "$HPL_LOG"
  assert_output "2"
  run grep '^tab rename tab-2' "$HPL_LOG"
  assert_output "tab rename tab-2 btop"
}

function test_scripts_1172_herdr_pane_labels_sweep_reports_a_failed_reconciliation() {
  _bats_test_init 1172 'herdr-pane-labels --sweep reports a failed reconciliation'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local dir
  dir="$(hpl_socket_dir "$HPL_DEFAULT_SOCKET")"
  : > "$dir/fail-snapshot"

  run hpl_sweep_run --sweep

  assert_failure
}

function test_scripts_1173_herdr_pane_labels_strict_sweep_rejects_failed_and_unapp() {
  _bats_test_init 1173 'herdr-pane-labels strict sweep rejects failed and unapplied presentation writes'
  command -v jq >/dev/null || skip "jq not available"
  local marker
  for marker in fail-pane-rename drop-pane-rename fail-tab-rename drop-tab-rename; do
    hpl_setup
    hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
    : > "$HPL_WORK/$marker"
    export HERDR_PANE_LABELS_STRICT_SWEEP=1

    run hpl_sweep_run --sweep

    assert_failure
    unset HERDR_PANE_LABELS_STRICT_SWEEP
    hpl_teardown
  done

  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
  hpl_transform_state "$HPL_DEFAULT_SOCKET" '.panes[0].tokens = {repo:"repo",worktree:"main",branch:"main",git_ref:"main",location_label:"legacy"}'
  : > "$HPL_WORK/fail-pane-report"
  export HERDR_PANE_LABELS_STRICT_SWEEP=1
  run hpl_sweep_run --sweep
  assert_failure
  unset HERDR_PANE_LABELS_STRICT_SWEEP
}

# The daemon sweeps every few seconds. Renaming a tab to the label it already
# carries would churn the tab row and the socket for nothing.
function test_scripts_1174_herdr_pane_labels_sweep_leaves_an_unchanged_tab_label_a() {
  _bats_test_init 1174 'herdr-pane-labels --sweep leaves an unchanged tab label alone'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_tab_list '{"result":{"tabs":[{"tab_id":"tab-1","label":"btop"}]}}'
  hpl_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":null,"label":"btop"}]}}'
  hpl_proc_info pane-1 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[
      {"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  run hpl_sweep_run --sweep
  assert_success
  run cat "$HPL_LOG"
  refute_output --partial "tab rename"
  refute_output --partial "pane rename"
}

# An all-idle tab is numbered instead of skipped, or its last composed label
# would outlive the pane that produced it. The number counts tabs inside one
# workspace, because a tab row shows one workspace at a time.
function test_scripts_1175_herdr_pane_labels_sweep_numbers_all_idle_tabs_per_works() {
  _bats_test_init 1175 'herdr-pane-labels --sweep numbers all-idle tabs per workspace'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_tab_list '{"result":{"tabs":[
    {"tab_id":"tab-1","workspace_id":"ws-1","label":"1"},
    {"tab_id":"tab-2","workspace_id":"ws-1","label":"stale name"},
    {"tab_id":"tab-3","workspace_id":"ws-2","label":"2"}]}}'
  hpl_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":null,"label":null},
    {"pane_id":"pane-2","tab_id":"tab-2","agent":null,"label":null},
    {"pane_id":"pane-3","tab_id":"tab-3","workspace_id":"ws-2","agent":null,"label":null}]}}'
  hpl_proc_info pane-1 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hpl_proc_info pane-2 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hpl_proc_info pane-3 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  run hpl_sweep_run --sweep
  assert_success
  run grep '^tab rename' "$HPL_LOG"
  assert_line "tab rename tab-1 ~ 1"
  assert_line "tab rename tab-2 ~ 2"
  assert_line "tab rename tab-3 ~ 1"
}

# herdr fires the plugin hook on every agent state change, so the guard has to
# be cheap and exact: one daemon per machine, however often it is called.
function test_scripts_1176_herdr_pane_labels_ensure_sweep_daemon_keeps_a_single_da() {
  _bats_test_init 1176 'herdr-pane-labels --ensure-sweep-daemon keeps a single daemon'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  sleep 30 &
  local live=$! sweep_lock="$(hpl_namespace "$HPL_DEFAULT_SOCKET")/sweep.lock"
  mkdir -p "$sweep_lock"
  printf '%s' "$live" > "$sweep_lock/pid"
  ps -p "$live" -o lstart= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' > "$sweep_lock/start"
  run hpl_sweep_run --ensure-sweep-daemon
  assert_success
  assert_equal "$(cat "$sweep_lock/pid")" "$live"
  kill "$live" 2>/dev/null || true
}

# A daemon killed with its herdr session leaves the lock behind. The next hook
# must clear it and start a new daemon, or labels stay frozen until a restart.
function test_scripts_1177_herdr_pane_labels_ensure_sweep_daemon_replaces_a_dead_d() {
  _bats_test_init 1177 'herdr-pane-labels --ensure-sweep-daemon replaces a dead daemon'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_tab_list '{"result":{"tabs":[{"tab_id":"tab-1","label":"1"}]}}'
  hpl_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","label":"agent-label"}]}}'
  local sweep_lock="$(hpl_namespace "$HPL_DEFAULT_SOCKET")/sweep.lock"
  mkdir -p "$sweep_lock"
  # A pid that cannot be running: process ids are allocated from 1 upwards.
  printf '%s' "999999" > "$sweep_lock/pid"
  run hpl_sweep_run --ensure-sweep-daemon
  assert_success
  hpl_wait_for_call 'tab rename'
  local pid; pid="$(cat "$sweep_lock/pid" 2>/dev/null)"
  [ -n "$pid" ] && [ "$pid" != "999999" ]
  kill "$pid" 2>/dev/null || true
}

function test_scripts_1178_herdr_pane_labels_sweep_daemon_exits_after_three_unreac() {
  _bats_test_init 1178 'herdr-pane-labels sweep daemon exits after three unreachable snapshots'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local dir daemon_pid i
  dir="$(hpl_socket_dir "$HPL_DEFAULT_SOCKET")"
  : > "$dir/fail-snapshot"
  HPL_SWEEP_INTERVAL=0.01 hpl_sweep_run --sweep-daemon &
  daemon_pid=$!
  for i in $(seq 1 $HPL_WAIT_POLLS); do
    kill -0 "$daemon_pid" 2>/dev/null || break
    sleep 0.01
  done
  if kill -0 "$daemon_pid" 2>/dev/null; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    fail "sweep daemon kept polling an unreachable socket"
  fi
  wait "$daemon_pid"
  run grep -c '^api snapshot$' "$HPL_LOG"
  assert_output "3"
  assert_dir_not_exists "$(hpl_namespace "$HPL_DEFAULT_SOCKET")/sweep.lock"
}

function test_scripts_1179_herdr_pane_labels_names_an_agent_whose_fresh_pane_repor() {
  _bats_test_init 1179 'herdr-pane-labels names an agent whose fresh pane reports no label yet'
  command -v jq >/dev/null || skip "jq not available"
  source "$HERDR_ALIASES"
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude
  # herdr 0.8.2 omits `label` from a pane that has never been renamed. The
  # engine must read that as an empty label, not reject the snapshot: rejecting
  # deadlocks the pipeline, because this engine is the only label writer.
  hpl_transform_state "$HPL_DEFAULT_SOCKET" 'del(.panes[0].label)'

  run hpl_sweep_run --sweep
  assert_success

  local state alias
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  alias="$(jq -r '.agents[0].name // ""' "$state")"
  run herdr_alias_in_pool "$alias"
  assert_success
  assert_equal "$(jq -r '.panes[0].label' "$state")" "cc:$alias"
}

# herdr pane-label cutover (U5)
# ===========================================

function test_scripts_1301_herdr_pane_label_cutover_selects_modes_only_for_the_con() {
  _bats_test_init 1301 'herdr pane-label cutover selects modes only for the configured engine paths'
  local library="$SOURCE_ROOT/.chezmoitemplates/herdr-pane-labels-cutover-lib.sh"
  run env HOME="$BATS_TEST_TMPDIR/cutover-mode-home" bash -c '
    source "$1"
    [ "$(hpl_cutover_mode_for_engine "$HPL_CUTOVER_OLD_ENGINE")" = --ensure-daemon ]
    [ "$(hpl_cutover_mode_for_engine "$HPL_CUTOVER_NEW_ENGINE")" = --ensure-sweep-daemon ]
    ! hpl_cutover_mode_for_engine "$HOME/.local/bin/unknown-engine"
  ' _ "$library"
  assert_success
}

function test_scripts_1302_herdr_pane_label_cutover_accepts_unlabeled_fresh_panes() {
  _bats_test_init 1302 'herdr pane-label cutover accepts unlabeled fresh panes but still rejects unsafe labels'
  command -v jq >/dev/null || skip "jq not available"
  local library="$SOURCE_ROOT/.chezmoitemplates/herdr-pane-labels-cutover-lib.sh"
  local script="$BATS_TEST_TMPDIR/cutover-label-check.sh"
  # herdr 0.8.2 omits `label` from a pane that has never been renamed. The
  # cutover validator must accept that shape, or the before-script blocks every
  # apply for as long as one fresh pane exists.
  cat > "$script" <<'CHECK'
source "$1"
pane_snapshot() {
  jq -c --argjson pane "$1" '{result:{snapshot:{
    panes:[$pane],
    tabs:[{tab_id:"tab1",workspace_id:"ws1",label:"1"}],
    agents:[],layouts:[],workspaces:[{workspace_id:"ws1"}]}}}' <<< '{}'
}
base='{"pane_id":"p1","terminal_id":"t1","tab_id":"tab1","workspace_id":"ws1","revision":1}'
pane_snapshot "$(jq -c 'del(.label)' <<< "$base")" | hpl_cutover_snapshot_is_complete || exit 1
pane_snapshot "$(jq -c '.label = null' <<< "$base")" | hpl_cutover_snapshot_is_complete || exit 1
pane_snapshot "$(jq -c '.label = "cc:red-wolf"' <<< "$base")" | hpl_cutover_snapshot_is_complete || exit 1
pane_snapshot "$(jq -c '.label = "badlabel"' <<< "$base")" | hpl_cutover_snapshot_is_complete && exit 1
exit 0
CHECK
  run env HOME="$BATS_TEST_TMPDIR/cutover-label-home" bash "$script" "$library"
  assert_success
}











function test_scripts_1312_herdr_pane_label_cutover_rejects_an_incomplete_cleanup_() {
  _bats_test_init 1312 'herdr pane-label cutover rejects an incomplete cleanup snapshot'
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local state tmp
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  tmp="$state.tmp"
  jq '.complete=false' "$state" > "$tmp" && mv "$tmp" "$state"

  run hpl_cutover_run "$HPL_CUTOVER_BEFORE"

  assert_failure
  run grep -q '^pane report-metadata.*--clear-token task' "$HPL_LOG"
  assert_failure
}




function test_scripts_1316_herdr_pane_label_after_script_links_offline_without_liv() {
  _bats_test_init 1316 'herdr pane-label after script links offline without live-only commands'
  skip_if_no_chezmoi
  hpl_cutover_setup
  hpl_cutover_sessions
  : > "$HPL_WORK/fail-live-plugin-command-without-sessions"

  run hpl_cutover_run "$HPL_CUTOVER_AFTER"

  assert_success
  assert_file_contains "$HPL_WORK/plugin.log" '^plugin link '
  assert_output --partial "no running Herdr sessions require verification"
  run grep -E '^plugin enable |^server reload-config$' "$HPL_WORK/plugin.log"
  assert_failure
}

function test_scripts_1317_herdr_pane_label_after_script_catches_a_session_created() {
  _bats_test_init 1317 'herdr pane-label after script catches a session created during plugin linking'
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local late_socket="$HPL_WORK/late-start.sock"
  hpl_cutover_sessions
  : > "$HPL_WORK/require-live-plugin-command-socket"
  hpl_set_agent_pane "$late_socket" pane-late tab-late ws-late term-late claude red-wolf
  printf '%s\n' '{"result":{"sessions":[{"running":true,"socket_path":"'"$late_socket"'"}]}}' \
    > "$HPL_WORK/sessions-after-link.json"

  run hpl_cutover_run "$HPL_CUTOVER_AFTER"

  assert_success
  grep -Fxq "$late_socket|plugin enable seigi.pane-labels" "$HPL_WORK/plugin-sockets.log"
  grep -Fxq "$late_socket|server reload-config" "$HPL_WORK/plugin-sockets.log"
  run grep -Fx "$HPL_DEFAULT_SOCKET|plugin enable seigi.pane-labels" "$HPL_WORK/plugin-sockets.log"
  assert_failure
  run grep -Fx "$HPL_DEFAULT_SOCKET|server reload-config" "$HPL_WORK/plugin-sockets.log"
  assert_failure
  assert_file_contains "$HPL_CUTOVER_TRACE" "^first-pass:$late_socket$"
  assert_file_contains "$HPL_CUTOVER_TRACE" "^daemon-verified:$late_socket:"
}

function test_scripts_1318_herdr_pane_label_after_script_disables_known_sessions_w() {
  _bats_test_init 1318 'herdr pane-label after script disables known sessions when post-link discovery fails'
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local saved_socket="$HPL_WORK/saved.sock"
  hpl_cutover_sessions "$saved_socket"
  : > "$HPL_WORK/require-live-plugin-command-socket"
  printf '%s\n' 2 > "$HPL_WORK/fail-session-list-at"

  run hpl_cutover_run "$HPL_CUTOVER_AFTER"

  assert_failure
  assert_output --partial "cannot inspect running Herdr sessions"
  grep -Fxq "$saved_socket|plugin disable seigi.pane-labels" "$HPL_WORK/plugin-sockets.log"
  assert_file_contains "$HPL_WORK/plugin.log" '^plugin link .* --disabled$'
  run grep -Fx "$HPL_DEFAULT_SOCKET|plugin disable seigi.pane-labels" "$HPL_WORK/plugin-sockets.log"
  assert_failure
}

function test_scripts_1319_herdr_pane_label_post_link_discovery_failure_disables_t() {
  _bats_test_init 1319 'herdr pane-label post-link discovery failure disables the offline registry without sessions'
  skip_if_no_chezmoi
  hpl_cutover_setup
  hpl_cutover_sessions
  printf '%s\n' 2 > "$HPL_WORK/fail-session-list-at"

  run hpl_cutover_run "$HPL_CUTOVER_AFTER"

  assert_failure
  assert_output --partial "cannot inspect running Herdr sessions"
  assert_file_contains "$HPL_WORK/plugin.log" '^plugin link .* --disabled$'
  run grep -E '^plugin enable |^plugin disable |^server reload-config$' "$HPL_WORK/plugin.log"
  assert_failure
}

function test_scripts_1320_herdr_pane_label_activation_failure_still_disables_ever() {
  _bats_test_init 1320 'herdr pane-label activation failure still disables every remaining live session'
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local stale_socket="$HPL_WORK/a-stale.sock" live_socket="$HPL_WORK/z-live.sock"
  hpl_cutover_sessions "$stale_socket" "$live_socket"
  hpl_set_agent_pane "$stale_socket" pane-stale tab-stale ws-stale term-stale claude red-wolf
  hpl_set_agent_pane "$live_socket" pane-live tab-live ws-live term-live opencode blue-fox
  : > "$HPL_WORK/require-live-plugin-command-socket"
  printf '%s\n' '{"result":{"sessions":[{"running":true,"socket_path":"'"$live_socket"'"}]}}' \
    > "$HPL_WORK/sessions-before-enable.json"

  run hpl_cutover_run "$HPL_CUTOVER_AFTER"

  assert_failure
  assert_output --partial "failed to enable or reload seigi.pane-labels"
  grep -Fxq "$live_socket|plugin enable seigi.pane-labels" "$HPL_WORK/plugin-sockets.log"
  grep -Fxq "$live_socket|plugin disable seigi.pane-labels" "$HPL_WORK/plugin-sockets.log"
}

function test_scripts_1321_herdr_pane_label_after_script_rejects_a_failed_first_sw() {
  _bats_test_init 1321 'herdr pane-label after script rejects a failed first sweep'
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local state tmp
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  tmp="$state.tmp"
  jq '.complete=false' "$state" > "$tmp" && mv "$tmp" "$state"

  run hpl_cutover_run "$HPL_CUTOVER_AFTER"

  assert_failure
  assert_file_contains "$HPL_WORK/plugin.log" '^plugin disable seigi\.pane-labels$'
  refute_output --partial "linked and verified"
}


# A live machine changes agent state while the sweep runs, and the strict pass
# compares the whole snapshot identity, so the first attempt can fail with every
# label already converged. Aborting the apply there disables pane labels for a
# condition that clears itself.
function test_scripts_1322_herdr_pane_label_after_script_retries_a_transiently_fai() {
  _bats_test_init 1322 'herdr pane-label after script retries a transiently failed first sweep'
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  hpl_cutover_sessions "$HPL_DEFAULT_SOCKET"
  printf '%s\n' 1 > "$HPL_WORK/sweep-failures"
  cat > "$HPL_CUTOVER_HOME/.local/bin/herdr-pane-labels" <<'SH'
#!/usr/bin/env bash
set -u
socket="${HERDR_SOCKET_PATH:-}"
namespace="$HOME/.cache/herdr-pane-labels/sockets/$(printf '%s' "$socket" | base64 | tr '/+' '_-' | tr -d '=\n')"
write_socket() {
  mkdir -p "$namespace"
  printf 'socket_path=%s\n' "$(printf '%s' "$socket" | base64 | tr -d '\n')" > "$namespace/socket.state"
}
case "${1:-}" in
  --sweep)
    count=0
    [ ! -f "$HPL_WORK/sweep-count" ] || read -r count < "$HPL_WORK/sweep-count"
    count=$((count + 1))
    printf '%s\n' "$count" > "$HPL_WORK/sweep-count"
    failures=0
    [ ! -f "$HPL_WORK/sweep-failures" ] || read -r failures < "$HPL_WORK/sweep-failures"
    if [ "$count" -le "$failures" ]; then
      printf 'herdr-pane-labels: strict sweep identity changed before verification\n' >&2
      exit 1
    fi
    ;;
  --ensure-sweep-daemon)
    write_socket
    if [ -f "$namespace/sweep.lock/pid" ] && kill -0 "$(cat "$namespace/sweep.lock/pid")" 2>/dev/null; then exit 0; fi
    mkdir -p "$namespace/sweep.lock"
    nohup bash "$0" --sweep-daemon </dev/null >/dev/null 2>&1 &
    ;;
  --sweep-daemon)
    write_socket
    mkdir -p "$namespace/sweep.lock"
    printf '%s' "$$" > "$namespace/sweep.lock/pid"
    trap 'rm -f "$namespace/sweep.lock/pid"; rmdir "$namespace/sweep.lock" 2>/dev/null || true; exit 0' INT TERM EXIT
    while :; do sleep 1; done
    ;;
esac
SH
  chmod +x "$HPL_CUTOVER_HOME/.local/bin/herdr-pane-labels"

  export HERDR_PANE_LABELS_CUTOVER_SWEEP_PAUSE=0
  run hpl_cutover_run "$HPL_CUTOVER_AFTER"
  unset HERDR_PANE_LABELS_CUTOVER_SWEEP_PAUSE

  assert_success
  assert_output --partial "linked and verified"
  assert_file_contains "$HPL_CUTOVER_TRACE" "^strict-sweep-retry:$HPL_DEFAULT_SOCKET:1$"
  assert_file_contains "$HPL_CUTOVER_TRACE" "^first-pass:$HPL_DEFAULT_SOCKET$"
  assert_dir_not_exists "$HPL_CUTOVER_HOME/.cache/herdr-pane-labels/cutover-rollback"
}

# The same retry must not paper over a sweep that never converges: every attempt
# fails, so the cutover still disables the plugin and reports the failure.
function test_scripts_1324_herdr_pane_label_after_script_still_fails_a_sweep_that_() {
  _bats_test_init 1324 'herdr pane-label after script still fails a sweep that never converges'
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  hpl_cutover_sessions "$HPL_DEFAULT_SOCKET"
  printf '%s\n' 99 > "$HPL_WORK/sweep-failures"
  cat > "$HPL_CUTOVER_HOME/.local/bin/herdr-pane-labels" <<'SH'
#!/usr/bin/env bash
set -u
socket="${HERDR_SOCKET_PATH:-}"
namespace="$HOME/.cache/herdr-pane-labels/sockets/$(printf '%s' "$socket" | base64 | tr '/+' '_-' | tr -d '=\n')"
case "${1:-}" in
  --sweep)
    count=0
    [ ! -f "$HPL_WORK/sweep-count" ] || read -r count < "$HPL_WORK/sweep-count"
    count=$((count + 1))
    printf '%s\n' "$count" > "$HPL_WORK/sweep-count"
    failures=0
    [ ! -f "$HPL_WORK/sweep-failures" ] || read -r failures < "$HPL_WORK/sweep-failures"
    if [ "$count" -le "$failures" ]; then
      printf 'herdr-pane-labels: strict sweep identity changed before verification\n' >&2
      exit 1
    fi
    ;;
  --ensure-sweep-daemon)
    mkdir -p "$namespace"
    printf 'socket_path=%s\n' "$(printf '%s' "$socket" | base64 | tr -d '\n')" > "$namespace/socket.state"
    ;;
esac
SH
  chmod +x "$HPL_CUTOVER_HOME/.local/bin/herdr-pane-labels"

  export HERDR_PANE_LABELS_CUTOVER_SWEEP_PAUSE=0 HERDR_PANE_LABELS_CUTOVER_SWEEP_ATTEMPTS=2
  run hpl_cutover_run "$HPL_CUTOVER_AFTER"
  unset HERDR_PANE_LABELS_CUTOVER_SWEEP_PAUSE HERDR_PANE_LABELS_CUTOVER_SWEEP_ATTEMPTS

  assert_failure
  assert_output --partial "strict pane-label sweep did not converge"
  assert_file_contains "$HPL_WORK/plugin.log" '^plugin disable seigi\.pane-labels$'
  run cat "$HPL_WORK/sweep-count"
  assert_output 2
}

function test_scripts_1323_herdr_pane_label_after_script_skips_missing_herdr_witho() {
  _bats_test_init 1323 'herdr pane-label after script skips missing herdr without a transaction'
  skip_if_no_chezmoi
  hpl_cutover_setup
  mv "$HPL_STUB/herdr" "$HPL_STUB/herdr.unavailable"

  run hpl_cutover_run "$HPL_CUTOVER_AFTER"

  assert_success
  assert_output --partial "herdr not found; skipping pane-labels plugin link"
  assert_dir_not_exists "$HPL_CUTOVER_HOME/.cache/herdr-pane-labels/cutover-rollback"
}



# ===========================================
# Claude settings modifier
# ===========================================

function test_scripts_245_claude_settings_modifier_registers_the_executor() {
  _bats_test_init 245 'Claude settings modifier registers the executor MCP server over stdio'
  local modifier="$SOURCE_ROOT/modify_dot_claude.json"
  local stub_bin="$BATS_TEST_TMPDIR/claude-modifier-bin"

  # executor registers with or without 1Password; the stub is here so one run
  # also covers the credentialed servers, whose entries exist only when `op`
  # answers.
  mkdir -p "$stub_bin"
  cat > "$stub_bin/op" <<'STUB'
#!/bin/sh
echo "stub-credential"
STUB
  chmod +x "$stub_bin/op"

  run env PATH="$stub_bin:$PATH" HOME=/stub/home bash "$modifier" \
    <<< '{"mcpServers":{"stale":{"type":"stdio"}},"other":"preserved"}'

  assert_success
  # stdio rather than the daemon's HTTP endpoint: the CLI resolves the scope and
  # token from ~/.executor itself, so no rotating secret lands in a tracked file.
  run jq -e '
    (.mcpServers.executor == {
      "type": "stdio",
      "command": "/stub/home/.local/bin/executor",
      "args": ["mcp"],
      "env": {}
    })
    and (.mcpServers["tavily-mcp"].url ==
      "https://mcp.tavily.com/mcp/?tavilyApiKey=stub-credential")
    and (.mcpServers | has("stale") | not)
    and (.other == "preserved")
  ' <<< "$output"
  assert_success
}

function test_scripts_246_claude_settings_modifier_registers_the_credentia() {
  _bats_test_init 246 'Claude settings modifier registers the credential-free MCP servers without 1Password'
  local modifier="$SOURCE_ROOT/modify_dot_claude.json"
  local jq_bin="$BATS_TEST_TMPDIR/claude-modifier-jq-bin"

  # Control for the test above. deepwiki, fff, and executor carry no credential,
  # so a machine where `op` never resolves must still get them; only jina and
  # tavily-mcp depend on 1Password and stay out rather than registering with an
  # empty key. A bare `op` absence is how CI and Docker run, so it stays silent.
  #
  # PATH_WITHOUT_OP drops every directory that holds an `op`, jq included when
  # the two share one. Re-front jq so this lands in the credential-free branch
  # rather than the no-jq guard the test below owns.
  mkdir -p "$jq_bin"
  ln -s "$(command -v jq)" "$jq_bin/jq"

  run --separate-stderr env PATH="$jq_bin:$PATH_WITHOUT_OP" HOME=/stub/home bash "$modifier" \
    <<< '{"mcpServers":{"stale":{"type":"stdio"}},"other":"preserved"}'

  assert_success
  assert_stderr ""
  run jq -e '
    ((.mcpServers | keys | sort) == ["deepwiki","executor","fff"])
    and (.mcpServers.executor.command == "/stub/home/.local/bin/executor")
    and (.other == "preserved")
  ' <<< "$output"
  assert_success
}

function test_scripts_247_claude_settings_modifier_registers_each_credenti() {
  _bats_test_init 247 'Claude settings modifier registers each credentialed MCP server independently'
  local modifier="$SOURCE_ROOT/modify_dot_claude.json"
  local stub_bin="$BATS_TEST_TMPDIR/claude-modifier-partial-bin"

  # One key resolves and the other comes back empty. The two servers must not
  # share a fate: the credential that exists is no reason to withhold its server
  # because the other one is missing.
  mkdir -p "$stub_bin"
  cat > "$stub_bin/op" <<'STUB'
#!/bin/sh
case "$2" in
  *Jina*) echo "jina-credential" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$stub_bin/op"

  run --separate-stderr env PATH="$stub_bin:$PATH" HOME=/stub/home bash "$modifier" \
    <<< '{"mcpServers":{}}'

  assert_success
  # `op` is installed yet answered nothing, which is a missing sign-in rather
  # than a deliberately credential-free machine. Say so without failing the
  # apply, and name the credential so the cause is readable.
  assert_stderr --partial "Tavily API Key"
  refute_stderr --partial "Jina API Key"
  run jq -e '
    ((.mcpServers | keys | sort) == ["deepwiki","executor","fff","jina"])
    and (.mcpServers.jina.headers.Authorization == "Bearer jina-credential")
  ' <<< "$output"
  assert_success
}

function test_scripts_248_claude_settings_modifier_registers_tavily_mcp_wh() {
  _bats_test_init 248 'Claude settings modifier registers tavily-mcp when only its credential resolves'
  local modifier="$SOURCE_ROOT/modify_dot_claude.json"
  local stub_bin="$BATS_TEST_TMPDIR/claude-modifier-tavily-bin"

  # The mirror of the test above. The two credentialed servers are built by
  # different jq expressions -- one a headers object, one a URL carrying the key
  # inline -- so covering one direction does not cover the other.
  mkdir -p "$stub_bin"
  cat > "$stub_bin/op" <<'STUB'
#!/bin/sh
case "$2" in
  *Tavily*) echo "tavily-credential" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$stub_bin/op"

  run --separate-stderr env PATH="$stub_bin:$PATH" HOME=/stub/home bash "$modifier" \
    <<< '{"mcpServers":{}}'

  assert_success
  assert_stderr --partial "Jina API Key"
  refute_stderr --partial "Tavily API Key"
  run jq -e '
    ((.mcpServers | keys | sort) == ["deepwiki","executor","fff","tavily-mcp"])
    and (.mcpServers["tavily-mcp"].url ==
      "https://mcp.tavily.com/mcp/?tavilyApiKey=tavily-credential")
  ' <<< "$output"
  assert_success
}

function test_scripts_249_claude_settings_modifier_passes_settings_through() {
  _bats_test_init 249 'Claude settings modifier passes settings through untouched without jq'
  local modifier="$SOURCE_ROOT/modify_dot_claude.json"
  local input='{"mcpServers":{"kept":{"type":"stdio"}}}'
  local stub_bin="$BATS_TEST_TMPDIR/claude-modifier-nojq-bin"

  # The modifier builds every server entry with jq, so a machine without it has
  # no way to write the file. Echoing stdin unchanged is the only safe answer,
  # and it is the one guard that must survive the credential-free split above.
  mkdir -p "$stub_bin"
  ln -s "$(command -v cat)" "$stub_bin/cat"
  ln -s "$(command -v bash)" "$stub_bin/bash"

  run env PATH="$stub_bin" bash "$modifier" <<< "$input"

  assert_success
  assert_output "$input"
}

# ===========================================
# Pi settings modifier
# ===========================================

function test_scripts_250_pi_settings_modifier_selects_the_terminal_theme() {
  _bats_test_init 250 'Pi settings modifier uses portable skills and the managed package set'
  local modifier="$SOURCE_ROOT/dot_pi/agent/modify_settings.json"
  local input='{"theme":"light","lastChangelogVersion":"0.84.2","packages":["git:github.com/EveryInc/compound-engineering-plugin","npm:obsolete-extension"],"skills":["~/.claude/skills","~/custom/skills"]}'

  run bash "$modifier" <<< "$input"

  assert_success
  # Restating the managed package names here would copy them out of the
  # modifier this test runs, so adding or dropping an extension would edit
  # both sides in one patch and never fail. What the modifier owes its
  # consumer is the replacement itself: the caller's packages array is
  # discarded, whatever it held, and only npm specs survive.
  run jq -e '
    .theme == "terminal" and
    .lastChangelogVersion == "0.84.2" and
    ((.packages | index("npm:obsolete-extension")) == null) and
    ((.packages | map(select(startswith("git:"))) | length) == 0) and
    ((.packages | length) > 0) and
    (.packages | all(startswith("npm:"))) and
    (.skills == ["~/custom/skills"])
  ' <<< "$output"
  assert_success
}

function test_scripts_251_pi_settings_modifier_is_idempotent() {
  _bats_test_init 251 'Pi settings modifier is idempotent'
  local modifier="$SOURCE_ROOT/dot_pi/agent/modify_settings.json"
  local input='{"lastChangelogVersion":"0.84.2","model":"anthropic/claude-sonnet-4-5","packages":["npm:@ff-labs/pi-fff","npm:@howaboua/pi-codex-conversion","npm:pi-subagents","npm:pi-agent-browser-native","git:github.com/EveryInc/compound-engineering-plugin","npm:pi-ask-user","npm:@trevonistrevon/pi-loop","npm:pi-web-access","npm:pi-context-view"],"skills":["~/custom/skills","~/.claude/skills"]}'
  local once

  run bash "$modifier" <<< "$input"

  assert_success
  once="$output"
  # The input above already carries the managed names, so comparing them back
  # would compare the fixture to itself. The contract here is that unrelated
  # user settings survive the rewrite and the git: entry does not.
  run jq -e '
    (.theme == "terminal") and
    (.lastChangelogVersion == "0.84.2") and
    (.model == "anthropic/claude-sonnet-4-5") and
    ((.packages | map(select(startswith("git:"))) | length) == 0) and
    (.packages | all(startswith("npm:"))) and
    (.skills == ["~/custom/skills"])
  ' <<< "$once"
  assert_success

  run bash "$modifier" <<< "$once"

  assert_success
  assert_output "$once"
}

function test_scripts_252_pi_terminal_theme_uses_only_terminal_palette_col() {
  _bats_test_init 252 'Pi terminal theme uses only terminal palette colors'
  local theme="$SOURCE_ROOT/dot_pi/agent/themes/terminal.json"

  # Naming two arbitrary empty slots proved nothing about the palette. The
  # property is structural and cross-references two independently edited
  # sections of the file: every colour either inherits (empty string) or
  # names a slot the vars block declares, so no colour can hardcode a value
  # the user's terminal does not control.
  run jq -e '
    .name == "terminal" and
    ([.vars[]] | all(type == "number" and . >= 0 and . <= 15)) and
    (. as $theme
      | [$theme.colors[]
         | select(type == "string")
         | . as $value
         | select($value != "" and (($theme.vars | has($value)) | not))]
      | length == 0)
  ' "$theme"
  assert_success
}

function test_scripts_253_claude_code_daltonized_theme_extends_light_ansi() {
  _bats_test_init 253 'Claude Code daltonized theme extends light ANSI with terminal colors'
  local theme="$SOURCE_ROOT/private_dot_claude/themes/light-ansi-daltonized.json"

  # length > 0 is not a content assertion -- it is the anti-vacuity guard that
  # keeps the slot-form check below from passing on an empty overrides object.
  # The vocabulary is the standard 16 ANSI colour names, which is what Claude
  # Code's theme loader resolves; a bare startswith("ansi:") would also accept
  # ansi:tomato, which resolves to nothing.
  run jq -e '
    ["black","red","green","yellow","blue","magenta","cyan","white",
     "blackBright","redBright","greenBright","yellowBright",
     "blueBright","magentaBright","cyanBright","whiteBright"] as $ansi |
    .base == "light-ansi" and
    (.overrides | length > 0) and
    ([.overrides[] | . as $value
      | select(($value | type) != "string"
               or ($value | startswith("ansi:") | not)
               or (($ansi | index($value | ltrimstr("ansi:"))) == null))]
     | length == 0)
  ' "$theme"
  assert_success
}

# ===========================================
# morning-cleanup script
# ===========================================

function test_scripts_254_morning_cleanup_trashes_stale_omc_state_and_stam() {
  _bats_test_init 254 'morning-cleanup trashes stale .omc state and stamps the day'
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

function test_scripts_255_morning_cleanup_keeps_a_recently_active_omc_dir() {
  _bats_test_init 255 'morning-cleanup keeps a recently active .omc dir'
  local script="$SOURCE_ROOT/dot_local/bin/executable_morning-cleanup.sh"
  local fake_home="$BATS_TEST_TMPDIR/mc-home-live"
  mkdir -p "$fake_home/Projects/demo/.omc"
  printf '{}' > "$fake_home/Projects/demo/.omc/state.json"

  run env HOME="$fake_home" MORNING_CLEANUP_NO_NOTIFY=1 bash "$script"
  assert_success
  [ -d "$fake_home/Projects/demo/.omc" ]
}

function test_scripts_256_morning_cleanup_is_a_no_op_on_its_second_run_of() {
  _bats_test_init 256 'morning-cleanup is a no-op on its second run of the day'
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

function test_scripts_257_morning_cleanup_keeps_fresh_trash_entries() {
  _bats_test_init 257 'morning-cleanup keeps fresh trash entries'
  local script="$SOURCE_ROOT/dot_local/bin/executable_morning-cleanup.sh"
  local fake_home="$BATS_TEST_TMPDIR/mc-home-trash"
  mkdir -p "$fake_home/Projects" "$fake_home/.scratchpad/fresh-entry"
  printf 'x' > "$fake_home/.scratchpad/fresh-entry/file"

  run env HOME="$fake_home" MORNING_CLEANUP_NO_NOTIFY=1 bash "$script"
  assert_success
  [ -d "$fake_home/.scratchpad/fresh-entry" ]
}

# Wires the herdr-child descriptor probe into the suite. run-post-apply.sh runs
# a fixed file list, so without this nested invocation the probe file would be
# dead coverage again -- its bats ancestor was exactly that
# (docs/issues/2026-08-29-002). A dedicated file, not an inline test, because
# the probe must observe launcher-descriptor EOF from outside any suite whose
# runner shares those descriptors.
function test_scripts_258_herdr_child_descriptor_probe_passes_under_a_nes() {
  _bats_test_init 258 'herdr-child descriptor probe passes under a nested bashunit run'
  local probe_file="$BATS_TEST_DIRNAME/bashunit/herdr_child_descriptor_probe_test.sh"
  assert_file_exists "$probe_file"
  run env NO_COLOR=1 "$BATS_TEST_DIRNAME/lib/bashunit" "$probe_file"
  assert_success
  # Bashunit abbreviates long titles to the terminal width in Docker panes.
  assert_output --partial "Passed: herdr-child detached watcher closes launcher desc"
}

# Guards the local patch in the pinned runner itself ('Local patch vs upstream
# 0.50.1' in tests/lib/bashunit): result parsing takes the last
# ##TEST_EXIT_CODE=-marked line, not the blind last line. A re-pin of bashunit
# that drops the patch turns this test red
# (docs/issues/2026-08-29-003-pinned-bashunit-carries-a-local-patch-payload-
# marker-result-parsing).
function test_scripts_260_pinned_bashunit_survives_late_child_output_aft() {
  _bats_test_init 260 'pinned bashunit survives late child output after the result payload'
  local probe_file="$BATS_TEST_DIRNAME/bashunit/bashunit_late_output_probe_test.sh"
  assert_file_exists "$probe_file"

  # Parallel leg: aggregate_parallel_results parses the .result file.
  run env NO_COLOR=1 "$BATS_TEST_DIRNAME/lib/bashunit" -j 2 "$probe_file"
  assert_success
  assert_output --partial "Passed: late child output lands after the result payload"
  assert_output --partial "Assertions: 1 passed, 1 total"

  # Sequential leg: extract_result_counts parses the captured execution
  # result. Unpatched it stays exit 0 but reports 0 assertions, so the
  # assertion-count line is the discriminator here, not the status.
  run env NO_COLOR=1 "$BATS_TEST_DIRNAME/lib/bashunit" "$probe_file"
  assert_success
  assert_output --partial "Assertions: 1 passed, 1 total"
}

# watcher orphan self-termination (docs/issues/2026-08-28-001)
# ===========================================

function test_scripts_261_herdr_child_watcher_at_arm_barrier_exits_when_la() {
  _bats_test_init 261 'herdr-child watcher held at the arm barrier exits when its launcher is SIGKILLed'
  child_stub_herdr
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 STUB_START_CONTEXT=1 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_TEST_ARM_BARRIER="$CHILD_STUB/arm" \
    bash "$HERDR_CHILD" start --kind claude --detach \
    --prompt "test task" > /dev/null 2>&1 &
  local launcher_pid=$!
  local attempt=0
  while [ ! -e "$CHILD_STUB/arm.ready" ] && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$CHILD_STUB/arm.ready"
  local watcher_pid
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  # SIGKILL writes no abort.state, so only the watcher's own launcher
  # liveness check can free it from the held barrier.
  kill -KILL "$launcher_pid" 2>/dev/null || true
  wait "$launcher_pid" 2>/dev/null || true
  attempt=0
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  run kill -0 "$watcher_pid"
  assert_failure
}

function test_scripts_262_herdr_child_armed_watcher_exits_when_run_state_i() {
  _bats_test_init 262 'herdr-child armed watcher exits when its supervision run state is torn down'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  local watcher_pid
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  kill -0 "$watcher_pid"
  # Teardown-style destruction mid-poll: with the run dir gone every herdr
  # error looks transient, so an unguarded watcher spins forever.
  rm -rf "$CHILD_STUB/state"
  local attempt=0
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  run kill -0 "$watcher_pid"
  assert_failure
}

function test_scripts_263_herdr_child_watcher_release_hold_is_bounded() {
  _bats_test_init 263 'herdr-child watcher held for release self-terminates once the hold bound expires'
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    STUB_START_CONTEXT=1 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_TEST_WATCHER_RELEASE="$CHILD_STUB/release-watcher" \
    HERDR_CHILD_TEST_HOLD_TIMEOUT_SECONDS=1 \
    bash "$HERDR_CHILD" start --kind claude --detach \
    --prompt "test task"
  assert_success
  local watcher_pid
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  # No release file is ever written: an abandoned hold must expire on its own
  # instead of orphaning a polling daemon.
  local attempt=0
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 400 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  run kill -0 "$watcher_pid"
  assert_failure
}

function test_scripts_264_herdr_child_reap_invalidation_suppresses_delivery_already_in_progress() {
  _bats_test_init 264 'herdr-child reap invalidation suppresses delivery already in progress'
  child_lifecycle_stub_herdr
  HERDR_CHILD_TEST_REAP_OWNER_VERIFIED="$CHILD_STUB/reap-owner-verified"
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  local generation run_dir reap_pid reap_status attempt=0
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/block-delivery-pane-get"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/delivery-pane-get.ready"

  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_REAP_INVALIDATED_BARRIER="$CHILD_STUB/reap-invalidated" \
    bash "$HERDR_CHILD" reap --to orange-panda --pane wT:p9 >"$CHILD_STUB/reap.out" 2>&1 &
  reap_pid=$!
  CHILD_REAP_PID="$reap_pid"
  child_wait_for_file "$CHILD_STUB/reap-invalidated.ready"
  assert_file_not_exists "$CHILD_STUB/pane-closed"

  : > "$CHILD_STUB/delivery-pane-get.release"
  while [ ! -e "$CHILD_STUB/reap-owner-verified" ] && \
        [ ! -e "$CHILD_STUB/successful-prompts.log" ] && \
        [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  assert_file_not_exists "$CHILD_STUB/successful-prompts.log"
  assert_file_contains "$run_dir/invalidated.state" '^reason=reap$'

  : > "$CHILD_STUB/reap-invalidated.release"
  if wait "$reap_pid"; then reap_status=0; else reap_status=$?; fi
  CHILD_REAP_PID=""
  [ "$reap_status" -eq 0 ] || cat "$CHILD_STUB/reap.out" >&2
  assert_equal "$reap_status" 0
  assert_file_contains "$CHILD_STUB/reap.out" 'closed pane wT:p9'
  assert_file_exists "$CHILD_STUB/pane-closed"
  attempt=0
  while [ -d "$run_dir" ] && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_dir_not_exists "$run_dir"
}

function test_scripts_265_herdr_child_delivery_claim_keeps_reap_fail_closed_without_holding_guard() {
  _bats_test_init 265 'herdr-child delivery claim keeps reap fail closed without holding the transition guard'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  local generation run_dir watcher_pid attempt=0
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/block-parent-prompt"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/parent-prompt-accepted"
  assert_file_exists "$run_dir/delivery-pending.state"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reap --to orange-panda --pane wT:p9
  assert_success
  assert_output --partial 'supervision generation could not be invalidated'
  assert_file_not_exists "$CHILD_STUB/pane-closed"

  : > "$CHILD_STUB/release-parent-prompt"
  child_wait_for_file "$CHILD_STUB/successful-prompts.log"
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  assert_dir_not_exists "$run_dir"
}

function test_scripts_266_herdr_child_reap_recovers_a_delivery_claim_owned_by_a_dead_watcher() {
  _bats_test_init 266 'herdr-child reap recovers a delivery claim owned by a dead watcher'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  local generation run_dir watcher_pid attempt=0
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/block-parent-prompt"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/parent-prompt-accepted"
  assert_file_exists "$run_dir/delivery-pending.state"

  kill -KILL "$watcher_pid"
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reap --to orange-panda --pane wT:p9
  assert_success
  assert_output --partial 'closed pane wT:p9'
  assert_file_exists "$CHILD_STUB/pane-closed"
  : > "$CHILD_STUB/release-parent-prompt"
}

function test_scripts_267_herdr_child_transition_owner_identity_uses_a_stable_locale() {
  _bats_test_init 267 'herdr-child transition owner identity uses a stable locale'
  child_lifecycle_stub_herdr
  : > "$CHILD_STUB/observe-ps-locale"
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/block-parent-prompt"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/parent-prompt-accepted"
  assert_file_contains "$CHILD_STUB/ps-locales.log" '^C$'
  run grep -v '^C$' "$CHILD_STUB/ps-locales.log"
  assert_failure
  : > "$CHILD_STUB/release-parent-prompt"
}

function test_scripts_268_herdr_child_checkout_help_resolves_runtime_module() {
  _bats_test_init 268 'herdr-child checkout help resolves the runtime module'
  run bash "$HERDR_CHILD" --help
  assert_success
  assert_output --partial 'Usage:'
  refute_output --partial '__watcher'

  run bash "$HERDR_CHILD" not-a-command
  assert_failure 2
  assert_output --partial 'unknown subcommand: not-a-command'
}

function test_scripts_269_herdr_child_modules_source_cleanly_without_source_time_effects() {
  _bats_test_init 269 'herdr-child modules source cleanly without source-time effects'
  local lib_dir="$SOURCE_ROOT/dot_local/lib"

  run /bin/bash -s -- "$lib_dir" "$BATS_TEST_TMPDIR/module-loading" <<'BASH'
set -euo pipefail
lib_dir="$1"
work_dir="$2"
shift 2
set -- 'module positional one' 'module-positional-two'
mkdir -p "$work_dir"

snapshot_shell_state() {
  local output="$1"
  shift
  {
    set +o
    trap -p
    printf 'pwd=%s\n' "$PWD"
    printf 'umask=%s\n' "$(umask)"
    printf 'path=<%q>\n' "$PATH"
    printf 'home=<%q>\n' "$HOME"
    printf 'ifs=<%q>\n' "$IFS"
    shopt -p
    printf 'argv'
    printf ' <%q>' "$@"
    printf '\n'
  } > "$output"
}

snapshot_function_definitions() {
  local output="$1" names="$2" function_name
  {
    while IFS= read -r function_name; do
      printf '%s ' "$function_name"
      declare -f "$function_name" | cksum
    done < "$names"
  } > "$output"
}

snapshot_global_definitions() {
  local output="$1" names="$2" global_name
  {
    while IFS= read -r global_name; do
      case "$global_name" in
        BASH*|BASHPID|EPOCHREALTIME|EPOCHSECONDS|FUNCNAME|GROUPS|LINENO|\
          OPTARG|OPTIND|PIPESTATUS|RANDOM|SECONDS|SHLVL|SRANDOM|_|\
          global_name|names|output)
          continue
          ;;
      esac
      declare -p "$global_name" 2>/dev/null || true
    done < "$names"
  } > "$output"
}

# herdr-process.sh is the already-declared predecessor of every child module.
source "$lib_dir/herdr-process.sh"
while IFS= read -r module; do
  declare -F | awk '{print $3}' | LC_ALL=C sort > "$work_dir/functions.before"
  snapshot_function_definitions "$work_dir/function-definitions.before" "$work_dir/functions.before"
  compgen -v | LC_ALL=C sort > "$work_dir/globals.before"
  snapshot_global_definitions "$work_dir/global-definitions.before" "$work_dir/globals.before"
  snapshot_shell_state "$work_dir/state.before" "$@"
  if ! source "$lib_dir/$module" > "$work_dir/source.output" 2>&1; then
    printf '%s failed to source\n' "$module" >&2
    cat "$work_dir/source.output" >&2
    exit 1
  fi
  snapshot_shell_state "$work_dir/state.after" "$@"
  cmp -s "$work_dir/state.before" "$work_dir/state.after" || {
    printf '%s changed shell state at source time\n' "$module" >&2
    diff -u "$work_dir/state.before" "$work_dir/state.after" >&2 || true
    exit 1
  }
  [ ! -s "$work_dir/source.output" ] || {
    printf '%s produced output at source time\n' "$module" >&2
    cat "$work_dir/source.output" >&2
    exit 1
  }
  snapshot_function_definitions "$work_dir/function-definitions.after" "$work_dir/functions.before"
  cmp -s "$work_dir/function-definitions.before" "$work_dir/function-definitions.after" || {
    printf '%s redefined an existing function\n' "$module" >&2
    diff -u "$work_dir/function-definitions.before" "$work_dir/function-definitions.after" >&2 || true
    exit 1
  }
  snapshot_global_definitions "$work_dir/global-definitions.after" "$work_dir/globals.before"
  cmp -s "$work_dir/global-definitions.before" "$work_dir/global-definitions.after" || {
    printf '%s mutated an existing global at source time\n' "$module" >&2
    diff -u "$work_dir/global-definitions.before" "$work_dir/global-definitions.after" >&2 || true
    exit 1
  }
done <<'EOF'
herdr-child-runtime.sh
herdr-child-supervision.sh
herdr-child-watcher.sh
herdr-child-launch.sh
herdr-child-continuation.sh
herdr-child-reap.sh
EOF
BASH
  assert_success
  assert_output ''
}

function test_scripts_270_herdr_child_reap_invalidation_barrier_is_bounded() {
  _bats_test_init 270 'herdr-child reap invalidation barrier restores supervision when abandoned'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  local generation run_dir reap_pid reap_status attempt=0
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/block-delivery-pane-get"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/delivery-pane-get.ready"

  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_REAP_INVALIDATED_BARRIER="$CHILD_STUB/reap-invalidated" \
    HERDR_CHILD_TEST_HOLD_TIMEOUT_SECONDS=1 \
    bash "$HERDR_CHILD" reap --to orange-panda --pane wT:p9 > "$CHILD_STUB/reap-bounded.out" 2>&1 &
  reap_pid=$!
  CHILD_REAP_PID="$reap_pid"
  child_wait_for_file "$CHILD_STUB/reap-invalidated.ready"
  while kill -0 "$reap_pid" 2>/dev/null && [ "$attempt" -lt 300 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  if kill -0 "$reap_pid" 2>/dev/null; then
    kill -TERM "$reap_pid" 2>/dev/null || true
    wait "$reap_pid" 2>/dev/null || true
    CHILD_REAP_PID=""
    fail 'reap invalidation barrier exceeded its test hold bound'
  fi
  if wait "$reap_pid"; then reap_status=0; else reap_status=$?; fi
  CHILD_REAP_PID=""
  assert_equal "$reap_status" 1
  assert_file_not_exists "$CHILD_STUB/pane-closed"
  assert_dir_exists "$run_dir"
  assert_file_exists "$run_dir/invalidated.state"
  assert_file_exists "$run_dir/reap-pending.state"
  assert_file_exists "$run_dir/reap-restore.state"

  : > "$CHILD_STUB/delivery-pane-get.release"
  child_wait_for_file "$CHILD_STUB/successful-prompts.log"
  attempt=0
  while [ -d "$run_dir" ] && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  assert_file_not_exists "$CHILD_STUB/pane-closed"
  assert_dir_not_exists "$run_dir"
}

function test_scripts_2701_herdr_child_reap_owner_guard_stops_when_run_dir() {
  _bats_test_init 2701 'herdr-child reap owner guard stops when its run directory disappears'
  local work_dir runtime supervision guard_test_pid guard_test_status guard_pid attempt=0
  work_dir="$BATS_TEST_TMPDIR/reap-owner-guard"
  mkdir -p "$work_dir"
  runtime="$SOURCE_ROOT/dot_local/lib/herdr-child-runtime.sh"
  supervision="$SOURCE_ROOT/dot_local/lib/herdr-child-supervision.sh"

  env WORK_DIR="$work_dir" RUNTIME="$runtime" SUPERVISION="$supervision" bash -c '
    set -euo pipefail
    source "$RUNTIME"
    source "$SUPERVISION"

    normal_dir="$WORK_DIR/normal"
    mkdir -p "$normal_dir"
    start_reap_owner_guard "$normal_dir"
    stop_reap_owner_guard "$normal_dir"
    [ -d "$normal_dir" ]
    remove_supervision_run "$normal_dir"

    race_dir="$WORK_DIR/race"
    mkdir -p "$race_dir"
    start_reap_owner_guard "$race_dir"
    printf "%s\n" "$REAP_OWNER_GUARD_PID" > "$WORK_DIR/guard.pid"
    kill -STOP "$REAP_OWNER_GUARD_PID"
    (
      attempt=0
      while [ ! -e "$race_dir/reap-owner-$REAP_OWNER_TOKEN.release" ] && [ "$attempt" -lt 500 ]; do
        attempt=$((attempt + 1))
        sleep 0.01
      done
      [ "$attempt" -lt 500 ]
      remove_supervision_run "$race_dir"
      kill -CONT "$REAP_OWNER_GUARD_PID"
    ) &
    cleanup_pid=$!
    stop_reap_owner_guard "$race_dir"
    wait "$cleanup_pid"
    : > "$WORK_DIR/stopped"
  ' > "$work_dir/guard.out" 2>&1 &
  guard_test_pid=$!

  while kill -0 "$guard_test_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  if kill -0 "$guard_test_pid" 2>/dev/null; then
    guard_pid="$(cat "$work_dir/guard.pid" 2>/dev/null || true)"
    [ -z "$guard_pid" ] || kill -CONT "$guard_pid" 2>/dev/null || true
    [ -z "$guard_pid" ] || kill -TERM "$guard_pid" 2>/dev/null || true
    kill -TERM "$guard_test_pid" 2>/dev/null || true
    wait "$guard_test_pid" 2>/dev/null || true
    fail 'reap owner guard did not stop after its run directory disappeared'
  fi
  if wait "$guard_test_pid"; then guard_test_status=0; else guard_test_status=$?; fi
  assert_equal "$guard_test_status" 0
  assert_file_exists "$work_dir/stopped"
  assert_dir_not_exists "$work_dir/race"
}

function test_scripts_271_herdr_child_shared_lifecycle_primitives_keep_con() {
  _bats_test_init 271 'herdr-child shared lifecycle primitives keep polling and launch-state contracts'
  local work_dir runtime supervision
  work_dir="$(mktemp -d)"
  runtime="$SOURCE_ROOT/dot_local/lib/herdr-child-runtime.sh"
  supervision="$SOURCE_ROOT/dot_local/lib/herdr-child-supervision.sh"

  run env WORK_DIR="$work_dir" RUNTIME="$runtime" SUPERVISION="$supervision" bash -c '
    set -u
    source "$RUNTIME"
    source "$SUPERVISION"

    IFS=$'"'"'\n'"'"'
    write_launch_state "$WORK_DIR/launch.state" generation-1 12345 parent-pane \
      parent-terminal parent-session child-name child-pane child-terminal \
      child-session 42 || exit 10

    : > "$WORK_DIR/wanted.state"
    wait_for_watcher_state "$WORK_DIR/wanted.state" "$WORK_DIR/failed.state" "$$" || exit 11
    rm -f "$WORK_DIR/wanted.state"
    : > "$WORK_DIR/failed.state"
    status=0
    wait_for_watcher_state "$WORK_DIR/wanted.state" "$WORK_DIR/failed.state" "$$" || status=$?
    [ "$status" -eq 2 ] || exit 12
    rm -f "$WORK_DIR/failed.state"
    : > "$WORK_DIR/failure-only.state"
    wait_for_watcher_failure "$WORK_DIR/failure-only.state" "$$" || exit 13
    rm -f "$WORK_DIR/failure-only.state"
    status=0
    wait_for_watcher_failure "$WORK_DIR/failure-only.state" 2147483647 || status=$?
    [ "$status" -eq 1 ] || exit 14

    if write_launch_state "$WORK_DIR/invalid.state" generation-2 12345 parent-pane \
      parent-terminal parent-session $'"'"'bad\nname'"'"' child-pane child-terminal \
      child-session 42; then
      exit 15
    fi
  '
  assert_success
  # Reading the file back byte-for-byte pinned two things no consumer has: the
  # field order, and mode=, which no reader under home/dot_local/lib parses --
  # the watcher, supervision, and continuation modules all go through
  # state_value with a named key. What is load-bearing is the mapping from
  # write_launch_state's eleven positional arguments onto those keys, so
  # assert it through the same accessor those readers use. The expected values
  # are the arguments this test passed in, not text copied out of the writer.
  run env WORK_DIR="$work_dir" RUNTIME="$runtime" bash -c '
    set -u
    source "$RUNTIME"
    for pair in generation:generation-1 timeout_ms:12345 parent_pane:parent-pane \
      parent_terminal:parent-terminal parent_session:parent-session \
      child_name:child-name child_pane:child-pane child_terminal:child-terminal \
      child_session:child-session baseline_seq:42; do
      key="${pair%%:*}"
      want="${pair#*:}"
      got="$(state_value "$WORK_DIR/launch.state" "$key")"
      [ "$got" = "$want" ] || { printf "%s read back as %s, wanted %s\n" "$key" "$got" "$want"; exit 1; }
    done
  '
  assert_success
  assert_file_not_exists "$work_dir/invalid.state"
}

SKILLS_WRAPPER="$SOURCE_ROOT/dot_local/bin/executable_skills"

skills_stub_npx() {
  local stub="$BATS_TEST_TMPDIR/skills-stub"
  mkdir -p "$stub"
  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
printf 'PWD=%s\n' "$PWD" >> "$TMPDIR/npx.log"
printf 'HOME=%s\n' "${HOME:-}" >> "$TMPDIR/npx.log"
printf 'XDG_STATE_HOME=%s\n' "${XDG_STATE_HOME:-}" >> "$TMPDIR/npx.log"
printf 'ARGS=' >> "$TMPDIR/npx.log"
printf '<%s>' "$@" >> "$TMPDIR/npx.log"
printf '\n' >> "$TMPDIR/npx.log"
exit "${NPX_STATUS:-0}"
SH
  chmod +x "$stub/npx"
  printf '%s' "$stub"
}

function test_scripts_272_skills_add_is_global_isolated_and_preserves_cwd() {
  _bats_test_init 272 'skills add invokes npx globally in an isolated temporary-directory subshell'
  local stub original
  stub="$(skills_stub_npx)"
  original="$PWD"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache" \
    bash "$SKILLS_WRAPPER" add owner/repo named-skill
  assert_success
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '^PWD=.*/tmp$'
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '^ARGS=<--yes><skills@latest><add><owner/repo><--skill><named-skill><--global><--agent><claude-code><--agent><opencode><--agent><pi><--yes>$'
  assert_equal "$PWD" "$original"
}

function test_scripts_2721_skills_hides_success_output_but_preserves_verbose_and_failure_diagnostics() {
  _bats_test_init 2721 'skills hides successful upstream output but preserves verbose and failure diagnostics'
  local stub="$BATS_TEST_TMPDIR/skills-output-stub"
  mkdir -p "$stub"
  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'upstream stdout'
printf '%s\n' 'upstream stderr' >&2
for arg in "$@"; do [ "$arg" != fail ] || exit 7; done
SH
  chmod +x "$stub/npx"
  mkdir -p "$BATS_TEST_TMPDIR/home/.local/state/skills"
  printf '%s\n' '{"version":3,"skills":{"fail":{"source":"owner/repo"}}}' \
    > "$BATS_TEST_TMPDIR/home/.local/state/skills/.skill-lock.json"

  run --separate-stderr env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    bash "$SKILLS_WRAPPER" update
  assert_success
  assert_output ''
  assert_stderr ''

  run --separate-stderr env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    bash "$SKILLS_WRAPPER" --verbose update
  assert_success
  assert_output --partial 'upstream stdout'
  refute_output --partial 'upstream stderr'
  assert_stderr --partial 'upstream stderr'
  refute_stderr --partial 'upstream stdout'

  run --separate-stderr env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    bash "$SKILLS_WRAPPER" --verbose update fail
  assert_failure 7
  assert_output --partial 'upstream stdout'
  assert_stderr --partial 'upstream stderr'

  run --separate-stderr env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    bash "$SKILLS_WRAPPER" update fail
  assert_failure 7
  assert_output ''
  assert_stderr --partial 'upstream stdout'
  assert_stderr --partial 'upstream stderr'

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    bash "$SKILLS_WRAPPER" add owner/repo fail
  assert_failure 7

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    bash "$SKILLS_WRAPPER" remove owner/repo fail
  assert_failure 7

  run bash -c 'for item in "$1"/skills-output.*; do [ ! -e "$item" ] || exit 1; done' _ \
    "$BATS_TEST_TMPDIR/tmp"
  assert_success
}

function test_scripts_2722_skills_removes_captured_output_after_a_signal() {
  _bats_test_init 2722 'skills removes captured upstream output after a signal'
  local stub="$BATS_TEST_TMPDIR/skills-signal-stub"
  mkdir -p "$stub" "$BATS_TEST_TMPDIR/tmp"
  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'captured before interruption'
: > "$TMPDIR/npx-ready"
while :; do sleep 1; done
SH
  chmod +x "$stub/npx"

  run python3 - "$SKILLS_WRAPPER" "$stub" "$BATS_TEST_TMPDIR" <<'PY'
import glob
import os
import signal
import subprocess
import sys
import time

wrapper, stub, root = sys.argv[1:]
tmpdir = os.path.join(root, "tmp")
env = {"PATH": f"{stub}:/usr/bin:/bin", "HOME": os.path.join(root, "home"), "TMPDIR": tmpdir}
process = subprocess.Popen(["bash", wrapper, "update"], env=env, start_new_session=True)
deadline = time.monotonic() + 5
while not os.path.exists(os.path.join(tmpdir, "npx-ready")):
    if process.poll() is not None or time.monotonic() >= deadline:
        process.kill()
        raise SystemExit("upstream stub did not start")
    time.sleep(0.01)
os.killpg(process.pid, signal.SIGTERM)
status = process.wait(timeout=5)
if status == 0:
    raise SystemExit("interrupted wrapper succeeded")
if glob.glob(os.path.join(tmpdir, "skills-output.*")):
    raise SystemExit("captured output survived interruption")
PY
  assert_success
}

function test_scripts_273_skills_dispatch_validates_inert_argv_and_uses_global_remove_update() {
  _bats_test_init 273 'skills validates argv before npx and maps remove and update to global upstream calls'
  local stub="$BATS_TEST_TMPDIR/skills-stub" lock
  stub="$(skills_stub_npx)"
  lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  mkdir -p "$(dirname "$lock")"
  printf '%s\n' '{"version":3,"skills":{"owned":{"source":"owner/repo"}}}' > "$lock"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" bash "$SKILLS_WRAPPER" add owner/repo
  assert_success
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '<add><owner/repo><--skill><\*><--global>'

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" bash "$SKILLS_WRAPPER" remove owner/repo owned
  assert_success
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '<remove><--global><owned><--yes>$'

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" bash "$SKILLS_WRAPPER" update owned
  assert_success
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '<update><--global><owned>$'

  rm -f "$BATS_TEST_TMPDIR/tmp/npx.log"
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" bash "$SKILLS_WRAPPER" add 'owner/repo;touch'
  assert_failure
  assert_file_not_exists "$BATS_TEST_TMPDIR/tmp/npx.log"
}

function test_scripts_274_skills_rejects_malformed_lock_before_npx() {
  _bats_test_init 274 'skills sync fails closed on malformed live lock without npx mutation'
  local stub lock
  stub="$(skills_stub_npx)"
  lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  mkdir -p "$(dirname "$lock")"
  printf '%s\n' '{not-json' > "$lock"
  cp "$lock" "$BATS_TEST_TMPDIR/lock.before"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$SOURCE_ROOT/private_dot_config/agent-skills/manifest" bash "$SKILLS_WRAPPER" sync
  assert_failure
  run cmp "$BATS_TEST_TMPDIR/lock.before" "$lock"
  assert_success
  assert_file_not_exists "$BATS_TEST_TMPDIR/tmp/npx.log"
}

function test_scripts_275_skills_sync_stops_on_failed_install_without_drift_report() {
  _bats_test_init 275 'skills sync stops at a failed source install and does not report drift'
  local stub manifest lock
  stub="$(skills_stub_npx)"
  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TMPDIR/npx.log"
exit 9
SH
  chmod +x "$stub/npx"
  manifest="$BATS_TEST_TMPDIR/manifest"
  lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  mkdir -p "$(dirname "$lock")"
  : > "$BATS_TEST_TMPDIR/repository-owned"
  printf '%s\n' 'EveryInc/compound-engineering-plugin *' > "$manifest"
  printf '%s\n' '{"version":3,"skills":{"obsolete":{"source":"missing/source"}}}' > "$lock"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" SKILLS_MANIFEST="$manifest" \
    SKILLS_REPOSITORY_OWNED_MANIFEST="$BATS_TEST_TMPDIR/repository-owned" \
    bash "$SKILLS_WRAPPER" sync
  assert_failure 9
  refute_output --partial 'drift:'
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '^add$'
}

function test_scripts_276_skills_remove_uses_explicit_and_default_xdg_locks_identically() {
  _bats_test_init 276 'skills remove validates source ownership through explicit and default XDG state locks'
  local stub state_lock fallback_lock
  stub="$(skills_stub_npx)"
  state_lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  fallback_lock="$BATS_TEST_TMPDIR/home/.local/state/skills/.skill-lock.json"
  mkdir -p "$(dirname "$state_lock")" "$(dirname "$fallback_lock")"
  printf '%s\n' '{"version":3,"skills":{"owned":{"source":"owner/repo"}}}' > "$state_lock"
  printf '%s\n' '{"version":3,"skills":{"owned":{"source":"owner/repo"}}}' > "$fallback_lock"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" bash "$SKILLS_WRAPPER" remove owner/repo owned
  assert_success
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME= bash "$SKILLS_WRAPPER" remove owner/repo owned
  assert_success
  run grep -c '<remove><--global><owned><--yes>' "$BATS_TEST_TMPDIR/tmp/npx.log"
  assert_output '2'
}

function test_scripts_277_skills_sync_restores_repository_owned_wildcard_collision() {
  _bats_test_init 277 'skills sync restores a repository-owned wildcard collision and removes its lock claim'
  local stub manifest lock canonical
  stub="$(skills_stub_npx)"
  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' upstream > "$HOME/.agents/skills/local-skill/SKILL.md"
exit 0
SH
  chmod +x "$stub/npx"
  manifest="$BATS_TEST_TMPDIR/manifest"
  lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  canonical="$BATS_TEST_TMPDIR/home/.agents/skills"
  mkdir -p "$(dirname "$lock")" "$canonical/local-skill" "$BATS_TEST_TMPDIR/config/agent-skills"
  printf '%s\n' 'EveryInc/compound-engineering-plugin *' > "$manifest"
  printf '%s\n' local-skill > "$BATS_TEST_TMPDIR/config/agent-skills/repository-owned"
  printf '%s\n' '{"version":3,"skills":{"local-skill":{"source":"EveryInc/compound-engineering-plugin"}}}' > "$lock"
  printf '%s\n' original > "$canonical/local-skill/SKILL.md"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$manifest" bash "$SKILLS_WRAPPER" sync
  assert_failure
  run cat "$canonical/local-skill/SKILL.md"
  assert_output original
  run python3 - "$lock" <<'PY'
import json, sys
assert "local-skill" not in json.load(open(sys.argv[1]))["skills"]
PY
  assert_success
}

function test_scripts_278_skills_sync_blocks_unsafe_canonical_trees() {
  _bats_test_init 278 'skills sync blocks symlink, non-regular, and oversized canonical entries'
  local kind stub manifest lock canonical item skill offender
  for kind in symlink fifo oversized; do
    stub="$(skills_stub_npx)"
    manifest="$BATS_TEST_TMPDIR/$kind.manifest"
    lock="$BATS_TEST_TMPDIR/$kind/state/skills/.skill-lock.json"
    canonical="$BATS_TEST_TMPDIR/$kind/canonical"
    mkdir -p "$(dirname "$lock")" "$canonical" "$BATS_TEST_TMPDIR/$kind/config/agent-skills"
    : > "$BATS_TEST_TMPDIR/$kind/config/agent-skills/repository-owned"
    printf '%s\n' 'EveryInc/compound-engineering-plugin *' > "$manifest"
    printf '%s\n' '{"version":3,"skills":{"ce-code-review":{"source":"EveryInc/compound-engineering-plugin"},"ce-doc-review":{"source":"EveryInc/compound-engineering-plugin"},"ce-plan":{"source":"EveryInc/compound-engineering-plugin"},"ce-simplify-code":{"source":"EveryInc/compound-engineering-plugin"},"ce-work":{"source":"EveryInc/compound-engineering-plugin"}}}' > "$lock"
    for skill in ce-code-review ce-doc-review ce-plan ce-simplify-code ce-work; do
      mkdir -p "$canonical/$skill"
      printf '%s\n' skill > "$canonical/$skill/SKILL.md"
    done
    case "$kind" in
      symlink) ln -s /etc/passwd "$canonical/escape"; offender="$canonical/escape" ;;
      fifo) mkfifo "$canonical/non-regular"; offender="$canonical/non-regular" ;;
      oversized) dd if=/dev/zero of="$canonical/oversized" bs=1048577 count=1 2>/dev/null; offender="$canonical/oversized" ;;
    esac
    run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/$kind/home" TMPDIR="$BATS_TEST_TMPDIR/$kind/tmp" \
      XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/$kind/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/$kind/state" \
      SKILLS_MANIFEST="$manifest" SKILLS_CANONICAL_ROOT="$canonical" SKILLS_MAX_FILE_BYTES=1048576 \
    bash "$SKILLS_WRAPPER" sync
    assert_failure
    # A bare assert_failure is satisfied by any of the three iterations, so two
    # of the guards could be deleted and the loop would stay green. The
    # rejected path is this test's own fixture, so requiring the message to
    # name it makes each iteration prove its own guard fired.
    assert_output --partial "$offender"
  done
}

function test_scripts_2781_skills_sync_default_file_limit_accepts_large_documentation() {
  _bats_test_init 2781 'skills sync default file limit accepts a large upstream documentation artifact'
  local stub manifest lock canonical skill
  stub="$(skills_stub_npx)"
  manifest="$BATS_TEST_TMPDIR/manifest"
  lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  canonical="$BATS_TEST_TMPDIR/canonical"
  mkdir -p "$(dirname "$lock")" "$canonical/large-doc" "$BATS_TEST_TMPDIR/config/agent-skills"
  : > "$BATS_TEST_TMPDIR/config/agent-skills/repository-owned"
  printf '%s\n' 'example/large-doc large-doc' > "$manifest"
  printf '%s\n' '{"version":3,"skills":{"ce-code-review":{"source":"EveryInc/compound-engineering-plugin"},"ce-doc-review":{"source":"EveryInc/compound-engineering-plugin"},"ce-plan":{"source":"EveryInc/compound-engineering-plugin"},"ce-simplify-code":{"source":"EveryInc/compound-engineering-plugin"},"ce-work":{"source":"EveryInc/compound-engineering-plugin"},"large-doc":{"source":"example/large-doc"}}}' > "$lock"
  for skill in ce-code-review ce-doc-review ce-plan ce-simplify-code ce-work; do
    mkdir -p "$canonical/$skill"
    printf '%s\n' skill > "$canonical/$skill/SKILL.md"
  done
  dd if=/dev/zero of="$canonical/large-doc/llms-full.txt" bs=1105837 count=1 2>/dev/null
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$manifest" SKILLS_CANONICAL_ROOT="$canonical" bash "$SKILLS_WRAPPER" sync
  assert_success

  dd if=/dev/zero of="$canonical/large-doc/llms-full.txt" bs=2097153 count=1 2>/dev/null
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$manifest" SKILLS_CANONICAL_ROOT="$canonical" bash "$SKILLS_WRAPPER" sync
  assert_failure
  assert_output --partial 'canonical tree file exceeds 2097152 bytes'
}

function test_scripts_279_skills_sync_reports_installs_and_named_drift_but_not_wildcard_drift() {
  _bats_test_init 279 'skills sync reports installs and non-wildcard drift without removing it'
  local stub manifest lock canonical skill
  stub="$(skills_stub_npx)"
  manifest="$BATS_TEST_TMPDIR/manifest"
  lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  canonical="$BATS_TEST_TMPDIR/canonical"
  mkdir -p "$(dirname "$lock")" "$BATS_TEST_TMPDIR/config/agent-skills"
  : > "$BATS_TEST_TMPDIR/config/agent-skills/repository-owned"
  printf '%s\n' 'EveryInc/compound-engineering-plugin *' 'owner/repo desired' > "$manifest"
  printf '%s\n' '{"version":3,"skills":{"ce-code-review":{"source":"EveryInc/compound-engineering-plugin"},"ce-doc-review":{"source":"EveryInc/compound-engineering-plugin"},"ce-plan":{"source":"EveryInc/compound-engineering-plugin"},"ce-simplify-code":{"source":"EveryInc/compound-engineering-plugin"},"ce-work":{"source":"EveryInc/compound-engineering-plugin"},"desired":{"source":"owner/repo"},"stale":{"source":"owner/repo"},"orphan":{"source":"gone/repo"}}}' > "$lock"
  for skill in ce-code-review ce-doc-review ce-plan ce-simplify-code ce-work desired; do
    mkdir -p "$canonical/$skill"
    printf '%s\n' skill > "$canonical/$skill/SKILL.md"
  done
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$manifest" SKILLS_CANONICAL_ROOT="$canonical" bash "$SKILLS_WRAPPER" sync
  assert_success
  assert_output --partial 'Installing skills from EveryInc/compound-engineering-plugin: *'
  assert_output --partial 'Installing skills from owner/repo: desired'
  assert_output --partial 'drift: skills remove owner/repo stale'
  assert_output --partial 'drift: skills remove gone/repo orphan'
  refute_output --partial 'ce-code-review'
}

# ===========================================
# agent-skills onchange hook
# ===========================================

AGENT_SKILLS_SYNC_TMPL="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_9-sync-agent-skills.sh.tmpl"

render_agent_skills_sync() {
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" --source "$SOURCE_ROOT" execute-template < "$AGENT_SKILLS_SYNC_TMPL"
}

function test_scripts_280_agent_skills_sync_hook_renders_valid_bash_and_skips_disposable_homes() {
  _bats_test_init 280 'agent-skills sync hook is valid Bash and skips network work in disposable homes'
  skip_if_no_chezmoi
  BATS_TEST_TMPFILE="$BATS_TEST_TMPDIR/sync-agent-skills.sh"
  render_agent_skills_sync > "$BATS_TEST_TMPFILE"
  run bash -n "$BATS_TEST_TMPFILE"
  assert_success

  local stub="$BATS_TEST_TMPDIR/disposable-bin"
  mkdir -p "$stub"
  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
: > "$TMPDIR/npx-ran"
exit 99
SH
  chmod +x "$stub/npx"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    MMS_DISPOSABLE_HOME=1 SKILLS_MANIFEST=ambient-manifest bash "$BATS_TEST_TMPFILE"
  assert_success
  assert_output --partial 'skipping agent-skills synchronization in disposable home'
  assert_file_not_exists "$BATS_TEST_TMPDIR/tmp/npx-ran"
}

function test_scripts_281_agent_skills_sync_hook_reports_node_and_npx_prerequisites() {
  _bats_test_init 281 'agent-skills sync hook clearly rejects missing or incompatible Node.js and npx'
  skip_if_no_chezmoi
  BATS_TEST_TMPFILE="$BATS_TEST_TMPDIR/sync-agent-skills.sh"
  render_agent_skills_sync > "$BATS_TEST_TMPFILE"
  local stub="$BATS_TEST_TMPDIR/prerequisite-bin"
  mkdir -p "$stub"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" MMS_DISPOSABLE_HOME=0 bash "$BATS_TEST_TMPFILE"
  assert_failure
  assert_output --partial 'Node.js is not available'

  cat > "$stub/node" <<'SH'
#!/usr/bin/env bash
[ "$1" != --version ] || exit 1
SH
  chmod +x "$stub/node"
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" MMS_DISPOSABLE_HOME=0 bash "$BATS_TEST_TMPFILE"
  assert_failure
  assert_output --partial 'Node.js is unavailable or incompatible'

  cat > "$stub/node" <<'SH'
#!/usr/bin/env bash
printf '%s\n' v22.0.0
SH
  chmod +x "$stub/node"
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" MMS_DISPOSABLE_HOME=0 bash "$BATS_TEST_TMPFILE"
  assert_failure
  assert_output --partial 'npx is not available'

  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
[ "$1" != --version ] || exit 1
SH
  chmod +x "$stub/npx"
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" MMS_DISPOSABLE_HOME=0 bash "$BATS_TEST_TMPFILE"
  assert_failure
  assert_output --partial 'npx is unavailable or incompatible'
}

function test_scripts_282_agent_skills_sync_hook_unsets_manifest_and_preserves_wrapper_failure() {
  _bats_test_init 282 'agent-skills sync hook invokes the deployed wrapper with no ambient manifest and preserves its status'
  skip_if_no_chezmoi
  BATS_TEST_TMPFILE="$BATS_TEST_TMPDIR/sync-agent-skills.sh"
  render_agent_skills_sync > "$BATS_TEST_TMPFILE"
  local home="$BATS_TEST_TMPDIR/home" stub="$BATS_TEST_TMPDIR/healthy-bin"
  mkdir -p "$home/.local/bin" "$stub"
  cat > "$stub/node" <<'SH'
#!/usr/bin/env bash
printf '%s\n' v22.0.0
SH
  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 10.0.0
SH
  cat > "$home/.local/bin/skills" <<'SH'
#!/usr/bin/env bash
printf 'manifest=%s\n' "${SKILLS_MANIFEST-unset}" > "$HOME/wrapper.log"
exit 23
SH
  chmod +x "$stub/node" "$stub/npx" "$home/.local/bin/skills"

  run env PATH="$stub:/usr/bin:/bin" HOME="$home" MMS_DISPOSABLE_HOME=0 SKILLS_MANIFEST=ambient-manifest bash "$BATS_TEST_TMPFILE"
  assert_failure 23
  run cat "$home/wrapper.log"
  assert_success
  assert_output 'manifest=unset'
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function tear_down() {
  if [ -n "${CHILD_STUB:-}" ] && [ -e "$CHILD_STUB/failure-publish.ready" ]; then
    : > "$CHILD_STUB/failure-publish.release"
  fi
  _bats_run_teardown
}
