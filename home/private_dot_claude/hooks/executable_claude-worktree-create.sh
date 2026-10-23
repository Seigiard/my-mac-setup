#!/usr/bin/env bash

set -uo pipefail

input="$(cat)" || {
  printf '%s\n' 'claude worktree create: could not read hook input' >&2
  exit 1
}

json_string() {
  local key="$1"
  printf '%s\n' "$input" |
    sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" |
    sed -n '1p'
}

name="$(json_string name)"
cwd="$(json_string cwd)"

if [ -z "$name" ] || [ -z "$cwd" ]; then
  printf '%s\n' 'claude worktree create: input needs name and cwd' >&2
  exit 1
fi

case "$name" in
  *\\*)
    printf '%s\n' 'claude worktree create: input contains a JSON escape' >&2
    exit 1
    ;;
esac
case "$cwd" in
  *\\*)
    printf '%s\n' 'claude worktree create: input contains a JSON escape' >&2
    exit 1
    ;;
esac

case "$name" in
  .|..|*/*)
    printf '%s\n' 'claude worktree create: invalid worktree name' >&2
    exit 1
    ;;
esac

case "$cwd" in
  /*) ;;
  *) cwd="$PWD/$cwd" ;;
esac
while [ "$cwd" != '/' ] && [ "${cwd%/}" != "$cwd" ]; do
  cwd="${cwd%/}"
done
git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || {
  printf '%s\n' 'claude worktree create: cwd is not a Git checkout' >&2
  exit 1
}

cdup="$(git -C "$cwd" rev-parse --show-cdup 2>/dev/null)" || {
  printf '%s\n' 'claude worktree create: could not locate checkout root' >&2
  exit 1
}
root="$cwd"
while [ -n "$cdup" ]; do
  case "$cdup" in
    ../*)
      root="${root%/*}"
      cdup="${cdup#../}"
      ;;
    ./*) cdup="${cdup#./}" ;;
    *) break ;;
  esac
done

path="$root/.claude/worktrees/$name"
root_real="$(cd "$root" 2>/dev/null && pwd -P)" || {
  printf '%s\n' 'claude worktree create: could not resolve checkout root' >&2
  exit 1
}
path_real="$root_real/.claude/worktrees/$name"
branch="worktree-$name"

if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
  printf '%s\n' 'claude worktree create: invalid worktree branch name' >&2
  exit 1
fi

worktrees="$(git -C "$root" worktree list --porcelain 2>/dev/null)" || {
  printf '%s\n' 'claude worktree create: could not inspect Git worktrees' >&2
  exit 1
}

registered=1
registered_path=''
registered_path_from_git=''
if [ -f "$path/.git" ]; then
  registered_path_from_git="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || registered_path_from_git=''
fi
check_registered_worktree() {
  registered=1
  registered_path=''
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        registered_path="${line#worktree }"
        if [ "$registered_path" = "$path" ] || [ "$registered_path" = "$path_real" ]; then
          registered=0
          break
        elif [ -n "$registered_path_from_git" ] && [ "$registered_path" = "$registered_path_from_git" ]; then
          registered=0
          break
        fi
        ;;
    esac
  done <<EOF
$worktrees
EOF
}

check_registered_worktree

if [ "$registered" -eq 0 ] && [ ! -e "$path" ] && [ ! -L "$path" ]; then
  if ! git -C "$root" worktree remove --force "$registered_path" >/dev/null 2>&1; then
    printf '%s\n' 'claude worktree create: could not prune stale worktree registration' >&2
    exit 1
  fi
  worktrees="$(git -C "$root" worktree list --porcelain 2>/dev/null)" || {
    printf '%s\n' 'claude worktree create: could not inspect Git worktrees' >&2
    exit 1
  }
  check_registered_worktree
fi

if [ "$registered" -eq 0 ]; then
  printf '%s\n' "$path"
  exit 0
fi

mkdir -p "$root/.claude/worktrees" || {
  printf '%s\n' 'claude worktree create: could not create worktree parent' >&2
  exit 1
}

base='HEAD'
if git -C "$root" rev-parse --verify --quiet 'origin/HEAD^{commit}' >/dev/null 2>&1; then
  base='origin/HEAD'
fi

if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
  if ! git -C "$root" worktree add -q "$path" "$branch"; then
    exit 1
  fi
elif ! git -C "$root" worktree add -q -b "$branch" "$path" "$base"; then
  exit 1
fi

plugin_dir="${CLAUDE_WORKTREE_SETUP_PLUGIN_DIR:-}"
setup_skip_reason=''
if [ -z "$plugin_dir" ]; then
  if ! command -v herdr >/dev/null 2>&1; then
    setup_skip_reason='claude worktree create: setup skipped (herdr not found)'
  elif ! command -v jq >/dev/null 2>&1; then
    setup_skip_reason='claude worktree create: setup skipped (jq not found)'
  elif ! plugin_json="$(herdr plugin list --json </dev/null 2>/dev/null)"; then
    setup_skip_reason='claude worktree create: setup skipped (herdr plugin list failed)'
  elif ! printf '%s\n' "$plugin_json" | jq empty >/dev/null 2>&1; then
    setup_skip_reason='claude worktree create: setup skipped (plugin list is not valid JSON)'
  else
    plugin_dir="$(printf '%s\n' "$plugin_json" |
      jq -r '.result.plugins[]? | select((type == "object") and (.plugin_id == "seigi.worktree-setup") and (.enabled == true)) | .plugin_root // empty' |
      sed -n '1p')"
    if [ -z "$plugin_dir" ]; then
      setup_skip_reason='claude worktree create: setup skipped (worktree setup plugin is not enabled)'
    fi
  fi
fi
config_dir="${CLAUDE_WORKTREE_SETUP_CONFIG_DIR:-$HOME/.config/herdr/plugins/config/seigi.worktree-setup}"

if [ -n "$setup_skip_reason" ]; then
  printf '%s\n' "$setup_skip_reason" >&2
elif [ ! -f "$plugin_dir/setup.ts" ]; then
  printf '%s\n' 'claude worktree create: setup skipped (setup.ts not found)' >&2
elif ! command -v bun >/dev/null 2>&1; then
  printf '%s\n' 'claude worktree create: setup skipped (bun not found)' >&2
else
  escaped_path="$(printf '%s' "$path" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  event="{\"data\":{\"worktree\":{\"path\":\"$escaped_path\",\"branch\":\"\"}}}"
  if ! (
    cd "$plugin_dir" || exit 1
    HERDR_PLUGIN_EVENT_JSON="$event" \
      HERDR_PLUGIN_CONFIG_DIR="$config_dir" \
      PWD="$plugin_dir" \
      bun setup.ts
  ) >&2; then
    printf '%s\n' 'claude worktree create: setup failed (creation retained)' >&2
  fi
fi

printf '%s\n' "$path"
