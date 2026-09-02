#!/bin/sh
set -eu

# Remove only the last version chezmoi shipped. Preserve an independently
# installed skill that reused the retired name before this migration ran.
managed_hash="36113a10bc75938c779b9bc316cbecd28432df52fb77b30c2746c501b8e2cf28"
agents_directory="$HOME/.agents/skills/se-cleanup"
agents_file="$agents_directory/SKILL.md"
claude_directory="$HOME/.claude/skills/se-cleanup"
claude_file="$claude_directory/SKILL.md"
remove_managed=0

if [ ! -e "$agents_file" ] && [ ! -L "$agents_file" ]; then
  remove_managed=1
elif [ -f "$agents_file" ] && [ ! -L "$agents_file" ]; then
  if actual_hash="$(shasum -a 256 "$agents_file" 2>/dev/null | cut -d ' ' -f 1)" && \
    [ "$actual_hash" = "$managed_hash" ]; then
    remove_managed=1
  fi
fi

if [ "$remove_managed" -eq 1 ]; then
  if [ -L "$claude_file" ]; then
    link_target="$(readlink "$claude_file")"
    case "$link_target" in
      *".agents/skills/se-cleanup/SKILL.md")
        rm -f "$claude_file"
        ;;
    esac
  fi
  rmdir "$claude_directory" 2>/dev/null || true
  rm -f "$agents_file"
  rmdir "$agents_directory" 2>/dev/null || true
fi
