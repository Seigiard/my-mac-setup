#!/usr/bin/env bats

load 'helpers/common'

setup() {
  unset HERDR_CHILD_NAME
  unset HERDR_CHILD_PARENT_PANE
}

teardown() {
  [[ -n "${BATS_TEST_TMPFILE:-}" ]] && rm -f "$BATS_TEST_TMPFILE" || true
  [[ -n "${HTS_WORK:-}" ]] && rm -rf "$HTS_WORK" || true
  [[ -n "${CHILD_STUB:-}" ]] && rm -rf "$CHILD_STUB" || true
}

# ===========================================
# Repository linting
# ===========================================

@test "shellcheck is managed by the cross-platform Brewfile" {
  assert_file_contains "$SOURCE_ROOT/private_dot_config/brewfiles/Brewfile.tmpl" '^brew "shellcheck"'
}

# Docker mounts only home/ and tests/, so the repo-root Makefile is absent there.
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
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" --source "$SOURCE_ROOT" execute-template \
    < "$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl"
}

@test "install-packages script renders as valid bash" {
  skip_if_no_chezmoi
  local script="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl"
  [[ -f "$script" ]] || skip "install-packages script not found at $script"

  BATS_TEST_TMPFILE="$(mktemp /tmp/install-packages-XXXXXX.sh)"
  render_install_packages > "$BATS_TEST_TMPFILE"
  run bash -n "$BATS_TEST_TMPFILE"
  assert_success
}

@test "install-packages template has no rendering errors" {
  skip_if_no_chezmoi
  local script="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl"
  [[ -f "$script" ]] || skip "install-packages script not found at $script"
  run render_install_packages
  assert_success
}

# ===========================================
# macOS tunes script
# ===========================================

@test "macos-tunes script exists in darwin-specific directory" {
  assert_file_exists "$SOURCE_ROOT/.chezmoiscripts/darwin/run_once_after_macos-tunes.sh"
}

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
  "pane get")
    if [ "${STUB_WAITING_LABEL:-0}" = 1 ]; then
      printf '{"result":{"pane":{"state_labels":{"blocked":"waiting for parent"}}}}\n'
    else printf '{"result":{"pane":{}}}\n'; fi ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$CHILD_STUB/herdr-child" "$CHILD_STUB/herdr"
}

@test "ask-in-herdr script is valid bash and requires arguments" {
  run bash -n "$ASK_HERDR_DIR/ask.sh"
  assert_success
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
  assert_output --partial "close with: herdr-child reap consult-claude-"
  assert_output --partial "ask.sh: status=answered"
  run grep -E -- '^start --kind claude --name consult-claude-[0-9]+ --posture ro ' "$CHILD_STUB/child.log"
  assert_success
  run grep -E -- '--prompt-file .* --wait --timeout 1800000' "$CHILD_STUB/child.log"
  assert_success
  run grep -E -- '^agent read consult-claude-[0-9]+ --source visible --lines 200' "$CHILD_STUB/herdr.log"
  assert_success
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

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_WAITING_LABEL=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" pi question --rw
  assert_failure 1
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=blocked"
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
    bash "$HERDR_CHILD" reap idle-a
  assert_success
  assert_output --partial "idle-a: closed pane wT:p1"
  run grep -c '^pane close wT:p1' "$CHILD_STUB/calls.log"
  assert_output 1
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

# One dead verb (`herdr wait output`, which herdr spells `herdr pane wait-output`) cost a
# whole broken mode for six weeks. Every herdr command a skill script runs is checked
# here: its group against the allowlist always, and the full command against the installed
# binary when there is one — CI has no herdr, a dev machine does. Scope includes skill
# scripts and the shared launch executable, where the surviving herdr calls are concentrated.
@test "skill scripts call only herdr commands that exist" {
  local groups='agent|api|channel|completion|config|integration|notification|pane|plugin|session|tab|workspace|worktree|status|update|server'
  local calls bad="" grp cmd
  # Comment lines out, then command position only: line start, or after a pipe, `;`,
  # `&&`, `(`, backtick or `$(` — prose about herdr must not read as a call.
  calls="$({ grep -rh --include='*.sh' -E 'herdr' "$SOURCE_ROOT/private_dot_claude/skills"; \
      grep -h -E 'herdr' "$HERDR_CHILD"; } \
    | grep -vE '^[[:space:]]*#' \
    | grep -oE '(^|[|;&(`]|\$\()[[:space:]]*herdr [a-z][a-z-]*( [a-z][a-z-]*)?' \
    | sed 's/.*herdr //' | sort -u)"
  while read -r grp cmd; do
    [ -n "$grp" ] || continue
    if ! printf '%s' "$grp" | grep -qE "^($groups)\$"; then
      bad="$bad herdr:$grp:$cmd"; continue
    fi
    if command -v herdr >/dev/null && [ -n "$cmd" ]; then
      herdr "$grp" "$cmd" --help >/dev/null 2>&1 || bad="$bad herdr:$grp:$cmd"
    fi
  done <<< "$calls"
  [ -z "$bad" ] || fail "skill scripts call herdr commands that do not exist:$bad"
}

# ===========================================
# herdr-integrations run-script
# ===========================================

HERDR_INTEGRATIONS_TMPL="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_3-setup-herdr-integrations.sh.tmpl"

@test "herdr-integrations script renders to valid bash" {
  skip_if_no_chezmoi
  [[ -f "$HERDR_INTEGRATIONS_TMPL" ]] || skip "herdr-integrations script not found"
  BATS_TEST_TMPFILE="$(mktemp /tmp/herdr-integrations-XXXXXX.sh)"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" execute-template < "$HERDR_INTEGRATIONS_TMPL" > "$BATS_TEST_TMPFILE"
  run bash -n "$BATS_TEST_TMPFILE"
  assert_success
}

@test "herdr-integrations script guards on command -v herdr and stays tolerant" {
  run grep -q "command -v herdr" "$HERDR_INTEGRATIONS_TMPL"
  assert_success
  run grep -q 'for target in claude pi opencode' "$HERDR_INTEGRATIONS_TMPL"
  assert_success
}

@test "herdr-integrations version trigger is lookPath-guarded so CI without herdr still renders" {
  run grep -q 'lookPath "herdr"' "$HERDR_INTEGRATIONS_TMPL"
  assert_success
}

@test "herdr-integrations script exits 0 and skips when herdr is absent" {
  skip_if_no_chezmoi
  [[ -f "$HERDR_INTEGRATIONS_TMPL" ]] || skip "herdr-integrations script not found"
  BATS_TEST_TMPFILE="$(mktemp /tmp/herdr-integrations-XXXXXX.sh)"
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

@test "PreToolUse hook scripts are valid bash" {
  run bash -n "$FFF_GUARD"
  assert_success
  run bash -n "$WEBFETCH_HINT"
  assert_success
}

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
  BATS_TEST_TMPFILE="$(mktemp /tmp/claude-settings-XXXXXX.json)"
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

HTS_ENGINE="$SOURCE_ROOT/dot_local/bin/executable_herdr-task-sync"
HTS_PLUGIN_DIR="$SOURCE_ROOT/private_dot_config/herdr/plugins/herdr-pane-labels"

# Build a sandbox with a stub `herdr` that records its argv. PATH is pinned to
# the stub directory plus the system directories, so a real `pi` or `claude`
# outside them can never be reached: a missing engine is then a property of the
# test, not of the machine that runs it.
# Codicon glyphs of the $git_ref grammar. The octal UTF-8 table lives once, in
# the engine; retyping it here would let an engine codepoint change pass while
# the suite still asserted the old bytes. Raw PUA glyphs must never be pasted
# into either file, so the sequences are read out and re-expanded.
hts_icon() {
  local octal
  octal="$(sed -n "s/^ICON_$1=\"\\\$(printf '\\([^']*\\)')\".*/\\1/p" "$HTS_ENGINE")"
  [ -n "$octal" ] || { printf 'missing ICON_%s in %s\n' "$1" "$HTS_ENGINE" >&2; return 1; }
  # shellcheck disable=SC2059  # the format string is the engine's own octal table
  printf "$octal"
}
HTS_ICON_BRANCH="$(hts_icon BRANCH)"     # nf-cod-git_branch U+EC6F
HTS_ICON_WORKTREE="$(hts_icon WORKTREE)" # nf-cod-worktree U+EC7E
HTS_ICON_COMMIT="$(hts_icon COMMIT)"     # nf-cod-git_commit U+EAFC
HTS_ICON_FOLDER="$(hts_icon FOLDER)"     # nf-cod-folder U+EA83
HTS_ICON_STALE="$(hts_icon STALE)"       # nf-cod-history U+EA82

hts_setup() {
  HTS_WORK="$(mktemp -d "${BATS_TMPDIR:-/tmp}/hts.XXXXXX")"
  HTS_STUB="$HTS_WORK/stub"
  HTS_STATE="$HTS_WORK/state"
  HTS_LOG="$HTS_WORK/herdr.log"
  HTS_DEFAULT_SOCKET="$HTS_WORK/session.sock"
  HTS_SOCKET_ROOT="$HTS_WORK/sockets"
  export HTS_WORK HTS_DEFAULT_SOCKET HTS_SOCKET_ROOT
  export HERDR_SOCKET_PATH="$HTS_DEFAULT_SOCKET"
  mkdir -p "$HTS_STUB" "$HTS_STATE" "$HTS_SOCKET_ROOT/socket-1"
  : > "$HTS_LOG"
  printf '%s' "$HTS_DEFAULT_SOCKET" > "$HTS_SOCKET_ROOT/socket-1/socket-path"
  printf '%s' "$HTS_LOG" > "$HTS_SOCKET_ROOT/socket-1/log-path"
  printf '%s' 2 > "$HTS_SOCKET_ROOT/next-id"
  hts_init_socket_dir "$HTS_SOCKET_ROOT/socket-1"

  # The mutable fixture uses exact socket paths as identities. Numeric storage
  # directories avoid the collision caused by replacing punctuation in names.
  cat > "$HTS_WORK/fixture-lib.sh" <<'SH'
hts_fixture_init_dir() {
  mkdir -p "$1/calls" "$1/completions" "$1/locks" "$1/after"
  [ -f "$1/state.json" ] || printf '%s\n' \
    '{"complete":true,"protocol":19,"panes":[],"tabs":[],"agents":[],"layouts":[],"workspaces":[],"metadata":{}}' \
    > "$1/state.json"
  [ -f "$1/call-seq" ] || printf '%s' 0 > "$1/call-seq"
  [ -f "$1/herdr.log" ] || : > "$1/herdr.log"
}

hts_fixture_socket_dir() {
  local socket_path="${1:-${HERDR_SOCKET_PATH:-$HTS_DEFAULT_SOCKET}}"
  local dir id lock="$HTS_SOCKET_ROOT/registry.lock" attempts=0
  [ -d "$HTS_SOCKET_ROOT" ] || return 1
  while ! mkdir "$lock" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ -d "$HTS_SOCKET_ROOT" ] && [ "$attempts" -lt 1000 ] || return 1
    sleep 0.01
  done
  for dir in "$HTS_SOCKET_ROOT"/socket-*; do
    [ -d "$dir" ] || continue
    if [ -f "$dir/socket-path" ] && [ "$(cat "$dir/socket-path")" = "$socket_path" ]; then
      rmdir "$lock"
      printf '%s\n' "$dir"
      return 0
    fi
  done
  id="$(cat "$HTS_SOCKET_ROOT/next-id")"
  printf '%s' $((id + 1)) > "$HTS_SOCKET_ROOT/next-id"
  dir="$HTS_SOCKET_ROOT/socket-$id"
  mkdir -p "$dir"
  printf '%s' "$socket_path" > "$dir/socket-path"
  hts_fixture_init_dir "$dir"
  rmdir "$lock"
  printf '%s\n' "$dir"
}

hts_fixture_log() {
  if [ -f "$1/log-path" ]; then
    cat "$1/log-path"
  else
    printf '%s/herdr.log\n' "$1"
  fi
}

hts_fixture_next_call() {
  local dir="$1" lock="$1/locks/call-seq" seq attempts=0
  [ -d "$dir/locks" ] || return 1
  while ! mkdir "$lock" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ -d "$dir/locks" ] && [ "$attempts" -lt 1000 ] || return 1
    sleep 0.01
  done
  seq=$(( $(cat "$dir/call-seq") + 1 ))
  printf '%s' "$seq" > "$dir/call-seq"
  rmdir "$lock"
  printf '%s\n' "$seq"
}

hts_fixture_state_lock() {
  local attempts=0
  [ -d "$1/locks" ] || return 1
  while ! mkdir "$1/locks/state" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ -d "$1/locks" ] && [ "$attempts" -lt 1000 ] || return 1
    sleep 0.01
  done
}

hts_fixture_state_unlock() {
  rmdir "$1/locks/state"
}
SH

  # Every read is generated from current state. Rename and metadata calls
  # mutate that state before their exact per-socket completion marker appears.
  cat > "$HTS_STUB/herdr" <<'SH'
#!/usr/bin/env bash
source "$HTS_WORK/fixture-lib.sh"
if [ -f "$HTS_WORK/block-herdr" ]; then
  block_attempts=0
  release_file="${HTS_DESCRIPTOR_RELEASE_FILE:-$HTS_WORK/release-herdr}"
  : > "$HTS_WORK/herdr-blocked"
  while [ ! -f "$release_file" ]; do
    block_attempts=$((block_attempts + 1))
    [ "$block_attempts" -lt 3000 ] || exit 124
    sleep 0.01
  done
fi
dir="$(hts_fixture_socket_dir)" || exit 1
log="$(hts_fixture_log "$dir")"
call="$*"
seq="$(hts_fixture_next_call "$dir")" || exit 1
printf '%s\n' "$call" >> "$log"
printf '%s\n' "$call" > "$dir/calls/$seq"

finish_call() {
  if [ -f "$dir/after/$seq.json" ]; then
    hts_fixture_state_lock "$dir" || return
    cp "$dir/after/$seq.json" "$dir/state.json"
    hts_fixture_state_unlock "$dir"
  fi
  if [ -f "$dir/after/$seq.sh" ]; then
    bash "$dir/after/$seq.sh"
  fi
  : > "$dir/completions/$seq"
}
trap finish_call EXIT

state="$dir/state.json"
if [ "$1" = "pane" ] && [ "$2" = "list" ]; then
  jq -c '{id:"cli:pane:list",result:{panes:.panes,type:"pane_list"}}' "$state"
elif [ "$1" = "pane" ] && [ "$2" = "get" ]; then
  pane="$(jq -c --arg id "$3" '.panes[] | select(.pane_id == $id)' "$state")"
  [ -n "$pane" ] || exit 1
  jq -cn --argjson pane "$pane" '{id:"cli:pane:get",result:{pane:$pane,type:"pane_info"}}'
elif [ "$1" = "pane" ] && [ "$2" = "process-info" ]; then
  cat "$dir/proc-${4:-$3}.json" 2>/dev/null
elif [ "$1" = "tab" ] && [ "$2" = "list" ]; then
  jq -c '{id:"cli:tab:list",result:{tabs:.tabs,type:"tab_list"}}' "$state"
elif [ "$1" = "tab" ] && [ "$2" = "get" ]; then
  tab="$(jq -c --arg id "$3" '.tabs[] | select(.tab_id == $id)' "$state")"
  [ -n "$tab" ] || exit 1
  jq -cn --argjson tab "$tab" '{id:"cli:tab:get",result:{tab:$tab,type:"tab_info"}}'
elif [ "$1" = "api" ] && [ "$2" = "snapshot" ]; then
  [ ! -f "$dir/fail-snapshot" ] || exit 1
  if [ -f "$dir/fail-next-snapshot" ]; then
    rm -f "$dir/fail-next-snapshot"
    exit 1
  fi
  if [ "$(jq -r '.complete' "$state")" = "true" ]; then
    jq -c '{id:"cli:api:snapshot",result:{snapshot:{protocol:.protocol,panes:.panes,tabs:.tabs,agents:.agents,layouts:.layouts,workspaces:.workspaces},type:"session_snapshot"}}' "$state"
  else
    jq -c '{id:"cli:api:snapshot",result:{snapshot:{protocol:.protocol,panes:.panes},type:"session_snapshot"}}' "$state"
  fi
elif [ "$1" = "pane" ] && [ "$2" = "rename" ]; then
  tmp="$state.tmp.$$"
  hts_fixture_state_lock "$dir" || exit 1
  jq --arg id "$3" --arg label "$4" \
    '.panes |= map(if .pane_id == $id then .label = $label else . end)' \
    "$state" > "$tmp" && mv "$tmp" "$state"
  result=$?
  hts_fixture_state_unlock "$dir"
  [ "$result" -eq 0 ] || exit "$result"
elif [ "$1" = "tab" ] && [ "$2" = "rename" ]; then
  tmp="$state.tmp.$$"
  hts_fixture_state_lock "$dir" || exit 1
  jq --arg id "$3" --arg label "$4" \
    '.tabs |= map(if .tab_id == $id then .label = $label else . end)' \
    "$state" > "$tmp" && mv "$tmp" "$state"
  result=$?
  hts_fixture_state_unlock "$dir"
  [ "$result" -eq 0 ] || exit "$result"
elif [ "$1" = "pane" ] && [ "$2" = "report-metadata" ]; then
  shift 2
  source_id= pane_id= report_seq= tokens='{}' clear_tokens='[]'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) source_id="$2"; shift 2 ;;
      --seq) report_seq="$2"; shift 2 ;;
      --token) tokens="$(jq -c --arg pair "$2" '. + {($pair | split("=")[0]): ($pair | split("=")[1:] | join("="))}' <<< "$tokens")"; shift 2 ;;
      --clear-token) clear_tokens="$(jq -c --arg name "$2" '. + [$name]' <<< "$clear_tokens")"; shift 2 ;;
      --*) shift 2 ;;
      *) pane_id="$1"; shift ;;
    esac
  done
  [ -n "$source_id" ] && [ -n "$pane_id" ] || exit 2
  [ -n "$report_seq" ] || report_seq=0
  tmp="$state.tmp.$$"
  hts_fixture_state_lock "$dir" || exit 1
  jq --arg pane "$pane_id" --arg source "$source_id" --argjson seq "$report_seq" \
    --argjson tokens "$tokens" --argjson clears "$clear_tokens" '
      (.metadata[$pane][$source].seq // -1) as $current
      | if $seq < $current then . else
          .metadata[$pane][$source].seq = $seq
          | .metadata[$pane][$source].tokens = ((.metadata[$pane][$source].tokens // {}) + $tokens | with_entries(select(.key as $key | $clears | index($key) | not)))
          | (.metadata[$pane] // {} | [.[] | .tokens // {}] | add // {}) as $merged
          | .panes |= map(if .pane_id == $pane then
              .tokens = ((reduce $clears[] as $key ((.tokens // {}); del(.[$key]))) + $merged)
            else . end)
        end' "$state" > "$tmp" && mv "$tmp" "$state"
  result=$?
  hts_fixture_state_unlock "$dir"
  [ "$result" -eq 0 ] || exit "$result"
fi
SH
  chmod +x "$HTS_STUB/herdr"

  # A controlled model call blocks on its own release marker. Tests can finish
  # generation 2 before generation 1 and wait for either completion exactly.
  cat > "$HTS_WORK/model-stub" <<'SH'
#!/usr/bin/env bash
set -e
name="$(basename "$0")"
root="$HTS_WORK/models/$name"
lock="$root/allocate.lock"
mkdir -p "$root"
while ! mkdir "$lock" 2>/dev/null; do sleep 0.01; done
call=$(( $(cat "$root/next" 2>/dev/null || printf '%s' 0) + 1 ))
printf '%s' "$call" > "$root/next"
rmdir "$lock"
fixture="$root/$call"
mkdir -p "$fixture"
cat > "$fixture/stdin"
: > "$fixture/started"
for _ in $(seq 1 1000); do
  [ -e "$fixture/release" ] && break
  sleep 0.01
done
[ -e "$fixture/release" ] || exit 124
cat "$fixture/stdout" 2>/dev/null || true
status="$(cat "$fixture/status" 2>/dev/null || printf '%s' 0)"
: > "$fixture/completed"
exit "$status"
SH
  chmod +x "$HTS_WORK/model-stub"

  # Git fixtures are selected by exact CWD. A blocked target lets an actual
  # 75 ms watchdog expire while seven independent probes complete normally.
  cat > "$HTS_STUB/git" <<'SH'
#!/usr/bin/env bash
cwd= command_args="$*"
if [ "$1" = "-C" ]; then
  cwd="$2"
  shift 2
elif [ "${1#--git-dir=}" != "$1" ]; then
  cwd="gitdir:${1#--git-dir=}"
  shift
elif [ "$1" = "--git-dir" ]; then
  cwd="gitdir:$2"
  shift 2
fi
fixture="$(awk -F "$(printf '\037')" -v cwd="$cwd" '$1 == cwd { print $2; exit }' "$HTS_WORK/git-fixtures/registry" 2>/dev/null)"
if [ -d "$fixture" ]; then
  printf '%s\n' "$command_args" >> "$fixture/calls"
  printf '%s' "${LC_ALL:-}" > "$fixture/locale"
  : > "$fixture/started"
  mkdir -p "$HTS_WORK/git-started"
  : > "$HTS_WORK/git-started/${fixture##*/}"
  if [ -n "${HTS_GIT_PROBE_ID:-}" ]; then
    : > "$HTS_WORK/git-started/$HTS_GIT_PROBE_ID"
  fi
  if [ -f "$fixture/block" ]; then
    while [ ! -f "$fixture/release" ]; do sleep 0.01; done
  fi
  # block.short stalls only the second (--short=7) probe of a detached-HEAD
  # resolve, so the first probe of the same fixture still answers in budget.
  case "$command_args" in
    *"--short=7"*)
      if [ -f "$fixture/block.short" ]; then
        while [ ! -f "$fixture/release" ]; do sleep 0.01; done
      fi
      ;;
  esac
  : > "$fixture/completed"
  cat "$fixture/stderr" >&2
  out="$fixture/stdout"
  case "$command_args" in
    *"--short=7"*) [ ! -f "$fixture/stdout.short" ] || out="$fixture/stdout.short" ;;
  esac
  cat "$out"
  exit "$(cat "$fixture/status")"
fi
exit 1
SH
  chmod +x "$HTS_STUB/git"
  "$HTS_STUB/git" --version >/dev/null 2>&1 || true

  cat > "$HTS_STUB/hts-crash-worker" <<'SH'
#!/usr/bin/env bash
set -e
state="$1"
crash_after="${2:-none}"
markers="$state.markers"
mkdir -p "$markers"
[ -f "$state" ] || printf '%s\n' '{"completed":[],"complete":false}' > "$state"
for boundary in enqueue state presentation; do
  if jq -e --arg boundary "$boundary" '.completed | index($boundary)' "$state" >/dev/null; then
    continue
  fi
  tmp="$state.tmp.$$"
  jq --arg boundary "$boundary" '.completed += [$boundary]' "$state" > "$tmp"
  mv "$tmp" "$state"
  : > "$markers/$boundary"
  [ "$crash_after" != "$boundary" ] || exit 97
done
tmp="$state.tmp.$$"
jq '.complete = true' "$state" > "$tmp"
mv "$tmp" "$state"
SH
  chmod +x "$HTS_STUB/hts-crash-worker"
  # jq lives outside /usr/bin on Homebrew installs (macOS and the Linux test
  # container alike), so link it in rather than widening the pinned PATH — a
  # wider PATH would also expose the real pi and claude.
  local jq_bin
  jq_bin="$(command -v jq 2>/dev/null || true)"
  [[ -n "$jq_bin" ]] && ln -s "$jq_bin" "$HTS_STUB/jq"
  return 0
}

# $1 = binary name, $2 = text printed on stdout, $3 = exit code, $4 = sleep seconds
hts_stub_engine() {
  cat > "$HTS_STUB/$1" <<SH
#!/usr/bin/env bash
cat > "$HTS_WORK/$1-stdin.txt"
sleep ${4:-0}
printf '%s\n' '$2'
exit ${3:-0}
SH
  chmod +x "$HTS_STUB/$1"
}

hts_run() {
  hts_run_for_socket "$HTS_DEFAULT_SOCKET" "$@"
}

hts_run_for_socket() {
  local socket_path="$1"
  shift
  hts_prepare_invocation_target "$socket_path" "$@"
  env PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_ENV=1 \
    HERDR_PANE_ID=pane-1 \
    HERDR_SOCKET_PATH="$socket_path" \
    HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    HERDR_TASK_SYNC_TIMEOUT="${HTS_TIMEOUT:-5}" \
    HERDR_TASK_SYNC_TEST_NO_WORKER="${HERDR_TASK_SYNC_TEST_NO_WORKER:-}" \
    HERDR_TASK_SYNC_TEST_NO_PRESENTATION="${HERDR_TASK_SYNC_TEST_NO_PRESENTATION:-}" \
    HERDR_TASK_SYNC_TEST_NOW_SEQ="${HERDR_TASK_SYNC_TEST_NOW_SEQ:-}" \
    HERDR_TASK_SYNC_LOCK_ATTEMPTS="${HERDR_TASK_SYNC_LOCK_ATTEMPTS:-}" \
    bash "$HTS_ENGINE" "$@"
}

hts_worker_run() {
  env PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_ENV=1 \
    HERDR_PANE_ID=pane-1 \
    HERDR_SOCKET_PATH="$HTS_DEFAULT_SOCKET" \
    HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    HERDR_TASK_SYNC_TIMEOUT="${HTS_TIMEOUT:-5}" \
    HERDR_TASK_SYNC_TEST_NO_PRESENTATION="${HERDR_TASK_SYNC_TEST_NO_PRESENTATION:-}" \
    HERDR_TASK_SYNC_TEST_NOW_SEQ="${HERDR_TASK_SYNC_TEST_NOW_SEQ:-}" \
    HERDR_TASK_SYNC_LOCK_ATTEMPTS="${HERDR_TASK_SYNC_LOCK_ATTEMPTS:-}" \
    bash "$HTS_ENGINE" --worker --pane pane-1
}

hts_pane_list() {
  local state tmp panes
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  tmp="$state.tmp"
  panes="$(jq -c '.result.panes' <<< "$1")"
  jq --argjson panes "$panes" '
    .panes = $panes
    | reduce $panes[] as $pane (.;
        if any(.tabs[]; .tab_id == $pane.tab_id) then .
        else .tabs += [{tab_id:$pane.tab_id,workspace_id:($pane.workspace_id // ""),label:""}]
        end)
  ' "$state" > "$tmp" && mv "$tmp" "$state"
}

# $1 = pane id, $2 = the `pane process-info` payload the stub replays for it
hts_proc_info() {
  hts_proc_info_for_socket "$HTS_DEFAULT_SOCKET" "$@"
}

hts_proc_info_for_socket() {
  local dir
  dir="$(hts_socket_dir "$1")"
  printf '%s' "$3" > "$dir/proc-$2.json"
}

hts_tab_list() {
  local state tmp
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  tmp="$state.tmp"
  jq --argjson tabs "$(jq -c '.result.tabs' <<< "$1")" '.tabs = $tabs' "$state" > "$tmp" && mv "$tmp" "$state"
}

hts_init_socket_dir() {
  mkdir -p "$1/calls" "$1/completions" "$1/locks" "$1/after"
  printf '%s\n' \
    '{"complete":true,"protocol":19,"panes":[],"tabs":[],"agents":[],"layouts":[],"workspaces":[],"metadata":{}}' \
    > "$1/state.json"
  printf '%s' 0 > "$1/call-seq"
  : > "$1/herdr.log"
}

hts_socket_dir() {
  # shellcheck source=/dev/null
  source "$HTS_WORK/fixture-lib.sh"
  hts_fixture_socket_dir "$1"
}

hts_socket_state() {
  printf '%s/state.json\n' "$(hts_socket_dir "$1")"
}

hts_socket_log() {
  local dir
  dir="$(hts_socket_dir "$1")"
  if [[ -f "$dir/log-path" ]]; then
    cat "$dir/log-path"
  else
    printf '%s/herdr.log\n' "$dir"
  fi
}

hts_socket_run() {
  local socket_path="$1"
  shift
  env PATH="$HTS_STUB:/usr/bin:/bin" HERDR_SOCKET_PATH="$socket_path" herdr "$@"
}

# Upsert one object into a snapshot array, replacing any element that already
# carries the same id. Serves panes, tabs, and workspaces alike.
hts_upsert() {
  local socket="$1" array="$2" id_field="$3" object="$4" state tmp
  state="$(hts_socket_state "$socket")"
  tmp="$state.tmp"
  jq --arg array "$array" --arg id "$id_field" --argjson object "$object" \
    '.[$array] = ([.[$array][] | select(.[$id] != $object[$id])] + [$object])' \
    "$state" > "$tmp" && mv "$tmp" "$state"
}

hts_set_pane() {
  hts_upsert "$1" panes pane_id "$2"
}

hts_remove_pane() {
  local state tmp
  state="$(hts_socket_state "$1")"
  tmp="$state.tmp"
  jq --arg id "$2" '.panes |= map(select(.pane_id != $id))' "$state" > "$tmp" && mv "$tmp" "$state"
}

hts_set_tab() {
  hts_upsert "$1" tabs tab_id "$2"
}

# Workspace names come from the snapshot's workspaces array; the formatter
# suppresses the $git_ref folder qualifier when the worktree token equals
# the pane's workspace name.
hts_set_workspace() {
  hts_upsert "$1" workspaces workspace_id "$2"
}

hts_snapshot_complete() {
  local state tmp
  state="$(hts_socket_state "$1")"
  tmp="$state.tmp"
  jq --argjson complete "$2" '.complete = $complete' "$state" > "$tmp" && mv "$tmp" "$state"
}

hts_after_next_call_state() {
  local dir next
  dir="$(hts_socket_dir "$1")"
  next=$(( $(cat "$dir/call-seq") + 1 ))
  printf '%s\n' "$2" > "$dir/after/$next.json"
}

hts_after_call_script() {
  local dir
  dir="$(hts_socket_dir "$1")"
  printf '%s\n' "$3" > "$dir/after/$2.sh"
}

hts_wait_for_file() {
  local file="$1" i
  for i in $(seq 1 1000); do
    [[ -e "$file" ]] && return 0
    sleep 0.01
  done
  return 1
}

hts_wait_for_socket_call() {
  local dir="$1" call_number="$2"
  hts_wait_for_file "$dir/calls/$call_number"
}

hts_wait_for_socket_completion() {
  local dir="$1" call_number="$2"
  hts_wait_for_file "$dir/completions/$call_number"
}

hts_stub_controlled_engine() {
  ln -s "$HTS_WORK/model-stub" "$HTS_STUB/$1"
  mkdir -p "$HTS_WORK/models/$1"
  printf '%s' 0 > "$HTS_WORK/models/$1/next"
}

hts_model_fixture() {
  local fixture="$HTS_WORK/models/$1/$2"
  mkdir -p "$fixture"
  printf '%s\n' "$3" > "$fixture/stdout"
  printf '%s' "${4:-0}" > "$fixture/status"
}

hts_release_model() {
  : > "$HTS_WORK/models/$1/$2/release"
}

hts_git_fixture() {
  local id fixture next="$HTS_WORK/git-fixtures/next"
  mkdir -p "$HTS_WORK/git-fixtures"
  id="$(cat "$next" 2>/dev/null || printf '%s' 1)"
  printf '%s' $((id + 1)) > "$next"
  fixture="$HTS_WORK/git-fixtures/$id"
  mkdir -p "$fixture"
  printf '%s' "$1" > "$fixture/cwd"
  printf '%s\n' "$2" > "$fixture/stdout"
  printf '%s' "${3:-0}" > "$fixture/status"
  printf '%s\n' "${5:-}" > "$fixture/stderr"
  : > "$fixture/calls"
  printf '%s\037%s\n' "$1" "$fixture" >> "$HTS_WORK/git-fixtures/registry"
  [[ "${4:-ready}" = "block" ]] && : > "$fixture/block"
  return 0
}

# The location probe's stdout is four lines: checkout root, common Git
# directory, symbolic ref (literally HEAD when detached), 7-char short SHA.
hts_git_location_fixture() {
  local branch="${4:-refs/heads/main}" sha="${5:-abc9876}"
  hts_git_fixture "$1" "$(printf '%s\n%s\n%s\n%s' "$2" "$3" "$branch" "$sha")" "${6:-0}" "${7:-ready}"
}

# A linked worktree carries a .git FILE at its root; the main checkout has a
# .git directory. The resolver's is_linked check reads only this marker.
hts_mark_linked_worktree() {
  printf 'gitdir: %s\n' "${2:-$1.gitdir}" > "$1/.git"
}

hts_git_fixture_dir() {
  awk -F "$(printf '\037')" -v cwd="$1" '$1 == cwd { print $2; exit }' \
    "$HTS_WORK/git-fixtures/registry"
}

hts_process_pane_json() {
  local id="$1" tab="$2" cwd="$3" foreground_mode="${4:-present}" foreground="$3"
  [ "$#" -lt 5 ] || foreground="$5"
  jq -cn --arg id "$id" --arg tab "$tab" --arg cwd "$cwd" --arg fg "$foreground" \
    --arg mode "$foreground_mode" '
      {pane_id:$id,tab_id:$tab,workspace_id:"ws-1",terminal_id:("term-" + $id),agent:null,label:"",tokens:{},cwd:$cwd}
      | if $mode == "absent" then . else .foreground_cwd = $fg end'
}

hts_set_process_label() {
  hts_proc_info "$1" "$(jq -cn --arg command "$2" '{result:{process_info:{shell_pid:1,foreground_process_group_id:2,foreground_processes:[{pid:2,argv:[$command]}]}}}')"
}

# GIVEN-only fixture for the mixed two-pane tab: two linked worktrees of one
# repository, one process pane each in the shared tab-1, both process names far
# past the column budget. Takes the two branch names. The acting step
# (hts_location_pass) and every assertion stay in the test.
hts_two_pane_mixed_worktrees() {
  local ref_one="$1" ref_two="$2"
  local one="$HTS_WORK/wt-one" two="$HTS_WORK/wt-two"
  local common="$HTS_WORK/repository/.git"
  mkdir -p "$one" "$two" "$common"
  hts_mark_linked_worktree "$one" "$common/worktrees/one"
  hts_mark_linked_worktree "$two" "$common/worktrees/two"
  hts_git_location_fixture "$one" "$one" "$common" "refs/heads/$ref_one"
  hts_git_location_fixture "$two" "$two" "$common" "refs/heads/$ref_two"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$one")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-2 tab-1 "$two")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_process_label pane-1 first-process-name-that-is-far-too-long
  hts_set_process_label pane-2 second-process-name-that-is-far-too-long
}

hts_set_pane_location() {
  local state tmp foreground="$4"
  state="$(hts_socket_state "$1")"
  tmp="$state.tmp"
  jq --arg id "$2" --arg cwd "$3" --arg fg "$foreground" --arg mode "${5:-present}" '
    .panes |= map(if .pane_id == $id then
      .cwd = $cwd
      | if $mode == "absent" then del(.foreground_cwd) else .foreground_cwd = $fg end
    else . end)' "$state" > "$tmp" && mv "$tmp" "$state"
}

hts_location_pass() {
  HERDR_TASK_SYNC_GIT_BUDGET="${HERDR_TASK_SYNC_GIT_BUDGET:-0.2}" hts_event_run
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
}

hts_location_source_tokens() {
  jq -c --arg pane "$2" '.metadata[$pane]["location-sync"].tokens // {}' "$(hts_socket_state "$1")"
}

hts_location_source_seq() {
  jq -r --arg pane "$2" '.metadata[$pane]["location-sync"].seq // 0' "$(hts_socket_state "$1")"
}

hts_git_probe() {
  local pane="$1" cwd="$2" result_dir="$HTS_WORK/git-results" git_pid timer_pid git_status
  mkdir -p "$result_dir"
  env PATH="$HTS_STUB:/usr/bin:/bin" HTS_GIT_PROBE_ID="$pane" \
    git -C "$cwd" rev-parse --show-toplevel \
    > "$result_dir/$pane.output" 2>/dev/null &
  git_pid=$!
  hts_wait_for_file "$HTS_WORK/git-started/$pane"
  (
    sleep 0.075
    if kill -0 "$git_pid" 2>/dev/null; then
      : > "$result_dir/$pane.timed-out"
      kill "$git_pid" 2>/dev/null || true
    fi
  ) &
  timer_pid=$!
  if wait "$git_pid"; then git_status=0; else git_status=$?; fi
  kill "$timer_pid" 2>/dev/null || true
  wait "$timer_pid" 2>/dev/null || true
  if [[ -e "$result_dir/$pane.timed-out" || "$git_status" -ne 0 ]]; then
    printf '%s\n' stale > "$result_dir/$pane"
  else
    printf 'fresh:%s\n' "$(cat "$result_dir/$pane.output")" > "$result_dir/$pane"
  fi
}

hts_crash_run() {
  "$HTS_STUB/hts-crash-worker" "$1" "${2:-none}"
}

# The sweep modes carry no agent and no pane, so they run the script directly
# rather than through hts_run.
hts_sweep_run() {
  env PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    HERDR_TASK_SYNC_SWEEP_INTERVAL="${HTS_SWEEP_INTERVAL:-1}" \
    bash "$HTS_ENGINE" "$@"
}

hts_event_run() {
  env PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_SOCKET_PATH="$HTS_DEFAULT_SOCKET" \
    HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    HERDR_TASK_SYNC_TEST_NO_PRESENTATION="${HERDR_TASK_SYNC_TEST_NO_PRESENTATION:-}" \
    HERDR_TASK_SYNC_TEST_PAUSE_BEFORE_RELEASE="${HERDR_TASK_SYNC_TEST_PAUSE_BEFORE_RELEASE:-}" \
    HERDR_TASK_SYNC_TEST_NOW_SEQ="${HERDR_TASK_SYNC_TEST_NOW_SEQ:-}" \
    HERDR_TASK_SYNC_TEST_DIGEST_FILE="${HERDR_TASK_SYNC_TEST_DIGEST_FILE:-}" \
    HERDR_TASK_SYNC_GIT_BUDGET="${HERDR_TASK_SYNC_GIT_BUDGET:-}" \
    HERDR_TASK_SYNC_LABEL_COLUMNS="${HERDR_TASK_SYNC_LABEL_COLUMNS:-80}" \
    HERDR_TASK_SYNC_STATE_MAX_AGE_DAYS="${HERDR_TASK_SYNC_STATE_MAX_AGE_DAYS:-14}" \
    HERDR_TASK_SYNC_TEST_NO_DAEMON="${HERDR_TASK_SYNC_TEST_NO_DAEMON-1}" \
    bash "$HTS_ENGINE" --event
}

hts_event_run_for_socket() {
  local socket_path="$1"
  env PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_SOCKET_PATH="$socket_path" \
    HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    HERDR_TASK_SYNC_TEST_NO_PRESENTATION="${HERDR_TASK_SYNC_TEST_NO_PRESENTATION:-}" \
    HERDR_TASK_SYNC_TEST_NO_DAEMON="${HERDR_TASK_SYNC_TEST_NO_DAEMON-1}" \
    bash "$HTS_ENGINE" --event
}

hts_presentation_run() {
  env PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_SOCKET_PATH="$HTS_DEFAULT_SOCKET" \
    HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    HERDR_TASK_SYNC_TEST_CRASH_AFTER="${HERDR_TASK_SYNC_TEST_CRASH_AFTER:-}" \
    HERDR_TASK_SYNC_TEST_NOW_SEQ="${HERDR_TASK_SYNC_TEST_NOW_SEQ:-}" \
    HERDR_TASK_SYNC_TEST_DIGEST_FILE="${HERDR_TASK_SYNC_TEST_DIGEST_FILE:-}" \
    HERDR_TASK_SYNC_GIT_BUDGET="${HERDR_TASK_SYNC_GIT_BUDGET:-}" \
    HERDR_TASK_SYNC_LABEL_COLUMNS="${HERDR_TASK_SYNC_LABEL_COLUMNS:-80}" \
    HERDR_TASK_SYNC_STATE_MAX_AGE_DAYS="${HERDR_TASK_SYNC_STATE_MAX_AGE_DAYS:-14}" \
    HERDR_TASK_SYNC_TEST_LOCATION_BARRIER="${HERDR_TASK_SYNC_TEST_LOCATION_BARRIER:-}" \
    HERDR_TASK_SYNC_TEST_LOCATION_BARRIER_COUNT="${HERDR_TASK_SYNC_TEST_LOCATION_BARRIER_COUNT:-}" \
    HERDR_TASK_SYNC_TEST_LOCATION_BARRIER_RELEASE="${HERDR_TASK_SYNC_TEST_LOCATION_BARRIER_RELEASE:-}" \
    bash "$HTS_ENGINE" --presentation-worker
}

# The worker logs several herdr calls in a row, so a test that reads a later
# call must wait for that call and not for the first line of the log.
hts_wait_for_call() {
  local i
  for i in $(seq 1 60); do
    grep -q -- "$1" "$HTS_LOG" && return 0
    sleep 0.25
  done
  return 1
}

# Waits for the publish itself — the `--token task=` metadata call — and not
# merely for a non-empty log. The entry point logs `pane process-info` before it
# forks the worker, so a non-empty log says only that the run started: the state
# file is unwritten, the naming engine has not been called, and the assertions
# that follow read whatever the PREVIOUS session left behind. That was a real
# flake, not a theoretical one (docs/issues/2026-08-14-001).
hts_wait_for_publish() {
  hts_wait_for_call '--token task='
}

# The presentation coordinator keeps logging after metadata publication. A
# test that truncates the log must wait for its fresh snapshot first.
hts_wait_for_worker_exit() {
  hts_wait_for_publish && hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
}

# Waits for a session's own durable state file. Session ids are part of the
# path, so this signal cannot be satisfied by another session's worker — the
# one guarantee a log-based wait cannot give while two workers overlap.
hts_wait_for_state() {
  local i
  for i in $(seq 1 60); do
    [[ -s "$1" ]] && return 0
    sleep 0.25
  done
  return 1
}

hts_token() {
  sed -n 's/.*--token task=\([^ ]*\).*/\1/p' "$HTS_LOG" | tail -1
}

hts_pane_label() {
  sed -n "s/^pane rename ${1:-pane-1} //p" "$HTS_LOG" | tail -1
}

hts_legacy_state_file() {
  printf '%s/%s.state' "$HTS_STATE" "$1"
}

hts_state_field() {
  grep -m1 "^${2}=" "$1" | cut -d= -f2- | base64 -d
}

hts_key() {
  printf '%s' "$1" | base64 | tr '/+' '_-' | tr -d '=\n'
}

hts_namespace() {
  printf '%s/sockets/%s\n' "$HTS_STATE" "$(hts_key "$1")"
}

hts_pane_state_dir() {
  printf '%s/panes/%s\n' "$(hts_namespace "$1")" "$(hts_key "$2")"
}

hts_prepare_invocation_target() {
  local socket_path="$1" pane_id=pane-1 invocation_agent= invocation_session= state tmp
  shift
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --pane) pane_id="${2:-}"; shift 2 ;;
      --agent) invocation_agent="${2:-}"; shift 2 ;;
      --session) invocation_session="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$invocation_agent" && -n "$invocation_session" ]] || return 0
  state="$(hts_socket_state "$socket_path")"
  if jq -e --arg id "$pane_id" '.panes[] | select(.pane_id == $id and ._hts_auto == true)' "$state" >/dev/null; then
    tmp="$state.tmp"
    jq --arg id "$pane_id" --arg agent "$invocation_agent" --arg session "$invocation_session" '
      .panes |= map(if .pane_id == $id then
        .agent = $agent
        | .agent_session = {source:("herdr:" + $agent),agent:$agent,kind:"id",value:$session}
      else . end)
    ' "$state" > "$tmp" && mv "$tmp" "$state"
    return 0
  fi
  jq -e --arg id "$pane_id" '.panes[] | select(.pane_id == $id)' "$state" >/dev/null && return 0
  tmp="$state.tmp"
  jq --arg pane "$pane_id" --arg agent "$invocation_agent" --arg session "$invocation_session" '
    .panes += [{pane_id:$pane,tab_id:"tab-1",workspace_id:"ws-1",terminal_id:("term-" + $pane),agent:$agent,agent_session:{source:("herdr:" + $agent),agent:$agent,kind:"id",value:$session},label:"",tokens:{},_hts_auto:true}]
    | if any(.tabs[]; .tab_id == "tab-1") then . else .tabs += [{tab_id:"tab-1",workspace_id:"ws-1",label:""}] end
  ' "$state" > "$tmp" && mv "$tmp" "$state"
}

hts_control_file() {
  printf '%s/control.state\n' "$(hts_pane_state_dir "$1" "$2")"
}

hts_task_file() {
  local identity
  identity="$(printf '%s\037%s\037%s' "$2" "$3" "$4")"
  printf '%s/tasks/%s.state\n' "$(hts_namespace "$1")" "$(hts_key "$identity")"
}

hts_migration_marker() {
  local identity
  identity="$(printf '%s\037%s\037%s' "$2" "$3" "$4")"
  printf '%s/migration/%s.done\n' "$(hts_namespace "$1")" "$(hts_key "$identity")"
}

hts_record_text() {
  hts_state_field "$1" "$2"
}

hts_record_number() {
  sed -n "s/^${2}=//p" "$1" | head -1
}

hts_wait_for_record_number() {
  local file="$1" field="$2" expected="$3" i value
  for i in $(seq 1 1000); do
    value="$(hts_record_number "$file" "$field" 2>/dev/null || true)"
    [[ -n "$value" && "$value" -ge "$expected" ]] && return 0
    sleep 0.01
  done
  return 1
}

hts_wait_for_quiescence() {
  local control="$1" i generation committed worker_claim
  worker_claim="$(dirname "$control")/worker.claim"
  for i in $(seq 1 1000); do
    generation="$(hts_record_number "$control" generation 2>/dev/null || true)"
    committed="$(hts_record_number "$control" committed_generation 2>/dev/null || true)"
    if [[ -n "$generation" && "$generation" = "$committed" && ! -d "$worker_claim" ]]; then
      sleep 0.02
      [[ ! -d "$worker_claim" ]] && return 0
    fi
    sleep 0.01
  done
  return 1
}

hts_wait_for_presentation_quiescence() {
  local namespace reconcile claim i pending completed
  namespace="$(hts_namespace "$1")"
  reconcile="$namespace/reconcile.state"
  claim="$namespace/presentation.claim"
  for i in $(seq 1 1000); do
    pending="$(hts_record_number "$reconcile" pending_generation 2>/dev/null || true)"
    completed="$(hts_record_number "$reconcile" completed_generation 2>/dev/null || true)"
    if [[ -n "$pending" && "$pending" -gt 0 && "$pending" = "$completed" && ! -d "$claim" ]]; then
      sleep 0.02
      [[ ! -d "$claim" ]] && return 0
    fi
    sleep 0.01
  done
  return 1
}

hts_write_legacy_state() {
  local file="$1" slug="$2" first="$3" latest="$4"
  {
    printf 'slug=%s\n' "$(printf '%s' "$slug" | base64 | tr -d '\n')"
    printf 'first_prompt=%s\n' "$(printf '%s' "$first" | base64 | tr -d '\n')"
    printf 'latest_prompt=%s\n' "$(printf '%s' "$latest" | base64 | tr -d '\n')"
  } > "$file"
}

hts_wait_for_task_slug() {
  local file="$1" expected="$2" i
  for i in $(seq 1 1000); do
    [[ "$(hts_record_text "$file" slug 2>/dev/null || true)" = "$expected" ]] && return 0
    sleep 0.01
  done
  return 1
}

@test "herdr-task-sync descriptor child probe" {
  [ -n "${HTS_DESCRIPTOR_PID_FILE:-}" ] || skip "internal descriptor probe"
  hts_setup
  hts_stub_controlled_engine pi
  hts_model_fixture pi 1 descriptor-probe
  local control task generation
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  task="$(hts_task_file "$HTS_DEFAULT_SOCKET" claude pane-1 descriptor-s)"

  hts_run --agent claude --session descriptor-s <<< 'descriptor probe prompt'
  hts_wait_for_file "$HTS_WORK/models/pi/1/started"
  generation="$(hts_record_number "$control" generation)"
  : > "$HTS_WORK/block-herdr"
  hts_release_model pi 1
  hts_wait_for_task_slug "$task" descriptor-probe
  hts_wait_for_record_number "$control" committed_generation "$generation"
  hts_wait_for_file "$HTS_WORK/herdr-blocked"
  hts_record_number \
    "$(hts_namespace "$HTS_DEFAULT_SOCKET")/presentation.claim/owner" pid \
    > "$HTS_DESCRIPTOR_PID_FILE"
}

@test "herdr-task-sync bounded Bats invocation exits after detached work" {
  command -v python3 >/dev/null || skip "python3 not available"
  local bats_bin release_file="$BATS_TEST_TMPDIR/release-herdr"
  local pid_file="$BATS_TEST_TMPDIR/descriptor-worker.pid"
  bats_bin="$(command -v bats)"
  export HTS_DESCRIPTOR_RELEASE_FILE="$release_file"
  export HTS_DESCRIPTOR_PID_FILE="$pid_file"
  run python3 - "$bats_bin" "$BATS_TEST_FILENAME" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import time

command = [
    sys.argv[1],
    sys.argv[2],
    "--filter",
    "^herdr-task-sync descriptor child probe$",
]
try:
    result = subprocess.run(command, capture_output=True, text=True, timeout=12)
except subprocess.TimeoutExpired as error:
    Path(os.environ["HTS_DESCRIPTOR_RELEASE_FILE"]).touch()
    if error.stdout:
        sys.stdout.write(error.stdout if isinstance(error.stdout, str) else error.stdout.decode())
    print("inner Bats invocation exceeded 12 seconds", file=sys.stderr)
    raise SystemExit(124)

sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
if result.returncode != 0:
    raise SystemExit(result.returncode)

Path(os.environ["HTS_DESCRIPTOR_RELEASE_FILE"]).touch()
pid = int(Path(os.environ["HTS_DESCRIPTOR_PID_FILE"]).read_text())
for _ in range(500):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        break
    time.sleep(0.01)
else:
    print(f"detached worker {pid} did not exit after release", file=sys.stderr)
    raise SystemExit(125)
PY
  unset HTS_DESCRIPTOR_RELEASE_FILE HTS_DESCRIPTOR_PID_FILE
  assert_success
  assert_output --partial "ok 1 herdr-task-sync descriptor child probe"
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

@test "herdr-task-sync harness restarts from every durable crash boundary" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local boundary state
  for boundary in enqueue state presentation; do
    state="$HTS_WORK/crash-$boundary.json"
    run hts_crash_run "$state" "$boundary"
    assert_failure 97
    assert_equal "$(jq -r '.complete' "$state")" false
    assert_file_exists "$state.markers/$boundary"

    run hts_crash_run "$state"
    assert_success
    assert_equal "$(jq -r '.complete' "$state")" true
    assert_equal "$(jq -r '.completed | length' "$state")" 3
    assert_equal "$(jq -r '.completed | unique | length' "$state")" 3
  done
}

@test "herdr-task-sync harness gives eight panes independent 75 ms Git budgets" {
  hts_setup
  local i pids= pid
  for i in 1 2 3 4 5 6 7; do
    hts_git_fixture "/repo/$i" "/repo/$i"
  done
  hts_git_fixture /repo/8 /repo/8 0 block

  for i in 1 2 3 4 5 6 7 8; do
    hts_git_probe "pane-$i" "/repo/$i" &
    pids="$pids $!"
  done
  for pid in $pids; do wait "$pid"; done

  for i in 1 2 3 4 5 6 7; do
    assert_equal "$(cat "$HTS_WORK/git-results/pane-$i")" "fresh:/repo/$i"
  done
  assert_equal "$(cat "$HTS_WORK/git-results/pane-8")" stale
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
  local task control reconcile stop="$HTS_WORK/stop-reader" bad="$HTS_WORK/bad-reader" reader i
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
  for i in $(seq 1 40); do
    hts_run --agent pi --session atomic-s --set "atomic-$i" < /dev/null
  done
  hts_wait_for_task_slug "$task" atomic-40
  : > "$stop"
  wait "$reader"
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

  hts_run_for_socket "$socket_one" --agent pi --session same --set socket-one < /dev/null
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
  grep -q '^checkout_root=' "$namespace_one/reconcile.state"
  grep -q '^repository_anchor=' "$namespace_one/reconcile.state"
}

@test "herdr-task-sync fails open for missing tools contention write failure and malformed input" {
  hts_setup
  local start end pane_dir
  start="$(date +%s)"
  run env PATH="/usr/bin:/bin" HERDR_ENV=1 HERDR_PANE_ID=pane-1 \
    HERDR_SOCKET_PATH="$HTS_DEFAULT_SOCKET" HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    bash "$HTS_ENGINE" --agent claude --session missing <<< 'missing herdr'
  end="$(date +%s)"
  assert_success
  [[ $((end - start)) -le 2 ]]

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
  local namespace control
  namespace="$(hts_namespace "$HTS_DEFAULT_SOCKET")"
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  rmdir "$namespace/tasks"
  printf 'not-a-directory\n' > "$namespace/tasks"
  start="$(date +%s)"
  run hts_worker_run
  end="$(date +%s)"
  assert_success
  [[ $((end - start)) -le 2 ]]
  [[ "$(hts_record_number "$control" generation)" -gt \
    "$(hts_record_number "$control" committed_generation)" ]]

  hts_setup
  HERDR_TASK_SYNC_TEST_NO_WORKER=1 hts_run \
    --agent pi --session commit-write-failure --set pending-task < /dev/null
  control="$(hts_control_file "$HTS_DEFAULT_SOCKET" pane-1)"
  local task_file
  task_file="$(hts_task_file "$HTS_DEFAULT_SOCKET" pi pane-1 commit-write-failure)"
  mkdir "$task_file"
  start="$(date +%s)"
  run hts_worker_run
  end="$(date +%s)"
  assert_success
  [[ $((end - start)) -le 2 ]]
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

@test "herdr-task-sync agent adapters await only the engine enqueue boundary" {
  local pi_adapter="$SOURCE_ROOT/dot_pi/agent/extensions/herdr-task-sync.ts"
  local opencode_adapter="$SOURCE_ROOT/private_dot_config/opencode/plugins/herdr-task-sync.ts"
  local claude_adapter="$SOURCE_ROOT/private_dot_claude/hooks/executable_herdr-task-sync-hook.sh"
  run grep -c 'await callEngine' "$pi_adapter"
  assert_output "2"
  run grep -c 'await callEngine' "$opencode_adapter"
  assert_output "1"
  run bash -c "! grep -q 'detached: true' '$pi_adapter' '$opencode_adapter'"
  assert_success
  run grep -c "bounded atomic inbox commit" "$claude_adapter"
  assert_output "1"
}

@test "herdr-task-sync adapters bound and clean up direct engine processes" {
  local pi_adapter="$SOURCE_ROOT/dot_pi/agent/extensions/herdr-task-sync.ts"
  local opencode_adapter="$SOURCE_ROOT/private_dot_config/opencode/plugins/herdr-task-sync.ts"
  local adapter
  for adapter in "$pi_adapter" "$opencode_adapter"; do
    run grep -Fq 'child.stdin?.destroy()' "$adapter"
    assert_success
    run grep -Fq 'child.kill("SIGTERM")' "$adapter"
    assert_success
    run grep -Fq 'child.once("error", finish)' "$adapter"
    assert_success
    run grep -Fq 'child.once("close", finish)' "$adapter"
    assert_success
    run grep -Fq 'timer.unref?.()' "$adapter"
    assert_success
    run grep -Fq 'removeListener("error"' "$adapter"
    assert_failure
  done
}

@test "herdr-task-sync adapters return when a direct engine hangs" {
  command -v bun >/dev/null || skip "bun not available"
  local pi_adapter="$SOURCE_ROOT/dot_pi/agent/extensions/herdr-task-sync.ts"
  local opencode_adapter="$SOURCE_ROOT/private_dot_config/opencode/plugins/herdr-task-sync.ts"
  local home="$BATS_TEST_TMPDIR/adapter-timeout-home"
  mkdir -p "$home/.local/bin"
  cat > "$home/.local/bin/herdr-task-sync" <<'SH'
#!/bin/sh
cat >/dev/null
trap 'exit 0' TERM
while :; do sleep 0.05; done
SH
  chmod +x "$home/.local/bin/herdr-task-sync"

  run env HOME="$home" HERDR_ENV=1 PI_ADAPTER_PATH="$pi_adapter" \
    OPENCODE_ADAPTER_PATH="$opencode_adapter" bun -e '
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
      const piStart = performance.now()
      await piHandlers.before_agent_start({ prompt: "hung pi engine" }, context)
      if (performance.now() - piStart > 1750) throw new Error("pi adapter exceeded timeout")

      const { HerdrTaskSyncPlugin } = await import(`file://${process.env.OPENCODE_ADAPTER_PATH}`)
      const hooks = await HerdrTaskSyncPlugin()
      const opencodeStart = performance.now()
      await hooks["chat.message"](
        { sessionID: "opencode-root" },
        { parts: [{ type: "text", text: "hung opencode engine" }] },
      )
      if (performance.now() - opencodeStart > 1750) throw new Error("opencode adapter exceeded timeout")
    '
  assert_success
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
  hts_event_run
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
  for _ in $(seq 1 1000); do
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
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "$HTS_ICON_COMMIT a1b2c3d · worker"
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
  HERDR_TASK_SYNC_GIT_BUDGET=0.075 hts_location_pass
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
  HERDR_TASK_SYNC_GIT_BUDGET=0.075 hts_location_pass
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
  export HERDR_TASK_SYNC_GIT_BUDGET=0.075
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
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "$HTS_ICON_BRANCH topic-one $HTS_ICON_STALE one · $HTS_ICON_FOLDER live-token $HTS_ICON_STALE two · three"
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

@test "herdr-task-sync formatter hoists one shared git ref and leaves all-non-Git unchanged" {
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
  # Scenario matrix #5 (docs/plans/2026-08-20-001-feat-herdr-label-system-plan.md):
  # panes that agree on branch and worktree hoist
  # one shared ref; the folder qualifier is suppressed by the workspace name.
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "$HTS_ICON_BRANCH main · alpha · beta"
  assert_equal "$(jq -r '.panes[] | .tokens.git_ref' "$state" | sort -u)" "$HTS_ICON_BRANCH main"

  # Stale drops the tab to per-segment prefixes; stale is a suffix icon on
  # the segment's ref, never a text marker.
  hts_set_pane_location "$HTS_DEFAULT_SOCKET" pane-2 "$two" "$missing"
  hts_location_pass
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "$HTS_ICON_BRANCH main alpha · $HTS_ICON_BRANCH main $HTS_ICON_STALE beta"

  hts_set_pane_location "$HTS_DEFAULT_SOCKET" pane-1 "$outside" "$outside"
  hts_set_pane_location "$HTS_DEFAULT_SOCKET" pane-2 "$outside" "$outside"
  hts_location_pass
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"
}

@test "herdr-task-sync formatter renders a main checkout as branch icon plus ref without a workspace-named folder" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # Scenario matrix #1 (same plan doc): main checkout (.git directory at the root),
  # branch main, checkout folder equal to the herdr workspace name.
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
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "$HTS_ICON_BRANCH main · task"
}

@test "herdr-task-sync formatter renders a worktree whose folder equals its branch as icon plus ref in sidebar and tab" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # Scenario matrix #2 (same plan doc): linked worktree in a folder named
  # exactly like its branch. The worktree icon alone carries the place; a
  # folder qualifier would only repeat the ref, so neither surface shows one.
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
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "$HTS_ICON_WORKTREE feature · task"
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
  # The tab segment stays compact: icon + ref only, folder in the sidebar.
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "$HTS_ICON_BRANCH main · task"
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
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "$HTS_ICON_COMMIT a1b2c3d · task"
}

@test "herdr-task-sync formatter qualifies a divergent worktree folder in the sidebar only and hoists the shared ref once" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # Scenario matrix #3 and #5 (same plan doc): linked worktree wt-hotfix on branch
  # fix-login. Both panes share the ref, so the tab hoists it once and never
  # shows the folder qualifier — the sidebar carries that detail.
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
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "$HTS_ICON_WORKTREE fix-login · alpha · beta"
}

@test "herdr-task-sync formatter keeps mixed identities adjacent and repairs external labels" {
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
  # Scenario matrix #7 (same plan doc): only panes in different repos carry the repo
  # name in front of the icon+ref segment prefix.
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "a $HTS_ICON_BRANCH dev first · b $HTS_ICON_BRANCH main second"

  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-2 tab-1 "$cwd_b" present "$missing")"
  hts_socket_run "$HTS_DEFAULT_SOCKET" pane rename pane-1 divergent-pane
  hts_socket_run "$HTS_DEFAULT_SOCKET" tab rename tab-1 divergent-tab
  hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .label' "$state")" first
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "a $HTS_ICON_BRANCH dev first · b $HTS_ICON_BRANCH main $HTS_ICON_STALE second"

  # With a single remaining repo the repo-name prefix disappears again.
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-2 tab-1 "$outside")"
  hts_location_pass
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "$HTS_ICON_BRANCH dev first · second"
}

@test "herdr-task-sync formatter repo-qualifies every segment when three panes span two repositories" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # The two-pane tab has its own composer; three or more panes walk the
  # per-segment loop instead, where first_repo/multiple_repos tracking must
  # still notice the second repository and repo-qualify every segment —
  # including the two that share repository a.
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
    "a $HTS_ICON_BRANCH dev one · a $HTS_ICON_BRANCH dev two · b $HTS_ICON_BRANCH main three"
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
  # The slash-suffix folder token appears only in the sidebar qualifier;
  # Scenario matrix #6 (same plan doc) keeps tab segment prefixes to icon+ref.
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.git_ref' "$state")" "$HTS_ICON_WORKTREE one $HTS_ICON_FOLDER team/feature"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-2") | .tokens.git_ref' "$state")" "$HTS_ICON_WORKTREE two $HTS_ICON_FOLDER release/feature"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "$HTS_ICON_WORKTREE one alpha · $HTS_ICON_WORKTREE two beta"
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

@test "herdr-task-sync two-pane mixed formatter preserves identities and eight task columns at 80 columns" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local state label
  hts_two_pane_mixed_worktrees abcdefghijklmnopqr stuvwxyzabcdefghi
  HERDR_TASK_SYNC_LABEL_COLUMNS=80 hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  label="$(jq -r '.tabs[0].label' "$state")"
  [[ "$(printf '%s' "$label" | wc -m | tr -d ' ')" -le 80 ]]
  [[ "$label" = *abcdefghijklmnopqr* && "$label" = *stuvwxyzabcdefghi* && "$label" = *…* ]]
  run jq -e \
    --arg one "$HTS_ICON_WORKTREE abcdefghijklmnopqr" \
    --arg two "$HTS_ICON_WORKTREE stuvwxyzabcdefghi" \
    '.tabs[0].label | capture("^" + $one + " (?<one>.+) · " + $two + " (?<two>.+)$") | (.one | length) >= 8 and (.two | length) >= 8' "$state"
  assert_success
}

@test "herdr-task-sync width math counts codepoints even when the daemon inherits a non-UTF-8 locale" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local state label expected
  hts_two_pane_mixed_worktrees abcdefghijklmnopqr stuvwxyzabcdefghi
  # when: the whole pass runs under LC_ALL=C, the locale a hook spawned from a
  # non-UTF-8 environment hands the daemon
  LC_ALL=C HERDR_TASK_SYNC_LABEL_COLUMNS=80 hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  label="$(jq -r '.tabs[0].label' "$state")"
  # then: byte-identical to the UTF-8 run — the pinned TEXT_LOCALE charged
  # each three-byte codicon one column, so the budget still hands each pane
  # text 18 columns instead of the shrunken byte-counted share.
  expected="$HTS_ICON_WORKTREE abcdefghijklmnopqr first-process-nam… · $HTS_ICON_WORKTREE stuvwxyzabcdefghi second-process-na…"
  assert_equal "$label" "$expected"
}

@test "herdr-task-sync two-pane mixed formatter caps long branch refs in tab prefixes while the sidebar keeps the full ref" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local state label
  # given: a 44-character branch name — far past the 18-column prefix cap
  local long_ref="feature/very-long-branch-name-that-overflows"
  hts_two_pane_mixed_worktrees "$long_ref" short-two
  # when
  HERDR_TASK_SYNC_LABEL_COLUMNS=80 hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  label="$(jq -r '.tabs[0].label' "$state")"
  # then: the tab prefix carries the ref capped at 18 columns and the whole
  # label still fits the 80-column budget
  [[ "$(printf '%s' "$label" | wc -m | tr -d ' ')" -le 80 ]]
  [[ "$label" = "$HTS_ICON_WORKTREE feature/very-long… "*" · $HTS_ICON_WORKTREE short-two "* ]]
  [[ "$label" != *"$long_ref"* ]]
  # then: the sidebar git_ref token keeps the FULL ref — only tab prefixes cap
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.git_ref' "$state")" "$HTS_ICON_WORKTREE $long_ref $HTS_ICON_FOLDER wt-one"
}

@test "herdr-task-sync two-pane mixed formatter caps repo names so a multi-repo tab holds the 80-column budget" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  # given: two distinct repositories whose names pass the 12-column repo cap,
  # each on a branch that also passes the 18-column ref cap. Both prefixes are
  # therefore at full width, which is the shape that used to overflow.
  local one="$HTS_WORK/integration-platform-connectors"
  local two="$HTS_WORK/internal-developer-tooling"
  local common_one="$one/.git" common_two="$two/.git" state label
  mkdir -p "$common_one" "$common_two"
  hts_git_location_fixture "$one" "$one" "$common_one" refs/heads/feat/connector-runtime-rewrite
  hts_git_location_fixture "$two" "$two" "$common_two" refs/heads/fix/oauth-refresh-loop-retry
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-1 tab-1 "$one")"
  hts_set_pane "$HTS_DEFAULT_SOCKET" "$(hts_process_pane_json pane-2 tab-1 "$two")"
  hts_set_tab "$HTS_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hts_set_process_label pane-1 first-process-name-that-is-far-too-long
  hts_set_process_label pane-2 second-process-name-that-is-far-too-long
  # when
  HERDR_TASK_SYNC_LABEL_COLUMNS=80 hts_location_pass
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  label="$(jq -r '.tabs[0].label' "$state")"
  # then: the whole label fits the budget the composer exists to enforce
  [[ "$(printf '%s' "$label" | wc -m | tr -d ' ')" -le 80 ]]
  # then: each segment carries its repo name capped at 12 columns
  [[ "$label" = "integration… $HTS_ICON_BRANCH"* ]]
  [[ "$label" = *" · internal-de… $HTS_ICON_BRANCH"* ]]
  [[ "$label" != *integration-platform-connectors* ]]
  [[ "$label" != *internal-developer-tooling* ]]
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
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "$HTS_ICON_WORKTREE plain · plain-task"
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
  hts_event_run
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
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

@test "herdr-task-sync passes bash syntax check" {
  run bash -n "$HTS_ENGINE"
  assert_success
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
@test "herdr-task-sync returns before the naming engine finishes (R8)" {
  hts_setup
  hts_stub_engine pi late-slug 0 4
  local start end
  start="$(date +%s)"
  run hts_run --agent claude --session s1 <<< 'a slow substantive prompt'
  end="$(date +%s)"
  assert_success
  [[ $((end - start)) -le 2 ]] || fail "entry point blocked for $((end - start))s"
  hts_wait_for_publish
  assert_equal "$(hts_token)" "late-slug"
}

# KTD8: the token reaching herdr and the sidebar is bounded whatever the model
# returns — no shell metacharacters, no ANSI escapes, no newlines. The stub's
# output normalizes to five hyphen-separated words, the engine's cap for a
# published slug; wordier output is treated as a failed naming call instead.
@test "herdr-task-sync normalizes a hostile engine slug (KTD8)" {
  hts_setup
  cat > "$HTS_STUB/pi" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '\n  cache $(touch /tmp/htspwn) \033[31mREVIEW\nsecond line\n'
SH
  chmod +x "$HTS_STUB/pi"
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_publish
  run bash -c "printf '%s' '$(hts_token)' | grep -Eq '^[a-z0-9-]{1,40}\$'"
  assert_success
  assert_file_not_exists /tmp/htspwn
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
# the labels of the tab's own agent panes; another tab's panes stay out.
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
  assert_output "tab rename tab-1 cc:cache-review · second"
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

@test "herdr-task-sync sweep daemon exits after three unreachable snapshots" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  local dir daemon_pid i
  dir="$(hts_socket_dir "$HTS_DEFAULT_SOCKET")"
  : > "$dir/fail-snapshot"
  HTS_SWEEP_INTERVAL=0.01 hts_sweep_run --sweep-daemon &
  daemon_pid=$!
  for i in $(seq 1 200); do
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

@test "herdr-task-sync hook passes bash syntax check" {
  run bash -n "$HTS_HOOK"
  assert_success
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
  plan="$(mktemp /tmp/se-dryrun-plan-XXXXXX.md)"
  printf -- '---\nartifact_contract: ce-unified-plan/v1\n---\n# t\n' > "$plan"
  run env SE_DRY_RUN=1 "$se_bin" pipeline "$plan" --setup-cmd 'bun install && bunx turbo run build --filter=@x/y'
  rm -f "$plan"
  assert_success
  assert_output --partial '"setupCmd":"bun install && bunx turbo run build --filter=@x/y"'
}

@test "se flow --dry-run lands spec path, budget, and setup-cmd in the workflow input JSON" {
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local spec
  spec="$(mktemp /tmp/se-flow-spec-XXXXXX.json)"
  printf '{"task":{"description":"x"},"repo":"/tmp/r","blocks":[{"id":"scan","block":"secret-scan","retries":0,"timeoutMs":120000}]}' > "$spec"
  run env "$se_bin" flow "$spec" --budget 12 --setup-cmd 'make setup' --dry-run
  rm -f "$spec"
  assert_success
  assert_output --partial 'workflows/se-flow.tsx'
  assert_output --partial '"budgetUsd":12'
  assert_output --partial '"setupCmd":"make setup"'
  assert_output --partial '"specPath":"'
  assert_output --partial 'se-flow-spec-'
}

@test "se flow --validate-cmd lands the operator's command in the workflow input JSON" {
  # The run-validate block and the simplify subflow read the command from the
  # run, never from the spec. Without this flag the workflow default is empty
  # and run-validate can only ever record exitCode null.
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local spec
  spec="$(mktemp /tmp/se-flow-spec-XXXXXX.json)"
  printf '{"task":{"description":"x"},"repo":"/tmp/r","blocks":[{"id":"scan","block":"secret-scan","retries":0,"timeoutMs":120000}]}' > "$spec"
  run env "$se_bin" flow "$spec" --validate-cmd 'bun test' --dry-run
  rm -f "$spec"
  assert_success
  assert_output --partial '"validateCmd":"bun test"'
}

@test "se flow without --validate-cmd sends an empty command, not a missing key" {
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local spec
  spec="$(mktemp /tmp/se-flow-spec-XXXXXX.json)"
  printf '{"task":{"description":"x"},"repo":"/tmp/r","blocks":[{"id":"scan","block":"secret-scan","retries":0,"timeoutMs":120000}]}' > "$spec"
  run env "$se_bin" flow "$spec" --dry-run
  rm -f "$spec"
  assert_success
  assert_output --partial '"validateCmd":""'
}

@test "se flow --dry-run prints the composed flow with a cost estimate (R10)" {
  # The operator sees what a launch will run and what it may cost before it
  # starts. A bare command line does not carry that.
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local spec
  spec="$(mktemp /tmp/se-flow-spec-XXXXXX.json)"
  cat > "$spec" <<'JSON'
{"task":{"description":"printout fixture"},"repo":"/tmp/r","blocks":[
 {"id":"implement","block":"work","input":{"prompt":"x"},"retries":0,"timeoutMs":600000,"after":[],"bindTo":[]},
 {"id":"scan","block":"secret-scan","input":{},"retries":0,"timeoutMs":120000,"after":["implement"],"bindTo":["implement"]}]}
JSON
  run env "$se_bin" flow "$spec" --dry-run
  rm -f "$spec"
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
  spec="$(mktemp /tmp/se-flow-spec-XXXXXX.json)"
  cat > "$spec" <<'JSON'
{"task":{"description":"unscanned publish"},"repo":"/tmp/r","blocks":[
 {"id":"implement","block":"work","input":{"prompt":"x"},"retries":0,"timeoutMs":600000,"after":[],"bindTo":[]},
 {"id":"ship","block":"pr","input":{"title":"t"},"retries":0,"timeoutMs":300000,"after":["implement"],"bindTo":["implement"]}]}
JSON
  run env "$se_bin" flow "$spec" --dry-run
  rm -f "$spec"
  assert_failure
  assert_output --partial 'scan-before-external'
}

@test "se flow rejects a non-numeric budget" {
  local se_bin="$SOURCE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"
  local spec
  spec="$(mktemp /tmp/se-flow-spec-XXXXXX.json)"
  printf '{}' > "$spec"
  run env "$se_bin" flow "$spec" --budget abc --dry-run
  rm -f "$spec"
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

@test "Pi settings modifier selects the terminal theme and preserves runtime settings" {
  local modifier="$SOURCE_ROOT/dot_pi/agent/modify_settings.json"
  local input='{"theme":"light","lastChangelogVersion":"0.84.2","packages":["npm:pi-ask-user"]}'

  run bash "$modifier" <<< "$input"

  assert_success
  run jq -e '
    .theme == "terminal" and
    .lastChangelogVersion == "0.84.2" and
    (.packages | index("git:github.com/EveryInc/compound-engineering-plugin") != null) and
    (.packages | index("npm:pi-ask-user") != null) and
    (.packages | index("npm:pi-subagentura") != null) and
    (.packages | index("npm:@trevonistrevon/pi-loop") != null) and
    (.packages | index("npm:pi-web-access") != null) and
    (.packages | index("npm:pi-context-view") != null) and
    (.packages | index("npm:@ff-labs/pi-fff") != null)
  ' <<< "$output"
  assert_success
}

@test "Pi settings modifier is idempotent" {
  local modifier="$SOURCE_ROOT/dot_pi/agent/modify_settings.json"
  local input='{"packages":["npm:pi-subagentura","npm:@trevonistrevon/pi-loop","npm:pi-ask-user","npm:pi-web-access","npm:pi-context-view","npm:@ff-labs/pi-fff"]}'

  run bash "$modifier" <<< "$input"

  assert_success
  run jq -e '
    [
      "npm:pi-subagentura",
      "npm:@trevonistrevon/pi-loop",
      "npm:pi-web-access",
      "npm:pi-context-view",
      "npm:@ff-labs/pi-fff"
    ] as $required |
    (.theme == "terminal") and
    (.packages as $packages |
      all($required[]; . as $package | [$packages[] | select(. == $package)] | length == 1))
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
