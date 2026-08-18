#!/usr/bin/env bats

load 'helpers/common'

teardown() {
  [[ -n "${BATS_TEST_TMPFILE:-}" ]] && rm -f "$BATS_TEST_TMPFILE" || true
  [[ -n "${HTS_WORK:-}" ]] && rm -rf "$HTS_WORK" || true
  [[ -n "${CHILD_STUB:-}" ]] && rm -rf "$CHILD_STUB" || true
}

# ===========================================
# Repository linting
# ===========================================

@test "shellcheck is managed by the cross-platform Brewfile" {
  assert_file_contains "$SOURCE_ROOT/private_dot_config/brewfiles/Brewfile" '^brew "shellcheck"'
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

@test "install-packages script renders as valid bash" {
  skip_if_no_chezmoi
  local script="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl"
  [[ -f "$script" ]] || skip "install-packages script not found at $script"

  BATS_TEST_TMPFILE="$(mktemp /tmp/install-packages-XXXXXX.sh)"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" execute-template < "$script" > "$BATS_TEST_TMPFILE"
  run bash -n "$BATS_TEST_TMPFILE"
  assert_success
}

@test "install-packages script uses set -e" {
  local script="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl"
  [[ -f "$script" ]] || skip "install-packages script not found at $script"
  run grep -q "set -e" "$script"
  assert_success
}

@test "install-packages template has no rendering errors" {
  skip_if_no_chezmoi
  local script="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl"
  [[ -f "$script" ]] || skip "install-packages script not found at $script"
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" execute-template < "$script"
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

@test "macos-tunes script uses set -e" {
  local script="$SOURCE_ROOT/.chezmoiscripts/darwin/run_once_after_macos-tunes.sh"
  run grep -q "set -e" "$script"
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
    if [ -n "${STUB_AGENTS_JSON:-}" ]; then printf '%s\n' "$STUB_AGENTS_JSON"
    else printf '{"result":{"agents":[]}}\n'
    fi ;;
  "pane split")
    [ "${STUB_SPLIT_FAIL:-0}" = 1 ] && exit 1
    printf '{"result":{"pane":{"pane_id":"wT:p9"}}}\n' ;;
  "agent start")
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
    if [ "${STUB_LABEL:-0}" = 1 ]; then
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
  run child_start --kind claude --name child-a --wait --timeout 5000
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
  assert_output 1
  run grep -c '^pane close' "$CHILD_STUB/calls.log"
  assert_output 1
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

# Build a sandbox with a stub `herdr` that records its argv. PATH is pinned to
# the stub directory plus the system directories, so a real `pi` or `claude`
# outside them can never be reached: a missing engine is then a property of the
# test, not of the machine that runs it.
hts_setup() {
  HTS_WORK="$(mktemp -d "${BATS_TMPDIR:-/tmp}/hts.XXXXXX")"
  HTS_STUB="$HTS_WORK/stub"
  HTS_STATE="$HTS_WORK/state"
  HTS_LOG="$HTS_WORK/herdr.log"
  mkdir -p "$HTS_STUB" "$HTS_STATE"
  : > "$HTS_LOG"
  # `pane list`, `pane process-info` and `tab list` are the herdr calls whose
  # answers the engine reads back, so the stub records every call and replays a
  # fixture for those three.
  cat > "$HTS_STUB/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HTS_LOG"
if [ "\$1" = "pane" ] && [ "\$2" = "list" ]; then
  cat "$HTS_WORK/pane-list.json" 2>/dev/null
fi
if [ "\$1" = "pane" ] && [ "\$2" = "process-info" ]; then
  cat "$HTS_WORK/proc-\$4.json" 2>/dev/null
fi
if [ "\$1" = "tab" ] && [ "\$2" = "list" ]; then
  cat "$HTS_WORK/tab-list.json" 2>/dev/null
fi
exit 0
SH
  chmod +x "$HTS_STUB/herdr"
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
  env PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_ENV=1 \
    HERDR_PANE_ID=pane-1 \
    HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    HERDR_TASK_SYNC_TIMEOUT="${HTS_TIMEOUT:-5}" \
    bash "$HTS_ENGINE" "$@"
}

hts_pane_list() {
  printf '%s' "$1" > "$HTS_WORK/pane-list.json"
}

# $1 = pane id, $2 = the `pane process-info` payload the stub replays for it
hts_proc_info() {
  printf '%s' "$2" > "$HTS_WORK/proc-$1.json"
}

hts_tab_list() {
  printf '%s' "$1" > "$HTS_WORK/tab-list.json"
}

# The sweep modes carry no agent and no pane, so they run the script directly
# rather than through hts_run.
hts_sweep_run() {
  env PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    HERDR_TASK_SYNC_SWEEP_INTERVAL="${HTS_SWEEP_INTERVAL:-1}" \
    bash "$HTS_ENGINE" "$@"
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

# The worker keeps logging after it publishes: compose_tab_label runs `pane
# list` and renames the tab when the label changed. A test that truncates the
# log between two sessions must wait for that tail, or a straggler write from
# the first worker lands in the freshly emptied log and the next wait returns
# on it.
hts_wait_for_worker_exit() {
  hts_wait_for_publish && hts_wait_for_call 'pane list'
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

hts_state_file() {
  printf '%s/%s.state' "$HTS_STATE" "$1"
}

hts_state_field() {
  grep -m1 "^${2}=" "$1" | cut -d= -f2- | base64 -d
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
  local state; state="$(hts_state_file claude-pane-1-s1)"
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
  : > "$HTS_LOG"
  hts_run --agent claude --session s1 <<< 'продолжай'
  hts_wait_for_publish
  assert_equal "$(hts_token)" "cache-review"
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
  local state before
  state="$(hts_state_file claude-pane-1-s1)"
  before="$(cat "$state")"

  rm -f "$HTS_STUB/pi"
  : > "$HTS_LOG"
  run hts_run --agent claude --session s1 <<< 'now fix the flaky login test'
  assert_success
  sleep 2
  assert_equal "$(cat "$HTS_LOG")" ""
  assert_equal "$(cat "$state")" "$before"
}

@test "herdr-task-sync resets the stored context on a new session id" {
  hts_setup
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_worker_exit
  : > "$HTS_LOG"
  hts_run --agent claude --session s2 <<< 'now fix the flaky login test'
  local state; state="$(hts_state_file claude-pane-1-s2)"
  # The second session's own state file, not the log: with two sessions in
  # play only a session-scoped signal proves whose worker got this far.
  hts_wait_for_state "$state"
  hts_wait_for_publish
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
  local state; state="$(hts_state_file pi-pane-1-pis1)"
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
  assert_output "tab rename tab-1 first · second"
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
  assert_output "tab rename tab-1 agent-label · bun run dev"
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
  assert_output "tab rename tab-1 agent-label · ~"
}

# The naming call knows one tab and not its position, so it cannot number a
# placeholder. It leaves an all-idle tab to the sweep, which can.
@test "herdr-task-sync leaves an all-idle tab label to the sweep" {
  command -v jq >/dev/null || skip "jq not available"
  hts_setup
  hts_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":null,"label":null}]}}'
  hts_proc_info pane-1 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hts_stub_engine pi cache-review 0 0
  hts_run --agent claude --session s1 <<< 'review the cache layer please'
  hts_wait_for_call 'pane rename pane-1 ~'
  sleep 1
  run cat "$HTS_LOG"
  refute_output --partial "tab rename"
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
  local live=$!
  mkdir -p "$HTS_STATE/sweep.lock"
  printf '%s' "$live" > "$HTS_STATE/sweep.lock/pid"
  run hts_sweep_run --ensure-daemon
  assert_success
  assert_equal "$(cat "$HTS_STATE/sweep.lock/pid")" "$live"
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
  mkdir -p "$HTS_STATE/sweep.lock"
  # A pid that cannot be running: process ids are allocated from 1 upwards.
  printf '%s' "999999" > "$HTS_STATE/sweep.lock/pid"
  run hts_sweep_run --ensure-daemon
  assert_success
  hts_wait_for_call 'tab rename'
  local pid; pid="$(cat "$HTS_STATE/sweep.lock/pid" 2>/dev/null)"
  [ -n "$pid" ] && [ "$pid" != "999999" ]
  kill "$pid" 2>/dev/null || true
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

@test "settings template wires the task-sync hook to all three events" {
  skip_if_no_chezmoi
  local tmpl="$SOURCE_ROOT/private_dot_claude/private_settings.json.tmpl"
  BATS_TEST_TMPFILE="$(mktemp /tmp/claude-settings-XXXXXX.json)"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" execute-template < "$tmpl" > "$BATS_TEST_TMPFILE"
  run python3 - "$BATS_TEST_TMPFILE" <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
def commands(event):
    return [h["command"] for entry in hooks[event] for h in entry["hooks"]]

for event, action in (("UserPromptSubmit", "prompt"),
                      ("SessionStart", "session"),
                      ("PreCompact", "compact")):
    matching = [c for c in commands(event) if "herdr-task-sync-hook.sh" in c]
    assert len(matching) == 1, (event, commands(event))
    assert matching[0].endswith(f"' {action}"), (event, matching[0])

# UserPromptSubmit has no matcher support; the herdr agent-state SessionStart
# hook must stay wired alongside the new one.
assert all("matcher" not in e for e in hooks["UserPromptSubmit"]), hooks["UserPromptSubmit"]
assert any("herdr-agent-state.sh" in c for c in commands("SessionStart")), commands("SessionStart")
PY
  assert_success
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
  run env SE_SMITHERS_DIR="$smithers_dir" "$se_bin" blocks --json
  assert_success
  assert_output --partial '"secret-scan"'
  assert_output --partial '"code-review"'
  # KTD6 JSON-Schema limitation note travels with the catalog.
  assert_output --partial 'runtime-parses'
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
