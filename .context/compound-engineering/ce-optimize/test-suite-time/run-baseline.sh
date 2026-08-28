#!/usr/bin/env bash
# Run N sequential measurement repetitions, writing <prefix>-run-<i>.json.
# Usage: run-baseline.sh <prefix> <count>
set -euo pipefail
cd "$(dirname "$0")"
prefix="${1:?prefix}"; count="${2:?count}"
for i in $(seq 1 "$count"); do
  echo "=== $prefix run $i/$count: $(date) ==="
  bash measure-suite.sh </dev/null > "$prefix-run-$i.json" 2> "$prefix-run-$i.stderr.log"
  echo "exit: $?"
  grep -E 'wall_seconds|suite_passed|count' "$prefix-run-$i.json"
done
echo "=== all $count runs done: $(date) ==="
