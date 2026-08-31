#!/usr/bin/env bash
set -euo pipefail

url=${1:-}

if [[ -z "$url" ]]; then
  echo "Usage: $0 <url>" >&2
  exit 2
fi

case "$url" in
  http://*|https://*) ;;
  *)
    echo "URL must start with http:// or https://" >&2
    exit 2
    ;;
esac

reader_url="https://r.jina.ai/${url}"
headers=(-H "Accept: text/markdown")
if [[ -n "${JINA_API_KEY:-}" ]]; then
  headers+=(-H "Authorization: Bearer ${JINA_API_KEY}")
fi

curl -sS -L "${headers[@]}" "$reader_url"
