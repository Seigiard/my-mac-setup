#!/bin/sh
# #576 holdout driver: bench-baseline (opus + gpt-6.1-sol) and bench-terra (opus + gpt-6.1-terra) on five cases, three repetitions, under the Claude and Codex weekly caps.
B=/Users/andrew.b/.local/state/revmux-bench/576-holdout; P=/Users/andrew.b/.local/state/revmux-bench/408-pilot
HARNESS=/Users/andrew.b/Projects/my-mac-setup/scripts/run_revmux_benchmark.py; CAP=60; CODEX_CAP=60
log() { echo "$(date '+%F %T') $*" >> $B/logs/driver.log; }
for rep in 1 2 3; do
  TASKS=$B/tasks-rep$rep; mkdir -p $TASKS
  for case in mms-pr-525 ux-chain-prd-3567 homelab-feat-8 platform-prd-3672 ttrpg-pr-152; do
    for arm in baseline terra; do
      task=$case-$arm-1; [ -d "$TASKS/$task" ] && { log "skip rep$rep $task"; continue; }
      while :; do
        q=$($P/quota.sh 2>/dev/null); week=${q%% *}; five=${q##* }; codex=$($P/codex-quota.sh 2>/dev/null)
        [ -z "$week" ] && { log "quota probe failed, retry"; sleep 120; continue; }
        [ "$(printf '%s\n' "$week >= $CAP" | bc)" = 1 ] && { log "STOP: claude weekly $week% >= $CAP%"; echo cap > $B/logs/driver.done; exit 0; }
        [ -n "$codex" ] && [ "$(printf '%s\n' "$codex >= $CODEX_CAP" | bc)" = 1 ] && { log "STOP: codex weekly $codex% >= $CODEX_CAP%"; echo cap > $B/logs/driver.done; exit 0; }
        [ "$(printf '%s\n' "$five >= 85" | bc)" = 1 ] && { log "five-hour $five% high, wait"; sleep 900; continue; }
        break
      done
      log "start rep$rep $task (claude weekly $week%, five-hour $five%, codex weekly ${codex:-?}%)"
      python3 "$HARNESS" --case $B/cases/$case.json --profile bench-$arm --arm $arm --repetitions 1 --tasks-dir "$TASKS" --revmux $P/revmux-bench > $B/logs/rep$rep-$task.log 2>&1
      log "end rep$rep $task exit $?"
    done
  done
done
echo "done" > "$B/logs/driver.done"; log "all rounds attempted"
