# shellcheck shell=sh
# Herdr Caffeinate plugin configuration.
#
# On first run this file is copied to $HERDR_PLUGIN_CONFIG_DIR/config.sh
# (usually ~/.config/herdr-caffeinate/config.sh). Edit THAT copy, not this
# template. Uncomment a line to change a default.

# Which agent states keep the Mac awake (space-separated).
#   working  - agent is actively computing            (default)
#   blocked  - agent is waiting for your input/approval
# Example, also stay awake when an agent is blocked on you:
#   AWAKE_STATES="working blocked"
# AWAKE_STATES="working"

# Flags passed to `caffeinate` while the lock is held:
#   -di   prevent system idle sleep AND keep the display on        (default)
#   -i    prevent system idle sleep only; the display may sleep
#   -is   only hold on AC power (lets the machine sleep on battery)
# CAFFEINATE_FLAGS="-di"

# How long to stay awake after the LAST agent goes quiet, in seconds.
# The wake lock is swapped for a time-limited `caffeinate -t` that expires on
# its own; an agent resuming work within the window restores the full lock.
#   0 = release immediately (upstream behavior)
# LINGER_SECONDS=1200
