#!/usr/bin/env bash
set -euo pipefail

target=${1:-}

if [[ -z "$target" ]]; then
  echo "Usage: $0 <org/repo|deepwiki-url>" >&2
  exit 2
fi

case "$target" in
  https://deepwiki.com/*|http://deepwiki.com/*)
    url="$target"
    ;;
  */*)
    url="https://deepwiki.com/${target}"
    ;;
  *)
    echo "Target must be org/repo or https://deepwiki.com/org/repo" >&2
    exit 2
    ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
"$script_dir/jina-read.sh" "$url"
