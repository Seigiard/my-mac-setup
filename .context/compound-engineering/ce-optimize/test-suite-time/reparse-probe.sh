#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
D=logs/20260828T055940
for f in docker_suite host_suite; do
  echo "== $f =="
  sed -e $'s/\x1b\\[[0-9;]*m//g' "$D/$f.log" | awk '
    /^ok [0-9]+ /      { tap_t++; if (/# skip/) tap_s++; next }
    /^not ok [0-9]+ /  { tap_t++; tap_f++; next }
    END { printf "tests=%d fails=%d skips=%d\n", tap_t, tap_f+0, tap_s+0 }'
done
bash extract-outcomes.sh "$D/docker_suite.log" > baseline-outcomes-docker.txt
bash extract-outcomes.sh "$D/host_suite.log" > baseline-outcomes-host.txt
wc -l baseline-outcomes-docker.txt baseline-outcomes-host.txt
