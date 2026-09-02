#!/usr/bin/env bash
# test-oracle-guard suite — bashunit source. Vocabulary (run, assert_*,
# skip, BATS_* contract) comes from tests/bashunit/test-dsl.bash.
#
# Consumer: the Claude Code hook, opencode plugin, and pi extension all shell
# out to this engine and trust its exit contract. Observable failure: the
# engine stops flagging unjustified negative assertions (weak absence tests
# slip back into repos) or starts flagging clean edits (every agent edit to a
# test file gets blocked). Oracle: the usage contract in the engine's header,
# exercised behaviorally with fixture content independent of the engine source.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/common'

GUARD="$SOURCE_ROOT/dot_local/bin/executable_test-oracle-guard"

run_guard() {
  local path="$1" fixture="$2"
  run bash -c 'printf "%s\n" "$2" | bash "$0" "$1"' "$GUARD" "$path" "$fixture"
}

function test_oracle_guard_001_non_test_file_passes_even_with_negative_assertion() {
  _bats_test_init 1 'non-test file passes even with negative assertion'
  # oracle: engine header — the gate applies to test files only.
  run_guard "src/deploy.sh" 'assert_not_contains "$output" "worktrunk"'
  assert_success
  assert_output ""
}

function test_oracle_guard_002_flags_negative_assertion_in_test_file() {
  _bats_test_init 2 'flags negative assertion in test file'
  # oracle: engine header — unjustified negative assertion exits 1 with reason.
  run_guard "tests/bashunit/smoke_test.sh" 'assert_not_contains "$palette" "worktrunk"'
  assert_failure
  assert_output --partial "without a named oracle"
  assert_output --partial "line 1"
}

function test_oracle_guard_003_oracle_comment_within_three_lines_passes() {
  _bats_test_init 3 'oracle comment within three lines passes'
  # oracle: engine header — the "oracle:" escape hatch admits justified lines.
  local fixture='# oracle: deployed uninstall boundary, seeded stale plugin
assert_not_contains "$active_plugins" "legacy-tool"'
  run_guard "tests/bashunit/smoke_test.sh" "$fixture"
  assert_success
  assert_output ""
}

function test_oracle_guard_004_oracle_comment_farther_than_three_lines_does_not_cover() {
  _bats_test_init 4 'oracle comment farther than three lines does not cover'
  # oracle: engine header — the escape hatch spans the flagged line plus 3 above.
  local fixture='# oracle: too far away to count
line two
line three
line four
assert_not_contains "$palette" "worktrunk"'
  run_guard "tests/bashunit/smoke_test.sh" "$fixture"
  assert_failure
  assert_output --partial "line 5"
}

function test_oracle_guard_005_positive_assertions_pass_untouched() {
  _bats_test_init 5 'positive assertions pass untouched'
  # oracle: engine header — only negative-assertion patterns are gated; this
  # control keeps the guard from blocking ordinary test edits.
  local fixture='assert_file_contains "$HOME/.zshrc" "starship init"
assert_success
assert_output --partial "applied"'
  run_guard "tests/bashunit/smoke_test.sh" "$fixture"
  assert_success
  assert_output ""
}

function test_oracle_guard_006_missing_path_fails_open() {
  _bats_test_init 6 'missing path fails open'
  # oracle: engine header — fails open so a broken adapter never blocks edits.
  run bash -c 'printf "x\n" | bash "$0"' "$GUARD"
  assert_success
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function tear_down() { _bats_run_teardown; }
