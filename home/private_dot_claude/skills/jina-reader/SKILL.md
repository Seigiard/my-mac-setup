---
name: jina-reader
description: Read URLs, search the web, and run deep research via Jina AI APIs. Use when fetching website content as markdown (r.jina.ai), performing web search (s.jina.ai), or multi-step research (DeepSearch). Supports PDFs, JS-heavy sites, CSS selectors, and screenshots. Requires JINA_API_KEY.
---

# Jina AI — Reader, Search & DeepSearch

Requires `JINA_API_KEY` environment variable. Auth: `Authorization: Bearer $(printenv JINA_API_KEY)`.

## Endpoints

| Endpoint | URL Pattern | Purpose |
|---|---|---|
| Reader | `https://r.jina.ai/{url}` | Convert any URL to clean markdown |
| Search | `https://s.jina.ai/{query}` | Web search with LLM-friendly results |
| DeepSearch | `https://deepsearch.jina.ai/v1/chat/completions` | Multi-step research agent |

## Reader API (`r.jina.ai`)

### Basic Usage

```bash
# Markdown output
curl -sS "https://r.jina.ai/https://example.com" \
  -H "Authorization: Bearer $(printenv JINA_API_KEY)" \
  -H "Accept: text/plain"

# JSON output (includes url, title, content, timestamp)
curl -sS "https://r.jina.ai/https://example.com" \
  -H "Authorization: Bearer $(printenv JINA_API_KEY)" \
  -H "Accept: application/json" | jq '.'
```

### Headers

#### Content Control

| Header | Values | Default | Description |
|---|---|---|---|
| `Accept` | `text/plain`, `application/json` | `text/plain` | Response format |
| `X-Respond-With` | `content`, `markdown`, `html`, `text`, `screenshot`, `pageshot` | `content` | Output type |
| `X-Retain-Images` | `none`, `all`, `alt` | `all` | Image handling |
| `X-Retain-Links` | `none`, `all`, `text` | `all` | Link handling |
| `X-With-Links-Summary` | `true` | - | Append links section at the end |
| `X-With-Images-Summary` | `true`/`false` | `false` | Append images section |
| `X-Token-Budget` | number | - | Max tokens for response |

#### CSS Selectors

| Header | Description |
|---|---|
| `X-Target-Selector` | Only extract matching elements (e.g. `article`, `.main-content`) |
| `X-Wait-For-Selector` | Wait for elements before extracting (for dynamic content) |
| `X-Remove-Selector` | Remove elements before extraction (e.g. `nav, footer, .ads`) |

#### Browser & Network

| Header | Description |
|---|---|
| `X-Timeout` | Page load timeout (1-180s) |
| `X-Respond-Timing` | When page is "ready" (`html`, `network-idle`) |
| `X-No-Cache` | Bypass cached content |
| `X-Proxy` | Country code or `auto` for proxy |
| `X-Set-Cookie` | Forward cookies for authenticated content |

### Common Patterns

```bash
# Clean article — remove nav/footer/ads
curl -sS "https://r.jina.ai/https://example.com/article" \
  -H "Authorization: Bearer $(printenv JINA_API_KEY)" \
  -H "X-Retain-Images: none" \
  -H "X-Remove-Selector: nav, footer, .sidebar, .ads"

# Extract specific section via CSS selector
curl -sS "https://r.jina.ai/https://example.com" \
  -H "Authorization: Bearer $(printenv JINA_API_KEY)" \
  -H "X-Target-Selector: article.main-content"

# Parse a PDF
curl -sS "https://r.jina.ai/https://example.com/paper.pdf" \
  -H "Authorization: Bearer $(printenv JINA_API_KEY)"

# Wait for dynamic SPA content
curl -sS "https://r.jina.ai/https://spa-app.com" \
  -H "Authorization: Bearer $(printenv JINA_API_KEY)" \
  -H "X-Wait-For-Selector: .loaded-content" \
  -H "X-Respond-Timing: network-idle"
```

## Search API (`s.jina.ai`)

```bash
# Plain text search
curl -sS "https://s.jina.ai/your+search+query" \
  -H "Authorization: Bearer $(printenv JINA_API_KEY)" \
  -H "Accept: text/plain"

# JSON search
curl -sS "https://s.jina.ai/your+search+query" \
  -H "Authorization: Bearer $(printenv JINA_API_KEY)" \
  -H "Accept: application/json" | jq '.'

# Site-scoped search
curl -sS "https://s.jina.ai/OpenAI+GPT-5?site=reddit.com" \
  -H "Authorization: Bearer $(printenv JINA_API_KEY)"

# Search without fetching page content (fast, headers only)
curl -sS "https://s.jina.ai/your+query" \
  -H "Authorization: Bearer $(printenv JINA_API_KEY)" \
  -H "X-Respond-With: no-content"
```

### Search Parameters

| Param | Values | Description |
|---|---|---|
| `site` | domain | Limit to specific site |
| `type` | `web`, `images`, `news` | Search type |
| `num` | 0-20 | Number of results |
| `gl` | country code | Geo-location (e.g. `us`) |
| `filetype` | extension | Filter by file type |
| `intitle` | string | Must appear in title |

## DeepSearch

Multi-step research agent. OpenAI-compatible chat completions API. Takes 30-120s.

```bash
curl -sS "https://deepsearch.jina.ai/v1/chat/completions" \
  -H "Authorization: Bearer $(printenv JINA_API_KEY)" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "jina-deepsearch-v1",
    "messages": [{"role": "user", "content": "Your research question"}],
    "stream": false
  }' | jq '.'
```

## Rate Limits

- **Free (no key):** 20 RPM
- **With API key:** Higher limits, token-based pricing

## When to Use vs Alternatives

| Need | Tool |
|---|---|
| Quick URL → markdown, no API key | **markdown.new** |
| URL → markdown with CSS selectors, PDFs, auth cookies | **Jina Reader** |
| Web search with LLM-friendly output | **Jina Search** or **Tavily search** |
| Multi-step deep research | **Jina DeepSearch** or **Tavily research** |
| Batch URL extraction with reranking | **Tavily extract** |
