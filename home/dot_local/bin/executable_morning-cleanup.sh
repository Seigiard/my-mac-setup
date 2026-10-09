#!/usr/bin/env bash
# Daily cleanup, run by launchd (com.andrew.morning-cleanup): stale .omc
# runtime state, platform worktrees/branches fully merged into origin/main,
# and Claude Code, Pi and OpenCode sessions idle past one shared retention
# threshold.
# Idempotent per calendar day via a stamp file, so RunAtLoad + wake coalescing
# can all fire without triple-running.
set -uo pipefail

STATE_DIR="$HOME/.local/state/morning-cleanup"
STAMP="$STATE_DIR/last-run"
LOG="$STATE_DIR/cleanup.log"
TRASH="$HOME/.scratchpad"
TRASH_MAX_AGE_DAYS="${MORNING_CLEANUP_TRASH_MAX_AGE_DAYS:-2}"
SESSION_MAX_AGE_DAYS="${MORNING_CLEANUP_SESSION_MAX_AGE_DAYS:-90}"
PLATFORM="$HOME/Projects/platform"
CLAUDE_PROJECTS="$HOME/.claude/projects"
PI_SESSIONS="$HOME/.pi/agent/sessions"
OPENCODE_DB="$HOME/.local/share/opencode/opencode.db"
# launchd starts this with /usr/bin:/bin:/usr/sbin:/sbin; opencode comes from
# mise. Appended, so an opencode already on PATH wins.
PATH="$PATH:$HOME/.local/share/mise/shims"
today=$(date +%Y-%m-%d)

mkdir -p "$STATE_DIR" "$TRASH"
[[ -f "$STAMP" && "$(cat "$STAMP")" == "$today" ]] && exit 0

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

omc_count=0
wt_count=0
br_count=0
trash_count=0
claude_count=0
pi_count=0
oc_count=0

# 0) Purge trash entries older than the age threshold (default 2 days). ctime
# is keyed to the moment the entry was moved into the trash (rename updates
# it), not its original mtime, so fresh moves keep an undo window. ctime cannot
# be backdated, so the aged-removal half of this contract has no local test;
# morning_cleanup_test.sh 002 owns the keep half.
trash_candidates() {
  find "$TRASH" -mindepth 1 -maxdepth 1 -ctime "+$TRASH_MAX_AGE_DAYS" 2>/dev/null
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

# 4) Claude Code and Pi sessions: one .jsonl per session, appended on every
# turn, so mtime is the last activity and a resumed old session stays. Both
# keep subagent runs and tool output in a same-named sibling directory, which
# goes with the file. Moved to the trash, so the purge above leaves a two-day undo window
# (the rename resets ctime). Claude Code's own cleanupPeriodDays sits above this
# threshold as a backstop, so this script decides first.
trash_session() {
  local file=$1 label=$2 stamp
  stamp="$label-session-$(date +%s)-$RANDOM"
  mv "$file" "$TRASH/$stamp-$(basename "$file")" || return 1
  if [[ -d "${file%.jsonl}" ]]; then
    mv "${file%.jsonl}" "$TRASH/$stamp-$(basename "${file%.jsonl}")" ||
      log "left behind: ${file%.jsonl}"
  fi
  log "trashed $label session: $file"
}
aged_sessions() {
  find "$1" -mindepth "$2" -maxdepth "$2" -type f -name '*.jsonl' \
    -mtime "+$SESSION_MAX_AGE_DAYS" 2>/dev/null
}
while IFS= read -r file; do
  trash_session "$file" claude && claude_count=$((claude_count + 1))
done < <(aged_sessions "$CLAUDE_PROJECTS" 2)
while IFS= read -r file; do
  trash_session "$file" pi && pi_count=$((pi_count + 1))
done < <(aged_sessions "$PI_SESSIONS" 2)

# 5) OpenCode sessions, deleted only through its CLI: direct writes to
# opencode.db are barred (#255), because event replay needs contiguous sequence
# numbers. The database is read only to find root sessions idle past the
# threshold, since `opencode session list` sees one project and at most 100
# sessions. Deleting a root also deletes its subagent sessions. Skipped while
# any process holds the database open: a live client keeps sessions in memory.
opencode_sessions() {
  [[ -f "$OPENCODE_DB" ]] || return 0
  local tool
  for tool in opencode sqlite3 lsof; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      log "skip opencode sessions: $tool not found"
      return 0
    fi
  done
  if [[ -n "$(lsof -t "$OPENCODE_DB" 2>/dev/null)" ]]; then
    log "skip opencode sessions: database in use"
    return 0
  fi

  local cutoff_ms=$((($(date +%s) - SESSION_MAX_AGE_DAYS * 86400) * 1000))
  local ids id
  if ! ids=$(sqlite3 -readonly "$OPENCODE_DB" \
    "select id from session where parent_id is null and time_updated < $cutoff_ms" 2>>"$LOG"); then
    log "skip opencode sessions: database read failed"
    return 0
  fi
  while IFS= read -r id; do
    # The id is interpolated into SQL below.
    [[ "$id" =~ ^ses_[A-Za-z0-9]+$ ]] || continue
    opencode session delete --pure "$id" >/dev/null 2>>"$LOG" || {
      log "opencode session delete failed: $id"
      continue
    }
    # Session.remove logs and swallows its own errors, so exit 0 is not proof.
    if [[ -z "$(sqlite3 -readonly "$OPENCODE_DB" "select 1 from session where id = '$id'" 2>>"$LOG")" ]]; then
      log "deleted opencode session: $id"
      oc_count=$((oc_count + 1))
    else
      log "opencode session still present after delete: $id"
    fi
  done <<<"$ids"
}
opencode_sessions

echo "$today" >"$STAMP"
summary="omc: $omc_count, worktrees: $wt_count, branches: $br_count, trash: $trash_count, claude sessions: $claude_count, pi sessions: $pi_count, opencode sessions: $oc_count"
log "done — $summary"

if [[ $((omc_count + wt_count + br_count + trash_count + claude_count + pi_count + oc_count)) -gt 0 && -z "${MORNING_CLEANUP_NO_NOTIFY:-}" ]] &&
  command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"$summary\" with title \"Morning cleanup\"" 2>>"$LOG" || true
fi
