#!/bin/sh
# Codex weekly quota: the primary window's used_percent from the newest rollout file (codex writes one per session, revmux agents included).
f=$(ls -t "$HOME"/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -1)
[ -n "$f" ] || exit 1
grep -o '"rate_limits":{"limit_id":"codex"[^}]*"primary":{[^}]*}' "$f" | tail -1 | sed -n 's/.*"used_percent":\([0-9.]*\).*/\1/p'
