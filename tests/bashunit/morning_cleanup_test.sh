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

# No positive aged-removal test: `-ctime +N` cannot be reached by a fixture,
# because ctime cannot be backdated (touch -t rewrites it to now). The former
# test 001 drove a threshold-0 branch that existed in the script for that test
# alone and never exercised the shipped comparison. The keep half of the purge
# contract is owned by 002 below; the removal half is uncovered.
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

  # Exact listing, not per-branch partials: git prints these three names sorted
  # and nothing else, so the whole set is the oracle. It states in one assertion
  # that merged-clean is gone and that the three survivors are untouched —
  # over-deletion and under-deletion both fail here.
  run fgit -C "$PLATFORM" branch --list --format='%(refname:short)'
  assert_success
  assert_output $'dirty-merged\nmain\nunmerged'

  # The main checkout itself is never a cleanup candidate.
  assert_dir_exists "$PLATFORM"
  assert_file_exists "$PLATFORM/base.txt"
}

last_summary() {
  grep ' done — ' "$FAKE_HOME/.local/state/morning-cleanup/cleanup.log" | tail -n 1 | sed 's/^.* done — //'
}

backdate_days() {
  local stamp=$(($(date +%s) - $1 * 86400))
  touch -t "$(date -r "$stamp" +%Y%m%d%H%M 2>/dev/null || date -d "@$stamp" +%Y%m%d%H%M)" "$2"
}

# Claude Code and Pi append to one .jsonl per session on every turn, so mtime
# is the idle age. 92 and 88 days straddle the 90-day retention from issue
# #426, shared by every agent. Each session's same-named sibling directory
# holds its subagent runs and must leave with it.
function test_morning_cleanup_004_claude_and_pi_sessions_idle_past_90_days_go_to_trash() {
  _bats_test_init 4 'Claude Code and Pi sessions idle past 90 days move to the trash; recent ones stay'
  local claude="$FAKE_HOME/.claude/projects/-project-" pi="$FAKE_HOME/.pi/agent/sessions/--project--"
  local dir
  for dir in "$claude" "$pi"; do
    mkdir -p "$dir/aged/subagents" "$dir/recent"
    printf 'aged\n' > "$dir/aged.jsonl"
    printf 'run\n' > "$dir/aged/subagents/run.jsonl"
    printf 'recent\n' > "$dir/recent.jsonl"
    backdate_days 92 "$dir/aged.jsonl"
    backdate_days 88 "$dir/recent.jsonl"
  done

  run_cleanup
  assert_success

  for dir in "$claude" "$pi"; do
    assert_file_not_exists "$dir/aged.jsonl"
    assert_dir_not_exists "$dir/aged"
    assert_file_exists "$dir/recent.jsonl"
    assert_dir_exists "$dir/recent"
  done
  run cat "$FAKE_HOME"/.scratchpad/claude-session-*-aged.jsonl "$FAKE_HOME"/.scratchpad/claude-session-*-aged/subagents/run.jsonl \
    "$FAKE_HOME"/.scratchpad/pi-session-*-aged.jsonl "$FAKE_HOME"/.scratchpad/pi-session-*-aged/subagents/run.jsonl
  assert_success
  assert_output $'aged\nrun\naged\nrun'
  run last_summary
  assert_output 'omc: 0, worktrees: 0, branches: 0, trash: 0, claude sessions: 1, pi sessions: 1, opencode sessions: 0'
}

# Fixture opencode.db with the session columns the leg reads, and an opencode
# stub on PATH that records each `session delete` id and removes the row the
# way the real command does. Rows: an aged root, a recent root, and an aged
# subagent session of the recent root.
build_opencode_fixture() {
  command -v sqlite3 >/dev/null || skip 'sqlite3 not installed'
  command -v lsof >/dev/null || skip 'lsof not installed'
  OC_DB="$FAKE_HOME/.local/share/opencode/opencode.db"
  OC_CALLS="$FAKE_HOME/opencode-calls"
  mkdir -p "$(dirname "$OC_DB")" "$FAKE_HOME/bin"
  local now_ms=$(($(date +%s) * 1000)) day_ms=86400000
  sqlite3 "$OC_DB" "create table session (id text primary key, parent_id text, time_updated integer);
    insert into session values
      ('ses_aged', null, $((now_ms - 92 * day_ms))),
      ('ses_recent', null, $((now_ms - 88 * day_ms))),
      ('ses_agedchild', 'ses_recent', $((now_ms - 92 * day_ms)));"
  cat > "$FAKE_HOME/bin/opencode" <<EOF
#!/usr/bin/env bash
[[ "\$1 \$2" == 'session delete' ]] || exit 2
id="\${*: -1}"
printf '%s\n' "\$id" >> '$OC_CALLS'
sqlite3 '$OC_DB' "delete from session where id = '\$id'"
EOF
  chmod +x "$FAKE_HOME/bin/opencode"
}

function test_morning_cleanup_005_opencode_deletes_only_aged_root_sessions() {
  _bats_test_init 5 'OpenCode root sessions idle past 90 days are deleted through the CLI'
  build_opencode_fixture

  run_cleanup PATH="$FAKE_HOME/bin:$PATH"
  assert_success

  run cat "$OC_CALLS"
  assert_success
  assert_output 'ses_aged'
  run sqlite3 "$OC_DB" 'select id from session order by id'
  assert_success
  assert_output $'ses_agedchild\nses_recent'
  run last_summary
  assert_output 'omc: 0, worktrees: 0, branches: 0, trash: 0, claude sessions: 0, pi sessions: 0, opencode sessions: 1'
}

function test_morning_cleanup_006_opencode_leg_skips_a_database_in_use() {
  _bats_test_init 6 'OpenCode sessions stay while a process holds the database open'
  build_opencode_fixture
  sleep 60 3<"$OC_DB" &
  local holder=$!

  run_cleanup PATH="$FAKE_HOME/bin:$PATH"
  kill "$holder"
  assert_success

  assert_file_not_exists "$OC_CALLS"
  run sqlite3 "$OC_DB" 'select id from session order by id'
  assert_success
  assert_output $'ses_aged\nses_agedchild\nses_recent'
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function tear_down() { _bats_run_teardown; }
