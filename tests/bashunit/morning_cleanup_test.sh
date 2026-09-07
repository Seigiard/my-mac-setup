#!/usr/bin/env bash
# post-apply: 25 host-safe
# morning-cleanup destructive legs (trash purge, platform worktree/branch
# cleanup), run against the SOURCE script under a disposable $HOME — both
# roots the script touches derive from $HOME, so the override isolates them.
# Oracle: resulting filesystem state and git's own reports (worktree list,
# branch --list); no assertion inspects the script's source.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/common'

setup() {
  SCRIPT="$SOURCE_ROOT/dot_local/bin/executable_morning-cleanup.sh"
  FAKE_HOME="$BATS_TEST_TMPDIR/mc-home"
  mkdir -p "$FAKE_HOME"
  # Resolved path: git prints worktrees resolved, and the script compares the
  # main checkout by string equality against $HOME-derived paths.
  FAKE_HOME="$(cd "$FAKE_HOME" && pwd -P)"
}

# Extra VAR=VALUE arguments are forwarded into the script's environment.
run_cleanup() {
  run env HOME="$FAKE_HOME" MORNING_CLEANUP_NO_NOTIFY=1 "$@" bash "$SCRIPT"
}

# Fixture git must not read the invoking user's real ~/.gitconfig (gpg
# signing, hooks templates would break commits in CI-less environments).
fgit() {
  env HOME="$FAKE_HOME" GIT_CONFIG_NOSYSTEM=1 git "$@"
}

# Bare origin + platform clone-equivalent checkout on main, three worktrees:
# merged-clean (tip == origin/main, clean), unmerged (commit ahead of
# origin/main), dirty-merged (tip == origin/main, untracked file).
build_platform_fixture() {
  PLATFORM="$FAKE_HOME/Projects/platform"
  ORIGIN="$FAKE_HOME/origin.git"
  WT_MERGED="$FAKE_HOME/Projects/platform-wt-merged"
  WT_UNMERGED="$FAKE_HOME/Projects/platform-wt-unmerged"
  WT_DIRTY="$FAKE_HOME/Projects/platform-wt-dirty"

  mkdir -p "$FAKE_HOME/Projects"
  fgit init -q "$PLATFORM"
  fgit -C "$PLATFORM" config user.name "Morning Cleanup Test"
  fgit -C "$PLATFORM" config user.email mc@example.invalid
  fgit -C "$PLATFORM" config commit.gpgsign false
  fgit -C "$PLATFORM" checkout -q -b main
  printf 'base\n' > "$PLATFORM/base.txt"
  fgit -C "$PLATFORM" add base.txt
  fgit -C "$PLATFORM" commit -q -m 'base commit'
  fgit init -q --bare "$ORIGIN"
  fgit -C "$PLATFORM" remote add origin "$ORIGIN"
  fgit -C "$PLATFORM" push -q origin main
  # The script's own fetch tolerates failure; the fixture must guarantee
  # refs/remotes/origin/main exists regardless.
  fgit -C "$PLATFORM" fetch -q origin

  fgit -C "$PLATFORM" worktree add -q -b merged-clean "$WT_MERGED"
  fgit -C "$PLATFORM" worktree add -q -b unmerged "$WT_UNMERGED"
  printf 'ahead\n' > "$WT_UNMERGED/ahead.txt"
  fgit -C "$WT_UNMERGED" add ahead.txt
  fgit -C "$WT_UNMERGED" commit -q -m 'unmerged commit'
  fgit -C "$PLATFORM" worktree add -q -b dirty-merged "$WT_DIRTY"
  printf 'dirt\n' > "$WT_DIRTY/untracked.txt"
}

function test_morning_cleanup_001_purge_removes_entries_past_the_age_threshold() {
  _bats_test_init 1 'trash purge removes entries past the age threshold'
  # ctime cannot be backdated (touch -t rewrites it to now), so staleness is
  # simulated by lowering the threshold to 0 instead of aging the entry.
  # Honest limit: this exercises the purge machinery, not the production
  # `-ctime +N` comparison itself -- no fixture can age past a day-granular
  # threshold, so a wrong sign or unit there is only caught by test 002
  # refusing to over-delete, never by a positive aged-removal proof.
  mkdir -p "$FAKE_HOME/.scratchpad/stale-entry"
  printf 'x' > "$FAKE_HOME/.scratchpad/stale-entry/file"
  printf 'y' > "$FAKE_HOME/.scratchpad/stale-file"

  run_cleanup MORNING_CLEANUP_TRASH_MAX_AGE_DAYS=0
  assert_success
  assert_dir_not_exists "$FAKE_HOME/.scratchpad/stale-entry"
  assert_file_not_exists "$FAKE_HOME/.scratchpad/stale-file"
  # -mindepth 1 contract: the trash root itself survives the purge.
  assert_dir_exists "$FAKE_HOME/.scratchpad"
  # Completion proof for the keep-control below: the same stamp shows the
  # default-threshold run also reached the end, not that it crashed early.
  assert_file_exists "$FAKE_HOME/.local/state/morning-cleanup/last-run"
}

function test_morning_cleanup_002_default_threshold_keeps_a_fresh_entry() {
  _bats_test_init 2 'default age threshold keeps a fresh trash entry (purge control)'
  mkdir -p "$FAKE_HOME/.scratchpad/fresh-entry"
  printf 'x' > "$FAKE_HOME/.scratchpad/fresh-entry/file"

  run_cleanup
  assert_success
  assert_file_exists "$FAKE_HOME/.local/state/morning-cleanup/last-run"
  assert_dir_exists "$FAKE_HOME/.scratchpad/fresh-entry"
  assert_file_exists "$FAKE_HOME/.scratchpad/fresh-entry/file"
}

function test_morning_cleanup_003_git_cleanup_removes_only_merged_clean() {
  _bats_test_init 3 'git cleanup removes only the merged-clean worktree and branch'
  build_platform_fixture

  run_cleanup
  assert_success

  run fgit -C "$PLATFORM" worktree list --porcelain
  assert_success
  # Positive control first: degenerate output cannot satisfy the refute.
  assert_output --partial "worktree $WT_UNMERGED"
  assert_output --partial "worktree $WT_DIRTY"
  refute_output --partial "worktree $WT_MERGED"
  assert_dir_not_exists "$WT_MERGED"
  assert_dir_exists "$WT_UNMERGED"
  assert_dir_exists "$WT_DIRTY"
  assert_file_exists "$WT_DIRTY/untracked.txt"

  run fgit -C "$PLATFORM" branch --list
  assert_success
  assert_output --partial "main"
  assert_output --partial "unmerged"
  assert_output --partial "dirty-merged"
  refute_output --partial "merged-clean"

  # The main checkout itself is never a cleanup candidate.
  assert_dir_exists "$PLATFORM"
  assert_file_exists "$PLATFORM/base.txt"
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function tear_down() { _bats_run_teardown; }
