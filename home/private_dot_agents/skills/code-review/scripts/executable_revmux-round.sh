#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'usage: revmux-round.sh next --task <id> [--run <NN-label>] [--base <sha>] [--workdir <path>] [--profile <name>]' \
    '       [--only <pathspec>]... [--note <text> | --note -] [--candidate <path.json>] [--exclude <text>] [--context-file <path>]' \
    '       [--out-dir <dir>]' \
    '       [--tasks-dir <dir>] [--prepare-only] [--wait]' \
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

limit_lines() {
  local content="$1"
  local limit="$2"
  local line
  local count=0

  [ -n "$content" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    count=$((count + 1))
    if [ "$count" -le "$limit" ]; then
      printf '%s\n' "$line"
    fi
  done <<EOF
$content
EOF

  if [ "$count" -gt "$limit" ]; then
    printf '… and %s more\n' "$((count - limit))"
  fi
}

count_lines() {
  local content="$1"
  local line
  local count=0

  [ -n "$content" ] || {
    printf '0\n'
    return 0
  }

  while IFS= read -r line || [ -n "$line" ]; do
    count=$((count + 1))
  done <<EOF
$content
EOF

  printf '%s\n' "$count"
}

build_scope() {
  local run_name="$1"
  local task="$2"
  local base="$3"
  local tip="$4"
  local scale="$5"
  local commits="$6"
  local changed_files="$7"
  local round_number="$8"
  local note_given="$9"
  local note="${10}"
  local candidate_given="${11}"
  local candidate_entries="${12}"
  local only_count="${13}"
  local exclusion
  local index
  local pathspec
  local separator=""
  local only_values=()

  shift 13
  for ((index = 0; index < only_count; index++)); do
    only_values[$index]="$1"
    shift
  done

  printf '# Scope\n\n'
  printf 'Round %s of task %s: review the cumulative change against base %s, including the fixes since the previous round.\n\n' \
    "$run_name" "$task" "$base"
  printf 'Tip: %s\n' "$tip"
  printf 'Scale: %s\n' "$scale"
  if [ "$only_count" -gt 0 ]; then
    printf 'Limited to: '
    for pathspec in "${only_values[@]}"; do
      printf '%s%s' "$separator" "$pathspec"
      separator=', '
    done
    printf '\n'
  fi
  printf '\n'
  printf 'Read the change:\n\n```\n'
  printf 'git diff %s..HEAD' "$base"
  if [ "$only_count" -gt 0 ]; then
    printf ' --'
    for pathspec in "${only_values[@]}"; do
      printf ' %q' "$pathspec"
    done
  fi
  printf '\n'
  printf 'git log --oneline %s..HEAD' "$base"
  if [ "$only_count" -gt 0 ]; then
    printf ' --'
    for pathspec in "${only_values[@]}"; do
      printf ' %q' "$pathspec"
    done
  fi
  printf '\n'
  printf '```\n\nCommits:\n\n```\n%s\n```\n\nChanged files:\n\n```\n%s\n```\n' \
    "$commits" "$changed_files"
  if [ "$candidate_given" = true ]; then
    printf '\nCandidate:\n\n%s\n' "$candidate_entries"
  fi
  if [ "$#" -gt 0 ]; then
    printf '\nExclusions:\n\n'
    for exclusion in "$@"; do
      printf -- '- %s\n' "$exclusion"
    done
  fi
  if [ "$note_given" = true ]; then
    printf '\n## ROUND %s UPDATE\n\n%s\n' "$round_number" "$note"
  fi
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
  local candidate_file=""
  local candidate_given=false
  local candidate_entries=""
  local invalid_candidate_key=""
  local only_values=()
  local exclude_values=()
  local context_file_values=()
  local only_count=0
  local exclusion_count=0
  local context_file_count=0
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
  local index=0
  local highest=0
  local prefix=""
  local number=0
  local new_result=""
  local round_dir=""
  local scope=""
  local goal=""
  local context=""
  local scope_without_optional_sections=""
  local scope_through_candidate=""
  local scope_through_exclusions=""
  local overflow_section=""
  local goal_state=absent
  local context_files=0
  local tip=""
  local scale=""
  local commits=""
  local changed_files=""
  local only_match=""
  local limited_commits=""
  local limited_changed_files=""
  local commit_count=0
  local changed_file_count=0
  local visible_commits=0
  local visible_changed_files=0
  local scope_args=()
  local scope_text=""
  local scope_characters=0
  local section_scope_characters=0
  local goal_characters=0
  local round_number=""
  local json_file=""
  local log_file=""
  local exit_file=""
  local pid=""
  local exit_status=""
  local launch_args=()
  local launch_wrapper=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task|--run|--base|--workdir|--profile|--out-dir|--tasks-dir|--only|--exclude|--context-file|--candidate)
        [ "$#" -gt 1 ] || { usage; return 1; }
        case "$1" in
          --task) task="$2" ;;
          --run) run_name="$2" ;;
          --base) base="$2" ;;
          --workdir) workdir="$2" ;;
          --profile) profile="$2" ;;
          --out-dir) out_dir="$2" ;;
          --tasks-dir) tasks_dir="$2"; tasks_dir_given=true ;;
          --only)
            only_values[$only_count]="$2"
            only_count=$((only_count + 1))
            ;;
          --candidate) candidate_file="$2"; candidate_given=true ;;
          --exclude)
            exclude_values[$exclusion_count]="$2"
            exclusion_count=$((exclusion_count + 1))
            ;;
          --context-file)
            context_file_values[$context_file_count]="$2"
            context_file_count=$((context_file_count + 1))
            ;;
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
    if [ "$candidate_name" = "$run_name" ]; then
      continue
    fi
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

  if [ -z "$run_name" ]; then
    run_name="$(printf '%02d-after-fix' $((highest + 1)))"
  fi

  if [ -d "$task_dir/$run_name" ]; then
    error "round $run_name already exists in task $task"
    return 1
  fi

  if [ -z "$previous_round" ]; then
    error "task $task has no previous round; author round 1 with the revmux skill"
    return 1
  fi

  if [ -z "$base" ]; then
    base="$(printf '%s\n' "$config_result" | jq -r --arg task "$task" \
      '.paths.tasks[] | select(.id == $task) | .base')"
  fi
  if [ -z "$base" ] || [ "$base" = "null" ]; then
    error "no base for task $task; pass --base"
    return 1
  fi

  for ((index = 0; index < context_file_count; index++)); do
    candidate="${context_file_values[$index]}"
    [ -f "$candidate" ] || {
      error "context file $candidate not found"
      return 1
    }
  done

  if [ "$candidate_given" = true ]; then
    [ -f "$candidate_file" ] || {
      error "candidate file $candidate_file not found"
      return 1
    }
    if ! jq empty "$candidate_file" >/dev/null 2>&1; then
      error "candidate file $candidate_file is not valid JSON"
      return 1
    fi
    if ! jq -se 'length == 1 and (.[0] | type == "object")' "$candidate_file" >/dev/null; then
      error "candidate file $candidate_file is not an object"
      return 1
    fi

    invalid_candidate_key="$(jq -r '([to_entries[] | select(.key | ((test("^[A-Za-z0-9_.-]+$") and (test("[\\r\\n]") | not)) | not)) | .key] | first // empty) | @json' "$candidate_file")"
    if [ -n "$invalid_candidate_key" ]; then
      error "candidate key $invalid_candidate_key is invalid"
      return 1
    fi
    invalid_candidate_key="$(jq -r '([to_entries[] | select((.value | type) != "string") | .key] | first // empty) | @json' "$candidate_file")"
    if [ -n "$invalid_candidate_key" ]; then
      error "candidate value for key $invalid_candidate_key is not a string"
      return 1
    fi
    invalid_candidate_key="$(jq -r '([to_entries[] | select(.value == "") | .key] | first // empty) | @json' "$candidate_file")"
    if [ -n "$invalid_candidate_key" ]; then
      error "candidate value for key $invalid_candidate_key is empty"
      return 1
    fi
    invalid_candidate_key="$(jq -r '([to_entries[] | select(.value | test("[\\r\\n]")) | .key] | first // empty) | @json' "$candidate_file")"
    if [ -n "$invalid_candidate_key" ]; then
      error "candidate value for key $invalid_candidate_key contains a line break"
      return 1
    fi
    candidate_entries="$(jq -r 'to_entries[] | "\(.key): \(.value)"' "$candidate_file")"
  fi

  for ((index = 0; index < only_count; index++)); do
    candidate="${only_values[$index]}"
    if ! only_match="$(git -C "$workdir" diff --name-only "$base..HEAD" -- "$candidate")"; then
      error "cannot evaluate --only pathspec $candidate"
      return 1
    fi
    if [ -z "$only_match" ]; then
      error "--only pathspec $candidate matches no changes in $base..HEAD"
      return 1
    fi
  done

  if [ "$only_count" -gt 0 ]; then
    if ! only_match="$(git -C "$workdir" diff --name-only "$base..HEAD" -- "${only_values[@]}")"; then
      error "cannot evaluate combined --only pathspecs"
      return 1
    fi
    if [ -z "$only_match" ]; then
      error "combined --only pathspecs match no changes in $base..HEAD"
      return 1
    fi
  fi

  tip="$(git -C "$workdir" rev-parse HEAD)"
  if [ "$only_count" -gt 0 ]; then
    scale="$(git -C "$workdir" diff --shortstat "$base..HEAD" -- "${only_values[@]}")"
  else
    scale="$(git -C "$workdir" diff --shortstat "$base..HEAD")"
  fi
  scale="${scale#"${scale%%[![:space:]]*}"}"
  [ -n "$scale" ] || scale="no changes"
  if [ "$only_count" -gt 0 ]; then
    commits="$(git -C "$workdir" log --oneline "$base..HEAD" -- "${only_values[@]}")"
    changed_files="$(git -C "$workdir" diff --name-status "$base..HEAD" -- "${only_values[@]}")"
  else
    commits="$(git -C "$workdir" log --oneline "$base..HEAD")"
    changed_files="$(git -C "$workdir" diff --name-status "$base..HEAD")"
  fi
  commit_count="$(count_lines "$commits")"
  changed_file_count="$(count_lines "$changed_files")"
  visible_commits="$commit_count"
  visible_changed_files="$changed_file_count"
  if [ "$visible_commits" -gt 10 ]; then
    visible_commits=10
  fi
  if [ "$visible_changed_files" -gt 20 ]; then
    visible_changed_files=20
  fi
  round_number="${run_name%%-*}"

  while :; do
    limited_commits="$(limit_lines "$commits" "$visible_commits")"
    limited_changed_files="$(limit_lines "$changed_files" "$visible_changed_files")"
    scope_args=("$run_name" "$task" "$base" "$tip" "$scale" "$limited_commits" \
      "$limited_changed_files" "$round_number" "$note_given" "$note" \
      "$candidate_given" "$candidate_entries" "$only_count")
    for ((index = 0; index < only_count; index++)); do
      scope_args[${#scope_args[@]}]="${only_values[$index]}"
    done
    for ((index = 0; index < exclusion_count; index++)); do
      scope_args[${#scope_args[@]}]="${exclude_values[$index]}"
    done
    scope_text="$(build_scope "${scope_args[@]}")"
    scope_characters="$(printf '%s\n' "$scope_text" | wc -m)"
    scope_characters="${scope_characters//[[:space:]]/}"
    [ "$scope_characters" -le 1500 ] && break

    if [ "$visible_changed_files" -gt 0 ]; then
      visible_changed_files=$((visible_changed_files - 1))
    elif [ "$visible_commits" -gt 0 ]; then
      visible_commits=$((visible_commits - 1))
    else
      scope_args=("$run_name" "$task" "$base" "$tip" "$scale" "$limited_commits" \
        "$limited_changed_files" "$round_number" false "" false "" "$only_count")
      for ((index = 0; index < only_count; index++)); do
        scope_args[${#scope_args[@]}]="${only_values[$index]}"
      done
      scope_without_optional_sections="$(build_scope "${scope_args[@]}")"
      section_scope_characters="$(printf '%s\n' "$scope_without_optional_sections" | wc -m)"
      section_scope_characters="${section_scope_characters//[[:space:]]/}"

      if [ "$section_scope_characters" -le 1500 ] && [ "$candidate_given" = true ]; then
        scope_args=("$run_name" "$task" "$base" "$tip" "$scale" "$limited_commits" \
          "$limited_changed_files" "$round_number" false "" true "$candidate_entries" "$only_count")
        for ((index = 0; index < only_count; index++)); do
          scope_args[${#scope_args[@]}]="${only_values[$index]}"
        done
        scope_through_candidate="$(build_scope "${scope_args[@]}")"
        section_scope_characters="$(printf '%s\n' "$scope_through_candidate" | wc -m)"
        section_scope_characters="${section_scope_characters//[[:space:]]/}"
        if [ "$section_scope_characters" -gt 1500 ]; then
          overflow_section=Candidate
        fi
      fi

      if [ -z "$overflow_section" ] && [ "$section_scope_characters" -le 1500 ] && [ "$exclusion_count" -gt 0 ]; then
        scope_args=("$run_name" "$task" "$base" "$tip" "$scale" "$limited_commits" \
          "$limited_changed_files" "$round_number" false "" \
          "$candidate_given" "$candidate_entries" "$only_count")
        for ((index = 0; index < only_count; index++)); do
          scope_args[${#scope_args[@]}]="${only_values[$index]}"
        done
        for ((index = 0; index < exclusion_count; index++)); do
          scope_args[${#scope_args[@]}]="${exclude_values[$index]}"
        done
        scope_through_exclusions="$(build_scope "${scope_args[@]}")"
        section_scope_characters="$(printf '%s\n' "$scope_through_exclusions" | wc -m)"
        section_scope_characters="${section_scope_characters//[[:space:]]/}"
        if [ "$section_scope_characters" -gt 1500 ]; then
          overflow_section=Exclusions
        fi
      fi

      if [ -z "$overflow_section" ] && [ "$section_scope_characters" -le 1500 ] \
        && [ "$note_given" = true ]; then
        overflow_section=Note
      fi

      if [ -n "$overflow_section" ]; then
        error "$overflow_section section makes scope.md $scope_characters characters; the limit is 1500"
      else
        error "scope.md is $scope_characters characters; the limit is 1500"
      fi
      return 1
    fi
  done

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
  fi

  if [ "$candidate_given" = false ]; then
    rm -f "$context/candidate.json"
  fi

  for ((index = 0; index < context_file_count; index++)); do
    candidate="${context_file_values[$index]}"
    mkdir -p "$context"
    cp "$candidate" "$context/${candidate##*/}"
  done

  if [ "$candidate_given" = true ]; then
    mkdir -p "$context"
    cp "$candidate_file" "$context/candidate.json"
  fi

  if [ -d "$context" ]; then
    count_files "$context"
  fi

  printf '%s\n' "$scope_text" > "$scope"

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
  rm -f "$json_file" "$log_file" "$exit_file"

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

  launch_wrapper=(nohup)
  if command -v setsid >/dev/null 2>&1; then
    launch_wrapper+=(setsid)
  fi
  "${launch_wrapper[@]}" bash -c 'json_file=$1; log_file=$2; exit_file=$3; exit_temp="$exit_file.tmp.$$"; shift 3; "$@" > "$json_file" 2> "$log_file"; status=$?; printf "%s\\n" "$status" > "$exit_temp" && mv "$exit_temp" "$exit_file"' \
    bash "$json_file" "$log_file" "$exit_file" "${launch_args[@]}" </dev/null >/dev/null 2>&1 &
  pid="$!"

  printf 'launched: true\n'
  printf 'json: %s\n' "$json_file"
  printf 'log: %s\n' "$log_file"
  printf 'exit_file: %s\n' "$exit_file"
  printf 'pid: %s\n' "$pid"

  if [ "$wait_for_exit" = true ]; then
    while [ ! -f "$exit_file" ]; do
      if ! kill -0 "$pid" 2>/dev/null && [ ! -f "$exit_file" ]; then
        error "revmux launcher exited without writing $exit_file"
        return 2
      fi
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
