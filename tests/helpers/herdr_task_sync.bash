# Herdr task-sync test harness.
# Load this after helpers/common so SOURCE_ROOT and the DSL assertion helpers exist.

HTS_ENGINE="$SOURCE_ROOT/dot_local/bin/executable_herdr-task-sync"
# shellcheck disable=SC2034 # The loading Bats file reads this shared harness value.
HTS_PLUGIN_DIR="$SOURCE_ROOT/private_dot_config/herdr/plugins/herdr-pane-labels"

# Build a sandbox with a stub `herdr` that records its argv. PATH is pinned to
# the stub directory plus the system directories, so a real `pi` or `claude`
# outside them can never be reached: a missing engine is then a property of the
# test, not of the machine that runs it.
# The engine's icon table is the single source of these sequences: they are
# extracted from it rather than retyped, so a drifted table fails loudly here
# instead of quietly asserting a glyph the engine no longer emits.
hts_icon() {
  local name="$1" octal
  octal="$(sed -n "s/^ICON_${name}=.*printf '\\([^']*\\)'.*/\\1/p" "$HTS_ENGINE")"
  if [[ -z "$octal" ]]; then
    printf 'missing ICON_%s in %s\n' "$name" "$HTS_ENGINE" >&2
    return 1
  fi
  # shellcheck disable=SC2059 # The extracted octal sequence is itself the format.
  printf "$octal"
}
# shellcheck disable=SC2034 # The loading Bats file reads these shared values.
HTS_ICON_BRANCH="$(hts_icon BRANCH)"
# shellcheck disable=SC2034
HTS_ICON_WORKTREE="$(hts_icon WORKTREE)"
# shellcheck disable=SC2034
HTS_ICON_COMMIT="$(hts_icon COMMIT)"
# shellcheck disable=SC2034
HTS_ICON_FOLDER="$(hts_icon FOLDER)"
# shellcheck disable=SC2034
HTS_ICON_STALE="$(hts_icon STALE)"
# Git status symbols are the user-facing contract, so tests define them
# independently instead of inheriting whatever the engine happens to render.
# shellcheck disable=SC2034
HTS_GIT_BEHIND="$(printf '\342\207\243')"
# shellcheck disable=SC2034
HTS_GIT_AHEAD="$(printf '\342\207\241')"
# shellcheck disable=SC2034
HTS_GIT_CONFLICT='~'
# shellcheck disable=SC2034
HTS_GIT_STAGED='+'
# shellcheck disable=SC2034
HTS_GIT_UNSTAGED='!'
# shellcheck disable=SC2034
HTS_GIT_UNTRACKED='?'
# Herdr trims ordinary trailing whitespace from metadata. A blank braille cell
# survives normalization and keeps the final Git count off the sidebar border.
# shellcheck disable=SC2034
HTS_SIDEBAR_PADDING="$(printf '\342\240\200')"

# Pids of every process the sandbox detached, from three complementary
# ledgers — each covers a blind spot of the others:
#   1. The engine's fork-time spawn registry (HERDR_TASK_SYNC_TEST_SPAWN_REGISTRY):
#      the only ledger that sees a worker before its first claim.
#   2. Claim/lock owner records under HTS_STATE: cover engines tests start
#      directly (hts_worker_run &), which the registry never sees.
#   3. A ps scan for commands referencing this sandbox's private HTS_WORK path:
#      stubs are exec'd by absolute path under $HTS_WORK and hold no claim; a
#      blocked stub orphaned by its engine's death gives up tens of seconds
#      later and recreates socket dirs on its way out.
# Registry and claim pids are emitted only while `ps` still shows them running
# herdr-task-sync AND carrying the start token recorded at fork/claim time, so
# a recycled pid can never be signalled; scan pids carry the sandbox path in
# their argv, which no unrelated process can.

# $1 = pid, $2 = recorded start token ('' = unverifiable, command check only).
_hts_engine_pid_live() {
  local pid="$1" start="$2" current
  case "$(ps -p "$pid" -o command= 2>/dev/null)" in
    *herdr-task-sync*) ;;
    *) return 1 ;;
  esac
  [[ -n "$start" ]] || return 0
  current="$(ps -p "$pid" -o lstart= 2>/dev/null |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$current" || "$current" == "$start" ]]
}

_hts_sandbox_pids() {
  local file pid command start
  {
    if [[ -s "${HTS_SPAWN_REGISTRY:-}" ]]; then
      # Registry lines are "pid start-token". A recycled pid fails the
      # start-token comparison and is left alone; an empty recorded token
      # (ps raced the fork) degrades to the command check alone.
      while IFS=' ' read -r pid start; do
        case "$pid" in '' | *[!0-9]*) continue ;; esac
        _hts_engine_pid_live "$pid" "$start" || continue
        printf '%s\n' "$pid"
      done < "$HTS_SPAWN_REGISTRY"
    fi
    if [[ -n "${HTS_STATE:-}" && -d "$HTS_STATE" ]]; then
      find "$HTS_STATE" -type f \( -name owner -o -path '*/sweep.lock/pid' \) 2>/dev/null |
        while IFS= read -r file; do
          start=""
          case "$file" in
            */sweep.lock/pid) pid="$(cat "$file" 2>/dev/null)" ;;
            *)
              pid="$(sed -n 's/^pid=//p' "$file" 2>/dev/null | head -1)"
              start="$(hts_state_field "$file" process_start 2>/dev/null || true)"
              ;;
          esac
          case "$pid" in '' | *[!0-9]*) continue ;; esac
          _hts_engine_pid_live "$pid" "$start" || continue
          printf '%s\n' "$pid"
        done
    fi
    # Plain read-loop on purpose: an awk/grep here would carry $HTS_WORK in its
    # own argv and match itself in the snapshot.
    ps -ax -o pid= -o command= 2>/dev/null |
      while IFS=' ' read -r pid command; do
        case "$pid" in '' | *[!0-9]*) continue ;; esac
        case "$command" in
          *"$HTS_WORK"*) printf '%s\n' "$pid" ;;
        esac
      done
  } | sort -u
}

# The pids above plus every live descendant (location-probe subshells, blocked
# stub calls, watchdogs). Descendants inherit no claim of their own, and the
# presentation coordinator's probe children keep writing state after their
# parent dies, so killing only the roots still loses the race.
_hts_engine_process_tree() {
  local roots="$1" table frontier pid next children
  [[ -n "$roots" ]] || return 0
  table="$(ps -ax -o pid= -o ppid= 2>/dev/null)"
  frontier="$roots"
  while [[ -n "$frontier" ]]; do
    printf '%s\n' "$frontier"
    next=""
    for pid in $frontier; do
      children="$(awk -v parent="$pid" '$2 == parent { print $1 }' <<< "$table")"
      [[ -z "$children" ]] || next="$next $children"
    done
    frontier="${next# }"
  done | sort -u
}

# Terminate every surviving sandbox process and WAIT for it to die — `rm -rf`
# alone races a survivor's writes, which resurrect HTS_WORK
# (docs/issues/2026-08-29-001). Multiple rounds, because a root killed in one
# round may have forked a child between the snapshot and the signal; the
# child surfaces in the next round's ledgers.
_hts_reap_engines() {
  local _round roots tree pid _ alive
  for _round in 1 2 3 4 5; do
    roots="$(_hts_sandbox_pids)"
    [[ -n "$roots" ]] || return 0
    tree="$(_hts_engine_process_tree "$roots")"
    while IFS= read -r pid; do
      kill "$pid" 2>/dev/null || true
    done <<< "$tree"
    for _ in $(seq 1 100); do
      alive=""
      while IFS= read -r pid; do
        kill -0 "$pid" 2>/dev/null && alive=1
      done <<< "$tree"
      [[ -n "$alive" ]] || break
      sleep 0.02
    done
    if [[ -n "$alive" ]]; then
      while IFS= read -r pid; do
        kill -9 "$pid" 2>/dev/null || true
      done <<< "$tree"
      sleep 0.02
    fi
  done
  return 0
}

hts_teardown() {
  # Reap a background reader a failed test left running BEFORE deleting its
  # HTS_WORK: the loop only stops via a file inside HTS_WORK, so once that
  # directory is gone the orphan spins forever and its ENOENT stderr lands on
  # top of the real failure output.
  if [[ -n "${HTS_READER_PID:-}" ]]; then
    kill "$HTS_READER_PID" 2>/dev/null || true
    wait "$HTS_READER_PID" 2>/dev/null || true
    unset HTS_READER_PID
  fi
  if [[ -n "${HTS_WORK:-}" ]]; then
    # The descriptor probe's contract requires its detached coordinator and
    # blocked herdr stub to OUTLIVE this teardown; reaping here would turn
    # that run vacuous. Its driver (the bounded-invocation test in
    # scripts_test.sh) releases and reaps them itself.
    if [[ -n "${HTS_DESCRIPTOR_PID_FILE:-}" ]]; then
      rm -rf "$HTS_WORK" 2>/dev/null || true
    # Every detached engine spawn is preceded by a synchronous
    # initialize_namespace, so a missing state/sockets dir proves no engine was
    # ever forked and the plain removal below cannot be raced. With it present,
    # reap survivors first, then CONFIRM the removal held: recreation by a
    # process this round's ledgers missed is only observable after the fact,
    # and each retry pass reaps again before removing.
    elif [[ -d "${HTS_STATE:-$HTS_WORK/state}/sockets" ]]; then
      local _hts_settle=0 _hts_attempt=0
      _hts_reap_engines
      rm -rf "$HTS_WORK" 2>/dev/null || true
      while [[ "$_hts_settle" -lt 2 && "$_hts_attempt" -lt 40 ]]; do
        _hts_attempt=$((_hts_attempt + 1))
        sleep 0.05
        if [[ -e "$HTS_WORK" ]]; then
          _hts_settle=0
          _hts_reap_engines
          rm -rf "$HTS_WORK" 2>/dev/null || true
        else
          _hts_settle=$((_hts_settle + 1))
        fi
      done
    else
      rm -rf "$HTS_WORK" 2>/dev/null || true
    fi
  fi
  unset HTS_WORK HTS_STUB HTS_STATE HTS_LOG HTS_DEFAULT_SOCKET HTS_SOCKET_ROOT
  unset HTS_SPAWN_REGISTRY HERDR_TASK_SYNC_TEST_SPAWN_REGISTRY
}

hts_setup() {
  [[ -z "${HTS_WORK:-}" ]] || hts_teardown
  HTS_WORK="$(mktemp -d "${BATS_TMPDIR:-/tmp}/hts.XXXXXX")"
  HTS_STUB="$HTS_WORK/stub"
  HTS_STATE="$HTS_WORK/state"
  HTS_LOG="$HTS_WORK/herdr.log"
  HTS_DEFAULT_SOCKET="$HTS_WORK/session.sock"
  HTS_SOCKET_ROOT="$HTS_WORK/sockets"
  export HTS_WORK HTS_DEFAULT_SOCKET HTS_SOCKET_ROOT
  export HERDR_SOCKET_PATH="$HTS_DEFAULT_SOCKET"
  # Fork-time spawn ledger for hts_teardown (docs/issues/2026-08-29-001). The
  # engine appends every detached pid here the instant it forks, which is the
  # only signal that exists in the window before the child's first claim.
  # Exported so nohup'd engines hand it down to the engines they spawn.
  HTS_SPAWN_REGISTRY="$HTS_WORK/spawn-registry"
  export HERDR_TASK_SYNC_TEST_SPAWN_REGISTRY="$HTS_SPAWN_REGISTRY"
  mkdir -p "$HTS_STUB" "$HTS_STATE" "$HTS_SOCKET_ROOT/socket-1"
  : > "$HTS_LOG"
  printf '%s' "$HTS_DEFAULT_SOCKET" > "$HTS_SOCKET_ROOT/socket-1/socket-path"
  printf '%s' "$HTS_LOG" > "$HTS_SOCKET_ROOT/socket-1/log-path"
  printf '%s' 2 > "$HTS_SOCKET_ROOT/next-id"
  hts_init_socket_dir "$HTS_SOCKET_ROOT/socket-1"

  # The mutable fixture uses exact socket paths as identities. Numeric storage
  # directories avoid the collision caused by replacing punctuation in names.
  cat > "$HTS_WORK/fixture-lib.sh" <<'SH'
hts_fixture_init_dir() {
  # Single-level mkdirs, never -p: a stub call surviving hts_teardown must
  # fail closed instead of resurrecting the deleted sandbox from the tmp
  # root up (docs/issues/2026-08-29-001).
  [ -d "$1" ] || return 1
  for _hts_sub in calls completions locks after; do
    mkdir "$1/$_hts_sub" 2>/dev/null || [ -d "$1/$_hts_sub" ] || return 1
  done
  [ -f "$1/state.json" ] || printf '%s\n' \
    '{"complete":true,"protocol":19,"panes":[],"tabs":[],"agents":[],"layouts":[],"workspaces":[],"metadata":{}}' \
    > "$1/state.json"
  [ -f "$1/call-seq" ] || printf '%s' 0 > "$1/call-seq"
  [ -f "$1/herdr.log" ] || : > "$1/herdr.log"
}

hts_fixture_socket_dir() {
  local socket_path="${1:-${HERDR_SOCKET_PATH:-$HTS_DEFAULT_SOCKET}}"
  local dir id lock="$HTS_SOCKET_ROOT/registry.lock" attempts=0
  [ -d "$HTS_SOCKET_ROOT" ] || return 1
  while ! mkdir "$lock" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ -d "$HTS_SOCKET_ROOT" ] && [ "$attempts" -lt 1000 ] || return 1
    sleep 0.01
  done
  for dir in "$HTS_SOCKET_ROOT"/socket-*; do
    [ -d "$dir" ] || continue
    if [ -f "$dir/socket-path" ] && [ "$(cat "$dir/socket-path")" = "$socket_path" ]; then
      rmdir "$lock"
      printf '%s\n' "$dir"
      return 0
    fi
  done
  id="$(cat "$HTS_SOCKET_ROOT/next-id" 2>/dev/null)"
  # An unreadable next-id means the sandbox is being torn down around this
  # call: fail closed rather than register a bogus "socket-" dir. Single-level
  # mkdir for the same reason (docs/issues/2026-08-29-001).
  case "$id" in
    '' | *[!0-9]*) rmdir "$lock" 2>/dev/null; return 1 ;;
  esac
  printf '%s' $((id + 1)) > "$HTS_SOCKET_ROOT/next-id"
  dir="$HTS_SOCKET_ROOT/socket-$id"
  mkdir "$dir" 2>/dev/null || { rmdir "$lock" 2>/dev/null; return 1; }
  printf '%s' "$socket_path" > "$dir/socket-path"
  hts_fixture_init_dir "$dir"
  rmdir "$lock"
  printf '%s\n' "$dir"
}

hts_fixture_log() {
  if [ -f "$1/log-path" ]; then
    cat "$1/log-path"
  else
    printf '%s/herdr.log\n' "$1"
  fi
}

hts_fixture_next_call() {
  local dir="$1" lock="$1/locks/call-seq" seq attempts=0
  [ -d "$dir/locks" ] || return 1
  while ! mkdir "$lock" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ -d "$dir/locks" ] && [ "$attempts" -lt 1000 ] || return 1
    sleep 0.01
  done
  seq=$(( $(cat "$dir/call-seq") + 1 ))
  printf '%s' "$seq" > "$dir/call-seq"
  rmdir "$lock"
  printf '%s\n' "$seq"
}

hts_fixture_state_lock() {
  local attempts=0
  [ -d "$1/locks" ] || return 1
  while ! mkdir "$1/locks/state" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ -d "$1/locks" ] && [ "$attempts" -lt 1000 ] || return 1
    sleep 0.01
  done
}

hts_fixture_state_unlock() {
  rmdir "$1/locks/state"
}
SH

  # Every read is generated from current state. Rename and metadata calls
  # mutate that state before their exact per-socket completion marker appears.
  cat > "$HTS_STUB/herdr" <<'SH'
#!/usr/bin/env bash
source "$HTS_WORK/fixture-lib.sh"
if [ -f "$HTS_WORK/block-herdr" ]; then
  block_attempts=0
  release_file="${HTS_DESCRIPTOR_RELEASE_FILE:-$HTS_WORK/release-herdr}"
  : > "$HTS_WORK/herdr-blocked"
  # Publish the blocking process itself, so a caller can prove it was still
  # blocked rather than inferring it from an ancestor that outlives the give-up
  # below. Only the descriptor test sets this.
  if [ -n "${HTS_DESCRIPTOR_BLOCKED_PID_FILE:-}" ]; then
    printf '%s\n' "$$" > "$HTS_DESCRIPTOR_BLOCKED_PID_FILE"
  fi
  # The 3000-poll default (~30 s) is what every other user of this stub gets.
  # Only the descriptor test raises it, and it exports the raised value itself.
  while [ ! -f "$release_file" ]; do
    block_attempts=$((block_attempts + 1))
    if [ "$block_attempts" -ge "${HTS_BLOCKED_HERDR_POLLS:-3000}" ]; then
      # Record the give-up durably. A caller cannot detect it by polling this
      # process for liveness -- that is a race it will usually lose -- and a
      # give-up silently invalidates any conclusion drawn about what was holding
      # a descriptor while it was supposed to be blocked.
      if [ -n "${HTS_DESCRIPTOR_BLOCKED_PID_FILE:-}" ]; then
        : > "$HTS_DESCRIPTOR_BLOCKED_PID_FILE.gave-up"
      fi
      exit 124
    fi
    sleep 0.01
  done
fi
dir="$(hts_fixture_socket_dir)" || exit 1
log="$(hts_fixture_log "$dir")"
call="$*"
seq="$(hts_fixture_next_call "$dir")" || exit 1
printf '%s\n' "$call" >> "$log"
printf '%s\n' "$call" > "$dir/calls/$seq"

finish_call() {
  if [ -f "$dir/after/$seq.json" ]; then
    hts_fixture_state_lock "$dir" || return
    cp "$dir/after/$seq.json" "$dir/state.json"
    hts_fixture_state_unlock "$dir"
  fi
  if [ -f "$dir/after/$seq.sh" ]; then
    bash "$dir/after/$seq.sh"
  fi
  : > "$dir/completions/$seq"
}
trap finish_call EXIT

state="$dir/state.json"
if [ "$1" = "pane" ] && [ "$2" = "list" ]; then
  jq -c '{id:"cli:pane:list",result:{panes:.panes,type:"pane_list"}}' "$state"
elif [ "$1" = "pane" ] && [ "$2" = "get" ]; then
  pane="$(jq -c --arg id "$3" '.panes[] | select(.pane_id == $id)' "$state")"
  [ -n "$pane" ] || exit 1
  jq -cn --argjson pane "$pane" '{id:"cli:pane:get",result:{pane:$pane,type:"pane_info"}}'
elif [ "$1" = "pane" ] && [ "$2" = "process-info" ]; then
  cat "$dir/proc-${4:-$3}.json" 2>/dev/null
elif [ "$1" = "tab" ] && [ "$2" = "list" ]; then
  jq -c '{id:"cli:tab:list",result:{tabs:.tabs,type:"tab_list"}}' "$state"
elif [ "$1" = "tab" ] && [ "$2" = "get" ]; then
  tab="$(jq -c --arg id "$3" '.tabs[] | select(.tab_id == $id)' "$state")"
  [ -n "$tab" ] || exit 1
  jq -cn --argjson tab "$tab" '{id:"cli:tab:get",result:{tab:$tab,type:"tab_info"}}'
elif [ "$1" = "api" ] && [ "$2" = "snapshot" ]; then
  [ ! -f "$dir/fail-snapshot" ] || exit 1
  if [ -f "$dir/fail-next-snapshot" ]; then
    rm -f "$dir/fail-next-snapshot"
    exit 1
  fi
  if [ "$(jq -r '.complete' "$state")" = "true" ]; then
    jq -c '{id:"cli:api:snapshot",result:{snapshot:{protocol:.protocol,panes:.panes,tabs:.tabs,agents:.agents,layouts:.layouts,workspaces:.workspaces},type:"session_snapshot"}}' "$state"
  else
    jq -c '{id:"cli:api:snapshot",result:{snapshot:{protocol:.protocol,panes:.panes},type:"session_snapshot"}}' "$state"
  fi
elif [ "$1" = "pane" ] && [ "$2" = "rename" ]; then
  tmp="$state.tmp.$$"
  hts_fixture_state_lock "$dir" || exit 1
  jq --arg id "$3" --arg label "$4" \
    '.panes |= map(if .pane_id == $id then .label = $label else . end)' \
    "$state" > "$tmp" && mv "$tmp" "$state"
  result=$?
  hts_fixture_state_unlock "$dir"
  [ "$result" -eq 0 ] || exit "$result"
elif [ "$1" = "tab" ] && [ "$2" = "rename" ]; then
  tmp="$state.tmp.$$"
  hts_fixture_state_lock "$dir" || exit 1
  jq --arg id "$3" --arg label "$4" \
    '.tabs |= map(if .tab_id == $id then .label = $label else . end)' \
    "$state" > "$tmp" && mv "$tmp" "$state"
  result=$?
  hts_fixture_state_unlock "$dir"
  [ "$result" -eq 0 ] || exit "$result"
elif [ "$1" = "pane" ] && [ "$2" = "report-metadata" ]; then
  shift 2
  source_id= pane_id= report_seq= tokens='{}' clear_tokens='[]'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) source_id="$2"; shift 2 ;;
      --seq) report_seq="$2"; shift 2 ;;
      --token) tokens="$(jq -c --arg pair "$2" '. + {($pair | split("=")[0]): ($pair | split("=")[1:] | join("="))}' <<< "$tokens")"; shift 2 ;;
      --clear-token) clear_tokens="$(jq -c --arg name "$2" '. + [$name]' <<< "$clear_tokens")"; shift 2 ;;
      --*) shift 2 ;;
      *) pane_id="$1"; shift ;;
    esac
  done
  [ -n "$source_id" ] && [ -n "$pane_id" ] || exit 2
  [ -n "$report_seq" ] || report_seq=0
  tmp="$state.tmp.$$"
  hts_fixture_state_lock "$dir" || exit 1
  jq --arg pane "$pane_id" --arg source "$source_id" --argjson seq "$report_seq" \
    --argjson tokens "$tokens" --argjson clears "$clear_tokens" '
      (.metadata[$pane][$source].seq // -1) as $current
      | if $seq < $current then . else
          .metadata[$pane][$source].seq = $seq
          | .metadata[$pane][$source].tokens = ((.metadata[$pane][$source].tokens // {}) + $tokens | with_entries(select(.key as $key | $clears | index($key) | not)))
          | (.metadata[$pane] // {} | [.[] | .tokens // {}] | add // {}) as $merged
          | .panes |= map(if .pane_id == $pane then
              .tokens = ((reduce $clears[] as $key ((.tokens // {}); del(.[$key]))) + $merged)
            else . end)
        end' "$state" > "$tmp" && mv "$tmp" "$state"
  result=$?
  hts_fixture_state_unlock "$dir"
  [ "$result" -eq 0 ] || exit "$result"
fi
SH
  chmod +x "$HTS_STUB/herdr"

  # A controlled model call blocks on its own release marker. Tests can finish
  # generation 2 before generation 1 and wait for either completion exactly.
  cat > "$HTS_WORK/model-stub" <<'SH'
#!/usr/bin/env bash
set -e
name="$(basename "$0")"
root="$HTS_WORK/models/$name"
lock="$root/allocate.lock"
# hts_stub_controlled_engine created this root at setup; a missing root means
# the sandbox is torn down, so fail closed instead of `mkdir -p`-resurrecting
# it (docs/issues/2026-08-29-001).
[ -d "$root" ] || exit 1
while ! mkdir "$lock" 2>/dev/null; do
  [ -d "$root" ] || exit 1
  sleep 0.01
done
call=$(( $(cat "$root/next" 2>/dev/null || printf '%s' 0) + 1 ))
printf '%s' "$call" > "$root/next"
rmdir "$lock"
fixture="$root/$call"
# Single-level, not -p: hts_model_fixture may have pre-created it, and a
# missing parent means the sandbox is torn down (docs/issues/2026-08-29-001).
mkdir "$fixture" 2>/dev/null || [ -d "$fixture" ] || exit 1
cat > "$fixture/stdin"
: > "$fixture/started"
for _ in $(seq 1 "${HTS_WAIT_POLLS:-6000}"); do
  [ -e "$fixture/release" ] && break
  sleep 0.01
done
[ -e "$fixture/release" ] || exit 124
cat "$fixture/stdout" 2>/dev/null || true
status="$(cat "$fixture/status" 2>/dev/null || printf '%s' 0)"
: > "$fixture/completed"
exit "$status"
SH
  chmod +x "$HTS_WORK/model-stub"

  # Git fixtures are selected by exact CWD. A blocked target lets an actual
  # 75 ms watchdog expire while seven independent probes complete normally.
  cat > "$HTS_STUB/git" <<'SH'
#!/usr/bin/env bash
cwd= command_args="$*"
if [ "$1" = "-C" ]; then
  cwd="$2"
  shift 2
elif [ "${1#--git-dir=}" != "$1" ]; then
  cwd="gitdir:${1#--git-dir=}"
  shift
elif [ "$1" = "--git-dir" ]; then
  cwd="gitdir:$2"
  shift 2
fi
fixture="$(awk -F "$(printf '\037')" -v cwd="$cwd" '$1 == cwd { print $2; exit }' "$HTS_WORK/git-fixtures/registry" 2>/dev/null)"
if [ -d "$fixture" ]; then
  printf '%s\n' "$command_args" >> "$fixture/calls"
  printf '%s' "${LC_ALL:-}" > "$fixture/locale"
  : > "$fixture/started"
  # Single-level, not -p: fail closed when the sandbox is torn down instead
  # of resurrecting it (docs/issues/2026-08-29-001).
  mkdir "$HTS_WORK/git-started" 2>/dev/null || [ -d "$HTS_WORK/git-started" ] || exit 1
  : > "$HTS_WORK/git-started/${fixture##*/}"
  if [ -f "$fixture/block" ]; then
    while [ ! -f "$fixture/release" ]; do sleep 0.01; done
  fi
  # block.short stalls only the second (--short=7) probe of a detached-HEAD
  # resolve, so the first probe of the same fixture still answers in budget.
  case "$command_args" in
    *"--short=7"*)
      if [ -f "$fixture/block.short" ]; then
        while [ ! -f "$fixture/release" ]; do sleep 0.01; done
      fi
      ;;
    *"--porcelain=v2"*)
      if [ -n "${HERDR_TASK_SYNC_TEST_STATUS_BARRIER:-}" ] && \
        [ -n "${HERDR_TASK_SYNC_TEST_STATUS_BARRIER_COUNT:-}" ]; then
        mkdir "$HERDR_TASK_SYNC_TEST_STATUS_BARRIER" 2>/dev/null || \
          [ -d "$HERDR_TASK_SYNC_TEST_STATUS_BARRIER" ] || exit 1
        : > "$HERDR_TASK_SYNC_TEST_STATUS_BARRIER/${fixture##*/}"
        while :; do
          set -- "$HERDR_TASK_SYNC_TEST_STATUS_BARRIER"/*
          [ "$#" -ge "$HERDR_TASK_SYNC_TEST_STATUS_BARRIER_COUNT" ] && break
          sleep 0.001
        done
      fi
      if [ -f "$fixture/block.status" ]; then
        while [ ! -f "$fixture/release" ]; do sleep 0.01; done
      fi
      ;;
    *"--show-toplevel"*)
      if [ -f "$fixture/block.location" ]; then
        while [ ! -f "$fixture/release" ]; do sleep 0.01; done
      fi
      ;;
  esac
  : > "$fixture/completed"
  cat "$fixture/stderr" >&2
  out="$fixture/stdout"
  case "$command_args" in
    *"--short=7"*) [ ! -f "$fixture/stdout.short" ] || out="$fixture/stdout.short" ;;
    # The status probe never falls back to the identity probe's stdout: those
    # four lines would read as four dirty paths. No canned body means a clean
    # checkout with no upstream.
    *"--porcelain=v2"*)
      out=/dev/null
      [ ! -f "$fixture/stdout.status" ] || out="$fixture/stdout.status"
      ;;
  esac
  cat "$out"
  exit "$(cat "$fixture/status")"
fi
exit 1
SH
  chmod +x "$HTS_STUB/git"
  "$HTS_STUB/git" --version >/dev/null 2>&1 || true

  # jq lives outside /usr/bin on Homebrew installs (macOS and the Linux test
  # container alike), so link it in rather than widening the pinned PATH — a
  # wider PATH would also expose the real pi and claude.
  local jq_bin
  jq_bin="$(command -v jq 2>/dev/null || true)"
  [[ -n "$jq_bin" ]] && ln -s "$jq_bin" "$HTS_STUB/jq"
  return 0
}

# $1 = binary name, $2 = text printed on stdout, $3 = exit code, $4 = sleep seconds
hts_stub_engine() {
  cat > "$HTS_STUB/$1" <<SH
#!/usr/bin/env bash
cat > "$HTS_WORK/$1-stdin.txt"
sleep ${4:-0}
printf '%s\n' '$2'
exit ${3:-0}
SH
  chmod +x "$HTS_STUB/$1"
}

hts_run() {
  hts_run_for_socket "$HTS_DEFAULT_SOCKET" "$@"
}

hts_run_for_socket() {
  local socket_path="$1"
  shift
  hts_prepare_invocation_target "$socket_path" "$@"
  env PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_ENV=1 \
    HERDR_PANE_ID=pane-1 \
    HERDR_SOCKET_PATH="$socket_path" \
    HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    HERDR_TASK_SYNC_TIMEOUT="${HTS_TIMEOUT:-$HTS_ENGINE_WATCHDOG_SECONDS}" \
    HERDR_TASK_SYNC_TEST_NO_WORKER="${HERDR_TASK_SYNC_TEST_NO_WORKER:-}" \
    HERDR_TASK_SYNC_TEST_NO_PRESENTATION="${HERDR_TASK_SYNC_TEST_NO_PRESENTATION:-}" \
    HERDR_TASK_SYNC_TEST_NOW_SEQ="${HERDR_TASK_SYNC_TEST_NOW_SEQ:-}" \
    HERDR_TASK_SYNC_LOCK_ATTEMPTS="${HERDR_TASK_SYNC_LOCK_ATTEMPTS:-}" \
    bash "$HTS_ENGINE" "$@"
}

hts_worker_run() {
  env PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_ENV=1 \
    HERDR_PANE_ID=pane-1 \
    HERDR_SOCKET_PATH="$HTS_DEFAULT_SOCKET" \
    HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    HERDR_TASK_SYNC_TIMEOUT="${HTS_TIMEOUT:-$HTS_ENGINE_WATCHDOG_SECONDS}" \
    HERDR_TASK_SYNC_TEST_NO_PRESENTATION="${HERDR_TASK_SYNC_TEST_NO_PRESENTATION:-}" \
    HERDR_TASK_SYNC_TEST_NOW_SEQ="${HERDR_TASK_SYNC_TEST_NOW_SEQ:-}" \
    HERDR_TASK_SYNC_LOCK_ATTEMPTS="${HERDR_TASK_SYNC_LOCK_ATTEMPTS:-}" \
    bash "$HTS_ENGINE" --worker --pane pane-1
}

hts_pane_list() {
  local state tmp panes
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  tmp="$state.tmp"
  panes="$(jq -c '.result.panes' <<< "$1")"
  jq --argjson panes "$panes" '
    .panes = $panes
    | reduce $panes[] as $pane (.;
        if any(.tabs[]; .tab_id == $pane.tab_id) then .
        else .tabs += [{tab_id:$pane.tab_id,workspace_id:($pane.workspace_id // ""),label:""}]
        end)
  ' "$state" > "$tmp" && mv "$tmp" "$state"
}

# $1 = pane id, $2 = the `pane process-info` payload the stub replays for it
hts_proc_info() {
  hts_proc_info_for_socket "$HTS_DEFAULT_SOCKET" "$@"
}

hts_proc_info_for_socket() {
  local dir
  dir="$(hts_socket_dir "$1")"
  printf '%s' "$3" > "$dir/proc-$2.json"
}

hts_tab_list() {
  local state tmp
  state="$(hts_socket_state "$HTS_DEFAULT_SOCKET")"
  tmp="$state.tmp"
  jq --argjson tabs "$(jq -c '.result.tabs' <<< "$1")" '.tabs = $tabs' "$state" > "$tmp" && mv "$tmp" "$state"
}

hts_init_socket_dir() {
  mkdir -p "$1/calls" "$1/completions" "$1/locks" "$1/after"
  printf '%s\n' \
    '{"complete":true,"protocol":19,"panes":[],"tabs":[],"agents":[],"layouts":[],"workspaces":[],"metadata":{}}' \
    > "$1/state.json"
  printf '%s' 0 > "$1/call-seq"
  : > "$1/herdr.log"
}

hts_socket_dir() {
  # shellcheck source=/dev/null
  source "$HTS_WORK/fixture-lib.sh"
  hts_fixture_socket_dir "$1"
}

hts_socket_state() {
  printf '%s/state.json\n' "$(hts_socket_dir "$1")"
}

hts_socket_log() {
  local dir
  dir="$(hts_socket_dir "$1")"
  if [[ -f "$dir/log-path" ]]; then
    cat "$dir/log-path"
  else
    printf '%s/herdr.log\n' "$dir"
  fi
}

hts_socket_run() {
  local socket_path="$1"
  shift
  env PATH="$HTS_STUB:/usr/bin:/bin" HERDR_SOCKET_PATH="$socket_path" herdr "$@"
}

# Upsert one object into a snapshot array, replacing any element that already
# carries the same id. Serves panes, tabs, and workspaces alike.
hts_upsert() {
  local socket="$1" array="$2" id_field="$3" object="$4" state tmp
  state="$(hts_socket_state "$socket")"
  tmp="$state.tmp"
  jq --arg array "$array" --arg id "$id_field" --argjson object "$object" \
    '.[$array] = ([.[$array][] | select(.[$id] != $object[$id])] + [$object])' \
    "$state" > "$tmp" && mv "$tmp" "$state"
}

hts_set_pane() {
  hts_upsert "$1" panes pane_id "$2"
}

hts_remove_pane() {
  local state tmp
  state="$(hts_socket_state "$1")"
  tmp="$state.tmp"
  jq --arg id "$2" '.panes |= map(select(.pane_id != $id))' "$state" > "$tmp" && mv "$tmp" "$state"
}

hts_set_tab() {
  hts_upsert "$1" tabs tab_id "$2"
}

# Workspace names come from the snapshot's workspaces array and feed the
# aggregate agent line independently of location identity.
hts_set_workspace() {
  hts_upsert "$1" workspaces workspace_id "$2"
}

hts_snapshot_complete() {
  local state tmp
  state="$(hts_socket_state "$1")"
  tmp="$state.tmp"
  jq --argjson complete "$2" '.complete = $complete' "$state" > "$tmp" && mv "$tmp" "$state"
}

hts_after_next_call_state() {
  local dir next
  dir="$(hts_socket_dir "$1")"
  next=$(( $(cat "$dir/call-seq") + 1 ))
  printf '%s\n' "$2" > "$dir/after/$next.json"
}

hts_after_call_script() {
  local dir
  dir="$(hts_socket_dir "$1")"
  printf '%s\n' "$3" > "$dir/after/$2.sh"
}

# Git-probe budget for every location pass, via hts_location_pass's own default.
# It only has to be long enough for a HEALTHY probe to finish: the engine's
# watchdog cancels its timer the moment the probe returns, so a generous value
# costs a passing run nothing. At 0.075 it was calibrated on an idle machine and
# SIGKILLs healthy probes as soon as the suite runs with --jobs, which reads as a
# coordinator bug rather than as the load artifact it is.
#
# Three tests do pay it in full, because they point a probe at a `block` fixture
# that spins on a `release` file they never create, and a budget only expires
# when nothing returns. That is ~1.9 s each. A second, smaller constant for
# those three would not be safe: each of them runs healthy probes on the same
# pass -- the eight-pane coordinator test runs seven -- and a tighter budget
# would SIGKILL those, which is the failure this value exists to prevent.
HTS_GIT_BUDGET="${HTS_GIT_BUDGET:-2}"
# The status probe has its own bound in the engine, so the harness gives it
# its own generous default for the same reason the identity budget is
# generous here: a stub probe under --jobs load must not lose the race and
# flake every counts assertion. A test that wants a timeout sets it low.
HTS_STATUS_BUDGET="${HTS_STATUS_BUDGET:-2}"

# Behavioral budget for the "fails open promptly rather than hanging" assertions.
# The helper below scales a same-run process-launch baseline before enforcing this,
# so full-suite scheduler contention does not become the behavioral deadline.
# The base deadline still catches idle multi-second regressions. The multiplier
# gives loaded CI a margin for scheduler stalls that the baseline observes.
HTS_FAIL_OPEN_BEHAVIOR_SECONDS="${HTS_FAIL_OPEN_BEHAVIOR_SECONDS:-2.5}"
HTS_FAIL_OPEN_BASELINE_MULTIPLIER="${HTS_FAIL_OPEN_BASELINE_MULTIPLIER:-8}"
# Process-heavy commands can provide a same-run healthy-path duration. The guard
# uses it only when it exceeds the scaled one-process launch baseline.
HTS_FAIL_OPEN_REFERENCE_MILLIS="${HTS_FAIL_OPEN_REFERENCE_MILLIS:-}"

# Hang guard for the same assertions. A return after the behavioral budget is a
# promptness regression. No return by this ceiling is a hung fail-open path.
# Twenty seconds is intentionally generous because this guard must tolerate
# --jobs contention; it must not become the behavioral deadline.
HTS_FAIL_OPEN_MAX_SECONDS="${HTS_FAIL_OPEN_MAX_SECONDS:-20}"

hts_millis() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

hts_seconds_to_millis() {
  python3 - "$1" <<'PY'
import decimal
import sys

try:
    seconds = decimal.Decimal(sys.argv[1])
except decimal.InvalidOperation:
    raise SystemExit(2)
if seconds < 0:
    raise SystemExit(2)
print(int(seconds * 1000))
PY
}

hts_millis_to_seconds() {
  python3 - "$1" <<'PY'
import decimal
import sys

try:
    millis = decimal.Decimal(sys.argv[1])
except decimal.InvalidOperation:
    raise SystemExit(2)
if millis < 0:
    raise SystemExit(2)
print(millis / decimal.Decimal(1000))
PY
}

hts_fail_open_behavior_baseline_ms() {
  local launch_ms="$1" multiplier="$2" reference_ms="$3"
  local scaled_ms=$((launch_ms * multiplier))

  if [ "$reference_ms" -gt "$scaled_ms" ]; then
    printf '%s\n' "$reference_ms"
  else
    printf '%s\n' "$scaled_ms"
  fi
}

hts_run_fail_open_guard() {
  local behavior_ms hang_ms baseline_multiplier reference_ms
  local baseline_start baseline_end baseline_ms behavior_baseline_ms
  local start end elapsed_ms behavior_allowed_ms hang_allowed_ms hang_allowed_seconds
  local input out err timeout_marker pid watchdog status

  behavior_ms="$(hts_seconds_to_millis "$HTS_FAIL_OPEN_BEHAVIOR_SECONDS")" || return 2
  hang_ms="$(hts_seconds_to_millis "$HTS_FAIL_OPEN_MAX_SECONDS")" || return 2
  case "$HTS_FAIL_OPEN_BASELINE_MULTIPLIER" in
    '' | *[!0-9]*) return 2 ;;
    *) baseline_multiplier="$HTS_FAIL_OPEN_BASELINE_MULTIPLIER" ;;
  esac
  case "$HTS_FAIL_OPEN_REFERENCE_MILLIS" in
    '' ) reference_ms=0 ;;
    *[!0-9]*) return 2 ;;
    *) reference_ms="$HTS_FAIL_OPEN_REFERENCE_MILLIS" ;;
  esac
  input="$(mktemp "$HTS_WORK/fail-open-stdin.XXXXXX")" || return 1
  out="$(mktemp "$HTS_WORK/fail-open-stdout.XXXXXX")" || { rm -f "$input"; return 1; }
  err="$(mktemp "$HTS_WORK/fail-open-stderr.XXXXXX")" || { rm -f "$input" "$out"; return 1; }
  timeout_marker="$(mktemp "$HTS_WORK/fail-open-timeout.XXXXXX")" || {
    rm -f "$input" "$out" "$err"
    return 1
  }
  rm -f "$timeout_marker"
  # A test with no redirected input must not consume the runner's terminal.
  if [[ ! -t 0 ]]; then
    cat > "$input"
  fi

  baseline_start="$(hts_millis)"
  bash -c ':' >/dev/null 2>&1
  baseline_end="$(hts_millis)"
  baseline_ms=$((baseline_end - baseline_start))
  behavior_baseline_ms="$(
    hts_fail_open_behavior_baseline_ms "$baseline_ms" "$baseline_multiplier" "$reference_ms"
  )"
  behavior_allowed_ms=$((behavior_ms + behavior_baseline_ms))
  hang_allowed_ms=$((baseline_ms + hang_ms))
  hang_allowed_seconds="$(hts_millis_to_seconds "$hang_allowed_ms")" || {
    rm -f "$input" "$out" "$err" "$timeout_marker"
    return 2
  }

  start="$(hts_millis)"
  "$@" < "$input" > "$out" 2> "$err" &
  pid=$!
  (
    sleep "$hang_allowed_seconds"
    if kill -0 "$pid" 2>/dev/null; then
      : > "$timeout_marker"
      kill -9 "$pid" 2>/dev/null || true
    fi
  ) >/dev/null 2>&1 &
  watchdog=$!
  wait "$pid"
  status=$?
  end="$(hts_millis)"
  kill "$watchdog" >/dev/null 2>&1 || true
  wait "$watchdog" 2>/dev/null || true
  cat "$out" 2>/dev/null || true
  cat "$err" >&2 2>/dev/null || true

  elapsed_ms=$((end - start))
  if [ -f "$timeout_marker" ]; then
    rm -f "$input" "$out" "$err" "$timeout_marker"
    printf 'fail-open command exceeded hang guard: elapsed_ms=%s allowed_ms=%s baseline_ms=%s\n' \
      "$elapsed_ms" "$hang_allowed_ms" "$baseline_ms"
    return 124
  fi
  rm -f "$input" "$out" "$err" "$timeout_marker"
  if [ "$elapsed_ms" -gt "$behavior_allowed_ms" ]; then
    printf 'fail-open command exceeded fail-open behavioral deadline: elapsed_ms=%s allowed_ms=%s baseline_ms=%s\n' \
      "$elapsed_ms" "$behavior_allowed_ms" "$behavior_baseline_ms"
    return 124
  fi
  return "$status"
}

# Watchdog for a single engine call, enforced by `kill -9` inside the engine's
# own run_with_timeout. It is a hang guard, not a budget: every test here stubs
# the engine, so it should never fire. The old 5 s left the R8 test -- which
# stubs an engine that sleeps 4 s on purpose -- a one-second margin, and under
# --jobs contention the stub loses that race and gets SIGKILLed mid-call. The
# invocation then commits nothing and the ordering tests that wait on that
# commit time out, which reads as a coordinator ordering bug rather than as the
# load artifact it is. 30 s tracks ENGINE_TIMEOUT in
# home/dot_local/bin/executable_herdr-task-sync, so the tests now run the
# shipped watchdog instead of a tightened test-only one -- keep the two in step
# if that default ever moves. The single test that wants the watchdog to fire
# pins HTS_TIMEOUT=1 for itself.
HTS_ENGINE_WATCHDOG_SECONDS="${HTS_ENGINE_WATCHDOG_SECONDS:-30}"

# Ceiling for the "poll until the state settles" helpers. The helpers sleep at
# three different intervals, so each gets its own poll count derived from the one
# ceiling rather than a separately hand-computed literal. Every one of them
# returns the moment its condition holds, so a high ceiling costs a healthy run
# nothing; it only decides how long a genuinely stuck run waits before it reports
# failure. The previous 10s and 15s ceilings were calibrated on an idle machine,
# and a multi-step fixture under --jobs contention can legitimately exceed them
# -- which surfaced as a hang that was really load.
HTS_WAIT_CEILING_SECONDS="${HTS_WAIT_CEILING_SECONDS:-60}"
HTS_WAIT_POLLS="${HTS_WAIT_POLLS:-$((HTS_WAIT_CEILING_SECONDS * 100))}"        # sleep 0.01
HTS_WAIT_SLOW_POLLS="${HTS_WAIT_SLOW_POLLS:-$((HTS_WAIT_CEILING_SECONDS * 4))}"  # sleep 0.25
HTS_WAIT_MATCH_POLLS="${HTS_WAIT_MATCH_POLLS:-$((HTS_WAIT_CEILING_SECONDS * 40))}" # sleep 0.025
# The model stub is written from a quoted heredoc and runs as its own process,
# so it reads its ceiling from the environment rather than from file scope. The
# other two are only ever read by functions in this file.
export HTS_WAIT_POLLS

# The two bounds around the nested runner invocation in "bounded bashunit invocation exits
# after detached work". They are deliberately two numbers, not one, because a
# hang guard and an assertion are different budgets: the old single 90 s budget
# covered the whole nested run, most of which was the runner parsing every test in
# the full scripts suite to reach the one the filter selects. The nested run now
# targets a dedicated one-test file, so the progress guard covers setup and the
# probe itself rather than a whole-suite parse.
#
# The causal remedy docs/issues/2026-08-21-015 prefers is unavailable here: a
# held pipe and a released one differ only in elapsed time, with no marker a test
# could block on. So the split is the fallback, applied deliberately.
#
# PROGRESS is the hang guard. It covers the nested run up to the probe writing
# its pid file. It never fires in a healthy run or in the guarded regression --
# only a genuine hang reaches it. Sixty seconds is intentionally still a guard,
# not a performance budget: it is far above the measured dedicated-file run, and
# far enough below the macOS job's timeout-minutes: 20 that it prints its own
# message instead of the job being killed with none.
HTS_INNER_BATS_PROGRESS_SECONDS="${HTS_INNER_BATS_PROGRESS_SECONDS:-60}"
# EXIT is the assertion, and the only bound here that can fire on a healthy run.
# It covers runner teardown and exit alone -- not the parse -- which is what takes
# the load sensitivity out. Sized from measurement, not intuition: the driver
# prints its elapsed value on every run, and this is a large multiple of the
# ~0.2 s observed under CPU saturation on a 10-core host. Must stay below
# HTS_BLOCKED_HERDR_CEILING_SECONDS below, which is stated in the same unit so
# the two can be compared; see that comment for the window it has to clear.
HTS_INNER_BATS_EXIT_SECONDS="${HTS_INNER_BATS_EXIT_SECONDS:-30}"
# The driver runs as its own process, so both bounds have to be exported to
# reach it -- like HTS_WAIT_POLLS above. Without this the driver silently falls
# back to its own literals and editing the values here changes nothing, which is
# the same two-sources-of-truth failure this whole change is about.
export HTS_INNER_BATS_PROGRESS_SECONDS HTS_INNER_BATS_EXIT_SECONDS

# How long the blocked herdr stub waits for its release before giving up. This
# is a non-vacuity guard, not a budget. If the stub gives up first, the detached
# worker exits on its own, nothing is holding a descriptor when the driver looks,
# and the test would have passed having proved nothing.
#
# So the ceiling has to outlast the entire window the stub must stay blocked for,
# which is NOT just the exit bound. The stub starts blocking inside the nested
# test body -- it writes herdr-blocked before the probe writes its pid file -- so
# the window runs from there through the rest of the progress phase, all of the
# exit bound, and the liveness check. Derived rather than hardcoded so that
# relation holds by construction: a hand-picked number silently inverts the first
# time either bound above moves, and the failure it produces is a misdiagnosis
# (the run reports "the fixture gave up" when what actually happened is the hang
# guard's case).
#
# Stated in seconds like its counterparts: the stub polls at 0.01 s, and under
# --jobs contention each iteration costs more than that, so the poll count
# derived below is a floor on the real wall clock, never a cap.
HTS_BLOCKED_HERDR_CEILING_SECONDS="${HTS_BLOCKED_HERDR_CEILING_SECONDS:-$((HTS_INNER_BATS_PROGRESS_SECONDS + HTS_INNER_BATS_EXIT_SECONDS + 60))}"
HTS_BLOCKED_HERDR_POLLS="${HTS_BLOCKED_HERDR_POLLS:-$((HTS_BLOCKED_HERDR_CEILING_SECONDS * 100))}" # sleep 0.01
# Deliberately NOT exported at file scope. Two other tests use the same blocking
# stub (search block-herdr) and release it promptly; handing them a ceiling two
# orders of magnitude larger only slows down their failure paths, where the stub
# would otherwise give up quickly inside an already-deleted work dir. The one
# test that needs the raised ceiling exports it for itself.



hts_wait_for_file() {
  local file="$1" _
  for _ in $(seq 1 $HTS_WAIT_POLLS); do
    [[ -e "$file" ]] && return 0
    sleep 0.01
  done
  return 1
}

# Waits for a file to CONTAIN something, not merely to exist. The adapter's
# stub is spawned by the plugin and writes its line after bun's hooks have all
# returned, so on a loaded machine the log can be absent or empty at the moment
# the test reads it. This is the same distinction hts_wait_for_publish draws for
# the same reason (docs/issues/2026-08-14-001).
hts_wait_for_file_match() {
  local file="$1" pattern="$2" _
  for _ in $(seq 1 $HTS_WAIT_MATCH_POLLS); do
    if [[ -e "$file" ]] && grep -q -- "$pattern" "$file"; then
      # Settle briefly so a second, unwanted line would also have landed --
      # this test asserts the log holds exactly one call, and returning the
      # instant the first line appears would hide a duplicate.
      sleep 0.1
      return 0
    fi
    sleep 0.025
  done
  return 1
}

hts_wait_for_socket_call() {
  local dir="$1" call_number="$2"
  hts_wait_for_file "$dir/calls/$call_number"
}

hts_wait_for_socket_completion() {
  local dir="$1" call_number="$2"
  hts_wait_for_file "$dir/completions/$call_number"
}

hts_stub_controlled_engine() {
  ln -s "$HTS_WORK/model-stub" "$HTS_STUB/$1"
  mkdir -p "$HTS_WORK/models/$1"
  printf '%s' 0 > "$HTS_WORK/models/$1/next"
}

hts_model_fixture() {
  local fixture="$HTS_WORK/models/$1/$2"
  mkdir -p "$fixture"
  printf '%s\n' "$3" > "$fixture/stdout"
  printf '%s' "${4:-0}" > "$fixture/status"
}

hts_release_model() {
  : > "$HTS_WORK/models/$1/$2/release"
}

hts_git_fixture() {
  local id fixture next="$HTS_WORK/git-fixtures/next"
  mkdir -p "$HTS_WORK/git-fixtures"
  id="$(cat "$next" 2>/dev/null || printf '%s' 1)"
  printf '%s' $((id + 1)) > "$next"
  fixture="$HTS_WORK/git-fixtures/$id"
  mkdir -p "$fixture"
  printf '%s' "$1" > "$fixture/cwd"
  printf '%s\n' "$2" > "$fixture/stdout"
  printf '%s' "${3:-0}" > "$fixture/status"
  printf '%s\n' "${5:-}" > "$fixture/stderr"
  : > "$fixture/calls"
  printf '%s\037%s\n' "$1" "$fixture" >> "$HTS_WORK/git-fixtures/registry"
  [[ "${4:-ready}" = "block" ]] && : > "$fixture/block"
  return 0
}

# The location probe's stdout is four lines: checkout root, common Git
# directory, symbolic ref (literally HEAD when detached), 7-char short SHA.
hts_git_location_fixture() {
  local branch="${4:-refs/heads/main}" sha="${5:-abc9876}"
  hts_git_fixture "$1" "$(printf '%s\n%s\n%s\n%s' "$2" "$3" "$branch" "$sha")" "${6:-0}" "${7:-ready}"
}

# The status probe is a second call against the same checkout, so its canned
# body lives beside the identity probe's rather than in a fixture of its own.
# Pass a porcelain v2 body; omit it and the stub answers empty, which is a
# clean checkout with no upstream.
hts_git_status_fixture() {
  local fixture
  fixture="$(hts_git_fixture_dir "$1")"
  [[ -n "$fixture" ]] || return 1
  printf '%s\n' "$2" > "$fixture/stdout.status"
}

# Stalls only the status probe of a fixture and leaves its identity probe
# inside budget: the case where the counts must go missing and $git_ref must
# not. Release it the way the other blocking fixtures are released, by
# touching $fixture/release.
hts_block_git_status() {
  local fixture
  fixture="$(hts_git_fixture_dir "$1")"
  [[ -n "$fixture" ]] || return 1
  : > "$fixture/block.status"
}

# The mirror image: stalls only the identity probe and leaves the status probe
# inside budget, which is how a transient location outcome is reached while
# real counts are still measurable for the retained root.
hts_block_git_location() {
  local fixture
  fixture="$(hts_git_fixture_dir "$1")"
  [[ -n "$fixture" ]] || return 1
  : > "$fixture/block.location"
}

# A linked worktree carries a .git FILE at its root; the main checkout has a
# .git directory. The resolver's is_linked check reads only this marker.
hts_mark_linked_worktree() {
  printf 'gitdir: %s\n' "${2:-$1.gitdir}" > "$1/.git"
}

hts_git_fixture_dir() {
  awk -F "$(printf '\037')" -v cwd="$1" '$1 == cwd { print $2; exit }' \
    "$HTS_WORK/git-fixtures/registry"
}

hts_process_pane_json() {
  local id="$1" tab="$2" cwd="$3" foreground_mode="${4:-present}" foreground="$3"
  [ "$#" -lt 5 ] || foreground="$5"
  jq -cn --arg id "$id" --arg tab "$tab" --arg cwd "$cwd" --arg fg "$foreground" \
    --arg mode "$foreground_mode" '
      {pane_id:$id,tab_id:$tab,workspace_id:"ws-1",terminal_id:("term-" + $id),agent:null,label:"",tokens:{},cwd:$cwd}
      | if $mode == "absent" then . else .foreground_cwd = $fg end'
}

# An agent pane. herdr carries the agent kind and its session id, and that
# session id is the key an agent's own directory report is filed under.
hts_agent_pane_json() {
  local id="$1" tab="$2" cwd="$3" agent="$4" session="$5"
  jq -cn --arg id "$id" --arg tab "$tab" --arg cwd "$cwd" \
    --arg agent "$agent" --arg session "$session" '
      {pane_id:$id,tab_id:$tab,workspace_id:"ws-1",terminal_id:("term-" + $id),
       agent:$agent,
       agent_session:{source:("herdr:" + $agent),agent:$agent,kind:"id",value:$session},
       label:"",tokens:{},cwd:$cwd,foreground_cwd:$cwd}'
}

# Files a directory report directly, for cases that need a body no real
# reporter would write.
hts_write_agent_cwd_record() {
  local root="$HTS_STATE/agent-cwd" key
  mkdir -p "$root"
  key="$(LC_ALL=C printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-64)"
  printf '%s\n' "$2" > "$root/$key"
}

# Drives the shipped Claude statusline the way Claude Code does, so the record
# under test is the one the real reporter writes rather than an imitation.
hts_run_claude_statusline() {
  local dir="$1" session="$2"
  jq -cn --arg dir "$dir" --arg session "$session" '
    {session_id:$session,workspace:{current_dir:$dir},
     model:{display_name:"test"},cost:{},context_window:{}}' |
    env HERDR_ENV=1 HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
      PATH="$HTS_STUB:/usr/bin:/bin" HOME="$HTS_WORK" \
      bash "$SOURCE_ROOT/private_dot_claude/hooks/executable_statusline.sh" \
      >/dev/null 2>&1
}

hts_set_process_label() {
  hts_proc_info "$1" "$(jq -cn --arg command "$2" '{result:{process_info:{shell_pid:1,foreground_process_group_id:2,foreground_processes:[{pid:2,argv:[$command]}]}}}')"
}

hts_set_pane_location() {
  local state tmp foreground="$4"
  state="$(hts_socket_state "$1")"
  tmp="$state.tmp"
  jq --arg id "$2" --arg cwd "$3" --arg fg "$foreground" --arg mode "${5:-present}" '
    .panes |= map(if .pane_id == $id then
      .cwd = $cwd
      | if $mode == "absent" then del(.foreground_cwd) else .foreground_cwd = $fg end
    else . end)' "$state" > "$tmp" && mv "$tmp" "$state"
}

hts_location_pass() {
  HERDR_TASK_SYNC_GIT_BUDGET="${HERDR_TASK_SYNC_GIT_BUDGET:-$HTS_GIT_BUDGET}" \
    HERDR_TASK_SYNC_STATUS_BUDGET="${HERDR_TASK_SYNC_STATUS_BUDGET:-$HTS_STATUS_BUDGET}" hts_event_run
  hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
}

hts_location_source_seq() {
  jq -r --arg pane "$2" '.metadata[$pane]["location-sync"].seq // 0' "$(hts_socket_state "$1")"
}

# The sweep modes carry no agent and no pane, so they run the script directly
# rather than through hts_run. The git budget mirrors hts_location_pass: the
# shipped 75 ms SIGKILL bound is a UI-latency budget calibrated against real
# git on an idle machine, and a forked bash-stub probe under --jobs load loses
# that race, degrades the pane to location_status=stale, and flakes any
# location assertion (the pattern docs/issues/2026-08-21-015 names; this was
# its third missed call site after 543ca9e and 7f675e1).
hts_sweep_run() {
  env PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    HERDR_TASK_SYNC_SWEEP_INTERVAL="${HTS_SWEEP_INTERVAL:-1}" \
    HERDR_TASK_SYNC_GIT_BUDGET="${HERDR_TASK_SYNC_GIT_BUDGET:-$HTS_GIT_BUDGET}" \
    HERDR_TASK_SYNC_STATUS_BUDGET="${HERDR_TASK_SYNC_STATUS_BUDGET:-$HTS_STATUS_BUDGET}" \
    bash "$HTS_ENGINE" "$@"
}

hts_event_run() {
  env PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_SOCKET_PATH="$HTS_DEFAULT_SOCKET" \
    HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    HERDR_TASK_SYNC_TEST_NO_PRESENTATION="${HERDR_TASK_SYNC_TEST_NO_PRESENTATION:-}" \
    HERDR_TASK_SYNC_TEST_PAUSE_BEFORE_RELEASE="${HERDR_TASK_SYNC_TEST_PAUSE_BEFORE_RELEASE:-}" \
    HERDR_TASK_SYNC_TEST_NOW_SEQ="${HERDR_TASK_SYNC_TEST_NOW_SEQ:-}" \
    HERDR_TASK_SYNC_TEST_DIGEST_FILE="${HERDR_TASK_SYNC_TEST_DIGEST_FILE:-}" \
    HERDR_TASK_SYNC_GIT_BUDGET="${HERDR_TASK_SYNC_GIT_BUDGET:-}" \
    HERDR_TASK_SYNC_STATUS_BUDGET="${HERDR_TASK_SYNC_STATUS_BUDGET:-}" \
    HERDR_TASK_SYNC_STATE_MAX_AGE_DAYS="${HERDR_TASK_SYNC_STATE_MAX_AGE_DAYS:-14}" \
    HERDR_TASK_SYNC_TEST_NO_DAEMON="${HERDR_TASK_SYNC_TEST_NO_DAEMON-1}" \
    bash "$HTS_ENGINE" --event
}

hts_event_run_for_socket() {
  local socket_path="$1"
  env PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_SOCKET_PATH="$socket_path" \
    HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    HERDR_TASK_SYNC_TEST_NO_PRESENTATION="${HERDR_TASK_SYNC_TEST_NO_PRESENTATION:-}" \
    HERDR_TASK_SYNC_TEST_NO_DAEMON="${HERDR_TASK_SYNC_TEST_NO_DAEMON-1}" \
    bash "$HTS_ENGINE" --event
}

hts_presentation_run() {
  env PATH="$HTS_STUB:/usr/bin:/bin" \
    HERDR_SOCKET_PATH="$HTS_DEFAULT_SOCKET" \
    HERDR_TASK_SYNC_STATE_DIR="$HTS_STATE" \
    HERDR_TASK_SYNC_TEST_CRASH_AFTER="${HERDR_TASK_SYNC_TEST_CRASH_AFTER:-}" \
    HERDR_TASK_SYNC_TEST_NOW_SEQ="${HERDR_TASK_SYNC_TEST_NOW_SEQ:-}" \
    HERDR_TASK_SYNC_TEST_DIGEST_FILE="${HERDR_TASK_SYNC_TEST_DIGEST_FILE:-}" \
    HERDR_TASK_SYNC_GIT_BUDGET="${HERDR_TASK_SYNC_GIT_BUDGET:-}" \
    HERDR_TASK_SYNC_STATUS_BUDGET="${HERDR_TASK_SYNC_STATUS_BUDGET:-}" \
    HERDR_TASK_SYNC_STATE_MAX_AGE_DAYS="${HERDR_TASK_SYNC_STATE_MAX_AGE_DAYS:-14}" \
    HERDR_TASK_SYNC_TEST_LOCATION_BARRIER="${HERDR_TASK_SYNC_TEST_LOCATION_BARRIER:-}" \
    HERDR_TASK_SYNC_TEST_LOCATION_BARRIER_COUNT="${HERDR_TASK_SYNC_TEST_LOCATION_BARRIER_COUNT:-}" \
    HERDR_TASK_SYNC_TEST_LOCATION_BARRIER_RELEASE="${HERDR_TASK_SYNC_TEST_LOCATION_BARRIER_RELEASE:-}" \
    HERDR_TASK_SYNC_TEST_STATUS_BARRIER="${HERDR_TASK_SYNC_TEST_STATUS_BARRIER:-}" \
    HERDR_TASK_SYNC_TEST_STATUS_BARRIER_COUNT="${HERDR_TASK_SYNC_TEST_STATUS_BARRIER_COUNT:-}" \
    bash "$HTS_ENGINE" --presentation-worker
}

# The worker logs several herdr calls in a row, so a test that reads a later
# call must wait for that call and not for the first line of the log.
hts_wait_for_call() {
  local _
  for _ in $(seq 1 $HTS_WAIT_SLOW_POLLS); do
    grep -q -- "$1" "$HTS_LOG" && return 0
    sleep 0.25
  done
  return 1
}

# Waits for the publish itself — the `--token task=` metadata call — and not
# merely for a non-empty log. The entry point logs `pane process-info` before it
# forks the worker, so a non-empty log says only that the run started: the state
# file is unwritten, the naming engine has not been called, and the assertions
# that follow read whatever the PREVIOUS session left behind. That was a real
# flake, not a theoretical one (docs/issues/2026-08-14-001).
hts_wait_for_publish() {
  hts_wait_for_call '--token task='
}

# The presentation coordinator keeps logging after metadata publication. A
# test that truncates the log must wait for its fresh snapshot first.
hts_wait_for_worker_exit() {
  hts_wait_for_publish && hts_wait_for_presentation_quiescence "$HTS_DEFAULT_SOCKET"
}

# Waits for a session's own durable state file. Session ids are part of the
# path, so this signal cannot be satisfied by another session's worker — the
# one guarantee a log-based wait cannot give while two workers overlap.
hts_wait_for_state() {
  local _
  for _ in $(seq 1 $HTS_WAIT_SLOW_POLLS); do
    [[ -s "$1" ]] && return 0
    sleep 0.25
  done
  return 1
}

hts_token() {
  sed -n 's/.*--token task=\([^ ]*\).*/\1/p' "$HTS_LOG" | tail -1
}

hts_pane_label() {
  sed -n "s/^pane rename ${1:-pane-1} //p" "$HTS_LOG" | tail -1
}

hts_legacy_state_file() {
  printf '%s/%s.state' "$HTS_STATE" "$1"
}

hts_state_field() {
  grep -m1 "^${2}=" "$1" | cut -d= -f2- | base64 -d
}

hts_key() {
  printf '%s' "$1" | base64 | tr '/+' '_-' | tr -d '=\n'
}

hts_namespace() {
  printf '%s/sockets/%s\n' "$HTS_STATE" "$(hts_key "$1")"
}

hts_pane_state_dir() {
  printf '%s/panes/%s\n' "$(hts_namespace "$1")" "$(hts_key "$2")"
}

hts_prepare_invocation_target() {
  local socket_path="$1" pane_id=pane-1 invocation_agent='' invocation_session='' state tmp
  shift
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --pane) pane_id="${2:-}"; shift 2 ;;
      --agent) invocation_agent="${2:-}"; shift 2 ;;
      --session) invocation_session="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$invocation_agent" && -n "$invocation_session" ]] || return 0
  state="$(hts_socket_state "$socket_path")"
  if jq -e --arg id "$pane_id" '.panes[] | select(.pane_id == $id and ._hts_auto == true)' "$state" >/dev/null; then
    tmp="$state.tmp"
    jq --arg id "$pane_id" --arg agent "$invocation_agent" --arg session "$invocation_session" '
      .panes |= map(if .pane_id == $id then
        .agent = $agent
        | .agent_session = {source:("herdr:" + $agent),agent:$agent,kind:"id",value:$session}
      else . end)
    ' "$state" > "$tmp" && mv "$tmp" "$state"
    return 0
  fi
  jq -e --arg id "$pane_id" '.panes[] | select(.pane_id == $id)' "$state" >/dev/null && return 0
  tmp="$state.tmp"
  jq --arg pane "$pane_id" --arg agent "$invocation_agent" --arg session "$invocation_session" '
    .panes += [{pane_id:$pane,tab_id:"tab-1",workspace_id:"ws-1",terminal_id:("term-" + $pane),agent:$agent,agent_session:{source:("herdr:" + $agent),agent:$agent,kind:"id",value:$session},label:"",tokens:{},_hts_auto:true}]
    | if any(.tabs[]; .tab_id == "tab-1") then . else .tabs += [{tab_id:"tab-1",workspace_id:"ws-1",label:""}] end
  ' "$state" > "$tmp" && mv "$tmp" "$state"
}

hts_control_file() {
  printf '%s/control.state\n' "$(hts_pane_state_dir "$1" "$2")"
}

hts_task_file() {
  local identity
  identity="$(printf '%s\037%s\037%s' "$2" "$3" "$4")"
  printf '%s/tasks/%s.state\n' "$(hts_namespace "$1")" "$(hts_key "$identity")"
}

hts_migration_marker() {
  local identity
  identity="$(printf '%s\037%s\037%s' "$2" "$3" "$4")"
  printf '%s/migration/%s.done\n' "$(hts_namespace "$1")" "$(hts_key "$identity")"
}

hts_record_text() {
  hts_state_field "$1" "$2"
}

hts_record_number() {
  sed -n "s/^${2}=//p" "$1" | head -1
}

hts_wait_for_record_number() {
  local file="$1" field="$2" expected="$3" _ value
  for _ in $(seq 1 $HTS_WAIT_POLLS); do
    value="$(hts_record_number "$file" "$field" 2>/dev/null || true)"
    [[ -n "$value" && "$value" -ge "$expected" ]] && return 0
    sleep 0.01
  done
  return 1
}

hts_wait_for_quiescence() {
  local control="$1" _ generation committed worker_claim
  worker_claim="$(dirname "$control")/worker.claim"
  for _ in $(seq 1 $HTS_WAIT_POLLS); do
    generation="$(hts_record_number "$control" generation 2>/dev/null || true)"
    committed="$(hts_record_number "$control" committed_generation 2>/dev/null || true)"
    if [[ -n "$generation" && "$generation" = "$committed" && ! -d "$worker_claim" ]]; then
      sleep 0.02
      [[ ! -d "$worker_claim" ]] && return 0
    fi
    sleep 0.01
  done
  return 1
}

hts_wait_for_presentation_quiescence() {
  local namespace reconcile claim _ pending completed
  namespace="$(hts_namespace "$1")"
  reconcile="$namespace/reconcile.state"
  claim="$namespace/presentation.claim"
  for _ in $(seq 1 $HTS_WAIT_POLLS); do
    pending="$(hts_record_number "$reconcile" pending_generation 2>/dev/null || true)"
    completed="$(hts_record_number "$reconcile" completed_generation 2>/dev/null || true)"
    if [[ -n "$pending" && "$pending" -gt 0 && "$pending" = "$completed" && ! -d "$claim" ]]; then
      sleep 0.02
      [[ ! -d "$claim" ]] && return 0
    fi
    sleep 0.01
  done
  return 1
}

hts_write_legacy_state() {
  local file="$1" slug="$2" first="$3" latest="$4"
  {
    printf 'slug=%s\n' "$(printf '%s' "$slug" | base64 | tr -d '\n')"
    printf 'first_prompt=%s\n' "$(printf '%s' "$first" | base64 | tr -d '\n')"
    printf 'latest_prompt=%s\n' "$(printf '%s' "$latest" | base64 | tr -d '\n')"
  } > "$file"
}

hts_wait_for_task_slug() {
  local file="$1" expected="$2" _
  for _ in $(seq 1 $HTS_WAIT_POLLS); do
    [[ "$(hts_record_text "$file" slug 2>/dev/null || true)" = "$expected" ]] && return 0
    sleep 0.01
  done
  return 1
}
