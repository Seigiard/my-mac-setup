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
# zsh init-cache generation (concurrency safety)
#
# Several shells can start at once — a terminal restoring its panes, or a
# multiplexer opening a tab. Each one regenerates a stale cache. Writing the
# cache path directly with `>` lets one shell's tail survive past the end of
# another shell's shorter output, leaving a spliced file that the next shell
# sources. That is how ~/.cache/zsh/mise-activate.zsh grew five orphan lines
# and every new shell printed "zsh: command not found: ".
# ===========================================

@test "zshenv generates the mise cache through a temp file rename" {
  run render_template "$SOURCE_ROOT/dot_zshenv.tmpl"
  assert_success
  assert_output --partial 'mv -f "$_mise_cache_tmp" "$_mise_cache"'
  refute_output --partial 'mise activate zsh > "$_mise_cache"'
}

@test "zshrc cached_init generates the cache through a temp file rename" {
  run render_template "$SOURCE_ROOT/dot_zshrc.tmpl"
  assert_success
  assert_output --partial 'mv -f "$tmp" "$cache"'
  refute_output --partial '"$@" > "$cache"'
}

@test "zshrc cached_init never splices two concurrent generators" {
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

@test ".chezmoiremove deletes the retired opencode forced theme" {
  # smoke.bats asserts the live file is gone; this entry is what makes
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

# The entries the suite actually needs from the brew prefix: jq directly, grc
# for the python3 that gates all of palette.bats, node for the sqlite3 that
# gates seven tests, bun because the macOS job's setup-bun step runs after the
# apply, and git because the deployed .gitconfig sets merge.conflictStyle =
# zdiff3, which apt's git 2.34.1 rejects outright.
#
# Every one of these is here because removing it broke something observable.
# Anything added without that evidence is install time the CI runs pay for
# nothing — the point of the guard is that this list stays honest.
assert_minimal_brewfile() {
  assert_line 'tap "oven-sh/bun", trusted: true'
  assert_line --partial 'brew "grc"'
  assert_line 'brew "git"'
  assert_line 'brew "node"'
  assert_line --partial 'brew "oven-sh/bun/bun"'
  assert_line 'brew "jq"'

  refute_line 'brew "ffmpeg"'
  refute_line 'brew "poppler"'
  refute_line 'brew "imagemagick"'
  refute_line 'brew "shellcheck"'
  refute_line 'brew "herdr"'
  refute_line 'brew "fzf"'
  refute_line 'brew "bats-core"'
}

@test "MMS_CI_MINIMAL=1 renders only the entries the test suite resolves from brew" {
  local cfg="$BATS_TEST_TMPDIR/minimal.yaml"
  MMS_CI_MINIMAL=1 write_test_config "$cfg"

  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_TMPL"
  assert_success
  assert_minimal_brewfile
}

@test "MMS_CI_MINIMAL=1 renders Brewfile.macos with no cask and no formula" {
  local cfg="$BATS_TEST_TMPDIR/minimal.yaml"
  MMS_CI_MINIMAL=1 write_test_config "$cfg"

  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_MACOS_TMPL"
  assert_success
  # No test in tests/ references any cask, or elio/rgrc/terminal-notifier/
  # linear, so the guard covers the whole file. `brew bundle` accepts empty.
  refute_output --partial 'cask "'
  refute_output --partial 'brew "'
  refute_output --partial 'tap "'
}

@test "an unset MMS_CI_MINIMAL renders the full Brewfiles" {
  local cfg="$BATS_TEST_TMPDIR/full-unset.yaml"
  unset MMS_CI_MINIMAL
  write_test_config "$cfg"

  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_TMPL"
  assert_success
  assert_line 'brew "ffmpeg"'
  assert_line 'brew "shellcheck"'
  assert_line 'brew "jq"'

  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_MACOS_TMPL"
  assert_success
  assert_line 'cask "spotify"'
  assert_line --partial 'brew "elio"'
}

@test "an empty MMS_CI_MINIMAL renders the full Brewfiles" {
  # This is the state the scheduled and workflow_dispatch runs produce: the
  # workflow-level expression yields '' for every event that is not push or
  # pull_request, so empty must mean full, not minimal.
  local cfg="$BATS_TEST_TMPDIR/full-empty.yaml"
  MMS_CI_MINIMAL="" write_test_config "$cfg"

  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_TMPL"
  assert_success
  assert_line 'brew "ffmpeg"'

  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_MACOS_TMPL"
  assert_success
  assert_line 'cask "spotify"'
}

@test "MMS_CI_MINIMAL=0 selects the minimal render, because 0 is non-empty" {
  # The flag is emptiness-tested, not parsed. Reading '0' as "off" is wrong,
  # and this pins which reading the implementation actually has.
  local cfg="$BATS_TEST_TMPDIR/zero.yaml"
  MMS_CI_MINIMAL=0 write_test_config "$cfg"

  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_TMPL"
  assert_success
  assert_minimal_brewfile
}

@test "a config with no ci_minimal key at all renders the full Brewfiles" {
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

@test "a config initialised with MMS_CI_MINIMAL=1 keeps rendering minimal without it" {
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

@test "no rendered brew, cask or tap entry is indented in either mode" {
  # Go template `{{ if }}` blocks do not indent their body, but a hand-indented
  # entry would still render indented, and `brew bundle` would keep working — so
  # without this nothing goes red.
  #
  # This covers the rendered file only, and that is deliberately half the job.
  # An entry sitting directly after a `-}}` trim marker renders at column zero
  # however it is indented in the source, because the marker eats the leading
  # whitespace. The other half is tests/scripts.bats, which asserts the anchored
  # pattern ^brew "shellcheck" against the template *source*. Verified by
  # mutation: indenting `brew "ffmpeg"` reddens this test, indenting
  # `brew "shellcheck"` reddens that one. Neither test alone catches both.
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

@test "the install script's hash triggers name the renamed .tmpl sources" {
  # `include` reads the chezmoi source path, which keeps the .tmpl suffix; the
  # `brew bundle` calls in the same script read the deployed path, which does
  # not. A stale include here is the documented gotcha: it either breaks the
  # apply or silently stops the script re-running when a Brewfile changes.
  local script="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl"

  run grep -F 'include "private_dot_config/brewfiles/Brewfile.tmpl"' "$script"
  assert_success
  run grep -F 'include "private_dot_config/brewfiles/empty_Brewfile.macos.tmpl"' "$script"
  assert_success

  # The deployed paths in the same file must NOT gain the suffix.
  run grep -F 'brew bundle --file="$BREWFILES_DIR/Brewfile"' "$script"
  assert_success
  run grep -F 'brew bundle --file="$BREWFILES_DIR/Brewfile.macos"' "$script"
  assert_success
}

@test "every hash-trigger include in the install script resolves to a real file" {
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

@test "the minimal render deploys Brewfile.macos empty rather than not at all" {
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
