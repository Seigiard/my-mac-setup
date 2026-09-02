#!/bin/sh
set -eu

# Remove only the files that chezmoi formerly owned. Preserve any unrelated
# content so a separately managed skill with the same name is not destroyed.
for directory in \
  "$HOME/.agents/skills/se-cleanup" \
  "$HOME/.claude/skills/se-cleanup"; do
  rm -f "$directory/SKILL.md"
  rmdir "$directory" 2>/dev/null || true
done
