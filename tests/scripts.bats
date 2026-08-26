#!/usr/bin/env bats

load 'helpers/common'
load 'helpers/herdr_pane_labels'

setup() {
  unset HERDR_CHILD_NAME
  unset HERDR_CHILD_PARENT_PANE
}

teardown() {
  hpl_teardown
  [[ -n "${BATS_TEST_TMPFILE:-}" ]] && rm -f "$BATS_TEST_TMPFILE" || true
  [[ -n "${CHILD_STUB:-}" ]] && rm -rf "$CHILD_STUB" || true
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
# Herdr alias allocator
# ===========================================

HERDR_ALIASES="$SOURCE_ROOT/dot_local/lib/herdr-aliases.sh"

@test "herdr alias library parses and exposes its source API" {
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

@test "herdr alias grammar validation is separate from exact pool membership" {
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

@test "herdr alias pool has at least 1024 unique grammar-safe candidates" {
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

@test "herdr alias fixed test seed produces one stable full sequence without state" {
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

@test "herdr alias traversal wraps to the last free candidate and exhausts once" {
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

@test "herdr alias allocation consults no Herdr model or network command" {
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

@test "ask.sh performs no agent-list preflight or query and verifies the returned pair twice" {
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" claude question
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
  run grep -q 'herdr agent list' "$ASK_HERDR_DIR/ask.sh"
  assert_failure
}

@test "ask.sh discards buffered output when either pair validation fails" {
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_PAIR_FAIL_AT=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" claude question
  assert_failure 1
  refute_output --partial "ANSWER from child"
  assert_output --partial "status=undelivered"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_PAIR_TERMINAL_CHANGE_AT=2 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_DIR/ask.sh" claude question
  assert_failure 1
  refute_output --partial "ANSWER from child"
  assert_output --partial "output discarded"
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
record_split() {
  count=0; [ ! -f "$CHILD_STUB/split-count" ] || read -r count < "$CHILD_STUB/split-count"
  count=$((count + 1)); printf '%s\n' "$count" > "$CHILD_STUB/split-count"
  pane="wT:p$((count + 8))"; terminal="term-child-$count"
  printf '%s\t%s\n' "$pane" "$terminal" >> "$CHILD_STUB/panes"
}
token_file_for() {
  printf '%s/token-%s' "$CHILD_STUB" "$(printf '%s' "$1" | tr ':' '_')"
}
case "${1:-} ${2:-}" in
  "agent list")
    if [ -n "${STUB_AGENTS_JSON_FILE_FIRST:-}" ] && [ ! -f "$CHILD_STUB/list-once" ]; then
      : > "$CHILD_STUB/list-once"
      cat "$STUB_AGENTS_JSON_FILE_FIRST"
    elif [ -n "${STUB_AGENTS_JSON_FIRST:-}" ] && [ ! -f "$CHILD_STUB/list-once" ]; then
      : > "$CHILD_STUB/list-once"
      printf '%s\n' "$STUB_AGENTS_JSON_FIRST"
    elif [ -n "${STUB_AGENTS_JSON_FILE_SECOND:-}" ]; then
      cat "$STUB_AGENTS_JSON_FILE_SECOND"
    elif [ -n "${STUB_AGENTS_JSON_SECOND:-}" ]; then
      printf '%s\n' "$STUB_AGENTS_JSON_SECOND"
    elif [ -n "${STUB_AGENTS_JSON_FILE:-}" ]; then cat "$STUB_AGENTS_JSON_FILE"
    elif [ -n "${STUB_AGENTS_JSON:-}" ]; then printf '%s\n' "$STUB_AGENTS_JSON"
    elif [ -f "$CHILD_STUB/collision-record" ]; then
      IFS=$'\t' read -r name pane terminal < "$CHILD_STUB/collision-record"
      printf '{"result":{"agents":[{"name":"%s","pane_id":"%s","agent":"claude","terminal_id":"%s","revision":1,"state_change_seq":1,"agent_status":"working","focused":false}]}}\n' "$name" "$pane" "$terminal"
    elif [ -f "$CHILD_STUB/registered-record" ]; then
      IFS=$'\t' read -r name pane terminal kind < "$CHILD_STUB/registered-record"
      printf '{"result":{"agents":[{"name":"%s","pane_id":"%s","agent":"%s","terminal_id":"%s","revision":1,"state_change_seq":1,"agent_status":"idle","focused":false}]}}\n' "$name" "$pane" "$kind" "$terminal"
    else printf '{"result":{"agents":[]}}\n'
    fi ;;
  "pane split")
    [ "${STUB_SPLIT_FAIL:-0}" = 1 ] && exit 1
    : > "$CHILD_STUB/split-seen"
    record_split
    printf '{"result":{"pane":{"pane_id":"%s","terminal_id":"%s"}}}\n' "$pane" "$terminal" ;;
  "tab create")
    [ "${STUB_TAB_CREATE_FAIL:-0}" = 1 ] && exit 1
    : > "$CHILD_STUB/split-seen"
    record_split
    tab="wT:t$((count + 8))"
    printf '%s\t%s\n' "$pane" "$tab" >> "$CHILD_STUB/pane-tabs"
    if [ "${STUB_TAB_CREATE_MALFORMED:-0}" = 1 ]; then
      printf '{"result":{"root_pane":{"pane_id":"%s"},"tab":{"tab_id":"%s"}}}\n' "$pane" "$tab"
    else
      printf '{"result":{"root_pane":{"pane_id":"%s","terminal_id":"%s"},"tab":{"tab_id":"%s"}}}\n' "$pane" "$terminal" "$tab"
    fi ;;
  "agent start")
    if [ "${STUB_REQUIRE_SPLIT:-0}" = 1 ] && [ ! -f "$CHILD_STUB/split-seen" ]; then
      printf 'agent start before pane split\n' >&2
      exit 1
    fi
    if [ "${STUB_START_BLOCK:-0}" = 1 ]; then
      : > "$CHILD_STUB/start-blocked"
      for _ in $(seq 1 200); do [ -f "$CHILD_STUB/start-release" ] && break; sleep 0.01; done
      if [ ! -f "$CHILD_STUB/start-release" ]; then
        printf '{"error":{"code":"timeout","message":"startup timed out"}}\n' >&2
        exit 1
      fi
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
    name="$3"; pane=""; kind=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --pane) pane="$2"; shift 2 ;;
        --kind) kind="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    terminal="$(awk -F '\t' -v pane="$pane" '$1==pane {print $2; exit}' "$CHILD_STUB/panes")"
    if [ "${STUB_START_MODE:-ok}" = collision-once ] && [ ! -f "$CHILD_STUB/collision-once" ]; then
      : > "$CHILD_STUB/collision-once"
      printf '%s\t%s\t%s\n' "$name" wT:p8 term-other > "$CHILD_STUB/collision-record"
      printf '{"error":{"code":"agent_name_taken","message":"name is already live"}}\n' >&2
      exit 1
    fi
    if [ "${STUB_START_MODE:-ok}" = collision ]; then
      printf '%s\t%s\t%s\n' "$name" wT:p8 term-other > "$CHILD_STUB/collision-record"
      printf '{"error":{"code":"agent_name_taken","message":"name is already live"}}\n' >&2
      exit 1
    fi
    if [ "${STUB_START_MODE:-ok}" = error-with-occupation ]; then
      printf '%s\t%s\t%s\n' "$name" wT:p8 term-other > "$CHILD_STUB/collision-record"
      printf '{"error":{"code":"timeout","message":"startup timed out"}}\n' >&2
      exit 1
    fi
    rm -f "$CHILD_STUB/collision-record"
    printf '%s\t%s\t%s\t%s\n' "$name" "$pane" "$terminal" "$kind" > "$CHILD_STUB/registered-record"
    printf '{"result":{"agent":{"interactive_ready":true}}}\n' ;;
  "agent prompt")
    [ "${STUB_PROMPT_FAIL:-0}" = 1 ] && { printf '{"error":{"code":"agent_prompt_stalled"}}\n' >&2; exit 1; }
    [ "${STUB_PROMPT_TIMEOUT:-0}" = 1 ] && { printf '{"error":{"code":"timeout"}}\n' >&2; exit 1; }
    if [ "${STUB_PROMPT_BLOCK:-0}" = 1 ]; then
      : > "$CHILD_STUB/prompt-blocked"
      for _ in $(seq 1 200); do [ -f "$CHILD_STUB/prompt-release" ] && break; sleep 0.01; done
    fi
    printf '{"result":{"agent":{"agent_status":"idle"}}}\n' ;;
  "pane report-metadata")
    [ "${STUB_REPORT_FAIL:-0}" = 1 ] && exit 1
    pane="$3"; shift 3
    token_file="$(token_file_for "$pane")"
    while [ $# -gt 0 ]; do
      case "$1" in
        --token) printf '%s' "$2" > "$token_file"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '{"result":{"type":"pane_metadata_reported"}}\n' ;;
  "pane get")
    pane="$3"
    terminal="${STUB_PANE_TERMINAL:-term-child}"
    tab_id=""
    token_field=""
    if [ -f "$CHILD_STUB/panes" ]; then
      found="$(awk -F '\t' -v pane="$pane" '$1==pane {print $2; exit}' "$CHILD_STUB/panes")"
      [ -z "$found" ] || terminal="$found"
    fi
    if [ -f "$CHILD_STUB/pane-tabs" ]; then
      tab_id="$(awk -F '\t' -v pane="$pane" '$1==pane {print $2; exit}' "$CHILD_STUB/pane-tabs")"
    fi
    [ "${STUB_TAB_ID_OVERRIDE:-0}" = 0 ] || tab_id="$STUB_TAB_ID_OVERRIDE"
    [ "${STUB_TERMINAL_CHANGED:-0}" = 0 ] || terminal=term-replaced
    token_file="$(token_file_for "$pane")"
    if [ -f "$token_file" ]; then
      token_kv="$(cat "$token_file")"
      token_name="${token_kv%%=*}"
      token_value="${token_kv#*=}"
      token_field=",\"tokens\":{\"$token_name\":\"$token_value\"}"
    fi
    if [ "${STUB_PANE_GET_MALFORMED:-0}" = 1 ]; then
      printf 'not json\n'
    elif [ "${STUB_LABEL:-0}" = 1 ]; then
      printf '{"result":{"pane":{"pane_id":"%s","terminal_id":"%s","tab_id":"%s","state_labels":{"blocked":"waiting for parent"}%s}}}\n' "$pane" "$terminal" "$tab_id" "$token_field"
    else
      printf '{"result":{"pane":{"pane_id":"%s","terminal_id":"%s","tab_id":"%s"%s}}}\n' "$pane" "$terminal" "$tab_id" "$token_field"
    fi ;;
  "pane close")
    if [ "${STUB_CLOSE_STATUS:-0}" != 0 ]; then
      printf '{"error":{"code":"%s","message":"close failed"}}\n' "${STUB_CLOSE_ERROR:-generic_error}" >&2
      exit "${STUB_CLOSE_STATUS}"
    fi
    exit 0 ;;
  "tab get")
    tab_arg="$3"
    if [ "${STUB_TAB_GET_FAIL:-0}" = 1 ]; then
      printf '{"error":{"code":"%s","message":"tab not found"}}\n' "${STUB_TAB_GET_ERROR:-tab_not_found}" >&2
      exit 1
    fi
    if [ "${STUB_TAB_PANE_COUNT_MALFORMED:-0}" = 1 ]; then
      printf '{"result":{"tab":{"tab_id":"%s"}}}\n' "$tab_arg"
    else
      printf '{"result":{"tab":{"tab_id":"%s","pane_count":%s}}}\n' "$tab_arg" "${STUB_TAB_PANE_COUNT:-1}"
    fi ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$CHILD_STUB/herdr"
}

child_start() {
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 HERDR_SOCKET_PATH=/tmp/herdr-u3.sock \
    HERDR_ALIAS_TEST_SEED=u3-child-seed \
    bash "$HERDR_CHILD" start "$@" --prompt "test task"
}

child_start_tab() {
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 HERDR_SOCKET_PATH=/tmp/herdr-u3.sock \
    HERDR_ALIAS_TEST_SEED=u3-child-seed HERDR_WORKSPACE_ID=wT \
    bash "$HERDR_CHILD" start "$@" --tab --prompt "test task"
}

child_first_alias() {
  HERDR_ALIAS_TEST_SEED=u3-child-seed bash -c 'source "$1"; herdr_alias_candidates ignored' _ "$HERDR_ALIASES" | sed -n '1p'
}

complete_agent_record() {
  local name="$1" pane="$2" terminal="$3" status="${4:-idle}" focused="${5:-false}" kind="${6:-claude}"
  printf '{"result":{"agents":[{"name":"%s","pane_id":"%s","agent":"%s","terminal_id":"%s","revision":1,"state_change_seq":1,"agent_status":"%s","focused":%s}]}}' \
    "$name" "$pane" "$kind" "$terminal" "$status" "$focused"
}

token_file_for() {
  printf '%s/token-%s' "$CHILD_STUB" "$(printf '%s' "$1" | tr ':' '_')"
}

seed_tab_token() {
  local pane="$1" tab="$2"
  printf 'tab-id=%s' "$tab" > "$(token_file_for "$pane")"
  printf '%s\t%s\n' "$pane" "$tab" >> "$CHILD_STUB/pane-tabs"
}

write_pool_records() {
  local output="$1" skip_alias="${2:-}" alias first=1 index=0
  printf '{"result":{"agents":[' > "$output"
  while IFS= read -r alias; do
    [ "$alias" = "$skip_alias" ] && continue
    [ "$first" -eq 1 ] || printf ',' >> "$output"
    first=0
    printf '{"name":"%s","pane_id":"pool:p%s","agent":"claude","terminal_id":"term-pool-%s","revision":1,"state_change_seq":1,"agent_status":"idle","focused":false}' \
      "$alias" "$index" "$index" >> "$output"
    index=$((index + 1))
  done < <(HERDR_ALIAS_TEST_SEED=u3-child-seed bash -c 'source "$1"; herdr_alias_candidates ignored' _ "$HERDR_ALIASES")
  printf ']}}\n' >> "$output"
}

@test "herdr-child requires a subcommand and herdr environment" {
  run bash "$HERDR_CHILD"
  assert_failure 2
  assert_output --partial "Usage:"

  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV= HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" start --kind claude --prompt task
  assert_failure
  [ ! -f "$CHILD_STUB/calls.log" ]
}

@test "herdr-child refuses pi read-only before splitting a pane" {
  child_stub_herdr
  run child_start --kind pi --posture ro
  assert_failure 2
  assert_output --partial "return channel requires bash"
  [ ! -f "$CHILD_STUB/calls.log" ]
}

@test "herdr-child help exposes verify and start options reject the removed --name flag" {
  child_stub_herdr
  run bash "$HERDR_CHILD" --help
  assert_success
  refute_output --partial "--name"
  assert_output --partial "herdr-child verify --to <alias> --pane <pane-id>"

  run child_start --kind claude --name legacy-name
  assert_failure 2
  assert_output --partial "unknown start option: --name"
  [ ! -f "$CHILD_STUB/calls.log" ]
}

@test "herdr-child --tab rejects an explicit --direction and requires HERDR_WORKSPACE_ID" {
  child_stub_herdr
  run child_start --kind claude --tab --direction right
  assert_failure 2
  assert_output --partial "--tab cannot be combined with an explicit --direction"
  [ ! -f "$CHILD_STUB/calls.log" ]

  child_stub_herdr
  run child_start --kind claude --label spike
  assert_failure 2
  assert_output --partial "--label requires --tab"
  [ ! -f "$CHILD_STUB/calls.log" ]

  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 HERDR_SOCKET_PATH=/tmp/herdr-u3.sock \
    HERDR_ALIAS_TEST_SEED=u3-child-seed HERDR_WORKSPACE_ID= \
    bash "$HERDR_CHILD" start --kind claude --tab --prompt "test task"
  assert_failure 2
  assert_output --partial "--tab requires HERDR_WORKSPACE_ID"
  [ ! -f "$CHILD_STUB/calls.log" ]
}

@test "herdr-child --tab passes argument validation before any mutating call" {
  child_stub_herdr
  local occupied="$BATS_TEST_TMPDIR/u2-tab-occupied.json"
  write_pool_records "$occupied"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 HERDR_SOCKET_PATH=/tmp/herdr-u3.sock \
    HERDR_ALIAS_TEST_SEED=u3-child-seed HERDR_WORKSPACE_ID=w4 STUB_AGENTS_JSON_FILE="$occupied" \
    bash "$HERDR_CHILD" start --kind claude --tab --prompt "test task"
  assert_failure
  refute_output --partial "Usage:"
  assert_output --partial "alias pool is exhausted"
  run grep -q '^pane split' "$CHILD_STUB/calls.log"
  assert_failure
  run grep -q '^tab create' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child verify accepts only one complete matching alias-pane pair" {
  child_stub_herdr
  local agents; agents="$(complete_agent_record child-a wT:p9 term-child)"
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" verify --to child-a --pane wT:p9
  assert_success
  assert_output term-child

  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" verify --to child-a --pane wT:p8
  assert_failure
  assert_output --partial "alias and pane do not identify the same live agent"

  child_stub_herdr
  local incomplete='{"result":{"agents":[{"name":"child-a","pane_id":"wT:p9"}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$incomplete" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" verify --to child-a --pane wT:p9
  assert_failure
  assert_output --partial "live agent records are incomplete"

  child_stub_herdr
  local duplicate_names='{"result":{"agents":[{"name":"child-a","pane_id":"wT:p9","agent":"claude","terminal_id":"term-1","revision":1,"state_change_seq":1},{"name":"child-a","pane_id":"wT:p10","agent":"opencode","terminal_id":"term-2","revision":1,"state_change_seq":1}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$duplicate_names" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" verify --to child-a --pane wT:p9
  assert_failure
  assert_output --partial "live agent records are incomplete"
}

@test "herdr-child rejects incomplete live records before splitting" {
  child_stub_herdr
  STUB_AGENTS_JSON='{"result":{"agents":[{"name":"red-wolf","pane_id":"wT:p8"}]}}' \
    run child_start --kind claude
  assert_failure
  assert_output --partial "live agent records are incomplete"
  run grep -q '^pane split' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child maps claude postures and skill directories" {
  child_stub_herdr
  local alias; alias="$(child_first_alias)"
  run child_start --kind claude --skills A --skills B
  assert_success
  assert_output "{\"agent\":\"$alias\",\"pane\":\"wT:p9\"}"
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--add-dir A --add-dir B.*--disallowed-tools Edit Write NotebookEdit AskUserQuestion'

  : > "$CHILD_STUB/calls.log"
  run child_start --kind claude --posture rw
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--disallowed-tools AskUserQuestion'
  run grep -q 'disallowed-tools Edit' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child maps opencode permissions, model, and configured agent" {
  child_stub_herdr
  run child_start --kind opencode --agent reviewer
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'OPENCODE_PERMISSION=.*question.*deny.*edit.*deny'
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--model openai/gpt-5.5 --agent reviewer'

  : > "$CHILD_STUB/calls.log"
  run child_start --kind opencode --posture rw
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'OPENCODE_PERMISSION=.*question.*deny'
  run grep -q 'OPENCODE_PERMISSION=.*edit' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child maps pi model, effort, skills, and question exclusion" {
  child_stub_herdr
  run child_start --kind pi --posture rw --skills A --skills B
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--exclude-tools ask_user --model openai-codex/gpt-5.5 --thinking medium --skill A --skill B'

  : > "$CHILD_STUB/calls.log"
  run child_start --kind pi --posture rw --model custom/model --effort high
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--model custom/model --thinking high'
}

@test "herdr-child returns a pool alias for every supported child kind" {
  local kind posture alias
  alias="$(child_first_alias)"
  for kind in claude opencode pi; do
    child_stub_herdr
    posture=ro
    [ "$kind" != pi ] || posture=rw
    run child_start --kind "$kind" --posture "$posture"
    assert_success
    assert_output "{\"agent\":\"$alias\",\"pane\":\"wT:p9\"}"
    assert_file_contains "$CHILD_STUB/calls.log" "HERDR_CHILD_NAME=$alias"
  done
}

@test "herdr-child rejects native options that the selected kind cannot map" {
  child_stub_herdr
  run child_start --kind claude --effort high
  assert_failure 2
  assert_output --partial "--effort is not supported for claude"
  run child_start --kind pi --posture rw --agent reviewer
  assert_failure 2
  assert_output --partial "--agent is not supported for pi"
  run child_start --kind opencode --skills A
  assert_failure 2
  assert_output --partial "--skills is not supported for opencode"
  [ ! -f "$CHILD_STUB/calls.log" ]
}

@test "herdr-child splits, starts, and prompts in order with both coordinates" {
  child_stub_herdr
  local alias; alias="$(child_first_alias)"
  STUB_REQUIRE_SPLIT=1 run child_start --kind claude --wait --timeout 5000
  assert_success
  local call1 call2 call3 call4 call5
  call1="$(sed -n '1p' "$CHILD_STUB/calls.log")"
  call2="$(sed -n '2p' "$CHILD_STUB/calls.log")"
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  call4="$(sed -n '4p' "$CHILD_STUB/calls.log")"
  call5="$(sed -n '5p' "$CHILD_STUB/calls.log")"
  [[ "$call1" == agent\ list* ]]
  [[ "$call2" == pane\ split*HERDR_CHILD_NAME="$alias"*HERDR_CHILD_PARENT_PANE=wT:p0* ]]
  [[ "$call3" == agent\ start* ]]
  [[ "$call4" == agent\ list* ]]
  [[ "$call5" == agent\ prompt\ wT:p9*"$alias"*wT:p9*wT:p0*--wait*--timeout\ 5000* ]]
}

@test "herdr-child --tab creates a tab, records ownership, and prompts in order" {
  child_stub_herdr
  local alias; alias="$(child_first_alias)"
  STUB_REQUIRE_SPLIT=1 run child_start_tab --kind claude --wait --timeout 5000
  assert_success
  assert_output "{\"agent\":\"$alias\",\"pane\":\"wT:p9\",\"tab\":\"wT:t9\"}"
  local call1 call2 call3 call4 call5 call6
  call1="$(sed -n '1p' "$CHILD_STUB/calls.log")"
  call2="$(sed -n '2p' "$CHILD_STUB/calls.log")"
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  call4="$(sed -n '4p' "$CHILD_STUB/calls.log")"
  call5="$(sed -n '5p' "$CHILD_STUB/calls.log")"
  call6="$(sed -n '6p' "$CHILD_STUB/calls.log")"
  [[ "$call1" == agent\ list* ]]
  [[ "$call2" == tab\ create*--workspace\ wT*HERDR_CHILD_NAME="$alias"*HERDR_CHILD_PARENT_PANE=wT:p0* ]]
  [[ "$call3" == pane\ report-metadata\ wT:p9*--source\ child-agent-tab*--token\ tab-id=wT:t9* ]]
  [[ "$call4" == agent\ start* ]]
  [[ "$call5" == agent\ list* ]]
  [[ "$call6" == agent\ prompt\ wT:p9* ]]
  run grep -q '^pane split' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child --tab passes --label to tab create and omits it when unset" {
  child_stub_herdr
  run child_start_tab --kind claude --label spike
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" '^tab create .*--label spike'

  child_stub_herdr
  run child_start_tab --kind claude
  assert_success
  run grep -q '\-\-label' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child --tab forwards opencode posture env to tab create" {
  child_stub_herdr
  run child_start_tab --kind opencode
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" '^tab create.*OPENCODE_PERMISSION=.*question.*deny.*edit.*deny'
}

@test "herdr-child --tab preserves the tab and reports its id when identity cannot be parsed" {
  child_stub_herdr
  STUB_TAB_CREATE_MALFORMED=1 run child_start_tab --kind claude
  assert_failure
  assert_output --partial "preserving tab wT:t9"
  run grep -q '^pane report-metadata' "$CHILD_STUB/calls.log"
  assert_failure
  run grep -q '^agent start' "$CHILD_STUB/calls.log"
  assert_failure
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child --tab cleans up the tab when the ownership token cannot be written" {
  child_stub_herdr
  STUB_REPORT_FAIL=1 run child_start_tab --kind claude
  assert_failure
  assert_output --partial "tab ownership token could not be written"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
  run grep -q '^agent start' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child --tab reports the tab id on a wait timeout" {
  child_stub_herdr
  local alias; alias="$(child_first_alias)"
  STUB_PROMPT_TIMEOUT=1 run child_start_tab --kind claude --wait
  assert_failure 124
  assert_output --partial "{\"agent\":\"$alias\",\"pane\":\"wT:p9\",\"tab\":\"wT:t9\"}"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child caps startup timeout while preserving a long prompt wait" {
  child_stub_herdr
  run child_start --kind claude --wait --timeout 1800000
  assert_success
  local start_call prompt_call
  start_call="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  prompt_call="$(sed -n '5p' "$CHILD_STUB/calls.log")"
  [[ "$start_call" == *--timeout\ 300000* ]]
  [[ "$prompt_call" == *--timeout\ 1800000* ]]
}

@test "herdr-child retries only the pane-readiness start failure" {
  child_stub_herdr
  STUB_START_MODE=busy-once run child_start --kind claude
  assert_success
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 2

  child_stub_herdr
  STUB_START_MODE=error run child_start --kind claude
  assert_failure
  assert_output --partial "agent start failed"
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 1
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

@test "herdr-child start closes the split pane on a real signal before registration succeeds" {
  child_stub_herdr
  local out="$BATS_TEST_TMPDIR/out" err="$BATS_TEST_TMPDIR/err" child_pid status
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 HERDR_SOCKET_PATH=/tmp/herdr-u3.sock \
    HERDR_ALIAS_TEST_SEED=u3-child-seed STUB_START_BLOCK=1 \
    bash "$HERDR_CHILD" start --kind claude --prompt "test task" >"$out" 2>"$err" &
  child_pid=$!
  hpl_wait_for_file "$CHILD_STUB/start-blocked"
  kill -TERM "$child_pid"
  status=0
  wait "$child_pid" || status=$?
  [ "$status" -eq 130 ]
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 1
  run grep -c '^agent prompt' "$CHILD_STUB/calls.log"
  assert_output 0
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
  run grep -q 'preserving pane' "$err"
  assert_failure
}

@test "herdr-child --tab removes the tab on a real signal before registration succeeds" {
  child_stub_herdr
  local out="$BATS_TEST_TMPDIR/out" err="$BATS_TEST_TMPDIR/err" child_pid status
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 HERDR_SOCKET_PATH=/tmp/herdr-u3.sock \
    HERDR_ALIAS_TEST_SEED=u3-child-seed HERDR_WORKSPACE_ID=wT STUB_START_BLOCK=1 \
    bash "$HERDR_CHILD" start --kind claude --tab --prompt "test task" >"$out" 2>"$err" &
  child_pid=$!
  hpl_wait_for_file "$CHILD_STUB/start-blocked"
  kill -TERM "$child_pid"
  status=0
  wait "$child_pid" || status=$?
  [ "$status" -eq 130 ]
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
  run grep -q '^tab close' "$CHILD_STUB/calls.log"
  assert_failure
  run grep -q 'preserving pane' "$err"
  assert_failure
}

@test "herdr-child start closes the registered pane on a real signal during the initial prompt" {
  child_stub_herdr
  local out="$BATS_TEST_TMPDIR/out" err="$BATS_TEST_TMPDIR/err" child_pid status
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 HERDR_SOCKET_PATH=/tmp/herdr-u3.sock \
    HERDR_ALIAS_TEST_SEED=u3-child-seed STUB_PROMPT_BLOCK=1 \
    bash "$HERDR_CHILD" start --kind claude --wait --prompt "test task" >"$out" 2>"$err" &
  child_pid=$!
  hpl_wait_for_file "$CHILD_STUB/prompt-blocked"
  kill -TERM "$child_pid"
  status=0
  wait "$child_pid" || status=$?
  [ "$status" -eq 130 ]
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 1
  run grep -c '^agent prompt' "$CHILD_STUB/calls.log"
  assert_output 1
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
  run grep -q 'preserving pane' "$err"
  assert_failure
}

@test "herdr-child --tab removes the tab on a real signal during the initial prompt" {
  child_stub_herdr
  local out="$BATS_TEST_TMPDIR/out" err="$BATS_TEST_TMPDIR/err" child_pid status
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 HERDR_SOCKET_PATH=/tmp/herdr-u3.sock \
    HERDR_ALIAS_TEST_SEED=u3-child-seed HERDR_WORKSPACE_ID=wT STUB_PROMPT_BLOCK=1 \
    bash "$HERDR_CHILD" start --kind claude --tab --wait --prompt "test task" >"$out" 2>"$err" &
  child_pid=$!
  hpl_wait_for_file "$CHILD_STUB/prompt-blocked"
  kill -TERM "$child_pid"
  status=0
  wait "$child_pid" || status=$?
  [ "$status" -eq 130 ]
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
  run grep -q 'preserving pane' "$err"
  assert_failure
}

@test "herdr-child --tab removes the previous tab before creating the next on collision" {
  child_stub_herdr
  local second
  second="$(HERDR_ALIAS_TEST_SEED=u3-child-seed bash -c 'source "$1"; herdr_alias_candidates ignored' _ "$HERDR_ALIASES" | sed -n '2p')"
  STUB_START_MODE=collision-once run child_start_tab --kind claude
  assert_success
  assert_output "{\"agent\":\"$second\",\"pane\":\"wT:p10\",\"tab\":\"wT:t10\"}"
  run grep -c '^tab create' "$CHILD_STUB/calls.log"
  assert_output 2
  run grep -c '^pane close wT:p9' "$CHILD_STUB/calls.log"
  assert_output 1
}

@test "herdr-child --tab removes the tab after three readiness failures" {
  child_stub_herdr
  STUB_START_MODE=busy run child_start_tab --kind claude
  assert_failure
  assert_output --partial "three agent start attempts"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

@test "herdr-child retries an exact name collision with the next bounded candidate" {
  child_stub_herdr
  local first second
  first="$(child_first_alias)"
  second="$(HERDR_ALIAS_TEST_SEED=u3-child-seed bash -c 'source "$1"; herdr_alias_candidates ignored' _ "$HERDR_ALIASES" | sed -n '2p')"
  STUB_START_MODE=collision-once run child_start --kind claude
  assert_success
  assert_output "{\"agent\":\"$second\",\"pane\":\"wT:p10\"}"
  assert_file_contains "$CHILD_STUB/calls.log" "^agent start $first "
  assert_file_contains "$CHILD_STUB/calls.log" "^agent start $second "
  run grep -c '^pane split' "$CHILD_STUB/calls.log"
  assert_output 2
  run grep -c '^pane close wT:p9' "$CHILD_STUB/calls.log"
  assert_output 1
}

@test "herdr-child exhausts the initial pool without creating a pane" {
  child_stub_herdr
  local occupied="$BATS_TEST_TMPDIR/u3-all-occupied.json"
  write_pool_records "$occupied"
  STUB_AGENTS_JSON_FILE="$occupied" run child_start --kind claude
  assert_failure
  assert_output --partial "alias pool is exhausted"
  run grep -q '^pane split' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child closes one last-free collision pane and does not split again" {
  child_stub_herdr
  local first initial occupied
  first="$(child_first_alias)"
  initial="$BATS_TEST_TMPDIR/u3-last-free-initial.json"
  occupied="$BATS_TEST_TMPDIR/u3-last-free-occupied.json"
  write_pool_records "$initial" "$first"
  write_pool_records "$occupied"
  STUB_AGENTS_JSON_FILE_FIRST="$initial" STUB_AGENTS_JSON_FILE_SECOND="$occupied" \
    STUB_START_MODE=collision run child_start --kind claude
  assert_failure
  assert_output --partial "pool became exhausted"
  run grep -c '^pane split' "$CHILD_STUB/calls.log"
  assert_output 1
  run grep -c '^pane close wT:p9' "$CHILD_STUB/calls.log"
  assert_output 1
}

@test "herdr-child preserves an ambiguous collision pane" {
  child_stub_herdr
  STUB_START_MODE=collision STUB_TERMINAL_CHANGED=1 run child_start --kind claude
  assert_failure
  assert_output --partial "preserving collision pane wT:p9"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure

  child_stub_herdr
  local alias initial fresh
  alias="$(child_first_alias)"
  initial='{"result":{"agents":[]}}'
  fresh="{\"result\":{\"agents\":[{\"name\":\"$alias\",\"pane_id\":\"wT:p8\",\"agent\":\"claude\",\"terminal_id\":\"term-other\",\"revision\":1,\"state_change_seq\":1},{\"name\":\"blue-wolf\",\"pane_id\":\"wT:p9\",\"agent\":\"opencode\",\"terminal_id\":\"term-child-1\",\"revision\":1,\"state_change_seq\":1} ]}}"
  STUB_AGENTS_JSON_FIRST="$initial" STUB_AGENTS_JSON_SECOND="$fresh" STUB_START_MODE=collision \
    run child_start --kind claude
  assert_failure
  assert_output --partial "preserving collision pane wT:p9"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child never turns a generic failure into a collision retry" {
  child_stub_herdr
  STUB_START_MODE=error-with-occupation run child_start --kind claude
  assert_failure
  assert_output --partial "agent start failed"
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 1
  run grep -c '^pane split' "$CHILD_STUB/calls.log"
  assert_output 1
}

@test "herdr-child closes its pane after three readiness failures" {
  child_stub_herdr
  STUB_START_MODE=busy run child_start --kind claude
  assert_failure
  assert_output --partial "three agent start attempts"
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 3
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

@test "herdr-child distinguishes a stalled initial prompt" {
  child_stub_herdr
  STUB_PROMPT_FAIL=1 run child_start --kind claude --wait
  assert_failure
  assert_output --partial "initial prompt stalled"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

@test "herdr-child preserves a post-registration failure when terminal proof changed" {
  child_stub_herdr
  STUB_PROMPT_FAIL=1 STUB_TERMINAL_CHANGED=1 run child_start --kind claude --wait
  assert_failure
  assert_output --partial "accepted alias no longer has the captured terminal"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child --tab removes the tab when the initial prompt stalls" {
  child_stub_herdr
  STUB_PROMPT_FAIL=1 run child_start_tab --kind claude --wait
  assert_failure
  assert_output --partial "initial prompt stalled"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

@test "herdr-child --tab preserves the tab when terminal proof changed before the prompt" {
  child_stub_herdr
  STUB_PROMPT_FAIL=1 STUB_TERMINAL_CHANGED=1 run child_start_tab --kind claude --wait
  assert_failure
  assert_output --partial "accepted alias no longer has the captured terminal"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
  run grep -q '^tab close' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child verifies the accepted pair before dispatching the initial prompt" {
  child_stub_herdr
  local alias initial fresh
  alias="$(child_first_alias)"
  initial='{"result":{"agents":[]}}'
  fresh="$(complete_agent_record "$alias" wT:p9 term-replaced)"
  STUB_AGENTS_JSON_FIRST="$initial" STUB_AGENTS_JSON_SECOND="$fresh" run child_start --kind claude
  assert_failure
  assert_output --partial "alias, pane, or terminal changed before the initial prompt"
  run grep -q '^agent prompt' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child preserves a working pane when the wait times out" {
  child_stub_herdr
  local alias; alias="$(child_first_alias)"
  STUB_PROMPT_TIMEOUT=1 run child_start --kind claude --wait
  assert_failure 124
  assert_output --partial "{\"agent\":\"$alias\",\"pane\":\"wT:p9\"}"
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
  local agents='{"result":{"agents":[{"name":"red-bear","pane_id":"wT:p0","agent":"opencode","terminal_id":"term-parent","revision":1,"state_change_seq":1},{"name":"blue-otter","pane_id":"wT:p9","agent":"claude","terminal_id":"term-child","revision":2,"state_change_seq":2}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 \
    HERDR_PANE_ID=wT:p9 HERDR_CHILD_NAME=launch-alias HERDR_CHILD_PARENT_PANE=wT:p0 \
    bash "$HERDR_CHILD" ask "Which path?"
  assert_success
  local call1 call2 call3
  call1="$(sed -n '1p' "$CHILD_STUB/calls.log")"
  call2="$(sed -n '2p' "$CHILD_STUB/calls.log")"
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  [[ "$call1" == pane\ report-metadata*wT:p9*--source\ child-agent*--state-label*--ttl-ms\ 3600000* ]]
  [[ "$call2" == agent\ list* ]]
  [[ "$call3" == agent\ prompt*wT:p0*child-ask*agent=blue-otter*pane=wT:p9* ]]
  [[ "$call3" != *--wait* ]]
}

@test "herdr skill verifies and reuses the callback alias for the launch pane" {
  local skill="$SOURCE_ROOT/private_dot_claude/skills/herdr/SKILL.md"

  assert_file_contains "$skill" 'callback alias may differ from the launch alias'
  assert_file_contains "$skill" 'CALLBACK_ALIAS="\$CHILD_NAME"'
  assert_file_contains "$skill" 'herdr-child verify --to "\$CALLBACK_CANDIDATE" --pane "\$CHILD_PANE"'
  assert_file_contains "$skill" 'CALLBACK_ALIAS="\$CALLBACK_CANDIDATE"'
  assert_file_contains "$skill" 'herdr-child reply --to "\$CALLBACK_ALIAS" --pane "\$CHILD_PANE"'
  assert_file_contains "$skill" 'herdr-child reap --to "\$CALLBACK_ALIAS" --pane "\$CHILD_PANE"'
  run grep -E -- 'herdr-child (reply|reap) --to "\$CHILD_NAME"' "$skill"
  assert_failure
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
  local agents='{"result":{"agents":[{"name":"red-bear","pane_id":"wT:p0","agent":"opencode","terminal_id":"term-parent","revision":1,"state_change_seq":1},{"name":"blue-otter","pane_id":"wT:p9","agent":"claude","terminal_id":"term-child","revision":2,"state_change_seq":2}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PROMPT_FAIL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p9 HERDR_CHILD_NAME=child-a HERDR_CHILD_PARENT_PANE=wT:p0 \
    bash "$HERDR_CHILD" ask question
  assert_failure
  assert_output --partial "waiting label remains published"
}

@test "herdr-child reply validates the live pair, delivers, then clears" {
  child_stub_herdr
  local agents; agents="$(complete_agent_record child-a wT:p9 term-child)"
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reply --to child-a --pane wT:p9 "Use path A"
  assert_success
  local call3 call4
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  call4="$(sed -n '4p' "$CHILD_STUB/calls.log")"
  [[ "$call3" == agent\ prompt\ wT:p9*parent-reply*pane=wT:p0* ]]
  [[ "$call4" == pane\ report-metadata*wT:p9*--clear-state-labels* ]]

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
  local parent_agents='{"result":{"agents":[{"name":"red-bear","pane_id":"wT:p0","agent":"opencode","terminal_id":"term-parent","revision":1,"state_change_seq":1},{"name":"blue-otter","pane_id":"wT:p9","agent":"claude","terminal_id":"term-child","revision":2,"state_change_seq":2}]}}'
  env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$parent_agents" HERDR_ENV=1 \
    HERDR_PANE_ID=wT:p9 HERDR_CHILD_NAME=child-a HERDR_CHILD_PARENT_PANE=wT:p0 \
    bash "$HERDR_CHILD" ask question >/dev/null
  local child_agents; child_agents="$(complete_agent_record child-a wT:p9 term-child)"
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
  local agents; agents="$(complete_agent_record child-a wT:p9 term-child)"
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

@test "herdr-child reply rejects a changed terminal immediately before prompt" {
  child_stub_herdr
  local initial fresh
  initial="$(complete_agent_record child-a wT:p9 term-child idle false)"
  fresh="$(complete_agent_record child-a wT:p9 term-replaced idle false)"
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON_FIRST="$initial" STUB_AGENTS_JSON_SECOND="$fresh" \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reply --to child-a --pane wT:p9 decision
  assert_failure
  assert_output --partial "alias, pane, or terminal changed before reply"
  run grep -q '^agent prompt' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child reap is single-target and keeps unsettled or focused panes" {
  child_stub_herdr
  local agents; agents="$(complete_agent_record work-a wT:p2 term-child working false)"
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --to work-a --pane wT:p2
  assert_success
  assert_output --partial "work-a: kept; status is working"

  child_stub_herdr
  agents="$(complete_agent_record focus-a wT:p3 term-child idle true)"
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --to focus-a --pane wT:p3
  assert_success
  assert_output --partial "focus-a: kept; pane wT:p3 is focused"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --to focus-a --pane wT:p3 extra
  assert_failure 2
}

@test "herdr-child reap closes an unfocused idle pane" {
  child_stub_herdr
  local agents; agents="$(complete_agent_record idle-a wT:p1 term-child idle false)"
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --to idle-a --pane wT:p1
  assert_success
  assert_output --partial "idle-a: closed pane wT:p1"
  refute_output --partial "--pane: skipped"
  run grep -c '^pane close wT:p1' "$CHILD_STUB/calls.log"
  assert_output 1
}

@test "herdr-child reap preserves a pane when fresh state no longer matches" {
  child_stub_herdr
  local initial fresh
  initial="$(complete_agent_record stale-a wT:p1 term-child done false)"
  fresh="$(complete_agent_record stale-a wT:p2 term-other done false)"
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON_FIRST="$initial" STUB_AGENTS_JSON_SECOND="$fresh" \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to stale-a --pane wT:p1
  assert_success
  assert_output --partial "stale-a: kept; child alias, pane, or terminal changed"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child reap refuses outside herdr and from a child pane" {
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV= HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --to child-a --pane wT:p1
  assert_failure
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_PARENT_PANE=wT:p0 bash "$HERDR_CHILD" reap --to child-a --pane wT:p1
  assert_failure
  assert_output --partial "parent-side"
}

@test "herdr-child reap does not close a same-pane replacement" {
  child_stub_herdr
  local initial fresh
  initial="$(complete_agent_record stale-a wT:p1 term-child done false)"
  fresh="$(complete_agent_record stale-a wT:p1 term-replaced done false)"
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON_FIRST="$initial" STUB_AGENTS_JSON_SECOND="$fresh" \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to stale-a --pane wT:p1
  assert_success
  assert_output --partial "alias, pane, or terminal changed"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child reap preserves a settled pane with a waiting label" {
  child_stub_herdr
  local agents; agents="$(complete_agent_record wait-a wT:p1 term-child idle false)"
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_LABEL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to wait-a --pane wT:p1
  assert_success
  assert_output --partial "has a waiting state label"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child reap preserves a settled pane when pane metadata is malformed" {
  child_stub_herdr
  local agents; agents="$(complete_agent_record bad-meta-a wT:p1 term-child idle false)"
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PANE_GET_MALFORMED=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to bad-meta-a --pane wT:p1
  assert_success
  assert_output --partial "bad-meta-a: kept; pane metadata could not be read"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child reap with no ownership token behaves like today's pane-mode reap" {
  child_stub_herdr
  local agents; agents="$(complete_agent_record idle-a wT:p1 term-child idle false)"
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --to idle-a --pane wT:p1
  assert_success
  assert_output --partial "idle-a: closed pane wT:p1"
  run grep -q '^tab get' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child reap removes the tab when the token matches and the pane is the only one" {
  child_stub_herdr
  seed_tab_token wT:p1 wT:t1
  local agents; agents="$(complete_agent_record tab-a wT:p1 term-child idle false)"
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_TAB_GET_FAIL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to tab-a --pane wT:p1
  assert_success
  assert_output --partial "tab-a: closed pane wT:p1 and its tab wT:t1"
  assert_file_contains "$CHILD_STUB/calls.log" '^tab get wT:t1'
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p1'
  local close_line tab_get_line
  close_line="$(grep -n '^pane close wT:p1' "$CHILD_STUB/calls.log" | cut -d: -f1)"
  tab_get_line="$(grep -n '^tab get wT:t1' "$CHILD_STUB/calls.log" | cut -d: -f1)"
  [ "$close_line" -lt "$tab_get_line" ]
}

@test "herdr-child reap keeps a matched-token tab with sibling panes and reports the count" {
  child_stub_herdr
  seed_tab_token wT:p1 wT:t1
  local agents; agents="$(complete_agent_record tab-a wT:p1 term-child idle false)"
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_TAB_PANE_COUNT=3 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to tab-a --pane wT:p1
  assert_success
  assert_output --partial "tab-a: closed pane wT:p1; tab wT:t1 kept with 3 panes"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p1'
}

@test "herdr-child reap keeps a pane whose token names a different tab" {
  child_stub_herdr
  seed_tab_token wT:p1 wT:t9
  local agents; agents="$(complete_agent_record mismatch-a wT:p1 term-child idle false)"
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_TAB_ID_OVERRIDE=wT:t1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to mismatch-a --pane wT:p1
  assert_success
  assert_output --partial "mismatch-a: kept; tab ownership is ambiguous"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
  run grep -q '^tab get' "$CHILD_STUB/calls.log"
  assert_failure
}

@test "herdr-child reap reports the tab status as unconfirmed when the post-close read fails" {
  child_stub_herdr
  seed_tab_token wT:p1 wT:t1
  local agents; agents="$(complete_agent_record gone-a wT:p1 term-child idle false)"
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" \
    STUB_TAB_GET_FAIL=1 STUB_TAB_GET_ERROR=timeout \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to gone-a --pane wT:p1
  assert_success
  assert_output --partial "gone-a: closed pane wT:p1; tab wT:t1 status could not be confirmed"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p1'
}

@test "herdr-child reap reports the tab status as unconfirmed when pane_count is malformed" {
  child_stub_herdr
  seed_tab_token wT:p1 wT:t1
  local agents; agents="$(complete_agent_record malformed-a wT:p1 term-child idle false)"
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_TAB_PANE_COUNT_MALFORMED=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to malformed-a --pane wT:p1
  assert_success
  assert_output --partial "malformed-a: closed pane wT:p1; tab wT:t1 status could not be confirmed"
}

@test "herdr-child reap reports an already-closed pane as cleaned when the token matched" {
  child_stub_herdr
  seed_tab_token wT:p1 wT:t1
  local agents; agents="$(complete_agent_record gone-b wT:p1 term-child idle false)"
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_TAB_PANE_COUNT=1 \
    STUB_CLOSE_STATUS=1 STUB_CLOSE_ERROR=pane_not_found \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to gone-b --pane wT:p1
  assert_success
  assert_output --partial "gone-b: already cleaned; pane wT:p1 is gone"
}

# One dead verb (`herdr wait output`, which herdr spells `herdr pane wait-output`) cost a
# whole broken mode for six weeks. Every herdr command a skill script runs is checked
# here: its group against the allowlist always, and the full command against the installed
# binary when there is one — CI has no herdr, a dev machine does. Scope includes skill
# scripts and the shared launch executable, where the surviving herdr calls are concentrated.
@test "skill scripts call only herdr commands that exist" {
  local groups='agent|api|channel|completion|config|integration|notification|pane|plugin|session|tab|workspace|worktree|status|update|server'
  local calls bad="" grp cmd child_calls child_cmd
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
  child_calls="$(grep -rh --include='*.sh' -E 'herdr-child' "$SOURCE_ROOT/private_dot_claude/skills" \
    | grep -vE '^[[:space:]]*#' \
    | grep -oE '(^|[|;&(`]|\$\()[[:space:]]*herdr-child [a-z][a-z-]*' \
    | sed 's/.*herdr-child //' | sort -u)"
  while read -r child_cmd; do
    [ -n "$child_cmd" ] || continue
    case "$child_cmd" in
      start | ask | verify | reply | reap) ;;
      *) bad="$bad herdr-child:$child_cmd" ;;
    esac
  done <<< "$child_calls"
  printf '%s\n' "$child_calls" | grep -qx verify || bad="$bad herdr-child:missing-verify-contract"
  [ -z "$bad" ] || fail "skill scripts call herdr commands that do not exist:$bad"
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
# herdr-pane-labels engine
# ===========================================

@test "herdr-pane-labels descriptor probe lives in a one-test Bats file" {
  local descriptor_probe_file="$BATS_TEST_DIRNAME/herdr_pane_labels_descriptor_probe.bats"
  assert_file_exists "$descriptor_probe_file"
  run bats --count "$descriptor_probe_file"
  assert_success
  assert_output "1"
}

@test "herdr-pane-labels bounded Bats invocation exits after detached work" {
  # No python3 skip guard: it is a declared requirement (README.md,
  # Requirements), a deliberate exception to the skip convention in
  # docs/issues/2026-08-20-013-se-blocks-test-hard-fails-without-deps.md.
  local bats_bin release_file="$BATS_TEST_TMPDIR/release-herdr"
  local pid_file="$BATS_TEST_TMPDIR/descriptor-worker.pid"
  local blocked_pid_file="$BATS_TEST_TMPDIR/blocked-herdr.pid"
  local descriptor_probe_file="$BATS_TEST_DIRNAME/herdr_pane_labels_descriptor_probe.bats"
  bats_bin="$(command -v bats)"
  export HPL_DESCRIPTOR_RELEASE_FILE="$release_file"
  export HPL_DESCRIPTOR_PID_FILE="$pid_file"
  export HPL_DESCRIPTOR_BLOCKED_PID_FILE="$blocked_pid_file"
  # This is the only test whose stub must stay blocked across a whole nested Bats
  # run, so it is the only one that gets the raised ceiling.
  export HPL_BLOCKED_HERDR_POLLS
  run python3 - "$bats_bin" "$descriptor_probe_file" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

# Two bounds, not one, and they measure different things. See the
# HPL_INNER_BATS_* comments in this file's constants block for why the single
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
progress_budget = int(os.environ.get("HPL_INNER_BATS_PROGRESS_SECONDS", "60"))
exit_budget = int(os.environ.get("HPL_INNER_BATS_EXIT_SECONDS", "30"))

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

release_file = Path(os.environ["HPL_DESCRIPTOR_RELEASE_FILE"])
pid_file = Path(os.environ["HPL_DESCRIPTOR_PID_FILE"])
blocked_pid_file = Path(os.environ["HPL_DESCRIPTOR_BLOCKED_PID_FILE"])
gave_up_file = Path(str(blocked_pid_file) + ".gave-up")


def fixture_gave_up():
    """The blocked herdr stub hit its ceiling and stopped holding its descriptor.
    Whatever else this run observed, it did not observe the property under test."""
    return gave_up_file.exists()


VACUOUS = (
    "the blocked herdr stub hit HPL_BLOCKED_HERDR_CEILING_SECONDS and gave up, so "
    "nothing held a descriptor while the inner Bats exited -- this run proved nothing"
)

proc = subprocess.Popen(
    [sys.argv[1], sys.argv[2], "--filter", "^herdr-pane-labels descriptor child probe$"],
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
# is what HPL_INNER_BATS_EXIT_SECONDS gets recalibrated against. 50 ms keeps the
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
# HPL_INNER_BATS_EXIT_SECONDS reads a number out of CI instead of reconstructing
# one from TAP print-order gaps.
print(f"inner Bats exit phase took {exit_elapsed:.3f}s", file=sys.stderr)

# Non-vacuity: the herdr stub must STILL be blocked right now. Everything above
# only proves the nested Bats exited and closed its pipes -- which is unremarkable
# if nothing was holding a descriptor at the time. The stub gives up on its own
# after HPL_BLOCKED_HERDR_CEILING_SECONDS, and if it did, this run proved nothing.
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
  unset HPL_DESCRIPTOR_RELEASE_FILE HPL_DESCRIPTOR_PID_FILE
  # `run` captures the driver's measurement into $output, which bats discards on
  # a passing test -- so forward it to the console descriptor. The number is only
  # useful if a green CI run carries it: it is what
  # HPL_INNER_BATS_EXIT_SECONDS gets recalibrated against, and reconstructing it
  # from TAP print-order gaps is what made the previous bound guesswork.
  printf '%s\n' "$output" | grep -F 'inner Bats exit phase took' >&3 || true
  assert_success
  assert_output --partial "ok 1 herdr-pane-labels descriptor child probe"
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
@test "herdr-pane-labels bounded Bats invocation refuses a vacuous run" {
  local bats_bin release_file="$BATS_TEST_TMPDIR/release-herdr"
  local pid_file="$BATS_TEST_TMPDIR/descriptor-worker.pid"
  local blocked_pid_file="$BATS_TEST_TMPDIR/blocked-herdr.pid"
  bats_bin="$(command -v bats)"
  export HPL_DESCRIPTOR_RELEASE_FILE="$release_file"
  export HPL_DESCRIPTOR_PID_FILE="$pid_file"
  export HPL_DESCRIPTOR_BLOCKED_PID_FILE="$blocked_pid_file"
  # One poll: the stub records its give-up before the driver ever looks.
  export HPL_BLOCKED_HERDR_POLLS=1

  run bats "$BATS_TEST_FILENAME" \
    --filter '^herdr-pane-labels bounded Bats invocation exits after detached work$'

  unset HPL_DESCRIPTOR_RELEASE_FILE HPL_DESCRIPTOR_PID_FILE
  unset HPL_DESCRIPTOR_BLOCKED_PID_FILE HPL_BLOCKED_HERDR_POLLS
  assert_failure
  assert_output --partial "this run proved nothing"
}

@test "herdr-pane-labels harness fresh reads follow pane and tab mutations" {
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

@test "herdr-pane-labels harness isolates colliding sanitized socket names" {
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local socket_one="$HPL_WORK/a-b.sock" socket_two="$HPL_WORK/a_b.sock"
  local dir_one dir_two sanitized_one sanitized_two
  sanitized_one="$(printf '%s' "$socket_one" | sed 's/[^[:alnum:]]/_/g')"
  sanitized_two="$(printf '%s' "$socket_two" | sed 's/[^[:alnum:]]/_/g')"
  assert_equal "$sanitized_one" "$sanitized_two"
  dir_one="$(hpl_socket_dir "$socket_one")"
  dir_two="$(hpl_socket_dir "$socket_two")"
  [[ "$dir_one" != "$dir_two" ]]
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
  mkdir "$dir_one/locks/held" "$dir_two/locks/held"
  assert_dir_exists "$dir_one/locks/held"
  assert_dir_exists "$dir_two/locks/held"
  assert_dir_exists "$dir_one/locks"
  assert_dir_exists "$dir_two/locks"
  assert_equal "$(wc -l < "$(hpl_socket_log "$socket_one")" | tr -d ' ')" 1
  assert_equal "$(wc -l < "$(hpl_socket_log "$socket_two")" | tr -d ' ')" 1
}

@test "herdr-pane-labels harness applies source metadata sequence and clear rules" {
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

@test "herdr-pane-labels harness models target loss move reuse and final-read change" {
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
  assert_output --partial '"terminal_id":"term-3"'
  assert_output --partial '"label":"stale-write"'
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane rename pane-1 converged
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" pane get pane-1
  assert_output --partial '"label":"converged"'
}

@test "herdr-pane-labels assigns distinct aliases and renders known and fallback runtime prefixes" {
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

@test "herdr-pane-labels preserves a unique pool alias across events and sweeps" {
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

@test "herdr-pane-labels accepts independent pane and agent revisions in a complete join" {
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

@test "herdr-pane-labels rejects unsafe snapshot strings before every write" {
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
    [[ "$pending" -gt "$completed" ]]
    run find "$namespace/panes" -name location.state -print
    assert_output ""
    hpl_teardown
  done
}

@test "herdr-pane-labels sources the alias library relative to its deployed path" {
  local deployed="$BATS_TEST_TMPDIR/deployed-herdr-pane-labels"
  mkdir -p "$deployed/bin" "$deployed/lib"
  cp "$HPL_ENGINE" "$deployed/bin/herdr-pane-labels"
  cp "$HERDR_ALIASES" "$deployed/lib/herdr-aliases.sh"

  run env PATH="$deployed/bin:/usr/bin:/bin" bash "$deployed/bin/herdr-pane-labels" --help
  assert_success
  assert_output --partial 'Usage: herdr-pane-labels'
}

@test "herdr-pane-labels terminates without writes when every alias is occupied" {
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

@test "herdr-pane-labels retries only an exact confirmed agent_name_taken conflict" {
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

@test "herdr-pane-labels never renames a stale target that exits moves or changes before validation" {
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

@test "herdr-pane-labels accepts a same-pane replacement in the rename command interval" {
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

@test "herdr-pane-labels rejects incomplete malformed duplicate and contradictory snapshots before writes" {
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

@test "herdr-pane-labels rejects a complete stale post-rename snapshot and converges later" {
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
  [[ "$(jq -r '.panes[0].label' "$state")" == cc:* ]]
}

@test "herdr-pane-labels contains no semantic naming or retired worker interface" {
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

@test "managed source removes semantic adapters and keeps alias presentation files" {
  local retired
  for retired in \
    "$SOURCE_ROOT/dot_local/bin/executable_herdr-task-sync" \
    "$SOURCE_ROOT/private_dot_claude/hooks/executable_herdr-task-sync-hook.sh" \
    "$SOURCE_ROOT/private_dot_config/opencode/plugins/herdr-task-sync.ts" \
    "$SOURCE_ROOT/dot_pi/agent/extensions/herdr-task-sync.ts"; do
    assert_file_not_exists "$retired"
  done

  assert_file_exists "$HPL_ENGINE"
  assert_file_exists "$HERDR_ALIASES"
  assert_file_exists "$HPL_PLUGIN_DIR/herdr-plugin.toml"
  assert_file_exists "$HPL_PLUGIN_DIR/ensure.sh"
  assert_file_exists "$HPL_PLUGIN_DIR/sweep.sh"
}

@test "herdr-pane-labels presentation coalesces event bursts into an active pass and rerun" {
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

@test "herdr-pane-labels presentation retries a newer invalidation after transient pass failure" {
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

@test "herdr-pane-labels presentation release recheck does not lose a pending invalidation" {
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

@test "herdr-pane-labels event presentation leaves the hook process group" {
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

  [ -n "$worker_pgid" ]
  [ "$worker_pgid" != "$hook_pgid" ]
}

@test "herdr-pane-labels presentation automatically corrects divergent pane and tab labels" {
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

@test "herdr-pane-labels presentation rejects an unsafe row without reducing pass scope" {
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
  [[ "$pending" -gt "$completed" ]]
}

@test "herdr-pane-labels aborts unsafe process and Git-derived positional rows" {
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
  [[ "$pending" -gt "$completed" ]]
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
  [[ "$pending" -gt "$completed" ]]
  run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure
  run find "$namespace/panes" -name location.state -print
  assert_output ""
}

@test "herdr-pane-labels presentation skips pre-read deletion and repairs the post-read race next pass" {
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

@test "herdr-pane-labels presentation skips reused pane and tab identities at the final read" {
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

@test "herdr-pane-labels presentation isolates exact colliding socket identities" {
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
  [[ "$(hpl_namespace "$socket_one")" != "$(hpl_namespace "$socket_two")" ]]
}

@test "herdr-pane-labels presentation fails closed without an exact socket" {
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

@test "herdr-pane-labels location resolves main linked nested and administrative paths with strict foreground semantics" {
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

@test "herdr-pane-labels dangling administrative gitdir retains stale location" {
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

@test "herdr-pane-labels location detached publishes a commit ref and non-Git clears are source-local with monotonic restart high-water" {
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
  [[ "$second_seq" -gt "$first_seq" ]]
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
  [[ "$(hpl_location_source_seq "$HPL_DEFAULT_SOCKET" pane-1)" -gt "$second_seq" ]]
}

@test "herdr-pane-labels location real probe shape pays the second sha call only when detached" {
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

@test "herdr-pane-labels location detached sha failure retains prior identity as stale and never publishes a malformed git_ref" {
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

@test "herdr-pane-labels location detached sha budget failure with no prior state renders no git location and self-heals" {
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

@test "herdr-pane-labels location clears the retired location_label token on both publish and non-git clear paths" {
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

@test "herdr-pane-labels location transient modes retain identity as stale without foreground fallback" {
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

@test "herdr-pane-labels coordinator resolves eight pane locations concurrently within one event envelope" {
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

@test "herdr-pane-labels no-op location event preserves the state file" {
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

@test "herdr-pane-labels transient location preserves live token-only identity when retained state is unavailable" {
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

@test "herdr-pane-labels location authoritative worktree deletion clears retained evidence" {
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

@test "herdr-pane-labels formatter keeps Git refs in metadata and tab labels names-only" {
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

@test "herdr-pane-labels formatter renders a main checkout ref in metadata only" {
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

@test "herdr-pane-labels formatter renders a worktree ref in metadata only" {
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

@test "herdr-pane-labels formatter keeps a Git-backed all-idle tab names-only" {
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

@test "herdr-pane-labels Git-only location changes do not rename a names-only tab" {
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

@test "herdr-pane-labels formatter keeps the folder qualifier on a main checkout in a differently-named folder" {
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

@test "herdr-pane-labels formatter reads the workspace display name from the legacy name field when label is absent" {
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

@test "herdr-pane-labels formatter gives a detached HEAD inside a linked worktree the commit icon" {
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

@test "herdr-pane-labels formatter qualifies a divergent worktree folder in metadata only" {
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

@test "herdr-pane-labels formatter keeps mixed Git identities out of tabs and repairs external labels" {
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

@test "herdr-pane-labels formatter joins only pane labels when three panes span two repositories" {
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

@test "herdr-pane-labels worktree tokens use shortest unique slash suffixes for basename collisions" {
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

@test "herdr-pane-labels worktree tokens digest overlong roots and extend colliding digest prefixes" {
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
  [[ "$token_one" != "$token_two" ]]
  [[ "$token_one" = *abcdef || "$token_two" = *abcdef ]]
  [[ "$token_one" = *abcdef0 || "$token_two" = *abcdef1 ]]
}

@test "herdr-pane-labels worktree token ordinal fallback is unique and stable under pane reordering" {
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

@test "herdr-pane-labels long branch refs stay in metadata and do not alter the tab label" {
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

@test "herdr-pane-labels long repository names do not alter a multi-repo tab label" {
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

@test "herdr-pane-labels location clears a retired location_label even when every published token already matches" {
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

@test "herdr-pane-labels location and formatter add only approved static icon glyphs and no forbidden ownership state" {
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

@test "herdr-pane-labels plugin exposes only the approved pane and tab invalidations" {
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
  assert_output $'pane.created|["sh", "ensure.sh", "--event"]\npane.moved|["sh", "ensure.sh", "--event"]\npane.exited|["sh", "ensure.sh", "--event"]\npane.closed|["sh", "ensure.sh", "--event"]\npane.agent_detected|["sh", "ensure.sh", "--event"]\npane.agent_status_changed|["sh", "ensure.sh", "--event"]\ntab.created|["sh", "ensure.sh", "--event"]\ntab.closed|["sh", "ensure.sh", "--event"]\ntab.moved|["sh", "ensure.sh", "--event"]\ntab.renamed|["sh", "ensure.sh", "--event"]'
  assert_file_contains "$manifest" '^min_herdr_version = "0\.8\.2"$'
  assert_file_contains "$manifest" '^id = "sweep"$'
  assert_file_contains "$manifest" '^title = "Pane labels: refresh now"$'
  assert_file_contains "$manifest" '^command = \["sh", "sweep\.sh"\]$'
  run grep -E '^on = ".*\*|^on = "(pane\.updated|workspace\.focused|tab\.focused|pane\.focused)"|reclaim' "$manifest"
  assert_failure
}

@test "herdr-pane-labels plugin wrappers invoke one engine mode and isolate failures" {
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

@test "herdr-pane-labels event requests reconciliation and ensures the daemon fail-open" {
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

@test "herdr-pane-labels sweep repairs an external pane rename without pane.updated" {
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

@test "herdr-pane-labels sweep repairs process and CWD changes through the presentation coordinator" {
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

@test "herdr-pane-labels names a command pane after the process group leader" {
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
@test "herdr-pane-labels names an idle pane with the placeholder" {
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
@test "herdr-pane-labels presentation numbers an all-idle tab" {
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
@test "herdr-pane-labels truncates a long command name" {
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
@test "herdr-pane-labels --sweep relabels every tab" {
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

@test "herdr-pane-labels --sweep reports a failed reconciliation" {
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local dir
  dir="$(hpl_socket_dir "$HPL_DEFAULT_SOCKET")"
  : > "$dir/fail-snapshot"

  run hpl_sweep_run --sweep

  assert_failure
}

@test "herdr-pane-labels strict sweep rejects failed and unapplied presentation writes" {
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
@test "herdr-pane-labels --sweep leaves an unchanged tab label alone" {
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
@test "herdr-pane-labels --sweep numbers all-idle tabs per workspace" {
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
@test "herdr-pane-labels --ensure-sweep-daemon keeps a single daemon" {
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
@test "herdr-pane-labels --ensure-sweep-daemon replaces a dead daemon" {
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

@test "herdr-pane-labels sweep daemon exits after three unreachable snapshots" {
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

# ===========================================
# herdr pane-label cutover (U5)
# ===========================================

@test "herdr pane-label cutover selects modes only for the configured engine paths" {
  local library="$SOURCE_ROOT/.chezmoitemplates/herdr-pane-labels-cutover-lib.sh"
  run env HOME="$BATS_TEST_TMPDIR/cutover-mode-home" bash -c '
    source "$1"
    [ "$(hpl_cutover_mode_for_engine "$HPL_CUTOVER_OLD_ENGINE")" = --ensure-daemon ]
    [ "$(hpl_cutover_mode_for_engine "$HPL_CUTOVER_NEW_ENGINE")" = --ensure-sweep-daemon ]
    ! hpl_cutover_mode_for_engine "$HOME/.local/bin/unknown-engine"
  ' _ "$library"
  assert_success
}

@test "herdr pane-label cutover freezes adapters, disables before TERM, and drains writers causally" {
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local owner hook disable_line term_line
  owner="$(hpl_cutover_spawn_owner --presentation-worker "$HPL_DEFAULT_SOCKET" presentation.claim)"
  cat > "$HPL_WORK/cutover-hook" <<'SH'
#!/usr/bin/env bash
if [[ "$1" = owner-free-1 ]]; then
  "$HOME/.local/bin/herdr-task-sync" --agent claude --session late </dev/null
  "$HOME/.local/bin/herdr-task-sync" --event </dev/null
  printf '%s\n' event-during-quiescence >> "$HPL_WORK/hook.log"
fi
SH
  chmod +x "$HPL_WORK/cutover-hook"
  export HERDR_PANE_LABELS_CUTOVER_TEST_HOOK="$HPL_WORK/cutover-hook"

  run hpl_cutover_run "$HPL_CUTOVER_BEFORE"

  assert_success
  run hpl_pid_is_live "$owner"
  assert_failure
  assert_file_not_exists "$HPL_WORK/legacy-adapter.log"
  assert_file_contains "$HPL_WORK/hook.log" '^event-during-quiescence$'
  disable_line="$(grep -n '^plugin-disabled$' "$HPL_CUTOVER_TRACE" | cut -d: -f1)"
  term_line="$(grep -n '^term:presentation:' "$HPL_CUTOVER_TRACE" | cut -d: -f1)"
  [[ -n "$disable_line" && -n "$term_line" && "$disable_line" -lt "$term_line" ]]
  assert_file_contains "$HPL_CUTOVER_TRACE" '^old-entry-frozen$'
  assert_file_contains "$HPL_CUTOVER_TRACE" '^child-entry-frozen$'
  assert_file_contains "$HPL_CUTOVER_TRACE" '^owner-free:2$'
  run env HOME="$HPL_CUTOVER_HOME" "$HPL_CUTOVER_HOME/.local/bin/herdr-child" start --kind claude --prompt blocked
  assert_failure
  assert_output --partial "unavailable during pane-label cutover"
  unset HERDR_PANE_LABELS_CUTOVER_TEST_HOOK
}

@test "herdr pane-label cutover rejects a non-pool child and restores old daemons for every socket" {
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local socket_two="$HPL_WORK/second.sock" before_hash after_hash child_before child_after pid_one pid_two
  hpl_cutover_sessions "$HPL_DEFAULT_SOCKET" "$socket_two"
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude review-auth
  hpl_socket_state "$socket_two" >/dev/null
  before_hash="$(shasum -a 256 "$HPL_CUTOVER_HOME/.local/bin/herdr-task-sync" | cut -d' ' -f1)"
  child_before="$(shasum -a 256 "$HPL_CUTOVER_HOME/.local/bin/herdr-child" | cut -d' ' -f1)"
  pid_one="$(hpl_cutover_start_old_daemon "$HPL_DEFAULT_SOCKET")"
  pid_two="$(hpl_cutover_start_old_daemon "$socket_two")"

  run hpl_cutover_run "$HPL_CUTOVER_BEFORE"

  assert_failure
  assert_output --partial "review-auth"
  assert_output --partial "pane-1"
  after_hash="$(shasum -a 256 "$HPL_CUTOVER_HOME/.local/bin/herdr-task-sync" | cut -d' ' -f1)"
  child_after="$(shasum -a 256 "$HPL_CUTOVER_HOME/.local/bin/herdr-child" | cut -d' ' -f1)"
  assert_equal "$after_hash" "$before_hash"
  assert_equal "$child_after" "$child_before"
  kill -0 "$pid_one"
  kill -0 "$pid_two"
  assert_file_contains "$HPL_WORK/plugin.log" '^plugin disable seigi\.pane-labels$'
  assert_file_contains "$HPL_WORK/plugin.log" '^plugin enable seigi\.pane-labels$'
  assert_file_contains "$HPL_CUTOVER_TRACE" "^ensure:$HPL_DEFAULT_SOCKET:--ensure-daemon$"
  assert_file_contains "$HPL_CUTOVER_TRACE" "^ensure:$socket_two:--ensure-daemon$"
  [[ "$(grep -c '^daemon-verified:' "$HPL_CUTOVER_TRACE")" -eq 2 ]]
}

@test "herdr pane-label cutover rollback restarts every daemon killed before a later refusal" {
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local socket_two="$HPL_WORK/rollback.sock" old_one old_two new_one new_two unrelated
  local namespace claim start
  hpl_cutover_sessions "$HPL_DEFAULT_SOCKET" "$socket_two"
  hpl_socket_state "$socket_two" >/dev/null
  old_one="$(hpl_cutover_start_old_daemon "$HPL_DEFAULT_SOCKET")"
  old_two="$(hpl_cutover_start_old_daemon "$socket_two")"
  sleep 30 &
  unrelated=$!
  namespace="$(hpl_cutover_namespace herdr-task-sync "$HPL_DEFAULT_SOCKET")"
  claim="$namespace/presentation.claim"
  mkdir -p "$claim"
  start="$(ps -p "$unrelated" -o lstart= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  printf 'owner_id=%s\npid=%s\nprocess_start=%s\nsocket_path=%s\n' \
    "$(printf unrelated | base64 | tr -d '\n')" "$unrelated" \
    "$(printf '%s' "$start" | base64 | tr -d '\n')" \
    "$(printf '%s' "$HPL_DEFAULT_SOCKET" | base64 | tr -d '\n')" > "$claim/owner"

  run hpl_cutover_run "$HPL_CUTOVER_BEFORE"

  assert_failure
  run hpl_pid_is_live "$old_one"
  assert_failure
  run hpl_pid_is_live "$old_two"
  assert_failure
  new_one="$(cat "$(hpl_cutover_namespace herdr-task-sync "$HPL_DEFAULT_SOCKET")/sweep.lock/pid")"
  new_two="$(cat "$(hpl_cutover_namespace herdr-task-sync "$socket_two")/sweep.lock/pid")"
  [[ "$new_one" != "$old_one" && "$new_two" != "$old_two" ]]
  kill -0 "$new_one"
  kill -0 "$new_two"
  assert_file_contains "$HPL_CUTOVER_TRACE" "^term:daemon:$HPL_DEFAULT_SOCKET:$old_one$"
  assert_file_contains "$HPL_CUTOVER_TRACE" "^term:daemon:$socket_two:$old_two$"
  assert_file_contains "$HPL_CUTOVER_TRACE" "^ensure:$HPL_DEFAULT_SOCKET:--ensure-daemon$"
  assert_file_contains "$HPL_CUTOVER_TRACE" "^ensure:$socket_two:--ensure-daemon$"
  kill "$unrelated" 2>/dev/null || true
}

@test "herdr pane-label cutover drains daemon presentation and naming owners and removes stale locks" {
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local namespace daemon presentation naming stale
  daemon="$(hpl_cutover_start_old_daemon "$HPL_DEFAULT_SOCKET")"
  presentation="$(hpl_cutover_spawn_owner --presentation-worker "$HPL_DEFAULT_SOCKET" presentation.claim)"
  naming="$(hpl_cutover_spawn_owner --worker "$HPL_DEFAULT_SOCKET" panes/$(hpl_key pane-1)/worker.claim)"
  namespace="$(hpl_cutover_namespace herdr-task-sync "$HPL_DEFAULT_SOCKET")"
  stale="$namespace/panes/$(hpl_key pane-2)/control.lock"
  mkdir -p "$HPL_CUTOVER_HOME/.cache/herdr-task-sync/sweep.lock"
  mkdir -p "$stale"
  printf 'owner_id=%s\npid=999999\nprocess_start=%s\nsocket_path=%s\n' \
    "$(printf stale | base64 | tr -d '\n')" "$(printf dead | base64 | tr -d '\n')" \
    "$(printf '%s' "$HPL_DEFAULT_SOCKET" | base64 | tr -d '\n')" > "$stale/owner"

  run hpl_cutover_run "$HPL_CUTOVER_BEFORE"

  assert_success
  for pid in "$daemon" "$presentation" "$naming"; do
    run hpl_pid_is_live "$pid"
    assert_failure
  done
  assert_dir_not_exists "$stale"
  assert_dir_not_exists "$HPL_CUTOVER_HOME/.cache/herdr-task-sync/sweep.lock"
  assert_file_contains "$HPL_CUTOVER_TRACE" '^term:daemon:'
  assert_file_contains "$HPL_CUTOVER_TRACE" '^term:presentation:'
  assert_file_contains "$HPL_CUTOVER_TRACE" '^term:naming:'
  assert_file_contains "$HPL_CUTOVER_TRACE" '^stale-lock:'
}

@test "herdr pane-label cutover double-check refuses a changed owner identity before TERM" {
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local owner namespace owner_file hook
  owner="$(hpl_cutover_spawn_owner --presentation-worker "$HPL_DEFAULT_SOCKET" presentation.claim)"
  namespace="$(hpl_cutover_namespace herdr-task-sync "$HPL_DEFAULT_SOCKET")"
  owner_file="$namespace/presentation.claim/owner"
  hook="$HPL_WORK/change-owner-hook"
  cat > "$hook" <<SH
#!/usr/bin/env bash
case "\$1" in
  before-term-claim:*)
    perl -pi -e 's/^pid=.*/pid=999999/' "$owner_file"
    ;;
esac
SH
  chmod +x "$hook"
  export HERDR_PANE_LABELS_CUTOVER_TEST_HOOK="$hook"

  run hpl_cutover_run "$HPL_CUTOVER_BEFORE"

  assert_failure
  kill -0 "$owner"
  refute_output --partial "old and current writers quiesced"
  run grep "^term:presentation:.*:$owner$" "$HPL_CUTOVER_TRACE"
  assert_failure
  kill "$owner" 2>/dev/null || true
  unset HERDR_PANE_LABELS_CUTOVER_TEST_HOOK
}

@test "herdr pane-label cutover double-checks the legacy daemon PID immediately before TERM" {
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local daemon namespace pid_file hook
  daemon="$(hpl_cutover_start_old_daemon "$HPL_DEFAULT_SOCKET")"
  namespace="$(hpl_cutover_namespace herdr-task-sync "$HPL_DEFAULT_SOCKET")"
  pid_file="$namespace/sweep.lock/pid"
  hook="$HPL_WORK/change-daemon-hook"
  cat > "$hook" <<SH
#!/usr/bin/env bash
case "\$1" in
  before-term-daemon:$daemon) printf '%s' 999999 > "$pid_file" ;;
esac
SH
  chmod +x "$hook"
  export HERDR_PANE_LABELS_CUTOVER_TEST_HOOK="$hook"

  run hpl_cutover_run "$HPL_CUTOVER_BEFORE"

  assert_failure
  assert_output --partial "daemon identity changed before TERM"
  kill -0 "$daemon"
  run grep "^term:daemon:.*:$daemon$" "$HPL_CUTOVER_TRACE"
  assert_failure
  kill "$daemon" 2>/dev/null || true
  unset HERDR_PANE_LABELS_CUTOVER_TEST_HOOK
}

@test "herdr pane-label cutover refuses an unrelated live PID and rolls back" {
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local namespace unrelated before_hash after_hash
  sleep 30 &
  unrelated=$!
  namespace="$(hpl_cutover_namespace herdr-task-sync "$HPL_DEFAULT_SOCKET")"
  hpl_cutover_write_socket_state "$namespace" "$HPL_DEFAULT_SOCKET"
  mkdir -p "$namespace/sweep.lock"
  printf '%s' "$unrelated" > "$namespace/sweep.lock/pid"
  before_hash="$(shasum -a 256 "$HPL_CUTOVER_HOME/.local/bin/herdr-task-sync" | cut -d' ' -f1)"

  run hpl_cutover_run "$HPL_CUTOVER_BEFORE"

  assert_failure
  assert_output --partial "refusing unrelated or unverifiable daemon PID"
  kill -0 "$unrelated"
  after_hash="$(shasum -a 256 "$HPL_CUTOVER_HOME/.local/bin/herdr-task-sync" | cut -d' ' -f1)"
  assert_equal "$after_hash" "$before_hash"
  kill "$unrelated" 2>/dev/null || true
}

@test "herdr pane-label cutover migrates only validated location state and clears task unsequenced" {
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local old_namespace new_namespace pane_key main_key old_reconcile new_reconcile clear_line
  old_namespace="$(hpl_cutover_namespace herdr-task-sync "$HPL_DEFAULT_SOCKET")"
  new_namespace="$(hpl_cutover_namespace herdr-pane-labels "$HPL_DEFAULT_SOCKET")"
  pane_key="$(hpl_key pane-1)"
  hpl_cutover_write_socket_state "$old_namespace" "$HPL_DEFAULT_SOCKET"
  mkdir -p "$old_namespace/panes/$pane_key" "$old_namespace/tasks" "$old_namespace/migration" \
    "$old_namespace/workers"
  cat > "$old_namespace/panes/$pane_key/location.state" <<EOF
pane=$(printf pane-1 | base64 | tr -d '\n')
checkout_root=$(printf /repo/wt | base64 | tr -d '\n')
repository_anchor=$(printf /repo/.git | base64 | tr -d '\n')
repo=$(printf repo | base64 | tr -d '\n')
branch=$(printf topic | base64 | tr -d '\n')
is_linked=$(printf 1 | base64 | tr -d '\n')
sha=$(printf abc1234 | base64 | tr -d '\n')
EOF
  main_key="$(hpl_key pane-main)"
  mkdir -p "$old_namespace/panes/$main_key"
  cat > "$old_namespace/panes/$main_key/location.state" <<EOF
pane=$(printf pane-main | base64 | tr -d '\n')
checkout_root=$(printf /repo/main | base64 | tr -d '\n')
repository_anchor=$(printf /repo/main/.git | base64 | tr -d '\n')
repo=$(printf repo | base64 | tr -d '\n')
branch=$(printf main | base64 | tr -d '\n')
is_linked=
sha=
EOF
  old_reconcile="$old_namespace/reconcile.state"
  cat > "$old_reconcile" <<EOF
pending_generation=90
completed_generation=80
task_metadata_high_water=99
location_metadata_high_water=77
checkout_root=$(printf /repo/wt | base64 | tr -d '\n')
repository_anchor=$(printf /repo/.git | base64 | tr -d '\n')
retained_location=$(printf pane-1 | base64 | tr -d '\n')
EOF
  printf secret > "$old_namespace/tasks/task.state"
  printf secret > "$old_namespace/migration/task.state"
  printf secret > "$old_namespace/panes/$pane_key/control.state"
  printf secret > "$old_namespace/workers/claim.state"
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane report-metadata pane-1 --source task-sync --seq 99 --token task=legacy
  : > "$HPL_LOG"

  run hpl_cutover_run "$HPL_CUTOVER_BEFORE"

  assert_success
  assert_file_exists "$new_namespace/socket.state"
  assert_file_exists "$new_namespace/panes/$pane_key/location.state"
  assert_file_exists "$new_namespace/panes/$main_key/location.state"
  new_reconcile="$new_namespace/reconcile.state"
  assert_file_contains "$new_reconcile" '^pending_generation=0$'
  assert_file_contains "$new_reconcile" '^completed_generation=0$'
  assert_file_contains "$new_reconcile" '^location_metadata_high_water=77$'
  run grep -ER 'task_metadata|secret|worker|claim|control' "$new_namespace"
  assert_failure
  clear_line="$(grep '^pane report-metadata pane-1 --source task-sync --clear-token task$' "$HPL_LOG")"
  assert_equal "$clear_line" "pane report-metadata pane-1 --source task-sync --clear-token task"
  run jq -e '.panes[0].tokens | has("task") | not' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_success
  assert_file_contains "$HPL_CUTOVER_TRACE" "^task-token-verified:$HPL_DEFAULT_SOCKET$"
  [[ "$(grep -c '^api snapshot$' "$HPL_LOG")" -ge 2 ]]
}

@test "herdr pane-label cutover fails closed when session discovery fails" {
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local before_hash after_hash
  before_hash="$(shasum -a 256 "$HPL_CUTOVER_HOME/.local/bin/herdr-task-sync" | cut -d' ' -f1)"
  : > "$HPL_WORK/fail-session-list"

  run hpl_cutover_run "$HPL_CUTOVER_BEFORE"

  assert_failure
  assert_output --partial "cannot inspect running Herdr sessions"
  after_hash="$(shasum -a 256 "$HPL_CUTOVER_HOME/.local/bin/herdr-task-sync" | cut -d' ' -f1)"
  assert_equal "$after_hash" "$before_hash"
  assert_dir_not_exists "$HPL_CUTOVER_HOME/.cache/herdr-pane-labels/cutover-rollback"
}

@test "herdr pane-label cutover preserves rollback sockets when the second refresh fails" {
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local old_pid new_pid namespace
  old_pid="$(hpl_cutover_start_old_daemon "$HPL_DEFAULT_SOCKET")"
  printf '%s\n' 2 > "$HPL_WORK/fail-session-list-at"

  run hpl_cutover_run "$HPL_CUTOVER_BEFORE"

  assert_failure
  run hpl_pid_is_live "$old_pid"
  assert_failure
  namespace="$(hpl_cutover_namespace herdr-task-sync "$HPL_DEFAULT_SOCKET")"
  new_pid="$(cat "$namespace/sweep.lock/pid")"
  kill -0 "$new_pid"
  assert_file_contains "$HPL_CUTOVER_TRACE" "^ensure:$HPL_DEFAULT_SOCKET:--ensure-daemon$"
}

@test "herdr pane-label cutover rejects an incomplete cleanup snapshot" {
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

@test "herdr pane-label after drain catches a late old writer and ensures independent socket daemons" {
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local socket_two="$HPL_WORK/late.sock" stopped_socket="$HPL_WORK/stopped.sock" late pid_one pid_two state
  hpl_cutover_sessions "$HPL_DEFAULT_SOCKET" "$socket_two"
  : > "$HPL_WORK/require-live-plugin-command-socket"
  jq -c --arg socket "$stopped_socket" \
    '.result.sessions += [{running:false,socket_path:$socket}]' "$HPL_WORK/sessions.json" \
    > "$HPL_WORK/sessions.tmp" && mv "$HPL_WORK/sessions.tmp" "$HPL_WORK/sessions.json"
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude review-auth
  hpl_set_agent_pane "$socket_two" pane-2 tab-2 ws-2 term-2 opencode CORE-42
  late="$(hpl_cutover_spawn_owner --presentation-worker "$HPL_DEFAULT_SOCKET" presentation.claim)"
  rm -f "$HPL_CUTOVER_HOME/.local/bin/herdr-task-sync"

  run hpl_cutover_run "$HPL_CUTOVER_AFTER"

  assert_success
  run hpl_pid_is_live "$late"
  assert_failure
  pid_one="$(cat "$(hpl_cutover_namespace herdr-pane-labels "$HPL_DEFAULT_SOCKET")/sweep.lock/pid")"
  pid_two="$(cat "$(hpl_cutover_namespace herdr-pane-labels "$socket_two")/sweep.lock/pid")"
  [[ "$pid_one" != "$pid_two" ]]
  kill -0 "$pid_one"
  kill -0 "$pid_two"
  assert_file_contains "$HPL_CUTOVER_TRACE" "^first-pass:$HPL_DEFAULT_SOCKET$"
  assert_file_contains "$HPL_CUTOVER_TRACE" "^first-pass:$socket_two$"
  assert_file_contains "$HPL_CUTOVER_TRACE" "^daemon-verified:$HPL_DEFAULT_SOCKET:"
  assert_file_contains "$HPL_CUTOVER_TRACE" "^daemon-verified:$socket_two:"
  grep -Fxq "$HPL_DEFAULT_SOCKET|plugin enable seigi.pane-labels" "$HPL_WORK/plugin-sockets.log"
  grep -Fxq "$socket_two|plugin enable seigi.pane-labels" "$HPL_WORK/plugin-sockets.log"
  grep -Fxq "$HPL_DEFAULT_SOCKET|server reload-config" "$HPL_WORK/plugin-sockets.log"
  grep -Fxq "$socket_two|server reload-config" "$HPL_WORK/plugin-sockets.log"
  assert_dir_not_exists "$(hpl_cutover_namespace herdr-pane-labels "$stopped_socket")/sweep.lock"
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  run jq -e '.agents[0].name | test("^[a-z]+-[a-z]+$")' "$state"
  assert_success
  run jq -e '.panes[0].label | test("^cc:[a-z]+-[a-z]+$")' "$state"
  assert_success
  run jq -e '.tabs[0].label == .panes[0].label' "$state"
  assert_success
}

@test "herdr pane-label second apply replaces the currently loaded daemon" {
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local namespace first second
  rm -f "$HPL_CUTOVER_HOME/.local/bin/herdr-task-sync"
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
  hpl_cutover_run "$HPL_CUTOVER_AFTER"
  namespace="$(hpl_cutover_namespace herdr-pane-labels "$HPL_DEFAULT_SOCKET")"
  first="$(cat "$namespace/sweep.lock/pid")"
  : > "$HPL_CUTOVER_TRACE"

  run hpl_cutover_run "$HPL_CUTOVER_BEFORE"
  assert_success
  run hpl_pid_is_live "$first"
  assert_failure
  run hpl_cutover_run "$HPL_CUTOVER_AFTER"
  assert_success
  second="$(cat "$namespace/sweep.lock/pid")"
  [[ "$second" != "$first" ]]
  kill -0 "$second"
  assert_file_contains "$HPL_CUTOVER_TRACE" "^term:daemon:$HPL_DEFAULT_SOCKET:$first$"
  assert_file_contains "$HPL_CUTOVER_TRACE" "^daemon-verified:$HPL_DEFAULT_SOCKET:$second:"
}

@test "herdr pane-label first install succeeds without Herdr sessions or old owners" {
  skip_if_no_chezmoi
  hpl_cutover_setup
  assert_file_contains "$SOURCE_ROOT/.chezmoitemplates/herdr-pane-labels-cutover-lib.sh" \
    'local root="\$1" lock pid'
  hpl_cutover_sessions
  rm -f "$HPL_CUTOVER_HOME/.local/bin/herdr-task-sync"
  local empty_path="$HPL_WORK/no-herdr-bin"
  mkdir -p "$empty_path"

  run env HOME="$HPL_CUTOVER_HOME" PATH="$empty_path:/usr/bin:/bin" \
    HERDR_PANE_LABELS_CUTOVER_TRACE="$HPL_CUTOVER_TRACE" \
    bash "$HPL_CUTOVER_BEFORE"

  assert_success
  assert_file_contains "$HPL_CUTOVER_TRACE" '^owner-free:2$'
}

@test "herdr pane-label after script links offline without live-only commands" {
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

@test "herdr pane-label after script catches a session created during plugin linking" {
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

@test "herdr pane-label after script disables known sessions when post-link discovery fails" {
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

@test "herdr pane-label post-link discovery failure disables the offline registry without sessions" {
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

@test "herdr pane-label activation failure still disables every remaining live session" {
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

@test "herdr pane-label after script rejects a failed first sweep" {
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

@test "herdr pane-label rollback artifact survives before and clears after verification" {
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf

  run hpl_cutover_run "$HPL_CUTOVER_BEFORE"
  assert_success
  assert_file_exists "$HPL_CUTOVER_HOME/.cache/herdr-pane-labels/cutover-rollback/herdr-task-sync.backup"
  assert_file_contains "$HPL_CUTOVER_HOME/.cache/herdr-pane-labels/cutover-rollback/state" '^phase=prepared$'
  assert_file_contains "$HPL_CUTOVER_HOME/.cache/herdr-pane-labels/cutover-rollback/state" '^plugin_disabled=1$'
  assert_file_contains "$HPL_CUTOVER_HOME/.cache/herdr-pane-labels/cutover-rollback/sockets" "^$HPL_DEFAULT_SOCKET$"
  rm -f "$HPL_CUTOVER_HOME/.local/bin/herdr-task-sync"
  cp "$SOURCE_ROOT/dot_local/bin/executable_herdr-child" "$HPL_CUTOVER_HOME/.local/bin/herdr-child"
  chmod +x "$HPL_CUTOVER_HOME/.local/bin/herdr-child"

  run hpl_cutover_run "$HPL_CUTOVER_AFTER"
  assert_success
  assert_dir_not_exists "$HPL_CUTOVER_HOME/.cache/herdr-pane-labels/cutover-rollback"
  assert_file_contains "$HPL_CUTOVER_TRACE" '^cutover-committed$'
}

@test "herdr pane-label after script skips missing herdr without a transaction" {
  skip_if_no_chezmoi
  hpl_cutover_setup
  mv "$HPL_STUB/herdr" "$HPL_STUB/herdr.unavailable"

  run hpl_cutover_run "$HPL_CUTOVER_AFTER"

  assert_success
  assert_output --partial "herdr not found; skipping pane-labels plugin link"
  assert_dir_not_exists "$HPL_CUTOVER_HOME/.cache/herdr-pane-labels/cutover-rollback"
}

@test "herdr pane-label after script retries when herdr disappears during cutover" {
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf

  hpl_cutover_run "$HPL_CUTOVER_BEFORE"
  rm -f "$HPL_CUTOVER_HOME/.local/bin/herdr-task-sync"
  cp "$SOURCE_ROOT/dot_local/bin/executable_herdr-child" "$HPL_CUTOVER_HOME/.local/bin/herdr-child"
  chmod +x "$HPL_CUTOVER_HOME/.local/bin/herdr-child"
  mv "$HPL_STUB/herdr" "$HPL_STUB/herdr.unavailable"

  run hpl_cutover_run "$HPL_CUTOVER_AFTER"

  assert_failure
  assert_output --partial "herdr not found; pane-label activation remains pending"
  assert_file_contains "$HPL_CUTOVER_HOME/.cache/herdr-pane-labels/cutover-rollback/state" '^phase=deployed$'
  refute_output --partial "skipping pane-labels plugin link"
}

@test "herdr pane-label deployed retry never restores the legacy child launcher" {
  command -v jq >/dev/null || skip "jq not available"
  skip_if_no_chezmoi
  hpl_cutover_setup
  local child_hash state tmp
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf

  hpl_cutover_run "$HPL_CUTOVER_BEFORE"
  rm -f "$HPL_CUTOVER_HOME/.local/bin/herdr-task-sync"
  cp "$SOURCE_ROOT/dot_local/bin/executable_herdr-child" "$HPL_CUTOVER_HOME/.local/bin/herdr-child"
  chmod +x "$HPL_CUTOVER_HOME/.local/bin/herdr-child"
  child_hash="$(shasum -a 256 "$HPL_CUTOVER_HOME/.local/bin/herdr-child" | cut -d' ' -f1)"
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  tmp="$state.tmp"
  jq '.complete=false' "$state" > "$tmp" && mv "$tmp" "$state"

  run hpl_cutover_run "$HPL_CUTOVER_AFTER"
  assert_failure
  assert_file_contains "$HPL_CUTOVER_HOME/.cache/herdr-pane-labels/cutover-rollback/state" '^phase=deployed$'
  assert_file_contains "$HPL_CUTOVER_HOME/.cache/herdr-pane-labels/cutover-rollback/state" '^child_backed_up=0$'
  assert_file_not_exists "$HPL_CUTOVER_HOME/.cache/herdr-pane-labels/cutover-rollback/herdr-child.backup"

  jq '.complete=true' "$state" > "$tmp" && mv "$tmp" "$state"
  : > "$HPL_WORK/fail-session-list"
  run hpl_cutover_run "$HPL_CUTOVER_BEFORE"
  assert_failure
  assert_equal "$(shasum -a 256 "$HPL_CUTOVER_HOME/.local/bin/herdr-child" | cut -d' ' -f1)" "$child_hash"
  assert_dir_not_exists "$HPL_CUTOVER_HOME/.cache/herdr-pane-labels/cutover-rollback"
}
