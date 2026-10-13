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
printf 'shim json\n'
printf 'shim log\n' >&2
exit "${REVMUX_SHIM_STATUS:-0}"
SH
  chmod +x "$SHIM_BIN/revmux"
}

run_prepare_only() {
  run bash "$SCRIPT" next --task fixture --tasks-dir "$TASKS_DIR" \
    --workdir "$FIXTURE_REPO" --prepare-only "$@"
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

function test_revmux_round_004_next_accepts_an_in_limit_scope() {
  _bats_test_init 4 'next accepts a nearby in-limit scope control'
  require_revmux
  make_round_fixture

  run_prepare_only --note 'short update'
  assert_success
}

function test_revmux_round_005_next_rejects_an_over_limit_scope_without_launching() {
  _bats_test_init 5 'next rejects an oversized scope before the review launch'
  require_revmux
  make_round_fixture
  install_revmux_shim
  local note
  note="$(LC_ALL=C head -c 1400 /dev/zero | tr '\0' x)"

  run env PATH="$SHIM_BIN:$PATH" bash "$SCRIPT" next --task fixture --tasks-dir "$TASKS_DIR" \
    --workdir "$FIXTURE_REPO" --out-dir "$BATS_TEST_TMPDIR/out" --note "$note"
  assert_failure 1
  assert_output --regexp '^error: scope\.md is [0-9]+ characters; the limit is 1500$'
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
    --workdir "$FIXTURE_REPO" --out-dir "$BATS_TEST_TMPDIR/out" --note 'short update'
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
