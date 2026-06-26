#!/usr/bin/env bats

load 'helpers/common'

teardown() {
  [[ -n "${BATS_TEST_TMPFILE:-}" ]] && rm -f "$BATS_TEST_TMPFILE" || true
}

# ===========================================
# install-packages script
# ===========================================

@test "install-packages script renders as valid bash" {
  skip_if_no_chezmoi
  local script="$CHEZMOI_SOURCE/.chezmoiscripts/run_onchange_after_install-packages.sh.tmpl"
  [[ -f "$script" ]] || skip "install-packages script not found at $script"

  BATS_TEST_TMPFILE="$(mktemp /tmp/install-packages-XXXXXX.sh)"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" execute-template < "$script" > "$BATS_TEST_TMPFILE"
  run bash -n "$BATS_TEST_TMPFILE"
  assert_success
}

@test "install-packages script uses set -e" {
  local script="$CHEZMOI_SOURCE/.chezmoiscripts/run_onchange_after_install-packages.sh.tmpl"
  [[ -f "$script" ]] || skip "install-packages script not found at $script"
  run grep -q "set -e" "$script"
  assert_success
}

@test "install-packages template has no rendering errors" {
  skip_if_no_chezmoi
  local script="$CHEZMOI_SOURCE/.chezmoiscripts/run_onchange_after_install-packages.sh.tmpl"
  [[ -f "$script" ]] || skip "install-packages script not found at $script"
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" execute-template < "$script"
  assert_success
}

# ===========================================
# macOS tunes script
# ===========================================

@test "macos-tunes script exists in darwin-specific directory" {
  assert_file_exists "$CHEZMOI_SOURCE/.chezmoiscripts/darwin/run_once_after_macos-tunes.sh"
}

@test "macos-tunes script is valid bash" {
  local script="$CHEZMOI_SOURCE/.chezmoiscripts/darwin/run_once_after_macos-tunes.sh"
  run bash -n "$script"
  assert_success
}

@test "macos-tunes script uses set -e" {
  local script="$CHEZMOI_SOURCE/.chezmoiscripts/darwin/run_once_after_macos-tunes.sh"
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
# ask-agent skill scripts
# ===========================================

ASK_AGENT_DIR="$CHEZMOI_SOURCE/private_dot_claude/skills/ask-agent/scripts"

@test "ask-agent scripts are valid bash" {
  for s in ask.sh agents/claude.sh agents/opencode.sh agents/pi.sh; do
    run bash -n "$ASK_AGENT_DIR/$s"
    assert_success
  done
}

@test "ask.sh uses set -euo pipefail" {
  run grep -q "set -euo pipefail" "$ASK_AGENT_DIR/ask.sh"
  assert_success
}

@test "ask.sh with no args exits 2" {
  run bash "$ASK_AGENT_DIR/ask.sh"
  assert_failure 2
}

@test "ask.sh with an unknown agent exits 2 and lists the valid agents" {
  run bash "$ASK_AGENT_DIR/ask.sh" bogus "question"
  assert_failure 2
  assert_output --partial "claude opencode pi"
}

@test "ask.sh claude read-only maps to allowlist plus explicit deny" {
  local stubdir; stubdir="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*"\n' > "$stubdir/claude"
  chmod +x "$stubdir/claude"
  run env PATH="$stubdir:$PATH" HERDR_ENV="" bash "$ASK_AGENT_DIR/ask.sh" claude "hi there"
  rm -rf "$stubdir"
  assert_success
  assert_output --partial -- "-p hi there"
  assert_output --partial -- "--allowed-tools Read Grep Glob WebFetch WebSearch"
  assert_output --partial -- "--disallowed-tools Bash Edit Write"
}
