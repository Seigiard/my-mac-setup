#!/usr/bin/env bats

load 'helpers/common'

setup() {
  skip_if_no_chezmoi
  export CHEZMOI_NAME="Test User"
  export CHEZMOI_EMAIL="test@example.com"
}

teardown() {
  [[ -n "${BATS_TEST_TMPFILE:-}" ]] && rm -f "$BATS_TEST_TMPFILE" || true
}

# ===========================================
# .chezmoi.yaml.tmpl (validated via chezmoi data — init-only template
# uses promptStringOnce which is unavailable in execute-template)
# ===========================================

@test "chezmoi data contains name from env var" {
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" data --format json
  assert_success
  assert_output --partial '"name"'
}

@test "chezmoi data contains email from env var" {
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" data --format json
  assert_success
  assert_output --partial '"email"'
}

# ===========================================
# dot_gitconfig.tmpl
# ===========================================

@test "gitconfig template renders successfully" {
  run render_template "$CHEZMOI_SOURCE/dot_gitconfig.tmpl"
  assert_success
}

@test "gitconfig template contains user name" {
  run render_template "$CHEZMOI_SOURCE/dot_gitconfig.tmpl"
  assert_output --partial "name = "
}

@test "gitconfig template contains user email" {
  run render_template "$CHEZMOI_SOURCE/dot_gitconfig.tmpl"
  assert_output --partial "email = "
}

@test "gitconfig template has no unresolved markers" {
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$CHEZMOI_SOURCE/dot_gitconfig.tmpl" > "$BATS_TEST_TMPFILE"
  assert_no_template_markers "$BATS_TEST_TMPFILE"
}

# ===========================================
# dot_zshenv.tmpl
# ===========================================

@test "zshenv template renders without op in PATH" {
  run render_template "$CHEZMOI_SOURCE/dot_zshenv.tmpl"
  assert_success
}

@test "zshenv template output has no unresolved markers" {
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$CHEZMOI_SOURCE/dot_zshenv.tmpl" > "$BATS_TEST_TMPFILE" || true
  assert_no_template_markers "$BATS_TEST_TMPFILE"
}

# ===========================================
# dot_zshrc.tmpl
# ===========================================

@test "zshrc template renders successfully" {
  run render_template "$CHEZMOI_SOURCE/dot_zshrc.tmpl"
  assert_success
}

@test "zshrc template has no unresolved markers" {
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$CHEZMOI_SOURCE/dot_zshrc.tmpl" > "$BATS_TEST_TMPFILE"
  assert_no_template_markers "$BATS_TEST_TMPFILE"
}

# ===========================================
# opencode.json.tmpl (macOS-only plugin path guarded by .is_darwin)
# ===========================================

@test "opencode.json.tmpl renders valid JSON" {
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$CHEZMOI_SOURCE/private_dot_config/opencode/opencode.json.tmpl" > "$BATS_TEST_TMPFILE"
  if command_exists jq; then
    run jq empty "$BATS_TEST_TMPFILE"
  elif command_exists python3; then
    run python3 -m json.tool "$BATS_TEST_TMPFILE"
  elif command_exists node; then
    run node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$BATS_TEST_TMPFILE"
  else
    skip "no JSON parser available (jq/python3/node)"
  fi
  assert_success
}

@test "opencode.json.tmpl renders with no unresolved template markers" {
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$CHEZMOI_SOURCE/private_dot_config/opencode/opencode.json.tmpl" > "$BATS_TEST_TMPFILE"
  assert_no_template_markers "$BATS_TEST_TMPFILE"
}

@test "opencode.json.tmpl omits the macOS brew plugin path on Linux" {
  is_linux || skip "Only relevant on Linux"
  run render_template "$CHEZMOI_SOURCE/private_dot_config/opencode/opencode.json.tmpl"
  refute_output --partial "/opt/homebrew"
}
