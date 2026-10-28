#!/bin/sh
# #249 baseline driver: the lean profile on each bad and repaired case, one repetition per pass, under the Claude weekly cap.
B=/Users/andrew.b/.local/state/revmux-bench/249-baseline; P=/Users/andrew.b/.local/state/revmux-bench/408-pilot
HARNESS=/Users/andrew.b/Projects/my-mac-setup/scripts/run_revmux_benchmark.py; CAP=35
log() { echo "$(date '+%F %T') $*" >> $B/logs/driver.log; }
for rep in 1 2 3; do
  TASKS=$B/tasks-rep$rep; mkdir -p $TASKS
  for case in t249-bad-2 t249-fix-2 t249-bad-4 t249-fix-4 t249-bad-3 t249-fix-3; do
    task=$case-lean-1; [ -d "$TASKS/$task" ] && { log "skip rep$rep $task"; continue; }
    while :; do
      q=$($P/quota.sh 2>/dev/null); week=${q%% *}; five=${q##* }
      [ -z "$week" ] && { log "quota probe failed, retry"; sleep 120; continue; }
      [ "$(printf '%s\n' "$week >= $CAP" | bc)" = 1 ] && { log "STOP: claude weekly $week% >= $CAP%"; echo cap > $B/logs/driver.done; exit 0; }
      [ "$(printf '%s\n' "$five >= 85" | bc)" = 1 ] && { log "five-hour $five% high, wait"; sleep 900; continue; }
      break
    done
    log "start rep$rep $task (claude weekly $week%, five-hour $five%)"
    python3 "$HARNESS" --case $B/cases/$case.json --profile lean --arm lean --repetitions 1 --tasks-dir "$TASKS" --revmux $P/revmux-bench > $B/logs/rep$rep-$task.log 2>&1
    log "end rep$rep $task exit $?"
  done
done
echo "done" > "$B/logs/driver.done"; log "all rounds attempted"
