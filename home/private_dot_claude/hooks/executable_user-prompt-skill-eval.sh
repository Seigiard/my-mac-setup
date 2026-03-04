#!/bin/sh
cat > /dev/null

cat <<'EOF'
INSTRUCTION: MANDATORY SKILL ACTIVATION SEQUENCE

Step 1 - EVALUATE:
For each skill in <available_skills>, state: [skill-name] - YES/NO - [reason]

Step 2 - ACTIVATE:
IF any skills are YES → Use Skill(skill-name) tool for EACH relevant skill NOW
IF no skills are YES → State "No skills needed" and proceed

Step 3 - IMPLEMENT:
Only after Step 2 is complete, proceed with implementation.

CRITICAL: You MUST call Skill() tool in Step 2. Do NOT skip to implementation.

---

TOOL ROUTING — use the right tool for the job:

WEB SEARCH: mcp__jina__search_web or mcp__tavily-mcp__tavily_search (NOT Bash curl)
DEEP RESEARCH: mcp__tavily-mcp__tavily_research (multi-step, citations)
READ URL: mcp__jina__read_url (PDFs, selectors, auth). Fallback: Skill(markdown-new) for simple pages
LIBRARY DOCS / API (quick inline): mcp__plugin_context7-plugin_context7 tools directly. Fallback: mcp__deepwiki
LIBRARY DOCS (background, keeps context clean): Agent(context7-plugin:docs-researcher)
LIBRARY DEEP RESEARCH (source code, PRs, history, versions, breaking changes): Agent(open-source-librarian) — background
SITE CRAWL: mcp__tavily-mcp__tavily_crawl or mcp__tavily-mcp__tavily_map

NEVER use Bash curl for web search/URL reading when MCP tools are available.
EOF
