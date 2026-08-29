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

# Daemon/process patterns this suite is known to spawn. Beyond the named
# daemons this covers the anonymous spawn classes the cleanup review found
# unmonitored: bare sleep timers/fake lock owners, bun test trees,
# `python3 -` heredoc drivers, and stubs living under hts.XXXXXX /
# palette.XXXXXX work dirs. The gate is directional (bashunit-only fails),
# so symmetric ambient matches cost nothing.
LEAK_PATTERNS='htspwn|herdr|sweep-daemon|chezmoi-test|/hts\.|/palette\.|sleep [0-9]|bun test|python3 -$'

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
  # Also watch the classes teardown regressions would shed (cleanup review
  # H2): hts.XXXXXX / palette.XXXXXX work dirs, bare mktemp tmp.XXXXXX stub
  # dirs, and the chezmoi test config.
  ls -d /tmp/htspwn* /tmp/bats-compat-run.* /tmp/bats-run-* \
    /tmp/hts.* /tmp/palette.* /tmp/tmp.* /tmp/chezmoi-test.yaml \
    "${TMPDIR:-/tmp}"/bats-compat-run.* "${TMPDIR:-/tmp}"/bats-run-* \
    "${TMPDIR:-/tmp}"/hts.* "${TMPDIR:-/tmp}"/palette.* \
    "${TMPDIR:-/tmp}"/tmp.* \
    2>/dev/null | sort -u || true
}

# Normalize a leak line to its CLASS: strip pid, hex generations, tmp names,
# and numeric ids so the same kind of leak on both sides compares equal.
# Count-aware (cleanup review H3): N instances of a class emit "class (xN)",
# so a side leaking MORE of the same class no longer compares equal to a
# side leaking one.
normalize_leaks() {
  sed -e 's/^[0-9][0-9]* //' \
      -e "s|^${TMPDIR:-/tmp}/*|TMP/|" \
      -e 's|^/tmp/|TMP/|' \
      -e 's|^/private/tmp/|TMP/|' \
      -e 's/[0-9a-f]\{32\}/HASH/g' \
      -e 's/tmp\.[A-Za-z0-9]\{6,\}/tmp.X/g' \
      -e 's/hts\.[A-Za-z0-9]\{6,\}/hts.X/g' \
      -e 's/palette\.[A-Za-z0-9]\{6,\}/palette.X/g' \
      -e 's/bats-compat-run\.[A-Za-z0-9]\{6,\}/bats-compat-run.X/g' \
      -e 's/bats-run-[A-Za-z0-9]\{6,\}/bats-run-X/g' \
      -e 's/--launcher-pid [0-9]*/--launcher-pid N/' \
      -e 's/[0-9][0-9]*/N/g' \
    | sort | uniq -c \
    | sed -e 's/^ *\([0-9][0-9]*\) \(.*\)$/\2 (x\1)/'
}

# Strip the (xN) count suffix: the directional gate compares CLASSES; counts
# stay visible in the reported lines (cleanup review H3: log counts, gate on
# class presence — count deltas of a class both sides shed are stochastic).
strip_counts() {
  sed -e 's/ (x[0-9][0-9]*)$//'
}

# new_entries <pre> <post> — lines in post but not in pre.
new_entries() {
  printf '%s\n' "$2" | grep -vxF -f <(printf '%s\n' "$1") || true
}

# collect_leaks <pre_procs> <pre_tmp> — echoes normalized new process/path
# entries after a 2s settle-retry (teardown TERM needs a moment).
collect_leaks() {
  local pre_procs="$1" pre_tmp="$2" post_procs post_tmp tries=0
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
bats_leaks="$(collect_leaks "$pre_procs" "$pre_tmp")"
reap_orphan_watchers

pre_procs="$(snapshot_procs)"; pre_tmp="$(snapshot_tmp)"
start=$(date +%s)
"$ROOT/tests/lib/bashunit" -j "$JOBS" --output tap \
  --report-json "$OUT_DIR/bashunit-$BASE.json" \
  "$BU_PATH" > "$OUT_DIR/bashunit-$BASE.tap" 2>&1
bu_rc=$?
bu_secs=$(( $(date +%s) - start ))
bu_leaks="$(collect_leaks "$pre_procs" "$pre_tmp")"
reap_orphan_watchers

# Cleanup gate, directional: bashunit must not leak any class the bats oracle
# does not also produce. Recorded oracle-side evidence for the allowlisted
# classes (status.md): herdr-child watchers observed both-sides symmetric and
# as ambient debris of aborted bats runs (launcher-death mechanism
# understood); sweep-daemon observed once, bats-only. The allowlist is
# rate-blind by design — counts are still visible in the (xN) suffix of
# LEAK-INFO lines, and per-run frequency is aggregated in the benchmark reps.
# TMP/hts.X: recorded oracle-side evidence (status.md 2026-08-29) — a herdr
# engine process surviving hts_teardown recreates $HTS_STATE/sockets after
# rm -rf; 2490 historical bats-shed instances under $TMPDIR plus 4 shed by
# the bats half of the same run that first flagged the class.
KNOWN_STOCHASTIC='herdr-child __watcher|herdr-task-sync --sweep-daemon|^path: TMP/hts\.X$'
bu_classes="$(printf '%s\n' "$bu_leaks" | strip_counts)"
bats_classes="$(printf '%s\n' "$bats_leaks" | strip_counts)"
bu_only="$(printf '%s\n' "$bu_classes" | grep -vxF -f <(printf '%s\n' "$bats_classes") | grep . || true)"
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
  echo "LEAK-INFO (oracle-stochastic or symmetric; not gating; counts per side):"
  [ -z "$bats_leaks" ] || printf '%s\n' "$bats_leaks" | sed 's/^/bats: /'
  [ -z "$bu_leaks" ] || printf '%s\n' "$bu_leaks" | sed 's/^/bashunit: /'
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
