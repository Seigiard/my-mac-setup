#!/usr/bin/env bash
# Post-apply suite runner. Leading '# post-apply:' declarations select the
# tests/bashunit/*_test.sh files, which are written against
# tests/bashunit/test-dsl.bash and executed with the pinned bashunit at
# tests/lib/bashunit — measured at ~24% less wall-clock than the previous bats
# runner with per-scenario behavioral parity (403/403 on macOS and Ubuntu).
# Evidence: docs/benchmarks/bashunit-full-suite-experiment.md.
#
# Execution shape: files run sequentially, tests within a file run with up to
# $MMS_BASHUNIT_JOBS workers (idempotent serializes itself via its
# '# bashunit: no-parallel-tests' marker).
#
# templates_test.sh is deliberately absent: it asserts pre-apply source-tree
# rendering, not post-apply state. It runs as the pre-apply gate in CI,
# docker-compose, and `make test-templates`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="${MMS_BASHUNIT_JOBS:-8}"
# Overridable so the suite contract test can exercise invalid declarations.
GEN="${MMS_BASHUNIT_SUITE_DIR:-$ROOT/tests/bashunit}"
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
  full|host-safe) mode="$1" ;;
  *) usage; exit 2 ;;
esac

suite_declaration() {
  local file="$1" line payload order eligibility extra declaration=""
  while IFS= read -r line; do
    case "$line" in
      '# post-apply:'*)
        [ -z "$declaration" ] || {
          echo "duplicate post-apply declaration: $file" >&2
          return 1
        }
        payload="${line#\# post-apply: }"
        if [ "$payload" = excluded ]; then
          declaration=excluded
          continue
        fi
        read -r order eligibility extra <<EOF
$payload
EOF
        [[ "$order" =~ ^[1-9][0-9]*$ ]] || {
          echo "invalid post-apply declaration: $file" >&2
          return 1
        }
        case "$eligibility" in
          host-safe|needs-disposable-home) ;;
          *) echo "invalid post-apply declaration: $file" >&2; return 1 ;;
        esac
        [ -z "${extra:-}" ] && [ "$line" = "# post-apply: $order $eligibility" ] || {
          echo "invalid post-apply declaration: $file" >&2
          return 1
        }
        declaration="$order $eligibility"
        ;;
      '#!'*|'#'*|'') ;;
      *) break ;;
    esac
  done < "$file"
  [ -n "$declaration" ] || {
    echo "missing post-apply declaration: $file" >&2
    return 1
  }
  printf '%s\n' "$declaration"
}

declarations=""
for file in "$GEN"/*_test.sh; do
  [ -e "$file" ] || continue
  declaration="$(suite_declaration "$file")" || exit $?
  [ "$declaration" != excluded ] || continue
  declarations="${declarations}${declaration} ${file##*/}
"
done
[ -n "$declarations" ] || {
  echo "no declared post-apply suites found in $GEN" >&2
  exit 1
}

files=""
previous_order=""
while read -r order eligibility name; do
  [ -z "$previous_order" ] || [ "$order" != "$previous_order" ] || {
    echo "duplicate post-apply order: $order" >&2
    exit 1
  }
  previous_order="$order"
  if [ "$mode" = full ] || [ "$eligibility" = host-safe ]; then
    files="$files ${name%_test.sh}"
  fi
done <<EOF
$(printf '%s' "$declarations" | sort -n -k1,1)
EOF

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
