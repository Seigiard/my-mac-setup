#!/usr/bin/env bash
# post-apply: 20 host-safe
# scripts post-apply suite — bashunit source. Vocabulary (run, assert_*,
# skip, BATS_* contract) comes from tests/bashunit/test-dsl.bash.
# Migrated from scripts.bats; parity evidence: docs/benchmarks/bashunit-full-suite-experiment.md.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/common'
load 'helpers/herdr_worktree_identity'

setup() {
  export HERDR_ALIAS_ALLOCATOR="$BATS_TEST_DIRNAME/helpers/herdr_alias_allocator"
  unset HERDR_ENV
  unset HERDR_AGENT_INTERCOM_ACTIVE
  unset HERDR_AGENT_INTERCOM_NAME
  unset HERDR_AGENT_INTERCOM_PANE
  unset HERDR_AGENT_INTERCOM_PI_LOAD
  unset HERDR_CHILD_NAME
  unset HERDR_CHILD_LAUNCH
  unset HERDR_CHILD_PARENT_PANE
  unset HERDR_CHILD_STATE_DIR
  unset HERDR_CHILD_COLD_INITIAL_PROMPT_DELAY
  unset HERDR_WORKSPACE_ID
  unset HERDR_PANE_ID
  unset OPENCODE_INTERCOM_NAME
  unset INTERCOM_DIR
  unset HERDR_CHILD_MAX_DELIVERY_RETRIES
  unset HERDR_CHILD_TEST_RETRY_LOG
  unset HERDR_CHILD_TEST_FAILURE_PUBLISH_BARRIER
  unset HERDR_CHILD_TEST_LIVENESS_PUBLISH_BARRIER
  unset HERDR_CHILD_TEST_CALLBACK_RECEIPT_BARRIER
  unset HERDR_CHILD_TEST_REAP_INVALIDATED_BARRIER
  unset HERDR_CHILD_TEST_REAP_OWNER_VERIFIED
  unset HERDR_CHILD_TEST_NOW_SEQ
  unset HERDR_CHILD_TEST_TAKEOVER_METADATA_PUBLISHED
  unset CHILD_REAP_PID
  CHILD_STUBS=()
  # U2 exercises authorization only. Do not let an installed local model CLI
  # turn those fixtures into live naming requests now that U3 derives names.
  export HERDR_WORKTREE_IDENTITY_DISABLE_ENGINES=1
}

# ===========================================
# Agent Intercom launcher
# ===========================================

agent_intercom_stub_command() {
  local path="$1"
  cat > "$path" <<'SH'
#!/usr/bin/env bash
pi_load=
if [[ -n "${HERDR_AGENT_INTERCOM_PI_LOAD:-}" ]]; then
  pi_load=foreign
  [[ "$HERDR_AGENT_INTERCOM_PI_LOAD" == "$$" ]] && pi_load=self
fi
printf '%s name=<%s> args=' "${0##*/}" "${OPENCODE_INTERCOM_NAME-}"
printf ' active=<%s> pi_load=<%s>' "${HERDR_AGENT_INTERCOM_ACTIVE-}" "$pi_load"
[[ $# -eq 0 ]] || printf '<%s>' "$@"
printf '\n'
SH
  chmod +x "$path"
}

agent_intercom_stub_bin() {
  local stub="$BATS_TEST_TMPDIR/agent-intercom-bin"
  local home="$BATS_TEST_TMPDIR/agent-intercom-home"
  mkdir -p "$stub"
  agent_intercom_stub_command "$stub/claude"
  agent_intercom_stub_command "$stub/opencode"
  agent_intercom_stub_command "$stub/pi"
  agent_intercom_stub_command "$stub/cci"
  cat > "$stub/herdr" <<'SH'
#!/usr/bin/env bash
[[ "$1 $2" == 'agent get' ]] || exit 2
case "$3" in
  w1:p2) name=ochre-okapi ;;
  w1:p3) name=violet-tern ;;
  *) exit 1 ;;
esac
printf '{"result":{"agent":{"name":"%s","pane_id":"%s","launch_pending":true}}}\n' "$name" "$3"
SH
  cat > "$stub/allocator" <<'SH'
#!/usr/bin/env bash
[[ "$1" == --alias-candidates && $# == 2 ]] || exit 2
printf '%s\n' ochre-okapi silver-ibis violet-tern
SH
  chmod +x "$stub/herdr" "$stub/allocator"
  mkdir -p "$home/.local/share/agent-intercom/node_modules/.bin" \
    "$home/.local/share/agent-intercom/node_modules/@dataforxyz/agent-intercom-claude/dist" \
    "$home/.local/bin"
  ln -sf "$stub/cci" "$home/.local/share/agent-intercom/node_modules/.bin/cci"
  : > "$home/.local/share/agent-intercom/node_modules/@dataforxyz/agent-intercom-claude/dist/claude-server.mjs"
  : > "$home/.local/share/agent-intercom/node_modules/@dataforxyz/agent-intercom-claude/dist/inbox-monitor.mjs"
  cp "$SOURCE_ROOT/dot_local/bin/executable_herdr-agent-intercom-claude" \
    "$home/.local/bin/herdr-agent-intercom-claude"
  chmod +x "$home/.local/bin/herdr-agent-intercom-claude"
  printf '%s\n' "$stub"
}

function test_scripts_1330_agent_intercom_launcher_is_an_exact_non_herdr_passthrough() {
  _bats_test_init 1330 'agent intercom launcher is an exact non-Herdr passthrough'
  local launcher="$SOURCE_ROOT/dot_local/bin/executable_herdr-agent-intercom"
  local stub
  stub="$(agent_intercom_stub_bin)"

  run env -u HERDR_ENV -u HERDR_CHILD_NAME -u HERDR_PANE_ID \
    PATH="$stub:$PATH" bash "$launcher" opencode --model test/model prompt

  assert_success
  assert_output 'opencode name=<> args= active=<> pi_load=<><--model><test/model><prompt>'
}

function test_scripts_1331_agent_intercom_launcher_propagates_a_child_alias_to_each_adapter() {
  _bats_test_init 1331 'agent intercom launcher propagates a preallocated pane alias to Claude OpenCode and Pi'
  local launcher="$SOURCE_ROOT/dot_local/bin/executable_herdr-agent-intercom"
  local stub
  stub="$(agent_intercom_stub_bin)"

  export HERDR_PANE_ID=w1:p2 HERDR_ALIAS_ALLOCATOR="$stub/allocator"

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/agent-intercom-home" \
    PATH="$stub:$PATH" bash "$launcher" claude \
    --dangerously-skip-permissions --model sonnet
  assert_success
  assert_output --partial 'active=<1> pi_load=<><--model><sonnet><--dangerously-skip-permissions><--tui><--transport><mcp><--name><ochre-okapi><--claude><'
  assert_output --partial '/herdr-agent-intercom-claude>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/agent-intercom-home" \
    PATH="$stub:$PATH" bash "$launcher" opencode --model test/model
  assert_success
  assert_output 'opencode name=<ochre-okapi> args= active=<1> pi_load=<><--model><test/model>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/agent-intercom-home" \
    PATH="$stub:$PATH" bash "$launcher" pi --provider anthropic
  assert_success
  assert_output 'pi name=<> args= active=<1> pi_load=<self><--name><ochre-okapi><--provider><anthropic>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/agent-intercom-home" \
    PATH="$stub:$PATH" bash "$launcher" pi --name wrong -n wrong-again -- --name message
  assert_success
  assert_output 'pi name=<> args= active=<1> pi_load=<self><--name><ochre-okapi><--><--name><message>'
}

function test_scripts_1905_agent_intercom_launcher_selects_shared_state_for_every_client() {
  _bats_test_init 1905 'agent intercom launcher selects shared state for every client'
  local launcher="$SOURCE_ROOT/dot_local/bin/executable_herdr-agent-intercom"
  local stub home="$BATS_TEST_TMPDIR/agent-intercom-home" client command
  stub="$(agent_intercom_stub_bin)"
  export HERDR_PANE_ID=w1:p2 HERDR_ALIAS_ALLOCATOR="$stub/allocator"
  for command in claude opencode pi cci; do
    cat > "$stub/$command" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${INTERCOM_DIR-}"
SH
  done

  for client in claude opencode pi; do
    run env -u XDG_STATE_HOME HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$home" \
      PATH="$stub:$PATH" bash "$launcher" "$client"
    assert_success
    assert_output "$home/.local/state/agent-intercom"

    run env XDG_STATE_HOME="$home/custom state" HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$home" \
      PATH="$stub:$PATH" bash "$launcher" "$client"
    assert_success
    assert_output "$home/custom state/agent-intercom"

    run env INTERCOM_DIR="$home/explicit runtime" XDG_STATE_HOME="$home/custom state" \
      HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$home" PATH="$stub:$PATH" \
      bash "$launcher" "$client"
    assert_success
    assert_output "$home/explicit runtime"

    run env -u HERDR_ENV HOME="$home" PATH="$stub:$PATH" bash "$launcher" "$client"
    assert_success
    assert_output ''
  done
}

function test_scripts_1332_agent_intercom_launcher_resolves_the_current_pane_alias() {
  _bats_test_init 1332 'agent intercom launcher resolves the current Herdr pane alias'
  local launcher="$SOURCE_ROOT/dot_local/bin/executable_herdr-agent-intercom"
  local stub
  stub="$(agent_intercom_stub_bin)"
  cat > "$stub/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"id":"cli:agent:get","result":{"agent":{"name":"silver-ibis","pane_id":"w1:p2"}}}'
SH
  chmod +x "$stub/herdr"

  run env HERDR_ENV=1 HERDR_CHILD_NAME=caller-supplied HERDR_PANE_ID=w1:p2 \
    HERDR_ALIAS_ALLOCATOR="$stub/allocator" \
    HOME="$BATS_TEST_TMPDIR/agent-intercom-home" PATH="$stub:$PATH" bash "$launcher" opencode

  assert_success
  assert_output 'opencode name=<silver-ibis> args= active=<1> pi_load=<>'

  # A provisional name can look like an alias without belonging to the pool.
  cat > "$stub/herdr" <<'SH'
#!/usr/bin/env bash
printf '{"result":{"agent":{"name":"%s","pane_id":"%s","launch_pending":true}}}\n' \
  "$PROBE_NAME" "${PROBE_PANE:-w1:p2}"
exit "${PROBE_STATUS:-0}"
SH
  local provisional
  for provisional in caller-supplied unnamed-alpha; do
    run env HERDR_ENV=1 HERDR_CHILD_NAME=silver-ibis HERDR_PANE_ID=w1:p2 \
      PROBE_NAME="$provisional" HERDR_ALIAS_ALLOCATOR="$stub/allocator" \
      HERDR_AGENT_INTERCOM_ACTIVE=1 HERDR_AGENT_INTERCOM_PANE=w1:p1 \
      HERDR_AGENT_INTERCOM_NAME=parent-alias OPENCODE_INTERCOM_NAME=parent-alias \
      HOME="$BATS_TEST_TMPDIR/agent-intercom-home" PATH="$stub:$PATH" bash "$launcher" opencode
    assert_success
    assert_output --partial 'canonical pane alias unavailable; starting opencode without Intercom'
    assert_output --partial 'opencode name=<> args= active=<> pi_load=<>'
  done

  run env HERDR_ENV=1 HERDR_PANE_ID=w1:p2 PROBE_NAME=silver-ibis PROBE_PANE=w1:p9 \
    HERDR_ALIAS_ALLOCATOR="$stub/allocator" PATH="$stub:$PATH" bash "$launcher" opencode
  assert_success
  assert_output --partial 'opencode name=<> args= active=<> pi_load=<>'

  run env HERDR_ENV=1 HERDR_PANE_ID=w1:p2 PROBE_NAME=silver-ibis PROBE_STATUS=1 \
    HERDR_ALIAS_ALLOCATOR="$stub/allocator" PATH="$stub:$PATH" bash "$launcher" opencode
  assert_success
  assert_output --partial 'opencode name=<> args= active=<> pi_load=<>'

  run env HERDR_ENV=1 HERDR_PANE_ID=w1:p2 PROBE_NAME=silver-ibis \
    HERDR_ALIAS_ALLOCATOR=/nonexistent/allocator PATH="$stub:$PATH" bash "$launcher" opencode
  assert_success
  assert_output --partial 'opencode name=<> args= active=<> pi_load=<>'
}

function test_scripts_1346_agent_intercom_launcher_claims_an_alias_for_a_pane_with_no_record() {
  _bats_test_init 1346 'agent intercom launcher claims an alias for a pane with no record'
  local launcher="$SOURCE_ROOT/dot_local/bin/executable_herdr-agent-intercom"
  local release="$SOURCE_ROOT/dot_local/bin/executable_herdr-agent-intercom-release"
  local stub home log marker
  stub="$(agent_intercom_stub_bin)"
  home="$BATS_TEST_TMPDIR/agent-intercom-home"
  log="$BATS_TEST_TMPDIR/claim-calls"
  marker="$home/.local/state/agent-intercom/claims/w1_p2"

  # #given a pane Herdr has no agent record for. The real CLI reports that on
  # stderr and exits 1 -- measured against herdr v0.9.1, not taken from the
  # launcher -- so the stub answers the same way or the launcher is never
  # exercised on the one input this feature exists for.
  cat > "$stub/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAIM_LOG"
case "$1 $2" in
  'agent get')
    printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"},"id":"cli:agent:get"}\n' "$3" >&2
    exit 1
    ;;
  'agent explain')
    printf 'agent: claude\nstate: working\nrule: osc_title_working (region=osc_title priority=1100)\n'
    exit 0
    ;;
  'pane report-agent'|'pane release-agent') exit 0 ;;
  'agent rename')
    [[ "$4" == "${RENAME_REJECT:-}" ]] && exit 1
    exit 0
    ;;
esac
exit 2
SH
  cat > "$stub/herdr-peer-alias" <<'SH'
#!/usr/bin/env bash
shift
for taken in "$@"; do
  [[ "$taken" == ochre-okapi ]] && { printf 'silver-ibis\n'; exit 0; }
done
printf '%s\n' "${PEER_ALIAS:-ochre-okapi}"
SH
  chmod +x "$stub/herdr" "$stub/herdr-peer-alias"

  # #when Claude starts by hand in that pane
  : > "$log"; rm -f "$marker"
  run env HERDR_ENV=1 HERDR_PANE_ID=w1:p2 CLAIM_LOG="$log" \
    HERDR_ALIAS_ALLOCATOR="$stub/allocator" \
    HOME="$home" PATH="$stub:$PATH" bash "$launcher" claude

  # #then it enrolls under the allocated name instead of warning
  assert_success
  assert_output --partial '<--name><ochre-okapi><--claude><'
  assert_file_contains "$log" 'pane report-agent w1:p2 --source herdr-agent-intercom --agent claude --state unknown'
  assert_file_contains "$log" 'agent rename w1:p2 ochre-okapi'

  # #then the claim it recorded is the one the release command acts on
  assert_file_contains "$marker" 'claude'
  : > "$log"
  run env HERDR_PANE_ID=w1:p2 CLAIM_LOG="$log" HOME="$home" PATH="$stub:$PATH" bash "$release"
  assert_success
  assert_file_contains "$log" 'pane release-agent w1:p2 --source herdr-agent-intercom --agent claude'
  assert_file_not_exists "$marker"

  # #when the server rejects the first name, as a concurrent launcher would cause
  : > "$log"; rm -f "$marker"
  run env HERDR_ENV=1 HERDR_PANE_ID=w1:p2 CLAIM_LOG="$log" RENAME_REJECT=ochre-okapi \
    HERDR_ALIAS_ALLOCATOR="$stub/allocator" \
    HOME="$home" PATH="$stub:$PATH" bash "$launcher" claude

  # #then it gives the first claim back and enrolls under the next candidate
  assert_success
  assert_output --partial '<--name><silver-ibis><--claude><'
  assert_file_contains "$log" 'pane release-agent w1:p2 --source herdr-agent-intercom --agent claude'

  # #when the allocator can only answer with an out-of-pool placeholder
  : > "$log"; rm -f "$marker"
  run env HERDR_ENV=1 HERDR_PANE_ID=w1:p2 CLAIM_LOG="$log" PEER_ALIAS=unnamed-alpha \
    HERDR_ALIAS_ALLOCATOR="$stub/allocator" \
    HOME="$home" PATH="$stub:$PATH" bash "$launcher" claude

  # #then it reports nothing and releases nothing, and the client starts bare
  assert_success
  assert_output --partial 'canonical pane alias unavailable; starting claude without Intercom'
  assert_equal "$(grep -c 'pane report-agent' "$log")" 0
  assert_equal "$(grep -c 'pane release-agent' "$log")" 0
  assert_file_not_exists "$marker"

  # #when the client is one with no surface that could ever release a claim
  : > "$log"; rm -f "$marker"
  run env HERDR_ENV=1 HERDR_PANE_ID=w1:p2 CLAIM_LOG="$log" \
    HERDR_ALIAS_ALLOCATOR="$stub/allocator" \
    HOME="$home" PATH="$stub:$PATH" bash "$launcher" opencode

  # #then it takes no claim at all rather than leaking one for the session
  assert_success
  assert_output --partial 'canonical pane alias unavailable; starting opencode without Intercom'
  assert_equal "$(grep -c 'pane report-agent' "$log")" 0
  assert_file_not_exists "$marker"

  # #when the allocator command is absent entirely
  rm -f "$stub/herdr-peer-alias"
  : > "$log"
  run env HERDR_ENV=1 HERDR_PANE_ID=w1:p2 CLAIM_LOG="$log" \
    HERDR_ALIAS_ALLOCATOR="$stub/allocator" \
    HOME="$home" PATH="$stub:$PATH" bash "$launcher" claude

  # #then the pane keeps its unclaimed state and the client starts without Intercom
  assert_success
  assert_output --partial 'canonical pane alias unavailable; starting claude without Intercom'
  assert_equal "$(grep -c 'pane report-agent' "$log")" 0
}

function test_scripts_1347_agent_intercom_release_hands_state_back_only_when_detection_can_take_over() {
  _bats_test_init 1347 'agent intercom release hands pane state back only when detection can take over'
  local release="$SOURCE_ROOT/dot_local/bin/executable_herdr-agent-intercom-release"
  local stub home log marker
  stub="$BATS_TEST_TMPDIR/release-bin"
  home="$BATS_TEST_TMPDIR/release-home"
  log="$BATS_TEST_TMPDIR/release-calls"
  marker="$home/.local/state/agent-intercom/claims/w1_p2"
  mkdir -p "$stub" "$(dirname "$marker")"

  # `rule: none` is what the real `herdr agent explain` prints whenever no rule
  # matched, which includes a pane whose detection the claim itself suppressed.
  # Measured against herdr v0.9.1.
  cat > "$stub/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RELEASE_LOG"
if [[ "$1 $2" == 'agent explain' ]]; then
  if [[ -n "${NO_RULE:-}" ]]; then
    printf 'agent: claude\nstate: idle\nrule: none\nfallback_reason: default_known_agent_idle_fallback\n'
  else
    printf 'agent: claude\nstate: working\nrule: osc_title_working (region=osc_title priority=1100)\n'
  fi
fi
exit 0
SH
  chmod +x "$stub/herdr"

  # #given a recorded claim on this pane, with detection already live
  printf 'claude\n' > "$marker"; : > "$log"
  # #when the release runs
  run env HERDR_PANE_ID=w1:p2 HERDR_AGENT_INTERCOM_CLAIM=w1:p2 \
    RELEASE_LOG="$log" HOME="$home" PATH="$stub:$PATH" bash "$release"
  # #then authority goes back to Herdr and the claim cannot be released twice
  assert_success
  assert_file_contains "$log" 'pane release-agent w1:p2 --source herdr-agent-intercom --agent claude'
  assert_file_not_exists "$marker"

  # #given a claim whose launcher is gone, so nothing exports the claim variable
  printf 'claude\n' > "$marker"; : > "$log"
  # #when the release runs in a successor session
  run env HERDR_PANE_ID=w1:p2 RELEASE_LOG="$log" HOME="$home" PATH="$stub:$PATH" bash "$release"
  # #then the marker alone is enough to give the pane back
  assert_success
  assert_file_contains "$log" 'pane release-agent w1:p2 --source herdr-agent-intercom --agent claude'
  assert_file_not_exists "$marker"

  # #given the same claim but no detection rule has matched yet
  printf 'claude\n' > "$marker"; : > "$log"
  # #when the release runs
  run env HERDR_PANE_ID=w1:p2 HERDR_AGENT_INTERCOM_CLAIM=w1:p2 NO_RULE=1 \
    RELEASE_LOG="$log" HOME="$home" PATH="$stub:$PATH" bash "$release"
  # #then it holds the claim, because releasing now destroys the record
  assert_success
  assert_equal "$(grep -c 'pane release-agent' "$log")" 0
  assert_file_exists "$marker"

  # #given a pane no launcher ever claimed
  rm -f "$marker"; : > "$log"
  # #when the release runs
  run env HERDR_PANE_ID=w1:p2 RELEASE_LOG="$log" HOME="$home" PATH="$stub:$PATH" bash "$release"
  # #then it touches nothing
  assert_success
  assert_equal "$(wc -c < "$log" | tr -d ' ')" 0

  # #given a claim recorded against a different pane
  printf 'claude\n' > "$marker"; : > "$log"
  # #when the release runs in a pane that is not the claimed one
  run env HERDR_PANE_ID=w1:p9 HERDR_AGENT_INTERCOM_CLAIM=w1:p2 RELEASE_LOG="$log" \
    HOME="$home" PATH="$stub:$PATH" bash "$release"
  # #then it refuses to release a pane that is not its own
  assert_success
  assert_equal "$(wc -c < "$log" | tr -d ' ')" 0
  assert_file_exists "$marker"
}

function test_scripts_1333_agent_intercom_launcher_passes_through_an_unidentified_herdr_session() {
  _bats_test_init 1333 'agent intercom launcher passes through an unidentified Herdr session'
  local launcher="$SOURCE_ROOT/dot_local/bin/executable_herdr-agent-intercom"
  local stub
  stub="$(agent_intercom_stub_bin)"

  run env HERDR_ENV=1 HERDR_CHILD_NAME= HERDR_PANE_ID= \
    HOME="$BATS_TEST_TMPDIR/agent-intercom-home" PATH="$stub:$PATH" bash "$launcher" pi

  assert_success
  assert_output --partial 'canonical pane alias unavailable; starting pi without Intercom'
  assert_output --partial 'pi name=<> args= active=<> pi_load=<>'

  cat > "$stub/herdr" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$stub/herdr"
  run env HERDR_ENV=1 HERDR_CHILD_NAME= HERDR_PANE_ID=w1:p2 \
    HOME="$BATS_TEST_TMPDIR/agent-intercom-home" PATH="$stub:$PATH" bash "$launcher" claude
  assert_success
  assert_output --partial 'canonical pane alias unavailable; starting claude without Intercom'
  assert_output --partial 'claude name=<> args= active=<> pi_load=<>'
}

function test_scripts_1334_agent_intercom_shell_wrappers_only_intercept_herdr_launches() {
  _bats_test_init 1334 'agent intercom shell wrappers only intercept Herdr launches'
  local aliases="$SOURCE_ROOT/dot_aliases"
  local launcher="$SOURCE_ROOT/dot_local/bin/executable_herdr-agent-intercom"
  local stub home="$BATS_TEST_TMPDIR/agent-intercom-home"
  stub="$(agent_intercom_stub_bin)"
  mkdir -p "$home/.local/bin"
  export HERDR_PANE_ID=w1:p2 HERDR_ALIAS_ALLOCATOR="$stub/allocator"
  cp "$launcher" "$home/.local/bin/herdr-agent-intercom"
  chmod +x "$home/.local/bin/herdr-agent-intercom"

  run env -u HERDR_ENV -u HERDR_CHILD_NAME -u HERDR_PANE_ID HOME="$home" PATH="$stub:/usr/bin:/bin" \
    zsh -fc 'source "$1"; opencode --model test/model' _ "$aliases"
  assert_success
  assert_output 'opencode name=<> args= active=<> pi_load=<><--model><test/model>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$home" PATH="$stub:/usr/bin:/bin" \
    zsh -fc 'source "$1"; opencode --model test/model' _ "$aliases"
  assert_success
  assert_output 'opencode name=<ochre-okapi> args= active=<1> pi_load=<><--model><test/model>'
}

function test_scripts_1337_agent_intercom_launcher_preserves_utility_and_nested_commands() {
  _bats_test_init 1337 'agent intercom launcher preserves utility commands and nested launches'
  local launcher="$SOURCE_ROOT/dot_local/bin/executable_herdr-agent-intercom"
  local stub
  stub="$(agent_intercom_stub_bin)"
  export HERDR_PANE_ID=w1:p2 HERDR_ALIAS_ALLOCATOR="$stub/allocator"

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/agent-intercom-home" \
    PATH="$stub:$PATH" bash "$launcher" claude mcp list
  assert_success
  assert_output 'claude name=<> args= active=<> pi_load=<><mcp><list>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/agent-intercom-home" \
    PATH="$stub:$PATH" bash "$launcher" claude --verbose plugins list
  assert_success
  assert_output 'claude name=<> args= active=<> pi_load=<><--verbose><plugins><list>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/agent-intercom-home" \
    PATH="$stub:$PATH" bash "$launcher" claude --plugin-dir /tmp mcp list
  assert_success
  assert_output 'claude name=<> args= active=<> pi_load=<><--plugin-dir></tmp><mcp><list>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/agent-intercom-home" \
    PATH="$stub:$PATH" bash "$launcher" claude -c --no-session-persistence mcp list
  assert_success
  assert_output 'claude name=<> args= active=<> pi_load=<><-c><--no-session-persistence><mcp><list>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/agent-intercom-home" \
    PATH="$stub:$PATH" bash "$launcher" claude upgrade
  assert_success
  assert_output 'claude name=<> args= active=<> pi_load=<><upgrade>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/agent-intercom-home" \
    PATH="$stub:$PATH" bash "$launcher" claude --debug mcp list
  assert_success
  assert_output --partial 'active=<1> pi_load=<><--tui><--transport><mcp><--name><ochre-okapi>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/agent-intercom-home" \
    PATH="$stub:$PATH" bash "$launcher" claude --mcp-config mcp --model sonnet
  assert_success
  assert_output --partial 'active=<1> pi_load=<><--model><sonnet><--tui><--transport><mcp><--name><ochre-okapi>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/agent-intercom-home" \
    PATH="$stub:$PATH" bash "$launcher" claude --tools Read mcp list
  assert_success
  assert_output --partial 'active=<1> pi_load=<><--tui><--transport><mcp><--name><ochre-okapi>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/agent-intercom-home" \
    PATH="$stub:$PATH" bash "$launcher" claude --model sonnet -p prompt
  assert_success
  assert_output 'claude name=<> args= active=<> pi_load=<><--model><sonnet><-p><prompt>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/agent-intercom-home" \
    PATH="$stub:$PATH" bash "$launcher" pi list
  assert_success
  assert_output 'pi name=<> args= active=<> pi_load=<><list>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/agent-intercom-home" \
    PATH="$stub:$PATH" bash "$launcher" pi --offline -p prompt
  assert_success
  assert_output 'pi name=<> args= active=<> pi_load=<><--offline><-p><prompt>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/agent-intercom-home" \
    PATH="$stub:$PATH" bash "$launcher" pi --export session.jsonl output.html
  assert_success
  assert_output 'pi name=<> args= active=<> pi_load=<><--export><session.jsonl><output.html>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/missing-intercom" \
    PATH="$stub:$PATH" bash "$launcher" claude
  assert_success
  assert_output 'claude name=<> args= active=<1> pi_load=<>'

  rm -f "$BATS_TEST_TMPDIR/agent-intercom-home/.local/share/agent-intercom/node_modules/@dataforxyz/agent-intercom-claude/dist/inbox-monitor.mjs"
  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HOME="$BATS_TEST_TMPDIR/agent-intercom-home" \
    PATH="$stub:$PATH" bash "$launcher" claude
  assert_success
  assert_output 'claude name=<> args= active=<1> pi_load=<>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=unrelated-launch-name HERDR_AGENT_INTERCOM_ACTIVE=1 \
    HERDR_AGENT_INTERCOM_NAME=ochre-okapi HERDR_AGENT_INTERCOM_PANE=w1:p2 \
    HOME="$BATS_TEST_TMPDIR/agent-intercom-home" PATH="$stub:$PATH" \
    bash "$launcher" opencode run prompt
  assert_success
  assert_output 'opencode name=<> args= active=<1> pi_load=<><run><prompt>'

  run env HERDR_ENV=1 HERDR_CHILD_NAME=ochre-okapi HERDR_AGENT_INTERCOM_ACTIVE=1 \
    HERDR_PANE_ID=w1:p3 HERDR_AGENT_INTERCOM_NAME=ochre-okapi HERDR_AGENT_INTERCOM_PANE=w1:p2 \
    HOME="$BATS_TEST_TMPDIR/agent-intercom-home" PATH="$stub:$PATH" \
    bash "$launcher" opencode
  assert_success
  assert_output 'opencode name=<violet-tern> args= active=<1> pi_load=<>'
}

function test_scripts_1335_agent_intercom_claude_bridge_preserves_native_arguments() {
  _bats_test_init 1335 'agent intercom Claude bridge preserves native arguments after cci reparses its controls'
  local bridge="$SOURCE_ROOT/dot_local/bin/executable_herdr-agent-intercom-claude"
  local stub
  stub="$(agent_intercom_stub_bin)"

  run env AGENT_INTERCOM_CLAUDE_COMMAND="$stub/claude" AGENT_INTERCOM_CLAUDE_ARGC=4 \
    AGENT_INTERCOM_CLAUDE_ARG_0=--disallowed-tools \
    AGENT_INTERCOM_CLAUDE_ARG_1='Edit Write NotebookEdit AskUserQuestion' \
    AGENT_INTERCOM_CLAUDE_ARG_2='prompt with spaces' AGENT_INTERCOM_CLAUDE_ARG_3= \
    bash "$bridge" --plugin-dir /managed/intercom --permission-mode manual

  assert_success
  assert_output 'claude name=<> args= active=<> pi_load=<><--disallowed-tools><Edit Write NotebookEdit AskUserQuestion><prompt with spaces><><--plugin-dir></managed/intercom>'

  run env AGENT_INTERCOM_CLAUDE_COMMAND="$stub/claude" AGENT_INTERCOM_CLAUDE_ARGC=2 \
    AGENT_INTERCOM_CLAUDE_ARG_0=--permission-mode AGENT_INTERCOM_CLAUDE_ARG_1=acceptEdits \
    bash "$bridge" --plugin-dir /managed/intercom --permission-mode manual
  assert_success
  assert_output 'claude name=<> args= active=<> pi_load=<><--permission-mode><acceptEdits><--plugin-dir></managed/intercom>'

  run env AGENT_INTERCOM_CLAUDE_COMMAND="$stub/claude" AGENT_INTERCOM_CLAUDE_ARGC=3 \
    AGENT_INTERCOM_CLAUDE_ARG_0=-- AGENT_INTERCOM_CLAUDE_ARG_1=--model \
    AGENT_INTERCOM_CLAUDE_ARG_2=literal \
    bash "$bridge" --plugin-dir /managed/intercom
  assert_success
  assert_output 'claude name=<> args= active=<> pi_load=<><--plugin-dir></managed/intercom><--><--model><literal>'

  run env AGENT_INTERCOM_CLAUDE_COMMAND="$stub/claude" AGENT_INTERCOM_CLAUDE_ARGC=0 \
    bash "$bridge" --plugin-dir /managed/intercom
  assert_success
  assert_output 'claude name=<> args= active=<> pi_load=<><--plugin-dir></managed/intercom>'
}

function test_scripts_1336_agent_intercom_claude_bridge_scrubs_its_transport_environment() {
  _bats_test_init 1336 'agent intercom Claude bridge scrubs transported arguments before starting Claude'
  local bridge="$SOURCE_ROOT/dot_local/bin/executable_herdr-agent-intercom-claude"
  local stub="$BATS_TEST_TMPDIR/agent-intercom-clean-claude"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
if [[ -n "${AGENT_INTERCOM_CLAUDE_COMMAND:-}" || -n "${AGENT_INTERCOM_CLAUDE_ARGC:-}" || -n "${AGENT_INTERCOM_CLAUDE_ARG_0:-}" ]]; then
  exit 9
fi
printf '<%s>' "$@"
SH
  chmod +x "$stub"

  run env AGENT_INTERCOM_CLAUDE_COMMAND="$stub" AGENT_INTERCOM_CLAUDE_ARGC=1 \
    AGENT_INTERCOM_CLAUDE_ARG_0='private prompt' bash "$bridge" --plugin-dir /managed/intercom

  assert_success
  assert_output '<private prompt><--plugin-dir></managed/intercom>'
}

# Mint every stub through here. A test that stubs herdr more than once
# re-points CHILD_STUB, and teardown used to see only the last value, so each
# earlier stub — and any watcher armed against it — was abandoned
# (docs/solutions/design-patterns/outliving-processes-hang-the-suite.md).
child_new_stub() {
  CHILD_STUB="$(mktemp -d)"
  export CHILD_STUB
  child_register_stub "$CHILD_STUB"
}

# For a directory the caller names itself rather than one minted above.
child_register_stub() {
  CHILD_STUBS+=("$1")
}

# A launch leaves its watcher armed on purpose and writes the pid to a path the
# next launch may reuse, so a stub's pid files record what teardown happens to
# have been told, not what is running. The watcher's --run-dir names its stub,
# so ask the process table instead.
# The whole identity -- watcher and stub -- never half of it.
child_stub_pid_is_watcher() {
  ps -o args= -p "$1" 2>/dev/null | grep -F 'herdr-child __watcher' \
    | grep -Fq -- "--run-dir $2/"
}

child_stub_watcher_pids() {
  local stub="$1" pid
  for pid in $(ps -axo pid=,args= | awk -v marker="--run-dir $stub/" '
    index($0, "herdr-child __watcher") && index($0, marker) { print $1 }'); do
    # The snapshot is stale by the time it is read and pids get recycled.
    child_stub_pid_is_watcher "$pid" "$stub" || continue
    printf '%s\n' "$pid"
  done
}

# A second argument re-verifies identity before the kill. Callers that read a
# pid out of a file pass none: reply.pid holds a test's own process rather than
# a watcher, so a watcher check there would stop reaping it altogether.
child_stub_stop_pid() {
  local pid="$1" stub="${2:-}" attempt=0
  kill -TERM "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [[ "$attempt" -lt 100 ]]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  kill -0 "$pid" 2>/dev/null || return 0
  # A watcher that survives TERM (e.g., stuck publishing through a deleted
  # stub) must not outlive the test (docs/solutions/design-patterns/outliving-processes-hang-the-suite.md).
  # The scan proved this pid a watcher up to a second ago, not now, so prove it
  # again before the kill -- tests/run-post-apply.sh re-verifies at both points
  # for the same reason.
  if [[ -n "$stub" ]]; then
    child_stub_pid_is_watcher "$pid" "$stub" || return 0
  fi
  kill -KILL "$pid" 2>/dev/null || true
}

# Reap before removing: rm -rf against a live writer is a race the writer wins.
child_stub_reap() {
  local stub="$1" pid_file pid
  [[ -d "$stub" ]] || return 0
  : > "$stub/release-watcher" 2>/dev/null || true
  for pid_file in "$stub"/*.pid; do
    [[ -s "$pid_file" ]] || continue
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [[ -n "$pid" ]] || continue
    child_stub_stop_pid "$pid"
  done
  for pid in $(child_stub_watcher_pids "$stub"); do
    child_stub_stop_pid "$pid" "$stub"
  done
  rm -rf "$stub"
}

child_reap_all_stubs() {
  local stub
  for stub in ${CHILD_STUBS[@]+"${CHILD_STUBS[@]}"}; do
    child_stub_reap "$stub"
  done
  CHILD_STUBS=()
  CHILD_STUB=""
}

teardown() {
  hwi_teardown
  local stub
  for stub in ${CHILD_STUBS[@]+"${CHILD_STUBS[@]}"}; do
    if [[ -e "$stub/reap-invalidated.ready" ]]; then
      : > "$stub/reap-invalidated.release"
    fi
  done
  if [[ -n "${CHILD_REAP_PID:-}" ]]; then
    local reap_attempt=0
    while kill -0 "$CHILD_REAP_PID" 2>/dev/null && [[ "$reap_attempt" -lt 100 ]]; do
      reap_attempt=$((reap_attempt + 1))
      sleep 0.01
    done
    if kill -0 "$CHILD_REAP_PID" 2>/dev/null; then
      kill -TERM "$CHILD_REAP_PID" 2>/dev/null || true
    fi
    wait "$CHILD_REAP_PID" 2>/dev/null || true
    CHILD_REAP_PID=""
  fi
  child_reap_all_stubs
  [[ -n "${BATS_TEST_TMPFILE:-}" ]] && rm -f "$BATS_TEST_TMPFILE" || true
  unset HERDR_WORKTREE_IDENTITY_DISABLE_ENGINES
}

# ===========================================
# herdr-worktree-identity state library
# ===========================================

function test_scripts_1209_shared_process_identity_is_stable_and_accepts_legacy_markers() {
  _bats_test_init 1209 'shared process identity is stable and accepts legacy persisted markers'
  local process_library="$SOURCE_ROOT/dot_local/lib/herdr-process.sh"
  local stub="$BATS_TEST_TMPDIR/process-identity-bin" log="$BATS_TEST_TMPDIR/process-identity-locales.log"
  mkdir -p "$stub"
  cat > "$stub/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${LC_ALL-<unset>}" >> "$PROCESS_IDENTITY_LOCALE_LOG"
if [ "${LC_ALL-}" = C ]; then
  printf '  Sat Sep 12 06:18:05 2026    \n'
else
  printf 'sam 12 sep 2026 06:18:05 UTC\n'
fi
SH
  chmod +x "$stub/ps"

  run env -u LC_ALL -u LC_CTYPE -u LANG PATH="$stub:$PATH" \
    PROCESS_IDENTITY_LOCALE_LOG="$log" bash -c '
      set -e
      source "$1"
      process_start_marker 42
      printf "\n"
      process_start_matches 42 "  Sat Sep 12 06:18:05 2026    "
      process_start_matches 42 "sam 12 sep 2026 06:18:05 UTC"
      ! process_start_matches 42 "wrong process start"
      ! process_start_marker invalid
    ' _ "$process_library"

  assert_success
  assert_output 'Sat Sep 12 06:18:05 2026'
  assert_file_contains "$log" '^C$'
  assert_file_contains "$log" '^<unset>$'
}

function test_scripts_1210_worktree_identity_state_library_claims_live_owners_and_recovers_dead_owners() {
  _bats_test_init 1210 'worktree identity claims live owners and recovers dead owners'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  local lock="$HWI_STATE/repositories/test/identity.claim" owner

  hwi_start_claim_holder "$lock" || fail 'second process did not acquire its claim'
  run acquire_claim "$lock" 3
  assert_failure 2
  run kill -0 "$HWI_HOLDER_PID"
  assert_success

  local no_ps="$HWI_WORK/no-ps"
  mkdir "$no_ps"
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$no_ps/ps"
  chmod +x "$no_ps/ps"
  run env PATH="$no_ps:$PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash -c 'source "$1"; acquire_claim "$2" 1' _ "$HWI_STATE_LIBRARY" "$lock"
  assert_failure 2
  run kill -0 "$HWI_HOLDER_PID"
  assert_success

  kill -KILL "$HWI_HOLDER_PID"
  wait "$HWI_HOLDER_PID" 2>/dev/null || true
  HWI_HOLDER_PID=""
  acquire_claim "$lock" 3 || fail 'dead owner claim was not recovered'
  owner="$claim_owner_id"
  release_claim "$lock" "$owner"
  assert_file_not_exists "$lock"
}

function test_scripts_1211_worktree_identity_state_library_recovers_malformed_claims_and_distinguishes_errors() {
  _bats_test_init 1211 'worktree identity recovers malformed claims and distinguishes contention from errors'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  local malformed="$HWI_STATE/malformed.claim" interrupted="$HWI_STATE/interrupted.claim" held="$HWI_STATE/held.claim"
  atomic_write "$malformed" "owner_id=$(encode_value malformed-owner)
pid=$$
process_start=$(encode_value '')"

  acquire_claim "$malformed" 3 || fail 'empty process-start claim was not recovered'
  release_claim "$malformed" "$claim_owner_id"

  : > "${interrupted}.candidate.abandoned"
  acquire_claim "$interrupted" 3 || fail 'interrupted owner write was not recovered'
  release_claim "$interrupted" "$claim_owner_id"

  hwi_start_claim_holder "$held" || fail 'second process did not acquire its claim'
  run acquire_claim "$held" 1
  assert_failure 2
  mkdir "$HWI_WORK/not-a-claim"
  run acquire_claim "$HWI_WORK/not-a-claim" 1
  assert_failure 1

  local no_ps="$HWI_WORK/no-ps" no_link="$HWI_WORK/no-link"
  mkdir "$no_ps" "$no_link"
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$no_ps/ps"
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$no_link/ln"
  chmod +x "$no_ps/ps" "$no_link/ln"
  run env PATH="$no_ps:$PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash -c 'source "$1"; acquire_claim "$2" 1' _ "$HWI_STATE_LIBRARY" "$HWI_STATE/no-token.claim"
  assert_failure 1
  assert_file_not_exists "$HWI_STATE/no-token.claim"
  run env PATH="$no_link:$PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash -c 'source "$1"; acquire_claim "$2" 1' _ "$HWI_STATE_LIBRARY" "$HWI_STATE/no-link.claim"
  assert_failure 1
}

function test_scripts_1212_worktree_identity_state_library_appends_diagnostics_and_preserves_preexisting_records() {
  _bats_test_init 1212 'worktree identity diagnostics append and failed pre-rename writes preserve records'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  local diagnostics="$HWI_STATE/worktree/diagnostics.log" record="$HWI_STATE/worktree/state"
  local stub="$HWI_WORK/stub"

  record_diagnostic "$diagnostics" marker-missing 'checkout=/tmp/first'
  record_diagnostic "$diagnostics" contended 'claim=repository'
  assert_file_contains "$diagnostics" '^reason=marker-missing observed_state=checkout=/tmp/first$'
  assert_file_contains "$diagnostics" '^reason=contended observed_state=claim=repository$'
  assert_equal "$(wc -l < "$diagnostics" | tr -d ' ')" 2

  atomic_write "$record" previous
  mkdir -p "$stub"
  cat > "$stub/mv" <<'SH'
#!/bin/sh
exit 1
SH
  chmod +x "$stub/mv"
  run env PATH="$stub:/usr/bin:/bin" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash -c 'source "$1"; atomic_write "$2" replacement' _ "$HWI_STATE_LIBRARY" "$record"
  assert_failure
  assert_file_contains "$record" '^previous$'
  run find "$(dirname "$record")" -name '.record.*' -print
  assert_success
  assert_output ''
}

# ===========================================
# herdr-worktree-identity engine (U2)
# ===========================================

function test_scripts_1213_worktree_identity_authorizes_a_real_plugin_marker_and_reentry_after_rename() {
  _bats_test_init 1213 'worktree identity authorizes the plugin marker after a real branch rename'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'name this task'
  assert_success
  local state marker
  state="$(hwi_identity_state_path)"
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  assert_file_contains "$marker" "^$HWI_BRANCH$"
  assert_equal "$(read_state_field "$state" original_branch)" "$HWI_BRANCH"
  assert_equal "$(read_state_field "$state" authorization)" authorized

  git -C "$HWI_CHECKOUT" branch -m task-derived-name
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'name this task again'
  assert_success
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" task-derived-name
  assert_equal "$(read_state_field "$state" original_branch)" "$HWI_BRANCH"
  assert_equal "$(read_state_field "$state" authorization)" authorized
}

function test_scripts_1214_worktree_identity_declines_missing_or_mismatched_markers_without_ref_mutation() {
  _bats_test_init 1214 'worktree identity declines absent and mismatched generated-worktree markers'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  local marker before state diagnostics
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  rm "$marker"
  before="$(git -C "$HWI_CHECKOUT" branch --show-current)"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'missing marker'
  assert_success
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$before"
  state="$(hwi_identity_state_path)"
  diagnostics="${state%.state}.diagnostics.log"
  assert_equal "$(read_state_field "$state" outcome)" declined
  assert_file_contains "$diagnostics" 'reason=marker-missing .*checkout='

  printf '%s\n' different-branch > "$marker"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'mismatched marker'
  assert_success
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$before"
  assert_file_contains "$diagnostics" 'reason=marker-mismatched .*marker_branch=different-branch'
}

function test_scripts_1215_worktree_identity_keeps_unresolved_events_retryable_and_prefers_reported_cwd() {
  _bats_test_init 1215 'worktree identity records unresolved pane reads and prefers reported working directories'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  : > "$HWI_WORK/fail-pane-get"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'retry later'
  assert_success
  local unresolved="$HWI_STATE/sessions/$(printf '%s' session-1 | base64 | tr '/+' '_-' | tr -d '=\n').state"
  assert_equal "$(read_state_field "$unresolved" outcome)" unresolved
  assert_file_contains "${unresolved%.state}.diagnostics.log" 'reason=pane-unreachable'

  rm "$HWI_WORK/fail-pane-get"
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_MAIN"
  local statusline="$SOURCE_ROOT/private_dot_claude/hooks/executable_statusline.sh" input
  input="$(jq -nc --arg dir "$HWI_CHECKOUT" --arg session session-1 \
    '{workspace:{current_dir:$dir},session_id:$session}')"
  run env HOME="$HWI_WORK/home" HERDR_ENV=1 HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_STATE_LIBRARY="$HWI_STATE_LIBRARY" \
    bash "$statusline" <<< "$input"
  assert_success
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'retry now'
  assert_success
  local state="$(hwi_identity_state_path)"
  assert_equal "$(read_state_field "$state" checkout_root)" "$(git -C "$HWI_CHECKOUT" rev-parse --show-toplevel)"
  assert_equal "$(read_state_field "$state" authorization)" authorized
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" retry-later
}

function test_scripts_1216_worktree_identity_waits_for_the_first_opencode_session_publication() {
  _bats_test_init 1216 'worktree identity waits for the first opencode session publication'
  hwi_setup
  hwi_create_generated_worktree
  hwi_delay_pane_session_publication pane-1 opencode session-1 workspace-1 "$HWI_CHECKOUT"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_PANE_SESSION_RETRY_DELAY=0 \
    bash "$HWI_ENGINE" --worker --agent opencode --session session-1 --pane pane-1 --workspace workspace-1 \
    <<< 'Rename on first OpenCode prompt'
  assert_success
  assert_file_exists "$HWI_WORK/pane-session-published"
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" rename-on-first-opencode-prompt
}

function test_scripts_1217_worktree_identity_declines_primary_checkouts_and_unmatched_sessions() {
  _bats_test_init 1217 'worktree identity declines primary checkouts and records unmatched sessions as unresolved'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_MAIN"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'primary checkout'
  assert_success
  local state="$HWI_STATE/sessions/$(printf '%s' session-1 | base64 | tr '/+' '_-' | tr -d '=\n').state"
  assert_equal "$(read_state_field "$state" outcome)" declined
  assert_file_contains "${state%.state}.diagnostics.log" 'reason=primary-checkout .*checkout='

  hwi_write_snapshot_without_match
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-2 --workspace workspace-1 <<< 'no pane for this session'
  assert_success
  state="$HWI_STATE/sessions/$(printf '%s' session-2 | base64 | tr '/+' '_-' | tr -d '=\n').state"
  assert_equal "$(read_state_field "$state" outcome)" unresolved
  assert_file_contains "${state%.state}.diagnostics.log" 'reason=pane-unresolved .*pane=missing'

  hwi_write_pane pane-2 codex session-3 workspace-1 "$HWI_CHECKOUT"
  hwi_write_snapshot_from_pane
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-3 --workspace workspace-1 <<< 'resolve from snapshot'
  assert_success
  assert_equal "$(read_state_field "$(hwi_identity_state_path)" authorization)" authorized
}

function test_scripts_1218_worktree_identity_foreground_hands_off_to_a_detached_worker() {
  _bats_test_init 1218 'worktree identity foreground hands prompt processing to a detached worker'
  hwi_setup
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  : > "$HWI_WORK/block-pane-get"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'do not place this prompt on argv'
  assert_success
  run find "$HWI_STATE/first-prompts" -type f
  assert_success
  local prompt_record="$output"
  assert_file_contains "$prompt_record" '^do not place this prompt on argv$'
  local attempt=0
  while [[ ! -e "$HWI_WORK/pane-get.ready" && "$attempt" -lt 3000 ]]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$HWI_WORK/pane-get.ready"
  assert_file_not_contains "$HWI_WORK/herdr.calls" 'do not place this prompt on argv'
  : > "$HWI_WORK/pane-get.release"
}

function test_scripts_12182_worktree_identity_worker_closes_inherited_descriptors() {
  _bats_test_init 12182 'worktree identity worker closes inherited descriptors'
  hwi_setup
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  : > "$HWI_WORK/block-pane-get"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HWI_ENGINE="$HWI_ENGINE" \
    HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" python3 - <<'PY'
import os
from pathlib import Path
import select
import signal
import subprocess
import time

work = Path(os.environ["HWI_WORK"])
release = work / "pane-get.release"
ready = work / "pane-get.ready"
control_read, control_write = os.pipe()
os.set_inheritable(control_write, True)
proc = subprocess.Popen(
    [
        "bash",
        os.environ["HWI_ENGINE"],
        "--worker",
        "--agent", "codex",
        "--session", "session-1",
        "--pane", "pane-1",
        "--workspace", "workspace-1",
    ],
    stdin=subprocess.PIPE,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    text=True,
    env=os.environ.copy(),
    pass_fds=(control_write,),
)
try:
    assert proc.stdin is not None
    proc.stdin.write("descriptor handoff\n")
    proc.stdin.close()
    os.close(control_write)
    control_write = -1

    deadline = time.monotonic() + 30
    while not ready.exists() and time.monotonic() < deadline:
        if proc.poll() is not None:
            raise AssertionError(f"worker exited before the controlled block with {proc.returncode}")
        time.sleep(0.02)
    if not ready.exists():
        raise AssertionError("worker did not reach the controlled block")
    if proc.poll() is not None:
        raise AssertionError("worker exited after publishing the controlled block")

    readable, _, _ = select.select([control_read], [], [], 1)
    if not readable or os.read(control_read, 1) != b"":
        raise AssertionError("worker retained the inherited control descriptor")
finally:
    release.touch()
    os.close(control_read)
    if control_write >= 0:
        os.close(control_write)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.send_signal(signal.SIGKILL)
        proc.wait()
PY
  assert_success
}

# ===========================================
# herdr-worktree-identity naming derivation (U3)
# ===========================================

hwi_write_naming_stub() {
  local binary="$1"
  cat > "$HWI_STUB/$binary" <<'SH'
#!/usr/bin/env bash
name="${0##*/}"
printf '%s\n' "$*" >> "$HWI_WORK/$name.calls"
printf '%s' "${HERDR_WORKTREE_IDENTITY_ACTIVE:-}" > "$HWI_WORK/$name.guard"
cat > "$HWI_WORK/$name.stdin"
cat "$HWI_WORK/$name.output"
SH
  chmod +x "$HWI_STUB/$binary"
}

function test_scripts_1219_worktree_identity_uses_normalized_multi_word_pi_identity() {
  _bats_test_init 1219 'worktree identity uses a normalized multi-word pi identity'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  hwi_write_naming_stub pi
  hwi_write_naming_stub claude
  printf '%s\n' '{"branch":"Normalize API Tokens"}' > "$HWI_WORK/pi.output"
  printf '%s\n' 'unexpected claude fallback' > "$HWI_WORK/claude.output"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_DISABLE_ENGINES=0 \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Normalize API tokens from model output'
  assert_success
  local state="$(hwi_identity_state_path)"
  assert_equal "$(read_state_field "$state" title)" normalize-api-tokens
  assert_equal "$(read_state_field "$state" slug)" normalize-api-tokens
  assert_file_contains "$HWI_WORK/pi.stdin" 'First prompt of the session:'
  assert_file_not_contains "$HWI_WORK/pi.calls" 'Normalize API tokens from model output'
  assert_equal "$(cat "$HWI_WORK/pi.guard")" 1
  assert_file_not_exists "$HWI_WORK/claude.calls"
}

function test_scripts_1220_worktree_identity_rejects_one_word_and_non_json_model_slugs() {
  _bats_test_init 1220 'worktree identity falls back for one-word and non-JSON model slugs'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  hwi_write_naming_stub pi
  hwi_write_naming_stub claude
  printf '%s\n' '{"branch":"json"}' > "$HWI_WORK/pi.output"
  printf '%s\n' 'not JSON' > "$HWI_WORK/claude.output"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_DISABLE_ENGINES=0 \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'json'
  assert_success
  local state="$(hwi_identity_state_path)"
  assert_equal "$(read_state_field "$state" title)" json-generated
  assert_equal "$(read_state_field "$state" slug)" json-generated
  assert_file_exists "$HWI_WORK/pi.calls"
  assert_file_exists "$HWI_WORK/claude.calls"
}

function test_scripts_1221_worktree_identity_falls_back_without_model_clis_and_caps_slugs() {
  _bats_test_init 1221 'worktree identity falls back without model CLIs and caps long slugs'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  local minimal="$HWI_WORK/minimal"
  mkdir "$minimal"
  ln -s "$(command -v jq)" "$minimal/jq"
  ln -s "$(command -v git)" "$minimal/git"

  run env PATH="$HWI_STUB:$minimal:/usr/bin:/bin" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_DISABLE_ENGINES=0 \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'json'
  assert_success
  local state="$(hwi_identity_state_path)"
  assert_equal "$(read_state_field "$state" title)" json-generated
  assert_equal "$(read_state_field "$state" slug)" json-generated

  rm "$state"
  git -C "$HWI_CHECKOUT" branch -m "$HWI_BRANCH"
  hwi_write_naming_stub pi
  printf '%s\n' '{"branch":"unusuallylongword-verylongsecondword-verylongthirdword-verylongfourthword-verylongfifthword"}' > "$HWI_WORK/pi.output"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_DISABLE_ENGINES=0 \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'a different prompt'
  assert_success
  state="$(hwi_identity_state_path)"
  local slug="$(read_state_field "$state" slug)"
  assert_equal "$(read_state_field "$state" title)" "$slug"
  assert_equal "${#slug}" 40
  run test "${slug%-}" = "$slug"
  assert_success
  run test "$(printf '%s' "$slug" | tr '-' '\n' | grep -c '.')" -ge 2
  assert_success
}

# Consumer: the naming chain when an engine wraps its object in a markdown
# fence. `claude -p` does it for this prompt every time, and jq rejected the
# fenced text, so a correct branch name was discarded and the slug fell back to
# the first prompt line -- a whole pasted issue URL as the branch name.
#
# Oracle: the identical payload without the fence, which test 1219 already pins
# and this patch does not change. Both forms must yield the same identity, and
# the prompt here is the URL that made the regression visible.
function test_scripts_1222_worktree_identity_accepts_a_fenced_model_object() {
  _bats_test_init 1222 'worktree identity accepts a model object wrapped in a markdown fence'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  hwi_write_naming_stub pi
  hwi_write_naming_stub claude
  printf '%s\n' '```json' '{"branch":"Normalize API Tokens"}' '```' > "$HWI_WORK/pi.output"
  printf '%s\n' 'unexpected claude fallback' > "$HWI_WORK/claude.output"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_DISABLE_ENGINES=0 \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'https://linear.app/membranehq/issue/PRD-2939/fix-agent-launch-timeout'
  assert_success
  local state="$(hwi_identity_state_path)"
  assert_equal "$(read_state_field "$state" title)" normalize-api-tokens
  assert_equal "$(read_state_field "$state" slug)" normalize-api-tokens
  assert_file_not_exists "$HWI_WORK/claude.calls"
}

# Consumer: the naming chain when a provider withdraws the configured model.
# It happened twice in one afternoon -- codex stopped serving gpt-5.4-mini to
# this account, OpenRouter retired qwen3-coder:free -- and with one hardcoded
# entry every generated worktree silently took the slugified prompt line as its
# branch, so a pasted issue URL became the branch name.
#
# Oracle: the second model's valid payload must produce the identity that test
# 1219 already pins for the single-model path, and the stub's own call log is
# independent evidence that the dead model was tried first and the live one was
# reached. The stub decides from the model argument, not from call order.
hwi_write_rotating_naming_stub() {
  cat > "$HWI_STUB/pi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HWI_WORK/pi.calls"
cat > "$HWI_WORK/pi.stdin"
for arg in "$@"; do
  if [ "$arg" = "$HWI_DEAD_MODEL" ]; then
    printf '404: {"message":"No endpoints found for %s.","code":404}\n' "$arg"
    exit 0
  fi
done
cat "$HWI_WORK/pi.output"
SH
  chmod +x "$HWI_STUB/pi"
}

function test_scripts_1223_worktree_identity_rotates_past_a_withdrawn_model() {
  _bats_test_init 1223 'worktree identity rotates past a withdrawn model to the next one'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  hwi_write_rotating_naming_stub
  hwi_write_naming_stub claude
  printf '%s\n' '{"branch":"Normalize API Tokens"}' > "$HWI_WORK/pi.output"
  printf '%s\n' 'unexpected claude fallback' > "$HWI_WORK/claude.output"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_DISABLE_ENGINES=0 \
    HERDR_WORKTREE_IDENTITY_PI_MODELS='withdrawn/model:free,live/model:free' \
    HWI_DEAD_MODEL='withdrawn/model:free' \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'https://linear.app/membranehq/issue/PRD-2939/fix-agent-launch-timeout'
  assert_success
  local state="$(hwi_identity_state_path)"
  assert_equal "$(read_state_field "$state" title)" normalize-api-tokens
  assert_equal "$(read_state_field "$state" slug)" normalize-api-tokens
  assert_file_contains "$HWI_WORK/pi.calls" 'withdrawn/model:free'
  assert_file_contains "$HWI_WORK/pi.calls" 'live/model:free'
  assert_equal "$(wc -l < "$HWI_WORK/pi.calls" | tr -d ' ')" 2
  assert_file_not_exists "$HWI_WORK/claude.calls"
}

# ===========================================
# herdr-worktree-identity branch rename (U4)
# ===========================================

function test_scripts_1180_worktree_identity_renames_once_and_attributes_the_branch() {
  _bats_test_init 1180 'worktree identity renames an authorized branch once with durable attribution'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Implement focused branch attribution'
  assert_success
  local state marker branch attribution
  state="$(hwi_identity_state_path)"
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  branch="$(git -C "$HWI_CHECKOUT" branch --show-current)"
  attribution="Intentional rename by herdr-worktree-identity: $HWI_BRANCH -> $branch"
  assert_equal "$branch" implement-focused-branch-attribution
  run git -C "$HWI_CHECKOUT" show-ref --verify --quiet "refs/heads/$HWI_BRANCH"
  assert_failure 1
  assert_file_contains "$marker" "^$HWI_BRANCH$"
  assert_file_contains "$marker" "^$attribution$"
  assert_equal "$(hwi_branch_description "$branch")" "$attribution"
  assert_equal "$(read_state_field "$state" outcome)" complete
  assert_equal "$(read_state_field "$state" branch)" "$branch"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Implement focused branch attribution again'
  assert_success
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$branch"
  assert_equal "$(git -C "$HWI_CHECKOUT" reflog --format='%gs' "$branch" | grep -c '^Branch: renamed ')" 1
}

function test_scripts_1181_worktree_identity_suffixes_candidates_against_local_and_remote_refs() {
  _bats_test_init 1181 'worktree identity avoids local and remote-tracking branch candidates'
  hwi_setup
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  git -C "$HWI_MAIN" branch implement-candidate-collision
  hwi_add_remote_tracking_branch implement-candidate-collision-2

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Implement candidate collision'
  assert_success
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" implement-candidate-collision-3
  assert_equal "$(cat "$HWI_WORK/workspace.label")" implement-candidate-collision-3
  run git -C "$HWI_CHECKOUT" show-ref --verify --quiet refs/remotes/origin/implement-candidate-collision-2
  assert_success
}

function test_scripts_1182_worktree_identity_preserves_upstream_and_agent_moved_branches() {
  _bats_test_init 1182 'worktree identity leaves upstream and concurrently agent-moved branches untouched'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  hwi_set_upstream
  local state diagnostics
  state="$(hwi_identity_state_path)"
  diagnostics="${state%.state}.diagnostics.log"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Preserve upstream branch'
  assert_success
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$HWI_BRANCH"
  assert_file_contains "$diagnostics" '^reason=branch-has-upstream '

  git -C "$HWI_CHECKOUT" config --unset "branch.$HWI_BRANCH.remote"
  git -C "$HWI_CHECKOUT" config --unset "branch.$HWI_BRANCH.merge"
  # The upstream leg reaches its terminal workspace-only outcome. Reset this
  # fixture's independent agent-move control to a new naming lifecycle.
  rm "$state"
  local ready="$HWI_WORK/revalidate.ready" release="$HWI_WORK/revalidate.release"
  env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_TEST_REVALIDATE_READY="$ready" \
    HERDR_WORKTREE_IDENTITY_TEST_REVALIDATE_RELEASE="$release" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 \
    <<< 'Preserve agent move' &
  local worker_pid=$! attempt=0
  while [[ ! -e "$ready" && "$attempt" -lt 3000 ]]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$ready"
  git -C "$HWI_CHECKOUT" branch -m agent-chosen-name
  : > "$release"
  wait "$worker_pid"
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" agent-chosen-name
  assert_file_contains "$diagnostics" '^reason=branch-changed-before-rename '
}

function test_scripts_1183_worktree_identity_records_branch_and_attribution_failures_for_recovery() {
  _bats_test_init 1183 'worktree identity records rename and attribution failures and retries attribution'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  hwi_write_git_proxy
  : > "$HWI_WORK/fail-git-branch-m"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Record branch failure'
  assert_success
  local state="$(hwi_identity_state_path)" marker branch
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$HWI_BRANCH"
  assert_equal "$(read_state_field "$state" outcome)" branch-failed
  assert_file_contains "${state%.state}.diagnostics.log" '^reason=branch-rename-failed '
  assert_file_not_contains "$marker" 'Intentional rename by herdr-worktree-identity'

  rm "$HWI_WORK/fail-git-branch-m"
  : > "$HWI_WORK/fail-git-description"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Record branch failure'
  assert_success
  branch="$(git -C "$HWI_CHECKOUT" branch --show-current)"
  assert_equal "$branch" record-branch-failure
  assert_equal "$(read_state_field "$state" outcome)" attribution-failed
  assert_file_contains "${state%.state}.diagnostics.log" '^reason=attribution-failed '

  rm "$HWI_WORK/fail-git-description"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Record branch failure'
  assert_success
  assert_equal "$(read_state_field "$state" outcome)" complete
  assert_equal "$(hwi_branch_description "$branch")" "Intentional rename by herdr-worktree-identity: $HWI_BRANCH -> $branch"
}

function test_scripts_1184_worktree_identity_serializes_branch_mutation_with_a_barrier() {
  _bats_test_init 1184 'worktree identity allows exactly one branch mutation after a two-process barrier'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  local ready="$HWI_WORK/lifecycle.ready" release="$HWI_WORK/lifecycle.release" attempt_ready="$HWI_WORK/lifecycle-attempt.ready"
  env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_TEST_LIFECYCLE_READY="$ready" \
    HERDR_WORKTREE_IDENTITY_TEST_LIFECYCLE_RELEASE="$release" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Serialize branch mutation' &
  local first_pid=$!
  local attempt=0
  while [[ ! -e "$ready" && "$attempt" -lt 3000 ]]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$ready"
  env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_TEST_LIFECYCLE_ATTEMPT_READY="$attempt_ready" \
    HERDR_WORKTREE_IDENTITY_LIFECYCLE_CLAIM_ATTEMPTS=1 \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Later conflicting prompt' &
  local second_pid=$!
  attempt=0
  while [[ ! -e "$attempt_ready" && "$attempt" -lt 3000 ]]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$attempt_ready"
  wait "$second_pid"
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$HWI_BRANCH"
  assert_equal "$(hwi_workspace_rename_count)" 0
  assert_file_contains "$(hwi_identity_state_path | sed 's/\.state$/.diagnostics.log/')" '^reason=lifecycle-contended '
  : > "$release"
  wait "$first_pid"
  local branch="$(git -C "$HWI_CHECKOUT" branch --show-current)" state="$(hwi_identity_state_path)"
  assert_equal "$branch" serialize-branch-mutation
  assert_equal "$(git -C "$HWI_CHECKOUT" reflog --format='%gs' "$branch" | grep -c '^Branch: renamed ')" 1
  assert_equal "$(read_state_field "$state" outcome)" complete
  assert_equal "$(hwi_workspace_rename_count)" 1
}

function test_scripts_1185_worktree_identity_recovers_marker_attribution_after_write_failure() {
  _bats_test_init 1185 'worktree identity retries marker attribution after a successful rename'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  local marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  chmod a-w "$marker"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Recover marker attribution'
  assert_success
  local state="$(hwi_identity_state_path)" branch="$(git -C "$HWI_CHECKOUT" branch --show-current)"
  assert_equal "$branch" recover-marker-attribution
  assert_equal "$(read_state_field "$state" outcome)" attribution-failed
  assert_file_contains "${state%.state}.diagnostics.log" '^reason=attribution-failed '

  chmod u+w "$marker"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Recover marker attribution'
  assert_success
  assert_equal "$(read_state_field "$state" outcome)" complete
  assert_file_contains "$marker" '^Intentional rename by herdr-worktree-identity: worktree/quiet-stone-fd75 -> recover-marker-attribution$'
}

# ===========================================
# herdr-worktree-identity workspace outcomes (U5)
# ===========================================

# The independent oracle for workspace behavior is the herdr recorder: it
# observes a workspace rename call without granting this component ownership
# of pane, tab, or agent labels. Branch assertions read the fixture's real Git
# state, not the identity state file.
function test_scripts_1186_worktree_identity_reconciles_terminal_workspace_to_the_branch_name() {
  _bats_test_init 1186 'worktree identity reconciles a terminal workspace to the branch name'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Label workspace independently'
  assert_success
  local state="$(hwi_identity_state_path)" branch="$(git -C "$HWI_CHECKOUT" branch --show-current)"
  assert_equal "$branch" label-workspace-independently
  assert_equal "$(read_state_field "$state" outcome)" complete
  assert_equal "$(cat "$HWI_WORK/workspace.label")" "$branch"
  assert_equal "$(hwi_workspace_rename_count)" 1
  assert_file_not_contains "$HWI_WORK/herdr.calls" 'pane rename '
  assert_file_not_contains "$HWI_WORK/herdr.calls" 'tab rename '
  assert_file_not_contains "$HWI_WORK/herdr.calls" 'agent rename '

  printf '%s' 'Legacy workspace title' > "$HWI_WORK/workspace.label"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'A later event must not rename labels'
  assert_success
  assert_equal "$(cat "$HWI_WORK/workspace.label")" "$branch"
  assert_equal "$(hwi_workspace_rename_count)" 2
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$branch"
}

function test_scripts_1187_worktree_identity_labels_workspace_only_for_upstream_and_reverted_branches() {
  _bats_test_init 1187 'worktree identity keeps upstream and agent-reverted branches while labeling the workspace'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  hwi_set_upstream
  : > "$HWI_WORK/fail-workspace-rename"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Preserve upstream workspace'
  assert_success
  local state="$(hwi_identity_state_path)"
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$HWI_BRANCH"
  assert_equal "$(read_state_field "$state" outcome)" workspace-failed
  rm "$HWI_WORK/fail-workspace-rename"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Later event retries upstream workspace'
  assert_success
  assert_equal "$(read_state_field "$state" outcome)" workspace-only
  assert_equal "$(cat "$HWI_WORK/workspace.label")" preserve-upstream-workspace

  git -C "$HWI_CHECKOUT" config --unset "branch.$HWI_BRANCH.remote"
  git -C "$HWI_CHECKOUT" config --unset "branch.$HWI_BRANCH.merge"
  rm "$state"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Keep agent reverted branch'
  assert_success
  local renamed="$(git -C "$HWI_CHECKOUT" branch --show-current)"
  git -C "$HWI_CHECKOUT" branch -m "$HWI_BRANCH"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Do not restore agent branch'
  assert_success
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$HWI_BRANCH"
  assert_equal "$(read_state_field "$state" outcome)" workspace-only
  assert_equal "$(git -C "$HWI_CHECKOUT" reflog --format='%gs' "$HWI_BRANCH" | grep -c '^Branch: renamed ')" 2
  assert_equal "$(hwi_workspace_rename_count)" 3
  assert_file_not_contains "$HWI_WORK/herdr.calls" 'pane rename '
  assert_file_not_contains "$HWI_WORK/herdr.calls" 'tab rename '
  assert_file_not_contains "$HWI_WORK/herdr.calls" 'agent rename '
  [ -n "$renamed" ] || fail 'control rename did not occur'
}

function test_scripts_1190_worktree_identity_revalidates_marker_before_ref_mutation() {
  _bats_test_init 1190 'worktree identity requires its marker immediately before ref mutation'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  local ready="$HWI_WORK/revalidate.ready" release="$HWI_WORK/revalidate.release" marker state
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  state="$(hwi_identity_state_path)"
  env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_TEST_REVALIDATE_READY="$ready" \
    HERDR_WORKTREE_IDENTITY_TEST_REVALIDATE_RELEASE="$release" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 \
    <<< 'Require live marker' &
  local worker_pid=$! attempt=0
  while [[ ! -e "$ready" && "$attempt" -lt 3000 ]]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$ready"
  rm "$marker"
  : > "$release"
  wait "$worker_pid"
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$HWI_BRANCH"
  assert_file_contains "${state%.state}.diagnostics.log" '^reason=marker-missing-before-rename '
}

function test_scripts_1191_worktree_identity_recovers_a_prepared_rename() {
  _bats_test_init 1191 'worktree identity recovers a prepared rename before completing the workspace'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  local common state
  common="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-common-dir)"
  state="$(hwi_identity_state_path)"
  write_identity_state "$state" checkout_root "$HWI_CHECKOUT" repository_anchor "$common" \
    workspace workspace-1 original_branch "$HWI_BRANCH" branch recover-prepared-rename \
    outcome prepared authorization authorized title 'Recover prepared rename' slug recover-prepared-rename

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Later event'
  assert_success
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" recover-prepared-rename
  assert_equal "$(read_state_field "$state" outcome)" complete
  assert_equal "$(hwi_workspace_rename_count)" 1
}

function test_scripts_1192_worktree_identity_serializes_workspace_label_retries() {
  _bats_test_init 1192 'worktree identity issues one workspace retry when concurrent workers observe workspace-failed'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  : > "$HWI_WORK/fail-workspace-rename"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Serialize workspace retry'
  assert_success
  local state="$(hwi_identity_state_path)" ready="$HWI_WORK/lifecycle.ready" release="$HWI_WORK/lifecycle.release"
  local attempt_ready="$HWI_WORK/lifecycle-attempt.ready"
  assert_equal "$(read_state_field "$state" outcome)" workspace-failed
  rm "$HWI_WORK/fail-workspace-rename"

  env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_TEST_LIFECYCLE_READY="$ready" \
    HERDR_WORKTREE_IDENTITY_TEST_LIFECYCLE_RELEASE="$release" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Later event' &
  local first_pid=$! attempt=0
  while [[ ! -e "$ready" && "$attempt" -lt 500 ]]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$ready"
  env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_TEST_LIFECYCLE_ATTEMPT_READY="$attempt_ready" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Another event' &
  local second_pid=$! attempt=0
  while [[ ! -e "$attempt_ready" && "$attempt" -lt 3000 ]]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$attempt_ready"
  : > "$release"
  wait "$first_pid"
  wait "$second_pid"
  assert_equal "$(read_state_field "$state" outcome)" complete
  assert_equal "$(hwi_workspace_rename_count)" 2
}

function test_scripts_1193_worktree_identity_labels_after_revert_from_attribution_failure() {
  _bats_test_init 1193 'worktree identity labels workspace-only after an agent reverts an attribution failure'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  hwi_write_git_proxy
  : > "$HWI_WORK/fail-git-description"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Revert failed attribution'
  assert_success
  local state="$(hwi_identity_state_path)"
  assert_equal "$(read_state_field "$state" outcome)" attribution-failed
  git -C "$HWI_CHECKOUT" branch -m "$HWI_BRANCH"
  rm "$HWI_WORK/fail-git-description"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Later event'
  assert_success
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$HWI_BRANCH"
  assert_equal "$(read_state_field "$state" outcome)" workspace-only
  assert_equal "$(hwi_workspace_rename_count)" 1
}

function test_scripts_1194_worktree_identity_bounds_herdr_pane_reads() {
  _bats_test_init 1194 'worktree identity turns a blocked Herdr pane read into retryable unresolved state'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  : > "$HWI_WORK/block-pane-get"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_HERDR_TIMEOUT=1 \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Bound pane read'
  assert_success
  assert_file_exists "$HWI_WORK/pane-get.ready"
  local state="$HWI_STATE/sessions/$(encode_key session-1).state"
  assert_equal "$(read_state_field "$state" outcome)" unresolved
  assert_file_contains "${state%.state}.diagnostics.log" '^reason=pane-unreachable '
}

function test_scripts_1195_worktree_identity_rejects_marker_owner_changes_before_ref_mutation() {
  _bats_test_init 1195 'worktree identity rejects a changed marker immediately before ref mutation'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  local ready="$HWI_WORK/revalidate.ready" release="$HWI_WORK/revalidate.release" marker state
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  state="$(hwi_identity_state_path)"
  env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_TEST_REVALIDATE_READY="$ready" \
    HERDR_WORKTREE_IDENTITY_TEST_REVALIDATE_RELEASE="$release" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 \
    <<< 'Require matching marker' &
  local worker_pid=$! attempt=0
  while [[ ! -e "$ready" && "$attempt" -lt 3000 ]]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$ready"
  printf '%s\n' another-owner > "$marker"
  : > "$release"
  wait "$worker_pid"
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$HWI_BRANCH"
  assert_equal "$(hwi_workspace_rename_count)" 0
  assert_file_contains "${state%.state}.diagnostics.log" '^reason=marker-mismatched-before-rename '
}

function test_scripts_1196_worktree_identity_recovers_prepared_attribution_after_ref_mutation() {
  _bats_test_init 1196 'worktree identity completes attribution when prepared HEAD already moved'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  local common state marker branch=recover-prepared-attribution
  common="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-common-dir)"
  state="$(hwi_identity_state_path)"
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  write_identity_state "$state" checkout_root "$HWI_CHECKOUT" repository_anchor "$common" \
    workspace workspace-1 original_branch "$HWI_BRANCH" branch "$branch" outcome prepared \
    authorization authorized title 'Recover prepared attribution' slug recover-prepared-attribution
  git -C "$HWI_CHECKOUT" branch -m "$branch"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Later event'
  assert_success
  assert_equal "$(read_state_field "$state" outcome)" complete
  assert_file_contains "$marker" "^Intentional rename by herdr-worktree-identity: $HWI_BRANCH -> $branch$"
  assert_equal "$(hwi_branch_description "$branch")" "Intentional rename by herdr-worktree-identity: $HWI_BRANCH -> $branch"
  assert_equal "$(hwi_workspace_rename_count)" 1
}

function test_scripts_1197_worktree_identity_does_not_repeat_a_rename_after_workspace_failure() {
  _bats_test_init 1197 'worktree identity preserves an agent revert after workspace failure'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  : > "$HWI_WORK/fail-workspace-rename"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Preserve workspace failure revert'
  assert_success
  local state="$(hwi_identity_state_path)"
  assert_equal "$(read_state_field "$state" outcome)" workspace-failed
  git -C "$HWI_CHECKOUT" branch -m "$HWI_BRANCH"
  rm "$HWI_WORK/fail-workspace-rename"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Later event'
  assert_success
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$HWI_BRANCH"
  assert_equal "$(read_state_field "$state" outcome)" workspace-only
  assert_equal "$(hwi_workspace_rename_count)" 2
}

function test_scripts_1198_worktree_identity_treats_a_prepared_revert_as_agent_owned() {
  _bats_test_init 1198 'worktree identity does not repeat a prepared rename after an agent revert'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  local common state candidate=prepared-agent-revert
  common="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-common-dir)"
  state="$(hwi_identity_state_path)"
  write_identity_state "$state" checkout_root "$HWI_CHECKOUT" repository_anchor "$common" \
    workspace workspace-1 original_branch "$HWI_BRANCH" branch "$candidate" outcome prepared \
    authorization authorized title 'Prepared agent revert' slug prepared-agent-revert
  git -C "$HWI_CHECKOUT" branch -m "$candidate"
  git -C "$HWI_CHECKOUT" branch -m "$HWI_BRANCH"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Later event'
  assert_success
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$HWI_BRANCH"
  assert_equal "$(git -C "$HWI_CHECKOUT" reflog --format='%gs' "$HWI_BRANCH" | grep -c '^Branch: renamed ')" 2
  assert_equal "$(read_state_field "$state" outcome)" workspace-only
  assert_equal "$(hwi_workspace_rename_count)" 1
}

function test_scripts_1199_worktree_identity_treats_a_prepared_branch_move_as_agent_owned() {
  _bats_test_init 1199 'worktree identity labels after an agent moves a prepared candidate elsewhere'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  local common state candidate=prepared-candidate-move
  common="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-common-dir)"
  state="$(hwi_identity_state_path)"
  write_identity_state "$state" checkout_root "$HWI_CHECKOUT" repository_anchor "$common" \
    workspace workspace-1 original_branch "$HWI_BRANCH" branch "$candidate" outcome prepared \
    authorization authorized title 'Prepared candidate move' slug prepared-candidate-move
  git -C "$HWI_CHECKOUT" branch -m "$candidate"
  git -C "$HWI_CHECKOUT" branch -m agent-owned-after-prepare

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Later event'
  assert_success
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" agent-owned-after-prepare
  assert_equal "$(read_state_field "$state" outcome)" workspace-only
  assert_equal "$(hwi_workspace_rename_count)" 1
}

function test_scripts_1200_worktree_identity_revalidates_after_prepared_state_persistence() {
  _bats_test_init 1200 'worktree identity revalidates marker ownership after persisting prepared state'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  local ready="$HWI_WORK/prepared.ready" release="$HWI_WORK/prepared.release" marker state
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  state="$(hwi_identity_state_path)"
  env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_TEST_PREPARED_READY="$ready" \
    HERDR_WORKTREE_IDENTITY_TEST_PREPARED_RELEASE="$release" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Revalidate after prepare' &
  local worker_pid=$! attempt=0
  while [[ ! -e "$ready" && "$attempt" -lt 3000 ]]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$ready"
  rm "$marker"
  : > "$release"
  wait "$worker_pid"
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$HWI_BRANCH"
  assert_equal "$(hwi_workspace_rename_count)" 0
  assert_file_contains "${state%.state}.diagnostics.log" '^reason=marker-missing-at-commit '
}

function test_scripts_1201_worktree_identity_reconciles_a_persist_failed_workspace_rename() {
  _bats_test_init 1201 'worktree identity reconciles workspace success without repeating the external rename'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  hwi_write_mv_proxy
  : > "$HWI_WORK/fail-terminal-state-write"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Reconcile workspace persistence'
  assert_success
  local state="$(hwi_identity_state_path)"
  assert_equal "$(read_state_field "$state" outcome)" workspace-prepared
  assert_equal "$(hwi_workspace_rename_count)" 1
  rm "$HWI_WORK/fail-terminal-state-write"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Later event'
  assert_success
  assert_equal "$(read_state_field "$state" outcome)" complete
  assert_equal "$(hwi_workspace_rename_count)" 1
}

function test_scripts_1305_worktree_state_named_writes_preserve_unspecified_fields() {
  _bats_test_init 1305 'worktree state named writes preserve unspecified fields atomically'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  local state="$HWI_WORK/named.state" title='A title with = and enough bytes to exercise wrapped base64 encoding 0123456789 0123456789'

  run write_identity_state "$state" \
    checkout_root /checkout repository_anchor /repository workspace workspace-1 \
    original_branch worktree/original branch proposed-branch outcome prepared \
    authorization authorized title "$title" slug proposed-branch
  assert_success
  run write_identity_state "$state" outcome complete
  assert_success
  assert_equal "$(read_state_field "$state" checkout_root)" /checkout
  assert_equal "$(read_state_field "$state" repository_anchor)" /repository
  assert_equal "$(read_state_field "$state" workspace)" workspace-1
  assert_equal "$(read_state_field "$state" original_branch)" worktree/original
  assert_equal "$(read_state_field "$state" branch)" proposed-branch
  assert_equal "$(read_state_field "$state" authorization)" authorized
  assert_equal "$(read_state_field "$state" title)" "$title"
  assert_equal "$(read_state_field "$state" slug)" proposed-branch
  assert_equal "$(read_state_field "$state" outcome)" complete

  cp "$state" "$HWI_WORK/before-unknown.state"
  run write_identity_state "$state" outcome declined invented_field value
  assert_failure 1
  run cmp -s "$state" "$HWI_WORK/before-unknown.state"
  assert_success
  run write_identity_state "$state" outcome declined title
  assert_failure 1
  run cmp -s "$state" "$HWI_WORK/before-unknown.state"
  assert_success
  run write_identity_state "$state" outcome impossible
  assert_failure 1
  run cmp -s "$state" "$HWI_WORK/before-unknown.state"
  assert_success
  local diagnostics
  diagnostics="$(diagnostic_file_for_state "$state")"
  assert_file_contains "$diagnostics" 'reason=invalid-record-field '
  assert_file_contains "$diagnostics" 'reason=invalid-record-update '
  assert_file_contains "$diagnostics" 'reason=illegal-outcome '

  hwi_write_mv_proxy
  : > "$HWI_WORK/fail-terminal-state-write"
  : > "$HWI_WORK/workspace.label"
  cp "$state" "$HWI_WORK/before-mv-failure.state"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash -c 'source "$1"; write_identity_state "$2" outcome declined' _ "$HWI_STATE_LIBRARY" "$state"
  assert_failure 1
  run cmp -s "$state" "$HWI_WORK/before-mv-failure.state"
  assert_success
  run bash -c 'compgen -G "$1/.record.*" >/dev/null' _ "${state%/*}"
  assert_failure 1
}

function test_scripts_1306_worktree_state_rewrites_the_legacy_outcome_canonically() {
  _bats_test_init 1306 'worktree state accepts a legacy outcome and rewrites it canonically'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  local state="$HWI_WORK/legacy.state"
  atomic_write "$state" "checkout_root=$(encode_value /checkout)
repository_anchor=$(encode_value /repository)
workspace=$(encode_value workspace-1)
original_branch=$(encode_value worktree/original)
branch=$(encode_value renamed-branch)
outcome=$(encode_value attribution_failed)
authorization=$(encode_value authorized)
title=$(encode_value 'Legacy title')
slug=$(encode_value legacy-title)"

  assert_equal "$(read_state_field "$state" outcome)" attribution_failed
  run write_identity_state "$state" title 'Updated title'
  assert_success
  assert_equal "$(read_state_field "$state" outcome)" attribution-failed
  assert_equal "$(read_state_field "$state" branch)" renamed-branch
  assert_equal "$(read_state_field "$state" title)" 'Updated title'

  local illegal="$HWI_WORK/illegal.state"
  atomic_write "$illegal" "outcome=$(encode_value impossible)"
  cp "$illegal" "$HWI_WORK/before-illegal.state"
  run write_identity_state "$illegal" title 'Rejected update'
  assert_failure 1
  run cmp -s "$illegal" "$HWI_WORK/before-illegal.state"
  assert_success
  assert_file_contains "$(diagnostic_file_for_state "$illegal")" 'reason=illegal-outcome '
}

function test_scripts_1202_worktree_identity_rejects_marker_owner_changes_at_commit() {
  _bats_test_init 1202 'worktree identity rejects changed marker ownership after persisting prepared state'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  local ready="$HWI_WORK/prepared.ready" release="$HWI_WORK/prepared.release" marker state
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  state="$(hwi_identity_state_path)"
  env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_TEST_PREPARED_READY="$ready" \
    HERDR_WORKTREE_IDENTITY_TEST_PREPARED_RELEASE="$release" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Revalidate changed owner at commit' &
  local worker_pid=$! attempt=0
  while [[ ! -e "$ready" && "$attempt" -lt 3000 ]]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$ready"
  printf '%s\n' another-owner > "$marker"
  : > "$release"
  wait "$worker_pid"
  assert_equal "$(git -C "$HWI_CHECKOUT" branch --show-current)" "$HWI_BRANCH"
  assert_equal "$(hwi_workspace_rename_count)" 0
  assert_file_contains "${state%.state}.diagnostics.log" '^reason=marker-mismatched-at-commit '
}

function test_scripts_1203_worktree_identity_retries_a_nonmatching_prepared_workspace() {
  _bats_test_init 1203 'worktree identity retries one workspace rename when reconciliation finds another label'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  hwi_write_mv_proxy
  : > "$HWI_WORK/fail-terminal-state-write"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Retry nonmatching workspace'
  assert_success
  local state="$(hwi_identity_state_path)"
  assert_equal "$(read_state_field "$state" outcome)" workspace-prepared
  printf '%s' manual-label > "$HWI_WORK/workspace.label"
  rm "$HWI_WORK/fail-terminal-state-write"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Later event'
  assert_success
  assert_equal "$(read_state_field "$state" outcome)" complete
  assert_equal "$(cat "$HWI_WORK/workspace.label")" retry-nonmatching-workspace
  assert_equal "$(hwi_workspace_rename_count)" 2
}

function test_scripts_1204_worktree_identity_reconciles_an_ambiguous_workspace_timeout() {
  _bats_test_init 1204 'worktree identity reconciles a workspace rename committed before timeout'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  : > "$HWI_WORK/commit-then-block-workspace-rename"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_HERDR_TIMEOUT=1 \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Reconcile timeout commit'
  assert_success
  assert_file_exists "$HWI_WORK/workspace-rename.ready"
  local state="$(hwi_identity_state_path)"
  assert_equal "$(read_state_field "$state" outcome)" complete
  assert_equal "$(hwi_workspace_rename_count)" 1
  rm "$HWI_WORK/commit-then-block-workspace-rename"

  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Later event'
  assert_success
  assert_equal "$(read_state_field "$state" outcome)" complete
  assert_equal "$(hwi_workspace_rename_count)" 1
}

function test_scripts_1205_worktree_identity_timeout_kills_term_ignoring_descendants() {
  _bats_test_init 1205 'worktree identity timeout kills a Herdr process group with a TERM-ignoring descendant'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  : > "$HWI_WORK/block-pane-get-with-descendant"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_HERDR_TIMEOUT=1 \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Kill blocked descendants'
  assert_success
  assert_file_exists "$HWI_WORK/pane-child.pid"
  local child_pid="$(cat "$HWI_WORK/pane-child.pid")" attempt=0
  while kill -0 "$child_pid" 2>/dev/null && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  run kill -0 "$child_pid"
  assert_failure
  local state="$HWI_STATE/sessions/$(encode_key session-1).state"
  assert_equal "$(read_state_field "$state" outcome)" unresolved
}

function test_scripts_1188_worktree_identity_declines_marker_and_retries_contention_and_workspace_failure() {
  _bats_test_init 1188 'worktree identity keeps terminal declines distinct from retryable contention and workspace failures'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  local state="$(hwi_identity_state_path)" marker
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  rm "$marker"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Missing marker never labels'
  assert_success
  assert_equal "$(read_state_field "$state" outcome)" declined
  assert_equal "$(hwi_workspace_rename_count)" 0

  rm "$state"
  marker="$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-path herdr-generated-worktree)"
  printf '%s\n' "$HWI_BRANCH" > "$marker"
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  state="$(hwi_identity_state_path)"
  local lock="$(namespace_dir "$(git -C "$HWI_CHECKOUT" rev-parse --path-format=absolute --git-common-dir)")/branch-rename.claim"
  hwi_start_claim_holder "$lock" || fail 'claim holder was not ready'
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_BRANCH_CLAIM_ATTEMPTS=1 \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Retry contention label'
  assert_success
  assert_equal "$(read_state_field "$state" outcome)" ''
  assert_file_contains "${state%.state}.diagnostics.log" '^reason=contended '
  : > "$HWI_HOLDER_RELEASE"
  wait "$HWI_HOLDER_PID"
  HWI_HOLDER_PID=''
  : > "$HWI_WORK/fail-workspace-rename"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Retry contention label'
  assert_success
  assert_equal "$(read_state_field "$state" outcome)" workspace-failed
  rm "$HWI_WORK/fail-workspace-rename"
  run env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Later naming event retries label'
  assert_success
  assert_equal "$(read_state_field "$state" outcome)" complete
  assert_equal "$(hwi_workspace_rename_count)" 2
}

function test_scripts_1189_worktree_identity_revalidates_occupant_before_workspace_rename() {
  _bats_test_init 1189 'worktree identity does not relabel a workspace after its pane changes occupants'
  hwi_setup
  source "$HWI_STATE_LIBRARY"
  hwi_create_generated_worktree
  hwi_write_pane pane-1 codex session-1 workspace-1 "$HWI_CHECKOUT"
  local ready="$HWI_WORK/workspace-revalidate.ready" release="$HWI_WORK/workspace-revalidate.release"
  env PATH="$HWI_STUB:$HWI_COMMAND_PATH" HERDR_WORKTREE_IDENTITY_STATE_DIR="$HWI_STATE" \
    HERDR_WORKTREE_IDENTITY_TEST_WORKSPACE_REVALIDATE_READY="$ready" \
    HERDR_WORKTREE_IDENTITY_TEST_WORKSPACE_REVALIDATE_RELEASE="$release" \
    bash "$HWI_ENGINE" --worker --agent codex --session session-1 --pane pane-1 --workspace workspace-1 <<< 'Revalidate workspace occupant' &
  local worker_pid=$! attempt=0
  while [[ ! -e "$ready" && "$attempt" -lt 3000 ]]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$ready"
  hwi_write_pane pane-1 claude other-session workspace-1 "$HWI_CHECKOUT"
  : > "$release"
  wait "$worker_pid"
  local state="$(hwi_identity_state_path)"
  assert_equal "$(read_state_field "$state" outcome)" workspace-failed
  assert_equal "$(hwi_workspace_rename_count)" 0
  assert_file_contains "${state%.state}.diagnostics.log" '^reason=workspace-occupant-changed '
}

# ===========================================
# python3 -- the declared interpreter
# ===========================================

# First, so a missing or too-old interpreter states its own cause instead of
# leaving the bare `python3` call sites below to fail without naming it.
function test_scripts_001_python3_is_present_and_at_least_3_9_the_floor_re() {
  _bats_test_init 1 'python3 is present and at least 3.9, the floor README.md declares'
  run assert_python3_available
  assert_success
}

# ===========================================
# Repository linting
# ===========================================

# Writes a shellcheck stub that appends its argv to $2 and exits with $3, so a
# test can tell "make lint failed because shellcheck failed" apart from "make
# lint failed for some other reason".
write_shellcheck_stub() {
  local dir="$1" log="$2" code="$3"
  cat > "$dir/shellcheck" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$log"
exit $code
STUB
  chmod +x "$dir/shellcheck"
}

function test_scripts_002_lint_target_propagates_shellcheck_failures() {
  _bats_test_init 2 'lint target propagates shellcheck failures'
  local repo_root="$BATS_TEST_DIRNAME/.."
  [[ -f "$repo_root/Makefile" ]] || skip "repo-root Makefile is not available in this environment"

  # `make lint` runs three shellcheck sweeps plus a python checker, so a bare
  # assert_failure is also satisfied by a broken Makefile or a failing python
  # step -- neither of which is this test's subject. The stub records that it
  # was reached, and the exit-0 leg is the control proving the target reaches
  # success when shellcheck is happy, so a `|| true` on the shellcheck lines
  # cannot keep both legs green.
  local stubdir="$BATS_TEST_TMPDIR/lint-stub"
  local invocations="$BATS_TEST_TMPDIR/shellcheck.invocations"
  mkdir -p "$stubdir"

  write_shellcheck_stub "$stubdir" "$invocations" 1
  run env PATH="$stubdir:$PATH" make -C "$repo_root" lint
  assert_failure
  assert_file_exists "$invocations"

  write_shellcheck_stub "$stubdir" "$invocations" 0
  run env PATH="$stubdir:$PATH" make -C "$repo_root" lint
  assert_success
}

function test_scripts_9_lint_input_set_excludes_agent_worktrees() {
  _bats_test_init 9 'lint input set excludes agent worktrees but keeps repository source'
  local repo_root="$BATS_TEST_DIRNAME/.."
  [[ -f "$repo_root/Makefile" ]] || skip "repo-root Makefile is not available in this environment"

  # Agent worktrees are checkouts of this repository living under
  # .claude/worktrees, so their .sh files look exactly like repository source to
  # find(1). Linting them makes the target's verdict depend on whichever
  # worktree happens to be left over rather than on the tree being linted. The
  # probe stays shellcheck-clean on purpose: this asserts on the input set, and
  # a leaked probe must not be able to fail a later real lint run.
  local stubdir="$BATS_TEST_TMPDIR/lint-scope-stub"
  local invocations="$BATS_TEST_TMPDIR/shellcheck.scope-invocations"
  local probe_dir="$repo_root/.claude/worktrees/lint-scope-probe-$$"
  mkdir -p "$stubdir" "$probe_dir"
  printf '#!/bin/bash\nprintf %%s "linted"\n' > "$probe_dir/probe.sh"

  write_shellcheck_stub "$stubdir" "$invocations" 0
  run env PATH="$stubdir:$PATH" make -C "$repo_root" lint
  local lint_status="$status"
  rm -f "$probe_dir/probe.sh"
  rmdir "$probe_dir" 2>/dev/null || true

  # #then
  assert_equal 0 "$lint_status"
  assert_file_exists "$invocations"
  run grep -q "lint-scope-probe-$$" "$invocations"
  assert_failure
  # Control: the same sweep still reaches ordinary repository source, so the
  # exclusion above cannot be satisfied by linting nothing at all.
  assert_file_contains "$invocations" 'home/dot_local/lib/herdr-process\.sh'
}

# ===========================================
# install-packages script
# ===========================================

# --source is load-bearing here, not decoration. This script's `include`
# directives resolve against the chezmoi source directory, so without it the
# script is read from the checkout under test while its includes are read from
# whatever tree the host's chezmoi config points at. Those are the same
# directory in CI and in Docker, which is why this passed for so long; they are
# different in a git worktree, and the mismatch surfaced the moment the
# Brewfiles were renamed in one tree and not the other.
render_install_packages() {
  local config_args=()
  if [[ -n "${1:-}" ]]; then
    config_args=(--config "$1")
  fi
  chezmoi_full_fixture_finite_stdin "${config_args[@]}" \
    --source "$SOURCE_ROOT" execute-template \
    < "$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl"
}

function test_scripts_003_ci_minimal_linux_render_skips_homebrew_but_keeps() {
  _bats_test_init 3 'CI-minimal Linux render skips Homebrew but keeps the remaining setup'
  skip_if_no_chezmoi
  local cfg="$BATS_TEST_TMPDIR/minimal-linux.yaml"
  MMS_CI_MINIMAL=1 write_test_config "$cfg"
  sed -i.bak 's/^  is_linux: .*/  is_linux: true/' "$cfg"

  run render_install_packages "$cfg"
  assert_success
  # Progress banners ("Installing Oh My Zsh...") are prose nothing consumes: a
  # reworded echo reddens the test while the install still runs, and deleting
  # the install while keeping the echo stays green. The upstream installer URL
  # below is a third-party constant this repo does not define, so it moves
  # only when the install itself moves.
  refute_output --partial 'Homebrew/install/HEAD/install.sh'
  refute_output --partial 'brew bundle --file='
  # Oh My Zsh and fff-mcp are pinned chezmoi externals now
  # (.chezmoiexternal.toml), not installed by this script; the retained
  # cleanup block is the positive control proving the plugin-cleanup section
  # of the script still renders.
  assert_output --partial 'rm -rf "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"'
}

function test_scripts_004_full_linux_render_keeps_homebrew_package_install() {
  _bats_test_init 4 'full Linux render keeps Homebrew package installation'
  skip_if_no_chezmoi
  local cfg="$BATS_TEST_TMPDIR/full-linux.yaml"
  MMS_CI_MINIMAL="" write_test_config "$cfg"
  sed -i.bak 's/^  is_linux: .*/  is_linux: true/' "$cfg"

  run render_install_packages "$cfg"
  assert_success
  assert_output --partial 'Homebrew/install/HEAD/install.sh'
  assert_output --partial 'HOMEBREW_BUNDLE_NO_UPGRADE=1 brew bundle --file="$BREWFILES_DIR/Brewfile"'
}

function test_scripts_005_ci_minimal_non_linux_render_keeps_homebrew_packa() {
  _bats_test_init 5 'CI-minimal non-Linux render keeps Homebrew package installation'
  skip_if_no_chezmoi
  local cfg="$BATS_TEST_TMPDIR/minimal-non-linux.yaml"
  MMS_CI_MINIMAL=1 write_test_config "$cfg"
  sed -i.bak 's/^  is_linux: .*/  is_linux: false/' "$cfg"

  run render_install_packages "$cfg"
  assert_success
  assert_output --partial 'Homebrew/install/HEAD/install.sh'
  assert_output --partial 'HOMEBREW_BUNDLE_NO_UPGRADE=1 brew bundle --file="$BREWFILES_DIR/Brewfile"'
}

function test_scripts_006_install_packages_script_renders_as_valid_bash() {
  _bats_test_init 6 'install-packages script renders as valid bash'
  skip_if_no_chezmoi
  BATS_TEST_TMPFILE="$BATS_TEST_TMPDIR/install-packages.sh"
  render_install_packages > "$BATS_TEST_TMPFILE"
  run bash -n "$BATS_TEST_TMPFILE"
  assert_success
}

# ===========================================
# macOS tunes script
# ===========================================

function test_scripts_007_macos_tunes_script_is_valid_bash() {
  _bats_test_init 7 'macos-tunes script is valid bash'
  local script="$SOURCE_ROOT/.chezmoiscripts/darwin/run_once_after_macos-tunes.sh"
  run bash -n "$script"
  assert_success
}

function test_scripts_008_darwin_scripts_excluded_from_managed_list_on_lin() {
  _bats_test_init 8 'darwin scripts excluded from managed list on Linux'
  is_linux || skip "Only relevant on Linux"
  skip_if_no_chezmoi
  run chezmoi_host_partial managed
  # A failed `chezmoi managed` emits an error string that would satisfy the
  # refutation, so status and a known-managed line come first.
  assert_success
  assert_output --partial ".gitconfig"
  refute_output --partial "run_once_after_macos-tunes"
}

function test_scripts_0081_retired_se_cleanup_migration_preserves_an_independent_skill() {
  _bats_test_init 81 'retired se-cleanup migration preserves an independently owned skill'
  local script="$SOURCE_ROOT/.chezmoiscripts/run_once_after_remove-retired-se-cleanup.sh"
  local agents="$BATS_TEST_TMPDIR/home/.agents/skills/se-cleanup"
  local claude="$BATS_TEST_TMPDIR/home/.claude/skills/se-cleanup"
  local orphan_home="$BATS_TEST_TMPDIR/orphan-home"
  mkdir -p "$agents" "$claude"
  printf '%s\n' 'independently managed skill' > "$agents/SKILL.md"
  printf '%s\n' 'user-owned content' > "$agents/notes.md"
  ln -s "$agents/SKILL.md" "$claude/SKILL.md"

  run env HOME="$BATS_TEST_TMPDIR/home" sh "$script"
  assert_success
  assert_file_contains "$agents/SKILL.md" '^independently managed skill$'
  assert_file_exists "$agents/notes.md"
  assert_dir_exists "$agents"
  assert_file_exists "$claude/SKILL.md"

  mkdir -p "$orphan_home/.claude/skills/se-cleanup"
  ln -s ../../../.agents/skills/se-cleanup/SKILL.md \
    "$orphan_home/.claude/skills/se-cleanup/SKILL.md"
  run env HOME="$orphan_home" sh "$script"
  assert_success
  assert_dir_not_exists "$orphan_home/.claude/skills/se-cleanup"
}

function test_scripts_0084_retired_worktrunk_migration_removes_only_managed_files() {
  _bats_test_init 84 'retired Worktrunk migration removes only formerly managed files'
  local script="$SOURCE_ROOT/.chezmoiscripts/run_once_after_remove-retired-worktrunk.sh"
  local home="$BATS_TEST_TMPDIR/worktrunk-home"
  mkdir -p \
    "$home/.config/worktrunk" \
    "$home/.config/herdr/plugins/config/worktrunk" \
    "$home/.config/herdr/plugins/command-palette"
  printf '%s\n' old > "$home/.config/worktrunk/config.toml"
  printf '%s\n' old > "$home/.config/herdr/plugins/config/worktrunk/config.toml"
  printf '%s\n' old > "$home/.config/herdr/plugins/command-palette/new_worktree.py"
  printf '%s\n' old > "$home/.config/herdr/plugins/command-palette/open_new_worktree.py"
  printf '%s\n' keep > "$home/.config/worktrunk/user-note"

  run env HOME="$home" sh "$script"
  assert_success
  assert_file_not_exists "$home/.config/worktrunk/config.toml"
  assert_file_not_exists "$home/.config/herdr/plugins/config/worktrunk/config.toml"
  assert_file_not_exists "$home/.config/herdr/plugins/command-palette/new_worktree.py"
  assert_file_not_exists "$home/.config/herdr/plugins/command-palette/open_new_worktree.py"
  assert_file_exists "$home/.config/worktrunk/user-note"
}

function test_scripts_0851_obsolete_plugin_removal_accepts_formatted_plugin_json() {
  _bats_test_init 851 'obsolete plugin removal accepts formatted plugin JSON'
  local template="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_7-install-herdr-github-plugins.sh.tmpl"
  local script="$BATS_TEST_TMPDIR/install-herdr-github-plugins.sh"
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  local calls="$BATS_TEST_TMPDIR/herdr.calls"
  local home="$BATS_TEST_TMPDIR/github-plugin-home"
  local wakeup_config="$home/.config/herdr/plugins/config/herdr-wakeup"
  mkdir -p "$fake_bin" "$wakeup_config"
  printf '%s\n' '{"stop_grace_seconds":1200}' > "$wakeup_config/config.json"
  chezmoi_full_fixture execute-template -S "$SOURCE_ROOT" --file "$template" > "$script"

  cat > "$fake_bin/uname" <<'SH'
#!/bin/sh
printf 'Darwin\n'
SH
  cat > "$fake_bin/herdr" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HERDR_CALLS"
if [ "$*" = "plugin list --json" ]; then
  cat <<'JSON'
{
  "result": {
    "plugins": [
      { "plugin_id": "artisann.zed-herdr" },
      { "plugin_id": "worktrunk" },
      { "plugin_id": "herdr-wakeup", "source": { "kind": "github" } },
      { "plugin_id": "seigi.command-palette", "source": { "kind": "local" } }
    ]
  }
}
JSON
elif [ "$*" = "plugin config-dir herdr-wakeup" ]; then
  printf '%s\n' "$HOME/.config/herdr/plugins/config/herdr-wakeup"
fi
exit 0
SH
  chmod +x "$fake_bin/uname" "$fake_bin/herdr"

  run env HOME="$home" HERDR_CALLS="$calls" \
    HERDR_SOCKET_PATH=/tmp/mms-herdr-wakeup-test.sock PATH="$fake_bin:$PATH" bash "$script"
  assert_success
  run grep -Fx "plugin uninstall artisann.zed-herdr" "$calls"
  assert_success
  run grep -Fx "plugin uninstall worktrunk" "$calls"
  assert_success
  run grep -Fx "plugin uninstall seigi.command-palette" "$calls"
  assert_failure
  run grep -Fx "plugin install dio16/herdr-auto-update -y" "$calls"
  assert_success
  run grep -Fx "plugin install Seigiard/herdr-command-palette --ref 9c92d2d0b0d275183880c9033e73657e513d3da1 -y" "$calls"
  assert_success
  run grep -Fx "plugin install Seigiard/herdr-pane-labels --ref aba61eb788c5fe0630dc570d96fd14683e2f63c7 -y" "$calls"
  assert_success
  run grep -Fx "plugin enable seigi.pane-labels" "$calls"
  assert_success
  run grep -Fx "plugin enable seigi.command-palette" "$calls"
  assert_success
  run grep -Fx "plugin install Seigiard/herdr-worktree-setup --ref 70048c616979719aa592df36f37ec076227b2ac8 -y" "$calls"
  assert_success
  run grep -Fx "plugin install Seigiard/herdr-pane-labels --ref aba61eb788c5fe0630dc570d96fd14683e2f63c7 -y" "$calls"
  assert_success
  run grep -Fx "plugin enable seigi.worktree-setup" "$calls"
  assert_success
  run grep -Fx "plugin install usrivastava92/herdr-wakeup/plugin --ref 43db0b9f88a4b1bc560593b0ce8f2a7d2a940f04 -y" "$calls"
  assert_success
  run grep -Fx "plugin action invoke stop --plugin herdr-wakeup" "$calls"
  assert_success
  run grep -Fx "plugin enable herdr-wakeup" "$calls"
  assert_success
  local session_config="$wakeup_config/sessions/f60c672338465554/config.json"
  run readlink "$session_config"
  assert_success
  assert_output "$wakeup_config/config.json"
}

function test_scripts_08511_github_command_palette_is_not_uninstalled_during_update() {
  _bats_test_init 8511 'GitHub command palette is updated in place, not treated as the local cutover'
  local template="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_7-install-herdr-github-plugins.sh.tmpl"
  local script="$BATS_TEST_TMPDIR/install-herdr-github-plugins-linux.sh"
  local fake_bin="$BATS_TEST_TMPDIR/bin-github-palette"
  local calls="$BATS_TEST_TMPDIR/herdr-github-palette.calls"
  mkdir -p "$fake_bin"
  chezmoi_full_fixture execute-template -S "$SOURCE_ROOT" --file "$template" > "$script"

  cat > "$fake_bin/uname" <<'SH'
#!/bin/sh
printf 'Linux\n'
SH
  cat > "$fake_bin/herdr" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HERDR_CALLS"
if [ "$*" = "plugin list --json" ]; then
  printf '%s\n' '{"result":{"plugins":[{"plugin_id":"seigi.command-palette","source":{"kind":"github","owner":"Seigiard","repo":"herdr-command-palette"}},{"plugin_id":"seigi.worktree-setup","source":{"kind":"github","owner":"Seigiard","repo":"herdr-worktree-setup"}}]}}'
fi
exit 0
SH
  chmod +x "$fake_bin/uname" "$fake_bin/herdr"

  run env HOME="$BATS_TEST_TMPDIR/github-palette-home" HERDR_CALLS="$calls" \
    PATH="$fake_bin:$PATH" bash "$script"
  assert_success
  run grep -Fx "plugin uninstall seigi.command-palette" "$calls"
  assert_failure
  run grep -Fx "plugin uninstall seigi.worktree-setup" "$calls"
  assert_failure
  run grep -Fx "plugin install Seigiard/herdr-command-palette --ref 9c92d2d0b0d275183880c9033e73657e513d3da1 -y" "$calls"
  assert_success
  run grep -Fx "plugin install Seigiard/herdr-worktree-setup --ref 70048c616979719aa592df36f37ec076227b2ac8 -y" "$calls"
  assert_success
  run grep -F "herdr-focus-notify" "$calls"
  assert_failure
  run grep -F "herdr-auto-update" "$calls"
  assert_failure
}

function test_scripts_08513_github_plugin_install_accepts_an_enabled_offline_registry() {
  _bats_test_init 8513 'GitHub plugin installation accepts an enabled local registry when Herdr is offline'
  local template="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_7-install-herdr-github-plugins.sh.tmpl"
  local script="$BATS_TEST_TMPDIR/install-herdr-offline.sh"
  local fake_bin="$BATS_TEST_TMPDIR/bin-herdr-offline"
  local calls="$BATS_TEST_TMPDIR/herdr-offline.calls"
  local home="$BATS_TEST_TMPDIR/herdr-offline-home"
  mkdir -p "$fake_bin" "$home"
  chezmoi_full_fixture execute-template -S "$SOURCE_ROOT" --file "$template" > "$script"

  cat > "$fake_bin/uname" <<'SH'
#!/bin/sh
printf 'Linux\n'
SH
  cat > "$fake_bin/herdr" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HERDR_CALLS"
if [ "$1" = plugin ] && [ "$2" = link ]; then
  : > "$HOME/local-plugin-restored"
fi
case "$*" in
  "plugin list --json")
    printf '%s\n' '{"result":{"plugins":[{"plugin_id":"seigi.command-palette","enabled":true,"source":{"kind":"github"}},{"plugin_id":"seigi.pane-labels","enabled":true,"source":{"kind":"github"}},{"plugin_id":"seigi.worktree-setup","enabled":true,"source":{"kind":"github"}}]}}'
    ;;
  "plugin enable "*)
    printf '%s\n' '{"id":"cli:plugin","error":{"code":"server_not_running","message":"offline"}}'
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$fake_bin/uname" "$fake_bin/herdr"

  run env HOME="$home" HERDR_CALLS="$calls" PATH="$fake_bin:$PATH" bash "$script"
  assert_success
  local result="$output"
  [[ "$result" == *'registered enabled for the next start'* ]] || fail 'offline registration was not accepted'
  [[ "$result" != *'Warning: failed to configure Herdr plugin'* ]] || fail 'offline registration was reported as failed'
}

function test_scripts_08514_github_plugin_install_rejects_an_disabled_offline_registry() {
  _bats_test_init 8514 'GitHub plugin installation rejects a disabled local registry when Herdr is offline'
  local template="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_7-install-herdr-github-plugins.sh.tmpl"
  local script="$BATS_TEST_TMPDIR/install-herdr-offline-disabled.sh"
  local fake_bin="$BATS_TEST_TMPDIR/bin-herdr-offline-disabled"
  local calls="$BATS_TEST_TMPDIR/herdr-offline-disabled.calls"
  local home="$BATS_TEST_TMPDIR/herdr-offline-disabled-home"
  mkdir -p "$fake_bin" "$home"
  chezmoi_full_fixture execute-template -S "$SOURCE_ROOT" --file "$template" > "$script"

  cat > "$fake_bin/uname" <<'SH'
#!/bin/sh
printf 'Linux\n'
SH
  cat > "$fake_bin/herdr" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HERDR_CALLS"
case "$*" in
  "plugin list --json")
    printf '%s\n' '{"result":{"plugins":[{"plugin_id":"seigi.command-palette","enabled":false,"source":{"kind":"github"}},{"plugin_id":"seigi.worktree-setup","enabled":false,"source":{"kind":"github"}}]}}'
    ;;
  "plugin enable "*)
    printf '%s\n' '{"id":"cli:plugin","error":{"code":"server_not_running","message":"offline"}}'
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$fake_bin/uname" "$fake_bin/herdr"

  run env HOME="$home" HERDR_CALLS="$calls" PATH="$fake_bin:$PATH" bash "$script"
  assert_success
  assert_output --partial 'Warning: failed to configure Herdr plugin'
}

worktree_migration_prepare() {
  local work="$1"
  local source="$work/source" home="$work/home" fake_bin="$work/bin"
  mkdir -p "$source/.chezmoiscripts" "$source/.chezmoitemplates" \
    "$home/.config/herdr/plugins/worktree-setup" "$fake_bin"
  cp "$SOURCE_ROOT/.chezmoiscripts/run_once_after_4-migrate-herdr-worktree-setup.sh.tmpl" \
    "$source/.chezmoiscripts/"
  cp "$SOURCE_ROOT/.chezmoitemplates/herdr-plugin-link-guard.sh" "$source/.chezmoitemplates/"
  printf 'legacy plugin\n' > "$home/.config/herdr/plugins/worktree-setup/setup.ts"
  write_test_config "$work/chezmoi.yaml"

  cat > "$fake_bin/herdr" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HERDR_CALLS"
case "$*" in
  --version)
    exit 0
    ;;
  "plugin list --json")
    if [ "${HERDR_FAIL_STEP:-}" = malformed ]; then
      printf '%s\n' '{"result":{"plugins":[null]}}'
    elif [ "${HERDR_FAIL_STEP:-}" = refresh ] && [ "$(grep -Fc "plugin list --json" "$HERDR_CALLS")" -gt 1 ]; then
      exit 1
    else
      printf '%s\n' '{"result":{"plugins":[{"plugin_id":"seigi.worktree-setup","source":{"kind":"local"}}]}}'
    fi
    ;;
  "plugin install Seigiard/herdr-worktree-setup --ref 70048c616979719aa592df36f37ec076227b2ac8 -y")
    [ "${HERDR_FAIL_STEP:-}" != install ]
    ;;
  "plugin uninstall seigi.worktree-setup")
    [ "${HERDR_FAIL_STEP:-}" != uninstall ]
    ;;
  "plugin enable seigi.worktree-setup")
    [ "${HERDR_FAIL_STEP:-}" != enable ]
    ;;
  "plugin link "*)
    [ "${HERDR_FAIL_STEP:-}" != link ]
    ;;
  *)
    exit 0
    ;;
esac
SH
  cat > "$fake_bin/getent" <<'SH'
#!/bin/sh
[ "${1:-}" = passwd ] || exit 1
printf 'test:x:1000:1000:Test User:%s:/bin/bash\n' "$HOME"
SH
  cat > "$fake_bin/dscl" <<'SH'
#!/bin/sh
printf 'NFSHomeDirectory: %s\n' "$HOME"
SH
  chmod +x "$fake_bin/herdr" "$fake_bin/getent" "$fake_bin/dscl"
}

worktree_migration_apply() {
  local work="$1" fail_step="${2:-}"
  HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" \
    PATH="$work/bin:$PATH" HERDR_CALLS="$work/herdr.calls" \
    HERDR_FAIL_STEP="$fail_step" chezmoi_full_fixture apply \
    --source "$work/source" --destination "$work/home" --config "$work/chezmoi.yaml"
}

worktree_migration_apply_custom_xdg() {
  local work="$1"
  HOME="$work/home" XDG_CONFIG_HOME="$work/home/custom-config" \
    PATH="$work/bin:$PATH" HERDR_CALLS="$work/herdr.calls" \
    HERDR_FAIL_STEP="" chezmoi_full_fixture apply \
    --source "$work/source" --destination "$work/home" --config "$work/chezmoi.yaml"
}

worktree_migration_live_apply() {
  local work="$1" fail_step="${2:-}"
  chezmoi_full_fixture execute-template -S "$work/source" \
    --file "$work/source/.chezmoiscripts/run_once_after_4-migrate-herdr-worktree-setup.sh.tmpl" \
    > "$work/migration.sh"
  env -u MMS_DISPOSABLE_HOME -u HERDR_SOCKET_PATH \
    HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" \
    PATH="$work/bin:$PATH" HERDR_CALLS="$work/herdr.calls" \
    HERDR_FAIL_STEP="$fail_step" bash "$work/migration.sh"
}

function test_scripts_0853_worktree_setup_migration_retries_after_install_failure() {
  _bats_test_init 853 'worktree setup migration retains local files and retries after install failure'
  command_exists chezmoi || skip "chezmoi not available"
  local work="$BATS_TEST_TMPDIR/worktree-migration"
  worktree_migration_prepare "$work"

  run worktree_migration_apply "$work" install
  assert_failure
  local migration_output="$output"
  assert_dir_exists "$work/home/.config/herdr/plugins/worktree-setup"
  run grep -Fx "plugin link $work/home/.config/herdr/plugins/worktree-setup --enabled" "$work/herdr.calls"
  assert_failure
  [[ "$migration_output" == *'MMS_DISPOSABLE_HOME=1'* ]] || fail 'rollback did not honor the disposable-home guard'

  run worktree_migration_apply "$work"
  assert_success
  assert_dir_not_exists "$work/home/.config/herdr/plugins/worktree-setup"
  run grep -Fc "plugin install Seigiard/herdr-worktree-setup --ref 70048c616979719aa592df36f37ec076227b2ac8 -y" "$work/herdr.calls"
  assert_success
  assert_output "2"
}

function test_scripts_08531_worktree_setup_migration_retries_after_enable_failure() {
  _bats_test_init 8531 'worktree setup migration restores local files and retries after enable failure'
  command_exists chezmoi || skip "chezmoi not available"
  local work="$BATS_TEST_TMPDIR/worktree-enable-migration"
  worktree_migration_prepare "$work"

  run worktree_migration_apply "$work" enable
  assert_failure
  local migration_output="$output"
  assert_dir_exists "$work/home/.config/herdr/plugins/worktree-setup"
  run grep -Fx "plugin uninstall seigi.worktree-setup" "$work/herdr.calls"
  assert_success
  run grep -Fx "plugin link $work/home/.config/herdr/plugins/worktree-setup --enabled" "$work/herdr.calls"
  assert_failure
  [[ "$migration_output" == *'MMS_DISPOSABLE_HOME=1'* ]] || fail 'rollback did not honor the disposable-home guard'

  run worktree_migration_apply "$work"
  assert_success
  assert_dir_not_exists "$work/home/.config/herdr/plugins/worktree-setup"
  run grep -Fc "plugin enable seigi.worktree-setup" "$work/herdr.calls"
  assert_success
  assert_output "2"
}

function test_scripts_08532_worktree_setup_migration_replaces_a_stale_local_registration() {
  _bats_test_init 8532 'worktree setup migration replaces a stale local registration without legacy files'
  command_exists chezmoi || skip "chezmoi not available"
  local work="$BATS_TEST_TMPDIR/worktree-stale-migration"
  worktree_migration_prepare "$work"
  rm -rf "$work/home/.config/herdr/plugins/worktree-setup"

  run worktree_migration_apply "$work"
  assert_success
  run grep -Fx "plugin uninstall seigi.worktree-setup" "$work/herdr.calls"
  assert_success
  run grep -Fx "plugin install Seigiard/herdr-worktree-setup --ref 70048c616979719aa592df36f37ec076227b2ac8 -y" "$work/herdr.calls"
  assert_success
}

function test_scripts_08536_worktree_setup_migration_rolls_back_after_registry_refresh_failure() {
  _bats_test_init 8536 'worktree setup migration removes the new registration after registry refresh failure'
  command_exists chezmoi || skip "chezmoi not available"
  local work="$BATS_TEST_TMPDIR/worktree-refresh-failure"
  worktree_migration_prepare "$work"

  run worktree_migration_apply "$work" refresh
  assert_failure
  assert_dir_exists "$work/home/.config/herdr/plugins/worktree-setup"
  run grep -Fc "plugin uninstall seigi.worktree-setup" "$work/herdr.calls"
  assert_success
  assert_output "2"
}

function test_scripts_08537_worktree_setup_migration_rejects_malformed_plugin_registry_data() {
  _bats_test_init 8537 'worktree setup migration rejects malformed plugin registry data'
  command_exists chezmoi || skip "chezmoi not available"
  local work="$BATS_TEST_TMPDIR/worktree-malformed-registry"
  worktree_migration_prepare "$work"

  run worktree_migration_apply "$work" malformed
  assert_failure
  assert_dir_exists "$work/home/.config/herdr/plugins/worktree-setup"
  run grep -F "plugin install Seigiard/herdr-worktree-setup" "$work/herdr.calls"
  assert_failure
}

function test_scripts_08533_worktree_setup_migration_restores_a_local_plugin_from_a_live_home() {
  _bats_test_init 8533 'worktree setup migration restores a local plugin when a live-home install fails'
  command_exists chezmoi || skip "chezmoi not available"
  local work="$BATS_TEST_TMPDIR/worktree-live-rollback"
  worktree_migration_prepare "$work"

  run worktree_migration_live_apply "$work" install
  assert_failure
  assert_dir_exists "$work/home/.config/herdr/plugins/worktree-setup"
  run grep -Fx "plugin link $work/home/.config/herdr/plugins/worktree-setup --enabled" "$work/herdr.calls"
  assert_success
}

function test_scripts_08534_worktree_setup_migration_preserves_unmanaged_legacy_files() {
  _bats_test_init 8534 'worktree setup migration preserves unmanaged files in the legacy directory'
  command_exists chezmoi || skip "chezmoi not available"
  local work="$BATS_TEST_TMPDIR/worktree-unmanaged-legacy"
  worktree_migration_prepare "$work"
  printf 'keep me\n' > "$work/home/.config/herdr/plugins/worktree-setup/notes.txt"

  run worktree_migration_apply "$work"
  assert_success
  assert_file_exists "$work/home/.config/herdr/plugins/worktree-setup/notes.txt"
  assert_file_not_exists "$work/home/.config/herdr/plugins/worktree-setup/setup.ts"
}

function test_scripts_08535_worktree_setup_migration_finds_the_managed_path_with_custom_xdg() {
  _bats_test_init 8535 'worktree setup migration finds the managed path when XDG_CONFIG_HOME is customized'
  command_exists chezmoi || skip "chezmoi not available"
  local work="$BATS_TEST_TMPDIR/worktree-custom-xdg"
  worktree_migration_prepare "$work"

  run worktree_migration_apply_custom_xdg "$work"
  assert_success
  assert_dir_not_exists "$work/home/.config/herdr/plugins/worktree-setup"
}

function test_scripts_08512_existing_herdr_wakeup_is_restored_when_managed_policy_linking_fails() {
  _bats_test_init 8512 'existing Herdr Wakeup is restored when managed policy linking fails'
  local template="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_7-install-herdr-github-plugins.sh.tmpl"
  local script="$BATS_TEST_TMPDIR/install-herdr-wakeup-config-failure.sh"
  local fake_bin="$BATS_TEST_TMPDIR/bin-wakeup-config-failure"
  local calls="$BATS_TEST_TMPDIR/herdr-wakeup-config-failure.calls"
  local home="$BATS_TEST_TMPDIR/herdr-wakeup-config-failure-home"
  mkdir -p "$fake_bin" "$home"
  chezmoi_full_fixture execute-template -S "$SOURCE_ROOT" --file "$template" > "$script"

  cat > "$fake_bin/uname" <<'SH'
#!/bin/sh
printf 'Darwin\n'
SH
  cat > "$fake_bin/herdr" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HERDR_CALLS"
if [ "$*" = "plugin list --json" ]; then
  printf '%s\n' '{"result":{"plugins":[{"plugin_id":"herdr-wakeup","source":{"kind":"github"}}]}}'
elif [ "$*" = "plugin config-dir herdr-wakeup" ]; then
  printf '%s\n' "$HOME/.config/herdr/plugins/config/herdr-wakeup"
fi
exit 0
SH
  chmod +x "$fake_bin/uname" "$fake_bin/herdr"

  run env HOME="$home" HERDR_CALLS="$calls" PATH="$fake_bin:$PATH" bash "$script"
  assert_success
  assert_output --partial "config: link the managed policy"
  run grep -Fx "plugin action invoke stop --plugin herdr-wakeup" "$calls"
  assert_success
  run grep -Fx "plugin action invoke start --plugin herdr-wakeup" "$calls"
  assert_success
}

function test_scripts_0852_obsolete_plugin_removal_reports_malformed_entries() {
  _bats_test_init 852 'obsolete plugin removal reports malformed plugin entries'
  local template="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_7-install-herdr-github-plugins.sh.tmpl"
  local script="$BATS_TEST_TMPDIR/install-herdr-github-plugins-malformed.sh"
  local fake_bin="$BATS_TEST_TMPDIR/bin-malformed"
  mkdir -p "$fake_bin"
  chezmoi_full_fixture execute-template -S "$SOURCE_ROOT" --file "$template" > "$script"

  cat > "$fake_bin/uname" <<'SH'
#!/bin/sh
printf 'Darwin\n'
SH
  cat > "$fake_bin/herdr" <<'SH'
#!/bin/sh
if [ "$*" = "plugin list --json" ]; then
  printf '{"result":{"plugins":[null,{"plugin_id":"worktrunk"}]}}\n'
fi
exit 0
SH
  chmod +x "$fake_bin/uname" "$fake_bin/herdr"

  run env HOME="$BATS_TEST_TMPDIR/malformed-plugin-home" PATH="$fake_bin:$PATH" bash "$script"
  assert_success
  assert_output --partial "failed to inspect obsolete plugin artisann.zed-herdr"
}

palette_migration_prepare() {
  local work="$1"
  local source="$work/source" home="$work/home" fake_bin="$work/bin"
  mkdir -p \
    "$source/.chezmoiscripts" \
    "$home/.config/herdr/plugins/command-palette" \
    "$home/.config/herdr/command-palette" \
    "$fake_bin"
  cp "$SOURCE_ROOT/.chezmoiscripts/run_once_after_6-migrate-herdr-command-palette.sh.tmpl" \
    "$source/.chezmoiscripts/"
  printf 'legacy plugin\n' > "$home/.config/herdr/plugins/command-palette/palette.py"
  printf 'user catalog\n' > "$home/.config/herdr/command-palette/commands.toml"
  write_test_config "$work/chezmoi.yaml"

  cat > "$fake_bin/herdr" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HERDR_CALLS"
case "$*" in
  "plugin list --json")
    printf '%s\n' '{"result":{"plugins":[{"plugin_id":"seigi.command-palette","source":{"kind":"local"}}]}}'
    ;;
  "plugin install Seigiard/herdr-command-palette --ref 9c92d2d0b0d275183880c9033e73657e513d3da1 -y")
    [ "${HERDR_FAIL_STEP:-}" != install ]
    ;;
  "plugin enable seigi.command-palette")
    [ "${HERDR_FAIL_STEP:-}" != enable ]
    ;;
  *)
    exit 0
    ;;
esac
SH
  chmod +x "$fake_bin/herdr"
}

palette_migration_apply() {
  local work="$1" fail_step="${2:-}"
  HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" \
    PATH="$work/bin:$PATH" HERDR_CALLS="$work/herdr.calls" \
    HERDR_FAIL_STEP="$fail_step" chezmoi_full_fixture apply \
    --source "$work/source" --destination "$work/home" --config "$work/chezmoi.yaml"
}

function test_scripts_08521_command_palette_migration_retries_after_install_failure() {
  _bats_test_init 8521 'command palette migration restores local registration and retries after install failure'
  command_exists chezmoi || skip "chezmoi not available"
  local work="$BATS_TEST_TMPDIR/palette-install-failure"
  palette_migration_prepare "$work"

  run palette_migration_apply "$work" install
  assert_failure
  assert_dir_exists "$work/home/.config/herdr/plugins/command-palette"
  assert_file_exists "$work/home/.config/herdr/command-palette/commands.toml"
  run grep -Fx "plugin link $work/home/.config/herdr/plugins/command-palette --enabled" "$work/herdr.calls"
  assert_success

  run palette_migration_apply "$work"
  assert_success
  assert_dir_not_exists "$work/home/.config/herdr/plugins/command-palette"
  assert_file_exists "$work/home/.config/herdr/command-palette/commands.toml"
  run grep -Fc "plugin install Seigiard/herdr-command-palette --ref 9c92d2d0b0d275183880c9033e73657e513d3da1 -y" "$work/herdr.calls"
  assert_success
  assert_output "2"
}

function test_scripts_08522_command_palette_migration_retries_after_enable_failure() {
  _bats_test_init 8522 'command palette migration restores local registration and retries after enable failure'
  command_exists chezmoi || skip "chezmoi not available"
  local work="$BATS_TEST_TMPDIR/palette-enable-failure"
  palette_migration_prepare "$work"

  run palette_migration_apply "$work" enable
  assert_failure
  assert_dir_exists "$work/home/.config/herdr/plugins/command-palette"
  assert_file_exists "$work/home/.config/herdr/command-palette/commands.toml"
  run grep -Fx "plugin link $work/home/.config/herdr/plugins/command-palette --enabled" "$work/herdr.calls"
  assert_success

  run palette_migration_apply "$work"
  assert_success
  assert_dir_not_exists "$work/home/.config/herdr/plugins/command-palette"
  assert_file_exists "$work/home/.config/herdr/command-palette/commands.toml"
  run grep -Fc "plugin enable seigi.command-palette" "$work/herdr.calls"
  assert_success
  assert_output "2"
}

function test_scripts_08523_plugin_list_fake_fields_match_real_herdr() {
  _bats_test_init 8523 'plugin-list fake fields match the installed Herdr contract'
  command_exists herdr || skip "herdr is not installed"
  local plugin_json

  run env -i HOME="$HOME" PATH="$PATH" \
    HERDR_SOCKET_PATH="/tmp/mms-herdr-plugin-contract-$$.sock" herdr plugin list --json
  [[ $status -eq 0 ]] || skip "real herdr returned no plugin list: $output"
  plugin_json="$output"

  run env PLUGIN_JSON="$plugin_json" python3 - <<'PY'
import json
import os

plugins = json.loads(os.environ["PLUGIN_JSON"])["result"]["plugins"]
assert plugins, "real herdr returned no plugins"
kinds = set()
for plugin in plugins:
    assert isinstance(plugin.get("plugin_id"), str), plugin
    assert isinstance(plugin.get("enabled"), bool), plugin
    source = plugin.get("source")
    assert isinstance(source, dict) and isinstance(source.get("kind"), str), plugin
    kinds.add(source["kind"])
assert kinds <= {"local", "github"}, kinds
print(" ".join(sorted(kinds)))
PY
  assert_success
  [[ " $output " == *" local "* && " $output " == *" github "* ]] \
    || skip "real registry does not currently expose both local and github source kinds: $output"

  run env -i HOME="$HOME" PATH="$PATH" \
    HERDR_SOCKET_PATH="/tmp/mms-herdr-plugin-contract-$$.sock" \
    herdr plugin enable missing.plugin
  assert_failure
  local enable_error="$output"
  run env ENABLE_ERROR="$enable_error" python3 - <<'PY'
import json
import os

error = json.loads(os.environ["ENABLE_ERROR"])["error"]
assert error["code"] == "server_not_running", error
PY
  assert_success
}

function test_scripts_08524_worktree_setup_is_installed_enabled_and_pinned() {
  _bats_test_init 8524 'standalone Worktree Setup is installed enabled and pinned to the reviewed commit'
  command_exists herdr && herdr --version >/dev/null 2>&1 \
    || skip "a working upstream herdr is not installed"
  [[ "${MMS_DISPOSABLE_HOME:-}" == 1 ]] || skip "requires the disposable post-apply registry"
  local plugin_json
  run env -i HOME="$HOME" PATH="$PATH" \
    HERDR_SOCKET_PATH="/tmp/mms-herdr-worktree-setup-$$.sock" herdr plugin list --json
  assert_success
  plugin_json="$output"

  run env PLUGIN_JSON="$plugin_json" python3 - <<'PY'
import json
import os

plugins = json.loads(os.environ["PLUGIN_JSON"])["result"]["plugins"]
matches = [
    plugin for plugin in plugins
    if plugin.get("plugin_id") == "seigi.worktree-setup"
]
assert len(matches) == 1, matches
plugin = matches[0]
source = plugin["source"]
assert plugin["enabled"] is True, plugin
assert source["kind"] == "github", source
assert source["owner"] == "Seigiard" and source["repo"] == "herdr-worktree-setup", source
assert source["resolved_commit"] == "70048c616979719aa592df36f37ec076227b2ac8", source
PY
  assert_success
}

caffeinate_migration_prepare() {
  local work="$1" legacy_root="${2:-present}"
  local source="$work/source" home="$work/home" fake_bin="$work/bin"
  mkdir -p \
    "$source/.chezmoiscripts/darwin" \
    "$source/.chezmoitemplates" \
    "$source/private_dot_config/herdr/plugins/config/herdr-wakeup" \
    "$home/.config/herdr/plugins/config/herdr-wakeup" \
    "$fake_bin"
  if [[ "$legacy_root" == present ]]; then
    mkdir -p "$home/.config/herdr/plugins/herdr-caffeinate"
    printf '%s\n' 'id = "keepawake.caffeinate"' \
      > "$home/.config/herdr/plugins/herdr-caffeinate/herdr-plugin.toml"
    cat > "$home/.config/herdr/plugins/herdr-caffeinate/reconcile.sh" <<'SH'
#!/bin/sh
: > "$HOME/legacy-reconciled"
SH
    chmod +x "$home/.config/herdr/plugins/herdr-caffeinate/reconcile.sh"
  fi
  cp "$SOURCE_ROOT/.chezmoiscripts/darwin/run_once_after_6-migrate-herdr-caffeinate.sh.tmpl" \
    "$source/.chezmoiscripts/darwin/"
  cp "$SOURCE_ROOT/.chezmoitemplates/herdr-wakeup-package.sh" \
    "$source/.chezmoitemplates/"
  printf '%s\n' '{"stop_grace_seconds":1200}' \
    > "$source/private_dot_config/herdr/plugins/config/herdr-wakeup/config.json"
  write_test_config "$work/chezmoi.yaml"

  cat > "$fake_bin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_CALLS"
case "$*" in
  "plugin list --json")
    printf '%s\n' '{"result":{"plugins":[{"plugin_id":"keepawake.caffeinate","source":{"kind":"local"}}]}}'
    ;;
  "plugin install usrivastava92/herdr-wakeup/plugin --ref 43db0b9f88a4b1bc560593b0ce8f2a7d2a940f04 -y")
    [ "$HERDR_FAIL_STEP" != install ] || exit 1
    : > "$HOME/replacement-installed"
    ;;
  "plugin config-dir herdr-wakeup")
    printf '%s\n' "$HOME/.config/herdr/plugins/config/herdr-wakeup"
    ;;
  "plugin enable herdr-wakeup")
    [ "$HERDR_FAIL_STEP" != enable ] || exit 1
    [ -f "$HOME/replacement-installed" ] || exit 3
    [ -L "$HOME/.config/herdr/plugins/config/herdr-wakeup/sessions/f60c672338465554/config.json" ] || exit 4
    : > "$HOME/replacement-enabled"
    ;;
  "plugin action invoke stop --plugin keepawake.caffeinate")
    [ -d "$HOME/.config/herdr/plugins/herdr-caffeinate" ] || exit 1
    [ -f "$HOME/replacement-enabled" ] || exit 5
    : > "$HOME/legacy-stopped"
    ;;
  "plugin action invoke status --plugin keepawake.caffeinate")
    [ -f "$HOME/legacy-reconciled" ] || exit 10
    ;;
  "plugin disable keepawake.caffeinate")
    [ ! -d "$HOME/.config/herdr/plugins/herdr-caffeinate" ] || \
      [ -f "$HOME/legacy-stopped" ] || exit 6
    : > "$HOME/legacy-disabled"
    ;;
  "server reload-config")
    [ -f "$HOME/legacy-disabled" ] || exit 7
    if [ "$HERDR_FAIL_STEP" = reload ] && [ ! -f "$HOME/activation-reload-failed" ]; then
      : > "$HOME/activation-reload-failed"
      exit 1
    fi
    : > "$HOME/server-reloaded"
    ;;
  "plugin action invoke start --plugin herdr-wakeup")
    [ -f "$HOME/server-reloaded" ] || exit 8
    : > "$HOME/replacement-started"
    ;;
  "plugin uninstall keepawake.caffeinate")
    [ -f "$HOME/replacement-started" ] || exit 9
    ;;
  *)
    exit 0
    ;;
esac
SH
  chmod +x "$fake_bin/herdr"
  : > "$work/herdr.calls"
}

caffeinate_migration_run() {
  local work="$1" fail_step="${2:-}"
  HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" \
    PATH="$work/bin:$PATH" HERDR_CALLS="$work/herdr.calls" \
    HERDR_FAIL_STEP="$fail_step" HERDR_SOCKET_PATH=/tmp/mms-herdr-wakeup-test.sock \
    chezmoi_full_fixture apply --source "$work/source" --destination "$work/home" \
      --config "$work/chezmoi.yaml"
}

function test_scripts_08524_caffeinate_migration_cuts_over_only_after_the_replacement_is_ready() {
  _bats_test_init 8524 'caffeinate migration configures the replacement before stopping the local plugin'
  local work="$BATS_TEST_TMPDIR/caffeinate-migration"
  local wakeup_config="$work/home/.config/herdr/plugins/config/herdr-wakeup"
  caffeinate_migration_prepare "$work"

  run caffeinate_migration_run "$work"
  assert_success
  assert_dir_not_exists "$work/home/.config/herdr/plugins/herdr-caffeinate"
  run readlink "$wakeup_config/sessions/f60c672338465554/config.json"
  assert_success
  assert_output "$wakeup_config/config.json"
  run grep -Fx "plugin action invoke stop --plugin keepawake.caffeinate" "$work/herdr.calls"
  assert_success
  run grep -Fx "plugin uninstall keepawake.caffeinate" "$work/herdr.calls"
  assert_success
  run grep -Fx "plugin install usrivastava92/herdr-wakeup/plugin --ref 43db0b9f88a4b1bc560593b0ce8f2a7d2a940f04 -y" "$work/herdr.calls"
  assert_success
  run grep -Fx "plugin enable herdr-wakeup" "$work/herdr.calls"
  assert_success
}

function test_scripts_08525_caffeinate_migration_keeps_the_local_owner_when_installation_fails() {
  _bats_test_init 8525 'caffeinate migration keeps the local wake-lock owner when replacement installation fails'
  local work="$BATS_TEST_TMPDIR/caffeinate-migration-install-failure"
  caffeinate_migration_prepare "$work"

  run caffeinate_migration_run "$work" install
  assert_failure
  assert_output --partial "Herdr Wakeup installation failed"
  assert_dir_exists "$work/home/.config/herdr/plugins/herdr-caffeinate"
  run grep -Fx "plugin action invoke stop --plugin keepawake.caffeinate" "$work/herdr.calls"
  assert_failure
  run grep -Fx "plugin uninstall keepawake.caffeinate" "$work/herdr.calls"
  assert_failure

  run caffeinate_migration_run "$work"
  assert_success
  assert_dir_not_exists "$work/home/.config/herdr/plugins/herdr-caffeinate"
  run grep -Fc "plugin install usrivastava92/herdr-wakeup/plugin --ref 43db0b9f88a4b1bc560593b0ce8f2a7d2a940f04 -y" "$work/herdr.calls"
  assert_success
  assert_output "2"
}

function test_scripts_08526_caffeinate_migration_removes_a_stale_local_registration_without_legacy_files() {
  _bats_test_init 8526 'caffeinate migration removes the stale local registration after replacement startup'
  local work="$BATS_TEST_TMPDIR/caffeinate-migration-stale-registration"
  caffeinate_migration_prepare "$work" absent

  run caffeinate_migration_run "$work"
  assert_success
  run grep -Fx "plugin uninstall keepawake.caffeinate" "$work/herdr.calls"
  assert_success
  run grep -Fx "plugin action invoke start --plugin herdr-wakeup" "$work/herdr.calls"
  assert_success
}

function test_scripts_08527_caffeinate_migration_restores_the_local_owner_when_reload_fails() {
  _bats_test_init 8527 'caffeinate migration restores the local owner when replacement activation fails'
  local work="$BATS_TEST_TMPDIR/caffeinate-migration-reload-failure"
  caffeinate_migration_prepare "$work"

  run caffeinate_migration_run "$work" reload
  assert_failure
  assert_output --partial "restored and reconciled the local owner"
  assert_dir_exists "$work/home/.config/herdr/plugins/herdr-caffeinate"
  assert_file_exists "$work/home/legacy-reconciled"
  run grep -Fx "plugin enable keepawake.caffeinate" "$work/herdr.calls"
  assert_success
  run grep -Fx "plugin action invoke status --plugin keepawake.caffeinate" "$work/herdr.calls"
  assert_success
  run grep -Fx "plugin uninstall herdr-wakeup" "$work/herdr.calls"
  assert_success
  run grep -Fx "plugin uninstall keepawake.caffeinate" "$work/herdr.calls"
  assert_failure
}

function test_scripts_08528_caffeinate_migration_skips_a_broken_wrapper_without_legacy_files() {
  _bats_test_init 8528 'caffeinate migration skips a broken wrapper without legacy files'
  local work="$BATS_TEST_TMPDIR/caffeinate-migration-wrapper-only"
  caffeinate_migration_prepare "$work" absent
  cat > "$work/bin/herdr" <<'SH'
#!/bin/sh
exit 127
SH
  chmod +x "$work/bin/herdr"

  run caffeinate_migration_run "$work"

  assert_success
}

# ask-in-herdr skill script
# ===========================================

PRE_EXTERNAL_SECRET_SCAN="$SOURCE_ROOT/dot_local/bin/executable_pre-external-secret-scan"
ASK_HERDR_DIR="$SOURCE_ROOT/private_dot_agents/skills/ask-in-herdr/scripts"
ASK_HERDR_SCRIPT="$ASK_HERDR_DIR/executable_ask.sh"
ASK_HERDR_FOLLOW_UP="$ASK_HERDR_DIR/executable_follow-up.sh"

function test_scripts_1225_pre_external_secret_scan_accepts_clean_references_and_rejects_a_real_leak() {
  _bats_test_init 1225 'pre-external secret scan accepts clean references and rejects a real leak'
  if ! command_exists gitleaks; then
    [ "${MMS_DISPOSABLE_HOME:-0}" != 1 ] || fail "gitleaks is missing from the disposable-home test process"
    skip "gitleaks is not installed"
  fi
  local clean_dir="$BATS_TEST_TMPDIR/scan-clean"
  local leak_dir="$BATS_TEST_TMPDIR/scan-leak"
  local token
  mkdir -p "$clean_dir" "$leak_dir"
  printf '%s\n' 'onepasswordRead "op://Private/Example/credential"' > "$clean_dir/config.tmpl"
  token='ghp_''A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8'
  printf 'token=%s # gitleaks:allow\n' "$token" > "$leak_dir/config"
  cat > "$leak_dir/.gitleaks.toml" <<'TOML'
title = "checkout-controlled empty rules"
TOML

  run bash "$PRE_EXTERNAL_SECRET_SCAN" "$clean_dir"
  assert_success
  assert_output --partial 'pre-external secret scan clean'

  run bash -c 'printf "%s\n" '\''onepasswordRead "op://Private/Example/credential"'\'' | bash "$1" --stdin "$2"' \
    _ "$PRE_EXTERNAL_SECRET_SCAN" "$clean_dir"
  assert_success
  assert_output --partial 'pre-external secret scan clean: <stdin>'

  run bash "$PRE_EXTERNAL_SECRET_SCAN" "$clean_dir" "$leak_dir"
  assert_failure 1
  assert_output --partial 'pre-external secret gate REFUSED'
  assert_output --partial 'FOUND secrets'
  refute_output --partial "$token"

  run bash -c 'printf "prompt=%s\n" "$3" | bash "$1" --stdin "$2"' \
    _ "$PRE_EXTERNAL_SECRET_SCAN" "$clean_dir" "$token"
  assert_failure 1
  assert_output --partial 'FOUND secrets in <stdin>'
  refute_output --partial "$token"

  local option_parent="$BATS_TEST_TMPDIR/scan-option"
  mkdir -p "$option_parent/--exit-code=0"
  printf 'token=%s\n' "$token" > "$option_parent/--exit-code=0/config"
  run bash -c 'cd "$1" && bash "$2" --exit-code=0' \
    _ "$option_parent" "$PRE_EXTERNAL_SECRET_SCAN"
  assert_failure 1
  assert_output --partial 'FOUND secrets'

  local linked_root="$BATS_TEST_TMPDIR/scan-linked-root"
  mkdir -p "$linked_root"
  ln -s "$leak_dir" "$linked_root/outside"
  run bash "$PRE_EXTERNAL_SECRET_SCAN" "$linked_root"
  assert_failure 1
  assert_output --partial 'directory symlink escapes scan root'

  run env SE_SKIP_SECRET_SCAN=1 bash "$PRE_EXTERNAL_SECRET_SCAN" "$leak_dir"
  assert_success
  assert_output --partial 'SKIPPED by operator'

  run env SE_SKIP_SECRET_SCAN=false bash "$PRE_EXTERNAL_SECRET_SCAN" "$leak_dir"
  assert_failure 1
  assert_output --partial 'FOUND secrets'

  run env GITLEAKS_CONFIG_TOML='title = "ambient empty rules"' \
    bash "$PRE_EXTERNAL_SECRET_SCAN" "$leak_dir"
  assert_failure 1
  assert_output --partial 'FOUND secrets'
}

function test_scripts_1226_pre_external_secret_scan_fails_closed_without_a_clean_scanner_verdict() {
  _bats_test_init 1226 'pre-external secret scan fails closed without a clean scanner verdict'
  local empty_bin="$BATS_TEST_TMPDIR/scan-empty-bin"
  local bad_bin="$BATS_TEST_TMPDIR/scan-bad-bin"
  local scan_dir="$BATS_TEST_TMPDIR/scan-input"
  mkdir -p "$empty_bin" "$bad_bin" "$scan_dir"
  cat > "$bad_bin/gitleaks" <<'SH'
#!/bin/sh
exit 7
SH
  chmod +x "$bad_bin/gitleaks"

  run env PATH="$empty_bin:/usr/bin:/bin" /bin/bash "$PRE_EXTERNAL_SECRET_SCAN" "$scan_dir"
  assert_failure 1
  assert_output --partial 'gitleaks is not on PATH'
  assert_output --partial 'Nothing was sent externally'

  run env PATH="$bad_bin:/usr/bin:/bin" /bin/bash "$PRE_EXTERNAL_SECRET_SCAN" "$scan_dir"
  assert_failure 1
  assert_output --partial 'unexpected code 7'
  assert_output --partial 'Nothing was sent externally'

  run bash "$PRE_EXTERNAL_SECRET_SCAN" "$scan_dir/missing"
  assert_failure 1
  assert_output --partial 'scan target does not exist'
  assert_output --partial 'Nothing was sent externally'
}

ask_live_stub() {
  child_new_stub
  cat > "$CHILD_STUB/herdr-child" <<'SH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$CHILD_STUB/child.log"; printf '\n' >> "$CHILD_STUB/child.log"
printf 'child ' >> "$CHILD_STUB/order.log"; printf '%q ' "$@" >> "$CHILD_STUB/order.log"; printf '\n' >> "$CHILD_STUB/order.log"
case "${1:-}" in
  start)
    stub_pf=""; stub_prev=""
    for stub_arg in "$@"; do
      [ "$stub_prev" != "--prompt-file" ] || stub_pf="$stub_arg"
      stub_prev="$stub_arg"
    done
    [ -z "$stub_pf" ] || cp "$stub_pf" "$CHILD_STUB/prompt.txt"
    stub_rp=""
    [ -z "$stub_pf" ] || stub_rp="$(grep -o '/[^ ]*/answer\.report' "$stub_pf" | head -1)"
    printf '%s' "$stub_rp" > "$CHILD_STUB/report-path"
    if [ -n "$stub_rp" ]; then
      case "${STUB_REPORT:-write}" in
        write)
          if [ -n "${STUB_REPORT_LINES:-}" ]; then
            : > "$stub_rp"
            stub_i=1
            while [ "$stub_i" -le "$STUB_REPORT_LINES" ]; do
              printf 'report line %s\n' "$stub_i" >> "$stub_rp"
              stub_i=$((stub_i + 1))
            done
          else
            printf '%s\n' "${STUB_REPORT_BODY:-ANSWER from child}" > "$stub_rp"
          fi
          ;;
        empty) : > "$stub_rp" ;;
        symlink) ln -s /etc/hosts "$stub_rp" ;;
        none) : ;;
      esac
    fi
    printf '{"agent":"red-wolf","pane":"wT:p9"}\n'
    [ "${STUB_CHILD_STATUS:-0}" -eq 0 ] || { printf 'child-start-error\n' >&2; exit "$STUB_CHILD_STATUS"; }
    ;;
  prompt)
    printf 'prompt ' >> "$CHILD_STUB/recover.log"; printf '\n' >> "$CHILD_STUB/recover.log"
    if [ "${STUB_RECOVER:-0}" = 1 ]; then
      stub_rp2=""; [ ! -f "$CHILD_STUB/report-path" ] || read -r stub_rp2 < "$CHILD_STUB/report-path"
      [ -z "$stub_rp2" ] || printf '%s\n' "${STUB_REPORT_BODY:-RECOVERED answer}" > "$stub_rp2"
    fi
    exit "${STUB_PROMPT_STATUS:-0}"
    ;;
  reply) exit "${STUB_REPLY_STATUS:-0}" ;;
  verify)
    count=0; [ ! -f "$CHILD_STUB/verify-count" ] || read -r count < "$CHILD_STUB/verify-count"
    count=$((count + 1)); printf '%s\n' "$count" > "$CHILD_STUB/verify-count"
    [ "${STUB_PAIR_FAIL_AT:-0}" -ne "$count" ] || exit 1
    if [ "${STUB_PAIR_TERMINAL_CHANGE_AT:-0}" -eq "$count" ]; then
      printf 'term-replaced\n'
    else
      printf 'term-child\n'
    fi
    ;;
  *) exit 2 ;;
esac
SH
  cat > "$CHILD_STUB/pre-external-secret-scan" <<'SH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$CHILD_STUB/scan.log"; printf '\n' >> "$CHILD_STUB/scan.log"
scan_count=0
[ ! -f "$CHILD_STUB/scan-count" ] || read -r scan_count < "$CHILD_STUB/scan-count"
scan_count=$((scan_count + 1))
printf '%s\n' "$scan_count" > "$CHILD_STUB/scan-count"
[ "${STUB_SCAN_FAIL_AT:-0}" -ne "$scan_count" ] || exit 1
if [ -n "${STUB_SCAN_MATCH:-}" ]; then
  for scan_arg in "$@"; do
    if [ -f "$scan_arg" ] && grep -q -- "$STUB_SCAN_MATCH" "$scan_arg"; then exit 1; fi
    if [ "${STUB_SCAN_DIRS:-0}" = 1 ] && [ -d "$scan_arg" ] && \
       grep -R -q -- "$STUB_SCAN_MATCH" "$scan_arg"; then exit 1; fi
  done
fi
exit "${STUB_SCAN_STATUS:-0}"
SH
  cat > "$CHILD_STUB/herdr" <<'SH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$CHILD_STUB/herdr.log"; printf '\n' >> "$CHILD_STUB/herdr.log"
printf 'herdr ' >> "$CHILD_STUB/order.log"; printf '%q ' "$@" >> "$CHILD_STUB/order.log"; printf '\n' >> "$CHILD_STUB/order.log"
case "$1 $2" in
  "agent list")
    count=0; [ ! -f "$CHILD_STUB/list-count" ] || read -r count < "$CHILD_STUB/list-count"
    count=$((count + 1)); printf '%s\n' "$count" > "$CHILD_STUB/list-count"
    if [ "${STUB_PAIR_FAIL_AT:-0}" -eq "$count" ]; then
      printf '{"result":{"agents":[{"name":"red-wolf","pane_id":"wT:p8","agent":"claude","terminal_id":"term-other","revision":2,"state_change_seq":2}]}}\n'
    elif [ "${STUB_PAIR_TERMINAL_CHANGE_AT:-0}" -eq "$count" ]; then
      printf '{"result":{"agents":[{"name":"red-wolf","pane_id":"wT:p9","agent":"claude","terminal_id":"term-replaced","revision":2,"state_change_seq":2}]}}\n'
    else
      printf '{"result":{"agents":[{"name":"red-wolf","pane_id":"wT:p9","agent":"claude","terminal_id":"term-child","revision":1,"state_change_seq":1}]}}\n'
    fi ;;
  "agent read") [ "${STUB_READ_FAIL:-0}" = 1 ] && { printf 'read failed\n' >&2; exit 1; }; printf 'ANSWER from child\n' ;;
  "agent get") printf '{"result":{"agent":{"name":"red-wolf","pane_id":"wT:p9","agent":"claude","terminal_id":"term-child","revision":1,"state_change_seq":1,"agent_status":"%s"}}}\n' "${STUB_AGENT_STATUS:-idle}" ;;
  "agent prompt")
    [ "${STUB_PARENT_PROMPT_FAIL:-0}" = 1 ] && { printf 'prompt failed\n' >&2; exit 1; }
    printf '%s' "$4" > "$CHILD_STUB/parent-prompt"
    printf '{"result":{"agent":{"agent_status":"working"}}}\n'
    ;;
  "pane get")
    if [ "${STUB_WAITING_LABEL:-0}" = 1 ]; then
      printf '{"result":{"pane":{"pane_id":"wT:p9","terminal_id":"term-child","cwd":"%s","state_labels":{"blocked":"waiting for parent"}}}}\n' "${STUB_PANE_CWD:-$PWD}"
    else printf '{"result":{"pane":{"pane_id":"wT:p9","terminal_id":"term-child","cwd":"%s"}}}\n' "${STUB_PANE_CWD:-$PWD}"; fi ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$CHILD_STUB/herdr-child" "$CHILD_STUB/herdr" "$CHILD_STUB/pre-external-secret-scan"
}

function test_scripts_1051_ask_in_herdr_script_requires_arguments() {
  _bats_test_init 1051 'ask-in-herdr script requires arguments'
  run bash "$ASK_HERDR_SCRIPT"
  assert_failure 2
  assert_output --partial "Usage:"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=refused"
}

function test_scripts_1052_ask_sh_rejects_unknown_agents_and_the_removed_headless_() {
  _bats_test_init 1052 'ask.sh rejects unknown agents and the removed headless flag'
  run bash "$ASK_HERDR_SCRIPT" bogus question
  assert_failure 2
  assert_output --partial "claude opencode pi"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=refused"

  run bash "$ASK_HERDR_SCRIPT" claude question --model
  assert_failure 2
  assert_output --partial "Usage:"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=refused"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question --headless
  assert_failure 2
  assert_output --partial "unknown flag '--headless'"
  assert_output --partial "ask.sh: status=refused"
  [ ! -f "$CHILD_STUB/child.log" ]
}

function test_scripts_1053_ask_sh_refuses_outside_herdr_and_when_herdr_child_is_ab() {
  _bats_test_init 1053 'ask.sh refuses outside herdr and when herdr-child is absent'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV= HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 2
  assert_output --partial "status=refused"
  [ ! -f "$CHILD_STUB/child.log" ]

  local no_child; no_child="$(mktemp -d)"
  cp "$CHILD_STUB/herdr" "$no_child/herdr"
  run env PATH="$no_child:/usr/bin:/bin" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 2
  assert_output --partial "herdr-child is not on PATH"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=refused"
  rm -rf "$no_child"
}

function test_scripts_1227_ask_sh_refuses_before_launch_when_the_secret_scan_is_not_clean() {
  _bats_test_init 1227 'ask.sh refuses before launch when the secret scan is not clean'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_SCAN_MATCH=question-secret-marker HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question-secret-marker --skills "$ASK_HERDR_DIR"
  assert_failure 2
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=refused"
  assert_file_not_exists "$CHILD_STUB/child.log"
  assert_file_contains "$CHILD_STUB/scan.log" "$PWD"
  assert_file_contains "$CHILD_STUB/scan.log" "$ASK_HERDR_DIR"
}

function test_scripts_1228_ask_in_herdr_follow_up_rescans_the_question_before_prompting() {
  _bats_test_init 1228 'ask-in-herdr follow-up rescans the question before prompting'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_SCAN_MATCH=follow-up-secret-marker HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_FOLLOW_UP" prompt red-wolf wT:p9 follow-up-secret-marker
  assert_failure 2
  assert_line --index "$(( ${#lines[@]} - 1 ))" 'follow-up.sh: status=refused'
  assert_file_not_exists "$CHILD_STUB/child.log"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_FOLLOW_UP" prompt red-wolf wT:p9 clean-question
  assert_success
  assert_line --index "$(( ${#lines[@]} - 1 ))" 'follow-up.sh: status=delivered'
  assert_file_contains "$CHILD_STUB/child.log" '^prompt --to red-wolf --pane wT:p9 --wait clean-question'

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_FOLLOW_UP" reply red-wolf wT:p9 clean-decision
  assert_success
  assert_line --index "$(( ${#lines[@]} - 1 ))" 'follow-up.sh: status=delivered'
  assert_file_contains "$CHILD_STUB/child.log" '^reply --to red-wolf --pane wT:p9 clean-decision'

  ask_live_stub
  local secret_cwd="$BATS_TEST_TMPDIR/follow-up-secret-cwd"
  mkdir -p "$secret_cwd"
  printf '%s\n' follow-up-secret-marker > "$secret_cwd/secret"
  run env PATH="$CHILD_STUB:$PATH" STUB_SCAN_MATCH=follow-up-secret-marker STUB_SCAN_DIRS=1 \
    STUB_PANE_CWD="$secret_cwd" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_FOLLOW_UP" prompt red-wolf wT:p9 clean-question
  assert_failure 2
  assert_file_not_exists "$CHILD_STUB/child.log"

  ask_live_stub
  local clean_cwd="$BATS_TEST_TMPDIR/follow-up-clean-cwd"
  local secret_skills="$BATS_TEST_TMPDIR/follow-up-secret-skills"
  mkdir -p "$clean_cwd" "$secret_skills"
  printf '%s\n' follow-up-secret-marker > "$secret_skills/secret"
  run env PATH="$CHILD_STUB:$PATH" STUB_SCAN_MATCH=follow-up-secret-marker STUB_SCAN_DIRS=1 \
    STUB_PANE_CWD="$clean_cwd" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_FOLLOW_UP" prompt red-wolf wT:p9 clean-question --skills "$secret_skills"
  assert_failure 2
  assert_file_not_exists "$CHILD_STUB/child.log"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_PROMPT_STATUS=124 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_FOLLOW_UP" prompt red-wolf wT:p9 clean-question
  assert_failure 124
  assert_line --index "$(( ${#lines[@]} - 1 ))" 'follow-up.sh: status=working'

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_PROMPT_STATUS=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_FOLLOW_UP" prompt red-wolf wT:p9 clean-question
  assert_failure 1
  assert_line --index "$(( ${#lines[@]} - 1 ))" 'follow-up.sh: status=delivery-unknown'
}

function test_scripts_1054_ask_sh_starts_a_read_only_live_child_and_returns_its_an() {
  _bats_test_init 1054 'ask.sh starts a read-only live child and returns its answer'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude "hi there"
  assert_success
  assert_output --partial "ANSWER from child"
  assert_output --partial "close with: herdr-child reap --to red-wolf --pane wT:p9"
  assert_output --partial "ask.sh: status=answered"
  run grep -E -- '^start --kind claude --posture ro ' "$CHILD_STUB/child.log"
  assert_success
  run grep -E -- '--prompt-file .* --wait --timeout 1800000' "$CHILD_STUB/child.log"
  assert_success
  run grep -E -- '^agent read red-wolf --source visible --lines 200' "$CHILD_STUB/herdr.log"
  assert_success
  assert_file_contains "$CHILD_STUB/parent-prompt" '^\[child-settled v1 agent=red-wolf pane=wT:p9\]$'
  assert_file_contains "$CHILD_STUB/parent-prompt" 'initial answer has been read'
  assert_file_contains "$CHILD_STUB/parent-prompt" 'read its current output before reaping'
  assert_file_contains "$CHILD_STUB/parent-prompt" 'herdr-child reap --to red-wolf --pane wT:p9'
  assert_file_contains "$CHILD_STUB/parent-prompt" 'ask-in-herdr/scripts/follow-up.sh prompt red-wolf wT:p9'
  assert_file_contains "$CHILD_STUB/herdr.log" '^agent prompt wT:p0 '
}

function test_scripts_1055_ask_sh_keeps_a_settled_answer_when_the_parent_reminder_() {
  _bats_test_init 1055 'ask.sh keeps a settled answer when the parent reminder cannot be queued'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENT_STATUS=done STUB_PARENT_PROMPT_FAIL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$ASK_HERDR_SCRIPT" claude question
  assert_success
  assert_output --partial "ANSWER from child"
  assert_output --partial "warning: could not queue the cleanup reminder"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=answered"
  assert_file_not_exists "$CHILD_STUB/parent-prompt"
}

function test_scripts_1056_ask_sh_forwards_posture_and_every_native_caller_option() {
  _bats_test_init 1056 'ask.sh forwards posture and every native caller option'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" pi question --rw --model M --effort high \
      --cwd "$PWD" --skills A --skills B --agent N
  assert_success
  run grep -E -- '--posture rw' "$CHILD_STUB/child.log"
  assert_success
  run grep -E -- '--model M --effort high --agent N --skills A --skills B' "$CHILD_STUB/child.log"
  assert_success

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" opencode question
  assert_success
  run grep -q -- '--model' "$CHILD_STUB/child.log"
  assert_failure
}

function test_scripts_1057_ask_sh_performs_no_agent_list_preflight_or_query_and_ve() {
  _bats_test_init 1057 'ask.sh performs no agent-list preflight or query and verifies the returned pair twice'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_success
  refute_output --partial "consult-claude"
  run grep -q -- '--name' "$CHILD_STUB/child.log"
  assert_failure
  run sed -n '1p' "$CHILD_STUB/order.log"
  assert_output --partial "child start"
  run grep -c '^herdr agent list' "$CHILD_STUB/herdr.log"
  assert_failure
  assert_output 0
  run grep -c '^verify --to red-wolf --pane wT:p9 ' "$CHILD_STUB/child.log"
  assert_success
  assert_output 2
}

function test_scripts_1058_ask_sh_discards_buffered_output_when_either_pair_valida() {
  _bats_test_init 1058 'ask.sh discards buffered output when either pair validation fails'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_PAIR_FAIL_AT=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 1
  refute_output --partial "ANSWER from child"
  assert_output --partial "status=undelivered"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_PAIR_TERMINAL_CHANGE_AT=2 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 1
  refute_output --partial "ANSWER from child"
  assert_output --partial "output discarded"
}

function test_scripts_1059_ask_sh_reports_blocked_children_after_printing_their_an() {
  _bats_test_init 1059 'ask.sh reports blocked children after printing their answer'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENT_STATUS=blocked HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" opencode question
  assert_failure 1
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=blocked"
  assert_file_contains "$CHILD_STUB/herdr.log" '^agent read .*--source recent-unwrapped'
  assert_file_not_exists "$CHILD_STUB/parent-prompt"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_WAITING_LABEL=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" pi question --rw
  assert_failure 1
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=blocked"
  assert_file_not_exists "$CHILD_STUB/parent-prompt"
}

function test_scripts_1060_ask_sh_reports_undelivered_when_child_output_cannot_be_() {
  _bats_test_init 1060 'ask.sh reports undelivered when child output cannot be read'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_READ_FAIL=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 1
  assert_output --partial "read failed"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=undelivered"
}

function test_scripts_1061_ask_sh_reports_a_still_working_child_with_exit_124() {
  _bats_test_init 1061 'ask.sh reports a still-working child with exit 124'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_CHILD_STATUS=124 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 124
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=working"
  assert_file_not_exists "$CHILD_STUB/parent-prompt"
}

function test_scripts_1062_ask_sh_classifies_successful_waits_with_working_unknown() {
  _bats_test_init 1062 'ask.sh classifies successful waits with working, unknown, and fallback statuses'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENT_STATUS=working HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 124
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=working"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENT_STATUS=unknown HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 124
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=working"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENT_STATUS=surprised HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 1
  assert_output --partial "ANSWER from child"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=undelivered"
}

function test_scripts_1063_ask_sh_maps_child_start_failures_to_refused_or_undelive() {
  _bats_test_init 1063 'ask.sh maps child start failures to refused or undelivered'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_CHILD_STATUS=2 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" pi question
  assert_failure 2
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=refused"

  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_CHILD_STATUS=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 1
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=undelivered"
}

function test_scripts_1064_ask_sh_names_a_report_path_outside_the_checkout_in_the_de() {
  _bats_test_init 1064 'ask.sh names a report path outside the checkout in the delivered question'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude 'what is set -e'
  assert_success

  # The child is the consumer of this text: without a report path in the question it
  # has nowhere to write, and the caller silently keeps the 200-line pane scrape.
  assert_file_exists "$CHILD_STUB/prompt.txt"
  assert_file_contains "$CHILD_STUB/prompt.txt" '\[report-transport\]'
  assert_file_contains "$CHILD_STUB/prompt.txt" 'answer\.report'
  assert_file_contains "$CHILD_STUB/prompt.txt" 'what is set -e'

  report_line="$(grep -o '/[^ ]*/answer\.report' "$CHILD_STUB/prompt.txt" | head -1)"
  [ -n "$report_line" ]
  case "$report_line" in
    "$SOURCE_ROOT"*) printf 'report path is inside the checkout: %s\n' "$report_line" >&2; return 1 ;;
  esac
}

function test_scripts_1065_ask_sh_tells_a_read_only_child_to_write_the_report_throug() {
  _bats_test_init 1065 'ask.sh tells a read-only child to write the report through its shell'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_success

  # The default posture is ro, which strips Edit/Write from claude and denies edit
  # for opencode. An instruction that assumes a write tool produces no report at all.
  assert_file_contains "$CHILD_STUB/prompt.txt" 'Use your shell'
  assert_file_contains "$CHILD_STUB/prompt.txt" 'answer\.report\.tmp'
  assert_file_contains "$CHILD_STUB/prompt.txt" 'rename'
  assert_file_contains "$CHILD_STUB/prompt.txt" 'Do not use a file-editing tool'
}

function test_scripts_1066_ask_sh_removes_its_report_transport_when_it_exits() {
  _bats_test_init 1066 'ask.sh removes its report transport when it exits'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_success

  report_line="$(grep -o '/[^ ]*/answer\.report' "$CHILD_STUB/prompt.txt" | head -1)"
  [ -n "$report_line" ]
  transport_dir="$(dirname "$report_line")"
  assert_dir_not_exists "$transport_dir"
}

function test_scripts_1067_ask_sh_returns_the_transport_file_not_the_pane_text() {
  _bats_test_init 1067 'ask.sh returns the transport file, not the pane text'
  ask_live_stub
  # The stub emits a different string from `herdr agent read` than it writes to
  # the transport, so only the file can be the source of the returned answer.
  run env PATH="$CHILD_STUB:$PATH" STUB_REPORT_LINES=250 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_success
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=answered"
  assert_output --partial 'report line 1'
  assert_output --partial 'report line 250'
  refute_output --partial 'ANSWER from child'
}

function test_scripts_1068_ask_sh_reports_no_report_after_one_failed_recovery() {
  _bats_test_init 1068 'ask.sh reports no-report after one failed recovery'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_REPORT=none HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 3
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=no-report"
  # Exactly one bounded recovery attempt, and the pane text is evidence only.
  assert_file_exists "$CHILD_STUB/recover.log"
  run grep -c 'prompt' "$CHILD_STUB/recover.log"
  assert_output '1'
}

function test_scripts_1229_ask_sh_reports_refusal_when_the_recovery_scan_is_not_clean() {
  _bats_test_init 1229 'ask.sh reports refusal when the recovery scan is not clean'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_REPORT=none STUB_SCAN_FAIL_AT=2 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 2
  assert_line --index "$(( ${#lines[@]} - 1 ))" 'ask.sh: status=refused'
  assert_file_not_exists "$CHILD_STUB/recover.log"
}

function test_scripts_1069_ask_sh_returns_a_recovered_report_as_a_normal_answer() {
  _bats_test_init 1069 'ask.sh returns a recovered report as a normal answer'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_REPORT=none STUB_RECOVER=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_success
  assert_output --partial 'RECOVERED answer'
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=answered"
}

function test_scripts_1070_ask_sh_reports_an_empty_report_as_its_own_status() {
  _bats_test_init 1070 'ask.sh reports an empty report as its own status'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_REPORT=empty HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 4
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=empty-report"

  # Control: one byte at the same path reaches the success path.
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_REPORT_BODY=x HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_success
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=answered"
}

function test_scripts_1071_ask_sh_refuses_a_report_that_is_not_a_regular_file() {
  _bats_test_init 1071 'ask.sh refuses a report that is not a regular file'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_REPORT=symlink HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 5
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=bad-report"
  # The symlink target is never read.
  refute_output --partial 'localhost'
}

function test_scripts_1072_ask_sh_retains_the_transport_while_the_child_may_still_wr() {
  _bats_test_init 1072 'ask.sh retains the transport while the child may still write'
  ask_live_stub
  run env PATH="$CHILD_STUB:$PATH" STUB_REPORT=none STUB_AGENT_STATUS=working HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$ASK_HERDR_SCRIPT" claude question
  assert_failure 124
  assert_line --index "$(( ${#lines[@]} - 1 ))" "ask.sh: status=working"
  assert_output --partial 'transport retained at'

  report_line="$(grep -o '/[^ ]*/answer\.report' "$CHILD_STUB/prompt.txt" | head -1)"
  [ -n "$report_line" ]
  transport_dir="$(dirname "$report_line")"
  assert_dir_exists "$transport_dir"
  rm -f "$report_line" "$report_line.tmp"
  rmdir "$transport_dir"
}

# ===========================================

# ===========================================
# herdr-child launch and return contract
# ===========================================

HERDR_CHILD="$SOURCE_ROOT/dot_local/bin/executable_herdr-child"

child_stub_herdr() {
  export HERDR_ALIAS_TEST_SEED=tests
  child_new_stub
  cat > "$CHILD_STUB/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%q ' "$@" >> "$CHILD_STUB/calls.log"
printf '\n' >> "$CHILD_STUB/calls.log"
case "${1:-} ${2:-}" in
  "agent list")
    if [ -n "${STUB_AGENTS_JSON_FIRST:-}" ] && [ ! -f "$CHILD_STUB/list-once" ]; then
      : > "$CHILD_STUB/list-once"
      printf '%s\n' "$STUB_AGENTS_JSON_FIRST"
    elif [ -n "${STUB_AGENTS_JSON_SECOND:-}" ]; then
      printf '%s\n' "$STUB_AGENTS_JSON_SECOND"
    elif [ -n "${STUB_AGENTS_JSON:-}" ]; then printf '%s\n' "$STUB_AGENTS_JSON"
    elif [ "${STUB_START_CONTEXT:-0}" = 1 ] && [ -f "$CHILD_STUB/started-name" ]; then
      child_name="$(cat "$CHILD_STUB/started-name")"
      if [ "${STUB_CHILD_SESSION_MISSING:-0}" = 1 ]; then
        printf '{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p0","terminal_id":"term-parent","revision":1,"state_change_seq":1,"agent_session":{"value":"parent-session"}},{"name":"%s","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10}]}}\n' "$child_name"
      elif [ "${STUB_PARENT_SESSION_MISSING:-0}" = 1 ]; then
        printf '{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p0","terminal_id":"term-parent","revision":1,"state_change_seq":1},{"name":"%s","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10,"agent_session":{"value":"child-session"}}]}}\n' "$child_name"
      else
        child_session="$(cat "$CHILD_STUB/child-session" 2>/dev/null || printf child-session)"
        printf '{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p0","terminal_id":"term-parent","revision":1,"state_change_seq":1,"agent_session":{"value":"parent-session"}},{"name":"%s","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10,"agent_session":{"value":"%s"}}]}}\n' "$child_name" "$child_session"
      fi
    elif [ "${STUB_START_CONTEXT:-0}" = 1 ] && [ "${STUB_PARENT_SESSION_MISSING:-0}" = 1 ]; then
      printf '{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p0","terminal_id":"term-parent","revision":1,"state_change_seq":1}]}}\n'
    elif [ "${STUB_START_CONTEXT:-0}" = 1 ]; then
      printf '{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p0","terminal_id":"term-parent","revision":1,"state_change_seq":1,"agent_session":{"value":"parent-session"}}]}}\n'
    else
      printf '{"result":{"agents":[]}}\n'
    fi ;;
  "pane split")
    [ "${STUB_SPLIT_FAIL:-0}" = 1 ] && exit 1
    : > "$CHILD_STUB/split-seen"
    if [ "${STUB_SPLIT_NO_TERMINAL:-0}" = 1 ]; then
      printf '{"result":{"pane":{"pane_id":"wT:p9","terminal_id":""}}}\n'
    else
      printf '{"result":{"pane":{"pane_id":"wT:p9","terminal_id":"term-child"}}}\n'
    fi
    exit "${STUB_SPLIT_STATUS:-0}" ;;
  "tab create")
    [ "${STUB_TAB_CREATE_FAIL:-0}" = 1 ] && exit 1
    : > "$CHILD_STUB/split-seen"
    if [ "${STUB_TAB_CREATE_MALFORMED:-0}" = 1 ]; then
      printf '{"result":{"root_pane":{"pane_id":"","terminal_id":""},"tab":{"tab_id":"wT:tA"}}}\n'
    elif [ "${STUB_TAB_CREATE_NO_TERMINAL:-0}" = 1 ]; then
      printf '{"result":{"root_pane":{"pane_id":"wT:p9","terminal_id":""},"tab":{"tab_id":"wT:tA"}}}\n'
    else
      printf '{"result":{"root_pane":{"pane_id":"wT:p9","terminal_id":"term-child"},"tab":{"tab_id":"wT:tA"}}}\n'
    fi
    exit "${STUB_TAB_CREATE_STATUS:-0}" ;;
  "agent start")
    if [ "${STUB_REQUIRE_SPLIT:-0}" = 1 ] && [ ! -f "$CHILD_STUB/split-seen" ]; then
      printf 'agent start before pane split\n' >&2
      exit 1
    fi
    if [ "${STUB_START_MODE:-ok}" = busy-once ] && [ ! -f "$CHILD_STUB/start-once" ]; then
      : > "$CHILD_STUB/start-once"
      printf '{"error":{"code":"agent_pane_busy","message":"not an available shell"}}\n' >&2
      exit 1
    fi
    if [ "${STUB_START_MODE:-ok}" = busy ]; then
      printf '{"error":{"code":"agent_pane_busy","message":"not an available shell"}}\n' >&2
      exit 1
    fi
    if [ "${STUB_START_MODE:-ok}" = error ]; then
      printf '{"error":{"code":"timeout","message":"startup timed out"}}\n' >&2
      exit 1
    fi
    printf '%s' "${3:-child}" > "$CHILD_STUB/started-name"
    printf '{"result":{"agent":{"interactive_ready":true}}}\n' ;;
  "agent get")
    child_name="$(cat "$CHILD_STUB/started-name" 2>/dev/null || printf child)"
    printf '{"result":{"agent":{"name":"%s","pane_id":"wT:p9","terminal_id":"term-child","agent_session":{"value":"child-session"},"agent_status":"working","state_change_seq":10}}}\n' "$child_name" ;;
  "agent prompt")
    : > "$CHILD_STUB/prompt-seen"
    if [ "${STUB_PROMPT_BLOCK:-0}" = 1 ]; then
      trap 'exit 143' HUP INT TERM
      # Bounded so an orphaned stub prompt cannot poll forever after a killed
      # harness (docs/solutions/design-patterns/outliving-processes-hang-the-suite.md).
      attempt=0
      while [ ! -e "$CHILD_STUB/release-prompt" ]; do
        [ -d "$CHILD_STUB" ] || exit 1
        attempt=$((attempt + 1))
        [ "$attempt" -lt 12000 ] || exit 1
        sleep 0.01
      done
    fi
    if [ "${STUB_REQUIRE_COLD_SETTLE:-0}" = 1 ] && [ ! -f "$CHILD_STUB/cold-settled" ]; then
      printf '{"error":{"code":"agent_prompt_stalled"}}\n' >&2
      exit 1
    fi
    [ "${STUB_PROMPT_FAIL:-0}" = 1 ] && { printf '{"error":{"code":"agent_prompt_stalled"}}\n' >&2; exit 1; }
    [ "${STUB_PROMPT_TIMEOUT:-0}" = 1 ] && { printf '{"error":{"code":"timeout"}}\n' >&2; exit 1; }
    printf '{"result":{"agent":{"agent_status":"idle"}}}\n' ;;
  "pane report-metadata")
    [ "${STUB_REPORT_FAIL:-0}" = 1 ] && exit 1
    if printf '%s\n' "$*" | grep -q 'supervised'; then
      if [ "${STUB_SUPERVISION_REPORT_BLOCK:-0}" = 1 ]; then
        : > "$CHILD_STUB/liveness-started"
        trap 'exit 143' HUP INT TERM
        # Bounded so an orphaned stub cannot poll forever after a killed
        # harness (docs/solutions/design-patterns/outliving-processes-hang-the-suite.md).
        attempt=0
        while [ ! -e "$CHILD_STUB/release-liveness" ]; do
          [ -d "$CHILD_STUB" ] || exit 1
          attempt=$((attempt + 1))
          [ "$attempt" -lt 12000 ] || exit 1
          sleep 0.01
        done
      fi
      [ "${STUB_SUPERVISION_REPORT_FAIL:-0}" != 1 ] || exit 1
    fi
    for arg in "$@"; do
      case "$arg" in
        supervision_generation=*) printf '%s\n' "${arg#*=}" > "$CHILD_STUB/generation" ;;
      esac
    done
    if printf '%s\n' "$*" | grep -q 'supervised=' && [ -f "$CHILD_STUB/fail-supervision-report" ]; then
      exit 1
    fi
    printf '{"result":{"type":"pane_metadata_reported"}}\n' ;;
  "pane get")
    if [ "${STUB_PANE_GET_MALFORMED:-0}" = 1 ]; then
      printf 'not json\n'
    elif [ "${STUB_LABEL:-0}" = 1 ]; then
      printf '{"result":{"pane":{"pane_id":"%s","terminal_id":"term-child","state_labels":{"blocked":"waiting for parent"}}}}\n' "${3:-wT:p9}"
    elif [ -n "${STUB_PANE_TAB_ID:-}" ]; then
      printf '{"result":{"pane":{"pane_id":"%s","terminal_id":"term-child","tab_id":"%s","tokens":{"child-tab":"%s"}}}}\n' \
        "${3:-wT:p9}" "$STUB_PANE_TAB_ID" "${STUB_PANE_CHILD_TAB_TOKEN:-$STUB_PANE_TAB_ID}"
    elif [ -f "$CHILD_STUB/generation" ]; then
      generation="$(cat "$CHILD_STUB/generation")"
      printf '{"result":{"pane":{"pane_id":"wT:p9","terminal_id":"term-child","agent_session":{"value":"child-session"},"tokens":{"supervision_generation":"%s"}}}}\n' "$generation"
    else
      printf '{"result":{"pane":{"pane_id":"%s","terminal_id":"term-child"}}}\n' "${3:-wT:p9}"
    fi ;;
  "pane close")
    [ "${STUB_CLOSE_NOT_FOUND:-0}" = 1 ] && { printf '{"error":{"code":"pane_not_found","message":"pane not found"}}\n' >&2; exit 1; }
    exit "${STUB_CLOSE_STATUS:-0}" ;;
  "tab get")
    [ "${STUB_TAB_GET_FAIL:-0}" = 1 ] && { printf '{"error":{"code":"tab_not_found","message":"tab not found"}}\n' >&2; exit 1; }
    [ "${STUB_TAB_GET_TRANSIENT:-0}" = 1 ] && { printf '{"error":{"code":"internal_error","message":"transient failure"}}\n' >&2; exit 1; }
    printf '{"result":{"tab":{"pane_count":%s}}}\n' "${STUB_TAB_PANE_COUNT:-1}" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$CHILD_STUB/herdr"
  cat > "$CHILD_STUB/herdr-resource-tree" <<'SH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$CHILD_STUB/resource-tree.log"
printf '\n' >> "$CHILD_STUB/resource-tree.log"
[ "${STUB_PARENTAGE_FAIL:-0}" != 1 ] || {
  printf 'injected parentage failure\n' >&2
  exit 75
}
printf '{"parent":{"presentation_name":"parent"},"child":{"presentation_name":"child"}}\n'
SH
  chmod +x "$CHILD_STUB/herdr-resource-tree"
  cat > "$CHILD_STUB/ps" <<'SH'
#!/usr/bin/env bash
if [ -f "$CHILD_STUB/fail-ps" ]; then
  exit 1
fi
if [ -f "$CHILD_STUB/observe-ps-locale" ]; then
  printf '%s\n' "${LC_ALL:-unset}" >> "$CHILD_STUB/ps-locales.log"
fi
exec /bin/ps "$@"
SH
  chmod +x "$CHILD_STUB/ps"
}

child_start() {
  # The pane-busy tests assert how many start attempts happen, never how far
  # apart they are, so the shipped one-second spacing is pure scaffolding here.
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    STUB_START_CONTEXT=1 \
    HERDR_CHILD_PANE_BUSY_RETRY_DELAY=0.01 \
    HERDR_CHILD_COLD_INITIAL_PROMPT_DELAY="${HERDR_CHILD_COLD_INITIAL_PROMPT_DELAY:-0}" \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_TEST_WATCHER_RELEASE="$CHILD_STUB/release-watcher" \
    bash "$HERDR_CHILD" start "$@" --prompt "test task"
}

child_start_with_default_initial_delay() {
  env -u HERDR_CHILD_COLD_INITIAL_PROMPT_DELAY PATH="$CHILD_STUB:$PATH" \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 STUB_START_CONTEXT=1 \
    HERDR_CHILD_PANE_BUSY_RETRY_DELAY=0.01 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_TEST_WATCHER_RELEASE="$CHILD_STUB/release-watcher" \
    bash "$HERDR_CHILD" start "$@" --prompt "test task"
}

child_started_name() {
  cat "$CHILD_STUB/started-name"
}

child_lifecycle_stub_herdr() {
  child_stub_herdr
  printf 'working 10\n' > "$CHILD_STUB/baseline-state"
  printf 'working 10\n' > "$CHILD_STUB/child-state"
  printf 'wT:p0\n' > "$CHILD_STUB/parent-pane"
  printf 'parent-session\n' > "$CHILD_STUB/parent-session"
  printf 'term-child\n' > "$CHILD_STUB/child-terminal"
  printf 'child-session\n' > "$CHILD_STUB/child-session"
  cat > "$CHILD_STUB/herdr" <<'SH'
#!/usr/bin/env bash
set -u

printf '%q ' "$@" >> "$CHILD_STUB/calls.log"
printf '\n' >> "$CHILD_STUB/calls.log"

read_value() {
  local file="$1" fallback="$2" value
  value="$(cat "$CHILD_STUB/$file" 2>/dev/null || true)"
  printf '%s' "${value:-$fallback}"
}

agent_json() {
  local name="$1" pane="$2" terminal="$3" session="$4" status="$5" seq="$6"
  printf '{"name":"%s","agent":"claude","pane_id":"%s","terminal_id":"%s","revision":1,"agent_session":{"value":"%s"},"agent_status":"%s","state_change_seq":%s,"focused":false}' \
    "$name" "$pane" "$terminal" "$session" "$status" "$seq"
}

case "${1:-} ${2:-}" in
  "agent list")
    parent_pane="$(read_value parent-pane 'wT:p0')"
    parent_session="$(read_value parent-session parent-session)"
    parent_status="$(read_value parent-status working)"
    if [ "$parent_status" = blocked ] && [ -f "$CHILD_STUB/generation" ]; then
      : > "$CHILD_STUB/parent-blocked-observed"
    fi
    parent="$(agent_json parent "$parent_pane" term-parent "$parent_session" "$parent_status" 1)"
    if [ -f "$CHILD_STUB/started-name" ] && [ ! -f "$CHILD_STUB/child-gone" ]; then
      child_name="$(cat "$CHILD_STUB/started-name")"
      child_terminal="$(read_value child-terminal term-child)"
      child_session="$(read_value child-session child-session)"
      read -r child_status child_seq < "$CHILD_STUB/child-state"
      child_status="$(read_value child-list-status "$child_status")"
      child="$(agent_json "$child_name" wT:p9 "$child_terminal" "$child_session" "$child_status" "$child_seq")"
      printf '{"result":{"agents":[%s,%s]}}\n' "$parent" "$child"
    else
      printf '{"result":{"agents":[%s]}}\n' "$parent"
    fi
    ;;
  "pane split")
    printf '{"result":{"pane":{"pane_id":"wT:p9","terminal_id":"term-child"}}}\n'
    ;;
  "tab create")
    printf '{"result":{"root_pane":{"pane_id":"wT:p9","terminal_id":"term-child"},"tab":{"tab_id":"wT:tA"}}}\n'
    ;;
  "agent start")
    printf '%s' "${3:-child}" > "$CHILD_STUB/started-name"
    printf '{"result":{"agent":{"interactive_ready":true}}}\n'
    ;;
  "agent get")
    count="$(read_value get-count 0)"
    count=$((count + 1))
    printf '%s\n' "$count" > "$CHILD_STUB/get-count"
    if [ "$count" -gt 1 ] && [ -f "$CHILD_STUB/child-gone" ]; then
      printf '{"error":{"code":"agent_not_found"}}\n' >&2
      exit 1
    fi
    if [ "$count" -gt 1 ] && [ -f "$CHILD_STUB/malformed-state" ]; then
      printf 'not-json\n'
      exit 0
    fi
    state_file=baseline-state
    [ "$count" -eq 1 ] || state_file=child-state
    read -r child_status child_seq < "$CHILD_STUB/$state_file"
    if [ "$count" -gt 1 ] && [ -f "$CHILD_STUB/block-agent-get" ]; then
      : > "$CHILD_STUB/agent-get.ready"
      attempt=0
      while [ ! -f "$CHILD_STUB/agent-get.release" ]; do
        [ -d "$CHILD_STUB" ] || exit 1
        attempt=$((attempt + 1))
        [ "$attempt" -lt 12000 ] || exit 1
        sleep 0.01
      done
    fi
    child_name="$(read_value started-name child)"
    child_terminal="$(read_value child-terminal term-child)"
    child_session="$(read_value child-session child-session)"
    child="$(agent_json "$child_name" wT:p9 "$child_terminal" "$child_session" "$child_status" "$child_seq")"
    if [ "$child_status" = working ] && [ "$child_seq" -gt 10 ]; then
      : > "$CHILD_STUB/fresh-working-observed"
    elif [ "$child_status" = blocked ]; then
      : > "$CHILD_STUB/blocked-observed"
    elif [ "$child_seq" -gt 10 ]; then
      : > "$CHILD_STUB/settlement-observed"
    fi
    printf '{"result":{"agent":%s}}\n' "$child"
    ;;
  "agent wait")
    : > "$CHILD_STUB/wait-observed"
    if [ -f "$CHILD_STUB/wait-block" ]; then
      # Bounded so an orphaned stub cannot poll forever after a killed
      # harness (docs/solutions/design-patterns/outliving-processes-hang-the-suite.md).
      attempt=0
      while [ ! -f "$CHILD_STUB/wait-release" ]; do
        [ -d "$CHILD_STUB" ] || exit 1
        attempt=$((attempt + 1))
        [ "$attempt" -lt 12000 ] || exit 1
        sleep 0.01
      done
    fi
    if [ -f "$CHILD_STUB/wait-error" ]; then
      printf '{"error":{"code":"internal_error","message":"transient wait failure"}}\n' >&2
      exit 1
    fi
    read -r child_status _ < "$CHILD_STUB/child-state"
    case "$child_status" in
      idle|done|blocked) printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$child_status" ;;
      *) printf '{"error":{"code":"timeout","message":"wait timed out"}}\n'; exit 1 ;;
    esac
    ;;
  "agent prompt")
    target="${3:-}"
    if [[ "$target" == wT:* ]]; then
      if [ -f "$CHILD_STUB/prompt-fail-count" ]; then
        failures="$(cat "$CHILD_STUB/prompt-fail-count")"
        if [ "$failures" -gt 0 ]; then
          printf '%s\n' $((failures - 1)) > "$CHILD_STUB/prompt-fail-count"
          printf '{"error":{"code":"transport_error"}}\n' >&2
          exit 1
        fi
      fi
      if [ -f "$CHILD_STUB/block-parent-prompt" ]; then
        : > "$CHILD_STUB/parent-prompt-accepted"
        # Bounded so an orphaned stub cannot poll forever after a killed
        # harness (docs/solutions/design-patterns/outliving-processes-hang-the-suite.md).
        attempt=0
        while [ ! -f "$CHILD_STUB/release-parent-prompt" ]; do
          [ -d "$CHILD_STUB" ] || exit 1
          attempt=$((attempt + 1))
          [ "$attempt" -lt 12000 ] || exit 1
          sleep 0.01
        done
      fi
      printf '%s\n' "${4:-}" >> "$CHILD_STUB/successful-prompts.log"
    elif [ -f "$CHILD_STUB/advance-on-prompt" ]; then
      printf 'idle 12\n' > "$CHILD_STUB/child-state"
    fi
    printf '{"result":{"agent":{"agent_status":"working"}}}\n'
    ;;
  "pane report-metadata")
    clear_labels=0
    waiting_label=0
    clear_next=0
    seq_next=0
    seq_value=
    for arg in "$@"; do
      if [ "$seq_next" -eq 1 ]; then
        seq_value="$arg"
        seq_next=0
        continue
      fi
      [ "$arg" != --seq ] || seq_next=1
    done
    if [ -n "$seq_value" ] && [ -f "$CHILD_STUB/metadata-seq" ] && \
       [ "$seq_value" -le "$(cat "$CHILD_STUB/metadata-seq")" ]; then
      printf '{"result":{"type":"pane_metadata_reported"}}\n'
      exit 0
    fi
    [ -z "$seq_value" ] || printf '%s\n' "$seq_value" > "$CHILD_STUB/metadata-seq"
    for arg in "$@"; do
      if [ "$clear_next" -eq 1 ]; then
        case "$arg" in
          supervision_generation)
            rm -f "$CHILD_STUB/generation"
            : > "$CHILD_STUB/generation-invalidated"
            ;;
          supervision_failure_reason) rm -f "$CHILD_STUB/failure-reason" ;;
          supervision_failure_generation) rm -f "$CHILD_STUB/failure-generation" ;;
          supervision_failure_diagnostic) rm -f "$CHILD_STUB/failure-diagnostic" ;;
        esac
        clear_next=0
        continue
      fi
      [ "$arg" != --clear-token ] || { clear_next=1; continue; }
      case "$arg" in
        supervision_generation=*) printf '%s\n' "${arg#*=}" > "$CHILD_STUB/generation" ;;
        supervision_failure_reason=*) printf '%s\n' "${arg#*=}" > "$CHILD_STUB/failure-reason" ;;
        supervision_failure_generation=*) printf '%s\n' "${arg#*=}" > "$CHILD_STUB/failure-generation" ;;
        supervision_failure_diagnostic=*) printf '%s\n' "${arg#*=}" > "$CHILD_STUB/failure-diagnostic" ;;
        child-tab=*) printf '%s\n' "${arg#*=}" > "$CHILD_STUB/child-tab" ;;
        --clear-state-labels) clear_labels=1 ;;
        blocked=waiting\ for\ parent) waiting_label=1 ;;
        supervision\ failed=*) : > "$CHILD_STUB/failure-label" ;;
      esac
    done
    [ "$clear_labels" -eq 0 ] || rm -f "$CHILD_STUB/waiting-label" "$CHILD_STUB/failure-label"
    [ "$waiting_label" -eq 0 ] || : > "$CHILD_STUB/waiting-label"
    printf '{"result":{"type":"pane_metadata_reported"}}\n'
    ;;
  "pane get")
    if [ -f "$CHILD_STUB/block-delivery-pane-get" ] && \
       [ -f "$CHILD_STUB/settlement-observed" ] && \
       [ ! -f "$CHILD_STUB/delivery-pane-get.ready" ]; then
      : > "$CHILD_STUB/delivery-pane-get.ready"
      attempt=0
      while [ ! -f "$CHILD_STUB/delivery-pane-get.release" ]; do
        [ -d "$CHILD_STUB" ] || exit 1
        attempt=$((attempt + 1))
        [ "$attempt" -lt 12000 ] || exit 1
        sleep 0.01
      done
    fi
    if [ -f "$CHILD_STUB/observe-reap-invalidation" ] && \
       [ -f "$CHILD_STUB/pane-close.ready" ]; then
      for run_dir in "$HERDR_CHILD_STATE_DIR"/runs/*; do
        [ ! -f "$run_dir/invalidated.state" ] || : > "$CHILD_STUB/reap-invalidation-consumed"
      done
      if [ -f "$CHILD_STUB/block-reap-pane-get" ]; then
        : > "$CHILD_STUB/reap-pane-get.ready"
        attempt=0
        while [ ! -f "$CHILD_STUB/reap-pane-get.release" ]; do
          [ -d "$CHILD_STUB" ] || exit 1
          attempt=$((attempt + 1))
          [ "$attempt" -lt 12000 ] || exit 1
          sleep 0.01
        done
      fi
    fi
    if [ -f "$CHILD_STUB/child-gone" ]; then
      printf '{"error":{"code":"pane_not_found","message":"pane not found"}}\n' >&2
      exit 1
    fi
    if [ -f "$CHILD_STUB/pane-get-transient-next" ]; then
      rm -f "$CHILD_STUB/pane-get-transient-next"
      : > "$CHILD_STUB/pane-get-transient-observed"
      printf '{"error":{"code":"internal_error","message":"transient pane read"}}\n' >&2
      exit 1
    fi
    if [ -f "$CHILD_STUB/pane-get-outage" ] && [ -f "$CHILD_STUB/settlement-observed" ]; then
      # A herdr transport outage that starts at the first read after settlement,
      # so the delivery-time revalidation read fails first and the poll reads
      # that follow keep failing for the requested number of reads.
      remaining="$(cat "$CHILD_STUB/pane-get-outage")"
      if [ "$remaining" -gt 0 ]; then
        printf '%s\n' "$((remaining - 1))" > "$CHILD_STUB/pane-get-outage"
        printf '{"error":{"code":"internal_error","message":"pane read outage"}}\n' >&2
        exit 1
      fi
    fi
    if [ -f "$CHILD_STUB/pane-transient-after-settlement" ] && \
       [ -f "$CHILD_STUB/settlement-observed" ] && \
       [ ! -f "$CHILD_STUB/pane-get-transient-observed" ]; then
      : > "$CHILD_STUB/pane-get-transient-observed"
      printf '{"error":{"code":"internal_error","message":"transient pane read"}}\n' >&2
      exit 1
    fi
    if [ -f "$CHILD_STUB/pane-malformed" ]; then
      printf 'not-json\n'
      exit 0
    fi
    child_terminal="$(read_value child-terminal term-child)"
    child_session="$(read_value child-session child-session)"
    generation="$(read_value generation '')"
    child_tab="$(read_value child-tab '')"
    tab_token=""
    tab_field=""
    if [ -n "$child_tab" ]; then
      tab_token=",\"child-tab\":\"$child_tab\""
      tab_field=",\"tab_id\":\"$child_tab\""
    fi
    if [ -n "$generation" ]; then
      tokens="{\"child_mode\":\"detach\",\"supervision_generation\":\"$generation\",\"supervision_timeout\":\"5000\",\"parent_terminal\":\"term-parent\",\"parent_session\":\"parent-session\",\"child_terminal\":\"term-child\",\"child_session\":\"child-session\"$tab_token}"
    elif [ -n "$child_tab" ]; then
      tokens="{\"child-tab\":\"$child_tab\"}"
    else
      tokens='{}'
    fi
    labels='{}'
    [ ! -f "$CHILD_STUB/waiting-label" ] || labels='{"blocked":"waiting for parent"}'
    printf '{"result":{"pane":{"pane_id":"wT:p9","terminal_id":"%s","agent_session":{"value":"%s"},"tokens":%s,"state_labels":%s%s}}}\n' \
      "$child_terminal" "$child_session" "$tokens" "$labels" "$tab_field"
    ;;
  "pane close")
    if [ -f "$CHILD_STUB/require-reap-invalidation" ]; then
      invalidation_found=0
      for run_dir in "$HERDR_CHILD_STATE_DIR"/runs/*; do
        [ ! -f "$run_dir/invalidated.state" ] || invalidation_found=1
      done
      if [ "$invalidation_found" -eq 1 ]; then
        : > "$CHILD_STUB/reap-invalidation-observed"
      else
        : > "$CHILD_STUB/close-before-invalidation"
      fi
    fi
    if [ -f "$CHILD_STUB/block-pane-close" ]; then
      : > "$CHILD_STUB/pane-close.ready"
      attempt=0
      while [ ! -f "$CHILD_STUB/pane-close.release" ]; do
        [ -d "$CHILD_STUB" ] || exit 1
        attempt=$((attempt + 1))
        [ "$attempt" -lt 12000 ] || exit 1
        sleep 0.01
      done
    fi
    if [ -f "$CHILD_STUB/close-fail" ]; then
      printf '{"error":{"code":"internal_error","message":"close failed"}}\n' >&2
      exit 1
    fi
    : > "$CHILD_STUB/pane-closed"
    ;;
  "tab get")
    if [ -f "$CHILD_STUB/pane-closed" ]; then
      printf '{"error":{"code":"tab_not_found","message":"tab not found"}}\n' >&2
      exit 1
    fi
    printf '{"result":{"tab":{"pane_count":1}}}\n'
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$CHILD_STUB/herdr"
}

child_lifecycle_start() {
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_REAP_OWNER_VERIFIED="${HERDR_CHILD_TEST_REAP_OWNER_VERIFIED:-}" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_POLL_INTERVAL=0.01 HERDR_CHILD_TEST_SKIP_RETRY_SLEEP=1 \
    bash "$HERDR_CHILD" start --kind claude --detach \
    --prompt "test task" "$@"
}

child_wait_for_log() {
  local pattern="$1" file="${2:-$CHILD_STUB/calls.log}" attempt=0
  while [ "$attempt" -lt 500 ]; do
    grep -q -- "$pattern" "$file" 2>/dev/null && return 0
    attempt=$((attempt + 1))
    sleep 0.01
  done
  printf 'pattern not observed: %s\n' "$pattern" >&2
  cat "$file" >&2
  return 1
}

child_wait_for_get_count() {
  local wanted="$1" attempt=0 count
  while [ "$attempt" -lt 500 ]; do
    count="$(cat "$CHILD_STUB/get-count" 2>/dev/null || printf 0)"
    [ "$count" -lt "$wanted" ] || return 0
    attempt=$((attempt + 1))
    sleep 0.01
  done
  return 1
}

child_wait_for_file() {
  local file="$1" attempt=0
  while [ "$attempt" -lt 500 ]; do
    [ ! -e "$file" ] || return 0
    attempt=$((attempt + 1))
    sleep 0.01
  done
  printf 'file not observed: %s\n' "$file" >&2
  return 1
}

function test_scripts_021_herdr_child_requires_a_subcommand_and_herdr_envi() {
  _bats_test_init 21 'herdr-child requires a subcommand and herdr environment'
  run bash "$HERDR_CHILD"
  assert_failure 2
  assert_output --partial "Usage:"

  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV= HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" start --kind claude --wait --prompt task
  assert_failure
  [ ! -f "$CHILD_STUB/calls.log" ]
}

function test_scripts_022_herdr_child_refuses_pi_read_only_before_splittin() {
  _bats_test_init 22 'herdr-child refuses pi read-only before splitting a pane'
  child_stub_herdr
  run child_start --kind pi --posture ro --wait
  assert_failure 2
  assert_output --partial "return channel requires bash"
  [ ! -f "$CHILD_STUB/calls.log" ]
}

function test_scripts_023_herdr_child_start_requires_exactly_one_explicit() {
  _bats_test_init 23 'herdr-child start requires exactly one explicit mode before Herdr mutation'
  child_stub_herdr

  run child_start --kind claude
  assert_failure 2
  assert_output --partial "exactly one of --wait or --detach"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --wait --detach
  assert_failure 2
  assert_output --partial "exactly one of --wait or --detach"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --wait --wait
  assert_failure 2
  assert_output --partial "mode flag may be specified only once"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --detach --detach
  assert_failure 2
  assert_output --partial "mode flag may be specified only once"
  assert_file_not_exists "$CHILD_STUB/calls.log"
}

function test_scripts_27203_herdr_child_refuses_to_start_inside_an_external_leg() {
  _bats_test_init 27203 'herdr-child refuses to start a child inside an External leg before Herdr mutation'
  child_stub_herdr

  SE_EXTERNAL_LEG=1 run child_start --kind claude --wait --timeout 5000
  assert_failure 2
  assert_output --partial "inside an external leg"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  SE_EXTERNAL_LEG= STUB_REQUIRE_SPLIT=1 run child_start --kind claude --wait --timeout 5000
  assert_success
  assert_file_exists "$CHILD_STUB/calls.log"
}

function test_scripts_024_herdr_child_validates_tab_placement_before_herdr() {
  _bats_test_init 24 'herdr-child validates tab placement before Herdr mutation'
  child_stub_herdr

  HERDR_WORKSPACE_ID=w1 run child_start --kind claude --tab --direction right --wait
  assert_failure 2
  assert_output --partial "--tab cannot be combined with --direction"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --label mylabel --wait
  assert_failure 2
  assert_output --partial "--label is only valid with --tab"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --tab --wait
  assert_failure 2
  assert_output --partial "--tab requires HERDR_WORKSPACE_ID"
  assert_file_not_exists "$CHILD_STUB/calls.log"
}

function test_scripts_025_herdr_child_validates_launch_and_supervision_tim() {
  _bats_test_init 25 'herdr-child validates launch and supervision timeouts before Herdr mutation'
  child_stub_herdr

  run child_start --kind claude --wait --timeout 0
  assert_failure 2
  assert_output --partial "--timeout must be a positive integer"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --wait --supervision-timeout 10
  assert_failure 2
  assert_output --partial "--supervision-timeout requires --detach"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  run child_start --kind claude --wait --supervision-timeout 3600000
  assert_failure 2
  assert_output --partial "--supervision-timeout requires --detach"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  local value
  for value in 0 86400001 malformed; do
    run child_start --kind claude --detach --supervision-timeout "$value"
    assert_failure 2
    assert_output --partial "--supervision-timeout must be between 1 and 86400000 milliseconds"
    assert_file_not_exists "$CHILD_STUB/calls.log"
  done

  for value in -1 malformed 31; do
    HERDR_CHILD_COLD_INITIAL_PROMPT_DELAY="$value" run child_start --kind claude --wait
    assert_failure 2
    assert_output --partial "HERDR_CHILD_COLD_INITIAL_PROMPT_DELAY must be between 0 and 30 seconds"
    assert_file_not_exists "$CHILD_STUB/calls.log"
  done

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" start --kind claude --detach \
    --prompt "test task" --supervision-timeout
  assert_failure 2
  assert_output --partial "--supervision-timeout needs a value"
  assert_file_not_exists "$CHILD_STUB/calls.log"

  HERDR_CHILD_COLD_INITIAL_PROMPT_DELAY=30 run child_start --kind claude --wait
  assert_success
}

function test_scripts_026_herdr_child_attached_mode_starts_no_watcher() {
  _bats_test_init 26 'herdr-child attached mode starts no watcher'
  child_stub_herdr
  run child_start --kind claude --wait
  assert_success
  assert_output "{\"agent\":\"$(child_started_name)\",\"pane\":\"wT:p9\"}"
  assert_file_not_exists "$CHILD_STUB/watcher.pid"
  assert_file_contains "$CHILD_STUB/calls.log" 'pane split.*HERDR_CHILD_LAUNCH_MODE=wait'
  assert_file_contains "$CHILD_STUB/calls.log" 'pane split.*HERDR_CHILD_PARENT_TERMINAL=term-parent'
  assert_file_contains "$CHILD_STUB/calls.log" 'pane split.*HERDR_CHILD_PARENT_SESSION=parent-session'
  assert_file_contains "$CHILD_STUB/resource-tree.log" '^record-child --pane wT:p9 --terminal term-child'
  run grep -q 'supervised' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_1240_herdr_child_preserves_a_verified_child_when_parentage_recording_fails() {
  _bats_test_init 1240 'herdr-child preserves a verified child when parentage recording fails'
  child_stub_herdr

  STUB_PARENTAGE_FAIL=1 run child_start --kind claude --wait
  assert_failure 75
  assert_output --partial 'injected parentage failure'
  assert_output --partial 'parentage recording failed after Agent start'
  assert_output --partial 'child preserved'
  assert_output --partial 'automatic launch retry is unsafe'
  assert_output --partial "\"agent\":\"$(child_started_name)\",\"pane\":\"wT:p9\""
  assert_file_contains "$CHILD_STUB/resource-tree.log" '^record-child --pane wT:p9 --terminal term-child'
  run grep -Eq '^(pane close|agent prompt)' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_1241_herdr_child_preserves_a_wrapper_partial_success_without_retrying() {
  _bats_test_init 1241 'herdr-child preserves a wrapper partial success without retrying'
  child_stub_herdr

  STUB_SPLIT_STATUS=70 run child_start --kind claude --wait
  assert_failure 70
  assert_output --partial '"pane_id":"wT:p9"'
  assert_output --partial 'pane creation returned status 70 after reporting pane wT:p9'
  assert_output --partial 'automatic creation retry is unsafe'
  run grep -Ec '^(pane split|agent start|pane close)' "$CHILD_STUB/calls.log"
  assert_success
  assert_output '1'
  assert_file_not_exists "$CHILD_STUB/resource-tree.log"
}

function test_scripts_027_herdr_child_detached_mode_fails_closed_without_a() {
  _bats_test_init 27 'herdr-child detached mode fails closed without a parent session'
  child_stub_herdr
  STUB_PARENT_SESSION_MISSING=1 run child_start --kind claude --detach
  assert_failure
  assert_output --partial "parent agent_session is unavailable"
  assert_file_contains "$CHILD_STUB/calls.log" '^agent list'
  run grep -Eq '^(pane split|agent start|agent prompt|pane report-metadata)' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_1242_herdr_child_attached_mode_keeps_unknown_parent_launches_usable() {
  _bats_test_init 1242 'herdr-child attached mode keeps unknown-parent launches usable'
  child_stub_herdr

  STUB_PARENT_SESSION_MISSING=1 run child_start --kind claude --wait
  assert_success
  assert_output --partial '"pane":"wT:p9"'
  assert_file_not_exists "$CHILD_STUB/resource-tree.log"
}

child_deployed_tree() {
  # A deployed layout: the provenance wrapper sits beside herdr-child, and a
  # different herdr comes first on PATH. Only a wrapper reached by path can
  # record the creator edge record-child later requires.
  local root="$CHILD_STUB/deployed"
  mkdir -p "$root/bin"
  ln -sf "$SOURCE_ROOT/dot_local/lib" "$root/lib"
  cp "$HERDR_CHILD" "$root/bin/herdr-child"
  chmod +x "$root/bin/herdr-child"
  cat > "$root/bin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CHILD_STUB/wrapper.log"
exec "$CHILD_STUB/herdr" "$@"
SH
  chmod +x "$root/bin/herdr"
  printf '%s\n' "$root/bin/herdr-child"
}

function test_scripts_1244_herdr_child_creates_through_the_wrapper_beside_it() {
  _bats_test_init 1244 'herdr-child creates through the wrapper beside it, not through PATH'
  child_stub_herdr
  local deployed
  deployed="$(child_deployed_tree)"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    STUB_START_CONTEXT=1 HERDR_CHILD_PANE_BUSY_RETRY_DELAY=0.01 \
    HERDR_CHILD_COLD_INITIAL_PROMPT_DELAY=0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_TEST_WATCHER_RELEASE="$CHILD_STUB/release-watcher" \
    bash "$deployed" start --kind claude --wait --prompt "test task"
  assert_success

  # The creation reached the sibling wrapper even though PATH resolves a
  # different herdr first.
  assert_file_contains "$CHILD_STUB/wrapper.log" '^pane split'

  # Reads stay off the wrapper: interception is only needed for creation, and
  # routing every call through it would pay its startup cost on each poll.
  run grep -q '^agent list' "$CHILD_STUB/wrapper.log"
  assert_failure
  assert_file_contains "$CHILD_STUB/calls.log" '^agent list'
}

function test_scripts_1245_herdr_child_attached_mode_keeps_unknown_child_session_launches_usable() {
  _bats_test_init 1245 'herdr-child attached mode keeps unknown-child-session launches usable'
  child_stub_herdr

  # Herdr may observe the child before supplying its optional conversation
  # identity. Attached mode records no edge rather than failing a live child.
  STUB_CHILD_SESSION_MISSING=1 run child_start --kind claude --wait
  assert_success
  assert_output --partial '"pane":"wT:p9"'
  assert_file_contains "$CHILD_STUB/calls.log" '^agent prompt'
  assert_file_not_exists "$CHILD_STUB/resource-tree.log"
}

function test_scripts_1246_herdr_child_replays_an_unparseable_partial_creation_response() {
  _bats_test_init 1246 'herdr-child replays a partial creation response it cannot parse'
  child_stub_herdr

  # The wrapper exits nonzero after Herdr created the pane, and the response is
  # too partial to yield an identity. The surviving coordinates only reach the
  # caller if the native result is replayed before parsing.
  STUB_SPLIT_NO_TERMINAL=1 STUB_SPLIT_STATUS=70 run child_start --kind claude --wait
  assert_failure 70
  assert_output --partial '"pane_id":"wT:p9"'
  assert_output --partial 'pane split failed'
  run grep -Eq '^(agent start|pane close)' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_028_herdr_child_detached_mode_closes_only_its_new_pa() {
  _bats_test_init 28 'herdr-child detached mode closes only its new pane without a child session'
  child_stub_herdr
  STUB_CHILD_SESSION_MISSING=1 run child_start --kind claude --detach
  assert_failure
  assert_output --partial "child agent_session is unavailable"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
  run grep -q '^agent prompt' "$CHILD_STUB/calls.log"
  assert_failure
  assert_file_not_exists "$CHILD_STUB/watcher.pid"
}

function test_scripts_029_herdr_child_detached_mode_returns_only_after_liv() {
  _bats_test_init 29 'herdr-child detached mode returns only after liveness and causal watcher arming'
  child_stub_herdr
  run child_start --kind claude --detach --supervision-timeout 60000
  assert_success
  assert_output --partial "\"agent\":\"$(child_started_name)\""
  assert_output --partial '"supervision":{"status":"armed"'
  assert_output --partial '"timeout_ms":60000'
  assert_file_exists "$CHILD_STUB/watcher.pid"
  local generation
  generation="$(cat "$CHILD_STUB/generation")"
  run cat "$CHILD_STUB/state/runs/$generation/launch.state"
  assert_success
  assert_output "$(printf '%s\n' 'mode=detach' "generation=$generation" 'timeout_ms=60000' \
    'parent_pane=wT:p0' 'parent_terminal=term-parent' 'parent_session=parent-session' \
    "child_name=$(child_started_name)" 'child_pane=wT:p9' 'child_terminal=term-child' \
    'child_session=child-session' 'baseline_seq=10')"

  local metadata_call prompt_call
  metadata_call="$(grep -n 'token supervised=' "$CHILD_STUB/calls.log" | cut -d: -f1)"
  prompt_call="$(grep -n '^agent prompt' "$CHILD_STUB/calls.log" | cut -d: -f1)"
  [ -n "$metadata_call" ]
  [ "$metadata_call" -lt "$prompt_call" ]
  assert_file_contains "$CHILD_STUB/calls.log" 'pane report-metadata.*--token child_mode=detach'
  assert_file_contains "$CHILD_STUB/calls.log" 'pane report-metadata.*--token parent_session=parent-session'
  assert_file_contains "$CHILD_STUB/calls.log" 'pane report-metadata.*--token child_session=child-session'
}

function test_scripts_030_herdr_child_detached_arm_failure_preserves_the_c() {
  _bats_test_init 30 'herdr-child detached arm failure preserves the child and returns recovery JSON'
  child_stub_herdr
  HERDR_CHILD_TEST_ARM_FAIL=1 run child_start --kind claude --detach
  assert_failure
  assert_output --partial "\"agent\":\"$(child_started_name)\",\"pane\":\"wT:p9\""
  assert_output --partial '"supervision":{"status":"failed","reason":"watcher-arm-failed"'
  assert_file_contains "$CHILD_STUB/calls.log" '^agent prompt'
  assert_file_contains "$CHILD_STUB/calls.log" 'token supervision_failure_reason=watcher-arm-failed'
  set -- "$CHILD_STUB/state/runs/"*
  [ "$#" -eq 1 ]
  assert_file_exists "$1/failed.state"
  assert_file_permission 700 "$1"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_031_herdr_child_signal_before_prompt_submission_clos() {
  _bats_test_init 31 'herdr-child signal before prompt submission closes owned state and pane'
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 STUB_START_CONTEXT=1 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    STUB_SUPERVISION_REPORT_BLOCK=1 CHILD_SCRIPT="$HERDR_CHILD" python3 - <<'PY'
import os
from pathlib import Path
import select
import signal
import subprocess
import time

stub = Path(os.environ["CHILD_STUB"])
proc = subprocess.Popen(
    ["bash", os.environ["CHILD_SCRIPT"], "start", "--kind", "claude", "--detach", "--prompt", "test task"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=os.environ.copy(),
)
for _ in range(1000):
    if (stub / "liveness-started").exists():
        break
    time.sleep(0.01)
else:
    proc.kill()
    raise AssertionError("watcher never reached its pre-submission liveness boundary")

watcher_pid = int((stub / "watcher.pid").read_text().strip())
proc.send_signal(signal.SIGTERM)
stdout, stderr = proc.communicate(timeout=10)
if proc.returncode == 0:
    raise AssertionError("signaled launcher returned success")
if stdout:
    raise AssertionError("pre-submission signal returned a detached success or recovery record")
calls = (stub / "calls.log").read_text()
if "pane close wT:p9" not in calls or "agent prompt" in calls:
    raise AssertionError("pre-submission signal did not close only the owned pane: %s" % calls)
for _ in range(1000):
    try:
        os.kill(watcher_pid, 0)
    except ProcessLookupError:
        break
    time.sleep(0.01)
else:
    raise AssertionError("owned watcher survived pre-submission cancellation")
run_root = stub / "state" / "runs"
if run_root.exists() and list(run_root.iterdir()):
    raise AssertionError("pre-submission cancellation left orphan run state")
PY
  assert_success
}

function test_scripts_032_herdr_child_catchable_launch_signals_preserve_ow() {
  _bats_test_init 32 'herdr-child catchable launch signals preserve ownership after prompt submission'
  local signal signal_name calls
  for signal in HUP INT TERM; do
    child_stub_herdr
    signal_name="$(printf '%s' "$signal" | tr '[:upper:]' '[:lower:]')"
    run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 STUB_START_CONTEXT=1 \
      HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
      HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
      HERDR_CHILD_TEST_WATCHER_RELEASE="$CHILD_STUB/release-watcher" \
      STUB_PROMPT_BLOCK=1 CHILD_SIGNAL="$signal" CHILD_SIGNAL_NAME="$signal_name" \
      CHILD_SCRIPT="$HERDR_CHILD" python3 - <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import time

stub = Path(os.environ["CHILD_STUB"])
child_signal = getattr(signal, "SIG" + os.environ["CHILD_SIGNAL"])
# Parallel Bats workers ignore SIGINT; reset it while spawning so Bash can install the trap.
previous_handler = signal.signal(child_signal, signal.SIG_DFL)
try:
    proc = subprocess.Popen(
        ["bash", os.environ["CHILD_SCRIPT"], "start", "--kind", "claude", "--detach", "--prompt", "test task"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=os.environ.copy(),
    )
finally:
    signal.signal(child_signal, previous_handler)
for _ in range(1000):
    if (stub / "prompt-seen").exists():
        break
    time.sleep(0.01)
else:
    proc.kill()
    raise AssertionError("prompt submission never reached its barrier")

proc.send_signal(child_signal)
try:
    # prompt-seen proves signal ordering; this only guards a stuck cleanup/exit path.
    stdout, stderr = proc.communicate(timeout=30)
except subprocess.TimeoutExpired:
    proc.kill()
    proc.wait()
    raise AssertionError("launcher exceeded the 30-second cleanup hang guard")
if proc.returncode == 0:
    raise AssertionError("signaled launcher returned success")
expected = '"supervision":{"status":"failed","reason":"launch-signal-' + os.environ["CHILD_SIGNAL"]
if expected not in stdout or '"pane":"wT:p9"' not in stdout:
    raise AssertionError("missing recovery JSON: stdout=%r stderr=%r" % (stdout, stderr))
calls = (stub / "calls.log").read_text()
if "pane close" in calls:
    raise AssertionError("signaled launcher closed the preserved child")
(stub / "release-watcher").touch()
PY
    assert_success
    calls="$CHILD_STUB"
    CHILD_STUB=""
    rm -rf "$calls"
  done
}

function test_scripts_033_herdr_child_signal_before_watcher_arm_reports_ab() {
  _bats_test_init 33 'herdr-child signal before the watcher arm reports the abort, never an armed watcher'
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 STUB_START_CONTEXT=1 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_TEST_ARM_BARRIER="$CHILD_STUB/arm" \
    CHILD_SCRIPT="$HERDR_CHILD" python3 - <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import time

stub = Path(os.environ["CHILD_STUB"])
proc = subprocess.Popen(
    ["bash", os.environ["CHILD_SCRIPT"], "start", "--kind", "claude", "--detach", "--prompt", "test task"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=os.environ.copy())
for _ in range(1000):
    if (stub / "arm.ready").exists():
        break
    time.sleep(0.01)
else:
    proc.kill()
    raise AssertionError("watcher did not reach the pre-arm barrier")
proc.send_signal(signal.SIGTERM)
stdout, stderr = proc.communicate(timeout=10)
if proc.returncode == 0:
    raise AssertionError("signaled launcher returned success")
if '"supervision":{"status":"failed","reason":"launch-signal-TERM"' not in stdout:
    raise AssertionError("abort was not confirmed before the failure record: %r %r" % (stdout, stderr))
if '"status":"armed"' in stdout:
    raise AssertionError("pre-arm abort was also reported as armed")
PY
  assert_success
}

function test_scripts_0332_herdr_child_signal_after_watcher_arm_reports_ar() {
  _bats_test_init 0332 'herdr-child signal after the confirmed watcher arm reports armed, never a failure'
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 STUB_START_CONTEXT=1 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_TEST_WATCHER_RELEASE="$CHILD_STUB/release-watcher" \
    HERDR_CHILD_TEST_LAUNCH_POST_ARM_BARRIER="$CHILD_STUB/post-arm" \
    CHILD_SCRIPT="$HERDR_CHILD" python3 - <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import time

stub = Path(os.environ["CHILD_STUB"])
proc = subprocess.Popen(
    ["bash", os.environ["CHILD_SCRIPT"], "start", "--kind", "claude", "--detach", "--prompt", "test task"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=os.environ.copy())
for _ in range(1000):
    if (stub / "post-arm.ready").exists():
        break
    time.sleep(0.01)
else:
    proc.kill()
    raise AssertionError("launcher did not reach the post-arm barrier")
proc.send_signal(signal.SIGTERM)
stdout, stderr = proc.communicate(timeout=10)
if proc.returncode == 0:
    raise AssertionError("signaled launcher returned success")
if '"supervision":{"status":"armed"' not in stdout:
    raise AssertionError("confirmed watcher arm was not reported: %r %r" % (stdout, stderr))
if '"status":"failed"' in stdout:
    raise AssertionError("confirmed watcher arm was falsely reported as failed")
(stub / "release-watcher").touch()
PY
  assert_success
}

function test_scripts_0331_herdr_child_post_arm_barrier_is_bounded() {
  _bats_test_init 0331 'herdr-child launcher held past the watcher arm self-terminates once the hold bound expires'
  # #given — a detached launcher parked at the post-arm barrier
  child_stub_herdr
  local launcher_pid launcher_status attempt=0
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 STUB_START_CONTEXT=1 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_TEST_WATCHER_RELEASE="$CHILD_STUB/release-watcher" \
    HERDR_CHILD_TEST_LAUNCH_POST_ARM_BARRIER="$CHILD_STUB/post-arm" \
    HERDR_CHILD_TEST_HOLD_TIMEOUT_SECONDS=1 \
    bash "$HERDR_CHILD" start --kind claude --detach --prompt "test task" \
    >"$CHILD_STUB/post-arm.out" 2>"$CHILD_STUB/post-arm.err" &
  launcher_pid=$!
  child_wait_for_file "$CHILD_STUB/post-arm.ready"

  # #when — the harness dies without ever writing the release signal
  while kill -0 "$launcher_pid" 2>/dev/null && [ "$attempt" -lt 400 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done

  # #then — the launcher leaves the process table and preserves the armed child
  if kill -0 "$launcher_pid" 2>/dev/null; then
    kill -KILL "$launcher_pid" 2>/dev/null || true
    wait "$launcher_pid" 2>/dev/null || true
    : > "$CHILD_STUB/release-watcher"
    fail 'post-arm barrier exceeded its test hold bound'
  fi
  if wait "$launcher_pid"; then launcher_status=0; else launcher_status=$?; fi
  assert_equal "$launcher_status" 1
  assert_file_contains "$CHILD_STUB/post-arm.out" '"supervision":{"status":"armed"'
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
  : > "$CHILD_STUB/release-watcher"
}

function test_scripts_034_herdr_child_detached_watcher_ignores_stale_settl() {
  _bats_test_init 34 'herdr-child detached watcher ignores stale settlement and delivers a fresh observed outcome'
  child_lifecycle_stub_herdr
  printf 'idle 10\n' > "$CHILD_STUB/child-state"

  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  child_wait_for_get_count 3
  run grep 'event=' "$CHILD_STUB/calls.log"
  assert_failure

  printf 'done 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'event=settled-11'
  run grep -c 'event=settled-11' "$CHILD_STUB/calls.log"
  assert_success
  assert_output 1
  assert_file_contains "$CHILD_STUB/calls.log" 'not\ a\ task-success\ verdict'
  run grep -Eiq 'task_succeeded=true|task completed successfully' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_035_herdr_child_detached_timeout_wakes_once_and_late() {
  _bats_test_init 35 'herdr-child detached timeout wakes once and later settlement wakes the same generation'
  child_lifecycle_stub_herdr

  run child_lifecycle_start --supervision-timeout 50
  assert_success
  child_wait_for_log 'event=timeout'
  run grep -c 'event=timeout' "$CHILD_STUB/calls.log"
  assert_success
  assert_output 1
  assert_file_not_exists "$CHILD_STUB/pane-closed"

  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'event=settled-11'
  run grep 'event=' "$CHILD_STUB/calls.log"
  assert_line --partial 'event=timeout'
  assert_line --partial 'event=settled-11'
  run grep -c 'event=' "$CHILD_STUB/calls.log"
  assert_success
  assert_output 2
}

function test_scripts_036_herdr_child_detached_delivery_follows_parent_ter() {
  _bats_test_init 36 'herdr-child detached delivery follows parent terminal identity to a moved pane'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  printf 'wT:p7\n' > "$CHILD_STUB/parent-pane"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'agent prompt wT:p7.*event=settled-11'
  run grep -q 'agent prompt wT:p0.*event=' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_0361_herdr_child_detached_delivery_fails_closed_on_s() {
  _bats_test_init 0361 'herdr-child detached delivery fails closed on parent session replacement'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  printf 'replaced-session\n' > "$CHILD_STUB/parent-session"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'parent-session-mismatch'
  run grep -q 'event=' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_037_herdr_child_detached_delivery_retries_temporary() {
  _bats_test_init 37 'herdr-child detached delivery retries temporary parent blockage'
  child_lifecycle_stub_herdr
  printf 'blocked\n' > "$CHILD_STUB/parent-status"
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  local attempt=0
  while [ ! -e "$CHILD_STUB/parent-blocked-observed" ] && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$CHILD_STUB/parent-blocked-observed"
  assert_file_not_exists "$CHILD_STUB/successful-prompts.log"
  printf 'working\n' > "$CHILD_STUB/parent-status"
  child_wait_for_log 'event=settled-11' "$CHILD_STUB/successful-prompts.log"
  run grep -c 'event=settled-11' "$CHILD_STUB/successful-prompts.log"
  assert_success
  assert_output 1
}

function test_scripts_0371_herdr_child_detached_delivery_retries_prompt_tr() {
  _bats_test_init 0371 'herdr-child detached delivery retries a prompt transport failure'
  child_lifecycle_stub_herdr
  printf '1\n' > "$CHILD_STUB/prompt-fail-count"
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'event=settled-11' "$CHILD_STUB/successful-prompts.log"
  run grep -c 'event=settled-11' "$CHILD_STUB/successful-prompts.log"
  assert_success
  assert_output 1
}

function test_scripts_038_herdr_child_detached_delivery_uses_capped_increa() {
  _bats_test_init 38 'herdr-child detached delivery uses capped increasing retry backoff and one terminal failure'
  child_lifecycle_stub_herdr
  export HERDR_CHILD_MAX_DELIVERY_RETRIES=4
  export HERDR_CHILD_TEST_RETRY_LOG="$CHILD_STUB/retry.log"
  printf '20\n' > "$CHILD_STUB/prompt-fail-count"
  run child_lifecycle_start --supervision-timeout 5000
  assert_success

  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'supervision_failure_reason=prompt-error'
  run cat "$CHILD_STUB/retry.log"
  assert_success
  assert_output $'1\n2\n4'
  run grep -c 'supervision_failure_reason=prompt-error' "$CHILD_STUB/calls.log"
  assert_success
  assert_output 1
}

function test_scripts_039_herdr_child_transient_pane_reads_never_become_ch() {
  _bats_test_init 39 'herdr-child transient pane reads never become child-gone and delivery continues'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success

  : > "$CHILD_STUB/pane-get-transient-next"
  child_wait_for_file "$CHILD_STUB/pane-get-transient-observed"
  rm -f "$CHILD_STUB/pane-get-transient-observed"
  : > "$CHILD_STUB/pane-transient-after-settlement"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/pane-get-transient-observed"
  child_wait_for_log 'event=settled-11' "$CHILD_STUB/successful-prompts.log"
  run grep -q 'event=child-gone' "$CHILD_STUB/calls.log"
  assert_failure
  run grep -c 'event=settled-11' "$CHILD_STUB/successful-prompts.log"
  assert_success
  assert_output 1
}

function test_scripts_040_herdr_child_superseded_watcher_cannot_publish_fa() {
  _bats_test_init 40 'herdr-child superseded watcher exits and removes its stale run directory'
  child_lifecycle_stub_herdr
  local old_generation old_run watcher_pid attempt=0
  export HERDR_CHILD_TEST_FAILURE_PUBLISH_BARRIER="$CHILD_STUB/failure-publish"
  export HERDR_CHILD_TEST_NOW_SEQ=100
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  old_generation="$(cat "$CHILD_STUB/generation")"
  old_run="$CHILD_STUB/state/runs/$old_generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  printf 'new-generation\n' > "$CHILD_STUB/generation"
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_dir_not_exists "$old_run"
}

function test_scripts_0401_herdr_child_superseded_watcher_cannot_publish_f() {
  _bats_test_init 0401 'herdr-child superseded watcher cannot publish failure metadata over a reply takeover generation'
  child_lifecycle_stub_herdr
  local old_generation new_generation watcher_pid new_watcher_pid reply_pid reply_status attempt=0
  export HERDR_CHILD_TEST_FAILURE_PUBLISH_BARRIER="$CHILD_STUB/failure-publish"
  export HERDR_CHILD_TEST_NOW_SEQ=100
  export HERDR_CHILD_MAX_DELIVERY_RETRIES=1
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  old_generation="$(cat "$CHILD_STUB/generation")"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"

  printf '12\n' > "$CHILD_STUB/prompt-fail-count"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/failure-publish.ready"
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/new-watcher.pid" \
    HERDR_CHILD_TEST_TAKEOVER_METADATA_PUBLISHED="$CHILD_STUB/takeover-metadata-published" \
    HERDR_CHILD_POLL_INTERVAL=0.01 HERDR_CHILD_RETRY_INTERVAL=0.01 \
    bash "$HERDR_CHILD" reply --to "$(child_started_name)" --pane wT:p9 "Use path A" \
    >"$CHILD_STUB/reply.out" 2>"$CHILD_STUB/reply.err" &
  reply_pid=$!
  printf '%s\n' "$reply_pid" > "$CHILD_STUB/reply.pid"
  child_wait_for_file "$CHILD_STUB/takeover-metadata-published"
  : > "$CHILD_STUB/failure-publish.release"
  if wait "$reply_pid"; then reply_status=0; else reply_status=$?; fi
  assert_equal 0 "$reply_status"
  new_generation="$(cat "$CHILD_STUB/generation")"
  run test "$new_generation" != "$old_generation"
  assert_success
  run grep -q 'supervision_failure_reason=prompt-error' "$CHILD_STUB/calls.log"
  assert_failure
  assert_file_not_exists "$CHILD_STUB/failure-label"
  assert_file_not_exists "$CHILD_STUB/failure-reason"
  assert_file_not_exists "$CHILD_STUB/failure-generation"
  assert_file_not_exists "$CHILD_STUB/failure-diagnostic"
  wait "$watcher_pid" 2>/dev/null || true
  printf 'done 12\n' > "$CHILD_STUB/child-state"
  child_wait_for_log "generation=$new_generation.*event=settled-12"
  new_watcher_pid="$(cat "$CHILD_STUB/new-watcher.pid")"
  while kill -0 "$new_watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  run kill -0 "$new_watcher_pid"
  assert_failure
}

function test_scripts_041_herdr_child_watcher_switches_from_fresh_polling() {
  _bats_test_init 41 'herdr-child watcher switches from fresh polling to sliced agent wait'
  child_lifecycle_stub_herdr
  : > "$CHILD_STUB/wait-block"
  run child_lifecycle_start --supervision-timeout 60000
  assert_success

  printf 'working 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/fresh-working-observed"
  child_wait_for_file "$CHILD_STUB/wait-observed"
  local wait_line refresh_line
  assert_file_contains "$CHILD_STUB/calls.log" 'agent wait wT:p9 --timeout 30000'

  printf 'idle 12\n' > "$CHILD_STUB/child-state"
  : > "$CHILD_STUB/wait-release"
  child_wait_for_log 'event=settled-12'
  wait_line="$(grep -n '^agent wait' "$CHILD_STUB/calls.log" | cut -d: -f1 | head -1)"
  refresh_line="$(grep -n 'token supervised=' "$CHILD_STUB/calls.log" | cut -d: -f1 | tail -1)"
  [ "$refresh_line" -gt "$wait_line" ]
}

function test_scripts_042_herdr_child_sliced_wait_revalidates_generation_b() {
  _bats_test_init 42 'herdr-child sliced wait revalidates generation before liveness refresh'
  child_lifecycle_stub_herdr
  : > "$CHILD_STUB/wait-block"
  run child_lifecycle_start --supervision-timeout 60000
  assert_success
  local old_generation old_run watcher_pid attempt=0 wait_line
  old_generation="$(cat "$CHILD_STUB/generation")"
  old_run="$CHILD_STUB/state/runs/$old_generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"

  printf 'working 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/wait-observed"
  wait_line="$(grep -n '^agent wait' "$CHILD_STUB/calls.log" | cut -d: -f1 | head -1)"
  printf 'new-generation\n' > "$CHILD_STUB/generation"
  : > "$CHILD_STUB/wait-release"
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  assert_dir_not_exists "$old_run"
  run bash -c 'line=$1; file=$2; ! sed -n "$((line + 1)),\$p" "$file" | grep -q "token supervised="' _ \
    "$wait_line" "$CHILD_STUB/calls.log"
  assert_success
}

function test_scripts_0421_herdr_child_superseded_watcher_cannot_refresh_li() {
  _bats_test_init 0421 'herdr-child superseded watcher cannot refresh liveness over a new generation'
  child_lifecycle_stub_herdr
  local old_generation new_generation watcher_pid new_watcher_pid reply_pid reply_status
  local wait_line attempt=0
  export HERDR_CHILD_TEST_LIVENESS_PUBLISH_BARRIER="$CHILD_STUB/liveness-publish"
  export HERDR_CHILD_TEST_NOW_SEQ=100

  # #given a detached watcher parked in a sliced agent wait
  : > "$CHILD_STUB/wait-block"
  run child_lifecycle_start --supervision-timeout 60000
  assert_success
  old_generation="$(cat "$CHILD_STUB/generation")"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  printf 'working 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/wait-observed"
  wait_line="$(grep -n '^agent wait' "$CHILD_STUB/calls.log" | cut -d: -f1 | head -1)"

  # #when a real managed continuation completes between the watcher's ordinary
  # generation check and its liveness publication
  : > "$CHILD_STUB/wait-release"
  child_wait_for_file "$CHILD_STUB/liveness-publish.ready"
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_LIVENESS_PUBLISH_BARRIER= \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/new-watcher.pid" \
    HERDR_CHILD_TEST_TAKEOVER_METADATA_PUBLISHED="$CHILD_STUB/takeover-metadata-published" \
    HERDR_CHILD_POLL_INTERVAL=0.01 HERDR_CHILD_RETRY_INTERVAL=0.01 \
    bash "$HERDR_CHILD" reply --to "$(child_started_name)" --pane wT:p9 "Use path A" \
    >"$CHILD_STUB/reply.out" 2>"$CHILD_STUB/reply.err" &
  reply_pid=$!
  printf '%s\n' "$reply_pid" > "$CHILD_STUB/reply.pid"
  child_wait_for_file "$CHILD_STUB/takeover-metadata-published"
  : > "$CHILD_STUB/liveness-publish.release"
  if wait "$reply_pid"; then reply_status=0; else reply_status=$?; fi
  assert_equal 0 "$reply_status"
  new_generation="$(cat "$CHILD_STUB/generation")"
  run test "$new_generation" != "$old_generation"
  assert_success

  # #then the superseded watcher retires without stamping its own generation,
  # while the live generation keeps refreshing through the same boundary
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  # oracle: calls.log records the metadata calls the herdr boundary actually
  # received, so a stale label is observable without reading watcher source.
  run bash -c 'line=$1; generation=$2; file=$3; ! sed -n "$((line + 1)),\$p" "$file" | grep -q "supervised=$generation"' _ \
    "$wait_line" "$old_generation" "$CHILD_STUB/calls.log"
  assert_success
  run bash -c 'line=$1; generation=$2; file=$3; sed -n "$((line + 1)),\$p" "$file" | grep -q "supervised=$generation"' _ \
    "$wait_line" "$new_generation" "$CHILD_STUB/calls.log"
  assert_success
  new_watcher_pid="$(cat "$CHILD_STUB/new-watcher.pid")"
  run kill -0 "$new_watcher_pid"
  assert_success
}

function test_scripts_043_herdr_child_sliced_wait_publishes_one_typed_non() {
  _bats_test_init 43 'herdr-child sliced wait publishes one typed non-timeout failure'
  child_lifecycle_stub_herdr
  : > "$CHILD_STUB/wait-error"
  run child_lifecycle_start --supervision-timeout 60000
  assert_success

  printf 'working 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/wait-observed"
  child_wait_for_log 'supervision_failure_reason=wait-error'
  run grep -c 'supervision_failure_reason=wait-error' "$CHILD_STUB/calls.log"
  assert_success
  assert_output 1
}

function test_scripts_044_herdr_child_detached_watcher_rejects_malformed_s() {
  _bats_test_init 44 'herdr-child detached watcher rejects malformed state and child identity replacement'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  : > "$CHILD_STUB/malformed-state"
  child_wait_for_log 'malformed-state'
  run grep -q 'event=' "$CHILD_STUB/calls.log"
  assert_failure

  teardown
  setup
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  printf 'replacement-session\n' > "$CHILD_STUB/child-session"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  local watcher_pid attempt=0
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  run grep -q 'event=' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_045_herdr_child_reap_invalidates_before_close_while() {
  _bats_test_init 45 'herdr-child reap invalidates before close while spontaneous loss wakes the parent'
  # The deadline is not what this scenario proves; keep it out of reach so a
  # loaded run cannot race reap (issues 2026-08-29-004, 2026-08-30-001).
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/require-reap-invalidation"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reap --to "$(child_started_name)" --pane wT:p9
  assert_success
  assert_file_exists "$CHILD_STUB/reap-invalidation-observed"
  assert_file_not_exists "$CHILD_STUB/close-before-invalidation"
  assert_file_exists "$CHILD_STUB/pane-closed"
  run grep -q 'event=child-gone' "$CHILD_STUB/calls.log"
  assert_failure

  teardown
  setup
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  : > "$CHILD_STUB/child-gone"
  child_wait_for_log 'event=child-gone'
  run grep -c 'event=child-gone' "$CHILD_STUB/calls.log"
  assert_success
  assert_output 1
}

function test_scripts_046_herdr_child_failed_reap_restores_supervision_for() {
  _bats_test_init 46 'herdr-child failed or stale reap restores supervision for the kept child'
  child_lifecycle_stub_herdr
  HERDR_CHILD_TEST_REAP_OWNER_VERIFIED="$CHILD_STUB/reap-owner-verified"
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  local generation run_dir watcher_pid reap_pid attempt=0
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/block-agent-get"
  : > "$CHILD_STUB/block-pane-close"
  : > "$CHILD_STUB/observe-reap-invalidation"
  : > "$CHILD_STUB/close-fail"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/agent-get.ready"

  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reap --to "$(child_started_name)" --pane wT:p9 >"$CHILD_STUB/reap.out" 2>&1 &
  reap_pid=$!
  child_wait_for_file "$CHILD_STUB/pane-close.ready"
  assert_file_contains "$run_dir/invalidated.state" '^reason=reap$'
  : > "$CHILD_STUB/agent-get.release"
  child_wait_for_file "$CHILD_STUB/reap-invalidation-consumed"
  child_wait_for_file "$CHILD_STUB/reap-owner-verified"
  assert_file_exists "$run_dir/invalidated.state"
  assert_file_not_exists "$CHILD_STUB/parent-prompt-accepted"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reap --to "$(child_started_name)" --pane wT:p9
  assert_success
  assert_output --partial 'supervision generation could not be invalidated'
  assert_file_exists "$run_dir/invalidated.state"
  : > "$CHILD_STUB/block-reap-pane-get"
  child_wait_for_file "$CHILD_STUB/reap-pane-get.ready"
  : > "$CHILD_STUB/block-parent-prompt"
  : > "$CHILD_STUB/pane-close.release"
  if ! wait "$reap_pid"; then
    cat "$CHILD_STUB/reap.out" >&2
    return 1
  fi
  assert_file_contains "$CHILD_STUB/reap.out" 'supervision recovery requested'
  assert_file_not_exists "$CHILD_STUB/pane-closed"
  : > "$CHILD_STUB/reap-pane-get.release"
  while [ -f "$run_dir/invalidated.state" ] && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  child_wait_for_file "$CHILD_STUB/parent-prompt-accepted"
  kill -0 "$watcher_pid"

  : > "$CHILD_STUB/release-parent-prompt"
  child_wait_for_file "$CHILD_STUB/successful-prompts.log"
  run grep -c 'event=settled-11' "$CHILD_STUB/successful-prompts.log"
  assert_success
  assert_output 1
  run grep -q 'event=child-gone' "$CHILD_STUB/calls.log"
  assert_failure

  teardown
  setup
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  : > "$CHILD_STUB/block-agent-get"
  : > "$CHILD_STUB/block-parent-prompt"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/agent-get.ready"

  local stale_token=00000000000000000000000000000001
  printf 'status=pending\nowner_pid=%s\nowner_token=%s\n' "$$" "$stale_token" > "$run_dir/reap-pending.state"
  printf 'reason=reap\n' > "$run_dir/invalidated.state"
  : > "$run_dir/reap-owner-$stale_token.gone"
  : > "$CHILD_STUB/agent-get.release"
  attempt=0
  while [ -f "$run_dir/invalidated.state" ] && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  child_wait_for_file "$CHILD_STUB/parent-prompt-accepted"
  kill -0 "$watcher_pid"

  : > "$CHILD_STUB/release-parent-prompt"
  child_wait_for_file "$CHILD_STUB/successful-prompts.log"
  run grep -c 'event=settled-11' "$CHILD_STUB/successful-prompts.log"
  assert_success
  assert_output 1
}

function test_scripts_047_herdr_child_detached_ask_follows_parent_identity() {
  _bats_test_init 47 'herdr-child detached ask follows parent identity and suppresses its ordinary blocked wake'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  local generation watcher_pid attempt=0
  generation="$(cat "$CHILD_STUB/generation")"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  printf 'wT:p7\n' > "$CHILD_STUB/parent-pane"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_LAUNCH=1 \
    HERDR_CHILD_PARENT_PANE=wT:p0 HERDR_CHILD_PARENT_TERMINAL=term-parent \
    HERDR_CHILD_PARENT_SESSION=parent-session \
    bash "$HERDR_CHILD" ask "Which path?"
  assert_success
  assert_file_contains "$CHILD_STUB/successful-prompts.log" "generation=$generation"
  assert_file_contains "$CHILD_STUB/successful-prompts.log" 'event=callback-'

  printf 'blocked 11\n' > "$CHILD_STUB/child-state"
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  run grep -q 'event=blocked-11' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_048_herdr_child_attached_ask_follows_captured_parent() {
  _bats_test_init 48 'herdr-child attached ask follows captured parent identity after the parent moves'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p7","terminal_id":"term-parent","revision":1,"state_change_seq":1,"agent_session":{"value":"parent-session"}},{"name":"orange-panda","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 \
    HERDR_PANE_ID=wT:p9 HERDR_CHILD_LAUNCH=1 HERDR_CHILD_PARENT_PANE=wT:p0 \
    HERDR_CHILD_LAUNCH_MODE=wait HERDR_CHILD_PARENT_TERMINAL=term-parent \
    HERDR_CHILD_PARENT_SESSION=parent-session \
    bash "$HERDR_CHILD" ask "Which path?"
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent prompt wT:p7.*child-ask\ v1'
  run grep -q 'agent prompt wT:p0' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_049_herdr_child_callback_intent_suppresses_blocked_w() {
  _bats_test_init 49 'herdr-child callback intent suppresses blocked wake until confirmed receipt'
  child_lifecycle_stub_herdr
  export HERDR_CHILD_TEST_CALLBACK_RECEIPT_BARRIER="$CHILD_STUB/callback-receipt"
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  local generation run_dir ask_pid watcher_pid attempt=0
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"

  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_LAUNCH=1 \
    HERDR_CHILD_PARENT_PANE=wT:p0 HERDR_CHILD_PARENT_TERMINAL=term-parent \
    HERDR_CHILD_PARENT_SESSION=parent-session \
    bash "$HERDR_CHILD" ask "Which path?" >"$CHILD_STUB/ask.out" 2>"$CHILD_STUB/ask.err" &
  ask_pid=$!
  child_wait_for_file "$CHILD_STUB/callback-receipt.ready"
  assert_file_contains "$run_dir/callback.state" '^status=in-progress$'
  assert_file_contains "$CHILD_STUB/successful-prompts.log" 'event=callback-'

  printf 'blocked 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/blocked-observed"
  run grep -q 'event=blocked-11' "$CHILD_STUB/calls.log"
  assert_failure
  kill -0 "$watcher_pid"

  : > "$CHILD_STUB/callback-receipt.release"
  wait "$ask_pid"
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  run grep -q 'event=blocked-11' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_050_herdr_child_callback_delivery_exhaustion_keeps_d() {
  _bats_test_init 50 'herdr-child callback delivery exhaustion keeps decision waiting and blocks reap'
  local generation run_dir
  child_lifecycle_stub_herdr
  export HERDR_CHILD_MAX_DELIVERY_RETRIES=3
  printf '20\n' > "$CHILD_STUB/prompt-fail-count"
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  run cat "$CHILD_STUB/generation"
  assert_success
  generation="$output"
  run_dir="$CHILD_STUB/state/runs/$generation"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_LAUNCH=1 \
    HERDR_CHILD_PARENT_PANE=wT:p0 HERDR_CHILD_PARENT_TERMINAL=term-parent \
    HERDR_CHILD_PARENT_SESSION=parent-session \
    bash "$HERDR_CHILD" ask "Which path?"
  assert_failure
  assert_file_exists "$CHILD_STUB/waiting-label"

  printf 'blocked 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$run_dir/failed.state"
  run grep -qx 'reason=prompt-error' "$run_dir/failed.state"
  assert_success
  assert_file_exists "$CHILD_STUB/waiting-label"
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reap --to "$(child_started_name)" --pane wT:p9
  assert_success
  assert_output --partial 'has a waiting state label'
  assert_file_not_exists "$CHILD_STUB/pane-closed"
}

function test_scripts_051_herdr_child_detached_callbacks_fail_closed_when() {
  _bats_test_init 51 'herdr-child detached callbacks fail closed when supervision metadata is unreadable'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  rm -f "$CHILD_STUB/generation"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_LAUNCH=1 \
    HERDR_CHILD_PARENT_PANE=wT:p0 HERDR_CHILD_PARENT_TERMINAL=term-parent \
    HERDR_CHILD_PARENT_SESSION=parent-session \
    bash "$HERDR_CHILD" ask "Which path?"
  assert_failure
  assert_output --partial 'detached child metadata is unavailable'
  assert_file_not_exists "$CHILD_STUB/successful-prompts.log"

  teardown
  setup
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  : > "$CHILD_STUB/pane-malformed"
  local prompts_before
  prompts_before="$(grep -c '^agent prompt' "$CHILD_STUB/calls.log")"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reply --to "$(child_started_name)" --pane wT:p9 "Use path A"
  assert_failure
  assert_output --partial 'pane metadata was malformed'
  run grep -c '^agent prompt' "$CHILD_STUB/calls.log"
  assert_output "$prompts_before"
}

function test_scripts_052_herdr_child_detached_reply_advances_generation_a() {
  _bats_test_init 52 'herdr-child detached reply advances generation and rearms later settlement'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  local old_generation new_generation
  old_generation="$(cat "$CHILD_STUB/generation")"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'event=settled-11'

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_POLL_INTERVAL=0.01 HERDR_CHILD_RETRY_INTERVAL=0.01 \
    bash "$HERDR_CHILD" reply --to "$(child_started_name)" --pane wT:p9 "Use path A"
  assert_success
  new_generation="$(cat "$CHILD_STUB/generation")"
  [ "$new_generation" != "$old_generation" ]
  assert_output --partial '"supervision":{"status":"armed"'

  printf 'idle 12\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'event=settled-12'
  assert_file_contains "$CHILD_STUB/calls.log" "generation=$new_generation.*event=settled-12"
}

function test_scripts_053_herdr_child_managed_prompt_requires_a_mode_and_a() {
  _bats_test_init 53 'herdr-child managed prompt requires a mode and attached wait observes a newer sequence'
  child_lifecycle_stub_herdr
  printf 'orange-panda' > "$CHILD_STUB/started-name"
  : > "$CHILD_STUB/advance-on-prompt"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" prompt --to orange-panda --pane wT:p9 "next task"
  assert_failure 2
  assert_output --partial 'exactly one of --wait or --detach'

  : > "$CHILD_STUB/calls.log"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" prompt --to orange-panda --pane wT:p9 --wait --timeout 1000 "next task"
  assert_success
  assert_output --partial 'Prompt completed for orange-panda in wT:p9.'
  run grep -q 'token supervised=' "$CHILD_STUB/calls.log"
  assert_failure
  assert_file_not_exists "$CHILD_STUB/watcher.pid"
}

function test_scripts_054_herdr_child_attached_prompt_wait_rejects_the_fir() {
  _bats_test_init 54 'herdr-child attached prompt wait rejects the first one-step settlement after a working baseline'
  child_lifecycle_stub_herdr
  printf 'orange-panda' > "$CHILD_STUB/started-name"
  printf 'working 10\n' > "$CHILD_STUB/baseline-state"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"

  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_POLL_INTERVAL=0.01 \
    bash "$HERDR_CHILD" prompt --to orange-panda --pane wT:p9 --wait --timeout 5000 \
    "sequence-sensitive task" >"$CHILD_STUB/prompt.out" 2>"$CHILD_STUB/prompt.err" &
  local prompt_pid=$!
  child_wait_for_get_count 3
  kill -0 "$prompt_pid"

  printf 'working 12\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/fresh-working-observed"
  printf 'idle 13\n' > "$CHILD_STUB/child-state"
  wait "$prompt_pid"
  assert_file_contains "$CHILD_STUB/prompt.out" 'Prompt completed for orange-panda in wT:p9.'
}

function test_scripts_055_herdr_child_managed_detached_prompt_advances_gen() {
  _bats_test_init 55 'herdr-child managed detached prompt advances generation, invalidates the old watcher, and preserves the child on rearm failure'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  local old_generation new_generation
  old_generation="$(cat "$CHILD_STUB/generation")"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'event=settled-11'

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_POLL_INTERVAL=0.01 HERDR_CHILD_RETRY_INTERVAL=0.01 \
    bash "$HERDR_CHILD" prompt --to "$(child_started_name)" --pane wT:p9 --detach \
    --supervision-timeout 5000 "ordinary follow-up"
  assert_success
  new_generation="$(cat "$CHILD_STUB/generation")"
  [ "$new_generation" != "$old_generation" ]
  run cat "$CHILD_STUB/state/runs/$new_generation/launch.state"
  assert_success
  assert_output "$(printf '%s\n' 'mode=detach' "generation=$new_generation" 'timeout_ms=5000' \
    'parent_pane=wT:p0' 'parent_terminal=term-parent' 'parent_session=parent-session' \
    "child_name=$(child_started_name)" 'child_pane=wT:p9' 'child_terminal=term-child' \
    'child_session=child-session' 'baseline_seq=11')"
  printf 'done 12\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'event=settled-12'

  teardown
  setup
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  old_generation="$(cat "$CHILD_STUB/generation")"
  local old_run="$CHILD_STUB/state/runs/$old_generation"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_TEST_ARM_FAIL=1 HERDR_CHILD_POLL_INTERVAL=0.01 \
    bash "$HERDR_CHILD" prompt --to "$(child_started_name)" --pane wT:p9 --detach \
    --supervision-timeout 5000 "ordinary follow-up"
  assert_failure
  assert_output --partial '"supervision":{"status":"failed","reason":"watcher-arm-failed"'
  [ ! -d "$old_run" ] || [ -f "$old_run/invalidated.state" ]
  run cat "$CHILD_STUB/generation"
  assert_success
  refute_output "$old_generation"
  assert_file_not_exists "$CHILD_STUB/pane-closed"

  teardown
  setup
  child_lifecycle_stub_herdr
  HERDR_CHILD_TEST_WATCHER_RELEASE="$CHILD_STUB/release-watcher" \
    HERDR_CHILD_TEST_HOLD_TIMEOUT_SECONDS=120 \
    run child_lifecycle_start --supervision-timeout 5000
  assert_success
  old_generation="$(cat "$CHILD_STUB/generation")"
  old_run="$CHILD_STUB/state/runs/$old_generation"
  local old_watcher old_watcher_identity attempt=0
  old_watcher="$(cat "$CHILD_STUB/watcher.pid")"
  kill -0 "$old_watcher"
  old_watcher_identity="$(LC_ALL=C /bin/ps -o lstart= -o command= -p "$old_watcher")"
  case "$old_watcher_identity" in
    *"$HERDR_CHILD __watcher"*"--run-dir $old_run"*) ;;
    *) printf 'old watcher identity was not observable: %s\n' "$old_watcher_identity" >&2; return 1 ;;
  esac
  old_watcher_is_alive() {
    local current_identity
    current_identity="$(LC_ALL=C /bin/ps -o lstart= -o command= -p "$old_watcher" 2>/dev/null)" || return 1
    [ "$current_identity" = "$old_watcher_identity" ]
  }
  assert_dir_exists "$old_run"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/new-watcher.pid" \
    HERDR_CHILD_TEST_WATCHER_RELEASE="$CHILD_STUB/release-watcher" \
    HERDR_CHILD_TEST_HOLD_TIMEOUT_SECONDS=120 HERDR_CHILD_POLL_INTERVAL=0.01 \
    bash "$HERDR_CHILD" prompt --to "$(child_started_name)" --pane wT:p9 --detach \
    --supervision-timeout 5000 "take over held watcher"
  assert_success
  assert_file_not_exists "$CHILD_STUB/release-watcher"
  while { old_watcher_is_alive || [ -d "$old_run" ]; } && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  if [ "$attempt" -ge 500 ]; then
    old_watcher_is_alive && printf 'stale watcher identity retained: %s\n' "$old_watcher" >&2
    [ ! -d "$old_run" ] || printf 'stale watcher run directory retained: %s\n' "$old_run" >&2
    return 1
  fi
  run old_watcher_is_alive
  assert_failure
  assert_dir_not_exists "$old_run"
  assert_file_not_exists "$CHILD_STUB/release-watcher"
  rm -f "$CHILD_STUB/watcher.pid"
}

function test_scripts_056_herdr_child_continuation_preflight_failures_pres() {
  _bats_test_init 56 'herdr-child continuation preflight failures preserve the prior generation'
  local old_generation old_run old_watcher

  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  old_generation="$(cat "$CHILD_STUB/generation")"
  old_run="$CHILD_STUB/state/runs/$old_generation"
  old_watcher="$(cat "$CHILD_STUB/watcher.pid")"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_TEST_BASELINE_FAIL=1 \
    bash "$HERDR_CHILD" prompt --to "$(child_started_name)" --pane wT:p9 --detach "next task"
  assert_failure
  assert_output --partial 'baseline state could not be read'
  assert_file_not_exists "$old_run/invalidated.state"
  run cat "$CHILD_STUB/generation"
  assert_output "$old_generation"
  kill -0 "$old_watcher"

  teardown
  setup
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  old_generation="$(cat "$CHILD_STUB/generation")"
  old_run="$CHILD_STUB/state/runs/$old_generation"
  old_watcher="$(cat "$CHILD_STUB/watcher.pid")"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_TEST_SETUP_FAIL=1 \
    bash "$HERDR_CHILD" prompt --to "$(child_started_name)" --pane wT:p9 --detach "next task"
  assert_failure
  assert_output --partial 'setup failed before supervision takeover'
  assert_file_not_exists "$old_run/invalidated.state"
  run cat "$CHILD_STUB/generation"
  assert_output "$old_generation"
  kill -0 "$old_watcher"

  teardown
  setup
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  old_generation="$(cat "$CHILD_STUB/generation")"
  old_run="$CHILD_STUB/state/runs/$old_generation"
  old_watcher="$(cat "$CHILD_STUB/watcher.pid")"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_TEST_PREPARE_FAIL=1 \
    bash "$HERDR_CHILD" prompt --to "$(child_started_name)" --pane wT:p9 --detach "next task"
  assert_failure
  assert_output --partial 'watcher failed before supervision takeover'
  assert_file_not_exists "$old_run/invalidated.state"
  run cat "$CHILD_STUB/generation"
  assert_output "$old_generation"
  kill -0 "$old_watcher"
}

function test_scripts_057_herdr_child_attached_child_promoted_to_detach_as() {
  _bats_test_init 57 'herdr-child attached child promoted to detach asks through validated metadata'
  child_lifecycle_stub_herdr
  printf 'orange-panda' > "$CHILD_STUB/started-name"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_POLL_INTERVAL=0.01 \
    bash "$HERDR_CHILD" prompt --to orange-panda --pane wT:p9 --detach \
    --supervision-timeout 5000 "promote this child"
  assert_success
  local generation
  generation="$(cat "$CHILD_STUB/generation")"
  printf 'wT:p7\n' > "$CHILD_STUB/parent-pane"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_LAUNCH=1 \
    HERDR_CHILD_PARENT_PANE=wT:p0 HERDR_CHILD_LAUNCH_MODE=wait \
    HERDR_CHILD_PARENT_TERMINAL=term-parent HERDR_CHILD_PARENT_SESSION=parent-session \
    bash "$HERDR_CHILD" ask "Which promoted path?"
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent prompt wT:p7.*child-ask\ v2'
  assert_file_contains "$CHILD_STUB/successful-prompts.log" "generation=$generation"
  assert_file_contains "$CHILD_STUB/successful-prompts.log" 'child-ask v2'
}

# Reduce a marker to its field-key skeleton: "[child-ask v2 generation=... pane=x]"
# becomes "[child-ask v2 generation= pane=]", so documented placeholders and
# emitted values compare as one shape.
child_marker_skeleton() {
  sed -E 's/=[^] ]+/=/g' <<<"$1"
}

# The marker lines in child-agent-contract.md are a consumed wire format: parents
# validate [child-supervision v1 ...] and [child-ask v2 ...] bodies field by field,
# so the emitted markers must round-trip the documented shapes.
function test_scripts_058_herdr_child_markers_round_trip_documented_shape() {
  _bats_test_init 58 'herdr-child emitted markers round-trip the documented wire shapes'
  local contract="$SOURCE_ROOT/private_dot_claude/shared/child-agent-contract.md"
  local skill="$SOURCE_ROOT/private_dot_agents/skills/herdr/SKILL.md"
  local consult="$SOURCE_ROOT/private_dot_agents/skills/ask-in-herdr/SKILL.md"

  # #given — a detached child settles, so the watcher prompts the parent
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  printf 'done 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_log 'event=settled-11' "$CHILD_STUB/successful-prompts.log"

  # #then — the delivered supervision marker matches the documented shape
  local emitted documented
  emitted="$(grep -o '\[child-supervision v1 generation=[^]]*\]' "$CHILD_STUB/successful-prompts.log" | head -n1)"
  documented="$(grep -o '\[child-supervision v1 generation=[^]]*\]' "$contract" | head -n1)"
  [ -n "$emitted" ] || fail "no child-supervision marker was delivered to the parent"
  [ -n "$documented" ] || fail "contract no longer documents the child-supervision marker shape"
  assert_equal "$(child_marker_skeleton "$documented")" "$(child_marker_skeleton "$emitted")"
  grep -Eq '^\[child-supervision v1 generation=[^ ]+ event=(timeout|settled-[0-9]+|blocked-[0-9]+|child-gone) outcome=[^ ]+ reason=[^ ]+ agent=[^ ]+ pane=[^] ]+\]$' \
    <<<"$emitted" || fail "supervision marker values break the documented grammar: $emitted"

  # #given — a detached child calls back through ask
  child_lifecycle_stub_herdr
  printf 'orange-panda' > "$CHILD_STUB/started-name"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_POLL_INTERVAL=0.01 \
    bash "$HERDR_CHILD" prompt --to orange-panda --pane wT:p9 --detach \
    --supervision-timeout 5000 "detached task"
  assert_success
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_LAUNCH=1 \
    HERDR_CHILD_PARENT_PANE=wT:p0 HERDR_CHILD_LAUNCH_MODE=wait \
    HERDR_CHILD_PARENT_TERMINAL=term-parent HERDR_CHILD_PARENT_SESSION=parent-session \
    bash "$HERDR_CHILD" ask "Which path?"
  assert_success

  # #then — the delivered callback marker matches the documented shape
  emitted="$(grep -o '\[child-ask v2 generation=[^]]*\]' "$CHILD_STUB/successful-prompts.log" | head -n1)"
  documented="$(grep -o '\[child-ask v2 generation=[^]]*\]' "$contract" | head -n1)"
  [ -n "$emitted" ] || fail "no child-ask v2 marker was delivered to the parent"
  [ -n "$documented" ] || fail "contract no longer documents the child-ask v2 marker shape"
  assert_equal "$(child_marker_skeleton "$documented")" "$(child_marker_skeleton "$emitted")"
  grep -Eq '^\[child-ask v2 generation=[^ ]+ event=callback-[0-9]+ agent=[^ ]+ pane=[^] ]+\]$' \
    <<<"$emitted" || fail "child-ask marker values break the documented grammar: $emitted"

  # #then — every subcommand the docs reference is one the CLI accepts
  local tokens token
  tokens="$(grep -ohE 'herdr-child [a-z][a-z-]*' "$contract" "$skill" "$consult" \
    | awk '{print $2}' | sort -u)"
  [ -n "$tokens" ] || fail "docs reference no herdr-child subcommands; the sync sweep would no-op"
  for token in $tokens; do
    # Without a herdr environment every real subcommand fails for an env
    # reason; only a token the CLI dropped fails with "unknown subcommand".
    run env PATH="$CHILD_STUB:$PATH" HERDR_ENV= HERDR_PANE_ID= bash "$HERDR_CHILD" "$token"
    assert_failure
    refute_output --partial 'unknown subcommand'
  done
}

function test_scripts_059_herdr_child_expires_an_abandoned_callback_claim() {
  _bats_test_init 59 'herdr-child expires an abandoned callback claim into a terminal supervision failure'
  # #given — a detached child holding an unresolved callback claim
  child_lifecycle_stub_herdr
  export HERDR_CHILD_TEST_CALLBACK_RECEIPT_BARRIER="$CHILD_STUB/callback-receipt"
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  local generation run_dir ask_pid watcher_pid attempt=0
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"

  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_LAUNCH=1 \
    HERDR_CHILD_PARENT_PANE=wT:p0 HERDR_CHILD_PARENT_TERMINAL=term-parent \
    HERDR_CHILD_PARENT_SESSION=parent-session \
    bash "$HERDR_CHILD" ask "Which path?" >"$CHILD_STUB/ask.out" 2>"$CHILD_STUB/ask.err" &
  ask_pid=$!
  child_wait_for_file "$CHILD_STUB/callback-receipt.ready"

  # #when — the process owning the claim dies before publishing its receipt
  kill -KILL "$ask_pid"
  wait "$ask_pid" 2>/dev/null || true
  printf 'blocked 11\n' > "$CHILD_STUB/child-state"

  # #then — supervision reaches a terminal outcome instead of polling forever
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 2000 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 2000 ] || fail "watcher kept polling an abandoned callback claim"
  assert_file_contains "$run_dir/failed.state" '^reason=callback-owner-lost$'
  assert_file_contains "$CHILD_STUB/failure-reason" '^callback-owner-lost$'
  assert_file_exists "$CHILD_STUB/waiting-label"
}

function test_scripts_0592_herdr_child_callback_receipt_barrier_is_bounded() {
  _bats_test_init 0592 'herdr-child ask held before its callback receipt self-terminates once the hold bound expires'
  # #given — a detached child parked at the callback receipt barrier
  child_lifecycle_stub_herdr
  export HERDR_CHILD_TEST_CALLBACK_RECEIPT_BARRIER="$CHILD_STUB/callback-receipt"
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  local ask_pid ask_status attempt=0
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_LAUNCH=1 \
    HERDR_CHILD_PARENT_PANE=wT:p0 HERDR_CHILD_PARENT_TERMINAL=term-parent \
    HERDR_CHILD_PARENT_SESSION=parent-session \
    HERDR_CHILD_TEST_HOLD_TIMEOUT_SECONDS=1 \
    bash "$HERDR_CHILD" ask "Which path?" >"$CHILD_STUB/ask.out" 2>"$CHILD_STUB/ask.err" &
  ask_pid=$!
  child_wait_for_file "$CHILD_STUB/callback-receipt.ready"

  # #when — the harness dies without ever writing the release signal
  while kill -0 "$ask_pid" 2>/dev/null && [ "$attempt" -lt 400 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done

  # #then — the ask process leaves the process table instead of polling forever
  if kill -0 "$ask_pid" 2>/dev/null; then
    kill -KILL "$ask_pid" 2>/dev/null || true
    wait "$ask_pid" 2>/dev/null || true
    fail 'callback receipt barrier exceeded its test hold bound'
  fi
  if wait "$ask_pid"; then ask_status=0; else ask_status=$?; fi
  assert_equal "$ask_status" 1
  assert_file_contains "$CHILD_STUB/ask.err" 'callback receipt barrier expired'
}

function test_scripts_0591_herdr_child_bounds_sustained_pane_read_failures() {
  _bats_test_init 591 'herdr-child bounds sustained pane-read failures into a reported terminal state'
  local generation run_dir watcher_pid attempt

  # #given — a detached child settles while herdr drops a single pane read
  child_lifecycle_stub_herdr
  export HERDR_CHILD_MAX_DELIVERY_RETRIES=3
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  printf '1\n' > "$CHILD_STUB/pane-get-outage"

  # #when — the outage ends well inside the budget
  printf 'idle 11\n' > "$CHILD_STUB/child-state"

  # #then — a recoverable outage still delivers the lifecycle event
  child_wait_for_log 'event=settled-11' "$CHILD_STUB/successful-prompts.log"
  assert_file_not_exists "$CHILD_STUB/failure-reason"

  # #given — the same child under an outage that lasts the whole budget
  teardown
  setup
  child_lifecycle_stub_herdr
  export HERDR_CHILD_MAX_DELIVERY_RETRIES=3
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  printf '3\n' > "$CHILD_STUB/pane-get-outage"

  # #when — every pane read the retry policy allows fails
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  attempt=0
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 2000 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done

  # #then — supervision fails diagnostically instead of delivering the event
  [ "$attempt" -lt 2000 ] || fail "watcher kept retrying an exhausted pane-read budget"
  assert_file_contains "$CHILD_STUB/failure-reason" '^wait-error$'
  assert_file_contains "$run_dir/failed.state" '^reason=wait-error$'
  run grep -q 'event=settled-11' "$CHILD_STUB/successful-prompts.log"
  assert_failure

  # #given — an outage that never recovers, so no diagnostic can be published
  teardown
  setup
  child_lifecycle_stub_herdr
  export HERDR_CHILD_MAX_DELIVERY_RETRIES=3
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  printf '100000\n' > "$CHILD_STUB/pane-get-outage"

  # #when — herdr stops answering pane reads for good
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  attempt=0
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 2000 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done

  # #then — the watcher still reaches a terminal state instead of polling forever
  [ "$attempt" -lt 2000 ] || fail "watcher polled a permanent pane-read outage forever"
  assert_file_contains "$run_dir/failed.state" '^reason=wait-error$'
}

function test_scripts_060_herdr_child_maps_claude_postures_effort_and_skill_direc() {
  _bats_test_init 60 'herdr-child maps claude postures, effort, and skill directories'
  child_stub_herdr
  run child_start --kind claude --effort high --skills A --skills B --wait
  assert_success
  assert_output "{\"agent\":\"$(child_started_name)\",\"pane\":\"wT:p9\"}"
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--effort high --add-dir A --add-dir B.*--disallowed-tools Edit Write NotebookEdit AskUserQuestion'

  : > "$CHILD_STUB/calls.log"
  run child_start --kind claude --posture rw --wait
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--disallowed-tools AskUserQuestion'
  run grep -q 'disallowed-tools Edit' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_061_herdr_child_maps_opencode_permissions_model_and() {
  _bats_test_init 61 'herdr-child maps opencode permissions, model, and configured agent'
  child_stub_herdr
  run child_start --kind opencode --agent reviewer --wait
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'OPENCODE_PERMISSION=.*question.*deny.*edit.*deny'
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--model openai/gpt-5.5 --agent reviewer'

  : > "$CHILD_STUB/calls.log"
  run child_start --kind opencode --posture rw --wait
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'OPENCODE_PERMISSION=.*question.*deny'
  run grep -q 'OPENCODE_PERMISSION=.*edit' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_062_herdr_child_maps_pi_model_effort_skills_and_ques() {
  _bats_test_init 62 'herdr-child maps pi model, effort, skills, and question exclusion'
  child_stub_herdr
  run child_start --kind pi --posture rw --skills A --skills B --wait
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--exclude-tools ask_user --model openai-codex/gpt-5.5 --thinking medium --skill A --skill B'

  : > "$CHILD_STUB/calls.log"
  run child_start --kind pi --posture rw --model custom/model --effort high --wait
  assert_success
  assert_file_contains "$CHILD_STUB/calls.log" 'agent start.*--model custom/model --thinking high'
}

function test_scripts_063_herdr_child_rejects_native_options_that_the_sele() {
  _bats_test_init 63 'herdr-child rejects native options that the selected kind cannot map'
  child_stub_herdr
  run child_start --kind opencode --effort high --wait
  assert_failure 2
  assert_output --partial "--effort is not supported for opencode"
  run child_start --kind pi --posture rw --agent reviewer --wait
  assert_failure 2
  assert_output --partial "--agent is not supported for pi"
  run child_start --kind opencode --skills A --wait
  assert_failure 2
  assert_output --partial "--skills is not supported for opencode"
  [ ! -f "$CHILD_STUB/calls.log" ]
}

function test_scripts_064_herdr_child_splits_starts_and_prompts_in_order_w() {
  _bats_test_init 64 'herdr-child splits, starts, and prompts in order with both coordinates'
  child_stub_herdr
  STUB_REQUIRE_SPLIT=1 run child_start --kind claude --wait --timeout 5000
  assert_success
  local child_name call1 call2 call3 call4 call5 call6
  child_name="$(child_started_name)"
  call1="$(sed -n '1p' "$CHILD_STUB/calls.log")"
  call2="$(sed -n '2p' "$CHILD_STUB/calls.log")"
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  call4="$(sed -n '4p' "$CHILD_STUB/calls.log")"
  call5="$(sed -n '5p' "$CHILD_STUB/calls.log")"
  call6="$(sed -n '6p' "$CHILD_STUB/calls.log")"
  [[ "$call1" == agent\ list* ]] || fail "unexpected first herdr-child call: $call1"
  [[ "$call2" == pane\ split*HERDR_CHILD_LAUNCH=1*HERDR_CHILD_PARENT_PANE=wT:p0* ]] || fail "unexpected second herdr-child call: $call2"
  [[ "$call3" == agent\ start* ]] || fail "unexpected third herdr-child call: $call3"
  [[ "$call4" == agent\ list* ]] || fail "unexpected fourth herdr-child call: $call4"
  [[ "$call5" == pane\ get*wT:p9* ]] || fail "unexpected fifth herdr-child call: $call5"
  [[ "$call6" == agent\ prompt*"$child_name"*wT:p9*wT:p0*--wait*--timeout\ 5000* ]] || fail "unexpected sixth herdr-child call: $call6"
}

function test_scripts_065_herdr_child_tab_mode_records_ownership_before_st() {
  _bats_test_init 65 'herdr-child tab mode records ownership before starting an attached child'
  child_stub_herdr
  STUB_REQUIRE_SPLIT=1 HERDR_WORKSPACE_ID=w1 run child_start \
    --kind claude --tab --label mylabel --wait
  assert_success
  assert_output "{\"agent\":\"$(child_started_name)\",\"pane\":\"wT:p9\",\"tab\":\"wT:tA\"}"
  local call1 call2 call3 call4 call5 call6 call7
  call1="$(sed -n '1p' "$CHILD_STUB/calls.log")"
  call2="$(sed -n '2p' "$CHILD_STUB/calls.log")"
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  call4="$(sed -n '4p' "$CHILD_STUB/calls.log")"
  call5="$(sed -n '5p' "$CHILD_STUB/calls.log")"
  call6="$(sed -n '6p' "$CHILD_STUB/calls.log")"
  call7="$(sed -n '7p' "$CHILD_STUB/calls.log")"
  [[ "$call1" == agent\ list* ]] || fail "unexpected first tab-mode call: $call1"
  [[ "$call2" == tab\ create*--workspace\ w1*HERDR_CHILD_LAUNCH=1*HERDR_CHILD_PARENT_PANE=wT:p0*--label\ mylabel* ]] || fail "unexpected second tab-mode call: $call2"
  [[ "$call3" == pane\ report-metadata\ wT:p9\ --source\ child-agent-tab*child-tab=wT:tA* ]] || fail "unexpected third tab-mode call: $call3"
  [[ "$call4" == agent\ start* ]] || fail "unexpected fourth tab-mode call: $call4"
  [[ "$call5" == agent\ list* ]] || fail "unexpected fifth tab-mode call: $call5"
  [[ "$call6" == pane\ get*wT:p9* ]] || fail "unexpected sixth tab-mode call: $call6"
  [[ "$call7" == agent\ prompt*--wait* ]] || fail "unexpected seventh tab-mode call: $call7"
  assert_file_contains "$CHILD_STUB/resource-tree.log" '^record-child --pane wT:p9 --terminal term-child'
}

function test_scripts_066_herdr_child_tab_launch_signal_closes_a_parsed_cr() {
  _bats_test_init 66 'herdr-child tab launch signal closes a parsed creation before ownership publication'
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_WORKSPACE_ID=w1 STUB_START_CONTEXT=1 \
    HERDR_CHILD_TEST_TAB_CREATED_BARRIER="$CHILD_STUB/tab-created" \
    CHILD_SCRIPT="$HERDR_CHILD" python3 - <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import time

stub = Path(os.environ["CHILD_STUB"])
proc = subprocess.Popen(
    ["bash", os.environ["CHILD_SCRIPT"], "start", "--kind", "claude", "--tab", "--wait", "--prompt", "test task"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=os.environ.copy())
for _ in range(1000):
    if (stub / "tab-created.ready").exists():
        break
    time.sleep(0.01)
else:
    proc.kill()
    raise AssertionError("launcher did not reach the post-create ownership barrier")
proc.send_signal(signal.SIGTERM)
stdout, stderr = proc.communicate(timeout=10)
if proc.returncode == 0:
    raise AssertionError("signaled tab launcher returned success")
calls = (stub / "calls.log").read_text()
if "pane close wT:p9" not in calls:
    raise AssertionError("owned tab root pane was not closed: %s" % calls)
if "pane report-metadata" in calls or "agent start" in calls:
    raise AssertionError("signal crossed the ownership publication barrier: %s" % calls)
if "manual cleanup" in stderr:
    raise AssertionError("parseable identity was reported as unknown: %s" % stderr)
PY
  assert_success
}

# Delivers SIGTERM to a launcher parked between the herdr response and the
# identity read, so the trap runs while pane and launch_terminal are still empty.
child_signal_before_identity_capture() {
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_WORKSPACE_ID=w1 STUB_START_CONTEXT=1 \
    HERDR_CHILD_TEST_SPLIT_CAPTURED_BARRIER="$CHILD_STUB/split-captured" \
    HERDR_CHILD_TEST_HOLD_TIMEOUT_SECONDS=10 \
    CHILD_EXTRA_ARGS="$1" CHILD_SCRIPT="$HERDR_CHILD" python3 - <<'PY'
import os
from pathlib import Path
import shlex
import signal
import subprocess
import time

stub = Path(os.environ["CHILD_STUB"])
extra = shlex.split(os.environ["CHILD_EXTRA_ARGS"])
proc = subprocess.Popen(
    ["bash", os.environ["CHILD_SCRIPT"], "start", "--kind", "claude", "--wait",
     "--prompt", "test task"] + extra,
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=os.environ.copy())
for _ in range(1000):
    if (stub / "split-captured.ready").exists():
        break
    time.sleep(0.01)
else:
    proc.kill()
    raise AssertionError("launcher did not reach the identity-capture barrier")
proc.send_signal(signal.SIGTERM)
stdout, stderr = proc.communicate(timeout=30)
if proc.returncode == 0:
    raise AssertionError("signaled launcher returned success")
calls = (stub / "calls.log").read_text()
if "pane close wT:p9" not in calls:
    raise AssertionError("created pane was left running: %s | %s" % (calls, stderr))
if "pane report-metadata" in calls or "agent start" in calls:
    raise AssertionError("signal crossed the ownership publication barrier: %s" % calls)
if "manual cleanup" in stderr:
    raise AssertionError("parseable identity was reported as unknown: %s" % stderr)
PY
}

function test_scripts_0801_herdr_child_tab_signal_before_identity_capture() {
  _bats_test_init 0801 'herdr-child tab signal before identity capture closes the created tab root pane'
  # #given — a tab-mode launcher parked between tab create and the identity read
  child_stub_herdr
  # #when — SIGTERM lands inside that window
  run child_signal_before_identity_capture --tab
  # #then — the recovered identity still passes the terminal check and the pane closes
  assert_success
}

function test_scripts_0802_herdr_child_pane_signal_before_identity_capture() {
  _bats_test_init 0802 'herdr-child pane signal before identity capture closes the created pane'
  # #given — a pane-mode launcher parked between pane split and the identity read
  child_stub_herdr
  # #when — SIGTERM lands inside that window
  run child_signal_before_identity_capture ''
  # #then — pane mode recovers the same identity and closes the split pane
  assert_success
}

function test_scripts_0661_herdr_child_tab_created_barrier_is_bounded() {
  _bats_test_init 0661 'herdr-child tab launcher held after creation self-terminates and drops the owned tab'
  # #given — a tab-mode launcher parked at the post-create ownership barrier
  child_stub_herdr
  local launcher_pid launcher_status attempt=0
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_WORKSPACE_ID=w1 STUB_START_CONTEXT=1 \
    HERDR_CHILD_TEST_TAB_CREATED_BARRIER="$CHILD_STUB/tab-created" \
    HERDR_CHILD_TEST_HOLD_TIMEOUT_SECONDS=1 \
    bash "$HERDR_CHILD" start --kind claude --tab --wait --prompt "test task" \
    >"$CHILD_STUB/tab-created.out" 2>"$CHILD_STUB/tab-created.err" &
  launcher_pid=$!
  child_wait_for_file "$CHILD_STUB/tab-created.ready"

  # #when — the harness dies without ever writing the release signal
  while kill -0 "$launcher_pid" 2>/dev/null && [ "$attempt" -lt 400 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done

  # #then — the launcher leaves the process table without stranding a half-created tab
  if kill -0 "$launcher_pid" 2>/dev/null; then
    kill -KILL "$launcher_pid" 2>/dev/null || true
    wait "$launcher_pid" 2>/dev/null || true
    fail 'tab-created barrier exceeded its test hold bound'
  fi
  if wait "$launcher_pid"; then launcher_status=0; else launcher_status=$?; fi
  assert_equal "$launcher_status" 1
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
  run grep -Eq '^(pane report-metadata|agent start)' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_067_herdr_child_tab_mode_composes_with_detached_supe() {
  _bats_test_init 67 'herdr-child tab mode composes with detached supervision'
  child_lifecycle_stub_herdr
  HERDR_WORKSPACE_ID=w1 run child_lifecycle_start --tab --supervision-timeout 5000
  assert_success
  assert_output --partial '"tab":"wT:tA"'
  assert_output --partial '"supervision":{"status":"armed"'
  assert_file_contains "$CHILD_STUB/calls.log" '^tab create --workspace w1'
  assert_file_contains "$CHILD_STUB/calls.log" 'pane report-metadata wT:p9 --source child-agent-tab.*child-tab=wT:tA'
  assert_file_contains "$CHILD_STUB/calls.log" 'pane report-metadata wT:p9 --source child-agent.*child_mode=detach'
  assert_file_contains "$CHILD_STUB/resource-tree.log" '^record-child --pane wT:p9 --terminal term-child'
}

function test_scripts_068_herdr_child_tab_mode_preserves_malformed_creatio() {
  _bats_test_init 68 'herdr-child tab mode preserves a malformed tab creation without mutating Herdr'
  child_stub_herdr
  STUB_TAB_CREATE_MALFORMED=1 HERDR_WORKSPACE_ID=w1 run child_start \
    --kind claude --tab --wait
  assert_failure 1
  assert_output --partial "tab wT:tA was preserved"
  run grep -Eq '^(pane report-metadata|agent start|pane close)' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_1243_herdr_child_tab_mode_preserves_wrapper_partial_success_without_retrying() {
  _bats_test_init 1243 'herdr-child tab mode preserves wrapper partial success without retrying'
  child_stub_herdr

  STUB_TAB_CREATE_STATUS=70 HERDR_WORKSPACE_ID=w1 run child_start \
    --kind claude --tab --wait
  assert_failure 70
  assert_output --partial '"pane_id":"wT:p9"'
  assert_output --partial 'tab creation returned status 70 after reporting pane wT:p9'
  assert_output --partial 'automatic creation retry is unsafe'
  run grep -Ec '^(tab create|pane report-metadata|agent start|pane close)' "$CHILD_STUB/calls.log"
  assert_success
  assert_output '1'
  assert_file_not_exists "$CHILD_STUB/resource-tree.log"
}

function test_scripts_0681_herdr_child_tab_mode_cleans_owned_pane_on_repor() {
  _bats_test_init 0681 'herdr-child tab mode cleans its owned pane when recording tab ownership fails'
  child_stub_herdr
  STUB_REPORT_FAIL=1 HERDR_WORKSPACE_ID=w1 run child_start \
    --kind claude --tab --wait
  assert_failure 1
  assert_output --partial "could not record tab ownership"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
  run grep -q '^agent start' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_069_herdr_child_tab_mode_reports_the_tab_on_timeout() {
  _bats_test_init 69 'herdr-child tab mode reports the tab coordinates on prompt timeout'
  child_stub_herdr
  STUB_PROMPT_TIMEOUT=1 HERDR_WORKSPACE_ID=w1 run child_start \
    --kind claude --tab --wait
  assert_failure 124
  assert_output --partial "{\"agent\":\"$(child_started_name)\",\"pane\":\"wT:p9\",\"tab\":\"wT:tA\"}"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_0691_herdr_child_tab_mode_names_the_tab_on_launch_fa() {
  _bats_test_init 0691 'herdr-child tab mode names the tab on agent launch failure'
  child_stub_herdr
  STUB_START_MODE=busy HERDR_WORKSPACE_ID=w1 run child_start \
    --kind claude --tab --wait
  assert_failure
  assert_output --partial "three agent start attempts (tab wT:tA)"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

function test_scripts_070_herdr_child_caps_startup_timeout_while_preservin() {
  _bats_test_init 70 'herdr-child caps startup timeout while preserving a long prompt wait'
  child_stub_herdr
  run child_start --kind claude --wait --timeout 1800000
  assert_success
  local start_call prompt_call
  start_call="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  prompt_call="$(grep '^agent prompt' "$CHILD_STUB/calls.log")"
  [[ "$start_call" == *--timeout\ 300000* ]] || fail "startup timeout was not capped: $start_call"
  [[ "$prompt_call" == *--timeout\ 1800000* ]] || fail "prompt timeout was not preserved: $prompt_call"
}

function test_scripts_071_herdr_child_retries_only_the_pane_readiness_star() {
  _bats_test_init 71 'herdr-child retries only the pane-readiness start failure'
  child_stub_herdr
  STUB_START_MODE=busy-once run child_start --kind claude --wait
  assert_success
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 2

  child_stub_herdr
  STUB_START_MODE=error run child_start --kind claude --wait
  assert_failure
  assert_output --partial "agent start failed"
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 1
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

function test_scripts_072_herdr_child_closes_its_pane_after_three_readines() {
  _bats_test_init 72 'herdr-child closes its pane after three readiness failures'
  child_stub_herdr
  STUB_START_MODE=busy run child_start --kind claude --wait
  assert_failure
  assert_output --partial "three agent start attempts"
  run grep -c '^agent start' "$CHILD_STUB/calls.log"
  assert_output 3
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p9'
}

function test_scripts_073_herdr_child_preserves_the_child_when_the_initia() {
  _bats_test_init 73 'herdr-child preserves the child when the initial prompt stalls'
  # herdr says agent_prompt_stalled does not prove the prompt was never
  # delivered, so this takes the same route as test 74's timeout: the pane a
  # working child may be sitting in must survive, and the caller is handed the
  # coordinates to recover it.
  child_stub_herdr
  STUB_PROMPT_FAIL=1 run child_start --kind claude --wait
  assert_failure 124
  assert_output --partial "{\"agent\":\"$(child_started_name)\",\"pane\":\"wT:p9\"}"
  assert_output --partial "initial prompt stalled"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_0731_herdr_child_waits_for_cold_agents_before_baseli() {
  _bats_test_init 0731 'herdr-child waits for cold agents before baseline and initial prompt'
  local kind launch_pid launch_status
  for kind in opencode pi; do
    child_stub_herdr
    cat > "$CHILD_STUB/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = 3 ]; then
  : > "$CHILD_STUB/cold-settle.ready"
  attempt=0
  while [ ! -e "$CHILD_STUB/cold-settle.release" ]; do
    [ -d "$CHILD_STUB" ] || exit 1
    attempt=$((attempt + 1))
    [ "$attempt" -lt 1000 ] || exit 1
    /bin/sleep 0.01
  done
  : > "$CHILD_STUB/cold-settled"
else
  /bin/sleep "$@"
fi
SH
    chmod +x "$CHILD_STUB/sleep"

    if [ "$kind" = pi ]; then
      STUB_REQUIRE_COLD_SETTLE=1 child_start_with_default_initial_delay \
        --kind pi --posture rw --wait >"$CHILD_STUB/launch.out" 2>&1 &
    else
      STUB_REQUIRE_COLD_SETTLE=1 child_start_with_default_initial_delay \
        --kind opencode --wait >"$CHILD_STUB/launch.out" 2>&1 &
    fi
    launch_pid=$!
    child_wait_for_file "$CHILD_STUB/cold-settle.ready"
    assert_file_not_exists "$CHILD_STUB/prompt-seen"
    : > "$CHILD_STUB/cold-settle.release"
    if wait "$launch_pid"; then launch_status=0; else launch_status=$?; fi
    assert_equal 0 "$launch_status"
    assert_file_exists "$CHILD_STUB/cold-settled"
    run grep -q '^pane close' "$CHILD_STUB/calls.log"
    assert_failure
  done

  child_stub_herdr
  cat > "$CHILD_STUB/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = 1 ]; then
  : > "$CHILD_STUB/configured-settle.ready"
  attempt=0
  while [ ! -e "$CHILD_STUB/configured-settle.release" ]; do
    [ -d "$CHILD_STUB" ] || exit 1
    attempt=$((attempt + 1))
    [ "$attempt" -lt 1000 ] || exit 1
    /bin/sleep 0.01
  done
  : > "$CHILD_STUB/cold-settled"
else
  /bin/sleep "$@"
fi
SH
  chmod +x "$CHILD_STUB/sleep"
  HERDR_CHILD_COLD_INITIAL_PROMPT_DELAY=1 STUB_REQUIRE_COLD_SETTLE=1 \
    child_start --kind opencode --wait >"$CHILD_STUB/launch.out" 2>&1 &
  launch_pid=$!
  child_wait_for_file "$CHILD_STUB/configured-settle.ready"
  assert_file_not_exists "$CHILD_STUB/prompt-seen"
  : > "$CHILD_STUB/configured-settle.release"
  if wait "$launch_pid"; then launch_status=0; else launch_status=$?; fi
  assert_equal 0 "$launch_status"

  child_stub_herdr
  cat > "$CHILD_STUB/sleep" <<'SH'
#!/usr/bin/env bash
: > "$CHILD_STUB/unexpected-settle"
SH
  chmod +x "$CHILD_STUB/sleep"
  run child_start_with_default_initial_delay --kind claude --wait
  assert_success
  assert_file_not_exists "$CHILD_STUB/unexpected-settle"

  child_stub_herdr
  cat > "$CHILD_STUB/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = 3 ]; then
  printf 'sleep %s\n' "$1" >> "$CHILD_STUB/calls.log"
  : > "$CHILD_STUB/cold-settle.ready"
  attempt=0
  while [ ! -e "$CHILD_STUB/cold-settle.release" ]; do
    [ -d "$CHILD_STUB" ] || exit 1
    attempt=$((attempt + 1))
    [ "$attempt" -lt 1000 ] || exit 1
    /bin/sleep 0.01
  done
else
  /bin/sleep "$@"
fi
SH
  chmod +x "$CHILD_STUB/sleep"
  child_start_with_default_initial_delay --kind pi --posture rw --detach \
    >"$CHILD_STUB/launch.out" 2>&1 &
  launch_pid=$!
  child_wait_for_file "$CHILD_STUB/cold-settle.ready"
  run grep -q '^agent get' "$CHILD_STUB/calls.log"
  assert_failure
  : > "$CHILD_STUB/cold-settle.release"
  if wait "$launch_pid"; then launch_status=0; else launch_status=$?; fi
  assert_equal 0 "$launch_status"
  local sleep_line baseline_line
  sleep_line="$(grep -n '^sleep 3$' "$CHILD_STUB/calls.log" | cut -d: -f1)"
  baseline_line="$(grep -n '^agent get' "$CHILD_STUB/calls.log" | cut -d: -f1)"
  [ "$sleep_line" -lt "$baseline_line" ] || \
    fail "cold settle must precede detached baseline: sleep=$sleep_line baseline=$baseline_line"

  child_stub_herdr
  cat > "$CHILD_STUB/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = 3 ]; then
  printf 'replacement-session\n' > "$CHILD_STUB/child-session"
fi
SH
  chmod +x "$CHILD_STUB/sleep"
  run child_start_with_default_initial_delay --kind opencode --wait
  assert_failure
  assert_output --partial "child session changed during startup grace"
  run grep -Eq '^(agent prompt|pane close)' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_0732_stub_teardown_reaps_a_watcher_from_every_stub_a() {
  _bats_test_init 0732 'stub teardown reaps a watcher from every stub a test created, not only the last'
  local first second probe probe_pid attempt
  child_stub_herdr
  first="$CHILD_STUB"
  probe="$first/state/runs/probe"
  mkdir -p "$probe"
  # Stands in for the watcher a detached launch arms: the same command line,
  # so the same reap has to find it, without a launch's timing. It borrows the
  # shipped descriptor hygiene, or a regression here would hold the runner's
  # capture pipe and stall the suite instead of failing this case.
  printf '#!/usr/bin/env bash\nsource %s\n' \
    "$SOURCE_ROOT/dot_local/lib/herdr-process.sh" > "$probe/herdr-child"
  cat >> "$probe/herdr-child" <<'SH'
close_inherited_descriptors
# Deliberately a hold that deleting the run directory does not end: that is
# the shape teardown cannot reap by rm -rf alone (incident 4 in
# docs/solutions/design-patterns/outliving-processes-hang-the-suite.md), so it
# is the shape that holds the sweep to its job. The absolute bound keeps a red
# run from leaking this for an hour.
attempt=0
while [ "$attempt" -lt 1200 ]; do
  attempt=$((attempt + 1))
  /bin/sleep 0.05
done
SH
  chmod +x "$probe/herdr-child"
  # Orphaned on purpose: a real watcher is nohup'd away from its launcher, and
  # a child of this shell would still answer kill -0 as a zombie once dead.
  # The pid lands outside *.pid so only the process-table sweep can find it.
  ( bash "$probe/herdr-child" __watcher --run-dir "$probe" \
      --pane wT:p9 --generation probe --timeout 3600000 --launcher-pid $$ \
      </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$first/probe.watcher" )
  child_wait_for_file "$first/probe.watcher"
  probe_pid="$(cat "$first/probe.watcher")"
  kill -0 "$probe_pid" 2>/dev/null || fail 'the probe watcher never started'

  # The next launch re-points CHILD_STUB away from the armed stub. What runs
  # below is the suite's real teardown, called early so the case can hold it
  # to its verdict; bashunit calling it again afterwards is a no-op.
  child_stub_herdr
  second="$CHILD_STUB"
  [ "$first" != "$second" ] || fail 'the second stub reused the first directory'

  teardown

  attempt=0
  while kill -0 "$probe_pid" 2>/dev/null && [ "$attempt" -lt 200 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  run kill -0 "$probe_pid"
  assert_failure
  assert_dir_not_exists "$first"
  assert_dir_not_exists "$second"
}

function test_scripts_074_herdr_child_preserves_a_working_pane_when_the_wa() {
  _bats_test_init 74 'herdr-child preserves a working pane when the wait times out'
  child_stub_herdr
  STUB_PROMPT_TIMEOUT=1 run child_start --kind claude --wait
  assert_failure 124
  assert_output --partial "{\"agent\":\"$(child_started_name)\",\"pane\":\"wT:p9\"}"
  assert_output --partial "wait timed out"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_075_herdr_child_ask_requires_every_injected_child_co() {
  _bats_test_init 75 'herdr-child ask requires every injected child coordinate'
  child_stub_herdr
  local marker
  for marker in '' 0 invalid; do
    run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
      HERDR_CHILD_LAUNCH="$marker" HERDR_CHILD_NAME=legacy-name HERDR_CHILD_PARENT_PANE=wT:p0 \
      bash "$HERDR_CHILD" ask question
    assert_failure
    assert_output --partial "HERDR_CHILD_LAUNCH must be 1"
    [ ! -f "$CHILD_STUB/calls.log" ]
  done
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_PARENT_PANE=wT:p0 bash "$HERDR_CHILD" ask question
  assert_failure
  assert_output --partial "HERDR_CHILD_LAUNCH must be 1"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_LAUNCH=1 bash "$HERDR_CHILD" ask question
  assert_failure
  assert_output --partial "HERDR_CHILD_PARENT_PANE is missing"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 \
    HERDR_CHILD_LAUNCH=1 HERDR_CHILD_PARENT_PANE=wT:p0 bash "$HERDR_CHILD" ask question
  assert_failure
  assert_output --partial "HERDR_PANE_ID is missing"
  [ ! -f "$CHILD_STUB/calls.log" ]
}

function test_scripts_076_herdr_child_ask_publishes_before_delivery_and_us() {
  _bats_test_init 76 'herdr-child ask publishes before delivery and uses the versioned marker'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p0","terminal_id":"term-parent","revision":1,"state_change_seq":1},{"name":"orange-panda","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 \
    HERDR_PANE_ID=wT:p9 HERDR_CHILD_LAUNCH=1 HERDR_CHILD_PARENT_PANE=wT:p0 \
    bash "$HERDR_CHILD" ask "Which path?"
  assert_success
  local call1 call2 call3 call4
  call1="$(sed -n '1p' "$CHILD_STUB/calls.log")"
  call2="$(sed -n '2p' "$CHILD_STUB/calls.log")"
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  call4="$(sed -n '4p' "$CHILD_STUB/calls.log")"
  [[ "$call1" == pane\ report-metadata*wT:p9*--source\ child-agent*--state-label*--ttl-ms\ 3600000* ]] || fail "waiting label was not published first: $call1"
  [[ "$call2" == agent\ list* ]] || fail "live aliases were not read second: $call2"
  [[ "$call3" == pane\ get*wT:p9* ]] || fail "child metadata was not read third: $call3"
  [[ "$call4" == agent\ prompt*wT:p0*child-ask*agent=orange-panda*pane=wT:p9* ]] || fail "callback was not delivered fourth: $call4"
  [[ "$call4" != *--wait* ]] || fail "callback delivery unexpectedly waited: $call4"

  # Pre-migration managed children retain the old name; its value is never a route.
  # A new managed child may inherit it too, but uses the explicit marker.
  local marker
  local -a launch_env
  for marker in managed legacy; do
    child_stub_herdr
    launch_env=(-u HERDR_CHILD_LAUNCH)
    [ "$marker" != managed ] || launch_env=(HERDR_CHILD_LAUNCH=1)
    run env "${launch_env[@]}" PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 \
      HERDR_PANE_ID=wT:p9 HERDR_CHILD_NAME=stale-launch-name HERDR_CHILD_PARENT_PANE=wT:p0 \
      bash "$HERDR_CHILD" ask "Which path?"
    assert_success
    assert_file_contains "$CHILD_STUB/calls.log" 'agent prompt wT:p0.*agent=orange-panda'
  done
}

function test_scripts_077_herdr_child_ask_leaves_the_label_when_parent_loo() {
  _bats_test_init 77 'herdr-child ask leaves the label when parent lookup or delivery fails'
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_LAUNCH=1 HERDR_CHILD_PARENT_PANE=wT:p0 \
    bash "$HERDR_CHILD" ask question
  assert_failure
  assert_file_contains "$CHILD_STUB/calls.log" '^pane report-metadata'
  run grep -q 'clear-state-labels' "$CHILD_STUB/calls.log"
  assert_failure

  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"parent","pane_id":"wT:p0"}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PROMPT_FAIL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p9 HERDR_CHILD_LAUNCH=1 HERDR_CHILD_PARENT_PANE=wT:p0 \
    bash "$HERDR_CHILD" ask question
  assert_failure
  assert_output --partial "waiting label remains published"
}

function test_scripts_078_herdr_child_reply_validates_the_live_pair_delive() {
  _bats_test_init 78 'herdr-child reply validates the live pair, delivers, then clears'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"orange-panda","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reply --to orange-panda --pane wT:p9 "Use path A"
  assert_success
  local call2 call3 call4
  call2="$(sed -n '2p' "$CHILD_STUB/calls.log")"
  call3="$(sed -n '3p' "$CHILD_STUB/calls.log")"
  call4="$(sed -n '4p' "$CHILD_STUB/calls.log")"
  [[ "$call2" == pane\ get*wT:p9* ]] || fail "child metadata was not read before reply: $call2"
  [[ "$call3" == agent\ prompt*parent-reply*pane=wT:p0* ]] || fail "reply was not delivered after validation: $call3"
  [[ "$call4" == pane\ report-metadata*wT:p9*--clear-state-labels* ]] || fail "waiting label was not cleared after delivery: $call4"

  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_REPORT_FAIL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reply --to orange-panda --pane wT:p9 decision
  assert_failure
  assert_output --partial "reply delivered to orange-panda in wT:p9"
  assert_output --partial "waiting label could not be cleared"

  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reply --to orange-panda --pane wT:p8 decision
  assert_failure
  run grep -q '^agent prompt' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_079_herdr_child_ask_and_reply_publish_strictly_incre() {
  _bats_test_init 79 'herdr-child ask and reply publish strictly increasing label sequences'
  child_stub_herdr
  local parent_agents='{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p0","terminal_id":"term-parent","revision":1,"state_change_seq":1},{"name":"orange-panda","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10}]}}'
  env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$parent_agents" HERDR_ENV=1 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_TEST_NOW_SEQ=200 \
    HERDR_PANE_ID=wT:p9 HERDR_CHILD_LAUNCH=1 HERDR_CHILD_PARENT_PANE=wT:p0 \
    bash "$HERDR_CHILD" ask question >/dev/null
  local child_agents='{"result":{"agents":[{"name":"orange-panda","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10}]}}'
  env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$child_agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" HERDR_CHILD_TEST_NOW_SEQ=100 \
    bash "$HERDR_CHILD" reply --to orange-panda --pane wT:p9 decision >/dev/null
  local first_seq second_seq
  first_seq="$(grep '^pane report-metadata' "$CHILD_STUB/calls.log" | sed -n '1s/.*--seq \([0-9]*\).*/\1/p')"
  second_seq="$(grep '^pane report-metadata' "$CHILD_STUB/calls.log" | sed -n '2s/.*--seq \([0-9]*\).*/\1/p')"
  run test -n "$first_seq"
  assert_success
  run test "$second_seq" -gt "$first_seq"
  assert_success
}

function test_scripts_080_herdr_child_reply_keeps_the_label_when_delivery() {
  _bats_test_init 80 'herdr-child reply keeps the label when delivery fails and refuses child callers'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"orange-panda","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PROMPT_FAIL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reply --to orange-panda --pane wT:p9 decision
  assert_failure
  run grep -q 'clear-state-labels' "$CHILD_STUB/calls.log"
  assert_failure

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_PARENT_PANE=wT:p0 bash "$HERDR_CHILD" reply --to orange-panda --pane wT:p9 decision
  assert_failure
  assert_output --partial "parent-side"
}

function test_scripts_101_herdr_child_reap_closes_an_unfocused_idle_pane() {
  _bats_test_init 101 'herdr-child reap closes an unfocused idle pane'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"idle-a","pane_id":"wT:p1","terminal_id":"term-child","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --to idle-a --pane wT:p1
  assert_success
  assert_output --partial "idle-a: closed pane wT:p1"
  refute_output --partial "--pane: skipped"
  run grep -c '^pane close wT:p1' "$CHILD_STUB/calls.log"
  assert_output 1
}

function test_scripts_102_herdr_child_reap_rejects_an_empty_expected_pane() {
  _bats_test_init 102 'herdr-child reap rejects an empty expected pane'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"idle-a","pane_id":"wT:p1","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --to idle-a --pane ""
  assert_failure 2
  assert_output --partial "reap requires --pane"
  assert_file_not_exists "$CHILD_STUB/calls.log"
}

function test_scripts_103_herdr_child_reap_preserves_a_reused_name_outside() {
  _bats_test_init 103 'herdr-child reap preserves a reused name outside the expected pane'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"reused-a","pane_id":"wT:p2","terminal_id":"term-child","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --to reused-a --pane wT:p1
  assert_success
  assert_output --partial "reused-a: kept; expected pane wT:p1, current pane is wT:p2"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_104_herdr_child_reap_preserves_a_pane_when_fresh_sta() {
  _bats_test_init 104 'herdr-child reap preserves a pane when fresh state no longer matches'
  child_stub_herdr
  local initial='{"result":{"agents":[{"name":"stale-a","pane_id":"wT:p1","terminal_id":"term-child","agent_status":"done","focused":false}]}}'
  local fresh='{"result":{"agents":[{"name":"stale-a","pane_id":"wT:p2","terminal_id":"term-child","agent_status":"done","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON_FIRST="$initial" STUB_AGENTS_JSON_SECOND="$fresh" \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to stale-a --pane wT:p1
  assert_success
  assert_output --partial "stale-a: kept; child name and pane no longer identify the same live agent"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_086_herdr_child_reap_refuses_outside_herdr_and_from() {
  _bats_test_init 86 'herdr-child reap refuses outside herdr and from a child pane'
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV= HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --to orange-panda --pane wT:p9
  assert_failure 1
  assert_output --partial 'requires HERDR_ENV=1'
  # The refusal is only a refusal if nothing reached herdr first.
  assert_file_not_exists "$CHILD_STUB/calls.log"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p9 \
    HERDR_CHILD_PARENT_PANE=wT:p0 bash "$HERDR_CHILD" reap --to orange-panda --pane wT:p9
  assert_failure
  assert_output --partial "parent-side"
}

function test_scripts_087_herdr_child_reap_preserves_a_settled_pane_with_a() {
  _bats_test_init 87 'herdr-child reap preserves a settled pane with a waiting label'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"wait-a","pane_id":"wT:p1","terminal_id":"term-child","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_LABEL=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to wait-a --pane wT:p1
  assert_success
  assert_output --partial "has a waiting state label"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_088_herdr_child_reap_preserves_a_settled_pane_when_p() {
  _bats_test_init 88 'herdr-child reap preserves a settled pane when pane metadata is malformed'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"bad-meta-a","pane_id":"wT:p1","terminal_id":"term-child","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PANE_GET_MALFORMED=1 \
    HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to bad-meta-a --pane wT:p1
  assert_success
  assert_output --partial "bad-meta-a: kept; pane metadata could not be read"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_089_herdr_child_reap_closes_a_positively_owned_one_p() {
  _bats_test_init 89 'herdr-child reap closes a positively owned one-pane tab'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"tab-a","pane_id":"wT:p1","terminal_id":"term-child","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PANE_TAB_ID=wT:tA \
    STUB_TAB_GET_FAIL=1 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to tab-a --pane wT:p1
  assert_success
  assert_output --partial "tab-a: closed pane wT:p1 and tab wT:tA"
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p1'
  assert_file_contains "$CHILD_STUB/calls.log" '^tab get wT:tA'
}

function test_scripts_090_herdr_child_reap_closes_the_child_pane_but_repor() {
  _bats_test_init 90 'herdr-child reap closes the child pane but reports a surviving multi-pane tab'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"tab-a","pane_id":"wT:p1","terminal_id":"term-child","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PANE_TAB_ID=wT:tA \
    STUB_TAB_PANE_COUNT=2 HERDR_ENV=1 HERDR_PANE_ID=wT:p0 bash "$HERDR_CHILD" reap --to tab-a --pane wT:p1
  assert_success
  assert_output --partial "tab-a: closed pane wT:p1; tab wT:tA kept with 2 panes"
  # The line is a report; these two are the acts it reports. A reap that printed
  # the line and then took the tab with the siblings in it would pass without
  # them.
  assert_file_contains "$CHILD_STUB/calls.log" '^pane close wT:p1'
  run grep -q '^tab close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_091_herdr_child_reap_preserves_ambiguous_tab_ownersh() {
  _bats_test_init 91 'herdr-child reap preserves ambiguous tab ownership'
  child_stub_herdr
  local agents='{"result":{"agents":[{"name":"tab-a","pane_id":"wT:p1","terminal_id":"term-child","agent_status":"idle","focused":false}]}}'
  run env PATH="$CHILD_STUB:$PATH" STUB_AGENTS_JSON="$agents" STUB_PANE_TAB_ID=wT:tA \
    STUB_PANE_CHILD_TAB_TOKEN=wT:tOTHER HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    bash "$HERDR_CHILD" reap --to tab-a --pane wT:p1
  assert_success
  assert_output --partial "tab-a: kept; pane wT:p1 tab ownership is ambiguous"
  run grep -q '^pane close' "$CHILD_STUB/calls.log"
  assert_failure
}

function test_scripts_092_herdr_child_tab_reap_invalidates_detached_superv() {
  _bats_test_init 92 'herdr-child tab reap invalidates detached supervision before close'
  child_lifecycle_stub_herdr
  HERDR_WORKSPACE_ID=w1 run child_lifecycle_start --tab --supervision-timeout 5000
  assert_success
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/require-reap-invalidation"

  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reap --to "$(child_started_name)" --pane wT:p9
  assert_success
  assert_output --partial "closed pane wT:p9 and tab wT:tA"
  assert_file_exists "$CHILD_STUB/reap-invalidation-observed"
  assert_file_not_exists "$CHILD_STUB/close-before-invalidation"
}

# ===========================================
# herdr-peer-alias allocator
# ===========================================

PEER_ALIAS_SCRIPT="$SOURCE_ROOT/dot_local/bin/executable_herdr-peer-alias"
peer_alias_stub() {
  local stub="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stub"
  cat > "$stub/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "agent list") printf '%s\n' "$STUB_AGENT_LIST" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$stub/herdr"
  printf '%s' "$stub"
}

# A peer that cannot be named does not start. The allocator is missing for a
# whole window on a clean machine and after any failed package install, so the
# command degrades to a placeholder instead of refusing to answer.
function test_scripts_1405_herdr_peer_alias_falls_back_to_a_placeholder_alia() {
  _bats_test_init 1405 'herdr-peer-alias falls back to a placeholder alias'
  command -v jq >/dev/null || skip "jq not available"
  local stub
  stub="$(peer_alias_stub)"

  run --separate-stderr env PATH="$stub:$PATH" \
    HERDR_ALIAS_ALLOCATOR="$BATS_TEST_TMPDIR/absent-allocator" \
    STUB_AGENT_LIST='{"result":{"agents":[{"name":"unnamed-alpha","pane_id":"wT:p1"}]}}' \
    bash "$PEER_ALIAS_SCRIPT" peer-seed
  assert_success
  assert_stderr --partial 'alias allocator unavailable'
  # unnamed-alpha is already held by a live agent, so the walk has to skip it
  # rather than hand back a duplicate.
  assert_output 'unnamed-bravo'
}

function test_scripts_1401_herdr_peer_alias_skips_live_and_reserved_aliase() {
  _bats_test_init 1401 'herdr-peer-alias skips live and reserved aliases'
  command -v jq >/dev/null || skip "jq not available"
  local seed="claude|peer-alias-suite|$BATS_TEST_TMPDIR"
  local stub
  stub="$(peer_alias_stub)"
  # tests/helpers/herdr_alias_allocator answers every seed with the same fixed
  # pool: red-wolf blue-fox green-otter amber-badger silver-koala purple-raven.
  # The literals are written out rather than read back from the allocator, so an
  # allocator that started printing something else fails this test instead of
  # relabelling its own expectation.
  run env PATH="$stub:$PATH" \
    STUB_AGENT_LIST='{"result":{"agents":[{"name":"red-wolf","pane_id":"wT:p1"},{"name":null,"pane_id":"wT:p2"}]}}' \
    bash "$PEER_ALIAS_SCRIPT" "$seed" blue-fox
  assert_success
  assert_output green-otter
}

# An agent record missing pane_id is a truncated list: its alias may be live
# and invisible here, so handing out any alias risks a duplicate registration.
function test_scripts_1402_herdr_peer_alias_fails_closed_on_an_incomplete_() {
  _bats_test_init 1402 'herdr-peer-alias fails closed on an incomplete agent list'
  command -v jq >/dev/null || skip "jq not available"
  local seed="claude|peer-alias-suite|$BATS_TEST_TMPDIR"
  local stub
  stub="$(peer_alias_stub)"

  run env PATH="$stub:$PATH" \
    STUB_AGENT_LIST='{"result":{"agents":[{"name":"amber-badger"}]}}' \
    bash "$PEER_ALIAS_SCRIPT" "$seed"
  assert_failure
  assert_output --partial "malformed herdr agent list"

  run env PATH="$stub:$PATH" \
    STUB_AGENT_LIST='{"result":{}}' \
    bash "$PEER_ALIAS_SCRIPT" "$seed"
  assert_failure
  assert_output --partial "malformed herdr agent list"
}

# herdr-child alias degradation
# ===========================================

herdr_child_alias_stub() {
  local work="$1"
  # $work is what callers register with child_register_stub, so every teardown
  # hook belongs under it: the state dir here, and the release barrier and pid
  # file in herdr_child_alias_launch. Point one at this bin directory instead
  # and that step goes silently inert, leaving the process-table sweep as the
  # only thing still reaping these cases
  # (docs/solutions/design-patterns/outliving-processes-hang-the-suite.md).
  local stub="$work/bin"
  mkdir -p "$stub" "$work/tmp"
  cat > "$stub/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "agent list")
    # Post-registration validation re-reads the list to confirm the alias it
    # was given, so the child has to appear once agent start has accepted it.
    if [ -f "$HCA_WORK/started-name" ]; then
      printf '{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p0","terminal_id":"term-parent","revision":1,"state_change_seq":1,"agent_session":{"value":"parent-session"}},{"name":"%s","agent":"claude","pane_id":"wT:p9","terminal_id":"term-child","revision":1,"state_change_seq":10,"agent_session":{"value":"child-session"}}]}}\n' "$(cat "$HCA_WORK/started-name")"
    else
      printf '{"result":{"agents":[{"name":"parent","agent":"claude","pane_id":"wT:p0","terminal_id":"term-parent","revision":1,"state_change_seq":1,"agent_session":{"value":"parent-session"}}]}}\n'
    fi
    ;;
  "pane split")
    printf '{"result":{"pane":{"pane_id":"wT:p9","terminal_id":"term-child"}}}\n'
    ;;
  "agent start")
    printf '%s' "$3" > "$HCA_WORK/started-name"
    printf '{"result":{"agent":{"interactive_ready":true}}}\n'
    ;;
  "agent get")
    printf '{"result":{"agent":{"name":"%s","pane_id":"wT:p9","terminal_id":"term-child","agent_session":{"value":"child-session"},"agent_status":"working","state_change_seq":10}}}\n' "$(cat "$HCA_WORK/started-name")"
    ;;
  "agent prompt")
    printf '{"result":{"agent":{"agent_status":"working"}}}\n'
    ;;
  "pane report-metadata")
    for arg in "$@"; do
      case "$arg" in
        supervision_generation=*) printf '%s' "${arg#*=}" > "$HCA_WORK/generation" ;;
      esac
    done
    printf '{"result":{"type":"pane_metadata_reported"}}\n'
    ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"wT:p9","terminal_id":"term-child","agent_session":{"value":"child-session"},"tokens":{"supervision_generation":"%s"}}}}\n' "$(cat "$HCA_WORK/generation" 2>/dev/null || true)"
    ;;
  "pane close") : > "$HCA_WORK/pane-closed" ;;
  *) exit 2 ;;
esac
SH
  cat > "$stub/herdr-resource-tree" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = record-child ] || exit 2
printf '{"parent":{"presentation_name":"parent"},"child":{"presentation_name":"child"}}\n'
SH
  chmod +x "$stub/herdr" "$stub/herdr-resource-tree"
  printf '%s' "$stub"
}

herdr_child_alias_launch() {
  local work="$1" allocator="$2" stub="$3"
  env PATH="$stub:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_ALIAS_ALLOCATOR="$allocator" HCA_WORK="$work" TMPDIR="$work/tmp" \
    HERDR_CHILD_STATE_DIR="$work/state" HERDR_CHILD_COLD_INITIAL_PROMPT_DELAY=0 \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$work/watcher.pid" \
    HERDR_CHILD_TEST_WATCHER_RELEASE="$work/release-watcher" \
    bash "$HERDR_CHILD" start --kind claude --detach --prompt 'alias degradation task'
}

# A silent allocator is the common state, not the rare one: chezmoi deploys this
# launcher before the package installs, and every failed install leaves the same
# gap. Losing the pane over a missing decorative name is the regression here.
function test_scripts_1403_herdr_child_starts_with_a_placeholder_when_the_al() {
  _bats_test_init 1403 'herdr-child starts with a placeholder when the alias allocator is silent'
  local work="$BATS_TEST_TMPDIR/child-alias-absent"
  local stub
  child_register_stub "$work"
  stub="$(herdr_child_alias_stub "$work")"

  run --separate-stderr herdr_child_alias_launch "$work" "$work/absent-allocator" "$stub"
  assert_success
  assert_stderr --partial 'alias allocator unavailable'
  assert_file_contains "$work/started-name" '^unnamed-alpha$'
}

# The control: with a working allocator the placeholder path must not engage,
# or the test above would pass for a launcher that ignores the allocator.
function test_scripts_1404_herdr_child_uses_the_allocator_when_it_answers() {
  _bats_test_init 1404 'herdr-child uses the allocator when it answers'
  local work="$BATS_TEST_TMPDIR/child-alias-present"
  local stub
  child_register_stub "$work"
  stub="$(herdr_child_alias_stub "$work")"

  run --separate-stderr herdr_child_alias_launch "$work" \
    "$BATS_TEST_DIRNAME/helpers/herdr_alias_allocator" "$stub"
  assert_success
  refute_stderr --partial 'alias allocator unavailable'
  assert_file_contains "$work/started-name" '^red-wolf$'
}


# ===========================================
# herdr-integrations run-script
# ===========================================

HERDR_INTEGRATIONS_TMPL="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_3-setup-herdr-integrations.sh.tmpl"

function test_scripts_093_herdr_integrations_script_exits_0_and_skips_when() {
  _bats_test_init 93 'herdr-integrations script exits 0 and skips when herdr is absent'
  skip_if_no_chezmoi
  [[ -f "$HERDR_INTEGRATIONS_TMPL" ]] || skip "herdr-integrations script not found"
  BATS_TEST_TMPFILE="$BATS_TEST_TMPDIR/herdr-integrations.sh"
  chezmoi_full_fixture_finite_stdin execute-template < "$HERDR_INTEGRATIONS_TMPL" > "$BATS_TEST_TMPFILE"
  run env PATH="/usr/bin:/bin" bash "$BATS_TEST_TMPFILE"
  assert_success
  assert_output --partial "skipping agent-state integration refresh"
}

function test_scripts_0932_herdr_integrations_template_renders_when_only_a_broken_wrapper_is_on_path() {
  _bats_test_init 932 'herdr-integrations template renders when only a broken wrapper is on PATH'
  skip_if_no_chezmoi
  [[ -f "$HERDR_INTEGRATIONS_TMPL" ]] || skip "herdr-integrations script not found"
  local stub="$BATS_TEST_TMPDIR/wrapper-only" chezmoi_dir
  chezmoi_dir="$(dirname "$(command -v chezmoi)")"
  mkdir -p "$stub"
  cat > "$stub/herdr" <<'SH'
#!/bin/sh
exit 127
SH
  chmod +x "$stub/herdr"

  PATH="$stub:$chezmoi_dir:/usr/bin:/bin" run --separate-stderr \
    chezmoi_full_fixture_finite_stdin execute-template < "$HERDR_INTEGRATIONS_TMPL"
  assert_success
  assert_output --partial '# herdr version:'
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/herdr-integrations-wrapper-only.sh"

  run env PATH="$stub:/usr/bin:/bin" bash "$BATS_TEST_TMPDIR/herdr-integrations-wrapper-only.sh"
  assert_success
  assert_output --partial 'skipping agent-state integration refresh'
}

# Present leg of 093's pair: with herdr on PATH the refresh must actually issue
# one `integration install <target>` per agent client. The stub records argv,
# so the oracle is what herdr received at runtime, not the script's source.
function test_scripts_0931_herdr_integrations_script_installs_each_target_() {
  _bats_test_init 931 'herdr-integrations script installs each integration target when herdr is present'
  skip_if_no_chezmoi
  [[ -f "$HERDR_INTEGRATIONS_TMPL" ]] || skip "herdr-integrations script not found"
  local rendered="$BATS_TEST_TMPDIR/herdr-integrations.sh"
  # Render status first: a partial render written straight to the file could
  # still emit the expected calls and mask a broken deployment template.
  run --separate-stderr chezmoi_full_fixture_finite_stdin execute-template < "$HERDR_INTEGRATIONS_TMPL"
  assert_success
  printf '%s\n' "$output" > "$rendered"

  local stub="$BATS_TEST_TMPDIR/stub" calls="$BATS_TEST_TMPDIR/herdr-calls.log"
  mkdir -p "$stub"
  cat > "$stub/herdr" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$calls"
STUB
  chmod +x "$stub/herdr"

  run env PATH="$stub:/usr/bin:/bin" bash "$rendered"
  assert_success
  assert_output --partial "Refreshed herdr agent-state integrations"

  assert_file_contains "$calls" '^integration install claude$'
  assert_file_contains "$calls" '^integration install pi$'
  assert_file_contains "$calls" '^integration install opencode$'
}

# ===========================================
# Claude Code PreToolUse hooks
# ===========================================
#
# One shim serves every tool-call policy through the shared dispatch core, so
# these cases drive the shim end to end rather than a per-policy script. The
# shim resolves the core through $HOME; pointing a temporary home at this
# checkout runs the source under test instead of whatever is deployed, which is
# what keeps this suite a source-tree gate.

HOOKS_DIR="$SOURCE_ROOT/private_dot_claude/hooks"
AGENT_HOOKS_SHIM="$HOOKS_DIR/agent-hooks-dispatch.sh"
AGENT_HOOKS_CORE="$SOURCE_ROOT/dot_local/lib/agent-hooks"

agent_hooks_checkout_home() {
  local root="$BATS_TEST_TMPDIR/agent-hooks-home"
  mkdir -p "$root/.local/lib"
  ln -sfn "$AGENT_HOOKS_CORE" "$root/.local/lib/agent-hooks"
  printf '%s' "$root"
}

# The shim exits 0 silently whenever bun is missing, so every case below would
# be green and vacuous without this gate.
require_bun_for_shim() {
  command_exists bun || skip "bun not available"
}

function test_scripts_094_dispatcher_denies_a_fff_query_of_several_bare_wo() {
  _bats_test_init 94 'dispatcher denies a fff query of several bare words'
  require_bun_for_shim
  run env HOME="$(agent_hooks_checkout_home)" bash "$AGENT_HOOKS_SHIM" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"TODO FIXME scheduling launchd cron"}}
EOF
  assert_success
  assert_output --partial "fff-grep-guard:"
  # R9 wants a named alternative, not a client's spelling of one. The reason is
  # shown to every client the policy is applicable to, so pinning Claude's
  # mcp__fff__multi_grep here would re-assert the bug that made an OpenCode deny
  # point at a tool OpenCode does not have.
  assert_output --partial "fff multi-grep tool"
  # The decision is a field of a document the client parses, not a line of text.
  # A substring match on the pretty-printed pair pins this shim's whitespace and
  # would still pass with the value filed under the wrong key.
  run python3 -c '
import json, sys
hook = json.loads(sys.argv[1])["hookSpecificOutput"]
if hook.get("permissionDecision") != "deny":
    raise SystemExit("permissionDecision is %r" % (hook.get("permissionDecision"),))
' "$output"
  assert_success
}

function test_scripts_095_dispatcher_stays_silent_on_a_single_identifier() {
  _bats_test_init 95 'dispatcher stays silent on a single fff identifier'
  require_bun_for_shim
  run env HOME="$(agent_hooks_checkout_home)" bash "$AGENT_HOOKS_SHIM" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"AGENT_PROFILES"}}
EOF
  assert_success
  assert_output ""
}

# Path-scoped and glob-scoped queries were the multi-token calls that actually
# returned hits, so the guard must let them through.
function test_scripts_096_dispatcher_stays_silent_on_a_path_scoped_or_glob() {
  _bats_test_init 96 'dispatcher stays silent on a path-scoped or glob-scoped fff query'
  require_bun_for_shim
  local fake_home
  fake_home="$(agent_hooks_checkout_home)"
  run env HOME="$fake_home" bash "$AGENT_HOOKS_SHIM" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"KnowledgeContextField console/"}}
EOF
  assert_success
  assert_output ""
  run env HOME="$fake_home" bash "$AGENT_HOOKS_SHIM" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"useRouter *.tsx"}}
EOF
  assert_success
  assert_output ""
}

function test_scripts_097_dispatcher_fails_open_on_malformed_input() {
  _bats_test_init 97 'dispatcher fails open on malformed input'
  require_bun_for_shim
  run env HOME="$(agent_hooks_checkout_home)" bash "$AGENT_HOOKS_SHIM" <<<'not json at all'
  assert_success
  assert_output ""
}

function test_scripts_098_dispatcher_adds_context_for_a_plain_webfetch_url() {
  _bats_test_init 98 'dispatcher adds context for a plain WebFetch URL'
  require_bun_for_shim
  run env HOME="$(agent_hooks_checkout_home)" bash "$AGENT_HOOKS_SHIM" <<'EOF'
{"tool_name":"WebFetch","tool_input":{"url":"https://example.com/docs"}}
EOF
  assert_success
  # Both halves read out of the parsed document: a bare '"additionalContext"'
  # substring passes on the key name appearing anywhere, including inside a
  # string, and the absent-decision half is the discriminator -- a context-only
  # policy routed through a deny would turn a hint into a wall.
  run python3 -c '
import json, sys
hook = json.loads(sys.argv[1])["hookSpecificOutput"]
if "permissionDecision" in hook:
    raise SystemExit("context-only policy carries a decision: %r" % (hook["permissionDecision"],))
context = hook.get("additionalContext")
if context is None or "/markdown-new" not in context:
    raise SystemExit("additionalContext does not name the skill: %r" % (context,))
' "$output"
  assert_success
}

function test_scripts_099_dispatcher_stays_silent_when_the_url_already_uses() {
  _bats_test_init 99 'dispatcher stays silent when the URL already uses markdown.new'
  require_bun_for_shim
  run env HOME="$(agent_hooks_checkout_home)" bash "$AGENT_HOOKS_SHIM" <<'EOF'
{"tool_name":"WebFetch","tool_input":{"url":"https://markdown.new/https://example.com/docs"}}
EOF
  assert_success
  assert_output ""
}

# The two sides compared here are independent by construction: the matcher set
# comes from the rendered settings template, the tool names from the core's one
# machine-readable registry export (KTD6). Adding a tool to either side alone
# turns this red, which is the whole point — a policy deployed behind a matcher
# nobody wired is silently dead.
function test_scripts_100_claude_matchers_equal_the_registry_tool_union() {
  _bats_test_init 100 'Claude PreToolUse matchers equal the registry Claude tool union'
  skip_if_no_chezmoi
  if ! command_exists bun; then
    # bun is a cross-platform Brewfile dependency baked into the Docker image
    # the authoritative gate runs, so its absence there is a broken environment,
    # not a reason to drop the only check binding wiring to the registry.
    case "$(mms_disposable_home_verdict)" in
      run)
        fail "bun is missing inside a disposable-home gate, where it is a declared Brewfile dependency. The registry/matcher union check cannot skip here -- it is the check make test-ubuntu owns."
        return 1
        ;;
      *) skip "bun not available" ;;
    esac
  fi
  assert_file_exists "$AGENT_HOOKS_SHIM"

  local tmpl="$SOURCE_ROOT/private_dot_claude/private_settings.json.tmpl"
  local rendered="$BATS_TEST_TMPDIR/claude-settings.json"
  local snapshot="$BATS_TEST_TMPDIR/agent-hooks-registry.json"
  chezmoi_full_fixture_finite_stdin execute-template < "$tmpl" > "$rendered"

  run env AGENT_HOOKS_CORE="$AGENT_HOOKS_CORE" bun --eval '
const { registrySnapshot } = await import(`${process.env.AGENT_HOOKS_CORE}/registry.ts`);
process.stdout.write(JSON.stringify(registrySnapshot()));
'
  assert_success
  printf '%s' "$output" > "$snapshot"

  run python3 - "$rendered" "$snapshot" <<'PY'
import json, sys

settings = json.load(open(sys.argv[1]))
snapshot = json.load(open(sys.argv[2]))

claude = next(c for c in snapshot["clients"] if c["client"] == "claude")
registry_tools = set(claude["tools"])
assert registry_tools, snapshot

entries = settings["hooks"]["PreToolUse"]
shim_entries = [
    e for e in entries
    if any("agent-hooks-dispatch.sh" in h["command"] for h in e["hooks"])
]
assert shim_entries, entries

wired = set()
for entry in shim_entries:
    wired.update(entry["matcher"].split("|"))

assert wired >= registry_tools, ("registry tools with no matcher", sorted(registry_tools - wired))
assert registry_tools >= wired, ("matcher alternatives absent from the registry", sorted(wired - registry_tools))

# Every PreToolUse entry runs through the one shim: a surviving per-policy hook
# would enforce a second copy of a policy the registry no longer describes.
assert len(shim_entries) == len(entries), [e["matcher"] for e in entries]
PY
  assert_success
}

function test_scripts_101_shim_exits_0_silently_when_bun_is_absent_from_pat() {
  _bats_test_init 101 'dispatch shim exits 0 silently when bun is absent from PATH'
  run env HOME="$(agent_hooks_checkout_home)" PATH="/usr/bin:/bin" bash "$AGENT_HOOKS_SHIM" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"TODO FIXME scheduling launchd cron"}}
EOF
  assert_success
  assert_output ""
}

# The same known-bad input test_scripts_094 denies: with the core file gone the
# shim must let it through, and say nothing while doing so. A degraded state
# that printed would put a line of noise on every matched tool call.
function test_scripts_102_shim_exits_0_silently_when_the_core_file_is_absen() {
  _bats_test_init 102 'dispatch shim exits 0 silently when the deployed core file is absent'
  require_bun_for_shim
  local empty_home="$BATS_TEST_TMPDIR/agent-hooks-empty-home"
  mkdir -p "$empty_home"
  run env HOME="$empty_home" bash "$AGENT_HOOKS_SHIM" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"TODO FIXME scheduling launchd cron"}}
EOF
  assert_success
  assert_output ""
}

# R4 names a failed core import as its own fail-open path, and test_scripts_102
# cannot reach it: deleting claude.ts makes the shim's `[ -f "$core" ]` return
# before bun ever attempts the import. The adapter's own guard needs a core that
# is present and unimportable. claude.ts imports "./index.ts" relative to itself
# and takes no core-path override, so the only way to degrade it is a copied
# core directory whose index.ts throws, run as a subprocess -- which is also how
# Claude Code invokes it, so the exit status is part of what this pins.
# The sibling adapters pin the same state in-process
# (tests/agent-hooks-opencode-adapter.test.ts,
# tests/agent-hooks-pi-adapter.test.ts: "a core directory whose import throws
# also registers nothing"); this adapter runs per matched tool call, so a
# regression here is a stack trace and a nonzero status on every one of them.
function test_scripts_1021_claude_adapter_exits_0_silently_when_the_core_will_not_import() {
  _bats_test_init 1021 'claude adapter exits 0 silently when the deployed core will not import'
  require_bun_for_shim
  local copied_home="$BATS_TEST_TMPDIR/agent-hooks-broken-core-home"
  mkdir -p "$copied_home/.local/lib"
  cp -R "$AGENT_HOOKS_CORE" "$copied_home/.local/lib/agent-hooks"

  # Control on the intact copy: it proves the input below is the known-bad one
  # test_scripts_094 denies and that a copied core still reaches the policy.
  # Without it, a fixture that never got as far as running claude.ts would be
  # indistinguishable from the fail-open this case is about to assert.
  run env HOME="$copied_home" bash "$AGENT_HOOKS_SHIM" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"TODO FIXME scheduling launchd cron"}}
EOF
  assert_success
  assert_output --partial '"permissionDecision": "deny"'

  printf "throw new Error('core is broken');\n" \
    > "$copied_home/.local/lib/agent-hooks/index.ts"
  run env HOME="$copied_home" bash "$AGENT_HOOKS_SHIM" <<'EOF'
{"tool_name":"mcp__fff__grep","tool_input":{"query":"TODO FIXME scheduling launchd cron"}}
EOF
  assert_success
  assert_output ""
}

# Pane Labels package migration
# ===========================================

pane_labels_migration_prepare() {
  local work="$1"
  local home="$work/home" bin="$work/bin"
  mkdir -p "$home/.local/bin" "$home/.local/lib" \
    "$home/.config/herdr/plugins/herdr-pane-labels" "$bin"
  printf 'legacy-engine\n' > "$home/.local/bin/herdr-pane-labels"
  printf 'legacy-aliases\n' > "$home/.local/lib/herdr-aliases.sh"
  printf 'legacy-process\n' > "$home/.local/lib/herdr-process.sh"
  printf 'legacy-child\n' > "$home/.local/bin/herdr-child"
  chmod +x "$home/.local/bin/herdr-pane-labels" "$home/.local/bin/herdr-child"
  printf 'legacy-plugin\n' > "$home/.config/herdr/plugins/herdr-pane-labels/herdr-plugin.toml"
  # The real machine has the local plugin registered, which is what makes
  # local_plugin_registered 1 and puts the uninstall on the cutover path.
  : > "$work/registry-local"

  cat > "$bin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_CALLS"
# Socket-scoped calls carry their target in the environment, not in the
# argument list, so the plain call log cannot show that the per-socket loops
# ran at all.
[ -n "${HERDR_SOCKET_PATH:-}" ] && printf '%s %s\n' "$HERDR_SOCKET_PATH" "$*" >> "$HERDR_CALLS.sockets"
case "$*" in
  'session list --json') printf '%s\n' "$STUB_SESSIONS" ;;
  'plugin list --json')
    if [ -f "$HERDR_REGISTRY/registry-github" ]; then
      printf '%s\n' '{"result":{"plugins":[{"plugin_id":"seigi.pane-labels","source":{"kind":"github","repo":"herdr-pane-labels"},"enabled":true}]}}'
    elif [ -f "$HERDR_REGISTRY/registry-local" ]; then
      printf '%s\n' '{"result":{"plugins":[{"plugin_id":"seigi.pane-labels","source":{"kind":"local"},"enabled":true}]}}'
    else
      printf '%s\n' '{"result":{"plugins":[]}}'
    fi
    ;;
  'plugin disable seigi.pane-labels')
    # Herdr refuses to disable an id it does not know, and an aborted attempt
    # leaves exactly that state.
    if [ ! -f "$HERDR_REGISTRY/registry-local" ] && [ ! -f "$HERDR_REGISTRY/registry-github" ]; then
      printf 'plugin_not_found\n' >&2
      exit 1
    fi
    ;;
  'plugin uninstall seigi.pane-labels')
    rm -f "$HERDR_REGISTRY/registry-local" "$HERDR_REGISTRY/registry-github"
    ;;
  'plugin install Seigiard/herdr-pane-labels --ref aba61eb788c5fe0630dc570d96fd14683e2f63c7 -y')
    # A real install can prompt. Record whatever it could read, so a caller that
    # leaves stdin open is visible instead of merely lucky.
    IFS= read -r -t 1 stdin_line < /dev/stdin 2>/dev/null || stdin_line=''
    printf '%s' "$stdin_line" > "$HERDR_INSTALL_STDIN"
    [ "${HERDR_FAIL_STEP:-}" = install ] && exit 1
    cat > "$HOME/.local/bin/herdr-pane-labels" <<'ENGINE'
#!/bin/sh
# The reconciliation loop drives the engine, not herdr, so its calls land in a
# log of their own.
printf '%s %s\n' "${HERDR_SOCKET_PATH:-none}" "$*" >> "$HERDR_ENGINE_CALLS"
case "${1:-}" in --sweep|--ensure-sweep-daemon) exit 0 ;; esac
ENGINE
    chmod +x "$HOME/.local/bin/herdr-pane-labels"
    printf 'package-aliases\n' > "$HOME/.local/lib/herdr-aliases.sh"
    printf 'package-process\n' > "$HOME/.local/lib/herdr-process.sh"
    printf '0.2.3\n' > "$HOME/.local/lib/herdr-pane-labels.version"
    : > "$HERDR_REGISTRY/registry-github"
    ;;
  'plugin enable seigi.pane-labels'|'server reload-config')
    if [ "${HERDR_FAIL_STEP:-}" = enable ] && [ "$*" = 'plugin enable seigi.pane-labels' ]; then
      exit 1
    fi
    :
    ;;
esac
SH
  chmod +x "$bin/herdr"
}

pane_labels_migration_apply() {
  local work="$1" fail_step="${2:-}" sessions="${3:-}"
  [ -n "$sessions" ] || sessions='{"result":{"sessions":[]}}'
  HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" PATH="$work/bin:$PATH" HERDR_CALLS="$work/herdr.calls" \
    HERDR_ENGINE_CALLS="$work/engine.calls" HERDR_INSTALL_STDIN="$work/install.stdin" \
    HERDR_REGISTRY="$work" \
    HERDR_FAIL_STEP="$fail_step" STUB_SESSIONS="$sessions" bash \
    "$SOURCE_ROOT/.chezmoiscripts/run_once_after_6-migrate-herdr-pane-labels.sh.tmpl"
}

function test_scripts_1337_pane_labels_migration_activates_and_removes_the_legacy() {
  _bats_test_init 1337 'pane labels migration activates the package before removing the legacy layout'
  local work="$BATS_TEST_TMPDIR/pane-labels-migration"
  pane_labels_migration_prepare "$work"

  run pane_labels_migration_apply "$work"
  assert_success
  assert_dir_not_exists "$work/home/.config/herdr/plugins/herdr-pane-labels"
  # The package engine and its two libs are written by the stub's own install
  # branch, so re-reading them proves only that install ran -- which the install
  # argv below proves directly. The migration never touches those paths.
  assert_file_contains "$work/home/.local/bin/herdr-child" '^legacy-child$'
  assert_file_contains "$work/herdr.calls" '^plugin install Seigiard/herdr-pane-labels --ref aba61eb788c5fe0630dc570d96fd14683e2f63c7 -y$'
  assert_file_exists "$work/home/.local/lib/herdr-pane-labels.version"
}

# A failed cutover does not restore the old writer -- that implementation is
# gone from source and a restored copy would be an orphan. What it must leave
# is a machine that can still launch panes and a next apply that actually
# retries instead of reading the half-finished install as a finished cutover.
function test_scripts_1338_pane_labels_migration_aborts_a_partial_install_cl() {
  _bats_test_init 1338 'pane labels migration aborts a partial package install cleanly'
  local work="$BATS_TEST_TMPDIR/pane-labels-migration-failure"
  pane_labels_migration_prepare "$work"

  run pane_labels_migration_apply "$work" install
  assert_failure
  # The freeze stub is the one edit that would otherwise brick pane launches.
  assert_file_contains "$work/home/.local/bin/herdr-child" '^legacy-child$'
  # Nothing may claim a finished cutover on the next run.
  run grep -Fx "plugin uninstall seigi.pane-labels" "$work/herdr.calls"
  assert_success
  # And nothing re-registers a local plugin the source no longer carries.
  run grep -F 'plugin link ' "$work/herdr.calls"
  assert_failure
}

# Failing at enable means the install already succeeded and wrote the boundary
# marker. Leaving that marker behind is what would make package_already_installed
# report a finished cutover and skip the retry for good.
function test_scripts_1342_pane_labels_migration_clears_the_boundary_marker_() {
  _bats_test_init 1342 'pane labels migration clears the boundary marker when it aborts after install'
  local work="$BATS_TEST_TMPDIR/pane-labels-migration-enable-failure"
  pane_labels_migration_prepare "$work"

  run pane_labels_migration_apply "$work" enable
  assert_failure
  # The control the sibling test cannot give: install ran, so the marker existed.
  run grep -Fx 'plugin install Seigiard/herdr-pane-labels --ref aba61eb788c5fe0630dc570d96fd14683e2f63c7 -y' "$work/herdr.calls"
  assert_success
  assert_file_not_exists "$work/home/.local/lib/herdr-pane-labels.version"
  run grep -Fx "plugin uninstall seigi.pane-labels" "$work/herdr.calls"
  assert_success
  assert_file_contains "$work/home/.local/bin/herdr-child" '^legacy-child$'
}

# running_sockets gates every destructive step on knowing which sessions are
# live. A payload it cannot parse must stop the cutover, not read as "no
# sessions" and let the migration proceed past the point of no return.
function test_scripts_1339_pane_labels_migration_stops_on_an_unparseable_ses() {
  _bats_test_init 1339 'pane labels migration stops on an unparseable session list'
  local work="$BATS_TEST_TMPDIR/pane-labels-migration-malformed"
  pane_labels_migration_prepare "$work"

  run pane_labels_migration_apply "$work" '' '{"unexpected":true}'
  assert_failure
  assert_output --partial 'could not inspect running Herdr sessions'
  assert_dir_exists "$work/home/.config/herdr/plugins/herdr-pane-labels"
  assert_file_contains "$work/home/.local/bin/herdr-pane-labels" '^legacy-engine$'
  run grep -F 'plugin install' "$work/herdr.calls"
  assert_failure
}

# An empty socket_path is discarded by every consumer loop, so accepting it
# would silently reduce a live session to no session at all.
function test_scripts_1340_pane_labels_migration_stops_on_a_running_session_() {
  _bats_test_init 1340 'pane labels migration stops on a running session without a socket path'
  local work="$BATS_TEST_TMPDIR/pane-labels-migration-no-socket"
  pane_labels_migration_prepare "$work"

  run pane_labels_migration_apply "$work" '' '{"result":{"sessions":[{"running":true,"socket_path":""}]}}'
  assert_failure
  assert_output --partial 'could not inspect running Herdr sessions'
  assert_dir_exists "$work/home/.config/herdr/plugins/herdr-pane-labels"
  run grep -F 'plugin install' "$work/herdr.calls"
  assert_failure
}

# With every session list empty, the socket-driven half of the cutover never
# executes and could be deleted outright without a test noticing.
function test_scripts_1341_pane_labels_migration_drives_each_running_session() {
  _bats_test_init 1341 'pane labels migration drives each running session socket'
  local work="$BATS_TEST_TMPDIR/pane-labels-migration-sessions"
  local socket="$BATS_TEST_TMPDIR/session-a.sock"
  pane_labels_migration_prepare "$work"

  local second="$BATS_TEST_TMPDIR/session-b.sock"
  run pane_labels_migration_apply "$work" '' \
    "{\"result\":{\"sessions\":[{\"running\":true,\"socket_path\":\"$socket\"},{\"running\":true,\"socket_path\":\"$second\"},{\"running\":false,\"socket_path\":\"$BATS_TEST_TMPDIR/stopped.sock\"}]}}"
  assert_success
  local sock
  for sock in "$socket" "$second"; do
    run grep -Fx "$sock plugin disable seigi.pane-labels" "$work/herdr.calls.sockets"
    assert_success
    run grep -Fx "$sock plugin enable seigi.pane-labels" "$work/herdr.calls.sockets"
    assert_success
    run grep -Fx "$sock server reload-config" "$work/herdr.calls.sockets"
    assert_success
    run grep -Fx "$sock --sweep" "$work/engine.calls"
    assert_success
    run grep -Fx "$sock --ensure-sweep-daemon" "$work/engine.calls"
    assert_success
  done
  run grep -F "$BATS_TEST_TMPDIR/stopped.sock" "$work/herdr.calls.sockets"
  assert_failure
  run grep -F "$BATS_TEST_TMPDIR/stopped.sock" "$work/engine.calls"
  assert_failure
}


# A running flag that is not a boolean is a schema the script cannot read. The
# same filter already carries a // fallback because the shape moved once, and
# guessing "stopped" would skip a live session the cutover has to reconcile.
function test_scripts_1343_pane_labels_migration_stops_on_a_non_boolean_runn() {
  _bats_test_init 1343 'pane labels migration stops on a non-boolean running flag'
  local work="$BATS_TEST_TMPDIR/pane-labels-migration-running-shape"
  pane_labels_migration_prepare "$work"

  run pane_labels_migration_apply "$work" '' \
    '{"result":{"sessions":[{"running":"true","socket_path":"/tmp/shape.sock"}]}}'
  assert_failure
  assert_output --partial 'could not inspect running Herdr sessions'
  run grep -F 'plugin install' "$work/herdr.calls"
  assert_failure
}

# Two sibling installers close stdin and say why: an unseen upstream prompt must
# fail rather than hang chezmoi apply, and here it would hang with herdr-child
# already replaced by the freeze stub.
function test_scripts_1344_pane_labels_migration_closes_stdin_for_the_packag() {
  _bats_test_init 1344 'pane labels migration closes stdin for the package install'
  local work="$BATS_TEST_TMPDIR/pane-labels-migration-stdin"
  pane_labels_migration_prepare "$work"

  run pane_labels_migration_apply "$work" <<'STDIN'
SHOULD-NOT-REACH-THE-INSTALLER
STDIN
  assert_success
  assert_file_exists "$work/install.stdin"
  run grep -F 'SHOULD-NOT-REACH-THE-INSTALLER' "$work/install.stdin"
  assert_failure
}


# The abort path drops the local registration and nothing puts it back, so the
# next run meets an id Herdr does not know. Treating that as a quiesce failure
# made the cutover unrepeatable: every later apply died at the gate while the
# labels it had already killed stayed dead.
function test_scripts_1345_pane_labels_migration_retries_after_an_abort() {
  _bats_test_init 1345 'pane labels migration retries after an abort'
  local work="$BATS_TEST_TMPDIR/pane-labels-migration-retry"
  local sessions='{"result":{"sessions":[{"running":true,"socket_path":"/tmp/retry.sock"}]}}'
  pane_labels_migration_prepare "$work"

  run pane_labels_migration_apply "$work" install "$sessions"
  assert_failure
  # The abort names the command that brings labels back before the next apply.
  assert_output --partial 'herdr plugin link '
  # The registration is gone, which is the state the retry has to tolerate.
  assert_file_not_exists "$work/registry-local"

  run pane_labels_migration_apply "$work" '' "$sessions"
  assert_success
  assert_file_exists "$work/registry-github"
  assert_dir_not_exists "$work/home/.config/herdr/plugins/herdr-pane-labels"
}


# Claude settings modifier
# ===========================================

claude_modifier_setup() {
  CLAUDE_MODIFIER="$SOURCE_ROOT/modify_dot_claude.json"
  CLAUDE_MODIFIER_BIN="$BATS_TEST_TMPDIR/claude-modifier-bin"
  CLAUDE_MODIFIER_OP_MARKER="$BATS_TEST_TMPDIR/claude-modifier-op-launched"
  mkdir -p "$CLAUDE_MODIFIER_BIN"
  cat > "$CLAUDE_MODIFIER_BIN/op" <<'STUB'
#!/bin/sh
printf '%s\n' "$2" >> "$MMS_TEST_OP_MARKER"
if [ "${MMS_TEST_OP_MODE:-}" = error ]; then
  printf '%s\n' 'op: account is not signed in' >&2
  exit 1
fi
case "$2" in
  *Jina*) printf '%s\n' 'interactive-jina' ;;
esac
STUB
  chmod +x "$CLAUDE_MODIFIER_BIN/op"
}

function test_scripts_245_claude_settings_modifier_preserves_jina_and_replaces_tavily_unattended() {
  _bats_test_init 245 'Claude settings modifier preserves Jina and replaces Tavily with its env-backed entry unattended'
  claude_modifier_setup
  local input='{"mcpServers":{"jina":{"type":"http","url":"https://existing.jina","headers":{"Authorization":"Bearer existing-jina","X-Keep":"yes"}},"tavily-mcp":{"type":"http","url":"https://existing.tavily/key=existing-tavily"},"stale":{"type":"stdio"}},"other":{"preserved":true}}'

  run env -u MMS_CHEZMOI_FIXTURE_JINA_API_KEY \
    PATH="$CLAUDE_MODIFIER_BIN:$PATH" HOME=/stub/home MMS_TEST_OP_MARKER="$CLAUDE_MODIFIER_OP_MARKER" \
    MMS_CHEZMOI_UNATTENDED=1 bash "$CLAUDE_MODIFIER" <<< "$input"

  assert_success
  run jq -e '
    (.mcpServers.jina == {"type":"http","url":"https://existing.jina","headers":{"Authorization":"Bearer existing-jina","X-Keep":"yes"}})
    and (.mcpServers["tavily-mcp"] == {"type":"http","url":"https://mcp.tavily.com/mcp/?tavilyApiKey=${TAVILY_API_KEY}"})
    and (.mcpServers.executor == {"type":"stdio","command":"/stub/home/.local/bin/executor","args":["mcp"],"env":{}})
    and (.mcpServers | has("stale") | not)
    and (.other == {"preserved":true})
  ' <<< "$output"
  assert_success
  # oracle: only the controlled fake helper can create this launch marker.
  assert_file_not_exists "$CLAUDE_MODIFIER_OP_MARKER"
}

function test_scripts_246_claude_settings_modifier_keeps_jina_absent_and_creates_tavily_unattended() {
  _bats_test_init 246 'Claude settings modifier keeps Jina absent and creates env-backed Tavily on clean unattended input'
  claude_modifier_setup

  run env -u MMS_CHEZMOI_FIXTURE_JINA_API_KEY \
    PATH="$CLAUDE_MODIFIER_BIN:$PATH" HOME=/stub/home MMS_TEST_OP_MARKER="$CLAUDE_MODIFIER_OP_MARKER" \
    MMS_CHEZMOI_UNATTENDED=1 bash "$CLAUDE_MODIFIER" <<< '{"mcpServers":{}}'

  assert_success
  run jq -e '
    true
    and ((.mcpServers | keys | sort) == ["deepwiki","executor","fff","tavily-mcp"])
    and (.mcpServers["tavily-mcp"].url == "https://mcp.tavily.com/mcp/?tavilyApiKey=${TAVILY_API_KEY}")
  ' <<< "$output"
  assert_success
  # oracle: only the controlled fake helper can create this launch marker.
  assert_file_not_exists "$CLAUDE_MODIFIER_OP_MARKER"
}

function test_scripts_247_claude_settings_modifier_replaces_only_jina_unattended() {
  _bats_test_init 247 'Claude settings modifier replaces only Jina from an unattended fixture'
  claude_modifier_setup
  local input='{"mcpServers":{"jina":{"type":"http","url":"https://old.jina"},"tavily-mcp":{"type":"http","url":"https://existing.tavily/key=existing-tavily"}}}'

  run env PATH="$CLAUDE_MODIFIER_BIN:$PATH" HOME=/stub/home \
    MMS_TEST_OP_MARKER="$CLAUDE_MODIFIER_OP_MARKER" MMS_CHEZMOI_UNATTENDED=1 \
    MMS_CHEZMOI_FIXTURE_JINA_API_KEY=jina-canary bash "$CLAUDE_MODIFIER" <<< "$input"

  assert_success
  run jq -e '
    (.mcpServers.jina == {"type":"http","url":"https://mcp.jina.ai/v1","headers":{"Authorization":"Bearer jina-canary"}})
    and (.mcpServers["tavily-mcp"] == {"type":"http","url":"https://mcp.tavily.com/mcp/?tavilyApiKey=${TAVILY_API_KEY}"})
  ' <<< "$output"
  assert_success
  # oracle: only the controlled fake helper can create this launch marker.
  assert_file_not_exists "$CLAUDE_MODIFIER_OP_MARKER"
}

function test_scripts_248_claude_settings_modifier_does_not_embed_tavily_fixture() {
  _bats_test_init 248 'Claude settings modifier uses env expansion instead of embedding the unattended Tavily fixture'
  claude_modifier_setup
  local input='{"mcpServers":{"jina":{"type":"http","url":"https://existing.jina","headers":{"Authorization":"Bearer existing-jina"}},"tavily-mcp":{"type":"http","url":"https://old.tavily"}}}'

  run env -u MMS_CHEZMOI_FIXTURE_JINA_API_KEY PATH="$CLAUDE_MODIFIER_BIN:$PATH" HOME=/stub/home \
    MMS_TEST_OP_MARKER="$CLAUDE_MODIFIER_OP_MARKER" MMS_CHEZMOI_UNATTENDED=1 \
    MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY=tavily-canary bash "$CLAUDE_MODIFIER" <<< "$input"

  assert_success
  run jq -e '
    (.mcpServers.jina == {"type":"http","url":"https://existing.jina","headers":{"Authorization":"Bearer existing-jina"}})
    and (.mcpServers["tavily-mcp"] == {"type":"http","url":"https://mcp.tavily.com/mcp/?tavilyApiKey=${TAVILY_API_KEY}"})
  ' <<< "$output"
  assert_success
  # oracle: only the controlled fake helper can create this launch marker.
  assert_file_not_exists "$CLAUDE_MODIFIER_OP_MARKER"
}

function test_scripts_249_claude_settings_modifier_creates_jina_and_env_backed_tavily_unattended() {
  _bats_test_init 249 'Claude settings modifier creates fixture-backed Jina and env-backed Tavily unattended'
  claude_modifier_setup

  run env PATH="$CLAUDE_MODIFIER_BIN:$PATH" HOME=/stub/home MMS_TEST_OP_MARKER="$CLAUDE_MODIFIER_OP_MARKER" \
    MMS_CHEZMOI_UNATTENDED=1 MMS_CHEZMOI_FIXTURE_JINA_API_KEY=jina-canary \
    MMS_CHEZMOI_FIXTURE_TAVILY_API_KEY=tavily-canary bash "$CLAUDE_MODIFIER" <<< '{}'

  assert_success
  run jq -e '
    (.mcpServers.jina.headers.Authorization == "Bearer jina-canary")
    and (.mcpServers["tavily-mcp"].url == "https://mcp.tavily.com/mcp/?tavilyApiKey=${TAVILY_API_KEY}")
  ' <<< "$output"
  assert_success
  # oracle: only the controlled fake helper can create this launch marker.
  assert_file_not_exists "$CLAUDE_MODIFIER_OP_MARKER"
}

function test_scripts_1324_claude_settings_modifier_treats_empty_fixtures_as_unavailable() {
  _bats_test_init 1324 'Claude settings modifier treats empty unattended fixtures as unavailable'
  claude_modifier_setup
  local input='{"mcpServers":{"jina":{"sentinel":"existing-jina"},"tavily-mcp":{"sentinel":"existing-tavily"}}}'

  run env PATH="$CLAUDE_MODIFIER_BIN:$PATH" HOME=/stub/home MMS_TEST_OP_MARKER="$CLAUDE_MODIFIER_OP_MARKER" \
    MMS_CHEZMOI_UNATTENDED=1 \
    MMS_CHEZMOI_FIXTURE_JINA_API_KEY= \
    bash "$CLAUDE_MODIFIER" <<< "$input"

  assert_success
  run jq -e '
    (.mcpServers.jina == {"sentinel":"existing-jina"})
    and (.mcpServers["tavily-mcp"] == {"type":"http","url":"https://mcp.tavily.com/mcp/?tavilyApiKey=${TAVILY_API_KEY}"})
  ' <<< "$output"
  assert_success
  # oracle: only the controlled fake helper can create this launch marker.
  assert_file_not_exists "$CLAUDE_MODIFIER_OP_MARKER"
}

function test_scripts_1325_claude_settings_modifier_requires_exact_unattended_selector() {
  _bats_test_init 1325 'Claude settings modifier keeps interactive behavior for invalid unattended selectors'
  claude_modifier_setup
  local selector

  for selector in unset 0 true; do
    rm -f "$CLAUDE_MODIFIER_OP_MARKER"
    if [[ "$selector" == unset ]]; then
      run env -u MMS_CHEZMOI_UNATTENDED PATH="$CLAUDE_MODIFIER_BIN:$PATH" HOME=/stub/home \
        MMS_TEST_OP_MARKER="$CLAUDE_MODIFIER_OP_MARKER" bash "$CLAUDE_MODIFIER" <<< '{}'
    else
      run env PATH="$CLAUDE_MODIFIER_BIN:$PATH" HOME=/stub/home MMS_TEST_OP_MARKER="$CLAUDE_MODIFIER_OP_MARKER" \
        MMS_CHEZMOI_UNATTENDED="$selector" bash "$CLAUDE_MODIFIER" <<< '{}'
    fi

    assert_success
    run jq -e '
      (.mcpServers.jina.headers.Authorization == "Bearer interactive-jina")
      and (.mcpServers["tavily-mcp"].url == "https://mcp.tavily.com/mcp/?tavilyApiKey=${TAVILY_API_KEY}")
    ' <<< "$output"
    assert_success
    assert_file_exists "$CLAUDE_MODIFIER_OP_MARKER"
  done
}

function test_scripts_1326_claude_settings_modifier_passes_settings_through_without_jq() {
  _bats_test_init 1326 'Claude settings modifier passes settings through without jq in both contexts'
  local modifier="$SOURCE_ROOT/modify_dot_claude.json"
  local input='{"mcpServers":{"kept":{"type":"stdio"}},"other":"preserved"}'
  local stub_bin="$BATS_TEST_TMPDIR/claude-modifier-nojq-bin"
  local selector
  mkdir -p "$stub_bin"
  ln -s "$(command -v cat)" "$stub_bin/cat"
  ln -s "$(command -v bash)" "$stub_bin/bash"

  for selector in interactive unattended; do
    if [[ "$selector" == interactive ]]; then
      run env -u MMS_CHEZMOI_UNATTENDED PATH="$stub_bin" bash "$modifier" <<< "$input"
    else
      run env PATH="$stub_bin" MMS_CHEZMOI_UNATTENDED=1 MMS_CHEZMOI_FIXTURE_JINA_API_KEY=jina-canary \
        bash "$modifier" <<< "$input"
    fi

    assert_success
    assert_output "$input"
  done
}

function test_scripts_1327_claude_settings_modifier_reports_1password_read_errors() {
  _bats_test_init 1327 'Claude settings modifier preserves the 1Password error when Jina cannot be read'
  claude_modifier_setup

  run --separate-stderr env -u MMS_CHEZMOI_UNATTENDED PATH="$CLAUDE_MODIFIER_BIN:$PATH" HOME=/stub/home \
    MMS_TEST_OP_MARKER="$CLAUDE_MODIFIER_OP_MARKER" MMS_TEST_OP_MODE=error \
    bash "$CLAUDE_MODIFIER" <<< '{}'

  assert_success
  # oracle: only the controlled fake helper can create this launch marker, so an
  # unattended run that never reaches `op` cannot pass on empty stderr alone.
  assert_file_exists "$CLAUDE_MODIFIER_OP_MARKER"
  assert_stderr --partial 'op: account is not signed in'
  assert_stderr --partial 'modify_dot_claude.json: could not read Jina API Key from 1Password; skipping its MCP server'
  refute_stderr --partial '1Password returned no Jina API Key'
  run jq -e '.mcpServers | has("jina") | not' <<< "$output"
  assert_success
}

# ===========================================
# Pi settings modifier
# ===========================================

function test_scripts_250_pi_settings_modifier_selects_the_terminal_theme() {
  _bats_test_init 250 'Pi settings modifier uses portable skills and the managed package set'
  local modifier="$SOURCE_ROOT/dot_pi/agent/modify_settings.json"
  local input='{"theme":"light","lastChangelogVersion":"0.84.2","packages":["git:github.com/EveryInc/compound-engineering-plugin","npm:obsolete-extension"],"skills":["~/.claude/skills","~/custom/skills"]}'

  run bash "$modifier" <<< "$input"

  assert_success
  # Restating the managed package names here would copy them out of the
  # modifier this test runs, so adding or dropping an extension would edit
  # both sides in one patch and never fail. What the modifier owes its
  # consumer is the replacement itself: the caller's packages array is
  # discarded, whatever it held, and only npm specs survive.
  run jq -e '
    .theme == "terminal" and
    .lastChangelogVersion == "0.84.2" and
    ((.packages | index("npm:obsolete-extension")) == null) and
    ((.packages | map(select(startswith("git:"))) | length) == 0) and
    ((.packages | length) > 0) and
    (.packages | all(startswith("npm:"))) and
    (.skills == ["~/custom/skills"])
  ' <<< "$output"
  assert_success
}

function test_scripts_251_pi_settings_modifier_is_idempotent() {
  _bats_test_init 251 'Pi settings modifier is idempotent'
  local modifier="$SOURCE_ROOT/dot_pi/agent/modify_settings.json"
  local input='{"lastChangelogVersion":"0.84.2","model":"anthropic/claude-sonnet-4-5","packages":["npm:@ff-labs/pi-fff","npm:@howaboua/pi-codex-conversion","npm:pi-subagents","npm:pi-agent-browser-native","git:github.com/EveryInc/compound-engineering-plugin","npm:pi-ask-user","npm:@trevonistrevon/pi-loop","npm:pi-web-access","npm:pi-context-view"],"skills":["~/custom/skills","~/.claude/skills"]}'
  local once

  run bash "$modifier" <<< "$input"

  assert_success
  once="$output"
  # The input above already carries the managed names, so comparing them back
  # would compare the fixture to itself. The contract here is that unrelated
  # user settings survive the rewrite and the git: entry does not.
  run jq -e '
    (.theme == "terminal") and
    (.lastChangelogVersion == "0.84.2") and
    (.model == "anthropic/claude-sonnet-4-5") and
    ((.packages | map(select(startswith("git:"))) | length) == 0) and
    (.packages | all(startswith("npm:"))) and
    (.skills == ["~/custom/skills"])
  ' <<< "$once"
  assert_success

  run bash "$modifier" <<< "$once"

  assert_success
  assert_output "$once"
}

function test_scripts_252_pi_terminal_theme_uses_only_terminal_palette_col() {
  _bats_test_init 252 'Pi terminal theme uses only terminal palette colors'
  local theme="$SOURCE_ROOT/dot_pi/agent/themes/terminal.json"

  # Naming two arbitrary empty slots proved nothing about the palette. The
  # property is structural and cross-references two independently edited
  # sections of the file: every colour either inherits (empty string) or
  # names a slot the vars block declares, so no colour can hardcode a value
  # the user's terminal does not control.
  run jq -e '
    .name == "terminal" and
    ([.vars[]] | all(type == "number" and . >= 0 and . <= 15)) and
    (. as $theme
      | [$theme.colors[]
         | select(type == "string")
         | . as $value
         | select($value != "" and (($theme.vars | has($value)) | not))]
      | length == 0)
  ' "$theme"
  assert_success
}

function test_scripts_253_claude_code_daltonized_theme_extends_light_ansi() {
  _bats_test_init 253 'Claude Code daltonized theme extends light ANSI with terminal colors'
  local theme="$SOURCE_ROOT/private_dot_claude/themes/light-ansi-daltonized.json"

  # length > 0 is not a content assertion -- it is the anti-vacuity guard that
  # keeps the slot-form check below from passing on an empty overrides object.
  # The vocabulary is the standard 16 ANSI colour names, which is what Claude
  # Code's theme loader resolves; a bare startswith("ansi:") would also accept
  # ansi:tomato, which resolves to nothing.
  run jq -e '
    ["black","red","green","yellow","blue","magenta","cyan","white",
     "blackBright","redBright","greenBright","yellowBright",
     "blueBright","magentaBright","cyanBright","whiteBright"] as $ansi |
    .base == "light-ansi" and
    (.overrides | length > 0) and
    ([.overrides[] | . as $value
      | select(($value | type) != "string"
               or ($value | startswith("ansi:") | not)
               or (($ansi | index($value | ltrimstr("ansi:"))) == null))]
     | length == 0)
  ' "$theme"
  assert_success
}

# ===========================================
# morning-cleanup script
# ===========================================

function test_scripts_254_morning_cleanup_trashes_stale_omc_state_and_stam() {
  _bats_test_init 254 'morning-cleanup trashes stale .omc state and stamps the day'
  local script="$SOURCE_ROOT/dot_local/bin/executable_morning-cleanup.sh"
  local fake_home="$BATS_TEST_TMPDIR/mc-home"
  mkdir -p "$fake_home/Projects/demo/.omc"
  printf '{}' > "$fake_home/Projects/demo/.omc/state.json"
  touch -t 202001010000 "$fake_home/Projects/demo/.omc/state.json"

  run env HOME="$fake_home" MORNING_CLEANUP_NO_NOTIFY=1 bash "$script"
  assert_success
  assert_dir_not_exists "$fake_home/Projects/demo/.omc"
  # "Trashed", not deleted. The script moves the dir into ~/.scratchpad and the
  # purge step only reclaims it days later; a regression to rm -rf would leave
  # the source gone all the same, so the destination is what carries the undo
  # window.
  run find "$fake_home/.scratchpad" -mindepth 1 -maxdepth 1 -type d -name 'omc-*'
  assert_success
  assert_equal "${#lines[@]}" 1
  assert_file_exists "${lines[0]}/state.json"
  # The stamp is a date, not a touch file: test 256 reads this content to decide
  # that a second run of the same day is a no-op.
  assert_equal "$(cat "$fake_home/.local/state/morning-cleanup/last-run")" "$(date +%Y-%m-%d)"
}

function test_scripts_255_morning_cleanup_keeps_a_recently_active_omc_dir() {
  _bats_test_init 255 'morning-cleanup keeps a recently active .omc dir'
  local script="$SOURCE_ROOT/dot_local/bin/executable_morning-cleanup.sh"
  local fake_home="$BATS_TEST_TMPDIR/mc-home-live"
  mkdir -p "$fake_home/Projects/demo/.omc"
  printf '{}' > "$fake_home/Projects/demo/.omc/state.json"

  run env HOME="$fake_home" MORNING_CLEANUP_NO_NOTIFY=1 bash "$script"
  assert_success
  [ -d "$fake_home/Projects/demo/.omc" ]
}

function test_scripts_256_morning_cleanup_is_a_no_op_on_its_second_run_of() {
  _bats_test_init 256 'morning-cleanup is a no-op on its second run of the day'
  local script="$SOURCE_ROOT/dot_local/bin/executable_morning-cleanup.sh"
  local fake_home="$BATS_TEST_TMPDIR/mc-home-stamp"
  mkdir -p "$fake_home/Projects"
  run env HOME="$fake_home" MORNING_CLEANUP_NO_NOTIFY=1 bash "$script"
  assert_success

  mkdir -p "$fake_home/Projects/late/.omc"
  printf '{}' > "$fake_home/Projects/late/.omc/state.json"
  touch -t 202001010000 "$fake_home/Projects/late/.omc/state.json"
  run env HOME="$fake_home" MORNING_CLEANUP_NO_NOTIFY=1 bash "$script"
  assert_success
  [ -d "$fake_home/Projects/late/.omc" ]
}

# The fresh-trash-keep scenario is owned by morning_cleanup_test.sh test 002,
# which pairs it with the stale-removal leg and a completion stamp; a second
# copy here would be a duplicate owner.

# Wires the herdr-child descriptor probe into the suite. run-post-apply.sh runs
# a fixed file list, so without this nested invocation the probe file would be
# dead coverage again -- its bats ancestor was exactly that
# (docs/solutions/design-patterns/outliving-processes-hang-the-suite.md).
# A dedicated file, not an inline test, because
# the probe must observe launcher-descriptor EOF from outside any suite whose
# runner shares those descriptors.
function test_scripts_258_herdr_child_descriptor_probe_passes_under_a_nes() {
  _bats_test_init 258 'herdr-child descriptor probe passes under a nested bashunit run'
  local probe_file="$BATS_TEST_DIRNAME/bashunit/herdr_child_descriptor_probe_test.sh"
  assert_file_exists "$probe_file"
  run env NO_COLOR=1 TMPDIR="$BATS_TEST_TMPDIR" \
    "$BATS_TEST_DIRNAME/lib/bashunit" "$probe_file"
  assert_success
  # Bashunit abbreviates long titles to the terminal width in Docker panes.
  assert_output --partial "All tests passed"
}

# Guards the local patch in the pinned runner itself ('Local patch vs upstream
# 0.50.1' in tests/lib/bashunit): result parsing takes the last
# ##TEST_EXIT_CODE=-marked line, not the blind last line. A re-pin of bashunit
# that drops the patch turns this test red
# (docs/solutions/design-patterns/outliving-processes-hang-the-suite.md).
function test_scripts_260_pinned_bashunit_survives_late_child_output_aft() {
  _bats_test_init 260 'pinned bashunit survives late child output after the result payload'
  local probe_file="$BATS_TEST_DIRNAME/bashunit/bashunit_late_output_probe_test.sh"
  assert_file_exists "$probe_file"

  # Parallel leg: aggregate_parallel_results parses the .result file.
  run env NO_COLOR=1 TMPDIR="$BATS_TEST_TMPDIR" \
    "$BATS_TEST_DIRNAME/lib/bashunit" -j 2 "$probe_file"
  assert_success
  # The title is terminal-width dependent; the single-test count proves the probe ran.
  assert_output --partial "Tests:      1 passed, 1 total"
  assert_output --partial "Assertions: 1 passed, 1 total"

  # Sequential leg: extract_result_counts parses the captured execution
  # result. Unpatched it stays exit 0 but reports 0 assertions, so the
  # assertion-count line is the discriminator here, not the status.
  run env NO_COLOR=1 TMPDIR="$BATS_TEST_TMPDIR" \
    "$BATS_TEST_DIRNAME/lib/bashunit" "$probe_file"
  assert_success
  assert_output --partial "Assertions: 1 passed, 1 total"
}

function test_scripts_259_test_dsl_isolates_parallel_tests_with_the_same_historical_number() {
  _bats_test_init 259 'test DSL isolates parallel tests with the same historical number'
  local probe_file="$BATS_TEST_DIRNAME/bashunit/test_dsl_parallel_isolation_probe_test.sh"
  assert_file_exists "$probe_file"

  run env NO_COLOR=1 TMPDIR="$BATS_TEST_TMPDIR" \
    "$BATS_TEST_DIRNAME/lib/bashunit" -j 2 "$probe_file"
  assert_success
  assert_output --partial "Tests:      2 passed, 2 total"
}

# watcher orphan self-termination (docs/solutions/design-patterns/outliving-processes-hang-the-suite.md)
# ===========================================

function test_scripts_261_herdr_child_watcher_at_arm_barrier_exits_when_la() {
  _bats_test_init 261 'herdr-child watcher held at the arm barrier exits when its launcher is SIGKILLed'
  child_stub_herdr
  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 STUB_START_CONTEXT=1 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_TEST_ARM_BARRIER="$CHILD_STUB/arm" \
    bash "$HERDR_CHILD" start --kind claude --detach \
    --prompt "test task" > /dev/null 2>&1 &
  local launcher_pid=$!
  local attempt=0
  while [ ! -e "$CHILD_STUB/arm.ready" ] && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_file_exists "$CHILD_STUB/arm.ready"
  local watcher_pid
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  # SIGKILL writes no abort.state, so only the watcher's own launcher
  # liveness check can free it from the held barrier.
  kill -KILL "$launcher_pid" 2>/dev/null || true
  wait "$launcher_pid" 2>/dev/null || true
  attempt=0
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  run kill -0 "$watcher_pid"
  assert_failure
}

function test_scripts_262_herdr_child_armed_watcher_exits_when_run_state_i() {
  _bats_test_init 262 'herdr-child armed watcher exits when its supervision run state is torn down'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 5000
  assert_success
  local watcher_pid
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  kill -0 "$watcher_pid"
  # Teardown-style destruction mid-poll: with the run dir gone every herdr
  # error looks transient, so an unguarded watcher spins forever.
  rm -rf "$CHILD_STUB/state"
  local attempt=0
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  run kill -0 "$watcher_pid"
  assert_failure
}

function test_scripts_263_herdr_child_watcher_release_hold_is_bounded() {
  _bats_test_init 263 'herdr-child watcher held for release self-terminates once the hold bound expires'
  child_stub_herdr
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    STUB_START_CONTEXT=1 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_WATCHER_PID_FILE="$CHILD_STUB/watcher.pid" \
    HERDR_CHILD_TEST_WATCHER_RELEASE="$CHILD_STUB/release-watcher" \
    HERDR_CHILD_TEST_HOLD_TIMEOUT_SECONDS=1 \
    bash "$HERDR_CHILD" start --kind claude --detach \
    --prompt "test task"
  assert_success
  local watcher_pid
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  # No release file is ever written: an abandoned hold must expire on its own
  # instead of orphaning a polling daemon. This hold carries the multiplied
  # bound that keeps it outlasting a launcher's, so the ceiling clears four
  # knob-seconds with room to spare; the watcher normally exits long before it.
  local attempt=0
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 2000 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  run kill -0 "$watcher_pid"
  assert_failure
}

function test_scripts_264_herdr_child_reap_invalidation_suppresses_delivery_already_in_progress() {
  _bats_test_init 264 'herdr-child reap invalidation suppresses delivery already in progress'
  child_lifecycle_stub_herdr
  HERDR_CHILD_TEST_REAP_OWNER_VERIFIED="$CHILD_STUB/reap-owner-verified"
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  local generation run_dir reap_pid reap_status attempt=0
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/block-delivery-pane-get"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/delivery-pane-get.ready"

  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_REAP_INVALIDATED_BARRIER="$CHILD_STUB/reap-invalidated" \
    bash "$HERDR_CHILD" reap --to "$(child_started_name)" --pane wT:p9 >"$CHILD_STUB/reap.out" 2>&1 &
  reap_pid=$!
  CHILD_REAP_PID="$reap_pid"
  child_wait_for_file "$CHILD_STUB/reap-invalidated.ready"
  assert_file_not_exists "$CHILD_STUB/pane-closed"

  : > "$CHILD_STUB/delivery-pane-get.release"
  while [ ! -e "$CHILD_STUB/reap-owner-verified" ] && \
        [ ! -e "$CHILD_STUB/successful-prompts.log" ] && \
        [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  assert_file_not_exists "$CHILD_STUB/successful-prompts.log"
  assert_file_contains "$run_dir/invalidated.state" '^reason=reap$'

  : > "$CHILD_STUB/reap-invalidated.release"
  if wait "$reap_pid"; then reap_status=0; else reap_status=$?; fi
  CHILD_REAP_PID=""
  [ "$reap_status" -eq 0 ] || cat "$CHILD_STUB/reap.out" >&2
  assert_equal "$reap_status" 0
  assert_file_contains "$CHILD_STUB/reap.out" 'closed pane wT:p9'
  assert_file_exists "$CHILD_STUB/pane-closed"
  attempt=0
  while [ -d "$run_dir" ] && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  assert_dir_not_exists "$run_dir"
}

function test_scripts_265_herdr_child_delivery_claim_keeps_reap_fail_closed_without_holding_guard() {
  _bats_test_init 265 'herdr-child delivery claim keeps reap fail closed without holding the transition guard'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  local generation run_dir watcher_pid attempt=0
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/block-parent-prompt"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/parent-prompt-accepted"
  assert_file_exists "$run_dir/delivery-pending.state"

  : > "$CHILD_STUB/fail-ps"
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reap --to "$(child_started_name)" --pane wT:p9
  assert_success
  assert_output --partial 'supervision generation could not be invalidated'
  assert_file_not_exists "$CHILD_STUB/pane-closed"

  rm "$CHILD_STUB/fail-ps"
  : > "$CHILD_STUB/release-parent-prompt"
  child_wait_for_file "$CHILD_STUB/successful-prompts.log"
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  assert_dir_not_exists "$run_dir"
}

function test_scripts_266_herdr_child_reap_recovers_a_delivery_claim_owned_by_a_dead_watcher() {
  _bats_test_init 266 'herdr-child reap recovers a delivery claim owned by a dead watcher'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  local generation run_dir watcher_pid attempt=0
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  watcher_pid="$(cat "$CHILD_STUB/watcher.pid")"
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/block-parent-prompt"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/parent-prompt-accepted"
  assert_file_exists "$run_dir/delivery-pending.state"

  kill -KILL "$watcher_pid"
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  run env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    bash "$HERDR_CHILD" reap --to "$(child_started_name)" --pane wT:p9
  assert_success
  assert_output --partial 'closed pane wT:p9'
  assert_file_exists "$CHILD_STUB/pane-closed"
  : > "$CHILD_STUB/release-parent-prompt"
}

function test_scripts_267_herdr_child_transition_owner_identity_uses_a_stable_locale() {
  _bats_test_init 267 'herdr-child transition owner identity uses a stable locale'
  child_lifecycle_stub_herdr
  : > "$CHILD_STUB/observe-ps-locale"
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/block-parent-prompt"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/parent-prompt-accepted"
  assert_file_contains "$CHILD_STUB/ps-locales.log" '^C$'
  run grep -v '^C$' "$CHILD_STUB/ps-locales.log"
  assert_failure
  : > "$CHILD_STUB/release-parent-prompt"
}

function test_scripts_268_herdr_child_checkout_help_resolves_runtime_module() {
  _bats_test_init 268 'herdr-child checkout help resolves the runtime module'
  run bash "$HERDR_CHILD" --help
  assert_success
  assert_output --partial 'Usage:'
  refute_output --partial '__watcher'

  run bash "$HERDR_CHILD" not-a-command
  assert_failure 2
  assert_output --partial 'unknown subcommand: not-a-command'
}

function test_scripts_269_herdr_child_modules_source_cleanly_without_source_time_effects() {
  _bats_test_init 269 'sourced library modules cause no source-time side effects'
  local lib_dir="$SOURCE_ROOT/dot_local/lib"

  run /bin/bash -s -- "$lib_dir" "$BATS_TEST_TMPDIR/module-loading" <<'BASH'
set -euo pipefail
lib_dir="$1"
work_dir="$2"
shift 2
set -- 'module positional one' 'module-positional-two'
mkdir -p "$work_dir"

snapshot_shell_state() {
  local output="$1"
  shift
  {
    set +o
    trap -p
    printf 'pwd=%s\n' "$PWD"
    printf 'umask=%s\n' "$(umask)"
    printf 'path=<%q>\n' "$PATH"
    printf 'home=<%q>\n' "$HOME"
    printf 'ifs=<%q>\n' "$IFS"
    shopt -p
    printf 'argv'
    printf ' <%q>' "$@"
    printf '\n'
  } > "$output"
}

snapshot_function_definitions() {
  local output="$1" names="$2" function_name
  {
    while IFS= read -r function_name; do
      printf '%s ' "$function_name"
      declare -f "$function_name" | cksum
    done < "$names"
  } > "$output"
}

snapshot_global_definitions() {
  local output="$1" names="$2" global_name
  {
    while IFS= read -r global_name; do
      case "$global_name" in
        BASH*|BASHPID|EPOCHREALTIME|EPOCHSECONDS|FUNCNAME|GROUPS|LINENO|\
          OPTARG|OPTIND|PIPESTATUS|RANDOM|SECONDS|SHLVL|SRANDOM|_|\
          global_name|names|output)
          continue
          ;;
      esac
      declare -p "$global_name" 2>/dev/null || true
    done < "$names"
  } > "$output"
}

# herdr-process.sh is the already-declared predecessor of every child module.
source "$lib_dir/herdr-process.sh"
while IFS= read -r module; do
  declare -F | awk '{print $3}' | LC_ALL=C sort > "$work_dir/functions.before"
  snapshot_function_definitions "$work_dir/function-definitions.before" "$work_dir/functions.before"
  compgen -v | LC_ALL=C sort > "$work_dir/globals.before"
  snapshot_global_definitions "$work_dir/global-definitions.before" "$work_dir/globals.before"
  snapshot_shell_state "$work_dir/state.before" "$@"
  if ! source "$lib_dir/$module" > "$work_dir/source.output" 2>&1; then
    printf '%s failed to source\n' "$module" >&2
    cat "$work_dir/source.output" >&2
    exit 1
  fi
  snapshot_shell_state "$work_dir/state.after" "$@"
  cmp -s "$work_dir/state.before" "$work_dir/state.after" || {
    printf '%s changed shell state at source time\n' "$module" >&2
    diff -u "$work_dir/state.before" "$work_dir/state.after" >&2 || true
    exit 1
  }
  [ ! -s "$work_dir/source.output" ] || {
    printf '%s produced output at source time\n' "$module" >&2
    cat "$work_dir/source.output" >&2
    exit 1
  }
  snapshot_function_definitions "$work_dir/function-definitions.after" "$work_dir/functions.before"
  cmp -s "$work_dir/function-definitions.before" "$work_dir/function-definitions.after" || {
    printf '%s redefined an existing function\n' "$module" >&2
    diff -u "$work_dir/function-definitions.before" "$work_dir/function-definitions.after" >&2 || true
    exit 1
  }
  snapshot_global_definitions "$work_dir/global-definitions.after" "$work_dir/globals.before"
  cmp -s "$work_dir/global-definitions.before" "$work_dir/global-definitions.after" || {
    printf '%s mutated an existing global at source time\n' "$module" >&2
    diff -u "$work_dir/global-definitions.before" "$work_dir/global-definitions.after" >&2 || true
    exit 1
  }
done <<'EOF'
herdr-child-runtime.sh
herdr-child-supervision.sh
herdr-child-watcher.sh
herdr-child-launch.sh
herdr-child-continuation.sh
herdr-child-reap.sh
context-usage.sh
EOF
BASH
  assert_success
  assert_output ''
}

function test_scripts_270_herdr_child_reap_invalidation_barrier_is_bounded() {
  _bats_test_init 270 'herdr-child reap invalidation barrier restores supervision when abandoned'
  child_lifecycle_stub_herdr
  run child_lifecycle_start --supervision-timeout 600000
  assert_success
  local generation run_dir reap_pid reap_status attempt=0
  generation="$(cat "$CHILD_STUB/generation")"
  run_dir="$CHILD_STUB/state/runs/$generation"
  printf 'done\n' > "$CHILD_STUB/child-list-status"
  : > "$CHILD_STUB/block-delivery-pane-get"
  printf 'idle 11\n' > "$CHILD_STUB/child-state"
  child_wait_for_file "$CHILD_STUB/delivery-pane-get.ready"

  env PATH="$CHILD_STUB:$PATH" HERDR_ENV=1 HERDR_PANE_ID=wT:p0 \
    HERDR_CHILD_STATE_DIR="$CHILD_STUB/state" \
    HERDR_CHILD_TEST_REAP_INVALIDATED_BARRIER="$CHILD_STUB/reap-invalidated" \
    HERDR_CHILD_TEST_HOLD_TIMEOUT_SECONDS=1 \
    bash "$HERDR_CHILD" reap --to "$(child_started_name)" --pane wT:p9 > "$CHILD_STUB/reap-bounded.out" 2>&1 &
  reap_pid=$!
  CHILD_REAP_PID="$reap_pid"
  child_wait_for_file "$CHILD_STUB/reap-invalidated.ready"
  while kill -0 "$reap_pid" 2>/dev/null && [ "$attempt" -lt 300 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  if kill -0 "$reap_pid" 2>/dev/null; then
    kill -TERM "$reap_pid" 2>/dev/null || true
    wait "$reap_pid" 2>/dev/null || true
    CHILD_REAP_PID=""
    fail 'reap invalidation barrier exceeded its test hold bound'
  fi
  if wait "$reap_pid"; then reap_status=0; else reap_status=$?; fi
  CHILD_REAP_PID=""
  assert_equal "$reap_status" 1
  assert_file_not_exists "$CHILD_STUB/pane-closed"
  assert_dir_exists "$run_dir"
  assert_file_exists "$run_dir/invalidated.state"
  assert_file_exists "$run_dir/reap-pending.state"
  assert_file_exists "$run_dir/reap-restore.state"

  : > "$CHILD_STUB/delivery-pane-get.release"
  child_wait_for_file "$CHILD_STUB/successful-prompts.log"
  attempt=0
  while [ -d "$run_dir" ] && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  [ "$attempt" -lt 500 ]
  assert_file_not_exists "$CHILD_STUB/pane-closed"
  assert_dir_not_exists "$run_dir"
}

function test_scripts_2701_herdr_child_reap_owner_guard_stops_when_run_dir() {
  _bats_test_init 2701 'herdr-child reap owner guard stops when its run directory disappears'
  local work_dir runtime supervision guard_test_pid guard_test_status guard_pid attempt=0
  work_dir="$BATS_TEST_TMPDIR/reap-owner-guard"
  mkdir -p "$work_dir"
  runtime="$SOURCE_ROOT/dot_local/lib/herdr-child-runtime.sh"
  supervision="$SOURCE_ROOT/dot_local/lib/herdr-child-supervision.sh"

  env WORK_DIR="$work_dir" RUNTIME="$runtime" SUPERVISION="$supervision" bash -c '
    set -euo pipefail
    source "$RUNTIME"
    source "$SUPERVISION"

    normal_dir="$WORK_DIR/normal"
    mkdir -p "$normal_dir"
    start_reap_owner_guard "$normal_dir"
    stop_reap_owner_guard "$normal_dir"
    [ -d "$normal_dir" ]
    remove_supervision_run "$normal_dir"

    race_dir="$WORK_DIR/race"
    mkdir -p "$race_dir"
    start_reap_owner_guard "$race_dir"
    printf "%s\n" "$REAP_OWNER_GUARD_PID" > "$WORK_DIR/guard.pid"
    kill -STOP "$REAP_OWNER_GUARD_PID"
    (
      attempt=0
      while [ ! -e "$race_dir/reap-owner-$REAP_OWNER_TOKEN.release" ] && [ "$attempt" -lt 500 ]; do
        attempt=$((attempt + 1))
        sleep 0.01
      done
      [ "$attempt" -lt 500 ]
      remove_supervision_run "$race_dir"
      kill -CONT "$REAP_OWNER_GUARD_PID"
    ) &
    cleanup_pid=$!
    stop_reap_owner_guard "$race_dir"
    wait "$cleanup_pid"
    : > "$WORK_DIR/stopped"
  ' > "$work_dir/guard.out" 2>&1 &
  guard_test_pid=$!

  while kill -0 "$guard_test_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  if kill -0 "$guard_test_pid" 2>/dev/null; then
    guard_pid="$(cat "$work_dir/guard.pid" 2>/dev/null || true)"
    [ -z "$guard_pid" ] || kill -CONT "$guard_pid" 2>/dev/null || true
    [ -z "$guard_pid" ] || kill -TERM "$guard_pid" 2>/dev/null || true
    kill -TERM "$guard_test_pid" 2>/dev/null || true
    wait "$guard_test_pid" 2>/dev/null || true
    fail 'reap owner guard did not stop after its run directory disappeared'
  fi
  if wait "$guard_test_pid"; then guard_test_status=0; else guard_test_status=$?; fi
  assert_equal "$guard_test_status" 0
  assert_file_exists "$work_dir/stopped"
  assert_dir_not_exists "$work_dir/race"
}

function test_scripts_271_herdr_child_shared_lifecycle_primitives_keep_con() {
  _bats_test_init 271 'herdr-child shared lifecycle primitives keep polling and launch-state contracts'
  local work_dir runtime supervision
  # Not a bare mktemp -d: the case keeps launch.state to read it back, and an
  # assertion failing before the last line exits the test (_bats_assert_fail),
  # so a trailing rm never runs on exactly the runs worth repeating. Under
  # BATS_TEST_TMPDIR the file tmproot reaps it either way
  # (docs/solutions/design-patterns/outliving-processes-hang-the-suite.md).
  work_dir="$BATS_TEST_TMPDIR/child-lifecycle"
  mkdir -p "$work_dir"
  runtime="$SOURCE_ROOT/dot_local/lib/herdr-child-runtime.sh"
  supervision="$SOURCE_ROOT/dot_local/lib/herdr-child-supervision.sh"

  run env WORK_DIR="$work_dir" RUNTIME="$runtime" SUPERVISION="$supervision" bash -c '
    set -u
    source "$RUNTIME"
    source "$SUPERVISION"

    IFS=$'"'"'\n'"'"'
    write_launch_state "$WORK_DIR/launch.state" generation-1 12345 parent-pane \
      parent-terminal parent-session child-name child-pane child-terminal \
      child-session 42 || exit 10

    : > "$WORK_DIR/wanted.state"
    wait_for_watcher_state "$WORK_DIR/wanted.state" "$WORK_DIR/failed.state" "$$" || exit 11
    rm -f "$WORK_DIR/wanted.state"
    : > "$WORK_DIR/failed.state"
    status=0
    wait_for_watcher_state "$WORK_DIR/wanted.state" "$WORK_DIR/failed.state" "$$" || status=$?
    [ "$status" -eq 2 ] || exit 12
    rm -f "$WORK_DIR/failed.state"
    : > "$WORK_DIR/failure-only.state"
    wait_for_watcher_failure "$WORK_DIR/failure-only.state" "$$" || exit 13
    rm -f "$WORK_DIR/failure-only.state"
    status=0
    wait_for_watcher_failure "$WORK_DIR/failure-only.state" 2147483647 || status=$?
    [ "$status" -eq 1 ] || exit 14

    if write_launch_state "$WORK_DIR/invalid.state" generation-2 12345 parent-pane \
      parent-terminal parent-session $'"'"'bad\nname'"'"' child-pane child-terminal \
      child-session 42; then
      exit 15
    fi
  '
  assert_success
  # Reading the file back byte-for-byte pinned two things no consumer has: the
  # field order, and mode=, which no reader under home/dot_local/lib parses --
  # the watcher, supervision, and continuation modules all go through
  # state_value with a named key. What is load-bearing is the mapping from
  # write_launch_state's eleven positional arguments onto those keys, so
  # assert it through the same accessor those readers use. The expected values
  # are the arguments this test passed in, not text copied out of the writer.
  run env WORK_DIR="$work_dir" RUNTIME="$runtime" bash -c '
    set -u
    source "$RUNTIME"
    for pair in generation:generation-1 timeout_ms:12345 parent_pane:parent-pane \
      parent_terminal:parent-terminal parent_session:parent-session \
      child_name:child-name child_pane:child-pane child_terminal:child-terminal \
      child_session:child-session baseline_seq:42; do
      key="${pair%%:*}"
      want="${pair#*:}"
      got="$(state_value "$WORK_DIR/launch.state" "$key")"
      [ "$got" = "$want" ] || { printf "%s read back as %s, wanted %s\n" "$key" "$got" "$want"; exit 1; }
    done
  '
  assert_success
  assert_file_not_exists "$work_dir/invalid.state"
}

SKILLS_WRAPPER="$SOURCE_ROOT/dot_local/bin/executable_skills"
# Sampling granularity, not the bound. A stub npx exits in milliseconds, so
# the shipped 0.2s default billed every wrapper call for a fifth of a second
# it never needed. The one test that proves SKILLS_TIMEOUT builds its own
# environment from scratch, so it keeps the shipped default and still burns
# the real two seconds.
export SKILLS_POLL_INTERVAL=0.01

skills_stub_npx() {
  local stub="$BATS_TEST_TMPDIR/skills-stub"
  mkdir -p "$stub"
  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
printf 'PWD=%s\n' "$PWD" >> "$TMPDIR/npx.log"
printf 'HOME=%s\n' "${HOME:-}" >> "$TMPDIR/npx.log"
printf 'XDG_STATE_HOME=%s\n' "${XDG_STATE_HOME:-}" >> "$TMPDIR/npx.log"
printf 'ARGS=' >> "$TMPDIR/npx.log"
printf '<%s>' "$@" >> "$TMPDIR/npx.log"
printf '\n' >> "$TMPDIR/npx.log"
exit "${NPX_STATUS:-0}"
SH
  chmod +x "$stub/npx"
  printf '%s' "$stub"
}

skills_exclusion_stub_npx() {
  local stub="$BATS_TEST_TMPDIR/skills-exclusion-stub"
  mkdir -p "$stub"
  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
printf 'ARGS=' >> "$TMPDIR/npx.log"
printf '<%s>' "$@" >> "$TMPDIR/npx.log"
printf '\n' >> "$TMPDIR/npx.log"
case "$3" in
  add)
    source="$4"
    if [ "$source" = mattpocock/skills ]; then
      mkdir -p "$HOME/.agents/skills/pr"
      printf '%s\n' pr > "$HOME/.agents/skills/pr/SKILL.md"
    else
      mkdir -p "$HOME/.agents/skills/stable" "$HOME/.agents/skills/draft"
      printf '%s\n' stable > "$HOME/.agents/skills/stable/SKILL.md"
      printf '%s\n' draft > "$HOME/.agents/skills/draft/SKILL.md"
    fi
    python3 - "$XDG_STATE_HOME/skills/.skill-lock.json" "$source" <<'PY'
import json, sys
path, source = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    data = json.load(stream)
if source == "mattpocock/skills":
    fixtures = {"pr": {"source": source, "skillPath": "skills/in-progress/pr/SKILL.md"}}
else:
    fixtures = {
        "stable": {"source": source, "skillPath": "skills/stable/SKILL.md"},
        "draft": {"source": source, "skillPath": "skills/in-progress/draft/SKILL.md"},
    }
data["skills"].update(fixtures)
with open(path, "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
    ;;
  remove)
    [ ! -e "$TMPDIR/fail-remove" ] || exit 9
    shift 3
    for skill in "$@"; do
      case "$skill" in --global|--yes) continue ;; esac
      rm -rf "$HOME/.agents/skills/$skill"
      python3 - "$XDG_STATE_HOME/skills/.skill-lock.json" "$skill" <<'PY'
import json, sys
path, skill = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    data = json.load(stream)
data["skills"].pop(skill, None)
with open(path, "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
    done
    ;;
esac
SH
  chmod +x "$stub/npx"
  printf '%s' "$stub"
}

function test_scripts_272_skills_add_is_global_isolated_and_preserves_cwd() {
  _bats_test_init 272 'skills add invokes npx globally in an isolated temporary-directory subshell'
  local stub original
  stub="$(skills_stub_npx)"
  original="$PWD"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache" \
    SKILLS_MANIFEST="$BATS_TEST_TMPDIR/manifest" \
    bash "$SKILLS_WRAPPER" add owner/repo named-skill
  assert_success
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '^PWD=.*/tmp$'
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '^ARGS=<--yes><skills@latest><add><owner/repo><--skill><named-skill><--global><--agent><claude-code><--agent><opencode><--agent><pi><--yes>$'
  assert_equal "$PWD" "$original"

  rm -f "$BATS_TEST_TMPDIR/tmp/npx.log"
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    bash "$SKILLS_WRAPPER" add owner/repo named-skill
  assert_failure
  assert_output --partial 'chezmoi is required for managed skill changes'
  assert_file_not_exists "$BATS_TEST_TMPDIR/tmp/npx.log"
}

function test_scripts_2720_skills_add_saves_the_skill_in_the_manifest() {
  _bats_test_init 2720 'skills add saves a successfully installed skill in the managed manifest'
  local stub manifest
  stub="$(skills_stub_npx)"
  manifest="$BATS_TEST_TMPDIR/manifest"
  printf '%s\n' 'other/repo other-skill' 'owner/repo existing-skill' > "$manifest"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    SKILLS_MANIFEST="$manifest" bash "$SKILLS_WRAPPER" add owner/repo named-skill
  assert_success
  assert_file_contains "$manifest" '^owner/repo existing-skill named-skill$'

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    SKILLS_MANIFEST="$manifest" bash "$SKILLS_WRAPPER" add owner/repo named-skill
  assert_success
  run grep -o 'named-skill' "$manifest"
  assert_success
  assert_output 'named-skill'
}

function test_scripts_27202_skills_add_publishes_the_managed_manifest_through_chezmoi() {
  _bats_test_init 27202 'skills add pulls, captures, commits, and pushes the managed manifest through chezmoi'
  local stub home source_manifest manifest
  stub="$(skills_stub_npx)"
  home="$BATS_TEST_TMPDIR/home"
  manifest="$home/.config/agent-skills/manifest"
  source_manifest="$home/source/home/private_dot_config/agent-skills/manifest"
  mkdir -p "$(dirname "$manifest")" "$(dirname "$source_manifest")" "$BATS_TEST_TMPDIR/tmp"
  printf '%s\n' 'owner/repo existing-skill' > "$manifest"
  cp "$manifest" "$source_manifest"
  cat > "$stub/chezmoi" <<'SH'
#!/usr/bin/env bash
printf '<%s>' "$@" >> "$TMPDIR/chezmoi.log"
printf '\n' >> "$TMPDIR/chezmoi.log"
if [ "$1" = git ]; then
  shift 2
  case "$1" in
    status) [ "${CHEZMOI_DIRTY:-0}" = 0 ] || printf '%s\n' ' M unrelated-file' ;;
    rev-parse) printf '%s\n' origin/main ;;
    pull) exit 0 ;;
    rev-list) printf '%s\n' 0 ;;
    diff) exit 1 ;;
    add|commit|push) exit 0 ;;
  esac
elif [ "$1" = cat ]; then
  cat "$HOME/source/home/private_dot_config/agent-skills/manifest"
elif [ "$1" = add ]; then
  cp "$2" "$HOME/source/home/private_dot_config/agent-skills/manifest"
elif [ "$1" = source-path ]; then
  printf '%s\n' "$HOME/source/home/private_dot_config/agent-skills/manifest"
fi
SH
  chmod +x "$stub/chezmoi"

  run env PATH="$stub:/usr/bin:/bin" HOME="$home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    bash "$SKILLS_WRAPPER" add owner/repo named-skill
  assert_success
  assert_file_contains "$source_manifest" '^owner/repo existing-skill named-skill$'
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/chezmoi.log" '^<git><--><pull><--ff-only>$'
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/chezmoi.log" '^<add>.*/\.config/agent-skills/manifest>$'
  run cat "$BATS_TEST_TMPDIR/tmp/chezmoi.log"
  assert_success
  assert_output --partial '<git><--><commit><-m><chore(skills): add named-skill><-->'
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/chezmoi.log" '^<git><--><push>$'

  mkdir -p "$home/.local/state/skills"
  printf '%s\n' '{"version":3,"skills":{"named-skill":{"source":"owner/repo"}}}' \
    > "$home/.local/state/skills/.skill-lock.json"
  run env PATH="$stub:/usr/bin:/bin" HOME="$home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    bash "$SKILLS_WRAPPER" remove owner/repo named-skill
  assert_success
  run cat "$source_manifest"
  assert_success
  assert_output 'owner/repo existing-skill'
  run cat "$BATS_TEST_TMPDIR/tmp/chezmoi.log"
  assert_success
  assert_output --partial '<git><--><commit><-m><chore(skills): remove named-skill><-->'

  rm -f "$BATS_TEST_TMPDIR/tmp/npx.log"
  run env PATH="$stub:/usr/bin:/bin" HOME="$home" TMPDIR="$BATS_TEST_TMPDIR/tmp" CHEZMOI_DIRTY=1 \
    bash "$SKILLS_WRAPPER" add owner/repo another-skill
  assert_failure
  assert_output --partial 'chezmoi source repository has uncommitted changes'
  assert_file_not_exists "$BATS_TEST_TMPDIR/tmp/npx.log"
}

function test_scripts_2721_skills_hides_success_output_but_preserves_verbose_and_failure_diagnostics() {
  _bats_test_init 2721 'skills hides successful upstream output but preserves verbose and failure diagnostics'
  local stub="$BATS_TEST_TMPDIR/skills-output-stub"
  mkdir -p "$stub"
  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'upstream stdout'
printf '%s\n' 'upstream stderr' >&2
for arg in "$@"; do [ "$arg" != fail ] || exit 7; done
SH
  chmod +x "$stub/npx"
  mkdir -p "$BATS_TEST_TMPDIR/home/.local/state/skills"
  mkdir -p "$BATS_TEST_TMPDIR/home/.config/agent-skills"
  printf '%s\n' '{"version":3,"skills":{"fail":{"source":"owner/repo"}}}' \
    > "$BATS_TEST_TMPDIR/home/.local/state/skills/.skill-lock.json"
  printf '%s\n' 'owner/repo fail' > "$BATS_TEST_TMPDIR/home/.config/agent-skills/manifest"

  run --separate-stderr env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    bash "$SKILLS_WRAPPER" update
  assert_success
  assert_output ''
  assert_stderr ''

  run --separate-stderr env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    bash "$SKILLS_WRAPPER" --verbose update
  assert_success
  assert_output --partial 'upstream stdout'
  refute_output --partial 'upstream stderr'
  assert_stderr --partial 'upstream stderr'
  refute_stderr --partial 'upstream stdout'

  run --separate-stderr env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    bash "$SKILLS_WRAPPER" --verbose update fail
  assert_failure 7
  assert_output --partial 'upstream stdout'
  assert_stderr --partial 'upstream stderr'

  run --separate-stderr env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    bash "$SKILLS_WRAPPER" update fail
  assert_failure 7
  assert_output ''
  assert_stderr --partial 'upstream stdout'
  assert_stderr --partial 'upstream stderr'

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    SKILLS_MANIFEST="$BATS_TEST_TMPDIR/home/.config/agent-skills/manifest" \
    bash "$SKILLS_WRAPPER" add owner/repo fail
  assert_failure 7

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    SKILLS_MANIFEST="$BATS_TEST_TMPDIR/home/.config/agent-skills/manifest" \
    bash "$SKILLS_WRAPPER" remove owner/repo fail
  assert_failure 7

  run bash -c 'for item in "$1"/skills-output.*; do [ ! -e "$item" ] || exit 1; done' _ \
    "$BATS_TEST_TMPDIR/tmp"
  assert_success
}

function test_scripts_2722_skills_removes_captured_output_after_a_signal() {
  _bats_test_init 2722 'skills removes captured upstream output after a signal'
  local stub="$BATS_TEST_TMPDIR/skills-signal-stub"
  mkdir -p "$stub" "$BATS_TEST_TMPDIR/tmp"
  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'captured before interruption'
: > "$TMPDIR/npx-ready"
while :; do sleep 1; done
SH
  chmod +x "$stub/npx"

  run python3 - "$SKILLS_WRAPPER" "$stub" "$BATS_TEST_TMPDIR" <<'PY'
import glob
import os
import signal
import subprocess
import sys
import time

wrapper, stub, root = sys.argv[1:]
tmpdir = os.path.join(root, "tmp")
env = {"PATH": f"{stub}:/usr/bin:/bin", "HOME": os.path.join(root, "home"), "TMPDIR": tmpdir}
process = subprocess.Popen(["bash", wrapper, "update"], env=env, start_new_session=True)
deadline = time.monotonic() + 5
while not os.path.exists(os.path.join(tmpdir, "npx-ready")):
    if process.poll() is not None or time.monotonic() >= deadline:
        process.kill()
        raise SystemExit("upstream stub did not start")
    time.sleep(0.01)
os.killpg(process.pid, signal.SIGTERM)
status = process.wait(timeout=5)
if status == 0:
    raise SystemExit("interrupted wrapper succeeded")
if glob.glob(os.path.join(tmpdir, "skills-output.*")):
    raise SystemExit("captured output survived interruption")
PY
  assert_success
}

function test_scripts_2723_skills_denies_a_prompting_upstream_a_terminal_to_wait_on() {
  _bats_test_init 2723 'skills finishes instead of waiting when upstream prompts for input'
  local stub="$BATS_TEST_TMPDIR/skills-prompt-stub"
  mkdir -p "$stub" "$BATS_TEST_TMPDIR/tmp"
  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'Would you like to remove the local copies of these deleted skills?'
IFS= read -r _answer || exit 3
exit 0
SH
  chmod +x "$stub/npx"

  run python3 - "$SKILLS_WRAPPER" "$stub" "$BATS_TEST_TMPDIR" <<'PY'
import glob
import os
import subprocess
import sys

wrapper, stub, root = sys.argv[1:]
tmpdir = os.path.join(root, "tmp")
env = {"PATH": f"{stub}:/usr/bin:/bin", "HOME": os.path.join(root, "home"), "TMPDIR": tmpdir}
# An open pipe the parent never writes to: the wrapper inherits a stdin that
# never reaches EOF, exactly as it inherits an idle terminal from a shell.
read_fd, write_fd = os.pipe()
process = subprocess.Popen(
    ["bash", wrapper, "update"],
    env=env,
    stdin=read_fd,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    start_new_session=True,
)
os.close(read_fd)
try:
    try:
        _, errors = process.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        process.kill()
        raise SystemExit("wrapper waited on an upstream prompt")
finally:
    os.close(write_fd)
if process.returncode == 0:
    raise SystemExit("wrapper reported success for an unanswered prompt")
if b"remove the local copies" not in errors:
    raise SystemExit("wrapper hid the prompt that stopped the run")
if glob.glob(os.path.join(tmpdir, "skills-output.*")):
    raise SystemExit("captured output survived the run")
PY
  assert_success
}

function test_scripts_2724_skills_bounds_the_wait_and_terminates_the_upstream_tree() {
  _bats_test_init 2724 'skills terminates a stalled upstream process tree after a bounded wait'
  local stub="$BATS_TEST_TMPDIR/skills-stall-stub"
  mkdir -p "$stub" "$BATS_TEST_TMPDIR/tmp"
  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'upstream started'
sleep 300 &
printf '%s\n' "$!" > "$TMPDIR/grandchild.pid"
while :; do sleep 1; done
SH
  chmod +x "$stub/npx"

  run python3 - "$SKILLS_WRAPPER" "$stub" "$BATS_TEST_TMPDIR" <<'PY'
import glob
import os
import subprocess
import sys
import time

wrapper, stub, root = sys.argv[1:]
tmpdir = os.path.join(root, "tmp")
env = {
    "PATH": f"{stub}:/usr/bin:/bin",
    "HOME": os.path.join(root, "home"),
    "TMPDIR": tmpdir,
    "SKILLS_TIMEOUT": "2",
}
process = subprocess.Popen(
    ["bash", wrapper, "update"],
    env=env,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    start_new_session=True,
)
try:
    _, errors = process.communicate(timeout=40)
except subprocess.TimeoutExpired:
    process.kill()
    raise SystemExit("wrapper did not bound its wait on a stalled upstream")
if process.returncode != 124:
    raise SystemExit(f"wrapper reported {process.returncode} instead of a timeout")
if b"upstream started" not in errors:
    raise SystemExit("wrapper discarded the captured output of the stalled run")
grandchild = int(open(os.path.join(tmpdir, "grandchild.pid"), encoding="utf-8").read())
deadline = time.monotonic() + 10
while True:
    try:
        os.kill(grandchild, 0)
    except ProcessLookupError:
        break
    if time.monotonic() >= deadline:
        os.kill(grandchild, 9)
        raise SystemExit("upstream grandchild survived the terminated run")
    time.sleep(0.1)
if glob.glob(os.path.join(tmpdir, "skills-output.*")):
    raise SystemExit("captured output survived the terminated run")
PY
  assert_success
}

function test_scripts_273_skills_dispatch_validates_inert_argv_and_uses_global_remove_update() {
  _bats_test_init 273 'skills validates argv before npx and maps remove and update to global upstream calls'
  local stub="$BATS_TEST_TMPDIR/skills-stub" lock
  stub="$(skills_stub_npx)"
  lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  mkdir -p "$(dirname "$lock")"
  printf '%s\n' '{"version":3,"skills":{"owned":{"source":"owner/repo"}}}' > "$lock"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" SKILLS_MANIFEST="$BATS_TEST_TMPDIR/home/.config/agent-skills/manifest" \
    bash "$SKILLS_WRAPPER" add owner/repo
  assert_success
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '<add><owner/repo><--skill><\*><--global>'

  mkdir -p "$BATS_TEST_TMPDIR/home/.config/agent-skills"
  printf '%s\n' 'owner/repo owned' > "$BATS_TEST_TMPDIR/home/.config/agent-skills/manifest"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" SKILLS_MANIFEST="$BATS_TEST_TMPDIR/home/.config/agent-skills/manifest" \
    bash "$SKILLS_WRAPPER" remove owner/repo owned
  assert_success
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '<remove><--global><owned><--yes>$'

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" bash "$SKILLS_WRAPPER" update owned
  assert_success
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '<update><--global><owned>$'

  rm -f "$BATS_TEST_TMPDIR/tmp/npx.log"
  # Same SKILLS_MANIFEST the legs above carry, so the chezmoi guard cannot be
  # the reason this fails: what is left is the argv check the title claims.
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" SKILLS_MANIFEST="$BATS_TEST_TMPDIR/home/.config/agent-skills/manifest" \
    bash "$SKILLS_WRAPPER" add 'owner/repo;touch'
  assert_failure 1
  assert_output --partial 'skills: invalid source: owner/repo;touch'
  assert_file_not_exists "$BATS_TEST_TMPDIR/tmp/npx.log"
}

function test_scripts_274_skills_rejects_malformed_lock_before_npx() {
  _bats_test_init 274 'skills sync fails closed on malformed live lock without npx mutation'
  local stub lock manifest
  stub="$(skills_stub_npx)"
  manifest="$BATS_TEST_TMPDIR/manifest"
  lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  # sync has several earlier exits -- unreadable manifest, unreadable
  # repository-owned manifest, invalid wildcard exclusion. The fixture supplies
  # a valid one of each so the only thing left to fail on is the lock.
  mkdir -p "$(dirname "$lock")" "$BATS_TEST_TMPDIR/home/.agents/skills"
  : > "$BATS_TEST_TMPDIR/repository-owned"
  printf '%s\n' 'example/upstream-skills *' > "$manifest"
  printf '%s\n' '{not-json' > "$lock"
  cp "$lock" "$BATS_TEST_TMPDIR/lock.before"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$manifest" \
    SKILLS_REPOSITORY_OWNED_MANIFEST="$BATS_TEST_TMPDIR/repository-owned" \
    bash "$SKILLS_WRAPPER" sync
  assert_failure 1
  assert_output --partial 'skills: malformed or unsupported global lock'
  run cmp "$BATS_TEST_TMPDIR/lock.before" "$lock"
  assert_success
  assert_file_not_exists "$BATS_TEST_TMPDIR/tmp/npx.log"

  # The control: one character of the fixture changes -- the lock parses -- and
  # the same sync reaches npx. Without it, "npx never ran" is satisfied by every
  # unrelated way sync can fall over first.
  printf '%s\n' '{"version":3,"skills":{}}' > "$lock"
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$manifest" \
    SKILLS_REPOSITORY_OWNED_MANIFEST="$BATS_TEST_TMPDIR/repository-owned" \
    bash "$SKILLS_WRAPPER" sync
  assert_success
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '^ARGS=<--yes><skills@latest><add><example/upstream-skills><--skill><\*><--global>'
}

function test_scripts_275_skills_sync_stops_on_failed_install_without_drift_report() {
  _bats_test_init 275 'skills sync stops at a failed source install and does not report drift'
  local stub manifest lock
  stub="$(skills_stub_npx)"
  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TMPDIR/npx.log"
exit 9
SH
  chmod +x "$stub/npx"
  manifest="$BATS_TEST_TMPDIR/manifest"
  lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  mkdir -p "$(dirname "$lock")"
  : > "$BATS_TEST_TMPDIR/repository-owned"
  printf '%s\n' 'example/upstream-skills *' > "$manifest"
  printf '%s\n' '{"version":3,"skills":{"obsolete":{"source":"missing/source"}}}' > "$lock"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" SKILLS_MANIFEST="$manifest" \
    SKILLS_REPOSITORY_OWNED_MANIFEST="$BATS_TEST_TMPDIR/repository-owned" \
    bash "$SKILLS_WRAPPER" sync
  assert_failure 9
  refute_output --partial 'drift:'
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '^add$'
}

function test_scripts_276_skills_remove_uses_explicit_and_default_xdg_locks_identically() {
  _bats_test_init 276 'skills remove validates source ownership through explicit and default XDG state locks'
  local stub state_lock fallback_lock
  stub="$(skills_stub_npx)"
  state_lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  fallback_lock="$BATS_TEST_TMPDIR/home/.local/state/skills/.skill-lock.json"
  mkdir -p "$(dirname "$state_lock")" "$(dirname "$fallback_lock")"
  printf '%s\n' '{"version":3,"skills":{"owned":{"source":"owner/repo"}}}' > "$state_lock"
  printf '%s\n' '{"version":3,"skills":{"owned":{"source":"owner/repo"}}}' > "$fallback_lock"
  mkdir -p "$BATS_TEST_TMPDIR/home/.config/agent-skills"
  printf '%s\n' 'owner/repo owned' > "$BATS_TEST_TMPDIR/home/.config/agent-skills/manifest"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" SKILLS_MANIFEST="$BATS_TEST_TMPDIR/home/.config/agent-skills/manifest" \
    bash "$SKILLS_WRAPPER" remove owner/repo owned
  assert_success
  printf '%s\n' 'owner/repo owned' > "$BATS_TEST_TMPDIR/home/.config/agent-skills/manifest"
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME= SKILLS_MANIFEST="$BATS_TEST_TMPDIR/home/.config/agent-skills/manifest" \
    bash "$SKILLS_WRAPPER" remove owner/repo owned
  assert_success
  run grep -c '<remove><--global><owned><--yes>' "$BATS_TEST_TMPDIR/tmp/npx.log"
  assert_success
  assert_output '2'

  # The negative control the two success legs cannot give. Same argv, same
  # manifest, same wrapper -- only the lock's recorded owner differs. Without
  # it, a wrapper that never opened either lock would pass the legs above.
  printf '%s\n' '{"version":3,"skills":{"owned":{"source":"someone/else"}}}' > "$state_lock"
  printf '%s\n' 'owner/repo owned' > "$BATS_TEST_TMPDIR/home/.config/agent-skills/manifest"
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" SKILLS_MANIFEST="$BATS_TEST_TMPDIR/home/.config/agent-skills/manifest" \
    bash "$SKILLS_WRAPPER" remove owner/repo owned
  assert_failure 1
  assert_output --partial 'skills: lock does not own owned as owner/repo'
  run grep -c '<remove><--global><owned><--yes>' "$BATS_TEST_TMPDIR/tmp/npx.log"
  assert_success
  assert_output '2'
}

function test_scripts_277_skills_sync_restores_repository_owned_wildcard_collision() {
  _bats_test_init 277 'skills sync restores repository-owned wildcard collisions whether rejected or excluded'
  local stub manifest lock canonical
  stub="$(skills_stub_npx)"
  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
case "$3" in
  add)
    printf '%s\n' upstream > "$HOME/.agents/skills/local-skill/SKILL.md"
    python3 - "$XDG_STATE_HOME/skills/.skill-lock.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    data = json.load(stream)
data["skills"]["local-skill"] = {
    "source": "example/upstream-skills",
    "skillPath": "skills/in-progress/local-skill/SKILL.md",
}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
    ;;
  remove)
    [ ! -e "$TMPDIR/fail-remove" ] || exit 9
    rm -rf "$HOME/.agents/skills/local-skill"
    python3 - "$XDG_STATE_HOME/skills/.skill-lock.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    data = json.load(stream)
data["skills"].pop("local-skill", None)
with open(path, "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
    ;;
esac
exit 0
SH
  chmod +x "$stub/npx"
  manifest="$BATS_TEST_TMPDIR/manifest"
  lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  canonical="$BATS_TEST_TMPDIR/home/.agents/skills"
  mkdir -p "$(dirname "$lock")" "$canonical/local-skill" "$BATS_TEST_TMPDIR/config/agent-skills"
  printf '%s\n' 'example/upstream-skills *' > "$manifest"
  printf '%s\n' local-skill > "$BATS_TEST_TMPDIR/config/agent-skills/repository-owned"
  printf '%s\n' '{"version":3,"skills":{}}' > "$lock"
  printf '%s\n' original > "$canonical/local-skill/SKILL.md"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$manifest" bash "$SKILLS_WRAPPER" sync
  assert_failure 1
  assert_output --partial 'skills: canonical skill collides with repository-owned skill: local-skill'
  run cat "$canonical/local-skill/SKILL.md"
  assert_success
  assert_output original
  run python3 - "$lock" <<'PY'
import json, sys
assert "local-skill" not in json.load(open(sys.argv[1]))["skills"]
PY
  assert_success

  printf '%s\n' 'example/upstream-skills * !*/in-progress/*' > "$manifest"
  printf '%s\n' '{"version":3,"skills":{}}' > "$lock"
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$manifest" bash "$SKILLS_WRAPPER" sync
  assert_success
  run cat "$canonical/local-skill/SKILL.md"
  assert_success
  assert_output original
  run python3 - "$lock" <<'PY'
import json, sys
assert "local-skill" not in json.load(open(sys.argv[1]))["skills"]
PY
  assert_success

  : > "$BATS_TEST_TMPDIR/tmp/fail-remove"
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$manifest" bash "$SKILLS_WRAPPER" sync
  assert_failure 9
  run cat "$canonical/local-skill/SKILL.md"
  assert_success
  assert_output original
  run python3 - "$lock" <<'PY'
import json, sys
assert "local-skill" not in json.load(open(sys.argv[1]))["skills"]
PY
  assert_success
}

function test_scripts_278_skills_sync_blocks_unsafe_canonical_trees() {
  _bats_test_init 278 'skills sync blocks symlink, non-regular, and oversized canonical entries'
  local kind stub manifest lock canonical item skill offender
  for kind in symlink fifo oversized; do
    stub="$(skills_stub_npx)"
    manifest="$BATS_TEST_TMPDIR/$kind.manifest"
    lock="$BATS_TEST_TMPDIR/$kind/state/skills/.skill-lock.json"
    canonical="$BATS_TEST_TMPDIR/$kind/canonical"
    mkdir -p "$(dirname "$lock")" "$canonical" "$BATS_TEST_TMPDIR/$kind/config/agent-skills"
    : > "$BATS_TEST_TMPDIR/$kind/config/agent-skills/repository-owned"
    printf '%s\n' 'example/upstream-skills upstream-skill' > "$manifest"
    printf '%s\n' '{"version":3,"skills":{"upstream-skill":{"source":"example/upstream-skills"}}}' > "$lock"
    mkdir -p "$canonical/upstream-skill"
    printf '%s\n' skill > "$canonical/upstream-skill/SKILL.md"
    case "$kind" in
      symlink) ln -s /etc/passwd "$canonical/escape"; offender="$canonical/escape" ;;
      fifo) mkfifo "$canonical/non-regular"; offender="$canonical/non-regular" ;;
      oversized) dd if=/dev/zero of="$canonical/oversized" bs=1048577 count=1 2>/dev/null; offender="$canonical/oversized" ;;
    esac
    run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/$kind/home" TMPDIR="$BATS_TEST_TMPDIR/$kind/tmp" \
      XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/$kind/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/$kind/state" \
      SKILLS_MANIFEST="$manifest" SKILLS_CANONICAL_ROOT="$canonical" SKILLS_MAX_FILE_BYTES=1048576 \
    bash "$SKILLS_WRAPPER" sync
    assert_failure
    # A bare assert_failure is satisfied by any of the three iterations, so two
    # of the guards could be deleted and the loop would stay green. The
    # rejected path is this test's own fixture, so requiring the message to
    # name it makes each iteration prove its own guard fired.
    assert_output --partial "$offender"
  done
}

function test_scripts_2781_skills_sync_default_file_limit_accepts_large_documentation() {
  _bats_test_init 2781 'skills sync default file limit accepts a large upstream documentation artifact'
  local stub manifest lock canonical skill
  stub="$(skills_stub_npx)"
  manifest="$BATS_TEST_TMPDIR/manifest"
  lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  canonical="$BATS_TEST_TMPDIR/canonical"
  mkdir -p "$(dirname "$lock")" "$canonical/large-doc" "$BATS_TEST_TMPDIR/config/agent-skills"
  : > "$BATS_TEST_TMPDIR/config/agent-skills/repository-owned"
  printf '%s\n' 'example/large-doc large-doc' > "$manifest"
  printf '%s\n' '{"version":3,"skills":{"large-doc":{"source":"example/large-doc"}}}' > "$lock"
  dd if=/dev/zero of="$canonical/large-doc/llms-full.txt" bs=1105837 count=1 2>/dev/null
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$manifest" SKILLS_CANONICAL_ROOT="$canonical" bash "$SKILLS_WRAPPER" sync
  assert_success

  dd if=/dev/zero of="$canonical/large-doc/llms-full.txt" bs=2097153 count=1 2>/dev/null
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$manifest" SKILLS_CANONICAL_ROOT="$canonical" bash "$SKILLS_WRAPPER" sync
  assert_failure
  assert_output --partial 'canonical tree file exceeds 2097152 bytes'
}

function test_scripts_279_skills_sync_offers_to_remove_or_save_named_drift_but_not_wildcard_drift() {
  _bats_test_init 279 'skills sync offers remove and add commands for non-wildcard drift'
  local stub manifest lock canonical skill
  stub="$(skills_stub_npx)"
  manifest="$BATS_TEST_TMPDIR/manifest"
  lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  canonical="$BATS_TEST_TMPDIR/canonical"
  mkdir -p "$(dirname "$lock")" "$BATS_TEST_TMPDIR/config/agent-skills"
  : > "$BATS_TEST_TMPDIR/config/agent-skills/repository-owned"
  printf '%s\n' 'example/upstream-skills *' 'owner/repo desired' > "$manifest"
  printf '%s\n' '{"version":3,"skills":{"upstream-skill":{"source":"example/upstream-skills"},"desired":{"source":"owner/repo"},"stale":{"source":"owner/repo"},"orphan":{"source":"gone/repo"}}}' > "$lock"
  for skill in upstream-skill desired; do
    mkdir -p "$canonical/$skill"
    printf '%s\n' skill > "$canonical/$skill/SKILL.md"
  done
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$manifest" SKILLS_CANONICAL_ROOT="$canonical" bash "$SKILLS_WRAPPER" sync
  assert_success
  assert_output --partial 'Installing skills from example/upstream-skills: *'
  assert_output --partial 'Installing skills from owner/repo: desired'
  assert_output --partial 'drift: skills remove owner/repo stale'
  assert_output --partial 'keep:  skills add owner/repo stale'
  assert_output --partial 'drift: skills remove gone/repo orphan'
  assert_output --partial 'keep:  skills add gone/repo orphan'
  refute_output --partial 'drift: skills remove example/upstream-skills upstream-skill'
}

function test_scripts_307_skills_sync_removes_wildcard_path_exclusions() {
  _bats_test_init 307 'skills sync removes wildcard exclusions by upstream path and reports their names'
  local stub manifest lock canonical
  stub="$(skills_exclusion_stub_npx)"
  manifest="$BATS_TEST_TMPDIR/manifest"
  lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  canonical="$BATS_TEST_TMPDIR/home/.agents/skills"
  mkdir -p "$(dirname "$lock")" "$BATS_TEST_TMPDIR/config/agent-skills"
  : > "$BATS_TEST_TMPDIR/config/agent-skills/repository-owned"
  printf '%s\n' 'example/upstream-skills * !*/in-progress/*' > "$manifest"
  printf '%s\n' '{"version":3,"skills":{}}' > "$lock"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$manifest" bash "$SKILLS_WRAPPER" sync
  assert_success
  assert_output --partial 'Excluded skills from example/upstream-skills: draft'
  assert_dir_exists "$canonical/stable"
  assert_dir_not_exists "$canonical/draft"
  run python3 - "$lock" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    skills = json.load(stream)["skills"]
assert set(skills) == {"stable"}
PY
  assert_success
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '<add><example/upstream-skills><--skill><\*><--global>'
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '<remove><--global><draft><--yes>$'
}

function test_scripts_3071_skills_add_persists_and_applies_wildcard_path_exclusions() {
  _bats_test_init 3071 'skills add persists wildcard path exclusions and removes matching installed skills'
  local stub manifest lock canonical
  stub="$(skills_exclusion_stub_npx)"
  manifest="$BATS_TEST_TMPDIR/manifest"
  lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  canonical="$BATS_TEST_TMPDIR/home/.agents/skills"
  mkdir -p "$(dirname "$lock")" "$canonical/draft" "$BATS_TEST_TMPDIR/config/agent-skills"
  printf '%s\n' draft > "$BATS_TEST_TMPDIR/config/agent-skills/repository-owned"
  printf '%s\n' original > "$canonical/draft/SKILL.md"
  printf '%s\n' 'other/repo other-skill' > "$manifest"
  printf '%s\n' '{"version":3,"skills":{}}' > "$lock"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$manifest" \
    bash "$SKILLS_WRAPPER" --verbose add owner/repo '*' '!*/in-progress/*'
  assert_success
  assert_output --partial 'Excluded skills from owner/repo: draft'
  assert_file_contains "$manifest" '^owner/repo \* !\*/in-progress/\*$'
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '<add><owner/repo><--skill><\*><--global>'
  assert_file_not_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '<--skill><!*/in-progress/*>'
  assert_file_contains "$BATS_TEST_TMPDIR/tmp/npx.log" '<remove><--global><draft><--yes>$'
  run python3 - "$lock" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    skills = json.load(stream)["skills"]
assert set(skills) == {"stable"}
PY
  assert_success
  run cat "$canonical/draft/SKILL.md"
  assert_success
  assert_output original

  : > "$BATS_TEST_TMPDIR/tmp/fail-remove"
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$manifest" \
    bash "$SKILLS_WRAPPER" --verbose add owner/repo '*' '!*/in-progress/*'
  assert_failure 9
  run cat "$canonical/draft/SKILL.md"
  assert_success
  assert_output original
  run python3 - "$lock" <<'PY'
import json, sys
assert "draft" not in json.load(open(sys.argv[1]))["skills"]
PY
  assert_success
}

function test_scripts_3072_skills_remove_points_wildcard_sources_to_exclusion_syntax() {
  _bats_test_init 3072 'skills remove points wildcard sources to persistent path exclusion syntax'
  local stub manifest lock
  stub="$(skills_stub_npx)"
  manifest="$BATS_TEST_TMPDIR/manifest"
  lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  mkdir -p "$(dirname "$lock")"
  printf '%s\n' 'owner/repo * !*/in-progress/*' > "$manifest"
  printf '%s\n' '{"version":3,"skills":{"draft":{"source":"owner/repo","skillPath":"skills/in-progress/draft/SKILL.md"}}}' > "$lock"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" SKILLS_MANIFEST="$manifest" \
    bash "$SKILLS_WRAPPER" remove owner/repo draft
  assert_failure
  assert_output --partial 'cannot persist removal from wildcard manifest source: owner/repo; use !<glob> after * to exclude upstream paths'
  assert_file_not_exists "$BATS_TEST_TMPDIR/tmp/npx.log"
}

function test_scripts_3075_skills_add_preserves_existing_wildcard_exclusions() {
  _bats_test_init 3075 'skills wildcard-only re-adds reapply stored exclusions'
  local stub manifest lock canonical
  stub="$(skills_exclusion_stub_npx)"
  manifest="$BATS_TEST_TMPDIR/manifest"
  lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  canonical="$BATS_TEST_TMPDIR/home/.agents/skills"
  mkdir -p "$(dirname "$lock")" "$BATS_TEST_TMPDIR/config/agent-skills"
  : > "$BATS_TEST_TMPDIR/config/agent-skills/repository-owned"
  printf '%s\n' 'owner/repo * !*/in-progress/*' > "$manifest"
  printf '%s\n' '{"version":3,"skills":{}}' > "$lock"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$manifest" \
    bash "$SKILLS_WRAPPER" add owner/repo
  assert_success
  assert_output --partial 'Excluded skills from owner/repo: draft'
  assert_file_contains "$manifest" '^owner/repo \* !\*/in-progress/\*$'
  assert_dir_exists "$canonical/stable"
  assert_dir_not_exists "$canonical/draft"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
    SKILLS_MANIFEST="$manifest" \
    bash "$SKILLS_WRAPPER" add owner/repo '*'
  assert_success
  assert_output --partial 'Excluded skills from owner/repo: draft'
  assert_file_contains "$manifest" '^owner/repo \* !\*/in-progress/\*$'
  assert_dir_not_exists "$canonical/draft"

  run python3 - "$lock" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    skills = json.load(stream)["skills"]
assert set(skills) == {"stable"}
PY
  assert_success
}

function test_scripts_3073_skills_add_rejects_named_or_unbound_exclusion_entries() {
  _bats_test_init 3073 'skills add keeps named selections separate from wildcard exclusions'
  local stub lock
  stub="$(skills_stub_npx)"
  lock="$BATS_TEST_TMPDIR/state/skills/.skill-lock.json"
  mkdir -p "$(dirname "$lock")"
  printf '%s\n' '{"version":3,"skills":{}}' > "$lock"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" SKILLS_MANIFEST="$BATS_TEST_TMPDIR/manifest" \
    bash "$SKILLS_WRAPPER" add owner/repo '*' named-skill
  assert_failure
  assert_output --partial 'wildcard cannot be mixed with named skills: owner/repo'

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" SKILLS_MANIFEST="$BATS_TEST_TMPDIR/manifest" \
    bash "$SKILLS_WRAPPER" add owner/repo '!*/in-progress/*'
  assert_failure
  assert_output --partial 'invalid wildcard exclusion: owner/repo !*/in-progress/*'
  assert_file_not_exists "$BATS_TEST_TMPDIR/tmp/npx.log"
}

function test_scripts_3074_skills_exclusion_fake_matches_the_real_lock_path_contract() {
  _bats_test_init 3074 'skills exclusion fake matches the real Skills CLI lock path contract'
  command_exists npx || skip 'npx is required as the Skills CLI oracle'
  local real_home real_state real_paths stub fake_home fake_state
  real_home="$BATS_TEST_TMPDIR/real-home"
  real_state="$BATS_TEST_TMPDIR/real-state"
  fake_home="$BATS_TEST_TMPDIR/fake-home"
  fake_state="$BATS_TEST_TMPDIR/fake-state"
  mkdir -p "$real_home" "$real_state/skills" "$fake_home" "$fake_state/skills" "$BATS_TEST_TMPDIR/tmp"

  run python3 - "$real_home" "$real_state" "$BATS_TEST_TMPDIR" <<'PY'
import os
import signal
import subprocess
import sys

home, state, root = sys.argv[1:]
env = os.environ.copy()
env.update({
    "HOME": home,
    "TMPDIR": os.path.join(root, "tmp"),
    "XDG_STATE_HOME": state,
    "XDG_CONFIG_HOME": os.path.join(root, "real-config"),
    "XDG_DATA_HOME": os.path.join(root, "real-data"),
    "XDG_CACHE_HOME": os.path.join(root, "real-cache"),
    "CI": "1",
    "NO_COLOR": "1",
})
try:
    process = subprocess.Popen(
        ["npx", "--yes", "skills@latest", "add", "mattpocock/skills", "--skill", "pr",
         "--global", "--agent", "claude-code", "--yes"],
        cwd=env["TMPDIR"],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    stdout, _ = process.communicate(timeout=60)
except subprocess.TimeoutExpired as error:
    os.killpg(process.pid, signal.SIGKILL)
    stdout, _ = process.communicate()
    sys.stdout.buffer.write(stdout)
    print("real Skills CLI fixture timed out after %ss" % error.timeout)
    sys.exit(124)
sys.stdout.buffer.write(stdout)
sys.exit(process.returncode)
PY
  [ "$status" -eq 0 ] || skip "real Skills CLI fixture is unavailable: $output"
  run python3 - "$real_state/skills/.skill-lock.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    skills = json.load(stream)["skills"]
print(json.dumps({
    name: {"source": entry["source"], "skillPath": entry["skillPath"]}
    for name, entry in skills.items()
}, sort_keys=True))
PY
  assert_success
  real_paths="$output"

  stub="$(skills_exclusion_stub_npx)"
  printf '%s\n' '{"version":3,"skills":{}}' > "$fake_state/skills/.skill-lock.json"
  run env HOME="$fake_home" TMPDIR="$BATS_TEST_TMPDIR/tmp" XDG_STATE_HOME="$fake_state" \
    "$stub/npx" --yes skills@latest add mattpocock/skills --skill pr --global --agent claude-code --yes
  assert_success
  run python3 - "$fake_state/skills/.skill-lock.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    skills = json.load(stream)["skills"]
print(json.dumps({
    name: {"source": entry["source"], "skillPath": entry["skillPath"]}
    for name, entry in skills.items()
}, sort_keys=True))
PY
  assert_success
  assert_output "$real_paths"
}

# ===========================================
# agent-skills onchange hook
# ===========================================

AGENT_SKILLS_SYNC_TMPL="$SOURCE_ROOT/.chezmoiscripts/run_onchange_after_9-sync-agent-skills.sh.tmpl"

render_agent_skills_sync() {
  chezmoi_full_fixture_finite_stdin --source "$SOURCE_ROOT" execute-template < "$AGENT_SKILLS_SYNC_TMPL"
}

function test_scripts_280_agent_skills_sync_hook_renders_valid_bash_and_skips_disposable_homes() {
  _bats_test_init 280 'agent-skills sync hook is valid Bash and skips network work in disposable homes'
  skip_if_no_chezmoi
  BATS_TEST_TMPFILE="$BATS_TEST_TMPDIR/sync-agent-skills.sh"
  render_agent_skills_sync > "$BATS_TEST_TMPFILE"
  run bash -n "$BATS_TEST_TMPFILE"
  assert_success

  local stub="$BATS_TEST_TMPDIR/disposable-bin"
  mkdir -p "$stub"
  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
: > "$TMPDIR/npx-ran"
exit 99
SH
  chmod +x "$stub/npx"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    MMS_DISPOSABLE_HOME=1 SKILLS_MANIFEST=ambient-manifest bash "$BATS_TEST_TMPFILE"
  assert_success
  assert_output --partial 'skipping agent-skills synchronization in disposable home'
  assert_file_not_exists "$BATS_TEST_TMPDIR/tmp/npx-ran"
}

function test_scripts_281_agent_skills_sync_hook_reports_node_and_npx_prerequisites() {
  _bats_test_init 281 'agent-skills sync hook clearly rejects missing or incompatible Node.js and npx'
  skip_if_no_chezmoi
  BATS_TEST_TMPFILE="$BATS_TEST_TMPDIR/sync-agent-skills.sh"
  render_agent_skills_sync > "$BATS_TEST_TMPFILE"
  local stub="$BATS_TEST_TMPDIR/prerequisite-bin"
  mkdir -p "$stub"

  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" MMS_DISPOSABLE_HOME=0 bash "$BATS_TEST_TMPFILE"
  assert_failure
  assert_output --partial 'Node.js is not available'

  cat > "$stub/node" <<'SH'
#!/usr/bin/env bash
[ "$1" != --version ] || exit 1
SH
  chmod +x "$stub/node"
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" MMS_DISPOSABLE_HOME=0 bash "$BATS_TEST_TMPFILE"
  assert_failure
  assert_output --partial 'Node.js is unavailable or incompatible'

  cat > "$stub/node" <<'SH'
#!/usr/bin/env bash
printf '%s\n' v22.0.0
SH
  chmod +x "$stub/node"
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" MMS_DISPOSABLE_HOME=0 bash "$BATS_TEST_TMPFILE"
  assert_failure
  assert_output --partial 'npx is not available'

  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
[ "$1" != --version ] || exit 1
SH
  chmod +x "$stub/npx"
  run env PATH="$stub:/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR/home" MMS_DISPOSABLE_HOME=0 bash "$BATS_TEST_TMPFILE"
  assert_failure
  assert_output --partial 'npx is unavailable or incompatible'
}

function test_scripts_282_agent_skills_sync_hook_unsets_manifest_and_preserves_wrapper_failure() {
  _bats_test_init 282 'agent-skills sync hook invokes the deployed wrapper with no ambient manifest and preserves its status'
  skip_if_no_chezmoi
  BATS_TEST_TMPFILE="$BATS_TEST_TMPDIR/sync-agent-skills.sh"
  render_agent_skills_sync > "$BATS_TEST_TMPFILE"
  local home="$BATS_TEST_TMPDIR/home" stub="$BATS_TEST_TMPDIR/healthy-bin"
  mkdir -p "$home/.local/bin" "$stub"
  cat > "$stub/node" <<'SH'
#!/usr/bin/env bash
printf '%s\n' v22.0.0
SH
  cat > "$stub/npx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 10.0.0
SH
  cat > "$home/.local/bin/skills" <<'SH'
#!/usr/bin/env bash
printf 'manifest=%s\n' "${SKILLS_MANIFEST-unset}" > "$HOME/wrapper.log"
exit 23
SH
  chmod +x "$stub/node" "$stub/npx" "$home/.local/bin/skills"

  run env PATH="$stub:/usr/bin:/bin" HOME="$home" MMS_DISPOSABLE_HOME=0 SKILLS_MANIFEST=ambient-manifest bash "$BATS_TEST_TMPFILE"
  assert_failure 23
  run cat "$home/wrapper.log"
  assert_success
  assert_output 'manifest=unset'
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function tear_down() {
  if [ -n "${CHILD_STUB:-}" ] && [ -e "$CHILD_STUB/failure-publish.ready" ]; then
    : > "$CHILD_STUB/failure-publish.release"
  fi
  _bats_run_teardown
}

# ===========================================
# herdr-worktree-identity client adapters (U6)
# ===========================================

HWI_CLAUDE_HOOK="$SOURCE_ROOT/private_dot_claude/hooks/executable_herdr-worktree-identity-hook.sh"
HWI_OPENCODE_PLUGIN_SOURCE="$SOURCE_ROOT/private_dot_config/opencode/plugins/herdr-worktree-identity.ts"
HRC_CLAUDE_HOOK="$SOURCE_ROOT/private_dot_claude/hooks/executable_herdr-resource-context.sh"

hwi_adapter_stub_engine() {
  local root="$1"
  mkdir -p "$root"
  cat > "$root/engine" <<'SH'
#!/usr/bin/env bash
set -eu
call="$HWI_ADAPTER_TEST_DIR/call-$$"
mkdir "$call"
printf '%s\n' "$@" > "$call/argv"
cat > "$call/stdin"
: > "$call/ready"
(
  while [ ! -e "$HWI_ADAPTER_TEST_DIR/release" ]; do sleep 0.01; done
  : > "$call/released"
) &
exit 0
SH
  chmod +x "$root/engine"
}

hwi_wait_for_file() {
  local path="$1" attempt=0
  while [[ ! -e "$path" && "$attempt" -lt 3000 ]]; do
    attempt=$((attempt + 1))
    sleep 0.01
  done
  if [[ -e "$path" ]]; then
    return 0
  fi
  return 1
}

function test_scripts_1222_claude_worktree_identity_hook_hands_off_prompt_on_stdin() {
  _bats_test_init 1222 'claude worktree identity hook passes prompt on stdin and returns after handoff'
  local root="$BATS_TEST_TMPDIR/claude-adapter" prompt='Name this Claude task: stdin-only sentinel'
  hwi_adapter_stub_engine "$root"

  run env HERDR_ENV=1 HERDR_PANE_ID=pane-claude HERDR_WORKSPACE_ID=workspace-claude \
    HERDR_WORKTREE_IDENTITY_ENGINE="$root/engine" HWI_ADAPTER_TEST_DIR="$root" \
    bash "$HWI_CLAUDE_HOOK" <<< "{\"session_id\":\"session-claude\",\"prompt\":\"$prompt\"}"
  assert_success
  assert_output ''
  local call
  call="$(find "$root" -mindepth 1 -maxdepth 1 -type d -name 'call-*' | head -n 1)"
  [[ -n "$call" ]] || fail 'the external engine did not receive the Claude prompt event'
  assert_file_contains "$call/stdin" "^$prompt$"
  assert_file_not_contains "$call/argv" "$prompt"
  assert_file_contains "$call/argv" '^--agent$'
  assert_file_contains "$call/argv" '^claude$'
  assert_file_contains "$call/argv" '^--pane$'
  assert_file_contains "$call/argv" '^pane-claude$'
  hwi_wait_for_file "$call/ready" || fail 'the external engine did not enter slow derivation'
  assert_file_not_exists "$call/released"
  : > "$root/release"
  hwi_wait_for_file "$call/released" || fail 'the slow derivation was not released'
}

function test_scripts_1223_claude_worktree_identity_hook_fails_open_without_engine() {
  _bats_test_init 1223 'claude worktree identity hook is quiet when unavailable or gated'
  run env HERDR_ENV=1 HERDR_WORKTREE_IDENTITY_ENGINE="$BATS_TEST_TMPDIR/missing-engine" \
    bash "$HWI_CLAUDE_HOOK" <<< '{"session_id":"session-claude","prompt":"ignored"}'
  assert_success
  assert_output ''

  local root="$BATS_TEST_TMPDIR/claude-gated"
  hwi_adapter_stub_engine "$root"
  run env HERDR_ENV= HERDR_WORKTREE_IDENTITY_ENGINE="$root/engine" HWI_ADAPTER_TEST_DIR="$root" \
    bash "$HWI_CLAUDE_HOOK" <<< '{"session_id":"session-claude","prompt":"outside herdr"}'
  assert_success
  run env HERDR_ENV=1 HERDR_WORKTREE_IDENTITY_ACTIVE=1 HERDR_WORKTREE_IDENTITY_ENGINE="$root/engine" HWI_ADAPTER_TEST_DIR="$root" \
    bash "$HWI_CLAUDE_HOOK" <<< '{"session_id":"session-claude","prompt":"recursive naming"}'
  assert_success
  run find "$root" -mindepth 1 -maxdepth 1 -type d -name 'call-*' -print
  assert_success
  assert_output ''
}

hrc_stub_hooks() {
  local root="$1"
  mkdir -p "$root/bin"
  cat > "$root/bin/herdr-resource-tree" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$HRC_TEST_DIR/query-argv"
[ -z "${HRC_QUERY_STATUS:-}" ] || exit "$HRC_QUERY_STATUS"
cat "$HRC_TEST_DIR/context"
SH
  cat > "$root/bin/herdr-agent-state" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$HRC_TEST_DIR/state-argv"
cat >> "$HRC_TEST_DIR/state-input"
SH
  chmod +x "$root/bin/herdr-resource-tree" "$root/bin/herdr-agent-state"
}

hrc_payload() {
  local event="$1" session="$2" source="${3:-}" agent_id="${4:-}"
  jq -nc --arg event "$event" --arg session "$session" --arg source "$source" --arg agent_id "$agent_id" '
    {hook_event_name: $event, session_id: $session, cwd: "/tmp"}
    + (if $source == "" then {} else {source: $source} end)
    + (if $agent_id == "" then {} else {agent_id: $agent_id} end)'
}

hrc_run() {
  local root="$1" event="$2" session="$3" source="${4:-}" agent_id="${5:-}"
  env HOME="$root/home" HERDR_ENV=1 HRC_TEST_DIR="$root" \
    HERDR_RESOURCE_CONTEXT_CLI="$root/bin/herdr-resource-tree" \
    HERDR_AGENT_STATE_HOOK="$root/bin/herdr-agent-state" \
    HERDR_RESOURCE_CONTEXT_STATE_DIR="$root/state" \
    bash "$HRC_CLAUDE_HOOK" <<< "$(hrc_payload "$event" "$session" "$source" "$agent_id")"
}

function test_scripts_1225_claude_resource_context_reaches_each_model_request_without_duplicate_turns() {
  _bats_test_init 1225 'Claude resource context reaches model input and refreshes only when changed'
  local root="$BATS_TEST_TMPDIR/resource-context" response
  hrc_stub_hooks "$root"
  printf '%s\n' 'Parent agent: "parent-a" [herdr:claude/id/parent-A]' \
    'Descendant agent: "child-old" [herdr:pi/id/child-old]' > "$root/context"

  run hrc_run "$root" SessionStart session-current startup
  assert_success
  response="$output"
  run jq -r '.hookSpecificOutput.hookEventName' <<< "$response"
  assert_success
  assert_output 'SessionStart'
  run jq -r '.hookSpecificOutput.additionalContext' <<< "$response"
  assert_success
  assert_output --partial 'Parent agent: "parent-a"'
  assert_output --partial 'child-old'
  run jq -e 'has("initialUserMessage") or has("systemMessage") or has("decision")' <<< "$response"
  assert_failure
  assert_file_contains "$root/state-argv" '^session$'
  assert_file_contains "$root/state-input" '"session_id":"session-current"'
  run paste -sd ' ' "$root/query-argv"
  assert_success
  assert_output '--context --caller-agent claude --caller-session-id session-current'

  # The unchanged projection is already in the conversation. Re-emitting it on
  # every lifecycle event would only add duplicate system reminders.
  run hrc_run "$root" UserPromptSubmit session-current
  assert_success
  assert_output ''

  printf '%s\n' 'Parent agent: "parent-a" [herdr:claude/id/parent-A]' \
    'Descendant agent: "child-new" [herdr:pi/id/child-new]' > "$root/context"
  run hrc_run "$root" UserPromptSubmit session-current
  assert_success
  response="$output"
  run jq -r '.hookSpecificOutput.hookEventName' <<< "$response"
  assert_success
  assert_output 'UserPromptSubmit'
  run jq -r '.hookSpecificOutput.additionalContext' <<< "$response"
  assert_success
  assert_output --partial 'child-new'
  refute_output --partial 'child-old'

  run hrc_run "$root" PostToolBatch session-current
  assert_success
  assert_output ''
  printf '%s\n' 'Descendant agent: "child-latest" [herdr:pi/id/child-latest]' > "$root/context"
  run hrc_run "$root" PostToolBatch session-current
  assert_success
  response="$output"
  run jq -r '.hookSpecificOutput.hookEventName' <<< "$response"
  assert_success
  assert_output 'PostToolBatch'
  run jq -r '.hookSpecificOutput.additionalContext' <<< "$response"
  assert_success
  assert_output --partial 'child-latest'

  # Compaction keeps the Claude session identity, but the compacted model input
  # needs the current projection restored even when it has not changed.
  run hrc_run "$root" SessionStart session-current compact
  assert_success
  assert_output --partial 'child-latest'
  assert_file_contains "$root/state-input" '"source":"compact"'

  run hrc_run "$root" SessionStart session-current resume
  assert_success
  assert_output --partial 'child-latest'
  assert_file_contains "$root/state-input" '"source":"resume"'
}

function test_scripts_1226_claude_resource_context_is_session_scoped_and_marks_unavailable_queries() {
  _bats_test_init 1226 'Claude resource context does not leak across sessions and marks unavailable queries'
  local root="$BATS_TEST_TMPDIR/resource-context-guards"
  hrc_stub_hooks "$root"
  printf '%s\n' 'Resources:' '- pane "owned" [w1:p1]' > "$root/context"

  run hrc_run "$root" SessionStart session-old startup
  assert_success
  local response="$output"
  run jq -r '.hookSpecificOutput.additionalContext' <<< "$response"
  assert_success
  assert_output --partial 'pane "owned"'

  # A successful empty projection invalidates stale generated context without
  # inventing an empty resource listing.
  : > "$root/context"
  run hrc_run "$root" UserPromptSubmit session-old
  assert_success
  local cleared="$output"
  run jq -e '.hookSpecificOutput.additionalContext | length > 0' <<< "$cleared"
  assert_success
  run jq -r '.hookSpecificOutput.additionalContext' <<< "$cleared"
  assert_success
  refute_output --partial 'Resources:'

  # The shared query rejects a stale pane occupant through the expected session
  # arguments. Query failure must not be presented as a complete empty tree.
  HRC_QUERY_STATUS=1 run hrc_run "$root" SessionStart session-fresh startup
  assert_success
  local unavailable="$output"
  run jq -r '.hookSpecificOutput.additionalContext' <<< "$unavailable"
  assert_success
  assert_output --partial 'Agent resource context unavailable'
  assert_output --partial 'earlier generated resource context is stale'
  assert_output --partial 'must not be treated as an empty resource branch'
  run paste -sd ' ' "$root/query-argv"
  assert_success
  assert_output '--context --caller-agent claude --caller-session-id session-fresh'

  # A transient failure invalidates the dedupe state. The next successful
  # query must restore the projection even when its value did not change.
  printf '%s\n' 'Resources:' '- pane "restored" [w1:p2]' > "$root/context"
  run hrc_run "$root" SessionStart session-recovery startup
  assert_success
  assert_output --partial 'pane \"restored\"'
  HRC_QUERY_STATUS=1 run hrc_run "$root" UserPromptSubmit session-recovery
  assert_success
  assert_output --partial 'Agent resource context unavailable'
  run hrc_run "$root" UserPromptSubmit session-recovery
  assert_success
  assert_output --partial 'pane \"restored\"'

  rm -f "$root/query-argv"
  run hrc_run "$root" UserPromptSubmit session-fresh '' subagent-1
  assert_success
  assert_output ''
  assert_file_not_exists "$root/query-argv"

  # A subagent id carrying a newline still suppresses the hook. Reading the
  # payload one line per field would leave agent_id empty and promote the
  # remainder into session_id, querying the parent pane's branch from a
  # subagent turn.
  rm -f "$root/query-argv"
  run hrc_run "$root" UserPromptSubmit session-fresh '' "$(printf '\nsub')"
  assert_success
  assert_output ''
  assert_file_not_exists "$root/query-argv"

  # Control: the same turn without an agent id must reach the CLI, so the
  # rejection above cannot pass by never querying at all.
  rm -f "$root/query-argv"
  run hrc_run "$root" UserPromptSubmit session-control
  assert_success
  assert_file_exists "$root/query-argv"

  run env HOME="$root/home" HERDR_ENV= HRC_TEST_DIR="$root/outside" \
    HERDR_RESOURCE_CONTEXT_CLI="$root/bin/herdr-resource-tree" \
    bash "$HRC_CLAUDE_HOOK" <<< "$(hrc_payload UserPromptSubmit outside)"
  assert_success
  assert_output ''
  assert_dir_not_exists "$root/outside"
}

hrc_run_without_jq() {
  local root="$1" event="$2" session="$3" minimal="$1/nojq"
  # PATH carries only what the hook and the stubbed reporter need to run, so
  # jq is genuinely absent rather than merely shadowed.
  mkdir -p "$minimal"
  ln -sf "$(command -v bash)" "$minimal/bash"
  ln -sf "$(command -v cat)" "$minimal/cat"
  env HOME="$root/home" HERDR_ENV=1 HRC_TEST_DIR="$root" PATH="$minimal" \
    HERDR_RESOURCE_CONTEXT_CLI="$root/bin/herdr-resource-tree" \
    HERDR_AGENT_STATE_HOOK="$root/bin/herdr-agent-state" \
    HERDR_RESOURCE_CONTEXT_STATE_DIR="$root/state" \
    bash "$HRC_CLAUDE_HOOK" <<< "$(hrc_payload "$event" "$session" startup)"
}

function test_scripts_1247_claude_resource_context_reports_session_identity_without_jq() {
  _bats_test_init 1247 'Claude resource context reports Agent session identity without jq'
  local root="$BATS_TEST_TMPDIR/resource-context-nojq"
  hrc_stub_hooks "$root"
  : > "$root/context"

  # Herdr's reporter needs no jq, and creator attribution, record-child and
  # branch resolution all fail once the Agent session is unknown. A missing jq
  # must degrade only the projection.
  run hrc_run_without_jq "$root" SessionStart session-nojq
  assert_success
  assert_output ''
  assert_file_contains "$root/state-argv" '^session$'

  # Control: the projection is the part jq gates, so it must not have queried.
  assert_file_not_exists "$root/query-argv"
}

function test_scripts_1248_claude_resource_context_states_one_outage_once() {
  _bats_test_init 1248 'Claude resource context states a persistent outage once per conversation'
  local root="$BATS_TEST_TMPDIR/resource-context-outage"
  hrc_stub_hooks "$root"
  printf '%s\n' 'Parent agent: "parent-a" [herdr:claude/id/parent-A]' > "$root/context"

  # A pane with no observable Agent session fails for the whole conversation,
  # and Claude's transcript is append-only: restating the notice on every tool
  # batch only grows context.
  HRC_QUERY_STATUS=1 run hrc_run "$root" UserPromptSubmit session-outage
  assert_success
  assert_output --partial 'resource context unavailable'

  HRC_QUERY_STATUS=1 run hrc_run "$root" PostToolBatch session-outage
  assert_success
  assert_output ''

  # A fresh conversation cannot know about the outage, so SessionStart still
  # emits.
  HRC_QUERY_STATUS=1 run hrc_run "$root" SessionStart session-outage
  assert_success
  assert_output --partial 'resource context unavailable'

  # Recovery re-declares the projection authoritative rather than staying quiet.
  run hrc_run "$root" PostToolBatch session-outage
  assert_success
  assert_output --partial 'parent-a'
}

function test_scripts_1224_opencode_worktree_identity_plugin_uses_deployed_consumer_boundary() {
  _bats_test_init 1224 'deployed opencode plugin gates and delivers every prompt on stdin'
  command_exists bun || skip 'bun is required'
  local root home deployed
  root="$BATS_TEST_TMPDIR/opencode-adapter"
  home="$root/home"
  deployed="$home/.config/opencode/plugins"
  mkdir -p "$deployed" "$home/.local/lib"
  hwi_adapter_stub_engine "$root"
  ln -s "$SOURCE_ROOT/dot_local/lib/agent-hooks" "$home/.local/lib/agent-hooks"
  ln -s "$HWI_OPENCODE_PLUGIN_SOURCE" "$deployed/herdr-worktree-identity.ts"
  cat > "$root/run.ts" <<'TS'
const { HerdrWorktreeIdentityPlugin } = await import(process.env.HWI_OPENCODE_PLUGIN!);
const plugin = await HerdrWorktreeIdentityPlugin();
await plugin["chat.message"]?.(
  { sessionID: "session-opencode" },
  { parts: [{ type: "text", text: "OpenCode stdin sentinel" }] },
);
await plugin["chat.message"]?.(
  { sessionID: "session-opencode" },
  { parts: [{ type: "text", text: "Second OpenCode prompt" }] },
);
TS
  run env HOME="$home" HERDR_ENV=1 HERDR_PANE_ID=pane-opencode HERDR_WORKSPACE_ID=workspace-opencode \
    HERDR_WORKTREE_IDENTITY_ENGINE="$root/engine" HWI_ADAPTER_TEST_DIR="$root" \
    HWI_OPENCODE_PLUGIN="$deployed/herdr-worktree-identity.ts" bun "$root/run.ts"
  assert_success
  local calls
  calls="$(find "$root" -mindepth 1 -maxdepth 1 -type d -name 'call-*' | wc -l | tr -d ' ')"
  assert_equal "$calls" 2
  run sh -c 'cat "$1"/call-*/stdin' _ "$root"
  assert_success
  assert_output --partial 'OpenCode stdin sentinel'
  assert_output --partial 'Second OpenCode prompt'
  run sh -c 'cat "$1"/call-*/argv' _ "$root"
  assert_success
  refute_output --partial 'OpenCode stdin sentinel'
  refute_output --partial 'Second OpenCode prompt'
  assert_output --partial 'opencode'
  : > "$root/release"

  run env HOME="$home" HERDR_ENV= HERDR_WORKTREE_IDENTITY_ENGINE="$root/engine" \
    HWI_ADAPTER_TEST_DIR="$root/gated" HWI_OPENCODE_PLUGIN="$deployed/herdr-worktree-identity.ts" bun "$root/run.ts"
  assert_success
  assert_file_not_exists "$root/gated"
  run env HOME="$home" HERDR_ENV=1 HERDR_WORKTREE_IDENTITY_ACTIVE=1 HERDR_WORKTREE_IDENTITY_ENGINE="$root/engine" \
    HWI_ADAPTER_TEST_DIR="$root/reentry" HWI_OPENCODE_PLUGIN="$deployed/herdr-worktree-identity.ts" bun "$root/run.ts"
  assert_success
  assert_file_not_exists "$root/reentry"
}

# --- context-usage library (U2) -------------------------------------------
#
# Coverage owner for the context load the statusline renders. The oracle is
# outside this library: the token count is the one Claude Code publishes in the
# statusline payload, and what is asserted is the relation between the two
# figures drawn from it rather than a number restated from the library.

context_usage_lib() {
  printf '%s' "$SOURCE_ROOT/dot_local/lib/context-usage.sh"
}

function test_scripts_2812_context_usage_allowance_is_environment_tunable() {
  _bats_test_init 2812 'context-usage allowance is environment tunable'

  # KTD11: the one number this library decides on moves without a code edit.
  # Claude Code does not report the system prompt, so an operator whose prompt
  # is nothing like 40k has to be able to say so.
  run env CONTEXT_USAGE_ALLOWANCE_TOKENS=0 bash -c '
    . "$1"; context_usage_fullness_pct 130000 1000000
  ' _ "$(context_usage_lib)"
  assert_success
  assert_output '13'

  run env CONTEXT_USAGE_ALLOWANCE_TOKENS=370000 bash -c '
    . "$1"; context_usage_fullness_pct 130000 1000000
  ' _ "$(context_usage_lib)"
  assert_success
  assert_output '50'
}

# --- statusline renders the context load (U3) ------------------------------

context_usage_statusline_payload() {
  jq -nc --arg session "$1" --argjson current "$2" --argjson window "$3" \
    '{workspace: {current_dir: "/tmp"},
      session_id: $session,
      model: {display_name: "Opus 5"},
      context_window: {
        current_usage: {input_tokens: $current, cache_creation_input_tokens: 0, cache_read_input_tokens: 0},
        context_window_size: $window}}'
}

function test_scripts_2842_statusline_figure_and_percentage_agree() {
  _bats_test_init 2842 'statusline prints a load figure the percentage beside it is a share of'
  local statusline="$SOURCE_ROOT/private_dot_claude/hooks/executable_statusline.sh"
  local library home="$BATS_TEST_TMPDIR/home" state="$BATS_TEST_TMPDIR/state"
  local rendered figure pct
  library="$(context_usage_lib)"
  mkdir -p "$home"

  # The two are rendered from separate calls, and an operator reads them as one
  # statement. Printing the occupancy Claude Code reports beside a percentage
  # that includes the allowance makes them disagree by the allowance -- on a 1M
  # window that reads as a fifth of the context appearing from nowhere. What is
  # asserted is the relation between the two printed sides, not either number.
  run env HOME="$home" HERDR_ENV= CONTEXT_USAGE_LIBRARY="$library" \
    CONTEXT_USAGE_STATE_DIR="$state" CONTEXT_USAGE_ALLOWANCE_TOKENS=40000 bash "$statusline" \
    <<< "$(context_usage_statusline_payload agreeing 360000 1000000)"
  assert_success
  rendered="$(printf '%s' "$output" | sed -e $'s/\033\[[0-9;]*m//g')"

  figure="$(printf '%s' "$rendered" | sed -n 's/.* \([0-9][0-9]*\)k · [0-9][0-9]*%.*/\1/p')"
  pct="$(printf '%s' "$rendered" | sed -n 's/.* [0-9][0-9]*k · \([0-9][0-9]*\)%.*/\1/p')"
  run bash -c '[ -n "$1" ] && [ -n "$2" ] && [ "$(($1 * 1000 * 100 / $3))" -eq "$2" ] &&
    printf "agree" || printf "%sk against %s%% of %s" "$1" "$2" "$3"' \
    _ "$figure" "$pct" 1000000
  assert_success
  assert_output 'agree'
}

function test_scripts_2814_statusline_renders_without_the_shared_library() {
  _bats_test_init 2814 'statusline renders when the library or the context window is missing'
  local statusline="$SOURCE_ROOT/private_dot_claude/hooks/executable_statusline.sh"
  local library home="$BATS_TEST_TMPDIR/home"
  library="$(context_usage_lib)"
  mkdir -p "$home"

  # A partially applied home has the status line but not yet the library. The
  # bar must still render: the operator's prompt is not a place to surface a
  # deployment race.
  run env HOME="$home" HERDR_ENV= CONTEXT_USAGE_LIBRARY="$BATS_TEST_TMPDIR/absent-library.sh" \
    bash "$statusline" \
    <<< "$(context_usage_statusline_payload nolib 372000 1000000)"
  assert_success
  refute_output ''

  # A payload without a context window renders the zero-percent bar rather than
  # dividing by nothing.
  run env HOME="$home" HERDR_ENV= CONTEXT_USAGE_LIBRARY="$library" \
    bash "$statusline" \
    <<< '{"workspace":{"current_dir":"/tmp"},"session_id":"empty","model":{"display_name":"Opus 5"}}'
  assert_success
  assert_output --partial '░░░░░░░░░░'
}

# --- vendored handoff hooks (U6, U7) ---------------------------------------

handoff_pre_compact_hook() {
  printf '%s' "$SOURCE_ROOT/private_dot_claude/hooks/executable_handoff-pre-compact.sh"
}

# A `claude` on PATH that writes the text it was told to, so the hook's
# storage and gating are exercised without a model call.
handoff_stub_claude() {
  local dir="$1" body="${2:-## Goal\nship the vendored hook\n}"
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%b" "%s"\n' "$body"
    printf 'exit 0\n'
  } > "$dir/claude"
  chmod +x "$dir/claude"
}

handoff_payload() {
  jq -nc --arg session "$1" --arg cwd "$2" --arg trigger "$3" --arg instructions "$4" \
    '{session_id: $session, cwd: $cwd, trigger: $trigger,
      custom_instructions: (if $instructions == "" then null else $instructions end),
      hook_event_name: "PreCompact"}'
}

handoff_stored_goal() {
  jq -r '.goal' < "$1"
}

function test_scripts_2815_handoff_pre_compact_stores_outside_the_git_directory() {
  _bats_test_init 2815 'handoff pre-compact stores a handoff where .git is a file or absent'
  local root="$BATS_TEST_TMPDIR" store="$BATS_TEST_TMPDIR/cache" stub="$BATS_TEST_TMPDIR/stub"
  local main="$root/main" linked="$root/linked" plain="$root/plain" file
  handoff_stub_claude "$stub"
  mkdir -p "$plain"

  git init -q "$main"
  git -C "$main" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  git -C "$main" worktree add -q -b probe "$linked" > /dev/null 2>&1

  # AE11, KTD5. `mkdir -p .git/handoff-pending` fails outright here: in a
  # linked worktree `.git` is a file, not a directory.
  assert_file_exists "$linked/.git"
  run test -d "$linked/.git"
  assert_failure

  run env PATH="$stub:$PATH" HOME="$root/home" HANDOFF_STORE_DIR="$store" \
    CONTEXT_USAGE_LIBRARY="$(context_usage_lib)" CONTEXT_USAGE_STATE_DIR="$root/usage" \
    bash "$(handoff_pre_compact_hook)" \
    <<< "$(handoff_payload worktree-session "$linked" manual 'finish the vendoring')"
  assert_success
  file="$store/$(printf '%s' worktree-session | base64 | tr '/+' '_-' | tr -d '=\n').json"
  assert_file_exists "$file"
  assert_equal "$(handoff_stored_goal "$file")" 'finish the vendoring'
  assert_file_contains "$file" 'ship the vendored hook'

  # And in a directory that is not a repository at all.
  run env PATH="$stub:$PATH" HOME="$root/home" HANDOFF_STORE_DIR="$store" \
    CONTEXT_USAGE_LIBRARY="$(context_usage_lib)" CONTEXT_USAGE_STATE_DIR="$root/usage" \
    bash "$(handoff_pre_compact_hook)" \
    <<< "$(handoff_payload plain-session "$plain" manual 'finish the vendoring')"
  assert_success
  assert_dir_not_exists "$plain/.git"
  assert_file_exists "$store/$(printf '%s' plain-session | base64 | tr '/+' '_-' | tr -d '=\n').json"
}

function test_scripts_2816_handoff_pre_compact_keys_the_store_by_session() {
  _bats_test_init 2816 'handoff pre-compact keeps concurrent sessions from overwriting each other'
  local root="$BATS_TEST_TMPDIR" store="$BATS_TEST_TMPDIR/cache" stub="$BATS_TEST_TMPDIR/stub"
  local one two
  handoff_stub_claude "$stub"

  run env PATH="$stub:$PATH" HOME="$root/home" HANDOFF_STORE_DIR="$store" \
    CONTEXT_USAGE_LIBRARY="$(context_usage_lib)" CONTEXT_USAGE_STATE_DIR="$root/usage" \
    bash "$(handoff_pre_compact_hook)" \
    <<< "$(handoff_payload session-a "$root" manual 'goal for a')"
  assert_success
  run env PATH="$stub:$PATH" HOME="$root/home" HANDOFF_STORE_DIR="$store" \
    CONTEXT_USAGE_LIBRARY="$(context_usage_lib)" CONTEXT_USAGE_STATE_DIR="$root/usage" \
    bash "$(handoff_pre_compact_hook)" \
    <<< "$(handoff_payload session-b "$root" manual 'goal for b')"
  assert_success

  one="$store/$(printf '%s' session-a | base64 | tr '/+' '_-' | tr -d '=\n').json"
  two="$store/$(printf '%s' session-b | base64 | tr '/+' '_-' | tr -d '=\n').json"
  assert_equal "$(handoff_stored_goal "$one")" 'goal for a'
  assert_equal "$(handoff_stored_goal "$two")" 'goal for b'
}

function test_scripts_2817_handoff_pre_compact_builds_a_handoff_for_a_plain_compaction() {
  _bats_test_init 2817 'handoff pre-compact builds a handoff when the operator names no goal'
  local root="$BATS_TEST_TMPDIR" store="$BATS_TEST_TMPDIR/cache" stub="$BATS_TEST_TMPDIR/stub"
  local file
  handoff_stub_claude "$stub" 'the handoff for an unstated goal'

  # A bare `/compact` arrives with no instructions at all, and an automatic
  # compaction with a null field. Both are the case the operator did not plan
  # for, so both must still leave a handoff: the fork resumes the whole session
  # and names the goal from it.
  file="$(handoff_store_path "$store" bare)"
  run env PATH="$stub:$PATH" HOME="$root/home" HANDOFF_STORE_DIR="$store" \
    CONTEXT_USAGE_LIBRARY="$(context_usage_lib)" \
    bash "$(handoff_pre_compact_hook)" \
    <<< "$(handoff_payload bare "$root" manual '')"
  assert_success
  assert_output ''
  assert_file_contains "$file" 'the handoff for an unstated goal'

  file="$(handoff_store_path "$store" auto)"
  run env PATH="$stub:$PATH" HOME="$root/home" HANDOFF_STORE_DIR="$store" \
    CONTEXT_USAGE_LIBRARY="$(context_usage_lib)" \
    bash "$(handoff_pre_compact_hook)" \
    <<< '{"session_id":"auto","cwd":"/tmp","trigger":"auto","custom_instructions":null,"hook_event_name":"PreCompact"}'
  assert_success
  assert_output ''
  assert_file_contains "$file" 'the handoff for an unstated goal'
}

function test_scripts_2844_handoff_pre_compact_hands_the_extractor_a_usable_goal() {
  _bats_test_init 2844 'handoff pre-compact hands its extractor a goal block that is never bare or prefixed'
  local root="$BATS_TEST_TMPDIR" store="$BATS_TEST_TMPDIR/cache" stub="$BATS_TEST_TMPDIR/stub"
  local prompt="$BATS_TEST_TMPDIR/prompt.txt" block

  # The extractor is a separate process, so what it is handed is an interface
  # and not an implementation detail. Capture the last argument -- the prompt.
  mkdir -p "$stub"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'last=""; for arg in "$@"; do last="$arg"; done\n'
    printf 'printf "%%s" "$last" > "%s"\n' "$prompt"
    printf 'printf "extracted\\n"\n'
  } > "$stub/claude"
  chmod +x "$stub/claude"

  # `handoff:` was the trigger word before a bare `/compact` was enough. A
  # session that still types it must not have the marker delivered as part of
  # the goal the extractor works from.
  run env PATH="$stub:$PATH" HOME="$root/home" HANDOFF_STORE_DIR="$store" \
    CONTEXT_USAGE_LIBRARY="$(context_usage_lib)" \
    bash "$(handoff_pre_compact_hook)" \
    <<< "$(handoff_payload prefixed "$root" manual 'handoff:land the vendored rewrite')"
  assert_success
  assert_file_contains "$prompt" 'land the vendored rewrite'
  run grep -c 'handoff:' "$prompt"
  assert_failure

  # And with nothing typed the block still has to say something. An empty
  # <goal> asks the extractor to select against no criterion at all, which is
  # the whole session back again rather than a handoff. The capture is removed
  # first, so a run that never reaches the extractor cannot be read as one that
  # did through the previous prompt left on disk.
  rm -f "$prompt"
  run env PATH="$stub:$PATH" HOME="$root/home" HANDOFF_STORE_DIR="$store" \
    CONTEXT_USAGE_LIBRARY="$(context_usage_lib)" \
    bash "$(handoff_pre_compact_hook)" \
    <<< "$(handoff_payload bareprompt "$root" manual '')"
  assert_success
  assert_file_exists "$prompt"
  block="$(sed -n '/<goal>/,/<\/goal>/p' "$prompt" | sed '1d;$d' | tr -d '[:space:]')"
  run bash -c '[ -n "$1" ] && printf named || printf "the goal block was empty"' _ "$block"
  assert_output 'named'
}

function test_scripts_2837_handoff_hooks_fail_open_without_a_home() {
  _bats_test_init 2837 'handoff hooks fail open when HOME is unset'
  local hook

  # KTD9. `set -u` plus a path defaulted from $HOME aborts the hook with a
  # non-zero status, which Claude Code surfaces as a hook error on every turn.
  # An advisory step in front of a compaction must fail open instead.
  for hook in executable_handoff-pre-compact.sh executable_handoff-session-start.sh; do
    run env -u HOME -u CONTEXT_USAGE_LIBRARY -u HANDOFF_STORE_DIR \
      bash "$SOURCE_ROOT/private_dot_claude/hooks/$hook" < /dev/null
    assert_success
    assert_output ''
  done

  # The library is sourced by both and must survive the same condition.
  run env -u HOME bash -c 'set -uo pipefail; . "$1"; printf "sourced"' _ "$(context_usage_lib)"
  assert_success
  assert_output 'sourced'
}

function test_scripts_2818_handoff_pre_compact_fails_open() {
  _bats_test_init 2818 'handoff pre-compact exits silently on malformed input and failed extraction'
  local root="$BATS_TEST_TMPDIR" store="$BATS_TEST_TMPDIR/cache" stub="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stub"

  run env PATH="$stub:$PATH" HOME="$root/home" HANDOFF_STORE_DIR="$store" \
    CONTEXT_USAGE_LIBRARY="$(context_usage_lib)" CONTEXT_USAGE_STATE_DIR="$root/usage" \
    bash "$(handoff_pre_compact_hook)" <<< 'not json at all'
  assert_success
  assert_output ''
  assert_dir_not_exists "$store"

  # KTD9: an extractor that fails leaves no half-written handoff behind, and
  # compaction still proceeds.
  printf '#!/usr/bin/env bash\nexit 3\n' > "$stub/claude"
  chmod +x "$stub/claude"
  run env PATH="$stub:$PATH" HOME="$root/home" HANDOFF_STORE_DIR="$store" \
    CONTEXT_USAGE_LIBRARY="$(context_usage_lib)" CONTEXT_USAGE_STATE_DIR="$root/usage" \
    bash "$(handoff_pre_compact_hook)" \
    <<< "$(handoff_payload broken "$root" manual 'a goal nobody can extract')"
  assert_success
  assert_file_not_exists "$store/$(printf '%s' broken | base64 | tr '/+' '_-' | tr -d '=\n').json"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/claude"
  run env PATH="$stub:$PATH" HOME="$root/home" HANDOFF_STORE_DIR="$store" \
    CONTEXT_USAGE_LIBRARY="$(context_usage_lib)" CONTEXT_USAGE_STATE_DIR="$root/usage" \
    bash "$(handoff_pre_compact_hook)" \
    <<< "$(handoff_payload empty "$root" manual 'a goal with an empty answer')"
  assert_success
  assert_file_not_exists "$store/$(printf '%s' empty | base64 | tr '/+' '_-' | tr -d '=\n').json"
}

# --- handoff SessionStart injector (U7) ------------------------------------

handoff_session_start_hook() {
  printf '%s' "$SOURCE_ROOT/private_dot_claude/hooks/executable_handoff-session-start.sh"
}

handoff_store_path() {
  printf '%s/%s.json' "$1" "$(printf '%s' "$2" | base64 | tr '/+' '_-' | tr -d '=\n')"
}

handoff_stage_stored() {
  local store="$1" session="$2" content="$3" file
  file="$(handoff_store_path "$store" "$session")"
  mkdir -p "$store"
  jq -n --arg content "$content" \
    '{handoff_content: $content, goal: "staged", trigger: "manual", type: "compact"}' > "$file"
  printf '%s' "$file"
}

handoff_session_start_payload() {
  jq -nc --arg session "$1" --arg source "$2" \
    '{session_id: $session, cwd: "/tmp", source: $source, hook_event_name: "SessionStart"}'
}

handoff_session_start_run() {
  env HOME="$BATS_TEST_TMPDIR/home" \
    HANDOFF_STORE_DIR="$BATS_TEST_TMPDIR/cache" \
    CONTEXT_USAGE_LIBRARY="$(context_usage_lib)" \
    CONTEXT_USAGE_STATE_DIR="$BATS_TEST_TMPDIR/state" \
    bash "$(handoff_session_start_hook)" \
    <<< "$(handoff_session_start_payload "$1" "$2")"
}

function test_scripts_2831_handoff_injector_places_the_handoff_in_model_context() {
  _bats_test_init 2831 'handoff injector emits additionalContext and never systemMessage'
  local store="$BATS_TEST_TMPDIR/cache" file
  mkdir -p "$BATS_TEST_TMPDIR/home"
  file="$(handoff_stage_stored "$store" injected '## Goal
finish the injector
## Key Details
the build id is 7731-ZARBLAX')"

  # KTD8, R15. This is the field the whole vendoring exists for: systemMessage
  # renders to the operator and never reaches the model, which is a handoff
  # that was shown rather than handed off.
  run handoff_session_start_run injected compact
  assert_success
  local response="$output"
  run jq -r '.hookSpecificOutput.hookEventName' <<< "$response"
  assert_success
  assert_output 'SessionStart'
  run jq -r '.hookSpecificOutput.additionalContext' <<< "$response"
  assert_success
  assert_output --partial '7731-ZARBLAX'
  run jq -e 'has("systemMessage") | not' <<< "$response"
  assert_success

  # Consumed once. A second start finds nothing to inject.
  assert_file_not_exists "$file"
  run handoff_session_start_run injected compact
  assert_success
  assert_output ''
}

function test_scripts_2832_handoff_injector_takes_only_this_sessions_handoff() {
  _bats_test_init 2832 'handoff injector leaves another session handoff untouched'
  local store="$BATS_TEST_TMPDIR/cache" other
  mkdir -p "$BATS_TEST_TMPDIR/home"
  other="$(handoff_stage_stored "$store" neighbour 'belongs to the other session')"

  # AE7, R16. Two worktree sessions compact independently; neither may consume
  # the other's handoff, and neither may inject a handoff it did not ask for.
  run handoff_session_start_run mine compact
  assert_success
  assert_output ''
  assert_file_exists "$other"
  assert_file_contains "$other" 'belongs to the other session'
}

function test_scripts_2833_handoff_injector_ignores_ordinary_session_starts() {
  _bats_test_init 2833 'handoff injector ignores session starts that are not compactions'
  local store="$BATS_TEST_TMPDIR/cache" file
  mkdir -p "$BATS_TEST_TMPDIR/home"
  file="$(handoff_stage_stored "$store" startup 'should survive a plain startup')"

  run handoff_session_start_run startup startup
  assert_success
  assert_output ''
  assert_file_exists "$file"

  run handoff_session_start_run startup resume
  assert_success
  assert_output ''
  assert_file_exists "$file"

  run env HOME="$BATS_TEST_TMPDIR/home" HANDOFF_STORE_DIR="$store" \
    CONTEXT_USAGE_LIBRARY="$(context_usage_lib)" CONTEXT_USAGE_STATE_DIR="$BATS_TEST_TMPDIR/state" \
    bash "$(handoff_session_start_hook)" <<< 'not json at all'
  assert_success
  assert_output ''
  assert_file_exists "$file"
}

function test_scripts_2840_handoff_pre_compact_never_resurrects_an_older_goal() {
  _bats_test_init 2840 'handoff pre-compact discards the previous handoff before extracting a new one'
  local root="$BATS_TEST_TMPDIR" store="$BATS_TEST_TMPDIR/cache" stub="$BATS_TEST_TMPDIR/stub"
  local file
  handoff_stub_claude "$stub" 'the first goal handoff'
  file="$(handoff_store_path "$store" replaced)"

  run env PATH="$stub:$PATH" HOME="$root/home" HANDOFF_STORE_DIR="$store" \
    CONTEXT_USAGE_LIBRARY="$(context_usage_lib)" CONTEXT_USAGE_STATE_DIR="$root/usage" \
    bash "$(handoff_pre_compact_hook)" \
    <<< "$(handoff_payload replaced "$root" manual 'the first goal')"
  assert_success
  assert_file_contains "$file" 'the first goal handoff'

  # R16 in its harder form: the operator asked for a *different* goal and the
  # extraction failed. Injecting the previous compaction's handoff would hand
  # the next session a goal it has already finished with.
  printf '#!/usr/bin/env bash\nexit 3\n' > "$stub/claude"
  chmod +x "$stub/claude"
  run env PATH="$stub:$PATH" HOME="$root/home" HANDOFF_STORE_DIR="$store" \
    CONTEXT_USAGE_LIBRARY="$(context_usage_lib)" CONTEXT_USAGE_STATE_DIR="$root/usage" \
    bash "$(handoff_pre_compact_hook)" \
    <<< "$(handoff_payload replaced "$root" manual 'a second and different goal')"
  assert_success
  assert_file_not_exists "$file"
}

# ===========================================
# update-pins
#
# Consumer: the two chezmoi *source* files update-pins rewrites —
# .chezmoiexternal.toml and private_dot_config/mise/config.toml. Observable
# failure: a declined bump mutates a pin anyway, an accepted bump writes
# something other than the value upstream returned, or a fff-mcp bump lands a
# partial checksum set that breaks `chezmoi apply` on the platforms it did not
# refresh. Oracle: the bytes of a fixture copy of those two real files before
# and after a run, against the values a stubbed fetcher returned. GitHub's own
# semantics belong to GitHub and are not asserted here — every upstream answer
# and every `mise outdated` report comes from a stub, so the suite never
# reaches the network.
# ===========================================

UPDATE_PINS="$SOURCE_ROOT/dot_local/bin/executable_update-pins"

pins_fixture() {
  PINS_ROOT="$BATS_TEST_TMPDIR/pins-source"
  PINS_STUBS="$BATS_TEST_TMPDIR/pins-stubs"
  PINS_BASELINE="$BATS_TEST_TMPDIR/pins-baseline"
  mkdir -p "$PINS_ROOT/private_dot_config/mise" "$PINS_STUBS" "$PINS_BASELINE"

  # The fixture is a copy of the repository's own pinned files, so the parsing
  # under test faces the shapes it will actually meet.
  cp "$SOURCE_ROOT/.chezmoiexternal.toml" "$PINS_ROOT/.chezmoiexternal.toml"
  cp "$SOURCE_ROOT/private_dot_config/mise/config.toml" \
    "$PINS_ROOT/private_dot_config/mise/config.toml"
  PINS_EXTERNAL="$PINS_ROOT/.chezmoiexternal.toml"
  PINS_MISE="$PINS_ROOT/private_dot_config/mise/config.toml"

  PINS_STUB_HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
  PINS_STUB_TAG="v99.0.0"
  PINS_STUB_CHECKSUM_FAILS_FOR=""

  PINS_FETCHER="$PINS_STUBS/upstream-stub"
  cat >"$PINS_FETCHER" <<'STUB'
#!/usr/bin/env bash
# Stubbed upstream. Answers in the shapes the real fetcher sees: a
# `git ls-remote` line, a bare release tag, and a `.sha256` asset line. An
# unknown asset exits non-zero, so a renamed target surfaces instead of
# silently borrowing another platform's checksum.
case "$1" in
  head-sha) printf '%s\tHEAD\n' "$STUB_HEAD_SHA" ;;
  latest-tag) printf '%s\n' "$STUB_TAG" ;;
  checksum)
    # checksum REPO TAG ASSET
    [ "$4" != "${STUB_CHECKSUM_FAILS_FOR:-}" ] || exit 1
    case "$4" in
      *aarch64-apple-darwin)
        printf '%s  %s\n' "1111111111111111111111111111111111111111111111111111111111111111" "$4" ;;
      *x86_64-apple-darwin)
        printf '%s  %s\n' "2222222222222222222222222222222222222222222222222222222222222222" "$4" ;;
      *aarch64-unknown-linux-musl)
        printf '%s  %s\n' "3333333333333333333333333333333333333333333333333333333333333333" "$4" ;;
      *x86_64-unknown-linux-musl)
        printf '%s  %s\n' "4444444444444444444444444444444444444444444444444444444444444444" "$4" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 2 ;;
esac
STUB
  chmod +x "$PINS_FETCHER"

  PINS_UNREACHABLE="$PINS_STUBS/unreachable-stub"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$PINS_UNREACHABLE"
  chmod +x "$PINS_UNREACHABLE"

  # `mise outdated --bump -J`, stubbed. The default report mirrors what a real
  # mise emits for a moving alias: no bump to offer.
  PINS_MISE_JSON="$BATS_TEST_TMPDIR/mise-outdated.json"
  printf '%s\n' \
    '{"node": {"name": "node", "requested": "lts", "current": "24.20.0", "bump": null, "latest": "26.8.1"}}' \
    >"$PINS_MISE_JSON"
  printf '%s\n' '#!/usr/bin/env bash' 'cat "$STUB_MISE_JSON"' >"$PINS_STUBS/mise"
  chmod +x "$PINS_STUBS/mise"

  cp "$PINS_EXTERNAL" "$PINS_BASELINE/externals"
  cp "$PINS_MISE" "$PINS_BASELINE/mise"
}

# run_pins ANSWERS [FETCHER]
run_pins() {
  local answers="$1" fetcher="${2:-$PINS_FETCHER}"
  run env \
    "PATH=$PINS_STUBS:$PATH" \
    "UPDATE_PINS_SOURCE_ROOT=$PINS_ROOT" \
    "UPDATE_PINS_FETCHER=$fetcher" \
    "STUB_MISE_JSON=$PINS_MISE_JSON" \
    "STUB_HEAD_SHA=$PINS_STUB_HEAD_SHA" \
    "STUB_TAG=$PINS_STUB_TAG" \
    "STUB_CHECKSUM_FAILS_FOR=$PINS_STUB_CHECKSUM_FAILS_FOR" \
    bash -c 'printf "%s" "$2" | bash "$1"' bash "$UPDATE_PINS" "$answers"
}

assert_pins_files_unchanged() {
  assert cmp -s "$PINS_BASELINE/externals" "$PINS_EXTERNAL"
  assert cmp -s "$PINS_BASELINE/mise" "$PINS_MISE"
}

pins_baseline_value() {
  sed -n "$1" "$PINS_BASELINE/externals" | head -1
}

# The externals file the fixture should hold after an accepted fff-mcp bump:
# the pinned tag replaced, and each platform's checksum replaced by the one the
# stub serves for that platform's asset.
pins_expected_fff_bump() {
  local out="$BATS_TEST_TMPDIR/expected-externals"
  local work="$BATS_TEST_TMPDIR/expected-externals.work"
  local old_tag template asset sum index=0
  local targets=() shas=()

  old_tag="$(pins_baseline_value 's|.*/releases/download/\([^/"]*\)/.*|\1|p')"
  template="$(pins_baseline_value 's|.*/releases/download/[^/"]*/\([^"]*\)".*|\1|p')"
  while IFS= read -r asset; do
    targets[${#targets[@]}]="$asset"
  done < <(sed -n 's|.*\$fffMcpTarget = "\([^"]*\)".*|\1|p' "$PINS_BASELINE/externals")
  while IFS= read -r sum; do
    shas[${#shas[@]}]="$sum"
  done < <(sed -n 's|.*\$fffMcpSha256 = "\([0-9a-f]\{64\}\)".*|\1|p' "$PINS_BASELINE/externals")

  sed "s|/releases/download/$old_tag/|/releases/download/$PINS_STUB_TAG/|" \
    "$PINS_BASELINE/externals" >"$out"
  while [ "$index" -lt "${#targets[@]}" ]; do
    asset="${template%%\{\{*}${targets[$index]}${template##*\}\}}"
    sum="$(STUB_CHECKSUM_FAILS_FOR= "$PINS_FETCHER" checksum repo "$PINS_STUB_TAG" "$asset" |
      awk '{ print $1 }')"
    sed "s|\"${shas[$index]}\"|\"$sum\"|" "$out" >"$work"
    mv "$work" "$out"
    index=$((index + 1))
  done
  printf '%s\n' "$out"
}

function test_scripts_1451_update_pins_declining_every_bump_leaves_the_pinned_files_byte_identical() {
  _bats_test_init 1451 'update-pins declining every bump leaves the pinned files byte-identical'
  # #given a source tree whose every pin has drifted upstream
  pins_fixture

  # #when every offer is declined
  run_pins 'n
n
n
n
n
n
'

  # #then the run reports the drift and writes nothing
  assert_success
  # Control for the byte-identical assertion below: without it a run that
  # reported every pin as up to date would also write nothing and pass. The
  # pinned sha comes from the fixture rather than a literal, because this is
  # the value update-pins exists to change.
  local pinned
  pinned="$(pins_baseline_value \
    's|.*ohmyzsh/ohmyzsh/archive/\([0-9a-f]\{40\}\)\.tar\.gz.*|\1|p')"
  assert_output --partial \
    "ohmyzsh/ohmyzsh: ${pinned:0:12} -> ${PINS_STUB_HEAD_SHA:0:12}"
  assert_output --partial 'kept'
  assert_pins_files_unchanged
}

function test_scripts_1452_update_pins_writes_exactly_the_fetched_sha_for_the_accepted_pin() {
  _bats_test_init 1452 'update-pins writes exactly the fetched sha for the accepted pin'
  # #given the drifted source tree and the sha the stubbed fetcher will return
  pins_fixture
  local old_sha expected="$BATS_TEST_TMPDIR/expected-externals"
  old_sha="$(pins_baseline_value 's|.*ohmyzsh/ohmyzsh/archive/\([0-9a-f]\{40\}\)\.tar\.gz.*|\1|p')"
  sed "s|/archive/$old_sha\.tar\.gz|/archive/$PINS_STUB_HEAD_SHA.tar.gz|" \
    "$PINS_BASELINE/externals" >"$expected"

  # #when only the first offer is accepted
  run_pins 'y
n
n
n
n
n
'

  # #then that one pin carries the fetched sha and nothing else moved
  assert_success
  assert cmp -s "$expected" "$PINS_EXTERNAL"
  assert cmp -s "$PINS_BASELINE/mise" "$PINS_MISE"
}

function test_scripts_1453_update_pins_bumps_fff_mcp_to_the_fetched_tag_and_all_four_checksums() {
  _bats_test_init 1453 'update-pins bumps fff-mcp to the fetched tag and all four checksums'
  # #given the drifted source tree and the four per-platform sums the stub serves
  pins_fixture
  local expected
  expected="$(pins_expected_fff_bump)"

  # #when every archive offer is declined and only the fff-mcp offer accepted
  run_pins 'n
n
n
n
n
y
'

  # #then the release tag and every platform checksum carry the fetched values
  assert_success
  assert cmp -s "$expected" "$PINS_EXTERNAL"
  assert cmp -s "$PINS_BASELINE/mise" "$PINS_MISE"
}

function test_scripts_1454_update_pins_abandons_a_fff_mcp_bump_when_one_checksum_cannot_be_fetched() {
  _bats_test_init 1454 'update-pins abandons a fff-mcp bump when one checksum cannot be fetched'
  # #given one of the four platform checksums is unavailable upstream
  pins_fixture
  PINS_STUB_CHECKSUM_FAILS_FOR='fff-mcp-aarch64-unknown-linux-musl'

  # #when the fff-mcp bump is accepted
  run_pins 'n
n
n
n
n
y
'

  # #then the pin keeps its whole consistent set and the run names what it needs
  assert_success
  assert_output --partial 'pin left unchanged'
  assert_output --partial 'the values a manual bump needs'
  assert_output --partial 'aarch64-unknown-linux-musl: unavailable'
  assert_pins_files_unchanged
}

function test_scripts_1455_update_pins_reports_unreachable_upstreams_and_still_succeeds() {
  _bats_test_init 1455 'update-pins reports unreachable upstreams and still succeeds'
  # #given every upstream query fails, as it would with no network
  pins_fixture

  # #when update-pins runs
  run_pins '' "$PINS_UNREACHABLE"

  # #then each pin reports as unknown, the run succeeds, and nothing is written
  assert_success
  assert_output --partial 'ohmyzsh/ohmyzsh: unknown'
  assert_output --partial 'dmtrKovalenko/fff: unknown'
  assert_pins_files_unchanged
}

function test_scripts_1456_update_pins_rewrites_only_the_accepted_mise_tool_version() {
  _bats_test_init 1456 'update-pins rewrites only the accepted mise tool version'
  # #given mise reports a concrete bump for a tool pinned in the managed config
  pins_fixture
  printf '%s\n' \
    '{"node": {"name": "node", "requested": "24", "current": "24.20.0", "bump": "26.8.1", "latest": "26.8.1"}}' \
    >"$PINS_MISE_JSON"
  sed 's|^node = ".*"$|node = "24"|' "$PINS_BASELINE/mise" >"$PINS_MISE"
  cp "$PINS_MISE" "$PINS_BASELINE/mise"
  assert_file_contains "$PINS_MISE" '^node = "24"$'
  local expected="$BATS_TEST_TMPDIR/expected-mise"
  sed 's|^node = "24"$|node = "26.8.1"|' "$PINS_BASELINE/mise" >"$expected"

  # #when every externals offer is declined and the mise offer accepted
  run_pins 'n
n
n
n
n
n
y
'

  # #then the managed mise config carries the reported bump and nothing else did
  assert_success
  assert cmp -s "$expected" "$PINS_MISE"
  assert cmp -s "$PINS_BASELINE/externals" "$PINS_EXTERNAL"
}

function test_scripts_1457_update_pins_follows_the_chezmoiroot_indirection_into_home() {
  _bats_test_init 1457 'update-pins follows the .chezmoiroot indirection into home/'
  # #given a source tree shaped like this repository's own, where .chezmoiroot
  # puts the pinned files one level below the root chezmoi source-path reports
  pins_fixture
  local outer="$BATS_TEST_TMPDIR/pins-chezmoiroot"
  mkdir -p "$outer"
  mv "$PINS_ROOT" "$outer/home"
  printf 'home\n' >"$outer/.chezmoiroot"
  PINS_ROOT="$outer"
  PINS_EXTERNAL="$outer/home/.chezmoiexternal.toml"
  PINS_MISE="$outer/home/private_dot_config/mise/config.toml"

  local expected="$BATS_TEST_TMPDIR/expected-nested-externals" old_sha
  old_sha="$(pins_baseline_value \
    's|.*ohmyzsh/ohmyzsh/archive/\([0-9a-f]\{40\}\)\.tar\.gz.*|\1|p')"
  sed "s|/archive/$old_sha\.tar\.gz|/archive/$PINS_STUB_HEAD_SHA.tar.gz|" \
    "$PINS_BASELINE/externals" >"$expected"

  # #when the first offer is accepted
  run_pins 'y
n
n
n
n
n
'

  # #then the nested file was found and rewritten rather than reported missing
  assert_success
  refute_output --partial 'no chezmoi externals file'
  assert cmp -s "$expected" "$PINS_EXTERNAL"
  assert cmp -s "$PINS_BASELINE/mise" "$PINS_MISE"
}

function test_scripts_1458_update_pins_reports_a_failed_mise_lookup_as_unknown() {
  _bats_test_init 1458 'update-pins reports a failed mise lookup as unknown, not as nothing outdated'
  # #given a mise whose outdated lookup fails the way a registry or network
  # outage makes it fail: nonzero exit, nothing usable on stdout
  pins_fixture
  printf '%s\n' '#!/usr/bin/env bash' 'exit 2' >"$PINS_STUBS/mise"
  chmod +x "$PINS_STUBS/mise"

  # #when every externals offer is declined
  run_pins 'n
n
n
n
n
n
'

  # #then the run says it does not know, rather than claiming nothing drifted
  assert_success
  assert_output --partial 'mise: unknown'
  refute_output --partial 'mise: nothing outdated'
  assert_pins_files_unchanged
}

# Turns the fixture source into a real repository tracking a real remote, so
# the publish assertions read git's own state instead of the script's intent.
pins_git_fixture() {
  PINS_ORIGIN="$BATS_TEST_TMPDIR/pins-origin.git"
  git init --quiet --bare -b main "$PINS_ORIGIN"
  git -C "$PINS_ROOT" init --quiet -b main
  git -C "$PINS_ROOT" config user.email 'pins@example.test'
  git -C "$PINS_ROOT" config user.name 'Pins Fixture'
  git -C "$PINS_ROOT" add --all
  git -C "$PINS_ROOT" commit --quiet -m 'fixture baseline'
  git -C "$PINS_ROOT" remote add origin "$PINS_ORIGIN"
  git -C "$PINS_ROOT" push --quiet --set-upstream origin main
}

function test_scripts_1459_update_pins_commits_and_pushes_the_accepted_bump() {
  _bats_test_init 1459 'update-pins commits and pushes the accepted bump to origin'
  # #given the drifted source tree as a repository tracking a remote
  pins_fixture
  pins_git_fixture
  local before published="$BATS_TEST_TMPDIR/published-externals"
  before="$(git -C "$PINS_ROOT" rev-parse HEAD)"

  # #when the first offer is accepted
  run_pins 'y
n
n
n
n
n
'

  # #then the source is clean again and origin carries the fetched sha
  assert_success
  assert_equal "$(git -C "$PINS_ROOT" status --porcelain)" ""
  assert_equal "$(git -C "$PINS_ROOT" rev-parse 'HEAD~1')" "$before"
  assert_equal "$(git -C "$PINS_ROOT" rev-parse HEAD)" \
    "$(git -C "$PINS_ORIGIN" rev-parse main)"
  git -C "$PINS_ORIGIN" show 'main:.chezmoiexternal.toml' >"$published"
  assert_file_contains "$published" "/archive/$PINS_STUB_HEAD_SHA\.tar\.gz"
}

function test_scripts_1460_update_pins_creates_no_commit_when_every_bump_is_declined() {
  _bats_test_init 1460 'update-pins creates no commit when every bump is declined'
  # #given the same repository-backed source tree
  pins_fixture
  pins_git_fixture
  local before
  before="$(git -C "$PINS_ROOT" rev-parse HEAD)"

  # #when every offer is declined
  run_pins 'n
n
n
n
n
n
'

  # #then nothing was committed and origin never moved
  assert_success
  assert_equal "$(git -C "$PINS_ROOT" rev-parse HEAD)" "$before"
  assert_equal "$(git -C "$PINS_ORIGIN" rev-parse main)" "$before"
  assert_pins_files_unchanged
}

function test_scripts_1461_update_pins_publishes_only_the_files_it_rewrote() {
  _bats_test_init 1461 'update-pins publishes only the files it rewrote'
  # #given unrelated work already sitting in the source tree: one tracked file
  # edited by hand and one untracked leftover
  pins_fixture
  pins_git_fixture
  printf 'edited by hand\n' >>"$PINS_MISE"
  printf 'leftover\n' >"$PINS_ROOT/stray-artifact"

  # #when the first offer is accepted
  run_pins 'y
n
n
n
n
n
'

  # #then the published commit touches the pinned file alone and the unrelated
  # work is still there, uncommitted
  assert_success
  assert_equal "$(git -C "$PINS_ROOT" show --format= --name-only HEAD)" \
    '.chezmoiexternal.toml'
  assert_file_contains "$PINS_MISE" '^edited by hand$'
  assert_file_exists "$PINS_ROOT/stray-artifact"
  assert_equal "$(git -C "$PINS_ROOT" status --porcelain --untracked-files=no)" \
    ' M private_dot_config/mise/config.toml'
}

# herdr-agent-limits tab bar status
# ===========================================

AGENT_LIMITS_SCRIPT="$SOURCE_ROOT/dot_local/bin/executable_herdr-agent-limits"

# Writes a fixture home whose windows are all live, then leaves the caller to
# age individual ones. Offsets are relative so the fixture never expires.
agent_limits_fixture() {
  local home="$1" cc_reset="$2" cx_reset="$3" now
  now="$(date +%s)"
  mkdir -p "$home/.cache/claude-rate-limits" "$home/.cache/codex-rate-limits" "$home/bin"
  printf '{"fetched_at":%s,"five_hour":{"used_percentage":3,"resets_at":%s}}' \
    "$now" "$((now + cc_reset))" > "$home/.cache/claude-rate-limits/latest.json"
  codex_limits_cache "$home" 15 "$((now + cx_reset))" false 0 "$now"
  # The codex segment is offered only where codex could refresh it. The display
  # path reads the cache and never runs the binary, so presence is all a
  # display fixture needs; test 27209 exercises the refresh against the real one.
  printf '#!/bin/sh\nexit 0\n' > "$home/bin/codex"
  chmod +x "$home/bin/codex"
}

# The cache the refresh writes and the bar reads, as a single window.
codex_limits_cache() {
  local home="$1" pct="$2" resets_at="$3" blocked="$4" credits="$5" fetched_at="$6"
  mkdir -p "$home/.cache/codex-rate-limits"
  printf '{"fetched_at":%s,"windows":[{"used_percent":%s,"window_minutes":10080,"resets_at":%s}],"blocked":%s,"reset_credits":%s}' \
    "$fetched_at" "$pct" "$resets_at" "$blocked" "$credits" \
    > "$home/.cache/codex-rate-limits/latest.json"
}

# A hermetic PATH: the fixture's codex, plus enough to resolve python3. The
# outer PATH stays out so a developer's real codex cannot answer for the stub.
agent_limits_run() {
  local home="$1"
  run env -i HOME="$home" PATH="$home/bin:/usr/bin:/bin" bash "$AGENT_LIMITS_SCRIPT"
}

function test_scripts_27204_agent_limits_drops_windows_whose_reset_has_passed() {
  _bats_test_init 27204 'agent limits drops windows whose reset has passed'
  local home="$BATS_TEST_TMPDIR/limits-expiry"

  # #given both providers report a window that is still open
  agent_limits_fixture "$home" 3600 86400

  # #when the status entry runs
  agent_limits_run "$home"

  # #then each provider contributes its live window
  assert_success
  assert_output --partial '  5h/3%'
  assert_output --partial '  7d/15%'

  # #given the same numbers, but after both windows have reset
  agent_limits_fixture "$home" -3600 -86400

  # #when the status entry runs again
  agent_limits_run "$home"

  # #then neither percentage is shown: a finished window describes a period
  # that is over, and a stale number in a status bar misleads silently
  assert_success
  refute_output --partial '3%'
  refute_output --partial '15%'
}

function test_scripts_27205_agent_limits_prefers_the_live_cache_over_the_stale_claude_json() {
  _bats_test_init 27205 'agent limits prefers the live cache over the stale claude json'
  local home="$BATS_TEST_TMPDIR/limits-precedence" now
  now="$(date +%s)"

  # #given a live status-line cache alongside a week-old .claude.json holding a
  # different figure for the same account-wide window
  agent_limits_fixture "$home" 3600 86400
  mkdir -p "$home/.claude"
  printf '{"cachedUsageUtilization":{"fetchedAtMs":%s,"utilization":{"five_hour":{"utilization":88}}}}' \
    "$(((now - 604800) * 1000))" > "$home/.claude/.claude.json"

  # #when the status entry runs
  agent_limits_run "$home"

  # #then the live figure wins and the stale one never reaches the bar
  assert_success
  assert_output --partial '  5h/3%'
  refute_output --partial '88%'

  # #given the live cache is gone, as on a home that has not run Claude yet
  rm -f "$home/.cache/claude-rate-limits/latest.json"

  # #when the status entry runs
  agent_limits_run "$home"

  # #then the fallback figure appears, labelled with its age rather than
  # passed off as current
  assert_success
  assert_output --partial '  5h/88%'
  assert_output --partial 'old)'
}

function test_scripts_27206_agent_limits_marks_a_spent_window_without_rounding_into_it() {
  _bats_test_init 27206 'agent limits marks a spent window without rounding into it'
  local home="$BATS_TEST_TMPDIR/limits-spent" now exhausted
  now="$(date +%s)"
  mkdir -p "$home/.cache/claude-rate-limits"
  # nf-cod-circle_slash U+EABD
  exhausted="$(printf '\356\252\275')"

  # #given a window that is genuinely spent
  printf '{"fetched_at":%s,"five_hour":{"used_percentage":100,"resets_at":%s}}' \
    "$now" "$((now + 3600))" > "$home/.cache/claude-rate-limits/latest.json"

  # #when the status entry runs
  run env -i HOME="$home" bash "$AGENT_LIMITS_SCRIPT"

  # #then it reads as a state rather than a stuck gauge, and still says when
  # the allowance comes back
  assert_success
  assert_output --partial "${exhausted}100%"
  assert_output --partial '↻'

  # #given a window that is merely close to spent
  printf '{"fetched_at":%s,"five_hour":{"used_percentage":99.6,"resets_at":%s}}' \
    "$now" "$((now + 3600))" > "$home/.cache/claude-rate-limits/latest.json"

  # #when the status entry runs
  run env -i HOME="$home" bash "$AGENT_LIMITS_SCRIPT"

  # #then rounding never manufactures an exhaustion that has not happened
  assert_success
  assert_output --partial '5h/99%'
  refute_output --partial '100%'
  refute_output --partial "$exhausted"
}

function test_scripts_27207_agent_limits_says_what_a_blocked_codex_account_can_still_do() {
  _bats_test_init 27207 'agent limits says what a blocked codex account can still do'
  local home="$BATS_TEST_TMPDIR/limits-credits" now exhausted
  now="$(date +%s)"
  # nf-cod-circle_slash U+EABD
  exhausted="$(printf '\356\252\275')"
  agent_limits_fixture "$home" 3600 86400

  # #given a spent window with reset credits in hand
  codex_limits_cache "$home" 100 "$((now + 86400))" true 2 "$now"

  # #when the status entry runs
  agent_limits_run "$home"

  # #then the count reaches the bar: at 100% it is the difference between
  # waiting for the reset and carrying on now. The spelling is ours; what the
  # zero-credit control below fixes is that the count appears at all.
  assert_success
  assert_output --partial '×2'

  # #given the same spent window with no credits left
  codex_limits_cache "$home" 100 "$((now + 86400))" true 0 "$now"

  # #when the status entry runs
  agent_limits_run "$home"

  # #then nothing claims a credit that is not there
  assert_success
  refute_output --partial '×0'
  refute_output --partial ' ×'

  # #given an account blocked while its window still reads below 100%, which
  # is what spend control and depleted credits look like
  codex_limits_cache "$home" 40 "$((now + 86400))" true 0 "$now"

  # #when the status entry runs
  agent_limits_run "$home"

  # #then the segment carries the state, because no percentage in the line
  # would reveal it
  assert_success
  assert_output --partial "  ${exhausted}"

  # #given the same figure on an account that is not blocked
  codex_limits_cache "$home" 40 "$((now + 86400))" false 0 "$now"

  # #when the status entry runs
  agent_limits_run "$home"

  # #then the marker stays off: it reports the backend's verdict, not a
  # threshold this script picked
  assert_success
  refute_output --partial "$exhausted"
}

function test_scripts_27208_agent_limits_labels_a_codex_figure_the_refresh_stopped_updating() {
  _bats_test_init 27208 'agent limits labels a codex figure the refresh stopped updating'
  local home="$BATS_TEST_TMPDIR/limits-stale" now
  now="$(date +%s)"
  agent_limits_fixture "$home" 3600 86400

  # #given a cache old enough to trigger its 15-minute refresh, but not old
  # enough to turn a brief backend failure into status-bar noise
  codex_limits_cache "$home" 40 "$((now + 86400))" false 0 "$((now - 1140))"

  # #when the status entry runs
  agent_limits_run "$home"

  # #then the last known figure remains available without a 19m-old warning
  assert_success
  assert_output --partial '  7d/40%'
  refute_output --partial 'old)'

  # #given refreshes have failed for a full hour
  codex_limits_cache "$home" 40 "$((now + 86400))" false 0 "$((now - 3600))"

  # #when the status entry runs again
  agent_limits_run "$home"

  # #then the bar makes the stale data explicit
  assert_success
  assert_output --partial '(1h old)'

  # #given the same figure from a refresh that is keeping up
  codex_limits_cache "$home" 40 "$((now + 86400))" false 0 "$now"

  # #when the status entry runs
  agent_limits_run "$home"

  # #then the bar says nothing about age, because there is nothing to qualify
  assert_success
  assert_output --partial '  7d/40%'
  refute_output --partial 'old)'
}

function test_scripts_27209_codex_limits_refresh_fills_its_cache_from_the_real_app_server() {
  _bats_test_init 27209 'codex limits refresh fills its cache from the real app server'
  [[ "${MMS_LIVE_CODEX_TEST:-}" = 1 ]] || skip "set MMS_LIVE_CODEX_TEST=1 to query the live Codex account"
  command_exists codex || skip "codex is not installed"
  local home="$BATS_TEST_TMPDIR/limits-refresh" cache
  mkdir -p "$home"
  cache="$home/.cache/codex-rate-limits/latest.json"

  # #given the real app server, reached with the real account: a fake codex
  # here would only compare this patch against itself, and the cache's fields
  # are a claim about codex's response that only codex can adjudicate.
  # #when the refresh path runs against it
  run env HOME="$home" CODEX_HOME="$HOME/.codex" \
    bash "$AGENT_LIMITS_SCRIPT" --refresh-codex
  assert_success

  # A logged-out or offline machine has no oracle, only a silent empty cache,
  # so say which one is missing instead of asserting an invented shape.
  [[ -f "$cache" ]] || skip "codex app-server returned no rate limits (logged out or offline?)"

  # #then every field the bar formats arrives populated. The depth stops at
  # what the display reads: anything further restates a response shape codex
  # owns and would fail on its next release for no local reason.
  run python3 -c '
import json, sys, time
d = json.load(open(sys.argv[1]))
assert time.time() - d["fetched_at"] < 300, "cache is not fresh"
assert isinstance(d["blocked"], bool), d["blocked"]
assert isinstance(d["reset_credits"], int), d["reset_credits"]
assert d["windows"], "no window carried a used_percent"
for w in d["windows"]:
    assert isinstance(w["used_percent"], (int, float)), w
    assert w["window_minutes"], w
print("ok")
' "$cache"
  assert_success
  assert_output --partial 'ok'
}

function test_scripts_27210_agent_limits_refreshes_stale_codex_data_before_rendering() {
  _bats_test_init 27210 'agent limits refreshes stale codex data before rendering'
  local home="$BATS_TEST_TMPDIR/limits-refresh-render" now marker
  now="$(date +%s)"
  marker="$home/codex-called"
  agent_limits_fixture "$home" 3600 86400
  codex_limits_cache "$home" 40 "$((now + 86400))" false 0 "$((now - 840))"

  # This fixture exercises our request lifecycle; test 27209 keeps the response
  # fields calibrated against the real app server.
  cat > "$home/bin/codex" <<EOF
#!/bin/sh
printf 'called\n' > "$marker"
while IFS= read -r request; do
  case "\$request" in
    *'"id": 2'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"primary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":$((now + 86400))}},"ordinaryUsageAllowed":true,"rateLimitResetCredits":{"availableCount":1}}}'
      exit 0
      ;;
  esac
done
EOF
  chmod +x "$home/bin/codex"

  # #when Herdr runs the status command before the 15-minute refresh interval
  agent_limits_run "$home"

  # #then the cache is rendered without asking the backend
  assert_success
  assert_output --partial '  7d/40%'
  refute_output --partial '  7d/7%'
  assert_file_not_exists "$marker"

  # #given the same snapshot has crossed the refresh interval
  codex_limits_cache "$home" 40 "$((now + 86400))" false 0 "$((now - 1140))"

  # #when Herdr runs the status command again
  agent_limits_run "$home"

  # #then that invocation waits for the bounded refresh and renders its result;
  # no background descendant or leaked lock is needed for a later redraw
  assert_success
  assert_output --partial '  7d/7%'
  assert_output --partial '×1'
  refute_output --partial 'old)'
  assert_file_exists "$marker"
  assert_dir_not_exists "$home/.cache/codex-rate-limits/refresh.lock"
}

function test_scripts_27211_agent_limits_compacts_reset_countdowns() {
  _bats_test_init 27211 'agent limits compacts reset countdowns'
  local home="$BATS_TEST_TMPDIR/limits-compact-resets"
  # Leave enough boundary margin that command startup cannot change the minute
  # or hour represented by either countdown.
  agent_limits_fixture "$home" 7250 90050

  # #when the status entry renders hour-minute and day-hour countdowns
  agent_limits_run "$home"

  # #then units already carried by position are not repeated
  assert_success
  assert_output --partial '  5h/3% ↻2:00'
  assert_output --partial '  7d/15% ↻1d1h'
}

function test_scripts_27212_agent_limits_renders_the_compact_provider_layout() {
  _bats_test_init 27212 'agent limits renders the compact provider layout'
  local home="$BATS_TEST_TMPDIR/limits-compact-layout" now
  now="$(date +%s)"
  agent_limits_fixture "$home" 6530 558050
  printf '{"fetched_at":%s,"five_hour":{"used_percentage":1,"resets_at":%s},"seven_day":{"used_percentage":18,"resets_at":%s}}' \
    "$now" "$((now + 6530))" "$((now + 356450))" \
    > "$home/.cache/claude-rate-limits/latest.json"
  codex_limits_cache "$home" 2 "$((now + 558050))" false 1 "$now"

  # #when the complete provider line renders
  agent_limits_run "$home"

  # #then its separators and spacing match the tab-bar layout exactly
  assert_success
  assert_output '  5h/1% ↻1:48 7d/18% ↻4d3h ·   7d/2% ↻6d11h ×1'
}

function test_scripts_27213_agent_limits_backs_off_after_a_failed_codex_refresh() {
  _bats_test_init 27213 'agent limits backs off after a failed codex refresh'
  local home="$BATS_TEST_TMPDIR/limits-refresh-backoff" marker now
  now="$(date +%s)"
  marker="$home/codex-called"
  agent_limits_fixture "$home" 3600 86400
  codex_limits_cache "$home" 40 "$((now + 86400))" false 0 "$((now - 1140))"
  cat > "$home/bin/codex" <<EOF
#!/bin/sh
printf 'called\n' >> "$marker"
exit 0
EOF
  chmod +x "$home/bin/codex"

  # #when two redraws encounter the same stale cache and a failing backend
  agent_limits_run "$home"
  assert_success
  agent_limits_run "$home"
  assert_success

  # #then the persisted attempt suppresses the second backend call
  assert_equal "$(<"$marker")" 'called'
  assert_file_exists "$home/.cache/codex-rate-limits/last-attempt"
}
