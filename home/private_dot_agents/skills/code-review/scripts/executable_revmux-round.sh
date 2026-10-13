#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'usage: revmux-round.sh next --task <id> [--run <NN-label>] [--base <sha>] [--workdir <path>] [--profile <name>]' \
    '       [--note <text> | --note -] [--out-dir <dir>] [--tasks-dir <dir>] [--prepare-only] [--wait]' \
    '       revmux-round.sh summary <report.json>' >&2
}

error() {
  printf 'error: %s\n' "$*" >&2
}

count_files() {
  local entry

  for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$entry" ] || continue
    if [ -f "$entry" ]; then
      context_files=$((context_files + 1))
    elif [ -d "$entry" ]; then
      count_files "$entry"
    fi
  done
}

remove_created_round() {
  if printf '%s\n' "$new_result" | jq -e --arg round "$round_dir" \
    '.created | index("round_dir") != null' >/dev/null; then
    rm -rf "$round_dir"
  fi
}

next() {
  local task=""
  local run_name=""
  local base=""
  local workdir="$PWD"
  local profile=""
  local note=""
  local note_given=false
  local out_dir=""
  local tasks_dir=""
  local tasks_dir_given=false
  local prepare_only=false
  local wait_for_exit=false
  local config_result=""
  local task_dir=""
  local previous_round=""
  local candidate=""
  local candidate_name=""
  local highest=0
  local prefix=""
  local number=0
  local new_result=""
  local round_dir=""
  local scope=""
  local goal=""
  local context=""
  local goal_state=absent
  local context_files=0
  local tip=""
  local scale=""
  local commits=""
  local changed_files=""
  local scope_characters=0
  local goal_characters=0
  local round_number=""
  local json_file=""
  local log_file=""
  local exit_file=""
  local pid=""
  local exit_status=""
  local launch_args=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task|--run|--base|--workdir|--profile|--out-dir|--tasks-dir)
        [ "$#" -gt 1 ] || { usage; return 1; }
        case "$1" in
          --task) task="$2" ;;
          --run) run_name="$2" ;;
          --base) base="$2" ;;
          --workdir) workdir="$2" ;;
          --profile) profile="$2" ;;
          --out-dir) out_dir="$2" ;;
          --tasks-dir) tasks_dir="$2"; tasks_dir_given=true ;;
        esac
        shift 2
        ;;
      --note)
        [ "$#" -gt 1 ] || { usage; return 1; }
        note_given=true
        if [ "$2" = "-" ]; then
          note="$(< /dev/stdin)"
        else
          note="$2"
        fi
        shift 2
        ;;
      --prepare-only)
        prepare_only=true
        shift
        ;;
      --wait)
        wait_for_exit=true
        shift
        ;;
      *)
        usage
        return 1
        ;;
    esac
  done

  [ -n "$task" ] || { usage; return 1; }

  if [ "$tasks_dir_given" = true ]; then
    config_result="$(revmux config --tasks-dir "$tasks_dir")"
  else
    config_result="$(revmux config)"
    tasks_dir="$(printf '%s\n' "$config_result" | jq -r '.paths.tasks_dir')"
  fi

  task_dir="$tasks_dir/$task"
  if [ ! -d "$task_dir" ]; then
    error "task $task has no previous round; author round 1 with the revmux skill"
    return 1
  fi

  for candidate in "$task_dir"/*; do
    [ -d "$candidate" ] || continue
    candidate_name="${candidate##*/}"
    if [ -z "$previous_round" ] || [[ "$candidate_name" > "${previous_round##*/}" ]]; then
      previous_round="$candidate"
    fi
    case "$candidate_name" in
      [0-9][0-9]-*)
        prefix="${candidate_name%%-*}"
        number=$(( ${prefix#0} + 0 ))
        if [ "$number" -gt "$highest" ]; then
          highest="$number"
        fi
        ;;
    esac
  done

  if [ -z "$previous_round" ]; then
    error "task $task has no previous round; author round 1 with the revmux skill"
    return 1
  fi

  if [ -z "$run_name" ]; then
    run_name="$(printf '%02d-after-fix' $((highest + 1)))"
  fi

  if [ "$tasks_dir_given" = true ]; then
    new_result="$(revmux new --task "$task" --run "$run_name" --tasks-dir "$tasks_dir")"
  else
    new_result="$(revmux new --task "$task" --run "$run_name")"
  fi
  round_dir="$(printf '%s\n' "$new_result" | jq -r '.round_dir')"
  scope="$(printf '%s\n' "$new_result" | jq -r '.scope')"
  goal="$(printf '%s\n' "$new_result" | jq -r '.goal')"
  context="$(printf '%s\n' "$new_result" | jq -r '.context')"

  if [ -f "$previous_round/input/goal.md" ]; then
    cp "$previous_round/input/goal.md" "$goal"
    goal_state=copied
  fi

  if [ -d "$previous_round/input/context" ]; then
    mkdir -p "$context"
    cp -R "$previous_round/input/context/." "$context"
    count_files "$context"
  fi

  if [ -z "$base" ]; then
    base="$(printf '%s\n' "$config_result" | jq -r --arg task "$task" \
      '.paths.tasks[] | select(.id == $task) | .base')"
  fi
  if [ -z "$base" ] || [ "$base" = "null" ]; then
    error "no base for task $task; pass --base"
    remove_created_round
    return 1
  fi

  tip="$(git -C "$workdir" rev-parse HEAD)"
  scale="$(git -C "$workdir" diff --shortstat "$base..HEAD")"
  scale="${scale#"${scale%%[![:space:]]*}"}"
  [ -n "$scale" ] || scale="no changes"
  commits="$(git -C "$workdir" log --oneline "$base..HEAD")"
  changed_files="$(git -C "$workdir" diff --name-status "$base..HEAD")"
  round_number="${run_name%%-*}"

  {
    printf '# Scope\n\n'
    printf 'Round %s of task %s: review the cumulative change against base %s, including the fixes since the previous round.\n\n' \
      "$run_name" "$task" "$base"
    printf 'Tip: %s\n' "$tip"
    printf 'Scale: %s\n\n' "$scale"
    printf 'Read the change:\n\n```\n'
    printf 'git diff %s..HEAD\n' "$base"
    printf 'git log --oneline %s..HEAD\n' "$base"
    printf '```\n\nCommits:\n\n```\n%s\n```\n\nChanged files:\n\n```\n%s\n```\n' \
      "$commits" "$changed_files"
    if [ "$note_given" = true ]; then
      printf '\n## ROUND %s UPDATE\n\n%s\n' "$round_number" "$note"
    fi
  } > "$scope"

  scope_characters="$(wc -m < "$scope")"
  scope_characters="${scope_characters//[[:space:]]/}"
  if [ "$scope_characters" -gt 1500 ]; then
    error "scope.md is $scope_characters characters; the limit is 1500"
    remove_created_round
    return 1
  fi

  if [ "$goal_state" = copied ]; then
    goal_characters="$(wc -m < "$goal")"
    goal_characters="${goal_characters//[[:space:]]/}"
    if [ "$goal_characters" -gt 1000 ]; then
      error "goal.md is $goal_characters characters; the limit is 1000"
      remove_created_round
      return 1
    fi
  fi

  printf 'task: %s\n' "$task"
  printf 'run: %s\n' "$run_name"
  printf 'round_dir: %s\n' "$round_dir"
  printf 'scope: %s\n' "$scope"
  printf 'goal: %s\n' "$goal_state"
  printf 'context: %s\n' "$context_files"
  printf 'base: %s\n' "$base"
  printf 'tip: %s\n' "$tip"
  printf 'scale: %s\n' "$scale"

  if [ "$prepare_only" = true ]; then
    printf 'launched: false\n'
    return 0
  fi

  if [ -z "$out_dir" ]; then
    out_dir="$HOME/.claude/artifacts/review-$task"
  fi
  mkdir -p "$out_dir"
  json_file="$out_dir/$run_name.json"
  log_file="$out_dir/$run_name.log"
  exit_file="$out_dir/$run_name.exit"

  launch_args=(revmux --task "$task" --run "$run_name" --no-tui)
  if [ "$tasks_dir_given" = true ]; then
    launch_args+=(--tasks-dir "$tasks_dir")
  fi
  if [ -n "$profile" ]; then
    launch_args+=(--profile "$profile")
  fi
  if [ "$workdir" != "$PWD" ]; then
    launch_args+=(--workdir "$workdir")
  fi

  if command -v setsid >/dev/null 2>&1; then
    nohup setsid bash -c 'json_file=$1; log_file=$2; exit_file=$3; shift 3; "$@" > "$json_file" 2> "$log_file"; status=$?; printf "%s\\n" "$status" > "$exit_file"' \
      bash "$json_file" "$log_file" "$exit_file" "${launch_args[@]}" </dev/null >/dev/null 2>&1 &
  else
    nohup bash -c 'json_file=$1; log_file=$2; exit_file=$3; shift 3; "$@" > "$json_file" 2> "$log_file"; status=$?; printf "%s\\n" "$status" > "$exit_file"' \
      bash "$json_file" "$log_file" "$exit_file" "${launch_args[@]}" </dev/null >/dev/null 2>&1 &
  fi
  pid="$!"

  printf 'launched: true\n'
  printf 'json: %s\n' "$json_file"
  printf 'log: %s\n' "$log_file"
  printf 'exit_file: %s\n' "$exit_file"
  printf 'pid: %s\n' "$pid"

  if [ "$wait_for_exit" = true ]; then
    while [ ! -f "$exit_file" ]; do
      sleep 1
    done
    exit_status="$(< "$exit_file")"
    printf 'exit: %s\n' "$exit_status"
    case "$exit_status" in
      0|1) return 0 ;;
      *) return 2 ;;
    esac
  fi
}

summary() {
  local report="${1:-}"
  local projection
  local critical=0
  local major=0
  local minor=0

  projection="$(dirname "$0")/../projection.jq"

  if [ "$#" -ne 1 ] || [ ! -f "$report" ] || ! jq -e . "$report" >/dev/null 2>&1; then
    error "cannot parse report ${report:-<missing>}"
    return 2
  fi

  jq -r -f "$projection" "$report"
  critical="$(jq '[.findings[]? | select(.severity == "critical")] | length' "$report")"
  major="$(jq '[.findings[]? | select(.severity == "major")] | length' "$report")"
  minor="$(jq '[.findings[]? | select(.severity == "minor")] | length' "$report")"
  printf 'severity: critical %s, major %s, minor %s\n' "$critical" "$major" "$minor"
}

case "${1:-}" in
  next)
    shift
    next "$@"
    ;;
  summary)
    shift
    summary "$@"
    ;;
  *)
    usage
    exit 1
    ;;
esac
