#!/usr/bin/env bash
# post-apply: excluded
# templates post-apply suite — bashunit source. Vocabulary (run, assert_*,
# skip, BATS_* contract) comes from tests/bashunit/test-dsl.bash.
# Migrated from templates.bats; parity evidence: docs/benchmarks/bashunit-full-suite-experiment.md.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"


load 'helpers/common'

setup() {
  skip_if_no_chezmoi
  # Unset, write_test_config()'s `execute-template --init` render would fall
  # through to promptStringOnce, which execute-template cannot prompt for.
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
  run assert_python3_available
  assert_success
}

# ===========================================
# .chezmoi.yaml.tmpl
# ===========================================

# CHEZMOI_NAME/CHEZMOI_EMAIL bind at `chezmoi init`, not at render time, so
# the setup() exports above are inert here — each value needs its own
# init-time config. The second render is the control against ambient host
# state.
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

function test_templates_032_chezmoi_init_binds_and_persists_the_machine_role() {
  _bats_test_init 32 'chezmoi init binds and persists the machine role'
  local cfg="$BATS_TEST_TMPDIR/machine-role.yaml"
  local probe="$BATS_TEST_TMPDIR/machine-role.tmpl"
  local role
  printf '{{ get . "machine_role" }}' > "$probe"

  case "$(get_os)" in
    darwin) role="mbp2026" ;;
    linux) role="server" ;;
    *) skip "unsupported test OS" ;;
  esac

  MMS_MACHINE_ROLE="$role" write_test_config "$cfg"
  export MMS_MACHINE_ROLE="invalid-after-init"

  run render_with_config "$cfg" "$probe"
  assert_success
  assert_output "$role"
}

function test_templates_033_unattended_init_requires_a_machine_role() {
  _bats_test_init 33 'unattended init requires a machine role'
  export MMS_MACHINE_ROLE=""

  run write_test_config "$BATS_TEST_TMPDIR/missing-machine-role.yaml"
  assert_failure
  assert_output --partial 'MMS_MACHINE_ROLE'
  assert_output --partial 'mbp2021, mbp2026, or server'
}

function test_templates_034_chezmoi_init_rejects_an_unknown_machine_role() {
  _bats_test_init 34 'chezmoi init rejects an unknown machine role'
  export MMS_MACHINE_ROLE="workstation"

  run write_test_config "$BATS_TEST_TMPDIR/unknown-machine-role.yaml"
  assert_failure
  # The operator has to learn which value was refused and what is accepted
  # instead; a message that names neither leaves them guessing. Partial only
  # because chezmoi wraps the message in its own template-error framing.
  assert_output --partial 'invalid MMS_MACHINE_ROLE "workstation": expected mbp2021, mbp2026, or server'
}

function test_templates_035_chezmoi_init_rejects_a_role_for_the_wrong_os() {
  _bats_test_init 35 'chezmoi init rejects a machine role for the wrong OS'
  # The runner's OS is an environment precondition, so each arm carries the
  # message it must produce literally. Without the role and the OS in the
  # match, a message naming the opposite pair would pass here too.
  local expected
  case "$(get_os)" in
    darwin)
      export MMS_MACHINE_ROLE="server"
      expected='machine role "server" is not supported on darwin'
      ;;
    linux)
      export MMS_MACHINE_ROLE="mbp2026"
      expected='machine role "mbp2026" is not supported on linux'
      ;;
    *) skip "unsupported test OS" ;;
  esac

  run write_test_config "$BATS_TEST_TMPDIR/wrong-os-machine-role.yaml"
  assert_failure
  assert_output --partial "$expected"
}

make_ssh_policy_fixture() {
  local source="$1"
  mkdir -p "$source/.chezmoidata" "$source/.chezmoitemplates" "$source/private_dot_ssh" \
    "$source/private_dot_config/1Password/private_ssh"
  cp "$SOURCE_ROOT/.chezmoiignore" "$source/.chezmoiignore"
  cp "$SOURCE_ROOT/.chezmoidata/ssh.yaml" "$source/.chezmoidata/ssh.yaml"
  cp "$SOURCE_ROOT/.chezmoitemplates/machine-role" "$source/.chezmoitemplates/machine-role"
  cp "$SOURCE_ROOT/.chezmoitemplates/resolve-machine-role.sh" \
    "$source/.chezmoitemplates/resolve-machine-role.sh"
  printf 'managed config\n' > "$source/private_dot_ssh/private_config"
  printf 'managed authorization\n' > "$source/private_dot_ssh/private_authorized_keys"
  printf 'managed mbp2026 public key\n' > "$source/private_dot_ssh/mbp2026.pub"
  printf 'managed mbp2021 public key\n' > "$source/private_dot_ssh/mbp2021.pub"
  printf 'managed agent config\n' \
    > "$source/private_dot_config/1Password/private_ssh/private_agent.toml"
}

plant_ssh_policy_sentinels() {
  local dest="$1"
  mkdir -p "$dest/.ssh" "$dest/.config/1Password/ssh"
  printf 'existing config\n' > "$dest/.ssh/config"
  printf 'existing authorization\n' > "$dest/.ssh/authorized_keys"
  printf 'existing mbp2026 public key\n' > "$dest/.ssh/mbp2026.pub"
  printf 'existing mbp2021 public key\n' > "$dest/.ssh/mbp2021.pub"
  printf 'existing agent config\n' > "$dest/.config/1Password/ssh/agent.toml"
}

assert_ssh_policy_sentinels() {
  local dest="$1"
  assert_file_contains "$dest/.ssh/config" '^existing config$'
  assert_file_contains "$dest/.ssh/authorized_keys" '^existing authorization$'
  assert_file_contains "$dest/.ssh/mbp2026.pub" '^existing mbp2026 public key$'
  assert_file_contains "$dest/.ssh/mbp2021.pub" '^existing mbp2021 public key$'
  assert_file_contains "$dest/.config/1Password/ssh/agent.toml" '^existing agent config$'
}

function test_templates_036_apply_resolves_and_persists_a_missing_machine_role() {
  _bats_test_init 36 'apply resolves and persists a missing machine role'
  local source="$BATS_TEST_TMPDIR/missing-role-source"
  local dest="$BATS_TEST_TMPDIR/missing-role-dest"
  local cfg="$BATS_TEST_TMPDIR/config/chezmoi.yaml"
  local role
  make_ssh_policy_fixture "$source"
  plant_ssh_policy_sentinels "$dest"
  mkdir -p "${cfg%/*}"
  write_test_config "$cfg"
  sed -i.bak '/machine_role/d' "$cfg"

  case "$(get_os)" in
    darwin) role="mbp2026" ;;
    linux) role="server" ;;
    *) skip "unsupported test OS" ;;
  esac
  export MMS_MACHINE_ROLE="$role"

  run chezmoi_full_fixture apply \
    --source "$source" --destination "$dest" --config "$cfg"
  assert_success
  assert_file_contains "${cfg%/*}/machine-role" "^$role$"
  assert_file_contains "$dest/.ssh/config" '^managed config$'
  assert_file_contains "$dest/.ssh/authorized_keys" '^managed authorization$'

  export MMS_MACHINE_ROLE="workstation"
  run chezmoi_full_fixture apply \
    --source "$source" --destination "$dest" --config "$cfg"
  assert_success
  assert_file_contains "${cfg%/*}/machine-role" "^$role$"
}

function test_templates_037_an_invalid_persisted_role_fails_before_ssh_policy_changes() {
  _bats_test_init 37 'an invalid persisted role fails before SSH policy changes'
  local source="$BATS_TEST_TMPDIR/invalid-source"
  local dest="$BATS_TEST_TMPDIR/invalid-dest"
  local cfg="$BATS_TEST_TMPDIR/invalid-role.yaml"
  make_ssh_policy_fixture "$source"
  plant_ssh_policy_sentinels "$dest"
  write_test_config "$cfg"
  sed -i.bak 's/machine_role:.*/machine_role: "workstation"/' "$cfg"

  run chezmoi_full_fixture apply \
    --source "$source" --destination "$dest" --config "$cfg"
  assert_failure
  assert_output --partial 'invalid machine_role'
  assert_ssh_policy_sentinels "$dest"
}

function test_templates_0371_a_wrong_os_persisted_role_fails_before_ssh_policy_changes() {
  _bats_test_init 371 'a persisted role for the wrong OS fails before SSH policy changes'
  local source="$BATS_TEST_TMPDIR/wrong-os-source"
  local dest="$BATS_TEST_TMPDIR/wrong-os-dest"
  local cfg="$BATS_TEST_TMPDIR/wrong-os-role.yaml"
  local role
  make_ssh_policy_fixture "$source"
  plant_ssh_policy_sentinels "$dest"
  write_test_config "$cfg"

  case "$(get_os)" in
    darwin) role="server" ;;
    linux) role="mbp2026" ;;
    *) skip "unsupported test OS" ;;
  esac
  sed -i.bak "s/machine_role:.*/machine_role: \"$role\"/" "$cfg"

  run chezmoi_full_fixture apply \
    --source "$source" --destination "$dest" --config "$cfg"
  assert_failure
  assert_output --partial 'is not supported on'
  assert_ssh_policy_sentinels "$dest"
}

# Applies the SSH policy fixture under a name of its own and leaves the
# rendered destination in SSH_POLICY_DEST. Called directly, never in a command
# substitution, so an assertion failure inside it still ends its caller.
SSH_POLICY_DEST=""
apply_valid_role_ssh_policy() {
  local name="$1"
  local source="$BATS_TEST_TMPDIR/$name-source"
  local cfg="$BATS_TEST_TMPDIR/$name-role.yaml"
  SSH_POLICY_DEST="$BATS_TEST_TMPDIR/$name-dest"
  make_ssh_policy_fixture "$source"
  plant_ssh_policy_sentinels "$SSH_POLICY_DEST"
  write_test_config "$cfg"

  run chezmoi_full_fixture apply \
    --source "$source" --destination "$SSH_POLICY_DEST" --config "$cfg"
  assert_success
}

function test_templates_038_a_valid_role_manages_its_ssh_policy_files() {
  _bats_test_init 38 'a valid role manages its SSH policy files'
  apply_valid_role_ssh_policy valid

  assert_file_contains "$SSH_POLICY_DEST/.ssh/config" '^managed config$'
  assert_file_contains "$SSH_POLICY_DEST/.ssh/authorized_keys" '^managed authorization$'
  assert_file_contains "$SSH_POLICY_DEST/.ssh/mbp2026.pub" '^managed mbp2026 public key$'
  assert_file_contains "$SSH_POLICY_DEST/.ssh/mbp2021.pub" '^managed mbp2021 public key$'
}

# The 1Password agent config is the one file in this fixture whose verdict
# depends on the host, because write_test_config binds the role the host can
# carry: mbp2026 on darwin, which uses the local agent, and server on linux,
# which .chezmoiignore keeps out of the render. Both expectations behind one
# `if is_macos` passed on either host whatever the ignore rules said. One test
# per role keeps a single assertion path, and the named skip makes a run that
# never reached the other one say so instead of reporting it as covered.
function test_templates_0381_a_valid_role_deploys_the_1password_agent_config() {
  _bats_test_init 381 'the mbp2026 role deploys the 1Password agent config'
  is_macos || skip "only darwin binds a role (mbp2026) that uses the local 1Password SSH agent"
  apply_valid_role_ssh_policy agent-used

  assert_file_contains "$SSH_POLICY_DEST/.config/1Password/ssh/agent.toml" '^managed agent config$'
}

function test_templates_0382_the_server_role_leaves_the_1password_agent_config_alone() {
  _bats_test_init 382 'the server role leaves an existing 1Password agent config alone'
  is_linux || skip "only linux binds the server role, the one that does not use the local 1Password SSH agent"
  apply_valid_role_ssh_policy agent-unused

  assert_file_contains "$SSH_POLICY_DEST/.config/1Password/ssh/agent.toml" '^existing agent config$'
}

write_role_config() {
  local role="$1"
  local cfg="$2"
  write_test_config "$cfg"
  sed -i.bak "s/machine_role:.*/machine_role: \"$role\"/" "$cfg"
}

render_role_file() {
  local role="$1"
  local template="$2"
  local output_file="$3"
  local cfg="$BATS_TEST_TMPDIR/$role.yaml"
  write_role_config "$role" "$cfg"
  run render_with_config "$cfg" "$template"
  assert_success
  printf '%s\n' "$output" > "$output_file"
}

function test_templates_039_laptop_public_keys_match_the_1password_items() {
  _bats_test_init 39 'laptop public keys match the 1Password items'
  command_exists ssh-keygen || skip "ssh-keygen not installed"

  run ssh-keygen -lf "$SOURCE_ROOT/private_dot_ssh/mbp2026.pub"
  assert_success
  assert_output --partial 'SHA256:i1+gX+0ai2jgE0ovOq6lxX59NwDqoUrLS8KizkWpA2Y'

  run ssh-keygen -lf "$SOURCE_ROOT/private_dot_ssh/mbp2021.pub"
  assert_success
  assert_output --partial 'SHA256:EHMTK4CF46qEsk/z2atgPgQdsXThJX55V7J+/lPLUNY'
}

function test_templates_040_laptop_ssh_configs_select_one_1password_identity() {
  _bats_test_init 40 'laptop SSH configs select one 1Password identity'
  command_exists ssh || skip "ssh not installed"
  local role config target expected_host expected_user expected_key

  for role in mbp2026 mbp2021; do
    config="$BATS_TEST_TMPDIR/$role-ssh-config"
    if [[ "$role" == "mbp2026" ]]; then
      target="mbp2021"
      expected_host="mbp2021.tailc9825c.ts.net"
      expected_user="seigiard"
      expected_key="mbp2026.pub"
    else
      target="mbp2026"
      expected_host="mbp2026.tailc9825c.ts.net"
      expected_user="andrew.b"
      expected_key="mbp2021.pub"
    fi
    render_role_file "$role" "$SOURCE_ROOT/private_dot_ssh/private_config.tmpl" "$config"

    run ssh -G -F "$config" "$target"
    assert_success
    assert_line "hostname $expected_host"
    assert_line "user $expected_user"
    assert_line "identityfile ~/.ssh/$expected_key"
    assert_line 'identitiesonly yes'
    assert_line 'forwardagent no'
    assert_line "identityagent $HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

    run ssh -G -F "$config" server
    assert_success
    assert_line 'hostname home.tailc9825c.ts.net'
    assert_line 'user seigiard'
    assert_line "identityfile ~/.ssh/$expected_key"
    assert_line 'identitiesonly yes'
    assert_line 'forwardagent no'
  done
}

function test_templates_041_server_ssh_config_uses_only_a_forwarded_agent() {
  _bats_test_init 41 'server SSH config uses only a forwarded agent'
  command_exists ssh || skip "ssh not installed"
  local config="$BATS_TEST_TMPDIR/server-ssh-config"
  render_role_file server "$SOURCE_ROOT/private_dot_ssh/private_config.tmpl" "$config"

  run ssh -G -F "$config" github.com
  assert_success
  assert_line 'identityfile none'
  assert_line 'identitiesonly no'
  assert_line 'forwardagent no'
  refute_line --regexp '^identityagent '
}

function test_templates_042_authorized_keys_render_the_required_access_matrix() {
  _bats_test_init 42 'authorized_keys render the required access matrix'
  command_exists ssh-keygen || skip "ssh-keygen not installed"
  local role keys

  for role in mbp2026 mbp2021 server; do
    keys="$BATS_TEST_TMPDIR/$role-authorized-keys"
    render_role_file "$role" \
      "$SOURCE_ROOT/private_dot_ssh/private_authorized_keys.tmpl" "$keys"

    run ssh-keygen -lf "$keys"
    assert_success
    case "$role" in
      mbp2026)
        assert_output --partial 'SHA256:EHMTK4CF46qEsk/z2atgPgQdsXThJX55V7J+/lPLUNY'
        refute_output --partial 'SHA256:i1+gX+0ai2jgE0ovOq6lxX59NwDqoUrLS8KizkWpA2Y'
        ;;
      mbp2021)
        assert_output --partial 'SHA256:i1+gX+0ai2jgE0ovOq6lxX59NwDqoUrLS8KizkWpA2Y'
        refute_output --partial 'SHA256:EHMTK4CF46qEsk/z2atgPgQdsXThJX55V7J+/lPLUNY'
        ;;
      server)
        assert_output --partial 'SHA256:i1+gX+0ai2jgE0ovOq6lxX59NwDqoUrLS8KizkWpA2Y'
        assert_output --partial 'SHA256:EHMTK4CF46qEsk/z2atgPgQdsXThJX55V7J+/lPLUNY'
        ;;
    esac
  done
}

function test_templates_0421_authorized_keys_reject_an_empty_role_allowlist() {
  _bats_test_init 421 'authorized_keys rejects an empty role allowlist'
  local source="$BATS_TEST_TMPDIR/empty-authorized-keys-source"
  local cfg="$BATS_TEST_TMPDIR/empty-authorized-keys.yaml"
  local role data template
  mkdir -p "$source/.chezmoidata" "$source/.chezmoitemplates" "$source/private_dot_ssh"
  data="$source/.chezmoidata/ssh.yaml"
  template="$source/private_dot_ssh/private_authorized_keys.tmpl"
  cp "$SOURCE_ROOT/.chezmoidata/ssh.yaml" "$data"
  cp "$SOURCE_ROOT/.chezmoitemplates/machine-role" "$source/.chezmoitemplates/machine-role"
  cp "$SOURCE_ROOT/.chezmoitemplates/resolve-machine-role.sh" \
    "$source/.chezmoitemplates/resolve-machine-role.sh"
  cp "$SOURCE_ROOT/private_dot_ssh/private_authorized_keys.tmpl" "$template"

  case "$(get_os)" in
    darwin) role="mbp2026" ;;
    linux) role="server" ;;
    *) skip "unsupported test OS" ;;
  esac
  write_role_config "$role" "$cfg"
  python3 -c '
import sys

path, role = sys.argv[1:]
lines = open(path).readlines()
in_role = False
skip_keys = False
with open(path, "w") as output:
    for line in lines:
        if line.startswith("    ") and not line.startswith("      "):
            in_role = line == "    %s:\n" % role
            skip_keys = False
        if in_role and line == "      authorized_keys:\n":
            output.write("      authorized_keys: []\n")
            skip_keys = True
            continue
        if skip_keys and line.startswith("        - "):
            continue
        skip_keys = False
        output.write(line)
' "$data" "$role"

  run chezmoi_full_fixture --config "$cfg" --source "$source" \
    execute-template --file "$template"
  assert_failure
  assert_output --partial 'has no authorized keys'
}

function test_templates_043_1password_agent_allowlists_only_the_role_key() {
  _bats_test_init 43 '1Password agent allowlists only the role key'
  local config="$SOURCE_ROOT/private_dot_config/1Password/private_ssh/private_agent.toml.tmpl"
  local rendered

  render_role_file mbp2026 "$config" "$BATS_TEST_TMPDIR/mbp2026-agent.toml"
  rendered="$(< "$BATS_TEST_TMPDIR/mbp2026-agent.toml")"
  run printf '%s\n' "$rendered"
  assert_line 'item = "xew24lnqepklck6mqik5lmirqi"'
  refute_output --partial 'ppztkbmrt3oo6xsm6ctlhia7ta'

  render_role_file mbp2021 "$config" "$BATS_TEST_TMPDIR/mbp2021-agent.toml"
  rendered="$(< "$BATS_TEST_TMPDIR/mbp2021-agent.toml")"
  run printf '%s\n' "$rendered"
  assert_line 'item = "ppztkbmrt3oo6xsm6ctlhia7ta"'
  refute_output --partial 'xew24lnqepklck6mqik5lmirqi'
}

# ===========================================
# dot_gitconfig.tmpl
# ===========================================

# "name = " / "email = " are unconditional boilerplate in the template;
# asserting them proves nothing about substitution — hence the probe values.
function test_templates_005_gitconfig_renders_the_config_name_into_user_name() {
  _bats_test_init 5 'gitconfig renders the config name into user.name'
  local cfg="$BATS_TEST_TMPDIR/gitconfig-name.yaml"
  CHEZMOI_NAME="Gitconfig Name Probe" write_test_config "$cfg"

  run render_with_config "$cfg" "$SOURCE_ROOT/dot_gitconfig.tmpl"
  assert_success
  assert_output --partial "name = Gitconfig Name Probe"
  refute_output --partial '{{'
}

function test_templates_006_gitconfig_renders_the_config_email_into_user_ema() {
  _bats_test_init 6 'gitconfig renders the config email into user.email'
  local cfg="$BATS_TEST_TMPDIR/gitconfig-email.yaml"
  CHEZMOI_EMAIL="gitconfig-probe@env.example" write_test_config "$cfg"

  run render_with_config "$cfg" "$SOURCE_ROOT/dot_gitconfig.tmpl"
  assert_success
  assert_output --partial "email = gitconfig-probe@env.example"
  refute_output --partial '{{'
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

function test_templates_0091_zshenv_full_fixture_exports_all_canaries_without_op() {
  _bats_test_init 91 'zshenv full fixture randomly selects a Tavily canary without invoking op'
  command_exists zsh || skip "zsh not installed"
  local work="$BATS_TEST_TMPDIR/zshenv-full"
  local launcher="$BATS_TEST_DIRNAME/helpers/chezmoi-unattended"
  local cfg="$work/chezmoi.yaml"
  mkdir -p "$work/bin" "$work/home"
  write_test_config "$cfg"
  cat > "$work/bin/op" <<'FAKE_OP'
#!/bin/sh
printf launched > "$FAKE_OP_MARKER"
exit 99
FAKE_OP
  chmod +x "$work/bin/op"

  run env \
    HOME="$work/home" \
    PATH="$work/bin:$PATH" \
    FAKE_OP_MARKER="$work/op-launched" \
    MMS_CHEZMOI_UNATTENDED=1 \
    MMS_DISPOSABLE_HOME=1 \
    MMS_CHEZMOI_FIXTURE_LINEAR_API_KEY=linear-zshenv-canary \
    MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY=tavily-zshenv-canary \
    MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY_2=tavily-2-zshenv-canary \
    MMS_CHEZMOI_FIXTURE_JINA_API_KEY=jina-zshenv-canary \
    MMS_CHEZMOI_FIXTURE_CONTEXT7_API_KEY=context7-zshenv-canary \
    MMS_CHEZMOI_FIXTURE_VECTOR_PRIME_API_KEY=vector-zshenv-canary \
    MMS_CHEZMOI_FIXTURE_OPENROUTER_API_KEY=openrouter-zshenv-canary \
    MMS_CHEZMOI_FIXTURE_POSTHOG_PERSONAL_API_KEY=posthog-zshenv-canary \
    MMS_CHEZMOI_FIXTURE_VRT_R2_ACCESS_KEY_ID=vrt-r2-access-key-zshenv-canary \
    MMS_CHEZMOI_FIXTURE_VRT_R2_SECRET_ACCESS_KEY=vrt-r2-secret-key-zshenv-canary \
    "$launcher" --profile full-fixture -- \
    apply --source "$SOURCE_ROOT" --destination "$work/home" --config "$cfg" \
    --refresh-externals=never "$work/home/.zshenv"
  assert_success
  assert_file_exists "$work/home/.zshenv"
  run grep -F '{{' "$work/home/.zshenv"
  assert_failure
  # oracle: fake op creates this marker only if template rendering launches it.
  assert_file_not_exists "$work/op-launched"

  run env HOME="$work/home" PATH="/usr/bin:/bin" zsh -f -c '
    RANDOM=2
    source "$1"
    print -r -- "$LINEAR_API_KEY|$TAVILY_API_KEY|$JINA_API_KEY|$CONTEXT7_API_KEY|$VECTOR_PRIME_API_KEY|$OPENROUTER_API_KEY|$POSTHOG_PERSONAL_API_KEY|$VRT_R2_ACCESS_KEY_ID|$VRT_R2_SECRET_ACCESS_KEY|$VRT_R2_BUCKET|$VRT_R2_ENDPOINT|$VRT_R2_PUBLIC_DOMAIN|${+_tavily_api_keys}"
  ' _ "$work/home/.zshenv"
  assert_success
  assert_output 'linear-zshenv-canary|tavily-zshenv-canary|jina-zshenv-canary|context7-zshenv-canary|vector-zshenv-canary|openrouter-zshenv-canary|posthog-zshenv-canary|vrt-r2-access-key-zshenv-canary|vrt-r2-secret-key-zshenv-canary|membrane-visual-regression-testing|https://e9d416b8a5d9a9bd386258cc37fd3a98.r2.cloudflarestorage.com|vrt.membrane-dev.com|0'

  run env HOME="$work/home" PATH="/usr/bin:/bin" zsh -f -c '
    RANDOM=1
    source "$1"
    print -r -- "$TAVILY_API_KEY|${+_tavily_api_keys}"
  ' _ "$work/home/.zshenv"
  assert_success
  assert_output 'tavily-2-zshenv-canary|0'
}

function test_templates_0092_zshenv_host_partial_diff_preserves_secret_target_and_reports_work() {
  _bats_test_init 92 'zshenv host partial diff preserves its sentinel while reporting omission and ordinary work'
  local work="$BATS_TEST_TMPDIR/zshenv-host-diff"
  local launcher="$BATS_TEST_DIRNAME/helpers/chezmoi-unattended"
  local cfg="$work/chezmoi.yaml"
  mkdir -p "$work/home"
  printf 'zshenv-host-sentinel\n' > "$work/home/.zshenv"
  write_test_config "$cfg"

  # A full host diff against an empty destination runs to ~180k lines. Narrow
  # it to the two facts this test owns inside the run, so the lines below are
  # whole-line matches and a failure prints three lines instead of five
  # megabytes. pipefail keeps the diff's own status in front of the match: a
  # launcher that died still prints text a grep would accept, and an empty
  # grep result fails here rather than passing as "nothing unexpected".
  run bash -c '
    set -o pipefail
    env HOME="$1" MMS_CHEZMOI_UNATTENDED=1 "$2" --profile host-partial -- \
      diff --source "$3" --destination "$1" --config "$4" --color=false 2>&1 \
      | grep -E "^(chezmoi-unattended: partial coverage;|diff --git a/\.zprofile )"
  ' _ "$work/home" "$launcher" "$SOURCE_ROOT" "$cfg"
  assert_success

  # The omission notice in full. 'partial coverage' on its own never says which
  # target was skipped, so a launcher omitting the wrong file passes it.
  assert_line 'chezmoi-unattended: partial coverage; omitted source home/dot_zshenv.tmpl -> destination ~/.zshenv'
  # Ordinary work still reported, as a diff header. A bare mention of the name
  # also occurs in ~/.zshrc's own cfgfiles list and in Homebrew's shellenv
  # advice, both of which land in this diff long before any .zprofile target.
  assert_line 'diff --git a/.zprofile b/.zprofile'

  assert_file_contains "$work/home/.zshenv" '^zshenv-host-sentinel$'
  assert_equal "$(wc -l < "$work/home/.zshenv" | tr -d ' ')" 1
}

function test_templates_0093_zshenv_shared_render_helper_uses_complete_full_fixture() {
  _bats_test_init 93 'zshenv shared render helper supplies the complete full fixture'
  command_exists zsh || skip "zsh not installed"
  local work="$BATS_TEST_TMPDIR/zshenv-interactive"
  mkdir -p "$work/home"

  run render_template "$SOURCE_ROOT/dot_zshenv.tmpl"
  assert_success
  printf '%s\n' "$output" > "$work/zshenv.rendered"

  run env HOME="$work/home" PATH="/usr/bin:/bin" zsh -f -c '
    RANDOM=2
    source "$1"
    print -r -- "$LINEAR_API_KEY|$TAVILY_API_KEY|$JINA_API_KEY|$CONTEXT7_API_KEY|$VECTOR_PRIME_API_KEY|$OPENROUTER_API_KEY|$POSTHOG_PERSONAL_API_KEY|$VRT_R2_ACCESS_KEY_ID|$VRT_R2_SECRET_ACCESS_KEY"
  ' _ "$work/zshenv.rendered"
  assert_success
  assert_output 'mms-test-linear-canary|mms-test-tavily-canary|mms-test-jina-canary|mms-test-context7-canary|mms-test-vector-prime-canary|mms-test-openrouter-canary|mms-test-posthog-canary|mms-test-vrt-r2-access-key-canary|mms-test-vrt-r2-secret-key-canary'
}

function test_templates_0094_zshenv_skip_secrets_omits_state_but_execute_template_fails() {
  _bats_test_init 94 'zshenv skip secrets omits state while execute-template still fails on its secret function'
  local work="$BATS_TEST_TMPDIR/zshenv-compatibility"
  local launcher="$BATS_TEST_DIRNAME/helpers/chezmoi-unattended"
  local cfg="$work/chezmoi.yaml"
  mkdir -p "$work/bin" "$work/home"
  write_test_config "$cfg"
  cat > "$work/bin/op" <<'FAKE_OP'
#!/bin/sh
printf launched > "$FAKE_OP_MARKER"
exit 99
FAKE_OP
  chmod +x "$work/bin/op"

  printf '{{ "execute-template-control" }}' > "$work/non-secret.tmpl"
  run env \
    HOME="$work/home" \
    PATH="$work/bin:$PATH" \
    FAKE_OP_MARKER="$work/op-launched" \
    MMS_CHEZMOI_UNATTENDED=1 \
    "$launcher" --profile host-partial --finite-stdin -- \
    execute-template --source "$SOURCE_ROOT" --config "$cfg" \
    < "$work/non-secret.tmpl"
  assert_success
  assert_output 'execute-template-control'

  run env \
    HOME="$work/home" \
    PATH="$work/bin:$PATH" \
    FAKE_OP_MARKER="$work/op-launched" \
    MMS_CHEZMOI_UNATTENDED=1 \
    "$launcher" --profile host-partial --finite-stdin -- \
    execute-template --source "$SOURCE_ROOT" --config "$cfg" \
    < "$SOURCE_ROOT/dot_zshenv.tmpl"
  assert_failure
  assert_output --partial 'onepasswordRead'
  # oracle: fake op creates this marker only if skip-secrets fails before helper launch.
  assert_file_not_exists "$work/op-launched"
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

# opencode.json.tmpl has zero template directives, so asserting its other
# literals would only mirror the source. These two are consumed verbatim as
# a security contract: `executor mcp` speaks stdio, so OpenCode never holds
# the daemon's rotating token.
function test_templates_012_opencode_keeps_the_external_dir_grant_and_stdio() {
  _bats_test_init 12 'opencode keeps the external-directory grant and the stdio executor transport'
  command_exists jq || skip "jq is required"
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$SOURCE_ROOT/private_dot_config/opencode/opencode.json.tmpl" > "$BATS_TEST_TMPFILE"

  run jq -r '.permission.external_directory["*"]' "$BATS_TEST_TMPFILE"
  assert_success
  assert_output "allow"

  run jq -r '[(.mcp.executor.command | join(" ")), (.mcp.executor.enabled | tostring)] | join("|")' "$BATS_TEST_TMPFILE"
  assert_success
  assert_output "executor mcp|true"
}

function test_templates_014_every_opencode_instructions_entry_is_a_managed_f() {
  _bats_test_init 14 'every opencode instructions entry is a managed source file'
  command_exists jq || skip "jq is required"
  # OpenCode fails silently on a dangling instructions path.
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$SOURCE_ROOT/private_dot_config/opencode/opencode.json.tmpl" > "$BATS_TEST_TMPFILE"

  local entries entry
  run jq -r '.instructions[]' "$BATS_TEST_TMPFILE"
  assert_success
  entries="$output"
  [[ -n "$entries" ]] || fail "no instructions entries in opencode.json.tmpl"

  while IFS= read -r entry; do
    [[ "$entry" == "~/"* ]] || fail "instructions entry '$entry' is not home-relative, so it cannot be checked against the source tree"
    run chezmoi_host_partial source-path \
      --source "$SOURCE_ROOT" "$HOME/${entry#\~/}"
    assert_success
    assert_file_exists "$output"
  done <<< "$entries"
}

# ===========================================
# private_settings.json.tmpl retirement contract
# ===========================================
function test_templates_0151_private_settings_registers_worktree_identity_prompt_hook() {
  _bats_test_init 151 'private settings register the worktree identity and handoff hooks'
  local hooks_dir="$HOME/.claude/hooks"
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$SOURCE_ROOT/private_dot_claude/private_settings.json.tmpl" > "$BATS_TEST_TMPFILE"
  run grep -F '{{' "$BATS_TEST_TMPFILE"
  assert_failure

  # The whole command line, not a substring of it: Claude runs this string, so
  # a commented-out entry or one carrying the wrong arguments is a dead hook
  # that a substring match still accepts.
  run jq -r '.hooks.UserPromptSubmit[]?.hooks[]?.command' "$BATS_TEST_TMPFILE"
  assert_success
  assert_line "bash '$hooks_dir/herdr-worktree-identity-hook.sh'"
  run jq -r '.hooks.SessionStart[]?.hooks[]?.command' "$BATS_TEST_TMPFILE"
  assert_success
  assert_line "bash '$hooks_dir/handoff-session-start.sh'"

  # Both registered paths, not just one: a registration pointing at a script
  # chezmoi does not manage is the same dead hook by another route.
  run chezmoi_host_partial source-path \
    --source "$SOURCE_ROOT" "$hooks_dir/herdr-worktree-identity-hook.sh"
  assert_success
  assert_file_exists "$output"
  run chezmoi_host_partial source-path \
    --source "$SOURCE_ROOT" "$hooks_dir/handoff-session-start.sh"
  assert_success
  assert_file_exists "$output"
}

function test_templates_0152_private_settings_register_the_precompact_handoff_builder() {
  _bats_test_init 152 'private settings register the PreCompact handoff builder'
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$SOURCE_ROOT/private_dot_claude/private_settings.json.tmpl" > "$BATS_TEST_TMPFILE"
  run grep -F '{{' "$BATS_TEST_TMPFILE"
  assert_failure

  # A hook deployed but never registered is a tracked defect class here, so the
  # registration is asserted alongside the hook rather than left to the smoke
  # suite. See the frozen source record at
  # https://github.com/Seigiard/my-mac-setup/blob/27f33a235548f19422b94565f6a14613219b5d5b/docs/issues/2026-09-03-004-user-prompt-skill-eval-hook-is-deployed-but-never-wired.md.
  run jq -r '.hooks.PreCompact[]?.hooks[]?.command' "$BATS_TEST_TMPFILE"
  assert_success
  assert_line "bash '$HOME/.claude/hooks/handoff-pre-compact.sh'"
  run chezmoi_host_partial source-path \
    --source "$SOURCE_ROOT" "$HOME/.claude/hooks/handoff-pre-compact.sh"
  assert_success
  assert_file_exists "$output"
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
  refute_line 'brew "nono"'
  refute_line 'brew "fzf"'
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
  # No test resolves a macOS-only cask or formula, so the guard covers the
  # whole file. `brew bundle` accepts empty.
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
  # node, bun, and gitleaks are asserted only in the minimal render elsewhere,
  # so they need pinning here too, or moving any of them into the
  # ci_minimal-only branch would satisfy every assertion in this file while
  # real hosts silently stop installing them.
  assert_line 'brew "node"'
  assert_line --partial 'brew "oven-sh/bun/bun"'
  assert_line 'brew "gitleaks"'
  assert_line 'brew "nono"'

  run render_with_config "$cfg" "$SOURCE_ROOT/$BREWFILE_MACOS_TMPL"
  assert_success
  assert_line 'cask "spotify"'
  assert_line --partial 'brew "elio"'
  assert_line --partial 'brew "rust"'
  refute_line 'brew "terminal-notifier"'
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
      # Status first, like every sibling in this section: a failed render
      # produces no entries, so the grep below would find nothing and the
      # assert_failure would pass on an empty string.
      run render_with_config "$cfg" "$SOURCE_ROOT/$tmpl"
      assert_success
      out="$output"
      run grep -n '^[[:space:]][[:space:]]*\(brew\|cask\|tap\) ' <<< "$out"
      assert_failure
    done
  done
}

render_with_source() {
  local template_file="$1"
  chezmoi_full_fixture_finite_stdin --source "$SOURCE_ROOT" execute-template < "$template_file"
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

  run chezmoi_full_fixture apply \
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

function test_templates_030_agent_skills_sync_hash_changes_for_each_managed_input() {
  _bats_test_init 30 'agent-skills sync onchange hash changes when either managed input changes'
  skip_if_no_chezmoi
  local hook="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_9-sync-agent-skills.sh.tmpl"
  local source="$BATS_TEST_TMPDIR/source" first manifest_changed wrapper_changed
  mkdir -p "$source/private_dot_config/agent-skills" "$source/dot_local/bin"
  cp "$SOURCE_ROOT/private_dot_config/agent-skills/manifest" \
    "$source/private_dot_config/agent-skills/manifest"
  cp "$SOURCE_ROOT/dot_local/bin/executable_skills" "$source/dot_local/bin/executable_skills"

  run chezmoi_full_fixture_finite_stdin --source "$source" execute-template < "$hook"
  assert_success
  first="$output"
  printf '\n# manifest probe\n' >> "$source/private_dot_config/agent-skills/manifest"
  run chezmoi_full_fixture_finite_stdin --source "$source" execute-template < "$hook"
  assert_success
  manifest_changed="$output"
  printf '\n# wrapper probe\n' >> "$source/dot_local/bin/executable_skills"
  run chezmoi_full_fixture_finite_stdin --source "$source" execute-template < "$hook"
  assert_success
  wrapper_changed="$output"

  run test "$first" != "$manifest_changed"
  assert_success
  run test "$manifest_changed" != "$wrapper_changed"
  assert_success
}

function test_templates_031_enabled_claude_plugin_keys_name_a_marketplace() {
  _bats_test_init 31 'every enabled Claude plugin key names both a plugin and its marketplace'
  skip_if_no_chezmoi
  # Which plugins are enabled is a selection, not a contract:
  # docs/agent-setup-inventory.md owns the list, and this suite cannot read it
  # (the template container mounts only home/, tests/, Makefile and README.md
  # -- docker/docker-compose.yml). Naming the four current plugins here would
  # copy them out of the template this test renders, so an intended edit would
  # change both sides at once and never fail.
  #
  # What survives any selection edit is the key format Claude resolves a plugin
  # by: "<plugin>@<marketplace>", mapped to true. A key that lost its
  # marketplace half, or a value that is not true, disables the plugin silently
  # at load -- no error, no plugin.
  #
  # The retired-provider absence checks this test used to carry are gone. Two
  # of them could not fail: the template declares no extraKnownMarketplaces and
  # opencode.json declares no plugin key, so `jq -e ... | has(...)` ran against
  # null and exited non-zero whatever the settings said. Removing a provider
  # does not by itself justify asserting its absence (~/.claude/rules/
  # testing.md); the capability that remains is asserted below. JSON validity
  # of both renders is owned by test 14 ('every opencode instructions entry is
  # a managed source file') and test 151 ('private settings register the
  # worktree identity and handoff hooks'), which jq the same two templates.
  local home="$BATS_TEST_TMPDIR/client-home"

  HOME="$home" run chezmoi_full_fixture_finite_stdin --source "$SOURCE_ROOT" execute-template \
    < "$SOURCE_ROOT/private_dot_claude/private_settings.json.tmpl"
  assert_success

  run jq -r '
    (.enabledPlugins // {}) as $plugins
    | [$plugins | to_entries[]
       | select((.key | test("^[^@[:space:]]+@[^@[:space:]]+$") | not) or .value != true)
       | .key]
    | if ($plugins | length) == 0 then "no plugin is enabled"
      elif length > 0 then "unresolvable: " + join(", ")
      else "every enabled plugin names its marketplace"
      end
  ' <<< "$output"
  assert_success
  assert_output 'every enabled plugin names its marketplace'
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function tear_down() { _bats_run_teardown; }
