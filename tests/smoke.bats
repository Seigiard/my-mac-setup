#!/usr/bin/env bats

load 'helpers/common'

# ===========================================
# Core tools (must exist on both platforms)
# ===========================================

@test "zsh is installed" {
  run command -v zsh
  assert_success
}

@test "git is installed" {
  run command -v git
  assert_success
}

@test "curl is installed" {
  run command -v curl
  assert_success
}

# ===========================================
# Chezmoi-managed files exist
# ===========================================

@test ".zshrc exists" {
  assert_file_exists "$HOME/.zshrc"
}

@test ".aliases exists" {
  assert_file_exists "$HOME/.aliases"
}

@test ".gitconfig exists" {
  assert_file_exists "$HOME/.gitconfig"
}

@test ".gitignore exists" {
  assert_file_exists "$HOME/.gitignore"
}

@test ".gitignore ignores the agent trash directory" {
  run grep -qx '\.scratchpad/' "$HOME/.gitignore"
  [ "$status" -eq 0 ]
}

@test ".editorconfig exists" {
  assert_file_exists "$HOME/.editorconfig"
}

@test "starship.toml exists" {
  assert_file_exists "$HOME/.config/starship.toml"
}

@test "herdr command palette plugin exists" {
  assert_file_exists "$HOME/.config/herdr/config.toml"
  assert_file_exists "$HOME/.config/herdr/plugins/command-palette/herdr-plugin.toml"
  assert_file_exists "$HOME/.config/herdr/plugins/command-palette/open.py"
  assert_file_exists "$HOME/.config/herdr/plugins/command-palette/palette.py"
  assert_file_exists "$HOME/.config/herdr/plugins/command-palette/smart_close.py"
  assert_file_exists "$HOME/.config/herdr/command-palette/commands.toml"
}

@test "herdr command palette keybinding is configured" {
  assert_file_contains "$HOME/.config/herdr/config.toml" "seigi.command-palette.open"
  assert_file_contains "$HOME/.config/herdr/command-palette/commands.toml" "Edit command palette config"
}

@test "herdr lazygit popup entrypoint is configured" {
  assert_file_contains "$HOME/.config/herdr/plugins/command-palette/herdr-plugin.toml" 'id = "lazygit"'
  assert_file_contains "$HOME/.config/herdr/command-palette/commands.toml" "Lazygit in popup"
}

@test "herdr command palette sources are valid" {
  run python3 -m py_compile \
    "$HOME/.config/herdr/plugins/command-palette/open.py" \
    "$HOME/.config/herdr/plugins/command-palette/palette.py" \
    "$HOME/.config/herdr/plugins/command-palette/smart_close.py"
  assert_success

  run python3 -c 'import importlib.util, os, sys; path=os.path.expanduser("~/.config/herdr/plugins/command-palette/palette.py"); spec=importlib.util.spec_from_file_location("palette", path); mod=importlib.util.module_from_spec(spec); sys.modules[spec.name]=mod; spec.loader.exec_module(mod); assert len(mod.load_command_data_file(__import__("pathlib").Path(os.path.expanduser("~/.config/herdr/command-palette/commands.toml")))) > 0'
  assert_success

  run python3 "$HOME/.config/herdr/plugins/command-palette/palette.py" --validate \
    "$HOME/.config/herdr/command-palette/commands.toml"
  assert_success
}

@test "herdr command palette opener detects active palette pane" {
  run python3 - <<'PY'
import importlib.util, os, sys
path=os.path.expanduser("~/.config/herdr/plugins/command-palette/open.py")
spec=importlib.util.spec_from_file_location("palette_open", path)
mod=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=mod
spec.loader.exec_module(mod)
assert mod.process_is_palette({"argv": ["python3", "palette.py"], "cwd": "/tmp/command-palette"})
assert mod.process_is_palette({"cmdline": "python3 /tmp/command-palette/palette.py"})
assert not mod.process_is_palette({"argv": ["vim", "palette.py"], "cwd": "/tmp/other-plugin"})
assert not mod.process_is_palette({"argv": ["python3", "open.py"], "cwd": "/tmp/command-palette"})

class Result:
    def __init__(self, stdout=""):
        self.returncode = 0
        self.stdout = stdout
        self.stderr = ""

calls = []
def fake_run(command, **kwargs):
    calls.append(command)
    if command[:3] == ["herdr", "pane", "current"]:
        return Result('{"result":{"pane":{"pane_id":"pane-1"}}}')
    if command[:3] == ["herdr", "pane", "process-info"]:
        return Result('{"result":{"process_info":{"foreground_processes":[{"argv":["python3","palette.py"],"cwd":"/tmp/command-palette"}]}}}')
    if command[:4] == ["herdr", "plugin", "pane", "focus"]:
        return Result()
    raise AssertionError(command)

mod.subprocess.run = fake_run
os.environ.pop("HERDR_PLUGIN_CONTEXT_JSON", None)
os.environ.pop("HERDR_ACTIVE_PANE_ID", None)
os.environ.pop("HERDR_PANE_ID", None)
assert mod.main() == 0
assert not any(command[:4] == ["herdr", "plugin", "pane", "open"] for command in calls)
PY
  assert_success
}

@test "herdr command palette can load commands" {
  run python3 -c 'import importlib.util, os, sys; path=os.path.expanduser("~/.config/herdr/plugins/command-palette/palette.py"); spec=importlib.util.spec_from_file_location("palette", path); mod=importlib.util.module_from_spec(spec); sys.modules[spec.name]=mod; spec.loader.exec_module(mod); cfg, cmds = mod.load_commands(); assert cfg.name == "commands.toml"; assert len(cmds) > 0'
  assert_success
  assert_file_exists "$HOME/.config/herdr/command-palette/commands.toml"
}

@test "herdr command palette loads TOML and project-local commands" {
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

@test "herdr command palette rejects invalid TOML commands" {
  tmpdir="$(mktemp -d)"
  cat > "$tmpdir/bad.toml" <<'TOML'
name = "Broken"
type = "not_a_type"
command = "echo broken"
TOML

  run python3 "$HOME/.config/herdr/plugins/command-palette/palette.py" --validate "$tmpdir/bad.toml"
  assert_failure
  assert_output --partial "unsupported type"
  rm -rf "$tmpdir"
}

# ===========================================
# Yazi configuration
# ===========================================

@test "yazi config exists" {
  assert_dir_exists "$HOME/.config/yazi"
}

# ===========================================
# Claude Code configuration
# ===========================================

@test ".claude directory exists" {
  assert_dir_exists "$HOME/.claude"
}

@test ".claude/CLAUDE.md exists" {
  assert_file_exists "$HOME/.claude/CLAUDE.md"
}

@test "writing-style output style is deployed and enabled in settings" {
  assert_file_exists "$HOME/.claude/output-styles/writing-style.md"
  run grep -q 'keep-coding-instructions: true' "$HOME/.claude/output-styles/writing-style.md"
  assert_success
  run grep -q 'Answer first: the conclusion is line one.' "$HOME/.claude/output-styles/writing-style.md"
  assert_success
  run grep -q '"outputStyle": "writing-style"' "$HOME/.claude/settings.json"
  assert_success
}

@test "pi APPEND_SYSTEM.md carries the full writing-style rules" {
  assert_file_exists "$HOME/.pi/agent/APPEND_SYSTEM.md"
  run grep -q 'Answer first: the conclusion is line one.' "$HOME/.pi/agent/APPEND_SYSTEM.md"
  assert_success
}

@test "opencode reads the shared writing-style file via instructions" {
  assert_file_exists "$HOME/.config/agents/writing-style.md"
  run grep -q 'Answer first: the conclusion is line one.' "$HOME/.config/agents/writing-style.md"
  assert_success
  run grep -q '"~/.config/agents/writing-style.md"' "$HOME/.config/opencode/opencode.json"
  assert_success
}

@test "CLAUDE.md no longer duplicates the Writing style section" {
  run grep '^## Writing style' "$HOME/.claude/CLAUDE.md"
  assert_failure
}

@test "ask-agent skill is deployed" {
  assert_file_exists "$HOME/.claude/skills/ask-agent/SKILL.md"
  assert_file_exists "$HOME/.claude/skills/ask-agent/scripts/ask.sh"
  assert_file_exists "$HOME/.claude/skills/ask-agent/scripts/agents/claude.sh"
}

@test "se-flow orchestrator skill is deployed" {
  assert_file_exists "$HOME/.claude/skills/se-flow/SKILL.md"
}

@test "eli5 skill is deployed" {
  assert_file_exists "$HOME/.claude/skills/eli5/SKILL.md"
}

@test "writing-for-agents skill is deployed with its mechanics reference" {
  assert_file_exists "$HOME/.claude/skills/writing-for-agents/SKILL.md"
  assert_file_exists "$HOME/.claude/skills/writing-for-agents/SKILL-MECHANICS.md"
}

@test "work-summary skill is deployed with both format references" {
  assert_file_exists "$HOME/.claude/skills/work-summary/SKILL.md"
  assert_file_exists "$HOME/.claude/skills/work-summary/references/update-format.md"
  assert_file_exists "$HOME/.claude/skills/work-summary/references/report-format.md"
}

@test "pf-research, pf-spec, and pf-build skills are deployed with the shared cycle doc" {
  assert_file_exists "$HOME/.claude/skills/pf-research/SKILL.md"
  assert_file_exists "$HOME/.claude/skills/pf-spec/SKILL.md"
  assert_file_exists "$HOME/.claude/skills/pf-build/SKILL.md"
  assert_file_exists "$HOME/.claude/pf-cycle.md"
}

@test "herdr-pair skill is deployed" {
  assert_file_exists "$HOME/.claude/skills/herdr-pair/SKILL.md"
  assert_file_exists "$HOME/.claude/skills/herdr-pair/references/peer-protocol.md"
  assert_file_exists "$HOME/.claude/skills/herdr-pair/references/workbench-tab.md"
  assert_file_exists "$HOME/.claude/skills/herdr-pair/scripts/session.sh"
  assert_file_exists "$HOME/.claude/skills/herdr-pair/scripts/spawn-partner.sh"
  assert_file_exists "$HOME/.claude/skills/herdr-pair/scripts/send.sh"
  assert_file_exists "$HOME/.claude/skills/herdr-pair/scripts/recv.sh"
}

# ===========================================
# macOS-only configs (skipped on Linux)
# ===========================================

@test "hammerspoon config exists (macOS only)" {
  is_macos || skip "Not on macOS"
  assert_dir_exists "$HOME/.hammerspoon"
}

@test "ghostty config exists (macOS only)" {
  is_macos || skip "Not on macOS"
  assert_dir_exists "$HOME/.config/ghostty"
}

@test "kitty config exists (macOS only)" {
  is_macos || skip "Not on macOS"
  assert_dir_exists "$HOME/.config/kitty"
  assert_file_exists "$HOME/.config/kitty/kitty.conf"
  assert_file_exists "$HOME/.config/kitty/herdr.conf"
}

@test "kitty includes its herdr bindings and keeps the Alabaster theme (macOS only)" {
  is_macos || skip "Not on macOS"
  local config="$HOME/.config/kitty/kitty.conf"
  assert_file_contains "$config" "^include herdr.conf$"
  assert_file_contains "$config" "^include Alabaster.conf$"
}

@test "kitty font family is one kitty accepts as monospaced (macOS only)" {
  is_macos || skip "Not on macOS"
  # kitty rejects the non-Mono "IosevkaTerm Nerd Font" that ghostty uses and
  # falls back to Menlo without failing, so pin the Mono family explicitly.
  assert_file_contains "$HOME/.config/kitty/kitty.conf" \
    "^font_family  *IosevkaTerm Nerd Font Mono$"
}

@test "kitty auto-launches herdr without exec'ing it (macOS only)" {
  is_macos || skip "Not on macOS"
  local config="$HOME/.config/kitty/herdr.conf"
  # Detaching from herdr must return to a plain login shell, so herdr is run
  # as a normal command and the shell is exec'd afterwards.
  assert_file_contains "$config" "^shell /bin/zsh -lc .*herdr"
  assert_file_contains "$config" "^shell /bin/zsh -lc .*exec /bin/zsh -l"
}

@test "kitty sends the herdr prefix for macOS-style shortcuts (macOS only)" {
  is_macos || skip "Not on macOS"
  local config="$HOME/.config/kitty/herdr.conf"
  # \x02 is herdr's ctrl+b prefix; these must match the ghostty keybindings.
  assert_file_contains "$config" 'cmd+t send_text all .x02c$'
  assert_file_contains "$config" 'cmd+d send_text all .x02v$'
  assert_file_contains "$config" 'cmd+w send_text all .x02x$'
  assert_file_contains "$config" 'ctrl+shift+1 send_text all .x1b\[49;6u$'
  assert_file_contains "$config" '^map shift+alt+left send_text all .x1b\[1;4D$'
}

@test "kitty herdr bindings survive a non-Latin keyboard layout (macOS only)" {
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

@test "kitty carries command-palette hints for the herdr plugin (macOS only)" {
  is_macos || skip "Not on macOS"
  local config="$HOME/.config/kitty/herdr.conf"
  assert_file_contains "$config" "^# palette: Tabs & workspaces | ⌘T | New tab$"
  assert_file_contains "$config" "^# palette: Panes | ⌘D | Split right$"
}

@test "karabiner config exists (macOS only)" {
  is_macos || skip "Not on macOS"
  assert_dir_exists "$HOME/.config/karabiner"
}

@test "zed config exists (macOS only)" {
  is_macos || skip "Not on macOS"
  assert_dir_exists "$HOME/.config/zed"
}

@test "lazygit config keeps Russian-layout keybindings and popup exit (macOS only)" {
  is_macos || skip "Not on macOS"
  local config="$HOME/Library/Application Support/lazygit/config.yml"
  assert_file_contains "$config" "^keybinding:$"
  assert_file_contains "$config" "^  universal:$"
  assert_file_contains "$config" "^    prevBlock-alt: р$"
  assert_file_contains "$config" "^    nextItem-alt: о$"
  assert_file_contains "$config" "^    prevItem-alt: л$"
  assert_file_contains "$config" "^    nextBlock-alt: д$"
  assert_file_contains "$config" "^    scrollDownMain-alt1: О$"
  assert_file_contains "$config" "^    scrollUpMain-alt1: Л$"
  assert_file_contains "$config" "^    diffingMenu-alt: Ц$"
  assert_file_contains "$config" "^quitOnTopLevelReturn: true$"
}

@test "herdr caffeinate plugin exists (macOS only)" {
  is_macos || skip "Not on macOS"
  assert_file_exists "$HOME/.config/herdr/plugins/herdr-caffeinate/herdr-plugin.toml"
  assert_file_exists "$HOME/.config/herdr/plugins/herdr-caffeinate/reconcile.sh"
  assert_file_exists "$HOME/.config/herdr/plugins/herdr-caffeinate/lib.sh"
  assert_file_exists "$HOME/.config/herdr/plugins/herdr-caffeinate/actions.sh"
  assert_file_exists "$HOME/.config/herdr/plugins/herdr-caffeinate/config.example.sh"
}

@test "herdr caffeinate plugin scripts are valid sh (macOS only)" {
  is_macos || skip "Not on macOS"
  for f in reconcile.sh lib.sh actions.sh; do
    run sh -n "$HOME/.config/herdr/plugins/herdr-caffeinate/$f"
    [ "$status" -eq 0 ]
  done
}

# ===========================================
# Optional tools (installed via package manager)
# ===========================================

@test "starship is available (if installed)" {
  command_exists starship || skip "starship not installed"
  run starship --version
  assert_success
}

@test "bat is available (if installed)" {
  command_exists bat || skip "bat not installed"
  run bat --version
  assert_success
}

@test "eza is available (if installed)" {
  command_exists eza || skip "eza not installed"
  run eza --version
  assert_success
}

@test "fd is available (if installed)" {
  command_exists fd || skip "fd not installed"
  run fd --version
  assert_success
}

@test "fzf is available (if installed)" {
  command_exists fzf || skip "fzf not installed"
  run fzf --version
  assert_success
}

@test "ripgrep is available (if installed)" {
  command_exists rg || skip "ripgrep not installed"
  run rg --version
  assert_success
}

@test "delta is available (if installed)" {
  command_exists delta || skip "delta not installed"
  run delta --version
  assert_success
}

@test "yazi is available (if installed)" {
  command_exists yazi || skip "yazi not installed"
  run yazi --version
  assert_success
}

@test "lazygit is available (if installed)" {
  command_exists lazygit || skip "lazygit not installed"
  run lazygit --version
  assert_success
}

@test "zoxide is available (if installed)" {
  command_exists zoxide || skip "zoxide not installed"
  run zoxide --version
  assert_success
}

@test "mise is available (if installed)" {
  command_exists mise || skip "mise not installed"
  run mise --version
  assert_success
}

# ===========================================
# se CLI wrapper (source tree, SE_DRY_RUN)
# ===========================================

SE_ROOT="$SOURCE_ROOT"
SE_SRC="$SE_ROOT/private_dot_claude/dot_smithers/bin/executable_se"

se_fixture_repo() {
  local repo="$BATS_TEST_TMPDIR/target-repo"
  mkdir -p "$repo/docs/plans"
  printf '# fixture plan\n' > "$repo/docs/plans/plan.md"
  echo "$repo"
}

@test "se source script exists and passes bash syntax check" {
  assert_file_exists "$SE_SRC"
  run bash -n "$SE_SRC"
  assert_success
}

@test "se --help prints usage" {
  run bash "$SE_SRC" --help
  assert_success
  assert_output --partial "Usage: se"
  assert_output --partial "pipeline"
  assert_output --partial "resume <runId>"
}

@test "se pipeline dry-run assembles smithers command with env and input JSON" {
  local repo
  repo="$(se_fixture_repo)"
  cd "$repo"
  local repo_abs
  repo_abs="$(pwd -P)"
  run env SE_DRY_RUN=1 bash "$SE_SRC" pipeline docs/plans/plan.md --validate-cmd 'make test'
  assert_success
  assert_output --partial "PIPELINE_REPO=$repo_abs"
  assert_output --partial "DOC_REVIEW_REPO=$repo_abs"
  assert_output --partial "smithers up workflows/se-pipeline.tsx --detach --input"
  assert_output --partial "\"planPath\":\"$repo_abs/docs/plans/plan.md\""
  assert_output --partial '"until":"branch"'
  assert_output --partial '"validateCmd":"make test"'
}

@test "se pipeline forwards the single doc-review key: absent=false, --doc-review=true" {
  local repo
  repo="$(se_fixture_repo)"
  cd "$repo"
  # se-work path: no flag → docReview:false
  run env SE_DRY_RUN=1 bash "$SE_SRC" pipeline docs/plans/plan.md --validate-cmd 'make test'
  assert_success
  assert_output --partial '"docReview":false'
  # se-review-and-work path: --doc-review → docReview:true
  run env SE_DRY_RUN=1 bash "$SE_SRC" pipeline docs/plans/plan.md --validate-cmd 'make test' --doc-review
  assert_success
  assert_output --partial '"docReview":true'
}

@test "se-simplify skill + se-review-and-work skill + se-simplify workflow are in the source tree" {
  assert_file_exists "$SE_ROOT/private_dot_claude/skills/se-simplify/SKILL.md"
  assert_file_exists "$SE_ROOT/private_dot_claude/skills/se-review-and-work/SKILL.md"
  assert_file_exists "$SE_ROOT/private_dot_claude/dot_smithers/workflows/se-simplify.tsx"
  assert_file_exists "$SE_ROOT/private_dot_claude/dot_smithers/workflows/lib/stage-gate.ts"
}

@test "opencode config allows the /tmp/ce-simplify staging directory (R11)" {
  local cfg="$SE_ROOT/private_dot_config/opencode/opencode.json.tmpl"
  assert_file_exists "$cfg"
  run grep -F '/tmp/ce-simplify/*' "$cfg"
  assert_success
  run grep -F '/tmp/ce-simplify/**/*' "$cfg"
  assert_success
  run grep -F '/private/tmp/ce-simplify/**/*' "$cfg"
  assert_success
}

@test "se pipeline dry-run honors --until=pr and --attach (no --detach)" {
  local repo
  repo="$(se_fixture_repo)"
  cd "$repo"
  run env SE_DRY_RUN=1 bash "$SE_SRC" pipeline docs/plans/plan.md --until=pr --validate-cmd 'make test' --attach
  assert_success
  assert_output --partial '"until":"pr"'
  refute_output --partial -- "--detach"
}

@test "se pipeline fails on nonexistent plan with reason" {
  run env SE_DRY_RUN=1 bash "$SE_SRC" pipeline /nonexistent/plan.md --validate-cmd 'make test'
  assert_failure
  assert_output --partial "not found"
}

@test "se pipeline fails on invalid --until value" {
  local repo
  repo="$(se_fixture_repo)"
  cd "$repo"
  run env SE_DRY_RUN=1 bash "$SE_SRC" pipeline docs/plans/plan.md --until=xyz --validate-cmd 'make test'
  assert_failure
  assert_output --partial "until"
}

@test "se pipeline without --validate-cmd succeeds (derived from plan at gate-0)" {
  # --validate-cmd is optional: omitted => empty validateCmd in the input JSON,
  # and the workflow derives it from the plan's Verification Contract at gate-0.
  local repo
  repo="$(se_fixture_repo)"
  cd "$repo"
  run env SE_DRY_RUN=1 bash "$SE_SRC" pipeline docs/plans/plan.md
  assert_success
  assert_output --partial '"validateCmd":""'
}

@test "se resume without runId fails with usage" {
  run env SE_DRY_RUN=1 bash "$SE_SRC" resume
  assert_failure
  assert_output --partial "Usage: se"
}

@test "se abort dry-run maps to smithers cancel" {
  run env SE_DRY_RUN=1 bash "$SE_SRC" abort run-123
  assert_success
  assert_output --partial "smithers cancel run-123"
}

@test "se list dry-run exits 0 and maps to smithers ps" {
  run env SE_DRY_RUN=1 bash "$SE_SRC" list
  assert_success
  assert_output --partial "smithers ps"
}

@test "se approve/deny/logs/chat dry-run pass through to smithers verbatim" {
  for sub in approve deny logs chat; do
    run env SE_DRY_RUN=1 bash "$SE_SRC" "$sub" run-xyz
    assert_success
    assert_output --partial "smithers $sub run-xyz"
  done
}

@test "se approve without runId fails with usage" {
  run env SE_DRY_RUN=1 bash "$SE_SRC" approve
  assert_failure
  assert_output --partial "Usage: se"
}

@test "se with unknown command fails with usage" {
  run bash "$SE_SRC" frobnicate
  assert_failure
  assert_output --partial "Usage: se"
}

@test "se symlink source for ~/.local/bin exists in dotfiles" {
  local link_src="$SE_ROOT/dot_local/bin/symlink_se.tmpl"
  assert_file_exists "$link_src"
  run grep -q '.claude/.smithers/bin/se' "$link_src"
  assert_success
}

@test "smithers deps install script exists with hash triggers on package.json and bun.lock" {
  local script="$SE_ROOT/.chezmoiscripts/run_onchange_after_4-install-smithers-deps.sh.tmpl"
  assert_file_exists "$script"
  run grep -c 'sha256sum' "$script"
  assert_success
  assert_output "2"
}

@test "smithers deps install script skips gracefully without bun" {
  local script="$SE_ROOT/.chezmoiscripts/run_onchange_after_4-install-smithers-deps.sh.tmpl"
  run grep -q 'command -v bun' "$script"
  assert_success
}

@test "chezmoiignore excludes smithers runtime state from management" {
  local ignore="$SE_ROOT/.chezmoiignore"
  for entry in '.claude/.smithers/node_modules' '.claude/.smithers/smithers.db*' '.claude/.smithers/executions'; do
    run grep -qF "$entry" "$ignore"
    assert_success
  done
}

@test "se list --json dry-run maps to smithers ps --format json" {
  run env SE_DRY_RUN=1 bash "$SE_SRC" list --json
  assert_success
  assert_output --partial "smithers ps --format json"
}

@test "se show dry-run maps to smithers inspect --format json" {
  run env SE_DRY_RUN=1 bash "$SE_SRC" show run-xyz
  assert_success
  assert_output --partial "smithers inspect run-xyz --format json"
}

@test "se show without runId fails with usage" {
  run env SE_DRY_RUN=1 bash "$SE_SRC" show
  assert_failure
  assert_output --partial "Usage: se"
}

@test "se show rejects run ids with shell/sql metacharacters" {
  run env SE_DRY_RUN=1 bash "$SE_SRC" show "run';drop table summary;--"
  assert_failure
}

@test "se usage documents list --json and show" {
  run bash "$SE_SRC" --help
  assert_success
  assert_output --partial "list [--json]"
  assert_output --partial "show <runId>"
}

@test "se db-path walks up past an empty runtime smithers.db (0.28 state layout)" {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/parent/.smithers"
  echo x > "$tmp/parent/smithers.db"
  : > "$tmp/parent/.smithers/smithers.db"
  run env SE_SMITHERS_DIR="$tmp/parent/.smithers" bash "$SE_SRC" db-path
  assert_success
  assert_output "$tmp/parent/smithers.db"
  echo y > "$tmp/parent/.smithers/smithers.db"
  run env SE_SMITHERS_DIR="$tmp/parent/.smithers" bash "$SE_SRC" db-path
  assert_output "$tmp/parent/.smithers/smithers.db"
  rm -rf "$tmp"
}

# ===========================================
# herdr task sync (engine, adapters, sidebar)
# ===========================================

@test "herdr-task-sync engine is deployed and executable" {
  assert_file_exists "$HOME/.local/bin/herdr-task-sync"
  assert_file_executable "$HOME/.local/bin/herdr-task-sync"
}

@test "herdr-task-sync Claude Code hook is deployed and executable" {
  assert_file_exists "$HOME/.claude/hooks/herdr-task-sync-hook.sh"
  assert_file_executable "$HOME/.claude/hooks/herdr-task-sync-hook.sh"
}

@test "claude settings wire the task-sync hook to prompt, session, and compact" {
  local settings="$HOME/.claude/settings.json"
  assert_file_exists "$settings"
  run python3 - "$settings" <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
for event, action in (("UserPromptSubmit", "prompt"),
                      ("SessionStart", "session"),
                      ("PreCompact", "compact")):
    commands = [h["command"] for entry in hooks[event] for h in entry["hooks"]]
    matching = [c for c in commands if "herdr-task-sync-hook.sh" in c]
    assert len(matching) == 1, (event, commands)
    assert matching[0].endswith(f"' {action}"), (event, matching[0])
PY
  assert_success
}

@test "herdr-task-sync pi extension is deployed beside herdr's own" {
  local ext="$HOME/.pi/agent/extensions/herdr-task-sync.ts"
  assert_file_exists "$ext"
  assert_file_contains "$ext" 'before_agent_start'
  assert_file_contains "$ext" 'session_start'
  assert_file_contains "$ext" 'getSessionName'
}

@test "herdr-task-sync opencode plugin is deployed and filters child sessions" {
  local plugin="$HOME/.config/opencode/plugins/herdr-task-sync.ts"
  assert_file_exists "$plugin"
  assert_file_contains "$plugin" 'chat.message'
  # Static stand-in for AE4: subagent messages must not rename the pane.
  assert_file_contains "$plugin" 'parentID'
}

@test "herdr agents sidebar renders the pane label" {
  local config="$HOME/.config/herdr/config.toml"
  assert_file_contains "$config" '^\[ui.sidebar.agents\]'
  # herdr-task-sync writes '<agent badge> <task slug>' into the pane label, so
  # the sidebar shows the agent and its task through the `pane` row.
  assert_file_contains "$config" '^rows = .*"pane"'
}
