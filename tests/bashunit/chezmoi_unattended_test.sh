#!/usr/bin/env bash
# post-apply: excluded
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
    if [ -n "${FAKE_MANAGED_EXIT_STATUS:-}" ]; then
      exit "$FAKE_MANAGED_EXIT_STATUS"
    fi
    if [ "${FAKE_MANAGED_OVERSIZED_TARGET:-}" = "1" ]; then
      # 98304 bytes = the launcher's 96 KiB batch budget; with the $HOME
      # prefix this single target can never fit in an empty batch.
      printf '%s\0' "$HOME/.config/oversized-$(head -c 98304 /dev/zero | tr '\0' x)"
      exit 0
    fi
    if [ "${FAKE_MANAGED_ONLY_OMITTED:-}" = "1" ]; then
      printf '%s\0' "$HOME/.zshenv" "$HOME/.claude.json"
      exit 0
    fi
    if [ -n "${FAKE_MANAGED_TARGET_COUNT:-}" ]; then
      managed_index=1
      while [ "$managed_index" -le "$FAKE_MANAGED_TARGET_COUNT" ]; do
        managed_target="$HOME/.config/generated-target-$managed_index-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        printf '%s\0' "$managed_target"
        printf '%s\0' "$managed_target" >> "$FAKE_STATE/managed-targets"
        managed_index=$((managed_index + 1))
      done
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

serialized_args="$0"
for arg in "$@"; do
  serialized_args="$serialized_args $arg"
done
if [ -n "${FAKE_MAX_CHEZMOI_ARGS_BYTES:-}" ] &&
   [ "${#serialized_args}" -gt "$FAKE_MAX_CHEZMOI_ARGS_BYTES" ]; then
  printf 'simulated CHEZMOI_ARGS limit exceeded: %s bytes\n' "${#serialized_args}" >&2
  exit 88
fi

printf 'final\n' >> "$FAKE_STATE/invocations"
printf '%s' "$PATH" > "$FAKE_STATE/path"
printf '%s' "${MMS_CHEZMOI_UNATTENDED_PROFILE:-}" > "$FAKE_STATE/profile"
printf '%s\0' "$@" > "$FAKE_STATE/argv"
printf '%s\n' "${#serialized_args}" >> "$FAKE_STATE/serialized-args-sizes"
for arg in "$@"; do
  case "$arg" in
    "$HOME/.config/generated-target-"*)
      printf '%s\0' "$arg" >> "$FAKE_STATE/received-targets"
      ;;
  esac
done
neighbor
cat > "$FAKE_STATE/stdin"
printf '%s' "${FAKE_STDOUT:-}"
printf '%s' "${FAKE_STDERR:-}" >&2
if [ -n "${FAKE_SIGNAL_MODE:-}" ]; then
  printf '%s' "$$" > "$FAKE_STATE/pid"
  trap 'printf term > "$FAKE_STATE/signal"; exit 143' TERM
  # Bounded wait: an undelivered TERM must fail this fake (exit 143, same
  # status as the trap but without the signal marker) instead of hanging the
  # suite forever.
  signal_wait_iterations=0
  while [ "$signal_wait_iterations" -lt 30 ]; do
    sleep 1
    signal_wait_iterations=$((signal_wait_iterations + 1))
  done
  exit 143
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
    MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY_2=tavily-2-canary \
    MMS_CHEZMOI_FIXTURE_JINA_API_KEY=jina-canary \
    MMS_CHEZMOI_FIXTURE_CONTEXT7_API_KEY=context7-canary \
    MMS_CHEZMOI_FIXTURE_VECTOR_PRIME_API_KEY=vector-prime-canary \
    MMS_CHEZMOI_FIXTURE_OPENROUTER_API_KEY=openrouter-canary \
    MMS_CHEZMOI_FIXTURE_POSTHOG_PERSONAL_API_KEY=posthog-canary \
    MMS_CHEZMOI_FIXTURE_VRT_R2_ACCESS_KEY_ID=vrt-r2-access-key-canary \
    MMS_CHEZMOI_FIXTURE_VRT_R2_SECRET_ACCESS_KEY=vrt-r2-secret-key-canary \
    run "$LAUNCHER" --profile full-fixture -- "$@"
}

# One version fixture, one exact gate message. The version probe has four
# rejection branches and the bare token 'version' appears in three of them —
# and inside two of the fixture strings themselves — so only the exact line
# says which gate answered.
assert_version_rejected() {
  FAKE_CHEZMOI_VERSION="$1" run_host verify
  assert_failure 2
  assert_output "$2"
  assert_final_not_reached
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
    assert_failure 2
    assert_output 'chezmoi-unattended: MMS_CHEZMOI_UNATTENDED must equal 1'
    assert_final_not_reached
  done

  run_host verify
  assert_success
  assert_file_exists "$FAKE_STATE/argv"
}

function test_chezmoi_unattended_002_rejects_missing_or_malformed_profile() {
  _bats_test_init 2 'rejects missing or malformed profile before final execution'
  # Exact line, not the token 'profile': that word is also in the usage header
  # and in MMS_CHEZMOI_UNATTENDED_PROFILE, so any other gate that mentions it
  # would satisfy a partial match and hide which one answered.
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 run "$LAUNCHER" -- verify
  assert_failure 2
  assert_output 'chezmoi-unattended: --profile must be full-fixture or host-partial'
  assert_final_not_reached

  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 \
    run "$LAUNCHER" --profile automatic -- verify
  assert_failure 2
  assert_output 'chezmoi-unattended: --profile must be full-fixture or host-partial'
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
  assert_failure 2
  assert_output 'chezmoi-unattended: chezmoi executable is not available on PATH'
  assert_final_not_reached
  mv "$FAKE_BIN/not-chezmoi" "$FAKE_BIN/chezmoi"

  assert_version_rejected broken \
    'chezmoi-unattended: malformed chezmoi version output: broken'
  assert_version_rejected 'chezmoi version latest' \
    'chezmoi-unattended: malformed chezmoi version: latest'
  assert_version_rejected 'chezmoi version v2.72.0, commit fake' \
    'chezmoi-unattended: chezmoi version 2.72.0 is older than required 2.72.1'

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
    MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY_2=x \
    MMS_CHEZMOI_FIXTURE_JINA_API_KEY=x \
    MMS_CHEZMOI_FIXTURE_CONTEXT7_API_KEY=x \
    MMS_CHEZMOI_FIXTURE_VECTOR_PRIME_API_KEY=x \
    MMS_CHEZMOI_FIXTURE_OPENROUTER_API_KEY=x \
    MMS_CHEZMOI_FIXTURE_POSTHOG_PERSONAL_API_KEY=x \
    MMS_CHEZMOI_FIXTURE_VRT_R2_ACCESS_KEY_ID=x \
    MMS_CHEZMOI_FIXTURE_VRT_R2_SECRET_ACCESS_KEY=x \
    run "$LAUNCHER" --profile full-fixture -- verify
  assert_failure 2
  # Exact line per gate. The two gates below print different messages; the
  # shared prefix 'MMS_DISPOSABLE_HOME must equal 1' matches either, so a
  # full-fixture run rejected by the write-capable branch would still pass.
  assert_output 'chezmoi-unattended: MMS_DISPOSABLE_HOME must equal 1 for full-fixture'
  assert_final_not_reached

  run_host apply
  assert_failure 2
  assert_output 'chezmoi-unattended: MMS_DISPOSABLE_HOME must equal 1 for write-capable command: apply'
  assert_final_not_reached

  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 MMS_DISPOSABLE_HOME=1 \
    run "$LAUNCHER" --profile host-partial -- apply
  assert_success
  assert_file_exists "$FAKE_STATE/argv"
}

function test_chezmoi_unattended_006_requires_each_full_fixture() {
  _bats_test_init 6 'requires every nonempty full fixture variable'
  local missing
  for missing in \
    MMS_CHEZMOI_FIXTURE_LINEAR_API_KEY \
    MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY \
    MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY_2 \
    MMS_CHEZMOI_FIXTURE_JINA_API_KEY \
    MMS_CHEZMOI_FIXTURE_CONTEXT7_API_KEY \
    MMS_CHEZMOI_FIXTURE_VECTOR_PRIME_API_KEY \
    MMS_CHEZMOI_FIXTURE_OPENROUTER_API_KEY \
    MMS_CHEZMOI_FIXTURE_POSTHOG_PERSONAL_API_KEY \
    MMS_CHEZMOI_FIXTURE_VRT_R2_ACCESS_KEY_ID \
    MMS_CHEZMOI_FIXTURE_VRT_R2_SECRET_ACCESS_KEY; do
    PATH="$TEST_PATH" run env \
      MMS_CHEZMOI_UNATTENDED=1 \
      MMS_DISPOSABLE_HOME=1 \
      MMS_CHEZMOI_FIXTURE_LINEAR_API_KEY=linear \
      MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY=tavily \
      MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY_2=tavily-2 \
      MMS_CHEZMOI_FIXTURE_JINA_API_KEY=jina \
      MMS_CHEZMOI_FIXTURE_CONTEXT7_API_KEY=context7 \
      MMS_CHEZMOI_FIXTURE_VECTOR_PRIME_API_KEY=vector \
      MMS_CHEZMOI_FIXTURE_OPENROUTER_API_KEY=openrouter \
      MMS_CHEZMOI_FIXTURE_POSTHOG_PERSONAL_API_KEY=posthog \
      MMS_CHEZMOI_FIXTURE_VRT_R2_ACCESS_KEY_ID=vrt-r2-access-key \
      MMS_CHEZMOI_FIXTURE_VRT_R2_SECRET_ACCESS_KEY=vrt-r2-secret-key \
      "$missing=" "$LAUNCHER" --profile full-fixture -- verify
    assert_failure 2
    assert_output "chezmoi-unattended: required fixture is empty or unset: $missing"
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
    env=env,
)
os.close(master)
os.close(slave)
sys.exit(result.returncode)
' "$TEST_PATH" "$LAUNCHER"
  assert_failure 2
  assert_output 'chezmoi-unattended: --finite-stdin requires non-terminal stdin'
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
  # Global, not local: teardown must still see the pid when an assertion below
  # exits the body mid-test, or the backgrounded fake outlives the test
  # (docs/solutions/design-patterns/outliving-processes-hang-the-suite.md).
  SIGNAL_LAUNCHER_PID=$!
  local rc deadline=$((SECONDS + 10))
  # Elapsed-time hang guard with a fast poll: the pid file lands in
  # milliseconds when healthy, but a loaded machine gets a real budget
  # (docs/solutions/design-patterns/idle-machine-wall-clock-bounds-are-latent-flakes.md).
  while [ ! -f "$FAKE_STATE/pid" ] && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.05
  done
  assert_file_exists "$FAKE_STATE/pid"
  assert_equal "$(< "$FAKE_STATE/pid")" "$SIGNAL_LAUNCHER_PID"
  kill -TERM "$SIGNAL_LAUNCHER_PID"
  rc=0
  wait "$SIGNAL_LAUNCHER_PID" || rc=$?
  SIGNAL_LAUNCHER_PID=""
  assert_equal "$rc" 143
  assert_equal "$(< "$FAKE_STATE/signal")" term
}

function test_chezmoi_unattended_010_diff_omits_exact_inventory_destinations() {
  _bats_test_init 10 'host diff omits exact inventory destinations and reports partial coverage'
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 \
    MMS_CHEZMOI_FIXTURE_LINEAR_API_KEY=DO_NOT_LEAK_LINEAR \
    MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY=DO_NOT_LEAK_TAVILY \
    MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY_2=DO_NOT_LEAK_TAVILY_2 \
    MMS_CHEZMOI_FIXTURE_JINA_API_KEY=DO_NOT_LEAK_JINA \
    MMS_CHEZMOI_FIXTURE_CONTEXT7_API_KEY=DO_NOT_LEAK_CONTEXT7 \
    MMS_CHEZMOI_FIXTURE_VECTOR_PRIME_API_KEY=DO_NOT_LEAK_VECTOR \
    MMS_CHEZMOI_FIXTURE_OPENROUTER_API_KEY=DO_NOT_LEAK_OPENROUTER \
    MMS_CHEZMOI_FIXTURE_POSTHOG_PERSONAL_API_KEY=DO_NOT_LEAK_POSTHOG_PERSONAL \
    MMS_CHEZMOI_FIXTURE_VRT_R2_ACCESS_KEY_ID=DO_NOT_LEAK_VRT_R2_ACCESS_KEY \
    MMS_CHEZMOI_FIXTURE_VRT_R2_SECRET_ACCESS_KEY=DO_NOT_LEAK_VRT_R2_SECRET_KEY \
    run "$LAUNCHER" --profile host-partial -- diff --source '/tmp/source tree'
  assert_success
  # Exact, whole output: the inventory holds two rows, the fake writes nothing
  # to stdout, so the notice block is fully determined. Partials on 'partial
  # coverage' or a single path passed when the other row's notice was missing,
  # duplicated, or paired with the wrong destination. The exact match also
  # subsumes the DO_NOT_LEAK refutation this replaced.
  assert_output 'chezmoi-unattended: partial coverage; omitted source home/dot_zshenv.tmpl -> destination ~/.zshenv
chezmoi-unattended: partial coverage; omitted source home/modify_dot_claude.json -> destination ~/.claude.json'
  assert_recorded_args --no-tty --no-pager --skip-secrets diff --source \
    '/tmp/source tree' "$HOME/.zshenv.backup" \
    "$HOME/.config/ordinary target" "$HOME/.config/line
break"
}

function test_chezmoi_unattended_0101_large_host_diff_stays_below_linux_exec_string_limit() {
  _bats_test_init 101 'large host diff keeps CHEZMOI_ARGS below the Linux exec string limit'
  # Known limit: the fake flattens argv with the same len(bin) + Σ(len(arg)+1)
  # accounting the launcher budgets batches with, so a shared off-by-N in how
  # chezmoi really flattens CHEZMOI_ARGS would pass both sides. What keeps the
  # check honest is the ceiling: 128 KiB minus the variable name and NUL is
  # Linux's documented per-string exec limit, an external number, and the
  # launcher budgets 96 KiB against it, so the assertion has real headroom to
  # measure. The batch count is a direction because the exact number depends on
  # the length of $HOME; `> 1` is also what proves the size loop below is not
  # reading an empty file.
  local target_count=2000 final_invocations=0 invocation serialized_size
  local linux_max_env_string_bytes=$((128 * 1024))
  local chezmoi_args_name_and_nul_bytes=14
  local max_chezmoi_args_bytes=$((linux_max_env_string_bytes - chezmoi_args_name_and_nul_bytes))

  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 \
    FAKE_MANAGED_TARGET_COUNT="$target_count" \
    FAKE_MAX_CHEZMOI_ARGS_BYTES="$max_chezmoi_args_bytes" \
    run "$LAUNCHER" --profile host-partial -- diff --source '/tmp/source tree'
  assert_success

  while IFS= read -r invocation; do
    [ "$invocation" = final ] && final_invocations=$((final_invocations + 1))
  done < "$FAKE_STATE/invocations"
  assert_equal "$((final_invocations > 1))" 1

  run cmp "$FAKE_STATE/managed-targets" "$FAKE_STATE/received-targets"
  assert_success

  local size_records=0
  while IFS= read -r serialized_size; do
    size_records=$((size_records + 1))
    assert_equal "$((serialized_size <= max_chezmoi_args_bytes))" 1
  done < "$FAKE_STATE/serialized-args-sizes"
  # One record per final invocation. The bound above is asserted per record, so
  # a short or empty record file would leave whole batches unmeasured and still
  # pass; the invocation log is the independent count of what actually ran.
  assert_equal "$size_records" "$final_invocations"
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
  assert_failure 2
  # Exact row message. 'inventory' alone also matches "is missing or unreadable"
  # and "contains no target rows", so a launcher that failed to locate its
  # sidecar next to the copy -- the resolution this copied directory exists to
  # exercise -- would pass on the wrong branch.
  assert_output 'chezmoi-unattended: malformed inventory row 1: expected five tab-separated fields'
  assert_final_not_reached
}

function test_chezmoi_unattended_012_empty_filtered_target_set_fails_closed() {
  _bats_test_init 12 'host diff rejects an empty filtered target set'
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 FAKE_MANAGED_ONLY_OMITTED=1 \
    run "$LAUNCHER" --profile host-partial -- diff --source /tmp/source
  assert_failure 2
  assert_output 'chezmoi-unattended: no non-sensitive managed targets remain after host-partial filtering'
  assert_final_not_reached
}

function test_chezmoi_unattended_013_rejects_malformed_launcher_invocations() {
  _bats_test_init 13 'rejects malformed launcher invocations before final execution'
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 \
    run "$LAUNCHER" --profile host-partial --bogus -- verify
  assert_failure 2
  assert_output 'chezmoi-unattended: unknown launcher option before --: --bogus'
  assert_final_not_reached

  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 \
    run "$LAUNCHER" --profile host-partial
  assert_failure 2
  assert_output 'chezmoi-unattended: launcher options must end with --'
  assert_final_not_reached

  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 \
    run "$LAUNCHER" --profile host-partial --
  assert_failure 2
  assert_output 'chezmoi-unattended: a chezmoi command is required after --'
  assert_final_not_reached

  run_host verify
  assert_success
  assert_file_exists "$FAKE_STATE/argv"
}

function test_chezmoi_unattended_014_inventory_requires_exactly_ten_fixture_identities() {
  _bats_test_init 14 'inventory requires exactly ten distinct fixture identities'
  local copied="$BATS_TEST_TMPDIR/copied"
  mkdir -p "$copied"
  cp "$LAUNCHER" "$copied/chezmoi-unattended"
  chmod +x "$copied/chezmoi-unattended"

  # Well-formed row, nine distinct identities: only the count gate can reject.
  printf 'home/dot_a.tmpl\t~/.a\tsecret-template\tomit\tMMS_CHEZMOI_FIXTURE_A,MMS_CHEZMOI_FIXTURE_B,MMS_CHEZMOI_FIXTURE_C,MMS_CHEZMOI_FIXTURE_D,MMS_CHEZMOI_FIXTURE_E,MMS_CHEZMOI_FIXTURE_F,MMS_CHEZMOI_FIXTURE_G,MMS_CHEZMOI_FIXTURE_H,MMS_CHEZMOI_FIXTURE_I\n' \
    > "$copied/chezmoi-unattended-targets.tsv"
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 \
    run "$copied/chezmoi-unattended" --profile host-partial -- verify
  assert_failure 2
  assert_output 'chezmoi-unattended: inventory must register exactly ten distinct fixture identities'
  assert_final_not_reached

  # Eleven distinct identities: "exactly ten" also rejects an over-count.
  printf 'home/dot_a.tmpl\t~/.a\tsecret-template\tomit\tMMS_CHEZMOI_FIXTURE_A,MMS_CHEZMOI_FIXTURE_B,MMS_CHEZMOI_FIXTURE_C,MMS_CHEZMOI_FIXTURE_D,MMS_CHEZMOI_FIXTURE_E,MMS_CHEZMOI_FIXTURE_F,MMS_CHEZMOI_FIXTURE_G,MMS_CHEZMOI_FIXTURE_H,MMS_CHEZMOI_FIXTURE_I,MMS_CHEZMOI_FIXTURE_J,MMS_CHEZMOI_FIXTURE_K\n' \
    > "$copied/chezmoi-unattended-targets.tsv"
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 \
    run "$copied/chezmoi-unattended" --profile host-partial -- verify
  assert_failure 2
  assert_output 'chezmoi-unattended: inventory must register exactly ten distinct fixture identities'
  assert_final_not_reached

  printf 'home/dot_a.tmpl\t~/.a\tsecret-template\tomit\tMMS_CHEZMOI_FIXTURE_A,MMS_CHEZMOI_FIXTURE_B,MMS_CHEZMOI_FIXTURE_C,MMS_CHEZMOI_FIXTURE_D,MMS_CHEZMOI_FIXTURE_E,MMS_CHEZMOI_FIXTURE_F,MMS_CHEZMOI_FIXTURE_G,MMS_CHEZMOI_FIXTURE_H,MMS_CHEZMOI_FIXTURE_I,MMS_CHEZMOI_FIXTURE_J\n' \
    > "$copied/chezmoi-unattended-targets.tsv"
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 \
    run "$copied/chezmoi-unattended" --profile host-partial -- verify
  assert_success
  assert_file_exists "$FAKE_STATE/argv"
}

function test_chezmoi_unattended_015_single_oversized_managed_target_fails_closed() {
  _bats_test_init 15 'host diff fails closed on a single oversized managed target'
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 FAKE_MANAGED_OVERSIZED_TARGET=1 \
    run "$LAUNCHER" --profile host-partial -- diff --source /tmp/source
  assert_failure 2
  # Partial: the reported target carries 96 KiB of filler, so an exact line
  # would assert the fixture. The destination prefix still proves the gate
  # named the oversized target rather than a neighbouring one.
  assert_output --partial "managed target is too long to invoke safely: $HOME/.config/oversized-"
  assert_final_not_reached

  # Control: the default managed targets fit one batch and pass the same gate.
  run_host diff --source /tmp/source
  assert_success
  assert_file_exists "$FAKE_STATE/argv"
}

function test_chezmoi_unattended_016_managed_failure_propagates_child_status() {
  _bats_test_init 16 'host diff propagates the managed child status without a final invocation'
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 FAKE_MANAGED_EXIT_STATUS=41 \
    run "$LAUNCHER" --profile host-partial -- diff --source /tmp/source
  assert_failure 41
  assert_final_not_reached

  run_host diff --source /tmp/source
  assert_success
  assert_file_exists "$FAKE_STATE/argv"
}

function test_chezmoi_unattended_017_mid_batch_diff_failure_propagates_and_stops() {
  _bats_test_init 17 'mid-batch diff failure propagates the child status and stops batching'
  # 2000 targets need several batches (test 0101 proves >1 final invocation);
  # every final invocation exits 53, so the first batch must end the launcher.
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 \
    FAKE_MANAGED_TARGET_COUNT=2000 FAKE_EXIT_STATUS=53 \
    run "$LAUNCHER" --profile host-partial -- diff --source /tmp/source
  assert_failure 53

  local final_invocations=0 invocation
  while IFS= read -r invocation; do
    [ "$invocation" = final ] && final_invocations=$((final_invocations + 1))
  done < "$FAKE_STATE/invocations"
  assert_equal "$final_invocations" 1

  rm -f "$FAKE_STATE/invocations" "$FAKE_STATE/managed-targets" \
    "$FAKE_STATE/received-targets"
  PATH="$TEST_PATH" MMS_CHEZMOI_UNATTENDED=1 FAKE_MANAGED_TARGET_COUNT=2000 \
    run "$LAUNCHER" --profile host-partial -- diff --source /tmp/source
  assert_success
  run cmp "$FAKE_STATE/managed-targets" "$FAKE_STATE/received-targets"
  assert_success
}

teardown() {
  # Failure-path cleanup for test 009: an assertion exiting the body between
  # launch and kill must not orphan the backgrounded launcher (the fake execs
  # in its place, so killing this pid kills the fake too). Green path clears
  # the variable after reaping, making this a no-op.
  if [ -n "${SIGNAL_LAUNCHER_PID:-}" ]; then
    kill -TERM "$SIGNAL_LAUNCHER_PID" 2>/dev/null || true
    wait "$SIGNAL_LAUNCHER_PID" 2>/dev/null || true
    SIGNAL_LAUNCHER_PID=""
  fi
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function tear_down() { _bats_run_teardown; }
