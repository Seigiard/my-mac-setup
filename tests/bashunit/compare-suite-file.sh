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
  # macOS pgrep has no -E; its patterns are ERE already. Exclude ambient
  # activity that is not test debris: the interactive herdr session, ALL
  # deployed ~/.local/bin/herdr-task-sync workers (live-session hooks), and
  # this pipeline itself.
  # Linux procps: -l lists only the program name; -a lists the full command
  # line (needed for classification). macOS -lf already prints full args, and
  # BSD -a means "include ancestors", so branch on OS rather than probing.
  if [ "$(uname -s)" = Darwin ]; then
    pgrep -lf "$LEAK_PATTERNS" 2>/dev/null
  else
    pgrep -af "$LEAK_PATTERNS" 2>/dev/null
  fi \
    | grep -v -e "compare-suite-file" -e "/usr/bin/login" -e "exec -l /bin/zsh" \
    | grep -v -e '^[0-9][0-9]* h[e]rdr$' -e 'p[g]rep' -e 'g[r]ep -v' \
    | grep -v -e '\.local/bin/h[e]rdr-task-sync' \
    || true
}
snapshot_tmp() {
  ls -d /tmp/htspwn* /tmp/bats-compat-run.* /tmp/bats-run-* \
    "${TMPDIR:-/tmp}"/bats-compat-run.* "${TMPDIR:-/tmp}"/bats-run-* \
    2>/dev/null | sort -u || true
}

# Normalize a leak line to its CLASS: strip pid, hex generations, tmp names,
# and numeric ids so the same kind of leak on both sides compares equal.
normalize_leaks() {
  sed -e 's/^[0-9][0-9]* //' \
      -e 's/[0-9a-f]\{32\}/HASH/g' \
      -e 's/tmp\.[A-Za-z0-9]\{6,\}/tmp.X/g' \
      -e 's/--launcher-pid [0-9]*/--launcher-pid N/' \
      -e 's/[0-9][0-9]*/N/g' | sort -u
}

# new_entries <pre> <post> — lines in post but not in pre.
new_entries() {
  printf '%s\n' "$2" | grep -vxF -f <(printf '%s\n' "$1") || true
}

# collect_leaks <label> <pre_procs> <pre_tmp> — echoes normalized new
# process/path entries after a 2s settle-retry (teardown TERM needs a moment).
collect_leaks() {
  local label="$1" pre_procs="$2" pre_tmp="$3" post_procs post_tmp tries=0
  while :; do
    post_procs="$(snapshot_procs)"
    post_tmp="$(snapshot_tmp)"
    if [ "$post_procs" = "$pre_procs" ] && [ "$post_tmp" = "$pre_tmp" ]; then
      return 0
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 3 ] || break
    sleep 2
  done
  { new_entries "$pre_procs" "$post_procs" | normalize_leaks | sed "s/^/proc: /"
    new_entries "$pre_tmp" "$post_tmp" | normalize_leaks | sed "s/^/path: /"
  } | grep -v '^proc: $' | grep -v '^path: $' || true
}

# Reap watchers whose launcher is dead so accumulation from one half does not
# pollute the next half's baseline (documented pre-existing suite behavior).
reap_orphan_watchers() {
  pgrep -f "herdr-child __watcher" 2>/dev/null | while read -r pid; do
    lp=$(ps -o command= -p "$pid" 2>/dev/null | sed -n 's/.*--launcher-pid \([0-9]*\).*/\1/p')
    [ -n "$lp" ] || continue
    kill -0 "$lp" 2>/dev/null || kill "$pid" 2>/dev/null
  done
}

overall=0

pre_procs="$(snapshot_procs)"; pre_tmp="$(snapshot_tmp)"
start=$(date +%s)
bats --jobs "$JOBS" --no-parallelize-across-files --tap \
  "$BATS_PATH" > "$OUT_DIR/bats-$BASE.tap" 2>&1
bats_rc=$?
bats_secs=$(( $(date +%s) - start ))
bats_leaks="$(collect_leaks "bats/$BASE" "$pre_procs" "$pre_tmp")"
reap_orphan_watchers

pre_procs="$(snapshot_procs)"; pre_tmp="$(snapshot_tmp)"
start=$(date +%s)
"$ROOT/tests/lib/bashunit" -j "$JOBS" --output tap \
  --report-json "$OUT_DIR/bashunit-$BASE.json" \
  "$BU_PATH" > "$OUT_DIR/bashunit-$BASE.tap" 2>&1
bu_rc=$?
bu_secs=$(( $(date +%s) - start ))
bu_leaks="$(collect_leaks "bashunit/$BASE" "$pre_procs" "$pre_tmp")"
reap_orphan_watchers

# Cleanup gate, directional: bashunit must not leak any class the bats oracle
# does not also produce. Known-stochastic classes the ORACLE itself leaks
# nondeterministically (observed bats-only, both-sides, and bashunit-only
# across repeated runs) are reported but do not fail the gate.
KNOWN_STOCHASTIC='herdr-child __watcher|herdr-task-sync --sweep-daemon'
bu_only="$(printf '%s\n' "$bu_leaks" | grep -vxF -f <(printf '%s\n' "$bats_leaks") | grep . || true)"
bats_only="$(printf '%s\n' "$bats_leaks" | grep -vxF -f <(printf '%s\n' "$bu_leaks") | grep . || true)"
bu_only_hard="$(printf '%s\n' "$bu_only" | grep -Ev "$KNOWN_STOCHASTIC" | grep . || true)"
if [ -n "$bu_only_hard" ]; then
  echo "LEAK-PARITY-MISMATCH (bashunit-only, not a known oracle-stochastic class):"
  printf '%s\n' "$bu_only_hard"
  case "$BASE" in
    leak)
      printf '%s\n' "$bu_only_hard" | grep -q '^proc: ' && echo "LEAK-PROCESS (bashunit/$BASE)"
      printf '%s\n' "$bu_only_hard" | grep -q '^path: ' && echo "LEAK-PATH (bashunit/$BASE)" ;;
  esac
  overall=1
fi
if [ -n "$bats_leaks$bu_leaks" ] && [ -z "$bu_only_hard" ]; then
  echo "LEAK-INFO (oracle-stochastic or symmetric; not gating):"
  [ -z "$bats_only" ] || printf 'bats-only: %s\n' "$bats_only"
  [ -z "$bu_only" ] || printf 'bashunit-only: %s\n' "$bu_only"
  comm_both="$(printf '%s\n' "$bats_leaks" | grep -xF -f <(printf '%s\n' "$bu_leaks") | grep . || true)"
  [ -z "$comm_both" ] || printf 'both: %s\n' "$comm_both"
fi

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
