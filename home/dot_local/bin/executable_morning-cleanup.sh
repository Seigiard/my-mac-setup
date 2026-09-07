#!/usr/bin/env bash
# Daily cleanup, run by launchd (com.andrew.morning-cleanup): stale .omc
# runtime state, and platform worktrees/branches fully merged into origin/main.
# Idempotent per calendar day via a stamp file, so RunAtLoad + wake coalescing
# can all fire without triple-running.
set -uo pipefail

STATE_DIR="$HOME/.local/state/morning-cleanup"
STAMP="$STATE_DIR/last-run"
LOG="$STATE_DIR/cleanup.log"
TRASH="$HOME/.scratchpad"
TRASH_MAX_AGE_DAYS="${MORNING_CLEANUP_TRASH_MAX_AGE_DAYS:-2}"
PLATFORM="$HOME/Projects/platform"
today=$(date +%Y-%m-%d)

mkdir -p "$STATE_DIR" "$TRASH"
[[ -f "$STAMP" && "$(cat "$STAMP")" == "$today" ]] && exit 0

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

omc_count=0
wt_count=0
br_count=0
trash_count=0

# 0) Purge trash entries older than the age threshold (default 2 days; ctime
# cannot be backdated, so tests lower MORNING_CLEANUP_TRASH_MAX_AGE_DAYS
# instead of aging fixtures). ctime is keyed to the moment the entry was moved
# into the trash (rename updates it), not its original mtime, so fresh moves
# keep an undo window. A threshold of 0 purges regardless of age — find's
# day-granularity rounding would otherwise keep sub-day entries at -ctime +0.
trash_candidates() {
  if [[ "$TRASH_MAX_AGE_DAYS" == 0 ]]; then
    find "$TRASH" -mindepth 1 -maxdepth 1 2>/dev/null
  else
    find "$TRASH" -mindepth 1 -maxdepth 1 -ctime "+$TRASH_MAX_AGE_DAYS" 2>/dev/null
  fi
}
while IFS= read -r entry; do
  if rm -rf "$entry"; then
    log "purged trash: $entry"
    trash_count=$((trash_count + 1))
  fi
done < <(trash_candidates)

# 1) .omc runtime state in project checkouts. Files touched in the last 12h
# can belong to a live OMC run — leave those dirs alone.
while IFS= read -r dir; do
  if [[ -n "$(find "$dir" -type f -mmin -720 -print -quit 2>/dev/null)" ]]; then
    log "skip (recently active): $dir"
    continue
  fi
  if mv "$dir" "$TRASH/omc-$(date +%s)-$RANDOM"; then
    log "trashed: $dir"
    omc_count=$((omc_count + 1))
  fi
done < <(find "$HOME/Projects" -maxdepth 3 -type d -name .omc 2>/dev/null)

# 2+3) platform: remove worktrees and local branches fully merged into
# origin/main. Every path is double-guarded: clean status + ancestor check,
# and soft `branch -d` / `worktree remove` refuse anything git deems unsafe.
if git -C "$PLATFORM" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$PLATFORM" fetch origin main --quiet 2>>"$LOG" ||
    log "fetch failed — comparing against stale origin/main"

  while IFS= read -r wt; do
    [[ "$wt" == "$PLATFORM" ]] && continue
    branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD) || continue
    [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]] && continue
    if git -C "$PLATFORM" merge-base --is-ancestor "$branch" origin/main 2>/dev/null; then
      if git -C "$PLATFORM" worktree remove "$wt" 2>>"$LOG"; then
        log "removed worktree: $wt ($branch)"
        wt_count=$((wt_count + 1))
      fi
    fi
  done < <(git -C "$PLATFORM" worktree list --porcelain | awk '/^worktree /{print $2}')
  git -C "$PLATFORM" worktree prune 2>>"$LOG"

  while IFS= read -r br; do
    [[ "$br" == "main" ]] && continue
    git -C "$PLATFORM" merge-base --is-ancestor "$br" origin/main 2>/dev/null || continue
    if git -C "$PLATFORM" branch -d "$br" >/dev/null 2>>"$LOG"; then
      log "deleted branch: $br"
      br_count=$((br_count + 1))
    fi
  done < <(git -C "$PLATFORM" branch --format='%(refname:short)')
fi

echo "$today" >"$STAMP"
summary="omc: $omc_count, worktrees: $wt_count, branches: $br_count, trash: $trash_count"
log "done — $summary"

if [[ $((omc_count + wt_count + br_count + trash_count)) -gt 0 && -z "${MORNING_CLEANUP_NO_NOTIFY:-}" ]] &&
  command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"$summary\" with title \"Morning cleanup\"" 2>>"$LOG" || true
fi
