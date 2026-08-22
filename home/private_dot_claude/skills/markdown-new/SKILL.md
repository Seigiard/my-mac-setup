---
name: markdown-new
description: "Read URLs and research web sources through curl-backed providers: markdown.new for URL-to-Markdown conversion, Jina Reader/Search for fallback reading and lightweight search, Tavily for API-backed web search, and DeepWiki for public GitHub repository documentation."
---

# Web research

Use this skill for internet and documentation research when curl-backed providers are appropriate.

## Provider choice

1. **Known URL or docs page to read** → use `markdown.new` first for clean Markdown.
2. **Known URL fallback** → use `scripts/jina-read.sh <url>` when `markdown.new` fails, is rate-limited, or returns noisy or truncated content.
3. **General web search** → use `scripts/tavily-search.sh "query"` when `TAVILY_API_KEY` is available.
4. **Lightweight fallback search** → use `scripts/jina-search.sh "query"` when Tavily is unavailable or a quick source-discovery pass is enough.
5. **GitHub repository documentation** → use `scripts/deepwiki-read.sh <org/repo>` or `scripts/deepwiki-read.sh <deepwiki-url>`.
6. **Noisy provider output** → summarize findings and cite URLs. Do not dump raw output unless the user asks.

## markdown.new

Convert public URLs to clean, structured Markdown via https://markdown.new/. Free, no API key, 500 requests/day per IP.

## API

### GET — Plain Text Response

```bash
curl -sS "https://markdown.new/<URL>"
```

Returns plain text with title, source URL, and markdown content. Includes `x-markdown-tokens` response header with estimated token count.

### POST — JSON Response (Preferred)

```bash
curl -sS -X POST "https://markdown.new/" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>"}'
```

Returns JSON:

```json
{
  "success": true,
  "url": "https://example.com",
  "title": "Example Domain",
  "content": "# Example Domain\n\n...",
  "timestamp": "2026-02-17 17:05:42",
  "method": "Cloudflare Workers AI",
  "duration_ms": 0
}
```

Use `jq -r '.content'` to extract markdown content from POST response.

### JS-heavy pages

```bash
curl -sS -X POST "https://markdown.new/" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com/app", "method": "browser"}' \
  | jq -r '.content'
```

### Query Parameters

Append to GET URL or include in POST body:

| Parameter | Values | Default | Description |
|---|---|---|---|
| `method` | `auto`, `ai`, `browser` | `auto` | Conversion method. Use `browser` for JS-heavy sites |
| `retain_images` | `true`, `false` | `false` | Keep image references in output |

## Conversion Pipeline

Three-tier fallback (fastest wins):
1. `Accept: text/markdown` header — native markdown from Cloudflare-enabled sites
2. Cloudflare Workers AI `toMarkdown()` — AI-powered HTML→Markdown
3. Cloudflare Browser Rendering API — renders JS-heavy pages first

### Response Headers (GET)

| Header | Description |
|---|---|
| `x-markdown-tokens` | Estimated token count of the converted content |
| `x-rate-limit-remaining` | Remaining daily requests |

## Details

- User-Agent: `markdown.new/1.0` — sites can block via `robots.txt` or WAF rules
- 500 requests/day per IP (HTTP 429 when exceeded)
- Paywalled/authenticated content not supported
- Very large pages may be truncated
- Browser rendering adds ~1-2s latency

## Scripts

All scripts are relative to this skill directory.

### Tavily search

```bash
scripts/tavily-search.sh "lazygit keybinding config aliases"
scripts/tavily-search.sh "query" advanced 8
```

Requires `TAVILY_API_KEY` in env. The script uses the modern `Authorization: Bearer` header and includes `api_key` in the JSON body for compatibility with older Tavily deployments.

### Jina read URL

```bash
scripts/jina-read.sh https://example.com/docs
```

Uses Jina Reader (`https://r.jina.ai/http://...`) to convert pages to Markdown. If `JINA_API_KEY` is present, the script sends it as `Authorization: Bearer` for rate limits and extra features.

### Jina search

```bash
scripts/jina-search.sh "query terms"
```

Uses Jina Search (`https://s.jina.ai/<query>`) and returns Markdown-like search output.

### DeepWiki read

```bash
scripts/deepwiki-read.sh jesseduffield/lazygit
scripts/deepwiki-read.sh https://deepwiki.com/jesseduffield/lazygit
```

DeepWiki does not need an API key for public pages. The script converts `org/repo` to `https://deepwiki.com/org/repo` and fetches it through Jina Reader for terminal-friendly Markdown.

## Output discipline

- Prefer a concise digest with sources.
- Include the exact URLs used.
- Mention if `TAVILY_API_KEY` or `JINA_API_KEY` is missing or a provider fails.
- For codebase internals, check repo-local references first when project instructions require it. Use web research only after local references.
