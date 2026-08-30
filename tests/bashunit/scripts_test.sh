#!/usr/bin/env bash
# scripts post-apply suite — bashunit source. Vocabulary (run, assert_*,
# skip, BATS_* contract) comes from tests/bashunit/test-dsl.bash.
# Migrated from scripts.bats; parity evidence: docs/benchmarks/bashunit-full-suite-experiment.md.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/common'
load 'helpers/herdr_task_sync'

setup() {
  unset HERDR_CHILD_NAME
  unset HERDR_CHILD_PARENT_PANE
  unset HERDR_CHILD_STATE_DIR
  unset HERDR_WORKSPACE_ID
  unset HERDR_CHILD_MAX_DELIVERY_RETRIES
  unset HERDR_CHILD_TEST_RETRY_LOG
  unset HERDR_CHILD_TEST_FAILURE_PUBLISH_BARRIER
  unset HERDR_CHILD_TEST_CALLBACK_RECEIPT_BARRIER
}

teardown() {
  hts_teardown
  if [[ -n "${CHILD_STUB:-}" ]]; then
    [[ ! -e "$CHILD_STUB/release-watcher" ]] || true
    : > "$CHILD_STUB/release-watcher" 2>/dev/null || true
    if [[ -s "$CHILD_STUB/watcher.pid" ]]; then
      local watcher_pid
      watcher_pid="$(cat "$CHILD_STUB/watcher.pid" 2>/dev/null || true)"
      if [[ -n "$watcher_pid" ]]; then
        kill -TERM "$watcher_pid" 2>/dev/null || true
        local attempt=0
        while kill -0 "$watcher_pid" 2>/dev/null && [[ "$attempt" -lt 100 ]]; do
          attempt=$((attempt + 1))
          sleep 0.01
        done
      fi
    fi
  fi
  [[ -n "${BATS_TEST_TMPFILE:-}" ]] && rm -f "$BATS_TEST_TMPFILE" || true
  [[ -n "${CHILD_STUB:-}" ]] && rm -rf "$CHILD_STUB" || true
}

# ===========================================
# python3 -- the declared interpreter
# ===========================================

# First, so a missing or too-old interpreter states its own cause instead of
# leaving the bare `python3` call sites below to fail without naming it.
function test_scripts_001_python3_is_present_and_at_least_3_9_the_floor_re() {
  _bats_test_init 1 'python3 is present and at least 3.9, the floor README.md declares'
  assert_python3_available
}

# ===========================================
# Repository linting
# ===========================================

function test_scripts_002_lint_target_propagates_shellcheck_failures() {
  _bats_test_init 2 'lint target propagates shellcheck failures'
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

function test_scripts_003_ci_minimal_linux_render_skips_homebrew_but_keeps() {
  _bats_test_init 3 'CI-minimal Linux render skips Homebrew but keeps the remaining setup'
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

function test_scripts_004_full_linux_render_keeps_homebrew_package_install() {
  _bats_test_init 4 'full Linux render keeps Homebrew package installation'
  skip_if_no_chezmoi
  local cfg="$BATS_TEST_TMPDIR/full-linux.yaml"
  MMS_CI_MINIMAL="" write_test_config "$cfg"
  sed -i.bak 's/^  is_linux: .*/  is_linux: true/' "$cfg"

  run render_install_packages "$cfg"
  assert_success
  assert_output --partial 'Installing Homebrew'
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
  assert_output --partial 'Installing Homebrew'
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

function test_scripts_009_ask_in_herdr_script_requires_arguments() {
  _bats_test_init 9 'ask-in-herdr script requires arguments'
  run bash "$ASK_HERDR_DIR/ask.sh"
  assert_failure 2
  assert_output --partial "Usage:"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=refused"
}

function test_scripts_010_ask_sh_rejects_unknown_agents_and_the_removed_he() {
  _bats_test_init 10 'ask.sh rejects unknown agents and the removed headless flag'
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

function test_scripts_011_ask_sh_refuses_outside_herdr_and_when_herdr_chil() {
  _bats_test_init 11 'ask.sh refuses outside herdr and when herdr-child is absent'
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

function test_scripts_012_ask_sh_starts_a_read_only_live_child_and_returns() {
  _bats_test_init 12 'ask.sh starts a read-only live child and returns its answer'
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

function test_scripts_013_ask_sh_keeps_a_settled_answer_when_the_parent_re() {
  _bats_test_init 13 'ask.sh keeps a settled answer when the parent reminder cannot be queued'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENT_STATUS=done STUB_PARENT_PROMPT_FAIL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$ASK_HERDR_DIR/ask.sh" claude question
  assert_success
  assert_output --partial "ANSWER from child"
  assert_output --partial "warning: could not queue the cleanup reminder"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=answered"
  assert_file_not_exists "$CHILD_STUB/parent-prompt"
}

function test_scripts_014_ask_sh_forwards_posture_and_every_native_caller() {
  _bats_test_init 14 'ask.sh forwards posture and every native caller option'
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

function test_scripts_015_ask_sh_retries_a_colliding_derived_name_with_a_v() {
  _bats_test_init 15 'ask.sh retries a colliding derived name with a valid suffix'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_NAME_COLLISION=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" claude question
  assert_success
  run grep -E -- '--name consult-claude-[0-9]+-2' "$CHILD_STUB/child.log"
  assert_success
}

function test_scripts_016_ask_sh_reports_blocked_children_after_printing_t() {
  _bats_test_init 16 'ask.sh reports blocked children after printing their answer'
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

function test_scripts_017_ask_sh_reports_undelivered_when_child_output_can() {
  _bats_test_init 17 'ask.sh reports undelivered when child output cannot be read'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_READ_FAIL=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" claude question
  assert_failure 1
  assert_output --partial "read failed"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=undelivered"
}

function test_scripts_018_ask_sh_reports_a_still_working_child_with_exit_1() {
  _bats_test_init 18 'ask.sh reports a still-working child with exit 124'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_CHILD_STATUS=124 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" claude question
  assert_failure 124
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=working"
  assert_file_not_exists "$CHILD_STUB/parent-prompt"
}

function test_scripts_019_ask_sh_classifies_successful_waits_with_working() {
  _bats_test_init 19 'ask.sh classifies successful waits with working, unknown, and fallback statuses'
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

function test_scripts_020_ask_sh_maps_child_start_failures_to_refused_or_u() {
  _bats_test_init 20 'ask.sh maps child start failures to refused or undelivered'
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
    elif [ "${STUB_START_CONTEXT:-0}" = 1 ] && [ -f "$CHILD_STUB/started-name" ]; then
      child_name="$(cat "$CHILD_STUB/started-name")"
      if [ "${STUB_CHILD_SESSION_MISSING:-0}" = 1 ]; then
        printf '{"result":{"agents":[{"name":"parent","pane_id":"wT:p0","terminal_id":"term-parent","agent_session":{"value":"parent-session"}},{"name":"%s","pane_id":"wT:p9","terminal_id":"term-child"}]}}\n' "$child_name"
      elif [ "${STUB_PARENT_SESSION_MISSING:-0}" = 1 ]; then
        printf '{"result":{"agents":[{"name":"parent","pane_id":"wT:p0","terminal_id":"term-parent"},{"name":"%s","pane_id":"wT:p9","terminal_id":"term-child","agent_session":{"value":"child-session"}}]}}\n' "$child_name"
      else
        printf '{"result":{"agents":[{"name":"parent","pane_id":"wT:p0","terminal_id":"term-parent","agent_session":{"value":"parent-session"}},{"name":"%s","pane_id":"wT:p9","terminal_id":"term-child","agent_session":{"value":"child-session"}}]}}\n' "$child_name"
      fi
    elif [ "${STUB_START_CONTEXT:-0}" = 1 ] && [ "${STUB_PARENT_SESSION_MISSING:-0}" = 1 ]; then
      printf '{"result":{"agents":[{"name":"parent","pane_id":"wT:p0","terminal_id":"term-parent"}]}}\n'
    elif [ "${STUB_START_CONTEXT:-0}" = 1 ]; then
      printf '{"result":{"agents":[{"name":"parent","pane_id":"wT:p0","terminal_id":"term-parent","agent_session":{"value":"parent-session"}}]}}\n'
    else
      printf '{"result":{"agents":[]}}\n'
    fi ;;
  "pane split")
    [ "${STUB_SPLIT_FAIL:-0}" = 1 ] && exit 1
    : > "$CHILD_STUB/split-seen"
    printf '{"result":{"pane":{"pane_id":"wT:p9"}}}\n' ;;
  "tab create")
    [ "${STUB_TAB_CREATE_FAIL:-0}" = 1 ] && exit 1
    : > "$CHILD_STUB/split-seen"
    if [ "${STUB_TAB_CREATE_MALFORMED:-0}" = 1 ]; then
      printf '{"result":{"root_pane":{"pane_id":"","terminal_id":""},"tab":{"tab_id":"wT:tA"}}}\n'
    elif [ "${STUB_TAB_CREATE_NO_TERMINAL:-0}" = 1 ]; then
      printf '{"result":{"root_pane":{"pane_id":"wT:p9","terminal_id":""},"tab":{"tab_id":"wT:tA"}}}\n'
    else
      printf '{"result":{"root_pane":{"pane_id":"wT:p9","terminal_id":"term_wTp9"},"tab":{"tab_id":"wT:tA"}}}\n'
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
      while [ ! -e "$CHILD_STUB/release-prompt" ]; do sleep 0.01; done
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
        while [ ! -e "$CHILD_STUB/release-liveness" ]; do sleep 0.01; done
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
      printf '{"result":{"pane":{"state_labels":{"blocked":"waiting for parent"}}}}\n'
    elif [ -n "${STUB_PANE_TAB_ID:-}" ]; then
      printf '{"result":{"pane":{"tab_id":"%s","tokens":{"child-tab":"%s"}}}}\n' \
        "$STUB_PANE_TAB_ID" "${STUB_PANE_CHILD_TAB_TOKEN:-$STUB_PANE_TAB_ID}"
    elif [ -f "$CHILD_STUB/generation" ]; then
      generation="$(cat "$CHILD_STUB/generation")"
      printf '{"result":{"pane":{"pane_id":"wT:p9","terminal_id":"term-child","agent_session":{"value":"child-session"},"tokens":{"supervision_generation":"%s"}}}}\n' "$generation"
    else
      printf '{"result":{"pane":{}}}\n'
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
  printf '{"name":"%s","pane_id":"%s","terminal_id":"%s","agent_session":{"value":"%s"},"agent_status":"%s","state_change_seq":%s,"focused":false}' \
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
    printf '{"result":{"pane":{"pane_id":"wT:p9"}}}\n'
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
      while [ ! -f "$CHILD_STUB/wait-release" ]; do sleep 0.01; done
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
        while [ ! -f "$CHILD_STUB/release-parent-prompt" ]; do sleep 0.01; done
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
    for arg in "$@"; do
      if [ "$clear_next" -eq 1 ]; then
        if [ "$arg" = supervision_generation ]; then
          rm -f "$CHILD_STUB/generation"
          : > "$CHILD_STUB/generation-invalidated"
        fi
        clear_next=0
        continue
      fi
      [ "$arg" != --clear-token ] || { clear_next=1; continue; }
      case "$arg" in
        supervision_generation=*) printf '%s\n' "${arg#*=}" > "$CHILD_STUB/generation" ;;
        child-tab=*) printf '%s\n' "${arg#*=}" > "$CHILD_STUB/child-tab" ;;
        --clear-state-labels) clear_labels=1 ;;
        blocked=waiting\ for\ parent) waiting_label=1 ;;
      esac
    done
    [ "$clear_labels" -eq 0 ] || rm -f "$CHILD_STUB/waiting-label"
    [ "$waiting_label" -eq 0 ] || : > "$CHILD_STUB/waiting-label"
    printf '{"result":{"type":"pane_metadata_reported"}}\n'
    ;;
  "pane get")
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
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_POLL_INTERVAL=0.01 HERDR_CHILD_TEST_SKIP_RETRY_SLEEP=1 \
    bash "$HERDR_CHILD" start --kind claude --name child-life --detach \
    --prompt "test task" "$@"
}

child_wait_for_log() {
  local pattern="$1" attempt=0
  while [ "$attempt" -lt 500 ]; do
    grep -q -- "$pattern" "$CHILD_STUB/calls.log" 2>/dev/null && return 0
    attempt=$((attempt + 1))
    sleep 0.01
  done
  printf 'pattern not observed: %s\n' "$pattern" >&2
  cat "$CHILD_STUB/calls.log" >&2
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
    bash "$HERDR_CHILD" start --kind claude --name child-a --wait --prompt task
  assert_failure
  [ ! -f "$CHILD_STUB/calls.log" ]
}

function test_scripts_022_herdr_child_refuses_pi_read_only_before_splittin() {
  _bats_test_init 22 'herdr-child refuses pi read-only before splitting a pane'
  child_stub_herdr
  run child_start --kind pi --name child-pi --posture ro --wait
  assert_failure 2
  assert_output --partial "return channel requires bash"
  [ ! -f "$CHILD_STUB/calls.log" ]
}

function test_scripts_023_herdr_child_start_requires_exactly_one_explicit() {
  _bats_test_init 23 'herdr-child start requires exactly one explicit mode before Herdr mutation'
  child_stub_herdr

  run child_start --kind claude --name child-none
  assert_failure 2
  assert_output --partial "exactly one of --wait or --detach"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --name child-both --wait --detach
  assert_failure 2
  assert_output --partial "exactly one of --wait or --detach"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --name child-repeat --wait --wait
  assert_failure 2
  assert_output --partial "mode flag may be specified only once"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --name child-repeat --detach --detach
  assert_failure 2
  assert_output --partial "mode flag may be specified only once"
  assert_file_not_exists "$CHILD_STUB/calls.log"
}

function test_scripts_024_herdr_child_validates_tab_placement_before_herdr() {
  _bats_test_init 24 'herdr-child validates tab placement before Herdr mutation'
  child_stub_herdr

  HERDR_WORKSPACE_ID=w1 run child_start --kind claude --name child-a --tab --direction right --wait
  assert_failure 2
  assert_output --partial "--tab cannot be combined with --direction"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --name child-a --label mylabel --wait
  assert_failure 2
  assert_output --partial "--label is only valid with --tab"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --name child-a --tab --wait
  assert_failure 2
  assert_output --partial "--tab requires HERDR_WORKSPACE_ID"
  assert_file_not_exists "$CHILD_STUB/calls.log"
}

function test_scripts_025_herdr_child_validates_launch_and_supervision_tim() {
  _bats_test_init 25 'herdr-child validates launch and supervision timeouts before Herdr mutation'
  child_stub_herdr

  run child_start --kind claude --name child-a --wait --timeout 0
  assert_failure 2
  assert_output --partial "--timeout must be a positive integer"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --name child-a --wait --supervision-timeout 10
  assert_failure 2
  assert_output --partial "--supervision-timeout requires --detach"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --name child-a --wait --supervision-timeout 3600000
  assert_failure 2
  assert_output --partial "--supervision-timeout requires --detach"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  local value
  for value in 0 86400001 malformed; do
    run child_start --kind claude --name child-a --detach --supervision-timeout "$value"
    assert_failure 2
    assert_output --partial "--supervision-timeout must be between 1 and 86400000 milliseconds"
    assert_file_not_exists "$CHILD_STUB/calls.log"
  done

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" start --kind claude --name child-a --detach \
    --prompt "test task" --supervision-timeout
  assert_failure 2
  assert_output --partial "--supervision-timeout needs a value"
  assert_file_not_exists "$CHILD_STUB/calls.log"
}

function test_scripts_026_herdr_child_attached_mode_starts_no_watcher() {
  _bats_test_init 26 'herdr-child attached mode starts no watcher'
  child_stub_herdr
  run child_start --kind claude --name child-attached --wait
  assert_success
  assert_output '{"agent":"child-attached","pane":"wT:p9"}'
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
  STUB_PARENT_SESSION_MISSING=1 run child_start --kind claude --name child-a --detach
  assert_failure
  assert_output --partial "parent agent_session is unavailable"
  assert_file_contains "$CHILD_STUB/calls.log" '^agent list'
  run grep -Eq '^(pane split|agent start|agent prompt|pane report-metadata)' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_028_herdr_child_detached_mode_closes_only_its_new_pa() {
  _bats_test_init 28 'herdr-child detached mode closes only its new pane without a child session'
  child_stub_herdr
  STUB_CHILD_SESSION_MISSING=1 run child_start --kind claude --name child-a --detach
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
  run child_start --kind claude --name child-detached --detach --supervision-timeout 60000
  assert_success
  assert_output --partial '"agent":"child-detached"'
  assert_output --partial '"supervision":{"status":"armed"'
  assert_output --partial '"timeout_ms":60000'
  assert_file_exists "$CHILD_STUB/watcher.pid"

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
  HERDR_CHILD_TEST_ARM_FAIL=1 run child_start --kind claude --name child-a --detach
  assert_failure
  assert_output --partial '"agent":"child-a","pane":"wT:p9"'
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
import signal
import subprocess
import time

stub = Path(os.environ["CHILD_STUB"])
proc = subprocess.Popen(
    ["bash", os.environ["CHILD_SCRIPT"], "start", "--kind", "claude", "--name",
     "child-pre-signal", "--detach", "--prompt", "test task"],
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
        ["bash", os.environ["CHILD_SCRIPT"], "start", "--kind", "claude", "--name",
         "child-" + os.environ["CHILD_SIGNAL_NAME"], "--detach", "--prompt", "test task"],
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
    ["bash", os.environ["CHILD_SCRIPT"], "start", "--kind", "claude", "--name",
     "child-arm-race", "--detach", "--prompt", "test task"],
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
    ["bash", os.environ["CHILD_SCRIPT"], "start", "--kind", "claude", "--name",
     "child-armed-signal", "--detach", "--prompt", "test task"],
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
  export HERDR_CHILD_TEST_FAILURE_PUBLISH_BARRIER="$CHILD_STUB/failure-publish"
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  local old_generation old_run watcher_pid attempt=0
  old_generation="$(cat "$CHILD_STUB/generation")"
  old_run="$CHILD_STUB/state/runs/$old_generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"

  : > "$CHILD_STUB/malformed-state"
  child_wait_for_file "$CHILD_STUB/failure-publish.ready"
  printf 'new-generation\n' > "$CHILD_STUB/generation"
  : > "$CHILD_STUB/failure-publish.release"
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  assert_file_not_exists "$old_run"
  run cat "$CHILD_STUB/generation"
  assert_success
  assert_output new-generation
  run grep -q 'supervision_failure_reason=' "$CHILD_STUB/calls.log"
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
  assert_file_not_exists "$old_run"
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
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/require-reap-invalidation"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reap --pane wT:p9 child-life
  assert_success
  assert_file_exists "$CHILD_STUB/reap-invalidation-observed"
  assert_file_not_exists "$CHILD_STUB/close-before-invalidation"
  assert_file_exists "$CHILD_STUB/pane-closed"
  run grep -q 'event=child-gone' "$CHILD_STUB/calls.log"
  assert_failure

  teardown
  setup
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  : > "$CHILD_STUB/child-gone"
  child_wait_for_log 'event=child-gone'
  run grep -c 'event=child-gone' "$CHILD_STUB/calls.log"
  assert_success
  assert_output 1
}

function test_scripts_046_herdr_child_failed_reap_restores_supervision_for() {
  _bats_test_init 46 'herdr-child failed reap restores supervision for the kept child'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  local generation run_dir watcher_pid attempt=0
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/close-fail"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reap --pane wT:p9 child-life
  assert_success
  assert_output --partial 'supervision recovery requested'
  assert_file_not_exists "$CHILD_STUB/pane-closed"
  while [ -f "$run_dir/invalidated.state" ] && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  kill -0 "$watcher_pid"

  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'event=settled-11'
  run grep -c 'event=settled-11' "$CHILD_STUB/successful-prompts.log"
  assert_success
  assert_output 1
  run grep -q 'event=child-gone' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_047_herdr_child_detached_ask_follows_parent_identity() {
  _bats_test_init 47 'herdr-child detached ask follows parent identity and suppresses its ordinary blocked wake'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  local generation watcher_pid attempt=0
  generation="$(cat "$CHILD_STUB/generation")"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  printf 'wT:p7\n' > "$CHILD_STUB/parent-pane"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_NAME=child-life \
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
  local agents='{"result":{"agents":[{"name":"parent","pane_id":"wT:p7","terminal_id":"term-parent","agent_session":{"value":"parent-session"}}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 \
    HERDR_PANE_ID=wT:p9 HERDR_CHILD_NAME=child-a HERDR_CHILD_PARENT_PANE=wT:p0 \
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
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_NAME=child-life \
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
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_NAME=child-life \
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
    bash "$HERDR_CHILD" reap --pane wT:p9 child-life
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
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_NAME=child-life \
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
    bash "$HERDR_CHILD" reply --to child-life --pane wT:p9 "Use path A"
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
    bash "$HERDR_CHILD" reply --to child-life --pane wT:p9 "Use path A"
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
  printf 'child-life' > "$CHILD_STUB/started-name"
  : > "$CHILD_STUB/advance-on-prompt"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" prompt --to child-life --pane wT:p9 "next task"
  assert_failure 2
  assert_output --partial 'exactly one of --wait or --detach'

  : > "$CHILD_STUB/calls.log"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" prompt --to child-life --pane wT:p9 --wait --timeout 1000 "next task"
  assert_success
  assert_output --partial 'Prompt completed for child-life in wT:p9.'
  run grep -q 'state-label supervised=' "$CHILD_STUB/calls.log"
  assert_failure
  assert_file_not_exists "$CHILD_STUB/watcher.pid"
}

function test_scripts_054_herdr_child_attached_prompt_wait_rejects_the_fir() {
  _bats_test_init 54 'herdr-child attached prompt wait rejects the first one-step settlement after a working baseline'
  child_lifecycle_stub_herdr
  printf 'child-life' > "$CHILD_STUB/started-name"
  printf 'working 10\n' > "$CHILD_STUB/baseline-state"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"

  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_POLL_INTERVAL=0.01 \
    bash "$HERDR_CHILD" prompt --to child-life --pane wT:p9 --wait --timeout 5000 \
    "sequence-sensitive task" >"$CHILD_STUB/prompt.out" 2>"$CHILD_STUB/prompt.err" &
  local prompt_pid=$!
  child_wait_for_get_count 3
  kill -0 "$prompt_pid"

  printf 'working 12\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/fresh-working-observed"
  printf 'idle 13\n' > "$CHILD_STUB/child-state"
  wait "$prompt_pid"
  assert_file_contains "$CHILD_STUB/prompt.out" 'Prompt completed for child-life in wT:p9.'
}

function test_scripts_055_herdr_child_managed_detached_prompt_advances_gen() {
  _bats_test_init 55 'herdr-child managed detached prompt advances generation and preserves the child on rearm failure'
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
    bash "$HERDR_CHILD" prompt --to child-life --pane wT:p9 --detach \
    --supervision-timeout 5000 "ordinary follow-up"
  assert_success
  new_generation="$(cat "$CHILD_STUB/generation")"
  [ "$new_generation" != "$old_generation" ]
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
    bash "$HERDR_CHILD" prompt --to child-life --pane wT:p9 --detach \
    --supervision-timeout 5000 "ordinary follow-up"
  assert_failure
  assert_output --partial '"supervision":{"status":"failed","reason":"watcher-arm-failed"'
  [ ! -d "$old_run" ] || [ -f "$old_run/invalidated.state" ]
  run cat "$CHILD_STUB/generation"
  assert_success
  refute_output "$old_generation"
  assert_file_not_exists "$CHILD_STUB/pane-closed"
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
    bash "$HERDR_CHILD" prompt --to child-life --pane wT:p9 --detach "next task"
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
    bash "$HERDR_CHILD" prompt --to child-life --pane wT:p9 --detach "next task"
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
    bash "$HERDR_CHILD" prompt --to child-life --pane wT:p9 --detach "next task"
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
  printf 'child-life' > "$CHILD_STUB/started-name"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_POLL_INTERVAL=0.01 \
    bash "$HERDR_CHILD" prompt --to child-life --pane wT:p9 --detach \
    --supervision-timeout 5000 "promote this child"
  assert_success
  local generation
  generation="$(cat "$CHILD_STUB/generation")"
  printf 'wT:p7\n' > "$CHILD_STUB/parent-pane"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_NAME=child-life \
    HERDR_CHILD_PARENT_PANE=wT:p0 HERDR_CHILD_LAUNCH_MODE=wait \
    HERDR_CHILD_PARENT_TERMINAL=term-parent HERDR_CHILD_PARENT_SESSION=parent-session \
    bash "$HERDR_CHILD" ask "Which promoted path?"
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent prompt wT:p7.*child-ask\ v2'
  assert_file_contains "$CHILD_STUB/successful-prompts.log" "generation=$generation"
  assert_file_contains "$CHILD_STUB/successful-prompts.log" 'child-ask v2'
}

function test_scripts_058_herdr_child_source_contracts_document_attached_a() {
  _bats_test_init 58 'herdr child source contracts document attached and detached lifecycle boundaries'
  local contract="$SOURCE_ROOT/private_dot_claude/shared/child-agent-contract.md"
  local skill="$SOURCE_ROOT/private_dot_claude/skills/herdr/SKILL.md"
  local consult="$SOURCE_ROOT/private_dot_claude/skills/ask-in-herdr/SKILL.md"

  assert_file_contains "$contract" 'herdr-child start.*--wait'
  assert_file_contains "$contract" 'herdr-child start.*--detach'
  assert_file_contains "$contract" 'generation.*event'
  assert_file_contains "$contract" 'herdr-child prompt.*--wait'
  assert_file_contains "$contract" 'herdr-child prompt.*--detach'
  assert_file_contains "$contract" 'not.*task-success verdict'
  assert_file_contains "$contract" 'start.*prompt.*reply.*nonzero.*recovery JSON'
  assert_file_contains "$contract" 'Do not retry.*start.*same name'
  assert_file_contains "$contract" 'herdr agent get.*pane-id'
  assert_file_contains "$contract" 'managed.*herdr-child prompt.*--detach.*reap'
  assert_file_contains "$skill" 'cooperative exclusive file scope'
  assert_file_contains "$skill" 'nonzero recovery JSON.*preserving the child'
  assert_file_contains "$skill" 'Do not retry.*start.*same name'
  assert_file_contains "$skill" 'herdr agent get'
  assert_file_contains "$skill" 'rearm.*managed.*prompt.*--detach.*reap'
  assert_file_contains "$consult" 'attached.*--wait'
}

function test_scripts_059_herdr_child_rejects_invalid_and_live_names_befor() {
  _bats_test_init 59 'herdr-child rejects invalid and live names before splitting'
  child_stub_herdr
  run child_start --kind claude --name Invalid --wait
  assert_failure 2
  [ ! -f "$CHILD_STUB/calls.log" ]

  STUB_AGENTS_JSON='{"result":{"agents":[{"name":"child-a","pane_id":"wT:p8"}]}}' \
    run child_start --kind claude --name child-a --wait
  assert_failure 2
  assert_output --partial "already live"
  run grep -q '^pane split' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_060_herdr_child_maps_claude_postures_and_skill_direc() {
  _bats_test_init 60 'herdr-child maps claude postures and skill directories'
  child_stub_herdr
  run child_start --kind claude --name child-ro --skills A --skills B --wait
  assert_success
  assert_output '{"agent":"child-ro","pane":"wT:p9"}'
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--add-dir A --add-dir B.*--disallowed-tools Edit Write NotebookEdit AskUserQuestion'

  : > "$CHILD_STUB/calls.log"
  run child_start --kind claude --name child-rw --posture rw --wait
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--disallowed-tools AskUserQuestion'
  run grep -q 'disallowed-tools Edit' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_061_herdr_child_maps_opencode_permissions_model_and() {
  _bats_test_init 61 'herdr-child maps opencode permissions, model, and configured agent'
  child_stub_herdr
  run child_start --kind opencode --name child-open --agent reviewer --wait
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'OPENCODE_PERMISSION=.*question.*deny.*edit.*deny'
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--model openai/gpt-5.5 --agent reviewer'

  : > "$CHILD_STUB/calls.log"
  run child_start --kind opencode --name child-open-rw --posture rw --wait
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'OPENCODE_PERMISSION=.*question.*deny'
  run grep -q 'OPENCODE_PERMISSION=.*edit' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_062_herdr_child_maps_pi_model_effort_skills_and_ques() {
  _bats_test_init 62 'herdr-child maps pi model, effort, skills, and question exclusion'
  child_stub_herdr
  run child_start --kind pi --name child-pi --posture rw --skills A --skills B --wait
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--exclude-tools ask_user --model openai-codex/gpt-5.5 --thinking medium --skill A --skill B'

  : > "$CHILD_STUB/calls.log"
  run child_start --kind pi --name child-pi-high --posture rw --model custom/model --effort high --wait
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--model custom/model --thinking high'
}

function test_scripts_063_herdr_child_rejects_native_options_that_the_sele() {
  _bats_test_init 63 'herdr-child rejects native options that the selected kind cannot map'
  child_stub_herdr
  run child_start --kind claude --name child-a --effort high --wait
  assert_failure 2
  assert_output --partial "--effort is not supported for claude"
  run child_start --kind pi --name child-b --posture rw --agent reviewer --wait
  assert_failure 2
  assert_output --partial "--agent is not supported for pi"
  run child_start --kind opencode --name child-c --skills A --wait
  assert_failure 2
  assert_output --partial "--skills is not supported for opencode"
  [ ! -f "$CHILD_STUB/calls.log" ]
}

function test_scripts_064_herdr_child_splits_starts_and_prompts_in_order_w() {
  _bats_test_init 64 'herdr-child splits, starts, and prompts in order with both coordinates'
  child_stub_herdr
  STUB_REQUIRE_SPLIT=1 run child_start --kind claude --name child-a --wait --timeout 5000
  assert_success
  local call1 call2 call3 call4
  call1="$(sed -n '1p' "$CHILD_STUB/calls.log")"
  call2="$(sed -n '2p' "$CHILD_STUB/calls.log")"
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  call4="$(sed -n '4p' "$CHILD_STUB/calls.log")"
  [[ "$call1" == agent\ list* ]] || fail "unexpected first herdr-child call: $call1"
  [[ "$call2" == pane\ split*HERDR_CHILD_NAME=child-a*HERDR_CHILD_PARENT_PANE=wT:p0* ]] || fail "unexpected second herdr-child call: $call2"
  [[ "$call3" == agent\ start* ]] || fail "unexpected third herdr-child call: $call3"
  [[ "$call4" == agent\ prompt*child-a*wT:p9*wT:p0*--wait*--timeout\ 5000* ]] || fail "unexpected fourth herdr-child call: $call4"
}

function test_scripts_065_herdr_child_tab_mode_records_ownership_before_st() {
  _bats_test_init 65 'herdr-child tab mode records ownership before starting an attached child'
  child_stub_herdr
  STUB_REQUIRE_SPLIT=1 HERDR_WORKSPACE_ID=w1 run child_start \
    --kind claude --name child-a --tab --label mylabel --wait
  assert_success
  assert_output '{"agent":"child-a","pane":"wT:p9","tab":"wT:tA"}'
  local call1 call2 call3 call4 call5
  call1="$(sed -n '1p' "$CHILD_STUB/calls.log")"
  call2="$(sed -n '2p' "$CHILD_STUB/calls.log")"
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  call4="$(sed -n '4p' "$CHILD_STUB/calls.log")"
  call5="$(sed -n '5p' "$CHILD_STUB/calls.log")"
  [[ "$call1" == agent\ list* ]] || fail "unexpected first tab-mode call: $call1"
  [[ "$call2" == tab\ create*--workspace\ w1*HERDR_CHILD_NAME=child-a*HERDR_CHILD_PARENT_PANE=wT:p0*--label\ mylabel* ]] || fail "unexpected second tab-mode call: $call2"
  [[ "$call3" == pane\ report-metadata\ wT:p9\ --source\ child-agent-tab*child-tab=wT:tA* ]] || fail "unexpected third tab-mode call: $call3"
  [[ "$call4" == agent\ start* ]] || fail "unexpected fourth tab-mode call: $call4"
  [[ "$call5" == agent\ prompt*--wait* ]] || fail "unexpected fifth tab-mode call: $call5"
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
    ["bash", os.environ["CHILD_SCRIPT"], "start", "--kind", "claude", "--name",
     "tab-signal", "--tab", "--wait", "--prompt", "test task"],
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
    --kind claude --name child-a --tab --wait
  assert_failure 1
  assert_output --partial "tab wT:tA was preserved"
  run grep -Eq '^(pane report-metadata|agent start|pane close)' "$CHILD_STUB/calls.log"
  assert_failure

  teardown
  setup
  child_stub_herdr
  STUB_REPORT_FAIL=1 HERDR_WORKSPACE_ID=w1 run child_start \
    --kind claude --name child-a --tab --wait
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
    --kind claude --name child-a --tab --wait
  assert_failure 124
  assert_output --partial '{"agent":"child-a","pane":"wT:p9","tab":"wT:tA"}'
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure

  teardown
  setup
  child_stub_herdr
  STUB_START_MODE=busy HERDR_WORKSPACE_ID=w1 run child_start \
    --kind claude --name child-a --tab --wait
  assert_failure
  assert_output --partial "three agent start attempts (tab wT:tA)"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

function test_scripts_070_herdr_child_caps_startup_timeout_while_preservin() {
  _bats_test_init 70 'herdr-child caps startup timeout while preserving a long prompt wait'
  child_stub_herdr
  run child_start --kind claude --name child-a --wait --timeout 1800000
  assert_success
  local start_call prompt_call
  start_call="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  prompt_call="$(sed -n '4p' "$CHILD_STUB/calls.log")"
  [[ "$start_call" == *--timeout\ 300000* ]] || fail "startup timeout was not capped: $start_call"
  [[ "$prompt_call" == *--timeout\ 1800000* ]] || fail "prompt timeout was not preserved: $prompt_call"
}

function test_scripts_071_herdr_child_retries_only_the_pane_readiness_star() {
  _bats_test_init 71 'herdr-child retries only the pane-readiness start failure'
  child_stub_herdr
  STUB_START_MODE=busy-once run child_start --kind claude --name child-a --wait
  assert_success
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 2

  child_stub_herdr
  STUB_START_MODE=error run child_start --kind claude --name child-b --wait
  assert_failure
  assert_output --partial "agent start failed"
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 1
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

function test_scripts_072_herdr_child_closes_its_pane_after_three_readines() {
  _bats_test_init 72 'herdr-child closes its pane after three readiness failures'
  child_stub_herdr
  STUB_START_MODE=busy run child_start --kind claude --name child-a --wait
  assert_failure
  assert_output --partial "three agent start attempts"
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 3
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

function test_scripts_073_herdr_child_distinguishes_a_stalled_initial_prom() {
  _bats_test_init 73 'herdr-child distinguishes a stalled initial prompt'
  child_stub_herdr
  STUB_PROMPT_FAIL=1 run child_start --kind claude --name child-a --wait
  assert_failure
  assert_output --partial "initial prompt stalled"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

function test_scripts_074_herdr_child_preserves_a_working_pane_when_the_wa() {
  _bats_test_init 74 'herdr-child preserves a working pane when the wait times out'
  child_stub_herdr
  STUB_PROMPT_TIMEOUT=1 run child_start --kind claude --name child-a --wait
  assert_failure 124
  assert_output --partial '{"agent":"child-a","pane":"wT:p9"}'
  assert_output --partial "wait timed out"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_075_herdr_child_ask_requires_every_injected_child_co() {
  _bats_test_init 75 'herdr-child ask requires every injected child coordinate'
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_NAME=child-a bash "$HERDR_CHILD" ask question
  assert_failure
  assert_output --partial "HERDR_CHILD_PARENT_PANE is missing"
  [ ! -f "$CHILD_STUB/calls.log" ]
}

function test_scripts_076_herdr_child_ask_publishes_before_delivery_and_us() {
  _bats_test_init 76 'herdr-child ask publishes before delivery and uses the versioned marker'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"parent","pane_id":"wT:p0"}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 \
    HERDR_PANE_ID=wT:p9 HERDR_CHILD_NAME=child-a HERDR_CHILD_PARENT_PANE=wT:p0 \
    bash "$HERDR_CHILD" ask "Which path?"
  assert_success
  local call1 call2 call3 call4
  call1="$(sed -n '1p' "$CHILD_STUB/calls.log")"
  call2="$(sed -n '2p' "$CHILD_STUB/calls.log")"
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  call4="$(sed -n '4p' "$CHILD_STUB/calls.log")"
  [[ "$call1" == pane\ report-metadata*wT:p9*--source\ child-agent*--state-label*--ttl-ms\ 3600000* ]] || fail "waiting label was not published first: $call1"
  [[ "$call2" == pane\ get*wT:p9* ]] || fail "child metadata was not read second: $call2"
  [[ "$call3" == agent\ list* ]] || fail "parent identity was not resolved third: $call3"
  [[ "$call4" == agent\ prompt*wT:p0*child-ask*agent=child-a*pane=wT:p9* ]] || fail "callback was not delivered fourth: $call4"
  [[ "$call4" != *--wait* ]] || fail "callback delivery unexpectedly waited: $call4"
}

function test_scripts_077_herdr_child_ask_leaves_the_label_when_parent_loo() {
  _bats_test_init 77 'herdr-child ask leaves the label when parent lookup or delivery fails'
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

function test_scripts_078_herdr_child_reply_validates_the_live_pair_delive() {
  _bats_test_init 78 'herdr-child reply validates the live pair, delivers, then clears'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"child-a","pane_id":"wT:p9"}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reply --to child-a --pane wT:p9 "Use path A"
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

function test_scripts_079_herdr_child_ask_and_reply_publish_strictly_incre() {
  _bats_test_init 79 'herdr-child ask and reply publish strictly increasing label sequences'
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

function test_scripts_080_herdr_child_reply_keeps_the_label_when_delivery() {
  _bats_test_init 80 'herdr-child reply keeps the label when delivery fails and refuses child callers'
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

function test_scripts_081_herdr_child_reap_closes_only_settled_unfocused_n() {
  _bats_test_init 81 'herdr-child reap closes only settled, unfocused, non-waiting panes'
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

function test_scripts_082_herdr_child_reap_closes_an_unfocused_idle_pane() {
  _bats_test_init 82 'herdr-child reap closes an unfocused idle pane'
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

function test_scripts_083_herdr_child_reap_rejects_an_empty_expected_pane() {
  _bats_test_init 83 'herdr-child reap rejects an empty expected pane'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"idle-a","pane_id":"wT:p1","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --pane "" idle-a
  assert_failure 2
  assert_output --partial "reap --pane requires a non-empty pane ID"
  assert_file_not_exists "$CHILD_STUB/calls.log"
}

function test_scripts_084_herdr_child_reap_preserves_a_reused_name_outside() {
  _bats_test_init 84 'herdr-child reap preserves a reused name outside the expected pane'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"reused-a","pane_id":"wT:p2","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --pane wT:p1 reused-a
  assert_success
  assert_output --partial "reused-a: kept; expected pane wT:p1, current pane is wT:p2"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_085_herdr_child_reap_preserves_a_pane_when_fresh_sta() {
  _bats_test_init 85 'herdr-child reap preserves a pane when fresh state no longer matches'
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

function test_scripts_086_herdr_child_reap_refuses_outside_herdr_and_from() {
  _bats_test_init 86 'herdr-child reap refuses outside herdr and from a child pane'
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV= HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap child-a
  assert_failure
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_PARENT_PANE=wT:p0 bash "$HERDR_CHILD" reap child-a
  assert_failure
  assert_output --partial "parent-side"
}

function test_scripts_087_herdr_child_reap_preserves_a_settled_pane_with_a() {
  _bats_test_init 87 'herdr-child reap preserves a settled pane with a waiting label'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"wait-a","pane_id":"wT:p1","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_LABEL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap wait-a
  assert_success
  assert_output --partial "has a waiting state label"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_088_herdr_child_reap_preserves_a_settled_pane_when_p() {
  _bats_test_init 88 'herdr-child reap preserves a settled pane when pane metadata is malformed'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"bad-meta-a","pane_id":"wT:p1","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PANE_GET_MALFORMED=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap bad-meta-a
  assert_success
  assert_output --partial "bad-meta-a: kept; pane metadata could not be read"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_089_herdr_child_reap_closes_a_positively_owned_one_p() {
  _bats_test_init 89 'herdr-child reap closes a positively owned one-pane tab'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"tab-a","pane_id":"wT:p1","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PANE_TAB_ID=wT:tA \
    STUB_TAB_GET_FAIL=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap tab-a
  assert_success
  assert_output --partial "tab-a: closed pane wT:p1 and tab wT:tA"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p1'
  assert_file_contains "$CHILD_STUB/calls.log" '^tab get wT:tA'
}

function test_scripts_090_herdr_child_reap_closes_the_child_pane_but_repor() {
  _bats_test_init 90 'herdr-child reap closes the child pane but reports a surviving multi-pane tab'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"tab-a","pane_id":"wT:p1","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PANE_TAB_ID=wT:tA \
    STUB_TAB_PANE_COUNT=2 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap tab-a
  assert_success
  assert_output --partial "tab-a: closed pane wT:p1; tab wT:tA kept with 2 panes"
}

function test_scripts_091_herdr_child_reap_preserves_ambiguous_tab_ownersh() {
  _bats_test_init 91 'herdr-child reap preserves ambiguous tab ownership'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"tab-a","pane_id":"wT:p1","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PANE_TAB_ID=wT:tA \
    STUB_PANE_CHILD_TAB_TOKEN=wT:tOTHER HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap tab-a
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
    bash "$HERDR_CHILD" reap --pane wT:p9 child-life
  assert_success
  assert_output --partial "closed pane wT:p9 and tab wT:tA"
  assert_file_exists "$CHILD_STUB/reap-invalidation-observed"
  assert_file_not_exists "$CHILD_STUB/close-before-invalidation"
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
{"tool_name":"WebFetch","tool_input":{"url":"https://smithers.sh/docs"}}
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
{"tool_name":"WebFetch","tool_input":{"url":"https://markdown.new/https://smithers.sh/docs"}}
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

# ===========================================
# herdr-task-sync engine
# ===========================================

function test_scripts_101_herdr_task_sync_descriptor_probe_lives_in_a_one() {
  _bats_test_init 101 'herdr-task-sync descriptor probe lives in a one-test bashunit file'
  local descriptor_probe_file="$BATS_TEST_DIRNAME/bashunit/herdr_task_sync_descriptor_probe_test.sh"
  assert_file_exists "$descriptor_probe_file"
  run env NO_COLOR=1 "$BATS_TEST_DIRNAME/lib/bashunit" --list "$descriptor_probe_file"
  assert_success
  # --list prints one `file::function` line per test plus a trailing count.
  assert_output --partial "::test_herdr_task_sync_descriptor_child_probe"
  assert_output --partial "1 test"
  assert_equal "${#lines[@]}" 2
}

function test_scripts_102_herdr_task_sync_bounded_bats_invocation_exits_af() {
  _bats_test_init 102 'herdr-task-sync bounded bashunit invocation exits after detached work'
  # No python3 skip guard: it is a declared requirement (README.md,
  # Requirements), a deliberate exception to the skip convention in
  # docs/issues/2026-08-20-013-se-blocks-test-hard-fails-without-deps.md.
  local bashunit_bin release_file="$BATS_TEST_TMPDIR/release-herdr"
  local pid_file="$BATS_TEST_TMPDIR/descriptor-worker.pid"
  local blocked_pid_file="$BATS_TEST_TMPDIR/blocked-herdr.pid"
  local descriptor_probe_file="$BATS_TEST_DIRNAME/bashunit/herdr_task_sync_descriptor_probe_test.sh"
  bashunit_bin="$BATS_TEST_DIRNAME/lib/bashunit"
  export HTS_DESCRIPTOR_RELEASE_FILE="$release_file"
  export HTS_DESCRIPTOR_PID_FILE="$pid_file"
  export HTS_DESCRIPTOR_BLOCKED_PID_FILE="$blocked_pid_file"
  # This is the only test whose stub must stay blocked across a whole nested
  # runner invocation, so it is the only one that gets the raised ceiling.
  export HTS_BLOCKED_HERDR_POLLS
  run python3 - "$bashunit_bin" "$descriptor_probe_file" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

# Two bounds, not one, and they measure different things. See the
# HTS_INNER_BATS_* comments in this file's constants block for why the single
# budget this replaced was a latent flake. (The env names keep their historical
# BATS spelling; the nested runner is now tests/lib/bashunit.)
#
# PROGRESS covers the nested run up to the probe writing its pid file. That run
# targets a dedicated one-test file, so the guard covers setup and the probe
# itself rather than the runner parsing the whole scripts suite.
#
# EXIT covers what happens after that signal: the nested runner must exit AND
# its output pipes must reach end-of-file. That pair is the property under test.
# Waiting on process exit alone would not detect the regression -- a detached
# worker that inherited the pipes keeps them open after the runner itself is
# gone, so EOF, not exit, is what a leaked descriptor withholds. The pipes are
# also why the nested run must never be given temp files instead: a worker
# holding a file descriptor blocks nothing, and the test would pass
# unconditionally.
progress_budget = int(os.environ.get("HTS_INNER_BATS_PROGRESS_SECONDS", "60"))
exit_budget = int(os.environ.get("HTS_INNER_BATS_EXIT_SECONDS", "30"))

# Distinct status per failure mode, so the outer test's failure block names which
# bound fired without reading the message. Avoid 126 and 127: the shell reserves
# them for "not executable" and "not found".
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
    "nothing held a descriptor while the inner runner exited -- this run proved nothing"
)

# No filter: the probe file holds exactly one test (the outer suite asserts
# that separately). NO_COLOR keeps the nested runner's output byte-greppable.
proc = subprocess.Popen(
    [sys.argv[1], sys.argv[2]],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env={**os.environ, "NO_COLOR": "1"},
)

# Drain both pipes from launch in their own threads. Nothing may leave a pipe
# unread: the nested run blocks on a full pipe buffer otherwise, and on the
# nested-test-failure path the runner echoes the failed test's captured output, which
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
# seconds away -- the nested run still has to start the runner, source the harness, and
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
# CPU that the runner's own parsing dwarfs anyway.
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
                f"inner runner exited with status {proc.returncode} before its test "
                "completed; it never wrote the descriptor pid file",
                EXIT_EARLY,
            )
        break
    if time.monotonic() > progress_deadline:
        report(
            f"inner runner did not reach its completion signal within "
            f"{progress_budget} seconds (hang guard)",
            EXIT_HANG_GUARD,
        )
    time.sleep(poll_interval)
    poll_interval = min(poll_interval * 1.5, poll_interval_cap)

# Phase 2: the property. Exit and EOF must both arrive, and quickly -- only
# teardown remains.
#
# Both are one condition, not two. A leaked descriptor does not merely keep the
# pipes open after the runner exits: the runner's own formatter reads that pipeline to EOF, so
# a descendant holding the write end stops the whole nested invocation from
# finishing. Rehearsal confirms it -- with close_inherited_descriptors neutered,
# it is the process wait that times out, not the reader join. Splitting these
# into separate faults would file the real regression under "the runner is stuck, which
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
    symptom = "the runner process never exited"

if symptom is None:
    for reader in readers:
        remaining = exit_budget - (time.monotonic() - exit_started)
        reader.join(timeout=max(remaining, 0))
    if any(reader.is_alive() for reader in readers):
        symptom = "the runner exited but its output pipes never reached EOF"

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
print(f"inner runner exit phase took {exit_elapsed:.3f}s", file=sys.stderr)

# Non-vacuity: the herdr stub must STILL be blocked right now. Everything above
# only proves the nested runner exited and closed its pipes -- which is unremarkable
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
        "a give-up; nothing held a descriptor while the inner runner exited",
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
    print(f"inner runner exited with status {proc.returncode}", file=sys.stderr)
    raise SystemExit(EXIT_NESTED_FAILED)
PY
  unset HTS_DESCRIPTOR_RELEASE_FILE HTS_DESCRIPTOR_PID_FILE
  # No fd-3 console forward of the driver's exit-phase measurement: bashunit
  # binds fd 3 to the worker's raw stream (`exec 3>&1` before per-test capture),
  # and under -j a write there can land as the last line of a worker's .result
  # file, which the parallel aggregator then cannot parse and counts as a
  # phantom failed test with zero failed assertions. The measurement stays in
  # the driver's stderr, which bashunit prints whenever this test fails -- the
  # only time HTS_INNER_BATS_EXIT_SECONDS needs recalibrating.
  assert_success
  assert_output --partial "Passed: herdr-task-sync descriptor child probe"
}

# Guards the guard. The test above can only prove anything while the herdr stub
# is still blocked -- if the stub gives up first, nothing holds a descriptor and
# a green run means nothing. That was not a hypothetical: the first version of
# the non-vacuity check watched the stub's parent, which outlives the give-up, so
# it passed on exactly the vacuous run it was written to catch.
#
# Pinning the stub to give up immediately must therefore turn the test red. This
# costs one extra nested runner invocation, which is the expensive thing in this file
# (docs/issues/2026-08-21-021), and it buys the one property no other test here
# can assert: that the guard above still fails when it should.
function test_scripts_103_herdr_task_sync_bounded_bats_invocation_refuses() {
  _bats_test_init 103 'herdr-task-sync bounded bashunit invocation refuses a vacuous run'
  local release_file="$BATS_TEST_TMPDIR/release-herdr"
  local pid_file="$BATS_TEST_TMPDIR/descriptor-worker.pid"
  local blocked_pid_file="$BATS_TEST_TMPDIR/blocked-herdr.pid"
  export HTS_DESCRIPTOR_RELEASE_FILE="$release_file"
  export HTS_DESCRIPTOR_PID_FILE="$pid_file"
  export HTS_DESCRIPTOR_BLOCKED_PID_FILE="$blocked_pid_file"
  # One poll: the stub records its give-up before the driver ever looks.
  export HTS_BLOCKED_HERDR_POLLS=1

  # bashunit's -f matches function names (test_*<filter>*), not titles; the
  # numeric prefix is the one substring unique to the guarded test above.
  run env NO_COLOR=1 "$BATS_TEST_DIRNAME/lib/bashunit" \
    -f 'scripts_102' "$BATS_TEST_FILENAME"

  unset HTS_DESCRIPTOR_RELEASE_FILE HTS_DESCRIPTOR_PID_FILE
  unset HTS_DESCRIPTOR_BLOCKED_PID_FILE HTS_BLOCKED_HERDR_POLLS
  assert_failure
  assert_output --partial "this run proved nothing"
}

function test_scripts_104_herdr_task_sync_harness_fresh_reads_follow_pane() {
  _bats_test_init 104 'herdr-task-sync harness fresh reads follow pane and tab mutations'
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

function test_scripts_105_herdr_task_sync_harness_controls_reverse_model_c() {
  _bats_test_init 105 'herdr-task-sync harness controls reverse model completion by generation'
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

function test_scripts_106_herdr_task_sync_harness_isolates_colliding_sanit() {
  _bats_test_init 106 'herdr-task-sync harness isolates colliding sanitized socket names'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local socket_one="$HTS_WORK/a-b.sock" socket_two="$HTS_WORK/a_b.sock"
  local dir_one dir_two sanitized_one sanitized_two
  sanitized_one="$(printf '%s' "$socket_one" | sed 's/[^[:alnum:]]/_/g')"
  sanitized_two="$(printf '%s' "$socket_two" | sed 's/[^[:alnum:]]/_/g')"
  assert_equal "$sanitized_one" "$sanitized_two"
  dir_one="$(hts_socket_dir "$socket_one")"
  dir_two="$(hts_socket_dir "$socket_two")"
  [[ "$dir_one" != "$dir_two" ]] || fail "colliding socket names shared one harness directory: $dir_one"
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

function test_scripts_107_herdr_task_sync_harness_applies_source_metadata() {
  _bats_test_init 107 'herdr-task-sync harness applies source metadata sequence and clear rules'
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

function test_scripts_108_herdr_task_sync_harness_models_target_loss_move() {
  _bats_test_init 108 'herdr-task-sync harness models target loss move reuse and final-read change'
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

function test_scripts_109_herdr_task_sync_latest_committed_request_survive() {
  _bats_test_init 109 'herdr-task-sync latest committed request survives stale completion and a third request'
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

function test_scripts_110_herdr_task_sync_active_native_session_fences_reu() {
  _bats_test_init 110 'herdr-task-sync active native session fences reused pane and session identifiers'
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

function test_scripts_111_herdr_task_sync_prompt_transcript_and_direct_set() {
  _bats_test_init 111 'herdr-task-sync prompt transcript and direct set share one committed-generation contract'
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
    [[ "$(hts_record_number "$control" presentation_generation)" -gt 0 ]] || fail "presentation generation was not positive for $mode"
  done
  task="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-transcript transcript-s)"
  assert_equal "$(hts_record_text "$task" first_prompt)" "transcript first"
  assert_equal "$(hts_record_text "$task" latest_prompt)" "transcript latest"
}

function test_scripts_112_herdr_task_sync_failed_latest_model_retains_newe() {
  _bats_test_init 112 'herdr-task-sync failed latest model retains newest context and prior slug'
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

function test_scripts_113_herdr_task_sync_atomic_records_never_expose_trun() {
  _bats_test_init 113 'herdr-task-sync atomic records never expose truncation or mixed fields'
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

function test_scripts_114_herdr_task_sync_one_way_legacy_import_is_atomic() {
  _bats_test_init 114 'herdr-task-sync one-way legacy import is atomic idempotent and ignores late legacy writes'
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

function test_scripts_115_herdr_task_sync_restart_recovers_accepted_and_in() {
  _bats_test_init 115 'herdr-task-sync restart recovers accepted and interrupted worker generations'
  hts_setup
  hts_stub_controlled_engine pi
  hts_model_fixture pi 1 abandoned-result
  hts_model_fixture pi 2 recovered-result
  local control task first_worker first_owner second_worker worker_claim
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  task="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 restart-s)"

  HERDR_TASK_SYNC_TEST_NO_WORKER=1 hts_run --agent claude --session restart-s <<< 'restart request'
  [[ "$(hts_record_number "$control" generation)" -gt \
    "$(hts_record_number "$control" committed_generation)" ]] || fail "restart fixture had no pending generation"
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

function test_scripts_116_herdr_task_sync_clock_rollback_and_restart_canno() {
  _bats_test_init 116 'herdr-task-sync clock rollback and restart cannot lower generation or task high-water'
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
  [[ "$second_generation" -gt "$first_generation" ]] || fail "generation did not advance after clock rollback"
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
  [[ "$second_high_water" -ge "$second_generation" ]] || fail "task metadata high-water fell below generation"
}

function test_scripts_117_herdr_task_sync_exact_socket_namespaces_survive() {
  _bats_test_init 117 'herdr-task-sync exact socket namespaces survive legacy sanitized-name collisions'
  hts_setup
  local socket_one="$HTS_WORK/a-b.sock" socket_two="$HTS_WORK/a_b.sock"
  local task_one task_two namespace_one namespace_two
  namespace_one="$(hts_namespace "$socket_one")"
  namespace_two="$(hts_namespace "$socket_two")"
  [[ "$namespace_one" != "$namespace_two" ]] || fail "exact socket paths shared one namespace: $namespace_one"

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
  [[ "$(hts_record_number "$namespace_one/reconcile.state" task_metadata_high_water)" -gt 0 ]] || fail "first socket task high-water was not positive"
  assert_equal "$(hts_record_number "$namespace_one/reconcile.state" location_metadata_high_water)" 0
  [[ "$(hts_record_number "$namespace_two/reconcile.state" task_metadata_high_water)" -gt 0 ]] || fail "second socket task high-water was not positive"
  assert_equal "$(hts_record_number "$namespace_two/reconcile.state" location_metadata_high_water)" 0
  grep -q '^checkout_root=' "$namespace_one/reconcile.state"
  grep -q '^repository_anchor=' "$namespace_one/reconcile.state"
}

function test_scripts_118_herdr_task_sync_fail_open_guard_ignores_terminal() {
  _bats_test_init 118 'herdr-task-sync fail-open guard ignores terminal input and preserves redirected input'
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

function test_scripts_119_herdr_task_sync_fail_open_deadline_rejects_late() {
  _bats_test_init 119 'herdr-task-sync fail-open deadline rejects late success before the hang guard'
  hts_setup
  local HTS_FAIL_OPEN_BEHAVIOR_SECONDS=1
  local HTS_FAIL_OPEN_BASELINE_MULTIPLIER=1
  local HTS_FAIL_OPEN_MAX_SECONDS=5

  run hts_run_fail_open_guard sleep 2 < /dev/null

  assert_failure 124
  assert_output --partial "exceeded fail-open behavioral deadline"
}

function test_scripts_120_herdr_task_sync_fail_open_guard_uses_the_greater() {
  _bats_test_init 120 'herdr-task-sync fail-open guard uses the greater baseline'
  run hts_fail_open_behavior_baseline_ms 200 8 1000
  assert_success
  assert_output 1600

  run hts_fail_open_behavior_baseline_ms 100 8 1000
  assert_success
  assert_output 1000
}

function test_scripts_121_herdr_task_sync_fails_open_for_missing_tools_con() {
  _bats_test_init 121 'herdr-task-sync fails open for missing tools contention write failure and malformed input'
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
  run hts_run_fail_open_guard hts_worker_run < /dev/null
  assert_success
  [[ "$(hts_record_number "$control" generation)" -gt \
    "$(hts_record_number "$control" committed_generation)" ]] || fail "worker write failure committed its pending generation"

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
  run hts_run_fail_open_guard hts_worker_run < /dev/null
  assert_success
  [[ "$(hts_record_number "$control" generation)" -gt \
    "$(hts_record_number "$control" committed_generation)" ]] || fail "task write failure committed its pending generation"
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

function test_scripts_122_herdr_task_sync_orders_adapter_calls_by_inbox_co() {
  _bats_test_init 122 'herdr-task-sync orders adapter calls by inbox commit rather than invocation start'
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
  [[ "$(hts_record_number "$control" committed_generation)" -gt "$first_generation" ]] || fail "later inbox commit did not advance generation"
}

function test_scripts_123_herdr_task_sync_adapters_return_when_a_direct_en() {
  _bats_test_init 123 'herdr-task-sync adapters return when a direct engine hangs'
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

function test_scripts_124_herdr_task_sync_opencode_forgets_a_deleted_child() {
  _bats_test_init 124 'herdr-task-sync opencode forgets a deleted child session'
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

function test_scripts_125_herdr_task_sync_presentation_coordinates_concurr() {
  _bats_test_init 125 'herdr-task-sync presentation coordinates concurrent panes in one shared tab'
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

function test_scripts_126_herdr_task_sync_presentation_accepts_pi_jsonl_pa() {
  _bats_test_init 126 'herdr-task-sync presentation accepts pi jsonl path sessions that end with the active session id'
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

function test_scripts_127_herdr_task_sync_presentation_labels_a_detected_a() {
  _bats_test_init 127 'herdr-task-sync presentation labels a detected agent without task state'
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

function test_scripts_128_herdr_task_sync_presentation_publishes_only_the() {
  _bats_test_init 128 'herdr-task-sync presentation publishes only the newest accepted generation'
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
  run grep -c -- '--source task-sync' "$HTS_LOG"
  assert_output "1"
  run grep -c -- '--source sidebar-sync' "$HTS_LOG"
  assert_output "1"
}

function test_scripts_129_herdr_task_sync_presentation_coalesces_event_bur() {
  _bats_test_init 129 'herdr-task-sync presentation coalesces event bursts into an active pass and rerun'
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

function test_scripts_130_herdr_task_sync_presentation_retries_a_newer_inv() {
  _bats_test_init 130 'herdr-task-sync presentation retries a newer invalidation after transient pass failure'
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

function test_scripts_131_herdr_task_sync_presentation_release_recheck_doe() {
  _bats_test_init 131 'herdr-task-sync presentation release recheck does not lose a pending invalidation'
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

function test_scripts_132_herdr_task_sync_event_presentation_leaves_the_ho() {
  _bats_test_init 132 'herdr-task-sync event presentation leaves the hook process group'
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

function test_scripts_133_herdr_task_sync_presentation_automatically_corre() {
  _bats_test_init 133 'herdr-task-sync presentation automatically corrects divergent pane and tab labels'
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

function test_scripts_134_herdr_task_sync_presentation_drops_a_malformed_w() {
  _bats_test_init 134 'herdr-task-sync presentation drops a malformed-width record and keeps labeling the rest'
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

function test_scripts_135_herdr_task_sync_presentation_skips_pre_read_dele() {
  _bats_test_init 135 'herdr-task-sync presentation skips pre-read deletion and repairs the post-read race next pass'
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

function test_scripts_136_herdr_task_sync_presentation_skips_reused_pane_a() {
  _bats_test_init 136 'herdr-task-sync presentation skips reused pane and tab identities at the final read'
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

function test_scripts_137_herdr_task_sync_age_cleanup_removes_only_inactiv() {
  _bats_test_init 137 'herdr-task-sync age cleanup removes only inactive task payloads'
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

function test_scripts_138_herdr_task_sync_presentation_preserves_state_on() {
  _bats_test_init 138 'herdr-task-sync presentation preserves state on incomplete and transient snapshots'
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

function test_scripts_139_herdr_task_sync_naming_worker_never_age_cleans_t() {
  _bats_test_init 139 'herdr-task-sync naming worker never age-cleans tasks without safe snapshot ownership'
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

function test_scripts_140_herdr_task_sync_presentation_isolates_exact_coll() {
  _bats_test_init 140 'herdr-task-sync presentation isolates exact colliding socket identities'
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
  [[ "$(hts_namespace "$socket_one")" != "$(hts_namespace "$socket_two")" ]] || fail "presentation sockets shared one namespace"
}

function test_scripts_141_herdr_task_sync_presentation_recovers_stale_and() {
  _bats_test_init 141 'herdr-task-sync presentation recovers stale and half-created owner claims'
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

function test_scripts_142_herdr_task_sync_presentation_resumes_safely_acro() {
  _bats_test_init 142 'herdr-task-sync presentation resumes safely across durable crash boundaries'
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

function test_scripts_143_herdr_task_sync_presentation_self_events_converg() {
  _bats_test_init 143 'herdr-task-sync presentation self-events converge to a no-op'
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

function test_scripts_144_herdr_task_sync_presentation_fails_closed_withou() {
  _bats_test_init 144 'herdr-task-sync presentation fails closed without an exact socket'
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

function test_scripts_145_herdr_task_sync_presentation_restart_recomputes() {
  _bats_test_init 145 'herdr-task-sync presentation restart recomputes durable pending intent without a label ledger'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  HERDR_TASK_SYNC_TEST_NO_PRESENTATION=1 hts_run --agent pi --session restart-presentation --set restart-task < /dev/null
  local reconcile="$(hts_namespace "$HTS_DEFAULT_SOCKET")/reconcile.state"
  hts_wait_for_record_number "$reconcile" pending_generation 1
  [[ "$(hts_record_number "$reconcile" pending_generation)" -gt "$(hts_record_number "$reconcile" completed_generation 2>/dev/null || printf 0)" ]] || fail "presentation restart fixture had no pending intent"
  run hts_presentation_run
  assert_success
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
  assert_equal "$(jq -r '.panes[0].label' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" pi:restart-task
  run grep -ER 'intended_label|applied_label|manual_owner|reclaim|server_epoch|prepare_rollback' "$(hts_namespace "$HTS_DEFAULT_SOCKET")"
  assert_failure
}

function test_scripts_146_herdr_task_sync_location_resolves_main_linked_ne() {
  _bats_test_init 146 'herdr-task-sync location resolves main linked nested and administrative paths with strict foreground semantics'
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
  # Main checkout: Git identity is only the branch.
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "main-nested" or .pane_id == "main-admin") | .tokens.git_ref' "$state" | sort -u)" "$HTS_ICON_BRANCH main"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "linked-admin" or .pane_id == "fallback") | .tokens.branch' "$state" | sort -u)" feature
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "linked-admin" or .pane_id == "fallback") | .tokens.worktree' "$state" | sort -u)" feature
  # Linked worktree (.git file at root): Git identity is only the branch.
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "linked-admin" or .pane_id == "fallback") | .tokens.git_ref' "$state" | sort -u)" "$HTS_ICON_WORKTREE feature"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "agent-ignores-foreground") | .tokens.branch' "$state")" feature
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "agent-ignores-foreground") | .tokens.worktree' "$state")" feature
  run jq -e --arg ref "$HTS_ICON_FOLDER outside" '
    .panes[] | select(.pane_id == "foreground-wins")
    | (.tokens.repo == null and .tokens.worktree == null and .tokens.branch == null and .tokens.git_ref == $ref)
  ' "$state"
  assert_success
  assert_equal "$(cat "$(hts_git_fixture_dir "$nongit")/locale")" C
}

function test_scripts_147_herdr_task_sync_dangling_administrative_gitdir_r() {
  _bats_test_init 147 'herdr-task-sync dangling administrative gitdir retains stale location'
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

function test_scripts_148_herdr_task_sync_location_detached_and_non_git_id() {
  _bats_test_init 148 'herdr-task-sync location detached and non-Git identities persist across transient probes'
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
  [[ "$second_seq" -gt "$first_seq" ]] || fail "detached location sequence did not advance"
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
  # Confirmed non-Git clears Git-specific metadata but publishes the cwd
  # basename as the durable location identity.
  assert_equal "$(jq -cS '.panes[0].tokens' "$state")" \
    "{\"agent_line\":\"repo worker\",\"git_line\":\"$HTS_ICON_FOLDER non-git$HTS_SIDEBAR_PADDING\",\"git_ref\":\"$HTS_ICON_FOLDER non-git\",\"task\":\"kept-task\"}"
  [[ "$(hts_location_source_seq "$HTS_DEFAULT_SOCKET" pane-1)" -gt "$second_seq" ]] || fail "non-Git location sequence did not advance"

  # A later probe failure retains the prior folder identity instead of
  # reverting to the older Git identity or clearing the location.
  printf '%s' 127 > "$(hts_git_fixture_dir "$nongit")/status"
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_FOLDER non-git $HTS_ICON_STALE"
  assert_equal "$(jq -r '.panes[0].tokens.location_status' "$state")" stale
}

function test_scripts_149_herdr_task_sync_location_real_probe_shape_pays_t() {
  _bats_test_init 149 'herdr-task-sync location real probe shape pays the second sha call only when detached'
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

function test_scripts_150_herdr_task_sync_location_detached_sha_failure_re() {
  _bats_test_init 150 'herdr-task-sync location detached sha failure retains prior identity as stale and never publishes a malformed git_ref'
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

function test_scripts_151_herdr_task_sync_location_detached_sha_budget_fai() {
  _bats_test_init 151 'herdr-task-sync location detached sha budget failure with no prior state renders no git location and self-heals'
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

function test_scripts_152_herdr_task_sync_location_clears_the_retired_loca() {
  _bats_test_init 152 'herdr-task-sync location clears the retired location_label token on both publish and non-git clear paths'
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
  # then: the non-Git path sheds it while publishing its folder identity
  run jq -e --arg ref "$HTS_ICON_FOLDER non-git" '
    .panes[] | select(.pane_id == "pane-2") | (.tokens.location_label == null and .tokens.git_ref == $ref)
  ' "$state"
  assert_success
}

function test_scripts_153_herdr_task_sync_location_transient_modes_retain() {
  _bats_test_init 153 'herdr-task-sync location transient modes retain identity as stale without foreground fallback'
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

function test_scripts_154_herdr_task_sync_coordinator_resolves_eight_pane() {
  _bats_test_init 154 'herdr-task-sync coordinator resolves eight pane locations concurrently within one event envelope'
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
    run jq -e --arg pane "pane-$i" --arg ref "$HTS_ICON_FOLDER work" \
      '.panes[] | select(.pane_id == $pane) | (.tokens.repo == null and .tokens.worktree == null and .tokens.branch == null and .tokens.location_status == null and .tokens.git_ref == $ref)' "$state"
    assert_success
    fixture="$(hts_git_fixture_dir "$HTS_WORK/repos/repo-$i/work")"
    assert_file_exists "$fixture/started"
    assert_file_exists "$fixture/completed"
  done
  assert_file_exists "$blocked_fixture/started"
  assert_file_not_exists "$blocked_fixture/completed"
}

function test_scripts_155_herdr_task_sync_no_op_location_event_preserves_t() {
  _bats_test_init 155 'herdr-task-sync no-op location event preserves the state file'
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

function test_scripts_156_herdr_task_sync_transient_location_preserves_liv() {
  _bats_test_init 156 'herdr-task-sync transient location preserves live token-only identity when retained state is unavailable'
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
  # back to the branch icon. A ref-less prior identity remains a folder.
  run jq -e \
    --arg ref_one "$HTS_ICON_BRANCH topic-one $HTS_ICON_STALE" \
    --arg ref_two "$HTS_ICON_FOLDER live-token $HTS_ICON_STALE" \
    --arg pad "$HTS_SIDEBAR_PADDING" '
    (.panes[] | select(.pane_id == "pane-1") | .tokens == {repo:"live-repo",worktree:"live-token",branch:"topic-one",location_status:"stale",git_ref:$ref_one,agent_line:"one",git_line:($ref_one + $pad)})
    and (.panes[] | select(.pane_id == "pane-2") | .tokens == {repo:"live-repo",worktree:"live-token",location_status:"stale",git_ref:$ref_two,agent_line:"two",git_line:($ref_two + $pad)})
  ' "$state"
  assert_success
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "one · two · three"
  assert_file_not_exists "$(hts_pane_state_dir "$HTS_DEFAULT_SOCKET" pane-1)/location.state"
  assert_equal "$(cat "$location_two")" not-a-location-record
}

function test_scripts_157_herdr_task_sync_location_authoritative_worktree() {
  _bats_test_init 157 'herdr-task-sync location authoritative worktree deletion clears retained evidence'
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

function test_scripts_158_herdr_task_sync_formatter_keeps_git_refs_in_meta() {
  _bats_test_init 158 'herdr-task-sync formatter keeps Git refs in metadata and tab labels names-only'
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

function test_scripts_159_herdr_task_sync_formatter_renders_a_main_checkou() {
  _bats_test_init 159 'herdr-task-sync formatter renders a main checkout ref in metadata only'
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

function test_scripts_160_herdr_task_sync_formatter_renders_a_worktree_ref() {
  _bats_test_init 160 'herdr-task-sync formatter renders a worktree ref in metadata only'
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

function test_scripts_161_herdr_task_sync_formatter_keeps_a_git_backed_all() {
  _bats_test_init 161 'herdr-task-sync formatter keeps a Git-backed all-idle tab names-only'
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
  assert_equal "$(jq -r '.panes[] | .tokens.git_ref' "$state" | sort -u)" "$HTS_ICON_BRANCH main"
}

function test_scripts_162_herdr_task_sync_git_only_location_changes_do_not() {
  _bats_test_init 162 'herdr-task-sync Git-only location changes do not rename a names-only tab'
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

function test_scripts_163_herdr_task_sync_formatter_never_qualifies_a_git() {
  _bats_test_init 163 'herdr-task-sync formatter never qualifies a Git branch with its folder'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # Git identity is the branch regardless of the checkout folder or workspace
  # name. Folder identity belongs exclusively to confirmed non-Git locations.
  local root="$HTS_WORK/setup-copy" state
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

function test_scripts_164_herdr_task_sync_formatter_reads_the_workspace_di() {
  _bats_test_init 164 'herdr-task-sync formatter reads the workspace display name from the legacy name field'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # Older snapshot shapes carry the workspace display name as `name`; it still
  # feeds the aggregate agent line independently of the Git identity.
  local root="$HTS_WORK/legacy-ws" state
  mkdir -p "$root/.git"
  hts_git_location_fixture "$root" "$root" "$root/.git" refs/heads/topic
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","name":"legacy-ws"}'
  hts_set_process_label pane-1 task
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.agent_line' "$state")" "legacy-ws task"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_BRANCH topic"
}

function test_scripts_165_herdr_task_sync_formatter_gives_a_detached_head() {
  _bats_test_init 165 'herdr-task-sync formatter gives a detached HEAD inside a linked worktree the commit icon'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # The commit place deliberately wins over the worktree place: the detached
  # short SHA is the complete Git identity.
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
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_COMMIT a1b2c3d"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" task
}

function test_scripts_166_herdr_task_sync_formatter_never_qualifies_a_link() {
  _bats_test_init 166 'herdr-task-sync formatter never qualifies a linked worktree branch with its folder'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # The worktree icon and branch are the complete Git identity even when the
  # checkout folder has a different name.
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
  assert_equal "$(jq -r '.panes[] | .tokens.git_ref' "$state" | sort -u)" "$HTS_ICON_WORKTREE fix-login"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"
}

function test_scripts_167_herdr_task_sync_formatter_keeps_mixed_git_identi() {
  _bats_test_init 167 'herdr-task-sync formatter keeps mixed Git identities out of tabs and repairs external labels'
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

function test_scripts_168_herdr_task_sync_formatter_joins_only_pane_labels() {
  _bats_test_init 168 'herdr-task-sync formatter joins only pane labels when three panes span two repositories'
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

function test_scripts_169_herdr_task_sync_worktree_tokens_use_shortest_uni() {
  _bats_test_init 169 'herdr-task-sync worktree tokens use shortest unique slash suffixes for basename collisions'
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
  # Worktree tokens remain independently available but never qualify Git refs.
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.git_ref' "$state")" "$HTS_ICON_WORKTREE one"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-2") | .tokens.git_ref' "$state")" "$HTS_ICON_WORKTREE two"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"
}

function test_scripts_170_herdr_task_sync_worktree_tokens_digest_overlong() {
  _bats_test_init 170 'herdr-task-sync worktree tokens digest overlong roots and extend colliding digest prefixes'
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
  [[ "$token_one" != "$token_two" ]] || fail "colliding worktree digests produced the same token: $token_one"
  [[ "$token_one" = *abcdef || "$token_two" = *abcdef ]] || fail "neither worktree token retained the six-character digest"
  [[ "$token_one" = *abcdef0 || "$token_two" = *abcdef1 ]] || fail "colliding digest prefixes were not extended"
}

function test_scripts_171_herdr_task_sync_worktree_token_ordinal_fallback() {
  _bats_test_init 171 'herdr-task-sync worktree token ordinal fallback is unique and stable under pane reordering'
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

function test_scripts_172_herdr_task_sync_long_branch_refs_stay_in_metadat() {
  _bats_test_init 172 'herdr-task-sync long branch refs stay in metadata and do not alter the tab label'
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
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_WORKTREE $long_ref"
}

function test_scripts_173_herdr_task_sync_long_repository_names_do_not_alt() {
  _bats_test_init 173 'herdr-task-sync long repository names do not alter a multi-repo tab label'
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

function test_scripts_174_herdr_task_sync_clears_retired_aggregate_tokens() {
  _bats_test_init 174 'herdr-task-sync clears retired aggregate tokens even when every published token already matches'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/repository" common="$HTS_WORK/repository/.git" state
  mkdir -p "$common"
  hts_git_location_fixture "$root" "$root" "$common" refs/heads/topic
  hts_git_status_fixture "$root" '1 .M N... 100644 100644 100644 1111111 1111111 one.txt'
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_process_label pane-1 worker
  # given: one pass has already published every current token
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_BRANCH topic"
  assert_equal "$(jq -r '.panes[0].tokens.git_unstaged' "$state")" "${HTS_GIT_UNSTAGED}1"
  assert_equal "$(jq -r '.panes[0].tokens.location_label // ""' "$state")" ""
  # given: a stale daemon of the retired version puts both aggregate tokens
  # back while leaving every current token untouched. It reports under the same
  # source at the sequence the last pass used, as a sharing old daemon would.
  local legacy_seq
  legacy_seq="$(jq -r '.metadata["pane-1"]["location-sync"].seq' "$state")"
  hts_socket_run "$HTS_DEFAULT_SOCKET" pane report-metadata pane-1 \
    --source location-sync --seq "$legacy_seq" --token 'location_label=repository/topic' \
    --token 'git_status=old-dirty-1'
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.location_label' "$state")" repository/topic
  assert_equal "$(jq -r '.panes[0].tokens.git_status' "$state")" old-dirty-1
  # when: the next pass computes identical tokens and would otherwise skip
  hts_location_pass
  # then: the legacy token is gone and the live tokens are unharmed
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.location_label // ""' "$state")" ""
  assert_equal "$(jq -r '.panes[0].tokens.git_status // ""' "$state")" ""
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_BRANCH topic"
  assert_equal "$(jq -r '.panes[0].tokens.git_unstaged' "$state")" "${HTS_GIT_UNSTAGED}1"
  assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" topic
}

function test_scripts_175_herdr_task_sync_location_and_formatter_add_only() {
  _bats_test_init 175 'herdr-task-sync location and formatter add only approved static icon glyphs and no forbidden ownership state'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/plain-worktree" common="$HTS_WORK/repository/.git" state
  mkdir -p "$root" "$common"
  hts_mark_linked_worktree "$root" "$common/worktrees/plain"
  hts_git_location_fixture "$root" "$root" "$common" refs/heads/plain
  # Exercise every status symbol so the character guard covers the complete
  # formatter rather than only identity and divergence.
  hts_git_status_fixture "$root" "$(printf '%s\n%s\n%s\n%s\n%s' \
    '# branch.ab +3 -4' \
    'u UU N... 100644 100644 100644 100644 1111111 2222222 3333333 conflict.txt' \
    '1 M. N... 100644 100644 100644 1111111 1111111 staged.txt' \
    '1 .M N... 100644 100644 100644 2222222 2222222 unstaged.txt' \
    '? untracked.txt')"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_process_label pane-1 plain-task
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  run grep -ER 'manual_owner|reclaim|label_ledger|server_epoch|takeover|prepare_rollback' "$(hts_namespace "$HTS_DEFAULT_SOCKET")"
  assert_failure
  # After removing every approved codicon glyph, only plain ASCII plus the
  # label separator, ellipsis, and blank-cell padding may remain.
  run jq -e --arg icons "$HTS_ICON_BRANCH$HTS_ICON_WORKTREE$HTS_ICON_COMMIT$HTS_ICON_FOLDER$HTS_ICON_STALE$HTS_GIT_BEHIND$HTS_GIT_AHEAD$HTS_GIT_CONFLICT$HTS_GIT_STAGED$HTS_GIT_UNSTAGED$HTS_GIT_UNTRACKED" '
    [.panes[0].label, .tabs[0].label, .panes[0].tokens.worktree,
     .panes[0].tokens.agent_line, .panes[0].tokens.git_line,
     .panes[0].tokens.git_ref, .panes[0].tokens.git_pull,
     .panes[0].tokens.git_push, .panes[0].tokens.git_conflicts,
     .panes[0].tokens.git_staged, .panes[0].tokens.git_unstaged,
     .panes[0].tokens.git_untracked]
    | all(.[]; (. // "") | explode - ($icons | explode) | implode | test("^[A-Za-z0-9._:/ ~\u00b7\u2026\u2800-]*$"))
  ' "$state"
  assert_success
  assert_equal "$(jq -r '.tabs[0].label' "$state")" plain-task
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_WORKTREE plain"
  assert_equal "$(jq -r '[.panes[0].tokens | .git_pull, .git_push, .git_conflicts, .git_staged, .git_unstaged, .git_untracked] | map(select(. != null)) | join(" ")' "$state")" \
    "${HTS_GIT_BEHIND}4 ${HTS_GIT_AHEAD}3 ${HTS_GIT_CONFLICT}1 ${HTS_GIT_STAGED}1 ${HTS_GIT_UNSTAGED}1 ${HTS_GIT_UNTRACKED}1"
  assert_equal "$(jq -r '.panes[0].tokens.git_status // ""' "$state")" ""
  # pane_inline stays deferred per the label-system plan: no pass publishes it.
  assert_equal "$(jq -r '.panes[0].tokens.pane_inline // ""' "$state")" ""
}

function test_scripts_176_herdr_task_sync_publishes_separator_free_sidebar() {
  _bats_test_init 176 'herdr-task-sync publishes separator-free sidebar lines in display order'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/repo" common="$HTS_WORK/repo.git" state
  mkdir -p "$root/.git" "$common"
  # given: a branch checkout whose status probe reports two changed paths and
  # one commit each way against its upstream
  hts_git_location_fixture "$root" "$root" "$common" refs/heads/topic
  hts_git_status_fixture "$root" "$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
    '# branch.oid 1111111111111111111111111111111111111111' \
    '# branch.head topic' \
    '# branch.upstream origin/topic' \
    '# branch.ab +1 -2' \
    '1 .M N... 100644 100644 100644 1111111 1111111 one.txt' \
    '1 M. N... 100644 100644 100644 2222222 2222222 two.txt')"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hts_set_process_label pane-1 worker

  # when: the location pass runs
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"

  # then: the aggregate lines render in the fixed order without Herdr inserting
  # separators, and the final blank cell keeps the count off the panel border
  assert_equal "$(jq -r '.panes[0].tokens.agent_line' "$state")" "repo worker"
  assert_equal "$(jq -r '.panes[0].tokens.git_line' "$state")" \
    "$HTS_ICON_BRANCH topic $HTS_GIT_BEHIND"'2 '"$HTS_GIT_AHEAD"'1 +1 !1'"$HTS_SIDEBAR_PADDING"
  run jq -e '.panes[0].tokens.git_line | contains("·") | not' "$state"
  assert_success

  # The independent source tokens remain available for other consumers.
  assert_equal "$(jq -r '[.panes[0].tokens | .git_pull, .git_push, .git_staged, .git_unstaged] | map(select(. != null)) | join(" ")' "$state")" \
    "${HTS_GIT_BEHIND}2 ${HTS_GIT_AHEAD}1 ${HTS_GIT_STAGED}1 ${HTS_GIT_UNSTAGED}1"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_BRANCH topic"

  # when: only one new untracked path remains on the next pass
  hts_git_status_fixture "$root" '? later.txt'
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"

  # then: every independently published stale category is cleared
  run jq -e --arg untracked "${HTS_GIT_UNTRACKED}1" '
    .panes[0].tokens
    | (.git_pull == null and .git_push == null and .git_staged == null and
       .git_unstaged == null and .git_untracked == $untracked)
  ' "$state"
  assert_success
}

function test_scripts_177_herdr_task_sync_clean_checkout_carries_no_count() {
  _bats_test_init 177 'herdr-task-sync clean checkout carries no count tokens and republishes when only the counts change'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/repo" common="$HTS_WORK/repo.git" state
  mkdir -p "$root/.git" "$common"
  # given: a branch checkout whose status probe reports nothing at all
  hts_git_location_fixture "$root" "$root" "$common" refs/heads/topic
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hts_set_process_label pane-1 worker

  # when: a clean pass runs
  HERDR_TASK_SYNC_TEST_NOW_SEQ=2000 hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"

  # then: no count tokens are published
  run jq -e '.panes[0].tokens | [.git_pull, .git_push, .git_conflicts, .git_staged, .git_unstaged, .git_untracked] | all(. == null)' "$state"
  assert_success
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_BRANCH topic"
  assert_equal "$(jq -r '.panes[0].tokens.git_line' "$state")" "$HTS_ICON_BRANCH topic$HTS_SIDEBAR_PADDING"

  # when: a file goes dirty and nothing about the identity changes
  hts_git_status_fixture "$root" '1 .M N... 100644 100644 100644 1111111 1111111 one.txt'
  HERDR_TASK_SYNC_TEST_NOW_SEQ=2001 hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"

  # then: the counts-only change still triggers a republish
  assert_equal "$(jq -r '.panes[0].tokens.git_unstaged' "$state")" "${HTS_GIT_UNSTAGED}1"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_BRANCH topic"
  assert_equal "$(jq -r '.panes[0].tokens.git_line' "$state")" "$HTS_ICON_BRANCH topic ${HTS_GIT_UNSTAGED}1$HTS_SIDEBAR_PADDING"
}

function test_scripts_178_herdr_task_sync_separates_conflicts_staged_unsta() {
  _bats_test_init 178 'herdr-task-sync separates conflicts staged unstaged and untracked paths'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/repo" common="$HTS_WORK/repo.git" state
  mkdir -p "$root/.git" "$common"
  # given: one staged path, one unstaged path, one ordinary path that is both,
  # one renamed path that is both, one untracked, and one unmerged path
  hts_git_location_fixture "$root" "$root" "$common" refs/heads/topic
  hts_git_status_fixture "$root" "$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
    '1 M. N... 100644 100644 100644 1111111 1111111 staged.txt' \
    '1 .M N... 100644 100644 100644 2222222 2222222 unstaged.txt' \
    '1 MM N... 100644 100644 100644 3333333 3333333 both.txt' \
    "$(printf '2 MM N... 100644 100644 100644 4444444 4444444 R100 renamed.txt\told.txt')" \
    '? untracked.txt' \
    'u UU N... 100644 100644 100644 100644 1111111 2222222 3333333 conflict.txt')"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hts_set_process_label pane-1 worker

  # when: the location pass runs
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"

  # then: the partially staged path belongs to both actionable categories,
  # while the unmerged path is reported only as a conflict
  assert_equal "$(jq -r '[.panes[0].tokens | .git_conflicts, .git_staged, .git_unstaged, .git_untracked] | map(select(. != null)) | join(" ")' "$state")" \
    "${HTS_GIT_CONFLICT}1 ${HTS_GIT_STAGED}3 ${HTS_GIT_UNSTAGED}3 ${HTS_GIT_UNTRACKED}1"
}

function test_scripts_179_herdr_task_sync_omits_ahead_and_behind_when_the() {
  _bats_test_init 179 'herdr-task-sync omits ahead and behind when the branch has no upstream'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/repo" common="$HTS_WORK/repo.git" state
  mkdir -p "$root/.git" "$common"
  # given: a status probe with no `# branch.ab` line, which is what git emits
  # for a branch that tracks nothing
  hts_git_location_fixture "$root" "$root" "$common" refs/heads/topic
  hts_git_status_fixture "$root" "$(printf '%s\n%s\n%s' \
    '# branch.oid 1111111111111111111111111111111111111111' \
    '# branch.head topic' \
    '1 .M N... 100644 100644 100644 1111111 1111111 one.txt')"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hts_set_process_label pane-1 worker

  # when: the location pass runs
  run hts_location_pass

  # then: the unstaged count stands alone and the pass stays quiet
  assert_success
  refute_output --partial "dropped"
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_unstaged' "$state")" "${HTS_GIT_UNSTAGED}1"
  run jq -e '.panes[0].tokens | (.git_pull == null and .git_push == null)' "$state"
  assert_success
}

function test_scripts_180_herdr_task_sync_clears_the_count_tokens_when_a_p() {
  _bats_test_init 180 'herdr-task-sync clears the count tokens when a pane leaves a Git checkout'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/repo" common="$HTS_WORK/repo.git" plain="$HTS_WORK/plain" state
  mkdir -p "$root/.git" "$common" "$plain"
  # given: a pane that has already published counts
  hts_git_location_fixture "$root" "$root" "$common" refs/heads/topic
  hts_git_status_fixture "$root" '1 .M N... 100644 100644 100644 1111111 1111111 one.txt'
  hts_git_fixture "$plain" "" 1 ready 'fatal: not a git repository'
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hts_set_process_label pane-1 worker
  HERDR_TASK_SYNC_TEST_NOW_SEQ=3000 hts_location_pass
  assert_equal "$(jq -r '.panes[0].tokens.git_unstaged' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" "${HTS_GIT_UNSTAGED}1"

  # when: the pane moves to a directory that is not a checkout
  hts_set_pane_location "$HTS_DEFAULT_SOCKET" pane-1 "$plain" "$plain"
  HERDR_TASK_SYNC_TEST_NOW_SEQ=3001 hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"

  # then: Git counts and metadata clear while the non-Git folder takes over
  run jq -e --arg ref "$HTS_ICON_FOLDER plain" --arg line "$HTS_ICON_FOLDER plain$HTS_SIDEBAR_PADDING" '
    .panes[0].tokens
    | ([.git_pull, .git_push, .git_conflicts, .git_staged, .git_unstaged, .git_untracked] | all(. == null))
      and (.git_ref == $ref and .git_line == $line and .repo == null)
  ' "$state"
  assert_success
}

function test_scripts_181_herdr_task_sync_status_probe_over_budget_drops_t() {
  _bats_test_init 181 'herdr-task-sync status probe over budget drops the count tokens and leaves git_ref intact'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/repo" common="$HTS_WORK/repo.git" fixture state
  mkdir -p "$root/.git" "$common"
  # given: an identity probe that answers in budget and a status probe that
  # does too, so a real count reaches the pane before anything is blocked
  hts_git_location_fixture "$root" "$root" "$common" refs/heads/topic
  hts_git_status_fixture "$root" '1 .M N... 100644 100644 100644 1111111 1111111 one.txt'
  fixture="$(hts_git_fixture_dir "$root")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hts_set_process_label pane-1 worker

  # given: that count is published, so the next assertion has something to lose
  HERDR_TASK_SYNC_TEST_NOW_SEQ=3999 hts_location_pass
  assert_equal "$(jq -r '.panes[0].tokens.git_unstaged' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" "${HTS_GIT_UNSTAGED}1"

  # when: the status probe stalls past its own budget on the next pass
  hts_block_git_status "$root"
  HERDR_TASK_SYNC_TEST_NOW_SEQ=4000 hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"

  # then: identity survives and the published count is cleared, not retained
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_BRANCH topic"
  run jq -e '.panes[0].tokens | [.git_pull, .git_push, .git_conflicts, .git_staged, .git_unstaged, .git_untracked] | all(. == null)' "$state"
  assert_success

  # when: the probe answers again
  : > "$fixture/release"
  HERDR_TASK_SYNC_TEST_NOW_SEQ=4001 hts_location_pass

  # then: the counts appear without manual repair
  assert_equal "$(jq -r '.panes[0].tokens.git_unstaged' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" "${HTS_GIT_UNSTAGED}1"
}

function test_scripts_182_herdr_task_sync_agent_pane_follows_the_directory() {
  _bats_test_init 182 'herdr-task-sync agent pane follows the directory its own statusline reports, not its launch directory'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local launch="$HTS_WORK/repo" worktree="$HTS_WORK/wt-feature" common="$HTS_WORK/repo.git" state
  mkdir -p "$launch/.git" "$worktree" "$common"
  # given: an agent pane launched in the main checkout, and a linked worktree
  # the agent's session will move into
  hts_mark_linked_worktree "$worktree" "$common/worktrees/wt-feature"
  hts_git_location_fixture "$launch" "$launch" "$common" refs/heads/main
  hts_git_location_fixture "$worktree" "$worktree" "$common" refs/heads/feature
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_agent_pane_json pane-1 tab-1 "$launch" claude sess-1)"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'

  # when: no report exists yet
  HERDR_TASK_SYNC_TEST_NOW_SEQ=5000 hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"

  # then: the pane cwd still decides, which is the unchanged fallback
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_BRANCH main"

  # when: the session moves and its own statusline records the new directory,
  # while the pane cwd stays at the launch checkout
  hts_run_claude_statusline "$worktree" sess-1
  HERDR_TASK_SYNC_TEST_NOW_SEQ=5001 hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"

  # then: the row names the worktree the agent actually works in
  assert_equal "$(jq -r '.panes[0].cwd' "$state")" "$launch"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_WORKTREE feature"
  assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" feature
}

function test_scripts_183_herdr_task_sync_keeps_the_counts_when_only_the_i() {
  _bats_test_init 183 'herdr-task-sync keeps the counts when only the identity probe misses its budget'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/repo" common="$HTS_WORK/repo.git" state
  mkdir -p "$root/.git" "$common"
  # given: a checkout whose counts are published from a healthy pass
  hts_git_location_fixture "$root" "$root" "$common" refs/heads/topic
  hts_git_status_fixture "$root" '1 .M N... 100644 100644 100644 1111111 1111111 one.txt'
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hts_set_process_label pane-1 worker
  HERDR_TASK_SYNC_TEST_NOW_SEQ=6000 hts_location_pass
  assert_equal "$(jq -r '.panes[0].tokens.git_unstaged' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" "${HTS_GIT_UNSTAGED}1"

  # when: the identity probe stalls past its budget while the status probe
  # still answers for the retained root
  hts_block_git_location "$root"
  HERDR_TASK_SYNC_TEST_NOW_SEQ=6001 hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"

  # then: the ref is marked stale, and the counts measured this pass survive
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HTS_ICON_BRANCH topic $HTS_ICON_STALE"
  assert_equal "$(jq -r '.panes[0].tokens.git_unstaged' "$state")" "${HTS_GIT_UNSTAGED}1"
}

function test_scripts_184_herdr_task_sync_counts_untracked_paths_its_way_n() {
  _bats_test_init 184 'herdr-task-sync counts untracked paths its way, not the user git config'\''s way'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local root="$HTS_WORK/repo" common="$HTS_WORK/repo.git" fixture
  mkdir -p "$root/.git" "$common"
  # given: an ordinary checkout with one changed path
  hts_git_location_fixture "$root" "$root" "$common" refs/heads/topic
  hts_git_status_fixture "$root" '1 .M N... 100644 100644 100644 1111111 1111111 one.txt'
  fixture="$(hts_git_fixture_dir "$root")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$root")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hts_set_process_label pane-1 worker

  # when: the pass runs
  HERDR_TASK_SYNC_TEST_NOW_SEQ=6100 hts_location_pass

  # then: the probe forced every untracked path to be listed, so no user-level
  # status.showUntrackedFiles setting can silently shrink the count
  assert_equal "$(grep -c -- '--untracked-files=all' "$fixture/calls")" 1
}

function test_scripts_185_herdr_task_sync_writer_and_reader_agree_on_the_r() {
  _bats_test_init 185 'herdr-task-sync writer and reader agree on the record name for an awkward session id'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local launch="$HTS_WORK/repo" worktree="$HTS_WORK/wt-feature" common="$HTS_WORK/repo.git"
  local session='../../escape me' state
  mkdir -p "$launch/.git" "$worktree" "$common"
  # given: a session id carrying separators and spaces, so the filename the
  # reporter writes and the one the daemon reads back are only equal if both
  # transforms still match. They live in three separate files with nothing but
  # this test holding them together, and divergence would fail silently.
  hts_mark_linked_worktree "$worktree" "$common/worktrees/wt-feature"
  hts_git_location_fixture "$launch" "$launch" "$common" refs/heads/main
  hts_git_location_fixture "$worktree" "$worktree" "$common" refs/heads/feature
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_agent_pane_json pane-1 tab-1 "$launch" claude "$session")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'

  # when: the shipped reporter records the move and a pass reads it back
  hts_run_claude_statusline "$worktree" "$session"
  HERDR_TASK_SYNC_TEST_NOW_SEQ=6200 hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"

  # then: the pane followed the report, which only happens when all three
  # copies of the transform agree
  assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" feature

  # then: the separators were flattened, so no record can be written outside
  # the directory that holds them
  assert_equal "$(find "$HTS_STATE/agent-cwd" -type f | wc -l | tr -d ' ')" 1
  assert [ ! -e "$HTS_STATE/escape me" ]
}

function test_scripts_186_herdr_task_sync_falls_back_to_the_pane_cwd_when() {
  _bats_test_init 186 'herdr-task-sync falls back to the pane cwd when the reported directory is gone'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local launch="$HTS_WORK/repo" common="$HTS_WORK/repo.git"
  mkdir -p "$launch/.git" "$common"
  # given: an absolute report naming a worktree that has since been deleted,
  # while the pane's own checkout is still perfectly readable
  hts_git_location_fixture "$launch" "$launch" "$common" refs/heads/main
  hts_write_agent_cwd_record sess-1 "$HTS_WORK/wt-deleted"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_agent_pane_json pane-1 tab-1 "$launch" claude sess-1)"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'

  # when: the pass runs
  run hts_location_pass

  # then: the pane names the checkout it can still see instead of freezing
  assert_success
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" "$HTS_ICON_BRANCH main"
}

function test_scripts_187_herdr_task_sync_ignores_an_agent_directory_repor() {
  _bats_test_init 187 'herdr-task-sync ignores an agent directory report that is not an absolute path'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local launch="$HTS_WORK/repo" common="$HTS_WORK/repo.git"
  mkdir -p "$launch/.git" "$common"
  # given: a report whose body could never name a checkout
  hts_git_location_fixture "$launch" "$launch" "$common" refs/heads/main
  hts_write_agent_cwd_record sess-1 'not-a-path'
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_agent_pane_json pane-1 tab-1 "$launch" claude sess-1)"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'

  # when: the pass runs
  run hts_location_pass

  # then: the pane falls back to its own cwd without noise
  assert_success
  refute_output --partial "dropped"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" "$HTS_ICON_BRANCH main"
}

function test_scripts_188_herdr_task_sync_reads_the_newest_agent_directory() {
  _bats_test_init 188 'herdr-task-sync reads the newest agent directory report when a session moves twice before a sweep'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local launch="$HTS_WORK/repo" first="$HTS_WORK/wt-one" second="$HTS_WORK/wt-two"
  local common="$HTS_WORK/repo.git"
  mkdir -p "$launch/.git" "$first" "$second" "$common"
  # given: two worktrees the session passes through between sweeps
  hts_mark_linked_worktree "$first" "$common/worktrees/wt-one"
  hts_mark_linked_worktree "$second" "$common/worktrees/wt-two"
  hts_git_location_fixture "$launch" "$launch" "$common" refs/heads/main
  hts_git_location_fixture "$first" "$first" "$common" refs/heads/one
  hts_git_location_fixture "$second" "$second" "$common" refs/heads/two
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_agent_pane_json pane-1 tab-1 "$launch" claude sess-1)"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_workspace "$HTS_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'

  # when: both moves are reported before a single pass runs
  hts_run_claude_statusline "$first" sess-1
  hts_run_claude_statusline "$second" sess-1
  hts_location_pass

  # then: the sweep publishes the last reported directory, not the first
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" "$HTS_ICON_WORKTREE two"
}

function test_scripts_189_herdr_task_sync_plugin_exposes_only_the_approved() {
  _bats_test_init 189 'herdr-task-sync plugin exposes only the approved pane, tab, and worktree invalidations'
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
  assert_output $'pane.created|["sh", "ensure.sh", "--event"]\npane.moved|["sh", "ensure.sh", "--event"]\npane.exited|["sh", "ensure.sh", "--event"]\npane.closed|["sh", "ensure.sh", "--event"]\npane.agent_detected|["sh", "ensure.sh", "--event"]\npane.agent_status_changed|["sh", "ensure.sh", "--event"]\ntab.created|["sh", "ensure.sh", "--event"]\ntab.closed|["sh", "ensure.sh", "--event"]\ntab.moved|["sh", "ensure.sh", "--event"]\ntab.renamed|["sh", "ensure.sh", "--event"]\nworktree.created|["sh", "ensure.sh", "--event"]\nworktree.opened|["sh", "ensure.sh", "--event"]'
  assert_file_contains "$manifest" '^min_herdr_version = "0\.8\.0"$'
  assert_file_contains "$manifest" '^id = "sweep"$'
  assert_file_contains "$manifest" '^title = "Pane labels: refresh now"$'
  assert_file_contains "$manifest" '^command = \["sh", "sweep\.sh"\]$'
  run grep -E '^on = ".*\*|^on = "(pane\.updated|workspace\.focused|tab\.focused|pane\.focused)"|reclaim' "$manifest"
  assert_failure
}

function test_scripts_190_herdr_task_sync_plugin_wrappers_invoke_one_engin() {
  _bats_test_init 190 'herdr-task-sync plugin wrappers invoke one engine mode and isolate failures'
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

function test_scripts_191_herdr_task_sync_event_requests_reconciliation_an() {
  _bats_test_init 191 'herdr-task-sync event requests reconciliation and ensures the daemon fail-open'
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

function test_scripts_192_herdr_task_sync_sweep_repairs_an_external_pane_r() {
  _bats_test_init 192 'herdr-task-sync sweep repairs an external pane rename without pane.updated'
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

function test_scripts_193_herdr_task_sync_sweep_repairs_process_and_cwd_ch() {
  _bats_test_init 193 'herdr-task-sync sweep repairs process and CWD changes through the presentation coordinator'
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
  assert_equal "$(jq -r '.panes[0].tokens.agent_line' "$(hts_socket_state "$HTS_DEFAULT_SOCKET")")" btop

  hts_git_location_fixture "$new" "$new" "$common" refs/heads/new-branch
  hts_set_pane_location "$HTS_DEFAULT_SOCKET" pane-1 "$new" "$new"
  hts_set_process_label pane-1 'cargo test'
  : > "$HTS_LOG"
  run hts_sweep_run --sweep
  assert_success

  local state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].label' "$state")" "cargo test"
  assert_equal "$(jq -r '.panes[0].tokens.worktree' "$state")" new-worktree
  assert_equal "$(jq -r '.panes[0].tokens.agent_line' "$state")" "cargo test"
  assert_file_contains "$HTS_LOG" '^api snapshot$'
  assert_file_contains "$HTS_LOG" '^pane rename pane-1 cargo test$'
}

function test_scripts_194_herdr_task_sync_stays_silent_outside_herdr() {
  _bats_test_init 194 'herdr-task-sync stays silent outside herdr'
  hts_setup
  hts_stub_engine pi never-used 0 0
  run env -u HERDR_ENV PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_PANE_ID=pane-1 HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    bash "$HTS_ENGINE" --agent claude --session s1 <<< 'review the cache layer'
  assert_success
  sleep 2
  assert_equal "$(cat "$HTS_LOG")" ""
}

function test_scripts_195_herdr_task_sync_publishes_the_engine_slug_and_st() {
  _bats_test_init 195 'herdr-task-sync publishes the engine slug and stores it (R4, R7)'
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
function test_scripts_196_herdr_task_sync_keeps_the_slug_on_a_continuation() {
  _bats_test_init 196 'herdr-task-sync keeps the slug on a continuation prompt (AE1)'
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
function test_scripts_197_herdr_task_sync_publishes_nothing_when_no_engine() {
  _bats_test_init 197 'herdr-task-sync publishes nothing when no engine is usable (AE3, R5)'
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

function test_scripts_198_herdr_task_sync_resets_the_stored_context_on_a_n() {
  _bats_test_init 198 'herdr-task-sync resets the stored context on a new session id'
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
function test_scripts_199_herdr_task_sync_returns_before_the_naming_engine() {
  _bats_test_init 199 'herdr-task-sync returns before the naming engine finishes (R8)'
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
function test_scripts_200_herdr_task_sync_normalizes_a_hostile_engine_slug() {
  _bats_test_init 200 'herdr-task-sync normalizes a hostile engine slug (KTD8)'
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
function test_scripts_201_herdr_task_sync_exits_under_the_recursion_guard() {
  _bats_test_init 201 'herdr-task-sync exits under the recursion guard (KTD7)'
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
function test_scripts_202_herdr_task_sync_falls_back_to_claude_when_pi_fai() {
  _bats_test_init 202 'herdr-task-sync falls back to claude when pi fails (KTD1)'
  hts_setup
  hts_stub_engine pi '' 1 0
  hts_stub_engine claude flaky-login-test 0 0
  hts_run --agent claude --session s1 <<< 'now fix the flaky login test'
  hts_wait_for_publish
  assert_equal "$(hts_token)" "flaky-login-test"
}

function test_scripts_203_herdr_task_sync_publishes_nothing_when_both_engi() {
  _bats_test_init 203 'herdr-task-sync publishes nothing when both engines time out (KTD1)'
  hts_setup
  hts_stub_engine pi slow-one 0 5
  hts_stub_engine claude slow-two 0 5
  HTS_TIMEOUT=1 hts_run --agent claude --session s1 <<< 'a substantive prompt here'
  sleep 6
  assert_equal "$(cat "$HTS_LOG")" ""
}

function test_scripts_204_herdr_task_sync_creates_its_state_directory_with() {
  _bats_test_init 204 'herdr-task-sync creates its state directory with mode 700 (KTD3)'
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
function test_scripts_205_herdr_task_sync_names_a_session_from_its_transcr() {
  _bats_test_init 205 'herdr-task-sync names a session from its transcript (AE5)'
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

function test_scripts_206_herdr_task_sync_publishes_nothing_for_an_empty_p() {
  _bats_test_init 206 'herdr-task-sync publishes nothing for an empty prompt without a transcript'
  hts_setup
  hts_stub_engine pi never-used 0 0
  run hts_run --agent claude --session s1 < /dev/null
  assert_success
  sleep 2
  assert_equal "$(cat "$HTS_LOG")" ""
}

# AE6: the pi session-name seed path publishes without a model call.
function test_scripts_207_herdr_task_sync_set_publishes_a_normalized_name() {
  _bats_test_init 207 'herdr-task-sync --set publishes a normalized name with no engine call (AE6)'
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
function test_scripts_208_herdr_task_sync_names_the_pane_with_the_agent_pr() {
  _bats_test_init 208 'herdr-task-sync names the pane with the agent prefix'
  hts_setup
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_call 'pane rename'
  assert_equal "$(hts_pane_label)" "cc:cache-review"
}

# An agent outside the known set still gets a readable label: its first letter.
function test_scripts_209_herdr_task_sync_falls_back_to_a_letter_prefix_fo() {
  _bats_test_init 209 'herdr-task-sync falls back to a letter prefix for an unknown agent'
  hts_setup
  hts_stub_engine pi cache-review 0 0
  hts_run --agent aider --session s1 <<< 'review the cache layer please'
  hts_wait_for_call 'pane rename'
  assert_equal "$(hts_pane_label)" "a:cache-review"
}

# Herdr keeps one label per tab and composes nothing itself. The engine joins
# normalized labels for the tab's own agent panes; another tab's panes stay out.
function test_scripts_210_herdr_task_sync_rebuilds_the_tab_label_from_the() {
  _bats_test_init 210 'herdr-task-sync rebuilds the tab label from the pane labels'
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
function test_scripts_211_herdr_task_sync_names_a_command_pane_after_the_p() {
  _bats_test_init 211 'herdr-task-sync names a command pane after the process group leader'
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
function test_scripts_212_herdr_task_sync_names_an_idle_pane_with_the_plac() {
  _bats_test_init 212 'herdr-task-sync names an idle pane with the placeholder'
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
function test_scripts_213_herdr_task_sync_presentation_numbers_an_all_idle() {
  _bats_test_init 213 'herdr-task-sync presentation numbers an all-idle tab'
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
function test_scripts_214_herdr_task_sync_truncates_a_long_command_name() {
  _bats_test_init 214 'herdr-task-sync truncates a long command name'
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
function test_scripts_215_herdr_task_sync_sweep_relabels_every_tab() {
  _bats_test_init 215 'herdr-task-sync --sweep relabels every tab'
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
function test_scripts_216_herdr_task_sync_sweep_leaves_an_unchanged_tab_la() {
  _bats_test_init 216 'herdr-task-sync --sweep leaves an unchanged tab label alone'
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
function test_scripts_217_herdr_task_sync_sweep_numbers_all_idle_tabs_per() {
  _bats_test_init 217 'herdr-task-sync --sweep numbers all-idle tabs per workspace'
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
function test_scripts_218_herdr_task_sync_ensure_daemon_keeps_a_single_dae() {
  _bats_test_init 218 'herdr-task-sync --ensure-daemon keeps a single daemon'
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
function test_scripts_219_herdr_task_sync_ensure_daemon_replaces_a_dead_da() {
  _bats_test_init 219 'herdr-task-sync --ensure-daemon replaces a dead daemon'
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

function test_scripts_220_herdr_task_sync_restart_daemon_replaces_a_live_d() {
  _bats_test_init 220 'herdr-task-sync --restart-daemon replaces a live daemon'
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

function test_scripts_221_herdr_task_sync_restart_daemon_refuses_an_unrela() {
  _bats_test_init 221 'herdr-task-sync --restart-daemon refuses an unrelated lock owner'
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

function test_scripts_222_herdr_task_sync_sweep_daemon_exits_after_three_u() {
  _bats_test_init 222 'herdr-task-sync sweep daemon exits after three unreachable snapshots'
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
function test_scripts_223_herdr_task_sync_hook_stays_silent_and_publishes() {
  _bats_test_init 223 'herdr-task-sync hook stays silent and publishes nothing outside herdr'
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

function test_scripts_224_herdr_task_sync_hook_writes_nothing_to_stdout_wh() {
  _bats_test_init 224 'herdr-task-sync hook writes nothing to stdout when the engine runs'
  command -v jq >/dev/null || skip "jq not available"
  hts_hook_setup
  run hts_hook_run prompt <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"s1","transcript_path":"/tmp/none.jsonl","prompt":"review the cache layer"}
EOF
  assert_success
  assert_output ""
}

function test_scripts_225_herdr_task_sync_hook_forwards_the_prompt_session() {
  _bats_test_init 225 'herdr-task-sync hook forwards the prompt, session, and transcript'
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
function test_scripts_226_herdr_task_sync_hook_calls_transcript_mode_on_se() {
  _bats_test_init 226 'herdr-task-sync hook calls transcript mode on session start and compact'
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
function test_scripts_227_herdr_task_sync_hook_drops_subagent_traffic_r3() {
  _bats_test_init 227 'herdr-task-sync hook drops subagent traffic (R3)'
  command -v jq >/dev/null || skip "jq not available"
  hts_hook_setup
  run hts_hook_run prompt <<'EOF'
{"hook_event_name":"UserPromptSubmit","session_id":"s1","agent_id":"agent-abc123","transcript_path":"/tmp/t.jsonl","prompt":"subagent prompt"}
EOF
  assert_success
  assert_file_not_exists "$HTS_WORK/engine.log"
}

function test_scripts_228_herdr_task_sync_hook_survives_malformed_stdin() {
  _bats_test_init 228 'herdr-task-sync hook survives malformed stdin'
  hts_hook_setup
  run hts_hook_run prompt <<< 'not json at all'
  assert_success
  assert_output ""
}

function test_scripts_229_se_pipeline_setup_cmd_lands_in_the_workflow_inpu() {
  _bats_test_init 229 'se pipeline --setup-cmd lands in the workflow input JSON'
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local plan
  plan="$BATS_TEST_TMPDIR/se-dryrun-plan.md"
  printf -- '---\nartifact_contract: ce-unified-plan/v1\n---\n# t\n' > "$plan"
  run env SE_DRY_RUN=1 "$se_bin" pipeline "$plan" --setup-cmd 'bun install && bunx turbo run build --filter=@x/y'
  assert_success
  assert_output --partial '"setupCmd":"bun install && bunx turbo run build --filter=@x/y"'
}

function test_scripts_230_se_flow_dry_run_lands_spec_path_budget_and_setup() {
  _bats_test_init 230 'se flow --dry-run lands spec path, budget, and setup-cmd in the workflow input JSON'
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

function test_scripts_231_se_flow_validate_cmd_lands_the_operator_s_comman() {
  _bats_test_init 231 'se flow --validate-cmd lands the operator'\''s command in the workflow input JSON'
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

function test_scripts_232_se_flow_without_validate_cmd_sends_an_empty_comm() {
  _bats_test_init 232 'se flow without --validate-cmd sends an empty command, not a missing key'
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local spec
  spec="$BATS_TEST_TMPDIR/se-flow-spec.json"
  printf '{"task":{"description":"x"},"repo":"/tmp/r","blocks":[{"id":"scan","block":"secret-scan","retries":0,"timeoutMs":120000}]}' > "$spec"
  run env "$se_bin" flow "$spec" --dry-run
  assert_success
  assert_output --partial '"validateCmd":""'
}

function test_scripts_233_se_flow_dry_run_prints_the_composed_flow_with_a() {
  _bats_test_init 233 'se flow --dry-run prints the composed flow with a cost estimate (R10)'
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

function test_scripts_234_se_flow_refuses_a_spec_the_validator_rejects_bef() {
  _bats_test_init 234 'se flow refuses a spec the validator rejects, before launching'
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

function test_scripts_235_se_flow_rejects_a_non_numeric_budget() {
  _bats_test_init 235 'se flow rejects a non-numeric budget'
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

function test_scripts_236_se_show_prints_the_pending_approval_s_title_and() {
  _bats_test_init 236 'se show prints the pending approval'\''s title and reasons, not just a status word'
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

function test_scripts_237_se_approve_prints_what_is_being_decided_before_r() {
  _bats_test_init 237 'se approve prints what is being decided before recording the decision'
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 is required"
  command -v jq >/dev/null 2>&1 || skip "jq is required"
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local dir
  dir="$(se_fake_runtime 'work failed the extra attempt — abort only: approve stops the run WITH a report' 'no content change')"

  run env SE_SMITHERS_DIR="$dir" "$se_bin" approve run-1

  # The operator must see that approve STOPS this run rather than continuing it.
  assert_output --partial 'approve stops the run WITH a report'
}

function test_scripts_238_se_show_on_a_run_with_no_pending_approval_prints() {
  _bats_test_init 238 'se show on a run with no pending approval prints no decision block'
  command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 is required"
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local dir
  dir="$(se_fake_runtime 'unused' 'unused')"
  sqlite3 "$dir/smithers.db" "UPDATE _smithers_approvals SET status='approved';"

  run env SE_SMITHERS_DIR="$dir" "$se_bin" show run-1

  assert_success
  refute_output --partial 'DECISION REQUIRED'
}

function test_scripts_239_se_approve_resumes_a_parked_run_that_nothing_is() {
  _bats_test_init 239 'se approve resumes a parked run that nothing is driving'
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

function test_scripts_240_se_approve_no_resume_records_the_decision_withou() {
  _bats_test_init 240 'se approve --no-resume records the decision without driving the run'
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

function test_scripts_241_se_approve_refuses_to_resume_a_run_a_live_proces() {
  _bats_test_init 241 'se approve refuses to resume a run a live process already owns'
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

function test_scripts_242_se_approve_does_not_resume_a_run_that_already_fi() {
  _bats_test_init 242 'se approve does not resume a run that already finished'
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

function test_scripts_243_se_approve_usage_does_not_promise_that_approve_c() {
  _bats_test_init 243 'se approve usage does not promise that approve continues the run'
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  run env "$se_bin" --help
  assert_success
  refute_output --partial 'approve a paused run (continue past the gate)'
  assert_output --partial 'ONE more attempt'
}

function test_scripts_244_se_blocks_json_emits_the_composable_block_catalo() {
  _bats_test_init 244 'se blocks --json emits the composable block catalog'
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
  _bats_test_init 250 'Pi settings modifier selects the terminal theme and exact extension packages'
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

function test_scripts_251_pi_settings_modifier_is_idempotent() {
  _bats_test_init 251 'Pi settings modifier is idempotent'
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

function test_scripts_252_pi_terminal_theme_uses_only_terminal_palette_col() {
  _bats_test_init 252 'Pi terminal theme uses only terminal palette colors'
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

function test_scripts_253_claude_code_daltonized_theme_extends_light_ansi() {
  _bats_test_init 253 'Claude Code daltonized theme extends light ANSI with terminal colors'
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
  assert_output --partial "Passed: herdr-child detached watcher closes launcher descriptors"
}

# Guards docs/issues/2026-08-29-001: hts_teardown must terminate and await a
# still-running engine before removing state. The contract is causal, so the
# assertion is process death, with the directory's settled absence as the
# observable effect.
function test_scripts_259_hts_teardown_reaps_a_surviving_engine_worker() {
  _bats_test_init 259 'hts_teardown reaps a surviving engine worker before removing state'
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # The model stub blocks until a release that never comes, pinning the worker
  # mid-task through teardown. The stub creates its own fixture dir, so no
  # canned stdout/status is needed for a call that is never released.
  hts_stub_controlled_engine pi

  hts_run --agent claude --session reap-s <<< 'reap request'
  hts_wait_for_file "$HTS_WORK/models/pi/1/started" || fail "worker never reached its model call"
  local engine_pid work="$HTS_WORK"
  engine_pid="$(hts_record_number \
    "$(hts_pane_state_dir "$HTS_DEFAULT_SOCKET" pane-1)/worker.claim/owner" pid)"
  # Control: prove a live engine was observed, not startup or cleanup noise.
  [[ -n "$engine_pid" ]] || fail "worker claim published no pid"
  kill -0 "$engine_pid" 2>/dev/null || fail "worker was not alive at teardown time"

  hts_teardown

  run kill -0 "$engine_pid"
  assert_failure
  [[ ! -e "$work" ]] || fail "teardown left $work behind"
  # A survivor recreates state within its first claim window; a settled check
  # distinguishes real removal from a removal about to be raced.
  sleep 0.3
  [[ ! -e "$work" ]] || fail "an engine process resurrected $work after teardown"
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function tear_down() { _bats_run_teardown; }

