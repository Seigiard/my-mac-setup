#!/usr/bin/env bash
# post-apply: 55 host-safe
# zsh-reserved-name-guard suite — bashunit source. Vocabulary (run, assert_*,
# skip, BATS_* contract) comes from tests/bashunit/test-dsl.bash.
#
# Consumer: the Claude Code hook, opencode plugin, and pi extension all shell
# out to this engine and trust its exit contract. Observable failure: the
# engine stops flagging reserved-name assignments (agents keep shipping
# `cmd; status=$?; exit $status`, whose failed assignment leaves $? at 1 so the
# exit reports a fabricated failure) or starts flagging ordinary commands
# (every agent Bash call gets denied). Oracle: live zsh — it is zsh, not this
# repo, that decides which names are readonly or tied — plus the usage contract
# in the engine's header, exercised with fixture command strings.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/common'

GUARD="$SOURCE_ROOT/dot_local/bin/executable_zsh-reserved-name-guard"

run_guard() {
  run bash -c 'printf "%s\n" "$1" | bash "$0"' "$GUARD" "$1"
}

function test_zsh_reserved_001_flags_the_status_capture_idiom() {
  _bats_test_init 1 'flags the status capture idiom'
  # The pinned text is the "zsh-reserved-name-guard:" prefix, the only part of
  # this report a consumer parses: the opencode adapter
  # (home/private_dot_config/opencode/plugins/zsh-reserved-name-guard.ts)
  # rethrows the engine's stdout only when
  # error.message.startsWith("zsh-reserved-name-guard:"), and swallows it
  # otherwise. Lose the prefix and the guard fails open in opencode. The rest
  # of the wording is prose nothing reads; the line number is produced from
  # this test's own fixture, so it stays.
  run_guard 'make test-ubuntu; status=$?; print -- FINAL_EXIT:$status; exit $status'
  assert_failure
  assert_output --partial "zsh-reserved-name-guard:"
  assert_output --partial "line 1"
}

function test_zsh_reserved_002_reading_status_is_not_an_assignment() {
  _bats_test_init 2 'reading status is not an assignment'
  # Control for the whole gate: the marker one-liner an agent hands to a herdr
  # pane reads $status and must keep working, or the guard blocks the very
  # pattern it is meant to make safe.
  run_guard 'print -- ALIAS_MERGE_UBUNTU_FINAL_EXIT:$status; sleep 30; exit $status'
  assert_success
  assert_output ""
}

function test_zsh_reserved_003_reserved_name_outside_command_position_passes() {
  _bats_test_init 3 'reserved name outside command position passes'
  # Control for the command-position rule: quoted output and long options carry
  # "status=" without assigning anything.
  run_guard 'rc=$?; echo "status=$rc"; gh run view --status=completed'
  assert_success
  assert_output ""
}

function test_zsh_reserved_004_heredoc_body_passes() {
  _bats_test_init 4 'heredoc body passes'
  # A script written into a file runs under its own interpreter, not under the
  # zsh executing this command, so its assignments are none of the gate's
  # business.
  local fixture='cat > /tmp/probe.sh <<EOF
make check
status=$?
exit $status
EOF'
  run_guard "$fixture"
  assert_success
  assert_output ""
}

function test_zsh_reserved_005_zsh_ok_comment_releases_the_command() {
  _bats_test_init 5 'zsh-ok comment releases the command'
  # oracle: engine header — the documented escape hatch for an assignment that
  # genuinely runs under bash.
  run_guard 'bash -c "true; status=\$?; exit \$status"  # zsh-ok: bash -c body'
  assert_success
  assert_output ""
}

function test_zsh_reserved_006_empty_input_fails_open() {
  _bats_test_init 6 'empty input fails open'
  # oracle: engine header — fails open so a broken adapter never blocks a call.
  run bash -c 'printf "" | bash "$0"' "$GUARD"
  assert_success
}

function test_zsh_reserved_007_every_blocked_name_is_one_zsh_rejects() {
  _bats_test_init 7 'every blocked name is one zsh rejects'
  # The two sides are independent: zsh decides which parameters are readonly,
  # the engine decides what to block. This asserts they agree, so a name the
  # engine quietly drops — or one zsh stops reserving — fails the suite.
  command -v zsh >/dev/null || skip "zsh not available"
  local name
  for name in status ARGC PPID HISTCMD LINENO; do
    run zsh -c "$name=1"
    assert_failure

    run_guard "$name=1"
    assert_failure
    assert_output --partial "zsh-reserved-name-guard:"
  done
}

function test_zsh_reserved_008_an_ordinary_name_zsh_accepts_is_not_blocked() {
  _bats_test_init 8 'an ordinary name zsh accepts is not blocked'
  # Control paired with test 7: the replacement the report recommends must
  # survive both zsh and the engine, or the guard has no usable escape.
  command -v zsh >/dev/null || skip "zsh not available"
  run zsh -c 'rc=1; exit $rc'
  assert_failure  # exit 1 comes from the assignment's value, not from zsh refusing it
  assert_output ""

  run_guard 'make check; rc=$?; exit $rc'
  assert_success
  assert_output ""
}

function test_zsh_reserved_009_assigning_path_destroys_PATH_and_is_blocked() {
  _bats_test_init 9 'assigning path destroys PATH and is blocked'
  # zsh ties `path` to PATH; the damage is observable, which is why the engine
  # gates a name that is not readonly.
  command -v zsh >/dev/null || skip "zsh not available"
  run zsh -c 'path=/nonexistent-guard-probe; printf "%s\n" "$PATH"'
  assert_success
  assert_output "/nonexistent-guard-probe"

  run_guard 'path=/usr/bin; ls'
  assert_failure
  assert_output --partial "zsh-reserved-name-guard:"
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function tear_down() { _bats_run_teardown; }
