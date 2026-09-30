---
name: markdown-new
description: "Read URLs and research web sources through curl-backed providers: markdown.new for URL-to-Markdown conversion, Tavily for API-backed web search, and DeepWiki for public GitHub repository documentation."
---

# Web research

## Provider choice

1. **Known URL or docs page** → fetch it with the `markdown.new` POST request below.
2. **Empty, noisy, or truncated result** → repeat the request with `"method": "browser"`.
3. **General web search** → run `scripts/tavily-search.sh "query"`.
4. **GitHub repository documentation** → run `scripts/deepwiki-read.sh <org/repo>`.

Scripts are relative to this skill directory.

## markdown.new

Converts a public URL to Markdown. No API key. The limit is 500 requests per day per IP; past it the service returns HTTP 429.

```bash
curl -sS -X POST "https://markdown.new/" \
  -H "Content-Type: application/json" \
  -d '{"url": "<URL>"}' \
  | jq -r '.content'
```

Body parameters:

| Parameter | Values | Default | Use |
|---|---|---|---|
| `method` | `auto`, `ai`, `browser` | `auto` | `browser` renders JS-heavy pages first, adding 1–2 s |
| `retain_images` | `true`, `false` | `false` | Keep image references |

It cannot read paywalled or logged-in pages. It truncates very large pages. Sites can block its User-Agent `markdown.new/1.0` through `robots.txt` or a WAF.

## Tavily search

```bash
scripts/tavily-search.sh "lazygit keybinding config aliases"
scripts/tavily-search.sh "query" advanced 8
```

Requires `TAVILY_API_KEY` in the environment.

## DeepWiki read

```bash
scripts/deepwiki-read.sh jesseduffield/lazygit
scripts/deepwiki-read.sh https://deepwiki.com/jesseduffield/lazygit
```

The script asks the DeepWiki MCP endpoint for the whole wiki as Markdown. No API key. A DeepWiki URL is reduced to its `org/repo`, so a page path still returns the whole wiki. Reader services such as `markdown.new` get only a bot-check page from deepwiki.com.

## Report

Give a concise digest and the exact URLs it rests on. Name a missing `TAVILY_API_KEY` or a failed provider.
