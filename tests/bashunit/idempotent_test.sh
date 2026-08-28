#!/usr/bin/env bash
# bashunit: no-parallel-tests
# Generated from tests/idempotent.bats by scripts/bats2bashunit.py — DO NOT EDIT.
source "$(dirname "${BASH_SOURCE[0]}")/bats-compat.bash"
_bats_file_init "$(dirname "${BASH_SOURCE[0]}")/../idempotent.bats"


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

function test_001_chezmoi_apply_is_idempotent_and_leaves_no_pendin() {
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

function test_002_chezmoi_verify_succeeds() {
  _bats_test_init 2 'chezmoi verify succeeds'
  # Read-only, so safe on a host, but it would assert against the chezmoi
  # clone rather than this checkout -- a weaker and different claim. Guarded
  # with the apply scenario so the file has one rule, not two.
  require_disposable_home
  PATH="$PATH_WITHOUT_OP" run "$CHEZMOI_BIN" verify --source="$CHEZMOI_SOURCE"
  assert_success
}

# ===========================================
# The guard itself
# ===========================================
#
# Everything below is unguarded on purpose: it must run on every host, so this
# file is never fully inert locally. Each test name is prefixed `guard:` so a
# developer can exercise the guard alone -- `bats --filter 'guard:'
# tests/idempotent.bats` -- without reaching the chezmoi scenarios above.

# Answer the predicate in a controlled environment. `env -u` drops whatever the
# calling shell exported, so a developer who already has CI or the marker set
# cannot change what these tests measure. The plain `bash -c` is also the proof
# that tests/helpers/disposable-home.bash needs no bats to work.
predicate_verdict() {
  env -u MMS_DISPOSABLE_HOME -u GITHUB_ACTIONS -u CI "$@" \
    bash -c '. "$1"; mms_disposable_home_verdict' _ \
    "$HELPERS_DIR/disposable-home.bash"
}

function test_003_guard_mms_disposable_home_1_yields_the_run_verdi() {
  _bats_test_init 3 'guard: MMS_DISPOSABLE_HOME=1 yields the run verdict'
  run predicate_verdict MMS_DISPOSABLE_HOME=1
  assert_success
  assert_output "run"
}

function test_004_guard_no_marker_and_no_platform_fact_yields_the() {
  _bats_test_init 4 'guard: no marker and no platform fact yields the skip verdict'
  # /.dockerenv is written by the container runtime and cannot be unset, so
  # this scenario is only observable outside a container.
  [[ ! -f /.dockerenv ]] || skip "/.dockerenv exists here"
  run predicate_verdict
  assert_success
  assert_output "skip"
}

function test_005_guard_an_empty_marker_does_not_yield_run() {
  _bats_test_init 5 'guard: an empty marker does not yield run'
  run predicate_verdict MMS_DISPOSABLE_HOME=
  assert_success
  refute_output "run"
}

function test_006_guard_mms_disposable_home_0_does_not_yield_run() {
  _bats_test_init 6 'guard: MMS_DISPOSABLE_HOME=0 does not yield run'
  # MMS_CI_MINIMAL treats any non-empty value as true (tests/templates.bats).
  # This guard deliberately diverges: a safety guard fails closed.
  run predicate_verdict MMS_DISPOSABLE_HOME=0
  assert_success
  refute_output "run"
}

function test_007_guard_mms_disposable_home_true_does_not_yield_ru() {
  _bats_test_init 7 'guard: MMS_DISPOSABLE_HOME=true does not yield run'
  run predicate_verdict MMS_DISPOSABLE_HOME=true
  assert_success
  refute_output "run"
}

function test_008_guard_an_exported_ci_does_not_yield_run() {
  _bats_test_init 8 'guard: an exported CI does not yield run'
  # The developer-exports-CI case. Sniffing CI for permission would re-create
  # the bug this guard exists to stop.
  run predicate_verdict CI=1
  assert_success
  refute_output "run"
}

function test_009_guard_github_actions_without_the_marker_yields_m() {
  _bats_test_init 9 'guard: GITHUB_ACTIONS without the marker yields misconfigured'
  run predicate_verdict GITHUB_ACTIONS=true
  assert_success
  assert_output "misconfigured"
}

function test_010_guard_every_disposable_environment_declares_the() {
  _bats_test_init 10 'guard: every disposable environment declares the marker'
  # Never skipped. A skip here would be indistinguishable from this file going
  # inert, which is exactly the rot the test exists to catch.
  if [[ -z "${GITHUB_ACTIONS:-}" ]] && [[ ! -f /.dockerenv ]]; then
    # Nothing reports this $HOME disposable, so the one claim available is that
    # the predicate does not accuse this machine of losing a marker it never
    # needed. It holds under the local opt-in too, where the verdict is `run`.
    [[ "$(mms_disposable_home_verdict)" != "misconfigured" ]] || \
      fail "No platform fact reports a disposable \$HOME here, yet the predicate returned misconfigured."
    return 0
  fi

  [[ "${MMS_DISPOSABLE_HOME:-}" == "1" ]] || \
    fail "This environment reports a disposable \$HOME (GITHUB_ACTIONS is set, or /.dockerenv exists), but MMS_DISPOSABLE_HOME is '${MMS_DISPOSABLE_HOME:-<unset>}' instead of 1. The idempotency scenarios in this file would skip here, removing that coverage without turning anything red. Declare the marker at the site that launched this suite: .github/workflows/test-dotfiles.yml (top-level env: block), or docker/docker-compose.yml (services ubuntu, test-ubuntu, test-full)."
}

function test_011_guard_the_marker_s_claim_covers_chezmoi_s_real_d() {
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

function test_012_guard_the_skip_message_names_make_test_ubuntu_an() {
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

function test_013_guard_the_misconfigured_message_names_the_marker() {
  _bats_test_init 13 'guard: the misconfigured message names the marker'\''s write sites'
  captured_fail_message() {
    mms_disposable_home_verdict() { echo "misconfigured"; }
    fail() { printf '%s' "$*"; return 0; }
    require_disposable_home
  }

  run captured_fail_message
  assert_output --partial "MMS_DISPOSABLE_HOME"
  assert_output --partial "test-dotfiles.yml"
  assert_output --partial "docker-compose.yml"
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

