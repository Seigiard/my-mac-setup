#!/usr/bin/env bash
# post-apply: 25 host-safe
# morning-cleanup destructive legs (trash purge, platform worktree/branch
# cleanup, agent sessions, opencode.db compaction), run against the SOURCE
# script under a disposable $HOME — every root the script touches derives from
# $HOME, so the override isolates them.
# Oracle: resulting filesystem state, git's own reports (worktree list,
# branch --list) and sqlite3 queries; no assertion inspects the script's source.
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
  install_docker_fixture
}

# Extra VAR=VALUE arguments are forwarded into the script's environment.
run_cleanup() {
  run env HOME="$FAKE_HOME" MORNING_CLEANUP_NO_NOTIFY=1 \
    MORNING_CLEANUP_DOCKER_CALLS="$DOCKER_CALLS" \
    MORNING_CLEANUP_DOCKER_OBSERVED="$DOCKER_OBSERVED" \
    MORNING_CLEANUP_DOCKER_CONTEXTS="$DOCKER_CONTEXTS" \
    MORNING_CLEANUP_DOCKER_CURRENT="$DOCKER_CURRENT" \
    MORNING_CLEANUP_OSASCRIPT_CALLS="$DOCKER_NOTIFICATIONS" \
    DOCKER_CONFIG="$FAKE_HOME/.docker" \
    DOCKER_HOST="unix://$FAKE_HOME/no-host-daemon.sock" \
    DOCKER_CONTEXT= \
    PATH="$FAKE_HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$@" bash "$SCRIPT"
}

run_cleanup_with_notifications() {
  run env HOME="$FAKE_HOME" \
    MORNING_CLEANUP_DOCKER_CALLS="$DOCKER_CALLS" \
    MORNING_CLEANUP_DOCKER_OBSERVED="$DOCKER_OBSERVED" \
    MORNING_CLEANUP_DOCKER_CONTEXTS="$DOCKER_CONTEXTS" \
    MORNING_CLEANUP_DOCKER_CURRENT="$DOCKER_CURRENT" \
    MORNING_CLEANUP_OSASCRIPT_CALLS="$DOCKER_NOTIFICATIONS" \
    DOCKER_CONFIG="$FAKE_HOME/.docker" \
    DOCKER_HOST="unix://$FAKE_HOME/no-host-daemon.sock" \
    DOCKER_CONTEXT= \
    PATH="$FAKE_HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$@" bash "$SCRIPT"
}

install_docker_fixture() {
  local fixtures="$BATS_TEST_DIRNAME/helpers/morning-cleanup-docker"
  # Every script run also clears DOCKER_CONTEXT and supplies an inert Unix
  # DOCKER_HOST. If production adds Homebrew or Docker.app to PATH, even a real
  # CLI found there cannot fall through to the developer's current daemon.
  DOCKER_CALLS="$FAKE_HOME/docker-destructive-calls"
  DOCKER_OBSERVED="$FAKE_HOME/docker-observed-calls"
  DOCKER_CONTEXTS="$FAKE_HOME/docker-contexts"
  DOCKER_CURRENT="$FAKE_HOME/docker-current"
  DOCKER_NOTIFICATIONS="$FAKE_HOME/osascript-calls"
  mkdir -p "$FAKE_HOME/bin" "$FAKE_HOME/.docker"
  cp "$fixtures/docker" "$FAKE_HOME/bin/docker"
  cp "$fixtures/osascript" "$FAKE_HOME/bin/osascript"
  chmod +x "$FAKE_HOME/bin/docker" "$FAKE_HOME/bin/osascript"
  : >"$DOCKER_CALLS"
  : >"$DOCKER_OBSERVED"
  : >"$DOCKER_NOTIFICATIONS"
  printf '%s\n' \
    'orbstack|unix:///tmp/orbstack.sock' \
    'desktop-linux|unix:///tmp/docker-desktop.sock' \
    'remote|ssh://docker.example.invalid' >"$DOCKER_CONTEXTS"
  printf 'orbstack\n' >"$DOCKER_CURRENT"
}

expected_docker_trace() {
  local endpoint=$1
  printf '%s\n' \
    "$endpoint|builder|all=true|force=true|until=336h|builder=default" \
    "$endpoint|image|all=true|force=true|until=336h|builder=builtin" \
    "$endpoint|network|all=false|force=true|until=336h|builder=builtin"
}

docker_trace() {
  LC_ALL=C sort "$DOCKER_CALLS"
}

docker_summary_value() {
  local summary key pattern value
  summary=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  key=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  case "$key" in
    cache)
      pattern='(^|[,;][[:space:]]*)docker[[:space:]]+cache:[[:space:]]+([0-9]+([.][0-9]+)?(b|kb|mb|gb|tb))([,;]|$)'
      ;;
    image)
      pattern='(^|[,;][[:space:]]*)docker[[:space:]]+images:[[:space:]]+([0-9]+([.][0-9]+)?(b|kb|mb|gb|tb))([,;]|$)'
      ;;
    network)
      pattern='(^|[,;][[:space:]]*)docker[[:space:]]+networks:[[:space:]]+([0-9]+)([,;]|$)'
      ;;
    claude-sessions)
      pattern='(^|[,;][[:space:]]*)claude[[:space:]]+sessions:[[:space:]]+([0-9]+)([,;]|$)'
      ;;
    *) return 2 ;;
  esac
  [[ "$summary" =~ $pattern ]] || return 1
  value=${BASH_REMATCH[2]}
  printf '%s=%s\n' "$key" "$value"
}

notification_semantics() {
  local summary=$1 script count
  count=$(awk 'END { print NR + 0 }' "$DOCKER_NOTIFICATIONS")
  script=$(cat "$DOCKER_NOTIFICATIONS")
  printf 'calls=%s\n' "$count"
  case "$script" in
    *"$summary"*) printf 'message=summary\n' ;;
    *) printf 'message=other\n' ;;
  esac
  case "$script" in
    *'Morning cleanup'*) printf 'title=Morning cleanup\n' ;;
    *) printf 'title=other\n' ;;
  esac
}

log_has_docker_failure() {
  local resource=$1 log="$FAKE_HOME/.local/state/morning-cleanup/cleanup.log"
  grep -Ei "($resource.*(fail|error)|(fail|error).*$resource)" "$log" >/dev/null
}

prune_output_shape() {
  local builder=$1 image=$2 network=$3
  case "$builder" in
    *'Total:'*) printf 'builder=buildx-total\n' ;;
    *'Total reclaimed space:'*) printf 'builder=reclaimed-space\n' ;;
    *) printf 'builder=unknown\n' ;;
  esac
  case "$image" in
    *'Total reclaimed space:'*) printf 'image=reclaimed-space\n' ;;
    *) printf 'image=unknown\n' ;;
  esac
  case "$network" in
    *'Deleted Networks:'*) printf 'network=deleted-list\n' ;;
    *) printf 'network=unknown\n' ;;
  esac
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

# A WAL-mode opencode.db with two tables of 2560 rows of 4000 bytes, one page
# per row at a 4096-byte page size. One table stays live; the other is deleted
# and leaves 10510336 bytes of free pages. The file is 21032960 bytes (20 MB);
# compacted it is 10522624 (10 MB). These sizes were measured with sqlite3 3.54
# and stay fixed because the page size and the row layout are fixed. auto_vacuum
# is pinned off, as in opencode.db: the macOS CI runner's sqlite3 defaults it on,
# which shrinks the file on delete and adds pointer-map pages. The free-page
# total sits between the 10 MB and 11 MB thresholds, while the file is above
# both, so the two thresholds tell a free-page gate from a size gate.
build_opencode_db_fixture() {
  command -v sqlite3 >/dev/null || skip 'sqlite3 not installed'
  command -v lsof >/dev/null || skip 'lsof not installed'
  OC_DB="$FAKE_HOME/.local/share/opencode/opencode.db"
  mkdir -p "$(dirname "$OC_DB")"
  sqlite3 "$OC_DB" "pragma page_size = 4096; pragma auto_vacuum = none; pragma journal_mode = wal;
    create table keep (v blob); create table gone (v blob);
    with recursive n(i) as (select 1 union all select i + 1 from n where i < 2560)
      insert into keep select zeroblob(4000) from n;
    with recursive n(i) as (select 1 union all select i + 1 from n where i < 2560)
      insert into gone select zeroblob(4000) from n;
    delete from gone;" >/dev/null
}

db_bytes() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

function test_morning_cleanup_007_opencode_db_free_pages_past_threshold_are_reclaimed() {
  _bats_test_init 7 'opencode.db is vacuumed when its free pages reach the threshold, with a backup in the trash'
  build_opencode_db_fixture

  run_cleanup MORNING_CLEANUP_OPENCODE_DB_RECLAIM_MB=10
  assert_success

  run db_bytes "$OC_DB"
  assert_output '10522624'
  run sqlite3 "$OC_DB" 'select count(*) from keep'
  assert_success
  assert_output '2560'
  run sqlite3 "$FAKE_HOME"/.scratchpad/opencode-db-backup-*.db 'select count(*) from keep'
  assert_success
  assert_output '2560'
  run last_summary
  assert_output 'omc: 0, worktrees: 0, branches: 0, trash: 0, claude sessions: 0, pi sessions: 0, opencode sessions: 0, opencode-db: 20 MB -> 10 MB'
}

function test_morning_cleanup_008_opencode_db_free_pages_below_threshold_stay() {
  _bats_test_init 8 'opencode.db stays untouched and unreported while its free pages are below the threshold'
  build_opencode_db_fixture

  run_cleanup MORNING_CLEANUP_OPENCODE_DB_RECLAIM_MB=11
  assert_success

  run db_bytes "$OC_DB"
  assert_output '21032960'
  run find "$FAKE_HOME/.scratchpad" -name 'opencode-db-backup-*'
  assert_success
  assert_output ''
  run last_summary
  assert_output 'omc: 0, worktrees: 0, branches: 0, trash: 0, claude sessions: 0, pi sessions: 0, opencode sessions: 0'
}

function test_morning_cleanup_009_opencode_db_in_use_is_not_vacuumed() {
  _bats_test_init 9 'opencode.db is not vacuumed while a process holds it open'
  build_opencode_db_fixture
  sleep 60 3<"$OC_DB" &
  local holder=$!

  run_cleanup MORNING_CLEANUP_OPENCODE_DB_RECLAIM_MB=10
  kill "$holder"
  assert_success

  run db_bytes "$OC_DB"
  assert_output '21032960'
  run last_summary
  assert_output 'omc: 0, worktrees: 0, branches: 0, trash: 0, claude sessions: 0, pi sessions: 0, opencode sessions: 0'
}

function test_morning_cleanup_010_scheduled_path_reaches_an_installed_docker_cli() {
  _bats_test_init 10 'the launchd PATH reaches an installed Docker CLI without an interactive shell'
  local scheduled_path='/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin'
  PATH="$scheduled_path" command -v docker >/dev/null ||
    skip 'Docker CLI is not installed in the scheduled-job discovery PATH'
  rm "$FAKE_HOME/bin/docker"

  run env HOME="$FAKE_HOME" MORNING_CLEANUP_NO_NOTIFY=1 \
    DOCKER_CONFIG="$FAKE_HOME/.docker" \
    DOCKER_HOST="unix://$FAKE_HOME/no-host-daemon.sock" \
    DOCKER_CONTEXT= \
    PATH='/usr/bin:/bin:/usr/sbin:/sbin' bash "$SCRIPT"
  assert_success
  run grep -Ei 'docker.*(unavailable|cannot connect)|cannot connect.*docker' \
    "$FAKE_HOME/.local/state/morning-cleanup/cleanup.log"
  assert_success
}

function test_morning_cleanup_011_missing_docker_cli_is_logged_when_no_discovery_path_has_it() {
  _bats_test_init 11 'a missing Docker CLI is logged and does not abort the existing cleanup'
  local scheduled_path='/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin'
  PATH="$scheduled_path" command -v docker >/dev/null &&
    skip 'Docker CLI is reachable in the scheduled-job discovery PATH'
  rm "$FAKE_HOME/bin/docker"
  build_platform_fixture

  run env HOME="$FAKE_HOME" MORNING_CLEANUP_NO_NOTIFY=1 \
    DOCKER_CONFIG="$FAKE_HOME/.docker" \
    DOCKER_HOST="unix://$FAKE_HOME/no-host-daemon.sock" \
    DOCKER_CONTEXT= \
    PATH='/usr/bin:/bin:/usr/sbin:/sbin' bash "$SCRIPT"
  assert_success
  run grep -Ei 'docker.*(not found|missing)' "$FAKE_HOME/.local/state/morning-cleanup/cleanup.log"
  assert_success
  assert_dir_not_exists "$WT_MERGED"
}

function test_morning_cleanup_012_current_context_changes_the_local_target() {
  _bats_test_init 12 'changing the current local context changes the cleanup target'

  run_cleanup MORNING_CLEANUP_DOCKER_FIXTURE=success DOCKER_HOST= DOCKER_CONTEXT= \
    BUILDX_BUILDER=external-cache
  assert_success
  run docker_trace
  assert_success
  assert_output "$(expected_docker_trace unix:///tmp/orbstack.sock)"

  printf 'desktop-linux\n' >"$DOCKER_CURRENT"
  printf '1999-12-31\n' >"$FAKE_HOME/.local/state/morning-cleanup/last-run"
  : >"$DOCKER_CALLS"
  run_cleanup MORNING_CLEANUP_DOCKER_FIXTURE=success DOCKER_HOST= DOCKER_CONTEXT= \
    BUILDX_BUILDER=external-cache
  assert_success
  run docker_trace
  assert_success
  assert_output "$(expected_docker_trace unix:///tmp/docker-desktop.sock)"
}

function test_morning_cleanup_013_docker_host_overrides_docker_context() {
  _bats_test_init 13 'DOCKER_HOST overrides DOCKER_CONTEXT when selecting the cleanup daemon'

  run_cleanup MORNING_CLEANUP_DOCKER_FIXTURE=success \
    DOCKER_HOST='ssh://wrong.example.invalid' DOCKER_CONTEXT=desktop-linux
  assert_success
  run docker_trace
  assert_success
  assert_output ''
  run grep -F 'ssh://wrong.example.invalid' "$FAKE_HOME/.local/state/morning-cleanup/cleanup.log"
  assert_success
}

function test_morning_cleanup_014_explicit_docker_host_does_not_require_context_inspection() {
  _bats_test_init 14 'an explicit local DOCKER_HOST can be used without inspecting a context'

  run_cleanup MORNING_CLEANUP_DOCKER_FIXTURE=context-unavailable \
    DOCKER_HOST='unix:///tmp/explicit.sock' DOCKER_CONTEXT=
  assert_success
  run docker_trace
  assert_success
  assert_output "$(expected_docker_trace unix:///tmp/explicit.sock)"
}

function test_morning_cleanup_015_local_docker_host_overrides_remote_context() {
  _bats_test_init 15 'a local DOCKER_HOST overrides a remote DOCKER_CONTEXT'

  run_cleanup MORNING_CLEANUP_DOCKER_FIXTURE=success \
    DOCKER_HOST='unix:///tmp/wrong-local.sock' DOCKER_CONTEXT=remote
  assert_success
  run docker_trace
  assert_success
  assert_output "$(expected_docker_trace unix:///tmp/wrong-local.sock)"
}

function test_morning_cleanup_016_one_daemon_stays_fixed_when_current_context_changes_mid_stage() {
  _bats_test_init 16 'all Docker cleanup steps keep one target when the current context changes mid-stage'

  run_cleanup MORNING_CLEANUP_DOCKER_FIXTURE=success DOCKER_HOST= DOCKER_CONTEXT= \
    MORNING_CLEANUP_DOCKER_SWITCH_TO=desktop-linux
  assert_success
  run docker_trace
  assert_success
  assert_output "$(expected_docker_trace unix:///tmp/orbstack.sock)"
  run cat "$DOCKER_CURRENT"
  assert_success
  assert_output 'desktop-linux'
}

function test_morning_cleanup_017_unavailable_daemon_is_logged_while_other_cleanup_continues() {
  _bats_test_init 17 'an unavailable Docker daemon is logged while existing cleanup continues'
  build_platform_fixture

  run_cleanup MORNING_CLEANUP_DOCKER_FIXTURE=unavailable
  assert_success
  run grep -Ei 'docker.*(unavailable|cannot connect)|cannot connect.*docker' \
    "$FAKE_HOME/.local/state/morning-cleanup/cleanup.log"
  assert_success
  assert_dir_not_exists "$WT_MERGED"
  run docker_trace
  assert_success
  assert_output ''
}

function test_morning_cleanup_018_failed_builder_prune_does_not_stop_later_steps() {
  _bats_test_init 18 'a failed builder prune is logged and image and network pruning continue'

  run_cleanup MORNING_CLEANUP_DOCKER_FIXTURE=fail-builder
  assert_success
  run docker_trace
  assert_success
  assert_output "$(expected_docker_trace "unix://$FAKE_HOME/no-host-daemon.sock")"
  run log_has_docker_failure builder
  assert_success
}

function test_morning_cleanup_019_failed_image_prune_does_not_stop_network_cleanup() {
  _bats_test_init 19 'a failed image prune is logged and network pruning continues'

  run_cleanup MORNING_CLEANUP_DOCKER_FIXTURE=fail-image
  assert_success
  run docker_trace
  assert_success
  assert_output "$(expected_docker_trace "unix://$FAKE_HOME/no-host-daemon.sock")"
  run log_has_docker_failure image
  assert_success
}

function test_morning_cleanup_020_failed_network_prune_keeps_the_completed_prior_steps() {
  _bats_test_init 20 'a failed network prune is logged after builder and image pruning complete'

  run_cleanup MORNING_CLEANUP_DOCKER_FIXTURE=fail-network
  assert_success
  run docker_trace
  assert_success
  assert_output "$(expected_docker_trace "unix://$FAKE_HOME/no-host-daemon.sock")"
  run log_has_docker_failure network
  assert_success
}

function test_morning_cleanup_021_failure_stamp_uses_date_content_and_retries_next_day() {
  _bats_test_init 21 'a failed Docker step stamps today, skips the same day, and retries after old stamp content'
  local first_trace expected_twice today
  today=$(date +%Y-%m-%d)

  run_cleanup MORNING_CLEANUP_DOCKER_FIXTURE=fail-image
  assert_success
  first_trace=$(docker_trace)
  assert_equal "$first_trace" "$(expected_docker_trace "unix://$FAKE_HOME/no-host-daemon.sock")"
  run cat "$FAKE_HOME/.local/state/morning-cleanup/last-run"
  assert_success
  assert_output "$today"

  run_cleanup MORNING_CLEANUP_DOCKER_FIXTURE=fail-image
  assert_success
  run docker_trace
  assert_success
  assert_output "$first_trace"

  printf '1999-12-31\n' >"$FAKE_HOME/.local/state/morning-cleanup/last-run"
  run_cleanup MORNING_CLEANUP_DOCKER_FIXTURE=fail-image
  assert_success
  expected_twice=$(printf '%s\n%s\n' "$first_trace" "$first_trace" | LC_ALL=C sort)
  run docker_trace
  assert_success
  assert_output "$expected_twice"
}

function test_morning_cleanup_022_docker_deletions_are_reported_in_summary_and_notification() {
  _bats_test_init 22 'Docker reclaimed space and deleted-network count enter the summary and notification'
  local summary

  run_cleanup_with_notifications MORNING_CLEANUP_DOCKER_FIXTURE=success
  assert_success
  run last_summary
  assert_success
  summary=$output
  run docker_summary_value "$summary" cache
  assert_success
  assert_output 'cache=1.25gb'
  run docker_summary_value "$summary" image
  assert_success
  assert_output 'image=42.5mb'
  run docker_summary_value "$summary" network
  assert_success
  assert_output 'network=2'
  run notification_semantics "$summary"
  assert_success
  assert_output $'calls=1\nmessage=summary\ntitle=Morning cleanup'
}

function test_morning_cleanup_023_docker_noop_reports_zero_without_notifying() {
  _bats_test_init 23 'a Docker no-op reports zero reclamation and does not notify by itself'
  local summary

  run_cleanup_with_notifications MORNING_CLEANUP_DOCKER_FIXTURE=noop
  assert_success
  run last_summary
  assert_success
  summary=$output
  run docker_summary_value "$summary" cache
  assert_success
  assert_output 'cache=0b'
  run docker_summary_value "$summary" image
  assert_success
  assert_output 'image=0b'
  run docker_summary_value "$summary" network
  assert_success
  assert_output 'network=0'
  run cat "$DOCKER_NOTIFICATIONS"
  assert_success
  assert_output ''
}

function test_morning_cleanup_024_zero_space_deletion_still_notifies() {
  _bats_test_init 24 'a Docker deletion that reports zero reclaimed space still notifies'
  local summary

  run_cleanup_with_notifications MORNING_CLEANUP_DOCKER_FIXTURE=legacy-zero-space-deletion
  assert_success
  run last_summary
  assert_success
  summary=$output
  run docker_summary_value "$summary" cache
  assert_success
  assert_output 'cache=0b'
  run notification_semantics "$summary"
  assert_success
  assert_output $'calls=1\nmessage=summary\ntitle=Morning cleanup'
}

function test_morning_cleanup_025_notification_switch_suppresses_docker_deletion_notice() {
  _bats_test_init 25 'the existing notification switch suppresses a Docker deletion notification'

  run_cleanup MORNING_CLEANUP_DOCKER_FIXTURE=success
  assert_success
  run docker_trace
  assert_success
  assert_output "$(expected_docker_trace "unix://$FAKE_HOME/no-host-daemon.sock")"
  run cat "$DOCKER_NOTIFICATIONS"
  assert_success
  assert_output ''
}

function test_morning_cleanup_026_docker_error_alone_does_not_notify() {
  _bats_test_init 26 'a Docker error alone does not send a deletion notification'

  run_cleanup_with_notifications MORNING_CLEANUP_DOCKER_FIXTURE=error-only-image
  assert_success
  run docker_trace
  assert_success
  assert_output "$(expected_docker_trace "unix://$FAKE_HOME/no-host-daemon.sock")"
  run log_has_docker_failure image
  assert_success
  run grep -F 'docker images prune failed: Error response from daemon: prune rejected by daemon' \
    "$FAKE_HOME/.local/state/morning-cleanup/cleanup.log"
  assert_success
  run cat "$DOCKER_NOTIFICATIONS"
  assert_success
  assert_output ''
}

function test_morning_cleanup_027_docker_noop_preserves_existing_cleanup_notification() {
  _bats_test_init 27 'a Docker no-op does not suppress a notification for another cleanup stage'
  local claude="$FAKE_HOME/.claude/projects/-project-/aged" summary
  mkdir -p "$claude"
  printf 'aged\n' >"$claude.jsonl"
  backdate_days 92 "$claude.jsonl"

  run_cleanup_with_notifications MORNING_CLEANUP_DOCKER_FIXTURE=noop
  assert_success
  run last_summary
  assert_success
  summary=$output
  run docker_trace
  assert_success
  assert_output "$(expected_docker_trace "unix://$FAKE_HOME/no-host-daemon.sock")"
  run docker_summary_value "$summary" cache
  assert_success
  assert_output 'cache=0b'
  run docker_summary_value "$summary" claude-sessions
  assert_success
  assert_output 'claude-sessions=1'
  run notification_semantics "$summary"
  assert_success
  assert_output $'calls=1\nmessage=summary\ntitle=Morning cleanup'
}

function test_morning_cleanup_028_fake_prune_output_matches_a_prepared_disposable_daemon() {
  _bats_test_init 28 'Docker fake output markers match a prepared disposable daemon'
  [[ "${MORNING_CLEANUP_DOCKER_CALIBRATION_CONFIRM:-}" == disposable ]] ||
    skip 'prepared disposable Docker daemon not confirmed for output calibration'
  [[ "${MORNING_CLEANUP_DISPOSABLE_DOCKER_HOST:-}" == unix://* ]] ||
    skip 'disposable Docker Unix socket not provided for output calibration'
  command -v docker >/dev/null || skip 'real Docker CLI not installed for output calibration'
  local real_builder real_image real_network fake_builder fake_image fake_network real_shape

  # `until=0h` permits recent resources on this confirmed disposable daemon.
  # This calibrates consumed output shape, not Docker retention semantics.
  real_builder=$(env DOCKER_HOST= DOCKER_CONTEXT= BUILDX_BUILDER=default \
    docker --host "$MORNING_CLEANUP_DISPOSABLE_DOCKER_HOST" builder prune \
    --all --force --filter until=0h) || fail 'real builder prune failed on disposable daemon'
  real_image=$(env DOCKER_HOST= DOCKER_CONTEXT= BUILDX_BUILDER=default \
    docker --host "$MORNING_CLEANUP_DISPOSABLE_DOCKER_HOST" image prune \
    --all --force --filter until=0h) || fail 'real image prune failed on disposable daemon'
  real_network=$(env DOCKER_HOST= DOCKER_CONTEXT= BUILDX_BUILDER=default \
    docker --host "$MORNING_CLEANUP_DISPOSABLE_DOCKER_HOST" network prune \
    --force --filter until=0h) || fail 'real network prune failed on disposable daemon'
  real_shape=$(prune_output_shape "$real_builder" "$real_image" "$real_network")

  fake_builder=$(env MORNING_CLEANUP_DOCKER_FIXTURE=success \
    MORNING_CLEANUP_DOCKER_CALLS="$DOCKER_CALLS" MORNING_CLEANUP_DOCKER_OBSERVED="$DOCKER_OBSERVED" \
    MORNING_CLEANUP_DOCKER_CONTEXTS="$DOCKER_CONTEXTS" MORNING_CLEANUP_DOCKER_CURRENT="$DOCKER_CURRENT" \
    DOCKER_HOST='unix:///tmp/calibration.sock' DOCKER_CONTEXT= BUILDX_BUILDER=default \
    "$FAKE_HOME/bin/docker" builder prune --all --force --filter until=0h)
  fake_image=$(env MORNING_CLEANUP_DOCKER_FIXTURE=success \
    MORNING_CLEANUP_DOCKER_CALLS="$DOCKER_CALLS" MORNING_CLEANUP_DOCKER_OBSERVED="$DOCKER_OBSERVED" \
    MORNING_CLEANUP_DOCKER_CONTEXTS="$DOCKER_CONTEXTS" MORNING_CLEANUP_DOCKER_CURRENT="$DOCKER_CURRENT" \
    DOCKER_HOST='unix:///tmp/calibration.sock' DOCKER_CONTEXT= BUILDX_BUILDER=default \
    "$FAKE_HOME/bin/docker" image prune --all --force --filter until=0h)
  fake_network=$(env MORNING_CLEANUP_DOCKER_FIXTURE=success \
    MORNING_CLEANUP_DOCKER_CALLS="$DOCKER_CALLS" MORNING_CLEANUP_DOCKER_OBSERVED="$DOCKER_OBSERVED" \
    MORNING_CLEANUP_DOCKER_CONTEXTS="$DOCKER_CONTEXTS" MORNING_CLEANUP_DOCKER_CURRENT="$DOCKER_CURRENT" \
    DOCKER_HOST='unix:///tmp/calibration.sock' DOCKER_CONTEXT= BUILDX_BUILDER=default \
    "$FAKE_HOME/bin/docker" network prune --force --filter until=0h)
  run prune_output_shape "$fake_builder" "$fake_image" "$fake_network"
  assert_success
  assert_output "$real_shape"
}

function test_morning_cleanup_029_buildx_zero_space_row_is_a_deletion() {
  _bats_test_init 29 'a Buildx table row with 0B still reports a cache deletion and notifies'
  local summary

  run_cleanup_with_notifications MORNING_CLEANUP_DOCKER_FIXTURE=zero-space-deletion
  assert_success
  run last_summary
  assert_success
  summary=$output
  run docker_summary_value "$summary" cache
  assert_success
  assert_output 'cache=0b'
  run notification_semantics "$summary"
  assert_success
  assert_output $'calls=1\nmessage=summary\ntitle=Morning cleanup'
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function tear_down() { _bats_run_teardown; }
