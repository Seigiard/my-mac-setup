#!/usr/bin/env bats
# Leak-detection fixture: the honest version leaves nothing behind. The
# negative-control runner mutates the CONVERTED side to leave a background
# process and a /tmp path matching the harness leak patterns, and asserts the
# compare harness reports LEAK-PROCESS and LEAK-PATH.

@test "leak fixture scenario" {
  run echo clean
  [ "$status" -eq 0 ]
}
