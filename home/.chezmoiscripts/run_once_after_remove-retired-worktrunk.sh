#!/bin/sh
set -eu

# Chezmoi stops owning deleted source files but does not remove deployed copies.
# Delete only files this repository previously managed and preserve other data.
for file in \
  "$HOME/.config/worktrunk/config.toml" \
  "$HOME/.config/herdr/plugins/config/worktrunk/config.toml" \
  "$HOME/.config/herdr/plugins/command-palette/new_worktree.py" \
  "$HOME/.config/herdr/plugins/command-palette/open_new_worktree.py"; do
  rm -f "$file"
done

rmdir "$HOME/.config/worktrunk" 2>/dev/null || true
rmdir "$HOME/.config/herdr/plugins/config/worktrunk" 2>/dev/null || true
