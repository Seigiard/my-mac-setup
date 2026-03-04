#!/usr/bin/env bats

load 'helpers/common'

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
