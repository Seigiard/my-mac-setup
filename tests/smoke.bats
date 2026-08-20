#!/usr/bin/env bats

load 'helpers/common'

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

@test "remaining herdr GitHub plugins install automatically on macOS" {
  local script="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_7-install-herdr-github-plugins.sh.tmpl"

  assert_file_exists "$script"
  run grep -F "ImArtisann/zed-herdr:artisann.zed-herdr" "$script"
  assert_failure
  assert_file_contains "$script" 'herdr plugin uninstall artisann.zed-herdr'
  assert_file_contains "$script" "dio16/herdr-auto-update:herdr-auto-update"
  assert_file_contains "$script" 'herdr plugin install "$repo" -y'
  assert_file_contains "$script" 'herdr plugin enable "$plugin_id"'

  run grep -Fq '[[ "$(uname -s)" != "Darwin" ]]' "$script"
  assert_success

  run bash -n "$script"
  assert_success
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

# herdr-auto-update holds any plugin whose GitHub owner is absent from
# trusted_owners, so adding a plugin without extending the list silently stops
# that plugin from ever updating. Keep the two lists coupled.
@test "every auto-installed herdr plugin owner is listed in trusted_owners" {
  local script="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_7-install-herdr-github-plugins.sh.tmpl"
  local config="$SOURCE_ROOT/private_dot_config/herdr/plugins/config/herdr-auto-update/config.toml"

  local owners_line
  owners_line="$(grep '^trusted_owners' "$config")"

  local owner
  local count=0
  while read -r owner; do
    [ -n "$owner" ] || continue
    count=$((count + 1))
    if [[ "$owners_line" != *"\"$owner\""* ]]; then
      fail "plugin owner $owner is installed by the script but missing from trusted_owners"
    fi
  done < <(awk '/^plugins=\(/{f=1;next} f&&/^\)/{f=0} f' "$script" |
    sed -n 's/^[[:space:]]*"\([^\/"]*\)\/.*/\1/p')

  [ "$count" -gt 0 ]
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

@test "pi settings include all managed packages" {
  local settings="$HOME/.pi/agent/settings.json"
  assert_file_exists "$settings"
  run jq -e '
    (.packages | index("npm:pi-subagentura") != null) and
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
  run grep -q 'Answer first: the conclusion is line one.' "$HOME/.config/agents/writing-style.md"
  assert_success
  run grep -q '"~/.config/agents/writing-style.md"' "$HOME/.config/opencode/opencode.json"
  assert_success
}

@test "CLAUDE.md no longer duplicates the Writing style section" {
  run grep '^## Writing style' "$HOME/.claude/CLAUDE.md"
  assert_failure
}

# One manifest replaces the per-skill existence tests; content-level guards
# (YAML descriptions, shared-pointer resolution) keep their own tests below.
@test "agent skills are deployed with their scripts and references" {
  local files=(
    skills/ask-in-herdr/SKILL.md
    skills/ask-in-herdr/scripts/ask.sh
    shared/child-agent-contract.md
    skills/se-flow/SKILL.md
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
  )
  local f missing=""
  for f in "${files[@]}"; do
    [ -f "$HOME/.claude/$f" ] || missing="$missing $f"
  done
  [ -z "$missing" ] || fail "missing under ~/.claude:$missing"

  # The retired per-agent scripts directory must stay deleted.
  assert_dir_not_exists "$HOME/.claude/skills/ask-in-herdr/scripts/agents"
}

@test "every skill description survives YAML parsing" {
  # An unquoted YAML scalar ends at " #" (comment) and cannot contain ": ".
  # Both truncate or invalidate the description, which is how the agent finds
  # the skill at all — and both fail silently in a lenient parser.
  local offenders=""
  for skill in "$HOME"/.claude/skills/*/SKILL.md; do
    [ -f "$skill" ] || continue
    local line
    line=$(grep -m1 '^description:' "$skill") || continue
    local value=${line#description:}
    value=${value# }
    case "$value" in
      \"*|\'*|\|*|\>*) continue ;;            # quoted or block scalar: safe
    esac
    case "$value" in
      *" #"*|*": "*) offenders="$offenders $skill" ;;
    esac
  done
  [ -z "$offenders" ] || fail "unquoted description with ' #' or ': ':$offenders"
}

@test "shared references are deployed and every pointer to them resolves" {
  assert_file_exists "$HOME/.claude/shared/README.md"
  assert_file_exists "$HOME/.claude/shared/pf-cycle.md"
  assert_file_exists "$HOME/.claude/shared/se-harness.md"
  assert_file_exists "$HOME/.claude/shared/decision-brief.md"
  assert_file_exists "$HOME/.claude/shared/child-agent-contract.md"

  # No skill may point into another skill's references/ — shared material lives in shared/.
  run grep -rEl '~/\.claude/skills/[a-z-]+/references/' "$HOME/.claude/skills"
  assert_output ""
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

@test "se-simplify skill + se-review-and-work skill + se-simplify workflow are in the source tree" {
  assert_file_exists "$SE_ROOT/private_dot_claude/skills/se-simplify/SKILL.md"
  assert_file_exists "$SE_ROOT/private_dot_claude/skills/se-review-and-work/SKILL.md"
  assert_file_exists "$SE_ROOT/private_dot_claude/dot_smithers/workflows/se-simplify.tsx"
  assert_file_exists "$SE_ROOT/private_dot_claude/dot_smithers/workflows/lib/stage-gate.ts"
}

@test "opencode config allows every external staging directory (R11)" {
  local cfg="$SE_ROOT/private_dot_config/opencode/opencode.json.tmpl"
  assert_file_exists "$cfg"
  run grep -F '"*": "allow"' "$cfg"
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

@test "smithers workflows carry a tsconfig so the package can be type-checked" {
  # `bun build` resolves the module graph without type-checking, so a green
  # build says nothing about types — a reserved output field refused every
  # launch for a day while the build stayed green
  # (docs/issues/2026-08-14-004). The tsconfig is what makes `bunx tsc
  # --noEmit` runnable at all (docs/issues/2026-08-15-006).
  local config="$SE_ROOT/private_dot_claude/dot_smithers/tsconfig.json"
  assert_file_exists "$config"
  # The JSX pragma is per-file today; the config must agree with it, or a file
  # that omits the pragma type-checks against the wrong runtime.
  run grep -q 'smithers-orchestrator' "$config"
  assert_success
}

@test "smithers workflows declare bun's own type definitions" {
  # Without @types/bun the language server cannot resolve bun:sqlite / bun:test
  # and reports an error in nearly every file, which trains its reader to
  # ignore it (docs/issues/2026-08-15-006).
  local manifest="$SE_ROOT/private_dot_claude/dot_smithers/package.json"
  run grep -q '"@types/bun"' "$manifest"
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
  assert_file_contains "$ext" 'before_agent_start'
  assert_file_contains "$ext" 'session_start'
  assert_file_contains "$ext" 'getSessionName'
}

@test "Pi brew auto updater is deployed with startup and manual entry points" {
  local ext="$HOME/.pi/agent/extensions/brew-auto-update/index.ts"
  assert_file_exists "$ext"
  assert_file_contains "$ext" 'pi.on("session_start"'
  assert_file_contains "$ext" 'event.reason !== "startup"'
  assert_file_contains "$ext" 'registerCommand("brew-auto-update-now"'
  assert_file_contains "$ext" 'PI_OFFLINE'
  assert_file_contains "$ext" 'PI_BREW_AUTO_UPDATE'
}

@test "Pi brew auto updater keeps package-manager commands scoped" {
  local ext="$HOME/.pi/agent/extensions/brew-auto-update/index.ts"
  run python3 - "$ext" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding="utf-8").read()
required = [
    r'command: "brew",\s+args: \["update"\]',
    r'command: "brew",\s+args: \["upgrade", "pi-coding-agent"\]',
    r'command: "pi",\s+args: \["update", "--extensions"\]',
    r'deps\.exec\(step\.command, \[\.\.\.step\.args\]',
]
for pattern in required:
    assert re.search(pattern, source), pattern
for forbidden in ('"--self"', '"--all"', 'command: "npm"'):
    assert forbidden not in source, forbidden
assert len(re.findall(r'command: "brew"', source)) == 2
assert len(re.findall(r'command: "pi"', source)) == 1
PY
  assert_success
}

@test "Pi brew auto updater focused tests pass" {
  run bun test "$BATS_TEST_DIRNAME/pi-brew-auto-update.test.ts"
  assert_success
}

@test "herdr-task-sync opencode plugin is deployed and filters child sessions" {
  local plugin="$HOME/.config/opencode/plugins/herdr-task-sync.ts"
  assert_file_exists "$plugin"
  assert_file_contains "$plugin" 'chat.message'
  # Static stand-in for AE4: subagent messages must not rename the pane.
  assert_file_contains "$plugin" 'parentID'
}

assert_herdr_sidebar_deployment_contract() {
  local config="$1"
  local engine="$2"
  local plugin="$3"
  local claude_adapter="$4"
  local opencode_adapter="$5"
  local pi_adapter="$6"
  local width
  local writer_files=(
    "$engine"
    "$plugin/herdr-plugin.toml"
    "$plugin/ensure.sh"
    "$plugin/sweep.sh"
    "$claude_adapter"
    "$opencode_adapter"
    "$pi_adapter"
  )
  local writer_roots=(
    "$(dirname "$engine")"
    "$(dirname "$config")"
    "$(dirname "$claude_adapter")"
    "$(dirname "$opencode_adapter")"
    "$(dirname "$pi_adapter")"
  )

  assert_file_contains "$config" '^sidebar_min_width = 32$'
  assert_file_contains "$config" '^\[ui.sidebar.agents\]$'
  # Herdr 0.8 collapses an empty custom-token row when the token is the row's
  # only item. The first row keeps workspace and task together, and the second
  # row carries the one combined $git_ref token — stale state rides on it as
  # a suffix icon, so there is no third row and no $location_status token.
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
  assert_file_contains "$config" 'rows = \[\["state_icon", "workspace", "pane"\], \["\$git_ref"\]\]'
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

  run grep -Ei 'location_status|(^|[^[:alnum:]_])(location|worktree|branch|git)([^[:alnum:]_]|$)' \
    "$claude_adapter" "$opencode_adapter" "$pi_adapter"
  assert_failure
}

@test "herdr managed source preserves the U6 sidebar and ownership boundaries" {
  assert_herdr_sidebar_deployment_contract \
    "$SOURCE_ROOT/private_dot_config/herdr/config.toml" \
    "$SOURCE_ROOT/dot_local/bin/executable_herdr-task-sync" \
    "$SOURCE_ROOT/private_dot_config/herdr/plugins/herdr-pane-labels" \
    "$SOURCE_ROOT/private_dot_claude/hooks/executable_herdr-task-sync-hook.sh" \
    "$SOURCE_ROOT/private_dot_config/opencode/plugins/herdr-task-sync.ts" \
    "$SOURCE_ROOT/dot_pi/agent/extensions/herdr-task-sync.ts"
}

@test "herdr deployed files preserve the U6 sidebar and ownership boundaries" {
  assert_herdr_sidebar_deployment_contract \
    "$HOME/.config/herdr/config.toml" \
    "$HOME/.local/bin/herdr-task-sync" \
    "$HOME/.config/herdr/plugins/herdr-pane-labels" \
    "$HOME/.claude/hooks/herdr-task-sync-hook.sh" \
    "$HOME/.config/opencode/plugins/herdr-task-sync.ts" \
    "$HOME/.pi/agent/extensions/herdr-task-sync.ts"
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
  assert_file_contains "$plugin/ensure.sh" 'herdr-task-sync'
  assert_file_contains "$plugin/ensure.sh" 'sync.*--ensure-daemon'
  assert_file_contains "$plugin/sweep.sh" 'sync.*--sweep'
  assert_file_contains "$relink" 'include "private_dot_config/herdr/plugins/herdr-pane-labels/herdr-plugin.toml"'
  assert_file_contains "$relink" 'include "private_dot_config/herdr/plugins/herdr-pane-labels/ensure.sh"'
  assert_file_contains "$relink" 'include "private_dot_config/herdr/plugins/herdr-pane-labels/sweep.sh"'
  assert_file_contains "$relink" 'herdr plugin link'
  assert_file_contains "$relink" 'herdr plugin enable seigi.pane-labels'
}
