#!/usr/bin/env bash
# Extract a canonical outcome set from a suite log for A/B parity checks:
# every skipped test with its reason, every failure, sorted for stable diffs.
# Usage: extract-outcomes.sh <logfile>
set -euo pipefail
sed -e $'s/\x1b\\[[0-9;]*m//g' "$1" | awk '
  /^ok [0-9]+ .*# skip/ { line=$0; sub(/^ok [0-9]+ /,"",line); print "SKIP: " line; next }
  /^not ok [0-9]+ /     { line=$0; sub(/^not ok [0-9]+ /,"",line); print "FAIL: " line; next }
  # pretty-format fallbacks
  /^ *- .*\(skipped/    { print "SKIP: " $0; next }
  /^ *✗ /               { print "FAIL: " $0; next }
' | sort
