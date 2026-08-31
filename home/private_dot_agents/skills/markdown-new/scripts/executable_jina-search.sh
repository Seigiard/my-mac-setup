#!/usr/bin/env bash
set -euo pipefail

query=${1:-}

if [[ -z "$query" ]]; then
  echo "Usage: $0 <query>" >&2
  exit 2
fi

encoded=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$query")
search_url="https://s.jina.ai/${encoded}"
headers=(-H "Accept: text/markdown")
if [[ -n "${JINA_API_KEY:-}" ]]; then
  headers+=(-H "Authorization: Bearer ${JINA_API_KEY}")
fi

curl -sS -L "${headers[@]}" "$search_url"
