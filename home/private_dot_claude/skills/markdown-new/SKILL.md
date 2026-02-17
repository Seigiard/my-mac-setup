---
name: markdown-new
description: Convert any public URL to clean Markdown via markdown.new. Use when fetching website content, reading documentation pages, extracting article text, or when WebFetch produces noisy output. Especially useful for JS-heavy sites and SPAs. No API key required.
---

# markdown.new

Convert public URLs to clean, structured Markdown via https://markdown.new/. Free, no API key, 500 requests/day per IP.

## When to Use

- Need clean markdown from a website (documentation, articles, blog posts)
- WebFetch returns noisy or incomplete content
- JS-heavy or SPA sites that need browser rendering
- Need structured JSON response with metadata (title, method used, duration)

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

### Query Parameters

Append to GET URL or include in POST body:

| Parameter | Values | Default | Description |
|---|---|---|---|
| `method` | `auto`, `ai`, `browser` | `auto` | Conversion method. Use `browser` for JS-heavy sites |
| `retain_images` | `true`, `false` | `false` | Keep image references in output |

### Multiple URLs

Fetch multiple pages sequentially:

```bash
for url in "https://docs.example.com/intro" "https://docs.example.com/api"; do
  curl -sS -X POST "https://markdown.new/" \
    -H "Content-Type: application/json" \
    -d "{\"url\": \"$url\"}" | jq -r '.content'
  echo -e "\n---\n"
done
```

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
