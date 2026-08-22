#!/usr/bin/env bash
set -euo pipefail

query=${1:-}
search_depth=${2:-advanced}
max_results=${3:-8}

if [[ -z "$query" ]]; then
  echo "Usage: $0 <query> [basic|advanced] [max_results]" >&2
  exit 2
fi

if [[ -z "${TAVILY_API_KEY:-}" ]]; then
  echo "TAVILY_API_KEY is not set" >&2
  exit 1
fi

jq -n \
  --arg api_key "$TAVILY_API_KEY" \
  --arg query "$query" \
  --arg search_depth "$search_depth" \
  --argjson max_results "$max_results" \
  '{
    api_key: $api_key,
    query: $query,
    search_depth: $search_depth,
    max_results: $max_results,
    include_answer: true,
    include_raw_content: false,
    include_images: false
  }' |
  curl -sS https://api.tavily.com/search \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TAVILY_API_KEY}" \
    --data-binary @- |
  jq -r '
    if .error then
      "ERROR: \(.error)"
    else
      (if .answer then "# Answer\n\n" + .answer + "\n" else "" end) +
      "# Results\n\n" +
      ((.results // []) | to_entries | map(
        "## " + ((.key + 1) | tostring) + ". " + (.value.title // "Untitled") +
        "\nURL: " + (.value.url // "") +
        (if .value.score then "\nScore: " + (.value.score | tostring) else "" end) +
        "\n\n" + (.value.content // "")
      ) | join("\n\n"))
    end
  '
