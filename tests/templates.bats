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
  run render_template "$SOURCE_ROOT/dot_gitconfig.tmpl"
  assert_success
}

@test "gitconfig template contains user name" {
  run render_template "$SOURCE_ROOT/dot_gitconfig.tmpl"
  assert_output --partial "name = "
}

@test "gitconfig template contains user email" {
  run render_template "$SOURCE_ROOT/dot_gitconfig.tmpl"
  assert_output --partial "email = "
}

@test "gitconfig template has no unresolved markers" {
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$SOURCE_ROOT/dot_gitconfig.tmpl" > "$BATS_TEST_TMPFILE"
  assert_no_template_markers "$BATS_TEST_TMPFILE"
}

# ===========================================
# dot_zshenv.tmpl
# ===========================================

@test "zshenv template renders without op in PATH" {
  run render_template "$SOURCE_ROOT/dot_zshenv.tmpl"
  assert_success
}

@test "zshenv template output has no unresolved markers" {
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$SOURCE_ROOT/dot_zshenv.tmpl" > "$BATS_TEST_TMPFILE" || true
  assert_no_template_markers "$BATS_TEST_TMPFILE"
}

@test "zshenv sources Cargo environment only when readable" {
  run render_template "$SOURCE_ROOT/dot_zshenv.tmpl"
  assert_success
  assert_output --partial '[[ -r "$HOME/.cargo/env" ]] && . "$HOME/.cargo/env"'
}

# ===========================================
# dot_zshrc.tmpl
# ===========================================

@test "zshrc template renders successfully" {
  run render_template "$SOURCE_ROOT/dot_zshrc.tmpl"
  assert_success
}

@test "zshrc template has no unresolved markers" {
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$SOURCE_ROOT/dot_zshrc.tmpl" > "$BATS_TEST_TMPFILE"
  assert_no_template_markers "$BATS_TEST_TMPFILE"
}

# ===========================================
# opencode.json.tmpl (macOS-only plugin path guarded by .is_darwin)
# ===========================================

@test "opencode.json.tmpl renders valid JSON" {
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$SOURCE_ROOT/private_dot_config/opencode/opencode.json.tmpl" > "$BATS_TEST_TMPFILE"
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

@test "opencode.json.tmpl grants unbounded external-directory reads without changing integrations" {
  command_exists jq || skip "jq is required"
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$SOURCE_ROOT/private_dot_config/opencode/opencode.json.tmpl" > "$BATS_TEST_TMPFILE"

  run jq -r '.permission.external_directory["*"]' "$BATS_TEST_TMPFILE"
  assert_success
  assert_output "allow"

  run jq -r '[.mcp.fff.command[0], (.provider.openrouter.models | has("qwen/qwen3-coder:free")), .plugin[0]] | @tsv' "$BATS_TEST_TMPFILE"
  assert_success
  assert_output $'fff-mcp\ttrue\tcompound-engineering@git+https://github.com/EveryInc/compound-engineering-plugin.git'
}

@test "opencode.json.tmpl renders with no unresolved template markers" {
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$SOURCE_ROOT/private_dot_config/opencode/opencode.json.tmpl" > "$BATS_TEST_TMPFILE"
  assert_no_template_markers "$BATS_TEST_TMPFILE"
}

@test "opencode.json.tmpl omits the macOS brew plugin path on Linux" {
  is_linux || skip "Only relevant on Linux"
  run render_template "$SOURCE_ROOT/private_dot_config/opencode/opencode.json.tmpl"
  refute_output --partial "/opt/homebrew"
}

# ===========================================
# Shared writing-style template (.chezmoitemplates/writing-style.md)
# rendered into each agent's native style mechanism
# ===========================================

# includeTemplate resolves against .chezmoitemplates in the chezmoi source dir,
# so these renders must point --source at the checkout under test, not at the
# host's chezmoi clone.
render_with_source() {
  local template_file="$1"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" --source "$SOURCE_ROOT" execute-template < "$template_file"
}

@test "claude output style renders the shared writing-style rules" {
  run render_with_source "$SOURCE_ROOT/private_dot_claude/output-styles/writing-style.md.tmpl"
  assert_success
  assert_output --partial 'keep-coding-instructions: true'
  assert_output --partial 'Answer first: the conclusion is line one.'
}

@test "pi APPEND_SYSTEM renders the shared writing-style rules" {
  run render_with_source "$SOURCE_ROOT/dot_pi/agent/APPEND_SYSTEM.md.tmpl"
  assert_success
  assert_output --partial '# Writing style'
  assert_output --partial 'Answer first: the conclusion is line one.'
}

@test "shared agents/writing-style.md renders the shared rules" {
  run render_with_source "$SOURCE_ROOT/private_dot_config/agents/writing-style.md.tmpl"
  assert_success
  assert_output --partial 'Answer first: the conclusion is line one.'
}

@test "opencode instructions point at the shared writing-style file" {
  run render_template "$SOURCE_ROOT/private_dot_config/opencode/opencode.json.tmpl"
  assert_success
  assert_output --partial '"instructions"'
  assert_output --partial '"~/.config/agents/writing-style.md"'
}

@test "CLAUDE.md source no longer carries the Writing style section" {
  run grep '^## Writing style' "$SOURCE_ROOT/private_dot_claude/CLAUDE.md"
  assert_failure
}

# ===========================================
# private_settings.json.tmpl (Claude Code settings)
# ===========================================

@test "private_settings.json.tmpl renders valid JSON" {
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$SOURCE_ROOT/private_dot_claude/private_settings.json.tmpl" > "$BATS_TEST_TMPFILE"
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

@test "private_settings.json.tmpl renders the task-sync hook on all three events" {
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$SOURCE_ROOT/private_dot_claude/private_settings.json.tmpl" > "$BATS_TEST_TMPFILE"
  assert_file_contains "$BATS_TEST_TMPFILE" '"UserPromptSubmit"'
  assert_file_contains "$BATS_TEST_TMPFILE" '"PreCompact"'
  run grep -c "herdr-task-sync-hook.sh" "$BATS_TEST_TMPFILE"
  assert_success
  assert_output "3"
}

@test "private_settings.json.tmpl has no unresolved template markers" {
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$SOURCE_ROOT/private_dot_claude/private_settings.json.tmpl" > "$BATS_TEST_TMPFILE"
  assert_no_template_markers "$BATS_TEST_TMPFILE"
}

# ===========================================
# .chezmoiremove
# ===========================================

@test ".chezmoiremove entries are absent from the source tree" {
  assert_file_exists "$SOURCE_ROOT/.chezmoiremove"

  # A path listed in .chezmoiremove that still exists in the source tree tells
  # chezmoi to both create and delete the same target, and `apply` aborts with
  # "inconsistent state". Only `apply` reports it — diff, status, verify and
  # managed all exit 0 on the broken tree — so the guard has to live here.
  # A stray untracked file (an editor or hook cache) inside a deleted directory
  # is enough to resurrect it.
  local conflicts=""
  local entry
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -z "$entry" || "$entry" == \#* || "$entry" == '!'* ]] && continue
    if PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" source-path \
        --source "$SOURCE_ROOT" "$HOME/$entry" >/dev/null 2>&1; then
      conflicts+="  $entry"$'\n'
    fi
  done < "$SOURCE_ROOT/.chezmoiremove"

  [[ -z "$conflicts" ]] || fail "listed in .chezmoiremove but still in the source tree:"$'\n'"$conflicts"
}
