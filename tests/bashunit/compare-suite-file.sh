#!/usr/bin/env bash
# Side-by-side runner for one suite file: production-shaped Bats run, then the
# converted bashunit run, then the per-scenario verifier plus process/path leak
# checks around each side. Artifacts land in $OUT_DIR (default .context/
# bashunit-full-suite/compare). Exit 0 only when the verifier reports parity
# and no leaks are detected.
set -u

BASE="${1:?usage: compare-suite-file.sh <base e.g. palette> [jobs]}"
JOBS="${2:-8}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/.context/bashunit-full-suite/compare}"
# Overridable for fixtures (negative controls) living outside tests/.
BATS_PATH="${BATS_PATH:-$ROOT/tests/$BASE.bats}"
BU_PATH="${BU_PATH:-$ROOT/tests/bashunit/${BASE}_test.sh}"
MANIFEST="${MANIFEST:-$ROOT/tests/bashunit/manifest.tsv}"
mkdir -p "$OUT_DIR"

# Daemon/process patterns this suite is known to spawn.
LEAK_PATTERNS='htspwn|herdr|sweep-daemon|chezmoi-test'

snapshot_procs() {
  # macOS pgrep has no -E; its patterns are ERE already. Filter to test debris:
  # exclude the interactive herdr session and this script itself.
  pgrep -lf "$LEAK_PATTERNS" 2>/dev/null \
    | grep -v -e "compare-suite-file" -e "/usr/bin/login" -e "exec -l /bin/zsh" \
    | grep -v -e '^[0-9][0-9]* h[e]rdr$' -e 'p[g]rep' -e 'g[r]ep -v' \
    || true
}
snapshot_tmp() {
  ls -d /tmp/htspwn* /tmp/bats-compat-run.* /tmp/bats-run-* 2>/dev/null || true
}

leak_check() { # label pre_procs pre_tmp
  local label="$1" pre_procs="$2" pre_tmp="$3" post_procs post_tmp rc=0
  post_procs="$(snapshot_procs)"
  post_tmp="$(snapshot_tmp)"
  if [ "$post_procs" != "$pre_procs" ]; then
    echo "LEAK-PROCESS ($label):"
    printf '%s\n' "$post_procs" | grep -vxF -f <(printf '%s\n' "$pre_procs") || true
    rc=1
  fi
  if [ "$post_tmp" != "$pre_tmp" ]; then
    echo "LEAK-PATH ($label):"
    printf '%s\n' "$post_tmp" | grep -vxF -f <(printf '%s\n' "$pre_tmp") || true
    rc=1
  fi
  return $rc
}

overall=0

pre_procs="$(snapshot_procs)"; pre_tmp="$(snapshot_tmp)"
start=$(date +%s)
bats --jobs "$JOBS" --no-parallelize-across-files --tap \
  "$BATS_PATH" > "$OUT_DIR/bats-$BASE.tap" 2>&1
bats_rc=$?
bats_secs=$(( $(date +%s) - start ))
leak_check "bats/$BASE" "$pre_procs" "$pre_tmp" || overall=1

pre_procs="$(snapshot_procs)"; pre_tmp="$(snapshot_tmp)"
start=$(date +%s)
"$ROOT/tests/lib/bashunit" -j "$JOBS" --output tap \
  --report-json "$OUT_DIR/bashunit-$BASE.json" \
  "$BU_PATH" > "$OUT_DIR/bashunit-$BASE.tap" 2>&1
bu_rc=$?
bu_secs=$(( $(date +%s) - start ))
leak_check "bashunit/$BASE" "$pre_procs" "$pre_tmp" || overall=1

echo "bats exit=$bats_rc (${bats_secs}s)  bashunit exit=$bu_rc (${bu_secs}s)"
if [ "$bats_rc" -ne "$bu_rc" ] && { [ "$bats_rc" -eq 0 ] || [ "$bu_rc" -eq 0 ]; }; then
  echo "MISMATCH-EXIT: bats=$bats_rc bashunit=$bu_rc"
  overall=1
fi

python3 "$ROOT/tests/bashunit/verify_bats_bashunit.py" \
  --manifest "$MANIFEST" \
  --bats-file "$BASE.bats" \
  --bats-tap "$OUT_DIR/bats-$BASE.tap" \
  --bashunit-json "$OUT_DIR/bashunit-$BASE.json" \
  --bashunit-tap "$OUT_DIR/bashunit-$BASE.tap" || overall=1

exit $overall
