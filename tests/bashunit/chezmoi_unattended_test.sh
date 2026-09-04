#!/usr/bin/env bash
# chezmoi-unattended launcher suite. The controlled child process and its
# filesystem markers are the oracle; no assertion inspects launcher source.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

LAUNCHER="$BATS_TEST_DIRNAME/helpers/chezmoi-unattended"

setup() {
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  FAKE_STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$FAKE_BIN" "$FAKE_STATE"
  ORIGINAL_PATH="$PATH"
  TEST_PATH="$FAKE_BIN:$ORIGINAL_PATH"
  export FAKE_STATE

  cat > "$FAKE_BIN/chezmoi" <<'FAKE_CHEZMOI'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' "${FAKE_CHEZMOI_VERSION:-chezmoi version v2.72.1, commit fake}"
  exit 0
fi

for arg in "$@"; do
  if [ "$arg" = "managed" ]; then
    printf 'managed\n' >> "$FAKE_STATE/invocations"
    if [ "${FAKE_MANAGED_ONLY_OMITTED:-}" = "1" ]; then
      printf '%s\0' "$HOME/.zshenv" "$HOME/.claude.json"
      exit 0
    fi
    printf '%s\0' \
      "$HOME/.zshenv" \
      "$HOME/.claude.json" \
      "$HOME/.zshenv.backup" \
      "$HOME/.config/ordinary target" \
      "$HOME/.config/line
break"
    exit 0
  fi
done

printf 'final\n' >> "$FAKE_STATE/invocations"
printf '%s' "$PATH" > "$FAKE_STATE/path"
printf '%s' "${MMS_CHEZMOI_UNATTENDED_PROFILE:-}" > "$FAKE_STATE/profile"
printf '%s\0' "$@" > "$FAKE_STATE/argv"
neighbor
cat > "$FAKE_STATE/stdin"
printf '%s' "${FAKE_STDOUT:-}"
printf '%s' "${FAKE_STDERR:-}" >&2
if [ -n "${FAKE_SIGNAL_MODE:-}" ]; then
  printf '%s' "$$" > "$FAKE_STATE/pid"
  trap 'printf term > "$FAKE_STATE/signal"; exit 143' TERM
  while :; do sleep 1; done
fi
exit "${FAKE_EXIT_STATUS:-0}"
FAKE_CHEZMOI

  cat > "$FAKE_BIN/op" <<'FAKE_OP'
#!/usr/bin/env bash
printf launched > "$FAKE_STATE/op-launched"
exit 99
FAKE_OP

  cat > "$FAKE_BIN/neighbor" <<'FAKE_NEIGHBOR'
#!/usr/bin/env bash
printf reached > "$FAKE_STATE/neighbor-reached"
FAKE_NEIGHBOR

  chmod +x "$FAKE_BIN/chezmoi" "$FAKE_BIN/op" "$FAKE_BIN/neighbor"
}

run_host() {
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 \
    run "$LAUNCHER" --profile host-partial -- "$@"
}

run_full() {
  PATH="$TEST_PATH" \
    MMS_CHEZMOI_UNATTENDED=1 \
    MMS_DISPOSABLE_HOME=1 \
    MMS_CHEZMOI_FIXTURE_LINEAR_API_KEY=linear-canary \
    MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY=tavily-canary \
    MMS_CHEZMOI_FIXTURE_JINA_API_KEY=jina-canary \
    MMS_CHEZMOI_FIXTURE_CONTEXT7_API_KEY=context7-canary \
    MMS_CHEZMOI_FIXTURE_VECTOR_PRIME_API_KEY=vector-prime-canary \
    run "$LAUNCHER" --profile full-fixture -- "$@"
}

assert_final_not_reached() {
  # oracle: the controlled child creates this marker only for a final command.
  assert_file_not_exists "$FAKE_STATE/argv"
}

assert_recorded_args() {
  local expected_count="$#" index=0 actual
  while IFS= read -r -d '' actual; do
    if [ "$index" -ge "$expected_count" ]; then
      fail "unexpected argument at index $index: $actual"
      return 1
    fi
    assert_equal "$actual" "$1"
    shift
    index=$((index + 1))
  done < "$FAKE_STATE/argv"
  assert_equal "$index" "$expected_count"
}

function test_chezmoi_unattended_001_requires_exact_selector_with_valid_control() {
  _bats_test_init 1 'requires exact MMS_CHEZMOI_UNATTENDED selector with valid control'
  local selector
  for selector in __unset__ '' 0 true; do
    if [ "$selector" = __unset__ ]; then
      PATH="$TEST_PATH" run env -u MMS_CHEZMOI_UNATTENDED \
        "$LAUNCHER" --profile host-partial -- verify
    else
      PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED="$selector" \
        run "$LAUNCHER" --profile host-partial -- verify
    fi
    assert_failure
    assert_output --partial 'MMS_CHEZMOI_UNATTENDED must equal 1'
    assert_final_not_reached
  done

  run_host verify
  assert_success
  assert_file_exists "$FAKE_STATE/argv"
}

function test_chezmoi_unattended_002_rejects_missing_or_malformed_profile() {
  _bats_test_init 2 'rejects missing or malformed profile before final execution'
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 run "$LAUNCHER" -- verify
  assert_failure
  assert_output --partial 'profile'
  assert_final_not_reached

  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 \
    run "$LAUNCHER" --profile automatic -- verify
  assert_failure
  assert_output --partial 'full-fixture or host-partial'
  assert_final_not_reached
}

function test_chezmoi_unattended_003_profiles_inject_global_flags_and_preserve_path() {
  _bats_test_init 3 'profiles inject their global flags and preserve PATH'
  run_host verify 'quoted value'
  assert_success
  assert_recorded_args --no-tty --no-pager --skip-secrets verify 'quoted value'
  assert_equal "$(< "$FAKE_STATE/profile")" host-partial
  assert_equal "$(< "$FAKE_STATE/path")" "$TEST_PATH"
  assert_file_exists "$FAKE_STATE/neighbor-reached"
  # oracle: fake op creates this independent launch marker if executed.
  assert_file_not_exists "$FAKE_STATE/op-launched"

  rm -f "$FAKE_STATE/argv" "$FAKE_STATE/neighbor-reached"
  run_full verify
  assert_success
  assert_recorded_args --no-tty --no-pager verify
  assert_equal "$(< "$FAKE_STATE/profile")" full-fixture
  assert_file_exists "$FAKE_STATE/neighbor-reached"
  # oracle: fake op creates this independent launch marker if executed.
  assert_file_not_exists "$FAKE_STATE/op-launched"
}

function test_chezmoi_unattended_004_rejects_bad_versions_with_valid_boundaries() {
  _bats_test_init 4 'rejects missing malformed and old chezmoi versions with valid boundaries'
  mv "$FAKE_BIN/chezmoi" "$FAKE_BIN/not-chezmoi"
  PATH="$FAKE_BIN" MMS_CHEZMOI_UNATTENDED=1 \
    run /bin/bash "$LAUNCHER" --profile host-partial -- verify
  assert_failure
  assert_output --partial 'chezmoi executable'
  assert_final_not_reached
  mv "$FAKE_BIN/not-chezmoi" "$FAKE_BIN/chezmoi"

  local version
  for version in broken 'chezmoi version latest' 'chezmoi version v2.72.0, commit fake'; do
    FAKE_CHEZMOI_VERSION="$version" run_host verify
    assert_failure
    assert_output --partial 'version'
    assert_final_not_reached
  done

  FAKE_CHEZMOI_VERSION='chezmoi version v2.72.1, commit fake' run_host verify
  assert_success
  FAKE_CHEZMOI_VERSION='chezmoi version v3.1.0, commit fake' run_host verify
  assert_success
}

function test_chezmoi_unattended_005_enforces_disposable_authority() {
  _bats_test_init 5 'enforces disposable authority for full fixture and host writes'
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 \
    MMS_CHEZMOI_FIXTURE_LINEAR_API_KEY=x \
    MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY=x \
    MMS_CHEZMOI_FIXTURE_JINA_API_KEY=x \
    MMS_CHEZMOI_FIXTURE_CONTEXT7_API_KEY=x \
    MMS_CHEZMOI_FIXTURE_VECTOR_PRIME_API_KEY=x \
    run "$LAUNCHER" --profile full-fixture -- verify
  assert_failure
  assert_output --partial 'MMS_DISPOSABLE_HOME must equal 1'
  assert_final_not_reached

  run_host apply
  assert_failure
  assert_output --partial 'MMS_DISPOSABLE_HOME must equal 1'
  assert_final_not_reached

  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 MMS_DISPOSABLE_HOME=1 \
    run "$LAUNCHER" --profile host-partial -- apply
  assert_success
  assert_file_exists "$FAKE_STATE/argv"
}

function test_chezmoi_unattended_006_requires_each_full_fixture() {
  _bats_test_init 6 'requires all five nonempty full fixture variables'
  local missing
  for missing in \
    MMS_CHEZMOI_FIXTURE_LINEAR_API_KEY \
    MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY \
    MMS_CHEZMOI_FIXTURE_JINA_API_KEY \
    MMS_CHEZMOI_FIXTURE_CONTEXT7_API_KEY \
    MMS_CHEZMOI_FIXTURE_VECTOR_PRIME_API_KEY; do
    PATH="$TEST_PATH" run env \
      MMS_CHEZMOI_UNATTENDED=1 \
      MMS_DISPOSABLE_HOME=1 \
      MMS_CHEZMOI_FIXTURE_LINEAR_API_KEY=linear \
      MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY=tavily \
      MMS_CHEZMOI_FIXTURE_JINA_API_KEY=jina \
      MMS_CHEZMOI_FIXTURE_CONTEXT7_API_KEY=context7 \
      MMS_CHEZMOI_FIXTURE_VECTOR_PRIME_API_KEY=vector \
      "$missing=" "$LAUNCHER" --profile full-fixture -- verify
    assert_failure
    assert_output --partial "$missing"
    assert_final_not_reached
  done

  run_full verify
  assert_success
}

function test_chezmoi_unattended_007_controls_stdin_modes() {
  _bats_test_init 7 'ordinary mode closes stdin and finite mode forwards exact input'
  run bash -c 'printf inherited | PATH="$1" MMS_CHEZMOI_UNATTENDED=1 "$2" --profile host-partial -- verify' \
    _ "$TEST_PATH" "$LAUNCHER"
  assert_success
  assert_equal "$(< "$FAKE_STATE/stdin")" ''

  rm -f "$FAKE_STATE/stdin"
  run bash -c 'printf "line one\nline two" | PATH="$1" MMS_CHEZMOI_UNATTENDED=1 "$2" --profile host-partial --finite-stdin -- execute-template' \
    _ "$TEST_PATH" "$LAUNCHER"
  assert_success
  assert_equal "$(< "$FAKE_STATE/stdin")" $'line one\nline two'
}

function test_chezmoi_unattended_0071_rejects_terminal_finite_stdin() {
  _bats_test_init 71 'finite stdin rejects a terminal before final execution'
  run python3 -c '
import os
import subprocess
import sys

master, slave = os.openpty()
env = os.environ.copy()
env["PATH"] = sys.argv[1]
env["MMS_CHEZMOI_UNATTENDED"] = "1"
result = subprocess.run(
    [sys.argv[2], "--profile", "host-partial", "--finite-stdin", "--", "verify"],
    stdin=slave,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    env=env,
)
os.close(master)
os.close(slave)
sys.exit(result.returncode)
' "$TEST_PATH" "$LAUNCHER"
  assert_failure
  assert_final_not_reached
}

function test_chezmoi_unattended_008_preserves_output_status_and_quoted_arguments() {
  _bats_test_init 8 'preserves output status and quoted arguments'
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 \
    FAKE_STDOUT='child stdout' FAKE_STDERR='child stderr' FAKE_EXIT_STATUS=37 \
    run --separate-stderr "$LAUNCHER" --profile host-partial -- verify \
      'space value' 'quote"value' ''
  assert_failure 37
  assert_output 'child stdout'
  assert_stderr 'child stderr'
  assert_recorded_args --no-tty --no-pager --skip-secrets verify \
    'space value' 'quote"value' ''
}

function test_chezmoi_unattended_009_exec_propagates_signals_to_the_child() {
  _bats_test_init 9 'exec propagates a causal signal to the child process'
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 FAKE_SIGNAL_MODE=1 \
    "$LAUNCHER" --profile host-partial -- verify \
    > "$BATS_TEST_TMPDIR/signal.out" 2>&1 &
  local launcher_pid=$! attempts=0 rc
  while [ ! -f "$FAKE_STATE/pid" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  assert_file_exists "$FAKE_STATE/pid"
  assert_equal "$(< "$FAKE_STATE/pid")" "$launcher_pid"
  kill -TERM "$launcher_pid"
  rc=0
  wait "$launcher_pid" || rc=$?
  assert_equal "$rc" 143
  assert_equal "$(< "$FAKE_STATE/signal")" term
}

function test_chezmoi_unattended_010_diff_omits_exact_inventory_destinations() {
  _bats_test_init 10 'host diff omits exact inventory destinations and reports partial coverage'
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 \
    MMS_CHEZMOI_FIXTURE_LINEAR_API_KEY=DO_NOT_LEAK_LINEAR \
    MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY=DO_NOT_LEAK_TAVILY \
    MMS_CHEZMOI_FIXTURE_JINA_API_KEY=DO_NOT_LEAK_JINA \
    MMS_CHEZMOI_FIXTURE_CONTEXT7_API_KEY=DO_NOT_LEAK_CONTEXT7 \
    MMS_CHEZMOI_FIXTURE_VECTOR_PRIME_API_KEY=DO_NOT_LEAK_VECTOR \
    run "$LAUNCHER" --profile host-partial -- diff --source '/tmp/source tree'
  assert_success
  assert_output --partial 'partial coverage'
  assert_output --partial 'home/dot_zshenv.tmpl'
  assert_output --partial '~/.zshenv'
  assert_output --partial 'home/modify_dot_claude.json'
  assert_output --partial '~/.claude.json'
  refute_output --partial 'DO_NOT_LEAK'
  assert_recorded_args --no-tty --no-pager --skip-secrets diff --source \
    '/tmp/source tree' "$HOME/.zshenv.backup" \
    "$HOME/.config/ordinary target" "$HOME/.config/line
break"
}

function test_chezmoi_unattended_011_malformed_inventory_fails_closed() {
  _bats_test_init 11 'malformed inventory fails closed before chezmoi final execution'
  local copied="$BATS_TEST_TMPDIR/copied"
  mkdir -p "$copied"
  cp "$LAUNCHER" "$copied/chezmoi-unattended"
  printf 'home/bad\t~/.bad\tsecret-template\tomit\n' \
    > "$copied/chezmoi-unattended-targets.tsv"
  chmod +x "$copied/chezmoi-unattended"

  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 \
    run "$copied/chezmoi-unattended" --profile host-partial -- verify
  assert_failure
  assert_output --partial 'inventory'
  assert_final_not_reached
}

function test_chezmoi_unattended_012_empty_filtered_target_set_fails_closed() {
  _bats_test_init 12 'host diff rejects an empty filtered target set'
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 FAKE_MANAGED_ONLY_OMITTED=1 \
    run "$LAUNCHER" --profile host-partial -- diff --source /tmp/source
  assert_failure
  assert_output --partial 'no non-sensitive managed targets remain'
  assert_final_not_reached
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function tear_down() { _bats_run_teardown; }
