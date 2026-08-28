#!/usr/bin/env bats
# Negative-control fixture for the bats->bashunit per-scenario verifier.
# One passing, one skipped (with reason), one deliberately failing, one more
# passing scenario. The failing scenario is the "semantic" canary: a shim that
# silently weakens assert_output would flip it to pass on the bashunit side,
# and the verifier must report the status mismatch.

load '../../helpers/common'

@test "control passing scenario" {
  run echo hello
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "control skipped scenario" {
  skip "control skip reason"
  false
}

@test "control failing scenario" {
  run echo actual-output
  [ "$status" -eq 0 ]
  assert_output "expected-but-absent"
}

@test "control second passing scenario" {
  run true
  [ "$status" -eq 0 ]
}
