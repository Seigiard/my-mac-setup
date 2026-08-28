#!/usr/bin/env bash
# bashunit counterpart of tests/run-post-apply.sh. NOT wired into production;
# the experiment's side-by-side and benchmark harnesses call it, and it becomes
# the production runner only if the experiment verdict is a win.
#
# Mirrors `bats --jobs 8 --no-parallelize-across-files`: files run
# sequentially, tests within a file run with up to 8 workers (idempotent
# serializes itself via '# bashunit: no-parallel-tests').
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JOBS="${MMS_BASHUNIT_JOBS:-8}"

usage() {
  cat <<'USAGE' >&2
usage: tests/bashunit/run-post-apply-bashunit.sh full|host-safe

full      Run the complete post-apply suite against a disposable home.
host-safe Run only the files that do not execute real chezmoi apply commands.
USAGE
}

case "${1:-}" in
  full)
    set -- smoke scripts palette platform idempotent
    ;;
  host-safe)
    set -- smoke scripts palette platform
    ;;
  *)
    usage
    exit 2
    ;;
esac

rc=0
for base in "$@"; do
  "$ROOT/tests/lib/bashunit" -j "$JOBS" "$ROOT/tests/bashunit/${base}_test.sh" || rc=$?
done
exit "$rc"
