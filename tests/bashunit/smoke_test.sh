#!/usr/bin/env bash
# post-apply: 10 host-safe
# smoke post-apply suite — bashunit source. Vocabulary (run, assert_*,
# skip, BATS_* contract) comes from tests/bashunit/test-dsl.bash.
# Migrated from smoke.bats; parity evidence: docs/benchmarks/bashunit-full-suite-experiment.md.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"


load 'helpers/common'

# ===========================================
# python3 -- the declared interpreter
# ===========================================

# This file loses no skip guard, but it holds eight of the nine bare `run
# python3` call sites, so a contributor running it alone still needs the cause
# named rather than inferred from the failures.
function test_smoke_001_python3_is_present_and_at_least_3_9_the_floor_re() {
  _bats_test_init 1 'python3 is present and at least 3.9, the floor README.md declares'
  run assert_python3_available
  assert_success
}

function test_smoke_003_post_apply_suite_wrapper_rejects_an_unknown_mode() {
  _bats_test_init 3 'post-apply suite wrapper rejects an unknown mode with usage'
  local repository_root
  repository_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  [[ -x "$repository_root/tests/run-post-apply.sh" ]] || skip "repository checkout is not mounted"

  run "$repository_root/tests/run-post-apply.sh" unknown
  [ "$status" -eq 2 ]
  assert_output --partial "usage: tests/run-post-apply.sh full|host-safe"
}

# Covers the suite-end orphan guard (docs/issues/2026-08-28-001). The
# near-miss controls are load-bearing: a dead launcher with a surviving run
# dir is a concurrent run's legitimately held watcher, not an orphan.
# MMS_BASHUNIT_BIN=/usr/bin/true stubs the per-file runs so only the guard
# executes.
function test_smoke_076_post_apply_orphan_guard_reaps_only_abandoned_wat() {
  _bats_test_init 76 'post-apply orphan guard reaps only abandoned watchers'
  local repository_root
  repository_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  [[ -x "$repository_root/tests/run-post-apply.sh" ]] || skip "repository checkout is not mounted"
  local watcher_argv="$repository_root/home/dot_local/bin/executable_herdr-child __watcher"

  local dead_pid
  true & dead_pid=$!
  wait "$dead_pid" || true

  local live_run_dir="$BATS_TEST_TMPDIR/guard-live-run"
  local stop_fakes="$BATS_TEST_TMPDIR/stop-fakes"
  mkdir -p "$live_run_dir"
  # Fakes poll a stop file rather than sleep for a fixed lifetime, which
  # would flake under load. The 300 x 0.2s cap keeps a failed assertion
  # (which skips the stop-file write) a bounded red test instead of a hang;
  # stdio is detached so no child holds the runner's output pipe open.
  bash -c 'n=0; until [ -e "$1" ] || [ "$n" -ge 300 ]; do n=$((n + 1)); sleep 0.2; done' \
    "guard-fake-live-launcher $watcher_argv --run-dir $BATS_TEST_TMPDIR/gone --launcher-pid $$" \
    "$stop_fakes" </dev/null >/dev/null 2>&1 &
  local live_launcher_fake=$!
  bash -c 'n=0; until [ -e "$1" ] || [ "$n" -ge 300 ]; do n=$((n + 1)); sleep 0.2; done' \
    "guard-fake-live-rundir $watcher_argv --run-dir $live_run_dir --launcher-pid $dead_pid" \
    "$stop_fakes" </dev/null >/dev/null 2>&1 &
  local live_rundir_fake=$!

  run env MMS_BASHUNIT_BIN=/usr/bin/true "$repository_root/tests/run-post-apply.sh" host-safe
  assert_success
  kill -0 "$live_launcher_fake"
  kill -0 "$live_rundir_fake"

  bash -c 'n=0; until [ -e "$1" ] || [ "$n" -ge 300 ]; do n=$((n + 1)); sleep 0.2; done' \
    "guard-fake-orphan $watcher_argv --run-dir $BATS_TEST_TMPDIR/gone --launcher-pid $dead_pid" \
    "$stop_fakes" </dev/null >/dev/null 2>&1 &
  local orphan_fake=$!
  run env MMS_BASHUNIT_BIN=/usr/bin/true "$repository_root/tests/run-post-apply.sh" host-safe
  [ "$status" -eq 1 ]
  assert_output --partial "ORPHANED herdr-child watcher survived the suite"
  local attempt=0
  while kill -0 "$orphan_fake" 2>/dev/null && [ "$attempt" -lt 300 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  run kill -0 "$orphan_fake"
  assert_failure

  : > "$stop_fakes"
  wait "$live_launcher_fake" "$live_rundir_fake" 2>/dev/null || true
}

# ===========================================
# Chezmoi-managed files exist
# ===========================================

# One manifest replaces the per-file existence tests. A file that falls out of
# management (a .chezmoiignore edit, a lost dot_ prefix) keeps `chezmoi verify`
# green — verify only checks what is still managed — so deployment and
# management membership are both asserted against this curated list.
function test_smoke_004_critical_managed_files_are_deployed_and_still_ma() {
  _bats_test_init 4 'critical managed files are deployed and still managed'
  local paths=(
    .zshrc
    .aliases
    .gitconfig
    .gitignore
    .editorconfig
    .config/starship.toml
    .config/yazi
    .claude
    .claude/CLAUDE.md
    .pi/agent/extensions/agents-local.ts
    .config/herdr/config.toml
    .config/herdr/plugins/command-palette/herdr-plugin.toml
    .config/herdr/plugins/command-palette/open.py
    .config/herdr/plugins/command-palette/open_in_zed.py
    .config/herdr/plugins/command-palette/palette.py
    .config/herdr/plugins/command-palette/smart_close.py
    .config/herdr/plugins/worktree-setup/herdr-plugin.toml
    .config/herdr/plugins/worktree-setup/setup.ts
    .config/herdr/plugins/config/seigi.worktree-setup/config.toml
    .config/herdr/command-palette/commands.toml
    .local/lib/herdr-process.sh
    .local/lib/herdr-child-runtime.sh
    .local/lib/herdr-child-supervision.sh
    .local/lib/herdr-child-watcher.sh
    .local/lib/herdr-child-launch.sh
    .local/lib/herdr-child-continuation.sh
    .local/lib/herdr-child-reap.sh
  )
  if is_macos; then
    paths+=(
      .hammerspoon
      .config/ghostty
      .config/kitty/kitty.conf
      .config/kitty/herdr.conf
      .config/karabiner
      .config/zed
      .config/herdr/plugins/herdr-caffeinate/herdr-plugin.toml
      .config/herdr/plugins/herdr-caffeinate/reconcile.sh
      .config/herdr/plugins/herdr-caffeinate/lib.sh
      .config/herdr/plugins/herdr-caffeinate/actions.sh
      .config/herdr/plugins/herdr-caffeinate/config.example.sh
      .config/herdr/plugins/herdr-focus-notify/herdr-plugin.toml
      .config/herdr/plugins/herdr-focus-notify/notify.py
    )
  fi

  local p missing=""
  for p in "${paths[@]}"; do
    [ -e "$HOME/$p" ] || missing="$missing $p"
  done
  [ -z "$missing" ] || fail "missing from \$HOME:$missing"

  command_exists chezmoi || return 0
  local managed unmanaged=""
  run env PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" managed
  assert_success
  managed="$output"
  for p in "${paths[@]}"; do
    case $'\n'"$managed"$'\n' in
      *$'\n'"$p"$'\n'*) ;;
      *$'\n'"$p"/*) ;;
      *) unmanaged="$unmanaged $p" ;;
    esac
  done
  [ -z "$unmanaged" ] || fail "deployed but no longer chezmoi-managed:$unmanaged"
}

function test_smoke_005_gitignore_ignores_the_agent_trash_directory() {
  _bats_test_init 5 '.gitignore ignores the agent trash directory'
  local repo="$BATS_TEST_TMPDIR/gitignore-probe"
  mkdir -p "$repo/.scratchpad"
  run git -C "$repo" init --quiet
  assert_success
  run git -C "$repo" check-ignore --quiet .scratchpad/probe
  assert_success
}

# Literal consumed outside this repo: herdr's own TOML parser reads this exact
# key at startup and binds the palette open action to it. No code here calls
# herdr to observe the binding, so the deployed literal is the whole contract.
function test_smoke_006_herdr_command_palette_keybinding_is_configured() {
_bats_test_init 6 'herdr command palette keybinding is configured'
assert_file_contains "$HOME/.config/herdr/config.toml" "seigi.command-palette.open"
}

function test_smoke_007_obsolete_plugin_removal_accepts_formatted_plugin_j() {
  _bats_test_init 7 'obsolete plugin removal accepts formatted plugin JSON'
  local script="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_7-install-herdr-github-plugins.sh.tmpl"
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  local calls="$BATS_TEST_TMPDIR/herdr.calls"
  mkdir -p "$fake_bin"

  cat > "$fake_bin/uname" <<'SH'
#!/bin/sh
printf 'Darwin\n'
SH
  cat > "$fake_bin/herdr" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HERDR_CALLS"
if [ "$*" = "plugin list --json" ]; then
  cat <<'JSON'
{
  "result": {
    "plugins": [
      { "plugin_id": "artisann.zed-herdr" },
      { "plugin_id": "worktrunk" }
    ]
  }
}
JSON
fi
exit 0
SH
  chmod +x "$fake_bin/uname" "$fake_bin/herdr"

  run env HERDR_CALLS="$calls" PATH="$fake_bin:$PATH" bash "$script"
  assert_success
  run grep -Fx "plugin uninstall artisann.zed-herdr" "$calls"
  assert_success
  run grep -Fx "plugin uninstall worktrunk" "$calls"
  assert_success
  run grep -Fx "plugin install dio16/herdr-auto-update -y" "$calls"
  assert_success
}

function test_smoke_008_obsolete_plugin_removal_reports_malformed_entries() {
  _bats_test_init 8 'obsolete plugin removal reports malformed plugin entries'
  local script="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_7-install-herdr-github-plugins.sh.tmpl"
  local fake_bin="$BATS_TEST_TMPDIR/bin-malformed"
  mkdir -p "$fake_bin"

  cat > "$fake_bin/uname" <<'SH'
#!/bin/sh
printf 'Darwin\n'
SH
  cat > "$fake_bin/herdr" <<'SH'
#!/bin/sh
if [ "$*" = "plugin list --json" ]; then
  printf '{"result":{"plugins":[null,{"plugin_id":"worktrunk"}]}}\n'
fi
exit 0
SH
  chmod +x "$fake_bin/uname" "$fake_bin/herdr"

  run env PATH="$fake_bin:$PATH" bash "$script"
  assert_success
  assert_output --partial "failed to inspect obsolete plugin artisann.zed-herdr"
}

# Literal consumed outside this repo: herdr's auto-update plugin reads
# `trusted_owners` at runtime and only auto-installs plugin updates from that
# allowlist — a real security boundary, not decoration. Reads the deployed
# $HOME copy (not $SOURCE_ROOT) so this actually proves chezmoi placed the
# file, matching every other assertion in this suite.
function test_smoke_009_herdr_plugin_updates_are_automatic_and_owner_res() {
  _bats_test_init 9 'herdr plugin updates are automatic and owner-restricted'
  local config="$HOME/.config/herdr/plugins/config/herdr-auto-update/config.toml"

  assert_file_exists "$config"
  assert_file_contains "$config" 'auto_update = true'
  assert_file_contains "$config" 'trusted_owners = \["dio16"\]'
}

# Literal consumed outside this repo: herdr's plugin manifest parser matches
# this exact `id` to register the palette entry, same category as test 006.
function test_smoke_010_herdr_lazygit_popup_entrypoint_is_configured() {
  _bats_test_init 10 'herdr lazygit popup entrypoint is configured'
  assert_file_contains "$HOME/.config/herdr/plugins/command-palette/herdr-plugin.toml" 'id = "lazygit"'
}

function test_smoke_013_herdr_command_palette_loads_toml_and_project_loc() {
  _bats_test_init 13 'herdr command palette loads TOML and project-local commands'
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/global" "$tmpdir/repo/sub" "$tmpdir/repo/.herdr/command-palette"
  cat > "$tmpdir/global/commands.toml" <<'TOML'
[[commands]]
title = "Global TOML"
type = "shell"
command = "echo global"

[[commands]]
name = "Search"
type = "form"
command = "echo {value_q}"

[commands.form]
prompt = "Search for"
TOML
  cat > "$tmpdir/repo/.herdr/command-palette/project.toml" <<'TOML'
name = "Project Choice"
type = "select"
command = "echo {value_q}"

[[options]]
label = "One"
value = "one"
TOML

  run env HERDR_COMMAND_PALETTE_CONFIG="$tmpdir/global/commands.toml" HERDR_TARGET_CWD="$tmpdir/repo/sub" python3 - <<'PY'
import importlib.util, os, sys
path=os.path.expanduser("~/.config/herdr/plugins/command-palette/palette.py")
spec=importlib.util.spec_from_file_location("palette", path)
mod=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=mod
spec.loader.exec_module(mod)
cfg, cmds = mod.load_commands()
by_title = {cmd.title: cmd for cmd in cmds}
assert cfg.name == "commands.toml"
assert by_title["Project Choice"].origin == "Project"
assert by_title["Project Choice"].kind == "select"
assert by_title["Search"].kind == "form"
assert by_title["Global TOML"].origin == "Global"
assert mod.command_kind({"name": "Default Shell", "command": "echo hi"}) == "shell"
assert mod.context_vars(cfg)["project_root"].endswith("/repo")
PY
  assert_success
  rm -rf "$tmpdir"
}

# ===========================================
# Claude Code configuration
# ===========================================

function test_smoke_014_writing_style_output_style_is_deployed_and_enabl() {
  _bats_test_init 14 'writing-style output style is deployed and enabled in settings'
  assert_file_exists "$HOME/.claude/output-styles/writing-style.md"
  run jq -e '.outputStyle == "writing-style"' "$HOME/.claude/settings.json"
  assert_success
}

# Pi appends this exact filename to its system prompt by convention, with no
# settings.json toggle to check the way Claude (test 014) and OpenCode (test
# 018) have — so unlike those two, the deployed path itself is the entire
# wiring contract for Pi and there is nothing cheaper to verify against.
function test_smoke_015_pi_append_system_md_is_deployed() {
  _bats_test_init 15 'pi APPEND_SYSTEM.md is deployed'
  assert_file_exists "$HOME/.pi/agent/APPEND_SYSTEM.md"
}

function test_smoke_016_pi_settings_include_all_managed_packages() {
  _bats_test_init 16 'pi settings include all managed packages'
  local settings="$HOME/.pi/agent/settings.json"
  assert_file_exists "$settings"

  # Derive the expected set from the modifier itself (the chezmoi source of
  # truth) instead of a hardcoded copy, so this test cannot drift from it.
  local modifier="$SOURCE_ROOT/dot_pi/agent/modify_settings.json"
  [[ -f "$modifier" ]] || skip "repository checkout is not mounted"

  run bash "$modifier" <<< '{}'
  assert_success

  local expected
  expected="$(jq -c '.packages' <<< "$output")"

  # An empty selection would let the subset assertion below pass vacuously.
  run jq -e 'length > 0' <<< "$expected"
  assert_success

  # Subset by design, not exact equality: tests/bashunit/scripts_test.sh:7039-7090
  # already owns exact transform equality for the modifier's output. This test
  # owns delivery completeness -- that apply reached the live settings.json --
  # and a real machine can legitimately carry an extra package installed
  # directly through Pi between applies (see
  # docs/issues/2026-08-19-001-pi-package-inventory-drift.md).
  run jq -e --argjson expected "$expected" '
    ($expected - .packages) == []
  ' "$settings"
  assert_success
}

function test_smoke_017_coding_agents_use_terminal_color_palettes() {
  _bats_test_init 17 'coding agents use terminal color palettes'
  run jq -e '.theme == "custom:light-ansi-daltonized"' "$HOME/.claude/settings.json"
  assert_success
  assert_file_exists "$HOME/.claude/themes/light-ansi-daltonized.json"

  run jq -e '.theme == "terminal"' "$HOME/.pi/agent/settings.json"
  assert_success
  assert_file_exists "$HOME/.pi/agent/themes/terminal.json"

  run jq -e '.theme == "system"' "$HOME/.config/opencode/tui.json"
  assert_success
  assert_file_not_exists "$HOME/.config/opencode/themes/flexoki-light-forced.json"
}

function test_smoke_018_opencode_reads_the_shared_writing_style_file_via() {
  _bats_test_init 18 'opencode reads the shared writing-style file via instructions'
  assert_file_exists "$HOME/.config/agents/writing-style.md"
  run jq -e '.instructions | index("~/.config/agents/writing-style.md") != null' "$HOME/.config/opencode/opencode.json"
  assert_success
}

function test_smoke_019_clients_resolve_model_invocable_skills_from_agents() {
  _bats_test_init 19 'clients resolve model-invocable skills from canonical .agents trees'
  local skill

  for skill in \
    ask-in-herdr herdr markdown-new \
    pf-build pf-research pf-spec plan-explainer \
    se-code-review se-doc-review se-plan se-simplify \
    vector-prime work-summary writing-for-agents; do
    run readlink "$HOME/.claude/skills/$skill/SKILL.md"
    assert_success
    assert_output "$HOME/.agents/skills/$skill/SKILL.md"
    assert_file_exists "$HOME/.agents/skills/$skill/SKILL.md"
    if [[ -e "$HOME/.config/opencode/skills/$skill" || -L "$HOME/.config/opencode/skills/$skill" ]]; then
      fail "stale OpenCode skill adapter remains: $HOME/.config/opencode/skills/$skill"
    fi
  done

  local retired path
  for path in \
    "$HOME/.agents/skills/se-cleanup" \
    "$HOME/.claude/skills/se-cleanup" \
    "$HOME/.config/opencode/skills/se-cleanup"; do
    [[ ! -e "$path" && ! -L "$path" ]] || fail "retired skill remains deployed: $path"
  done
  for retired in se-flow se-review-and-work se-work; do
    for path in \
      "$HOME/.claude/skills/$retired" \
      "$HOME/.config/opencode/skills/$retired"; do
      [[ ! -e "$path" && ! -L "$path" ]] || fail "retired skill remains deployed: $path"
    done
  done
  for path in "$HOME/.claude/.smithers" "$HOME/.local/bin/se"; do
    [[ ! -e "$path" && ! -L "$path" ]] || fail "retired Smithers path remains deployed: $path"
  done
}

function test_smoke_020_explicit_only_workflows_keep_manual_invocation_b() {
  _bats_test_init 20 'explicit-only workflows keep manual invocation boundaries'
  local workflow claude_skill pi_skill opencode_command opencode_skill

  for workflow in eli5 open-questions; do
    claude_skill="$HOME/.claude/skills/$workflow/SKILL.md"
    pi_skill="$HOME/.pi/agent/skills/$workflow"
    opencode_command="$HOME/.config/opencode/commands/$workflow.md"
    opencode_skill="$HOME/.config/opencode/skills/$workflow"

    assert_file_exists "$claude_skill"
    run awk '
      NR == 1 { if ($0 != "---") exit 1; frontmatter = 1; next }
      frontmatter && $0 == "---" { frontmatter = 0; closed = 1; next }
      frontmatter && /^disable-model-invocation:/ { keys++ }
      frontmatter && $0 == "disable-model-invocation: true" { valid++ }
      END { exit !(closed && keys == 1 && valid == 1) }
    ' "$claude_skill"
    assert_success

    run readlink "$pi_skill"
    assert_success
    assert_output "$HOME/.claude/skills/$workflow"
    assert_file_exists "$pi_skill/SKILL.md"

    assert_file_exists "$opencode_command"
    run awk '
      NR == 1 { if ($0 != "---") exit 1; frontmatter = 1; next }
      frontmatter && $0 == "---" { frontmatter = 0; closed = 1; next }
      frontmatter && /^description: ".+"$/ { description = 1 }
      closed && NF { body = 1 }
      END { exit !(closed && description && body) }
    ' "$opencode_command"
    assert_success

    if [[ -e "$opencode_skill" || -L "$opencode_skill" ]]; then
      fail "explicit-only workflow exposed as native OpenCode skill: $opencode_skill"
    fi
  done

  run zsh -dfc 'unset OPENCODE_DISABLE_EXTERNAL_SKILLS OPENCODE_DISABLE_CLAUDE_CODE_SKILLS; source "$1"; zsh -dfc "$2"' _ "$HOME/.zshenv" '[[ -z "${OPENCODE_DISABLE_EXTERNAL_SKILLS:-}" && "$OPENCODE_DISABLE_CLAUDE_CODE_SKILLS" == 1 ]]'
  assert_success
}

# One manifest replaces the per-skill existence tests; content-level guards
# (YAML descriptions, shared-pointer resolution) keep their own tests below.
function test_smoke_021_agent_skills_are_deployed_with_their_scripts_and() {
  _bats_test_init 21 'agent skills are deployed with their scripts and references'
  local files=(
    skills/ask-in-herdr/SKILL.md
    skills/ask-in-herdr/scripts/ask.sh
    skills/herdr/SKILL.md
    skills/writing-for-agents/SKILL.md
    skills/writing-for-agents/SKILL-MECHANICS.md
    skills/work-summary/SKILL.md
    skills/work-summary/references/update-format.md
    skills/work-summary/references/report-format.md
    skills/vector-prime/SKILL.md
    skills/vector-prime/scripts/vp.sh
    skills/pf-research/SKILL.md
    skills/pf-spec/SKILL.md
    skills/pf-build/SKILL.md
    skills/pf-build/references/direct-build.md
    skills/pf-build/references/implementer-prompt.md
    skills/pf-build/references/demo.md
    skills/plan-explainer/SKILL.md
    skills/plan-explainer/references/sections.md
    skills/plan-explainer/references/page-craft.md
    skills/plan-explainer/references/edge-cases.md
    skills/plan-explainer/scripts/capture-sections.sh
  )
  local f missing=""
  for f in "${files[@]}"; do
    [ -f "$HOME/.agents/$f" ] || missing="$missing $f"
  done
  [ -z "$missing" ] || fail "missing under ~/.agents:$missing"

  assert_file_exists "$HOME/.claude/skills/eli5/SKILL.md"
  assert_file_exists "$HOME/.claude/skills/open-questions/SKILL.md"
  assert_file_executable "$HOME/.agents/skills/ask-in-herdr/scripts/ask.sh"
  assert_file_executable "$HOME/.agents/skills/markdown-new/scripts/deepwiki-read.sh"
  assert_file_executable "$HOME/.agents/skills/markdown-new/scripts/jina-read.sh"
  assert_file_executable "$HOME/.agents/skills/markdown-new/scripts/jina-search.sh"
  assert_file_executable "$HOME/.agents/skills/markdown-new/scripts/tavily-search.sh"

  # The retired per-agent scripts directory must stay deleted.
  assert_dir_not_exists "$HOME/.agents/skills/ask-in-herdr/scripts/agents"
}

# A hand-copied list of shared filenames here can only restate the pointers the
# deployed surface already writes; it drifts silently when a shared file is
# renamed and its entry here is forgotten. Cross-check both independent sides
# instead: every ~/.claude/shared/*.md pointer written in the deployed surface
# (CLAUDE.md, skills, agents, hooks, output-styles, rules, and the herdr
# child-launch lib) must resolve to a real file, and conversely every deployed
# shared file except the directory's own README index must be reachable from
# at least one such pointer, or it is dead weight nothing loads. The scanned
# paths are chezmoi-managed content dirs only (see home/private_dot_claude/*)
# — runtime state like sessions or telemetry is deliberately excluded, since a
# pointer written only there was never part of the wiring this repo deploys.
function test_smoke_022_shared_references_form_a_closed_reference_set() {
  _bats_test_init 22 'shared references form a closed reference set with the deployed agent surface'
  local shared_dir="$HOME/.claude/shared"
  assert_dir_exists "$shared_dir"

  local pointers
  pointers="$(grep -rho '~/\.claude/shared/[A-Za-z0-9._-]*\.md' \
    "$HOME/.claude/CLAUDE.md" "$HOME/.agents" "$HOME/.local/lib" \
    "$HOME/.claude/agents" "$HOME/.claude/hooks" "$HOME/.claude/output-styles" \
    "$HOME/.claude/rules" "$HOME/.claude/skills" 2>/dev/null | sort -u)"
  [ -n "$pointers" ] || fail "no ~/.claude/shared pointer found in the deployed agent surface"

  local pointer missing=""
  while IFS= read -r pointer; do
    [ -f "$HOME/${pointer#\~/}" ] || missing="$missing $pointer"
  done <<< "$pointers"
  [ -z "$missing" ] || fail "dangling ~/.claude/shared pointers:$missing"

  local f name orphans=""
  for f in "$shared_dir"/*.md; do
    name="$(basename "$f")"
    [ "$name" = "README.md" ] && continue
    grep -qF "shared/$name" <<< "$pointers" || orphans="$orphans $name"
  done
  [ -z "$orphans" ] || fail "orphaned ~/.claude/shared files referenced by nothing:$orphans"
}

# ===========================================
# macOS-only configs (skipped on Linux)
# ===========================================

function test_smoke_023_executor_cli_resolves_on_path_through_local_bin() {
  _bats_test_init 23 'executor CLI resolves on PATH through ~/.local/bin (macOS only)'
  is_macos || skip "Not on macOS"
  # The symlink deploys on every macOS apply, but MMS_CI_MINIMAL renders
  # Brewfile.macos to zero bytes, so CI never installs the cask that provides
  # the target. Guard on the app bundle rather than on the link, which is
  # present-but-dangling there.
  [ -e /Applications/Executor.app ] || skip "Executor.app not installed (CI-minimal render omits the cask)"
  # The target lives inside the app bundle, so running the binary is what proves
  # the link resolves -- an existence check alone would pass against a dangling
  # link after the app is moved or removed.
  local link="$HOME/.local/bin/executor"
  assert_file_exists "$link"
  run "$link" --version
  assert_success
  assert_output --partial "executor v"
}

function test_smoke_024_kitty_includes_its_herdr_bindings_and_keeps_the() {
  _bats_test_init 24 'kitty includes its herdr bindings and keeps the Alabaster theme (macOS only)'
  is_macos || skip "Not on macOS"
  local config="$HOME/.config/kitty/kitty.conf"
  assert_file_contains "$config" "^include herdr.conf$"
  assert_file_contains "$config" "^include Alabaster.conf$"
}

function test_smoke_025_kitty_font_family_is_one_kitty_accepts_as_monosp() {
  _bats_test_init 25 'kitty font family is one kitty accepts as monospaced (macOS only)'
  is_macos || skip "Not on macOS"
  # kitty rejects the non-Mono "IosevkaTerm Nerd Font" that ghostty uses and
  # falls back to Menlo without failing, so pin the Mono family explicitly.
  assert_file_contains "$HOME/.config/kitty/kitty.conf" \
    "^font_family  *IosevkaTerm Nerd Font Mono$"
}

function test_smoke_026_kitty_auto_launches_herdr_without_exec_ing_it_ma() {
  _bats_test_init 26 'kitty auto-launches herdr without exec'\''ing it (macOS only)'
  is_macos || skip "Not on macOS"
  local config="$HOME/.config/kitty/herdr.conf"
  # Detaching from herdr must return to a plain login shell, so herdr is run
  # as a normal command and the shell is exec'd afterwards.
  assert_file_contains "$config" "^shell /bin/zsh -lc .*herdr"
  assert_file_contains "$config" "^shell /bin/zsh -lc .*exec /bin/zsh -l"
}

function test_smoke_027_kitty_sends_the_herdr_prefix_for_macos_style_sho() {
  _bats_test_init 27 'kitty sends the herdr prefix for macOS-style shortcuts (macOS only)'
  is_macos || skip "Not on macOS"
  local config="$HOME/.config/kitty/herdr.conf"
  # \x02 is herdr's ctrl+b prefix; these must match the ghostty keybindings.
  assert_file_contains "$config" 'cmd+t send_text all .x02c$'
  assert_file_contains "$config" 'cmd+d send_text all .x02v$'
  assert_file_contains "$config" 'cmd+w send_text all .x02x$'
  assert_file_contains "$config" 'ctrl+shift+1 send_text all .x1b\[49;6u$'
  assert_file_contains "$config" '^map shift+alt+left send_text all .x1b\[1;4D$'
}

function test_smoke_028_kitty_herdr_bindings_survive_a_non_latin_keyboar() {
  _bats_test_init 28 'kitty herdr bindings survive a non-Latin keyboard layout (macOS only)'
  is_macos || skip "Not on macOS"
  local config="$HOME/.config/kitty/herdr.conf"
  # Without --allow-fallback=shifted,ascii kitty drops a letter-key override
  # from the physical-key lookup on a non-Latin layout, and its own built-in
  # action fires instead: cmd+t would open a kitty tab, not a herdr tab.
  # This is the kitty counterpart of ghostty's cmd+KeyT physical-key syntax.
  assert_file_contains "$config" \
    "^map --allow-fallback=shifted,ascii cmd+t send_text all "
  assert_file_contains "$config" \
    "^map --allow-fallback=shifted,ascii ctrl+shift+h send_text all "
  # Every letter, digit and bracket binding needs the flag. Arrow, Tab and
  # Enter keys do not, because the keyboard layout does not change them.
  local risky
  risky=$(grep '^map [^-]' "$config" \
    | grep ' send_text ' \
    | grep -vE '[+ ](enter|tab|left|right|up|down) send_text ' || true)
  [ -z "$risky" ] || fail "bindings missing --allow-fallback: $risky"
}

# The real consumer is the palette's own hint parser: load_key_binding_groups()
# reads `# palette: Group | Key | Description` comments out of the terminal
# config and builds the panel from them, silently dropping any line that does
# not split into three non-empty fields. Grepping the literal comment cannot
# see that drop, so run the deployed parser over the deployed kitty config
# (pinned via HERDR_COMMAND_PALETTE_KEYBINDINGS_CONFIG, which is the parser's
# own override, so the result does not depend on which terminal hosts the run)
# and assert the entries it actually produces.
function test_smoke_029_kitty_carries_command_palette_hints_for_the_herd() {
  _bats_test_init 29 'kitty command-palette hints parse into palette key-binding groups (macOS only)'
  is_macos || skip "Not on macOS"
  run env \
    HERDR_COMMAND_PALETTE_KEYBINDINGS_CONFIG="$HOME/.config/kitty/herdr.conf" \
    PYTHONPYCACHEPREFIX="$BATS_TEST_TMPDIR/pycache" \
    python3 - <<'PY'
import importlib.util, os, sys

path = os.path.expanduser("~/.config/herdr/plugins/command-palette/palette.py")
spec = importlib.util.spec_from_file_location("palette", path)
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)

groups = dict(mod.load_key_binding_groups())
assert ("⌘T", "New tab") in groups.get("Tabs & workspaces", []), groups
assert ("⌘D", "Split right") in groups.get("Panes", []), groups
PY
  assert_success
}

function test_smoke_030_lazygit_config_keeps_russian_layout_keybindings() {
  _bats_test_init 30 'lazygit config keeps Russian-layout keybindings and popup exit (macOS only)'
  is_macos || skip "Not on macOS"
  local config="$HOME/Library/Application Support/lazygit/config.yml"
  # One -alt binding stands in for the whole Russian-layout section; losing the
  # section drops them all together, so a single marker catches it.
  assert_file_contains "$config" "^    prevBlock-alt: р$"
  assert_file_contains "$config" "^quitOnTopLevelReturn: true$"
}

function test_smoke_031_herdr_caffeinate_plugin_scripts_are_valid_sh_mac() {
  _bats_test_init 31 'herdr caffeinate plugin scripts are valid sh (macOS only)'
  is_macos || skip "Not on macOS"
  for f in reconcile.sh lib.sh actions.sh; do
    run sh -n "$HOME/.config/herdr/plugins/herdr-caffeinate/$f"
    assert_success
  done
}

# ===========================================
# herdr focus-notify plugin (source tree)
# ===========================================

FOCUS_NOTIFY_DIR="$SOURCE_ROOT/private_dot_config/herdr/plugins/herdr-focus-notify"

# Runs notify.py against a fake notifier that records its argv one line per
# argument, so tests can assert the exact command terminal-notifier would get.
# $1: event JSON. Extra env for the run comes via focus_notify_env array.
run_focus_notify() {
  local event_json="$1"
  local fake_bin="$BATS_TEST_TMPDIR/fake-notifier"
  FOCUS_NOTIFY_ARGV="$BATS_TEST_TMPDIR/notifier.argv"
  cat > "$fake_bin" <<SH
#!/bin/sh
printf '%s\n' "\$@" > "$FOCUS_NOTIFY_ARGV"
SH
  chmod +x "$fake_bin"
  HERDR_PLUGIN_EVENT_JSON="$event_json" \
    HERDR_FOCUS_NOTIFY_NOTIFIER_BIN="$fake_bin" \
    HERDR_BIN_PATH="$BATS_TEST_TMPDIR/dir with space/herdr" \
    run python3 "$FOCUS_NOTIFY_DIR/notify.py"
}

function test_smoke_032_focus_notify_plugin_compiles_and_declares_its_ru() {
  _bats_test_init 32 'focus-notify plugin compiles and declares its runtime entrypoint'
  run env PYTHONPYCACHEPREFIX="$BATS_TEST_TMPDIR/pycache" \
    python3 -m py_compile "$FOCUS_NOTIFY_DIR/notify.py"
  assert_success

  # The manifest wires the status event and the interpreter as argv arrays.
  # Literal consumed outside this repo: herdr's plugin loader parses these two
  # keys to decide which event fires the plugin and how to exec it. Assert the
  # deployed copy, not $SOURCE_ROOT — reading the checkout here would be a
  # source grep wearing a smoke test's name and would stay green when chezmoi
  # never placed the file (same fix as test 009 in commit 50654e2). The plugin
  # is darwin-only per home/.chezmoiignore, so it only deploys on macOS.
  is_macos || return 0
  local manifest="$HOME/.config/herdr/plugins/herdr-focus-notify/herdr-plugin.toml"
  assert_file_exists "$manifest"
  assert_file_contains "$manifest" '^on = "pane.agent_status_changed"$'
  assert_file_contains "$manifest" '^command = \["python3", "notify.py"\]$'
}

function test_smoke_033_focus_notify_builds_a_safely_quoted_click_comman() {
  _bats_test_init 33 'focus-notify builds a safely quoted click command'
  # A hostile pane id proves the quoting: nothing here may reach sh as syntax.
  run_focus_notify '{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p3; $(boom) &","agent_status":"blocked","agent":"codex","display_agent":"Codex"}}'
  assert_success
  assert_file_exists "$FOCUS_NOTIFY_ARGV"

  run python3 - "$FOCUS_NOTIFY_ARGV" "$BATS_TEST_TMPDIR/dir with space/herdr" <<'PY'
import shlex, sys
argv = open(sys.argv[1], encoding="utf-8").read().split("\n")
execute = argv[argv.index("-execute") + 1]
# shlex.split proves the string survives sh word-splitting as exactly the
# intended four tokens -- binary, agent, focus, pane id -- nothing executed.
assert shlex.split(execute) == [sys.argv[2], "agent", "focus", "w1:p3; $(boom) &"], execute
assert argv[argv.index("-group") + 1] == "herdr-w1-p3-boom-", argv
assert argv[argv.index("-title") + 1] == "Codex needs your input", argv
assert "-activate" in argv, argv
PY
  assert_success
}

function test_smoke_034_focus_notify_stays_quiet_for_non_actionable_stat() {
  _bats_test_init 34 'focus-notify stays quiet for non-actionable statuses and missing pane id'
  run_focus_notify '{"data":{"pane_id":"w1:p1","agent_status":"working","agent":"codex"}}'
  assert_success
  assert_file_not_exists "$FOCUS_NOTIFY_ARGV"

  run_focus_notify '{"data":{"agent_status":"blocked","agent":"codex"}}'
  assert_success
  assert_file_not_exists "$FOCUS_NOTIFY_ARGV"
}

function test_smoke_035_focus_notify_uses_one_notification_group_per_pan() {
  _bats_test_init 35 'focus-notify uses one notification group per pane for duplicate replacement'
  run_focus_notify '{"data":{"pane_id":"w1:p3","agent_status":"done","agent":"claude"}}'
  assert_success

  run python3 - "$FOCUS_NOTIFY_ARGV" <<'PY'
import sys
argv = open(sys.argv[1], encoding="utf-8").read().split("\n")
assert argv[argv.index("-group") + 1] == "herdr-w1-p3", argv
assert argv[argv.index("-title") + 1] == "claude finished", argv
PY
  assert_success
}

# ===========================================
# Hard tool dependencies
# ===========================================

# fzf is a hard dependency of the command palette: palette.py shells out to
# `fzf --filter` as its only scorer and refuses to start without it. So this
# test asserts rather than skips, and it asserts the version floor. The floor
# is read from palette.py's own FZF_MIN_VERSION so the two cannot drift.
function test_smoke_036_fzf_is_installed_and_meets_the_command_palette_s() {
  _bats_test_init 36 'fzf is installed and meets the command palette'\''s version floor'
  run command -v fzf
  assert_success

  run fzf --version
  assert_success
  local version="${output%% *}"

  run python3 - "$version" <<'PY'
import importlib.util, os, sys
path = os.path.expanduser("~/.config/herdr/plugins/command-palette/palette.py")
spec = importlib.util.spec_from_file_location("palette", path)
palette = importlib.util.module_from_spec(spec)
sys.modules["palette"] = palette
spec.loader.exec_module(palette)
found = tuple(int(part) for part in sys.argv[1].split(".")[:2])
assert found >= palette.FZF_MIN_VERSION, f"fzf {sys.argv[1]} is below {palette.FZF_MIN_VERSION}"
PY
  assert_success
}

# herdr alias presentation (engine, native integrations, sidebar)
# ===========================================

function test_smoke_1051_herdr_alias_pane_label_and_child_files_are_deployed() {
  _bats_test_init 1051 'herdr alias, pane-label, and child files are deployed'
  assert_file_exists "$HOME/.local/lib/herdr-aliases.sh"
  assert_file_exists "$HOME/.local/bin/herdr-pane-labels"
  assert_file_executable "$HOME/.local/bin/herdr-pane-labels"
  assert_file_exists "$HOME/.local/bin/herdr-child"
  assert_file_executable "$HOME/.local/bin/herdr-child"
}

function test_smoke_1052_herdr_child_and_consult_contracts_use_allocator_owned_p() {
  _bats_test_init 1052 'herdr child and consult contracts use allocator-owned pair addressing'
  local child="$HOME/.local/bin/herdr-child"
  local ask="$HOME/.agents/skills/ask-in-herdr/scripts/ask.sh"
  local contract="$HOME/.claude/shared/child-agent-contract.md"
  local consult_skill="$HOME/.agents/skills/ask-in-herdr/SKILL.md"
  local herdr_skill="$HOME/.agents/skills/herdr/SKILL.md"

  run grep -E -- 'start .*--name|case .*--name' "$child"
  assert_failure
  run grep -E -- 'consult-\$AGENT|herdr-child.*--name' "$ask"
  assert_failure
  assert_file_contains "$ask" 'herdr-child reap --to %s --pane %s'
  assert_file_contains "$contract" 'herdr-child reap --to <alias> --pane <pane-id>'
  assert_file_contains "$consult_skill" 'herdr-child reap --to <alias> --pane <pane-id>'
  assert_file_contains "$herdr_skill" 'callback alias may differ from the launch alias'
  assert_file_contains "$herdr_skill" 'CALLBACK_ALIAS="\$CHILD_NAME"'
  assert_file_contains "$herdr_skill" 'herdr-child verify --to "\$CALLBACK_CANDIDATE" --pane "\$CHILD_PANE"'
  assert_file_contains "$herdr_skill" 'CALLBACK_ALIAS="\$CALLBACK_CANDIDATE"'
  assert_file_contains "$herdr_skill" 'herdr-child reply --to "\$CALLBACK_ALIAS" --pane "\$CHILD_PANE"'
  assert_file_contains "$herdr_skill" 'herdr-child reap --to "\$CALLBACK_ALIAS" --pane "\$CHILD_PANE"'
}

function test_smoke_1053_semantic_adapters_are_absent() {
  _bats_test_init 1053 'semantic adapters are absent'
  assert_file_not_exists "$HOME/.local/bin/herdr-task-sync"
  assert_file_not_exists "$HOME/.claude/hooks/herdr-task-sync-hook.sh"
  assert_file_not_exists "$HOME/.config/opencode/plugins/herdr-task-sync.ts"
  assert_file_not_exists "$HOME/.pi/agent/extensions/herdr-task-sync.ts"
}

function test_smoke_1054_claude_settings_omit_task_sync_hooks_and_retain_native_() {
  _bats_test_init 1054 'claude settings omit task-sync hooks and retain native agent state'
  local settings="$HOME/.claude/settings.json"
  assert_file_exists "$settings"
  run python3 - "$settings" <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
commands = [h["command"] for entries in hooks.values() for entry in entries for h in entry["hooks"]]
assert not any("herdr-task-sync-hook.sh" in command for command in commands), commands
session = [h["command"] for entry in hooks["SessionStart"] for h in entry["hooks"]]
assert any("herdr-agent-state.sh" in c for c in session), session
PY
  assert_success
}

function test_smoke_1063_worktree_identity_deploys_and_statusline_records_() {
  _bats_test_init 1063 'worktree identity deploys and Claude statusline records its cwd'
  local engine="$HOME/.local/bin/herdr-worktree-identity"
  local library="$HOME/.local/lib/herdr-worktree-state.sh"
  local hook="$HOME/.claude/hooks/statusline.sh"
  local record_home="$BATS_TEST_TMPDIR/statusline-record-home"
  local session='statusline-cwd-session'
  local input

  assert_file_executable "$engine"
  assert_file_exists "$library"
  assert_file_executable "$hook"
  input="$(jq -nc --arg dir "$BATS_TEST_TMPDIR" --arg session "$session" \
    '{workspace: {current_dir: $dir}, session_id: $session}')"

  run env HOME="$record_home" HERDR_ENV=1 bash "$hook" <<< "$input"
  assert_success
  assert_file_contains "$record_home/.cache/herdr-worktree-identity/agent-cwd/$session" "^$BATS_TEST_TMPDIR$"
  assert_file_not_exists "$record_home/.cache/herdr-task-sync/agent-cwd/$session"
}

function test_smoke_1055_pi_local_private_instructions_focused_tests_pass() {
  _bats_test_init 1055 'Pi local private instructions focused tests pass'
  run env PI_AGENTS_LOCAL_EXTENSION_PATH="$HOME/.pi/agent/extensions/agents-local.ts" \
    bun test "$BATS_TEST_DIRNAME/pi-agents-local-extension.test.ts"
  assert_success
}

function test_smoke_1056_pi_brew_auto_updater_is_deployed() {
  _bats_test_init 1056 'Pi brew auto updater is deployed'
  local ext="$HOME/.pi/agent/extensions/brew-auto-update/index.ts"
  assert_file_exists "$ext"
}

function test_smoke_1057_pi_brew_auto_updater_focused_tests_pass() {
  _bats_test_init 1057 'Pi brew auto updater focused tests pass'
  run bun test "$BATS_TEST_DIRNAME/pi-brew-auto-update.test.ts"
  assert_success
}

assert_herdr_sidebar_deployment_contract() {
  local config="$1"
  local engine="$2"
  local plugin="$3"
  local width
  local writer_files=(
    "$engine"
    "$plugin/herdr-plugin.toml"
    "$plugin/ensure.sh"
    "$plugin/sweep.sh"
  )
  local writer_roots=(
    "$(dirname "$engine")"
    "$(dirname "$config")"
  )

  assert_file_contains "$config" '^\[ui.sidebar.agents\]$'
  # Pane and tab identity stay stable when Git state changes. Location metadata
  # remains available to integrations, but the sidebar renders identity only.
  assert_file_contains "$config" '^rows = \[\["state_icon", "workspace"\], \["pane"\]\]$'
  run grep -E '\$git_ref|\$location_label|\$location_status' "$config"
  assert_failure
  # Sole owner of sidebar_min_width: the awk scope proves the key both carries
  # the value herdr reads and sits inside [ui], which a flat file grep cannot.
  # No width-derived assertions here: nothing consumes a "width - 4" budget.
  width="$(awk '
    $0 == "[ui]" { in_ui = 1; next }
    /^\[/ { in_ui = 0 }
    in_ui && /^sidebar_min_width = [0-9]+$/ { print $3 }
  ' "$config")"
  [ "$width" -eq 32 ]

  run bash -c '
    pattern="$1"; shift
    find "$@" -type f -exec grep -hE "$pattern" {} +
  ' _ '^[[:space:]]*herdr pane rename ' "${writer_roots[@]}"
  assert_success
  [ "$(printf '%s\n' "$output" | wc -l | tr -d '[:space:]')" -eq 1 ]
  run bash -c '
    pattern="$1"; shift
    find "$@" -type f -exec grep -hE "$pattern" {} +
  ' _ '^[[:space:]]*herdr tab rename ' "${writer_roots[@]}"
  assert_success
  [ "$(printf '%s\n' "$output" | wc -l | tr -d '[:space:]')" -eq 1 ]

  run grep -Ei 'reclaim|manual[-_ ]ownership|ownership[-_ ]notification' \
    "$engine" "$plugin/herdr-plugin.toml" "$plugin/ensure.sh" "$plugin/sweep.sh"
  assert_failure
  run grep -hEi 'state_icon|(^|[^[:alnum:]_])(icon|icons|glyph)([^[:alnum:]_]|$)|nerd[ -]?font' \
    "$config" "${writer_files[@]}"
  assert_success
  assert_file_contains "$config" 'rows = \[\["state_icon", "workspace"\], \["pane"\]\]'
  assert_file_contains "$config" '"state_icon"'
  # The engine builds the five codicon glyphs of the $git_ref grammar from
  # bash 3.2-safe octal printf sequences. Raw PUA glyphs are easily lost when
  # files pass through editors or agents, so none may be committed verbatim.
  assert_file_contains "$engine" '\\356\\261\\257' # nf-cod-git_branch U+EC6F
  assert_file_contains "$engine" '\\356\\261\\276' # nf-cod-worktree U+EC7E
  assert_file_contains "$engine" '\\356\\253\\274' # nf-cod-git_commit U+EAFC
  assert_file_contains "$engine" '\\356\\252\\203' # nf-cod-folder U+EA83
  assert_file_contains "$engine" '\\356\\252\\202' # nf-cod-history U+EA82
  run env LC_ALL=C grep -n "$(printf '\356')" "$engine" "$config"
  assert_failure
  assert_file_contains "$engine" 'LABEL_SEPARATOR=.* · '
  assert_file_contains "$engine" '…'
}

function test_smoke_1058_herdr_managed_source_preserves_the_u6_sidebar_and_owner() {
  _bats_test_init 1058 'herdr managed source preserves the U6 sidebar and ownership boundaries'
  assert_herdr_sidebar_deployment_contract \
    "$SOURCE_ROOT/private_dot_config/herdr/config.toml" \
    "$SOURCE_ROOT/dot_local/bin/executable_herdr-pane-labels" \
    "$SOURCE_ROOT/private_dot_config/herdr/plugins/herdr-pane-labels"
}

function test_smoke_1059_herdr_deployed_files_preserve_the_u6_sidebar_and_owners() {
  _bats_test_init 1059 'herdr deployed files preserve the U6 sidebar and ownership boundaries'
  assert_herdr_sidebar_deployment_contract \
    "$HOME/.config/herdr/config.toml" \
    "$HOME/.local/bin/herdr-pane-labels" \
    "$HOME/.config/herdr/plugins/herdr-pane-labels"
}

function test_smoke_1060_herdr_pane_label_plugin_deploys_the_approved_herdr_0_8_() {
  _bats_test_init 1060 'herdr pane-label plugin deploys the approved Herdr 0.8 lifecycle inputs'
  local plugin="$HOME/.config/herdr/plugins/herdr-pane-labels"
  local manifest="$plugin/herdr-plugin.toml"
  assert_file_exists "$manifest"
  assert_file_exists "$plugin/ensure.sh"
  assert_file_exists "$plugin/sweep.sh"
  run sh -n "$plugin/ensure.sh"
  assert_success
  run sh -n "$plugin/sweep.sh"
  assert_success

  run awk '
    /^on = "/ {
      event = $0
      sub(/^on = "/, "", event)
      sub(/"$/, "", event)
      next
    }
    /^command = / && event != "" {
      command = $0
      sub(/^command = /, "", command)
      print event "|" command
      event = ""
    }
  ' "$manifest"
  assert_success
  assert_output $'pane.created|["sh", "ensure.sh", "--event"]\npane.moved|["sh", "ensure.sh", "--event"]\npane.exited|["sh", "ensure.sh", "--event"]\npane.closed|["sh", "ensure.sh", "--event"]\npane.agent_detected|["sh", "ensure.sh", "--event"]\npane.agent_status_changed|["sh", "ensure.sh", "--event"]\ntab.created|["sh", "ensure.sh", "--event"]\ntab.closed|["sh", "ensure.sh", "--event"]\ntab.moved|["sh", "ensure.sh", "--event"]\ntab.renamed|["sh", "ensure.sh", "--event"]\nworktree.created|["sh", "ensure.sh", "--event"]\nworktree.opened|["sh", "ensure.sh", "--event"]'
  assert_file_contains "$manifest" '^min_herdr_version = "0\.8\.2"$'
  assert_file_contains "$manifest" '^id = "sweep"$'
  assert_file_contains "$manifest" '^title = "Pane labels: refresh now"$'
  assert_file_contains "$manifest" '^command = \["sh", "sweep\.sh"\]$'
  run grep -E '^on = ".*\*|^on = "(pane\.updated|workspace\.focused|tab\.focused|pane\.focused)"|reclaim' "$manifest"
  assert_failure
}

function test_smoke_1061_herdr_pane_label_plugin_keeps_startup_sweep_and_relink_() {
  _bats_test_init 1061 'herdr pane-label plugin keeps startup sweep and relink deployment wiring'
  local plugin="$HOME/.config/herdr/plugins/herdr-pane-labels"
  local manifest="$plugin/herdr-plugin.toml"
  local relink="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_6-link-herdr-pane-labels.sh.tmpl"
  assert_file_contains "$manifest" '^\[\[startup\]\]$'
  assert_file_contains "$manifest" '^command = \["sh", "ensure.sh"\]$'
  assert_file_contains "$plugin/ensure.sh" 'herdr-pane-labels'
  assert_file_contains "$plugin/ensure.sh" 'labels.*--ensure-sweep-daemon'
  assert_file_contains "$plugin/ensure.sh" "^  ''|--ensure-sweep-daemon)\$"
  assert_file_contains "$plugin/sweep.sh" 'labels.*--sweep'
  assert_file_contains "$relink" 'include "private_dot_config/herdr/plugins/herdr-pane-labels/herdr-plugin.toml"'
  assert_file_contains "$relink" 'include "private_dot_config/herdr/plugins/herdr-pane-labels/ensure.sh"'
  assert_file_contains "$relink" 'include "private_dot_config/herdr/plugins/herdr-pane-labels/sweep.sh"'
  assert_file_contains "$relink" 'herdr plugin link'
  assert_file_contains "$relink" 'herdr plugin enable "\$HPL_CUTOVER_PLUGIN_ID"'
}

function test_smoke_1062_herdr_pane_label_cutover_templates_share_one_safety_bod() {
  _bats_test_init 1062 'herdr pane-label cutover templates share one safety body and complete hash inputs'
  local before="$SOURCE_ROOT/.chezmoiscripts/run_onchange_before_6-quiesce-herdr-pane-labels.sh.tmpl"
  local after="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_6-link-herdr-pane-labels.sh.tmpl"
  local shared="$SOURCE_ROOT/.chezmoitemplates/herdr-pane-labels-cutover-lib.sh"
  local file input
  local inputs=(
    'dot_local/bin/executable_herdr-pane-labels'
    'dot_local/lib/herdr-aliases.sh'
    'private_dot_config/herdr/plugins/herdr-pane-labels/herdr-plugin.toml'
    'private_dot_config/herdr/plugins/herdr-pane-labels/ensure.sh'
    'private_dot_config/herdr/plugins/herdr-pane-labels/sweep.sh'
    '.chezmoitemplates/herdr-pane-labels-cutover-lib.sh'
  )

  assert_file_exists "$before"
  assert_file_exists "$after"
  assert_file_exists "$shared"
  for file in "$before" "$after"; do
    assert_file_contains "$file" 'include "\.chezmoitemplates/herdr-pane-labels-cutover-lib\.sh"'
    for input in "${inputs[@]}"; do
      assert_file_contains "$file" "include \"$input\" \\| sha256sum"
    done
  done
  assert_file_contains "$before" 'include "dot_local/lib/herdr-aliases\.sh"'
  assert_file_contains "$before" '^source "\$alias_library"'
  assert_file_contains "$shared" 'herdr pane report-metadata "\$pane"'
  assert_file_contains "$shared" '^        --source task-sync --clear-token task'
  run grep -n -- '--source task-sync.*--seq\|--clear-token task.*--seq' "$shared"
  assert_failure
  assert_file_contains "$after" 'hpl_cutover_drain_fixed_point'
  assert_file_contains "$after" 'hpl_cutover_ensure_all'
  assert_file_contains "$shared" '^hpl_cutover_rollback()'
  assert_file_contains "$shared" '^hpl_cutover_verify_daemon()'
}

# ===========================================

# ===========================================
# zsh cached_init consumers (docs/issues/2026-08-21-001)
#
# ~/.zshrc caches the output of these tools via cached_init and sources the
# cache in every later shell. An absolute `export PATH=...` line in any of
# them would freeze the generating shell PATH into every shell that sources
# the cache -- the exact bug mise activate had. As of 2026-08-21 none of them
# emits one; these guards keep it that way across tool upgrades.
# ===========================================

function test_smoke_072_starship_init_output_embeds_no_absolute_path_exp() {
  _bats_test_init 72 'starship init output embeds no absolute PATH export'
  command_exists starship || skip "starship not installed"
  run starship init zsh
  assert_success
  refute_line --regexp '^export PATH='
}

function test_smoke_073_zoxide_init_output_embeds_no_absolute_path_expor() {
  _bats_test_init 73 'zoxide init output embeds no absolute PATH export'
  command_exists zoxide || skip "zoxide not installed"
  run zoxide init zsh --cmd cd
  assert_success
  refute_line --regexp '^export PATH='
}

function test_smoke_074_rgrc_aliases_output_embeds_no_absolute_path_expo() {
  _bats_test_init 74 'rgrc aliases output embeds no absolute PATH export'
  command_exists rgrc || skip "rgrc not installed"
  run rgrc --aliases
  assert_success
  refute_line --regexp '^export PATH='
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}
