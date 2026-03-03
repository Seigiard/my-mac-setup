#!/usr/bin/env bats

load 'helpers/common'

@test "bats-assert is loaded (assert_success available)" {
  run true
  assert_success
}

@test "bats-file is loaded (assert_file_exists available)" {
  assert_file_exists /etc/hosts
}

@test "render_template helper is available" {
  run type render_template
  assert_success
}

@test "assert_no_template_markers helper is available" {
  run type assert_no_template_markers
  assert_success
}

@test "skip_if_no_chezmoi helper works when chezmoi present" {
  if ! command -v chezmoi >/dev/null 2>&1; then
    skip "chezmoi not installed"
  fi
  skip_if_no_chezmoi
}

@test "existing helpers preserved: command_exists works" {
  run command_exists bash
  assert_success
}

@test "existing helpers preserved: get_os returns valid value" {
  run get_os
  assert_success
  [[ "$output" == "darwin" || "$output" == "linux" || "$output" == "unknown" ]]
}
