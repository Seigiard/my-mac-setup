#!/bin/bash
# Expose the local Paseo daemon to this Mac's tailnet, so the Paseo app on
# another device connects directly (Settings -> Add host -> Direct connection,
# the Tailscale IP, port 6767, SSL off).
#
# Paseo's own Tailscale recipe sets daemon.listen to the Tailscale IP, but
# listen takes one address, and the desktop app reaches its daemon only on
# 127.0.0.1:6767. The daemon keeps the loopback default; Tailscale forwards the
# tailnet port to it. The serve entry lives in tailscaled's state, so this
# runs on every apply and changes nothing once the entry exists. Tailscale
# that is missing or logged out is skipped: the next apply retries.
#
# Roll back on a machine: tailscale serve --tcp=6767 off

set -euo pipefail

port=6767
target="127.0.0.1:${port}"

ts=$(command -v tailscale || true)
if [ -z "$ts" ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
  ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale
fi
if [ -z "$ts" ]; then
  echo "paseo: Tailscale is not installed; tailnet port ${port} not exposed"
  exit 0
fi

if ! "$ts" status >/dev/null 2>&1; then
  echo "paseo: Tailscale is not running or logged out; tailnet port ${port} not exposed"
  exit 0
fi

if "$ts" serve status --json 2>/dev/null |
  jq -e --arg port "$port" --arg target "$target" \
    '.TCP[$port].TCPForward == $target' >/dev/null 2>&1; then
  exit 0
fi

echo "paseo: exposing ${target} to the tailnet on port ${port}"
"$ts" serve --bg --tcp "$port" "tcp://${target}"
