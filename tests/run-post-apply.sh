#!/usr/bin/env bash
# Post-apply suite runner. tests/bashunit/*_test.sh are the source of truth,
# written against tests/bashunit/test-dsl.bash, executed with the pinned
# bashunit at tests/lib/bashunit — measured at ~24% less wall-clock than the
# previous bats runner with per-scenario behavioral parity (403/403 on macOS
# and Ubuntu). Evidence: docs/benchmarks/bashunit-full-suite-experiment.md.
#
# Execution shape: files run sequentially, tests within a file run with up to
# $MMS_BASHUNIT_JOBS workers (idempotent serializes itself via its
# '# bashunit: no-parallel-tests' marker).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="${MMS_BASHUNIT_JOBS:-8}"
GEN="$ROOT/tests/bashunit"
# Overridable so the suite contract test can substitute a recording stub.
BASHUNIT_BIN="${MMS_BASHUNIT_BIN:-$ROOT/tests/lib/bashunit}"

usage() {
  cat <<'USAGE' >&2
usage: tests/run-post-apply.sh full|host-safe

full      Run the complete post-apply suite against a disposable home.
host-safe Run only the files that do not execute real chezmoi apply commands.
USAGE
}

case "${1:-}" in
  full)      files="smoke scripts palette platform idempotent" ;;
  host-safe) files="smoke scripts palette platform" ;;
  *) usage; exit 2 ;;
esac

rc=0
for base in $files; do
  report=$(mktemp "${TMPDIR:-/tmp}/bashunit-report.XXXXXX")
  frc=0
  "$BASHUNIT_BIN" -j "$JOBS" --report-json "$report" "$GEN/${base}_test.sh" || frc=$?
  if [ "$frc" -ne 0 ]; then
    rc=$frc
    # Under -j the per-test failure line can be swallowed by a worker; name
    # the failed tests explicitly so CI logs stay diagnosable.
    python3 - "$report" "$base" <<'PYEOF' || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
failed = [t.get("name", "?") for t in data.get("tests", [])
          if t.get("status", "").lower() not in ("passed", "skipped", "risky")]
for name in failed:
    print(f"FAILED [{sys.argv[2]}]: {name}", file=sys.stderr)
PYEOF
  fi
  command rm -f "$report"
done
exit "$rc"
