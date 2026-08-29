#!/usr/bin/env bash
# Post-apply suite runner. The .bats files remain the single source of truth;
# they are converted on the fly (deterministic, <1s) and executed with the
# pinned bashunit at tests/lib/bashunit — measured at ~24% less wall-clock
# than bats with per-scenario behavioral parity (403/403 on macOS and
# Ubuntu). Evidence: docs/benchmarks/bashunit-full-suite-experiment.md.
#
# Execution mirrors the previous `bats --jobs 8 --no-parallelize-across-files`
# shape: files run sequentially, tests within a file run with up to
# $MMS_BASHUNIT_JOBS workers (idempotent.bats converts with --serial).
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

python3 "$ROOT/scripts/bats2bashunit.py" \
  --out-dir "$GEN" --manifest "$GEN/manifest.tsv" \
  "$ROOT/tests/smoke.bats" "$ROOT/tests/scripts.bats" \
  "$ROOT/tests/palette.bats" "$ROOT/tests/platform.bats" >/dev/null
python3 "$ROOT/scripts/bats2bashunit.py" --serial \
  --out-dir "$GEN" --manifest "$GEN/manifest.tsv" --append-manifest \
  "$ROOT/tests/idempotent.bats" >/dev/null

rc=0
for base in $files; do
  "$BASHUNIT_BIN" -j "$JOBS" "$GEN/${base}_test.sh" || rc=$?
done
exit "$rc"
