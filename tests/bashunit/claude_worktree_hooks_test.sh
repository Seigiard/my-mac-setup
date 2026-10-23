#!/usr/bin/env bash
# post-apply: 23 host-safe
# Claude Code calls these scripts before it enters a nested worktree. The suite
# exercises that command boundary against Git's worktree and ref state.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/common'

setup() {
  CREATE_HOOK="$SOURCE_ROOT/private_dot_claude/hooks/executable_claude-worktree-create.sh"
  REMOVE_HOOK="$SOURCE_ROOT/private_dot_claude/hooks/executable_claude-worktree-remove.sh"
  GIT_HOME="$BATS_TEST_TMPDIR/git-home"
  MAIN="$BATS_TEST_TMPDIR/project"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  PLUGIN_DIR="$BATS_TEST_TMPDIR/plugin"
  PLUGIN_CONFIG_DIR="$BATS_TEST_TMPDIR/plugin-config"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  BUN_ONLY_BIN="$BATS_TEST_TMPDIR/bun-only-bin"
  BUN_CWD="$BATS_TEST_TMPDIR/bun-cwd"
  BUN_EVENT="$BATS_TEST_TMPDIR/bun-event"
  BUN_CONFIG="$BATS_TEST_TMPDIR/bun-config"
  BUN_ARGS="$BATS_TEST_TMPDIR/bun-args"
  BUN_CALLS="$BATS_TEST_TMPDIR/bun-calls"
  HERDR_CALLS="$BATS_TEST_TMPDIR/herdr-calls"
  mkdir -p "$GIT_HOME" "$PLUGIN_DIR" "$PLUGIN_CONFIG_DIR" "$FAKE_BIN" "$BUN_ONLY_BIN"
  : > "$PLUGIN_DIR/setup.ts"
  : > "$BUN_CALLS"
  install_fake_bun
  install_fake_herdr
  create_git_fixture
}

fgit() {
  env HOME="$GIT_HOME" GIT_CONFIG_NOSYSTEM=1 git "$@"
}

registered_worktree_paths() {
  fgit -C "$1" worktree list --porcelain |
    awk '/^worktree / { print substr($0, 10) }'
}

create_git_fixture() {
  fgit init -q "$MAIN"
  fgit -C "$MAIN" config user.name 'Claude Worktree Test'
  fgit -C "$MAIN" config user.email 'claude-worktree@example.invalid'
  fgit -C "$MAIN" config commit.gpgsign false
  fgit -C "$MAIN" checkout -q -b main
  printf 'base\n' > "$MAIN/base.txt"
  fgit -C "$MAIN" add base.txt
  fgit -C "$MAIN" commit -q -m 'base commit'
  fgit init -q --bare "$ORIGIN"
  fgit -C "$MAIN" remote add origin "$ORIGIN"
  fgit -C "$MAIN" push -q -u origin main
  fgit --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main
  fgit -C "$MAIN" remote set-head origin -a
  # Keep local HEAD ahead so the origin/HEAD choice differs from the fallback.
  printf 'local only\n' > "$MAIN/local-only.txt"
  fgit -C "$MAIN" add local-only.txt
  fgit -C "$MAIN" commit -q -m 'local-only commit'
  mkdir -p "$MAIN/nested/cwd"
}

install_fake_bun() {
  cat > "$FAKE_BIN/bun" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PWD" > "$WORKTREE_HOOK_TEST_BUN_CWD"
printf '%s\n' "$HERDR_PLUGIN_EVENT_JSON" > "$WORKTREE_HOOK_TEST_BUN_EVENT"
printf '%s\n' "$HERDR_PLUGIN_CONFIG_DIR" > "$WORKTREE_HOOK_TEST_BUN_CONFIG"
printf '%s\n' "$*" > "$WORKTREE_HOOK_TEST_BUN_ARGS"
printf 'called\n' >> "$WORKTREE_HOOK_TEST_BUN_CALLS"
printf 'plugin setup output\n'
exit "${WORKTREE_HOOK_TEST_BUN_STATUS:-0}"
SH
  chmod +x "$FAKE_BIN/bun"
  cp "$FAKE_BIN/bun" "$BUN_ONLY_BIN/bun"
}

install_fake_herdr() {
  cat > "$FAKE_BIN/herdr" <<'SH'
#!/usr/bin/env bash
if [ "$*" = 'plugin list --json' ]; then
  printf '%s\n' "$*" >> "$WORKTREE_HOOK_TEST_HERDR_CALLS"
  printf '%s\n' "$WORKTREE_HOOK_TEST_HERDR_RESPONSE"
  exit "${WORKTREE_HOOK_TEST_HERDR_STATUS:-0}"
fi
exit 64
SH
  chmod +x "$FAKE_BIN/herdr"
}

write_create_input() {
  local name="$1" cwd="$2"
  CREATE_INPUT="$BATS_TEST_TMPDIR/create-input.json"
  printf '{"name":"%s","cwd":"%s"}\n' "$name" "$cwd" > "$CREATE_INPUT"
}

run_create() {
  local name="$1" cwd="$2"
  write_create_input "$name" "$cwd"
  run --separate-stderr env \
    CLAUDE_WORKTREE_SETUP_PLUGIN_DIR="$PLUGIN_DIR" \
    CLAUDE_WORKTREE_SETUP_CONFIG_DIR="$PLUGIN_CONFIG_DIR" \
    WORKTREE_HOOK_TEST_BUN_CWD="$BUN_CWD" \
    WORKTREE_HOOK_TEST_BUN_EVENT="$BUN_EVENT" \
    WORKTREE_HOOK_TEST_BUN_CONFIG="$BUN_CONFIG" \
    WORKTREE_HOOK_TEST_BUN_ARGS="$BUN_ARGS" \
    WORKTREE_HOOK_TEST_BUN_CALLS="$BUN_CALLS" \
    WORKTREE_HOOK_TEST_BUN_STATUS="${WORKTREE_HOOK_TEST_BUN_STATUS:-0}" \
    PATH="$FAKE_BIN:$PATH" \
    bash -c 'bash "$1" < "$2"' _ "$CREATE_HOOK" "$CREATE_INPUT"
}

run_create_without_bun() {
  local name="$1" cwd="$2"
  write_create_input "$name" "$cwd"
  run --separate-stderr env \
    CLAUDE_WORKTREE_SETUP_PLUGIN_DIR="$PLUGIN_DIR" \
    CLAUDE_WORKTREE_SETUP_CONFIG_DIR="$PLUGIN_CONFIG_DIR" \
    PATH='/usr/bin:/bin' \
    bash -c 'bash "$1" < "$2"' _ "$CREATE_HOOK" "$CREATE_INPUT"
}

run_create_via_herdr() {
  local name="$1" cwd="$2" response="$3"
  write_create_input "$name" "$cwd"
  run --separate-stderr env \
    HOME="$BATS_TEST_TMPDIR/discovery-home" \
    CLAUDE_WORKTREE_SETUP_CONFIG_DIR="$PLUGIN_CONFIG_DIR" \
    WORKTREE_HOOK_TEST_BUN_CWD="$BUN_CWD" \
    WORKTREE_HOOK_TEST_BUN_EVENT="$BUN_EVENT" \
    WORKTREE_HOOK_TEST_BUN_CONFIG="$BUN_CONFIG" \
    WORKTREE_HOOK_TEST_BUN_ARGS="$BUN_ARGS" \
    WORKTREE_HOOK_TEST_BUN_CALLS="$BUN_CALLS" \
    WORKTREE_HOOK_TEST_BUN_STATUS="${WORKTREE_HOOK_TEST_BUN_STATUS:-0}" \
    WORKTREE_HOOK_TEST_HERDR_CALLS="$HERDR_CALLS" \
    WORKTREE_HOOK_TEST_HERDR_RESPONSE="$response" \
    WORKTREE_HOOK_TEST_HERDR_STATUS="${WORKTREE_HOOK_TEST_HERDR_STATUS:-0}" \
    PATH="$FAKE_BIN:$PATH" \
    bash -c 'bash "$1" < "$2"' _ "$CREATE_HOOK" "$CREATE_INPUT"
}

run_create_without_herdr() {
  local name="$1" cwd="$2"
  write_create_input "$name" "$cwd"
  run --separate-stderr env \
    HOME="$BATS_TEST_TMPDIR/discovery-home" \
    CLAUDE_WORKTREE_SETUP_CONFIG_DIR="$PLUGIN_CONFIG_DIR" \
    WORKTREE_HOOK_TEST_BUN_CWD="$BUN_CWD" \
    WORKTREE_HOOK_TEST_BUN_EVENT="$BUN_EVENT" \
    WORKTREE_HOOK_TEST_BUN_CONFIG="$BUN_CONFIG" \
    WORKTREE_HOOK_TEST_BUN_ARGS="$BUN_ARGS" \
    WORKTREE_HOOK_TEST_BUN_CALLS="$BUN_CALLS" \
    PATH="$BUN_ONLY_BIN:/usr/bin:/bin" \
    bash -c 'bash "$1" < "$2"' _ "$CREATE_HOOK" "$CREATE_INPUT"
}

run_remove() {
  local path="$1"
  REMOVE_INPUT="$BATS_TEST_TMPDIR/remove-input.json"
  printf '{"worktree_path":"%s"}\n' "$path" > "$REMOVE_INPUT"
  run --separate-stderr bash -c 'bash "$1" < "$2"' _ "$REMOVE_HOOK" "$REMOVE_INPUT"
}

assert_record_equals() {
  local path="$1" expected="$2"
  run cat "$path"
  assert_success
  assert_output "$expected"
}

assert_setup_did_not_run() {
  assert_record_equals "$BUN_CALLS" ''
}

function test_claude_worktree_hooks_001_create_uses_origin_head_and_keeps_stdout_to_the_path() {
  _bats_test_init 54001 'create hook creates the named linked worktree from origin HEAD'
  local name='bright-otter' expected_path="$MAIN/.claude/worktrees/bright-otter" base
  base="$(fgit -C "$MAIN" rev-parse origin/HEAD)"

  # #given
  # The fixture has a bare origin whose symbolic HEAD points at main.
  # #when
  run_create "$name" "$MAIN/nested/cwd"
  # #then
  assert_success
  assert_output "$expected_path"
  assert_dir_exists "$expected_path"
  run fgit -C "$expected_path" rev-parse HEAD
  assert_success
  assert_output "$base"
  run fgit -C "$expected_path" branch --show-current
  assert_success
  assert_output 'worktree-bright-otter'
}

function test_claude_worktree_hooks_002_create_reentry_returns_the_registered_path_without_setup() {
  _bats_test_init 54002 'create hook does not recreate or set up a registered worktree'
  local name='quiet-lynx' expected_path="$MAIN/.claude/worktrees/quiet-lynx"

  # #given
  run_create "$name" "$MAIN/nested/cwd"
  assert_success
  assert_record_equals "$BUN_CALLS" 'called'
  # #when
  run_create "$name" "$MAIN/nested/cwd"
  # #then
  assert_success
  assert_output "$expected_path"
  assert_record_equals "$BUN_CALLS" 'called'
}

function test_claude_worktree_hooks_003_create_falls_back_to_head_without_origin_head() {
  _bats_test_init 54003 'create hook uses HEAD when origin HEAD cannot resolve'
  local expected_path="$MAIN/.claude/worktrees/head-fallback" base
  base="$(fgit -C "$MAIN" rev-parse HEAD)"
  fgit -C "$MAIN" remote remove origin

  # #given
  # The checkout has no origin/HEAD but has a valid local HEAD.
  # #when
  run_create 'head-fallback' "$MAIN/nested/cwd"
  # #then
  assert_success
  assert_output "$expected_path"
  run fgit -C "$expected_path" rev-parse HEAD
  assert_success
  assert_output "$base"
}

function test_claude_worktree_hooks_004_create_fails_without_a_worktree_and_prints_no_path() {
  _bats_test_init 54004 'create hook rejects a branch already checked out elsewhere'
  local occupied="$BATS_TEST_TMPDIR/occupied"
  local ready_path="$MAIN/.claude/worktrees/ready-before-conflict"
  run_create 'ready-before-conflict' "$MAIN/nested/cwd"
  assert_success
  assert_output "$ready_path"
  fgit -C "$MAIN" worktree add -q -b worktree-occupied "$occupied" origin/HEAD

  # #given
  # A successful control proves the hook reached creation before Git rejects the occupied branch.
  # #when
  run_create 'occupied' "$MAIN/nested/cwd"
  # #then
  assert_failure
  assert_output ''
}

function test_claude_worktree_hooks_005_create_rejects_a_cwd_outside_git() {
  _bats_test_init 54005 'create hook rejects a cwd outside a Git checkout'
  local outside="$BATS_TEST_TMPDIR/not-a-repository"
  local ready_path="$MAIN/.claude/worktrees/ready-before-non-git"
  mkdir -p "$outside"
  run_create 'ready-before-non-git' "$MAIN/nested/cwd"
  assert_success
  assert_output "$ready_path"

  # #given
  # A successful control proves the JSON reaches the hook before cwd has no Git root.
  # #when
  run_create 'no-repository' "$outside"
  # #then
  assert_failure
  assert_output ''
}

function test_claude_worktree_hooks_006_create_passes_the_plugin_event_and_redirects_plugin_stdout() {
  _bats_test_init 54006 'create hook invokes setup with the detached-branch event'
  local expected_path="$MAIN/.claude/worktrees/event-check"
  local expected_event
  expected_event="{\"data\":{\"worktree\":{\"path\":\"$expected_path\",\"branch\":\"\"}}}"

  # #given
  # The fake bun records its process boundary and emits output on stdout.
  # #when
  run_create 'event-check' "$MAIN/nested/cwd"
  # #then
  assert_success
  assert_output "$expected_path"
  assert_stderr --partial 'plugin setup output'
  assert_record_equals "$BUN_CWD" "$PLUGIN_DIR"
  assert_record_equals "$BUN_EVENT" "$expected_event"
  assert_record_equals "$BUN_CONFIG" "$PLUGIN_CONFIG_DIR"
  assert_record_equals "$BUN_ARGS" 'setup.ts'
}

function test_claude_worktree_hooks_007_create_keeps_the_base_tip_when_the_project_enables_fresh_base() {
  _bats_test_init 54007 'create hook gives fresh-base setup an empty branch field'
  local expected_path="$MAIN/.claude/worktrees/fresh-base" base expected_event
  base="$(fgit -C "$MAIN" rev-parse origin/HEAD)"
  expected_event="{\"data\":{\"worktree\":{\"path\":\"$expected_path\",\"branch\":\"\"}}}"

  # #given
  # The event's empty branch is the plugin's documented fresh-base skip signal.
  # #when
  run_create 'fresh-base' "$MAIN/nested/cwd"
  # #then
  assert_success
  assert_record_equals "$BUN_EVENT" "$expected_event"
  run fgit -C "$expected_path" rev-parse HEAD
  assert_success
  assert_output "$base"
}

function test_claude_worktree_hooks_008_create_keeps_creation_success_when_setup_is_missing() {
  _bats_test_init 54008 'create hook leaves a missing plugin outside the creation result'
  local expected_path="$MAIN/.claude/worktrees/missing-plugin"
  PLUGIN_DIR="$BATS_TEST_TMPDIR/no-plugin"

  # #given
  # No setup.ts is available at the configured plugin directory.
  # #when
  run_create 'missing-plugin' "$MAIN/nested/cwd"
  # #then
  assert_success
  assert_output "$expected_path"
  assert_stderr 'claude worktree create: setup skipped (setup.ts not found)'
}

function test_claude_worktree_hooks_009_create_keeps_creation_success_when_bun_is_missing() {
  _bats_test_init 54009 'create hook leaves a missing bun outside the creation result'
  local expected_path="$MAIN/.claude/worktrees/missing-bun"

  # #given
  # PATH has Git but does not contain the fake bun or a host-installed bun.
  # #when
  run_create_without_bun 'missing-bun' "$MAIN/nested/cwd"
  # #then
  assert_success
  assert_output "$expected_path"
  assert_stderr 'claude worktree create: setup skipped (bun not found)'
}

function test_claude_worktree_hooks_010_create_keeps_creation_success_when_setup_fails() {
  _bats_test_init 54010 'create hook leaves a setup exit outside the creation result'
  local expected_path="$MAIN/.claude/worktrees/failing-setup"

  # #given
  # The fake plugin process fails after it records the event.
  # #when
  WORKTREE_HOOK_TEST_BUN_STATUS=42 run_create 'failing-setup' "$MAIN/nested/cwd"
  # #then
  assert_success
  assert_output "$expected_path"
  assert_stderr --partial 'claude worktree create: setup failed (creation retained)'
}

function test_claude_worktree_hooks_011_remove_deletes_a_merged_branch_with_its_worktree() {
  _bats_test_init 54011 'remove hook deletes a worktree branch contained by main'
  local path="$MAIN/.claude/worktrees/merged"
  fgit -C "$MAIN" worktree add -q -b worktree-merged "$path" origin/HEAD

  # #given
  # worktree-merged points at main, so another local branch contains its tip.
  # #when
  run_remove "$path"
  # #then
  assert_success
  assert_dir_not_exists "$path"
  run fgit -C "$MAIN" branch --list --format='%(refname:short)'
  assert_success
  assert_output 'main'
}

function test_claude_worktree_hooks_012_remove_keeps_an_unmerged_branch_after_removing_its_worktree() {
  _bats_test_init 54012 'remove hook preserves a worktree branch not contained elsewhere'
  local path="$MAIN/.claude/worktrees/unmerged"
  fgit -C "$MAIN" worktree add -q -b worktree-unmerged "$path" origin/HEAD
  printf 'unmerged\n' > "$path/unmerged.txt"
  fgit -C "$path" add unmerged.txt
  fgit -C "$path" commit -q -m 'unmerged work'

  # #given
  # No local or remote-tracking ref contains the worktree branch tip.
  # #when
  run_remove "$path"
  # #then
  assert_success
  assert_dir_not_exists "$path"
  assert_stderr --partial 'worktree-unmerged'
  run fgit -C "$MAIN" branch --list --format='%(refname:short)'
  assert_success
  assert_output $'main\nworktree-unmerged'
}

function test_claude_worktree_hooks_013_remove_ignores_a_missing_path_and_rejects_a_plain_directory() {
  _bats_test_init 54013 'remove hook does not delete a non-worktree directory'
  local missing="$BATS_TEST_TMPDIR/missing"
  local plain="$BATS_TEST_TMPDIR/plain-directory"
  mkdir -p "$plain"
  printf 'keep\n' > "$plain/keep.txt"

  # #given
  # Claude may ask removal after a directory has gone, but a plain directory is not its worktree.
  # #when
  run_remove "$missing"
  # #then
  assert_success
  run_remove "$plain"
  assert_failure
  assert_dir_exists "$plain"
  assert_file_exists "$plain/keep.txt"
}

function test_claude_worktree_hooks_014_create_discovers_the_enabled_worktree_setup_plugin_from_herdr() {
  _bats_test_init 54014 'create hook discovers the enabled plugin root from Herdr'
  local expected_path="$MAIN/.claude/worktrees/discovered-plugin"
  local response
  response="{\"result\":{\"plugins\":[{\"plugin_id\":\"seigi.worktree-setup\",\"enabled\":true,\"plugin_root\":\"$PLUGIN_DIR\",\"config_dir\":null}]}}"

  # #given
  # The plugin-directory override is absent; only Herdr's registry selects setup.ts.
  # #when
  run_create_via_herdr 'discovered-plugin' "$MAIN/nested/cwd" "$response"
  # #then
  assert_success
  assert_output "$expected_path"
  assert_stderr 'plugin setup output'
  assert_record_equals "$HERDR_CALLS" 'plugin list --json'
  assert_record_equals "$BUN_CWD" "$PLUGIN_DIR"
}

function test_claude_worktree_hooks_015_create_keeps_creation_when_herdr_is_unavailable() {
  _bats_test_init 54015 'create hook retains creation when Herdr is unavailable for plugin discovery'
  local expected_path="$MAIN/.claude/worktrees/no-herdr"

  # #given
  # bun and setup.ts are available, but no herdr executable is on PATH.
  # #when
  run_create_without_herdr 'no-herdr' "$MAIN/nested/cwd"
  # #then
  assert_success
  assert_output "$expected_path"
  assert_stderr 'claude worktree create: setup skipped (herdr not found)'
  assert_setup_did_not_run
}

function test_claude_worktree_hooks_016_create_keeps_creation_when_herdr_plugin_list_is_not_json() {
  _bats_test_init 54016 'create hook retains creation when Herdr returns malformed plugin JSON'
  local expected_path="$MAIN/.claude/worktrees/malformed-registry"

  # #given
  # The registry command succeeds but its reply cannot identify a plugin root.
  # #when
  run_create_via_herdr 'malformed-registry' "$MAIN/nested/cwd" 'this is not JSON'
  # #then
  assert_success
  assert_output "$expected_path"
  assert_stderr 'claude worktree create: setup skipped (plugin list is not valid JSON)'
  assert_setup_did_not_run
}

function test_claude_worktree_hooks_017_create_keeps_creation_when_herdr_does_not_list_worktree_setup() {
  _bats_test_init 54017 'create hook retains creation when Herdr has no Worktree Setup entry'
  local expected_path="$MAIN/.claude/worktrees/missing-registry-plugin"
  local response='{"result":{"plugins":[]}}'

  # #given
  # The registry is valid but contains no selected setup plugin.
  # #when
  run_create_via_herdr 'missing-registry-plugin' "$MAIN/nested/cwd" "$response"
  # #then
  assert_success
  assert_output "$expected_path"
  assert_stderr 'claude worktree create: setup skipped (worktree setup plugin is not enabled)'
  assert_setup_did_not_run
}

function test_claude_worktree_hooks_018_create_keeps_creation_when_herdr_lists_worktree_setup_disabled() {
  _bats_test_init 54018 'create hook retains creation when Worktree Setup is disabled in Herdr'
  local expected_path="$MAIN/.claude/worktrees/disabled-registry-plugin"
  local response="{\"result\":{\"plugins\":[{\"plugin_id\":\"seigi.worktree-setup\",\"enabled\":false,\"plugin_root\":\"$PLUGIN_DIR\",\"config_dir\":null}]}}"

  # #given
  # A disabled entry must not supply a plugin root even when it names setup.ts.
  # #when
  run_create_via_herdr 'disabled-registry-plugin' "$MAIN/nested/cwd" "$response"
  # #then
  assert_success
  assert_output "$expected_path"
  assert_stderr 'claude worktree create: setup skipped (worktree setup plugin is not enabled)'
  assert_setup_did_not_run
}

function test_claude_worktree_hooks_019_remove_refuses_a_worktree_that_contains_another_registered_worktree() {
  _bats_test_init 54019 'remove hook leaves nested registered worktrees untouched'
  local path="$MAIN/.claude/worktrees/parent"
  local nested="$path/.claude/worktrees/child"
  fgit -C "$MAIN" worktree add -q -b worktree-parent "$path" origin/HEAD
  mkdir -p "$(dirname "$nested")"
  fgit -C "$MAIN" worktree add -q -b worktree-child "$nested" origin/HEAD

  # #given
  # Git's registry has a child linked worktree below the requested parent path.
  # #when
  run_remove "$path"
  # #then
  assert_failure
  assert_stderr 'claude worktree remove: refusing to remove a path that contains another registered worktree'
  assert_dir_exists "$path"
  assert_dir_exists "$nested"
  run fgit -C "$MAIN" branch --list --format='%(refname:short)'
  assert_success
  assert_output $'main\nworktree-child\nworktree-parent'
}

function test_claude_worktree_hooks_020_create_reuses_an_existing_unchecked_out_worktree_branch() {
  _bats_test_init 54020 'create hook attaches an unoccupied worktree branch without resetting it'
  local expected_path="$MAIN/.claude/worktrees/reuse-branch"
  local edit_path="$BATS_TEST_TMPDIR/reuse-branch-edit" branch_tip
  fgit -C "$MAIN" branch worktree-reuse-branch origin/HEAD
  fgit -C "$MAIN" worktree add -q "$edit_path" worktree-reuse-branch
  printf 'branch work\n' > "$edit_path/branch-work.txt"
  fgit -C "$edit_path" add branch-work.txt
  fgit -C "$edit_path" commit -q -m 'branch work'
  branch_tip="$(fgit -C "$edit_path" rev-parse HEAD)"
  fgit -C "$MAIN" worktree remove --force "$edit_path"

  # #given
  # The target branch has an unmerged commit but Git reports no linked worktree
  # for it.
  # #when
  run_create 'reuse-branch' "$MAIN/nested/cwd"
  # #then
  assert_success
  assert_output "$expected_path"
  assert_record_equals "$BUN_CALLS" 'called'
  run fgit -C "$expected_path" branch --show-current
  assert_success
  assert_output 'worktree-reuse-branch'
  run fgit -C "$expected_path" rev-parse HEAD
  assert_success
  assert_output "$branch_tip"
}

function test_claude_worktree_hooks_021_create_rejects_a_json_escaped_name_before_creating_a_worktree() {
  _bats_test_init 54021 'create hook rejects a JSON-escaped worktree name'
  local expected_path="$MAIN/.claude/worktrees/escaped-name"
  CREATE_INPUT="$BATS_TEST_TMPDIR/create-escaped-name.json"
  printf '%s\n' '{"name":"escaped\\u002dname","cwd":"'"$MAIN/nested/cwd"'"}' > "$CREATE_INPUT"

  # #given
  # The hook receives a JSON escape rather than a literal worktree name.
  # #when
  run --separate-stderr bash -c 'bash "$1" < "$2"' _ "$CREATE_HOOK" "$CREATE_INPUT"
  # #then
  assert_failure
  assert_output ''
  assert_stderr 'claude worktree create: input contains a JSON escape'
  assert_dir_not_exists "$expected_path"
}

function test_claude_worktree_hooks_022_create_rejects_a_json_escaped_cwd_before_creating_a_worktree() {
  _bats_test_init 54022 'create hook rejects a JSON-escaped cwd'
  local expected_path="$MAIN/.claude/worktrees/escaped-cwd"
  CREATE_INPUT="$BATS_TEST_TMPDIR/create-escaped-cwd.json"
  printf '%s\n' '{"name":"escaped-cwd","cwd":"'"$MAIN/nested/cwd"'\\u002fchild"}' > "$CREATE_INPUT"

  # #given
  # The cwd has a JSON escape which must not become a literal filesystem path.
  # #when
  run --separate-stderr bash -c 'bash "$1" < "$2"' _ "$CREATE_HOOK" "$CREATE_INPUT"
  # #then
  assert_failure
  assert_output ''
  assert_stderr 'claude worktree create: input contains a JSON escape'
  assert_dir_not_exists "$expected_path"
}

function test_claude_worktree_hooks_023_remove_rejects_a_json_escaped_worktree_path_without_removal() {
  _bats_test_init 54023 'remove hook rejects a JSON-escaped worktree path'
  local path="$MAIN/.claude/worktrees/escaped-remove"
  fgit -C "$MAIN" worktree add -q -b worktree-escaped-remove "$path" origin/HEAD
  REMOVE_INPUT="$BATS_TEST_TMPDIR/remove-escaped-path.json"
  printf '%s\n' '{"worktree_path":"'"$path"'\\u002fchild"}' > "$REMOVE_INPUT"

  # #given
  # The encoded child suffix must not make the hook act on an undecoded path.
  # #when
  run --separate-stderr bash -c 'bash "$1" < "$2"' _ "$REMOVE_HOOK" "$REMOVE_INPUT"
  # #then
  assert_failure
  assert_output ''
  assert_stderr 'claude worktree remove: input contains a JSON escape'
  assert_dir_exists "$path"
  run fgit -C "$MAIN" branch --show-current
  assert_success
  assert_output 'main'
}

function test_claude_worktree_hooks_024_remove_keeps_an_unmerged_branch_when_a_tag_has_its_short_name() {
  _bats_test_init 54024 'remove hook checks containment against the worktree branch ref'
  local path="$MAIN/.claude/worktrees/tag-collision" remove_stderr
  fgit -C "$MAIN" worktree add -q -b worktree-tag-collision "$path" origin/HEAD
  printf 'unmerged\n' > "$path/unmerged.txt"
  fgit -C "$path" add unmerged.txt
  fgit -C "$path" commit -q -m 'unmerged work'
  fgit -C "$MAIN" tag worktree-tag-collision origin/HEAD

  # #given
  # A tag with the branch's short name points at main, while the branch has an
  # unmerged commit.
  # #when
  run_remove "$path"
  remove_stderr="$stderr"
  # #then
  assert_success
  assert_dir_not_exists "$path"
  run fgit -C "$MAIN" for-each-ref --format='%(refname)' refs/heads
  assert_success
  assert_output $'refs/heads/main\nrefs/heads/worktree-tag-collision'
  assert_equal "$remove_stderr" 'claude worktree remove: kept branch worktree-tag-collision (tip is not contained)'
}

function test_claude_worktree_hooks_025_create_prunes_a_registered_path_that_no_longer_exists() {
  _bats_test_init 54025 'create hook recreates a prunable registered worktree'
  local name='prunable' expected_path="$MAIN/.claude/worktrees/prunable"
  fgit -C "$MAIN" worktree add -q -b worktree-prunable "$expected_path" origin/HEAD
  rm -rf "$expected_path"

  # #given
  # Git still registers the removed worktree path, but its directory is gone.
  # #when
  run_create "$name" "$MAIN/nested/cwd"
  # #then
  assert_success
  assert_output "$expected_path"
  assert_dir_exists "$expected_path"
  assert_record_equals "$BUN_CALLS" 'called'
  run fgit -C "$expected_path" branch --show-current
  assert_success
  assert_output 'worktree-prunable'
}

function test_claude_worktree_hooks_026_create_recovers_only_its_own_prunable_registration() {
  _bats_test_init 54026 'create hook retains unrelated prunable worktree registrations'
  local name='recover-one' expected_path="$MAIN/.claude/worktrees/recover-one"
  local unrelated_path="$BATS_TEST_TMPDIR/unavailable-worktree"
  local main_real expected_registered_path unrelated_registered_path expected_registrations
  main_real="$(cd "$MAIN" && pwd -P)"
  expected_registered_path="$main_real/.claude/worktrees/recover-one"
  unrelated_registered_path="$(cd "$(dirname "$unrelated_path")" && pwd -P)/$(basename "$unrelated_path")"
  expected_registrations="$main_real"$'\n'"$expected_registered_path"$'\n'"$unrelated_registered_path"
  fgit -C "$MAIN" worktree add -q -b worktree-recover-one "$expected_path" origin/HEAD
  fgit -C "$MAIN" worktree add -q -b worktree-unavailable "$unrelated_path" origin/HEAD
  rm -rf "$expected_path" "$unrelated_path"

  # #given
  # Both missing directories remain Git worktree registrations before the hook
  # receives a request to recover only recover-one.
  run registered_worktree_paths "$MAIN"
  assert_success
  assert_output "$expected_registrations"
  # #when
  run_create "$name" "$MAIN/nested/cwd"
  # #then
  assert_success
  assert_output "$expected_path"
  run registered_worktree_paths "$MAIN"
  assert_success
  assert_output "$expected_registrations"
}
