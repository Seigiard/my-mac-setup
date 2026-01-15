#!/usr/bin/env bats

load 'helpers/common'

# ===========================================
# Idempotency tests
# ===========================================

@test "chezmoi apply succeeds" {
  run chezmoi apply --source="$CHEZMOI_SOURCE" --verbose
  echo "Output: $output"
  [[ "$status" -eq 0 ]]
}

@test "second chezmoi apply succeeds (idempotency)" {
  run chezmoi apply --source="$CHEZMOI_SOURCE"
  echo "Output: $output"
  [[ "$status" -eq 0 ]]
}

@test "chezmoi diff is empty after apply (no pending changes)" {
  # First ensure we've applied
  chezmoi apply --source="$CHEZMOI_SOURCE"

  # Then check diff is empty
  run chezmoi diff --source="$CHEZMOI_SOURCE"
  echo "Diff output: $output"

  # Diff should be empty (no output)
  [[ -z "$output" ]]
}

@test "chezmoi verify succeeds" {
  run chezmoi verify --source="$CHEZMOI_SOURCE"
  echo "Output: $output"
  [[ "$status" -eq 0 ]]
}
