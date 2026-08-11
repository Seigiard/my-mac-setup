#!/bin/sh
# One immediate pass over every tab, for when waiting out the interval is not
# worth it. The daemon keeps running either way.
exec "$HOME/.local/bin/herdr-task-sync" --sweep
