#!/bin/sh
# Startup ensures the fallback daemon; lifecycle hooks request reconciliation.
# Both paths stay silent and fail open so plugin failures never affect Herdr.
sync="$HOME/.local/bin/herdr-task-sync"
[ -x "$sync" ] || exit 0

case "${1:-}" in
  --event)
    "$sync" --event >/dev/null 2>&1 || true
    ;;
  '') "$sync" --ensure-daemon >/dev/null 2>&1 || true ;;
esac

exit 0
