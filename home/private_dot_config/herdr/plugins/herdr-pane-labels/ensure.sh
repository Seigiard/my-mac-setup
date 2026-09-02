#!/bin/sh
# Startup ensures the fallback daemon; lifecycle hooks request reconciliation.
# Both paths stay silent and fail open so plugin failures never affect Herdr.
labels="$HOME/.local/bin/herdr-pane-labels"
[ -x "$labels" ] || exit 0

case "${1:-}" in
  --event)
    "$labels" --event >/dev/null 2>&1 || true
    ;;
  ''|--ensure-sweep-daemon)
    "$labels" --ensure-sweep-daemon >/dev/null 2>&1 || true
    ;;
esac

exit 0
