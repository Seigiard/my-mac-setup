#!/bin/sh
# Herdr event hook for `pane.agent_status_changed`.
# Re-derives the truth from `herdr agent list` and makes the wake lock match:
# caffeinate is held iff at least one agent is in an AWAKE state.
set -u

DIR=${HERDR_PLUGIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
# shellcheck source=lib.sh disable=SC1091
. "$DIR/lib.sh"

reconcile
