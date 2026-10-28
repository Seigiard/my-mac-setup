#!/bin/sh
# #408 pilot driver: one repetition of every (case, arm) in case-major order, under the Claude weekly cap.
B=/Users/andrew.b/.local/state/revmux-bench/408-pilot
HARNESS=/Users/andrew.b/Projects/my-mac-setup/scripts/run_revmux_benchmark.py
CAP=35
TASKS=${TASKS:-$B/tasks}
log() { echo "$(date '+%F %T') $*" >> $B/logs/driver.log; }
for case in issue-509 prd-3488 r249-2; do
  for arm in baseline sonnet terra; do
    task=$case-$arm-1
    if [ -d "$TASKS/$task" ]; then log "skip $task (exists)"; continue; fi
    while :; do
      q=$($B/quota.sh 2>/dev/null); week=${q%% *}; five=${q##* }
      if [ -z "$week" ]; then log "quota probe failed, retry in 120s"; sleep 120; continue; fi
      if [ "$(printf '%s\n' "$week >= $CAP" | bc)" = 1 ]; then log "STOP: claude weekly $week% >= $CAP% before $task"; echo "cap" > $B/logs/driver.done; exit 0; fi
      if [ "$(printf '%s\n' "$five >= 85" | bc)" = 1 ]; then log "five-hour $five% high, wait 900s before $task"; sleep 900; continue; fi
      break
    done
    log "start $task (claude weekly $week%, five-hour $five%)"
    python3 "$HARNESS" --case $B/cases/$case.json --profile bench-$arm --arm $arm --repetitions 1 --tasks-dir "$TASKS" --revmux $B/revmux-bench > $B/logs/$task.log 2>&1
    log "end $task exit $? (claude weekly $($B/quota.sh 2>/dev/null | cut -d' ' -f1)%)"
  done
done
echo "done" > $B/logs/driver.done; log "all rounds attempted"
