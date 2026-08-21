---
status: superseded
superseded-by: commit c05718a — curl-based skills replaced by marketplace MCP plugins
---

# Context7 Skill Auth Fix

## Problem

Context7 SKILL.md curl commands lack auth headers, hitting the rate-limited free tier instead of using the provisioned API key.

## Solution

Mirror the Jina Reader auth pattern: add `Authorization: Bearer $(printenv CONTEXT7_API_KEY)` to all curl commands.

## Changes

1. **Frontmatter**: add `Requires CONTEXT7_API_KEY` to description
2. **Auth line**: add `Requires CONTEXT7_API_KEY. Auth: Authorization: Bearer $(printenv CONTEXT7_API_KEY)` after the overview heading
3. **All curl commands** (7 total): add `-H "Authorization: Bearer $(printenv CONTEXT7_API_KEY)"`
4. **Tips section**: remove "No API key is required for basic usage (rate-limited)" line

## Dependencies

- `CONTEXT7_API_KEY` env var added to `dot_zshenv.tmpl` (done by user)
- 1Password entry `op://Private/Context7 API Key/credential` (already exists in `modify_dot_claude.json`)
