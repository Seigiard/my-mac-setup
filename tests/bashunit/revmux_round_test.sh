#!/usr/bin/env bash
# post-apply: 27 host-safe
# revmux-round command contract. The fixture Git history and the real revmux
# setup command are independent inputs; tests exercise only the local wrapper.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/common'

setup() {
  SCRIPT="$SOURCE_ROOT/private_dot_agents/skills/code-review/scripts/executable_revmux-round.sh"
  REAL_REVMUX="$(command -v revmux || true)"
  export REAL_REVMUX
}

function tear_down_after_script() {
  _bats_file_cleanup
}

require_revmux() {
  if [ -z "$REAL_REVMUX" ] || ! "$REAL_REVMUX" --version >/dev/null 2>&1; then
    skip "revmux is not installed"
  fi
}

make_round_fixture() {
  local goal_text="${1:-fixture goal}"
  local task="${2:-fixture}"

  FIXTURE_REPO="$BATS_TEST_TMPDIR/repo-$task"
  TASKS_DIR="$(cd "$BATS_TEST_TMPDIR" && pwd)/tasks"
  mkdir -p "$FIXTURE_REPO"
  git -C "$FIXTURE_REPO" init -q
  git -C "$FIXTURE_REPO" config user.email fixture@example.test
  git -C "$FIXTURE_REPO" config user.name Fixture
  printf 'base\n' > "$FIXTURE_REPO/base.txt"
  git -C "$FIXTURE_REPO" add base.txt
  git -C "$FIXTURE_REPO" commit -qm base
  FIXTURE_BASE="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
  printf 'alpha\n' > "$FIXTURE_REPO/alpha.txt"
  printf 'beta\n' > "$FIXTURE_REPO/beta.txt"
  git -C "$FIXTURE_REPO" add alpha.txt beta.txt
  git -C "$FIXTURE_REPO" commit -qm 'add fixture files'
  FIXTURE_TIP="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
  FIXTURE_COMMITS="$(git -C "$FIXTURE_REPO" log --oneline "$FIXTURE_BASE..HEAD")"
  FIXTURE_CHANGED="$(git -C "$FIXTURE_REPO" diff --name-status "$FIXTURE_BASE..HEAD")"

  "$REAL_REVMUX" new --tasks-dir "$TASKS_DIR" --task "$task" --run 01-initial \
    > "$BATS_TEST_TMPDIR/new-$task.json"
  PREVIOUS_ROUND="$(jq -r .round_dir "$BATS_TEST_TMPDIR/new-$task.json")"
  cat > "$TASKS_DIR/$task/task.md" <<EOF
---
base: $FIXTURE_BASE
---

# Fixture task
EOF
  printf '%s' "$goal_text" > "$PREVIOUS_ROUND/input/goal.md"
  mkdir -p "$PREVIOUS_ROUND/input/context"
  printf 'fixture context\nwith a second line\n' > "$PREVIOUS_ROUND/input/context/review.md"
  printf 'fixture profile\n' > "$PREVIOUS_ROUND/input/profile.md"
}

expected_scope() {
  local note="$1"
  local exclusions="${2:-}"
  local exclusion_section=""
  if [ -n "$exclusions" ]; then
    exclusion_section=$'\n\n'"$exclusions"
  fi
  cat <<EOF
# Scope

Round 02-after-fix of task fixture: review the cumulative change against base $FIXTURE_BASE, including the fixes since the previous round.

Tip: $FIXTURE_TIP
Scale: 2 files changed, 2 insertions(+)

Read the change:

\`\`\`
git diff $FIXTURE_BASE..HEAD
git log --oneline $FIXTURE_BASE..HEAD
\`\`\`

Commits:

\`\`\`
$FIXTURE_COMMITS
\`\`\`

Changed files:

\`\`\`
$FIXTURE_CHANGED
\`\`\`${exclusion_section}

## ROUND 02 UPDATE

$note
EOF
}

install_revmux_shim() {
  SHIM_BIN="$BATS_TEST_TMPDIR/shim-bin"
  REVMUX_SHIM_RUN_ARGS="$BATS_TEST_TMPDIR/revmux-run-args"
  export REVMUX_SHIM_RUN_ARGS
  mkdir -p "$SHIM_BIN"
  cat > "$SHIM_BIN/revmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  new|config|--version|--help) exec "$REAL_REVMUX" "$@" ;;
esac
  printf '%s\n' "$@" > "$REVMUX_SHIM_RUN_ARGS"
  sleep "${REVMUX_SHIM_DELAY:-0}"
  printf 'shim json\n'
  printf 'shim log\n' >&2
  exit "${REVMUX_SHIM_STATUS:-0}"
SH
  chmod +x "$SHIM_BIN/revmux"
}

install_revmux_kill_parent_shim() {
  SHIM_BIN="$BATS_TEST_TMPDIR/kill-parent-shim-bin"
  REVMUX_SHIM_WRAPPER_PID="$BATS_TEST_TMPDIR/revmux-wrapper-pid"
  export REVMUX_SHIM_WRAPPER_PID
  mkdir -p "$SHIM_BIN"
  cat > "$SHIM_BIN/revmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  new|config|--version|--help) exec "$REAL_REVMUX" "$@" ;;
esac
printf '%s\n' "$PPID" > "$REVMUX_SHIM_WRAPPER_PID"
kill -9 "$PPID"
exit 0
SH
  chmod +x "$SHIM_BIN/revmux"
}

run_prepare_only() {
  run bash "$SCRIPT" next --task fixture --tasks-dir "$TASKS_DIR" \
    --workdir "$FIXTURE_REPO" --prepare-only "$@"
}

write_valid_candidate() {
  cat > "$1" <<'JSON'
{
  "artifact.name": "alerter-26.5.tar.gz",
  "sha-256": "0123456789abcdef",
  "build_version": "26.5",
  "revision2": "final"
}
JSON
}

expected_candidate_scope() {
  cat <<EOF
# Scope

Round 02-after-fix of task fixture: review the cumulative change against base $FIXTURE_BASE, including the fixes since the previous round.

Tip: $FIXTURE_TIP
Scale: 2 files changed, 2 insertions(+)

Read the change:

\`\`\`
git diff $FIXTURE_BASE..HEAD
git log --oneline $FIXTURE_BASE..HEAD
\`\`\`

Commits:

\`\`\`
$FIXTURE_COMMITS
\`\`\`

Changed files:

\`\`\`
$FIXTURE_CHANGED
\`\`\`

Candidate:

artifact.name: alerter-26.5.tar.gz
sha-256: 0123456789abcdef
build_version: 26.5
revision2: final
EOF
}

function test_revmux_round_001_next_writes_the_authored_git_facts_and_argument_note() {
  _bats_test_init 1 'next writes fixture Git facts in the prescribed scope layout'
  require_revmux
  make_round_fixture

  run_prepare_only --note 'review the fixture change'
  assert_success
  assert_line -n 3 "scope: $TASKS_DIR/fixture/02-after-fix/input/scope.md"

  run cat "$TASKS_DIR/fixture/02-after-fix/input/scope.md"
  assert_success
  assert_output "$(expected_scope 'review the fixture change')"
}

function test_revmux_round_002_next_reads_the_update_note_from_standard_input() {
  _bats_test_init 2 'next reads a scope update note from standard input'
  require_revmux
  make_round_fixture

  run bash -c 'printf %s "$1" | bash "$2" next --task fixture --tasks-dir "$3" --workdir "$4" --prepare-only --note -' \
    bash 'review from standard input' "$SCRIPT" "$TASKS_DIR" "$FIXTURE_REPO"
  assert_success

  run cat "$TASKS_DIR/fixture/02-after-fix/input/scope.md"
  assert_success
  assert_output "$(expected_scope 'review from standard input')"
}

function test_revmux_round_003_next_copies_the_previous_goal_and_context_without_profile() {
  _bats_test_init 3 'next carries forward the goal and context but not the round profile'
  require_revmux
  make_round_fixture

  run_prepare_only --note 'copy fixture inputs'
  assert_success
  local round="$TASKS_DIR/fixture/02-after-fix/input"

  run cmp "$PREVIOUS_ROUND/input/goal.md" "$round/goal.md"
  assert_success
  run cmp "$PREVIOUS_ROUND/input/context/review.md" "$round/context/review.md"
  assert_success
  assert_file_not_exists "$round/profile.md"
}

function test_revmux_round_005_next_rejects_an_over_limit_scope_without_launching() {
  _bats_test_init 5 'next rejects an oversized scope before the review launch'
  require_revmux
  make_round_fixture
  install_revmux_shim
  local note
  note="$(LC_ALL=C head -c 1400 /dev/zero | tr '\0' x)"

  run env PATH="$SHIM_BIN:$PATH" bash "$SCRIPT" next --task fixture --tasks-dir "$TASKS_DIR" \
    --workdir "$FIXTURE_REPO" --out-dir "$BATS_TEST_TMPDIR/out" --note "$note" --wait
  assert_failure 1
  assert_output --regexp '^error: Note section makes scope\.md [0-9]+ characters; the limit is 1500$'
  assert_dir_not_exists "$TASKS_DIR/fixture/02-after-fix"
  assert_file_not_exists "$REVMUX_SHIM_RUN_ARGS"
}

function test_revmux_round_006_next_rejects_an_over_limit_goal_without_launching() {
  _bats_test_init 6 'next rejects an oversized carried-forward goal before launch'
  require_revmux
  local goal
  goal="$(LC_ALL=C head -c 1001 /dev/zero | tr '\0' g)"
  make_round_fixture "$goal"
  install_revmux_shim

  run env PATH="$SHIM_BIN:$PATH" bash "$SCRIPT" next --task fixture --tasks-dir "$TASKS_DIR" \
    --workdir "$FIXTURE_REPO" --out-dir "$BATS_TEST_TMPDIR/out" --note 'short update' --wait
  assert_failure 1
  assert_output 'error: goal.md is 1001 characters; the limit is 1000'
  assert_dir_not_exists "$TASKS_DIR/fixture/02-after-fix"
  assert_file_not_exists "$REVMUX_SHIM_RUN_ARGS"
}

function test_revmux_round_007_next_launches_with_the_orchestrator_arguments_and_files() {
  _bats_test_init 7 'next launches revmux with named outputs and waits for completion'
  require_revmux
  make_round_fixture
  install_revmux_shim
  local out="$BATS_TEST_TMPDIR/out"

  run env REVMUX_SHIM_STATUS=0 PATH="$SHIM_BIN:$PATH" bash "$SCRIPT" next --task fixture \
    --tasks-dir "$TASKS_DIR" --workdir "$FIXTURE_REPO" --out-dir "$out" --profile focused --wait \
    --note 'launch the fixture review'
  assert_success
  run cat "$REVMUX_SHIM_RUN_ARGS"
  assert_success
  assert_output "$(cat <<EOF
--task
fixture
--run
02-after-fix
--no-tui
--tasks-dir
$TASKS_DIR
--profile
focused
--workdir
$FIXTURE_REPO
EOF
)"
  run cat "$out/02-after-fix.json"
  assert_success
  assert_output 'shim json'
  run cat "$out/02-after-fix.log"
  assert_success
  assert_output 'shim log'
  run cat "$out/02-after-fix.exit"
  assert_success
  assert_output '0'
}

function test_revmux_round_008_next_treats_revmux_exit_one_as_a_completed_review() {
  _bats_test_init 8 'next maps a completed revmux status one to success while waiting'
  require_revmux
  make_round_fixture
  install_revmux_shim

  run env REVMUX_SHIM_STATUS=1 PATH="$SHIM_BIN:$PATH" bash "$SCRIPT" next --task fixture \
    --tasks-dir "$TASKS_DIR" --workdir "$FIXTURE_REPO" --out-dir "$BATS_TEST_TMPDIR/out" --wait \
    --note 'status one is complete'
  assert_success
  run cat "$BATS_TEST_TMPDIR/out/02-after-fix.exit"
  assert_success
  assert_output '1'
}

function test_revmux_round_009_next_maps_an_abnormal_revmux_exit_to_two() {
  _bats_test_init 9 'next reports an abnormal completed revmux status as two while waiting'
  require_revmux
  make_round_fixture
  install_revmux_shim

  run env REVMUX_SHIM_STATUS=9 PATH="$SHIM_BIN:$PATH" bash "$SCRIPT" next --task fixture \
    --tasks-dir "$TASKS_DIR" --workdir "$FIXTURE_REPO" --out-dir "$BATS_TEST_TMPDIR/out" --wait \
    --note 'status nine is abnormal'
  assert_failure 2
  run cat "$BATS_TEST_TMPDIR/out/02-after-fix.exit"
  assert_success
  assert_output '9'
}

function test_revmux_round_010_summary_appends_literal_severity_counts() {
  _bats_test_init 10 'summary retains the projection then appends severity counts'
  local report="$BATS_TEST_TMPDIR/report.json"
  cat > "$report" <<'JSON'
{
  "sources": {"expected": 3, "reported": 2, "degraded": ["tests"]},
  "findings": [
    {"id": "minor", "severity": "minor", "title": "Minor"},
    {"id": "major-one", "severity": "major", "title": "Major one"},
    {"id": "critical", "severity": "critical", "title": "Critical"},
    {"id": "major-two", "severity": "major", "title": "Major two"}
  ]
}
JSON

  run bash "$SCRIPT" summary "$report"
  assert_success
  assert_line -n 0 'sources: 2/3 reported; degraded: tests'
  assert_line -n 1 'findings: 4'
  assert_line -n 8 'severity: critical 1, major 2, minor 1'
  assert_equal "${#lines[@]}" '9'
}

function test_revmux_round_011_summary_rejects_a_missing_report() {
  _bats_test_init 11 'summary rejects a missing report with status two'

  run bash "$SCRIPT" summary "$BATS_TEST_TMPDIR/missing.json"
  assert_failure 2
  assert_output --regexp '^error: .+'
}

function test_revmux_round_012_summary_rejects_an_unparseable_report() {
  _bats_test_init 12 'summary rejects an unparseable report with status two'
  local report="$BATS_TEST_TMPDIR/broken.json"
  printf '{broken\n' > "$report"

  run bash "$SCRIPT" summary "$report"
  assert_failure 2
  assert_output --regexp '^error: .+'
}

function test_revmux_round_013_next_rejects_an_unknown_option_with_usage() {
  _bats_test_init 13 'next rejects unknown options instead of selecting a different round'
  require_revmux
  make_round_fixture

  run bash "$SCRIPT" next --task fixture --tasks-dir "$TASKS_DIR" \
    --workdir "$FIXTURE_REPO" --prepare-only --unknown
  assert_failure 1
  assert_output --partial 'usage:'
}

function test_revmux_round_014_next_requires_a_task_with_usage() {
  _bats_test_init 14 'next requires a task identifier'

  run bash "$SCRIPT" next --prepare-only
  assert_failure 1
  assert_output --partial 'usage:'
}

function test_revmux_round_015_next_renders_repeatable_exclusions_in_scope() {
  _bats_test_init 15 'next carries round exclusions in their prescribed scope section'
  require_revmux
  make_round_fixture
  local exclusions
  exclusions=$(cat <<'EOF'
Exclusions:

- do not review generated files
- defer documentation polish
EOF
)

  run_prepare_only --note 'carry the round decisions' \
    --exclude 'do not review generated files' \
    --exclude 'defer documentation polish'
  assert_success

  run cat "$TASKS_DIR/fixture/02-after-fix/input/scope.md"
  assert_success
  assert_output "$(expected_scope 'carry the round decisions' "$exclusions")"
}

function test_revmux_round_016_next_replaces_carried_context_with_context_file() {
  _bats_test_init 16 'next replaces carried context with an explicit context file of the same name'
  require_revmux
  make_round_fixture
  local replacement="$BATS_TEST_TMPDIR/review.md"
  printf 'replacement verification evidence\n' > "$replacement"

  run_prepare_only --note 'use current verification evidence' --context-file "$replacement"
  assert_success
  assert_line 'context: 1'

  run cmp "$replacement" "$TASKS_DIR/fixture/02-after-fix/input/context/review.md"
  assert_success
}

function test_revmux_round_017_next_refuses_an_existing_explicit_run_without_changing_it() {
  _bats_test_init 17 'next refuses an explicit name that already identifies a round'
  require_revmux
  make_round_fixture
  local before="$BATS_TEST_TMPDIR/previous-input"
  cp -R "$PREVIOUS_ROUND/input" "$before"

  run bash "$SCRIPT" next --task fixture --run 01-initial --tasks-dir "$TASKS_DIR" \
    --workdir "$FIXTURE_REPO" --prepare-only
  assert_failure 1
  assert_output 'error: round 01-initial already exists in task fixture'

  run diff -r "$before" "$PREVIOUS_ROUND/input"
  assert_success
}

function test_revmux_round_018_next_truncates_long_scope_lists_without_exceeding_the_limit() {
  _bats_test_init 18 'next limits commit and changed-file scope blocks for a 25-file fixture'
  require_revmux
  make_round_fixture
  git -C "$FIXTURE_REPO" reset --hard -q "$FIXTURE_BASE"
  local index
  local scope="$TASKS_DIR/fixture/02-after-fix/input/scope.md"
  local expected_changed
  expected_changed=$(cat <<'EOF'
A	limit-01.txt
A	limit-02.txt
A	limit-03.txt
A	limit-04.txt
A	limit-05.txt
A	limit-06.txt
A	limit-07.txt
A	limit-08.txt
A	limit-09.txt
A	limit-10.txt
A	limit-11.txt
A	limit-12.txt
A	limit-13.txt
A	limit-14.txt
A	limit-15.txt
A	limit-16.txt
A	limit-17.txt
A	limit-18.txt
A	limit-19.txt
A	limit-20.txt
… and 5 more
EOF
)

  for index in $(seq -w 1 25); do
    printf 'limit %s\n' "$index" > "$FIXTURE_REPO/limit-$index.txt"
  done
  git -C "$FIXTURE_REPO" add limit-*.txt
  git -C "$FIXTURE_REPO" commit -qm 'add 25 limit files'
  for index in $(seq -w 1 15); do
    git -C "$FIXTURE_REPO" commit --allow-empty -qm "limit history $index"
  done

  run_prepare_only --note 'review the bounded fixture history'
  assert_success

  run bash -c '
    in_block=false
    while IFS= read -r line; do
      if [ "$line" = "Changed files:" ]; then
        in_block=awaiting_fence
      elif [ "$in_block" = awaiting_fence ] && [ "$line" = "\`\`\`" ]; then
        in_block=inside
      elif [ "$in_block" = inside ] && [ "$line" = "\`\`\`" ]; then
        break
      elif [ "$in_block" = inside ]; then
        printf "%s\n" "$line"
      fi
    done < "$1"
  ' bash "$scope"
  assert_success
  assert_output "$expected_changed"

  run bash -c '
    in_block=false
    while IFS= read -r line; do
      if [ "$line" = "Commits:" ]; then
        in_block=awaiting_fence
      elif [ "$in_block" = awaiting_fence ] && [ "$line" = "\`\`\`" ]; then
        in_block=inside
      elif [ "$in_block" = inside ] && [ "$line" = "\`\`\`" ]; then
        break
      elif [ "$in_block" = inside ]; then
        case "$line" in
          [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\ *)
            printf "%s\n" "${line#* }"
            ;;
          *) printf "%s\n" "$line" ;;
        esac
      fi
    done < "$1"
  ' bash "$scope"
  assert_success
  assert_output "$(cat <<'EOF'
limit history 15
limit history 14
limit history 13
limit history 12
limit history 11
limit history 10
limit history 09
limit history 08
limit history 07
limit history 06
… and 6 more
EOF
)"
  assert_equal "${#lines[@]}" '11'
  assert_line -n 10 '… and 6 more'

  run bash -c '[ "$(wc -m < "$1")" -le 1500 ]' bash "$scope"
  assert_success
}

function test_revmux_round_019_next_trims_long_changed_file_names_to_the_scope_budget() {
  _bats_test_init 19 'next keeps a long changed-file fixture within the scope budget'
  require_revmux
  make_round_fixture
  git -C "$FIXTURE_REPO" reset --hard -q "$FIXTURE_BASE"
  local index
  local prefix
  local padding
  local filename
  local scope="$TASKS_DIR/fixture/02-after-fix/input/scope.md"

  for index in $(seq -w 1 20); do
    prefix="f-$index-"
    padding="$(printf '%*s' "$((120 - ${#prefix}))" '')"
    filename="${prefix}${padding// /x}"
    printf 'long fixture %s\n' "$index" > "$FIXTURE_REPO/$filename"
  done
  git -C "$FIXTURE_REPO" add .
  git -C "$FIXTURE_REPO" commit -qm 'add 20 long fixture files'

  run bash -c '[ "$(git -C "$1" diff --name-status "$2..HEAD" | wc -l | tr -d "[:space:]")" = 20 ]' \
    bash "$FIXTURE_REPO" "$FIXTURE_BASE"
  assert_success

  run_prepare_only --note 'short update'
  assert_success

  run bash -c '
    in_block=false
    while IFS= read -r line; do
      if [ "$line" = "Changed files:" ]; then
        in_block=awaiting_fence
      elif [ "$in_block" = awaiting_fence ] && [ "$line" = "\`\`\`" ]; then
        in_block=inside
      elif [ "$in_block" = inside ] && [ "$line" = "\`\`\`" ]; then
        break
      elif [ "$in_block" = inside ]; then
        printf "%s\n" "$line"
      fi
    done < "$1"
  ' bash "$scope"
  assert_success
  assert_equal "${#lines[@]}" '8'
  assert_line -n 7 '… and 13 more'

  run bash -c '[ "$(wc -m < "$1")" -le 1500 ]' bash "$scope"
  assert_success
}

function test_revmux_round_020_next_wait_ignores_a_stale_exit_file() {
  _bats_test_init 20 'next removes a stale exit status before waiting for the launcher'
  require_revmux
  make_round_fixture
  install_revmux_shim
  local out="$BATS_TEST_TMPDIR/out"
  mkdir -p "$out"
  printf '7\n' > "$out/02-after-fix.exit"

  run env REVMUX_SHIM_DELAY=2 REVMUX_SHIM_STATUS=0 PATH="$SHIM_BIN:$PATH" bash "$SCRIPT" next \
    --task fixture --tasks-dir "$TASKS_DIR" --workdir "$FIXTURE_REPO" --out-dir "$out" --wait \
    --note 'replace the stale exit status'
  assert_success
  assert_line 'exit: 0'

  run cat "$out/02-after-fix.exit"
  assert_success
  assert_output '0'
}

function test_revmux_round_021_next_wait_reports_a_launcher_that_dies_without_an_exit_file() {
  _bats_test_init 21 'next reports a launcher that dies before publishing its exit status'
  require_revmux
  make_round_fixture
  install_revmux_kill_parent_shim
  local out="$BATS_TEST_TMPDIR/out"
  local exit_file="$out/02-after-fix.exit"
  local command_output="$BATS_TEST_TMPDIR/dead-launcher-output"

  run bash -c '
    command_output=$1
    shift
    "$@" > "$command_output" 2>&1 &
    command_pid=$!
    attempt=0
    while kill -0 "$command_pid" 2>/dev/null && [ "$attempt" -lt 200 ]; do
      attempt=$((attempt + 1))
      sleep 0.1
    done
    if kill -0 "$command_pid" 2>/dev/null; then
      kill -KILL "$command_pid" 2>/dev/null || true
      wait "$command_pid" 2>/dev/null || true
      printf "deadline exceeded while waiting for revmux-round next\n" >&2
      exit 125
    fi
    if wait "$command_pid"; then command_status=0; else command_status=$?; fi
    cat "$command_output"
    exit "$command_status"
  ' bash "$command_output" env PATH="$SHIM_BIN:$PATH" bash "$SCRIPT" next --task fixture --tasks-dir "$TASKS_DIR" \
    --workdir "$FIXTURE_REPO" --out-dir "$out" --wait --note 'observe the dead launcher'
  assert_failure 2
  assert_line "error: revmux launcher exited without writing $exit_file"
  assert_file_not_exists "$exit_file"

  run bash -c '! kill -0 "$(cat "$1")" 2>/dev/null' bash "$REVMUX_SHIM_WRAPPER_PID"
  assert_success
}

function test_revmux_round_022_next_refuses_an_unknown_base_without_creating_a_round() {
  _bats_test_init 22 'next leaves no round behind when the selected Git base does not exist'
  require_revmux
  make_round_fixture

  run_prepare_only --base no-such-git-object
  assert_failure
  assert_dir_not_exists "$TASKS_DIR/fixture/02-after-fix"
}

function test_revmux_round_023_next_renders_empty_git_blocks_when_base_equals_tip() {
  _bats_test_init 23 'next renders no-change Git facts without aborting'
  require_revmux
  make_round_fixture
  local scope="$TASKS_DIR/fixture/02-after-fix/input/scope.md"
  local expected
  expected="$(cat <<EOF
# Scope

Round 02-after-fix of task fixture: review the cumulative change against base $FIXTURE_TIP, including the fixes since the previous round.

Tip: $FIXTURE_TIP
Scale: no changes

Read the change:

\`\`\`
git diff $FIXTURE_TIP..HEAD
git log --oneline $FIXTURE_TIP..HEAD
\`\`\`

Commits:

\`\`\`

\`\`\`

Changed files:

\`\`\`

\`\`\`
EOF
)"

  run_prepare_only --base "$FIXTURE_TIP"
  assert_success

  run cat "$scope"
  assert_success
  assert_output "$expected"
}

function test_revmux_round_024_next_accepts_a_goal_at_the_character_limit() {
  _bats_test_init 24 'next accepts a carried-forward goal of exactly 1000 characters'
  require_revmux
  local goal
  goal="$(LC_ALL=C head -c 1000 /dev/zero | tr '\0' g)"
  make_round_fixture "$goal"

  run bash -c '[ "$(wc -m < "$1" | tr -d "[:space:]")" = 1000 ]' bash "$PREVIOUS_ROUND/input/goal.md"
  assert_success

  run_prepare_only --note 'goal at the limit is valid'
  assert_success
}

function test_revmux_round_025_next_rejects_a_missing_context_file_without_creating_a_round() {
  _bats_test_init 25 'next leaves no round behind when an explicit context file is absent'
  require_revmux
  make_round_fixture
  local missing="$BATS_TEST_TMPDIR/missing-context.md"

  run_prepare_only --context-file "$missing"
  assert_failure 1
  assert_output "error: context file $missing not found"
  assert_dir_not_exists "$TASKS_DIR/fixture/02-after-fix"
}

function test_revmux_round_026_next_renders_candidate_values_in_file_order() {
  _bats_test_init 26 'next renders every candidate value in source file order'
  require_revmux

  # #given
  make_round_fixture
  local candidate="$BATS_TEST_TMPDIR/candidate.json"
  local scope="$TASKS_DIR/fixture/02-after-fix/input/scope.md"
  write_valid_candidate "$candidate"

  # #when
  run_prepare_only --candidate "$candidate"

  # #then
  assert_success
  run cat "$scope"
  assert_success
  assert_output "$(expected_candidate_scope)"
}

function test_revmux_round_027_next_archives_the_candidate_file_byte_for_byte() {
  _bats_test_init 27 'next archives the exact candidate file bytes with the round input'
  require_revmux

  # #given
  make_round_fixture
  local candidate="$BATS_TEST_TMPDIR/candidate.json"
  local archived="$TASKS_DIR/fixture/02-after-fix/input/context/candidate.json"
  write_valid_candidate "$candidate"

  # #when
  run_prepare_only --candidate "$candidate"

  # #then
  assert_success
  run cmp "$candidate" "$archived"
  assert_success
}

function test_revmux_round_028_next_rejects_a_candidate_that_is_not_an_object() {
  _bats_test_init 28 'next rejects a non-object candidate before creating the round'
  require_revmux

  # #given
  make_round_fixture
  local candidate="$BATS_TEST_TMPDIR/invalid.json"
  printf '["artifact"]\n' > "$candidate"

  # #when
  run_prepare_only --candidate "$candidate"

  # #then
  assert_failure 1
  assert_dir_not_exists "$TASKS_DIR/fixture/02-after-fix"
  assert_output --regexp '^error: .*not an object.*$'
}

function test_revmux_round_029_next_rejects_a_nested_candidate_value_and_names_its_key() {
  _bats_test_init 29 'next names the key whose candidate value is nested'
  require_revmux

  # #given
  make_round_fixture
  local candidate="$BATS_TEST_TMPDIR/invalid.json"
  printf '{"artifact":{"name":"alerter-26.5.tar.gz"}}\n' > "$candidate"

  # #when
  run_prepare_only --candidate "$candidate"

  # #then
  assert_failure 1
  assert_dir_not_exists "$TASKS_DIR/fixture/02-after-fix"
  assert_output --regexp '^error: .*artifact.*$'
}

function test_revmux_round_030_next_rejects_an_empty_candidate_value_and_names_its_key() {
  _bats_test_init 30 'next names the key whose candidate value is empty'
  require_revmux

  # #given
  make_round_fixture
  local candidate="$BATS_TEST_TMPDIR/invalid.json"
  printf '{"version":""}\n' > "$candidate"

  # #when
  run_prepare_only --candidate "$candidate"

  # #then
  assert_failure 1
  assert_dir_not_exists "$TASKS_DIR/fixture/02-after-fix"
  assert_output --regexp '^error: .*version.*$'
}

function test_revmux_round_031_next_rejects_an_invalid_candidate_key_and_names_it() {
  _bats_test_init 31 'next names a candidate key outside the allowed alphabet'
  require_revmux

  # #given
  make_round_fixture
  local candidate="$BATS_TEST_TMPDIR/invalid.json"
  printf '{"bad key":"value"}\n' > "$candidate"

  # #when
  run_prepare_only --candidate "$candidate"

  # #then
  assert_failure 1
  assert_dir_not_exists "$TASKS_DIR/fixture/02-after-fix"
  assert_output --regexp '^error: .*bad key.*$'
}

function test_revmux_round_032_next_names_candidate_when_it_alone_exceeds_the_scope_limit() {
  _bats_test_init 32 'next names Candidate when that section alone exceeds the scope limit'
  require_revmux

  # #given
  make_round_fixture
  local candidate="$BATS_TEST_TMPDIR/large.json"
  {
    printf '{"blob":"'
    LC_ALL=C head -c 1501 /dev/zero | tr '\0' x
    printf '"}\n'
  } > "$candidate"

  # #when
  run_prepare_only --candidate "$candidate"

  # #then
  assert_failure 1
  assert_dir_not_exists "$TASKS_DIR/fixture/02-after-fix"
  assert_output --regexp '^error: .*Candidate.*$'
}

function test_revmux_round_033_next_names_note_when_note_overflows_with_a_small_candidate() {
  _bats_test_init 33 'next names Note instead of Candidate when the note exceeds the scope limit'
  require_revmux

  # #given
  make_round_fixture
  local candidate="$BATS_TEST_TMPDIR/small.json"
  local note
  printf '{"artifact":"small"}\n' > "$candidate"
  note="$(LC_ALL=C head -c 1400 /dev/zero | tr '\0' n)"

  # #when
  run_prepare_only --candidate "$candidate" --note "$note"

  # #then
  assert_failure 1
  assert_dir_not_exists "$TASKS_DIR/fixture/02-after-fix"
  assert_output --regexp '^error: Note section makes scope\.md [0-9]+ characters; the limit is 1500$'
}

function test_revmux_round_034_next_rejects_a_line_feed_in_a_candidate_value() {
  _bats_test_init 34 'next rejects a candidate value containing a line feed and names its key'
  require_revmux

  # #given
  make_round_fixture
  local candidate="$BATS_TEST_TMPDIR/line-feed-value.json"
  printf '{"artifact":"first line\\nforged: line"}\n' > "$candidate"

  # #when
  run_prepare_only --candidate "$candidate"

  # #then
  assert_failure 1
  assert_dir_not_exists "$TASKS_DIR/fixture/02-after-fix"
  assert_output --regexp '^error: .*artifact.*$'
}

function test_revmux_round_035_next_rejects_a_carriage_return_in_a_candidate_value() {
  _bats_test_init 35 'next rejects a candidate value containing a carriage return and names its key'
  require_revmux

  # #given
  make_round_fixture
  local candidate="$BATS_TEST_TMPDIR/carriage-return-value.json"
  printf '{"digest":"trusted\\rforged"}\n' > "$candidate"

  # #when
  run_prepare_only --candidate "$candidate"

  # #then
  assert_failure 1
  assert_dir_not_exists "$TASKS_DIR/fixture/02-after-fix"
  assert_output --regexp '^error: .*digest.*$'
}

function test_revmux_round_036_next_rejects_a_candidate_key_ending_in_a_line_feed() {
  _bats_test_init 36 'next applies the key alphabet check through a trailing line feed'
  require_revmux

  # #given
  make_round_fixture
  local candidate="$BATS_TEST_TMPDIR/line-feed-key.json"
  printf '{"linefeed-key\\n":"value"}\n' > "$candidate"

  # #when
  run_prepare_only --candidate "$candidate"

  # #then
  assert_failure 1
  assert_dir_not_exists "$TASKS_DIR/fixture/02-after-fix"
  assert_output --regexp '^error: .*linefeed-key.*$'
}

function test_revmux_round_037_next_rejects_a_candidate_key_ending_in_a_carriage_return() {
  _bats_test_init 37 'next applies the key alphabet check through a trailing carriage return'
  require_revmux

  # #given
  make_round_fixture
  local candidate="$BATS_TEST_TMPDIR/carriage-return-key.json"
  printf '{"carriage-key\\r":"value"}\n' > "$candidate"

  # #when
  run_prepare_only --candidate "$candidate"

  # #then
  assert_failure 1
  assert_dir_not_exists "$TASKS_DIR/fixture/02-after-fix"
  assert_output --regexp '^error: .*carriage-key.*$'
}
