#!/usr/bin/env bash

set -uo pipefail

input="$(cat)" || {
  printf '%s\n' 'claude worktree remove: could not read hook input' >&2
  exit 1
}

path="$(printf '%s\n' "$input" |
  sed -n 's/.*"worktree_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
  sed -n '1p')"

if [ -z "$path" ]; then
  printf '%s\n' 'claude worktree remove: input needs worktree_path' >&2
  exit 1
fi

case "$path" in
  *\\*)
    printf '%s\n' 'claude worktree remove: input contains a JSON escape' >&2
    exit 1
    ;;
esac

if [ ! -e "$path" ] && [ ! -L "$path" ]; then
  exit 0
fi

if [ ! -d "$path" ]; then
  printf '%s\n' 'claude worktree remove: path is not a directory' >&2
  exit 1
fi

path_real="$(cd "$path" 2>/dev/null && pwd -P)" || {
  printf '%s\n' 'claude worktree remove: could not resolve worktree path' >&2
  exit 1
}

if [ ! -f "$path/.git" ]; then
  printf '%s\n' 'claude worktree remove: path is not a linked worktree' >&2
  exit 1
fi

worktrees="$(git -C "$path" worktree list --porcelain 2>/dev/null)" || {
  printf '%s\n' 'claude worktree remove: path is not a Git worktree' >&2
  exit 1
}

registered_path_from_git="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || {
  printf '%s\n' 'claude worktree remove: path is not a Git worktree' >&2
  exit 1
}

registered=1
nested_registered=1
main_root=''
while IFS= read -r line; do
  case "$line" in
    worktree\ *)
      registered_path="${line#worktree }"
      if [ -z "$main_root" ]; then
        main_root="$registered_path"
      fi
      if [ "$registered_path" = "$path" ] || [ "$registered_path" = "$path_real" ] || [ "$registered_path" = "$registered_path_from_git" ]; then
        registered=0
      fi
      case "$registered_path" in
        "$path_real"/*) nested_registered=0 ;;
      esac
      ;;
  esac
done <<EOF
$worktrees
EOF

if [ "$registered" -ne 0 ] || [ -z "$main_root" ]; then
  printf '%s\n' 'claude worktree remove: path is not a registered linked worktree' >&2
  exit 1
fi

if [ "$nested_registered" -eq 0 ]; then
  printf '%s\n' 'claude worktree remove: refusing to remove a path that contains another registered worktree' >&2
  exit 1
fi

branch="$(git -C "$path" branch --show-current 2>/dev/null)"
contained=1
if [ -n "$branch" ] && [[ "$branch" == worktree-* ]]; then
  refs="$(git -C "$main_root" for-each-ref --format='%(refname)' refs/heads refs/remotes 2>/dev/null)" || refs=''
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    [ "$ref" = "refs/heads/$branch" ] && continue
    if git -C "$main_root" merge-base --is-ancestor "refs/heads/$branch" "$ref" >/dev/null 2>&1; then
      contained=0
      break
    fi
  done <<EOF
$refs
EOF
fi

if ! git -C "$main_root" worktree remove --force "$path"; then
  printf '%s\n' 'claude worktree remove: git worktree remove failed' >&2
  exit 1
fi

if [ -n "$branch" ] && [[ "$branch" == worktree-* ]]; then
  if [ "$contained" -eq 0 ]; then
    if ! git -C "$main_root" branch -D -- "$branch" >/dev/null 2>&1; then
      printf 'claude worktree remove: kept branch %s (branch deletion failed)\n' "$branch" >&2
    fi
  else
    printf 'claude worktree remove: kept branch %s (tip is not contained)\n' "$branch" >&2
  fi
fi

exit 0
