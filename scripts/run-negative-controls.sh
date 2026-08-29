#!/usr/bin/env bash
# Proves the per-scenario verifier and the compare harness actually reject the
# failure classes they claim to catch. Each control mutates a converted
# fixture (never the .bats oracle) and asserts the expected rejection marker.
#
# Controls:
#   0 positive     honest conversion (incl. a deliberately failing scenario)
#                  reaches per-scenario parity
#   1 missing      converted file lost a scenario        -> MISSING-IN-BASHUNIT
#   2 dup-mapping  manifest maps one function twice      -> duplicate mapping
#   3 wrong-skip   converted test skips where bats passes-> MISMATCH-STATUS
#   4 wrong-status shim weakened: failing test passes    -> MISMATCH-STATUS
#   5 skip-reason  skip reason text drifted              -> MISMATCH-SKIP-REASON
#   6 leak         converted side leaks process + path   -> LEAK-PROCESS, LEAK-PATH
#   7 allowlist    bashunit-only leak of an allowlisted class (herdr-child
#                  __watcher) passes the gate by design -> rc 0 + LEAK-INFO.
#                  This control documents the accepted allowlist hole rather
#                  than detection coverage: a deterministic watcher leak is
#                  excused, visible only via the LEAK-INFO (xN) counts.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/bashunit/negative-controls"
WORK="${TMPDIR:-/tmp}/bashunit-negctl.$$"
mkdir -p "$WORK"
trap 'command rm -rf "$WORK"' EXIT

failures=0

expect() { # name expected_rc marker logfile actual_rc
  local name="$1" want_rc="$2" marker="$3" log="$4" got_rc="$5"
  local ok=1
  if [ "$want_rc" = 0 ]; then
    [ "$got_rc" -eq 0 ] || ok=0
  else
    [ "$got_rc" -ne 0 ] || ok=0
  fi
  if [ -n "$marker" ] && ! grep -q "$marker" "$log"; then
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    echo "NEGCTL PASS: $name"
  else
    echo "NEGCTL FAIL: $name (rc=$got_rc, wanted rc${want_rc:+=}$want_rc, marker '$marker')"
    sed -n '1,15p' "$log" | sed 's/^/    /'
    failures=$((failures + 1))
  fi
}

convert() { # dest-dir [--serial]
  python3 "$ROOT/scripts/bats2bashunit.py" --out-dir "$1" \
    --manifest "$1/manifest.tsv" "$FIX/control.bats" >/dev/null
  # Converted fixtures live outside tests/bashunit; point them at the shim
  # and the original fixture explicitly.
  python3 - "$1/control_test.sh" "$ROOT" "$FIX" <<'PYEOF'
import sys
p, root, fix = sys.argv[1:4]
s = open(p).read()
s = s.replace('$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash', root + '/tests/bashunit/test-dsl.bash')
s = s.replace('$(dirname "${BASH_SOURCE[0]}")/../control.bats', fix + '/control.bats')
open(p, 'w').write(s)
PYEOF
}

run_compare() { # dir logfile
  ( cd "$ROOT" && \
    OUT_DIR="$1" BATS_PATH="$FIX/control.bats" BU_PATH="$1/control_test.sh" \
    MANIFEST="$1/manifest.tsv" bash tests/bashunit/compare-suite-file.sh control 4 ) \
    > "$2" 2>&1
}

# --- 0 positive control ------------------------------------------------------
d="$WORK/positive"; mkdir -p "$d"; convert "$d"
run_compare "$d" "$d/log"; rc=$?
expect "positive: honest conversion reaches parity" 0 "RESULT: OK" "$d/log" "$rc"

# --- 1 missing scenario ------------------------------------------------------
d="$WORK/missing"; mkdir -p "$d"; convert "$d"
python3 - "$d/control_test.sh" <<'EOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'function test_control_004_control_second_passing_scenario\(\) \{.*?\n\}\n',
           '', s, flags=re.S)
open(p, 'w').write(s)
EOF
run_compare "$d" "$d/log"; rc=$?
expect "missing scenario is rejected" 1 "MISSING-IN-BASHUNIT" "$d/log" "$rc"

# --- 2 duplicated mapping ----------------------------------------------------
d="$WORK/dup"; mkdir -p "$d"; convert "$d"
tail -1 "$d/manifest.tsv" >> "$d/manifest.tsv"
run_compare "$d" "$d/log"; rc=$?
expect "duplicated mapping is rejected" 1 "DUP" "$d/log" "$rc"

# --- 3 incorrect skip --------------------------------------------------------
d="$WORK/wrongskip"; mkdir -p "$d"; convert "$d"
python3 - "$d/control_test.sh" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
marker = "_bats_test_init 4 'control second passing scenario'"
s = s.replace(marker, marker + '\n  skip "spurious skip"')
open(p, 'w').write(s)
EOF
run_compare "$d" "$d/log"; rc=$?
expect "incorrect skip is rejected" 1 "MISMATCH-STATUS" "$d/log" "$rc"

# --- 4 wrong status (weakened assertion flips fail->pass) --------------------
d="$WORK/wrongstatus"; mkdir -p "$d"; convert "$d"
python3 - "$d/control_test.sh" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('assert_output "expected-but-absent"', 'assert_output "actual-output"')
open(p, 'w').write(s)
EOF
run_compare "$d" "$d/log"; rc=$?
expect "wrong status (fail->pass) is rejected" 1 "MISMATCH-STATUS" "$d/log" "$rc"

# --- 5 skip reason drift -----------------------------------------------------
d="$WORK/skipreason"; mkdir -p "$d"; convert "$d"
python3 - "$d/control_test.sh" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('skip "control skip reason"', 'skip "different reason"')
open(p, 'w').write(s)
EOF
run_compare "$d" "$d/log"; rc=$?
expect "skip reason drift is rejected" 1 "MISMATCH-SKIP-REASON" "$d/log" "$rc"

# --- 6 leaked process and path -----------------------------------------------
d="$WORK/leak"; mkdir -p "$d"
python3 "$ROOT/scripts/bats2bashunit.py" --out-dir "$d" \
  --manifest "$d/manifest.tsv" "$FIX/leak.bats" >/dev/null
python3 - "$d/leak_test.sh" "$ROOT" "$FIX" <<'PYEOF'
import sys
p, root, fix = sys.argv[1:4]
s = open(p).read()
s = s.replace('$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash', root + '/tests/bashunit/test-dsl.bash')
s = s.replace('$(dirname "${BASH_SOURCE[0]}")/../leak.bats', fix + '/leak.bats')
open(p, 'w').write(s)
PYEOF
python3 - "$d/leak_test.sh" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
marker = "run echo clean"
inject = (
  # Double-fork so bashunit's runner cannot wait on the daemon; fds closed so
  # nothing holds the capture open. PID via pgrep at cleanup time.
  '( bash -c "exec -a htspwn-negctl-sleep sleep 45" </dev/null >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- & )\n'
  '  : > /tmp/htspwn-negctl-leak\n'
  '  ' + marker)
s = s.replace(marker, inject)
open(p, 'w').write(s)
EOF
( cd "$ROOT" && \
  OUT_DIR="$d" BATS_PATH="$FIX/leak.bats" BU_PATH="$d/leak_test.sh" \
  MANIFEST="$d/manifest.tsv" bash tests/bashunit/compare-suite-file.sh leak 4 ) \
  > "$d/log" 2>&1
rc=$?
grep -q "LEAK-PROCESS" "$d/log" && grep -q "LEAK-PATH" "$d/log" && [ $rc -ne 0 ] \
  && echo "NEGCTL PASS: leaked process and path are rejected" \
  || { echo "NEGCTL FAIL: leak control"; sed -n '1,15p' "$d/log" | sed 's/^/    /'; failures=$((failures+1)); }
# Clean the deliberate leak.
pkill -f htspwn-negctl-sleep 2>/dev/null
command rm -f /tmp/htspwn-negctl-leak

# --- 7 allowlist blindness (expected PASS: documents the accepted hole) ------
d="$WORK/allowlist"; mkdir -p "$d"
python3 "$ROOT/scripts/bats2bashunit.py" --out-dir "$d" \
  --manifest "$d/manifest.tsv" "$FIX/leak.bats" >/dev/null
python3 - "$d/leak_test.sh" "$ROOT" "$FIX" <<'PYEOF'
import sys
p, root, fix = sys.argv[1:4]
s = open(p).read()
s = s.replace('$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash', root + '/tests/bashunit/test-dsl.bash')
s = s.replace('$(dirname "${BASH_SOURCE[0]}")/../leak.bats', fix + '/leak.bats')
open(p, 'w').write(s)
PYEOF
python3 - "$d/leak_test.sh" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
marker = "run echo clean"
inject = (
  # Same double-fork shape as control 6, but the argv matches the
  # KNOWN_STOCHASTIC watcher class, so the directional gate must NOT fail.
  '( bash -c "exec -a \\"herdr-child __watcher --launcher-pid 99999\\" sleep 45" </dev/null >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- & )\n'
  '  ' + marker)
s = s.replace(marker, inject)
open(p, 'w').write(s)
EOF
( cd "$ROOT" && \
  OUT_DIR="$d" BATS_PATH="$FIX/leak.bats" BU_PATH="$d/leak_test.sh" \
  MANIFEST="$d/manifest.tsv" bash tests/bashunit/compare-suite-file.sh leak 4 ) \
  > "$d/log" 2>&1
rc=$?
grep -q "LEAK-INFO" "$d/log" && [ $rc -eq 0 ] \
  && echo "NEGCTL PASS: allowlisted watcher leak is excused (documented hole; LEAK-INFO only)" \
  || { echo "NEGCTL FAIL: allowlist-blindness control"; sed -n '1,15p' "$d/log" | sed 's/^/    /'; failures=$((failures+1)); }
pkill -f "herdr-child __watcher --launcher-pid 99999" 2>/dev/null

if [ "$failures" -eq 0 ]; then
  echo "ALL NEGATIVE CONTROLS PASS"
  exit 0
fi
echo "$failures NEGATIVE CONTROL(S) FAILED"
exit 1
