#!/usr/bin/env bash
# templates post-apply suite — bashunit source. Vocabulary (run, assert_*,
# skip, BATS_* contract) comes from tests/bashunit/test-dsl.bash.
# Migrated from templates.bats; parity evidence: docs/benchmarks/bashunit-full-suite-experiment.md.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"


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
# python3 -- the declared interpreter
# ===========================================

# First, so JSON validation below fails with the repository-level requirement
# message rather than a bare `python3: command not found`.
function test_templates_001_python3_is_present_and_at_least_3_9_the_floor_re() {
  _bats_test_init 1 'python3 is present and at least 3.9, the floor README.md declares'
  assert_python3_available
}

# ===========================================
# .chezmoi.yaml.tmpl (validated via chezmoi data — init-only template
# uses promptStringOnce which is unavailable in execute-template)
# ===========================================

# CHEZMOI_NAME/CHEZMOI_EMAIL bind at `chezmoi init`, not at data/render time,
# so `chezmoi data` reads whatever config the host already has and the setup()
# exports above are inert there — asserting on `chezmoi data` output proved
# nothing about the env vars. Bind each value into its own init-time config via
# write_test_config and prove a different value renders differently: the second
# render is the control that the first match came from the env var, not from
# ambient host state.
function test_templates_002_chezmoi_init_binds_name_from_env_var() {
  _bats_test_init 2 'chezmoi init binds name from env var'
  local tmpl="$BATS_TEST_TMPDIR/name.tmpl"
  printf '{{ .name }}' > "$tmpl"

  CHEZMOI_NAME="Alpha Tester" write_test_config "$BATS_TEST_TMPDIR/name-a.yaml"
  run render_with_config "$BATS_TEST_TMPDIR/name-a.yaml" "$tmpl"
  assert_success
  assert_output "Alpha Tester"

  CHEZMOI_NAME="Beta Tester" write_test_config "$BATS_TEST_TMPDIR/name-b.yaml"
  run render_with_config "$BATS_TEST_TMPDIR/name-b.yaml" "$tmpl"
  assert_success
  assert_output "Beta Tester"
}

function test_templates_003_chezmoi_init_binds_email_from_env_var() {
  _bats_test_init 3 'chezmoi init binds email from env var'
  local tmpl="$BATS_TEST_TMPDIR/email.tmpl"
  printf '{{ .email }}' > "$tmpl"

  CHEZMOI_EMAIL="alpha@example.net" write_test_config "$BATS_TEST_TMPDIR/email-a.yaml"
  run render_with_config "$BATS_TEST_TMPDIR/email-a.yaml" "$tmpl"
  assert_success
  assert_output "alpha@example.net"

  CHEZMOI_EMAIL="beta@example.net" write_test_config "$BATS_TEST_TMPDIR/email-b.yaml"
  run render_with_config "$BATS_TEST_TMPDIR/email-b.yaml" "$tmpl"
  assert_success
  assert_output "beta@example.net"
}

# ===========================================
# dot_gitconfig.tmpl
# ===========================================

function test_templates_004_gitconfig_template_renders_successfully() {
  _bats_test_init 4 'gitconfig template renders successfully'
  run render_template "$SOURCE_ROOT/dot_gitconfig.tmpl"
  assert_success
}

function test_templates_005_gitconfig_template_contains_user_name() {
  _bats_test_init 5 'gitconfig template contains user name'
  run render_template "$SOURCE_ROOT/dot_gitconfig.tmpl"
  assert_output --partial "name = "
}

function test_templates_006_gitconfig_template_contains_user_email() {
  _bats_test_init 6 'gitconfig template contains user email'
  run render_template "$SOURCE_ROOT/dot_gitconfig.tmpl"
  assert_output --partial "email = "
}

# ===========================================
# dot_zshenv.tmpl
# ===========================================

function test_templates_007_zshenv_template_renders_without_op_in_path() {
  _bats_test_init 7 'zshenv template renders without op in PATH'
  run render_template "$SOURCE_ROOT/dot_zshenv.tmpl"
  assert_success
}

# ===========================================
# dot_zshrc.tmpl
# ===========================================

function test_templates_008_zshrc_template_renders_successfully() {
  _bats_test_init 8 'zshrc template renders successfully'
  run render_template "$SOURCE_ROOT/dot_zshrc.tmpl"
  assert_success
}

# ===========================================
# zsh init-cache generation (concurrency safety)
#
# Several shells can start at once — a terminal restoring its panes, or a
# multiplexer opening a tab. Each one regenerates a stale cache. Writing the
# cache path directly with `>` lets one shell's tail survive past the end of
# another shell's shorter output, leaving a spliced file that the next shell
# sources. That is how ~/.cache/zsh/mise-activate.zsh grew five orphan lines
# and every new shell printed "zsh: command not found: ".
# ===========================================

function test_templates_009_zshenv_mise_cache_does_not_freeze_the_generating() {
  _bats_test_init 9 'zshenv mise cache does not freeze the generating shell'\''s PATH into later shells'
  command_exists zsh || skip "zsh not installed"

  local work="$BATS_TEST_TMPDIR/mise-freeze"
  mkdir -p "$work/bin" "$work/home" "$work/marker" "$work/toolbin"

  # A fake mise shaped like the real activate output: line 1 is an absolute
  # snapshot of the generating shell's PATH; the second line mutates PATH at
  # source time, standing in for the trailing `_mise_hook` call that real
  # activate output performs via `mise hook-env`.
  cat > "$work/bin/mise" <<MISE
#!/bin/sh
if [ "\$1" = "activate" ]; then
  printf "export PATH='%s'\n" "\$PATH"
  printf 'export PATH="%s/toolbin:\$PATH"\n' "$work"
fi
MISE
  chmod +x "$work/bin/mise"

  render_template "$SOURCE_ROOT/dot_zshenv.tmpl" > "$work/zshenv.rendered"

  # The shim is a function, not a PATH entry, because the rendered zshenv
  # prepends the homebrew dirs before the mise block: on a host with a real
  # mise install, any PATH-based fake would be shadowed by it. zsh's
  # `command -v` resolves functions, so `has mise` and the activate call both
  # hit the fake, and the `-ot` regeneration probe against the nonexistent
  # path "mise" is simply false.
  # Shell 1 generates the cache while a marker directory is on its PATH.
  cat > "$work/gen.zsh" <<GEN
mise() { "$work/bin/mise" "\$@" }
export HOME="$work/home"
export PATH="$work/marker:/usr/bin:/bin"
source "$work/zshenv.rendered"
GEN
  run zsh -f "$work/gen.zsh"
  assert_success
  assert_file_exists "$work/home/.cache/zsh/mise-activate.zsh"

  # The generating shell's PATH (with the marker) must not be in the cache;
  # the runtime PATH-mutation line must survive the strip.
  run grep -F "$work/marker" "$work/home/.cache/zsh/mise-activate.zsh"
  assert_failure
  run grep -F "$work/toolbin" "$work/home/.cache/zsh/mise-activate.zsh"
  assert_success

  # Shell 2 starts with a normal PATH against the same cache: the marker must
  # not leak in, while the runtime hook line must still mutate PATH.
  cat > "$work/probe.zsh" <<PROBE
mise() { "$work/bin/mise" "\$@" }
export HOME="$work/home"
export PATH="/usr/bin:/bin"
source "$work/zshenv.rendered"
print -r -- "\$PATH"
PROBE
  run zsh -f "$work/probe.zsh"
  assert_success
  refute_output --partial "$work/marker"
  assert_output --partial "$work/toolbin"
}

function test_templates_010_zshrc_cached_init_never_splices_two_concurrent_g() {
  _bats_test_init 10 'zshrc cached_init never splices two concurrent generators'
  command_exists zsh || skip "zsh not installed"

  local work="$BATS_TEST_TMPDIR/cached_init"
  mkdir -p "$work/bin" "$work/cache"

  # Two generators with the same line count but different line lengths: the
  # splice is only observable when the outputs differ in byte length.
  cat > "$work/bin/genlong" <<'GEN'
#!/bin/sh
i=0; while [ $i -lt 400 ]; do echo "# long-generator-line-$i-padding-padding-padding"; i=$((i+1)); done
GEN
  cat > "$work/bin/genshort" <<'GEN'
#!/bin/sh
i=0; while [ $i -lt 400 ]; do echo "# short-$i"; i=$((i+1)); done
GEN
  chmod +x "$work/bin/genlong" "$work/bin/genshort"

  render_template "$SOURCE_ROOT/dot_zshrc.tmpl" > "$work/zshrc.rendered"
  sed -n '/^cached_init() {/,/^}/p' "$work/zshrc.rendered" > "$work/cached_init.zsh"
  [[ -s "$work/cached_init.zsh" ]] || fail "cached_init not found in the rendered .zshrc"

  cat > "$work/probe.zsh" <<PROBE
export PATH="$work/bin:\$PATH"
_zsh_cache_dir="$work/cache"
source "$work/cached_init.zsh"
corrupt=0
for i in {1..15}; do
  rm -f "\$_zsh_cache_dir/probe.zsh"
  ( cached_init probe genlong genlong >/dev/null 2>&1 ) &
  ( cached_init probe genshort genshort >/dev/null 2>&1 ) &
  wait
  cache="\$_zsh_cache_dir/probe.zsh"
  lines=\$(wc -l < "\$cache")
  if [[ \$lines -ne 400 ]]; then
    corrupt=\$((corrupt+1))
    echo "round \$i: \$lines lines, expected 400"
  elif grep -q "long-generator" "\$cache" && grep -q "# short-" "\$cache"; then
    corrupt=\$((corrupt+1))
    echo "round \$i: output of both generators spliced into one file"
  fi
done
exit \$corrupt
PROBE

  run zsh "$work/probe.zsh"
  assert_success
}

# ===========================================
# opencode.json.tmpl
# ===========================================

function test_templates_011_opencode_json_tmpl_renders_valid_json() {
  _bats_test_init 11 'opencode.json.tmpl renders valid JSON'
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$SOURCE_ROOT/private_dot_config/opencode/opencode.json.tmpl" > "$BATS_TEST_TMPFILE"
  run python3 -m json.tool "$BATS_TEST_TMPFILE"
  assert_success
}

function test_templates_012_opencode_json_tmpl_grants_unbounded_external_dir() {
  _bats_test_init 12 'opencode.json.tmpl grants unbounded external-directory reads without changing integrations'
  command_exists jq || skip "jq is required"
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$SOURCE_ROOT/private_dot_config/opencode/opencode.json.tmpl" > "$BATS_TEST_TMPFILE"

  run jq -r '.permission.external_directory["*"]' "$BATS_TEST_TMPFILE"
  assert_success
  assert_output "allow"

  run jq -r '[.mcp.fff.command[0], (.mcp.executor.command | join(" ")), .mcp.executor.enabled, (.provider.openrouter.models | has("qwen/qwen3-coder:free")), .plugin[0]] | @tsv' "$BATS_TEST_TMPFILE"
  assert_success
  # `executor mcp` speaks stdio, so OpenCode never holds the daemon's rotating token.
  assert_output $'fff-mcp\texecutor mcp\ttrue\ttrue\tcompound-engineering@git+https://github.com/EveryInc/compound-engineering-plugin.git'
}

function test_templates_013_opencode_skill_symlinks_target_canonical_claude() {
  _bats_test_init 13 'opencode skill symlinks target canonical claude skills'
  local skill

  for skill in ask-in-herdr markdown-new plan-explainer vector-prime work-summary writing-for-agents; do
    run render_template "$SOURCE_ROOT/private_dot_config/opencode/skills/symlink_${skill}.tmpl"
    assert_success
    assert_output "$HOME/.claude/skills/$skill"
  done
}

function test_templates_014_opencode_instructions_point_at_the_shared_writin() {
  _bats_test_init 14 'opencode instructions point at the shared writing-style file'
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$SOURCE_ROOT/private_dot_config/opencode/opencode.json.tmpl" > "$BATS_TEST_TMPFILE"
  run jq -e '.instructions | index("~/.config/agents/writing-style.md") != null' "$BATS_TEST_TMPFILE"
  assert_success
}

# ===========================================
# private_settings.json.tmpl (Claude Code settings)
# ===========================================

function test_templates_015_private_settings_json_tmpl_renders_valid_json() {
  _bats_test_init 15 'private_settings.json.tmpl renders valid JSON'
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$SOURCE_ROOT/private_dot_claude/private_settings.json.tmpl" > "$BATS_TEST_TMPFILE"
  run python3 -m json.tool "$BATS_TEST_TMPFILE"
  assert_success
}

# ===========================================
# Yazi plugin keymaps
# ===========================================

function test_templates_016_every_yazi_plugin_keymap_has_a_managed_plugin_en() {
  _bats_test_init 16 'every Yazi plugin keymap has a managed plugin entrypoint'
  local yazi_dir="$SOURCE_ROOT/private_dot_config/yazi"
  local plugin
  local plugins
  plugins="$(grep -o 'run = "plugin [^"]*"' "$yazi_dir/keymap.toml" \
    | sed 's/run = "plugin //; s/"$//' \
    | sort -u)"

  [[ -n "$plugins" ]] || fail "no Yazi plugin keymaps found"
  for plugin in $plugins; do
    assert_file_exists "$yazi_dir/plugins/$plugin.yazi/main.lua"
  done
}

# ===========================================
# .chezmoiremove
# ===========================================

function test_templates_017_chezmoiremove_entries_are_absent_from_the_source() {
  _bats_test_init 17 '.chezmoiremove entries are absent from the source tree'
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

function test_templates_018_chezmoiremove_deletes_the_retired_opencode_force() {
  _bats_test_init 18 '.chezmoiremove deletes the retired opencode forced theme'
  # smoke_test.sh asserts the live file is gone; this entry is what makes
  # `chezmoi apply` delete it on machines that deployed the old theme.
  run grep -qx '.config/opencode/themes/flexoki-light-forced.json' \
    "$SOURCE_ROOT/.chezmoiremove"
  assert_success
}

# ===========================================
# CI-minimal Brewfile render guard
# private_dot_config/brewfiles/Brewfile.tmpl
# private_dot_config/brewfiles/empty_Brewfile.macos.tmpl
#
# The guard is driven by the chezmoi data key `ci_minimal`, which
# .chezmoi.yaml.tmpl reads from the MMS_CI_MINIMAL environment variable. It
# binds at `chezmoi init`, not at apply, so each mode needs its own config —
# hence write_test_config()/render_with_config() rather than render_template().
#
# These are the fast gate: a broken guard must fail here, before any package
# installs, rather than during the apply step minutes later.
# ===========================================

BREWFILE_TMPL="private_dot_config/brewfiles/Brewfile.tmpl"
BREWFILE_MACOS_TMPL="private_dot_config/brewfiles/empty_Brewfile.macos.tmpl"

# The entries the suite actually needs from the brew prefix: jq directly, node
# for the sqlite3 that gates seven tests, and bun because the macOS job's
# setup-bun step runs after the apply.
#
# git was on that list and is not any more. The deployed .gitconfig sets
# merge.conflictStyle = zdiff3, which needs git >= 2.35, and Ubuntu 22.04's apt
# git was 2.34.1 — so Homebrew's git was the only one that could read the config
# inside the image. docker/Dockerfile.ubuntu now builds on 24.04, whose apt git
# is 2.43.0, so the claim no longer holds. It is refuted below rather than left
# unasserted, or a later fold-back passes silently.
#
# Every other entry is here because removing it broke something observable.
# Anything added without that evidence is install time the CI runs pay for
# nothing — the point of the guard is that this list stays honest.
assert_minimal_brewfile() {
  assert_line 'tap "oven-sh/bun", trusted: true'
  assert_line 'brew "node"'
  assert_line --partial 'brew "oven-sh/bun/bun"'
  assert_line 'brew "jq"'
  assert_line 'brew "gitleaks"'

  refute_line 'brew "git"'
  # rgrc stays out of the minimal set: no test references it, and the shell
  # init in dot_zshrc.tmpl is guarded by `has rgrc`.
  refute_line 'brew "lazywalker/tap/rgrc"'
  refute_line 'brew "ffmpeg"'
  refute_line 'brew "poppler"'
  refute_line 'brew "imagemagick"'
  refute_line 'brew "shellcheck"'
  refute_line 'brew "herdr"'
  refute_line 'brew "fzf"'
  refute_line 'brew "bats-core"'
}

function test_templates_019_mms_ci_minimal_1_renders_only_the_entries_the_te() {
  _bats_test_init 19 'MMS_CI_MINIMAL=1 renders only the entries the test suite resolves from brew'
  local cfg="$BATS_TEST_TMPDIR/minimal.yaml"
  MMS_CI_MINIMAL=1 write_test_config "$cfg"

  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_TMPL"
  assert_success
  assert_minimal_brewfile
}

function test_templates_020_mms_ci_minimal_1_renders_brewfile_macos_with_no() {
  _bats_test_init 20 'MMS_CI_MINIMAL=1 renders Brewfile.macos with no cask and no formula'
  local cfg="$BATS_TEST_TMPDIR/minimal.yaml"
  MMS_CI_MINIMAL=1 write_test_config "$cfg"

  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_MACOS_TMPL"
  assert_success
  # No test in tests/ references any cask, or elio/terminal-notifier/linear,
  # so the guard covers the whole file. `brew bundle` accepts empty.
  refute_output --partial 'cask "'
  refute_output --partial 'brew "'
  refute_output --partial 'tap "'
}

function test_templates_021_an_unset_mms_ci_minimal_renders_the_full_brewfil() {
  _bats_test_init 21 'an unset MMS_CI_MINIMAL renders the full Brewfiles'
  local cfg="$BATS_TEST_TMPDIR/full-unset.yaml"
  unset MMS_CI_MINIMAL
  write_test_config "$cfg"

  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_TMPL"
  assert_success
  assert_line 'brew "ffmpeg"'
  assert_line 'brew "shellcheck"'
  assert_line 'brew "jq"'
  # git and rgrc are refuted in the minimal render, so they need pinning here
  # too, or deleting either from the template outright would satisfy every
  # assertion in this file while real hosts silently stop getting it.
  assert_line 'brew "git"'
  assert_line --partial 'brew "lazywalker/tap/rgrc"'

  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_MACOS_TMPL"
  assert_success
  assert_line 'cask "spotify"'
  assert_line --partial 'brew "elio"'
}

function test_templates_022_an_empty_mms_ci_minimal_renders_the_full_brewfil() {
  _bats_test_init 22 'an empty MMS_CI_MINIMAL renders the full Brewfiles'
  # This is the state the scheduled and workflow_dispatch runs produce: the
  # workflow-level expression yields '' for every event that is not push or
  # pull_request, so empty must mean full, not minimal.
  local cfg="$BATS_TEST_TMPDIR/full-empty.yaml"
  MMS_CI_MINIMAL="" write_test_config "$cfg"

  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_TMPL"
  assert_success
  assert_line 'brew "ffmpeg"'
  assert_line 'brew "git"'

  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_MACOS_TMPL"
  assert_success
  assert_line 'cask "spotify"'
}

function test_templates_023_mms_ci_minimal_0_selects_the_minimal_render_beca() {
  _bats_test_init 23 'MMS_CI_MINIMAL=0 selects the minimal render, because 0 is non-empty'
  local cfg="$BATS_TEST_TMPDIR/zero.yaml"
  MMS_CI_MINIMAL=0 write_test_config "$cfg"

  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_TMPL"
  assert_success
  assert_minimal_brewfile
}

function test_templates_024_a_config_with_no_ci_minimal_key_at_all_renders_t() {
  _bats_test_init 24 'a config with no ci_minimal key at all renders the full Brewfiles'
  # A host whose config was generated before this key existed. chezmoi's
  # default missingkey=error would abort on a bare .ci_minimal reference, so
  # the templates use `get`, which yields "" for a missing key.
  local cfg="$BATS_TEST_TMPDIR/legacy.yaml"
  unset MMS_CI_MINIMAL
  write_test_config "$cfg"
  sed -i.bak '/ci_minimal/d' "$cfg"
  run grep -c 'ci_minimal' "$cfg"
  assert_output "0"

  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_TMPL"
  assert_success
  assert_line 'brew "ffmpeg"'

  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_MACOS_TMPL"
  assert_success
  assert_line 'cask "spotify"'
}

function test_templates_025_a_config_initialised_with_mms_ci_minimal_1_keeps() {
  _bats_test_init 25 'a config initialised with MMS_CI_MINIMAL=1 keeps rendering minimal without it'
  # The binding is init-time, so a checkout initialised in CI-minimal mode stays
  # minimal on every later apply, even with the variable gone from the
  # environment. Intended, but surprising enough to pin: this is what a
  # contributor hits after reproducing the CI path locally. The recovery is
  # re-running `chezmoi init` without the variable.
  local cfg="$BATS_TEST_TMPDIR/sticky.yaml"
  MMS_CI_MINIMAL=1 write_test_config "$cfg"

  unset MMS_CI_MINIMAL
  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_TMPL"
  assert_success
  assert_minimal_brewfile
}

function test_templates_026_no_rendered_brew_cask_or_tap_entry_is_indented_i() {
  _bats_test_init 26 'no rendered brew, cask or tap entry is indented in either mode'
  # Go template `{{ if }}` blocks do not indent their body, but a hand-indented
  # entry would still render indented, and `brew bundle` would keep working — so
  # without this nothing goes red.
  #
  local mode cfg tmpl out
  for mode in 1 ""; do
    cfg="$BATS_TEST_TMPDIR/indent-$mode.yaml"
    MMS_CI_MINIMAL="$mode" write_test_config "$cfg"
    for tmpl in "$BREWFILE_TMPL" "$BREWFILE_MACOS_TMPL"; do
      out="$(render_with_config "$cfg" "$SOURCE_ROOT/$tmpl")"
      run grep -n '^[[:space:]][[:space:]]*\(brew\|cask\|tap\) ' <<< "$out"
      assert_failure
    done
  done
}

render_with_source() {
  local template_file="$1"
  PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" --source "$SOURCE_ROOT" execute-template < "$template_file"
}

function test_templates_027_every_hash_trigger_include_in_the_install_script() {
  _bats_test_init 27 'every hash-trigger include in the install script resolves to a real file'
  # Derived from the script rather than hardcoded, so it cannot drift from it.
  # `include` errors on a missing path, so a successful render with a real
  # digest is the proof. Checked for both files on every OS: the macOS include
  # sits behind an `eq .chezmoi.os "darwin"` guard, so rendering the script
  # itself on Linux would skip it and miss a stale path there.
  local script="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl"
  local probe="$BATS_TEST_TMPDIR/include-probe.tmpl"
  local paths path
  paths="$(grep -o 'include "[^"]*"' "$script" | sed 's/^include "//; s/"$//')"
  [[ -n "$paths" ]] || fail "no include directives found in $script"

  while IFS= read -r path; do
    printf '{{ include "%s" | sha256sum }}' "$path" > "$probe"
    run render_with_source "$probe"
    assert_success
    assert_output --regexp '^[0-9a-f]{64}$'
  done <<< "$paths"
}

function test_templates_028_the_minimal_render_deploys_brewfile_macos_empty() {
  _bats_test_init 28 'the minimal render deploys Brewfile.macos empty rather than not at all'
  # This is the gap that let a green suite ship a broken apply. Every other test
  # in this section checks what `chezmoi execute-template` prints, and for the
  # minimal macOS render that is correctly nothing. What rendering cannot show is
  # that chezmoi *deletes* a file whose template renders to zero bytes, unless the
  # source name carries the `empty_` attribute. Without it the deployed
  # ~/.config/brewfiles/Brewfile.macos never appeared, and the apply died on the
  # next line of run_onchange_after_1 with "No Brewfile found" — on macOS only,
  # because Brewfile.macos is brew-bundled solely under darwin.
  #
  # So this one applies for real. It is safe and stays within the repo's rule
  # against applying on a host: the apply is scoped to .config/brewfiles, which
  # contains no run_ scripts, and --destination points at a throwaway directory,
  # so $HOME is never a target.
  local cfg="$BATS_TEST_TMPDIR/deploy.yaml"
  local dest="$BATS_TEST_TMPDIR/dest"
  MMS_CI_MINIMAL=1 write_test_config "$cfg"
  # chezmoi does not create ancestor directories for a scoped apply.
  mkdir -p "$dest/.config"

  run env PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" apply \
    --source "$SOURCE_ROOT" --destination "$dest" --config "$cfg" \
    "$dest/.config/brewfiles"
  assert_success

  assert_file_exists "$dest/.config/brewfiles/Brewfile"
  assert_file_exists "$dest/.config/brewfiles/Brewfile.macos"
  # Empty is the intended state — the entries are guarded out, the file remains.
  [[ ! -s "$dest/.config/brewfiles/Brewfile.macos" ]] \
    || fail "Brewfile.macos should be empty in minimal mode"
  assert_file_contains "$dest/.config/brewfiles/Brewfile" '^brew "jq"'
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function tear_down() { _bats_run_teardown; }

