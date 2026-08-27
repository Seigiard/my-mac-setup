#!/usr/bin/env bats

load 'helpers/common'

# ===========================================
# python3 -- the declared interpreter
# ===========================================

# This file loses no skip guard, but it holds eight of the nine bare `run
# python3` call sites, so a contributor running it alone still needs the cause
# named rather than inferred from the failures.
@test "python3 is present and at least 3.9, the floor README.md declares" {
  assert_python3_available
}

@test "repository issues CLI exposes its contract and reads checkout issues" {
  local repository_root
  repository_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  [[ -f "$repository_root/scripts/issues" ]] || skip "repository checkout is not mounted"

  run python3 "$repository_root/scripts/issues" --version
  assert_success
  assert_output "repository-issues-contract 2"

  run bash -c 'cd "$1" && python3 scripts/issues list --status open --json' _ "$repository_root"
  assert_success
  run python3 -c 'import json, sys; value = json.loads(sys.argv[1]); assert isinstance(value["issues"], list)' "$output"
  assert_success
}

@test "post-apply suite wrapper rejects an unknown mode with usage" {
  local repository_root
  repository_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  [[ -x "$repository_root/tests/run-post-apply.sh" ]] || skip "repository checkout is not mounted"

  run "$repository_root/tests/run-post-apply.sh" unknown
  [ "$status" -eq 2 ]
  assert_output --partial "usage: tests/run-post-apply.sh full|host-safe"
}

# ===========================================
# Chezmoi-managed files exist
# ===========================================

# One manifest replaces the per-file existence tests. A file that falls out of
# management (a .chezmoiignore edit, a lost dot_ prefix) keeps `chezmoi verify`
# green — verify only checks what is still managed — so deployment and
# management membership are both asserted against this curated list.
@test "critical managed files are deployed and still managed" {
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
    .config/herdr/command-palette/commands.toml
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
  managed="$(PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" managed)"
  for p in "${paths[@]}"; do
    case $'\n'"$managed"$'\n' in
      *$'\n'"$p"$'\n'*) ;;
      *$'\n'"$p"/*) ;;
      *) unmanaged="$unmanaged $p" ;;
    esac
  done
  [ -z "$unmanaged" ] || fail "deployed but no longer chezmoi-managed:$unmanaged"
}

@test ".gitignore ignores the agent trash directory" {
  run grep -qx '\.scratchpad/' "$HOME/.gitignore"
  [ "$status" -eq 0 ]
}

@test "herdr command palette keybinding is configured" {
  assert_file_contains "$HOME/.config/herdr/config.toml" "seigi.command-palette.open"
  assert_file_contains "$HOME/.config/herdr/command-palette/commands.toml" "Edit command palette config"
}

@test "obsolete zed-herdr removal accepts formatted plugin JSON" {
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
      { "plugin_id": "artisann.zed-herdr" }
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
}

@test "obsolete zed-herdr removal reports malformed plugin JSON" {
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
  printf '{malformed}\n'
fi
exit 0
SH
  chmod +x "$fake_bin/uname" "$fake_bin/herdr"

  run env PATH="$fake_bin:$PATH" bash "$script"
  assert_success
  assert_output --partial "failed to inspect obsolete plugin artisann.zed-herdr"
}

@test "herdr plugin updates are automatic and owner-restricted" {
  local config="$SOURCE_ROOT/private_dot_config/herdr/plugins/config/herdr-auto-update/config.toml"

  assert_file_exists "$config"
  assert_file_contains "$config" 'auto_update = true'
  assert_file_contains "$config" 'trusted_owners = \["dio16"\]'
}

@test "herdr lazygit popup entrypoint is configured" {
  assert_file_contains "$HOME/.config/herdr/plugins/command-palette/herdr-plugin.toml" 'id = "lazygit"'
  assert_file_contains "$HOME/.config/herdr/command-palette/commands.toml" "Lazygit in popup"
}

@test "herdr command palette sources are valid" {
  run python3 -m py_compile \
    "$HOME/.config/herdr/plugins/command-palette/open.py" \
    "$HOME/.config/herdr/plugins/command-palette/open_in_zed.py" \
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
token = {mod.PALETTE_TOKEN: mod.PALETTE_TOKEN_VALUE}
assert mod.pane_is_palette({"pane_id": "pane-1", "tokens": token})
assert not mod.pane_is_palette({"pane_id": "pane-2", "tokens": {}})
assert not mod.pane_is_palette({"pane_id": "pane-3", "label": "nvim palette.py"})

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
    if command[:3] == ["herdr", "pane", "get"]:
        return Result('{"result":{"pane":{"pane_id":"pane-1","workspace_id":"w1","tokens":{"command_palette":"open"}}}}')
    if command[:4] == ["herdr", "plugin", "pane", "focus"]:
        return Result()
    raise AssertionError(command)

mod.subprocess.run = fake_run
os.environ.pop("HERDR_PLUGIN_CONTEXT_JSON", None)
os.environ.pop("HERDR_ACTIVE_PANE_ID", None)
os.environ.pop("HERDR_PANE_ID", None)
# fake_run matches argv[0] == "herdr", which is open.py's default. A shell
# inside a herdr pane exports HERDR_BIN_PATH, and the absolute path it carries
# would miss every branch of the mock and open a second palette instead.
os.environ.pop("HERDR_BIN_PATH", None)
assert mod.main() == 0
assert not any(command[:4] == ["herdr", "plugin", "pane", "open"] for command in calls)
PY
  assert_success
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

# ===========================================
# Claude Code configuration
# ===========================================

@test "writing-style output style is deployed and enabled in settings" {
  assert_file_exists "$HOME/.claude/output-styles/writing-style.md"
  run jq -e '.outputStyle == "writing-style"' "$HOME/.claude/settings.json"
  assert_success
}

@test "pi APPEND_SYSTEM.md is deployed" {
  assert_file_exists "$HOME/.pi/agent/APPEND_SYSTEM.md"
}

@test "pi settings include all managed packages" {
  local settings="$HOME/.pi/agent/settings.json"
  assert_file_exists "$settings"
  run jq -e '
    (.packages | index("npm:pi-subagents") != null) and
    (.packages | index("npm:pi-agent-browser-native") != null) and
    (.packages | index("npm:@howaboua/pi-codex-conversion") != null) and
    (.packages | index("npm:@trevonistrevon/pi-loop") != null) and
    (.packages | index("npm:pi-web-access") != null) and
    (.packages | index("npm:pi-context-view") != null) and
    (.packages | index("npm:@ff-labs/pi-fff") != null)
  ' "$settings"
  assert_success
}

@test "coding agents use terminal color palettes" {
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

@test "opencode reads the shared writing-style file via instructions" {
  assert_file_exists "$HOME/.config/agents/writing-style.md"
  run jq -e '.instructions | index("~/.config/agents/writing-style.md") != null' "$HOME/.config/opencode/opencode.json"
  assert_success
}

@test "opencode exposes curated claude skills through canonical symlinks" {
  local skill

  for skill in ask-in-herdr markdown-new plan-explainer vector-prime work-summary writing-for-agents; do
    run readlink "$HOME/.config/opencode/skills/$skill"
    assert_success
    assert_output "$HOME/.claude/skills/$skill"
    assert_file_exists "$HOME/.config/opencode/skills/$skill/SKILL.md"
  done
}

@test "explicit-only workflows keep manual invocation boundaries" {
  local workflow claude_skill opencode_command opencode_skill

  for workflow in eli5 open-questions; do
    claude_skill="$HOME/.claude/skills/$workflow/SKILL.md"
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

  run zsh -dfc 'unset OPENCODE_DISABLE_EXTERNAL_SKILLS OPENCODE_DISABLE_CLAUDE_CODE_SKILLS; source "$1"; zsh -dfc "$2"' _ "$HOME/.zshenv" '[[ "$OPENCODE_DISABLE_EXTERNAL_SKILLS" == 1 && "$OPENCODE_DISABLE_CLAUDE_CODE_SKILLS" == 1 ]]'
  assert_success
}

# One manifest replaces the per-skill existence tests; content-level guards
# (YAML descriptions, shared-pointer resolution) keep their own tests below.
@test "agent skills are deployed with their scripts and references" {
  local files=(
    skills/ask-in-herdr/SKILL.md
    skills/ask-in-herdr/scripts/ask.sh
    shared/child-agent-contract.md
    skills/se-flow/SKILL.md
    skills/se-cleanup/SKILL.md
    skills/eli5/SKILL.md
    skills/open-questions/SKILL.md
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
    shared/pf-cycle.md
    skills/pf-build/references/direct-build.md
    skills/pf-build/references/implementer-prompt.md
    skills/pf-build/references/demo.md
    skills/plan-explainer/SKILL.md
    skills/plan-explainer/references/sections.md
    skills/plan-explainer/references/page-craft.md
  )
  local f missing=""
  for f in "${files[@]}"; do
    [ -f "$HOME/.claude/$f" ] || missing="$missing $f"
  done
  [ -z "$missing" ] || fail "missing under ~/.claude:$missing"

  # The retired per-agent scripts directory must stay deleted.
  assert_dir_not_exists "$HOME/.claude/skills/ask-in-herdr/scripts/agents"
}

@test "shared references are deployed" {
  assert_file_exists "$HOME/.claude/shared/README.md"
  assert_file_exists "$HOME/.claude/shared/pf-cycle.md"
  assert_file_exists "$HOME/.claude/shared/herdr-peer-launch.md"
  assert_file_exists "$HOME/.claude/shared/decision-brief.md"
  assert_file_exists "$HOME/.claude/shared/child-agent-contract.md"
}

# ===========================================
# macOS-only configs (skipped on Linux)
# ===========================================

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

@test "lazygit config keeps Russian-layout keybindings and popup exit (macOS only)" {
  is_macos || skip "Not on macOS"
  local config="$HOME/Library/Application Support/lazygit/config.yml"
  # One -alt binding stands in for the whole Russian-layout section; losing the
  # section drops them all together, so a single marker catches it.
  assert_file_contains "$config" "^    prevBlock-alt: р$"
  assert_file_contains "$config" "^quitOnTopLevelReturn: true$"
}

@test "herdr caffeinate plugin scripts are valid sh (macOS only)" {
  is_macos || skip "Not on macOS"
  for f in reconcile.sh lib.sh actions.sh; do
    run sh -n "$HOME/.config/herdr/plugins/herdr-caffeinate/$f"
    [ "$status" -eq 0 ]
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

@test "focus-notify plugin compiles and declares its runtime entrypoint" {
  run env PYTHONPYCACHEPREFIX="$BATS_TEST_TMPDIR/pycache" \
    python3 -m py_compile "$FOCUS_NOTIFY_DIR/notify.py"
  assert_success

  # The manifest wires the status event and the interpreter as argv arrays.
  assert_file_contains "$FOCUS_NOTIFY_DIR/herdr-plugin.toml" \
    '^on = "pane.agent_status_changed"$'
  assert_file_contains "$FOCUS_NOTIFY_DIR/herdr-plugin.toml" \
    '^command = \["python3", "notify.py"\]$'
}

@test "focus-notify builds a safely quoted click command" {
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

@test "focus-notify stays quiet for non-actionable statuses and missing pane id" {
  run_focus_notify '{"data":{"pane_id":"w1:p1","agent_status":"working","agent":"codex"}}'
  assert_success
  assert_file_not_exists "$FOCUS_NOTIFY_ARGV"

  run_focus_notify '{"data":{"agent_status":"blocked","agent":"codex"}}'
  assert_success
  assert_file_not_exists "$FOCUS_NOTIFY_ARGV"
}

@test "focus-notify uses one notification group per pane for duplicate replacement" {
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
@test "fzf is installed and meets the command palette's version floor" {
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

@test "herdr task and child engines are deployed and executable" {
  assert_file_exists "$HOME/.local/bin/herdr-task-sync"
  assert_file_executable "$HOME/.local/bin/herdr-task-sync"
  assert_file_exists "$HOME/.local/bin/herdr-child"
  assert_file_executable "$HOME/.local/bin/herdr-child"
  assert_file_exists "$HOME/.local/lib/herdr-process.sh"
}

@test "deployed herdr child contracts expose managed supervision modes" {
  local contract="$HOME/.claude/shared/child-agent-contract.md"
  local skill="$HOME/.claude/skills/herdr/SKILL.md"
  local consult="$HOME/.claude/skills/ask-in-herdr/SKILL.md"

  assert_file_contains "$contract" 'herdr-child start.*--wait'
  assert_file_contains "$contract" 'herdr-child start.*--detach'
  assert_file_contains "$contract" 'generation.*event'
  assert_file_contains "$contract" 'herdr-child prompt.*--wait'
  assert_file_contains "$contract" 'herdr-child prompt.*--detach'
  assert_file_contains "$contract" 'not.*task-success verdict'
  assert_file_contains "$contract" 'start.*prompt.*reply.*nonzero.*recovery JSON'
  assert_file_contains "$contract" 'Do not retry.*start.*same name'
  assert_file_contains "$contract" 'herdr agent get.*pane-id'
  assert_file_contains "$contract" 'managed.*herdr-child prompt.*--detach.*reap'
  assert_file_contains "$skill" 'cooperative exclusive file scope'
  assert_file_contains "$skill" 'nonzero recovery JSON.*preserving the child'
  assert_file_contains "$skill" 'Do not retry.*start.*same name'
  assert_file_contains "$skill" 'herdr agent get'
  assert_file_contains "$skill" 'rearm.*managed.*prompt.*--detach.*reap'
  assert_file_contains "$consult" 'attached.*--wait'
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

# UserPromptSubmit has no matcher support; the herdr agent-state SessionStart
# hook must stay wired alongside the task-sync one.
assert all("matcher" not in e for e in hooks["UserPromptSubmit"]), hooks["UserPromptSubmit"]
session = [h["command"] for entry in hooks["SessionStart"] for h in entry["hooks"]]
assert any("herdr-agent-state.sh" in c for c in session), session
PY
  assert_success
}

@test "herdr-task-sync pi extension is deployed beside herdr's own" {
  local ext="$HOME/.pi/agent/extensions/herdr-task-sync.ts"
  assert_file_exists "$ext"
}

@test "Pi local private instructions focused tests pass" {
  run env PI_AGENTS_LOCAL_EXTENSION_PATH="$HOME/.pi/agent/extensions/agents-local.ts" \
    bun test "$BATS_TEST_DIRNAME/pi-agents-local-extension.test.ts"
  assert_success
}

@test "Pi brew auto updater is deployed" {
  local ext="$HOME/.pi/agent/extensions/brew-auto-update/index.ts"
  assert_file_exists "$ext"
}

@test "Pi brew auto updater focused tests pass" {
  run bun test "$BATS_TEST_DIRNAME/pi-brew-auto-update.test.ts"
  assert_success
}

@test "herdr-task-sync opencode plugin is deployed" {
  local plugin="$HOME/.config/opencode/plugins/herdr-task-sync.ts"
  assert_file_exists "$plugin"
}

assert_herdr_sidebar_deployment_contract() {
  local config="$1"
  local width

  assert_file_contains "$config" '^sidebar_min_width = 32$'
  assert_file_contains "$config" '^\[ui.sidebar.agents\]$'
  # Tab labels stay names-only, while the sidebar keeps Git location on its
  # own row so branch/worktree context never competes with the agent name.
  assert_file_contains "$config" '^rows = \[\["state_icon", "workspace", "pane"\], \["\$git_ref"\]\]$'
  run grep -E '\$location_label|\$location_status' "$config"
  assert_failure
  width="$(awk '
    $0 == "[ui]" { in_ui = 1; next }
    /^\[/ { in_ui = 0 }
    in_ui && /^sidebar_min_width = [0-9]+$/ { print $3 }
  ' "$config")"
  [ "$width" -eq 32 ]
  [ "$((width - 4))" -ge 28 ]
  [ "$((width - 4))" -ge 8 ]
}

@test "herdr managed source preserves the U6 sidebar and ownership boundaries" {
  assert_herdr_sidebar_deployment_contract "$SOURCE_ROOT/private_dot_config/herdr/config.toml"
}

@test "herdr deployed files preserve the U6 sidebar and ownership boundaries" {
  assert_herdr_sidebar_deployment_contract "$HOME/.config/herdr/config.toml"
}

@test "herdr pane-label plugin deploys the approved Herdr 0.8 lifecycle inputs" {
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
  assert_output $'pane.created|["sh", "ensure.sh", "--event"]\npane.moved|["sh", "ensure.sh", "--event"]\npane.exited|["sh", "ensure.sh", "--event"]\npane.closed|["sh", "ensure.sh", "--event"]\npane.agent_detected|["sh", "ensure.sh", "--event"]\npane.agent_status_changed|["sh", "ensure.sh", "--event"]\ntab.created|["sh", "ensure.sh", "--event"]\ntab.closed|["sh", "ensure.sh", "--event"]\ntab.moved|["sh", "ensure.sh", "--event"]\ntab.renamed|["sh", "ensure.sh", "--event"]'
  assert_file_contains "$manifest" '^min_herdr_version = "0\.8\.0"$'
  assert_file_contains "$manifest" '^id = "sweep"$'
  assert_file_contains "$manifest" '^title = "Pane labels: refresh now"$'
  assert_file_contains "$manifest" '^command = \["sh", "sweep\.sh"\]$'
  run grep -E '^on = ".*\*|^on = "(pane\.updated|workspace\.focused|tab\.focused|pane\.focused)"|reclaim' "$manifest"
  assert_failure
}

@test "herdr pane-label plugin keeps startup sweep and relink deployment wiring" {
  local plugin="$HOME/.config/herdr/plugins/herdr-pane-labels"
  local manifest="$plugin/herdr-plugin.toml"
  local relink="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_6-link-herdr-pane-labels.sh.tmpl"
  assert_file_contains "$manifest" '^\[\[startup\]\]$'
  assert_file_contains "$manifest" '^command = \["sh", "ensure.sh"\]$'
  assert_file_contains "$relink" 'include "private_dot_config/herdr/plugins/herdr-pane-labels/herdr-plugin.toml"'
  assert_file_contains "$relink" 'include "private_dot_config/herdr/plugins/herdr-pane-labels/ensure.sh"'
  assert_file_contains "$relink" 'include "private_dot_config/herdr/plugins/herdr-pane-labels/sweep.sh"'
  assert_file_contains "$relink" 'include "private_dot_config/herdr/config.toml"'
  assert_file_contains "$relink" 'include "dot_local/bin/executable_herdr-task-sync"'
}

# ===========================================
# zsh cached_init consumers (docs/issues/2026-08-21-001)
#
# ~/.zshrc caches the output of these tools via cached_init and sources the
# cache in every later shell. An absolute `export PATH=...` line in any of
# them would freeze the generating shell PATH into every shell that sources
# the cache -- the exact bug mise activate had. As of 2026-08-21 none of them
# emits one; these guards keep it that way across tool upgrades.
# ===========================================

@test "starship init output embeds no absolute PATH export" {
  command_exists starship || skip "starship not installed"
  run starship init zsh
  assert_success
  refute_line --regexp '^export PATH='
}

@test "zoxide init output embeds no absolute PATH export" {
  command_exists zoxide || skip "zoxide not installed"
  run zoxide init zsh --cmd cd
  assert_success
  refute_line --regexp '^export PATH='
}

@test "rgrc aliases output embeds no absolute PATH export" {
  command_exists rgrc || skip "rgrc not installed"
  run rgrc --aliases
  assert_success
  refute_line --regexp '^export PATH='
}
