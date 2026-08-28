#!/usr/bin/env bash
# Measurement harness for the ce-optimize run "test-suite-time".
# IMMUTABLE during the run: experiments must not edit this file.
#
# Runs the complete production test suite:
#   1. make test-issues        (host, python)
#   2. make build-docker       (docker image build, warm cache expected)
#   3. docker compose run --rm -T test-ubuntu   (full in-container suite)
#   4. make test-suite         (host-safe parallel bats suite on macOS)
# and emits one JSON object on stdout. All suite output goes to log files
# under $MMS_MEASURE_LOGDIR (default: alongside this script, logs/<ts>/).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$REPO_ROOT"

TS="$(date +%Y%m%dT%H%M%S)"
LOGDIR="${MMS_MEASURE_LOGDIR:-$REPO_ROOT/.context/compound-engineering/ce-optimize/test-suite-time/logs/$TS}"
mkdir -p "$LOGDIR"

now() { date +%s; }

run_timed() { # name command...
  local name="$1"; shift
  local t0 t1 rc
  t0=$(now)
  "$@" >"$LOGDIR/$name.log" 2>&1
  rc=$?
  t1=$(now)
  eval "${name}_seconds=$((t1 - t0))"
  eval "${name}_rc=$rc"
}

# Count bats results across every bats invocation in the log. Non-TTY runs
# emit TAP ("ok N ...", "not ok N ...", skips as "ok N ... # skip[ reason]");
# pretty-mode runs end with "N tests, M failures[, K skipped]" summary lines.
# Handle both, preferring TAP lines when present.
bats_counts() { # logfile -> "tests failures skipped"
  sed -e $'s/\x1b\\[[0-9;]*m//g' "$1" | awk '
    /^ok [0-9]+ /      { tap_t++; if (/# skip/) tap_s++; next }
    /^not ok [0-9]+ /  { tap_t++; tap_f++; next }
    /^[0-9]+ tests?, [0-9]+ failure/ {
      sum_t += $1; sum_f += $3;
      if (match($0, /[0-9]+ skipped/)) { sum_s += substr($0, RSTART, RLENGTH - 8) + 0 }
    }
    END {
      if (tap_t > 0) printf "%d %d %d", tap_t, tap_f+0, tap_s+0;
      else printf "%d %d %d", sum_t+0, sum_f+0, sum_s+0
    }'
}

total0=$(now)
run_timed test_issues make test-issues
run_timed docker_build make build-docker
run_timed docker_suite docker compose -f docker/docker-compose.yml run --rm -T test-ubuntu
total1=$(now)
full_suite_wall_seconds=$((total1 - total0))

run_timed host_suite make test-suite

read -r docker_tests docker_fails docker_skips <<<"$(bats_counts "$LOGDIR/docker_suite.log")"
read -r host_tests host_fails host_skips <<<"$(bats_counts "$LOGDIR/host_suite.log")"

suite_passed=1
[ "$test_issues_rc" -eq 0 ] || suite_passed=0
[ "$docker_build_rc" -eq 0 ] || suite_passed=0
[ "$docker_suite_rc" -eq 0 ] || suite_passed=0
[ "$host_suite_rc" -eq 0 ] || suite_passed=0

cat <<JSON
{
  "full_suite_wall_seconds": $full_suite_wall_seconds,
  "host_suite_wall_seconds": $host_suite_seconds,
  "suite_passed": $suite_passed,
  "docker_test_count": $docker_tests,
  "docker_fail_count": $docker_fails,
  "docker_skip_count": $docker_skips,
  "host_test_count": $host_tests,
  "host_fail_count": $host_fails,
  "host_skip_count": $host_skips,
  "test_issues_seconds": $test_issues_seconds,
  "docker_build_seconds": $docker_build_seconds,
  "docker_suite_seconds": $docker_suite_seconds,
  "log_dir": "$LOGDIR"
}
JSON
