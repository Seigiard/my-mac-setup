#!/bin/sh
# Start the label sweep daemon unless one already runs. Safe to call as often
# as herdr fires events: a live daemon turns this into a no-op.
exec "$HOME/.local/bin/herdr-task-sync" --ensure-daemon
