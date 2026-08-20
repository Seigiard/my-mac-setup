#!/usr/bin/env bats

load 'helpers/common'

# These tests run a real `chezmoi apply` against the shared $HOME that every
# other test file reads deployed state from. Two of them applying at once would
# race, so this file stays sequential even when the suite runs with --jobs.
# It is 1.3 s of a 268 s suite, so serializing it costs nothing measurable.
BATS_NO_PARALLELIZE_WITHIN_FILE=true

# All chezmoi commands use PATH_WITHOUT_OP to prevent 1Password auth
# prompts during testing. CHEZMOI_BIN holds the resolved chezmoi path.

# ===========================================
# Idempotency tests
# ===========================================

@test "chezmoi apply succeeds" {
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" apply --source="$CHEZMOI_SOURCE" --force --verbose
  assert_success
}

@test "second chezmoi apply succeeds (idempotency)" {
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" apply --source="$CHEZMOI_SOURCE" --force
  assert_success
}

@test "chezmoi diff is empty after apply (no pending changes)" {
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" apply --source="$CHEZMOI_SOURCE" --force
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" diff --source="$CHEZMOI_SOURCE"
  assert_output ""
}

@test "chezmoi verify succeeds" {
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" verify --source="$CHEZMOI_SOURCE"
  assert_success
}
