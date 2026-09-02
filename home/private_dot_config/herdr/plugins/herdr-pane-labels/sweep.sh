#!/bin/sh
# Request one immediate pass through the same session presentation coordinator.
labels="$HOME/.local/bin/herdr-pane-labels"
[ -x "$labels" ] || exit 0
"$labels" --sweep >/dev/null 2>&1 || true
exit 0
