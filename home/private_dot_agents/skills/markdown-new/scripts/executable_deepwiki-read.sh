#!/usr/bin/env bash
set -euo pipefail

target=${1:-}

if [[ -z "$target" ]]; then
  echo "Usage: $0 <org/repo|deepwiki-url>" >&2
  exit 2
fi

case "$target" in
  https://deepwiki.com/*|http://deepwiki.com/*)
    repo=${target#*://deepwiki.com/}
    repo=$(printf '%s' "$repo" | cut -d/ -f1-2)
    ;;
  */*)
    repo="$target"
    ;;
  *)
    echo "Target must be org/repo or https://deepwiki.com/org/repo" >&2
    exit 2
    ;;
esac

# deepwiki.com sits behind a Vercel bot check that URL-to-Markdown readers
# cannot pass; its keyless MCP endpoint answers a bare tools/call instead.
request=$(jq -cn --arg repo "$repo" \
  '{jsonrpc: "2.0", id: 1, method: "tools/call", params: {name: "read_wiki_contents", arguments: {repoName: $repo}}}')

curl -fsS https://mcp.deepwiki.com/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d "$request" \
  | sed -n 's/^data: //p' \
  | jq -er 'if .error then error(.error.message) else .result.content[].text end'
