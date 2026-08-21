set -e
SUITE="tests/smoke.bats tests/scripts.bats tests/palette.bats tests/platform.bats tests/idempotent.bats"
echo "=== nproc=$(nproc) flock=$(command -v flock || echo NONE) bats=$(bats --version) ==="
(cd /home/testuser/dotfiles && cp -r . /home/testuser/.local/share/chezmoi/)
chezmoi init --source=/home/testuser/.local/share/chezmoi \
  --promptString name="Test User" --promptString email="test@example.com"
bats tests/templates.bats > /tmp/tmpl.log 2>&1 || { tail -30 /tmp/tmpl.log; exit 1; }
echo "=== applying once ==="
chezmoi apply --source=/home/testuser/.local/share/chezmoi > /tmp/apply.log 2>&1 \
  || { tail -40 /tmp/apply.log; exit 1; }
echo "=== apply done ==="

: > /tmp/results.txt
time_run() {
  label="$1"; shift
  start=$(date +%s)
  "$@" > "/tmp/out-$label.txt" 2>&1 && rc=0 || rc=$?
  end=$(date +%s)
  notok=$(grep -c '^not ok' "/tmp/out-$label.txt" || true)
  echo "RESULT|$label|$((end-start))|rc=$rc|notok=$notok" | tee -a /tmp/results.txt
  if [ "$rc" -ne 0 ]; then
    echo "----- FAILURE BLOCK ($label) -----"
    grep -A 18 '^not ok' "/tmp/out-$label.txt" | head -120
    echo "----- END FAILURE BLOCK -----"
  fi
}

# Curve, one pass each.
time_run sequential bats $SUITE
time_run jobs4  bats --jobs 4  --no-parallelize-across-files $SUITE
time_run jobs8  bats --jobs 8  --no-parallelize-across-files $SUITE
time_run jobs12 bats --jobs 12 --no-parallelize-across-files $SUITE

# Pick the fastest parallel count by measurement, not by eye.
BEST=$(awk -F'|' '$2 ~ /^jobs/ { t=$3+0; sub(/^jobs/,"",$2); if (best=="" || t<bt) { bt=t; best=$2 } } END { print best }' /tmp/results.txt)
echo "=== BEST_JOBS=$BEST ==="

i=1
while [ "$i" -le 10 ]; do
  time_run "stability-$i" bats --jobs "$BEST" --no-parallelize-across-files $SUITE
  i=$((i+1))
done

echo "===== CONTAINER RESULTS ====="
cat /tmp/results.txt
echo "===== BEST_JOBS=$BEST ====="
echo CONTAINER_RUN_COMPLETE
