#!/usr/bin/env bash
# post-apply: 15 host-safe
# Semantic coverage for the paired External leg lifecycle executable.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/common'

PAIR_SCRIPT="${PAIR_SCRIPT_OVERRIDE:-$SOURCE_ROOT/dot_local/bin/executable_se-external-leg-pair}"

pair_stub() {
  PAIR_WORK="$BATS_TEST_TMPDIR/pair"
  PAIR_BIN="$PAIR_WORK/bin"
  PAIR_REPO="$PAIR_WORK/repository"
  PAIR_RESULTS="$PAIR_WORK/results"
  mkdir -p "$PAIR_BIN" "$PAIR_REPO" "$PAIR_RESULTS"
  PAIR_REAL_MKTEMP="$(command -v mktemp)"
  PAIR_REAL_RM="$(command -v rm)"
  PAIR_REAL_CMP="$(command -v cmp)"
  export PAIR_WORK PAIR_REAL_MKTEMP PAIR_REAL_RM PAIR_REAL_CMP

  cat > "$PAIR_BIN/cmp" <<'SH'
#!/usr/bin/env bash
[ "${PAIR_STUB_CMP_FAIL:-0}" != 1 ] || exit 2
exec "$PAIR_REAL_CMP" "$@"
SH

  cat > "$PAIR_BIN/mktemp" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$PAIR_WORK/mktemp-count" ] || read -r count < "$PAIR_WORK/mktemp-count"
count=$((count + 1))
printf '%s\n' "$count" > "$PAIR_WORK/mktemp-count"
[ "${PAIR_STUB_MKTEMP_FAIL_AT:-0}" -ne "$count" ] || exit 1
exec "$PAIR_REAL_MKTEMP" "$@"
SH

  cat > "$PAIR_BIN/rm" <<'SH'
#!/usr/bin/env bash
if [ "${PAIR_STUB_RM_FAIL_TRANSPORT:-0}" = 1 ]; then
  for argument in "$@"; do
    case "$argument" in
      */se-external-leg-pair.*) exit 1 ;;
    esac
  done
fi
exec "$PAIR_REAL_RM" "$@"
SH

  cat > "$PAIR_BIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH

  cat > "$PAIR_BIN/herdr-peer-alias" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$PAIR_WORK/alias-count" ] || read -r count < "$PAIR_WORK/alias-count"
count=$((count + 1))
printf '%s\n' "$count" > "$PAIR_WORK/alias-count"
case "$count" in
  1) printf 'blue-fox\n' ;;
  2) printf 'green-owl\n' ;;
  *) printf 'amber-hare\n' ;;
esac
SH

  cat > "$PAIR_BIN/pre-external-secret-scan" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$PAIR_WORK/scan-count" ] || read -r count < "$PAIR_WORK/scan-count"
count=$((count + 1))
printf '%s\n' "$count" > "$PAIR_WORK/scan-count"
printf 'scan %s\n' "$count" >> "$PAIR_WORK/order.log"
index=0
for target in "$@"; do
  index=$((index + 1))
  printf '%s\n' "$target" >> "$PAIR_WORK/scan-$count.paths"
  [ ! -f "$target" ] || cp "$target" "$PAIR_WORK/scan-$count-$index.input"
done
[ "${SE_SKIP_SECRET_SCAN:-0}" = 1 ] && exit 0
[ "${PAIR_STUB_SCAN_FAIL_AT:-0}" -ne "$count" ]
SH

  cat > "$PAIR_BIN/herdr" <<'SH'
#!/usr/bin/env bash
printf 'herdr' >> "$PAIR_WORK/herdr.log"
printf ' %q' "$@" >> "$PAIR_WORK/herdr.log"
printf '\n' >> "$PAIR_WORK/herdr.log"
printf '%s %s\n' "${1:-}" "${2:-}" >> "$PAIR_WORK/order.log"

case "${1:-} ${2:-}" in
  "tab create")
    count=0
    [ ! -f "$PAIR_WORK/tab-count" ] || read -r count < "$PAIR_WORK/tab-count"
    count=$((count + 1))
    printf '%s\n' "$count" > "$PAIR_WORK/tab-count"
    if [ "${PAIR_STUB_TAB_FAIL_AT:-0}" -eq "$count" ]; then
      printf 'tab create failed\n' >&2
      exit 1
    fi
    if [ "${PAIR_STUB_MALFORMED_TAB_AT:-0}" -eq "$count" ]; then
      printf '{"result":{"tab":{},"root_pane":{"pane_id":"wT:p%s"}}}\n' "$count"
    elif [ "${PAIR_STUB_MISSING_PANE_AT:-0}" -eq "$count" ]; then
      printf '{"result":{"tab":{"tab_id":"wT:t%s"},"root_pane":{}}}\n' "$count"
    else
      printf '{"result":{"tab":{"tab_id":"wT:t%s"},"root_pane":{"pane_id":"wT:p%s"}}}\n' "$count" "$count"
    fi
    ;;
  "agent start")
    count=0
    [ ! -f "$PAIR_WORK/start-count" ] || read -r count < "$PAIR_WORK/start-count"
    count=$((count + 1))
    printf '%s\n' "$count" > "$PAIR_WORK/start-count"
    if [ "${PAIR_STUB_START_MIXED_TRANSIENT:-0}" = 1 ] && [ "$count" -eq 1 ]; then
      printf 'agent_pane_busy\n' >&2
      exit 1
    fi
    if [ "${PAIR_STUB_START_MIXED_TRANSIENT:-0}" = 1 ] && [ "$count" -eq 2 ]; then
      printf 'agent_name_taken\n' >&2
      exit 1
    fi
    printf '{"result":{"agent":{"interactive_ready":true}}}\n'
    ;;
  "agent prompt")
    pane="$3"
    prompt="$4"
    prompt_file="$PAIR_WORK/prompt-${pane##*:}"
    printf '%s' "$prompt" > "$prompt_file"
    report_path=""
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        'Report path: '*) report_path="${line#Report path: }" ;;
        'Recovery report path: '*) report_path="${line#Recovery report path: }" ;;
      esac
    done < "$prompt_file"
    [ -z "$report_path" ] || printf '%s' "$report_path" > "$PAIR_WORK/report-${pane##*:}.path"

    if [ "${5:-}" = --wait ]; then
      if [ "${PAIR_STUB_RECOVER:-0}" = 1 ] && [ -n "$report_path" ]; then
        printf '%s' "${PAIR_STUB_RECOVER_BODY:-recovered}" > "$report_path"
      fi
    elif [ -n "$report_path" ]; then
      case "$pane" in
        wT:p1) mode="${PAIR_STUB_CLAUDE_MODE:-write}"; body="${PAIR_STUB_CLAUDE_REPORT:-claude report}" ;;
        *) mode="${PAIR_STUB_OPENCODE_MODE:-write}"; body="${PAIR_STUB_OPENCODE_REPORT:-opencode report}" ;;
      esac
      if [ "${PAIR_STUB_PROMPT_ACK_FAIL_PANE:-}" = "$pane" ]; then
        printf '%s' "$report_path" > "$PAIR_WORK/pending-${pane##*:}.path"
        printf '%s' "$mode" > "$PAIR_WORK/pending-${pane##*:}.mode"
        printf '%s' "$body" > "$PAIR_WORK/pending-${pane##*:}.body"
        exit 1
      fi
      case "$mode" in
        write) printf '%s' "$body" > "$report_path" ;;
        empty) : > "$report_path" ;;
        symlink) ln -s /etc/hosts "$report_path" ;;
        none) : ;;
      esac
    fi
    printf '{"result":{"agent":{"agent_status":"working"}}}\n'
    ;;
  "agent wait")
    pane="$3"
    if [ -f "$PAIR_WORK/pending-${pane##*:}.path" ]; then
      report_path="$(cat "$PAIR_WORK/pending-${pane##*:}.path")"
      mode="$(cat "$PAIR_WORK/pending-${pane##*:}.mode")"
      body="$(cat "$PAIR_WORK/pending-${pane##*:}.body")"
      case "$mode" in
        write) printf '%s' "$body" > "$report_path" ;;
        empty) : > "$report_path" ;;
        symlink) ln -s /etc/hosts "$report_path" ;;
        none) : ;;
      esac
    fi
    exit 0
    ;;
  "agent read")
    printf 'diagnostic only\n'
    ;;
  "tab close")
    printf '%s\n' "$3" >> "$PAIR_WORK/closed-tabs"
    if [ "${PAIR_STUB_ASSERT_NO_STAGE_ON_CLOSE:-0}" = 1 ]; then
      for candidate in "$PAIR_RESULTS"/.se-external-leg-pair.*; do
        [ ! -e "$candidate" ] && [ ! -L "$candidate" ] || exit 1
      done
    fi
    [ "${PAIR_STUB_CLOSE_FAIL_TAB:-}" != "$3" ]
    ;;
  *) exit 2 ;;
esac
SH

  cat > "$PAIR_BIN/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cp "$PAIR_BIN/claude" "$PAIR_BIN/opencode"
  chmod +x "$PAIR_BIN/cmp" "$PAIR_BIN/mktemp" "$PAIR_BIN/rm" "$PAIR_BIN/sleep" "$PAIR_BIN/herdr-peer-alias" "$PAIR_BIN/pre-external-secret-scan" \
    "$PAIR_BIN/herdr" "$PAIR_BIN/claude" "$PAIR_BIN/opencode"

  printf 'claude scope' > "$PAIR_WORK/claude.prompt"
  printf 'opencode scope' > "$PAIR_WORK/opencode.prompt"
  printf 'frozen document' > "$PAIR_WORK/document.md"
}

function test_external_leg_pair_1301_scans_exact_inputs_before_launch_and_publishes_distinct_reports() {
  _bats_test_init 1301 'External leg pair scans exact inputs before launch and publishes distinct reports'
  pair_stub
  local result="$PAIR_RESULTS/distinct"

  run env PATH="$PAIR_BIN:$PATH" PAIR_STUB_ASSERT_NO_STAGE_ON_CLOSE=1 HERDR_ENV=1 HERDR_WORKSPACE_ID=wT \
    bash "$PAIR_SCRIPT" --complexity medium --effort high --repo-root "$PAIR_REPO" \
      --claude-prompt-file "$PAIR_WORK/claude.prompt" \
      --opencode-prompt-file "$PAIR_WORK/opencode.prompt" \
      --exposed-document "$PAIR_WORK/document.md" --result-dir "$result"
  assert_success

  run jq -cS '{classification,cleanup,interface,reports,scan}' "$result/result.json"
  assert_success
  assert_output '{"classification":"paired","cleanup":"complete","interface":"se-external-leg-pair/v1","reports":[{"path":"claude.report","source":"claude"},{"path":"opencode.report","source":"opencode"}],"scan":"clean"}'
  run cmp -s "$result/claude.report" <(printf 'claude report')
  assert_success
  run cmp -s "$result/opencode.report" <(printf 'opencode report')
  assert_success

  run python3 - "$PAIR_WORK/order.log" <<'PY'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert lines.index("scan 1") < lines.index("tab create")
prompts = [i for i, line in enumerate(lines) if line == "agent prompt"]
waits = [i for i, line in enumerate(lines) if line == "agent wait"]
assert len(prompts) == 2
assert len(waits) == 2
assert max(prompts) < min(waits)
PY
  assert_success

  run python3 - "$PAIR_WORK" <<'PY'
import pathlib
import sys

work = pathlib.Path(sys.argv[1])
paths = (work / "scan-1.paths").read_text().splitlines()
assert pathlib.Path(paths[0]).samefile(work / "repository")
assert pathlib.Path(paths[1]).samefile(work / "document.md")
assert pathlib.Path(paths[2]).name == "claude.prompt"
assert pathlib.Path(paths[3]).name == "opencode.prompt"
assert len(paths) == 4
claude_prompt = (work / "scan-1-3.input").read_text()
opencode_prompt = (work / "scan-1-4.input").read_text()
assert claude_prompt.startswith("claude scope")
assert opencode_prompt.startswith("opencode scope")
assert "Report path: " in claude_prompt
assert "Report path: " in opencode_prompt
assert claude_prompt != opencode_prompt
PY
  assert_success
  run cmp -s "$PAIR_WORK/scan-1-3.input" "$PAIR_WORK/prompt-p1"
  assert_success
  run cmp -s "$PAIR_WORK/scan-1-4.input" "$PAIR_WORK/prompt-p2"
  assert_success
  local transport
  transport="$(dirname "$(cat "$PAIR_WORK/report-p1.path")")"
  assert_dir_not_exists "$transport"
  run python3 - "$PAIR_RESULTS" <<'PY'
import pathlib
import sys

assert not list(pathlib.Path(sys.argv[1]).glob(".se-external-leg-pair.*"))
PY
  assert_success
  run grep -F -- '--kind claude' "$PAIR_WORK/herdr.log"
  assert_success
  assert_output --partial '--model sonnet'
  assert_output --partial '--effort high'
  run grep -F -- '--kind opencode' "$PAIR_WORK/herdr.log"
  assert_success
  assert_output --partial '--model openai/gpt-5.6-terra'
  assert_output --partial '--agent build'
}

function test_external_leg_pair_1302_refuses_before_tabs_and_records_an_explicit_scan_waiver() {
  _bats_test_init 1302 'External leg pair refuses before tabs and records an explicit scan waiver'
  pair_stub
  local refused="$PAIR_RESULTS/refused" waived="$PAIR_RESULTS/waived"

  run env PATH="$PAIR_BIN:$PATH" PAIR_STUB_SCAN_FAIL_AT=1 HERDR_ENV=1 HERDR_WORKSPACE_ID=wT \
    bash "$PAIR_SCRIPT" --complexity medium --effort high --repo-root "$PAIR_REPO" \
      --claude-prompt-file "$PAIR_WORK/claude.prompt" \
      --opencode-prompt-file "$PAIR_WORK/opencode.prompt" --result-dir "$refused"
  assert_failure 2
  assert_dir_not_exists "$refused"
  assert_file_not_exists "$PAIR_WORK/herdr.log"
  local refused_transport
  refused_transport="$(dirname "$(sed -n '2p' "$PAIR_WORK/scan-1.paths")")"
  assert_dir_not_exists "$refused_transport"

  rm -f "$PAIR_WORK/alias-count" "$PAIR_WORK/scan-count" "$PAIR_WORK/order.log"
  run env PATH="$PAIR_BIN:$PATH" PAIR_STUB_SCAN_FAIL_AT=1 SE_SKIP_SECRET_SCAN=1 \
    HERDR_ENV=1 HERDR_WORKSPACE_ID=wT bash "$PAIR_SCRIPT" --complexity medium --effort high \
      --repo-root "$PAIR_REPO" \
      --claude-prompt-file "$PAIR_WORK/claude.prompt" \
      --opencode-prompt-file "$PAIR_WORK/opencode.prompt" --result-dir "$waived"
  assert_success
  run jq -r '.scan' "$waived/result.json"
  assert_success
  assert_output waived
}

function test_external_leg_pair_1303_rescans_recovery_prompts_and_counts_identical_reports_once() {
  _bats_test_init 1303 'External leg pair rescans recovery prompts and counts identical reports once'
  pair_stub
  local result="$PAIR_RESULTS/identical"

  run env PATH="$PAIR_BIN:$PATH" PAIR_STUB_CLAUDE_MODE=none PAIR_STUB_OPENCODE_MODE=none \
    PAIR_STUB_RECOVER=1 PAIR_STUB_RECOVER_BODY='same report' \
    HERDR_ENV=1 HERDR_WORKSPACE_ID=wT bash "$PAIR_SCRIPT" --complexity medium --effort high \
      --repo-root "$PAIR_REPO" \
      --claude-prompt-file "$PAIR_WORK/claude.prompt" \
      --opencode-prompt-file "$PAIR_WORK/opencode.prompt" \
      --exposed-document "$PAIR_WORK/document.md" --result-dir "$result"
  assert_success
  run jq -cS '{classification,legs,reports}' "$result/result.json"
  assert_success
  assert_output '{"classification":"identical-single","legs":{"claude":"recovered","opencode":"recovered"},"reports":[{"path":"identical.report","source":"indeterminate"}]}'
  assert_file_exists "$result/identical.report"
  assert_file_not_exists "$result/claude.report"
  assert_file_not_exists "$result/opencode.report"
  run cmp -s "$result/identical.report" <(printf 'same report')
  assert_success
  run cat "$PAIR_WORK/scan-count"
  assert_success
  assert_output 3
  run python3 - "$PAIR_WORK" <<'PY'
import pathlib
import sys

work = pathlib.Path(sys.argv[1])
for count, pane in ((2, "p1"), (3, "p2")):
    paths = (work / f"scan-{count}.paths").read_text().splitlines()
    assert pathlib.Path(paths[0]).samefile(work / "repository")
    assert pathlib.Path(paths[1]).samefile(work / "document.md")
    assert pathlib.Path(paths[2]).name.endswith("recovery.prompt")
    assert len(paths) == 3
    assert (work / f"scan-{count}-3.input").read_bytes() == (work / f"prompt-{pane}").read_bytes()
order = (work / "order.log").read_text().splitlines()
assert order.index("scan 2") < order.index("agent prompt", order.index("scan 2"))
assert order.index("scan 3") < order.index("agent prompt", order.index("scan 3"))
PY
  assert_success
}

function test_external_leg_pair_1304_withholds_results_when_cleanup_is_incomplete() {
  _bats_test_init 1304 'External leg pair withholds results when cleanup is incomplete'
  pair_stub
  local result="$PAIR_RESULTS/cleanup-failed"

  run env PATH="$PAIR_BIN:$PATH" PAIR_STUB_CLOSE_FAIL_TAB=wT:t1 PAIR_STUB_ASSERT_NO_STAGE_ON_CLOSE=1 \
    HERDR_ENV=1 HERDR_WORKSPACE_ID=wT bash "$PAIR_SCRIPT" --complexity medium --effort high \
      --repo-root "$PAIR_REPO" \
      --claude-prompt-file "$PAIR_WORK/claude.prompt" \
      --opencode-prompt-file "$PAIR_WORK/opencode.prompt" --result-dir "$result"
  assert_failure 3
  assert_dir_not_exists "$result"
  run cat "$PAIR_WORK/closed-tabs"
  assert_success
  assert_line --index 0 wT:t1
  assert_line --index 1 wT:t2
  assert_line --index 2 wT:t1
  local transport
  transport="$(dirname "$(cat "$PAIR_WORK/report-p1.path")")"
  assert_dir_not_exists "$transport"
  run python3 - "$PAIR_RESULTS" <<'PY'
import pathlib
import sys

assert not list(pathlib.Path(sys.argv[1]).glob(".se-external-leg-pair.*"))
PY
  assert_success
}

function test_external_leg_pair_1305_preserves_a_valid_claude_report_when_opencode_fails() {
  _bats_test_init 1305 'External leg pair preserves a valid Claude report when OpenCode fails'
  pair_stub
  local result="$PAIR_RESULTS/claude-only"

  run env PATH="$PAIR_BIN:$PATH" PAIR_STUB_OPENCODE_MODE=symlink \
    HERDR_ENV=1 HERDR_WORKSPACE_ID=wT bash "$PAIR_SCRIPT" --complexity medium --effort high \
      --repo-root "$PAIR_REPO" \
      --claude-prompt-file "$PAIR_WORK/claude.prompt" \
      --opencode-prompt-file "$PAIR_WORK/opencode.prompt" --result-dir "$result"
  assert_success
  run jq -cS '{classification,legs,reports}' "$result/result.json"
  assert_success
  assert_output '{"classification":"claude-only","legs":{"claude":"delivered","opencode":"malformed"},"reports":[{"path":"claude.report","source":"claude"}]}'
  run cmp -s "$result/claude.report" <(printf 'claude report')
  assert_success
  assert_file_not_exists "$result/opencode.report"
}

function test_external_leg_pair_1306_preserves_a_valid_opencode_report_when_claude_fails() {
  _bats_test_init 1306 'External leg pair preserves a valid OpenCode report when Claude fails'
  pair_stub
  local result="$PAIR_RESULTS/opencode-only"

  run env PATH="$PAIR_BIN:$PATH" PAIR_STUB_CLAUDE_MODE=symlink \
    HERDR_ENV=1 HERDR_WORKSPACE_ID=wT bash "$PAIR_SCRIPT" --complexity medium --effort high \
      --repo-root "$PAIR_REPO" \
      --claude-prompt-file "$PAIR_WORK/claude.prompt" \
      --opencode-prompt-file "$PAIR_WORK/opencode.prompt" --result-dir "$result"
  assert_success
  run jq -cS '{classification,legs,reports}' "$result/result.json"
  assert_success
  assert_output '{"classification":"opencode-only","legs":{"claude":"malformed","opencode":"delivered"},"reports":[{"path":"opencode.report","source":"opencode"}]}'
  run cmp -s "$result/opencode.report" <(printf 'opencode report')
  assert_success
  assert_file_not_exists "$result/claude.report"
}

function test_external_leg_pair_1307_publishes_none_only_after_complete_cleanup() {
  _bats_test_init 1307 'External leg pair publishes none only after complete cleanup'
  pair_stub
  local result="$PAIR_RESULTS/none"

  run env PATH="$PAIR_BIN:$PATH" PAIR_STUB_CLAUDE_MODE=symlink PAIR_STUB_OPENCODE_MODE=symlink \
    HERDR_ENV=1 HERDR_WORKSPACE_ID=wT bash "$PAIR_SCRIPT" --complexity medium --effort high \
      --repo-root "$PAIR_REPO" \
      --claude-prompt-file "$PAIR_WORK/claude.prompt" \
      --opencode-prompt-file "$PAIR_WORK/opencode.prompt" --result-dir "$result"
  assert_failure 1
  run jq -cS '{classification,cleanup,legs,reports}' "$result/result.json"
  assert_success
  assert_output '{"classification":"none","cleanup":"complete","legs":{"claude":"malformed","opencode":"malformed"},"reports":[]}'
  assert_file_not_exists "$result/claude.report"
  assert_file_not_exists "$result/opencode.report"
}

function test_external_leg_pair_1308_treats_untracked_tabs_and_failed_error_cleanup_as_exit_three() {
  _bats_test_init 1308 'External leg pair treats untracked tabs and failed error cleanup as exit three'
  pair_stub
  local malformed="$PAIR_RESULTS/malformed-tab" staging="$PAIR_RESULTS/staging-failed"

  run env PATH="$PAIR_BIN:$PATH" PAIR_STUB_MALFORMED_TAB_AT=1 \
    HERDR_ENV=1 HERDR_WORKSPACE_ID=wT bash "$PAIR_SCRIPT" --complexity medium --effort high \
      --repo-root "$PAIR_REPO" \
      --claude-prompt-file "$PAIR_WORK/claude.prompt" \
      --opencode-prompt-file "$PAIR_WORK/opencode.prompt" --result-dir "$malformed"
  assert_failure 3
  assert_dir_not_exists "$malformed"
  local malformed_transport
  malformed_transport="$(dirname "$(sed -n '2p' "$PAIR_WORK/scan-1.paths")")"
  assert_dir_not_exists "$malformed_transport"

  rm -rf "$PAIR_WORK"
  pair_stub
  run env PATH="$PAIR_BIN:$PATH" PAIR_STUB_MKTEMP_FAIL_AT=2 PAIR_STUB_RM_FAIL_TRANSPORT=1 \
    HERDR_ENV=1 HERDR_WORKSPACE_ID=wT bash "$PAIR_SCRIPT" --complexity medium --effort high \
      --repo-root "$PAIR_REPO" \
      --claude-prompt-file "$PAIR_WORK/claude.prompt" \
      --opencode-prompt-file "$PAIR_WORK/opencode.prompt" --result-dir "$staging"
  assert_failure 3
  assert_output --partial 'could not stage the result'
  assert_output --partial 'cleanup failed for transport'
  assert_dir_not_exists "$staging"
  run cat "$PAIR_WORK/mktemp-count"
  assert_success
  assert_output 2

  rm -rf "$PAIR_WORK"
  pair_stub
  local known_tab="$PAIR_RESULTS/known-tab"
  run env PATH="$PAIR_BIN:$PATH" PAIR_STUB_MISSING_PANE_AT=1 \
    HERDR_ENV=1 HERDR_WORKSPACE_ID=wT bash "$PAIR_SCRIPT" --complexity medium --effort high \
      --repo-root "$PAIR_REPO" \
      --claude-prompt-file "$PAIR_WORK/claude.prompt" \
      --opencode-prompt-file "$PAIR_WORK/opencode.prompt" --result-dir "$known_tab"
  assert_success
  run jq -cS '{classification,legs}' "$known_tab/result.json"
  assert_success
  assert_output '{"classification":"opencode-only","legs":{"claude":"tab-malformed","opencode":"delivered"}}'
  run cat "$PAIR_WORK/closed-tabs"
  assert_success
  assert_line --index 0 wT:t1
  assert_line --index 1 wT:t2
}

function test_external_leg_pair_1309_recovers_mixed_start_races_and_keeps_an_ack_lost_report() {
  _bats_test_init 1309 'External leg pair recovers mixed start races and keeps an ack-lost report'
  pair_stub
  local result="$PAIR_RESULTS/transient"

  run env PATH="$PAIR_BIN:$PATH" PAIR_STUB_START_MIXED_TRANSIENT=1 \
    PAIR_STUB_PROMPT_ACK_FAIL_PANE=wT:p1 HERDR_ENV=1 HERDR_WORKSPACE_ID=wT \
    bash "$PAIR_SCRIPT" --complexity medium --effort high --repo-root "$PAIR_REPO" \
      --claude-prompt-file "$PAIR_WORK/claude.prompt" \
      --opencode-prompt-file "$PAIR_WORK/opencode.prompt" --result-dir "$result"
  assert_success
  run jq -cS '{classification,legs}' "$result/result.json"
  assert_success
  assert_output '{"classification":"paired","legs":{"claude":"delivered","opencode":"delivered"}}'
  run cat "$PAIR_WORK/start-count"
  assert_success
  assert_output 4
  run grep -F 'agent start amber-hare' "$PAIR_WORK/herdr.log"
  assert_success
}

function test_external_leg_pair_1310_degrades_when_one_tab_cannot_start() {
  _bats_test_init 1310 'External leg pair degrades when one tab cannot start'
  pair_stub
  local result="$PAIR_RESULTS/tab-failed"

  run env PATH="$PAIR_BIN:$PATH" PAIR_STUB_TAB_FAIL_AT=1 \
    HERDR_ENV=1 HERDR_WORKSPACE_ID=wT bash "$PAIR_SCRIPT" --complexity medium --effort high \
      --repo-root "$PAIR_REPO" \
      --claude-prompt-file "$PAIR_WORK/claude.prompt" \
      --opencode-prompt-file "$PAIR_WORK/opencode.prompt" --result-dir "$result"
  assert_success
  run jq -cS '{classification,legs,reports}' "$result/result.json"
  assert_success
  assert_output '{"classification":"opencode-only","legs":{"claude":"tab-create-failed","opencode":"delivered"},"reports":[{"path":"opencode.report","source":"opencode"}]}'
  run cat "$PAIR_WORK/closed-tabs"
  assert_success
  assert_output wT:t2
}

function test_external_leg_pair_1311_refuses_to_classify_when_report_comparison_fails() {
  _bats_test_init 1311 'External leg pair refuses to classify when report comparison fails'
  pair_stub
  local result="$PAIR_RESULTS/compare-failed"

  run env PATH="$PAIR_BIN:$PATH" PAIR_STUB_CMP_FAIL=1 \
    HERDR_ENV=1 HERDR_WORKSPACE_ID=wT bash "$PAIR_SCRIPT" --complexity medium --effort high \
      --repo-root "$PAIR_REPO" \
      --claude-prompt-file "$PAIR_WORK/claude.prompt" \
      --opencode-prompt-file "$PAIR_WORK/opencode.prompt" --result-dir "$result"
  assert_failure 1
  assert_output --partial 'could not compare peer reports'
  assert_dir_not_exists "$result"
  run cat "$PAIR_WORK/closed-tabs"
  assert_success
  assert_line --index 0 wT:t1
  assert_line --index 1 wT:t2
  local transport
  transport="$(dirname "$(cat "$PAIR_WORK/report-p1.path")")"
  assert_dir_not_exists "$transport"
}

function test_external_leg_pair_1312_refuses_missing_or_unsupported_selection_before_tabs() {
  _bats_test_init 1312 'External leg pair refuses missing or unsupported selection before tabs'
  pair_stub
  local result="$PAIR_RESULTS/refused-selection"

  run env PATH="$PAIR_BIN:$PATH" HERDR_ENV=1 HERDR_WORKSPACE_ID=wT bash "$PAIR_SCRIPT" \
    --effort high --repo-root "$PAIR_REPO" \
    --claude-prompt-file "$PAIR_WORK/claude.prompt" \
    --opencode-prompt-file "$PAIR_WORK/opencode.prompt" --result-dir "$result"
  assert_failure 2
  assert_output --partial '--complexity is required'

  run env PATH="$PAIR_BIN:$PATH" HERDR_ENV=1 HERDR_WORKSPACE_ID=wT bash "$PAIR_SCRIPT" \
    --complexity medium --repo-root "$PAIR_REPO" \
    --claude-prompt-file "$PAIR_WORK/claude.prompt" \
    --opencode-prompt-file "$PAIR_WORK/opencode.prompt" --result-dir "$result"
  assert_failure 2
  assert_output --partial '--effort is required'

  run env PATH="$PAIR_BIN:$PATH" HERDR_ENV=1 HERDR_WORKSPACE_ID=wT bash "$PAIR_SCRIPT" \
    --complexity extreme --effort high --repo-root "$PAIR_REPO" \
    --claude-prompt-file "$PAIR_WORK/claude.prompt" \
    --opencode-prompt-file "$PAIR_WORK/opencode.prompt" --result-dir "$result"
  assert_failure 2
  assert_output --partial '--complexity must be one of: low, medium, high, xhigh'

  run env PATH="$PAIR_BIN:$PATH" HERDR_ENV=1 HERDR_WORKSPACE_ID=wT bash "$PAIR_SCRIPT" \
    --complexity medium --effort extreme --repo-root "$PAIR_REPO" \
    --claude-prompt-file "$PAIR_WORK/claude.prompt" \
    --opencode-prompt-file "$PAIR_WORK/opencode.prompt" --result-dir "$result"
  assert_failure 2
  assert_output --partial '--effort must be one of: low, medium, high, xhigh, max'
  assert_file_not_exists "$PAIR_WORK/herdr.log"
  assert_dir_not_exists "$result"
}

function test_external_leg_pair_1313_maps_every_complexity_and_effort_to_launch_settings() {
  _bats_test_init 1313 'External leg pair maps every complexity and effort to launch settings'
  local selection complexity effort claude_model opencode_model result

  for selection in \
    'low low sonnet openai/gpt-5.6-luna' \
    'low medium sonnet openai/gpt-5.6-luna' \
    'medium high sonnet openai/gpt-5.6-terra' \
    'high xhigh opus openai/gpt-5.6-sol' \
    'xhigh max fable openai/gpt-6-astra'; do
    read -r complexity effort claude_model opencode_model <<< "$selection"
    rm -rf "$BATS_TEST_TMPDIR/pair"
    pair_stub
    result="$PAIR_RESULTS/$complexity-$effort"

    run env PATH="$PAIR_BIN:$PATH" HERDR_ENV=1 HERDR_WORKSPACE_ID=wT bash "$PAIR_SCRIPT" \
      --complexity "$complexity" --effort "$effort" --repo-root "$PAIR_REPO" \
      --claude-prompt-file "$PAIR_WORK/claude.prompt" \
      --opencode-prompt-file "$PAIR_WORK/opencode.prompt" --result-dir "$result"
    assert_success

    run grep -F -- '--kind claude' "$PAIR_WORK/herdr.log"
    assert_success
    assert_output --partial "--model $claude_model"
    assert_output --partial "--effort $effort"
    run grep -F -- '--kind opencode' "$PAIR_WORK/herdr.log"
    assert_success
    assert_output --partial "--model $opencode_model"
    run python3 - "$PAIR_WORK/herdr.log" "$effort" "$opencode_model" <<'PY'
import json
import shlex
import sys

for line in open(sys.argv[1], encoding="utf-8"):
    arguments = shlex.split(line)
    if arguments[:3] == ["herdr", "tab", "create"] and "--env" in arguments:
        value = arguments[arguments.index("--env") + 1]
        config = json.loads(value.split("=", 1)[1])
        assert config["agent"]["build"]["model"] == sys.argv[3]
        assert config["agent"]["build"]["variant"] == sys.argv[2]
        break
else:
    raise AssertionError("OpenCode tab environment was not forwarded")
PY
    assert_success

    run jq -cS '.selection' "$result/result.json"
    assert_success
    assert_output "{\"mapping\":\"external-leg-models/2026-09-12\",\"requested\":{\"complexity\":\"$complexity\",\"effort\":\"$effort\"},\"resolved\":{\"claude\":{\"effort\":\"$effort\",\"model\":\"$claude_model\"},\"opencode\":{\"model\":\"$opencode_model\",\"variant\":\"$effort\"}}}"
  done
}

function test_external_leg_pair_1314_mapped_claude_settings_exist_in_the_installed_client() {
  _bats_test_init 1314 'External leg pair mapped Claude settings exist in the installed client'
  command_exists claude || skip "claude is not installed"
  local help model effort

  run claude --help
  assert_success
  help="$output"
  for model in sonnet opus fable; do
    run grep -F -- "'$model'" <<< "$help"
    assert_success
  done

  for effort in low medium high xhigh max; do
    run claude --effort "$effort" --version
    assert_success
    refute_output --partial 'Unknown --effort value'
  done
}

function test_external_leg_pair_1315_mapped_opencode_settings_exist_in_the_installed_client() {
  _bats_test_init 1315 'External leg pair mapped OpenCode settings exist in the installed client'
  command_exists opencode || skip "opencode is not installed"
  local catalog="$BATS_TEST_TMPDIR/opencode-models"

  run opencode models openai --verbose
  [ "$status" -eq 0 ] || skip "installed opencode has no openai model catalog: $output"
  assert_success
  printf '%s\n' "$output" > "$catalog"
  run python3 - "$catalog" <<'PY'
import json
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
decoder = json.JSONDecoder()
catalog = {}
for match in re.finditer(r"^(openai/[^\n]+)\n", text, re.MULTILINE):
    metadata, _ = decoder.raw_decode(text[match.end():].lstrip())
    catalog[match.group(1)] = metadata

efforts = {"low", "medium", "high", "xhigh", "max"}
for model in (
    "openai/gpt-5.6-luna",
    "openai/gpt-5.6-terra",
    "openai/gpt-5.6-sol",
    "openai/gpt-6-astra",
):
    assert model in catalog
    assert efforts <= set(catalog[model]["variants"])
PY
  assert_success
}

function set_up_before_script() {
  :
}

function tear_down_after_script() {
  _bats_file_cleanup
}

function tear_down() { _bats_run_teardown; }
