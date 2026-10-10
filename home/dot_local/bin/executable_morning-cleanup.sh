#!/usr/bin/env bash
# Daily cleanup, run by launchd (com.andrew.morning-cleanup): stale .omc
# runtime state, platform worktrees/branches fully merged into origin/main,
# Claude Code, Pi and OpenCode sessions idle past one shared retention
# threshold, and the space those OpenCode deletions free in opencode.db.
# Idempotent per calendar day via a stamp file, so RunAtLoad + wake coalescing
# can all fire without triple-running.
set -uo pipefail

STATE_DIR="$HOME/.local/state/morning-cleanup"
STAMP="$STATE_DIR/last-run"
LOG="$STATE_DIR/cleanup.log"
TRASH="$HOME/.scratchpad"
TRASH_MAX_AGE_DAYS="${MORNING_CLEANUP_TRASH_MAX_AGE_DAYS:-2}"
SESSION_MAX_AGE_DAYS="${MORNING_CLEANUP_SESSION_MAX_AGE_DAYS:-90}"
OPENCODE_DB_RECLAIM_MB="${MORNING_CLEANUP_OPENCODE_DB_RECLAIM_MB:-1024}"
PLATFORM="$HOME/Projects/platform"
CLAUDE_PROJECTS="$HOME/.claude/projects"
PI_SESSIONS="$HOME/.pi/agent/sessions"
OPENCODE_DB="$HOME/.local/share/opencode/opencode.db"
# launchd starts this with /usr/bin:/bin:/usr/sbin:/sbin. Appended, so tools
# already on PATH win while scheduled jobs can still find installed CLIs.
PATH="$PATH:$HOME/.local/share/mise/shims:/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin"
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
oc_db_report=""

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

# 6) Give the pages freed in opencode.db back to the filesystem. SQLite reuses
# free pages but never releases them; VACUUM rewrites the file without them.
# Gated on free pages, not on file size: under the retention above the file
# settles at 90 days of live data, so a size gate would rewrite all of it daily
# to return one day's deletions. VACUUM needs an exclusive lock, so the leg
# skips a database in use. Free space must hold the backup (the whole file)
# and VACUUM's temporary copy (up to twice the file).
# The backup goes to the trash, so the purge above keeps it two days. `.backup`
# folds committed WAL frames into one self-contained file. Restore: quit every
# OpenCode client, delete opencode.db-wal and opencode.db-shm, then copy the
# backup over opencode.db.
file_bytes() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }
compact_opencode_db() {
  [[ -f "$OPENCODE_DB" ]] || return 0
  local tool
  for tool in sqlite3 lsof; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      log "skip opencode-db: $tool not found"
      return 0
    fi
  done

  # No -readonly here: a read-only connection cannot open a WAL database whose
  # -shm sidecar is gone, and Linux sqlite removes it on the last close.
  local free_bytes
  if ! free_bytes=$(sqlite3 "$OPENCODE_DB" \
    "select freelist_count * page_size from pragma_freelist_count(), pragma_page_size()" 2>>"$LOG"); then
    log "skip opencode-db: database read failed"
    return 0
  fi
  ((free_bytes >= OPENCODE_DB_RECLAIM_MB * 1048576)) || return 0
  if [[ -n "$(lsof -t "$OPENCODE_DB" 2>/dev/null)" ]]; then
    log "skip opencode-db: database in use"
    return 0
  fi

  local before after avail_kb backup
  before=$(file_bytes "$OPENCODE_DB")
  avail_kb=$(df -Pk "$(dirname "$OPENCODE_DB")" | awk 'NR == 2 { print $4 }')
  if ((avail_kb * 1024 < 3 * before)); then
    log "skip opencode-db: needs $((3 * before / 1048576)) MB free, has $((avail_kb / 1024)) MB"
    return 0
  fi
  backup="$TRASH/opencode-db-backup-$(date +%s)-$RANDOM.db"
  if ! sqlite3 "$OPENCODE_DB" ".backup '$backup'" 2>>"$LOG"; then
    log "skip opencode-db: backup failed"
    rm -f "$backup"
    return 0
  fi
  # In WAL mode the rewritten pages land in the WAL; the checkpoint moves them
  # into the file and truncates it.
  if ! sqlite3 "$OPENCODE_DB" "vacuum; pragma wal_checkpoint(truncate);" >/dev/null 2>>"$LOG"; then
    log "opencode-db vacuum failed, backup kept: $backup"
    return 0
  fi
  after=$(file_bytes "$OPENCODE_DB")
  oc_db_report="opencode-db: $((before / 1048576)) MB -> $((after / 1048576)) MB"
  log "$oc_db_report (backup: $backup)"
}
compact_opencode_db

# 7) Docker keeps its own age and in-use rules. Resolve one local endpoint
# once, then pass it explicitly so context changes cannot split the stage.
docker_cache_report=""
docker_image_report=""
docker_network_report=""
docker_success_count=0
docker_deleted=0
docker_endpoint=""
docker_cli=""
docker_cleanup() {
  local configured_host configured_context context endpoint output space count
  configured_host=${DOCKER_HOST:-}
  configured_context=${DOCKER_CONTEXT:-}

  docker_cli=$(command -v docker 2>/dev/null || true)
  if [[ -z "$docker_cli" ]]; then
    log "skip docker cleanup: Docker CLI not found"
    return 0
  fi

  if [[ -n "$configured_host" ]]; then
    endpoint=$configured_host
  elif [[ -n "$configured_context" ]]; then
    context=$configured_context
    endpoint=$(
      "$docker_cli" context inspect "$context" \
        --format '{{.Endpoints.docker.Host}}' 2>>"$LOG"
    ) || {
      log "skip docker cleanup: cannot inspect context: $context"
      return 0
    }
  else
    context=$("$docker_cli" context show 2>>"$LOG") || {
      log "skip docker cleanup: cannot determine current context"
      return 0
    }
    endpoint=$(
      "$docker_cli" context inspect "$context" \
        --format '{{.Endpoints.docker.Host}}' 2>>"$LOG"
    ) || {
      log "skip docker cleanup: cannot inspect context: $context"
      return 0
    }
  fi

  if [[ "$endpoint" != unix://* ]]; then
    log "skip docker cleanup: non-Unix endpoint: $endpoint"
    return 0
  fi
  docker_endpoint=$endpoint

  # Probe the frozen daemon before prune. Some Docker clients fail while
  # initializing prune against an unavailable Unix socket without reporting a
  # connection error, but `info` reports the unavailable daemon without changing it.
  if ! output=$(DOCKER_CONTEXT='' DOCKER_HOST='' BUILDX_BUILDER='' \
    "$docker_cli" --host "$docker_endpoint" info --format '{{.ServerVersion}}' 2>&1); then
    log "skip docker cleanup: Docker daemon unavailable: $output"
    return 0
  fi

  docker_prune_failure() {
    local label=$1 output=$2
    case "$output" in
      *[Cc]onnect*)
        log "docker cleanup unavailable (cannot connect to Docker daemon) during $label prune: $output"
        ;;
      *)
        log "docker $label prune failed: $output"
        ;;
    esac
  }

  docker_prune() {
    local resource=$1 label=$2 output space count
    case "$resource" in
      builder)
        if output=$(DOCKER_CONTEXT='' DOCKER_HOST='' BUILDX_BUILDER=default \
          "$docker_cli" --host "$docker_endpoint" builder prune \
          --all --force --filter until=336h 2>&1); then
          space=$(docker_reclaimed_space "$output")
          docker_cache_report=$space
          docker_success_count=$((docker_success_count + 1))
          docker_deleted_cache "$output" && docker_deleted=1
          log "docker cache: $space"
        else
          docker_prune_failure cache "$output"
        fi
        ;;
      image)
        if output=$(DOCKER_CONTEXT='' DOCKER_HOST='' BUILDX_BUILDER='' \
          "$docker_cli" --host "$docker_endpoint" image prune \
          --all --force --filter until=336h 2>&1); then
          space=$(docker_reclaimed_space "$output")
          docker_image_report=$space
          docker_success_count=$((docker_success_count + 1))
          docker_has_deletion_listing "$output" 'Deleted Images:' && docker_deleted=1
          log "docker images: $space"
        else
          docker_prune_failure images "$output"
        fi
        ;;
      network)
        if output=$(DOCKER_CONTEXT='' DOCKER_HOST='' BUILDX_BUILDER='' \
          "$docker_cli" --host "$docker_endpoint" network prune \
          --force --filter until=336h 2>&1); then
          count=$(docker_deleted_networks "$output")
          docker_network_report=$count
          docker_success_count=$((docker_success_count + 1))
          ((count > 0)) && docker_deleted=1
          log "docker networks: $count"
        else
          docker_prune_failure networks "$output"
        fi
        ;;
    esac
  }

  docker_reclaimed_space() {
    local value
    value=$(printf '%s\n' "$1" | awk '
      /^Total reclaimed space:[[:space:]]*/ {
        sub(/^Total reclaimed space:[[:space:]]*/, "")
        value = $0
      }
      /^Total:[[:space:]]*/ {
        sub(/^Total:[[:space:]]*/, "")
        value = $0
      }
      END { print value }
    ')
    [[ -n "$value" ]] && printf '%s\n' "$value" || printf '0B\n'
  }

  docker_has_deletion_listing() {
    local output=$1 header=$2
    printf '%s\n' "$output" | awk -v header="$header" '
      $0 == header { listing = 1; next }
      listing && NF { deleted = 1; exit }
      END { exit deleted ? 0 : 1 }
    '
  }

  docker_deleted_cache() {
    printf '%s\n' "$1" | awk '
      /^Deleted build cache objects:$/ { legacy_listing = 1; next }
      legacy_listing && NF { deleted = 1; exit }
      /^ID([[:space:]]|$)/ && /RECLAIMABLE/ && /SIZE/ { buildx_table = 1; next }
      buildx_table && /^Total:[[:space:]]*/ { exit }
      buildx_table && NF { deleted = 1; exit }
      END { exit deleted ? 0 : 1 }
    '
  }

  docker_deleted_networks() {
    printf '%s\n' "$1" | awk '
      /^Deleted Networks:$/ { listing=1; next }
      listing && NF == 0 { exit }
      listing { count++ }
      END { print count + 0 }
    '
  }

  # `docker builder prune` delegates to Buildx. Pin the default builder while
  # the explicit host keeps this command on the resolved daemon.
  docker_prune builder cache
  docker_prune image images
  docker_prune network networks
}
docker_cleanup

echo "$today" >"$STAMP"
summary="omc: $omc_count, worktrees: $wt_count, branches: $br_count, trash: $trash_count, claude sessions: $claude_count, pi sessions: $pi_count, opencode sessions: $oc_count"
[[ -n "$oc_db_report" ]] && summary+=", $oc_db_report"
if ((docker_success_count > 0)); then
  summary+=", Docker cache: ${docker_cache_report:-error}, Docker images: ${docker_image_report:-error}, Docker networks: ${docker_network_report:-error}"
fi
log "done — $summary"

if [[ ( $((omc_count + wt_count + br_count + trash_count + claude_count + pi_count + oc_count)) -gt 0 || -n "$oc_db_report" || "$docker_deleted" == 1 ) &&
  -z "${MORNING_CLEANUP_NO_NOTIFY:-}" ]] &&
  command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"$summary\" with title \"Morning cleanup\"" 2>>"$LOG" || true
fi
