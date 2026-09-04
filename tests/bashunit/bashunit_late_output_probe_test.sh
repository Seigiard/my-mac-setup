#!/usr/bin/env bash
# post-apply: excluded
# Dedicated one-test fixture for the local bashunit patch "payload-marker
# result parsing" (docs/solutions/design-patterns/outliving-processes-hang-the-suite.md): a test's background child that
# inherits the captured stdout can append output after the ##...## payload
# line, which stock upstream 0.50.1 parses as the result line. The guard is
# owned by test_scripts_260 in tests/bashunit/scripts_test.sh.
# Vocabulary (run, assert_*, BATS_* contract) comes from
# tests/bashunit/test-dsl.bash.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

function test_late_child_output_lands_after_the_result_payload() {
  _bats_test_init 1 'late child output lands after the result payload'
  # Not $BASHPID: the suite must stay bash-3.2-clean (test-dsl.bash header),
  # and on macOS bash 3.2 $BASHPID is unset, which would end the child's wait
  # loop instantly and land the noise harmlessly before the payload. The
  # `exec` is load-bearing: without it the substitution forks once more and
  # $PPID names that already-dead fork, not this test's subshell.
  local body_pid
  body_pid=$(exec sh -c 'echo $PPID')
  # Wait for subshell death, not a sleep: the payload line is written by the
  # subshell's EXIT trap, so death is the only signal that it already exists.
  # The runner reads the capture to EOF, which the child's open descriptor
  # holds back until the noise has landed after the payload.
  (
    while kill -0 "$body_pid" 2>/dev/null; do sleep 0.01; done
    echo "late child noise after the payload line"
  ) &
  run true
  assert_success
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function tear_down() { _bats_run_teardown; }
