#!/usr/bin/env bash
# One call to the Membrane Dashboard (vector-prime) API: auth, base URL, status check.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: vp.sh <METHOD> <PATH> [JSON_BODY]

  METHOD     GET | POST | PATCH | DELETE
  PATH       API path starting with / — e.g. /workstreams
  JSON_BODY  request body; DELETE may carry one too

Env:
  VECTOR_PRIME_API_KEY  bearer token; falls back to 1Password when unset
  VECTOR_PRIME_API_URL  base URL, default https://vector.membranehq.com/api

Prints the response body on 2xx. On any other status prints status and body
to stderr and exits 1.
EOF
  exit 2
}

[ "$#" -ge 2 ] || usage

method=$1
path=$2
body=${3:-}

case "$path" in
  /*) ;;
  *)
    echo "vp.sh: PATH must start with / (got: $path)" >&2
    exit 2
    ;;
esac

base=${VECTOR_PRIME_API_URL:-https://vector.membranehq.com/api}

token=${VECTOR_PRIME_API_KEY:-}
if [ -z "$token" ] && command -v op >/dev/null 2>&1; then
  token=$(op read "op://Private/VectorPrime API Key/credential" 2>/dev/null || true)
fi
if [ -z "$token" ]; then
  echo "vp.sh: no token. Open a new shell so .zshenv exports VECTOR_PRIME_API_KEY, or run: op signin" >&2
  exit 2
fi

set -- -sS -X "$method" -H "Authorization: Bearer $token" -w '\n%{http_code}'
if [ -n "$body" ]; then
  set -- "$@" -H 'Content-Type: application/json' --data-binary "$body"
fi

if ! response=$(curl "$@" "$base$path"); then
  echo "vp.sh: request failed before a status came back: $method $base$path" >&2
  exit 1
fi

status=${response##*$'\n'}
payload=${response%$'\n'*}

case "$status" in
  2*)
    printf '%s\n' "$payload"
    ;;
  *)
    printf 'vp.sh: HTTP %s on %s %s\n' "$status" "$method" "$path" >&2
    # An unknown path returns the dashboard's HTML 404, thousands of tokens of markup.
    case "$payload" in
      '<'*) echo 'vp.sh: body is an HTML page, not JSON — the path is wrong' >&2 ;;
      *) printf '%.2000s\n' "$payload" >&2 ;;
    esac
    exit 1
    ;;
esac
