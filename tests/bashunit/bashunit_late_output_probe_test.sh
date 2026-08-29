#!/usr/bin/env bash
# Dedicated one-test fixture for the local bashunit patch "payload-marker
# result parsing" (docs/issues/2026-08-29-003-pinned-bashunit-carries-a-local-
# patch-payload-marker-result-parsing). A test's background child that
# inherits the captured stdout can append output after the ##...## payload
# line; stock upstream 0.50.1 then parses that garbage as the result line and
# reports a phantom failed test with zero failed assertions and no name.
# scripts_test.sh runs this file under a nested `tests/lib/bashunit -j`
# invocation and requires a clean 1-passed verdict, so a re-pin of bashunit
# that drops the patch (sites marked 'Local patch vs upstream 0.50.1') turns
# that guard red instead of resurfacing as anonymous CI failures.
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
  # The child inherits this test's captured stdout. It waits for the test
  # subshell to die -- by then bashunit's EXIT trap has written the payload
  # line to the capture -- then appends noise and closes the descriptor.
  # Ordering is deterministic: the runner's command substitution (and the
  # parallel .result writer fed from it) reads the capture to EOF, which it
  # cannot reach before the noise lands after the payload.
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
