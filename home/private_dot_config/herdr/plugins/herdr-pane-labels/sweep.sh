#!/bin/sh
# Request one immediate pass through the same session presentation coordinator.
sync="$HOME/.local/bin/herdr-task-sync"
[ -x "$sync" ] || exit 0
"$sync" --sweep >/dev/null 2>&1 || true
exit 0
