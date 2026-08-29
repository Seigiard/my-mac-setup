#!/usr/bin/env bash
# Interleaved paired benchmark: bats vs bashunit over the post-apply suite.
# Runs N repetitions of (bats, bashunit) back to back under equivalent
# conditions, rejects any repetition whose runs did not exit cleanly, and
# reports raw durations plus median / MAD / CV / %change per suite mode.
#
# usage: bench-bats-vs-bashunit.sh <host-safe|full> [reps=3] [jobs=8]
# Timings from failed or leaking runs are NOT evidence; the script refuses to
# aggregate a repetition unless both halves exited 0.
set -u

MODE="${1:?usage: bench-bats-vs-bashunit.sh <host-safe|full> [reps] [jobs]}"
REPS="${2:-3}"
JOBS="${3:-8}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${OUT:-$ROOT/.context/bashunit-full-suite/bench-$MODE.csv}"

case "$MODE" in
  host-safe) FILES="smoke scripts palette platform" ;;
  full)      FILES="smoke scripts palette platform idempotent" ;;
  *) echo "unknown mode: $MODE" >&2; exit 2 ;;
esac

bats_files=""
bu_files=""
for f in $FILES; do
  bats_files="$bats_files $ROOT/tests/$f.bats"
  bu_files="$bu_files $ROOT/tests/bashunit/${f}_test.sh"
done

# The converted files are generated artifacts (gitignored); regenerate them
# the same way tests/run-post-apply.sh does before timing anything.
python3 "$ROOT/scripts/bats2bashunit.py" \
  --out-dir "$ROOT/tests/bashunit" --manifest "$ROOT/tests/bashunit/manifest.tsv" \
  "$ROOT/tests/smoke.bats" "$ROOT/tests/scripts.bats" \
  "$ROOT/tests/palette.bats" "$ROOT/tests/platform.bats" >/dev/null
python3 "$ROOT/scripts/bats2bashunit.py" --serial \
  --out-dir "$ROOT/tests/bashunit" --manifest "$ROOT/tests/bashunit/manifest.tsv" \
  --append-manifest "$ROOT/tests/idempotent.bats" >/dev/null

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

# The suite leaks orphaned herdr-child watchers (pre-existing behavior, both
# runners); each polls at 10ms, so back-to-back repetitions accumulate load
# and poison the timings. Reap dead-launcher orphans between halves so every
# half starts from the same floor.
reap_orphans() {
  pgrep -f "herdr-child __watcher" 2>/dev/null | while read -r pid; do
    lp=$(ps -o command= -p "$pid" 2>/dev/null | sed -n 's/.*--launcher-pid \([0-9]*\).*/\1/p')
    [ -n "$lp" ] || continue
    kill -0 "$lp" 2>/dev/null || kill "$pid" 2>/dev/null
  done
  sleep 1
}

echo "runner,rep,ms,exit" > "$OUT"
rep=1
while [ "$rep" -le "$REPS" ]; do
  # bats half: production shape.
  s=$(now_ms)
  # shellcheck disable=SC2086
  bats --jobs "$JOBS" --no-parallelize-across-files $bats_files >/dev/null 2>&1
  rc=$?
  e=$(now_ms)
  echo "bats,$rep,$((e - s)),$rc" >> "$OUT"
  reap_orphans

  # bashunit half: one invocation per file, sequential across files,
  # -j within a file (mirrors --no-parallelize-across-files).
  s=$(now_ms)
  burc=0
  for f in $bu_files; do
    "$ROOT/tests/lib/bashunit" -j "$JOBS" --no-output "$f"
    frc=$?
    [ "$frc" -eq 0 ] || burc=$frc
  done
  e=$(now_ms)
  echo "bashunit,$rep,$((e - s)),$burc" >> "$OUT"
  reap_orphans

  rep=$((rep + 1))
done

python3 - "$OUT" <<'EOF'
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
bad = [r for r in rows if r["exit"] != "0"]
if bad:
    print("INVALID: repetitions with non-zero exits present; timings are not evidence:")
    for r in bad:
        print("  ", r)
    sys.exit(1)
out = {}
for runner in ("bats", "bashunit"):
    xs = [int(r["ms"]) for r in rows if r["runner"] == runner]
    med = statistics.median(xs)
    mad = statistics.median([abs(x - med) for x in xs])
    mean = statistics.mean(xs)
    cv = (statistics.pstdev(xs) / mean * 100) if mean else 0.0
    out[runner] = (xs, med, mad, cv)
    print(f"{runner}: raw={xs} median={med:.0f}ms MAD={mad:.0f}ms CV={cv:.1f}%")
b, u = out["bats"][1], out["bashunit"][1]
change = (u - b) / b * 100
noise = max(out["bats"][3], out["bashunit"][3])
print(f"%change (bashunit vs bats, median): {change:+.1f}%  (worst CV {noise:.1f}%)")
verdict = "improvement beyond noise" if (-change) > 2 * noise and change < 0 else \
          ("regression" if change > 0 else "within noise")
print(f"assessment: {verdict}")
EOF
