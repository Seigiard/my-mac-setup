#!/usr/bin/env bash
# post-apply: 26 host-safe
# revmux wrapper contract: which auth and arguments the real revmux receives.
# A fake revmux on PATH prints what reached it; the wrapper is the only logic
# under test.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/common'

setup() {
  WRAP_DIR="$BATS_TEST_TMPDIR/wrap"
  FAKE_DIR="$BATS_TEST_TMPDIR/fake"
  mkdir -p "$WRAP_DIR" "$FAKE_DIR"
  cp "$SOURCE_ROOT/dot_local/bin/executable_revmux" "$WRAP_DIR/revmux"
  chmod +x "$WRAP_DIR/revmux"
  cat > "$FAKE_DIR/revmux" <<'FAKE'
#!/usr/bin/env bash
printf 'ANTHROPIC_API_KEY=%s\n' "${ANTHROPIC_API_KEY-unset}"
printf 'arg=%s\n' "$@"
[ "${1:-}" != --preserve-anthropic-api-key ] || shift
[ "${1:-}" != fail ] || exit 7
if [ -n "${FAKE_REVMUX_READY:-}" ]; then
  trap 'printf term > "$FAKE_REVMUX_READY.got"; exit 143' TERM
  : > "$FAKE_REVMUX_READY"
  # bounded, so a TERM that never arrives fails the test instead of hanging it
  i=0
  while [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
fi
exit "${FAKE_REVMUX_EXIT:-0}"
FAKE
  chmod +x "$FAKE_DIR/revmux"
  # the probe target: records what reached it, answers as FAKE_CLAUDE says
  PROBE_LOG="$BATS_TEST_TMPDIR/probe.log"
  cat > "$FAKE_DIR/claude" <<'FAKE'
#!/usr/bin/env bash
printf 'key=%s claudecode=%s args=%s\n' "${ANTHROPIC_API_KEY-unset}" "${CLAUDECODE-unset}" "$*" >> "$PROBE_LOG"
mode=${FAKE_CLAUDE:-ok}
# ok-then-credit: the credit answers the first probe and runs out before the second
if [ "$mode" = ok-then-credit ]; then
  if [ "$(wc -l < "$PROBE_LOG")" -le 1 ]; then mode=ok; else mode=credit; fi
fi
case "$mode" in
  ok) printf '{"type":"result","subtype":"success","is_error":false,"result":"ok"}\n' ;;
  credit) printf '{"type":"result","subtype":"error","is_error":true,"result":"Your credit balance is too low"}\n'; exit 1 ;;
esac
FAKE
  chmod +x "$FAKE_DIR/claude"
  export PROBE_LOG
  WITH_REAL="$WRAP_DIR:$FAKE_DIR:/usr/bin:/bin"
}

function tear_down_after_script() {
  _bats_file_cleanup
}

# `VAR=value`... -- command args. A wall-clock watchdog turns a wrapper that
# execs itself in a loop into a killed status instead of a hung suite. The
# command gets its own process group and the watchdog kills the group: a
# `sh -c` in front of the wrapper would otherwise die alone and leave the
# loop holding the output pipe.
wrapped_revmux() {
  local assignments=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    assignments[${#assignments[@]}]="$1"
    shift
  done
  shift
  env -u ANTHROPIC_API_KEY -u REVMUX_ANTHROPIC_API_KEY "${assignments[@]}" bash -c '
    perl -e "setpgrp(0, 0); exec @ARGV or exit 127" -- "$@" &
    child=$!
    perl -e "setpgrp(0, 0); exec @ARGV or exit 127" -- \
      sh -c "sleep 10; kill -- -$child" >/dev/null 2>&1 &
    watchdog=$!
    # a disowned job is not reported when its kill below lands, so the
    # "Terminated" notice cannot land in the captured output
    disown "$watchdog" 2>/dev/null
    wait "$child"
    status=$?
    kill -- -"$watchdog" 2>/dev/null
    exit "$status"' bash "$@"
}

function test_revmux_wrapper_7301_routes_the_key_and_the_preserve_flag_to_the_real_binary() {
  _bats_test_init 7301 'routes the key and the preserve flag to the real binary'
  # #given
  local expected
  expected="$(printf '%s\n' 'revmux: claude agents on the API credit' 'ANTHROPIC_API_KEY=key-canary' \
    'arg=--preserve-anthropic-api-key' 'arg=--task' 'arg=t' 'arg=--run' 'arg=r' 'arg=--no-tui')"
  # #when
  run wrapped_revmux PATH="$WITH_REAL" REVMUX_ANTHROPIC_API_KEY=key-canary CLAUDECODE=1 \
    -- "$WRAP_DIR/revmux" --task t --run r --no-tui
  # #then
  assert_success
  assert_output "$expected"
  # one probe before the round, one after it
  assert_equal "$(cat "$PROBE_LOG")" "$(printf '%s\n' \
    'key=key-canary claudecode=unset args=--print --model haiku --output-format json --max-turns 1 reply with one word: ok' \
    'key=key-canary claudecode=unset args=--print --model haiku --output-format json --max-turns 1 reply with one word: ok')"
}

function test_revmux_wrapper_7302_runs_the_real_binary_unchanged_without_the_key() {
  _bats_test_init 7302 'runs the real binary unchanged without the key'
  # #given
  # #when
  run wrapped_revmux PATH="$WITH_REAL" -- "$WRAP_DIR/revmux" config
  # #then
  assert_success
  assert_output "$(printf '%s\n' 'ANTHROPIC_API_KEY=unset' 'arg=config')"

  # a shell-wide ANTHROPIC_API_KEY passes through untouched; revmux itself decides its fate
  run wrapped_revmux PATH="$WITH_REAL" ANTHROPIC_API_KEY=outer -- "$WRAP_DIR/revmux" config
  assert_success
  assert_output "$(printf '%s\n' 'ANTHROPIC_API_KEY=outer' 'arg=config')"

  # a subcommand spawns no agents: no probe, no key, even with the key set
  run wrapped_revmux PATH="$WITH_REAL" REVMUX_ANTHROPIC_API_KEY=key-canary -- "$WRAP_DIR/revmux" config
  assert_success
  assert_output "$(printf '%s\n' 'ANTHROPIC_API_KEY=unset' 'arg=config')"
  assert_file_not_exists "$PROBE_LOG"

  # `new --task` is how revmux-round.sh opens every round; it names a task and still spawns nothing
  run wrapped_revmux PATH="$WITH_REAL" REVMUX_ANTHROPIC_API_KEY=key-canary -- "$WRAP_DIR/revmux" new --task t --run r
  assert_success
  assert_output "$(printf '%s\n' 'ANTHROPIC_API_KEY=unset' 'arg=new' 'arg=--task' 'arg=t' 'arg=--run' 'arg=r')"
  assert_file_not_exists "$PROBE_LOG"

  # go-flags accepts global options before the subcommand
  run wrapped_revmux PATH="$WITH_REAL" REVMUX_ANTHROPIC_API_KEY=key-canary -- "$WRAP_DIR/revmux" --tasks-dir /t new --task t
  assert_success
  assert_output "$(printf '%s\n' 'ANTHROPIC_API_KEY=unset' 'arg=--tasks-dir' 'arg=/t' 'arg=new' 'arg=--task' 'arg=t')"
  assert_file_not_exists "$PROBE_LOG"

  # a task or run named like a subcommand is still a review run
  run wrapped_revmux PATH="$WITH_REAL" REVMUX_ANTHROPIC_API_KEY=key-canary -- "$WRAP_DIR/revmux" --task stats --run new
  assert_success
  assert_output "$(printf '%s\n' 'revmux: claude agents on the API credit' 'ANTHROPIC_API_KEY=key-canary' \
    'arg=--preserve-anthropic-api-key' 'arg=--task' 'arg=stats' 'arg=--run' 'arg=new')"
}

function test_revmux_wrapper_7303_returns_the_real_binary_exit_status() {
  _bats_test_init 7303 'returns the real binary exit status'
  # #given
  # #when
  run wrapped_revmux PATH="$WITH_REAL" REVMUX_ANTHROPIC_API_KEY=key-canary -- "$WRAP_DIR/revmux" fail
  # #then
  assert_failure 7
}

function test_revmux_wrapper_7304_fails_instead_of_calling_itself_when_no_binary_follows() {
  _bats_test_init 7304 'fails instead of calling itself when no binary follows'
  # #given
  # #when
  run wrapped_revmux PATH="$WRAP_DIR:/usr/bin:/bin" -- "$WRAP_DIR/revmux" --version
  # #then
  assert_failure 127
  assert_output 'revmux: no revmux binary in PATH after this wrapper'
}

function test_revmux_wrapper_7305_ignores_empty_and_relative_path_entries() {
  _bats_test_init 7305 'ignores empty and relative PATH entries'
  # #given a planted revmux in the working directory
  cp "$FAKE_DIR/revmux" "$BATS_TEST_TMPDIR/revmux"
  # #when PATH names the working directory through an empty and a relative entry
  run wrapped_revmux PATH="$WRAP_DIR::.:/usr/bin:/bin" REVMUX_ANTHROPIC_API_KEY=key-canary \
    -- sh -c 'cd "$1" && "$2" --version' sh "$BATS_TEST_TMPDIR" "$WRAP_DIR/revmux"
  # #then
  assert_failure 127
  assert_output 'revmux: no revmux binary in PATH after this wrapper'
}

function test_revmux_wrapper_7306_skips_a_front_end_before_it_that_delegates_back() {
  _bats_test_init 7306 'skips a front end before it that delegates back'
  # #given a shim ahead of the wrapper in PATH that execs the wrapper, as the revmux-round suite does
  local shim_dir="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$shim_dir"
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$WRAP_DIR/revmux" > "$shim_dir/revmux"
  chmod +x "$shim_dir/revmux"
  # #when
  run wrapped_revmux PATH="$shim_dir:$WITH_REAL" REVMUX_ANTHROPIC_API_KEY=key-canary -- "$shim_dir/revmux" --task t
  # #then the real binary behind the wrapper answers, not the shim again
  assert_success
  assert_output "$(printf '%s\n' 'revmux: claude agents on the API credit' 'ANTHROPIC_API_KEY=key-canary' \
    'arg=--preserve-anthropic-api-key' 'arg=--task' 'arg=t')"
}


function test_revmux_wrapper_7307_falls_back_to_the_subscription_when_the_probe_fails() {
  _bats_test_init 7307 'falls back to the subscription when the probe fails'
  # #given a key whose API call fails, as an exhausted credit does
  # #when
  run wrapped_revmux PATH="$WITH_REAL" REVMUX_ANTHROPIC_API_KEY=key-canary FAKE_CLAUDE=credit \
    -- "$WRAP_DIR/revmux" --task t --run r
  # #then the round runs without the key and stderr names the cause
  assert_success
  assert_output "$(printf '%s\n' \
    'revmux: claude agents on the subscription; API probe failed: exit 1: "result":"Your credit balance is too low"' \
    'ANTHROPIC_API_KEY=unset' 'arg=--task' 'arg=t' 'arg=--run' 'arg=r')"
}

function test_revmux_wrapper_7308_probes_only_a_claude_from_an_absolute_path_entry() {
  _bats_test_init 7308 'probes only a claude from an absolute PATH entry'
  # #given a planted claude in the working directory, named by a relative PATH entry ahead of the real one
  local planted="$BATS_TEST_TMPDIR/planted"
  mkdir -p "$planted"
  printf '#!/usr/bin/env bash\nprintf %%s "$ANTHROPIC_API_KEY" > "%s/leak"\nprintf %%s "{\\"is_error\\":false}"\n' "$planted" > "$planted/claude"
  chmod +x "$planted/claude"
  # #when
  run wrapped_revmux PATH="$WRAP_DIR:.:$FAKE_DIR:/usr/bin:/bin" REVMUX_ANTHROPIC_API_KEY=key-canary \
    -- sh -c 'cd "$1" && "$2" --task t' sh "$planted" "$WRAP_DIR/revmux"
  # #then the probe reached the absolute-path claude and the planted one saw nothing
  assert_success
  assert_output "$(printf '%s\n' 'revmux: claude agents on the API credit' 'ANTHROPIC_API_KEY=key-canary' \
    'arg=--preserve-anthropic-api-key' 'arg=--task' 'arg=t')"
  assert_file_not_exists "$planted/leak"
  # one probe before the round, one after it
  assert_equal "$(cat "$PROBE_LOG")" "$(printf '%s\n' \
    'key=key-canary claudecode=unset args=--print --model haiku --output-format json --max-turns 1 reply with one word: ok' \
    'key=key-canary claudecode=unset args=--print --model haiku --output-format json --max-turns 1 reply with one word: ok')"
}

function test_revmux_wrapper_7309_tells_the_caller_to_rerun_when_the_credit_runs_out_mid_round() {
  _bats_test_init 7309 'tells the caller to re-run when the credit runs out mid-round'
  # #given a key that answers before the round and is out of credit after it
  # #when the round ends with findings
  run wrapped_revmux PATH="$WITH_REAL" REVMUX_ANTHROPIC_API_KEY=key-canary FAKE_CLAUDE=ok-then-credit \
    FAKE_REVMUX_EXIT=1 -- "$WRAP_DIR/revmux" --task t --run r
  # #then revmux's verdict stands and stderr says a re-run goes to the subscription
  assert_failure 1
  assert_output "$(printf '%s\n' 'revmux: claude agents on the API credit' 'ANTHROPIC_API_KEY=key-canary' \
    'arg=--preserve-anthropic-api-key' 'arg=--task' 'arg=t' 'arg=--run' 'arg=r' \
    'revmux: API credit limit reached (exit 1: "result":"Your credit balance is too low"). Claude agents that failed in this round failed on it. Run the review again as a new round: revmux will run its claude agents on the subscription. A codex-only profile is not needed.')"
}

function test_revmux_wrapper_7310_passes_a_term_on_to_a_round_on_the_credit() {
  _bats_test_init 7310 'passes a TERM on to a round on the credit'
  # #given a round on the credit that runs until it is stopped
  local ready="$BATS_TEST_TMPDIR/ready" wrapper waited=0
  env -u ANTHROPIC_API_KEY PATH="$WITH_REAL" REVMUX_ANTHROPIC_API_KEY=key-canary FAKE_REVMUX_READY="$ready" \
    "$WRAP_DIR/revmux" --task t >/dev/null 2>&1 &
  wrapper=$!
  while [ ! -e "$ready" ] && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
  assert_file_exists "$ready"
  # #when the wrapper alone is told to stop
  kill -TERM "$wrapper"
  local code=0
  wait "$wrapper" || code=$?
  # #then revmux received it and its status comes back
  assert_equal "$(cat "$ready.got")" term
  assert_equal "$code" 143
}
