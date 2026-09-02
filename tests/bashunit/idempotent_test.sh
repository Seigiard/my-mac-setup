#!/usr/bin/env bash
# post-apply: 60 needs-disposable-home
# bashunit: no-parallel-tests
# idempotent post-apply suite — bashunit source. Vocabulary (run, assert_*,
# skip, BATS_* contract) comes from tests/bashunit/test-dsl.bash.
# Migrated from idempotent.bats; parity evidence: docs/benchmarks/bashunit-full-suite-experiment.md.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"


load 'helpers/common'

# The apply scenario below runs a real `chezmoi apply`, and its destination is
# $HOME. `--source` only selects where templates are read from; nothing here
# redirects the write. It deploys the source tree onto whatever machine runs
# the file, and the run scripts under home/.chezmoiscripts/ target $HOME
# directly -- installing Homebrew, running brew bundle, and on macOS calling
# sudo defaults write.
#
# require_disposable_home is therefore the first statement of each scenario.
# It runs them only where MMS_DISPOSABLE_HOME=1 declares this $HOME throwaway,
# skips on a workstation, and hard-fails on a runner that lost the marker
# (tests/helpers/disposable-home.bash holds the truth table). The guard is
# inline rather than in setup_file() on purpose: a skip there would take the
# `guard:` tests below with it, and those are what keep this file honest.
#
# Where the marker is set, the scenarios still inspect or mutate the shared
# $HOME that every other test file reads deployed state from. Concurrent applies
# would race, so this file stays sequential even when the suite runs with --jobs,
# and the shared tests/run-post-apply.sh wrapper keeps
# --no-parallelize-across-files in both modes. It is 1.3 s of a 268 s suite,
# so serializing it costs nothing measurable.
BATS_NO_PARALLELIZE_WITHIN_FILE=true

# All chezmoi commands use PATH_WITHOUT_OP to prevent 1Password auth
# prompts during testing. CHEZMOI_BIN holds the resolved chezmoi path.

# ===========================================
# Idempotency tests
# ===========================================

function test_idempotent_001_chezmoi_apply_is_idempotent_and_leaves_no_pendin() {
  _bats_test_init 1 'chezmoi apply is idempotent and leaves no pending diff'
  require_disposable_home
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" apply --source="$CHEZMOI_SOURCE" --force --verbose
  assert_success

  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" apply --source="$CHEZMOI_SOURCE" --force
  assert_success
  assert_output ""

  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" diff --source="$CHEZMOI_SOURCE"
  assert_success
  assert_output ""
}

function test_idempotent_002_chezmoi_verify_succeeds() {
  _bats_test_init 2 'chezmoi verify succeeds'
  # Read-only, so safe on a host, but it would assert against the chezmoi
  # clone rather than this checkout -- a weaker and different claim. Guarded
  # with the apply scenario so the file has one rule, not two.
  require_disposable_home
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" verify --source="$CHEZMOI_SOURCE"
  assert_success
}

function test_idempotent_0021_chezmoi_apply_preserves_skills_owned_outside_chezmoi() {
  _bats_test_init 21 'chezmoi apply preserves agent skills owned outside chezmoi'
  require_disposable_home
  local skill
  for skill in smithers se-flow se-review-and-work se-work; do
    mkdir -p "$HOME/.agents/skills/$skill"
    printf 'manual %s\n' "$skill" > "$HOME/.agents/skills/$skill/SKILL.md"
  done

  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" apply --source="$CHEZMOI_SOURCE" --force
  assert_success
  for skill in smithers se-flow se-review-and-work se-work; do
    run cat "$HOME/.agents/skills/$skill/SKILL.md"
    assert_success
    assert_output "manual $skill"
  done
}

# ===========================================
# The guard itself
# ===========================================
#
# Everything below is unguarded on purpose: it must run on every host, so this
# file is never fully inert locally. Each test name is prefixed `guard:` so a
# developer can exercise the guard alone -- `tests/lib/bashunit -f guard
# tests/bashunit/idempotent_test.sh` -- without reaching the chezmoi scenarios
# above.

# Answer the predicate in a controlled environment. `env -u` drops whatever the
# calling shell exported, so a developer who already has CI or the marker set
# cannot change what these tests measure. The plain `bash -c` is also the proof
# that tests/helpers/disposable-home.bash needs no bats to work.
predicate_verdict() {
  env -u MMS_DISPOSABLE_HOME -u GITHUB_ACTIONS -u CI "$@" \
    bash -c '. "$1"; mms_disposable_home_verdict' _ \
    "$HELPERS_DIR/disposable-home.bash"
}

function test_idempotent_003_guard_mms_disposable_home_1_yields_the_run_verdi() {
  _bats_test_init 3 'guard: MMS_DISPOSABLE_HOME=1 yields the run verdict'
  run predicate_verdict MMS_DISPOSABLE_HOME=1
  assert_success
  assert_output "run"
}

function test_idempotent_004_guard_no_marker_and_no_platform_fact_yields_the() {
  _bats_test_init 4 'guard: no marker and no platform fact yields the skip verdict'
  # /.dockerenv is written by the container runtime and cannot be unset, so
  # this scenario is only observable outside a container.
  [[ ! -f /.dockerenv ]] || skip "/.dockerenv exists here"
  run predicate_verdict
  assert_success
  assert_output "skip"
}

function test_idempotent_005_guard_an_empty_marker_does_not_yield_run() {
  _bats_test_init 5 'guard: an empty marker does not yield run'
  run predicate_verdict MMS_DISPOSABLE_HOME=
  assert_success
  refute_output "run"
}

function test_idempotent_006_guard_mms_disposable_home_0_does_not_yield_run() {
  _bats_test_init 6 'guard: MMS_DISPOSABLE_HOME=0 does not yield run'
  # MMS_CI_MINIMAL treats any non-empty value as true (tests/bashunit/templates_test.sh).
  # This guard deliberately diverges: a safety guard fails closed.
  run predicate_verdict MMS_DISPOSABLE_HOME=0
  assert_success
  refute_output "run"
}

function test_idempotent_007_guard_mms_disposable_home_true_does_not_yield_ru() {
  _bats_test_init 7 'guard: MMS_DISPOSABLE_HOME=true does not yield run'
  run predicate_verdict MMS_DISPOSABLE_HOME=true
  assert_success
  refute_output "run"
}

function test_idempotent_008_guard_an_exported_ci_does_not_yield_run() {
  _bats_test_init 8 'guard: an exported CI does not yield run'
  # The developer-exports-CI case. Sniffing CI for permission would re-create
  # the bug this guard exists to stop.
  run predicate_verdict CI=1
  assert_success
  refute_output "run"
}

function test_idempotent_009_guard_github_actions_without_the_marker_yields_m() {
  _bats_test_init 9 'guard: GITHUB_ACTIONS without the marker yields misconfigured'
  run predicate_verdict GITHUB_ACTIONS=true
  assert_success
  assert_output "misconfigured"
}

function test_idempotent_010_guard_every_disposable_environment_declares_the() {
  _bats_test_init 10 'guard: every disposable environment declares the marker'
  # Never skipped. A skip here would be indistinguishable from this file going
  # inert, which is exactly the rot the test exists to catch.
  if [[ -z "${GITHUB_ACTIONS:-}" ]] && [[ ! -f /.dockerenv ]]; then
    # Nothing reports this $HOME disposable. Do not assert `!= misconfigured`
    # here — this branch's own condition makes that verdict unreachable.
    # Deliberately unscrubbed: the marker must win over whatever this shell
    # exports, a claim the env -u guard tests above cannot make.
    local live marked
    live="$(mms_disposable_home_verdict)"
    [[ "$live" == "run" || "$live" == "skip" ]] || \
      fail "No platform fact reports a disposable \$HOME here, yet the predicate returned '$live' instead of run or skip."
    marked="$(MMS_DISPOSABLE_HOME=1 mms_disposable_home_verdict)"
    assert_equal "$marked" "run"
    return 0
  fi

  [[ "${MMS_DISPOSABLE_HOME:-}" == "1" ]] || \
    fail "This environment reports a disposable \$HOME (GITHUB_ACTIONS is set, or /.dockerenv exists), but MMS_DISPOSABLE_HOME is '${MMS_DISPOSABLE_HOME:-<unset>}' instead of 1. The idempotency scenarios in this file would skip here, removing that coverage without turning anything red. Declare the marker at the site that launched this suite: .github/workflows/test-dotfiles.yml (top-level env: block), or docker/docker-compose.yml (services ubuntu, test-ubuntu, test-full)."
}

function test_idempotent_011_guard_the_marker_s_claim_covers_chezmoi_s_real_d() {
  _bats_test_init 11 'guard: the marker'\''s claim covers chezmoi'\''s real destination'
  skip_if_no_chezmoi
  [[ "${MMS_DISPOSABLE_HOME:-}" == "1" ]] || skip "marker unset, nothing claims this \$HOME is disposable"
  assert_python3_available

  # The marker says "$HOME is disposable". These tests are only safe if that is
  # also where chezmoi writes -- which --source never controls.
  local config dest
  config="$(PATH="$PATH_WITHOUT_OP" "$CHEZMOI_BIN" dump-config --format=json)"
  dest="$(printf '%s' "$config" | python3 -c 'import json,sys; print(json.load(sys.stdin)["destDir"])')"
  assert_equal "$dest" "$HOME"
}

function test_idempotent_012_guard_the_skip_message_names_make_test_ubuntu_an() {
  _bats_test_init 12 'guard: the skip message names make test-ubuntu and the marker'
  # `run` executes in a subshell, so these stubs cannot leak into another test.
  # Stubbing is the only way to read the message: a real skip ends the test
  # before any assertion can run.
  captured_skip_message() {
    mms_disposable_home_verdict() { echo "skip"; }
    skip() { printf '%s' "$*"; }
    require_disposable_home
  }

  run captured_skip_message
  assert_output --partial "make test-ubuntu"
  assert_output --partial "MMS_DISPOSABLE_HOME"
}

function test_idempotent_013_guard_the_misconfigured_message_names_the_marker() {
  _bats_test_init 13 'guard: the misconfigured message names the marker'\''s write sites'
  captured_fail_message() {
    mms_disposable_home_verdict() { echo "misconfigured"; }
    fail() { printf '%s' "$*"; return 0; }
    require_disposable_home
  }

  run captured_fail_message
  # One text assertion, kept for the human who reads this failure: the message
  # has to name the marker it is asking for. The file names it also carries are
  # not pinned as strings -- copied out of the message they would only restate
  # it -- but read back out of the message and checked against the tree.
  assert_output --partial "MMS_DISPOSABLE_HOME"

  # Two independently maintained sides: the message in tests/helpers/common.bash
  # claims which launch sites declare the marker, and those launch sites have to
  # actually declare it. The rot this catches is a dropped `env:` block in the
  # workflow or a dropped `environment:` entry in a compose service -- after
  # which the scenarios above skip in CI and the suite stays green.
  #
  # The repo root only exists where the full checkout does: the host, and the
  # macOS CI job. `make test-ubuntu` mounts home/ and tests/ alone, so the
  # cross-check is unreachable there and the file-name half of this contract is
  # owned by the host and macOS runs.
  local repo_root named rel
  repo_root="$BATS_TEST_DIRNAME/.."
  named="$(printf '%s\n' "$output" | grep -oE '[A-Za-z0-9_./-]+\.ya?ml')"
  [[ -n "$named" ]] || fail "the misconfigured message names no marker-declaring file: $output"
  if [[ -d "$repo_root/.github" ]]; then
    while IFS= read -r rel; do
      assert_file_exists "$repo_root/$rel"
      grep -qE 'MMS_DISPOSABLE_HOME[=:][[:space:]]*"?1"?' "$repo_root/$rel" || \
        fail "$rel is named as a site that declares MMS_DISPOSABLE_HOME=1, but does not set it"
    done <<< "$named"
  fi
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}
